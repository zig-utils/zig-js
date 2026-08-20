//! Machine-readable zig-js side of the JavaScriptCore comparison benchmark.
//!
//! Usage:
//!   bench-comparison-zig-js single <workload> <jobs> <samples>
//!   bench-comparison-zig-js single_observed <workload> <jobs> <samples>
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
const builtin = @import("builtin");
const js = @import("js");
const representative_modules = @import("representative_modules.zig");

const workload_source = @embedFile("comparison.js");
// Workload-specific fixtures are selected and configured before warmup.
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
    \\globalThis.__benchmarkPrepareShared = function(jobs, lanes) {
    \\  if (globalThis.__benchmarkPrepare) {
    \\    globalThis.__benchmarkPrepare(jobs, lanes, 0, true);
    \\    return true;
    \\  }
    \\  return false;
    \\};
    \\globalThis.__benchmarkRunShared = function(jobs, lanes) {
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

const Mode = enum { single, single_profiled, single_observed, independent_steady, independent_cold, shared, attribution, shared_attribution, module_cold, module_attribution, context_lifecycle };

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

const LifecycleScenario = enum {
    no_evaluation,
    first_source,
    first_module,
    full_feature,
};

const LifecycleTotals = struct {
    create_ns: u64 = 0,
    work_ns: u64 = 0,
    destroy_ns: u64 = 0,
    checksum: f64 = 0,
    max_live_rss_bytes: u64 = 0,
    post_destroy_rss_bytes: u64 = 0,
    rss_checkpoints: [4]u64 = @splat(0),
    finalizers: js.Context.GcFinalizerStats = .{},
};

// Darwin's public proc_pid_rusage RUSAGE_INFO_V6 layout. Keep the public field
// names and complete trailing storage: libproc writes the entire flavor, and a
// named layout prevents a new SDK field from silently shifting an array index.
const DarwinRusageInfoV6 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
    ri_flags: u64,
    ri_user_ptime: u64,
    ri_system_ptime: u64,
    ri_pinstructions: u64,
    ri_pcycles: u64,
    ri_energy_nj: u64,
    ri_penergy_nj: u64,
    ri_secure_time_in_system: u64,
    ri_secure_ptime_in_system: u64,
    ri_neural_footprint: u64,
    ri_lifetime_max_neural_footprint: u64,
    ri_interval_max_neural_footprint: u64,
    ri_conclave_footprint: u64,
    ri_page_wait_time_mach: u64,
    ri_page_cache_hits: u64,
    ri_reserved: [6]u64,
};
comptime {
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_user_time") == 16);
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_instructions") == 248);
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_energy_nj") == 336);
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_page_cache_hits") == 408);
    std.debug.assert(@sizeOf(DarwinRusageInfoV6) == 464);
}

const DarwinCounterSnapshot = struct {
    instructions: u64,
    cycles: u64,
    energy_nj: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    page_cache_hits: u64,
};

const rusage_info_v6 = 6;
extern "c" fn proc_pid_rusage(pid: std.c.pid_t, flavor: c_int, buffer: *anyopaque) c_int;
extern "c" fn zig_js_benchmark_thermal_state() i32;

fn darwinCounterSnapshot() !DarwinCounterSnapshot {
    if (builtin.os.tag != .macos) return error.DarwinRusageUnavailable;
    var info = std.mem.zeroes(DarwinRusageInfoV6);
    if (proc_pid_rusage(std.c.getpid(), rusage_info_v6, &info) != 0) return error.DarwinRusageUnavailable;
    return .{
        .package_idle_wakeups = info.ri_pkg_idle_wkups,
        .interrupt_wakeups = info.ri_interrupt_wkups,
        .pageins = info.ri_pageins,
        .instructions = info.ri_instructions,
        .cycles = info.ri_cycles,
        .energy_nj = info.ri_energy_nj,
        .page_cache_hits = info.ri_page_cache_hits,
    };
}

