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
//! Every handle is affine to the thread that created its context:
//! a `JSContextRef` — and every `JSValueRef`/`JSObjectRef` obtained through it —
//! may only be used on the thread that called `JSGlobalContextCreate`.
//! Cross-thread use is undefined behavior (the arena, object graph, and
//! microtask queue are unsynchronized by design); debug builds panic on it.
//! The supported multithreading pattern is one context per thread, sharing
//! only `SharedArrayBuffer` storage — see docs/threads/bindings.md and
//! https://github.com/zig-utils/zig-js/issues/1 for the worker/agent roadmap.
//! The `JSWorker*` surface (below) spawns such per-thread contexts and moves
//! values between them as structured-clone bytes.
//! `JSStringRef`s are immutable and retain/release is atomic, so references may
//! be created, retained, and released on any thread.

const std = @import("std");
const builtin = @import("builtin");
const gc_mod = @import("gc.zig");
const value = @import("value.zig");
const ContextMod = @import("context.zig");
const interp = @import("interpreter.zig");
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
const Boxed = struct { value: Value };

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

pub const JSValueRef = ?*anyopaque;
pub const JSObjectRef = ?*anyopaque;
pub const JSContextRef = ?*anyopaque;
pub const JSStringRef = ?*anyopaque;
pub const ExceptionRef = [*c]JSValueRef;

pub const JSObjectCallAsFunctionCallback = ?*const fn (
    ctx: JSContextRef,
    function: JSObjectRef,
    this_object: JSObjectRef,
    argument_count: usize,
    arguments: [*c]const JSValueRef,
    exception: ExceptionRef,
) callconv(.c) JSValueRef;

pub const kJSPropertyAttributeNone: c_uint = 0;
pub const kJSPropertyAttributeReadOnly: c_uint = 1 << 1;
pub const kJSPropertyAttributeDontEnum: c_uint = 1 << 2;
pub const kJSPropertyAttributeDontDelete: c_uint = 1 << 3;

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

fn box(ctx: *Context, v: Value) JSValueRef {
    const b = ctx.arena().create(Boxed) catch return null;
    b.* = .{ .value = v };
    return @ptrCast(b);
}

fn valueFrom(ref: JSValueRef) ?Value {
    const b: *Boxed = @ptrCast(@alignCast(ref orelse return null));
    return b.value;
}

fn unbox(ref: JSValueRef) Value {
    return valueFrom(ref) orelse Value.undef();
}

fn valueArgFrom(ctx: *Context, ref: JSValueRef, exception: ExceptionRef) ?Value {
    if (valueFrom(ref)) |v| return v;
    setException(ctx, exception, "TypeError: value is not a value");
    return null;
}

