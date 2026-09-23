//! Typed creation boundary for every OS thread the production engine owns.
//!
//! The boundary owns admission, lifecycle telemetry, and runnable/blocked
//! state. A process-wide slot budget bounds how many typed threads may be
//! runnable at once; blocked threads release their slot and reacquire one
//! before resuming.

const std = @import("std");
const engine_io = @import("engine_io.zig");

pub const Kind = enum {
    test262_agent,
    concurrent_gc_marker,
    javascript_thread,
    script_worker,
    module_worker,
    execution_watchdog,
};

pub const kind_count = std.meta.fieldNames(Kind).len;

pub const Priority = enum {
    safety,
    foreground,
    background,
};

pub const priority_count = std.meta.fieldNames(Priority).len;
pub const priority_weights: [priority_count]u64 = .{ 4, 2, 1 };

pub const InternalWorkKind = enum {
    native_compilation,
    wasm_compilation,
};

pub const internal_work_kind_count = std.meta.fieldNames(InternalWorkKind).len;

const priority_schedule = [_]Priority{
    .safety,
    .safety,
    .safety,
    .safety,
    .foreground,
    .foreground,
    .background,
};

fn priorityFor(kind: Kind) Priority {
    return switch (kind) {
        .concurrent_gc_marker, .execution_watchdog => .safety,
        .javascript_thread, .test262_agent => .foreground,
        .script_worker, .module_worker => .background,
    };
}

const Counters = struct {
    admission_lock: std.atomic.Mutex = .unlocked,
    attempts: std.atomic.Value(u64) = .init(0),
    starts: std.atomic.Value(u64) = .init(0),
    completions: std.atomic.Value(u64) = .init(0),
    spawn_failures: std.atomic.Value(u64) = .init(0),
    admission_rejections: std.atomic.Value(u64) = .init(0),
    in_flight_attempts: std.atomic.Value(u64) = .init(0),
    admitted_threads: std.atomic.Value(u64) = .init(0),
    admitted_stack_bytes: std.atomic.Value(u64) = .init(0),
    max_threads: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    max_configured_stack_bytes: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    live: std.atomic.Value(u64) = .init(0),
    peak_live: std.atomic.Value(u64) = .init(0),
    runnable: std.atomic.Value(u64) = .init(0),
    peak_runnable: std.atomic.Value(u64) = .init(0),
    blocked: std.atomic.Value(u64) = .init(0),
    peak_blocked: std.atomic.Value(u64) = .init(0),
    block_transitions: std.atomic.Value(u64) = .init(0),
    runnable_transitions: std.atomic.Value(u64) = .init(0),
    configured_stack_bytes: std.atomic.Value(u64) = .init(0),
    peak_configured_stack_bytes: std.atomic.Value(u64) = .init(0),
};

var counters: [kind_count]Counters = @splat(.{});
var mutation_writers: std.atomic.Value(u64) = .init(0);
var mutation_generation: std.atomic.Value(u64) = .init(0);

const SlotWaiter = struct {
    kind: Kind,
    priority: Priority,
    ticket: u64,
    cond: std.Io.Condition = .init,
    next: ?*SlotWaiter = null,
    granted: bool = false,
};

const WorkAdmission = enum {
    typed_slot_reuse,
    nested_reuse,
    host_reserved,
    general_slot,
};

const WorkWaiter = struct {
    kind: InternalWorkKind,
    ticket: u64,
    wait_started_ns: i96,
    cond: std.Io.Condition = .init,
    next: ?*WorkWaiter = null,
    granted: ?WorkAdmission = null,
};

const WorkCounters = struct {
    requests: std.atomic.Value(u64) = .init(0),
    starts: std.atomic.Value(u64) = .init(0),
    completions: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(u64) = .init(0),
    peak_active: std.atomic.Value(u64) = .init(0),
    typed_slot_reuses: std.atomic.Value(u64) = .init(0),
    nested_reuses: std.atomic.Value(u64) = .init(0),
    host_reserved_admissions: std.atomic.Value(u64) = .init(0),
    general_slot_admissions: std.atomic.Value(u64) = .init(0),
    waiters: std.atomic.Value(u64) = .init(0),
    peak_waiters: std.atomic.Value(u64) = .init(0),
    waits: std.atomic.Value(u64) = .init(0),
    wait_ns: std.atomic.Value(u64) = .init(0),
    wait_ns_max: std.atomic.Value(u64) = .init(0),
    last_grant_ticket: std.atomic.Value(u64) = .init(0),
};

var work_counters: [internal_work_kind_count]WorkCounters = @splat(.{});

const PriorityCounters = struct {
    waiters: std.atomic.Value(u64) = .init(0),
    peak_waiters: std.atomic.Value(u64) = .init(0),
    grants: std.atomic.Value(u64) = .init(0),
    last_grant_ticket: std.atomic.Value(u64) = .init(0),
};

const Coordinator = struct {
    mutex: std.Io.Mutex = .init,
    initialized: std.atomic.Value(bool) = .init(false),
    automatic: std.atomic.Value(bool) = .init(true),
    host_logical_cpus: std.atomic.Value(u64) = .init(1),
    automatic_host_reservation: std.atomic.Value(u64) = .init(0),
    configured_max_runnable_threads: std.atomic.Value(u64) = .init(0),
    effective_max_runnable_threads: std.atomic.Value(u64) = .init(1),
    active_slots: std.atomic.Value(u64) = .init(0),
    peak_active_slots: std.atomic.Value(u64) = .init(0),
    internal_work_general_active: std.atomic.Value(u64) = .init(0),
    peak_internal_work_general_active: std.atomic.Value(u64) = .init(0),
    host_work_reserved_active: std.atomic.Value(u64) = .init(0),
    peak_host_work_reserved_active: std.atomic.Value(u64) = .init(0),
    slot_waiters: std.atomic.Value(u64) = .init(0),
    peak_slot_waiters: std.atomic.Value(u64) = .init(0),
    slot_waits: std.atomic.Value(u64) = .init(0),
    priority: [priority_count]PriorityCounters = @splat(.{}),
    wait_heads: [priority_count]?*SlotWaiter = @splat(null),
    wait_tails: [priority_count]?*SlotWaiter = @splat(null),
    work_head: ?*WorkWaiter = null,
    work_tail: ?*WorkWaiter = null,
    next_ticket: u64 = 0,
    schedule_cursor: usize = 0,
};

var coordinator: Coordinator = .{};

pub const ResourceSnapshot = struct {
    attempts: u64,
    starts: u64,
    completions: u64,
    spawn_failures: u64,
    admission_rejections: u64,
    in_flight_attempts: u64,
    admitted_threads: u64,
    admitted_stack_bytes: u64,
    max_threads: u64,
    max_configured_stack_bytes: u64,
    live: u64,
    peak_live: u64,
    runnable: u64,
    peak_runnable: u64,
    blocked: u64,
    peak_blocked: u64,
    block_transitions: u64,
    runnable_transitions: u64,
    configured_stack_bytes: u64,
    peak_configured_stack_bytes: u64,
};

pub const Limits = struct {
    max_threads: u64 = std.math.maxInt(u64),
    max_configured_stack_bytes: u64 = std.math.maxInt(u64),
};

pub const SchedulerLimits = struct {
    /// `null` derives a finite limit from host capacity. Numeric values are
    /// exact: zero pauses entry/resume and `maxInt(u64)` is explicit unlimited.
    max_runnable_threads: ?u64 = null,
};

pub const SchedulerPolicy = enum { automatic, fixed };

pub const PrioritySnapshot = struct {
    weight: u64,
    waiters: u64,
    peak_waiters: u64,
    grants: u64,
    last_grant_ticket: u64,
};

pub const InternalWorkSnapshot = struct {
    priority: Priority,
    requests: u64,
    starts: u64,
    completions: u64,
    active: u64,
    peak_active: u64,
    typed_slot_reuses: u64,
    nested_reuses: u64,
    host_reserved_admissions: u64,
    general_slot_admissions: u64,
    waiters: u64,
    peak_waiters: u64,
    waits: u64,
    wait_ns: u64,
    wait_ns_max: u64,
    last_grant_ticket: u64,
};

