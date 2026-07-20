const std = @import("std");

const JSGlobalObject = opaque {};
const InspectorSession = opaque {};
const CallFrame = opaque {};
const MessageCallback = *const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;

const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};
const ZigString = extern struct { tagged_ptr: usize = 0, len: usize = 0 };
const BunStringImpl = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*anyopaque,
};
const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringImpl,

    fn static(bytes: []const u8) BunString {
        return .{
            .tag = .static_zig_string,
            .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(bytes.ptr), .len = bytes.len } },
        };
    }

    fn empty() BunString {
        return .{ .tag = .empty, .value = .{ .zig_string = .{} } };
    }
};

const ZigStackFramePosition = extern struct {
    line: c_int,
    column: c_int,
    line_start_byte: c_int,
};
const ZigStackFrameCode = enum(u8) {
    none = 0,
    eval = 1,
    module = 2,
    function = 3,
    global = 4,
    wasm = 5,
    constructor = 6,
};
const ZigStackFrame = extern struct {
    function_name: BunString,
    source_url: BunString,
    position: ZigStackFramePosition,
    code_type: ZigStackFrameCode,
    is_async: bool,
    remapped: bool = false,
    jsc_stack_frame_index: i32 = -1,
};
const ZigStackTrace = extern struct {
    source_lines_ptr: [*c]BunString,
    source_lines_numbers: [*c]i32,
    source_lines_len: u8,
    source_lines_to_collect: u8,
    frames_ptr: [*c]ZigStackFrame,
    frames_len: u8,
    frames_cap: u8,
    referenced_source_provider: ?*anyopaque = null,
};
const ZigException = extern struct {
    type: u8 = 254,
    runtime_type: u16 = 0,
    errno: c_int = 0,
    syscall: BunString = BunString.empty(),
    system_code: BunString = BunString.empty(),
    path: BunString = BunString.empty(),
    name: BunString = BunString.empty(),
    message: BunString = BunString.empty(),
    stack: ZigStackTrace,
    exception: ?*anyopaque = null,
    remapped: bool = false,
    fd: i32 = -1,
    browser_url: BunString = BunString.empty(),
};
const TestType = enum(u8) { @"test" = 0, describe = 1 };
const TestStatus = enum(u8) {
    pass = 0,
    fail = 1,
    timeout = 2,
    skip = 3,
    todo = 4,
    skipped_because_label = 5,
};
const HTTPMethod = enum(u8) {
    acl = 0,
    bind = 1,
    checkout = 2,
    connect = 3,
    copy = 4,
    delete = 5,
    get = 6,
    head = 7,
    link = 8,
    lock = 9,
    m_search = 10,
    merge = 11,
    mkactivity = 12,
    mkaddressbook = 13,
    mkcalendar = 14,
    mkcol = 15,
    move = 16,
    notify = 17,
    options = 18,
    patch = 19,
    post = 20,
    propfind = 21,
    proppatch = 22,
    purge = 23,
    put = 24,
    query = 25,
    rebind = 26,
    report = 27,
    search = 28,
    source = 29,
    subscribe = 30,
    trace = 31,
    unbind = 32,
    unlink = 33,
    unlock = 34,
    unsubscribe = 35,
};

extern "c" fn JSGlobalContextCreate(global_class: ?*anyopaque) ?*JSGlobalObject;
extern "c" fn JSGlobalContextRelease(global: ?*JSGlobalObject) void;
extern "c" fn JSGlobalContextSetInspectable(global: ?*JSGlobalObject, inspectable: bool) void;
extern "c" fn ZJSInspectorSessionCreate(
    global: ?*JSGlobalObject,
    callback: MessageCallback,
    user_data: ?*anyopaque,
) ?*InspectorSession;
extern "c" fn ZJSInspectorSessionDispatch(
    session: ?*InspectorSession,
    message: [*]const u8,
    message_len: usize,
) bool;
extern "c" fn ZJSInspectorSessionRelease(session: ?*InspectorSession) void;
extern "c" fn Bun__LifecycleAgentReportReload(agent: *InspectorSession) void;
extern "c" fn Bun__LifecycleAgentReportError(agent: *InspectorSession, exception: *ZigException) void;
extern "c" fn Bun__LifecycleAgentPreventExit(agent: *InspectorSession) void;
extern "c" fn Bun__LifecycleAgentStopPreventingExit(agent: *InspectorSession) void;
extern "c" fn Bun__TestReporterAgentReportTestFound(
    agent: *InspectorSession,
    call_frame: *CallFrame,
    test_id: c_int,
    name: *BunString,
    item_type: TestType,
    parent_id: c_int,
) void;
extern "c" fn Bun__TestReporterAgentReportTestFoundWithLocation(
    agent: *InspectorSession,
    test_id: c_int,
    name: *BunString,
    item_type: TestType,
    parent_id: c_int,
    source_url: *BunString,
    line: c_int,
) void;
extern "c" fn Bun__TestReporterAgentReportTestStart(agent: *InspectorSession, test_id: c_int) void;
extern "c" fn Bun__TestReporterAgentReportTestEnd(
    agent: *InspectorSession,
    test_id: c_int,
    status: TestStatus,
    elapsed: f64,
) void;
extern "c" fn Bun__HTTPServerAgent__notifyRequestWillBeSent(
    agent: *InspectorSession,
    request_id: c_int,
    server_id: c_int,
    route_id: c_int,
    url: *const BunString,
    full_url: *const BunString,
    method: HTTPMethod,
    headers_json: *const BunString,
    params_json: *const BunString,
    has_body: bool,
    timestamp: f64,
) void;
extern "c" fn Bun__HTTPServerAgent__notifyResponseReceived(
    agent: *InspectorSession,
    request_id: c_int,
    server_id: c_int,
    status_code: i32,
    status_text: *const BunString,
    headers_json: *const BunString,
    has_body: bool,
    timestamp: f64,
) void;
extern "c" fn Bun__HTTPServerAgent__notifyBodyChunkReceived(
    agent: *InspectorSession,
    request_id: c_int,
    server_id: c_int,
    flags: i32,
    chunk: *const BunString,
    timestamp: f64,
) void;
extern "c" fn Bun__HTTPServerAgent__notifyRequestFinished(
    agent: *InspectorSession,
    request_id: c_int,
    server_id: c_int,
    timestamp: f64,
    duration: f64,
) void;
extern "c" fn Bun__HTTPServerAgent__notifyRequestHandlerException(
    agent: *InspectorSession,
    request_id: c_int,
    server_id: c_int,
    message: *const BunString,
    url: *const BunString,
    line: i32,
    timestamp: f64,
) void;

