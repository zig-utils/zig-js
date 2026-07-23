const std = @import("std");
const Shape = @import("shape.zig").Shape;
const SharedBufferStorage = @import("shared_buffer.zig").SharedBufferStorage;
const gc_runtime = @import("gc_runtime.zig");
const object_profile = @import("object_profile.zig");
const strcell = @import("strcell.zig");
const StringCell = strcell.StringCell;

/// GC insertion barrier for a `Value` stored into a live cell. It records an
/// old-to-young edge for minor collection and shades the child during an active
/// incremental/full mark. Runtime strings may also carry a GC-managed cell;
/// static, arena, and interned strings explicitly remain outside the heap.
inline fn gcBarrier(owner: *Object, v: Value) void {
    if (v.isObject()) {
        gc_runtime.barrierFrom(@ptrCast(owner), @ptrCast(v.asObj()));
    } else if (v.isString()) {
        const cell = v.asStringCell();
        if (cell.isGcManaged()) gc_runtime.barrierFrom(@ptrCast(owner), @ptrCast(@constCast(cell)));
    }
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

/// Live JavaScript references held only by an active WebAssembly invocation.
/// The Wasm executor refreshes this stable descriptor before every GC
/// checkpoint; the active Interpreter then publishes it through the same
/// precise-root path as VM operand stacks and frame locals.
pub const WasmException = struct {
    tag: *anyopaque,
    payload: []const WasmSlot,
    externrefs: []const Value,
    owner: *anyopaque,
    /// Stable JS identity for a WebAssembly.Exception. Native exceptions fill
    /// this lazily when they cross into JS; JS-constructed exceptions set it
    /// immediately. The owning exception root list traces the object.
    wrapper: std.atomic.Value(?*Object) = .init(null),
    /// Payload for the built-in JSTag transport. Such exceptions escape back
    /// to JavaScript as the original thrown value, not a wrapper.
    js_exception: Value = Value.undef(),
    is_js_exception: bool = false,
    next: ?*WasmException = null,
    published: bool = false,
};

pub const WasmGcMarkValueFn = *const fn (*anyopaque, Value) void;
pub const WasmGcRewriteValueFn = *const fn (*anyopaque, *Value) void;
pub const WasmGcReleaseFn = *const fn (*anyopaque, *Object) void;
pub const WasmGcTraceRootsFn = *const fn (*anyopaque, *anyopaque, WasmGcMarkValueFn) void;
pub const WasmGcRelocateRootsFn = *const fn (*anyopaque, *anyopaque, WasmGcRewriteValueFn) void;

/// Type-erased tracing header embedded in every runtime-owned Wasm GC
/// aggregate. Core GC can precisely visit nested JavaScript references
/// without importing the WebAssembly executor (or knowing its object layout).
pub const WasmGcRef = struct {
    context: *anyopaque,
    trace: *const fn (*WasmGcRef, *anyopaque, WasmGcMarkValueFn) void,
    relocate: *const fn (*WasmGcRef, *anyopaque, WasmGcRewriteValueFn) void,
};

pub const WasmSlot = union(enum) {
    numeric: u64,
    vector: u128,
    funcref: ?*anyopaque,
    exnref: ?*WasmException,
    externref: Value,
    /// Host reference after `any.convert_extern` removes the external wrapper.
    hostref: Value,
    /// Unboxed low 31 bits for the Wasm GC i31 hierarchy.
    i31ref: u32,
    /// Struct/array identity. The concrete aggregate remains runtime-owned;
    /// this header exposes only precise host-GC tracing.
    gcref: ?*WasmGcRef,
    /// Internal references wrapped by `extern.convert_any`.
    externalized_gcref: *WasmGcRef,
    externalized_i31: u32,

    pub fn numericBits(self: WasmSlot) u64 {
        return switch (self) {
            .numeric => |bits| bits,
            else => unreachable,
        };
    }

    pub fn vectorBits(self: WasmSlot) u128 {
        return switch (self) {
            .vector => |bits| bits,
            else => unreachable,
        };
    }
};

pub const WasmExecutionRoots = struct {
    stack: []const WasmSlot = &.{},
    locals: []const WasmSlot = &.{},
    exceptions: []const *WasmException = &.{},
};

pub const HostClassGetResult = union(enum) {
    unhandled,
    value: Value,
};

pub const HostClassSetResult = union(enum) {
    unhandled,
    declined,
    accepted: bool,
};

pub const HostClassDeleteResult = union(enum) {
    unhandled,
    accepted: bool,
};

pub const HostClassConvertHint = enum { number, string };

/// Type-erased essential-internal-method bridge for embedding-defined classes.
/// The Interpreter pointer is opaque here to avoid a value/interpreter import
/// cycle; C-API implementations cast it back at the boundary.
pub const HostClassHooks = struct {
    get: ?*const fn (*anyopaque, *Object, []const u8) HostError!HostClassGetResult = null,
    set: ?*const fn (*anyopaque, *Object, []const u8, Value) HostError!HostClassSetResult = null,
    has: ?*const fn (*anyopaque, *Object, []const u8) HostError!bool = null,
    delete: ?*const fn (*anyopaque, *Object, []const u8) HostError!HostClassDeleteResult = null,
    attributes: ?*const fn (*anyopaque, *Object, []const u8) HostError!?PropAttr = null,
    own_keys: ?*const fn (*anyopaque, *Object) HostError![]const []const u8 = null,
    is_callable: ?*const fn (*const Object) bool = null,
    is_constructor: ?*const fn (*const Object) bool = null,
    call: ?*const fn (*anyopaque, *Object, Value, []const Value) HostError!Value = null,
    construct: ?*const fn (*anyopaque, *Object, []const Value) HostError!Value = null,
    has_instance: ?*const fn (*anyopaque, *Object, Value) HostError!bool = null,
    convert: ?*const fn (*anyopaque, *Object, HostClassConvertHint) HostError!Value = null,
};

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

/// Ownership record for an embedder-supplied ArrayBuffer backing store. The
/// record is context-owned (not cell-owned) so arena contexts can release it at
/// teardown while GC contexts may release it earlier from the object finalizer.
/// `release` is idempotent because both paths can observe the same record.
pub const ExternalBufferDeallocator = *const fn (bytes: ?*anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void;

pub const ExternalBufferLease = struct {
    bytes: ?*anyopaque,
    deallocator: ?ExternalBufferDeallocator,
    deallocator_context: ?*anyopaque,
};

pub const ExternalBufferOwner = struct {
    bytes: ?*anyopaque,
    deallocator: ?ExternalBufferDeallocator,
    deallocator_context: ?*anyopaque,
    released: std.atomic.Value(bool) = .init(false),
    release_queued: std.atomic.Value(bool) = .init(false),
    pending_next: ?*ExternalBufferOwner = null,

    pub fn release(self: *ExternalBufferOwner) bool {
        if (self.released.swap(true, .acq_rel)) return false;
        if (self.deallocator) |deallocator| deallocator(self.bytes, self.deallocator_context);
        return true;
    }

    /// Transfer the callback obligation into a backing handle without running
    /// it. Context teardown then sees an already-released owner while the
    /// independently refcounted handle may outlive the VM.
    pub fn take(self: *ExternalBufferOwner) ?ExternalBufferLease {
        if (self.released.swap(true, .acq_rel)) return null;
        return .{
            .bytes = self.bytes,
            .deallocator = self.deallocator,
            .deallocator_context = self.deallocator_context,
        };
    }
};

/// Opaque native equivalent of JSC's independently refcounted ArrayBuffer
/// backing object. It has three ownership domains: the JS wrapper, the owning
/// Context's tracking list, and the generated binding's transferred +1. Native
/// ref/deref operations touch only `external_refs`, so an imbalanced consumer
/// cannot steal the wrapper/tracker references before an underflow is detected.
pub const NativeArrayBufferHandle = struct {
    const global_allocator = std.heap.page_allocator;

    const Storage = union(enum) {
        owned: []u8,
        external: struct {
            lease: ExternalBufferLease,
            len: usize,
        },
        shared: *SharedBufferStorage,
    };

    refcount: std.atomic.Value(usize) = .init(3),
    external_refs: std.atomic.Value(usize) = .init(1),
    wrapper_released: std.atomic.Value(bool) = .init(false),
    tracking_released: std.atomic.Value(bool) = .init(false),
    lock: std.atomic.Mutex = .unlocked,
    storage: Storage,
    max_byte_length: ?usize,
    shared: bool = false,

    pub fn createOwned(bytes: []const u8, max_byte_length: ?usize) error{OutOfMemory}!*NativeArrayBufferHandle {
        const self = try global_allocator.create(NativeArrayBufferHandle);
        errdefer global_allocator.destroy(self);
        const copy = try global_allocator.alloc(u8, bytes.len);
        errdefer global_allocator.free(copy);
        @memcpy(copy, bytes);
        self.* = .{ .storage = .{ .owned = copy }, .max_byte_length = max_byte_length };
        return self;
    }

    pub fn createExternal(bytes: []u8, max_byte_length: ?usize) error{OutOfMemory}!*NativeArrayBufferHandle {
        const self = try global_allocator.create(NativeArrayBufferHandle);
        self.* = .{
            .storage = .{ .external = .{
                .lease = .{
                    .bytes = if (bytes.len == 0) null else bytes.ptr,
                    .deallocator = null,
                    .deallocator_context = null,
                },
                .len = bytes.len,
            } },
            .max_byte_length = max_byte_length,
        };
        return self;
    }

    pub fn createShared(storage: *SharedBufferStorage) error{OutOfMemory}!*NativeArrayBufferHandle {
        const retained = storage.tryRetain() orelse return error.OutOfMemory;
        errdefer retained.release();
        const self = try global_allocator.create(NativeArrayBufferHandle);
        self.* = .{
            .storage = .{ .shared = retained },
            .max_byte_length = if (storage.growable) storage.capacity else null,
            .shared = true,
        };
        return self;
    }

    pub fn armExternal(self: *NativeArrayBufferHandle, lease: ExternalBufferLease) void {
        self.lockHandle();
        defer self.lock.unlock();
        std.debug.assert(self.storage == .external);
        self.storage.external.lease = lease;
    }

    pub fn tryRetainExternal(self: *NativeArrayBufferHandle) bool {
        var total = self.refcount.load(.acquire);
        while (true) {
            if (total == 0 or total == std.math.maxInt(usize)) return false;
            if (self.refcount.cmpxchgWeak(total, total + 1, .acq_rel, .acquire)) |observed| {
                total = observed;
                continue;
            }
            break;
        }
        var external = self.external_refs.load(.acquire);
        while (true) {
            if (external == std.math.maxInt(usize)) {
                self.releaseTotal();
                return false;
            }
            if (self.external_refs.cmpxchgWeak(external, external + 1, .acq_rel, .acquire)) |observed| {
                external = observed;
                continue;
            }
            return true;
        }
    }

    pub fn releaseExternal(self: *NativeArrayBufferHandle) bool {
        var current = self.external_refs.load(.acquire);
        while (true) {
            if (current == 0) return false;
            if (self.external_refs.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |observed| {
                current = observed;
                continue;
            }
            self.releaseTotal();
            return true;
        }
    }

    pub fn releaseWrapper(self: *NativeArrayBufferHandle) void {
        if (!self.wrapper_released.swap(true, .acq_rel)) self.releaseTotal();
    }

    pub fn releaseTracking(self: *NativeArrayBufferHandle) void {
        if (!self.tracking_released.swap(true, .acq_rel)) self.releaseTotal();
    }

    fn releaseTotal(self: *NativeArrayBufferHandle) void {
        if (self.refcount.fetchSub(1, .release) != 1) return;
        _ = self.refcount.load(.acquire);
        self.destroy();
    }

    fn destroy(self: *NativeArrayBufferHandle) void {
        switch (self.storage) {
            .owned => |bytes| global_allocator.free(bytes),
            .external => |entry| if (entry.lease.deallocator) |deallocator|
                deallocator(entry.lease.bytes, entry.lease.deallocator_context),
            .shared => |storage| storage.release(),
        }
        global_allocator.destroy(self);
    }

    fn lockHandle(self: *NativeArrayBufferHandle) void {
        var spins: usize = 0;
        while (!self.lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn snapshotBytes(self: *NativeArrayBufferHandle) []u8 {
        self.lockHandle();
        defer self.lock.unlock();
        return switch (self.storage) {
            .owned => |bytes| bytes,
            .external => |entry| if (entry.lease.bytes) |ptr| @as([*]u8, @ptrCast(ptr))[0..entry.len] else &.{},
            .shared => |storage| storage.slice(),
        };
    }

    pub fn isShared(self: *const NativeArrayBufferHandle) bool {
        return self.shared;
    }

    pub fn isResizable(self: *const NativeArrayBufferHandle) bool {
        return self.max_byte_length != null;
    }

    pub fn resize(self: *NativeArrayBufferHandle, new_len: usize) error{ OutOfMemory, NotResizable, OutOfRange }!void {
        const max = self.max_byte_length orelse return error.NotResizable;
        if (new_len > max) return error.OutOfRange;
        self.lockHandle();
        defer self.lock.unlock();
        switch (self.storage) {
            .owned => |old| {
                const fresh = try global_allocator.alloc(u8, new_len);
                @memset(fresh, 0);
                @memcpy(fresh[0..@min(old.len, fresh.len)], old[0..@min(old.len, fresh.len)]);
                self.storage = .{ .owned = fresh };
                global_allocator.free(old);
            },
            else => return error.NotResizable,
        }
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
    /// Fixed byte length for a SharedArrayBuffer view over a larger shared
    /// slab. WebAssembly.Memory replaces its buffer on grow without detaching
    /// the old one, so every historical wrapper retains its creation length.
    /// Null is the normal growable-SAB behavior: read the storage's live size.
    shared_fixed_byte_length: ?usize = null,
    /// Metadata and `local_data` are owned by the GC finalizer rather than the
    /// arena. Shared buffers set this for the metadata only; their bytes are
    /// owned by `SharedBufferStorage`.
    gc_owned: bool = false,
    /// Non-null for C-API no-copy buffers. The owner record outlives this
    /// metadata and invokes the embedder deallocator exactly once, either from
    /// the GC finalizer or from Context teardown in arena mode.
    external_owner: ?*ExternalBufferOwner = null,
    /// Lazily installed when a generated IDLArrayBufferRef binding transfers a
    /// native +1. The handle owns a backing that can outlive this wrapper/VM.
    native_handle: std.atomic.Value(?*NativeArrayBufferHandle) = .init(null),
    detached_flag: std.atomic.Value(bool) = .init(false),
    /// For a resizable ArrayBuffer (or growable SharedArrayBuffer), the maximum
    /// byte length; null means fixed-length (not resizable/growable).
    max_byte_length: ?usize = null,
    /// A SharedArrayBuffer (never detaches; `grow` only increases length).
    is_shared: bool = false,
    /// An immutable ArrayBuffer (from `transferToImmutable`/`sliceToImmutable`):
    /// fixed-length, never detaches, and rejects every write.
    immutable: bool = false,
    /// The live buffer exposed by a WebAssembly.Memory. Ordinary JS transfer
    /// operations must not detach it; only Memory.grow may replace/detach it.
    is_wasm_memory: bool = false,

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
        if (self.shared) |s| return if (self.shared_fixed_byte_length) |len| s.fixedSlice(len) else s.slice();
        if (@constCast(&self.native_handle).load(.acquire)) |handle| return handle.snapshotBytes();
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

    /// Read ordinary (non-`Atomics`) bytes from a buffer. Shared bytes use
    /// monotonic byte atomics so overlapping ordinary/atomic accesses are a
    /// defined host operation and remain visible to ThreadSanitizer. Reading
    /// one byte at a time deliberately preserves JavaScript's permitted
    /// tearing for multi-byte ordinary accesses.
    pub fn readUnordered(self: *const ArrayBufferData, bytes_: []const u8, offset: usize, len: usize, endian: std.builtin.Endian) u64 {
        var raw: u64 = 0;
        for (0..len) |i| {
            const source = if (endian == .little) i else len - 1 - i;
            const byte = if (self.is_shared)
                @atomicLoad(u8, @constCast(&bytes_[offset + source]), .monotonic)
            else
                bytes_[offset + source];
            raw |= @as(u64, byte) << @intCast(i * 8);
        }
        return raw;
    }

    /// Write ordinary bytes, paired with `readUnordered`. Each shared byte is
    /// independently atomic; the complete multi-byte value is not.
    pub fn writeUnordered(self: *const ArrayBufferData, bytes_: []u8, offset: usize, len: usize, endian: std.builtin.Endian, raw: u64) void {
        for (0..len) |i| {
            const dest = if (endian == .little) i else len - 1 - i;
            const byte: u8 = @truncate(raw >> @intCast(i * 8));
            if (self.is_shared)
                @atomicStore(u8, &bytes_[offset + dest], byte, .monotonic)
            else
                bytes_[offset + dest] = byte;
        }
    }
};

/// Memmove between ArrayBuffer byte ranges without introducing host data races
/// when either backing is shared. Pointer ordering also handles two distinct
/// SharedArrayBuffer wrappers over the same storage.
pub fn copyArrayBufferBytes(dest_buf: *ArrayBufferData, dest_bytes: []u8, dest_offset: usize, source_buf: *const ArrayBufferData, source_bytes: []const u8, source_offset: usize, len: usize) void {
    if (!dest_buf.is_shared and !source_buf.is_shared) {
        const to = dest_bytes[dest_offset..][0..len];
        const from = source_bytes[source_offset..][0..len];
        if (@intFromPtr(to.ptr) <= @intFromPtr(from.ptr))
            std.mem.copyForwards(u8, to, from)
        else
            std.mem.copyBackwards(u8, to, from);
        return;
    }

    const dest_address = @intFromPtr(dest_bytes.ptr + dest_offset);
    const source_address = @intFromPtr(source_bytes.ptr + source_offset);
    if (dest_address > source_address and dest_address < source_address + len) {
        var i = len;
        while (i > 0) {
            i -= 1;
            dest_buf.writeUnordered(dest_bytes, dest_offset + i, 1, .little, source_buf.readUnordered(source_bytes, source_offset + i, 1, .little));
        }
    } else {
        for (0..len) |i|
            dest_buf.writeUnordered(dest_bytes, dest_offset + i, 1, .little, source_buf.readUnordered(source_bytes, source_offset + i, 1, .little));
    }
}

pub fn writeArrayBufferBytes(dest_buf: *ArrayBufferData, dest_bytes: []u8, dest_offset: usize, source: []const u8) void {
    if (!dest_buf.is_shared) {
        @memcpy(dest_bytes[dest_offset..][0..source.len], source);
        return;
    }
    for (source, 0..) |byte, i| dest_buf.writeUnordered(dest_bytes, dest_offset + i, 1, .little, byte);
}

fn taOrdinaryReadRaw(buf: *const ArrayBufferData, bytes_: []u8, offset: usize, kind: TAKind) u64 {
    if (!buf.is_shared) return buf.readUnordered(bytes_, offset, kind.byteSize(), .little);
    const p = bytes_.ptr + offset;
    // ECMAScript IsNoTearConfiguration requires unordered integer TypedArray
    // elements (other than the one-byte clamped distinction) to be read as one
    // no-tear event. Float and BigInt unordered reads may tear byte-by-byte.
    return switch (kind) {
        .i8, .u8, .u8c => @atomicLoad(u8, @as(*u8, @ptrCast(p)), .monotonic),
        .i16, .u16 => @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(p))), .monotonic),
        .i32, .u32 => @atomicLoad(u32, @as(*u32, @ptrCast(@alignCast(p))), .monotonic),
        else => buf.readUnordered(bytes_, offset, kind.byteSize(), .little),
    };
}

fn taOrdinaryWriteRaw(buf: *const ArrayBufferData, bytes_: []u8, offset: usize, kind: TAKind, raw: u64) void {
    if (!buf.is_shared) {
        buf.writeUnordered(bytes_, offset, kind.byteSize(), .little, raw);
        return;
    }
    const p = bytes_.ptr + offset;
    switch (kind) {
        .i8, .u8, .u8c => @atomicStore(u8, @as(*u8, @ptrCast(p)), @truncate(raw), .monotonic),
        .i16, .u16 => @atomicStore(u16, @as(*u16, @ptrCast(@alignCast(p))), @truncate(raw), .monotonic),
        .i32, .u32 => @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(p))), @truncate(raw), .monotonic),
        else => buf.writeUnordered(bytes_, offset, kind.byteSize(), .little, raw),
    }
}

