const std = @import("std");

const JSContextGroupRef = ?*anyopaque;
const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    undefined = 0x0a,
    null = 0x02,
    true = 0x07,
    false = 0x06,
    _,

    fn fromBits(bits: u64) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(bits)));
    }

    fn fromDouble(number: f64) EncodedValue {
        return fromBits(@as(u64, @bitCast(number)) -% 0x0001_0000_0000_0000);
    }

    fn fromRef(value: JSValueRef) EncodedValue {
        return fromBits(@intFromPtr(value.?));
    }
};

const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};
const ZigString = extern struct { tagged_ptr: usize, len: usize };
const BunStringImpl = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*anyopaque,
};
const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringImpl,
};

extern "c" fn JSContextGroupCreate() JSContextGroupRef;
extern "c" fn JSContextGroupRelease(JSContextGroupRef) void;
extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextCreateInGroup(JSContextGroupRef, ?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSC__JSValue__isStrictEqual(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn BunString__toJS(JSContextRef, *const BunString) EncodedValue;
extern "c" fn Bun__WTFStringImpl__deref(?*anyopaque) void;
extern "c" fn Bun__ErrorCode__determineSpecificType(JSContextRef, EncodedValue) BunString;

fn fail(message: []const u8) noreturn {
    std.debug.panic("private ErrorCode fixture: {s}", .{message});
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) EncodedValue {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (exception != null or result == null) fail("script evaluation failed");
    return EncodedValue.fromRef(result);
}

fn expectDiagnostic(context: JSContextRef, input: EncodedValue, expected_source: [*:0]const u8) void {
    const output = Bun__ErrorCode__determineSpecificType(context, input);
    if (output.tag != .wtf_string_impl or output.value.wtf_string_impl == null)
        fail("diagnostic did not return an owned WTFStringImpl");
    defer Bun__WTFStringImpl__deref(output.value.wtf_string_impl);
    const projected = BunString__toJS(context, &output);
    if (projected == .empty or !JSC__JSValue__isStrictEqual(projected, evaluate(context, expected_source), context))
        fail("diagnostic text mismatch");
}

pub fn main() void {
    const group = JSContextGroupCreate() orelse fail("context group creation failed");
    defer JSContextGroupRelease(group);
    const context = JSGlobalContextCreateInGroup(group, null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const sibling = JSGlobalContextCreateInGroup(group, null) orelse fail("sibling context creation failed");
    defer JSGlobalContextRelease(sibling);

    expectDiagnostic(context, .null, "'null'");
    expectDiagnostic(context, .undefined, "'undefined'");
    expectDiagnostic(context, .true, "'type boolean (true)'");
    expectDiagnostic(context, EncodedValue.fromDouble(std.math.nan(f64)), "'type number (NaN)'");
    expectDiagnostic(context, evaluate(context, "123456789012345678901234567890n"), "'type bigint (123456789012345678901234567890n)'");
    expectDiagnostic(context, evaluate(context, "Symbol('fixture')"), "'type symbol (Symbol(fixture))'");
    expectDiagnostic(context, evaluate(context, "(function fixtureName(){})"), "'function fixtureName'");
    expectDiagnostic(context, evaluate(context, "\"a'b\\\"c\""), "`type string (\"a'b\\\\\"c\")`");
    expectDiagnostic(sibling, evaluate(context, "new (class SharedWidget {})"), "'an instance of SharedWidget'");

    const abrupt = Bun__ErrorCode__determineSpecificType(
        context,
        evaluate(context, "({ get constructor() { throw 393; } })"),
    );
    if (abrupt.tag != .dead or !JSGlobalObject__hasException(context))
        fail("observable constructor throw was not failure-atomic");
    JSGlobalObject__clearException(context);

    const foreign = JSGlobalContextCreate(null) orelse fail("foreign context creation failed");
    defer JSGlobalContextRelease(foreign);
    const rejected = Bun__ErrorCode__determineSpecificType(context, evaluate(foreign, "({})"));
    if (rejected.tag != .dead or !JSGlobalObject__hasException(context))
        fail("foreign-VM value was not rejected");
    JSGlobalObject__clearException(context);
}
