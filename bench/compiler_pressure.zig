//! Synchronous native-compiler pressure benchmark for independent Contexts.
//!
//! Every lane owns one creator-thread-affine Context. The cold boundary includes
//! OS-thread creation, Context/source setup, bytecode compilation, and enough
//! calls to cross the native-tier thresholds. The warm boundary reuses those
//! live Contexts and separates steady execution from cold compiler pressure.
//!
//! Usage:
//!   compiler-pressure-benchmark <jit_on|jit_off> <lanes> <jobs> <samples>
//!   compiler-pressure-benchmark --self-test

const std = @import("std");
const builtin = @import("builtin");
const js = @import("js");

const workload_source = @embedFile("compiler_pressure.js");
const workload_source_path = "bench/compiler_pressure.js";
const workload_source_sha256 = "7260df7f15efb177a067d8457df244044b6ea3c4c7e39b3225726228ba46d83f";
const benchmark_allocator = std.heap.c_allocator;
const schema_version = 2;
const cold_invocations = 10;
const warm_invocations = 3;

const Mode = enum {
    jit_on,
    jit_off,
};

const Phase = enum {
    cold,
    warm,
};

const ProcessResourceSnapshot = struct {
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    peak_rss_bytes: u64,
    retained_rss_bytes: u64,
};

const CompilerSnapshot = struct {
    baseline_attempts: u64 = 0,
    baseline_tier_ups: u64 = 0,
    baseline_tier_up_ns: u64 = 0,
    baseline_failures: u64 = 0,
    baseline_failure_ns: u64 = 0,
    optimizer_attempts: u64 = 0,
    optimizer_tier_ups: u64 = 0,
    optimizer_tier_up_ns: u64 = 0,
    optimizer_failures: u64 = 0,
    optimizer_failure_ns: u64 = 0,
    baseline_publications: u64 = 0,
    optimizer_publications: u64 = 0,
    generated_code_bytes: u64 = 0,

    fn capture(ctx: *js.Context) CompilerSnapshot {
        const snapshot = ctx.tierAttributionSnapshot();
        return .{
            .baseline_attempts = snapshot.timing.baseline_attempts,
            .baseline_tier_ups = snapshot.timing.baseline_tier_ups,
            .baseline_tier_up_ns = snapshot.timing.baseline_tier_up_ns,
            .baseline_failures = snapshot.timing.baseline_failures,
            .baseline_failure_ns = snapshot.timing.baseline_failure_ns,
            .optimizer_attempts = snapshot.timing.optimizer_attempts,
            .optimizer_tier_ups = snapshot.timing.optimizer_tier_ups,
            .optimizer_tier_up_ns = snapshot.timing.optimizer_tier_up_ns,
            .optimizer_failures = snapshot.timing.optimizer_failures,
            .optimizer_failure_ns = snapshot.timing.optimizer_failure_ns,
            .baseline_publications = snapshot.baseline_publications,
            .optimizer_publications = snapshot.optimizer_publications,
            .generated_code_bytes = @intCast(snapshot.generated_code_bytes),
        };
    }

    fn add(self: *CompilerSnapshot, other: CompilerSnapshot) void {
        inline for (comptime std.meta.fieldNames(CompilerSnapshot)) |name|
            @field(self, name) += @field(other, name);
    }

    fn subtract(after: CompilerSnapshot, before: CompilerSnapshot) CompilerSnapshot {
        var result: CompilerSnapshot = .{};
        inline for (comptime std.meta.fieldNames(CompilerSnapshot)) |name|
            @field(result, name) = @field(after, name) -| @field(before, name);
        return result;
    }

    fn publications(self: CompilerSnapshot) u64 {
        return self.baseline_publications + self.optimizer_publications;
    }
};

const RuntimePoint = struct {
    schema_version: u32,
    requests: u64,
    starts: u64,
    completions: u64,
    typed_slot_reuses: u64,
    nested_reuses: u64,
    host_reserved_admissions: u64,
    general_slot_admissions: u64,
    waits: u64,
    wait_ns: u64,
    active: u64,
    waiters: u64,
    peak_active: u64,
    peak_waiters: u64,
    wait_ns_max: u64,
    general_active: u64,
    host_reserved_active: u64,
    peak_general_active: u64,
    peak_host_reserved_active: u64,

    fn capture() RuntimePoint {
        const snapshot = js.runtimeThreadSnapshot();
        const work = snapshot.work(.native_compilation);
        return .{
            .schema_version = snapshot.schema_version,
            .requests = work.requests,
            .starts = work.starts,
            .completions = work.completions,
            .typed_slot_reuses = work.typed_slot_reuses,
            .nested_reuses = work.nested_reuses,
            .host_reserved_admissions = work.host_reserved_admissions,
            .general_slot_admissions = work.general_slot_admissions,
            .waits = work.waits,
            .wait_ns = work.wait_ns,
            .active = work.active,
            .waiters = work.waiters,
            .peak_active = work.peak_active,
            .peak_waiters = work.peak_waiters,
            .wait_ns_max = work.wait_ns_max,
            .general_active = snapshot.scheduler.internal_work_general_active,
            .host_reserved_active = snapshot.scheduler.host_work_reserved_active,
            .peak_general_active = snapshot.scheduler.peak_internal_work_general_active,
            .peak_host_reserved_active = snapshot.scheduler.peak_host_work_reserved_active,
        };
    }
};

