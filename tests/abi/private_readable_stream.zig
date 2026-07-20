const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;
const PrivateCallFrame = opaque {};

const EncodedValue = enum(i64) {
    empty = 0,
    null = 2,
    deleted = 4,
    false = 6,
    true = 7,
    undefined = 10,
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
};

const JSHostFn = fn (JSContextRef, *PrivateCallFrame) callconv(.c) EncodedValue;

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSC__JSGlobalObject__drainMicrotasks(JSContextRef) usize;
extern "c" fn JSC__JSValue___then(EncodedValue, JSContextRef, EncodedValue, ?*const JSHostFn, ?*const JSHostFn) void;
extern "c" fn JSC__JSValue__isStrictEqual(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__isInstanceOf(EncodedValue, JSContextRef, EncodedValue) bool;
extern "c" fn JSC__JSValue__getDirectIndex(EncodedValue, JSContextRef, u32) EncodedValue;
extern "c" fn JSC__JSValue__getIfPropertyExistsImpl(EncodedValue, JSContextRef, [*]const u8, u32) EncodedValue;
extern "c" fn Bun__JSValue__toNumber(EncodedValue, JSContextRef) f64;

extern "c" fn ZigGlobalObject__readableStreamToArrayBuffer(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn ZigGlobalObject__readableStreamToBytes(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn ZigGlobalObject__readableStreamToText(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn ZigGlobalObject__readableStreamToJSON(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn ZigGlobalObject__readableStreamToFormData(JSContextRef, EncodedValue, EncodedValue) EncodedValue;
extern "c" fn ZigGlobalObject__readableStreamToBlob(JSContextRef, EncodedValue) EncodedValue;

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

const Outcome = struct {
    expected_global: JSContextRef = null,
    fulfilled: usize = 0,
    rejected: usize = 0,
    value: EncodedValue = .empty,
};

var outcome = Outcome{};

fn callFrameSlots(frame: *PrivateCallFrame) [*]const EncodedValue {
    return @ptrCast(@alignCast(frame));
}

fn capture(global: JSContextRef, frame: *PrivateCallFrame, was_fulfilled: bool) EncodedValue {
    const slots = callFrameSlots(frame);
    const argument_bits: u64 = @bitCast(@intFromEnum(slots[4]));
    if (global != outcome.expected_global or @as(u32, @truncate(argument_bits)) != 3)
        fail("ReadableStream Promise callback frame mismatch");
    outcome.value = slots[6];
    if (was_fulfilled)
        outcome.fulfilled += 1
    else
        outcome.rejected += 1;
    return .undefined;
}

fn fulfilled(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    return capture(global, frame, true);
}

fn rejected(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    return capture(global, frame, false);
}

fn settle(context: JSContextRef, result: EncodedValue, expect_rejected: bool) EncodedValue {
    if (result == .empty) fail("ReadableStream consumer returned empty");
    outcome = .{ .expected_global = context };
    JSC__JSValue___then(result, context, EncodedValue.fromInt32(405), fulfilled, rejected);
    _ = JSC__JSGlobalObject__drainMicrotasks(context);
    if (expect_rejected) {
        if (outcome.fulfilled != 0 or outcome.rejected != 1) fail("ReadableStream Promise did not reject once");
    } else if (outcome.fulfilled != 1 or outcome.rejected != 0) {
        fail("ReadableStream Promise did not fulfill once");
    }
    return outcome.value;
}

fn expectNumber(context: JSContextRef, value: EncodedValue, expected: f64) void {
    if (Bun__JSValue__toNumber(value, context) != expected) fail("ReadableStream numeric result mismatch");
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);

    const text_stream = evaluate(context,
        \\new ReadableStream({ pull(c) {
        \\  return Promise.resolve().then(function () {
        \\    c.enqueue(new Uint8Array([239, 187]));
        \\    c.enqueue(new Uint8Array([191, 104, 105]));
        \\    c.close();
        \\  });
        \\} })
    );
    const text = settle(context, ZigGlobalObject__readableStreamToText(context, text_stream), false);
    if (!JSC__JSValue__isStrictEqual(text, evaluate(context, "'hi'"), context))
        fail("ReadableStream text result mismatch");

    const bytes_stream = evaluate(context,
        \\new ReadableStream({ start(c) { c.enqueue("ab"); c.enqueue(new Uint8Array([99])); c.close(); } })
    );
    const bytes = settle(context, ZigGlobalObject__readableStreamToBytes(context, bytes_stream), false);
    expectNumber(context, JSC__JSValue__getIfPropertyExistsImpl(bytes, context, "0".ptr, 1), 'a');
    expectNumber(context, JSC__JSValue__getIfPropertyExistsImpl(bytes, context, "1".ptr, 1), 'b');
    expectNumber(context, JSC__JSValue__getIfPropertyExistsImpl(bytes, context, "2".ptr, 1), 'c');

    const buffer_stream = evaluate(context,
        \\new ReadableStream({ start(c) { c.enqueue(new Uint8Array([1, 2, 3])); c.close(); } })
    );
    const buffer = settle(context, ZigGlobalObject__readableStreamToArrayBuffer(context, buffer_stream), false);
    expectNumber(context, JSC__JSValue__getIfPropertyExistsImpl(buffer, context, "byteLength".ptr, 10), 3);

    const json_stream = evaluate(context,
        \\new ReadableStream({ start(c) { c.enqueue('{"issue":405}'); c.close(); } })
    );
    const json = settle(context, ZigGlobalObject__readableStreamToJSON(context, json_stream), false);
    expectNumber(context, JSC__JSValue__getIfPropertyExistsImpl(json, context, "issue".ptr, 5), 405);

    const blob_stream = evaluate(context,
        \\new ReadableStream({ start(c) { c.enqueue("blob"); c.close(); } })
    );
    const blob = settle(context, ZigGlobalObject__readableStreamToBlob(context, blob_stream), false);
    if (!JSC__JSValue__isInstanceOf(blob, context, evaluate(context, "Blob")))
        fail("ReadableStream Blob result mismatch");

    const form_stream = evaluate(context,
        \\new ReadableStream({ start(c) { c.enqueue("a=1&b=two"); c.close(); } })
    );
    const form = settle(context, ZigGlobalObject__readableStreamToFormData(context, form_stream, .undefined), false);
    if (!JSC__JSValue__isInstanceOf(form, context, evaluate(context, "FormData")))
        fail("ReadableStream FormData result mismatch");

    const locked_stream = evaluate(context,
        \\globalThis.__lockedStream405 = new ReadableStream({}); __lockedStream405.getReader(); __lockedStream405
    );
    _ = settle(context, ZigGlobalObject__readableStreamToText(context, locked_stream), true);

    std.debug.print("Private ReadableStream: 6/6 symbols linked; runtime matrix passed\n", .{});
}
