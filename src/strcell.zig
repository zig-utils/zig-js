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
const agent = @import("agent.zig");

/// XXH3, the canonical content hash for a string cell. The fixed seed keeps
/// compile-time literal cells compatible with runtime cells. Hash equality is
/// only a fast reject: every semantic comparison still checks the exact bytes.
pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(0, bytes);
}

/// The top bit of a StringCell's atomic hash-state word flags a pure-ASCII string
/// (every byte < 0x80). For ASCII, the WTF-8 storage is already a flat
/// 1-byte-per-code-unit image, so `byte offset == UTF-16 index`: charAt/indexOf/
/// slice and regexp offset math become O(1) instead of walking the string. The
/// payload bits carry the UTF-16 length and the masked XXH3 content hash once
/// bit 61 marks it ready. Interning and `eql` stay exact
/// because ASCII-ness is a deterministic function of content — two equal strings
/// classify identically and so carry an identical `hash` word. Intern placement
/// uses an independent keyed hash. ASCII is the allocation-free subset of the
/// production flat Latin-1 representation.
pub const ascii_flag: u64 = @as(u64, 1) << 63;

/// Bit 62 of a StringCell's hash-state word flags a **latin1 / is8Bit**
/// string: every UTF-16 code unit ≤ 0xFF. For well-formed WTF-8 this is exactly
/// "every byte ≤ 0xC3" — a code unit > 0xFF is only ever encoded with a lead
/// byte ≥ 0xC4 (2-byte C4–DF for U+0100–U+07FF, 3/4-byte E0–F4, or the
/// lone-surrogate lead ED), while latin1 uses only ASCII bytes plus the leads
/// C2/C3 and their 0x80–0xBF continuations. ASCII ⊂ latin1, so an ASCII cell
/// carries BOTH flags. This is the representation discriminator flat storage
/// keys on (a flat-latin1 cell is exactly an is8Bit, non-ASCII
/// cell) and it makes the ABI `is8Bit` predicate an O(1) cell read. Same
/// safety argument as `ascii_flag`: latin1-ness is a deterministic function of
/// content, so equal strings classify identically and share one hash state.
pub const latin1_flag: u64 = @as(u64, 1) << 62;

/// Bit 61 distinguishes a published content hash from classification-only
/// state. Uninterned runtime strings begin without this bit and publish their
/// deterministic hash on first equality; static and interned strings set it at
/// construction because their consumers need the hash immediately.
pub const hash_ready_flag: u64 = @as(u64, 1) << 61;

/// Managed-cell classification is cell identity, not StringData content. It
/// lives outside every equality/hash mask but inside the same atomic word so
/// the auxiliary pointer can represent typed lifetime/index state without
/// growing StringCell.
pub const gc_managed_flag: u64 = @as(u64, 1) << 60;

pub const classification_mask: u64 = ascii_flag | latin1_flag;

/// The low 27 bits retain the exact UTF-16 length for every ordinary engine
/// string (the runtime cap is 2^26 bytes). The all-ones value is an explicit
/// fallback sentinel for oversized embedding inputs, which remain exact by
/// walking their immutable bytes. Keeping length in the existing hash-state
/// word makes String exotic `length` and bounds probes O(1) without growing the
/// 32-byte cell or allocating lazy metadata in nominally allocation-free paths.
pub const utf16_length_bits = 27;
pub const utf16_length_mask: u64 = (@as(u64, 1) << utf16_length_bits) - 1;
pub const utf16_length_unknown: u64 = utf16_length_mask;

/// The remaining 33 payload bits hold XXH3 content after `hash_ready_flag` is
/// set. Equality always confirms exact bytes, and intern-table placement uses
/// its independent keyed 64-bit hash, so shortening this fast-reject cache does
/// not weaken semantic equality or adversarial shard placement.
pub const content_hash_mask: u64 = ~(classification_mask | hash_ready_flag | gc_managed_flag | utf16_length_mask);

const persistent_state_mask = classification_mask | gc_managed_flag | utf16_length_mask;

/// The flat-latin1 storage representation is part of the production string
/// model: Latin-1-but-not-ASCII cells store one raw byte per UTF-16 code unit.
/// Representation-aware readers consume the physical image directly; byte-
/// canonical boundaries use `Value.asWtf8` to re-encode on demand. Keeping the
/// discriminator centralized prevents constructors and readers from choosing
/// different layouts.
pub const flat_storage_active: bool = true;

/// True when the cell whose content hash is `h` is *stored* as flat latin1
/// (1 raw byte per code unit) rather than WTF-8. Latin1-but-not-ASCII content is
/// the flat case; but only when `flat_storage_active`, since that is the only
/// time the constructors actually lay it out flat. Readers use this to decide
/// whether `.bytes` must be re-encoded to WTF-8 (see `Value.asWtf8`).
pub fn isFlatLatin1(h: u64) bool {
    return flat_storage_active and h & latin1_flag != 0 and h & ascii_flag == 0;
}

/// ASCII and latin1 classification as a separate dependency-free reduction so
/// the compiler can vectorize it instead of extending a byte-serial recurrence:
/// `high` accumulates the OR of every byte (no bit 0x80 ⇒ ASCII); `wide`
/// accumulates whether any byte ≥ 0xC4 (none ⇒ every code unit ≤ 0xFF ⇒ latin1).
/// Every StringCell construction path uses this so `isAscii()` / `isLatin1()`
/// are O(1), even before an uninterned cell needs its content hash.
fn classificationBits(bytes: []const u8) u64 {
    var high: u8 = 0;
    var wide: u8 = 0;
    const ClassificationVector = @Vector(16, u8);
    var i: usize = 0;
    while (bytes.len - i >= @sizeOf(ClassificationVector)) : (i += @sizeOf(ClassificationVector)) {
        const block: ClassificationVector = bytes[i..][0..@sizeOf(ClassificationVector)].*;
        high |= @reduce(.Or, block);
        wide |= @intFromBool(@reduce(.Or, block >= @as(ClassificationVector, @splat(0xC4))));
    }
    for (bytes[i..]) |b| {
        high |= b;
        wide |= @intFromBool(b >= 0xC4);
    }
    var bits: u64 = 0;
    if (high & 0x80 == 0) bits |= ascii_flag;
    if (wide == 0) bits |= latin1_flag;
    return bits;
}

/// Exact UTF-16 length of canonical WTF-8 without decoding scalar values.
/// Each continuation byte reduces the scalar count by one; each four-byte lead
/// adds the second surrogate code unit represented by that scalar.
pub fn utf16LengthOfWtf8(bytes: []const u8) usize {
    var units = bytes.len;
    for (bytes) |byte| {
        if (byte & 0xC0 == 0x80) {
            units -= 1;
        } else if (byte >= 0xF0) {
            units += 1;
        }
    }
    return units;
}

fn utf16LengthState(bytes: []const u8) u64 {
    const units = utf16LengthOfWtf8(bytes);
    return if (units < utf16_length_unknown) @intCast(units) else utf16_length_unknown;
}

/// XXH3 content hash with eager classification and a ready marker. Static
/// literals and intern-table entries consume this during construction.
pub fn contentHash(bytes: []const u8) u64 {
    return classificationBits(bytes) | utf16LengthState(bytes) | hash_ready_flag |
        (hashBytes(bytes) & content_hash_mask);
}

/// Initial state for an uninterned runtime cell. Flat-latin1 storage would
/// transform the canonical bytes, so that representation keeps an eager hash;
/// the current canonical WTF-8 representation can derive it from stored bytes
/// on first equality.
pub fn uninternedHashState(bytes: []const u8) u64 {
    const classification = classificationBits(bytes) | utf16LengthState(bytes);
    if (isFlatLatin1(classification))
        return classification | hash_ready_flag | (hashBytes(bytes) & content_hash_mask);
    return classification;
}

pub const ExternalStringDeallocator = *const fn (
    context: ?*anyopaque,
    pointer: ?*anyopaque,
    len: usize,
) callconv(.c) void;

pub const StringAuxKind = enum(u8) {
    external_owner,
    intern_owner,
    utf16_index,
    static_utf16_index,
};

const StringAuxHeader = struct {
    kind: StringAuxKind,
};

fn stringAuxKind(raw: *anyopaque) StringAuxKind {
    const header: *const StringAuxHeader = @ptrCast(raw);
    return header.kind;
}

