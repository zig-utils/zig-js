//! Parser-only growth runner for representative frontend complexity witnesses.
//!
//! Usage:
//!   frontend-parse-benchmark single <workload> <jobs> <samples>

const std = @import("std");
const js = @import("js");

const warmup_calls = 10;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn workloadWidth(name: []const u8) !usize {
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_4096")) return 4096;
    return error.InvalidWorkload;
}

fn strictFunctionSource(allocator: std.mem.Allocator, width: usize) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function strictWidth(");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "parameter{d}", .{index}));
    }
    try source.appendSlice(allocator, "){\"use strict\";return 7;}");
    return source.items;
}

fn parseOnce(allocator: std.mem.Allocator, source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = try js.Parser.init(arena.allocator(), source);
    const program = try parser.parseProgram();
    const declaration = program.program[0];
    if (declaration.* != .func_decl) return error.InvalidProgram;
    return declaration.func_decl.params.len + 7;
}

fn runJobs(allocator: std.mem.Allocator, source: []const u8, jobs: usize) !usize {
    var checksum: usize = 0;
    for (0..jobs) |_| checksum += try parseOnce(allocator, source);
    return checksum;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5 or !std.mem.eql(u8, args[1], "single")) return error.InvalidArguments;
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    if (jobs == 0 or samples == 0) return error.InvalidArguments;

    const source = try strictFunctionSource(init.arena.allocator(), try workloadWidth(workload));
    for (0..warmup_calls) |_| _ = try runJobs(init.gpa, source, @max(@as(usize, 1), jobs / 10));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (0..samples) |sample| {
        const started = nowNs(init.io);
        const checksum = try runJobs(init.gpa, source, jobs);
        const elapsed: u64 = @intCast(nowNs(init.io) - started);
        try stdout.print("zig-js\tsingle\t{s}\t1\t{d}\t{d}\t{d}\t{d}\n", .{
            workload, jobs, sample, elapsed, checksum,
        });
    }
    try stdout.flush();
}
