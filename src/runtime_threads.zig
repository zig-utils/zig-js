//! Typed creation boundary for every OS thread the production engine owns.
//!
//! The kind is intentionally behavior-neutral today. It makes ownership
//! auditable now and is the stable admission point for #502's resource
//! coordinator without changing stack, scheduling, or lifecycle semantics.

const std = @import("std");

pub const Kind = enum {
    test262_agent,
    concurrent_gc_marker,
    javascript_thread,
    script_worker,
    module_worker,
    execution_watchdog,
};

pub const kind_count = std.meta.fieldNames(Kind).len;

const Counters = struct {
    attempts: std.atomic.Value(u64) = .init(0),
    starts: std.atomic.Value(u64) = .init(0),
    completions: std.atomic.Value(u64) = .init(0),
    spawn_failures: std.atomic.Value(u64) = .init(0),
    in_flight_attempts: std.atomic.Value(u64) = .init(0),
    live: std.atomic.Value(u64) = .init(0),
    peak_live: std.atomic.Value(u64) = .init(0),
    configured_stack_bytes: std.atomic.Value(u64) = .init(0),
    peak_configured_stack_bytes: std.atomic.Value(u64) = .init(0),
};

var counters: [kind_count]Counters = @splat(.{});
var mutation_writers: std.atomic.Value(u64) = .init(0);
var mutation_generation: std.atomic.Value(u64) = .init(0);

pub const ResourceSnapshot = struct {
    attempts: u64,
    starts: u64,
    completions: u64,
    spawn_failures: u64,
    in_flight_attempts: u64,
    live: u64,
    peak_live: u64,
    configured_stack_bytes: u64,
    peak_configured_stack_bytes: u64,
};

pub const Snapshot = struct {
    schema_version: u32 = 1,
    generation: u64,
    resources: [kind_count]ResourceSnapshot,

    pub fn resource(self: *const Snapshot, kind: Kind) ResourceSnapshot {
        return self.resources[@backingInt(kind)];
    }
};

fn beginMutation() void {
    _ = mutation_writers.fetchAdd(1, .acquire);
}

fn finishMutation() void {
    _ = mutation_generation.fetchAdd(1, .release);
    const previous = mutation_writers.fetchSub(1, .release);
    std.debug.assert(previous > 0);
}

fn recordPeak(value: *std.atomic.Value(u64), candidate: u64) void {
    var peak = value.load(.monotonic);
    while (candidate > peak) {
        if (value.cmpxchgWeak(peak, candidate, .monotonic, .monotonic)) |observed| {
            peak = observed;
        } else break;
    }
}

fn recordAttempt(kind: Kind) void {
    beginMutation();
    defer finishMutation();
    const state = &counters[@backingInt(kind)];
    _ = state.attempts.fetchAdd(1, .monotonic);
    _ = state.in_flight_attempts.fetchAdd(1, .monotonic);
}

fn recordStart(kind: Kind, stack_bytes: usize) void {
    beginMutation();
    defer finishMutation();
    const state = &counters[@backingInt(kind)];
    const pending = state.in_flight_attempts.fetchSub(1, .monotonic);
    std.debug.assert(pending > 0);
    _ = state.starts.fetchAdd(1, .monotonic);
    const live = state.live.fetchAdd(1, .monotonic) + 1;
    recordPeak(&state.peak_live, live);
    const stack = state.configured_stack_bytes.fetchAdd(stack_bytes, .monotonic) + stack_bytes;
    recordPeak(&state.peak_configured_stack_bytes, stack);
}

fn recordFailure(kind: Kind) void {
    beginMutation();
    defer finishMutation();
    const state = &counters[@backingInt(kind)];
    const pending = state.in_flight_attempts.fetchSub(1, .monotonic);
    std.debug.assert(pending > 0);
    _ = state.spawn_failures.fetchAdd(1, .monotonic);
}

fn recordCompletion(kind: Kind, stack_bytes: usize) void {
    beginMutation();
    defer finishMutation();
    const state = &counters[@backingInt(kind)];
    _ = state.completions.fetchAdd(1, .monotonic);
    const live = state.live.fetchSub(1, .monotonic);
    const stack = state.configured_stack_bytes.fetchSub(stack_bytes, .monotonic);
    std.debug.assert(live > 0 and stack >= stack_bytes);
}

