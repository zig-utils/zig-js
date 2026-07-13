//! Machine-readable zig-js side of the JavaScriptCore comparison benchmark.
//!
//! Usage:
//!   bench-comparison-zig-js single <workload> <jobs> <samples>
//!   bench-comparison-zig-js shared <workload> <jobs> <samples> <lanes>
//!
//! Setup, compilation, and warm-up happen before the timer. A shared-mode
//! sample creates and joins its shared-realm Threads inside the timed region,
//! matching the JSC runner's timed OS-thread spawn/join boundary.

const std = @import("std");
const js = @import("js");

const workload_source = @embedFile("comparison.js");

const shared_harness =
    \\globalThis.__benchmarkRunShared = function(jobs, lanes) {
    \\  var threads = [];
    \\  for (var lane = 0; lane < lanes; lane = lane + 1) {
    \\    threads.push(new Thread(globalThis.__benchmarkSelected, jobs, lane));
    \\  }
    \\  var checksum = 0;
    \\  for (var index = 0; index < threads.length; index = index + 1)
    \\    checksum = checksum + threads[index].join();
    \\  return checksum;
    \\};
;

const Mode = enum { single, shared };

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn parseMode(text: []const u8) !Mode {
    if (std.mem.eql(u8, text, "single")) return .single;
    if (std.mem.eql(u8, text, "shared")) return .shared;
    return error.InvalidMode;
}

fn printRow(
    writer: *std.Io.Writer,
    mode: Mode,
    workload: []const u8,
    lanes: usize,
    jobs: usize,
    sample: usize,
    elapsed_ns: u64,
    checksum: f64,
) !void {
    try writer.print("zig-js\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.0}\n", .{
        @tagName(mode), workload, lanes, jobs, sample, elapsed_ns, checksum,
    });
}

fn runSingle(
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
) !void {
    const ctx = try js.Context.createWith(gpa, .{ .enable_gc = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(workload_source);

    const configure = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkSelected = benchmarkFunction(\"{s}\"); globalThis.__benchmarkJobs = {d};", .{ workload, jobs });
    _ = try ctx.evaluate(configure);
    const warm_jobs = @max(@as(usize, 1), jobs / 10);
    const warm = try std.fmt.allocPrint(ctx.arena(), "__benchmarkSelected({d}, 0)", .{warm_jobs});
    for (0..3) |_| _ = try ctx.evaluate(warm);

    for (0..samples) |sample| {
        const started = nowNs(io);
        const result = try ctx.evaluate("__benchmarkSelected(__benchmarkJobs, 0)");
        const elapsed: u64 = @intCast(nowNs(io) - started);
        try printRow(writer, .single, workload, 1, jobs, sample, elapsed, result.toNumber());
    }
}

fn runShared(
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lanes: usize,
) !void {
    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(workload_source);
    _ = try ctx.evaluate(shared_harness);

    const configure = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkSelected = benchmarkFunction(\"{s}\");", .{workload});
    _ = try ctx.evaluate(configure);

    const warm_jobs = @max(@as(usize, 1), jobs / 10);
    const warm = try std.fmt.allocPrint(ctx.arena(), "__benchmarkSelected({d}, 0)", .{warm_jobs});
    for (0..3) |_| _ = try ctx.evaluate(warm);

    const invocation = try std.fmt.allocPrint(ctx.arena(), "__benchmarkRunShared({d}, {d})", .{
        jobs, lanes,
    });
    for (0..samples) |sample| {
        const started = nowNs(io);
        const result = try ctx.evaluate(invocation);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        try printRow(writer, .shared, workload, lanes, jobs, sample, elapsed, result.toNumber());
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5 and args.len != 6) return error.InvalidArguments;

    const mode = try parseMode(args[1]);
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    const lanes = if (mode == .shared)
        if (args.len == 6) try std.fmt.parseUnsigned(usize, args[5], 10) else return error.InvalidArguments
    else
        1;
    if (jobs == 0 or samples == 0 or lanes == 0) return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    switch (mode) {
        .single => try runSingle(init.gpa, init.io, stdout, workload, jobs, samples),
        .shared => try runShared(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
    }
    try stdout.flush();
}