const RuntimePhase = struct {
    requests: u64,
    starts: u64,
    completions: u64,
    typed_slot_reuses: u64,
    nested_reuses: u64,
    host_reserved_admissions: u64,
    general_slot_admissions: u64,
    waits: u64,
    wait_ns: u64,
    active_before: u64,
    active_after: u64,
    waiters_before: u64,
    waiters_after: u64,
    peak_active_after: u64,
    peak_waiters_after: u64,
    wait_ns_max_after: u64,
    general_active_before: u64,
    general_active_after: u64,
    host_reserved_active_before: u64,
    host_reserved_active_after: u64,
    peak_general_active_after: u64,
    peak_host_reserved_active_after: u64,

    fn between(before: RuntimePoint, after: RuntimePoint) RuntimePhase {
        std.debug.assert(before.schema_version == after.schema_version);
        return .{
            .requests = after.requests -| before.requests,
            .starts = after.starts -| before.starts,
            .completions = after.completions -| before.completions,
            .typed_slot_reuses = after.typed_slot_reuses -| before.typed_slot_reuses,
            .nested_reuses = after.nested_reuses -| before.nested_reuses,
            .host_reserved_admissions = after.host_reserved_admissions -| before.host_reserved_admissions,
            .general_slot_admissions = after.general_slot_admissions -| before.general_slot_admissions,
            .waits = after.waits -| before.waits,
            .wait_ns = after.wait_ns -| before.wait_ns,
            .active_before = before.active,
            .active_after = after.active,
            .waiters_before = before.waiters,
            .waiters_after = after.waiters,
            .peak_active_after = after.peak_active,
            .peak_waiters_after = after.peak_waiters,
            .wait_ns_max_after = after.wait_ns_max,
            .general_active_before = before.general_active,
            .general_active_after = after.general_active,
            .host_reserved_active_before = before.host_reserved_active,
            .host_reserved_active_after = after.host_reserved_active,
            .peak_general_active_after = after.peak_general_active,
            .peak_host_reserved_active_after = after.peak_host_reserved_active,
        };
    }
};

const Lane = struct {
    io: std.Io,
    mode: Mode,
    jobs: usize,
    lane_index: usize,
    cold_done: *std.Io.Semaphore,
    warm_done: *std.Io.Semaphore,
    start_warm: std.Io.Semaphore = .{},
    release: std.Io.Semaphore = .{},
    failed: std.atomic.Value(bool) = .init(false),
    cold: CompilerSnapshot = .{},
    warm: CompilerSnapshot = .{},
    checksum: f64 = 0,
};

fn timevalNs(value: std.c.timeval) u64 {
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.usec)) * std.time.ns_per_us;
}