pub const SchedulerSnapshot = struct {
    policy: SchedulerPolicy,
    host_logical_cpus: u64,
    automatic_host_reservation: u64,
    configured_max_runnable_threads: ?u64,
    effective_max_runnable_threads: u64,
    active_slots: u64,
    peak_active_slots: u64,
    internal_work_general_active: u64,
    peak_internal_work_general_active: u64,
    host_work_reserved_active: u64,
    peak_host_work_reserved_active: u64,
    slot_waiters: u64,
    peak_slot_waiters: u64,
    slot_waits: u64,
    priorities: [priority_count]PrioritySnapshot,

    pub fn priority(self: *const SchedulerSnapshot, value: Priority) PrioritySnapshot {
        return self.priorities[@backingInt(value)];
    }
};

pub const Snapshot = struct {
    schema_version: u32 = 7,
    generation: u64,
    scheduler: SchedulerSnapshot,
    resources: [kind_count]ResourceSnapshot,
    internal_work: [internal_work_kind_count]InternalWorkSnapshot,

    pub fn resource(self: *const Snapshot, kind: Kind) ResourceSnapshot {
        return self.resources[@backingInt(kind)];
    }

    pub fn runnableTotal(self: *const Snapshot) u64 {
        var total: u64 = 0;
        for (self.resources) |resource_state| total += resource_state.runnable;
        return total;
    }

    pub fn work(self: *const Snapshot, kind: InternalWorkKind) InternalWorkSnapshot {
        return self.internal_work[@backingInt(kind)];
    }

    pub fn scheduledGeneralTotal(self: *const Snapshot) u64 {
        return self.runnableTotal() + self.scheduler.internal_work_general_active;
    }

    pub fn scheduledCpuTotal(self: *const Snapshot) u64 {
        return self.scheduledGeneralTotal() + self.scheduler.host_work_reserved_active;
    }
};

const ThreadState = struct {
    kind: Kind,
    blocking_depth: usize = 0,
};

threadlocal var current_thread: ?ThreadState = null;
threadlocal var internal_work_depth: usize = 0;

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

fn workState(kind: InternalWorkKind) *WorkCounters {
    return &work_counters[@backingInt(kind)];
}

fn recordWorkRequest(kind: InternalWorkKind) void {
    _ = workState(kind).requests.fetchAdd(1, .monotonic);
}

fn recordWorkStart(kind: InternalWorkKind, admission: WorkAdmission) void {
    const state = workState(kind);
    _ = state.starts.fetchAdd(1, .monotonic);
    const active = state.active.fetchAdd(1, .monotonic) + 1;
    recordPeak(&state.peak_active, active);
    switch (admission) {
        .typed_slot_reuse => _ = state.typed_slot_reuses.fetchAdd(1, .monotonic),
        .nested_reuse => _ = state.nested_reuses.fetchAdd(1, .monotonic),
        .host_reserved => _ = state.host_reserved_admissions.fetchAdd(1, .monotonic),
        .general_slot => _ = state.general_slot_admissions.fetchAdd(1, .monotonic),
    }
}

fn recordWorkCompletion(kind: InternalWorkKind) void {
    const state = workState(kind);
    _ = state.completions.fetchAdd(1, .monotonic);
    const active = state.active.fetchSub(1, .monotonic);
    std.debug.assert(active > 0);
}

fn beginWorkWaitState(kind: InternalWorkKind) void {
    const state = workState(kind);
    const waiters = state.waiters.fetchAdd(1, .monotonic) + 1;
    recordPeak(&state.peak_waiters, waiters);
    _ = state.waits.fetchAdd(1, .monotonic);
}

fn finishWorkWaitState(kind: InternalWorkKind, ticket: u64, elapsed_ns: u64, admission: WorkAdmission) void {
    const state = workState(kind);
    const waiters = state.waiters.fetchSub(1, .monotonic);
    std.debug.assert(waiters > 0);
    _ = state.wait_ns.fetchAdd(elapsed_ns, .monotonic);
    recordPeak(&state.wait_ns_max, elapsed_ns);
    const previous_ticket = state.last_grant_ticket.swap(ticket, .monotonic);
    std.debug.assert(ticket > previous_ticket);
    recordWorkStart(kind, admission);
}

fn lockAdmission(state: *Counters) void {
    while (!state.admission_lock.tryLock()) std.atomic.spinLoopHint();
}

fn tryAdmit(kind: Kind, stack_bytes: usize) bool {
    const state = &counters[@backingInt(kind)];
    lockAdmission(state);
    defer state.admission_lock.unlock();
    beginMutation();
    defer finishMutation();
    _ = state.attempts.fetchAdd(1, .monotonic);
    const admitted_threads = state.admitted_threads.load(.monotonic);
    const admitted_stack = state.admitted_stack_bytes.load(.monotonic);
    const max_threads = state.max_threads.load(.monotonic);
    const max_stack = state.max_configured_stack_bytes.load(.monotonic);
    const stack: u64 = @intCast(stack_bytes);
    if (admitted_threads >= max_threads or admitted_stack > max_stack or stack > max_stack - admitted_stack) {
        _ = state.admission_rejections.fetchAdd(1, .monotonic);
        return false;
    }
    _ = state.admitted_threads.fetchAdd(1, .monotonic);
    _ = state.admitted_stack_bytes.fetchAdd(stack, .monotonic);
    _ = state.in_flight_attempts.fetchAdd(1, .monotonic);
    return true;
}

fn recordStartState(kind: Kind, stack_bytes: usize, runnable_state: bool) void {
    const state = &counters[@backingInt(kind)];
    const pending = state.in_flight_attempts.fetchSub(1, .monotonic);
    std.debug.assert(pending > 0);
    _ = state.starts.fetchAdd(1, .monotonic);
    const live = state.live.fetchAdd(1, .monotonic) + 1;
    recordPeak(&state.peak_live, live);
    if (runnable_state) {
        const runnable = state.runnable.fetchAdd(1, .monotonic) + 1;
        recordPeak(&state.peak_runnable, runnable);
    } else {
        const blocked = state.blocked.fetchAdd(1, .monotonic) + 1;
        recordPeak(&state.peak_blocked, blocked);
        _ = state.block_transitions.fetchAdd(1, .monotonic);
    }
    const stack = state.configured_stack_bytes.fetchAdd(stack_bytes, .monotonic) + stack_bytes;
    recordPeak(&state.peak_configured_stack_bytes, stack);
}

fn releaseAdmission(state: *Counters, stack_bytes: usize) void {
    const admitted = state.admitted_threads.fetchSub(1, .monotonic);
    const stack = state.admitted_stack_bytes.fetchSub(stack_bytes, .monotonic);
    std.debug.assert(admitted > 0 and stack >= stack_bytes);
}

fn recordFailure(kind: Kind, stack_bytes: usize) void {
    beginMutation();
    defer finishMutation();
    const state = &counters[@backingInt(kind)];
    const pending = state.in_flight_attempts.fetchSub(1, .monotonic);
    std.debug.assert(pending > 0);
    _ = state.spawn_failures.fetchAdd(1, .monotonic);
    releaseAdmission(state, stack_bytes);
}

fn recordCompletionState(kind: Kind, stack_bytes: usize) void {
    const state = &counters[@backingInt(kind)];
    _ = state.completions.fetchAdd(1, .monotonic);
    const live = state.live.fetchSub(1, .monotonic);
    const runnable = state.runnable.fetchSub(1, .monotonic);
    const stack = state.configured_stack_bytes.fetchSub(stack_bytes, .monotonic);
    std.debug.assert(live > 0 and runnable > 0 and stack >= stack_bytes);
    releaseAdmission(state, stack_bytes);
}

fn recordBlockedState(kind: Kind) void {
    const state = &counters[@backingInt(kind)];
    const runnable = state.runnable.fetchSub(1, .monotonic);
    std.debug.assert(runnable > 0);
    const blocked = state.blocked.fetchAdd(1, .monotonic) + 1;
    recordPeak(&state.peak_blocked, blocked);
    _ = state.block_transitions.fetchAdd(1, .monotonic);
}

