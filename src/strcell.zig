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

/// The top bit of a StringCell's cached `hash` word flags a pure-ASCII string
/// (every byte < 0x80). For ASCII, the WTF-8 storage is already a flat
/// 1-byte-per-code-unit image, so `byte offset == UTF-16 index`: charAt/indexOf/
/// slice and regexp offset math become O(1) instead of walking the string. The
/// low 63 bits remain the FNV-1a content hash. Interning and `eql` stay exact
/// because ASCII-ness is a deterministic function of content — two equal strings
/// classify identically and so carry an identical `hash` word — and the intern
/// shard pick uses only low bits. This is the first brick of the flat-string
/// model (Phase 1); later phases widen to true latin1/UTF-16 flat storage.
pub const ascii_flag: u64 = @as(u64, 1) << 63;

/// Bit 62 of a StringCell's cached `hash` word flags a **latin1 / is8Bit**
/// string: every UTF-16 code unit ≤ 0xFF. For well-formed WTF-8 this is exactly
/// "every byte ≤ 0xC3" — a code unit > 0xFF is only ever encoded with a lead
/// byte ≥ 0xC4 (2-byte C4–DF for U+0100–U+07FF, 3/4-byte E0–F4, or the
/// lone-surrogate lead ED), while latin1 uses only ASCII bytes plus the leads
/// C2/C3 and their 0x80–0xBF continuations. ASCII ⊂ latin1, so an ASCII cell
/// carries BOTH flags. This is the representation discriminator the flat-string
/// storage flip keys on (a flat-latin1 cell is exactly an is8Bit, non-ASCII
/// cell) and it makes the ABI `is8Bit` predicate an O(1) cell read. Same
/// safety argument as `ascii_flag`: latin1-ness is a deterministic function of
/// content, so equal strings classify identically and share one `hash` word;
/// the low bits (intern shard pick, `eql` fast-reject) are unaffected.
pub const latin1_flag: u64 = @as(u64, 1) << 62;

/// The bits of `hash` that are the actual FNV-1a content hash (the top two are
/// the cached ASCII/latin1 classification flags). Compare masked when checking
/// a cell's hash against a raw `hashBytes`.
pub const content_hash_mask: u64 = ~(ascii_flag | latin1_flag);

