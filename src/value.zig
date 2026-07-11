const std = @import("std");
const Shape = @import("shape.zig").Shape;
const SharedBufferStorage = @import("shared_buffer.zig").SharedBufferStorage;
const gc_runtime = @import("gc_runtime.zig");
const strcell = @import("strcell.zig");
const StringCell = strcell.StringCell;

/// GC insertion barrier for a `Value` stored into a live cell. It records an
/// old-to-young edge for minor collection and shades the child during an active
/// incremental/full mark. Only `.object` carries a cell.
inline fn gcBarrier(owner: *Object, v: Value) void {
    if (v.isObject()) gc_runtime.barrierFrom(@ptrCast(owner), @ptrCast(v.asObj()));
}

/// The C-ABI shape of a host (Zig/C) function exposed to JS via
/// `JSObjectMakeFunctionWithCallback`. Kept here so both the interpreter and
/// the C-API layer agree on the type. All ref args are word-sized opaque
/// pointers (JSValueRef / JSObjectRef / JSContextRef in JSC terms).
pub const HostCallback = *const fn (
    ctx: ?*anyopaque,
    function: ?*anyopaque,
    this_object: ?*anyopaque,
    argument_count: usize,
    arguments: [*c]const ?*anyopaque,
    exception: [*c]?*anyopaque,
) callconv(.c) ?*anyopaque;

/// Error set a native builtin may return (mirrors the interpreter's EvalError;
/// error values are global by name, so they coerce). `OptShortCircuit` is an
/// internal control-flow signal natives never actually produce, included only
/// so the sets unify.
pub const HostError = error{ OutOfMemory, Throw, OptShortCircuit };

/// A Zig-native function exposed to JS. Unlike `HostCallback` (the C-ABI JSC
/// shape used across the FFI boundary), this is the in-process hook the
/// interpreter calls directly: `ctx` is the `*Interpreter` (type-erased to
/// avoid an import cycle; cast it back), `this` is the receiver, and the native
/// may allocate via the interpreter's arena and raise JS exceptions. Used for
/// engine builtins and the conformance harness's `assert`.
pub const NativeFn = *const fn (ctx: *anyopaque, this: Value, args: []const Value) HostError!Value;

/// The element type of a typed array (no BigInt variants — those need a BigInt
/// value type). Each carries its byte width and how to read/write a value.
pub const TAKind = enum {
    i8,
    u8,
    u8c, // Uint8ClampedArray
    i16,
    u16,
    i32,
    u32,
    f16,
    f32,
    f64,
    i64, // BigInt64Array  (elements are BigInt)
    u64, // BigUint64Array (elements are BigInt)

    pub fn byteSize(self: TAKind) usize {
        return switch (self) {
            .i8, .u8, .u8c => 1,
            .i16, .u16, .f16 => 2,
            .i32, .u32, .f32 => 4,
            .f64, .i64, .u64 => 8,
        };
    }

    /// The constructor/`Symbol.toStringTag` name (`"Int8Array"`, …).
    pub fn ctorName(self: TAKind) []const u8 {
        return switch (self) {
            .i8 => "Int8Array",
            .u8 => "Uint8Array",
            .u8c => "Uint8ClampedArray",
            .i16 => "Int16Array",
            .u16 => "Uint16Array",
            .i32 => "Int32Array",
            .u32 => "Uint32Array",
            .f16 => "Float16Array",
            .f32 => "Float32Array",
            .f64 => "Float64Array",
            .i64 => "BigInt64Array",
            .u64 => "BigUint64Array",
        };
    }

    /// Whether the element type is BigInt (BigInt64Array / BigUint64Array): such
    /// arrays read/write BigInt values rather than Numbers.
    pub fn isBigInt(self: TAKind) bool {
        return self == .i64 or self == .u64;
    }

    pub fn fromName(name: []const u8) ?TAKind {
        inline for (.{ .i8, .u8, .u8c, .i16, .u16, .i32, .u32, .f16, .f32, .f64, .i64, .u64 }) |k| {
            if (std.mem.eql(u8, name, (@as(TAKind, k)).ctorName())) return k;
        }
        return null;
    }
};

/// An `ArrayBuffer`'s backing bytes. `detached` is set by `$262.detachArrayBuffer`
/// / transfer; a detached buffer's views read undefined / throw on length checks.
pub const ArrayBufferData = struct {
    lock: std.atomic.Mutex = .unlocked,
    /// Seqlock counter for `local_data` swaps in `resize` (see `bytes`). Even =
    /// stable, odd = swap in progress.
    resize_seq: std.atomic.Value(u32) = .init(0),
    /// Backing bytes of a NON-shared buffer. Arena contexts keep these in the
    /// realm arena; GC contexts allocate them from the context backing
    /// allocator so object finalization can release them on collection. Empty
    /// and unused when `shared` is set — a SharedArrayBuffer's bytes live in
    /// process-wide refcounted storage so they can outlive this realm and be
    /// seen by other agents. Always read the live bytes through `bytes()`,
    /// never this field directly.
    local_data: []u8,
    /// Non-null iff `is_shared`: the cross-agent backing storage. The wrapper
    /// holds one reference, tracked in the owning realm's `RetainList`.
    shared: ?*SharedBufferStorage = null,
    /// Metadata and `local_data` are owned by the GC finalizer rather than the
    /// arena. Shared buffers set this for the metadata only; their bytes are
    /// owned by `SharedBufferStorage`.
    gc_owned: bool = false,
    detached_flag: std.atomic.Value(bool) = .init(false),
    /// For a resizable ArrayBuffer (or growable SharedArrayBuffer), the maximum
    /// byte length; null means fixed-length (not resizable/growable).
    max_byte_length: ?usize = null,
    /// A SharedArrayBuffer (never detaches; `grow` only increases length).
    is_shared: bool = false,
    /// An immutable ArrayBuffer (from `transferToImmutable`/`sliceToImmutable`):
    /// fixed-length, never detaches, and rejects every write.
    immutable: bool = false,

    /// The buffer's live bytes: the shared storage's published slice for a
    /// SharedArrayBuffer (always current, even after another realm grows it),
    /// the arena bytes otherwise.
    /// A resize swaps `local_data` (ptr+len) under `lockBuffer`; an unlocked
    /// reader here could otherwise read a torn ptr/len (→ OOB). Under parallel
    /// mode, read it through a seqlock against `resize_seq` (bumped odd→even
    /// around the swap in `arrayBufferResize`). Default engine: the gate is off,
    /// so this stays a single field load. Callers that already hold `lockBuffer`
    /// (the Atomics paths) see a stable `resize_seq` and return on the first try —
    /// no re-entrancy, no deadlock.
    pub inline fn bytes(self: *const ArrayBufferData) []u8 {
        if (self.shared) |s| return s.slice();
        if (!Object.element_locks_enabled.load(.monotonic)) return self.local_data;
        // Seqlock read: ptr+len accessed with relaxed atomics (a plain mov each,
        // so even a retried read is a non-racing atomic access — TSan-clean), and
        // the seqcount makes the pair consistent across a concurrent resize swap.
        const ld = &@constCast(self).local_data;
        const sc = &@constCast(self).resize_seq;
        while (true) {
            const s1 = sc.load(.acquire);
            if ((s1 & 1) != 0) { // writer mid-swap
                std.atomic.spinLoopHint();
                continue;
            }
            const p = @atomicLoad([*]u8, &ld.ptr, .monotonic);
            const l = @atomicLoad(usize, &ld.len, .monotonic);
            // Re-read the seqcount with a no-op acq_rel RMW (Zig has no standalone
            // fence): its release ordering keeps the ptr/len loads from being
            // reordered past it, so a torn pair can't slip through the check.
            if (sc.fetchAdd(0, .acq_rel) == s1) return p[0..l];
            std.atomic.spinLoopHint();
        }
    }

    /// Swap `local_data` to `fresh` as a seqlock writer: odd during the swap,
    /// even after; ptr/len stored with relaxed atomics to pair with `bytes()`.
    /// Caller holds `lockBuffer` (writers serialized).
    pub fn swapLocalData(self: *ArrayBufferData, fresh: []u8) void {
        _ = self.resize_seq.fetchAdd(1, .acq_rel); // → odd
        @atomicStore([*]u8, &self.local_data.ptr, fresh.ptr, .monotonic);
        @atomicStore(usize, &self.local_data.len, fresh.len, .monotonic);
        _ = self.resize_seq.fetchAdd(1, .release); // → even
    }

    /// The detach flag, accessed atomically: a peer thread can `transfer`/detach
    /// a (non-shared) buffer while another reads it (no-GIL). A single bool is one
    /// byte, so `.monotonic` is a plain load/store — it just marks the access
    /// synchronized for ThreadSanitizer.
    pub inline fn isDetached(self: *const ArrayBufferData) bool {
        return @constCast(self).detached_flag.load(.monotonic);
    }
    pub inline fn setDetached(self: *ArrayBufferData, v: bool) void {
        self.detached_flag.store(v, .monotonic);
    }

    pub fn lockBuffer(self: *const ArrayBufferData) void {
        var spins: usize = 0;
        const mutex = &@constCast(self).lock;
        while (!mutex.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlockBuffer(self: *const ArrayBufferData) void {
        @constCast(self).lock.unlock();
    }

    /// Whether a bulk-byte op (a `copyWithin` memmove, etc.) must hold
    /// `lockBuffer` across pointer resolution through `bytes()` and the copy.
    ///
    /// A non-shared buffer's `resize` swaps `local_data` and then FREES the old
    /// backing (interpreter `arrayBufferResizeFn`), so under no-GIL a peer
    /// resizing mid-copy can pull the base out from under an in-flight memmove —
    /// a use-after-free / torn copy. Locking serializes against the swap+free
    /// exactly as `taRead`/`taWrite` do. Shared buffers never take it (storage is
    /// page-reserved to the max and never freed on grow; the per-wrapper mutex
    /// gives no cross-agent exclusion regardless), and the gate stays off in the
    /// default single-threaded engine, where there is no concurrent resizer.
    pub inline fn needsElementLock(self: *const ArrayBufferData) bool {
        return !self.is_shared and Object.element_locks_enabled.load(.monotonic);
    }
};

/// Read typed-array element `i` (within bounds, buffer attached) as a Number.
pub fn taRead(ta: *const TypedArrayData, i: usize) Value {
    const buf = ta.buffer.array_buffer.?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    // A resizable buffer may have shrunk below the view's cached length; reading
    // out of bounds returns 0 rather than a panic.
    if (off + ta.kind.byteSize() > bytes.len) return Value.num(0);
    const n: f64 = switch (ta.kind) {
        .i8 => @floatFromInt(@as(i8, @bitCast(bytes[off]))),
        .u8, .u8c => @floatFromInt(bytes[off]),
        .i16 => @floatFromInt(std.mem.readInt(i16, bytes[off..][0..2], .little)),
        .u16 => @floatFromInt(std.mem.readInt(u16, bytes[off..][0..2], .little)),
        .i32 => @floatFromInt(std.mem.readInt(i32, bytes[off..][0..4], .little)),
        .u32 => @floatFromInt(std.mem.readInt(u32, bytes[off..][0..4], .little)),
        .f16 => @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, bytes[off..][0..2], .little)))),
        .f32 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little)))),
        .f64 => @bitCast(std.mem.readInt(u64, bytes[off..][0..8], .little)),
        // A BigInt element read as a Number is lossy, but keeps the Number-typed
        // method paths crash-free; the interpreter's index get uses `taReadBig`.
        .i64 => @floatFromInt(std.mem.readInt(i64, bytes[off..][0..8], .little)),
        .u64 => @floatFromInt(std.mem.readInt(u64, bytes[off..][0..8], .little)),
    };
    return Value.num(n);
}

/// Read a BigInt typed-array element `i` as an `i128` (the raw 64-bit value,
/// sign-extended for BigInt64Array).
pub fn taReadBig(ta: *const TypedArrayData, i: usize) i128 {
    const buf = ta.buffer.array_buffer.?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + 8 > bytes.len) return 0;
    return switch (ta.kind) {
        .i64 => std.mem.readInt(i64, bytes[off..][0..8], .little),
        .u64 => @as(i128, std.mem.readInt(u64, bytes[off..][0..8], .little)),
        else => 0,
    };
}

/// Write a BigInt typed-array element `i` from an `i128` (the low 64 bits).
pub fn taWriteBig(ta: *const TypedArrayData, i: usize, val: i128) void {
    const buf = ta.buffer.array_buffer.?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + 8 > bytes.len) return;
    const low: u64 = @truncate(@as(u128, @bitCast(val)));
    std.mem.writeInt(u64, bytes[off..][0..8], low, .little);
}

/// ToInt of `num` truncated to a wrapping integer width (NaN/±Inf → 0).
fn taToInt(comptime T: type, num: f64) T {
    if (std.math.isNan(num) or std.math.isInf(num)) return 0;
    const bits = @bitSizeOf(T);
    const two_pow: f64 = std.math.pow(f64, 2, @floatFromInt(bits));
    var m = @mod(@trunc(num), two_pow); // wrap into [0, 2^bits)
    if (m < 0) m += two_pow;
    // For a signed target, map the upper half [2^(bits-1), 2^bits) to negatives.
    if (@typeInfo(T).int.signedness == .signed and m >= two_pow / 2) m -= two_pow;
    return @intFromFloat(m);
}

/// Write Number `num` into typed-array element `i`, coercing to the element type
/// (integer wrap, Uint8Clamped rounding/clamping, float narrowing).
pub fn taWrite(ta: *const TypedArrayData, i: usize, num: f64) void {
    const buf = ta.buffer.array_buffer.?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + ta.kind.byteSize() > bytes.len) return; // shrunk resizable buffer
    switch (ta.kind) {
        .i8 => bytes[off] = @bitCast(taToInt(i8, num)),
        .u8 => bytes[off] = taToInt(u8, num),
        .u8c => {
            // ToUint8Clamp: NaN→0, round-half-to-even, clamp [0,255].
            if (std.math.isNan(num) or num <= 0) {
                bytes[off] = 0;
            } else if (num >= 255) {
                bytes[off] = 255;
            } else {
                const f = @floor(num);
                const rounded: f64 = if (num - f == 0.5)
                    (if (@mod(f, 2) == 0) f else f + 1)
                else
                    @round(num);
                bytes[off] = @intFromFloat(rounded);
            }
        },
        .i16 => std.mem.writeInt(i16, bytes[off..][0..2], taToInt(i16, num), .little),
        .u16 => std.mem.writeInt(u16, bytes[off..][0..2], taToInt(u16, num), .little),
        .i32 => std.mem.writeInt(i32, bytes[off..][0..4], taToInt(i32, num), .little),
        .u32 => std.mem.writeInt(u32, bytes[off..][0..4], taToInt(u32, num), .little),
        .f16 => std.mem.writeInt(u16, bytes[off..][0..2], @bitCast(@as(f16, @floatCast(num))), .little),
        .f32 => std.mem.writeInt(u32, bytes[off..][0..4], @bitCast(@as(f32, @floatCast(num))), .little),
        .f64 => std.mem.writeInt(u64, bytes[off..][0..8], @bitCast(num), .little),
        // A Number written to a BigInt array is only reached via the lossy
        // Number-typed method paths; the index set uses `taWriteBig`.
        .i64 => std.mem.writeInt(i64, bytes[off..][0..8], taToInt(i64, num), .little),
        .u64 => std.mem.writeInt(u64, bytes[off..][0..8], taToInt(u64, num), .little),
    }
}

