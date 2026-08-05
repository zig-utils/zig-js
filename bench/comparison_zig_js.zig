//! Machine-readable zig-js side of the JavaScriptCore comparison benchmark.
//!
//! Usage:
//!   bench-comparison-zig-js single <workload> <jobs> <samples>
//!   bench-comparison-zig-js independent_steady <workload> <jobs> <samples> <lanes>
//!   bench-comparison-zig-js independent_cold <workload> <jobs> <samples> <lanes>
//!   bench-comparison-zig-js shared <workload> <jobs> <samples> <lanes>
//!   bench-comparison-zig-js shared <workload> <jobs> <samples> <lanes> --gc-telemetry
//!   bench-comparison-zig-js attribution <workload> <jobs> 1
//!   bench-comparison-zig-js shared_attribution <workload> <jobs> 1 <lanes>
//!
//! Independent modes use one creator-thread-affine context per OS worker. In
//! steady mode worker/context setup and warm-up are outside every timed sample;
//! in cold mode thread/context/source setup and teardown are all timed. Shared
//! mode measures zig-js's distinct shared-realm JavaScript Thread model.

const std = @import("std");
const js = @import("js");
const representative_modules = @import("representative_modules.zig");

const workload_source = @embedFile("comparison.js");
const representative_workload_source = @embedFile("representative_comparison.js");
const wasm_simd_workload_source = @embedFile("wasm_simd_comparison.js");
const wasm_threads_workload_source = @embedFile("wasm_threads_comparison.js");
const invocation = "__benchmarkInvoke(__benchmarkJobs, __benchmarkLane)";
// Promise workloads finish during evaluate's host checkpoint. Read their
// checksum only after that checkpoint; synchronous rows retain one evaluation.
const checkpoint_checksum = "__benchmarkReadChecksum(__benchmarkJobs, 1, __benchmarkLane, false)";
const warmup_calls = 10;
// Every measured context uses the same process-wide production allocator.
// libc malloc keeps reusable slabs between contexts instead of translating
// arena/GC backing allocations into page-level mmap/munmap churn, is safe for
// independent workers, and matches JSC's cached process allocator more closely
// than mixing the runner allocator into the direct and shared rows.
const benchmark_context_allocator = std.heap.c_allocator;

const shared_harness =
    \\globalThis.__benchmarkRunShared = function(jobs, lanes) {
    \\  if (globalThis.__benchmarkPrepare)
    \\    globalThis.__benchmarkPrepare(jobs, lanes, 0, true);
    \\  var threads = [];
    \\  for (var lane = 0; lane < lanes; lane = lane + 1) {
    \\    threads.push(new Thread(globalThis.__benchmarkSelected, jobs, lane));
    \\  }
    \\  var checksum = 0;
    \\  for (var index = 0; index < threads.length; index = index + 1)
    \\    checksum = checksum + threads[index].join();
    \\  if (globalThis.__benchmarkFinish)
    \\    return globalThis.__benchmarkFinish(jobs, lanes, 0, true);
    \\  return checksum;
    \\};
;

const Mode = enum { single, single_profiled, independent_steady, independent_cold, shared, attribution, shared_attribution, module_cold, module_attribution };

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

const ModuleLane = struct {
    workload: []const u8,
    jobs: usize,
    lane: usize,
    failed: std.atomic.Value(bool) = .init(false),
    checksum: f64 = 0,
};

const ProcessResourceSnapshot = struct {
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    peak_rss_bytes: u64,
    retained_rss_bytes: u64,
};

fn timevalNs(value: std.c.timeval) u64 {
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.usec)) * std.time.ns_per_us;
}

