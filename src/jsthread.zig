//! The JS-visible `Thread` API (Phase 6 step 2 of
//! https://github.com/zig-utils/zig-js/issues/1; semantics copied from
//! oven-sh/WebKit#249, design in docs/threads/P6-thread-api.md).
//!
//! `new Thread(fn, ...args)` runs `fn` on another OS thread **in the same
//! realm** — same globalThis, same heap, same closures. `enable_threads` is
//! no-GIL/parallel by default; `.gil = true` opts into the legacy serialized
//! fallback. `t.join()` parks without holding that legacy GIL when the fallback
//! is enabled and returns fn's value or rethrows its actual exception object;
//! each thread drains its own microtask queue before publishing its result.
//! `Thread.current` is the calling thread's Thread object (main has id 0).
//! Installed only on `enable_threads` Contexts.

const std = @import("std");
const io_compat = @import("io_compat.zig");
const gc_mod = @import("gc.zig");
const gc_relocation = @import("gc_relocation.zig");
const stack_scan = @import("stack_scan.zig");
const value = @import("value.zig");
const strcell = @import("strcell.zig");
const gc_runtime = @import("gc_runtime.zig");
const interp = @import("interpreter.zig");
const ContextMod = @import("context.zig");
const gil_mod = @import("gil.zig");
const agent = @import("agent.zig");
const object_profile = @import("object_profile.zig");

const promise = @import("promise.zig");

const Context = ContextMod.Context;
const Value = value.Value;
const Interpreter = interp.Interpreter;

pub const PendingJoin = struct {
    promise: *value.Object,
    microtasks: *promise.MicrotaskQueue,
    /// The thread that registered this `asyncJoin` (the joiner), or null for the
    /// main/host thread. When the joiner is a spawned thread that has finished
    /// (`done`), its local `microtasks` queue is being abandoned, so the finishing
    /// thread routes this settlement's reactions to the realm queue
    /// (`ctx.microtasks`, which the host keeps draining) instead — otherwise a
    /// nested `asyncJoin` reaction strands in a dead thread's queue. A still-live
    /// joiner keeps its reactions (thread affinity preserved).
    owner: ?*ThreadRecord = null,
};

pub const ThreadRecord = struct {
    id: u32,
    gil: *gil_mod.Gil,
    ctx: *Context,
    thread: ?std.Thread = null,
    /// Guards completion state independently from the context GIL. Shipping
    /// GIL-mode joiners still release the GIL while parked, but `parallel_js`
    /// joiners wait only on this mutex/condition pair.
    join_mutex: std.Io.Mutex = .init,
    done: bool = false,
    /// True only after the OS thread has run all cleanup defers and is about
    /// to return. GC quiescence uses this, not `done`: `done` only means the JS
    /// result is published for joiners.
    exited: bool = false,
    threw: bool = false,
    result: Value = Value.undef(),
    done_cond: std.Io.Condition = .init,
    /// The realm's wrapper object (`Thread.current` returns it).
    js_obj: ?*value.Object = null,
    /// Promises handed out by `asyncJoin` before completion; settled by the
    /// finishing thread (reactions run on the settling thread's queue — the
    /// PR's ordinary-promise rule; awaiters elsewhere observe the shared
    /// state via awaitValue's GIL-yield loop).
    pending_joins: std.ArrayListUnmanaged(PendingJoin) = .empty,
    /// Snapshot being settled by the finishing thread after `done` is
    /// published. This duplicates the local settlement list solely as a GC root:
    /// `publishThreadCompletion` must remove entries from `pending_joins` under
    /// `join_mutex`, but a parallel collector can start before the finisher has
    /// copied those promises into its interpreter temp roots.
    settling_joins: std.ArrayListUnmanaged(PendingJoin) = .empty,
    /// `done` publishes the synchronous result before the finishing thread
    /// settles the pre-existing asyncJoin snapshot. A synchronous join must
    /// wait for both transitions or it can drain the joiner queue in between
    /// them and miss the settlement reactions.
    joins_settled: bool = true,
    /// The live microtask queue for this JS thread. Worker queues are stack
    /// locals in `threadMain`; outstanding async tickets are transferred away
    /// before that stack frame exits.
    microtasks: ?*promise.MicrotaskQueue = null,
    /// ThreadLocal records this thread has stored into. The records are
    /// arena-lived host data; this list lets thread exit remove the OS-thread
    /// keyed entries so ThreadLocal-only JS roots do not survive termination.
    touched_thread_locals: std.ArrayListUnmanaged(*TLRecord) = .empty,
};

const pending_join_reserve_granularity = 16;

threadlocal var t_current: ?*ThreadRecord = null;

/// Internal profiling counters for issue #1's long-tail contention work.
/// These are deliberately not part of the embedder API; local tools such as
/// `zig build threads-profile` snapshot them to attribute wall-clock scaling
/// regressions to synchronization paths.
pub const ContentionStats = struct {
    thread_join_parks: u64 = 0,
    lock_contentions: u64 = 0,
    lock_wait_parks: u64 = 0,
    async_hold_queued: u64 = 0,
    condition_async_waits: u64 = 0,
    condition_async_settled: u64 = 0,
    condition_waits: u64 = 0,
    condition_wait_parks: u64 = 0,
    property_waits: u64 = 0,
    property_wait_parks: u64 = 0,
    property_wait_async_enqueued: u64 = 0,
    property_wait_async_settled: u64 = 0,
    task_pump_empty: u64 = 0,
    task_pump_jobs: u64 = 0,
    task_pump_async_hold_jobs: u64 = 0,
    task_pump_condition_jobs: u64 = 0,
    condition_queue_grows: u64 = 0,
    condition_queue_compactions: u64 = 0,
    worker_channel_pushes: u64 = 0,
    worker_channel_pops: u64 = 0,
    worker_channel_empty_pops: u64 = 0,
    worker_channel_closes: u64 = 0,
    arena_lock_acquires: u64 = 0,
    arena_lock_contentions: u64 = 0,
    arena_lock_spins: u64 = 0,
    env_lock_acquires: u64 = 0,
    env_lock_contentions: u64 = 0,
    env_lock_spins: u64 = 0,
    object_backing_lock_acquires: u64 = 0,
    object_backing_lock_contentions: u64 = 0,
    object_backing_lock_spins: u64 = 0,
    object_property_lock_acquires: u64 = 0,
    object_property_lock_contentions: u64 = 0,
    object_property_lock_spins: u64 = 0,
    object_element_lock_acquires: u64 = 0,
    object_element_lock_contentions: u64 = 0,
    object_element_lock_spins: u64 = 0,
    thread_join_wait_ns: u64 = 0,
    lock_wait_ns: u64 = 0,
    condition_wait_ns: u64 = 0,
    property_wait_ns: u64 = 0,

    pub fn events(self: ContentionStats) u64 {
        return self.lock_contentions + self.async_hold_queued +
            self.condition_waits + self.condition_async_waits +
            self.property_waits + self.property_wait_async_enqueued;
    }

    pub fn parks(self: ContentionStats) u64 {
        return self.thread_join_parks + self.lock_wait_parks +
            self.condition_wait_parks + self.property_wait_parks;
    }

    pub fn asyncWaits(self: ContentionStats) u64 {
        return self.condition_async_waits + self.property_wait_async_enqueued;
    }

    pub fn asyncSettled(self: ContentionStats) u64 {
        return self.condition_async_settled + self.property_wait_async_settled;
    }

    pub fn waitNs(self: ContentionStats) u64 {
        return self.thread_join_wait_ns + self.lock_wait_ns +
            self.condition_wait_ns + self.property_wait_ns;
    }
};

const ContentionCounters = struct {
    thread_join_parks: std.atomic.Value(u64) = .init(0),
    lock_contentions: std.atomic.Value(u64) = .init(0),
    lock_wait_parks: std.atomic.Value(u64) = .init(0),
    async_hold_queued: std.atomic.Value(u64) = .init(0),
    condition_async_waits: std.atomic.Value(u64) = .init(0),
    condition_async_settled: std.atomic.Value(u64) = .init(0),
    condition_waits: std.atomic.Value(u64) = .init(0),
    condition_wait_parks: std.atomic.Value(u64) = .init(0),
    property_waits: std.atomic.Value(u64) = .init(0),
    property_wait_parks: std.atomic.Value(u64) = .init(0),
    property_wait_async_enqueued: std.atomic.Value(u64) = .init(0),
    property_wait_async_settled: std.atomic.Value(u64) = .init(0),
    task_pump_empty: std.atomic.Value(u64) = .init(0),
    task_pump_jobs: std.atomic.Value(u64) = .init(0),
    task_pump_async_hold_jobs: std.atomic.Value(u64) = .init(0),
    task_pump_condition_jobs: std.atomic.Value(u64) = .init(0),
    condition_queue_grows: std.atomic.Value(u64) = .init(0),
    condition_queue_compactions: std.atomic.Value(u64) = .init(0),
    worker_channel_pushes: std.atomic.Value(u64) = .init(0),
    worker_channel_pops: std.atomic.Value(u64) = .init(0),
    worker_channel_empty_pops: std.atomic.Value(u64) = .init(0),
    worker_channel_closes: std.atomic.Value(u64) = .init(0),
    arena_lock_acquires: std.atomic.Value(u64) = .init(0),
    arena_lock_contentions: std.atomic.Value(u64) = .init(0),
    arena_lock_spins: std.atomic.Value(u64) = .init(0),
    env_lock_acquires: std.atomic.Value(u64) = .init(0),
    env_lock_contentions: std.atomic.Value(u64) = .init(0),
    env_lock_spins: std.atomic.Value(u64) = .init(0),
    thread_join_wait_ns: std.atomic.Value(u64) = .init(0),
    lock_wait_ns: std.atomic.Value(u64) = .init(0),
    condition_wait_ns: std.atomic.Value(u64) = .init(0),
    property_wait_ns: std.atomic.Value(u64) = .init(0),
};

var contention_counters: ContentionCounters = .{};
var contention_stats_enabled: std.atomic.Value(bool) = .init(false);

fn outOfMemoryCompletionValue(ctx: *Context) Value {
    return ctx.reserved_thread_oom_error orelse Value.staticStr("OutOfMemoryError");
}

pub fn resetContentionStats() void {
    contention_stats_enabled.store(false, .release);
    contention_counters.thread_join_parks.store(0, .release);
    contention_counters.lock_contentions.store(0, .release);
    contention_counters.lock_wait_parks.store(0, .release);
    contention_counters.async_hold_queued.store(0, .release);
    contention_counters.condition_async_waits.store(0, .release);
    contention_counters.condition_async_settled.store(0, .release);
    contention_counters.condition_waits.store(0, .release);
    contention_counters.condition_wait_parks.store(0, .release);
    contention_counters.property_waits.store(0, .release);
    contention_counters.property_wait_parks.store(0, .release);
    contention_counters.property_wait_async_enqueued.store(0, .release);
    contention_counters.property_wait_async_settled.store(0, .release);
    contention_counters.task_pump_empty.store(0, .release);
    contention_counters.task_pump_jobs.store(0, .release);
    contention_counters.task_pump_async_hold_jobs.store(0, .release);
    contention_counters.task_pump_condition_jobs.store(0, .release);
    contention_counters.condition_queue_grows.store(0, .release);
    contention_counters.condition_queue_compactions.store(0, .release);
    contention_counters.worker_channel_pushes.store(0, .release);
    contention_counters.worker_channel_pops.store(0, .release);
    contention_counters.worker_channel_empty_pops.store(0, .release);
    contention_counters.worker_channel_closes.store(0, .release);
    contention_counters.arena_lock_acquires.store(0, .release);
    contention_counters.arena_lock_contentions.store(0, .release);
    contention_counters.arena_lock_spins.store(0, .release);
    contention_counters.env_lock_acquires.store(0, .release);
    contention_counters.env_lock_contentions.store(0, .release);
    contention_counters.env_lock_spins.store(0, .release);
    object_profile.reset();
    contention_counters.thread_join_wait_ns.store(0, .release);
    contention_counters.lock_wait_ns.store(0, .release);
    contention_counters.condition_wait_ns.store(0, .release);
    contention_counters.property_wait_ns.store(0, .release);
    contention_stats_enabled.store(true, .release);
}

pub fn disableContentionStats() void {
    contention_stats_enabled.store(false, .release);
    object_profile.disable();
}

pub fn contentionStats() ContentionStats {
    const object = object_profile.snapshot();
    return .{
        .thread_join_parks = contention_counters.thread_join_parks.load(.acquire),
        .lock_contentions = contention_counters.lock_contentions.load(.acquire),
        .lock_wait_parks = contention_counters.lock_wait_parks.load(.acquire),
        .async_hold_queued = contention_counters.async_hold_queued.load(.acquire),
        .condition_async_waits = contention_counters.condition_async_waits.load(.acquire),
        .condition_async_settled = contention_counters.condition_async_settled.load(.acquire),
        .condition_waits = contention_counters.condition_waits.load(.acquire),
        .condition_wait_parks = contention_counters.condition_wait_parks.load(.acquire),
        .property_waits = contention_counters.property_waits.load(.acquire),
        .property_wait_parks = contention_counters.property_wait_parks.load(.acquire),
        .property_wait_async_enqueued = contention_counters.property_wait_async_enqueued.load(.acquire),
        .property_wait_async_settled = contention_counters.property_wait_async_settled.load(.acquire),
        .task_pump_empty = contention_counters.task_pump_empty.load(.acquire),
        .task_pump_jobs = contention_counters.task_pump_jobs.load(.acquire),
        .task_pump_async_hold_jobs = contention_counters.task_pump_async_hold_jobs.load(.acquire),
        .task_pump_condition_jobs = contention_counters.task_pump_condition_jobs.load(.acquire),
        .condition_queue_grows = contention_counters.condition_queue_grows.load(.acquire),
        .condition_queue_compactions = contention_counters.condition_queue_compactions.load(.acquire),
        .worker_channel_pushes = contention_counters.worker_channel_pushes.load(.acquire),
        .worker_channel_pops = contention_counters.worker_channel_pops.load(.acquire),
        .worker_channel_empty_pops = contention_counters.worker_channel_empty_pops.load(.acquire),
        .worker_channel_closes = contention_counters.worker_channel_closes.load(.acquire),
        .arena_lock_acquires = contention_counters.arena_lock_acquires.load(.acquire),
        .arena_lock_contentions = contention_counters.arena_lock_contentions.load(.acquire),
        .arena_lock_spins = contention_counters.arena_lock_spins.load(.acquire),
        .env_lock_acquires = contention_counters.env_lock_acquires.load(.acquire),
        .env_lock_contentions = contention_counters.env_lock_contentions.load(.acquire),
        .env_lock_spins = contention_counters.env_lock_spins.load(.acquire),
        .object_backing_lock_acquires = object.object_backing_lock_acquires,
        .object_backing_lock_contentions = object.object_backing_lock_contentions,
        .object_backing_lock_spins = object.object_backing_lock_spins,
        .object_property_lock_acquires = object.object_property_lock_acquires,
        .object_property_lock_contentions = object.object_property_lock_contentions,
        .object_property_lock_spins = object.object_property_lock_spins,
        .object_element_lock_acquires = object.object_element_lock_acquires,
        .object_element_lock_contentions = object.object_element_lock_contentions,
        .object_element_lock_spins = object.object_element_lock_spins,
        .thread_join_wait_ns = contention_counters.thread_join_wait_ns.load(.acquire),
        .lock_wait_ns = contention_counters.lock_wait_ns.load(.acquire),
        .condition_wait_ns = contention_counters.condition_wait_ns.load(.acquire),
        .property_wait_ns = contention_counters.property_wait_ns.load(.acquire),
    };
}

inline fn bumpContention(comptime field: []const u8) void {
    if (!contention_stats_enabled.load(.monotonic)) return;
    _ = @field(contention_counters, field).fetchAdd(1, .monotonic);
}

inline fn addContention(comptime field: []const u8, count: u64) void {
    if (count == 0 or !contention_stats_enabled.load(.monotonic)) return;
    _ = @field(contention_counters, field).fetchAdd(count, .monotonic);
}

pub inline fn recordArenaLockAcquire(spins: usize) void {
    bumpContention("arena_lock_acquires");
    if (spins > 0) {
        bumpContention("arena_lock_contentions");
        addContention("arena_lock_spins", @intCast(spins));
    }
}

pub inline fn recordEnvLockAcquire(spins: usize) void {
    bumpContention("env_lock_acquires");
    if (spins > 0) {
        bumpContention("env_lock_contentions");
        addContention("env_lock_spins", @intCast(spins));
    }
}

pub inline fn recordWorkerChannelPush() void {
    bumpContention("worker_channel_pushes");
}

pub inline fn recordWorkerChannelPop() void {
    bumpContention("worker_channel_pops");
}

pub inline fn recordWorkerChannelEmptyPop() void {
    bumpContention("worker_channel_empty_pops");
}

pub inline fn recordWorkerChannelClose() void {
    bumpContention("worker_channel_closes");
}

inline fn startContentionWaitTimer() ?i96 {
    if (!contention_stats_enabled.load(.monotonic)) return null;
    return std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
}

inline fn finishContentionWaitTimer(comptime field: []const u8, start_ns: ?i96) void {
    const start = start_ns orelse return;
    const elapsed = @as(u64, @intCast(@max(std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds - start, 0)));
    _ = @field(contention_counters, field).fetchAdd(elapsed, .monotonic);
}

pub fn currentThreadId() u64 {
    return if (t_current) |rec| rec.id else 0;
}

test "jsthread contention stats reset and snapshot" {
    disableContentionStats();
    bumpContention("lock_contentions");
    finishContentionWaitTimer("lock_wait_ns", startContentionWaitTimer());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().events());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().waitNs());

    resetContentionStats();
    try std.testing.expectEqual(@as(u64, 0), contentionStats().events());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().parks());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().waitNs());

    bumpContention("lock_contentions");
    bumpContention("async_hold_queued");
    bumpContention("condition_async_waits");
    bumpContention("condition_async_settled");
    bumpContention("condition_waits");
    bumpContention("property_waits");
    bumpContention("property_wait_async_enqueued");
    bumpContention("property_wait_async_settled");
    bumpContention("thread_join_parks");
    bumpContention("lock_wait_parks");
    bumpContention("condition_wait_parks");
    bumpContention("property_wait_parks");
    bumpContention("task_pump_empty");
    bumpContention("task_pump_jobs");
    bumpContention("task_pump_async_hold_jobs");
    bumpContention("task_pump_condition_jobs");
    bumpContention("condition_queue_grows");
    bumpContention("condition_queue_compactions");
    recordWorkerChannelPush();
    recordWorkerChannelPop();
    recordWorkerChannelEmptyPop();
    recordWorkerChannelClose();
    recordArenaLockAcquire(3);
    recordEnvLockAcquire(5);
    object_profile.recordBackingLockAcquire(7);
    object_profile.recordPropertyLockAcquire(11);
    object_profile.recordElementLockAcquire(13);
    finishContentionWaitTimer("thread_join_wait_ns", 0);
    finishContentionWaitTimer("lock_wait_ns", 0);
    finishContentionWaitTimer("condition_wait_ns", 0);
    finishContentionWaitTimer("property_wait_ns", 0);

    const stats = contentionStats();
    try std.testing.expectEqual(@as(u64, 6), stats.events());
    try std.testing.expectEqual(@as(u64, 4), stats.parks());
    try std.testing.expectEqual(@as(u64, 2), stats.asyncWaits());
    try std.testing.expectEqual(@as(u64, 2), stats.asyncSettled());
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_empty);
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_jobs);
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_async_hold_jobs);
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_condition_jobs);
    try std.testing.expectEqual(@as(u64, 1), stats.condition_queue_grows);
    try std.testing.expectEqual(@as(u64, 1), stats.condition_queue_compactions);
    try std.testing.expectEqual(@as(u64, 1), stats.worker_channel_pushes);
    try std.testing.expectEqual(@as(u64, 1), stats.worker_channel_pops);
    try std.testing.expectEqual(@as(u64, 1), stats.worker_channel_empty_pops);
    try std.testing.expectEqual(@as(u64, 1), stats.worker_channel_closes);
    try std.testing.expectEqual(@as(u64, 1), stats.arena_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.arena_lock_contentions);
    try std.testing.expectEqual(@as(u64, 3), stats.arena_lock_spins);
    try std.testing.expectEqual(@as(u64, 1), stats.env_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.env_lock_contentions);
    try std.testing.expectEqual(@as(u64, 5), stats.env_lock_spins);
    try std.testing.expectEqual(@as(u64, 1), stats.object_backing_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.object_backing_lock_contentions);
    try std.testing.expectEqual(@as(u64, 7), stats.object_backing_lock_spins);
    try std.testing.expectEqual(@as(u64, 1), stats.object_property_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.object_property_lock_contentions);
    try std.testing.expectEqual(@as(u64, 11), stats.object_property_lock_spins);
    try std.testing.expectEqual(@as(u64, 1), stats.object_element_lock_acquires);
    try std.testing.expectEqual(@as(u64, 1), stats.object_element_lock_contentions);
    try std.testing.expectEqual(@as(u64, 13), stats.object_element_lock_spins);
    try std.testing.expect(stats.thread_join_wait_ns > 0);
    try std.testing.expect(stats.lock_wait_ns > 0);
    try std.testing.expect(stats.condition_wait_ns > 0);
    try std.testing.expect(stats.property_wait_ns > 0);
    try std.testing.expectEqual(stats.thread_join_wait_ns + stats.lock_wait_ns + stats.condition_wait_ns + stats.property_wait_ns, stats.waitNs());

    resetContentionStats();
    try std.testing.expectEqual(@as(u64, 0), contentionStats().events());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().parks());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().asyncWaits());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().asyncSettled());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_empty);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_jobs);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_async_hold_jobs);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_condition_jobs);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().condition_queue_grows);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().condition_queue_compactions);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().worker_channel_pushes);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().worker_channel_pops);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().worker_channel_empty_pops);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().worker_channel_closes);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().arena_lock_acquires);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().arena_lock_contentions);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().arena_lock_spins);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().env_lock_acquires);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().env_lock_contentions);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().env_lock_spins);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_backing_lock_acquires);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_backing_lock_contentions);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_backing_lock_spins);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_property_lock_acquires);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_property_lock_contentions);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_property_lock_spins);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_element_lock_acquires);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_element_lock_contentions);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().object_element_lock_spins);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().waitNs());
    disableContentionStats();
}