// ---- Atomic element access (the `Atomics.*` fast paths) -------------------
//
// Each helper performs ONE SeqCst hardware atomic on the element's bytes, so
// racing agents over a SharedArrayBuffer can never tear an element or lose an
// update. Raw bits travel as zero-extended u64 (preserving full 64-bit
// precision for BigInt views, which the f64 route cannot). Alignment is
// guaranteed: element offsets are spec-forced multiples of the element size,
// and buffer allocations are at least 8-byte aligned (shared slabs are
// page-aligned; `makeArrayBuffer` aligns its arena bytes). The byte order
// matches the non-atomic paths' explicit little-endian on every supported
// target. Out-of-bounds (a shrunk resizable buffer) mirrors `taRead`/`taWrite`:
// loads read 0, stores no-op.

/// The element's byte address, or null when the view is out of bounds.
fn taElemPtr(ta: *const TypedArrayData, i: usize) ?[*]u8 {
    const b = ta.buffer.array_buffer.?.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + ta.kind.byteSize() > b.len) return null;
    return b.ptr + off;
}

/// Whether an atomic op on `buf` must hold `lockBuffer` around the WHOLE op
/// (element-pointer resolution through `bytes()` plus the hardware atomic).
///
/// A non-shared ArrayBuffer's `resize` swaps `local_data` and then FREES the old
/// backing (interpreter `arrayBufferResizeFn`), so a peer thread resizing under
/// no-GIL can otherwise pull the base out from under an atomic that already
/// resolved its element pointer — a use-after-free that reads a stale/foreign
/// value. Serializing against the swap+free (exactly as `taRead`/`taWrite` do)
/// closes the window: an atomic holding the lock blocks the resize's swap, and
/// once the resize has swapped every later atomic resolves the fresh base.
///
/// Shared buffers never take this lock: their storage is page-reserved to the
/// maximum and never freed on grow, and each agent holds a distinct wrapper (so
/// this per-wrapper mutex gives no cross-agent exclusion regardless) — the
/// hardware atomic alone orders concurrent agents. The gate also stays off in
/// the default single-threaded engine, where there is no concurrent resizer.
inline fn atomicNeedsLock(buf: *const ArrayBufferData) bool {
    return buf.needsElementLock();
}

/// The element address as a typed pointer (alignment guaranteed, see above).
fn elemAs(comptime T: type, p: [*]u8) *T {
    return @ptrCast(@alignCast(p));
}

/// Sign-aware conversion of raw element bits to a Number (integer kinds only;
/// BigInt/float kinds never take this path).
pub fn taRawToF64(kind: TAKind, raw: u64) f64 {
    return switch (kind) {
        .i8 => @floatFromInt(@as(i8, @bitCast(@as(u8, @truncate(raw))))),
        .u8, .u8c => @floatFromInt(@as(u8, @truncate(raw))),
        .i16 => @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(raw))))),
        .u16 => @floatFromInt(@as(u16, @truncate(raw))),
        .i32 => @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(raw))))),
        .u32 => @floatFromInt(@as(u32, @truncate(raw))),
        else => 0,
    };
}

/// Wrap an integer Number into the element type, as zero-extended raw bits
/// (the atomic-path counterpart of `taToInt` + write).
pub fn taNumToRaw(kind: TAKind, num: f64) u64 {
    return switch (kind) {
        .i8 => @as(u8, @bitCast(taToInt(i8, num))),
        .u8, .u8c => taToInt(u8, num),
        .i16 => @as(u16, @bitCast(taToInt(i16, num))),
        .u16 => taToInt(u16, num),
        .i32 => @as(u32, @bitCast(taToInt(i32, num))),
        .u32 => taToInt(u32, num),
        .i64 => @as(u64, @bitCast(taToInt(i64, num))),
        .u64 => taToInt(u64, num),
        else => 0,
    };
}

pub fn taAtomicLoadRaw(ta: *const TypedArrayData, i: usize) u64 {
    const buf = ta.buffer.array_buffer.?;
    const locked = atomicNeedsLock(buf);
    if (locked) buf.lockBuffer();
    defer {
        if (locked) buf.unlockBuffer();
    }
    const p = taElemPtr(ta, i) orelse return 0;
    return switch (ta.kind.byteSize()) {
        1 => @atomicLoad(u8, elemAs(u8, p), .seq_cst),
        2 => @atomicLoad(u16, elemAs(u16, p), .seq_cst),
        4 => @atomicLoad(u32, elemAs(u32, p), .seq_cst),
        else => @atomicLoad(u64, elemAs(u64, p), .seq_cst),
    };
}

pub fn taAtomicStoreRaw(ta: *const TypedArrayData, i: usize, raw: u64) void {
    const buf = ta.buffer.array_buffer.?;
    const locked = atomicNeedsLock(buf);
    if (locked) buf.lockBuffer();
    defer {
        if (locked) buf.unlockBuffer();
    }
    const p = taElemPtr(ta, i) orelse return;
    switch (ta.kind.byteSize()) {
        1 => @atomicStore(u8, elemAs(u8, p), @truncate(raw), .seq_cst),
        2 => @atomicStore(u16, elemAs(u16, p), @truncate(raw), .seq_cst),
        4 => @atomicStore(u32, elemAs(u32, p), @truncate(raw), .seq_cst),
        else => @atomicStore(u64, elemAs(u64, p), raw, .seq_cst),
    }
}

/// One atomic read-modify-write; returns the previous raw bits. Integer ops
/// wrap modulo the element width, matching the spec's modular arithmetic.
pub fn taAtomicRmwRaw(comptime op: std.builtin.AtomicRmwOp, ta: *const TypedArrayData, i: usize, raw: u64) u64 {
    const buf = ta.buffer.array_buffer.?;
    const locked = atomicNeedsLock(buf);
    if (locked) buf.lockBuffer();
    defer {
        if (locked) buf.unlockBuffer();
    }
    const p = taElemPtr(ta, i) orelse return 0;
    return switch (ta.kind.byteSize()) {
        1 => @atomicRmw(u8, elemAs(u8, p), op, @truncate(raw), .seq_cst),
        2 => @atomicRmw(u16, elemAs(u16, p), op, @truncate(raw), .seq_cst),
        4 => @atomicRmw(u32, elemAs(u32, p), op, @truncate(raw), .seq_cst),
        else => @atomicRmw(u64, elemAs(u64, p), op, raw, .seq_cst),
    };
}

/// One atomic compare-exchange; returns the previous raw bits (== `expected`
/// when the swap happened, per `Atomics.compareExchange` semantics).
pub fn taAtomicCasRaw(ta: *const TypedArrayData, i: usize, expected: u64, replacement: u64) u64 {
    const buf = ta.buffer.array_buffer.?;
    const locked = atomicNeedsLock(buf);
    if (locked) buf.lockBuffer();
    defer {
        if (locked) buf.unlockBuffer();
    }
    const p = taElemPtr(ta, i) orelse return 0;
    switch (ta.kind.byteSize()) {
        1 => {
            const e: u8 = @truncate(expected);
            return @cmpxchgStrong(u8, elemAs(u8, p), e, @truncate(replacement), .seq_cst, .seq_cst) orelse e;
        },
        2 => {
            const e: u16 = @truncate(expected);
            return @cmpxchgStrong(u16, elemAs(u16, p), e, @truncate(replacement), .seq_cst, .seq_cst) orelse e;
        },
        4 => {
            const e: u32 = @truncate(expected);
            return @cmpxchgStrong(u32, elemAs(u32, p), e, @truncate(replacement), .seq_cst, .seq_cst) orelse e;
        },
        else => return @cmpxchgStrong(u64, elemAs(u64, p), expected, replacement, .seq_cst, .seq_cst) orelse expected,
    }
}

/// A typed-array view: `length` elements of `kind`, starting at `byte_offset`
/// into `buffer`'s bytes.
pub const TypedArrayData = struct {
    buffer: *Object,
    byte_offset: usize,
    length: usize,
    kind: TAKind,
    /// A length-tracking view (created without an explicit length on a resizable
    /// ArrayBuffer): its length follows the buffer's current size rather than the
    /// cached `length`.
    track_length: bool = false,

    /// The view's current element length, or null if it is out of bounds (the
    /// backing resizable buffer shrank below it) or detached. A length-tracking
    /// view recomputes from the live buffer size; a fixed view keeps `length`
    /// unless its range no longer fits.
    pub fn currentLength(self: *const TypedArrayData) ?usize {
        const buf = self.buffer.array_buffer orelse return null;
        if (buf.isDetached()) return null;
        const esz = self.kind.byteSize();
        if (self.byte_offset > buf.bytes().len) return null;
        if (self.track_length) return (buf.bytes().len - self.byte_offset) / esz;
        if (self.byte_offset + self.length * esz > buf.bytes().len) return null;
        return self.length;
    }
};

/// A `DataView`: a typed read/write window of `byte_length` bytes starting at
/// `byte_offset` into `buffer`'s bytes, with per-access endianness.
pub const DataViewData = struct {
    buffer: *Object,
    byte_offset: usize,
    byte_length: usize,
    /// A length-tracking DataView (no explicit byteLength on a resizable buffer).
    track_length: bool = false,

    /// The view's current byte length, or null if it is out of bounds (the
    /// resizable buffer shrank below it) or detached.
    pub fn currentByteLength(self: *const DataViewData) ?usize {
        const buf = self.buffer.array_buffer orelse return null;
        if (buf.isDetached()) return null;
        if (self.byte_offset > buf.bytes().len) return null;
        if (self.track_length) return buf.bytes().len - self.byte_offset;
        if (self.byte_offset + self.byte_length > buf.bytes().len) return null;
        return self.byte_length;
    }
};

/// Internal slots for the `Temporal.*` types. One flat record covers every
/// kind (the `kind` tag selects which fields are meaningful), keeping the
/// `Object` footprint to a single pointer.
pub const TemporalData = struct {
    pub const Kind = enum { instant, plain_date, plain_time, plain_date_time, plain_year_month, plain_month_day, duration, zoned_date_time };
    kind: Kind,
    // ISO date components (PlainDate/DateTime/YearMonth/MonthDay/ZonedDateTime).
    year: i32 = 0,
    month: u8 = 1,
    day: u8 = 1,
    // ISO time components (PlainTime/DateTime/ZonedDateTime).
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
    microsecond: u16 = 0,
    nanosecond: u16 = 0,
    // Instant / ZonedDateTime: nanoseconds since the Unix epoch.
    epoch_ns: i128 = 0,
    // ZonedDateTime time zone: its identifier and (for fixed-offset zones) the
    // UTC offset in nanoseconds. IANA-named zones without DST data use offset 0.
    tz_name: []const u8 = "UTC",
    tz_offset_ns: i64 = 0,
    // Duration components (signed, may be fractional only for the smallest set).
    dur: [10]f64 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // years,months,weeks,days,hours,minutes,seconds,ms,us,ns
    // The calendar identifier for a date-bearing value. "iso8601" is the default
    // and the only one whose date arithmetic is the engine's native (proleptic
    // Gregorian) math; other ids (e.g. "gregory") share that math but differ in
    // era/eraYear reflection and the toString `[u-ca=…]` annotation.
    calendar: []const u8 = "iso8601",
};

