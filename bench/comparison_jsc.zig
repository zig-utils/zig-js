//! Machine-readable system-JavaScriptCore comparison benchmark runner.
//!
//! Single mode reuses one warmed JSGlobalContext. Independent steady mode
//! keeps one warmed creator-thread-owned context and one OS worker per lane;
//! only symmetric dispatch/evaluation/completion is timed. Independent cold
//! mode times OS-thread and context creation, source setup, one invocation,
//! context destruction, and join.

const std = @import("std");

// Zig 0.17 removed source-level @cImport. Keep this intentionally tiny public
// JSC ABI declaration beside the runner; build.zig links the real framework.
const JSGlobalContextRef = ?*anyopaque;
const JSContextRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;

extern fn JSGlobalContextCreate(global_object_class: ?*anyopaque) callconv(.c) JSGlobalContextRef;
extern fn JSGlobalContextRelease(ctx: JSGlobalContextRef) callconv(.c) void;
extern fn JSStringCreateWithUTF8CString(string: [*:0]const u8) callconv(.c) JSStringRef;
extern fn JSStringRelease(string: JSStringRef) callconv(.c) void;
extern fn JSEvaluateScript(
    ctx: JSContextRef,
    script: JSStringRef,
    this_object: JSObjectRef,
    source_url: JSStringRef,
    starting_line_number: c_int,
    exception: [*c]JSValueRef,
) callconv(.c) JSValueRef;
extern fn JSValueToNumber(ctx: JSContextRef, value: JSValueRef, exception: [*c]JSValueRef) callconv(.c) f64;

const workload_source: [:0]const u8 = @embedFile("comparison.js");
const wasm_simd_workload_source: [:0]const u8 = @embedFile("wasm_simd_comparison.js");
const wasm_threads_workload_source: [:0]const u8 = @embedFile("wasm_threads_comparison.js");
const invocation: [:0]const u8 = "__benchmarkInvoke(__benchmarkJobs, __benchmarkLane)";
const warmup_calls = 10;

const Mode = enum { single, independent_steady, independent_cold };

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

fn evaluate(ctx: JSGlobalContextRef, source: [:0]const u8) !f64 {
    const script = JSStringCreateWithUTF8CString(source.ptr) orelse return error.JavaScriptCoreFailure;
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const value = JSEvaluateScript(ctx, script, null, null, 1, &exception);
    if (exception != null or value == null) return error.JavaScriptException;
    var number_exception: JSValueRef = null;
    const number = JSValueToNumber(ctx, value, &number_exception);
    if (number_exception != null) return error.JavaScriptException;
    return number;
}

fn configure(
    allocator: std.mem.Allocator,
    ctx: JSGlobalContextRef,
    workload: []const u8,
    jobs: usize,
    lane: usize,
) !void {
    const source_bytes = if (std.mem.startsWith(u8, workload, "wasm_threads_"))
        wasm_threads_workload_source
    else if (std.mem.startsWith(u8, workload, "wasm_"))
        wasm_simd_workload_source
    else
        workload_source;
    _ = try evaluate(ctx, source_bytes);
    const source = try std.fmt.allocPrintSentinel(allocator, "globalThis.__benchmarkPrepare = undefined; globalThis.__benchmarkFinish = undefined; globalThis.__benchmarkSelected = benchmarkFunction(\"{s}\"); globalThis.__benchmarkInvoke = function(jobs, lane) {{ if (globalThis.__benchmarkPrepare) globalThis.__benchmarkPrepare(jobs, 1, lane, false); var result = globalThis.__benchmarkSelected(jobs, lane); return globalThis.__benchmarkFinish ? globalThis.__benchmarkFinish(jobs, 1, lane, false) : result; }}; globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{
        workload, jobs, lane,
    }, 0);
    defer allocator.free(source);
    _ = try evaluate(ctx, source);
}

fn warm(
    allocator: std.mem.Allocator,
    ctx: JSGlobalContextRef,
    warm_jobs: usize,
    jobs: usize,
    lane: usize,
) !void {
    const warm_config = try std.fmt.allocPrintSentinel(allocator, "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{ warm_jobs, lane }, 0);
    defer allocator.free(warm_config);
    _ = try evaluate(ctx, warm_config);
    for (0..warmup_calls) |_| _ = try evaluate(ctx, invocation);
    const restore = try std.fmt.allocPrintSentinel(allocator, "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{ jobs, lane }, 0);
    defer allocator.free(restore);
    _ = try evaluate(ctx, restore);
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
    try writer.print("JavaScriptCore\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.0}\n", .{
        @tagName(mode), workload, lanes, jobs, sample, elapsed_ns, checksum,
    });
}

fn runSingle(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
) !void {
    const ctx = JSGlobalContextCreate(null) orelse return error.JavaScriptCoreFailure;
    defer JSGlobalContextRelease(ctx);
    try configure(allocator, ctx, workload, jobs, 0);
    try warm(allocator, ctx, @max(@as(usize, 1), jobs / 10), jobs, 0);

    for (0..samples) |sample| {
        const started = nowNs(io);
        const checksum = try evaluate(ctx, invocation);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        try printRow(writer, .single, workload, 1, jobs, sample, elapsed, checksum);
    }
}

fn steadyLaneMain(lane: *SteadyLane) void {
    const allocator = std.heap.page_allocator;
    const ctx = JSGlobalContextCreate(null) orelse {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    defer JSGlobalContextRelease(ctx);
    configure(allocator, ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    warm(allocator, ctx, @max(@as(usize, 1), lane.jobs / 10), lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    lane.ready.post(lane.io);

    while (true) {
        lane.start.waitUncancelable(lane.io);
        if (lane.stop.load(.acquire)) return;
        lane.checksum = evaluate(ctx, invocation) catch {
            lane.failed.store(true, .release);
            lane.done.post(lane.io);
            return;
        };
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
    const allocator = std.heap.page_allocator;
    const ctx = JSGlobalContextCreate(null) orelse {
        lane.failed.store(true, .release);
        return;
    };
    defer JSGlobalContextRelease(ctx);
    configure(allocator, ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        return;
    };
    lane.checksum = evaluate(ctx, invocation) catch {
        lane.failed.store(true, .release);
        return;
    };
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
        .single => try runSingle(init.gpa, init.io, stdout, workload, jobs, samples),
        .independent_steady => try runIndependentSteady(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
        .independent_cold => try runIndependentCold(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
    }
    try stdout.flush();
}