fn darwinThermalState() !i32 {
    if (builtin.os.tag != .macos) return error.DarwinThermalStateUnavailable;
    const state = zig_js_benchmark_thermal_state();
    if (state < 0 or state > 3) return error.DarwinThermalStateUnavailable;
    return state;
}

fn printDarwinCounterRow(
    writer: *std.Io.Writer,
    mode: Mode,
    workload: []const u8,
    jobs: usize,
    sample: usize,
    before: DarwinCounterSnapshot,
    after: DarwinCounterSnapshot,
    thermal_before: i32,
    thermal_after: i32,
) !void {
    try writer.print("zig-js-darwin-rusage\t{s}\t{s}\t{d}\t{d}\tmeasured\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @tagName(mode),
        workload,
        jobs,
        sample,
        after.instructions -| before.instructions,
        after.cycles -| before.cycles,
        after.energy_nj -| before.energy_nj,
        after.package_idle_wakeups -| before.package_idle_wakeups,
        after.interrupt_wakeups -| before.interrupt_wakeups,
        after.pageins -| before.pageins,
        after.page_cache_hits -| before.page_cache_hits,
        thermal_before,
        thermal_after,
    });
}

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

fn prepareShared(ctx: *js.Context, source: []const u8) !void {
    const prepared = try evaluateShared(ctx, source);
    // Fixture allocation can arm more than one cooperative cycle. Complete it
    // at this quiescent boundary so deferred collection cannot become the
    // scored workers' prologue. Workloads without preparation retain their
    // normal steady heap and do not pay an artificial collection.
    if (prepared.toBoolean()) ctx.collectGarbage();
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

fn printNativeObservabilityRow(
    writer: *std.Io.Writer,
    mode: Mode,
    workload: []const u8,
    jobs: usize,
    sample: usize,
    ctx: *js.Context,
) !void {
    const code = ctx.jit_owner.stats();
    const publisher = js.jit.gdbJitStats();
    const process = try processResourceSnapshot();
    try writer.print("zig-js-native-observability\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @tagName(mode),
        workload,
        jobs,
        sample,
        code.live_artifacts,
        code.live_bytes,
        ctx.jit_owner.baselinePublications(),
        ctx.jit_owner.optimizerPublications(),
        publisher.live_registrations,
        publisher.live_symfile_bytes,
        publisher.live_unwind_bytes,
        publisher.registrations,
        publisher.unregistrations,
        process.peak_rss_bytes,
        process.retained_rss_bytes,
    });
}

fn printNativeObservabilityRetiredRow(
    writer: *std.Io.Writer,
    mode: Mode,
    workload: []const u8,
    jobs: usize,
) !void {
    const publisher = js.jit.gdbJitStats();
    const process = try processResourceSnapshot();
    try writer.print("zig-js-native-observability-retired\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        @tagName(mode),
        workload,
        jobs,
        publisher.live_registrations,
        publisher.live_symfile_bytes,
        publisher.live_unwind_bytes,
        publisher.registrations,
        publisher.unregistrations,
        process.peak_rss_bytes,
        process.retained_rss_bytes,
    });
}

