const std = @import("std");
const builtin = @import("builtin");
const js = @import("js");

pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const execute_mode = "--execute-after-publish";
const execute_writable_mode = "--execute-while-writable";
const write_executable_mode = "--write-after-publish";

fn machineCode() []const u8 {
    return switch (builtin.cpu.arch) {
        // mov w0, #42; ret
        .aarch64 => &.{ 0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6 },
        // mov eax, 42; ret
        .x86_64 => &.{ 0xb8, 0x2a, 0x00, 0x00, 0x00, 0x00, 0xc3 },
        else => unreachable,
    };
}

fn preparedMemory() !js.jit.CodeMemory {
    const code = machineCode();
    var memory = try js.jit.CodeMemory.init(code.len);
    errdefer memory.deinit();
    @memcpy(memory.writableBytes()[0..code.len], code);
    return memory;
}

fn executeAt(memory: *const js.jit.CodeMemory) u32 {
    const NativeFn = *const fn () callconv(.c) u32;
    const entry: NativeFn = @ptrCast(@alignCast(memory.mapping.ptr));
    return entry();
}

fn runChild(mode: []const u8) !void {
    var memory = try preparedMemory();
    defer memory.deinit();
    if (std.mem.eql(u8, mode, execute_writable_mode)) {
        if (executeAt(&memory) == 42) return error.TestExecutedWritableMemory;
        return error.TestUnexpectedNativeResult;
    }
    try memory.publish(machineCode().len);
    if (std.mem.eql(u8, mode, execute_mode)) {
        if (executeAt(&memory) != 42) return error.TestUnexpectedNativeResult;
        return;
    }
    if (std.mem.eql(u8, mode, write_executable_mode)) {
        const first: *volatile u8 = @ptrCast(memory.mapping.ptr);
        first.* ^= 1;
        return error.TestWroteExecutableMemory;
    }
    return error.TestUnexpectedArgument;
}

fn runProcess(gpa: std.mem.Allocator, io: std.Io, executable: []const u8, mode: []const u8) !std.process.Child.Term {
    const completed = try std.process.run(gpa, io, .{
        .argv = &.{ executable, mode },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(completed.stdout);
    defer gpa.free(completed.stderr);
    if (completed.stdout.len != 0) return error.TestUnexpectedChildStdout;
    if (completed.stderr.len != 0) return error.TestUnexpectedChildStderr;
    return completed.term;
}

fn expectProtectionFault(term: std.process.Child.Term) !void {
    switch (term) {
        .signal => |signal| if (signal != .SEGV and signal != .BUS)
            return error.TestUnexpectedProtectionSignal,
        else => return error.TestMissingProtectionFault,
    }
}

fn runParent(gpa: std.mem.Allocator, io: std.Io) !void {
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    const execute_term = try runProcess(gpa, io, executable, execute_mode);
    if (!execute_term.success()) return error.TestPublishedExecutionFailed;
    try expectProtectionFault(try runProcess(gpa, io, executable, execute_writable_mode));
    try expectProtectionFault(try runProcess(gpa, io, executable, write_executable_mode));
}

pub fn main(init: std.process.Init) !void {
    if (!js.jit.executable_memory_supported) return error.UnsupportedTarget;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next();
    if (args.next() != null) return error.TestUnexpectedArgument;
    if (mode) |child_mode| return runChild(child_mode);
    return runParent(init.gpa, init.io);
}
