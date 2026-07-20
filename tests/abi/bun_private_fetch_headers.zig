const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    undefined = 0x0a,
    _,

    fn fromRef(value: JSValueRef) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intFromPtr(value.?)))));
    }
};

const ZigString = extern struct { tagged_ptr: usize = 0, len: usize = 0 };
const StringPointer = extern struct { offset: u32, length: u32 };
const FetchHeaders = opaque {};
const PicoSlice = extern struct { ptr: [*c]const u8, len: usize };
const PicoHTTPHeader = extern struct { name: PicoSlice, value: PicoSlice };
const PicoHTTPHeaders = extern struct { ptr: [*c]const PicoHTTPHeader, len: usize };
const FetchHeadersBridgeVisitorV1 = *const fn (?*anyopaque, PicoSlice, PicoSlice) callconv(.c) bool;
const FakeBridgeRequest = extern struct {
    rows: [*c]const PicoHTTPHeader,
    len: usize,
    fail_after: usize,
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;

// Exact declarations consumed by Bun's pinned src/jsc/FetchHeaders.zig.
extern "c" fn WebCore__FetchHeaders__append(*FetchHeaders, *const ZigString, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__cast_(EncodedValue, ?*anyopaque) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__clone(*FetchHeaders, JSContextRef) EncodedValue;
extern "c" fn WebCore__FetchHeaders__cloneThis(*FetchHeaders, JSContextRef) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__copyTo(*FetchHeaders, [*]StringPointer, [*]StringPointer, [*]u8) void;
extern "c" fn WebCore__FetchHeaders__count(*FetchHeaders, *u32, *u32) void;
extern "c" fn WebCore__FetchHeaders__createEmpty() *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createFromH3(*anyopaque) *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createFromPicoHeaders_(?*const anyopaque) *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createFromJS(JSContextRef, EncodedValue) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createFromUWS(*anyopaque) *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createValue(JSContextRef, [*c]const StringPointer, [*c]const StringPointer, *const ZigString, u32) EncodedValue;
extern "c" fn WebCore__FetchHeaders__createValueNotJS(JSContextRef, [*c]const StringPointer, [*c]const StringPointer, *const ZigString, u32) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__deref(*FetchHeaders) void;
extern "c" fn WebCore__FetchHeaders__fastGet_(*FetchHeaders, u8, *ZigString) void;
extern "c" fn WebCore__FetchHeaders__fastHas_(*FetchHeaders, u8) bool;
extern "c" fn WebCore__FetchHeaders__fastRemove_(*FetchHeaders, u8) void;
extern "c" fn WebCore__FetchHeaders__get_(*FetchHeaders, *const ZigString, *ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__has(*FetchHeaders, *const ZigString, JSContextRef) bool;
extern "c" fn WebCore__FetchHeaders__isEmpty(*FetchHeaders) bool;
extern "c" fn WebCore__FetchHeaders__put(*FetchHeaders, u8, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__put_(*FetchHeaders, *const ZigString, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__remove(*FetchHeaders, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__toJS(*FetchHeaders, JSContextRef) EncodedValue;

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

fn zigString(bytes: []const u8) ZigString {
    return .{ .tagged_ptr = @intFromPtr(bytes.ptr), .len = bytes.len };
}

fn picoSlice(bytes: []const u8) PicoSlice {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn visitFakeBridgeRequest(
    raw_request: ?*anyopaque,
    context: ?*anyopaque,
    visitor: FetchHeadersBridgeVisitorV1,
) bool {
    const request: *const FakeBridgeRequest = @ptrCast(@alignCast(raw_request orelse return false));
    if (request.len != 0 and request.rows == null) return false;
    for (request.rows[0..request.len], 0..) |row, index| {
        if (index == request.fail_after) return false;
        if (!visitor(context, row.name, row.value)) return false;
    }
    return request.fail_after >= request.len;
}

export fn ZigJS__FetchHeadersBridge__visitUWSRequestV1(
    raw_request: ?*anyopaque,
    context: ?*anyopaque,
    visitor: FetchHeadersBridgeVisitorV1,
) callconv(.c) bool {
    return visitFakeBridgeRequest(raw_request, context, visitor);
}

export fn ZigJS__FetchHeadersBridge__visitH3RequestV1(
    raw_request: ?*anyopaque,
    context: ?*anyopaque,
    visitor: FetchHeadersBridgeVisitorV1,
) callconv(.c) bool {
    return visitFakeBridgeRequest(raw_request, context, visitor);
}

fn zigStringEquals(actual: ZigString, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    const address = actual.tagged_ptr & ((@as(usize, 1) << 53) - 1);
    if (address == 0 and actual.len != 0) return false;
    if (actual.tagged_ptr & (@as(usize, 1) << 63) != 0) {
        const units: [*]align(1) const u16 = @ptrFromInt(address);
        for (expected, 0..) |byte, index| if (units[index] != byte) return false;
        return true;
    }
    const bytes: [*]const u8 = @ptrFromInt(address);
    return std.mem.eql(u8, bytes[0..actual.len], expected);
}

fn expectGet(headers: *FetchHeaders, context: JSContextRef, name_bytes: []const u8, expected: []const u8) void {
    var name = zigString(name_bytes);
    var output: ZigString = .{};
    WebCore__FetchHeaders__get_(headers, &name, &output, context);
    if (!zigStringEquals(output, expected)) fail("FetchHeaders get mismatch");
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const vm = JSC__JSGlobalObject__vm(context) orelse fail("VM projection failed");

    const headers = WebCore__FetchHeaders__createEmpty();
    defer WebCore__FetchHeaders__deref(headers);
    if (!WebCore__FetchHeaders__isEmpty(headers)) fail("empty FetchHeaders is not empty");

    var accept = zigString("Accept");
    var text = zigString(" text/plain ");
    var json = zigString("application/json");
    WebCore__FetchHeaders__append(headers, &accept, &text, context);
    WebCore__FetchHeaders__append(headers, &accept, &json, context);
    expectGet(headers, context, "accept", "text/plain, application/json");

    var cookie = zigString("Cookie");
    var cookie_a = zigString("a=1");
    var cookie_b = zigString("b=2");
    WebCore__FetchHeaders__append(headers, &cookie, &cookie_a, context);
    WebCore__FetchHeaders__append(headers, &cookie, &cookie_b, context);
    expectGet(headers, context, "cookie", "a=1; b=2");

    var set_cookie = zigString("Set-Cookie");
    WebCore__FetchHeaders__append(headers, &set_cookie, &cookie_a, context);
    WebCore__FetchHeaders__append(headers, &set_cookie, &cookie_b, context);
    expectGet(headers, context, "set-cookie", "a=1, b=2");

    var content_type_value = zigString("text/html");
    WebCore__FetchHeaders__put(headers, 25, &content_type_value, context);
    var custom_name = zigString("x-custom");
    var custom_value = zigString("fixture");
    WebCore__FetchHeaders__put_(headers, &custom_name, &custom_value, context);
    if (!WebCore__FetchHeaders__fastHas_(headers, 25) or !WebCore__FetchHeaders__has(headers, &custom_name, context))
        fail("FetchHeaders has mismatch");
    var fast_value: ZigString = .{};
    WebCore__FetchHeaders__fastGet_(headers, 25, &fast_value);
    if (!zigStringEquals(fast_value, "text/html")) fail("FetchHeaders fastGet mismatch");

    var count: u32 = 0;
    var buffer_length: u32 = 0;
    WebCore__FetchHeaders__count(headers, &count, &buffer_length);
    if (count != 6 or buffer_length == 0) fail("FetchHeaders count mismatch");
    const names = std.heap.page_allocator.alloc(StringPointer, count) catch fail("names allocation failed");
    defer std.heap.page_allocator.free(names);
    const values = std.heap.page_allocator.alloc(StringPointer, count) catch fail("values allocation failed");
    defer std.heap.page_allocator.free(values);
    const buffer = std.heap.page_allocator.alloc(u8, buffer_length) catch fail("buffer allocation failed");
    defer std.heap.page_allocator.free(buffer);
    WebCore__FetchHeaders__copyTo(headers, names.ptr, values.ptr, buffer.ptr);
    if (!std.mem.eql(u8, buffer[names[0].offset .. names[0].offset + names[0].length], "Accept") or
        !std.mem.eql(u8, buffer[names[count - 2].offset .. names[count - 2].offset + names[count - 2].length], "Set-Cookie") or
        !std.mem.eql(u8, buffer[values[count - 1].offset .. values[count - 1].offset + values[count - 1].length], "b=2"))
        fail("FetchHeaders copyTo ordering mismatch");

    const js_value = WebCore__FetchHeaders__toJS(headers, context);
    if (js_value == .empty or WebCore__FetchHeaders__cast_(js_value, vm) != headers or
        WebCore__FetchHeaders__toJS(headers, context) != js_value)
        fail("FetchHeaders JS wrapper identity mismatch");
    if (WebCore__FetchHeaders__cast_(evaluate(context, "Object.create(Headers.prototype)"), vm) != null)
        fail("FetchHeaders accepted a prototype-spoofed object");

    const js_created_value = evaluate(context, "new Headers([['Accept','a'],['accept','b'],['Set-Cookie','x'],['Set-Cookie','y']])");
    const js_created = WebCore__FetchHeaders__cast_(js_created_value, vm) orelse fail("JS Headers cast failed");
    expectGet(js_created, context, "accept", "a, b");
    var js_count: u32 = 0;
    var js_length: u32 = 0;
    WebCore__FetchHeaders__count(js_created, &js_count, &js_length);
    if (js_count != 3) fail("JS/native FetchHeaders storage diverged");

    const cloned_native = WebCore__FetchHeaders__cloneThis(headers, context) orelse fail("cloneThis failed");
    defer WebCore__FetchHeaders__deref(cloned_native);
    WebCore__FetchHeaders__fastRemove_(cloned_native, 25);
    if (WebCore__FetchHeaders__fastHas_(cloned_native, 25) or !WebCore__FetchHeaders__fastHas_(headers, 25))
        fail("FetchHeaders clone independence mismatch");
    const cloned_js = WebCore__FetchHeaders__clone(headers, context);
    if (cloned_js == .empty or WebCore__FetchHeaders__cast_(cloned_js, vm) == null)
        fail("FetchHeaders JS clone failed");

    const packed_bytes = "Accepttext/plainSet-Cookiea=1Set-Cookieb=2";
    var packed_string = zigString(packed_bytes);
    const packed_names = [_]StringPointer{
        .{ .offset = 0, .length = 6 },
        .{ .offset = 16, .length = 10 },
        .{ .offset = 29, .length = 10 },
    };
    const packed_values = [_]StringPointer{
        .{ .offset = 6, .length = 10 },
        .{ .offset = 26, .length = 3 },
        .{ .offset = 39, .length = 3 },
    };
    const packed_headers = WebCore__FetchHeaders__createValueNotJS(context, &packed_names, &packed_values, &packed_string, @intCast(packed_names.len)) orelse
        fail("FetchHeaders createValueNotJS failed");
    defer WebCore__FetchHeaders__deref(packed_headers);
    expectGet(packed_headers, context, "set-cookie", "a=1, b=2");
    if (WebCore__FetchHeaders__createValue(context, &packed_names, &packed_values, &packed_string, @intCast(packed_names.len)) == .empty)
        fail("FetchHeaders createValue failed");

    const from_js = WebCore__FetchHeaders__createFromJS(context, evaluate(context, "[['A','1'],['a','2']]")) orelse
        fail("FetchHeaders createFromJS failed");
    defer WebCore__FetchHeaders__deref(from_js);
    expectGet(from_js, context, "a", "1, 2");
    if (WebCore__FetchHeaders__createFromJS(context, .undefined) != null)
        fail("FetchHeaders undefined initializer was not empty");
    _ = WebCore__FetchHeaders__createFromJS(context, evaluate(context, "[['bad name','x']]"));
    if (!JSGlobalObject__hasException(context)) fail("FetchHeaders invalid initializer did not throw");
    JSGlobalObject__clearException(context);

    if (@sizeOf(PicoSlice) != 2 * @sizeOf(usize) or
        @sizeOf(PicoHTTPHeader) != 4 * @sizeOf(usize) or
        @sizeOf(PicoHTTPHeaders) != 2 * @sizeOf(usize) or
        @offsetOf(PicoHTTPHeader, "value") != 2 * @sizeOf(usize) or
        @offsetOf(PicoHTTPHeaders, "len") != @sizeOf(usize))
        fail("PicoHeaders ABI layout mismatch");
    var pico_last = [_]u8{ 'l', 'a', 's', 't' };
    const pico_rows = [_]PicoHTTPHeader{
        .{ .name = picoSlice("Accept"), .value = picoSlice(" one ") },
        .{ .name = picoSlice("accept"), .value = picoSlice("two") },
        .{ .name = picoSlice("X-Raw"), .value = picoSlice("first") },
        .{ .name = picoSlice("x-raw"), .value = picoSlice(&pico_last) },
        .{ .name = picoSlice("Cookie"), .value = picoSlice("a=1") },
        .{ .name = picoSlice("cookie"), .value = picoSlice("b=2") },
        .{ .name = picoSlice("Set-Cookie"), .value = picoSlice("a=1") },
        .{ .name = picoSlice("set-cookie"), .value = picoSlice("b=2") },
        .{ .name = picoSlice(""), .value = picoSlice("ignored") },
        .{ .name = picoSlice("X-Empty"), .value = picoSlice("") },
    };
    const pico_input = PicoHTTPHeaders{ .ptr = &pico_rows, .len = pico_rows.len };
    const pico_headers = WebCore__FetchHeaders__createFromPicoHeaders_(&pico_input);
    defer WebCore__FetchHeaders__deref(pico_headers);
    pico_last[0] = 'X';
    expectGet(pico_headers, context, "accept", " one , two");
    expectGet(pico_headers, context, "x-raw", "last");
    expectGet(pico_headers, context, "cookie", "a=1; b=2");
    expectGet(pico_headers, context, "set-cookie", "a=1, b=2");
    var pico_count: u32 = 0;
    var pico_length: u32 = 0;
    WebCore__FetchHeaders__count(pico_headers, &pico_count, &pico_length);
    if (pico_count != 5 or pico_length == 0) fail("PicoHeaders import row semantics mismatch");
    const null_pico = WebCore__FetchHeaders__createFromPicoHeaders_(null);
    defer WebCore__FetchHeaders__deref(null_pico);
    if (!WebCore__FetchHeaders__isEmpty(null_pico)) fail("null PicoHeaders input was not rejected");
    const invalid_pico = PicoHTTPHeaders{ .ptr = null, .len = 1 };
    const rejected_pico = WebCore__FetchHeaders__createFromPicoHeaders_(&invalid_pico);
    defer WebCore__FetchHeaders__deref(rejected_pico);
    if (!WebCore__FetchHeaders__isEmpty(rejected_pico)) fail("invalid PicoHeaders span was not rejected");
    var misaligned_storage: [@sizeOf(PicoHTTPHeaders) + 1]u8 align(@alignOf(PicoHTTPHeaders)) = undefined;
    const misaligned_pico = WebCore__FetchHeaders__createFromPicoHeaders_(&misaligned_storage[1]);
    defer WebCore__FetchHeaders__deref(misaligned_pico);
    if (!WebCore__FetchHeaders__isEmpty(misaligned_pico)) fail("misaligned PicoHeaders record was not rejected");

    var bridge_last = [_]u8{ 'l', 'a', 's', 't' };
    const uws_rows = [_]PicoHTTPHeader{
        .{ .name = picoSlice("Accept"), .value = picoSlice(" raw ") },
        .{ .name = picoSlice("accept"), .value = picoSlice("two") },
        .{ .name = picoSlice("X-UWS"), .value = picoSlice("first") },
        .{ .name = picoSlice("x-uws"), .value = picoSlice(&bridge_last) },
        .{ .name = picoSlice("X-Empty"), .value = picoSlice("") },
    };
    const uws_request = FakeBridgeRequest{ .rows = &uws_rows, .len = uws_rows.len, .fail_after = std.math.maxInt(usize) };
    const uws_headers = WebCore__FetchHeaders__createFromUWS(@constCast(&uws_request));
    defer WebCore__FetchHeaders__deref(uws_headers);
    bridge_last[0] = 'X';
    expectGet(uws_headers, context, "accept", " raw , two");
    expectGet(uws_headers, context, "x-uws", "last");
    var empty_name = zigString("X-Empty");
    if (!WebCore__FetchHeaders__has(uws_headers, &empty_name, context)) fail("UWS bridge dropped an empty parsed value");

    const h3_rows = [_]PicoHTTPHeader{
        .{ .name = picoSlice(":method"), .value = picoSlice("GET") },
        .{ .name = picoSlice("X-H3"), .value = picoSlice("one") },
        .{ .name = picoSlice("x-h3"), .value = picoSlice("two") },
    };
    const h3_request = FakeBridgeRequest{ .rows = &h3_rows, .len = h3_rows.len, .fail_after = std.math.maxInt(usize) };
    const h3_headers = WebCore__FetchHeaders__createFromH3(@constCast(&h3_request));
    defer WebCore__FetchHeaders__deref(h3_headers);
    expectGet(h3_headers, context, "x-h3", "two");
    var h3_count: u32 = 0;
    var h3_length: u32 = 0;
    WebCore__FetchHeaders__count(h3_headers, &h3_count, &h3_length);
    if (h3_count != 2 or h3_length == 0) fail("H3 bridge pseudo-header or duplicate semantics mismatch");

    const failing_request = FakeBridgeRequest{ .rows = &uws_rows, .len = uws_rows.len, .fail_after = 1 };
    const failed_headers = WebCore__FetchHeaders__createFromUWS(@constCast(&failing_request));
    defer WebCore__FetchHeaders__deref(failed_headers);
    if (!WebCore__FetchHeaders__isEmpty(failed_headers)) fail("aborted UWS bridge import was not atomic");

    WebCore__FetchHeaders__remove(headers, &custom_name, context);
    if (WebCore__FetchHeaders__has(headers, &custom_name, context)) fail("FetchHeaders remove mismatch");
    std.debug.print("Bun private FetchHeaders: 24/24 symbols linked; runtime matrix passed\n", .{});
}