fn processResourceSnapshot() !ProcessResourceSnapshot {
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    const task = std.c.mach_task_self();
    if (task == std.c.TASK.NULL) return error.ProcessResourceUnavailable;
    var vm_info: std.c.task_vm_info_data_t = std.mem.zeroes(std.c.task_vm_info_data_t);
    var info_count = std.c.TASK.VM.INFO_COUNT;
    const task_result = std.c.task_info(
        task,
        std.c.TASK.VM.INFO,
        @as(std.c.task_info_t, @ptrCast(&vm_info)),
        &info_count,
    );
    const resident_peak_info_count = std.math.divCeil(
        usize,
        @offsetOf(std.c.task_vm_info_data_t, "resident_size_peak") + @sizeOf(std.c.mach_vm_size_t),
        @sizeOf(std.c.natural_t),
    ) catch unreachable;
    // Older Darwin kernels may return fewer trailing task_vm_info fields than
    // the build SDK declares. Both resident fields are in the original prefix;
    // require exactly through resident_size_peak instead of fields this
    // measurement never reads.
    if (task_result != 0 or info_count < resident_peak_info_count) return error.ProcessResourceUnavailable;
    return .{
        .cpu_user_ns = timevalNs(usage.utime),
        .cpu_system_ns = timevalNs(usage.stime),
        // Keep peak and current resident size in one Mach accounting domain.
        // Darwin documents all non-CPU rusage fields as implementation-defined;
        // ru_maxrss can diverge from task_vm_info.resident_size under pressure.
        .peak_rss_bytes = @intCast(vm_info.resident_size_peak),
        .retained_rss_bytes = @intCast(vm_info.resident_size),
    };
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn evaluateShared(ctx: *js.Context, source: []const u8) !js.Value {
    return ctx.evaluate(source) catch |err| {
        var name: []const u8 = @errorName(err);
        var message: []const u8 = "";
        if (ctx.exception) |exception| {
            if (exception.isObject()) {
                const object = exception.asObj();
                if (object.errorName().len != 0) name = object.errorName();
                if (object.getOwn("name")) |value| if (value.isString()) {
                    name = value.asStr();
                };
                if (object.getOwn("message")) |value| if (value.isString()) {
                    message = value.asStr();
                };
            } else if (exception.isString()) {
                name = "ThrownString";
                message = exception.asStr();
            }
        }
        std.debug.print("shared benchmark exception: {s}: {s}\n", .{ name, message });
        return err;
    };
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

fn printTierAttributionRow(
    writer: *std.Io.Writer,
    mode: []const u8,
    workload: []const u8,
    lanes: usize,
    jobs: usize,
    phase: []const u8,
    checksum: f64,
    snapshot: js.Context.TierAttributionSnapshot,
    process: ProcessResourceSnapshot,
) !void {
    try writer.print("{{\"kind\":\"zig-js-tier-attribution\",\"mode\":\"{s}\",\"workload\":\"{s}\",\"lanes\":{d},\"jobs\":{d},\"phase\":\"{s}\",\"checksum\":{d:.0},\"execution\":{{", .{
        mode, workload, lanes, jobs, phase, checksum,
    });
    const execution_info = @typeInfo(js.ExecutionTierMetric).@"enum";
    inline for (execution_info.field_names, execution_info.field_values, 0..) |name, field_value, index| {
        if (index != 0) try writer.writeByte(',');
        const metric: js.ExecutionTierMetric = @fromBackingInt(@intCast(field_value));
        try writer.print("\"{s}\":{d}", .{ name, snapshot.execution.count(metric) });
    }
    try writer.writeAll("},\"timing\":{");
    inline for (comptime std.meta.fieldNames(@TypeOf(snapshot.timing)), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(snapshot.timing, name) });
    }
    try writer.writeAll("},\"admissions\":{");
    const admission_info = @typeInfo(js.BytecodeAdmissionReason).@"enum";
    inline for (admission_info.field_names, admission_info.field_values, 0..) |name, field_value, index| {
        if (index != 0) try writer.writeByte(',');
        const reason: js.BytecodeAdmissionReason = @fromBackingInt(@intCast(field_value));
        try writer.print("\"{s}\":{d}", .{ name, snapshot.admissions.count(reason) });
    }
    try writer.writeAll("},\"synchronization\":{");
    const synchronization = js.jsthread.contentionStats();
    inline for (comptime std.meta.fieldNames(js.jsthread.ContentionStats), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(synchronization, name) });
    }
    try writer.print("}},\"baseline_publications\":{d},\"optimizer_publications\":{d},\"generated_code_bytes\":{d},\"native_code\":{{\"live_artifacts\":{d},\"live_bytes\":{d},\"retired_artifacts\":{d},\"retired_bytes_current\":{d},\"reclaimed_artifacts\":{d},\"reclaimed_bytes_total\":{d},\"shape_invalidation_events\":{d},\"shape_retired_artifacts\":{d},\"shape_survivor_artifacts\":{d},\"shape_retired_bytes\":{d},\"full_invalidation_events\":{d},\"unknown_shape_invalidation_events\":{d},\"shape_fallback_events\":{d}}},\"heap\":{{\"live_bytes\":{d},\"last_full_collection_bytes\":{d},\"collections\":{d},\"full_collections\":{d}}}", .{
        snapshot.baseline_publications,
        snapshot.optimizer_publications,
        snapshot.generated_code_bytes,
        snapshot.native_code.live_artifacts,
        snapshot.native_code.live_bytes,
        snapshot.native_code.retired_artifacts,
        snapshot.native_code.retired_bytes_current,
        snapshot.native_code.reclaimed_artifacts,
        snapshot.native_code.reclaimed_bytes_total,
        snapshot.native_code.shape_invalidation_events,
        snapshot.native_code.shape_retired_artifacts,
        snapshot.native_code.shape_survivor_artifacts,
        snapshot.native_code.shape_retired_bytes,
        snapshot.native_code.full_invalidation_events,
        snapshot.native_code.unknown_shape_invalidation_events,
        snapshot.native_code.shape_fallback_events,
        snapshot.heap.live_bytes,
        snapshot.heap.last_full_collection_bytes,
        snapshot.heap.collections,
        snapshot.heap.full_collections,
    });
    try writer.writeAll(",\"allocation\":{");
    inline for (comptime std.meta.fieldNames(@TypeOf(snapshot.runtime.allocation)), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(snapshot.runtime.allocation, name) });
    }
    try writer.writeAll("},\"gc_pauses\":{\"minor_ns\":[");
    for (snapshot.runtime.minor_pauses.values[0..snapshot.runtime.minor_pauses.len], 0..) |pause_ns, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{pause_ns});
    }
    try writer.print("],\"minor_overflow\":{d},\"full_ns\":[", .{snapshot.runtime.minor_pauses.overflow});
    for (snapshot.runtime.full_pauses.values[0..snapshot.runtime.full_pauses.len], 0..) |pause_ns, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{pause_ns});
    }
    try writer.print("],\"full_overflow\":{d}}},\"process\":{{\"cpu_user_ns\":{d},\"cpu_system_ns\":{d},\"peak_rss_bytes\":{d},\"retained_rss_bytes\":{d}}}}}\n", .{
        snapshot.runtime.full_pauses.overflow,
        process.cpu_user_ns,
        process.cpu_system_ns,
        process.peak_rss_bytes,
        process.retained_rss_bytes,
    });
}