/// State for a lazy Iterator Helper (the object returned by `map`/`filter`/…).
pub const IterHelper = struct {
    pub const Kind = enum(u8) { map, filter, take, drop, flat_map, wrap, concat, zip, zip_keyed };
    lock: std.atomic.Mutex = .unlocked,
    src: Value, // the underlying iterator (its `.next()` is pulled)
    next_method: Value = Value.undef(), // captured once (GetIteratorDirect); called per step
    kind: Kind,
    func: Value = Value.undef(), // mapper/filterer/flatMapper; or zip_keyed's key array
    counter: f64 = 0, // index argument to the callback
    limit: f64 = 0, // take/drop count; or zip mode (0 shortest, 1 longest, 2 strict)
    inner: ?Value = null, // flat_map's current inner iterator; or zip's per-source done-flag array
    inner_next: Value = Value.undef(), // flat_map inner iterator's captured `next`
    padding: Value = Value.undef(), // zip(longest)'s per-source padding values
    done: bool = false,
    started: bool = false, // drop: the initial skip has run
    is_async: bool = false, // AsyncIterator helper: `next` returns a promise
    running: bool = false, // GeneratorValidate: a re-entrant next() is a TypeError

    pub fn lockState(self: *IterHelper) void {
        var spins: usize = 0;
        while (!self.lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }

    pub fn unlockState(self: *IterHelper) void {
        self.lock.unlock();
    }
};

pub const WeakCollectionEntry = struct {
    key: ?*anyopaque = null,
    value: Value = Value.undef(),
};

pub const FinalizationRecord = struct {
    target: ?*anyopaque = null,
    held: Value = Value.undef(),
    token: ?*anyopaque = null,
    ready: bool = false,
};

pub const ObjectBackingFlags = packed struct {
    slots: bool = false,
    elements: bool = false,
    accessors: bool = false,
    key_order: bool = false,
    attrs: bool = false,
    holes: bool = false,
    weak_entries: bool = false,
    finalization_records: bool = false,
    typed_array: bool = false,
    data_view: bool = false,
    temporal: bool = false,
    arg_map_names: bool = false,
};

pub const ObjectPrivateDataTag = enum(u8) {
    none,
    jsthread_thread,
    jsthread_lock,
    jsthread_condition,
    jsthread_thread_local,
    jsthread_unlock_token,
    jsthread_release_state,
};

/// A JavaScript object. v1 keeps this deliberately small: a string-keyed
/// property map, an optional dense array part, and three flavors of callable:
/// a JS-defined function (`js_func`, type-erased `*Function` to avoid an
/// import cycle with the interpreter), a Zig-native builtin (`native`), and a
/// C-ABI host callback (`callback`). In arena mode, backing stores still share
/// the owning Context's arena; in GC mode, migrated backing stores record their
/// allocator so object finalization can reclaim them before Context teardown.
pub const Object = struct {
    /// Non-null when this object's lazily-allocated backing stores have moved
    /// out of the arena for GC-mode reclamation. Individual flags below record
    /// which stores actually use this allocator, so mixed legacy/GC state is
    /// finalized accurately while migration is incremental.
    backing_allocator: ?std.mem.Allocator = null,
    backing_flags: ObjectBackingFlags = .{},
    /// `backingFor`/`(de)activateBacking` touch `backing_flags`/`backing_allocator`
    /// while the caller holds *whichever* structure lock matches the field
    /// (elements_lock for elements, property_lock for slots/attrs/accessors), so
    /// those don't mutually exclude on the shared packed `backing_flags` byte —
    /// under `parallel_js` an elements-grow on one thread races an attrs-grow on
    /// another. This dedicated lock serializes backing activation across them.
    /// Gated on `element_locks_enabled` so the default engine pays nothing.
    backing_lock: std.atomic.Mutex = .unlocked,
    /// Coarse synchronization for ordinary named-property metadata: shape
    /// publication, slots, accessors, attributes, and key order. The Layer-B GIL
    /// still serializes JS execution today; this lock is the Layer-C object-side
    /// convergence point for paths that already flow through Object helpers.
    property_lock: std.atomic.Mutex = .unlocked,
    /// Coarse synchronization for the dense/indexed element store. Arrays,
    /// Map/Set data, iterator cursor cells, and many small engine tuples use
    /// `elements`; Layer-C work must move each direct access behind this lock or
    /// a narrower equivalent before the GIL can go away.
    elements_lock: std.atomic.Mutex = .unlocked,
    /// Named properties live behind a shared `Shape` (null = no own properties)
    /// plus a flat per-object `slots` array indexed by the shape. See shape.zig.
    shape: ?*Shape = null,
    slots: std.ArrayListUnmanaged(Value) = .empty,
    /// Prototype link ([[Prototype]]): property lookup walks this chain. An
    /// instance's proto is its constructor's `.prototype`; a class's `.prototype`
    /// protos to its superclass's `.prototype`.
    proto: ?*Object = null,
    /// Callable built-ins may leave `proto` null and inherit %Function.prototype%
    /// implicitly. Once [[SetPrototypeOf]] explicitly sets null, that null must be
    /// observable through [[GetPrototypeOf]] instead of falling back again.
    proto_explicit_null: bool = false,
    /// Accessor (get/set) properties, lazily allocated. Checked before the data
    /// slot at each level of the prototype walk. The POINTER is accessed atomically
    /// (`.load`/`.store(.monotonic)`, a plain mov — zero cost): under `parallel_js`
    /// a peer's `setAccessor` publishes the map (null -> non-null) under
    /// `lockProperties` while other threads read the many unlocked `accessors ==
    /// null` fast-path guards, which on a plain field ThreadSanitizer flags as a
    /// race. The map CONTENTS are only ever grown under `lockProperties`, so the
    /// pointer is the only unsynchronized access.
    accessors: std.atomic.Value(?*std.StringHashMapUnmanaged(Accessor)) = .init(null),
    /// The set of private names this object was *branded* with at construction
    /// (its class's private fields/methods/accessors). PrivateGet/PrivateSet check
    /// brand membership here rather than via prototype inheritance, so an object
    /// missing the brand (a non-instance, a derived `this` before `super()`
    /// returns, an instance of a different evaluation of the class) is rejected.
    /// Lazily allocated. Keyed by the (evaluation-unique) private storage name.
    private_brands: ?*std.StringHashMapUnmanaged(void) = null,
    /// All own named keys (data AND accessor) in creation order — allocated
    /// lazily only when an accessor is first added, since data slots otherwise
    /// keep insertion order via the shape chain. `ownKeys` uses this to interleave
    /// data and accessor keys by creation order (the shape can't, as accessors
    /// live in a side map). May hold stale/duplicate entries (deleted or re-added
    /// keys) — readers re-check membership and keep each key's LAST occurrence.
    /// The POINTER is accessed atomically (`.load`/`.store(.monotonic)`, a plain
    /// mov): under `parallel_js` a peer publishes it null->non-null under
    /// `lockProperties` (`ensureKeyOrderUnlocked`, first accessor) while other
    /// threads read the unlocked `key_order == null` fast-path guards — a data race
    /// on a plain field. The list CONTENTS are only mutated under `lockProperties`,
    /// so the pointer is the only unsynchronized access (mirrors `accessors`).
    key_order: std.atomic.Value(?*std.ArrayListUnmanaged([]const u8)) = .init(null),
    elements: std.ArrayListUnmanaged(Value) = .empty,
    /// Per-property attribute overrides, lazily allocated. Absent name = the
    /// all-true default (a plain-assignment property). See `PropAttr`.
    attrs: ?*std.StringHashMapUnmanaged(PropAttr) = null,
    /// When false (set by `Object.preventExtensions`/`seal`/`freeze`), new own
    /// properties can't be added. Accessed atomically via `isExtensible`/
    /// `setExtensible`: under `parallel_js` a peer can seal/freeze a shared object
    /// while another thread reads extensibility to add a property, which on a
    /// plain bool is a data race. `.monotonic` is a plain byte load/store that
    /// just marks the access synchronized for ThreadSanitizer (the freeze-vs-add
    /// outcome is racy-by-spec regardless of who wins).
    extensible_flag: std.atomic.Value(bool) = .init(true),
    /// A Symbol (a tagged object so identity `===` and storage reuse the object
    /// machinery; `typeof` reports "symbol"). `sym_key` is its unique property-key
    /// encoding (used when a symbol is an object property key).
    is_symbol: bool = false,
    sym_key: []const u8 = "",
    /// A BigInt primitive (`typeof` reports "bigint"; treated as a primitive in
    /// equality/arithmetic). Small values use the `i128` fast path; oversized
    /// literals/decimal strings keep a canonical decimal identity in
    /// `bigint_text` until full arbitrary-precision arithmetic lands.
    is_bigint: bool = false,
    bigint: i128 = 0,
    bigint_text: ?[]const u8 = null,
    /// An `[[IsHTMLDDA]]` exotic object (e.g. `document.all`): `typeof` reports
    /// "undefined", ToBoolean is false, and it is loosely-equal to null/undefined.
    is_htmldda: bool = false,
    /// A `JSON.rawJSON(...)` result (carries `[[IsRawJSON]]`): a frozen null-proto
    /// object with an own "rawJSON" string property emitted verbatim by stringify.
    is_raw_json: bool = false,
    /// A Symbol's `[[Description]]`: `null` = no description (reads as
    /// `undefined`), else the string. Held in this dedicated slot rather than an
    /// own `description` property so it stays invisible to reflection
    /// (`Object.getOwnPropertyDescriptor(sym, "description")` is undefined) —
    /// `Symbol.prototype.description` is a prototype accessor instead.
    sym_desc: ?[]const u8 = null,
    /// A `Date` instance — its [[DateValue]] (ms since the Unix epoch, or NaN
    /// for an invalid date) is the internal-slot field `date_ms`, invisible to
    /// reflection/enumeration; methods are dispatched in `dateMethod`.
    is_date: bool = false,
    date_ms: f64 = 0,
    is_array: bool = false,
    // (atomic accessors for `date_ms` are defined as methods below)
    /// Test-shell `$vm.ensureArrayStorage(array)` marker. zig-js uses one
    /// generic array element backing rather than JSC's multiple butterfly
    /// regimes; this bit records the requested ArrayStorage witness mode so
    /// `$vm.indexingMode` can report the effective stress precondition without
    /// changing ordinary ECMAScript array semantics.
    forced_array_storage: bool = false,
    /// Conservative guard for fast indexed writes: once an object has ever had an
    /// array-index data/accessor property, prototype-chain writes must use the
    /// ordinary path so inherited setters/non-writable data stay observable.
    /// Atomic: read on the indexed-write fast path while a peer can set it when a
    /// proto-chain object gains an array-index property (no-GIL). One byte → a
    /// plain load/store. Mirrors `indexed_own_seen`.
    has_indexed_property: std.atomic.Value(bool) = .init(false),
    /// Conservative cross-thread guard for prototype-chain indexed writes. Unlike
    /// `has_indexed_property`, this also records dense element creation and is
    /// used only when another object is consulting this object as a prototype.
    indexed_own_seen: std.atomic.Value(bool) = .init(false),
    /// For arrays, a *logical* length floor used when it exceeds the physically
    /// stored `elements` — so `new Array(4294967295)` / `arr.length = big` track a
    /// length without materializing (and OOM-ing on) that many holes. The array's
    /// observable length is `max(elements.items.len, array_len)`.
    array_len: usize = 0,
    callback: ?HostCallback = null,
    /// Owning Context for C-API host callbacks. Kept separate from
    /// `private_data`, which belongs to `JSObjectMake(..., data)` embedders.
    callback_context: ?*anyopaque = null,
    native: ?NativeFn = null,
    /// For a `native` function, whether it implements [[Construct]] — i.e. is
    /// `new`-able. Most built-ins are *not* constructors (methods, `Math.*`,
    /// `parseInt`, `Symbol`, …); only the handful that the spec defines as
    /// constructors (`Array`, `Object`, `Map`, `RegExp`, …) set this, so
    /// `new Object.keys()` / `new Symbol()` throw a TypeError as required.
    native_ctor: bool = false,
    /// `*Interpreter.Function`, type-erased to break the value↔interpreter
    /// import cycle. The interpreter casts it back when calling.
    js_func: ?*anyopaque = null,
    /// `*vm.Generator`, type-erased (same cycle break as `js_func`). Non-null
    /// marks a generator *object* — the iterator returned by calling a
    /// `function*`; its `.next()`/`.return()`/`.throw()` drive the suspendable VM.
    gen: ?*anyopaque = null,
    /// `*Interpreter.BoundFn`, type-erased. Non-null marks a bound function
    /// (`fn.bind(this, ...args)`): calling it invokes the target with the bound
    /// `this` and the bound args prepended.
    bound: ?*anyopaque = null,
    /// Opaque `data` pointer carried for `JSObjectMake(ctx, class, data)` and
    /// surfaced to host callbacks via private-data accessors later.
    private_data: ?*anyopaque = null,
    /// Internal owner tag for engine-managed `private_data` roots. Untagged
    /// host data stays opaque; tracers must not inspect it speculatively.
    private_data_tag: ObjectPrivateDataTag = .none,
    /// Promise resolving functions carry one shared, spec-observable
    /// [[AlreadyResolved]] record per resolve/reject pair. The resolve function
    /// object owns that tiny record directly; the reject function points at the
    /// resolve object through `private_data`.
    promise_resolving_already: bool = false,
    /// `Thread.restrict(obj)`: the only OS thread allowed to touch this
    /// object through the enforced internal-method funnels (0 =
    /// unrestricted). Foreign access throws `ConcurrentAccessError`. Atomic: the
    /// claim is a CAS (two `Thread.restrict` calls on the same object race), and
    /// the enforcement check reads it from any thread. Thread ids are never 0.
    restricted_to: std.atomic.Value(u64) = .init(0),
    /// True for `Error`-family instances; drives `toString` and `instanceof`.
    is_error: bool = false,
    /// True for `RegExp` instances (carries `source`/`flags` properties; matching
    /// is backed by zig-regex).
    is_regex: bool = false,
    /// True for function `arguments` objects; they are array-like internally but
    /// carry the Arguments brand for Object.prototype.toString.
    is_arguments: bool = false,
    /// A mapped (sloppy-mode, simple-parameter) arguments object's
    /// `[[ParameterMap]]`: the call's environment record (type-erased
    /// `*Environment`) and the parameter name each index maps to (`""` = not
    /// mapped). A mapped index reads/writes the parameter binding; defining it as
    /// an accessor or non-writable, or deleting it, severs the mapping.
    arg_map_env: ?*anyopaque = null,
    arg_map_names: [][]const u8 = &.{},
    /// `Map`/`Set` instances. A Map keeps `[key,value]` pair-arrays in
    /// `elements`; a Set keeps values directly. `size` is a maintained property.
    is_map: bool = false,
    is_set: bool = false,
    /// Internal tombstone for SetData slots deleted during observable iteration.
    /// User code can never obtain one; Set/iterator helpers skip these slots.
    is_set_deleted: bool = false,
    /// A WeakMap/WeakSet reuses the `is_map`/`is_set` storage but carries this
    /// flag so the brand checks can tell a Map from a WeakMap (and Set/WeakSet).
    is_weak: bool = false,
    /// WeakMap/WeakSet entries. Keys are weak GC edges; for WeakMap, `value`
    /// becomes live iff `key` is live during the ephemeron fixed-point pass.
    weak_entries: std.ArrayListUnmanaged(WeakCollectionEntry) = .empty,
    /// Pointer identity -> `weak_entries` index. This keeps WeakMap/WeakSet
    /// operations O(1) while the entry list remains the GC-visible ephemeron
    /// storage. Stale/missing entries are tolerated and repaired by mutators.
    weak_index: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// For error instances, the error class name (e.g. "TypeError"); for a
    /// builtin error *constructor* object, see `error_ctor`.
    error_name: []const u8 = "",
    /// Non-null marks this object as a builtin error constructor; the value is
    /// the class name it produces ("Error", "TypeError", ...). Callable both
    /// plainly (`TypeError("x")`) and via `new`.
    error_ctor: ?[]const u8 = null,
    /// For objects created by `new F()`, the constructor function's object —
    /// used by `instanceof` to walk the (flat, v1) construction link.
    ctor_ref: ?*Object = null,
    /// `*Interpreter.Promise`, type-erased (cycle break like `js_func`/`gen`).
    /// Non-null marks a Promise object — its `then`/`catch`/`finally` are
    /// dispatched specially and it carries pending reactions + settled state.
    promise: ?*anyopaque = null,
    /// A primitive-wrapper object's boxed [[NumberData]]/[[StringData]]/
    /// [[BooleanData]] — set by `new Number(x)` / `new String(x)` / `new
    /// Boolean(x)`. Non-null marks the object as a wrapper: `typeof` is still
    /// "object", but `valueOf`/ToPrimitive unwrap it and `Object.prototype.
    /// toString` reports `[object Number|String|Boolean]`.
    prim: ?Value = null,
    /// `Proxy` exotic object: the wrapped target and the handler object. Both
    /// non-null marks a proxy — property operations route through the handler's
    /// traps (falling back to the target). A revoked proxy has both set to a
    /// sentinel `revoked` flag.
    proxy_target: ?*Object = null,
    proxy_handler: ?*Object = null,
    proxy_revoked: bool = false,
    /// Proxies keep their [[Call]] exotic behavior even after revocation. Once
    /// revoked, the target slot is gone, so cache the callable bit at creation.
    proxy_callable: bool = false,
    /// Module Namespace exotic object: points to an `interpreter.ModuleNs`
    /// (its sorted export names + live bindings). When set, this object is a
    /// `[[Module]]` namespace and the engine intercepts its essential internal
    /// methods (live [[Get]], [[HasProperty]], sorted [[OwnPropertyKeys]],
    /// frozen/non-extensible, throwing [[Set]]/[[Delete]]/[[DefineOwnProperty]]).
    module_ns: ?*anyopaque = null,
    /// For arrays: the set of dense-index *holes* (gaps that read as absent — a
    /// deleted element, an elision in `[1,,3]`, or a gap created by a sparse
    /// assignment). The `elements` slot for a hole still exists (holds undefined),
    /// but `HasProperty`/iteration treat the index as not present. Lazily allocated.
    holes: ?*std.AutoHashMapUnmanaged(usize, void) = null,

    /// `ArrayBuffer` backing store (non-null marks an ArrayBuffer object).
    array_buffer: ?*ArrayBufferData = null,
    /// Typed-array view (non-null marks a `Int8Array`/…/`Float64Array`): an
    /// integer-indexed view over `buffer`'s bytes. Index get/set read/write the
    /// underlying bytes coerced to/from the element type.
    typed_array: ?*TypedArrayData = null,
    /// `DataView` view (non-null marks a DataView): a typed read/write window
    /// over `buffer`'s bytes with per-access endianness.
    data_view: ?*DataViewData = null,
    /// A RegExp's [[OriginalSource]] / [[OriginalFlags]] internal slots. Held off
    /// the property map so `source`/`flags`/`global`/… resolve through the
    /// RegExp.prototype accessor getters (not instance own data properties).
    regex_source: []const u8 = "",
    regex_flags: []const u8 = "",
    /// Cached `*regex.Regex`, type-erased to keep value.zig independent from the
    /// regex package. Invalidated when `RegExp.prototype.compile` changes slots.
    regex_compiled: ?*anyopaque = null,
    /// Marks a `WeakRef` instance. The target is a weak GC edge, so collection
    /// may clear it while the WeakRef object itself remains branded.
    is_weak_ref: bool = false,
    weak_ref_target: ?*Object = null,
    /// Marks a `FinalizationRegistry`. Dead targets make records ready for
    /// explicit `cleanupSome()` delivery at quiescent collection points.
    is_finalization_registry: bool = false,
    finalization_callback: Value = Value.undef(),
    finalization_records: std.ArrayListUnmanaged(FinalizationRecord) = .empty,
    /// Lazy Iterator-Helper state (`map`/`filter`/`take`/`drop`/`flatMap`/wrap),
    /// non-null on a helper iterator returned by those methods.
    iter_helper: ?*IterHelper = null,
    /// Marks a `ShadowRealm` instance (its child realm's Environment is in
    /// `private_data`).
    is_shadow_realm: bool = false,
    /// `Temporal.*` internal slots (PlainDate/Time/DateTime/Duration/Instant/…),
    /// non-null on a Temporal object.
    temporal: ?*TemporalData = null,

    fn lockBacking(self: *Object) bool {
        if (!element_locks_enabled.load(.acquire)) return false;
        var spins: usize = 0;
        while (!self.backing_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        return true;
    }
    fn unlockBacking(self: *Object, held: bool) void {
        if (held) self.backing_lock.unlock();
    }

    // Assumes `backing_lock` held (called only from `backingFor`).
    fn activateBacking(self: *Object, comptime field: []const u8) ?std.mem.Allocator {
        const state = gc_runtime.activeObjectBacking() orelse return null;
        if (self.backing_allocator == null) self.backing_allocator = state.allocator;
        if (!@field(self.backing_flags, field)) {
            @field(self.backing_flags, field) = true;
            // Atomic: parallel mutators (post-GIL) bump this shared accounting
            // counter concurrently. Identical result single-threaded.
            if (state.stores_live) |live| _ = @atomicRmw(usize, live, .Add, 1, .monotonic);
        }
        return self.backing_allocator.?;
    }

    fn deactivateBacking(self: *Object, comptime field: []const u8) void {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        if (!@field(self.backing_flags, field)) return;
        @field(self.backing_flags, field) = false;
        if (gc_runtime.activeObjectBacking()) |state| {
            if (state.stores_live) |live| {
                _ = @atomicRmw(usize, live, .Sub, 1, .monotonic);
            }
        }
    }

    fn backingFor(self: *Object, fallback: std.mem.Allocator, comptime field: []const u8) std.mem.Allocator {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        if (self.backing_allocator) |a| {
            if (!@field(self.backing_flags, field)) {
                if (self.activateBacking(field)) |active| return active;
            }
            return a;
        }
        return self.activateBacking(field) orelse fallback;
    }

    /// Whether new own properties may be added (see `extensible_flag`).
    pub inline fn isExtensible(self: *const Object) bool {
        return @constCast(self).extensible_flag.load(.monotonic);
    }
    /// Set by `Object.preventExtensions`/`seal`/`freeze`.
    pub inline fn setExtensible(self: *Object, v: bool) void {
        self.extensible_flag.store(v, .monotonic);
    }

    pub fn slotsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "slots");
    }

    pub fn elementsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "elements");
    }

    pub fn accessorsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "accessors");
    }

    pub fn keyOrderAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "key_order");
    }

    pub fn attrsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "attrs");
    }

    pub fn holesAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "holes");
    }

    pub fn weakEntriesAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "weak_entries");
    }

    pub fn finalizationRecordsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "finalization_records");
    }

    pub fn typedArrayAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "typed_array");
    }

    pub fn destroyUninstalledTypedArray(self: *Object, fallback: std.mem.Allocator, ta: *TypedArrayData) void {
        const a = self.backing_allocator orelse fallback;
        a.destroy(ta);
        self.deactivateBacking("typed_array");
    }

    pub fn dataViewAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "data_view");
    }

    pub fn temporalAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "temporal");
    }

    pub fn argMapNamesAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "arg_map_names");
    }

    pub fn lockProperties(self: *const Object) void {
        var spins: usize = 0;
        const mutex = &@constCast(self).property_lock;
        while (!mutex.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlockProperties(self: *const Object) void {
        @constCast(self).property_lock.unlock();
    }

    /// [[Prototype]], read/written atomically: `setPrototypeOf` (and internal
    /// reparenting) writes `proto` on a shared object while peers walk its
    /// prototype chain (no-GIL). A nullable pointer is one word, so `.monotonic`
    /// is a plain load/store — zero perf cost, it just marks the access
    /// synchronized for ThreadSanitizer. Object-creation struct-inits write the
    /// raw field directly (the object isn't published yet → no race).
    pub inline fn protoAtomic(self: *const Object) ?*Object {
        return @atomicLoad(?*Object, &@constCast(self).proto, .monotonic);
    }
    pub inline fn setProtoAtomic(self: *Object, p: ?*Object) void {
        gc_runtime.barrierFrom(@ptrCast(self), if (p) |proto| @ptrCast(proto) else null);
        @atomicStore(?*Object, &self.proto, p, .monotonic);
    }

    /// Gate for the per-object `elements_lock`, enabled by the
    /// parallel/concurrent synchronization protocol (mutators in parallel or a
    /// concurrent marker). The single-threaded and `.gil = true` engines leave
    /// `lockElements`/`unlockElements` as a single relaxed-ish load and return —
    /// the hot dense-element read/write paths stay lock-free and full-speed.
    pub var element_locks_enabled: std.atomic.Value(bool) = .init(false);

    pub fn lockElements(self: *const Object) void {
        if (!element_locks_enabled.load(.acquire)) return;
        var spins: usize = 0;
        const mutex = &@constCast(self).elements_lock;
        while (!mutex.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlockElements(self: *const Object) void {
        if (!element_locks_enabled.load(.acquire)) return;
        @constCast(self).elements_lock.unlock();
    }

    /// `Date`'s [[DateValue]] slot, read/written atomically: a shared Date can be
    /// `setTime`'d on one thread while another reads it (no-GIL). A single f64 is
    /// one word, so `.monotonic` is a plain load/store (no perf cost) and just
    /// tells ThreadSanitizer the access is synchronized.
    pub fn dateMs(self: *const Object) f64 {
        return @atomicLoad(f64, &@constCast(self).date_ms, .monotonic);
    }
    pub fn setDateMs(self: *Object, v: f64) void {
        @atomicStore(f64, &self.date_ms, v, .monotonic);
    }

    pub fn elementsLen(self: *const Object) usize {
        self.lockElements();
        defer self.unlockElements();
        return self.elements.items.len;
    }

    pub fn arrayLength(self: *const Object) usize {
        self.lockElements();
        defer self.unlockElements();
        return @max(self.elements.items.len, self.array_len);
    }

    pub fn elementAt(self: *const Object, i: usize) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len) return null;
        return self.elements.items[i];
    }

    pub fn setElementAt(self: *Object, i: usize, v: Value) bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len) return false;
        gcBarrier(self, v);
        self.elements.items[i] = v;
        return true;
    }

    pub fn appendElement(self: *Object, arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        try self.elements.append(self.elementsAllocator(arena), v);
    }

    pub fn appendElementIfLen(self: *Object, arena: std.mem.Allocator, expected_len: usize, v: Value) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.elements.items.len != expected_len) return false;
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        try self.elements.append(self.elementsAllocator(arena), v);
        return true;
    }

    /// Append to `elements` when it is used as engine/private side storage
    /// rather than observable indexed properties (for example Map/Set backing
    /// entries). This keeps the same lock + GC barrier discipline as
    /// `appendElement` without changing `indexed_own_seen`.
    pub fn appendInternalElement(self: *Object, arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        gcBarrier(self, v);
        try self.elements.append(self.elementsAllocator(arena), v);
    }

    /// Append an array-literal elision at the current dense end. The slot
    /// contributes to array length but remains an absent indexed property.
    pub fn appendArrayHole(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        try self.markHoleUnlocked(arena, self.elements.items.len);
        try self.elements.append(self.elementsAllocator(arena), Value.undef());
    }

    /// Atomic fast path for `Array.prototype.push` on a packed dense Array.
    /// Returns the new logical length, or null when holes/sparse tail require
    /// the full observable `[[Set]]` path.
    pub fn appendPackedDenseElements(self: *Object, arena: std.mem.Allocator, values: []const Value) std.mem.Allocator.Error!?usize {
        self.lockElements();
        defer self.unlockElements();
        if (self.holes != null or self.array_len > self.elements.items.len) return null;
        const new_len = self.elements.items.len + values.len;
        if (new_len > 4294967295) return null;
        for (values) |v| gcBarrier(self, v);
        if (values.len != 0) self.indexed_own_seen.store(true, .release);
        try self.elements.appendSlice(self.elementsAllocator(arena), values);
        self.array_len = new_len;
        return new_len;
    }

    /// Fast path for CreateDataPropertyOrThrow on a plain dense Array when the
    /// requested index is exactly the current logical end. The check and append
    /// are one element-lock critical section so a peer grow cannot race the
    /// `items.len` observation.
    pub fn appendDataIndexIfDense(self: *Object, arena: std.mem.Allocator, i: usize, v: Value) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.holes != null or i != self.elements.items.len or i != self.array_len) return false;
        if (i >= 4294967295) return false;
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        try self.elements.append(self.elementsAllocator(arena), v);
        self.array_len = i + 1;
        return true;
    }

    pub fn atomicDenseElementLoad(self: *Object, i: usize) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len or self.isHoleUnlocked(i)) return null;
        return self.elements.items[i];
    }

    pub fn atomicDenseElementStore(self: *Object, i: usize, v: Value) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len or self.isHoleUnlocked(i)) return null;
        gcBarrier(self, v);
        self.elements.items[i] = v;
        return v;
    }

    pub fn atomicDenseElementExchange(self: *Object, i: usize, v: Value) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len or self.isHoleUnlocked(i)) return null;
        const old = self.elements.items[i];
        gcBarrier(self, v);
        self.elements.items[i] = v;
        return old;
    }

    pub fn atomicDenseElementCompareExchange(self: *Object, i: usize, expected: Value, replacement: Value) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len or self.isHoleUnlocked(i)) return null;
        const old = self.elements.items[i];
        if (sameValueZero(old, expected)) {
            gcBarrier(self, replacement);
            self.elements.items[i] = replacement;
        }
        return old;
    }

    pub const DenseElementRmwOp = enum { add, sub, and_, or_, xor };

    pub fn atomicDenseElementRmwNumber(self: *Object, i: usize, operand: f64, op: DenseElementRmwOp) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len or self.isHoleUnlocked(i)) return null;
        const old = self.elements.items[i];
        if (!old.isNumber()) return null;
        const result: f64 = switch (op) {
            .add => old.asNum() + operand,
            .sub => old.asNum() - operand,
            .and_ => @floatFromInt(jsInt32(old.asNum()) & jsInt32(operand)),
            .or_ => @floatFromInt(jsInt32(old.asNum()) | jsInt32(operand)),
            .xor => @floatFromInt(jsInt32(old.asNum()) ^ jsInt32(operand)),
        };
        self.elements.items[i] = Value.num(result);
        return old;
    }

    fn jsInt32(n: f64) i32 {
        if (std.math.isNan(n) or std.math.isInf(n)) return 0;
        const wrapped = @mod(@trunc(n), 4294967296.0);
        const u: u32 = @intFromFloat(if (wrapped < 0) wrapped + 4294967296.0 else wrapped);
        return @bitCast(u);
    }

    pub fn clearElementsRetainingCapacity(self: *Object) void {
        self.lockElements();
        defer self.unlockElements();
        self.elements.clearRetainingCapacity();
    }

    // --- WeakMap/WeakSet entry storage + FinalizationRegistry records --------
    // All guarded by `elements_lock` (the object's collection/side-storage lock)
    // so a *concurrent* GC marker reading `weak_entries`/`finalization_records`
    // (gc.zig `traceObject`) races neither an append nor a remove. Each helper is
    // self-contained — the lock is never held across a JS callback, so WeakMap
    // `getOrInsertComputed` and `FinalizationRegistry` cleanup callbacks (which
    // may re-enter the same collection) are safe. Keys/tokens compare by
    // identity, so no callback runs inside the locked region.

    /// WeakMap `[[Get]]`: the value stored under `key`, or null if absent.
    pub fn weakEntryGet(self: *Object, key: ?*anyopaque) ?Value {
        self.lockElements();
        defer self.unlockElements();
        const i = self.weakEntryIndexUnlocked(key) orelse return null;
        return self.weak_entries.items[i].value;
    }

    /// WeakMap/WeakSet `[[Has]]`.
    pub fn weakEntryHas(self: *Object, key: ?*anyopaque) bool {
        self.lockElements();
        defer self.unlockElements();
        return self.weakEntryIndexUnlocked(key) != null;
    }

    /// WeakMap `[[Set]]` upsert: update the entry for `key` or append a new one.
    pub fn weakEntrySet(self: *Object, fallback: std.mem.Allocator, key: ?*anyopaque, v: Value) std.mem.Allocator.Error!void {
        gc_runtime.barrierWeak(@ptrCast(self));
        gcBarrier(self, v);
        self.lockElements();
        defer self.unlockElements();
        const alloc = self.weakEntriesAllocator(fallback);
        if (self.weakEntryIndexUnlocked(key)) |i| {
            self.weak_entries.items[i].value = v;
            self.weakIndexPut(alloc, key, i);
            return;
        }
        const i = self.weak_entries.items.len;
        try self.weak_entries.append(alloc, .{ .key = key, .value = v });
        self.weakIndexPut(alloc, key, i);
    }

    /// WeakSet `add`: append `key` if it is not already present.
    pub fn weakEntryAdd(self: *Object, fallback: std.mem.Allocator, key: ?*anyopaque) std.mem.Allocator.Error!void {
        gc_runtime.barrierWeak(@ptrCast(self));
        self.lockElements();
        defer self.unlockElements();
        const alloc = self.weakEntriesAllocator(fallback);
        if (self.weakEntryIndexUnlocked(key)) |i| {
            self.weakIndexPut(alloc, key, i);
            return;
        }
        const i = self.weak_entries.items.len;
        try self.weak_entries.append(alloc, .{ .key = key });
        self.weakIndexPut(alloc, key, i);
    }

    /// WeakMap/WeakSet `delete`: remove the entry for `key`; returns whether one
    /// was found.
    pub fn weakEntryDelete(self: *Object, key: ?*anyopaque) bool {
        self.lockElements();
        defer self.unlockElements();
        const i = self.weakEntryIndexUnlocked(key) orelse return false;
        self.weakEntrySwapRemoveAtUnlocked(i);
        return true;
    }

    fn weakIndexKey(key: ?*anyopaque) usize {
        return if (key) |ptr| @intFromPtr(ptr) else 0;
    }

    fn weakEntryIndexUnlocked(self: *Object, key: ?*anyopaque) ?usize {
        const k = weakIndexKey(key);
        if (self.weak_index.get(k)) |i| {
            if (i < self.weak_entries.items.len and self.weak_entries.items[i].key == key) return i;
        }
        for (self.weak_entries.items, 0..) |entry, i| {
            if (entry.key == key) return i;
        }
        return null;
    }

    fn weakIndexPut(self: *Object, alloc: std.mem.Allocator, key: ?*anyopaque, i: usize) void {
        self.weak_index.put(alloc, weakIndexKey(key), i) catch {};
    }

    pub fn weakEntrySwapRemoveAtUnlocked(self: *Object, i: usize) void {
        const removed_key = self.weak_entries.items[i].key;
        const last_i = self.weak_entries.items.len - 1;
        const moved_key = self.weak_entries.items[last_i].key;
        _ = self.weak_entries.swapRemove(i);
        _ = self.weak_index.remove(weakIndexKey(removed_key));
        if (i != last_i) {
            if (self.weak_index.getPtr(weakIndexKey(moved_key))) |slot| slot.* = i;
        }
    }

    /// FinalizationRegistry `register`: append a record (the strong `held` value
    /// is barriered by the caller before this store into the live registry cell).
    pub fn finRecordAppend(self: *Object, fallback: std.mem.Allocator, record: FinalizationRecord) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        try self.finalization_records.append(self.finalizationRecordsAllocator(fallback), record);
    }

    /// FinalizationRegistry `unregister`: remove every record whose token matches
    /// `token`; returns whether any were removed.
    pub fn finRecordUnregister(self: *Object, token: ?*anyopaque) bool {
        self.lockElements();
        defer self.unlockElements();
        var removed = false;
        var write: usize = 0;
        for (self.finalization_records.items, 0..) |record, read| {
            if (record.token == token) {
                removed = true;
                continue;
            }
            if (write != read) self.finalization_records.items[write] = record;
            write += 1;
        }
        if (removed) self.finalization_records.shrinkRetainingCapacity(write);
        return removed;
    }

    /// Pop the next `ready` finalization record (its target died), or null. The
    /// caller runs the cleanup callback *after* this returns — never under the
    /// lock — so the callback may re-enter the registry.
    pub fn finRecordTakeReady(self: *Object) ?FinalizationRecord {
        self.lockElements();
        defer self.unlockElements();
        var i: usize = 0;
        while (i < self.finalization_records.items.len) : (i += 1) {
            if (self.finalization_records.items[i].ready)
                return self.finalization_records.orderedRemove(i);
        }
        return null;
    }

    pub fn packedDenseElementsCoverLength(self: *const Object) bool {
        self.lockElements();
        defer self.unlockElements();
        return self.holes == null and self.array_len <= self.elements.items.len;
    }

    /// Snapshot a plain packed dense Array's iteration values under
    /// `elements_lock`. Returns null when Array iteration must fall back to
    /// observable `[[Get]]` (holes, sparse logical tail, or index accessors).
    pub fn packedDenseElementsSnapshot(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]Value {
        self.lockElements();
        defer self.unlockElements();
        if (self.holes != null or self.array_len > self.elements.items.len or self.accessors.load(.monotonic) != null) return null;
        const out = try arena.alloc(Value, self.elements.items.len);
        @memcpy(out, self.elements.items);
        return out;
    }

    /// Snapshot internal element-backed tuples/lists under `elements_lock`.
    /// Unlike `packedDenseElementsSnapshot`, this does not apply Array iteration
    /// semantics; callers use it only for engine-owned element lists such as
    /// iterator-helper source arrays.
    pub fn internalElementsSnapshot(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]Value {
        self.lockElements();
        defer self.unlockElements();
        const out = try arena.alloc(Value, self.elements.items.len);
        @memcpy(out, self.elements.items);
        return out;
    }

    pub fn denseElementLimit(self: *const Object, logical_len: usize) usize {
        self.lockElements();
        defer self.unlockElements();
        return @min(self.elements.items.len, logical_len);
    }

    fn isHoleUnlocked(self: *const Object, i: usize) bool {
        const h = self.holes orelse return false;
        return h.contains(i);
    }

    fn markHoleUnlocked(self: *Object, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        const a = self.holesAllocator(arena);
        if (self.holes == null) {
            self.holes = try a.create(std.AutoHashMapUnmanaged(usize, void));
            self.holes.?.* = .{};
        }
        try self.holes.?.put(a, i, {});
    }

    fn clearHoleUnlocked(self: *Object, i: usize) void {
        if (self.holes) |h| _ = h.remove(i);
    }

    pub fn denseElementInBounds(self: *const Object, i: usize) bool {
        self.lockElements();
        defer self.unlockElements();
        return i < self.elements.items.len;
    }

    pub fn denseElementPresent(self: *const Object, i: usize) bool {
        self.lockElements();
        defer self.unlockElements();
        return i < self.elements.items.len and !self.isHoleUnlocked(i);
    }

    pub fn denseElement(self: *const Object, i: usize) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len or self.isHoleUnlocked(i)) return null;
        return self.elements.items[i];
    }

    pub fn denseElementIndices(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]usize {
        self.lockElements();
        defer self.unlockElements();
        var list: std.ArrayListUnmanaged(usize) = .empty;
        errdefer list.deinit(arena);
        for (self.elements.items, 0..) |_, i| {
            if (self.isHoleUnlocked(i)) continue;
            try list.append(arena, i);
        }
        return list.items;
    }

    pub fn setDenseElement(self: *Object, i: usize, v: Value) bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len) return false;
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        self.elements.items[i] = v;
        self.clearHoleUnlocked(i);
        return true;
    }

    pub fn growDenseElement(self: *Object, arena: std.mem.Allocator, i: usize, v: Value) std.mem.Allocator.Error!usize {
        self.lockElements();
        defer self.unlockElements();
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        const gap_start = self.elements.items.len;
        while (self.elements.items.len <= i) try self.elements.append(self.elementsAllocator(arena), Value.undef());
        self.elements.items[i] = v;
        self.clearHoleUnlocked(i);
        var g = gap_start;
        while (g < i) : (g += 1) try self.markHoleUnlocked(arena, g);
        return gap_start;
    }

    pub fn setOrGrowDenseElement(
        self: *Object,
        arena: std.mem.Allocator,
        i: usize,
        v: Value,
        dense_cap: usize,
    ) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        if (i < self.elements.items.len) {
            self.elements.items[i] = v;
            self.clearHoleUnlocked(i);
            return true;
        }
        if (i >= dense_cap or i > self.elements.items.len + 1024) return false;
        const gap_start = self.elements.items.len;
        while (self.elements.items.len <= i) try self.elements.append(self.elementsAllocator(arena), Value.undef());
        self.elements.items[i] = v;
        self.clearHoleUnlocked(i);
        var g = gap_start;
        while (g < i) : (g += 1) try self.markHoleUnlocked(arena, g);
        return true;
    }

    pub fn deleteDenseElement(self: *Object, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elements.items.len) return false;
        self.elements.items[i] = Value.undef();
        try self.markHoleUnlocked(arena, i);
        return true;
    }

    pub fn truncateDenseElementsAndSetLength(self: *Object, new_len: usize) void {
        self.lockElements();
        defer self.unlockElements();
        if (new_len < self.elements.items.len) self.elements.shrinkRetainingCapacity(new_len);
        self.array_len = new_len;
    }

    pub fn extendArrayLengthFloor(self: *Object, new_len: usize) void {
        self.lockElements();
        defer self.unlockElements();
        self.array_len = @max(self.array_len, new_len);
    }

    pub fn reversePackedDenseElements(self: *Object) bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.holes != null or self.array_len > self.elements.items.len) return false;
        std.mem.reverse(Value, self.elements.items);
        return true;
    }

    pub fn replaceDenseElementsAndSetLength(
        self: *Object,
        arena: std.mem.Allocator,
        values: []const Value,
        new_len: usize,
    ) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        self.indexed_own_seen.store(true, .release);
        for (values) |v| gcBarrier(self, v);
        self.elements.clearRetainingCapacity();
        try self.elements.appendSlice(self.elementsAllocator(arena), values);
        if (self.holes) |h| h.clearRetainingCapacity();
        self.array_len = new_len;
    }

    pub fn splicePackedDenseElements(
        self: *Object,
        arena: std.mem.Allocator,
        start: usize,
        delete_count: usize,
        inserts: []const Value,
    ) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.holes != null or self.array_len > self.elements.items.len) return false;
        for (inserts) |v| gcBarrier(self, v);
        if (inserts.len != 0) self.indexed_own_seen.store(true, .release);
        var i: usize = 0;
        while (i < delete_count) : (i += 1) {
            if (start < self.elements.items.len) {
                _ = self.elements.orderedRemove(start);
            }
        }
        var j: usize = inserts.len;
        while (j > 0) : (j -= 1) {
            try self.elements.insert(self.elementsAllocator(arena), start, inserts[j - 1]);
        }
        self.array_len = self.elements.items.len;
        return true;
    }

    pub fn resetSlotsForRebuild(self: *Object) void {
        self.lockProperties();
        defer self.unlockProperties();
        self.resetSlotsForRebuildUnlocked();
    }

    fn resetSlotsForRebuildUnlocked(self: *Object) void {
        if (self.backing_flags.slots) {
            self.slots.deinit(self.backing_allocator.?);
            self.deactivateBacking("slots");
        }
        self.slots = .empty;
    }

    pub fn deinitKeyOrder(self: *Object) void {
        self.lockProperties();
        defer self.unlockProperties();
        self.deinitKeyOrderUnlocked();
    }

    fn deinitKeyOrderUnlocked(self: *Object) void {
        if (self.key_order.load(.monotonic)) |ord| {
            if (self.backing_flags.key_order) {
                const a = self.backing_allocator.?;
                for (ord.items) |key| a.free(key);
                ord.deinit(a);
                a.destroy(ord);
                self.deactivateBacking("key_order");
            }
        }
        self.key_order.store(null, .monotonic);
    }

    pub fn replaceKeyOrder(self: *Object, arena: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        try self.replaceKeyOrderUnlocked(arena, names);
    }

    fn replaceKeyOrderUnlocked(self: *Object, arena: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error!void {
        // Build the replacement list FIRST, then free the old one: `names` may
        // alias the current `key_order`'s key strings (the `deleteNamedDataOwn`
        // rebuild passes its surviving keys, which point into this very table), so
        // deiniting before copying frees the bytes `dupe` then reads - a
        // use-after-free. Copying first makes the new list self-owned. Do not
        // call `deinitKeyOrderUnlocked` for the swap: it deactivates the backing
        // flag, but the replacement list uses that same backing store and still
        // needs to be visible to the GC finalizer.
        const old_key_order = self.key_order.load(.monotonic);
        const old_uses_backing = self.backing_flags.key_order;
        const old_backing_allocator = self.backing_allocator;
        const alloc = self.keyOrderAllocator(arena);
        const ko = try alloc.create(std.ArrayListUnmanaged([]const u8));
        ko.* = .empty;
        errdefer {
            for (ko.items) |key| alloc.free(key);
            ko.deinit(alloc);
            alloc.destroy(ko);
            if (!old_uses_backing and self.backing_flags.key_order) self.deactivateBacking("key_order");
        }
        for (names) |name| try ko.append(alloc, try alloc.dupe(u8, name));
        if (old_key_order) |ord| {
            if (old_uses_backing) {
                const a = old_backing_allocator.?;
                for (ord.items) |key| a.free(key);
                ord.deinit(a);
                a.destroy(ord);
            }
        }
        self.key_order.store(ko, .monotonic);
    }

    /// Whether dense array index `i` is a hole (absent).
    pub fn isHole(self: *const Object, i: usize) bool {
        self.lockElements();
        defer self.unlockElements();
        return self.isHoleUnlocked(i);
    }

    /// Mark dense index `i` as a hole.
    pub fn markHole(self: *Object, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        try self.markHoleUnlocked(arena, i);
    }

    /// Clear the hole at index `i` (an assignment fills it).
    pub fn clearHole(self: *Object, i: usize) void {
        self.lockElements();
        defer self.unlockElements();
        self.clearHoleUnlocked(i);
    }

    pub fn isCallableObject(self: *const Object) bool {
        // A proxy is callable iff its target is; walk iteratively (bounded) so a
        // pathological proxy→target cycle can't blow the stack.
        var o = self;
        var guard: u32 = 0;
        while (o.proxy_target) |t| {
            guard += 1;
            if (guard > 10000) return false;
            o = t;
        }
        if (o.proxy_revoked) return o.proxy_callable;
        return o.callback != null or o.native != null or
            o.js_func != null or o.error_ctor != null or o.bound != null;
    }

    /// Own named property keys in insertion order (for `for-in` / enumeration).
    pub fn ownKeys(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        self.lockProperties();
        defer self.unlockProperties();
        return self.ownKeysUnlocked(arena);
    }

    fn ownKeysUnlocked(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        var insertion: std.ArrayListUnmanaged([]const u8) = .empty;
        const has_own = struct {
            fn f(o: *const Object, k: []const u8) bool {
                return o.getOwnUnlocked(k) != null or (o.accessors.load(.monotonic) != null and o.accessors.load(.monotonic).?.get(k) != null);
            }
        }.f;
        const contains = struct {
            fn f(list: []const []const u8, k: []const u8) bool {
                for (list) |e| if (std.mem.eql(u8, e, k)) return true;
                return false;
            }
        }.f;
        if (self.key_order.load(.monotonic)) |ord| {
            // Creation order across data + accessor keys. Keep each present key's
            // LAST occurrence (a deleted-then-re-added key sorts to its new spot).
            for (ord.items, 0..) |k, i| {
                if (!has_own(self, k)) continue;
                var later = false;
                var j = i + 1;
                while (j < ord.items.len) : (j += 1) if (std.mem.eql(u8, ord.items[j], k)) {
                    later = true;
                    break;
                };
                if (later) continue;
                try insertion.append(arena, k);
            }
            // Safety net: surface any current data slot or accessor that somehow
            // bypassed key_order, so no key is ever dropped (order best-effort).
            var s2 = self.shape;
            while (s2) |sh| {
                if (sh.name) |n| if (!contains(insertion.items, n)) try insertion.append(arena, n);
                s2 = sh.parent;
            }
            if (self.accessors.load(.monotonic)) |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    const k = entry.key_ptr.*;
                    if (!contains(insertion.items, k)) try insertion.append(arena, k);
                }
            }
        } else {
            // No accessors ever added: data slots in shape-chain insertion order.
            var s = self.shape;
            while (s) |sh| {
                if (sh.name) |n| try insertion.append(arena, n);
                s = sh.parent;
            }
            std.mem.reverse([]const u8, insertion.items); // chain is newest-first → insertion order
        }
        // OrdinaryOwnPropertyKeys order: canonical array-index keys ascending
        // first, then string keys in insertion order, then Symbol keys in
        // insertion order. Keep internal/private keys in the string bucket here:
        // public reflection filters them at the interpreter boundary, while
        // engine algorithms that call this low-level helper still need them.
        var indices: std.ArrayListUnmanaged([]const u8) = .empty;
        var strings: std.ArrayListUnmanaged([]const u8) = .empty;
        var symbols: std.ArrayListUnmanaged([]const u8) = .empty;
        for (insertion.items) |k| {
            if (canonicalIndex(k) != null) {
                try indices.append(arena, k);
            } else if (isRealSymbolKey(k)) {
                try symbols.append(arena, k);
            } else {
                try strings.append(arena, k);
            }
        }
        std.mem.sort([]const u8, indices.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return canonicalIndex(x).? < canonicalIndex(y).?;
            }
        }.lt);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        try out.appendSlice(arena, indices.items);
        try out.appendSlice(arena, strings.items);
        try out.appendSlice(arena, symbols.items);
        return out.items;
    }

    /// Atomic view of the `attrs` map pointer. Hot fast-path guards read
    /// `attrs != null` off-lock while `setAttr` publishes the map under
    /// `lockProperties`; a peer thread's defineProperty then races those raw
    /// reads (Linux tsan-nogil-corpus). A monotonic atomic load is a plain `mov`
    /// (perf-neutral) that gives those unlocked readers a defined synchronization
    /// with the atomic publish in `setAttrUnlocked`. Map *contents* stay guarded
    /// by `lockProperties`.
    pub inline fn attrsMap(self: *const Object) ?*std.StringHashMapUnmanaged(PropAttr) {
        return @atomicLoad(?*std.StringHashMapUnmanaged(PropAttr), &self.attrs, .monotonic);
    }

    /// The attributes of own property `name` (all-true default if no override).
    pub fn getAttr(self: *const Object, name: []const u8) PropAttr {
        self.lockProperties();
        defer self.unlockProperties();
        return self.getAttrUnlocked(name);
    }

    fn getAttrUnlocked(self: *const Object, name: []const u8) PropAttr {
        if (self.attrsMap()) |m| {
            if (m.get(name)) |a| return a;
        }
        return .{};
    }

    /// Record an attribute override for `name`.
    pub fn setAttr(self: *Object, arena: std.mem.Allocator, name: []const u8, a: PropAttr) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        try self.setAttrUnlocked(arena, name, a);
    }

    fn setAttrUnlocked(self: *Object, arena: std.mem.Allocator, name: []const u8, a: PropAttr) std.mem.Allocator.Error!void {
        const alloc = self.attrsAllocator(arena);
        if (self.attrsMap() == null) {
            const m = try alloc.create(std.StringHashMapUnmanaged(PropAttr));
            m.* = .{};
            // Publish the map pointer atomically so off-lock `attrsMap()` readers
            // (fast-path guards) synchronize with it; content stays under the lock.
            @atomicStore(?*std.StringHashMapUnmanaged(PropAttr), &self.attrs, m, .release);
        }
        const gop = try self.attrsMap().?.getOrPut(alloc, name);
        if (!gop.found_existing) gop.key_ptr.* = try alloc.dupe(u8, name);
        gop.value_ptr.* = a;
    }

    fn deleteAttrUnlocked(self: *Object, name: []const u8) void {
        const m = self.attrsMap() orelse return;
        if (m.fetchRemove(name)) |removed| {
            if (self.backing_flags.attrs) self.backing_allocator.?.free(removed.key);
        }
    }

    /// Own named data + accessor keys whose [[Enumerable]] is true, in insertion
    /// order (for `Object.keys`/`values`/`entries`, `for-in`, JSON).
    pub fn enumerableKeys(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (try self.ownKeys(arena)) |k| {
            if (isSymbolKey(k) or isPrivateKey(k)) continue; // symbol/private keys aren't string-enumerable
            if (self.getAttr(k).enumerable) try list.append(arena, k);
        }
        return list.items;
    }

    /// Whether this object carries the private brand `name`. Guarded by
    /// `property_lock` like every other named-metadata map: under `parallel_js`
    /// the same shared object can be branded (e.g. a class object's static
    /// brand, or `this` during construction) on one thread while another reads
    /// the brand set — an unsynchronized `StringHashMap` grow vs lookup corrupts
    /// the table (observed as an infinite grow-recursion). Uncontended in GIL
    /// mode (one tryLock, like `getOwn`).
    pub fn hasPrivateBrand(self: *const Object, name: []const u8) bool {
        self.lockProperties();
        defer self.unlockProperties();
        const m = self.private_brands orelse return false;
        return m.contains(name);
    }

    /// Brand this object with the private name `name` (PrivateFieldAdd /
    /// PrivateMethodOrAccessorAdd record-keeping). Funneled through
    /// `property_lock` (see `hasPrivateBrand`) so concurrent brand-adds on a
    /// shared object can't race the lazy-init or the `StringHashMap` grow.
    pub fn addPrivateBrand(self: *Object, arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        const alloc = self.accessorsAllocator(arena);
        if (self.private_brands == null) {
            self.private_brands = try alloc.create(std.StringHashMapUnmanaged(void));
            self.private_brands.?.* = .{};
        }
        try self.private_brands.?.put(alloc, name, {});
    }

    /// An own accessor (get/set) property, if present.
    pub fn getAccessor(self: *const Object, name: []const u8) ?Accessor {
        self.lockProperties();
        defer self.unlockProperties();
        return self.getAccessorUnlocked(name);
    }

    fn getAccessorUnlocked(self: *const Object, name: []const u8) ?Accessor {
        const m = self.accessors.load(.monotonic) orelse return null;
        return m.get(name);
    }

    /// Snapshot this object's own accessor keys (dup'd into `arena`) under
    /// `property_lock`. Callers that need to iterate accessor keys while also
    /// mutating the object (e.g. `seal`/`freeze`, which `setAttr` each key) must
    /// use this rather than iterating the live `accessors` map: under
    /// `parallel_js` a peer's concurrent `setAccessor` can grow (reallocate) the
    /// `StringHashMap` mid-iteration, corrupting it (the "grow vs lookup" panic).
    /// The snapshot is stable; the subsequent per-key work re-locks via the
    /// `getAttr`/`setAttr` accessors.
    pub fn accessorKeysSnapshot(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        self.lockProperties();
        defer self.unlockProperties();
        const m = self.accessors.load(.monotonic) orelse return &.{};
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        try list.ensureTotalCapacityPrecise(arena, m.count());
        var it = m.iterator();
        while (it.next()) |e| list.appendAssumeCapacity(try arena.dupe(u8, e.key_ptr.*));
        return list.items;
    }

    /// Define/merge an own accessor (get and/or set). Promotes the name to an
    /// accessor property.
    pub fn setAccessor(self: *Object, arena: std.mem.Allocator, name: []const u8, get: ?Value, set: ?Value) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        const alloc = self.accessorsAllocator(arena);
        if (self.accessors.load(.monotonic) == null) {
            const nm = try alloc.create(std.StringHashMapUnmanaged(Accessor));
            nm.* = .{};
            self.accessors.store(nm, .monotonic); // publish under lockProperties
        }
        const gop = try self.accessors.load(.monotonic).?.getOrPut(alloc, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try alloc.dupe(u8, name);
            gop.value_ptr.* = .{};
            if (canonicalIndex(name) != null) {
                self.has_indexed_property.store(true, .monotonic);
                self.indexed_own_seen.store(true, .release);
            }
            // First accessor on this object: start key_order by snapshotting the
            // existing data keys (shape-chain insertion order), so the new
            // accessor interleaves correctly with them.
            try self.ensureKeyOrderUnlocked(arena);
            try self.recordKeyOrderUnlocked(arena, gop.key_ptr.*);
        }
        if (get) |g| {
            gcBarrier(self, g);
            gop.value_ptr.get = g;
        }
        if (set) |s| {
            gcBarrier(self, s);
            gop.value_ptr.set = s;
        }
    }

    /// Append `name` to `key_order` unless it's already recorded — so converting
    /// a property between data and accessor keeps its original creation position
    /// (only a brand-new key extends the order).
    fn recordKeyOrder(self: *Object, arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        try self.recordKeyOrderUnlocked(arena, name);
    }

    fn recordKeyOrderUnlocked(self: *Object, arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!void {
        const ko = self.key_order.load(.monotonic) orelse return;
        for (ko.items) |e| if (std.mem.eql(u8, e, name)) return;
        const alloc = self.keyOrderAllocator(arena);
        try ko.append(alloc, try alloc.dupe(u8, name));
    }

    /// Lazily build `key_order`, seeding it with the current data keys in
    /// insertion order (the order the shape chain already encodes).
    fn ensureKeyOrder(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        try self.ensureKeyOrderUnlocked(arena);
    }

    fn ensureKeyOrderUnlocked(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.key_order.load(.monotonic) != null) return;
        const alloc = self.keyOrderAllocator(arena);
        const ko = try alloc.create(std.ArrayListUnmanaged([]const u8));
        ko.* = .empty;
        var seed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer seed.deinit(arena);
        var s = self.shape;
        while (s) |sh| {
            if (sh.name) |n| try seed.append(arena, n);
            s = sh.parent;
        }
        std.mem.reverse([]const u8, seed.items); // newest-first → insertion order
        for (seed.items) |n| try ko.append(alloc, try alloc.dupe(u8, n));
        self.key_order.store(ko, .monotonic);
    }

    /// Read an own named property, or null if absent. No allocation.
    pub fn getOwn(self: *const Object, name: []const u8) ?Value {
        self.lockProperties();
        defer self.unlockProperties();
        return self.getOwnUnlocked(name);
    }

    pub fn getOwnUnlocked(self: *const Object, name: []const u8) ?Value {
        const sh = self.shape orelse return null;
        // `lookup` doesn't mutate; the const-cast keeps Object read-only here.
        const slot = (@constCast(sh)).lookup(name) orelse return null;
        return self.slots.items[slot];
    }

    /// Set an own named property, transitioning the shape and growing `slots`
    /// when the name is new. `root` is the Context's empty shape; `arena` backs
    /// the slot storage and shape tree.
    pub fn setOwn(self: *Object, arena: std.mem.Allocator, root: *Shape, name: []const u8, v: Value) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        try self.setOwnUnlocked(arena, root, name, v);
    }

    pub fn setOwnUnlocked(self: *Object, arena: std.mem.Allocator, root: *Shape, name: []const u8, v: Value) std.mem.Allocator.Error!void {
        gcBarrier(self, v); // stored into this cell's slots on either path below
        if (self.shape) |sh| {
            if (sh.lookup(name)) |slot| {
                self.slots.items[slot] = v;
                return;
            }
        }
        const base = self.shape orelse root;
        const child = try base.transition(name);
        try self.slots.append(self.slotsAllocator(arena), v); // new slot index == base.count == child.slot
        self.shape = child;
        if (canonicalIndex(name) != null) {
            self.has_indexed_property.store(true, .monotonic);
            self.indexed_own_seen.store(true, .release);
        }
        // A new data key on an accessor-bearing object records its creation order
        // (a data↔accessor conversion keeps its position; deleteOwn drops stale
        // entries so a genuinely re-added key lands at the end).
        if (self.key_order.load(.monotonic) != null) try self.recordKeyOrderUnlocked(arena, name);
    }

    pub const AccessorDeleteResult = enum {
        absent,
        blocked,
        removed_continue,
        deleted,
    };

    pub fn deleteAccessorOwn(self: *Object, arena: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!AccessorDeleteResult {
        self.lockProperties();
        defer self.unlockProperties();
        const m = self.accessors.load(.monotonic) orelse return .absent;
        if (m.getPtr(key) == null) return .absent;
        if (!self.getAttrUnlocked(key).configurable) return .blocked;
        if (m.fetchRemove(key)) |removed| {
            if (self.backing_flags.accessors) self.backing_allocator.?.free(removed.key);
        }
        if (self.is_array) {
            if (canonicalIndex(key)) |i| {
                self.lockElements();
                defer self.unlockElements();
                if (i < self.elements.items.len) try self.markHoleUnlocked(arena, i);
            }
        }
        return if (self.getOwnUnlocked(key) == null) .deleted else .removed_continue;
    }

    pub fn deleteNamedDataOwn(self: *Object, arena: std.mem.Allocator, root: *Shape, key: []const u8) std.mem.Allocator.Error!bool {
        return self.deleteNamedDataOwnInternal(arena, root, key, false);
    }

    pub fn deleteNamedDataOwnPreserveOrder(self: *Object, arena: std.mem.Allocator, root: *Shape, key: []const u8) std.mem.Allocator.Error!bool {
        return self.deleteNamedDataOwnInternal(arena, root, key, true);
    }

    fn deleteNamedDataOwnInternal(self: *Object, arena: std.mem.Allocator, root: *Shape, key: []const u8, preserve_order: bool) std.mem.Allocator.Error!bool {
        self.lockProperties();
        defer self.unlockProperties();
        if (self.getOwnUnlocked(key) == null) return true;
        if (!self.getAttrUnlocked(key).configurable) return false;
        if (preserve_order) try self.ensureKeyOrderUnlocked(arena);

        const keys = try self.ownKeysUnlocked(arena);
        const Entry = struct { k: []const u8, v: Value, a: PropAttr };
        var saved: std.ArrayListUnmanaged(Entry) = .empty;
        var survived: std.ArrayListUnmanaged([]const u8) = .empty;
        for (keys) |k| {
            if (std.mem.eql(u8, k, key)) continue;
            try survived.append(arena, k);
            const v = self.getOwnUnlocked(k) orelse continue;
            try saved.append(arena, .{ .k = k, .v = v, .a = self.getAttrUnlocked(k) });
        }

        const old_key_order = self.key_order.load(.monotonic);
        self.shape = root;
        self.resetSlotsForRebuildUnlocked();
        self.deleteAttrUnlocked(key);
        self.key_order.store(null, .monotonic);
        for (saved.items) |entry| {
            try self.setOwnUnlocked(arena, root, entry.k, entry.v);
            try self.setAttrUnlocked(arena, entry.k, entry.a);
        }
        self.key_order.store(old_key_order, .monotonic);
        if (preserve_order) {
            // Data->accessor conversion keeps the property's original creation
            // position; `setAccessor` will reuse this existing key-order entry.
        } else if (self.accessors.load(.monotonic) != null) {
            try self.replaceKeyOrderUnlocked(arena, survived.items);
        } else {
            self.deinitKeyOrderUnlocked();
        }
        return true;
    }
};