fn recordRunnableState(kind: Kind) void {
    const state = &counters[@backingInt(kind)];
    const blocked = state.blocked.fetchSub(1, .monotonic);
    std.debug.assert(blocked > 0);
    const runnable = state.runnable.fetchAdd(1, .monotonic) + 1;
    recordPeak(&state.peak_runnable, runnable);
    _ = state.runnable_transitions.fetchAdd(1, .monotonic);
}

const AutomaticPolicy = struct {
    host_logical_cpus: u64,
    host_reservation: u64,
    effective_max_runnable_threads: u64,
};

fn automaticPolicy(host_logical_cpus: u64) AutomaticPolicy {
    std.debug.assert(host_logical_cpus >= 1);
    const reservation: u64 = if (host_logical_cpus > 1) 1 else 0;
    return .{
        .host_logical_cpus = host_logical_cpus,
        .host_reservation = reservation,
        .effective_max_runnable_threads = host_logical_cpus - reservation,
    };
}

fn detectAutomaticPolicy() AutomaticPolicy {
    const detected: u64 = @intCast(std.Thread.getCpuCount() catch 1);
    return automaticPolicy(detected);
}

fn storeAutomaticPolicyState(policy: AutomaticPolicy) void {
    coordinator.automatic.store(true, .monotonic);
    coordinator.host_logical_cpus.store(policy.host_logical_cpus, .monotonic);
    coordinator.automatic_host_reservation.store(policy.host_reservation, .monotonic);
    coordinator.configured_max_runnable_threads.store(0, .monotonic);
    coordinator.effective_max_runnable_threads.store(policy.effective_max_runnable_threads, .monotonic);
}

fn ensureCoordinatorInitializedLocked() void {
    if (coordinator.initialized.load(.monotonic)) return;
    beginMutation();
    storeAutomaticPolicyState(detectAutomaticPolicy());
    finishMutation();
    coordinator.initialized.store(true, .release);
}

fn ensureCoordinatorInitialized() void {
    if (coordinator.initialized.load(.acquire)) return;
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    ensureCoordinatorInitializedLocked();
    coordinator.mutex.unlock(io);
}

fn loadScheduler() SchedulerSnapshot {
    const automatic = coordinator.automatic.load(.acquire);
    var result = SchedulerSnapshot{
        .policy = if (automatic) .automatic else .fixed,
        .host_logical_cpus = coordinator.host_logical_cpus.load(.acquire),
        .automatic_host_reservation = coordinator.automatic_host_reservation.load(.acquire),
        .configured_max_runnable_threads = if (automatic) null else coordinator.configured_max_runnable_threads.load(.acquire),
        .effective_max_runnable_threads = coordinator.effective_max_runnable_threads.load(.acquire),
        .active_slots = coordinator.active_slots.load(.acquire),
        .peak_active_slots = coordinator.peak_active_slots.load(.acquire),
        .internal_work_general_active = coordinator.internal_work_general_active.load(.acquire),
        .peak_internal_work_general_active = coordinator.peak_internal_work_general_active.load(.acquire),
        .host_work_reserved_active = coordinator.host_work_reserved_active.load(.acquire),
        .peak_host_work_reserved_active = coordinator.peak_host_work_reserved_active.load(.acquire),
        .slot_waiters = coordinator.slot_waiters.load(.acquire),
        .peak_slot_waiters = coordinator.peak_slot_waiters.load(.acquire),
        .slot_waits = coordinator.slot_waits.load(.acquire),
        .priorities = undefined,
    };
    for (&coordinator.priority, 0..) |*state, index| {
        result.priorities[index] = .{
            .weight = priority_weights[index],
            .waiters = state.waiters.load(.acquire),
            .peak_waiters = state.peak_waiters.load(.acquire),
            .grants = state.grants.load(.acquire),
            .last_grant_ticket = state.last_grant_ticket.load(.acquire),
        };
    }
    return result;
}

fn slotAvailableLocked() bool {
    return coordinator.active_slots.load(.monotonic) < coordinator.effective_max_runnable_threads.load(.monotonic);
}

fn reserveSlotState() void {
    const active = coordinator.active_slots.fetchAdd(1, .monotonic) + 1;
    recordPeak(&coordinator.peak_active_slots, active);
}

fn releaseSlotState() void {
    const active = coordinator.active_slots.fetchSub(1, .monotonic);
    std.debug.assert(active > 0);
}

fn reserveGeneralWorkSlotState() void {
    reserveSlotState();
    const active = coordinator.internal_work_general_active.fetchAdd(1, .monotonic) + 1;
    recordPeak(&coordinator.peak_internal_work_general_active, active);
}

fn releaseGeneralWorkSlotState() void {
    const active = coordinator.internal_work_general_active.fetchSub(1, .monotonic);
    std.debug.assert(active > 0);
    releaseSlotState();
}

fn hostWorkReservationAvailableLocked() bool {
    if (!coordinator.automatic.load(.monotonic)) return false;
    return coordinator.host_work_reserved_active.load(.monotonic) <
        coordinator.automatic_host_reservation.load(.monotonic);
}

fn reserveHostWorkState() void {
    const active = coordinator.host_work_reserved_active.fetchAdd(1, .monotonic) + 1;
    recordPeak(&coordinator.peak_host_work_reserved_active, active);
}

fn releaseHostWorkState() void {
    const active = coordinator.host_work_reserved_active.fetchSub(1, .monotonic);
    std.debug.assert(active > 0);
}

fn beginSchedulerWaitState() void {
    const waiters = coordinator.slot_waiters.fetchAdd(1, .monotonic) + 1;
    recordPeak(&coordinator.peak_slot_waiters, waiters);
    _ = coordinator.slot_waits.fetchAdd(1, .monotonic);
}

fn beginSlotWaitState(priority: Priority) void {
    beginSchedulerWaitState();
    const priority_state = &coordinator.priority[@backingInt(priority)];
    const priority_waiters = priority_state.waiters.fetchAdd(1, .monotonic) + 1;
    recordPeak(&priority_state.peak_waiters, priority_waiters);
}

fn finishSchedulerWaitState() void {
    const waiters = coordinator.slot_waiters.fetchSub(1, .monotonic);
    std.debug.assert(waiters > 0);
}

fn finishSlotWaitState(priority: Priority, ticket: u64) void {
    finishSchedulerWaitState();
    const priority_state = &coordinator.priority[@backingInt(priority)];
    const priority_waiters = priority_state.waiters.fetchSub(1, .monotonic);
    std.debug.assert(priority_waiters > 0);
    _ = priority_state.grants.fetchAdd(1, .monotonic);
    const previous_ticket = priority_state.last_grant_ticket.swap(ticket, .monotonic);
    std.debug.assert(ticket > previous_ticket);
}

fn hasQueuedWaitersLocked() bool {
    return coordinator.slot_waiters.load(.monotonic) != 0;
}

fn enqueueWaiterLocked(waiter: *SlotWaiter) void {
    coordinator.next_ticket += 1;
    waiter.ticket = coordinator.next_ticket;
    const index = @backingInt(waiter.priority);
    if (coordinator.wait_tails[index]) |tail| {
        tail.next = waiter;
    } else {
        coordinator.wait_heads[index] = waiter;
    }
    coordinator.wait_tails[index] = waiter;
    beginMutation();
    beginSlotWaitState(waiter.priority);
    finishMutation();
}

fn enqueueWorkWaiterLocked(waiter: *WorkWaiter) void {
    coordinator.next_ticket += 1;
    waiter.ticket = coordinator.next_ticket;
    waiter.wait_started_ns = std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds;
    if (coordinator.work_tail) |tail| {
        tail.next = waiter;
    } else {
        coordinator.work_head = waiter;
    }
    coordinator.work_tail = waiter;
    beginMutation();
    recordWorkRequest(waiter.kind);
    beginSchedulerWaitState();
    beginWorkWaitState(waiter.kind);
    finishMutation();
}

fn priorityQueuedLocked(priority: Priority) bool {
    if (coordinator.wait_heads[@backingInt(priority)] != null) return true;
    return priority == .background and coordinator.work_head != null;
}