fn loadResource(state: *const Counters) ResourceSnapshot {
    return .{
        .attempts = state.attempts.load(.acquire),
        .starts = state.starts.load(.acquire),
        .completions = state.completions.load(.acquire),
        .spawn_failures = state.spawn_failures.load(.acquire),
        .in_flight_attempts = state.in_flight_attempts.load(.acquire),
        .live = state.live.load(.acquire),
        .peak_live = state.peak_live.load(.acquire),
        .configured_stack_bytes = state.configured_stack_bytes.load(.acquire),
        .peak_configured_stack_bytes = state.peak_configured_stack_bytes.load(.acquire),
    };
}

/// Coherent process-wide resource state. Readers retry only across the short
/// atomic mutation sections at thread creation and exit; JavaScript execution,
/// blocking waits, and joins never hold a telemetry lock.
pub fn snapshot() Snapshot {
    while (true) {
        const generation = mutation_generation.load(.acquire);
        if (mutation_writers.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        var result = Snapshot{ .generation = generation, .resources = undefined };
        for (&counters, 0..) |*state, index| result.resources[index] = loadResource(state);
        const after_generation = mutation_generation.load(.acquire);
        const after_writers = mutation_writers.load(.acquire);
        const final_generation = mutation_generation.load(.acquire);
        if (after_writers == 0 and generation == after_generation and after_generation == final_generation)
            return result;
        std.atomic.spinLoopHint();
    }
}

pub fn spawn(
    comptime kind: Kind,
    config: std.Thread.SpawnConfig,
    comptime function: anytype,
    args: anytype,
) !std.Thread {
    recordAttempt(kind);
    const Runner = struct {
        fn run(call_args: @TypeOf(args), stack_bytes: usize) void {
            recordStart(kind, stack_bytes);
            defer recordCompletion(kind, stack_bytes);
            @call(.auto, function, call_args);
        }
    };
    return std.Thread.spawn(config, Runner.run, .{ args, config.stack_size }) catch |err| {
        recordFailure(kind);
        return err;
    };
}

test "runtime thread telemetry is coherent across concurrent starts and exits" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const before = snapshot().resource(.script_worker);
    var release = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(gate: *std.atomic.Value(bool)) void {
            while (!gate.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try spawn(.script_worker, .{}, Worker.run, .{&release});
    while (true) {
        const live = snapshot().resource(.script_worker);
        try std.testing.expectEqual(live.attempts, live.starts + live.spawn_failures + live.in_flight_attempts);
        try std.testing.expectEqual(live.live, live.starts - live.completions);
        if (live.live - before.live == threads.len) {
            try std.testing.expectEqual(@as(u64, threads.len), live.starts - before.starts);
            try std.testing.expectEqual(@as(u64, threads.len * std.Thread.SpawnConfig.default_stack_size), live.configured_stack_bytes - before.configured_stack_bytes);
            try std.testing.expect(live.peak_live >= before.live + threads.len);
            break;
        }
        std.atomic.spinLoopHint();
    }
    release.store(true, .release);
    for (&threads) |*thread| thread.join();
    const after = snapshot().resource(.script_worker);
    try std.testing.expectEqual(@as(u64, threads.len), after.attempts - before.attempts);
    try std.testing.expectEqual(@as(u64, threads.len), after.starts - before.starts);
    try std.testing.expectEqual(@as(u64, threads.len), after.completions - before.completions);
    try std.testing.expectEqual(@as(u64, 0), after.spawn_failures - before.spawn_failures);
    try std.testing.expectEqual(before.live, after.live);
    try std.testing.expectEqual(before.configured_stack_bytes, after.configured_stack_bytes);
}

test "runtime thread telemetry distinguishes failed and in-flight attempts" {
    const before = snapshot().resource(.module_worker);
    recordAttempt(.module_worker);
    const pending = snapshot().resource(.module_worker);
    try std.testing.expectEqual(before.attempts + 1, pending.attempts);
    try std.testing.expectEqual(before.in_flight_attempts + 1, pending.in_flight_attempts);
    try std.testing.expectEqual(pending.attempts, pending.starts + pending.spawn_failures + pending.in_flight_attempts);
    recordFailure(.module_worker);
    const after = snapshot().resource(.module_worker);
    try std.testing.expectEqual(before.in_flight_attempts, after.in_flight_attempts);
    try std.testing.expectEqual(before.spawn_failures + 1, after.spawn_failures);
    try std.testing.expectEqual(after.attempts, after.starts + after.spawn_failures + after.in_flight_attempts);
}