/// An accessor property: getter and/or setter functions.
pub const Accessor = struct { get: ?Value = null, set: ?Value = null };

/// A symbol's internal property-key encoding is a NUL-led string, which can't
/// be produced by user code — so symbol-keyed properties never collide with
/// string keys and are excluded from string enumeration.
pub fn isSymbolKey(k: []const u8) bool {
    return k.len > 0 and k[0] == 0;
}

/// A key for an actual JS Symbol ("\x00s" + digits), as minted by makeSymbolObj
/// — distinct from the engine's hidden internal slots ("\x00intl", "\x00opts",
/// …), which are also NUL-prefixed but must not surface as symbols.
pub fn isRealSymbolKey(k: []const u8) bool {
    if (k.len < 3 or k[0] != 0 or k[1] != 's') return false;
    for (k[2..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// If `k` is a canonical array-index string — a non-negative integer below
/// 2**32-1 with no leading zeros or sign — return its numeric value, for the
/// spec's integer-keys-ascending property ordering. Otherwise null.
pub fn canonicalIndex(k: []const u8) ?u32 {
    if (k.len == 0) return null;
    if (k.len > 1 and k[0] == '0') return null; // leading zero → not canonical
    for (k) |c| if (c < '0' or c > '9') return null;
    const n = std.fmt.parseInt(u64, k, 10) catch return null;
    if (n >= 0xFFFFFFFF) return null; // not an array index
    return @intCast(n);
}

/// A class private member (`#x`). Stored under its `#`-prefixed name but hidden
/// from all reflection (Object.keys/getOwnPropertyNames/for-in/JSON) and never
/// enumerable — observable only through `obj.#x` inside the defining class.
pub fn isPrivateKey(k: []const u8) bool {
    // A genuine private name is rewritten to `#name\x00<serial>` (see
    // nextPrivateStorageKey): the embedded NUL — impossible in a source-level
    // property key — distinguishes it from an ordinary public property whose key
    // merely starts with '#' (e.g. a computed `["#m"]`), which must NOT be treated
    // as private. This predicate is for *runtime* storage keys (post-rewrite).
    return k.len > 0 and k[0] == '#' and std.mem.indexOfScalar(u8, k, 0) != null;
}

/// A *source-level* private name (`#x`), before the per-class rewrite assigns it
/// a unique storage key. Used only by the private-name rewriting machinery, which
/// operates on raw parser keys/identifiers; everything at runtime uses
/// `isPrivateKey` (which requires the rewritten NUL marker).
pub fn isRawPrivateName(k: []const u8) bool {
    return k.len > 0 and k[0] == '#';
}

/// A property's [[Writable]]/[[Enumerable]]/[[Configurable]] attributes. The
/// default (all true) matches a property created by plain assignment, so only
/// `Object.defineProperty`/`freeze`/etc. allocate an override entry.
pub const PropAttr = struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
};

/// A JavaScript value. Strings and objects point into the Context arena.
/// A JavaScript value — an 8-byte NaN-boxed word (issue #1 Phase 7, blocker #7).
/// A number is any non-boxed word; non-number values live in the negative
/// quiet-NaN region with a 3-bit tag in bits 50..48 and a 48-bit payload in bits
/// 47..0 (a pointer, or a boolean bit). Strings point at a `StringCell`. This
/// encoding is the one proven in `nanbox.zig` / `value_nb.zig`; every call site
/// reaches the value only through the API below (`kind`/`num`/`str`/`obj`/
/// `boolVal`/`undef`/`nul`/`asNum`/`asStr`/`asObj`/`asBool`/`isX`).
pub const Value = struct {
    bits: u64,

    const box_mask: u64 = 0xFFF8_0000_0000_0000;
    const canon_nan: u64 = 0x7FF8_0000_0000_0000;
    const tag_shift: u6 = 48;
    const payload_mask: u64 = 0x0000_FFFF_FFFF_FFFF;
    const tag_object: u3 = 1;
    const tag_string: u3 = 2;
    const tag_boolean: u3 = 3;
    const tag_undefined: u3 = 4;
    const tag_null: u3 = 5;

    pub const Kind = enum { undefined, null, boolean, number, string, object };

    inline fn boxed(tag: u3, payload: u64) Value {
        return .{ .bits = box_mask | (@as(u64, tag) << tag_shift) | payload };
    }
    inline fn boxedTag(self: Value) u3 {
        return @truncate(self.bits >> tag_shift);
    }

    pub inline fn kind(self: Value) Kind {
        if ((self.bits & box_mask) != box_mask) return .number;
        return switch (self.boxedTag()) {
            tag_object => .object,
            tag_string => .string,
            tag_boolean => .boolean,
            tag_undefined => .undefined,
            tag_null => .null,
            else => .number,
        };
    }

    // Constructors.
    pub inline fn num(n: f64) Value {
        return .{ .bits = if (std.math.isNan(n)) canon_nan else @bitCast(n) };
    }
    pub inline fn str(s: []const u8) Value {
        return boxed(tag_string, @intFromPtr(strcell.makeCell(s)));
    }
    pub inline fn obj(o: *Object) Value {
        return boxed(tag_object, @intFromPtr(o));
    }
    pub inline fn boolVal(b: bool) Value {
        return boxed(tag_boolean, @intFromBool(b));
    }
    pub inline fn undef() Value {
        return boxed(tag_undefined, 0);
    }
    pub inline fn nul() Value {
        return boxed(tag_null, 0);
    }

    // Accessors (caller has checked `kind()` first).
    pub inline fn asNum(self: Value) f64 {
        return @bitCast(self.bits);
    }
    pub inline fn asStr(self: Value) []const u8 {
        const cell: *const StringCell = @ptrFromInt(self.bits & payload_mask);
        return cell.bytes;
    }
    pub inline fn asObj(self: Value) *Object {
        return @ptrFromInt(self.bits & payload_mask);
    }
    pub inline fn asBool(self: Value) bool {
        return (self.bits & payload_mask) != 0;
    }

    // Kind predicates.
    pub inline fn isNumber(self: Value) bool {
        return self.kind() == .number;
    }
    pub inline fn isString(self: Value) bool {
        return self.kind() == .string;
    }
    pub inline fn isObject(self: Value) bool {
        return self.kind() == .object;
    }
    pub inline fn isBoolean(self: Value) bool {
        return self.kind() == .boolean;
    }
    pub inline fn isUndefined(self: Value) bool {
        return self.kind() == .undefined;
    }
    pub inline fn isNull(self: Value) bool {
        return self.kind() == .null;
    }

    pub fn isCallable(self: Value) bool {
        return switch (self.kind()) {
            .object => self.asObj().isCallableObject(),
            else => false,
        };
    }

    /// ECMAScript ToBoolean.
    pub fn toBoolean(self: Value) bool {
        return switch (self.kind()) {
            .undefined, .null => false,
            .boolean => self.asBool(),
            .number => self.asNum() != 0 and !std.math.isNan(self.asNum()),
            .string => self.asStr().len != 0,
            .object => if (self.asObj().is_htmldda) false else if (self.asObj().is_bigint) !bigIntIsZero(self.asObj()) else true,
        };
    }

    /// ECMAScript ToNumber (subset: objects coerce to NaN for now).
    pub fn toNumber(self: Value) f64 {
        return switch (self.kind()) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => if (self.asBool()) 1 else 0,
            .number => self.asNum(),
            .string => stringToNumber(self.asStr()),
            // A BigInt's mathematical value (explicit `Number(1n) === 1`); other
            // objects coerce to NaN here (proper ToPrimitive is `Interpreter`-level).
            .object => if (self.asObj().is_bigint) bigIntToNumber(self.asObj()) else std.math.nan(f64),
        };
    }

    /// ECMAScript ToInt32 — used by the bitwise/shift operators. NaN/±Inf → 0,
    /// otherwise truncate toward zero and reduce modulo 2^32 into a signed int.
    pub fn toInt32(self: Value) i32 {
        const n = self.toNumber();
        if (std.math.isNan(n) or std.math.isInf(n)) return 0;
        const t = @trunc(n);
        const m = t - @floor(t / 4294967296.0) * 4294967296.0; // t mod 2^32, in [0, 2^32)
        return @bitCast(@as(u32, @intFromFloat(m)));
    }

    /// ECMAScript ToUint32 (the same bit pattern, read unsigned).
    pub fn toUint32(self: Value) u32 {
        return @bitCast(self.toInt32());
    }

    /// ECMAScript ToUint32 over an already-coerced Number (so a value object's
    /// valueOf/toString is run once by the caller via ToNumber, not again here).
    pub fn uint32FromF64(n: f64) u32 {
        if (std.math.isNan(n) or std.math.isInf(n)) return 0;
        const t = @trunc(n);
        const m = t - @floor(t / 4294967296.0) * 4294967296.0; // t mod 2^32
        return @intFromFloat(m);
    }

    /// The `typeof` operator result.
    pub fn typeOf(self: Value) []const u8 {
        return switch (self.kind()) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => if (self.asObj().is_htmldda) "undefined" else if (self.asObj().is_symbol) "symbol" else if (self.asObj().is_bigint) "bigint" else if (self.asObj().isCallableObject()) "function" else "object",
        };
    }

    /// ECMAScript ToString, allocating in `arena`.
    pub fn toString(self: Value, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return switch (self.kind()) {
            .undefined => "undefined",
            .null => "null",
            .boolean => if (self.asBool()) "true" else "false",
            .number => try numberToString(arena, self.asNum()),
            .string => self.asStr(),
            .object => if (self.asObj().is_bigint) try bigIntToString(self.asObj(), arena) else try objectToString(self.asObj(), arena),
        };
    }
};