test "ArrayBuffer ordinary shared accesses are host-race-free" {
    const storage = try SharedBufferStorage.create(64, null);
    defer storage.release();
    var buffer = ArrayBufferData{
        .local_data = &.{},
        .shared = storage,
        .is_shared = true,
    };
    var start = std.atomic.Value(bool).init(false);

    const AtomicSide = struct {
        fn run(shared: *SharedBufferStorage, ready: *std.atomic.Value(bool)) void {
            const words: [*]u32 = @ptrCast(@alignCast(shared.slice().ptr));
            while (!ready.load(.acquire)) std.atomic.spinLoopHint();
            for (0..20_000) |i| {
                @atomicStore(u32, &words[0], @truncate(i), .seq_cst);
                _ = @atomicLoad(u32, &words[2], .seq_cst);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, AtomicSide.run, .{ storage, &start });
    start.store(true, .release);
    const bytes_ = buffer.bytes();
    for (0..20_000) |i| {
        _ = taOrdinaryReadRaw(&buffer, bytes_, 0, .u32);
        taOrdinaryWriteRaw(&buffer, bytes_, 8, .u32, i);
        writeArrayBufferBytes(&buffer, bytes_, 16, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
        copyArrayBufferBytes(&buffer, bytes_, 17, &buffer, bytes_, 16, 7);
    }
    thread.join();

    try std.testing.expect(buffer.readUnordered(bytes_, 0, 4, .little) < 20_000);
}

/// Read typed-array element `i` (within bounds, buffer attached) as a Number.
pub fn taRead(ta: *const TypedArrayData, i: usize) Value {
    const buf = ta.buffer.arrayBuffer().?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    // A resizable buffer may have shrunk below the view's cached length; reading
    // out of bounds returns 0 rather than a panic.
    if (off + ta.kind.byteSize() > bytes.len) return Value.num(0);
    const raw = taOrdinaryReadRaw(buf, bytes, off, ta.kind);
    const n: f64 = switch (ta.kind) {
        .i8 => @floatFromInt(@as(i8, @bitCast(@as(u8, @truncate(raw))))),
        .u8, .u8c => @floatFromInt(@as(u8, @truncate(raw))),
        .i16 => @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(raw))))),
        .u16 => @floatFromInt(@as(u16, @truncate(raw))),
        .i32 => @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(raw))))),
        .u32 => @floatFromInt(@as(u32, @truncate(raw))),
        .f16 => @floatCast(@as(f16, @bitCast(@as(u16, @truncate(raw))))),
        .f32 => @floatCast(@as(f32, @bitCast(@as(u32, @truncate(raw))))),
        .f64 => @bitCast(raw),
        // A BigInt element read as a Number is lossy, but keeps the Number-typed
        // method paths crash-free; the interpreter's index get uses `taReadBig`.
        .i64 => @floatFromInt(@as(i64, @bitCast(raw))),
        .u64 => @floatFromInt(raw),
    };
    return Value.num(n);
}

/// Read a BigInt typed-array element `i` as an `i128` (the raw 64-bit value,
/// sign-extended for BigInt64Array).
pub fn taReadBig(ta: *const TypedArrayData, i: usize) i128 {
    const buf = ta.buffer.arrayBuffer().?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + 8 > bytes.len) return 0;
    const raw = taOrdinaryReadRaw(buf, bytes, off, ta.kind);
    return switch (ta.kind) {
        .i64 => @as(i64, @bitCast(raw)),
        .u64 => @as(i128, raw),
        else => 0,
    };
}

/// Write a BigInt typed-array element `i` from an `i128` (the low 64 bits).
pub fn taWriteBig(ta: *const TypedArrayData, i: usize, val: i128) void {
    const buf = ta.buffer.arrayBuffer().?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + 8 > bytes.len) return;
    const low: u64 = @truncate(@as(u128, @bitCast(val)));
    taOrdinaryWriteRaw(buf, bytes, off, ta.kind, low);
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
    const buf = ta.buffer.arrayBuffer().?;
    buf.lockBuffer();
    defer buf.unlockBuffer();
    const bytes = buf.bytes();
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + ta.kind.byteSize() > bytes.len) return; // shrunk resizable buffer
    const raw: u64 = switch (ta.kind) {
        .i8 => @as(u8, @bitCast(taToInt(i8, num))),
        .u8 => taToInt(u8, num),
        .u8c => blk: {
            // ToUint8Clamp: NaN→0, round-half-to-even, clamp [0,255].
            if (std.math.isNan(num) or num <= 0) {
                break :blk 0;
            } else if (num >= 255) {
                break :blk 255;
            } else {
                const f = @floor(num);
                const rounded: f64 = if (num - f == 0.5)
                    (if (@mod(f, 2) == 0) f else f + 1)
                else
                    @round(num);
                break :blk @as(u8, @intFromFloat(rounded));
            }
        },
        .i16 => @as(u16, @bitCast(taToInt(i16, num))),
        .u16 => taToInt(u16, num),
        .i32 => @as(u32, @bitCast(taToInt(i32, num))),
        .u32 => taToInt(u32, num),
        .f16 => @as(u16, @bitCast(@as(f16, @floatCast(num)))),
        .f32 => @as(u32, @bitCast(@as(f32, @floatCast(num)))),
        .f64 => @bitCast(num),
        // A Number written to a BigInt array is only reached via the lossy
        // Number-typed method paths; the index set uses `taWriteBig`.
        .i64 => @as(u64, @bitCast(taToInt(i64, num))),
        .u64 => taToInt(u64, num),
    };
    taOrdinaryWriteRaw(buf, bytes, off, ta.kind, raw);
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
    const b = ta.buffer.arrayBuffer().?.bytes();
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
    const buf = ta.buffer.arrayBuffer().?;
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
    const buf = ta.buffer.arrayBuffer().?;
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
    const buf = ta.buffer.arrayBuffer().?;
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
    const buf = ta.buffer.arrayBuffer().?;
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
    /// Bun's `Buffer` is a Uint8Array subclass. Keep that identity on the live
    /// view even before the rest of the Buffer private ABI is installed so
    /// native constructors and the later `JSBuffer__isBuffer` boundary agree.
    is_buffer: bool = false,
    /// A length-tracking view (created without an explicit length on a resizable
    /// ArrayBuffer): its length follows the buffer's current size rather than the
    /// cached `length`.
    track_length: bool = false,

    /// The view's current element length, or null if it is out of bounds (the
    /// backing resizable buffer shrank below it) or detached. A length-tracking
    /// view recomputes from the live buffer size; a fixed view keeps `length`
    /// unless its range no longer fits.
    pub fn currentLength(self: *const TypedArrayData) ?usize {
        const buf = self.buffer.arrayBuffer() orelse return null;
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
        const buf = self.buffer.arrayBuffer() orelse return null;
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
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn unlockState(self: *IterHelper) void {
        gc_runtime.leaveTraceSensitiveLock();
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

/// Context-owned lifetime record for a C-API class instance. The concrete
/// class definition stays private to `c_api.zig`; core GC and Context teardown
/// only need one idempotent callback that runs class finalizers and releases
/// the instance's retained JSClassRef.
pub const CApiObjectOwner = struct {
    finalized: std.atomic.Value(bool) = .init(false),
    finish_queued: std.atomic.Value(bool) = .init(false),
    pending_next: ?*CApiObjectOwner = null,
    allocator: std.mem.Allocator,
    object_ref: ?*anyopaque = null,
    class_ref: ?*anyopaque,
    payload: ?*anyopaque = null,
    hooks: ?*const HostClassHooks = null,
    custom_accessor_cells: std.StringHashMapUnmanaged(*Object) = .empty,
    finish_fn: *const fn (*CApiObjectOwner) void,

    pub fn finishOnce(self: *CApiObjectOwner) void {
        if (self.finalized.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            var keys = self.custom_accessor_cells.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            self.custom_accessor_cells.deinit(self.allocator);
            self.finish_fn(self);
        }
    }
};

/// A shared automatic prototype created for one JSClassRef in one Context.
/// Context root tracing keeps `object` alive; the opaque finish callback drops
/// the cache's class retain during teardown without importing `c_api.zig`.
pub const CApiClassPrototypeOwner = struct {
    class_ref: *anyopaque,
    object: *Object,
    finish_fn: *const fn (*CApiClassPrototypeOwner) void,

    pub fn finish(self: *CApiClassPrototypeOwner) void {
        self.finish_fn(self);
    }
};

/// Rare internal slots kept out of every ordinary object. These states belong
/// to disjoint exotic object kinds, but a single sidecar keeps access simple
/// while removing enough default-initialized payload to place Object cells in
/// zig-js's existing 512-byte GC slab. The sidecar is allocated lazily through
/// the same budgeted allocator and ownership accounting as other Object backing
/// stores.
pub const ObjectRareTag = enum(u8) {
    none,
    primitive,
    error_state,
    date,
    module_ns,
    weak_ref,
    host_callback,
    boxed_primitive,
    generator,
    iter_helper,
    bound_function,
    async_context_frame,
    proxy,
    buffer_view,
    temporal,
    promise,
    constructor,
    sparse_array,
    js_function,
    regex,
    wasm_module,
    wasm_instance,
    wasm_memory,
    wasm_table,
    wasm_global,
    wasm_function,
    wasm_tag,
    wasm_exception,
    wasm_gc_ref,
};

/// Structured JavaScript stack metadata retained when an Error is created.
/// The numeric code values intentionally match Bun's `ZigStackFrameCode` ABI.
pub const ErrorStackFrameCode = enum(u8) {
    none = 0,
    eval = 1,
    module = 2,
    function = 3,
    global = 4,
    wasm = 5,
    constructor = 6,
    _,
};

pub const ErrorStackFrame = struct {
    function_name: []const u8 = "",
    source_url: []const u8 = "",
    script_id: u64 = 0,
    line_zero_based: i32 = -1,
    column_zero_based: i32 = -1,
    line_start_byte: i32 = -1,
    code_type: ErrorStackFrameCode = .none,
    is_async: bool = false,
    jsc_stack_frame_index: i32 = -1,
};

pub const PackedDenseStorageSnapshot = struct {
    values: []Value,
    source_address: usize,
};

const ErrorStack = struct {
    frames: []const ErrorStackFrame,
};

pub const ObjectRareState = union(ObjectRareTag) {
    none: void,
    primitive: ObjectPrimitiveState,
    error_state: struct {
        name: []const u8 = "",
        ctor: ?[]const u8 = null,
        stack: ?*const ErrorStack = null,
        stack_materialized: bool = false,
        wasm_uncatchable: bool = false,
    },
    date: struct {},
    module_ns: struct { ptr: ?*anyopaque = null },
    weak_ref: struct { target: ?*Object = null },
    host_callback: struct {
        callback: ?HostCallback = null,
        context: ?*anyopaque = null,
    },
    boxed_primitive: struct { value: Value = Value.undef() },
    generator: struct { ptr: ?*anyopaque = null },
    iter_helper: struct { ptr: ?*IterHelper = null },
    bound_function: struct { ptr: ?*anyopaque = null },
    async_context_frame: struct {
        callback: Value = Value.undef(),
        context: Value = Value.undef(),
    },
    proxy: struct {
        target: ?*Object = null,
        handler: ?*Object = null,
    },
    buffer_view: struct {
        array_buffer: ?*ArrayBufferData = null,
        typed_array: ?*TypedArrayData = null,
        data_view: ?*DataViewData = null,
    },
    temporal: struct { ptr: ?*TemporalData = null },
    promise: struct { ptr: ?*anyopaque = null },
    constructor: struct { ptr: ?*Object = null },
    sparse_array: struct { holes: ?*std.AutoHashMapUnmanaged(usize, void) = null },
    js_function: struct { ptr: ?*anyopaque = null },
    regex: ObjectRegexState,
    // WebAssembly JS API (issue #141). Native payloads are type-erased module,
    // instance, store-object owner, or function records. A context-level
    // registry owns their memory, so these slots are weak views — only the
    // Object edges below participate in GC tracing.
    wasm_module: struct { mod: ?*anyopaque = null }, // *wasm/types.Module
    wasm_instance: struct { inst: ?*anyopaque = null, module_obj: ?*Object = null, import_vals: []const Value = &.{}, exports_obj: ?*Object = null, gc_state: ?*WasmInstanceGcState = null },
    wasm_memory: struct { mem: ?*anyopaque = null, buffer_obj: ?*Object = null, owner_obj: ?*Object = null }, // *wasm/api.MemoryOwner
    wasm_table: struct {
        table: ?*anyopaque = null,
        refs: []const std.atomic.Value(u64) = &.{},
        owner_obj: ?*Object = null,
        gc_state: ?*WasmOwnerGcState = null,
    }, // *wasm/api.TableOwner
    wasm_global: struct {
        glob: ?*anyopaque = null,
        ref: ?*std.atomic.Value(u64) = null,
        owner_obj: ?*Object = null,
        gc_state: ?*WasmOwnerGcState = null,
    }, // *wasm/api.GlobalOwner
    wasm_function: struct { func: ?*anyopaque = null, owner_obj: ?*Object = null }, // *wasm/api.FunctionOwner
    wasm_tag: struct { tag: ?*anyopaque = null, store: ?*anyopaque = null, owner_obj: ?*Object = null }, // *wasm/exec.TagInst
    wasm_exception: struct { exception: ?*WasmException = null, payload_values: []const Value = &.{}, owner_obj: ?*Object = null },
    wasm_gc_ref: struct {
        reference: ?*WasmGcRef = null,
        root: ?*anyopaque = null,
        release: ?WasmGcReleaseFn = null,
    },
};

/// Exact payload for JSC's internal GetterSetter / CustomGetterSetter cells.
/// Ordinary accessor cells retain JavaScript callable values; custom cells
/// retain only native callback addresses. The latter are owned by the class or
/// binding definition and use nullness only at this private ABI boundary.
pub const GetterSetterCellData = struct {
    first: u64 = 0,
    second: u64 = 0,
    custom: bool = false,

    pub fn ordinary(getter: ?Value, setter: ?Value) GetterSetterCellData {
        return .{
            .first = if (getter) |entry| entry.bits else Value.undef().bits,
            .second = if (setter) |entry| entry.bits else Value.undef().bits,
        };
    }

    pub fn native(getter: ?*const anyopaque, setter: ?*const anyopaque) GetterSetterCellData {
        return .{
            .first = if (getter) |entry| @intFromPtr(entry) else 0,
            .second = if (setter) |entry| @intFromPtr(entry) else 0,
            .custom = true,
        };
    }

    pub inline fn isCustom(self: GetterSetterCellData) bool {
        return self.custom;
    }

    pub inline fn getterValue(self: GetterSetterCellData) ?Value {
        if (self.isCustom() or self.first == Value.undef().bits) return null;
        return .{ .bits = self.first };
    }

    pub inline fn setterValue(self: GetterSetterCellData) ?Value {
        if (self.isCustom() or self.second == Value.undef().bits) return null;
        return .{ .bits = self.second };
    }

    pub inline fn customGetter(self: GetterSetterCellData) ?*const anyopaque {
        return if (self.isCustom() and self.first != 0) @ptrFromInt(@as(usize, @intCast(self.first))) else null;
    }

    pub inline fn customSetter(self: GetterSetterCellData) ?*const anyopaque {
        return if (self.isCustom() and self.second != 0) @ptrFromInt(@as(usize, @intCast(self.second))) else null;
    }
};

/// Collection-only indexes and entry storage live behind one allocation. Maps,
/// Sets, WeakMaps, and WeakSets already require a cold sidecar, but ordinary
/// objects must not pay for three growable container headers. The pointer is
/// published under `backing_lock`; all contents remain guarded by
/// `elements_lock`.
pub const ObjectCollectionState = struct {
    weak_entries: std.ArrayListUnmanaged(WeakCollectionEntry) = .empty,
    weak_index: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// Strong Map/Set acceleration index: content-hash(key) → position in the
    /// ordered `elements` list. It contains no managed pointers and therefore
    /// survives moving collection without tracing.
    coll_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    coll_unindexed: bool = false,
};

pub const ObjectColdState = struct {
    /// One-time publication tag for `rare`. Exotic state is initialized while
    /// `Object.backing_lock` is held, then this tag is released. Unlocked
    /// no-GIL probes acquire it before touching the stable union payload, so a
    /// probe for one exotic kind cannot race another kind's `none` transition.
    rare_tag: std.atomic.Value(ObjectRareTag) = .init(.none),
    rare: ObjectRareState = .{ .none = {} },
    /// Kept outside the tagged union because Zig dev.1413 materializes even an
    /// explicitly addressed union payload through `__tsan_memcpy` before an
    /// atomic RMW. Date is the only rare payload mutated after publication.
    date_ms_bits: std.atomic.Value(u64) = .init(0),
    private_brands: ?*std.StringHashMapUnmanaged(void) = null,
    /// Accessor properties are rare and always flow through `property_lock`;
    /// only this nullable map pointer needs atomic off-lock publication.
    accessors: std.atomic.Value(?*std.StringHashMapUnmanaged(Accessor)) = .init(null),
    /// `Thread.restrict` is opt-in. Its owner id belongs with the other rare
    /// cross-thread behavior instead of taxing every unrestricted object.
    restricted_to: std.atomic.Value(u64) = .init(0),
    /// Mixed data/accessor insertion order is needed only after an accessor or
    /// dictionary-style rebuild. Ordinary shape-only objects stay sidecar-free.
    key_order: std.atomic.Value(?*std.ArrayListUnmanaged([]const u8)) = .init(null),
    /// Per-property attribute overrides are rare on ordinary objects. Keep the
    /// atomically published map pointer off the common allocation payload.
    attrs: ?*std.StringHashMapUnmanaged(PropAttr) = null,
    /// Logical Array length only when it exceeds the dense element count.
    /// Packed dense arrays derive their length directly and leave this zero.
    array_len: u32 = 0,
    arg_map_env: ?*anyopaque = null,
    arg_map_names: [][]const u8 = &.{},
    arg_map_severed: []std.atomic.Value(bool) = &.{},
    collection_state: ?*ObjectCollectionState = null,
    finalization_callback: Value = Value.undef(),
    /// FinalizationRegistry is uncommon, so keep its 24-byte list header behind
    /// the backing flag instead of charging every cold object for it.
    finalization_records: ?*std.ArrayListUnmanaged(FinalizationRecord) = null,
    pub inline fn hasRare(self: *const ObjectColdState, tag: ObjectRareTag) bool {
        return @constCast(&self.rare_tag).load(.acquire) == tag;
    }
};

/// Symbol and BigInt are mutually exclusive primitive-tagged Object variants.
/// Their equal-size payloads overlap without a redundant runtime tag because
/// `is_symbol` / `is_bigint` already select the active interpretation.
pub const ObjectOptionalBytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub inline fn init(bytes: ?[]const u8) ObjectOptionalBytes {
        return if (bytes) |s| .{ .ptr = s.ptr, .len = s.len } else .{};
    }

    pub inline fn get(self: ObjectOptionalBytes) ?[]const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else null;
    }
};

pub const ObjectPrimitiveState = extern union {
    symbol: extern struct {
        key: ObjectOptionalBytes = .{},
        description: ObjectOptionalBytes = .{},
    },
    bigint: extern struct {
        value: i128 = 0,
        text: ObjectOptionalBytes = .{},
    },
};

pub const ObjectRegexState = struct {
    source: []const u8 = "",
    flags: []const u8 = "",
    compiled: ?*anyopaque = null,
};