const gc_telemetry_header = "zig-js-gc\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum\tattempts\tcollections\ttimeouts\tpeer_parks\texit_cleanups\tpause_ns_total\tpause_ns_max\trendezvous_ns_total\trendezvous_ns_max\ttranche_bytes\tbytes_issued\tbytes_reset\tbytes_current\tminor_cycles\tminor_prepare_ns\tminor_trace_ns\tminor_sweep_ns\tminor_post_sweep_ns\tfull_cycles\tfull_prepare_ns\tfull_trace_ns\tfull_sweep_ns\tfull_post_sweep_ns\tobject_batch_calls\tobject_batch_cells\tobject_batch_ns_total\tobject_batch_ns_max\tworker_runs\tworker_run_ns\tworker_run_ns_max\tjoin_wait_ns\tjoin_parks\theap_collections\theap_minor_collections\theap_live_cells\theap_young_cells\theap_young_bytes\tlast_minor_young_bytes\tlast_minor_reclaimed_bytes\tlast_minor_survived_cells\tlast_minor_survived_bytes\tbacking_chunks\tbacking_capacity_slots\tbacking_live_slots\tbacking_free_slots\n";

fn printGcTelemetryRow(
    writer: *std.Io.Writer,
    workload: []const u8,
    lanes: usize,
    jobs: usize,
    sample: usize,
    elapsed_ns: u64,
    checksum: f64,
    before: js.Context.CooperativeGcProfile,
    after: js.Context.CooperativeGcProfile,
    threads: js.jsthread.ContentionStats,
) !void {
    try writer.print("zig-js-gc\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.0}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{
        workload,
        lanes,
        jobs,
        sample,
        elapsed_ns,
        checksum,
        after.attempts,
        after.collections,
        after.timeouts,
        after.peer_parks,
        after.exit_cleanups,
        after.pause_ns_total,
        after.pause_ns_max,
        after.rendezvous_ns_total,
        after.rendezvous_ns_max,
        after.tranche_bytes,
        after.bytesIssued(),
        after.bytes_reset_total,
        after.bytes_since_collection,
        after.minor_profile_cycles,
        after.minor_prepare_ns_total,
        after.minor_trace_ns_total,
        after.minor_sweep_ns_total,
        after.minor_post_sweep_ns_total,
        after.full_profile_cycles,
        after.full_prepare_ns_total,
        after.full_trace_ns_total,
        after.full_sweep_ns_total,
        after.full_post_sweep_ns_total,
    });
    try writer.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}", .{
        after.object_batch_calls,
        after.object_batch_cells,
        after.object_batch_ns_total,
        after.object_batch_ns_max,
        threads.worker_runs,
        threads.worker_run_ns,
        threads.worker_run_ns_max,
        threads.thread_join_wait_ns,
        threads.thread_join_parks,
    });
    try writer.print("\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        after.heap.collections -| before.heap.collections,
        after.heap.minor_collections -| before.heap.minor_collections,
        after.heap.live_cells,
        after.heap.young_cells,
        after.heap.young_bytes,
        after.heap.last_minor_young_bytes,
        after.heap.last_minor_reclaimed_bytes,
        after.heap.last_minor_survived_cells,
        after.heap.last_minor_survived_bytes,
        after.backing.chunks,
        after.backing.capacity_slots,
        after.backing.live_slots,
        after.backing.free_slots,
    });
}