/// Install the `Thread` global into an `enable_threads` Context. Called by
/// `Context.createWith` while still single-threaded.
pub fn installThreadAPI(ctx: *Context) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;

    const proto = try gc_mod.allocObj(a);
    proto.* = .{};
    try interp.setNative(a, rs, proto, "join", 0, threadJoinFn);
    try interp.setNative(a, rs, proto, "asyncJoin", 0, threadAsyncJoinFn);
    try interp.setNativeGetter(a, rs, proto, "id", threadIdGetter);
    try setTag(ctx, proto, "Thread");

    const ctor = try gc_mod.allocObj(a);
    ctor.* = .{ .native = threadCtorFn, .native_ctor = true, .private_data = ctx };
    try interp.installNativeProps(a, rs, ctor, "Thread", 1);
    try ctor.setOwn(a, rs, "prototype", Value.obj(proto));
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try interp.setConstructor(a, rs, proto, ctor);
    try interp.setNativeGetter(a, rs, ctor, "current", threadCurrentGetter);
    try interp.setNative(a, rs, ctor, "restrict", 1, threadRestrictFn);

    try ctx.env.put("Thread", Value.obj(ctor));
    try ctx.global_object.setOwn(a, rs, "Thread", Value.obj(ctor));
    try ctx.global_object.setAttr(a, "Thread", .{ .writable = true, .enumerable = false, .configurable = true });

    // The main thread's record: id 0, never "joinable-blocking" (done from
    // birth, so a stray main.join() returns undefined instead of hanging).
    try ctx.reserveJsThreadsLocked(1);
    const main_rec = try a.create(ThreadRecord);
    main_rec.* = .{ .id = 0, .gil = ctx.gil.?, .ctx = ctx, .done = true, .exited = true, .microtasks = &ctx.microtasks };
    main_rec.js_obj = try makeWrapper(ctx, main_rec);
    t_current = main_rec;
    ctx.js_threads.appendAssumeCapacity(main_rec);

    try installSyncAPI(ctx);
    try installConcurrentAccessError(ctx);
}

/// The `ConcurrentAccessError` global error constructor (PR-249: thrown by
/// enforced access to a `Thread.restrict`ed object). Rides the engine's
/// name-driven error machinery, chained under %Error%.
fn installConcurrentAccessError(ctx: *Context) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;
    const name = "ConcurrentAccessError";
    const base_v = ctx.env.get("Error") orelse return;
    if (!base_v.isObject()) return;
    const base_proto_v = base_v.asObj().getOwn("prototype") orelse return;
    if (!base_proto_v.isObject()) return;

    const ctor = try gc_mod.allocObj(a);
    ctor.* = .{ .private_data = @ptrCast(&ctx.env), .proto = base_v.asObj() };
    try ctor.setErrorCtor(a, name);
    try interp.installNativeProps(a, rs, ctor, name, 1);
    const proto = try gc_mod.allocObj(a);
    proto.* = .{ .proto = base_proto_v.asObj() };
    const ro = value.PropAttr{ .writable = true, .enumerable = false, .configurable = true };
    try proto.setOwn(a, rs, "name", Value.str("ConcurrentAccessError"));
    try proto.setAttr(a, "name", ro);
    try proto.setOwn(a, rs, "message", Value.str(""));
    try proto.setAttr(a, "message", ro);
    try proto.setOwn(a, rs, "constructor", Value.obj(ctor));
    try proto.setAttr(a, "constructor", ro);
    try ctor.setOwn(a, rs, "prototype", Value.obj(proto));
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try ctx.env.put(name, Value.obj(ctor));
    try ctx.global_object.setOwn(a, rs, name, Value.obj(ctor));
    try ctx.global_object.setAttr(a, name, .{ .writable = true, .enumerable = false, .configurable = true });
}

fn makeWrapper(ctx: *Context, rec: *ThreadRecord) !*value.Object {
    const a = ctx.arena();
    const o = try gc_mod.allocObj(a);
    o.* = .{ .private_data = rec, .private_data_tag = .jsthread_thread };
    if (ctx.env.get("Thread")) |c| if (c.isObject()) {
        if (try threadProtoOf(ctx, c.asObj())) |p| o.proto = p;
    };
    return o;
}

fn threadProtoOf(ctx: *Context, ctor: *value.Object) !?*value.Object {
    var machine = ctx.interpreter();
    const p = try machine.getProperty(Value.obj(ctor), "prototype");
    return if (p.isObject()) p.asObj() else null;
}

fn recordOf(self: *Interpreter, this: Value) ?*ThreadRecord {
    _ = self;
    if (!this.isObject()) return null;
    const obj = this.asObj();
    if (obj.private_data_tag != .jsthread_thread) return null;
    const pd = obj.private_data orelse return null;
    // Only Thread wrappers reach the Thread.prototype methods in practice;
    // the private_data brand is the check.
    if (this.asObj().proto == null) return null;
    return @ptrCast(@alignCast(pd));
}

/// `new Thread(fn, ...args)` — spawn fn on a new OS thread in this realm.
fn threadCtorFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "calling Thread constructor without new is invalid");
    const native = self.active_native orelse return self.throwError("TypeError", "Thread constructor lost its context");
    const ctx: *Context = @ptrCast(@alignCast(native.private_data.?));
    const g = ctx.gil orelse return self.throwError("TypeError", "Thread requires an enable_threads Context");

    const fn_v = if (args.len > 0) args[0] else Value.undef();
    if (!fn_v.isCallable())
        return self.throwError("TypeError", "Thread constructor requires a callable argument");

    // The cap-check → id-claim → list-append must be one atomic transaction:
    // two concurrent constructions (once the GIL is dropped during bytecode)
    // must not both pass the live cap or claim the same `next_thread_id`. The
    // GIL serializes this today; `api_lock` keeps it serialized independently of
    // the GIL. No JS runs inside, so there is no reentrancy back into the lock.
    g.lockApi();
    defer g.unlockApi();

    // Live cap and id-space checks come BEFORE the id is consumed — a
    // refused spawn must not burn a TID or leak a live entry (I17).
    if (ctx.max_js_threads) |cap| {
        var live: u32 = 0;
        for (ctx.js_threads.items) |r| {
            if (!r.done) live += 1;
        }
        if (live >= cap)
            return self.throwError("RangeError", "too many live Threads (or thread-ID space exhausted)");
    }
    if (g.next_thread_id > 0x7ffe)
        return self.throwError("RangeError", "too many live Threads (or thread-ID space exhausted)");

    const a = ctx.arena();
    try ctx.reserveJsThreadsLocked(1);
    const rec = try a.create(ThreadRecord);
    rec.* = .{ .id = g.next_thread_id, .gil = g, .ctx = ctx };
    g.next_thread_id += 1;
    rec.js_obj = makeWrapper(ctx, rec) catch return error.OutOfMemory;
    const call_args = try a.dupe(Value, if (args.len > 1) args[1..] else &.{});
    ctx.js_threads.appendAssumeCapacity(rec);
    if (ctx.js_threads.items.len >= 3) ctx.enableCooperativeGcTracking();

    rec.thread = std.Thread.spawn(.{ .stack_size = 64 << 20 }, threadMain, .{ rec, fn_v, call_args }) catch {
        rec.done = true;
        rec.exited = true;
        return self.throwError("Error", "Thread: could not spawn OS thread");
    };
    return Value.obj(rec.js_obj.?);
}

/// Acquire the realm GIL for a terminating thread's completion/settlement
/// section (`publishThreadCompletion` + asyncJoin reaction routing) without
/// stalling a mid-script parallel collector. `Gil.acquire` blocks in native
/// mutex code, publishing no roots; when several threads terminate together
/// (the termination-reaction profile) they serialize here, and a blocked one
/// that never republishes its precise roots for the collector's next
/// generation makes `driveParallelCollection` exhaust its budget and abort —
/// the low-frequency threadfuzz-midgc "did not finish a parallel collection"
/// flake. This thread's interpreter roots are stable at this point (it runs no
/// JS until the lock is held, and its live values — `result`/`exception`, and
/// `rec.pending_joins` traced via `ctx.js_threads` — are already in the
/// collector-visible precise set), so servicing the same root-publication hook
/// the sync-wait parkers use between short backoffs lets the collector count
/// this thread and converge, rather than blocking it out. Mirrors the
/// lock/property-wait pump loops.
fn acquireGilForTeardown(self: *Interpreter, g: *gil_mod.Gil) void {
    while (!g.tryAcquire()) {
        // No waiter/lock state held here, so publishing precise roots for any
        // open collector generation is safe. Back off briefly rather than
        // yield-spinning so the GIL holder and the collector keep a core under
        // the oversubscription that makes this path flake in CI.
        self.serviceGcSafepoint();
        std.Io.sleep(agent.engineIo(), .fromMilliseconds(1), .awake) catch {};
    }
}

fn threadMain(rec: *ThreadRecord, fn_v: Value, args: []const Value) void {
    const g = rec.gil;
    defer markThreadExited(rec);
    if (rec.ctx.parallel_js) _ = rec.ctx.parallel_worker_count.fetchAdd(1, .acq_rel);
    defer {
        if (rec.ctx.parallel_js) _ = rec.ctx.parallel_worker_count.fetchSub(1, .acq_rel);
    }
    if (!rec.ctx.parallel_js) g.acquire();
    defer if (!rec.ctx.parallel_js) g.release();
    const gc_saved = gc_mod.setActiveHeap(rec.ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const sa_saved = strcell.setActiveArena(rec.ctx.arena());
    defer _ = strcell.setActiveArena(sa_saved);
    // Register this spawned thread's native-stack scan boundary. Mid-script
    // collection is gated off while any JS thread is running (a parked thread's
    // stack is not scanned yet — the M3 safepoint protocol), so this is hygiene
    // for the future, not yet load-bearing.
    const ss_saved = stack_scan.enter(@frameAddress());
    defer stack_scan.leave(ss_saved);
    // Publish this thread's park record so a mid-script collection on another
    // thread can root our native stack while we are parked. Registered/
    // unregistered under the GIL (held here); the defer runs before the final
    // `g.release()` above (LIFO), i.e. while we still hold the lock and before
    // our stack is torn down.
    if (rec.ctx.parallel_js) g.acquire();
    g.registerPark(stack_scan.parkRecord());
    if (rec.ctx.parallel_js) g.release();
    defer {
        if (rec.ctx.parallel_js) g.acquire();
        g.unregisterPark(stack_scan.parkRecord());
        if (rec.ctx.parallel_js) g.release();
    }
    t_current = rec;
    defer clearThreadLocalValuesForCurrentThread(rec);
    // A per-thread interpreter over the SHARED realm: same arena, environment,
    // global object, and shapes (safe under the GIL), with its own job queues.
    // join() performs the joiner's completion checkpoint before observing the
    // result, which is the only cross-thread microtask drain point.
    // Heap-allocate the per-thread microtask queue (arena-owned, freed at realm
    // teardown) instead of putting it on this thread's native stack. A peer
    // settling a cross-thread promise appends into this queue under the queue's
    // microtask lock, growing its ArrayList header; on the stack that write
    // races the collector's CONSERVATIVE scan of this thread's stack (the blind
    // word scan can't take that queue lock). Off the stack the header is never
    // conservatively scanned, and the queued tasks stay precisely rooted via
    // `machine.microtasks` in `traceInterpreterRoots` (which holds the lock).
    const microtasks = rec.ctx.arena().create(promise.MicrotaskQueue) catch {
        var pj = publishThreadCompletion(rec, true, outOfMemoryCompletionValue(rec.ctx));
        finishThreadJoinSettlement(rec);
        pj.deinit(rec.ctx.arena());
        return;
    };
    microtasks.* = .{};
    var async_waiters: std.ArrayListUnmanaged(interp.AsyncWaiterEntry) = .empty;
    rec.microtasks = microtasks;
    var machine = rec.ctx.interpreter();
    rec.ctx.pushActiveInterpreter(&machine) catch {
        var pending_joins = publishThreadCompletion(rec, true, outOfMemoryCompletionValue(rec.ctx));
        finishThreadJoinSettlement(rec);
        pending_joins.deinit(rec.ctx.arena());
        return;
    };
    defer rec.ctx.popActiveInterpreter(&machine);
    const ai_saved = gc_mod.setActiveInterpreter(&machine);
    defer _ = gc_mod.setActiveInterpreter(ai_saved);
    machine.microtasks = microtasks;
    machine.async_waiters = &async_waiters;
    defer machine.abandonTimers();
    var result: Value = Value.undef();
    var threw = false;
    if (machine.callValueWithThis(fn_v, args, Value.undef())) |out| {
        // Root the return value before the drains below. They run JS that can
        // trigger a mid-script parallel GC, and until `publishThreadCompletion`
        // records `out` in `rec.result` it lives ONLY on this thread's native
        // stack — which the collector does not conservatively scan for a running
        // peer (only parked peers' frozen stacks and self-published precise
        // roots). Without a precise root here `out` is swept during the drain,
        // and every later root/barrier then holds a dangling pointer, surfacing
        // as the `promiseOf` alignment panic in thread settlement. `gc_temp_roots`
        // is a precise per-interpreter root, published at every safepoint.
        machine.gc_temp_roots.append(machine.arena, out) catch {};
        machine.drainMicrotasks() catch {};
        // Thread-local async waiters are owned by this interpreter. If a thread
        // returns a pending Atomics.waitAsync promise, asyncJoin can assimilate
        // the promise object but cannot harvest this soon-to-be-destroyed
        // waiter list, so run the thread's final settlement checkpoint before
        // publishing completion.
        pumpTasks(&machine);
        machine.settleAsyncWaiters();
        machine.keepaliveTimers();
        result = out;
    } else |err| {
        machine.drainMicrotasks() catch {};
        if (async_waiters.items.len > 0) {
            agent.abandonAsync(@ptrCast(&async_waiters));
            async_waiters.clearRetainingCapacity();
        }
        abandonPropAsyncQueue(g, microtasks);
        threw = true;
        result = switch (err) {
            error.OutOfMemory => outOfMemoryCompletionValue(rec.ctx),
            else => machine.exception,
        };
    }
    // Settle asyncJoin promises on this (the settling) thread, then drain
    // the reactions it just queued. `publishThreadCompletion` snapshots the
    // pending join list under `join_mutex`; JS/promise work runs after release.
    if (rec.ctx.parallel_js) acquireGilForTeardown(&machine, g);
    defer if (rec.ctx.parallel_js) g.release();
    var pending_joins = publishThreadCompletion(rec, threw, result);
    defer {
        finishThreadJoinSettlement(rec);
        pending_joins.deinit(rec.ctx.arena());
    }
    // publishThreadCompletion emptied `rec.pending_joins` (a GC root) into this
    // local snapshot, so settle the promises and the result value under explicit
    // roots: settlement runs JS (reaction and thenable `then` getters, microtask
    // drain) that can trigger a mid-script GC, and `resolve` reads the result
    // value's shape (`promiseOf`) — a swept result surfaces as a misaligned
    // `Object.promise`. Root both the snapshot promises and the result in
    // `gc_temp_roots` (traced per-interpreter) for the settlement's duration.
    const temp_root_mark = machine.gc_temp_roots.items.len;
    defer machine.gc_temp_roots.shrinkRetainingCapacity(temp_root_mark);
    machine.gc_temp_roots.append(machine.arena, result) catch {};
    for (pending_joins.items) |pending| machine.gc_temp_roots.append(machine.arena, Value.obj(pending.promise)) catch {};
    const saved_microtasks = machine.microtasks;
    for (pending_joins.items) |pending| {
        // Route the settlement's reactions. When the joiner is a spawned thread
        // (`owner != null`) we enqueue into the realm queue (`ctx.microtasks`,
        // which the host drains until every thread is done) rather than the
        // joiner thread's local queue: that queue can be torn down before — or
        // concurrently with — this settlement, stranding a nested-`asyncJoin`
        // reaction (its `.then` continuation may even have been registered by a
        // third thread via thenable adoption). The main-thread joiner's queue
        // *is* `ctx.microtasks`, so this is identical for it. (A live joiner
        // thread loses strict reaction affinity, but the reaction still runs in
        // the shared realm, which is what asyncJoin's await observers need; no
        // liveness race remains.)
        machine.microtasks = if (pending.owner != null) &rec.ctx.microtasks else pending.microtasks;
        // Re-shade the result and the pending promise on each iteration: a prior
        // iteration's `resolve` runs JS (thenable `then` getters, reaction
        // enqueue) that can begin *and* advance a mid-script parallel GC, and
        // `resolve` immediately reads the result value's shape (`promiseOf`). The
        // gc_temp_roots rooting above is captured by the self-publish handshake at
        // safepoints, but this barrier closes the narrow window where a mark
        // starts within a reaction chain between safepoints — shading is
        // idempotent and cheap (a no-op when no mark is active).
        gc_mod.barrierValue(result);
        gc_mod.barrierValue(Value.obj(pending.promise));
        if (promise.promiseOf(Value.obj(pending.promise))) |pp| {
            if (threw)
                promise.reject(&machine, pp, result) catch {}
            else
                promise.resolve(&machine, pp, result) catch {};
        }
    }
    machine.microtasks = saved_microtasks;
    machine.drainMicrotasks() catch {};
    transferPendingJoinQueue(rec.ctx, microtasks, &rec.ctx.microtasks);
    transferPropAsyncQueue(g, microtasks, &rec.ctx.microtasks);
    // Pending prop-async tickets now target the realm queue, but another peer
    // may already have removed one of this thread's tickets from the global
    // table and be about to settle it. Publish "local queue closed" before the
    // final flush, under the same mutex that late settlement checks, so such a
    // peer either appends before this flush or reroutes to the realm queue.
    {
        const io = agent.engineIo();
        rec.join_mutex.lockUncancelable(io);
        rec.microtasks = null;
        rec.join_mutex.unlock(io);
    }
    // Flush any reactions a peer routed into this thread's local queue after the
    // final drain above (e.g. a nested-asyncJoin or removed prop-async ticket
    // settling here in the teardown window) into the realm queue, which the host
    // keeps draining — otherwise they strand when this queue is abandoned below.
    // Serialized with peer enqueues by the source and destination queue locks
    // under no-GIL (a direct transfer in GIL mode).
    transferMicrotasks(rec.ctx, microtasks, &rec.ctx.microtasks);
}

fn transferMicrotasks(ctx: *Context, from: *promise.MicrotaskQueue, to: *promise.MicrotaskQueue) void {
    if (from == to) return;
    if (ctx.parallel_js) {
        const from_addr = @intFromPtr(from);
        const to_addr = @intFromPtr(to);
        const source_first = from_addr < to_addr;
        if (source_first) {
            from.acquire();
            to.acquire();
        } else {
            to.acquire();
            from.acquire();
        }
        transferMicrotasksUnlocked(ctx, from, to);
        if (source_first) {
            to.release();
            from.release();
        } else {
            from.release();
            to.release();
        }
        return;
    }
    transferMicrotasksUnlocked(ctx, from, to);
}

fn transferMicrotasksUnlocked(ctx: *Context, from: *promise.MicrotaskQueue, to: *promise.MicrotaskQueue) void {
    if (!from.isEmpty()) {
        to.appendPendingSlice(ctx.arena(), from) catch {};
        from.clearRetainingCapacity();
    }
}

fn publishThreadCompletion(rec: *ThreadRecord, threw: bool, result: Value) std.ArrayListUnmanaged(PendingJoin) {
    gc_mod.barrierValue(result);
    const io = agent.engineIo();
    rec.join_mutex.lockUncancelable(io);
    defer rec.join_mutex.unlock(io);
    rec.threw = threw;
    rec.result = result;
    const pending = rec.pending_joins;
    rec.pending_joins = .empty;
    rec.settling_joins = pending;
    rec.joins_settled = pending.items.len == 0;
    rec.done = true;
    rec.done_cond.broadcast(io);
    return pending;
}

fn finishThreadJoinSettlement(rec: *ThreadRecord) void {
    const io = agent.engineIo();
    rec.join_mutex.lockUncancelable(io);
    rec.settling_joins = .empty;
    rec.joins_settled = true;
    rec.done_cond.broadcast(io);
    rec.join_mutex.unlock(io);
}

fn threadJoinReadyLocked(rec: *const ThreadRecord) bool {
    return rec.done and rec.joins_settled;
}

fn appendPendingJoinLocked(rec: *ThreadRecord, arena: std.mem.Allocator, pending: PendingJoin) !void {
    const spare = rec.pending_joins.capacity - rec.pending_joins.items.len;
    if (spare == 0) {
        // The parallel tracer takes `join_mutex` to find pending promise roots.
        // Capacity growth runs with that mutex held, so recovery must not
        // collect back into it.
        gc_runtime.enterTraceSensitiveLock();
        defer gc_runtime.leaveTraceSensitiveLock();
        try rec.pending_joins.ensureTotalCapacity(arena, rec.pending_joins.items.len + pending_join_reserve_granularity);
    }
    rec.pending_joins.appendAssumeCapacity(pending);
}

test "Thread asyncJoin pending growth and synchronous join settlement gate" {
    var probe = TraceSensitiveAllocProbe{ .inner = std.testing.allocator };
    const a = probe.allocator();
    var rec = ThreadRecord{
        .id = 1,
        .gil = undefined,
        .ctx = undefined,
    };
    defer rec.pending_joins.deinit(a);

    var microtasks = promise.MicrotaskQueue{};
    var first_promise = value.Object{};
    try appendPendingJoinLocked(&rec, a, .{ .promise = &first_promise, .microtasks = &microtasks });
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(rec.pending_joins.capacity >= pending_join_reserve_granularity);

    const first_capacity = rec.pending_joins.capacity;
    var promises = try a.alloc(value.Object, first_capacity + 1);
    defer a.free(promises);
    @memset(promises, .{});

    var i: usize = 0;
    while (rec.pending_joins.items.len < first_capacity) : (i += 1) {
        try appendPendingJoinLocked(&rec, a, .{ .promise = &promises[i], .microtasks = &microtasks });
    }
    try std.testing.expectEqual(first_capacity, rec.pending_joins.items.len);
    try std.testing.expectEqual(first_capacity, rec.pending_joins.capacity);

    try appendPendingJoinLocked(&rec, a, .{ .promise = &promises[i], .microtasks = &microtasks });
    try std.testing.expectEqual(first_capacity + 1, rec.pending_joins.items.len);
    try std.testing.expect(rec.pending_joins.capacity > first_capacity);

    var pending = publishThreadCompletion(&rec, false, Value.undef());
    defer pending.deinit(a);
    try std.testing.expect(rec.done);
    try std.testing.expect(!rec.joins_settled);
    try std.testing.expect(!threadJoinReadyLocked(&rec));
    try std.testing.expectEqual(first_capacity + 1, pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.pending_joins.items.len);
    finishThreadJoinSettlement(&rec);
    try std.testing.expect(rec.joins_settled);
    try std.testing.expect(threadJoinReadyLocked(&rec));
    try std.testing.expectEqual(@as(usize, 0), rec.settling_joins.items.len);
}

fn markThreadExited(rec: *ThreadRecord) void {
    const io = agent.engineIo();
    rec.join_mutex.lockUncancelable(io);
    rec.exited = true;
    rec.done_cond.broadcast(io);
    rec.join_mutex.unlock(io);
}

/// `Thread.prototype.join()` — park (GIL released) until the thread's fn has
/// returned and its queues drained; return its value or rethrow its
/// exception object.
fn threadJoinFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recordOf(self, this) orelse return self.throwError("TypeError", "Thread.prototype.join called on incompatible receiver");
    if (rec == t_current) return self.throwError("Error", "Thread cannot join itself");
    // The gate guards the BLOCK, not the call: joining a finished thread is
    // always allowed.
    const io = agent.engineIo();
    rec.join_mutex.lockUncancelable(io);
    if (!threadJoinReadyLocked(rec) and !self.main_can_block) {
        rec.join_mutex.unlock(io);
        return self.throwError("TypeError", "Thread.prototype.join cannot block the current thread");
    }
    var join_mutex_locked = true;
    errdefer if (join_mutex_locked) rec.join_mutex.unlock(io);
    while (!threadJoinReadyLocked(rec)) try parkPumpThreadJoin(self, rec);
    const threw = rec.threw;
    const result = rec.result;
    rec.join_mutex.unlock(io);
    join_mutex_locked = false;
    self.drainMicrotasks() catch {};
    if (threw) {
        self.exception = result;
        return error.Throw;
    }
    return result;
}

