//! Machine-readable system-JavaScriptCore side of the comparison benchmark.
//!
//! Single mode reuses one warmed JSGlobalContext. Contexts mode prepares one
//! independent warmed JSGlobalContext per lane, then includes OS-thread spawn,
//! evaluation, and join in the timed region. Context teardown happens later.

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

const Mode = enum { single, contexts };

const Lane = struct {
    workload: []const u8,
    jobs: usize,
    lane: usize,
    context: JSGlobalContextRef = null,
    checksum: f64 = 0,
    failed: std.atomic.Value(bool) = .init(false),
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn parseMode(text: []const u8) !Mode {
    if (std.mem.eql(u8, text, "single")) return .single;
    if (std.mem.eql(u8, text, "contexts")) return .contexts;
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
    _ = try evaluate(ctx, workload_source);
    const source = try std.fmt.allocPrintSentinel(allocator, "globalThis.__benchmarkName = \"{s}\"; globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{
        workload, jobs, lane,
    }, 0);
    defer allocator.free(source);
    _ = try evaluate(ctx, source);
}

fn warm(
    allocator: std.mem.Allocator,
    ctx: JSGlobalContextRef,
    warm_jobs: usize,
    lane: usize,
) !void {
    const source = try std.fmt.allocPrintSentinel(allocator, "runBenchmark(__benchmarkName, {d}, {d})", .{ warm_jobs, lane }, 0);
    defer allocator.free(source);
    for (0..3) |_| _ = try evaluate(ctx, source);
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
    try warm(allocator, ctx, @max(@as(usize, 1), jobs / 10), 0);

    const invocation: [:0]const u8 = "runBenchmark(__benchmarkName, __benchmarkJobs, 0)";
    for (0..samples) |sample| {
        const started = nowNs(io);
        const checksum = try evaluate(ctx, invocation);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        try printRow(writer, .single, workload, 1, jobs, sample, elapsed, checksum);
    }
}

fn laneMain(lane: *Lane) void {
    const ctx = lane.context orelse {
        lane.failed.store(true, .release);
        return;
    };
    lane.checksum = evaluate(ctx, "runBenchmark(__benchmarkName, __benchmarkJobs, __benchmarkLane)") catch {
        lane.failed.store(true, .release);
        return;
    };
}

fn runContexts(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lane_count: usize,
) !void {
    const lanes = try allocator.alloc(Lane, lane_count);
    defer allocator.free(lanes);
    const threads = try allocator.alloc(std.Thread, lane_count);
    defer allocator.free(threads);

    for (0..samples) |sample| {
        for (lanes, 0..) |*lane, lane_index| {
            lane.* = .{
                .workload = workload,
                .jobs = jobs,
                .lane = lane_index,
            };
            const ctx = JSGlobalContextCreate(null) orelse return error.JavaScriptCoreFailure;
            lane.context = ctx;
            errdefer JSGlobalContextRelease(ctx);
            try configure(allocator, ctx, workload, jobs, lane_index);
            try warm(allocator, ctx, @max(@as(usize, 1), jobs / 10), lane_index);
        }

        const started = nowNs(io);
        for (lanes, 0..) |*lane, lane_index|
            threads[lane_index] = try std.Thread.spawn(.{}, laneMain, .{lane});
        for (threads) |thread| thread.join();
        const elapsed: u64 = @intCast(nowNs(io) - started);

        var checksum: f64 = 0;
        for (lanes) |*lane| {
            defer if (lane.context) |ctx| JSGlobalContextRelease(ctx);
            if (lane.failed.load(.acquire)) return error.JavaScriptCoreFailure;
            checksum += lane.checksum;
        }
        try printRow(writer, .contexts, workload, lane_count, jobs, sample, elapsed, checksum);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5 and args.len != 6) return error.InvalidArguments;

    const mode = try parseMode(args[1]);
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    const lanes = if (mode == .contexts)
        if (args.len == 6) try std.fmt.parseUnsigned(usize, args[5], 10) else return error.InvalidArguments
    else
        1;
    if (jobs == 0 or samples == 0 or lanes == 0) return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    switch (mode) {
        .single => try runSingle(init.gpa, init.io, stdout, workload, jobs, samples),
        .contexts => try runContexts(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
    }
    try stdout.flush();
}
