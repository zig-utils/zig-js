const std = @import("std");
const support = @import("cpu_profile_fixture_support.zig");

extern fn Bun__setSamplingInterval(interval_microseconds: c_int) void;
extern fn Bun__startCPUProfiler(vm: ?*support.VM) void;
extern fn Bun__stopCPUProfiler(vm: ?*support.VM, out_json: ?*support.BunString, out_text: ?*support.BunString) void;

fn takeBytes(string: support.BunString) ![]u8 {
    if (string.tag != .wtf_string_impl) return error.ExpectedOwnedString;
    const impl = string.value.wtf_string_impl orelse return error.ExpectedOwnedString;
    defer support.Bun__WTFStringImpl__deref(impl);
    return support.ownedImplBytes(std.heap.page_allocator, impl);
}

pub fn main() !void {
    var invalid_json: support.BunString = undefined;
    Bun__stopCPUProfiler(null, &invalid_json, null);
    try std.testing.expect(invalid_json.tag == .dead);

    const fixture = try support.createFixtureVM();
    defer support.destroyFixtureVM(fixture.vm, fixture.global, fixture.sibling);
    Bun__setSamplingInterval(1);
    Bun__startCPUProfiler(fixture.vm);
    try support.runMainWorkload(fixture.global);
    try support.runSiblingWorkload(fixture.sibling);
    var json_string: support.BunString = undefined;
    var text_string: support.BunString = undefined;
    Bun__stopCPUProfiler(fixture.vm, &json_string, &text_string);
    const json = try takeBytes(json_string);
    defer std.heap.page_allocator.free(json);
    const text = try takeBytes(text_string);
    defer std.heap.page_allocator.free(text);
    try support.validateJSON(json, true, true, false);
    try support.validateMarkdown(text, true, true);

    const isolated = try support.createFixtureVM();
    defer support.destroyFixtureVM(isolated.vm, isolated.global, isolated.sibling);
    Bun__startCPUProfiler(fixture.vm);
    Bun__startCPUProfiler(isolated.vm);
    try support.runMainWorkload(fixture.global);
    try support.runRestartWorkload(isolated.global);
    Bun__stopCPUProfiler(fixture.vm, &json_string, null);
    const first_vm_only = try takeBytes(json_string);
    defer std.heap.page_allocator.free(first_vm_only);
    try support.validateJSON(first_vm_only, true, false, false);
    Bun__stopCPUProfiler(isolated.vm, &json_string, null);
    const second_vm_only = try takeBytes(json_string);
    defer std.heap.page_allocator.free(second_vm_only);
    try support.validateJSON(second_vm_only, false, false, true);

    Bun__startCPUProfiler(fixture.vm);
    try support.runMainWorkload(fixture.global);
    Bun__startCPUProfiler(fixture.vm);
    try support.runRestartWorkload(fixture.global);
    Bun__stopCPUProfiler(fixture.vm, &json_string, null);
    const restarted = try takeBytes(json_string);
    defer std.heap.page_allocator.free(restarted);
    try support.validateJSON(restarted, false, false, true);
    Bun__stopCPUProfiler(fixture.vm, &json_string, null);
    try std.testing.expect(json_string.tag == .dead);
    Bun__startCPUProfiler(fixture.vm);
    try support.runRestartWorkload(fixture.global);
    Bun__stopCPUProfiler(fixture.vm, null, null);
    Bun__stopCPUProfiler(fixture.vm, &json_string, null);
    try std.testing.expect(json_string.tag == .dead);

    const idle = try support.createFixtureVM();
    defer support.destroyFixtureVM(idle.vm, idle.global, idle.sibling);
    Bun__startCPUProfiler(idle.vm);
    Bun__stopCPUProfiler(idle.vm, &json_string, &text_string);
    const idle_json = try takeBytes(json_string);
    defer std.heap.page_allocator.free(idle_json);
    try support.validateEmptyJSON(idle_json);
    const idle_text = try takeBytes(text_string);
    defer std.heap.page_allocator.free(idle_text);
    try std.testing.expectEqualStrings("No samples collected.\n", idle_text);
}