fn strFrom(ref: JSStringRef) ?*JsString {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn setException(ctx: *Context, exc: ExceptionRef, message: []const u8) void {
    if (exc != null) exc[0] = box(ctx, Value.str(message));
}

fn setExceptionValue(ctx: *Context, exc: ExceptionRef, exception_value: Value) void {
    if (exc != null) exc[0] = box(ctx, exception_value);
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
    try setDiagnosticField(ctx, obj, "sourceURL", Value.str(source_name_copy));
    try setDiagnosticField(ctx, obj, "line", Value.num(@floatFromInt(line)));
    try setDiagnosticField(ctx, obj, "column", Value.num(@floatFromInt(column)));
    try setDiagnosticField(ctx, obj, "byteOffset", Value.num(@floatFromInt(byte_offset)));
    return err;
}

fn setEvaluationException(ctx: *Context, exc: ExceptionRef, err: anyerror, source_url: JSStringRef, starting_line_number: c_int) void {
    if (isEvaluationParseError(err)) {
        if (ctx.last_evaluation_diagnostic) |loc| {
            const source_name = if (strFrom(source_url)) |s|
                if (s.bytes.len == 0) "<eval>" else s.bytes
            else
                "<eval>";
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
    const c = ctxRawFrom(ctx) orelse return;
    if (c.releaseCApiRef()) c.destroy();
}

export fn JSGlobalContextRetain(ctx: JSContextRef) callconv(.c) JSContextRef {
    const c = ctxRawFrom(ctx) orelse return null;
    c.retainCApiRef();
    return ctx;
}

export fn JSContextGetGlobalObject(ctx: JSContextRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, Value.obj(c.global_object));
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
    // threaded contexts. Fetch raw here so `ZJSGlobalContextCreateThreaded(true)`
    // is usable through the public C API in Debug builds too.
    const c = ctxRawFrom(ctx) orelse return null;
    const s = strFrom(script) orelse {
        setException(c, exception, "TypeError: script is null");
        return null;
    };
    const this_value = if (this_object) |_|
        Value.obj(objectFrom(this_object) orelse {
            setException(c, exception, "TypeError: thisObject is not an object");
            return null;
        })
    else
        Value.obj(c.global_object);
    const result = c.evaluateWithThis(s.bytes, this_value) catch |err| {
        // A JS `throw` surfaces the actual thrown value; host failures (parse
        // errors, OOM) surface their error name as a string.
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, c.exception orelse Value.str("uncaught exception"));
        } else {
            setEvaluationException(c, exception, err, source_url, starting_line_number);
        }
        return null;
    };
    return box(c, result);
}

// ---- JSValue inspection ------------------------------------------------

export fn JSValueGetType(ctx: JSContextRef, v: JSValueRef) callconv(.c) JSType {
    _ = ctx;
    const uv = valueFrom(v) orelse return .invalid;
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
    _ = ctx;
    return if (valueFrom(v)) |uv| uv.isUndefined() else false;
}

export fn JSValueIsNull(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return if (valueFrom(v)) |uv| uv.isNull() else false;
}

export fn JSValueIsBoolean(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return if (valueFrom(v)) |uv| uv.isBoolean() else false;
}

export fn JSValueIsNumber(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return if (valueFrom(v)) |uv| uv.isNumber() else false;
}

export fn JSValueIsString(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return if (valueFrom(v)) |uv| uv.isString() else false;
}

export fn JSValueIsObject(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    const uv = valueFrom(v) orelse return false;
    return uv.isObject() and !uv.asObj().is_symbol and !uv.asObj().is_bigint;
}

export fn JSValueIsArray(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    const uv = valueFrom(v) orelse return false;
    return uv.isObject() and uv.asObj().is_array;
}

export fn JSValueIsDate(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    const uv = valueFrom(v) orelse return false;
    return uv.isObject() and uv.asObj().is_date;
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
    _ = ctx;
    const lhs = valueFrom(a) orelse return false;
    const rhs = valueFrom(b) orelse return false;
    return value.strictEquals(lhs, rhs);
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
    const s = strFrom(str) orelse return box(c, Value.undef());
    const copy = c.arena().dupe(u8, s.bytes) catch return null;
    return box(c, Value.str(copy));
}

// ---- JSValue coercion -------------------------------------------------

export fn JSValueToBoolean(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return if (valueFrom(v)) |uv| uv.toBoolean() else false;
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
    return machine.toNumberV(val) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else {
            setException(c, exception, @errorName(err));
        }
        return std.math.nan(f64);
    };
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
    const js = JsString.create(gpa, s) catch return null;
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
    return box(c, Value.obj(obj));
}

export fn JSValueProtect(ctx: JSContextRef, v: JSValueRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    if (c.gc == null) return; // arena contexts keep values for the context lifetime.
    const raw = v orelse return;
    // `c_api_handles` is read by the mid-script parallel collector; guard it
    // under `realm_lock` (a no-op outside parallel_js).
    c.realmLock();
    defer c.realmUnlock();
    for (c.c_api_handles.items) |*h| {
        if (h.ref == raw) {
            h.count += 1;
            return;
        }
    }
    c.reserveCApiHandlesLocked(1) catch return;
    c.c_api_handles.appendAssumeCapacity(.{ .ref = raw, .count = 1 });
}