fn choosePriorityLocked() ?Priority {
    for (0..priority_schedule.len) |_| {
        const priority = priority_schedule[coordinator.schedule_cursor];
        coordinator.schedule_cursor = (coordinator.schedule_cursor + 1) % priority_schedule.len;
        if (priorityQueuedLocked(priority)) return priority;
    }
    return null;
}

fn popWorkWaiterLocked() *WorkWaiter {
    const waiter = coordinator.work_head orelse unreachable;
    coordinator.work_head = waiter.next;
    if (waiter.next == null) coordinator.work_tail = null;
    waiter.next = null;
    return waiter;
}

fn grantWorkWaiterLocked(waiter: *WorkWaiter, admission: WorkAdmission, io: std.Io) void {
    const elapsed: u64 = @intCast(@max(std.Io.Timestamp.now(io, .awake).nanoseconds - waiter.wait_started_ns, 0));
    beginMutation();
    finishSchedulerWaitState();
    switch (admission) {
        .host_reserved => reserveHostWorkState(),
        .general_slot => reserveGeneralWorkSlotState(),
        else => unreachable,
    }
    finishWorkWaitState(waiter.kind, waiter.ticket, elapsed, admission);
    finishMutation();
    waiter.granted = admission;
    waiter.cond.signal(io);
}

fn dispatchReservedWorkLocked(io: std.Io) void {
    while (hostWorkReservationAvailableLocked() and coordinator.work_head != null)
        grantWorkWaiterLocked(popWorkWaiterLocked(), .host_reserved, io);
}

fn grantThreadWaiterLocked(priority: Priority, io: std.Io) void {
    const index = @backingInt(priority);
    const waiter = coordinator.wait_heads[index] orelse unreachable;
    coordinator.wait_heads[index] = waiter.next;
    if (waiter.next == null) coordinator.wait_tails[index] = null;
    waiter.next = null;

    beginMutation();
    finishSlotWaitState(priority, waiter.ticket);
    reserveSlotState();
    recordRunnableState(waiter.kind);
    finishMutation();
    waiter.granted = true;
    waiter.cond.signal(io);
}

fn dispatchSlotsLocked(io: std.Io) void {
    dispatchReservedWorkLocked(io);
    while (slotAvailableLocked() and hasQueuedWaitersLocked()) {
        const priority = choosePriorityLocked() orelse unreachable;
        const index = @backingInt(priority);
        const thread_waiter = coordinator.wait_heads[index];
        if (priority == .background) if (coordinator.work_head) |work_waiter| {
            if (thread_waiter == null or work_waiter.ticket < thread_waiter.?.ticket) {
                grantWorkWaiterLocked(popWorkWaiterLocked(), .general_slot, io);
                continue;
            }
        };
        grantThreadWaiterLocked(priority, io);
    }
}

fn waitForSlotLocked(kind: Kind, io: std.Io) void {
    var waiter = SlotWaiter{
        .kind = kind,
        .priority = priorityFor(kind),
        .ticket = 0,
    };
    enqueueWaiterLocked(&waiter);
    dispatchSlotsLocked(io);
    while (!waiter.granted) waiter.cond.waitUncancelable(io, &coordinator.mutex);
}

fn waitForWorkLocked(kind: InternalWorkKind, io: std.Io) WorkAdmission {
    var waiter = WorkWaiter{
        .kind = kind,
        .ticket = 0,
        .wait_started_ns = 0,
    };
    enqueueWorkWaiterLocked(&waiter);
    dispatchSlotsLocked(io);
    while (waiter.granted == null) waiter.cond.waitUncancelable(io, &coordinator.mutex);
    return waiter.granted.?;
}

fn admitHostWork(kind: InternalWorkKind) WorkAdmission {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    defer coordinator.mutex.unlock(io);
    ensureCoordinatorInitializedLocked();
    if (hostWorkReservationAvailableLocked() and coordinator.work_head == null) {
        beginMutation();
        recordWorkRequest(kind);
        reserveHostWorkState();
        recordWorkStart(kind, .host_reserved);
        finishMutation();
        return .host_reserved;
    }
    if (slotAvailableLocked() and !hasQueuedWaitersLocked()) {
        beginMutation();
        recordWorkRequest(kind);
        reserveGeneralWorkSlotState();
        recordWorkStart(kind, .general_slot);
        finishMutation();
        return .general_slot;
    }
    return waitForWorkLocked(kind, io);
}

fn startThread(kind: Kind, stack_bytes: usize) void {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    defer coordinator.mutex.unlock(io);
    ensureCoordinatorInitializedLocked();
    if (slotAvailableLocked() and !hasQueuedWaitersLocked()) {
        beginMutation();
        reserveSlotState();
        recordStartState(kind, stack_bytes, true);
        finishMutation();
        return;
    }

    beginMutation();
    recordStartState(kind, stack_bytes, false);
    finishMutation();
    waitForSlotLocked(kind, io);
}

fn blockThread(kind: Kind) void {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    beginMutation();
    recordBlockedState(kind);
    releaseSlotState();
    finishMutation();
    dispatchSlotsLocked(io);
    coordinator.mutex.unlock(io);
}

fn resumeThread(kind: Kind) void {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    defer coordinator.mutex.unlock(io);
    if (!slotAvailableLocked() or hasQueuedWaitersLocked()) {
        waitForSlotLocked(kind, io);
        return;
    }
    beginMutation();
    reserveSlotState();
    recordRunnableState(kind);
    finishMutation();
}

fn tryResumeThread(kind: Kind) bool {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    defer coordinator.mutex.unlock(io);
    if (!slotAvailableLocked() or hasQueuedWaitersLocked()) return false;
    beginMutation();
    reserveSlotState();
    recordRunnableState(kind);
    finishMutation();
    return true;
}

fn completeThread(kind: Kind, stack_bytes: usize) void {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    beginMutation();
    recordCompletionState(kind, stack_bytes);
    releaseSlotState();
    finishMutation();
    dispatchSlotsLocked(io);
    coordinator.mutex.unlock(io);
}

fn loadResource(state: *const Counters) ResourceSnapshot {
    return .{
        .attempts = state.attempts.load(.acquire),
        .starts = state.starts.load(.acquire),
        .completions = state.completions.load(.acquire),
        .spawn_failures = state.spawn_failures.load(.acquire),
        .admission_rejections = state.admission_rejections.load(.acquire),
        .in_flight_attempts = state.in_flight_attempts.load(.acquire),
        .admitted_threads = state.admitted_threads.load(.acquire),
        .admitted_stack_bytes = state.admitted_stack_bytes.load(.acquire),
        .max_threads = state.max_threads.load(.acquire),
        .max_configured_stack_bytes = state.max_configured_stack_bytes.load(.acquire),
        .live = state.live.load(.acquire),
        .peak_live = state.peak_live.load(.acquire),
        .runnable = state.runnable.load(.acquire),
        .peak_runnable = state.peak_runnable.load(.acquire),
        .blocked = state.blocked.load(.acquire),
        .peak_blocked = state.peak_blocked.load(.acquire),
        .block_transitions = state.block_transitions.load(.acquire),
        .runnable_transitions = state.runnable_transitions.load(.acquire),
        .configured_stack_bytes = state.configured_stack_bytes.load(.acquire),
        .peak_configured_stack_bytes = state.peak_configured_stack_bytes.load(.acquire),
    };
}

fn loadInternalWork(state: *const WorkCounters) InternalWorkSnapshot {
    return .{
        .priority = .background,
        .requests = state.requests.load(.acquire),
        .starts = state.starts.load(.acquire),
        .completions = state.completions.load(.acquire),
        .active = state.active.load(.acquire),
        .peak_active = state.peak_active.load(.acquire),
        .typed_slot_reuses = state.typed_slot_reuses.load(.acquire),
        .nested_reuses = state.nested_reuses.load(.acquire),
        .host_reserved_admissions = state.host_reserved_admissions.load(.acquire),
        .general_slot_admissions = state.general_slot_admissions.load(.acquire),
        .waiters = state.waiters.load(.acquire),
        .peak_waiters = state.peak_waiters.load(.acquire),
        .waits = state.waits.load(.acquire),
        .wait_ns = state.wait_ns.load(.acquire),
        .wait_ns_max = state.wait_ns_max.load(.acquire),
        .last_grant_ticket = state.last_grant_ticket.load(.acquire),
    };
}