fn threadIdGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recordOf(self, this) orelse return self.throwError("TypeError", "Thread.prototype.id called on incompatible receiver");
    return Value.num(@floatFromInt(rec.id));
}

fn threadCurrentGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    _ = self;
    const rec = t_current orelse return Value.undef();
    return Value.obj(rec.js_obj.?);
}

// ---- Lock / Condition / ThreadLocal (Phase 6 step 3) -----------------------
// PR-249 semantics: Lock is non-recursive with a `hold(fn)` discipline
// (release is finally-equivalent); Condition.wait(lock) atomically releases
// the lock and parks (spurious wakeups allowed); ThreadLocal.value is
// per-thread storage for any JS value. In `.gil = true` mode, blocking paths
// release the legacy VM lock while parked; in the default no-GIL mode, the
// same operations use their per-structure mutexes and publish roots for GC.

const SyncBrand = usize;
const sync_brand_lock: SyncBrand = 0x6a73_7468_6c6f_636b;
const sync_brand_condition: SyncBrand = 0x6a73_7468_636f_6e64;
const sync_brand_thread_local: SyncBrand = 0x6a73_7468_746c_736c;
const sync_brand_unlock_token: SyncBrand = 0x6a73_7468_7574_6f6b;
const sync_brand_release_state: SyncBrand = 0x6a73_7468_7265_6c73;
const lock_pending_reserve_granularity = 16;
const condition_queue_reserve_granularity = 16;

const LockRecord = struct {
    brand: SyncBrand = sync_brand_lock,
    gil: *gil_mod.Gil,
    /// GC wrapper that owns this native side record. Used only as the owner of
    /// old-to-young barriers for pending jobs; the record itself is arena-lived.
    owner: ?*value.Object = null,
    mutex: std.Io.Mutex = .init,
    locked: bool = false,
    /// Holding thread (0 = unheld) — recursion detection: a nested hold on
    /// the same thread must throw, not self-deadlock.
    holder: u64 = 0,
    cond: std.Io.Condition = .init,
    /// Queued asyncHold jobs, granted FIFO at release time.
    pending: std.ArrayListUnmanaged(*HoldJob) = .empty,
    pending_head: usize = 0,
    /// Jobs that were already granted as realm tasks but could not run yet
    /// (for example because a sync waiter took the handoff first). They must be
    /// retried before ordinary pending jobs, but keeping them in a small front
    /// stack avoids shifting `pending` when `pending_head == 0`.
    pending_front: std.ArrayListUnmanaged(*HoldJob) = .empty,
    /// An async grant exists but its job hasn't run yet. The grant already
    /// excludes sync `hold`, but it is not delivered enough for
    /// `Condition.asyncWait` to consume.
    grant_pending: bool = false,
    /// A delivered no-fn grant's live release() state (4.3(b): asyncWait may
    /// consume it, poisoning the release function).
    active_release: ?*ReleaseState = null,
    /// Thread currently running a delivered asyncHold(fn) grant. It is allowed
    /// to consume the grant via cond.asyncWait(lock), but it is not a sync
    /// lock owner for cond.wait(lock).
    async_runner: u64 = 0,
    /// Threads currently parked acquiring this lock (hold contention or a
    /// Condition.wait reacquire). Release serves them before queued async
    /// jobs — a parked thread arrived first, and an async grant handed to a
    /// parker's own undrained queue would deadlock its join.
    sync_waiting: usize = 0,
    /// Release handoff generation for sync waiters. A waiter records the
    /// current value before parking and can acquire only after a release
    /// advances it, so a fresh barger cannot steal the signaled handoff.
    sync_generation: u64 = 0,

    fn hasPending(self: *const LockRecord) bool {
        return self.pending_front.items.len > 0 or self.pending_head < self.pending.items.len;
    }

    fn reservePending(arena: std.mem.Allocator, list: *std.ArrayListUnmanaged(*HoldJob), additional: usize) !void {
        const spare = list.capacity - list.items.len;
        if (spare >= additional) return;
        const extra = @max(additional, lock_pending_reserve_granularity);
        gc_runtime.enterTraceSensitiveLock();
        defer gc_runtime.leaveTraceSensitiveLock();
        try list.ensureTotalCapacity(arena, list.items.len + extra);
    }

    fn appendPending(self: *LockRecord, arena: std.mem.Allocator, job: *HoldJob) !void {
        try reservePending(arena, &self.pending, 1);
        self.pending.appendAssumeCapacity(job);
    }

    fn pushFrontPending(self: *LockRecord, arena: std.mem.Allocator, job: *HoldJob) !void {
        if (self.pending_front.items.len == 0 and self.pending_head > 0) {
            self.pending_head -= 1;
            self.pending.items[self.pending_head] = job;
            return;
        }
        try reservePending(arena, &self.pending_front, 1);
        self.pending_front.appendAssumeCapacity(job);
    }

    fn popPending(self: *LockRecord) ?*HoldJob {
        if (self.pending_front.pop()) |job| return job;
        if (!self.hasPending()) {
            self.pending.clearRetainingCapacity();
            self.pending_head = 0;
            return null;
        }
        const job = self.pending.items[self.pending_head];
        self.pending.items[self.pending_head] = undefined;
        self.pending_head += 1;
        if (self.pending_head == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            self.pending_head = 0;
        }
        return job;
    }
};

/// A parked sync waiter's ticket. Timed-out/terminated waiters are marked
/// canceled and skipped by the FIFO head cursor instead of being removed from
/// the middle of the condition queue.
const SyncCondTicket = struct {
    woken: bool = false,
    canceled: bool = false,
    /// Set once the woken waiter has re-registered on the lock — notifyAll's
    /// handoff loops until every wake is consumed.
    consumed: bool = false,
};

const CondEntry = union(enum) {
    sync: *SyncCondTicket,
    asynchronous: *AsyncCondWaiter,
};

const CondRecord = struct {
    brand: SyncBrand = sync_brand_condition,
    gil: *gil_mod.Gil,
    owner: ?*value.Object = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// ONE FIFO domain for sync and async waiters (4.3: notify wakes them
    /// uniformly in arrival order — cross-kind).
    queue: std.ArrayListUnmanaged(CondEntry) = .empty,
    queue_head: usize = 0,
    /// Number of sync tickets from the current notify operation that still
    /// need to acknowledge re-registration on their lock. The notifier holds
    /// `mutex` across the handoff wait, so this is a single-operation counter
    /// rather than a durable queue field.
    sync_handoff_pending: usize = 0,

    fn maybeCompactBeforeAppend(self: *CondRecord) void {
        if (self.queue_head == 0) return;
        if (self.queue.items.len < self.queue.capacity) return;
        const live_len = self.queue.items.len - self.queue_head;
        if (live_len == 0) {
            self.queue.clearRetainingCapacity();
            self.queue_head = 0;
            return;
        }
        // Keep the notify hot path cursor-based, but do not let steady
        // notify/re-wait churn grow the backing array forever. Compact only
        // when an append would otherwise allocate and the consumed prefix is
        // large enough to make the copy amortized.
        if (self.queue_head < condition_queue_reserve_granularity) return;
        if (self.queue_head < live_len) return;
        const live = self.queue.items[self.queue_head..];
        std.mem.copyForwards(CondEntry, self.queue.items[0..live.len], live);
        self.queue.shrinkRetainingCapacity(live.len);
        self.queue_head = 0;
        bumpContention("condition_queue_compactions");
    }

    fn appendWaiter(self: *CondRecord, arena: std.mem.Allocator, entry: CondEntry) !void {
        self.maybeCompactBeforeAppend();
        const spare = self.queue.capacity - self.queue.items.len;
        if (spare == 0) {
            gc_runtime.enterTraceSensitiveLock();
            defer gc_runtime.leaveTraceSensitiveLock();
            try self.queue.ensureTotalCapacity(arena, self.queue.items.len + condition_queue_reserve_granularity);
            bumpContention("condition_queue_grows");
        }
        self.queue.appendAssumeCapacity(entry);
    }

    fn popWaiter(self: *CondRecord) ?CondEntry {
        while (self.queue_head < self.queue.items.len) {
            const entry = self.queue.items[self.queue_head];
            self.queue.items[self.queue_head] = undefined;
            self.queue_head += 1;
            if (self.queue_head == self.queue.items.len) {
                self.queue.clearRetainingCapacity();
                self.queue_head = 0;
            }
            switch (entry) {
                .sync => |t| if (t.canceled) continue,
                else => {},
            }
            return entry;
        }
        self.queue.clearRetainingCapacity();
        self.queue_head = 0;
        return null;
    }
};

fn createSyncCondTicketTraceSensitive(arena: std.mem.Allocator) std.mem.Allocator.Error!*SyncCondTicket {
    gc_runtime.enterTraceSensitiveLock();
    defer gc_runtime.leaveTraceSensitiveLock();
    return arena.create(SyncCondTicket);
}

const TraceSensitiveAllocProbe = struct {
    inner: std.mem.Allocator,
    saw_trace_sensitive_alloc: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn note(self: *@This()) void {
        self.saw_trace_sensitive_alloc = self.saw_trace_sensitive_alloc or gc_runtime.inTraceSensitiveLock();
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.note();
        return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.note();
        return self.inner.vtable.resize(self.inner.ptr, mem, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.note();
        return self.inner.vtable.remap(self.inner.ptr, mem, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.inner.vtable.free(self.inner.ptr, mem, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
};

test "condition queue head cursor skips canceled sync waiters" {
    var rec = CondRecord{ .gil = undefined };
    defer rec.queue.deinit(std.testing.allocator);

    var t0 = SyncCondTicket{};
    var t1 = SyncCondTicket{};
    var t2 = SyncCondTicket{};
    try rec.appendWaiter(std.testing.allocator, .{ .sync = &t0 });
    try rec.appendWaiter(std.testing.allocator, .{ .sync = &t1 });
    try rec.appendWaiter(std.testing.allocator, .{ .sync = &t2 });

    const first = rec.popWaiter() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@intFromPtr(&t0), @intFromPtr(first.sync));
    removeSyncCondTicketLocked(&rec, &t1);
    try std.testing.expect(t1.canceled);
    const second = rec.popWaiter() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@intFromPtr(&t2), @intFromPtr(second.sync));
    try std.testing.expectEqual(@as(?CondEntry, null), rec.popWaiter());
    try std.testing.expectEqual(@as(usize, 0), rec.queue_head);
    try std.testing.expectEqual(@as(usize, 0), rec.queue.items.len);
}

test "condition queue reserves capacity chunks" {
    var rec = CondRecord{ .gil = undefined };
    const a = std.testing.allocator;
    defer rec.queue.deinit(a);

    var first = SyncCondTicket{};
    try rec.appendWaiter(a, .{ .sync = &first });
    try std.testing.expect(rec.queue.capacity >= condition_queue_reserve_granularity);

    const first_capacity = rec.queue.capacity;
    var tickets = try a.alloc(SyncCondTicket, first_capacity + 1);
    defer a.free(tickets);
    @memset(tickets, .{});

    var appended: usize = 0;
    while (rec.queue.items.len < first_capacity) : (appended += 1) {
        try rec.appendWaiter(a, .{ .sync = &tickets[appended] });
    }
    try std.testing.expectEqual(first_capacity, rec.queue.capacity);

    try rec.appendWaiter(a, .{ .sync = &tickets[appended] });
    try std.testing.expect(rec.queue.capacity > first_capacity);

    while (rec.popWaiter()) |_| {}
    try std.testing.expectEqual(@as(usize, 0), rec.queue_head);
    try std.testing.expectEqual(@as(usize, 0), rec.queue.items.len);
}

test "condition queue growth is trace-sensitive" {
    var probe = TraceSensitiveAllocProbe{ .inner = std.testing.allocator };
    const a = probe.allocator();
    var rec = CondRecord{ .gil = undefined };
    defer rec.queue.deinit(a);

    var ticket = SyncCondTicket{};
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    try rec.appendWaiter(a, .{ .sync = &ticket });
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
}

test "sync condition ticket allocation is trace-sensitive" {
    var probe = TraceSensitiveAllocProbe{ .inner = std.testing.allocator };
    const a = probe.allocator();

    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    const ticket = try createSyncCondTicketTraceSensitive(a);
    defer a.destroy(ticket);
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
}

test "condition queue compacts consumed head before growing" {
    resetContentionStats();
    defer disableContentionStats();

    var rec = CondRecord{ .gil = undefined };
    const a = std.testing.allocator;
    defer rec.queue.deinit(a);

    var tickets = try a.alloc(SyncCondTicket, condition_queue_reserve_granularity * 2 + 1);
    defer a.free(tickets);
    @memset(tickets, .{});

    var i: usize = 0;
    while (i < condition_queue_reserve_granularity * 2) : (i += 1) {
        try rec.appendWaiter(a, .{ .sync = &tickets[i] });
    }
    const full_capacity = rec.queue.capacity;
    try std.testing.expectEqual(full_capacity, rec.queue.items.len);
    var stats = contentionStats();
    try std.testing.expect(stats.condition_queue_grows > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.condition_queue_compactions);
    const grows_before_compaction = stats.condition_queue_grows;

    i = 0;
    while (i < condition_queue_reserve_granularity) : (i += 1) {
        _ = rec.popWaiter() orelse return error.TestExpectedEqual;
    }
    try std.testing.expectEqual(condition_queue_reserve_granularity, rec.queue_head);

    try rec.appendWaiter(a, .{ .sync = &tickets[condition_queue_reserve_granularity * 2] });
    try std.testing.expectEqual(full_capacity, rec.queue.capacity);
    try std.testing.expectEqual(@as(usize, 0), rec.queue_head);
    try std.testing.expectEqual(condition_queue_reserve_granularity + 1, rec.queue.items.len);
    try std.testing.expectEqual(@intFromPtr(&tickets[condition_queue_reserve_granularity]), @intFromPtr(rec.queue.items[0].sync));
    try std.testing.expectEqual(@intFromPtr(&tickets[condition_queue_reserve_granularity * 2]), @intFromPtr(rec.queue.items[condition_queue_reserve_granularity].sync));
    stats = contentionStats();
    try std.testing.expectEqual(grows_before_compaction, stats.condition_queue_grows);
    try std.testing.expectEqual(@as(u64, 1), stats.condition_queue_compactions);
}

test "condition sync handoff countdown tracks acknowledged tickets" {
    var rec = CondRecord{ .gil = undefined, .sync_handoff_pending = 2 };
    var t0 = SyncCondTicket{};
    var t1 = SyncCondTicket{};

    ackSyncCondTicketLocked(&rec, &t0);
    try std.testing.expect(t0.consumed);
    try std.testing.expectEqual(@as(usize, 1), rec.sync_handoff_pending);

    ackSyncCondTicketLocked(&rec, &t1);
    try std.testing.expect(t1.consumed);
    try std.testing.expectEqual(@as(usize, 0), rec.sync_handoff_pending);

    ackSyncCondTicketLocked(&rec, &t1);
    try std.testing.expectEqual(@as(usize, 0), rec.sync_handoff_pending);
}

const TLRecord = struct {
    brand: SyncBrand = sync_brand_thread_local,
    gil: *gil_mod.Gil,
    arena: std.mem.Allocator,
    owner: ?*value.Object = null,
    map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
    // Each thread keys `map` by its own tid, but they share the table: a peer's
    // `put` (which can rehash/grow) races another thread's `get`/`put` under
    // `parallel_js`. Always-lock (ThreadLocal is a niche API — uncontended in the
    // single-thread case), no gating needed.
    map_lock: std.atomic.Mutex = .unlocked,
    fn lockMap(self: *TLRecord) void {
        var spins: usize = 0;
        while (!self.map_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        gc_runtime.enterTraceSensitiveLock();
    }
    fn unlockMap(self: *TLRecord) void {
        gc_runtime.leaveTraceSensitiveLock();
        self.map_lock.unlock();
    }
};

test "ThreadLocal map lock is trace-sensitive" {
    var rec = TLRecord{ .gil = undefined, .arena = std.testing.allocator };

    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    rec.lockMap();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
    rec.unlockMap();
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
}

fn rememberThreadLocalForCurrentThread(rec: *TLRecord) !void {
    const thread_rec = t_current orelse return;
    if (thread_rec.id == 0) return;
    for (thread_rec.touched_thread_locals.items) |seen| {
        if (seen == rec) return;
    }
    try thread_rec.touched_thread_locals.append(thread_rec.ctx.arena(), rec);
}

fn clearThreadLocalValuesForCurrentThread(thread_rec: *ThreadRecord) void {
    if (thread_rec.touched_thread_locals.items.len == 0) return;
    const tid = currentTid();
    for (thread_rec.touched_thread_locals.items) |rec| {
        rec.lockMap();
        _ = rec.map.remove(tid);
        rec.unlockMap();
    }
    thread_rec.touched_thread_locals.clearRetainingCapacity();
}

const UnlockTokenRecord = struct {
    brand: SyncBrand = sync_brand_unlock_token,
    lock: ?*LockRecord = null,
};

inline fn traceThreadValue(v: anytype, val: Value) void {
    gc_mod.markValue(v, val);
}

fn traceHoldJob(job: *HoldJob, v: anytype) void {
    v.mark(job.lock.owner);
    v.mark(job.outer);
    if (job.cb) |cb| traceThreadValue(v, cb);
}

pub fn traceHoldJobRoot(raw: *anyopaque, v: anytype) void {
    const job: *HoldJob = @ptrCast(@alignCast(raw));
    traceHoldJob(job, v);
}

pub fn relocateHoldJobRoot(raw: *anyopaque, v: anytype) void {
    const job: *HoldJob = @ptrCast(@alignCast(raw));
    relocateHoldJob(job, v);
}

fn barrierHoldJob(job: *HoldJob) void {
    const owner: ?*anyopaque = if (job.lock.owner) |o| @ptrCast(o) else null;
    gc_mod.barrierCellFrom(owner, @ptrCast(job.outer));
    if (job.cb) |cb| gc_mod.barrierValueFrom(owner, cb);
}

fn traceLockRecordRoots(rec: *LockRecord, v: anytype) void {
    rec.mutex.lockUncancelable(agent.engineIo());
    defer rec.mutex.unlock(agent.engineIo());
    for (rec.pending_front.items) |job| traceHoldJob(job, v);
    for (rec.pending.items[rec.pending_head..]) |job| traceHoldJob(job, v);
}

fn traceCondRecordRoots(rec: *CondRecord, v: anytype) void {
    rec.mutex.lockUncancelable(agent.engineIo());
    defer rec.mutex.unlock(agent.engineIo());
    for (rec.queue.items[rec.queue_head..]) |entry| switch (entry) {
        .sync => {},
        .asynchronous => |w| {
            v.mark(w.lock.owner);
            v.mark(w.outer);
        },
    };
}

fn traceThreadLocalRoots(rec: *TLRecord, v: anytype) void {
    rec.lockMap();
    defer rec.unlockMap();
    var it = rec.map.valueIterator();
    while (it.next()) |val| traceThreadValue(v, val.*);
}

/// Trace JS roots hidden behind native `private_data` records owned by this
/// module. `gc.zig` calls this from the Object tracer after the object itself is
/// marked; this covers host-side queues that are not ordinary JS properties.
pub fn traceNativePrivateData(o: *value.Object, v: anytype) void {
    const pd = o.private_data orelse return;
    switch (o.private_data_tag) {
        .jsthread_lock => traceLockRecordRoots(@ptrCast(@alignCast(pd)), v),
        .jsthread_condition => traceCondRecordRoots(@ptrCast(@alignCast(pd)), v),
        .jsthread_thread_local => traceThreadLocalRoots(@ptrCast(@alignCast(pd)), v),
        .jsthread_release_state => {
            const st: *ReleaseState = @ptrCast(@alignCast(pd));
            v.mark(st.lock.owner);
            traceLockRecordRoots(st.lock, v);
        },
        .jsthread_thread, .jsthread_unlock_token, .abort_signal, .form_data_native_blob, .fetch_headers, .host, .none => {},
    }
}

fn relocateHoldJob(job: *HoldJob, v: anytype) void {
    gc_relocation.rewriteOptionalSlot(v, value.Object, &job.lock.owner);
    gc_relocation.rewriteRequiredSlot(v, value.Object, &job.outer);
    gc_relocation.rewriteOptionalValueSlot(v, &job.cb);
}

fn relocateLockRecordRoots(record: *LockRecord, v: anytype) void {
    gc_relocation.rewriteOptionalSlot(v, value.Object, &record.owner);
    for (record.pending_front.items) |job| relocateHoldJob(job, v);
    for (record.pending.items[record.pending_head..]) |job| relocateHoldJob(job, v);
}

fn relocateCondRecordRoots(record: *CondRecord, v: anytype) void {
    gc_relocation.rewriteOptionalSlot(v, value.Object, &record.owner);
    for (record.queue.items[record.queue_head..]) |entry| switch (entry) {
        .sync => {},
        .asynchronous => |waiter| {
            gc_relocation.rewriteOptionalSlot(v, value.Object, &waiter.lock.owner);
            gc_relocation.rewriteRequiredSlot(v, value.Object, &waiter.outer);
        },
    };
}

fn relocateThreadLocalRoots(record: *TLRecord, v: anytype) void {
    gc_relocation.rewriteOptionalSlot(v, value.Object, &record.owner);
    var it = record.map.valueIterator();
    while (it.next()) |slot| gc_relocation.rewriteValueSlot(v, slot);
}

pub fn relocateNativePrivateData(o: *value.Object, v: anytype) void {
    const pd = o.private_data orelse return;
    switch (o.private_data_tag) {
        .jsthread_lock => relocateLockRecordRoots(@ptrCast(@alignCast(pd)), v),
        .jsthread_condition => relocateCondRecordRoots(@ptrCast(@alignCast(pd)), v),
        .jsthread_thread_local => relocateThreadLocalRoots(@ptrCast(@alignCast(pd)), v),
        .jsthread_release_state => {
            const state: *ReleaseState = @ptrCast(@alignCast(pd));
            relocateLockRecordRoots(state.lock, v);
        },
        .jsthread_thread, .jsthread_unlock_token, .abort_signal, .form_data_native_blob, .fetch_headers, .host, .none => {},
    }
}

test "jsthread native private relocation mirrors every traced payload" {
    var old_objects: [9]value.Object = undefined;
    var new_objects: [9]value.Object = undefined;
    var lock = LockRecord{ .gil = undefined, .owner = &old_objects[0] };
    var hold = HoldJob{
        .lock = &lock,
        .outer = &old_objects[1],
        .cb = Value.obj(&old_objects[2]),
        .release_state = .{ .lock = &lock },
    };
    var pending = [_]*HoldJob{&hold};
    lock.pending = .{ .items = &pending, .capacity = pending.len };

    var waiter_lock = LockRecord{ .gil = undefined, .owner = &old_objects[4] };
    var waiter = AsyncCondWaiter{ .lock = &waiter_lock, .outer = &old_objects[5] };
    var queue = [_]CondEntry{.{ .asynchronous = &waiter }};
    var condition = CondRecord{
        .gil = undefined,
        .owner = &old_objects[3],
        .queue = .{ .items = &queue, .capacity = queue.len },
    };

    var thread_local = TLRecord{
        .gil = undefined,
        .arena = std.testing.allocator,
        .owner = &old_objects[6],
    };
    defer thread_local.map.deinit(std.testing.allocator);
    try thread_local.map.put(std.testing.allocator, 7, Value.obj(&old_objects[7]));
    var release_lock = LockRecord{ .gil = undefined, .owner = &old_objects[8] };
    var release = ReleaseState{ .lock = &release_lock };

    var lock_object = value.Object{ .private_data = &lock, .private_data_tag = .jsthread_lock };
    var condition_object = value.Object{ .private_data = &condition, .private_data_tag = .jsthread_condition };
    var local_object = value.Object{ .private_data = &thread_local, .private_data_tag = .jsthread_thread_local };
    var release_object = value.Object{ .private_data = &release, .private_data_tag = .jsthread_release_state };

    const Plan = struct {
        old_objects: *[9]value.Object,
        new_objects: *[9]value.Object,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            return old;
        }
    };
    const plan = Plan{ .old_objects = &old_objects, .new_objects = &new_objects };
    relocateNativePrivateData(&lock_object, &plan);
    relocateNativePrivateData(&condition_object, &plan);
    relocateNativePrivateData(&local_object, &plan);
    relocateNativePrivateData(&release_object, &plan);

    try std.testing.expectEqual(&new_objects[0], lock.owner.?);
    try std.testing.expectEqual(&new_objects[1], hold.outer);
    try std.testing.expectEqual(&new_objects[2], hold.cb.?.asObj());
    try std.testing.expectEqual(&new_objects[3], condition.owner.?);
    try std.testing.expectEqual(&new_objects[4], waiter_lock.owner.?);
    try std.testing.expectEqual(&new_objects[5], waiter.outer);
    try std.testing.expectEqual(&new_objects[6], thread_local.owner.?);
    try std.testing.expectEqual(&new_objects[7], thread_local.map.get(7).?.asObj());
    try std.testing.expectEqual(&new_objects[8], release_lock.owner.?);
}

test "jsthread private-data tracer ignores unowned opaque data" {
    const FakePrivateData = struct {
        brand: SyncBrand = sync_brand_lock,
    };
    const Visitor = struct {
        marks: usize = 0,

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            _ = cell;
            self.marks += 1;
        }
    };

    var fake = FakePrivateData{};
    var obj = value.Object{ .private_data = &fake };
    var visitor = Visitor{};
    traceNativePrivateData(&obj, &visitor);
    try std.testing.expectEqual(@as(usize, 0), visitor.marks);
}

/// Trace the realm run-loop task queue (`Gil.tasks`). Entries are pending
/// `HoldJob`s for `Lock.asyncHold` / async condition reacquire delivery; if a
/// mid-script GC runs while sync waiters pump this queue, the callback and outer
/// promise must stay live until the task executes.
pub fn traceGilTaskRoots(g: *gil_mod.Gil, v: anytype) void {
    g.lockApi();
    defer g.unlockApi();
    if (g.tasks_head >= g.tasks.items.len) return;
    for (g.tasks.items[g.tasks_head..]) |raw| {
        const job: *HoldJob = @ptrCast(@alignCast(raw));
        traceHoldJob(job, v);
    }
}

/// World-stopped companion to `traceGilTaskRoots`. The task queue and its
/// arena-owned job records stay in place; only their managed payloads move.
pub fn relocateGilTaskRoots(g: *gil_mod.Gil, v: anytype) void {
    if (g.tasks_head >= g.tasks.items.len) return;
    for (g.tasks.items[g.tasks_head..]) |raw| {
        const job: *HoldJob = @ptrCast(@alignCast(raw));
        relocateHoldJob(job, v);
    }
}

/// Rewrite the Context-owned completion and async-join roots for one stable
/// ThreadRecord. Its OS-thread, queue, mutex, and owner pointers are native
/// metadata and deliberately remain unchanged.
pub fn relocateThreadRecordRoots(record: *ThreadRecord, v: anytype) void {
    gc_relocation.rewriteValueSlot(v, &record.result);
    gc_relocation.rewriteOptionalSlot(v, value.Object, &record.js_obj);
    for (record.pending_joins.items) |*pending|
        gc_relocation.rewriteRequiredSlot(v, value.Object, &pending.promise);
    for (record.settling_joins.items) |*pending|
        gc_relocation.rewriteRequiredSlot(v, value.Object, &pending.promise);
}

/// Rewrite the managed fields in a type-erased property waitAsync ticket.
/// The ticket and its captured native queue/thread ownership stay stable.
pub fn relocatePropAsyncTicketRoot(raw: *anyopaque, v: anytype) void {
    const ticket: *PropAsyncTicket = @ptrCast(@alignCast(raw));
    gc_relocation.rewriteRequiredSlot(v, value.Object, &ticket.obj);
    gc_relocation.rewriteRequiredSlot(v, value.Object, &ticket.promise);
}

test "realm root relocation rewrites GIL tasks thread records and property waiters" {
    var old_objects: [9]value.Object = undefined;
    var new_objects: [9]value.Object = undefined;
    var g = gil_mod.Gil{};

    var lock = LockRecord{ .gil = &g, .owner = &old_objects[0] };
    var job = HoldJob{
        .lock = &lock,
        .outer = &old_objects[1],
        .cb = Value.obj(&old_objects[2]),
        .release_state = .{ .lock = &lock },
    };
    var task_items = [_]*anyopaque{@ptrCast(&job)};
    g.tasks = .{ .items = &task_items, .capacity = task_items.len };

    var queue = promise.MicrotaskQueue{};
    var pending_joins = [_]PendingJoin{.{ .promise = &old_objects[5], .microtasks = &queue }};
    var settling_joins = [_]PendingJoin{.{ .promise = &old_objects[6], .microtasks = &queue }};
    var record = ThreadRecord{
        .id = 7,
        .gil = &g,
        .ctx = undefined,
        .result = Value.obj(&old_objects[3]),
        .js_obj = &old_objects[4],
        .pending_joins = .{ .items = &pending_joins, .capacity = pending_joins.len },
        .settling_joins = .{ .items = &settling_joins, .capacity = settling_joins.len },
    };
    var ticket = PropAsyncTicket{
        .obj = &old_objects[7],
        .key = "root",
        .deadline_ns = null,
        .promise = &old_objects[8],
        .microtasks = &queue,
        .thread = &record,
        .owner = &g,
    };

    const Plan = struct {
        old_objects: *[9]value.Object,
        new_objects: *[9]value.Object,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            return old;
        }
    };
    const plan = Plan{ .old_objects = &old_objects, .new_objects = &new_objects };
    relocateGilTaskRoots(&g, &plan);
    relocateThreadRecordRoots(&record, &plan);
    relocatePropAsyncTicketRoot(&ticket, &plan);

    try std.testing.expectEqual(&new_objects[0], lock.owner.?);
    try std.testing.expectEqual(&new_objects[1], job.outer);
    try std.testing.expectEqual(&new_objects[2], job.cb.?.asObj());
    try std.testing.expectEqual(&new_objects[3], record.result.asObj());
    try std.testing.expectEqual(&new_objects[4], record.js_obj.?);
    try std.testing.expectEqual(&new_objects[5], record.pending_joins.items[0].promise);
    try std.testing.expectEqual(&new_objects[6], record.settling_joins.items[0].promise);
    try std.testing.expectEqual(&new_objects[7], ticket.obj);
    try std.testing.expectEqual(&new_objects[8], ticket.promise);
}