/// Instance-only tracing metadata lives behind one arena-owned pointer so the
/// largest WebAssembly rare state does not widen every Object cold sidecar.
pub const WasmInstanceGcState = struct {
    global_refs: []const *std.atomic.Value(u64) = &.{},
    context: ?*anyopaque = null,
    trace: ?WasmGcTraceRootsFn = null,
    relocate: ?WasmGcRelocateRootsFn = null,
};

/// Table/Global owner tracing callbacks are uncommon and owner-lifetime data.
/// Keeping their triplet behind the existing native owner prevents either rare
/// variant from widening every Object cold sidecar.
pub const WasmOwnerGcState = struct {
    context: ?*anyopaque = null,
    verify: ?WasmGcTraceRootsFn = null,
    relocate: ?WasmGcRelocateRootsFn = null,
};

pub const ObjectBackingFlags = packed struct {
    allocator_active: bool = false,
    storage_state: bool = false,
    cold: bool = false,
    slots: bool = false,
    elements_state: bool = false,
    elements: bool = false,
    accessors: bool = false,
    key_order: bool = false,
    attrs: bool = false,
    holes: bool = false,
    collection_state: bool = false,
    weak_entries: bool = false,
    coll_index: bool = false,
    finalization_records: bool = false,
    typed_array: bool = false,
    data_view: bool = false,
    temporal: bool = false,
    arg_map_names: bool = false,
    arg_map_severed: bool = false,
};

/// Infrequent object behavior tags share two bytes instead of reserving one
/// byte apiece in every ordinary object. High-traffic primitive/array/proxy
/// tags remain direct fields until their larger migration can be benchmarked
/// independently.
pub const ObjectBehaviorFlags = packed struct(u16) {
    is_htmldda: bool = false,
    is_raw_json: bool = false,
    is_date: bool = false,
    is_error: bool = false,
    is_regex: bool = false,
    is_set_deleted: bool = false,
    proxy_callable: bool = false,
    is_weak_ref: bool = false,
    is_finalization_registry: bool = false,
    is_shadow_realm: bool = false,
    is_getter_setter: bool = false,
    is_custom_getter_setter: bool = false,
    is_abort_signal: bool = false,
    is_form_data: bool = false,
    is_blob: bool = false,
    is_file: bool = false,
};

pub const ObjectPrivateDataTag = enum(u8) {
    none,
    host,
    jsthread_thread,
    jsthread_lock,
    jsthread_condition,
    jsthread_thread_local,
    jsthread_unlock_token,
    jsthread_release_state,
    abort_signal,
    /// Foreign `BlobImpl*` carried by a File wrapper created at the private
    /// DOMFormData boundary. The pointer is an opaque identity token: GC must
    /// neither trace nor dereference it.
    form_data_native_blob,
    /// Independently ref-counted FetchHeaders record. It contains only native
    /// byte storage, so GC tracing and relocation deliberately ignore it.
    fetch_headers,
};

/// Type-erased bridge installed only on genuine engine-created AbortSignals.
/// The private ABI owns the record; the interpreter calls the hook after the
/// exact-once aborted/reason transition and before JavaScript abort steps.
pub const AbortSignalNativeState = struct {
    owner: ?*anyopaque = null,
    run_abort_steps: ?*const fn (?*anyopaque, Value) void = null,
    finish_owner: ?*const fn (?*anyopaque) void = null,
    timeout_handle: ?*anyopaque = null,
    cancel_timeout: ?*const fn (*AbortSignalNativeState) void = null,
    set_js_observed: ?*const fn (*AbortSignalNativeState, bool) bool = null,
    set_native_observed: ?*const fn (*AbortSignalNativeState, bool) bool = null,
};

pub const PreparedInlineLiteralShape = struct {
    final_shape: *Shape,
    slot_count: u8,
};

pub const ObjectElementsState = struct {
    list: std.ArrayListUnmanaged(Value) = .empty,
};

pub const ObjectSlotsState = struct {
    list: std.ArrayListUnmanaged(Value) = .empty,
};

pub const ObjectStorageState = struct {
    /// Allocator that owns this wrapper itself. It can differ from
    /// `backing_allocator` when an arena object first gains storage before its
    /// subsequently migrated buffers become individually GC-owned.
    owner_allocator: std.mem.Allocator,
    backing_allocator: std.mem.Allocator = undefined,
    backing_flags: ObjectBackingFlags = .{},
    cold: std.atomic.Value(?*ObjectColdState) = .init(null),
    slots: std.atomic.Value(?*ObjectSlotsState) = .init(null),
    elements: std.atomic.Value(?*ObjectElementsState) = .init(null),
    /// Context-owned C-class metadata. It belongs in the wrapper already
    /// required by a host-class object, keeping the cold sidecar inside its
    /// 256-byte GC allocation class.
    c_api_object_owner: std.atomic.Value(?*CApiObjectOwner) = .init(null),
};