/// Coherent process-wide resource and runnable-slot state. Readers retry only
/// across short atomic mutation sections; JavaScript execution never holds a
/// telemetry or coordinator lock.
pub fn snapshot() Snapshot {
    ensureCoordinatorInitialized();
    while (true) {
        const generation = mutation_generation.load(.acquire);
        if (mutation_writers.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        var result = Snapshot{
            .generation = generation,
            .scheduler = loadScheduler(),
            .resources = undefined,
            .internal_work = undefined,
        };
        for (&counters, 0..) |*state, index| result.resources[index] = loadResource(state);
        for (&work_counters, 0..) |*state, index| result.internal_work[index] = loadInternalWork(state);
        const after_generation = mutation_generation.load(.acquire);
        const after_writers = mutation_writers.load(.acquire);
        const final_generation = mutation_generation.load(.acquire);
        if (after_writers == 0 and generation == after_generation and after_generation == final_generation)
            return result;
        std.atomic.spinLoopHint();
    }
}

/// Atomically replace one resource class's process-wide admission policy.
/// Existing threads are never terminated; a limit below current reservations
/// simply refuses new admissions until exits bring usage back under it.
pub fn setLimits(kind: Kind, limits: Limits) Limits {
    const state = &counters[@backingInt(kind)];
    lockAdmission(state);
    defer state.admission_lock.unlock();
    beginMutation();
    defer finishMutation();
    const previous = Limits{
        .max_threads = state.max_threads.load(.monotonic),
        .max_configured_stack_bytes = state.max_configured_stack_bytes.load(.monotonic),
    };
    state.max_threads.store(limits.max_threads, .monotonic);
    state.max_configured_stack_bytes.store(limits.max_configured_stack_bytes, .monotonic);
    return previous;
}

/// Atomically replace the process-wide runnable-slot policy. Lowering the
/// limit never interrupts a running thread; entries and resumes wait until
/// active use falls below the new limit. Raising the limit dispatches exactly
/// the newly available slots through the weighted priority queues.
pub fn setSchedulerLimits(limits: SchedulerLimits) SchedulerLimits {
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    defer coordinator.mutex.unlock(io);
    ensureCoordinatorInitializedLocked();
    beginMutation();
    const was_automatic = coordinator.automatic.load(.monotonic);
    const previous = SchedulerLimits{
        .max_runnable_threads = if (was_automatic) null else coordinator.configured_max_runnable_threads.load(.monotonic),
    };
    if (limits.max_runnable_threads) |fixed| {
        coordinator.automatic.store(false, .monotonic);
        coordinator.configured_max_runnable_threads.store(fixed, .monotonic);
        coordinator.effective_max_runnable_threads.store(fixed, .monotonic);
    } else {
        storeAutomaticPolicyState(detectAutomaticPolicy());
    }
    finishMutation();
    dispatchSlotsLocked(io);
    return previous;
}

/// Marks the current engine-owned thread blocked until `end` runs. Nested
/// scopes count as one outer transition. Calls from host and test threads that
/// did not enter through `spawn` are inert.
pub const BlockingScope = struct {
    active: bool,

    /// Resume without waiting for a slot. On failure the outer scope remains
    /// active, letting a condition waiter release its reacquired mutex before
    /// calling `end` and parking on the scheduler queue.
    pub fn tryEnd(scope: *BlockingScope) bool {
        if (!scope.active) return true;
        const state = if (current_thread) |*value| value else unreachable;
        std.debug.assert(state.blocking_depth > 0);
        if (state.blocking_depth > 1) {
            state.blocking_depth -= 1;
            scope.active = false;
            return true;
        }
        if (!tryResumeThread(state.kind)) return false;
        state.blocking_depth = 0;
        scope.active = false;
        return true;
    }

    pub fn end(scope: *BlockingScope) void {
        if (scope.tryEnd()) return;
        const state = if (current_thread) |*value| value else unreachable;
        std.debug.assert(state.blocking_depth == 1);
        resumeThread(state.kind);
        state.blocking_depth = 0;
        scope.active = false;
    }

    /// End a condition-wait scope while preserving the caller's mutex-held
    /// postcondition. If no slot is immediately available, release the mutex,
    /// park for a slot, then reacquire it. This prevents slot/mutex inversion.
    pub fn endWithMutex(scope: *BlockingScope, mutex: *std.Io.Mutex, io: std.Io) void {
        if (scope.tryEnd()) return;
        mutex.unlock(io);
        scope.end();
        mutex.lockUncancelable(io);
    }
};

pub fn beginBlocking() BlockingScope {
    const state = if (current_thread) |*value| value else return .{ .active = false };
    if (state.blocking_depth == 0) blockThread(state.kind);
    state.blocking_depth += 1;
    return .{ .active = true };
}

/// Synchronous internal CPU work remains on its requesting thread. A typed
/// engine thread reuses its runnable slot; an untyped host request uses the
/// automatic host reservation or joins the background queue for a general
/// slot. Nested internal work reuses the outer admission.
pub const InternalWorkScope = struct {
    kind: InternalWorkKind,
    admission: WorkAdmission,
    active: bool = true,

    pub fn end(scope: *InternalWorkScope) void {
        if (!scope.active) return;
        std.debug.assert(internal_work_depth > 0);
        internal_work_depth -= 1;
        if (scope.admission == .host_reserved or scope.admission == .general_slot) {
            std.debug.assert(internal_work_depth == 0);
            const io = engine_io.get();
            coordinator.mutex.lockUncancelable(io);
            beginMutation();
            recordWorkCompletion(scope.kind);
            if (scope.admission == .host_reserved)
                releaseHostWorkState()
            else
                releaseGeneralWorkSlotState();
            finishMutation();
            dispatchSlotsLocked(io);
            coordinator.mutex.unlock(io);
        } else {
            beginMutation();
            recordWorkCompletion(scope.kind);
            finishMutation();
        }
        scope.active = false;
    }
};

pub fn beginInternalWork(kind: InternalWorkKind) InternalWorkScope {
    if (internal_work_depth != 0) {
        internal_work_depth += 1;
        beginMutation();
        recordWorkRequest(kind);
        recordWorkStart(kind, .nested_reuse);
        finishMutation();
        return .{ .kind = kind, .admission = .nested_reuse };
    }
    if (current_thread) |state| {
        std.debug.assert(state.blocking_depth == 0);
        internal_work_depth = 1;
        beginMutation();
        recordWorkRequest(kind);
        recordWorkStart(kind, .typed_slot_reuse);
        finishMutation();
        return .{ .kind = kind, .admission = .typed_slot_reuse };
    }
    const admission = admitHostWork(kind);
    internal_work_depth = 1;
    return .{ .kind = kind, .admission = admission };
}

pub fn spawn(
    comptime kind: Kind,
    config: std.Thread.SpawnConfig,
    comptime function: anytype,
    args: anytype,
) !std.Thread {
    if (!tryAdmit(kind, config.stack_size)) return error.ThreadQuotaExceeded;
    const Runner = struct {
        fn run(call_args: @TypeOf(args), stack_bytes: usize) void {
            std.debug.assert(current_thread == null);
            current_thread = .{ .kind = kind };
            startThread(kind, stack_bytes);
            defer {
                const state = current_thread orelse unreachable;
                std.debug.assert(state.kind == kind and state.blocking_depth == 0);
                completeThread(kind, stack_bytes);
                current_thread = null;
            }
            @call(.auto, function, call_args);
        }
    };
    return std.Thread.spawn(config, Runner.run, .{ args, config.stack_size }) catch |err| {
        recordFailure(kind, config.stack_size);
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
        try std.testing.expectEqual(live.attempts, live.starts + live.spawn_failures + live.admission_rejections + live.in_flight_attempts);
        try std.testing.expectEqual(live.live, live.starts - live.completions);
        try std.testing.expectEqual(live.live, live.runnable + live.blocked);
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
    try std.testing.expectEqual(@as(u64, 0), after.admission_rejections - before.admission_rejections);
    try std.testing.expectEqual(before.live, after.live);
    try std.testing.expectEqual(after.live, after.runnable + after.blocked);
    try std.testing.expectEqual(before.configured_stack_bytes, after.configured_stack_bytes);
}

test "runtime blocking scopes account nested and concurrent transitions once" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 7), snapshot().schema_version);
    const before = snapshot().resource(.script_worker);
    var blocked = std.atomic.Value(u64).init(0);
    var release = std.atomic.Value(bool).init(false);
    var resumed = std.atomic.Value(u64).init(0);
    var finish = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(blocked_count: *std.atomic.Value(u64), release_gate: *std.atomic.Value(bool), resumed_count: *std.atomic.Value(u64), finish_gate: *std.atomic.Value(bool)) void {
            var outer = beginBlocking();
            var inner = beginBlocking();
            _ = blocked_count.fetchAdd(1, .release);
            while (!release_gate.load(.acquire)) std.atomic.spinLoopHint();
            inner.end();
            outer.end();
            _ = resumed_count.fetchAdd(1, .release);
            while (!finish_gate.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try spawn(.script_worker, .{}, Worker.run, .{ &blocked, &release, &resumed, &finish });
    while (blocked.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    const parked = snapshot().resource(.script_worker);
    try std.testing.expectEqual(before.live + threads.len, parked.live);
    try std.testing.expectEqual(before.blocked + threads.len, parked.blocked);
    try std.testing.expectEqual(before.runnable, parked.runnable);
    try std.testing.expectEqual(before.block_transitions + threads.len, parked.block_transitions);
    try std.testing.expectEqual(before.runnable_transitions, parked.runnable_transitions);
    try std.testing.expectEqual(parked.live, parked.runnable + parked.blocked);

    release.store(true, .release);
    while (resumed.load(.acquire) != threads.len) std.atomic.spinLoopHint();
    const running = snapshot().resource(.script_worker);
    try std.testing.expectEqual(before.live + threads.len, running.live);
    try std.testing.expectEqual(before.blocked, running.blocked);
    try std.testing.expectEqual(before.runnable + threads.len, running.runnable);
    try std.testing.expectEqual(before.runnable_transitions + threads.len, running.runnable_transitions);
    try std.testing.expectEqual(running.live, running.runnable + running.blocked);

    finish.store(true, .release);
    for (&threads) |*thread| thread.join();
    const after = snapshot().resource(.script_worker);
    try std.testing.expectEqual(before.live, after.live);
    try std.testing.expectEqual(before.runnable, after.runnable);
    try std.testing.expectEqual(before.blocked, after.blocked);
    try std.testing.expectEqual(after.live, after.runnable + after.blocked);
}

test "internal work reuses typed slots and nested admission" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const before = snapshot();
    var entered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(entered_gate: *std.atomic.Value(bool), release_gate: *std.atomic.Value(bool)) void {
            var native = beginInternalWork(.native_compilation);
            defer native.end();
            var wasm = beginInternalWork(.wasm_compilation);
            defer wasm.end();
            entered_gate.store(true, .release);
            while (!release_gate.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    const thread = try spawn(.script_worker, .{}, Worker.run, .{ &entered, &release });
    while (!entered.load(.acquire)) std.Thread.yield() catch {};
    const active = snapshot();
    const native_before = before.work(.native_compilation);
    const native_active = active.work(.native_compilation);
    const wasm_before = before.work(.wasm_compilation);
    const wasm_active = active.work(.wasm_compilation);
    try std.testing.expectEqual(native_before.requests + 1, native_active.requests);
    try std.testing.expectEqual(native_before.starts + 1, native_active.starts);
    try std.testing.expectEqual(native_before.active + 1, native_active.active);
    try std.testing.expectEqual(native_before.typed_slot_reuses + 1, native_active.typed_slot_reuses);
    try std.testing.expectEqual(wasm_before.requests + 1, wasm_active.requests);
    try std.testing.expectEqual(wasm_before.starts + 1, wasm_active.starts);
    try std.testing.expectEqual(wasm_before.active + 1, wasm_active.active);
    try std.testing.expectEqual(wasm_before.nested_reuses + 1, wasm_active.nested_reuses);
    try std.testing.expectEqual(before.scheduler.internal_work_general_active, active.scheduler.internal_work_general_active);
    try std.testing.expectEqual(before.scheduler.host_work_reserved_active, active.scheduler.host_work_reserved_active);
    try std.testing.expectEqual(active.scheduler.active_slots, active.scheduledGeneralTotal());

    release.store(true, .release);
    thread.join();
    const after = snapshot();
    try std.testing.expectEqual(native_before.active, after.work(.native_compilation).active);
    try std.testing.expectEqual(native_before.completions + 1, after.work(.native_compilation).completions);
    try std.testing.expectEqual(wasm_before.active, after.work(.wasm_compilation).active);
    try std.testing.expectEqual(wasm_before.completions + 1, after.work(.wasm_compilation).completions);
    try std.testing.expectEqual(before.scheduler.active_slots, after.scheduler.active_slots);
}

test "host internal work uses one reservation and queues excess background work" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const previous = setSchedulerLimits(.{ .max_runnable_threads = 1 });
    defer _ = setSchedulerLimits(previous);
    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    std.debug.assert(coordinator.active_slots.load(.monotonic) == 0 and !hasQueuedWaitersLocked());
    beginMutation();
    storeAutomaticPolicyState(automaticPolicy(2));
    finishMutation();
    coordinator.mutex.unlock(io);

    const before = snapshot();
    var entered = std.atomic.Value(u64).init(0);
    var active = std.atomic.Value(u64).init(0);
    var peak = std.atomic.Value(u64).init(0);
    var phase = std.atomic.Value(u64).init(0);
    const Worker = struct {
        fn run(entered_count: *std.atomic.Value(u64), active_count: *std.atomic.Value(u64), peak_count: *std.atomic.Value(u64), phase_gate: *std.atomic.Value(u64)) void {
            var work = beginInternalWork(.native_compilation);
            defer work.end();
            const ordinal = entered_count.fetchAdd(1, .acq_rel);
            const now_active = active_count.fetchAdd(1, .acq_rel) + 1;
            recordPeak(peak_count, now_active);
            const required_phase: u64 = if (ordinal == 0) 1 else 2;
            while (phase_gate.load(.acquire) < required_phase) std.atomic.spinLoopHint();
            _ = active_count.fetchSub(1, .acq_rel);
        }
    };
    var threads: [3]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        phase.store(2, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &entered, &active, &peak, &phase });
        spawned += 1;
    }

    const deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + 5 * std.time.ns_per_s;
    var pressured = snapshot();
    while ((entered.load(.acquire) != 2 or pressured.work(.native_compilation).waiters != before.work(.native_compilation).waiters + 1) and
        std.Io.Timestamp.now(io, .awake).nanoseconds < deadline)
    {
        std.Thread.yield() catch {};
        pressured = snapshot();
    }
    const work_before = before.work(.native_compilation);
    const work_pressured = pressured.work(.native_compilation);
    try std.testing.expectEqual(@as(u64, 2), entered.load(.acquire));
    try std.testing.expectEqual(work_before.requests + 3, work_pressured.requests);
    try std.testing.expectEqual(work_before.starts + 2, work_pressured.starts);
    try std.testing.expectEqual(work_before.active + 2, work_pressured.active);
    try std.testing.expectEqual(work_before.waiters + 1, work_pressured.waiters);
    try std.testing.expectEqual(work_before.waits + 1, work_pressured.waits);
    try std.testing.expectEqual(before.scheduler.internal_work_general_active + 1, pressured.scheduler.internal_work_general_active);
    try std.testing.expectEqual(before.scheduler.host_work_reserved_active + 1, pressured.scheduler.host_work_reserved_active);
    try std.testing.expectEqual(before.scheduledCpuTotal() + 2, pressured.scheduledCpuTotal());

    phase.store(1, .release);
    const resume_deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + 5 * std.time.ns_per_s;
    while (entered.load(.acquire) != 3 and std.Io.Timestamp.now(io, .awake).nanoseconds < resume_deadline)
        std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u64, 3), entered.load(.acquire));
    const resumed = snapshot().work(.native_compilation);
    try std.testing.expectEqual(work_before.starts + 3, resumed.starts);
    try std.testing.expectEqual(work_before.completions + 1, resumed.completions);
    try std.testing.expectEqual(work_before.active + 2, resumed.active);
    try std.testing.expectEqual(work_before.waiters, resumed.waiters);

    phase.store(2, .release);
    for (threads) |thread| thread.join();
    spawned = 0;
    const after = snapshot();
    const work_after = after.work(.native_compilation);
    try std.testing.expectEqual(@as(u64, 2), peak.load(.acquire));
    try std.testing.expectEqual(work_before.requests + 3, work_after.requests);
    try std.testing.expectEqual(work_before.starts + 3, work_after.starts);
    try std.testing.expectEqual(work_before.completions + 3, work_after.completions);
    try std.testing.expectEqual(work_before.active, work_after.active);
    try std.testing.expectEqual(work_before.waiters, work_after.waiters);
    try std.testing.expectEqual(work_before.waits + 1, work_after.waits);
    try std.testing.expect(work_after.wait_ns > work_before.wait_ns);
    try std.testing.expectEqual(@as(u64, 3), work_after.host_reserved_admissions - work_before.host_reserved_admissions +
        work_after.general_slot_admissions - work_before.general_slot_admissions);
    try std.testing.expect(work_after.host_reserved_admissions > work_before.host_reserved_admissions);
    try std.testing.expect(work_after.general_slot_admissions > work_before.general_slot_admissions);
    try std.testing.expectEqual(before.scheduler.active_slots, after.scheduler.active_slots);
    try std.testing.expectEqual(before.scheduler.internal_work_general_active, after.scheduler.internal_work_general_active);
    try std.testing.expectEqual(before.scheduler.host_work_reserved_active, after.scheduler.host_work_reserved_active);
}