fn processResourceSnapshot() !ProcessResourceSnapshot {
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    if (builtin.os.tag == .macos) {
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
        const required_count = std.math.divCeil(
            usize,
            @offsetOf(std.c.task_vm_info_data_t, "resident_size_peak") + @sizeOf(std.c.mach_vm_size_t),
            @sizeOf(std.c.natural_t),
        ) catch unreachable;
        if (task_result != 0 or info_count < required_count) return error.ProcessResourceUnavailable;
        return .{
            .cpu_user_ns = timevalNs(usage.utime),
            .cpu_system_ns = timevalNs(usage.stime),
            .peak_rss_bytes = @intCast(vm_info.resident_size_peak),
            .retained_rss_bytes = @intCast(vm_info.resident_size),
        };
    }
    return .{
        .cpu_user_ns = timevalNs(usage.utime),
        .cpu_system_ns = timevalNs(usage.stime),
        .peak_rss_bytes = if (builtin.os.tag == .linux) @as(u64, @intCast(usage.maxrss)) * 1024 else @intCast(usage.maxrss),
        .retained_rss_bytes = 0,
    };
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn sourceDigest() [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(workload_source, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn expectedChecksum(jobs: usize, lane_index: usize) f64 {
    var total: u64 = 0;
    for (0..jobs) |job| {
        const seed = lane_index + job + 1;
        for (0..64) |function_index| {
            var value: u64 = seed + function_index + function_index + 1;
            for (0..64) |index|
                value = (value * 33 + index + function_index) % 1_000_003;
            total += value;
        }
    }
    return @floatFromInt(total);
}

fn invoke(ctx: *js.Context) !f64 {
    return (try ctx.evaluate("__compilerPressureInvoke()")).toNumber();
}

fn laneMain(lane: *Lane) void {
    const ctx = js.Context.createWith(benchmark_allocator, .{
        .enable_jit = lane.mode == .jit_on,
        .enable_gc = true,
        .profile_execution_tiers = true,
    }) catch {
        lane.failed.store(true, .release);
        lane.cold_done.post(lane.io);
        return;
    };
    defer ctx.destroy();
    if (lane.mode == .jit_off) ctx.setBytecodeExecutionModeForTesting(.required);

    _ = ctx.evaluate(workload_source) catch {
        lane.failed.store(true, .release);
        lane.cold_done.post(lane.io);
        return;
    };
    const configuration = std.fmt.allocPrint(
        ctx.arena(),
        "globalThis.__compilerPressureInvoke = function() {{ return compilerPressureRun({d}, {d}); }};",
        .{ lane.jobs, lane.lane_index },
    ) catch {
        lane.failed.store(true, .release);
        lane.cold_done.post(lane.io);
        return;
    };
    _ = ctx.evaluate(configuration) catch {
        lane.failed.store(true, .release);
        lane.cold_done.post(lane.io);
        return;
    };
    for (0..cold_invocations) |_| {
        lane.checksum = invoke(ctx) catch {
            lane.failed.store(true, .release);
            lane.cold_done.post(lane.io);
            return;
        };
    }
    lane.cold = CompilerSnapshot.capture(ctx);
    lane.cold_done.post(lane.io);

    lane.start_warm.waitUncancelable(lane.io);
    for (0..warm_invocations) |_| {
        lane.checksum = invoke(ctx) catch {
            lane.failed.store(true, .release);
            lane.warm_done.post(lane.io);
            return;
        };
    }
    lane.warm = CompilerSnapshot.capture(ctx);
    lane.warm_done.post(lane.io);
    lane.release.waitUncancelable(lane.io);
}

fn printMetadata(writer: *std.Io.Writer, logical_cpus: usize) !void {
    const runtime = RuntimePoint.capture();
    try writer.print(
        "{{\"kind\":\"zig-js-compiler-pressure-metadata\",\"schema\":{d},\"source_path\":\"{s}\",\"source_sha256\":\"{s}\",\"logical_cpus\":{d},\"jit_supported\":{s},\"cold_invocations\":{d},\"warm_invocations\":{d},\"runtime_thread_schema\":{d}}}\n",
        .{ schema_version, workload_source_path, workload_source_sha256, logical_cpus, if (js.jit.supported) "true" else "false", cold_invocations, warm_invocations, runtime.schema_version },
    );
}

fn printRow(
    writer: *std.Io.Writer,
    mode: Mode,
    phase: Phase,
    lanes: usize,
    jobs: usize,
    sample: usize,
    elapsed_ns: u64,
    checksum: f64,
    compiler: CompilerSnapshot,
    runtime: RuntimePhase,
    before: ProcessResourceSnapshot,
    after: ProcessResourceSnapshot,
) !void {
    try writer.print(
        "{{\"kind\":\"zig-js-compiler-pressure\",\"schema\":{d},\"mode\":\"{s}\",\"phase\":\"{s}\",\"source_sha256\":\"{s}\",\"lanes\":{d},\"jobs_per_lane\":{d},\"sample\":{d},\"elapsed_ns\":{d},\"checksum\":{d:.0},\"process\":{{\"cpu_user_ns\":{d},\"cpu_system_ns\":{d},\"peak_rss_bytes_before\":{d},\"peak_rss_bytes_after\":{d},\"retained_rss_bytes_before\":{d},\"retained_rss_bytes_after\":{d}}},\"compiler\":{{",
        .{
            schema_version,
            @tagName(mode),
            @tagName(phase),
            workload_source_sha256,
            lanes,
            jobs,
            sample,
            elapsed_ns,
            checksum,
            after.cpu_user_ns -| before.cpu_user_ns,
            after.cpu_system_ns -| before.cpu_system_ns,
            before.peak_rss_bytes,
            after.peak_rss_bytes,
            before.retained_rss_bytes,
            after.retained_rss_bytes,
        },
    );
    inline for (comptime std.meta.fieldNames(CompilerSnapshot), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(compiler, name) });
    }
    try writer.writeAll("},\"runtime\":{");
    inline for (comptime std.meta.fieldNames(RuntimePhase), 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, @field(runtime, name) });
    }
    try writer.writeAll("}}\n");
}

