//! Machine-readable zig-js side of the JavaScriptCore comparison benchmark.
//!
//! Usage:
//!   bench-comparison-zig-js single <workload> <jobs> <samples>
//!   bench-comparison-zig-js independent_steady <workload> <jobs> <samples> <lanes>
//!   bench-comparison-zig-js independent_cold <workload> <jobs> <samples> <lanes>
//!   bench-comparison-zig-js shared <workload> <jobs> <samples> <lanes>
//!
//! Independent modes use one creator-thread-affine context per OS worker. In
//! steady mode worker/context setup and warm-up are outside every timed sample;
//! in cold mode thread/context/source setup and teardown are all timed. Shared
//! mode measures zig-js's distinct shared-realm JavaScript Thread model.

const std = @import("std");
const js = @import("js");

const workload_source = @embedFile("comparison.js");
const invocation = "__benchmarkSelected(__benchmarkJobs, __benchmarkLane)";
// Every measured context uses the same process-wide production allocator.
// libc malloc keeps reusable slabs between contexts instead of translating
// arena/GC backing allocations into page-level mmap/munmap churn, is safe for
// independent workers, and matches JSC's cached process allocator more closely
// than mixing the runner allocator into the direct and shared rows.
const benchmark_context_allocator = std.heap.c_allocator;

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

const Mode = enum { single, independent_steady, independent_cold, shared };

const SteadyLane = struct {
    io: std.Io,
    workload: []const u8,
    jobs: usize,
    lane: usize,
    ready: *std.Io.Semaphore,
    done: *std.Io.Semaphore,
    start: std.Io.Semaphore = .{},
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    checksum: f64 = 0,
};

const ColdLane = struct {
    workload: []const u8,
    jobs: usize,
    lane: usize,
    failed: std.atomic.Value(bool) = .init(false),
    checksum: f64 = 0,
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn parseMode(text: []const u8) !Mode {
    inline for (std.meta.tags(Mode)) |mode|
        if (std.mem.eql(u8, text, @tagName(mode))) return mode;
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

fn configure(ctx: *js.Context, workload: []const u8, jobs: usize, lane: usize) !void {
    _ = try ctx.evaluate(workload_source);
    const source = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkSelected = benchmarkFunction(\"{s}\"); globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{
        workload, jobs, lane,
    });
    _ = try ctx.evaluate(source);
}

fn warm(ctx: *js.Context, warm_jobs: usize, jobs: usize, lane: usize) !void {
    const warm_config = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{ warm_jobs, lane });
    _ = try ctx.evaluate(warm_config);
    for (0..3) |_| _ = try ctx.evaluate(invocation);
    const restore = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{ jobs, lane });
    _ = try ctx.evaluate(restore);
}

fn runSingle(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
) !void {
    const ctx = try js.Context.createWith(allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    try configure(ctx, workload, jobs, 0);
    try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0);

    for (0..samples) |sample| {
        const started = nowNs(io);
        const result = try ctx.evaluate(invocation);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        try printRow(writer, .single, workload, 1, jobs, sample, elapsed, result.toNumber());
    }
}