test "runtime scheduler derives automatic capacity and exposes fixed overrides" {
    try std.testing.expectEqualDeep(AutomaticPolicy{
        .host_logical_cpus = 1,
        .host_reservation = 0,
        .effective_max_runnable_threads = 1,
    }, automaticPolicy(1));
    try std.testing.expectEqualDeep(AutomaticPolicy{
        .host_logical_cpus = 2,
        .host_reservation = 1,
        .effective_max_runnable_threads = 1,
    }, automaticPolicy(2));
    try std.testing.expectEqualDeep(AutomaticPolicy{
        .host_logical_cpus = 64,
        .host_reservation = 1,
        .effective_max_runnable_threads = 63,
    }, automaticPolicy(64));

    const previous = setSchedulerLimits(.{});
    defer _ = setSchedulerLimits(previous);
    const automatic = snapshot().scheduler;
    try std.testing.expectEqual(SchedulerPolicy.automatic, automatic.policy);
    try std.testing.expectEqual(@as(?u64, null), automatic.configured_max_runnable_threads);
    try std.testing.expect(automatic.host_logical_cpus >= 1);
    const expected = automaticPolicy(automatic.host_logical_cpus);
    try std.testing.expectEqual(expected.host_reservation, automatic.automatic_host_reservation);
    try std.testing.expectEqual(expected.effective_max_runnable_threads, automatic.effective_max_runnable_threads);

    const automatic_limits = setSchedulerLimits(.{ .max_runnable_threads = std.math.maxInt(u64) });
    try std.testing.expectEqual(@as(?u64, null), automatic_limits.max_runnable_threads);
    const unlimited = snapshot().scheduler;
    try std.testing.expectEqual(SchedulerPolicy.fixed, unlimited.policy);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), unlimited.configured_max_runnable_threads);
    try std.testing.expectEqual(std.math.maxInt(u64), unlimited.effective_max_runnable_threads);

    const unlimited_limits = setSchedulerLimits(automatic_limits);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), unlimited_limits.max_runnable_threads);
    const restored = snapshot().scheduler;
    try std.testing.expectEqual(SchedulerPolicy.automatic, restored.policy);
    try std.testing.expectEqual(@as(?u64, null), restored.configured_max_runnable_threads);
    try std.testing.expectEqual(restored.active_slots, snapshot().runnableTotal());
}