test "Value is an engine-wide 8-byte NaN-boxed word" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Value) * 8);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const prev_arena = strcell.setActiveArena(arena_state.allocator());
    defer _ = strcell.setActiveArena(prev_arena);

    var object = Object{};
    const cases = [_]Value{
        Value.undef(),
        Value.nul(),
        Value.boolVal(true),
        Value.boolVal(false),
        Value.num(123.5),
        Value.num(std.math.nan(f64)),
        Value.str("nan-boxed"),
        Value.obj(&object),
    };

    try std.testing.expect(cases[0].isUndefined());
    try std.testing.expect(cases[1].isNull());
    try std.testing.expect(cases[2].isBoolean() and cases[2].asBool());
    try std.testing.expect(cases[3].isBoolean() and !cases[3].asBool());
    try std.testing.expect(cases[4].isNumber());
    try std.testing.expectEqual(@as(f64, 123.5), cases[4].asNum());
    try std.testing.expect(cases[5].isNumber());
    try std.testing.expect(std.math.isNan(cases[5].asNum()));
    try std.testing.expect(cases[6].isString());
    try std.testing.expectEqualStrings("nan-boxed", cases[6].asStr());
    try std.testing.expect(cases[7].isObject());
    try std.testing.expectEqual(&object, cases[7].asObj());
}

