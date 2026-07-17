const std = @import("std");
const options = @import("private_abi_options");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    null = 2,
    deleted = 4,
    false = 6,
    true = 7,
    undefined = 10,
    _,

    fn fromRef(value: JSValueRef) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intFromPtr(value.?)))));
    }
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(
    JSContextRef,
    JSStringRef,
    JSObjectRef,
    JSStringRef,
    c_int,
    [*c]JSValueRef,
) JSValueRef;

extern "c" fn JSC__JSValue__jsType(EncodedValue) u8;
extern "c" fn JSC__JSCell__getType(?*anyopaque) u8;

fn fail(message: []const u8) noreturn {
    std.debug.print("private JSType shims ({s}): {s}\n", .{
        if (options.is_bun) "bun" else "home",
        message,
    });
    std.process.exit(1);
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) JSValueRef {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (result == null or exception != null) fail("evaluation failed");
    return result;
}

fn expected(home_tag: u8) u8 {
    return home_tag + @intFromBool(options.is_bun and home_tag >= 27);
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);

    const cases = [_]struct {
        source: [*:0]const u8,
        home_tag: u8,
    }{
        .{ .source = "'text'", .home_tag = 2 },
        .{ .source = "123n", .home_tag = 3 },
        .{ .source = "Symbol('tag')", .home_tag = 6 },
        .{ .source = "({})", .home_tag = 34 },
        .{ .source = "(function named(){})", .home_tag = 36 },
        .{ .source = "Array", .home_tag = 37 },
        .{ .source = "new Error('boom')", .home_tag = 41 },
        .{ .source = "[]", .home_tag = 46 },
        .{ .source = "new ArrayBuffer(4)", .home_tag = 48 },
        .{ .source = "new Uint8Array(4)", .home_tag = 50 },
        .{ .source = "new BigInt64Array(2)", .home_tag = 59 },
        .{ .source = "new DataView(new ArrayBuffer(4))", .home_tag = 61 },
        .{ .source = "/x/", .home_tag = 72 },
        .{ .source = "new Date(0)", .home_tag = 73 },
        .{ .source = "Promise.resolve(1)", .home_tag = 86 },
        .{ .source = "new Map()", .home_tag = 87 },
        .{ .source = "new Set()", .home_tag = 88 },
        .{ .source = "new WeakMap()", .home_tag = 89 },
        .{ .source = "new WeakSet()", .home_tag = 90 },
        .{ .source = "new String('boxed')", .home_tag = 94 },
    };

    for (cases) |case| {
        const result = evaluate(context, case.source);
        const encoded = EncodedValue.fromRef(result);
        const tag = expected(case.home_tag);
        if (JSC__JSValue__jsType(encoded) != tag or JSC__JSCell__getType(result) != tag)
            fail("selected tag mismatch");
    }
    if (JSC__JSValue__jsType(.empty) != 0 or JSC__JSCell__getType(null) != 0)
        fail("invalid cell boundary mismatch");

    std.debug.print("private JSType shims ({s}): 2/2 symbols, {d} cell kinds passed\n", .{
        if (options.is_bun) "bun" else "home",
        cases.len,
    });
}
