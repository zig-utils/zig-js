//! JavaScriptCore C-API drop-in surface, implemented in pure Zig.
//!
//! These `export fn` symbols mirror Apple's `<JavaScriptCore/JSValueRef.h>` and
//! `<JSObjectRef.h>` so a consumer that today links the system
//! `JavaScriptCore.framework` (e.g. `~/Code/Home/lang`'s
//! `packages/runtime/src/jsc/extern_fns.zig`) can link this library instead
//! with zero call-site changes. All `JSValueRef` / `JSObjectRef` /
//! `JSContextRef` arguments are word-sized opaque pointers, so the ABI matches
//! regardless of the concrete Zig pointee types used internally.
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
//! `JSStringRef`s are immutable and may be created and released on any thread,
//! but a given string must not be used from two threads concurrently (its
//! refcount is not atomic).

const std = @import("std");
const gc_mod = @import("gc.zig");
const value = @import("value.zig");
const ContextMod = @import("context.zig");
const interp = @import("interpreter.zig");
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

/// JSC `JSType` — ABI-compatible with Apple's enum and Home's `types.JSType`.
pub const JSType = enum(c_uint) {
    undefined = 0,
    null = 1,
    boolean = 2,
    number = 3,
    string = 4,
    object = 5,
    symbol = 6,
};

pub const JSValueRef = ?*anyopaque;
pub const JSObjectRef = ?*anyopaque;
pub const JSContextRef = ?*anyopaque;
pub const JSStringRef = ?*anyopaque;
pub const ExceptionRef = [*c]JSValueRef;

pub const JSObjectCallAsFunctionCallback = *const fn (
    ctx: JSContextRef,
    function: JSObjectRef,
    this_object: JSObjectRef,
    argument_count: usize,
    arguments: [*c]const JSValueRef,
    exception: ExceptionRef,
) callconv(.c) JSValueRef;

// ---- internal helpers --------------------------------------------------

fn ctxFrom(ref: JSContextRef) ?*Context {
    const c: *Context = @ptrCast(@alignCast(ref orelse return null));
    // Single funnel for every C-API entry point: enforce context thread
    // affinity in debug builds (see "Threading rules" above).
    c.assertOwnerThread();
    return c;
}

fn box(ctx: *Context, v: Value) JSValueRef {
    const b = ctx.arena().create(Boxed) catch return null;
    b.* = .{ .value = v };
    // When the GC is on, an embedder-held `JSValueRef` must keep its object
    // alive across collections: register the `Boxed` as a root (`*Boxed` aliases
    // `*Value` — `value` is its only/first field). Off-GC contexts skip this, so
    // the default C-API path pays nothing. (No `JSValueUnprotect` yet, so a
    // boxed object is pinned for the context's life — conservative but sound.)
    if (ctx.gc != null) ctx.c_api_handles.append(ctx.gpa, @ptrCast(b)) catch {};
    return @ptrCast(b);
}

fn unbox(ref: JSValueRef) Value {
    const b: *Boxed = @ptrCast(@alignCast(ref orelse return .undefined));
    return b.value;
}

fn strFrom(ref: JSStringRef) ?*JsString {
    return @ptrCast(@alignCast(ref orelse return null));
}

fn setException(ctx: *Context, exc: ExceptionRef, message: []const u8) void {
    if (exc != null) exc[0] = box(ctx, .{ .string = message });
}

// ---- VM lifecycle ------------------------------------------------------

export fn JSGarbageCollect(ctx: JSContextRef) callconv(.c) void {
    // Real precise mark-sweep when the context has the GC enabled; a no-op on
    // the default arena engine. Sound here because the C-API entry point is a
    // quiescent point (no JS executing) and every live `JSValueRef` is rooted
    // via the handle table (see `box`).
    const c = ctxFrom(ctx) orelse return;
    c.collectGarbage();
}

export fn JSGlobalContextCreate(global_class: ?*anyopaque) callconv(.c) JSContextRef {
    _ = global_class;
    const ctx = Context.create(gpa) catch return null;
    return @ptrCast(ctx);
}

export fn JSGlobalContextRelease(ctx: JSContextRef) callconv(.c) void {
    const c = ctxFrom(ctx) orelse return;
    c.destroy();
}

export fn JSGlobalContextRetain(ctx: JSContextRef) callconv(.c) JSContextRef {
    return ctx; // Single-owner for v1; refcounting lands with multi-realm support.
}

