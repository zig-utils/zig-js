//! WebAssembly MVP (wg-1.0) execution engine: store, instantiation, and
//! interpreter.
//!
//! The store is host-agnostic: hosts create `MemoryInst`/`TableInst`/
//! `GlobalInst`/`ImportFunc` values and hand them to `instantiate`, which
//! wires up the module's full index spaces (imports first) and runs the
//! wg-1.0 instantiation algorithm (import checks, allocation, elem/data
//! segment application, optional start function). `invoke`/`callFuncInst`
//! run the interpreter with per-invocation state, so host imports may
//! re-enter wasm execution safely.
//!
//! Values on the operand stack and typed argument/result slots retain their
//! WebAssembly type. Numeric payloads are raw bits: i32 and f32 live in the
//! low 32 bits with the upper bits zero; i64 and f64 use all 64 bits. The
//! legacy `u64` invocation path is numeric-only.

const std = @import("std");
const agent = @import("../agent.zig");
const js_value = @import("../value.zig");
const SharedBufferStorage = @import("../shared_buffer.zig").SharedBufferStorage;
const wasm_atomic = @import("atomic.zig");
const types = @import("types.zig");
const decode = @import("decode.zig");
const validate = @import("validate.zig");
const simd = @import("simd.zig");

const Allocator = std.mem.Allocator;
pub const ValueSlot = js_value.WasmSlot;
const WasmSlot = ValueSlot;
var atomic_fence_word = std.atomic.Value(u8).init(0);

pub const ExecError = error{ OutOfMemory, Trap, Host, Exception };
pub const ImportCallError = error{ OutOfMemory, Trap, Host };

pub const RootHooks = struct {
    ctx: *anyopaque,
    enter: *const fn (*anyopaque, *js_value.WasmExecutionRoots) error{OutOfMemory}!void,
    leave: *const fn (*anyopaque, *js_value.WasmExecutionRoots) void,
    checkpoint: *const fn (*anyopaque, *js_value.WasmExecutionRoots) void,
    begin_wait: ?*const fn (*anyopaque) void = null,
    end_wait: ?*const fn (*anyopaque) void = null,
    wait_interrupted: ?*const fn (*anyopaque) bool = null,
    uncaught_ctx: ?*anyopaque = null,
    uncaught_exception: ?*const fn (*anyopaque, *js_value.WasmException) error{OutOfMemory}!void = null,
};

pub const HostException = union(enum) {
    wasm: *js_value.WasmException,
    js: struct { tag: *TagInst, value: js_value.Value },
};

/// Host-imported function. `ctx` is host-owned (traced/freed by the host).
pub const ImportFunc = struct {
    ctx: *anyopaque,
    type: types.FuncType,
    call: *const fn (ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) ImportCallError!void,
    call_slots: ?*const fn (ctx: *anyopaque, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ImportCallError!void = null,
    take_exception: ?*const fn (ctx: *anyopaque) ?HostException = null,
    clear_exception: ?*const fn (ctx: *anyopaque) void = null,
    owner_instance: ?*Instance = null,
};

pub const FunctionHost = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, func: *FuncInst) js_value.HostError!js_value.Value,
};

pub const FuncInst = union(enum) {
    defined: struct { inst: *Instance, idx: u32 }, // idx into module-defined funcs (0-based after imports)
    imported: ImportFunc, // by value
};

pub const MemoryInst = struct {
    /// Ordinary memories own this allocation. Shared memories leave it empty
    /// and read their stable, process-wide slab through `shared_storage`.
    local_bytes: []u8,
    shared_storage: ?*SharedBufferStorage = null,
    address: types.AddressType = .i32,
    limits: types.Limits,
    gpa: Allocator,
    grow_lock: std.atomic.Mutex = .unlocked,
    /// Host hook (WebAssembly JS API, issue #141): when set, `memoryGrow`
    /// calls it after the new bytes are in place and before the old bytes are
    /// freed, so the host can re-expose the grown buffer (e.g. swap a JS
    /// ArrayBuffer onto the fresh allocation). Returning false rolls the grow
    /// back failure-atomically. Null on the pure-wasm path.
    on_grow: ?*const fn (ctx: *anyopaque, mem: *MemoryInst) bool = null,
    on_grow_ctx: ?*anyopaque = null,

    pub fn pages(self: *const MemoryInst) u32 {
        return @intCast(self.bytes().len / types.PAGE_SIZE);
    }

    pub inline fn bytes(self: *const MemoryInst) []u8 {
        return if (self.shared_storage) |storage| storage.slice() else self.local_bytes;
    }

    pub inline fn isShared(self: *const MemoryInst) bool {
        return self.shared_storage != null;
    }

    /// Ordinary Wasm memory operations are byte-atomic on shared memories.
    /// This preserves the proposal's permitted tearing for multi-byte accesses
    /// while avoiding host-language data races with atomic instructions.
    pub fn readUnordered(self: *const MemoryInst, offset: usize, len: usize) u64 {
        const data = self.bytes();
        var raw: u64 = 0;
        for (0..len) |i| {
            const byte = if (self.isShared())
                @atomicLoad(u8, &data[offset + i], .monotonic)
            else
                data[offset + i];
            raw |= @as(u64, byte) << @intCast(i * 8);
        }
        return raw;
    }

    pub fn writeUnordered(self: *MemoryInst, offset: usize, len: usize, raw: u64) void {
        const data = self.bytes();
        for (0..len) |i| {
            const byte: u8 = @truncate(raw >> @intCast(i * 8));
            if (self.isShared())
                @atomicStore(u8, &data[offset + i], byte, .monotonic)
            else
                data[offset + i] = byte;
        }
    }

    pub fn writeSliceUnordered(self: *MemoryInst, offset: usize, source: []const u8) void {
        if (!self.isShared()) {
            @memcpy(self.bytes()[offset..][0..source.len], source);
            return;
        }
        for (source, 0..) |byte, i| @atomicStore(u8, &self.bytes()[offset + i], byte, .monotonic);
    }

    pub fn fillUnordered(self: *MemoryInst, offset: usize, len: usize, byte: u8) void {
        if (!self.isShared()) {
            @memset(self.bytes()[offset..][0..len], byte);
            return;
        }
        for (0..len) |i| @atomicStore(u8, &self.bytes()[offset + i], byte, .monotonic);
    }
};

fn copyMemoryUnordered(dest: *MemoryInst, dest_offset: usize, source: *const MemoryInst, source_offset: usize, len: usize) void {
    if (!dest.isShared() and !source.isShared()) {
        const to = dest.bytes()[dest_offset..][0..len];
        const from = source.bytes()[source_offset..][0..len];
        if (dest != source or dest_offset <= source_offset)
            std.mem.copyForwards(u8, to, from)
        else
            std.mem.copyBackwards(u8, to, from);
        return;
    }

    if (dest == source and dest_offset > source_offset) {
        var i = len;
        while (i > 0) {
            i -= 1;
            dest.writeUnordered(dest_offset + i, 1, source.readUnordered(source_offset + i, 1));
        }
    } else {
        for (0..len) |i| dest.writeUnordered(dest_offset + i, 1, source.readUnordered(source_offset + i, 1));
    }
}

pub const TableInst = struct {
    elems: []ValueSlot,
    address: types.AddressType = .i32,
    type: types.ValType = .funcref,
    limits: types.Limits,
    gpa: Allocator,
    lock: std.atomic.Mutex = .unlocked,
    host: ?TableHost = null,

    pub fn lockTable(self: *TableInst) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlockTable(self: *TableInst) void {
        self.lock.unlock();
    }
};

pub const TableHost = struct {
    ctx: *anyopaque,
    lock: *const fn (*anyopaque) void,
    unlock: *const fn (*anyopaque) void,
    ensure_len: *const fn (*anyopaque, usize) bool,
    sync: *const fn (*anyopaque, *TableInst, usize, usize) void,
};

pub const GlobalInst = struct {
    type: types.GlobalType,
    value: ValueSlot,
    ref_root: std.atomic.Value(u64) = .init(js_value.Value.undef().bits),
    barrier_ctx: ?*anyopaque = null,
    barrier: ?*const fn (*anyopaque, ValueSlot) void = null,
};

/// Runtime tag identity. Imported aliases point at the same TagInst; defined
/// tags allocate distinct store objects even when their payload types match.
pub const TagInst = struct {
    type: types.FuncType,
};

pub const ElemSegmentInst = struct {
    elems: []const ValueSlot,
    dropped: bool,
};

pub const DataSegmentInst = struct {
    bytes: []const u8,
    dropped: bool,
};

const GcAggregateKind = enum { struct_, array };

/// Stable Wasm GC identity. Objects and their slot arrays are individually
/// owned so publication into the instance list happens only after every
/// allocation succeeds. Fields may point across instances; the owner pointer
/// keeps tracing and future moving-GC rewriting explicit at every boundary.
pub const GcObject = struct {
    trace_ref: js_value.WasmGcRef,
    owner: *Instance,
    type_index: u32,
    kind: GcAggregateKind,
    fields: []ValueSlot,
    next: ?*GcObject = null,
    mark_epoch: u32 = 0,
    host_trace_epoch: u64 = 0,
    host_trace_next: ?*GcObject = null,
    wrapper: std.atomic.Value(?*js_value.Object) = .init(null),
};

var gc_host_trace_lock: std.atomic.Mutex = .unlocked;
var gc_host_trace_epoch = std.atomic.Value(u64).init(0);

fn gcObjectRef(object: *GcObject) *js_value.WasmGcRef {
    return &object.trace_ref;
}

fn gcObjectFromRef(reference: *js_value.WasmGcRef) *GcObject {
    return @ptrCast(@alignCast(reference.context));
}

/// Walks arbitrary-depth aggregate graphs without allocating or recursing.
/// A dedicated trace lock protects the intrusive scratch links; field reads
/// still use each owning instance's mutation lock.
fn traceGcReference(
    reference: *js_value.WasmGcRef,
    visitor: *anyopaque,
    mark_value: js_value.WasmGcMarkValueFn,
) void {
    while (!gc_host_trace_lock.tryLock()) std.atomic.spinLoopHint();
    defer gc_host_trace_lock.unlock();

    var epoch = gc_host_trace_epoch.fetchAdd(1, .monotonic) +% 1;
    if (epoch == 0) {
        epoch = gc_host_trace_epoch.fetchAdd(1, .monotonic) +% 1;
        if (epoch == 0) epoch = 1;
    }
    const first = gcObjectFromRef(reference);
    first.host_trace_epoch = epoch;
    first.host_trace_next = null;
    var worklist: ?*GcObject = first;
    while (worklist) |object| {
        worklist = object.host_trace_next;
        object.host_trace_next = null;
        const owner = object.owner;
        while (!owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
        for (object.fields) |slot| switch (slot) {
            .externref => |child| mark_value(visitor, child),
            .exnref => |exception| if (exception) |ex|
                for (ex.externrefs) |child| mark_value(visitor, child),
            .gcref => |child_ref| if (child_ref) |child_header| {
                const child = gcObjectFromRef(child_header);
                if (child.host_trace_epoch != epoch) {
                    child.host_trace_epoch = epoch;
                    child.host_trace_next = worklist;
                    worklist = child;
                }
            },
            .numeric, .vector, .funcref, .i31ref => {},
        };
        owner.gc_object_lock.unlock();
    }
}

const GcRootRegistration = struct {
    roots: *js_value.WasmExecutionRoots,
    next: ?*GcRootRegistration = null,
};

pub const GcRootHandle = struct {
    owner: *Instance,
    object: *GcObject,
    next: ?*GcRootHandle = null,
};

pub const GcWrapperRetain = union(enum) {
    existing: *js_value.Object,
    retained: *GcRootHandle,
};

pub const Imports = struct {
    funcs: []const ImportFunc = &.{}, // in import declaration order, per kind
    tables: []const *TableInst = &.{},
    mems: []const *MemoryInst = &.{},
    globals: []const *GlobalInst = &.{},
    tags: []const *TagInst = &.{},
};

pub const LinkError = error{ OutOfMemory, Link, Trap, Host, Exception };

/// A fully instantiated module: full index spaces, imports first. `module`
/// is borrowed (NOT owned); internal slices live in the instance arena.
/// Defined tables/mems/globals are owned and freed by `destroyInstance`;
/// imported ones belong to the host.
pub const Instance = struct {
    module: *const types.Module,
    funcs: []*FuncInst,
    tables: []*TableInst,
    mems: []*MemoryInst,
    globals: []*GlobalInst,
    tags: []*TagInst,
    exception_head: std.atomic.Value(usize) = .init(0),
    elem_segments: []ElemSegmentInst,
    data_segments: []DataSegmentInst,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    root_hooks: ?RootHooks = null,
    function_host: ?FunctionHost = null,
    gc_objects: ?*GcObject = null,
    gc_object_count: usize = 0,
    gc_object_lock: std.atomic.Mutex = .unlocked,
    gc_mark_epoch: u32 = 0,
    gc_active_roots: ?*GcRootRegistration = null,
    gc_external_roots: ?*GcRootHandle = null,
};

/// Stable external root indirection. A moving collector rewrites `object`
/// without changing the handle held by a JavaScript/embedding wrapper.
pub fn retainGcReference(slot: ValueSlot) error{OutOfMemory}!?*GcRootHandle {
    const reference = switch (slot) {
        .gcref => |value| value orelse return null,
        else => return null,
    };
    const object = gcObjectFromRef(reference);
    const owner = object.owner;
    const handle = try owner.gpa.create(GcRootHandle);
    handle.* = .{ .owner = owner, .object = object };
    while (!owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    handle.next = owner.gc_external_roots;
    owner.gc_external_roots = handle;
    owner.gc_object_lock.unlock();
    return handle;
}

pub fn releaseGcReference(handle: *GcRootHandle) void {
    const owner = handle.owner;
    while (!owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    var link = &owner.gc_external_roots;
    while (link.*) |candidate| {
        if (candidate == handle) {
            link.* = candidate.next;
            break;
        }
        link = &candidate.next;
    }
    owner.gc_object_lock.unlock();
    owner.gpa.destroy(handle);
}

/// Publishes exactly one weak JavaScript identity for an aggregate and roots
/// the aggregate until that wrapper is finalized. The wrapper pointer itself
/// is weak: its finalizer clears it before releasing the native root.
pub fn retainGcWrapper(slot: ValueSlot, wrapper: *js_value.Object) error{OutOfMemory}!GcWrapperRetain {
    const reference = switch (slot) {
        .gcref => |value| value orelse unreachable,
        else => unreachable,
    };
    const object = gcObjectFromRef(reference);
    const owner = object.owner;
    const handle = try owner.gpa.create(GcRootHandle);
    handle.* = .{ .owner = owner, .object = object };
    while (!owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    if (object.wrapper.load(.acquire)) |existing| {
        owner.gc_object_lock.unlock();
        owner.gpa.destroy(handle);
        return .{ .existing = existing };
    }
    object.wrapper.store(wrapper, .release);
    handle.next = owner.gc_external_roots;
    owner.gc_external_roots = handle;
    owner.gc_object_lock.unlock();
    return .{ .retained = handle };
}

pub fn releaseGcWrapper(raw: *anyopaque, wrapper: *js_value.Object) void {
    const handle: *GcRootHandle = @ptrCast(@alignCast(raw));
    const owner = handle.owner;
    while (!owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    if (handle.object.wrapper.load(.acquire) == wrapper)
        handle.object.wrapper.store(null, .release);
    var link = &owner.gc_external_roots;
    while (link.*) |candidate| {
        if (candidate == handle) {
            link.* = candidate.next;
            break;
        }
        link = &candidate.next;
    }
    owner.gc_object_lock.unlock();
    owner.gpa.destroy(handle);
}

fn createGcAggregate(inst: *Instance, type_index: u32, kind: GcAggregateKind, fields: []const ValueSlot) error{OutOfMemory}!*GcObject {
    const owned_fields = try inst.gpa.dupe(ValueSlot, fields);
    errdefer inst.gpa.free(owned_fields);
    const object = try inst.gpa.create(GcObject);
    object.* = .{
        .trace_ref = .{ .context = @ptrCast(object), .trace = traceGcReference },
        .owner = inst,
        .type_index = type_index,
        .kind = kind,
        .fields = owned_fields,
    };
    while (!inst.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    object.next = inst.gc_objects;
    inst.gc_objects = object;
    inst.gc_object_count += 1;
    inst.gc_object_lock.unlock();
    return object;
}

fn destroyGcAggregates(inst: *Instance) void {
    var root = inst.gc_external_roots;
    inst.gc_external_roots = null;
    while (root) |handle| {
        const next = handle.next;
        inst.gpa.destroy(handle);
        root = next;
    }
    var current = inst.gc_objects;
    inst.gc_objects = null;
    inst.gc_object_count = 0;
    while (current) |object| {
        const next = object.next;
        inst.gpa.free(object.fields);
        inst.gpa.destroy(object);
        current = next;
    }
}

fn markGcSlot(
    inst: *Instance,
    slot: ValueSlot,
    epoch: u32,
    worklist: *std.ArrayListUnmanaged(*GcObject),
) error{OutOfMemory}!void {
    const reference = switch (slot) {
        .gcref => |value| value orelse return,
        else => return,
    };
    const object = gcObjectFromRef(reference);
    if (object.owner != inst or object.mark_epoch == epoch) return;
    object.mark_epoch = epoch;
    try worklist.append(inst.gpa, object);
}

/// Quiescent precise collection for one instance-owned aggregate heap. The
/// caller supplies active/escaping slots; globals, tables, and published
/// exception payloads are included automatically. Cross-instance objects are
/// left to their owner. Mark allocation failure performs no sweep.
pub fn collectGcAggregatesQuiescent(inst: *Instance, roots: []const ValueSlot) error{OutOfMemory}!usize {
    while (!inst.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    defer inst.gc_object_lock.unlock();

    if (inst.gc_mark_epoch == std.math.maxInt(u32)) {
        var current = inst.gc_objects;
        while (current) |object| : (current = object.next) object.mark_epoch = 0;
        inst.gc_mark_epoch = 1;
    } else {
        inst.gc_mark_epoch += 1;
        if (inst.gc_mark_epoch == 0) inst.gc_mark_epoch = 1;
    }
    const epoch = inst.gc_mark_epoch;
    var worklist: std.ArrayListUnmanaged(*GcObject) = .empty;
    defer worklist.deinit(inst.gpa);

    for (roots) |slot| try markGcSlot(inst, slot, epoch, &worklist);
    var external_root = inst.gc_external_roots;
    while (external_root) |handle| : (external_root = handle.next)
        try markGcSlot(inst, .{ .gcref = gcObjectRef(handle.object) }, epoch, &worklist);
    var registration = inst.gc_active_roots;
    while (registration) |active| : (registration = active.next) {
        for (active.roots.stack) |slot| try markGcSlot(inst, slot, epoch, &worklist);
        for (active.roots.locals) |slot| try markGcSlot(inst, slot, epoch, &worklist);
    }
    for (inst.globals) |global| try markGcSlot(inst, global.value, epoch, &worklist);
    for (inst.tables) |table| for (table.elems) |slot|
        try markGcSlot(inst, slot, epoch, &worklist);
    var exception_raw = inst.exception_head.load(.acquire);
    while (exception_raw != 0) {
        const exception: *js_value.WasmException = @ptrFromInt(exception_raw);
        for (exception.payload) |slot| try markGcSlot(inst, slot, epoch, &worklist);
        exception_raw = if (exception.next) |next| @intFromPtr(next) else 0;
    }
    var cursor: usize = 0;
    while (cursor < worklist.items.len) : (cursor += 1)
        for (worklist.items[cursor].fields) |slot|
            try markGcSlot(inst, slot, epoch, &worklist);

    var reclaimed: usize = 0;
    var link = &inst.gc_objects;
    while (link.*) |object| {
        if (object.mark_epoch == epoch) {
            link = &object.next;
        } else {
            link.* = object.next;
            inst.gpa.free(object.fields);
            inst.gpa.destroy(object);
            inst.gc_object_count -= 1;
            reclaimed += 1;
        }
    }
    return reclaimed;
}

// ---------------------------------------------------------------------------
// Host-side constructors
// ---------------------------------------------------------------------------

/// Exact limits required by the Wasm 3.0 JavaScript embedding. Valid core
/// modules may declare larger maxima, but allocation/growth never crosses
/// these deterministic host boundaries.
pub const MAX_HOST_MEMORY64_PAGES: u64 = 262_144; // 16 GiB
pub const MAX_HOST_TABLE_ELEMENTS: u64 = 10_000_000;

/// memory64 execution requires a host whose native address type can represent
/// every address in an allocated backing. Decoding and validation remain
/// available on narrower hosts, but runtime construction fails deterministically.
pub fn memory64HostSupportedForPointerBits(pointer_bits: u16) bool {
    return pointer_bits >= 64;
}

pub fn memory64HostSupported() bool {
    return memory64HostSupportedForPointerBits(@bitSizeOf(usize));
}

pub fn createMemory(gpa: Allocator, min_pages: u32, max_pages: ?u32) error{OutOfMemory}!*MemoryInst {
    return createMemoryTyped(gpa, min_pages, if (max_pages) |value| value else null, false);
}

pub fn createMemoryTyped(gpa: Allocator, min_pages: u64, max_pages: ?u64, shared: bool) error{OutOfMemory}!*MemoryInst {
    return createMemoryAddressed(gpa, .i32, min_pages, max_pages, shared);
}

pub fn createMemoryAddressed(gpa: Allocator, address: types.AddressType, min_pages: u64, max_pages: ?u64, shared: bool) error{OutOfMemory}!*MemoryInst {
    const m = try gpa.create(MemoryInst);
    errdefer gpa.destroy(m);
    if (address == .i64 and !memory64HostSupported()) return error.OutOfMemory;
    const host_limit: u64 = if (address == .i64) MAX_HOST_MEMORY64_PAGES else types.MAX_PAGES;
    if (min_pages > host_limit) return error.OutOfMemory;
    const initial_len_u64 = std.math.mul(u64, min_pages, types.PAGE_SIZE) catch return error.OutOfMemory;
    if (initial_len_u64 > std.math.maxInt(usize)) return error.OutOfMemory;
    const initial_len: usize = @intCast(initial_len_u64);
    if (shared) {
        const max = max_pages orelse return error.OutOfMemory;
        // This implementation reserves a shared memory's complete stable slab
        // up front. Reject impossible host maxima before size conversion or an
        // allocator call so failure is deterministic and mutation-free.
        if (max > host_limit) return error.OutOfMemory;
        const max_len_u64 = std.math.mul(u64, max, types.PAGE_SIZE) catch return error.OutOfMemory;
        if (max_len_u64 > std.math.maxInt(usize)) return error.OutOfMemory;
        const storage = try SharedBufferStorage.create(initial_len, @intCast(max_len_u64));
        m.* = .{
            .local_bytes = &.{},
            .shared_storage = storage,
            .address = address,
            .limits = .{ .min = min_pages, .max = max_pages },
            .gpa = gpa,
        };
    } else {
        m.* = .{
            .local_bytes = try gpa.alloc(u8, initial_len),
            .address = address,
            .limits = .{ .min = min_pages, .max = max_pages },
            .gpa = gpa,
        };
        @memset(m.local_bytes, 0);
    }
    return m;
}

pub fn destroyMemory(gpa: Allocator, mem: *MemoryInst) void {
    if (mem.shared_storage) |storage| storage.release() else gpa.free(mem.local_bytes);
    gpa.destroy(mem);
}

/// Grow by `delta` pages. Returns the previous page count, or -1 on
/// failure (limit exceeded or allocation failure); failure leaves the
/// memory untouched.
pub fn memoryGrow(mem: *MemoryInst, delta: u32) i32 {
    const previous = memoryGrowAddressed(mem, delta) orelse return -1;
    return @intCast(previous);
}

/// Full-width core grow operation. Null is the Wasm -1 sentinel. Every size
/// conversion is checked before mutation, and the host callback can still
/// roll back a published candidate buffer atomically.
pub fn memoryGrowAddressed(mem: *MemoryInst, delta: u64) ?u64 {
    while (!mem.grow_lock.tryLock()) std.atomic.spinLoopHint();
    defer mem.grow_lock.unlock();
    const old_pages: u64 = mem.pages();
    if (delta == 0) return old_pages;
    const host_limit: u64 = if (mem.address == .i64) MAX_HOST_MEMORY64_PAGES else types.MAX_PAGES;
    const limit = @min(mem.limits.max orelse mem.address.maxMemoryPages(), host_limit);
    if (old_pages >= limit or delta > limit - old_pages) return null;
    const new_pages = old_pages + delta;
    const new_len_u64 = std.math.mul(u64, new_pages, types.PAGE_SIZE) catch return null;
    if (new_len_u64 > std.math.maxInt(usize)) return null;
    const new_len: usize = @intCast(new_len_u64);
    if (mem.shared_storage) |storage| {
        const delta_len_u64 = std.math.mul(u64, delta, types.PAGE_SIZE) catch return null;
        if (delta_len_u64 > std.math.maxInt(usize)) return null;
        const old_len = storage.growBy(@intCast(delta_len_u64)) catch return null;
        std.debug.assert(old_len / types.PAGE_SIZE == old_pages);
        if (mem.on_grow) |cb| {
            // The shared slab never moves. The hook only installs a new fixed
            // SharedArrayBuffer view; historical views remain valid and keep
            // their old lengths.
            if (!cb(mem.on_grow_ctx orelse @ptrCast(mem), mem)) {
                std.debug.assert(storage.rollbackGrow(new_len, old_len));
                return null;
            }
        }
        mem.limits.min = new_pages;
        return old_pages;
    }
    if (mem.on_grow) |cb| {
        // Host-observed grow: `realloc` may release the old bytes before the
        // hook could observe the grown buffer, so allocate fresh, publish the
        // new bytes, run the hook, and only then free the old slab.
        const fresh = mem.gpa.alloc(u8, new_len) catch return null;
        @memcpy(fresh[0..mem.local_bytes.len], mem.local_bytes);
        @memset(fresh[mem.local_bytes.len..], 0);
        const old = mem.local_bytes;
        mem.local_bytes = fresh;
        if (!cb(mem.on_grow_ctx orelse @ptrCast(mem), mem)) {
            mem.local_bytes = old;
            mem.gpa.free(fresh);
            return null;
        }
        mem.gpa.free(old);
        mem.limits.min = new_pages;
        return old_pages;
    }
    mem.local_bytes = mem.gpa.realloc(mem.local_bytes, new_len) catch return null;
    @memset(mem.local_bytes[@as(usize, old_pages) * types.PAGE_SIZE ..], 0);
    mem.limits.min = new_pages;
    return old_pages;
}

pub fn createTable(gpa: Allocator, initial: u32, max: ?u32) error{OutOfMemory}!*TableInst {
    return createTableTyped(gpa, .funcref, initial, if (max) |value| value else null);
}

pub fn createTableTyped(gpa: Allocator, elem_type: types.ValType, initial: u64, max: ?u64) error{OutOfMemory}!*TableInst {
    return createTableAddressed(gpa, .i32, elem_type, initial, max);
}

pub fn createTableAddressed(gpa: Allocator, address: types.AddressType, elem_type: types.ValType, initial: u64, max: ?u64) error{OutOfMemory}!*TableInst {
    const t = try gpa.create(TableInst);
    errdefer gpa.destroy(t);
    if (address == .i64 and !memory64HostSupported()) return error.OutOfMemory;
    if (initial > MAX_HOST_TABLE_ELEMENTS or initial > std.math.maxInt(usize)) return error.OutOfMemory;
    t.* = .{
        .elems = try gpa.alloc(ValueSlot, @intCast(initial)),
        .address = address,
        .type = elem_type,
        .limits = .{ .min = initial, .max = max },
        .gpa = gpa,
    };
    @memset(t.elems, nullTableSlot(elem_type));
    return t;
}

pub fn destroyTable(gpa: Allocator, tab: *TableInst) void {
    gpa.free(tab.elems);
    gpa.destroy(tab);
}

/// Grow by `delta` elements (null-initialized). Returns the previous
/// element count, or -1 on failure.
pub fn tableGrow(tab: *TableInst, delta: u32) i32 {
    return tableGrowWith(tab, delta, nullTableSlot(tab.type));
}

/// Grow and initialize new slots with `fill` while holding the table lock, so
/// a concurrent indirect call observes either the old table or the complete
/// grown table.
pub fn tableGrowWith(tab: *TableInst, delta: u32, fill: ValueSlot) i32 {
    const previous = tableGrowAddressed(tab, delta, fill) orelse return -1;
    return @intCast(previous);
}

pub fn tableGrowAddressed(tab: *TableInst, delta: u64, fill: ValueSlot) ?u64 {
    tab.lockTable();
    defer tab.unlockTable();
    const old: u64 = @intCast(tab.elems.len);
    if (delta == 0) return old;
    const limit = @min(tab.limits.max orelse tab.address.maxTableElements(), MAX_HOST_TABLE_ELEMENTS);
    if (old >= limit or delta > limit - old) return null;
    const new_len_u64 = old + delta;
    if (new_len_u64 > std.math.maxInt(usize)) return null;
    const new_len: usize = @intCast(new_len_u64);
    tab.elems = tab.gpa.realloc(tab.elems, new_len) catch return null;
    @memset(tab.elems[@intCast(old)..], fill);
    tab.limits.min = new_len_u64;
    return old;
}

fn tableGrowObserved(tab: *TableInst, delta: u64, fill: ValueSlot) ?u64 {
    if (tab.host) |host| host.lock(host.ctx);
    defer if (tab.host) |host| host.unlock(host.ctx);
    tab.lockTable();
    defer tab.unlockTable();
    const old: u64 = @intCast(tab.elems.len);
    if (delta == 0) return old;
    const limit = @min(tab.limits.max orelse tab.address.maxTableElements(), MAX_HOST_TABLE_ELEMENTS);
    if (old >= limit or delta > limit - old) return null;
    const new_len_u64 = old + delta;
    if (new_len_u64 > std.math.maxInt(usize)) return null;
    const new_len: usize = @intCast(new_len_u64);
    const fresh = tab.gpa.alloc(ValueSlot, new_len) catch return null;
    @memcpy(fresh[0..@intCast(old)], tab.elems);
    @memset(fresh[@intCast(old)..], fill);
    if (tab.host) |host| if (!host.ensure_len(host.ctx, new_len)) {
        tab.gpa.free(fresh);
        return null;
    };
    const retired = tab.elems;
    tab.elems = fresh;
    tab.limits.min = new_len_u64;
    if (tab.host) |host| host.sync(host.ctx, tab, @intCast(old), @intCast(delta));
    tab.gpa.free(retired);
    return old;
}

fn nullTableSlot(elem_type: types.ValType) ValueSlot {
    const reference = elem_type.refType() orelse return switch (elem_type) {
        .exnref => .{ .exnref = null },
        else => unreachable,
    };
    return switch (reference.heap) {
        .func, .nofunc => .{ .funcref = null },
        .extern_, .noextern => .{ .externref = js_value.Value.nul() },
        else => .{ .gcref = null },
    };
}

fn funcFromSlot(slot: ValueSlot) ?*FuncInst {
    return if (slot.funcref) |func| @ptrCast(@alignCast(func)) else null;
}

pub fn createGlobal(gpa: Allocator, gt: types.GlobalType, value: u64) error{OutOfMemory}!*GlobalInst {
    return createGlobalSlot(gpa, gt, .{ .numeric = value });
}

pub fn createGlobalSlot(gpa: Allocator, gt: types.GlobalType, value: ValueSlot) error{OutOfMemory}!*GlobalInst {
    const g = try gpa.create(GlobalInst);
    g.* = .{ .type = gt, .value = value };
    publishGlobalValue(g, value);
    return g;
}

fn publishGlobalValue(global: *GlobalInst, slot: ValueSlot) void {
    const bits = switch (slot) {
        .externref => |ref| ref.bits,
        .numeric, .vector, .funcref, .exnref, .i31ref, .gcref => js_value.Value.undef().bits,
    };
    global.ref_root.store(bits, .release);
    if (global.barrier) |barrier| barrier(global.barrier_ctx.?, slot);
}

pub fn setGlobalValue(global: *GlobalInst, slot: ValueSlot) void {
    global.value = slot;
    publishGlobalValue(global, slot);
}

pub fn destroyGlobal(gpa: Allocator, g: *GlobalInst) void {
    gpa.destroy(g);
}

pub fn createTag(gpa: Allocator, tag_type: types.FuncType) error{OutOfMemory}!*TagInst {
    const tag = try gpa.create(TagInst);
    tag.* = .{ .type = tag_type };
    return tag;
}

pub fn destroyTag(gpa: Allocator, tag: *TagInst) void {
    gpa.destroy(tag);
}

fn destroyExceptions(gpa: Allocator, inst: *Instance) void {
    var raw = inst.exception_head.load(.acquire);
    while (raw != 0) {
        const exception: *js_value.WasmException = @ptrFromInt(raw);
        raw = if (exception.next) |next| @intFromPtr(next) else 0;
        destroyExceptionRecord(gpa, exception);
    }
}

pub fn destroyExceptionRecord(gpa: Allocator, exception: *js_value.WasmException) void {
    gpa.free(exception.payload);
    gpa.free(exception.externrefs);
    gpa.destroy(exception);
}

// ---------------------------------------------------------------------------
// Instantiation (wg-1.0)
// ---------------------------------------------------------------------------

/// Import limits compatibility: the provided instance must be at least as
/// large as declared, and a declared maximum must be matched by a provided
/// maximum within it.
fn limitsCompatible(actual: types.Limits, declared: types.Limits) bool {
    if (actual.min < declared.min) return false;
    if (declared.max) |dmax| {
        const amax = actual.max orelse return false;
        if (amax > dmax) return false;
    }
    return true;
}

fn evalConstExpr(inst: *const Instance, ce: types.ConstExpr) ValueSlot {
    return switch (ce) {
        .i32 => |v| .{ .numeric = @as(u32, @bitCast(v)) },
        .i64 => |v| .{ .numeric = @as(u64, @bitCast(v)) },
        .f32 => |bits| .{ .numeric = @as(u64, bits) },
        .f64 => |bits| .{ .numeric = bits },
        .v128 => |bits| .{ .vector = bits },
        .global => |k| inst.globals[k].value,
        .ref_null => |ref_type| switch (ref_type) {
            .funcref => .{ .funcref = null },
            .exnref => .{ .exnref = null },
            .externref => .{ .externref = js_value.Value.nul() },
            else => unreachable,
        },
        .ref_func => |funcidx| .{ .funcref = @ptrCast(inst.funcs[funcidx]) },
    };
}

/// Allocate/link an instance and apply active segments without invoking its
/// start function. Embedders that must retain store mutations after a trapping
/// start (the JS API) take ownership here, then call `runStart` separately.
pub fn instantiateStore(gpa: Allocator, mod: *const types.Module, imports: Imports, diag: *types.Diagnostic) error{ OutOfMemory, Link }!*Instance {
    // 1. Import resolution.
    if (imports.funcs.len != mod.imported_funcs or
        imports.tables.len != mod.imported_tables or
        imports.mems.len != mod.imported_mems or
        imports.globals.len != mod.imported_globals or
        imports.tags.len != mod.imported_tags)
    {
        diag.set(types.Diagnostic.no_offset, "inconsistent import count", .{});
        return error.Link;
    }
    {
        var ti: usize = 0;
        var mi: usize = 0;
        var gi: usize = 0;
        var tag_i: usize = 0;
        for (mod.imports) |imp| {
            switch (imp.desc) {
                .func => {},
                .table => |tt| {
                    if (imports.tables[ti].address != tt.address or
                        imports.tables[ti].type != tt.elem or
                        !limitsCompatible(imports.tables[ti].limits, tt.limits))
                    {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    ti += 1;
                },
                .mem => |mt| {
                    if (imports.mems[mi].address != mt.address or
                        imports.mems[mi].isShared() != mt.shared or
                        !limitsCompatible(imports.mems[mi].limits, mt.limits))
                    {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    mi += 1;
                },
                .global => |gt| {
                    const ig = imports.globals[gi];
                    if (ig.type.val != gt.val or ig.type.mutable != gt.mutable) {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    gi += 1;
                },
                .tag => |tag_decl| {
                    const function_type = mod.funcTypeAt(tag_decl.type_index) orelse {
                        diag.set(types.Diagnostic.no_offset, "tag references a non-function type", .{});
                        return error.Link;
                    };
                    if (!types.funcTypeEql(imports.tags[tag_i].type, function_type)) {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    tag_i += 1;
                },
            }
        }
    }

    const inst = try gpa.create(Instance);
    inst.* = .{
        .module = mod,
        .funcs = &.{},
        .tables = &.{},
        .mems = &.{},
        .globals = &.{},
        .tags = &.{},
        .elem_segments = &.{},
        .data_segments = &.{},
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    var created_tables: usize = 0;
    var created_mems: usize = 0;
    var created_globals: usize = 0;
    var created_tags: usize = 0;
    errdefer {
        if (created_tables != 0)
            for (inst.tables[mod.imported_tables..][0..created_tables]) |t| destroyTable(gpa, t);
        if (created_mems != 0)
            for (inst.mems[mod.imported_mems..][0..created_mems]) |m| destroyMemory(gpa, m);
        if (created_globals != 0)
            for (inst.globals[mod.imported_globals..][0..created_globals]) |g| destroyGlobal(gpa, g);
        if (created_tags != 0)
            for (inst.tags[mod.imported_tags..][0..created_tags]) |tag| destroyTag(gpa, tag);
        inst.arena.deinit();
        gpa.destroy(inst);
    }
    const a = inst.arena.allocator();

    // Function index space: imported FuncInst copies, then defined ones.
    inst.funcs = try a.alloc(*FuncInst, mod.totalFuncs());
    var fi: usize = 0;
    for (imports.funcs) |imf| {
        const p = try a.create(FuncInst);
        p.* = .{ .imported = imf };
        p.imported.owner_instance = inst;
        inst.funcs[fi] = p;
        fi += 1;
    }
    for (0..mod.funcs.len) |j| {
        const p = try a.create(FuncInst);
        p.* = .{ .defined = .{ .inst = inst, .idx = @intCast(j) } };
        inst.funcs[fi] = p;
        fi += 1;
    }

    // 2. Allocate defined tables, memories, globals (imports first).
    inst.tables = try a.alloc(*TableInst, mod.totalTables());
    for (imports.tables, 0..) |t, k| inst.tables[k] = t;
    for (mod.tables, 0..) |tt, j| {
        const t = try createTableAddressed(gpa, tt.address, tt.elem, tt.limits.min, tt.limits.max);
        created_tables += 1;
        inst.tables[mod.imported_tables + j] = t;
    }

    inst.mems = try a.alloc(*MemoryInst, mod.totalMems());
    for (imports.mems, 0..) |m, k| inst.mems[k] = m;
    for (mod.mems, 0..) |mt, j| {
        const m = try createMemoryAddressed(gpa, mt.address, mt.limits.min, mt.limits.max, mt.shared);
        created_mems += 1;
        inst.mems[mod.imported_mems + j] = m;
    }

    inst.globals = try a.alloc(*GlobalInst, mod.totalGlobals());
    for (imports.globals, 0..) |g, k| inst.globals[k] = g;
    for (mod.globals, 0..) |gd, j| {
        const g = try createGlobalSlot(gpa, gd.type, evalConstExpr(inst, gd.init));
        created_globals += 1;
        inst.globals[mod.imported_globals + j] = g;
    }

    inst.tags = try a.alloc(*TagInst, mod.totalTags());
    for (imports.tags, 0..) |tag, k| inst.tags[k] = tag;
    for (mod.tags, 0..) |tag_decl, j| {
        const tag = try createTag(gpa, mod.funcTypeAt(tag_decl.type_index).?);
        created_tags += 1;
        inst.tags[mod.imported_tags + j] = tag;
    }

    inst.elem_segments = try a.alloc(ElemSegmentInst, mod.elems.len);
    for (mod.elems, inst.elem_segments) |elem, *segment| {
        const values = try a.alloc(ValueSlot, elem.init.len);
        for (elem.init, values) |init, *slot| slot.* = evalConstExpr(inst, init);
        segment.* = .{ .elems = values, .dropped = switch (elem.mode) {
            .passive => false,
            .active, .declarative => true,
        } };
    }
    inst.data_segments = try a.alloc(DataSegmentInst, mod.datas.len);
    for (mod.datas, inst.data_segments) |data, *segment|
        segment.* = .{ .bytes = data.bytes, .dropped = switch (data.mode) {
            .passive => false,
            .active => true,
        } };

    return inst;
}

/// Apply active segments in declaration order. Core 2 requires writes from a
/// completed segment to remain visible when a later segment traps, while the
/// failing segment itself performs no partial write.
pub fn applyActiveSegments(inst: *Instance, diag: *types.Diagnostic) error{Trap}!void {
    const mod = inst.module;

    for (mod.elems, inst.elem_segments) |e, segment| {
        const active = switch (e.mode) {
            .active => |active| active,
            .passive, .declarative => continue,
        };
        const tab = inst.tables[active.table];
        const start = switch (tab.address) {
            .i32 => @as(u64, @as(u32, @truncate(evalConstExpr(inst, active.offset).numericBits()))),
            .i64 => evalConstExpr(inst, active.offset).numericBits(),
        };
        tab.lockTable();
        const table_len: u64 = @intCast(tab.elems.len);
        const available = if (start <= table_len) tab.elems.len - @as(usize, @intCast(start)) else 0;
        if (start > table_len or segment.elems.len > available) {
            tab.unlockTable();
            diag.set(types.Diagnostic.no_offset, "out of bounds table index", .{});
            return error.Trap;
        }
        @memcpy(tab.elems[@intCast(start)..][0..segment.elems.len], segment.elems);
        tab.unlockTable();
    }

    for (mod.datas) |d| {
        const active = switch (d.mode) {
            .active => |active| active,
            .passive => continue,
        };
        const mem = inst.mems[active.mem];
        const start = switch (mem.address) {
            .i32 => @as(u64, @as(u32, @truncate(evalConstExpr(inst, active.offset).numericBits()))),
            .i64 => evalConstExpr(inst, active.offset).numericBits(),
        };
        const memory_len: u64 = @intCast(mem.bytes().len);
        const available = if (start <= memory_len) mem.bytes().len - @as(usize, @intCast(start)) else 0;
        if (start > memory_len or d.bytes.len > available) {
            diag.set(types.Diagnostic.no_offset, "out of bounds memory index", .{});
            return error.Trap;
        }
        const lo: usize = @intCast(start);
        @memcpy(mem.bytes()[lo..][0..d.bytes.len], d.bytes);
    }
}

pub fn runStart(inst: *Instance, diag: *types.Diagnostic) ExecError!void {
    if (inst.module.start) |sidx| try invoke(inst, sidx, &.{}, &.{}, diag);
}

pub fn instantiate(gpa: Allocator, mod: *const types.Module, imports: Imports, diag: *types.Diagnostic) LinkError!*Instance {
    const inst = try instantiateStore(gpa, mod, imports, diag);
    errdefer destroyInstance(gpa, inst);
    try applyActiveSegments(inst, diag);
    try runStart(inst, diag);
    return inst;
}

pub fn destroyInstance(gpa: Allocator, inst: *Instance) void {
    const mod = inst.module;
    for (inst.tables[mod.imported_tables..]) |t| destroyTable(gpa, t);
    for (inst.mems[mod.imported_mems..]) |m| destroyMemory(gpa, m);
    for (inst.globals[mod.imported_globals..]) |g| destroyGlobal(gpa, g);
    for (inst.tags[mod.imported_tags..]) |tag| destroyTag(gpa, tag);
    destroyExceptions(gpa, inst);
    destroyGcAggregates(inst);
    inst.arena.deinit();
    gpa.destroy(inst);
}

// ---------------------------------------------------------------------------
// Invocation
// ---------------------------------------------------------------------------

/// Invoke any function in the instance's index space (incl. imported).
pub fn invoke(inst: *Instance, funcidx: u32, args: []const u64, results: []u64, diag: *types.Diagnostic) ExecError!void {
    if (funcidx >= inst.funcs.len) {
        diag.set(types.Diagnostic.no_offset, "unknown function", .{});
        return error.Trap;
    }
    return callFuncInst(inst.funcs[funcidx], args, results, diag);
}

pub fn invokeSlots(inst: *Instance, funcidx: u32, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    if (funcidx >= inst.funcs.len) {
        diag.set(types.Diagnostic.no_offset, "unknown function", .{});
        return error.Trap;
    }
    return callFuncInstSlots(inst.funcs[funcidx], args, results, diag);
}

/// Invoke a function instance obtained e.g. from a table (cross-instance).
pub fn callFuncInst(f: *const FuncInst, args: []const u64, results: []u64, diag: *types.Diagnostic) ExecError!void {
    const alloc = std.heap.page_allocator;
    const slot_args = try alloc.alloc(ValueSlot, args.len);
    defer alloc.free(slot_args);
    const slot_results = try alloc.alloc(ValueSlot, results.len);
    defer alloc.free(slot_results);
    for (args, 0..) |bits, i| slot_args[i] = .{ .numeric = bits };
    try callFuncInstSlots(f, slot_args, slot_results, diag);
    for (slot_results, 0..) |slot, i| results[i] = slot.numericBits();
}

fn slotMatchesType(slot: ValueSlot, val_type: types.ValType) bool {
    if (val_type.refType()) |reference| {
        if (!reference.nullable and slotIsNull(slot)) return false;
        return switch (reference.heap) {
            .func, .nofunc => slot == .funcref,
            .extern_, .noextern => slot == .externref,
            .i31 => slot == .i31ref or (reference.nullable and slot == .gcref and slot.gcref == null),
            .eq, .any => slot == .i31ref or slot == .gcref,
            .struct_, .array, .none => slot == .gcref,
            _ => reference.heap.concreteIndex() != null and slot == .gcref,
        };
    }
    return switch (val_type) {
        .i32, .i64, .f32, .f64 => slot == .numeric,
        .v128 => slot == .vector,
        .exnref => slot == .exnref,
        else => false,
    };
}

fn argumentsMatchSignature(signature: types.FuncType, args: []const ValueSlot, result_len: usize) bool {
    if (args.len != signature.params.len or result_len != signature.results.len) return false;
    for (args, signature.params) |slot, val_type|
        if (!slotMatchesType(slot, val_type)) return false;
    return true;
}

fn callNumericImport(alloc: Allocator, imp: *const ImportFunc, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    const raw_args = try alloc.alloc(u64, args.len);
    defer alloc.free(raw_args);
    const raw_results = try alloc.alloc(u64, results.len);
    defer alloc.free(raw_results);
    for (args, 0..) |slot, i| raw_args[i] = slot.numericBits();
    try imp.call(imp.ctx, raw_args, raw_results, diag);
    for (raw_results, 0..) |bits, i| results[i] = .{ .numeric = bits };
}

/// Invoke a function instance with unambiguous numeric/reference slots.
pub fn callFuncInstSlots(f: *const FuncInst, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    switch (f.*) {
        .imported => |*imp| {
            if (!argumentsMatchSignature(imp.type, args, results.len)) {
                diag.set(types.Diagnostic.no_offset, "function signature mismatch", .{});
                return error.Trap;
            }
            if (imp.call_slots) |call_slots|
                try call_slots(imp.ctx, args, results, diag)
            else
                try callNumericImport(std.heap.page_allocator, imp, args, results, diag);
            for (results, imp.type.results) |slot, val_type| {
                if (!slotMatchesType(slot, val_type)) {
                    diag.set(types.Diagnostic.no_offset, "function signature mismatch", .{});
                    return error.Trap;
                }
            }
        },
        .defined => try runDefinedSlots(f, args, results, diag),
    }
}

fn runDefinedSlots(f: *const FuncInst, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    const def = f.defined;
    const fty = def.inst.module.funcTypeAt(def.inst.module.funcs[def.idx]).?;
    if (!argumentsMatchSignature(fty, args, results.len)) {
        diag.set(types.Diagnostic.no_offset, "function signature mismatch", .{});
        return error.Trap;
    }
    // Per-invocation state: reentrant by construction (a host import calling
    // back into wasm gets a fresh arena, stack, and frame set).
    var arena = std.heap.ArenaAllocator.init(def.inst.gpa);
    defer arena.deinit();
    var s: State = .{ .alloc = arena.allocator(), .diag = diag, .root_hooks = def.inst.root_hooks };
    defer unregisterGcRoots(&s);
    if (s.root_hooks) |hooks| {
        try hooks.enter(hooks.ctx, &s.roots);
        defer hooks.leave(hooks.ctx, &s.roots);
    }
    execute(&s, f, args, results) catch |err| {
        finalizeExceptions(&s, false);
        return err;
    };
    finalizeExceptions(&s, true);
}

// ---------------------------------------------------------------------------
// Interpreter
// ---------------------------------------------------------------------------

const MAX_FRAMES: usize = 1024;
const MAX_OPERAND_SLOTS: usize = 1 << 20;

const Label = struct {
    target_pc: u32, // loop -> body start; block/if -> pc past end
    stack_height: usize, // operand stack height when the label was pushed
    arity: usize, // values carried on branch (loop -> 0)
    is_loop: bool,
    is_try: bool = false,
};

const Frame = struct {
    func: *const FuncInst, // always .defined
    pc: u32,
    locals_base: usize,
    locals_end: usize,
    stack_base: usize, // operand stack height at entry (params already consumed)
    label_base: usize, // label stack height at entry; function label sits here
    result_arity: usize,
};

const ExceptionHandler = struct {
    frame_index: usize,
    label_index: usize,
    stack_height: usize,
    inst: *Instance,
    catches: []const types.Instr.Catch,
};

const ActiveException = struct {
    tag: *TagInst,
    payload: []const WasmSlot,
    reference: ?*js_value.WasmException = null,
    owner: *Instance,
    js_exception: js_value.Value = js_value.Value.undef(),
    is_js_exception: bool = false,
};

const State = struct {
    alloc: Allocator, // per-invocation arena
    diag: *types.Diagnostic,
    stack: std.ArrayListUnmanaged(WasmSlot) = .empty,
    locals: std.ArrayListUnmanaged(WasmSlot) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    labels: std.ArrayListUnmanaged(Label) = .empty,
    handlers: std.ArrayListUnmanaged(ExceptionHandler) = .empty,
    created_exceptions: std.ArrayListUnmanaged(*js_value.WasmException) = .empty,
    touched_instances: std.ArrayListUnmanaged(*Instance) = .empty,
    gc_registrations: std.ArrayListUnmanaged(*GcRootRegistration) = .empty,
    roots: js_value.WasmExecutionRoots = .{},
    root_hooks: ?RootHooks = null,

    fn trap(s: *State, comptime msg: []const u8) error{Trap} {
        s.diag.set(types.Diagnostic.no_offset, msg, .{});
        return error.Trap;
    }
};

fn registerGcRoots(s: *State, inst: *Instance) error{OutOfMemory}!void {
    const registration = try s.alloc.create(GcRootRegistration);
    registration.* = .{ .roots = &s.roots };
    try s.gc_registrations.append(s.alloc, registration);
    while (!inst.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
    registration.next = inst.gc_active_roots;
    inst.gc_active_roots = registration;
    inst.gc_object_lock.unlock();
}

fn unregisterGcRoots(s: *State) void {
    for (s.touched_instances.items, s.gc_registrations.items) |inst, registration| {
        while (!inst.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
        var link = &inst.gc_active_roots;
        while (link.*) |candidate| {
            if (candidate == registration) {
                link.* = candidate.next;
                break;
            }
            link = &candidate.next;
        }
        inst.gc_object_lock.unlock();
    }
    s.gc_registrations.items.len = 0;
}

fn checkpoint(s: *State) void {
    s.roots.stack = s.stack.items;
    s.roots.locals = s.locals.items;
    s.roots.exceptions = s.created_exceptions.items;
    if (s.root_hooks) |hooks| hooks.checkpoint(hooks.ctx, &s.roots);
}

fn push(s: *State, v: u64) ExecError!void {
    try pushSlot(s, .{ .numeric = v });
}

fn pushSlot(s: *State, slot: WasmSlot) ExecError!void {
    if (s.stack.items.len >= MAX_OPERAND_SLOTS) return s.trap("operand stack exhausted");
    try s.stack.append(s.alloc, slot);
}

fn pop(s: *State) u64 {
    return popSlot(s).numericBits();
}

fn popSlot(s: *State) WasmSlot {
    const v = s.stack.items[s.stack.items.len - 1];
    s.stack.items.len -= 1;
    return v;
}

fn slotIsNull(slot: WasmSlot) bool {
    return switch (slot) {
        .funcref => |value| value == null,
        .exnref => |value| value == null,
        .externref => |value| value.isNull(),
        .gcref => |value| value == null,
        .i31ref => false,
        .numeric, .vector => unreachable,
    };
}

fn gcObjectFromSlot(s: *State, slot: WasmSlot) ExecError!*GcObject {
    const reference = slot.gcref orelse return s.trap("null reference");
    return gcObjectFromRef(reference);
}

fn gcReferenceMatches(inst: ?*const Instance, slot: WasmSlot, target: types.RefType) bool {
    if (slotIsNull(slot)) return target.nullable;
    return switch (slot) {
        .i31ref => target.heap == .i31 or target.heap == .eq or target.heap == .any,
        .gcref => |raw| blk: {
            const object = gcObjectFromRef(raw.?);
            if (target.heap.concreteIndex() != null) {
                const target_inst = inst orelse break :blk false;
                if (object.owner != target_inst) break :blk false;
                break :blk validate.heapTypeMatches(
                    target_inst.module,
                    types.HeapType.concrete(object.type_index),
                    target.heap,
                );
            }
            break :blk switch (object.kind) {
                .struct_ => target.heap == .struct_ or target.heap == .eq or target.heap == .any,
                .array => target.heap == .array or target.heap == .eq or target.heap == .any,
            };
        },
        else => false,
    };
}

pub fn gcReferenceSlotMatches(inst: ?*const Instance, slot: WasmSlot, val_type: types.ValType) bool {
    const target = val_type.refType() orelse return false;
    return gcReferenceMatches(inst, slot, target);
}

fn normalizePackedField(storage: types.StorageType, slot: WasmSlot) WasmSlot {
    return switch (storage) {
        .i8 => .{ .numeric = slot.numericBits() & 0xff },
        .i16 => .{ .numeric = slot.numericBits() & 0xffff },
        .value => slot,
    };
}

fn readPackedField(storage: types.StorageType, signed: bool, slot: WasmSlot) u32 {
    const raw: u32 = @truncate(slot.numericBits());
    return switch (storage) {
        .i8 => if (signed) @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw)))))) else raw & 0xff,
        .i16 => if (signed) @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw)))))) else raw & 0xffff,
        .value => unreachable,
    };
}

fn fieldByteWidth(storage: types.StorageType) usize {
    return switch (storage) {
        .i8 => 1,
        .i16 => 2,
        .value => |value_type| switch (value_type) {
            .i32, .f32 => 4,
            .i64, .f64 => 8,
            .v128 => 16,
            else => unreachable,
        },
    };
}

fn fieldFromBytes(storage: types.StorageType, bytes: []const u8) WasmSlot {
    var bits: u128 = 0;
    for (bytes, 0..) |byte, index| bits |= @as(u128, byte) << @intCast(index * 8);
    return switch (storage) {
        .i8 => .{ .numeric = @as(u8, @truncate(bits)) },
        .i16 => .{ .numeric = @as(u16, @truncate(bits)) },
        .value => |value_type| switch (value_type) {
            .i32, .f32 => .{ .numeric = @as(u32, @truncate(bits)) },
            .i64, .f64 => .{ .numeric = @as(u64, @truncate(bits)) },
            .v128 => .{ .vector = bits },
            else => unreachable,
        },
    };
}

fn executeGc(s: *State, inst: *Instance, instr: types.Instr) ExecError!void {
    const op = switch (instr.imm) {
        .gc => |value| value,
        .gc_type => |value| value.op,
        .gc_type_field => |value| value.op,
        .gc_two_indices => |value| value.op,
        .gc_heap => |value| value.op,
        .gc_cast_branch => |value| value.op,
        else => unreachable,
    };
    switch (op) {
        .struct_new, .struct_new_default => {
            const type_index = instr.imm.gc_type.type_index;
            const structure = inst.module.types[type_index].subtype.composite.struct_;
            const fields = try s.alloc.alloc(ValueSlot, structure.fields.len);
            if (op == .struct_new) {
                var index = fields.len;
                while (index > 0) {
                    index -= 1;
                    fields[index] = normalizePackedField(structure.fields[index].storage, popSlot(s));
                }
            } else for (structure.fields, fields) |field, *slot|
                slot.* = zeroSlot(field.storage.unpacked());
            const object = try createGcAggregate(inst, type_index, .struct_, fields);
            try pushSlot(s, .{ .gcref = gcObjectRef(object) });
        },
        .struct_get, .struct_get_s, .struct_get_u => {
            const immediate = instr.imm.gc_type_field;
            const object = try gcObjectFromSlot(s, popSlot(s));
            const field = inst.module.types[immediate.type_index].subtype.composite.struct_.fields[immediate.field_index];
            while (!object.owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            const field_value = object.fields[immediate.field_index];
            object.owner.gc_object_lock.unlock();
            if (op == .struct_get) {
                try pushSlot(s, field_value);
            } else {
                try pushI32(s, readPackedField(field.storage, op == .struct_get_s, field_value));
            }
        },
        .struct_set => {
            const immediate = instr.imm.gc_type_field;
            const value = popSlot(s);
            const object = try gcObjectFromSlot(s, popSlot(s));
            const field = inst.module.types[immediate.type_index].subtype.composite.struct_.fields[immediate.field_index];
            while (!object.owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            defer object.owner.gc_object_lock.unlock();
            object.fields[immediate.field_index] = normalizePackedField(field.storage, value);
        },
        .array_new, .array_new_default, .array_new_fixed => {
            const immediate = if (op == .array_new_fixed)
                instr.imm.gc_two_indices
            else
                types.Instr.GcTwoIndices{ .op = op, .first = instr.imm.gc_type.type_index, .second = 0 };
            const array_type = inst.module.types[immediate.first].subtype.composite.array;
            const count: u32 = switch (op) {
                .array_new, .array_new_default => popI32(s),
                .array_new_fixed => immediate.second,
                else => unreachable,
            };
            const fields = try s.alloc.alloc(ValueSlot, count);
            if (op == .array_new_fixed) {
                var index = fields.len;
                while (index > 0) {
                    index -= 1;
                    fields[index] = normalizePackedField(array_type.field.storage, popSlot(s));
                }
            } else {
                const initial = if (op == .array_new)
                    normalizePackedField(array_type.field.storage, popSlot(s))
                else
                    zeroSlot(array_type.field.storage.unpacked());
                @memset(fields, initial);
            }
            const object = try createGcAggregate(inst, immediate.first, .array, fields);
            try pushSlot(s, .{ .gcref = gcObjectRef(object) });
        },
        .array_new_data, .array_new_elem => {
            const count = popI32(s);
            const source = popI32(s);
            const immediate = instr.imm.gc_two_indices;
            const array_type = inst.module.types[immediate.first].subtype.composite.array;
            const fields = try s.alloc.alloc(ValueSlot, count);
            if (op == .array_new_data) {
                const segment = &inst.data_segments[immediate.second];
                const bytes = if (segment.dropped) &.{} else segment.bytes;
                const width = fieldByteWidth(array_type.field.storage);
                const byte_count = std.math.mul(u64, count, width) catch return s.trap("out of bounds array initialization");
                const range = checkedRange(source, byte_count, bytes.len) orelse return s.trap("out of bounds array initialization");
                for (fields, 0..) |*field, index| {
                    const start = range.start + index * width;
                    field.* = fieldFromBytes(array_type.field.storage, bytes[start..][0..width]);
                }
            } else {
                const segment = &inst.elem_segments[immediate.second];
                const elems = if (segment.dropped) &.{} else segment.elems;
                const range = checkedRange(source, count, elems.len) orelse return s.trap("out of bounds array initialization");
                @memcpy(fields, elems[range.start..range.end]);
            }
            const object = try createGcAggregate(inst, immediate.first, .array, fields);
            try pushSlot(s, .{ .gcref = gcObjectRef(object) });
        },
        .array_get, .array_get_s, .array_get_u => {
            const index = popI32(s);
            const object = try gcObjectFromSlot(s, popSlot(s));
            if (index >= object.fields.len) return s.trap("out of bounds array access");
            const storage = inst.module.types[instr.imm.gc_type.type_index].subtype.composite.array.field.storage;
            while (!object.owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            const field_value = object.fields[index];
            object.owner.gc_object_lock.unlock();
            if (op == .array_get) {
                try pushSlot(s, field_value);
            } else {
                try pushI32(s, readPackedField(storage, op == .array_get_s, field_value));
            }
        },
        .array_set => {
            const value = popSlot(s);
            const index = popI32(s);
            const object = try gcObjectFromSlot(s, popSlot(s));
            if (index >= object.fields.len) return s.trap("out of bounds array access");
            const storage = inst.module.types[instr.imm.gc_type.type_index].subtype.composite.array.field.storage;
            while (!object.owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            defer object.owner.gc_object_lock.unlock();
            object.fields[index] = normalizePackedField(storage, value);
        },
        .array_len => {
            const object = try gcObjectFromSlot(s, popSlot(s));
            try pushI32(s, @intCast(object.fields.len));
        },
        .array_fill => {
            const count = popI32(s);
            const value = popSlot(s);
            const start = popI32(s);
            const object = try gcObjectFromSlot(s, popSlot(s));
            const range = checkedRange(start, count, object.fields.len) orelse return s.trap("out of bounds array access");
            const storage = inst.module.types[instr.imm.gc_type.type_index].subtype.composite.array.field.storage;
            while (!object.owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            defer object.owner.gc_object_lock.unlock();
            @memset(object.fields[range.start..range.end], normalizePackedField(storage, value));
        },
        .array_copy => {
            const count = popI32(s);
            const source_index = popI32(s);
            const source = try gcObjectFromSlot(s, popSlot(s));
            const destination_index = popI32(s);
            const destination = try gcObjectFromSlot(s, popSlot(s));
            const source_range = checkedRange(source_index, count, source.fields.len) orelse return s.trap("out of bounds array access");
            const destination_range = checkedRange(destination_index, count, destination.fields.len) orelse return s.trap("out of bounds array access");
            const first_owner = if (@intFromPtr(destination.owner) <= @intFromPtr(source.owner)) destination.owner else source.owner;
            const second_owner = if (first_owner == destination.owner) source.owner else destination.owner;
            while (!first_owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            if (second_owner != first_owner)
                while (!second_owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            defer {
                if (second_owner != first_owner) second_owner.gc_object_lock.unlock();
                first_owner.gc_object_lock.unlock();
            }
            const from = source.fields[source_range.start..source_range.end];
            const to = destination.fields[destination_range.start..destination_range.end];
            if (source != destination or destination_range.start <= source_range.start)
                std.mem.copyForwards(ValueSlot, to, from)
            else
                std.mem.copyBackwards(ValueSlot, to, from);
        },
        .array_init_data, .array_init_elem => {
            const count = popI32(s);
            const source = popI32(s);
            const destination_index = popI32(s);
            const destination = try gcObjectFromSlot(s, popSlot(s));
            const immediate = instr.imm.gc_two_indices;
            const destination_range = checkedRange(destination_index, count, destination.fields.len) orelse
                return s.trap("out of bounds array access");
            while (!destination.owner.gc_object_lock.tryLock()) std.atomic.spinLoopHint();
            defer destination.owner.gc_object_lock.unlock();
            if (op == .array_init_data) {
                const segment = &inst.data_segments[immediate.second];
                const bytes = if (segment.dropped) &.{} else segment.bytes;
                const storage = inst.module.types[immediate.first].subtype.composite.array.field.storage;
                const width = fieldByteWidth(storage);
                const byte_count = std.math.mul(u64, count, width) catch return s.trap("out of bounds array initialization");
                const source_range = checkedRange(source, byte_count, bytes.len) orelse return s.trap("out of bounds array initialization");
                for (destination.fields[destination_range.start..destination_range.end], 0..) |*field, index| {
                    const start = source_range.start + index * width;
                    field.* = fieldFromBytes(storage, bytes[start..][0..width]);
                }
            } else {
                const segment = &inst.elem_segments[immediate.second];
                const elems = if (segment.dropped) &.{} else segment.elems;
                const source_range = checkedRange(source, count, elems.len) orelse return s.trap("out of bounds array initialization");
                @memcpy(destination.fields[destination_range.start..destination_range.end], elems[source_range.start..source_range.end]);
            }
        },
        .ref_test, .ref_test_null, .ref_cast, .ref_cast_null => {
            const reference = popSlot(s);
            const immediate = instr.imm.gc_heap;
            const target: types.RefType = .{
                .nullable = op == .ref_test_null or op == .ref_cast_null,
                .heap = immediate.heap,
            };
            const matches = gcReferenceMatches(inst, reference, target);
            if (op == .ref_test or op == .ref_test_null) {
                try pushBool(s, matches);
            } else {
                if (!matches) return s.trap("cast failure");
                try pushSlot(s, reference);
            }
        },
        .br_on_cast, .br_on_cast_fail => {
            const reference = popSlot(s);
            const immediate = instr.imm.gc_cast_branch;
            const target: types.RefType = .{
                .nullable = immediate.target_nullable,
                .heap = immediate.target_heap,
            };
            const matches = gcReferenceMatches(inst, reference, target);
            try pushSlot(s, reference);
            if ((op == .br_on_cast and matches) or (op == .br_on_cast_fail and !matches))
                branchTo(s, immediate.label_index);
        },
        .ref_i31 => try pushSlot(s, .{ .i31ref = popI32(s) & 0x7fff_ffff }),
        .i31_get_u => try pushI32(s, popSlot(s).i31ref),
        .i31_get_s => {
            const raw = popSlot(s).i31ref;
            const signed: i32 = @as(i32, @bitCast(raw << 1)) >> 1;
            try pushI32(s, @bitCast(signed));
        },
        else => return s.trap("WebAssembly GC instruction is not implemented"),
    }
}

fn pushI32(s: *State, v: u32) ExecError!void {
    try push(s, v);
}

fn pushI64(s: *State, v: u64) ExecError!void {
    try push(s, v);
}

fn pushF32(s: *State, v: f32) ExecError!void {
    try push(s, @as(u32, @bitCast(v)));
}

fn pushF64(s: *State, v: f64) ExecError!void {
    try push(s, @bitCast(v));
}

fn pushBool(s: *State, v: bool) ExecError!void {
    try push(s, @intFromBool(v));
}

fn pushVector(s: *State, bits: u128) ExecError!void {
    try pushSlot(s, .{ .vector = bits });
}

fn popVector(s: *State) u128 {
    return popSlot(s).vectorBits();
}

fn simdOp(instr: types.Instr) simd.Op {
    return switch (instr.imm) {
        .simd => |op| op,
        .simd_memarg => |value| value.op,
        .simd_v128 => |value| value.op,
        .simd_shuffle => |value| value.op,
        .simd_lane => |value| value.op,
        .simd_memarg_lane => |value| value.op,
        else => unreachable,
    };
}

fn laneBits(vector: u128, lane: u8, width: u8) u64 {
    const shift: u7 = @intCast(@as(u16, lane) * width);
    const mask: u128 = (@as(u128, 1) << @intCast(width)) - 1;
    return @truncate((vector >> shift) & mask);
}

fn replaceLaneBits(vector: u128, lane: u8, width: u8, value: u64) u128 {
    const shift: u7 = @intCast(@as(u16, lane) * width);
    const low_mask: u128 = (@as(u128, 1) << @intCast(width)) - 1;
    const mask = low_mask << shift;
    return (vector & ~mask) | ((@as(u128, value) & low_mask) << shift);
}

fn splatLaneBits(value: u64, width: u8, count: u8) u128 {
    var vector: u128 = 0;
    for (0..count) |lane| vector = replaceLaneBits(vector, @intCast(lane), width, value);
    return vector;
}

fn readLittle(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
    return value;
}

fn writeLittle(bytes: []u8, value: u64) void {
    for (bytes, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

fn signExtendLane(value: u64, width: u8) u64 {
    const shift: u6 = @intCast(64 - width);
    return @bitCast(@as(i64, @bitCast(value << shift)) >> shift);
}

const SimdMemoryRange = struct {
    mem: *MemoryInst,
    offset: usize,
    len: usize,

    fn readLittle(self: SimdMemoryRange, relative: usize, size: usize) u64 {
        std.debug.assert(relative + size <= self.len);
        return self.mem.readUnordered(self.offset + relative, size);
    }

    fn writeLittle(self: SimdMemoryRange, relative: usize, size: usize, value: u64) void {
        std.debug.assert(relative + size <= self.len);
        self.mem.writeUnordered(self.offset + relative, size, value);
    }
};

fn simdMemoryRange(s: *State, inst: *Instance, memarg: types.Instr.MemArg, size: usize) ExecError!SimdMemoryRange {
    const mem = inst.mems[0];
    const address = popAddress(s, mem.address);
    const start = std.math.add(u64, address, memarg.offset) catch
        return s.trap("out of bounds memory access");
    const range = checkedRange(start, size, mem.bytes().len) orelse
        return s.trap("out of bounds memory access");
    return .{ .mem = mem, .offset = range.start, .len = size };
}

fn loadExtended(bytes: []const u8, source_width: u8, target_width: u8, signed: bool) u128 {
    const source_size: usize = source_width / 8;
    const lanes = bytes.len / source_size;
    var result: u128 = 0;
    for (0..lanes) |lane| {
        const start = lane * source_size;
        var value = readLittle(bytes[start..][0..source_size]);
        if (signed) value = signExtendLane(value, source_width);
        result = replaceLaneBits(result, @intCast(lane), target_width, value);
    }
    return result;
}

fn loadExtendedMemory(range: SimdMemoryRange, source_width: u8, target_width: u8, signed: bool) u128 {
    const source_size: usize = source_width / 8;
    const lanes = range.len / source_size;
    var result: u128 = 0;
    for (0..lanes) |lane| {
        var value = range.readLittle(lane * source_size, source_size);
        if (signed) value = signExtendLane(value, source_width);
        result = replaceLaneBits(result, @intCast(lane), target_width, value);
    }
    return result;
}

const SimdRelation = enum { eq, ne, lt, gt, le, ge };

const SimdComparison = struct {
    width: u8,
    signed: bool,
    relation: SimdRelation,
};

fn simdComparison(op: simd.Op) ?SimdComparison {
    return switch (op) {
        .i8x16_eq => .{ .width = 8, .signed = false, .relation = .eq },
        .i8x16_ne => .{ .width = 8, .signed = false, .relation = .ne },
        .i8x16_lt_s => .{ .width = 8, .signed = true, .relation = .lt },
        .i8x16_lt_u => .{ .width = 8, .signed = false, .relation = .lt },
        .i8x16_gt_s => .{ .width = 8, .signed = true, .relation = .gt },
        .i8x16_gt_u => .{ .width = 8, .signed = false, .relation = .gt },
        .i8x16_le_s => .{ .width = 8, .signed = true, .relation = .le },
        .i8x16_le_u => .{ .width = 8, .signed = false, .relation = .le },
        .i8x16_ge_s => .{ .width = 8, .signed = true, .relation = .ge },
        .i8x16_ge_u => .{ .width = 8, .signed = false, .relation = .ge },
        .i16x8_eq => .{ .width = 16, .signed = false, .relation = .eq },
        .i16x8_ne => .{ .width = 16, .signed = false, .relation = .ne },
        .i16x8_lt_s => .{ .width = 16, .signed = true, .relation = .lt },
        .i16x8_lt_u => .{ .width = 16, .signed = false, .relation = .lt },
        .i16x8_gt_s => .{ .width = 16, .signed = true, .relation = .gt },
        .i16x8_gt_u => .{ .width = 16, .signed = false, .relation = .gt },
        .i16x8_le_s => .{ .width = 16, .signed = true, .relation = .le },
        .i16x8_le_u => .{ .width = 16, .signed = false, .relation = .le },
        .i16x8_ge_s => .{ .width = 16, .signed = true, .relation = .ge },
        .i16x8_ge_u => .{ .width = 16, .signed = false, .relation = .ge },
        .i32x4_eq => .{ .width = 32, .signed = false, .relation = .eq },
        .i32x4_ne => .{ .width = 32, .signed = false, .relation = .ne },
        .i32x4_lt_s => .{ .width = 32, .signed = true, .relation = .lt },
        .i32x4_lt_u => .{ .width = 32, .signed = false, .relation = .lt },
        .i32x4_gt_s => .{ .width = 32, .signed = true, .relation = .gt },
        .i32x4_gt_u => .{ .width = 32, .signed = false, .relation = .gt },
        .i32x4_le_s => .{ .width = 32, .signed = true, .relation = .le },
        .i32x4_le_u => .{ .width = 32, .signed = false, .relation = .le },
        .i32x4_ge_s => .{ .width = 32, .signed = true, .relation = .ge },
        .i32x4_ge_u => .{ .width = 32, .signed = false, .relation = .ge },
        .i64x2_eq => .{ .width = 64, .signed = false, .relation = .eq },
        .i64x2_ne => .{ .width = 64, .signed = false, .relation = .ne },
        .i64x2_lt_s => .{ .width = 64, .signed = true, .relation = .lt },
        .i64x2_gt_s => .{ .width = 64, .signed = true, .relation = .gt },
        .i64x2_le_s => .{ .width = 64, .signed = true, .relation = .le },
        .i64x2_ge_s => .{ .width = 64, .signed = true, .relation = .ge },
        else => null,
    };
}

fn laneRelation(left: u64, right: u64, signed: bool, relation: SimdRelation) bool {
    if (relation == .eq) return left == right;
    if (relation == .ne) return left != right;
    if (signed) {
        const a: i64 = @bitCast(left);
        const b: i64 = @bitCast(right);
        return switch (relation) {
            .lt => a < b,
            .gt => a > b,
            .le => a <= b,
            .ge => a >= b,
            else => unreachable,
        };
    }
    return switch (relation) {
        .lt => left < right,
        .gt => left > right,
        .le => left <= right,
        .ge => left >= right,
        else => unreachable,
    };
}

fn compareSimdLanes(left: u128, right: u128, comparison: SimdComparison) u128 {
    var result: u128 = 0;
    const lanes = 128 / comparison.width;
    for (0..lanes) |lane| {
        var a = laneBits(left, @intCast(lane), comparison.width);
        var b = laneBits(right, @intCast(lane), comparison.width);
        if (comparison.signed) {
            a = signExtendLane(a, comparison.width);
            b = signExtendLane(b, comparison.width);
        }
        if (laneRelation(a, b, comparison.signed, comparison.relation))
            result = replaceLaneBits(result, @intCast(lane), comparison.width, std.math.maxInt(u64));
    }
    return result;
}

fn allSimdLanesTrue(vector: u128, width: u8) bool {
    for (0..128 / width) |lane|
        if (laneBits(vector, @intCast(lane), width) == 0) return false;
    return true;
}

fn simdLaneBitmask(vector: u128, width: u8) u32 {
    var result: u32 = 0;
    for (0..128 / width) |lane|
        result |= @as(u32, @truncate(laneBits(vector, @intCast(lane), width) >> @intCast(width - 1))) << @intCast(lane);
    return result;
}

fn executeSimdIntegerComparison(s: *State, op: simd.Op) ExecError!bool {
    if (simdComparison(op)) |comparison| {
        const right = popVector(s);
        try pushVector(s, compareSimdLanes(popVector(s), right, comparison));
        return true;
    }
    const reduction_width: ?u8 = switch (op) {
        .i8x16_all_true, .i8x16_bitmask => 8,
        .i16x8_all_true, .i16x8_bitmask => 16,
        .i32x4_all_true, .i32x4_bitmask => 32,
        .i64x2_all_true, .i64x2_bitmask => 64,
        else => null,
    };
    const width = reduction_width orelse return false;
    const vector = popVector(s);
    switch (op) {
        .i8x16_all_true, .i16x8_all_true, .i32x4_all_true, .i64x2_all_true => try pushBool(s, allSimdLanesTrue(vector, width)),
        .i8x16_bitmask, .i16x8_bitmask, .i32x4_bitmask, .i64x2_bitmask => try pushI32(s, simdLaneBitmask(vector, width)),
        else => unreachable,
    }
    return true;
}

const SimdUnaryInteger = enum { abs, neg, popcnt };

const SimdUnaryIntegerOp = struct {
    width: u8,
    operation: SimdUnaryInteger,
};

fn simdUnaryInteger(op: simd.Op) ?SimdUnaryIntegerOp {
    return switch (op) {
        .i8x16_abs => .{ .width = 8, .operation = .abs },
        .i8x16_neg => .{ .width = 8, .operation = .neg },
        .i8x16_popcnt => .{ .width = 8, .operation = .popcnt },
        .i16x8_abs => .{ .width = 16, .operation = .abs },
        .i16x8_neg => .{ .width = 16, .operation = .neg },
        .i32x4_abs => .{ .width = 32, .operation = .abs },
        .i32x4_neg => .{ .width = 32, .operation = .neg },
        .i64x2_abs => .{ .width = 64, .operation = .abs },
        .i64x2_neg => .{ .width = 64, .operation = .neg },
        else => null,
    };
}

fn mapSimdUnaryInteger(vector: u128, descriptor: SimdUnaryIntegerOp) u128 {
    var result: u128 = 0;
    for (0..128 / descriptor.width) |lane| {
        const value = laneBits(vector, @intCast(lane), descriptor.width);
        const mapped = switch (descriptor.operation) {
            .abs => if (value >> @intCast(descriptor.width - 1) != 0) 0 -% value else value,
            .neg => 0 -% value,
            .popcnt => @popCount(value),
        };
        result = replaceLaneBits(result, @intCast(lane), descriptor.width, mapped);
    }
    return result;
}

const SimdShift = enum { left, right_signed, right_unsigned };

const SimdShiftOp = struct {
    width: u8,
    operation: SimdShift,
};

fn simdShift(op: simd.Op) ?SimdShiftOp {
    return switch (op) {
        .i8x16_shl => .{ .width = 8, .operation = .left },
        .i8x16_shr_s => .{ .width = 8, .operation = .right_signed },
        .i8x16_shr_u => .{ .width = 8, .operation = .right_unsigned },
        .i16x8_shl => .{ .width = 16, .operation = .left },
        .i16x8_shr_s => .{ .width = 16, .operation = .right_signed },
        .i16x8_shr_u => .{ .width = 16, .operation = .right_unsigned },
        .i32x4_shl => .{ .width = 32, .operation = .left },
        .i32x4_shr_s => .{ .width = 32, .operation = .right_signed },
        .i32x4_shr_u => .{ .width = 32, .operation = .right_unsigned },
        .i64x2_shl => .{ .width = 64, .operation = .left },
        .i64x2_shr_s => .{ .width = 64, .operation = .right_signed },
        .i64x2_shr_u => .{ .width = 64, .operation = .right_unsigned },
        else => null,
    };
}

fn shiftSimdLanes(vector: u128, shift: u32, descriptor: SimdShiftOp) u128 {
    const amount: u6 = @intCast(shift & (descriptor.width - 1));
    var result: u128 = 0;
    for (0..128 / descriptor.width) |lane| {
        const value = laneBits(vector, @intCast(lane), descriptor.width);
        const shifted = switch (descriptor.operation) {
            .left => value << amount,
            .right_unsigned => value >> amount,
            .right_signed => @as(u64, @bitCast(@as(i64, @bitCast(signExtendLane(value, descriptor.width))) >> amount)),
        };
        result = replaceLaneBits(result, @intCast(lane), descriptor.width, shifted);
    }
    return result;
}

const SimdWrappingBinary = enum { add, sub, mul };

const SimdWrappingBinaryOp = struct {
    width: u8,
    operation: SimdWrappingBinary,
};

fn simdWrappingBinary(op: simd.Op) ?SimdWrappingBinaryOp {
    return switch (op) {
        .i8x16_add => .{ .width = 8, .operation = .add },
        .i8x16_sub => .{ .width = 8, .operation = .sub },
        .i16x8_add => .{ .width = 16, .operation = .add },
        .i16x8_sub => .{ .width = 16, .operation = .sub },
        .i16x8_mul => .{ .width = 16, .operation = .mul },
        .i32x4_add => .{ .width = 32, .operation = .add },
        .i32x4_sub => .{ .width = 32, .operation = .sub },
        .i32x4_mul => .{ .width = 32, .operation = .mul },
        .i64x2_add => .{ .width = 64, .operation = .add },
        .i64x2_sub => .{ .width = 64, .operation = .sub },
        .i64x2_mul => .{ .width = 64, .operation = .mul },
        else => null,
    };
}

fn mapSimdWrappingBinary(left: u128, right: u128, descriptor: SimdWrappingBinaryOp) u128 {
    var result: u128 = 0;
    for (0..128 / descriptor.width) |lane| {
        const a = laneBits(left, @intCast(lane), descriptor.width);
        const b = laneBits(right, @intCast(lane), descriptor.width);
        const mapped = switch (descriptor.operation) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
        };
        result = replaceLaneBits(result, @intCast(lane), descriptor.width, mapped);
    }
    return result;
}

fn executeSimdIntegerBasic(s: *State, op: simd.Op) ExecError!bool {
    if (simdUnaryInteger(op)) |descriptor| {
        try pushVector(s, mapSimdUnaryInteger(popVector(s), descriptor));
        return true;
    }
    if (simdShift(op)) |descriptor| {
        const amount = popI32(s);
        try pushVector(s, shiftSimdLanes(popVector(s), amount, descriptor));
        return true;
    }
    if (simdWrappingBinary(op)) |descriptor| {
        const right = popVector(s);
        try pushVector(s, mapSimdWrappingBinary(popVector(s), right, descriptor));
        return true;
    }
    return false;
}

const SimdBoundedBinary = enum {
    add_sat_signed,
    add_sat_unsigned,
    sub_sat_signed,
    sub_sat_unsigned,
    min_signed,
    min_unsigned,
    max_signed,
    max_unsigned,
    average_unsigned,
};

const SimdBoundedBinaryOp = struct {
    width: u8,
    operation: SimdBoundedBinary,
};

fn simdBoundedBinary(op: simd.Op) ?SimdBoundedBinaryOp {
    return switch (op) {
        .i8x16_add_sat_s => .{ .width = 8, .operation = .add_sat_signed },
        .i8x16_add_sat_u => .{ .width = 8, .operation = .add_sat_unsigned },
        .i8x16_sub_sat_s => .{ .width = 8, .operation = .sub_sat_signed },
        .i8x16_sub_sat_u => .{ .width = 8, .operation = .sub_sat_unsigned },
        .i8x16_min_s => .{ .width = 8, .operation = .min_signed },
        .i8x16_min_u => .{ .width = 8, .operation = .min_unsigned },
        .i8x16_max_s => .{ .width = 8, .operation = .max_signed },
        .i8x16_max_u => .{ .width = 8, .operation = .max_unsigned },
        .i8x16_avgr_u => .{ .width = 8, .operation = .average_unsigned },
        .i16x8_add_sat_s => .{ .width = 16, .operation = .add_sat_signed },
        .i16x8_add_sat_u => .{ .width = 16, .operation = .add_sat_unsigned },
        .i16x8_sub_sat_s => .{ .width = 16, .operation = .sub_sat_signed },
        .i16x8_sub_sat_u => .{ .width = 16, .operation = .sub_sat_unsigned },
        .i16x8_min_s => .{ .width = 16, .operation = .min_signed },
        .i16x8_min_u => .{ .width = 16, .operation = .min_unsigned },
        .i16x8_max_s => .{ .width = 16, .operation = .max_signed },
        .i16x8_max_u => .{ .width = 16, .operation = .max_unsigned },
        .i16x8_avgr_u => .{ .width = 16, .operation = .average_unsigned },
        .i32x4_min_s => .{ .width = 32, .operation = .min_signed },
        .i32x4_min_u => .{ .width = 32, .operation = .min_unsigned },
        .i32x4_max_s => .{ .width = 32, .operation = .max_signed },
        .i32x4_max_u => .{ .width = 32, .operation = .max_unsigned },
        else => null,
    };
}

fn signedSimdLane(value: u64, width: u8) i64 {
    return @bitCast(signExtendLane(value, width));
}

fn signedLaneBits(value: i64) u64 {
    return @bitCast(value);
}

fn boundedSimdLane(a: u64, b: u64, descriptor: SimdBoundedBinaryOp) u64 {
    const unsigned_max = (@as(u64, 1) << @intCast(descriptor.width)) - 1;
    const signed_min = -(@as(i64, 1) << @intCast(descriptor.width - 1));
    const signed_max = (@as(i64, 1) << @intCast(descriptor.width - 1)) - 1;
    const signed_a = signedSimdLane(a, descriptor.width);
    const signed_b = signedSimdLane(b, descriptor.width);
    return switch (descriptor.operation) {
        .add_sat_signed => signedLaneBits(std.math.clamp(signed_a + signed_b, signed_min, signed_max)),
        .add_sat_unsigned => @min(a + b, unsigned_max),
        .sub_sat_signed => signedLaneBits(std.math.clamp(signed_a - signed_b, signed_min, signed_max)),
        .sub_sat_unsigned => if (a < b) 0 else a - b,
        .min_signed => signedLaneBits(@min(signed_a, signed_b)),
        .min_unsigned => @min(a, b),
        .max_signed => signedLaneBits(@max(signed_a, signed_b)),
        .max_unsigned => @max(a, b),
        .average_unsigned => (a + b + 1) >> 1,
    };
}

fn mapSimdBoundedBinary(left: u128, right: u128, descriptor: SimdBoundedBinaryOp) u128 {
    var result: u128 = 0;
    for (0..128 / descriptor.width) |lane| {
        const mapped = boundedSimdLane(
            laneBits(left, @intCast(lane), descriptor.width),
            laneBits(right, @intCast(lane), descriptor.width),
            descriptor,
        );
        result = replaceLaneBits(result, @intCast(lane), descriptor.width, mapped);
    }
    return result;
}

fn executeSimdIntegerBounded(s: *State, op: simd.Op) ExecError!bool {
    const descriptor = simdBoundedBinary(op) orelse return false;
    const right = popVector(s);
    try pushVector(s, mapSimdBoundedBinary(popVector(s), right, descriptor));
    return true;
}

fn f32Lane(vector: u128, lane: u8) f32 {
    return @bitCast(@as(u32, @truncate(laneBits(vector, lane, 32))));
}

fn f64Lane(vector: u128, lane: u8) f64 {
    return @bitCast(laneBits(vector, lane, 64));
}

fn replaceF32Lane(vector: u128, lane: u8, value: f32) u128 {
    var bits: u32 = @bitCast(value);
    if (bits & 0x7F800000 == 0x7F800000 and bits & 0x007FFFFF != 0)
        bits |= 0x00400000;
    return replaceLaneBits(vector, lane, 32, bits);
}

fn replaceF64Lane(vector: u128, lane: u8, value: f64) u128 {
    var bits: u64 = @bitCast(value);
    if (bits & 0x7FF0000000000000 == 0x7FF0000000000000 and bits & 0x000FFFFFFFFFFFFF != 0)
        bits |= 0x0008000000000000;
    return replaceLaneBits(vector, lane, 64, bits);
}

fn executeSimdFloatComparison(s: *State, op: simd.Op) ExecError!bool {
    const width: u8 = switch (op) {
        .f32x4_eq, .f32x4_ne, .f32x4_lt, .f32x4_gt, .f32x4_le, .f32x4_ge => 32,
        .f64x2_eq, .f64x2_ne, .f64x2_lt, .f64x2_gt, .f64x2_le, .f64x2_ge => 64,
        else => return false,
    };
    const right = popVector(s);
    const left = popVector(s);
    var result: u128 = 0;
    for (0..128 / width) |lane| {
        const matches = if (width == 32) blk: {
            const a = f32Lane(left, @intCast(lane));
            const b = f32Lane(right, @intCast(lane));
            break :blk switch (op) {
                .f32x4_eq => a == b,
                .f32x4_ne => a != b,
                .f32x4_lt => a < b,
                .f32x4_gt => a > b,
                .f32x4_le => a <= b,
                .f32x4_ge => a >= b,
                else => unreachable,
            };
        } else blk: {
            const a = f64Lane(left, @intCast(lane));
            const b = f64Lane(right, @intCast(lane));
            break :blk switch (op) {
                .f64x2_eq => a == b,
                .f64x2_ne => a != b,
                .f64x2_lt => a < b,
                .f64x2_gt => a > b,
                .f64x2_le => a <= b,
                .f64x2_ge => a >= b,
                else => unreachable,
            };
        };
        if (matches) result = replaceLaneBits(result, @intCast(lane), width, std.math.maxInt(u64));
    }
    try pushVector(s, result);
    return true;
}

fn executeSimdFloatUnary(s: *State, op: simd.Op) ExecError!bool {
    const width: u8 = switch (op) {
        .f32x4_abs, .f32x4_neg, .f32x4_sqrt, .f32x4_ceil, .f32x4_floor, .f32x4_trunc, .f32x4_nearest => 32,
        .f64x2_abs, .f64x2_neg, .f64x2_sqrt, .f64x2_ceil, .f64x2_floor, .f64x2_trunc, .f64x2_nearest => 64,
        else => return false,
    };
    const source = popVector(s);
    var result: u128 = 0;
    for (0..128 / width) |lane| {
        const bits = laneBits(source, @intCast(lane), width);
        if (op == .f32x4_abs or op == .f64x2_abs) {
            result = replaceLaneBits(result, @intCast(lane), width, bits & ~(@as(u64, 1) << @intCast(width - 1)));
            continue;
        }
        if (op == .f32x4_neg or op == .f64x2_neg) {
            result = replaceLaneBits(result, @intCast(lane), width, bits ^ (@as(u64, 1) << @intCast(width - 1)));
            continue;
        }
        if (width == 32) {
            const value = f32Lane(source, @intCast(lane));
            result = replaceF32Lane(result, @intCast(lane), switch (op) {
                .f32x4_sqrt => @sqrt(value),
                .f32x4_ceil => @ceil(value),
                .f32x4_floor => @floor(value),
                .f32x4_trunc => @trunc(value),
                .f32x4_nearest => nearestF32(value),
                else => unreachable,
            });
        } else {
            const value = f64Lane(source, @intCast(lane));
            result = replaceF64Lane(result, @intCast(lane), switch (op) {
                .f64x2_sqrt => @sqrt(value),
                .f64x2_ceil => @ceil(value),
                .f64x2_floor => @floor(value),
                .f64x2_trunc => @trunc(value),
                .f64x2_nearest => nearestF64(value),
                else => unreachable,
            });
        }
    }
    try pushVector(s, result);
    return true;
}

fn executeSimdFloatBinary(s: *State, op: simd.Op) ExecError!bool {
    const width: u8 = switch (op) {
        .f32x4_add, .f32x4_sub, .f32x4_mul, .f32x4_div, .f32x4_min, .f32x4_max, .f32x4_pmin, .f32x4_pmax => 32,
        .f64x2_add, .f64x2_sub, .f64x2_mul, .f64x2_div, .f64x2_min, .f64x2_max, .f64x2_pmin, .f64x2_pmax => 64,
        else => return false,
    };
    const right = popVector(s);
    const left = popVector(s);
    var result: u128 = 0;
    for (0..128 / width) |lane| {
        if (width == 32) {
            const a = f32Lane(left, @intCast(lane));
            const b = f32Lane(right, @intCast(lane));
            if (op == .f32x4_pmin or op == .f32x4_pmax) {
                const choose_right = if (op == .f32x4_pmin) b < a else a < b;
                const chosen = if (choose_right) right else left;
                result = replaceLaneBits(result, @intCast(lane), 32, laneBits(chosen, @intCast(lane), 32));
                continue;
            }
            result = replaceF32Lane(result, @intCast(lane), switch (op) {
                .f32x4_add => a + b,
                .f32x4_sub => a - b,
                .f32x4_mul => a * b,
                .f32x4_div => a / b,
                .f32x4_min => fminF32(a, b),
                .f32x4_max => fmaxF32(a, b),
                else => unreachable,
            });
        } else {
            const a = f64Lane(left, @intCast(lane));
            const b = f64Lane(right, @intCast(lane));
            if (op == .f64x2_pmin or op == .f64x2_pmax) {
                const choose_right = if (op == .f64x2_pmin) b < a else a < b;
                const chosen = if (choose_right) right else left;
                result = replaceLaneBits(result, @intCast(lane), 64, laneBits(chosen, @intCast(lane), 64));
                continue;
            }
            result = replaceF64Lane(result, @intCast(lane), switch (op) {
                .f64x2_add => a + b,
                .f64x2_sub => a - b,
                .f64x2_mul => a * b,
                .f64x2_div => a / b,
                .f64x2_min => fminF64(a, b),
                .f64x2_max => fmaxF64(a, b),
                else => unreachable,
            });
        }
    }
    try pushVector(s, result);
    return true;
}

fn executeSimdFloatConversion(s: *State, op: simd.Op) ExecError!bool {
    switch (op) {
        .i32x4_trunc_sat_f32x4_s, .i32x4_trunc_sat_f32x4_u => {
            const source = popVector(s);
            var result: u128 = 0;
            for (0..4) |lane| {
                const value = f32Lane(source, @intCast(lane));
                const converted: u32 = if (op == .i32x4_trunc_sat_f32x4_s)
                    @bitCast(truncSatI32S(value))
                else
                    truncSatI32U(value);
                result = replaceLaneBits(result, @intCast(lane), 32, converted);
            }
            try pushVector(s, result);
        },
        .f32x4_convert_i32x4_s, .f32x4_convert_i32x4_u => {
            const source = popVector(s);
            var result: u128 = 0;
            for (0..4) |lane| {
                const bits: u32 = @truncate(laneBits(source, @intCast(lane), 32));
                const converted: f32 = if (op == .f32x4_convert_i32x4_s)
                    @floatFromInt(@as(i32, @bitCast(bits)))
                else
                    @floatFromInt(bits);
                result = replaceF32Lane(result, @intCast(lane), converted);
            }
            try pushVector(s, result);
        },
        .f32x4_demote_f64x2_zero => {
            const source = popVector(s);
            var result: u128 = 0;
            for (0..2) |lane|
                result = replaceF32Lane(result, @intCast(lane), @floatCast(f64Lane(source, @intCast(lane))));
            try pushVector(s, result);
        },
        .f64x2_promote_low_f32x4 => {
            const source = popVector(s);
            var result: u128 = 0;
            for (0..2) |lane|
                result = replaceF64Lane(result, @intCast(lane), f32Lane(source, @intCast(lane)));
            try pushVector(s, result);
        },
        .i32x4_trunc_sat_f64x2_s_zero, .i32x4_trunc_sat_f64x2_u_zero => {
            const source = popVector(s);
            var result: u128 = 0;
            for (0..2) |lane| {
                const value = f64Lane(source, @intCast(lane));
                const converted: u32 = if (op == .i32x4_trunc_sat_f64x2_s_zero)
                    @bitCast(truncSatI32S(value))
                else
                    truncSatI32U(value);
                result = replaceLaneBits(result, @intCast(lane), 32, converted);
            }
            try pushVector(s, result);
        },
        .f64x2_convert_low_i32x4_s, .f64x2_convert_low_i32x4_u => {
            const source = popVector(s);
            var result: u128 = 0;
            for (0..2) |lane| {
                const bits: u32 = @truncate(laneBits(source, @intCast(lane), 32));
                const converted: f64 = if (op == .f64x2_convert_low_i32x4_s)
                    @floatFromInt(@as(i32, @bitCast(bits)))
                else
                    @floatFromInt(bits);
                result = replaceF64Lane(result, @intCast(lane), converted);
            }
            try pushVector(s, result);
        },
        else => return false,
    }
    return true;
}

const SimdIntegerTransform = struct {
    source_width: u8,
    target_width: u8,
    signed: bool,
    high: bool = false,
};

fn simdExtend(op: simd.Op) ?SimdIntegerTransform {
    return switch (op) {
        .i16x8_extend_low_i8x16_s => .{ .source_width = 8, .target_width = 16, .signed = true },
        .i16x8_extend_high_i8x16_s => .{ .source_width = 8, .target_width = 16, .signed = true, .high = true },
        .i16x8_extend_low_i8x16_u => .{ .source_width = 8, .target_width = 16, .signed = false },
        .i16x8_extend_high_i8x16_u => .{ .source_width = 8, .target_width = 16, .signed = false, .high = true },
        .i32x4_extend_low_i16x8_s => .{ .source_width = 16, .target_width = 32, .signed = true },
        .i32x4_extend_high_i16x8_s => .{ .source_width = 16, .target_width = 32, .signed = true, .high = true },
        .i32x4_extend_low_i16x8_u => .{ .source_width = 16, .target_width = 32, .signed = false },
        .i32x4_extend_high_i16x8_u => .{ .source_width = 16, .target_width = 32, .signed = false, .high = true },
        .i64x2_extend_low_i32x4_s => .{ .source_width = 32, .target_width = 64, .signed = true },
        .i64x2_extend_high_i32x4_s => .{ .source_width = 32, .target_width = 64, .signed = true, .high = true },
        .i64x2_extend_low_i32x4_u => .{ .source_width = 32, .target_width = 64, .signed = false },
        .i64x2_extend_high_i32x4_u => .{ .source_width = 32, .target_width = 64, .signed = false, .high = true },
        else => null,
    };
}

fn extendSimdHalf(vector: u128, descriptor: SimdIntegerTransform) u128 {
    const lanes = 128 / descriptor.target_width;
    const first = if (descriptor.high) lanes else 0;
    var result: u128 = 0;
    for (0..lanes) |lane| {
        var value = laneBits(vector, @intCast(first + lane), descriptor.source_width);
        if (descriptor.signed) value = signExtendLane(value, descriptor.source_width);
        result = replaceLaneBits(result, @intCast(lane), descriptor.target_width, value);
    }
    return result;
}

fn simdExtMul(op: simd.Op) ?SimdIntegerTransform {
    return switch (op) {
        .i16x8_extmul_low_i8x16_s => .{ .source_width = 8, .target_width = 16, .signed = true },
        .i16x8_extmul_high_i8x16_s => .{ .source_width = 8, .target_width = 16, .signed = true, .high = true },
        .i16x8_extmul_low_i8x16_u => .{ .source_width = 8, .target_width = 16, .signed = false },
        .i16x8_extmul_high_i8x16_u => .{ .source_width = 8, .target_width = 16, .signed = false, .high = true },
        .i32x4_extmul_low_i16x8_s => .{ .source_width = 16, .target_width = 32, .signed = true },
        .i32x4_extmul_high_i16x8_s => .{ .source_width = 16, .target_width = 32, .signed = true, .high = true },
        .i32x4_extmul_low_i16x8_u => .{ .source_width = 16, .target_width = 32, .signed = false },
        .i32x4_extmul_high_i16x8_u => .{ .source_width = 16, .target_width = 32, .signed = false, .high = true },
        .i64x2_extmul_low_i32x4_s => .{ .source_width = 32, .target_width = 64, .signed = true },
        .i64x2_extmul_high_i32x4_s => .{ .source_width = 32, .target_width = 64, .signed = true, .high = true },
        .i64x2_extmul_low_i32x4_u => .{ .source_width = 32, .target_width = 64, .signed = false },
        .i64x2_extmul_high_i32x4_u => .{ .source_width = 32, .target_width = 64, .signed = false, .high = true },
        else => null,
    };
}

fn extMulSimdHalf(left: u128, right: u128, descriptor: SimdIntegerTransform) u128 {
    const lanes = 128 / descriptor.target_width;
    const first = if (descriptor.high) lanes else 0;
    var result: u128 = 0;
    for (0..lanes) |lane| {
        const a = laneBits(left, @intCast(first + lane), descriptor.source_width);
        const b = laneBits(right, @intCast(first + lane), descriptor.source_width);
        const product: u64 = if (descriptor.signed)
            @bitCast(signedSimdLane(a, descriptor.source_width) * signedSimdLane(b, descriptor.source_width))
        else
            a * b;
        result = replaceLaneBits(result, @intCast(lane), descriptor.target_width, product);
    }
    return result;
}

fn simdNarrow(op: simd.Op) ?SimdIntegerTransform {
    return switch (op) {
        .i8x16_narrow_i16x8_s => .{ .source_width = 16, .target_width = 8, .signed = true },
        .i8x16_narrow_i16x8_u => .{ .source_width = 16, .target_width = 8, .signed = false },
        .i16x8_narrow_i32x4_s => .{ .source_width = 32, .target_width = 16, .signed = true },
        .i16x8_narrow_i32x4_u => .{ .source_width = 32, .target_width = 16, .signed = false },
        else => null,
    };
}

fn narrowSimdLanes(left: u128, right: u128, descriptor: SimdIntegerTransform) u128 {
    const source_lanes = 128 / descriptor.source_width;
    const signed_min = -(@as(i64, 1) << @intCast(descriptor.target_width - 1));
    const signed_max = (@as(i64, 1) << @intCast(descriptor.target_width - 1)) - 1;
    const unsigned_max = (@as(i64, 1) << @intCast(descriptor.target_width)) - 1;
    var result: u128 = 0;
    for (0..source_lanes * 2) |lane| {
        const source = if (lane < source_lanes) left else right;
        const source_lane = lane % source_lanes;
        const value = signedSimdLane(laneBits(source, @intCast(source_lane), descriptor.source_width), descriptor.source_width);
        const narrowed = if (descriptor.signed)
            std.math.clamp(value, signed_min, signed_max)
        else
            std.math.clamp(value, 0, unsigned_max);
        result = replaceLaneBits(result, @intCast(lane), descriptor.target_width, signedLaneBits(narrowed));
    }
    return result;
}

fn extAddPairwise(vector: u128, source_width: u8, signed: bool) u128 {
    const target_width = source_width * 2;
    var result: u128 = 0;
    for (0..128 / target_width) |lane| {
        var a = laneBits(vector, @intCast(lane * 2), source_width);
        var b = laneBits(vector, @intCast(lane * 2 + 1), source_width);
        if (signed) {
            a = signExtendLane(a, source_width);
            b = signExtendLane(b, source_width);
        }
        result = replaceLaneBits(result, @intCast(lane), target_width, a +% b);
    }
    return result;
}

fn dotI16x8(left: u128, right: u128) u128 {
    var result: u128 = 0;
    for (0..4) |lane| {
        const a0 = signedSimdLane(laneBits(left, @intCast(lane * 2), 16), 16);
        const a1 = signedSimdLane(laneBits(left, @intCast(lane * 2 + 1), 16), 16);
        const b0 = signedSimdLane(laneBits(right, @intCast(lane * 2), 16), 16);
        const b1 = signedSimdLane(laneBits(right, @intCast(lane * 2 + 1), 16), 16);
        result = replaceLaneBits(result, @intCast(lane), 32, signedLaneBits(a0 * b0 + a1 * b1));
    }
    return result;
}

fn q15MulRoundSaturate(left: u128, right: u128) u128 {
    var result: u128 = 0;
    for (0..8) |lane| {
        const a = signedSimdLane(laneBits(left, @intCast(lane), 16), 16);
        const b = signedSimdLane(laneBits(right, @intCast(lane), 16), 16);
        const value = std.math.clamp((a * b + 0x4000) >> 15, -32768, 32767);
        result = replaceLaneBits(result, @intCast(lane), 16, signedLaneBits(value));
    }
    return result;
}

fn executeSimdIntegerTransform(s: *State, op: simd.Op) ExecError!bool {
    if (simdExtend(op)) |descriptor| {
        try pushVector(s, extendSimdHalf(popVector(s), descriptor));
        return true;
    }
    if (simdExtMul(op)) |descriptor| {
        const right = popVector(s);
        try pushVector(s, extMulSimdHalf(popVector(s), right, descriptor));
        return true;
    }
    if (simdNarrow(op)) |descriptor| {
        const right = popVector(s);
        try pushVector(s, narrowSimdLanes(popVector(s), right, descriptor));
        return true;
    }
    switch (op) {
        .i16x8_extadd_pairwise_i8x16_s, .i16x8_extadd_pairwise_i8x16_u => try pushVector(s, extAddPairwise(popVector(s), 8, op == .i16x8_extadd_pairwise_i8x16_s)),
        .i32x4_extadd_pairwise_i16x8_s, .i32x4_extadd_pairwise_i16x8_u => try pushVector(s, extAddPairwise(popVector(s), 16, op == .i32x4_extadd_pairwise_i16x8_s)),
        .i32x4_dot_i16x8_s => {
            const right = popVector(s);
            try pushVector(s, dotI16x8(popVector(s), right));
        },
        .i16x8_q15mulr_sat_s => {
            const right = popVector(s);
            try pushVector(s, q15MulRoundSaturate(popVector(s), right));
        },
        else => return false,
    }
    return true;
}

fn executeSimdMemory(s: *State, inst: *Instance, instr: types.Instr) ExecError!bool {
    const op = simdOp(instr);
    switch (op) {
        .v128_load => {
            const range = try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, 16);
            try pushVector(s, @as(u128, range.readLittle(0, 8)) |
                (@as(u128, range.readLittle(8, 8)) << 64));
        },
        .v128_load8x8_s, .v128_load8x8_u => try pushVector(s, loadExtendedMemory(
            try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, 8),
            8,
            16,
            op == .v128_load8x8_s,
        )),
        .v128_load16x4_s, .v128_load16x4_u => try pushVector(s, loadExtendedMemory(
            try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, 8),
            16,
            32,
            op == .v128_load16x4_s,
        )),
        .v128_load32x2_s, .v128_load32x2_u => try pushVector(s, loadExtendedMemory(
            try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, 8),
            32,
            64,
            op == .v128_load32x2_s,
        )),
        .v128_load8_splat, .v128_load16_splat, .v128_load32_splat, .v128_load64_splat => {
            const width: u8 = switch (op) {
                .v128_load8_splat => 8,
                .v128_load16_splat => 16,
                .v128_load32_splat => 32,
                .v128_load64_splat => 64,
                else => unreachable,
            };
            const range = try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, width / 8);
            const value = range.readLittle(0, width / 8);
            try pushVector(s, splatLaneBits(value, width, @intCast(128 / width)));
        },
        .v128_load32_zero, .v128_load64_zero => {
            const size: usize = if (op == .v128_load32_zero) 4 else 8;
            const range = try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, size);
            try pushVector(s, range.readLittle(0, size));
        },
        .v128_store => {
            const vector = popVector(s);
            const range = try simdMemoryRange(s, inst, instr.imm.simd_memarg.memarg, 16);
            range.writeLittle(0, 8, @truncate(vector));
            range.writeLittle(8, 8, @truncate(vector >> 64));
        },
        .v128_load8_lane, .v128_load16_lane, .v128_load32_lane, .v128_load64_lane => {
            const vector = popVector(s);
            const width: u8 = switch (op) {
                .v128_load8_lane => 8,
                .v128_load16_lane => 16,
                .v128_load32_lane => 32,
                .v128_load64_lane => 64,
                else => unreachable,
            };
            const immediate = instr.imm.simd_memarg_lane;
            const range = try simdMemoryRange(s, inst, immediate.memarg, width / 8);
            const value = range.readLittle(0, width / 8);
            try pushVector(s, replaceLaneBits(vector, immediate.lane, width, value));
        },
        .v128_store8_lane, .v128_store16_lane, .v128_store32_lane, .v128_store64_lane => {
            const vector = popVector(s);
            const width: u8 = switch (op) {
                .v128_store8_lane => 8,
                .v128_store16_lane => 16,
                .v128_store32_lane => 32,
                .v128_store64_lane => 64,
                else => unreachable,
            };
            const immediate = instr.imm.simd_memarg_lane;
            const range = try simdMemoryRange(s, inst, immediate.memarg, width / 8);
            range.writeLittle(0, width / 8, laneBits(vector, immediate.lane, width));
        },
        else => return false,
    }
    return true;
}

fn executeSimd(s: *State, inst: *Instance, instr: types.Instr) ExecError!void {
    if (try executeSimdMemory(s, inst, instr)) return;
    const op = simdOp(instr);
    if (try executeSimdIntegerComparison(s, op)) return;
    if (try executeSimdIntegerBasic(s, op)) return;
    if (try executeSimdIntegerBounded(s, op)) return;
    if (try executeSimdIntegerTransform(s, op)) return;
    if (try executeSimdFloatComparison(s, op)) return;
    if (try executeSimdFloatUnary(s, op)) return;
    if (try executeSimdFloatBinary(s, op)) return;
    if (try executeSimdFloatConversion(s, op)) return;
    switch (op) {
        .v128_const => try pushVector(s, instr.imm.simd_v128.bits),
        .i8x16_splat => try pushVector(s, splatLaneBits(popI32(s), 8, 16)),
        .i16x8_splat => try pushVector(s, splatLaneBits(popI32(s), 16, 8)),
        .i32x4_splat, .f32x4_splat => try pushVector(s, splatLaneBits(popI32(s), 32, 4)),
        .i64x2_splat, .f64x2_splat => try pushVector(s, splatLaneBits(pop(s), 64, 2)),
        .i8x16_extract_lane_s => try pushI32(s, @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(laneBits(popVector(s), instr.imm.simd_lane.lane, 8)))))))),
        .i8x16_extract_lane_u => try pushI32(s, @truncate(laneBits(popVector(s), instr.imm.simd_lane.lane, 8))),
        .i16x8_extract_lane_s => try pushI32(s, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(laneBits(popVector(s), instr.imm.simd_lane.lane, 16)))))))),
        .i16x8_extract_lane_u => try pushI32(s, @truncate(laneBits(popVector(s), instr.imm.simd_lane.lane, 16))),
        .i32x4_extract_lane, .f32x4_extract_lane => try pushI32(s, @truncate(laneBits(popVector(s), instr.imm.simd_lane.lane, 32))),
        .i64x2_extract_lane, .f64x2_extract_lane => try pushI64(s, laneBits(popVector(s), instr.imm.simd_lane.lane, 64)),
        .i8x16_replace_lane => {
            const value = popI32(s);
            try pushVector(s, replaceLaneBits(popVector(s), instr.imm.simd_lane.lane, 8, value));
        },
        .i16x8_replace_lane => {
            const value = popI32(s);
            try pushVector(s, replaceLaneBits(popVector(s), instr.imm.simd_lane.lane, 16, value));
        },
        .i32x4_replace_lane, .f32x4_replace_lane => {
            const value = popI32(s);
            try pushVector(s, replaceLaneBits(popVector(s), instr.imm.simd_lane.lane, 32, value));
        },
        .i64x2_replace_lane, .f64x2_replace_lane => {
            const value = pop(s);
            try pushVector(s, replaceLaneBits(popVector(s), instr.imm.simd_lane.lane, 64, value));
        },
        .i8x16_shuffle => {
            const right = popVector(s);
            const left = popVector(s);
            var result: u128 = 0;
            for (instr.imm.simd_shuffle.lanes, 0..) |source, lane| {
                const vector = if (source < 16) left else right;
                result = replaceLaneBits(result, @intCast(lane), 8, laneBits(vector, source & 15, 8));
            }
            try pushVector(s, result);
        },
        .i8x16_swizzle => {
            const indices = popVector(s);
            const source = popVector(s);
            var result: u128 = 0;
            for (0..16) |lane| {
                const index: u8 = @truncate(laneBits(indices, @intCast(lane), 8));
                const byte = if (index < 16) laneBits(source, index, 8) else 0;
                result = replaceLaneBits(result, @intCast(lane), 8, byte);
            }
            try pushVector(s, result);
        },
        .v128_not => try pushVector(s, ~popVector(s)),
        .v128_and => {
            const right = popVector(s);
            try pushVector(s, popVector(s) & right);
        },
        .v128_andnot => {
            const right = popVector(s);
            try pushVector(s, popVector(s) & ~right);
        },
        .v128_or => {
            const right = popVector(s);
            try pushVector(s, popVector(s) | right);
        },
        .v128_xor => {
            const right = popVector(s);
            try pushVector(s, popVector(s) ^ right);
        },
        .v128_bitselect => {
            const mask = popVector(s);
            const right = popVector(s);
            const left = popVector(s);
            try pushVector(s, (left & mask) | (right & ~mask));
        },
        .v128_any_true => try pushBool(s, popVector(s) != 0),
        else => return s.trap("SIMD instruction execution not implemented"),
    }
}

fn popI32(s: *State) u32 {
    return @truncate(pop(s));
}

fn popAddress(s: *State, address: types.AddressType) u64 {
    return switch (address) {
        .i32 => popI32(s),
        .i64 => pop(s),
    };
}

fn pushAddress(s: *State, address: types.AddressType, value: u64) ExecError!void {
    switch (address) {
        .i32 => try pushI32(s, @truncate(value)),
        .i64 => try pushI64(s, value),
    }
}

fn pushAddressGrowResult(s: *State, address: types.AddressType, value: ?u64) ExecError!void {
    try pushAddress(s, address, value orelse switch (address) {
        .i32 => std.math.maxInt(u32),
        .i64 => std.math.maxInt(u64),
    });
}

const CheckedRange = struct { start: usize, end: usize };

fn checkedRange(start: u64, len: u64, bound: usize) ?CheckedRange {
    const end = std.math.add(u64, start, len) catch return null;
    if (end > bound or start > std.math.maxInt(usize)) return null;
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

fn popF32(s: *State) f32 {
    return @bitCast(@as(u32, @truncate(pop(s))));
}

fn popF64(s: *State) f64 {
    return @bitCast(pop(s));
}

fn zeroSlot(val_type: types.ValType) WasmSlot {
    if (val_type.refType()) |reference| return switch (reference.heap) {
        .func, .nofunc => .{ .funcref = null },
        .extern_, .noextern => .{ .externref = js_value.Value.nul() },
        else => .{ .gcref = null },
    };
    return switch (val_type) {
        .i32, .i64, .f32, .f64 => .{ .numeric = 0 },
        .v128 => .{ .vector = 0 },
        .exnref => .{ .exnref = null },
        else => unreachable,
    };
}

fn pushFrame(s: *State, f: *const FuncInst) ExecError!void {
    if (s.frames.items.len >= MAX_FRAMES) return s.trap("call stack exhausted");
    const def = f.defined;
    var seen_instance = false;
    for (s.touched_instances.items) |instance| {
        if (instance == def.inst) {
            seen_instance = true;
            break;
        }
    }
    if (!seen_instance) {
        try s.touched_instances.append(s.alloc, def.inst);
        registerGcRoots(s, def.inst) catch |err| {
            s.touched_instances.items.len -= 1;
            return err;
        };
    }
    const mod = def.inst.module;
    const body = &mod.code[def.idx];
    const fty = mod.funcTypeAt(mod.funcs[def.idx]).?;
    // Params move from the operand stack into fresh locals; declared locals
    // follow, zero-initialized.
    const arg_start = s.stack.items.len - fty.params.len;
    const locals_base = s.locals.items.len;
    try s.locals.appendSlice(s.alloc, s.stack.items[arg_start..]);
    s.stack.items.len = arg_start;
    for (body.locals) |local_type| try s.locals.append(s.alloc, zeroSlot(local_type));
    try s.frames.append(s.alloc, .{
        .func = f,
        .pc = 0,
        .locals_base = locals_base,
        .locals_end = s.locals.items.len,
        .stack_base = s.stack.items.len,
        .label_base = s.labels.items.len,
        .result_arity = fty.results.len,
    });
    // Implicit function-level label: branching to it returns.
    try s.labels.append(s.alloc, .{
        .target_pc = @intCast(body.instrs.len),
        .stack_height = s.stack.items.len,
        .arity = fty.results.len,
        .is_loop = false,
    });
}

/// Pop the current frame, moving its result values onto the caller's
/// operand stack.
fn returnFrame(s: *State) void {
    const fr = s.frames.items[s.frames.items.len - 1];
    const top = s.stack.items.len;
    std.mem.copyForwards(WasmSlot, s.stack.items[fr.stack_base..][0..fr.result_arity], s.stack.items[top - fr.result_arity ..]);
    s.stack.items.len = fr.stack_base + fr.result_arity;
    s.labels.items.len = fr.label_base;
    s.locals.items.len = fr.locals_base;
    s.frames.items.len -= 1;
    pruneHandlers(s);
}

fn pruneHandlers(s: *State) void {
    while (s.handlers.items.len != 0) {
        const handler = s.handlers.items[s.handlers.items.len - 1];
        if (handler.frame_index < s.frames.items.len and handler.label_index < s.labels.items.len) break;
        s.handlers.items.len -= 1;
    }
}

/// Branch to the label `depth` levels out, carrying its arity of values.
/// A branch to the function-level label returns from the current frame.
fn branchTo(s: *State, depth: u32) void {
    const fr = &s.frames.items[s.frames.items.len - 1];
    const li = s.labels.items.len - 1 - depth;
    const lab = s.labels.items[li];
    const top = s.stack.items.len;
    std.mem.copyForwards(WasmSlot, s.stack.items[lab.stack_height..][0..lab.arity], s.stack.items[top - lab.arity ..]);
    s.stack.items.len = lab.stack_height + lab.arity;
    if (li == fr.label_base) {
        s.labels.items.len = fr.label_base;
        s.locals.items.len = fr.locals_base;
        s.frames.items.len -= 1;
    } else if (lab.is_loop) {
        s.labels.items.len = li + 1;
        fr.pc = lab.target_pc;
        checkpoint(s);
    } else {
        s.labels.items.len = li;
        fr.pc = lab.target_pc;
    }
    pruneHandlers(s);
}

fn publishStoredException(exception: *js_value.WasmException) void {
    if (exception.published) return;
    const owner: *Instance = @ptrCast(@alignCast(exception.owner));
    var head = owner.exception_head.load(.acquire);
    while (true) {
        exception.next = if (head == 0) null else @ptrFromInt(head);
        if (owner.exception_head.cmpxchgWeak(head, @intFromPtr(exception), .release, .acquire)) |observed| {
            head = observed;
        } else break;
    }
    exception.published = true;
}

fn publishExceptionReference(s: *State, active: *ActiveException) ExecError!*js_value.WasmException {
    if (active.reference) |reference| return reference;
    const owner = active.owner;
    const payload = try owner.gpa.dupe(WasmSlot, active.payload);
    errdefer owner.gpa.free(payload);
    var externref_set: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer externref_set.deinit(s.alloc);
    for (payload) |slot| switch (slot) {
        .externref => |root| try externref_set.put(s.alloc, root.bits, {}),
        .exnref => |nested| if (nested) |exception| {
            for (exception.externrefs) |root| try externref_set.put(s.alloc, root.bits, {});
        },
        .numeric, .vector, .funcref, .i31ref, .gcref => {},
    };
    const externrefs = try owner.gpa.alloc(js_value.Value, externref_set.count());
    errdefer owner.gpa.free(externrefs);
    var externref_index: usize = 0;
    var externref_iterator = externref_set.keyIterator();
    while (externref_iterator.next()) |bits| : (externref_index += 1)
        externrefs[externref_index] = .{ .bits = bits.* };
    const exception = owner.gpa.create(js_value.WasmException) catch |err| {
        return err;
    };
    exception.* = .{
        .tag = @ptrCast(active.tag),
        .payload = payload,
        .externrefs = externrefs,
        .owner = @ptrCast(owner),
        .js_exception = active.js_exception,
        .is_js_exception = active.is_js_exception,
    };
    s.created_exceptions.append(s.alloc, exception) catch |err| {
        owner.gpa.destroy(exception);
        return err;
    };
    active.reference = exception;
    return exception;
}

fn markCreatedException(s: *State, live: []bool, exception: *js_value.WasmException) void {
    var found: ?usize = null;
    for (s.created_exceptions.items, 0..) |candidate, index| {
        if (candidate == exception) {
            found = index;
            break;
        }
    }
    const index = found orelse return;
    if (live[index]) return;
    live[index] = true;
    for (exception.payload) |slot|
        if (slot == .exnref)
            if (slot.exnref) |nested| markCreatedException(s, live, nested);
}

fn markExceptionSlots(s: *State, live: []bool, slots: []const WasmSlot) void {
    for (slots) |slot|
        if (slot == .exnref)
            if (slot.exnref) |exception| markCreatedException(s, live, exception);
}

fn finalizeExceptions(s: *State, include_stack: bool) void {
    if (s.created_exceptions.items.len == 0) return;
    const live = s.alloc.alloc(bool, s.created_exceptions.items.len) catch {
        for (s.created_exceptions.items) |exception| publishStoredException(exception);
        return;
    };
    @memset(live, false);
    if (include_stack) markExceptionSlots(s, live, s.stack.items);
    for (s.touched_instances.items) |instance| {
        for (instance.globals) |global| markExceptionSlots(s, live, &.{global.value});
        for (instance.tables) |table| {
            table.lockTable();
            markExceptionSlots(s, live, table.elems);
            table.unlockTable();
        }
    }
    for (s.created_exceptions.items, live) |exception, is_live| {
        if (is_live or exception.published) {
            publishStoredException(exception);
        } else {
            const owner: *Instance = @ptrCast(@alignCast(exception.owner));
            destroyExceptionRecord(owner.gpa, exception);
        }
    }
    s.created_exceptions.items.len = 0;
}

fn unwindToHandler(s: *State, handler: ExceptionHandler) void {
    const frame = &s.frames.items[handler.frame_index];
    s.frames.items.len = handler.frame_index + 1;
    s.locals.items.len = frame.locals_end;
    s.labels.items.len = handler.label_index;
    s.stack.items.len = handler.stack_height;
}

fn handleException(s: *State, active: *ActiveException) ExecError!void {
    while (s.handlers.items.len != 0) {
        const handler = s.handlers.items[s.handlers.items.len - 1];
        s.handlers.items.len -= 1;
        unwindToHandler(s, handler);

        for (handler.catches) |catch_clause| {
            const matched = switch (catch_clause) {
                .catch_tag => |tagged| handler.inst.tags[tagged.tag_index] == active.tag,
                .catch_ref => |tagged| handler.inst.tags[tagged.tag_index] == active.tag,
                .catch_all, .catch_all_ref => true,
            };
            if (!matched) continue;

            switch (catch_clause) {
                .catch_tag => |tagged| {
                    for (active.payload) |slot| try pushSlot(s, slot);
                    branchTo(s, tagged.label_index);
                },
                .catch_ref => |tagged| {
                    for (active.payload) |slot| try pushSlot(s, slot);
                    try pushSlot(s, .{ .exnref = try publishExceptionReference(s, active) });
                    branchTo(s, tagged.label_index);
                },
                .catch_all => |label_index| branchTo(s, label_index),
                .catch_all_ref => |label_index| {
                    try pushSlot(s, .{ .exnref = try publishExceptionReference(s, active) });
                    branchTo(s, label_index);
                },
            }
            checkpoint(s);
            return;
        }
    }

    s.stack.items.len = 0;
    s.locals.items.len = 0;
    s.labels.items.len = 0;
    s.frames.items.len = 0;
    s.diag.set(types.Diagnostic.no_offset, "uncaught WebAssembly exception", .{});
    const exception = try publishExceptionReference(s, active);
    publishStoredException(exception);
    if (active.owner.root_hooks) |hooks|
        if (hooks.uncaught_exception) |uncaught|
            try uncaught(hooks.uncaught_ctx orelse hooks.ctx, exception);
    return error.Exception;
}

fn throwTag(s: *State, inst: *Instance, tag_index: u32) ExecError!void {
    const tag = inst.tags[tag_index];
    const payload_len = tag.type.params.len;
    const payload_start = s.stack.items.len - payload_len;
    const payload = try s.alloc.dupe(WasmSlot, s.stack.items[payload_start..]);
    s.stack.items.len = payload_start;
    var active: ActiveException = .{ .tag = tag, .payload = payload, .owner = inst };
    try handleException(s, &active);
}

fn throwReference(s: *State, inst: *Instance) ExecError!void {
    const reference = popSlot(s).exnref orelse return s.trap("null exception reference");
    var active: ActiveException = .{
        .tag = @ptrCast(@alignCast(reference.tag)),
        .payload = reference.payload,
        .reference = reference,
        .owner = inst,
    };
    try handleException(s, &active);
}

fn publishEscapingSlots(slots: []const WasmSlot) void {
    for (slots) |slot|
        if (slot == .exnref)
            if (slot.exnref) |exception| publishStoredException(exception);
}

fn handleHostException(s: *State, imp: *const ImportFunc, owner: *Instance) ExecError!void {
    const take = imp.take_exception orelse return error.Host;
    const thrown = take(imp.ctx) orelse return error.Host;
    var js_payload: [1]WasmSlot = undefined;
    var active: ActiveException = switch (thrown) {
        .wasm => |exception| .{
            .tag = @ptrCast(@alignCast(exception.tag)),
            .payload = exception.payload,
            .reference = exception,
            .owner = owner,
            .js_exception = exception.js_exception,
            .is_js_exception = exception.is_js_exception,
        },
        .js => |js| blk: {
            js_payload[0] = .{ .externref = js.value };
            break :blk .{
                .tag = js.tag,
                .payload = &js_payload,
                .owner = owner,
                .js_exception = js.value,
                .is_js_exception = true,
            };
        },
    };
    handleException(s, &active) catch |err| return err;
    if (imp.clear_exception) |clear| clear(imp.ctx);
}

fn callFunc(s: *State, f: *const FuncInst) ExecError!void {
    checkpoint(s);
    switch (f.*) {
        .defined => try pushFrame(s, f),
        .imported => |*imp| {
            const arg_start = s.stack.items.len - imp.type.params.len;
            const args = s.stack.items[arg_start..];
            publishEscapingSlots(args);
            const res = try s.alloc.alloc(ValueSlot, imp.type.results.len);
            if (!argumentsMatchSignature(imp.type, args, res.len))
                return s.trap("function signature mismatch");
            if (imp.call_slots) |call_slots|
                call_slots(imp.ctx, args, res, s.diag) catch |err| switch (err) {
                    error.Host => return handleHostException(s, imp, s.frames.items[s.frames.items.len - 1].func.defined.inst),
                    else => return err,
                }
            else
                callNumericImport(s.alloc, imp, args, res, s.diag) catch |err| switch (err) {
                    error.Host => return handleHostException(s, imp, s.frames.items[s.frames.items.len - 1].func.defined.inst),
                    else => return err,
                };
            for (res, imp.type.results) |slot, val_type|
                if (!slotMatchesType(slot, val_type)) return s.trap("function signature mismatch");
            s.stack.items.len = arg_start;
            for (res) |slot| try pushSlot(s, slot);
        },
    }
}

/// Replace the active defined frame while preserving the caller-facing bases.
/// Arguments are already on the operand stack in validation order. Array-list
/// capacities grow only to the largest tail target encountered, then remain
/// stable across arbitrarily deep tail recursion.
fn replaceFrame(s: *State, f: *const FuncInst) ExecError!void {
    const current_index = s.frames.items.len - 1;
    const current = s.frames.items[current_index];
    const def = f.defined;
    const mod = def.inst.module;
    const body = &mod.code[def.idx];
    const fty = mod.funcTypeAt(mod.funcs[def.idx]).?;
    const arg_start = s.stack.items.len - fty.params.len;
    const args = s.stack.items[arg_start..];

    s.locals.items.len = current.locals_base;
    try s.locals.appendSlice(s.alloc, args);
    for (body.locals) |local_type| try s.locals.append(s.alloc, zeroSlot(local_type));
    s.stack.items.len = current.stack_base;
    s.labels.items.len = current.label_base;
    pruneHandlers(s);
    s.frames.items[current_index] = .{
        .func = f,
        .pc = 0,
        .locals_base = current.locals_base,
        .locals_end = s.locals.items.len,
        .stack_base = current.stack_base,
        .label_base = current.label_base,
        .result_arity = fty.results.len,
    };
    try s.labels.append(s.alloc, .{
        .target_pc = @intCast(body.instrs.len),
        .stack_height = current.stack_base,
        .arity = fty.results.len,
        .is_loop = false,
    });
    checkpoint(s);
}

fn tailCallFunc(s: *State, f: *const FuncInst) ExecError!void {
    switch (f.*) {
        .defined => try replaceFrame(s, f),
        .imported => |*imp| {
            // Publish current locals and the argument stack before a host call,
            // which may re-enter the runtime or request collection.
            checkpoint(s);
            const current = s.frames.items[s.frames.items.len - 1];
            const arg_start = s.stack.items.len - imp.type.params.len;
            const args = s.stack.items[arg_start..];
            publishEscapingSlots(args);
            const res = try s.alloc.alloc(ValueSlot, imp.type.results.len);
            if (!argumentsMatchSignature(imp.type, args, res.len))
                return s.trap("function signature mismatch");
            const caller_inst = current.func.defined.inst;
            if (imp.call_slots) |call_slots|
                call_slots(imp.ctx, args, res, s.diag) catch |err| switch (err) {
                    error.Host => {
                        s.stack.items.len = current.stack_base;
                        s.labels.items.len = current.label_base;
                        s.locals.items.len = current.locals_base;
                        s.frames.items.len -= 1;
                        pruneHandlers(s);
                        return handleHostException(s, imp, caller_inst);
                    },
                    else => return err,
                }
            else
                callNumericImport(s.alloc, imp, args, res, s.diag) catch |err| switch (err) {
                    error.Host => {
                        s.stack.items.len = current.stack_base;
                        s.labels.items.len = current.label_base;
                        s.locals.items.len = current.locals_base;
                        s.frames.items.len -= 1;
                        pruneHandlers(s);
                        return handleHostException(s, imp, caller_inst);
                    },
                    else => return err,
                };
            for (res, imp.type.results) |slot, val_type|
                if (!slotMatchesType(slot, val_type)) return s.trap("function signature mismatch");

            s.stack.items.len = current.stack_base;
            for (res) |slot| try pushSlot(s, slot);
            s.labels.items.len = current.label_base;
            s.locals.items.len = current.locals_base;
            s.frames.items.len -= 1;
            pruneHandlers(s);
            checkpoint(s);
        },
    }
}

fn indirectCallable(
    s: *State,
    inst: *const Instance,
    expected: types.FuncType,
    immediate: types.Instr.CallIndirect,
) ExecError!*const FuncInst {
    const tab = inst.tables[immediate.table_index];
    const i = popAddress(s, tab.address);
    tab.lockTable();
    const in_bounds = i < tab.elems.len;
    const target = if (in_bounds) funcFromSlot(tab.elems[@intCast(i)]) else null;
    tab.unlockTable();
    if (!in_bounds) return s.trap("undefined element");
    const callable = target orelse {
        s.diag.set(types.Diagnostic.no_offset, "uninitialized element {d}", .{i});
        return error.Trap;
    };
    const actual: types.FuncType = switch (callable.*) {
        .defined => |d| d.inst.module.funcType(d.inst.module.imported_funcs + d.idx),
        .imported => |im| im.type,
    };
    if (!types.funcTypeEql(expected, actual)) return s.trap("indirect call type mismatch");
    return callable;
}

fn effAddr(s: *State, mem: *const MemoryInst, addr: u64, offset: u64, size: u64) ExecError!usize {
    const ea = std.math.add(u64, addr, offset) catch return s.trap("out of bounds memory access");
    const end = std.math.add(u64, ea, size) catch return s.trap("out of bounds memory access");
    if (end > mem.bytes().len) return s.trap("out of bounds memory access");
    return @intCast(ea);
}

const AtomicDecoded = struct {
    op: wasm_atomic.Op,
    memarg: ?types.Instr.MemArg = null,
};

fn atomicDecoded(instr: types.Instr) AtomicDecoded {
    return switch (instr.imm) {
        .atomic => |op| .{ .op = op },
        .atomic_memarg => |decoded| .{ .op = decoded.op, .memarg = decoded.memarg },
        else => unreachable,
    };
}

fn atomicByteWidth(op: wasm_atomic.Op) usize {
    return @as(usize, 1) << @intCast(op.naturalAlignment().?);
}

fn atomicResultIsI64(op: wasm_atomic.Op) bool {
    return switch (op.shape()) {
        .load_i64, .store_i64, .rmw_i64, .cmpxchg_i64, .wait64 => true,
        else => false,
    };
}

fn atomicAddress(s: *State, mem: *const MemoryInst, addr: u64, memarg: types.Instr.MemArg, width: usize) ExecError!usize {
    const ea = try effAddr(s, mem, addr, memarg.offset, width);
    if ((ea & (width - 1)) != 0) return s.trap("unaligned atomic");
    return ea;
}

fn atomicPtr(comptime T: type, bytes: []u8, offset: usize) *T {
    return @ptrCast(@alignCast(bytes.ptr + offset));
}

fn atomicLoadRaw(bytes: []u8, offset: usize, width: usize) u64 {
    return switch (width) {
        1 => @atomicLoad(u8, atomicPtr(u8, bytes, offset), .seq_cst),
        2 => @atomicLoad(u16, atomicPtr(u16, bytes, offset), .seq_cst),
        4 => @atomicLoad(u32, atomicPtr(u32, bytes, offset), .seq_cst),
        8 => @atomicLoad(u64, atomicPtr(u64, bytes, offset), .seq_cst),
        else => unreachable,
    };
}

fn atomicStoreRaw(bytes: []u8, offset: usize, width: usize, raw: u64) void {
    switch (width) {
        1 => @atomicStore(u8, atomicPtr(u8, bytes, offset), @truncate(raw), .seq_cst),
        2 => @atomicStore(u16, atomicPtr(u16, bytes, offset), @truncate(raw), .seq_cst),
        4 => @atomicStore(u32, atomicPtr(u32, bytes, offset), @truncate(raw), .seq_cst),
        8 => @atomicStore(u64, atomicPtr(u64, bytes, offset), raw, .seq_cst),
        else => unreachable,
    }
}

fn atomicRmwRaw(comptime operation: std.builtin.AtomicRmwOp, bytes: []u8, offset: usize, width: usize, raw: u64) u64 {
    return switch (width) {
        1 => @atomicRmw(u8, atomicPtr(u8, bytes, offset), operation, @truncate(raw), .seq_cst),
        2 => @atomicRmw(u16, atomicPtr(u16, bytes, offset), operation, @truncate(raw), .seq_cst),
        4 => @atomicRmw(u32, atomicPtr(u32, bytes, offset), operation, @truncate(raw), .seq_cst),
        8 => @atomicRmw(u64, atomicPtr(u64, bytes, offset), operation, raw, .seq_cst),
        else => unreachable,
    };
}

fn atomicCmpxchgRaw(bytes: []u8, offset: usize, width: usize, expected: u64, replacement: u64) u64 {
    return switch (width) {
        1 => blk: {
            const e: u8 = @truncate(expected);
            break :blk @cmpxchgStrong(u8, atomicPtr(u8, bytes, offset), e, @truncate(replacement), .seq_cst, .seq_cst) orelse e;
        },
        2 => blk: {
            const e: u16 = @truncate(expected);
            break :blk @cmpxchgStrong(u16, atomicPtr(u16, bytes, offset), e, @truncate(replacement), .seq_cst, .seq_cst) orelse e;
        },
        4 => blk: {
            const e: u32 = @truncate(expected);
            break :blk @cmpxchgStrong(u32, atomicPtr(u32, bytes, offset), e, @truncate(replacement), .seq_cst, .seq_cst) orelse e;
        },
        8 => @cmpxchgStrong(u64, atomicPtr(u64, bytes, offset), expected, replacement, .seq_cst, .seq_cst) orelse expected,
        else => unreachable,
    };
}

fn executeAtomic(s: *State, inst: *Instance, instr: types.Instr) ExecError!void {
    const decoded = atomicDecoded(instr);
    if (decoded.op == .memory_atomic_fence) {
        _ = atomic_fence_word.fetchAdd(0, .seq_cst);
        return;
    }

    const mem = inst.mems[0];
    // Ordinary memories may move on grow. Shared slabs never move, so their
    // atomics stay lock-free and scale through hardware SeqCst operations.
    const lock_memory = !mem.isShared();
    if (lock_memory) while (!mem.grow_lock.tryLock()) std.atomic.spinLoopHint();
    defer if (lock_memory) mem.grow_lock.unlock();

    const memarg = decoded.memarg.?;
    const width = atomicByteWidth(decoded.op);
    switch (decoded.op.shape()) {
        .notify => {
            const count: usize = popI32(s);
            const address = popAddress(s, mem.address);
            const ea = try atomicAddress(s, mem, address, memarg, width);
            const storage = mem.shared_storage orelse {
                try pushI32(s, 0);
                return;
            };
            try pushI32(s, @intCast(agent.notify(storage, ea, count)));
        },
        .wait32, .wait64 => {
            const timeout: i64 = @bitCast(pop(s));
            const expected = pop(s);
            const address = popAddress(s, mem.address);
            const ea = try atomicAddress(s, mem, address, memarg, width);
            const storage = mem.shared_storage orelse return s.trap("expected shared memory");
            checkpoint(s);
            if (s.root_hooks) |hooks| if (hooks.begin_wait) |begin| begin(hooks.ctx);
            defer if (s.root_hooks) |hooks| if (hooks.end_wait) |end| end(hooks.ctx);
            const timeout_ns: ?u64 = if (timeout < 0) null else @intCast(timeout);
            const interrupt: ?agent.WaitInterrupt = if (s.root_hooks) |hooks|
                if (hooks.wait_interrupted) |is_interrupted| .{ .ctx = hooks.ctx, .is_interrupted = is_interrupted } else null
            else
                null;
            const outcome = if (decoded.op.shape() == .wait64)
                agent.waitInterruptible(storage, ea, i64, @bitCast(expected), timeout_ns, interrupt)
            else
                agent.waitInterruptible(storage, ea, i32, @bitCast(@as(u32, @truncate(expected))), timeout_ns, interrupt);
            if (outcome == .interrupted) return s.trap("WebAssembly execution interrupted");
            try pushI32(s, switch (outcome) {
                .ok => 0,
                .not_equal => 1,
                .timed_out => 2,
                .interrupted => unreachable,
            });
        },
        .load_i32, .load_i64 => {
            const address = popAddress(s, mem.address);
            const ea = try atomicAddress(s, mem, address, memarg, width);
            const raw = atomicLoadRaw(mem.bytes(), ea, width);
            if (atomicResultIsI64(decoded.op)) try pushI64(s, raw) else try pushI32(s, @truncate(raw));
        },
        .store_i32, .store_i64 => {
            const value_bits = pop(s);
            const address = popAddress(s, mem.address);
            const ea = try atomicAddress(s, mem, address, memarg, width);
            atomicStoreRaw(mem.bytes(), ea, width, value_bits);
        },
        .rmw_i32, .rmw_i64 => {
            const operand = pop(s);
            const address = popAddress(s, mem.address);
            const ea = try atomicAddress(s, mem, address, memarg, width);
            const group = (@intFromEnum(decoded.op) - 0x1e) / 7;
            const old = switch (group) {
                0 => atomicRmwRaw(.Add, mem.bytes(), ea, width, operand),
                1 => atomicRmwRaw(.Sub, mem.bytes(), ea, width, operand),
                2 => atomicRmwRaw(.And, mem.bytes(), ea, width, operand),
                3 => atomicRmwRaw(.Or, mem.bytes(), ea, width, operand),
                4 => atomicRmwRaw(.Xor, mem.bytes(), ea, width, operand),
                5 => atomicRmwRaw(.Xchg, mem.bytes(), ea, width, operand),
                else => unreachable,
            };
            if (atomicResultIsI64(decoded.op)) try pushI64(s, old) else try pushI32(s, @truncate(old));
        },
        .cmpxchg_i32, .cmpxchg_i64 => {
            const replacement = pop(s);
            const expected = pop(s);
            const address = popAddress(s, mem.address);
            const ea = try atomicAddress(s, mem, address, memarg, width);
            const old = atomicCmpxchgRaw(mem.bytes(), ea, width, expected, replacement);
            if (atomicResultIsI64(decoded.op)) try pushI64(s, old) else try pushI32(s, @truncate(old));
        },
        .fence => unreachable,
    }
}

// IEEE roundTiesToEven via the 2^52/2^23 add-subtract trick (valid in the
// default to-nearest-even rounding mode), with a sign fix for zero results
// (nearest(-0.5) is -0.0, not +0.0).
fn nearestF32(x: f32) f32 {
    const ax = @abs(x);
    if (!(ax < 8388608.0)) return x; // NaN, Inf, or already integral
    const m = std.math.copysign(@as(f32, 8388608.0), x);
    const r = (x + m) - m;
    return if (r == 0) std.math.copysign(@as(f32, 0.0), x) else r;
}

fn nearestF64(x: f64) f64 {
    const ax = @abs(x);
    if (!(ax < 4503599627370496.0)) return x; // NaN, Inf, or already integral
    const m = std.math.copysign(@as(f64, 4503599627370496.0), x);
    const r = (x + m) - m;
    return if (r == 0) std.math.copysign(@as(f64, 0.0), x) else r;
}

// fmin/fmax per the spec pseudo-code: NaN propagates; min(-0,+0) = -0,
// max(-0,+0) = +0.
fn fminF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

fn fmaxF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) b else a;
    return if (a > b) a else b;
}

fn fminF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

fn fmaxF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) b else a;
    return if (a > b) a else b;
}

// Truncations: range-check BEFORE @intFromFloat (which is UB out of range).
fn truncI32S(s: *State, x: anytype) ExecError!i32 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    const ok = if (@TypeOf(x) == f32)
        x >= -2147483648.0 and x < 2147483648.0
    else
        x > -2147483649.0 and x < 2147483648.0;
    if (ok) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncI32U(s: *State, x: anytype) ExecError!u32 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    if (x > -1.0 and x < 4294967296.0) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncI64S(s: *State, x: anytype) ExecError!i64 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    if (x >= -0x1p63 and x < 0x1p63) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncI64U(s: *State, x: anytype) ExecError!u64 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    if (x > -1.0 and x < 0x1p64) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncSatI32S(x: anytype) i32 {
    if (std.math.isNan(x)) return 0;
    if (x >= 2147483648.0) return std.math.maxInt(i32);
    const lower = if (@TypeOf(x) == f32) -2147483648.0 else -2147483649.0;
    if (x <= lower) return std.math.minInt(i32);
    return @intFromFloat(x);
}

fn truncSatI32U(x: anytype) u32 {
    if (std.math.isNan(x) or x <= -1.0) return 0;
    if (x >= 4294967296.0) return std.math.maxInt(u32);
    return @intFromFloat(x);
}

fn truncSatI64S(x: anytype) i64 {
    if (std.math.isNan(x)) return 0;
    if (x <= -0x1p63) return std.math.minInt(i64);
    if (x >= 0x1p63) return std.math.maxInt(i64);
    return @intFromFloat(x);
}

fn truncSatI64U(x: anytype) u64 {
    if (std.math.isNan(x) or x <= -1.0) return 0;
    if (x >= 0x1p64) return std.math.maxInt(u64);
    return @intFromFloat(x);
}

fn execute(s: *State, entry: *const FuncInst, args: []const ValueSlot, results: []ValueSlot) ExecError!void {
    for (args) |slot| try pushSlot(s, slot);
    try pushFrame(s, entry);
    while (s.frames.items.len > 0) {
        const fr = &s.frames.items[s.frames.items.len - 1];
        const inst = fr.func.defined.inst;
        const mod = inst.module;
        const instr = mod.code[fr.func.defined.idx].instrs[fr.pc];
        fr.pc += 1;
        switch (instr.op) {
            .unreachable_ => return s.trap("unreachable"),
            .nop => {},
            .block => try s.labels.append(s.alloc, .{
                .target_pc = instr.imm.block.end_pc,
                .stack_height = s.stack.items.len - instr.imm.block.type.funcType(mod).?.params.len,
                .arity = instr.imm.block.type.funcType(mod).?.results.len,
                .is_loop = false,
            }),
            .try_table => {
                const immediate = instr.imm.try_table;
                const block_type = immediate.block.type.funcType(mod).?;
                const label_index = s.labels.items.len;
                const stack_height = s.stack.items.len - block_type.params.len;
                try s.labels.append(s.alloc, .{
                    .target_pc = immediate.block.end_pc,
                    .stack_height = stack_height,
                    .arity = block_type.results.len,
                    .is_loop = false,
                    .is_try = true,
                });
                try s.handlers.append(s.alloc, .{
                    .frame_index = s.frames.items.len - 1,
                    .label_index = label_index,
                    .stack_height = stack_height,
                    .inst = inst,
                    .catches = immediate.catches,
                });
            },
            .loop => try s.labels.append(s.alloc, .{
                .target_pc = instr.imm.block.else_pc,
                .stack_height = s.stack.items.len - instr.imm.block.type.funcType(mod).?.params.len,
                .arity = instr.imm.block.type.funcType(mod).?.params.len,
                .is_loop = true,
            }),
            .if_ => {
                const b = instr.imm.block;
                if (popI32(s) != 0) {
                    try s.labels.append(s.alloc, .{
                        .target_pc = b.end_pc,
                        .stack_height = s.stack.items.len - b.type.funcType(mod).?.params.len,
                        .arity = b.type.funcType(mod).?.results.len,
                        .is_loop = false,
                    });
                } else if (b.else_pc == b.end_pc) {
                    fr.pc = b.end_pc; // no else arm: skip the whole if
                } else {
                    try s.labels.append(s.alloc, .{
                        .target_pc = b.end_pc,
                        .stack_height = s.stack.items.len - b.type.funcType(mod).?.params.len,
                        .arity = b.type.funcType(mod).?.results.len,
                        .is_loop = false,
                    });
                    fr.pc = b.else_pc;
                }
            },
            .else_ => {
                // The if-arm completed: discard its label, jump past `end`.
                s.labels.items.len -= 1;
                fr.pc = instr.imm.block.end_pc;
            },
            .end => {
                if (s.labels.items[s.labels.items.len - 1].is_try) {
                    std.debug.assert(s.handlers.items.len != 0);
                    std.debug.assert(s.handlers.items[s.handlers.items.len - 1].label_index == s.labels.items.len - 1);
                    s.handlers.items.len -= 1;
                }
                s.labels.items.len -= 1;
                if (s.labels.items.len == fr.label_base) returnFrame(s);
            },
            .br => branchTo(s, instr.imm.idx),
            .br_if => {
                if (popI32(s) != 0) branchTo(s, instr.imm.idx);
            },
            .br_table => {
                const i = popI32(s);
                const bt = instr.imm.br_table;
                branchTo(s, if (i < bt.targets.len) bt.targets[i] else bt.default);
            },
            .return_ => branchTo(s, @intCast(s.labels.items.len - 1 - fr.label_base)),
            .throw => try throwTag(s, inst, instr.imm.idx),
            .throw_ref => try throwReference(s, inst),
            .call => try callFunc(s, inst.funcs[instr.imm.idx]),
            .return_call => try tailCallFunc(s, inst.funcs[instr.imm.idx]),
            .call_indirect => {
                const immediate = instr.imm.call_indirect;
                const callable = try indirectCallable(s, inst, mod.funcTypeAt(immediate.type_index).?, immediate);
                try callFunc(s, callable);
            },
            .return_call_indirect => {
                const immediate = instr.imm.call_indirect;
                const callable = try indirectCallable(s, inst, mod.funcTypeAt(immediate.type_index).?, immediate);
                try tailCallFunc(s, callable);
            },
            .drop => _ = popSlot(s),
            .select, .typed_select => {
                const c = popI32(s);
                const v2 = popSlot(s);
                const v1 = popSlot(s);
                try pushSlot(s, if (c != 0) v1 else v2);
            },
            .local_get => try pushSlot(s, s.locals.items[fr.locals_base + instr.imm.idx]),
            .local_set => s.locals.items[fr.locals_base + instr.imm.idx] = popSlot(s),
            .local_tee => s.locals.items[fr.locals_base + instr.imm.idx] = s.stack.items[s.stack.items.len - 1],
            .global_get => try pushSlot(s, inst.globals[instr.imm.idx].value),
            .global_set => setGlobalValue(inst.globals[instr.imm.idx], popSlot(s)),
            .table_get => {
                const table = inst.tables[instr.imm.idx];
                const index = popAddress(s, table.address);
                table.lockTable();
                const in_bounds = index < table.elems.len;
                const table_entry = if (in_bounds) table.elems[@intCast(index)] else nullTableSlot(table.type);
                table.unlockTable();
                if (!in_bounds) return s.trap("undefined element");
                try pushSlot(s, table_entry);
            },
            .table_set => {
                const slot = popSlot(s);
                const table = inst.tables[instr.imm.idx];
                const index = popAddress(s, table.address);
                if (table.host) |host| host.lock(host.ctx);
                defer if (table.host) |host| host.unlock(host.ctx);
                table.lockTable();
                defer table.unlockTable();
                if (index >= table.elems.len) return s.trap("undefined element");
                table.elems[@intCast(index)] = slot;
                if (table.host) |host| host.sync(host.ctx, table, @intCast(index), 1);
            },
            .ref_null => try pushSlot(s, zeroSlot(instr.imm.type)),
            .ref_is_null => {
                const slot = popSlot(s);
                try pushBool(s, slotIsNull(slot));
            },
            .ref_func => try pushSlot(s, .{ .funcref = @ptrCast(inst.funcs[instr.imm.idx]) }),
            .table_grow => {
                const table = inst.tables[instr.imm.idx];
                const delta = popAddress(s, table.address);
                const slot = popSlot(s);
                try pushAddressGrowResult(s, table.address, tableGrowObserved(table, delta, slot));
            },
            .table_size => {
                const table = inst.tables[instr.imm.idx];
                table.lockTable();
                const len: u64 = @intCast(table.elems.len);
                table.unlockTable();
                try pushAddress(s, table.address, len);
            },
            .table_fill => {
                const table = inst.tables[instr.imm.idx];
                const count = popAddress(s, table.address);
                const slot = popSlot(s);
                const start = popAddress(s, table.address);
                if (table.host) |host| host.lock(host.ctx);
                defer if (table.host) |host| host.unlock(host.ctx);
                table.lockTable();
                defer table.unlockTable();
                const range = checkedRange(start, count, table.elems.len) orelse
                    return s.trap("out of bounds table access");
                @memset(table.elems[range.start..range.end], slot);
                if (table.host) |host| host.sync(host.ctx, table, range.start, range.end - range.start);
            },
            .memory_init => {
                const count = popI32(s);
                const source = popI32(s);
                const immediate = instr.imm.indices;
                const memory = inst.mems[immediate.second];
                const dest = popAddress(s, memory.address);
                const segment = &inst.data_segments[immediate.first];
                const bytes = if (segment.dropped) &.{} else segment.bytes;
                const source_range = checkedRange(source, count, bytes.len) orelse
                    return s.trap("out of bounds memory access");
                const dest_range = checkedRange(dest, count, memory.bytes().len) orelse
                    return s.trap("out of bounds memory access");
                memory.writeSliceUnordered(dest_range.start, bytes[source_range.start..source_range.end]);
            },
            .data_drop => inst.data_segments[instr.imm.idx].dropped = true,
            .memory_copy => {
                const immediate = instr.imm.indices;
                const dest_memory = inst.mems[immediate.first];
                const source_memory = inst.mems[immediate.second];
                const count = popAddress(s, types.AddressType.min(dest_memory.address, source_memory.address));
                const source = popAddress(s, source_memory.address);
                const dest = popAddress(s, dest_memory.address);
                const source_range = checkedRange(source, count, source_memory.bytes().len) orelse
                    return s.trap("out of bounds memory access");
                const dest_range = checkedRange(dest, count, dest_memory.bytes().len) orelse
                    return s.trap("out of bounds memory access");
                copyMemoryUnordered(dest_memory, dest_range.start, source_memory, source_range.start, dest_range.end - dest_range.start);
            },
            .memory_fill => {
                const memory = inst.mems[instr.imm.idx];
                const count = popAddress(s, memory.address);
                const value: u8 = @truncate(popI32(s));
                const dest = popAddress(s, memory.address);
                const range = checkedRange(dest, count, memory.bytes().len) orelse
                    return s.trap("out of bounds memory access");
                memory.fillUnordered(range.start, range.end - range.start, value);
            },
            .table_init => {
                const count = popI32(s);
                const source = popI32(s);
                const immediate = instr.imm.indices;
                const table = inst.tables[immediate.second];
                const dest = popAddress(s, table.address);
                const segment = &inst.elem_segments[immediate.first];
                const elems = if (segment.dropped) &.{} else segment.elems;
                if (table.host) |host| host.lock(host.ctx);
                defer if (table.host) |host| host.unlock(host.ctx);
                table.lockTable();
                defer table.unlockTable();
                const source_range = checkedRange(source, count, elems.len) orelse
                    return s.trap("out of bounds table access");
                const dest_range = checkedRange(dest, count, table.elems.len) orelse
                    return s.trap("out of bounds table access");
                @memcpy(table.elems[dest_range.start..dest_range.end], elems[source_range.start..source_range.end]);
                if (table.host) |host| host.sync(host.ctx, table, dest_range.start, dest_range.end - dest_range.start);
            },
            .elem_drop => inst.elem_segments[instr.imm.idx].dropped = true,
            .table_copy => {
                const immediate = instr.imm.indices;
                const dest_table = inst.tables[immediate.first];
                const source_table = inst.tables[immediate.second];
                const count = popAddress(s, types.AddressType.min(dest_table.address, source_table.address));
                const source = popAddress(s, source_table.address);
                const dest = popAddress(s, dest_table.address);
                if (dest_table == source_table) {
                    if (dest_table.host) |host| host.lock(host.ctx);
                    dest_table.lockTable();
                } else {
                    const first = if (@intFromPtr(dest_table) < @intFromPtr(source_table)) dest_table else source_table;
                    const second = if (first == dest_table) source_table else dest_table;
                    if (first.host) |host| host.lock(host.ctx);
                    if (second.host) |host| host.lock(host.ctx);
                    first.lockTable();
                    second.lockTable();
                }
                defer {
                    if (dest_table == source_table) {
                        dest_table.unlockTable();
                        if (dest_table.host) |host| host.unlock(host.ctx);
                    } else {
                        const first = if (@intFromPtr(dest_table) < @intFromPtr(source_table)) dest_table else source_table;
                        const second = if (first == dest_table) source_table else dest_table;
                        second.unlockTable();
                        first.unlockTable();
                        if (second.host) |host| host.unlock(host.ctx);
                        if (first.host) |host| host.unlock(host.ctx);
                    }
                }
                const source_range = checkedRange(source, count, source_table.elems.len) orelse
                    return s.trap("out of bounds table access");
                const dest_range = checkedRange(dest, count, dest_table.elems.len) orelse
                    return s.trap("out of bounds table access");
                const dest_slice = dest_table.elems[dest_range.start..dest_range.end];
                const source_slice = source_table.elems[source_range.start..source_range.end];
                if (dest_table != source_table or dest <= source)
                    std.mem.copyForwards(ValueSlot, dest_slice, source_slice)
                else
                    std.mem.copyBackwards(ValueSlot, dest_slice, source_slice);
                if (dest_table.host) |host| host.sync(host.ctx, dest_table, dest_range.start, dest_range.end - dest_range.start);
            },
            .i32_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                try pushI32(s, @truncate(mem.readUnordered(ea, 4)));
            },
            .i64_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 8);
                try pushI64(s, mem.readUnordered(ea, 8));
            },
            .f32_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                try push(s, @truncate(mem.readUnordered(ea, 4)));
            },
            .f64_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 8);
                try push(s, mem.readUnordered(ea, 8));
            },
            .i32_load8_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 1);
                try pushI32(s, @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(mem.readUnordered(ea, 1))))))));
            },
            .i32_load8_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 1);
                try pushI32(s, @truncate(mem.readUnordered(ea, 1)));
            },
            .i32_load16_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 2);
                try pushI32(s, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(mem.readUnordered(ea, 2))))))));
            },
            .i32_load16_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 2);
                try pushI32(s, @truncate(mem.readUnordered(ea, 2)));
            },
            .i64_load8_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 1);
                try pushI64(s, @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(mem.readUnordered(ea, 1))))))));
            },
            .i64_load8_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 1);
                try pushI64(s, mem.readUnordered(ea, 1));
            },
            .i64_load16_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 2);
                try pushI64(s, @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(mem.readUnordered(ea, 2))))))));
            },
            .i64_load16_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 2);
                try pushI64(s, mem.readUnordered(ea, 2));
            },
            .i64_load32_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                try pushI64(s, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(mem.readUnordered(ea, 4))))))));
            },
            .i64_load32_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                try pushI64(s, mem.readUnordered(ea, 4));
            },
            .i32_store => {
                const v = popI32(s);
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                mem.writeUnordered(ea, 4, v);
            },
            .i64_store => {
                const v = pop(s);
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 8);
                mem.writeUnordered(ea, 8, v);
            },
            .f32_store => {
                const v = @as(u32, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                mem.writeUnordered(ea, 4, v);
            },
            .f64_store => {
                const v = pop(s);
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 8);
                mem.writeUnordered(ea, 8, v);
            },
            .i32_store8 => {
                const v = @as(u8, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 1);
                mem.writeUnordered(ea, 1, v);
            },
            .i32_store16 => {
                const v = @as(u16, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 2);
                mem.writeUnordered(ea, 2, v);
            },
            .i64_store8 => {
                const v = @as(u8, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 1);
                mem.writeUnordered(ea, 1, v);
            },
            .i64_store16 => {
                const v = @as(u16, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 2);
                mem.writeUnordered(ea, 2, v);
            },
            .i64_store32 => {
                const v = @as(u32, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popAddress(s, mem.address), m.offset, 4);
                mem.writeUnordered(ea, 4, v);
            },
            .memory_size => {
                const memory = inst.mems[0];
                try pushAddress(s, memory.address, memory.pages());
            },
            .memory_grow => {
                const memory = inst.mems[0];
                const delta = popAddress(s, memory.address);
                checkpoint(s);
                try pushAddressGrowResult(s, memory.address, memoryGrowAddressed(memory, delta));
            },
            .i32_const => try pushI32(s, @bitCast(instr.imm.i32)),
            .i64_const => try pushI64(s, @bitCast(instr.imm.i64)),
            .f32_const => try push(s, instr.imm.f32),
            .f64_const => try push(s, instr.imm.f64),
            .gc => try executeGc(s, inst, instr),
            .ref_eq => {
                const b = popSlot(s);
                const a = popSlot(s);
                const equal = switch (a) {
                    .i31ref => |value| b == .i31ref and value == b.i31ref,
                    .gcref => |value| b == .gcref and value == b.gcref,
                    else => unreachable,
                };
                try pushBool(s, equal);
            },
            .ref_as_non_null => {
                const reference = popSlot(s);
                if (slotIsNull(reference)) return s.trap("null reference");
                try pushSlot(s, reference);
            },
            .simd => try executeSimd(s, inst, instr),
            .atomic => try executeAtomic(s, inst, instr),
            .i32_eqz => try pushBool(s, popI32(s) == 0),
            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => {
                const bu = popI32(s);
                const au = popI32(s);
                const a: i32 = @bitCast(au);
                const b: i32 = @bitCast(bu);
                try pushBool(s, switch (instr.op) {
                    .i32_eq => au == bu,
                    .i32_ne => au != bu,
                    .i32_lt_s => a < b,
                    .i32_lt_u => au < bu,
                    .i32_gt_s => a > b,
                    .i32_gt_u => au > bu,
                    .i32_le_s => a <= b,
                    .i32_le_u => au <= bu,
                    .i32_ge_s => a >= b,
                    .i32_ge_u => au >= bu,
                    else => unreachable,
                });
            },
            .i64_eqz => try pushBool(s, pop(s) == 0),
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => {
                const bu = pop(s);
                const au = pop(s);
                const a: i64 = @bitCast(au);
                const b: i64 = @bitCast(bu);
                try pushBool(s, switch (instr.op) {
                    .i64_eq => au == bu,
                    .i64_ne => au != bu,
                    .i64_lt_s => a < b,
                    .i64_lt_u => au < bu,
                    .i64_gt_s => a > b,
                    .i64_gt_u => au > bu,
                    .i64_le_s => a <= b,
                    .i64_le_u => au <= bu,
                    .i64_ge_s => a >= b,
                    .i64_ge_u => au >= bu,
                    else => unreachable,
                });
            },
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => {
                const b = popF32(s);
                const a = popF32(s);
                try pushBool(s, switch (instr.op) {
                    .f32_eq => a == b,
                    .f32_ne => a != b,
                    .f32_lt => a < b,
                    .f32_gt => a > b,
                    .f32_le => a <= b,
                    .f32_ge => a >= b,
                    else => unreachable,
                });
            },
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => {
                const b = popF64(s);
                const a = popF64(s);
                try pushBool(s, switch (instr.op) {
                    .f64_eq => a == b,
                    .f64_ne => a != b,
                    .f64_lt => a < b,
                    .f64_gt => a > b,
                    .f64_le => a <= b,
                    .f64_ge => a >= b,
                    else => unreachable,
                });
            },
            .i32_clz => try pushI32(s, @clz(popI32(s))),
            .i32_ctz => try pushI32(s, @ctz(popI32(s))),
            .i32_popcnt => try pushI32(s, @popCount(popI32(s))),
            .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => {
                const bu = popI32(s);
                const au = popI32(s);
                const a: i32 = @bitCast(au);
                const b: i32 = @bitCast(bu);
                const r: u32 = switch (instr.op) {
                    .i32_add => au +% bu,
                    .i32_sub => au -% bu,
                    .i32_mul => au *% bu,
                    .i32_div_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i32) and b == -1) return s.trap("integer overflow");
                        break :blk @bitCast(@divTrunc(a, b));
                    },
                    .i32_div_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @divTrunc(au, bu);
                    },
                    .i32_rem_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i32) and b == -1) break :blk 0;
                        break :blk @bitCast(@rem(a, b));
                    },
                    .i32_rem_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @rem(au, bu);
                    },
                    .i32_and => au & bu,
                    .i32_or => au | bu,
                    .i32_xor => au ^ bu,
                    .i32_shl => au << @as(u5, @truncate(bu)),
                    .i32_shr_s => @bitCast(a >> @as(u5, @truncate(bu))),
                    .i32_shr_u => au >> @as(u5, @truncate(bu)),
                    .i32_rotl => std.math.rotl(u32, au, bu),
                    .i32_rotr => std.math.rotr(u32, au, bu),
                    else => unreachable,
                };
                try pushI32(s, r);
            },
            .i64_clz => try pushI64(s, @clz(pop(s))),
            .i64_ctz => try pushI64(s, @ctz(pop(s))),
            .i64_popcnt => try pushI64(s, @popCount(pop(s))),
            .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => {
                const bu = pop(s);
                const au = pop(s);
                const a: i64 = @bitCast(au);
                const b: i64 = @bitCast(bu);
                const r: u64 = switch (instr.op) {
                    .i64_add => au +% bu,
                    .i64_sub => au -% bu,
                    .i64_mul => au *% bu,
                    .i64_div_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i64) and b == -1) return s.trap("integer overflow");
                        break :blk @bitCast(@divTrunc(a, b));
                    },
                    .i64_div_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @divTrunc(au, bu);
                    },
                    .i64_rem_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i64) and b == -1) break :blk 0;
                        break :blk @bitCast(@rem(a, b));
                    },
                    .i64_rem_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @rem(au, bu);
                    },
                    .i64_and => au & bu,
                    .i64_or => au | bu,
                    .i64_xor => au ^ bu,
                    .i64_shl => au << @as(u6, @truncate(bu)),
                    .i64_shr_s => @bitCast(a >> @as(u6, @truncate(bu))),
                    .i64_shr_u => au >> @as(u6, @truncate(bu)),
                    .i64_rotl => std.math.rotl(u64, au, bu),
                    .i64_rotr => std.math.rotr(u64, au, bu),
                    else => unreachable,
                };
                try pushI64(s, r);
            },
            .f32_abs => try push(s, pop(s) & 0x7FFF_FFFF),
            .f32_neg => try push(s, pop(s) ^ 0x8000_0000),
            .f32_ceil => try pushF32(s, @ceil(popF32(s))),
            .f32_floor => try pushF32(s, @floor(popF32(s))),
            .f32_trunc => try pushF32(s, @trunc(popF32(s))),
            .f32_nearest => try pushF32(s, nearestF32(popF32(s))),
            .f32_sqrt => try pushF32(s, @sqrt(popF32(s))),
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max => {
                const b = popF32(s);
                const a = popF32(s);
                try pushF32(s, switch (instr.op) {
                    .f32_add => a + b,
                    .f32_sub => a - b,
                    .f32_mul => a * b,
                    .f32_div => a / b,
                    .f32_min => fminF32(a, b),
                    .f32_max => fmaxF32(a, b),
                    else => unreachable,
                });
            },
            .f32_copysign => {
                const b = pop(s);
                const a = pop(s);
                try push(s, (a & 0x7FFF_FFFF) | (b & 0x8000_0000));
            },
            .f64_abs => try push(s, pop(s) & 0x7FFF_FFFF_FFFF_FFFF),
            .f64_neg => try push(s, pop(s) ^ 0x8000_0000_0000_0000),
            .f64_ceil => try pushF64(s, @ceil(popF64(s))),
            .f64_floor => try pushF64(s, @floor(popF64(s))),
            .f64_trunc => try pushF64(s, @trunc(popF64(s))),
            .f64_nearest => try pushF64(s, nearestF64(popF64(s))),
            .f64_sqrt => try pushF64(s, @sqrt(popF64(s))),
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max => {
                const b = popF64(s);
                const a = popF64(s);
                try pushF64(s, switch (instr.op) {
                    .f64_add => a + b,
                    .f64_sub => a - b,
                    .f64_mul => a * b,
                    .f64_div => a / b,
                    .f64_min => fminF64(a, b),
                    .f64_max => fmaxF64(a, b),
                    else => unreachable,
                });
            },
            .f64_copysign => {
                const b = pop(s);
                const a = pop(s);
                try push(s, (a & 0x7FFF_FFFF_FFFF_FFFF) | (b & 0x8000_0000_0000_0000));
            },
            .i32_wrap_i64 => try pushI32(s, @truncate(pop(s))),
            .i32_trunc_f32_s => try pushI32(s, @bitCast(try truncI32S(s, popF32(s)))),
            .i32_trunc_f32_u => try pushI32(s, try truncI32U(s, popF32(s))),
            .i32_trunc_f64_s => try pushI32(s, @bitCast(try truncI32S(s, popF64(s)))),
            .i32_trunc_f64_u => try pushI32(s, try truncI32U(s, popF64(s))),
            .i64_extend_i32_s => try pushI64(s, @bitCast(@as(i64, @as(i32, @bitCast(popI32(s)))))),
            .i64_extend_i32_u => try pushI64(s, popI32(s)),
            .i64_trunc_f32_s => try pushI64(s, @bitCast(try truncI64S(s, popF32(s)))),
            .i64_trunc_f32_u => try pushI64(s, try truncI64U(s, popF32(s))),
            .i64_trunc_f64_s => try pushI64(s, @bitCast(try truncI64S(s, popF64(s)))),
            .i64_trunc_f64_u => try pushI64(s, try truncI64U(s, popF64(s))),
            .f32_convert_i32_s => try pushF32(s, @floatFromInt(@as(i32, @bitCast(popI32(s))))),
            .f32_convert_i32_u => try pushF32(s, @floatFromInt(popI32(s))),
            .f32_convert_i64_s => try pushF32(s, @floatFromInt(@as(i64, @bitCast(pop(s))))),
            .f32_convert_i64_u => try pushF32(s, @floatFromInt(pop(s))),
            .f32_demote_f64 => try pushF32(s, @floatCast(popF64(s))),
            .f64_convert_i32_s => try pushF64(s, @floatFromInt(@as(i32, @bitCast(popI32(s))))),
            .f64_convert_i32_u => try pushF64(s, @floatFromInt(popI32(s))),
            .f64_convert_i64_s => try pushF64(s, @floatFromInt(@as(i64, @bitCast(pop(s))))),
            .f64_convert_i64_u => try pushF64(s, @floatFromInt(pop(s))),
            .f64_promote_f32 => try pushF64(s, @floatCast(popF32(s))),
            .i32_reinterpret_f32 => try pushI32(s, @bitCast(popF32(s))),
            .i64_reinterpret_f64 => try pushI64(s, @bitCast(popF64(s))),
            .f32_reinterpret_i32 => try pushF32(s, @bitCast(popI32(s))),
            .f64_reinterpret_i64 => try pushF64(s, @bitCast(pop(s))),
            .i32_extend8_s => {
                const value: i8 = @bitCast(@as(u8, @truncate(popI32(s))));
                try pushI32(s, @bitCast(@as(i32, value)));
            },
            .i32_extend16_s => {
                const value: i16 = @bitCast(@as(u16, @truncate(popI32(s))));
                try pushI32(s, @bitCast(@as(i32, value)));
            },
            .i64_extend8_s => {
                const value: i8 = @bitCast(@as(u8, @truncate(pop(s))));
                try pushI64(s, @bitCast(@as(i64, value)));
            },
            .i64_extend16_s => {
                const value: i16 = @bitCast(@as(u16, @truncate(pop(s))));
                try pushI64(s, @bitCast(@as(i64, value)));
            },
            .i64_extend32_s => {
                const value: i32 = @bitCast(@as(u32, @truncate(pop(s))));
                try pushI64(s, @bitCast(@as(i64, value)));
            },
            .i32_trunc_sat_f32_s => try pushI32(s, @bitCast(truncSatI32S(popF32(s)))),
            .i32_trunc_sat_f32_u => try pushI32(s, truncSatI32U(popF32(s))),
            .i32_trunc_sat_f64_s => try pushI32(s, @bitCast(truncSatI32S(popF64(s)))),
            .i32_trunc_sat_f64_u => try pushI32(s, truncSatI32U(popF64(s))),
            .i64_trunc_sat_f32_s => try pushI64(s, @bitCast(truncSatI64S(popF32(s)))),
            .i64_trunc_sat_f32_u => try pushI64(s, truncSatI64U(popF32(s))),
            .i64_trunc_sat_f64_s => try pushI64(s, @bitCast(truncSatI64S(popF64(s)))),
            .i64_trunc_sat_f64_u => try pushI64(s, truncSatI64U(popF64(s))),
        }
    }
    @memcpy(results, s.stack.items[s.stack.items.len - results.len ..]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const hdr = "\x00asm\x01\x00\x00\x00";
const talloc = std.testing.allocator;

const I32 = "\x7F";
const I64 = "\x7E";
const F32 = "\x7D";
const F64 = "\x7C";
const V128 = "\x7B";
const EXNREF = "\x69";

const f32nan: u64 = 0x7FC00000;
const f64nan: u64 = 0x7FF8000000000000;

const RootHookProbe = struct {
    enters: usize = 0,
    leaves: usize = 0,
    checkpoints: usize = 0,

    fn enter(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) error{OutOfMemory}!void {
        const self: *RootHookProbe = @ptrCast(@alignCast(raw));
        self.enters += 1;
        std.debug.assert(roots.stack.len == 0 and roots.locals.len == 0);
    }

    fn leave(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *RootHookProbe = @ptrCast(@alignCast(raw));
        self.leaves += 1;
        std.debug.assert(roots.stack.len <= MAX_OPERAND_SLOTS);
    }

    fn checkpoint(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *RootHookProbe = @ptrCast(@alignCast(raw));
        self.checkpoints += 1;
        std.debug.assert(roots.stack.len <= MAX_OPERAND_SLOTS);
    }
};

fn rejectNumericReferenceCall(_: *anyopaque, _: []const u64, _: []u64, _: *types.Diagnostic) error{ Trap, Host }!void {
    return error.Trap;
}

fn echoReferenceSlot(_: *anyopaque, args: []const ValueSlot, results: []ValueSlot, _: *types.Diagnostic) error{ Trap, Host }!void {
    results[0] = args[0];
}

fn trapReferenceSlot(_: *anyopaque, _: []const ValueSlot, _: []ValueSlot, _: *types.Diagnostic) error{ Trap, Host }!void {
    return error.Trap;
}

fn recordGlobalBarrier(raw: *anyopaque, slot: ValueSlot) void {
    const count: *usize = @ptrCast(@alignCast(raw));
    if (slot == .externref) count.* += 1;
}

const RootLivenessProbe = struct {
    externrefs: [4]usize = .{ 0, 0, 0, 0 },
    len: usize = 0,

    fn enter(_: *anyopaque, _: *js_value.WasmExecutionRoots) error{OutOfMemory}!void {}
    fn leave(_: *anyopaque, _: *js_value.WasmExecutionRoots) void {}
    fn checkpoint(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *RootLivenessProbe = @ptrCast(@alignCast(raw));
        var count: usize = 0;
        for (roots.stack) |slot| if (slot == .externref) {
            count += 1;
        };
        for (roots.locals) |slot| if (slot == .externref) {
            count += 1;
        };
        self.externrefs[self.len] = count;
        self.len += 1;
    }
};

const TailRootProbe = struct {
    checkpoint_limit: usize,
    expected_externref: ?*js_value.Object = null,
    expected_funcref: ?*anyopaque = null,
    checkpoints: usize = 0,
    max_stack: usize = 0,
    max_locals: usize = 0,
    max_externrefs: usize = 0,
    max_funcrefs: usize = 0,
    saw_expected_externref: bool = false,
    saw_expected_funcref: bool = false,

    fn enter(_: *anyopaque, roots: *js_value.WasmExecutionRoots) error{OutOfMemory}!void {
        std.debug.assert(roots.stack.len == 0 and roots.locals.len == 0);
    }

    fn leave(_: *anyopaque, _: *js_value.WasmExecutionRoots) void {}

    fn checkpoint(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *TailRootProbe = @ptrCast(@alignCast(raw));
        self.checkpoints += 1;
        // A finite checkpoint budget is the stress-test watchdog: incorrect
        // tail dispatch cannot silently spin past the declared recursion input.
        std.debug.assert(self.checkpoints <= self.checkpoint_limit);
        self.max_stack = @max(self.max_stack, roots.stack.len);
        self.max_locals = @max(self.max_locals, roots.locals.len);
        var externrefs: usize = 0;
        var funcrefs: usize = 0;
        for (roots.stack) |slot| self.observe(slot, &externrefs, &funcrefs);
        for (roots.locals) |slot| self.observe(slot, &externrefs, &funcrefs);
        self.max_externrefs = @max(self.max_externrefs, externrefs);
        self.max_funcrefs = @max(self.max_funcrefs, funcrefs);
    }

    fn observe(self: *TailRootProbe, slot: ValueSlot, externrefs: *usize, funcrefs: *usize) void {
        switch (slot) {
            .externref => |ref| {
                externrefs.* += 1;
                if (self.expected_externref) |expected| {
                    if (ref.isObject() and ref.asObj() == expected)
                        self.saw_expected_externref = true;
                }
            },
            .funcref => |ref| {
                funcrefs.* += 1;
                if (self.expected_funcref) |expected| {
                    if (ref == expected)
                        self.saw_expected_funcref = true;
                }
            },
            else => {},
        }
    }

    fn hooks(self: *TailRootProbe) RootHooks {
        return .{
            .ctx = @ptrCast(self),
            .enter = TailRootProbe.enter,
            .leave = TailRootProbe.leave,
            .checkpoint = TailRootProbe.checkpoint,
        };
    }
};

fn leb(comptime v: u64) []const u8 {
    comptime {
        var buf: []const u8 = &.{};
        var x = v;
        while (true) {
            var b: u8 = @truncate(x);
            x >>= 7;
            if (x != 0) b |= 0x80;
            buf = buf ++ &[_]u8{b};
            if (x == 0) break;
        }
        return buf;
    }
}

fn sleb(comptime v: i64) []const u8 {
    comptime {
        var buf: []const u8 = &.{};
        var x = v;
        while (true) {
            const b: u8 = @truncate(@as(u64, @bitCast(x)) & 0x7F);
            x >>= 7;
            const sign = (b & 0x40) != 0;
            if ((x == 0 and !sign) or (x == -1 and sign)) {
                buf = buf ++ &[_]u8{b};
                break;
            }
            buf = buf ++ &[_]u8{b | 0x80};
        }
        return buf;
    }
}

fn sec(comptime id: u8, comptime payload: []const u8) []const u8 {
    comptime return &[_]u8{id} ++ leb(payload.len) ++ payload;
}

fn ft(comptime params: []const u8, comptime results: []const u8) []const u8 {
    comptime return "\x60" ++ leb(params.len) ++ params ++ leb(results.len) ++ results;
}

fn ob(comptime op: types.Op) []const u8 {
    comptime {
        const raw = @intFromEnum(op);
        if (raw <= 0xFF) return &[_]u8{@intCast(raw)};
        std.debug.assert(raw >> 8 == 0xFC);
        return "\xFC" ++ leb(raw & 0xFF);
    }
}

fn typesSec(comptime defs: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(defs.len);
        for (defs) |d| payload = payload ++ d;
        return sec(1, payload);
    }
}

fn funcSec(comptime type_indices: []const u32) []const u8 {
    comptime {
        var payload: []const u8 = leb(type_indices.len);
        for (type_indices) |t| payload = payload ++ leb(t);
        return sec(3, payload);
    }
}

fn codeSec(comptime bodies: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(bodies.len);
        for (bodies) |b| {
            const full = "\x00" ++ b ++ "\x0B";
            payload = payload ++ leb(full.len) ++ full;
        }
        return sec(10, payload);
    }
}

fn codeSecL(comptime locals_decl: []const u8, comptime body: []const u8) []const u8 {
    comptime {
        const full = locals_decl ++ body ++ "\x0B";
        return sec(10, leb(1) ++ leb(full.len) ++ full);
    }
}

fn deepExceptionBody(comptime depth: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        var body: []const u8 = "\x1F\x40\x01\x00\x01\x00"; // outer tag 1 -> function
        for (0..depth) |_| body = body ++ "\x1F\x40\x01\x00\x00\x00"; // nonmatching tag 0
        body = body ++ i32c(123) ++ "\x08\x01";
        for (0..depth + 1) |_| body = body ++ "\x0B";
        return body ++ i32c(9);
    }
}

fn memSec(comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return sec(5, "\x01\x01" ++ leb(min) ++ leb(m));
        return sec(5, "\x01\x00" ++ leb(min));
    }
}

fn mem64Sec(comptime min: usize, comptime max: ?usize) []const u8 {
    comptime {
        if (max) |m| return sec(5, "\x01\x05" ++ leb(min) ++ leb(m));
        return sec(5, "\x01\x04" ++ leb(min));
    }
}

fn tableSec(comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return sec(4, "\x01\x70\x01" ++ leb(min) ++ leb(m));
        return sec(4, "\x01\x70\x00" ++ leb(min));
    }
}

fn table64Sec(comptime min: usize, comptime max: ?usize) []const u8 {
    comptime {
        if (max) |m| return sec(4, "\x01\x70\x05" ++ leb(min) ++ leb(m));
        return sec(4, "\x01\x70\x04" ++ leb(min));
    }
}

fn glob(comptime vt: []const u8, comptime mutable: bool, comptime init: []const u8) []const u8 {
    comptime return vt ++ &[_]u8{@intFromBool(mutable)} ++ init ++ "\x0B";
}

fn globalSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |e| payload = payload ++ e;
        return sec(6, payload);
    }
}

fn i32c(comptime v: i32) []const u8 {
    comptime return "\x41" ++ sleb(v);
}

fn i64c(comptime v: i64) []const u8 {
    comptime return "\x42" ++ sleb(v);
}

fn f32c(comptime v: f32) []const u8 {
    comptime {
        const b: u32 = @bitCast(v);
        return "\x43" ++ &[_]u8{ @truncate(b), @truncate(b >> 8), @truncate(b >> 16), @truncate(b >> 24) };
    }
}

fn f64c(comptime v: f64) []const u8 {
    comptime {
        const b: u64 = @bitCast(v);
        return "\x44" ++ &[_]u8{
            @truncate(b),       @truncate(b >> 8),  @truncate(b >> 16), @truncate(b >> 24),
            @truncate(b >> 32), @truncate(b >> 40), @truncate(b >> 48), @truncate(b >> 56),
        };
    }
}

fn impName(comptime module: []const u8, comptime name: []const u8) []const u8 {
    comptime return leb(module.len) ++ module ++ leb(name.len) ++ name;
}

fn impFunc(comptime module: []const u8, comptime name: []const u8, comptime typeidx: u32) []const u8 {
    comptime return impName(module, name) ++ "\x00" ++ leb(typeidx);
}

fn impTable(comptime module: []const u8, comptime name: []const u8, comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return impName(module, name) ++ "\x01\x70\x01" ++ leb(min) ++ leb(m);
        return impName(module, name) ++ "\x01\x70\x00" ++ leb(min);
    }
}

fn impMem(comptime module: []const u8, comptime name: []const u8, comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return impName(module, name) ++ "\x02\x01" ++ leb(min) ++ leb(m);
        return impName(module, name) ++ "\x02\x00" ++ leb(min);
    }
}

fn impGlobal(comptime module: []const u8, comptime name: []const u8, comptime vt: []const u8, comptime mutable: bool) []const u8 {
    comptime return impName(module, name) ++ "\x03" ++ vt ++ &[_]u8{@intFromBool(mutable)};
}

fn importSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |e| payload = payload ++ e;
        return sec(2, payload);
    }
}

fn elemSec0(comptime offset: i32, comptime funcs: []const u32) []const u8 {
    comptime {
        return sec(9, "\x01" ++ elemEntry0(offset, funcs));
    }
}

fn dataSec0(comptime offset: i32, comptime bytes: []const u8) []const u8 {
    comptime return sec(11, "\x01" ++ dataEntry0(offset, bytes));
}

fn elemEntry0(comptime offset: i32, comptime funcs: []const u32) []const u8 {
    comptime {
        var encoded: []const u8 = &.{};
        for (funcs) |index| encoded = encoded ++ leb(index);
        return "\x00" ++ i32c(offset) ++ "\x0B" ++ leb(funcs.len) ++ encoded;
    }
}

fn elemSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |entry| payload = payload ++ entry;
        return sec(9, payload);
    }
}

fn dataEntry0(comptime offset: i32, comptime bytes: []const u8) []const u8 {
    comptime return "\x00" ++ i32c(offset) ++ "\x0B" ++ leb(bytes.len) ++ bytes;
}

fn dataSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |entry| payload = payload ++ entry;
        return sec(11, payload);
    }
}

fn startSec(comptime funcidx: u32) []const u8 {
    comptime return sec(8, leb(funcidx));
}

fn arithModule(comptime params: []const u8, comptime results: []const u8, comptime body: []const u8) []const u8 {
    comptime return hdr ++ typesSec(&.{ft(params, results)}) ++ funcSec(&.{0}) ++ codeSec(&.{body});
}

// Value bit-pattern helpers.
fn i32v(comptime v: i32) u64 {
    return @as(u32, @bitCast(v));
}

fn i64v(comptime v: i64) u64 {
    return @bitCast(v);
}

fn f32v(comptime v: f32) u64 {
    return @as(u32, @bitCast(v));
}

fn f64v(comptime v: f64) u64 {
    return @bitCast(v);
}

fn bitsToF32(v: u64) f32 {
    return @bitCast(@as(u32, @truncate(v)));
}

fn bitsToF64(v: u64) f64 {
    return @bitCast(v);
}

// Module / instance lifecycle helpers.
fn buildModule(bytes: []const u8, diag: *types.Diagnostic) !*types.Module {
    return buildModuleWithFeatures(bytes, .{}, diag);
}

fn buildModuleWithFeatures(bytes: []const u8, features: types.Features, diag: *types.Diagnostic) !*types.Module {
    const mod = try decode.decodeWithFeatures(talloc, bytes, features, diag);
    errdefer decode.destroyModule(talloc, mod);
    try validate.validate(mod, diag);
    return mod;
}

const Built = struct { mod: *types.Module, inst: *Instance };

fn build(comptime bytes: []const u8) !Built {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(bytes, &diag);
    errdefer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    return .{ .mod = mod, .inst = inst };
}

fn destroyBuilt(b: Built) void {
    destroyInstance(talloc, b.inst);
    decode.destroyModule(talloc, b.mod);
}

fn expectResults(comptime bytes: []const u8, funcidx: u32, args: []const u64, expected: []const u64) !void {
    return expectResultsWithFeatures(bytes, .{}, funcidx, args, expected);
}

fn expectResultsWithFeatures(comptime bytes: []const u8, features: types.Features, funcidx: u32, args: []const u64, expected: []const u64) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    const res = try talloc.alloc(u64, expected.len);
    defer talloc.free(res);
    try invoke(inst, funcidx, args, res, &diag);
    try std.testing.expectEqualSlices(u64, expected, res);
}

fn expectTrap(comptime bytes: []const u8, comptime nres: usize, funcidx: u32, args: []const u64, msg: []const u8) !void {
    return expectTrapWithFeatures(bytes, .{}, nres, funcidx, args, msg);
}

fn expectTrapWithFeatures(
    comptime bytes: []const u8,
    features: types.Features,
    comptime nres: usize,
    funcidx: u32,
    args: []const u64,
    msg: []const u8,
) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    var res: [nres]u64 = undefined;
    try std.testing.expectError(error.Trap, invoke(inst, funcidx, args, &res, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
}

fn expectLink(comptime bytes: []const u8, imports: Imports, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    if (instantiate(talloc, mod, imports, &diag)) |inst| {
        destroyInstance(talloc, inst);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.Link, err);
        try std.testing.expectEqualStrings(msg, diag.message());
    }
}

fn expectInstantiationTrap(comptime bytes: []const u8, imports: Imports, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    try std.testing.expectError(error.Trap, instantiate(talloc, mod, imports, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
}

fn binop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, b: u64, expected: u64) !void {
    const bytes = comptime arithModule(pt ++ pt, rt, "\x20\x00\x20\x01" ++ ob(op));
    try expectResults(bytes, 0, &.{ a, b }, &.{expected});
}

fn binopTrap(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, b: u64, msg: []const u8) !void {
    const bytes = comptime arithModule(pt ++ pt, rt, "\x20\x00\x20\x01" ++ ob(op));
    try expectTrap(bytes, 1, 0, &.{ a, b }, msg);
}

fn unop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, expected: u64) !void {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    try expectResults(bytes, 0, &.{a}, &.{expected});
}

fn unopWithFeatures(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, features: types.Features, a: u64, expected: u64) !void {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    try expectResultsWithFeatures(bytes, features, 0, &.{a}, &.{expected});
}

fn unopTrap(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, msg: []const u8) !void {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    try expectTrap(bytes, 1, 0, &.{a}, msg);
}

fn runBinop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, b: u64) !u64 {
    const bytes = comptime arithModule(pt ++ pt, rt, "\x20\x00\x20\x01" ++ ob(op));
    var diag: types.Diagnostic = .{};
    const bld = try build(bytes);
    defer destroyBuilt(bld);
    var res: [1]u64 = .{0};
    try invoke(bld.inst, 0, &.{ a, b }, &res, &diag);
    return res[0];
}

fn runUnop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64) !u64 {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    var diag: types.Diagnostic = .{};
    const bld = try build(bytes);
    defer destroyBuilt(bld);
    var res: [1]u64 = .{0};
    try invoke(bld.inst, 0, &.{a}, &res, &diag);
    return res[0];
}

fn run1(inst: *Instance, funcidx: u32, args: []const u64) !u64 {
    var diag: types.Diagnostic = .{};
    var res: [1]u64 = .{0};
    try invoke(inst, funcidx, args, &res, &diag);
    return res[0];
}

fn run0(inst: *Instance, funcidx: u32, args: []const u64) !void {
    var diag: types.Diagnostic = .{};
    try invoke(inst, funcidx, args, &.{}, &diag);
}

fn runTrap(comptime nres: usize, inst: *Instance, funcidx: u32, args: []const u64, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    var res: [nres]u64 = undefined;
    try std.testing.expectError(error.Trap, invoke(inst, funcidx, args, &res, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
}

// -- Host-side constructors --------------------------------------------------

test "wasm.exec memory64 addressed instances and host allocation limits" {
    try std.testing.expect(!memory64HostSupportedForPointerBits(32));
    try std.testing.expect(memory64HostSupportedForPointerBits(64));
    try std.testing.expect(memory64HostSupported());

    const memory = try createMemoryAddressed(talloc, .i64, 1, 2, false);
    defer destroyMemory(talloc, memory);
    try std.testing.expectEqual(types.AddressType.i64, memory.address);
    try std.testing.expectEqual(@as(u32, 1), memory.pages());

    const table = try createTableAddressed(talloc, .i64, .funcref, 1, 2);
    defer destroyTable(talloc, table);
    try std.testing.expectEqual(types.AddressType.i64, table.address);

    try std.testing.expectError(
        error.OutOfMemory,
        createMemoryAddressed(talloc, .i64, MAX_HOST_MEMORY64_PAGES + 1, null, false),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        createMemoryAddressed(talloc, .i64, 1, MAX_HOST_MEMORY64_PAGES + 1, true),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        createTableAddressed(talloc, .i64, .funcref, MAX_HOST_TABLE_ELEMENTS + 1, null),
    );

    const bytes = comptime (hdr ++
        sec(4, "\x01\x70\x04\x01") ++
        sec(5, "\x01\x04\x01"));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .memory64 = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(types.AddressType.i64, inst.mems[0].address);
    try std.testing.expectEqual(types.AddressType.i64, inst.tables[0].address);
}

test "wasm.exec shared memory64 grows concurrently without moving its backing" {
    const mem = try createMemoryAddressed(talloc, .i64, 1, 9, true);
    defer destroyMemory(talloc, mem);
    const storage = mem.shared_storage.?;
    const original_ptr = mem.bytes().ptr;
    var previous: [8]u64 = undefined;
    var threads: [8]std.Thread = undefined;

    const Grower = struct {
        fn run(memory: *MemoryInst, result: *u64) void {
            result.* = memoryGrowAddressed(memory, 1) orelse std.math.maxInt(u64);
        }
    };
    for (&threads, &previous) |*thread, *result|
        thread.* = try std.Thread.spawn(.{}, Grower.run, .{ mem, result });
    for (&threads) |*thread| thread.join();

    std.mem.sort(u64, &previous, {}, std.sort.asc(u64));
    for (previous, 1..) |observed, expected| try std.testing.expectEqual(@as(u64, expected), observed);
    try std.testing.expectEqual(@as(u32, 9), mem.pages());
    try std.testing.expectEqual(original_ptr, mem.bytes().ptr);
    try std.testing.expectEqual(@as(usize, 9 * types.PAGE_SIZE), storage.len());
    try std.testing.expectEqual(@as(?u64, 9), memoryGrowAddressed(mem, 0));
    try std.testing.expectEqual(@as(?u64, null), memoryGrowAddressed(mem, 1));
}

fn instantiateMemory64WithFailingAllocator(gpa: Allocator) !void {
    const bytes = comptime (hdr ++ table64Sec(2, 3) ++ mem64Sec(0, 1));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .memory64 = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(gpa, mod, .{}, &diag);
    defer destroyInstance(gpa, inst);
    try std.testing.expectEqual(types.AddressType.i64, inst.mems[0].address);
    try std.testing.expectEqual(types.AddressType.i64, inst.tables[0].address);
}

test "wasm.exec memory64 instantiation is rollback safe across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        talloc,
        instantiateMemory64WithFailingAllocator,
        .{},
    );
}

test "wasm.exec memory64 active offsets retain all address bits" {
    const bytes = comptime (hdr ++
        sec(5, "\x01\x04\x01") ++
        sec(11, "\x01\x00\x42\x80\x80\x80\x80\x10\x0B\x01A"));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .memory64 = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    try std.testing.expectError(error.Trap, instantiate(talloc, mod, .{}, &diag));
    try std.testing.expectEqualStrings("out of bounds memory index", diag.message());
}

test "wasm.exec memory64 scalar access size grow and overflow traps" {
    const bytes = comptime (hdr ++
        typesSec(&.{
            ft(I64 ++ I32, I32),
            ft("", I64),
            ft(I64, I64),
        }) ++
        funcSec(&.{ 0, 1, 2 }) ++ mem64Sec(1, 2) ++ codeSec(&.{
        "\x20\x00\x20\x01\x36\x02\x00\x20\x00\x28\x02\x00",
        "\x3F\x00",
        "\x20\x00\x40\x00",
    }));
    const features: types.Features = .{ .memory64 = true };
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    try std.testing.expectEqual(@as(u64, 0xA5A5_5A5A), try run1(inst, 0, &.{ 8, 0xA5A5_5A5A }));
    try std.testing.expectEqual(@as(u64, 1), try run1(inst, 1, &.{}));
    try runTrap(1, inst, 0, &.{ 0x1_0000_0000, 7 }, "out of bounds memory access");
    try runTrap(1, inst, 0, &.{ std.math.maxInt(u64), 7 }, "out of bounds memory access");

    try std.testing.expectEqual(@as(u64, 1), try run1(inst, 2, &.{1}));
    try std.testing.expectEqual(@as(u64, 2), try run1(inst, 1, &.{}));
    try std.testing.expectEqual(std.math.maxInt(u64), try run1(inst, 2, &.{1}));
    try std.testing.expectEqual(@as(u64, 2), try run1(inst, 1, &.{}));
}

test "wasm.exec memory64 table64 size grow and overflow traps" {
    const bytes = comptime (hdr ++
        typesSec(&.{ ft("", I64), ft(I64, I64), ft(I64, "\x70") }) ++
        funcSec(&.{ 0, 1, 2 }) ++ table64Sec(1, 2) ++ codeSec(&.{
        "\xFC\x10\x00",
        "\xD0\x70\x20\x00\xFC\x0F\x00",
        "\x20\x00\x25\x00",
    }));
    const features: types.Features = .{ .memory64 = true, .reference_types = true };
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    try std.testing.expectEqual(@as(u64, 1), try run1(inst, 0, &.{}));
    try std.testing.expectEqual(@as(u64, 1), try run1(inst, 1, &.{1}));
    try std.testing.expectEqual(@as(u64, 2), try run1(inst, 0, &.{}));
    try std.testing.expectEqual(std.math.maxInt(u64), try run1(inst, 1, &.{1}));
    try runTrap(1, inst, 2, &.{0x1_0000_0000}, "undefined element");
}

test "wasm.exec memory64 bulk initialization uses full-width destinations" {
    const bytes = comptime (hdr ++
        typesSec(&.{ft(I64, I32)}) ++ funcSec(&.{0}) ++ mem64Sec(1, null) ++
        sec(12, "\x01") ++ codeSec(&.{
        "\x20\x00\x41\x00\x41\x01\xFC\x08\x00\x00\x20\x00\x2D\x00\x00",
    }) ++ sec(11, "\x01\x01\x01A"));
    const features: types.Features = .{ .memory64 = true, .bulk_memory = true };
    try expectResultsWithFeatures(bytes, features, 0, &.{7}, &.{65});
    try expectTrapWithFeatures(bytes, features, 1, 0, &.{0x1_0000_0000}, "out of bounds memory access");
}

test "wasm.exec memory64 bulk fill copy are bounds atomic" {
    const bytes = comptime (hdr ++
        typesSec(&.{ ft(I64 ++ I64, I32), ft(I64 ++ I64 ++ I64, I32), ft(I64, I32) }) ++
        funcSec(&.{ 0, 1, 2 }) ++ mem64Sec(1, null) ++ codeSec(&.{
        "\x20\x00" ++ i32c(0x5A) ++ "\x20\x01\xFC\x0B\x00\x20\x00\x2D\x00\x00",
        "\x20\x00\x20\x01\x20\x02\xFC\x0A\x00\x00\x20\x00\x2D\x00\x00",
        "\x20\x00\x2D\x00\x00",
    }));
    const features: types.Features = .{ .memory64 = true, .bulk_memory = true };
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    try std.testing.expectEqual(@as(u64, 0x5A), try run1(inst, 0, &.{ 5, 3 }));
    try std.testing.expectEqual(@as(u64, 0x5A), try run1(inst, 1, &.{ 10, 5, 3 }));
    try runTrap(1, inst, 0, &.{ 0x1_0000_0000, 1 }, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(inst, 2, &.{0}));
}

test "wasm.exec memory64 indirect calls retain table64 indices" {
    const bytes = comptime (hdr ++
        typesSec(&.{ ft("", I32), ft(I64, I32) }) ++ funcSec(&.{ 0, 1 }) ++
        table64Sec(1, 1) ++ sec(9, "\x01\x00\x42\x00\x0B\x01\x00") ++ codeSec(&.{
        i32c(42),
        "\x20\x00\x11\x00\x00",
    }));
    const features: types.Features = .{ .memory64 = true };
    try expectResultsWithFeatures(bytes, features, 1, &.{0}, &.{42});
    try expectTrapWithFeatures(bytes, features, 1, 1, &.{0x1_0000_0000}, "undefined element");
}

test "wasm.exec memory64 SIMD and atomic accesses use i64 addresses" {
    const simd_bytes = comptime (hdr ++
        typesSec(&.{ft(I64, I32)}) ++ funcSec(&.{0}) ++ mem64Sec(1, null) ++ codeSec(&.{
        "\x20\x00\xFD\x00\x04\x00\xFD\x1B\x00",
    }));
    const simd_features: types.Features = .{ .memory64 = true, .fixed_width_simd = true };
    try expectResultsWithFeatures(simd_bytes, simd_features, 0, &.{0}, &.{0});
    try expectTrapWithFeatures(simd_bytes, simd_features, 1, 0, &.{0x1_0000_0000}, "out of bounds memory access");

    const atomic_bytes = comptime (hdr ++
        typesSec(&.{ft(I64, I32)}) ++ funcSec(&.{0}) ++
        sec(5, "\x01\x07\x01\x01") ++ codeSec(&.{
        "\x20\x00\xFE\x10\x02\x00",
    }));
    const atomic_features: types.Features = .{ .memory64 = true, .threads = true };
    try expectResultsWithFeatures(atomic_bytes, atomic_features, 0, &.{0}, &.{0});
    try expectTrapWithFeatures(atomic_bytes, atomic_features, 1, 0, &.{0x1_0000_0000}, "out of bounds memory access");
}

test "wasm.exec host constructors memory table global" {
    const mem = try createMemory(talloc, 1, 2);
    defer destroyMemory(talloc, mem);
    try std.testing.expectEqual(@as(usize, types.PAGE_SIZE), mem.bytes().len);
    try std.testing.expectEqual(@as(u8, 0), mem.bytes()[123]);
    try std.testing.expectEqual(@as(u32, 1), mem.pages());
    try std.testing.expectEqual(@as(i32, 1), memoryGrow(mem, 1));
    try std.testing.expectEqual(@as(usize, 2 * types.PAGE_SIZE), mem.bytes().len);
    try std.testing.expectEqual(@as(u8, 0), mem.bytes()[types.PAGE_SIZE + 5]);
    try std.testing.expectEqual(@as(i32, -1), memoryGrow(mem, 1)); // at max
    try std.testing.expectEqual(@as(i32, 2), memoryGrow(mem, 0));
    try std.testing.expectEqual(@as(i32, -1), memoryGrow(mem, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(usize, 2 * types.PAGE_SIZE), mem.bytes().len); // unchanged

    const tab = try createTable(talloc, 2, 3);
    defer destroyTable(talloc, tab);
    try std.testing.expectEqual(@as(usize, 2), tab.elems.len);
    try std.testing.expect(tab.elems[0] == .funcref and tab.elems[0].funcref == null);
    try std.testing.expectEqual(@as(i32, 2), tableGrow(tab, 1));
    try std.testing.expect(tab.elems[2] == .funcref and tab.elems[2].funcref == null);
    try std.testing.expectEqual(@as(i32, -1), tableGrow(tab, 1)); // at max
    try std.testing.expectEqual(@as(i32, 3), tableGrow(tab, 0));

    const g = try createGlobal(talloc, .{ .val = .i64, .mutable = true }, 0xDEADBEEF);
    defer destroyGlobal(talloc, g);
    try std.testing.expectEqual(types.GlobalType{ .val = .i64, .mutable = true }, g.type);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), g.value.numericBits());
    setGlobalValue(g, .{ .numeric = 7 });
    try std.testing.expectEqual(@as(u64, 7), g.value.numericBits());
}

test "wasm.exec shared memory grows in place with unique concurrent results" {
    const mem = try createMemoryTyped(talloc, 1, 9, true);
    defer destroyMemory(talloc, mem);
    const original_ptr = mem.bytes().ptr;
    mem.bytes()[17] = 0x6d;

    const Worker = struct {
        fn run(memory: *MemoryInst, result: *i32) void {
            result.* = memoryGrow(memory, 1);
        }
    };
    var results: [8]i32 = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &results) |*thread, *result|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ mem, result });
    for (&threads) |*thread| thread.join();

    std.mem.sort(i32, &results, {}, std.sort.asc(i32));
    for (results, 1..) |result, expected|
        try std.testing.expectEqual(@as(i32, @intCast(expected)), result);
    try std.testing.expectEqual(@as(u32, 9), mem.pages());
    try std.testing.expectEqual(original_ptr, mem.bytes().ptr);
    try std.testing.expectEqual(@as(u8, 0x6d), mem.bytes()[17]);
    try std.testing.expectEqual(@as(u8, 0), mem.bytes()[8 * types.PAGE_SIZE + 17]);
    try std.testing.expectEqual(@as(i32, -1), memoryGrow(mem, 1));
}

test "wasm.exec shared memory backing outlives its store owner" {
    const mem = try createMemoryTyped(talloc, 1, 2, true);
    const storage = mem.shared_storage.?;
    _ = storage.retain(); // independent realm/Worker-style hold
    try std.testing.expectEqual(@as(usize, 2), storage.retainCount());
    mem.bytes()[31] = 0xa5;
    destroyMemory(talloc, mem);
    try std.testing.expectEqual(@as(usize, 1), storage.retainCount());
    try std.testing.expectEqual(@as(u8, 0xa5), storage.fixedSlice(types.PAGE_SIZE)[31]);
    storage.release();
}

fn atomicTestInstr(op: wasm_atomic.Op) types.Instr {
    return .{
        .op = .atomic,
        .imm = if (op == .memory_atomic_fence)
            .{ .atomic = op }
        else
            .{ .atomic_memarg = .{
                .op = op,
                .memarg = .{ .align_ = op.naturalAlignment().?, .offset = 0 },
            } },
    };
}

test "wasm.exec executes every atomic load store RMW and cmpxchg opcode" {
    const mem = try createMemoryTyped(talloc, 1, 1, true);
    defer destroyMemory(talloc, mem);
    var inst: Instance = undefined;
    var memories = [_]*MemoryInst{mem};
    inst.mems = &memories;
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    var diag: types.Diagnostic = .{};
    var state: State = .{ .alloc = arena.allocator(), .diag = &diag };
    const initial: u64 = 0x0102030405060708;
    const operand: u64 = 0xf1e2d3c4b5a69788;

    for (std.enums.values(wasm_atomic.Op)) |op| {
        switch (op.shape()) {
            .notify, .wait32, .wait64, .fence => continue,
            else => {},
        }
        state.stack.clearRetainingCapacity();
        atomicStoreRaw(mem.bytes(), 0, 8, initial);
        const width = atomicByteWidth(op);
        const mask: u64 = if (width == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width * 8)) - 1;
        const old = initial & mask;
        try pushI32(&state, 0);
        switch (op.shape()) {
            .load_i32, .load_i64 => {
                try executeAtomic(&state, &inst, atomicTestInstr(op));
                try std.testing.expectEqual(old, pop(&state));
            },
            .store_i32, .store_i64 => {
                try push(&state, operand);
                try executeAtomic(&state, &inst, atomicTestInstr(op));
                try std.testing.expectEqual(operand & mask, atomicLoadRaw(mem.bytes(), 0, width));
            },
            .rmw_i32, .rmw_i64 => {
                try push(&state, operand);
                try executeAtomic(&state, &inst, atomicTestInstr(op));
                try std.testing.expectEqual(old, pop(&state));
                const group = (@intFromEnum(op) - 0x1e) / 7;
                const expected = switch (group) {
                    0 => (old +% operand) & mask,
                    1 => (old -% operand) & mask,
                    2 => old & operand & mask,
                    3 => (old | operand) & mask,
                    4 => (old ^ operand) & mask,
                    5 => operand & mask,
                    else => unreachable,
                };
                try std.testing.expectEqual(expected, atomicLoadRaw(mem.bytes(), 0, width));
            },
            .cmpxchg_i32, .cmpxchg_i64 => {
                try push(&state, old);
                try push(&state, operand);
                try executeAtomic(&state, &inst, atomicTestInstr(op));
                try std.testing.expectEqual(old, pop(&state));
                try std.testing.expectEqual(operand & mask, atomicLoadRaw(mem.bytes(), 0, width));
            },
            else => unreachable,
        }
    }

    state.stack.clearRetainingCapacity();
    try executeAtomic(&state, &inst, atomicTestInstr(.memory_atomic_fence));

    try pushI32(&state, 1);
    try std.testing.expectError(error.Trap, executeAtomic(&state, &inst, atomicTestInstr(.i32_atomic_load)));
    try std.testing.expectEqualStrings("unaligned atomic", state.diag.message());
}

test "wasm.exec ordinary shared memory accesses are host-race-free" {
    const mem = try createMemoryTyped(talloc, 1, 1, true);
    defer destroyMemory(talloc, mem);
    var start = std.atomic.Value(bool).init(false);

    const AtomicSide = struct {
        fn run(memory: *MemoryInst, ready: *std.atomic.Value(bool)) void {
            while (!ready.load(.acquire)) std.atomic.spinLoopHint();
            for (0..20_000) |i| {
                atomicStoreRaw(memory.bytes(), 0, 4, i);
                _ = atomicLoadRaw(memory.bytes(), 8, 4);
                atomicStoreRaw(memory.bytes(), 16, 8, i);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, AtomicSide.run, .{ mem, &start });
    start.store(true, .release);
    for (0..20_000) |i| {
        _ = mem.readUnordered(0, 4);
        mem.writeUnordered(8, 4, i);
        mem.writeSliceUnordered(16, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
        mem.fillUnordered(16, 8, @truncate(i));
        copyMemoryUnordered(mem, 17, mem, 16, 7);
    }
    thread.join();

    try std.testing.expect(mem.readUnordered(0, 4) < 20_000);
}

test "wasm.exec atomic wait and notify share the FIFO waiter table" {
    const mem = try createMemoryTyped(talloc, 1, 1, true);
    defer destroyMemory(talloc, mem);
    atomicStoreRaw(mem.bytes(), 0, 8, 0);

    const Waiter = struct {
        fn run(memory: *MemoryInst, result: *i32) void {
            var inst: Instance = undefined;
            var memories = [_]*MemoryInst{memory};
            inst.mems = &memories;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var diag: types.Diagnostic = .{};
            var state: State = .{ .alloc = arena.allocator(), .diag = &diag };
            pushI32(&state, 0) catch return;
            pushI32(&state, 0) catch return;
            pushI64(&state, std.time.ns_per_s) catch return;
            executeAtomic(&state, &inst, atomicTestInstr(.memory_atomic_wait32)) catch return;
            result.* = @bitCast(popI32(&state));
        }
    };
    var wait_result: i32 = -1;
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{ mem, &wait_result });

    var woke: u32 = 0;
    var attempts: usize = 0;
    while (woke == 0 and attempts < 100_000) : (attempts += 1) {
        var inst: Instance = undefined;
        var memories = [_]*MemoryInst{mem};
        inst.mems = &memories;
        var arena = std.heap.ArenaAllocator.init(talloc);
        defer arena.deinit();
        var diag: types.Diagnostic = .{};
        var state: State = .{ .alloc = arena.allocator(), .diag = &diag };
        try pushI32(&state, 0);
        try pushI32(&state, 1);
        try executeAtomic(&state, &inst, atomicTestInstr(.memory_atomic_notify));
        woke = popI32(&state);
        if (woke == 0) std.Thread.yield() catch {};
    }
    thread.join();
    try std.testing.expectEqual(@as(u32, 1), woke);
    try std.testing.expectEqual(@as(i32, 0), wait_result);

    var inst: Instance = undefined;
    var memories = [_]*MemoryInst{mem};
    inst.mems = &memories;
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    var diag: types.Diagnostic = .{};
    var state: State = .{ .alloc = arena.allocator(), .diag = &diag };
    try pushI32(&state, 0);
    try pushI64(&state, 1);
    try pushI64(&state, 0);
    try executeAtomic(&state, &inst, atomicTestInstr(.memory_atomic_wait64));
    try std.testing.expectEqual(@as(u32, 1), popI32(&state));

    const ordinary = try createMemory(talloc, 1, 1);
    defer destroyMemory(talloc, ordinary);
    memories[0] = ordinary;
    state.stack.clearRetainingCapacity();
    try pushI32(&state, 0);
    try pushI32(&state, 0);
    try pushI64(&state, 0);
    try std.testing.expectError(error.Trap, executeAtomic(&state, &inst, atomicTestInstr(.memory_atomic_wait32)));
    try std.testing.expectEqualStrings("expected shared memory", diag.message());
}

test "wasm.exec atomic waiter survives shared growth and store destruction" {
    const mem = try createMemoryTyped(talloc, 1, 2, true);
    const storage = mem.shared_storage.?.retain();
    defer storage.release();
    atomicStoreRaw(storage.slice(), 0, 4, 0);

    const Waiter = struct {
        fn run(shared: *SharedBufferStorage, result: *agent.WaitOutcome) void {
            result.* = agent.wait(shared, 0, i32, 0, 2 * std.time.ns_per_s);
        }
    };
    var outcome: agent.WaitOutcome = .timed_out;
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{ storage, &outcome });

    try std.testing.expectEqual(@as(i32, 1), memoryGrow(mem, 1));
    destroyMemory(talloc, mem); // the independent waiter-domain hold remains

    var woke: usize = 0;
    var attempts: usize = 0;
    while (woke == 0 and attempts < 100_000) : (attempts += 1) {
        woke = agent.notify(storage, 0, 1);
        if (woke == 0) std.Thread.yield() catch {};
    }
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), woke);
    try std.testing.expectEqual(agent.WaitOutcome.ok, outcome);
    try std.testing.expectEqual(@as(usize, 2 * types.PAGE_SIZE), storage.len());
}

// -- Instantiation: import resolution ----------------------------------------

const one_func_import = hdr ++ typesSec(&.{ft(I32, I32)}) ++ importSec(&.{impFunc("a", "f", 0)});

test "wasm.exec instantiate import count mismatch" {
    try expectLink(one_func_import, .{}, "inconsistent import count");
    var dummy: u8 = 0;
    const imf: ImportFunc = .{
        .ctx = @ptrCast(&dummy),
        .type = .{ .params = &.{.i32}, .results = &.{.i32} },
        .call = struct {
            fn f(ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
                _ = ctx;
                _ = args;
                _ = results;
                _ = diag;
            }
        }.f,
    };
    // Two provided for one declared is still an inconsistent count.
    try expectLink(one_func_import, .{ .funcs = &.{ imf, imf } }, "inconsistent import count");
}

test "wasm.exec instantiate incompatible table limits" {
    const mod_bytes = comptime (hdr ++ importSec(&.{impTable("a", "t", 2, null)}));
    const too_small = try createTable(talloc, 1, null);
    defer destroyTable(talloc, too_small);
    try expectLink(mod_bytes, .{ .tables = &.{too_small} }, "incompatible import type");
    const mod_max = comptime (hdr ++ importSec(&.{impTable("a", "t", 1, 2)}));
    const no_max = try createTable(talloc, 1, null);
    defer destroyTable(talloc, no_max);
    try expectLink(mod_max, .{ .tables = &.{no_max} }, "incompatible import type");
    const big_max = try createTable(talloc, 1, 3);
    defer destroyTable(talloc, big_max);
    try expectLink(mod_max, .{ .tables = &.{big_max} }, "incompatible import type");
}

test "wasm.exec instantiate incompatible memory limits" {
    const mod_min = comptime (hdr ++ importSec(&.{impMem("a", "m", 2, null)}));
    const too_small = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, too_small);
    try expectLink(mod_min, .{ .mems = &.{too_small} }, "incompatible import type");
    const mod_max = comptime (hdr ++ importSec(&.{impMem("a", "m", 1, 2)}));
    const no_max = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, no_max);
    try expectLink(mod_max, .{ .mems = &.{no_max} }, "incompatible import type");
    const big_max = try createMemory(talloc, 1, 3);
    defer destroyMemory(talloc, big_max);
    try expectLink(mod_max, .{ .mems = &.{big_max} }, "incompatible import type");
}

test "wasm.exec instantiate compatible larger imports succeed" {
    var diag: types.Diagnostic = .{};
    const mod_bytes = comptime (hdr ++ importSec(&.{ impTable("a", "t", 1, 3), impMem("a", "m", 1, 2) }));
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const tab = try createTable(talloc, 2, 3); // min 2 >= 1, max 3 <= 3
    defer destroyTable(talloc, tab);
    const mem = try createMemory(talloc, 2, 2); // min 2 >= 1, max 2 <= 2
    defer destroyMemory(talloc, mem);
    const inst = try instantiate(talloc, mod, .{ .tables = &.{tab}, .mems = &.{mem} }, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(tab, inst.tables[0]);
    try std.testing.expectEqual(mem, inst.mems[0]);
}

test "wasm.exec instantiate incompatible global type" {
    const mod_bytes = comptime (hdr ++ importSec(&.{impGlobal("a", "g", I32, false)}));
    const wrong_mut = try createGlobal(talloc, .{ .val = .i32, .mutable = true }, 0);
    defer destroyGlobal(talloc, wrong_mut);
    try expectLink(mod_bytes, .{ .globals = &.{wrong_mut} }, "incompatible import type");
    const wrong_val = try createGlobal(talloc, .{ .val = .i64, .mutable = false }, 0);
    defer destroyGlobal(talloc, wrong_val);
    try expectLink(mod_bytes, .{ .globals = &.{wrong_val} }, "incompatible import type");
}

var host_state: u32 = 0;

fn hostDouble(ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
    _ = ctx;
    _ = diag;
    results[0] = args[0] *% 2;
}

const double_import: ImportFunc = .{
    .ctx = @ptrCast(&host_state),
    .type = .{ .params = &.{.i32}, .results = &.{.i32} },
    .call = hostDouble,
};

// Kitchen sink: one import of each kind plus a defined func using them, an
// elem into the imported table, and a data segment into the imported memory.
const ks2_bytes = hdr ++
    typesSec(&.{ ft(I32, I32), ft(I32, I32) }) ++
    importSec(&.{ impFunc("a", "f", 0), impTable("a", "t", 1, null), impMem("a", "m", 1, null), impGlobal("a", "g", I32, false) }) ++
    funcSec(&.{1}) ++
    elemSec0(0, &.{1}) ++
    codeSec(&.{"\x20\x00\x10\x00\x23\x00\x6A"}) ++
    dataSec0(2, "Z");

test "wasm.exec instantiate resolves all import kinds" {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(ks2_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const tab = try createTable(talloc, 1, null);
    defer destroyTable(talloc, tab);
    const mem = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, mem);
    const glob_inst = try createGlobal(talloc, .{ .val = .i32, .mutable = false }, 100);
    defer destroyGlobal(talloc, glob_inst);
    const inst = try instantiate(talloc, mod, .{
        .funcs = &.{double_import},
        .tables = &.{tab},
        .mems = &.{mem},
        .globals = &.{glob_inst},
    }, &diag);
    defer destroyInstance(talloc, inst);

    // Index spaces: imports first.
    try std.testing.expectEqual(@as(usize, 2), inst.funcs.len);
    try std.testing.expect(inst.funcs[0].* == .imported);
    try std.testing.expect(inst.funcs[1].* == .defined);
    try std.testing.expectEqual(tab, inst.tables[0]);
    try std.testing.expectEqual(mem, inst.mems[0]);
    try std.testing.expectEqual(glob_inst, inst.globals[0]);

    // Defined func: double(param) + imported global.
    try std.testing.expectEqual(@as(u64, 110), try run1(inst, 1, &.{5}));

    // Elem wrote the defined func into the imported table.
    try std.testing.expect(tab.elems[0] == .funcref);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(inst.funcs[1])), tab.elems[0].funcref.?);

    // Data wrote into the imported memory.
    try std.testing.expectEqual(@as(u8, 'Z'), mem.bytes()[2]);

    // Imported FuncInst is directly callable through callFuncInst.
    var diag2: types.Diagnostic = .{};
    var res: [1]u64 = .{0};
    try callFuncInst(inst.funcs[0], &.{21}, &res, &diag2);
    try std.testing.expectEqual(@as(u64, 42), res[0]);
}

// -- Instantiation: globals, elems, datas, start ------------------------------

test "wasm.exec instantiate global initializers" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft("", I32), ft("", I64), ft("", F32), ft("", F64) }) ++
        funcSec(&.{ 0, 1, 2, 3 }) ++
        globalSec(&.{ glob(I32, true, i32c(42)), glob(I64, false, i64c(-7)), glob(F32, false, f32c(1.5)), glob(F64, true, f64c(-2.5)) }) ++
        codeSec(&.{ "\x23\x00", "\x23\x01", "\x23\x02", "\x23\x03" }));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(usize, 4), b.inst.globals.len);
    try std.testing.expectEqual(i32v(42), b.inst.globals[0].value.numericBits());
    try std.testing.expectEqual(i64v(-7), b.inst.globals[1].value.numericBits());
    try std.testing.expectEqual(f32v(1.5), b.inst.globals[2].value.numericBits());
    try std.testing.expectEqual(f64v(-2.5), b.inst.globals[3].value.numericBits());
    try std.testing.expectEqual(i32v(42), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(i64v(-7), try run1(b.inst, 1, &.{}));
    try std.testing.expectEqual(f32v(1.5), try run1(b.inst, 2, &.{}));
    try std.testing.expectEqual(f64v(-2.5), try run1(b.inst, 3, &.{}));
}

test "wasm.exec instantiate global init referencing imported global" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ft("", I32)}) ++
        importSec(&.{impGlobal("a", "g", I32, false)}) ++
        funcSec(&.{0}) ++
        globalSec(&.{glob(I32, false, "\x23\x00")}) ++
        codeSec(&.{"\x23\x01"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const imported = try createGlobal(talloc, .{ .val = .i32, .mutable = false }, 99);
    defer destroyGlobal(talloc, imported);
    const inst = try instantiate(talloc, mod, .{ .globals = &.{imported} }, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(@as(u64, 99), inst.globals[1].value.numericBits());
    try std.testing.expectEqual(@as(u64, 99), try run1(inst, 0, &.{}));
}

test "wasm.exec instantiate elem out of bounds is a trap" {
    const base = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++ tableSec(2, null));
    try expectInstantiationTrap(comptime (base ++ elemSec0(2, &.{0}) ++ codeSec(&.{""})), .{}, "out of bounds table index");
    try expectInstantiationTrap(comptime (base ++ elemSec0(1, &.{ 0, 0 }) ++ codeSec(&.{""})), .{}, "out of bounds table index");
}

test "wasm.exec instantiate data out of bounds is a trap" {
    const base = comptime (hdr ++ memSec(1, null));
    try expectInstantiationTrap(comptime (base ++ dataSec0(65535, "AB")), .{}, "out of bounds memory index");
    try expectInstantiationTrap(comptime (base ++ dataSec0(65536, "A")), .{}, "out of bounds memory index");
}

test "wasm.exec instantiate data at exact end succeeds" {
    const b = try build(hdr ++ memSec(1, null) ++ dataSec0(65535, "Q"));
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u8, 'Q'), b.inst.mems[0].bytes()[65535]);
    // An empty segment at the exact end is in bounds.
    const b2 = try build(hdr ++ memSec(1, null) ++ dataSec0(65536, ""));
    defer destroyBuilt(b2);
}

test "wasm.exec instantiation trap retains earlier active segments" {
    var diag: types.Diagnostic = .{};
    const memory_module = try buildModule(comptime (hdr ++
        importSec(&.{impMem("a", "m", 1, null)}) ++
        dataSec(&.{ dataEntry0(0, "abc"), dataEntry0(65536, "x") })), &diag);
    defer decode.destroyModule(talloc, memory_module);
    const memory = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, memory);
    try std.testing.expectError(error.Trap, instantiate(talloc, memory_module, .{ .mems = &.{memory} }, &diag));
    try std.testing.expectEqualStrings("abc", memory.bytes()[0..3]);

    diag = .{};
    const table_module = try buildModule(comptime (hdr ++
        typesSec(&.{ft("", "")}) ++
        importSec(&.{impTable("a", "t", 1, null)}) ++
        funcSec(&.{0}) ++
        elemSec(&.{ elemEntry0(0, &.{0}), elemEntry0(1, &.{0}) }) ++
        codeSec(&.{""})), &diag);
    defer decode.destroyModule(talloc, table_module);
    const table = try createTable(talloc, 1, null);
    defer destroyTable(talloc, table);
    try std.testing.expectError(error.Trap, instantiate(talloc, table_module, .{ .tables = &.{table} }, &diag));
    try std.testing.expect(table.elems[0] == .funcref and table.elems[0].funcref != null);
}

fn hostInc(ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
    _ = args;
    _ = results;
    _ = diag;
    const c: *u32 = @ptrCast(@alignCast(ctx));
    c.* += 1;
}

test "wasm.exec instantiate start function runs" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ft("", "")}) ++
        importSec(&.{impFunc("a", "f", 0)}) ++
        funcSec(&.{0}) ++
        startSec(1) ++
        codeSec(&.{"\x10\x00"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    var counter: u32 = 0;
    const inc_import: ImportFunc = .{
        .ctx = @ptrCast(&counter),
        .type = .{ .params = &.{}, .results = &.{} },
        .call = hostInc,
    };
    const inst = try instantiate(talloc, mod, .{ .funcs = &.{inc_import} }, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "wasm.exec instantiate start trap propagates" {
    const mod_bytes = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++ startSec(0) ++ codeSec(&.{"\x00"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    try std.testing.expectError(error.Trap, instantiate(talloc, mod, .{}, &diag));
    try std.testing.expectEqualStrings("unreachable", diag.message());
}

// -- invoke: value types and reentrancy ---------------------------------------

test "wasm.exec invoke passes all value types bit-exact" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, I32), ft(I64, I64), ft(F32, F32), ft(F64, F64) }) ++
        funcSec(&.{ 0, 1, 2, 3 }) ++
        codeSec(&.{ "\x20\x00", "\x20\x00", "\x20\x00", "\x20\x00" }));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), try run1(b.inst, 0, &.{0xDEADBEEF}));
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF_CAFEBABE), try run1(b.inst, 1, &.{0xDEADBEEF_CAFEBABE}));
    try std.testing.expectEqual(@as(u64, 0x7FC00001), try run1(b.inst, 2, &.{0x7FC00001})); // NaN payload preserved
    try std.testing.expectEqual(@as(u64, 0x80000000), try run1(b.inst, 2, &.{0x80000000})); // -0.0 f32
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), try run1(b.inst, 3, &.{0x8000000000000000})); // -0.0 f64
}

const ReentCtx = struct {
    inst_b: *Instance,
    funcidx_b: u32,
};

fn hostReenter(ctx_raw: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
    const ctx: *ReentCtx = @ptrCast(@alignCast(ctx_raw));
    var inner: types.Diagnostic = .{};
    invoke(ctx.inst_b, ctx.funcidx_b, args, results, &inner) catch |e| switch (e) {
        error.Trap => {
            diag.set(types.Diagnostic.no_offset, "{s}", .{inner.message()});
            return error.Trap;
        },
        error.OutOfMemory, error.Host, error.Exception => return error.Host,
    };
}

test "wasm.exec invoke reentrancy through host import" {
    // Module B: func 0 = x + 10.
    const b_bytes = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++ funcSec(&.{0}) ++ codeSec(&.{"\x20\x00" ++ i32c(10) ++ "\x6A"}));
    const b = try build(b_bytes);
    defer destroyBuilt(b);

    // Module A: import "a"."f"; func 1 = f(x) + 1, where f re-enters B.
    const a_bytes = comptime (hdr ++
        typesSec(&.{ft(I32, I32)}) ++
        importSec(&.{impFunc("a", "f", 0)}) ++
        funcSec(&.{0}) ++
        codeSec(&.{"\x20\x00\x10\x00" ++ i32c(1) ++ "\x6A"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(a_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    var ctx: ReentCtx = .{ .inst_b = b.inst, .funcidx_b = 0 };
    const reent: ImportFunc = .{
        .ctx = @ptrCast(&ctx),
        .type = .{ .params = &.{.i32}, .results = &.{.i32} },
        .call = hostReenter,
    };
    const inst_a = try instantiate(talloc, mod, .{ .funcs = &.{reent} }, &diag);
    defer destroyInstance(talloc, inst_a);
    try std.testing.expectEqual(@as(u64, 16), try run1(inst_a, 1, &.{5}));
}

// -- Control flow ---------------------------------------------------------------

test "wasm.exec control nested blocks br with value" {
    const body = comptime ("\x02\x7F" ++ // block $a (result i32)
        "\x02\x40" ++ //   block $b
        "\x02\x40" ++ //     block $c
        i32c(7) ++ "\x0C\x02" ++ // i32.const 7; br 2 ($a)
        "\x0B" ++ //   end $c
        "\x0B" ++ //   end $b
        i32c(9) ++ //   unreachable const
        "\x0B"); // end $a
    try expectResults(comptime arithModule("", I32, body), 0, &.{}, &.{7});
}

test "wasm.exec control loop sum 1 to 10" {
    const body = comptime (i32c(10) ++ "\x21\x01" ++ // i = 10 (local 1)
        "\x03\x40" ++ // loop
        "\x20\x00\x20\x01\x6A\x21\x00" ++ // sum += i
        "\x20\x01" ++ i32c(1) ++ "\x6B\x22\x01" ++ // i -= 1 (tee)
        "\x0D\x00" ++ // br_if loop
        "\x0B" ++ // end loop
        "\x20\x00"); // sum
    const bytes = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ codeSecL("\x01\x02\x7F", body));
    try expectResults(bytes, 0, &.{}, &.{55});
}

test "wasm.exec control if else both arms" {
    const body = comptime ("\x20\x00\x04\x7F" ++ i32c(1) ++ "\x05" ++ i32c(2) ++ "\x0B");
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{1}, &.{1});
    try expectResults(bytes, 0, &.{0}, &.{2});
}

test "wasm.exec control if without else" {
    // (param i32) (result i32): if (empty) nop end; i32.const 7
    const body = comptime ("\x20\x00\x04\x40\x01\x0B" ++ i32c(7));
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{1}, &.{7});
    try expectResults(bytes, 0, &.{0}, &.{7});
}

test "wasm.exec control br_table dispatch" {
    // Targets are empty-arity blocks; each landing pad pushes its own value
    // and branches to the result-valued outer block.
    const body = comptime ("\x02\x7F" ++ // block $a (result i32)
        "\x02\x40" ++ //   block $d
        "\x02\x40" ++ //     block $b
        "\x02\x40" ++ //       block $c
        "\x20\x00" ++ "\x0E\x02\x00\x01\x02" ++ // local.get 0; br_table 0 1, default 2
        "\x0B" ++ //       end $c
        i32c(10) ++ "\x0C\x02" ++ // case 0 -> 10 (br $a)
        "\x0B" ++ //     end $b
        i32c(20) ++ "\x0C\x01" ++ // case 1 -> 20 (br $a)
        "\x0B" ++ //   end $d
        i32c(30) ++ // default -> 30 (falls into end $a)
        "\x0B"); // end $a
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{0}, &.{10});
    try expectResults(bytes, 0, &.{1}, &.{20});
    try expectResults(bytes, 0, &.{2}, &.{30});
    try expectResults(bytes, 0, &.{99}, &.{30});
}

test "wasm.exec control return mid function" {
    const body = comptime (i32c(42) ++ "\x0F" ++ i32c(0));
    try expectResults(comptime arithModule("", I32, body), 0, &.{}, &.{42});
}

test "wasm.exec control br_if not taken" {
    const body = comptime ("\x02\x7F" ++ // block (result i32)
        i32c(5) ++ "\x20\x00\x0D\x00" ++ "\x1A" ++ // const 5; br_if 0 (cond); drop
        i32c(6) ++ "\x0B");
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{1}, &.{5});
    try expectResults(bytes, 0, &.{0}, &.{6});
}

// -- Parametric ------------------------------------------------------------------

test "wasm.exec parametric drop and select" {
    try expectResults(comptime arithModule("", I32, i32c(5) ++ i32c(6) ++ "\x1A"), 0, &.{}, &.{5});
    const sel = "\x20\x00\x20\x01\x20\x02\x1B";
    const bytes = comptime arithModule(I32 ++ I32 ++ I32, I32, sel);
    try expectResults(bytes, 0, &.{ 11, 22, 1 }, &.{11});
    try expectResults(bytes, 0, &.{ 11, 22, 0 }, &.{22});
}

test "wasm.exec unreachable traps" {
    try expectTrap(comptime arithModule("", "", "\x00"), 0, 0, &.{}, "unreachable");
}

// -- i32 numerics ----------------------------------------------------------------

test "wasm.exec i32 arithmetic binops" {
    try binop(.i32_add, I32, I32, 1, 2, 3);
    try binop(.i32_add, I32, I32, 0xFFFFFFFF, 1, 0);
    try binop(.i32_add, I32, I32, 0x7FFFFFFF, 1, 0x80000000);
    try binop(.i32_sub, I32, I32, 3, 5, i32v(-2));
    try binop(.i32_sub, I32, I32, 0, 1, 0xFFFFFFFF);
    try binop(.i32_mul, I32, I32, 7, 6, 42);
    try binop(.i32_mul, I32, I32, 0x10000, 0x10000, 0);
    try binop(.i32_and, I32, I32, 0xFF00FF00, 0x0FF00FF0, 0x0F000F00);
    try binop(.i32_or, I32, I32, 0xFF00FF00, 0x0FF00FF0, 0xFFF0FFF0);
    try binop(.i32_xor, I32, I32, 0xFF00FF00, 0x0FF00FF0, 0xF0F0F0F0);
}

test "wasm.exec i32 div and rem" {
    try binop(.i32_div_s, I32, I32, 7, 2, 3);
    try binop(.i32_div_s, I32, I32, i32v(-7), 2, i32v(-3));
    try binop(.i32_div_s, I32, I32, 7, i32v(-2), i32v(-3));
    try binop(.i32_div_s, I32, I32, i32v(-7), i32v(-2), 3);
    try binop(.i32_div_s, I32, I32, i32v(std.math.minInt(i32)), 1, i32v(std.math.minInt(i32)));
    try binop(.i32_div_u, I32, I32, 7, 2, 3);
    try binop(.i32_div_u, I32, I32, 0xFFFFFFFF, 2, 0x7FFFFFFF);
    try binop(.i32_rem_s, I32, I32, 7, 2, 1);
    try binop(.i32_rem_s, I32, I32, i32v(-7), 2, i32v(-1)); // sign follows dividend
    try binop(.i32_rem_s, I32, I32, 7, i32v(-2), 1);
    try binop(.i32_rem_s, I32, I32, i32v(-7), i32v(-2), i32v(-1));
    try binop(.i32_rem_s, I32, I32, i32v(std.math.minInt(i32)), i32v(-1), 0); // no trap
    try binop(.i32_rem_u, I32, I32, 7, 2, 1);
    try binop(.i32_rem_u, I32, I32, 0xFFFFFFFF, 2, 1);
}

test "wasm.exec i32 div and rem traps" {
    try binopTrap(.i32_div_s, I32, I32, 1, 0, "integer divide by zero");
    try binopTrap(.i32_div_s, I32, I32, i32v(std.math.minInt(i32)), i32v(-1), "integer overflow");
    try binopTrap(.i32_div_u, I32, I32, 1, 0, "integer divide by zero");
    try binopTrap(.i32_rem_s, I32, I32, 5, 0, "integer divide by zero");
    try binopTrap(.i32_rem_u, I32, I32, 5, 0, "integer divide by zero");
}

test "wasm.exec i32 shifts and rotates" {
    try binop(.i32_shl, I32, I32, 1, 31, 0x80000000);
    try binop(.i32_shl, I32, I32, 1, 33, 2); // count masked mod 32
    try binop(.i32_shl, I32, I32, 0xFFFFFFFF, 37, 0xFFFFFFE0);
    try binop(.i32_shr_s, I32, I32, 0x80000000, 31, 0xFFFFFFFF);
    try binop(.i32_shr_s, I32, I32, 0x80000000, 33, 0xC0000000);
    try binop(.i32_shr_u, I32, I32, 0x80000000, 31, 1);
    try binop(.i32_shr_u, I32, I32, 0x80000000, 33, 0x40000000);
    try binop(.i32_rotl, I32, I32, 0x12345678, 8, 0x34567812);
    try binop(.i32_rotl, I32, I32, 0x12345678, 40, 0x34567812);
    try binop(.i32_rotr, I32, I32, 0x12345678, 8, 0x78123456);
    try binop(.i32_rotr, I32, I32, 0x12345678, 40, 0x78123456);
}

test "wasm.exec i32 clz ctz popcnt" {
    try unop(.i32_clz, I32, I32, 0, 32);
    try unop(.i32_clz, I32, I32, 1, 31);
    try unop(.i32_clz, I32, I32, 0x80000000, 0);
    try unop(.i32_clz, I32, I32, 0x00F00000, 8);
    try unop(.i32_ctz, I32, I32, 0, 32);
    try unop(.i32_ctz, I32, I32, 0x80000000, 31);
    try unop(.i32_ctz, I32, I32, 1, 0);
    try unop(.i32_ctz, I32, I32, 0x00F00000, 20);
    try unop(.i32_popcnt, I32, I32, 0, 0);
    try unop(.i32_popcnt, I32, I32, 0xFFFFFFFF, 32);
    try unop(.i32_popcnt, I32, I32, 0x55555555, 16);
}

test "wasm.exec i32 comparisons" {
    try unop(.i32_eqz, I32, I32, 0, 1);
    try unop(.i32_eqz, I32, I32, 42, 0);
    try binop(.i32_eq, I32, I32, 5, 5, 1);
    try binop(.i32_eq, I32, I32, 5, 6, 0);
    try binop(.i32_ne, I32, I32, 5, 6, 1);
    try binop(.i32_lt_s, I32, I32, i32v(-1), 1, 1);
    try binop(.i32_lt_s, I32, I32, 1, i32v(-1), 0);
    try binop(.i32_lt_u, I32, I32, 0xFFFFFFFF, 1, 0);
    try binop(.i32_lt_u, I32, I32, 1, 2, 1);
    try binop(.i32_gt_s, I32, I32, 1, i32v(-1), 1);
    try binop(.i32_gt_u, I32, I32, 0xFFFFFFFF, 1, 1);
    try binop(.i32_le_s, I32, I32, i32v(-1), i32v(-1), 1);
    try binop(.i32_le_u, I32, I32, 1, 1, 1);
    try binop(.i32_ge_s, I32, I32, 0, i32v(-1), 1);
    try binop(.i32_ge_u, I32, I32, 1, 0, 1);
}

// -- i64 numerics ----------------------------------------------------------------

test "wasm.exec i64 arithmetic binops" {
    try binop(.i64_add, I64, I64, 1, 2, 3);
    try binop(.i64_add, I64, I64, 0xFFFFFFFFFFFFFFFF, 1, 0);
    try binop(.i64_sub, I64, I64, 0, 1, 0xFFFFFFFFFFFFFFFF);
    try binop(.i64_mul, I64, I64, 0x100000000, 0x100000000, 0);
    try binop(.i64_and, I64, I64, 0xFF00FF00FF00FF00, 0x0FF00FF00FF00FF0, 0x0F000F000F000F00);
    try binop(.i64_or, I64, I64, 0xFF00FF00FF00FF00, 0x0FF00FF00FF00FF0, 0xFFF0FFF0FFF0FFF0);
    try binop(.i64_xor, I64, I64, 0xFF00FF00FF00FF00, 0x0FF00FF00FF00FF0, 0xF0F0F0F0F0F0F0F0);
}

test "wasm.exec i64 div and rem" {
    try binop(.i64_div_s, I64, I64, i64v(-7), 2, i64v(-3));
    try binop(.i64_div_s, I64, I64, 7, i64v(-2), i64v(-3));
    try binop(.i64_div_s, I64, I64, i64v(-7), i64v(-2), 3);
    try binop(.i64_div_u, I64, I64, 0xFFFFFFFFFFFFFFFF, 2, 0x7FFFFFFFFFFFFFFF);
    try binop(.i64_rem_s, I64, I64, i64v(-7), 2, i64v(-1));
    try binop(.i64_rem_s, I64, I64, 7, i64v(-2), 1);
    try binop(.i64_rem_s, I64, I64, i64v(std.math.minInt(i64)), i64v(-1), 0); // no trap
    try binop(.i64_rem_u, I64, I64, 7, 2, 1);
}

test "wasm.exec i64 div and rem traps" {
    try binopTrap(.i64_div_s, I64, I64, 1, 0, "integer divide by zero");
    try binopTrap(.i64_div_s, I64, I64, i64v(std.math.minInt(i64)), i64v(-1), "integer overflow");
    try binopTrap(.i64_div_u, I64, I64, 1, 0, "integer divide by zero");
    try binopTrap(.i64_rem_s, I64, I64, 5, 0, "integer divide by zero");
    try binopTrap(.i64_rem_u, I64, I64, 5, 0, "integer divide by zero");
}

test "wasm.exec i64 shifts and rotates" {
    try binop(.i64_shl, I64, I64, 1, 63, 0x8000000000000000);
    try binop(.i64_shl, I64, I64, 1, 65, 2); // count masked mod 64
    try binop(.i64_shr_s, I64, I64, 0x8000000000000000, 63, 0xFFFFFFFFFFFFFFFF);
    try binop(.i64_shr_s, I64, I64, 0x8000000000000000, 65, 0xC000000000000000);
    try binop(.i64_shr_u, I64, I64, 0x8000000000000000, 63, 1);
    try binop(.i64_shr_u, I64, I64, 0x8000000000000000, 65, 0x4000000000000000);
    try binop(.i64_rotl, I64, I64, 0x123456789ABCDEF0, 16, 0x56789ABCDEF01234);
    try binop(.i64_rotl, I64, I64, 0x123456789ABCDEF0, 80, 0x56789ABCDEF01234);
    try binop(.i64_rotr, I64, I64, 0x123456789ABCDEF0, 16, 0xDEF0123456789ABC);
}

test "wasm.exec i64 clz ctz popcnt" {
    try unop(.i64_clz, I64, I64, 0, 64);
    try unop(.i64_clz, I64, I64, 1, 63);
    try unop(.i64_clz, I64, I64, 0x8000000000000000, 0);
    try unop(.i64_ctz, I64, I64, 0, 64);
    try unop(.i64_ctz, I64, I64, 0x8000000000000000, 63);
    try unop(.i64_popcnt, I64, I64, 0, 0);
    try unop(.i64_popcnt, I64, I64, 0xFFFFFFFFFFFFFFFF, 64);
    try unop(.i64_popcnt, I64, I64, 0x5555555555555555, 32);
}

test "wasm.exec i64 comparisons" {
    try unop(.i64_eqz, I64, I32, 0, 1);
    try unop(.i64_eqz, I64, I32, 7, 0);
    try binop(.i64_eq, I64, I32, 5, 5, 1);
    try binop(.i64_ne, I64, I32, 5, 6, 1);
    try binop(.i64_lt_s, I64, I32, i64v(-1), 1, 1);
    try binop(.i64_lt_u, I64, I32, 0xFFFFFFFFFFFFFFFF, 1, 0);
    try binop(.i64_gt_s, I64, I32, 1, i64v(-1), 1);
    try binop(.i64_gt_u, I64, I32, 0xFFFFFFFFFFFFFFFF, 1, 1);
    try binop(.i64_le_s, I64, I32, i64v(-1), i64v(-1), 1);
    try binop(.i64_le_u, I64, I32, 1, 1, 1);
    try binop(.i64_ge_s, I64, I32, 0, i64v(-1), 1);
    try binop(.i64_ge_u, I64, I32, 1, 0, 1);
}

// -- f32 numerics ----------------------------------------------------------------

test "wasm.exec f32 arithmetic" {
    try binop(.f32_add, F32, F32, f32v(1.5), f32v(2.25), f32v(3.75));
    try binop(.f32_add, F32, F32, f32v(0.1), f32v(0.2), f32v(@as(f32, 0.1) + @as(f32, 0.2)));
    try binop(.f32_sub, F32, F32, f32v(5.5), f32v(2.0), f32v(3.5));
    try binop(.f32_mul, F32, F32, f32v(1.5), f32v(4.0), f32v(6.0));
    try binop(.f32_div, F32, F32, f32v(7.0), f32v(2.0), f32v(3.5));
    try unop(.f32_abs, F32, F32, f32v(-1.5), f32v(1.5));
    try unop(.f32_abs, F32, F32, 0x80000000, 0); // abs(-0.0) = +0.0
    try unop(.f32_neg, F32, F32, f32v(1.5), f32v(-1.5));
    try unop(.f32_neg, F32, F32, 0, 0x80000000); // neg(+0.0) = -0.0
    try binop(.f32_copysign, F32, F32, f32v(1.5), f32v(-2.0), f32v(-1.5));
    try binop(.f32_copysign, F32, F32, f32v(1.5), 0x80000000, f32v(-1.5));
    try binop(.f32_copysign, F32, F32, f32v(-1.5), 0, f32v(1.5));
    try unop(.f32_sqrt, F32, F32, f32v(4.0), f32v(2.0));
    try unop(.f32_sqrt, F32, F32, f32v(2.0), f32v(@sqrt(@as(f32, 2.0))));
    try std.testing.expect(std.math.isNan(bitsToF32(try runUnop(.f32_sqrt, F32, F32, f32v(-1.0)))));
}

test "wasm.exec f32 ceil floor trunc" {
    try unop(.f32_ceil, F32, F32, f32v(1.5), f32v(2.0));
    try unop(.f32_ceil, F32, F32, f32v(-1.5), f32v(-1.0));
    try unop(.f32_ceil, F32, F32, f32v(1.0), f32v(1.0));
    try unop(.f32_floor, F32, F32, f32v(1.5), f32v(1.0));
    try unop(.f32_floor, F32, F32, f32v(-1.5), f32v(-2.0));
    try unop(.f32_trunc, F32, F32, f32v(1.5), f32v(1.0));
    try unop(.f32_trunc, F32, F32, f32v(-1.5), f32v(-1.0));
}

test "wasm.exec f32 nearest ties to even" {
    try unop(.f32_nearest, F32, F32, f32v(0.5), f32v(0.0));
    try unop(.f32_nearest, F32, F32, f32v(1.5), f32v(2.0));
    try unop(.f32_nearest, F32, F32, f32v(2.5), f32v(2.0));
    try unop(.f32_nearest, F32, F32, f32v(-2.5), f32v(-2.0));
    try unop(.f32_nearest, F32, F32, f32v(-0.5), 0x80000000); // -0.0
    try unop(.f32_nearest, F32, F32, f32v(3.5), f32v(4.0));
    try unop(.f32_nearest, F32, F32, f32v(8388607.5), f32v(8388608.0)); // largest non-integral f32
    try unop(.f32_nearest, F32, F32, f32v(-8388607.5), f32v(-8388608.0));
    try unop(.f32_nearest, F32, F32, f32v(16777216.0), f32v(16777216.0));
}

test "wasm.exec f32 min max nan and signed zero" {
    try binop(.f32_min, F32, F32, f32v(1.5), f32v(2.5), f32v(1.5));
    try binop(.f32_min, F32, F32, f32v(2.5), f32v(1.5), f32v(1.5));
    try binop(.f32_max, F32, F32, f32v(1.5), f32v(2.5), f32v(2.5));
    try binop(.f32_min, F32, F32, 0x80000000, 0, 0x80000000); // min(-0,+0) = -0
    try binop(.f32_min, F32, F32, 0, 0x80000000, 0x80000000);
    try binop(.f32_max, F32, F32, 0x80000000, 0, 0); // max(-0,+0) = +0
    try binop(.f32_max, F32, F32, 0, 0x80000000, 0);
    try std.testing.expect(std.math.isNan(bitsToF32(try runBinop(.f32_min, F32, F32, f32nan, f32v(1.0)))));
    try std.testing.expect(std.math.isNan(bitsToF32(try runBinop(.f32_min, F32, F32, f32v(1.0), f32nan))));
    try std.testing.expect(std.math.isNan(bitsToF32(try runBinop(.f32_max, F32, F32, f32nan, f32nan))));
}

test "wasm.exec f32 comparisons" {
    try binop(.f32_eq, F32, I32, f32v(1.5), f32v(1.5), 1);
    try binop(.f32_eq, F32, I32, f32nan, f32v(1.0), 0);
    try binop(.f32_eq, F32, I32, f32nan, f32nan, 0);
    try binop(.f32_eq, F32, I32, 0x80000000, 0, 1); // -0.0 == +0.0
    try binop(.f32_ne, F32, I32, f32nan, f32v(1.0), 1);
    try binop(.f32_ne, F32, I32, f32v(1.0), f32v(1.0), 0);
    try binop(.f32_lt, F32, I32, f32v(1.0), f32v(1.5), 1);
    try binop(.f32_lt, F32, I32, f32nan, f32v(1.0), 0);
    try binop(.f32_gt, F32, I32, f32v(1.5), f32v(1.0), 1);
    try binop(.f32_gt, F32, I32, f32v(1.0), f32nan, 0);
    try binop(.f32_le, F32, I32, f32v(1.5), f32v(1.5), 1);
    try binop(.f32_ge, F32, I32, f32v(1.5), f32v(1.5), 1);
    try binop(.f32_ge, F32, I32, f32v(1.0), f32v(1.5), 0);
}

// -- f64 numerics ----------------------------------------------------------------

test "wasm.exec f64 arithmetic" {
    try binop(.f64_add, F64, F64, f64v(1.5), f64v(2.25), f64v(3.75));
    try binop(.f64_add, F64, F64, f64v(0.1), f64v(0.2), f64v(@as(f64, 0.1) + @as(f64, 0.2)));
    try binop(.f64_sub, F64, F64, f64v(5.5), f64v(2.0), f64v(3.5));
    try binop(.f64_mul, F64, F64, f64v(1.5), f64v(4.0), f64v(6.0));
    try binop(.f64_div, F64, F64, f64v(7.0), f64v(2.0), f64v(3.5));
    try unop(.f64_abs, F64, F64, f64v(-1.5), f64v(1.5));
    try unop(.f64_abs, F64, F64, 0x8000000000000000, 0);
    try unop(.f64_neg, F64, F64, f64v(1.5), f64v(-1.5));
    try unop(.f64_neg, F64, F64, 0, 0x8000000000000000);
    try binop(.f64_copysign, F64, F64, f64v(1.5), f64v(-2.0), f64v(-1.5));
    try binop(.f64_copysign, F64, F64, f64v(1.5), 0x8000000000000000, f64v(-1.5));
    try unop(.f64_sqrt, F64, F64, f64v(4.0), f64v(2.0));
    try unop(.f64_sqrt, F64, F64, f64v(2.0), f64v(@sqrt(2.0)));
    try std.testing.expect(std.math.isNan(bitsToF64(try runUnop(.f64_sqrt, F64, F64, f64v(-1.0)))));
}

test "wasm.exec f64 ceil floor trunc" {
    try unop(.f64_ceil, F64, F64, f64v(1.5), f64v(2.0));
    try unop(.f64_ceil, F64, F64, f64v(-1.5), f64v(-1.0));
    try unop(.f64_floor, F64, F64, f64v(1.5), f64v(1.0));
    try unop(.f64_floor, F64, F64, f64v(-1.5), f64v(-2.0));
    try unop(.f64_trunc, F64, F64, f64v(1.5), f64v(1.0));
    try unop(.f64_trunc, F64, F64, f64v(-1.5), f64v(-1.0));
}

test "wasm.exec f64 nearest ties to even" {
    try unop(.f64_nearest, F64, F64, f64v(0.5), f64v(0.0));
    try unop(.f64_nearest, F64, F64, f64v(1.5), f64v(2.0));
    try unop(.f64_nearest, F64, F64, f64v(2.5), f64v(2.0));
    try unop(.f64_nearest, F64, F64, f64v(-2.5), f64v(-2.0));
    try unop(.f64_nearest, F64, F64, f64v(-0.5), 0x8000000000000000); // -0.0
    try unop(.f64_nearest, F64, F64, f64v(3.5), f64v(4.0));
    try unop(.f64_nearest, F64, F64, f64v(8388609.5), f64v(8388610.0));
    try unop(.f64_nearest, F64, F64, f64v(4503599627370495.5), f64v(4503599627370496.0)); // tie below 2^52
    try unop(.f64_nearest, F64, F64, f64v(9007199254740992.0), f64v(9007199254740992.0));
}

test "wasm.exec f64 min max nan and signed zero" {
    try binop(.f64_min, F64, F64, f64v(1.5), f64v(2.5), f64v(1.5));
    try binop(.f64_max, F64, F64, f64v(1.5), f64v(2.5), f64v(2.5));
    try binop(.f64_min, F64, F64, 0x8000000000000000, 0, 0x8000000000000000); // min(-0,+0) = -0
    try binop(.f64_max, F64, F64, 0x8000000000000000, 0, 0); // max(-0,+0) = +0
    try std.testing.expect(std.math.isNan(bitsToF64(try runBinop(.f64_min, F64, F64, f64nan, f64v(1.0)))));
    try std.testing.expect(std.math.isNan(bitsToF64(try runBinop(.f64_max, F64, F64, f64v(1.0), f64nan))));
}

test "wasm.exec f64 comparisons" {
    try binop(.f64_eq, F64, I32, f64v(1.5), f64v(1.5), 1);
    try binop(.f64_eq, F64, I32, f64nan, f64nan, 0);
    try binop(.f64_eq, F64, I32, 0x8000000000000000, 0, 1);
    try binop(.f64_ne, F64, I32, f64nan, f64v(1.0), 1);
    try binop(.f64_lt, F64, I32, f64v(1.0), f64v(1.5), 1);
    try binop(.f64_lt, F64, I32, f64v(1.0), f64nan, 0);
    try binop(.f64_gt, F64, I32, f64v(1.5), f64v(1.0), 1);
    try binop(.f64_le, F64, I32, f64v(1.5), f64v(1.5), 1);
    try binop(.f64_ge, F64, I32, f64v(1.0), f64v(1.5), 0);
}

// -- Conversions -----------------------------------------------------------------

test "wasm.exec conversions wrap and extend" {
    try unop(.i32_wrap_i64, I64, I32, 0x1_0000_0005, 5);
    try unop(.i32_wrap_i64, I64, I32, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF);
    try unop(.i64_extend_i32_s, I32, I64, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF);
    try unop(.i64_extend_i32_s, I32, I64, 0x7FFFFFFF, 0x7FFFFFFF);
    try unop(.i64_extend_i32_u, I32, I64, 0xFFFFFFFF, 0xFFFFFFFF);
    try unop(.i64_extend_i32_u, I32, I64, 0x80000000, 0x80000000);
}

test "wasm.exec sign-extension operations" {
    const features: types.Features = .{ .sign_extension_ops = true };
    try unopWithFeatures(.i32_extend8_s, I32, I32, features, 0x00000080, 0xFFFFFF80);
    try unopWithFeatures(.i32_extend8_s, I32, I32, features, 0xFFFFFF7F, 0x0000007F);
    try unopWithFeatures(.i32_extend16_s, I32, I32, features, 0x00008000, 0xFFFF8000);
    try unopWithFeatures(.i32_extend16_s, I32, I32, features, 0xFFFF7FFF, 0x00007FFF);
    try unopWithFeatures(.i64_extend8_s, I64, I64, features, 0x80, 0xFFFFFFFFFFFFFF80);
    try unopWithFeatures(.i64_extend16_s, I64, I64, features, 0x8000, 0xFFFFFFFFFFFF8000);
    try unopWithFeatures(.i64_extend32_s, I64, I64, features, 0x80000000, 0xFFFFFFFF80000000);
    try unopWithFeatures(.i64_extend32_s, I64, I64, features, 0xFFFFFFFF7FFFFFFF, 0x000000007FFFFFFF);
}

test "wasm.exec nontrapping float-to-integer conversions" {
    const features: types.Features = .{ .nontrapping_float_to_int = true };

    try unopWithFeatures(.i32_trunc_sat_f32_s, F32, I32, features, f32nan, 0);
    try unopWithFeatures(.i32_trunc_sat_f32_s, F32, I32, features, f32v(-1.9), i32v(-1));
    try unopWithFeatures(.i32_trunc_sat_f32_s, F32, I32, features, f32v(-std.math.inf(f32)), i32v(std.math.minInt(i32)));
    try unopWithFeatures(.i32_trunc_sat_f32_u, F32, I32, features, f32v(std.math.inf(f32)), std.math.maxInt(u32));

    try unopWithFeatures(.i32_trunc_sat_f64_s, F64, I32, features, f64v(-2147483648.9), i32v(std.math.minInt(i32)));
    try unopWithFeatures(.i32_trunc_sat_f64_s, F64, I32, features, f64v(2147483648.0), std.math.maxInt(i32));
    try unopWithFeatures(.i32_trunc_sat_f64_u, F64, I32, features, f64v(-0.9), 0);
    try unopWithFeatures(.i32_trunc_sat_f64_u, F64, I32, features, f64v(4294967296.0), std.math.maxInt(u32));

    try unopWithFeatures(.i64_trunc_sat_f32_s, F32, I64, features, f32v(-std.math.inf(f32)), i64v(std.math.minInt(i64)));
    try unopWithFeatures(.i64_trunc_sat_f32_u, F32, I64, features, f32v(std.math.inf(f32)), std.math.maxInt(u64));
    try unopWithFeatures(.i64_trunc_sat_f64_s, F64, I64, features, f64nan, 0);
    try unopWithFeatures(.i64_trunc_sat_f64_s, F64, I64, features, f64v(0x1p63), i64v(std.math.maxInt(i64)));
    try unopWithFeatures(.i64_trunc_sat_f64_u, F64, I64, features, f64v(-1.0), 0);
    try unopWithFeatures(.i64_trunc_sat_f64_u, F64, I64, features, f64v(0x1p64), std.math.maxInt(u64));
}

test "wasm.exec multi-value type-index block" {
    const bytes = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x0B");
    try expectResultsWithFeatures(bytes, .{ .multi_value = true }, 0, &.{}, &.{ 7, 9 });
}

test "wasm.exec multi-value loop carries parameters" {
    const body = "\x20\x00\x03\x00\x21\x00\x20\x00\x41\x01\x6B\x22\x00\x20\x00\x0D\x00\x0B";
    const bytes = comptime arithModule(I32, I32, body);
    try expectResultsWithFeatures(bytes, .{ .multi_value = true }, 0, &.{3}, &.{0});
}

test "wasm.exec multi-value branches calls and implicit else" {
    const features: types.Features = .{ .multi_value = true };

    const branch = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x0C\x00\x00\x0B");
    try expectResultsWithFeatures(branch, features, 0, &.{}, &.{ 7, 9 });

    const branch_if = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x41\x01\x0D\x00\x0B");
    try expectResultsWithFeatures(branch_if, features, 0, &.{}, &.{ 7, 9 });

    const branch_table = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x41\x00\x0E\x01\x00\x00\x0B");
    try expectResultsWithFeatures(branch_table, features, 0, &.{}, &.{ 7, 9 });

    const implicit_else = comptime arithModule(I32, I32, "\x20\x00\x20\x00\x04\x00\x0B");
    try expectResultsWithFeatures(implicit_else, features, 0, &.{5}, &.{5});
    try expectResultsWithFeatures(implicit_else, features, 0, &.{0}, &.{0});

    const call = comptime (hdr ++ typesSec(&.{ft("", I32 ++ I64)}) ++ funcSec(&.{ 0, 0 }) ++
        codeSec(&.{ "\x41\x07\x42\x09", "\x10\x00" }));
    try expectResultsWithFeatures(call, features, 1, &.{}, &.{ 7, 9 });

    const return_ = comptime arithModule("", I32 ++ I64, "\x41\x07\x42\x09\x0F\x00");
    try expectResultsWithFeatures(return_, features, 0, &.{}, &.{ 7, 9 });
}

test "wasm.exec tail calls keep deep mutual recursion storage bounded" {
    const depth: u32 = 200_000;
    const even =
        "\x20\x00\x45\x04\x7F\x41\x01\x05" ++
        "\x20\x00\x41\x01\x6B\x12\x01\x0B";
    const odd =
        "\x20\x00\x45\x04\x7F\x41\x00\x05" ++
        "\x20\x00\x41\x01\x6B\x12\x00\x0B";
    const bytes = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        funcSec(&.{ 0, 0 }) ++ codeSec(&.{ even, odd }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .tail_calls = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    var probe: TailRootProbe = .{ .checkpoint_limit = depth + 1 };
    var state: State = .{
        .alloc = arena.allocator(),
        .diag = &diag,
        .root_hooks = probe.hooks(),
    };
    try state.root_hooks.?.enter(state.root_hooks.?.ctx, &state.roots);
    defer state.root_hooks.?.leave(state.root_hooks.?.ctx, &state.roots);
    var results: [1]ValueSlot = undefined;
    try execute(&state, inst.funcs[0], &.{.{ .numeric = depth }}, &results);

    try std.testing.expectEqual(@as(u64, 1), results[0].numericBits());
    try std.testing.expectEqual(@as(usize, depth), probe.checkpoints);
    try std.testing.expect(state.frames.capacity <= 64);
    try std.testing.expect(state.labels.capacity <= 64);
    try std.testing.expect(state.locals.capacity <= 64);
    try std.testing.expect(state.stack.capacity <= 64);
    try std.testing.expectEqual(@as(usize, 0), state.frames.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.labels.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.locals.items.len);
}

test "wasm.exec exception tag imports preserve identity and reject mismatched types" {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const provider_bytes = comptime (hdr ++ typesSec(&.{ft(I32, "")}) ++
        sec(13, "\x01\x00\x00"));
    var diag: types.Diagnostic = .{};
    const provider_mod = try buildModuleWithFeatures(provider_bytes, features, &diag);
    defer decode.destroyModule(talloc, provider_mod);
    const provider = try instantiate(talloc, provider_mod, .{}, &diag);
    defer destroyInstance(talloc, provider);

    const consumer_bytes = comptime (hdr ++ typesSec(&.{ft(I32, "")}) ++
        sec(2, "\x01\x01m\x01t\x04\x00\x00") ++
        sec(13, "\x01\x00\x00"));
    const consumer_mod = try buildModuleWithFeatures(consumer_bytes, features, &diag);
    defer decode.destroyModule(talloc, consumer_mod);
    const consumer = try instantiate(talloc, consumer_mod, .{ .tags = &.{provider.tags[0]} }, &diag);
    defer destroyInstance(talloc, consumer);

    try std.testing.expectEqual(@as(usize, 2), consumer.tags.len);
    try std.testing.expect(consumer.tags[0] == provider.tags[0]);
    try std.testing.expect(consumer.tags[1] != provider.tags[0]);
    try std.testing.expect(types.funcTypeEql(consumer.tags[0].type, consumer.tags[1].type));

    const wrong = try createTag(talloc, .{ .params = &.{.i64}, .results = &.{} });
    defer destroyTag(talloc, wrong);
    try std.testing.expectError(
        error.Link,
        instantiate(talloc, consumer_mod, .{ .tags = &.{wrong} }, &diag),
    );
    try std.testing.expectEqualStrings("incompatible import type", diag.message());
    try std.testing.expectError(error.Link, instantiate(talloc, consumer_mod, .{}, &diag));
    try std.testing.expectEqualStrings("inconsistent import count", diag.message());
}

fn instantiateExceptionTagsWithFailingAllocator(gpa: std.mem.Allocator) !void {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const bytes = comptime (hdr ++ typesSec(&.{ft(I32, "")}) ++
        sec(13, "\x03\x00\x00\x00\x00\x00\x00"));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(gpa, mod, .{}, &diag);
    defer destroyInstance(gpa, inst);
    try std.testing.expectEqual(@as(usize, 3), inst.tags.len);
}

test "wasm.exec exception tag instantiation is rollback-safe across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        talloc,
        instantiateExceptionTagsWithFailingAllocator,
        .{},
    );
}

test "wasm.exec exceptions match tag identity and unwind across calls" {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const identity_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", I32) }) ++ funcSec(&.{1}) ++
        sec(13, "\x02\x00\x00\x00\x00") ++ codeSec(&.{
        "\x02\x7F" ++ // outer block -> i32
            "\x02\x7F" ++ // inner block -> i32
            "\x1F\x40\x02\x00\x00\x00\x00\x01\x01" ++
            i32c(7) ++ "\x08\x01\x0B" ++ // throw tag 1
            i32c(9) ++ "\x0B\x1A" ++ // wrong tag path reaches 11
            i32c(11) ++ "\x0B",
    }));
    var diag: types.Diagnostic = .{};
    const identity_mod = try buildModuleWithFeatures(identity_bytes, features, &diag);
    defer decode.destroyModule(talloc, identity_mod);
    const identity = try instantiate(talloc, identity_mod, .{}, &diag);
    defer destroyInstance(talloc, identity);
    var identity_result: [1]u64 = undefined;
    try invoke(identity, 0, &.{}, &identity_result, &diag);
    try std.testing.expectEqual(@as(u64, 7), identity_result[0]);

    const call_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", ""), ft("", I32) }) ++
        funcSec(&.{ 1, 2 }) ++ sec(13, "\x01\x00\x00") ++ codeSec(&.{
        i32c(55) ++ "\x08\x00",
        "\x1F\x40\x01\x00\x00\x00\x10\x00\x0B" ++ i32c(9),
    }));
    const call_mod = try buildModuleWithFeatures(call_bytes, features, &diag);
    defer decode.destroyModule(talloc, call_mod);
    const call_inst = try instantiate(talloc, call_mod, .{}, &diag);
    defer destroyInstance(talloc, call_inst);
    var call_result: [1]u64 = undefined;
    try invoke(call_inst, 1, &.{}, &call_result, &diag);
    try std.testing.expectEqual(@as(u64, 55), call_result[0]);

    try std.testing.expectError(error.Exception, invoke(call_inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("uncaught WebAssembly exception", diag.message());

    const deep_bytes = comptime (hdr ++
        typesSec(&.{ ft("", ""), ft(I32, ""), ft("", I32) }) ++
        funcSec(&.{2}) ++ sec(13, "\x02\x00\x00\x00\x01") ++
        codeSec(&.{deepExceptionBody(512)}));
    const deep_mod = try buildModuleWithFeatures(deep_bytes, features, &diag);
    defer decode.destroyModule(talloc, deep_mod);
    const deep_inst = try instantiate(talloc, deep_mod, .{}, &diag);
    defer destroyInstance(talloc, deep_inst);
    var deep_result: [1]u64 = undefined;
    try invoke(deep_inst, 0, &.{}, &deep_result, &diag);
    try std.testing.expectEqual(@as(u64, 123), deep_result[0]);

    const tail_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", I32) }) ++ funcSec(&.{ 1, 1 }) ++
        sec(13, "\x01\x00\x00") ++ codeSec(&.{
        i32c(7) ++ "\x08\x00",
        "\x1F\x40\x01\x00\x00\x00\x12\x00\x0B" ++ i32c(9),
    }));
    const tail_mod = try buildModuleWithFeatures(tail_bytes, .{
        .reference_types = true,
        .exception_handling = true,
        .tail_calls = true,
    }, &diag);
    defer decode.destroyModule(talloc, tail_mod);
    const tail_inst = try instantiate(talloc, tail_mod, .{}, &diag);
    defer destroyInstance(talloc, tail_inst);
    var tail_result: [1]u64 = undefined;
    try std.testing.expectError(error.Exception, invoke(tail_inst, 1, &.{}, &tail_result, &diag));

    const trap_bytes = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++
        codeSec(&.{"\x1F\x40\x01\x02\x00\x00\x0B"}));
    const trap_mod = try buildModuleWithFeatures(trap_bytes, features, &diag);
    defer decode.destroyModule(talloc, trap_mod);
    const trap_inst = try instantiate(talloc, trap_mod, .{}, &diag);
    defer destroyInstance(talloc, trap_inst);
    try std.testing.expectError(error.Trap, invoke(trap_inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("unreachable", diag.message());
}

test "wasm.exec exception payloads preserve bits references and rethrow identity" {
    const features: types.Features = .{
        .multi_value = true,
        .reference_types = true,
        .exception_handling = true,
    };
    var diag: types.Diagnostic = .{};
    const bits_bytes = comptime (hdr ++
        typesSec(&.{ ft(F32 ++ I64, ""), ft(F32 ++ I64, F32 ++ I64) }) ++
        funcSec(&.{1}) ++ sec(13, "\x01\x00\x00") ++ codeSec(&.{
        "\x1F\x40\x01\x00\x00\x00\x20\x00\x20\x01\x08\x00\x0B" ++
            "\x20\x00\x20\x01",
    }));
    const bits_mod = try buildModuleWithFeatures(bits_bytes, features, &diag);
    defer decode.destroyModule(talloc, bits_mod);
    const bits_inst = try instantiate(talloc, bits_mod, .{}, &diag);
    defer destroyInstance(talloc, bits_inst);
    const nan_payload: u64 = 0x7FA1_2345;
    const wide_payload: u64 = 0xFEDC_BA98_7654_3210;
    var bit_results: [2]ValueSlot = undefined;
    try invokeSlots(
        bits_inst,
        0,
        &.{ .{ .numeric = nan_payload }, .{ .numeric = wide_payload } },
        &bit_results,
        &diag,
    );
    try std.testing.expectEqual(nan_payload, bit_results[0].numericBits());
    try std.testing.expectEqual(wide_payload, bit_results[1].numericBits());

    const ref_bytes = comptime (hdr ++
        typesSec(&.{ ft("\x6F", ""), ft("\x6F", "\x6F") }) ++
        funcSec(&.{1}) ++ sec(13, "\x01\x00\x00") ++ codeSec(&.{
        "\x1F\x40\x01\x00\x00\x00\x20\x00\x08\x00\x0B\x20\x00",
    }));
    const ref_mod = try buildModuleWithFeatures(ref_bytes, features, &diag);
    defer decode.destroyModule(talloc, ref_mod);
    const ref_inst = try instantiate(talloc, ref_mod, .{}, &diag);
    defer destroyInstance(talloc, ref_inst);
    var object: js_value.Object = .{};
    var ref_result: [1]ValueSlot = undefined;
    try invokeSlots(
        ref_inst,
        0,
        &.{.{ .externref = js_value.Value.obj(&object) }},
        &ref_result,
        &diag,
    );
    try std.testing.expect(ref_result[0].externref.asObj() == &object);

    const rethrow_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", I32 ++ EXNREF), ft("", I32) }) ++
        funcSec(&.{2}) ++ sec(13, "\x01\x00\x00") ++ codeSec(&.{
        "\x1F\x40\x01\x00\x00\x00" ++ // outer catch payload -> function
            "\x02\x01" ++ // block type 1: () -> (i32, exnref)
            "\x1F\x40\x01\x01\x00\x00" ++ // inner catch_ref -> block
            i32c(42) ++ "\x08\x00\x0B" ++
            i32c(0) ++ "\xD0\x69\x0B" ++
            "\x0A\x0B" ++ i32c(9),
    }));
    const rethrow_mod = try buildModuleWithFeatures(rethrow_bytes, features, &diag);
    defer decode.destroyModule(talloc, rethrow_mod);
    const rethrow_inst = try instantiate(talloc, rethrow_mod, .{}, &diag);
    defer destroyInstance(talloc, rethrow_inst);
    var rethrow_result: [1]u64 = undefined;
    try invoke(rethrow_inst, 0, &.{}, &rethrow_result, &diag);
    try std.testing.expectEqual(@as(u64, 42), rethrow_result[0]);
    try std.testing.expectEqual(@as(usize, 0), rethrow_inst.exception_head.load(.acquire));

    const escaping_ref_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", EXNREF), ft(EXNREF, I32) }) ++
        funcSec(&.{ 1, 2 }) ++ sec(13, "\x01\x00\x00") ++ codeSec(&.{
        "\x1F\x40\x01\x03\x00" ++ i32c(77) ++ "\x08\x00\x0B\xD0\x69",
        "\x1F\x40\x01\x00\x00\x00\x20\x00\x0A\x0B" ++ i32c(9),
    }));
    const escaping_ref_mod = try buildModuleWithFeatures(escaping_ref_bytes, features, &diag);
    defer decode.destroyModule(talloc, escaping_ref_mod);
    const escaping_ref_inst = try instantiate(talloc, escaping_ref_mod, .{}, &diag);
    defer destroyInstance(talloc, escaping_ref_inst);
    var exception_result: [1]ValueSlot = undefined;
    try invokeSlots(escaping_ref_inst, 0, &.{}, &exception_result, &diag);
    try std.testing.expect(exception_result[0] == .exnref and exception_result[0].exnref != null);
    try std.testing.expect(escaping_ref_inst.exception_head.load(.acquire) != 0);
    var caught_again: [1]ValueSlot = undefined;
    try invokeSlots(escaping_ref_inst, 1, &exception_result, &caught_again, &diag);
    try std.testing.expectEqual(@as(u64, 77), caught_again[0].numericBits());

    const null_ref_bytes = comptime (hdr ++ typesSec(&.{ft("", "")}) ++
        funcSec(&.{0}) ++ codeSec(&.{"\xD0\x69\x0A"}));
    const null_ref_mod = try buildModuleWithFeatures(null_ref_bytes, features, &diag);
    defer decode.destroyModule(talloc, null_ref_mod);
    const null_ref_inst = try instantiate(talloc, null_ref_mod, .{}, &diag);
    defer destroyInstance(talloc, null_ref_inst);
    try std.testing.expectError(error.Trap, invoke(null_ref_inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("null exception reference", diag.message());
}

fn executeExceptionReferenceWithFailingAllocator(gpa: std.mem.Allocator) !void {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", EXNREF) }) ++ funcSec(&.{1}) ++
        sec(13, "\x01\x00\x00") ++ codeSec(&.{
        "\x1F\x40\x01\x03\x00" ++ i32c(17) ++ "\x08\x00\x0B\xD0\x69",
    }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(gpa, mod, .{}, &diag);
    defer destroyInstance(gpa, inst);
    var result: [1]ValueSlot = undefined;
    try invokeSlots(inst, 0, &.{}, &result, &diag);
    try std.testing.expect(result[0] == .exnref and result[0].exnref != null);
}

test "wasm.exec exception reference promotion is allocation-failure atomic" {
    try std.testing.checkAllAllocationFailures(
        talloc,
        executeExceptionReferenceWithFailingAllocator,
        .{},
    );
}

test "wasm.exec exception references publish concurrently" {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, ""), ft("", EXNREF) }) ++ funcSec(&.{1}) ++
        sec(13, "\x01\x00\x00") ++ codeSec(&.{
        "\x1F\x40\x01\x03\x00" ++ i32c(23) ++ "\x08\x00\x0B\xD0\x69",
    }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    const Invocation = struct {
        inst: *Instance,
        result: [1]ValueSlot = undefined,
        diag: types.Diagnostic = .{},
        failure: ?ExecError = null,

        fn run(self: *@This()) void {
            invokeSlots(self.inst, 0, &.{}, &self.result, &self.diag) catch |err| {
                self.failure = err;
            };
        }
    };
    var invocations: [8]Invocation = undefined;
    var threads: [8]std.Thread = undefined;
    for (&invocations, 0..) |*invocation, index| {
        invocation.* = .{ .inst = inst };
        threads[index] = try std.Thread.spawn(.{}, Invocation.run, .{invocation});
    }
    for (&threads) |*thread| thread.join();
    for (&invocations) |*invocation| {
        try std.testing.expectEqual(@as(?ExecError, null), invocation.failure);
        try std.testing.expect(invocation.result[0] == .exnref and invocation.result[0].exnref != null);
    }
    var published: usize = 0;
    var raw = inst.exception_head.load(.acquire);
    while (raw != 0) : (published += 1) {
        const exception: *const js_value.WasmException = @ptrFromInt(raw);
        raw = if (exception.next) |next| @intFromPtr(next) else 0;
    }
    try std.testing.expectEqual(@as(usize, invocations.len), published);
}

test "wasm.exec tail calls preserve indirect checks and host imports" {
    const features: types.Features = .{ .tail_calls = true };
    const nested_direct = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++
        funcSec(&.{ 0, 0, 0 }) ++ codeSec(&.{
        "\x41\x0A\x10\x01\x6A",
        "\x12\x02",
        "\x41\x20",
    }));
    try expectResultsWithFeatures(nested_direct, features, 0, &.{}, &.{42});

    const indirect = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        funcSec(&.{ 0, 0 }) ++ tableSec(1, null) ++ elemSec0(0, &.{0}) ++
        codeSec(&.{
            "\x20\x00\x41\x01\x6A",
            "\x20\x00\x41\x00\x13\x00\x00",
        }));
    try expectResultsWithFeatures(indirect, features, 1, &.{41}, &.{42});

    const out_of_bounds = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        funcSec(&.{ 0, 0 }) ++ tableSec(1, null) ++ elemSec0(0, &.{0}) ++
        codeSec(&.{ "\x20\x00", "\x20\x00\x41\x01\x13\x00\x00" }));
    try expectTrapWithFeatures(out_of_bounds, features, 1, 1, &.{41}, "undefined element");

    const uninitialized = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        funcSec(&.{0}) ++ tableSec(1, null) ++
        codeSec(&.{"\x20\x00\x41\x00\x13\x00\x00"}));
    try expectTrapWithFeatures(uninitialized, features, 1, 0, &.{41}, "uninitialized element 0");

    const mismatch = comptime (hdr ++ typesSec(&.{ ft(I32, I32), ft(I64, I32) }) ++
        funcSec(&.{ 1, 0 }) ++ tableSec(1, null) ++ elemSec0(0, &.{0}) ++
        codeSec(&.{ "\x41\x07", "\x20\x00\x41\x00\x13\x00\x00" }));
    try expectTrapWithFeatures(mismatch, features, 1, 1, &.{41}, "indirect call type mismatch");

    const imported = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        importSec(&.{impFunc("m", "double", 0)}) ++ funcSec(&.{ 0, 0 }) ++
        codeSec(&.{
            "\x20\x00\x12\x00",
            "\x20\x00\x10\x01\x41\x01\x6A",
        }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(imported, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{ .funcs = &.{double_import} }, &diag);
    defer destroyInstance(talloc, inst);
    var result: [1]u64 = undefined;
    try invoke(inst, 2, &.{21}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 43), result[0]);

    const target_bytes = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        funcSec(&.{0}) ++ codeSec(&.{"\x20\x00\x41\x01\x6A"}));
    const target = try build(target_bytes);
    defer destroyBuilt(target);
    const table = try createTable(talloc, 1, null);
    defer destroyTable(talloc, table);
    table.elems[0] = .{ .funcref = @ptrCast(target.inst.funcs[0]) };
    const cross_instance = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++
        importSec(&.{impTable("a", "t", 1, null)}) ++ funcSec(&.{0}) ++
        codeSec(&.{"\x20\x00\x41\x00\x13\x00\x00"}));
    const cross_mod = try buildModuleWithFeatures(cross_instance, features, &diag);
    defer decode.destroyModule(talloc, cross_mod);
    const cross_inst = try instantiate(talloc, cross_mod, .{ .tables = &.{table} }, &diag);
    defer destroyInstance(talloc, cross_inst);
    try invoke(cross_inst, 0, &.{41}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 42), result[0]);

    // The indirect path must preserve the same host-import tail semantics and
    // type checks even when the table points into a different instance.
    table.elems[0] = .{ .funcref = @ptrCast(inst.funcs[0]) };
    try invoke(cross_inst, 0, &.{21}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 42), result[0]);
}

test "wasm.exec tail replacement preserves reference roots and identity" {
    const features: types.Features = .{ .tail_calls = true, .reference_types = true };
    const extern_body =
        "\x20\x01\x45\x04\x6F\x20\x00\x05" ++
        "\x20\x00\x20\x01\x41\x01\x6B\x12\x00\x0B";
    const extern_bytes = comptime (hdr ++ typesSec(&.{ft("\x6F" ++ I32, "\x6F")}) ++
        funcSec(&.{0}) ++ codeSecL("\x01\x01\x6F", extern_body));
    var diag: types.Diagnostic = .{};
    const extern_mod = try buildModuleWithFeatures(extern_bytes, features, &diag);
    defer decode.destroyModule(talloc, extern_mod);
    const extern_inst = try instantiate(talloc, extern_mod, .{}, &diag);
    defer destroyInstance(talloc, extern_inst);
    var object = js_value.Object{};
    var probe: TailRootProbe = .{
        .checkpoint_limit = 5_001,
        .expected_externref = &object,
    };
    extern_inst.root_hooks = probe.hooks();
    var extern_result: [1]ValueSlot = undefined;
    try invokeSlots(
        extern_inst,
        0,
        &.{ .{ .externref = js_value.Value.obj(&object) }, .{ .numeric = 5_000 } },
        &extern_result,
        &diag,
    );
    try std.testing.expect(extern_result[0] == .externref);
    try std.testing.expect(extern_result[0].externref.asObj() == &object);
    try std.testing.expectEqual(@as(usize, 5_000), probe.checkpoints);
    try std.testing.expectEqual(@as(usize, 3), probe.max_locals);
    try std.testing.expect(probe.max_externrefs >= 1);
    try std.testing.expect(probe.saw_expected_externref);

    const funcref_body =
        "\x20\x01\x45\x04\x70\x20\x00\x05" ++
        "\x20\x00\x20\x01\x41\x01\x6B\x12\x00\x0B";
    const funcref_bytes = comptime (hdr ++ typesSec(&.{ft("\x70" ++ I32, "\x70")}) ++
        funcSec(&.{0}) ++ codeSec(&.{funcref_body}));
    const funcref_mod = try buildModuleWithFeatures(funcref_bytes, features, &diag);
    defer decode.destroyModule(talloc, funcref_mod);
    const funcref_inst = try instantiate(talloc, funcref_mod, .{}, &diag);
    defer destroyInstance(talloc, funcref_inst);
    var funcref_probe: TailRootProbe = .{
        .checkpoint_limit = 5_001,
        .expected_funcref = @ptrCast(funcref_inst.funcs[0]),
    };
    funcref_inst.root_hooks = funcref_probe.hooks();
    var funcref_result: [1]ValueSlot = undefined;
    try invokeSlots(
        funcref_inst,
        0,
        &.{ .{ .funcref = @ptrCast(funcref_inst.funcs[0]) }, .{ .numeric = 5_000 } },
        &funcref_result,
        &diag,
    );
    try std.testing.expect(funcref_result[0] == .funcref);
    try std.testing.expect(funcref_result[0].funcref == @as(*anyopaque, @ptrCast(funcref_inst.funcs[0])));
    try std.testing.expectEqual(@as(usize, 5_000), funcref_probe.checkpoints);
    try std.testing.expect(funcref_probe.max_funcrefs >= 1);
    try std.testing.expect(funcref_probe.saw_expected_funcref);

    const imported = comptime (hdr ++ typesSec(&.{ft("\x6F", "\x6F")}) ++
        importSec(&.{impFunc("m", "echo", 0)}) ++ funcSec(&.{0}) ++
        codeSec(&.{"\x20\x00\x12\x00"}));
    const imported_mod = try buildModuleWithFeatures(imported, features, &diag);
    defer decode.destroyModule(talloc, imported_mod);
    var marker: u8 = 0;
    const echo_import: ImportFunc = .{
        .ctx = @ptrCast(&marker),
        .type = .{ .params = &.{.externref}, .results = &.{.externref} },
        .call = rejectNumericReferenceCall,
        .call_slots = echoReferenceSlot,
    };
    const imported_inst = try instantiate(talloc, imported_mod, .{ .funcs = &.{echo_import} }, &diag);
    defer destroyInstance(talloc, imported_inst);
    var import_probe: TailRootProbe = .{
        .checkpoint_limit = 4,
        .expected_externref = &object,
    };
    imported_inst.root_hooks = import_probe.hooks();
    try invokeSlots(
        imported_inst,
        1,
        &.{.{ .externref = js_value.Value.obj(&object) }},
        &extern_result,
        &diag,
    );
    try std.testing.expect(extern_result[0].externref.asObj() == &object);
    try std.testing.expectEqual(@as(usize, 2), import_probe.checkpoints);
    try std.testing.expect(import_probe.max_externrefs >= 1);
    try std.testing.expect(import_probe.saw_expected_externref);

    const trapping_import: ImportFunc = .{
        .ctx = @ptrCast(&marker),
        .type = echo_import.type,
        .call = rejectNumericReferenceCall,
        .call_slots = trapReferenceSlot,
    };
    const trapping_inst = try instantiate(talloc, imported_mod, .{ .funcs = &.{trapping_import} }, &diag);
    defer destroyInstance(talloc, trapping_inst);
    var trapping_probe: TailRootProbe = .{
        .checkpoint_limit = 1,
        .expected_externref = &object,
    };
    trapping_inst.root_hooks = trapping_probe.hooks();
    try std.testing.expectError(
        error.Trap,
        invokeSlots(
            trapping_inst,
            1,
            &.{.{ .externref = js_value.Value.obj(&object) }},
            &extern_result,
            &diag,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), trapping_probe.checkpoints);
    try std.testing.expect(trapping_probe.saw_expected_externref);
}

test "wasm.exec execution root hooks balance across checkpoints and traps" {
    const loop = comptime arithModule(I32, "", "\x03\x40\x20\x00\x41\x01\x6B\x22\x00\x0D\x00\x0B");
    var built = try build(loop);
    defer destroyBuilt(built);
    var probe: RootHookProbe = .{};
    built.inst.root_hooks = .{
        .ctx = @ptrCast(&probe),
        .enter = RootHookProbe.enter,
        .leave = RootHookProbe.leave,
        .checkpoint = RootHookProbe.checkpoint,
    };
    var diag: types.Diagnostic = .{};
    try invoke(built.inst, 0, &.{2}, &.{}, &diag);
    try std.testing.expectEqual(@as(usize, 1), probe.enters);
    try std.testing.expectEqual(@as(usize, 1), probe.leaves);
    try std.testing.expectEqual(@as(usize, 1), probe.checkpoints);

    const trap = comptime arithModule("", "", "\x00");
    var trapping = try build(trap);
    defer destroyBuilt(trapping);
    trapping.inst.root_hooks = built.inst.root_hooks;
    try std.testing.expectError(error.Trap, invoke(trapping.inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 2), probe.enters);
    try std.testing.expectEqual(@as(usize, 2), probe.leaves);
}

test "wasm.exec typed invocation preserves references and rejects numeric aliases" {
    var diag: types.Diagnostic = .{};
    var object = js_value.Object{};
    const extern_import: FuncInst = .{ .imported = .{
        .ctx = @ptrCast(&object),
        .type = .{ .params = &.{.externref}, .results = &.{.externref} },
        .call = rejectNumericReferenceCall,
        .call_slots = echoReferenceSlot,
    } };
    var extern_result: [1]ValueSlot = undefined;
    try callFuncInstSlots(
        &extern_import,
        &.{.{ .externref = js_value.Value.obj(&object) }},
        &extern_result,
        &diag,
    );
    try std.testing.expect(extern_result[0] == .externref);
    try std.testing.expect(extern_result[0].externref.asObj() == &object);
    var raw_result: [1]u64 = undefined;
    try std.testing.expectError(
        error.Trap,
        callFuncInst(&extern_import, &.{@intFromPtr(&object)}, &raw_result, &diag),
    );
    try std.testing.expectEqualStrings("function signature mismatch", diag.message());

    var function_marker: u8 = 0;
    const funcref_import: FuncInst = .{ .imported = .{
        .ctx = @ptrCast(&function_marker),
        .type = .{ .params = &.{.funcref}, .results = &.{.funcref} },
        .call = rejectNumericReferenceCall,
        .call_slots = echoReferenceSlot,
    } };
    var funcref_result: [1]ValueSlot = undefined;
    try callFuncInstSlots(
        &funcref_import,
        &.{.{ .funcref = @ptrCast(&function_marker) }},
        &funcref_result,
        &diag,
    );
    try std.testing.expect(funcref_result[0] == .funcref);
    try std.testing.expect(funcref_result[0].funcref.? == @as(*anyopaque, @ptrCast(&function_marker)));
}

test "wasm.exec reference instructions and table operations" {
    const body = comptime i32c(0) ++ "\xD2\x00\x26\x00" ++ // table[0] = ref.func 0
        i32c(0) ++ "\x25\x00\xD1\x45" ++ // !ref.is_null(table[0]) => 1
        "\xFC\x10\x00" ++ i32c(2) ++ "\x46\x6A" ++ // table.size == 2
        "\xD0\x70" ++ i32c(1) ++ "\xFC\x0F\x00" ++ i32c(2) ++ "\x46\x6A" ++ // grow returns 2
        i32c(0) ++ "\xD0\x70" ++ i32c(1) ++ "\xFC\x11\x00" ++ // fill slot 0 with null
        i32c(0) ++ "\x25\x00\xD1\x6A"; // ref.is_null(table[0]) => 1
    const bytes = comptime hdr ++
        typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ tableSec(2, 4) ++
        elemSec0(1, &.{0}) ++ codeSec(&.{body});
    try expectResultsWithFeatures(bytes, .{ .reference_types = true }, 0, &.{}, &.{4});
}

test "wasm.exec externref tables preserve arbitrary identity" {
    const body = comptime i32c(0) ++ "\x20\x00\x26\x00" ++ i32c(0) ++ "\x25\x00";
    const bytes = comptime hdr ++
        typesSec(&.{ft("\x6F", "\x6F")}) ++ funcSec(&.{0}) ++
        sec(4, "\x01\x6F\x01\x01\x03") ++ codeSec(&.{body});
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .reference_types = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    var object = js_value.Object{};
    var results: [1]ValueSlot = undefined;
    try invokeSlots(inst, 0, &.{.{ .externref = js_value.Value.obj(&object) }}, &results, &diag);
    try std.testing.expect(results[0] == .externref);
    try std.testing.expect(results[0].externref.asObj() == &object);
    try std.testing.expect(inst.tables[0].elems[0] == .externref);
    try std.testing.expect(inst.tables[0].elems[0].externref.asObj() == &object);
    try std.testing.expectEqual(@as(i32, 1), tableGrowWith(inst.tables[0], 1, results[0]));
    try std.testing.expect(inst.tables[0].elems[1].externref.asObj() == &object);
}

test "wasm.exec GC i31 equality and non-null scalar operations" {
    const features: types.Features = .{
        .reference_types = true,
        .typed_function_references = true,
        .gc = true,
    };
    const bytes = comptime (hdr ++
        typesSec(&.{ ft("", I32), ft("", "") }) ++
        funcSec(&.{ 0, 0, 1 }) ++
        codeSec(&.{
            i32c(-1) ++ "\xFB\x1C\xFB\x1D",
            i32c(5) ++ "\xFB\x1C" ++ i32c(5) ++ "\xFB\x1C\xD3",
            "\xD0\x6C\xD4\x1A",
        }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    var result: [1]u64 = undefined;
    try invoke(inst, 0, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), @as(u32, @truncate(result[0])));
    try invoke(inst, 1, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 1), result[0]);
    try std.testing.expectError(error.Trap, invoke(inst, 2, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("null reference", diag.message());
}

fn exerciseGcAggregateAllocation(gpa: Allocator) !void {
    var mod: types.Module = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer mod.deinit();
    var inst: Instance = .{
        .module = &mod,
        .funcs = &.{},
        .tables = &.{},
        .mems = &.{},
        .globals = &.{},
        .tags = &.{},
        .elem_segments = &.{},
        .data_segments = &.{},
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer inst.arena.deinit();
    defer destroyGcAggregates(&inst);

    var js_child = js_value.Object{};
    const first = try createGcAggregate(&inst, 3, .struct_, &.{.{ .gcref = null }});
    const second = try createGcAggregate(&inst, 7, .array, &.{.{ .gcref = gcObjectRef(first) }});
    first.fields[0] = .{ .gcref = gcObjectRef(second) };
    const third = try createGcAggregate(&inst, 9, .struct_, &.{
        .{ .externref = js_value.Value.obj(&js_child) },
        .{ .gcref = gcObjectRef(first) },
    });
    try std.testing.expectEqual(@as(usize, 3), inst.gc_object_count);
    try std.testing.expect(first.owner == &inst and second.owner == &inst);
    try std.testing.expect(first.fields[0].gcref == gcObjectRef(second));
    try std.testing.expect(second.fields[0].gcref == gcObjectRef(first));
    const TraceProbe = struct {
        marked: ?*js_value.Object = null,

        fn mark(raw: *anyopaque, child: js_value.Value) void {
            const probe: *@This() = @ptrCast(@alignCast(raw));
            if (child.isObject()) probe.marked = child.asObj();
        }
    };
    var trace_probe: TraceProbe = .{};
    third.trace_ref.trace(&third.trace_ref, @ptrCast(&trace_probe), TraceProbe.mark);
    try std.testing.expectEqual(&js_child, trace_probe.marked);
    const active_slots = [_]ValueSlot{.{ .gcref = gcObjectRef(first) }};
    var active_roots: js_value.WasmExecutionRoots = .{ .stack = &active_slots };
    var registration: GcRootRegistration = .{ .roots = &active_roots };
    inst.gc_active_roots = &registration;
    try std.testing.expectEqual(@as(usize, 1), try collectGcAggregatesQuiescent(&inst, &.{}));
    try std.testing.expectEqual(@as(usize, 2), inst.gc_object_count);
    inst.gc_active_roots = null;
    const external_root = (try retainGcReference(.{ .gcref = gcObjectRef(first) })).?;
    try std.testing.expectEqual(@as(usize, 0), try collectGcAggregatesQuiescent(&inst, &.{}));
    try std.testing.expectEqual(@as(usize, 2), inst.gc_object_count);
    releaseGcReference(external_root);
    try std.testing.expectEqual(@as(usize, 2), try collectGcAggregatesQuiescent(&inst, &.{}));
    try std.testing.expectEqual(@as(usize, 0), inst.gc_object_count);
}

test "wasm.exec GC aggregate allocation is failure atomic and cycle safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseGcAggregateAllocation,
        .{},
    );
}

test "wasm.exec GC struct and array allocation access packed and bounds" {
    const features: types.Features = .{
        .reference_types = true,
        .typed_function_references = true,
        .gc = true,
    };
    const bytes = comptime (hdr ++
        typesSec(&.{
            "\x5F\x02\x7F\x00\x78\x01",
            "\x5E\x7F\x01",
            ft("", I32),
        }) ++
        funcSec(&.{ 2, 2, 2 }) ++
        codeSec(&.{
            i32c(10) ++ i32c(-1) ++ "\xFB\x00\x00\xFB\x03\x00\x01",
            i32c(1) ++ i32c(2) ++ i32c(3) ++ "\xFB\x08\x01\x03" ++ i32c(1) ++ "\xFB\x0B\x01",
            i32c(1) ++ i32c(2) ++ i32c(3) ++ "\xFB\x08\x01\x03" ++ i32c(3) ++ "\xFB\x0B\x01",
        }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    var result: [1]u64 = undefined;
    try invoke(inst, 0, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), @as(u32, @truncate(result[0])));
    try invoke(inst, 1, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 2), result[0]);
    try std.testing.expectError(error.Trap, invoke(inst, 2, &.{}, &result, &diag));
    try std.testing.expectEqualStrings("out of bounds array access", diag.message());

    const mutation_bytes = comptime (hdr ++
        typesSec(&.{ "\x5E\x7F\x01", ft("", I32) }) ++
        funcSec(&.{1}) ++
        codeSecL(
            "\x01\x01\x63\x00",
            i32c(0) ++ i32c(3) ++ "\xFB\x06\x00\x21\x00" ++
                "\x20\x00" ++ i32c(0) ++ i32c(9) ++ i32c(3) ++ "\xFB\x10\x00" ++
                "\x20\x00" ++ i32c(1) ++ i32c(7) ++ "\xFB\x0E\x00" ++
                "\x20\x00" ++ i32c(1) ++ "\xFB\x0B\x00",
        ));
    var mutation_diag: types.Diagnostic = .{};
    const mutation_mod = try buildModuleWithFeatures(mutation_bytes, features, &mutation_diag);
    defer decode.destroyModule(talloc, mutation_mod);
    const mutation_inst = try instantiate(talloc, mutation_mod, .{}, &mutation_diag);
    defer destroyInstance(talloc, mutation_inst);
    try invoke(mutation_inst, 0, &.{}, &result, &mutation_diag);
    try std.testing.expectEqual(@as(u64, 7), result[0]);
}

test "wasm.exec GC array data element and overlapping copy operations" {
    const features: types.Features = .{
        .reference_types = true,
        .typed_function_references = true,
        .bulk_memory = true,
        .gc = true,
    };
    const segment_bytes = comptime (hdr ++
        typesSec(&.{ "\x5E\x7F\x01", "\x5E\x70\x01", ft("", I32) }) ++
        funcSec(&.{ 2, 2 }) ++
        sec(9, "\x01\x01\x00\x01\x00") ++
        codeSec(&.{
            i32c(0) ++ i32c(1) ++ "\xFB\x09\x00\x00" ++ i32c(0) ++ "\xFB\x0B\x00",
            i32c(0) ++ i32c(1) ++ "\xFB\x0A\x01\x00\xFB\x0F",
        }) ++
        sec(11, "\x01\x01\x04A\x00\x00\x00"));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(segment_bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    var result: [1]u64 = undefined;
    try invoke(inst, 0, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 65), result[0]);
    try invoke(inst, 1, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 1), result[0]);

    const copy_bytes = comptime (hdr ++
        typesSec(&.{ "\x5E\x7F\x01", ft("", I32) }) ++
        funcSec(&.{1}) ++
        codeSecL(
            "\x01\x01\x63\x00",
            i32c(1) ++ i32c(2) ++ i32c(3) ++ "\xFB\x08\x00\x03\x21\x00" ++
                "\x20\x00" ++ i32c(1) ++ "\x20\x00" ++ i32c(0) ++ i32c(2) ++ "\xFB\x11\x00\x00" ++
                "\x20\x00" ++ i32c(2) ++ "\xFB\x0B\x00",
        ));
    var copy_diag: types.Diagnostic = .{};
    const copy_mod = try buildModuleWithFeatures(copy_bytes, features, &copy_diag);
    defer decode.destroyModule(talloc, copy_mod);
    const copy_inst = try instantiate(talloc, copy_mod, .{}, &copy_diag);
    defer destroyInstance(talloc, copy_inst);
    try invoke(copy_inst, 0, &.{}, &result, &copy_diag);
    try std.testing.expectEqual(@as(u64, 2), result[0]);
}

test "wasm.exec GC tests casts and cast branches use runtime identity" {
    const features: types.Features = .{
        .reference_types = true,
        .typed_function_references = true,
        .gc = true,
    };
    const bytes = comptime (hdr ++
        typesSec(&.{ "\x5F\x00", "\x5E\x7F\x01", ft("", I32) }) ++
        funcSec(&.{ 2, 2, 2, 2, 2 }) ++
        codeSec(&.{
            "\xFB\x00\x00\xFB\x14\x00",
            "\xD0\x00\xFB\x14\x00",
            "\xFB\x00\x00\xFB\x16\x00\x1A" ++ i32c(7),
            "\xD0\x6B\xFB\x16\x6B\x1A" ++ i32c(0),
            "\x02\x6D\xFB\x00\x00\xFB\x18\x00\x00\x6B\x6B\x0B\x1A" ++ i32c(1),
        }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    var result: [1]u64 = undefined;
    try invoke(inst, 0, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 1), result[0]);
    try invoke(inst, 1, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 0), result[0]);
    try invoke(inst, 2, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 7), result[0]);
    try std.testing.expectError(error.Trap, invoke(inst, 3, &.{}, &result, &diag));
    try std.testing.expectEqualStrings("cast failure", diag.message());
    try invoke(inst, 4, &.{}, &result, &diag);
    try std.testing.expectEqual(@as(u64, 1), result[0]);
}

test "wasm.exec bulk memory preserves overlap drop and zero-length bounds" {
    const initialize = comptime i32c(10) ++ i32c(0) ++ i32c(5) ++ "\xFC\x08\x00\x00" ++
        i32c(12) ++ i32c(10) ++ i32c(5) ++ "\xFC\x0A\x00\x00" ++
        i32c(20) ++ i32c(81) ++ i32c(3) ++ "\xFC\x0B\x00" ++
        "\xFC\x09\x00";
    const zero_at_end = comptime i32c(65536) ++ i32c(0) ++ i32c(0) ++ "\xFC\x08\x00\x00";
    const bad_zero_source = comptime i32c(65536) ++ i32c(1) ++ i32c(0) ++ "\xFC\x08\x00\x00";
    const bad_copy = comptime i32c(65535) ++ i32c(0) ++ i32c(2) ++ "\xFC\x0A\x00\x00";
    const bytes = comptime hdr ++
        typesSec(&.{ft("", "")}) ++ funcSec(&.{ 0, 0, 0, 0 }) ++ memSec(1, null) ++
        sec(12, "\x01") ++ codeSec(&.{ initialize, zero_at_end, bad_zero_source, bad_copy }) ++
        sec(11, "\x01\x01\x05ABCDE");
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .bulk_memory = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    try invoke(inst, 0, &.{}, &.{}, &diag);
    try std.testing.expectEqualSlices(u8, "ABABCDE", inst.mems[0].bytes()[10..17]);
    try std.testing.expectEqualSlices(u8, "QQQ", inst.mems[0].bytes()[20..23]);
    try std.testing.expect(inst.data_segments[0].dropped);
    try invoke(inst, 1, &.{}, &.{}, &diag);
    try std.testing.expectError(error.Trap, invoke(inst, 2, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("out of bounds memory access", diag.message());
    const before = inst.mems[0].bytes()[65534];
    try std.testing.expectError(error.Trap, invoke(inst, 3, &.{}, &.{}, &diag));
    try std.testing.expectEqual(before, inst.mems[0].bytes()[65534]);
    try std.testing.expectError(error.Trap, invoke(inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqualSlices(u8, "ABABCDE", inst.mems[0].bytes()[10..17]);
}

test "wasm.exec bulk table operations preserve explicit indices and drop state" {
    const initialize = comptime i32c(1) ++ i32c(0) ++ i32c(1) ++ "\xFC\x0C\x00\x01" ++
        "\xFC\x0D\x00" ++
        i32c(2) ++ i32c(1) ++ i32c(1) ++ "\xFC\x0E\x00\x01";
    const call = comptime i32c(2) ++ "\x11\x00\x00";
    const bytes = comptime hdr ++
        typesSec(&.{ ft("", I32), ft("", "") }) ++ funcSec(&.{ 0, 1, 0 }) ++
        sec(4, "\x02\x70\x00\x03\x70\x00\x03") ++
        sec(9, "\x01\x01\x00\x01\x00") ++
        codeSec(&.{ i32c(77), initialize, call });
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .bulk_memory = true, .reference_types = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    try invoke(inst, 1, &.{}, &.{}, &diag);
    try std.testing.expect(inst.elem_segments[0].dropped);
    try std.testing.expect(inst.tables[1].elems[1].funcref == @as(*anyopaque, @ptrCast(inst.funcs[0])));
    try std.testing.expect(inst.tables[0].elems[2].funcref == @as(*anyopaque, @ptrCast(inst.funcs[0])));
    try std.testing.expectEqual(@as(u64, 77), try run1(inst, 2, &.{}));
    try std.testing.expectError(error.Trap, invoke(inst, 1, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("out of bounds table access", diag.message());
}

test "wasm.exec global reference roots publish overwrite and barrier state" {
    var object = js_value.Object{};
    const global = try createGlobalSlot(
        talloc,
        .{ .val = .externref, .mutable = true },
        .{ .externref = js_value.Value.obj(&object) },
    );
    defer destroyGlobal(talloc, global);
    try std.testing.expectEqual(js_value.Value.obj(&object).bits, global.ref_root.load(.acquire));

    var barriers: usize = 0;
    global.barrier_ctx = @ptrCast(&barriers);
    global.barrier = recordGlobalBarrier;
    setGlobalValue(global, .{ .externref = js_value.Value.obj(&object) });
    try std.testing.expectEqual(@as(usize, 1), barriers);
    setGlobalValue(global, .{ .numeric = 7 });
    try std.testing.expectEqual(js_value.Value.undef().bits, global.ref_root.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), barriers);
}

test "wasm.exec execution roots refresh after pop and local overwrite" {
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    var probe: RootLivenessProbe = .{};
    var diag: types.Diagnostic = .{};
    var state: State = .{
        .alloc = arena.allocator(),
        .diag = &diag,
        .root_hooks = .{
            .ctx = @ptrCast(&probe),
            .enter = RootLivenessProbe.enter,
            .leave = RootLivenessProbe.leave,
            .checkpoint = RootLivenessProbe.checkpoint,
        },
    };
    var object = js_value.Object{};
    try pushSlot(&state, .{ .externref = js_value.Value.obj(&object) });
    checkpoint(&state);
    _ = popSlot(&state);
    checkpoint(&state);
    try state.locals.append(state.alloc, .{ .externref = js_value.Value.obj(&object) });
    checkpoint(&state);
    state.locals.items[0] = .{ .numeric = 0 };
    checkpoint(&state);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1, 0 }, &probe.externrefs);
}

test "wasm.exec v128 slots preserve all lane bits" {
    const bits: u128 = 0xFEDCBA98765432100123456789ABCDEF;
    const slot: ValueSlot = .{ .vector = bits };
    try std.testing.expectEqual(bits, slot.vectorBits());
    try std.testing.expect(slot == .vector);
}

test "wasm.exec SIMD lane movement and bitwise operations" {
    const bytes = comptime (hdr ++
        typesSec(&.{
            ft(V128 ++ V128, V128),
            ft(V128 ++ V128 ++ V128, V128),
            ft(V128, I32),
            ft(I32, V128),
            ft(V128 ++ I32, V128),
            ft(V128, V128),
        }) ++
        funcSec(&.{ 0, 0, 1, 2, 3, 4, 2, 0, 5 }) ++
        codeSec(&.{
            "\x20\x00\x20\x01\xFD\x0D\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F",
            "\x20\x00\x20\x01\xFD\x51",
            "\x20\x00\x20\x01\x20\x02\xFD\x52",
            "\x20\x00\xFD\x53",
            "\x20\x00\xFD\x0F",
            "\x20\x00\x20\x01\xFD\x17\x0F",
            "\x20\x00\xFD\x15\x0F",
            "\x20\x00\x20\x01\xFD\x0E",
            "\x20\x00\xFD\x4D",
        }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .fixed_width_simd = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    const left: u128 = 0x0F0E0D0C0B0A09080706050403020100;
    const right: u128 = 0xF0E0D0C0B0A090807060504030201000;
    var vector_result: [1]ValueSlot = undefined;
    try invokeSlots(inst, 0, &.{ .{ .vector = left }, .{ .vector = right } }, &vector_result, &diag);
    try std.testing.expectEqual(left, vector_result[0].vectorBits());
    try invokeSlots(inst, 1, &.{ .{ .vector = left }, .{ .vector = right } }, &vector_result, &diag);
    try std.testing.expectEqual(left ^ right, vector_result[0].vectorBits());
    const mask: u128 = 0xFFFF0000FFFF0000FFFF0000FFFF0000;
    try invokeSlots(inst, 2, &.{ .{ .vector = left }, .{ .vector = right }, .{ .vector = mask } }, &vector_result, &diag);
    try std.testing.expectEqual((left & mask) | (right & ~mask), vector_result[0].vectorBits());

    var scalar_result: [1]ValueSlot = undefined;
    try invokeSlots(inst, 3, &.{.{ .vector = left }}, &scalar_result, &diag);
    try std.testing.expectEqual(@as(u64, 1), scalar_result[0].numericBits());
    try invokeSlots(inst, 4, &.{.{ .numeric = 0xAB }}, &vector_result, &diag);
    try std.testing.expectEqual(@as(u128, 0xABABABABABABABABABABABABABABABAB), vector_result[0].vectorBits());
    try invokeSlots(inst, 5, &.{ .{ .vector = left }, .{ .numeric = 0xFF } }, &vector_result, &diag);
    try std.testing.expectEqual(replaceLaneBits(left, 15, 8, 0xFF), vector_result[0].vectorBits());
    try invokeSlots(inst, 6, &.{.{ .vector = @as(u128, 0x80) << 120 }}, &scalar_result, &diag);
    try std.testing.expectEqual(@as(u64, 0xFFFFFF80), scalar_result[0].numericBits());
    try invokeSlots(inst, 7, &.{ .{ .vector = left }, .{ .vector = right } }, &vector_result, &diag);
    try std.testing.expectEqual(@as(u128, 0), vector_result[0].vectorBits());
    try invokeSlots(inst, 8, &.{.{ .vector = left }}, &vector_result, &diag);
    try std.testing.expectEqual(~left, vector_result[0].vectorBits());
}

test "wasm.exec SIMD memory operations preserve bits and trap atomically" {
    const bytes = comptime (hdr ++
        typesSec(&.{
            ft(I32, V128),
            ft(I32 ++ V128, ""),
            ft(I32 ++ V128, V128),
        }) ++
        funcSec(&.{ 0, 1, 2, 0, 0, 1 }) ++ memSec(1, null) ++
        codeSec(&.{
            "\x20\x00\xFD\x00\x04\x01",
            "\x20\x00\x20\x01\xFD\x0B\x04\x00",
            "\x20\x00\x20\x01\xFD\x54\x00\x00\x0F",
            "\x20\x00\xFD\x01\x03\x00",
            "\x20\x00\xFD\x5C\x02\x00",
            "\x20\x00\x20\x01\xFD\x58\x00\x00\x0F",
        }));
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .fixed_width_simd = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    for (0..16) |index| inst.mems[0].bytes()[3 + index] = @intCast(index);
    var vector_result: [1]ValueSlot = undefined;
    try invokeSlots(inst, 0, &.{.{ .numeric = 2 }}, &vector_result, &diag);
    try std.testing.expectEqual(@as(u128, 0x0F0E0D0C0B0A09080706050403020100), vector_result[0].vectorBits());

    const stored: u128 = 0xFEDCBA98765432100123456789ABCDEF;
    var no_results: [0]ValueSlot = .{};
    try invokeSlots(inst, 1, &.{ .{ .numeric = 32 }, .{ .vector = stored } }, &no_results, &diag);
    try std.testing.expectEqual(@as(u64, @truncate(stored)), readLittle(inst.mems[0].bytes()[32..40]));
    try std.testing.expectEqual(@as(u64, @truncate(stored >> 64)), readLittle(inst.mems[0].bytes()[40..48]));

    inst.mems[0].bytes()[20] = 0xFE;
    try invokeSlots(inst, 2, &.{ .{ .numeric = 20 }, .{ .vector = stored } }, &vector_result, &diag);
    try std.testing.expectEqual(replaceLaneBits(stored, 15, 8, 0xFE), vector_result[0].vectorBits());

    const signed_source = [_]u8{ 0x80, 0x7F, 0xFF, 0x01, 0x00, 0x81, 0x55, 0xAA };
    @memcpy(inst.mems[0].bytes()[48..56], &signed_source);
    try invokeSlots(inst, 3, &.{.{ .numeric = 48 }}, &vector_result, &diag);
    try std.testing.expectEqual(loadExtended(&signed_source, 8, 16, true), vector_result[0].vectorBits());

    @memcpy(inst.mems[0].bytes()[64..68], &[_]u8{ 0x78, 0x56, 0x34, 0x12 });
    try invokeSlots(inst, 4, &.{.{ .numeric = 64 }}, &vector_result, &diag);
    try std.testing.expectEqual(@as(u128, 0x12345678), vector_result[0].vectorBits());

    try invokeSlots(inst, 5, &.{ .{ .numeric = 70 }, .{ .vector = stored } }, &no_results, &diag);
    try std.testing.expectEqual(@as(u8, @truncate(stored >> 120)), inst.mems[0].bytes()[70]);

    try std.testing.expectError(error.Trap, invokeSlots(inst, 0, &.{.{ .numeric = 65521 }}, &vector_result, &diag));
    try std.testing.expectEqualStrings("out of bounds memory access", diag.message());
    var before: [6]u8 = undefined;
    @memcpy(&before, inst.mems[0].bytes()[65530..65536]);
    try std.testing.expectError(error.Trap, invokeSlots(inst, 1, &.{ .{ .numeric = 65530 }, .{ .vector = 0 } }, &no_results, &diag));
    try std.testing.expectEqualSlices(u8, &before, inst.mems[0].bytes()[65530..65536]);
}

test "wasm.exec conversions trunc f32 to int" {
    try unop(.i32_trunc_f32_s, F32, I32, f32v(1.5), 1);
    try unop(.i32_trunc_f32_s, F32, I32, f32v(-1.5), i32v(-1));
    try unop(.i32_trunc_f32_s, F32, I32, f32v(2147483520.0), 2147483520);
    try unop(.i32_trunc_f32_s, F32, I32, f32v(-2147483648.0), i32v(std.math.minInt(i32)));
    try unop(.i32_trunc_f32_u, F32, I32, f32v(4294967040.0), 4294967040);
    try unop(.i32_trunc_f32_u, F32, I32, f32v(-0.5), 0);
    try unop(.i32_trunc_f32_u, F32, I32, f32v(0.999), 0);
    try unop(.i64_trunc_f32_s, F32, I64, f32v(9223371487098961920.0), 9223371487098961920);
    try unop(.i64_trunc_f32_s, F32, I64, f32v(-9223372036854775808.0), i64v(std.math.minInt(i64)));
    try unop(.i64_trunc_f32_u, F32, I64, f32v(18446742974197923840.0), 18446742974197923840);
}

test "wasm.exec conversions trunc f64 to int" {
    try unop(.i32_trunc_f64_s, F64, I32, f64v(1.5), 1);
    try unop(.i32_trunc_f64_s, F64, I32, f64v(2147483647.9), 2147483647);
    try unop(.i32_trunc_f64_s, F64, I32, f64v(-2147483648.9999), i32v(std.math.minInt(i32)));
    try unop(.i32_trunc_f64_u, F64, I32, f64v(4294967295.9), 4294967295);
    try unop(.i32_trunc_f64_u, F64, I32, f64v(-0.9), 0);
    try unop(.i64_trunc_f64_s, F64, I64, f64v(9223372036854774784.0), 9223372036854774784);
    try unop(.i64_trunc_f64_s, F64, I64, f64v(-9223372036854775808.0), i64v(std.math.minInt(i64)));
    try unop(.i64_trunc_f64_u, F64, I64, f64v(18446744073709549568.0), 18446744073709549568);
}

test "wasm.exec conversions trunc traps" {
    try unopTrap(.i32_trunc_f32_s, F32, I32, f32v(2147483648.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_s, F32, I32, f32v(-2147483904.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_s, F32, I32, f32nan, "invalid conversion to integer");
    try unopTrap(.i32_trunc_f32_u, F32, I32, f32v(4294967296.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_u, F32, I32, f32v(-1.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_u, F32, I32, f32nan, "invalid conversion to integer");
    try unopTrap(.i32_trunc_f64_s, F64, I32, f64v(2147483648.0), "integer overflow");
    try unopTrap(.i32_trunc_f64_s, F64, I32, f64v(-2147483649.0), "integer overflow");
    try unopTrap(.i32_trunc_f64_s, F64, I32, f64nan, "invalid conversion to integer");
    try unopTrap(.i32_trunc_f64_u, F64, I32, f64v(4294967296.0), "integer overflow");
    try unopTrap(.i32_trunc_f64_u, F64, I32, f64v(-1.0), "integer overflow");
    try unopTrap(.i64_trunc_f32_s, F32, I64, f32v(9223372036854775808.0), "integer overflow");
    try unopTrap(.i64_trunc_f32_s, F32, I64, f32nan, "invalid conversion to integer");
    try unopTrap(.i64_trunc_f32_u, F32, I64, f32v(18446744073709551616.0), "integer overflow");
    try unopTrap(.i64_trunc_f32_u, F32, I64, f32v(-1.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_s, F64, I64, f64v(9223372036854775808.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_s, F64, I64, f64v(-9223372036854777856.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_s, F64, I64, f64nan, "invalid conversion to integer");
    try unopTrap(.i64_trunc_f64_u, F64, I64, f64v(18446744073709551616.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_u, F64, I64, f64v(-1.0), "integer overflow");
}

test "wasm.exec conversions int to float" {
    try unop(.f32_convert_i32_s, I32, F32, i32v(-1), f32v(-1.0));
    try unop(.f32_convert_i32_s, I32, F32, 16777217, f32v(16777216.0)); // tie to even
    try unop(.f32_convert_i32_s, I32, F32, 16777219, f32v(16777220.0)); // tie to even
    try unop(.f32_convert_i32_u, I32, F32, 0xFFFFFFFF, f32v(4294967296.0));
    try unop(.f32_convert_i64_s, I64, F32, 4611686018427387905, f32v(4611686018427387904.0));
    try unop(.f32_convert_i64_u, I64, F32, 0xFFFFFFFFFFFFFFFF, f32v(18446744073709551616.0));
    try unop(.f64_convert_i32_s, I32, F64, i32v(-3), f64v(-3.0));
    try unop(.f64_convert_i32_u, I32, F64, 0xFFFFFFFF, f64v(4294967295.0));
    try unop(.f64_convert_i64_s, I64, F64, 9007199254740993, f64v(9007199254740992.0)); // tie to even
    try unop(.f64_convert_i64_u, I64, F64, 0xFFFFFFFFFFFFFFFF, f64v(18446744073709551616.0));
}

test "wasm.exec conversions demote promote reinterpret" {
    try unop(.f32_demote_f64, F64, F32, f64v(1.5), f32v(1.5));
    try unop(.f32_demote_f64, F64, F32, f64v(0.1), f32v(@floatCast(@as(f64, 0.1))));
    try unop(.f64_promote_f32, F32, F64, f32v(0.1), f64v(@as(f32, 0.1)));
    try unop(.f64_promote_f32, F32, F64, f32v(-2.5), f64v(-2.5));
    try unop(.i32_reinterpret_f32, F32, I32, f32v(1.5), 0x3FC00000);
    try unop(.f32_reinterpret_i32, I32, F32, 0x3FC00000, 0x3FC00000);
    try unop(.i64_reinterpret_f64, F64, I64, f64v(-2.5), f64v(-2.5));
    try unop(.f64_reinterpret_i64, I64, F64, 0xC004000000000000, 0xC004000000000000);
    // Reinterpret round-trips preserve exact bits, incl. NaN payloads.
    try unop(.f32_reinterpret_i32, I32, F32, 0x7FC00001, 0x7FC00001);
    try unop(.f64_reinterpret_i64, I64, F64, 0x7FF8000000000001, 0x7FF8000000000001);
}

// -- Memory ----------------------------------------------------------------------

const ld0 = "\x20\x00";
const ld01 = "\x20\x00\x20\x01";

const mem_types: []const []const u8 = &.{
    ft(I32, I32), ft(I32, I32), ft(I32, I32), ft(I32, I32), ft(I32, I32), // 0-4: i32 loads
    ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), // 5-11: i64 loads
    ft(I32, F32), ft(I32, F64), // 12-13: float loads
    ft(I32 ++ I32, ""), ft(I32 ++ I32, ""), ft(I32 ++ I32, ""), // 14-16: i32 stores
    ft(I32 ++ I64, ""), ft(I32 ++ I64, ""), ft(I32 ++ I64, ""), ft(I32 ++ I64, ""), // 17-20: i64 stores
    ft(I32 ++ F32, ""), ft(I32 ++ F64, ""), // 21-22: float stores
    ft(I32, I32), // 23: i32.load with offset=4
};

const mem_bodies: []const []const u8 = &.{
    ld0 ++ "\x2C\x00\x00", // 0: i32.load8_s
    ld0 ++ "\x2D\x00\x00", // 1: i32.load8_u
    ld0 ++ "\x2E\x00\x00", // 2: i32.load16_s
    ld0 ++ "\x2F\x00\x00", // 3: i32.load16_u
    ld0 ++ "\x28\x00\x00", // 4: i32.load
    ld0 ++ "\x30\x00\x00", // 5: i64.load8_s
    ld0 ++ "\x31\x00\x00", // 6: i64.load8_u
    ld0 ++ "\x32\x00\x00", // 7: i64.load16_s
    ld0 ++ "\x33\x00\x00", // 8: i64.load16_u
    ld0 ++ "\x34\x00\x00", // 9: i64.load32_s
    ld0 ++ "\x35\x00\x00", // 10: i64.load32_u
    ld0 ++ "\x29\x00\x00", // 11: i64.load
    ld0 ++ "\x2A\x00\x00", // 12: f32.load
    ld0 ++ "\x2B\x00\x00", // 13: f64.load
    ld01 ++ "\x36\x00\x00", // 14: i32.store
    ld01 ++ "\x3A\x00\x00", // 15: i32.store8
    ld01 ++ "\x3B\x00\x00", // 16: i32.store16
    ld01 ++ "\x37\x00\x00", // 17: i64.store
    ld01 ++ "\x3C\x00\x00", // 18: i64.store8
    ld01 ++ "\x3D\x00\x00", // 19: i64.store16
    ld01 ++ "\x3E\x00\x00", // 20: i64.store32
    ld01 ++ "\x38\x00\x00", // 21: f32.store
    ld01 ++ "\x39\x00\x00", // 22: f64.store
    ld0 ++ "\x28\x00\x04", // 23: i32.load offset=4
};

const mem_mod_bytes = hdr ++
    typesSec(mem_types) ++
    funcSec(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 }) ++
    memSec(1, null) ++
    codeSec(mem_bodies);

fn memInstance() !Built {
    return build(mem_mod_bytes);
}

test "wasm.exec memory little endian widths" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 14, &.{ 0, 0x04030201 }); // i32.store
    try std.testing.expectEqual(@as(u64, 0x01), try run1(b.inst, 1, &.{0}));
    try std.testing.expectEqual(@as(u64, 0x02), try run1(b.inst, 1, &.{1}));
    try std.testing.expectEqual(@as(u64, 0x03), try run1(b.inst, 1, &.{2}));
    try std.testing.expectEqual(@as(u64, 0x04), try run1(b.inst, 1, &.{3}));
    try std.testing.expectEqual(@as(u64, 0x0201), try run1(b.inst, 3, &.{0})); // i32.load16_u
    try std.testing.expectEqual(@as(u64, 0x04030201), try run1(b.inst, 4, &.{0}));
}

test "wasm.exec memory sign and zero extension" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 15, &.{ 10, 0x80 }); // i32.store8
    try std.testing.expectEqual(i32v(-128), try run1(b.inst, 0, &.{10})); // i32.load8_s
    try std.testing.expectEqual(@as(u64, 128), try run1(b.inst, 1, &.{10})); // i32.load8_u
    try run0(b.inst, 16, &.{ 12, 0x8001 }); // i32.store16
    try std.testing.expectEqual(@as(u64, 0xFFFF8001), try run1(b.inst, 2, &.{12})); // i32.load16_s
    try std.testing.expectEqual(@as(u64, 0x8001), try run1(b.inst, 3, &.{12})); // i32.load16_u

    try run0(b.inst, 17, &.{ 16, 0x8070605040302010 }); // i64.store
    try std.testing.expectEqual(@as(u64, 0x10), try run1(b.inst, 6, &.{16})); // i64.load8_u
    try std.testing.expectEqual(@as(u64, 0x2010), try run1(b.inst, 8, &.{16})); // i64.load16_u
    try std.testing.expectEqual(@as(u64, 0x40302010), try run1(b.inst, 10, &.{16})); // i64.load32_u
    try std.testing.expectEqual(@as(u64, 0x8070605040302010), try run1(b.inst, 11, &.{16}));
    try run0(b.inst, 17, &.{ 24, 0xFFFFFFFF80000000 });
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF80000000), try run1(b.inst, 9, &.{24})); // i64.load32_s
    try std.testing.expectEqual(@as(u64, 0x80000000), try run1(b.inst, 10, &.{24})); // i64.load32_u
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFF80), try run1(b.inst, 5, &.{27})); // i64.load8_s of 0x80
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFF8000), try run1(b.inst, 7, &.{26})); // i64.load16_s of 0x8000
}

test "wasm.exec memory float load store" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 21, &.{ 32, 0x3FC00000 }); // f32.store 1.5
    try std.testing.expectEqual(@as(u64, 0x3FC00000), try run1(b.inst, 12, &.{32}));
    try std.testing.expectEqual(@as(u64, 0x3FC00000), try run1(b.inst, 4, &.{32})); // raw i32 view
    try run0(b.inst, 22, &.{ 40, 0xC004000000000000 }); // f64.store -2.5
    try std.testing.expectEqual(@as(u64, 0xC004000000000000), try run1(b.inst, 13, &.{40}));
    try std.testing.expectEqual(@as(u64, 0xC004000000000000), try run1(b.inst, 11, &.{40}));
}

test "wasm.exec memory unaligned access" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 14, &.{ 3, 0xAABBCCDD });
    try std.testing.expectEqual(@as(u64, 0xAABBCCDD), try run1(b.inst, 4, &.{3}));
    try run0(b.inst, 17, &.{ 5, 0x1122334455667788 });
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), try run1(b.inst, 11, &.{5}));
    try std.testing.expectEqual(@as(u64, 0x7788CCDD), try run1(b.inst, 10, &.{3})); // overlapping unaligned
}

test "wasm.exec memory out of bounds traps at exact boundary" {
    const b = try memInstance();
    defer destroyBuilt(b);
    // One page: len = 65536. ea + size == len is legal; +1 traps.
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 4, &.{65532})); // i32.load, last legal
    try runTrap(1, b.inst, 4, &.{65533}, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 11, &.{65528})); // i64.load, last legal
    try runTrap(1, b.inst, 11, &.{65529}, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 1, &.{65535})); // i32.load8_u, last legal
    try runTrap(1, b.inst, 1, &.{65536}, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 3, &.{65534})); // i32.load16_u, last legal
    try runTrap(1, b.inst, 3, &.{65535}, "out of bounds memory access");
    // memarg offset participates in the bounds check.
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 23, &.{65528})); // 65528+4+4 == 65536
    try runTrap(1, b.inst, 23, &.{65529}, "out of bounds memory access");
    // Effective address arithmetic is 64-bit: no 32-bit wraparound.
    try runTrap(1, b.inst, 23, &.{0xFFFFFFFF}, "out of bounds memory access");
    try runTrap(1, b.inst, 4, &.{0xFFFFFFFE}, "out of bounds memory access");
    // Stores bounds-check too.
    try runTrap(0, b.inst, 14, &.{ 65533, 0 }, "out of bounds memory access");
    try runTrap(0, b.inst, 15, &.{ 65536, 0 }, "out of bounds memory access");
    try run0(b.inst, 14, &.{ 65532, 0xDEADBEEF }); // last legal store
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), try run1(b.inst, 4, &.{65532}));
}

const grow_mod_bytes = hdr ++
    typesSec(&.{ ft("", I32), ft(I32, I32), ft(I32, I32) }) ++
    funcSec(&.{ 0, 1, 2 }) ++
    memSec(1, 3) ++
    codeSec(&.{ "\x3F\x00", "\x20\x00\x40\x00", ld0 ++ "\x28\x00\x00" });

test "wasm.exec memory grow and size" {
    const b = try build(grow_mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 1), try run1(b.inst, 0, &.{})); // size
    try std.testing.expectEqual(@as(u64, 1), try run1(b.inst, 1, &.{1})); // grow(1) -> old size
    try std.testing.expectEqual(@as(u64, 2), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 2, &.{2 * 65536 - 4})); // grown pages are zero-filled
    try std.testing.expectEqual(@as(u64, 2), try run1(b.inst, 1, &.{1})); // grow to max
    try std.testing.expectEqual(@as(u64, 3), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), try run1(b.inst, 1, &.{1})); // beyond max -> -1
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), try run1(b.inst, 1, &.{std.math.maxInt(u32)})); // huge delta -> -1
    try std.testing.expectEqual(@as(u64, 3), try run1(b.inst, 0, &.{})); // size unchanged after failures
    try std.testing.expectEqual(@as(u64, 3), try run1(b.inst, 1, &.{0})); // grow(0) -> current size
}

test "wasm.exec memory data segment bytes" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, I32), ft(I32, I32) }) ++
        funcSec(&.{ 0, 1 }) ++
        memSec(1, null) ++
        codeSec(&.{ ld0 ++ "\x2D\x00\x00", ld0 ++ "\x28\x00\x00" }) ++
        dataSec0(4, "ABCD"));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 'A'), try run1(b.inst, 0, &.{4}));
    try std.testing.expectEqual(@as(u64, 'D'), try run1(b.inst, 0, &.{7}));
    try std.testing.expectEqual(@as(u64, 0x44434241), try run1(b.inst, 1, &.{4})); // little-endian "ABCD"
}

// -- call_indirect ---------------------------------------------------------------

const ci_bytes = hdr ++
    typesSec(&.{ ft("", I32), ft(I32, I32), ft(I32 ++ I32, I32) }) ++
    funcSec(&.{ 0, 1, 2 }) ++
    tableSec(2, null) ++
    elemSec0(0, &.{0}) ++
    codeSec(&.{
        i32c(77), // 0: () -> 77
        "\x20\x00\x11\x00\x00", // 1: (i32 index) -> call_indirect type 0
        "\x20\x00\x20\x01\x11\x01\x00", // 2: (i32 param, i32 index) -> call_indirect type 1
    });

test "wasm.exec call_indirect happy path" {
    const b = try build(ci_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 77), try run1(b.inst, 1, &.{0}));
}

test "wasm.exec call_indirect traps" {
    const b = try build(ci_bytes);
    defer destroyBuilt(b);
    try runTrap(1, b.inst, 1, &.{1}, "uninitialized element 1"); // elem wrote only index 0
    try runTrap(1, b.inst, 1, &.{2}, "undefined element");
    try runTrap(1, b.inst, 1, &.{99}, "undefined element");
    try runTrap(1, b.inst, 2, &.{ 0, 0 }, "indirect call type mismatch"); // ()->i32 entry vs (i32)->i32
}

test "wasm.exec call_indirect cross-instance shared table" {
    // Module A defines func () -> 77; module B imports a table and calls
    // through it. The shared TableInst is host-owned: B's destroyInstance
    // must not free it, and B is destroyed before A (its table references
    // A's FuncInst).
    const a_bytes = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ codeSec(&.{i32c(77)}));
    const a = try build(a_bytes);
    defer destroyBuilt(a);
    const tab = try createTable(talloc, 1, null);
    defer destroyTable(talloc, tab);
    tab.elems[0] = .{ .funcref = @ptrCast(a.inst.funcs[0]) };

    const b_bytes = comptime (hdr ++
        typesSec(&.{ft("", I32)}) ++
        importSec(&.{impTable("a", "t", 1, null)}) ++
        funcSec(&.{0}) ++
        codeSec(&.{i32c(0) ++ "\x11\x00\x00"}));
    var diag: types.Diagnostic = .{};
    const bmod = try buildModule(b_bytes, &diag);
    defer decode.destroyModule(talloc, bmod);
    const binst = try instantiate(talloc, bmod, .{ .tables = &.{tab} }, &diag);
    defer destroyInstance(talloc, binst);
    try std.testing.expectEqual(@as(u64, 77), try run1(binst, 0, &.{}));
}

test "wasm.exec call_indirect selects an explicit table across instances" {
    const a_bytes = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ codeSec(&.{i32c(91)}));
    const a = try build(a_bytes);
    defer destroyBuilt(a);
    const decoy = try createTable(talloc, 1, null);
    defer destroyTable(talloc, decoy);
    const target = try createTable(talloc, 1, null);
    defer destroyTable(talloc, target);
    target.elems[0] = .{ .funcref = @ptrCast(a.inst.funcs[0]) };

    const b_bytes = comptime (hdr ++
        typesSec(&.{ft("", I32)}) ++
        importSec(&.{ impTable("a", "decoy", 1, null), impTable("a", "target", 1, null) }) ++
        funcSec(&.{0}) ++
        codeSec(&.{
            "\xFC\x10\x01" ++ // table.size 1 => 1
                "\xD0\x70" ++ i32c(1) ++ "\xFC\x0F\x01\x6A" ++ // table.grow 1 => old size 1; sum 2
                i32c(1) ++ "\xD0\x70" ++ i32c(1) ++ "\xFC\x11\x01" ++ // table.fill 1[1] with null
                i32c(1) ++ "\x25\x01\xD1\x6A" ++ // table.get 1[1] is null; sum 3
                i32c(0) ++ "\x11\x00\x01\x6A", // call_indirect type 0 table 1 => 91; sum 94
        }));
    var diag: types.Diagnostic = .{};
    const bmod = try buildModuleWithFeatures(b_bytes, .{ .reference_types = true }, &diag);
    defer decode.destroyModule(talloc, bmod);
    const binst = try instantiate(talloc, bmod, .{ .tables = &.{ decoy, target } }, &diag);
    defer destroyInstance(talloc, binst);
    try std.testing.expectEqual(@as(u64, 94), try run1(binst, 0, &.{}));
    try std.testing.expectEqual(@as(usize, 2), target.elems.len);
    try std.testing.expect(target.elems[1] == .funcref and target.elems[1].funcref == null);
}

// -- Globals ---------------------------------------------------------------------

test "wasm.exec globals get and set" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft("", I32), ft(I32, I32), ft("", I64), ft("", F32), ft("", F64) }) ++
        funcSec(&.{ 0, 1, 2, 3, 4 }) ++
        globalSec(&.{ glob(I32, true, i32c(42)), glob(I64, false, i64c(-7)), glob(F32, true, f32c(1.5)), glob(F64, false, f64c(-2.5)) }) ++
        codeSec(&.{
            "\x23\x00", // 0: global.get 0
            "\x20\x00\x24\x00\x23\x00", // 1: global.set 0; global.get 0
            "\x23\x01", // 2: global.get 1
            "\x23\x02", // 3: global.get 2
            "\x23\x03", // 4: global.get 3
        }));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(i32v(42), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(i32v(7), try run1(b.inst, 1, &.{7}));
    try std.testing.expectEqual(i32v(7), try run1(b.inst, 0, &.{})); // mutation persists
    try std.testing.expectEqual(i64v(-7), try run1(b.inst, 2, &.{}));
    try std.testing.expectEqual(f32v(1.5), try run1(b.inst, 3, &.{}));
    try std.testing.expectEqual(f64v(-2.5), try run1(b.inst, 4, &.{}));
}

// -- Stack exhaustion --------------------------------------------------------------

test "wasm.exec call stack exhaustion traps without crashing" {
    const mod_bytes = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++ codeSec(&.{"\x10\x00"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectError(error.Trap, invoke(inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("call stack exhausted", diag.message());
}