fn currentTid() u64 {
    return @intCast(std.Thread.getCurrentId());
}

/// Install Lock/Condition/ThreadLocal alongside Thread (same Context).
fn installSyncAPI(ctx: *Context) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;

    const lock_proto = try gc_mod.allocObj(a);
    lock_proto.* = .{};
    try interp.setNative(a, rs, lock_proto, "hold", 1, lockHoldFn);
    try interp.setNative(a, rs, lock_proto, "asyncHold", 1, lockAsyncHoldFn);
    try interp.setNativeGetter(a, rs, lock_proto, "locked", lockLockedGetter);
    try setTag(ctx, lock_proto, "Lock");
    const lock_ctor = try installCtor(ctx, "Lock", lockCtorFn, lock_proto);

    const cond_proto = try gc_mod.allocObj(a);
    cond_proto.* = .{};
    try interp.setNative(a, rs, cond_proto, "wait", 1, condWaitFn);
    try interp.setNative(a, rs, cond_proto, "notify", 0, condNotifyFn(false));
    try interp.setNative(a, rs, cond_proto, "notifyAll", 0, condNotifyFn(true));
    try interp.setNative(a, rs, cond_proto, "asyncWait", 1, condAsyncWaitFn);
    try setTag(ctx, cond_proto, "Condition");
    const cond_ctor = try installCtor(ctx, "Condition", condCtorFn, cond_proto);

    const tl_proto = try gc_mod.allocObj(a);
    tl_proto.* = .{};
    const getter = try gc_mod.allocObj(a);
    getter.* = .{ .native = tlValueGetFn };
    const setter = try gc_mod.allocObj(a);
    setter.* = .{ .native = tlValueSetFn };
    try tl_proto.setAccessor(a, "value", Value.obj(getter), Value.obj(setter));
    try tl_proto.setAttr(a, "value", .{ .enumerable = false, .configurable = true });
    try setTag(ctx, tl_proto, "ThreadLocal");
    _ = try installCtor(ctx, "ThreadLocal", tlCtorFn, tl_proto);

    // Phase 8 sync-primitive alignment: the current TC39 proposal names these
    // Atomics.Mutex/Atomics.Condition. They reuse our shipped Lock/Condition
    // records while exposing the draft's token-oriented static methods.
    try installMutexStaticAPI(ctx, lock_ctor);
    try installConditionStaticAPI(ctx, cond_ctor);
    if (ctx.env.get("Atomics")) |atomics_v| if (atomics_v.isObject()) {
        try atomics_v.asObj().setOwn(a, rs, "Mutex", Value.obj(lock_ctor));
        try atomics_v.asObj().setAttr(a, "Mutex", .{ .writable = true, .enumerable = false, .configurable = true });
        try atomics_v.asObj().setOwn(a, rs, "Condition", Value.obj(cond_ctor));
        try atomics_v.asObj().setAttr(a, "Condition", .{ .writable = true, .enumerable = false, .configurable = true });
    };
}

/// `Symbol.toStringTag` on a prototype (the corpus checks "[object Lock]").
fn setTag(ctx: *Context, proto: *value.Object, name: []const u8) !void {
    var machine = ctx.interpreter();
    const k = machine.wellKnownSymbolKey("toStringTag") orelse return;
    const a = ctx.arena();
    try proto.setOwn(a, ctx.root_shape, k, try Value.strAlloc(a, name));
    try proto.setAttr(a, k, .{ .writable = false, .enumerable = false, .configurable = true });
}

fn installCtor(ctx: *Context, name: []const u8, f: value.NativeFn, proto: *value.Object) !*value.Object {
    const a = ctx.arena();
    const rs = ctx.root_shape;
    const ctor = try gc_mod.allocObj(a);
    ctor.* = .{ .native = f, .native_ctor = true, .private_data = ctx };
    try ctor.setOwn(a, rs, "prototype", Value.obj(proto));
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try interp.setConstructor(a, rs, proto, ctor);
    try ctx.env.put(name, Value.obj(ctor));
    try ctx.global_object.setOwn(a, rs, name, Value.obj(ctor));
    try ctx.global_object.setAttr(a, name, .{ .writable = true, .enumerable = false, .configurable = true });
    return ctor;
}

fn installMutexStaticAPI(ctx: *Context, lock_ctor: *value.Object) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;

    const token_proto = try gc_mod.allocObj(a);
    token_proto.* = .{};
    try interp.setNativeGetter(a, rs, token_proto, "locked", unlockTokenLockedGetter);
    try interp.setNative(a, rs, token_proto, "unlock", 0, unlockTokenUnlockFn);
    var machine = ctx.interpreter();
    if (machine.wellKnownSymbolKey("dispose")) |dispose_key|
        try interp.setNative(a, rs, token_proto, dispose_key, 0, unlockTokenDisposeFn);
    try setTag(ctx, token_proto, "Atomics.Mutex.UnlockToken");

    const token_ctor = try gc_mod.allocObj(a);
    token_ctor.* = .{ .native = unlockTokenCtorFn, .native_ctor = true, .private_data = ctx };
    try interp.installNativeProps(a, rs, token_ctor, "UnlockToken", 0);
    try token_ctor.setOwn(a, rs, "prototype", Value.obj(token_proto));
    try token_ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try interp.setConstructor(a, rs, token_proto, token_ctor);

    try lock_ctor.setOwn(a, rs, "UnlockToken", Value.obj(token_ctor));
    try lock_ctor.setAttr(a, "UnlockToken", .{ .writable = true, .enumerable = false, .configurable = true });
    try interp.setNative(a, rs, lock_ctor, "lock", 1, mutexStaticLockFn);
    try interp.setNative(a, rs, lock_ctor, "lockIfAvailable", 2, mutexStaticLockIfAvailableFn);
}

fn installConditionStaticAPI(ctx: *Context, cond_ctor: *value.Object) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;
    try interp.setNative(a, rs, cond_ctor, "wait", 2, conditionStaticWaitFn);
    try interp.setNative(a, rs, cond_ctor, "waitFor", 3, conditionStaticWaitForFn);
    try interp.setNative(a, rs, cond_ctor, "notify", 1, conditionStaticNotifyFn);
}

/// Shared ctor shape: a fresh instance whose private_data is a record of `T`.
fn syncCtor(comptime T: type, comptime ctor_name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = this;
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
            if (self.new_target.isUndefined()) return self.throwError("TypeError", "calling " ++ ctor_name ++ " constructor without new is invalid");
            const native = self.active_native orelse return self.throwError("TypeError", "constructor lost its context");
            const ctx: *Context = @ptrCast(@alignCast(native.private_data.?));
            const g = ctx.gil orelse return self.throwError("TypeError", "requires an enable_threads Context");
            const a = ctx.arena();
            const rec = try a.create(T);
            rec.* = if (T == TLRecord) .{ .gil = g, .arena = a } else .{ .gil = g };
            const o = try gc_mod.allocObj(a);
            o.* = .{ .private_data = rec, .private_data_tag = privateDataTagOf(T) };
            rec.owner = o;
            const p = try self.getProperty(Value.obj(native), "prototype");
            if (p.isObject()) o.proto = p.asObj();
            return Value.obj(o);
        }
    }.call;
}

const lockCtorFn = syncCtor(LockRecord, "Lock");
const condCtorFn = syncCtor(CondRecord, "Condition");
const tlCtorFn = syncCtor(TLRecord, "ThreadLocal");

fn brandOf(comptime T: type) SyncBrand {
    if (T == LockRecord) return sync_brand_lock;
    if (T == CondRecord) return sync_brand_condition;
    if (T == TLRecord) return sync_brand_thread_local;
    if (T == UnlockTokenRecord) return sync_brand_unlock_token;
    @compileError("unknown sync record type");
}

fn privateDataTagOf(comptime T: type) value.ObjectPrivateDataTag {
    if (T == LockRecord) return .jsthread_lock;
    if (T == CondRecord) return .jsthread_condition;
    if (T == TLRecord) return .jsthread_thread_local;
    if (T == UnlockTokenRecord) return .jsthread_unlock_token;
    @compileError("unknown sync record type");
}

fn recOf(comptime T: type, this: Value) ?*T {
    if (!this.isObject()) return null;
    const obj = this.asObj();
    if (obj.private_data_tag != privateDataTagOf(T)) return null;
    const pd = obj.private_data orelse return null;
    const tag: *SyncBrand = @ptrCast(@alignCast(pd));
    if (tag.* != brandOf(T)) return null;
    return @ptrCast(@alignCast(pd));
}

const AcquireResult = enum { acquired, timed_out };

fn timeoutMillisToNs(ms: f64) value.HostError!?u64 {
    if (std.math.isNan(ms) or ms == std.math.inf(f64)) return null;
    if (ms <= 0 or ms == -std.math.inf(f64)) return 0;
    const max_ms: f64 = @floatFromInt(std.math.maxInt(u64) / std.time.ns_per_ms);
    const clamped = @min(ms, max_ms);
    return @intFromFloat(@ceil(clamped * std.time.ns_per_ms));
}

fn waitOnLockCond(self: *Interpreter, rec: *LockRecord, timeout: std.Io.Timeout) void {
    const io = agent.engineIo();
    if (self.use_thread_gil) {
        const g = rec.gil;
        stack_scan.beginPark();
        g.release();
        io_compat.conditionWaitTimeout(&rec.cond, io, &rec.mutex, timeout) catch {};
        rec.mutex.unlock(io);
        g.acquire();
        stack_scan.endPark();
        rec.mutex.lockUncancelable(io);
    } else {
        io_compat.conditionWaitTimeout(&rec.cond, io, &rec.mutex, timeout) catch {};
    }
}

fn acquireLock(self: *Interpreter, rec: *LockRecord, timeout_ns: ?u64, err_name: []const u8) value.HostError!AcquireResult {
    const io = agent.engineIo();
    rec.mutex.lockUncancelable(io);
    defer rec.mutex.unlock(io);

    if (rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid())) {
        if (timeout_ns != null and timeout_ns.? == 0) return .timed_out;
        return self.throwError("TypeError", err_name);
    }
    if (rec.locked or rec.sync_waiting > 0) {
        if (timeout_ns != null and timeout_ns.? == 0) return .timed_out;
        if (!self.main_can_block)
            return self.throwError("TypeError", err_name);
        bumpContention("lock_contentions");
        const deadline_ns: ?i96 = if (timeout_ns) |ns|
            std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds + ns
        else
            null;
        const my_generation = rec.sync_generation;
        rec.sync_waiting += 1;
        errdefer rec.sync_waiting -= 1;
        while (rec.locked or rec.sync_generation == my_generation) {
            if (deadline_ns) |d| {
                const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
                if (d <= now) {
                    rec.sync_waiting -= 1;
                    return .timed_out;
                }
            }
            const tick_ns: u64 = if (deadline_ns) |d| blk: {
                const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
                if (d <= now) {
                    rec.sync_waiting -= 1;
                    return .timed_out;
                }
                break :blk @min(@as(u64, @intCast(d - now)), 5 * std.time.ns_per_ms);
            } else 5 * std.time.ns_per_ms;
            rec.mutex.unlock(io);
            // No waiter/lock state is held here. Under the experimental
            // parallel mid-script collector, service any root-publication
            // request before this waiter re-enters its bounded native park.
            self.serviceGcSafepoint();
            pumpTasks(self);
            const stopped = if (self.stop_flag) |sf| sf.load(.monotonic) else false;
            rec.mutex.lockUncancelable(io);
            if (stopped)
                return self.throwError("Error", "worker terminated");
            if (!rec.locked and rec.sync_generation != my_generation) break;
            bumpContention("lock_wait_parks");
            const wait_start = startContentionWaitTimer();
            waitOnLockCond(self, rec, .{ .duration = .{
                .raw = .fromNanoseconds(tick_ns),
                .clock = .awake,
            } });
            finishContentionWaitTimer("lock_wait_ns", wait_start);
        }
        rec.sync_waiting -= 1;
    }
    rec.locked = true;
    rec.holder = currentTid();
    return .acquired;
}