fn printPromiseProfileRow(
    writer: *std.Io.Writer,
    workload: []const u8,
    lanes: usize,
    jobs: usize,
    samples: usize,
    stats: js.promise_profile.PromiseStats,
    process: ProcessResourceSnapshot,
) !void {
    try writer.print("{{\"kind\":\"zig-js-promise-profile\",\"mode\":\"independent_steady\",\"workload\":\"{s}\",\"lanes\":{d},\"jobs\":{d},\"samples\":{d},\"counters\":{{", .{
        workload,
        lanes,
        jobs,
        samples,
    });
    inline for (comptime std.meta.fieldNames(js.promise_profile.PromiseStats), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(stats, name) });
    }
    try writer.print("}},\"process\":{{\"cpu_user_ns\":{d},\"cpu_system_ns\":{d},\"peak_rss_bytes\":{d},\"retained_rss_bytes\":{d}}}}}\n", .{
        process.cpu_user_ns,
        process.cpu_system_ns,
        process.peak_rss_bytes,
        process.retained_rss_bytes,
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
    try writer.writeAll("},\"shape\":{");
    const shape = js.shape.shapeStats();
    inline for (comptime std.meta.fieldNames(js.shape.ShapeStats), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(shape, name) });
    }
    try writer.writeAll("},\"debug_registry\":{");
    inline for (comptime std.meta.fieldNames(@TypeOf(snapshot.debug_registry)), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(snapshot.debug_registry, name) });
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
    try writer.writeAll("},\"cell_slab_lock\":{");
    inline for (comptime std.meta.fieldNames(@TypeOf(snapshot.runtime.cell_slab_lock)), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(snapshot.runtime.cell_slab_lock, name) });
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

fn evaluateRegistered(ctx: *js.Context, source: []const u8, source_url: []const u8) !js.Value {
    const script = try ctx.registerDebugScript(source, source_url, 1);
    const saved_script_id = ctx.debug_script_id;
    const saved_start_line = ctx.debug_script_start_line;
    defer {
        ctx.debug_script_id = saved_script_id;
        ctx.debug_script_start_line = saved_start_line;
    }
    ctx.debug_script_id = script.id;
    ctx.debug_script_start_line = script.start_line;
    return ctx.evaluate(source);
}

fn configure(ctx: *js.Context, workload: []const u8, jobs: usize, lane: usize, observed: bool) !bool {
    const source_bytes = if (std.mem.startsWith(u8, workload, "wasm_threads_"))
        wasm_threads_workload_source
    else if (std.mem.startsWith(u8, workload, "wasm_"))
        wasm_simd_workload_source
    else if (std.mem.startsWith(u8, workload, "representative_"))
        representative_workload_source
    else
        workload_source;
    if (observed) {
        const source_url = if (std.mem.startsWith(u8, workload, "wasm_threads_"))
            "bench/wasm_threads_comparison.js"
        else if (std.mem.startsWith(u8, workload, "wasm_"))
            "bench/wasm_simd_comparison.js"
        else if (std.mem.startsWith(u8, workload, "representative_"))
            "bench/representative_comparison.js"
        else
            "bench/comparison.js";
        _ = try evaluateRegistered(ctx, source_bytes, source_url);
    } else {
        _ = try ctx.evaluate(source_bytes);
    }
    const source = try std.fmt.allocPrint(ctx.arena(), "globalThis.__benchmarkPrepare = undefined; globalThis.__benchmarkFinish = undefined; globalThis.__benchmarkReadChecksum = undefined; globalThis.__benchmarkSelected = benchmarkFunction(\"{s}\"); globalThis.__benchmarkInvoke = function(jobs, lane) {{ if (globalThis.__benchmarkPrepare) globalThis.__benchmarkPrepare(jobs, 1, lane, false); var result = globalThis.__benchmarkSelected(jobs, lane); return globalThis.__benchmarkFinish ? globalThis.__benchmarkFinish(jobs, 1, lane, false) : result; }}; globalThis.__benchmarkJobs = {d}; globalThis.__benchmarkLane = {d};", .{
        workload, jobs, lane,
    });
    if (observed)
        _ = try evaluateRegistered(ctx, source, "bench/comparison-runner.js")
    else
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

fn preparePostWarmupFixture(ctx: *js.Context, workload: []const u8) !void {
    if (!std.mem.startsWith(u8, workload, "representative_weak_post_compact_")) return;
    const result = ctx.compactGarbage();
    if (result.status != .compacted or result.moved_cells == 0)
        return error.BenchmarkMovingCollectionUnavailable;
}

fn runSingle(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    mode: Mode,
    workload: []const u8,
    jobs: usize,
    samples: usize,
    darwin_rusage: bool,
    native_observability_telemetry: bool,
) !void {
    const observed = mode == .single_observed;
    const ctx = try js.Context.createWith(allocator, .{
        .enable_gc = true,
        .profile_execution_tiers = mode == .single_profiled,
        .native_code_publisher = if (observed) js.jit.gdbJitPublisher() else null,
        .wasm_features = .{
            .nontrapping_float_to_int = true,
            .fixed_width_simd = true,
            .threads = true,
        },
    });
    var context_live = true;
    errdefer if (context_live) ctx.destroy();
    const checkpoint = try configure(ctx, workload, jobs, 0, observed);
    try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0, checkpoint);
    try preparePostWarmupFixture(ctx, workload);

    for (0..samples) |sample| {
        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const started = nowNs(io);
        const result = try invoke(ctx, checkpoint);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        const counters_after = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const thermal_after = if (darwin_rusage) try darwinThermalState() else undefined;
        try printRow(writer, mode, workload, 1, jobs, sample, elapsed, result.toNumber());
        if (darwin_rusage) try printDarwinCounterRow(writer, mode, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);
        if (native_observability_telemetry)
            try printNativeObservabilityRow(writer, mode, workload, jobs, sample, ctx);
    }
    ctx.destroy();
    context_live = false;
    if (native_observability_telemetry)
        try printNativeObservabilityRetiredRow(writer, mode, workload, jobs);
}

