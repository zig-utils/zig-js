//! Implementation fixture: lower the owned Context's allowance, not its ABI.
const std = @import("std");
const Context = @import("context.zig").Context;
const api = struct {
    const JSContextRef = ?*anyopaque;
    const JSObjectRef = ?*anyopaque;
    const JSValueRef = ?*anyopaque;
    const JSStringRef = ?*anyopaque;
    const JSObjectCallAsFunctionCallback = ?*const fn (JSContextRef, JSObjectRef, JSObjectRef, usize, [*c]const JSValueRef, [*c]JSValueRef) callconv(.c) JSValueRef;
    const kJSPropertyAttributeNone: c_uint = 0;
    extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
    extern "c" fn JSGlobalContextRelease(JSContextRef) void;
    extern "c" fn JSContextGetGlobalObject(JSContextRef) JSObjectRef;
    extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
    extern "c" fn JSStringRelease(JSStringRef) void;
    extern "c" fn JSStringGetUTF8CString(JSStringRef, [*]u8, usize) usize;
    extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
    extern "c" fn JSValueToObject(JSContextRef, JSValueRef, [*c]JSValueRef) JSObjectRef;
    extern "c" fn JSValueToStringCopy(JSContextRef, JSValueRef, [*c]JSValueRef) JSStringRef;
    extern "c" fn JSValueMakeUndefined(JSContextRef) JSValueRef;
    extern "c" fn JSValueToNumber(JSContextRef, JSValueRef, [*c]JSValueRef) f64;
    extern "c" fn JSObjectMakeFunctionWithCallback(JSContextRef, JSStringRef, JSObjectCallAsFunctionCallback) JSObjectRef;
    extern "c" fn JSObjectSetProperty(JSContextRef, JSObjectRef, JSStringRef, JSValueRef, c_uint, [*c]JSValueRef) void;
    extern "c" fn JSObjectCallAsFunction(JSContextRef, JSObjectRef, JSObjectRef, usize, [*c]const JSValueRef, [*c]JSValueRef) JSValueRef;
};

fn evaluate(ctx: api.JSContextRef, source: [*:0]const u8, exception: [*c]api.JSValueRef) api.JSValueRef {
    const text = api.JSStringCreateWithUTF8CString(source);
    defer api.JSStringRelease(text);
    return api.JSEvaluateScript(ctx, text, null, null, 1, exception);
}

fn burn(ctx: api.JSContextRef, _: api.JSObjectRef, _: api.JSObjectRef, _: usize, _: [*c]const api.JSValueRef, exception: [*c]api.JSValueRef) callconv(.c) api.JSValueRef {
    return evaluate(ctx, "for(var inner=0;inner<100;inner++){}", exception);
}

fn nested(ctx: api.JSContextRef, _: api.JSObjectRef, _: api.JSObjectRef, count: usize, arguments: [*c]const api.JSValueRef, exception: [*c]api.JSValueRef) callconv(.c) api.JSValueRef {
    if (count != 1) return api.JSValueMakeUndefined(ctx);
    const function = api.JSValueToObject(ctx, arguments[0], exception);
    return api.JSObjectCallAsFunction(ctx, function, null, 0, null, exception);
}

pub fn main() !void {
    const reference = api.JSGlobalContextCreate(null) orelse return error.ContextCreationFailed;
    defer api.JSGlobalContextRelease(reference);
    // Internal test-only resource knob. The public Context handle stays opaque.
    const ctx: *Context = @ptrCast(@alignCast(reference));
    ctx.step_budget = 2000;
    const names = [_][*:0]const u8{ "burn", "nested" };
    const callbacks = [_]api.JSObjectCallAsFunctionCallback{ burn, nested };
    for (names, callbacks) |name, callback| {
        const key = api.JSStringCreateWithUTF8CString(name);
        defer api.JSStringRelease(key);
        const function = api.JSObjectMakeFunctionWithCallback(reference, key, callback);
        var exception: api.JSValueRef = null;
        api.JSObjectSetProperty(reference, api.JSContextGetGlobalObject(reference), key, function, api.kJSPropertyAttributeNone, &exception);
        if (exception != null) return error.InstallFailed;
    }
    var exception: api.JSValueRef = null;
    const result = evaluate(reference, "var calls=0;for(var round=0;round<20;round++){nested(burn);calls++;}calls", &exception);
    if (result != null or exception == null) return error.NestedCallResetBudget;
    const text = api.JSValueToStringCopy(reference, exception, null);
    defer api.JSStringRelease(text);
    var message: [256]u8 = undefined;
    const length = api.JSStringGetUTF8CString(text, &message, message.len);
    if (length == 0 or !std.mem.startsWith(u8, message[0 .. length - 1], "RangeError:")) return error.WrongBudgetException;
    exception = null;
    const next = evaluate(reference, "7", &exception);
    if (next == null or exception != null or api.JSValueToNumber(reference, next, null) != 7) return error.FreshHostEntryFailed;
    std.debug.print("C call reentry budget: RangeError and fresh host entry passed\n", .{});
}