export fn JSValueUnprotect(ctx: JSContextRef, v: JSValueRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    if (c.gc == null) return;
    const raw = v orelse return;
    c.realmLock();
    defer c.realmUnlock();
    for (c.c_api_handles.items, 0..) |*h, i| {
        if (h.ref != raw) continue;
        if (h.count > 1) {
            h.count -= 1;
        } else {
            _ = c.c_api_handles.swapRemove(i);
        }
        return;
    }
}

// ---- JSObject construction & properties --------------------------------

export fn JSObjectMake(ctx: JSContextRef, class: ?*anyopaque, data: ?*anyopaque) callconv(.c) JSObjectRef {
    if (class != null) return null;
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
    return box(c, Value.obj(obj));
}

export fn JSObjectGetPrivate(object: JSObjectRef) callconv(.c) ?*anyopaque {
    const obj = objectFrom(object) orelse return null;
    return if (obj.private_data_tag == .host) obj.private_data else null;
}

export fn JSObjectSetPrivate(object: JSObjectRef, data: ?*anyopaque) callconv(.c) bool {
    const obj = objectFrom(object) orelse return false;
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
    return box(c, arr);
}

export fn JSObjectMakeDeferredPromise(ctx: JSContextRef, resolve: [*c]JSObjectRef, reject: [*c]JSObjectRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
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
    const obj = promise.newPromise(&machine) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    const p: *promise.Promise = @ptrCast(@alignCast(obj.promise.?));
    const capability = promise.nativeResolveReject(&machine, p) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, machine.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };

    if (resolve != null) {
        resolve[0] = box(c, capability.resolve) orelse {
            setException(c, exception, "OutOfMemory");
            return null;
        };
    }
    if (reject != null) {
        reject[0] = box(c, capability.reject) orelse {
            setException(c, exception, "OutOfMemory");
            return null;
        };
    }
    return box(c, Value.obj(obj)) orelse {
        setException(c, exception, "OutOfMemory");
        return null;
    };
}

fn objectFrom(ref: JSObjectRef) ?*Object {
    const u = unbox(ref);
    return if (u.isObject()) u.asObj() else null;
}