/// FNV-1a content hash with the ASCII and latin1 classification folded into the
/// top two bits, computed in a single pass: `high` accumulates the OR of every
/// byte (no bit 0x80 ⇒ ASCII); `wide` accumulates whether any byte ≥ 0xC4 (none
/// ⇒ every code unit ≤ 0xFF ⇒ latin1). Every StringCell construction path uses
/// this so `isAscii()` / `isLatin1()` are O(1).
pub fn contentHash(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    var high: u8 = 0;
    var wide: u8 = 0;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
        high |= b;
        wide |= @intFromBool(b >= 0xC4);
    }
    h &= content_hash_mask;
    if (high & 0x80 == 0) h |= ascii_flag;
    if (wide == 0) h |= latin1_flag;
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
    const gc_managed_mask: usize = 1;

    bytes: []const u8,
    hash: u64,
    /// The aligned owner pointer leaves its low bit available for managed-cell
    /// classification. Keeping both facts in one word preserves StringCell's
    /// 32-byte hot footprint even when a string retains external storage.
    owner_and_gc: usize = 0,

    /// True only when the cell itself was allocated by zig-gc. Static literals,
    /// arena strings, and intern-table entries remain outside the heap and must
    /// never be handed to the collector's strict `mark` entry point.
    pub fn isGcManaged(self: *const StringCell) bool {
        return self.owner_and_gc & gc_managed_mask != 0;
    }

    pub fn setGcManaged(self: *StringCell, managed: bool) void {
        if (managed) {
            self.owner_and_gc |= gc_managed_mask;
        } else {
            self.owner_and_gc &= ~gc_managed_mask;
        }
    }

    /// Original embedder allocation retained by private external-string
    /// constructors. Internal bytes may be canonical WTF-8; this obligation is
    /// released only when the cell dies or its arena Context is destroyed.
    pub fn externalOwner(self: *const StringCell) ?*ExternalStringOwner {
        const address = self.owner_and_gc & ~gc_managed_mask;
        return if (address == 0) null else @ptrFromInt(address);
    }

    pub fn setExternalOwner(self: *StringCell, owner: ?*ExternalStringOwner) void {
        const address = if (owner) |record| @intFromPtr(record) else 0;
        std.debug.assert(address & gc_managed_mask == 0);
        self.owner_and_gc = address | (self.owner_and_gc & gc_managed_mask);
    }

    pub fn eql(self: *const StringCell, other: *const StringCell) bool {
        if (self == other) return true; // interned ⇒ pointer identity is enough
        // `hash` is computed over the WTF-8 CONTENT (never the stored image) and
        // carries the latin1/ASCII classification in its top bits, so equal
        // hashes imply equal representation. That separates a flat latin1 image
        // from a byte-identical non-latin1 WTF-8 image of *different* content:
        // their contents differ ⇒ their content hashes differ ⇒ not equal, even
        // though the stored bytes collide. Within one representation the stored
        // image is injective, so hash-equal + bytes-equal ⇒ content-equal.
        return self.hash == other.hash and std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn eqlBytes(self: *const StringCell, bytes: []const u8) bool {
        return std.mem.eql(u8, self.bytes, bytes);
    }

    /// True when every code unit is ASCII (< 0x80), so the WTF-8 bytes are
    /// already a flat 1-byte-per-unit image (`byte offset == UTF-16 index`),
    /// making indexOf/charAt/slice/regexp offset conversions O(1). Cached in
    /// `hash`'s top bit at construction — see `contentHash`.
    pub fn isAscii(self: *const StringCell) bool {
        return self.hash & ascii_flag != 0;
    }

    /// True when every UTF-16 code unit is ≤ 0xFF (latin1 / JSC `is8Bit`).
    /// O(1): cached in `hash`'s bit 62 at construction — see `latin1_flag`.
    /// ASCII ⇒ latin1, so this is a superset of `isAscii()`.
    pub fn isLatin1(self: *const StringCell) bool {
        return self.hash & latin1_flag != 0;
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
        const cell = StringCell{ .bytes = s, .hash = contentHash(s) };
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

/// Transcode a **flat-latin1** byte image (1 raw byte per code unit, values
/// 0x00–0xFF) into canonical WTF-8, returning an owned copy. Bytes < 0x80 copy
/// unchanged; each 0x80–0xFF byte becomes the 2-byte UTF-8 encoding of
/// U+0080–U+00FF (a 0xC2/0xC3 lead + one 0x80–0xBF continuation). This is the
/// **egress** transform for the flat-string model: once latin1 strings are
/// stored flat (Phase 2/3), a caller that needs real WTF-8/UTF-8 bytes for a
/// latin1 cell materializes them through here. Always allocates (the caller that
/// wants to borrow-when-ASCII checks `isAscii()`/for a high byte first).
pub fn latin1FlatToWtf8(allocator: std.mem.Allocator, flat: []const u8) std.mem.Allocator.Error![]u8 {
    var extra: usize = 0;
    for (flat) |b| extra += @intFromBool(b >= 0x80);
    const out = try allocator.alloc(u8, flat.len + extra);
    var j: usize = 0;
    for (flat) |b| {
        if (b < 0x80) {
            out[j] = b;
            j += 1;
        } else {
            out[j] = 0xC0 | (b >> 6); // 0xC2 or 0xC3
            out[j + 1] = 0x80 | (b & 0x3F);
            j += 2;
        }
    }
    return out;
}

/// Transcode canonical WTF-8 that is KNOWN to be latin1 (every code unit ≤ 0xFF,
/// i.e. only ASCII bytes plus 0xC2/0xC3 two-byte sequences — exactly what
/// `latin1_flag` marks) into the flat-latin1 image (1 raw byte per code unit),
/// returning an owned copy. Inverse of `latin1FlatToWtf8`; this is the
/// **construction** transform that shrinks a latin1-non-ASCII string to
/// 1 byte/unit at storage time. Caller MUST guarantee latin1 input — a lead byte
/// ≥ 0xC4 or a 3/4-byte sequence would be mis-decoded (asserted in debug).
pub fn wtf8ToLatin1Flat(allocator: std.mem.Allocator, wtf8: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, wtf8.len); // latin1 WTF-8 only shrinks (≤2→1)
    var i: usize = 0;
    while (i < wtf8.len) {
        const b = wtf8[i];
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
            i += 1;
        } else {
            std.debug.assert(b == 0xC2 or b == 0xC3); // latin1 lead only
            const cont = wtf8[i + 1];
            out.appendAssumeCapacity((@as(u8, b & 0x1F) << 6) | (cont & 0x3F));
            i += 2;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Choose the STORED byte image for canonical WTF-8 `canon` (whose content hash
/// is `h`): a flat latin1 image (1 raw byte per code unit) when the content is
/// latin1 but not pure ASCII, otherwise `canon` itself unchanged (ASCII is
/// already flat; non-latin1 stays WTF-8 until the UTF-16 phase). **Takes
/// ownership of `canon`**: on the flat path it frees `canon` (even on an
/// allocation failure) and returns the flat copy; otherwise it returns `canon`
/// verbatim. This is the storage side of the flat-string model — the stored
/// image is a deterministic function of content, so equal strings still get one
/// byte image *within a representation*, and cross-representation collisions
/// (a flat latin1 image equal to some non-latin1 WTF-8 image) are separated by
/// the content hash (computed over `canon`, never the stored image) and the
/// cached latin1 flag — see `StringCell.eql`.
///
/// TRANSITIONAL NOTE: `createCell`/`createCellOwned`/`InternTable.intern` use
/// this now; `staticCell` and the gc managed factory still store WTF-8, so the
/// live engine (which builds strings through the factory) is unchanged. Those
/// two flip together in the coordinated engine change; until then, do not mix a
/// latin1 `staticCell` with a latin1 `createCell` of the same content.
fn storedImage(allocator: std.mem.Allocator, canon: []u8, h: u64) std.mem.Allocator.Error![]u8 {
    if (h & latin1_flag != 0 and h & ascii_flag == 0) {
        defer allocator.free(canon);
        return try wtf8ToLatin1Flat(allocator, canon);
    }
    return canon;
}

/// Allocate a fresh (un-interned) cell that owns a (surrogate-canonicalized),
/// representation-selected copy of `bytes`. This is the minimal constructor the
/// NaN-box `Value` representation needs; interning is optional (below).
/// `allocator` owns both the cell and the byte copy.
pub fn createCell(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!*StringCell {
    if (active_managed_factory) |factory|
        return factory.create(factory.context, allocator, bytes);
    const canon = try canonicalizeSurrogates(allocator, bytes);
    const h = contentHash(canon); // over the WTF-8 content, not the stored image
    const stored = try storedImage(allocator, canon, h); // consumes canon
    errdefer allocator.free(stored);
    const cell = try allocator.create(StringCell);
    cell.* = .{ .bytes = stored, .hash = h };
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
    const canon = if (std.mem.indexOfScalar(u8, owned, 0xED) == null) owned else blk: {
        const canonical = try canonicalizeSurrogates(allocator, owned);
        allocator.free(owned);
        owns_original = false;
        break :blk canonical;
    };
    owns_original = false; // ownership of `canon` now passes to storedImage
    const h = contentHash(canon); // over the WTF-8 content, not the stored image
    const stored = try storedImage(allocator, canon, h); // consumes canon
    errdefer allocator.free(stored);
    const cell = try allocator.create(StringCell);
    cell.* = .{ .bytes = stored, .hash = h };
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
                // Key (WTF-8 content) and cell.bytes (stored image) are now
                // separate allocations — the stored image may be flat latin1.
                self.allocator.free(entry.key_ptr.*);
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
        const h = contentHash(bytes);
        const shard = &self.shards[h & (shard_count - 1)];
        shard.acquire();
        defer shard.releaseLock();

        // Look up by the WTF-8 CONTENT `bytes`: the map is keyed on content, not
        // on the cell's stored image, because a flat latin1 image can collide
        // byte-for-byte with a different string's WTF-8 image.
        if (shard.map.get(bytes)) |existing| return existing;

        // Miss: the map key is an owned copy of the WTF-8 content (so it outlives
        // the caller's slice and stays a canonical, collision-free key); the cell
        // stores the representation-selected image (flat latin1 when applicable),
        // a separate allocation.
        const key = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(key);
        const canon = try self.allocator.dupe(u8, bytes);
        const stored = try storedImage(self.allocator, canon, h); // consumes canon
        errdefer self.allocator.free(stored);
        const cell = try self.allocator.create(StringCell);
        errdefer self.allocator.destroy(cell);
        cell.* = .{ .bytes = stored, .hash = h };
        try shard.map.put(self.allocator, key, cell);
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
    try std.testing.expectEqual(contentHash("abc"), c.hash);
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
    try std.testing.expectEqual(contentHash("hi"), cell.hash);
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
    try std.testing.expectEqual(contentHash("undefined"), a.hash);
    // Its hash matches what the runtime intern path would compute for the same
    // bytes, so a literal cell and an interned cell of equal content agree on
    // hash (equality stays by-bytes; only identity differs across the boundary).
    try std.testing.expectEqual(contentHash("null"), c.hash);
}

test "strcell: isAscii is cached and reflects content, hash low bits unchanged" {
    const a = std.testing.allocator;
    const ascii = try createCell(a, "hello world");
    defer {
        a.free(ascii.bytes);
        a.destroy(ascii);
    }
    // "café" has a non-ASCII 'é' (U+00E9) → not ASCII.
    const latin1 = try createCell(a, "caf\xc3\xa9");
    defer {
        a.free(latin1.bytes);
        a.destroy(latin1);
    }
    try std.testing.expect(ascii.isAscii());
    try std.testing.expect(!latin1.isAscii());
    // ASCII ⊂ latin1: an ASCII cell is also is8Bit; "café" is latin1 but not ASCII.
    try std.testing.expect(ascii.isLatin1());
    try std.testing.expect(latin1.isLatin1());
    // The flags live in the top two bits; the low 62 bits still match the pure
    // FNV content hash, so the shard pick (low bits) and hash agreement hold.
    try std.testing.expectEqual(hashBytes("hello world") & content_hash_mask, ascii.hash & content_hash_mask);
    try std.testing.expectEqual(hashBytes("caf\xc3\xa9") & content_hash_mask, latin1.hash & content_hash_mask);
}

test "strcell: isLatin1 tracks the is8Bit boundary (≤ 0xFF) at construction" {
    const a = std.testing.allocator;
    const Case = struct { bytes: []const u8, ascii: bool, latin1: bool };
    const cases = [_]Case{
        .{ .bytes = "plain ascii", .ascii = true, .latin1 = true },
        .{ .bytes = "", .ascii = true, .latin1 = true }, // empty is vacuously 8-bit
        .{ .bytes = "caf\xc3\xa9", .ascii = false, .latin1 = true }, // é U+00E9
        .{ .bytes = "\xc3\xbf", .ascii = false, .latin1 = true }, // ÿ U+00FF, the boundary
        .{ .bytes = "\xc4\x80", .ascii = false, .latin1 = false }, // Ā U+0100, just past it
        .{ .bytes = "\xce\xb1", .ascii = false, .latin1 = false }, // α U+03B1 (Greek)
        .{ .bytes = "\xf0\x9f\x98\x80", .ascii = false, .latin1 = false }, // 😀 astral
        .{ .bytes = "\xed\xa0\x80", .ascii = false, .latin1 = false }, // lone high surrogate
    };
    for (cases) |c| {
        const cell = try createCell(a, c.bytes);
        defer {
            a.free(cell.bytes);
            a.destroy(cell);
        }
        try std.testing.expectEqual(c.ascii, cell.isAscii());
        try std.testing.expectEqual(c.latin1, cell.isLatin1());
    }
}

test "strcell: latin1<->WTF-8 transcode round-trips every code unit and matches std UTF-8" {
    const a = std.testing.allocator;
    // Flat image of all 256 latin1 code units 0x00..0xFF, once each.
    var flat: [256]u8 = undefined;
    for (0..256) |i| flat[i] = @intCast(i);

    const wtf8 = try latin1FlatToWtf8(a, &flat);
    defer a.free(wtf8);

    // The produced WTF-8 must be exactly the UTF-8 encoding of U+0000..U+00FF and
    // must classify as latin1 (never ASCII, since it contains 0x80..0xFF units).
    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(a);
    for (0..256) |cp| {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(@intCast(cp), &buf);
        try expected.appendSlice(a, buf[0..n]);
    }
    try std.testing.expectEqualSlices(u8, expected.items, wtf8);
    try std.testing.expect(contentHash(wtf8) & latin1_flag != 0);
    try std.testing.expect(contentHash(wtf8) & ascii_flag == 0);

    // Inverse recovers the original flat image exactly.
    const back = try wtf8ToLatin1Flat(a, wtf8);
    defer a.free(back);
    try std.testing.expectEqualSlices(u8, &flat, back);

    // A pure-ASCII flat image transcodes to itself (byte-identical, no widening).
    const ascii_flat = "hello, world!";
    const ascii_wtf8 = try latin1FlatToWtf8(a, ascii_flat);
    defer a.free(ascii_wtf8);
    try std.testing.expectEqualStrings(ascii_flat, ascii_wtf8);
    const ascii_back = try wtf8ToLatin1Flat(a, ascii_wtf8);
    defer a.free(ascii_back);
    try std.testing.expectEqualStrings(ascii_flat, ascii_back);
}

test "strcell: latin1 non-ASCII stores flat (1 byte/unit); ASCII and non-latin1 unchanged" {
    const a = std.testing.allocator;
    // café — é is U+00E9 (latin1). Stored flat: the 2-byte WTF-8 C3 A9 becomes 0xE9.
    const cafe = try createCell(a, "caf\xc3\xa9");
    defer {
        a.free(cafe.bytes);
        a.destroy(cafe);
    }
    try std.testing.expectEqualStrings("caf\xe9", cafe.bytes);
    try std.testing.expect(cafe.isLatin1() and !cafe.isAscii());

    // Pure ASCII: byte-identical in both encodings, so storage is unchanged.
    const ascii = try createCell(a, "hello");
    defer {
        a.free(ascii.bytes);
        a.destroy(ascii);
    }
    try std.testing.expectEqualStrings("hello", ascii.bytes);

    // Non-latin1 (😀, astral) keeps its WTF-8 image (flat UTF-16 is a later phase).
    const emoji = try createCell(a, "\xf0\x9f\x98\x80");
    defer {
        a.free(emoji.bytes);
        a.destroy(emoji);
    }
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", emoji.bytes);
    try std.testing.expect(!emoji.isLatin1());

    // Two independently-built "café" cells are still content-equal despite flat
    // storage — the hash is over content, the stored image is deterministic.
    const cafe2 = try createCell(a, "caf\xc3\xa9");
    defer {
        a.free(cafe2.bytes);
        a.destroy(cafe2);
    }
    try std.testing.expect(cafe.eql(cafe2));
}

test "strcell: flat-latin1 image colliding with a WTF-8 image stays a distinct string" {
    const a = std.testing.allocator;
    // A latin1 string of code units U+00E4 U+00BA U+009C. Its WTF-8 *input* is
    // C3 A4 C2 BA C2 9C; stored FLAT it becomes the 3 bytes E4 BA 9C.
    const latin1_input = "\xc3\xa4\xc2\xba\xc2\x9c";
    // The CJK char 亜 (U+4E9C) has WTF-8 exactly E4 BA 9C — the SAME stored image.
    const cjk_input = "\xe4\xba\x9c";

    const l = try createCell(a, latin1_input);
    defer {
        a.free(l.bytes);
        a.destroy(l);
    }
    const c = try createCell(a, cjk_input);
    defer {
        a.free(c.bytes);
        a.destroy(c);
    }

    // Their STORED images collide byte-for-byte...
    try std.testing.expectEqualSlices(u8, "\xe4\xba\x9c", l.bytes);
    try std.testing.expectEqualSlices(u8, l.bytes, c.bytes);
    // ...yet they are different strings: representation and content hash differ,
    // so byte-equality does NOT make them equal.
    try std.testing.expect(l.isLatin1() and !c.isLatin1());
    try std.testing.expect(l.hash != c.hash);
    try std.testing.expect(!l.eql(c));

    // Interning keeps them distinct too (keyed on WTF-8 content, not the image).
    var t = InternTable.init(a);
    defer t.deinit();
    const il = try t.intern(latin1_input);
    const ic = try t.intern(cjk_input);
    try std.testing.expect(il != ic);
    try std.testing.expectEqual(@as(usize, 2), t.count());
    try std.testing.expectEqual(il, try t.intern(latin1_input)); // re-intern → same cell
    try std.testing.expectEqual(ic, try t.intern(cjk_input));
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
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(StringCell));
}