fn configure(ctx: *js.Context, workload: []const u8, jobs: usize, lane: usize) !bool {
    const source_bytes = if (std.mem.startsWith(u8, workload, "wasm_threads_"))
        wasm_threads_workload_source
    else if (std.mem.startsWith(u8, workload, "wasm_"))
        wasm_simd_workload_source
    else if (std.mem.startsWith(u8, workload, "representative_"))
        representative_workload_source
    else
        workload_source;
    _ = try ctx.evaluate(source_bytes);
    const source = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkPrepare = undefined; globalThis.__benchmarkFinish = undefined; globalThis.__benchmarkReadChecksum = undefined; globalThis.__benchmarkSelected = benchmarkFunction(\"{s}\"); globalThis.__benchmarkInvoke = function(jobs, lane) {{ if (globalThis.__benchmarkPrepare) globalThis.__benchmarkPrepare(jobs, 1, lane, false); var result = globalThis.__benchmarkSelected(jobs, lane); return globalThis.__benchmarkFinish ? globalThis.__benchmarkFinish(jobs, 1, lane, false) : result; }}; globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{
        workload, jobs, lane,
    });
    _ = try ctx.evaluate(source);
    return (try ctx.evaluate("typeof globalThis.__benchmarkReadChecksum === 'function' ? 1 : 0")).toNumber() == 1;
}

