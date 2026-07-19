//! String cells + a concurrent intern table — blocker #8 of Phase 7
//! (issue zig-utils/zig-js#1, docs/threads/P7-gil-removal.md).
//!
//! Two coupled facts made this a prerequisite for NaN-boxing `Value` (#7):
//!   1. A NaN-boxed value is one 64-bit word with a 48-bit pointer payload, but
//!      a string slice is two words. A NaN-boxed string therefore points to a
//!      **`StringCell`** holding the {bytes, len}; `Value.str` now uses
//!      `makeCell` for that payload.
//!   2. Layer C (the GIL-removed shared heap) wants equal strings to be able to
//!      share one immutable cell across threads — a **sharded intern table**.
//!      Runtime strings remain uninterned by default, so the table can be used
//!      deliberately without making pointer identity observable for ordinary
//!      string equality.
//!
//! This module is exhaustively tested in isolation (including real
//! multi-threaded convergence) and is also used by the engine's live `Value`
//! representation.

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

pub const ExternalStringDeallocator = *const fn (
    context: ?*anyopaque,
    pointer: ?*anyopaque,
    len: usize,
) callconv(.c) void;

/// Context-owned exact-once obligation for an embedder string allocation.
/// The StringCell keeps this pointer until collection; the Context owns the
/// record itself so arena-mode teardown provides the same lifetime contract.
pub const ExternalStringOwner = struct {
    pointer: ?*anyopaque,
    len: usize,
    context: ?*anyopaque,
    deallocator: ExternalStringDeallocator,
    released: std.atomic.Value(bool) = .init(false),
    release_queued: std.atomic.Value(bool) = .init(false),
    pending_next: ?*ExternalStringOwner = null,

    pub fn release(self: *ExternalStringOwner) bool {
        if (self.released.swap(true, .acq_rel)) return false;
        self.deallocator(self.context, self.pointer, self.len);
        return true;
    }
};