export fn JSContextGetGlobalObject(ctx: JSContextRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, .{ .object = c.global_object });
}

export fn JSEvaluateScript(
    ctx: JSContextRef,
    script: JSStringRef,
    this_object: JSObjectRef,
    source_url: JSStringRef,
    starting_line_number: c_int,
    exception: ExceptionRef,
) callconv(.c) JSValueRef {
    _ = this_object;
    _ = source_url;
    _ = starting_line_number;
    const c = ctxFrom(ctx) orelse return null;
    const s = strFrom(script) orelse return null;
    const result = c.evaluate(s.bytes) catch |err| {
        // A JS `throw` surfaces the actual thrown value; host failures (parse
        // errors, OOM) surface their error name as a string.
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, c.exception orelse .{ .string = "uncaught exception" });
        } else {
            setException(c, exception, @errorName(err));
        }
        return null;
    };
    return box(c, result);
}

// ---- JSValue inspection ------------------------------------------------

export fn JSValueGetType(ctx: JSContextRef, v: JSValueRef) callconv(.c) JSType {
    _ = ctx;
    return switch (unbox(v)) {
        .undefined => .undefined,
        .null => .null,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .object => .object,
    };
}

export fn JSValueIsUndefined(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v) == .undefined;
}

export fn JSValueIsNull(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v) == .null;
}

export fn JSValueIsBoolean(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v) == .boolean;
}

export fn JSValueIsNumber(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v) == .number;
}

export fn JSValueIsString(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v) == .string;
}

export fn JSValueIsObject(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v) == .object;
}

export fn JSValueIsArray(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return switch (unbox(v)) {
        .object => |o| o.is_array,
        else => false,
    };
}

export fn JSValueIsDate(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    _ = v;
    return false; // Date type not yet implemented.
}

export fn JSValueIsEqual(ctx: JSContextRef, a: JSValueRef, b: JSValueRef, exception: ExceptionRef) callconv(.c) bool {
    _ = ctx;
    _ = exception;
    return value.looseEquals(unbox(a), unbox(b));
}

export fn JSValueIsStrictEqual(ctx: JSContextRef, a: JSValueRef, b: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return value.strictEquals(unbox(a), unbox(b));
}

// ---- JSValue constructors ---------------------------------------------

export fn JSValueMakeUndefined(ctx: JSContextRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, .undefined);
}

export fn JSValueMakeNull(ctx: JSContextRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, .null);
}

export fn JSValueMakeBoolean(ctx: JSContextRef, b: bool) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, .{ .boolean = b });
}

export fn JSValueMakeNumber(ctx: JSContextRef, n: f64) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    return box(c, .{ .number = n });
}

export fn JSValueMakeString(ctx: JSContextRef, str: JSStringRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const s = strFrom(str) orelse return box(c, .undefined);
    const copy = c.arena().dupe(u8, s.bytes) catch return null;
    return box(c, .{ .string = copy });
}

// ---- JSValue coercion -------------------------------------------------

export fn JSValueToBoolean(ctx: JSContextRef, v: JSValueRef) callconv(.c) bool {
    _ = ctx;
    return unbox(v).toBoolean();
}

export fn JSValueToNumber(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) f64 {
    _ = ctx;
    _ = exception;
    return unbox(v).toNumber();
}

export fn JSValueToStringCopy(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) JSStringRef {
    const c = ctxFrom(ctx) orelse return null;
    const s = unbox(v).toString(c.arena()) catch {
        setException(c, exception, "OutOfMemory");
        return null;
    };
    const js = JsString.create(gpa, s) catch return null;
    return @ptrCast(js);
}

export fn JSValueToObject(ctx: JSContextRef, v: JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    _ = exception;
    const c = ctxFrom(ctx) orelse return null;
    const val = unbox(v);
    if (val == .object) return v;
    const obj = gc_mod.allocObj(c.arena()) catch return null;
    obj.* = .{};
    return box(c, .{ .object = obj });
}

export fn JSValueProtect(ctx: JSContextRef, v: JSValueRef) callconv(.c) void {
    _ = ctx;
    _ = v; // No-op: arena keeps values alive for the context lifetime.
}

export fn JSValueUnprotect(ctx: JSContextRef, v: JSValueRef) callconv(.c) void {
    _ = ctx;
    _ = v;
}

// ---- JSObject construction & properties --------------------------------