/// Context-owned exact-once obligation for an embedder string allocation.
/// The StringCell keeps this pointer until collection; the Context owns the
/// record itself so arena-mode teardown provides the same lifetime contract.
pub const ExternalStringOwner = struct {
    aux_header: StringAuxHeader = .{ .kind = .external_owner },
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

const InternStringOwner = struct {
    aux_header: StringAuxHeader = .{ .kind = .intern_owner },
    allocator: std.mem.Allocator,
};

pub const utf16_index_stride: usize = 64;
pub const utf16_index_min_bytes: usize = 128;

pub const Utf16CodeUnit = struct {
    unit: u16,
    astral: ?u21 = null,
};

/// Representation-aware UTF-16 iterator shared by the immutable stride index
/// and the interpreter's existing streaming algorithms.
pub const Utf16CodeUnitIterator = struct {
    bytes: []const u8,
    flat_latin1: bool,
    byte_index: usize = 0,
    pending_low: ?u16 = null,

    pub fn init(bytes: []const u8, flat_latin1: bool) Utf16CodeUnitIterator {
        return .{ .bytes = bytes, .flat_latin1 = flat_latin1 };
    }

    fn wtf8SurrogateAt(bytes: []const u8, index: usize) ?u21 {
        if (index + 2 >= bytes.len or bytes[index] != 0xED) return null;
        const second = bytes[index + 1];
        const third = bytes[index + 2];
        if (second < 0xA0 or second > 0xBF or third & 0xC0 != 0x80) return null;
        return (@as(u21, bytes[index] & 0x0F) << 12) |
            (@as(u21, second & 0x3F) << 6) | @as(u21, third & 0x3F);
    }

    fn sequenceLength(bytes: []const u8, index: usize) usize {
        const byte = bytes[index];
        if (byte < 0x80) return 1;
        if (byte & 0xE0 == 0xC0) return 2;
        if (byte & 0xF0 == 0xE0) return 3;
        return 4;
    }

    pub fn next(self: *Utf16CodeUnitIterator) ?Utf16CodeUnit {
        if (self.pending_low) |unit| {
            self.pending_low = null;
            return .{ .unit = unit };
        }
        if (self.byte_index >= self.bytes.len) return null;
        if (self.flat_latin1) {
            const unit = self.bytes[self.byte_index];
            self.byte_index += 1;
            return .{ .unit = unit };
        }

        const index = self.byte_index;
        if (wtf8SurrogateAt(self.bytes, index)) |codepoint| {
            self.byte_index += 3;
            return .{ .unit = @intCast(codepoint) };
        }

        const sequence_len = sequenceLength(self.bytes, index);
        if (sequence_len == 4 and index + sequence_len <= self.bytes.len) {
            if (std.unicode.utf8Decode(self.bytes[index .. index + sequence_len])) |codepoint| {
                if (codepoint > 0xFFFF) {
                    const scalar = codepoint - 0x10000;
                    self.byte_index += sequence_len;
                    self.pending_low = @intCast(0xDC00 + (scalar & 0x3FF));
                    return .{ .unit = @intCast(0xD800 + (scalar >> 10)), .astral = codepoint };
                }
            } else |_| {}
        }

        const codepoint = if (sequence_len > 1 and index + sequence_len <= self.bytes.len)
            std.unicode.utf8Decode(self.bytes[index .. index + sequence_len]) catch @as(u21, self.bytes[index])
        else
            @as(u21, self.bytes[index]);
        self.byte_index += sequence_len;
        return .{ .unit = @intCast(codepoint & 0xFFFF) };
    }

    fn encodedState(self: *const Utf16CodeUnitIterator) usize {
        return (self.byte_index << 1) | @intFromBool(self.pending_low != null);
    }

    fn restore(bytes: []const u8, encoded: usize) Utf16CodeUnitIterator {
        const byte_index = encoded >> 1;
        var iterator = Utf16CodeUnitIterator.init(bytes, false);
        iterator.byte_index = byte_index;
        if (encoded & 1 != 0) {
            std.debug.assert(byte_index >= 4);
            const codepoint = std.unicode.utf8Decode(bytes[byte_index - 4 .. byte_index]) catch unreachable;
            std.debug.assert(codepoint > 0xFFFF);
            iterator.pending_low = @intCast(0xDC00 + ((codepoint - 0x10000) & 0x3FF));
        }
        return iterator;
    }
};

pub const Utf16Index = struct {
    aux_header: StringAuxHeader,
    previous_owner: std.atomic.Value(?*anyopaque),
    units: usize,
    checkpoints: []const usize,

    fn checkpointCount(units: usize) usize {
        return if (units == 0) 0 else (units - 1) / utf16_index_stride + 1;
    }

    fn create(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        units: usize,
        previous_owner: ?*anyopaque,
    ) std.mem.Allocator.Error!*Utf16Index {
        const checkpoints = try allocator.alloc(usize, checkpointCount(units));
        errdefer allocator.free(checkpoints);
        var iterator = Utf16CodeUnitIterator.init(bytes, false);
        var unit_index: usize = 0;
        for (checkpoints, 0..) |*checkpoint, checkpoint_index| {
            const target = checkpoint_index * utf16_index_stride;
            while (unit_index < target) : (unit_index += 1)
                _ = iterator.next() orelse unreachable;
            checkpoint.* = iterator.encodedState();
        }
        const index = try allocator.create(Utf16Index);
        index.* = .{
            .aux_header = .{ .kind = .utf16_index },
            .previous_owner = .init(previous_owner),
            .units = units,
            .checkpoints = checkpoints,
        };
        return index;
    }

    fn destroy(self: *Utf16Index, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.checkpoints));
        allocator.destroy(self);
    }

    fn codeUnitAt(self: *const Utf16Index, bytes: []const u8, index: usize) ?Utf16CodeUnit {
        if (index >= self.units) return null;
        const checkpoint_index = index / utf16_index_stride;
        if (checkpoint_index >= self.checkpoints.len) return null;
        var iterator = Utf16CodeUnitIterator.restore(bytes, self.checkpoints[checkpoint_index]);
        var remaining = index - checkpoint_index * utf16_index_stride;
        while (remaining > 0) : (remaining -= 1) _ = iterator.next() orelse return null;
        return iterator.next();
    }
};

fn staticUtf16Checkpoints(comptime bytes: []const u8) [Utf16Index.checkpointCount(utf16LengthOfWtf8(bytes))]usize {
    comptime {
        var checkpoints: [Utf16Index.checkpointCount(utf16LengthOfWtf8(bytes))]usize = undefined;
        var iterator = Utf16CodeUnitIterator.init(bytes, false);
        var unit_index: usize = 0;
        for (&checkpoints, 0..) |*checkpoint, checkpoint_index| {
            const target = checkpoint_index * utf16_index_stride;
            while (unit_index < target) : (unit_index += 1)
                _ = iterator.next() orelse unreachable;
            checkpoint.* = iterator.encodedState();
        }
        return checkpoints;
    }
}