const Capture = struct {
    bytes: [32 * 1024]u8 = undefined,
    len: usize = 0,

    fn receive(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        if (self.len + message_len + 1 > self.bytes.len) @panic("inspector capture overflow");
        @memcpy(self.bytes[self.len .. self.len + message_len], message[0..message_len]);
        self.len += message_len;
        self.bytes[self.len] = '\n';
        self.len += 1;
    }

    fn containsFrom(self: *const @This(), start: usize, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.bytes[start..self.len], needle) != null;
    }
};

fn dispatch(session: *InspectorSession, message: []const u8) !void {
    if (!ZJSInspectorSessionDispatch(session, message.ptr, message.len))
        return error.InspectorDispatchFailed;
}

pub fn main() !void {
    const context = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(context);
    JSGlobalContextSetInspectable(context, true);

    var capture: Capture = .{};
    const session = ZJSInspectorSessionCreate(context, Capture.receive, &capture) orelse
        return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(session);

    const disabled_before_enable = capture.len;
    Bun__LifecycleAgentReportReload(session);
    Bun__TestReporterAgentReportTestStart(session, 1);
    try std.testing.expectEqual(disabled_before_enable, capture.len);

    try dispatch(session, "{\"id\":1,\"method\":\"Schema.getDomains\"}");
    try std.testing.expect(capture.containsFrom(0, "LifecycleReporter"));
    try std.testing.expect(capture.containsFrom(0, "TestReporter"));
    try dispatch(session, "{\"id\":2,\"method\":\"LifecycleReporter.enable\"}");
    try dispatch(session, "{\"id\":3,\"method\":\"TestReporter.enable\"}");

    const error_name = BunString.static("TypeError");
    const error_message = BunString.static("fixture failed");
    const frame_url = BunString.static("file:///fixture.ts");
    const source_line = BunString.static("throw new TypeError('fixture failed')");
    var frames = [_]ZigStackFrame{.{
        .function_name = BunString.empty(),
        .source_url = frame_url,
        .position = .{ .line = 8, .column = 12, .line_start_byte = 0 },
        .code_type = .function,
        .is_async = false,
    }};
    var source_lines = [_]BunString{source_line};
    var exception = ZigException{
        .name = error_name,
        .message = error_message,
        .stack = .{
            .source_lines_ptr = source_lines[0..].ptr,
            .source_lines_numbers = null,
            .source_lines_len = 1,
            .source_lines_to_collect = 1,
            .frames_ptr = frames[0..].ptr,
            .frames_len = 1,
            .frames_cap = 1,
        },
    };

    const lifecycle_start = capture.len;
    Bun__LifecycleAgentPreventExit(session);
    Bun__LifecycleAgentReportReload(session);
    Bun__LifecycleAgentReportError(session, &exception);
    Bun__LifecycleAgentStopPreventingExit(session);
    try std.testing.expect(capture.containsFrom(lifecycle_start, "\"method\":\"LifecycleReporter.reload\""));
    try std.testing.expect(capture.containsFrom(lifecycle_start, "\"message\":\"fixture failed\""));
    try std.testing.expect(capture.containsFrom(lifecycle_start, "\"name\":\"TypeError\""));
    try std.testing.expect(capture.containsFrom(lifecycle_start, "\"urls\":[\"file:///fixture.ts\"]"));
    try std.testing.expect(capture.containsFrom(lifecycle_start, "\"lineColumns\":[9,13]"));

    var test_name = BunString.static("fixture test");
    var source_url = BunString.static("file:///fixture.test.ts");
    const explicit_start = capture.len;
    Bun__TestReporterAgentReportTestFoundWithLocation(session, 41, &test_name, .describe, 7, &source_url, 22);
    Bun__TestReporterAgentReportTestStart(session, 41);
    Bun__TestReporterAgentReportTestEnd(session, 41, .skipped_because_label, 12.5);
    try std.testing.expect(capture.containsFrom(explicit_start, "\"method\":\"TestReporter.found\""));
    try std.testing.expect(capture.containsFrom(explicit_start, "\"url\":\"file:///fixture.test.ts\""));
    try std.testing.expect(capture.containsFrom(explicit_start, "\"line\":22"));
    try std.testing.expect(capture.containsFrom(explicit_start, "\"type\":\"describe\""));
    try std.testing.expect(capture.containsFrom(explicit_start, "\"parentId\":7"));
    try std.testing.expect(capture.containsFrom(explicit_start, "\"status\":\"skipped_because_label\""));

    var call_frame_storage: usize = 0;
    const call_frame: *CallFrame = @ptrCast(&call_frame_storage);
    const implicit_start = capture.len;
    Bun__TestReporterAgentReportTestFound(session, call_frame, 42, &test_name, .@"test", -1);
    try std.testing.expect(capture.containsFrom(implicit_start, "\"id\":42"));
    try std.testing.expect(capture.containsFrom(implicit_start, "\"line\":0"));
    try std.testing.expect(!capture.containsFrom(implicit_start, "\"scriptId\""));
    try std.testing.expect(!capture.containsFrom(implicit_start, "\"url\""));
    try std.testing.expect(!capture.containsFrom(implicit_start, "\"parentId\""));

    try dispatch(session, "{\"id\":4,\"method\":\"LifecycleReporter.disable\"}");
    try dispatch(session, "{\"id\":5,\"method\":\"TestReporter.disable\"}");
    const disabled_start = capture.len;
    Bun__LifecycleAgentReportReload(session);
    Bun__TestReporterAgentReportTestStart(session, 43);
    try std.testing.expectEqual(disabled_start, capture.len);

    const http_before_enable = capture.len;
    Bun__HTTPServerAgent__notifyRequestFinished(session, 51, 9, 2000, 3);
    try std.testing.expectEqual(http_before_enable, capture.len);
    try dispatch(session, "{\"id\":6,\"method\":\"HTTPServer.enable\"}");
    var request_url = BunString.static("/fixture/9");
    var full_url = BunString.static("https://example.test/fixture/9");
    var headers_json = BunString.static("[\"accept\",\"application/json\"]");
    var params_json = BunString.static("[\"id\",\"9\"]");
    var response_status = BunString.static("No Content");
    var chunk = BunString.static("Zml4dHVyZQ==");
    var handler_message = BunString.static("fixture handler failed");
    var handler_url = BunString.static("file:///fixture-server.ts");
    const http_start = capture.len;
    Bun__HTTPServerAgent__notifyRequestWillBeSent(session, 51, 9, 4, &request_url, &full_url, .get, &headers_json, &params_json, true, 2000);
    Bun__HTTPServerAgent__notifyResponseReceived(session, 51, 9, 204, &response_status, &headers_json, false, 2001);
    Bun__HTTPServerAgent__notifyBodyChunkReceived(session, 51, 9, 6, &chunk, 2002);
    Bun__HTTPServerAgent__notifyRequestFinished(session, 51, 9, 2003, 3);
    Bun__HTTPServerAgent__notifyRequestHandlerException(session, 52, 9, &handler_message, &handler_url, 17, 2004);
    try std.testing.expect(capture.containsFrom(http_start, "\"method\":\"HTTPServer.requestWillBeSent\""));
    try std.testing.expect(capture.containsFrom(http_start, "\"headers\":[\"accept\",\"application/json\"]"));
    try std.testing.expect(capture.containsFrom(http_start, "\"params\":[\"id\",\"9\"]"));
    try std.testing.expect(capture.containsFrom(http_start, "\"method\":\"HTTPServer.responseReceived\""));
    try std.testing.expect(capture.containsFrom(http_start, "\"statusCode\":204"));
    try std.testing.expect(capture.containsFrom(http_start, "\"method\":\"HTTPServer.bodyChunkReceived\""));
    try std.testing.expect(capture.containsFrom(http_start, "\"flags\":6"));
    try std.testing.expect(capture.containsFrom(http_start, "\"method\":\"HTTPServer.requestFinished\""));
    try std.testing.expect(capture.containsFrom(http_start, "\"duration\":3"));
    try std.testing.expect(capture.containsFrom(http_start, "\"method\":\"HTTPServer.requestHandlerException\""));
    try std.testing.expect(capture.containsFrom(http_start, "\"message\":\"fixture handler failed\""));
    try dispatch(session, "{\"id\":7,\"method\":\"HTTPServer.disable\"}");
    const http_disabled = capture.len;
    Bun__HTTPServerAgent__notifyRequestFinished(session, 53, 9, 2005, 1);
    try std.testing.expectEqual(http_disabled, capture.len);
}
