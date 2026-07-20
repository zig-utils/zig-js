const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSValueToBoolean(JSContextRef, JSValueRef) bool;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn Bun__onSignalForJS(c_int, JSContextRef) void;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) JSValueRef {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (exception != null or result == null) fail("script evaluation failed");
    return result;
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const sibling = JSGlobalContextCreate(null) orelse fail("sibling context creation failed");
    defer JSGlobalContextRelease(sibling);
    const signal_number: c_int = @intCast(@intFromEnum(std.c.SIG.INT));

    _ = evaluate(context,
        \\globalThis.__signal_fixture = [];
        \\globalThis.__signal_on = function (name, number) { __signal_fixture.push(["on", name, number, this === process]); };
        \\process.on("SIGINT", __signal_on);
        \\process.once("SIGINT", function (name, number) { __signal_fixture.push(["once", name, number, this === process]); });
    );
    _ = evaluate(sibling, "globalThis.__signal_fixture = []; process.on('SIGINT', () => __signal_fixture.push('sibling'));");

    Bun__onSignalForJS(signal_number, context);
    Bun__onSignalForJS(signal_number, context);
    Bun__onSignalForJS(std.math.maxInt(c_int), context);
    Bun__onSignalForJS(signal_number, null);
    if (!JSValueToBoolean(context, evaluate(context,
        \\JSON.stringify(__signal_fixture) === '[["on","SIGINT",2,true],["once","SIGINT",2,true],["on","SIGINT",2,true]]'
    ))) fail("process signal name, arguments, or once ordering mismatch");
    if (!JSValueToBoolean(sibling, evaluate(sibling, "__signal_fixture.length === 0")))
        fail("process signal crossed realms");

    Bun__onSignalForJS(signal_number, sibling);
    if (!JSValueToBoolean(sibling, evaluate(sibling, "__signal_fixture.join(',') === 'sibling'")))
        fail("sibling process signal dispatch mismatch");

    _ = evaluate(context,
        \\process.removeListener("SIGINT", __signal_on);
        \\process.on("SIGINT", function () { throw 400; });
        \\process.on("SIGINT", function () { __signal_fixture.push("late"); });
    );
    Bun__onSignalForJS(signal_number, context);
    if (!JSGlobalObject__hasException(context)) fail("signal listener exception was not preserved");
    JSGlobalObject__clearException(context);
}