/// An immutable string cell: a single allocation the engine can point at with
/// one 48-bit word. `bytes` is owned by whoever allocated the cell (the GC heap
/// or an arena); `hash` atomically publishes a deterministic XXH3 cache on
/// first equality and retains managed-cell classification. `aux` atomically
/// publishes typed lifetime/index metadata. Bytes and content classification
/// are immutable after creation; both monotonic publications are thread-safe.
pub const StringCell = struct {
    bytes: []const u8,
    hash: u64,
    /// Null, an ExternalStringOwner, a stable InternStringOwner, or a UTF-16
    /// index that retains the previous owner. Every target starts with
    /// StringAuxKind.
    /// Static cells may point at compile-time index storage; runtime cells
    /// publish a dynamic index with compare-and-swap.
    aux: std.atomic.Value(?*anyopaque) = .init(null),

    /// True only when the cell itself was allocated by zig-gc. Static literals,
    /// arena strings, and intern-table entries remain outside the heap and must
    /// never be handed to the collector's strict `mark` entry point.
    pub fn isGcManaged(self: *const StringCell) bool {
        return self.hashState() & gc_managed_flag != 0;
    }

    pub fn setGcManaged(self: *StringCell, managed: bool) void {
        if (managed) {
            _ = @atomicRmw(u64, &self.hash, .Or, gc_managed_flag, .monotonic);
        } else {
            _ = @atomicRmw(u64, &self.hash, .And, ~gc_managed_flag, .monotonic);
        }
    }

    fn indexFromAux(raw: ?*anyopaque) ?*const Utf16Index {
        const pointer = raw orelse return null;
        return switch (stringAuxKind(pointer)) {
            .utf16_index, .static_utf16_index => blk: {
                const header: *const StringAuxHeader = @ptrCast(pointer);
                const unaligned: *align(1) const Utf16Index = @fieldParentPtr("aux_header", header);
                break :blk @alignCast(unaligned);
            },
            else => null,
        };
    }

    fn priorOwner(raw: ?*anyopaque) ?*anyopaque {
        const index = indexFromAux(raw) orelse return raw;
        return index.previous_owner.load(.acquire);
    }

    /// Original embedder allocation retained by private external-string
    /// constructors. Internal bytes may be canonical WTF-8; this obligation is
    /// released only when the cell dies or its arena Context is destroyed.
    pub fn externalOwner(self: *const StringCell) ?*ExternalStringOwner {
        const owner = priorOwner(self.aux.load(.acquire)) orelse return null;
        if (stringAuxKind(owner) != .external_owner) return null;
        const header: *const StringAuxHeader = @ptrCast(owner);
        const unaligned: *align(1) const ExternalStringOwner = @fieldParentPtr("aux_header", header);
        return @alignCast(@constCast(unaligned));
    }

    pub fn setExternalOwner(self: *StringCell, owner: ?*ExternalStringOwner) void {
        const raw_owner: ?*anyopaque = if (owner) |record| @ptrCast(&record.aux_header) else null;
        const current = self.aux.load(.acquire);
        if (indexFromAux(current)) |index| {
            @constCast(index).previous_owner.store(raw_owner, .release);
            return;
        }
        std.debug.assert(current == null or stringAuxKind(current.?) == .external_owner);
        self.aux.store(raw_owner, .release);
    }

    pub fn eql(self: *const StringCell, other: *const StringCell) bool {
        if (self == other) return true; // interned ⇒ pointer identity is enough
        var self_hash = self.hashState();
        var other_hash = other.hashState();
        if ((self_hash ^ other_hash) & classification_mask != 0 or self.bytes.len != other.bytes.len)
            return false;
        if (self_hash & hash_ready_flag == 0) self_hash = self.ensureContentHash(self_hash);
        if (other_hash & hash_ready_flag == 0) other_hash = other.ensureContentHash(other_hash);
        return (self_hash ^ other_hash) & content_hash_mask == 0 and
            std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn eqlBytes(self: *const StringCell, bytes: []const u8) bool {
        return std.mem.eql(u8, self.bytes, bytes);
    }

    pub inline fn hashState(self: *const StringCell) u64 {
        return @atomicLoad(u64, &@constCast(self).hash, .monotonic);
    }

    pub inline fn hasCachedContentHash(self: *const StringCell) bool {
        return self.hashState() & hash_ready_flag != 0;
    }

    fn ensureContentHash(self: *const StringCell, pending: u64) u64 {
        std.debug.assert(pending & hash_ready_flag == 0);
        // Flat storage changes the byte image, so those cells are deliberately
        // eager in `uninternedHashState` and can never enter this path.
        std.debug.assert(!isFlatLatin1(pending));
        const computed = (pending & persistent_state_mask) | hash_ready_flag |
            (hashBytes(self.bytes) & content_hash_mask);
        return @cmpxchgStrong(
            u64,
            &@constCast(self).hash,
            pending,
            computed,
            .monotonic,
            .monotonic,
        ) orelse computed;
    }

    /// True when every code unit is ASCII (< 0x80), so the WTF-8 bytes are
    /// already a flat 1-byte-per-unit image (`byte offset == UTF-16 index`),
    /// making indexOf/charAt/slice/regexp offset conversions O(1). Cached in
    /// `hash`'s top bit at construction — see `contentHash`.
    pub fn isAscii(self: *const StringCell) bool {
        return self.hashState() & ascii_flag != 0;
    }

    /// True when every UTF-16 code unit is ≤ 0xFF (latin1 / JSC `is8Bit`).
    /// O(1): cached in `hash`'s bit 62 at construction — see `latin1_flag`.
    /// ASCII ⇒ latin1, so this is a superset of `isAscii()`.
    pub fn isLatin1(self: *const StringCell) bool {
        return self.hashState() & latin1_flag != 0;
    }

    /// Exact ECMAScript String length. Ordinary cells read the construction-time
    /// cache; only an embedding input beyond the cache's representable range
    /// takes the exact representation-aware fallback.
    pub fn utf16Len(self: *const StringCell) usize {
        const state = self.hashState();
        const cached = state & utf16_length_mask;
        if (cached != utf16_length_unknown) return @intCast(cached);
        if (indexFromAux(self.aux.load(.acquire))) |index| return index.units;
        if (isFlatLatin1(state)) return self.bytes.len;
        return utf16LengthOfWtf8(self.bytes);
    }

    fn indexAllocator(raw: ?*anyopaque, fallback: std.mem.Allocator) std.mem.Allocator {
        const owner = priorOwner(raw) orelse return fallback;
        if (stringAuxKind(owner) != .intern_owner) return fallback;
        const header: *const StringAuxHeader = @ptrCast(owner);
        const unaligned: *align(1) const InternStringOwner = @fieldParentPtr("aux_header", header);
        const intern_owner: *const InternStringOwner = @alignCast(unaligned);
        return intern_owner.allocator;
    }

    /// Publish one immutable sparse index. A loser frees its complete candidate;
    /// an allocation failure leaves the cell byte-for-byte unchanged. Interned
    /// cells select their table allocator, managed callers pass the realm's
    /// accounted allocator, and arena callers pass their owning arena.
    fn publishUtf16Index(
        self: *const StringCell,
        fallback_allocator: std.mem.Allocator,
        units: usize,
    ) std.mem.Allocator.Error!?*const Utf16Index {
        const state = self.hashState();
        if (state & ascii_flag != 0 or isFlatLatin1(state) or self.bytes.len < utf16_index_min_bytes)
            return null;

        var observed = self.aux.load(.acquire);
        while (true) {
            if (indexFromAux(observed)) |index| return index;
            const allocator = indexAllocator(observed, fallback_allocator);
            const candidate = try Utf16Index.create(allocator, self.bytes, units, observed);
            if (@constCast(self).aux.cmpxchgStrong(observed, @ptrCast(&candidate.aux_header), .release, .acquire)) |actual| {
                candidate.destroy(allocator);
                observed = actual;
                continue;
            }
            return candidate;
        }
    }

    pub fn ensureUtf16Index(
        self: *const StringCell,
        fallback_allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!?*const Utf16Index {
        return self.publishUtf16Index(fallback_allocator, self.utf16Len());
    }

    /// Release dynamic index backing during the cell owner's normal teardown.
    /// Static metadata is part of the executable image and is never freed.
    pub fn deinitUtf16Index(self: *StringCell, allocator: std.mem.Allocator) void {
        const raw = self.aux.load(.acquire);
        const index = indexFromAux(raw) orelse return;
        if (index.aux_header.kind == .static_utf16_index) return;
        const previous = index.previous_owner.load(.acquire);
        self.aux.store(previous, .release);
        @constCast(index).destroy(allocator);
    }

    pub fn hasUtf16Index(self: *const StringCell) bool {
        return indexFromAux(self.aux.load(.acquire)) != null;
    }

    fn linearCodeUnitAt(self: *const StringCell, index: usize) ?Utf16CodeUnit {
        var iterator = Utf16CodeUnitIterator.init(self.bytes, isFlatLatin1(self.hashState()));
        var current: usize = 0;
        while (iterator.next()) |unit| : (current += 1)
            if (current == index) return unit;
        return null;
    }

    /// Exact random UTF-16 read: O(1) for one-byte cells, at most one O(n)
    /// index construction for long WTF-8 cells, then O(stride) per access.
    pub fn codeUnitAt(
        self: *const StringCell,
        allocator: std.mem.Allocator,
        index: usize,
    ) std.mem.Allocator.Error!?Utf16CodeUnit {
        const state = self.hashState();
        if (state & ascii_flag != 0 or isFlatLatin1(state)) {
            if (index >= self.bytes.len) return null;
            return .{ .unit = self.bytes[index] };
        }
        const cached_units: usize = @intCast(state & utf16_length_mask);
        if (cached_units != utf16_length_unknown and index >= cached_units) return null;
        if (indexFromAux(self.aux.load(.acquire))) |sparse| return sparse.codeUnitAt(self.bytes, index);
        if (self.bytes.len >= utf16_index_min_bytes) {
            const exact_units = if (cached_units == utf16_length_unknown)
                utf16LengthOfWtf8(self.bytes)
            else
                cached_units;
            if (index >= exact_units) return null;
            if (try self.publishUtf16Index(allocator, exact_units)) |sparse|
                return sparse.codeUnitAt(self.bytes, index);
        }
        return self.linearCodeUnitAt(index);
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
        const h = contentHash(s);
        // Match the runtime constructors' storage so an internal literal and a
        // computed string of equal content share one representation (and compare
        // equal): a latin1-but-not-ASCII literal is stored flat when the master
        // switch is on.
        const stored = comptimeStored(s, h);
        const needs_index = h & ascii_flag == 0 and !isFlatLatin1(h) and stored.len >= utf16_index_min_bytes;
        const checkpoints = staticUtf16Checkpoints(stored);
        const index = Utf16Index{
            .aux_header = .{ .kind = .static_utf16_index },
            .previous_owner = .init(null),
            .units = utf16LengthOfWtf8(stored),
            .checkpoints = &checkpoints,
        };
        const cell = StringCell{
            .bytes = stored,
            .hash = h,
            .aux = .init(if (needs_index) @ptrCast(@constCast(&index.aux_header)) else null),
        };
    }.cell;
}

/// Compile-time counterpart of `storedImage`: folds a latin1-but-not-ASCII WTF-8
/// literal to its flat latin1 image in a comptime array; ASCII and non-latin1
/// literals (and everything, while `flat_storage_active` is off) are unchanged.
fn comptimeStored(comptime s: []const u8, comptime h: u64) []const u8 {
    if (!isFlatLatin1(h)) return s;
    comptime {
        var units: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (units += 1) i += if (s[i] < 0x80) @as(usize, 1) else 2;
        var buf: [units]u8 = undefined;
        var j: usize = 0;
        i = 0;
        while (i < s.len) : (j += 1) {
            if (s[i] < 0x80) {
                buf[j] = s[i];
                i += 1;
            } else {
                buf[j] = (@as(u8, s[i] & 0x1F) << 6) | (s[i + 1] & 0x3F);
                i += 2;
            }
        }
        const final = buf;
        return &final;
    }
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
/// re-encode `Value.asWtf8` performs for a flat cell whose consumer needs WTF-8.
/// Always allocates (a caller that wants to borrow-when-ASCII checks first).
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

/// Transcode canonical WTF-8 that is KNOWN to be latin1 (every code unit ≤ 0xFF
/// — only ASCII bytes plus 0xC2/0xC3 two-byte sequences, exactly what
/// `latin1_flag` marks) into the flat-latin1 image (1 raw byte per code unit),
/// returning an owned copy. Inverse of `latin1FlatToWtf8`; the **construction**
/// transform that shrinks a latin1-but-not-ASCII string to 1 byte/unit at
/// storage. Caller MUST guarantee latin1 input (asserted in debug).
pub fn wtf8ToLatin1Flat(allocator: std.mem.Allocator, wtf8: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, wtf8.len); // latin1 WTF-8 only shrinks
    var i: usize = 0;
    while (i < wtf8.len) {
        const b = wtf8[i];
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
            i += 1;
        } else {
            std.debug.assert(b == 0xC2 or b == 0xC3);
            out.appendAssumeCapacity((@as(u8, b & 0x1F) << 6) | (wtf8[i + 1] & 0x3F));
            i += 2;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Choose the STORED byte image for canonical WTF-8 `canon` (content hash `h`):
/// the flat-latin1 image when `isFlatLatin1(h)` (latin1-but-not-ASCII AND the
/// `flat_storage_active` master switch is on), otherwise `canon` unchanged.
/// **Takes ownership of `canon`** — the flat path frees it (even on an allocation
/// failure); the WTF-8 path returns it verbatim. The stored image is a
/// deterministic function of content, so equal strings share one image within a
/// representation; cross-representation collisions (a flat latin1 image equal to
/// some non-latin1 WTF-8 image of different content) are separated by the content
/// hash — computed over `canon`, never the stored image — see `StringCell.eql`.
pub fn storedImage(allocator: std.mem.Allocator, canon: []u8, h: u64) std.mem.Allocator.Error![]u8 {
    if (isFlatLatin1(h)) {
        defer allocator.free(canon);
        return wtf8ToLatin1Flat(allocator, canon);
    }
    return canon;
}

/// Debug-only tripwire: a StringCell's stored image must be well-formed WTF-8
/// (UTF-8 extended so a lone surrogate U+D800..U+DFFF is a legal 3-byte `ED xx
/// xx`). Every construction path runs this on the exact bytes it is about to
/// store. Today all cells store WTF-8 so it is always satisfied; its purpose is
/// the flat-string model — when storage becomes representation-dependent, this
/// fires the instant a non-WTF-8 image (e.g. a raw flat-latin1 byte produced by
/// slicing a flat cell and re-wrapping it as WTF-8) reaches a WTF-8 constructor,
/// which is precisely the silent "slice-then-build" corruption that a mixed
/// flat/WTF-8 world otherwise hides. Compiled out entirely in release builds.
pub fn debugAssertWtf8(bytes: []const u8) void {
    if (!std.debug.runtime_safety) return;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const seq_len: usize = if (b < 0x80) 1 else if (b >= 0xC2 and b <= 0xDF)
            2
        else if (b >= 0xE0 and b <= 0xEF)
            3
        else if (b >= 0xF0 and b <= 0xF4)
            4
        else
            std.debug.panic("StringCell: invalid WTF-8 lead byte 0x{x:0>2} at index {d} of {x}", .{ b, i, bytes });
        if (i + seq_len > bytes.len)
            std.debug.panic("StringCell: truncated WTF-8 sequence at index {d} of {x}", .{ i, bytes });
        var k: usize = 1;
        while (k < seq_len) : (k += 1) {
            if (bytes[i + k] & 0xC0 != 0x80)
                std.debug.panic("StringCell: bad WTF-8 continuation 0x{x:0>2} at index {d} of {x}", .{ bytes[i + k], i + k, bytes });
        }
        i += seq_len;
    }
}

fn allAscii(bytes: []const u8) bool {
    for (bytes) |byte| if (byte >= 0x80) return false;
    return true;
}

/// Canonical WTF-8 length of `prefix + middle + suffix`, where both affixes are
/// ASCII and `middle` is either canonical WTF-8 or a physical flat-latin1 image.
/// Keeping this public lets the interpreter enforce its JS string-size ceiling
/// before any backing allocation is attempted.
pub fn asciiAffixedCanonicalLength(prefix: []const u8, middle: []const u8, middle_flat_latin1: bool, suffix: []const u8) std.mem.Allocator.Error!usize {
    std.debug.assert(allAscii(prefix) and allAscii(suffix));
    var middle_len = middle.len;
    if (middle_flat_latin1) {
        for (middle) |byte| {
            if (byte >= 0x80)
                middle_len = std.math.add(usize, middle_len, 1) catch return error.OutOfMemory;
        }
    } else {
        debugAssertWtf8(middle);
    }
    const with_prefix = std.math.add(usize, prefix.len, middle_len) catch return error.OutOfMemory;
    return std.math.add(usize, with_prefix, suffix.len) catch error.OutOfMemory;
}

pub const PreparedAsciiAffixedString = struct {
    stored: []u8,
    hash: u64,
};

/// Materialize an ASCII-affixed String directly in its final physical image.
/// A flat-latin1 middle is encoded into the final canonical destination when
/// canonical storage is active; when flat storage is active, a canonical
/// latin1 middle is decoded directly into the final flat destination. No
/// intermediate transcode buffer exists in either direction.
pub fn prepareAsciiAffixedString(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    middle: []const u8,
    middle_flat_latin1: bool,
    suffix: []const u8,
) std.mem.Allocator.Error!PreparedAsciiAffixedString {
    std.debug.assert(allAscii(prefix) and allAscii(suffix));
    const canonical_len = try asciiAffixedCanonicalLength(prefix, middle, middle_flat_latin1, suffix);
    const classification = if (middle_flat_latin1) blk: {
        var flags = latin1_flag;
        if (allAscii(middle)) flags |= ascii_flag;
        break :blk flags;
    } else classificationBits(middle);
    const store_flat = isFlatLatin1(classification);
    const middle_suffix_len = std.math.add(usize, middle.len, suffix.len) catch return error.OutOfMemory;
    const stored_len = if (store_flat)
        std.math.add(usize, prefix.len, middle_suffix_len) catch return error.OutOfMemory
    else
        canonical_len;
    const stored = try allocator.alloc(u8, stored_len);
    errdefer allocator.free(stored);

    var out: usize = 0;
    @memcpy(stored[out..][0..prefix.len], prefix);
    out += prefix.len;
    const middle_units = if (middle_flat_latin1) middle.len else utf16LengthOfWtf8(middle);
    const utf16_len = std.math.add(usize, prefix.len, middle_units) catch return error.OutOfMemory;
    const final_utf16_len = std.math.add(usize, utf16_len, suffix.len) catch return error.OutOfMemory;
    var hash = classification |
        (if (final_utf16_len < utf16_length_unknown) @as(u64, @intCast(final_utf16_len)) else utf16_length_unknown);
    if (store_flat) {
        var hasher = std.hash.XxHash3.init(0);
        hasher.update(prefix);
        if (middle_flat_latin1) {
            @memcpy(stored[out..][0..middle.len], middle);
            out += middle.len;
            for (middle) |byte| {
                if (byte < 0x80) {
                    const one = [1]u8{byte};
                    hasher.update(&one);
                } else {
                    const encoded = [2]u8{
                        @intCast(0xC0 | (byte >> 6)),
                        @intCast(0x80 | (byte & 0x3F)),
                    };
                    hasher.update(&encoded);
                }
            }
        } else {
            hasher.update(middle);
            var i: usize = 0;
            while (i < middle.len) {
                const byte = middle[i];
                if (byte < 0x80) {
                    stored[out] = byte;
                    out += 1;
                    i += 1;
                } else {
                    std.debug.assert(byte == 0xC2 or byte == 0xC3);
                    stored[out] = (@as(u8, byte & 0x1F) << 6) | (middle[i + 1] & 0x3F);
                    out += 1;
                    i += 2;
                }
            }
        }
        hasher.update(suffix);
        hash |= hash_ready_flag | (hasher.final() & content_hash_mask);
    } else if (middle_flat_latin1) {
        for (middle) |byte| {
            if (byte < 0x80) {
                stored[out] = byte;
                out += 1;
            } else {
                stored[out] = @intCast(0xC0 | (byte >> 6));
                stored[out + 1] = @intCast(0x80 | (byte & 0x3F));
                out += 2;
            }
        }
    } else {
        @memcpy(stored[out..][0..middle.len], middle);
        out += middle.len;
    }
    @memcpy(stored[out..][0..suffix.len], suffix);
    out += suffix.len;
    std.debug.assert(out == stored.len);
    if (!store_flat) debugAssertWtf8(stored);
    return .{ .stored = stored, .hash = hash };
}

pub fn createCellWithAsciiAffixes(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    middle: []const u8,
    middle_flat_latin1: bool,
    suffix: []const u8,
) std.mem.Allocator.Error!*StringCell {
    if (active_managed_factory) |factory|
        return factory.create_ascii_affixes(factory.context, allocator, prefix, middle, middle_flat_latin1, suffix);
    const prepared = try prepareAsciiAffixedString(allocator, prefix, middle, middle_flat_latin1, suffix);
    errdefer allocator.free(prepared.stored);
    const cell = try allocator.create(StringCell);
    cell.* = .{ .bytes = prepared.stored, .hash = prepared.hash };
    return cell;
}

/// Allocate a fresh (un-interned) cell that owns a (surrogate-canonicalized) copy
/// of `bytes`. This is the minimal constructor the NaN-box `Value` representation
/// needs; interning is optional (below). `allocator` owns both the cell and the
/// byte copy.
pub fn createCell(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!*StringCell {
    if (active_managed_factory) |factory|
        return factory.create(factory.context, allocator, bytes);
    const owned = try canonicalizeSurrogates(allocator, bytes);
    debugAssertWtf8(owned); // tripwire on the WTF-8 INPUT (catches a flat byte leaking in)
    const h = uninternedHashState(owned);
    const stored = try storedImage(allocator, owned, h); // consumes owned
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
    const bytes = if (std.mem.indexOfScalar(u8, owned, 0xED) == null) owned else blk: {
        const canonical = try canonicalizeSurrogates(allocator, owned);
        allocator.free(owned);
        owns_original = false;
        break :blk canonical;
    };
    owns_original = false; // ownership of `bytes` passes to storedImage
    debugAssertWtf8(bytes); // tripwire on the WTF-8 INPUT
    const h = uninternedHashState(bytes);
    const stored = try storedImage(allocator, bytes, h); // consumes bytes
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
    create_ascii_affixes: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, bool, []const u8) std.mem.Allocator.Error!*StringCell,
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
const InternPlacementContext = struct {
    seed: u64,

    fn hash(context: @This(), bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(context.seed, bytes);
    }
};

/// Retain one placement word per canonical key so shard selection and native
/// bucket lookup share a single keyed byte scan. Equality still checks bytes.
const InternKey = struct {
    bytes: []const u8,
    placement_hash: u64,
};

const InternStoredContext = struct {
    pub fn hash(_: @This(), key: InternKey) u64 {
        return key.placement_hash;
    }

    pub fn eql(_: @This(), left: InternKey, right: InternKey) bool {
        return std.mem.eql(u8, left.bytes, right.bytes);
    }
};

const InternLookup = struct {
    bytes: []const u8,
    placement_hash: u64,
};

const InternLookupContext = struct {
    pub fn hash(_: @This(), lookup: InternLookup) u64 {
        return lookup.placement_hash;
    }

    pub fn eql(_: @This(), lookup: InternLookup, stored: InternKey) bool {
        return std.mem.eql(u8, lookup.bytes, stored.bytes);
    }
};

const InternMap = std.HashMapUnmanaged(
    InternKey,
    *StringCell,
    InternStoredContext,
    std.hash_map.default_max_load_percentage,
);
const InternPlacementContextProvider = *const fn () std.mem.Allocator.Error!InternPlacementContext;

fn newInternPlacementContext() std.mem.Allocator.Error!InternPlacementContext {
    var seed_bytes: [@sizeOf(u64)]u8 = undefined;
    agent.engineIo().randomSecure(&seed_bytes) catch return error.OutOfMemory;
    return .{ .seed = std.mem.readInt(u64, &seed_bytes, .little) };
}

pub const InternTable = struct {
    pub const shard_count = 16; // power of two; hash low bits pick the shard

    const placement_empty: u8 = 0;
    const placement_initializing: u8 = 1;
    const placement_ready: u8 = 2;

    const Shard = struct {
        lock: std.atomic.Value(u32) = .init(0), // 0 = free, 1 = held
        map: InternMap = .empty,

        fn acquire(self: *Shard) void {
            var spins: usize = 0;
            while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) : (spins += 1) {
                if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
            }
        }
        fn releaseLock(self: *Shard) void {
            self.lock.store(0, .release);
        }
    };

    allocator: std.mem.Allocator,
    string_owner: std.atomic.Value(?*InternStringOwner) = .init(null),
    shards: [shard_count]Shard = @splat(.{}),
    /// `placement_context` is readable only after the release-published ready
    /// state. The initializing owner inserts the first cell before publishing;
    /// waiters cannot observe a map whose context is still provisional.
    placement_state: std.atomic.Value(u8) = .init(placement_empty),
    placement_context: InternPlacementContext = undefined,
    context_provider: InternPlacementContextProvider = newInternPlacementContext,

    pub fn init(allocator: std.mem.Allocator) InternTable {
        return .{ .allocator = allocator };
    }

    fn ensureStringOwner(self: *InternTable) std.mem.Allocator.Error!*InternStringOwner {
        if (self.string_owner.load(.acquire)) |owner| return owner;
        const candidate = try self.allocator.create(InternStringOwner);
        candidate.* = .{ .allocator = self.allocator };
        if (self.string_owner.cmpxchgStrong(null, candidate, .release, .acquire)) |owner| {
            self.allocator.destroy(candidate);
            return owner.?;
        }
        return candidate;
    }

    pub fn deinit(self: *InternTable) void {
        const string_owner = self.string_owner.load(.acquire);
        const string_allocator = if (string_owner) |owner| owner.allocator else self.allocator;
        for (&self.shards) |*shard| {
            var it = shard.map.iterator();
            while (it.next()) |entry| {
                // Key (WTF-8 content) and cell.bytes (stored image, possibly flat
                // latin1) are separate allocations — free both.
                self.allocator.free(entry.key_ptr.bytes);
                entry.value_ptr.*.deinitUtf16Index(string_allocator);
                self.allocator.free(entry.value_ptr.*.bytes);
                self.allocator.destroy(entry.value_ptr.*);
            }
            shard.map.deinit(self.allocator);
        }
        if (string_owner) |owner| owner.allocator.destroy(owner);
        self.string_owner.store(null, .release);
    }

    /// Return the canonical cell for `bytes`, creating + inserting it on first
    /// sight. Repeated calls with equal bytes return the *same* pointer, from
    /// any thread. The returned cell is owned by the table (freed at `deinit`).
    pub fn intern(self: *InternTable, bytes: []const u8) std.mem.Allocator.Error!*StringCell {
        const h = contentHash(bytes);
        var spins: usize = 0;
        while (true) : (spins += 1) switch (self.placement_state.load(.acquire)) {
            placement_ready => return self.internWithContext(bytes, h, self.placement_context),
            placement_empty => if (self.placement_state.cmpxchgStrong(
                placement_empty,
                placement_initializing,
                .acq_rel,
                .acquire,
            ) == null) {
                const context = self.context_provider() catch |err| {
                    self.placement_state.store(placement_empty, .release);
                    return err;
                };
                const cell = self.internWithContext(bytes, h, context) catch |err| {
                    self.resetEmptyShardStorage();
                    self.resetStringOwner();
                    self.placement_state.store(placement_empty, .release);
                    return err;
                };
                self.placement_context = context;
                self.placement_state.store(placement_ready, .release);
                return cell;
            },
            placement_initializing => {
                if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
            },
            else => unreachable,
        };
    }

    fn resetEmptyShardStorage(self: *InternTable) void {
        for (&self.shards) |*shard| {
            shard.acquire();
            defer shard.releaseLock();
            std.debug.assert(shard.map.count() == 0);
            shard.map.deinit(self.allocator);
            shard.map = .empty;
        }
    }

    fn resetStringOwner(self: *InternTable) void {
        if (self.string_owner.swap(null, .acq_rel)) |owner| owner.allocator.destroy(owner);
    }

    fn internWithContext(
        self: *InternTable,
        bytes: []const u8,
        content_hash: u64,
        context: InternPlacementContext,
    ) std.mem.Allocator.Error!*StringCell {
        const placement_hash = context.hash(bytes);
        const lookup = InternLookup{ .bytes = bytes, .placement_hash = placement_hash };
        const shard = &self.shards[placement_hash & (shard_count - 1)];
        shard.acquire();
        defer shard.releaseLock();

        // Look up by the WTF-8 CONTENT `bytes` (not the stored image): a flat
        // latin1 image can collide byte-for-byte with a different string's WTF-8.
        const result = try shard.map.getOrPutContextAdapted(
            self.allocator,
            lookup,
            InternLookupContext{},
            InternStoredContext{},
        );
        if (result.found_existing) return result.value_ptr.*;
        result.key_ptr.* = .{ .bytes = bytes, .placement_hash = placement_hash };
        var inserted = true;
        errdefer if (inserted) std.debug.assert(shard.map.removeAdapted(lookup, InternLookupContext{}));

        // Miss: the map key is an owned copy of the WTF-8 content (collision-free
        // canonical key); the cell stores the representation-selected image
        // (flat latin1 when applicable), a separate allocation.
        debugAssertWtf8(bytes);
        const key = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(key);
        const canon = try self.allocator.dupe(u8, bytes);
        const stored = try storedImage(self.allocator, canon, content_hash); // consumes canon
        errdefer self.allocator.free(stored);
        const string_owner = try self.ensureStringOwner();
        const cell = try self.allocator.create(StringCell);
        errdefer self.allocator.destroy(cell);
        cell.* = .{ .bytes = stored, .hash = content_hash, .aux = .init(@ptrCast(&string_owner.aux_header)) };
        result.key_ptr.bytes = key;
        result.value_ptr.* = cell;
        inserted = false;
        return cell;
    }

    /// Intern a representation-selected cell by its canonical StringData.
    /// Canonical cells borrow their existing WTF-8 bytes. A flat-latin1 cell
    /// needs a temporary canonical key because its physical bytes are not a
    /// valid input to `intern` and can collide with unrelated WTF-8 content.
    pub fn internCell(self: *InternTable, cell: *const StringCell) std.mem.Allocator.Error!*StringCell {
        if (!isFlatLatin1(cell.hashState())) return self.intern(cell.bytes);
        const canonical = try latin1FlatToWtf8(self.allocator, cell.bytes);
        defer self.allocator.free(canonical);
        return self.intern(canonical);
    }

    /// Total interned cells across all shards (test/diagnostic helper).
    pub fn count(self: *InternTable) usize {
        var spins: usize = 0;
        while (self.placement_state.load(.acquire) == placement_initializing) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
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

test "strcell: makeCell allocates from the active arena and hashes on equality" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit(); // frees every cell — no leak
    const prev = setActiveArena(arena_state.allocator());
    defer _ = setActiveArena(prev);

    var buf = [_]u8{ 'a', 'b', 'c' };
    const c = makeCell(&buf); // no allocator argument
    buf[0] = 'Z'; // cell kept its own copy
    try std.testing.expectEqualStrings("abc", c.bytes);
    try std.testing.expect(!c.hasCachedContentHash());
    // Non-interned: two calls with equal bytes yield distinct cells (equality is
    // by bytes, so this is still correct for the NaN-box value).
    const d = makeCell("abc");
    try std.testing.expect(c != d);
    try std.testing.expect(c.eql(d));
    try std.testing.expectEqual(contentHash("abc"), c.hashState());
    try std.testing.expectEqual(contentHash("abc"), d.hashState());
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

test "strcell: createCell owns its bytes and defers the content hash" {
    const a = std.testing.allocator;
    var src = [_]u8{ 'h', 'i' };
    const cell = try createCell(a, &src);
    defer {
        a.free(cell.bytes);
        a.destroy(cell);
    }
    src[0] = 'X'; // mutate the source: the cell kept its own copy
    try std.testing.expectEqualStrings("hi", cell.bytes);
    try std.testing.expect(!cell.hasCachedContentHash());
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
    try std.testing.expectEqual(contentHash("undefined"), a.hashState());
    // Its hash matches what the runtime intern path would compute for the same
    // bytes, so a literal cell and an interned cell of equal content agree on
    // hash (equality stays by-bytes; only identity differs across the boundary).
    try std.testing.expectEqual(contentHash("null"), c.hashState());
}

test "strcell: classification is eager and flat content hash preserves canonical identity" {
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
    // Canonical "café" occupies five WTF-8 bytes; its production cell owns
    // four physical bytes, exactly one per UTF-16 code unit.
    try std.testing.expectEqual(@as(usize, 5), "caf\xc3\xa9".len);
    try std.testing.expectEqualStrings("caf\xe9", latin1.bytes);
    try std.testing.expect(!ascii.hasCachedContentHash());
    // Flat storage cannot derive the canonical content hash from its physical
    // byte image, so constructors publish the hash before discarding that form.
    try std.testing.expect(latin1.hasCachedContentHash());
    try std.testing.expect(ascii.eql(staticCell("hello world")));
    try std.testing.expect(latin1.eql(staticCell("caf\xc3\xa9")));
    try std.testing.expectEqual(hashBytes("hello world") & content_hash_mask, ascii.hashState() & content_hash_mask);
    try std.testing.expectEqual(hashBytes("caf\xc3\xa9") & content_hash_mask, latin1.hashState() & content_hash_mask);
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

test "strcell: construction caches exact UTF-16 length across representations" {
    const a = std.testing.allocator;
    const Case = struct { bytes: []const u8, units: usize };
    const cases = [_]Case{
        .{ .bytes = "", .units = 0 },
        .{ .bytes = "ascii", .units = 5 },
        .{ .bytes = "caf\xc3\xa9", .units = 4 },
        .{ .bytes = "\xe6\xb0\xb4\xce\xa9", .units = 2 },
        .{ .bytes = "\xf0\x9f\x98\x80", .units = 2 },
        .{ .bytes = "\xed\xa0\x80x", .units = 2 },
        .{ .bytes = "A\xc3\xa9\xe6\xb0\xb4\xf0\x9f\x98\x80\xed\xa0\x80x", .units = 7 },
    };
    for (cases) |case| {
        const cell = try createCell(a, case.bytes);
        defer {
            a.free(cell.bytes);
            a.destroy(cell);
        }
        try std.testing.expectEqual(case.units, utf16LengthOfWtf8(case.bytes));
        try std.testing.expectEqual(case.units, cell.utf16Len());
        try std.testing.expectEqual(@as(u64, @intCast(case.units)), cell.hashState() & utf16_length_mask);
        _ = cell.eql(staticCell("different"));
        try std.testing.expectEqual(case.units, cell.utf16Len());
    }
}

test "strcell: static and runtime states converge and hash collisions stay exact" {
    const a = std.testing.allocator;
    const Case = struct { bytes: []const u8, static: *const StringCell };
    const cases = [_]Case{
        .{ .bytes = "ascii", .static = staticCell("ascii") },
        .{ .bytes = "caf\xc3\xa9", .static = staticCell("caf\xc3\xa9") },
        .{ .bytes = "\xc4\x80", .static = staticCell("\xc4\x80") },
        .{ .bytes = "\xf0\x9f\x98\x80", .static = staticCell("\xf0\x9f\x98\x80") },
        .{ .bytes = "\xed\xa0\x80", .static = staticCell("\xed\xa0\x80") },
    };
    for (cases) |case| {
        const runtime = try createCell(a, case.bytes);
        defer {
            a.free(runtime.bytes);
            a.destroy(runtime);
        }
        try std.testing.expect(case.static.hasCachedContentHash());
        try std.testing.expectEqual(isFlatLatin1(runtime.hashState()), runtime.hasCachedContentHash());
        try std.testing.expectEqual(case.static.isAscii(), runtime.isAscii());
        try std.testing.expectEqual(case.static.isLatin1(), runtime.isLatin1());
        try std.testing.expect(case.static.eql(runtime));
        try std.testing.expectEqual(case.static.hashState(), runtime.hashState());
    }

    const collision_hash = contentHash("first");
    const first = StringCell{ .bytes = "first", .hash = collision_hash };
    const second = StringCell{ .bytes = "other", .hash = collision_hash };
    try std.testing.expect(!first.eql(&second));
}

test "strcell: length and classification mismatches reject without hashing" {
    const a = std.testing.allocator;
    const short = try createCell(a, "a");
    defer {
        a.free(short.bytes);
        a.destroy(short);
    }
    const long = try createCell(a, "longer");
    defer {
        a.free(long.bytes);
        a.destroy(long);
    }
    const ascii = try createCell(a, "aa");
    defer {
        a.free(ascii.bytes);
        a.destroy(ascii);
    }
    const wide = try createCell(a, "\xc4\x80");
    defer {
        a.free(wide.bytes);
        a.destroy(wide);
    }

    try std.testing.expect(!short.eql(long));
    try std.testing.expect(!ascii.eql(wide));
    try std.testing.expect(!short.hasCachedContentHash());
    try std.testing.expect(!long.hasCachedContentHash());
    try std.testing.expect(!ascii.hasCachedContentHash());
    try std.testing.expect(!wide.hasCachedContentHash());
}

test "strcell: concurrent first equality publishes one deterministic hash state" {
    const a = std.testing.allocator;
    const left = try createCell(a, "shared runtime string whose first hash is raced");
    defer {
        a.free(left.bytes);
        a.destroy(left);
    }
    const right = try createCell(a, "shared runtime string whose first hash is raced");
    defer {
        a.free(right.bytes);
        a.destroy(right);
    }
    try std.testing.expect(!left.hasCachedContentHash());
    try std.testing.expect(!right.hasCachedContentHash());

    const Worker = struct {
        fn run(a_cell: *const StringCell, b_cell: *const StringCell) void {
            var iteration: usize = 0;
            while (iteration < 1_000) : (iteration += 1)
                std.debug.assert(a_cell.eql(b_cell));
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ left, right });
    for (threads) |thread| thread.join();

    const expected = contentHash(left.bytes);
    try std.testing.expectEqual(expected, left.hashState());
    try std.testing.expectEqual(expected, right.hashState());
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

test "strcell: intern placement is lazy independent exact and distributed" {
    const Sequence = struct {
        var calls: std.atomic.Value(u64) = .init(0);

        fn context() std.mem.Allocator.Error!InternPlacementContext {
            return .{ .seed = 0x494e_5445_524e_0000 + calls.fetchAdd(1, .monotonic) };
        }
    };
    Sequence.calls.store(0, .monotonic);

    var first = InternTable.init(std.testing.allocator);
    defer first.deinit();
    first.context_provider = Sequence.context;
    var second = InternTable.init(std.testing.allocator);
    defer second.deinit();
    second.context_provider = Sequence.context;

    try std.testing.expectEqual(@as(usize, 0), first.count());
    try std.testing.expectEqual(InternTable.placement_empty, first.placement_state.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), Sequence.calls.load(.monotonic));

    const first_cell = try first.intern("\x00shared-\xf0\x9f\x99\x82");
    const first_duplicate = try first.intern("\x00shared-\xf0\x9f\x99\x82");
    var hit_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const allocation_free_duplicate = duplicate: {
        first.allocator = hit_allocator.allocator();
        defer first.allocator = std.testing.allocator;
        break :duplicate try first.intern("\x00shared-\xf0\x9f\x99\x82");
    };
    const second_cell = try second.intern("\x00shared-\xf0\x9f\x99\x82");
    try std.testing.expectEqual(first_cell, first_duplicate);
    try std.testing.expectEqual(first_cell, allocation_free_duplicate);
    try std.testing.expectEqual(@as(usize, 0), hit_allocator.allocations);
    try std.testing.expect(first_cell != second_cell);
    try std.testing.expectEqual(first_cell.hashState(), second_cell.hashState());
    try std.testing.expect(first.placement_context.seed != second.placement_context.seed);
    try std.testing.expectEqual(@as(u64, 2), Sequence.calls.load(.monotonic));

    var wide: [4096]u8 = @splat('w');
    const wide_cell = try first.intern(&wide);
    wide[0] = 'x';
    try std.testing.expectEqual(@as(u8, 'w'), wide_cell.bytes[0]);
    try std.testing.expectEqual(@as(usize, 2), first.count());

    for (&first.shards, 0..) |*shard, shard_index| {
        var iterator = shard.map.iterator();
        while (iterator.next()) |entry| {
            const expected = first.placement_context.hash(entry.key_ptr.bytes);
            try std.testing.expectEqual(expected, entry.key_ptr.placement_hash);
            try std.testing.expectEqual(shard_index, expected & (InternTable.shard_count - 1));
        }
    }

    const adversarial_context = InternPlacementContext{ .seed = 0x4449_5354_5249_4255 };
    var secure_shards: [InternTable.shard_count]usize = @splat(0);
    var collision_count: usize = 0;
    var candidate: usize = 0;
    while (collision_count < 128) : (candidate += 1) {
        var storage: [48]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&storage, "deterministic-shard-collision-{d}", .{candidate});
        // Collide four retained XXH3 bits, not the low UTF-16-length cache.
        // Keyed placement must still distribute attacker-selected content-hash
        // collisions independently across the secure shards.
        if ((contentHash(bytes) >> utf16_length_bits) & (InternTable.shard_count - 1) != 0) continue;
        secure_shards[adversarial_context.hash(bytes) & (InternTable.shard_count - 1)] += 1;
        collision_count += 1;
    }
    var occupied: usize = 0;
    for (secure_shards) |count_| occupied += @intFromBool(count_ != 0);
    try std.testing.expect(occupied >= 12);
}

test "strcell: intern first insertion failures are atomic and retryable" {
    const Providers = struct {
        fn unavailable() std.mem.Allocator.Error!InternPlacementContext {
            return error.OutOfMemory;
        }
        fn fixed() std.mem.Allocator.Error!InternPlacementContext {
            return .{ .seed = 0x4641_494c_5552_4501 };
        }
    };

    var unavailable = InternTable.init(std.testing.allocator);
    defer unavailable.deinit();
    unavailable.context_provider = Providers.unavailable;
    try std.testing.expectError(error.OutOfMemory, unavailable.intern("first"));
    try std.testing.expectEqual(InternTable.placement_empty, unavailable.placement_state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), unavailable.count());
    for (&unavailable.shards) |*shard| try std.testing.expectEqual(@as(usize, 0), shard.map.capacity());
    unavailable.context_provider = Providers.fixed;
    try std.testing.expectEqualStrings("first", (try unavailable.intern("first")).bytes);

    var induced_failures: usize = 0;
    var reached_success = false;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var table = InternTable.init(failing.allocator());
        table.context_provider = Providers.fixed;
        const outcome = table.intern("\x00first-\xf0\x9f\x99\x82");
        if (outcome) |cell| {
            try std.testing.expectEqualStrings("\x00first-\xf0\x9f\x99\x82", cell.bytes);
            reached_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            induced_failures += 1;
            try std.testing.expectEqual(InternTable.placement_empty, table.placement_state.load(.acquire));
            try std.testing.expectEqual(@as(usize, 0), table.count());
            for (&table.shards) |*shard| try std.testing.expectEqual(@as(usize, 0), shard.map.capacity());
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            table.allocator = std.testing.allocator;
            try std.testing.expectEqualStrings("\x00first-\xf0\x9f\x99\x82", (try table.intern("\x00first-\xf0\x9f\x99\x82")).bytes);
        }
        table.deinit();
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (reached_success) break;
    }
    try std.testing.expect(reached_success);
    try std.testing.expect(induced_failures >= 4);
}

test "strcell: concurrent interning converges to one cell per string" {
    const a = std.testing.allocator;
    var t = InternTable.init(a);
    defer t.deinit();

    const Provider = struct {
        var calls: std.atomic.Value(usize) = .init(0);

        fn context() std.mem.Allocator.Error!InternPlacementContext {
            _ = calls.fetchAdd(1, .monotonic);
            return .{ .seed = 0x434f_4e43_5552_0001 };
        }
    };
    Provider.calls.store(0, .monotonic);
    t.context_provider = Provider.context;

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
    try std.testing.expectEqual(@as(usize, 1), Provider.calls.load(.monotonic));
    try std.testing.expectEqual(InternTable.placement_ready, t.placement_state.load(.acquire));
    // Every thread saw the SAME canonical cell for each word.
    for (0..words.len) |wi| {
        const canonical = results[0][wi];
        for (1..n_threads) |ti| try std.testing.expectEqual(canonical, results[ti][wi]);
        try std.testing.expect(canonical.eqlBytes(words[wi]));
    }
}

test "strcell: ASCII affixes materialize one final backing image" {
    const canonical = "[object caf\xC3\xA9]";
    const middle = if (flat_storage_active) "caf\xE9" else "caf\xC3\xA9";
    var measured: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const allocator = measured.allocator();
    const cell = try createCellWithAsciiAffixes(allocator, "[object ", middle, flat_storage_active, "]");
    defer {
        allocator.free(@constCast(cell.bytes));
        allocator.destroy(cell);
    }
    // Exactly one byte backing plus the StringCell itself; no conversion
    // scratch allocation appears in either storage mode.
    try std.testing.expectEqual(@as(usize, 2), measured.allocations);
    if (flat_storage_active) {
        try std.testing.expectEqualStrings("[object caf\xE9]", cell.bytes);
        try std.testing.expectEqual(contentHash(canonical), cell.hashState());
    } else {
        try std.testing.expectEqualStrings(canonical, cell.bytes);
        try std.testing.expectEqual(uninternedHashState(canonical), cell.hashState());
    }

    var fail_backing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        createCellWithAsciiAffixes(fail_backing.allocator(), "[object ", middle, flat_storage_active, "]"),
    );
    try std.testing.expect(fail_backing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), fail_backing.allocations);
    try std.testing.expectEqual(@as(usize, 0), fail_backing.deallocations);

    var fail_cell: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        createCellWithAsciiAffixes(fail_cell.allocator(), "[object ", middle, flat_storage_active, "]"),
    );
    try std.testing.expect(fail_cell.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), fail_cell.allocations);
    try std.testing.expectEqual(@as(usize, 1), fail_cell.deallocations);
    try std.testing.expectEqual(fail_cell.allocated_bytes, fail_cell.freed_bytes);
}

