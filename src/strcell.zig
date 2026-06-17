//! String cells + a concurrent intern table — blocker #8 of Phase 7
//! (issue zig-utils/zig-js#1, docs/threads/P7-gil-removal.md).
//!
//! Two coupled facts make this a prerequisite for NaN-boxing `Value` (#7):
//!   1. A NaN-boxed value is one 64-bit word with a 48-bit pointer payload, but
//!      today a string `Value` is a `[]const u8` slice — *two* words. So a
//!      NaN-boxed string must be a single pointer to a **`StringCell`** holding
//!      the {bytes, len}. That's the minimal, on-critical-path piece.
//!   2. Layer C (the GIL-removed shared heap) wants equal strings to be able to
//!      share one immutable cell across threads — a **sharded intern table**.
//!      The design note keeps strings *uninterned* until Layer C precisely so
//!      this table can be introduced without earlier phases assuming
//!      pointer-identity of equal strings.
//!
//! This module is the **mechanism only**, exhaustively tested in isolation
//! (including real multi-threaded convergence) — the same discipline used for
//! the GC and the NaN-box codec. Nothing in the engine imports it yet; wiring
//! `Value`'s string payload to `*StringCell` is part of the mechanical `Value`
//! swap, which is a separate step.

const std = @import("std");

/// FNV-1a, the canonical content hash for a string cell. Stable across runs and
/// cheap; used both as the intern key and as a cached field so a `StringCell`
/// can key a hash map without rehashing.
pub fn hashBytes(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// An immutable string cell: a single allocation the engine can point at with
/// one 48-bit word. `bytes` is owned by whoever allocated the cell (the GC heap
/// or an arena); `hash` is the cached FNV-1a content hash. Immutable after
/// creation, so it is safe to share read-only across threads.
pub const StringCell = struct {
    bytes: []const u8,
    hash: u64,

    pub fn eql(self: *const StringCell, other: *const StringCell) bool {
        if (self == other) return true; // interned ⇒ pointer identity is enough
        return self.hash == other.hash and std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn eqlBytes(self: *const StringCell, bytes: []const u8) bool {
        return std.mem.eql(u8, self.bytes, bytes);
    }
};

/// A compile-time-interned cell for a string *literal* — **no allocator
/// needed**. This resolves the one real design wrinkle of the NaN-box `Value`
/// swap: hundreds of `Value{ .string = "literal" }` sites construct strings with
/// no allocator in scope, but a NaN-boxed string must point at a `StringCell`.
/// `staticCell` returns a pointer into static storage that lives for the whole
/// program, and Zig memoizes the instantiation by the comptime `s`, so repeated
/// calls with the *same* literal return the *same* pointer (literals are
/// interned for free, at compile time). Runtime strings (concatenation results,
/// etc.) use `createCell` / `InternTable.intern` with their in-scope allocator.
pub fn staticCell(comptime s: []const u8) *const StringCell {
    return &struct {
        const cell = StringCell{ .bytes = s, .hash = hashBytes(s) };
    }.cell;
}

/// Allocate a fresh (un-interned) cell that owns a copy of `bytes`. This is the
/// minimal constructor the NaN-box `Value` swap needs; interning is optional
/// (below). `allocator` owns both the cell and the byte copy.
pub fn createCell(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!*StringCell {
    const owned = try allocator.dupe(u8, bytes);
    const cell = try allocator.create(StringCell);
    cell.* = .{ .bytes = owned, .hash = hashBytes(owned) };
    return cell;
}

/// A sharded, thread-safe string intern table: equal byte sequences map to one
/// canonical `*StringCell`, so equality becomes a pointer compare and identical
/// strings across threads share storage. Sharded by hash so concurrent interns
/// of *different* strings rarely contend; each shard is guarded by an atomic
/// spinlock (held only for the brief map lookup/insert, never across JS).
///
/// This is the Layer-C shared-string mechanism. It is opt-in: the engine stays
/// uninterned until Layer C wires this in, so nothing today assumes equal
/// strings share identity.
pub const InternTable = struct {
    pub const shard_count = 16; // power of two; hash low bits pick the shard

    const Shard = struct {
        lock: std.atomic.Value(u32) = .init(0), // 0 = free, 1 = held
        map: std.StringHashMapUnmanaged(*StringCell) = .empty,

        fn acquire(self: *Shard) void {
            while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
        }
        fn releaseLock(self: *Shard) void {
            self.lock.store(0, .release);
        }
    };

    allocator: std.mem.Allocator,
    shards: [shard_count]Shard = @splat(.{}),

    pub fn init(allocator: std.mem.Allocator) InternTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InternTable) void {
        for (&self.shards) |*shard| {
            var it = shard.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*.bytes);
                self.allocator.destroy(entry.value_ptr.*);
            }
            shard.map.deinit(self.allocator);
        }
    }

    /// Return the canonical cell for `bytes`, creating + inserting it on first
    /// sight. Repeated calls with equal bytes return the *same* pointer, from
    /// any thread. The returned cell is owned by the table (freed at `deinit`).
    pub fn intern(self: *InternTable, bytes: []const u8) std.mem.Allocator.Error!*StringCell {
        const h = hashBytes(bytes);
        const shard = &self.shards[h & (shard_count - 1)];
        shard.acquire();
        defer shard.releaseLock();

        if (shard.map.get(bytes)) |existing| return existing;

        // Miss: allocate an owned copy + cell, key the map by the owned bytes
        // (so the key outlives the caller's slice).
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        const cell = try self.allocator.create(StringCell);
        errdefer self.allocator.destroy(cell);
        cell.* = .{ .bytes = owned, .hash = h };
        try shard.map.put(self.allocator, owned, cell);
        return cell;
    }

    /// Total interned cells across all shards (test/diagnostic helper).
    pub fn count(self: *InternTable) usize {
        var n: usize = 0;
        for (&self.shards) |*shard| {
            shard.acquire();
            n += shard.map.count();
            shard.releaseLock();
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "strcell: createCell owns its bytes and caches the hash" {
    const a = std.testing.allocator;
    var src = [_]u8{ 'h', 'i' };
    const cell = try createCell(a, &src);
    defer {
        a.free(cell.bytes);
        a.destroy(cell);
    }
    src[0] = 'X'; // mutate the source: the cell kept its own copy
    try std.testing.expectEqualStrings("hi", cell.bytes);
    try std.testing.expectEqual(hashBytes("hi"), cell.hash);
    try std.testing.expect(cell.eqlBytes("hi"));
    try std.testing.expect(!cell.eqlBytes("hX"));
}

test "strcell: staticCell needs no allocator and comptime-interns literals" {
    // No allocator argument — usable at the literal-construction sites that
    // have none. Same literal → same static pointer (comptime memoization);
    // distinct literals → distinct cells.
    const a = staticCell("undefined");
    const b = staticCell("undefined");
    const c = staticCell("null");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expectEqualStrings("undefined", a.bytes);
    try std.testing.expectEqual(hashBytes("undefined"), a.hash);
    // Its hash matches what the runtime intern path would compute for the same
    // bytes, so a literal cell and an interned cell of equal content agree on
    // hash (equality stays by-bytes; only identity differs across the boundary).
    try std.testing.expectEqual(hashBytes("null"), c.hash);
}

test "strcell: intern dedups equal bytes to one cell, separates distinct" {
    const a = std.testing.allocator;
    var t = InternTable.init(a);
    defer t.deinit();

    const x1 = try t.intern("hello");
    const x2 = try t.intern("hello"); // distinct caller slice, same content
    const y = try t.intern("world");
    const e1 = try t.intern("");
    const e2 = try t.intern("");

    try std.testing.expectEqual(x1, x2); // same canonical pointer
    try std.testing.expect(x1 != y);
    try std.testing.expectEqual(e1, e2); // empty string interns too
    try std.testing.expect(x1.eql(x2) and !x1.eql(y));
    try std.testing.expectEqual(@as(usize, 3), t.count()); // hello, world, ""
}

test "strcell: interned bytes survive a mutated caller buffer" {
    const a = std.testing.allocator;
    var t = InternTable.init(a);
    defer t.deinit();

    var buf = [_]u8{ 'a', 'b', 'c' };
    const c = try t.intern(&buf);
    buf[1] = 'Z'; // caller reuses its buffer; the table kept its own copy
    try std.testing.expectEqualStrings("abc", c.bytes);
    // Interning the original content still hits the same cell.
    try std.testing.expectEqual(c, try t.intern("abc"));
}

test "strcell: concurrent interning converges to one cell per string" {
    const a = std.testing.allocator;
    var t = InternTable.init(a);
    defer t.deinit();

    // Many threads race to intern the same small set of strings. The table must
    // converge: exactly one cell per distinct string, no corruption, no leak
    // (the testing allocator checks the last two).
    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const Worker = struct {
        fn run(table: *InternTable, ws: []const []const u8, out: []*StringCell) void {
            for (ws, 0..) |w, i| {
                // Intern each word several times; every call must agree.
                var last: ?*StringCell = null;
                var k: usize = 0;
                while (k < 50) : (k += 1) {
                    const cell = table.intern(w) catch unreachable;
                    if (last) |l| std.debug.assert(l == cell);
                    last = cell;
                }
                out[i] = last.?;
            }
        }
    };

    const n_threads = 8;
    var results: [n_threads][words.len]*StringCell = undefined;
    var threads: [n_threads]std.Thread = undefined;
    for (&threads, 0..) |*th, ti| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{ &t, words[0..], results[ti][0..] });
    }
    for (threads) |th| th.join();

    // Exactly one cell per distinct word.
    try std.testing.expectEqual(@as(usize, words.len), t.count());
    // Every thread saw the SAME canonical cell for each word.
    for (0..words.len) |wi| {
        const canonical = results[0][wi];
        for (1..n_threads) |ti| try std.testing.expectEqual(canonical, results[ti][wi]);
        try std.testing.expect(canonical.eqlBytes(words[wi]));
    }
}

test "strcell: StringCell is two words (the NaN-box string payload target)" {
    // A NaN-boxed string is one pointer to this cell; the cell itself is the
    // {ptr,len} pair the old inline slice used, plus the cached hash.
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(usize) + @sizeOf(u64)), @sizeOf(StringCell));
}
