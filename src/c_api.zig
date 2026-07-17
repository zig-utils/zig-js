//! JavaScriptCore-shaped C API subset, implemented in pure Zig.
//!
//! These `export fn` symbols mirror Apple's `<JavaScriptCore/JSValueRef.h>` and
//! `<JSObjectRef.h>` names closely enough for embedders that only use the
//! implemented public subset to try this library in place of
//! `JavaScriptCore.framework` (e.g. `~/Code/Home/lang`'s
//! `packages/runtime/src/jsc/extern_fns.zig`). Pre-stabilization API cleanup
//! should prefer clear zig-js contracts over preserving inert compatibility
//! parameters.
//!
//! Internally a `JSValueRef` is a pointer to a `Boxed` value living in the
//! Context arena; a `JSStringRef` is a reference-counted `JsString`.
//!
//! ## Threading rules
//!
//! Every handle is affine to its context group and creator thread. Values may be
//! exchanged by distinct global contexts in the same `JSContextGroupRef`; APIs
//! reject handles from another group. Cross-thread use is still
//! undefined behavior (the arena, object graph, and microtask queue are
//! unsynchronized by design); debug builds panic on it.
//! The supported multithreading pattern is one context per thread, sharing
//! only `SharedArrayBuffer` storage — see docs/threads/bindings.md and
//! https://github.com/zig-utils/zig-js/issues/1 for the worker/agent roadmap.
//! The `JSWorker*` surface (below) spawns such per-thread contexts and moves
//! values between them as structured-clone bytes.
//! `JSStringRef`s are immutable and retain/release is atomic, so references may
//! be created, retained, and released on any thread.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");
const gc_mod = @import("gc.zig");
const value = @import("value.zig");
const ContextMod = @import("context.zig");
const interp = @import("interpreter.zig");
const builtins = @import("builtins.zig");
const promise = @import("promise.zig");
const vm = @import("vm.zig");
const strcell = @import("strcell.zig");
const private_encoded_value = @import("private_abi/encoded_value.zig");
const private_jstype = @import("private_abi/jstype.zig");
const WorkerMod = @import("worker.zig");
const JsString = @import("jsstring.zig").JsString;

const Context = ContextMod.Context;
const Value = value.Value;
const Object = value.Object;
const EncodedValue = private_encoded_value.EncodedValue;

/// Global allocator for C-API-created contexts and strings. `page_allocator`
/// needs no libc and is always available; a tuned allocator can replace it.
const gpa = std.heap.page_allocator;

/// Boxed interpreter value handed across the C boundary as a `JSValueRef`.
/// Handles are realm-affine: APIs that receive a `JSContextRef` reject boxes
/// created by another context instead of silently mixing arenas/object graphs.
const Boxed = struct {
    /// Keep `value` first: the GC root scanner treats a protected `*Boxed` as
    /// a `*Value` when tracing C-API handles.
    value: Value,
    owner: *Context,
};

const ReachabilityCell = struct {
    pointer: *anyopaque,
    kind: gc_mod.CellKind,
};

const ReachabilityVisitor = struct {
    allocator: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(usize, void) = .empty,
    queue: std.ArrayListUnmanaged(ReachabilityCell) = .empty,
    objects: std.ArrayListUnmanaged(*Object) = .empty,

    fn deinit(self: *ReachabilityVisitor) void {
        self.seen.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.objects.deinit(self.allocator);
    }

    pub fn concurrent(_: *ReachabilityVisitor) bool { return false; }
    pub fn markWeak(_: *ReachabilityVisitor, _: *?*anyopaque) void {}
    pub fn deferToFinish(_: *ReachabilityVisitor, _: *anyopaque) void {}
    pub fn isManaged(_: *ReachabilityVisitor, cell: ?*anyopaque) bool { return cell != null; }
    pub fn markConservativeWord(_: *ReachabilityVisitor, _: usize) void {}
    pub fn markConservativeWords(_: *ReachabilityVisitor, _: [*]const usize, _: usize) void {}

    pub fn isMarked(self: *ReachabilityVisitor, cell: ?*anyopaque) bool {
        return if (cell) |pointer| self.seen.contains(@intFromPtr(pointer)) else false;
    }

    pub fn mark(self: *ReachabilityVisitor, maybe_cell: anytype) void {
        const cell = switch (@typeInfo(@TypeOf(maybe_cell))) {
            .optional => maybe_cell orelse return,
            .pointer => maybe_cell,
            else => @compileError("reachability mark expects a cell pointer"),
        };
        const Pointer = @TypeOf(cell);
        const kind: gc_mod.CellKind = if (Pointer == *Object)
            .object
        else if (Pointer == *interp.Environment)
            .environment
        else if (Pointer == *interp.Function)
            .function
        else if (Pointer == *interp.Interpreter.BoundFn)
            .bound_fn
        else if (Pointer == *promise.Promise)
            .promise
        else if (Pointer == *vm.Generator)
            .generator
        else if (Pointer == *value.IterHelper)
            .iter_helper
        else if (Pointer == *interp.ModuleNs)
            .module_ns
        else
            @compileError("unclassified reachability cell " ++ @typeName(Pointer));
        const pointer: *anyopaque = @ptrCast(cell);
        const result = self.seen.getOrPut(self.allocator, @intFromPtr(pointer)) catch return;
        if (result.found_existing) return;
        self.queue.append(self.allocator, .{ .pointer = pointer, .kind = kind }) catch return;
        if (kind == .object)
            self.objects.append(self.allocator, @ptrCast(@alignCast(pointer))) catch return;
    }

    fn drain(self: *ReachabilityVisitor) void {
        var index: usize = 0;
        while (index < self.queue.items.len) : (index += 1) {
            const cell = self.queue.items[index];
            switch (cell.kind) {
                .function => {
                    const function: *interp.Function = @ptrCast(@alignCast(cell.pointer));
                    self.mark(function.closure);
                    self.mark(function.realm_global);
                    gc_mod.traceFunction(function, self);
                },
                .environment => {
                    const environment: *interp.Environment = @ptrCast(@alignCast(cell.pointer));
                    self.mark(environment.parent);
                    var aliases = environment.aliases.valueIterator();
                    while (aliases.next()) |alias| self.mark(alias.env);
                    gc_mod.traceEnv(environment, self);
                },
                else => gc_mod.Binding.trace(cell.pointer, cell.kind, self),
            }
        }
    }

    fn finishEphemerons(self: *ReachabilityVisitor) void {
        while (true) {
            const before = self.queue.items.len;
            for (self.objects.items) |object| gc_mod.traceObjectEphemeron(object, self);
            self.drain();
            if (self.queue.items.len == before) return;
        }
    }
};

/// One public JavaScriptCore VM lifetime. The hidden primary Context owns the
/// shared arena/JIT runtime; every exposed global context is a distinct realm on
/// that runtime and retains this record until its own final release.
const CContextGroup = struct {
    ref_count: std.atomic.Value(usize) = .init(1),
    owner_thread: std.Thread.Id,
    primary: *Context,
    contexts: std.ArrayListUnmanaged(*Context) = .empty,
    collection_epoch: u64 = 0,

    fn retain(self: *CContextGroup) bool {
        var current = self.ref_count.load(.monotonic);
        while (true) {
            if (current == 0 or current == std.math.maxInt(usize)) return false;
            if (self.ref_count.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                current = observed;
                continue;
            }
            return true;
        }
    }

    fn release(self: *CContextGroup) bool {
        var current = self.ref_count.load(.acquire);
        while (true) {
            if (current == 0) return false;
            const next = current - 1;
            if (self.ref_count.cmpxchgWeak(current, next, .acq_rel, .acquire)) |observed| {
                current = observed;
                continue;
            }
            return next == 0;
        }
    }

    fn destroy(self: *CContextGroup) void {
        var index = self.contexts.items.len;
        while (index > 0) {
            index -= 1;
            self.contexts.items[index].destroySharedArenaRealm();
        }
        self.contexts.deinit(gpa);
        self.primary.c_api_group = null;
        self.primary.destroy();
        gpa.destroy(self);
    }
};

pub const ZJSInspectorMessageCallback = ?*const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;
pub const ZJSInspectorSessionRef = ?*anyopaque;

const CInspectorState = struct {
    context: *Context,
    sessions: std.ArrayListUnmanaged(*CInspectorSession) = .empty,
    scripts: std.ArrayListUnmanaged(CInspectorScript) = .empty,
    pause_requested: bool = false,
    paused: bool = false,
    breakpoints: std.ArrayListUnmanaged(CInspectorBreakpoint) = .empty,
    resolved_breakpoints: std.ArrayListUnmanaged(CInspectorResolvedBreakpoint) = .empty,
    next_breakpoint_id: u64 = 1,
    step_mode: CInspectorStepMode = .none,
    step_depth: u32 = 0,
    paused_depth: u32 = 0,
    paused_at_uncaught_boundary: bool = false,
    paused_machine: ?*interp.Interpreter = null,
    pause_owner: ?*CInspectorSession = null,
    next_pause_owner: ?*CInspectorSession = null,
    exception_mode: CInspectorExceptionMode = .none,
    next_exception_id: u64 = 1,
    remote_objects: std.ArrayListUnmanaged(CInspectorRemoteObject) = .empty,
    next_remote_object_id: u64 = 1,
    callback_depth: usize = 0,
    operation_depth: usize = 0,
    detached_resume_pending: bool = false,
    pause_wait_ctx: ?*anyopaque = null,
    pause_wait_hook: ?WorkerMod.InspectorPauseWaitHook = null,
};

const CInspectorStepMode = enum { none, into, over, out };
const CInspectorExceptionMode = enum { none, uncaught, all };

const CInspectorScript = Context.DebugScript;

const CInspectorBreakpointKind = enum { script, url };

const CInspectorBreakpoint = struct {
    id: u64,
    kind: CInspectorBreakpointKind,
    script_id: u64 = 0,
    url: []const u8 = "",
    line_number: usize,
    column_number: usize,
};

const InspectorProtocolLocation = struct {
    scriptId: u64,
    lineNumber: usize,
    columnNumber: usize,
    byteOffset: usize,
};

const InspectorRemoteValue = struct {
    type: []const u8,
    value: ?std.json.Value = null,
    description: []const u8,
    objectId: ?u64 = null,
};

const InspectorScopeBinding = struct {
    name: []const u8,
    value: InspectorRemoteValue,
};

const InspectorScope = struct {
    type: []const u8,
    name: []const u8,
    bindingCount: usize,
    bindings: []const InspectorScopeBinding,
    object: InspectorRemoteValue,
};

const InspectorCallFrame = struct {
    callFrameId: u64,
    functionName: []const u8,
    location: InspectorProtocolLocation,
    scopeChain: []const InspectorScope,
    this: InspectorRemoteValue,
};

const InspectorPropertyDescriptor = struct {
    name: []const u8,
    value: ?InspectorRemoteValue = null,
    get: ?InspectorRemoteValue = null,
    set: ?InspectorRemoteValue = null,
    writable: bool,
    enumerable: bool,
    configurable: bool,
    isOwn: bool = true,
};

const CInspectorResolvedBreakpoint = struct {
    breakpoint_id: u64,
    location: InspectorProtocolLocation,
};

const CInspectorSession = struct {
    state: *CInspectorState,
    callback: *const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
    attached: bool = true,
    runtime_enabled: bool = false,
    debugger_enabled: bool = false,
    release_requested: bool = false,
};

const CInspectorRemoteKind = union(enum) {
    value: JSValueRef,
    scope: *interp.Environment,
};

const CInspectorRemoteObject = struct {
    id: u64,
    owner: *CInspectorSession,
    kind: CInspectorRemoteKind,
    group: []u8,
    pause_only: bool,
};

/// JSC-shaped `JSType`. Values 0..6 match Apple's public enum; `bigint` and
/// `invalid` are zig-js extensions so the C boundary does not misreport BigInt
/// primitives or null handles as generic/undefined values.
pub const JSType = enum(c_uint) {
    undefined = 0,
    null = 1,
    boolean = 2,
    number = 3,
    string = 4,
    object = 5,
    symbol = 6,
    bigint = 7,
    invalid = 8,
};

/// Public JavaScriptCore `JSTypedArrayType` values. Keep the numeric layout in
/// lockstep with the macOS 27.0 SDK headers: embedders pass this enum across the
/// C ABI, so the declaration is deliberately non-exhaustive for defensive
/// handling of unknown future values.
pub const JSTypedArrayType = enum(c_uint) {
    int8_array = 0,
    int16_array = 1,
    int32_array = 2,
    uint8_array = 3,
    uint8_clamped_array = 4,
    uint16_array = 5,
    uint32_array = 6,
    float32_array = 7,
    float64_array = 8,
    array_buffer = 9,
    none = 10,
    bigint64_array = 11,
    biguint64_array = 12,
    _,
};

pub const JSRelationCondition = enum(c_uint) {
    undefined = 0,
    equal = 1,
    greater_than = 2,
    less_than = 3,
};

pub const kJSTypedArrayTypeInt8Array = JSTypedArrayType.int8_array;
pub const kJSTypedArrayTypeInt16Array = JSTypedArrayType.int16_array;
pub const kJSTypedArrayTypeInt32Array = JSTypedArrayType.int32_array;
pub const kJSTypedArrayTypeUint8Array = JSTypedArrayType.uint8_array;
pub const kJSTypedArrayTypeUint8ClampedArray = JSTypedArrayType.uint8_clamped_array;
pub const kJSTypedArrayTypeUint16Array = JSTypedArrayType.uint16_array;
pub const kJSTypedArrayTypeUint32Array = JSTypedArrayType.uint32_array;
pub const kJSTypedArrayTypeFloat32Array = JSTypedArrayType.float32_array;
pub const kJSTypedArrayTypeFloat64Array = JSTypedArrayType.float64_array;
pub const kJSTypedArrayTypeArrayBuffer = JSTypedArrayType.array_buffer;
pub const kJSTypedArrayTypeNone = JSTypedArrayType.none;
pub const kJSTypedArrayTypeBigInt64Array = JSTypedArrayType.bigint64_array;
pub const kJSTypedArrayTypeBigUint64Array = JSTypedArrayType.biguint64_array;

pub const JSValueRef = ?*anyopaque;
pub const JSObjectRef = ?*anyopaque;
pub const JSContextRef = ?*anyopaque;
pub const JSContextGroupRef = ?*anyopaque;
pub const JSStringRef = ?*anyopaque;
pub const JSClassRef = ?*anyopaque;
pub const JSPropertyNameArrayRef = ?*anyopaque;
pub const JSPropertyNameAccumulatorRef = ?*anyopaque;
pub const ExceptionRef = [*c]JSValueRef;

pub const JSObjectInitializeCallback = ?*const fn (JSContextRef, JSObjectRef) callconv(.c) void;
pub const JSObjectFinalizeCallback = ?*const fn (JSObjectRef) callconv(.c) void;
pub const JSObjectHasPropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef) callconv(.c) bool;
pub const JSObjectGetPropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef, ExceptionRef) callconv(.c) JSValueRef;
pub const JSObjectSetPropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef, JSValueRef, ExceptionRef) callconv(.c) bool;
pub const JSObjectDeletePropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef, ExceptionRef) callconv(.c) bool;
pub const JSObjectGetPropertyNamesCallback = ?*const fn (JSContextRef, JSObjectRef, JSPropertyNameAccumulatorRef) callconv(.c) void;

pub const JSObjectCallAsFunctionCallback = ?*const fn (
    ctx: JSContextRef,
    function: JSObjectRef,
    this_object: JSObjectRef,
    argument_count: usize,
    arguments: [*c]const JSValueRef,
    exception: ExceptionRef,
) callconv(.c) JSValueRef;

pub const JSObjectCallAsConstructorCallback = ?*const fn (JSContextRef, JSObjectRef, usize, [*c]const JSValueRef, ExceptionRef) callconv(.c) JSObjectRef;
pub const JSObjectHasInstanceCallback = ?*const fn (JSContextRef, JSObjectRef, JSValueRef, ExceptionRef) callconv(.c) bool;
pub const JSObjectConvertToTypeCallback = ?*const fn (JSContextRef, JSObjectRef, JSType, ExceptionRef) callconv(.c) JSValueRef;

pub const JSStaticValue = extern struct {
    name: ?[*:0]const u8 = null,
    get_property: JSObjectGetPropertyCallback = null,
    set_property: JSObjectSetPropertyCallback = null,
    attributes: c_uint = 0,
};

pub const JSStaticFunction = extern struct {
    name: ?[*:0]const u8 = null,
    call_as_function: JSObjectCallAsFunctionCallback = null,
    attributes: c_uint = 0,
};

pub const JSClassDefinition = extern struct {
    version: c_int = 0,
    attributes: c_uint = 0,
    class_name: ?[*:0]const u8 = null,
    parent_class: JSClassRef = null,
    static_values: [*c]const JSStaticValue = null,
    static_functions: [*c]const JSStaticFunction = null,
    initialize: JSObjectInitializeCallback = null,
    finalize: JSObjectFinalizeCallback = null,
    has_property: JSObjectHasPropertyCallback = null,
    get_property: JSObjectGetPropertyCallback = null,
    set_property: JSObjectSetPropertyCallback = null,
    delete_property: JSObjectDeletePropertyCallback = null,
    get_property_names: JSObjectGetPropertyNamesCallback = null,
    call_as_function: JSObjectCallAsFunctionCallback = null,
    call_as_constructor: JSObjectCallAsConstructorCallback = null,
    has_instance: JSObjectHasInstanceCallback = null,
    convert_to_type: JSObjectConvertToTypeCallback = null,
};

pub const kJSClassAttributeNone: c_uint = 0;
pub const kJSClassAttributeNoAutomaticPrototype: c_uint = 1 << 1;
export const kJSClassDefinitionEmpty: JSClassDefinition = .{};

pub const JSTypedArrayBytesDeallocator = ?value.ExternalBufferDeallocator;

pub const kJSPropertyAttributeNone: c_uint = 0;
pub const kJSPropertyAttributeReadOnly: c_uint = 1 << 1;
pub const kJSPropertyAttributeDontEnum: c_uint = 1 << 2;
pub const kJSPropertyAttributeDontDelete: c_uint = 1 << 3;

const CClass = struct {
    ref_count: std.atomic.Value(usize) = .init(1),
    definition: JSClassDefinition,
    class_name: ?[:0]u8 = null,
    static_values: []JSStaticValue = &.{},
    static_functions: []JSStaticFunction = &.{},
    parent: ?*CClass = null,
};

const PropertyNameAccumulator = struct {
    names: std.ArrayListUnmanaged(*JsString) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    failed: bool = false,

    fn addBytes(self: *PropertyNameAccumulator, bytes: []const u8) void {
        if (self.failed or self.seen.contains(bytes)) return;
        const string = JsString.create(gpa, bytes) catch {
            self.failed = true;
            return;
        };
        self.seen.put(gpa, string.bytes, {}) catch {
            string.release();
            self.failed = true;
            return;
        };
        self.names.append(gpa, string) catch {
            _ = self.seen.remove(string.bytes);
            string.release();
            self.failed = true;
        };
    }

    fn deinit(self: *PropertyNameAccumulator) void {
        for (self.names.items) |name| name.release();
        self.names.deinit(gpa);
        self.seen.deinit(gpa);
        self.* = .{};
    }
};

const PropertyNameArray = struct {
    ref_count: std.atomic.Value(usize) = .init(1),
    names: []*JsString,
};

fn propertyNameArrayFrom(ref: JSPropertyNameArrayRef) ?*PropertyNameArray {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn destroyPropertyNameArray(array: *PropertyNameArray) void {
    for (array.names) |name| name.release();
    gpa.free(array.names);
    gpa.destroy(array);
}

fn classFrom(ref: JSClassRef) ?*CClass {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn retainClass(class: *CClass) bool {
    var current = class.ref_count.load(.acquire);
    while (true) {
        if (current == std.math.maxInt(usize)) return false;
        if (class.ref_count.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
            current = actual;
        } else return true;
    }
}

fn destroyClass(class: *CClass) void {
    for (class.static_values) |entry| if (entry.name) |name| gpa.free(std.mem.span(name));
    for (class.static_functions) |entry| if (entry.name) |name| gpa.free(std.mem.span(name));
    if (class.static_values.len > 0) gpa.free(class.static_values);
    if (class.static_functions.len > 0) gpa.free(class.static_functions);
    if (class.class_name) |name| gpa.free(name);
    if (class.parent) |parent| releaseClass(parent);
    gpa.destroy(class);
}

fn releaseClass(class: *CClass) void {
    var current = class.ref_count.load(.acquire);
    while (true) {
        std.debug.assert(current > 0);
        if (class.ref_count.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |actual| {
            current = actual;
        } else {
            if (current == 1) destroyClass(class);
            return;
        }
    }
}

fn dupeCString(bytes: []const u8) ![:0]u8 {
    const out = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(out, bytes);
    return out;
}

fn copyStaticValues(source: [*c]const JSStaticValue) ![]JSStaticValue {
    if (source == null) return &.{};
    var count: usize = 0;
    while (source[count].name != null) : (count += 1) {}
    if (count == 0) return &.{};
    const out = try gpa.alloc(JSStaticValue, count + 1);
    errdefer gpa.free(out);
    var copied: usize = 0;
    errdefer for (out[0..copied]) |entry| if (entry.name) |name| gpa.free(std.mem.span(name));
    while (copied < count) : (copied += 1) {
        out[copied] = source[copied];
        const owned = try dupeCString(std.mem.span(source[copied].name.?));
        out[copied].name = owned.ptr;
    }
    out[count] = .{};
    return out;
}

fn copyStaticFunctions(source: [*c]const JSStaticFunction) ![]JSStaticFunction {
    if (source == null) return &.{};
    var count: usize = 0;
    while (source[count].name != null) : (count += 1) {}
    if (count == 0) return &.{};
    const out = try gpa.alloc(JSStaticFunction, count + 1);
    errdefer gpa.free(out);
    var copied: usize = 0;
    errdefer for (out[0..copied]) |entry| if (entry.name) |name| gpa.free(std.mem.span(name));
    while (copied < count) : (copied += 1) {
        out[copied] = source[copied];
        const owned = try dupeCString(std.mem.span(source[copied].name.?));
        out[copied].name = owned.ptr;
    }
    out[count] = .{};
    return out;
}

fn finishClassObject(owner: *value.CApiObjectOwner) void {
    const class = classFrom(owner.class_ref).?;
    if (owner.object_ref) |object_ref| {
        var current: ?*CClass = class;
        while (current) |item| : (current = item.parent) {
            if (item.definition.finalize) |finalize| finalize(object_ref);
        }
    }
    releaseClass(class);
}

fn initializeClassObject(ctx: JSContextRef, object_ref: JSObjectRef, class: *CClass) void {
    if (class.parent) |parent| initializeClassObject(ctx, object_ref, parent);
    if (class.definition.initialize) |initialize| initialize(ctx, object_ref);
}

fn attachClassToExistingObject(ctx: JSContextRef, c: *Context, obj: *Object, class: *CClass, data: ?*anyopaque) bool {
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return false;
    defer c.popActiveInterpreter(&machine);

    if ((class.definition.attributes & kJSClassAttributeNoAutomaticPrototype) != 0) {
        installStaticFunctionChain(c, &machine, obj, class) catch return false;
    } else {
        const prototype = ensureClassPrototype(c, &machine, class) catch return false;
        obj.setProtoAtomic(prototype);
    }
    if (!retainClass(class)) return false;
    const owner = c.createCApiObjectOwner(@ptrCast(class), finishClassObject) catch {
        releaseClass(class);
        return false;
    };
    obj.private_data = data;
    obj.private_data_tag = .host;
    obj.setCApiObjectClass(c.arena(), owner, &c_api_class_hooks) catch {
        owner.finishOnce();
        return false;
    };
    const object_ref = box(c, Value.obj(obj)) orelse {
        owner.finishOnce();
        return false;
    };
    owner.object_ref = object_ref;
    const protected = valueProtect(ctx, object_ref);
    defer {
        if (protected) _ = valueUnprotect(ctx, object_ref);
    }
    initializeClassObject(ctx, object_ref, class);
    return true;
}

fn finishClassPrototype(owner: *value.CApiClassPrototypeOwner) void {
    releaseClass(classFrom(owner.class_ref).?);
}

const CApiConstructorData = struct {
    context: *Context,
    class: ?*CClass,
    callback: JSObjectCallAsConstructorCallback,
    constructor_ref: JSObjectRef = null,
};

fn finishCApiConstructor(owner: *value.CApiObjectOwner) void {
    const data: *CApiConstructorData = @ptrCast(@alignCast(owner.payload.?));
    if (data.class) |class| releaseClass(class);
}

fn cApiConstructorData(object: *const Object) ?*CApiConstructorData {
    const owner = object.cApiObjectOwner() orelse return null;
    return @ptrCast(@alignCast(owner.payload orelse return null));
}

fn cApiConstructorIsConstructor(object: *const Object) bool {
    return cApiConstructorData(object) != null;
}

fn cApiConstructorConstruct(
    raw_machine: *anyopaque,
    object: *Object,
    args: []const Value,
) value.HostError!Value {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const data = cApiConstructorData(object) orelse {
        machine.exception = Value.str("TypeError: constructor metadata is missing");
        return error.Throw;
    };
    if (data.callback) |callback| {
        const js_args = try machine.arena.alloc(JSValueRef, args.len);
        for (args, js_args) |arg, *slot| slot.* = box(data.context, arg) orelse return error.OutOfMemory;
        var exception: JSValueRef = null;
        const result = callback(
            @ptrCast(data.context),
            data.constructor_ref,
            js_args.len,
            js_args.ptr,
            &exception,
        );
        try applyCallbackException(machine, data.context, exception);
        const result_ref = result orelse {
            machine.exception = Value.str("TypeError: constructor callback returned null without exception");
            return error.Throw;
        };
        const result_value = valueFromContext(data.context, result_ref) orelse {
            machine.exception = Value.str("TypeError: constructor callback returned an invalid object");
            return error.Throw;
        };
        if (!result_value.isObject() or result_value.asObj().is_symbol or result_value.asObj().is_bigint) {
            machine.exception = Value.str("TypeError: constructor callback returned a non-object");
            return error.Throw;
        }
        return result_value;
    }
    const class_ref: JSClassRef = if (data.class) |class| @ptrCast(class) else null;
    const result_ref = JSObjectMake(@ptrCast(data.context), class_ref, null) orelse {
        machine.exception = Value.str("OutOfMemory");
        return error.OutOfMemory;
    };
    return valueFromContext(data.context, result_ref).?;
}

const c_api_constructor_hooks: value.HostClassHooks = .{
    .is_constructor = cApiConstructorIsConstructor,
    .construct = cApiConstructorConstruct,
};

const ClassCallbackTarget = struct {
    context: *Context,
    object_ref: JSObjectRef,
    class: *CClass,
};

fn classCallbackTarget(machine: *interp.Interpreter, object: *Object) value.HostError!ClassCallbackTarget {
    const owner = object.cApiObjectOwner() orelse {
        machine.exception = Value.str("TypeError: class callback missing instance owner");
        return error.Throw;
    };
    const object_ref = owner.object_ref orelse {
        machine.exception = Value.str("TypeError: class callback missing object handle");
        return error.Throw;
    };
    const boxed = boxedFrom(object_ref) orelse {
        machine.exception = Value.str("TypeError: class callback has invalid object handle");
        return error.Throw;
    };
    return .{
        .context = boxed.owner,
        .object_ref = object_ref,
        .class = classFrom(owner.class_ref).?,
    };
}

fn callbackPropertyName(key: []const u8) value.HostError!JSStringRef {
    const string = JsString.create(gpa, key) catch return error.OutOfMemory;
    return @ptrCast(string);
}

fn applyCallbackException(
    machine: *interp.Interpreter,
    context: *Context,
    exception: JSValueRef,
) value.HostError!void {
    if (exception == null) return;
    machine.exception = valueFromContext(context, exception) orelse
        Value.str("TypeError: class callback set an invalid exception");
    return error.Throw;
}

fn callHasPropertyCallback(
    target: ClassCallbackTarget,
    key: []const u8,
    callback: *const fn (JSContextRef, JSObjectRef, JSStringRef) callconv(.c) bool,
) value.HostError!bool {
    const property_name = try callbackPropertyName(key);
    defer JSStringRelease(property_name);
    return callback(@ptrCast(target.context), target.object_ref, property_name);
}

fn callGetPropertyCallback(
    machine: *interp.Interpreter,
    target: ClassCallbackTarget,
    key: []const u8,
    callback: *const fn (JSContextRef, JSObjectRef, JSStringRef, ExceptionRef) callconv(.c) JSValueRef,
) value.HostError!?Value {
    const property_name = try callbackPropertyName(key);
    defer JSStringRelease(property_name);
    var exception: JSValueRef = null;
    const result = callback(@ptrCast(target.context), target.object_ref, property_name, &exception);
    try applyCallbackException(machine, target.context, exception);
    const result_ref = result orelse return null;
    return valueFromContext(target.context, result_ref) orelse {
        machine.exception = Value.str("TypeError: class getter returned an invalid value");
        return error.Throw;
    };
}

fn callSetPropertyCallback(
    machine: *interp.Interpreter,
    target: ClassCallbackTarget,
    key: []const u8,
    new_value: Value,
    callback: *const fn (JSContextRef, JSObjectRef, JSStringRef, JSValueRef, ExceptionRef) callconv(.c) bool,
) value.HostError!bool {
    const property_name = try callbackPropertyName(key);
    defer JSStringRelease(property_name);
    var exception: JSValueRef = null;
    const value_ref = box(target.context, new_value) orelse return error.OutOfMemory;
    const handled = callback(
        @ptrCast(target.context),
        target.object_ref,
        property_name,
        value_ref,
        &exception,
    );
    try applyCallbackException(machine, target.context, exception);
    return handled;
}

fn classGet(
    raw_machine: *anyopaque,
    object: *Object,
    key: []const u8,
) value.HostError!value.HostClassGetResult {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        if (item.definition.has_property) |has| {
            if (try callHasPropertyCallback(target, key, has)) {
                if (item.definition.get_property) |get| {
                    if (try callGetPropertyCallback(machine, target, key, get)) |result|
                        return .{ .value = result };
                }
            }
        } else if (item.definition.get_property) |get| {
            if (try callGetPropertyCallback(machine, target, key, get)) |result|
                return .{ .value = result };
        }
        for (item.static_values) |entry| {
            const name = entry.name orelse continue;
            if (!std.mem.eql(u8, std.mem.span(name), key)) continue;
            const getter = entry.get_property orelse return .unhandled;
            if (try callGetPropertyCallback(machine, target, key, getter)) |result|
                return .{ .value = result };
        }
    }
    return .unhandled;
}

fn classSet(
    raw_machine: *anyopaque,
    object: *Object,
    key: []const u8,
    new_value: Value,
) value.HostError!value.HostClassSetResult {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        var has_static_value = false;
        for (item.static_values) |entry| {
            const name = entry.name orelse continue;
            if (std.mem.eql(u8, std.mem.span(name), key)) {
                has_static_value = true;
                break;
            }
        }
        if (!has_static_value) {
            if (item.definition.has_property) |has|
                _ = try callHasPropertyCallback(target, key, has);
        }
        if (item.definition.set_property) |set| {
            if (try callSetPropertyCallback(machine, target, key, new_value, set))
                return .{ .accepted = true };
        }
        for (item.static_values) |entry| {
            const name = entry.name orelse continue;
            if (!std.mem.eql(u8, std.mem.span(name), key)) continue;
            const setter = entry.set_property orelse return if ((entry.attributes & kJSPropertyAttributeReadOnly) != 0)
                .{ .accepted = false }
            else
                .unhandled;
            const handled = try callSetPropertyCallback(machine, target, key, new_value, setter);
            return if (handled) .{ .accepted = true } else .declined;
        }
    }
    return .unhandled;
}

fn classHas(
    raw_machine: *anyopaque,
    object: *Object,
    key: []const u8,
) value.HostError!bool {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        if (item.definition.has_property) |has| {
            if (try callHasPropertyCallback(target, key, has)) return true;
        } else if (item.definition.get_property) |get| {
            if (try callGetPropertyCallback(machine, target, key, get) != null) return true;
        }
        for (item.static_values) |entry| {
            const name = entry.name orelse continue;
            if (!std.mem.eql(u8, std.mem.span(name), key)) continue;
            const getter = entry.get_property orelse continue;
            if (try callGetPropertyCallback(machine, target, key, getter) != null) return true;
        }
    }
    return false;
}

fn classDelete(
    raw_machine: *anyopaque,
    object: *Object,
    key: []const u8,
) value.HostError!value.HostClassDeleteResult {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        if (item.definition.delete_property) |callback| {
            const property_name = try callbackPropertyName(key);
            defer JSStringRelease(property_name);
            var exception: JSValueRef = null;
            const handled = callback(
                @ptrCast(target.context),
                target.object_ref,
                property_name,
                &exception,
            );
            try applyCallbackException(machine, target.context, exception);
            if (handled) return .{ .accepted = true };
        }
        for (item.static_values) |entry| {
            const name = entry.name orelse continue;
            if (!std.mem.eql(u8, std.mem.span(name), key)) continue;
            return .{ .accepted = (entry.attributes & kJSPropertyAttributeDontDelete) == 0 };
        }
    }
    return .unhandled;
}

fn staticValueAttributes(
    raw_machine: *anyopaque,
    object: *Object,
    key: []const u8,
) value.HostError!?value.PropAttr {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    var has_name_callback = false;
    while (class) |item| : (class = item.parent) {
        has_name_callback = has_name_callback or item.definition.get_property_names != null;
        for (item.static_values) |entry| {
            const name = entry.name orelse continue;
            if (std.mem.eql(u8, std.mem.span(name), key)) return propAttrFromC(entry.attributes);
        }
    }
    if (has_name_callback) return .{ .writable = false, .enumerable = true, .configurable = true };
    return null;
}

fn classOwnKeys(
    raw_machine: *anyopaque,
    object: *Object,
) value.HostError![]const []const u8 {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var accumulator: PropertyNameAccumulator = .{};
    defer accumulator.deinit();
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        if (item.definition.get_property_names) |callback| {
            callback(@ptrCast(target.context), target.object_ref, @ptrCast(&accumulator));
            if (accumulator.failed) return error.OutOfMemory;
        }
        for (item.static_values) |entry| {
            const name_ptr = entry.name orelse continue;
            accumulator.addBytes(std.mem.span(name_ptr));
            if (accumulator.failed) return error.OutOfMemory;
        }
    }
    const result = try machine.arena.alloc([]const u8, accumulator.names.items.len);
    for (accumulator.names.items, result) |name, *slot|
        slot.* = try machine.arena.dupe(u8, name.bytes);
    return result;
}

fn classForObject(object: *const Object) ?*CClass {
    const owner = object.cApiObjectOwner() orelse return null;
    return classFrom(owner.class_ref);
}

fn classIsCallable(object: *const Object) bool {
    var class: ?*CClass = classForObject(object);
    while (class) |item| : (class = item.parent)
        if (item.definition.call_as_function != null) return true;
    return false;
}

fn classIsConstructor(object: *const Object) bool {
    var class: ?*CClass = classForObject(object);
    while (class) |item| : (class = item.parent)
        if (item.definition.call_as_constructor != null) return true;
    return false;
}

fn classCall(
    raw_machine: *anyopaque,
    object: *Object,
    this_value: Value,
    args: []const Value,
) value.HostError!Value {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        const callback = item.definition.call_as_function orelse continue;
        const js_args = try machine.arena.alloc(JSValueRef, args.len);
        for (args, js_args) |arg, *slot| slot.* = box(target.context, arg) orelse return error.OutOfMemory;
        const this_ref = if (this_value.isObject() and !this_value.asObj().is_symbol and !this_value.asObj().is_bigint)
            box(target.context, this_value)
        else
            box(target.context, Value.obj(target.context.global_object));
        if (this_ref == null) return error.OutOfMemory;
        var exception: JSValueRef = null;
        const result = callback(
            @ptrCast(target.context),
            target.object_ref,
            this_ref,
            js_args.len,
            js_args.ptr,
            &exception,
        );
        try applyCallbackException(machine, target.context, exception);
        const result_ref = result orelse {
            machine.exception = Value.str("TypeError: class call callback returned null without exception");
            return error.Throw;
        };
        return valueFromContext(target.context, result_ref) orelse {
            machine.exception = Value.str("TypeError: class call callback returned an invalid value");
            return error.Throw;
        };
    }
    machine.exception = Value.str("TypeError: class object is not callable");
    return error.Throw;
}

fn classConstruct(
    raw_machine: *anyopaque,
    object: *Object,
    args: []const Value,
) value.HostError!Value {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        const callback = item.definition.call_as_constructor orelse continue;
        const js_args = try machine.arena.alloc(JSValueRef, args.len);
        for (args, js_args) |arg, *slot| slot.* = box(target.context, arg) orelse return error.OutOfMemory;
        var exception: JSValueRef = null;
        const result = callback(
            @ptrCast(target.context),
            target.object_ref,
            js_args.len,
            js_args.ptr,
            &exception,
        );
        try applyCallbackException(machine, target.context, exception);
        const result_ref = result orelse {
            machine.exception = Value.str("TypeError: class constructor callback returned null without exception");
            return error.Throw;
        };
        const result_value = valueFromContext(target.context, result_ref) orelse {
            machine.exception = Value.str("TypeError: class constructor callback returned an invalid object");
            return error.Throw;
        };
        if (!result_value.isObject() or result_value.asObj().is_symbol or result_value.asObj().is_bigint) {
            machine.exception = Value.str("TypeError: class constructor callback returned a non-object");
            return error.Throw;
        }
        return result_value;
    }
    machine.exception = Value.str("TypeError: class object is not a constructor");
    return error.Throw;
}

fn classHasInstance(
    raw_machine: *anyopaque,
    object: *Object,
    candidate: Value,
) value.HostError!bool {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        const callback = item.definition.has_instance orelse continue;
        var exception: JSValueRef = null;
        const candidate_ref = box(target.context, candidate) orelse return error.OutOfMemory;
        const result = callback(
            @ptrCast(target.context),
            target.object_ref,
            candidate_ref,
            &exception,
        );
        try applyCallbackException(machine, target.context, exception);
        return result;
    }
    return false;
}

fn classConvert(
    raw_machine: *anyopaque,
    object: *Object,
    hint: value.HostClassConvertHint,
) value.HostError!Value {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
    const target = try classCallbackTarget(machine, object);
    var class: ?*CClass = target.class;
    while (class) |item| : (class = item.parent) {
        const callback = item.definition.convert_to_type orelse continue;
        var exception: JSValueRef = null;
        const result = callback(
            @ptrCast(target.context),
            target.object_ref,
            if (hint == .string) .string else .number,
            &exception,
        );
        try applyCallbackException(machine, target.context, exception);
        const result_ref = result orelse {
            machine.exception = Value.str("TypeError: class conversion callback returned null without exception");
            return error.Throw;
        };
        return valueFromContext(target.context, result_ref) orelse {
            machine.exception = Value.str("TypeError: class conversion callback returned an invalid value");
            return error.Throw;
        };
    }
    machine.exception = Value.str("TypeError: class object has no conversion callback");
    return error.Throw;
}

const c_api_class_hooks: value.HostClassHooks = .{
    .get = classGet,
    .set = classSet,
    .has = classHas,
    .delete = classDelete,
    .attributes = staticValueAttributes,
    .own_keys = classOwnKeys,
    .is_callable = classIsCallable,
    .is_constructor = classIsConstructor,
    .call = classCall,
    .construct = classConstruct,
    .has_instance = classHasInstance,
    .convert = classConvert,
};

// ---- internal helpers --------------------------------------------------

fn ctxRawFrom(ref: JSContextRef) ?*Context {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn ctxFrom(ref: JSContextRef) ?*Context {
    const c = ctxRawFrom(ref) orelse return null;
    if (c.c_api_group != null and c.c_api_ref_count.load(.acquire) == 0) return null;
    // Single funnel for every C-API entry point: enforce context thread
    // affinity in debug builds (see "Threading rules" above).
    c.assertOwnerThread();
    return c;
}

fn ctxForHandleInspection(ref: JSContextRef) ?*Context {
    const c = ctxRawFrom(ref) orelse return null;
    if (c.c_api_group != null and c.c_api_ref_count.load(.acquire) == 0) return null;
    if (comptime builtin.mode == .Debug) {
        if (!c.isOwnerThread()) std.debug.panic(
            "Context is single-thread-affine: used from thread {d}, owned by thread {d} (docs/threads/bindings.md)",
            .{ std.Thread.getCurrentId(), c.owner_thread },
        );
    }
    return c;
}

fn ctxForEvaluation(ref: JSContextRef) ?*Context {
    const c = ctxRawFrom(ref) orelse return null;
    if (c.c_api_group != null and c.c_api_ref_count.load(.acquire) == 0) return null;
    if (comptime builtin.mode == .Debug) {
        // Serialized threaded contexts acquire the GIL inside
        // `Context.evaluateWithThis`, then assert that ownership there. For
        // non-threaded and true-parallel C contexts, preserve the documented
        // C-handle affinity before touching the unsynchronized host boundary.
        if (c.gil == null or c.parallel_js) {
            if (!c.isOwnerThread()) std.debug.panic(
                "Context is single-thread-affine: used from thread {d}, owned by thread {d} (docs/threads/bindings.md)",
                .{ std.Thread.getCurrentId(), c.owner_thread },
            );
        }
    }
    return c;
}

fn ctxForLifecycle(ref: JSContextRef) ?*Context {
    const c = ctxRawFrom(ref) orelse return null;
    if (c.c_api_group != null and c.c_api_ref_count.load(.acquire) == 0) return null;
    if (comptime builtin.mode == .Debug) {
        // Retain/release are host lifecycle operations, not VM execution. They
        // must preserve context thread-affinity without requiring the serialized
        // GIL to already be held.
        if (!c.isOwnerThread()) std.debug.panic(
            "Context is single-thread-affine: used from thread {d}, owned by thread {d} (docs/threads/bindings.md)",
            .{ std.Thread.getCurrentId(), c.owner_thread },
        );
    }
    return c;
}

fn box(ctx: *Context, v: Value) JSValueRef {
    const b = ctx.arena().create(Boxed) catch return null;
    b.* = .{ .value = v, .owner = ctx };
    return @ptrCast(b);
}

fn boxedFrom(ref: JSValueRef) ?*Boxed {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn privateBoxedFrom(encoded: EncodedValue) ?*Boxed {
    const address = encoded.asCellAddress() catch return null;
    const boxed: *Boxed = @ptrFromInt(address);
    if (boxed.owner.c_api_group == null or boxed.owner.c_api_ref_count.load(.acquire) == 0)
        return null;
    boxed.owner.assertOwnerThread();
    return boxed;
}

fn privateEncodedFromRef(ref: JSValueRef) EncodedValue {
    const pointer = ref orelse return .empty;
    return EncodedValue.fromCellAddress(@intFromPtr(pointer)) catch .empty;
}

fn privateValueFrom(global: JSContextRef, encoded: EncodedValue) ?Value {
    const context = ctxForHandleInspection(global) orelse return null;
    return encoded.toInternalPrimitive(Value) catch |err| switch (err) {
        error.CellRequiresHandle => {
            const boxed = privateBoxedFrom(encoded) orelse return null;
            if (boxed.owner != context) {
                const group = context.c_api_group orelse return null;
                if (boxed.owner.c_api_group != group) return null;
            }
            return boxed.value;
        },
        else => null,
    };
}

fn privateBigIntModuloU64(object: *Object) u64 {
    if (object.bigIntText()) |text| {
        const negative = text.len > 0 and text[0] == '-';
        var result: u64 = 0;
        for (text[@intFromBool(negative)..]) |digit| {
            if (digit < '0' or digit > '9') return 0;
            result = result *% 10 +% (digit - '0');
        }
        return if (negative) 0 -% result else result;
    }
    return @truncate(@as(u128, @bitCast(object.bigIntValue())));
}

fn privateObjectJSType(object: *Object) private_jstype.Kind {
    if (object.is_symbol) return .Symbol;
    if (object.is_bigint) return .HeapBigInt;
    if (object.behavior.is_error) return .ErrorInstance;
    if (object.arrayBuffer() != null) return .ArrayBuffer;
    if (object.typedArray()) |typed_array| return switch (typed_array.kind) {
        .i8 => .Int8Array,
        .u8 => .Uint8Array,
        .u8c => .Uint8ClampedArray,
        .i16 => .Int16Array,
        .u16 => .Uint16Array,
        .i32 => .Int32Array,
        .u32 => .Uint32Array,
        .f16 => .Float16Array,
        .f32 => .Float32Array,
        .f64 => .Float64Array,
        .i64 => .BigInt64Array,
        .u64 => .BigUint64Array,
    };
    if (object.dataView() != null) return .DataView;
    if (object.moduleNs() != null) return .ModuleNamespaceObject;
    if (object.behavior.is_shadow_realm) return .ShadowRealm;
    if (object.behavior.is_regex) return .RegExpObject;
    if (object.behavior.is_date) return .JSDate;
    if (object.proxy_revoked or object.proxyTarget() != null) return .ProxyObject;
    if (object.generator() != null) return .Generator;
    if (object.iteratorHelper() != null) return .IteratorHelper;
    if (object.promiseData() != null) return .JSPromise;
    if (object.is_map) return if (object.is_weak) .WeakMap else .Map;
    if (object.is_set) return if (object.is_weak) .WeakSet else .Set;
    if (object.is_arguments) return .DirectArguments;
    if (object.is_array) return .Array;
    if (object.boxedPrimitive()) |primitive| return switch (primitive.kind()) {
        .boolean => .BooleanObject,
        .number => .NumberObject,
        .string => .StringObject,
        else => .FinalObject,
    };
    if (object.jsFunction() != null) return .JSFunction;
    if (object.isCallableObject()) return .InternalFunction;
    return .FinalObject;
}

fn privateJSType(encoded: EncodedValue) u8 {
    const boxed = privateBoxedFrom(encoded) orelse return 0;
    const kind: private_jstype.Kind = switch (boxed.value.kind()) {
        .string => .String,
        .object => privateObjectJSType(boxed.value.asObj()),
        else => return 0,
    };
    return private_jstype.selectedTag(kind);
}

/// First revision-pinned Home private-ABI slice. These symbols consume JSC64
/// words, not zig-js's internal NaN-box representation.
export fn JSC__JSValue__eqlCell(encoded: EncodedValue, cell: ?*anyopaque) callconv(.c) bool {
    const address = encoded.asCellAddress() catch return false;
    return cell != null and address == @intFromPtr(cell.?);
}

export fn JSC__JSValue__eqlValue(left: EncodedValue, right: EncodedValue) callconv(.c) bool {
    return left.rawBits() == right.rawBits();
}

export fn JSC__JSValue__toInt32(encoded: EncodedValue) callconv(.c) i32 {
    return if (encoded.isInt32()) encoded.asInt32() else 0;
}

export fn JSC__JSValue__toBoolean(encoded: EncodedValue) callconv(.c) bool {
    const decoded = encoded.toInternalPrimitive(Value) catch |conversion_error| switch (conversion_error) {
        error.CellRequiresHandle => {
            const boxed = privateBoxedFrom(encoded) orelse return false;
            // Bun's pinned shim uses pureToBoolean() and deliberately counts
            // masquerades-as-undefined objects as true at this boundary.
            if (boxed.value.isObject() and boxed.value.asObj().behavior.is_htmldda) return true;
            return boxed.value.toBoolean();
        },
        else => return false,
    };
    return decoded.toBoolean();
}

export fn JSC__JSValue__fromInt64NoTruncate(global: JSContextRef, number: i64) callconv(.c) EncodedValue {
    return privateEncodedFromRef(JSBigIntCreateWithInt64(global, number, null));
}

export fn JSC__JSValue__fromUInt64NoTruncate(global: JSContextRef, number: u64) callconv(.c) EncodedValue {
    return privateEncodedFromRef(JSBigIntCreateWithUInt64(global, number, null));
}

export fn JSC__JSValue__toUInt64NoTruncate(encoded: EncodedValue) callconv(.c) u64 {
    if (encoded.isInt32()) return @bitCast(@as(i64, encoded.asInt32()));
    if (encoded.isDouble()) {
        const number = encoded.asDouble();
        const int52_limit: f64 = @floatFromInt(@as(u64, 1) << 51);
        if (!std.math.isFinite(number) or @trunc(number) != number or
            number < 0 or number >= int52_limit)
            return 0;
        return @intFromFloat(number);
    }
    const boxed = privateBoxedFrom(encoded) orelse return 0;
    if (!boxed.value.isObject() or !boxed.value.asObj().is_bigint) return 0;
    return privateBigIntModuloU64(boxed.value.asObj());
}

export fn JSC__JSValue__isStrictEqual(
    left: EncodedValue,
    right: EncodedValue,
    global: JSContextRef,
) callconv(.c) bool {
    const lhs = privateValueFrom(global, left) orelse return false;
    const rhs = privateValueFrom(global, right) orelse return false;
    return value.strictEquals(lhs, rhs);
}

export fn JSC__JSValue__isSameValue(
    left: EncodedValue,
    right: EncodedValue,
    global: JSContextRef,
) callconv(.c) bool {
    const lhs = privateValueFrom(global, left) orelse return false;
    const rhs = privateValueFrom(global, right) orelse return false;
    return value.sameValue(lhs, rhs);
}

export fn JSC__JSValue__jsType(encoded: EncodedValue) callconv(.c) u8 {
    return privateJSType(encoded);
}

export fn JSC__JSCell__getType(cell: ?*anyopaque) callconv(.c) u8 {
    const pointer = cell orelse return 0;
    const encoded = EncodedValue.fromCellAddress(@intFromPtr(pointer)) catch return 0;
    return privateJSType(encoded);
}

fn valueFromContext(ctx: *Context, ref: JSValueRef) ?Value {
    const b = boxedFrom(ref) orelse return null;
    if (b.owner != ctx) {
        const group = ctx.c_api_group orelse return null;
        if (b.owner.c_api_group != group) return null;
    }
    return b.value;
}

fn objectFromHandleInspection(ref: JSObjectRef) ?*Object {
    const b = boxedFrom(ref) orelse return null;
    if (comptime builtin.mode == .Debug) {
        if (!b.owner.isOwnerThread()) std.debug.panic(
            "Context is single-thread-affine: used from thread {d}, owned by thread {d} (docs/threads/bindings.md)",
            .{ std.Thread.getCurrentId(), b.owner.owner_thread },
        );
    }
    return if (b.value.isObject()) b.value.asObj() else null;
}

fn valueArgFrom(ctx: *Context, ref: JSValueRef, exception: ExceptionRef) ?Value {
    if (valueFromContext(ctx, ref)) |v| return v;
    setException(ctx, exception, "TypeError: value is not a value");
    return null;
}

fn strFrom(ref: JSStringRef) ?*JsString {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn setException(ctx: *Context, exc: ExceptionRef, message: []const u8) void {
    if (exc != null) {
        const v = Value.strAlloc(ctx.arena(), message) catch Value.staticStr("OutOfMemory");
        exc[0] = box(ctx, v);
    }
}

fn setExceptionValue(ctx: *Context, exc: ExceptionRef, exception_value: Value) void {
    if (exc != null) exc[0] = box(ctx, exception_value);
}

fn boxResult(ctx: *Context, exception: ExceptionRef, result: Value) JSValueRef {
    return box(ctx, result) orelse {
        setException(ctx, exception, "OutOfMemory");
        return null;
    };
}

fn isEvaluationParseError(err: anyerror) bool {
    return switch (err) {
        error.UnexpectedCharacter,
        error.UnterminatedString,
        error.UnterminatedComment,
        error.InvalidNumber,
        error.UnexpectedToken,
        error.ExpectedToken,
        error.InvalidAssignmentTarget,
        => true,
        else => false,
    };
}

fn setDiagnosticField(ctx: *Context, obj: *Object, name: []const u8, field_value: Value) !void {
    try obj.setOwn(ctx.arena(), ctx.root_shape, name, field_value);
    try obj.setAttr(ctx.arena(), name, .{ .writable = true, .enumerable = false, .configurable = true });
}

fn makeEvaluationSyntaxError(
    ctx: *Context,
    message: []const u8,
    source_name: []const u8,
    line: usize,
    column: usize,
    byte_offset: usize,
) !Value {
    const gc_saved = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa_saved);

    var machine = ctx.interpreter();
    try ctx.pushActiveInterpreter(&machine);
    defer ctx.popActiveInterpreter(&machine);

    const err = try machine.makeError("SyntaxError", message);
    const obj = err.asObj();
    const source_name_copy = try ctx.arena().dupe(u8, source_name);
    try setDiagnosticField(ctx, obj, "sourceURL", try Value.strOwned(ctx.arena(), source_name_copy));
    try setDiagnosticField(ctx, obj, "line", Value.num(@floatFromInt(line)));
    try setDiagnosticField(ctx, obj, "column", Value.num(@floatFromInt(column)));
    try setDiagnosticField(ctx, obj, "byteOffset", Value.num(@floatFromInt(byte_offset)));
    return err;
}

fn evaluationSourceName(source_url: JSStringRef) []const u8 {
    return if (strFrom(source_url)) |s|
        if (s.bytes.len == 0) "<eval>" else s.bytes
    else
        "<eval>";
}

fn attachEvaluationRuntimeSourceMetadata(
    ctx: *Context,
    thrown: Value,
    source_url: JSStringRef,
    starting_line_number: c_int,
) !void {
    if (!thrown.isObject()) return;
    const obj = thrown.asObj();
    if (!obj.behavior.is_error) return;
    if (source_url == null and starting_line_number <= 0) return;

    const gc_saved = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa_saved);

    const source_name = evaluationSourceName(source_url);
    const source_name_copy = try ctx.arena().dupe(u8, source_name);
    try setDiagnosticField(ctx, obj, "sourceURL", try Value.strOwned(ctx.arena(), source_name_copy));
    try setDiagnosticField(ctx, obj, "startingLineNumber", Value.num(@floatFromInt(if (starting_line_number > 0) starting_line_number else 1)));
}

fn setEvaluationException(ctx: *Context, exc: ExceptionRef, err: anyerror, source_url: JSStringRef, starting_line_number: c_int) void {
    if (isEvaluationParseError(err)) {
        if (ctx.last_evaluation_diagnostic) |loc| {
            const source_name = evaluationSourceName(source_url);
            const base_line: usize = if (starting_line_number > 0) @intCast(starting_line_number) else 1;
            const line = loc.line + base_line - 1;
            const message = std.fmt.allocPrint(ctx.arena(), "{s}: {s}:{d}:{d}", .{
                @errorName(err),
                source_name,
                line,
                loc.column,
            }) catch {
                setException(ctx, exc, @errorName(err));
                return;
            };
            const syntax_error = makeEvaluationSyntaxError(ctx, message, source_name, line, loc.column, loc.byte_offset) catch {
                setException(ctx, exc, message);
                return;
            };
            setExceptionValue(ctx, exc, syntax_error);
            return;
        }
    }
    setException(ctx, exc, @errorName(err));
}

fn propAttrFromC(attrs: c_uint) value.PropAttr {
    return .{
        .writable = (attrs & kJSPropertyAttributeReadOnly) == 0,
        .enumerable = (attrs & kJSPropertyAttributeDontEnum) == 0,
        .configurable = (attrs & kJSPropertyAttributeDontDelete) == 0,
    };
}

fn typedArrayKind(array_type: JSTypedArrayType) ?value.TAKind {
    return switch (array_type) {
        .int8_array => .i8,
        .int16_array => .i16,
        .int32_array => .i32,
        .uint8_array => .u8,
        .uint8_clamped_array => .u8c,
        .uint16_array => .u16,
        .uint32_array => .u32,
        .float32_array => .f32,
        .float64_array => .f64,
        .bigint64_array => .i64,
        .biguint64_array => .u64,
        .array_buffer, .none, _ => null,
    };
}

fn typedArrayTypeFromKind(kind: value.TAKind) JSTypedArrayType {
    return switch (kind) {
        .i8 => .int8_array,
        .i16 => .int16_array,
        .i32 => .int32_array,
        .u8 => .uint8_array,
        .u8c => .uint8_clamped_array,
        .u16 => .uint16_array,
        .u32 => .uint32_array,
        .f32 => .float32_array,
        .f64 => .float64_array,
        .i64 => .bigint64_array,
        .u64 => .biguint64_array,
        // Float16Array is implemented by the JS runtime but is not part of the
        // pinned public JSC enum, so it must not masquerade as another type.
        .f16 => .none,
    };
}

fn typedArrayTypeFromValue(v: Value) JSTypedArrayType {
    if (!v.isObject()) return .none;
    const obj = v.asObj();
    if (obj.typedArray()) |ta| return typedArrayTypeFromKind(ta.kind);
    if (obj.arrayBuffer() != null) return .array_buffer;
    return .none;
}

// ---- VM lifecycle ------------------------------------------------------

fn contextGroupFrom(ref: JSContextGroupRef) ?*CContextGroup {
    const group: *CContextGroup = @ptrCast(@alignCast(ref orelse return null));
    if (comptime builtin.mode == .Debug) {
        if (group.owner_thread != std.Thread.getCurrentId()) std.debug.panic(
            "JSContextGroupRef is thread-affine: used from thread {d}, owned by thread {d}",
            .{ std.Thread.getCurrentId(), group.owner_thread },
        );
    }
    return group;
}

export fn JSContextGroupCreate() callconv(.c) JSContextGroupRef {
    const primary = Context.create(gpa) catch return null;
    const group = gpa.create(CContextGroup) catch {
        primary.destroy();
        return null;
    };
    group.* = .{
        .owner_thread = std.Thread.getCurrentId(),
        .primary = primary,
    };
    primary.c_api_group = @ptrCast(group);
    return @ptrCast(group);
}

export fn JSContextGroupRetain(group_ref: JSContextGroupRef) callconv(.c) JSContextGroupRef {
    const group = contextGroupFrom(group_ref) orelse return null;
    return if (group.retain()) group_ref else null;
}

export fn JSContextGroupRelease(group_ref: JSContextGroupRef) callconv(.c) void {
    const group = contextGroupFrom(group_ref) orelse return;
    if (group.release()) group.destroy();
}

export fn JSGarbageCollect(ctx: JSContextRef) callconv(.c) void {
    // Real precise mark-sweep when the context has the GC enabled; a no-op on
    // the default arena engine. Sound here because the C-API entry point is a
    // quiescent point (no JS executing); embedder-held `JSValueRef`s that must
    // survive this call are rooted by JSValueProtect's counted handle table.
    const c = ctxFrom(ctx) orelse return;
    if (c.c_api_group) |opaque_group| {
        const group: *CContextGroup = @ptrCast(@alignCast(opaque_group));
        if (group.collection_epoch != std.math.maxInt(u64))
            group.collection_epoch += 1;
    }
    c.collectGarbage();
}

/// zig-js extension: monotonically counts explicit collection points for the
/// context group. Arena-backed groups use this epoch for semantic weak-value
/// processing even though physical storage remains VM-lifetime.
export fn ZJSContextGetCollectionEpoch(ctx: JSContextRef) callconv(.c) u64 {
    const c = ctxFrom(ctx) orelse return 0;
    const opaque_group = c.c_api_group orelse return 0;
    const group: *CContextGroup = @ptrCast(@alignCast(opaque_group));
    return group.collection_epoch;
}

/// zig-js extension: semantic reachability from every strong realm root in the
/// value's context group. WeakRef and weak-collection edges do not retain it.
export fn ZJSValueIsReachable(ctx: JSContextRef, value_ref: JSValueRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const value_to_find = valueFromContext(c, value_ref) orelse return false;
    if (!value_to_find.isObject()) return true;
    var visitor = ReachabilityVisitor{ .allocator = gpa };
    defer visitor.deinit();
    if (c.c_api_group) |opaque_group| {
        const group: *CContextGroup = @ptrCast(@alignCast(opaque_group));
        var primary_binding = gc_mod.Binding{ .context = group.primary };
        primary_binding.traceRoots(&visitor);
        for (group.contexts.items) |realm| {
            var binding = gc_mod.Binding{ .context = realm };
            binding.traceRoots(&visitor);
        }
    } else {
        var binding = gc_mod.Binding{ .context = c };
        binding.traceRoots(&visitor);
    }
    visitor.drain();
    visitor.finishEphemerons();
    return visitor.isMarked(value_to_find.asObj());
}

export fn JSGlobalContextCreate(global_class: ?*anyopaque) callconv(.c) JSContextRef {
    return JSGlobalContextCreateInGroup(null, global_class);
}

export fn JSGlobalContextCreateInGroup(group_ref: JSContextGroupRef, global_class: JSClassRef) callconv(.c) JSContextRef {
    const created_group = group_ref == null;
    const effective_ref = if (created_group) JSContextGroupCreate() else group_ref;
    const group = contextGroupFrom(effective_ref) orelse return null;
    if (!group.retain()) {
        if (created_group) JSContextGroupRelease(effective_ref);
        return null;
    }
    const ctx = Context.createSharedArenaRealm(group.primary) catch {
        if (group.release()) group.destroy();
        if (created_group) JSContextGroupRelease(effective_ref);
        return null;
    };
    ctx.c_api_group = @ptrCast(group);
    ctx.initCApiRef();
    const ctx_ref: JSContextRef = @ptrCast(ctx);
    if (global_class != null) {
        const class = classFrom(global_class) orelse {
            ctx.destroySharedArenaRealm();
            _ = group.release();
            if (created_group) JSContextGroupRelease(effective_ref);
            return null;
        };
        if (!attachClassToExistingObject(ctx_ref, ctx, ctx.global_object, class, null)) {
            ctx.destroySharedArenaRealm();
            _ = group.release();
            if (created_group) JSContextGroupRelease(effective_ref);
            return null;
        }
    }
    group.contexts.append(gpa, ctx) catch {
        ctx.destroySharedArenaRealm();
        _ = group.release();
        if (created_group) JSContextGroupRelease(effective_ref);
        return null;
    };
    if (created_group) JSContextGroupRelease(effective_ref);
    return ctx_ref;
}

/// zig-js extension (issue #1): create a context with the `Thread` API enabled.
/// With `gil == false` — the default execution model — spawned `Thread`s run
/// TRUE-parallel (no GIL), backed by the GC-managed thread-safe cell allocator;
/// with `gil == true` they're serialized behind the per-context GIL. Returns null
/// on failure. (`JSGlobalContextCreate` stays single-threaded for JSC parity.)
export fn ZJSGlobalContextCreateThreaded(gil: bool) callconv(.c) JSContextRef {
    const ctx = Context.createWith(gpa, .{ .enable_threads = true, .gil = gil }) catch return null;
    ctx.initCApiRef();
    return @ptrCast(ctx);
}

export fn JSGlobalContextRelease(ctx: JSContextRef) callconv(.c) void {
    // A `.gil = true` threaded context is released from outside JS execution;
    // `Context.destroy()` performs the serialized teardown itself.
    const c = ctxForLifecycle(ctx) orelse return;
    if (!c.releaseCApiRef()) return;
    if (c.c_api_group) |opaque_group| {
        const group: *CContextGroup = @ptrCast(@alignCast(opaque_group));
        if (group.release()) group.destroy();
    } else c.destroy();
}

export fn JSGlobalContextRetain(ctx: JSContextRef) callconv(.c) JSContextRef {
    const c = ctxForLifecycle(ctx) orelse return null;
    if (!c.retainCApiRef()) return null;
    return ctx;
}

export fn JSContextGetGlobalObject(ctx: JSContextRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, Value.obj(c.global_object));
}

export fn JSContextGetGroup(ctx: JSContextRef) callconv(.c) JSContextGroupRef {
    const c = ctxFrom(ctx) orelse return null;
    return c.c_api_group;
}

export fn JSContextGetGlobalContext(ctx: JSContextRef) callconv(.c) JSContextRef {
    _ = ctxFrom(ctx) orelse return null;
    return ctx;
}

export fn JSGlobalContextCopyName(ctx: JSContextRef) callconv(.c) JSStringRef {
    const c = ctxFrom(ctx) orelse return null;
    const units = c.c_api_name_utf16 orelse return null;
    const copy = JsString.createUtf16(gpa, units) catch return null;
    return @ptrCast(copy);
}

export fn JSGlobalContextSetName(ctx: JSContextRef, name: JSStringRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    if (name == null) {
        c.c_api_name_utf16 = null;
        return;
    }
    const string = strFrom(name) orelse return;
    c.c_api_name_utf16 = c.arena().dupe(u16, string.utf16) catch return;
}

fn inspectorState(c: *Context) ?*CInspectorState {
    return @ptrCast(@alignCast(c.c_api_inspector_state orelse return null));
}

fn inspectorSession(ref: ZJSInspectorSessionRef) ?*CInspectorSession {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn sendInspectorJson(session: *CInspectorSession, payload: anytype) bool {
    const message = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return false;
    defer gpa.free(message);
    session.state.callback_depth += 1;
    defer session.state.callback_depth -= 1;
    session.callback(message.ptr, message.len, session.user_data);
    return true;
}

fn sendInspectorError(session: *CInspectorSession, id: i64, code: i64, message: []const u8) bool {
    return sendInspectorJson(session, .{
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    });
}

fn inspectorHasDebugger(state: *const CInspectorState) bool {
    for (state.sessions.items) |session| {
        if (session.attached and session.debugger_enabled) return true;
    }
    return false;
}

fn inspectorSessionCanOwnPause(session: *const CInspectorSession) bool {
    return session.attached and session.debugger_enabled;
}

fn chooseInspectorPauseOwner(state: *CInspectorState) ?*CInspectorSession {
    if (state.next_pause_owner) |preferred| {
        state.next_pause_owner = null;
        for (state.sessions.items) |session| {
            if (session == preferred and inspectorSessionCanOwnPause(session)) return session;
        }
    }
    for (state.sessions.items) |session| if (inspectorSessionCanOwnPause(session)) return session;
    return null;
}

fn refreshInspectorDebuggerHook(state: *CInspectorState) void {
    const context = state.context;
    if (inspectorHasDebugger(state)) {
        context.debug_statement_ctx = state;
        context.debug_statement_hook = inspectorStatementBoundary;
        context.debug_exception_hook = inspectorExceptionBoundary;
    } else {
        if (state.paused_machine) |machine| {
            machine.debug_statement_ctx = null;
            machine.debug_statement_hook = null;
            machine.debug_exception_ctx = null;
            machine.debug_exception_hook = null;
        }
        context.debug_statement_ctx = null;
        context.debug_statement_hook = null;
        context.debug_exception_hook = null;
        state.pause_requested = false;
        state.paused = false;
        state.paused_machine = null;
        state.pause_owner = null;
        state.next_pause_owner = null;
        releaseInspectorRemotes(state, null, null, true);
        state.paused_at_uncaught_boundary = false;
        state.step_mode = .none;
    }
}

fn sendInspectorScriptParsed(session: *CInspectorSession, script: CInspectorScript) bool {
    return sendInspectorJson(session, .{
        .method = "Debugger.scriptParsed",
        .params = .{
            .scriptId = script.id,
            .url = script.url,
            .startLine = script.start_line - 1,
            .sourceLength = script.source.len,
        },
    });
}

fn inspectorScript(state: *const CInspectorState, id: u64) ?CInspectorScript {
    for (state.scripts.items) |script| if (script.id == id) return script;
    return null;
}

fn inspectorResolvedLocation(state: *const CInspectorState, script_id: u64, line_number: usize, column_number: usize) ?InspectorProtocolLocation {
    var best: ?InspectorProtocolLocation = null;
    var it = state.context.debug_statement_locations.valueIterator();
    while (it.next()) |entry| {
        if (entry.script_id != script_id) continue;
        const candidate = InspectorProtocolLocation{
            .scriptId = script_id,
            .lineNumber = entry.location.line - 1,
            .columnNumber = entry.location.column - 1,
            .byteOffset = entry.location.byte_offset,
        };
        if (candidate.lineNumber < line_number or
            (candidate.lineNumber == line_number and candidate.columnNumber < column_number)) continue;
        if (best == null or candidate.lineNumber < best.?.lineNumber or
            (candidate.lineNumber == best.?.lineNumber and candidate.columnNumber < best.?.columnNumber) or
            (candidate.lineNumber == best.?.lineNumber and candidate.columnNumber == best.?.columnNumber and candidate.byteOffset < best.?.byteOffset))
        {
            best = candidate;
        }
    }
    return best;
}

fn inspectorBreakpointAlreadyResolved(state: *const CInspectorState, breakpoint_id: u64, script_id: u64) bool {
    for (state.resolved_breakpoints.items) |resolved| {
        if (resolved.breakpoint_id == breakpoint_id and resolved.location.scriptId == script_id) return true;
    }
    return false;
}

fn resolveInspectorBreakpointForScript(state: *CInspectorState, breakpoint: CInspectorBreakpoint, script: CInspectorScript) ?InspectorProtocolLocation {
    if (inspectorBreakpointAlreadyResolved(state, breakpoint.id, script.id)) return null;
    if (breakpoint.kind == .script and breakpoint.script_id != script.id) return null;
    if (breakpoint.kind == .url and !std.mem.eql(u8, breakpoint.url, script.url)) return null;
    const location = inspectorResolvedLocation(state, script.id, breakpoint.line_number, breakpoint.column_number) orelse return null;
    state.resolved_breakpoints.append(gpa, .{ .breakpoint_id = breakpoint.id, .location = location }) catch return null;
    for (state.sessions.items) |session| {
        if (session.attached and session.debugger_enabled) _ = sendInspectorJson(session, .{
            .method = "Debugger.breakpointResolved",
            .params = .{ .breakpointId = breakpoint.id, .location = location },
        });
    }
    return location;
}

fn resolveInspectorBreakpointsForScript(state: *CInspectorState, script_id: u64) void {
    const script = inspectorScript(state, script_id) orelse return;
    for (state.breakpoints.items) |breakpoint| _ = resolveInspectorBreakpointForScript(state, breakpoint, script);
}

fn inspectorBreakpointHits(state: *const CInspectorState, location: interp.DebugStatementLocation, hits: *std.ArrayListUnmanaged(u64)) !void {
    for (state.resolved_breakpoints.items) |resolved| {
        if (resolved.location.scriptId != location.script_id or
            resolved.location.lineNumber != location.location.line - 1 or
            resolved.location.columnNumber != location.location.column - 1 or
            resolved.location.byteOffset != location.location.byte_offset) continue;
        var already_hit = false;
        for (hits.items) |id| {
            if (id == resolved.breakpoint_id) {
                already_hit = true;
                break;
            }
        }
        if (!already_hit) try hits.append(gpa, resolved.breakpoint_id);
    }
}

fn inspectorProtocolLocation(location: interp.DebugStatementLocation) InspectorProtocolLocation {
    return .{
        .scriptId = location.script_id,
        .lineNumber = location.location.line - 1,
        .columnNumber = location.location.column - 1,
        .byteOffset = location.location.byte_offset,
    };
}

fn registerInspectorRemote(
    session: *CInspectorSession,
    kind: CInspectorRemoteKind,
    group: []const u8,
    pause_only: bool,
) !u64 {
    const state = session.state;
    const group_copy = try gpa.dupe(u8, group);
    errdefer gpa.free(group_copy);
    if (kind == .value) {
        const ctx: JSContextRef = @ptrCast(state.context);
        if (!valueProtect(ctx, kind.value)) return error.OutOfMemory;
        errdefer _ = valueUnprotect(ctx, kind.value);
    }
    const id = state.next_remote_object_id;
    state.next_remote_object_id += 1;
    try state.remote_objects.append(gpa, .{
        .id = id,
        .owner = session,
        .kind = kind,
        .group = group_copy,
        .pause_only = pause_only,
    });
    return id;
}

fn releaseInspectorRemoteAt(state: *CInspectorState, index: usize) void {
    const remote = state.remote_objects.swapRemove(index);
    if (remote.kind == .value) {
        const ctx: JSContextRef = @ptrCast(state.context);
        _ = valueUnprotect(ctx, remote.kind.value);
    }
    gpa.free(remote.group);
}

fn releaseInspectorRemotes(state: *CInspectorState, owner: ?*CInspectorSession, group: ?[]const u8, pause_only: bool) void {
    var index: usize = state.remote_objects.items.len;
    while (index > 0) {
        index -= 1;
        const remote = state.remote_objects.items[index];
        if (owner) |expected| if (remote.owner != expected) continue;
        if (group) |expected| if (!std.mem.eql(u8, remote.group, expected)) continue;
        if (pause_only and !remote.pause_only) continue;
        releaseInspectorRemoteAt(state, index);
    }
}

fn inspectorRemote(state: *CInspectorState, session: *CInspectorSession, id: u64) ?*CInspectorRemoteObject {
    for (state.remote_objects.items) |*remote| {
        if (remote.id == id and remote.owner == session) return remote;
    }
    return null;
}

fn inspectorRemoteValue(raw: Value) InspectorRemoteValue {
    return switch (raw.kind()) {
        .undefined => .{ .type = "undefined", .description = "undefined" },
        .null => .{ .type = "object", .value = .null, .description = "null" },
        .boolean => .{
            .type = "boolean",
            .value = .{ .bool = raw.asBool() },
            .description = if (raw.asBool()) "true" else "false",
        },
        .number => .{
            .type = "number",
            .value = if (std.math.isFinite(raw.asNum())) .{ .float = raw.asNum() } else null,
            .description = "number",
        },
        .string => .{
            .type = "string",
            .value = .{ .string = @constCast(raw.asStr()) },
            .description = raw.asStr(),
        },
        .object => blk: {
            const object = raw.asObj();
            if (object.is_symbol) break :blk .{ .type = "symbol", .description = "Symbol" };
            if (object.is_bigint) break :blk .{ .type = "bigint", .description = "BigInt" };
            if (object.jsFunction() != null) break :blk .{ .type = "function", .description = "Function" };
            break :blk .{ .type = "object", .description = "Object" };
        },
    };
}

fn inspectorRemoteValueForSession(session: *CInspectorSession, raw: Value, group: []const u8, pause_only: bool) !InspectorRemoteValue {
    var remote = inspectorRemoteValue(raw);
    if (raw.kind() == .object) {
        const value_ref = box(session.state.context, raw) orelse return error.OutOfMemory;
        remote.objectId = try registerInspectorRemote(session, .{ .value = value_ref }, group, pause_only);
    }
    return remote;
}

fn inspectorProperties(arena: std.mem.Allocator, session: *CInspectorSession, remote: CInspectorRemoteObject) ![]const InspectorPropertyDescriptor {
    const RawBinding = struct { name: []const u8, value: Value, writable: bool };
    var properties: std.ArrayListUnmanaged(InspectorPropertyDescriptor) = .empty;
    switch (remote.kind) {
        .scope => |environment| {
            if (!session.state.paused or session.state.paused_machine == null) return error.InvalidRemoteObject;
            var raw_bindings: std.ArrayListUnmanaged(RawBinding) = .empty;
            const AliasSnapshot = struct { local_name: []const u8, target: interp.Environment.Alias };
            var aliases: std.ArrayListUnmanaged(AliasSnapshot) = .empty;
            environment.lockBindings();
            {
                defer environment.unlockBindings();
                var iterator = environment.vars.iterator();
                while (iterator.next()) |entry| try raw_bindings.append(arena, .{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                    .writable = !environment.consts.contains(entry.key_ptr.*),
                });
                var alias_iterator = environment.aliases.iterator();
                while (alias_iterator.next()) |entry| try aliases.append(arena, .{ .local_name = entry.key_ptr.*, .target = entry.value_ptr.* });
            }
            for (aliases.items) |alias| try raw_bindings.append(arena, .{
                .name = alias.local_name,
                .value = alias.target.env.get(alias.target.name) orelse Value.undef(),
                .writable = false,
            });
            for (raw_bindings.items) |binding| try properties.append(arena, .{
                .name = binding.name,
                .value = try inspectorRemoteValueForSession(session, binding.value, remote.group, remote.pause_only),
                .writable = binding.writable,
                .enumerable = true,
                .configurable = false,
            });
        },
        .value => |value_ref| {
            const raw = valueFromContext(session.state.context, value_ref) orelse return error.InvalidRemoteObject;
            if (!raw.isObject() or raw.asObj().is_symbol or raw.asObj().is_bigint) return error.InvalidRemoteObject;
            const object = raw.asObj();
            const keys = try object.ownKeys(arena);
            for (keys) |key| {
                const attr = object.getAttr(key);
                if (object.getOwn(key)) |property_value| {
                    try properties.append(arena, .{
                        .name = key,
                        .value = try inspectorRemoteValueForSession(session, property_value, remote.group, remote.pause_only),
                        .writable = attr.writable,
                        .enumerable = attr.enumerable,
                        .configurable = attr.configurable,
                    });
                } else if (object.getAccessor(key)) |accessor| {
                    try properties.append(arena, .{
                        .name = key,
                        .get = if (accessor.get) |getter| try inspectorRemoteValueForSession(session, getter, remote.group, remote.pause_only) else null,
                        .set = if (accessor.set) |setter| try inspectorRemoteValueForSession(session, setter, remote.group, remote.pause_only) else null,
                        .writable = false,
                        .enumerable = attr.enumerable,
                        .configurable = attr.configurable,
                    });
                }
            }
        },
    }
    return properties.items;
}

fn inspectorScopeChain(arena: std.mem.Allocator, session: *CInspectorSession, start: *interp.Environment) ![]const InspectorScope {
    const AliasSnapshot = struct { local_name: []const u8, target: interp.Environment.Alias };
    var scopes: std.ArrayListUnmanaged(InspectorScope) = .empty;
    var current: ?*interp.Environment = start;
    while (current) |environment| : (current = environment.parent) {
        const is_global = environment.parent == null;
        var bindings: std.ArrayListUnmanaged(InspectorScopeBinding) = .empty;
        var aliases: std.ArrayListUnmanaged(AliasSnapshot) = .empty;
        const binding_count = locked: {
            environment.lockBindings();
            defer environment.unlockBindings();
            const count = environment.vars.count() + environment.aliases.count();
            if (!is_global) {
                var iterator = environment.vars.iterator();
                while (iterator.next()) |entry| try bindings.append(arena, .{
                    .name = entry.key_ptr.*,
                    .value = try inspectorRemoteValueForSession(session, entry.value_ptr.*, "backtrace", true),
                });
                var alias_iterator = environment.aliases.iterator();
                while (alias_iterator.next()) |entry| try aliases.append(arena, .{
                    .local_name = entry.key_ptr.*,
                    .target = entry.value_ptr.*,
                });
            }
            break :locked count;
        };
        for (aliases.items) |alias| try bindings.append(arena, .{
            .name = alias.local_name,
            .value = try inspectorRemoteValueForSession(session, alias.target.env.get(alias.target.name) orelse Value.undef(), "backtrace", true),
        });
        const scope_id = try registerInspectorRemote(session, .{ .scope = environment }, "backtrace", true);
        try scopes.append(arena, .{
            .type = if (is_global) "global" else if (environment.fn_scope) "local" else "block",
            .name = if (is_global) "Global" else if (environment.fn_scope) "Local" else "Block",
            .bindingCount = binding_count,
            .bindings = bindings.items,
            .object = .{ .type = "object", .description = "Scope", .objectId = scope_id },
        });
    }
    return scopes.items;
}

fn inspectorCallFrames(arena: std.mem.Allocator, session: *CInspectorSession, machine: *interp.Interpreter, current_location: interp.DebugStatementLocation) ![]const InspectorCallFrame {
    var frames: std.ArrayListUnmanaged(InspectorCallFrame) = .empty;
    var frame_id: u64 = 0;
    var current = machine.debug_call_frame;
    while (current) |frame| : (current = frame.caller) {
        const location = frame.location orelse current_location;
        try frames.append(arena, .{
            .callFrameId = frame_id,
            .functionName = if (frame.function_name.len == 0) "(anonymous)" else frame.function_name,
            .location = inspectorProtocolLocation(location),
            .scopeChain = try inspectorScopeChain(arena, session, frame.environment),
            .this = try inspectorRemoteValueForSession(session, frame.this_value, "backtrace", true),
        });
        frame_id += 1;
    }
    const top_location = machine.debug_top_level_location orelse current_location;
    const top_environment = machine.debug_top_level_environment orelse machine.env;
    try frames.append(arena, .{
        .callFrameId = frame_id,
        .functionName = "(global)",
        .location = inspectorProtocolLocation(top_location),
        .scopeChain = try inspectorScopeChain(arena, session, top_environment),
        .this = try inspectorRemoteValueForSession(session, if (machine.global_object) |global| Value.obj(global) else machine.this_value, "backtrace", true),
    });
    return frames.items;
}

const InspectorEvaluationFrame = struct {
    environment: *interp.Environment,
    this_value: Value,
    strict: bool,
};

fn inspectorEvaluationFrame(machine: *interp.Interpreter, requested_id: u64) ?InspectorEvaluationFrame {
    var frame_id: u64 = 0;
    var current = machine.debug_call_frame;
    while (current) |frame| : (current = frame.caller) {
        if (frame_id == requested_id) return .{
            .environment = frame.environment,
            .this_value = frame.this_value,
            .strict = frame.strict,
        };
        frame_id += 1;
    }
    if (frame_id != requested_id) return null;
    return .{
        .environment = machine.debug_top_level_environment orelse machine.env,
        .this_value = if (machine.global_object) |global| Value.obj(global) else machine.this_value,
        .strict = machine.debug_top_level_strict,
    };
}

fn beginInspectorScript(
    state: *CInspectorState,
    script: CInspectorScript,
) ?CInspectorScript {
    state.scripts.append(gpa, script) catch return null;
    for (state.sessions.items) |session| {
        if (session.attached and session.debugger_enabled) _ = sendInspectorScriptParsed(session, script);
    }
    return script;
}

fn inspectorScriptRegistered(ctx: *anyopaque, script: Context.DebugScript) bool {
    const state: *CInspectorState = @ptrCast(@alignCast(ctx));
    state.operation_depth += 1;
    defer finishInspectorOperation(state);
    return beginInspectorScript(state, script) != null;
}

fn inspectorStatementBoundary(
    hook_context: *anyopaque,
    machine: *interp.Interpreter,
    location: interp.DebugStatementLocation,
) interp.EvalError!void {
    const state: *CInspectorState = @ptrCast(@alignCast(hook_context));
    state.operation_depth += 1;
    defer finishInspectorOperation(state);
    resolveInspectorBreakpointsForScript(state, location.script_id);
    var hits: std.ArrayListUnmanaged(u64) = .empty;
    defer hits.deinit(gpa);
    try inspectorBreakpointHits(state, location, &hits);
    const step_hit = switch (state.step_mode) {
        .none => false,
        .into => true,
        .over => machine.depth <= state.step_depth,
        .out => machine.depth < state.step_depth,
    };
    if (!location.debugger_statement and !state.pause_requested and hits.items.len == 0 and !step_hit) return;
    const reason: []const u8 = if (location.debugger_statement)
        "debuggerStatement"
    else if (hits.items.len > 0)
        "breakpoint"
    else if (step_hit)
        "step"
    else
        "pause";
    state.pause_requested = false;
    state.step_mode = .none;
    state.paused = true;
    state.paused_depth = machine.depth;
    state.paused_at_uncaught_boundary = false;
    state.paused_machine = machine;
    state.pause_owner = chooseInspectorPauseOwner(state);
    var pause_arena = std.heap.ArenaAllocator.init(gpa);
    defer pause_arena.deinit();
    var owner_pass = false;
    while (true) : (owner_pass = true) {
        for (state.sessions.items) |session| {
            if (!inspectorSessionCanOwnPause(session) or (session == state.pause_owner) != owner_pass) continue;
            const call_frames = try inspectorCallFrames(pause_arena.allocator(), session, machine, location);
            _ = sendInspectorJson(session, .{
                .method = "Debugger.paused",
                .params = .{
                    .reason = reason,
                    .hitBreakpoints = hits.items,
                    .location = .{
                        .scriptId = location.script_id,
                        .lineNumber = location.location.line - 1,
                        .columnNumber = location.location.column - 1,
                        .byteOffset = location.location.byte_offset,
                    },
                    .callFrames = call_frames,
                },
            });
        }
        if (owner_pass) break;
    }
    if (state.detached_resume_pending) {
        state.detached_resume_pending = false;
        for (state.sessions.items) |session| {
            if (inspectorSessionCanOwnPause(session)) _ = sendInspectorJson(session, .{
                .method = "Debugger.resumed",
                .params = .{},
            });
        }
    }
    while (state.paused) {
        const wait_hook = state.pause_wait_hook orelse break;
        if (!wait_hook(state.pause_wait_ctx.?)) break;
    }
    // Direct sessions resume synchronously from their callback. Worker sessions
    // install a wait hook that drains owner-queued commands on this runtime
    // thread. Returning to JS while still marked paused would violate either
    // contract, so abort deterministically.
    if (state.paused) {
        state.paused = false;
        state.paused_machine = null;
        state.pause_owner = null;
        releaseInspectorRemotes(state, null, null, true);
        machine.exception = try machine.makeError("Error", "debugger pause requires a synchronous resume command");
        return error.Throw;
    }
}

fn continueInspectorExecution(session: *CInspectorSession, id: i64, mode: CInspectorStepMode) bool {
    const state = session.state;
    if (!state.paused) return sendInspectorError(session, id, -32000, "runtime is not paused");
    if (state.pause_owner != session) return sendInspectorError(session, id, -32000, "session does not own continuation for this pause");
    if (state.paused_at_uncaught_boundary and mode != .none) return sendInspectorError(session, id, -32000, "cannot step after an uncaught exception left the runtime");
    if (mode == .out and state.paused_depth == 0) return sendInspectorError(session, id, -32000, "cannot step out of top-level execution");
    state.paused = false;
    state.paused_machine = null;
    state.pause_owner = null;
    state.next_pause_owner = if (mode == .none) null else session;
    releaseInspectorRemotes(state, null, null, true);
    state.step_mode = mode;
    state.step_depth = state.paused_depth;
    state.paused_at_uncaught_boundary = false;
    if (!sendInspectorJson(session, .{ .id = id, .result = .{} })) return false;
    for (state.sessions.items) |candidate| {
        if (candidate.attached and candidate.debugger_enabled) _ = sendInspectorJson(candidate, .{
            .method = "Debugger.resumed",
            .params = .{},
        });
    }
    return true;
}

fn inspectorExceptionBoundary(
    hook_context: *anyopaque,
    machine: *interp.Interpreter,
    exception: Value,
    maybe_location: ?interp.DebugStatementLocation,
    uncaught: bool,
) interp.EvalError!void {
    const state: *CInspectorState = @ptrCast(@alignCast(hook_context));
    state.operation_depth += 1;
    defer finishInspectorOperation(state);
    const should_pause = switch (state.exception_mode) {
        .none => false,
        .all => !uncaught,
        .uncaught => uncaught,
    };
    if (!should_pause) return;
    const exception_id = state.next_exception_id;
    state.next_exception_id += 1;
    const protocol_type: []const u8 = switch (exception.kind()) {
        .undefined => "undefined",
        .null => "object",
        .boolean => "boolean",
        .number => "number",
        .string => "string",
        .object => if (exception.asObj().is_symbol) "symbol" else if (exception.asObj().is_bigint) "bigint" else "object",
    };
    const location = if (maybe_location) |source_location| InspectorProtocolLocation{
        .scriptId = source_location.script_id,
        .lineNumber = source_location.location.line - 1,
        .columnNumber = source_location.location.column - 1,
        .byteOffset = source_location.location.byte_offset,
    } else InspectorProtocolLocation{
        .scriptId = 0,
        .lineNumber = 0,
        .columnNumber = 0,
        .byteOffset = 0,
    };
    state.paused = true;
    state.paused_depth = machine.depth;
    state.paused_at_uncaught_boundary = uncaught;
    state.paused_machine = machine;
    state.pause_owner = chooseInspectorPauseOwner(state);
    state.pause_requested = false;
    state.step_mode = .none;
    var pause_arena = std.heap.ArenaAllocator.init(gpa);
    defer pause_arena.deinit();
    const frame_location = maybe_location orelse machine.debug_current_location orelse interp.DebugStatementLocation{
        .script_id = 0,
        .location = .{ .line = 1, .column = 1, .byte_offset = 0 },
    };
    var owner_pass = false;
    while (true) : (owner_pass = true) {
        for (state.sessions.items) |session| {
            if (!inspectorSessionCanOwnPause(session) or (session == state.pause_owner) != owner_pass) continue;
            const call_frames = try inspectorCallFrames(pause_arena.allocator(), session, machine, frame_location);
            _ = sendInspectorJson(session, .{
                .method = "Debugger.exceptionThrown",
                .params = .{
                    .exceptionId = exception_id,
                    .uncaught = uncaught,
                    .location = location,
                    .exception = .{ .type = protocol_type, .description = "JavaScript exception" },
                },
            });
            _ = sendInspectorJson(session, .{
                .method = "Debugger.paused",
                .params = .{
                    .reason = "exception",
                    .hitBreakpoints = &[_]u64{},
                    .location = location,
                    .data = .{ .exceptionId = exception_id, .uncaught = uncaught },
                    .callFrames = call_frames,
                },
            });
        }
        if (owner_pass) break;
    }
    if (state.detached_resume_pending) {
        state.detached_resume_pending = false;
        for (state.sessions.items) |session| {
            if (inspectorSessionCanOwnPause(session)) _ = sendInspectorJson(session, .{
                .method = "Debugger.resumed",
                .params = .{},
            });
        }
    }
    while (state.paused) {
        const wait_hook = state.pause_wait_hook orelse break;
        if (!wait_hook(state.pause_wait_ctx.?)) break;
    }
    if (state.paused) {
        state.paused = false;
        state.paused_machine = null;
        state.pause_owner = null;
        releaseInspectorRemotes(state, null, null, true);
        state.paused_at_uncaught_boundary = false;
        machine.exception = try machine.makeError("Error", "debugger exception pause requires a synchronous resume command");
        return error.Throw;
    }
}

const InspectorDescription = struct {
    allocation: []u8,
    bytes: []const u8,

    fn deinit(self: InspectorDescription) void {
        gpa.free(self.allocation);
    }
};

fn inspectorDescription(ctx: JSContextRef, value_ref: JSValueRef) ?InspectorDescription {
    const string = JSValueToStringCopy(ctx, value_ref, null) orelse return null;
    defer JSStringRelease(string);
    const capacity = JSStringGetMaximumUTF8CStringSize(string);
    const allocation = gpa.alloc(u8, capacity) catch return null;
    const written = JSStringGetUTF8CString(string, allocation.ptr, allocation.len);
    if (written == 0) {
        gpa.free(allocation);
        return null;
    }
    return .{ .allocation = allocation, .bytes = allocation[0 .. written - 1] };
}

fn sendInspectorRemoteObject(session: *CInspectorSession, id: i64, value_ref: JSValueRef, exception_ref: JSValueRef, object_group: []const u8) bool {
    const ctx: JSContextRef = @ptrCast(session.state.context);
    const target = if (value_ref != null) value_ref else exception_ref;
    const description = inspectorDescription(ctx, target) orelse
        return sendInspectorError(session, id, -32000, "could not describe evaluation result");
    defer description.deinit();
    const raw = valueFromContext(session.state.context, target) orelse
        return sendInspectorError(session, id, -32000, "evaluation returned an invalid value");
    var remote = inspectorRemoteValueForSession(session, raw, object_group, false) catch
        return sendInspectorError(session, id, -32000, "could not retain evaluation result");
    remote.description = description.bytes;
    if (exception_ref != null) {
        return sendInspectorJson(session, .{
            .id = id,
            .result = .{
                .result = remote,
                .exceptionDetails = .{ .text = description.bytes },
            },
        });
    }
    return sendInspectorJson(session, .{
        .id = id,
        .result = .{
            .result = remote,
        },
    });
}

export fn JSGlobalContextIsInspectable(ctx: JSContextRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    return c.c_api_inspectable;
}

export fn JSGlobalContextSetInspectable(ctx: JSContextRef, inspectable: bool) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    if (c.c_api_inspectable == inspectable) return;
    c.c_api_inspectable = inspectable;
    if (!inspectable) {
        if (inspectorState(c)) |state| {
            state.operation_depth += 1;
            defer finishInspectorOperation(state);
            for (state.sessions.items) |session| {
                if (!session.attached) continue;
                session.attached = false;
                _ = sendInspectorJson(session, .{
                    .method = "Inspector.detached",
                    .params = .{ .reason = "context is no longer inspectable" },
                });
            }
            refreshInspectorDebuggerHook(state);
        }
    }
}

fn createInspectorSession(
    ctx: JSContextRef,
    callback: ZJSInspectorMessageCallback,
    user_data: ?*anyopaque,
    pause_wait_ctx: ?*anyopaque,
    pause_wait_hook: ?WorkerMod.InspectorPauseWaitHook,
) ZJSInspectorSessionRef {
    const c = ctxFrom(ctx) orelse return null;
    const cb = callback orelse return null;
    if (!c.c_api_inspectable) return null;
    _ = JSGlobalContextRetain(ctx) orelse return null;
    errdefer JSGlobalContextRelease(ctx);

    var state = inspectorState(c);
    var created_state = false;
    if (state == null) {
        const new_state = gpa.create(CInspectorState) catch return null;
        new_state.* = .{
            .context = c,
            .pause_wait_ctx = pause_wait_ctx,
            .pause_wait_hook = pause_wait_hook,
        };
        for (c.debug_scripts.items) |script| new_state.scripts.append(gpa, script) catch {
            new_state.scripts.deinit(gpa);
            gpa.destroy(new_state);
            return null;
        };
        c.debug_script_notify_ctx = new_state;
        c.debug_script_notify_hook = inspectorScriptRegistered;
        c.c_api_inspector_state = @ptrCast(new_state);
        state = new_state;
        created_state = true;
    }
    errdefer if (created_state) {
        c.c_api_inspector_state = null;
        c.debug_script_notify_ctx = null;
        c.debug_script_notify_hook = null;
        state.?.scripts.deinit(gpa);
        gpa.destroy(state.?);
    };
    const session = gpa.create(CInspectorSession) catch return null;
    errdefer gpa.destroy(session);
    session.* = .{ .state = state.?, .callback = cb, .user_data = user_data };
    state.?.sessions.append(gpa, session) catch return null;
    _ = sendInspectorJson(session, .{
        .method = "Inspector.attached",
        .params = .{ .protocolVersion = "zig-js-inspector/0.1" },
    });
    return @ptrCast(session);
}

export fn ZJSInspectorSessionCreate(
    ctx: JSContextRef,
    callback: ZJSInspectorMessageCallback,
    user_data: ?*anyopaque,
) callconv(.c) ZJSInspectorSessionRef {
    return createInspectorSession(ctx, callback, user_data, null, null);
}

fn releaseInspectorSessionNow(session: *CInspectorSession) bool {
    const state = session.state;
    const ctx: JSContextRef = @ptrCast(state.context);
    if (state.next_pause_owner == session) state.next_pause_owner = null;
    releaseInspectorRemotes(state, session, null, false);
    for (state.sessions.items, 0..) |candidate, index| {
        if (candidate != session) continue;
        _ = state.sessions.swapRemove(index);
        break;
    }
    gpa.destroy(session);
    refreshInspectorDebuggerHook(state);
    if (state.sessions.items.len == 0) {
        state.context.c_api_inspector_state = null;
        state.context.debug_script_notify_ctx = null;
        state.context.debug_script_notify_hook = null;
        state.sessions.deinit(gpa);
        state.scripts.deinit(gpa);
        state.breakpoints.deinit(gpa);
        state.resolved_breakpoints.deinit(gpa);
        state.remote_objects.deinit(gpa);
        gpa.destroy(state);
        JSGlobalContextRelease(ctx);
        return true;
    }
    JSGlobalContextRelease(ctx);
    return false;
}

fn drainDeferredInspectorReleases(state: *CInspectorState) void {
    var index: usize = state.sessions.items.len;
    while (index > 0) {
        index -= 1;
        const session = state.sessions.items[index];
        if (!session.release_requested) continue;
        if (releaseInspectorSessionNow(session)) return;
        index = @min(index, state.sessions.items.len);
    }
}

fn finishInspectorOperation(state: *CInspectorState) void {
    std.debug.assert(state.operation_depth > 0);
    state.operation_depth -= 1;
    if (state.operation_depth == 0 and state.callback_depth == 0) drainDeferredInspectorReleases(state);
}

export fn ZJSInspectorSessionRelease(session_ref: ZJSInspectorSessionRef) callconv(.c) void {
    const session = inspectorSession(session_ref) orelse return;
    const state = session.state;
    const ctx: JSContextRef = @ptrCast(state.context);
    _ = ctxFrom(ctx) orelse return;
    if (session.release_requested) return;
    if (state.operation_depth > 0 or state.callback_depth > 0) {
        session.release_requested = true;
        session.attached = false;
        session.debugger_enabled = false;
        if (state.next_pause_owner == session) state.next_pause_owner = null;
        if (state.pause_owner == session) {
            if (state.paused_machine) |machine| {
                machine.debug_statement_ctx = null;
                machine.debug_statement_hook = null;
                machine.debug_exception_ctx = null;
                machine.debug_exception_hook = null;
            }
            state.pause_owner = null;
            state.paused = false;
            state.paused_machine = null;
            state.detached_resume_pending = true;
            releaseInspectorRemotes(state, null, null, true);
        }
        refreshInspectorDebuggerHook(state);
        return;
    }
    _ = releaseInspectorSessionNow(session);
}

export fn ZJSInspectorSessionDispatch(
    session_ref: ZJSInspectorSessionRef,
    message: [*c]const u8,
    message_length: usize,
) callconv(.c) bool {
    const session = inspectorSession(session_ref) orelse return false;
    const state = session.state;
    const ctx: JSContextRef = @ptrCast(state.context);
    _ = ctxFrom(ctx) orelse return false;
    if (!session.attached or message == null or message_length == 0) return false;
    state.operation_depth += 1;
    defer finishInspectorOperation(state);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, message[0..message_length], .{}) catch {
        return sendInspectorError(session, 0, -32700, "invalid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return sendInspectorError(session, 0, -32600, "request must be an object");
    const request = parsed.value.object;
    const id_value = request.get("id") orelse return sendInspectorError(session, 0, -32600, "request id is required");
    const id: i64 = switch (id_value) {
        .integer => |integer| integer,
        else => return sendInspectorError(session, 0, -32600, "request id must be an integer"),
    };
    const method_value = request.get("method") orelse return sendInspectorError(session, id, -32600, "request method is required");
    const method = switch (method_value) {
        .string => |string| string,
        else => return sendInspectorError(session, id, -32600, "request method must be a string"),
    };

    if (std.mem.eql(u8, method, "Schema.getDomains")) {
        return sendInspectorJson(session, .{
            .id = id,
            .result = .{ .domains = &[_]struct { name: []const u8, version: []const u8 }{
                .{ .name = "Runtime", .version = "1.0" },
                .{ .name = "Debugger", .version = "0.1" },
                .{ .name = "Schema", .version = "1.0" },
            } },
        });
    }
    if (std.mem.eql(u8, method, "Runtime.enable")) {
        session.runtime_enabled = true;
        if (!sendInspectorJson(session, .{ .id = id, .result = .{} })) return false;
        return sendInspectorJson(session, .{
            .method = "Runtime.executionContextCreated",
            .params = .{ .context = .{
                .id = @as(u64, @intCast(@intFromPtr(session.state.context))),
                .origin = "zig-js://local",
                .name = "zig-js",
            } },
        });
    }
    if (std.mem.eql(u8, method, "Runtime.disable")) {
        session.runtime_enabled = false;
        return sendInspectorJson(session, .{ .id = id, .result = .{} });
    }
    if (std.mem.eql(u8, method, "Debugger.enable")) {
        session.debugger_enabled = true;
        refreshInspectorDebuggerHook(session.state);
        if (!sendInspectorJson(session, .{
            .id = id,
            .result = .{ .debuggerId = "zig-js-debugger-0.1" },
        })) return false;
        for (session.state.scripts.items) |script| {
            if (!sendInspectorScriptParsed(session, script)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, method, "Debugger.disable")) {
        if (session.state.paused and session.state.pause_owner == session)
            return sendInspectorError(session, id, -32000, "continuation owner must resume before disabling Debugger");
        session.debugger_enabled = false;
        refreshInspectorDebuggerHook(session.state);
        return sendInspectorJson(session, .{ .id = id, .result = .{} });
    }
    if (std.mem.eql(u8, method, "Debugger.pause")) {
        if (!session.debugger_enabled) return sendInspectorError(session, id, -32000, "Debugger domain is not enabled");
        session.state.pause_requested = true;
        session.state.next_pause_owner = session;
        return sendInspectorJson(session, .{ .id = id, .result = .{} });
    }
    if (std.mem.eql(u8, method, "Debugger.resume")) {
        return continueInspectorExecution(session, id, .none);
    }
    if (std.mem.eql(u8, method, "Debugger.stepInto")) {
        return continueInspectorExecution(session, id, .into);
    }
    if (std.mem.eql(u8, method, "Debugger.stepOver")) {
        return continueInspectorExecution(session, id, .over);
    }
    if (std.mem.eql(u8, method, "Debugger.stepOut")) {
        return continueInspectorExecution(session, id, .out);
    }
    if (std.mem.eql(u8, method, "Debugger.evaluateOnCallFrame")) {
        if (!session.debugger_enabled) return sendInspectorError(session, id, -32000, "Debugger domain is not enabled");
        if (!session.state.paused) return sendInspectorError(session, id, -32000, "runtime is not paused");
        const machine = session.state.paused_machine orelse return sendInspectorError(session, id, -32000, "paused execution has no live interpreter");
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const params = params_value.object;
        const frame_id_value = params.get("callFrameId") orelse return sendInspectorError(session, id, -32602, "callFrameId is required");
        const frame_id: u64 = switch (frame_id_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "callFrameId must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "callFrameId must be an integer"),
        };
        const expression_value = params.get("expression") orelse return sendInspectorError(session, id, -32602, "expression is required");
        const expression = switch (expression_value) {
            .string => |string| string,
            else => return sendInspectorError(session, id, -32602, "expression must be a string"),
        };
        const object_group = if (params.get("objectGroup")) |group_value| switch (group_value) {
            .string => |group| group,
            else => return sendInspectorError(session, id, -32602, "objectGroup must be a string"),
        } else "";
        const frame = inspectorEvaluationFrame(machine, frame_id) orelse return sendInspectorError(session, id, -32000, "unknown callFrameId for this pause");
        const saved_exception = machine.exception;
        machine.exception = Value.undef();
        const outcome = machine.evaluateForDebugger(expression, frame.environment, frame.this_value, frame.strict);
        if (outcome) |result| {
            const result_ref = box(session.state.context, result);
            machine.exception = saved_exception;
            return sendInspectorRemoteObject(session, id, result_ref, null, object_group);
        } else |err| {
            if (err != error.Throw) {
                machine.exception = saved_exception;
                return sendInspectorError(session, id, -32000, @errorName(err));
            }
            const exception_ref = box(session.state.context, machine.exception);
            machine.exception = saved_exception;
            return sendInspectorRemoteObject(session, id, null, exception_ref, object_group);
        }
    }
    if (std.mem.eql(u8, method, "Debugger.setPauseOnExceptions")) {
        if (!session.debugger_enabled) return sendInspectorError(session, id, -32000, "Debugger domain is not enabled");
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const state_value = params_value.object.get("state") orelse return sendInspectorError(session, id, -32602, "state is required");
        const requested_state = switch (state_value) {
            .string => |string| string,
            else => return sendInspectorError(session, id, -32602, "state must be a string"),
        };
        session.state.exception_mode = if (std.mem.eql(u8, requested_state, "none"))
            .none
        else if (std.mem.eql(u8, requested_state, "uncaught"))
            .uncaught
        else if (std.mem.eql(u8, requested_state, "all"))
            .all
        else
            return sendInspectorError(session, id, -32602, "state must be none, uncaught, or all");
        return sendInspectorJson(session, .{ .id = id, .result = .{} });
    }
    if (std.mem.eql(u8, method, "Debugger.getScriptSource")) {
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const script_id_value = params_value.object.get("scriptId") orelse return sendInspectorError(session, id, -32602, "scriptId is required");
        const script_id: u64 = switch (script_id_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "scriptId must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "scriptId must be an integer"),
        };
        const script = inspectorScript(session.state, script_id) orelse return sendInspectorError(session, id, -32000, "unknown scriptId");
        return sendInspectorJson(session, .{ .id = id, .result = .{ .scriptSource = script.source } });
    }
    if (std.mem.eql(u8, method, "Debugger.setBreakpoint") or std.mem.eql(u8, method, "Debugger.setBreakpointByUrl")) {
        if (!session.debugger_enabled) return sendInspectorError(session, id, -32000, "Debugger domain is not enabled");
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const params = params_value.object;
        const by_url = std.mem.eql(u8, method, "Debugger.setBreakpointByUrl");
        const location_params = if (by_url) params else blk: {
            const location_value = params.get("location") orelse return sendInspectorError(session, id, -32602, "location is required");
            if (location_value != .object) return sendInspectorError(session, id, -32602, "location must be an object");
            break :blk location_value.object;
        };
        const line_value = location_params.get("lineNumber") orelse return sendInspectorError(session, id, -32602, "lineNumber is required");
        const line_number: usize = switch (line_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "lineNumber must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "lineNumber must be an integer"),
        };
        const column_number: usize = if (location_params.get("columnNumber")) |column_value| switch (column_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "columnNumber must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "columnNumber must be an integer"),
        } else 0;
        var breakpoint = CInspectorBreakpoint{
            .id = session.state.next_breakpoint_id,
            .kind = if (by_url) .url else .script,
            .line_number = line_number,
            .column_number = column_number,
        };
        if (by_url) {
            const url_value = params.get("url") orelse return sendInspectorError(session, id, -32602, "url is required");
            const url = switch (url_value) {
                .string => |string| string,
                else => return sendInspectorError(session, id, -32602, "url must be a string"),
            };
            breakpoint.url = session.state.context.arena().dupe(u8, url) catch return sendInspectorError(session, id, -32000, "out of memory");
        } else {
            const script_id_value = location_params.get("scriptId") orelse return sendInspectorError(session, id, -32602, "scriptId is required");
            breakpoint.script_id = switch (script_id_value) {
                .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "scriptId must be non-negative"),
                else => return sendInspectorError(session, id, -32602, "scriptId must be an integer"),
            };
            if (inspectorScript(session.state, breakpoint.script_id) == null) return sendInspectorError(session, id, -32000, "unknown scriptId");
        }
        session.state.next_breakpoint_id += 1;
        session.state.breakpoints.append(gpa, breakpoint) catch return sendInspectorError(session, id, -32000, "out of memory");
        var locations: std.ArrayListUnmanaged(InspectorProtocolLocation) = .empty;
        defer locations.deinit(gpa);
        for (session.state.scripts.items) |script| {
            if (resolveInspectorBreakpointForScript(session.state, breakpoint, script)) |location| locations.append(gpa, location) catch return sendInspectorError(session, id, -32000, "out of memory");
        }
        if (by_url) return sendInspectorJson(session, .{
            .id = id,
            .result = .{ .breakpointId = breakpoint.id, .locations = locations.items },
        });
        const actual = if (locations.items.len > 0) locations.items[0] else InspectorProtocolLocation{
            .scriptId = breakpoint.script_id,
            .lineNumber = breakpoint.line_number,
            .columnNumber = breakpoint.column_number,
            .byteOffset = 0,
        };
        return sendInspectorJson(session, .{
            .id = id,
            .result = .{ .breakpointId = breakpoint.id, .actualLocation = actual },
        });
    }
    if (std.mem.eql(u8, method, "Debugger.removeBreakpoint")) {
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const breakpoint_id_value = params_value.object.get("breakpointId") orelse return sendInspectorError(session, id, -32602, "breakpointId is required");
        const breakpoint_id: u64 = switch (breakpoint_id_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "breakpointId must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "breakpointId must be an integer"),
        };
        var found = false;
        var breakpoint_index: usize = 0;
        while (breakpoint_index < session.state.breakpoints.items.len) {
            if (session.state.breakpoints.items[breakpoint_index].id == breakpoint_id) {
                _ = session.state.breakpoints.swapRemove(breakpoint_index);
                found = true;
                break;
            }
            breakpoint_index += 1;
        }
        if (!found) return sendInspectorError(session, id, -32000, "unknown breakpointId");
        var resolved_index: usize = 0;
        while (resolved_index < session.state.resolved_breakpoints.items.len) {
            if (session.state.resolved_breakpoints.items[resolved_index].breakpoint_id == breakpoint_id) {
                _ = session.state.resolved_breakpoints.swapRemove(resolved_index);
            } else resolved_index += 1;
        }
        return sendInspectorJson(session, .{ .id = id, .result = .{} });
    }
    if (std.mem.eql(u8, method, "Runtime.getProperties")) {
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const object_id_value = params_value.object.get("objectId") orelse return sendInspectorError(session, id, -32602, "objectId is required");
        const object_id: u64 = switch (object_id_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "objectId must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "objectId must be an integer"),
        };
        const remote = (inspectorRemote(session.state, session, object_id) orelse return sendInspectorError(session, id, -32000, "unknown or expired objectId")).*;
        var property_arena = std.heap.ArenaAllocator.init(gpa);
        defer property_arena.deinit();
        const properties = inspectorProperties(property_arena.allocator(), session, remote) catch |err| switch (err) {
            error.InvalidRemoteObject => return sendInspectorError(session, id, -32000, "objectId is not expandable in the current state"),
            else => return sendInspectorError(session, id, -32000, @errorName(err)),
        };
        return sendInspectorJson(session, .{ .id = id, .result = .{ .result = properties } });
    }
    if (std.mem.eql(u8, method, "Runtime.releaseObject")) {
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const object_id_value = params_value.object.get("objectId") orelse return sendInspectorError(session, id, -32602, "objectId is required");
        const object_id: u64 = switch (object_id_value) {
            .integer => |integer| if (integer >= 0) @intCast(integer) else return sendInspectorError(session, id, -32602, "objectId must be non-negative"),
            else => return sendInspectorError(session, id, -32602, "objectId must be an integer"),
        };
        var index: usize = 0;
        while (index < session.state.remote_objects.items.len) : (index += 1) {
            const remote = session.state.remote_objects.items[index];
            if (remote.id != object_id or remote.owner != session) continue;
            releaseInspectorRemoteAt(session.state, index);
            return sendInspectorJson(session, .{ .id = id, .result = .{} });
        }
        return sendInspectorError(session, id, -32000, "unknown or expired objectId");
    }
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) {
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const group_value = params_value.object.get("objectGroup") orelse return sendInspectorError(session, id, -32602, "objectGroup is required");
        const group = switch (group_value) {
            .string => |string| string,
            else => return sendInspectorError(session, id, -32602, "objectGroup must be a string"),
        };
        releaseInspectorRemotes(session.state, session, group, false);
        return sendInspectorJson(session, .{ .id = id, .result = .{} });
    }
    if (std.mem.eql(u8, method, "Runtime.evaluate")) {
        const params_value = request.get("params") orelse return sendInspectorError(session, id, -32602, "params are required");
        if (params_value != .object) return sendInspectorError(session, id, -32602, "params must be an object");
        const expression_value = params_value.object.get("expression") orelse return sendInspectorError(session, id, -32602, "expression is required");
        const expression = switch (expression_value) {
            .string => |string| string,
            else => return sendInspectorError(session, id, -32602, "expression must be a string"),
        };
        const object_group = if (params_value.object.get("objectGroup")) |group_value| switch (group_value) {
            .string => |group| group,
            else => return sendInspectorError(session, id, -32602, "objectGroup must be a string"),
        } else "";
        const script = JsString.create(gpa, expression) catch return sendInspectorError(session, id, -32000, "out of memory");
        defer script.release();
        var exception: JSValueRef = null;
        const result = JSEvaluateScript(ctx, @ptrCast(script), null, null, 1, &exception);
        return sendInspectorRemoteObject(session, id, result, exception, object_group);
    }
    return sendInspectorError(session, id, -32601, "method is not implemented by this protocol version");
}

export fn JSCheckScriptSyntax(
    ctx: JSContextRef,
    script: JSStringRef,
    source_url: JSStringRef,
    starting_line_number: c_int,
    exception: ExceptionRef,
) callconv(.c) bool {
    const c = ctxForEvaluation(ctx) orelse return false;
    const source = strFrom(script) orelse {
        setException(c, exception, "TypeError: script is null");
        return false;
    };
    c.checkScriptSyntax(source.bytes) catch |err| {
        setEvaluationException(c, exception, err, source_url, starting_line_number);
        return false;
    };
    return true;
}

export fn JSEvaluateScript(
    ctx: JSContextRef,
    script: JSStringRef,
    this_object: JSObjectRef,
    source_url: JSStringRef,
    starting_line_number: c_int,
    exception: ExceptionRef,
) callconv(.c) JSValueRef {
    // `Context.evaluate()` acquires/releases the per-context GIL for serialized
    // threaded contexts, so this uses the evaluation-specific C-boundary helper
    // instead of `ctxFrom` while still preserving debug affinity checks for
    // non-threaded and true-parallel C contexts.
    const c = ctxForEvaluation(ctx) orelse return null;
    const s = strFrom(script) orelse {
        setException(c, exception, "TypeError: script is null");
        return null;
    };
    const this_value = if (this_object) |_|
        Value.obj(objectArgFrom(c, this_object, exception) orelse return null)
    else
        Value.obj(c.global_object);
    const saved_script_id = c.debug_script_id;
    const saved_start_line = c.debug_script_start_line;
    defer {
        c.debug_script_id = saved_script_id;
        c.debug_script_start_line = saved_start_line;
    }
    const registered_script = c.registerDebugScript(
        s.bytes,
        evaluationSourceName(source_url),
        if (starting_line_number > 0) @intCast(starting_line_number) else 1,
    ) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    c.debug_script_id = registered_script.id;
    c.debug_script_start_line = registered_script.start_line;
    const result = c.evaluateWithThis(s.bytes, this_value) catch |err| {
        // A JS `throw` surfaces the actual thrown value; host failures (parse
        // errors, OOM) surface their error name as a string.
        if (err == error.Throw) {
            const thrown = c.exception orelse Value.str("uncaught exception");
            attachEvaluationRuntimeSourceMetadata(c, thrown, source_url, starting_line_number) catch {};
            if (exception != null) exception[0] = box(c, thrown);
        } else {
            setEvaluationException(c, exception, err, source_url, starting_line_number);
        }
        return null;
    };
    return boxResult(c, exception, result);
}

// ---- JSValue inspection ------------------------------------------------

export fn JSValueGetType(ctx: JSContextRef, v: JSValueRef) callconv(.c) JSType {
    const c = ctxForHandleInspection(ctx) orelse return .invalid;
    const uv = valueFromContext(c, v) orelse return .invalid;
    return switch (uv.kind()) {
        .undefined => .undefined,
        .null => .null,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .object => if (uv.asObj().is_symbol) .symbol else if (uv.asObj().is_bigint) .bigint else .object,
    };
}

export fn JSValueIsUndefined(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    return if (valueFromContext(c, v)) |uv| uv.isUndefined() else false;
}

export fn JSValueIsNull(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    return if (valueFromContext(c, v)) |uv| uv.isNull() else false;
}

export fn JSValueIsBoolean(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    return if (valueFromContext(c, v)) |uv| uv.isBoolean() else false;
}

export fn JSValueIsNumber(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    return if (valueFromContext(c, v)) |uv| uv.isNumber() else false;
}

export fn JSValueIsString(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    return if (valueFromContext(c, v)) |uv| uv.isString() else false;
}

export fn JSValueIsSymbol(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    return JSValueGetType(ctx, v) == .symbol;
}

export fn JSValueIsBigInt(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    return JSValueGetType(ctx, v) == .bigint;
}

export fn JSValueIsObject(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const uv = valueFromContext(c, v) orelse return false;
    return uv.isObject() and !uv.asObj().is_symbol and !uv.asObj().is_bigint;
}

export fn JSValueIsObjectOfClass(ctx: JSContextRef, v: JSValueRef, js_class: JSClassRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const expected = classFrom(js_class) orelse return false;
    const uv = valueFromContext(c, v) orelse return false;
    if (!uv.isObject() or uv.asObj().is_symbol or uv.asObj().is_bigint) return false;
    const owner = uv.asObj().cApiObjectOwner() orelse return false;
    var current = classFrom(owner.class_ref);
    while (current) |item| : (current = item.parent) {
        if (item == expected) return true;
    }
    return false;
}

export fn JSValueIsArray(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const uv = valueFromContext(c, v) orelse return false;
    return uv.isObject() and uv.asObj().is_array;
}

export fn JSValueIsDate(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const uv = valueFromContext(c, v) orelse return false;
    return uv.isObject() and uv.asObj().behavior.is_date;
}

export fn JSValueGetTypedArrayType(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) JSTypedArrayType {
    const c = ctxFrom(ctx) orelse return .none;
    const uv = valueFromContext(c, v) orelse {
        if (v != null) setException(c, exception, "TypeError: value belongs to a different context");
        return .none;
    };
    return typedArrayTypeFromValue(uv);
}

export fn JSValueIsEqual(ctx: JSContextRef, a: JSValueRef, b: JSValueRef, exception: ExceptionRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const lhs = valueArgFrom(c, a, exception) orelse return false;
    const rhs = valueArgFrom(c, b, exception) orelse return false;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return false;
    };
    defer c.popActiveInterpreter(&machine);
    const result = machine.applyBinary(.eq, lhs, rhs) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return false;
    };
    return result.toBoolean();
}

export fn JSValueIsStrictEqual(ctx: JSContextRef, a: JSValueRef, b: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const lhs = valueFromContext(c, a) orelse return false;
    const rhs = valueFromContext(c, b) orelse return false;
    return value.strictEquals(lhs, rhs);
}

export fn JSValueIsInstanceOfConstructor(
    ctx: JSContextRef,
    value_ref: JSValueRef,
    constructor_ref: JSObjectRef,
    exception: ExceptionRef,
) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const candidate = valueArgFrom(c, value_ref, exception) orelse return false;
    const constructor = objectArgFrom(c, constructor_ref, exception) orelse return false;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return false;
    };
    defer c.popActiveInterpreter(&machine);
    return machine.instanceOf(candidate, Value.obj(constructor)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return false;
    };
}

export fn JSValueCompare(
    ctx: JSContextRef,
    left_ref: JSValueRef,
    right_ref: JSValueRef,
    exception: ExceptionRef,
) callconv(.c) JSRelationCondition {
    const c = ctxFrom(ctx) orelse return .undefined;
    const left = valueArgFrom(c, left_ref, exception) orelse return .undefined;
    const right = valueArgFrom(c, right_ref, exception) orelse return .undefined;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return .undefined;
    };
    defer c.popActiveInterpreter(&machine);
    inline for (.{
        .{ .op = ast.BinaryOp.eq, .condition = JSRelationCondition.equal },
        .{ .op = ast.BinaryOp.lt, .condition = JSRelationCondition.less_than },
        .{ .op = ast.BinaryOp.gt, .condition = JSRelationCondition.greater_than },
    }) |comparison| {
        const result = machine.applyBinary(comparison.op, left, right) catch |err| {
            if (err == error.Throw) {
                if (exception != null) exception[0] = box(c, machine.exception);
            } else {
                setException(c, exception, @errorName(err));
            }
            return .undefined;
        };
        if (result.toBoolean()) return comparison.condition;
    }
    return .undefined;
}

export fn JSValueCompareInt64(ctx: JSContextRef, left: JSValueRef, right: i64, exception: ExceptionRef) callconv(.c) JSRelationCondition {
    const right_ref = JSBigIntCreateWithInt64(ctx, right, exception) orelse return .undefined;
    return JSValueCompare(ctx, left, right_ref, exception);
}

export fn JSValueCompareUInt64(ctx: JSContextRef, left: JSValueRef, right: u64, exception: ExceptionRef) callconv(.c) JSRelationCondition {
    const right_ref = JSBigIntCreateWithUInt64(ctx, right, exception) orelse return .undefined;
    return JSValueCompare(ctx, left, right_ref, exception);
}

export fn JSValueCompareDouble(ctx: JSContextRef, left: JSValueRef, right: f64, exception: ExceptionRef) callconv(.c) JSRelationCondition {
    const right_ref = JSValueMakeNumber(ctx, right) orelse return .undefined;
    return JSValueCompare(ctx, left, right_ref, exception);
}

// ---- JSValue constructors ---------------------------------------------

export fn JSValueMakeUndefined(ctx: JSContextRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, Value.undef());
}

export fn JSValueMakeNull(ctx: JSContextRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, Value.nul());
}

export fn JSValueMakeBoolean(ctx: JSContextRef, b: bool) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, Value.boolVal(b));
}

export fn JSValueMakeNumber(ctx: JSContextRef, n: f64) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, Value.num(n));
}

export fn JSValueMakeString(ctx: JSContextRef, str: JSStringRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const s = strFrom(str) orelse return null;
    const copy = c.arena().dupe(u8, s.bytes) catch return null;
    return box(c, Value.strOwned(c.arena(), copy) catch return null);
}

export fn JSValueMakeSymbol(ctx: JSContextRef, description: JSStringRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const desc: ?[]const u8 = if (description) |_| blk: {
        const source = strFrom(description) orelse return null;
        break :blk c.arena().dupe(u8, source.bytes) catch return null;
    } else null;

    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return null;
    defer c.popActiveInterpreter(&machine);
    const symbol = machine.makeSymbol(desc) catch return null;
    return box(c, symbol);
}

const CBigIntInput = union(enum) {
    double: f64,
    signed: i64,
    unsigned: u64,
    string: []const u8,
};

fn makeCBigInt(ctx: JSContextRef, input: CBigIntInput, exception: ExceptionRef) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const result = switch (input) {
        .double => |number| machine.toBigIntValueImpl(Value.num(number), true),
        .signed => |integer| machine.makeBigInt(integer),
        .unsigned => |integer| machine.makeBigInt(integer),
        .string => |string| blk: {
            const string_value = Value.strAlloc(c.arena(), string) catch {
                setException(c, exception, "OutOfMemory");
                return null;
            };
            break :blk machine.toBigIntValueImpl(string_value, true);
        },
    } catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    return boxResult(c, exception, result);
}

export fn JSBigIntCreateWithDouble(ctx: JSContextRef, number: f64, exception: ExceptionRef) callconv(.c) JSValueRef {
    return makeCBigInt(ctx, .{ .double = number }, exception);
}

export fn JSBigIntCreateWithInt64(ctx: JSContextRef, integer: i64, exception: ExceptionRef) callconv(.c) JSValueRef {
    return makeCBigInt(ctx, .{ .signed = integer }, exception);
}

export fn JSBigIntCreateWithUInt64(ctx: JSContextRef, integer: u64, exception: ExceptionRef) callconv(.c) JSValueRef {
    return makeCBigInt(ctx, .{ .unsigned = integer }, exception);
}

export fn JSBigIntCreateWithString(ctx: JSContextRef, string: JSStringRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    const source = strFrom(string) orelse {
        const c = ctxFrom(ctx) orelse return null;
        setException(c, exception, "TypeError: string is null");
        return null;
    };
    return makeCBigInt(ctx, .{ .string = source.bytes }, exception);
}

export fn JSValueMakeFromJSONString(ctx: JSContextRef, string: JSStringRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const source = strFrom(string) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return null;
    defer c.popActiveInterpreter(&machine);
    const input = Value.strAlloc(c.arena(), source.bytes) catch return null;
    const parsed = builtins.jsonParse(&machine, Value.undef(), &.{input}) catch return null;
    return box(c, parsed);
}

export fn JSValueCreateJSONString(
    ctx: JSContextRef,
    value_ref: JSValueRef,
    indent: c_uint,
    exception: ExceptionRef,
) callconv(.c) JSStringRef {
    const c = ctxFrom(ctx) orelse return null;
    const input = valueArgFrom(c, value_ref, exception) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const spacing = Value.num(@floatFromInt(@min(indent, 10)));
    const rendered = builtins.jsonStringify(
        &machine,
        Value.undef(),
        &.{ input, Value.undef(), spacing },
    ) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    if (!rendered.isString()) return null;
    const result = JsString.create(gpa, rendered.asStr()) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    return @ptrCast(result);
}

// ---- JSValue coercion -------------------------------------------------

export fn JSValueToBoolean(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    return if (valueFromContext(c, v)) |uv| uv.toBoolean() else false;
}

export fn JSValueToNumber(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) f64 {
    const c = ctxFrom(ctx) orelse return std.math.nan(f64);
    const val = valueArgFrom(c, v, exception) orelse return std.math.nan(f64);
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return std.math.nan(f64);
    };
    defer c.popActiveInterpreter(&machine);
    return numberConstructorConversion(&machine, val) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return std.math.nan(f64);
    };
}

fn numberConstructorConversion(machine: *interp.Interpreter, input: Value) interp.EvalError!f64 {
    var primitive = input;
    if (primitive.isObject() and !primitive.asObj().is_bigint and !primitive.asObj().is_symbol)
        primitive = try machine.toPrimitive(primitive, .number);
    if (primitive.isObject() and primitive.asObj().is_symbol)
        return machine.throwError("TypeError", "Cannot convert a Symbol value to a number");
    return primitive.toNumber();
}

fn bigIntLow64(object: *Object) u64 {
    if (object.bigIntText()) |text| {
        const negative = text.len > 0 and text[0] == '-';
        const digits = if (negative) text[1..] else text;
        var low: u64 = 0;
        for (digits) |digit| low = low *% 10 +% (digit - '0');
        return if (negative) 0 -% low else low;
    }
    const raw: u128 = @bitCast(object.bigIntValue());
    return @truncate(raw);
}

fn valueToIntegerBits(
    ctx: JSContextRef,
    value_ref: JSValueRef,
    width: enum { bits32, bits64 },
    exception: ExceptionRef,
) ?u64 {
    const c = ctxFrom(ctx) orelse return null;
    const input = valueArgFrom(c, value_ref, exception) orelse return null;
    var bits: u64 = if (input.isObject() and input.asObj().is_bigint)
        bigIntLow64(input.asObj())
    else blk: {
        const gc_saved = gc_mod.setActiveHeap(c.gc);
        defer _ = gc_mod.setActiveHeap(gc_saved);
        const sa_saved = strcell.setActiveArena(c.arena());
        defer _ = strcell.setActiveArena(sa_saved);
        var machine = c.interpreter();
        c.pushActiveInterpreter(&machine) catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        defer c.popActiveInterpreter(&machine);
        const number = machine.toNumberV(input) catch |err| {
            if (err == error.Throw) {
                if (exception != null) exception[0] = box(c, machine.exception);
            } else {
                setException(c, exception, @errorName(err));
            }
            return null;
        };
        break :blk Value.uint64FromF64(number);
    };
    if (width == .bits32) bits &= std.math.maxInt(u32);
    return bits;
}

export fn JSValueToInt32(ctx: JSContextRef, value_ref: JSValueRef, exception: ExceptionRef) callconv(.c) i32 {
    const bits = valueToIntegerBits(ctx, value_ref, .bits32, exception) orelse return 0;
    return @bitCast(@as(u32, @truncate(bits)));
}

export fn JSValueToUInt32(ctx: JSContextRef, value_ref: JSValueRef, exception: ExceptionRef) callconv(.c) u32 {
    const bits = valueToIntegerBits(ctx, value_ref, .bits32, exception) orelse return 0;
    return @truncate(bits);
}

export fn JSValueToInt64(ctx: JSContextRef, value_ref: JSValueRef, exception: ExceptionRef) callconv(.c) i64 {
    const bits = valueToIntegerBits(ctx, value_ref, .bits64, exception) orelse return 0;
    return @bitCast(bits);
}

export fn JSValueToUInt64(ctx: JSContextRef, value_ref: JSValueRef, exception: ExceptionRef) callconv(.c) u64 {
    return valueToIntegerBits(ctx, value_ref, .bits64, exception) orelse 0;
}

export fn JSValueToStringCopy(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) JSStringRef {
    const c = ctxFrom(ctx) orelse return null;
    const val = valueArgFrom(c, v, exception) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const s = machine.toStringV(val) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    const js = JsString.create(gpa, s) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    return @ptrCast(js);
}

export fn JSValueToObject(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const val = valueArgFrom(c, v, exception) orelse return null;
    if (val.isObject() and !val.asObj().is_symbol and !val.asObj().is_bigint) return v;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const obj = machine.toObject(val) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    return boxResult(c, exception, Value.obj(obj));
}

fn valueProtect(ctx: JSContextRef, v: JSValueRef) bool {
    const c = ctxFrom(ctx) orelse return false;
    const boxed = boxedFrom(v) orelse return false;
    if (valueFromContext(c, v) == null) return false;
    const raw = v.?;
    // Shared JSC realms use one VM-lifetime arena, so a handle created by a
    // sibling context is already stable for the entire group lifetime. Precise
    // GC contexts are currently single-realm and retain per-context root tables.
    if (c.gc == null) return true; // arena contexts keep values for the context lifetime.
    if (boxed.owner != c) return false;
    // `c_api_handles` is read by the mid-script parallel collector; guard it
    // under `realm_lock` (a no-op outside parallel_js).
    c.realmLock();
    defer c.realmUnlock();
    for (c.c_api_handles.items) |*h| {
        if (h.ref == raw) {
            h.count = std.math.add(usize, h.count, 1) catch return false;
            return true;
        }
    }
    c.reserveCApiHandlesLocked(1) catch return false;
    c.c_api_handles.appendAssumeCapacity(.{ .ref = raw, .count = 1 });
    return true;
}

fn valueUnprotect(ctx: JSContextRef, v: JSValueRef) bool {
    const c = ctxFrom(ctx) orelse return false;
    const boxed = boxedFrom(v) orelse return false;
    if (valueFromContext(c, v) == null) return false;
    const raw = v.?;
    if (c.gc == null) return true;
    if (boxed.owner != c) return false;
    c.realmLock();
    defer c.realmUnlock();
    for (c.c_api_handles.items, 0..) |*h, i| {
        if (h.ref != raw) continue;
        if (h.count > 1) {
            h.count -= 1;
        } else {
            _ = c.c_api_handles.swapRemove(i);
        }
        return true;
    }
    return false;
}

/// Public JSC ABI: protection failures are intentionally not returned.
export fn JSValueProtect(ctx: JSContextRef, v: JSValueRef) callconv(.c) void {
    _ = valueProtect(ctx, v);
}

/// Public JSC ABI: unmatched or invalid unprotect calls are no-ops.
export fn JSValueUnprotect(ctx: JSContextRef, v: JSValueRef) callconv(.c) void {
    _ = valueUnprotect(ctx, v);
}

/// zig-js extension for hosts that need allocation/validation observability.
export fn ZJSValueProtect(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    return valueProtect(ctx, v);
}

/// zig-js extension for detecting unmatched or invalid unprotect calls.
export fn ZJSValueUnprotect(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    return valueUnprotect(ctx, v);
}

// ---- JSObject construction & properties --------------------------------

export fn JSClassCreate(definition: ?*const JSClassDefinition) callconv(.c) JSClassRef {
    const source = definition orelse return null;
    if (source.version != 0) return null;
    const class = gpa.create(CClass) catch return null;
    class.* = .{ .definition = source.* };
    errdefer gpa.destroy(class);

    if (source.parent_class) |parent_ref| {
        const parent = classFrom(parent_ref) orelse return null;
        if (!retainClass(parent)) return null;
        class.parent = parent;
        class.definition.parent_class = @ptrCast(parent);
    }
    errdefer if (class.parent) |parent| releaseClass(parent);

    if (source.class_name) |name| {
        class.class_name = dupeCString(std.mem.span(name)) catch return null;
        class.definition.class_name = class.class_name.?.ptr;
    }
    errdefer if (class.class_name) |name| gpa.free(name);

    class.static_values = copyStaticValues(source.static_values) catch return null;
    errdefer {
        for (class.static_values) |entry| if (entry.name) |name| gpa.free(std.mem.span(name));
        if (class.static_values.len > 0) gpa.free(class.static_values);
    }
    class.definition.static_values = if (class.static_values.len == 0) null else class.static_values.ptr;

    class.static_functions = copyStaticFunctions(source.static_functions) catch return null;
    class.definition.static_functions = if (class.static_functions.len == 0) null else class.static_functions.ptr;
    return @ptrCast(class);
}

export fn JSClassRetain(js_class: JSClassRef) callconv(.c) JSClassRef {
    const class = classFrom(js_class) orelse return null;
    return if (retainClass(class)) js_class else null;
}

export fn JSClassRelease(js_class: JSClassRef) callconv(.c) void {
    const class = classFrom(js_class) orelse return;
    releaseClass(class);
}

export fn JSObjectMake(ctx: JSContextRef, js_class: JSClassRef, data: ?*anyopaque) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return null;
    defer c.popActiveInterpreter(&machine);
    const value_obj = machine.newObject() catch return null;
    const obj = value_obj.asObj();
    obj.private_data = data;
    obj.private_data_tag = .host;
    const class = classFrom(js_class);
    var owner: ?*value.CApiObjectOwner = null;
    if (class) |item| {
        if ((item.definition.attributes & kJSClassAttributeNoAutomaticPrototype) != 0) {
            installStaticFunctionChain(c, &machine, obj, item) catch return null;
        } else {
            const prototype = ensureClassPrototype(c, &machine, item) catch return null;
            obj.setProtoAtomic(prototype);
        }
        if (!retainClass(item)) return null;
        const created = c.createCApiObjectOwner(@ptrCast(item), finishClassObject) catch {
            releaseClass(item);
            return null;
        };
        owner = created;
        obj.setCApiObjectClass(c.arena(), created, &c_api_class_hooks) catch {
            created.finishOnce();
            return null;
        };
    }
    const object_ref = box(c, Value.obj(obj)) orelse {
        if (owner) |record| record.finishOnce();
        return null;
    };
    if (owner) |record| {
        record.object_ref = object_ref;
        const protected = valueProtect(ctx, object_ref);
        defer {
            if (protected) _ = valueUnprotect(ctx, object_ref);
        }
        initializeClassObject(ctx, object_ref, class.?);
    }
    return object_ref;
}

export fn JSObjectMakeConstructor(
    ctx: JSContextRef,
    js_class: JSClassRef,
    callback: JSObjectCallAsConstructorCallback,
) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const class = classFrom(js_class);
    if (class) |item| if (!retainClass(item)) return null;
    const data = c.arena().create(CApiConstructorData) catch {
        if (class) |item| releaseClass(item);
        return null;
    };
    data.* = .{ .context = c, .class = class, .callback = callback };
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        if (class) |item| releaseClass(item);
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const obj = (machine.newObject() catch {
        if (class) |item| releaseClass(item);
        return null;
    }).asObj();
    const owner_class_ref: *anyopaque = if (class) |item| @ptrCast(item) else @ptrCast(data);
    const owner = c.createCApiObjectOwner(owner_class_ref, finishCApiConstructor) catch {
        if (class) |item| releaseClass(item);
        return null;
    };
    owner.payload = data;
    obj.setCApiObjectClass(c.arena(), owner, &c_api_constructor_hooks) catch {
        owner.finishOnce();
        return null;
    };
    const constructor_ref = box(c, Value.obj(obj)) orelse {
        owner.finishOnce();
        return null;
    };
    owner.object_ref = constructor_ref;
    data.constructor_ref = constructor_ref;
    return constructor_ref;
}

export fn JSObjectGetPrivate(object: JSObjectRef) callconv(.c) ?*anyopaque {
    const obj = objectFromHandleInspection(object) orelse return null;
    return if (obj.private_data_tag == .host) obj.private_data else null;
}

export fn JSObjectSetPrivate(object: JSObjectRef, data: ?*anyopaque) callconv(.c) bool {
    const obj = objectFromHandleInspection(object) orelse return false;
    if (obj.private_data_tag == .host) {
        obj.private_data = data;
        return true;
    }
    if (obj.private_data_tag == .none and obj.private_data == null) {
        obj.private_data = data;
        obj.private_data_tag = .host;
        return true;
    }
    return false;
}

fn collectArgs(c: *Context, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) ?[]Value {
    const args = c.arena().alloc(Value, argc) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        args[i] = valueArgFrom(c, argv[i], exception) orelse return null;
    }
    return args;
}

export fn JSObjectMakeArray(ctx: JSContextRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    if (argc > 0 and argv == null) {
        setException(c, exception, "TypeError: argc > 0 requires non-null argv");
        return null;
    }
    const args = collectArgs(c, argc, argv, exception) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const arr = machine.newArray() catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    const obj = arr.asObj();
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        obj.appendElement(c.arena(), args[i]) catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
    }
    return boxResult(c, exception, arr);
}

const CApiBuiltinConstructor = enum(u2) {
    date,
    error_object,
    regexp,
    function,
};

fn makeBuiltinObject(
    c: *Context,
    constructor_kind: CApiBuiltinConstructor,
    args: []const Value,
    exception: ExceptionRef,
    debug_source_url: ?[]const u8,
    debug_start_line: usize,
) JSObjectRef {
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    machine.debug_dynamic_url_override = debug_source_url;
    machine.debug_dynamic_start_line = debug_start_line;
    const constructor = c.c_api_builtin_constructors[@intFromEnum(constructor_kind)];
    const result = machine.construct(constructor, args) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    if (!result.isObject() or result.asObj().is_symbol or result.asObj().is_bigint) {
        setException(c, exception, "TypeError: constructor returned a non-object");
        return null;
    }
    return boxResult(c, exception, result);
}

fn makeBuiltinObjectFromRefs(
    ctx: JSContextRef,
    constructor_kind: CApiBuiltinConstructor,
    argc: usize,
    argv: [*c]const JSValueRef,
    exception: ExceptionRef,
) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    if (argc > 0 and argv == null) {
        setException(c, exception, "TypeError: argc > 0 requires non-null argv");
        return null;
    }
    const args = collectArgs(c, argc, argv, exception) orelse return null;
    return makeBuiltinObject(c, constructor_kind, args, exception, null, 1);
}

export fn JSObjectMakeDate(ctx: JSContextRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    return makeBuiltinObjectFromRefs(ctx, .date, argc, argv, exception);
}

export fn JSObjectMakeError(ctx: JSContextRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    return makeBuiltinObjectFromRefs(ctx, .error_object, argc, argv, exception);
}

export fn JSObjectMakeRegExp(ctx: JSContextRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    return makeBuiltinObjectFromRefs(ctx, .regexp, argc, argv, exception);
}

export fn JSObjectMakeFunction(
    ctx: JSContextRef,
    name: JSStringRef,
    parameter_count: c_uint,
    parameter_names: [*c]const JSStringRef,
    body: JSStringRef,
    source_url: JSStringRef,
    starting_line_number: c_int,
    exception: ExceptionRef,
) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    if (parameter_count > 0 and parameter_names == null) {
        setException(c, exception, "TypeError: parameterCount > 0 requires parameterNames");
        return null;
    }
    var args = c.arena().alloc(Value, @as(usize, parameter_count) + 1) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    for (0..parameter_count) |index| {
        const parameter = strFrom(parameter_names[index]) orelse {
            setException(c, exception, "TypeError: parameter name is null");
            return null;
        };
        args[index] = Value.strAlloc(c.arena(), parameter.bytes) catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
    }
    const body_bytes = if (strFrom(body)) |string| string.bytes else "";
    args[parameter_count] = Value.strAlloc(c.arena(), body_bytes) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    const function_ref = makeBuiltinObject(
        c,
        .function,
        args,
        exception,
        evaluationSourceName(source_url),
        if (starting_line_number > 0) @intCast(starting_line_number) else 1,
    ) orelse {
        if (exception != null) {
            if (valueFromContext(c, exception[0])) |thrown| {
                attachEvaluationRuntimeSourceMetadata(c, thrown, source_url, starting_line_number) catch {};
            }
        }
        return null;
    };
    const function_object = objectArgFrom(c, function_ref, exception) orelse return null;
    const display_name = if (strFrom(name)) |string| string.bytes else "";
    const name_value = Value.strAlloc(c.arena(), display_name) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    function_object.setOwn(c.arena(), c.root_shape, "name", name_value) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    function_object.setAttr(c.arena(), "name", .{ .writable = false, .enumerable = false, .configurable = true }) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    if (interp.Interpreter.funcOf(Value.obj(function_object))) |function| {
        function.name = c.arena().dupe(u8, display_name) catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        var source = std.ArrayListUnmanaged(u8).empty;
        source.appendSlice(c.arena(), "function ") catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        source.appendSlice(c.arena(), display_name) catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        source.append(c.arena(), '(') catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        for (0..parameter_count) |index| {
            if (index != 0) source.append(c.arena(), ',') catch {
                setException(c, exception, "OutOfMemory");
                return null;
            };
            source.appendSlice(c.arena(), strFrom(parameter_names[index]).?.bytes) catch {
                setException(c, exception, "OutOfMemory");
                return null;
            };
        }
        source.appendSlice(c.arena(), "\n) {\n") catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        source.appendSlice(c.arena(), body_bytes) catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        source.appendSlice(c.arena(), "\n}") catch {
            setException(c, exception, "OutOfMemory");
            return null;
        };
        function.source = source.items;
    }
    return function_ref;
}

export fn JSObjectMakeDeferredPromise(ctx: JSContextRef, resolve: [*c]JSObjectRef, reject: [*c]JSObjectRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    if (resolve == null or reject == null) {
        setException(c, exception, "TypeError: resolve and reject out pointers are required");
        return null;
    }
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);

    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const obj = promise.newPromise(&machine) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    const p: *promise.Promise = @ptrCast(@alignCast(obj.promiseData().?));
    const capability = promise.nativeResolveReject(&machine, p) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };

    resolve[0] = box(c, capability.resolve) orelse {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    reject[0] = box(c, capability.reject) orelse {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    return box(c, Value.obj(obj)) orelse {
        setException(c, exception, "OutOfMemory");
        return null;
    };
}

fn objectArgFrom(ctx: *Context, object: JSObjectRef, exception: ExceptionRef) ?*Object {
    const value_ref = valueArgFrom(ctx, object, exception) orelse return null;
    return if (value_ref.isObject()) value_ref.asObj() else {
        setException(ctx, exception, "TypeError: object is not an object");
        return null;
    };
}

fn makeTypedArrayObject(c: *Context, kind: value.TAKind, args: []const Value, exception: ExceptionRef) JSObjectRef {
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const result = machine.makeTypedArray(kind, args) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    return boxResult(c, exception, result);
}

const ExternalArrayBuffer = struct {
    object: *Object,
    owner: *value.ExternalBufferOwner,
};

fn releaseExternalInput(bytes: ?*anyopaque, deallocator: JSTypedArrayBytesDeallocator, deallocator_context: ?*anyopaque) void {
    if (deallocator) |callback| callback(bytes, deallocator_context);
}

fn makeExternalArrayBuffer(
    c: *Context,
    bytes: ?*anyopaque,
    byte_length: usize,
    deallocator: JSTypedArrayBytesDeallocator,
    deallocator_context: ?*anyopaque,
    exception: ExceptionRef,
) ?ExternalArrayBuffer {
    if (byte_length > 0 and bytes == null) {
        releaseExternalInput(bytes, deallocator, deallocator_context);
        setException(c, exception, "TypeError: non-empty external buffer requires non-null bytes");
        return null;
    }
    const owner = c.createExternalBufferOwner(bytes, deallocator, deallocator_context) catch {
        releaseExternalInput(bytes, deallocator, deallocator_context);
        setException(c, exception, "OutOfMemory");
        return null;
    };
    var owner_transferred = false;
    defer {
        if (!owner_transferred) _ = owner.release();
    }
    const data: []u8 = if (byte_length == 0)
        &.{}
    else
        @as([*]u8, @ptrCast(bytes.?))[0..byte_length];

    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const object = machine.makeExternalArrayBuffer(data, owner) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    owner_transferred = true;
    return .{ .object = object, .owner = owner };
}

export fn JSObjectMakeTypedArray(ctx: JSContextRef, array_type: JSTypedArrayType, length: usize, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const kind = typedArrayKind(array_type) orelse return null;
    const args = [_]Value{Value.num(@floatFromInt(length))};
    return makeTypedArrayObject(c, kind, &args, exception);
}

export fn JSObjectMakeTypedArrayWithBytesNoCopy(
    ctx: JSContextRef,
    array_type: JSTypedArrayType,
    bytes: ?*anyopaque,
    byte_length: usize,
    bytes_deallocator: JSTypedArrayBytesDeallocator,
    deallocator_context: ?*anyopaque,
    exception: ExceptionRef,
) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse {
        releaseExternalInput(bytes, bytes_deallocator, deallocator_context);
        return null;
    };
    const kind = typedArrayKind(array_type) orelse {
        releaseExternalInput(bytes, bytes_deallocator, deallocator_context);
        return null;
    };
    const element_size = kind.byteSize();
    if (byte_length % element_size != 0) {
        releaseExternalInput(bytes, bytes_deallocator, deallocator_context);
        setException(c, exception, "RangeError: external byte length is not a multiple of the element size");
        return null;
    }
    const external = makeExternalArrayBuffer(c, bytes, byte_length, bytes_deallocator, deallocator_context, exception) orelse return null;
    const args = [_]Value{Value.obj(external.object)};
    return makeTypedArrayObject(c, kind, &args, exception) orelse {
        _ = external.owner.release();
        return null;
    };
}

export fn JSObjectMakeArrayBufferWithBytesNoCopy(
    ctx: JSContextRef,
    bytes: ?*anyopaque,
    byte_length: usize,
    bytes_deallocator: JSTypedArrayBytesDeallocator,
    deallocator_context: ?*anyopaque,
    exception: ExceptionRef,
) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse {
        releaseExternalInput(bytes, bytes_deallocator, deallocator_context);
        return null;
    };
    const external = makeExternalArrayBuffer(c, bytes, byte_length, bytes_deallocator, deallocator_context, exception) orelse return null;
    return boxResult(c, exception, Value.obj(external.object)) orelse {
        _ = external.owner.release();
        return null;
    };
}

export fn JSObjectMakeTypedArrayWithArrayBuffer(ctx: JSContextRef, array_type: JSTypedArrayType, buffer: JSObjectRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const kind = typedArrayKind(array_type) orelse return null;
    const buffer_obj = objectArgFrom(c, buffer, exception) orelse return null;
    const buffer_data = buffer_obj.arrayBuffer() orelse {
        setException(c, exception, "TypeError: buffer is not an ArrayBuffer");
        return null;
    };
    if (buffer_data.is_shared) {
        setException(c, exception, "TypeError: buffer is not an ArrayBuffer");
        return null;
    }
    const args = [_]Value{Value.obj(buffer_obj)};
    return makeTypedArrayObject(c, kind, &args, exception);
}

export fn JSObjectMakeTypedArrayWithArrayBufferAndOffset(
    ctx: JSContextRef,
    array_type: JSTypedArrayType,
    buffer: JSObjectRef,
    byte_offset: usize,
    length: usize,
    exception: ExceptionRef,
) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const kind = typedArrayKind(array_type) orelse return null;
    const buffer_obj = objectArgFrom(c, buffer, exception) orelse return null;
    const buffer_data = buffer_obj.arrayBuffer() orelse {
        setException(c, exception, "TypeError: buffer is not an ArrayBuffer");
        return null;
    };
    if (buffer_data.is_shared) {
        setException(c, exception, "TypeError: buffer is not an ArrayBuffer");
        return null;
    }
    const args = [_]Value{
        Value.obj(buffer_obj),
        Value.num(@floatFromInt(byte_offset)),
        Value.num(@floatFromInt(length)),
    };
    return makeTypedArrayObject(c, kind, &args, exception);
}

fn typedArrayArgFrom(c: *Context, object: JSObjectRef, exception: ExceptionRef) ?*value.TypedArrayData {
    const obj = objectArgFrom(c, object, exception) orelse return null;
    return obj.typedArray();
}

fn currentTypedArrayLength(c: *Context, ta: *const value.TypedArrayData, exception: ExceptionRef) ?usize {
    const buffer_data = ta.buffer.arrayBuffer() orelse {
        setException(c, exception, "TypeError: TypedArray has no ArrayBuffer");
        return null;
    };
    buffer_data.lockBuffer();
    defer buffer_data.unlockBuffer();
    return ta.currentLength() orelse {
        setException(c, exception, "TypeError: TypedArray is detached or out of bounds");
        return null;
    };
}

export fn JSObjectGetTypedArrayBytesPtr(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) ?*anyopaque {
    const c = ctxFrom(ctx) orelse return null;
    const ta = typedArrayArgFrom(c, object, exception) orelse return null;
    const buffer_data = ta.buffer.arrayBuffer() orelse return null;
    buffer_data.lockBuffer();
    defer buffer_data.unlockBuffer();
    const length = ta.currentLength() orelse {
        setException(c, exception, "TypeError: TypedArray is detached or out of bounds");
        return null;
    };
    const byte_length = std.math.mul(usize, length, ta.kind.byteSize()) catch {
        setException(c, exception, "RangeError: TypedArray byte length overflow");
        return null;
    };
    const bytes = buffer_data.bytes();
    if (ta.byte_offset > bytes.len or byte_length > bytes.len - ta.byte_offset) {
        setException(c, exception, "TypeError: TypedArray is detached or out of bounds");
        return null;
    }
    return @ptrCast(bytes.ptr + ta.byte_offset);
}

export fn JSObjectGetTypedArrayLength(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) usize {
    const c = ctxFrom(ctx) orelse return 0;
    const ta = typedArrayArgFrom(c, object, exception) orelse return 0;
    return currentTypedArrayLength(c, ta, exception) orelse 0;
}

export fn JSObjectGetTypedArrayByteLength(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) usize {
    const c = ctxFrom(ctx) orelse return 0;
    const ta = typedArrayArgFrom(c, object, exception) orelse return 0;
    const length = currentTypedArrayLength(c, ta, exception) orelse return 0;
    return std.math.mul(usize, length, ta.kind.byteSize()) catch {
        setException(c, exception, "RangeError: TypedArray byte length overflow");
        return 0;
    };
}

export fn JSObjectGetTypedArrayByteOffset(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) usize {
    const c = ctxFrom(ctx) orelse return 0;
    const ta = typedArrayArgFrom(c, object, exception) orelse return 0;
    _ = currentTypedArrayLength(c, ta, exception) orelse return 0;
    return ta.byte_offset;
}

export fn JSObjectGetTypedArrayBuffer(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const ta = typedArrayArgFrom(c, object, exception) orelse return null;
    _ = currentTypedArrayLength(c, ta, exception) orelse return null;
    return boxResult(c, exception, Value.obj(ta.buffer));
}

export fn JSObjectGetArrayBufferBytesPtr(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) ?*anyopaque {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectArgFrom(c, object, exception) orelse return null;
    const buffer_data = obj.arrayBuffer() orelse return null;
    if (buffer_data.is_shared) return null;
    buffer_data.lockBuffer();
    defer buffer_data.unlockBuffer();
    if (buffer_data.isDetached()) {
        setException(c, exception, "TypeError: ArrayBuffer is detached");
        return null;
    }
    return @ptrCast(buffer_data.bytes().ptr);
}

export fn JSObjectGetArrayBufferByteLength(ctx: JSContextRef, object: JSObjectRef, exception: ExceptionRef) callconv(.c) usize {
    const c = ctxFrom(ctx) orelse return 0;
    const obj = objectArgFrom(c, object, exception) orelse return 0;
    const buffer_data = obj.arrayBuffer() orelse return 0;
    if (buffer_data.is_shared) return 0;
    buffer_data.lockBuffer();
    defer buffer_data.unlockBuffer();
    if (buffer_data.isDetached()) {
        setException(c, exception, "TypeError: ArrayBuffer is detached");
        return 0;
    }
    return buffer_data.bytes().len;
}

export fn JSObjectGetPrototype(ctx: JSContextRef, object: JSObjectRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectArgFrom(c, object, null) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return null;
    defer c.popActiveInterpreter(&machine);
    const result = machine.getPrototypeOfObject(obj) catch return null;
    return box(c, result);
}

export fn JSObjectSetPrototype(ctx: JSContextRef, object: JSObjectRef, prototype: JSValueRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    const obj = objectArgFrom(c, object, null) orelse return;
    const proto_value = valueFromContext(c, prototype) orelse return;
    const new_proto: ?*Object = if (proto_value.isNull()) null else if (proto_value.isObject() and
        !proto_value.asObj().is_symbol and !proto_value.asObj().is_bigint)
        proto_value.asObj()
    else
        return;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return;
    defer c.popActiveInterpreter(&machine);
    _ = machine.setPrototypeOfObject(obj, new_proto) catch return;
}

export fn JSObjectHasProperty(ctx: JSContextRef, object: JSObjectRef, name: JSStringRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const obj = objectArgFrom(c, object, null) orelse return false;
    const key = strFrom(name) orelse return false;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return false;
    defer c.popActiveInterpreter(&machine);
    return machine.hasPropertyResult(obj, key.bytes) catch false;
}

fn propertyKeyBytes(c: *Context, machine: *interp.Interpreter, key_ref: JSValueRef, exception: ExceptionRef) ?[]const u8 {
    const input = valueArgFrom(c, key_ref, exception) orelse return null;
    const key = machine.toPropertyKeyValue(input) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    if (key.isString()) return key.asStr();
    if (key.isObject() and key.asObj().is_symbol) return key.asObj().symbolKey();
    return key.toString(c.arena()) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
}

export fn JSObjectHasPropertyForKey(ctx: JSContextRef, object: JSObjectRef, property_key: JSValueRef, exception: ExceptionRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const obj = objectArgFrom(c, object, exception) orelse return false;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return false;
    };
    defer c.popActiveInterpreter(&machine);
    const key = propertyKeyBytes(c, &machine, property_key, exception) orelse return false;
    return machine.hasPropertyResult(obj, key) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return false;
    };
}

export fn JSObjectGetProperty(ctx: JSContextRef, object: JSObjectRef, name: JSStringRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectArgFrom(c, object, exception) orelse return null;
    const key = strFrom(name) orelse {
        setException(c, exception, "TypeError: property name is null");
        return null;
    };
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const result = machine.getProperty(Value.obj(obj), key.bytes) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    return boxResult(c, exception, result);
}

export fn JSObjectGetPropertyForKey(ctx: JSContextRef, object: JSObjectRef, property_key: JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectArgFrom(c, object, exception) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const key = propertyKeyBytes(c, &machine, property_key, exception) orelse return null;
    const result = machine.getProperty(Value.obj(obj), key) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    return boxResult(c, exception, result);
}

export fn JSObjectSetProperty(ctx: JSContextRef, object: JSObjectRef, name: JSStringRef, val: JSValueRef, attrs: c_uint, exception: ExceptionRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    const obj = objectArgFrom(c, object, exception) orelse return;
    const key = strFrom(name) orelse {
        setException(c, exception, "TypeError: property name is null");
        return;
    };
    const property_value = valueArgFrom(c, val, exception) orelse return;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return;
    };
    defer c.popActiveInterpreter(&machine);
    const had_own = interp.objectHasOwn(obj, key.bytes);
    const accepted = machine.setMemberResult(Value.obj(obj), key.bytes, property_value, Value.obj(obj)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return;
    };
    if (!accepted) {
        setException(c, exception, "TypeError: property assignment was rejected");
        return;
    }
    if (!had_own and interp.objectHasOwn(obj, key.bytes)) {
        obj.setAttr(c.arena(), key.bytes, propAttrFromC(attrs)) catch {
            setException(c, exception, "OutOfMemory");
        };
    }
}

export fn JSObjectDeleteProperty(ctx: JSContextRef, object: JSObjectRef, name: JSStringRef, exception: ExceptionRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const obj = objectArgFrom(c, object, exception) orelse return false;
    const key = strFrom(name) orelse {
        setException(c, exception, "TypeError: property name is null");
        return false;
    };
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return false;
    };
    defer c.popActiveInterpreter(&machine);
    return machine.deleteOwn(obj, key.bytes) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return false;
    };
}

export fn JSObjectSetPropertyForKey(
    ctx: JSContextRef,
    object: JSObjectRef,
    property_key: JSValueRef,
    val: JSValueRef,
    attrs: c_uint,
    exception: ExceptionRef,
) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    const obj = objectArgFrom(c, object, exception) orelse return;
    const property_value = valueArgFrom(c, val, exception) orelse return;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return;
    };
    defer c.popActiveInterpreter(&machine);
    const key = propertyKeyBytes(c, &machine, property_key, exception) orelse return;
    const had_own = interp.objectHasOwn(obj, key);
    const accepted = machine.setMemberResult(Value.obj(obj), key, property_value, Value.obj(obj)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return;
    };
    if (!accepted) {
        setException(c, exception, "TypeError: property assignment was rejected");
        return;
    }
    if (!had_own and interp.objectHasOwn(obj, key)) {
        obj.setAttr(c.arena(), key, propAttrFromC(attrs)) catch {
            setException(c, exception, "OutOfMemory");
        };
    }
}

export fn JSObjectDeletePropertyForKey(ctx: JSContextRef, object: JSObjectRef, property_key: JSValueRef, exception: ExceptionRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const obj = objectArgFrom(c, object, exception) orelse return false;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return false;
    };
    defer c.popActiveInterpreter(&machine);
    const key = propertyKeyBytes(c, &machine, property_key, exception) orelse return false;
    return machine.deleteOwn(obj, key) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return false;
    };
}

export fn JSObjectGetPropertyAtIndex(ctx: JSContextRef, object: JSObjectRef, index: c_uint, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectArgFrom(c, object, exception) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    const key = std.fmt.allocPrint(c.arena(), "{d}", .{index}) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const result = machine.getProperty(Value.obj(obj), key) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    return boxResult(c, exception, result);
}

export fn JSObjectSetPropertyAtIndex(ctx: JSContextRef, object: JSObjectRef, index: c_uint, val: JSValueRef, exception: ExceptionRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    const obj = objectArgFrom(c, object, exception) orelse return;
    const property_value = valueArgFrom(c, val, exception) orelse return;
    const key = std.fmt.allocPrint(c.arena(), "{d}", .{index}) catch {
        setException(c, exception, "OutOfMemory");
        return;
    };
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return;
    };
    defer c.popActiveInterpreter(&machine);
    const accepted = machine.setMemberResult(Value.obj(obj), key, property_value, Value.obj(obj)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return;
    };
    if (!accepted) setException(c, exception, "TypeError: property assignment was rejected");
}

export fn JSObjectCallAsFunction(ctx: JSContextRef, function: JSObjectRef, this_object: JSObjectRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    if (argc > 0 and argv == null) {
        setException(c, exception, "TypeError: argc > 0 requires non-null argv");
        return null;
    }
    const obj = objectArgFrom(c, function, exception) orelse {
        setException(c, exception, "TypeError: value is not a function");
        return null;
    };
    const this_ref = if (this_object) |_|
        if (objectArgFrom(c, this_object, exception) != null) this_object else return null
    else
        box(c, Value.obj(c.global_object)) orelse {
            setException(c, exception, "OutOfMemory");
            return null;
        };
    const args = collectArgs(c, argc, argv, exception) orelse return null;
    if (!obj.isCallableObject()) return null;
    // C-ABI host callbacks run directly across the FFI boundary.
    if (obj.hostCallback()) |cb| {
        const result = cb(ctx, function, this_ref, argc, argv, exception);
        if (result) |ref| {
            _ = valueArgFrom(c, ref, exception) orelse return null;
            return result;
        }
        if (exception != null and exception[0] != null) {
            _ = valueArgFrom(c, exception[0], exception) orelse return null;
            return null;
        }
        setException(c, exception, "TypeError: host callback returned null without exception");
        return null;
    }
    // JS functions / native builtins / error constructors run on the interpreter.
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var interpreter = c.interpreter();
    c.pushActiveInterpreter(&interpreter) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&interpreter);
    const this_value = valueArgFrom(c, this_ref, exception) orelse return null;
    const res = interpreter.callValueWithThis(Value.obj(obj), args, this_value) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, interpreter.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    return boxResult(c, exception, res);
}

fn hostCallbackNative(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(ctx));
    const obj = machine.active_native orelse {
        machine.exception = Value.str("TypeError: host callback missing callee");
        return error.Throw;
    };
    const cb = obj.hostCallback() orelse {
        machine.exception = Value.str("TypeError: host callback missing callback");
        return error.Throw;
    };
    const c: *Context = @ptrCast(@alignCast(obj.hostCallbackContext() orelse {
        machine.exception = Value.str("TypeError: host callback missing context");
        return error.Throw;
    }));
    const js_args = try machine.arena.alloc(JSValueRef, args.len);
    for (args, js_args) |arg, *slot| slot.* = box(c, arg);
    var exception: JSValueRef = null;
    const result = cb(@ptrCast(c), box(c, Value.obj(obj)), box(c, this), args.len, js_args.ptr, &exception);
    if (result) |ref| return valueFromContext(c, ref) orelse return machine.throwError("TypeError", "host callback returned invalid value");
    if (exception) |ref| {
        machine.exception = valueFromContext(c, ref) orelse Value.str("TypeError: host callback set invalid exception");
        return error.Throw;
    }
    return machine.throwError("TypeError", "host callback returned null without exception");
}

fn makeHostFunctionObject(
    c: *Context,
    machine: *interp.Interpreter,
    name: []const u8,
    callback: JSObjectCallAsFunctionCallback,
) !*Object {
    const cb = callback orelse return error.InvalidCallback;
    const obj = try gc_mod.allocObject(c.gc, c.arena());
    obj.* = .{ .native = hostCallbackNative, .proto = machine.functionProto() };
    try obj.setHostCallback(c.arena(), cb, c);
    const name_copy = try c.arena().dupe(u8, name);
    try obj.setOwn(c.arena(), c.root_shape, "name", try Value.strOwned(c.arena(), name_copy));
    try obj.setAttr(c.arena(), "name", .{ .writable = false, .enumerable = false, .configurable = true });
    return obj;
}

fn installStaticFunctions(
    c: *Context,
    machine: *interp.Interpreter,
    target: *Object,
    class: *CClass,
) !void {
    for (class.static_functions) |entry| {
        const name_ptr = entry.name orelse continue;
        const callback = entry.call_as_function orelse continue;
        const name = std.mem.span(name_ptr);
        const function = try makeHostFunctionObject(c, machine, name, callback);
        try target.setOwn(c.arena(), c.root_shape, name, Value.obj(function));
        try target.setAttr(c.arena(), name, propAttrFromC(entry.attributes));
    }
}

fn installStaticFunctionChain(
    c: *Context,
    machine: *interp.Interpreter,
    target: *Object,
    class: *CClass,
) !void {
    if (class.parent) |parent| try installStaticFunctionChain(c, machine, target, parent);
    try installStaticFunctions(c, machine, target, class);
}

fn ensureClassPrototype(c: *Context, machine: *interp.Interpreter, class: *CClass) !*Object {
    const class_ref: *anyopaque = @ptrCast(class);
    if (c.findCApiClassPrototype(class_ref)) |prototype| return prototype;

    const prototype = (try machine.newObject()).asObj();
    if (class.parent) |parent| {
        if ((parent.definition.attributes & kJSClassAttributeNoAutomaticPrototype) == 0) {
            prototype.setProtoAtomic(try ensureClassPrototype(c, machine, parent));
        } else {
            try installStaticFunctionChain(c, machine, prototype, parent);
        }
    }
    try installStaticFunctions(c, machine, prototype, class);
    if (!retainClass(class)) return error.ReferenceCountOverflow;
    c.createCApiClassPrototype(class_ref, prototype, finishClassPrototype) catch |err| {
        releaseClass(class);
        return err;
    };
    return prototype;
}

export fn JSObjectMakeFunctionWithCallback(ctx: JSContextRef, name: JSStringRef, callback: JSObjectCallAsFunctionCallback) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const cb = callback orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return null;
    defer c.popActiveInterpreter(&machine);
    const name_bytes = if (strFrom(name)) |s| s.bytes else "";
    const obj = makeHostFunctionObject(c, &machine, name_bytes, cb) catch return null;
    return box(c, Value.obj(obj));
}

export fn JSObjectCallAsConstructor(ctx: JSContextRef, constructor: JSObjectRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    if (argc > 0 and argv == null) {
        setException(c, exception, "TypeError: argc > 0 requires non-null argv");
        return null;
    }
    const obj = objectArgFrom(c, constructor, exception) orelse {
        setException(c, exception, "TypeError: value is not a constructor");
        return null;
    };
    const args = collectArgs(c, argc, argv, exception) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var interpreter = c.interpreter();
    c.pushActiveInterpreter(&interpreter) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&interpreter);
    const res = interpreter.construct(Value.obj(obj), args) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, interpreter.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    return boxResult(c, exception, res);
}

export fn JSObjectIsFunction(ctx: JSContextRef, object: JSObjectRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const val = valueFromContext(c, object) orelse return false;
    return val.isObject() and val.asObj().isCallableObject();
}

export fn JSObjectIsConstructor(ctx: JSContextRef, object: JSObjectRef) callconv(.c) bool {
    const c = ctxForHandleInspection(ctx) orelse return false;
    const val = valueFromContext(c, object) orelse return false;
    return val.isObject() and interp.isConstructorValue(val);
}

export fn JSObjectCopyPropertyNames(ctx: JSContextRef, object: JSObjectRef) callconv(.c) JSPropertyNameArrayRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectArgFrom(c, object, null) orelse return null;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch return null;
    defer c.popActiveInterpreter(&machine);
    const keys = machine.cApiPropertyNameSnapshot(obj) catch return null;
    const array = gpa.create(PropertyNameArray) catch return null;
    errdefer gpa.destroy(array);
    const names = gpa.alloc(*JsString, keys.len) catch return null;
    errdefer gpa.free(names);
    var initialized: usize = 0;
    errdefer for (names[0..initialized]) |name| name.release();
    for (keys, names) |key, *slot| {
        slot.* = JsString.create(gpa, key) catch return null;
        initialized += 1;
    }
    array.* = .{ .names = names };
    return @ptrCast(array);
}

export fn JSPropertyNameArrayRetain(ref: JSPropertyNameArrayRef) callconv(.c) JSPropertyNameArrayRef {
    const array = propertyNameArrayFrom(ref) orelse return null;
    var current = array.ref_count.load(.acquire);
    while (true) {
        if (current == std.math.maxInt(usize)) return null;
        if (array.ref_count.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |actual| {
            current = actual;
        } else return ref;
    }
}

export fn JSPropertyNameArrayRelease(ref: JSPropertyNameArrayRef) callconv(.c) void {
    const array = propertyNameArrayFrom(ref) orelse return;
    var current = array.ref_count.load(.acquire);
    while (true) {
        std.debug.assert(current > 0);
        if (array.ref_count.cmpxchgWeak(current, current - 1, .acq_rel, .acquire)) |actual| {
            current = actual;
        } else {
            if (current == 1) destroyPropertyNameArray(array);
            return;
        }
    }
}

export fn JSPropertyNameArrayGetCount(ref: JSPropertyNameArrayRef) callconv(.c) usize {
    return if (propertyNameArrayFrom(ref)) |array| array.names.len else 0;
}

export fn JSPropertyNameArrayGetNameAtIndex(ref: JSPropertyNameArrayRef, index: usize) callconv(.c) JSStringRef {
    const array = propertyNameArrayFrom(ref) orelse return null;
    if (index >= array.names.len) return null;
    return @ptrCast(array.names[index]);
}

export fn JSPropertyNameAccumulatorAddName(ref: JSPropertyNameAccumulatorRef, property_name: JSStringRef) callconv(.c) void {
    const accumulator: *PropertyNameAccumulator = @ptrCast(@alignCast(ref orelse return));
    const name = strFrom(property_name) orelse return;
    accumulator.addBytes(name.bytes);
}

// ---- JSString lifecycle ------------------------------------------------

export fn JSStringCreateWithCharacters(chars: [*c]const u16, num_chars: usize) callconv(.c) JSStringRef {
    if (chars == null and num_chars != 0) return null;
    const units: []const u16 = if (num_chars == 0) &.{} else chars[0..num_chars];
    const js = JsString.createUtf16(gpa, units) catch return null;
    return @ptrCast(js);
}

export fn JSStringCreateWithUTF8CString(utf8: [*c]const u8) callconv(.c) JSStringRef {
    if (utf8 == null) return null;
    const js = JsString.create(gpa, std.mem.sliceTo(utf8, 0)) catch return null;
    return @ptrCast(js);
}

export fn JSStringRetain(str: JSStringRef) callconv(.c) JSStringRef {
    const s = strFrom(str) orelse return null;
    _ = s.tryRetain() orelse return null;
    return str;
}

export fn JSStringRelease(str: JSStringRef) callconv(.c) void {
    const s = strFrom(str) orelse return;
    s.release();
}

export fn JSStringGetLength(str: JSStringRef) callconv(.c) usize {
    const s = strFrom(str) orelse return 0;
    return s.utf16Len();
}

export fn JSStringGetCharactersPtr(str: JSStringRef) callconv(.c) [*c]const u16 {
    const s = strFrom(str) orelse return null;
    return s.utf16.ptr;
}

export fn JSStringGetMaximumUTF8CStringSize(str: JSStringRef) callconv(.c) usize {
    const s = strFrom(str) orelse return 0;
    const payload = std.math.mul(usize, s.utf16.len, 3) catch return std.math.maxInt(usize);
    return std.math.add(usize, payload, 1) catch std.math.maxInt(usize);
}

export fn JSStringGetUTF8CString(str: JSStringRef, buffer: [*c]u8, buffer_size: usize) callconv(.c) usize {
    const s = strFrom(str) orelse return 0;
    if (buffer_size == 0) return 0;
    if (buffer == null) return 0;
    var copy_len = @min(s.bytes.len, buffer_size - 1);
    if (copy_len < s.bytes.len) {
        while (copy_len > 0 and s.bytes[copy_len] & 0xC0 == 0x80) copy_len -= 1;
    }
    @memcpy(buffer[0..copy_len], s.bytes[0..copy_len]);
    buffer[copy_len] = 0;
    return copy_len + 1; // bytes written, including the null terminator
}

export fn JSStringIsEqual(a: JSStringRef, b: JSStringRef) callconv(.c) bool {
    const left = strFrom(a) orelse return false;
    const right = strFrom(b) orelse return false;
    return std.mem.eql(u16, left.utf16, right.utf16);
}

export fn JSStringIsEqualToUTF8CString(a: JSStringRef, b: [*c]const u8) callconv(.c) bool {
    const left = strFrom(a) orelse return false;
    if (b == null) return false;
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(gpa, std.mem.sliceTo(b, 0)) catch return false;
    defer gpa.free(utf16);
    return std.mem.eql(u16, left.utf16, utf16);
}

// ---- JSWorker: embedder worker agents (issue #1 Phase 5) ----------------
//
// A minimal C surface over `src/worker.zig`: each worker owns its own OS
// thread and `Context`, and messages cross the boundary as structured-clone
// bytes (the only safe inter-realm transfer — see the threading rules above).
// A `JSWorkerRef` is itself thread-affine to its creator: post/receive/
// terminate/release must all run on the thread that called `JSWorkerCreate`.
// Values posted or received are (de)serialized against the `JSContextRef`
// passed to each call, so only that context's handles are ever touched here.

pub const JSWorkerRef = ?*anyopaque;
pub const ZJSWorkerInspectorSessionRef = ?*anyopaque;

pub const ZJSInspectorTargetKind = WorkerMod.Worker.InspectorTargetKind;
pub const ZJSInspectorTargetState = WorkerMod.Worker.InspectorTargetState;

pub const ZJSInspectorTargetInfo = extern struct {
    id: u64,
    kind: ZJSInspectorTargetKind,
    state: ZJSInspectorTargetState,
};

pub const ZJSWorkerInspectorPumpResult = enum(c_uint) {
    message = 0,
    timeout = 1,
    closed = 2,
};

const CWorkerInspectorSession = struct {
    client: *WorkerMod.InspectorClient,
    callback: *const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
};

fn workerInspectorBackendCreate(
    ctx: *Context,
    callback: WorkerMod.InspectorMessageCallback,
    user_data: ?*anyopaque,
    pause_wait_ctx: *anyopaque,
    pause_wait_hook: WorkerMod.InspectorPauseWaitHook,
) ?*anyopaque {
    JSGlobalContextSetInspectable(@ptrCast(ctx), true);
    return createInspectorSession(
        @ptrCast(ctx),
        callback,
        user_data,
        pause_wait_ctx,
        pause_wait_hook,
    );
}

fn workerInspectorBackendDispatch(session: *anyopaque, message: []const u8) bool {
    return ZJSInspectorSessionDispatch(session, message.ptr, message.len);
}

fn workerInspectorBackendRelease(session: *anyopaque) void {
    ZJSInspectorSessionRelease(session);
}

const worker_inspector_backend: WorkerMod.InspectorBackend = .{
    .create = workerInspectorBackendCreate,
    .dispatch = workerInspectorBackendDispatch,
    .release = workerInspectorBackendRelease,
};

fn workerFrom(ref: JSWorkerRef) ?*WorkerMod.Worker {
    const w: *WorkerMod.Worker = @ptrCast(@alignCast(ref orelse return null));
    if (!w.isOwnerThread()) return null;
    return w;
}

/// Spawn a worker running `source` (a script) in a fresh realm on its own
/// thread. Returns null on spawn failure. The worker installs
/// `globalThis.onmessage` from its own script and replies via `postMessage`.
export fn JSWorkerCreate(source: JSStringRef) callconv(.c) JSWorkerRef {
    const s = strFrom(source) orelse return null;
    const w = WorkerMod.Worker.spawnWith(s.bytes, .{ .inspector_backend = &worker_inspector_backend }) catch return null;
    return @ptrCast(w);
}

/// Spawn a worker whose inbox and outbox share explicit nonblocking delivery
/// limits. Zero is a real zero limit, not a request for a default.
export fn JSWorkerCreateWithLimits(
    source: JSStringRef,
    max_message_bytes: usize,
    max_queued_bytes: usize,
    max_queued_messages: usize,
) callconv(.c) JSWorkerRef {
    const s = strFrom(source) orelse return null;
    const limits: WorkerMod.ChannelLimits = .{
        .max_message_bytes = max_message_bytes,
        .max_queued_bytes = max_queued_bytes,
        .max_queued_messages = max_queued_messages,
    };
    const w = WorkerMod.Worker.spawnWith(s.bytes, .{
        .inbox_limits = limits,
        .outbox_limits = limits,
        .inspector_backend = &worker_inspector_backend,
    }) catch return null;
    return @ptrCast(w);
}

/// Snapshot the stable inspector identity and lifecycle metadata for a worker.
/// The id is process-wide, non-zero, and never derived from the Worker address.
export fn ZJSWorkerGetInspectorTargetInfo(worker: JSWorkerRef, info: ?*ZJSInspectorTargetInfo) callconv(.c) bool {
    const w = workerFrom(worker) orelse return false;
    const out = info orelse return false;
    out.* = .{
        .id = w.inspector_target_id,
        .kind = w.inspector_target_kind,
        .state = w.inspectorTargetState(),
    };
    return true;
}

/// Attach an asynchronous inspector session to a worker target. Commands are
/// queued to the runtime thread; callbacks run only when the worker owner calls
/// `ZJSWorkerInspectorSessionPump`, never on the worker thread.
export fn ZJSWorkerInspectorSessionCreate(
    worker: JSWorkerRef,
    callback: ZJSInspectorMessageCallback,
    user_data: ?*anyopaque,
) callconv(.c) ZJSWorkerInspectorSessionRef {
    const w = workerFrom(worker) orelse return null;
    const cb = callback orelse return null;
    const client = w.createInspectorClient() catch return null;
    const session = gpa.create(CWorkerInspectorSession) catch {
        WorkerMod.Worker.releaseInspectorClient(client);
        return null;
    };
    session.* = .{ .client = client, .callback = cb, .user_data = user_data };
    return @ptrCast(session);
}

fn workerInspectorSession(ref: ZJSWorkerInspectorSessionRef) ?*CWorkerInspectorSession {
    const session: *CWorkerInspectorSession = @ptrCast(@alignCast(ref orelse return null));
    if (!session.client.isOwnerThread()) return null;
    return session;
}

export fn ZJSWorkerInspectorSessionDispatch(
    session_ref: ZJSWorkerInspectorSessionRef,
    message: [*c]const u8,
    message_length: usize,
) callconv(.c) bool {
    const session = workerInspectorSession(session_ref) orelse return false;
    if (message == null or message_length == 0) return false;
    return WorkerMod.Worker.dispatchInspector(session.client, message[0..message_length]);
}

export fn ZJSWorkerInspectorSessionPump(
    session_ref: ZJSWorkerInspectorSessionRef,
    timeout_ms: u64,
) callconv(.c) ZJSWorkerInspectorPumpResult {
    const session = workerInspectorSession(session_ref) orelse return .closed;
    const timeout: ?u64 = if (timeout_ms == 0) null else timeout_ms;
    var event = WorkerMod.Worker.receiveInspector(session.client, timeout) orelse
        return if (session.client.transport_closed.load(.acquire)) .closed else .timeout;
    defer event.deinit();
    if (event.kind == .detached) return .closed;
    session.callback(event.message.ptr, event.message.len, session.user_data);
    return .message;
}

export fn ZJSWorkerInspectorSessionRelease(session_ref: ZJSWorkerInspectorSessionRef) callconv(.c) void {
    const session = workerInspectorSession(session_ref) orelse return;
    WorkerMod.Worker.releaseInspectorClient(session.client);
    gpa.destroy(session);
}

/// Serialize `value` from `ctx`'s realm and deliver it to the worker's inbox.
/// Returns false (and sets `exception`) if serialization fails (e.g. the value
/// holds a function or symbol, which structured clone refuses).
export fn JSWorkerPostMessage(worker: JSWorkerRef, ctx: JSContextRef, value_ref: JSValueRef, exception: ExceptionRef) callconv(.c) bool {
    const c = ctxFrom(ctx) orelse return false;
    const w = workerFrom(worker) orelse {
        setException(c, exception, "TypeError: worker is not a worker");
        return false;
    };
    const message_value = valueArgFrom(c, value_ref, exception) orelse return false;
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return false;
    };
    defer c.popActiveInterpreter(&machine);
    w.postMessage(&machine, message_value) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return false;
    };
    return true;
}

/// Block up to `timeout_ms` (0 = wait indefinitely) for the next worker→main
/// message, deserialized into `ctx`'s realm. Returns null when the worker has
/// closed its side and drained, or the timeout elapsed.
export fn JSWorkerReceive(worker: JSWorkerRef, ctx: JSContextRef, timeout_ms: u64, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const w = workerFrom(worker) orelse {
        setException(c, exception, "TypeError: worker is not a worker");
        return null;
    };
    const gc_saved = gc_mod.setActiveHeap(c.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(c.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    var machine = c.interpreter();
    c.pushActiveInterpreter(&machine) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    defer c.popActiveInterpreter(&machine);
    const tmo: ?u64 = if (timeout_ms == 0) null else timeout_ms;
    const v = w.receive(&machine, tmo) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    return boxResult(c, exception, v orelse return null);
}

/// Request cooperative termination: running JS throws at the next step
/// checkpoint and the worker's delivery loop ends.
export fn JSWorkerTerminate(worker: JSWorkerRef) callconv(.c) void {
    const w = workerFrom(worker) orelse return;
    w.terminate();
}

/// Join the worker thread and free it. If the worker was not terminated, this
/// first closes its inbox so the delivery loop drains and exits.
export fn JSWorkerRelease(worker: JSWorkerRef) callconv(.c) void {
    const w = workerFrom(worker) orelse return;
    w.close();
    w.join();
    w.destroy();
}

// ---------------------------------------------------------------------------
// Tests — exercise the C-API exactly as a C/Zig consumer (e.g. Home's
// extern_fns.zig) would, mirroring lang's M3 smoke tests plus real evaluation.
// ---------------------------------------------------------------------------

test "C-API: create + release context, round-trip a number" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const num = JSValueMakeNumber(ctx, 42.5) orelse return error.JSValueMakeFailed;
    try std.testing.expect(JSValueIsNumber(ctx, num));
    try std.testing.expectEqual(@as(f64, 42.5), JSValueToNumber(ctx, num, null));
}

test "C-API: context groups share values while preserving distinct realms and lifetime" {
    const group = JSContextGroupCreate() orelse return error.GroupCreateFailed;
    try std.testing.expectEqual(group, JSContextGroupRetain(group));
    JSContextGroupRelease(group);

    const first = JSGlobalContextCreateInGroup(group, null) orelse return error.ContextCreateFailed;
    const second = JSGlobalContextCreateInGroup(group, null) orelse return error.ContextCreateFailed;
    try std.testing.expectEqual(group, JSContextGetGroup(first));
    try std.testing.expectEqual(group, JSContextGetGroup(second));
    const first_global = JSContextGetGlobalObject(first) orelse return error.GlobalObjectFailed;
    const second_global = JSContextGetGlobalObject(second) orelse return error.GlobalObjectFailed;
    try std.testing.expect(!JSValueIsStrictEqual(second, first_global, second_global));

    const make_object = JSStringCreateWithUTF8CString("({ answer: 42 })") orelse return error.StringInitFailed;
    defer JSStringRelease(make_object);
    var exception: JSValueRef = null;
    const shared = JSEvaluateScript(first, make_object, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(!ZJSValueIsReachable(first, shared));
    try std.testing.expectEqual(@as(u64, 0), ZJSContextGetCollectionEpoch(first));
    JSGarbageCollect(first);
    try std.testing.expectEqual(@as(u64, 1), ZJSContextGetCollectionEpoch(first));
    try std.testing.expectEqual(@as(u64, 1), ZJSContextGetCollectionEpoch(second));
    const shared_name = JSStringCreateWithUTF8CString("sharedFromFirst") orelse return error.StringInitFailed;
    defer JSStringRelease(shared_name);
    JSObjectSetProperty(second, second_global, shared_name, shared, 0, &exception);
    try std.testing.expect(exception == null);
    try std.testing.expect(ZJSValueIsReachable(first, shared));
    try std.testing.expect(ZJSValueIsReachable(second, shared));
    const read_shared = JSStringCreateWithUTF8CString("sharedFromFirst.answer") orelse return error.StringInitFailed;
    defer JSStringRelease(read_shared);
    const answer = JSEvaluateScript(second, read_shared, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(second, answer, &exception));
    const fetched = JSObjectGetProperty(second, second_global, shared_name, &exception) orelse return error.PropertyGetFailed;
    try std.testing.expect(JSValueIsStrictEqual(second, shared, fetched));
    try std.testing.expect(ZJSValueProtect(second, shared));
    try std.testing.expect(ZJSValueUnprotect(second, shared));

    const first_array_proto_source = JSStringCreateWithUTF8CString("Array.prototype") orelse return error.StringInitFailed;
    defer JSStringRelease(first_array_proto_source);
    const second_array_proto_source = JSStringCreateWithUTF8CString("Array.prototype") orelse return error.StringInitFailed;
    defer JSStringRelease(second_array_proto_source);
    const first_array_proto = JSEvaluateScript(first, first_array_proto_source, null, null, 1, &exception) orelse return error.EvalFailed;
    const second_array_proto = JSEvaluateScript(second, second_array_proto_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(!JSValueIsStrictEqual(second, first_array_proto, second_array_proto));

    const closure_source = JSStringCreateWithUTF8CString(
        "globalThis.hold = (() => { const target = { closure: true }; globalThis.read = () => target; return target; })(); hold",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(closure_source);
    const closure_target = JSEvaluateScript(first, closure_source, null, null, 1, &exception) orelse return error.EvalFailed;
    const clear_direct_root = JSStringCreateWithUTF8CString("globalThis.hold = undefined") orelse return error.StringInitFailed;
    defer JSStringRelease(clear_direct_root);
    _ = JSEvaluateScript(first, clear_direct_root, null, null, 1, &exception);
    try std.testing.expect(ZJSValueIsReachable(second, closure_target));

    const weak_source = JSStringCreateWithUTF8CString(
        "(() => { const target = { weak: true }; globalThis.onlyWeak = new WeakRef(target); return target; })()",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(weak_source);
    const weak_target = JSEvaluateScript(second, weak_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(!ZJSValueIsReachable(first, weak_target));

    const promise_source = JSStringCreateWithUTF8CString(
        "(() => { const target = { promise: true }; globalThis.pendingTarget = Promise.resolve(target); return target; })()",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(promise_source);
    const promise_target = JSEvaluateScript(second, promise_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(ZJSValueIsReachable(first, promise_target));
    const clear_promise = JSStringCreateWithUTF8CString("globalThis.pendingTarget = undefined") orelse return error.StringInitFailed;
    defer JSStringRelease(clear_promise);
    _ = JSEvaluateScript(second, clear_promise, null, null, 1, &exception);
    try std.testing.expect(!ZJSValueIsReachable(first, promise_target));

    // Releasing a realm handle does not invalidate values retained by another
    // realm in the VM; the group keeps every realm allocation alive to teardown.
    JSGlobalContextRelease(first);
    const answer_after_release = JSEvaluateScript(second, read_shared, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(second, answer_after_release, &exception));

    const foreign = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    const foreign_name = JSStringCreateWithUTF8CString("foreign") orelse return error.StringInitFailed;
    defer JSStringRelease(foreign_name);
    exception = null;
    JSObjectSetProperty(foreign, JSContextGetGlobalObject(foreign), foreign_name, shared, 0, &exception);
    try std.testing.expect(exception != null);
    try std.testing.expect(!ZJSValueProtect(foreign, shared));
    try std.testing.expect(!ZJSValueUnprotect(foreign, shared));
    try std.testing.expect(!ZJSValueIsReachable(foreign, shared));
    JSGlobalContextRelease(foreign);

    // Drop the caller's group retain before its final realm: the realm retain is
    // sufficient, and its release performs the one shared-VM teardown.
    JSContextGroupRelease(group);
    JSGlobalContextRelease(second);
}

test "C-API: inspectability gates concurrent in-process protocol sessions" {
    const State = struct {
        bytes: [8192]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    try std.testing.expect(!JSGlobalContextIsInspectable(ctx));
    var first_state: State = .{};
    var second_state: State = .{};
    try std.testing.expect(ZJSInspectorSessionCreate(ctx, State.receive, &first_state) == null);
    JSGlobalContextSetInspectable(ctx, true);
    try std.testing.expect(JSGlobalContextIsInspectable(ctx));
    const first = ZJSInspectorSessionCreate(ctx, State.receive, &first_state) orelse return error.SessionCreateFailed;
    const second = ZJSInspectorSessionCreate(ctx, State.receive, &second_state) orelse return error.SessionCreateFailed;
    try std.testing.expect(std.mem.indexOf(u8, first_state.bytes[0..first_state.len], "zig-js-inspector/0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_state.bytes[0..second_state.len], "Inspector.attached") != null);

    const schema = "{\"id\":1,\"method\":\"Schema.getDomains\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(first, schema, schema.len));
    const runtime_enable = "{\"id\":2,\"method\":\"Runtime.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(first, runtime_enable, runtime_enable.len));
    const evaluate_request = "{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"6 * 7\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(first, evaluate_request, evaluate_request.len));
    const debugger_enable = "{\"id\":4,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(second, debugger_enable, debugger_enable.len));
    const malformed = "{";
    try std.testing.expect(ZJSInspectorSessionDispatch(second, malformed, malformed.len));

    const first_messages = first_state.bytes[0..first_state.len];
    try std.testing.expect(std.mem.indexOf(u8, first_messages, "\"Runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_messages, "Runtime.executionContextCreated") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_messages, "\"description\":\"42\"") != null);
    const second_messages = second_state.bytes[0..second_state.len];
    try std.testing.expect(std.mem.indexOf(u8, second_messages, "zig-js-debugger-0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_messages, "-32700") != null);

    JSGlobalContextSetInspectable(ctx, false);
    try std.testing.expect(!JSGlobalContextIsInspectable(ctx));
    try std.testing.expect(!ZJSInspectorSessionDispatch(first, schema, schema.len));
    try std.testing.expect(std.mem.indexOf(u8, first_state.bytes[0..first_state.len], "Inspector.detached") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_state.bytes[0..second_state.len], "Inspector.detached") != null);
    ZJSInspectorSessionRelease(first);
    ZJSInspectorSessionRelease(second);
    JSGlobalContextRelease(ctx);
}

test "C-API: inspector protocol inventory has no hidden commands" {
    const inventory_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/inspector-protocol-0.1.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(inventory_source);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, inventory_source, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("zig-js-inspector/0.1", root.get("protocolVersion").?.string);
    const unsupported = root.get("unsupportedCommandBehavior").?.object;
    try std.testing.expectEqual(@as(i64, -32601), unsupported.get("code").?.integer);
    try std.testing.expect(!unsupported.get("silentAcceptance").?.bool);
    const commands = root.get("commands").?.array.items;
    const events = root.get("events").?.array.items;
    const transports = root.get("transports").?.array.items;
    try std.testing.expectEqual(@as(usize, 20), commands.len);
    try std.testing.expectEqual(@as(usize, 8), events.len);
    try std.testing.expectEqual(@as(usize, 2), transports.len);
    for (transports) |transport_value| {
        const transport = transport_value.object;
        try std.testing.expectEqualStrings("implemented", transport.get("status").?.string);
        try std.testing.expect(transport.get("name").?.string.len > 0);
        try std.testing.expect(transport.get("evidence").?.string.len > 0);
    }
    var methods: std.StringHashMapUnmanaged(void) = .empty;
    defer methods.deinit(std.testing.allocator);
    for (commands) |command_value| {
        const command = command_value.object;
        const method = command.get("method").?.string;
        try std.testing.expectEqualStrings("implemented", command.get("status").?.string);
        try std.testing.expect(command.get("evidence").?.string.len > 0);
        const entry = try methods.getOrPut(std.testing.allocator, method);
        try std.testing.expect(!entry.found_existing);
    }
    for (events) |event_value| {
        const event = event_value.object;
        try std.testing.expectEqualStrings("implemented", event.get("status").?.string);
        const entry = try methods.getOrPut(std.testing.allocator, event.get("method").?.string);
        try std.testing.expect(!entry.found_existing);
    }

    const State = struct {
        bytes: [8192]u8 = undefined,
        len: usize = 0,
        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
        }
    };
    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    const session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(session);
    const runtime_enable = "{\"id\":1,\"method\":\"Runtime.enable\"}";
    const runtime_disable = "{\"id\":2,\"method\":\"Runtime.disable\"}";
    const debugger_enable = "{\"id\":3,\"method\":\"Debugger.enable\"}";
    const debugger_disable = "{\"id\":4,\"method\":\"Debugger.disable\"}";
    const unsupported_request = "{\"id\":5,\"method\":\"Debugger.silentlyPretend\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(session, runtime_enable, runtime_enable.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(session, runtime_disable, runtime_disable.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(session, debugger_enable, debugger_enable.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(session, debugger_disable, debugger_disable.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(session, unsupported_request, unsupported_request.len));
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "-32601") != null);
}

test "C-API: inspector session retains its context until deterministic release" {
    const State = struct {
        fn receive(_: [*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
            const count: *usize = @ptrCast(@alignCast(user_data.?));
            count.* += 1;
        }
    };
    var received: usize = 0;
    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    JSGlobalContextSetInspectable(ctx, true);
    const session = ZJSInspectorSessionCreate(ctx, State.receive, &received) orelse return error.SessionCreateFailed;
    JSGlobalContextRelease(ctx);
    const request = "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"21 + 21\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(session, request, request.len));
    try std.testing.expect(received >= 2);
    ZJSInspectorSessionRelease(session);
}

test "C-API: debugger publishes scripts and synchronously pauses at source locations" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        bytes: [16384]u8 = undefined,
        len: usize = 0,
        pause_count: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") != null) {
                self.pause_count += 1;
                const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
                std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
            }
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);

    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    const script = JSStringCreateWithUTF8CString("let x = 1;\ndebugger;\nx += 2;\nx;") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const url = JSStringCreateWithUTF8CString("pause.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, script, null, url, 7, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 3), JSValueToNumber(ctx, result, &exception));
    try std.testing.expectEqual(@as(usize, 1), state.pause_count);

    const recursive_script = JSStringCreateWithUTF8CString(
        "function recur(n) { if (n === 0) { debugger; return 0; } return recur(n - 1) + 1; } recur(2);",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(recursive_script);
    const recursive = JSEvaluateScript(ctx, recursive_script, null, url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, recursive, &exception));
    try std.testing.expectEqual(@as(usize, 2), state.pause_count);

    const pause = "{\"id\":2,\"method\":\"Debugger.pause\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, pause, pause.len));
    const second_script = JSStringCreateWithUTF8CString("40 + 2;") orelse return error.StringInitFailed;
    defer JSStringRelease(second_script);
    const second = JSEvaluateScript(ctx, second_script, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, second, &exception));
    try std.testing.expectEqual(@as(usize, 3), state.pause_count);

    const set_url_breakpoint =
        "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"breakpoint.js\",\"lineNumber\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, set_url_breakpoint, set_url_breakpoint.len));
    const breakpoint_script = JSStringCreateWithUTF8CString("var bpValue = 40;\nbpValue += 2;\nbpValue;") orelse return error.StringInitFailed;
    defer JSStringRelease(breakpoint_script);
    const breakpoint_url = JSStringCreateWithUTF8CString("breakpoint.js") orelse return error.StringInitFailed;
    defer JSStringRelease(breakpoint_url);
    const breakpoint_result = JSEvaluateScript(ctx, breakpoint_script, null, breakpoint_url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, breakpoint_result, &exception));
    try std.testing.expectEqual(@as(usize, 4), state.pause_count);
    const remove_breakpoint = "{\"id\":4,\"method\":\"Debugger.removeBreakpoint\",\"params\":{\"breakpointId\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, remove_breakpoint, remove_breakpoint.len));
    _ = JSEvaluateScript(ctx, breakpoint_script, null, breakpoint_url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(usize, 4), state.pause_count);

    const get_source = "{\"id\":5,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, get_source, get_source.len));
    const set_script_breakpoint =
        "{\"id\":6,\"method\":\"Debugger.setBreakpoint\",\"params\":{\"location\":{\"scriptId\":2,\"lineNumber\":0,\"columnNumber\":20}}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, set_script_breakpoint, set_script_breakpoint.len));
    const call_recursive = JSStringCreateWithUTF8CString("recur(1);") orelse return error.StringInitFailed;
    defer JSStringRelease(call_recursive);
    const recursive_again = JSEvaluateScript(ctx, call_recursive, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 1), JSValueToNumber(ctx, recursive_again, &exception));
    // The resolved `if` statement runs for n=1 and n=0, then the base-case
    // debugger statement produces its own pause.
    try std.testing.expectEqual(@as(usize, 7), state.pause_count);
    const remove_script_breakpoint = "{\"id\":7,\"method\":\"Debugger.removeBreakpoint\",\"params\":{\"breakpointId\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, remove_script_breakpoint, remove_script_breakpoint.len));

    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.scriptParsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "pause.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"startLine\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "debuggerStatement") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"lineNumber\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.resumed") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.breakpointResolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"breakpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"hitBreakpoints\":[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "function recur") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"hitBreakpoints\":[2]") != null);
}

test "C-API: debugger disables ordinary bytecode and native tier entry" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    const context = ctxRawFrom(ctx) orelse return error.ContextCreateFailed;
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));

    // Debug-enabled interpreters never expose an executable-code owner, and
    // ordinary functions parsed in this mode retain no bytecode entry that
    // could skip statement-boundary callbacks.
    const machine = context.interpreter();
    try std.testing.expect(machine.jit_owner == null);
    const source = JSStringCreateWithUTF8CString(
        "function inspectedTier(value) { var local = value + 1; debugger; return local; } inspectedTier(41);",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const url = JSStringCreateWithUTF8CString("debug-tier.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, source, null, url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, &exception));
    try std.testing.expectEqual(@as(usize, 1), state.pauses);

    const name = JSStringCreateWithUTF8CString("inspectedTier") orelse return error.StringInitFailed;
    defer JSStringRelease(name);
    const function_ref = JSObjectGetProperty(ctx, JSContextGetGlobalObject(ctx), name, &exception) orelse return error.PropertyGetFailed;
    const function_value = valueFromContext(context, function_ref) orelse return error.InvalidValue;
    const erased = function_value.asObj().jsFunction() orelse return error.NotFunction;
    const function: *interp.Function = @ptrCast(@alignCast(erased));
    try std.testing.expect(function.chunk == null);
}

test "C-API: debugger preserves script history across late attach and reattach" {
    const State = struct {
        bytes: [16384]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    const historical_source = JSStringCreateWithUTF8CString(
        "function historical(value) { return value + 1; } historical(1);",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(historical_source);
    const historical_url = JSStringCreateWithUTF8CString("historical.js") orelse return error.StringInitFailed;
    defer JSStringRelease(historical_url);
    var exception: JSValueRef = null;
    const historical_result = JSEvaluateScript(ctx, historical_source, null, historical_url, 11, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, historical_result, &exception));

    JSGlobalContextSetInspectable(ctx, true);
    var first_state: State = .{};
    const first = ZJSInspectorSessionCreate(ctx, State.receive, &first_state) orelse return error.SessionCreateFailed;
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(first, enable, enable.len));
    const get_source = "{\"id\":2,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(first, get_source, get_source.len));
    const first_transcript = first_state.bytes[0..first_state.len];
    try std.testing.expect(std.mem.indexOf(u8, first_transcript, "Debugger.scriptParsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_transcript, "historical.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_transcript, "\"startLine\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_transcript, "function historical") != null);
    ZJSInspectorSessionRelease(first);

    // Destroying the last session must not discard context-owned script IDs.
    var second_state: State = .{};
    const second = ZJSInspectorSessionCreate(ctx, State.receive, &second_state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(second);
    try std.testing.expect(ZJSInspectorSessionDispatch(second, enable, enable.len));
    const second_transcript = second_state.bytes[0..second_state.len];
    try std.testing.expect(std.mem.indexOf(u8, second_transcript, "historical.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_transcript, "\"scriptId\":1") != null);
}

test "C-API: debugger enters warmed functions compiled before attachment" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,
        bytes: [32768]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            if (self.pauses == 1) {
                const evaluate =
                    "{\"id\":89,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"expression\":\"local = 100\"}}";
                std.debug.assert(ZJSInspectorSessionDispatch(self.session, evaluate, evaluate.len));
            }
            const command = if (self.pauses == 1)
                "{\"id\":90,\"method\":\"Debugger.stepOver\"}"
            else
                "{\"id\":91,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, command, command.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    const context = ctxRawFrom(ctx) orelse return error.ContextCreateFailed;
    const source = JSStringCreateWithUTF8CString(
        "function warmed(value) {\n var local = value + 1;\n local += 1;\n return local;\n}\nfor (var i = 0; i < 10000; i++) warmed(i);",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const url = JSStringCreateWithUTF8CString("warmed-before-attach.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);
    var exception: JSValueRef = null;
    _ = JSEvaluateScript(ctx, source, null, url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const name = JSStringCreateWithUTF8CString("warmed") orelse return error.StringInitFailed;
    defer JSStringRelease(name);
    const function_ref = JSObjectGetProperty(ctx, JSContextGetGlobalObject(ctx), name, &exception) orelse return error.PropertyGetFailed;
    const function_value = valueFromContext(context, function_ref) orelse return error.InvalidValue;
    const erased = function_value.asObj().jsFunction() orelse return error.NotFunction;
    const function: *interp.Function = @ptrCast(@alignCast(erased));
    const historical_chunk = function.chunk orelse return error.ExpectedBytecode;
    try std.testing.expect(historical_chunk.debug_nodes.len != 0);

    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    try std.testing.expect(context.interpreter().jit_owner == null);
    const breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"warmed-before-attach.js\",\"lineNumber\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, breakpoint, breakpoint.len));
    const call_source = JSStringCreateWithUTF8CString("warmed(40);") orelse return error.StringInitFailed;
    defer JSStringRelease(call_source);
    const result = JSEvaluateScript(ctx, call_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 101), JSValueToNumber(ctx, result, &exception));
    try std.testing.expectEqual(@as(usize, 2), state.pauses);
    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "warmed-before-attach.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"functionName\":\"warmed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"breakpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"lineNumber\":3") != null);
}

test "C-API: debugger registers direct and indirect eval sources independently" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,
        used_step: bool = false,
        bytes: [32768]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const command = if (!self.used_step)
                "{\"id\":89,\"method\":\"Debugger.stepOver\"}"
            else
                "{\"id\":90,\"method\":\"Debugger.resume\"}";
            self.used_step = true;
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, command, command.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    const breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"eval-source.js\",\"lineNumber\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, breakpoint, breakpoint.len));

    const outer_source = JSStringCreateWithUTF8CString(
        "eval(\"var evalLocal = 40;\\nevalLocal += 2;\\nevalLocal;\\n//# sourceURL=eval-source.js\");",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(outer_source);
    var exception: JSValueRef = null;
    const first = JSEvaluateScript(ctx, outer_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, first, &exception));
    const second = JSEvaluateScript(ctx, outer_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, second, &exception));
    const indirect_breakpoint =
        "{\"id\":4,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"indirect-eval.js\",\"lineNumber\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, indirect_breakpoint, indirect_breakpoint.len));
    const indirect_source = JSStringCreateWithUTF8CString(
        "(0, eval)(\"var indirectLocal = 5;\\nindirectLocal += 2;\\nindirectLocal;\\n//# sourceURL=indirect-eval.js\");",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(indirect_source);
    const indirect = JSEvaluateScript(ctx, indirect_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 7), JSValueToNumber(ctx, indirect, &exception));
    try std.testing.expectEqual(@as(usize, 4), state.pauses);

    const pause_all = "{\"id\":5,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"all\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, pause_all, pause_all.len));
    const throwing_source = JSStringCreateWithUTF8CString(
        "try { eval(\"throw new Error('dynamic');\\n//# sourceURL=eval-throw.js\"); } catch (error) { 9; }",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(throwing_source);
    _ = JSEvaluateScript(ctx, throwing_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(usize, 5), state.pauses);

    const get_source = "{\"id\":3,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, get_source, get_source.len));
    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "eval-source.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "var evalLocal = 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "indirect-eval.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "eval-throw.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.breakpointResolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"breakpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.exceptionThrown") != null);
}

test "C-API: dynamic script history survives multi-session detach and reattach" {
    const State = struct {
        bytes: [16384]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var first_state: State = .{};
    var second_state: State = .{};
    const first = ZJSInspectorSessionCreate(ctx, State.receive, &first_state) orelse return error.SessionCreateFailed;
    const second = ZJSInspectorSessionCreate(ctx, State.receive, &second_state) orelse return error.SessionCreateFailed;
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(first, enable, enable.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(second, enable, enable.len));
    const source = JSStringCreateWithUTF8CString(
        "eval(\"40 + 2;\\n//# sourceURL=multi-eval.js\");",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, &exception));
    try std.testing.expect(std.mem.indexOf(u8, first_state.bytes[0..first_state.len], "multi-eval.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_state.bytes[0..second_state.len], "multi-eval.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_state.bytes[0..first_state.len], "\"scriptId\":2") != null);
    ZJSInspectorSessionRelease(first);
    ZJSInspectorSessionRelease(second);

    var reattached_state: State = .{};
    const reattached = ZJSInspectorSessionCreate(ctx, State.receive, &reattached_state) orelse return error.SessionCreateFailed;
    try std.testing.expect(ZJSInspectorSessionDispatch(reattached, enable, enable.len));
    try std.testing.expect(std.mem.indexOf(u8, reattached_state.bytes[0..reattached_state.len], "multi-eval.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, reattached_state.bytes[0..reattached_state.len], "\"scriptId\":2") != null);
    JSGlobalContextSetInspectable(ctx, false);
    try std.testing.expect(std.mem.indexOf(u8, reattached_state.bytes[0..reattached_state.len], "Inspector.detached") != null);
    try std.testing.expect(!ZJSInspectorSessionDispatch(reattached, enable, enable.len));
    ZJSInspectorSessionRelease(reattached);
}

test "C-API: debugger registers generated function constructors" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,
        bytes: [65536]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    const ordinary_breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"generated-function.js\",\"lineNumber\":3}}";
    const generator_breakpoint =
        "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"generated-generator.js\",\"lineNumber\":2}}";
    const async_breakpoint =
        "{\"id\":4,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"generated-async.js\",\"lineNumber\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, ordinary_breakpoint, ordinary_breakpoint.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, generator_breakpoint, generator_breakpoint.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, async_breakpoint, async_breakpoint.len));

    const constructors_source = JSStringCreateWithUTF8CString(
        "var GeneratorFunction = Object.getPrototypeOf(function*(){}).constructor;\n" ++
            "var AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;\n" ++
            "var AsyncGeneratorFunction = Object.getPrototypeOf(async function*(){}).constructor;\n" ++
            "var generatedOrdinary = Function('value', 'var local = value + 1;\\nlocal += 1;\\nreturn local;\\n//# sourceURL=generated-function.js');\n" ++
            "var generatedGenerator = GeneratorFunction('value', 'yield value;\\nreturn value + 1;\\n//# sourceURL=generated-generator.js');\n" ++
            "var generatedAsync = AsyncFunction('value', 'return value + 2;\\n//# sourceURL=generated-async.js');\n" ++
            "var generatedAsyncGenerator = AsyncGeneratorFunction('value', 'yield value;\\n//# sourceURL=generated-async-generator.js');\n" ++
            "generatedOrdinary(40);",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(constructors_source);
    var exception: JSValueRef = null;
    const ordinary_result = JSEvaluateScript(ctx, constructors_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, ordinary_result, &exception));

    const generator_call = JSStringCreateWithUTF8CString("generatedGenerator(7).next().value;") orelse return error.StringInitFailed;
    defer JSStringRelease(generator_call);
    const generator_result = JSEvaluateScript(ctx, generator_call, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 7), JSValueToNumber(ctx, generator_result, &exception));
    const async_call = JSStringCreateWithUTF8CString(
        "var generatedAsyncValue = 0; generatedAsync(8).then(function(value) { generatedAsyncValue = value; }); 'scheduled';",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(async_call);
    _ = JSEvaluateScript(ctx, async_call, null, null, 1, &exception) orelse return error.EvalFailed;
    const async_value_source = JSStringCreateWithUTF8CString("generatedAsyncValue;") orelse return error.StringInitFailed;
    defer JSStringRelease(async_value_source);
    const async_result = JSEvaluateScript(ctx, async_value_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 10), JSValueToNumber(ctx, async_result, &exception));
    try std.testing.expectEqual(@as(usize, 3), state.pauses);

    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "generated-function.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "generated-generator.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "generated-async.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "generated-async-generator.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"breakpoint\"") != null);
}

test "C-API: JSObjectMakeFunction preserves inspector URL and starting line" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,
        bytes: [16384]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    const breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"c-generated.js\",\"lineNumber\":19}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, breakpoint, breakpoint.len));

    const name = JSStringCreateWithUTF8CString("cGenerated") orelse return error.StringInitFailed;
    defer JSStringRelease(name);
    const parameter = JSStringCreateWithUTF8CString("value") orelse return error.StringInitFailed;
    defer JSStringRelease(parameter);
    const parameters = [_]JSStringRef{parameter};
    const body = JSStringCreateWithUTF8CString("var local = value + 1;\nlocal += 1;\nreturn local;") orelse return error.StringInitFailed;
    defer JSStringRelease(body);
    const url = JSStringCreateWithUTF8CString("c-generated.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);
    var exception: JSValueRef = null;
    const function = JSObjectMakeFunction(ctx, name, parameters.len, &parameters, body, url, 17, &exception) orelse return error.FunctionCreateFailed;
    const argument = JSValueMakeNumber(ctx, 40) orelse return error.ValueCreateFailed;
    const result = JSObjectCallAsFunction(ctx, function, null, 1, @ptrCast(&argument), &exception) orelse return error.FunctionCallFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, &exception));
    try std.testing.expectEqual(@as(usize, 1), state.pauses);

    const get_source = "{\"id\":3,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, get_source, get_source.len));
    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "c-generated.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"startLine\":16") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"lineNumber\":19") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "var local = value + 1") != null);
}

test "C-API: debugger registers and pauses across a module graph" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,
        bytes: [32768]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };
    const Host = struct {
        fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
            if (!std.mem.eql(u8, specifier, "./dep.js")) return null;
            out_path.* = "dep.js";
            return "export const dep = 40;";
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    const context = ctxRawFrom(ctx) orelse return error.ContextCreateFailed;
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    const dep_breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"dep.js\",\"lineNumber\":0}}";
    const entry_breakpoint =
        "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"entry.js\",\"lineNumber\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, dep_breakpoint, dep_breakpoint.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, entry_breakpoint, entry_breakpoint.len));

    var host_token: u8 = 0;
    const host = Context.ModuleHost{ .ctx = &host_token, .load = Host.load };
    _ = try context.evaluateModule(
        "entry.js",
        "import { dep } from './dep.js';\nvar entryLocal = dep + 1;\nentryLocal += 1;\nglobalThis.moduleDebugResult = entryLocal;",
        host,
    );
    try std.testing.expectEqual(@as(usize, 2), state.pauses);
    try std.testing.expectEqual(@as(usize, 2), context.debug_scripts.items.len);
    const value_source = JSStringCreateWithUTF8CString("moduleDebugResult;") orelse return error.StringInitFailed;
    defer JSStringRelease(value_source);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, value_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, &exception));

    const entry_source_request = "{\"id\":4,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":1}}";
    const dep_source_request = "{\"id\":5,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, entry_source_request, entry_source_request.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, dep_source_request, dep_source_request.len));
    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "entry.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "dep.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "import { dep }") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "export const dep = 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scriptId\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"breakpoint\"") != null);
}

test "C-API: paused frames expose scopes and live frame evaluation" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        held_object_id: u64 = 0,
        scope_object_id: u64 = 0,
        bytes: [65536]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "\"id\":96") != null) {
                var parsed = std.json.parseFromSlice(std.json.Value, gpa, message[0..message_len], .{}) catch return;
                defer parsed.deinit();
                self.held_object_id = @intCast(parsed.value.object.get("result").?.object.get("result").?.object.get("objectId").?.integer);
            }
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") != null) {
                var parsed = std.json.parseFromSlice(std.json.Value, gpa, message[0..message_len], .{}) catch return;
                defer parsed.deinit();
                const first_frame = parsed.value.object.get("params").?.object.get("callFrames").?.array.items[0].object;
                const first_scope = first_frame.get("scopeChain").?.array.items[0].object;
                self.scope_object_id = @intCast(first_scope.get("object").?.object.get("objectId").?.integer);
            }
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            const evaluate_inner =
                "{\"id\":91,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"expression\":\"innerLocal = 8; innerLocal + outerLocal\"}}";
            const evaluate_outer =
                "{\"id\":92,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":1,\"expression\":\"outerLocal\"}}";
            const invalid_frame =
                "{\"id\":93,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":99,\"expression\":\"1\"}}";
            const throwing_evaluation =
                "{\"id\":94,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"expression\":\"throw \'debug-eval\';\"}}";
            const evaluate_object =
                "{\"id\":96,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"objectGroup\":\"held\",\"expression\":\"({ answer: 42, nested: { ok: true }, get boom() { throw \'getter-ran\'; } })\"}}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, evaluate_inner, evaluate_inner.len));
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, evaluate_outer, evaluate_outer.len));
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, invalid_frame, invalid_frame.len));
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, throwing_evaluation, throwing_evaluation.len));
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, evaluate_object, evaluate_object.len));
            std.debug.assert(self.held_object_id != 0);
            std.debug.assert(self.scope_object_id != 0);
            var properties_buffer: [256]u8 = undefined;
            const get_properties = std.fmt.bufPrint(
                &properties_buffer,
                "{{\"id\":97,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
                .{self.held_object_id},
            ) catch unreachable;
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, get_properties.ptr, get_properties.len));
            const get_scope = std.fmt.bufPrint(
                &properties_buffer,
                "{{\"id\":101,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
                .{self.scope_object_id},
            ) catch unreachable;
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, get_scope.ptr, get_scope.len));
            const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));

    const source = JSStringCreateWithUTF8CString(
        "function outer(alpha) { let outerLocal = alpha + 1; function inner(beta) { let innerLocal = beta + 2; debugger; return outerLocal + innerLocal; } return inner(3); } outer(4);",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const url = JSStringCreateWithUTF8CString("frames.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, source, null, url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 13), JSValueToNumber(ctx, result, &exception));
    const expired_frame =
        "{\"id\":95,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"expression\":\"1\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, expired_frame, expired_frame.len));

    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"callFrames\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"callFrameId\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"functionName\":\"inner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"functionName\":\"outer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"functionName\":\"(global)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"innerLocal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"outerLocal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"type\":\"global\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"id\":91") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"value\":13") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"id\":92") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"value\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "unknown callFrameId for this pause") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "debug-eval") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "exceptionDetails") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "runtime is not paused") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"id\":97") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"boom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "getter-ran") == null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"id\":101") != null);

    var properties_buffer: [256]u8 = undefined;
    const get_held = try std.fmt.bufPrint(
        &properties_buffer,
        "{{\"id\":98,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.held_object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, get_held.ptr, get_held.len));
    const expired_scope = try std.fmt.bufPrint(
        &properties_buffer,
        "{{\"id\":102,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.scope_object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, expired_scope.ptr, expired_scope.len));

    const ObserverState = struct {
        bytes: [2048]u8 = undefined,
        len: usize = 0,
        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
        }
    };
    var observer_state: ObserverState = .{};
    const observer = ZJSInspectorSessionCreate(ctx, ObserverState.receive, &observer_state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(observer);
    const foreign_get = try std.fmt.bufPrint(
        &properties_buffer,
        "{{\"id\":103,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.held_object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(observer, foreign_get.ptr, foreign_get.len));
    try std.testing.expect(std.mem.indexOf(u8, observer_state.bytes[0..observer_state.len], "unknown or expired objectId") != null);
    const release_group = "{\"id\":99,\"method\":\"Runtime.releaseObjectGroup\",\"params\":{\"objectGroup\":\"held\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, release_group, release_group.len));
    const expired_held = try std.fmt.bufPrint(
        &properties_buffer,
        "{{\"id\":100,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.held_object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, expired_held.ptr, expired_held.len));
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "unknown or expired objectId") != null);
}

test "C-API: concurrent inspector sessions have deterministic pause ownership" {
    const Coordinator = struct { observer_saw_pause: bool = false };
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        coordinator: *Coordinator,
        owns_pause: bool,
        bytes: [8192]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            const resume_request = "{\"id\":50,\"method\":\"Debugger.resume\"}";
            if (self.owns_pause) {
                std.debug.assert(self.coordinator.observer_saw_pause);
                std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
            } else {
                self.coordinator.observer_saw_pause = true;
                std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
            }
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var coordinator: Coordinator = .{};
    var owner_state = State{ .coordinator = &coordinator, .owns_pause = true };
    var observer_state = State{ .coordinator = &coordinator, .owns_pause = false };
    owner_state.session = ZJSInspectorSessionCreate(ctx, State.receive, &owner_state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(owner_state.session);
    observer_state.session = ZJSInspectorSessionCreate(ctx, State.receive, &observer_state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(observer_state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(owner_state.session, enable, enable.len));
    try std.testing.expect(ZJSInspectorSessionDispatch(observer_state.session, enable, enable.len));

    const source = JSStringCreateWithUTF8CString("debugger; 42;") orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, &exception));
    try std.testing.expect(coordinator.observer_saw_pause);
    try std.testing.expect(std.mem.indexOf(u8, observer_state.bytes[0..observer_state.len], "session does not own continuation for this pause") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_state.bytes[0..owner_state.len], "Debugger.resumed") != null);
    try std.testing.expect(std.mem.indexOf(u8, observer_state.bytes[0..observer_state.len], "Debugger.resumed") != null);
}

test "C-API: parent inspector pauses preserve isolated worker progress" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        ctx: JSContextRef,
        worker: JSWorkerRef,
        reply: f64 = 0,
        terminated: bool = false,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            const message_value = JSValueMakeNumber(self.ctx, 21);
            std.debug.assert(JSWorkerPostMessage(self.worker, self.ctx, message_value, null));
            const response = JSWorkerReceive(self.worker, self.ctx, 10_000, null) orelse unreachable;
            self.reply = JSValueToNumber(self.ctx, response, null);
            JSWorkerTerminate(self.worker);
            self.terminated = true;
            const resume_request = "{\"id\":70,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };

    const worker_source = JSStringCreateWithUTF8CString(
        "onmessage = function(event) { postMessage(event.data * 2); };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(worker_source);
    const worker = JSWorkerCreate(worker_source) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(worker);
    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state = State{ .ctx = ctx, .worker = worker };
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));
    const source = JSStringCreateWithUTF8CString("debugger; 42;") orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const result = JSEvaluateScript(ctx, source, null, null, 1, null) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, null));
    try std.testing.expectEqual(@as(f64, 42), state.reply);
    try std.testing.expect(state.terminated);
}

test "C-API: inspector release is safe inside pause response and detach callbacks" {
    const State = struct {
        const Trigger = enum { pause, response, detach };
        session: ZJSInspectorSessionRef = null,
        trigger: Trigger,
        released: bool = false,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            const bytes = message[0..message_len];
            const should_release = switch (self.trigger) {
                .pause => std.mem.indexOf(u8, bytes, "Debugger.paused") != null,
                .response => std.mem.indexOf(u8, bytes, "\"id\":7") != null,
                .detach => std.mem.indexOf(u8, bytes, "Inspector.detached") != null,
            };
            if (!should_release or self.released) return;
            const session = self.session;
            self.session = null;
            self.released = true;
            ZJSInspectorSessionRelease(session);
        }
    };

    const paused_ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(paused_ctx);
    JSGlobalContextSetInspectable(paused_ctx, true);
    var paused_state = State{ .trigger = .pause };
    paused_state.session = ZJSInspectorSessionCreate(paused_ctx, State.receive, &paused_state) orelse return error.SessionCreateFailed;
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(paused_state.session, enable, enable.len));
    const paused_source = JSStringCreateWithUTF8CString("debugger; 42;") orelse return error.StringInitFailed;
    defer JSStringRelease(paused_source);
    const paused_result = JSEvaluateScript(paused_ctx, paused_source, null, null, 1, null) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(paused_ctx, paused_result, null));
    try std.testing.expect(paused_state.released);
    try std.testing.expect(inspectorState(ctxRawFrom(paused_ctx).?) == null);

    const response_ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(response_ctx);
    JSGlobalContextSetInspectable(response_ctx, true);
    var response_state = State{ .trigger = .response };
    response_state.session = ZJSInspectorSessionCreate(response_ctx, State.receive, &response_state) orelse return error.SessionCreateFailed;
    const evaluate = "{\"id\":7,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"6 * 7\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(response_state.session, evaluate, evaluate.len));
    try std.testing.expect(response_state.released);
    try std.testing.expect(inspectorState(ctxRawFrom(response_ctx).?) == null);

    const detach_ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(detach_ctx);
    JSGlobalContextSetInspectable(detach_ctx, true);
    var detach_state = State{ .trigger = .detach };
    detach_state.session = ZJSInspectorSessionCreate(detach_ctx, State.receive, &detach_state) orelse return error.SessionCreateFailed;
    JSGlobalContextSetInspectable(detach_ctx, false);
    try std.testing.expect(detach_state.released);
    try std.testing.expect(inspectorState(ctxRawFrom(detach_ctx).?) == null);
}

test "C-API: inspector remote objects stay rooted until deterministic release" {
    const State = struct {
        object_id: u64 = 0,
        bytes: [8192]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "\"id\":1") == null) return;
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, message[0..message_len], .{}) catch return;
            defer parsed.deinit();
            const result = parsed.value.object.get("result") orelse return;
            self.object_id = @intCast(result.object.get("result").?.object.get("objectId").?.integer);
        }
    };

    const context = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    context.initCApiRef();
    const ctx: JSContextRef = @ptrCast(context);
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    const session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(session);

    const evaluate =
        "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"objectGroup\":\"gc-hold\",\"expression\":\"({ alive: 42 })\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(session, evaluate, evaluate.len));
    try std.testing.expect(state.object_id != 0);
    const junk = JSStringCreateWithUTF8CString("for (let i = 0; i < 500; i++) ({ junk: i }); 0;") orelse return error.StringInitFailed;
    defer JSStringRelease(junk);
    _ = JSEvaluateScript(ctx, junk, null, null, 1, null) orelse return error.EvalFailed;
    JSGarbageCollect(ctx);

    var request_buffer: [256]u8 = undefined;
    const get_properties = try std.fmt.bufPrint(
        &request_buffer,
        "{{\"id\":2,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(session, get_properties.ptr, get_properties.len));
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "\"name\":\"alive\"") != null);
    const live_while_protected = context.gc.?.live_cells;

    const release = try std.fmt.bufPrint(
        &request_buffer,
        "{{\"id\":3,\"method\":\"Runtime.releaseObject\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(session, release.ptr, release.len));
    JSGarbageCollect(ctx);
    try std.testing.expect(context.gc.?.live_cells < live_while_protected);
    const expired = try std.fmt.bufPrint(
        &request_buffer,
        "{{\"id\":4,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
        .{state.object_id},
    );
    try std.testing.expect(ZJSInspectorSessionDispatch(session, expired.ptr, expired.len));
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "unknown or expired objectId") != null);
}

test "C-API: debugger stepping observes logical call depth" {
    const ContinueMode = enum { into, over, out };
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        mode: ContinueMode = .into,
        used_step: bool = false,
        pauses: usize = 0,
        bytes: [32768]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const command = if (!self.used_step) switch (self.mode) {
                .into => "{\"id\":80,\"method\":\"Debugger.stepInto\"}",
                .over => "{\"id\":81,\"method\":\"Debugger.stepOver\"}",
                .out => "{\"id\":82,\"method\":\"Debugger.stepOut\"}",
            } else "{\"id\":89,\"method\":\"Debugger.resume\"}";
            self.used_step = true;
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, command, command.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));

    const step_into_breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"step-into.js\",\"lineNumber\":4}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, step_into_breakpoint, step_into_breakpoint.len));
    const into_source = JSStringCreateWithUTF8CString(
        "function intoFn() {\n var insideInto = 1;\n return insideInto;\n}\nvar intoResult = intoFn();\nintoResult += 1;\nintoResult;",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(into_source);
    const into_url = JSStringCreateWithUTF8CString("step-into.js") orelse return error.StringInitFailed;
    defer JSStringRelease(into_url);
    var exception: JSValueRef = null;
    const into_start = state.len;
    const into_result = JSEvaluateScript(ctx, into_source, null, into_url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, into_result, &exception));
    try std.testing.expectEqual(@as(usize, 2), state.pauses);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[into_start..state.len], "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[into_start..state.len], "\"lineNumber\":1") != null);

    state.mode = .over;
    state.used_step = false;
    const step_over_breakpoint =
        "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"step-over.js\",\"lineNumber\":4}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, step_over_breakpoint, step_over_breakpoint.len));
    const over_source = JSStringCreateWithUTF8CString(
        "function overFn() {\n var insideOver = 1;\n return insideOver;\n}\nvar overResult = overFn();\noverResult += 1;\noverResult;",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(over_source);
    const over_url = JSStringCreateWithUTF8CString("step-over.js") orelse return error.StringInitFailed;
    defer JSStringRelease(over_url);
    const over_start = state.len;
    const over_result = JSEvaluateScript(ctx, over_source, null, over_url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, over_result, &exception));
    try std.testing.expectEqual(@as(usize, 4), state.pauses);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[over_start..state.len], "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[over_start..state.len], "\"lineNumber\":5") != null);

    state.mode = .out;
    state.used_step = false;
    const step_out_breakpoint =
        "{\"id\":4,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"step-out.js\",\"lineNumber\":1}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, step_out_breakpoint, step_out_breakpoint.len));
    const out_source = JSStringCreateWithUTF8CString(
        "function outFn() {\n var insideOut = 1;\n return insideOut;\n}\nvar outResult = outFn();\noutResult += 1;\noutResult;",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(out_source);
    const out_url = JSStringCreateWithUTF8CString("step-out.js") orelse return error.StringInitFailed;
    defer JSStringRelease(out_url);
    const out_start = state.len;
    const out_result = JSEvaluateScript(ctx, out_source, null, out_url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, out_result, &exception));
    try std.testing.expectEqual(@as(usize, 6), state.pauses);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[out_start..state.len], "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[out_start..state.len], "\"lineNumber\":5") != null);

    state.mode = .over;
    state.used_step = false;
    const step_exception_breakpoint =
        "{\"id\":5,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"step-exception.js\",\"lineNumber\":5}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, step_exception_breakpoint, step_exception_breakpoint.len));
    const exception_source = JSStringCreateWithUTF8CString(
        "function throwFn() {\n throw 1;\n}\nvar afterThrow = 0;\ntry {\n throwFn();\n} catch (errorValue) {\n afterThrow = 2;\n}\nafterThrow;",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(exception_source);
    const exception_url = JSStringCreateWithUTF8CString("step-exception.js") orelse return error.StringInitFailed;
    defer JSStringRelease(exception_url);
    const exception_start = state.len;
    const exception_result = JSEvaluateScript(ctx, exception_source, null, exception_url, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, exception_result, &exception));
    try std.testing.expectEqual(@as(usize, 8), state.pauses);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[exception_start..state.len], "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[exception_start..state.len], "\"lineNumber\":7") != null);
}

test "C-API: debugger exception policy distinguishes caught and uncaught throws" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,
        bytes: [32768]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const resume_request = "{\"id\":90,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_request, resume_request.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));

    const pause_all = "{\"id\":2,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"all\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, pause_all, pause_all.len));
    const caught_source = JSStringCreateWithUTF8CString("var caught = 0;\ntry { throw 'caught'; } catch (value) { caught = 1; }\ncaught;") orelse return error.StringInitFailed;
    defer JSStringRelease(caught_source);
    const exception_url = JSStringCreateWithUTF8CString("exceptions.js") orelse return error.StringInitFailed;
    defer JSStringRelease(exception_url);
    var exception: JSValueRef = null;
    const caught = JSEvaluateScript(ctx, caught_source, null, exception_url, 10, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 1), JSValueToNumber(ctx, caught, &exception));
    try std.testing.expectEqual(@as(usize, 1), state.pauses);

    // Engine-created errors use the same origin hook, not just explicit throw.
    const type_error_source = JSStringCreateWithUTF8CString("try { null.missing; } catch (value) { 2; }") orelse return error.StringInitFailed;
    defer JSStringRelease(type_error_source);
    _ = JSEvaluateScript(ctx, type_error_source, null, exception_url, 20, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(usize, 2), state.pauses);

    const pause_uncaught = "{\"id\":3,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"uncaught\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, pause_uncaught, pause_uncaught.len));
    _ = JSEvaluateScript(ctx, caught_source, null, exception_url, 30, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(usize, 2), state.pauses);
    const uncaught_source = JSStringCreateWithUTF8CString("throw new Error('uncaught');") orelse return error.StringInitFailed;
    defer JSStringRelease(uncaught_source);
    try std.testing.expect(JSEvaluateScript(ctx, uncaught_source, null, exception_url, 40, &exception) == null);
    try std.testing.expect(exception != null);
    try std.testing.expectEqual(@as(usize, 3), state.pauses);

    const pause_none = "{\"id\":4,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"none\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, pause_none, pause_none.len));
    exception = null;
    try std.testing.expect(JSEvaluateScript(ctx, uncaught_source, null, exception_url, 50, &exception) == null);
    try std.testing.expectEqual(@as(usize, 3), state.pauses);

    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.exceptionThrown") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"exception\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"uncaught\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"uncaught\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"lineNumber\":10") != null);
}

test "C-API: debugger checkpoints survive generator yield and async await" {
    const State = struct {
        session: ZJSInspectorSessionRef = null,
        step_next: bool = true,
        used_step: bool = false,
        pauses: usize = 0,
        bytes: [32768]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.len + message_len + 1 <= self.bytes.len);
            @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
            self.len += message_len;
            self.bytes[self.len] = '\n';
            self.len += 1;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const command = if (self.step_next and !self.used_step)
                "{\"id\":80,\"method\":\"Debugger.stepInto\"}"
            else
                "{\"id\":89,\"method\":\"Debugger.resume\"}";
            self.used_step = true;
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, command, command.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    var state: State = .{};
    state.session = ZJSInspectorSessionCreate(ctx, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(state.session);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, enable, enable.len));

    const generator_breakpoint =
        "{\"id\":2,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"generator-debug.js\",\"lineNumber\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, generator_breakpoint, generator_breakpoint.len));
    const generator_source = JSStringCreateWithUTF8CString(
        "function* debugGenerator() {\n var value = 1;\n yield value;\n value += 1;\n return value;\n}\nvar debugIterator = debugGenerator();\nvar generatorPair = String(debugIterator.next().value) + ',' + String(debugIterator.next().value);\ngeneratorPair;",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(generator_source);
    const generator_url = JSStringCreateWithUTF8CString("generator-debug.js") orelse return error.StringInitFailed;
    defer JSStringRelease(generator_url);
    var exception: JSValueRef = null;
    const generator_result = JSEvaluateScript(ctx, generator_source, null, generator_url, 1, &exception) orelse return error.EvalFailed;
    const generator_description = inspectorDescription(ctx, generator_result) orelse return error.DescriptionFailed;
    defer generator_description.deinit();
    try std.testing.expectEqualStrings("1,2", generator_description.bytes);
    try std.testing.expectEqual(@as(usize, 2), state.pauses);

    state.used_step = false;
    const async_breakpoint =
        "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"async-debug.js\",\"lineNumber\":2}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, async_breakpoint, async_breakpoint.len));
    const async_source = JSStringCreateWithUTF8CString(
        "async function debugAsync() {\n var value = 3;\n await 0;\n value += 1;\n return value;\n}\nvar asyncDebugResult = 0;\ndebugAsync().then(function(value) { asyncDebugResult = value; });\n'scheduled';",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(async_source);
    const async_url = JSStringCreateWithUTF8CString("async-debug.js") orelse return error.StringInitFailed;
    defer JSStringRelease(async_url);
    _ = JSEvaluateScript(ctx, async_source, null, async_url, 1, &exception) orelse return error.EvalFailed;
    const async_result_source = JSStringCreateWithUTF8CString("asyncDebugResult;") orelse return error.StringInitFailed;
    defer JSStringRelease(async_result_source);
    const async_result = JSEvaluateScript(ctx, async_result_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 4), JSValueToNumber(ctx, async_result, &exception));
    try std.testing.expectEqual(@as(usize, 4), state.pauses);

    state.step_next = false;
    state.used_step = false;
    const pause_all = "{\"id\":4,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"all\"}}";
    try std.testing.expect(ZJSInspectorSessionDispatch(state.session, pause_all, pause_all.len));
    const generator_throw_source = JSStringCreateWithUTF8CString(
        "function* throwingGenerator() { try { throw 'vm'; } catch (value) { yield 5; } } throwingGenerator().next().value;",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(generator_throw_source);
    _ = JSEvaluateScript(ctx, generator_throw_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(usize, 5), state.pauses);

    const transcript = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"lineNumber\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.exceptionThrown") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"functionName\":\"debugGenerator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"functionName\":\"debugAsync\"") != null);
}

test "C-API: ordinary constructors keep intrinsic identity and function source metadata" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const override_source = JSStringCreateWithUTF8CString(
        "Date = Error = RegExp = Function = function Replaced(){ throw 99; };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(override_source);
    var exception: JSValueRef = null;
    _ = JSEvaluateScript(ctx, override_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const zero = JSValueMakeNumber(ctx, 0) orelse return error.ValueCreateFailed;
    const date = JSObjectMakeDate(ctx, 1, @ptrCast(&zero), &exception) orelse return error.DateCreateFailed;
    try std.testing.expect(exception == null);
    const get_time_key = JSStringCreateWithUTF8CString("getTime") orelse return error.StringInitFailed;
    defer JSStringRelease(get_time_key);
    const get_time = JSObjectGetProperty(ctx, date, get_time_key, &exception) orelse return error.PropertyGetFailed;
    const epoch = JSObjectCallAsFunction(ctx, get_time, date, 0, null, &exception) orelse return error.FunctionCallFailed;
    try std.testing.expectEqual(@as(f64, 0), JSValueToNumber(ctx, epoch, &exception));

    const function_name = JSStringCreateWithUTF8CString("sum") orelse return error.StringInitFailed;
    defer JSStringRelease(function_name);
    const param_a = JSStringCreateWithUTF8CString("a") orelse return error.StringInitFailed;
    defer JSStringRelease(param_a);
    const param_b = JSStringCreateWithUTF8CString("b") orelse return error.StringInitFailed;
    defer JSStringRelease(param_b);
    const params = [_]JSStringRef{ param_a, param_b };
    const function_body = JSStringCreateWithUTF8CString("return a + b;") orelse return error.StringInitFailed;
    defer JSStringRelease(function_body);
    const source_url = JSStringCreateWithUTF8CString("dynamic.js") orelse return error.StringInitFailed;
    defer JSStringRelease(source_url);
    const function = JSObjectMakeFunction(ctx, function_name, params.len, &params, function_body, source_url, 17, &exception) orelse return error.FunctionCreateFailed;
    try std.testing.expect(exception == null);

    const arguments = [_]JSValueRef{
        JSValueMakeNumber(ctx, 2) orelse return error.ValueCreateFailed,
        JSValueMakeNumber(ctx, 3) orelse return error.ValueCreateFailed,
    };
    const result = JSObjectCallAsFunction(ctx, function, null, arguments.len, &arguments, &exception) orelse return error.FunctionCallFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 5), JSValueToNumber(ctx, result, &exception));

    const name_key = JSStringCreateWithUTF8CString("name") orelse return error.StringInitFailed;
    defer JSStringRelease(name_key);
    const name_value = JSObjectGetProperty(ctx, function, name_key, &exception) orelse return error.PropertyGetFailed;
    const actual_name = JSValueToStringCopy(ctx, name_value, &exception) orelse return error.StringConvertFailed;
    defer JSStringRelease(actual_name);
    try std.testing.expect(JSStringIsEqual(actual_name, function_name));

    const to_string_source = JSStringCreateWithUTF8CString("globalThis.createdFunction.toString()") orelse return error.StringInitFailed;
    defer JSStringRelease(to_string_source);
    const binding = JSStringCreateWithUTF8CString("createdFunction") orelse return error.StringInitFailed;
    defer JSStringRelease(binding);
    JSObjectSetProperty(ctx, JSContextGetGlobalObject(ctx), binding, function, 0, &exception);
    const rendered = JSEvaluateScript(ctx, to_string_source, null, null, 1, &exception) orelse return error.EvalFailed;
    const rendered_string = JSValueToStringCopy(ctx, rendered, &exception) orelse return error.StringConvertFailed;
    defer JSStringRelease(rendered_string);
    try std.testing.expect(JSStringIsEqualToUTF8CString(rendered_string, "function sum(a,b\n) {\nreturn a + b;\n}"));

    const invalid_body = JSStringCreateWithUTF8CString("return )") orelse return error.StringInitFailed;
    defer JSStringRelease(invalid_body);
    exception = null;
    try std.testing.expect(JSObjectMakeFunction(ctx, function_name, 0, null, invalid_body, source_url, 41, &exception) == null);
    try std.testing.expect(exception != null);
    const source_key = JSStringCreateWithUTF8CString("sourceURL") orelse return error.StringInitFailed;
    defer JSStringRelease(source_key);
    const line_key = JSStringCreateWithUTF8CString("startingLineNumber") orelse return error.StringInitFailed;
    defer JSStringRelease(line_key);
    const exception_source = JSObjectGetProperty(ctx, exception, source_key, null) orelse return error.PropertyGetFailed;
    const exception_source_string = JSValueToStringCopy(ctx, exception_source, null) orelse return error.StringConvertFailed;
    defer JSStringRelease(exception_source_string);
    try std.testing.expect(JSStringIsEqual(exception_source_string, source_url));
    const exception_line = JSObjectGetProperty(ctx, exception, line_key, null) orelse return error.PropertyGetFailed;
    try std.testing.expectEqual(@as(f64, 41), JSValueToNumber(ctx, exception_line, null));
}

test "C-API: JSObjectSetPropertyForKey preserves key coercion and attributes" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const pair_source = JSStringCreateWithUTF8CString("(() => { const key = Symbol('key'); return [{}, key]; })()") orelse return error.StringInitFailed;
    defer JSStringRelease(pair_source);
    var exception: JSValueRef = null;
    const pair = JSEvaluateScript(ctx, pair_source, null, null, 1, &exception) orelse return error.EvalFailed;
    const object = JSObjectGetPropertyAtIndex(ctx, pair, 0, &exception) orelse return error.PropertyGetFailed;
    const symbol = JSObjectGetPropertyAtIndex(ctx, pair, 1, &exception) orelse return error.PropertyGetFailed;
    const value_ref = JSValueMakeNumber(ctx, 13) orelse return error.ValueCreateFailed;
    JSObjectSetPropertyForKey(ctx, object, symbol, value_ref, kJSPropertyAttributeDontDelete, &exception);
    try std.testing.expect(exception == null);
    try std.testing.expect(JSObjectHasPropertyForKey(ctx, object, symbol, &exception));
    const stored = JSObjectGetPropertyForKey(ctx, object, symbol, &exception) orelse return error.PropertyGetFailed;
    try std.testing.expectEqual(@as(f64, 13), JSValueToNumber(ctx, stored, &exception));
    try std.testing.expect(!JSObjectDeletePropertyForKey(ctx, object, symbol, &exception));
    try std.testing.expect(JSObjectHasPropertyForKey(ctx, object, symbol, &exception));

    const number_key = JSValueMakeNumber(ctx, 5) orelse return error.ValueCreateFailed;
    JSObjectSetPropertyForKey(ctx, object, number_key, JSValueMakeBoolean(ctx, true), 0, &exception);
    const five = JSStringCreateWithUTF8CString("5") orelse return error.StringInitFailed;
    defer JSStringRelease(five);
    try std.testing.expect(JSValueToBoolean(ctx, JSObjectGetProperty(ctx, object, five, &exception)));

    const throwing_key_source = JSStringCreateWithUTF8CString("({ [Symbol.toPrimitive]() { throw 44; } })") orelse return error.StringInitFailed;
    defer JSStringRelease(throwing_key_source);
    const throwing_key = JSEvaluateScript(ctx, throwing_key_source, null, null, 1, &exception) orelse return error.EvalFailed;
    exception = null;
    JSObjectSetPropertyForKey(ctx, object, throwing_key, value_ref, 0, &exception);
    try std.testing.expect(exception != null);
    try std.testing.expectEqual(@as(f64, 44), JSValueToNumber(ctx, exception, null));
}

test "C-API: JSGlobalContextRetain keeps context alive until final release" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    const retained = JSGlobalContextRetain(ctx) orelse return error.RetainFailed;
    try std.testing.expectEqual(ctx, retained);

    JSGlobalContextRelease(ctx);

    const script = JSStringCreateWithUTF8CString("var retainedValue = 40; retainedValue + 2") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(retained, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(retained, result, null));

    JSGlobalContextRelease(retained);
}

test "C-API: JSGlobalContextRetain rejects refcount overflow" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    const c = ctxRawFrom(ctx) orelse return error.JSCInitFailed;
    c.c_api_ref_count.store(std.math.maxInt(usize), .release);
    try std.testing.expect(JSGlobalContextRetain(ctx) == null);
    try std.testing.expectEqual(std.math.maxInt(usize), c.c_api_ref_count.load(.acquire));
    c.c_api_ref_count.store(1, .release);
    JSGlobalContextRelease(ctx);
}

test "C-API: round-trip a UTF-8 string" {
    const s = JSStringCreateWithUTF8CString("hello") orelse return error.StringInitFailed;
    defer JSStringRelease(s);
    try std.testing.expectEqual(@as(usize, 5), JSStringGetLength(s));

    var buf: [16]u8 = undefined;
    const written = JSStringGetUTF8CString(s, &buf, buf.len);
    try std.testing.expectEqual(@as(usize, 6), written); // "hello" + NUL
    try std.testing.expectEqualStrings("hello", buf[0 .. written - 1]);
}

test "C-API: JSString preserves UTF-16 and compares by code units" {
    const units = [_]u16{ 'A', 0xD83D, 0xDE00, 0xD800, 'Z' };
    const string = JSStringCreateWithCharacters(&units, units.len) orelse return error.StringInitFailed;
    defer JSStringRelease(string);

    try std.testing.expectEqual(units.len, JSStringGetLength(string));
    const borrowed = JSStringGetCharactersPtr(string);
    try std.testing.expect(borrowed != null);
    try std.testing.expectEqualSlices(u16, &units, borrowed[0..units.len]);
    try std.testing.expectEqual(units.len * 3 + 1, JSStringGetMaximumUTF8CStringSize(string));

    const same = JSStringCreateWithCharacters(&units, units.len) orelse return error.StringInitFailed;
    defer JSStringRelease(same);
    try std.testing.expect(JSStringIsEqual(string, same));
    try std.testing.expect(!JSStringIsEqualToUTF8CString(string, "A😀�Z"));

    const empty = JSStringCreateWithCharacters(null, 0) orelse return error.StringInitFailed;
    defer JSStringRelease(empty);
    try std.testing.expectEqual(@as(usize, 0), JSStringGetLength(empty));
    try std.testing.expect(JSStringCreateWithCharacters(null, 1) == null);
}

test "C-API: JSString preserves embedded NUL and saturates maximum UTF-8 size" {
    const units = [_]u16{ 'a', 0, 'b' };
    const string = JSStringCreateWithCharacters(&units, units.len) orelse return error.StringInitFailed;
    defer JSStringRelease(string);
    try std.testing.expectEqual(@as(usize, 3), JSStringGetLength(string));
    try std.testing.expectEqualSlices(u16, &units, JSStringGetCharactersPtr(string)[0..units.len]);
    try std.testing.expect(!JSStringIsEqualToUTF8CString(string, "a"));

    const raw = strFrom(string) orelse return error.StringInitFailed;
    const original = raw.utf16;
    raw.utf16 = raw.utf16.ptr[0 .. std.math.maxInt(usize) / 3 + 1];
    defer raw.utf16 = original;
    try std.testing.expectEqual(std.math.maxInt(usize), JSStringGetMaximumUTF8CStringSize(string));
}

test "C-API: JSString UTF-8 truncation preserves code point boundaries" {
    const string = JSStringCreateWithUTF8CString("A😀Z") orelse return error.StringInitFailed;
    defer JSStringRelease(string);
    try std.testing.expect(JSStringIsEqualToUTF8CString(string, "A😀Z"));
    try std.testing.expect(!JSStringIsEqualToUTF8CString(string, "A😀X"));

    var short: [4]u8 = undefined;
    const written = JSStringGetUTF8CString(string, &short, short.len);
    try std.testing.expectEqual(@as(usize, 2), written);
    try std.testing.expectEqualStrings("A", short[0 .. written - 1]);
}

test "C-API: JSString null C pointers are rejected safely" {
    try std.testing.expect(JSStringCreateWithUTF8CString(null) == null);
    try std.testing.expectEqual(@as(usize, 0), JSStringGetLength(null));
    try std.testing.expect(JSStringGetCharactersPtr(null) == null);
    try std.testing.expectEqual(@as(usize, 0), JSStringGetMaximumUTF8CStringSize(null));
    try std.testing.expect(!JSStringIsEqual(null, null));
    try std.testing.expect(!JSStringIsEqualToUTF8CString(null, ""));
    try std.testing.expectEqual(@as(usize, 0), JSStringGetUTF8CString(null, null, 8));

    const s = JSStringCreateWithUTF8CString("hello") orelse return error.StringInitFailed;
    defer JSStringRelease(s);
    try std.testing.expectEqual(@as(usize, 0), JSStringGetUTF8CString(s, null, 8));
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), JSStringGetUTF8CString(s, &one, one.len));
    try std.testing.expectEqual(@as(u8, 0), one[0]);
}

test "C-API: JSString rejects invalid UTF-8 input" {
    const invalid = [_:0]u8{ 'b', 'a', 'd', 0xc0, 'u', 't', 'f', '8' };
    try std.testing.expect(JSStringCreateWithUTF8CString(&invalid) == null);
    const valid = JSStringCreateWithUTF8CString("valid") orelse return error.StringInitFailed;
    defer JSStringRelease(valid);
    try std.testing.expect(!JSStringIsEqualToUTF8CString(valid, &invalid));
}

test "C-API: JSStringRetain rejects refcount overflow" {
    const str = JSStringCreateWithUTF8CString("retain overflow") orelse return error.StringInitFailed;
    const s = strFrom(str) orelse return error.StringInitFailed;
    s.refcount.store(std.math.maxInt(usize), .release);
    try std.testing.expect(JSStringRetain(str) == null);
    try std.testing.expectEqual(std.math.maxInt(usize), s.refcount.load(.acquire));
    s.refcount.store(1, .release);
    JSStringRelease(str);
}

test "C-API: JSValueMakeString rejects null string refs" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    try std.testing.expect(JSValueMakeString(ctx, null) == null);
}

test "C-API: primitive object-tagged values report primitive types" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const symbol_script = JSStringCreateWithUTF8CString("Symbol('x')") orelse return error.StringInitFailed;
    defer JSStringRelease(symbol_script);
    const symbol_value = JSEvaluateScript(ctx, symbol_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(JSType.symbol, JSValueGetType(ctx, symbol_value));
    try std.testing.expect(!JSValueIsObject(ctx, symbol_value));

    const bigint_script = JSStringCreateWithUTF8CString("1n") orelse return error.StringInitFailed;
    defer JSStringRelease(bigint_script);
    const bigint_value = JSEvaluateScript(ctx, bigint_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(JSType.bigint, JSValueGetType(ctx, bigint_value));
    try std.testing.expect(!JSValueIsObject(ctx, bigint_value));
}

test "C-API: Symbol construction preserves uniqueness and owned description" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const description = JSStringCreateWithUTF8CString("native") orelse return error.StringInitFailed;
    const first = JSValueMakeSymbol(ctx, description) orelse return error.SymbolCreateFailed;
    JSStringRelease(description);
    const second_description = JSStringCreateWithUTF8CString("native") orelse return error.StringInitFailed;
    defer JSStringRelease(second_description);
    const second = JSValueMakeSymbol(ctx, second_description) orelse return error.SymbolCreateFailed;

    try std.testing.expect(JSValueIsSymbol(ctx, first));
    try std.testing.expect(!JSValueIsBigInt(ctx, first));
    try std.testing.expect(!JSValueIsStrictEqual(ctx, first, second));
    const binding = JSStringCreateWithUTF8CString("nativeSymbol") orelse return error.StringInitFailed;
    defer JSStringRelease(binding);
    var exception: JSValueRef = null;
    JSObjectSetProperty(ctx, JSContextGetGlobalObject(ctx), binding, first, 0, &exception);
    try std.testing.expect(exception == null);
    const description_probe = JSStringCreateWithUTF8CString("nativeSymbol.description === 'native' && String(nativeSymbol) === 'Symbol(native)'") orelse return error.StringInitFailed;
    defer JSStringRelease(description_probe);
    const description_ok = JSEvaluateScript(ctx, description_probe, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, description_ok));

    const bigint_source = JSStringCreateWithUTF8CString("123n") orelse return error.StringInitFailed;
    defer JSStringRelease(bigint_source);
    const bigint = JSEvaluateScript(ctx, bigint_source, null, null, 1, null) orelse return error.EvalFailed;
    try std.testing.expect(JSValueIsBigInt(ctx, bigint));
    try std.testing.expect(!JSValueIsSymbol(ctx, bigint));
}

test "C-API: BigInt constructors preserve exact values and exceptions" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    var exception: JSValueRef = null;
    const from_double = JSBigIntCreateWithDouble(ctx, 42.0, &exception) orelse return error.BigIntCreateFailed;
    const from_signed = JSBigIntCreateWithInt64(ctx, std.math.minInt(i64), &exception) orelse return error.BigIntCreateFailed;
    const from_unsigned = JSBigIntCreateWithUInt64(ctx, std.math.maxInt(u64), &exception) orelse return error.BigIntCreateFailed;
    const text = JSStringCreateWithUTF8CString("123456789012345678901234567890") orelse return error.StringInitFailed;
    defer JSStringRelease(text);
    const from_text = JSBigIntCreateWithString(ctx, text, &exception) orelse return error.BigIntCreateFailed;
    try std.testing.expect(exception == null);

    const global = JSContextGetGlobalObject(ctx);
    for ([_]struct { name: [*:0]const u8, value_ref: JSValueRef }{
        .{ .name = "bigDouble", .value_ref = from_double },
        .{ .name = "bigSigned", .value_ref = from_signed },
        .{ .name = "bigUnsigned", .value_ref = from_unsigned },
        .{ .name = "bigText", .value_ref = from_text },
    }) |entry| {
        const name = JSStringCreateWithUTF8CString(entry.name) orelse return error.StringInitFailed;
        defer JSStringRelease(name);
        JSObjectSetProperty(ctx, global, name, entry.value_ref, 0, &exception);
    }
    const probe = JSStringCreateWithUTF8CString(
        "bigDouble === 42n && bigSigned === -9223372036854775808n && " ++
            "bigUnsigned === 18446744073709551615n && " ++
            "bigText === 123456789012345678901234567890n",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(probe);
    const exact = JSEvaluateScript(ctx, probe, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, exact));

    try std.testing.expect(JSBigIntCreateWithDouble(ctx, 1.5, &exception) == null);
    try std.testing.expect(exception != null);
    exception = null;
    const invalid = JSStringCreateWithUTF8CString("12x") orelse return error.StringInitFailed;
    defer JSStringRelease(invalid);
    try std.testing.expect(JSBigIntCreateWithString(ctx, invalid, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSON parse and stringify preserve JSC contracts" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const json = JSStringCreateWithUTF8CString("{\"a\":1,\"b\":[true,null],\"text\":\"😀\"}") orelse return error.StringInitFailed;
    defer JSStringRelease(json);
    const parsed = JSValueMakeFromJSONString(ctx, json) orelse return error.JsonParseFailed;

    const binding = JSStringCreateWithUTF8CString("parsedFromC") orelse return error.StringInitFailed;
    defer JSStringRelease(binding);
    var exception: JSValueRef = null;
    JSObjectSetProperty(ctx, JSContextGetGlobalObject(ctx), binding, parsed, 0, &exception);
    const probe = JSStringCreateWithUTF8CString("parsedFromC.a === 1 && parsedFromC.b[0] === true && parsedFromC.b[1] === null && parsedFromC.text === '😀'") orelse return error.StringInitFailed;
    defer JSStringRelease(probe);
    const correct = JSEvaluateScript(ctx, probe, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, correct));

    const pretty = JSValueCreateJSONString(ctx, parsed, 99, &exception) orelse return error.JsonStringifyFailed;
    defer JSStringRelease(pretty);
    try std.testing.expect(exception == null);
    var output: [256]u8 = undefined;
    const written = JSStringGetUTF8CString(pretty, &output, output.len);
    try std.testing.expect(std.mem.indexOf(u8, output[0 .. written - 1], "\n          \"a\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output[0 .. written - 1], "\n           \"a\": 1") == null);

    const invalid = JSStringCreateWithUTF8CString("{]") orelse return error.StringInitFailed;
    defer JSStringRelease(invalid);
    try std.testing.expect(JSValueMakeFromJSONString(ctx, invalid) == null);

    const cyclic_source = JSStringCreateWithUTF8CString("(() => { const value = {}; value.self = value; return value; })()") orelse return error.StringInitFailed;
    defer JSStringRelease(cyclic_source);
    const cyclic = JSEvaluateScript(ctx, cyclic_source, null, null, 1, &exception) orelse return error.EvalFailed;
    exception = null;
    try std.testing.expect(JSValueCreateJSONString(ctx, cyclic, 0, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSValueCreateJSONString(ctx, JSValueMakeUndefined(ctx), 0, &exception) == null);
    try std.testing.expect(exception == null);
}

test "C-API: integer conversions match JSC modulo and exception semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const Case = struct { number: f64, i32: i32, u32: u32, i64: i64, u64: u64 };
    for ([_]Case{
        .{ .number = std.math.nan(f64), .i32 = 0, .u32 = 0, .i64 = 0, .u64 = 0 },
        .{ .number = std.math.inf(f64), .i32 = 0, .u32 = 0, .i64 = 0, .u64 = 0 },
        .{ .number = -1.5, .i32 = -1, .u32 = std.math.maxInt(u32), .i64 = -1, .u64 = std.math.maxInt(u64) },
        .{ .number = 4294967297.0, .i32 = 1, .u32 = 1, .i64 = 4294967297, .u64 = 4294967297 },
        .{ .number = 9223372036854775808.0, .i32 = 0, .u32 = 0, .i64 = std.math.minInt(i64), .u64 = @as(u64, 1) << 63 },
        .{ .number = 18446744073709551616.0, .i32 = 0, .u32 = 0, .i64 = 0, .u64 = 0 },
    }) |case| {
        const number = JSValueMakeNumber(ctx, case.number) orelse return error.ValueCreateFailed;
        var exception: JSValueRef = null;
        try std.testing.expectEqual(case.i32, JSValueToInt32(ctx, number, &exception));
        try std.testing.expect(exception == null);
        try std.testing.expectEqual(case.u32, JSValueToUInt32(ctx, number, &exception));
        try std.testing.expectEqual(case.i64, JSValueToInt64(ctx, number, &exception));
        try std.testing.expectEqual(case.u64, JSValueToUInt64(ctx, number, &exception));
    }

    var exception: JSValueRef = null;
    const positive_text = JSStringCreateWithUTF8CString("18446744073709551617") orelse return error.StringInitFailed;
    defer JSStringRelease(positive_text);
    const positive = JSBigIntCreateWithString(ctx, positive_text, &exception) orelse return error.BigIntCreateFailed;
    try std.testing.expectEqual(@as(i32, 1), JSValueToInt32(ctx, positive, &exception));
    try std.testing.expectEqual(@as(u64, 1), JSValueToUInt64(ctx, positive, &exception));

    const negative_text = JSStringCreateWithUTF8CString("-9223372036854775809") orelse return error.StringInitFailed;
    defer JSStringRelease(negative_text);
    const negative = JSBigIntCreateWithString(ctx, negative_text, &exception) orelse return error.BigIntCreateFailed;
    try std.testing.expectEqual(std.math.maxInt(i64), JSValueToInt64(ctx, negative, &exception));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i64)), JSValueToUInt64(ctx, negative, &exception));
    try std.testing.expectEqual(@as(i32, -1), JSValueToInt32(ctx, negative, &exception));
    try std.testing.expectEqual(std.math.maxInt(u32), JSValueToUInt32(ctx, negative, &exception));

    const symbol = JSValueMakeSymbol(ctx, null) orelse return error.SymbolCreateFailed;
    exception = null;
    try std.testing.expectEqual(@as(i64, 0), JSValueToInt64(ctx, symbol, &exception));
    try std.testing.expect(exception != null);
}

test "C-API: relation conditions and Number conversion match JSC" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    var exception: JSValueRef = null;
    const one = JSValueMakeNumber(ctx, 1) orelse return error.ValueCreateFailed;
    const two = JSValueMakeNumber(ctx, 2) orelse return error.ValueCreateFailed;
    try std.testing.expectEqual(JSRelationCondition.less_than, JSValueCompare(ctx, one, two, &exception));
    try std.testing.expectEqual(JSRelationCondition.greater_than, JSValueCompare(ctx, two, one, &exception));
    try std.testing.expectEqual(JSRelationCondition.equal, JSValueCompare(ctx, one, one, &exception));
    try std.testing.expectEqual(JSRelationCondition.undefined, JSValueCompare(ctx, JSValueMakeNumber(ctx, std.math.nan(f64)), one, &exception));
    try std.testing.expect(exception == null);

    const two_string = JSStringCreateWithUTF8CString("2") orelse return error.StringInitFailed;
    defer JSStringRelease(two_string);
    const string_two = JSValueMakeString(ctx, two_string) orelse return error.ValueCreateFailed;
    try std.testing.expectEqual(JSRelationCondition.equal, JSValueCompare(ctx, string_two, two, &exception));
    try std.testing.expectEqual(JSRelationCondition.greater_than, JSValueCompareInt64(ctx, JSValueMakeNumber(ctx, 1.5), 1, &exception));
    try std.testing.expectEqual(JSRelationCondition.greater_than, JSValueCompareDouble(ctx, JSValueMakeNumber(ctx, std.math.inf(f64)), 0, &exception));

    const huge_text = JSStringCreateWithUTF8CString("18446744073709551617") orelse return error.StringInitFailed;
    defer JSStringRelease(huge_text);
    const huge = JSBigIntCreateWithString(ctx, huge_text, &exception) orelse return error.BigIntCreateFailed;
    try std.testing.expectEqual(JSRelationCondition.greater_than, JSValueCompareUInt64(ctx, huge, 1, &exception));
    try std.testing.expectEqual(@as(f64, 18446744073709551616.0), JSValueToNumber(ctx, huge, &exception));

    const boxed_source = JSStringCreateWithUTF8CString("Object(42n)") orelse return error.StringInitFailed;
    defer JSStringRelease(boxed_source);
    const boxed = JSEvaluateScript(ctx, boxed_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, boxed, &exception));

    const same_object_source = JSStringCreateWithUTF8CString("({ valueOf() { return NaN; } })") orelse return error.StringInitFailed;
    defer JSStringRelease(same_object_source);
    const same_object = JSEvaluateScript(ctx, same_object_source, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expectEqual(JSRelationCondition.equal, JSValueCompare(ctx, same_object, same_object, &exception));
    try std.testing.expectEqual(JSRelationCondition.undefined, JSValueCompare(ctx, same_object, one, &exception));

    const symbol = JSValueMakeSymbol(ctx, null) orelse return error.SymbolCreateFailed;
    exception = null;
    try std.testing.expectEqual(JSRelationCondition.undefined, JSValueCompareInt64(ctx, symbol, 0, &exception));
    try std.testing.expect(exception != null);
}

test "C-API: instanceof honors constructors and Symbol.hasInstance" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    var exception: JSValueRef = null;
    const setup = JSStringCreateWithUTF8CString(
        "class NativeCheck {}; globalThis.nativeCtor = NativeCheck; " ++
            "globalThis.nativeInstance = new NativeCheck(); globalThis.nativeOther = {}; " ++
            "globalThis.customCtor = { [Symbol.hasInstance](value) { return value === nativeOther; } };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(setup);
    _ = JSEvaluateScript(ctx, setup, null, null, 1, &exception) orelse return error.EvalFailed;
    const global = JSContextGetGlobalObject(ctx);
    const ctor_name = JSStringCreateWithUTF8CString("nativeCtor") orelse return error.StringInitFailed;
    defer JSStringRelease(ctor_name);
    const instance_name = JSStringCreateWithUTF8CString("nativeInstance") orelse return error.StringInitFailed;
    defer JSStringRelease(instance_name);
    const other_name = JSStringCreateWithUTF8CString("nativeOther") orelse return error.StringInitFailed;
    defer JSStringRelease(other_name);
    const custom_name = JSStringCreateWithUTF8CString("customCtor") orelse return error.StringInitFailed;
    defer JSStringRelease(custom_name);
    const ctor = JSObjectGetProperty(ctx, global, ctor_name, &exception) orelse return error.PropFailed;
    const instance = JSObjectGetProperty(ctx, global, instance_name, &exception) orelse return error.PropFailed;
    const other = JSObjectGetProperty(ctx, global, other_name, &exception) orelse return error.PropFailed;
    const custom = JSObjectGetProperty(ctx, global, custom_name, &exception) orelse return error.PropFailed;
    try std.testing.expect(JSValueIsInstanceOfConstructor(ctx, instance, ctor, &exception));
    try std.testing.expect(!JSValueIsInstanceOfConstructor(ctx, other, ctor, &exception));
    try std.testing.expect(JSValueIsInstanceOfConstructor(ctx, other, custom, &exception));

    exception = null;
    try std.testing.expect(!JSValueIsInstanceOfConstructor(ctx, other, other, &exception));
    try std.testing.expect(exception != null);
}

test "C-API: value inspection APIs report null handles as invalid" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const undefined_value = JSValueMakeUndefined(ctx) orelse return error.ValueInitFailed;

    try std.testing.expectEqual(JSType.invalid, JSValueGetType(ctx, null));
    try std.testing.expect(!JSValueIsUndefined(ctx, null));
    try std.testing.expect(!JSValueIsNull(ctx, null));
    try std.testing.expect(!JSValueIsBoolean(ctx, null));
    try std.testing.expect(!JSValueIsNumber(ctx, null));
    try std.testing.expect(!JSValueIsString(ctx, null));
    try std.testing.expect(!JSValueIsObject(ctx, null));
    try std.testing.expect(!JSValueIsArray(ctx, null));
    try std.testing.expect(!JSValueIsDate(ctx, null));
    try std.testing.expect(!JSValueIsStrictEqual(ctx, null, null));
    try std.testing.expect(!JSValueIsStrictEqual(ctx, null, undefined_value));
    try std.testing.expect(!JSValueToBoolean(ctx, null));
}

test "C-API: context-owned handles reject cross-context use" {
    const ctx_a = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx_a);
    const ctx_b = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx_b);

    var exception: JSValueRef = null;
    const number_a = JSValueMakeNumber(ctx_a, 7) orelse return error.ValueInitFailed;
    const object_a = JSObjectMake(ctx_a, null, null) orelse return error.ObjectCreateFailed;
    const function_src = JSStringCreateWithUTF8CString("(function () { return 1; })") orelse return error.StringInitFailed;
    defer JSStringRelease(function_src);
    const function_a = JSEvaluateScript(ctx_a, function_src, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    try std.testing.expectEqual(JSType.invalid, JSValueGetType(ctx_b, number_a));
    try std.testing.expect(!JSValueIsNumber(ctx_b, number_a));
    try std.testing.expect(!JSValueToBoolean(ctx_b, number_a));
    try std.testing.expect(!JSValueIsStrictEqual(ctx_b, number_a, number_a));
    try std.testing.expect(!ZJSValueProtect(ctx_b, number_a));

    exception = null;
    try std.testing.expect(!JSValueIsEqual(ctx_b, number_a, JSValueMakeNumber(ctx_b, 7), &exception));
    try std.testing.expect(exception != null);

    exception = null;
    const coerced = JSValueToNumber(ctx_b, number_a, &exception);
    try std.testing.expect(std.math.isNan(coerced));
    try std.testing.expect(exception != null);

    const key = JSStringCreateWithUTF8CString("x") orelse return error.StringInitFailed;
    defer JSStringRelease(key);

    exception = null;
    try std.testing.expect(JSObjectGetProperty(ctx_b, object_a, key, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    JSObjectSetProperty(ctx_b, object_a, key, JSValueMakeNumber(ctx_b, 1), kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSObjectCallAsFunction(ctx_b, function_a, null, 0, null, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSObjectCallAsConstructor(ctx_b, function_a, 0, null, &exception) == null);
    try std.testing.expect(exception != null);

    const this_src = JSStringCreateWithUTF8CString("this") orelse return error.StringInitFailed;
    defer JSStringRelease(this_src);
    exception = null;
    try std.testing.expect(JSEvaluateScript(ctx_b, this_src, object_a, null, 0, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSEvaluateScript computes 1 + 1 === 2" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const script = JSStringCreateWithUTF8CString("1 + 1") orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsNumber(ctx, result));
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, result, null));
}

test "C-API: JSEvaluateScript rejects null script with exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    try std.testing.expect(JSEvaluateScript(ctx, null, null, null, 0, &exception) == null);
    try std.testing.expect(exception != null);

    const msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(msg);
    var buf: [128]u8 = undefined;
    const written = JSStringGetUTF8CString(msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "script is null") != null);
}

test "C-API: global JSClassRef attaches callbacks and static values" {
    const State = struct {
        var initialized: usize = 0;
        var finalized: usize = 0;

        fn initialize(_: JSContextRef, _: JSObjectRef) callconv(.c) void {
            initialized += 1;
        }
        fn finalize(_: JSObjectRef) callconv(.c) void {
            finalized += 1;
        }
        fn getValue(ctx: JSContextRef, _: JSObjectRef, _: JSStringRef, _: ExceptionRef) callconv(.c) JSValueRef {
            return JSValueMakeNumber(ctx, 77);
        }
    };
    State.initialized = 0;
    State.finalized = 0;
    const values = [_]JSStaticValue{
        .{ .name = "globalValue", .get_property = State.getValue },
        .{},
    };
    var definition: JSClassDefinition = .{
        .class_name = "CustomGlobal",
        .static_values = &values,
        .initialize = State.initialize,
        .finalize = State.finalize,
    };
    const class = JSClassCreate(&definition) orelse return error.ClassCreateFailed;
    const ctx = JSGlobalContextCreate(class) orelse return error.ContextCreateFailed;
    JSClassRelease(class);
    try std.testing.expectEqual(@as(usize, 1), State.initialized);

    const key = JSStringCreateWithUTF8CString("globalValue") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    var exception: JSValueRef = null;
    const global = JSContextGetGlobalObject(ctx) orelse return error.GlobalObjectFailed;
    const result = JSObjectGetProperty(ctx, global, key, &exception) orelse return error.PropertyGetFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 77), JSValueToNumber(ctx, result, &exception));
    JSGlobalContextRelease(ctx);
    try std.testing.expectEqual(@as(usize, 1), State.finalized);
}

test "C-API: JSClassRef copies definitions and owns inherited instance lifecycle" {
    const State = struct {
        var events: [4]u8 = undefined;
        var count: usize = 0;

        fn record(event: u8) void {
            events[count] = event;
            count += 1;
        }
        fn parentInitialize(_: JSContextRef, object: JSObjectRef) callconv(.c) void {
            std.debug.assert(JSObjectGetPrivate(object) == @as(?*anyopaque, @ptrFromInt(0x1234)));
            record(1);
        }
        fn childInitialize(_: JSContextRef, _: JSObjectRef) callconv(.c) void {
            record(2);
        }
        fn parentFinalize(_: JSObjectRef) callconv(.c) void {
            record(4);
        }
        fn childFinalize(_: JSObjectRef) callconv(.c) void {
            record(3);
        }
    };
    State.count = 0;

    var parent_definition: JSClassDefinition = .{
        .class_name = "Parent",
        .initialize = State.parentInitialize,
        .finalize = State.parentFinalize,
    };
    const parent = JSClassCreate(&parent_definition) orelse return error.ClassCreateFailed;

    var child_name = [_:0]u8{ 'C', 'h', 'i', 'l', 'd' };
    var static_name = [_:0]u8{'x'};
    var static_function_name = [_:0]u8{ 'r', 'u', 'n' };
    var static_values = [_]JSStaticValue{
        .{ .name = static_name[0.. :0].ptr },
        .{},
    };
    var static_functions = [_]JSStaticFunction{
        .{ .name = static_function_name[0.. :0].ptr },
        .{},
    };
    // Use a separate mutable static name to verify the sentinel-terminated
    // definition table and every entry name are copied, not borrowed.
    var child_definition: JSClassDefinition = .{
        .class_name = child_name[0.. :0].ptr,
        .parent_class = parent,
        .static_values = &static_values,
        .static_functions = &static_functions,
        .initialize = State.childInitialize,
        .finalize = State.childFinalize,
    };
    const child = JSClassCreate(&child_definition) orelse return error.ClassCreateFailed;
    child_name[0] = 'X';
    static_name[0] = 'y';
    static_function_name[0] = 'x';
    const child_internal = classFrom(child).?;
    try std.testing.expectEqualStrings("Child", child_internal.class_name.?);
    try std.testing.expectEqualStrings("x", std.mem.span(child_internal.static_values[0].name.?));
    try std.testing.expect(child_internal.static_values[1].name == null);
    try std.testing.expectEqualStrings("run", std.mem.span(child_internal.static_functions[0].name.?));
    try std.testing.expect(child_internal.static_functions[1].name == null);

    // The child and then the object independently retain their ancestry.
    JSClassRelease(parent);
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    const private: *anyopaque = @ptrFromInt(0x1234);
    const object = JSObjectMake(ctx, child, private) orelse return error.ObjectCreateFailed;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, State.events[0..State.count]);
    try std.testing.expect(JSValueIsObjectOfClass(ctx, object, child));
    try std.testing.expect(JSValueIsObjectOfClass(ctx, object, parent));
    try std.testing.expectEqual(private, JSObjectGetPrivate(object).?);

    var unrelated_definition: JSClassDefinition = .{ .class_name = "Unrelated" };
    const unrelated = JSClassCreate(&unrelated_definition) orelse return error.ClassCreateFailed;
    try std.testing.expect(!JSValueIsObjectOfClass(ctx, object, unrelated));
    JSClassRelease(unrelated);

    JSClassRelease(child);
    JSGlobalContextRelease(ctx);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, State.events[0..State.count]);
}

test "C-API: GC and context teardown finalize class instances exactly once" {
    const State = struct {
        var finalizations: usize = 0;
        fn finalize(_: JSObjectRef) callconv(.c) void {
            finalizations += 1;
        }
    };
    State.finalizations = 0;

    var definition: JSClassDefinition = .{ .finalize = State.finalize };
    const class = JSClassCreate(&definition) orelse return error.ClassCreateFailed;
    const context = Context.createWith(gpa, .{ .enable_gc = true }) catch return error.JSCInitFailed;
    context.initCApiRef();
    const ctx: JSContextRef = @ptrCast(context);
    _ = JSObjectMake(ctx, class, null) orelse return error.ObjectCreateFailed;
    JSClassRelease(class);

    JSGarbageCollect(ctx);
    try std.testing.expectEqual(@as(usize, 1), State.finalizations);
    JSGlobalContextRelease(ctx);
    try std.testing.expectEqual(@as(usize, 1), State.finalizations);
}

test "C-API: GC roots shared class prototypes and static functions" {
    const State = struct {
        fn call(
            ctx: JSContextRef,
            _: JSObjectRef,
            _: JSObjectRef,
            _: usize,
            _: [*c]const JSValueRef,
            _: ExceptionRef,
        ) callconv(.c) JSValueRef {
            return JSValueMakeNumber(ctx, 17);
        }
    };
    var functions = [_]JSStaticFunction{
        .{ .name = "run", .call_as_function = State.call },
        .{},
    };
    var definition: JSClassDefinition = .{ .static_functions = &functions };
    const class = JSClassCreate(&definition) orelse return error.ClassCreateFailed;
    const context = Context.createWith(gpa, .{ .enable_gc = true }) catch return error.JSCInitFailed;
    context.initCApiRef();
    const ctx: JSContextRef = @ptrCast(context);
    const name = JSStringCreateWithUTF8CString("run") orelse return error.StringInitFailed;
    defer JSStringRelease(name);

    const first = JSObjectMake(ctx, class, null) orelse return error.ObjectCreateFailed;
    const first_function = JSObjectGetProperty(ctx, first, name, null) orelse return error.PropertyGetFailed;
    JSGarbageCollect(ctx);
    const second = JSObjectMake(ctx, class, null) orelse return error.ObjectCreateFailed;
    const second_function = JSObjectGetProperty(ctx, second, name, null) orelse return error.PropertyGetFailed;
    try std.testing.expect(JSValueIsStrictEqual(ctx, first_function, second_function));
    const result = JSObjectCallAsFunction(ctx, second_function, second, 0, null, null) orelse return error.CallFailed;
    try std.testing.expectEqual(@as(f64, 17), JSValueToNumber(ctx, result, null));

    JSClassRelease(class);
    JSGlobalContextRelease(ctx);
}

test "C-API: constructor objects retain their instance class through precise GC" {
    var definition: JSClassDefinition = .{ .class_name = "RetainedByConstructor" };
    const class = JSClassCreate(&definition) orelse return error.ClassCreateFailed;
    const context = Context.createWith(gpa, .{ .enable_gc = true }) catch return error.JSCInitFailed;
    context.initCApiRef();
    const ctx: JSContextRef = @ptrCast(context);
    const constructor = JSObjectMakeConstructor(ctx, class, null) orelse return error.ConstructorCreateFailed;
    const name = JSStringCreateWithUTF8CString("RetainedConstructor") orelse return error.StringInitFailed;
    defer JSStringRelease(name);
    var exception: JSValueRef = null;
    JSObjectSetProperty(ctx, JSContextGetGlobalObject(ctx), name, constructor, 0, &exception);
    try std.testing.expect(exception == null);
    JSClassRelease(class);

    JSGarbageCollect(ctx);
    const instance = JSObjectCallAsConstructor(ctx, constructor, 0, null, &exception) orelse return error.ConstructFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsObject(ctx, instance));

    JSGlobalContextRelease(ctx);
}

test "C-API: class callbacks reject foreign-context and invalid return handles" {
    const State = struct {
        const Mode = enum { foreign_return, foreign_exception, invalid_return };
        var mode: Mode = .foreign_return;
        var foreign_value: JSValueRef = null;
        var foreign_object: JSObjectRef = null;

        fn get(
            _: JSContextRef,
            _: JSObjectRef,
            _: JSStringRef,
            exception: ExceptionRef,
        ) callconv(.c) JSValueRef {
            return switch (mode) {
                .foreign_return => foreign_value,
                .foreign_exception => blk: {
                    exception[0] = foreign_value;
                    break :blk null;
                },
                .invalid_return => null,
            };
        }

        fn call(
            _: JSContextRef,
            _: JSObjectRef,
            _: JSObjectRef,
            _: usize,
            _: [*c]const JSValueRef,
            _: ExceptionRef,
        ) callconv(.c) JSValueRef {
            return if (mode == .invalid_return) null else foreign_value;
        }

        fn construct(
            ctx: JSContextRef,
            _: JSObjectRef,
            _: usize,
            _: [*c]const JSValueRef,
            _: ExceptionRef,
        ) callconv(.c) JSObjectRef {
            if (mode == .foreign_return) return foreign_object;
            return if (mode == .invalid_return) JSValueMakeNumber(ctx, 1) else null;
        }

        fn convert(
            ctx: JSContextRef,
            _: JSObjectRef,
            _: JSType,
            _: ExceptionRef,
        ) callconv(.c) JSValueRef {
            if (mode == .foreign_return) return foreign_value;
            return if (mode == .invalid_return) JSObjectMake(ctx, null, null) else null;
        }
    };

    const ctx_a = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx_a);
    const context_a = ctxRawFrom(ctx_a).?;
    const ctx_b = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx_b);
    State.foreign_value = JSValueMakeNumber(ctx_b, 7);
    State.foreign_object = JSObjectMake(ctx_b, null, null);

    var definition: JSClassDefinition = .{
        .get_property = State.get,
        .call_as_function = State.call,
        .call_as_constructor = State.construct,
        .convert_to_type = State.convert,
    };
    const class = JSClassCreate(&definition) orelse return error.ClassCreateFailed;
    defer JSClassRelease(class);
    const object = JSObjectMake(ctx_a, class, null) orelse return error.ObjectCreateFailed;
    const name = JSStringCreateWithUTF8CString("foreign") orelse return error.StringInitFailed;
    defer JSStringRelease(name);

    State.mode = .foreign_return;
    var exception: JSValueRef = null;
    try std.testing.expect(JSObjectGetProperty(ctx_a, object, name, &exception) == null);
    try std.testing.expect(valueFromContext(context_a, exception) != null);
    exception = null;
    try std.testing.expect(JSObjectCallAsFunction(ctx_a, object, null, 0, null, &exception) == null);
    try std.testing.expect(valueFromContext(context_a, exception) != null);
    exception = null;
    try std.testing.expect(JSObjectCallAsConstructor(ctx_a, object, 0, null, &exception) == null);
    try std.testing.expect(valueFromContext(context_a, exception) != null);
    exception = null;
    try std.testing.expect(std.math.isNan(JSValueToNumber(ctx_a, object, &exception)));
    try std.testing.expect(valueFromContext(context_a, exception) != null);

    State.mode = .foreign_exception;
    exception = null;
    try std.testing.expect(JSObjectGetProperty(ctx_a, object, name, &exception) == null);
    try std.testing.expect(valueFromContext(context_a, exception) != null);
    try std.testing.expect(exception != State.foreign_value);

    State.mode = .invalid_return;
    exception = null;
    try std.testing.expect(JSObjectCallAsFunction(ctx_a, object, null, 0, null, &exception) == null);
    try std.testing.expect(valueFromContext(context_a, exception) != null);
    exception = null;
    try std.testing.expect(JSObjectCallAsConstructor(ctx_a, object, 0, null, &exception) == null);
    try std.testing.expect(valueFromContext(context_a, exception) != null);
    exception = null;
    try std.testing.expect(std.math.isNan(JSValueToNumber(ctx_a, object, &exception)));
    try std.testing.expect(valueFromContext(context_a, exception) != null);
}

test "C-API: owned TypedArrays expose their public type, geometry, buffer, and bytes" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const typed = JSObjectMakeTypedArray(ctx, .int16_array, 4, &exception) orelse return error.TypedArrayCreateFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(JSTypedArrayType.int16_array, JSValueGetTypedArrayType(ctx, typed, &exception));
    try std.testing.expectEqual(@as(usize, 4), JSObjectGetTypedArrayLength(ctx, typed, &exception));
    try std.testing.expectEqual(@as(usize, 8), JSObjectGetTypedArrayByteLength(ctx, typed, &exception));
    try std.testing.expectEqual(@as(usize, 0), JSObjectGetTypedArrayByteOffset(ctx, typed, &exception));
    try std.testing.expect(exception == null);

    const raw = JSObjectGetTypedArrayBytesPtr(ctx, typed, &exception) orelse return error.TypedArrayBytesFailed;
    const numbers: [*]i16 = @ptrCast(@alignCast(raw));
    numbers[1] = 1234;
    const element = JSObjectGetPropertyAtIndex(ctx, typed, 1, &exception) orelse return error.TypedArrayReadFailed;
    try std.testing.expectEqual(@as(f64, 1234), JSValueToNumber(ctx, element, &exception));

    const buffer = JSObjectGetTypedArrayBuffer(ctx, typed, &exception) orelse return error.ArrayBufferFailed;
    try std.testing.expectEqual(JSTypedArrayType.array_buffer, JSValueGetTypedArrayType(ctx, buffer, &exception));
    try std.testing.expectEqual(@as(usize, 8), JSObjectGetArrayBufferByteLength(ctx, buffer, &exception));
    const buffer_raw = JSObjectGetArrayBufferBytesPtr(ctx, buffer, &exception) orelse return error.ArrayBufferBytesFailed;
    try std.testing.expectEqual(@intFromPtr(raw), @intFromPtr(buffer_raw));
    try std.testing.expect(exception == null);

    const plain = JSObjectMake(ctx, null, null) orelse return error.ObjectCreateFailed;
    try std.testing.expectEqual(JSTypedArrayType.none, JSValueGetTypedArrayType(ctx, plain, &exception));
    try std.testing.expect(JSObjectGetTypedArrayBytesPtr(ctx, plain, &exception) == null);
    try std.testing.expectEqual(@as(usize, 0), JSObjectGetTypedArrayLength(ctx, plain, &exception));
    try std.testing.expect(JSObjectGetArrayBufferBytesPtr(ctx, plain, &exception) == null);
    try std.testing.expectEqual(@as(usize, 0), JSObjectGetArrayBufferByteLength(ctx, plain, &exception));
    try std.testing.expect(exception == null);
}

test "C-API: TypedArray ArrayBuffer views preserve offsets and reject invalid geometry" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const bytes = JSObjectMakeTypedArray(ctx, .uint8_array, 12, &exception) orelse return error.TypedArrayCreateFailed;
    const buffer = JSObjectGetTypedArrayBuffer(ctx, bytes, &exception) orelse return error.ArrayBufferFailed;
    const view = JSObjectMakeTypedArrayWithArrayBufferAndOffset(ctx, .uint32_array, buffer, 4, 2, &exception) orelse return error.TypedArrayViewFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(usize, 2), JSObjectGetTypedArrayLength(ctx, view, &exception));
    try std.testing.expectEqual(@as(usize, 8), JSObjectGetTypedArrayByteLength(ctx, view, &exception));
    try std.testing.expectEqual(@as(usize, 4), JSObjectGetTypedArrayByteOffset(ctx, view, &exception));

    const buffer_raw = JSObjectGetArrayBufferBytesPtr(ctx, buffer, &exception) orelse return error.ArrayBufferBytesFailed;
    const view_raw = JSObjectGetTypedArrayBytesPtr(ctx, view, &exception) orelse return error.TypedArrayBytesFailed;
    try std.testing.expectEqual(@intFromPtr(buffer_raw) + 4, @intFromPtr(view_raw));

    const whole = JSObjectMakeTypedArrayWithArrayBuffer(ctx, .uint16_array, buffer, &exception) orelse return error.TypedArrayViewFailed;
    try std.testing.expectEqual(@as(usize, 6), JSObjectGetTypedArrayLength(ctx, whole, &exception));
    try std.testing.expect(exception == null);

    try std.testing.expect(JSObjectMakeTypedArray(ctx, .none, 1, &exception) == null);
    try std.testing.expect(JSObjectMakeTypedArray(ctx, .array_buffer, 1, &exception) == null);
    try std.testing.expect(JSObjectMakeTypedArray(ctx, @enumFromInt(99), 1, &exception) == null);
    try std.testing.expect(exception == null);

    try std.testing.expect(JSObjectMakeTypedArrayWithArrayBufferAndOffset(ctx, .uint32_array, buffer, 2, 1, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: TypedArray accessors reject detached and cross-context buffers" {
    const ctx_a = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx_a);
    const ctx_b = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx_b);

    var exception: JSValueRef = null;
    const typed = JSObjectMakeTypedArray(ctx_a, .uint8_array, 8, &exception) orelse return error.TypedArrayCreateFailed;
    const buffer = JSObjectGetTypedArrayBuffer(ctx_a, typed, &exception) orelse return error.ArrayBufferFailed;

    try std.testing.expect(JSObjectMakeTypedArrayWithArrayBuffer(ctx_b, .uint8_array, buffer, &exception) == null);
    try std.testing.expect(exception != null);

    const typed_value = valueFromContext(ctxRawFrom(ctx_a).?, typed) orelse return error.InvalidHandle;
    typed_value.asObj().typedArray().?.buffer.arrayBuffer().?.setDetached(true);

    exception = null;
    try std.testing.expectEqual(@as(usize, 0), JSObjectGetTypedArrayLength(ctx_a, typed, &exception));
    try std.testing.expect(exception != null);
    exception = null;
    try std.testing.expect(JSObjectGetTypedArrayBytesPtr(ctx_a, typed, &exception) == null);
    try std.testing.expect(exception != null);
    exception = null;
    try std.testing.expectEqual(@as(usize, 0), JSObjectGetArrayBufferByteLength(ctx_a, buffer, &exception));
    try std.testing.expect(exception != null);
}

test "C-API: no-copy TypedArray and ArrayBuffer preserve bytes and deallocate exactly once" {
    const Deallocator = struct {
        fn call(bytes: ?*anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
            _ = bytes;
            const calls: *usize = @ptrCast(@alignCast(deallocator_context.?));
            calls.* += 1;
        }
    };

    var typed_calls: usize = 0;
    var typed_bytes = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 };
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    var exception: JSValueRef = null;
    const typed = JSObjectMakeTypedArrayWithBytesNoCopy(
        ctx,
        .uint16_array,
        &typed_bytes,
        typed_bytes.len,
        Deallocator.call,
        &typed_calls,
        &exception,
    ) orelse return error.TypedArrayCreateFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(usize, 4), JSObjectGetTypedArrayLength(ctx, typed, &exception));
    const raw = JSObjectGetTypedArrayBytesPtr(ctx, typed, &exception) orelse return error.TypedArrayBytesFailed;
    try std.testing.expectEqual(@intFromPtr(&typed_bytes), @intFromPtr(raw));
    @as([*]u8, @ptrCast(raw))[0] = 9;
    try std.testing.expectEqual(@as(u8, 9), typed_bytes[0]);
    try std.testing.expectEqual(@as(usize, 0), typed_calls);
    JSGlobalContextRelease(ctx);
    try std.testing.expectEqual(@as(usize, 1), typed_calls);

    var buffer_calls: usize = 0;
    var buffer_bytes = [_]u8{ 5, 6, 7 };
    const buffer_ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    const buffer = JSObjectMakeArrayBufferWithBytesNoCopy(
        buffer_ctx,
        &buffer_bytes,
        buffer_bytes.len,
        Deallocator.call,
        &buffer_calls,
        &exception,
    ) orelse return error.ArrayBufferCreateFailed;
    try std.testing.expectEqual(@as(usize, 3), JSObjectGetArrayBufferByteLength(buffer_ctx, buffer, &exception));
    const buffer_raw = JSObjectGetArrayBufferBytesPtr(buffer_ctx, buffer, &exception) orelse return error.ArrayBufferBytesFailed;
    try std.testing.expectEqual(@intFromPtr(&buffer_bytes), @intFromPtr(buffer_raw));
    JSGlobalContextRelease(buffer_ctx);
    try std.testing.expectEqual(@as(usize, 1), buffer_calls);
}

test "C-API: no-copy constructors release transferred bytes immediately on failure" {
    const Deallocator = struct {
        fn call(bytes: ?*anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
            _ = bytes;
            const calls: *usize = @ptrCast(@alignCast(deallocator_context.?));
            calls.* += 1;
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    var bytes = [_]u8{ 1, 2, 3 };
    var calls: usize = 0;
    var exception: JSValueRef = null;

    try std.testing.expect(JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .uint16_array, &bytes, bytes.len, Deallocator.call, &calls, &exception) == null);
    try std.testing.expect(exception != null);
    try std.testing.expectEqual(@as(usize, 1), calls);

    exception = null;
    try std.testing.expect(JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .none, &bytes, bytes.len, Deallocator.call, &calls, &exception) == null);
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(usize, 2), calls);

    try std.testing.expect(JSObjectMakeArrayBufferWithBytesNoCopy(ctx, null, 1, Deallocator.call, &calls, &exception) == null);
    try std.testing.expect(exception != null);
    try std.testing.expectEqual(@as(usize, 3), calls);
}

test "C-API: GC finalization releases no-copy bytes before context teardown" {
    const Deallocator = struct {
        fn call(bytes: ?*anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
            _ = bytes;
            const calls: *usize = @ptrCast(@alignCast(deallocator_context.?));
            calls.* += 1;
        }
    };

    const c = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    c.initCApiRef();
    const ctx: JSContextRef = @ptrCast(c);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var calls: usize = 0;
    var exception: JSValueRef = null;
    _ = JSObjectMakeArrayBufferWithBytesNoCopy(ctx, &bytes, bytes.len, Deallocator.call, &calls, &exception) orelse return error.ArrayBufferCreateFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(usize, 0), calls);

    JSGarbageCollect(ctx);
    try std.testing.expectEqual(@as(usize, 1), calls);
    JSGlobalContextRelease(ctx);
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "C-API: JSValueIsEqual uses JavaScript abstract equality semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const object_script = JSStringCreateWithUTF8CString(
        \\var cApiEqCount = 0;
        \\({
        \\  valueOf() { cApiEqCount += 1; return 7; }
        \\});
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(object_script);
    const object_value = JSEvaluateScript(ctx, object_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    try std.testing.expect(JSValueIsEqual(ctx, object_value, JSValueMakeNumber(ctx, 7), &exception));
    try std.testing.expect(exception == null);

    const count_script = JSStringCreateWithUTF8CString("cApiEqCount") orelse return error.StringInitFailed;
    defer JSStringRelease(count_script);
    const count = JSEvaluateScript(ctx, count_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 1), JSValueToNumber(ctx, count, null));

    const throwing_script = JSStringCreateWithUTF8CString("({ valueOf() { throw new TypeError('eq boom'); } })") orelse return error.StringInitFailed;
    defer JSStringRelease(throwing_script);
    const throwing_value = JSEvaluateScript(ctx, throwing_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    exception = null;
    try std.testing.expect(!JSValueIsEqual(ctx, throwing_value, JSValueMakeNumber(ctx, 1), &exception));
    try std.testing.expect(exception != null);
}

test "C-API: JSValueToNumber uses JavaScript ToNumber semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, JSValueMakeNumber(ctx, 42), &exception));
    try std.testing.expect(exception == null);

    const object_script = JSStringCreateWithUTF8CString("({ valueOf() { return 7 * 6; } })") orelse return error.StringInitFailed;
    defer JSStringRelease(object_script);
    const object_value = JSEvaluateScript(ctx, object_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, object_value, &exception));
    try std.testing.expect(exception == null);

    const throwing_script = JSStringCreateWithUTF8CString("({ valueOf() { throw new TypeError('nope'); } })") orelse return error.StringInitFailed;
    defer JSStringRelease(throwing_script);
    const throwing_value = JSEvaluateScript(ctx, throwing_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    const throwing_number = JSValueToNumber(ctx, throwing_value, &exception);
    try std.testing.expect(std.math.isNan(throwing_number));
    try std.testing.expect(exception != null);

    exception = null;
    const symbol_script = JSStringCreateWithUTF8CString("Symbol('x')") orelse return error.StringInitFailed;
    defer JSStringRelease(symbol_script);
    const symbol_value = JSEvaluateScript(ctx, symbol_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    const symbol_number = JSValueToNumber(ctx, symbol_value, &exception);
    try std.testing.expect(std.math.isNan(symbol_number));
    try std.testing.expect(exception != null);
}

test "C-API: JSValueToStringCopy uses JavaScript ToString semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const object_script = JSStringCreateWithUTF8CString("({ toString() { return 'zig'; } })") orelse return error.StringInitFailed;
    defer JSStringRelease(object_script);
    const object_value = JSEvaluateScript(ctx, object_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    const object_string = JSValueToStringCopy(ctx, object_value, &exception) orelse return error.ToStringFailed;
    defer JSStringRelease(object_string);
    try std.testing.expect(exception == null);
    var object_buf: [8]u8 = undefined;
    const object_written = JSStringGetUTF8CString(object_string, &object_buf, object_buf.len);
    try std.testing.expectEqualStrings("zig", object_buf[0 .. object_written - 1]);

    const throwing_script = JSStringCreateWithUTF8CString("({ toString() { throw new TypeError('nope'); } })") orelse return error.StringInitFailed;
    defer JSStringRelease(throwing_script);
    const throwing_value = JSEvaluateScript(ctx, throwing_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToStringCopy(ctx, throwing_value, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    const symbol_script = JSStringCreateWithUTF8CString("Symbol('x')") orelse return error.StringInitFailed;
    defer JSStringRelease(symbol_script);
    const symbol_value = JSEvaluateScript(ctx, symbol_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToStringCopy(ctx, symbol_value, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSValueIsDate reports Date internal slot" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const date_script = JSStringCreateWithUTF8CString("new Date(0)") orelse return error.StringInitFailed;
    defer JSStringRelease(date_script);
    const date = JSEvaluateScript(ctx, date_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsDate(ctx, date));

    const invalid_date_script = JSStringCreateWithUTF8CString("new Date(NaN)") orelse return error.StringInitFailed;
    defer JSStringRelease(invalid_date_script);
    const invalid_date = JSEvaluateScript(ctx, invalid_date_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsDate(ctx, invalid_date));

    const callable_date_script = JSStringCreateWithUTF8CString("Date()") orelse return error.StringInitFailed;
    defer JSStringRelease(callable_date_script);
    const callable_date = JSEvaluateScript(ctx, callable_date_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(!JSValueIsDate(ctx, callable_date));

    const plain = JSObjectMake(ctx, null, null);
    try std.testing.expect(!JSValueIsDate(ctx, plain));
}

test "C-API: ZJSGlobalContextCreateThreaded(parallel) evaluates JS + exposes Thread" {
    const ctx = ZJSGlobalContextCreateThreaded(false) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const script = JSStringCreateWithUTF8CString("let s = 0; for (let i = 0; i < 50; i++) s += i; s") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 1225), JSValueToNumber(ctx, result, null));
    // The threaded context exposes the Thread constructor.
    const probe = JSStringCreateWithUTF8CString("typeof Thread === 'function'") orelse return error.StringInitFailed;
    defer JSStringRelease(probe);
    const tv = JSEvaluateScript(ctx, probe, null, null, 0, null) orelse return error.EvalFailed;
    try std.testing.expect(JSValueToBoolean(ctx, tv));
}

test "C-API: ZJSGlobalContextCreateThreaded(serialized) evaluates JS + exposes Thread" {
    const ctx = ZJSGlobalContextCreateThreaded(true) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const script = JSStringCreateWithUTF8CString("typeof Thread === 'function' && (1 + 2 + 3) === 6") orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    var exception: JSValueRef = null;
    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));
}

test "C-API: object property get/set" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const obj = JSObjectMake(ctx, null, null);
    const key = JSStringCreateWithUTF8CString("answer") orelse return error.StringInitFailed;
    defer JSStringRelease(key);

    JSObjectSetProperty(ctx, obj, key, JSValueMakeNumber(ctx, 42), 0, null);
    const got = JSObjectGetProperty(ctx, obj, key, null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, got, null));
}

test "C-API: property accessors reject null names with exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const obj = JSObjectMake(ctx, null, null);
    var exception: JSValueRef = null;
    try std.testing.expect(JSObjectGetProperty(ctx, obj, null, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    JSObjectSetProperty(ctx, obj, null, JSValueMakeNumber(ctx, 1), 0, &exception);
    try std.testing.expect(exception != null);
}

test "C-API: property accessors reject null objects with exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const key = JSStringCreateWithUTF8CString("missing") orelse return error.StringInitFailed;
    defer JSStringRelease(key);

    var exception: JSValueRef = null;
    try std.testing.expect(JSObjectGetProperty(ctx, null, key, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    JSObjectSetProperty(ctx, null, key, JSValueMakeNumber(ctx, 1), 0, &exception);
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSObjectGetPropertyAtIndex(ctx, null, 0, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: value write APIs reject null value refs with exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const obj = JSObjectMake(ctx, null, null) orelse return error.ObjectCreateFailed;
    const key = JSStringCreateWithUTF8CString("missingValue") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    var exception: JSValueRef = null;

    JSObjectSetProperty(ctx, obj, key, null, 0, &exception);
    try std.testing.expect(exception != null);

    const src = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = () => {};",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(src);

    const w = JSWorkerCreate(src) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(w);

    exception = null;
    try std.testing.expect(!JSWorkerPostMessage(w, ctx, null, &exception));
    try std.testing.expect(exception != null);
}

test "C-API: JSObjectGetProperty uses JavaScript get semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const script = JSStringCreateWithUTF8CString(
        \\var cApiGetCount = 0;
        \\var cApiProto = { inherited: 42 };
        \\var cApiObj = Object.create(cApiProto);
        \\Object.defineProperty(cApiObj, "accessed", {
        \\  get() { cApiGetCount += 1; return this.inherited + 1; }
        \\});
        \\Object.defineProperty(cApiObj, "boom", {
        \\  get() { throw new TypeError("boom"); }
        \\});
        \\cApiObj;
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    const obj = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const inherited_key = JSStringCreateWithUTF8CString("inherited") orelse return error.StringInitFailed;
    defer JSStringRelease(inherited_key);
    const inherited = JSObjectGetProperty(ctx, obj, inherited_key, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, inherited, null));

    const accessed_key = JSStringCreateWithUTF8CString("accessed") orelse return error.StringInitFailed;
    defer JSStringRelease(accessed_key);
    const accessed = JSObjectGetProperty(ctx, obj, accessed_key, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 43), JSValueToNumber(ctx, accessed, null));

    const count_script = JSStringCreateWithUTF8CString("cApiGetCount") orelse return error.StringInitFailed;
    defer JSStringRelease(count_script);
    const count = JSEvaluateScript(ctx, count_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 1), JSValueToNumber(ctx, count, null));

    const boom_key = JSStringCreateWithUTF8CString("boom") orelse return error.StringInitFailed;
    defer JSStringRelease(boom_key);
    exception = null;
    const failed = JSObjectGetProperty(ctx, obj, boom_key, &exception);
    try std.testing.expect(failed == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSObject private data is host-owned and guarded" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var first: u8 = 1;
    var second: u8 = 2;
    var engine_probe: u8 = 3;
    const first_ptr: *anyopaque = @ptrCast(&first);
    const second_ptr: *anyopaque = @ptrCast(&second);
    const engine_probe_ptr: *anyopaque = @ptrCast(&engine_probe);

    const obj = JSObjectMake(ctx, null, first_ptr);
    try std.testing.expectEqual(@intFromPtr(first_ptr), @intFromPtr(JSObjectGetPrivate(obj).?));
    try std.testing.expect(JSObjectSetPrivate(obj, second_ptr));
    try std.testing.expectEqual(@intFromPtr(second_ptr), @intFromPtr(JSObjectGetPrivate(obj).?));
    try std.testing.expect(JSObjectSetPrivate(obj, null));
    try std.testing.expect(JSObjectGetPrivate(obj) == null);

    const global = JSContextGetGlobalObject(ctx);
    const date_name = JSStringCreateWithUTF8CString("Date") orelse return error.StringInitFailed;
    defer JSStringRelease(date_name);
    const date_ctor = JSObjectGetProperty(ctx, global, date_name, null) orelse return error.PropFailed;
    try std.testing.expect(JSObjectGetPrivate(date_ctor) == null);
    try std.testing.expect(!JSObjectSetPrivate(date_ctor, engine_probe_ptr));
    try std.testing.expect(JSObjectGetPrivate(date_ctor) == null);
}

test "C-API: JSObjectMake creates ordinary realm objects" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const obj = JSObjectMake(ctx, null, null);
    const global = JSContextGetGlobalObject(ctx);
    const name = JSStringCreateWithUTF8CString("cApiObject") orelse return error.StringInitFailed;
    defer JSStringRelease(name);
    JSObjectSetProperty(ctx, global, name, obj, 0, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString(
        \\Object.getPrototypeOf(cApiObject) === Object.prototype &&
        \\cApiObject.toString() === "[object Object]" &&
        \\typeof cApiObject.hasOwnProperty === "function"
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));
}

test "C-API: JSValueToObject uses JavaScript ToObject semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const num_obj = JSValueToObject(ctx, JSValueMakeNumber(ctx, 7), &exception) orelse return error.ObjectCreateFailed;
    try std.testing.expect(exception == null);
    const bool_obj = JSValueToObject(ctx, JSValueMakeBoolean(ctx, true), &exception) orelse return error.ObjectCreateFailed;
    try std.testing.expect(exception == null);
    const str_ref = JSStringCreateWithUTF8CString("zig") orelse return error.StringInitFailed;
    defer JSStringRelease(str_ref);
    const str_obj = JSValueToObject(ctx, JSValueMakeString(ctx, str_ref), &exception) orelse return error.ObjectCreateFailed;
    try std.testing.expect(exception == null);
    const symbol_script = JSStringCreateWithUTF8CString("Symbol('boxed')") orelse return error.StringInitFailed;
    defer JSStringRelease(symbol_script);
    const symbol_prim = JSEvaluateScript(ctx, symbol_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    const symbol_obj = JSValueToObject(ctx, symbol_prim, &exception) orelse return error.ObjectCreateFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsObject(ctx, symbol_obj));
    const bigint_script = JSStringCreateWithUTF8CString("1n") orelse return error.StringInitFailed;
    defer JSStringRelease(bigint_script);
    const bigint_prim = JSEvaluateScript(ctx, bigint_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    const bigint_obj = JSValueToObject(ctx, bigint_prim, &exception) orelse return error.ObjectCreateFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsObject(ctx, bigint_obj));

    const global = JSContextGetGlobalObject(ctx);
    const num_name = JSStringCreateWithUTF8CString("boxedNumber") orelse return error.StringInitFailed;
    defer JSStringRelease(num_name);
    const bool_name = JSStringCreateWithUTF8CString("boxedBoolean") orelse return error.StringInitFailed;
    defer JSStringRelease(bool_name);
    const str_name = JSStringCreateWithUTF8CString("boxedString") orelse return error.StringInitFailed;
    defer JSStringRelease(str_name);
    const symbol_name = JSStringCreateWithUTF8CString("boxedSymbol") orelse return error.StringInitFailed;
    defer JSStringRelease(symbol_name);
    const bigint_name = JSStringCreateWithUTF8CString("boxedBigInt") orelse return error.StringInitFailed;
    defer JSStringRelease(bigint_name);
    JSObjectSetProperty(ctx, global, num_name, num_obj, kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);
    JSObjectSetProperty(ctx, global, bool_name, bool_obj, kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);
    JSObjectSetProperty(ctx, global, str_name, str_obj, kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);
    JSObjectSetProperty(ctx, global, symbol_name, symbol_obj, kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);
    JSObjectSetProperty(ctx, global, bigint_name, bigint_obj, kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString(
        \\boxedNumber.valueOf() === 7 &&
        \\Object.prototype.toString.call(boxedNumber) === "[object Number]" &&
        \\boxedBoolean.valueOf() === true &&
        \\Object.prototype.toString.call(boxedBoolean) === "[object Boolean]" &&
        \\boxedString.valueOf() === "zig" &&
        \\Object.prototype.toString.call(boxedString) === "[object String]" &&
        \\typeof boxedSymbol.valueOf() === "symbol" &&
        \\Object.prototype.toString.call(boxedSymbol) === "[object Symbol]" &&
        \\boxedBigInt.valueOf() === 1n &&
        \\Object.prototype.toString.call(boxedBigInt) === "[object BigInt]"
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));

    const obj = JSObjectMake(ctx, null, null);
    try std.testing.expect(JSValueIsStrictEqual(ctx, obj, JSValueToObject(ctx, obj, &exception)));
    try std.testing.expect(exception == null);

    exception = null;
    try std.testing.expect(JSValueToObject(ctx, JSValueMakeNull(ctx), &exception) == null);
    try std.testing.expect(exception != null);
    exception = null;
    try std.testing.expect(JSValueToObject(ctx, JSValueMakeUndefined(ctx), &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: value coercion APIs reject null value refs with exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const undefined_value = JSValueMakeUndefined(ctx) orelse return error.ValueInitFailed;
    var exception: JSValueRef = null;

    try std.testing.expect(!JSValueIsEqual(ctx, null, undefined_value, &exception));
    try std.testing.expect(exception != null);

    exception = null;
    const number = JSValueToNumber(ctx, null, &exception);
    try std.testing.expect(std.math.isNan(number));
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSValueToStringCopy(ctx, null, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSValueToObject(ctx, null, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSEvaluateScript honors explicit thisObject" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const global_probe = JSStringCreateWithUTF8CString("this === globalThis") orelse return error.StringInitFailed;
    defer JSStringRelease(global_probe);
    const global_result = JSEvaluateScript(ctx, global_probe, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, global_result));

    const obj = JSObjectMake(ctx, null, null);
    const key = JSStringCreateWithUTF8CString("answer") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    JSObjectSetProperty(ctx, obj, key, JSValueMakeNumber(ctx, 42), kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString("this.answer") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const result = JSEvaluateScript(ctx, script, obj, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, &exception));
    try std.testing.expect(exception == null);
}

test "C-API: evaluation syntax exceptions include source URL and line" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const script = JSStringCreateWithUTF8CString("let ok = 1;\nlet bad = ;") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const url = JSStringCreateWithUTF8CString("app.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);

    var exception: JSValueRef = null;
    try std.testing.expect(JSEvaluateScript(ctx, script, null, url, 40, &exception) == null);
    try std.testing.expect(exception != null);

    const msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(msg);
    var buf: [128]u8 = undefined;
    const written = JSStringGetUTF8CString(msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "app.js:41:12") != null);

    var prop_exception: JSValueRef = null;
    const source_key = JSStringCreateWithUTF8CString("sourceURL") orelse return error.StringInitFailed;
    defer JSStringRelease(source_key);
    const line_key = JSStringCreateWithUTF8CString("line") orelse return error.StringInitFailed;
    defer JSStringRelease(line_key);
    const column_key = JSStringCreateWithUTF8CString("column") orelse return error.StringInitFailed;
    defer JSStringRelease(column_key);
    const byte_offset_key = JSStringCreateWithUTF8CString("byteOffset") orelse return error.StringInitFailed;
    defer JSStringRelease(byte_offset_key);

    const source_value = JSObjectGetProperty(ctx, exception, source_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    const source_out = JSValueToStringCopy(ctx, source_value, null) orelse return error.StringInitFailed;
    defer JSStringRelease(source_out);
    var source_buf: [64]u8 = undefined;
    const source_written = JSStringGetUTF8CString(source_out, &source_buf, source_buf.len);
    try std.testing.expectEqualStrings("app.js", source_buf[0 .. source_written - 1]);

    const line_value = JSObjectGetProperty(ctx, exception, line_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    try std.testing.expectEqual(@as(f64, 41), JSValueToNumber(ctx, line_value, null));

    const column_value = JSObjectGetProperty(ctx, exception, column_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    try std.testing.expectEqual(@as(f64, 12), JSValueToNumber(ctx, column_value, null));

    const byte_offset_value = JSObjectGetProperty(ctx, exception, byte_offset_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    try std.testing.expect(JSValueIsNumber(ctx, byte_offset_value));

    const lex_script = JSStringCreateWithUTF8CString("let ok = 1;\n'") orelse return error.StringInitFailed;
    defer JSStringRelease(lex_script);
    exception = null;
    try std.testing.expect(JSEvaluateScript(ctx, lex_script, null, url, 40, &exception) == null);
    try std.testing.expect(exception != null);

    const lex_msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(lex_msg);
    var lex_buf: [128]u8 = undefined;
    const lex_written = JSStringGetUTF8CString(lex_msg, &lex_buf, lex_buf.len);
    try std.testing.expect(std.mem.indexOf(u8, lex_buf[0 .. lex_written - 1], "app.js:41:2") != null);
}

test "C-API: syntax checking shares diagnostics and never executes" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const url = JSStringCreateWithUTF8CString("syntax.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);

    const valid = JSStringCreateWithUTF8CString("globalThis.syntaxSideEffect = 1;") orelse return error.StringInitFailed;
    defer JSStringRelease(valid);
    var exception: JSValueRef = null;
    try std.testing.expect(JSCheckScriptSyntax(ctx, valid, url, 20, &exception));
    try std.testing.expect(exception == null);

    const probe = JSStringCreateWithUTF8CString("typeof globalThis.syntaxSideEffect === 'undefined'") orelse return error.StringInitFailed;
    defer JSStringRelease(probe);
    const result = JSEvaluateScript(ctx, probe, null, null, 1, &exception) orelse return error.EvalFailed;
    try std.testing.expect(JSValueToBoolean(ctx, result));

    const invalid = JSStringCreateWithUTF8CString("let x = ;") orelse return error.StringInitFailed;
    defer JSStringRelease(invalid);
    try std.testing.expect(!JSCheckScriptSyntax(ctx, invalid, url, 20, &exception));
    try std.testing.expect(exception != null);
    const check_message = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(check_message);

    var eval_exception: JSValueRef = null;
    try std.testing.expect(JSEvaluateScript(ctx, invalid, null, url, 20, &eval_exception) == null);
    try std.testing.expect(eval_exception != null);
    const eval_message = JSValueToStringCopy(ctx, eval_exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(eval_message);
    try std.testing.expect(JSStringIsEqual(check_message, eval_message));
}

test "C-API: global context metadata copies exact UTF-16 ownership" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    try std.testing.expect(JSContextGetGlobalContext(ctx) == ctx);
    try std.testing.expect(JSContextGetGlobalContext(null) == null);
    try std.testing.expect(JSGlobalContextCopyName(ctx) == null);

    const units = [_]u16{ 'v', 'm', 0, 0xD800 };
    const name = JSStringCreateWithCharacters(&units, units.len) orelse return error.StringInitFailed;
    JSGlobalContextSetName(ctx, name);
    JSStringRelease(name);

    const copied = JSGlobalContextCopyName(ctx) orelse return error.StringInitFailed;
    defer JSStringRelease(copied);
    try std.testing.expectEqualSlices(u16, &units, JSStringGetCharactersPtr(copied)[0..units.len]);

    JSGlobalContextSetName(ctx, null);
    try std.testing.expect(JSGlobalContextCopyName(ctx) == null);
}

test "C-API: evaluation runtime errors include source metadata" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const script = JSStringCreateWithUTF8CString("throw new Error('boom')") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const url = JSStringCreateWithUTF8CString("runtime.js") orelse return error.StringInitFailed;
    defer JSStringRelease(url);

    var exception: JSValueRef = null;
    try std.testing.expect(JSEvaluateScript(ctx, script, null, url, 99, &exception) == null);
    try std.testing.expect(exception != null);

    var prop_exception: JSValueRef = null;
    const source_key = JSStringCreateWithUTF8CString("sourceURL") orelse return error.StringInitFailed;
    defer JSStringRelease(source_key);
    const starting_line_key = JSStringCreateWithUTF8CString("startingLineNumber") orelse return error.StringInitFailed;
    defer JSStringRelease(starting_line_key);
    const stack_key = JSStringCreateWithUTF8CString("stack") orelse return error.StringInitFailed;
    defer JSStringRelease(stack_key);

    const source_value = JSObjectGetProperty(ctx, exception, source_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    const source_out = JSValueToStringCopy(ctx, source_value, null) orelse return error.StringInitFailed;
    defer JSStringRelease(source_out);
    var source_buf: [64]u8 = undefined;
    const source_written = JSStringGetUTF8CString(source_out, &source_buf, source_buf.len);
    try std.testing.expectEqualStrings("runtime.js", source_buf[0 .. source_written - 1]);

    const starting_line_value = JSObjectGetProperty(ctx, exception, starting_line_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    try std.testing.expectEqual(@as(f64, 99), JSValueToNumber(ctx, starting_line_value, null));

    const stack_value = JSObjectGetProperty(ctx, exception, stack_key, &prop_exception) orelse return error.PropFailed;
    try std.testing.expect(prop_exception == null);
    const stack_out = JSValueToStringCopy(ctx, stack_value, null) orelse return error.StringInitFailed;
    defer JSStringRelease(stack_out);
    var stack_buf: [160]u8 = undefined;
    const stack_written = JSStringGetUTF8CString(stack_out, &stack_buf, stack_buf.len);
    try std.testing.expect(std.mem.indexOf(u8, stack_buf[0 .. stack_written - 1], "runtime.js:99") != null);
}

test "C-API: JSObjectSetProperty honors property attributes" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const obj = JSObjectMake(ctx, null, null);
    const key = JSStringCreateWithUTF8CString("locked") orelse return error.StringInitFailed;
    defer JSStringRelease(key);

    var exception: JSValueRef = null;
    JSObjectSetProperty(
        ctx,
        obj,
        key,
        JSValueMakeNumber(ctx, 7),
        kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete,
        &exception,
    );
    try std.testing.expect(exception == null);

    const global = JSContextGetGlobalObject(ctx);
    const target_name = JSStringCreateWithUTF8CString("attrTarget") orelse return error.StringInitFailed;
    defer JSStringRelease(target_name);
    JSObjectSetProperty(ctx, global, target_name, obj, kJSPropertyAttributeNone, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString(
        \\var d = Object.getOwnPropertyDescriptor(attrTarget, "locked");
        \\var before = attrTarget.locked;
        \\attrTarget.locked = 9;
        \\var del = delete attrTarget.locked;
        \\before === 7 &&
        \\attrTarget.locked === 7 &&
        \\del === false &&
        \\Object.prototype.hasOwnProperty.call(attrTarget, "locked") &&
        \\Object.keys(attrTarget).indexOf("locked") === -1 &&
        \\d.value === 7 &&
        \\d.writable === false &&
        \\d.enumerable === false &&
        \\d.configurable === false
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));
}

fn namedHostCallback(ctx: JSContextRef, function: JSObjectRef, this_object: JSObjectRef, argument_count: usize, arguments: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    _ = function;
    _ = this_object;
    _ = argument_count;
    _ = arguments;
    _ = exception;
    return JSValueMakeNumber(ctx, 42);
}

fn nullHostCallback(ctx: JSContextRef, function: JSObjectRef, this_object: JSObjectRef, argument_count: usize, arguments: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    _ = ctx;
    _ = function;
    _ = this_object;
    _ = argument_count;
    _ = arguments;
    _ = exception;
    return null;
}

test "C-API: callback functions honor name and Function prototype" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const fn_name = JSStringCreateWithUTF8CString("hostAnswer") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_name);
    const fn_obj = JSObjectMakeFunctionWithCallback(ctx, fn_name, namedHostCallback) orelse return error.FunctionCreateFailed;
    try std.testing.expect(JSObjectIsFunction(ctx, fn_obj));

    var exception: JSValueRef = null;
    const global = JSContextGetGlobalObject(ctx);
    JSObjectSetProperty(ctx, global, fn_name, fn_obj, 0, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString(
        \\var d = Object.getOwnPropertyDescriptor(hostAnswer, "name");
        \\typeof hostAnswer === "function" &&
        \\hostAnswer() === 42 &&
        \\hostAnswer.name === "hostAnswer" &&
        \\d.writable === false &&
        \\d.enumerable === false &&
        \\d.configurable === true &&
        \\Object.getPrototypeOf(hostAnswer) === Function.prototype &&
        \\hostAnswer instanceof Function &&
        \\Function.prototype.toString.call(hostAnswer) === "function hostAnswer() { [native code] }"
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));
}

test "C-API: host callback null result throws without implicit undefined" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const fn_name = JSStringCreateWithUTF8CString("badHostCallback") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_name);
    const fn_obj = JSObjectMakeFunctionWithCallback(ctx, fn_name, nullHostCallback) orelse return error.FunctionCreateFailed;

    var exception: JSValueRef = null;
    try std.testing.expect(JSObjectCallAsFunction(ctx, fn_obj, null, 0, null, &exception) == null);
    try std.testing.expect(exception != null);
    const direct_msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(direct_msg);
    var direct_buf: [128]u8 = undefined;
    const direct_written = JSStringGetUTF8CString(direct_msg, &direct_buf, direct_buf.len);
    try std.testing.expect(std.mem.indexOf(u8, direct_buf[0 .. direct_written - 1], "host callback returned null") != null);

    exception = null;
    const global = JSContextGetGlobalObject(ctx);
    JSObjectSetProperty(ctx, global, fn_name, fn_obj, 0, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString(
        \\try {
        \\  badHostCallback();
        \\  false;
        \\} catch (e) {
        \\  e instanceof TypeError && /host callback returned null/.test(String(e));
        \\}
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));
}

test "C-API: JSObjectMakeFunctionWithCallback rejects null callback" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const fn_name = JSStringCreateWithUTF8CString("missingCallback") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_name);
    try std.testing.expect(JSObjectMakeFunctionWithCallback(ctx, fn_name, null) == null);
}

test "C-API: argc rejects null argv" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    try std.testing.expect(JSObjectMakeArray(ctx, 1, null, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    const fn_name = JSStringCreateWithUTF8CString("hostAnswer") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_name);
    const fn_obj = JSObjectMakeFunctionWithCallback(ctx, fn_name, namedHostCallback) orelse return error.FunctionCreateFailed;
    try std.testing.expect(JSObjectCallAsFunction(ctx, fn_obj, null, 1, null, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    const global = JSContextGetGlobalObject(ctx);
    const date_name = JSStringCreateWithUTF8CString("Date") orelse return error.StringInitFailed;
    defer JSStringRelease(date_name);
    const date_ctor = JSObjectGetProperty(ctx, global, date_name, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSObjectCallAsConstructor(ctx, date_ctor, 1, null, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: argv rejects null value refs" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var args = [_]JSValueRef{null};
    var exception: JSValueRef = null;

    try std.testing.expect(JSObjectMakeArray(ctx, args.len, &args, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    const fn_name = JSStringCreateWithUTF8CString("hostAnswer") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_name);
    const fn_obj = JSObjectMakeFunctionWithCallback(ctx, fn_name, namedHostCallback) orelse return error.FunctionCreateFailed;
    try std.testing.expect(JSObjectCallAsFunction(ctx, fn_obj, null, args.len, &args, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    const global = JSContextGetGlobalObject(ctx);
    const date_name = JSStringCreateWithUTF8CString("Date") orelse return error.StringInitFailed;
    defer JSStringRelease(date_name);
    const date_ctor = JSObjectGetProperty(ctx, global, date_name, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSObjectCallAsConstructor(ctx, date_ctor, args.len, &args, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: argv collection failures report exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const fn_script = JSStringCreateWithUTF8CString("(function(){ return 1; })") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_script);
    const fn_obj = JSEvaluateScript(ctx, fn_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    var dummy = JSValueMakeUndefined(ctx);
    try std.testing.expect(JSObjectMakeArray(ctx, std.math.maxInt(usize), &dummy, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    try std.testing.expect(JSObjectCallAsFunction(ctx, fn_obj, null, std.math.maxInt(usize), &dummy, &exception) == null);
    try std.testing.expect(exception != null);

    exception = null;
    const global = JSContextGetGlobalObject(ctx);
    const date_name = JSStringCreateWithUTF8CString("Date") orelse return error.StringInitFailed;
    defer JSStringRelease(date_name);
    const date_ctor = JSObjectGetProperty(ctx, global, date_name, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);

    try std.testing.expect(JSObjectCallAsConstructor(ctx, date_ctor, std.math.maxInt(usize), &dummy, &exception) == null);
    try std.testing.expect(exception != null);
}

fn thisObjectProbeCallback(ctx: JSContextRef, function: JSObjectRef, this_object: JSObjectRef, argument_count: usize, arguments: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    _ = function;
    _ = argument_count;
    _ = arguments;
    _ = exception;
    return JSValueMakeBoolean(ctx, JSValueIsStrictEqual(ctx, this_object, JSContextGetGlobalObject(ctx)));
}

test "C-API: JSObjectCallAsFunction defaults null thisObject to global object" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const script = JSStringCreateWithUTF8CString("(function () { return this === globalThis; })") orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const func = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const result = JSObjectCallAsFunction(ctx, func, null, 0, null, &exception) orelse return error.CallFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));

    const cb_name = JSStringCreateWithUTF8CString("probeThisObject") orelse return error.StringInitFailed;
    defer JSStringRelease(cb_name);
    const cb = JSObjectMakeFunctionWithCallback(ctx, cb_name, thisObjectProbeCallback) orelse return error.FunctionCreateFailed;
    const cb_result = JSObjectCallAsFunction(ctx, cb, null, 0, null, &exception) orelse return error.CallFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, cb_result));
}

test "C-API: JSObjectIsConstructor recognizes native constructors" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const global = JSContextGetGlobalObject(ctx);
    const date_name = JSStringCreateWithUTF8CString("Date") orelse return error.StringInitFailed;
    defer JSStringRelease(date_name);
    const date_ctor = JSObjectGetProperty(ctx, global, date_name, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSObjectIsFunction(ctx, date_ctor));
    try std.testing.expect(JSObjectIsConstructor(ctx, date_ctor));

    const date_obj = JSObjectCallAsConstructor(ctx, date_ctor, 0, null, &exception) orelse return error.ConstructFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueIsDate(ctx, date_obj));

    const fn_name = JSStringCreateWithUTF8CString("hostAnswer") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_name);
    const fn_obj = JSObjectMakeFunctionWithCallback(ctx, fn_name, namedHostCallback) orelse return error.FunctionCreateFailed;
    try std.testing.expect(JSObjectIsFunction(ctx, fn_obj));
    try std.testing.expect(!JSObjectIsConstructor(ctx, fn_obj));

    const plain = JSObjectMake(ctx, null, null);
    try std.testing.expect(!JSObjectIsFunction(ctx, plain));
    try std.testing.expect(!JSObjectIsConstructor(ctx, plain));
}

test "C-API: JSObjectCallAsConstructor runs JavaScript constructors and reports throws" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    const script = JSStringCreateWithUTF8CString(
        \\var cApiCtorCount = 0;
        \\function CApiCtor(n) { cApiCtorCount += n; this.value = cApiCtorCount; }
        \\CApiCtor;
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const ctor = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    var args = [_]JSValueRef{JSValueMakeNumber(ctx, 5)};
    const instance = JSObjectCallAsConstructor(ctx, ctor, args.len, &args, &exception) orelse return error.ConstructFailed;
    try std.testing.expect(exception == null);

    const value_key = JSStringCreateWithUTF8CString("value") orelse return error.StringInitFailed;
    defer JSStringRelease(value_key);
    const value_prop = JSObjectGetProperty(ctx, instance, value_key, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 5), JSValueToNumber(ctx, value_prop, null));

    const throwing_script = JSStringCreateWithUTF8CString("(function ThrowingCtor() { throw new TypeError('ctor boom'); })") orelse return error.StringInitFailed;
    defer JSStringRelease(throwing_script);
    const throwing_ctor = JSEvaluateScript(ctx, throwing_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    exception = null;
    const failed = JSObjectCallAsConstructor(ctx, throwing_ctor, 0, null, &exception);
    try std.testing.expect(failed == null);
    try std.testing.expect(exception != null);
}

test "C-API: array construction and indexed get use JavaScript get semantics" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    var values = [_]JSValueRef{
        JSValueMakeNumber(ctx, 10),
        JSValueMakeNumber(ctx, 20),
    };
    const arr = JSObjectMakeArray(ctx, values.len, &values, null) orelse return error.ArrayCreateFailed;

    const first = JSObjectGetPropertyAtIndex(ctx, arr, 0, null);
    const second = JSObjectGetPropertyAtIndex(ctx, arr, 1, null);
    const missing = JSObjectGetPropertyAtIndex(ctx, arr, 2, null);
    try std.testing.expectEqual(@as(f64, 10), JSValueToNumber(ctx, first, null));
    try std.testing.expectEqual(@as(f64, 20), JSValueToNumber(ctx, second, null));
    try std.testing.expect(JSValueIsUndefined(ctx, missing));

    const script = JSStringCreateWithUTF8CString(
        \\var cApiIndexGetCount = 0;
        \\var cApiIndexProto = {};
        \\Object.defineProperty(cApiIndexProto, "2", {
        \\  get() { cApiIndexGetCount += 1; return 30; }
        \\});
        \\Object.defineProperty(cApiIndexProto, "3", {
        \\  get() { throw new RangeError("indexed boom"); }
        \\});
        \\Object.create(cApiIndexProto);
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const obj = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const inherited_index = JSObjectGetPropertyAtIndex(ctx, obj, 2, &exception) orelse return error.PropFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 30), JSValueToNumber(ctx, inherited_index, null));

    const count_script = JSStringCreateWithUTF8CString("cApiIndexGetCount") orelse return error.StringInitFailed;
    defer JSStringRelease(count_script);
    const count = JSEvaluateScript(ctx, count_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 1), JSValueToNumber(ctx, count, null));

    exception = null;
    const failed = JSObjectGetPropertyAtIndex(ctx, obj, 3, &exception);
    try std.testing.expect(failed == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSObjectMakeArray inherits Array prototype" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var exception: JSValueRef = null;
    var values = [_]JSValueRef{
        JSValueMakeNumber(ctx, 10),
        JSValueMakeNumber(ctx, 20),
    };
    const arr = JSObjectMakeArray(ctx, values.len, &values, &exception) orelse return error.ArrayCreateFailed;
    try std.testing.expect(exception == null);

    const global = JSContextGetGlobalObject(ctx);
    const name = JSStringCreateWithUTF8CString("cApiArray") orelse return error.StringInitFailed;
    defer JSStringRelease(name);
    JSObjectSetProperty(ctx, global, name, arr, 0, &exception);
    try std.testing.expect(exception == null);

    const script = JSStringCreateWithUTF8CString(
        \\Array.isArray(cApiArray) &&
        \\Object.getPrototypeOf(cApiArray) === Array.prototype &&
        \\cApiArray.join("-") === "10-20" &&
        \\cApiArray.map(function (x) { return x * 2; }).join(",") === "20,40"
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(script);
    const result = JSEvaluateScript(ctx, script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(JSValueToBoolean(ctx, result));
}

test "C-API: JSObjectMakeDeferredPromise resolves and rejects through returned functions" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var resolve: JSObjectRef = null;
    var reject: JSObjectRef = null;
    var exception: JSValueRef = null;
    const deferred = JSObjectMakeDeferredPromise(ctx, &resolve, &reject, &exception) orelse return error.DeferredPromiseFailed;
    try std.testing.expect(exception == null);
    try std.testing.expect(resolve != null);
    try std.testing.expect(reject != null);
    try std.testing.expect(JSObjectIsFunction(ctx, resolve));
    try std.testing.expect(JSObjectIsFunction(ctx, reject));

    const global = JSContextGetGlobalObject(ctx);
    const key = JSStringCreateWithUTF8CString("deferred") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    JSObjectSetProperty(ctx, global, key, deferred, 0, &exception);
    try std.testing.expect(exception == null);

    const observe = JSStringCreateWithUTF8CString(
        \\globalThis.deferredSeen = 0;
        \\deferred.then(v => { globalThis.deferredSeen = v; });
        \\0
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(observe);
    _ = JSEvaluateScript(ctx, observe, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    var resolve_args = [_]JSValueRef{JSValueMakeNumber(ctx, 42)};
    _ = JSObjectCallAsFunction(ctx, resolve, null, resolve_args.len, &resolve_args, &exception) orelse return error.ResolveCallFailed;
    try std.testing.expect(exception == null);

    const drain = JSStringCreateWithUTF8CString("0") orelse return error.StringInitFailed;
    defer JSStringRelease(drain);
    _ = JSEvaluateScript(ctx, drain, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const seen = JSStringCreateWithUTF8CString("globalThis.deferredSeen") orelse return error.StringInitFailed;
    defer JSStringRelease(seen);
    const result = JSEvaluateScript(ctx, seen, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, result, null));

    var reject_args = [_]JSValueRef{JSValueMakeNumber(ctx, 99)};
    _ = JSObjectCallAsFunction(ctx, reject, null, reject_args.len, &reject_args, &exception) orelse return error.RejectCallFailed;
    try std.testing.expect(exception == null);
    _ = JSEvaluateScript(ctx, drain, null, null, 0, &exception) orelse return error.EvalFailed;
    const still_seen = JSEvaluateScript(ctx, seen, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, still_seen, null));
}

test "C-API: JSObjectMakeDeferredPromise requires resolve and reject outputs" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var resolve: JSObjectRef = null;
    var reject: JSObjectRef = null;
    var exception: JSValueRef = null;
    try std.testing.expect(JSObjectMakeDeferredPromise(ctx, null, &reject, &exception) == null);
    try std.testing.expect(exception != null);

    const msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(msg);
    var buf: [128]u8 = undefined;
    const written = JSStringGetUTF8CString(msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "out pointers are required") != null);

    exception = null;
    try std.testing.expect(JSObjectMakeDeferredPromise(ctx, &resolve, null, &exception) == null);
    try std.testing.expect(exception != null);
}

test "C-API: JSObjectMakeDeferredPromise reject function settles the promise" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    var resolve: JSObjectRef = null;
    var reject: JSObjectRef = null;
    var exception: JSValueRef = null;
    const deferred = JSObjectMakeDeferredPromise(ctx, &resolve, &reject, &exception) orelse return error.DeferredPromiseFailed;
    try std.testing.expect(exception == null);

    const global = JSContextGetGlobalObject(ctx);
    const key = JSStringCreateWithUTF8CString("deferredReject") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    JSObjectSetProperty(ctx, global, key, deferred, 0, &exception);

    const observe = JSStringCreateWithUTF8CString(
        \\globalThis.deferredRejected = 0;
        \\deferredReject.catch(e => { globalThis.deferredRejected = e; });
        \\0
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(observe);
    _ = JSEvaluateScript(ctx, observe, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    var reject_args = [_]JSValueRef{JSValueMakeNumber(ctx, 7)};
    _ = JSObjectCallAsFunction(ctx, reject, null, reject_args.len, &reject_args, &exception) orelse return error.RejectCallFailed;
    try std.testing.expect(exception == null);

    const drain = JSStringCreateWithUTF8CString("0") orelse return error.StringInitFailed;
    defer JSStringRelease(drain);
    _ = JSEvaluateScript(ctx, drain, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    const rejected = JSStringCreateWithUTF8CString("globalThis.deferredRejected") orelse return error.StringInitFailed;
    defer JSStringRelease(rejected);
    const result = JSEvaluateScript(ctx, rejected, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);
    try std.testing.expectEqual(@as(f64, 7), JSValueToNumber(ctx, result, null));
}

test "C-API: string value evaluation round-trips through JSValueToStringCopy" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const script = JSStringCreateWithUTF8CString("'craft' + '-' + 'js'") orelse return error.StringInitFailed;
    defer JSStringRelease(script);

    const result = JSEvaluateScript(ctx, script, null, null, 0, null) orelse return error.EvalFailed;
    try std.testing.expect(JSValueIsString(ctx, result));

    const out = JSValueToStringCopy(ctx, result, null) orelse return error.ToStringFailed;
    defer JSStringRelease(out);
    var buf: [32]u8 = undefined;
    const written = JSStringGetUTF8CString(out, &buf, buf.len);
    try std.testing.expectEqualStrings("craft-js", buf[0 .. written - 1]);
}

test "C-API: worker create, post a number, receive the doubled reply" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const src = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = (e) => { postMessage(e.data * 2); close(); };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(src);

    const w = JSWorkerCreate(src) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(w);

    const arg = JSValueMakeNumber(ctx, 21);
    try std.testing.expect(JSWorkerPostMessage(w, ctx, arg, null));

    const reply = JSWorkerReceive(w, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, reply, null));
}

test "C-API: worker inspector target metadata is stable and validated" {
    const src = JSStringCreateWithUTF8CString("") orelse return error.StringInitFailed;
    defer JSStringRelease(src);
    const first = JSWorkerCreate(src) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(first);
    const second = JSWorkerCreate(src) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(second);

    var first_info: ZJSInspectorTargetInfo = undefined;
    var second_info: ZJSInspectorTargetInfo = undefined;
    try std.testing.expect(ZJSWorkerGetInspectorTargetInfo(first, &first_info));
    try std.testing.expect(ZJSWorkerGetInspectorTargetInfo(second, &second_info));
    try std.testing.expect(first_info.id != 0);
    try std.testing.expect(first_info.id != second_info.id);
    try std.testing.expectEqual(ZJSInspectorTargetKind.script, first_info.kind);
    try std.testing.expect(first_info.state == .starting or first_info.state == .running);
    try std.testing.expect(!ZJSWorkerGetInspectorTargetInfo(null, &first_info));
    try std.testing.expect(!ZJSWorkerGetInspectorTargetInfo(first, null));

    JSWorkerTerminate(first);
    try std.testing.expect(ZJSWorkerGetInspectorTargetInfo(first, &first_info));
    try std.testing.expect(first_info.state == .closing or first_info.state == .closed);
}

test "C-API: worker inspector marshals commands and callbacks across threads" {
    const State = struct {
        owner: std.Thread.Id,
        session: ZJSWorkerInspectorSessionRef = null,
        bytes: [8192]u8 = undefined,
        len: usize = 0,
        wrong_thread: bool = false,
        pauses: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (std.Thread.getCurrentId() != self.owner) self.wrong_thread = true;
            const available = self.bytes.len - self.len;
            const copied = @min(available, message_len);
            @memcpy(self.bytes[self.len..][0..copied], message[0..copied]);
            self.len += copied;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") != null) {
                self.pauses += 1;
                const resume_command = "{\"id\":9,\"method\":\"Debugger.resume\"}";
                std.debug.assert(ZJSWorkerInspectorSessionDispatch(self.session, resume_command, resume_command.len));
            }
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const source = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = (e) => { let x = e.data; debugger; x += 2; postMessage(x); close(); };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(worker);

    var state = State{ .owner = std.Thread.getCurrentId() };
    state.session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(state.session);

    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    const schema = "{\"id\":1,\"method\":\"Schema.getDomains\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, schema, schema.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    const enable = "{\"id\":2,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, enable, enable.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));

    try std.testing.expect(JSWorkerPostMessage(worker, ctx, JSValueMakeNumber(ctx, 40), null));
    var pumps: usize = 0;
    while (state.pauses == 0 and pumps < 8) : (pumps += 1) {
        const pump_result = ZJSWorkerInspectorSessionPump(state.session, 10_000);
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, pump_result);
    }
    try std.testing.expectEqual(@as(usize, 1), state.pauses);
    const reply = JSWorkerReceive(worker, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, reply, null));
    try std.testing.expect(!state.wrong_thread);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "zig-js-inspector/0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "Schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.bytes[0..state.len], "Debugger.paused") != null);
}

test "C-API: worker inspector supports breakpoints stepping exceptions frames scopes and remotes" {
    const State = struct {
        session: ZJSWorkerInspectorSessionRef = null,
        transcript: [65536]u8 = undefined,
        transcript_len: usize = 0,
        breakpoint_pauses: usize = 0,
        step_pauses: usize = 0,
        exception_pauses: usize = 0,
        scope_object_id: u64 = 0,
        held_object_id: u64 = 0,

        fn dispatch(self: *@This(), command: []const u8) void {
            std.debug.assert(ZJSWorkerInspectorSessionDispatch(self.session, command.ptr, command.len));
        }

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            std.debug.assert(self.transcript_len + message_len + 1 <= self.transcript.len);
            @memcpy(self.transcript[self.transcript_len .. self.transcript_len + message_len], message[0..message_len]);
            self.transcript_len += message_len;
            self.transcript[self.transcript_len] = '\n';
            self.transcript_len += 1;
            const bytes = message[0..message_len];

            if (std.mem.indexOf(u8, bytes, "\"id\":13") != null) {
                var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return;
                defer parsed.deinit();
                self.held_object_id = @intCast(parsed.value.object.get("result").?.object.get("result").?.object.get("objectId").?.integer);
                var command_buffer: [256]u8 = undefined;
                const get_properties = std.fmt.bufPrint(
                    &command_buffer,
                    "{{\"id\":14,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
                    .{self.held_object_id},
                ) catch unreachable;
                self.dispatch(get_properties);
            }

            if (std.mem.indexOf(u8, bytes, "Debugger.paused") == null) return;
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return;
            defer parsed.deinit();
            const params = parsed.value.object.get("params").?.object;
            const reason = params.get("reason").?.string;
            if (std.mem.eql(u8, reason, "breakpoint")) {
                self.breakpoint_pauses += 1;
                const first_frame = params.get("callFrames").?.array.items[0].object;
                const first_scope = first_frame.get("scopeChain").?.array.items[0].object;
                self.scope_object_id = @intCast(first_scope.get("object").?.object.get("objectId").?.integer);
                var command_buffer: [256]u8 = undefined;
                const get_scope = std.fmt.bufPrint(
                    &command_buffer,
                    "{{\"id\":11,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":{d}}}}}",
                    .{self.scope_object_id},
                ) catch unreachable;
                self.dispatch(get_scope);
                self.dispatch("{\"id\":12,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"expression\":\"x = 100; x\"}}");
                self.dispatch("{\"id\":13,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":0,\"objectGroup\":\"worker-held\",\"expression\":\"({ answer: 42, nested: { ok: true } })\"}}");
                self.dispatch("{\"id\":15,\"method\":\"Debugger.stepOver\"}");
            } else if (std.mem.eql(u8, reason, "step")) {
                self.step_pauses += 1;
                self.dispatch("{\"id\":16,\"method\":\"Debugger.resume\"}");
            } else if (std.mem.eql(u8, reason, "exception")) {
                self.exception_pauses += 1;
                self.dispatch("{\"id\":17,\"method\":\"Debugger.resume\"}");
            }
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const source = JSStringCreateWithUTF8CString(
        \\globalThis.onmessage = (e) => {
        \\  let x = e.data;
        \\  x += 1;
        \\  x += 2;
        \\  try { throw x; } catch (caught) { x = caught + 1; }
        \\  postMessage(x);
        \\  close();
        \\};
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(worker);
    var target: ZJSInspectorTargetInfo = undefined;
    try std.testing.expect(ZJSWorkerGetInspectorTargetInfo(worker, &target));

    var state: State = .{};
    state.session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(state.session);
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, enable, enable.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    const pause_exceptions = "{\"id\":2,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"all\"}}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, pause_exceptions, pause_exceptions.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    var breakpoint_buffer: [256]u8 = undefined;
    const breakpoint = try std.fmt.bufPrint(
        &breakpoint_buffer,
        "{{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{{\"url\":\"worker://{d}/script\",\"lineNumber\":2}}}}",
        .{target.id},
    );
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, breakpoint.ptr, breakpoint.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));

    try std.testing.expect(JSWorkerPostMessage(worker, ctx, JSValueMakeNumber(ctx, 1), null));
    var pumps: usize = 0;
    while ((state.breakpoint_pauses == 0 or state.step_pauses == 0 or state.exception_pauses == 0 or state.held_object_id == 0) and pumps < 64) : (pumps += 1) {
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    }
    const reply = JSWorkerReceive(worker, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 104), JSValueToNumber(ctx, reply, null));
    try std.testing.expectEqual(@as(usize, 1), state.breakpoint_pauses);
    try std.testing.expectEqual(@as(usize, 1), state.step_pauses);
    try std.testing.expectEqual(@as(usize, 1), state.exception_pauses);
    try std.testing.expect(state.scope_object_id != 0);
    try std.testing.expect(state.held_object_id != 0);

    const transcript = state.transcript[0..state.transcript_len];
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"breakpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"reason\":\"exception\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Debugger.exceptionThrown") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"callFrames\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"scopeChain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"id\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"value\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"id\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "\"name\":\"x\"") != null);
}

test "C-API: worker inspector detach and termination unblock paused execution" {
    const Action = enum { detach, terminate };
    const State = struct {
        action: Action,
        worker: JSWorkerRef,
        session: ZJSWorkerInspectorSessionRef = null,
        paused: bool = false,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.paused = true;
            switch (self.action) {
                .detach => {
                    ZJSWorkerInspectorSessionRelease(self.session);
                    self.session = null;
                },
                .terminate => JSWorkerTerminate(self.worker),
            }
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const source = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = () => { debugger; postMessage(7); close(); };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";

    for ([_]Action{ .detach, .terminate }) |action| {
        const worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
        var state = State{ .action = action, .worker = worker };
        state.session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &state) orelse return error.SessionCreateFailed;
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
        try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, enable, enable.len));
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
        try std.testing.expect(JSWorkerPostMessage(worker, ctx, JSValueMakeNumber(ctx, 1), null));

        var pumps: usize = 0;
        while (!state.paused and pumps < 8) : (pumps += 1) {
            const result = ZJSWorkerInspectorSessionPump(state.session, 10_000);
            try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, result);
        }
        try std.testing.expect(state.paused);
        if (action == .detach) {
            try std.testing.expect(state.session == null);
            const reply = JSWorkerReceive(worker, ctx, 10_000, null) orelse return error.NoReply;
            try std.testing.expectEqual(@as(f64, 7), JSValueToNumber(ctx, reply, null));
        } else {
            ZJSWorkerInspectorSessionRelease(state.session);
            state.session = null;
        }
        JSWorkerRelease(worker);
    }
}

test "C-API: worker inspector detach and worker release unroot remotes exactly once" {
    const TrackingBackend = struct {
        var release_calls: std.atomic.Value(usize) = .init(0);
        var remotes_before: std.atomic.Value(usize) = .init(0);
        var handles_before: std.atomic.Value(usize) = .init(0);
        var handles_after: std.atomic.Value(usize) = .init(0);

        fn reset() void {
            release_calls.store(0, .release);
            remotes_before.store(0, .release);
            handles_before.store(0, .release);
            handles_after.store(0, .release);
        }

        fn create(
            ctx: *Context,
            callback: WorkerMod.InspectorMessageCallback,
            user_data: ?*anyopaque,
            pause_wait_ctx: *anyopaque,
            pause_wait_hook: WorkerMod.InspectorPauseWaitHook,
        ) ?*anyopaque {
            return workerInspectorBackendCreate(ctx, callback, user_data, pause_wait_ctx, pause_wait_hook);
        }

        fn dispatch(session: *anyopaque, message: []const u8) bool {
            return workerInspectorBackendDispatch(session, message);
        }

        fn release(session_ref: *anyopaque) void {
            const session: *CInspectorSession = @ptrCast(@alignCast(session_ref));
            const context = session.state.context;
            remotes_before.store(session.state.remote_objects.items.len, .release);
            handles_before.store(context.c_api_handles.items.len, .release);
            _ = release_calls.fetchAdd(1, .acq_rel);
            workerInspectorBackendRelease(session_ref);
            handles_after.store(context.c_api_handles.items.len, .release);
        }

        const implementation: WorkerMod.InspectorBackend = .{
            .create = create,
            .dispatch = dispatch,
            .release = release,
        };
    };
    const State = struct {
        object_id: u64 = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            const bytes = message[0..message_len];
            if (std.mem.indexOf(u8, bytes, "\"id\":7") == null) return;
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return;
            defer parsed.deinit();
            self.object_id = @intCast(parsed.value.object.get("result").?.object.get("result").?.object.get("objectId").?.integer);
        }
    };
    const Action = enum { detach, worker_release };

    for ([_]Action{ .detach, .worker_release }) |action| {
        TrackingBackend.reset();
        const worker_ptr = WorkerMod.Worker.spawnWith("", .{ .inspector_backend = &TrackingBackend.implementation }) catch return error.WorkerSpawnFailed;
        const worker: JSWorkerRef = @ptrCast(worker_ptr);
        var state: State = .{};
        const session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &state) orelse return error.SessionCreateFailed;
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(session, 10_000));
        const evaluate = "{\"id\":7,\"method\":\"Runtime.evaluate\",\"params\":{\"objectGroup\":\"teardown\",\"expression\":\"({ alive: 42 })\"}}";
        try std.testing.expect(ZJSWorkerInspectorSessionDispatch(session, evaluate, evaluate.len));
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(session, 10_000));
        try std.testing.expect(state.object_id != 0);

        switch (action) {
            .detach => {
                ZJSWorkerInspectorSessionRelease(session);
                JSWorkerRelease(worker);
            },
            .worker_release => {
                JSWorkerRelease(worker);
                var pumps: usize = 0;
                while (pumps < 8) : (pumps += 1) {
                    if (ZJSWorkerInspectorSessionPump(session, 100) == .closed) break;
                }
                try std.testing.expect(pumps < 8);
                ZJSWorkerInspectorSessionRelease(session);
            },
        }
        try std.testing.expectEqual(@as(usize, 1), TrackingBackend.release_calls.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), TrackingBackend.remotes_before.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), TrackingBackend.handles_before.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), TrackingBackend.handles_after.load(.acquire));
    }
}

test "C-API: worker release closes accepted pending inspector traffic" {
    const State = struct {
        callbacks: usize = 0,

        fn receive(_: [*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.callbacks += 1;
        }
    };

    const source = JSStringCreateWithUTF8CString("") orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
    var state: State = .{};
    const session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &state) orelse return error.SessionCreateFailed;
    const schema = "{\"id\":1,\"method\":\"Schema.getDomains\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(session, schema, schema.len));
    JSWorkerRelease(worker);

    var closed = false;
    var pumps: usize = 0;
    while (pumps < 8) : (pumps += 1) {
        if (ZJSWorkerInspectorSessionPump(session, 100) == .closed) {
            closed = true;
            break;
        }
    }
    try std.testing.expect(closed);
    try std.testing.expect(state.callbacks >= 1);
    ZJSWorkerInspectorSessionRelease(session);
}

test "C-API: worker inspector continuation owner is deterministic across sessions" {
    const State = struct {
        session: ZJSWorkerInspectorSessionRef = null,
        resume_on_pause: bool,
        paused: bool = false,
        bytes: [4096]u8 = undefined,
        len: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            const copied = @min(self.bytes.len - self.len, message_len);
            @memcpy(self.bytes[self.len..][0..copied], message[0..copied]);
            self.len += copied;
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.paused = true;
            const resume_command = if (self.resume_on_pause)
                "{\"id\":21,\"method\":\"Debugger.resume\"}"
            else
                "{\"id\":20,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSWorkerInspectorSessionDispatch(self.session, resume_command, resume_command.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const source = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = () => { debugger; postMessage(11); close(); };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(worker);
    var owner = State{ .resume_on_pause = true };
    var observer = State{ .resume_on_pause = false };
    owner.session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &owner) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(owner.session);
    observer.session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &observer) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(observer.session);
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(owner.session, 10_000));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(observer.session, 10_000));
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(owner.session, enable, enable.len));
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(observer.session, enable, enable.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(owner.session, 10_000));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(observer.session, 10_000));
    try std.testing.expect(JSWorkerPostMessage(worker, ctx, JSValueMakeNumber(ctx, 1), null));

    while (!observer.paused) try std.testing.expectEqual(
        ZJSWorkerInspectorPumpResult.message,
        ZJSWorkerInspectorSessionPump(observer.session, 10_000),
    );
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(observer.session, 10_000));
    try std.testing.expect(std.mem.indexOf(u8, observer.bytes[0..observer.len], "session does not own continuation") != null);
    while (!owner.paused) try std.testing.expectEqual(
        ZJSWorkerInspectorPumpResult.message,
        ZJSWorkerInspectorSessionPump(owner.session, 10_000),
    );
    const reply = JSWorkerReceive(worker, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 11), JSValueToNumber(ctx, reply, null));
}

test "C-API: workers and main context pause and continue independently" {
    const WorkerState = struct {
        paused: bool = false,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") != null) self.paused = true;
        }
    };
    const MainState = struct {
        session: ZJSInspectorSessionRef = null,
        pauses: usize = 0,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            if (std.mem.indexOf(u8, message[0..message_len], "Debugger.paused") == null) return;
            self.pauses += 1;
            const resume_command = "{\"id\":2,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSInspectorSessionDispatch(self.session, resume_command, resume_command.len));
        }
    };

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    JSGlobalContextSetInspectable(ctx, true);
    const source = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = (e) => { debugger; postMessage(e.data); close(); };",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(source);
    const first_worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(first_worker);
    const second_worker = JSWorkerCreate(source) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(second_worker);

    var first_state: WorkerState = .{};
    var second_state: WorkerState = .{};
    const first_session = ZJSWorkerInspectorSessionCreate(first_worker, WorkerState.receive, &first_state) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(first_session);
    const second_session = ZJSWorkerInspectorSessionCreate(second_worker, WorkerState.receive, &second_state) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(second_session);
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(first_session, 10_000));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(second_session, 10_000));
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(first_session, enable, enable.len));
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(second_session, enable, enable.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(first_session, 10_000));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(second_session, 10_000));
    try std.testing.expect(JSWorkerPostMessage(first_worker, ctx, JSValueMakeNumber(ctx, 1), null));
    try std.testing.expect(JSWorkerPostMessage(second_worker, ctx, JSValueMakeNumber(ctx, 2), null));

    var pumps: usize = 0;
    while (!first_state.paused and pumps < 8) : (pumps += 1) try std.testing.expectEqual(
        ZJSWorkerInspectorPumpResult.message,
        ZJSWorkerInspectorSessionPump(first_session, 10_000),
    );
    pumps = 0;
    while (!second_state.paused and pumps < 8) : (pumps += 1) try std.testing.expectEqual(
        ZJSWorkerInspectorPumpResult.message,
        ZJSWorkerInspectorSessionPump(second_session, 10_000),
    );
    try std.testing.expect(first_state.paused);
    try std.testing.expect(second_state.paused);

    var main_state: MainState = .{};
    main_state.session = ZJSInspectorSessionCreate(ctx, MainState.receive, &main_state) orelse return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(main_state.session);
    try std.testing.expect(ZJSInspectorSessionDispatch(main_state.session, enable, enable.len));
    const main_source = JSStringCreateWithUTF8CString("debugger; 40 + 2;") orelse return error.StringInitFailed;
    defer JSStringRelease(main_source);
    const main_result = JSEvaluateScript(ctx, main_source, null, null, 0, null) orelse return error.EvalFailed;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, main_result, null));
    try std.testing.expectEqual(@as(usize, 1), main_state.pauses);
    try std.testing.expect(first_state.paused);
    try std.testing.expect(second_state.paused);

    const resume_first = "{\"id\":10,\"method\":\"Debugger.resume\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(first_session, resume_first, resume_first.len));
    const first_reply = JSWorkerReceive(first_worker, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 1), JSValueToNumber(ctx, first_reply, null));
    try std.testing.expect(JSWorkerReceive(second_worker, ctx, 1, null) == null);

    const resume_second = "{\"id\":11,\"method\":\"Debugger.resume\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(second_session, resume_second, resume_second.len));
    const second_reply = JSWorkerReceive(second_worker, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 2), JSValueToNumber(ctx, second_reply, null));
}

test "C-API: module worker inspector publishes graph and pauses in handler" {
    const Modules = struct {
        var token: u8 = 0;

        fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
            if (!std.mem.eql(u8, specifier, "./dep.js")) return null;
            out_path.* = "dep.js";
            return "export const answer = 42;";
        }

        fn host() Context.ModuleHost {
            return .{ .ctx = &token, .load = load };
        }
    };
    const State = struct {
        session: ZJSWorkerInspectorSessionRef = null,
        paused: bool = false,
        saw_entry: bool = false,
        saw_dependency: bool = false,

        fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            const bytes = message[0..message_len];
            self.saw_entry = self.saw_entry or std.mem.indexOf(u8, bytes, "entry.js") != null;
            self.saw_dependency = self.saw_dependency or std.mem.indexOf(u8, bytes, "dep.js") != null;
            if (std.mem.indexOf(u8, bytes, "Debugger.paused") == null) return;
            self.paused = true;
            const resume_command = "{\"id\":9,\"method\":\"Debugger.resume\"}";
            std.debug.assert(ZJSWorkerInspectorSessionDispatch(self.session, resume_command, resume_command.len));
        }
    };

    const entry_source =
        \\import { answer } from "./dep.js";
        \\globalThis.onmessage = () => { debugger; postMessage(answer); close(); };
    ;
    const worker_ptr = WorkerMod.Worker.spawnModuleWith(
        "entry.js",
        entry_source,
        Modules.host(),
        .{ .inspector_backend = &worker_inspector_backend },
    ) catch return error.WorkerSpawnFailed;
    const worker: JSWorkerRef = @ptrCast(worker_ptr);
    defer JSWorkerRelease(worker);
    var info: ZJSInspectorTargetInfo = undefined;
    try std.testing.expect(ZJSWorkerGetInspectorTargetInfo(worker, &info));
    try std.testing.expectEqual(ZJSInspectorTargetKind.module, info.kind);

    var state = State{};
    state.session = ZJSWorkerInspectorSessionCreate(worker, State.receive, &state) orelse return error.SessionCreateFailed;
    defer ZJSWorkerInspectorSessionRelease(state.session);
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    const enable = "{\"id\":1,\"method\":\"Debugger.enable\"}";
    try std.testing.expect(ZJSWorkerInspectorSessionDispatch(state.session, enable, enable.len));
    try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    try std.testing.expect(JSWorkerPostMessage(worker, ctx, JSValueMakeNumber(ctx, 1), null));
    var pumps: usize = 0;
    while ((!state.paused or !state.saw_entry or !state.saw_dependency) and pumps < 12) : (pumps += 1) {
        try std.testing.expectEqual(ZJSWorkerInspectorPumpResult.message, ZJSWorkerInspectorSessionPump(state.session, 10_000));
    }
    try std.testing.expect(state.paused);
    try std.testing.expect(state.saw_entry);
    try std.testing.expect(state.saw_dependency);
    const reply = JSWorkerReceive(worker, ctx, 10_000, null) orelse return error.NoReply;
    try std.testing.expectEqual(@as(f64, 42), JSValueToNumber(ctx, reply, null));
}

test "C-API: worker post rejects uncloneable values through exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const src = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = () => {};",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(src);

    const w = JSWorkerCreate(src) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(w);

    var exception: JSValueRef = null;
    const fn_script = JSStringCreateWithUTF8CString("(function uncloneable() {})") orelse return error.StringInitFailed;
    defer JSStringRelease(fn_script);
    const fn_value = JSEvaluateScript(ctx, fn_script, null, null, 0, &exception) orelse return error.EvalFailed;
    try std.testing.expect(exception == null);

    try std.testing.expect(!JSWorkerPostMessage(w, ctx, fn_value, &exception));
    try std.testing.expect(exception != null);

    const msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(msg);
    var buf: [128]u8 = undefined;
    const written = JSStringGetUTF8CString(msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "DataCloneError") != null);
}

test "C-API: worker post reports configured channel limits" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    const src = JSStringCreateWithUTF8CString("globalThis.onmessage = () => {};") orelse
        return error.StringInitFailed;
    defer JSStringRelease(src);
    const w = JSWorkerCreateWithLimits(src, 1, 1, 1) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(w);

    var exception: JSValueRef = null;
    try std.testing.expect(!JSWorkerPostMessage(w, ctx, JSValueMakeNumber(ctx, 1), &exception));
    try std.testing.expect(exception != null);
    const msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(msg);
    var buf: [128]u8 = undefined;
    const written = JSStringGetUTF8CString(msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "message limit") != null);
}

test "C-API: worker APIs reject null workers through exception" {
    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);

    const message_value = JSValueMakeNumber(ctx, 1) orelse return error.ValueInitFailed;
    var exception: JSValueRef = null;

    try std.testing.expect(!JSWorkerPostMessage(null, ctx, message_value, &exception));
    try std.testing.expect(exception != null);
    const post_msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(post_msg);
    var buf: [128]u8 = undefined;
    var written = JSStringGetUTF8CString(post_msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "worker is not a worker") != null);

    exception = null;
    try std.testing.expect(JSWorkerReceive(null, ctx, 1, &exception) == null);
    try std.testing.expect(exception != null);
    const receive_msg = JSValueToStringCopy(ctx, exception, null) orelse return error.StringInitFailed;
    defer JSStringRelease(receive_msg);
    written = JSStringGetUTF8CString(receive_msg, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0 .. written - 1], "worker is not a worker") != null);
}

test "C-API: worker handles are owner-thread affine" {
    const src = JSStringCreateWithUTF8CString(
        "globalThis.onmessage = () => {};",
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(src);

    const w = JSWorkerCreate(src) orelse return error.WorkerSpawnFailed;
    defer JSWorkerRelease(w);
    try std.testing.expect(workerFrom(w) != null);

    const Probe = struct {
        fn run(worker: JSWorkerRef, rejected: *bool) void {
            rejected.* = workerFrom(worker) == null;
        }
    };
    var rejected = false;
    const t = try std.Thread.spawn(.{}, Probe.run, .{ w, &rejected });
    t.join();
    try std.testing.expect(rejected);
}

test "C-API: JSGarbageCollect honors JSValueProtect/Unprotect (GC on)" {
    // A GC-enabled context driven through the C-API (the default
    // JSGlobalContextCreate stays arena-backed; here we opt in directly).
    const ctx_obj = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx_obj.destroy();
    const ctx: JSContextRef = @ptrCast(ctx_obj);

    // Protect a JSValueRef to an object — protected handles are traced as GC
    // roots until matching JSValueUnprotect calls remove them.
    const mk = JSStringCreateWithUTF8CString("({ tag: 123 })") orelse return error.StringInitFailed;
    defer JSStringRelease(mk);
    const held = JSEvaluateScript(ctx, mk, null, null, 0, null) orelse return error.EvalFailed;
    try std.testing.expect(ZJSValueProtect(ctx, held));
    try std.testing.expect(ZJSValueProtect(ctx, held));

    // Produce a pile of unreferenced garbage.
    const junk = JSStringCreateWithUTF8CString("for (let i = 0; i < 500; i++) { ({ a: i, b: [i] }); } 0") orelse return error.StringInitFailed;
    defer JSStringRelease(junk);
    _ = JSEvaluateScript(ctx, junk, null, null, 0, null);

    const before = ctx_obj.gc.?.live_cells;
    JSGarbageCollect(ctx); // real precise collection
    const after = ctx_obj.gc.?.live_cells;
    try std.testing.expect(after < before); // garbage reclaimed

    // The held reference survived collection while protected and is still usable.
    const key = JSStringCreateWithUTF8CString("tag") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    const tag = JSObjectGetProperty(ctx, held, key, null) orelse return error.PropFailed;
    try std.testing.expectEqual(@as(f64, 123), JSValueToNumber(ctx, tag, null));

    const with_protection = ctx_obj.gc.?.live_cells;
    try std.testing.expect(ZJSValueUnprotect(ctx, held));
    JSGarbageCollect(ctx);
    try std.testing.expectEqual(with_protection, ctx_obj.gc.?.live_cells);
    try std.testing.expect(ZJSValueUnprotect(ctx, held));
    JSGarbageCollect(ctx);
    try std.testing.expect(ctx_obj.gc.?.live_cells < with_protection);
    try std.testing.expect(!ZJSValueUnprotect(ctx, held));
}

test "C-API: JSValueProtect reserves handle capacity chunks" {
    const ctx_obj = try Context.createWith(std.testing.allocator, .{ .enable_gc = true, .enable_threads = true });
    defer ctx_obj.destroy();
    const ctx: JSContextRef = @ptrCast(ctx_obj);

    const first = JSValueToObject(ctx, JSValueMakeNumber(ctx, 1), null) orelse return error.ObjectCreateFailed;
    try std.testing.expect(ZJSValueProtect(ctx, first));
    try std.testing.expectEqual(@as(usize, 1), ctx_obj.c_api_handles.items.len);
    try std.testing.expect(ctx_obj.c_api_handles.capacity >= Context.c_api_handle_reserve_granularity);
    const first_capacity = ctx_obj.c_api_handles.capacity;

    try std.testing.expect(ZJSValueProtect(ctx, first));
    try std.testing.expectEqual(@as(usize, 1), ctx_obj.c_api_handles.items.len);
    try std.testing.expectEqual(@as(usize, 2), ctx_obj.c_api_handles.items[0].count);
    try std.testing.expectEqual(first_capacity, ctx_obj.c_api_handles.capacity);

    ctx_obj.c_api_handles.items[0].count = std.math.maxInt(usize);
    try std.testing.expect(!ZJSValueProtect(ctx, first));
    try std.testing.expectEqual(std.math.maxInt(usize), ctx_obj.c_api_handles.items[0].count);
    ctx_obj.c_api_handles.items[0].count = 2;

    while (ctx_obj.c_api_handles.items.len < first_capacity) {
        const v = JSValueToObject(ctx, JSValueMakeNumber(ctx, @floatFromInt(ctx_obj.c_api_handles.items.len)), null) orelse return error.ObjectCreateFailed;
        try std.testing.expect(ZJSValueProtect(ctx, v));
    }
    try std.testing.expectEqual(first_capacity, ctx_obj.c_api_handles.items.len);
    try std.testing.expectEqual(first_capacity, ctx_obj.c_api_handles.capacity);

    const overflow = JSValueToObject(ctx, JSValueMakeNumber(ctx, 99), null) orelse return error.ObjectCreateFailed;
    try std.testing.expect(ZJSValueProtect(ctx, overflow));
    try std.testing.expectEqual(first_capacity + 1, ctx_obj.c_api_handles.items.len);
    try std.testing.expect(ctx_obj.c_api_handles.capacity > first_capacity);

    try std.testing.expect(!ZJSValueProtect(ctx, null));
    try std.testing.expect(!ZJSValueUnprotect(ctx, null));
}

test "C-API: JSValueProtect roots survive mid-script parallel GC" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const ctx_obj = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    });
    defer ctx_obj.destroy();
    const ctx: JSContextRef = @ptrCast(ctx_obj);

    const mk = JSStringCreateWithUTF8CString("({ tag: 456, nested: { marker: 789 } })") orelse return error.StringInitFailed;
    defer JSStringRelease(mk);
    const held = JSEvaluateScript(ctx, mk, null, null, 0, null) orelse return error.EvalFailed;
    try std.testing.expect(ZJSValueProtect(ctx, held));

    const src = JSStringCreateWithUTF8CString(
        \\(() => {
        \\  const N = 3;
        \\  const gate = { ready: 0, go: 0 };
        \\  const threads = [];
        \\  for (let t = 0; t < N; t++) {
        \\    threads.push(new Thread((gate, id) => {
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      while (Atomics.load(gate, 'go') === 0)
        \\        Atomics.wait(gate, 'go', 0, 1);
        \\      const keep = [];
        \\      for (let round = 0; round < 6; round++) {
        \\        for (let i = 0; i < 500; i++)
        \\          ({ id, round, i, payload: 'c-api-midgc-worker-' + id + '-' + round + '-' + i });
        \\        keep.push({ id, round, marker: id * 100 + round });
        \\        let spin = 0;
        \\        for (let j = 0; j < 5000; j++) spin = (spin + j + round) & 0x3fffffff;
        \\        if (spin < 0) keep.push({ impossible: true });
        \\      }
        \\      return keep.length;
        \\    }, gate, t));
        \\  }
        \\  while (Atomics.load(gate, 'ready') < N)
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  Atomics.store(gate, 'go', 1);
        \\  Atomics.notify(gate, 'go', Infinity);
        \\  const keep = [];
        \\  for (let round = 0; round < 12; round++) {
        \\    for (let i = 0; i < 900; i++)
        \\      keep.push({ round, i, nested: { value: round + i }, text: 'c-api-midgc-main-' + round + '-' + i });
        \\    let spin = 0;
        \\    for (let j = 0; j < 8000; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({ impossible: true });
        \\  }
        \\  let joined = 0;
        \\  for (const t of threads) joined += t.join();
        \\  return keep.length + joined;
        \\})();
    ) orelse return error.StringInitFailed;
    defer JSStringRelease(src);

    const before_collections = ctx_obj.gc_par_collections.load(.monotonic);
    var attempt: usize = 0;
    while (attempt < 10 and ctx_obj.gc_par_collections.load(.monotonic) == before_collections) : (attempt += 1) {
        const result = JSEvaluateScript(ctx, src, null, null, 0, null) orelse return error.EvalFailed;
        try std.testing.expectEqual(@as(f64, 10818), JSValueToNumber(ctx, result, null));
    }
    try std.testing.expect(ctx_obj.gc_par_collections.load(.monotonic) > before_collections);

    const key = JSStringCreateWithUTF8CString("tag") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    const tag = JSObjectGetProperty(ctx, held, key, null) orelse return error.PropFailed;
    try std.testing.expectEqual(@as(f64, 456), JSValueToNumber(ctx, tag, null));

    const nested_key = JSStringCreateWithUTF8CString("nested") orelse return error.StringInitFailed;
    defer JSStringRelease(nested_key);
    const marker_key = JSStringCreateWithUTF8CString("marker") orelse return error.StringInitFailed;
    defer JSStringRelease(marker_key);
    const nested = JSObjectGetProperty(ctx, held, nested_key, null) orelse return error.PropFailed;
    const marker = JSObjectGetProperty(ctx, nested, marker_key, null) orelse return error.PropFailed;
    try std.testing.expectEqual(@as(f64, 789), JSValueToNumber(ctx, marker, null));

    JSGarbageCollect(ctx);
    const with_protection = ctx_obj.gc.?.live_cells;
    try std.testing.expect(ZJSValueUnprotect(ctx, held));
    JSGarbageCollect(ctx);
    try std.testing.expect(ctx_obj.gc.?.live_cells < with_protection);
}