fn invoke(ctx: *js.Context, checkpoint: bool) !js.Value {
    const result = try ctx.evaluate(invocation);
    return if (checkpoint) try ctx.evaluate(checkpoint_checksum) else result;
}

fn warm(ctx: *js.Context, warm_jobs: usize, jobs: usize, lane: usize, checkpoint: bool) !void {
    const warm_config = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{ warm_jobs, lane });
    _ = try ctx.evaluate(warm_config);
    for (0..warmup_calls) |_| _ = try invoke(ctx, checkpoint);
    const restore = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{ jobs, lane });
    _ = try ctx.evaluate(restore);
}

fn runSingle(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    mode: Mode,
    workload: []const u8,
    jobs: usize,
    samples: usize,
) !void {
    const ctx = try js.Context.createWith(allocator, .{
        .enable_gc = true,
        .profile_execution_tiers = mode == .single_profiled,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    });
    defer ctx.destroy();
    const checkpoint = try configure(ctx, workload, jobs, 0);
    try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0, checkpoint);

    for (0..samples) |sample| {
        const started = nowNs(io);
        const result = try invoke(ctx, checkpoint);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        try printRow(writer, mode, workload, 1, jobs, sample, elapsed, result.toNumber());
    }
}

fn runAttribution(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
) !void {
    js.jsthread.resetContentionStats();
    defer js.jsthread.disableContentionStats();
    const ctx = try js.Context.createWith(allocator, .{
        .enable_gc = true,
        .profile_execution_tiers = true,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    });
    defer ctx.destroy();
    const checkpoint = try configure(ctx, workload, jobs, 0);
    const configuration = ctx.tierAttributionSnapshot();
    const configuration_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "single", workload, 1, jobs, "configuration", 0, configuration, configuration_process);
    try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0, checkpoint);
    const warmed = ctx.tierAttributionSnapshot();
    const warmed_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "single", workload, 1, jobs, "warmup", 0, warmed, warmed_process);
    const result = try invoke(ctx, checkpoint);
    const invoked = ctx.tierAttributionSnapshot();
    const invoked_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "single", workload, 1, jobs, "invocation", result.toNumber(), invoked, invoked_process);
    _ = io;
}

