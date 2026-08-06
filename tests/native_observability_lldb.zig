const std = @import("std");
const js = @import("js");

export fn native_observability_after_unregister() callconv(.c) void {
    asm volatile ("" ::: .{ .memory = true });
}

pub fn main() !void {
    if (!js.jit.supported) return error.UnsupportedTarget;

    const context = try js.Context.createWith(std.heap.page_allocator, .{
        .native_code_publisher = js.jit.gdbJitPublisher(),
    });
    errdefer context.destroy();
    const result = try context.evaluate(
        \\function observedNative(n) {
        \\  var total = 0;
        \\  var i = 0;
        \\  while (i < n) { total = total + i; i = i + 1; }
        \\  return total;
        \\}
        \\observedNative(100)
    );
    if (result.asNum() != 4950) return error.TestUnexpectedResult;
    const warmed = try context.evaluate("observedNative(101)");
    if (warmed.asNum() != 5050 or context.jit_owner.stats().live_artifacts == 0)
        return error.TestUnexpectedResult;
    context.destroy();
    @call(.never_inline, native_observability_after_unregister, .{});
}