fn unlockTokenCreate(self: *Interpreter, token_v: Value, lock: *LockRecord) value.HostError!Value {
    const token = if (token_v.isUndefined()) blk: {
        const rec = try self.arena.create(UnlockTokenRecord);
        rec.* = .{};
        const obj = try gc_mod.allocObj(self.arena);
        obj.* = .{ .private_data = rec, .private_data_tag = .jsthread_unlock_token };
        if (self.env.get("Atomics")) |atomics_v| if (atomics_v.isObject()) {
            const mutex_v = try self.getProperty(Value.obj(atomics_v.asObj()), "Mutex");
            if (mutex_v.isObject()) {
                const token_ctor_v = try self.getProperty(mutex_v, "UnlockToken");
                if (token_ctor_v.isObject()) {
                    const proto_v = try self.getProperty(token_ctor_v, "prototype");
                    if (proto_v.isObject()) obj.proto = proto_v.asObj();
                }
            }
        };
        break :blk obj;
    } else blk: {
        const rec = recOf(UnlockTokenRecord, token_v) orelse
            return self.throwError("TypeError", "Atomics.Mutex expected an UnlockToken");
        if (rec.lock != null)
            return self.throwError("TypeError", "Atomics.Mutex UnlockToken is already locked");
        break :blk token_v.asObj();
    };
    const rec = recOf(UnlockTokenRecord, Value.obj(token)).?;
    rec.lock = lock;
    return Value.obj(token);
}

fn unlockTokenCtorFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    if (self.new_target.isUndefined())
        return self.throwError("TypeError", "calling Atomics.Mutex.UnlockToken constructor without new is invalid");
    const native = self.active_native orelse return self.throwError("TypeError", "UnlockToken constructor lost its context");
    const ctx: *Context = @ptrCast(@alignCast(native.private_data.?));
    const rec = try ctx.arena().create(UnlockTokenRecord);
    rec.* = .{};
    const obj = try gc_mod.allocObj(ctx.arena());
    obj.* = .{ .private_data = rec, .private_data_tag = .jsthread_unlock_token };
    const proto = try self.getProperty(Value.obj(native), "prototype");
    if (proto.isObject()) obj.proto = proto.asObj();
    return Value.obj(obj);
}

fn unlockTokenLockedGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(UnlockTokenRecord, this) orelse
        return self.throwError("TypeError", "Atomics.Mutex.UnlockToken.prototype.locked called on incompatible receiver");
    return Value.boolVal(rec.lock != null);
}

fn unlockTokenUnlock(self: *Interpreter, rec: *UnlockTokenRecord) value.HostError!bool {
    const lock = rec.lock orelse return false;
    var job_to_enqueue: ?*HoldJob = null;
    lock.mutex.lockUncancelable(agent.engineIo());
    if (!lock.locked or lock.holder != currentTid()) {
        lock.mutex.unlock(agent.engineIo());
        return self.throwError("TypeError", "Atomics.Mutex.UnlockToken does not own the mutex");
    }
    rec.lock = null;
    job_to_enqueue = lockReleaseLocked(lock);
    lock.mutex.unlock(agent.engineIo());
    if (job_to_enqueue) |job| enqueueHoldJob(self, job) catch {};
    return true;
}

fn unlockTokenUnlockFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(UnlockTokenRecord, this) orelse
        return self.throwError("TypeError", "Atomics.Mutex.UnlockToken.prototype.unlock called on incompatible receiver");
    return Value.boolVal(try unlockTokenUnlock(self, rec));
}

fn unlockTokenDisposeFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(UnlockTokenRecord, this) orelse
        return self.throwError("TypeError", "Atomics.Mutex.UnlockToken.prototype[Symbol.dispose] called on incompatible receiver");
    _ = try unlockTokenUnlock(self, rec);
    return Value.undef();
}

fn mutexStaticLockFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Atomics.Mutex.lock requires a Mutex argument");
    _ = try acquireLock(self, rec, null, "Atomics.Mutex.lock cannot acquire the mutex");
    return unlockTokenCreate(self, if (args.len > 1) args[1] else Value.undef(), rec) catch |err| {
        lockReleaseIfHeldByCurrent(self, rec);
        return err;
    };
}

fn mutexStaticLockIfAvailableFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Atomics.Mutex.lockIfAvailable requires a Mutex argument");
    const timeout_v = if (args.len > 1) args[1] else Value.undef();
    if (timeout_v.isUndefined())
        return self.throwError("TypeError", "Atomics.Mutex.lockIfAvailable requires a timeout");
    const timeout_ns = try timeoutMillisToNs(try self.toNumberV(timeout_v));
    switch (try acquireLock(self, rec, timeout_ns, "Atomics.Mutex.lockIfAvailable cannot acquire the mutex")) {
        .acquired => return unlockTokenCreate(self, if (args.len > 2) args[2] else Value.undef(), rec) catch |err| {
            lockReleaseIfHeldByCurrent(self, rec);
            return err;
        },
        .timed_out => return Value.nul(),
    }
}

/// `Lock.prototype.hold(fn)` — acquire (parking GIL-released while
/// contended), run fn, release even when fn throws.
fn lockHoldFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.hold called on incompatible receiver");
    const cb = if (args.len > 0) args[0] else Value.undef();
    if (!cb.isCallable()) return self.throwError("TypeError", "Lock.prototype.hold requires a callable argument");
    const root_mark = try self.pushTempRoot(this);
    defer self.restoreTempRoots(root_mark);
    _ = try self.pushTempRoot(cb);
    rec.mutex.lockUncancelable(agent.engineIo());
    const recursive = rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid());
    rec.mutex.unlock(agent.engineIo());
    if (recursive) return self.throwError("Error", "Lock is not recursive");
    _ = try acquireLock(self, rec, null, "Lock.prototype.hold cannot block the current thread");
    const out = self.callValueWithThis(cb, &.{}, Value.undef());
    // Epilogue guard: a termination thrown from a cond.wait inside cb left
    // the lock unheld (D9) — releasing here would corrupt the lock state.
    lockReleaseIfHeldByCurrent(self, rec);
    return out;
}

fn lockLockedGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.locked called on incompatible receiver");
    rec.mutex.lockUncancelable(agent.engineIo());
    defer rec.mutex.unlock(agent.engineIo());
    return Value.boolVal(rec.locked);
}

fn removeSyncCondTicket(rec: *CondRecord, ticket: *SyncCondTicket) void {
    rec.mutex.lockUncancelable(agent.engineIo());
    defer rec.mutex.unlock(agent.engineIo());
    removeSyncCondTicketLocked(rec, ticket);
}

fn removeSyncCondTicketLocked(rec: *CondRecord, ticket: *SyncCondTicket) void {
    _ = rec;
    ticket.canceled = true;
}

fn ackSyncCondTicketLocked(rec: *CondRecord, ticket: *SyncCondTicket) void {
    ticket.consumed = true;
    if (rec.sync_handoff_pending > 0)
        rec.sync_handoff_pending -= 1;
}

fn waitOnCondRecord(self: *Interpreter, rec: *CondRecord, timeout: std.Io.Timeout) void {
    const io = agent.engineIo();
    if (self.use_thread_gil) {
        const g = rec.gil;
        stack_scan.beginPark();
        g.release();
        io_compat.conditionWaitTimeout(&rec.cond, io, &rec.mutex, timeout) catch {};
        rec.mutex.unlock(io);
        g.acquire();
        stack_scan.endPark();
        rec.mutex.lockUncancelable(io);
    } else {
        io_compat.conditionWaitTimeout(&rec.cond, io, &rec.mutex, timeout) catch {};
    }
}

fn condWaitCore(self: *Interpreter, rec: *CondRecord, lock: *LockRecord, timeout_ns: ?u64) value.HostError!bool {
    const io = agent.engineIo();
    bumpContention("condition_waits");
    rec.mutex.lockUncancelable(io);
    lock.mutex.lockUncancelable(io);
    const held_by_me = lock.locked and lock.holder == currentTid();
    if (!held_by_me) {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return self.throwError("TypeError", "Condition wait requires the lock to be held by the caller");
    }
    if ((timeout_ns == null or timeout_ns.? != 0) and !self.main_can_block) {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return self.throwError("TypeError", "Condition wait cannot block the current thread");
    }
    // Arena-allocated, NOT stack: the notifier's consume-loop reads the
    // ticket after this frame may have returned (a stack ticket dangles —
    // it read clobbered memory and spun forever).
    const ticket = createSyncCondTicketTraceSensitive(self.arena) catch |err| {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return err;
    };
    ticket.* = .{};
    rec.appendWaiter(self.arena, .{ .sync = ticket }) catch |err| {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return err;
    };
    const job_to_enqueue = lockReleaseLocked(lock);
    lock.mutex.unlock(io);
    rec.mutex.unlock(io);
    if (job_to_enqueue) |job| enqueueHoldJob(self, job) catch {};
    rec.mutex.lockUncancelable(io);
    const deadline_ns: ?i96 = if (timeout_ns) |ns|
        std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds + ns
    else
        null;
    // A termination observed here propagates WITHOUT reacquiring the lock
    // (the enclosing hold's epilogue guard skips its release — D9).
    while (!ticket.woken) {
        if (deadline_ns) |d| {
            const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
            if (d <= now) {
                removeSyncCondTicketLocked(rec, ticket);
                rec.mutex.unlock(io);
                switch (try acquireLock(self, lock, null, "Condition wait cannot reacquire the lock")) {
                    .acquired => return false,
                    .timed_out => unreachable,
                }
            }
        }
        rec.mutex.unlock(io);
        // Publish roots at the wait loop's lock-free pump point. The sync waiter
        // is not a frozen parked peer; it periodically runs tasks, so it must
        // cooperate with the parallel collector instead of being traced as
        // parked.
        self.serviceGcSafepoint();
        pumpTasks(self);
        const stopped = if (self.stop_flag) |sf| sf.load(.monotonic) else false;
        rec.mutex.lockUncancelable(io);
        if (stopped) {
            removeSyncCondTicketLocked(rec, ticket);
            rec.mutex.unlock(io);
            return self.throwError("Error", "worker terminated");
        }
        if (ticket.woken) break;
        var tick_ns: u64 = 5 * std.time.ns_per_ms;
        if (deadline_ns) |d| {
            const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
            if (d <= now) {
                removeSyncCondTicketLocked(rec, ticket);
                rec.mutex.unlock(io);
                switch (try acquireLock(self, lock, null, "Condition wait cannot reacquire the lock")) {
                    .acquired => return false,
                    .timed_out => unreachable,
                }
            }
            tick_ns = @min(tick_ns, @as(u64, @intCast(d - now)));
        }
        bumpContention("condition_wait_parks");
        const wait_start = startContentionWaitTimer();
        waitOnCondRecord(self, rec, .{ .duration = .{
            .raw = .fromNanoseconds(tick_ns),
            .clock = .awake,
        } });
        finishContentionWaitTimer("condition_wait_ns", wait_start);
    }
    // Re-register on the lock BEFORE acking the wake, so notifyAll's
    // consume-loop guarantees FIFO against async regrants.
    ackSyncCondTicketLocked(rec, ticket);
    rec.cond.signal(io);
    rec.mutex.unlock(io);
    switch (try acquireLock(self, lock, null, "Condition wait cannot reacquire the lock")) {
        .acquired => return true,
        .timed_out => unreachable,
    }
}

/// `Condition.prototype.wait(lock)` — atomically release the lock and park;
/// reacquire before returning. Spurious wakeups are permitted by spec, so
/// callers loop on their predicate.
fn condWaitFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.wait called on incompatible receiver");
    const lock = recOf(LockRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Condition.prototype.wait requires a Lock argument");
    lock.mutex.lockUncancelable(agent.engineIo());
    const held_by_me = lock.locked and lock.holder == currentTid();
    lock.mutex.unlock(agent.engineIo());
    if (!held_by_me)
        return self.throwError("TypeError", "Condition.prototype.wait requires the lock to be held by the caller");
    if (!self.main_can_block)
        return self.throwError("TypeError", "Condition.prototype.wait cannot block the current thread");
    _ = try condWaitCore(self, rec, lock, null);
    return Value.undef();
}

fn condNotify(self: *Interpreter, rec: *CondRecord, count: usize) value.HostError!usize {
    // ONE FIFO domain: wake in arrival order regardless of kind.
    const io = agent.engineIo();
    var n: usize = 0;
    var woken_stack: [64]CondEntry = undefined;
    var woken_stack_len: usize = 0;
    var woken_heap: std.ArrayListUnmanaged(CondEntry) = .empty;
    defer woken_heap.deinit(self.arena);
    rec.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) rec.mutex.unlock(io);
    const available = rec.queue.items.len - rec.queue_head;
    const wake_cap = @min(count, available);
    const use_heap_woken = wake_cap > woken_stack.len;
    if (use_heap_woken) try woken_heap.ensureTotalCapacity(self.arena, wake_cap);
    var sync_count: usize = 0;
    while (n < count) {
        const entry = rec.popWaiter() orelse break;
        switch (entry) {
            .sync => |t| {
                t.woken = true;
                sync_count += 1;
            },
            .asynchronous => {},
        }
        if (use_heap_woken) {
            woken_heap.appendAssumeCapacity(entry);
        } else {
            woken_stack[woken_stack_len] = entry;
            woken_stack_len += 1;
        }
        n += 1;
    }
    const woken: []const CondEntry = if (use_heap_woken) woken_heap.items else woken_stack[0..woken_stack_len];

    if (sync_count == 0) {
        // Async-only notifications do not need the sync notifyAll handoff.
        // Deliver their lock regrants outside the condition queue mutex so
        // regrant bookkeeping and realm task enqueueing do not lengthen the
        // condition critical section.
        rec.mutex.unlock(io);
        locked = false;
        wakeAsyncCondWaiters(self, woken);
        return n;
    }
    rec.sync_handoff_pending = sync_count;

    // Mixed wakeups keep the old ordering shape: async regrants are prepared
    // before the sync handoff wait, while the condition mutex still serializes
    // the notify operation.
    wakeAsyncCondWaiters(self, woken);
    rec.cond.broadcast(io);
    // Depth-free handoff (notify-all-shared-lock) + FIFO against
    // async regrants (condition-async-wait): loop until every woken
    // sync waiter has re-registered on its lock.
    while (rec.sync_handoff_pending != 0) {
        // Woken sync waiters signal this same condition after re-registering on
        // their lock. The timeout keeps spurious or missed wakes bounded without
        // paying the old fixed 1ms sleep when the waiter acks immediately.
        waitOnCondRecord(self, rec, .{ .duration = .{
            .raw = .fromMilliseconds(1),
            .clock = .awake,
        } });
    }
    rec.sync_handoff_pending = 0;
    return n;
}

fn condNotifyFn(comptime all: bool) value.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
            const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.notify called on incompatible receiver");
            const n = try condNotify(self, rec, if (all) std.math.maxInt(usize) else 1);
            return Value.num(@floatFromInt(n));
        }
    }.call;
}

fn lockFromToken(self: *Interpreter, token_v: Value, name: []const u8) value.HostError!*LockRecord {
    const token = recOf(UnlockTokenRecord, token_v) orelse
        return self.throwError("TypeError", name);
    return token.lock orelse self.throwError("TypeError", name);
}

fn conditionStaticWaitFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const cond_v = if (args.len > 0) args[0] else Value.undef();
    const token_v = if (args.len > 1) args[1] else Value.undef();
    const rec = recOf(CondRecord, cond_v) orelse
        return self.throwError("TypeError", "Atomics.Condition.wait requires a Condition argument");
    const lock = try lockFromToken(self, token_v, "Atomics.Condition.wait requires a locked UnlockToken");
    const root_mark = try self.pushTempRoot(cond_v);
    defer self.restoreTempRoots(root_mark);
    _ = try self.pushTempRoot(token_v);
    _ = try condWaitCore(self, rec, lock, null);
    return Value.undef();
}

fn conditionStaticWaitForFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const cond_v = if (args.len > 0) args[0] else Value.undef();
    const token_v = if (args.len > 1) args[1] else Value.undef();
    const rec = recOf(CondRecord, cond_v) orelse
        return self.throwError("TypeError", "Atomics.Condition.waitFor requires a Condition argument");
    const lock = try lockFromToken(self, token_v, "Atomics.Condition.waitFor requires a locked UnlockToken");
    const timeout_v = if (args.len > 2) args[2] else Value.undef();
    if (timeout_v.isUndefined())
        return self.throwError("TypeError", "Atomics.Condition.waitFor requires a timeout");
    const timeout_ns = try timeoutMillisToNs(try self.toNumberV(timeout_v));
    const pred = if (args.len > 3) args[3] else Value.undef();
    if (!pred.isUndefined() and !pred.isCallable())
        return self.throwError("TypeError", "Atomics.Condition.waitFor predicate must be callable");
    const root_mark = try self.pushTempRoot(cond_v);
    defer self.restoreTempRoots(root_mark);
    _ = try self.pushTempRoot(token_v);
    if (!pred.isUndefined()) _ = try self.pushTempRoot(pred);

    const start = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    while (true) {
        if (pred.isCallable()) {
            const ok = try self.callValueWithThis(pred, &.{}, Value.undef());
            if (ok.toBoolean()) return Value.boolVal(true);
        }
        const remaining: ?u64 = if (timeout_ns) |ns| blk: {
            const elapsed: u64 = @intCast(@max(std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds - start, 0));
            if (elapsed >= ns) return Value.boolVal(false);
            break :blk ns - elapsed;
        } else null;
        const notified = try condWaitCore(self, rec, lock, remaining);
        if (!pred.isCallable()) return Value.boolVal(notified);
    }
}

fn conditionNotifyCount(self: *Interpreter, v: Value) value.HostError!usize {
    if (v.isUndefined()) return std.math.maxInt(usize);
    const n = try self.toNumberV(v);
    if (n == std.math.inf(f64)) return std.math.maxInt(usize);
    if (std.math.isNan(n) or n < 0 or @trunc(n) != n)
        return self.throwError("TypeError", "Atomics.Condition.notify count must be a non-negative integer or Infinity");
    if (n > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(n);
}

fn conditionStaticNotifyFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Atomics.Condition.notify requires a Condition argument");
    const count = try conditionNotifyCount(self, if (args.len > 1) args[1] else Value.undef());
    return Value.num(@floatFromInt(try condNotify(self, rec, count)));
}

fn tlValueGetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.prototype.value called on incompatible receiver");
    rec.lockMap();
    defer rec.unlockMap();
    return rec.map.get(currentTid()) orelse Value.undef();
}

fn tlValueSetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.prototype.value called on incompatible receiver");
    const v = if (args.len > 0) args[0] else Value.undef();
    if (v.isUndefined()) {
        rec.lockMap();
        _ = rec.map.remove(currentTid());
        rec.unlockMap();
        return Value.undef();
    }
    try rememberThreadLocalForCurrentThread(rec);
    rec.lockMap();
    defer rec.unlockMap();
    try rec.map.put(rec.arena, currentTid(), v);
    gc_mod.barrierValueFrom(if (rec.owner) |o| @ptrCast(o) else null, v);
    return Value.undef();
}

// ---- Atomics on plain object properties (Phase 6 step 4) -------------------
// PR-249 SPEC-api 4.5, spec'd line-by-line by
// reference/webkit-249/threads-tests/atomics/property-*.js: each op is one
// SeqCst step on an OWN DATA property. Values are NOT coerced (any JS value
// round-trips by identity); load and the RMW family require an existing own
// data property (absent/accessor/inherited throw); store writes through
// preserving attributes and may create a fresh default-attribute property on
// an extensible object; compareExchange is SameValueZero; wait/notify key on
// (object, property). Property mode only exists in enable_threads Contexts,
// so the test262-visible TypedArray path is untouched.

/// Whether an Atomics call should take the property path.
pub fn isPropertyMode(self: *Interpreter, v: Value) bool {
    return self.gil != null and
        v.isObject() and
        !v.asObj().is_symbol and
        !v.asObj().is_bigint and
        v.asObj().proxyTarget() == null and
        v.asObj().typedArray() == null and
        v.asObj().dataView() == null;
}

fn sameValueZero(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber())
        return a.asNum() == b.asNum() or (std.math.isNan(a.asNum()) and std.math.isNan(b.asNum()));
    return value.strictEquals(a, b);
}

fn isAccessor(o: *value.Object, key: []const u8) bool {
    // Read via the property_lock-guarded accessor (not the live map): this runs
    // on the index-keyed property-mode Atomics fall-through where the caller does
    // NOT already hold the lock, so under parallel_js a concurrent
    // defineProperty-accessor could grow o.accessors mid-`get` (the same
    // "grow vs lookup" class fixed in seal/freeze).
    return o.getAccessor(key) != null;
}

fn isLockedNamedAtomicsKey(key: []const u8) bool {
    return value.canonicalIndex(key) == null;
}

fn denseAtomicsIndex(o: *value.Object, key: []const u8) ?usize {
    const i = value.canonicalIndex(key) orelse return null;
    if (!o.is_array or o.is_arguments or o.accessorsMap() != null or o.attrsMap() != null) return null;
    return i;
}

fn attrUnlocked(o: *const value.Object, key: []const u8) value.PropAttr {
    if (o.attrsMap()) |m| {
        if (m.get(key)) |a| return a;
    }
    return .{};
}

fn accessorUnlocked(o: *const value.Object, key: []const u8) bool {
    if (o.accessorsMap()) |m| return m.get(key) != null;
    return false;
}

fn namedSlotUnlocked(o: *const value.Object, key: []const u8) ?usize {
    const sh = o.shape orelse return null;
    return @intCast(sh.lookup(key) orelse return null);
}

fn ownDataOrThrow(self: *Interpreter, o: *value.Object, key: []const u8, what: []const u8) value.HostError!Value {
    if (isLockedNamedAtomicsKey(key)) {
        o.lockProperties();
        defer o.unlockProperties();
        if (accessorUnlocked(o, key)) return self.throwError("TypeError", what);
        if (namedSlotUnlocked(o, key)) |slot| return o.slotsItems()[slot];
        return self.throwError("TypeError", what);
    }
    if (isAccessor(o, key)) return self.throwError("TypeError", what);
    if (o.getOwn(key)) |v| return v;
    // Array dense elements (and other index-shaped own data) live outside the
    // shape slots; the generic own check + [[Get]] covers them (one step
    // under the GIL in the supported Layer-B mode).
    if (interp.objectHasOwn(o, key)) return self.getProperty(Value.obj(o), key);
    return self.throwError("TypeError", what);
}