export fn JSObjectMake(ctx: JSContextRef, class: ?*anyopaque, data: ?*anyopaque) callconv(.c) JSObjectRef {
    _ = class;
    const c = ctxFrom(ctx) orelse return null;
    const obj = gc_mod.allocObj(c.arena()) catch return null;
    obj.* = .{ .private_data = data };
    return box(c, .{ .object = obj });
}

export fn JSObjectMakeArray(ctx: JSContextRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    _ = exception;
    const c = ctxFrom(ctx) orelse return null;
    const obj = gc_mod.allocObj(c.arena()) catch return null;
    obj.* = .{ .is_array = true };
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        obj.elements.append(obj.elementsAllocator(c.arena()), unbox(argv[i])) catch return null;
    }
    return box(c, .{ .object = obj });
}

export fn JSObjectMakeDeferredPromise(ctx: JSContextRef, resolve: [*c]JSObjectRef, reject: [*c]JSObjectRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    _ = resolve;
    _ = reject;
    const c = ctxFrom(ctx) orelse return null;
    setException(c, exception, "NotImplemented: JSObjectMakeDeferredPromise");
    return null;
}

fn objectFrom(ref: JSObjectRef) ?*Object {
    return switch (unbox(ref)) {
        .object => |o| o,
        else => null,
    };
}

export fn JSObjectGetProperty(ctx: JSContextRef, object: JSObjectRef, name: JSStringRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    _ = exception;
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectFrom(object) orelse return box(c, .undefined);
    const key = strFrom(name) orelse return box(c, .undefined);
    return box(c, obj.getOwn(key.bytes) orelse .undefined);
}

export fn JSObjectSetProperty(ctx: JSContextRef, object: JSObjectRef, name: JSStringRef, val: JSValueRef, attrs: c_uint, exception: ExceptionRef) callconv(.c) void {
    _ = attrs;
    _ = exception;
    const c = ctxFrom(ctx) orelse return;
    const obj = objectFrom(object) orelse return;
    const key = strFrom(name) orelse return;
    obj.setOwn(c.arena(), c.root_shape, key.bytes, unbox(val)) catch return;
}

export fn JSObjectGetPropertyAtIndex(ctx: JSContextRef, object: JSObjectRef, index: c_uint, exception: ExceptionRef) callconv(.c) JSValueRef {
    _ = exception;
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectFrom(object) orelse return box(c, .undefined);
    if (index < obj.elements.items.len) return box(c, obj.elements.items[index]);
    return box(c, .undefined);
}

fn collectArgs(c: *Context, argc: usize, argv: [*c]const JSValueRef) ?[]Value {
    const args = c.arena().alloc(Value, argc) catch return null;
    var i: usize = 0;
    while (i < argc) : (i += 1) args[i] = unbox(argv[i]);
    return args;
}

export fn JSObjectCallAsFunction(ctx: JSContextRef, function: JSObjectRef, this_object: JSObjectRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSValueRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectFrom(function) orelse {
        setException(c, exception, "TypeError: value is not a function");
        return null;
    };
    // C-ABI host callbacks run directly across the FFI boundary.
    if (obj.callback) |cb| return cb(ctx, function, this_object, argc, argv, exception);
    // JS functions / native builtins / error constructors run on the interpreter.
    const args = collectArgs(c, argc, argv) orelse return null;
    var interpreter = c.interpreter();
    const res = interpreter.callValueWithThis(.{ .object = obj }, args, unbox(this_object)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, interpreter.exception);
        } else setException(c, exception, @errorName(err));
        return null;
    };
    return box(c, res);
}

export fn JSObjectMakeFunctionWithCallback(ctx: JSContextRef, name: JSStringRef, callback: JSObjectCallAsFunctionCallback) callconv(.c) JSObjectRef {
    _ = name;
    const c = ctxFrom(ctx) orelse return null;
    const obj = gc_mod.allocObj(c.arena()) catch return null;
    obj.* = .{ .callback = callback };
    return box(c, .{ .object = obj });
}