/// An immutable string cell: a single allocation the engine can point at with
/// one 48-bit word. `bytes` is owned by whoever allocated the cell (the GC heap
/// or an arena); `hash` is the cached FNV-1a content hash. Immutable after
/// creation, so it is safe to share read-only across threads.
pub const StringCell = struct {
    bytes: []const u8,
    hash: u64,
    /// True only when the cell itself was allocated by zig-gc. Static literals,
    /// arena strings, and intern-table entries remain outside the heap and must
    /// never be handed to the collector's strict `mark` entry point.
    gc_managed: bool = false,
    /// Original embedder allocation retained by private external-string
    /// constructors. Internal bytes may be canonical WTF-8; this obligation is
    /// released only when the cell dies or its arena Context is destroyed.
    external_owner: ?*ExternalStringOwner = null,

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

/// Combine any adjacent WTF-8 high+low surrogate pair into its 4-byte astral
/// UTF-8 encoding, returning an owned copy. A JS string is a UTF-16 code-unit
/// sequence; zig-js stores it as (W)TF-8, and the lexer already folds a literal
/// `😀` (or an astral source char) into 4-byte UTF-8. But a pair formed
/// at RUNTIME — e.g. `"\uD83D" + "\uDE00"` — arrives as two separate 3-byte WTF-8
/// surrogates: a different byte image for the same abstract string. Since a
/// string `Value` compares by cell bytes (`===`, Map/Set/property keys, indexOf),
/// the two would wrongly differ. Folding pairs at cell creation gives equal
/// strings one canonical byte image. Lone surrogates (no adjacent partner) stay
/// WTF-8, and length/charCodeAt/codePointAt already decode astral UTF-8 into two
/// code units, so this is transparent to every other string op.
pub fn canonicalizeSurrogates(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    // A surrogate needs an 0xED lead byte (U+D800..U+DFFF encode as ED A0..BF xx);
    // no 0xED means nothing to fold — the overwhelmingly common path.
    if (std.mem.indexOfScalar(u8, bytes, 0xED) == null) return allocator.dupe(u8, bytes);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, bytes.len); // folding only shrinks (6->4)
    var i: usize = 0;
    while (i < bytes.len) {
        // ED A0..AF xx  followed by  ED B0..BF xx  = high surrogate then low
        // surrogate: decode both and emit the combined 4-byte astral char.
        if (i + 6 <= bytes.len and bytes[i] == 0xED and (bytes[i + 1] & 0xF0) == 0xA0 and
            bytes[i + 3] == 0xED and (bytes[i + 4] & 0xF0) == 0xB0)
        {
            const hi: u21 = (@as(u21, bytes[i] & 0x0F) << 12) | (@as(u21, bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F);
            const lo: u21 = (@as(u21, bytes[i + 3] & 0x0F) << 12) | (@as(u21, bytes[i + 4] & 0x3F) << 6) | (bytes[i + 5] & 0x3F);
            const cp: u21 = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
            out.appendAssumeCapacity(0xF0 | @as(u8, @intCast(cp >> 18)));
            out.appendAssumeCapacity(0x80 | @as(u8, @intCast((cp >> 12) & 0x3F)));
            out.appendAssumeCapacity(0x80 | @as(u8, @intCast((cp >> 6) & 0x3F)));
            out.appendAssumeCapacity(0x80 | @as(u8, @intCast(cp & 0x3F)));
            i += 6;
        } else {
            out.appendAssumeCapacity(bytes[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Allocate a fresh (un-interned) cell that owns a (surrogate-canonicalized) copy
/// of `bytes`. This is the minimal constructor the NaN-box `Value` representation
/// needs; interning is optional (below). `allocator` owns both the cell and the
/// byte copy.
pub fn createCell(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!*StringCell {
    if (active_managed_factory) |factory|
        return factory.create(factory.context, allocator, bytes);
    const owned = try canonicalizeSurrogates(allocator, bytes);
    errdefer allocator.free(owned);
    const cell = try allocator.create(StringCell);
    cell.* = .{ .bytes = owned, .hash = hashBytes(owned) };
    return cell;
}

/// Allocate a fresh (un-interned) cell that takes ownership of `owned` when no
/// surrogate canonicalization is needed. If the bytes contain a runtime-formed
/// surrogate pair, the returned cell owns a canonicalized copy and `owned` is
/// released through the same allocator.
pub fn createCellOwned(allocator: std.mem.Allocator, owned: []u8) std.mem.Allocator.Error!*StringCell {
    if (active_managed_factory) |factory|
        return factory.create_owned(factory.context, allocator, owned);
    var owns_original = true;
    errdefer if (owns_original) allocator.free(owned);
    const bytes = if (std.mem.indexOfScalar(u8, owned, 0xED) == null) owned else blk: {
        const canonical = try canonicalizeSurrogates(allocator, owned);
        allocator.free(owned);
        owns_original = false;
        break :blk canonical;
    };
    owns_original = false;
    errdefer allocator.free(bytes);
    const cell = try allocator.create(StringCell);
    cell.* = .{ .bytes = bytes, .hash = hashBytes(bytes) };
    return cell;
}

/// Type-erased bridge installed by `gc.zig` while a context heap is active.
/// Keeping the bridge here avoids a `value -> gc -> value` import cycle while
/// letting every existing `Value.strAlloc`/`strOwned` site use one allocation
/// funnel. The GC side owns canonical byte allocation and the StringCell.
pub const ManagedFactory = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, std.mem.Allocator, []const u8) std.mem.Allocator.Error!*StringCell,
    create_owned: *const fn (*anyopaque, std.mem.Allocator, []u8) std.mem.Allocator.Error!*StringCell,
};

threadlocal var active_managed_factory: ?ManagedFactory = null;

pub fn setActiveManagedFactory(factory: ?ManagedFactory) ?ManagedFactory {
    const previous = active_managed_factory;
    active_managed_factory = factory;
    return previous;
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
// Threadlocal active intern table — optional shared-string machinery.
//
// The NaN-box `Value` swap (#7) makes a string `Value` a single pointer to a
// `StringCell`. Runtime strings now use fallible `Value.strAlloc`/`strOwned`,
// while `Value.str("literal")` is a static-cell constructor. This optional
// active intern table remains for standalone/proof paths that explicitly want
// canonical cells without threading a table through every call.
// ---------------------------------------------------------------------------

threadlocal var active_table: ?*InternTable = null;

/// Threadlocal active *arena* for legacy standalone paths that still need to
/// manufacture non-interned cells without passing an allocator. Main engine
/// runtime strings should prefer fallible `Value.strAlloc`/`strOwned`, and
/// literals should use `Value.str("literal")` / `Value.staticStr`.
threadlocal var active_arena: ?std.mem.Allocator = null;

/// Install `a` as this thread's active string arena; returns the previous one.
pub fn setActiveArena(a: ?std.mem.Allocator) ?std.mem.Allocator {
    const prev = active_arena;
    active_arena = a;
    return prev;
}

/// Allocate a (non-interned) `StringCell` owning a copy of `s` from the active
/// arena, or the (thread-safe, never-freed) page allocator if none is active.
/// Never fails except on true OOM. The allocator-free string constructor
/// `Value.str` calls this.
pub fn makeCell(s: []const u8) *StringCell {
    const a = active_arena orelse std.heap.page_allocator;
    return createCell(a, s) catch @panic("strcell.makeCell OOM");
}

/// Install `t` as this thread's active intern table; returns the previous one
/// so nested entry points can restore it. Pass null for "no interning".
pub fn setActiveTable(t: ?*InternTable) ?*InternTable {
    const prev = active_table;
    active_table = t;
    return prev;
}

pub fn activeTable() ?*InternTable {
    return active_table;
}

/// Intern `bytes` into the thread's active table → canonical `*StringCell`, or
/// null if no table is active (caller falls back to the inline slice). The
/// allocator-free string constructor the rep-flip's `Value.str` will call.
pub fn internActive(bytes: []const u8) ?*StringCell {
    const t = active_table orelse return null;
    return t.intern(bytes) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "strcell: makeCell allocates from the active arena (no per-site allocator)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit(); // frees every cell — no leak
    const prev = setActiveArena(arena_state.allocator());
    defer _ = setActiveArena(prev);

    var buf = [_]u8{ 'a', 'b', 'c' };
    const c = makeCell(&buf); // no allocator argument
    buf[0] = 'Z'; // cell kept its own copy
    try std.testing.expectEqualStrings("abc", c.bytes);
    try std.testing.expectEqual(hashBytes("abc"), c.hash);
    // Non-interned: two calls with equal bytes yield distinct cells (equality is
    // by bytes, so this is still correct for the NaN-box value).
    const d = makeCell("abc");
    try std.testing.expect(c != d);
    try std.testing.expect(c.eql(d));
}

test "strcell: threadlocal active table interns with no per-call allocator" {
    const a = std.testing.allocator;
    // No active table → internActive returns null (caller uses inline slice).
    try std.testing.expect(internActive("x") == null);

    var t = InternTable.init(a);
    defer t.deinit();
    const prev = setActiveTable(&t);
    defer _ = setActiveTable(prev);

    // With a table active, internActive needs no allocator arg and dedups.
    const c1 = internActive("hello").?;
    const c2 = internActive("hello").?;
    const d = internActive("world").?;
    try std.testing.expectEqual(c1, c2);
    try std.testing.expect(c1 != d);
    try std.testing.expectEqualStrings("hello", c1.bytes);
    try std.testing.expectEqual(@as(usize, 2), t.count());

    // Restoring null disables interning again.
    _ = setActiveTable(null);
    try std.testing.expect(internActive("hello") == null);
    _ = setActiveTable(&t);
}

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

test "strcell: StringCell stays a compact NaN-box payload target" {
    // A NaN-boxed string remains one pointer. The target carries {ptr,len}, a
    // cached hash, and immutable ownership classification for strict GC marks.
    try std.testing.expect(@sizeOf(StringCell) >= 2 * @sizeOf(usize) + @sizeOf(u64) + 1);
    try std.testing.expect(@sizeOf(StringCell) <= 32);
}