fn writableOrThrow(self: *Interpreter, o: *value.Object, key: []const u8, what: []const u8) value.HostError!void {
    if (!o.getAttr(key).writable) return self.throwError("TypeError", what);
}

fn argAt(args: []const Value, i: usize) Value {
    return if (args.len > i) args[i] else Value.undef();
}

pub fn propLoad(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    if (denseAtomicsIndex(o, key)) |i| {
        if (o.atomicDenseElementLoad(i)) |v| return v;
    }
    return ownDataOrThrow(self, o, key, "Atomics.load: object has no own property");
}

pub fn propStore(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    const v = argAt(args, 2);
    if (denseAtomicsIndex(o, key)) |i| {
        if (o.atomicDenseElementStore(i, v)) |stored| return stored;
    }
    if (isLockedNamedAtomicsKey(key)) {
        o.lockProperties();
        defer o.unlockProperties();
        if (accessorUnlocked(o, key)) return self.throwError("TypeError", "Atomics.store: property is an accessor");
        if (namedSlotUnlocked(o, key) != null) {
            if (!attrUnlocked(o, key).writable) return self.throwError("TypeError", "Atomics.store: property is not writable");
        } else if (!o.isExtensible()) {
            return self.throwError("TypeError", "Atomics.store: cannot add a property to a non-extensible object");
        }
        try o.setOwnUnlocked(self.arena, self.root_shape, key, v);
        return v;
    }
    if (isAccessor(o, key)) return self.throwError("TypeError", "Atomics.store: property is an accessor");
    if (interp.objectHasOwn(o, key)) {
        try writableOrThrow(self, o, key, "Atomics.store: property is not writable");
    } else if (!o.isExtensible()) {
        return self.throwError("TypeError", "Atomics.store: cannot add a property to a non-extensible object");
    }
    // [[Set]] writes shape props and index elements alike, preserving
    // attributes and creating fresh default-attribute properties.
    try self.setMember(Value.obj(o), key, v);
    return v;
}

pub fn propExchange(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    if (denseAtomicsIndex(o, key)) |i| {
        if (o.atomicDenseElementExchange(i, argAt(args, 2))) |old| return old;
    }
    if (isLockedNamedAtomicsKey(key)) {
        o.lockProperties();
        defer o.unlockProperties();
        if (accessorUnlocked(o, key)) return self.throwError("TypeError", "Atomics.exchange: object has no own data property");
        const slot = namedSlotUnlocked(o, key) orelse
            return self.throwError("TypeError", "Atomics.exchange: object has no own data property");
        const old = o.slotsItems()[slot];
        if (!attrUnlocked(o, key).writable) return self.throwError("TypeError", "Atomics.exchange: property is not writable");
        try o.setOwnUnlocked(self.arena, self.root_shape, key, argAt(args, 2));
        return old;
    }
    const old = try ownDataOrThrow(self, o, key, "Atomics.exchange: object has no own data property");
    try writableOrThrow(self, o, key, "Atomics.exchange: property is not writable");
    try self.setMember(Value.obj(o), key, argAt(args, 2));
    return old;
}

pub fn propCompareExchange(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    if (denseAtomicsIndex(o, key)) |i| {
        if (o.atomicDenseElementCompareExchange(i, argAt(args, 2), argAt(args, 3))) |old| return old;
    }
    if (isLockedNamedAtomicsKey(key)) {
        o.lockProperties();
        defer o.unlockProperties();
        if (accessorUnlocked(o, key)) return self.throwError("TypeError", "Atomics.compareExchange: object has no own data property");
        const slot = namedSlotUnlocked(o, key) orelse
            return self.throwError("TypeError", "Atomics.compareExchange: object has no own data property");
        const old = o.slotsItems()[slot];
        // The writability rule throws unconditionally — even when the compare
        // would fail.
        if (!attrUnlocked(o, key).writable) return self.throwError("TypeError", "Atomics.compareExchange: property is not writable");
        if (sameValueZero(old, argAt(args, 2)))
            try o.setOwnUnlocked(self.arena, self.root_shape, key, argAt(args, 3));
        return old;
    }
    const old = try ownDataOrThrow(self, o, key, "Atomics.compareExchange: object has no own data property");
    // The writability rule throws unconditionally — even when the compare
    // would fail.
    try writableOrThrow(self, o, key, "Atomics.compareExchange: property is not writable");
    if (sameValueZero(old, argAt(args, 2)))
        try self.setMember(Value.obj(o), key, argAt(args, 3));
    return old;
}

pub const PropRmwOp = enum { add, sub, and_, or_, xor };

pub fn propRmw(self: *Interpreter, op: PropRmwOp, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    const operand = try self.toNumberV(argAt(args, 2));
    if (denseAtomicsIndex(o, key)) |i| {
        const dense_op: value.Object.DenseElementRmwOp = switch (op) {
            .add => .add,
            .sub => .sub,
            .and_ => .and_,
            .or_ => .or_,
            .xor => .xor,
        };
        if (o.atomicDenseElementRmwNumber(i, operand, dense_op)) |old| return old;
    }
    if (isLockedNamedAtomicsKey(key)) {
        o.lockProperties();
        defer o.unlockProperties();
        if (accessorUnlocked(o, key)) return self.throwError("TypeError", "Atomics RMW: object has no own data property");
        const slot = namedSlotUnlocked(o, key) orelse
            return self.throwError("TypeError", "Atomics RMW: object has no own data property");
        const old = o.slotsItems()[slot];
        if (!attrUnlocked(o, key).writable) return self.throwError("TypeError", "Atomics RMW: property is not writable");
        if (!old.isNumber()) return self.throwError("TypeError", "Atomics RMW: stored value is not a number");
        const result: f64 = switch (op) {
            .add => old.asNum() + operand,
            .sub => old.asNum() - operand,
            .and_ => @floatFromInt(jsInt32(old.asNum()) & jsInt32(operand)),
            .or_ => @floatFromInt(jsInt32(old.asNum()) | jsInt32(operand)),
            .xor => @floatFromInt(jsInt32(old.asNum()) ^ jsInt32(operand)),
        };
        try o.setOwnUnlocked(self.arena, self.root_shape, key, Value.num(result));
        return old;
    }
    const old = try ownDataOrThrow(self, o, key, "Atomics RMW: object has no own data property");
    try writableOrThrow(self, o, key, "Atomics RMW: property is not writable");
    if (!old.isNumber()) return self.throwError("TypeError", "Atomics RMW: stored value is not a number");
    const result: f64 = switch (op) {
        .add => old.asNum() + operand,
        .sub => old.asNum() - operand,
        // Bitwise ops use JS ToInt32 semantics on both sides.
        .and_ => @floatFromInt(jsInt32(old.asNum()) & jsInt32(operand)),
        .or_ => @floatFromInt(jsInt32(old.asNum()) | jsInt32(operand)),
        .xor => @floatFromInt(jsInt32(old.asNum()) ^ jsInt32(operand)),
    };
    try self.setMember(Value.obj(o), key, Value.num(result));
    return old;
}

fn jsInt32(n: f64) i32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const wrapped = @mod(@trunc(n), 4294967296.0);
    const u: u32 = @intFromFloat(if (wrapped < 0) wrapped + 4294967296.0 else wrapped);
    return @bitCast(u);
}

// One FIFO of property waiters per threaded realm, stored on `Gil`.
// `Gil.prop_mutex` serializes the lists independently from the context GIL;
// sync tickets are unlinked before wait returns, while async tickets are owned
// until settlement. Metadata allocation uses `Gil.prop_alloc`, which is the
// Context allocator in real threaded contexts so heap caps cover waiter
// pressure.
const PropTicket = struct {
    obj: *value.Object,
    key: []const u8,
    cond: std.Io.Condition = .init,
    woken: bool = false,
    /// True while `Gil.prop_waiters` owns a pointer to this sync ticket.
    /// Notify unlinks matching tickets before signaling them; timeout and
    /// termination paths unlink their own ticket before returning.
    queued: bool = false,
};
const prop_waiter_reserve_granularity = 16;
const prop_async_reserve_granularity = 16;

pub const PropAsyncTicket = struct {
    obj: *value.Object,
    key: []const u8,
    deadline_ns: ?i96,
    promise: *value.Object,
    microtasks: *promise.MicrotaskQueue,
    /// The JS thread whose local queue was captured at registration time. When
    /// a peer removes this ticket from the global table and settles it after the
    /// owner has begun teardown, settlement reroutes to the realm queue instead
    /// of appending to the owner's stack-local queue after its final flush.
    thread: ?*ThreadRecord,
    /// The realm's gil pointer — the abandon token at Context.destroy.
    owner: *const anyopaque,
};

fn propAsyncAllocator(t: *const PropAsyncTicket) std.mem.Allocator {
    const g: *const gil_mod.Gil = @ptrCast(@alignCast(t.owner));
    return g.prop_alloc;
}

fn reservePropQueueLocked(
    g: *gil_mod.Gil,
    queue: *std.ArrayListUnmanaged(*anyopaque),
    additional: usize,
    granularity: usize,
) !void {
    const spare = queue.capacity - queue.items.len;
    if (spare >= additional) return;
    const extra = @max(additional, granularity);
    gc_runtime.enterTraceSensitiveLock();
    defer gc_runtime.leaveTraceSensitiveLock();
    try queue.ensureTotalCapacity(g.prop_alloc, queue.items.len + extra);
}

fn appendPropTicketLocked(g: *gil_mod.Gil, ticket: *PropTicket) !void {
    try reservePropQueueLocked(g, &g.prop_waiters, 1, prop_waiter_reserve_granularity);
    g.prop_waiters.appendAssumeCapacity(@ptrCast(ticket));
    ticket.queued = true;
}

fn appendPropAsyncLocked(g: *gil_mod.Gil, ticket: *PropAsyncTicket) !void {
    try reservePropQueueLocked(g, &g.prop_async, 1, prop_async_reserve_granularity);
    g.prop_async.appendAssumeCapacity(@ptrCast(ticket));
}

/// `Atomics.waitAsync(obj, key, expected, timeout)` — the property path.
/// Settlement: a notify resolves "ok" on the notifying thread; expiry
/// resolves "timed-out" from the awaiters' poll points.
pub fn propWaitAsync(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].asObj();
    const g = self.gil.?;
    const prop_alloc = g.prop_alloc;
    const key_tmp = try self.keyOf(argAt(args, 1));
    const expected = argAt(args, 2);
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.waitAsync: object has no own data property");
    if (!sameValueZero(cur, expected)) {
        const res = (try self.newObject()).asObj();
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("not-equal"));
        return Value.obj(res);
    }
    if (timeout_ns != null and timeout_ns.? == 0) {
        const res = (try self.newObject()).asObj();
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("timed-out"));
        return Value.obj(res);
    }
    const microtasks = self.microtasks orelse
        return self.throwError("Error", "Atomics.waitAsync requires a microtask queue");
    const key = prop_alloc.dupe(u8, key_tmp) catch return error.OutOfMemory;
    const t = prop_alloc.create(PropAsyncTicket) catch {
        prop_alloc.free(key);
        return error.OutOfMemory;
    };
    var queued = false;
    defer if (!queued) {
        prop_alloc.free(key);
        prop_alloc.destroy(t);
    };
    const p_obj = try promise.newPromise(self);
    const res = (try self.newObject()).asObj();
    // Build the externally visible result before publishing the ticket. These
    // property writes may allocate; the collector traces `g.prop_async` under
    // `prop_mutex`, so doing them after publication while still holding that
    // mutex can self-deadlock allocation recovery. Prebuilding also makes
    // publication failure-atomic: every queued ticket has a complete result.
    try self.setProp(res, "async", Value.boolVal(true));
    try self.setProp(res, "value", Value.obj(p_obj));
    const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    t.* = .{
        .obj = o,
        .key = key,
        .deadline_ns = if (timeout_ns) |ns| now + ns else null,
        .promise = p_obj,
        .microtasks = microtasks,
        .thread = t_current,
        .owner = @ptrCast(g),
    };
    g.lockPropWaiters();
    var locked = true;
    defer if (locked) g.unlockPropWaiters();
    const cur_locked = try ownDataOrThrow(self, o, key_tmp, "Atomics.waitAsync: object has no own data property");
    if (!sameValueZero(cur_locked, expected)) {
        g.unlockPropWaiters();
        locked = false;
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("not-equal"));
        return Value.obj(res);
    }
    appendPropAsyncLocked(g, t) catch {
        g.unlockPropWaiters();
        locked = false;
        return error.OutOfMemory;
    };
    queued = true;
    bumpContention("property_wait_async_enqueued");
    return Value.obj(res);
}

fn settlePropAsync(self: *Interpreter, t: *PropAsyncTicket, outcome: []const u8) void {
    const prop_alloc = propAsyncAllocator(t);
    bumpContention("property_wait_async_settled");
    const outcome_value = if (std.mem.eql(u8, outcome, "ok")) Value.str("ok") else Value.str("timed-out");
    if (promise.promiseOf(Value.obj(t.promise))) |pp| {
        const saved_microtasks = self.microtasks;
        if (t.thread) |rec| {
            const io = agent.engineIo();
            rec.join_mutex.lockUncancelable(io);
            // The parallel root walk takes this mutex before tracing the same
            // completion record. Promise settlement can grow the selected job
            // queue, so suppress collection/recovery until the queue choice and
            // enqueue are atomically published against thread teardown.
            gc_runtime.enterTraceSensitiveLock();
            const target = if (rec.microtasks == t.microtasks) t.microtasks else &rec.ctx.microtasks;
            self.microtasks = target;
            promise.resolve(self, pp, outcome_value) catch {};
            self.microtasks = saved_microtasks;
            gc_runtime.leaveTraceSensitiveLock();
            rec.join_mutex.unlock(io);
        } else {
            self.microtasks = t.microtasks;
            promise.resolve(self, pp, outcome_value) catch {};
            self.microtasks = saved_microtasks;
        }
    }
    prop_alloc.free(t.key);
    prop_alloc.destroy(t);
}

fn transferPropAsyncQueue(g: *gil_mod.Gil, from: *promise.MicrotaskQueue, to: *promise.MicrotaskQueue) void {
    g.lockPropWaiters();
    defer g.unlockPropWaiters();
    for (g.prop_async.items) |raw| {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (t.microtasks == from) t.microtasks = to;
    }
}

fn abandonPropAsyncQueue(g: *gil_mod.Gil, queue: *promise.MicrotaskQueue) void {
    const prop_alloc = g.prop_alloc;
    g.lockPropWaiters();
    defer g.unlockPropWaiters();
    var write: usize = 0;
    var read: usize = 0;
    while (read < g.prop_async.items.len) : (read += 1) {
        const raw = g.prop_async.items[read];
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (t.microtasks == queue) {
            prop_alloc.free(t.key);
            prop_alloc.destroy(t);
            continue;
        }
        if (write != read) g.prop_async.items[write] = raw;
        write += 1;
    }
    shrinkPropAsyncLocked(g, write);
}

fn transferPendingJoinQueue(ctx: *Context, from: *promise.MicrotaskQueue, to: *promise.MicrotaskQueue) void {
    const g = ctx.gil orelse return;
    const io = agent.engineIo();
    g.lockApi();
    defer g.unlockApi();
    for (ctx.js_threads.items) |rec| {
        rec.join_mutex.lockUncancelable(io);
        for (rec.pending_joins.items) |*pending| {
            if (pending.microtasks == from) pending.microtasks = to;
        }
        rec.join_mutex.unlock(io);
    }
}

/// Resolve expired property waitAsync tickets — called from the awaiters'
/// poll points (awaitValue's GIL-handover loop, the drain tail).
pub fn pollPropAsync(self: *Interpreter) void {
    const g = self.gil orelse return;
    const prop_alloc = g.prop_alloc;
    const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    var expired: std.ArrayListUnmanaged(*PropAsyncTicket) = .empty;
    defer expired.deinit(prop_alloc);
    g.lockPropWaiters();
    collectPropAsyncExpiredLocked(g, now, &expired);
    g.unlockPropWaiters();
    for (expired.items) |t| settlePropAsync(self, t, "timed-out");
}

/// Earliest finite property `Atomics.waitAsync` deadline in this realm, or
/// null when there are no finite timers to keep the shell alive for.
pub fn nextPropAsyncDeadline(self: *Interpreter) ?i96 {
    const g = self.gil orelse return null;
    var nearest: ?i96 = null;
    g.lockPropWaiters();
    defer g.unlockPropWaiters();
    for (g.prop_async.items) |raw| {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (t.deadline_ns) |d| nearest = if (nearest) |m| @min(m, d) else d;
    }
    return nearest;
}

/// Drop tickets of a dying realm (their promises die with the arena).
pub fn abandonPropAsync(g: *gil_mod.Gil) void {
    const prop_alloc = g.prop_alloc;
    const owner: *const anyopaque = @ptrCast(g);
    g.lockPropWaiters();
    for (g.prop_async.items) |raw| {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (t.owner == owner) {
            prop_alloc.free(t.key);
            prop_alloc.destroy(t);
        }
    }
    g.prop_async.deinit(prop_alloc);
    g.prop_waiters.deinit(prop_alloc);
    g.unlockPropWaiters();
}

fn removePropTicketLocked(g: *gil_mod.Gil, ticket: *PropTicket) void {
    if (!ticket.queued) return;
    var found = false;
    var write: usize = 0;
    var read: usize = 0;
    while (read < g.prop_waiters.items.len) : (read += 1) {
        const raw = g.prop_waiters.items[read];
        const t: *PropTicket = @ptrCast(@alignCast(raw));
        if (t == ticket) {
            ticket.queued = false;
            found = true;
            continue;
        }
        if (write != read) g.prop_waiters.items[write] = raw;
        write += 1;
    }
    shrinkPropWaitersLocked(g, write);
    if (!found) ticket.queued = false;
}

fn propTicketMatches(t: anytype, obj: *value.Object, key: []const u8) bool {
    return t.obj == obj and std.mem.eql(u8, t.key, key);
}

fn shrinkPropWaitersLocked(g: *gil_mod.Gil, len: usize) void {
    if (len == 0) {
        g.prop_waiters.clearRetainingCapacity();
    } else {
        g.prop_waiters.shrinkRetainingCapacity(len);
    }
}

fn shrinkPropAsyncLocked(g: *gil_mod.Gil, len: usize) void {
    if (len == 0) {
        g.prop_async.clearRetainingCapacity();
    } else {
        g.prop_async.shrinkRetainingCapacity(len);
    }
}

fn notifyPropWaitersLocked(g: *gil_mod.Gil, obj: *value.Object, key: []const u8, count: usize, io: std.Io) usize {
    var n: usize = 0;
    var write: usize = 0;
    var read: usize = 0;
    while (read < g.prop_waiters.items.len) : (read += 1) {
        const raw = g.prop_waiters.items[read];
        const t: *PropTicket = @ptrCast(@alignCast(raw));
        if (n < count and !t.woken and propTicketMatches(t, obj, key)) {
            t.woken = true;
            t.queued = false;
            t.cond.signal(io);
            n += 1;
            continue;
        }
        if (write != read) g.prop_waiters.items[write] = raw;
        write += 1;
    }
    shrinkPropWaitersLocked(g, write);
    return n;
}

fn countPropAsyncMatchesLocked(g: *gil_mod.Gil, obj: *value.Object, key: []const u8, limit: usize) usize {
    var n: usize = 0;
    for (g.prop_async.items) |raw| {
        if (n >= limit) break;
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (propTicketMatches(t, obj, key)) n += 1;
    }
    return n;
}

fn collectPropAsyncNotifyLocked(
    g: *gil_mod.Gil,
    obj: *value.Object,
    key: []const u8,
    limit: usize,
    settle: *std.ArrayListUnmanaged(*PropAsyncTicket),
) void {
    var n: usize = 0;
    var write: usize = 0;
    var read: usize = 0;
    while (read < g.prop_async.items.len) : (read += 1) {
        const raw = g.prop_async.items[read];
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (n < limit and propTicketMatches(t, obj, key)) {
            settle.appendAssumeCapacity(t);
            n += 1;
            continue;
        }
        if (write != read) g.prop_async.items[write] = raw;
        write += 1;
    }
    shrinkPropAsyncLocked(g, write);
}

fn collectPropAsyncExpiredLocked(g: *gil_mod.Gil, now: i96, settle: *std.ArrayListUnmanaged(*PropAsyncTicket)) void {
    var write: usize = 0;
    var read: usize = 0;
    while (read < g.prop_async.items.len) : (read += 1) {
        const raw = g.prop_async.items[read];
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (t.deadline_ns != null and t.deadline_ns.? <= now) {
            gc_runtime.enterTraceSensitiveLock();
            settle.append(g.prop_alloc, t) catch {
                gc_runtime.leaveTraceSensitiveLock();
                if (write != read) g.prop_async.items[write] = raw;
                write += 1;
                continue;
            };
            gc_runtime.leaveTraceSensitiveLock();
            continue;
        }
        if (write != read) g.prop_async.items[write] = raw;
        write += 1;
    }
    shrinkPropAsyncLocked(g, write);
}

test "property waiter notify stable-compacts matching sync tickets" {
    var g = gil_mod.Gil{};
    defer g.prop_waiters.deinit(std.testing.allocator);
    var obj_a: value.Object = undefined;
    var obj_b: value.Object = undefined;
    var t0 = PropTicket{ .obj = &obj_a, .key = "x", .queued = true };
    var t1 = PropTicket{ .obj = &obj_b, .key = "x", .queued = true };
    var t2 = PropTicket{ .obj = &obj_a, .key = "y", .queued = true };
    var t3 = PropTicket{ .obj = &obj_a, .key = "x", .queued = true };
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t0));
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t1));
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t2));
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t3));

    const woke = notifyPropWaitersLocked(&g, &obj_a, "x", 1, agent.engineIo());
    try std.testing.expectEqual(@as(usize, 1), woke);
    try std.testing.expect(t0.woken);
    try std.testing.expect(!t0.queued);
    try std.testing.expect(!t1.woken and t1.queued);
    try std.testing.expect(!t2.woken and t2.queued);
    try std.testing.expect(!t3.woken and t3.queued);
    try std.testing.expectEqual(@as(usize, 3), g.prop_waiters.items.len);
    try std.testing.expectEqual(@intFromPtr(&t1), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[0])))));
    try std.testing.expectEqual(@intFromPtr(&t2), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[1])))));
    try std.testing.expectEqual(@intFromPtr(&t3), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[2])))));

    const woke_rest = notifyPropWaitersLocked(&g, &obj_a, "x", std.math.maxInt(usize), agent.engineIo());
    try std.testing.expectEqual(@as(usize, 1), woke_rest);
    try std.testing.expect(t3.woken);
    try std.testing.expect(!t3.queued);
    try std.testing.expectEqual(@as(usize, 2), g.prop_waiters.items.len);
    try std.testing.expectEqual(@intFromPtr(&t1), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[0])))));
    try std.testing.expectEqual(@intFromPtr(&t2), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[1])))));
}