fn repeatedTestBytes(comptime pattern: []const u8, comptime count: usize) [pattern.len * count]u8 {
    var result: [pattern.len * count]u8 = undefined;
    for (0..count) |index|
        @memcpy(result[index * pattern.len ..][0..pattern.len], pattern);
    return result;
}

test "strcell: UTF-16 stride index is exact across representation boundaries" {
    const a = std.testing.allocator;
    const pattern = "A\xc3\xa9\xe6\xb0\xb4\xf0\x9f\x98\x80\xed\xa0\x80x";
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(a);
    for (0..40) |_| try source.appendSlice(a, pattern);
    const cell = try createCell(a, source.items);
    defer {
        cell.deinitUtf16Index(a);
        a.free(cell.bytes);
        a.destroy(cell);
    }

    // Exercise the oversized-embedding sentinel without allocating a giant
    // fixture: an out-of-bounds probe stays allocation-free, while the first
    // in-bounds read publishes the exact length alongside the checkpoints.
    const exact_units = utf16LengthOfWtf8(cell.bytes);
    @atomicStore(u64, &cell.hash, (cell.hashState() & ~utf16_length_mask) | utf16_length_unknown, .monotonic);
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expect((try cell.codeUnitAt(unavailable.allocator(), exact_units)) == null);
    try std.testing.expectEqual(@as(usize, 0), unavailable.allocations);
    try std.testing.expect(cell.aux.load(.acquire) == null);
    var expected = Utf16CodeUnitIterator.init(cell.bytes, false);
    var unit_index: usize = 0;
    while (expected.next()) |unit| : (unit_index += 1) {
        const actual = (try cell.codeUnitAt(a, unit_index)).?;
        try std.testing.expectEqual(unit.unit, actual.unit);
        try std.testing.expectEqual(unit.astral, actual.astral);
    }
    try std.testing.expectEqual(exact_units, unit_index);
    try std.testing.expectEqual(exact_units, cell.utf16Len());
    const raw_index = cell.aux.load(.acquire).?;
    try std.testing.expectEqual(StringAuxKind.utf16_index, stringAuxKind(raw_index));
    const sparse = StringCell.indexFromAux(raw_index).?;
    try std.testing.expectEqual(Utf16Index.checkpointCount(unit_index), sparse.checkpoints.len);
    try std.testing.expect((try cell.codeUnitAt(a, unit_index)) == null);
}