pub fn bigIntIsZero(o: *Object) bool {
    if (o.bigint_text) |s| return std.mem.eql(u8, s, "0");
    return o.bigint == 0;
}

pub fn bigIntToNumber(o: *Object) f64 {
    if (o.bigint_text) |s| return std.fmt.parseFloat(f64, s) catch if (s.len > 0 and s[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    return @floatFromInt(o.bigint);
}

pub fn bigIntToString(o: *Object, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    if (o.bigint_text) |s| return s;
    return std.fmt.allocPrint(arena, "{d}", .{o.bigint});
}

fn bigIntEquals(a: *Object, b: *Object) bool {
    if (a.bigint_text) |as| {
        if (b.bigint_text) |bs| return std.mem.eql(u8, as, bs);
        const parsed = std.fmt.parseInt(i128, as, 10) catch return false;
        return parsed == b.bigint;
    }
    if (b.bigint_text) |bs| {
        const parsed = std.fmt.parseInt(i128, bs, 10) catch return false;
        return a.bigint == parsed;
    }
    return a.bigint == b.bigint;
}

/// ECMAScript-ish ToString for objects: errors render `Name: message`, arrays
/// join their elements with commas (Array.prototype.toString), everything else
/// is `[object Object]`.
fn objectToString(o: *Object, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    // A primitive-wrapper object stringifies as its boxed primitive.
    if (o.prim) |p| return p.toString(arena);
    if (o.is_error) {
        const name = if (o.getOwn("name")) |v|
            (if (v.isString()) v.asStr() else o.error_name)
        else
            o.error_name;
        const msg = if (o.getOwn("message")) |v|
            (if (v.isString()) v.asStr() else "")
        else
            "";
        if (msg.len == 0) return name;
        return std.mem.concat(arena, u8, &.{ name, ": ", msg });
    }
    if (o.is_array) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (o.elements.items, 0..) |el, i| {
            if (i != 0) try buf.append(arena, ',');
            // null/undefined render as empty per Array.prototype.join.
            const part = switch (el.kind()) {
                .undefined, .null => "",
                else => try el.toString(arena),
            };
            try buf.appendSlice(arena, part);
        }
        return buf.toOwnedSlice(arena);
    }
    return "[object Object]";
}

/// ECMAScript ToString for numbers (best-effort; full Number::toString comes
/// with the test262 number slice). Integer-valued numbers print without a
/// trailing ".0" to match JS.
/// ToString(number) per ECMAScript Number::toString (radix 10): the shortest
/// decimal that round-trips, formatted with the spec's fixed/exponential
/// thresholds (n > 21 or n <= -6 use `e` notation). `1e21` → "1e+21",
/// `1e-7` → "1e-7", `0.001` → "0.001".
pub fn numberToString(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n < 0) "-Infinity" else "Infinity";
    if (n == 0) return "0";
    // Fast path: an exactly-representable integer always renders without
    // exponent (its `n` is <= 21), so plain decimal output matches the spec.
    if (@floor(n) == n and @abs(n) < 9.007199254740992e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }

    const negative = n < 0;
    // Shortest round-tripping scientific form "d.ddde±X" / "deX".
    var sbuf: [512]u8 = undefined;
    const sci = std.fmt.float.render(&sbuf, @abs(n), .{ .mode = .scientific, .precision = null }) catch return error.OutOfMemory;
    const e_idx = std.mem.indexOfScalar(u8, sci, 'e') orelse return std.fmt.allocPrint(arena, "{d}", .{n});
    const exp = std.fmt.parseInt(i32, sci[e_idx + 1 ..], 10) catch return error.OutOfMemory;

    // Mantissa significant digits (drop the '.'), with trailing zeros trimmed.
    var digbuf: [64]u8 = undefined;
    var k: usize = 0;
    for (sci[0..e_idx]) |c| {
        if (c == '.') continue;
        digbuf[k] = c;
        k += 1;
    }
    while (k > 1 and digbuf[k - 1] == '0') k -= 1;
    const digits = digbuf[0..k];
    const ki: i32 = @intCast(k);
    const np: i32 = exp + 1; // the spec's `n`: value = digits × 10^(n-k)

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (negative) try out.append(arena, '-');
    if (np >= ki and np <= 21) {
        // Integer: all k digits, then (n-k) trailing zeros.
        try out.appendSlice(arena, digits);
        try out.appendNTimes(arena, '0', @intCast(np - ki));
    } else if (np > 0 and np <= 21) {
        // Decimal point inside the digit run.
        try out.appendSlice(arena, digits[0..@intCast(np)]);
        try out.append(arena, '.');
        try out.appendSlice(arena, digits[@intCast(np)..]);
    } else if (np > -6 and np <= 0) {
        // Leading "0.000…" then all the digits.
        try out.appendSlice(arena, "0.");
        try out.appendNTimes(arena, '0', @intCast(-np));
        try out.appendSlice(arena, digits);
    } else {
        // Exponential: first digit, optional fraction, then `e±(n-1)`.
        try out.append(arena, digits[0]);
        if (k > 1) {
            try out.append(arena, '.');
            try out.appendSlice(arena, digits[1..]);
        }
        try out.append(arena, 'e');
        const e2 = np - 1;
        try out.append(arena, if (e2 >= 0) '+' else '-');
        var ebuf: [12]u8 = undefined;
        try out.appendSlice(arena, std.fmt.bufPrint(&ebuf, "{d}", .{@abs(e2)}) catch unreachable);
    }
    return out.toOwnedSlice(arena);
}