test "property waiter removal stable-compacts timed-out sync ticket" {
    var g = gil_mod.Gil{};
    defer g.prop_waiters.deinit(std.testing.allocator);
    var obj_a: value.Object = undefined;
    var obj_b: value.Object = undefined;
    var t0 = PropTicket{ .obj = &obj_a, .key = "x", .queued = true };
    var t1 = PropTicket{ .obj = &obj_b, .key = "x", .queued = true };
    var t2 = PropTicket{ .obj = &obj_a, .key = "y", .queued = true };
    var t3 = PropTicket{ .obj = &obj_a, .key = "x", .queued = true };
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t0));
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t1));
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t2));
    try g.prop_waiters.append(std.testing.allocator, @ptrCast(&t3));

    removePropTicketLocked(&g, &t1);
    try std.testing.expect(!t1.queued);
    try std.testing.expect(t0.queued);
    try std.testing.expect(t2.queued);
    try std.testing.expect(t3.queued);
    try std.testing.expectEqual(@as(usize, 3), g.prop_waiters.items.len);
    try std.testing.expectEqual(@intFromPtr(&t0), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[0])))));
    try std.testing.expectEqual(@intFromPtr(&t2), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[1])))));
    try std.testing.expectEqual(@intFromPtr(&t3), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[2])))));

    removePropTicketLocked(&g, &t0);
    try std.testing.expect(!t0.queued);
    try std.testing.expectEqual(@as(usize, 2), g.prop_waiters.items.len);
    try std.testing.expectEqual(@intFromPtr(&t2), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[0])))));
    try std.testing.expectEqual(@intFromPtr(&t3), @intFromPtr(@as(*PropTicket, @ptrCast(@alignCast(g.prop_waiters.items[1])))));
}

test "property waitAsync expiry stable-compacts expired tickets" {
    var g = gil_mod.Gil{};
    const prop_alloc = g.prop_alloc;
    defer g.prop_async.deinit(prop_alloc);
    var expired: std.ArrayListUnmanaged(*PropAsyncTicket) = .empty;
    defer expired.deinit(prop_alloc);
    var obj: value.Object = undefined;
    var t0 = PropAsyncTicket{ .obj = &obj, .key = "a", .deadline_ns = 10, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };
    var t1 = PropAsyncTicket{ .obj = &obj, .key = "b", .deadline_ns = 40, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };
    var t2 = PropAsyncTicket{ .obj = &obj, .key = "c", .deadline_ns = 20, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };
    var t3 = PropAsyncTicket{ .obj = &obj, .key = "d", .deadline_ns = null, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };
    var t4 = PropAsyncTicket{ .obj = &obj, .key = "e", .deadline_ns = 30, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };

    try g.prop_async.append(prop_alloc, @ptrCast(&t0));
    try g.prop_async.append(prop_alloc, @ptrCast(&t1));
    try g.prop_async.append(prop_alloc, @ptrCast(&t2));
    try g.prop_async.append(prop_alloc, @ptrCast(&t3));
    try g.prop_async.append(prop_alloc, @ptrCast(&t4));

    collectPropAsyncExpiredLocked(&g, 25, &expired);
    try std.testing.expectEqual(@as(usize, 2), expired.items.len);
    try std.testing.expectEqual(@intFromPtr(&t0), @intFromPtr(expired.items[0]));
    try std.testing.expectEqual(@intFromPtr(&t2), @intFromPtr(expired.items[1]));
    try std.testing.expectEqual(@as(usize, 3), g.prop_async.items.len);
    try std.testing.expectEqual(@intFromPtr(&t1), @intFromPtr(@as(*PropAsyncTicket, @ptrCast(@alignCast(g.prop_async.items[0])))));
    try std.testing.expectEqual(@intFromPtr(&t3), @intFromPtr(@as(*PropAsyncTicket, @ptrCast(@alignCast(g.prop_async.items[1])))));
    try std.testing.expectEqual(@intFromPtr(&t4), @intFromPtr(@as(*PropAsyncTicket, @ptrCast(@alignCast(g.prop_async.items[2])))));

    collectPropAsyncExpiredLocked(&g, 40, &expired);
    try std.testing.expectEqual(@as(usize, 4), expired.items.len);
    try std.testing.expectEqual(@intFromPtr(&t1), @intFromPtr(expired.items[2]));
    try std.testing.expectEqual(@intFromPtr(&t4), @intFromPtr(expired.items[3]));
    try std.testing.expectEqual(@as(usize, 1), g.prop_async.items.len);
    try std.testing.expectEqual(@intFromPtr(&t3), @intFromPtr(@as(*PropAsyncTicket, @ptrCast(@alignCast(g.prop_async.items[0])))));
}

test "property waitAsync abandon removes one owner queue" {
    var g = gil_mod.Gil{};
    const prop_alloc = g.prop_alloc;
    defer g.prop_async.deinit(prop_alloc);
    var obj: value.Object = undefined;
    var promise_obj: value.Object = undefined;
    var q0 = promise.MicrotaskQueue{};
    var q1 = promise.MicrotaskQueue{};

    const t0 = try prop_alloc.create(PropAsyncTicket);
    t0.* = .{ .obj = &obj, .key = try prop_alloc.dupe(u8, "a"), .deadline_ns = null, .promise = &promise_obj, .microtasks = &q0, .thread = null, .owner = @ptrCast(&g) };
    const t1 = try prop_alloc.create(PropAsyncTicket);
    errdefer {
        prop_alloc.free(t1.key);
        prop_alloc.destroy(t1);
    }
    t1.* = .{ .obj = &obj, .key = try prop_alloc.dupe(u8, "b"), .deadline_ns = null, .promise = &promise_obj, .microtasks = &q1, .thread = null, .owner = @ptrCast(&g) };
    const t2 = try prop_alloc.create(PropAsyncTicket);
    t2.* = .{ .obj = &obj, .key = try prop_alloc.dupe(u8, "c"), .deadline_ns = null, .promise = &promise_obj, .microtasks = &q0, .thread = null, .owner = @ptrCast(&g) };

    try g.prop_async.append(prop_alloc, @ptrCast(t0));
    try g.prop_async.append(prop_alloc, @ptrCast(t1));
    try g.prop_async.append(prop_alloc, @ptrCast(t2));

    abandonPropAsyncQueue(&g, &q0);
    try std.testing.expectEqual(@as(usize, 1), g.prop_async.items.len);
    try std.testing.expectEqual(@intFromPtr(t1), @intFromPtr(@as(*PropAsyncTicket, @ptrCast(@alignCast(g.prop_async.items[0])))));

    prop_alloc.free(t1.key);
    prop_alloc.destroy(t1);
    g.prop_async.clearRetainingCapacity();
}

test "property waiter queues reserve capacity chunks" {
    var g = gil_mod.Gil{};
    const prop_alloc = g.prop_alloc;
    defer g.prop_waiters.deinit(prop_alloc);
    defer g.prop_async.deinit(prop_alloc);
    var obj: value.Object = undefined;

    var first_waiter = PropTicket{ .obj = &obj, .key = "x" };
    try appendPropTicketLocked(&g, &first_waiter);
    try std.testing.expect(first_waiter.queued);
    try std.testing.expect(g.prop_waiters.capacity >= prop_waiter_reserve_granularity);

    const waiter_capacity = g.prop_waiters.capacity;
    var waiters = try prop_alloc.alloc(PropTicket, waiter_capacity + 1);
    defer prop_alloc.free(waiters);
    for (waiters) |*ticket| ticket.* = .{ .obj = &obj, .key = "x" };

    var waiter_i: usize = 0;
    while (g.prop_waiters.items.len < waiter_capacity) : (waiter_i += 1) {
        try appendPropTicketLocked(&g, &waiters[waiter_i]);
    }
    try std.testing.expectEqual(waiter_capacity, g.prop_waiters.capacity);

    try appendPropTicketLocked(&g, &waiters[waiter_i]);
    try std.testing.expect(waiters[waiter_i].queued);
    try std.testing.expect(g.prop_waiters.capacity > waiter_capacity);

    var first_async = PropAsyncTicket{ .obj = &obj, .key = "x", .deadline_ns = null, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };
    try appendPropAsyncLocked(&g, &first_async);
    try std.testing.expect(g.prop_async.capacity >= prop_async_reserve_granularity);

    const async_capacity = g.prop_async.capacity;
    var async = try prop_alloc.alloc(PropAsyncTicket, async_capacity + 1);
    defer prop_alloc.free(async);
    for (async) |*ticket| ticket.* = .{ .obj = &obj, .key = "x", .deadline_ns = null, .promise = undefined, .microtasks = undefined, .thread = null, .owner = undefined };

    var async_i: usize = 0;
    while (g.prop_async.items.len < async_capacity) : (async_i += 1) {
        try appendPropAsyncLocked(&g, &async[async_i]);
    }
    try std.testing.expectEqual(async_capacity, g.prop_async.capacity);

    try appendPropAsyncLocked(&g, &async[async_i]);
    try std.testing.expect(g.prop_async.capacity > async_capacity);
}

test "property waiter queue growth uses Gil allocator and is trace-sensitive" {
    var g = gil_mod.Gil{};
    var probe = TraceSensitiveAllocProbe{ .inner = std.testing.allocator };
    g.prop_alloc = probe.allocator();
    defer g.prop_waiters.deinit(g.prop_alloc);
    defer g.prop_async.deinit(g.prop_alloc);

    var obj: value.Object = undefined;
    var waiter = PropTicket{ .obj = &obj, .key = "x" };
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    try appendPropTicketLocked(&g, &waiter);
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());

    probe.saw_trace_sensitive_alloc = false;
    var async = PropAsyncTicket{ .obj = &obj, .key = "x", .deadline_ns = null, .promise = undefined, .microtasks = undefined, .thread = null, .owner = @ptrCast(&g) };
    try appendPropAsyncLocked(&g, &async);
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
}

test "property waiter metadata counts against heap budget" {
    const ctx = try Context.createWith(std.testing.allocator, .{
        .enable_threads = true,
        .heap_limit_bytes = 8 * 1024 * 1024,
    });
    defer ctx.destroy();

    const g = ctx.gil.?;
    const before = ctx.heapBudgetStats().?.used_bytes;
    const key = try g.prop_alloc.dupe(u8, "budgeted-property-waiter");
    errdefer g.prop_alloc.free(key);
    const ticket = try g.prop_alloc.create(PropAsyncTicket);
    errdefer g.prop_alloc.destroy(ticket);
    ticket.* = .{
        .obj = ctx.global_object,
        .key = key,
        .deadline_ns = null,
        .promise = ctx.global_object,
        .microtasks = &ctx.microtasks,
        .thread = null,
        .owner = @ptrCast(g),
    };
    try appendPropAsyncLocked(g, ticket);

    const after = ctx.heapBudgetStats().?.used_bytes;
    try std.testing.expect(after > before);
}

fn waitPropTicketTimeout(self: *Interpreter, g: *gil_mod.Gil, ticket: *PropTicket, timeout: std.Io.Timeout) error{Timeout}!void {
    const io = agent.engineIo();
    if (self.use_thread_gil) {
        var timed_out = false;
        stack_scan.beginPark();
        g.release();
        io_compat.conditionWaitTimeout(&ticket.cond, io, &g.prop_mutex, timeout) catch |err| {
            switch (err) {
                error.Timeout => timed_out = true,
                error.Canceled => {},
            }
        };
        // Avoid lock-order inversion with notifiers: a woken/timed-out waiter
        // must not hold prop_mutex while trying to reacquire the GIL, because a
        // GIL holder may be entering Atomics.notify and need prop_mutex.
        g.unlockPropWaiters();
        g.acquire();
        stack_scan.endPark();
        g.lockPropWaiters();
        if (timed_out) return error.Timeout;
    } else {
        io_compat.conditionWaitTimeout(&ticket.cond, io, &g.prop_mutex, timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => {},
        };
    }
}

pub fn propWait(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].asObj();
    const g = self.gil.?;
    const prop_alloc = g.prop_alloc;
    const key_tmp = try self.keyOf(argAt(args, 1));
    const expected = argAt(args, 2);
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.wait: object has no own data property");
    if (!sameValueZero(cur, expected)) return Value.str("not-equal");
    if (timeout_ns != null and timeout_ns.? == 0) return Value.str("timed-out");
    if (!self.main_can_block)
        return self.throwError("TypeError", "Atomics.wait cannot be called from the current thread.");
    const key = prop_alloc.dupe(u8, key_tmp) catch return error.OutOfMemory;
    const ticket = prop_alloc.create(PropTicket) catch {
        prop_alloc.free(key);
        return error.OutOfMemory;
    };
    ticket.* = .{ .obj = o, .key = key };
    defer {
        prop_alloc.destroy(ticket);
        prop_alloc.free(key);
    }
    g.lockPropWaiters();
    var linked = false;
    defer {
        if (linked) removePropTicketLocked(g, ticket);
        g.unlockPropWaiters();
    }
    const cur_locked = try ownDataOrThrow(self, o, key_tmp, "Atomics.wait: object has no own data property");
    if (!sameValueZero(cur_locked, expected)) return Value.str("not-equal");
    appendPropTicketLocked(g, ticket) catch return error.OutOfMemory;
    linked = true;
    bumpContention("property_waits");
    const deadline_ns: ?i96 = if (timeout_ns) |ns|
        std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds + ns
    else
        null;
    while (!ticket.woken) {
        g.unlockPropWaiters();
        // Property waiters pump between short parks; service the safepoint hook
        // while the waiter table is unlocked so a concurrent collector can get
        // this interpreter's roots without racing the waiter table.
        self.serviceGcSafepoint();
        pumpTasks(self);
        const stopped = if (self.stop_flag) |sf| sf.load(.monotonic) else false;
        g.lockPropWaiters();
        if (stopped) return self.throwError("Error", "worker terminated");
        if (ticket.woken) break;
        var tick_ns: u64 = 5 * std.time.ns_per_ms;
        if (deadline_ns) |d| {
            const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
            if (d <= now) return Value.str("timed-out");
            tick_ns = @min(tick_ns, @as(u64, @intCast(d - now)));
        }
        bumpContention("property_wait_parks");
        const wait_start = startContentionWaitTimer();
        waitPropTicketTimeout(self, g, ticket, .{ .duration = .{
            .raw = .fromNanoseconds(tick_ns),
            .clock = .awake,
        } }) catch {};
        finishContentionWaitTimer("property_wait_ns", wait_start);
    }
    return Value.str("ok");
}

pub fn propNotify(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    var count: usize = std.math.maxInt(usize);
    if (args.len > 2 and !args[2].isUndefined()) {
        const n = try self.toNumberV(args[2]);
        if (std.math.isNan(n) or n <= 0) count = 0 else if (n != std.math.inf(f64) and n < 1e18) count = @intFromFloat(@trunc(n));
    }
    const io = agent.engineIo();
    var n: usize = 0;
    const g = self.gil.?;
    const prop_alloc = g.prop_alloc;
    var settle: std.ArrayListUnmanaged(*PropAsyncTicket) = .empty;
    defer settle.deinit(prop_alloc);
    g.lockPropWaiters();
    var locked = true;
    defer if (locked) g.unlockPropWaiters();
    n += notifyPropWaitersLocked(g, o, key, count, io);
    if (n < count) {
        const limit = count - n;
        const async_matches = countPropAsyncMatchesLocked(g, o, key, limit);
        gc_runtime.enterTraceSensitiveLock();
        defer gc_runtime.leaveTraceSensitiveLock();
        try settle.ensureTotalCapacity(prop_alloc, async_matches);
        collectPropAsyncNotifyLocked(g, o, key, limit, &settle);
        n += async_matches;
    }
    g.unlockPropWaiters();
    locked = false;
    for (settle.items) |t| settlePropAsync(self, t, "ok"); // settling-thread rule
    return Value.num(@floatFromInt(n));
}

/// `Thread.prototype.asyncJoin()` — a promise for the thread's completion.
/// Settles immediately when already done; otherwise the finishing thread
/// settles it (reactions run there — the settling-thread rule; an `await`
/// on any other thread observes the shared state via the GIL-yield loop).
fn threadAsyncJoinFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recordOf(self, this) orelse return self.throwError("TypeError", "Thread.prototype.asyncJoin called on incompatible receiver");
    const p_obj = try promise.newPromise(self);
    const pp = promise.promiseOf(Value.obj(p_obj)).?;
    const io = agent.engineIo();
    rec.join_mutex.lockUncancelable(io);
    if (rec.done) {
        const threw = rec.threw;
        const result = rec.result;
        rec.join_mutex.unlock(io);
        if (threw) try promise.reject(self, pp, result) else try promise.resolve(self, pp, result);
    } else {
        const microtasks = self.microtasks orelse {
            rec.join_mutex.unlock(io);
            return self.throwError("Error", "Thread.prototype.asyncJoin requires a microtask queue");
        };
        appendPendingJoinLocked(rec, self.arena, .{ .promise = p_obj, .microtasks = microtasks, .owner = t_current }) catch |err| {
            rec.join_mutex.unlock(io);
            return err;
        };
        rec.join_mutex.unlock(io);
    }
    return Value.obj(p_obj);
}

/// `Thread.restrict(obj)` — pin `obj` to the calling thread; any enforced
/// access from another thread throws ConcurrentAccessError. The restrictable
/// set is an allowlist: plain objects and plain arrays (everything exotic —
/// callables, proxies, the global, views/buffers, collections, dates,
/// regexps, errors, builtin prototypes — is refused, per the corpus).
fn threadRestrictFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const v = if (args.len > 0) args[0] else Value.undef();
    if (!v.isObject()) return self.throwError("TypeError", "cannot restrict this object");
    const o = v.asObj();
    const plain = o.jsFunction() == null and o.native == null and o.hostCallback() == null and o.boundFunction() == null and
        o.generator() == null and o.proxyTarget() == null and !o.proxy_revoked and
        o != (self.global_object orelse o) and
        o.typedArray() == null and o.dataView() == null and o.arrayBuffer() == null and
        !o.behavior.is_date and !o.behavior.is_regex and !o.is_map and !o.is_set and !o.is_weak and
        o.promiseData() == null and !o.is_symbol and !o.is_bigint and o.moduleNs() == null and
        o.weakRefTarget() == null and !o.is_arguments and !o.behavior.is_error and
        o.boxedPrimitive() == null and o.errorCtor() == null and o.getOwn("constructor") == null;
    if (!plain) return self.throwError("TypeError", "cannot restrict this object");
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    // Claim via CAS 0→tid so two concurrent restricts can't both win.
    if (try o.claimRestriction(self.arena, tid)) |owner| {
        if (owner != tid)
            return self.throwError("ConcurrentAccessError", "Thread.restrict called from a non-owning thread");
        return v; // owner double-restrict is a no-op returning o
    }
    return v;
}

// ---- Lock.asyncHold / Condition.asyncWait ----------------------------------
// I12: neither settles synchronously — the GRANT can happen at registration
// (lock.locked reads true), but the fn / settlement runs on a run-loop turn.
// On this engine that means: take or queue the lock now, then push the
// completion through a real microtask (a reaction on an internally-resolved
// promise), so `.then` ordering and `await` behave like the corpus demands.
// Settlement runs on the granting thread (the registrant when uncontended,
// the releaser when contended) — the settling-thread rule.

const ReleaseState = struct {
    brand: SyncBrand = sync_brand_release_state,
    lock: *LockRecord,
    used: bool = false,
};

const HoldJob = struct {
    lock: *LockRecord,
    outer: *value.Object,
    /// User fn (with-fn arity), or null = resolve with a release() function.
    cb: ?Value,
    /// No-fn asyncHold grants need a once-only native release() state. The job is
    /// already one-per-grant and arena-lived, so embedding avoids a second small
    /// allocation in the release-function hot path.
    release_state: ReleaseState,
    /// True only for Condition.asyncWait reacquire grants; this keeps the local
    /// profile's async/done columns honest without exposing a public API knob.
    condition_async_reacquire: bool = false,
};

test "jsthread lock pending async jobs are cursor FIFO" {
    var rec = LockRecord{ .gil = undefined };
    const a = std.testing.allocator;
    defer rec.pending_front.deinit(a);
    defer rec.pending.deinit(a);

    var one = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    var two = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    var three = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    var front = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    var fallback_front = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    var fallback_front2 = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };

    try rec.appendPending(a, &one);
    try rec.appendPending(a, &two);
    try rec.appendPending(a, &three);

    try std.testing.expect(rec.hasPending());
    try std.testing.expectEqual(@as(usize, 0), rec.pending_head);
    try std.testing.expectEqual(@as(usize, 3), rec.pending.items.len);

    try std.testing.expectEqual(@intFromPtr(&one), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@as(usize, 1), rec.pending_head);
    try std.testing.expectEqual(@as(usize, 3), rec.pending.items.len);

    try rec.pushFrontPending(a, &front);
    try std.testing.expectEqual(@as(usize, 0), rec.pending_head);
    try std.testing.expectEqual(@intFromPtr(&front), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@intFromPtr(&two), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@intFromPtr(&three), @intFromPtr(rec.popPending().?));
    try std.testing.expect(!rec.hasPending());
    try std.testing.expectEqual(@as(usize, 0), rec.pending_head);
    try std.testing.expectEqual(@as(usize, 0), rec.pending.items.len);
    try std.testing.expectEqual(@as(?*HoldJob, null), rec.popPending());

    try rec.appendPending(a, &one);
    try rec.appendPending(a, &two);
    try rec.appendPending(a, &three);
    try rec.pushFrontPending(a, &fallback_front);
    try rec.pushFrontPending(a, &fallback_front2);
    try std.testing.expectEqual(@as(usize, 0), rec.pending_head);
    try std.testing.expectEqual(@as(usize, 3), rec.pending.items.len);
    try std.testing.expectEqual(@as(usize, 2), rec.pending_front.items.len);
    try std.testing.expectEqual(@intFromPtr(&fallback_front2), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@intFromPtr(&fallback_front), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@intFromPtr(&one), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@intFromPtr(&two), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@intFromPtr(&three), @intFromPtr(rec.popPending().?));
    try std.testing.expectEqual(@as(?*HoldJob, null), rec.popPending());
}