test "runtime scheduler grants weighted priorities with FIFO class order" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    try std.testing.expectEqual(Priority.safety, priorityFor(.concurrent_gc_marker));
    try std.testing.expectEqual(Priority.safety, priorityFor(.execution_watchdog));
    try std.testing.expectEqual(Priority.foreground, priorityFor(.javascript_thread));
    try std.testing.expectEqual(Priority.foreground, priorityFor(.test262_agent));
    try std.testing.expectEqual(Priority.background, priorityFor(.script_worker));
    try std.testing.expectEqual(Priority.background, priorityFor(.module_worker));

    const previous = setSchedulerLimits(.{ .max_runnable_threads = 0 });
    var threads: [14]std.Thread = undefined;
    var spawned: usize = 0;
    var output: [14]u64 = @splat(std.math.maxInt(u64));
    var output_count = std.atomic.Value(u64).init(0);
    defer {
        _ = setSchedulerLimits(.{});
        for (threads[0..spawned]) |thread| thread.join();
        _ = setSchedulerLimits(previous);
    }

    const io = engine_io.get();
    coordinator.mutex.lockUncancelable(io);
    std.debug.assert(!hasQueuedWaitersLocked() and coordinator.active_slots.load(.monotonic) == 0);
    coordinator.schedule_cursor = 0;
    coordinator.mutex.unlock(io);

    const Worker = struct {
        fn run(id: u64, count: *std.atomic.Value(u64), values: *[14]u64) void {
            const index: usize = @intCast(count.fetchAdd(1, .acq_rel));
            values[index] = id;
        }
    };
    const before = snapshot().scheduler;
    const deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + 5 * std.time.ns_per_s;
    for (0..8) |index| {
        threads[spawned] = try spawn(.execution_watchdog, .{}, Worker.run, .{ 100 + index, &output_count, &output });
        spawned += 1;
        while (snapshot().scheduler.slot_waiters != before.slot_waiters + spawned and
            std.Io.Timestamp.now(io, .awake).nanoseconds < deadline)
            std.Thread.yield() catch {};
    }
    for (0..4) |index| {
        threads[spawned] = try spawn(.javascript_thread, .{}, Worker.run, .{ 200 + index, &output_count, &output });
        spawned += 1;
        while (snapshot().scheduler.slot_waiters != before.slot_waiters + spawned and
            std.Io.Timestamp.now(io, .awake).nanoseconds < deadline)
            std.Thread.yield() catch {};
    }
    for (0..2) |index| {
        threads[spawned] = try spawn(.script_worker, .{}, Worker.run, .{ 300 + index, &output_count, &output });
        spawned += 1;
        while (snapshot().scheduler.slot_waiters != before.slot_waiters + spawned and
            std.Io.Timestamp.now(io, .awake).nanoseconds < deadline)
            std.Thread.yield() catch {};
    }
    const queued = snapshot().scheduler;
    try std.testing.expectEqual(before.slot_waiters + threads.len, queued.slot_waiters);
    try std.testing.expectEqual(before.priority(.safety).waiters + 8, queued.priority(.safety).waiters);
    try std.testing.expectEqual(before.priority(.foreground).waiters + 4, queued.priority(.foreground).waiters);
    try std.testing.expectEqual(before.priority(.background).waiters + 2, queued.priority(.background).waiters);

    _ = setSchedulerLimits(.{ .max_runnable_threads = 1 });
    for (&threads) |*thread| thread.join();
    spawned = 0;
    try std.testing.expectEqual(@as(u64, output.len), output_count.load(.acquire));
    try std.testing.expectEqualSlices(u64, &.{ 100, 101, 102, 103, 200, 201, 300, 104, 105, 106, 107, 202, 203, 301 }, &output);

    const after = snapshot().scheduler;
    try std.testing.expectEqual(before.slot_waiters, after.slot_waiters);
    try std.testing.expectEqual(before.priority(.safety).grants + 8, after.priority(.safety).grants);
    try std.testing.expectEqual(before.priority(.foreground).grants + 4, after.priority(.foreground).grants);
    try std.testing.expectEqual(before.priority(.background).grants + 2, after.priority(.background).grants);
    try std.testing.expectEqual(after.active_slots, snapshot().runnableTotal());
}

