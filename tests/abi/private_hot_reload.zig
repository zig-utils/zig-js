const std = @import("std");

const JSGlobalObject = opaque {};
const InspectorSession = opaque {};
const MessageCallback = *const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;

extern fn JSGlobalContextCreate(global_class: ?*anyopaque) ?*JSGlobalObject;
extern fn JSGlobalContextRelease(global: ?*JSGlobalObject) void;
extern fn JSGlobalContextSetInspectable(global: ?*JSGlobalObject, inspectable: bool) void;
extern fn ZJSInspectorSessionCreate(
    global: ?*JSGlobalObject,
    callback: MessageCallback,
    user_data: ?*anyopaque,
) ?*InspectorSession;
extern fn ZJSInspectorSessionRelease(session: ?*InspectorSession) void;
extern fn BunDebugger__willHotReload() void;

const Capture = struct {
    reloads: usize = 0,

    fn receive(message: [*]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        if (std.mem.eql(u8, message[0..len], "{\"method\":\"Bun.canReload\"}"))
            self.reloads += 1;
    }
};

pub fn main() !void {
    const first = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(first);
    const second = JSGlobalContextCreate(null) orelse return error.ContextCreateFailed;
    defer JSGlobalContextRelease(second);
    JSGlobalContextSetInspectable(first, true);
    JSGlobalContextSetInspectable(second, true);

    var first_capture: Capture = .{};
    var second_capture: Capture = .{};
    const first_session = ZJSInspectorSessionCreate(first, Capture.receive, &first_capture) orelse
        return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(first_session);
    const second_session = ZJSInspectorSessionCreate(second, Capture.receive, &second_capture) orelse
        return error.SessionCreateFailed;
    defer ZJSInspectorSessionRelease(second_session);

    BunDebugger__willHotReload();
    try std.testing.expectEqual(@as(usize, 1), first_capture.reloads);
    try std.testing.expectEqual(@as(usize, 1), second_capture.reloads);
}