test "jsthread lock pending queues reserve capacity chunks" {
    const a = std.testing.allocator;
    var rec = LockRecord{ .gil = undefined };
    defer rec.pending_front.deinit(a);
    defer rec.pending.deinit(a);

    var first = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    try rec.appendPending(a, &first);
    try std.testing.expect(rec.pending.capacity >= lock_pending_reserve_granularity);

    const first_capacity = rec.pending.capacity;
    var jobs = try a.alloc(HoldJob, first_capacity + 1);
    defer a.free(jobs);
    for (jobs) |*job| job.* = .{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };

    var appended: usize = 0;
    while (rec.pending.items.len < first_capacity) : (appended += 1) {
        try rec.appendPending(a, &jobs[appended]);
    }
    try std.testing.expectEqual(first_capacity, rec.pending.capacity);

    try rec.appendPending(a, &jobs[appended]);
    try std.testing.expect(rec.pending.capacity > first_capacity);

    while (rec.popPending()) |_| {}
    try std.testing.expectEqual(@as(usize, 0), rec.pending_head);
    try std.testing.expectEqual(@as(usize, 0), rec.pending.items.len);
}

test "jsthread lock retry-front queue reserves capacity chunks" {
    const a = std.testing.allocator;
    var rec = LockRecord{ .gil = undefined };
    defer rec.pending_front.deinit(a);
    defer rec.pending.deinit(a);

    var first = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    try rec.pushFrontPending(a, &first);
    try std.testing.expect(rec.pending_front.capacity >= lock_pending_reserve_granularity);

    const first_capacity = rec.pending_front.capacity;
    var jobs = try a.alloc(HoldJob, first_capacity + 1);
    defer a.free(jobs);
    for (jobs) |*job| job.* = .{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };

    var appended: usize = 0;
    while (rec.pending_front.items.len < first_capacity) : (appended += 1) {
        try rec.pushFrontPending(a, &jobs[appended]);
    }
    try std.testing.expectEqual(first_capacity, rec.pending_front.capacity);

    try rec.pushFrontPending(a, &jobs[appended]);
    try std.testing.expect(rec.pending_front.capacity > first_capacity);

    while (rec.popPending()) |_| {}
    try std.testing.expectEqual(@as(usize, 0), rec.pending_front.items.len);
    try std.testing.expectEqual(@as(usize, 0), rec.pending_head);
}

test "jsthread lock pending queue growth is trace-sensitive" {
    var rec = LockRecord{ .gil = undefined };
    var probe = TraceSensitiveAllocProbe{ .inner = std.testing.allocator };
    const a = probe.allocator();
    defer rec.pending_front.deinit(a);
    defer rec.pending.deinit(a);

    var pending_job = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    try rec.appendPending(a, &pending_job);
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());

    probe.saw_trace_sensitive_alloc = false;
    var front_job = HoldJob{ .lock = &rec, .outer = undefined, .cb = null, .release_state = .{ .lock = &rec } };
    try rec.pushFrontPending(a, &front_job);
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
}

test "jsthread traces queued async hold task roots" {
    const Visitor = struct {
        outer: *value.Object,
        cb: *value.Object,
        saw_outer: bool = false,
        saw_cb: bool = false,

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            const ptr = cell orelse return;
            if (ptr == @as(*anyopaque, @ptrCast(self.outer))) self.saw_outer = true;
            if (ptr == @as(*anyopaque, @ptrCast(self.cb))) self.saw_cb = true;
        }
    };

    var g = gil_mod.Gil{};
    defer g.tasks.deinit(std.testing.allocator);
    var rec = LockRecord{ .gil = &g };
    defer rec.pending_front.deinit(std.testing.allocator);
    defer rec.pending.deinit(std.testing.allocator);
    var outer = value.Object{};
    var cb = value.Object{};
    var job = HoldJob{ .lock = &rec, .outer = &outer, .cb = Value.obj(&cb), .release_state = .{ .lock = &rec } };

    try g.enqueueTask(std.testing.allocator, @ptrCast(&job));
    var visitor = Visitor{ .outer = &outer, .cb = &cb };
    traceGilTaskRoots(&g, &visitor);
    try std.testing.expect(visitor.saw_outer);
    try std.testing.expect(visitor.saw_cb);

    var front_job = HoldJob{ .lock = &rec, .outer = &outer, .cb = Value.obj(&cb), .release_state = .{ .lock = &rec } };
    try rec.pushFrontPending(std.testing.allocator, &front_job);
    visitor.saw_outer = false;
    visitor.saw_cb = false;
    traceLockRecordRoots(&rec, &visitor);
    try std.testing.expect(visitor.saw_outer);
    try std.testing.expect(visitor.saw_cb);
}

/// `holder` value for an asyncHold grant: the hold belongs to the JOB, not
/// to any thread — a same-thread sync `hold` must read as CONTENDED (block
/// or gate), never as recursive.
const async_holder: u64 = std.math.maxInt(u64);

/// Centralized release: hand the lock to the next queued asyncHold job
/// (granted on this, the releasing thread), else open it and wake a parked
/// hold.
fn lockRelease(self: *Interpreter, rec: *LockRecord) void {
    var job_to_enqueue: ?*HoldJob = null;
    rec.mutex.lockUncancelable(agent.engineIo());
    job_to_enqueue = lockReleaseLocked(rec);
    rec.mutex.unlock(agent.engineIo());
    if (job_to_enqueue) |job| enqueueHoldJob(self, job) catch {};
}

fn lockReleaseIfHeldByCurrent(self: *Interpreter, rec: *LockRecord) void {
    var job_to_enqueue: ?*HoldJob = null;
    rec.mutex.lockUncancelable(agent.engineIo());
    if (rec.locked and rec.holder == currentTid()) job_to_enqueue = lockReleaseLocked(rec);
    rec.mutex.unlock(agent.engineIo());
    if (job_to_enqueue) |job| enqueueHoldJob(self, job) catch {};
}

fn lockReleaseLocked(rec: *LockRecord) ?*HoldJob {
    if (rec.sync_waiting > 0) {
        rec.locked = false;
        rec.holder = 0;
        rec.sync_generation +%= 1;
        rec.cond.signal(agent.engineIo());
        return null;
    }
    if (rec.grant_pending) {
        rec.locked = true;
        rec.holder = async_holder;
        return null;
    }
    if (rec.hasPending()) {
        const job = rec.popPending().?;
        rec.locked = false;
        rec.holder = 0;
        rec.grant_pending = false;
        return job;
    }
    rec.locked = false;
    rec.holder = 0;
    rec.cond.signal(agent.engineIo());
    return null;
}

/// Queue `job` on the realm's run-loop TASK queue (gil.tasks). Tasks are
/// pumped at the drain tail and at every park — a grant delivery must make
/// progress even while its granting thread is blocked (the corpus's
/// waitUntil/sleepMs rendezvous depend on it).
fn enqueueHoldJob(self: *Interpreter, job: *HoldJob) value.HostError!void {
    const g = self.gil orelse return;
    try g.enqueueTask(self.arena, @ptrCast(job));
}

fn enqueueHoldJobs(self: *Interpreter, jobs: []const *HoldJob) value.HostError!void {
    const g = self.gil orelse return;
    var erased: [256]*anyopaque = undefined;
    var i: usize = 0;
    while (i < jobs.len) {
        const n = @min(erased.len, jobs.len - i);
        for (jobs[i..][0..n], 0..) |job, j| erased[j] = @ptrCast(job);
        try g.enqueueTaskBurst(self.arena, erased[0..n]);
        i += n;
    }
}

inline fn microtaskEnqueueGeneration(self: *Interpreter) u64 {
    return if (self.microtasks) |q| q.enqueueGeneration() else 0;
}

/// Pump the realm's run-loop tasks: run each pending grant delivery as its
/// own turn (draining the pumping thread's microtasks after each). Called
/// from the drain tail and from every parking point.
pub fn pumpTasks(self: *Interpreter) void {
    const g = self.gil orelse return;
    var burst: [256]*anyopaque = undefined;
    while (true) {
        if (g.tasks_queued.load(.acquire) == 0) {
            bumpContention("task_pump_empty");
            return;
        }
        // Copy a bounded FIFO burst under api_lock, but run every job OUTSIDE the
        // lock — runHoldJob executes JS and takes per-structure locks, so holding
        // api_lock across it would invert lock order. Batching keeps asyncHold
        // delivery from taking the shared API lock once per queued grant.
        const n = g.dequeueTaskBurst(&burst);
        if (n == 0) break;
        self.current_hold_jobs = burst[0..n];
        for (burst[0..n]) |r| {
            bumpContention("task_pump_jobs");
            const job: *HoldJob = @ptrCast(@alignCast(r));
            if (job.condition_async_reacquire)
                bumpContention("task_pump_condition_jobs")
            else
                bumpContention("task_pump_async_hold_jobs");
            const microtask_gen = microtaskEnqueueGeneration(self);
            runHoldJob(self, job) catch {};
            if (microtaskEnqueueGeneration(self) != microtask_gen)
                self.drainMicrotasks() catch {};
        }
        self.current_hold_jobs = &.{};
    }
}

/// Pump-then-park tick: serve pending run-loop tasks, poll the termination
/// request (D9: parked waiters cannot be woken by traps, so every park
/// quantum checks), then wait on `cond` briefly.
fn parkPump(self: *Interpreter, g: *gil_mod.Gil, cond: *std.Io.Condition) value.HostError!void {
    pumpTasks(self);
    if (self.stop_flag) |sf| if (sf.load(.monotonic))
        return self.throwError("Error", "worker terminated");
    g.waitTimeout(cond, .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } }) catch {};
}

/// Like `parkPump`, but waits on a `ThreadRecord`'s completion mutex instead
/// of the context GIL. In shipped GIL mode the caller enters with the GIL held;
/// release it only for the actual park, and never wait for it again while still
/// holding `join_mutex` (that would invert against another thread entering
/// `asyncJoin` while it holds the GIL).
fn parkPumpThreadJoin(self: *Interpreter, rec: *ThreadRecord) value.HostError!void {
    const io = agent.engineIo();
    rec.join_mutex.unlock(io);
    pumpTasks(self);
    const stopped = if (self.stop_flag) |sf| sf.load(.monotonic) else false;
    rec.join_mutex.lockUncancelable(io);
    if (stopped)
        return self.throwError("Error", "worker terminated");
    if (threadJoinReadyLocked(rec)) return;

    stack_scan.beginPark();
    self.gc_parked.store(true, .release);
    defer {
        // Clear the frozen-peer flag under `gc_root_lock` so a collector that is
        // mid-trace of this (still-parked) interpreter finishes reading its
        // operand stack / frame slots before we resume and mutate them. Setting
        // the flag needs no lock (the store is followed only by the native wait,
        // no root mutation), but clearing it gates the transition back to running.
        self.lockGcRoots();
        self.gc_parked.store(false, .release);
        self.unlockGcRoots();
        stack_scan.endPark();
    }
    const released_gil = self.use_thread_gil;
    if (released_gil) rec.gil.release();
    bumpContention("thread_join_parks");
    const wait_start = startContentionWaitTimer();
    io_compat.conditionWaitTimeout(&rec.done_cond, io, &rec.join_mutex, .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } }) catch {};
    finishContentionWaitTimer("thread_join_wait_ns", wait_start);
    if (released_gil) {
        rec.join_mutex.unlock(io);
        rec.gil.acquire();
        rec.join_mutex.lockUncancelable(io);
    }
}

test "jsthread join park termination leaves parked state and mutex balanced" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();

    var machine = ctx.interpreter();
    var stop = std.atomic.Value(bool).init(true);
    machine.stop_flag = &stop;
    machine.gc_parked.store(false, .release);

    var rec = ThreadRecord{
        .id = 999,
        .gil = ctx.gil.?,
        .ctx = ctx,
    };
    const io = agent.engineIo();
    rec.join_mutex.lockUncancelable(io);
    try std.testing.expectError(error.Throw, parkPumpThreadJoin(&machine, &rec));

    // The helper contract is "return with join_mutex held", including error
    // unwinds. The caller can then perform its normal cleanup without racing a
    // finishing thread or double-unlocking.
    try std.testing.expect(!rec.join_mutex.tryLock());
    rec.join_mutex.unlock(io);
    try std.testing.expect(!machine.gc_parked.load(.acquire));
}

fn runHoldJob(self: *Interpreter, job: *HoldJob) value.HostError!void {
    const outer_pp = promise.promiseOf(Value.obj(job.outer)).?;
    var release_fn: ?*value.Object = null;
    if (job.cb == null) {
        job.release_state.used = false;
        job.release_state.lock = job.lock;
        const rel = try gc_mod.allocObj(self.arena);
        rel.* = .{ .native = releaseFnNative, .private_data = &job.release_state, .private_data_tag = .jsthread_release_state };
        gc_mod.barrierValue(Value.obj(rel));
        release_fn = rel;
    }
    const tid = currentTid();
    job.lock.mutex.lockUncancelable(agent.engineIo());
    if (!job.lock.locked) {
        job.lock.locked = true;
        job.lock.holder = async_holder;
    } else if (!job.lock.grant_pending or job.lock.holder != async_holder) {
        job.lock.pushFrontPending(self.arena, job) catch |err| {
            job.lock.mutex.unlock(agent.engineIo());
            return err;
        };
        job.lock.mutex.unlock(agent.engineIo());
        return;
    }
    // The grant is now DELIVERED.
    job.lock.grant_pending = false;
    if (job.cb) |cb| {
        // A live with-fn grant is async-held by the thread running fn (D12):
        // cond.asyncWait may consume it, but sync cond.wait still requires a
        // genuine sync hold.
        job.lock.async_runner = tid;
        job.lock.mutex.unlock(agent.engineIo());
        const out = self.callValueWithThis(cb, &.{}, Value.undef());
        // fn may itself have consumed the hold (same-thread asyncWait, I23);
        // only release when this grant still owns the lock.
        var job_to_enqueue: ?*HoldJob = null;
        job.lock.mutex.lockUncancelable(agent.engineIo());
        if (job.lock.locked and job.lock.async_runner == tid) {
            job.lock.async_runner = 0;
            job_to_enqueue = lockReleaseLocked(job.lock); // implicit release, throw or not
        }
        job.lock.mutex.unlock(agent.engineIo());
        if (job_to_enqueue) |next| enqueueHoldJob(self, next) catch {};
        if (out) |v| {
            try promise.resolve(self, outer_pp, v);
        } else |err| {
            if (err != error.Throw) return err;
            const reason = self.exception;
            self.exception = Value.undef();
            try promise.reject(self, outer_pp, reason);
        }
        return;
    }
    // no-fn arity: resolve with a once-only release() function.
    job.lock.active_release = &job.release_state;
    job.lock.mutex.unlock(agent.engineIo());
    try promise.resolve(self, outer_pp, Value.obj(release_fn.?));
    if (job.condition_async_reacquire) bumpContention("condition_async_settled");
}

fn releaseFnNative(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const native = self.active_native orelse return Value.undef();
    const st: *ReleaseState = @ptrCast(@alignCast(native.private_data.?));
    var already_used = false;
    var job_to_enqueue: ?*HoldJob = null;
    st.lock.mutex.lockUncancelable(agent.engineIo());
    if (st.used) {
        already_used = true;
    } else {
        st.used = true;
        if (st.lock.active_release == st) st.lock.active_release = null;
        job_to_enqueue = lockReleaseLocked(st.lock);
    }
    st.lock.mutex.unlock(agent.engineIo());
    if (already_used) return self.throwError("Error", "Lock release function called more than once");
    if (job_to_enqueue) |job| enqueueHoldJob(self, job) catch {};
    return Value.undef();
}

/// `Lock.prototype.asyncHold(fn?)`.
fn lockAsyncHoldFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.asyncHold called on incompatible receiver");
    const cb = if (args.len > 0) args[0] else Value.undef();
    if (!cb.isUndefined() and !cb.isCallable())
        return self.throwError("TypeError", "Lock.prototype.asyncHold requires a callable argument when one is provided");
    const outer = try promise.newPromise(self);
    const job = try self.arena.create(HoldJob);
    job.* = .{ .lock = rec, .outer = outer, .cb = if (cb.isUndefined()) null else cb, .release_state = .{ .lock = rec } };
    barrierHoldJob(job);
    var enqueue_now = false;
    rec.mutex.lockUncancelable(agent.engineIo());
    if (rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid())) {
        rec.mutex.unlock(agent.engineIo());
        return self.throwError("Error", "Lock is not recursive");
    }
    if (!rec.locked and rec.sync_waiting == 0) {
        rec.locked = true; // the grant happens at registration (5.5a)
        rec.holder = async_holder;
        rec.grant_pending = true;
        enqueue_now = true;
    } else {
        bumpContention("async_hold_queued");
        rec.appendPending(self.arena, job) catch |err| {
            rec.mutex.unlock(agent.engineIo());
            return err;
        };
    }
    rec.mutex.unlock(agent.engineIo());
    if (enqueue_now) try enqueueHoldJob(self, job);
    return Value.obj(outer);
}

const AsyncCondWaiter = struct { lock: *LockRecord, outer: *value.Object };

/// `Condition.prototype.asyncWait(lock)` — releases the lock, parks as an
/// async waiter; the promise resolves holding the lock again.
fn condAsyncWaitFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.asyncWait called on incompatible receiver");
    const lock = recOf(LockRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Condition.prototype.asyncWait requires a Lock argument");
    // 4.3(b) hold-state rules: an UNDELIVERED grant is not held; a delivered
    // no-fn grant is consumable from anywhere (poisoning its release()); a
    // delivered with-fn grant or sync hold is held only for its own thread.
    lock.mutex.lockUncancelable(agent.engineIo());
    const held = lock.locked and !lock.grant_pending and
        (lock.active_release != null or lock.async_runner == currentTid() or lock.holder == currentTid());
    if (!held) {
        lock.mutex.unlock(agent.engineIo());
        return self.throwError("TypeError", "Condition.prototype.asyncWait requires the lock to be held");
    }
    lock.mutex.unlock(agent.engineIo());
    const outer = try promise.newPromise(self);
    const w = try self.arena.create(AsyncCondWaiter);
    w.* = .{ .lock = lock, .outer = outer };
    const cond_owner: ?*anyopaque = if (rec.owner) |o| @ptrCast(o) else null;
    gc_mod.barrierCellFrom(cond_owner, @ptrCast(outer));
    gc_mod.barrierCellFrom(cond_owner, if (lock.owner) |o| @ptrCast(o) else null);
    const io = agent.engineIo();
    rec.mutex.lockUncancelable(io);
    lock.mutex.lockUncancelable(io);
    var job_to_enqueue: ?*HoldJob = null;
    if (!lock.locked or lock.grant_pending) {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return self.throwError("TypeError", "Condition.prototype.asyncWait requires the lock to be held");
    }
    if (lock.active_release) |st| {
        st.used = true; // consume: the original release() now throws
        lock.active_release = null;
    } else if (lock.async_runner == currentTid()) {
        lock.async_runner = 0;
    } else if (lock.holder != currentTid()) {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return self.throwError("TypeError", "Condition.prototype.asyncWait requires the lock to be held");
    }
    rec.appendWaiter(self.arena, .{ .asynchronous = w }) catch |err| {
        lock.mutex.unlock(io);
        rec.mutex.unlock(io);
        return err;
    };
    bumpContention("condition_async_waits");
    job_to_enqueue = lockReleaseLocked(lock);
    lock.mutex.unlock(io);
    rec.mutex.unlock(io);
    if (job_to_enqueue) |job| enqueueHoldJob(self, job) catch {};
    return Value.obj(outer);
}

/// Notify-side wake of an async cond waiter: the wake is a no-fn asyncHold
/// grant — the promise resolves holding the lock again, with a release()
/// function (the corpus consumes `p.then(release => ...)`).
fn createAsyncCondReacquireJob(self: *Interpreter, w: *AsyncCondWaiter) ?*HoldJob {
    const job = self.arena.create(HoldJob) catch return null;
    job.* = .{ .lock = w.lock, .outer = w.outer, .cb = null, .release_state = .{ .lock = w.lock }, .condition_async_reacquire = true };
    barrierHoldJob(job);
    return job;
}

fn grantAsyncCondReacquireLocked(lock: *LockRecord, arena: std.mem.Allocator, job: *HoldJob) bool {
    if (!lock.locked and lock.sync_waiting == 0) {
        lock.locked = true;
        lock.holder = async_holder;
        lock.grant_pending = true;
        return true;
    }
    lock.appendPending(arena, job) catch return false;
    return false;
}

fn wakeAsyncCondWaiters(self: *Interpreter, entries: []const CondEntry) void {
    var batch: [256]*HoldJob = undefined;
    var ready_batch: [256]*HoldJob = undefined;
    var ready_len: usize = 0;
    var i: usize = 0;
    const io = agent.engineIo();
    while (i < entries.len) {
        const first = switch (entries[i]) {
            .sync => {
                i += 1;
                continue;
            },
            .asynchronous => |w| w,
        };
        const lock = first.lock;
        var batch_len: usize = 0;
        while (i < entries.len and batch_len < batch.len) {
            const w = switch (entries[i]) {
                .sync => break,
                .asynchronous => |w| w,
            };
            if (w.lock != lock) break;
            if (createAsyncCondReacquireJob(self, w)) |job| {
                batch[batch_len] = job;
                batch_len += 1;
            }
            i += 1;
        }
        if (batch_len == 0) continue;

        var ready: ?*HoldJob = null;
        lock.mutex.lockUncancelable(io);
        for (batch[0..batch_len]) |job| {
            if (grantAsyncCondReacquireLocked(lock, self.arena, job))
                ready = job;
        }
        lock.mutex.unlock(io);
        if (ready) |job| {
            ready_batch[ready_len] = job;
            ready_len += 1;
            if (ready_len == ready_batch.len) {
                enqueueHoldJobs(self, ready_batch[0..ready_len]) catch {};
                ready_len = 0;
            }
        }
    }
    if (ready_len > 0) enqueueHoldJobs(self, ready_batch[0..ready_len]) catch {};
}
