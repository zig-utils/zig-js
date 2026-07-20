const std = @import("std");
const support = @import("cpu_profile_fixture_support.zig");

extern fn Bun__setSamplingInterval(interval_microseconds: c_int) void;
extern fn Bun__startCPUProfiler(vm: ?*support.VM) void;
extern fn Bun__stopCPUProfiler(vm: ?*support.VM, out_json: ?*?*support.WTFStringImpl, out_text: ?*?*support.WTFStringImpl) void;

fn takeBytes(impl: ?*support.WTFStringImpl) ![]u8 {
    const owned = impl orelse return error.ExpectedOwnedString;
    defer support.Bun__WTFStringImpl__deref(owned);
    return support.ownedImplBytes(std.heap.page_allocator, owned);
}

pub fn main() !void {
    var invalid_json: ?*support.WTFStringImpl = undefined;
    Bun__stopCPUProfiler(null, &invalid_json, null);
    try std.testing.expect(invalid_json == null);

    const fixture = try support.createFixtureVM();
    defer support.destroyFixtureVM(fixture.vm, fixture.global, fixture.sibling);
    Bun__setSamplingInterval(60_000_000);
    Bun__startCPUProfiler(fixture.vm);
    try support.evaluate(fixture.global, "globalThis.warmup404 = 1;", "/tmp/zig-js-cpu-warmup-404.js");
    Bun__setSamplingInterval(1);
    try support.runMainWorkload(fixture.global);
    try support.runSiblingWorkload(fixture.sibling);
    var json_impl: ?*support.WTFStringImpl = null;
    var text_impl: ?*support.WTFStringImpl = null;
    Bun__stopCPUProfiler(fixture.vm, &json_impl, &text_impl);
    const json = try takeBytes(json_impl);
    defer std.heap.page_allocator.free(json);
    const text = try takeBytes(text_impl);
    defer std.heap.page_allocator.free(text);
    try support.validateJSON(json, true, true, false);
    try support.validateMarkdown(text, true, true);

    Bun__startCPUProfiler(fixture.vm);
    try support.runMainWorkload(fixture.global);
    Bun__startCPUProfiler(fixture.vm);
    try support.runRestartWorkload(fixture.global);
    json_impl = null;
    Bun__stopCPUProfiler(fixture.vm, &json_impl, null);
    const restarted = try takeBytes(json_impl);
    defer std.heap.page_allocator.free(restarted);
    try support.validateJSON(restarted, false, false, true);
    json_impl = undefined;
    Bun__stopCPUProfiler(fixture.vm, &json_impl, null);
    try std.testing.expect(json_impl == null);

    const idle = try support.createFixtureVM();
    defer support.destroyFixtureVM(idle.vm, idle.global, idle.sibling);
    Bun__startCPUProfiler(idle.vm);
    var idle_json_impl: ?*support.WTFStringImpl = null;
    var idle_text_impl: ?*support.WTFStringImpl = null;
    Bun__stopCPUProfiler(idle.vm, &idle_json_impl, &idle_text_impl);
    const idle_json = try takeBytes(idle_json_impl);
    defer std.heap.page_allocator.free(idle_json);
    try support.validateEmptyJSON(idle_json);
    const idle_text = try takeBytes(idle_text_impl);
    defer std.heap.page_allocator.free(idle_text);
    try std.testing.expectEqualStrings("No samples collected.\n", idle_text);
}