test "runtime scheduler bounds runnable slots and wakes policy waiters" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const before = snapshot();
    try std.testing.expectEqual(before.scheduler.active_slots, before.runnableTotal());
    const previous = setSchedulerLimits(.{ .max_runnable_threads = 2 });
    var phase = std.atomic.Value(u64).init(0);
    var entered = std.atomic.Value(u64).init(0);
    var active = std.atomic.Value(u64).init(0);
    var max_active = std.atomic.Value(u64).init(0);
    const Worker = struct {
        fn run(phase_gate: *std.atomic.Value(u64), entered_count: *std.atomic.Value(u64), active_count: *std.atomic.Value(u64), peak: *std.atomic.Value(u64)) void {
            const ordinal = entered_count.fetchAdd(1, .acq_rel);
            const now_active = active_count.fetchAdd(1, .acq_rel) + 1;
            recordPeak(peak, now_active);
            const required_phase: u64 = if (ordinal < 2) 1 else 2;
            while (phase_gate.load(.acquire) < required_phase) std.atomic.spinLoopHint();
            _ = active_count.fetchSub(1, .acq_rel);
        }
    };
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    var paused_thread: ?std.Thread = null;
    defer {
        phase.store(2, .release);
        _ = setSchedulerLimits(.{});
        for (threads[0..spawned]) |thread| thread.join();
        if (paused_thread) |thread| thread.join();
        _ = setSchedulerLimits(previous);
    }
    for (&threads) |*thread| {
        thread.* = try spawn(.script_worker, .{}, Worker.run, .{ &phase, &entered, &active, &max_active });
        spawned += 1;
    }
    const first_deadline = std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds + 5 * std.time.ns_per_s;
    while (entered.load(.acquire) != 2 and std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds < first_deadline)
        std.Thread.yield() catch {};
    var pressured = snapshot();
    while (pressured.scheduler.slot_waiters != before.scheduler.slot_waiters + 2 and
        std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds < first_deadline)
    {
        std.Thread.yield() catch {};
        pressured = snapshot();
    }
    try std.testing.expectEqual(@as(u64, 2), entered.load(.acquire));
    try std.testing.expectEqual(before.scheduler.active_slots + 2, pressured.scheduler.active_slots);
    try std.testing.expectEqual(before.scheduler.slot_waiters + 2, pressured.scheduler.slot_waiters);
    try std.testing.expectEqual(pressured.scheduler.active_slots, pressured.runnableTotal());
    const pressured_workers = pressured.resource(.script_worker);
    const before_workers = before.resource(.script_worker);
    try std.testing.expectEqual(before_workers.runnable + 2, pressured_workers.runnable);
    try std.testing.expectEqual(before_workers.blocked + 2, pressured_workers.blocked);

    phase.store(1, .release);
    const second_deadline = std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds + 5 * std.time.ns_per_s;
    while (entered.load(.acquire) != 4 and std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds < second_deadline)
        std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u64, 4), entered.load(.acquire));
    const second = snapshot();
    try std.testing.expectEqual(before.scheduler.active_slots + 2, second.scheduler.active_slots);
    try std.testing.expectEqual(before.scheduler.slot_waiters, second.scheduler.slot_waiters);
    try std.testing.expectEqual(second.scheduler.active_slots, second.runnableTotal());
    try std.testing.expectEqual(@as(u64, 2), max_active.load(.acquire));
    phase.store(2, .release);
    for (&threads) |*thread| thread.join();
    spawned = 0;

    _ = setSchedulerLimits(.{ .max_runnable_threads = 0 });
    var ran = std.atomic.Value(bool).init(false);
    const Paused = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            flag.store(true, .release);
        }
    };
    paused_thread = try spawn(.module_worker, .{}, Paused.run, .{&ran});
    const zero_deadline = std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds + 5 * std.time.ns_per_s;
    var paused = snapshot();
    while (paused.scheduler.slot_waiters == before.scheduler.slot_waiters and
        std.Io.Timestamp.now(engine_io.get(), .awake).nanoseconds < zero_deadline)
    {
        std.Thread.yield() catch {};
        paused = snapshot();
    }
    try std.testing.expect(!ran.load(.acquire));
    try std.testing.expectEqual(before.scheduler.active_slots, paused.scheduler.active_slots);
    try std.testing.expectEqual(before.scheduler.slot_waiters + 1, paused.scheduler.slot_waiters);
    _ = setSchedulerLimits(.{});
    paused_thread.?.join();
    paused_thread = null;
    try std.testing.expect(ran.load(.acquire));
    const after = snapshot();
    try std.testing.expectEqual(before.scheduler.active_slots, after.scheduler.active_slots);
    try std.testing.expectEqual(before.scheduler.slot_waiters, after.scheduler.slot_waiters);
    try std.testing.expectEqual(before.scheduler.slot_waits + 3, after.scheduler.slot_waits);
    try std.testing.expectEqual(SchedulerPolicy.automatic, after.scheduler.policy);
    try std.testing.expect(after.scheduler.effective_max_runnable_threads >= 1);
    try std.testing.expectEqual(after.scheduler.active_slots, after.runnableTotal());
}

test "runtime thread telemetry distinguishes failed and in-flight attempts" {
    const before = snapshot().resource(.module_worker);
    try std.testing.expect(tryAdmit(.module_worker, std.Thread.SpawnConfig.default_stack_size));
    const pending = snapshot().resource(.module_worker);
    try std.testing.expectEqual(before.attempts + 1, pending.attempts);
    try std.testing.expectEqual(before.in_flight_attempts + 1, pending.in_flight_attempts);
    try std.testing.expectEqual(pending.attempts, pending.starts + pending.spawn_failures + pending.admission_rejections + pending.in_flight_attempts);
    recordFailure(.module_worker, std.Thread.SpawnConfig.default_stack_size);
    const after = snapshot().resource(.module_worker);
    try std.testing.expectEqual(before.in_flight_attempts, after.in_flight_attempts);
    try std.testing.expectEqual(before.spawn_failures + 1, after.spawn_failures);
    try std.testing.expectEqual(after.attempts, after.starts + after.spawn_failures + after.admission_rejections + after.in_flight_attempts);
}

test "runtime thread admission enforces thread and configured-stack limits" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const stack = std.Thread.SpawnConfig.default_stack_size;
    const previous = setLimits(.module_worker, .{ .max_threads = 2, .max_configured_stack_bytes = stack * 2 });
    defer _ = setLimits(.module_worker, previous);
    const before = snapshot().resource(.module_worker);
    var release = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(gate: *std.atomic.Value(bool)) void {
            while (!gate.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    const first = try spawn(.module_worker, .{}, Worker.run, .{&release});
    const second = try spawn(.module_worker, .{}, Worker.run, .{&release});
    try std.testing.expectError(error.ThreadQuotaExceeded, spawn(.module_worker, .{}, Worker.run, .{&release}));
    const pressured = snapshot().resource(.module_worker);
    try std.testing.expectEqual(before.admitted_threads + 2, pressured.admitted_threads);
    try std.testing.expectEqual(before.admitted_stack_bytes + stack * 2, pressured.admitted_stack_bytes);
    try std.testing.expectEqual(before.admission_rejections + 1, pressured.admission_rejections);

    _ = setLimits(.module_worker, .{ .max_threads = 0, .max_configured_stack_bytes = 0 });
    try std.testing.expectError(error.ThreadQuotaExceeded, spawn(.module_worker, .{}, Worker.run, .{&release}));
    release.store(true, .release);
    first.join();
    second.join();
    const after = snapshot().resource(.module_worker);
    try std.testing.expectEqual(before.admitted_threads, after.admitted_threads);
    try std.testing.expectEqual(before.admitted_stack_bytes, after.admitted_stack_bytes);
    try std.testing.expectEqual(before.admission_rejections + 2, after.admission_rejections);

    _ = setLimits(.module_worker, .{ .max_threads = 1, .max_configured_stack_bytes = stack - 1 });
    try std.testing.expectError(error.ThreadQuotaExceeded, spawn(.module_worker, .{}, Worker.run, .{&release}));
}