fn steadyLaneMain(lane: *SteadyLane) void {
    const ctx = js.Context.createWith(benchmark_context_allocator, .{
        .enable_gc = true,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    }) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    defer ctx.destroy();
    const checkpoint = configure(ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    warm(ctx, @max(@as(usize, 1), lane.jobs / 10), lane.jobs, lane.lane, checkpoint) catch {
        lane.failed.store(true, .release);
        lane.ready.post(lane.io);
        return;
    };
    lane.ready.post(lane.io);

    while (true) {
        lane.start.waitUncancelable(lane.io);
        if (lane.stop.load(.acquire)) return;
        const result = invoke(ctx, checkpoint) catch {
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
    const ctx = js.Context.createWith(benchmark_context_allocator, .{
        .enable_gc = true,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    }) catch {
        lane.failed.store(true, .release);
        return;
    };
    defer ctx.destroy();
    const checkpoint = configure(ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        return;
    };
    const result = invoke(ctx, checkpoint) catch {
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

fn configureModuleGlobals(ctx: *js.Context, jobs: usize, lane: usize) !void {
    const source = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d}; globalThis.__representativeModuleChecksum = 0;", .{ jobs, lane });
    _ = try ctx.evaluate(source);
}

fn evaluateModuleWorkload(ctx: *js.Context, workload: []const u8, jobs: usize, lane: usize) !f64 {
    const profile = representative_modules.profile(workload) orelse return error.InvalidWorkload;
    try configureModuleGlobals(ctx, jobs, lane);
    _ = try ctx.evaluateModule(profile.entry_path, profile.entry_source, profile.host());
    return (try ctx.evaluate("globalThis.__representativeModuleChecksum")).toNumber();
}

fn moduleLaneMain(lane: *ModuleLane) void {
    const ctx = js.Context.createWith(benchmark_context_allocator, .{ .enable_gc = true }) catch {
        lane.failed.store(true, .release);
        return;
    };
    lane.checksum = evaluateModuleWorkload(ctx, lane.workload, lane.jobs, lane.lane) catch {
        lane.failed.store(true, .release);
        ctx.destroy();
        return;
    };
    ctx.destroy();
}

fn runModuleCold(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lane_count: usize,
) !void {
    _ = representative_modules.profile(workload) orelse return error.InvalidWorkload;
    const lanes = try allocator.alloc(ModuleLane, lane_count);
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
            threads[spawned] = std.Thread.spawn(.{}, moduleLaneMain, .{lane}) catch |err| {
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
        try printRow(writer, .module_cold, workload, lane_count, jobs, sample, elapsed, checksum);
    }
}

fn runModuleAttribution(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
) !void {
    js.jsthread.resetContentionStats();
    defer js.jsthread.disableContentionStats();
    const profile = representative_modules.profile(workload) orelse return error.InvalidWorkload;
    const ctx = try js.Context.createWith(allocator, .{
        .enable_gc = true,
        .profile_execution_tiers = true,
    });
    defer ctx.destroy();
    const configuration = ctx.tierAttributionSnapshot();
    const configuration_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "module_cold", workload, 1, jobs, "configuration", 0, configuration, configuration_process);
    try configureModuleGlobals(ctx, jobs, 0);
    const warmed = ctx.tierAttributionSnapshot();
    const warmed_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "module_cold", workload, 1, jobs, "warmup", 0, warmed, warmed_process);
    _ = try ctx.evaluateModule(profile.entry_path, profile.entry_source, profile.host());
    const checksum = (try ctx.evaluate("globalThis.__representativeModuleChecksum")).toNumber();
    const invoked = ctx.tierAttributionSnapshot();
    const invoked_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "module_cold", workload, 1, jobs, "invocation", checksum, invoked, invoked_process);
    _ = io;
}

fn runSharedAttribution(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    lanes: usize,
) !void {
    js.jsthread.resetContentionStats();
    defer js.jsthread.disableContentionStats();
    const ctx = try js.Context.createWith(allocator, .{
        .enable_threads = true,
        .profile_execution_tiers = true,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    });
    defer ctx.destroy();
    const checkpoint = try configure(ctx, workload, jobs, 0);
    _ = try ctx.evaluate(shared_harness);
    const shared_invocation = try std.fmt.allocPrint(ctx.arena(), "__benchmarkRunShared({d}, {d})", .{
        jobs, lanes,
    });
    const configuration = ctx.tierAttributionSnapshot();
    const configuration_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "shared", workload, lanes, jobs, "configuration", 0, configuration, configuration_process);

    if (!std.mem.eql(u8, workload, "wasm_threads_wait_notify")) {
        try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0, checkpoint);
        // Match the scored shared-mode lifecycle boundary: warm real workers,
        // then complete the first cooperative collection/reuse cycle.
        for (0..2) |_| _ = try evaluateShared(ctx, shared_invocation);
    }
    const warmed = ctx.tierAttributionSnapshot();
    const warmed_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "shared", workload, lanes, jobs, "warmup", 0, warmed, warmed_process);

    const result = try evaluateShared(ctx, shared_invocation);
    const invoked = ctx.tierAttributionSnapshot();
    const invoked_process = try processResourceSnapshot();
    try printTierAttributionRow(writer, "shared", workload, lanes, jobs, "invocation", result.toNumber(), invoked, invoked_process);
    _ = io;
}

