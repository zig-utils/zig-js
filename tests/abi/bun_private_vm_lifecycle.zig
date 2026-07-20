const std = @import("std");

const VM = opaque {};
const JSGlobalObject = opaque {};

extern fn JSC__VM__create(heap_type: u8) *VM;
extern fn JSC__VM__deinit(vm: *VM, global: *JSGlobalObject) void;
extern fn JSC__VM__deferGC(
    vm: *VM,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern fn JSC__VM__setControlFlowProfiler(vm: *VM, enabled: bool) void;
extern fn JSGlobalContextCreateInGroup(group: ?*anyopaque, global_class: ?*anyopaque) ?*JSGlobalObject;
extern fn JSGlobalContextRelease(global: ?*JSGlobalObject) void;
extern fn JSContextGetGlobalObject(global: ?*JSGlobalObject) ?*anyopaque;

const CallbackState = struct {
    vm: *VM,
    calls: usize = 0,
};

fn deferredCallback(raw: ?*anyopaque) callconv(.c) void {
    const state: *CallbackState = @ptrCast(@alignCast(raw orelse return));
    state.calls += 1;
    JSC__VM__setControlFlowProfiler(state.vm, true);
    JSC__VM__setControlFlowProfiler(state.vm, false);
}

fn exercise(heap_type: u8) !void {
    const vm = JSC__VM__create(heap_type);
    const global = JSGlobalContextCreateInGroup(@ptrCast(vm), null) orelse
        return error.ContextCreateFailed;
    defer JSGlobalContextRelease(global);

    var state = CallbackState{ .vm = vm };
    JSC__VM__deferGC(vm, &state, deferredCallback);
    try std.testing.expectEqual(@as(usize, 1), state.calls);

    JSC__VM__deinit(vm, global);
    JSC__VM__deinit(vm, global);
    try std.testing.expect(JSContextGetGlobalObject(global) != null);
}

pub fn main() !void {
    try exercise(0);
    try exercise(1);
}