/// A JavaScript object. v1 keeps this deliberately small: a string-keyed
/// property map, an optional dense array part, and three flavors of callable:
/// a JS-defined function (`js_func`, type-erased `*Function` to avoid an
/// import cycle with the interpreter), a Zig-native builtin (`native`), and a
/// C-ABI host callback (`callback`). In arena mode, backing stores still share
/// the owning Context's arena; in GC mode, migrated backing stores record their
/// allocator so object finalization can reclaim them before Context teardown.
pub const Object = struct {
    pub const inline_slot_capacity: usize = 4;

    /// One lazily installed wrapper owns all optional object storage metadata:
    /// cold/exotic state, external named slots, dense/internal elements, and
    /// GC backing allocator bookkeeping. A plain inline object pays for only
    /// this nullable pointer. The backing lock keeps first installation unique;
    /// release/acquire publication supports already-shared objects.
    storage: std.atomic.Value(?*ObjectStorageState) = .init(null),
    /// `backingFor`/`(de)activateBacking` touch storage-state allocator flags
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
    /// Named properties live behind a shared `Shape` (null = no own properties).
    /// Objects with more than four properties publish their external slot-list
    /// metadata here; smaller objects derive their live slice from `shape.count`
    /// and keep every value in `inline_slots` without a side allocation.
    shape: ?*Shape = null,
    /// Most ordinary objects never grow beyond a handful of named properties.
    /// Keep those values in the GC cell itself so object literals avoid a
    /// second allocator round trip.
    inline_slots: [inline_slot_capacity]Value = undefined,
    /// Prototype link ([[Prototype]]): property lookup walks this chain. An
    /// instance's proto is its constructor's `.prototype`; a class's `.prototype`
    /// protos to its superclass's `.prototype`.
    proto: ?*Object = null,
    /// Callable built-ins may leave `proto` null and inherit %Function.prototype%
    /// implicitly. Once [[SetPrototypeOf]] explicitly sets null, that null must be
    /// observable through [[GetPrototypeOf]] instead of falling back again.
    proto_explicit_null: bool = false,
    behavior: ObjectBehaviorFlags = .{},
    /// Accessor metadata lives in the cold sidecar.
    /// The set of private names this object was *branded* with at construction
    /// (its class's private fields/methods/accessors). PrivateGet/PrivateSet check
    /// brand membership here rather than via prototype inheritance, so an object
    /// missing the brand (a non-instance, a derived `this` before `super()`
    /// returns, an instance of a different evaluation of the class) is rejected.
    /// Lazily allocated. Keyed by the (evaluation-unique) private storage name.
    // Private brand metadata lives in the cold sidecar.
    /// Mixed data/accessor insertion order lives in the cold sidecar.
    /// Dense/indexed and internal tuple storage is absent on ordinary named
    /// objects. The backing lock serializes first installation; release/acquire
    /// publication lets shared readers observe the stable list state.
    /// Per-property attribute overrides live in the cold sidecar.
    /// When false (set by `Object.preventExtensions`/`seal`/`freeze`), new own
    /// properties can't be added. Accessed atomically via `isExtensible`/
    /// `setExtensible`: under `parallel_js` a peer can seal/freeze a shared object
    /// while another thread reads extensibility to add a property, which on a
    /// plain bool is a data race. `.monotonic` is a plain byte load/store that
    /// just marks the access synchronized for ThreadSanitizer (the freeze-vs-add
    /// outcome is racy-by-spec regardless of who wins).
    extensible_flag: std.atomic.Value(bool) = .init(true),
    /// A Symbol (a tagged object so identity `===` and storage reuse the object
    /// machinery; `typeof` reports "symbol"). The primitive union's symbol key
    /// is its unique property-key encoding.
    is_symbol: bool = false,
    /// A BigInt primitive (`typeof` reports "bigint"; treated as a primitive in
    /// equality/arithmetic). Small values use the `i128` fast path; oversized
    /// literals/decimal strings keep a canonical decimal identity in
    /// canonical decimal text until full arbitrary-precision arithmetic lands.
    is_bigint: bool = false,
    // Symbol key/description and BigInt value/text overlap in the cold sidecar.
    /// An `[[IsHTMLDDA]]` exotic object (e.g. `document.all`): `typeof` reports
    /// "undefined", ToBoolean is false, and it is loosely-equal to null/undefined.
    /// A `JSON.rawJSON(...)` result (carries `[[IsRawJSON]]`): a frozen null-proto
    /// object with an own "rawJSON" string property emitted verbatim by stringify.
    /// A `Date` instance — its [[DateValue]] (ms since the Unix epoch, or NaN
    /// for an invalid date) is the internal-slot field `date_ms`, invisible to
    /// reflection/enumeration; methods are dispatched in `dateMethod`.
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
    /// Sparse/oversized Array length lives in the cold sidecar. Packed dense
    /// arrays derive it from `elements.items.len` and remain sidecar-free.
    // C-API callback and owning Context live in the cold sidecar.
    native: ?NativeFn = null,
    /// For a `native` function, whether it implements [[Construct]] — i.e. is
    /// `new`-able. Most built-ins are *not* constructors (methods, `Math.*`,
    /// `parseInt`, `Symbol`, …); only the handful that the spec defines as
    /// constructors (`Array`, `Object`, `Map`, `RegExp`, …) set this, so
    /// `new Object.keys()` / `new Symbol()` throw a TypeError as required.
    native_ctor: bool = false,
    // The type-erased `*Interpreter.Function` pointer lives in rare state.
    /// `*vm.Generator`, type-erased (same cycle break as `js_func`). Non-null
    /// marks a generator *object* — the iterator returned by calling a
    /// `function*`; its `.next()`/`.return()`/`.throw()` drive the suspendable VM.
    // Generator-object and iterator-helper side cells live in the cold sidecar.
    /// `*Interpreter.BoundFn`, type-erased. Non-null marks a bound function
    /// (`fn.bind(this, ...args)`): calling it invokes the target with the bound
    /// `this` and the bound args prepended.
    // Bound-function side cells live in the cold sidecar.
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
    /// `Thread.restrict` ownership lives in the cold sidecar.
    /// True for `Error`-family instances; drives `toString` and `instanceof`.
    /// True for `RegExp` instances (carries `source`/`flags` properties; matching
    /// is backed by zig-regex).
    // RegExp source, flags, and compiled cache live in `cold`.
    /// True for function `arguments` objects; they are array-like internally but
    /// carry the Arguments brand for Object.prototype.toString.
    is_arguments: bool = false,
    // Mapped-arguments environment, names, and severed bits live in `cold`.
    /// `Map`/`Set` instances. A Map keeps `[key,value]` pair-arrays in
    /// `elements`; a Set keeps values directly. `size` is a maintained property.
    is_map: bool = false,
    is_set: bool = false,
    /// Internal tombstone for SetData slots deleted during observable iteration.
    /// User code can never obtain one; Set/iterator helpers skip these slots.
    /// A WeakMap/WeakSet reuses the `is_map`/`is_set` storage but carries this
    /// flag so the brand checks can tell a Map from a WeakMap (and Set/WeakSet).
    is_weak: bool = false,
    // Weak entries and their lookup index live in `cold`.
    // Error instance/constructor class names live in the cold sidecar.
    // `new F()` construction links live in the disjoint rare-state sidecar.
    // The type-erased Promise state-cell pointer lives in rare state.
    // Primitive-wrapper [[NumberData]]/[[StringData]]/[[BooleanData]] lives cold.
    /// `Proxy` target and handler live in the disjoint rare-state sidecar.
    /// A revoked proxy retains only these hot behavior flags.
    proxy_revoked: bool = false,
    /// Proxies keep their [[Call]] exotic behavior even after revocation. Once
    /// revoked, the target slot is gone, so cache the callable bit at creation.
    /// Module Namespace exotic object: points to an `interpreter.ModuleNs`
    /// (its sorted export names + live bindings). When set, this object is a
    /// `[[Module]]` namespace and the engine intercepts its essential internal
    /// methods (live [[Get]], [[HasProperty]], sorted [[OwnPropertyKeys]],
    /// frozen/non-extensible, throwing [[Set]]/[[Delete]]/[[DefineOwnProperty]]).
    // Sparse-array holes live in the disjoint rare-state sidecar.

    // ArrayBuffer, TypedArray, and DataView are mutually exclusive exotic
    // object kinds; their backing pointer lives in the rare-state sidecar.
    /// Marks a `WeakRef` instance. The target is a weak GC edge, so collection
    /// may clear it while the WeakRef object itself remains branded.
    /// Marks a `FinalizationRegistry`. Dead targets make records ready for
    /// automatic host cleanup delivery at quiescent collection points.
    // Cleanup callback and records live in `cold`.
    /// Lazy Iterator-Helper state (`map`/`filter`/`take`/`drop`/`flatMap`/wrap),
    /// non-null on a helper iterator returned by those methods.
    /// Marks a `ShadowRealm` instance (its child realm's Environment is in
    /// `private_data`).
    // Temporal internal slots live in the disjoint rare-state sidecar.

    fn lockBacking(self: *Object) bool {
        if (!element_locks_enabled.load(.acquire)) return false;
        var spins: usize = 0;
        while (!self.backing_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        object_profile.recordBackingLockAcquire(spins);
        // Concurrent tracing snapshots the cold pointer and its rare GC edges
        // under this lock. Treat it like the property/element locks so allocator
        // recovery cannot recursively enter the tracer while it is held.
        gc_runtime.enterTraceSensitiveLock();
        return true;
    }
    fn unlockBacking(self: *Object, held: bool) void {
        if (held) {
            gc_runtime.leaveTraceSensitiveLock();
            self.backing_lock.unlock();
        }
    }

    pub inline fn storageState(self: *const Object) ?*ObjectStorageState {
        return @constCast(&self.storage).load(.acquire);
    }

    const StorageSelection = struct {
        state: *ObjectStorageState,
        created: bool,
    };

    // Assumes `backing_lock` held when object-side locks are enabled.
    fn ensureStorageLocked(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!StorageSelection {
        if (self.storage.load(.acquire)) |state| return .{ .state = state, .created = false };
        const active = gc_runtime.activeObjectBacking();
        const allocator = if (active) |state| state.allocator else fallback;
        const state = try allocator.create(ObjectStorageState);
        state.* = .{ .owner_allocator = allocator };
        if (active) |tracking| {
            state.backing_allocator = tracking.allocator;
            state.backing_flags.allocator_active = true;
            state.backing_flags.storage_state = true;
            if (tracking.stores_live) |live| _ = @atomicRmw(usize, live, .Add, 1, .monotonic);
        }
        self.storage.store(state, .release);
        return .{ .state = state, .created = true };
    }

    // Roll back a failed first child allocation so OOM never leaves an empty
    // wrapper or a live-store accounting delta behind.
    fn rollbackStorageLocked(self: *Object, selection: StorageSelection) void {
        if (!selection.created) return;
        const state = selection.state;
        std.debug.assert(state.cold.load(.monotonic) == null);
        std.debug.assert(state.slots.load(.monotonic) == null);
        std.debug.assert(state.elements.load(.monotonic) == null);
        std.debug.assert(state.c_api_object_owner.load(.monotonic) == null);
        if (state.backing_flags.storage_state) {
            if (gc_runtime.activeObjectBacking()) |tracking| {
                if (tracking.stores_live) |live| _ = @atomicRmw(usize, live, .Sub, 1, .monotonic);
            }
        }
        self.storage.store(null, .release);
        state.owner_allocator.destroy(state);
    }

    pub inline fn backingFlagsSnapshot(self: *const Object) ObjectBackingFlags {
        return if (self.storageState()) |state| state.backing_flags else .{};
    }

    pub inline fn backingAllocatorIfActive(self: *const Object) ?std.mem.Allocator {
        const state = self.storageState() orelse return null;
        return if (state.backing_flags.allocator_active) state.backing_allocator else null;
    }

    // Assumes `backing_lock` held (called only from `backingFor`).
    fn activateBacking(self: *Object, comptime field: []const u8) ?std.mem.Allocator {
        const tracking = gc_runtime.activeObjectBacking() orelse return null;
        const storage = self.storageState().?;
        if (!storage.backing_flags.allocator_active) {
            storage.backing_allocator = tracking.allocator;
            storage.backing_flags.allocator_active = true;
        }
        if (!@field(storage.backing_flags, field)) {
            @field(storage.backing_flags, field) = true;
            // Atomic: parallel mutators (post-GIL) bump this shared accounting
            // counter concurrently. Identical result single-threaded.
            if (tracking.stores_live) |live| _ = @atomicRmw(usize, live, .Add, 1, .monotonic);
        }
        return storage.backing_allocator;
    }

    // Assumes `backing_lock` held when object-side locks are enabled.
    fn deactivateBackingLocked(self: *Object, comptime field: []const u8) void {
        const storage = self.storageState() orelse return;
        if (!@field(storage.backing_flags, field)) return;
        @field(storage.backing_flags, field) = false;
        if (gc_runtime.activeObjectBacking()) |state| {
            if (state.stores_live) |live| {
                _ = @atomicRmw(usize, live, .Sub, 1, .monotonic);
            }
        }
    }

    fn deactivateBacking(self: *Object, comptime field: []const u8) void {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        self.deactivateBackingLocked(field);
    }

    fn backingFor(self: *Object, fallback: std.mem.Allocator, comptime field: []const u8) std.mem.Allocator {
        return self.backingForTracked(fallback, field).allocator;
    }

    fn ensureBackingFor(self: *Object, fallback: std.mem.Allocator, comptime field: []const u8) std.mem.Allocator.Error!std.mem.Allocator {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        _ = try self.ensureStorageLocked(fallback);
        return self.backingForTrackedLocked(fallback, field).allocator;
    }

    const BackingSelection = struct {
        allocator: std.mem.Allocator,
        activated: bool,
    };

    fn backingForTracked(self: *Object, fallback: std.mem.Allocator, comptime field: []const u8) BackingSelection {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        return self.backingForTrackedLocked(fallback, field);
    }

    // Assumes `backing_lock` held when object-side locks are enabled.
    fn backingForTrackedLocked(self: *Object, fallback: std.mem.Allocator, comptime field: []const u8) BackingSelection {
        const storage = self.storageState().?;
        if (storage.backing_flags.allocator_active) {
            const a = storage.backing_allocator;
            if (!@field(storage.backing_flags, field)) {
                if (self.activateBacking(field)) |active| return .{ .allocator = active, .activated = true };
            }
            return .{ .allocator = a, .activated = false };
        }
        if (self.activateBacking(field)) |active| return .{ .allocator = active, .activated = true };
        return .{ .allocator = fallback, .activated = false };
    }

    fn activeBackingAllocator(self: *Object, comptime field: []const u8) ?std.mem.Allocator {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const storage = self.storageState() orelse return null;
        if (!@field(storage.backing_flags, field)) return null;
        if (!storage.backing_flags.allocator_active) return null;
        return storage.backing_allocator;
    }

    /// Allocate the cold internal-slot sidecar on first use. Exotic objects
    /// pay this cost; ordinary objects retain only the nullable pointer.
    pub fn ensureCold(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*ObjectColdState {
        // The sidecar may be installed on an already-published object (for
        // example, the first WeakMap.set). Serialize both the null check and
        // publication with the concurrent tracer's cold-edge snapshot.
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const storage = try self.ensureStorageLocked(fallback);
        if (storage.state.cold.load(.acquire)) |cold| return cold;
        const backing = self.backingForTrackedLocked(fallback, "cold");
        const cold = backing.allocator.create(ObjectColdState) catch |err| {
            if (backing.activated) self.deactivateBackingLocked("cold");
            self.rollbackStorageLocked(storage);
            return err;
        };
        cold.* = .{};
        storage.state.cold.store(cold, .release);
        return cold;
    }

    pub inline fn coldState(self: *const Object) ?*ObjectColdState {
        const storage = self.storageState() orelse return null;
        return storage.cold.load(.acquire);
    }

    /// Install the collection-only state under the same publication lock as the
    /// cold sidecar. Callers already hold `elements_lock`, which continues to
    /// guard every map and list inside the state.
    pub fn ensureCollectionState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*ObjectCollectionState {
        const cold = try self.ensureCold(fallback);
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        if (cold.collection_state) |state| return state;
        const backing = self.backingForTrackedLocked(fallback, "collection_state");
        const state = backing.allocator.create(ObjectCollectionState) catch |err| {
            if (backing.activated) self.deactivateBackingLocked("collection_state");
            return err;
        };
        state.* = .{};
        cold.collection_state = state;
        return state;
    }

    pub inline fn collectionState(self: *const Object) ?*ObjectCollectionState {
        const cold = self.coldState() orelse return null;
        return cold.collection_state;
    }

    pub inline fn cApiObjectOwner(self: *const Object) ?*CApiObjectOwner {
        const storage = self.storageState() orelse return null;
        return storage.c_api_object_owner.load(.acquire);
    }

    pub fn setCApiObjectClass(
        self: *Object,
        fallback: std.mem.Allocator,
        owner: *CApiObjectOwner,
        hooks: *const HostClassHooks,
    ) std.mem.Allocator.Error!void {
        try self.setCApiObjectOwner(fallback, owner);
        owner.hooks = hooks;
    }

    /// Attach a context-owned finalization record without changing the
    /// object's property behavior. Native wrappers such as AbortSignal need
    /// deterministic teardown but are not C-API host classes.
    pub fn setCApiObjectOwner(
        self: *Object,
        fallback: std.mem.Allocator,
        owner: *CApiObjectOwner,
    ) std.mem.Allocator.Error!void {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const storage = (try self.ensureStorageLocked(fallback)).state;
        std.debug.assert(storage.c_api_object_owner.load(.monotonic) == null);
        storage.c_api_object_owner.store(owner, .release);
    }

    pub inline fn hostClassHooks(self: *const Object) ?*const HostClassHooks {
        const owner = self.cApiObjectOwner() orelse return null;
        return owner.hooks;
    }

    /// Atomic view of the cold key-order pointer. Contents remain protected by
    /// `property_lock`; null is the shape-chain-only common case.
    pub inline fn keyOrder(self: *const Object) ?*std.ArrayListUnmanaged([]const u8) {
        const cold = self.coldState() orelse return null;
        return cold.key_order.load(.monotonic);
    }

    /// Atomic view of the cold accessor-map pointer. Map contents remain behind
    /// `property_lock`; null is the data-property-only common case.
    pub inline fn accessorsMap(self: *const Object) ?*std.StringHashMapUnmanaged(Accessor) {
        const cold = self.coldState() orelse return null;
        return cold.accessors.load(.monotonic);
    }

    /// The owning thread id for `Thread.restrict`, or zero for the overwhelmingly
    /// common unrestricted object. The cold pointer publication orders the
    /// subsequent atomic owner claim.
    pub inline fn restrictionOwner(self: *const Object) u64 {
        const cold = self.coldState() orelse return 0;
        return cold.restricted_to.load(.acquire);
    }

    pub fn claimRestriction(self: *Object, fallback: std.mem.Allocator, tid: u64) std.mem.Allocator.Error!?u64 {
        std.debug.assert(tid != 0);
        const cold = try self.ensureCold(fallback);
        return cold.restricted_to.cmpxchgStrong(0, tid, .acq_rel, .acquire);
    }

    inline fn setKeyOrder(self: *Object, order: ?*std.ArrayListUnmanaged([]const u8)) void {
        const cold = self.coldState() orelse {
            std.debug.assert(order == null);
            return;
        };
        cold.key_order.store(order, .monotonic);
    }

    fn ensureRare(
        self: *Object,
        fallback: std.mem.Allocator,
        comptime tag: ObjectRareTag,
        initial: @FieldType(ObjectRareState, @tagName(tag)),
    ) std.mem.Allocator.Error!*@FieldType(ObjectRareState, @tagName(tag)) {
        const cold = try self.ensureCold(fallback);
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const active = cold.rare_tag.load(.acquire);
        if (active == .none) {
            cold.rare = @unionInit(ObjectRareState, @tagName(tag), initial);
            cold.rare_tag.store(tag, .release);
        } else {
            std.debug.assert(active == tag);
        }
        return &@field(cold.rare, @tagName(tag));
    }

    /// GC-visible Object edges out of the WebAssembly rare states (issue #141).
    /// At most one wasm rare tag is active per object, so a single flat
    /// snapshot covers all of them; null/empty fields mark nothing.
    pub const WasmTraceSnapshot = struct {
        module_obj: ?*Object = null,
        import_vals: []const Value = &.{},
        table_refs: []const std.atomic.Value(u64) = &.{},
        global_refs: []const *std.atomic.Value(u64) = &.{},
        global_ref: ?*std.atomic.Value(u64) = null,
        exception: ?*WasmException = null,
        exports_obj: ?*Object = null,
        buffer_obj: ?*Object = null,
        owner_obj: ?*Object = null,
        gc_ref: ?*WasmGcRef = null,
        gc_trace_context: ?*anyopaque = null,
        gc_trace: ?WasmGcTraceRootsFn = null,
    };

    /// Stable snapshot of every GC-visible cold/rare edge. The concurrent
    /// marker uses one backing-lock section and releases it before acquiring
    /// property or element locks, preserving the mutator's lock order.
    pub const TraceColdSnapshot = struct {
        cold: ?*ObjectColdState,
        ctor_ref: ?*Object,
        proxy_target: ?*Object,
        proxy_handler: ?*Object,
        boxed_primitive: ?Value,
        async_context_callback: ?Value,
        async_context: ?Value,
        weak_ref_target_slot: ?*?*Object,
        js_function: ?*anyopaque,
        bound_function: ?*anyopaque,
        promise_data: ?*anyopaque,
        generator: ?*anyopaque,
        iterator_helper: ?*IterHelper,
        module_ns: ?*anyopaque,
        arg_map_env: ?*anyopaque,
        typed_array: ?*TypedArrayData,
        data_view: ?*DataViewData,
        getter_setter_getter: ?Value,
        getter_setter_setter: ?Value,
        wasm: WasmTraceSnapshot,
    };

    pub fn traceColdSnapshot(self: *Object, concurrent: bool) TraceColdSnapshot {
        const backing_locked = if (concurrent) self.lockBacking() else false;
        defer self.unlockBacking(backing_locked);
        const cold = self.coldState();
        return .{
            .cold = cold,
            .ctor_ref = self.ctorRef(),
            .proxy_target = self.proxyTarget(),
            .proxy_handler = self.proxyHandler(),
            .boxed_primitive = self.boxedPrimitive(),
            .async_context_callback = if (self.asyncContextFrame()) |frame| frame.callback else null,
            .async_context = if (self.asyncContextFrame()) |frame| frame.context else null,
            .weak_ref_target_slot = if (self.behavior.is_weak_ref) self.weakRefTargetSlot() else null,
            .js_function = self.jsFunction(),
            .bound_function = self.boundFunction(),
            .promise_data = self.promiseData(),
            .generator = self.generator(),
            .iterator_helper = self.iteratorHelper(),
            .module_ns = self.moduleNs(),
            .arg_map_env = if (cold) |state| state.arg_map_env else null,
            .typed_array = self.typedArray(),
            .data_view = self.dataView(),
            .getter_setter_getter = if (self.getterSetterCellData()) |cell| cell.getterValue() else null,
            .getter_setter_setter = if (self.getterSetterCellData()) |cell| cell.setterValue() else null,
            .wasm = if (cold) |state| wasmTraceSnapshot(state) else .{},
        };
    }

    /// Copy the active wasm rare state's Object edges into a flat snapshot.
    /// Called under the backing lock (concurrent mark) or in a quiescent world.
    fn wasmTraceSnapshot(cold: *ObjectColdState) WasmTraceSnapshot {
        return switch (cold.rare_tag.load(.acquire)) {
            .wasm_instance => instance: {
                const state = cold.rare.wasm_instance;
                const gc_state = state.gc_state;
                break :instance .{
                    .module_obj = state.module_obj,
                    .import_vals = state.import_vals,
                    .global_refs = if (gc_state) |trace| trace.global_refs else &.{},
                    .exports_obj = state.exports_obj,
                    .gc_trace_context = if (gc_state) |trace| trace.context else null,
                    .gc_trace = if (gc_state) |trace| trace.trace else null,
                };
            },
            .wasm_memory => .{
                .buffer_obj = cold.rare.wasm_memory.buffer_obj,
                .owner_obj = cold.rare.wasm_memory.owner_obj,
            },
            .wasm_table => .{
                .table_refs = cold.rare.wasm_table.refs,
                .owner_obj = cold.rare.wasm_table.owner_obj,
            },
            .wasm_global => .{
                .global_ref = cold.rare.wasm_global.ref,
                .owner_obj = cold.rare.wasm_global.owner_obj,
            },
            .wasm_function => .{ .owner_obj = cold.rare.wasm_function.owner_obj },
            .wasm_tag => .{ .owner_obj = cold.rare.wasm_tag.owner_obj },
            .wasm_exception => .{
                .import_vals = cold.rare.wasm_exception.payload_values,
                .owner_obj = cold.rare.wasm_exception.owner_obj,
                .exception = cold.rare.wasm_exception.exception,
            },
            .wasm_gc_ref => .{ .gc_ref = cold.rare.wasm_gc_ref.reference },
            else => .{},
        };
    }

    pub inline fn getterSetterCellData(self: *const Object) ?GetterSetterCellData {
        if (!self.behavior.is_getter_setter) return null;
        return .{
            .first = self.inline_slots[0].bits,
            .second = self.inline_slots[1].bits,
            .custom = self.behavior.is_custom_getter_setter,
        };
    }

    pub fn setGetterSetterCellData(self: *Object, data: GetterSetterCellData) void {
        std.debug.assert(self.shape == null);
        self.inline_slots[0] = .{ .bits = data.first };
        self.inline_slots[1] = .{ .bits = data.second };
        self.behavior.is_getter_setter = true;
        self.behavior.is_custom_getter_setter = data.custom;
    }

    pub inline fn symbolKey(self: *const Object) []const u8 {
        const cold = self.coldState() orelse return "";
        if (!cold.hasRare(.primitive)) return "";
        return cold.rare.primitive.symbol.key.get() orelse "";
    }

    pub inline fn symbolDescription(self: *const Object) ?[]const u8 {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.primitive)) return null;
        return cold.rare.primitive.symbol.description.get();
    }

    pub inline fn bigIntValue(self: *const Object) i128 {
        const cold = self.coldState() orelse return 0;
        if (!cold.hasRare(.primitive)) return 0;
        return cold.rare.primitive.bigint.value;
    }

    pub inline fn bigIntText(self: *const Object) ?[]const u8 {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.primitive)) return null;
        return cold.rare.primitive.bigint.text.get();
    }

    pub fn setPrimitiveState(self: *Object, fallback: std.mem.Allocator, primitive: ObjectPrimitiveState) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .primitive, primitive);
        state.* = primitive;
    }

    pub fn setSymbolKey(self: *Object, key: []const u8) void {
        self.coldState().?.rare.primitive.symbol.key = .init(key);
    }

    pub inline fn errorName(self: *const Object) []const u8 {
        const cold = self.coldState() orelse return "";
        if (!cold.hasRare(.error_state)) return "";
        return cold.rare.error_state.name;
    }

    pub inline fn errorCtor(self: *const Object) ?[]const u8 {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.error_state)) return null;
        return cold.rare.error_state.ctor;
    }

    pub inline fn errorStackFrames(self: *const Object) []const ErrorStackFrame {
        const cold = self.coldState() orelse return &.{};
        if (!cold.hasRare(.error_state)) return &.{};
        const stack = cold.rare.error_state.stack orelse return &.{};
        return stack.frames;
    }

    pub inline fn hasMaterializedErrorInfo(self: *const Object) bool {
        const cold = self.coldState() orelse return false;
        return cold.hasRare(.error_state) and cold.rare.error_state.stack_materialized;
    }

    pub inline fn markErrorInfoMaterialized(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.error_state)) cold.rare.error_state.stack_materialized = true;
    }

    pub inline fn isWasmUncatchableException(self: *const Object) bool {
        const cold = self.coldState() orelse return false;
        return cold.hasRare(.error_state) and cold.rare.error_state.wasm_uncatchable;
    }

    pub inline fn markWasmUncatchableException(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.error_state)) cold.rare.error_state.wasm_uncatchable = true;
    }

    pub inline fn moduleNs(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.module_ns)) return null;
        return cold.rare.module_ns.ptr;
    }

    pub fn setModuleNs(self: *Object, fallback: std.mem.Allocator, module_ns: *anyopaque) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .module_ns, .{});
        state.ptr = module_ns;
    }

    pub inline fn weakRefTarget(self: *const Object) ?*Object {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.weak_ref)) return null;
        return cold.rare.weak_ref.target;
    }

    pub fn setWeakRefTarget(self: *Object, fallback: std.mem.Allocator, target: *Object) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .weak_ref, .{});
        state.target = target;
    }

    pub inline fn weakRefTargetSlot(self: *Object) *?*Object {
        return &self.coldState().?.rare.weak_ref.target;
    }

    pub inline fn hostCallback(self: *const Object) ?HostCallback {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.host_callback)) return null;
        return cold.rare.host_callback.callback;
    }

    pub inline fn hostCallbackContext(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.host_callback)) return null;
        return cold.rare.host_callback.context;
    }

    pub fn setHostCallback(
        self: *Object,
        fallback: std.mem.Allocator,
        callback: HostCallback,
        context: *anyopaque,
    ) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .host_callback, .{});
        state.callback = callback;
        state.context = context;
    }

    pub inline fn boxedPrimitive(self: *const Object) ?Value {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.boxed_primitive)) return null;
        return cold.rare.boxed_primitive.value;
    }

    pub fn setBoxedPrimitive(self: *Object, fallback: std.mem.Allocator, primitive: Value) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .boxed_primitive, .{});
        state.value = primitive;
    }

    pub inline fn generator(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.generator)) return null;
        return cold.rare.generator.ptr;
    }

    pub fn setGenerator(self: *Object, fallback: std.mem.Allocator, raw_generator: *anyopaque) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .generator, .{});
        state.ptr = raw_generator;
    }

    pub inline fn iteratorHelper(self: *const Object) ?*IterHelper {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.iter_helper)) return null;
        return cold.rare.iter_helper.ptr;
    }

    pub fn setIteratorHelper(self: *Object, fallback: std.mem.Allocator, helper: *IterHelper) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .iter_helper, .{});
        state.ptr = helper;
    }

    pub inline fn boundFunction(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.bound_function)) return null;
        return cold.rare.bound_function.ptr;
    }

    pub fn setBoundFunction(self: *Object, fallback: std.mem.Allocator, bound_function: *anyopaque) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .bound_function, .{});
        state.ptr = bound_function;
    }

    pub inline fn asyncContextFrame(self: *const Object) ?*@FieldType(ObjectRareState, "async_context_frame") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.async_context_frame)) return null;
        return @constCast(&cold.rare.async_context_frame);
    }

    pub fn setAsyncContextFrame(
        self: *Object,
        fallback: std.mem.Allocator,
        callback: Value,
        context: Value,
    ) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .async_context_frame, .{});
        state.callback = callback;
        state.context = context;
    }

    pub inline fn proxyTarget(self: *const Object) ?*Object {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.proxy)) return null;
        return cold.rare.proxy.target;
    }

    pub inline fn proxyHandler(self: *const Object) ?*Object {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.proxy)) return null;
        return cold.rare.proxy.handler;
    }

    pub fn setProxyState(
        self: *Object,
        fallback: std.mem.Allocator,
        target: *Object,
        handler: *Object,
    ) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .proxy, .{});
        state.target = target;
        state.handler = handler;
    }

    pub fn clearProxyState(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (!cold.hasRare(.proxy)) return;
        cold.rare.proxy.target = null;
        cold.rare.proxy.handler = null;
    }

    pub inline fn arrayBuffer(self: *const Object) ?*ArrayBufferData {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.buffer_view)) return null;
        return cold.rare.buffer_view.array_buffer;
    }

    pub inline fn typedArray(self: *const Object) ?*TypedArrayData {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.buffer_view)) return null;
        return cold.rare.buffer_view.typed_array;
    }

    pub inline fn dataView(self: *const Object) ?*DataViewData {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.buffer_view)) return null;
        return cold.rare.buffer_view.data_view;
    }

    fn bufferViewState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "buffer_view") {
        return self.ensureRare(fallback, .buffer_view, .{});
    }

    pub fn setArrayBuffer(self: *Object, fallback: std.mem.Allocator, data: *ArrayBufferData) std.mem.Allocator.Error!void {
        const state = try self.bufferViewState(fallback);
        state.array_buffer = data;
    }

    pub fn setTypedArray(self: *Object, fallback: std.mem.Allocator, data: *TypedArrayData) std.mem.Allocator.Error!void {
        const state = try self.bufferViewState(fallback);
        state.typed_array = data;
    }

    pub fn setDataView(self: *Object, fallback: std.mem.Allocator, data: *DataViewData) std.mem.Allocator.Error!void {
        const state = try self.bufferViewState(fallback);
        state.data_view = data;
    }

    pub fn clearArrayBuffer(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.buffer_view)) cold.rare.buffer_view.array_buffer = null;
    }

    pub fn clearTypedArray(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.buffer_view)) cold.rare.buffer_view.typed_array = null;
    }

    pub fn clearDataView(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.buffer_view)) cold.rare.buffer_view.data_view = null;
    }

    // ---- WebAssembly JS API rare-state accessors (issue #141) ----------------
    // Getter/setter pairs mirror the buffer_view pattern above: the getter
    // probes the published tag, the setter ensures the sidecar payload. For
    // payloads with Object edges the state accessor hands out the mutable
    // payload struct so the wasm API can fill several fields in one ensure.

    pub inline fn wasmModule(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_module)) return null;
        return cold.rare.wasm_module.mod;
    }

    pub fn setWasmModule(self: *Object, fallback: std.mem.Allocator, mod: *anyopaque) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .wasm_module, .{});
        state.mod = mod;
    }

    pub inline fn wasmInstance(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_instance") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_instance)) return null;
        return &cold.rare.wasm_instance;
    }

    pub fn wasmInstanceState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_instance") {
        return self.ensureRare(fallback, .wasm_instance, .{});
    }

    /// Copy the complete Memory wrapper record while it is stable. Shared
    /// memory growth replaces `buffer_obj` after the wrapper has already been
    /// published to other no-GIL mutators, so callers must not retain a raw
    /// pointer into the rare-state union across that replacement.
    pub fn wasmMemorySnapshot(self: *Object) ?@FieldType(ObjectRareState, "wasm_memory") {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_memory)) return null;
        return cold.rare.wasm_memory;
    }

    /// Atomically replace a Memory wrapper's current buffer. For unshared
    /// memory, detaching the historical ArrayBuffer and publishing its
    /// replacement occur under the same wrapper lock, so a concurrent getter
    /// observes either the complete old record or the complete new record.
    pub fn replaceWasmMemoryBuffer(self: *Object, fresh: *Object, detach_old: bool) bool {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const cold = self.coldState() orelse return false;
        if (!cold.hasRare(.wasm_memory)) return false;
        const state = &cold.rare.wasm_memory;
        const old_object = state.buffer_obj orelse return false;
        if (detach_old) {
            const old = old_object.arrayBuffer() orelse return false;
            // Generated native handles promise stable backing ownership.
            if (old.native_handle.load(.acquire) != null) return false;
            old.lockBuffer();
            old.swapLocalData(&.{});
            old.setDetached(true);
            old.unlockBuffer();
        }
        state.buffer_obj = fresh;
        return true;
    }

    pub fn wasmMemoryState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_memory") {
        return self.ensureRare(fallback, .wasm_memory, .{});
    }

    pub inline fn wasmTable(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_table") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_table)) return null;
        return &cold.rare.wasm_table;
    }

    pub fn wasmTableState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_table") {
        return self.ensureRare(fallback, .wasm_table, .{});
    }

    pub fn setWasmTableRefs(self: *Object, fallback: std.mem.Allocator, refs: []const std.atomic.Value(u64)) std.mem.Allocator.Error!void {
        _ = try self.ensureRare(fallback, .wasm_table, .{});
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        self.coldState().?.rare.wasm_table.refs = refs;
    }

    pub inline fn wasmGlobal(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_global") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_global)) return null;
        return &cold.rare.wasm_global;
    }

    pub fn wasmGlobalState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_global") {
        return self.ensureRare(fallback, .wasm_global, .{});
    }

    pub inline fn wasmFunction(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_function") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_function)) return null;
        return &cold.rare.wasm_function;
    }

    pub fn wasmFunctionState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_function") {
        return self.ensureRare(fallback, .wasm_function, .{});
    }

    pub inline fn wasmTag(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_tag") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_tag)) return null;
        return &cold.rare.wasm_tag;
    }

    pub fn wasmTagState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_tag") {
        return self.ensureRare(fallback, .wasm_tag, .{});
    }

    pub inline fn wasmException(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_exception") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_exception)) return null;
        return &cold.rare.wasm_exception;
    }

    pub fn wasmExceptionState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_exception") {
        return self.ensureRare(fallback, .wasm_exception, .{});
    }

    pub inline fn wasmGcReference(self: *const Object) ?*@FieldType(ObjectRareState, "wasm_gc_ref") {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.wasm_gc_ref)) return null;
        return &cold.rare.wasm_gc_ref;
    }

    pub fn wasmGcReferenceState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "wasm_gc_ref") {
        return self.ensureRare(fallback, .wasm_gc_ref, .{});
    }

    pub inline fn temporalData(self: *const Object) ?*TemporalData {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.temporal)) return null;
        return cold.rare.temporal.ptr;
    }

    pub fn setTemporalData(self: *Object, fallback: std.mem.Allocator, data: *TemporalData) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .temporal, .{});
        state.ptr = data;
    }

    pub fn clearTemporalData(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.temporal)) cold.rare.temporal.ptr = null;
    }

    pub inline fn promiseData(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.promise)) return null;
        return cold.rare.promise.ptr;
    }

    pub fn setPromiseData(self: *Object, fallback: std.mem.Allocator, data: *anyopaque) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .promise, .{});
        state.ptr = data;
    }

    pub inline fn ctorRef(self: *const Object) ?*Object {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.constructor)) return null;
        return cold.rare.constructor.ptr;
    }

    pub fn setCtorRef(self: *Object, fallback: std.mem.Allocator, ctor: *Object) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .constructor, .{});
        state.ptr = ctor;
    }

    pub inline fn holesMap(self: *const Object) ?*std.AutoHashMapUnmanaged(usize, void) {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.sparse_array)) return null;
        return cold.rare.sparse_array.holes;
    }

    fn sparseArrayState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*@FieldType(ObjectRareState, "sparse_array") {
        return self.ensureRare(fallback, .sparse_array, .{});
    }

    pub fn clearHolesMap(self: *Object) void {
        const cold = self.coldState() orelse return;
        if (cold.hasRare(.sparse_array)) cold.rare.sparse_array.holes = null;
    }

    pub inline fn jsFunction(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.js_function)) return null;
        return cold.rare.js_function.ptr;
    }

    pub fn setJsFunction(self: *Object, fallback: std.mem.Allocator, function: *anyopaque) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .js_function, .{});
        state.ptr = function;
    }

    pub inline fn privateBrands(self: *const Object) ?*std.StringHashMapUnmanaged(void) {
        const cold = self.coldState() orelse return null;
        return cold.private_brands;
    }

    pub fn clearPrivateBrands(self: *Object) void {
        if (self.coldState()) |cold| cold.private_brands = null;
    }

    pub fn setErrorName(self: *Object, fallback: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .error_state, .{});
        state.name = name;
    }

    pub fn setErrorCtor(self: *Object, fallback: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .error_state, .{});
        state.ctor = name;
    }

    pub fn setErrorStackFrames(self: *Object, fallback: std.mem.Allocator, frames: []const ErrorStackFrame) std.mem.Allocator.Error!void {
        const state = try self.ensureRare(fallback, .error_state, .{});
        const stack = try fallback.create(ErrorStack);
        stack.* = .{ .frames = frames };
        state.stack = stack;
    }

    pub inline fn regexSource(self: *const Object) []const u8 {
        const cold = self.coldState() orelse return "";
        if (!cold.hasRare(.regex)) return "";
        return cold.rare.regex.source;
    }

    pub inline fn regexFlags(self: *const Object) []const u8 {
        const cold = self.coldState() orelse return "";
        if (!cold.hasRare(.regex)) return "";
        return cold.rare.regex.flags;
    }

    pub inline fn regexCompiled(self: *const Object) ?*anyopaque {
        const cold = self.coldState() orelse return null;
        if (!cold.hasRare(.regex)) return null;
        return cold.rare.regex.compiled;
    }

    pub fn ensureRegexState(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*ObjectRegexState {
        return self.ensureRare(fallback, .regex, .{});
    }

    pub inline fn finalizationCallback(self: *const Object) Value {
        return if (self.coldState()) |cold| cold.finalization_callback else Value.undef();
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

    pub fn initInlineSlots(self: *Object) void {
        if (self.storageState()) |storage| storage.slots.store(null, .monotonic);
    }

    pub inline fn slotsState(self: *const Object) ?*ObjectSlotsState {
        const storage = self.storageState() orelse return null;
        return storage.slots.load(.acquire);
    }

    /// Representation boundary for named-property values. Callers retain their
    /// existing `property_lock` discipline; keeping the slice behind this
    /// helper lets external slot metadata move out of the common Object cell.
    pub inline fn slotsItems(self: *const Object) []Value {
        if (self.slotsState()) |state| return state.list.items;
        const len: usize = if (self.shape) |shape| @intCast(shape.count) else 0;
        std.debug.assert(len <= inline_slot_capacity);
        return @constCast(self).inline_slots[0..len];
    }

    /// Validate an immutable root-to-final shape chain once before a hot
    /// allocation site publishes it repeatedly. The prepared descriptor is
    /// valid for the lifetime of the owning Context because Shapes never
    /// mutate their parent/name/slot metadata after publication.
    pub fn prepareInlineLiteralShape(
        root: *Shape,
        final_shape: *Shape,
        slot_count: usize,
    ) ?PreparedInlineLiteralShape {
        if (slot_count == 0 or slot_count > inline_slot_capacity)
            return null;

        var chain: [inline_slot_capacity]*Shape = undefined;
        var cursor: ?*Shape = final_shape;
        var remaining = slot_count;
        while (remaining > 0) {
            const child = cursor orelse return null;
            const name = child.name orelse return null;
            const index = remaining - 1;
            if (child.slot != index or child.count != remaining or canonicalIndex(name) != null)
                return null;
            chain[index] = child;
            cursor = child.parent;
            remaining = index;
        }
        if (cursor != root) return null;
        for (chain[0..slot_count], 0..) |child, left| {
            const name = child.name.?;
            for (chain[left + 1 .. slot_count]) |other|
                if (std.mem.eql(u8, name, other.name.?)) return null;
        }
        return .{ .final_shape = final_shape, .slot_count = @intCast(slot_count) };
    }

    /// Initialize an exclusively-owned fresh object using a descriptor prepared
    /// by `prepareInlineLiteralShape`, without replaying generic property
    /// transitions or re-walking immutable shape metadata. Values stay in the
    /// cell's inline storage and retain owner-aware insertion barriers.
    pub inline fn initializePreparedInlineLiteralShape(
        self: *Object,
        prepared: PreparedInlineLiteralShape,
        values: []const Value,
    ) bool {
        if (values.len != prepared.slot_count or
            self.shape != null or self.slotsItems().len != 0 or !self.slotsAreInline() or
            self.backingFlagsSnapshot().slots or self.accessorsMap() != null or
            self.keyOrder() != null or self.attrsMap() != null or !self.isExtensible())
            return false;

        for (values, 0..) |value_, index| {
            gcBarrier(self, value_);
            self.inline_slots[index] = value_;
        }
        self.shape = prepared.final_shape;
        return true;
    }

    fn slotsAreInline(self: *const Object) bool {
        return self.slotsState() == null;
    }

    fn appendSlot(self: *Object, fallback: std.mem.Allocator, value_: Value) std.mem.Allocator.Error!void {
        if (self.slotsState()) |state| {
            try state.list.append(self.slotsAllocator(fallback), value_);
            return;
        }

        const old_slots = self.slotsItems();
        if (old_slots.len < inline_slot_capacity) {
            self.inline_slots[old_slots.len] = value_;
            return;
        }

        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const storage = try self.ensureStorageLocked(fallback);
        const backing = self.backingForTrackedLocked(fallback, "slots");
        const state = backing.allocator.create(ObjectSlotsState) catch |err| {
            if (backing.activated) self.deactivateBackingLocked("slots");
            self.rollbackStorageLocked(storage);
            return err;
        };
        const values = backing.allocator.alloc(Value, inline_slot_capacity * 2) catch |err| {
            backing.allocator.destroy(state);
            if (backing.activated) self.deactivateBackingLocked("slots");
            self.rollbackStorageLocked(storage);
            return err;
        };
        @memcpy(values[0..old_slots.len], old_slots);
        state.* = .{ .list = .{ .items = values[0..old_slots.len], .capacity = values.len } };
        state.list.appendAssumeCapacity(value_);
        storage.state.slots.store(state, .release);
    }

    pub fn elementsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "elements");
    }

    pub inline fn elementsState(self: *const Object) ?*ObjectElementsState {
        const storage = self.storageState() orelse return null;
        return storage.elements.load(.acquire);
    }

    pub fn ensureElementsList(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!*std.ArrayListUnmanaged(Value) {
        const backing_locked = self.lockBacking();
        defer self.unlockBacking(backing_locked);
        const storage = try self.ensureStorageLocked(fallback);
        if (storage.state.elements.load(.acquire)) |state| return &state.list;
        const backing = self.backingForTrackedLocked(fallback, "elements_state");
        const state = backing.allocator.create(ObjectElementsState) catch |err| {
            if (backing.activated) self.deactivateBackingLocked("elements_state");
            self.rollbackStorageLocked(storage);
            return err;
        };
        state.* = .{};
        storage.state.elements.store(state, .release);
        return &state.list;
    }

    pub fn accessorsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "accessors");
    }

    pub fn keyOrderAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "key_order");
    }

    pub fn attrsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "attrs");
    }

    pub fn holesAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "holes");
    }

    pub fn weakEntriesAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "weak_entries");
    }

    pub fn finalizationRecordsAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "finalization_records");
    }

    pub fn typedArrayAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "typed_array");
    }

    pub fn destroyUninstalledTypedArray(self: *Object, fallback: std.mem.Allocator, ta: *TypedArrayData) void {
        const a = self.backingAllocatorIfActive() orelse fallback;
        a.destroy(ta);
        self.deactivateBacking("typed_array");
    }

    pub fn dataViewAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "data_view");
    }

    pub fn temporalAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "temporal");
    }

    pub fn destroyUninstalledTemporal(self: *Object, fallback: std.mem.Allocator, data: *TemporalData) void {
        const a = self.backingAllocatorIfActive() orelse fallback;
        a.destroy(data);
        self.deactivateBacking("temporal");
    }

    pub fn argMapNamesAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "arg_map_names");
    }

    pub fn argMapSeveredAllocator(self: *Object, fallback: std.mem.Allocator) std.mem.Allocator.Error!std.mem.Allocator {
        return self.ensureBackingFor(fallback, "arg_map_severed");
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
        object_profile.recordPropertyLockAcquire(spins);
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn unlockProperties(self: *const Object) void {
        gc_runtime.leaveTraceSensitiveLock();
        @constCast(self).property_lock.unlock();
    }

    /// [[Prototype]], read/written atomically: `setPrototypeOf` (and internal
    /// reparenting) writes `proto` on a shared object while peers walk its
    /// prototype chain (no-GIL). Acquire/release also publishes the accompanying
    /// explicit-null discriminator without requiring readers to lock the graph.
    /// Object-creation struct-inits write the raw field directly (the object
    /// isn't published yet → no race).
    pub inline fn protoAtomic(self: *const Object) ?*Object {
        return @atomicLoad(?*Object, &@constCast(self).proto, .acquire);
    }
    pub inline fn setProtoAtomic(self: *Object, p: ?*Object) void {
        gc_runtime.barrierFrom(@ptrCast(self), if (p) |proto| @ptrCast(proto) else null);
        @atomicStore(?*Object, &self.proto, p, .release);
    }

    pub inline fn protoExplicitNull(self: *const Object) bool {
        return @atomicLoad(bool, &@constCast(self).proto_explicit_null, .monotonic);
    }

    pub inline fn setProtoExplicitNull(self: *Object, value_: bool) void {
        @atomicStore(bool, &self.proto_explicit_null, value_, .monotonic);
    }

    pub inline fn setPrototypeStateAtomic(self: *Object, p: ?*Object) void {
        // Publish the explicit-null discriminator before the release-store of a
        // null link. A reader that acquires that null therefore cannot revive
        // the implicit Function.prototype fallback. For a non-null link the
        // pointer itself determines the result, so clear the discriminator only
        // after publishing the link.
        if (p == null) self.setProtoExplicitNull(true);
        self.setProtoAtomic(p);
        if (p != null) self.setProtoExplicitNull(false);
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
        object_profile.recordElementLockAcquire(spins);
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn unlockElements(self: *const Object) void {
        if (!element_locks_enabled.load(.acquire)) return;
        gc_runtime.leaveTraceSensitiveLock();
        @constCast(self).elements_lock.unlock();
    }

    /// `Date`'s [[DateValue]] slot, read/written atomically: a shared Date can be
    /// `setTime`'d on one thread while another reads it (no-GIL). A single f64 is
    /// one word, so `.monotonic` is a plain load/store (no perf cost) and just
    /// tells ThreadSanitizer the access is synchronized.
    pub fn dateMs(self: *const Object) f64 {
        const cold = self.coldState() orelse return 0;
        if (!cold.hasRare(.date)) return 0;
        // A zero-effect RMW forces atomic TSan instrumentation on every Zig
        // revision while preserving every IEEE-754 payload bit exactly.
        return @bitCast(@constCast(&cold.date_ms_bits).fetchOr(0, .monotonic));
    }
    pub fn initDateMs(self: *Object, fallback: std.mem.Allocator, v: f64) std.mem.Allocator.Error!void {
        const cold = try self.ensureCold(fallback);
        cold.date_ms_bits.store(@bitCast(v), .monotonic);
        // `ensureRare` release-publishes the Date tag after the initial bits.
        _ = try self.ensureRare(fallback, .date, .{});
    }
    pub fn setDateMs(self: *Object, v: f64) void {
        self.coldState().?.date_ms_bits.store(@bitCast(v), .monotonic);
    }

    /// Central slice view for indexed/internal element storage. Callers retain
    /// their existing element-lock discipline; keeping the representation
    /// behind this helper lets the common Object move the list into lazy side
    /// state without exposing that layout throughout the engine.
    pub inline fn elementsItems(self: *const Object) []Value {
        const state = self.elementsState() orelse return &.{};
        return state.list.items;
    }

    pub fn elementsLen(self: *const Object) usize {
        self.lockElements();
        defer self.unlockElements();
        return self.elementsItems().len;
    }

    pub inline fn arrayLengthFloor(self: *const Object) usize {
        const cold = self.coldState() orelse return 0;
        return cold.array_len;
    }

    fn setArrayLengthFloorUnlocked(self: *Object, fallback: std.mem.Allocator, new_len: usize) std.mem.Allocator.Error!void {
        std.debug.assert(new_len <= std.math.maxInt(u32));
        if (new_len <= self.elementsItems().len) {
            if (self.coldState()) |cold| cold.array_len = 0;
            return;
        }
        const cold = try self.ensureCold(fallback);
        cold.array_len = @intCast(new_len);
    }

    pub fn arrayLength(self: *const Object) usize {
        self.lockElements();
        defer self.unlockElements();
        return @max(self.elementsItems().len, self.arrayLengthFloor());
    }

    pub fn elementAt(self: *const Object, i: usize) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len) return null;
        return self.elementsItems()[i];
    }

    pub fn setElementAt(self: *Object, i: usize, v: Value) bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len) return false;
        gcBarrier(self, v);
        self.elementsItems()[i] = v;
        return true;
    }

    pub fn appendElement(self: *Object, arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        const elements = try self.ensureElementsList(arena);
        try elements.append(self.elementsAllocator(arena), v);
    }

    pub fn appendElementIfLen(self: *Object, arena: std.mem.Allocator, expected_len: usize, v: Value) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.elementsItems().len != expected_len) return false;
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        const elements = try self.ensureElementsList(arena);
        try elements.append(self.elementsAllocator(arena), v);
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
        const elements = try self.ensureElementsList(arena);
        try elements.append(self.elementsAllocator(arena), v);
    }

    /// Append an array-literal elision at the current dense end. The slot
    /// contributes to array length but remains an absent indexed property.
    pub fn appendArrayHole(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        try self.markHoleUnlocked(arena, self.elementsItems().len);
        const elements = try self.ensureElementsList(arena);
        try elements.append(self.elementsAllocator(arena), Value.undef());
    }

    /// Atomic fast path for `Array.prototype.push` on a packed dense Array.
    /// Returns the new logical length, or null when holes/sparse tail require
    /// the full observable `[[Set]]` path.
    pub fn appendPackedDenseElements(self: *Object, arena: std.mem.Allocator, values: []const Value) std.mem.Allocator.Error!?usize {
        self.lockElements();
        defer self.unlockElements();
        if (self.holesMap() != null or self.arrayLengthFloor() > self.elementsItems().len) return null;
        const new_len = std.math.add(usize, self.elementsItems().len, values.len) catch return null;
        if (new_len > 4294967295) return null;
        const elements = try self.ensureElementsList(arena);
        // Capacity is the only fallible step. Reserve it before barriers,
        // indexed publication, or the observable length changes so OOM leaves
        // the packed array logically untouched.
        try elements.ensureTotalCapacity(self.elementsAllocator(arena), new_len);
        for (values) |v| gcBarrier(self, v);
        elements.appendSliceAssumeCapacity(values);
        if (values.len != 0) self.indexed_own_seen.store(true, .release);
        return new_len;
    }

    /// Fast path for CreateDataPropertyOrThrow on a plain dense Array when the
    /// requested index is exactly the current logical end. The check and append
    /// are one element-lock critical section so a peer grow cannot race the
    /// `items.len` observation.
    pub fn appendDataIndexIfDense(self: *Object, arena: std.mem.Allocator, i: usize, v: Value) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.holesMap() != null or i != self.elementsItems().len or self.arrayLengthFloor() > i) return false;
        if (i >= 4294967295) return false;
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        const elements = try self.ensureElementsList(arena);
        try elements.append(self.elementsAllocator(arena), v);
        return true;
    }

    pub fn atomicDenseElementLoad(self: *Object, i: usize) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return null;
        return self.elementsItems()[i];
    }

    pub fn atomicDenseElementStore(self: *Object, i: usize, v: Value) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return null;
        gcBarrier(self, v);
        self.elementsItems()[i] = v;
        return v;
    }

    pub fn atomicDenseElementExchange(self: *Object, i: usize, v: Value) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return null;
        const old = self.elementsItems()[i];
        gcBarrier(self, v);
        self.elementsItems()[i] = v;
        return old;
    }

    pub fn atomicDenseElementCompareExchange(self: *Object, i: usize, expected: Value, replacement: Value) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return null;
        const old = self.elementsItems()[i];
        if (sameValueZero(old, expected)) {
            gcBarrier(self, replacement);
            self.elementsItems()[i] = replacement;
        }
        return old;
    }

    pub const DenseElementRmwOp = enum { add, sub, and_, or_, xor };

    pub fn atomicDenseElementRmwNumber(self: *Object, i: usize, operand: f64, op: DenseElementRmwOp) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return null;
        const old = self.elementsItems()[i];
        if (!old.isNumber()) return null;
        const result: f64 = switch (op) {
            .add => old.asNum() + operand,
            .sub => old.asNum() - operand,
            .and_ => @floatFromInt(jsInt32(old.asNum()) & jsInt32(operand)),
            .or_ => @floatFromInt(jsInt32(old.asNum()) | jsInt32(operand)),
            .xor => @floatFromInt(jsInt32(old.asNum()) ^ jsInt32(operand)),
        };
        self.elementsItems()[i] = Value.num(result);
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
        if (self.elementsState()) |state| state.list.clearRetainingCapacity();
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
        return self.collectionState().?.weak_entries.items[i].value;
    }

    /// WeakMap/WeakSet `[[Has]]`.
    pub fn weakEntryHas(self: *Object, key: ?*anyopaque) bool {
        self.lockElements();
        defer self.unlockElements();
        return self.weakEntryIndexUnlocked(key) != null;
    }

    pub fn weakEntryCount(self: *Object) usize {
        self.lockElements();
        defer self.unlockElements();
        const state = self.collectionState() orelse return 0;
        return state.weak_entries.items.len;
    }

    /// WeakMap `[[Set]]` upsert: update the entry for `key` or append a new one.
    pub fn weakEntrySet(self: *Object, fallback: std.mem.Allocator, key: ?*anyopaque, v: Value) std.mem.Allocator.Error!void {
        gc_runtime.barrierWeak(@ptrCast(self));
        gcBarrier(self, v);
        self.lockElements();
        defer self.unlockElements();
        const state = try self.ensureCollectionState(fallback);
        const alloc = try self.weakEntriesAllocator(fallback);
        if (self.weakEntryIndexUnlocked(key)) |i| {
            state.weak_entries.items[i].value = v;
            self.weakIndexPut(alloc, key, i);
            return;
        }
        const i = state.weak_entries.items.len;
        try state.weak_entries.append(alloc, .{ .key = key, .value = v });
        self.weakIndexPut(alloc, key, i);
    }

    /// WeakSet `add`: append `key` if it is not already present.
    pub fn weakEntryAdd(self: *Object, fallback: std.mem.Allocator, key: ?*anyopaque) std.mem.Allocator.Error!void {
        gc_runtime.barrierWeak(@ptrCast(self));
        self.lockElements();
        defer self.unlockElements();
        const state = try self.ensureCollectionState(fallback);
        const alloc = try self.weakEntriesAllocator(fallback);
        if (self.weakEntryIndexUnlocked(key)) |i| {
            self.weakIndexPut(alloc, key, i);
            return;
        }
        const i = state.weak_entries.items.len;
        try state.weak_entries.append(alloc, .{ .key = key });
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

    // ---- Strong Map/Set acceleration index ---------------------------------
    // All of these assume the caller holds `lockElements()` (the index is
    // logically part of the ordered `elements` list it accelerates).
    /// Stored position for `hash`, or null. Null is authoritative ("absent")
    /// only while `collUnindexed()` is false.
    pub fn collIndexGet(self: *Object, hash: u64) ?u32 {
        const state = self.collectionState() orelse return null;
        return state.coll_index.get(hash);
    }
    /// Record hash→position. Ensures cold state and the backing allocator first
    /// (like the weak path). Returns false if it could not be recorded (OOM); the
    /// caller must then `collDisableIndex` so lookups stay correct.
    pub fn collIndexPut(self: *Object, fallback: std.mem.Allocator, hash: u64, pos: u32) bool {
        const state = self.ensureCollectionState(fallback) catch return false;
        const alloc = self.ensureBackingFor(fallback, "coll_index") catch return false;
        state.coll_index.put(alloc, hash, pos) catch return false;
        return true;
    }
    pub fn collIndexRemove(self: *Object, hash: u64) void {
        if (self.collectionState()) |state| _ = state.coll_index.remove(hash);
    }
    pub fn collUnindexed(self: *Object) bool {
        return if (self.collectionState()) |state| state.coll_unindexed else false;
    }
    /// Permanently drop to linear scanning (a non-indexable key or hash
    /// collision appeared). Needs cold state so the flag persists.
    pub fn collDisableIndex(self: *Object, fallback: std.mem.Allocator) void {
        const state = self.ensureCollectionState(fallback) catch return;
        state.coll_unindexed = true;
        state.coll_index.clearRetainingCapacity();
    }
    /// `clear()` empties the collection: wipe the index and re-enable it.
    pub fn collIndexReset(self: *Object) void {
        if (self.collectionState()) |state| {
            state.coll_index.clearRetainingCapacity();
            state.coll_unindexed = false;
        }
    }

    fn weakIndexKey(key: ?*anyopaque) usize {
        return if (key) |ptr| @intFromPtr(ptr) else 0;
    }

    fn weakEntryIndexUnlocked(self: *Object, key: ?*anyopaque) ?usize {
        const state = self.collectionState() orelse return null;
        const k = weakIndexKey(key);
        if (state.weak_index.get(k)) |i| {
            if (i < state.weak_entries.items.len and state.weak_entries.items[i].key == key) return i;
        }
        for (state.weak_entries.items, 0..) |entry, i| {
            if (entry.key == key) return i;
        }
        return null;
    }

    fn weakIndexPut(self: *Object, alloc: std.mem.Allocator, key: ?*anyopaque, i: usize) void {
        self.collectionState().?.weak_index.put(alloc, weakIndexKey(key), i) catch {};
    }

    pub fn weakEntrySwapRemoveAtUnlocked(self: *Object, i: usize) void {
        const state = self.collectionState().?;
        const removed_key = state.weak_entries.items[i].key;
        const last_i = state.weak_entries.items.len - 1;
        const moved_key = state.weak_entries.items[last_i].key;
        _ = state.weak_entries.swapRemove(i);
        _ = state.weak_index.remove(weakIndexKey(removed_key));
        if (i != last_i) {
            if (state.weak_index.getPtr(weakIndexKey(moved_key))) |slot| slot.* = i;
        }
    }

    /// FinalizationRegistry `register`: append a record (the strong `held` value
    /// is barriered by the caller before this store into the live registry cell).
    pub fn finRecordAppend(self: *Object, fallback: std.mem.Allocator, record: FinalizationRecord) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        const cold = try self.ensureCold(fallback);
        const allocator = try self.finalizationRecordsAllocator(fallback);
        var created = false;
        if (cold.finalization_records == null) {
            const records = try allocator.create(std.ArrayListUnmanaged(FinalizationRecord));
            records.* = .empty;
            cold.finalization_records = records;
            created = true;
        }
        const records = cold.finalization_records.?;
        errdefer if (created) {
            records.deinit(allocator);
            allocator.destroy(records);
            cold.finalization_records = null;
        };
        try records.append(allocator, record);
    }

    /// FinalizationRegistry `unregister`: remove every record whose token matches
    /// `token`; returns whether any were removed.
    pub fn finRecordUnregister(self: *Object, token: ?*anyopaque) bool {
        self.lockElements();
        defer self.unlockElements();
        const cold = self.coldState() orelse return false;
        const records = cold.finalization_records orelse return false;
        var removed = false;
        var write: usize = 0;
        for (records.items, 0..) |record, read| {
            if (record.token == token) {
                removed = true;
                continue;
            }
            if (write != read) records.items[write] = record;
            write += 1;
        }
        if (removed) records.shrinkRetainingCapacity(write);
        return removed;
    }

    /// Pop the next `ready` finalization record (its target died), or null. The
    /// caller runs the cleanup callback *after* this returns — never under the
    /// lock — so the callback may re-enter the registry.
    pub fn finRecordTakeReady(self: *Object) ?FinalizationRecord {
        self.lockElements();
        defer self.unlockElements();
        const cold = self.coldState() orelse return null;
        const records = cold.finalization_records orelse return null;
        var i: usize = 0;
        while (i < records.items.len) : (i += 1) {
            if (records.items[i].ready)
                return records.orderedRemove(i);
        }
        return null;
    }

    pub fn packedDenseElementsCoverLength(self: *const Object) bool {
        self.lockElements();
        defer self.unlockElements();
        return self.holesMap() == null and self.arrayLengthFloor() <= self.elementsItems().len;
    }

    /// Snapshot a plain packed dense Array's iteration values under
    /// `elements_lock`. Returns null when Array iteration must fall back to
    /// observable `[[Get]]` (holes, sparse logical tail, or index accessors).
    pub fn packedDenseElementsSnapshot(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]Value {
        const snapshot = try self.packedDenseStorageSnapshot(arena) orelse return null;
        return snapshot.values;
    }

    /// Copy a packed dense Array while also retaining the identity of its
    /// current element backing. Private contiguous-vector consumers compare
    /// both the encoded snapshot and this address before every direct read.
    pub fn packedDenseStorageSnapshot(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error!?PackedDenseStorageSnapshot {
        self.lockElements();
        defer self.unlockElements();
        if (self.holesMap() != null or self.arrayLengthFloor() > self.elementsItems().len or self.accessorsMap() != null) return null;
        const out = try arena.alloc(Value, self.elementsItems().len);
        @memcpy(out, self.elementsItems());
        return .{ .values = out, .source_address = @intFromPtr(self.elementsItems().ptr) };
    }

    /// Snapshot internal element-backed tuples/lists under `elements_lock`.
    /// Unlike `packedDenseElementsSnapshot`, this does not apply Array iteration
    /// semantics; callers use it only for engine-owned element lists such as
    /// iterator-helper source arrays.
    pub fn internalElementsSnapshot(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]Value {
        self.lockElements();
        defer self.unlockElements();
        const out = try arena.alloc(Value, self.elementsItems().len);
        @memcpy(out, self.elementsItems());
        return out;
    }

    pub fn denseElementLimit(self: *const Object, logical_len: usize) usize {
        self.lockElements();
        defer self.unlockElements();
        return @min(self.elementsItems().len, logical_len);
    }

    fn isHoleUnlocked(self: *const Object, i: usize) bool {
        const h = self.holesMap() orelse return false;
        return h.contains(i);
    }

    fn markHoleUnlocked(self: *Object, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        const state = try self.sparseArrayState(arena);
        const a = try self.holesAllocator(arena);
        if (state.holes == null) {
            state.holes = try a.create(std.AutoHashMapUnmanaged(usize, void));
            state.holes.?.* = .{};
        }
        try state.holes.?.put(a, i, {});
    }

    fn clearHoleUnlocked(self: *Object, i: usize) void {
        if (self.holesMap()) |h| _ = h.remove(i);
    }

    pub fn denseElementInBounds(self: *const Object, i: usize) bool {
        self.lockElements();
        defer self.unlockElements();
        return i < self.elementsItems().len;
    }

    pub fn denseElementPresent(self: *const Object, i: usize) bool {
        self.lockElements();
        defer self.unlockElements();
        return i < self.elementsItems().len and !self.isHoleUnlocked(i);
    }

    pub fn denseElement(self: *const Object, i: usize) ?Value {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return null;
        return self.elementsItems()[i];
    }

    pub fn denseElementIndices(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]usize {
        self.lockElements();
        defer self.unlockElements();
        var list: std.ArrayListUnmanaged(usize) = .empty;
        errdefer list.deinit(arena);
        for (self.elementsItems(), 0..) |_, i| {
            if (self.isHoleUnlocked(i)) continue;
            try list.append(arena, i);
        }
        return list.items;
    }

    pub fn setDenseElement(self: *Object, i: usize, v: Value) bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len) return false;
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        self.elementsItems()[i] = v;
        self.clearHoleUnlocked(i);
        return true;
    }

    /// Replace one existing, present dense element without changing Array
    /// length or filling a hole. The presence check and write share one element
    /// lock so a parallel delete/truncate cannot race between them.
    pub fn replaceDenseElement(self: *Object, i: usize, v: Value) bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return false;
        gcBarrier(self, v);
        self.elementsItems()[i] = v;
        return true;
    }

    /// Replace one existing, present dense element after the caller has fired
    /// an exact managed-cell barrier. Unlike the exclusive variant below, this
    /// retains the element lock and presence check required by shared-realm
    /// quick paths racing delete/truncate operations.
    pub fn replaceDenseElementPresentAfterBarrier(self: *Object, i: usize, v: Value) bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len or self.isHoleUnlocked(i)) return false;
        self.elementsItems()[i] = v;
        return true;
    }

    /// Replace a prevalidated present dense element after the caller has fired
    /// the appropriate GC barrier. Only isolated quick paths that already proved
    /// exclusive access, bounds, and a hole-free dense store may use this.
    pub inline fn replaceDenseElementExclusivePresentAfterBarrier(self: *Object, i: usize, v: Value) void {
        std.debug.assert(i < self.elementsItems().len);
        std.debug.assert(self.holesMap() == null);
        self.elementsItems()[i] = v;
    }

    pub fn growDenseElement(self: *Object, arena: std.mem.Allocator, i: usize, v: Value) std.mem.Allocator.Error!usize {
        self.lockElements();
        defer self.unlockElements();
        gcBarrier(self, v);
        self.indexed_own_seen.store(true, .release);
        const gap_start = self.elementsItems().len;
        const elements = try self.ensureElementsList(arena);
        while (self.elementsItems().len <= i) try elements.append(self.elementsAllocator(arena), Value.undef());
        self.elementsItems()[i] = v;
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
        if (i < self.elementsItems().len) {
            self.elementsItems()[i] = v;
            self.clearHoleUnlocked(i);
            return true;
        }
        if (i >= dense_cap or i > self.elementsItems().len + 1024) return false;
        const gap_start = self.elementsItems().len;
        const elements = try self.ensureElementsList(arena);
        while (self.elementsItems().len <= i) try elements.append(self.elementsAllocator(arena), Value.undef());
        self.elementsItems()[i] = v;
        self.clearHoleUnlocked(i);
        var g = gap_start;
        while (g < i) : (g += 1) try self.markHoleUnlocked(arena, g);
        return true;
    }

    pub fn deleteDenseElement(self: *Object, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!bool {
        self.lockElements();
        defer self.unlockElements();
        if (i >= self.elementsItems().len) return false;
        self.elementsItems()[i] = Value.undef();
        try self.markHoleUnlocked(arena, i);
        return true;
    }

    pub fn truncateDenseElementsAndSetLength(self: *Object, fallback: std.mem.Allocator, new_len: usize) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        if (new_len < self.elementsItems().len) self.elementsState().?.list.shrinkRetainingCapacity(new_len);
        try self.setArrayLengthFloorUnlocked(fallback, new_len);
    }

    pub fn extendArrayLengthFloor(self: *Object, fallback: std.mem.Allocator, new_len: usize) std.mem.Allocator.Error!void {
        self.lockElements();
        defer self.unlockElements();
        try self.setArrayLengthFloorUnlocked(fallback, @max(self.arrayLengthFloor(), new_len));
    }

    pub fn reversePackedDenseElements(self: *Object) bool {
        self.lockElements();
        defer self.unlockElements();
        if (self.holesMap() != null or self.arrayLengthFloor() > self.elementsItems().len) return false;
        std.mem.reverse(Value, self.elementsItems());
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
        // If a sparse logical tail will need cold storage, reserve it before
        // mutating an existing array so OOM cannot leave a half-replaced value.
        if (new_len > values.len and self.coldState() == null) _ = try self.ensureCold(arena);
        self.indexed_own_seen.store(true, .release);
        for (values) |v| gcBarrier(self, v);
        const elements = try self.ensureElementsList(arena);
        elements.clearRetainingCapacity();
        try elements.appendSlice(self.elementsAllocator(arena), values);
        if (self.holesMap()) |h| h.clearRetainingCapacity();
        try self.setArrayLengthFloorUnlocked(arena, new_len);
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
        if (self.holesMap() != null or self.arrayLengthFloor() > self.elementsItems().len) return false;
        for (inserts) |v| gcBarrier(self, v);
        if (inserts.len != 0) self.indexed_own_seen.store(true, .release);
        var i: usize = 0;
        while (i < delete_count) : (i += 1) {
            if (start < self.elementsItems().len) {
                _ = self.elementsState().?.list.orderedRemove(start);
            }
        }
        var j: usize = inserts.len;
        while (j > 0) : (j -= 1) {
            const elements = try self.ensureElementsList(arena);
            try elements.insert(self.elementsAllocator(arena), start, inserts[j - 1]);
        }
        if (self.coldState()) |cold| cold.array_len = 0;
        return true;
    }

    pub fn resetSlotsForRebuild(self: *Object) void {
        self.lockProperties();
        defer self.unlockProperties();
        self.resetSlotsForRebuildUnlocked();
    }

    fn resetSlotsForRebuildUnlocked(self: *Object) void {
        if (self.slotsState()) |state| {
            if (self.activeBackingAllocator("slots")) |allocator| {
                state.list.deinit(allocator);
                allocator.destroy(state);
                self.deactivateBacking("slots");
            }
        }
        self.initInlineSlots();
    }

    pub fn deinitKeyOrder(self: *Object) void {
        self.lockProperties();
        defer self.unlockProperties();
        self.deinitKeyOrderUnlocked();
    }

    fn deinitKeyOrderUnlocked(self: *Object) void {
        if (self.keyOrder()) |ord| {
            if (self.activeBackingAllocator("key_order")) |a| {
                for (ord.items) |key| a.free(key);
                ord.deinit(a);
                a.destroy(ord);
                self.deactivateBacking("key_order");
            }
        }
        self.setKeyOrder(null);
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
        const cold = try self.ensureCold(arena);
        const old_key_order = self.keyOrder();
        const old_backing_allocator = self.activeBackingAllocator("key_order");
        const old_uses_backing = old_backing_allocator != null;
        const backing = self.backingForTracked(arena, "key_order");
        const alloc = backing.allocator;
        errdefer if (backing.activated) self.deactivateBacking("key_order");
        const ko = try alloc.create(std.ArrayListUnmanaged([]const u8));
        ko.* = .empty;
        errdefer {
            for (ko.items) |key| alloc.free(key);
            ko.deinit(alloc);
            alloc.destroy(ko);
        }
        for (names) |name| try appendOwnedKey(ko, alloc, name);
        if (old_key_order) |ord| {
            if (old_uses_backing) {
                const a = old_backing_allocator.?;
                for (ord.items) |key| a.free(key);
                ord.deinit(a);
                a.destroy(ord);
            }
        }
        cold.key_order.store(ko, .monotonic);
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
        while (o.proxyTarget()) |t| {
            guard += 1;
            if (guard > 10000) return false;
            o = t;
        }
        if (o.proxy_revoked) return o.behavior.proxy_callable;
        return o.hostCallback() != null or o.native != null or
            (if (o.hostClassHooks()) |hooks| if (hooks.is_callable) |is_callable| is_callable(o) else false else false) or
            o.jsFunction() != null or o.errorCtor() != null or o.boundFunction() != null;
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
                return o.getOwnUnlocked(k) != null or (o.accessorsMap() orelse return false).get(k) != null;
            }
        }.f;
        const contains = struct {
            fn f(list: []const []const u8, k: []const u8) bool {
                for (list) |e| if (std.mem.eql(u8, e, k)) return true;
                return false;
            }
        }.f;
        if (self.keyOrder()) |ord| {
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
            if (self.accessorsMap()) |m| {
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
        const cold = self.coldState() orelse return null;
        return @atomicLoad(?*std.StringHashMapUnmanaged(PropAttr), &cold.attrs, .monotonic);
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
        const cold = try self.ensureCold(arena);
        const alloc = try self.attrsAllocator(arena);
        if (self.attrsMap() == null) {
            const m = try alloc.create(std.StringHashMapUnmanaged(PropAttr));
            m.* = .{};
            // Publish the map pointer atomically so off-lock `attrsMap()` readers
            // (fast-path guards) synchronize with it; content stays under the lock.
            @atomicStore(?*std.StringHashMapUnmanaged(PropAttr), &cold.attrs, m, .release);
        }
        const attrs = self.attrsMap().?;
        if (attrs.getPtr(name)) |value_ptr| {
            value_ptr.* = a;
            return;
        }
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const gop = try attrs.getOrPut(alloc, owned_name);
        std.debug.assert(!gop.found_existing); // property_lock excludes a competing insert
        gop.key_ptr.* = owned_name;
        gop.value_ptr.* = a;
    }

    fn deleteAttrUnlocked(self: *Object, name: []const u8) void {
        const m = self.attrsMap() orelse return;
        if (m.fetchRemove(name)) |removed| {
            if (self.activeBackingAllocator("attrs")) |allocator| allocator.free(removed.key);
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
        const m = self.privateBrands() orelse return false;
        return m.contains(name);
    }

    /// Brand this object with the private name `name` (PrivateFieldAdd /
    /// PrivateMethodOrAccessorAdd record-keeping). Funneled through
    /// `property_lock` (see `hasPrivateBrand`) so concurrent brand-adds on a
    /// shared object can't race the lazy-init or the `StringHashMap` grow.
    pub fn addPrivateBrand(self: *Object, arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        const cold = try self.ensureCold(arena);
        const alloc = try self.accessorsAllocator(arena);
        if (cold.private_brands == null) {
            cold.private_brands = try alloc.create(std.StringHashMapUnmanaged(void));
            cold.private_brands.?.* = .{};
        }
        try cold.private_brands.?.put(alloc, name, {});
    }

    /// An own accessor (get/set) property, if present.
    pub fn getAccessor(self: *const Object, name: []const u8) ?Accessor {
        self.lockProperties();
        defer self.unlockProperties();
        return self.getAccessorUnlocked(name);
    }

    fn getAccessorUnlocked(self: *const Object, name: []const u8) ?Accessor {
        const m = self.accessorsMap() orelse return null;
        return m.get(name);
    }

    /// Publish a lazily allocated descriptor cell only if the accessor still
    /// has the getter/setter snapshot used to build it. Repeated traversals then
    /// observe JSC's stable GetterSetter cell identity.
    pub fn installAccessorDescriptorCell(
        self: *Object,
        name: []const u8,
        getter: ?Value,
        setter: ?Value,
        candidate: *Object,
    ) ?*Object {
        self.lockProperties();
        defer self.unlockProperties();
        const accessors = self.accessorsMap() orelse return null;
        const accessor = accessors.getPtr(name) orelse return null;
        const same_optional = struct {
            fn f(left: ?Value, right: ?Value) bool {
                if (left == null or right == null) return left == null and right == null;
                return left.?.bits == right.?.bits;
            }
        }.f;
        if (!same_optional(accessor.get, getter) or !same_optional(accessor.set, setter)) return null;
        if (accessor.descriptor_cell) |existing| return existing;
        gcBarrier(self, Value.obj(candidate));
        accessor.descriptor_cell = candidate;
        return candidate;
    }

    pub fn customAccessorDescriptorCell(self: *const Object, name: []const u8) ?*Object {
        self.lockProperties();
        defer self.unlockProperties();
        const owner = self.cApiObjectOwner() orelse return null;
        return owner.custom_accessor_cells.get(name);
    }

    pub fn installCustomAccessorDescriptorCell(
        self: *Object,
        name: []const u8,
        candidate: *Object,
    ) std.mem.Allocator.Error!*Object {
        self.lockProperties();
        defer self.unlockProperties();
        const owner = self.cApiObjectOwner() orelse return error.OutOfMemory;
        if (owner.custom_accessor_cells.get(name)) |existing| return existing;
        const owned_name = try owner.allocator.dupe(u8, name);
        errdefer owner.allocator.free(owned_name);
        gcBarrier(self, Value.obj(candidate));
        try owner.custom_accessor_cells.put(owner.allocator, owned_name, candidate);
        return candidate;
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
        const m = self.accessorsMap() orelse return &.{};
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
        const cold = try self.ensureCold(arena);
        const alloc = try self.accessorsAllocator(arena);
        if (self.accessorsMap() == null) {
            const nm = try alloc.create(std.StringHashMapUnmanaged(Accessor));
            nm.* = .{};
            cold.accessors.store(nm, .monotonic); // publish under lockProperties
        }
        const accessors = self.accessorsMap().?;
        var inserted = false;
        const value_ptr = accessors.getPtr(name) orelse entry: {
            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            const gop = try accessors.getOrPut(alloc, owned_name);
            std.debug.assert(!gop.found_existing); // property_lock excludes a competing insert
            gop.key_ptr.* = owned_name;
            gop.value_ptr.* = .{};
            inserted = true;
            break :entry gop.value_ptr;
        };
        if (inserted) {
            if (canonicalIndex(name) != null) {
                self.has_indexed_property.store(true, .monotonic);
                self.indexed_own_seen.store(true, .release);
            }
            // First accessor on this object: start key_order by snapshotting the
            // existing data keys (shape-chain insertion order), so the new
            // accessor interleaves correctly with them.
            try self.ensureKeyOrderUnlocked(arena);
            try self.recordKeyOrderUnlocked(arena, name);
        }
        if (get) |g| {
            gcBarrier(self, g);
            value_ptr.get = g;
            value_ptr.descriptor_cell = null;
        }
        if (set) |s| {
            gcBarrier(self, s);
            value_ptr.set = s;
            value_ptr.descriptor_cell = null;
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
        const ko = self.keyOrder() orelse return;
        for (ko.items) |e| if (std.mem.eql(u8, e, name)) return;
        const alloc = try self.keyOrderAllocator(arena);
        try appendOwnedKey(ko, alloc, name);
    }

    /// Lazily build `key_order`, seeding it with the current data keys in
    /// insertion order (the order the shape chain already encodes).
    fn ensureKeyOrder(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.lockProperties();
        defer self.unlockProperties();
        try self.ensureKeyOrderUnlocked(arena);
    }

    fn ensureKeyOrderUnlocked(self: *Object, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.keyOrder() != null) return;
        const cold = try self.ensureCold(arena);
        const backing = self.backingForTracked(arena, "key_order");
        const alloc = backing.allocator;
        errdefer if (backing.activated) self.deactivateBacking("key_order");
        const ko = try alloc.create(std.ArrayListUnmanaged([]const u8));
        ko.* = .empty;
        errdefer {
            for (ko.items) |key| alloc.free(key);
            ko.deinit(alloc);
            alloc.destroy(ko);
        }
        var seed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer seed.deinit(arena);
        var s = self.shape;
        while (s) |sh| {
            if (sh.name) |n| try seed.append(arena, n);
            s = sh.parent;
        }
        std.mem.reverse([]const u8, seed.items); // newest-first → insertion order
        for (seed.items) |n| try appendOwnedKey(ko, alloc, n);
        cold.key_order.store(ko, .monotonic);
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
        return self.slotsItems()[slot];
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
                self.slotsItems()[slot] = v;
                return;
            }
        }
        const base = self.shape orelse root;
        const child = try base.transition(name);
        try self.appendSlot(arena, v); // new slot index == base.count == child.slot
        self.shape = child;
        if (canonicalIndex(name) != null) {
            self.has_indexed_property.store(true, .monotonic);
            self.indexed_own_seen.store(true, .release);
        }
        // A new data key on an accessor-bearing object records its creation order
        // (a data↔accessor conversion keeps its position; deleteOwn drops stale
        // entries so a genuinely re-added key lands at the end).
        if (self.keyOrder() != null) try self.recordKeyOrderUnlocked(arena, name);
    }

    /// JSC's `putDirectOffset`: replace an existing shape slot without a
    /// property lookup or transition. The caller supplies a proven offset; an
    /// invalid offset is rejected instead of indexing uninitialized storage.
    pub fn putDirectOffset(self: *Object, offset: u32, v: Value) bool {
        self.lockProperties();
        defer self.unlockProperties();
        const slots = self.slotsItems();
        if (offset >= slots.len) return false;
        gcBarrier(self, v);
        @constCast(slots)[offset] = v;
        return true;
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
        return self.deleteAccessorOwnUnlocked(arena, key);
    }

    fn deleteAccessorOwnUnlocked(self: *Object, arena: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!AccessorDeleteResult {
        const m = self.accessorsMap() orelse return .absent;
        if (m.getPtr(key) == null) return .absent;
        if (!self.getAttrUnlocked(key).configurable) return .blocked;
        if (m.fetchRemove(key)) |removed| {
            if (self.activeBackingAllocator("accessors")) |allocator| allocator.free(removed.key);
        }
        if (self.is_array) {
            if (canonicalIndex(key)) |i| {
                self.lockElements();
                defer self.unlockElements();
                if (i < self.elementsItems().len) try self.markHoleUnlocked(arena, i);
            }
        }
        return if (self.getOwnUnlocked(key) == null) .deleted else .removed_continue;
    }

    /// Object-literal data initialization is CreateDataProperty: replace any
    /// existing own accessor with a data property, or overwrite/create the data
    /// property directly. Do the accessor probe/delete and data slot write under
    /// one property lock; the older two-call path took the same lock twice per
    /// ordinary literal property, which shows up directly in no-GIL allocation
    /// profiles even though there is no semantic need to drop the lock between
    /// the two operations.
    pub fn defineLiteralDataOwn(self: *Object, arena: std.mem.Allocator, root: *Shape, key: []const u8, v: Value) std.mem.Allocator.Error!AccessorDeleteResult {
        self.lockProperties();
        defer self.unlockProperties();
        const deleted = try self.deleteAccessorOwnUnlocked(arena, key);
        if (deleted == .blocked) return .blocked;
        try self.setOwnUnlocked(arena, root, key, v);
        return deleted;
    }

    /// Apply an already-proven fixed-name object-literal shape transition. The
    /// bytecode caller owns the fresh, not-yet-published literal exclusively.
    /// Isolated execution can avoid `property_lock`; concurrent tracing/shared
    /// execution still takes it before revalidating every piece of object-local
    /// state that would make CreateDataProperty observable.
    pub fn applyLiteralTransition(self: *Object, arena: std.mem.Allocator, root: *Shape, child: *Shape, slot: u32, v: Value, synchronized: bool) std.mem.Allocator.Error!bool {
        if (synchronized) self.lockProperties();
        defer if (synchronized) self.unlockProperties();
        const parent = child.parent orelse return false;
        if ((self.shape orelse root) != parent or child.slot != slot) return false;
        if (self.slotsItems().len != @as(usize, slot) or child.count != slot + 1) return false;
        if (child.name == null or self.accessorsMap() != null or
            self.keyOrder() != null or self.attrsMap() != null or !self.isExtensible()) return false;

        gcBarrier(self, v);
        try self.appendSlot(arena, v);
        self.shape = child;
        if (canonicalIndex(child.name.?) != null) {
            self.has_indexed_property.store(true, .monotonic);
            self.indexed_own_seen.store(true, .release);
        }
        return true;
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

        const old_key_order = self.keyOrder();
        self.shape = root;
        self.resetSlotsForRebuildUnlocked();
        self.deleteAttrUnlocked(key);
        self.setKeyOrder(null);
        for (saved.items) |entry| {
            try self.setOwnUnlocked(arena, root, entry.k, entry.v);
            try self.setAttrUnlocked(arena, entry.k, entry.a);
        }
        self.setKeyOrder(old_key_order);
        if (preserve_order) {
            // Data->accessor conversion keeps the property's original creation
            // position; `setAccessor` will reuse this existing key-order entry.
        } else if (self.accessorsMap() != null) {
            try self.replaceKeyOrderUnlocked(arena, survived.items);
        } else {
            self.deinitKeyOrderUnlocked();
        }
        return true;
    }
};

