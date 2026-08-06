const std = @import("std");
const builtin = @import("builtin");
const js = @import("js");

export fn native_observability_after_unregister() callconv(.c) void {
    asm volatile ("" ::: .{ .memory = true });
}

pub fn main() !void {
    if (!js.jit.supported) return error.UnsupportedTarget;

    var owner = js.jit.Owner.initWithOptions(std.heap.page_allocator, .{
        .native_code_publisher = js.jit.gdbJitPublisher(),
    });
    errdefer owner.deinit();
    var tier: js.jit.Tier = .{};
    var claim = owner.claimCompilation(&tier, 1) orelse return error.TestUnexpectedResult;
    errdefer claim.release();

    const machine_code: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &[_]u8{ 0xc0, 0x03, 0x5f, 0xd6 }, // ret
        .x86_64 => &[_]u8{0xc3}, // ret
        else => return error.UnsupportedTarget,
    };
    var memory = try js.jit.CodeMemory.init(machine_code.len);
    errdefer memory.deinit();
    @memcpy(memory.writableBytes()[0..machine_code.len], machine_code);
    try memory.publish(machine_code.len);
    const entry: js.jit.NativeEntry = @ptrCast(@alignCast(memory.executableBytes().ptr));
    const compiled: js.jit.CompiledCode = .{ .memory = memory, .entry = entry };
    const code = owner.adoptAndPublishObserved(&tier, compiled, .{
        .function_name = "observedNative",
        .function_identity = 0x501,
        .script_id = 1,
        .source_url = "native-observability-lldb.js",
        .source_byte_offset = 0,
        .source_line = 1,
        .source_column = 1,
    }) catch |err| {
        return err;
    };
    claim.release();

    const invoke: *const fn () callconv(.c) void = @ptrCast(@alignCast(code.memory.executableBytes().ptr));
    invoke();
    owner.deinit();
    @call(.never_inline, native_observability_after_unregister, .{});
}