fn runShared(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    lanes: usize,
    gc_telemetry: bool,
) !void {
    const ctx = try js.Context.createWith(allocator, .{
        .enable_threads = true,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    });
    defer ctx.destroy();
    const checkpoint = try configure(ctx, workload, jobs, 0);
    _ = try ctx.evaluate(shared_harness);
    const shared_invocation = try std.fmt.allocPrint(ctx.arena(), "__benchmarkRunShared({d}, {d})", .{
        jobs, lanes,
    });
    if (!std.mem.eql(u8, workload, "wasm_threads_wait_notify")) {
        try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0, checkpoint);
        // Warm the actual Thread lifecycle, then complete one collect/reuse
        // cycle before sample zero. One shared invocation only armed the first
        // cooperative collection, leaving the first recorded sample slower than
        // every later persistent-realm sample.
        for (0..2) |_| _ = try evaluateShared(ctx, shared_invocation);
    }
    if (gc_telemetry) try writer.writeAll(gc_telemetry_header);
    for (0..samples) |sample| {
        const before = if (gc_telemetry) ctx.cooperativeGcProfile().? else undefined;
        if (gc_telemetry) {
            js.jsthread.resetLifecycleStats();
            if (!ctx.beginCooperativeGcProfile()) return error.GcTelemetryUnavailable;
        }
        const started = nowNs(io);
        const result = try evaluateShared(ctx, shared_invocation);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        const thread_stats = if (gc_telemetry) js.jsthread.contentionStats() else undefined;
        if (gc_telemetry) js.jsthread.disableLifecycleStats();
        const gc_stats = if (gc_telemetry) ctx.endCooperativeGcProfile().? else undefined;
        try printRow(writer, .shared, workload, lanes, jobs, sample, elapsed, result.toNumber());
        if (gc_telemetry)
            try printGcTelemetryRow(writer, workload, lanes, jobs, sample, elapsed, result.toNumber(), before, gc_stats, thread_stats);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 5 or args.len > 7) return error.InvalidArguments;

    const mode = try parseMode(args[1]);
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    const lanes = if (mode == .single or mode == .single_profiled or mode == .attribution or mode == .module_attribution)
        1
    else if (args.len >= 6)
        try std.fmt.parseUnsigned(usize, args[5], 10)
    else
        return error.InvalidArguments;
    const gc_telemetry = args.len == 7 and std.mem.eql(u8, args[6], "--gc-telemetry");
    if (args.len == 7 and !gc_telemetry) return error.InvalidArguments;
    if (gc_telemetry and mode != .shared) return error.InvalidArguments;
    if ((mode == .attribution or mode == .shared_attribution or mode == .module_attribution) and samples != 1) return error.InvalidArguments;
    if (jobs == 0 or samples == 0 or lanes == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, workload, "wasm_threads_wait_notify") and
        ((mode != .shared and mode != .shared_attribution) or lanes < 2 or lanes % 2 != 0)) return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    switch (mode) {
        .single, .single_profiled => try runSingle(benchmark_context_allocator, init.io, stdout, mode, workload, jobs, samples),
        .independent_steady => try runIndependentSteady(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
        .independent_cold => try runIndependentCold(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
        .shared => try runShared(benchmark_context_allocator, init.io, stdout, workload, jobs, samples, lanes, gc_telemetry),
        .attribution => try runAttribution(benchmark_context_allocator, init.io, stdout, workload, jobs),
        .shared_attribution => try runSharedAttribution(benchmark_context_allocator, init.io, stdout, workload, jobs, lanes),
        .module_cold => try runModuleCold(init.gpa, init.io, stdout, workload, jobs, samples, lanes),
        .module_attribution => try runModuleAttribution(benchmark_context_allocator, init.io, stdout, workload, jobs),
    }
    try stdout.flush();
}