test "strcell: UTF-16 index allocation failures leave the cell unchanged" {
    const a = std.testing.allocator;
    const pattern = "\xe6\xb0\xb4\xf0\x9f\x98\x80\xed\xa0\x80";
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(a);
    for (0..40) |_| try source.appendSlice(a, pattern);
    const cell = try createCell(a, source.items);
    defer {
        cell.deinitUtf16Index(a);
        a.free(cell.bytes);
        a.destroy(cell);
    }

    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, cell.codeUnitAt(failing.allocator(), 100));
        try std.testing.expect(cell.aux.load(.acquire) == null);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect((try cell.codeUnitAt(a, 100)) != null);
}

test "strcell: concurrent UTF-16 index publication retains one complete winner" {
    const a = std.testing.allocator;
    const pattern = "\xf0\x9f\x98\x80\xe6\xb0\xb4\xed\xa0\x80x";
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(a);
    for (0..64) |_| try source.appendSlice(a, pattern);
    const cell = try createCell(a, source.items);
    defer {
        cell.deinitUtf16Index(a);
        a.free(cell.bytes);
        a.destroy(cell);
    }

    const Worker = struct {
        fn run(target: *const StringCell, allocator: std.mem.Allocator, seed: usize) void {
            for (0..200) |iteration| {
                const index = (seed * 31 + iteration * 17) % target.utf16Len();
                std.debug.assert((target.codeUnitAt(allocator, index) catch unreachable) != null);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, index|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ cell, a, index });
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(StringAuxKind.utf16_index, stringAuxKind(cell.aux.load(.acquire).?));
}

test "strcell: interned UTF-16 index uses its stable owner allocator" {
    const a = std.testing.allocator;
    var table = InternTable.init(a);
    defer table.deinit();
    const source = repeatedTestBytes("\xe6\xb0\xb4\xf0\x9f\x98\x80", 32);
    const cell = try table.intern(&source);
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expect((try cell.codeUnitAt(unavailable.allocator(), 70)) != null);
    try std.testing.expectEqual(@as(usize, 0), unavailable.allocations);
    try std.testing.expectEqual(StringAuxKind.utf16_index, stringAuxKind(cell.aux.load(.acquire).?));
}

test "strcell: UTF-16 index preserves external ownership until release" {
    const Callback = struct {
        fn run(_: ?*anyopaque, _: ?*anyopaque, _: usize) callconv(.c) void {}
    };
    const a = std.testing.allocator;
    const source = repeatedTestBytes("\xe6\xb0\xb4\xf0\x9f\x98\x80", 32);
    const cell = try createCell(a, &source);
    defer {
        cell.deinitUtf16Index(a);
        a.free(cell.bytes);
        a.destroy(cell);
    }
    var owner = ExternalStringOwner{
        .pointer = null,
        .len = source.len,
        .context = null,
        .deallocator = Callback.run,
    };
    cell.setExternalOwner(&owner);
    try std.testing.expectEqual(&owner, cell.externalOwner().?);
    try std.testing.expect((try cell.codeUnitAt(a, 70)) != null);
    try std.testing.expect(cell.hasUtf16Index());
    try std.testing.expectEqual(&owner, cell.externalOwner().?);
    cell.setExternalOwner(null);
    try std.testing.expect(cell.externalOwner() == null);
}

test "strcell: static UTF-16 index is allocation free" {
    const source = comptime repeatedTestBytes("\xe6\xb0\xb4\xf0\x9f\x98\x80", 32);
    const cell = staticCell(&source);
    try std.testing.expectEqual(StringAuxKind.static_utf16_index, stringAuxKind(cell.aux.load(.acquire).?));
    var unavailable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect((try cell.codeUnitAt(unavailable.allocator(), 70)) != null);
    try std.testing.expectEqual(@as(usize, 0), unavailable.allocations);
}

test "strcell: StringCell stays a compact NaN-box payload target" {
    // A NaN-boxed string remains one pointer. The target carries {ptr,len}, a
    // cached hash, and immutable ownership classification for strict GC marks.
    try std.testing.expect(@sizeOf(StringCell) >= 2 * @sizeOf(usize) + @sizeOf(u64) + 1);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(StringCell));
}