fn steadyLaneMain(lane: *SteadyLane) void {
    const ctx = js.Context.createWith(benchmark_context_allocator, .{ .enable_gc = true }) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    defer ctx.destroy();
    configure(ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    warm(ctx, @max(@as(usize, 1), lane.jobs / 10), lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    lane.ready.post(lane.io);

    while (true) {
        lane.start.waitUncancelable(lane.io);
        if (lane.stop.load(.acquire)) return;
        const result = ctx.evaluate(invocation) catch {
            lane.failed.store(true, .release);
            lane.done.post(lane.io);
            return;
        };
        lane.checksum = result.toNumber();
        lane.done.post(lane.io);
    }
}

fn runIndependentSteady(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lane_count: usize,
) !void {
    const lanes = try allocator.alloc(SteadyLane, lane_count);
    defer allocator.free(lanes);
    const threads = try allocator.alloc(std.Thread, lane_count);
    defer allocator.free(threads);
    var ready: std.Io.Semaphore = .{};
    var done: std.Io.Semaphore = .{};
    var spawned: usize = 0;
    defer {
        for (lanes[0..spawned]) |*lane| {
            lane.stop.store(true, .release);
            lane.start.post(io);
        }
        for (threads[0..spawned]) |thread| thread.join();
    }

    for (lanes, 0..) |*lane, lane_index| {
        lane.* = .{
            .io = io,
            .workload = workload,
            .jobs = jobs,
            .lane = lane_index,
            .ready = &ready,
            .done = &done,
        };
        threads[lane_index] = try std.Thread.spawn(.{}, steadyLaneMain, .{lane});
        spawned += 1;
    }
    for (0..lane_count) |_| ready.waitUncancelable(io);
    for (lanes) |*lane| if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;

    for (0..samples) |sample| {
        const started = nowNs(io);
        for (lanes) |*lane| lane.start.post(io);
        for (0..lane_count) |_| done.waitUncancelable(io);
        const elapsed: u64 = @intCast(nowNs(io) - started);

        var checksum: f64 = 0;
        for (lanes) |*lane| {
            if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;
            checksum += lane.checksum;
        }
        try printRow(writer, .independent_steady, workload, lane_count, jobs, sample, elapsed, checksum);
    }
}

fn coldLaneMain(lane: *ColdLane) void {
    const ctx = js.Context.createWith(benchmark_context_allocator, .{ .enable_gc = true }) catch {
        lane.failed.store(true, .release);
        return;
    };
    defer ctx.destroy();
    configure(ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        return;
    };
    const result = ctx.evaluate(invocation) catch {
        lane.failed.store(true, .release);
        return;
    };
    lane.checksum = result.toNumber();
}

fn runIndependentCold(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lane_count: usize,
) !void {
    const lanes = try allocator.alloc(ColdLane, lane_count);
    defer allocator.free(lanes);
    const threads = try allocator.alloc(std.Thread, lane_count);
    defer allocator.free(threads);

    for (0..samples) |sample| {
        for (lanes, 0..) |*lane, lane_index| lane.* = .{
            .workload = workload,
            .jobs = jobs,
            .lane = lane_index,
        };

        const started = nowNs(io);
        var spawned: usize = 0;
        for (lanes) |*lane| {
            threads[spawned] = std.Thread.spawn(.{}, coldLaneMain, .{lane}) catch |err| {
                for (threads[0..spawned]) |thread| thread.join();
                return err;
            };
            spawned += 1;
        }
        for (threads) |thread| thread.join();
        const elapsed: u64 = @intCast(nowNs(io) - started);

        var checksum: f64 = 0;
        for (lanes) |*lane| {
            if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;
            checksum += lane.checksum;
        }
        try printRow(writer, .independent_cold, workload, lane_count, jobs, sample, elapsed, checksum);
    }
}

fn runShared(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lanes: usize,
) !void {
    const ctx = try js.Context.createWith(allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    try configure(ctx, workload, jobs, 0);
    _ = try ctx.evaluate(shared_harness);
    try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0);

    const shared_invocation = try std.fmt.allocPrint(ctx.arena(), "__benchmarkRunShared({d}, {d})", .{
        jobs, lanes,
    });
    for (0..samples) |sample| {
        const started = nowNs(io);
        const result = try ctx.evaluate(shared_invocation);
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
    const lanes = if (mode == .single)
        1
    else if (args.len == 6)
        try std.fmt.parseUnsigned(usize, args[5], 10)
    else
        return error.InvalidArguments;
    if (jobs == 0 or samples == 0 or lanes == 0) return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    switch (mode) {
        .single => try runSingle(benchmark_context_allocator, init.io, stdout, workload, jobs, samples),
        .independent_steady => try runIndependentSteady(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
        .independent_cold => try runIndependentCold(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
        .shared => try runShared(benchmark_context_allocator, init.io, stdout, workload, jobs, samples, lanes),
    }
    try stdout.flush();
}