/// Append a self-owned property name without leaking the duplicate when list
/// growth fails. Callers that build an unpublished list still own rollback for
/// entries appended by earlier iterations.
fn appendOwnedKey(
    list: *std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) std.mem.Allocator.Error!void {
    const owned = try allocator.dupe(u8, name);
    list.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

/// An accessor property: getter and/or setter functions. The private JSC ABI
/// lazily caches the internal descriptor cell without affecting ordinary
/// property reads.
pub const Accessor = struct {
    get: ?Value = null,
    set: ?Value = null,
    descriptor_cell: ?*Object = null,
};

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

    pub const boxed_kind_mask: u64 = box_mask | (@as(u64, 0b111) << tag_shift);
    pub const number_box_mask: u64 = box_mask;
    pub const object_kind_bits: u64 = box_mask | (@as(u64, tag_object) << tag_shift);
    pub const boxed_payload_mask: u64 = payload_mask;

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
    pub inline fn str(comptime s: []const u8) Value {
        return staticStr(s);
    }
    pub inline fn strAlloc(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!Value {
        return boxed(tag_string, @intFromPtr(try strcell.createCell(allocator, s)));
    }
    pub inline fn strOwned(allocator: std.mem.Allocator, s: []u8) std.mem.Allocator.Error!Value {
        return boxed(tag_string, @intFromPtr(try strcell.createCellOwned(allocator, s)));
    }
    pub inline fn strCell(cell: *const StringCell) Value {
        return boxed(tag_string, @intFromPtr(cell));
    }
    pub inline fn staticStr(comptime s: []const u8) Value {
        return boxed(tag_string, @intFromPtr(strcell.staticCell(s)));
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

    /// Exact NaN-box word used by the baseline native-code ABI. Engine code
    /// must preserve this word unchanged unless it is constructing a Number,
    /// in which case `num` remains responsible for canonicalizing NaN.
    pub inline fn rawBits(self: Value) u64 {
        return self.bits;
    }

    pub inline fn fromRawBits(bits: u64) Value {
        return .{ .bits = bits };
    }

    // Accessors (caller has checked `kind()` first).
    pub inline fn asNum(self: Value) f64 {
        return @bitCast(self.bits);
    }
    pub inline fn asStr(self: Value) []const u8 {
        return self.asStringCell().bytes;
    }
    pub inline fn asStringCell(self: Value) *const StringCell {
        return @ptrFromInt(self.bits & payload_mask);
    }
    /// O(1) ASCII classification (every code unit < 0x80), cached on the cell.
    /// For ASCII the WTF-8 bytes are a flat 1-byte-per-unit image, so byte
    /// offsets and UTF-16 indices coincide and offset conversions are O(1).
    /// Caller has checked `isString()`.
    pub inline fn strIsAscii(self: Value) bool {
        return self.asStringCell().isAscii();
    }
    /// O(1) latin1 / is8Bit classification (every code unit ≤ 0xFF), cached on
    /// the cell. Superset of `strIsAscii()`; this is the representation the
    /// flat-string storage flip and the JSC `is8Bit` ABI predicate key on.
    /// Caller has checked `isString()`.
    pub inline fn strIsLatin1(self: Value) bool {
        return self.asStringCell().isLatin1();
    }
    /// The string's bytes as canonical **WTF-8**, regardless of how the cell
    /// physically stores them. Today (WTF-8 storage) this always borrows
    /// `.bytes` with no allocation; once flat-latin1 storage is active it
    /// re-encodes a flat cell's 1-byte-per-unit image into `arena`. Every reader
    /// that interprets the bytes as WTF-8 — decoders, code-unit iteration, UTF-8
    /// egress, or copying into a WTF-8-expecting string constructor (incl.
    /// slice/substring re-wrap) — must obtain its bytes through this rather than
    /// `asStr()`. Byte-canonical readers (equality via the content hash, length,
    /// hashing) keep using `asStr()`. Caller has checked `isString()`.
    pub fn asWtf8(self: Value, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const cell = self.asStringCell();
        if (strcell.isFlatLatin1(cell.hash)) return strcell.latin1FlatToWtf8(arena, cell.bytes);
        return cell.bytes;
    }
    /// True when this string is *stored* as a flat latin1 image (1 byte/unit).
    /// Lets a reader take a representation-native shortcut (e.g. UTF-16 length ==
    /// byte length) instead of re-encoding to WTF-8. Caller has checked
    /// `isString()`.
    pub inline fn strIsFlatLatin1(self: Value) bool {
        return strcell.isFlatLatin1(self.asStringCell().hash);
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
            .object => if (self.asObj().behavior.is_htmldda) false else if (self.asObj().is_bigint) !bigIntIsZero(self.asObj()) else true,
        };
    }

    /// ECMAScript ToNumber (subset: objects coerce to NaN for now).
    pub fn toNumber(self: Value) f64 {
        return switch (self.kind()) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => if (self.asBool()) 1 else 0,
            .number => self.asNum(),
            .string => stringToNumber(self.asStr(), self.strIsFlatLatin1()),
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

    /// ToUint64 over an already-coerced Number. Decode the IEEE-754 integer
    /// bits directly so modulo 2^64 remains exact even when the input is far
    /// outside the range of an integer cast.
    pub fn uint64FromF64(n: f64) u64 {
        const bits: u64 = @bitCast(n);
        const exponent_bits: u11 = @truncate(bits >> 52);
        if (exponent_bits == 0 or exponent_bits == 0x7ff) return 0;

        const significand = (bits & ((@as(u64, 1) << 52) - 1)) | (@as(u64, 1) << 52);
        const shift: i32 = @as(i32, exponent_bits) - 1023 - 52;
        const magnitude: u64 = if (shift >= 64)
            0
        else if (shift >= 0)
            significand << @intCast(shift)
        else if (shift <= -53)
            0
        else
            significand >> @intCast(-shift);
        return if (bits >> 63 != 0) 0 -% magnitude else magnitude;
    }

    /// The `typeof` operator result.
    pub fn typeOf(self: Value) []const u8 {
        return switch (self.kind()) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => if (self.asObj().behavior.is_htmldda) "undefined" else if (self.asObj().is_symbol) "symbol" else if (self.asObj().is_bigint) "bigint" else if (self.asObj().isCallableObject()) "function" else "object",
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

test "uint64FromF64 performs exact modulo conversion" {
    try std.testing.expectEqual(@as(u64, 0), Value.uint64FromF64(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u64, 0), Value.uint64FromF64(std.math.inf(f64)));
    try std.testing.expectEqual(@as(u64, 1), Value.uint64FromF64(1.5));
    try std.testing.expectEqual(std.math.maxInt(u64), Value.uint64FromF64(-1.5));
    try std.testing.expectEqual(@as(u64, 1) << 63, Value.uint64FromF64(9223372036854775808.0));
    try std.testing.expectEqual(@as(u64, 0), Value.uint64FromF64(18446744073709551616.0));
    try std.testing.expectEqual(@as(u64, 4096), Value.uint64FromF64(18446744073709555712.0));
    try std.testing.expectEqual(@as(u64, 0), Value.uint64FromF64(1.0e300));
}

pub fn bigIntIsZero(o: *Object) bool {
    if (o.bigIntText()) |s| return std.mem.eql(u8, s, "0");
    return o.bigIntValue() == 0;
}

pub fn bigIntToNumber(o: *Object) f64 {
    if (o.bigIntText()) |s| return std.fmt.parseFloat(f64, s) catch if (s.len > 0 and s[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    return @floatFromInt(o.bigIntValue());
}

pub fn bigIntToString(o: *Object, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    if (o.bigIntText()) |s| return s;
    return std.fmt.allocPrint(arena, "{d}", .{o.bigIntValue()});
}

fn bigIntEquals(a: *Object, b: *Object) bool {
    if (a.bigIntText()) |as| {
        if (b.bigIntText()) |bs| return std.mem.eql(u8, as, bs);
        const parsed = std.fmt.parseInt(i128, as, 10) catch return false;
        return parsed == b.bigIntValue();
    }
    if (b.bigIntText()) |bs| {
        const parsed = std.fmt.parseInt(i128, bs, 10) catch return false;
        return a.bigIntValue() == parsed;
    }
    return a.bigIntValue() == b.bigIntValue();
}

/// ECMAScript-ish ToString for objects: errors render `Name: message`, arrays
/// join their elements with commas (Array.prototype.toString), everything else
/// is `[object Object]`.
fn objectToString(o: *Object, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    // A primitive-wrapper object stringifies as its boxed primitive.
    if (o.boxedPrimitive()) |p| return p.toString(arena);
    if (o.behavior.is_error) {
        const name = if (o.getOwn("name")) |v|
            (if (v.isString()) v.asStr() else o.errorName())
        else
            o.errorName();
        const msg = if (o.getOwn("message")) |v|
            (if (v.isString()) v.asStr() else "")
        else
            "";
        if (msg.len == 0) return name;
        return std.mem.concat(arena, u8, &.{ name, ": ", msg });
    }
    if (o.is_array) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (o.elementsItems(), 0..) |el, i| {
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

fn trimStringNumberWhitespace(s: []const u8, flat: bool) []const u8 {
    if (flat) {
        // Flat latin1 storage: 1 raw byte per code unit, and the bytes are not
        // valid UTF-8 (a 0xA0 NBSP byte is a bare continuation), so trim the
        // StrWhiteSpace code points directly by byte. Only U+00A0 (NBSP) fits in
        // latin1 beyond ASCII whitespace — every other StrWhiteSpace code point
        // is > 0xFF and therefore never present in a latin1 image.
        var start: usize = 0;
        var end: usize = s.len;
        while (start < end and isStringNumberWhitespace(s[start])) start += 1;
        while (end > start and isStringNumberWhitespace(s[end - 1])) end -= 1;
        return s[start..end];
    }
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
pub fn stringToNumber(s: []const u8, flat: bool) f64 {
    const nan = std.math.nan(f64);
    const trimmed = trimStringNumberWhitespace(s, flat);
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
        .string => b.isString() and a.asStringCell().eql(b.asStringCell()),
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

/// SameValue(x, y) (ECMA-262 7.2.11): like SameValueZero, but distinguishes
/// +0 from -0 — SameValue(+0, -0) is false, while SameValue(NaN, NaN) is true.
/// Used by the Proxy [[Get]]/[[Set]] invariants and Object.is.
pub fn sameValue(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNum();
        const y = b.asNum();
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        // Zeros compare equal only when their sign bits agree (+0 vs -0 differ).
        if (x == 0 and y == 0) return std.math.signbit(x) == std.math.signbit(y);
        return x == y;
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
    if ((a.isObject() and a.asObj().behavior.is_htmldda) and (b.isNull() or b.isUndefined())) return true;
    if ((b.isObject() and b.asObj().behavior.is_htmldda) and (a.isNull() or a.isUndefined())) return true;
    // BigInt == Number/Boolean/String: compare mathematically (a string is parsed
    // to a BigInt; a non-integer/unparseable comparand is unequal).
    const a_big = a.isObject() and a.asObj().is_bigint;
    const b_big = b.isObject() and b.asObj().is_bigint;
    if (a_big != b_big) {
        const big_obj = if (a_big) a.asObj() else b.asObj();
        const other = if (a_big) b else a;
        if (big_obj.bigIntText() != null) {
            return switch (other.kind()) {
                .string => std.mem.eql(u8, std.mem.trim(u8, other.asStr(), " \t\r\n"), big_obj.bigIntText().?),
                else => false,
            };
        }
        const big: i128 = big_obj.bigIntValue();
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
    try std.testing.expectEqual(@as(usize, 1), object.slotsItems().len);
    try std.testing.expectEqual(@as(?u32, 0), object.shape.?.lookup("shared"));
    try std.testing.expect(value.isNumber());
}

test "ordinary object keeps four named property values inline before migrating" {
    const root = try Shape.createRoot(std.heap.page_allocator);
    var object = Object{};
    object.initInlineSlots();

    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (names[0..4], 0..) |name, i| {
        try object.setOwn(std.testing.allocator, root, name, Value.num(@floatFromInt(i)));
    }
    try std.testing.expect(object.slotsAreInline());
    try std.testing.expect(object.slotsState() == null);
    try std.testing.expectEqual(@as(usize, 4), object.slotsItems().len);

    try object.setOwn(std.testing.allocator, root, names[4], Value.num(4));
    try std.testing.expect(!object.slotsAreInline());
    try std.testing.expect(object.slotsState() != null);
    try std.testing.expectEqual(@as(usize, 5), object.slotsItems().len);
    const state = object.slotsState().?;
    state.list.deinit(std.testing.allocator);
    std.testing.allocator.destroy(state);
    std.testing.allocator.destroy(object.storageState().?);
}

fn exerciseExternalSlotsOomRollback(allocator: std.mem.Allocator) !void {
    var four_slot_shape = Shape{
        .parent = null,
        .name = "d",
        .slot = 3,
        .count = Object.inline_slot_capacity,
        .arena = allocator,
    };
    var object = Object{ .shape = &four_slot_shape };
    for (&object.inline_slots, 0..) |*slot, i| slot.* = Value.num(@floatFromInt(i));

    object.appendSlot(allocator, Value.num(4)) catch |err| {
        try std.testing.expect(object.slotsState() == null);
        try std.testing.expectEqual(Object.inline_slot_capacity, object.slotsItems().len);
        try std.testing.expect(!object.backingFlagsSnapshot().slots);
        return err;
    };
    const state = object.slotsState().?;
    defer allocator.destroy(object.storageState().?);
    defer {
        state.list.deinit(allocator);
        allocator.destroy(state);
    }
    try std.testing.expectEqual(Object.inline_slot_capacity + 1, object.slotsItems().len);
}

test "external named slot state rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseExternalSlotsOomRollback,
        .{},
    );
}

test "external named slot state publishes once under concurrent growth" {
    const root = try Shape.createRoot(std.heap.page_allocator);
    var object = Object{};
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };

    const Worker = struct {
        fn run(o: *Object, root_shape: *Shape, name: []const u8, n: usize) void {
            o.setOwn(std.heap.page_allocator, root_shape, name, Value.num(@floatFromInt(n))) catch @panic("setOwn failed");
        }
    };
    var threads: [names.len]std.Thread = undefined;
    for (&threads, names, 0..) |*thread, name, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &object, root, name, i });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(names.len, object.slotsItems().len);
    const state = object.slotsState().?;
    state.list.deinit(std.heap.page_allocator);
    std.heap.page_allocator.destroy(state);
    std.heap.page_allocator.destroy(object.storageState().?);
}

test "Object storage wrapper converges across concurrent slot and element installation" {
    const root = try Shape.createRoot(std.heap.page_allocator);
    var object = Object{};
    for ([_][]const u8{ "a", "b", "c", "d" }, 0..) |name, i| {
        try object.setOwn(std.heap.page_allocator, root, name, Value.num(@floatFromInt(i)));
    }
    try std.testing.expect(object.storageState() == null);

    const previous_locks = Object.element_locks_enabled.swap(true, .acq_rel);
    defer Object.element_locks_enabled.store(previous_locks, .release);
    const Worker = struct {
        fn addSlot(o: *Object, root_shape: *Shape) void {
            o.setOwn(std.heap.page_allocator, root_shape, "e", Value.num(4)) catch @panic("setOwn failed");
        }
        fn addElement(o: *Object) void {
            o.appendElement(std.heap.page_allocator, Value.num(9)) catch @panic("appendElement failed");
        }
    };
    const slot_thread = try std.Thread.spawn(.{}, Worker.addSlot, .{ &object, root });
    const element_thread = try std.Thread.spawn(.{}, Worker.addElement, .{&object});
    slot_thread.join();
    element_thread.join();

    try std.testing.expectEqual(@as(usize, 5), object.slotsItems().len);
    try std.testing.expectEqual(@as(usize, 1), object.elementsItems().len);
    const storage = object.storageState().?;
    const slots = object.slotsState().?;
    const elements = object.elementsState().?;
    slots.list.deinit(std.heap.page_allocator);
    elements.list.deinit(std.heap.page_allocator);
    std.heap.page_allocator.destroy(slots);
    std.heap.page_allocator.destroy(elements);
    std.heap.page_allocator.destroy(storage);
}

fn exerciseKeyOrderOomRollback(allocator: std.mem.Allocator) !void {
    var root = Shape{ .parent = null, .name = null, .slot = 0, .count = 0, .arena = allocator };
    var alpha = Shape{ .parent = &root, .name = "alpha", .slot = 0, .count = 1, .arena = allocator };
    var beta = Shape{ .parent = &alpha, .name = "beta", .slot = 1, .count = 2, .arena = allocator };
    var gamma = Shape{ .parent = &beta, .name = "gamma", .slot = 2, .count = 3, .arena = allocator };
    var object = Object{ .shape = &gamma };
    object.initInlineSlots();
    defer if (object.storageState()) |storage| allocator.destroy(storage);
    defer if (object.coldState()) |cold| allocator.destroy(cold);
    defer if (object.keyOrder()) |order| {
        for (order.items) |key| allocator.free(key);
        order.deinit(allocator);
        allocator.destroy(order);
    };

    try object.ensureKeyOrder(allocator);
    try object.recordKeyOrder(allocator, "delta");

    const order = object.keyOrder().?;
    try std.testing.expectEqual(@as(usize, 4), order.items.len);
    try std.testing.expectEqualStrings("alpha", order.items[0]);
    try std.testing.expectEqualStrings("delta", order.items[3]);
}

test "object key-order construction rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseKeyOrderOomRollback,
        .{},
    );
}

test "fixed-shape object allocation publishes validated literal shape into inline slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Shape.createRoot(arena.allocator());
    const first = try root.transition("alpha");
    const second = try first.transition("beta");
    const final_shape = try second.transition("gamma");
    var referenced = Object{};
    referenced.initInlineSlots();

    var object = Object{};
    object.initInlineSlots();
    const values = [_]Value{ Value.num(11), Value.obj(&referenced), Value.num(33) };
    const prepared = Object.prepareInlineLiteralShape(root, final_shape, values.len) orelse return error.TestUnexpectedResult;
    try std.testing.expect(object.initializePreparedInlineLiteralShape(prepared, &values));
    try std.testing.expectEqual(final_shape, object.shape.?);
    try std.testing.expect(object.slotsAreInline());
    try std.testing.expectEqualSlices(Value, &values, object.slotsItems());

    try std.testing.expect(Object.prepareInlineLiteralShape(root, final_shape, 2) == null);
    const other_root = try Shape.createRoot(arena.allocator());
    try std.testing.expect(Object.prepareInlineLiteralShape(other_root, final_shape, values.len) == null);
    const duplicate = try first.transition("alpha");
    try std.testing.expect(Object.prepareInlineLiteralShape(root, duplicate, 2) == null);
    var wrong_count = Object{};
    wrong_count.initInlineSlots();
    try std.testing.expect(!wrong_count.initializePreparedInlineLiteralShape(prepared, values[0..2]));

    var occupied = Object{};
    occupied.initInlineSlots();
    try occupied.setOwn(arena.allocator(), root, "existing", Value.num(1));
    try std.testing.expect(!occupied.initializePreparedInlineLiteralShape(prepared, &values));
    try std.testing.expectEqual(@as(usize, 1), occupied.slotsItems().len);

    const indexed_shape = try root.transition("0");
    try std.testing.expect(Object.prepareInlineLiteralShape(root, indexed_shape, 1) == null);

    var accessor_map: std.StringHashMapUnmanaged(Accessor) = .empty;
    var accessored = Object{};
    accessored.initInlineSlots();
    var accessored_cold = ObjectColdState{ .accessors = .init(&accessor_map) };
    var accessored_storage = ObjectStorageState{ .owner_allocator = arena.allocator() };
    accessored_storage.cold.store(&accessored_cold, .monotonic);
    accessored.storage.store(&accessored_storage, .monotonic);
    try std.testing.expect(!accessored.initializePreparedInlineLiteralShape(prepared, &values));

    var attrs_map: std.StringHashMapUnmanaged(PropAttr) = .empty;
    var attributed_cold = ObjectColdState{ .attrs = &attrs_map };
    var attributed = Object{};
    var attributed_storage = ObjectStorageState{ .owner_allocator = arena.allocator() };
    attributed_storage.cold.store(&attributed_cold, .monotonic);
    attributed.storage.store(&attributed_storage, .monotonic);
    attributed.initInlineSlots();
    try std.testing.expect(!attributed.initializePreparedInlineLiteralShape(prepared, &values));

    var key_order: std.ArrayListUnmanaged([]const u8) = .empty;
    var ordered = Object{};
    ordered.initInlineSlots();
    var ordered_cold = ObjectColdState{ .key_order = .init(&key_order) };
    var ordered_storage = ObjectStorageState{ .owner_allocator = arena.allocator() };
    ordered_storage.cold.store(&ordered_cold, .monotonic);
    ordered.storage.store(&ordered_storage, .monotonic);
    try std.testing.expect(!ordered.initializePreparedInlineLiteralShape(prepared, &values));

    var sealed = Object{};
    sealed.initInlineSlots();
    sealed.setExtensible(false);
    try std.testing.expect(!sealed.initializePreparedInlineLiteralShape(prepared, &values));
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
    try std.testing.expectEqual(count, object.slotsItems().len);
}

// ---- no-GIL regression tests (issue #1): the atomic/seqlock primitives that
// keep the corpus TSan-clean. Run under `-Dtsan=true` to also catch data races;
// without TSan they still catch torn reads / crashes / corruption. ----

test "Object prototype state atomics survive concurrent setPrototypeOf" {
    var a = Object{};
    var b = Object{};
    var o = Object{ .proto = &a };
    const Worker = struct {
        fn reader(target: *Object, pa: *Object, pb: *Object, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.monotonic)) {
                const p = target.protoAtomic();
                // Must always be one of the two valid protos (never a torn ptr).
                if (p != pa and p != pb) @panic("proto torn read");
                _ = target.protoExplicitNull();
            }
        }
        fn writer(target: *Object, pa: *Object, pb: *Object, stop: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (i < 200_000) : (i += 1) {
                target.setProtoAtomic(if ((i & 1) == 0) pa else pb);
                target.setProtoExplicitNull((i & 1) == 0);
            }
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
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    Object.element_locks_enabled.store(true, .release);
    o.unlockBacking(not_locked);

    const locked = o.lockBacking();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
    Object.element_locks_enabled.store(false, .release);
    o.unlockBacking(locked);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
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
    var cold = ObjectColdState{};
    var storage = ObjectStorageState{ .owner_allocator = std.testing.allocator };
    storage.cold.store(&cold, .release);
    o.storage.store(&storage, .release);
    const Worker = struct {
        fn run(target: *Object, my_tid: u64, won: *std.atomic.Value(u32)) void {
            // Mirror Thread.restrict's claim: CAS 0 -> tid; null means we won.
            if (target.coldState().?.restricted_to.cmpxchgStrong(0, my_tid, .acq_rel, .acquire) == null)
                _ = won.fetchAdd(1, .acq_rel);
        }
    };
    var won = std.atomic.Value(u32).init(0);
    var threads: [16]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &o, @as(u64, i) + 1, &won });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 1), won.load(.acquire));
    try std.testing.expect(o.restrictionOwner() != 0);
}