fn runSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    mode: Mode,
    lane_count: usize,
    jobs: usize,
    sample: usize,
) !void {
    const lanes = try allocator.alloc(Lane, lane_count);
    defer allocator.free(lanes);
    const threads = try allocator.alloc(std.Thread, lane_count);
    defer allocator.free(threads);
    var cold_done: std.Io.Semaphore = .{};
    var warm_done: std.Io.Semaphore = .{};
    var spawned: usize = 0;
    defer {
        for (lanes[0..spawned]) |*lane| {
            lane.start_warm.post(io);
            lane.release.post(io);
        }
        for (threads[0..spawned]) |thread| thread.join();
    }

    const cold_runtime_before = RuntimePoint.capture();
    const cold_process_before = try processResourceSnapshot();
    const cold_started = nowNs(io);
    for (lanes, 0..) |*lane, lane_index| {
        lane.* = .{
            .io = io,
            .mode = mode,
            .jobs = jobs,
            .lane_index = lane_index,
            .cold_done = &cold_done,
            .warm_done = &warm_done,
        };
        threads[lane_index] = try std.Thread.spawn(.{}, laneMain, .{lane});
        spawned += 1;
    }
    for (0..lane_count) |_| cold_done.waitUncancelable(io);
    const cold_elapsed: u64 = @intCast(nowNs(io) - cold_started);
    const cold_process_after = try processResourceSnapshot();
    const cold_runtime_after = RuntimePoint.capture();
    for (lanes) |*lane| if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;

    var cold: CompilerSnapshot = .{};
    var checksum: f64 = 0;
    var expected_checksum: f64 = 0;
    for (lanes) |*lane| {
        cold.add(lane.cold);
        checksum += lane.checksum;
        expected_checksum += expectedChecksum(jobs, lane.lane_index);
    }
    if (checksum != expected_checksum) return error.ChecksumMismatch;
    if (mode == .jit_off and (cold.publications() != 0 or cold.generated_code_bytes != 0))
        return error.JitOffPublishedNativeCode;
    if (mode == .jit_on and js.jit.supported and cold.publications() == 0)
        return error.JitOnDidNotPublishNativeCode;
    try printRow(writer, mode, .cold, lane_count, jobs, sample, cold_elapsed, checksum, cold, RuntimePhase.between(cold_runtime_before, cold_runtime_after), cold_process_before, cold_process_after);

    const warm_runtime_before = RuntimePoint.capture();
    const warm_process_before = try processResourceSnapshot();
    const warm_started = nowNs(io);
    for (lanes) |*lane| lane.start_warm.post(io);
    for (0..lane_count) |_| warm_done.waitUncancelable(io);
    const warm_elapsed: u64 = @intCast(nowNs(io) - warm_started);
    const warm_process_after = try processResourceSnapshot();
    const warm_runtime_after = RuntimePoint.capture();
    for (lanes) |*lane| if (lane.failed.load(.acquire)) return error.BenchmarkWorkerFailure;

    var cumulative_warm: CompilerSnapshot = .{};
    checksum = 0;
    for (lanes) |*lane| {
        cumulative_warm.add(lane.warm);
        checksum += lane.checksum;
    }
    if (checksum != expected_checksum) return error.ChecksumMismatch;
    const warm = CompilerSnapshot.subtract(cumulative_warm, cold);
    try printRow(writer, mode, .warm, lane_count, jobs, sample, warm_elapsed, checksum, warm, RuntimePhase.between(warm_runtime_before, warm_runtime_after), warm_process_before, warm_process_after);

    for (lanes) |*lane| lane.release.post(io);
}

fn parseMode(text: []const u8) !Mode {
    inline for (std.meta.tags(Mode)) |mode|
        if (std.mem.eql(u8, text, @tagName(mode))) return mode;
    return error.InvalidMode;
}

pub fn main(init: std.process.Init) !void {
    const digest = sourceDigest();
    if (!std.mem.eql(u8, &digest, workload_source_sha256)) return error.SourceChecksumMismatch;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const self_test = args.len == 2 and std.mem.eql(u8, args[1], "--self-test");
    if (!self_test and args.len != 5) return error.InvalidArguments;

    const logical_cpus = std.Thread.getCpuCount() catch 1;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try printMetadata(stdout, logical_cpus);
    if (self_test) {
        try runSample(init.gpa, init.io, stdout, .jit_off, 1, 1, 0);
        try runSample(init.gpa, init.io, stdout, .jit_on, 1, 1, 0);
        try stdout.flush();
        return;
    }

    const mode = try parseMode(args[1]);
    const lane_count = try std.fmt.parseUnsigned(usize, args[2], 10);
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    if (lane_count == 0 or lane_count > 1024 or jobs == 0 or samples == 0) return error.InvalidArguments;
    for (0..samples) |sample|
        try runSample(init.gpa, init.io, stdout, mode, lane_count, jobs, sample);
    try stdout.flush();
}