export fn JSObjectCallAsConstructor(ctx: JSContextRef, constructor: JSObjectRef, argc: usize, argv: [*c]const JSValueRef, exception: ExceptionRef) callconv(.c) JSObjectRef {
    const c = ctxFrom(ctx) orelse return null;
    const obj = objectFrom(constructor) orelse {
        setException(c, exception, "TypeError: value is not a constructor");
        return null;
    };
    const args = collectArgs(c, argc, argv) orelse return null;
    var interpreter = c.interpreter();
    const res = interpreter.construct(.{ .object = obj }, args) catch |err| {
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
    return obj.js_func != null or obj.error_ctor != null;
}

// ---- JSString lifecycle ------------------------------------------------

export fn JSStringCreateWithUTF8CString(utf8: [*:0]const u8) callconv(.c) JSStringRef {
    const js = JsString.create(gpa, std.mem.span(utf8)) catch return null;
    return @ptrCast(js);
}

export fn JSStringRetain(str: JSStringRef) callconv(.c) JSStringRef {
    const s = strFrom(str) orelse return null;
    s.retain();
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

export fn JSStringGetUTF8CString(str: JSStringRef, buffer: [*]u8, buffer_size: usize) callconv(.c) usize {
    const s = strFrom(str) orelse return 0;
    if (buffer_size == 0) return 0;
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
    const w = workerFrom(worker) orelse return false;
    const c = ctxFrom(ctx) orelse return false;
    var machine = c.interpreter();
    w.postMessage(&machine, unbox(value_ref)) catch |err| {
        if (err == error.Throw) {
            if (exception != null) exception[0] = box(c, c.exception orelse .{ .string = "DataCloneError" });
        } else setException(c, exception, @errorName(err));
        return false;
    };
    return true;
}

/// Block up to `timeout_ms` (0 = wait indefinitely) for the next worker→main
/// message, deserialized into `ctx`'s realm. Returns null when the worker has
/// closed its side and drained, or the timeout elapsed.
export fn JSWorkerReceive(worker: JSWorkerRef, ctx: JSContextRef, timeout_ms: u64, exception: ExceptionRef) callconv(.c) JSValueRef {
    const w = workerFrom(worker) orelse return null;
    const c = ctxFrom(ctx) orelse return null;
    var machine = c.interpreter();
    const tmo: ?u64 = if (timeout_ms == 0) null else timeout_ms;
    const v = w.receive(&machine, tmo) catch |err| {
        setException(c, exception, @errorName(err));
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

test "C-API: round-trip a UTF-8 string" {
    const s = JSStringCreateWithUTF8CString("hello") orelse return error.StringInitFailed;
    defer JSStringRelease(s);
    try std.testing.expectEqual(@as(usize, 5), JSStringGetLength(s));

    var buf: [16]u8 = undefined;
    const written = JSStringGetUTF8CString(s, &buf, buf.len);
    try std.testing.expectEqual(@as(usize, 6), written); // "hello" + NUL
    try std.testing.expectEqualStrings("hello", buf[0 .. written - 1]);
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

test "C-API: JSGarbageCollect reclaims garbage and keeps held JSValueRefs (GC on)" {
    // A GC-enabled context driven through the C-API (the default
    // JSGlobalContextCreate stays arena-backed; here we opt in directly).
    const ctx_obj = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx_obj.destroy();
    const ctx: JSContextRef = @ptrCast(ctx_obj);

    // Hold a JSValueRef to an object — it is registered as a GC handle.
    const mk = JSStringCreateWithUTF8CString("({ tag: 123 })") orelse return error.StringInitFailed;
    defer JSStringRelease(mk);
    const held = JSEvaluateScript(ctx, mk, null, null, 0, null) orelse return error.EvalFailed;

    // Produce a pile of unreferenced garbage.
    const junk = JSStringCreateWithUTF8CString("for (let i = 0; i < 500; i++) { ({ a: i, b: [i] }); } 0") orelse return error.StringInitFailed;
    defer JSStringRelease(junk);
    _ = JSEvaluateScript(ctx, junk, null, null, 0, null);

    const before = ctx_obj.gc.?.live_cells;
    JSGarbageCollect(ctx); // real precise collection
    const after = ctx_obj.gc.?.live_cells;
    try std.testing.expect(after < before); // garbage reclaimed

    // The held reference survived collection (rooted via the handle table) and
    // is still usable.
    const key = JSStringCreateWithUTF8CString("tag") orelse return error.StringInitFailed;
    defer JSStringRelease(key);
    const tag = JSObjectGetProperty(ctx, held, key, null) orelse return error.PropFailed;
    try std.testing.expectEqual(@as(f64, 123), JSValueToNumber(ctx, tag, null));
}