fn objectArgFrom(ctx: *Context, object: JSObjectRef, exception: ExceptionRef) ?*Object {
    return objectFrom(object) orelse {
        setException(ctx, exception, "TypeError: object is not an object");
        return null;
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
    return box(c, result);
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
    return box(c, result);
}

export fn JSObjectCallAsFunction(ctx: JSContextRef, function: JSObjectRef, this_object: JSObjectRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    if (argc > 0 and argv == null) {
        setException(c, exception, "TypeError: argc > 0 requires non-null argv");
        return null;
    }
    const obj = objectFrom(function) orelse {
        setException(c, exception, "TypeError: value is not a function");
        return null;
    };
    const this_ref = if (this_object) |_|
        if (objectFrom(this_object) != null) this_object else {
            setException(c, exception, "TypeError: thisObject is not an object");
            return null;
        }
    else
        box(c, Value.obj(c.global_object)) orelse {
            setException(c, exception, "OutOfMemory");
            return null;
        };
    const args = collectArgs(c, argc, argv, exception) orelse return null;
    // C-ABI host callbacks run directly across the FFI boundary.
    if (obj.callback) |cb| return cb(ctx, function, this_ref, argc, argv, exception);
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
    const res = interpreter.callValueWithThis(Value.obj(obj), args, unbox(this_ref)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, interpreter.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    return box(c, res);
}

fn hostCallbackNative(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const machine: *interp.Interpreter = @ptrCast(@alignCast(ctx));
    const obj = machine.active_native orelse {
        machine.exception = Value.str("TypeError: host callback missing callee");
        return error.Throw;
    };
    const cb = obj.callback orelse {
        machine.exception = Value.str("TypeError: host callback missing callback");
        return error.Throw;
    };
    const c: *Context = @ptrCast(@alignCast(obj.callback_context orelse {
        machine.exception = Value.str("TypeError: host callback missing context");
        return error.Throw;
    }));
    const js_args = try machine.arena.alloc(JSValueRef, args.len);
    for (args, js_args) |arg, *slot| slot.* = box(c, arg);
    var exception: JSValueRef = null;
    const result = cb(@ptrCast(c), box(c, Value.obj(obj)), box(c, this), args.len, js_args.ptr, &exception);
    if (result) |ref| return unbox(ref);
    if (exception) |ref| {
        machine.exception = unbox(ref);
        return error.Throw;
    }
    return Value.undef();
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
    obj.* = .{ .callback = cb, .callback_context = c, .native = hostCallbackNative, .proto = machine.functionProto() };
    const name_bytes = if (strFrom(name)) |s| s.bytes else "";
    const name_copy = c.arena().dupe(u8, name_bytes) catch return null;
    obj.setOwn(c.arena(), c.root_shape, "name", Value.str(name_copy)) catch return null;
    obj.setAttr(c.arena(), "name", .{ .writable = false, .enumerable = false, .configurable = true }) catch return null;
    return box(c, Value.obj(obj));
}

export fn JSObjectCallAsConstructor(ctx: JSContextRef, constructor: JSObjectRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    if (argc > 0 and argv == null) {
        setException(c, exception, "TypeError: argc > 0 requires non-null argv");
        return null;
    }
    const obj = objectFrom(constructor) orelse {
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
    return box(c, res);
}

export fn JSObjectIsFunction(ctx: JSContextRef, object: JSObjectRef) callconv(.c) bool {
    _ = ctx;
    const obj = objectFrom(object) orelse return false;
    return obj.isCallableObject();
}

export fn JSObjectIsConstructor(ctx: JSContextRef, object: JSObjectRef) callconv(.c) bool {
    _ = ctx;
    const obj = objectFrom(object) orelse return false;
    return interp.isConstructorValue(Value.obj(obj));
}

// ---- JSString lifecycle ------------------------------------------------

export fn JSStringCreateWithUTF8CString(utf8: [*c]const u8) callconv(.c) JSStringRef {
    if (utf8 == null) return null;
    const js = JsString.create(gpa, std.mem.sliceTo(utf8, 0)) catch return null;
    return @ptrCast(js);
}

export fn JSStringRetain(str: JSStringRef) callconv(.c) JSStringRef {
    const s = strFrom(str) orelse return null;
    _ = s.retain();
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

export fn JSStringGetUTF8CString(str: JSStringRef, buffer: [*c]u8, buffer_size: usize) callconv(.c) usize {
    const s = strFrom(str) orelse return 0;
    if (buffer_size == 0) return 0;
    if (buffer == null) return 0;
    const copy_len = @min(s.bytes.len, buffer_size - 1);
    @memcpy(buffer[0..copy_len], s.bytes[0..copy_len]);
    buffer[copy_len] = 0;
    return copy_len + 1; // bytes written, including the null terminator
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
    return @ptrCast(@alignCast(ref orelse return null));
}

/// Spawn a worker running `source` (a script) in a fresh realm on its own
/// thread. Returns null on spawn failure. The worker installs
/// `globalThis.onmessage` from its own script and replies via `postMessage`.
export fn JSWorkerCreate(source: JSStringRef) callconv(.c) JSWorkerRef {
    const s = strFrom(source) orelse return null;
    const w = WorkerMod.Worker.spawn(s.bytes) catch return null;
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
    return box(c, v orelse return null);
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

test "C-API: round-trip a UTF-8 string" {
    const s = JSStringCreateWithUTF8CString("hello") orelse return error.StringInitFailed;
    defer JSStringRelease(s);
    try std.testing.expectEqual(@as(usize, 5), JSStringGetLength(s));

    var buf: [16]u8 = undefined;
    const written = JSStringGetUTF8CString(s, &buf, buf.len);
    try std.testing.expectEqual(@as(usize, 6), written); // "hello" + NUL
    try std.testing.expectEqualStrings("hello", buf[0 .. written - 1]);
}

test "C-API: JSString null C pointers are rejected safely" {
    try std.testing.expect(JSStringCreateWithUTF8CString(null) == null);
    try std.testing.expectEqual(@as(usize, 0), JSStringGetLength(null));
    try std.testing.expectEqual(@as(usize, 0), JSStringGetUTF8CString(null, null, 8));

    const s = JSStringCreateWithUTF8CString("hello") orelse return error.StringInitFailed;
    defer JSStringRelease(s);
    try std.testing.expectEqual(@as(usize, 0), JSStringGetUTF8CString(s, null, 8));
    var one: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), JSStringGetUTF8CString(s, &one, one.len));
    try std.testing.expectEqual(@as(u8, 0), one[0]);
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

test "C-API: unsupported JSClassRef inputs fail fast" {
    var fake_class: u8 = 0;
    const fake: *anyopaque = @ptrCast(&fake_class);
    try std.testing.expect(JSGlobalContextCreate(fake) == null);

    const ctx = JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer JSGlobalContextRelease(ctx);
    try std.testing.expect(JSObjectMake(ctx, fake, null) == null);
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
    JSValueProtect(ctx, held);
    JSValueProtect(ctx, held);

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
    JSValueUnprotect(ctx, held);
    JSGarbageCollect(ctx);
    try std.testing.expectEqual(with_protection, ctx_obj.gc.?.live_cells);
    JSValueUnprotect(ctx, held);
    JSGarbageCollect(ctx);
    try std.testing.expect(ctx_obj.gc.?.live_cells < with_protection);
}

test "C-API: JSValueProtect reserves handle capacity chunks" {
    const ctx_obj = try Context.createWith(std.testing.allocator, .{ .enable_gc = true, .enable_threads = true });
    defer ctx_obj.destroy();
    const ctx: JSContextRef = @ptrCast(ctx_obj);

    const first = JSValueToObject(ctx, JSValueMakeNumber(ctx, 1), null) orelse return error.ObjectCreateFailed;
    JSValueProtect(ctx, first);
    try std.testing.expectEqual(@as(usize, 1), ctx_obj.c_api_handles.items.len);
    try std.testing.expect(ctx_obj.c_api_handles.capacity >= Context.c_api_handle_reserve_granularity);
    const first_capacity = ctx_obj.c_api_handles.capacity;

    JSValueProtect(ctx, first);
    try std.testing.expectEqual(@as(usize, 1), ctx_obj.c_api_handles.items.len);
    try std.testing.expectEqual(@as(usize, 2), ctx_obj.c_api_handles.items[0].count);
    try std.testing.expectEqual(first_capacity, ctx_obj.c_api_handles.capacity);

    while (ctx_obj.c_api_handles.items.len < first_capacity) {
        const v = JSValueToObject(ctx, JSValueMakeNumber(ctx, @floatFromInt(ctx_obj.c_api_handles.items.len)), null) orelse return error.ObjectCreateFailed;
        JSValueProtect(ctx, v);
    }
    try std.testing.expectEqual(first_capacity, ctx_obj.c_api_handles.items.len);
    try std.testing.expectEqual(first_capacity, ctx_obj.c_api_handles.capacity);

    const overflow = JSValueToObject(ctx, JSValueMakeNumber(ctx, 99), null) orelse return error.ObjectCreateFailed;
    JSValueProtect(ctx, overflow);
    try std.testing.expectEqual(first_capacity + 1, ctx_obj.c_api_handles.items.len);
    try std.testing.expect(ctx_obj.c_api_handles.capacity > first_capacity);
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
    JSValueProtect(ctx, held);

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
    JSValueUnprotect(ctx, held);
    JSGarbageCollect(ctx);
    try std.testing.expect(ctx_obj.gc.?.live_cells < with_protection);
}