fn isStringNumberWhitespace(cp: u21) bool {
    return switch (cp) {
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

fn trimStringNumberWhitespace(s: []const u8) []const u8 {
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    var start: usize = 0;
    var end: usize = 0;
    var seen_non_ws = false;
    const base = @intFromPtr(s.ptr);
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
        if (isStringNumberWhitespace(cp)) continue;
        const off = @intFromPtr(slice.ptr) - base;
        if (!seen_non_ws) {
            start = off;
            seen_non_ws = true;
        }
        end = off + slice.len;
    }
    if (!seen_non_ws) return s[0..0];
    return s[start..end];
}

/// Parse a string to a number per ToNumber(string): trims ECMAScript
/// StrWhiteSpace, empty string is 0, otherwise float parse or NaN.
pub fn stringToNumber(s: []const u8) f64 {
    const nan = std.math.nan(f64);
    const trimmed = trimStringNumberWhitespace(s);
    if (trimmed.len == 0) return 0;
    // Numeric separators (`_`) are a *source* lexical feature and never valid in
    // a runtime ToNumber(String) — `Number("1_0")` is NaN, not 10. (Zig's
    // parseFloat would otherwise accept them.)
    if (std.mem.indexOfScalar(u8, trimmed, '_') != null) return nan;
    // `Infinity` with an optional sign and exact casing (Zig also accepts
    // "inf"/"infinity"/"nan", which JS does not).
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    // Non-decimal integer literals: `0x`/`0o`/`0b` (unsigned, no sign, no '.').
    if (trimmed.len > 2 and trimmed[0] == '0') {
        const radix: ?u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            var acc: f64 = 0;
            for (trimmed[2..]) |c| {
                const d = std.fmt.charToDigit(c, r) catch return nan;
                acc = acc * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(d));
            }
            return acc;
        }
    }
    // A decimal literal: restrict to the StrDecimalLiteral character set so Zig's
    // parseFloat can't accept its extensions (hex floats, "inf"/"nan"); the parse
    // still rejects malformed combinations (e.g. "1e", "1.2.3") as NaN.
    for (trimmed) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return nan,
    };
    return std.fmt.parseFloat(f64, trimmed) catch nan;
}