test "WeakMap and WeakSet entry delete is unordered tail removal" {
    const a = std.testing.allocator;
    var o = Object{ .is_weak = true, .is_map = true };
    const cold = try o.ensureCold(a);
    const collection = try o.ensureCollectionState(a);
    defer a.destroy(o.storageState().?);
    defer a.destroy(cold);
    defer a.destroy(collection);
    defer collection.weak_entries.deinit(a);
    defer collection.weak_index.deinit(a);

    var key1: u8 = 1;
    var key2: u8 = 2;
    var key3: u8 = 3;
    try o.weakEntrySet(a, @ptrCast(&key1), Value.num(1));
    try o.weakEntrySet(a, @ptrCast(&key2), Value.num(2));
    try o.weakEntrySet(a, @ptrCast(&key3), Value.num(3));

    try std.testing.expect(o.weakEntryDelete(@ptrCast(&key1)));
    try std.testing.expectEqual(@as(usize, 2), collection.weak_entries.items.len);
    try std.testing.expect(!o.weakEntryHas(@ptrCast(&key1)));
    try std.testing.expect(o.weakEntryHas(@ptrCast(&key2)));
    try std.testing.expect(o.weakEntryHas(@ptrCast(&key3)));
    try std.testing.expectEqual(@intFromPtr(&key3), @intFromPtr(collection.weak_entries.items[0].key.?));
}

