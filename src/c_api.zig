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
//! Every handle is affine to the context and thread that created it:
//! a `JSContextRef` — and every `JSValueRef`/`JSObjectRef` obtained through it —
//! may only be used on the thread that called `JSGlobalContextCreate`.
//! `JSValueRef`/`JSObjectRef` boxes carry their owning context, and context-taking
//! C APIs reject handles from a different context. Cross-thread use is still
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
const strcell = @import("strcell.zig");
const WorkerMod = @import("worker.zig");
const JsString = @import("jsstring.zig").JsString;

const Context = ContextMod.Context;
const Value = value.Value;
const Object = value.Object;

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
pub const JSStringRef = ?*anyopaque;
pub const JSClassRef = ?*anyopaque;
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

// ---- internal helpers --------------------------------------------------

fn ctxRawFrom(ref: JSContextRef) ?*Context {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn ctxFrom(ref: JSContextRef) ?*Context {
    const c = ctxRawFrom(ref) orelse return null;
    // Single funnel for every C-API entry point: enforce context thread
    // affinity in debug builds (see "Threading rules" above).
    c.assertOwnerThread();
    return c;
}

fn ctxForHandleInspection(ref: JSContextRef) ?*Context {
    const c = ctxRawFrom(ref) orelse return null;
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

fn valueFromContext(ctx: *Context, ref: JSValueRef) ?Value {
    const b = boxedFrom(ref) orelse return null;
    if (b.owner != ctx) return null;
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

export fn JSGarbageCollect(ctx: JSContextRef) callconv(.c) void {
    // Real precise mark-sweep when the context has the GC enabled; a no-op on
    // the default arena engine. Sound here because the C-API entry point is a
    // quiescent point (no JS executing); embedder-held `JSValueRef`s that must
    // survive this call are rooted by JSValueProtect's counted handle table.
    const c = ctxFrom(ctx) orelse return;
    c.collectGarbage();
}

export fn JSGlobalContextCreate(global_class: ?*anyopaque) callconv(.c) JSContextRef {
    if (global_class != null) return null;
    const ctx = Context.create(gpa) catch return null;
    ctx.initCApiRef();
    return @ptrCast(ctx);
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
    if (c.releaseCApiRef()) c.destroy();
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
    if (boxed.owner != c) return false;
    const raw = v.?;
    if (c.gc == null) return true; // arena contexts keep values for the context lifetime.
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
    if (boxed.owner != c) return false;
    const raw = v.?;
    if (c.gc == null) return true;
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
        if (!retainClass(item)) return null;
        const created = c.createCApiObjectOwner(@ptrCast(item), finishClassObject) catch {
            releaseClass(item);
            return null;
        };
        owner = created;
        obj.setCApiObjectOwner(c.arena(), created) catch {
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
    switch (obj.deleteAccessorOwn(c.arena(), key.bytes) catch {
        setException(c, exception, "OutOfMemory");
        return;
    }) {
        .absent, .removed_continue, .deleted => {},
        .blocked => {
            setException(c, exception, "TypeError: cannot redefine non-configurable accessor");
            return;
        },
    }
    obj.setOwn(c.arena(), c.root_shape, key.bytes, property_value) catch {
        setException(c, exception, "OutOfMemory");
        return;
    };
    obj.setAttr(c.arena(), key.bytes, propAttrFromC(attrs)) catch {
        setException(c, exception, "OutOfMemory");
        return;
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
    const obj = gc_mod.allocObject(c.gc, c.arena()) catch return null;
    obj.* = .{ .native = hostCallbackNative, .proto = machine.functionProto() };
    obj.setHostCallback(c.arena(), cb, c) catch return null;
    const name_bytes = if (strFrom(name)) |s| s.bytes else "";
    const name_copy = c.arena().dupe(u8, name_bytes) catch return null;
    obj.setOwn(c.arena(), c.root_shape, "name", Value.strOwned(c.arena(), name_copy) catch return null) catch return null;
    obj.setAttr(c.arena(), "name", .{ .writable = false, .enumerable = false, .configurable = true }) catch return null;
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
    const w = WorkerMod.Worker.spawn(s.bytes) catch return null;
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
    }) catch return null;
    return @ptrCast(w);
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

test "C-API: unsupported global JSClassRef input fails fast" {
    var fake_class: u8 = 0;
    const fake: *anyopaque = @ptrCast(&fake_class);
    try std.testing.expect(JSGlobalContextCreate(fake) == null);
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
