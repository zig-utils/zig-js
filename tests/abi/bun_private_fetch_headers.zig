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
const FetchHeadersBridgeVisitRequestV1 = *const fn (?*anyopaque, ?*anyopaque, FetchHeadersBridgeVisitorV1) callconv(.c) bool;
const FetchHeadersBridgeRowV1 = extern struct { name: PicoSlice, value: PicoSlice };
const FetchHeadersBridgeWriteResponseV1 = *const fn (?*anyopaque, i32, [*c]const FetchHeadersBridgeRowV1, usize) callconv(.c) bool;
const FetchHeadersBridgeV1 = extern struct {
    abi_version: u32,
    struct_size: u32,
    visit_uws_request: ?FetchHeadersBridgeVisitRequestV1,
    visit_h3_request: ?FetchHeadersBridgeVisitRequestV1,
    write_response: ?FetchHeadersBridgeWriteResponseV1,
};
const FakeBridgeRequest = extern struct {
    rows: [*c]const PicoHTTPHeader,
    len: usize,
    fail_after: usize,
};
const CapturedResponseHeader = struct {
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    value: [128]u8 = @splat(0),
    value_len: usize = 0,
};
const FakeBridgeResponse = struct {
    rows: [16]CapturedResponseHeader = @splat(.{}),
    count: usize = 0,
    state: u8 = 0,
    marks: usize = 0,
    kind: i32 = -1,
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn ZigJS__FetchHeadersBridge__installV1(?*const FetchHeadersBridgeV1) bool;

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
extern "c" fn WebCore__FetchHeaders__toUWSResponse(*FetchHeaders, i32, ?*anyopaque) void;

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

export fn ZigJS__FetchHeadersBridge__writeResponseV1(
    raw_response: ?*anyopaque,
    kind: i32,
    rows: [*c]const FetchHeadersBridgeRowV1,
    count: usize,
) callconv(.c) bool {
    const response: *FakeBridgeResponse = @ptrCast(@alignCast(raw_response orelse return false));
    if (kind < 0 or kind > 2 or count > response.rows.len or (count != 0 and rows == null)) return false;
    response.* = .{ .kind = kind };
    for (rows[0..count], 0..) |row, index| {
        if (row.name.len > response.rows[index].name.len or row.value.len > response.rows[index].value.len or
            (row.name.len != 0 and row.name.ptr == null) or (row.value.len != 0 and row.value.ptr == null)) return false;
        if (row.name.len != 0) @memcpy(response.rows[index].name[0..row.name.len], row.name.ptr[0..row.name.len]);
        if (row.value.len != 0) @memcpy(response.rows[index].value[0..row.value.len], row.value.ptr[0..row.value.len]);
        response.rows[index].name_len = row.name.len;
        response.rows[index].value_len = row.value.len;
        const name = response.rows[index].name[0..row.name.len];
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (response.state & 1 == 0) {
                response.state |= 1;
                response.marks += 1;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "date")) {
            response.state |= 2;
        } else if (kind != 2 and std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            response.state |= 4;
        }
        response.count += 1;
    }
    return true;
}