/// Strict equality (===).
pub fn strictEquals(a: Value, b: Value) bool {
    return switch (a.kind()) {
        .undefined => b.isUndefined(),
        .null => b.isNull(),
        .boolean => b.isBoolean() and b.asBool() == a.asBool(),
        .number => b.isNumber() and b.asNum() == a.asNum(),
        .string => b.isString() and std.mem.eql(u8, a.asStr(), b.asStr()),
        // BigInt is a primitive: `===` compares its value, not object identity.
        .object => if (a.asObj().is_bigint)
            (b.isObject() and b.asObj().is_bigint and bigIntEquals(a.asObj(), b.asObj()))
        else
            (b.isObject() and b.asObj() == a.asObj() and !b.asObj().is_bigint),
    };
}

/// SameValueZero: strict equality except NaN equals NaN (and +0 equals -0).
/// Used by `Array.prototype.includes` and Map/Set key comparison.
pub fn sameValueZero(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        if (std.math.isNan(a.asNum()) and std.math.isNan(b.asNum())) return true;
        return a.asNum() == b.asNum();
    }
    return strictEquals(a, b);
}

/// Abstract Equality Comparison (==), simplified for the v1 value set.
pub fn looseEquals(a: Value, b: Value) bool {
    if (a.kind() == b.kind()) {
        return strictEquals(a, b);
    }
    if ((a.isNull() and b.isUndefined()) or (a.isUndefined() and b.isNull())) return true;
    // An [[IsHTMLDDA]] object is loosely equal to null and undefined.
    if ((a.isObject() and a.asObj().is_htmldda) and (b.isNull() or b.isUndefined())) return true;
    if ((b.isObject() and b.asObj().is_htmldda) and (a.isNull() or a.isUndefined())) return true;
    // BigInt == Number/Boolean/String: compare mathematically (a string is parsed
    // to a BigInt; a non-integer/unparseable comparand is unequal).
    const a_big = a.isObject() and a.asObj().is_bigint;
    const b_big = b.isObject() and b.asObj().is_bigint;
    if (a_big != b_big) {
        const big_obj = if (a_big) a.asObj() else b.asObj();
        const other = if (a_big) b else a;
        if (big_obj.bigint_text != null) {
            return switch (other.kind()) {
                .string => std.mem.eql(u8, std.mem.trim(u8, other.asStr(), " \t\r\n"), big_obj.bigint_text.?),
                else => false,
            };
        }
        const big: i128 = big_obj.bigint;
        return switch (other.kind()) {
            .number => @as(f64, @floatFromInt(big)) == other.asNum(),
            .boolean => big == @as(i128, if (other.asBool()) 1 else 0),
            .string => if (std.fmt.parseInt(i128, std.mem.trim(u8, other.asStr(), " \t\r\n"), 10)) |p| p == big else |_| false,
            else => false,
        };
    }
    switch (a.kind()) {
        .number, .string, .boolean => switch (b.kind()) {
            .number, .string, .boolean => return a.toNumber() == b.toNumber(),
            else => {},
        },
        else => {},
    }
    return false;
}

test "object named properties serialize concurrent same-name writes" {
    const root = try Shape.createRoot(std.heap.page_allocator);
    var object = Object{};

    const Worker = struct {
        fn run(o: *Object, root_shape: *Shape, n: usize) void {
            o.setOwn(std.heap.page_allocator, root_shape, "shared", Value.num(@floatFromInt(n))) catch @panic("setOwn failed");
            _ = o.getOwn("shared") orelse @panic("missing shared property");
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &object, root, i });
    }
    for (threads) |thread| thread.join();

    const value = object.getOwn("shared") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), object.slots.items.len);
    try std.testing.expectEqual(@as(?u32, 0), object.shape.?.lookup("shared"));
    try std.testing.expect(value.isNumber());
}

test "object named property delete rebuild serializes with writers" {
    const root = try Shape.createRoot(std.heap.page_allocator);
    var object = Object{};
    try object.setOwn(std.heap.page_allocator, root, "anchor", Value.num(1));

    const Worker = struct {
        fn run(o: *Object, root_shape: *Shape, n: usize) void {
            if ((n & 1) == 0) {
                o.setOwn(std.heap.page_allocator, root_shape, "shared", Value.num(@floatFromInt(n))) catch @panic("setOwn failed");
            } else {
                _ = o.deleteNamedDataOwn(std.heap.page_allocator, root_shape, "shared") catch @panic("deleteNamedDataOwn failed");
            }
        }
    };

    var threads: [16]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &object, root, i });
    }
    for (threads) |thread| thread.join();

    try std.testing.expect(object.getOwn("anchor") != null);
    var count: usize = 0;
    var shape = object.shape;
    while (shape) |s| {
        if (s.name != null) count += 1;
        shape = s.parent;
    }
    try std.testing.expectEqual(count, object.slots.items.len);
}

// ---- no-GIL regression tests (issue #1): the atomic/seqlock primitives that
// keep the corpus TSan-clean. Run under `-Dtsan=true` to also catch data races;
// without TSan they still catch torn reads / crashes / corruption. ----

test "Object.proto atomic read survives concurrent setPrototypeOf" {
    var a = Object{};
    var b = Object{};
    var o = Object{ .proto = &a };
    const Worker = struct {
        fn reader(target: *Object, pa: *Object, pb: *Object, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.monotonic)) {
                const p = target.protoAtomic();
                // Must always be one of the two valid protos (never a torn ptr).
                if (p != pa and p != pb) @panic("proto torn read");
            }
        }
        fn writer(target: *Object, pa: *Object, pb: *Object, stop: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < 200_000) : (i += 1) target.setProtoAtomic(if ((i & 1) == 0) pa else pb);
            stop.store(true, .release);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var readers: [4]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, Worker.reader, .{ &o, &a, &b, &stop });
    const w = try std.Thread.spawn(.{}, Worker.writer, .{ &o, &a, &b, &stop });
    w.join();
    for (readers) |t| t.join();
    const final = o.protoAtomic();
    try std.testing.expect(final == &a or final == &b);
}

test "ArrayBufferData.bytes seqlock stays consistent across concurrent resize swaps" {
    const prev = Object.element_locks_enabled.swap(true, .release);
    defer Object.element_locks_enabled.store(prev, .release);
    var sa: [16]u8 = undefined;
    @memset(&sa, 0xAA);
    var sb: [128]u8 = undefined;
    @memset(&sb, 0xBB);
    var ab = ArrayBufferData{ .local_data = sa[0..] };
    const Worker = struct {
        fn reader(buf: *ArrayBufferData, pa: [*]u8, pb: [*]u8, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.monotonic)) {
                const s = buf.bytes();
                // ptr and len must always agree (seqlock): A is 16 bytes, B is 128.
                const ok = (s.ptr == pa and s.len == 16) or (s.ptr == pb and s.len == 128);
                if (!ok) @panic("bytes() torn ptr/len");
            }
        }
        fn writer(buf: *ArrayBufferData, a: []u8, b: []u8, stop: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < 200_000) : (i += 1) buf.swapLocalData(if ((i & 1) == 0) a else b);
            stop.store(true, .release);
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var readers: [4]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, Worker.reader, .{ &ab, sa[0..].ptr, sb[0..].ptr, &stop });
    const w = try std.Thread.spawn(.{}, Worker.writer, .{ &ab, sa[0..], sb[0..], &stop });
    w.join();
    for (readers) |t| t.join();
}

test "Object backing lock pairs unlock with actual acquisition" {
    var o = Object{};

    const prev = Object.element_locks_enabled.swap(false, .release);
    const not_locked = o.lockBacking();
    Object.element_locks_enabled.store(true, .release);
    o.unlockBacking(not_locked);

    const locked = o.lockBacking();
    Object.element_locks_enabled.store(false, .release);
    o.unlockBacking(locked);
    defer Object.element_locks_enabled.store(prev, .release);

    try std.testing.expect(o.backing_lock.tryLock());
    o.backing_lock.unlock();
}

test "Object.has_indexed_property atomic flag converges under concurrent set" {
    var o = Object{};
    const Worker = struct {
        fn run(target: *Object) void {
            var i: usize = 0;
            while (i < 100_000) : (i += 1) {
                if ((i & 1) == 0) target.has_indexed_property.store(true, .monotonic) else _ = target.has_indexed_property.load(.monotonic);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&o});
    for (threads) |t| t.join();
    try std.testing.expect(o.has_indexed_property.load(.acquire));
}

test "Object.restricted_to CAS lets exactly one concurrent claimer win" {
    var o = Object{};
    const Worker = struct {
        fn run(target: *Object, my_tid: u64, won: *std.atomic.Value(u32)) void {
            // Mirror Thread.restrict's claim: CAS 0 -> tid; null means we won.
            if (target.restricted_to.cmpxchgStrong(0, my_tid, .acq_rel, .acquire) == null)
                _ = won.fetchAdd(1, .acq_rel);
        }
    };
    var won = std.atomic.Value(u32).init(0);
    var threads: [16]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &o, @as(u64, i) + 1, &won });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 1), won.load(.acquire));
    try std.testing.expect(o.restricted_to.load(.acquire) != 0);
}

test "WeakMap and WeakSet entry delete is unordered tail removal" {
    const a = std.testing.allocator;
    var o = Object{ .is_weak = true, .is_map = true };
    defer o.weak_entries.deinit(a);
    defer o.weak_index.deinit(a);

    var key1: u8 = 1;
    var key2: u8 = 2;
    var key3: u8 = 3;
    try o.weakEntrySet(a, @ptrCast(&key1), Value.num(1));
    try o.weakEntrySet(a, @ptrCast(&key2), Value.num(2));
    try o.weakEntrySet(a, @ptrCast(&key3), Value.num(3));

    try std.testing.expect(o.weakEntryDelete(@ptrCast(&key1)));
    try std.testing.expectEqual(@as(usize, 2), o.weak_entries.items.len);
    try std.testing.expect(!o.weakEntryHas(@ptrCast(&key1)));
    try std.testing.expect(o.weakEntryHas(@ptrCast(&key2)));
    try std.testing.expect(o.weakEntryHas(@ptrCast(&key3)));
    try std.testing.expectEqual(@intFromPtr(&key3), @intFromPtr(o.weak_entries.items[0].key.?));
}

test "FinalizationRegistry unregister stable-compacts matching records" {
    const a = std.testing.allocator;
    var o = Object{ .is_finalization_registry = true };
    defer o.finalization_records.deinit(a);

    var token_a: u8 = 1;
    var token_b: u8 = 2;
    var token_c: u8 = 3;
    var target1: u8 = 11;
    var target2: u8 = 12;
    var target3: u8 = 13;
    var target4: u8 = 14;
    var target5: u8 = 15;
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target1), .held = Value.num(1), .token = @ptrCast(&token_a) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target2), .held = Value.num(2), .token = @ptrCast(&token_b) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target3), .held = Value.num(3), .token = @ptrCast(&token_a) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target4), .held = Value.num(4), .token = @ptrCast(&token_c) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target5), .held = Value.num(5), .token = @ptrCast(&token_a) });

    try std.testing.expect(o.finRecordUnregister(@ptrCast(&token_a)));
    try std.testing.expectEqual(@as(usize, 2), o.finalization_records.items.len);
    try std.testing.expectEqual(@as(f64, 2), o.finalization_records.items[0].held.asNum());
    try std.testing.expectEqual(@as(f64, 4), o.finalization_records.items[1].held.asNum());
    try std.testing.expectEqual(@intFromPtr(&token_b), @intFromPtr(o.finalization_records.items[0].token.?));
    try std.testing.expectEqual(@intFromPtr(&token_c), @intFromPtr(o.finalization_records.items[1].token.?));

    var missing: u8 = 4;
    try std.testing.expect(!o.finRecordUnregister(@ptrCast(&missing)));
    try std.testing.expect(o.finRecordUnregister(@ptrCast(&token_b)));
    try std.testing.expectEqual(@as(usize, 1), o.finalization_records.items.len);
    try std.testing.expectEqual(@as(f64, 4), o.finalization_records.items[0].held.asNum());
}