fn runDarwinRusageNoOp(writer: *std.Io.Writer) !void {
    const thermal_before = try darwinThermalState();
    const before = try darwinCounterSnapshot();
    const after = try darwinCounterSnapshot();
    const thermal_after = try darwinThermalState();
    try printDarwinCounterRow(writer, .single, "counter_noop", 1, 0, before, after, thermal_before, thermal_after);
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
    js.shape.resetShapeStats();
    defer js.shape.disableShapeStats();
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
    const checkpoint = try configure(ctx, workload, jobs, 0, false);
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
    const checkpoint = configure(ctx, lane.workload, lane.jobs, lane.lane, false) catch {
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
    darwin_rusage: bool,
    promise_profile_enabled: bool,
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

    if (promise_profile_enabled) js.promise_profile.resetPromiseStats();
    errdefer if (promise_profile_enabled) js.promise_profile.disablePromiseStats();

    for (0..samples) |sample| {
        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const started = nowNs(io);
        for (lanes) |*lane| lane.start.post(io);
        for (0..lane_count) |_| done.waitUncancelable(io);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        const counters_after = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const thermal_after = if (darwin_rusage) try darwinThermalState() else undefined;

        var checksum: f64 = 0;
        for (lanes) |*lane| {
            if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;
            checksum += lane.checksum;
        }
        try printRow(writer, .independent_steady, workload, lane_count, jobs, sample, elapsed, checksum);
        if (darwin_rusage) try printDarwinCounterRow(writer, .independent_steady, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);
    }
    if (promise_profile_enabled) {
        const stats = js.promise_profile.promiseStats();
        js.promise_profile.disablePromiseStats();
        try printPromiseProfileRow(writer, workload, lane_count, jobs, samples, stats, try processResourceSnapshot());
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
    const checkpoint = configure(ctx, lane.workload, lane.jobs, lane.lane, false) catch {
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
    darwin_rusage: bool,
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

        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
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
        const counters_after = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const thermal_after = if (darwin_rusage) try darwinThermalState() else undefined;

        var checksum: f64 = 0;
        for (lanes) |*lane| {
            if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;
            checksum += lane.checksum;
        }
        try printRow(writer, .independent_cold, workload, lane_count, jobs, sample, elapsed, checksum);
        if (darwin_rusage) try printDarwinCounterRow(writer, .independent_cold, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);
    }
}

fn parseLifecycleScenario(workload: []const u8) !LifecycleScenario {
    if (std.mem.eql(u8, workload, "context_no_evaluation")) return .no_evaluation;
    if (std.mem.eql(u8, workload, "context_first_source")) return .first_source;
    if (std.mem.eql(u8, workload, "context_first_module")) return .first_module;
    if (std.mem.eql(u8, workload, "context_full_feature")) return .full_feature;
    return error.InvalidWorkload;
}

fn lifecycleOptions(scenario: LifecycleScenario) js.Context.Options {
    if (scenario != .full_feature) return .{ .enable_gc = true };
    return .{
        .enable_gc = true,
        .wasm_features = .{
            .sign_extension_ops = true,
            .nontrapping_float_to_int = true,
            .multi_value = true,
            .reference_types = true,
            .bulk_memory = true,
            .fixed_width_simd = true,
            .relaxed_simd = true,
            .threads = true,
            .tail_calls = true,
            .typed_function_references = true,
            .gc = true,
            .exception_handling = true,
            .memory64 = true,
            .multi_memory = true,
        },
    };
}

fn lifecycleWork(ctx: *js.Context, scenario: LifecycleScenario) !f64 {
    return switch (scenario) {
        .no_evaluation => 0,
        .first_source => (try ctx.evaluate("21 + 21")).toNumber(),
        .first_module => module: {
            const Host = struct {
                fn load(_: *anyopaque, _: []const u8, _: []const u8, _: *[]const u8) ?[]const u8 {
                    return null;
                }
            };
            var token: u8 = 0;
            _ = try ctx.evaluateModule(
                "context-lifecycle-entry.js",
                "export const answer = 42; globalThis.__contextLifecycleChecksum = answer;",
                .{ .ctx = &token, .load = Host.load },
            );
            break :module (try ctx.evaluate("globalThis.__contextLifecycleChecksum")).toNumber();
        },
        .full_feature => (try ctx.evaluate(
            \\(function () {
            \\  class Box { constructor(value) { this.value = value; } }
            \\  var bytes = new Uint8Array([3, 5, 8, 13]);
            \\  var text = JSON.stringify({ label: "cold-context", value: bytes[3] });
            \\  var matched = /cold-context/.test(text);
            \\  return new Box(bytes[0] + bytes[1] + bytes[2] + bytes[3] + (matched ? 13 : 0)).value;
            \\})()
        )).toNumber(),
    };
}

fn addFinalizerStats(total: *js.Context.GcFinalizerStats, sample: js.Context.GcFinalizerStats) void {
    inline for (@typeInfo(js.Context.GcFinalizerStats).@"struct".field_names) |name|
        @field(total, name) += @field(sample, name);
}

fn printLifecycleTelemetry(
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    sample: usize,
    baseline: ProcessResourceSnapshot,
    after: ProcessResourceSnapshot,
    totals: LifecycleTotals,
) !void {
    const retained_delta: i128 = @as(i128, after.retained_rss_bytes) - @as(i128, baseline.retained_rss_bytes);
    const finalizers = totals.finalizers;
    const options_profile = if (std.mem.eql(u8, workload, "context_full_feature")) "gc_full_wasm" else "gc_default";
    try writer.print(
        "zig-js-context-lifecycle\t{{\"schema_version\":1,\"scenario\":\"{s}\",\"context_options_profile\":\"{s}\",\"iterations\":{d},\"sample\":{d},\"create_ns\":{d},\"work_ns\":{d},\"destroy_ns\":{d},\"phase_total_ns\":{d},\"cpu_user_ns\":{d},\"cpu_system_ns\":{d},\"baseline_rss_bytes\":{d},\"max_live_rss_bytes\":{d},\"post_destroy_rss_bytes\":{d},\"retained_delta_bytes\":{d},\"peak_rss_bytes\":{d},\"rss_checkpoints\":[{d},{d},{d},{d}],\"finalizers\":{{",
        .{
            workload,
            options_profile,
            jobs,
            sample,
            totals.create_ns,
            totals.work_ns,
            totals.destroy_ns,
            totals.create_ns + totals.work_ns + totals.destroy_ns,
            after.cpu_user_ns -| baseline.cpu_user_ns,
            after.cpu_system_ns -| baseline.cpu_system_ns,
            baseline.retained_rss_bytes,
            totals.max_live_rss_bytes,
            totals.post_destroy_rss_bytes,
            retained_delta,
            after.peak_rss_bytes,
            totals.rss_checkpoints[0],
            totals.rss_checkpoints[1],
            totals.rss_checkpoints[2],
            totals.rss_checkpoints[3],
        },
    );
    try writer.print(
        "\"cells\":{d},\"bulk_cell_frees_skipped\":{d},\"objects\":{d},\"strings\":{d},\"environments\":{d},\"functions\":{d},\"bound_functions\":{d},\"promises\":{d},\"generators\":{d},\"iter_helpers\":{d},\"module_namespaces\":{d},\"object_backing_releases\":{d},\"array_buffers\":{d},\"shared_array_buffers\":{d},\"promise_reactions\":{d}}}}}\n",
        .{
            finalizers.cells,
            finalizers.bulk_cell_frees_skipped,
            finalizers.objects,
            finalizers.strings,
            finalizers.environments,
            finalizers.functions,
            finalizers.bound_functions,
            finalizers.promises,
            finalizers.generators,
            finalizers.iter_helpers,
            finalizers.module_namespaces,
            finalizers.object_backing_releases,
            finalizers.array_buffers,
            finalizers.shared_array_buffers,
            finalizers.promise_reactions,
        },
    );
}

fn runContextLifecycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    samples: usize,
) !void {
    const scenario = try parseLifecycleScenario(workload);
    const checkpoint_targets = [4]usize{
        std.math.divCeil(usize, jobs, 4) catch unreachable,
        std.math.divCeil(usize, jobs *| 2, 4) catch unreachable,
        std.math.divCeil(usize, jobs *| 3, 4) catch unreachable,
        jobs,
    };
    for (0..samples) |sample| {
        const thermal_before = try darwinThermalState();
        const counters_before = try darwinCounterSnapshot();
        const baseline = try processResourceSnapshot();
        var totals: LifecycleTotals = .{};
        var checkpoint_index: usize = 0;
        for (0..jobs) |iteration| {
            const create_started = nowNs(io);
            const ctx = try js.Context.createWith(allocator, lifecycleOptions(scenario));
            totals.create_ns += @intCast(nowNs(io) - create_started);
            var finalizers: js.Context.GcFinalizerStats = .{};
            ctx.gc_finalizer_stats_out = &finalizers;
            const after_create = try processResourceSnapshot();
            totals.max_live_rss_bytes = @max(totals.max_live_rss_bytes, after_create.retained_rss_bytes);

            const work_started = nowNs(io);
            totals.checksum += lifecycleWork(ctx, scenario) catch |err| {
                ctx.destroy();
                return err;
            };
            totals.work_ns += @intCast(nowNs(io) - work_started);
            const after_work = try processResourceSnapshot();
            totals.max_live_rss_bytes = @max(totals.max_live_rss_bytes, after_work.retained_rss_bytes);

            const destroy_started = nowNs(io);
            ctx.destroy();
            totals.destroy_ns += @intCast(nowNs(io) - destroy_started);
            addFinalizerStats(&totals.finalizers, finalizers);
            const after_destroy = try processResourceSnapshot();
            totals.post_destroy_rss_bytes = after_destroy.retained_rss_bytes;
            while (checkpoint_index < checkpoint_targets.len and iteration + 1 >= checkpoint_targets[checkpoint_index]) : (checkpoint_index += 1)
                totals.rss_checkpoints[checkpoint_index] = after_destroy.retained_rss_bytes;
        }
        const after = try processResourceSnapshot();
        const counters_after = try darwinCounterSnapshot();
        const thermal_after = try darwinThermalState();
        const phase_total = totals.create_ns + totals.work_ns + totals.destroy_ns;
        try printRow(writer, .context_lifecycle, workload, 1, jobs, sample, phase_total, totals.checksum);
        try printDarwinCounterRow(writer, .context_lifecycle, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);
        try printLifecycleTelemetry(writer, workload, jobs, sample, baseline, after, totals);
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
    darwin_rusage: bool,
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

        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
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
        const counters_after = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const thermal_after = if (darwin_rusage) try darwinThermalState() else undefined;

        var checksum: f64 = 0;
        for (lanes) |*lane| {
            if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;
            checksum += lane.checksum;
        }
        try printRow(writer, .module_cold, workload, lane_count, jobs, sample, elapsed, checksum);
        if (darwin_rusage) try printDarwinCounterRow(writer, .module_cold, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);
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
    js.shape.resetShapeStats();
    defer js.shape.disableShapeStats();
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
    const checkpoint = try configure(ctx, workload, jobs, 0, false);
    _ = try ctx.evaluate(shared_harness);
    const shared_prepare = try std.fmt.allocPrint(ctx.arena(), "__benchmarkPrepareShared({d}, {d})", .{
        jobs, lanes,
    });
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
        for (0..2) |_| {
            try prepareShared(ctx, shared_prepare);
            _ = try evaluateShared(ctx, shared_invocation);
        }
    }
    // Prepare the exact scored fixture before the attribution snapshot. This
    // keeps key/string construction and any resulting collection outside the
    // invocation delta while retaining the same worker-visible frozen inputs.
    try prepareShared(ctx, shared_prepare);
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
    darwin_rusage: bool,
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
    const checkpoint = try configure(ctx, workload, jobs, 0, false);
    _ = try ctx.evaluate(shared_harness);
    const shared_prepare = try std.fmt.allocPrint(ctx.arena(), "__benchmarkPrepareShared({d}, {d})", .{
        jobs, lanes,
    });
    const shared_invocation = try std.fmt.allocPrint(ctx.arena(), "__benchmarkRunShared({d}, {d})", .{
        jobs, lanes,
    });
    if (!std.mem.eql(u8, workload, "wasm_threads_wait_notify")) {
        try warm(ctx, @max(@as(usize, 1), jobs / 10), jobs, 0, checkpoint);
        // Warm the actual Thread lifecycle, then complete one collect/reuse
        // cycle before sample zero. One shared invocation only armed the first
        // cooperative collection, leaving the first recorded sample slower than
        // every later persistent-realm sample.
        for (0..2) |_| {
            try prepareShared(ctx, shared_prepare);
            _ = try evaluateShared(ctx, shared_invocation);
        }
    }
    if (gc_telemetry) try writer.writeAll(gc_telemetry_header);
    for (0..samples) |sample| {
        // Fixture construction is deliberately outside both the wall timer and
        // the GC counter delta. The scored boundary begins with fully prepared,
        // immutable lane inputs and still creates/joins every JavaScript Thread.
        try prepareShared(ctx, shared_prepare);
        const before = if (gc_telemetry) ctx.cooperativeGcProfile().? else undefined;
        if (gc_telemetry) {
            js.jsthread.resetLifecycleStats();
            if (!ctx.beginCooperativeGcProfile()) return error.GcTelemetryUnavailable;
        }
        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const started = nowNs(io);
        const result = try evaluateShared(ctx, shared_invocation);
        const elapsed: u64 = @intCast(nowNs(io) - started);
        const counters_after = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const thermal_after = if (darwin_rusage) try darwinThermalState() else undefined;
        const thread_stats = if (gc_telemetry) js.jsthread.contentionStats() else undefined;
        if (gc_telemetry) js.jsthread.disableLifecycleStats();
        const gc_stats = if (gc_telemetry) ctx.endCooperativeGcProfile().? else undefined;
        try printRow(writer, .shared, workload, lanes, jobs, sample, elapsed, result.toNumber());
        if (darwin_rusage) try printDarwinCounterRow(writer, .shared, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);
        if (gc_telemetry)
            try printGcTelemetryRow(writer, workload, lanes, jobs, sample, elapsed, result.toNumber(), before, gc_stats, thread_stats);
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--darwin-rusage-noop")) {
        var noop_buffer: [1024]u8 = undefined;
        var noop_writer = std.Io.File.stdout().writer(init.io, &noop_buffer);
        try runDarwinRusageNoOp(&noop_writer.interface);
        try noop_writer.interface.flush();
        return;
    }
    if (args.len < 5 or args.len > 7) return error.InvalidArguments;

    const mode = try parseMode(args[1]);
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    const has_lanes = mode == .independent_steady or mode == .independent_cold or mode == .shared or mode == .shared_attribution or mode == .module_cold;
    const base_len: usize = if (has_lanes) 6 else 5;
    if (args.len != base_len and args.len != base_len + 1) return error.InvalidArguments;
    const lanes = if (has_lanes) try std.fmt.parseUnsigned(usize, args[5], 10) else 1;
    const option = if (args.len == base_len + 1) args[base_len] else "";
    const native_observability_telemetry = std.mem.eql(u8, option, "--native-observability-telemetry");
    const darwin_rusage = std.mem.eql(u8, option, "--darwin-rusage") or native_observability_telemetry;
    const gc_telemetry = std.mem.eql(u8, option, "--gc-telemetry");
    const promise_profile_enabled = std.mem.eql(u8, option, "--promise-profile");
    if (option.len != 0 and !darwin_rusage and !gc_telemetry and !promise_profile_enabled) return error.InvalidArguments;
    if (darwin_rusage and (mode == .attribution or mode == .shared_attribution or mode == .module_attribution)) return error.InvalidArguments;
    if (native_observability_telemetry and mode != .single and mode != .single_observed) return error.InvalidArguments;
    if (gc_telemetry and mode != .shared) return error.InvalidArguments;
    if (promise_profile_enabled and mode != .independent_steady) return error.InvalidArguments;
    if (mode == .context_lifecycle and !darwin_rusage) return error.InvalidArguments;
    if ((mode == .attribution or mode == .shared_attribution or mode == .module_attribution) and samples != 1) return error.InvalidArguments;
    if (jobs == 0 or samples == 0 or lanes == 0) return error.InvalidArguments;
    if (std.mem.eql(u8, workload, "wasm_threads_wait_notify") and
        ((mode != .shared and mode != .shared_attribution) or lanes < 2 or lanes % 2 != 0)) return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    switch (mode) {
        .single, .single_profiled, .single_observed => try runSingle(benchmark_context_allocator, init.io, stdout, mode, workload, jobs, samples, darwin_rusage, native_observability_telemetry),
        .independent_steady => try runIndependentSteady(init.gpa, init.io, stdout, workload, jobs, samples, lanes, darwin_rusage, promise_profile_enabled),
        .independent_cold => try runIndependentCold(init.gpa, init.io, stdout, workload, jobs, samples, lanes, darwin_rusage),
        .shared => try runShared(benchmark_context_allocator, init.io, stdout, workload, jobs, samples, lanes, gc_telemetry, darwin_rusage),
        .attribution => try runAttribution(benchmark_context_allocator, init.io, stdout, workload, jobs),
        .shared_attribution => try runSharedAttribution(benchmark_context_allocator, init.io, stdout, workload, jobs, lanes),
        .module_cold => try runModuleCold(init.gpa, init.io, stdout, workload, jobs, samples, lanes, darwin_rusage),
        .module_attribution => try runModuleAttribution(benchmark_context_allocator, init.io, stdout, workload, jobs),
        .context_lifecycle => try runContextLifecycle(benchmark_context_allocator, init.io, stdout, workload, jobs, samples),
    }
    try stdout.flush();
}
