const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    true = 7,
    _,

    fn fromBits(bits: u64) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(bits)));
    }

    fn fromInt32(value: i32) EncodedValue {
        return fromBits(0xfffe_0000_0000_0000 | @as(u64, @as(u32, @bitCast(value))));
    }

    fn fromRef(value: JSValueRef) EncodedValue {
        return fromBits(@intFromPtr(value.?));
    }

    fn cellPointer(value: EncodedValue) ?*anyopaque {
        if (value == .empty) return null;
        const bits: u64 = @bitCast(@intFromEnum(value));
        if (bits & 0xfffe_0000_0000_0002 != 0) return null;
        return @ptrFromInt(@as(usize, @intCast(bits)));
    }
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSObjectCallAsFunctionReturnValueHoldingAPILock(JSContextRef, JSObjectRef, JSObjectRef, usize, [*c]const JSValueRef) EncodedValue;
extern "c" fn JSObjectGetProxyTarget(JSObjectRef) JSObjectRef;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSC__JSValue__isException(EncodedValue, ?*anyopaque) bool;
extern "c" fn JSC__Exception__asJSValue(?*anyopaque) EncodedValue;
extern "c" fn JSC__JSValue__isStrictEqual(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn Bun__JSC__operationMathPow(f64, f64) f64;
extern "c" fn AsyncContextFrame__withAsyncContextIfNeeded(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn Bun__JSValue__isAsyncContextFrame(EncodedValue) bool;
extern "c" fn Bun__JSValue__call(JSContextRef, EncodedValue, EncodedValue, usize, [*]const EncodedValue) EncodedValue;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) EncodedValue {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (exception != null or result == null) fail("script evaluation failed");
    return EncodedValue.fromRef(result);
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const vm = JSC__JSGlobalObject__vm(context) orelse fail("VM projection failed");

    const function = evaluate(context, "(function(a,b){return [this.marker,a,b]})");
    const this_object = evaluate(context, "({marker:371})");
    const arguments = [_]JSValueRef{
        evaluate(context, "10").cellPointer(),
        evaluate(context, "11").cellPointer(),
    };
    const result = JSObjectCallAsFunctionReturnValueHoldingAPILock(
        context,
        function.cellPointer(),
        this_object.cellPointer(),
        arguments.len,
        &arguments,
    );
    const stringify_arguments = [_]JSValueRef{result.cellPointer()};
    const result_json = JSObjectCallAsFunctionReturnValueHoldingAPILock(
        context,
        evaluate(context, "JSON.stringify").cellPointer(),
        null,
        stringify_arguments.len,
        &stringify_arguments,
    );
    if (!JSC__JSValue__isStrictEqual(result_json, evaluate(context, "'[371,10,11]'"), context))
        fail("Bun API-lock call result mismatch");
    const default_this = evaluate(context, "(function(){return this===globalThis})");
    if (JSObjectCallAsFunctionReturnValueHoldingAPILock(context, default_this.cellPointer(), null, 0, null) != .true)
        fail("Bun API-lock call default this mismatch");
    const throwing = evaluate(context, "(function(){throw 371})");
    const exception = JSObjectCallAsFunctionReturnValueHoldingAPILock(context, throwing.cellPointer(), null, 0, null);
    if (!JSC__JSValue__isException(exception, vm) or
        JSC__Exception__asJSValue(exception.cellPointer()) != EncodedValue.fromInt32(371) or
        JSGlobalObject__hasException(context))
        fail("Bun API-lock call exception-cell mismatch");
    if (JSObjectCallAsFunctionReturnValueHoldingAPILock(context, null, null, 0, null) != .empty or
        JSObjectCallAsFunctionReturnValueHoldingAPILock(context, this_object.cellPointer(), null, 0, null) != .empty)
        fail("Bun API-lock call invalid callable mismatch");

    const target = evaluate(context, "globalThis.__bun_proxy_target_371={marker:371};__bun_proxy_target_371");
    const proxy = evaluate(
        context,
        "globalThis.__bun_proxy_traps_371=0;new Proxy(__bun_proxy_target_371,{" ++
            "get(){__bun_proxy_traps_371++},getOwnPropertyDescriptor(){__bun_proxy_traps_371++}})",
    );
    const projected = JSObjectGetProxyTarget(proxy.cellPointer()) orelse fail("Bun proxy target projection failed");
    if (!JSC__JSValue__isStrictEqual(EncodedValue.fromRef(projected), target, context) or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__bun_proxy_traps_371"), EncodedValue.fromInt32(0), context) or
        JSObjectGetProxyTarget(target.cellPointer()) != null)
        fail("Bun proxy target identity/trap mismatch");
    const revoked = evaluate(context, "(()=>{const p=Proxy.revocable({},{});p.revoke();return p.proxy})()");
    if (JSObjectGetProxyTarget(revoked.cellPointer()) != null or JSObjectGetProxyTarget(null) != null)
        fail("Bun proxy target invalid/revoked mismatch");

    if (AsyncContextFrame__withAsyncContextIfNeeded(context, function) != function or
        Bun__JSValue__isAsyncContextFrame(function))
        fail("Bun inactive async-context identity/brand mismatch");
    const async_arguments = [_]EncodedValue{ EncodedValue.fromInt32(12), EncodedValue.fromInt32(13) };
    const async_result = Bun__JSValue__call(context, function, this_object, async_arguments.len, &async_arguments);
    const async_stringify_arguments = [_]JSValueRef{async_result.cellPointer()};
    const async_result_json = JSObjectCallAsFunctionReturnValueHoldingAPILock(
        context,
        evaluate(context, "JSON.stringify").cellPointer(),
        null,
        async_stringify_arguments.len,
        &async_stringify_arguments,
    );
    if (!JSC__JSValue__isStrictEqual(async_result_json, evaluate(context, "'[371,12,13]'"), context))
        fail("Bun async-context call result mismatch");
    const no_async_arguments: [1]EncodedValue = undefined;
    if (Bun__JSValue__call(context, default_this, .empty, 0, &no_async_arguments) != .true or
        AsyncContextFrame__withAsyncContextIfNeeded(context, .empty) != .empty or
        Bun__JSValue__isAsyncContextFrame(EncodedValue.fromInt32(1)))
        fail("Bun async-context default-this/invalid boundary mismatch");

    const negative_zero = Bun__JSC__operationMathPow(-0.0, 3);
    if (Bun__JSC__operationMathPow(2, 10) != 1024 or
        !std.math.isNan(Bun__JSC__operationMathPow(1, std.math.nan(f64))) or
        !std.math.isNan(Bun__JSC__operationMathPow(-1, std.math.inf(f64))) or
        negative_zero != 0 or !std.math.signbit(negative_zero) or
        Bun__JSC__operationMathPow(-0.0, -3) != -std.math.inf(f64))
        fail("Bun JSC Math.pow operation mismatch");
}
