const std = @import("std");

pub const PromiseStats = struct {
    microtask_enqueues: u64 = 0,
    microtask_pops: u64 = 0,
    microtask_lock_acquires: u64 = 0,
    microtask_lock_yields: u64 = 0,
    promise_lock_acquires: u64 = 0,
    promise_lock_yields: u64 = 0,
    reaction_jobs_enqueued: u64 = 0,
    thenable_jobs_enqueued: u64 = 0,
    reaction_jobs_run: u64 = 0,
    thenable_jobs_run: u64 = 0,

    pub fn jobsEnqueued(self: PromiseStats) u64 {
        return self.reaction_jobs_enqueued + self.thenable_jobs_enqueued;
    }

    pub fn jobsRun(self: PromiseStats) u64 {
        return self.reaction_jobs_run + self.thenable_jobs_run;
    }
};

const PromiseCounters = struct {
    microtask_enqueues: std.atomic.Value(u64) = .init(0),
    microtask_pops: std.atomic.Value(u64) = .init(0),
    microtask_lock_acquires: std.atomic.Value(u64) = .init(0),
    microtask_lock_yields: std.atomic.Value(u64) = .init(0),
    promise_lock_acquires: std.atomic.Value(u64) = .init(0),
    promise_lock_yields: std.atomic.Value(u64) = .init(0),
    reaction_jobs_enqueued: std.atomic.Value(u64) = .init(0),
    thenable_jobs_enqueued: std.atomic.Value(u64) = .init(0),
    reaction_jobs_run: std.atomic.Value(u64) = .init(0),
    thenable_jobs_run: std.atomic.Value(u64) = .init(0),
};

var counters: PromiseCounters = .{};
var enabled: std.atomic.Value(bool) = .init(false);

pub fn resetPromiseStats() void {
    enabled.store(false, .release);
    counters.microtask_enqueues.store(0, .release);
    counters.microtask_pops.store(0, .release);
    counters.microtask_lock_acquires.store(0, .release);
    counters.microtask_lock_yields.store(0, .release);
    counters.promise_lock_acquires.store(0, .release);
    counters.promise_lock_yields.store(0, .release);
    counters.reaction_jobs_enqueued.store(0, .release);
    counters.thenable_jobs_enqueued.store(0, .release);
    counters.reaction_jobs_run.store(0, .release);
    counters.thenable_jobs_run.store(0, .release);
    enabled.store(true, .release);
}

pub fn disablePromiseStats() void {
    enabled.store(false, .release);
}

pub fn promiseStats() PromiseStats {
    return .{
        .microtask_enqueues = counters.microtask_enqueues.load(.acquire),
        .microtask_pops = counters.microtask_pops.load(.acquire),
        .microtask_lock_acquires = counters.microtask_lock_acquires.load(.acquire),
        .microtask_lock_yields = counters.microtask_lock_yields.load(.acquire),
        .promise_lock_acquires = counters.promise_lock_acquires.load(.acquire),
        .promise_lock_yields = counters.promise_lock_yields.load(.acquire),
        .reaction_jobs_enqueued = counters.reaction_jobs_enqueued.load(.acquire),
        .thenable_jobs_enqueued = counters.thenable_jobs_enqueued.load(.acquire),
        .reaction_jobs_run = counters.reaction_jobs_run.load(.acquire),
        .thenable_jobs_run = counters.thenable_jobs_run.load(.acquire),
    };
}

inline fn bump(comptime field: []const u8) void {
    if (!enabled.load(.monotonic)) return;
    _ = @field(counters, field).fetchAdd(1, .monotonic);
}

pub inline fn recordMicrotaskEnqueue(thenable: bool) void {
    bump("microtask_enqueues");
    if (thenable) bump("thenable_jobs_enqueued") else bump("reaction_jobs_enqueued");
}

pub inline fn recordMicrotaskPop() void {
    bump("microtask_pops");
}

pub inline fn recordMicrotaskPops(count: usize) void {
    if (count == 0 or !enabled.load(.monotonic)) return;
    _ = counters.microtask_pops.fetchAdd(@intCast(count), .monotonic);
}

pub inline fn recordMicrotaskLockAcquire() void {
    bump("microtask_lock_acquires");
}

pub inline fn recordMicrotaskLockYield() void {
    bump("microtask_lock_yields");
}

pub inline fn recordPromiseLockAcquire() void {
    bump("promise_lock_acquires");
}

pub inline fn recordPromiseLockYield() void {
    bump("promise_lock_yields");
}

pub inline fn recordMicrotaskRun(thenable: bool) void {
    if (thenable) bump("thenable_jobs_run") else bump("reaction_jobs_run");
}

test "promise profile stats reset and snapshot" {
    resetPromiseStats();
    defer disablePromiseStats();
    recordMicrotaskEnqueue(false);
    recordMicrotaskEnqueue(true);
    recordMicrotaskPop();
    recordMicrotaskLockAcquire();
    recordMicrotaskLockYield();
    recordPromiseLockAcquire();
    recordPromiseLockYield();
    recordMicrotaskRun(false);
    recordMicrotaskRun(true);

    const stats = promiseStats();
    try std.testing.expectEqual(@as(u64, 2), stats.microtask_enqueues);
    try std.testing.expectEqual(@as(u64, 1), stats.microtask_pops);
    try std.testing.expectEqual(@as(u64, 1), stats.microtask_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.microtask_lock_yields);
    try std.testing.expectEqual(@as(u64, 1), stats.promise_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.promise_lock_yields);
    try std.testing.expectEqual(@as(u64, 1), stats.reaction_jobs_enqueued);
    try std.testing.expectEqual(@as(u64, 1), stats.thenable_jobs_enqueued);
    try std.testing.expectEqual(@as(u64, 2), stats.jobsEnqueued());
    try std.testing.expectEqual(@as(u64, 1), stats.reaction_jobs_run);
    try std.testing.expectEqual(@as(u64, 1), stats.thenable_jobs_run);
    try std.testing.expectEqual(@as(u64, 2), stats.jobsRun());
}