fn capturedName(response: *const FakeBridgeResponse, index: usize) []const u8 {
    return response.rows[index].name[0..response.rows[index].name_len];
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

    const invalid_bridge = FetchHeadersBridgeV1{
        .abi_version = 2,
        .struct_size = @sizeOf(FetchHeadersBridgeV1),
        .visit_uws_request = ZigJS__FetchHeadersBridge__visitUWSRequestV1,
        .visit_h3_request = ZigJS__FetchHeadersBridge__visitH3RequestV1,
        .write_response = ZigJS__FetchHeadersBridge__writeResponseV1,
    };
    if (ZigJS__FetchHeadersBridge__installV1(&invalid_bridge)) fail("invalid FetchHeaders bridge version was accepted");
    const invalid_bridge_size = FetchHeadersBridgeV1{
        .abi_version = 1,
        .struct_size = @sizeOf(FetchHeadersBridgeV1) - 1,
        .visit_uws_request = ZigJS__FetchHeadersBridge__visitUWSRequestV1,
        .visit_h3_request = ZigJS__FetchHeadersBridge__visitH3RequestV1,
        .write_response = ZigJS__FetchHeadersBridge__writeResponseV1,
    };
    if (ZigJS__FetchHeadersBridge__installV1(&invalid_bridge_size)) fail("invalid FetchHeaders bridge size was accepted");
    const bridge = FetchHeadersBridgeV1{
        .abi_version = 1,
        .struct_size = @sizeOf(FetchHeadersBridgeV1),
        .visit_uws_request = ZigJS__FetchHeadersBridge__visitUWSRequestV1,
        .visit_h3_request = ZigJS__FetchHeadersBridge__visitH3RequestV1,
        .write_response = ZigJS__FetchHeadersBridge__writeResponseV1,
    };
    if (!ZigJS__FetchHeadersBridge__installV1(&bridge)) fail("FetchHeaders bridge installation failed");
    defer _ = ZigJS__FetchHeadersBridge__installV1(null);

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

    const response_headers = WebCore__FetchHeaders__createEmpty();
    defer WebCore__FetchHeaders__deref(response_headers);
    var response_x_name = zigString("X-Response");
    var response_x_value = zigString("x");
    var response_date_name = zigString("Date");
    var response_date_value = zigString("today");
    var response_length_name = zigString("Content-Length");
    var response_length_value = zigString("3");
    var response_transfer_name = zigString("Transfer-Encoding");
    var response_transfer_value = zigString("chunked");
    WebCore__FetchHeaders__append(response_headers, &response_x_name, &response_x_value, context);
    WebCore__FetchHeaders__append(response_headers, &set_cookie, &cookie_a, context);
    WebCore__FetchHeaders__append(response_headers, &response_date_name, &response_date_value, context);
    WebCore__FetchHeaders__append(response_headers, &set_cookie, &cookie_b, context);
    WebCore__FetchHeaders__append(response_headers, &response_length_name, &response_length_value, context);
    WebCore__FetchHeaders__append(response_headers, &response_transfer_name, &response_transfer_value, context);

    var tcp_response = FakeBridgeResponse{};
    WebCore__FetchHeaders__toUWSResponse(response_headers, 0, &tcp_response);
    if (tcp_response.kind != 0 or tcp_response.count != 6 or tcp_response.state != 7 or tcp_response.marks != 1 or
        !std.mem.eql(u8, capturedName(&tcp_response, 0), "Set-Cookie") or
        !std.mem.eql(u8, capturedName(&tcp_response, 1), "Set-Cookie") or
        !std.mem.eql(u8, capturedName(&tcp_response, 2), "Date") or
        !std.mem.eql(u8, capturedName(&tcp_response, 3), "Content-Length") or
        !std.mem.eql(u8, capturedName(&tcp_response, 4), "Transfer-Encoding") or
        !std.mem.eql(u8, capturedName(&tcp_response, 5), "X-Response"))
        fail("TCP response bridge order/state mismatch");
    var ssl_response = FakeBridgeResponse{};
    WebCore__FetchHeaders__toUWSResponse(response_headers, 1, &ssl_response);
    if (ssl_response.kind != 1 or ssl_response.count != 6 or ssl_response.state != 7 or ssl_response.marks != 1)
        fail("SSL response bridge state mismatch");
    var h3_response = FakeBridgeResponse{};
    WebCore__FetchHeaders__toUWSResponse(response_headers, 2, &h3_response);
    if (h3_response.kind != 2 or h3_response.count != 6 or h3_response.state != 3 or h3_response.marks != 1)
        fail("H3 response bridge state mismatch");
    var unknown_response = FakeBridgeResponse{};
    WebCore__FetchHeaders__toUWSResponse(response_headers, 3, &unknown_response);
    WebCore__FetchHeaders__toUWSResponse(response_headers, 0, null);
    if (unknown_response.count != 0) fail("unknown response kind reached the bridge");

    WebCore__FetchHeaders__remove(headers, &custom_name, context);
    if (WebCore__FetchHeaders__has(headers, &custom_name, context)) fail("FetchHeaders remove mismatch");
    std.debug.print("Bun private FetchHeaders: 25/25 symbols linked; runtime matrix passed\n", .{});
}