test "FinalizationRegistry unregister stable-compacts matching records" {
    const a = std.testing.allocator;
    var o = Object{ .behavior = .{ .is_finalization_registry = true } };
    const cold = try o.ensureCold(a);
    defer a.destroy(o.storageState().?);
    defer a.destroy(cold);

    var token_a: u8 = 1;
    var token_b: u8 = 2;
    var token_c: u8 = 3;
    var target1: u8 = 11;
    var target2: u8 = 12;
    var target3: u8 = 13;
    var target4: u8 = 14;
    var target5: u8 = 15;
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target1), .held = Value.num(1), .token = @ptrCast(&token_a) });
    const records = cold.finalization_records.?;
    defer a.destroy(records);
    defer records.deinit(a);
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target2), .held = Value.num(2), .token = @ptrCast(&token_b) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target3), .held = Value.num(3), .token = @ptrCast(&token_a) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target4), .held = Value.num(4), .token = @ptrCast(&token_c) });
    try o.finRecordAppend(a, .{ .target = @ptrCast(&target5), .held = Value.num(5), .token = @ptrCast(&token_a) });

    try std.testing.expect(o.finRecordUnregister(@ptrCast(&token_a)));
    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqual(@as(f64, 2), records.items[0].held.asNum());
    try std.testing.expectEqual(@as(f64, 4), records.items[1].held.asNum());
    try std.testing.expectEqual(@intFromPtr(&token_b), @intFromPtr(records.items[0].token.?));
    try std.testing.expectEqual(@intFromPtr(&token_c), @intFromPtr(records.items[1].token.?));

    var missing: u8 = 4;
    try std.testing.expect(!o.finRecordUnregister(@ptrCast(&missing)));
    try std.testing.expect(o.finRecordUnregister(@ptrCast(&token_b)));
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqual(@as(f64, 4), records.items[0].held.asNum());
}

test "stringToNumber flat-latin1 trims NBSP by byte, matching the WTF-8 path" {
    // "  5 " (NBSP, space, '5', space). Flat latin1 image is 1 byte/unit:
    // A0 20 35 20; the equivalent WTF-8 image encodes NBSP as C2 A0.
    try std.testing.expectEqual(@as(f64, 5), stringToNumber("\xa0\x20\x35\x20", true));
    try std.testing.expectEqual(@as(f64, 5), stringToNumber("\xc2\xa0\x20\x35\x20", false));
    // NBSP-wrapped decimal, flat.
    try std.testing.expectEqual(@as(f64, 0.5), stringToNumber("\xa00.5\xa0", true));
    // Pure ASCII is identical under either flag.
    try std.testing.expectEqual(@as(f64, 42), stringToNumber("  42  ", false));
    try std.testing.expectEqual(@as(f64, 42), stringToNumber("  42  ", true));
    // A non-numeric flat latin1 byte (é = 0xE9) is NaN, not a spurious parse.
    try std.testing.expect(std.math.isNan(stringToNumber("\xe9", true)));
}
