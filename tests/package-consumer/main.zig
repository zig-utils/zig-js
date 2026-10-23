const std = @import("std");
const js = @import("js");

pub fn main() !void {
    const context = try js.Context.createWith(std.heap.page_allocator, .{
        .enable_gc = true,
        .enable_jit = false,
        .heap_limit_bytes = 64 * 1024 * 1024,
    });
    defer context.destroy();
    const result = try context.evaluate("(/settlers/.test('the-settlers-iii-remake') ? 40 : 0) + 2");
    if (result.asNum() != 42) return error.PublicPackageResultMismatch;
    context.collectGarbage();
    std.debug.print("public package consumer: JavaScript, RegExp and owned GC executed successfully\n", .{});
}
