//! Promises + the microtask queue for zig-js.
//!
//! A `Promise` is a `value.Object` whose `promise` field points at a `Promise`
//! state record (pending/fulfilled/rejected + recorded reactions). Settling a
//! promise enqueues one allocation-free settlement descriptor; the queue
//! materializes its recorded `Reaction` jobs atomically before dequeue.
//! `Context.evaluate` drains that queue after the main script (and
//! which `await` drains inline until the awaited promise settles — the
//! synchronous-settling model: faithful for values, not for exact ordering).
//!
//! Operates on a type-erased `*Interpreter` (the same cycle-break the VM and
//! generators use); the interpreter casts back when dispatching.

const std = @import("std");
const gc_runtime = @import("gc_runtime.zig");
const gc_mod = @import("gc.zig");
const gc_relocation = @import("gc_relocation.zig");
const value = @import("value.zig");
const interp = @import("interpreter.zig");
const promise_profile = @import("promise_profile.zig");

const Value = value.Value;
const Object = value.Object;
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;

const microtask_queue_reserve_granularity: usize = 32;
const reaction_list_reserve_granularity: usize = 16;

pub const State = enum { pending, fulfilled, rejected };

/// A `.then` reaction: when the source promise settles, `handler` (the
/// onFulfilled/onRejected callback, or null for pass-through) is run and its
/// outcome resolves/rejects `result` (the promise `.then` returned).
pub const Reaction = struct {
    handler: ?Value,
    /// Optional second argument supplied after the settlement value. Private
    /// Home/Bun Promise bridges use this to retain and deliver their opaque
    /// context JSValue without allocating a closure per registration.
    extra_argument: ?Value = null,
    /// Host-only reactions have no result capability. Their callback result is
    /// discarded; an abrupt callback still escapes the microtask checkpoint.
    detached: bool = false,
    /// Suspended async activation retained until this reaction job runs. The
    /// Promise's pending-link is cleared at settlement; this edge bridges the
    /// queued interval without teaching native callback objects to trace their
    /// opaque `private_data` payload.
    retained_async_activation: ?*anyopaque = null,
    /// Intrinsic `.then` fast path: settle this result promise directly instead
    /// of allocating native resolve/reject capability closures. Custom species
    /// capabilities keep using `resolve`/`reject` below.
    result: ?*Promise = null,
    /// The result capability's resolve/reject functions: running the reaction
    /// settles the dependent promise by *calling* one of these. For a plain
    /// `.then` they are native closures over a fresh promise; for a subclass
    /// (`SpeciesConstructor`) they are the functions that constructor handed out.
    resolve: Value = Value.undef(),
    reject: Value = Value.undef(),
};

/// Fulfill/reject reactions are registered and consumed as one specification
/// record. Keeping the pair together makes registration OOM-atomic and removes
/// one overflow allocation/list from every Promise.
pub const ReactionPair = struct {
    fulfill: Reaction,
    reject: Reaction,
};

/// Awaiting activations exist only after reaction registration has made a
/// Promise handled. Rejection-tracker nodes are settled while still unhandled,
/// so these two pointer roles are mutually exclusive and share one word.
pub const AwaitingActivationOrRejectionLink = extern union {
    awaiting_async_activation: ?*anyopaque,
    rejection_next: ?*Promise,
};

pub const Promise = struct {
    lock: std.atomic.Mutex = .unlocked,
    /// Immutable after construction. Concurrent-marker and parallel-mutator
    /// contexts take `lock`; serialized contexts rely on their execution policy
    /// while retaining the trace-sensitive guard below.
    state_locking: bool = false,
    state: State = .pending,
    value: Value = Value.undef(),
    /// The unique JavaScript wrapper for this internal Promise cell. The host
    /// rejection tracker needs its exact identity for process events.
    wrapper: ?*Object = null,
    /// While pending, the suspended async activation directly awaiting this
    /// Promise. Type-erased to keep promise.zig independent of vm.zig.
    awaiting_activation_or_rejection_link: AwaitingActivationOrRejectionLink = .{ .awaiting_async_activation = null },
    /// A transparent adoption/pass-through destination. Async-stack walking
    /// follows this only when there is no direct awaiting activation.
    async_forward_to: ?*Promise = null,
    /// Reaction list buffers are owned by the GC backing allocator when this
    /// promise cell is GC-owned; arena contexts keep the legacy arena path.
    gc_owned: bool = false,
    /// The overwhelmingly common pending-promise shape has one reaction pair.
    /// Keep it inline and allocate one paired overflow list only for fanout.
    reactions_inline: ?ReactionPair = null,
    reactions: std.ArrayListUnmanaged(ReactionPair) = .empty,
    /// HostPromiseRejectionTracker state. A rejection is queued only when no
    /// reaction has handled this promise; the host checkpoint consumes it once.
    is_handled: bool = false,
    rejection_queued: bool = false,
    rejection_notified: bool = false,
    rejection_handled_notified: bool = false,
    /// Selects the rejection-link arm above. Queue mutation and traversal are
    /// serialized by the owning realm lock; a Promise can enter the handled
    /// queue only after it has left the unhandled queue.
    rejection_linked: std.atomic.Value(bool) = .init(false),

    pub fn lockState(self: *Promise) void {
        if (self.state_locking) {
            promise_profile.recordPromiseLockAcquire();
            var spins: usize = 0;
            while (!self.lock.tryLock()) : (spins += 1) {
                if ((spins & 0xff) == 0) {
                    promise_profile.recordPromiseLockYield();
                    std.Thread.yield() catch {};
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn unlockState(self: *Promise) void {
        gc_runtime.leaveTraceSensitiveLock();
        if (self.state_locking) self.lock.unlock();
    }
};

/// Realm-owned allocation-free HostPromiseRejectionTracker FIFO. The realm
/// lock serializes mutation/traversal under `parallel_js`; intrusive links keep
/// append and dequeue O(1) without a fallible publication boundary.
pub const RejectionQueue = struct {
    head: ?*Promise = null,
    tail: ?*Promise = null,
    len: usize = 0,

    pub fn append(self: *@This(), item: *Promise) void {
        std.debug.assert(!item.rejection_linked.load(.acquire));
        std.debug.assert(item.state != .pending);
        std.debug.assert(item.awaiting_activation_or_rejection_link.awaiting_async_activation == null);
        std.debug.assert(item.reactions_inline == null);
        std.debug.assert(item.reactions.items.len == 0 and item.reactions.capacity == 0);
        item.awaiting_activation_or_rejection_link = .{ .rejection_next = null };
        item.rejection_linked.store(true, .release);
        std.debug.assert((self.head == null) == (self.tail == null));
        std.debug.assert((self.head == null) == (self.len == 0));
        std.debug.assert(self.len != std.math.maxInt(usize));
        if (self.tail) |tail| {
            std.debug.assert(tail.rejection_linked.load(.acquire));
            std.debug.assert(tail.awaiting_activation_or_rejection_link.rejection_next == null);
            tail.awaiting_activation_or_rejection_link.rejection_next = item;
        } else {
            self.head = item;
        }
        self.tail = item;
        self.len += 1;
    }

    pub fn pop(self: *@This()) ?*Promise {
        const item = self.head orelse {
            std.debug.assert(self.tail == null and self.len == 0);
            return null;
        };
        std.debug.assert(self.tail != null and self.len != 0);
        std.debug.assert(item.rejection_linked.load(.acquire));
        const next = item.awaiting_activation_or_rejection_link.rejection_next;
        if (item == self.tail.?) {
            std.debug.assert(self.len == 1 and next == null);
        } else {
            std.debug.assert(self.len > 1 and next != null);
        }
        self.head = next;
        item.awaiting_activation_or_rejection_link = .{ .awaiting_async_activation = null };
        item.rejection_linked.store(false, .release);
        self.len -= 1;
        if (self.head == null) {
            std.debug.assert(self.len == 0);
            self.tail = null;
        }
        return item;
    }

    pub fn pendingLen(self: *const @This()) usize {
        return self.len;
    }

    pub fn isEmpty(self: *const @This()) bool {
        std.debug.assert((self.head == null) == (self.tail == null));
        std.debug.assert((self.head == null) == (self.len == 0));
        return self.head == null;
    }

    pub const Iterator = struct {
        next_item: ?*Promise,
        remaining: usize,

        pub fn next(self: *@This()) ?*Promise {
            if (self.remaining == 0) {
                std.debug.assert(self.next_item == null);
                return null;
            }
            const item = self.next_item orelse {
                std.debug.assert(false);
                self.remaining = 0;
                return null;
            };
            std.debug.assert(item.rejection_linked.load(.acquire));
            self.next_item = item.awaiting_activation_or_rejection_link.rejection_next;
            self.remaining -= 1;
            return item;
        }
    };

    pub fn iterator(self: *const @This()) Iterator {
        std.debug.assert((self.head == null) == (self.tail == null));
        std.debug.assert((self.head == null) == (self.len == 0));
        return .{ .next_item = self.head, .remaining = self.len };
    }

    pub fn clear(self: *@This()) void {
        while (self.pop()) |_| {}
        self.* = .{};
    }
};

test "rejection queue is wide allocation-free FIFO" {
    const width = 4096;
    const promises = try std.testing.allocator.alloc(Promise, width + 1);
    defer std.testing.allocator.free(promises);
    for (promises) |*item| item.* = .{ .state = .rejected };

    var queue: RejectionQueue = .{};
    defer queue.clear();
    try std.testing.expect(queue.pop() == null);
    for (promises[0..width]) |*item| queue.append(item);

    try std.testing.expectEqual(@as(usize, width), queue.pendingLen());
    try std.testing.expectEqual(&promises[0], queue.head.?);
    try std.testing.expectEqual(&promises[width - 1], queue.tail.?);
    var iter = queue.iterator();
    for (promises[0..width]) |*item| try std.testing.expectEqual(item, iter.next().?);
    try std.testing.expect(iter.next() == null);
    try std.testing.expectEqual(&promises[0], queue.pop().?);
    try std.testing.expect(!promises[0].rejection_linked.load(.acquire));
    try std.testing.expectEqual(@as(usize, width - 1), queue.pendingLen());

    // A notification queued reentrantly follows the complete pending suffix.
    queue.append(&promises[width]);
    for (promises[1..width]) |*item| try std.testing.expectEqual(item, queue.pop().?);
    try std.testing.expectEqual(&promises[width], queue.pop().?);
    try std.testing.expect(queue.isEmpty());
    try std.testing.expect(queue.head == null and queue.tail == null);

    queue.append(&promises[0]);
    queue.append(&promises[1]);
    queue.clear();
    try std.testing.expect(!promises[0].rejection_linked.load(.acquire));
    try std.testing.expect(!promises[1].rejection_linked.load(.acquire));
    try std.testing.expect(queue.isEmpty());
}

pub const AsyncStackLink = struct {
    state: State,
    activation: ?*anyopaque,
    forward_to: ?*Promise,
};

pub fn asyncStackLink(p: *Promise) AsyncStackLink {
    p.lockState();
    defer p.unlockState();
    return .{
        .state = p.state,
        .activation = if (p.rejection_linked.load(.acquire))
            null
        else
            p.awaiting_activation_or_rejection_link.awaiting_async_activation,
        .forward_to = p.async_forward_to,
    };
}

pub fn linkAwaitingAsyncActivation(p: *Promise, activation: *anyopaque) void {
    p.lockState();
    defer p.unlockState();
    if (p.state != .pending) return;
    std.debug.assert(p.is_handled);
    std.debug.assert(!p.rejection_linked.load(.acquire));
    gc_mod.barrierCellFrom(p, activation);
    p.awaiting_activation_or_rejection_link.awaiting_async_activation = activation;
}

fn linkAsyncForward(source: *Promise, destination: *Promise) void {
    if (source == destination) return;
    source.lockState();
    defer source.unlockState();
    if (source.state != .pending or source.async_forward_to != null) return;
    gc_mod.barrierCellFrom(source, destination);
    source.async_forward_to = destination;
}

/// A queued reaction job: run `reaction.handler(argument)` and settle
/// `reaction.result` accordingly (a pass-through when `handler` is null).
pub const Microtask = struct {
    kind: enum { reaction, settlement_batch, transferred_batch, thenable, callback, native_callback, job, next_tick } = .reaction,
    reaction: Reaction,
    argument: Value,
    fulfilled: bool, // whether the source settled fulfilled (vs rejected)
    thenable: Value = Value.undef(),
    then_fn: Value = Value.undef(),
    /// Selected by `kind`: transferred batches own arena-lived backing, while
    /// thenable and settlement jobs own a managed Promise. The union preserves
    /// the ordinary job's allocation density.
    payload: extern union { promise: ?*Promise, transfer: *MicrotaskTransfer } = .{ .promise = null },
    /// `.callback` jobs (HTML queueMicrotask): the function to invoke with no
    /// arguments. Settles no promise; a throw propagates as a reported exception.
    callback: Value = Value.undef(),
    /// Private-JSC native microtask callback. These are opaque host bits, not GC
    /// pointers; copying both fields into the queue retains their exact identity
    /// until the callback has run once.
    native_callback_context: ?*anyopaque = null,
    native_callback: ?*const fn (?*anyopaque) callconv(.c) void = null,
    /// BunPerformMicrotaskJob payload. The async-context slot is intentionally
    /// absent until AsyncContextFrame exists; the callable receives the exact
    /// two pinned encoded arguments (empty values normalize to undefined).
    job: Value = Value.undef(),
    job_first: Value = Value.undef(),
    job_second: Value = Value.undef(),
    /// Process next-tick jobs retain their exact argument count. The slice is
    /// arena-owned and every value is traced while queued or in an active drain
    /// batch, so one- and two-argument private calls remain observably distinct.
    job_args: []const Value = &.{},
};

/// One future queue handoff, reserved before a Thread can publish work. After
/// closure, the destination owns the moved backing through its descriptor; no
/// pointer into a running thread's queue or native stack remains. All state is
/// guarded by the destination queue lock after preparation.
pub const MicrotaskTransfer = struct {
    destination: ?*MicrotaskQueue = null,
    state: enum { empty, reserved, queued, consumed } = .empty,
    items: std.ArrayListUnmanaged(Microtask) = .empty,
    head: usize = 0,

    pub fn pendingItems(self: *MicrotaskTransfer) []Microtask {
        return self.items.items[self.head..];
    }
};

pub const MicrotaskQueue = struct {
    items: std.ArrayListUnmanaged(Microtask) = .empty,
    head: usize = 0,
    /// Capacity promised to resolving-function transactions and detached drain
    /// batches. Every producer includes these slots in growth decisions, so
    /// reentrant enqueueing cannot consume settlement or restoration capacity.
    reservations: usize = 0,
    /// Serializes this queue's content mutation under no-GIL execution. The
    /// queue itself owns the lock so spawned `Thread`s with independent
    /// microtask queues do not contend on the realm queue's lock.
    lock: std.atomic.Mutex = .unlocked,
    /// Monotonic enqueue generation for run-loop pumps that need to know
    /// whether a task turn produced microtasks without taking the queue lock on
    /// the common empty path. This is not a length; it never decreases.
    generation: std.atomic.Value(u64) = .init(0),

    pub fn acquire(self: *MicrotaskQueue) void {
        promise_profile.recordMicrotaskLockAcquire();
        var spins: usize = 0;
        while (!self.lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                promise_profile.recordMicrotaskLockYield();
                std.Thread.yield() catch {};
            } else std.atomic.spinLoopHint();
        }
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn release(self: *MicrotaskQueue) void {
        gc_runtime.leaveTraceSensitiveLock();
        self.lock.unlock();
    }

    pub fn append(self: *MicrotaskQueue, a: std.mem.Allocator, task: Microtask) !void {
        try self.reserve(a, 1);
        self.appendAssumeCapacity(task);
    }

    fn appendAssumeCapacity(self: *MicrotaskQueue, task: Microtask) void {
        self.items.appendAssumeCapacity(task);
        _ = self.generation.fetchAdd(1, .release);
    }

    pub fn prepareTransfer(self: *MicrotaskQueue, a: std.mem.Allocator, transfer: *MicrotaskTransfer) !void {
        std.debug.assert(transfer.state == .empty);
        try self.reserveTransactionSlot(a);
        transfer.destination = self;
        transfer.state = .reserved;
    }

    pub fn cancelTransfer(self: *MicrotaskQueue, transfer: *MicrotaskTransfer) void {
        std.debug.assert(transfer.destination == self and transfer.state == .reserved);
        self.cancelTransactionSlot();
        transfer.state = .consumed;
    }

    /// Both queue locks are held, and source publication is closed. The one
    /// descriptor slot was reserved before source work could become observable.
    /// This moves backing ownership; materialization may fail later but can
    /// never clear the source without retaining its complete pending suffix.
    pub fn publishTransfer(self: *MicrotaskQueue, source: *MicrotaskQueue, transfer: *MicrotaskTransfer) void {
        std.debug.assert(source != self and source.reservations == 0);
        std.debug.assert(transfer.destination == self and transfer.state == .reserved);
        const count = source.pendingLen();
        if (count == 0) {
            self.cancelTransfer(transfer);
            return;
        }
        transfer.items = source.items;
        transfer.head = source.head;
        gc_mod.barrierMicrotasks(transfer.pendingItems());
        self.appendInTransactionSlot(.{
            .kind = .transferred_batch,
            .reaction = undefined,
            .argument = Value.undef(),
            .fulfilled = true,
            .payload = .{ .transfer = transfer },
        });
        if (count > 1) _ = self.generation.fetchAdd(@intCast(count - 1), .release);
        transfer.state = .queued;
        source.items = .empty;
        source.head = 0;
    }

    /// The batch copy must succeed before detaching. Its original occupied
    /// slots become a reservation without allocating; every producer and nested
    /// drain preserves that capacity until this batch finishes or restores.
    pub fn detachBatch(self: *MicrotaskQueue) usize {
        const count = self.pendingLen();
        std.debug.assert(self.items.items.len + self.reservations <= self.items.capacity);
        self.reservations += count;
        self.clearRetainingCapacity();
        return count;
    }

    pub fn finishBatch(self: *MicrotaskQueue, count: usize) void {
        std.debug.assert(count <= self.reservations);
        self.reservations -= count;
    }

    /// Consume the batch's reservation while restoring its untouched suffix
    /// ahead of reentrant jobs. No allocator or user code runs during this
    /// ownership handoff, even when an inner drain already restored a suffix.
    pub fn restoreBatch(self: *MicrotaskQueue, tasks: []const Microtask, count: usize) void {
        std.debug.assert(tasks.len <= count);
        self.finishBatch(count);
        if (tasks.len == 0) return;
        const pending = self.pendingItems();
        const pending_len = pending.len;
        std.debug.assert(pending_len + tasks.len + self.reservations <= self.items.capacity);
        if (self.head != 0 and pending_len != 0)
            std.mem.copyForwards(Microtask, self.items.items[0..pending_len], pending);
        self.items.items.len = pending_len + tasks.len;
        self.head = 0;
        std.mem.copyBackwards(Microtask, self.items.items[tasks.len..], self.items.items[0..pending_len]);
        @memcpy(self.items.items[0..tasks.len], tasks);
        _ = self.generation.fetchAdd(@intCast(tasks.len), .release);
    }

    fn reserve(self: *MicrotaskQueue, a: std.mem.Allocator, additional: usize) !void {
        if (additional == 0) return;
        const occupied = std.math.add(usize, self.items.items.len, self.reservations) catch return error.OutOfMemory;
        const spare = self.items.capacity - occupied;
        if (spare >= additional) return;
        const extra = @max(additional, microtask_queue_reserve_granularity);
        const required = std.math.add(usize, occupied, extra) catch return error.OutOfMemory;
        promise_profile.recordMicrotaskQueueGrow();
        try self.items.ensureTotalCapacity(a, required);
    }

    fn reserveTransactionSlot(self: *MicrotaskQueue, a: std.mem.Allocator) !void {
        try self.reserve(a, 1);
        self.reservations += 1;
    }

    fn cancelTransactionSlot(self: *MicrotaskQueue) void {
        std.debug.assert(self.reservations != 0);
        self.reservations -= 1;
    }

    fn appendInTransactionSlot(self: *MicrotaskQueue, task: Microtask) void {
        self.cancelTransactionSlot();
        self.appendAssumeCapacity(task);
    }

    pub fn pendingLen(self: *const MicrotaskQueue) usize {
        if (self.head >= self.items.items.len) return 0;
        return self.items.items.len - self.head;
    }

    pub fn isEmpty(self: *const MicrotaskQueue) bool {
        return self.pendingLen() == 0;
    }

    pub fn pendingItems(self: *MicrotaskQueue) []Microtask {
        if (self.head >= self.items.items.len) return self.items.items[0..0];
        return self.items.items[self.head..];
    }

    pub fn pop(self: *MicrotaskQueue) ?Microtask {
        if (self.head >= self.items.items.len) {
            self.clearRetainingCapacity();
            return null;
        }
        const task = self.items.items[self.head];
        self.items.items[self.head] = undefined;
        self.head += 1;
        promise_profile.recordMicrotaskPop();
        if (self.head == self.items.items.len) self.clearRetainingCapacity();
        return task;
    }

    pub fn clearRetainingCapacity(self: *MicrotaskQueue) void {
        self.items.clearRetainingCapacity();
        self.head = 0;
    }

    pub fn enqueueGeneration(self: *const MicrotaskQueue) u64 {
        return self.generation.load(.acquire);
    }
};

test "microtask queue is FIFO with a head cursor" {
    var q = MicrotaskQueue{};
    const a = std.testing.allocator;
    defer q.items.deinit(a);

    try q.append(a, .{ .reaction = undefined, .argument = Value.num(1), .fulfilled = true });
    try std.testing.expect(q.items.capacity >= microtask_queue_reserve_granularity);
    const first_capacity = q.items.capacity;
    try q.append(a, .{ .reaction = undefined, .argument = Value.num(2), .fulfilled = true });
    try q.append(a, .{ .reaction = undefined, .argument = Value.num(3), .fulfilled = true });

    try std.testing.expectEqual(@as(u64, 3), q.enqueueGeneration());
    try std.testing.expectEqual(@as(usize, 3), q.pendingLen());
    try std.testing.expectEqual(@as(f64, 1), q.pop().?.argument.asNum());
    try std.testing.expectEqual(@as(usize, 2), q.pendingLen());
    try q.append(a, .{ .reaction = undefined, .argument = Value.num(4), .fulfilled = true });
    try std.testing.expectEqual(@as(u64, 4), q.enqueueGeneration());
    try std.testing.expectEqual(@as(f64, 2), q.pop().?.argument.asNum());
    try std.testing.expectEqual(@as(f64, 3), q.pop().?.argument.asNum());
    try std.testing.expectEqual(@as(f64, 4), q.pop().?.argument.asNum());
    try std.testing.expect(q.isEmpty());
    try std.testing.expect(q.pop() == null);
    try std.testing.expectEqual(@as(u64, 4), q.enqueueGeneration());
    try std.testing.expectEqual(first_capacity, q.items.capacity);

    var source = MicrotaskQueue{};
    defer source.items.deinit(a);
    try source.append(a, .{ .reaction = undefined, .argument = Value.num(5), .fulfilled = true });
    try source.append(a, .{ .reaction = undefined, .argument = Value.num(6), .fulfilled = true });
    try std.testing.expectEqual(@as(f64, 5), source.pop().?.argument.asNum());
    var transfer = MicrotaskTransfer{};
    try q.prepareTransfer(a, &transfer);
    q.publishTransfer(&source, &transfer);
    var machine = Interpreter{ .arena = a, .env = undefined, .root_shape = undefined };
    try materializeSettlementBatches(&machine, &q);
    try std.testing.expectEqual(@as(u64, 5), q.enqueueGeneration());
    try std.testing.expectEqual(@as(usize, 1), q.pendingLen());
    try std.testing.expectEqual(@as(f64, 6), q.pop().?.argument.asNum());
}

test "microtask transfer owns the closed suffix through allocation failure" {
    const a = std.testing.allocator;
    const Job = struct {
        fn make(n: f64) Microtask {
            return .{ .kind = .native_callback, .reaction = undefined, .argument = Value.num(n), .fulfilled = true };
        }
    };
    for ([_]bool{ false, true }) |nonempty| {
        var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
        const storage = try a.alloc(Microtask, 2 + @as(usize, @intFromBool(nonempty)));
        var destination = MicrotaskQueue{ .items = .{ .items = storage[0..0], .capacity = storage.len } };
        defer destination.items.deinit(a);
        var source = MicrotaskQueue{};
        defer source.items.deinit(a);
        if (nonempty) try destination.append(a, Job.make(1));
        var transfer = MicrotaskTransfer{};
        try destination.prepareTransfer(unavailable.allocator(), &transfer);
        try destination.reserveTransactionSlot(unavailable.allocator());
        try std.testing.expectError(error.OutOfMemory, destination.append(unavailable.allocator(), Job.make(2)));
        for ([_]f64{ 10, 11, 12, 13 }) |n| try source.append(a, Job.make(n));
        try std.testing.expectEqual(@as(f64, 10), source.pop().?.argument.asNum());
        const backing = source.items.items.ptr;
        const generation = destination.enqueueGeneration();
        destination.publishTransfer(&source, &transfer);
        try std.testing.expect(source.isEmpty());
        try std.testing.expectEqual(@as(usize, 0), source.items.capacity);
        try std.testing.expectEqual(backing, transfer.items.items.ptr);
        try std.testing.expectEqual(@as(usize, 1), transfer.head);
        try std.testing.expectEqual(generation + 3, destination.enqueueGeneration());
        try std.testing.expectEqual(@as(usize, 1), destination.reservations);
        var machine = Interpreter{ .arena = unavailable.allocator(), .env = undefined, .root_shape = undefined };
        try std.testing.expectError(error.OutOfMemory, materializeSettlementBatches(&machine, &destination));
        try std.testing.expectEqual(.queued, transfer.state);
        try std.testing.expectEqual(backing, transfer.items.items.ptr);
        for (transfer.pendingItems(), 11..) |task, n|
            try std.testing.expectEqual(@as(f64, @floatFromInt(n)), task.argument.asNum());
        try std.testing.expectEqual(.transferred_batch, destination.pendingItems()[@intFromBool(nonempty)].kind);
        machine.arena = a;
        try materializeSettlementBatches(&machine, &destination);
        try std.testing.expectEqual(.consumed, transfer.state);
        try std.testing.expectEqual(@as(usize, 0), transfer.items.capacity);
        try std.testing.expectEqual(@as(usize, 0), transfer.head);
        destination.appendInTransactionSlot(Job.make(99));
        if (nonempty) try std.testing.expectEqual(@as(f64, 1), destination.pop().?.argument.asNum());
        for ([_]f64{ 11, 12, 13, 99 }) |n|
            try std.testing.expectEqual(n, destination.pop().?.argument.asNum());
        try std.testing.expect(destination.isEmpty());
        try std.testing.expectEqual(@as(usize, 0), destination.reservations);
    }
}

test "microtask transferred settlement batch expands atomically with sibling reactions" {
    const a = std.testing.allocator;
    const pair = ReactionPair{
        .fulfill = .{ .handler = null, .detached = true },
        .reject = .{ .handler = null, .detached = true },
    };
    var overflow = [_]ReactionPair{pair};
    var settled = Promise{ .state = .fulfilled, .value = Value.num(886), .reactions_inline = pair, .reactions = .fromOwnedSlice(&overflow) };
    var source = MicrotaskQueue{};
    defer source.items.deinit(a);
    try source.append(a, .{ .kind = .settlement_batch, .reaction = undefined, .argument = Value.undef(), .fulfilled = true, .payload = .{ .promise = &settled } });
    const storage = try a.alloc(Microtask, 1);
    var queue = MicrotaskQueue{ .items = .{ .items = storage[0..0], .capacity = storage.len } };
    defer queue.items.deinit(a);
    var transfer = MicrotaskTransfer{};
    try queue.prepareTransfer(a, &transfer);
    queue.publishTransfer(&source, &transfer);
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    var machine = Interpreter{ .arena = unavailable.allocator(), .env = undefined, .root_shape = undefined };
    try std.testing.expectError(error.OutOfMemory, materializeSettlementBatches(&machine, &queue));
    try std.testing.expectEqual(.queued, transfer.state);
    try std.testing.expect(settled.reactions_inline != null);
    try std.testing.expectEqual(@as(usize, 1), settled.reactions.items.len);
    machine.arena = a;
    try materializeSettlementBatches(&machine, &queue);
    try std.testing.expectEqual(.consumed, transfer.state);
    try std.testing.expect(settled.reactions_inline == null);
    try std.testing.expectEqual(@as(usize, 0), settled.reactions.items.len);
    try std.testing.expectEqual(@as(usize, 2), queue.pendingLen());
    for (0..2) |_| {
        const task = queue.pop().?;
        try std.testing.expectEqual(.reaction, task.kind);
        try std.testing.expectEqual(@as(f64, 886), task.argument.asNum());
    }
    try std.testing.expect(queue.isEmpty());
}

test "microtask transfer preparation and empty completion preserve reservation ownership" {
    const a = std.testing.allocator;
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0, .resize_fail_index = 0 });
    var queue = MicrotaskQueue{};
    defer queue.items.deinit(a);
    var transfer = MicrotaskTransfer{};
    try std.testing.expectError(error.OutOfMemory, queue.prepareTransfer(unavailable.allocator(), &transfer));
    try std.testing.expectEqual(.empty, transfer.state);
    try std.testing.expect(transfer.destination == null);
    try std.testing.expectEqual(@as(usize, 0), queue.reservations);
    try queue.prepareTransfer(a, &transfer);
    var empty = MicrotaskQueue{};
    queue.publishTransfer(&empty, &transfer);
    try std.testing.expectEqual(.consumed, transfer.state);
    try std.testing.expectEqual(@as(usize, 0), queue.reservations);
    try std.testing.expectEqual(@as(u64, 0), queue.enqueueGeneration());
    var canceled = MicrotaskTransfer{};
    try queue.prepareTransfer(unavailable.allocator(), &canceled);
    queue.cancelTransfer(&canceled);
    try std.testing.expectEqual(.consumed, canceled.state);
    try std.testing.expectEqual(@as(usize, 0), queue.reservations);
    try std.testing.expectEqual(@sizeOf(?*Promise), @sizeOf(@FieldType(Microtask, "payload")));
}

test "microtask batch reservations survive OOM and nested restoration" {
    const storage = try std.testing.allocator.alloc(Microtask, 8);
    defer std.testing.allocator.free(storage);
    var queue = MicrotaskQueue{ .items = .{ .items = storage[0..0], .capacity = storage.len } };
    var unavailable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const a = unavailable.allocator();
    const Job = struct {
        fn make(n: f64) Microtask {
            return .{ .kind = .native_callback, .reaction = undefined, .argument = Value.num(n), .fulfilled = true };
        }
    };
    try queue.reserveTransactionSlot(a);
    try queue.append(a, Job.make(1));
    try queue.append(a, Job.make(2));
    const outer = [_]Microtask{ Job.make(1), Job.make(2) };
    const outer_count = queue.detachBatch();
    try queue.append(a, Job.make(3));
    try queue.append(a, Job.make(4));
    const inner = [_]Microtask{ Job.make(3), Job.make(4) };
    const inner_count = queue.detachBatch();
    try queue.append(a, Job.make(5));
    try queue.append(a, Job.make(6));
    try queue.append(a, Job.make(7));
    try std.testing.expectError(error.OutOfMemory, queue.append(a, Job.make(8)));
    try std.testing.expectEqual(@as(usize, 5), queue.reservations);
    const allocations = unavailable.alloc_index;
    queue.restoreBatch(inner[1..], inner_count);
    queue.restoreBatch(outer[1..], outer_count);
    try std.testing.expectEqual(allocations, unavailable.alloc_index);
    try std.testing.expectEqual(@as(usize, 1), queue.reservations);
    queue.appendInTransactionSlot(Job.make(9));
    for ([_]f64{ 2, 4, 5, 6, 7, 9 }) |n|
        try std.testing.expectEqual(n, queue.pop().?.argument.asNum());
    try std.testing.expect(queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), queue.reservations);
    try queue.append(a, Job.make(10));
    const completed = queue.detachBatch();
    queue.finishBatch(completed);
    try std.testing.expectEqual(@as(usize, 0), queue.reservations);
    try std.testing.expectEqual(@as(usize, 8), queue.items.capacity);
}

test "MicrotaskQueue lock is trace-sensitive" {
    var q = MicrotaskQueue{};

    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    q.acquire();
    defer q.release();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
}

test "Promise state mutex is conditional but mutations remain trace-sensitive" {
    promise_profile.resetPromiseStats();
    defer promise_profile.disablePromiseStats();
    var p = Promise{};

    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    p.lockState();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
    p.unlockState();
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    try std.testing.expectEqual(@as(u64, 0), promise_profile.promiseStats().promise_lock_acquires);

    p.state_locking = true;
    p.lockState();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
    p.unlockState();
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    try std.testing.expectEqual(@as(u64, 1), promise_profile.promiseStats().promise_lock_acquires);
}

test "Promise reaction pairs keep first entry inline then reserve overflow chunks" {
    const a = std.testing.allocator;
    var live: usize = 0;
    var machine = Interpreter{
        .arena = a,
        .env = undefined,
        .root_shape = undefined,
        .gc_side_storage = a,
        .gc_promise_reactions_live = &live,
    };
    var p = Promise{ .gc_owned = true };
    defer p.reactions.deinit(reactionAllocator(&machine));

    const reaction = Reaction{
        .handler = null,
        .resolve = Value.undef(),
        .reject = Value.undef(),
    };
    const pair = ReactionPair{ .fulfill = reaction, .reject = reaction };
    try appendReactionPairUnlocked(&machine, &p, pair);
    try std.testing.expect(p.reactions_inline != null);
    try std.testing.expectEqual(@as(usize, 0), p.reactions.capacity);
    try std.testing.expectEqual(@as(usize, 2), live);

    try appendReactionPairUnlocked(&machine, &p, pair);
    try std.testing.expect(p.reactions.capacity >= reaction_list_reserve_granularity);
    try std.testing.expectEqual(@as(usize, 1), p.reactions.items.len);
    try std.testing.expectEqual(@as(usize, 4), live);

    const first_capacity = p.reactions.capacity;
    while (p.reactions.items.len < first_capacity) {
        try appendReactionPairUnlocked(&machine, &p, pair);
    }
    try std.testing.expectEqual(first_capacity, p.reactions.items.len);
    try std.testing.expectEqual(first_capacity, p.reactions.capacity);
    try std.testing.expectEqual((first_capacity + 1) * 2, live);

    try appendReactionPairUnlocked(&machine, &p, pair);
    try std.testing.expectEqual(first_capacity + 1, p.reactions.items.len);
    try std.testing.expect(p.reactions.capacity > first_capacity);
    try std.testing.expectEqual((first_capacity + 2) * 2, live);

    popReactionPairUnlocked(&machine, &p);
    try std.testing.expectEqual(first_capacity, p.reactions.items.len);
    try std.testing.expectEqual((first_capacity + 1) * 2, live);
}

/// Shared aggregation state for the combinators (`Promise.all`/`allSettled`/
/// `any`). `result` is the combined promise; `values` the in-order results
/// array; `remaining` counts inputs not yet settled; `kind` selects how each
/// element's outcome is recorded.
pub const Combine = struct {
    lock: std.atomic.Mutex = .unlocked,
    /// The combined promise's capability resolve/reject functions (so the result
    /// can be a subclass instance, not just a native promise).
    resolve: Value,
    reject: Value,
    values: *Object,
    keys: ?[]const []const u8 = null,
    remaining: usize,
    settled: bool = false,
    kind: enum { all, all_settled, any, all_keyed, all_settled_keyed },

    pub fn lockState(self: *Combine) void {
        var spins: usize = 0;
        while (!self.lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn unlockState(self: *Combine) void {
        gc_runtime.leaveTraceSensitiveLock();
        self.lock.unlock();
    }
};

/// A per-element reaction's captured context: which `Combine` it belongs to and
/// the element's index (so results land in order). Stored on the closure's
/// `private_data`.
pub const Elem = struct {
    combine: *Combine,
    index: usize,
    is_reject: bool,
    /// [[AlreadyCalled]] — shared between the resolve and reject element
    /// functions of one element, so the element settles at most once. Protected
    /// by `combine.lock`.
    already: *bool,
};

fn resolvingStateObject(fnobj: *Object) ?*Object {
    if (fnobj.native == resolveThunk) return fnobj;
    if (fnobj.native == rejectThunk) {
        const raw = fnobj.private_data orelse return null;
        return @ptrCast(@alignCast(raw));
    }
    return null;
}

fn resolvingTarget(state: *Object) ?*Promise {
    const raw = state.private_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Native resolve/reject closures (used for thenable assimilation): the resolve
/// function object owns the shared resolving record, and the paired reject
/// function's `private_data` points at that resolve object.
fn resolveThunk(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return Value.undef();
    const argument = if (args.len > 0) args[0] else Value.undef();
    const roots_mark = try self.pushTempRootSlice(&.{ Value.obj(fnobj), argument });
    defer self.restoreTempRoots(roots_mark);
    const state = resolvingStateObject(
        self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
    ) orelse return Value.undef();
    const target = resolvingTarget(state) orelse return Value.undef();
    const promise_mark = try self.pushTempPromiseRoot(target);
    defer self.restoreTempPromiseRoots(promise_mark);
    const initial_state = resolvingStateObject(
        self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
    ) orelse return Value.undef();
    if (initial_state.promise_resolving_already.load(.acquire)) return Value.undef();
    var reservation = reserveResolvingJob(self) catch |err| {
        // A peer may have committed while this contender tried to reserve its
        // own publication slot. Once that release is visible this call is the
        // specified allocation-free no-op, not an unrelated OOM observation.
        const current_state = resolvingStateObject(
            self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
        ) orelse return Value.undef();
        if (current_state.promise_resolving_already.load(.acquire)) return Value.undef();
        return err;
    };
    defer cancelResolvingJob(self, &reservation);
    const current_state = resolvingStateObject(
        self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
    ) orelse {
        cancelResolvingJob(self, &reservation);
        return Value.undef();
    };
    if (current_state.promise_resolving_already.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        cancelResolvingJob(self, &reservation);
        return Value.undef();
    }
    try resolveRootedWithReservation(
        self,
        promise_mark,
        target,
        roots_mark + 1,
        argument,
        &reservation,
    );
    std.debug.assert(!reservation.active);
    return Value.undef();
}

fn rejectThunk(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return Value.undef();
    const reason = if (args.len > 0) args[0] else Value.undef();
    const roots_mark = try self.pushTempRootSlice(&.{ Value.obj(fnobj), reason });
    defer self.restoreTempRoots(roots_mark);
    const state = resolvingStateObject(
        self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
    ) orelse return Value.undef();
    const target = resolvingTarget(state) orelse return Value.undef();
    const promise_mark = try self.pushTempPromiseRoot(target);
    defer self.restoreTempPromiseRoots(promise_mark);
    const initial_state = resolvingStateObject(
        self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
    ) orelse return Value.undef();
    if (initial_state.promise_resolving_already.load(.acquire)) return Value.undef();
    var reservation = reserveResolvingJob(self) catch |err| {
        const current_state = resolvingStateObject(
            self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
        ) orelse return Value.undef();
        if (current_state.promise_resolving_already.load(.acquire)) return Value.undef();
        return err;
    };
    const current_state = resolvingStateObject(
        self.tempRoot(roots_mark, Value.obj(fnobj)).asObj(),
    ) orelse {
        cancelResolvingJob(self, &reservation);
        return Value.undef();
    };
    if (current_state.promise_resolving_already.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        cancelResolvingJob(self, &reservation);
        return Value.undef();
    }
    try settleWithReservation(
        self,
        self.tempPromiseRoot(promise_mark, target),
        .rejected,
        self.tempRoot(roots_mark + 1, reason),
        &reservation,
    );
    std.debug.assert(!reservation.active);
    return Value.undef();
}

pub fn promiseOf(v: Value) ?*Promise {
    if (v.isObject()) {
        if (v.asObj().promiseData()) |p| return @ptrCast(@alignCast(p));
    }
    return null;
}

/// Trace engine-owned `private_data` carried by promise resolving functions.
/// Host callbacks remain opaque; this recognizes only the native closures
/// allocated in this file.
pub fn traceNativePrivateData(o: *Object, v: anytype) void {
    const nf = o.native orelse return;
    if (nf == resolveThunk) {
        if (resolvingTarget(o)) |p| v.mark(p);
        return;
    }
    if (nf == rejectThunk) {
        const pd = o.private_data orelse return;
        const state: *Object = @ptrCast(@alignCast(pd));
        v.mark(state);
        if (resolvingTarget(state)) |p| v.mark(p);
    }
}

pub fn relocateNativePrivateData(o: *Object, v: anytype) void {
    const nf = o.native orelse return;
    if (nf == resolveThunk) {
        gc_relocation.rewriteOptionalSlot(v, anyopaque, &o.private_data);
        return;
    }
    if (nf == rejectThunk) {
        gc_relocation.rewriteOptionalSlot(v, anyopaque, &o.private_data);
        const state: *Object = @ptrCast(@alignCast(o.private_data orelse return));
        gc_relocation.rewriteOptionalSlot(v, anyopaque, &state.private_data);
    }
}

test "promise native private relocation mirrors resolving closure tracing" {
    var old_promise: Promise = .{};
    var new_promise: Promise = .{};
    var old_state = Object{ .native = resolveThunk, .private_data = @ptrCast(&old_promise) };
    var new_state = Object{ .native = resolveThunk, .private_data = @ptrCast(&old_promise) };
    var resolve_object = Object{ .native = resolveThunk, .private_data = @ptrCast(&old_promise) };
    var reject_object = Object{ .native = rejectThunk, .private_data = @ptrCast(&old_state) };

    const Plan = struct {
        old_promise: *Promise,
        new_promise: *Promise,
        old_state: *Object,
        new_state: *Object,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            if (old == @as(*anyopaque, @ptrCast(self.old_promise))) return @ptrCast(self.new_promise);
            if (old == @as(*anyopaque, @ptrCast(self.old_state))) return @ptrCast(self.new_state);
            return old;
        }
    };
    const plan = Plan{
        .old_promise = &old_promise,
        .new_promise = &new_promise,
        .old_state = &old_state,
        .new_state = &new_state,
    };
    relocateNativePrivateData(&resolve_object, &plan);
    relocateNativePrivateData(&reject_object, &plan);

    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_promise)), resolve_object.private_data.?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_state)), reject_object.private_data.?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_promise)), new_state.private_data.?);
}

/// Allocate a fresh pending Promise object (proto = `Promise.prototype`).
pub fn newPromise(self: *Interpreter) EvalError!*Object {
    const p = try gc_mod.allocPromise(self.arena);
    promise_profile.recordPromiseStateCell();
    p.* = .{
        .gc_owned = gc_mod.allocationsAreManaged(),
        .state_locking = self.lock_promise_state,
    };
    const obj = try gc_mod.allocObj(self.arena);
    promise_profile.recordPromiseWrapperObject();
    obj.* = .{};
    try obj.setPromiseData(self.arena, @ptrCast(p));
    gc_mod.barrierCellFrom(p, @ptrCast(obj));
    p.wrapper = obj;
    const promise_ctor = self.env.get("\x00Promise") orelse self.env.get("Promise");
    if (promise_ctor) |ctor| {
        if (ctor.isObject()) obj.proto = try self.protoObject(ctor.asObj());
    }
    promise_profile.recordPromiseCreated();
    return obj;
}

/// Allocate a fresh already-settled native Promise object. This is only valid
/// for intrinsic Promise paths that do not need user-observable resolving
/// functions or thenable assimilation.
pub fn newSettledPromise(self: *Interpreter, state: State, v: Value) EvalError!*Object {
    std.debug.assert(state != .pending);
    const obj = try newPromise(self);
    const p: *Promise = @ptrCast(@alignCast(obj.promiseData().?));
    p.state = state;
    gc_mod.barrierValueFrom(p, v);
    p.value = v;
    return obj;
}

/// Create a rejected promise through the ordinary RejectPromise path so the
/// realm's HostPromiseRejectionTracker observes it. Private ABI constructors
/// that deliberately suppress tracking keep using `newSettledPromise`.
pub fn newRejectedPromise(self: *Interpreter, reason: Value) EvalError!*Object {
    const obj = try newPromise(self);
    try reject(self, @ptrCast(@alignCast(obj.promiseData().?)), reason);
    return obj;
}

inline fn reactionAllocator(self: *Interpreter) std.mem.Allocator {
    return self.gc_side_storage orelse self.arena;
}

fn noteReactionsAdded(self: *Interpreter, p: *Promise, count: usize) void {
    if (!p.gc_owned or count == 0) return;
    if (self.gc_promise_reactions_live) |live| _ = @atomicRmw(usize, live, .Add, count, .monotonic);
}

fn noteReactionsRemoved(self: *Interpreter, p: *Promise, count: usize) void {
    if (!p.gc_owned or count == 0) return;
    if (self.gc_promise_reactions_live) |live| {
        _ = @atomicRmw(usize, live, .Sub, count, .monotonic);
    }
}

fn reserveReactionListUnlocked(self: *Interpreter, list: *std.ArrayListUnmanaged(ReactionPair), additional: usize) EvalError!void {
    if (additional == 0) return;
    const spare = list.capacity - list.items.len;
    if (spare >= additional) return;
    const extra = @max(additional, reaction_list_reserve_granularity);
    promise_profile.recordReactionListGrow();
    try list.ensureTotalCapacity(reactionAllocator(self), list.items.len + extra);
}

fn barrierReactionFrom(p: *Promise, r: Reaction) void {
    // Incremental-GC barrier: the reaction's callbacks are stored into the live
    // promise cell (which may already be marked black). Shade them.
    if (r.handler) |h| gc_mod.barrierValueFrom(p, h);
    if (r.result) |result| {
        gc_mod.barrierCellFrom(p, @ptrCast(result));
    } else {
        gc_mod.barrierValueFrom(p, r.resolve);
        gc_mod.barrierValueFrom(p, r.reject);
    }
}

fn appendReactionPairUnlocked(self: *Interpreter, p: *Promise, pair: ReactionPair) EvalError!void {
    barrierReactionFrom(p, pair.fulfill);
    barrierReactionFrom(p, pair.reject);
    if (p.reactions_inline == null) {
        p.reactions_inline = pair;
        noteReactionsAdded(self, p, 2);
        return;
    }
    try reserveReactionListUnlocked(self, &p.reactions, 1);
    p.reactions.appendAssumeCapacity(pair);
    noteReactionsAdded(self, p, 2);
}

fn popReactionPairUnlocked(self: *Interpreter, p: *Promise) void {
    if (p.reactions.items.len > 0) {
        _ = p.reactions.pop();
    } else {
        p.reactions_inline = null;
    }
    noteReactionsRemoved(self, p, 2);
}

pub fn snapshot(p: *Promise) struct { state: State, value: Value } {
    p.lockState();
    defer p.unlockState();
    return .{ .state = p.state, .value = p.value };
}

pub fn isPending(p: *Promise) bool {
    p.lockState();
    defer p.unlockState();
    return p.state == .pending;
}

fn disposeMovedReactions(self: *Interpreter, p: *Promise, pairs: *std.ArrayListUnmanaged(ReactionPair), count: usize) void {
    if (p.gc_owned) pairs.deinit(reactionAllocator(self));
    noteReactionsRemoved(self, p, count);
}

const MicrotaskReservation = struct {
    queue: ?*MicrotaskQueue = null,
    active: bool = false,
};

fn reserveResolvingJob(self: *Interpreter) EvalError!MicrotaskReservation {
    const queue = self.microtasks orelse return .{};
    self.lockMicrotasks();
    defer self.unlockMicrotasks();
    try queue.reserveTransactionSlot(self.arena);
    return .{ .queue = queue, .active = true };
}

fn cancelResolvingJob(self: *Interpreter, reservation: *MicrotaskReservation) void {
    if (!reservation.active) return;
    const queue = reservation.queue.?;
    self.lockJobQueue(queue);
    queue.cancelTransactionSlot();
    self.unlockJobQueue(queue);
    reservation.active = false;
}

/// Locks and prepared capacity form the Promise state/publication transaction.
/// The commit does not grow Promise/queue storage or execute JavaScript.
const LockedSettlement = struct {
    machine: *Interpreter,
    target: *Promise,
    state: State,
    realm_locked: bool,

    fn begin(self: *Interpreter, p: *Promise, state: State) LockedSettlement {
        std.debug.assert(state != .pending);
        self.lockMicrotasks();
        const realm_locked = state == .rejected and self.unhandled_rejections != null and self.realm_lock != null;
        if (realm_locked) self.lockRealm();
        p.lockState();
        return .{ .machine = self, .target = p, .state = state, .realm_locked = realm_locked };
    }

    fn end(locked: *const LockedSettlement) void {
        locked.target.unlockState();
        if (locked.realm_locked) locked.machine.unlockRealm();
        locked.machine.unlockMicrotasks();
    }

    fn reactionCount(locked: *const LockedSettlement) usize {
        return locked.target.reactions.items.len + @intFromBool(locked.target.reactions_inline != null);
    }

    fn commit(locked: *const LockedSettlement, v: Value, reservation: ?*MicrotaskReservation) void {
        const self = locked.machine;
        const p = locked.target;
        const state = locked.state;
        const pair_count = locked.reactionCount();
        const queue = self.microtasks;
        const unhandled_queue = if (state == .rejected) self.unhandled_rejections else null;
        std.debug.assert(p.state == .pending);
        p.state = state;
        gc_mod.barrierValueFrom(p, v); // settlement value stored into the live promise cell
        p.value = v;
        if (state == .rejected and !p.is_handled and !p.rejection_queued and !p.rejection_notified) {
            if (unhandled_queue) |rejections| {
                p.rejection_queued = true;
                rejections.append(p);
                gc_mod.barrierCell(p);
            }
        }
        if (queue) |jobs| {
            if (pair_count != 0) {
                const task = Microtask{
                    .kind = .settlement_batch,
                    .reaction = undefined,
                    .argument = Value.undef(),
                    .fulfilled = state == .fulfilled,
                    .payload = .{ .promise = p },
                };
                if (reservation) |slot| {
                    jobs.appendInTransactionSlot(task);
                    slot.active = false;
                } else {
                    jobs.appendAssumeCapacity(task);
                }
                for (0..pair_count) |_| promise_profile.recordMicrotaskEnqueue(false);
            } else if (reservation) |slot| {
                jobs.cancelTransactionSlot();
                slot.active = false;
            }
        } else if (reservation) |slot| {
            std.debug.assert(!slot.active);
        }
        // The selected reactions remain traced by the settled Promise until batch
        // materialization copies them into ordinary queue jobs. Their retained
        // activation edges therefore bridge this interval directly.
        if (!p.rejection_linked.load(.acquire))
            p.awaiting_activation_or_rejection_link.awaiting_async_activation = null;
        p.async_forward_to = null;
    }
};

fn settleWithReservation(
    self: *Interpreter,
    p: *Promise,
    state: State,
    v: Value,
    reservation: ?*MicrotaskReservation,
) EvalError!void {
    const locked = LockedSettlement.begin(self, p, state);
    if (p.state != .pending) {
        locked.end();
        if (reservation) |slot| cancelResolvingJob(self, slot);
        return;
    }
    if (self.microtasks) |queue| if (locked.reactionCount() != 0) {
        if (reservation) |slot| {
            std.debug.assert(slot.active and slot.queue == queue);
        } else {
            queue.reserve(self.arena, 1) catch |err| {
                locked.end();
                return err;
            };
        }
    };
    locked.commit(v, reservation);
    locked.end();
}

/// An intrinsic Promise completion slot reserved before its capability escapes.
/// Resolution retains this slot on error so the owner can reject with its exact
/// rooted failure value. Move this token with the capability; never copy it into
/// two live owners. All methods use the queue that was reserved at preparation.
pub const PreparedSettlement = struct {
    slot: MicrotaskReservation = .{},

    pub fn prepare(self: *Interpreter, queue: *MicrotaskQueue) EvalError!PreparedSettlement {
        self.lockJobQueue(queue);
        defer self.unlockJobQueue(queue);
        try queue.reserveTransactionSlot(self.arena);
        return .{ .slot = .{ .queue = queue, .active = true } };
    }

    pub fn cancel(prepared: *PreparedSettlement, self: *Interpreter) void {
        cancelResolvingJob(self, &prepared.slot);
    }

    pub fn resolve(prepared: *PreparedSettlement, self: *Interpreter, p: *Promise, v: Value) EvalError!void {
        std.debug.assert(prepared.slot.active);
        const saved = self.microtasks;
        self.microtasks = prepared.slot.queue.?;
        defer self.microtasks = saved;
        // On an abrupt completion the caller reloads its authoritative roots
        // before rejecting. No user callback is retried and the slot stays owned.
        try resolveWithReservation(self, p, v, &prepared.slot);
        prepared.cancel(self);
    }

    /// Inputs must already have durable roots. Rejection-tracker and reaction
    /// publication need no interpreter/queue growth, safepoint, or JS call.
    pub fn reject(prepared: *PreparedSettlement, self: *Interpreter, p: *Promise, reason: Value) void {
        std.debug.assert(prepared.slot.active);
        const saved = self.microtasks;
        self.microtasks = prepared.slot.queue.?;
        defer self.microtasks = saved;
        const locked = LockedSettlement.begin(self, p, .rejected);
        if (p.state == .pending) locked.commit(reason, &prepared.slot);
        locked.end();
        prepared.cancel(self);
    }
};

fn settle(self: *Interpreter, p: *Promise, state: State, v: Value) EvalError!void {
    return settleWithReservation(self, p, state, v, null);
}

fn settlementJobCount(task: Microtask) usize {
    std.debug.assert(task.kind != .transferred_batch);
    if (task.kind != .settlement_batch) return 1;
    const p = task.payload.promise orelse unreachable;
    p.lockState();
    defer p.unlockState();
    const count = p.reactions.items.len + @intFromBool(p.reactions_inline != null);
    std.debug.assert(count != 0);
    return count;
}

fn materializedJobCount(task: Microtask) EvalError!usize {
    if (task.kind != .transferred_batch) return settlementJobCount(task);
    const transfer = task.payload.transfer;
    std.debug.assert(transfer.state == .queued);
    var count: usize = 0;
    // Only the realm queue accepts transfers; a closed worker buffer contains
    // ordinary/settlement jobs, so the graph is one level deep, never recursive.
    for (transfer.pendingItems()) |child|
        count = std.math.add(usize, count, settlementJobCount(child)) catch return error.OutOfMemory;
    std.debug.assert(count != 0);
    return count;
}

fn materializeSettlement(self: *Interpreter, task: Microtask, output: []Microtask) void {
    if (task.kind != .settlement_batch) {
        std.debug.assert(task.kind != .transferred_batch and output.len == 1);
        output[0] = task;
        return;
    }
    const p = task.payload.promise orelse unreachable;
    p.lockState();
    const inline_pair = p.reactions_inline;
    var pairs = p.reactions;
    var out: usize = 0;
    if (inline_pair) |pair| {
        output[out] = .{
            .reaction = if (task.fulfilled) pair.fulfill else pair.reject,
            .argument = p.value,
            .fulfilled = task.fulfilled,
        };
        out += 1;
    }
    for (pairs.items) |pair| {
        output[out] = .{
            .reaction = if (task.fulfilled) pair.fulfill else pair.reject,
            .argument = p.value,
            .fulfilled = task.fulfilled,
        };
        out += 1;
    }
    std.debug.assert(out == output.len);
    p.reactions_inline = null;
    p.reactions = .empty;
    p.unlockState();
    disposeMovedReactions(self, p, &pairs, out * 2);
}

/// Reserve the complete expanded layout before either reaction or transferred
/// backing ownership changes. OOM retains every descriptor and its graph in the
/// destination queue. The commit pass only moves/copies owned jobs and frees
/// consumed backing; no allocator growth or user code remains.
pub fn materializeSettlementBatches(self: *Interpreter, queue: *MicrotaskQueue) EvalError!void {
    var pending = queue.pendingItems();
    var expanded_len = pending.len;
    var has_batch = false;
    for (pending) |task| {
        if (task.kind != .settlement_batch and task.kind != .transferred_batch) continue;
        has_batch = true;
        expanded_len = std.math.add(usize, expanded_len, (try materializedJobCount(task)) - 1) catch return error.OutOfMemory;
    }
    if (!has_batch) return;
    if (queue.head != 0) {
        std.mem.copyForwards(Microtask, queue.items.items[0..pending.len], pending);
        queue.items.items.len = pending.len;
        queue.head = 0;
        pending = queue.items.items;
    }
    try queue.reserve(self.arena, expanded_len - pending.len);
    const original_len = pending.len;
    queue.items.items.len = expanded_len;
    var read = original_len;
    var write = expanded_len;
    while (read != 0) {
        read -= 1;
        const task = queue.items.items[read];
        // The first pass proved this exact immutable descriptor count fits.
        const count = materializedJobCount(task) catch unreachable;
        write -= count;
        const output = queue.items.items[write..][0..count];
        if (task.kind == .transferred_batch) {
            const transfer = task.payload.transfer;
            std.debug.assert(transfer.destination == queue);
            var out: usize = 0;
            for (transfer.pendingItems()) |child| {
                const child_count = settlementJobCount(child);
                materializeSettlement(self, child, output[out..][0..child_count]);
                out += child_count;
            }
            std.debug.assert(out == count);
            transfer.items.deinit(self.arena);
            transfer.items = .empty;
            transfer.head = 0;
            transfer.state = .consumed;
        } else materializeSettlement(self, task, output);
    }
    std.debug.assert(write == 0);
}

fn resolveRootedWithReservation(
    self: *Interpreter,
    promise_mark: usize,
    p: *Promise,
    value_mark: usize,
    v: Value,
    reservation: ?*MicrotaskReservation,
) EvalError!void {
    if (!isPending(self.tempPromiseRoot(promise_mark, p))) return;
    if (promiseOf(self.tempRoot(value_mark, v))) |inner|
        if (inner == self.tempPromiseRoot(promise_mark, p)) {
            const err = try self.makeError("TypeError", "Cannot resolve promise with itself");
            try settleWithReservation(self, self.tempPromiseRoot(promise_mark, p), .rejected, err, reservation);
            return;
        };
    // Thenable assimilation: `then` is read synchronously from every object
    // resolution (including native promises and arrays), then invoked from the
    // queued PromiseResolveThenableJob.
    if (self.tempRoot(value_mark, v).isObject()) {
        const then_fn = self.getProperty(self.tempRoot(value_mark, v), "then") catch |err| {
            if (err == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                try settleWithReservation(self, self.tempPromiseRoot(promise_mark, p), .rejected, reason, reservation);
                return;
            }
            return err;
        };
        if (then_fn.isCallable()) {
            try enqueueWithReservation(self, .{
                .kind = .thenable,
                .reaction = undefined,
                .argument = Value.undef(),
                .fulfilled = true,
                .thenable = self.tempRoot(value_mark, v),
                .then_fn = then_fn,
                .payload = .{ .promise = self.tempPromiseRoot(promise_mark, p) },
            }, reservation);
            if (promiseOf(self.tempRoot(value_mark, v))) |inner|
                linkAsyncForward(inner, self.tempPromiseRoot(promise_mark, p));
            return;
        }
    }
    try settleWithReservation(
        self,
        self.tempPromiseRoot(promise_mark, p),
        .fulfilled,
        self.tempRoot(value_mark, v),
        reservation,
    );
}

fn resolveWithReservation(
    self: *Interpreter,
    p: *Promise,
    v: Value,
    reservation: ?*MicrotaskReservation,
) EvalError!void {
    const promise_mark = try self.pushTempPromiseRoot(p);
    defer self.restoreTempPromiseRoots(promise_mark);
    const value_mark = try self.pushTempRoot(v);
    defer self.restoreTempRoots(value_mark);
    try resolveRootedWithReservation(self, promise_mark, p, value_mark, v, reservation);
}

/// Fulfill `p` with `v` (no-op if already settled). If `v` is itself a thenable,
/// adopt its state instead (resolution).
pub fn resolve(self: *Interpreter, p: *Promise, v: Value) EvalError!void {
    return resolveWithReservation(self, p, v, null);
}

/// Reject `p` with `reason` (no-op if already settled).
pub fn reject(self: *Interpreter, p: *Promise, reason: Value) EvalError!void {
    const promise_mark = try self.pushTempPromiseRoot(p);
    defer self.restoreTempPromiseRoots(promise_mark);
    const reason_mark = try self.pushTempRoot(reason);
    defer self.restoreTempRoots(reason_mark);
    try settle(
        self,
        self.tempPromiseRoot(promise_mark, p),
        .rejected,
        self.tempRoot(reason_mark, reason),
    );
}

/// `p.then(onFulfilled, onRejected)` → a new promise settled by running the
/// matching handler when `p` settles (pass-through if the handler is absent).
/// Native resolve/reject closures over `p`'s state (a capability whose promise
/// is the native `p`). Used wherever the result is an intrinsic promise.
pub fn nativeResolveReject(self: *Interpreter, p: *Promise) EvalError!struct { resolve: Value, reject: Value } {
    const promise_mark = try self.pushTempPromiseRoot(p);
    defer self.restoreTempPromiseRoots(promise_mark);
    promise_profile.recordResolvingFunctionPair();
    const res = try gc_mod.allocObj(self.arena);
    const resolve_mark = try self.pushTempRoot(Value.obj(res));
    defer self.restoreTempRoots(resolve_mark);
    promise_profile.recordResolvingFunctionObject();
    self.tempRoot(resolve_mark, Value.obj(res)).asObj().* = .{
        .native = resolveThunk,
        .private_data = @ptrCast(self.tempPromiseRoot(promise_mark, p)),
    };
    try interp.installNativeProps(
        self.arena,
        self.root_shape,
        self.tempRoot(resolve_mark, Value.obj(res)).asObj(),
        "",
        1,
    );
    const rej = try gc_mod.allocObj(self.arena);
    const reject_mark = try self.pushTempRoot(Value.obj(rej));
    defer self.restoreTempRoots(reject_mark);
    promise_profile.recordResolvingFunctionObject();
    self.tempRoot(reject_mark, Value.obj(rej)).asObj().* = .{
        .native = rejectThunk,
        .private_data = @ptrCast(self.tempRoot(resolve_mark, Value.obj(res)).asObj()),
    };
    try interp.installNativeProps(
        self.arena,
        self.root_shape,
        self.tempRoot(reject_mark, Value.obj(rej)).asObj(),
        "",
        1,
    );
    return .{
        .resolve = self.tempRoot(resolve_mark, Value.obj(res)),
        .reject = self.tempRoot(reject_mark, Value.obj(rej)),
    };
}

/// `p.then(...)` with an intrinsic result promise (the non-species path used
/// internally by the combinators, `finally`, and the async drivers).
/// PerformPromiseThen: register fulfill/reject reactions that settle the result
/// capability (`resolve_fn`/`reject_fn`) when `p` settles.
pub fn performThen(self: *Interpreter, p: *Promise, on_f: Value, on_r: Value, resolve_fn: Value, reject_fn: Value) EvalError!void {
    const fh: ?Value = if (on_f.isCallable()) on_f else null;
    const rh: ?Value = if (on_r.isCallable()) on_r else null;
    const react_f = Reaction{ .handler = fh, .resolve = resolve_fn, .reject = reject_fn };
    const react_r = Reaction{ .handler = rh, .resolve = resolve_fn, .reject = reject_fn };
    try performThenReactions(self, p, react_f, react_r);
}

/// Internal intrinsic-Promise path: register reactions that settle `result`
/// directly. Use only when the result capability is the engine's own native
/// Promise; custom species/external capabilities must use `performThen`.
pub fn performThenResult(self: *Interpreter, p: *Promise, on_f: Value, on_r: Value, result: *Promise) EvalError!void {
    const fh: ?Value = if (on_f.isCallable()) on_f else null;
    const rh: ?Value = if (on_r.isCallable()) on_r else null;
    const react_f = Reaction{ .handler = fh, .result = result };
    const react_r = Reaction{ .handler = rh, .result = result };
    try performThenReactions(self, p, react_f, react_r);
    if (fh == null and rh == null) linkAsyncForward(p, result);
}

/// Async-driver variant of `then`: the continuation activation stays precisely
/// rooted after source settlement moves its reactions into the microtask queue.
pub fn thenRetainingAsyncActivation(
    self: *Interpreter,
    p: *Promise,
    on_f: Value,
    on_r: Value,
    activation: *anyopaque,
) EvalError!Value {
    const result = try newPromise(self);
    const rp: *Promise = @ptrCast(@alignCast(result.promiseData().?));
    const fh: ?Value = if (on_f.isCallable()) on_f else null;
    const rh: ?Value = if (on_r.isCallable()) on_r else null;
    const react_f = Reaction{ .handler = fh, .result = rp, .retained_async_activation = activation };
    const react_r = Reaction{ .handler = rh, .result = rp, .retained_async_activation = activation };
    try performThenReactions(self, p, react_f, react_r);
    return Value.obj(result);
}

/// Register host callbacks without creating a dependent Promise. Both handlers
/// receive `(settlement_value, context)` in their CallFrame, matching Bun's
/// private `JSC__JSValue___then` bridge.
pub fn performThenDetached(self: *Interpreter, p: *Promise, on_f: Value, on_r: Value, context: Value) EvalError!void {
    const react_f = Reaction{ .handler = on_f, .extra_argument = context, .detached = true };
    const react_r = Reaction{ .handler = on_r, .extra_argument = context, .detached = true };
    try performThenReactions(self, p, react_f, react_r);
}

pub fn then(self: *Interpreter, p: *Promise, on_f: Value, on_r: Value) EvalError!Value {
    const result = try newPromise(self);
    const rp: *Promise = @ptrCast(@alignCast(result.promiseData().?));
    try performThenResult(self, p, on_f, on_r, rp);
    return Value.obj(result);
}

fn performThenReactions(self: *Interpreter, p: *Promise, react_f: Reaction, react_r: Reaction) EvalError!void {
    p.lockState();
    if (p.state == .pending) {
        appendReactionPairUnlocked(self, p, .{ .fulfill = react_f, .reject = react_r }) catch |err| {
            p.unlockState();
            return err;
        };
        p.is_handled = true;
        p.unlockState();
        return;
    }
    const settled_state = p.state;
    p.unlockState();
    // A settled handler is one queue -> realm -> Promise transaction. Reserve
    // its job before publishing handled/tracker state, then append infallibly.
    self.lockMicrotasks();
    const handled_queue = if (settled_state == .rejected) self.handled_rejections else null;
    const realm_locked = handled_queue != null and self.realm_lock != null;
    if (realm_locked) self.lockRealm();
    p.lockState();
    if (self.microtasks) |queue| {
        queue.reserve(self.arena, 1) catch |err| {
            p.unlockState();
            if (realm_locked) self.unlockRealm();
            self.unlockMicrotasks();
            return err;
        };
    }
    if (!p.is_handled and p.state == .rejected and p.rejection_notified and !p.rejection_handled_notified) {
        if (handled_queue) |queue| {
            p.rejection_handled_notified = true;
            queue.append(p);
            gc_mod.barrierCell(p);
        }
    }
    p.is_handled = true;
    const snap = .{ .state = p.state, .value = p.value };
    if (self.microtasks) |queue| {
        const reaction = if (snap.state == .fulfilled) react_f else react_r;
        queue.appendAssumeCapacity(.{ .reaction = reaction, .argument = snap.value, .fulfilled = snap.state == .fulfilled });
        promise_profile.recordMicrotaskEnqueue(false);
    }
    p.unlockState();
    if (realm_locked) self.unlockRealm();
    self.unlockMicrotasks();
}

test "rejection tracker publication is allocation-free and state exact" {
    var unhandled: RejectionQueue = .{};
    defer unhandled.clear();
    var handled: RejectionQueue = .{};
    defer handled.clear();
    var unused_queue: RejectionQueue = .{};
    defer unused_queue.clear();

    var reject_oom = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var machine = Interpreter{
        .arena = reject_oom.allocator(),
        .env = undefined,
        .root_shape = undefined,
        .unhandled_rejections = &unhandled,
        .handled_rejections = &handled,
    };
    var rejected: Promise = .{};

    try settle(&machine, &rejected, .rejected, Value.num(884));
    try std.testing.expect(!reject_oom.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), reject_oom.alloc_index);
    try std.testing.expectEqual(State.rejected, rejected.state);
    try std.testing.expect(rejected.rejection_queued);
    try std.testing.expectEqual(@as(usize, 1), unhandled.pendingLen());
    const notification = takeUnhandledRejection(&machine).?;
    try std.testing.expectEqual(@as(f64, 884), notification.reason.asNum());
    try std.testing.expect(notification.promise.isUndefined());
    try std.testing.expect(!rejected.rejection_queued);
    try std.testing.expect(rejected.rejection_notified);
    try std.testing.expect(unhandled.isEmpty());

    // Repeated settlement and a Promise handled before rejection also remain
    // allocation-free with a fresh queue.
    var no_queue_allocation = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    machine.arena = no_queue_allocation.allocator();
    machine.unhandled_rejections = &unused_queue;
    try settle(&machine, &rejected, .rejected, Value.num(885));
    try std.testing.expectEqual(@as(f64, 884), rejected.value.asNum());
    var prehandled = Promise{ .is_handled = true };
    try settle(&machine, &prehandled, .rejected, Value.num(886));
    try std.testing.expectEqual(State.rejected, prehandled.state);
    try std.testing.expectEqual(@as(f64, 886), prehandled.value.asNum());
    try std.testing.expect(!prehandled.rejection_queued);
    try std.testing.expect(unused_queue.isEmpty());
    try std.testing.expect(!no_queue_allocation.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), no_queue_allocation.alloc_index);

    var handled_oom = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    machine.arena = handled_oom.allocator();
    const reaction = Reaction{ .handler = null, .detached = true };
    try performThenReactions(&machine, &rejected, reaction, reaction);
    try std.testing.expect(!handled_oom.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), handled_oom.alloc_index);
    try std.testing.expect(rejected.is_handled);
    try std.testing.expect(rejected.rejection_handled_notified);
    try std.testing.expectEqual(@as(usize, 1), handled.pendingLen());
    try std.testing.expect(takeHandledRejection(&machine).?.isUndefined());
    try std.testing.expect(handled.isEmpty());
}

test "settlement reserves the complete reaction batch before state commit" {
    const a = std.testing.allocator;
    var queue: MicrotaskQueue = .{};
    defer queue.items.deinit(a);
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var machine = Interpreter{
        .arena = unavailable.allocator(),
        .env = undefined,
        .root_shape = undefined,
        .microtasks = &queue,
    };
    const first = ReactionPair{
        .fulfill = .{ .handler = null, .extra_argument = Value.num(1), .detached = true },
        .reject = .{ .handler = null, .extra_argument = Value.num(-1), .detached = true },
    };
    const second = ReactionPair{
        .fulfill = .{ .handler = null, .extra_argument = Value.num(2), .detached = true },
        .reject = .{ .handler = null, .extra_argument = Value.num(-2), .detached = true },
    };
    var overflow = [_]ReactionPair{second};
    var p = Promise{ .reactions_inline = first, .reactions = .fromOwnedSlice(&overflow) };

    try std.testing.expectError(error.OutOfMemory, settle(&machine, &p, .fulfilled, Value.num(73)));
    try std.testing.expectEqual(State.pending, p.state);
    try std.testing.expect(p.reactions_inline != null);
    try std.testing.expectEqual(@as(usize, 1), p.reactions.items.len);
    try std.testing.expect(queue.isEmpty());

    machine.arena = a;
    try settle(&machine, &p, .fulfilled, Value.num(73));
    try std.testing.expectEqual(State.fulfilled, p.state);
    try std.testing.expectEqual(@as(usize, 1), queue.pendingLen());
    try std.testing.expectEqual(.settlement_batch, queue.pendingItems()[0].kind);
    try materializeSettlementBatches(&machine, &queue);
    try std.testing.expectEqual(@as(usize, 2), queue.pendingLen());
    try std.testing.expectEqual(@as(f64, 1), queue.pendingItems()[0].reaction.extra_argument.?.asNum());
    try std.testing.expectEqual(@as(f64, 2), queue.pendingItems()[1].reaction.extra_argument.?.asNum());
}

test "settlement batch expansion is OOM-atomic between sibling jobs" {
    const a = std.testing.allocator;
    var fixed_bytes: [@sizeOf(Microtask)]u8 align(@alignOf(Microtask)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_bytes);
    const storage = try fixed.allocator().alloc(Microtask, 1);
    var queue = MicrotaskQueue{ .items = .{ .items = storage[0..0], .capacity = storage.len } };
    var machine = Interpreter{
        .arena = fixed.allocator(),
        .env = undefined,
        .root_shape = undefined,
        .microtasks = &queue,
    };
    const pair = ReactionPair{
        .fulfill = .{ .handler = null, .detached = true },
        .reject = .{ .handler = null, .detached = true },
    };
    var overflow = [_]ReactionPair{pair};
    var p = Promise{ .reactions_inline = pair, .reactions = .fromOwnedSlice(&overflow) };

    // One physical slot commits arbitrary fanout without allocation. Expansion
    // then fails before replacing the descriptor with even the first sibling.
    try settle(&machine, &p, .fulfilled, Value.num(7));
    try std.testing.expectEqual(State.fulfilled, p.state);
    try std.testing.expectEqual(@as(usize, 1), queue.pendingLen());
    try std.testing.expectEqual(.settlement_batch, queue.pendingItems()[0].kind);
    try std.testing.expectError(error.OutOfMemory, materializeSettlementBatches(&machine, &queue));
    try std.testing.expectEqual(@as(usize, 1), queue.pendingLen());
    try std.testing.expectEqual(.settlement_batch, queue.pendingItems()[0].kind);
    try std.testing.expect(p.reactions_inline != null);
    try std.testing.expectEqual(@as(usize, 1), p.reactions.items.len);

    const descriptor = queue.pop().?;
    var recovery: MicrotaskQueue = .{};
    defer recovery.items.deinit(a);
    try recovery.append(a, descriptor);
    machine.microtasks = &recovery;
    machine.arena = a;
    try materializeSettlementBatches(&machine, &recovery);
    try std.testing.expectEqual(@as(usize, 2), recovery.pendingLen());
    try std.testing.expectEqual(@as(f64, 7), recovery.pendingItems()[0].argument.asNum());
    try std.testing.expectEqual(@as(f64, 7), recovery.pendingItems()[1].argument.asNum());
}

test "resolving capability reserves settlement publication before once-only commit" {
    const a = std.testing.allocator;
    const pair = ReactionPair{
        .fulfill = .{ .handler = null, .detached = true },
        .reject = .{ .handler = null, .detached = true },
    };
    var overflow = [_]ReactionPair{pair};
    var p = Promise{ .reactions_inline = pair, .reactions = .fromOwnedSlice(&overflow) };
    var state = Object{ .native = resolveThunk, .private_data = @ptrCast(&p) };
    var gc_sentinel: u8 = 0;

    var no_bytes: [0]u8 = .{};
    var unavailable = std.heap.FixedBufferAllocator.init(&no_bytes);
    var preallocated_jobs: [1]Microtask = undefined;
    var root_blocked_queue = MicrotaskQueue{
        .items = .{ .items = preallocated_jobs[0..0], .capacity = preallocated_jobs.len },
    };
    var machine = Interpreter{
        .arena = unavailable.allocator(),
        .env = undefined,
        .root_shape = undefined,
        .microtasks = &root_blocked_queue,
        .active_native = &state,
        .gc = &gc_sentinel,
    };

    // The resolving record and inputs are rooted before [[AlreadyResolved]] is
    // claimed. Root-registration OOM therefore leaves both the record and the
    // already-reserved job queue untouched for an exact retry.
    try std.testing.expectError(error.OutOfMemory, resolveThunk(&machine, Value.undef(), &.{Value.num(884)}));
    try std.testing.expect(!state.promise_resolving_already.load(.acquire));
    try std.testing.expectEqual(State.pending, p.state);
    try std.testing.expect(root_blocked_queue.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), root_blocked_queue.reservations);

    var blocked_queue: MicrotaskQueue = .{};
    var promise_roots: [2]*Promise = undefined;
    var value_roots: [2]Value = undefined;
    machine.microtasks = &blocked_queue;
    machine.gc_temp_promise_roots = .{ .items = promise_roots[0..0], .capacity = promise_roots.len };
    machine.gc_temp_roots = .{ .items = value_roots[0..0], .capacity = value_roots.len };

    try std.testing.expectError(error.OutOfMemory, resolveThunk(&machine, Value.undef(), &.{Value.num(885)}));
    try std.testing.expect(!state.promise_resolving_already.load(.acquire));
    try std.testing.expectEqual(State.pending, p.state);
    try std.testing.expect(blocked_queue.isEmpty());

    var fixed_bytes: [@sizeOf(Microtask)]u8 align(@alignOf(Microtask)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_bytes);
    const storage = try fixed.allocator().alloc(Microtask, 1);
    var queue = MicrotaskQueue{ .items = .{ .items = storage[0..0], .capacity = storage.len } };
    machine.arena = fixed.allocator();
    machine.microtasks = &queue;
    _ = try resolveThunk(&machine, Value.undef(), &.{Value.num(885)});
    try std.testing.expect(state.promise_resolving_already.load(.acquire));
    try std.testing.expectEqual(State.fulfilled, p.state);
    try std.testing.expectEqual(@as(usize, 1), queue.pendingLen());
    try std.testing.expectEqual(.settlement_batch, queue.pendingItems()[0].kind);
    try std.testing.expectEqual(@as(usize, 0), queue.reservations);

    // Duplicate resolve/reject calls observe the committed bit and remain a
    // true allocation-free no-op even though the fixed queue has no spare slot.
    _ = try resolveThunk(&machine, Value.undef(), &.{Value.num(999)});
    try std.testing.expectEqual(@as(f64, 885), p.value.asNum());

    const descriptor = queue.pop().?;
    var recovery: MicrotaskQueue = .{};
    defer recovery.items.deinit(a);
    try recovery.append(a, descriptor);
    machine.arena = a;
    machine.microtasks = &recovery;
    try materializeSettlementBatches(&machine, &recovery);
    try std.testing.expectEqual(@as(usize, 2), recovery.pendingLen());
    try std.testing.expect(p.reactions_inline == null);
    try std.testing.expectEqual(@as(usize, 0), p.reactions.items.len);
}

test "settled then reserves its job before handled tracker publication" {
    const a = std.testing.allocator;
    var queue: MicrotaskQueue = .{};
    defer queue.items.deinit(a);
    var handled: RejectionQueue = .{};
    defer handled.clear();
    var unavailable = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var machine = Interpreter{
        .arena = unavailable.allocator(),
        .env = undefined,
        .root_shape = undefined,
        .microtasks = &queue,
        .handled_rejections = &handled,
    };
    var p = Promise{ .state = .rejected, .value = Value.num(885), .rejection_notified = true };
    const reaction = Reaction{ .handler = null, .detached = true };

    try std.testing.expectError(error.OutOfMemory, performThenReactions(&machine, &p, reaction, reaction));
    try std.testing.expect(!p.is_handled);
    try std.testing.expect(!p.rejection_handled_notified);
    try std.testing.expect(handled.isEmpty());
    try std.testing.expect(queue.isEmpty());

    machine.arena = a;
    try performThenReactions(&machine, &p, reaction, reaction);
    try std.testing.expect(p.is_handled);
    try std.testing.expect(p.rejection_handled_notified);
    try std.testing.expectEqual(@as(usize, 1), handled.pendingLen());
    try std.testing.expectEqual(@as(usize, 1), queue.pendingLen());
    try std.testing.expect(takeHandledRejection(&machine).?.isUndefined());
}

/// Queue a bare callback microtask (HTML `queueMicrotask`). Runs on the same
/// checkpoint as Promise reactions, in FIFO order relative to them.
pub fn enqueueCallback(self: *Interpreter, callback: Value) EvalError!void {
    try enqueue(self, .{ .kind = .callback, .reaction = undefined, .argument = Value.undef(), .fulfilled = true, .callback = callback });
}

pub fn enqueueNativeCallback(
    self: *Interpreter,
    callback_context: ?*anyopaque,
    callback: *const fn (?*anyopaque) callconv(.c) void,
) EvalError!void {
    try enqueue(self, .{
        .kind = .native_callback,
        .reaction = undefined,
        .argument = Value.undef(),
        .fulfilled = true,
        .native_callback_context = callback_context,
        .native_callback = callback,
    });
}

pub fn enqueueJob(self: *Interpreter, job: Value, first: Value, second: Value) EvalError!void {
    try enqueue(self, .{
        .kind = .job,
        .reaction = undefined,
        .argument = Value.undef(),
        .fulfilled = true,
        .job = job,
        .job_first = first,
        .job_second = second,
    });
}

pub fn enqueueNextTick(self: *Interpreter, callback: Value, args: []const Value) EvalError!void {
    const queue = self.next_ticks orelse return;
    const copied_args = try self.arena.dupe(Value, args);
    const task = Microtask{
        .kind = .next_tick,
        .reaction = undefined,
        .argument = Value.undef(),
        .fulfilled = true,
        .job = callback,
        .job_args = copied_args,
    };
    self.lockJobQueue(queue);
    defer self.unlockJobQueue(queue);
    try queue.append(self.arena, task);
}

pub fn takeHandledRejection(self: *Interpreter) ?Value {
    const queue = self.handled_rejections orelse return null;
    self.lockRealm();
    defer self.unlockRealm();
    const handled = queue.pop() orelse return null;
    handled.lockState();
    defer handled.unlockState();
    return if (handled.wrapper) |wrapper| Value.obj(wrapper) else Value.undef();
}

/// Consume the next still-unhandled rejection notification. Promises handled
/// between rejection and this host checkpoint are silently skipped.
pub const RejectionNotification = struct {
    reason: Value,
    promise: Value,
};

pub fn takeUnhandledRejection(self: *Interpreter) ?RejectionNotification {
    const queue = self.unhandled_rejections orelse return null;
    self.lockRealm();
    defer self.unlockRealm();
    while (queue.pop()) |rejected| {
        rejected.lockState();
        rejected.rejection_queued = false;
        if (rejected.is_handled or rejected.rejection_notified or rejected.state != .rejected) {
            rejected.unlockState();
            continue;
        }
        rejected.rejection_notified = true;
        const notification = RejectionNotification{
            .reason = rejected.value,
            .promise = if (rejected.wrapper) |wrapper| Value.obj(wrapper) else Value.undef(),
        };
        rejected.unlockState();
        return notification;
    }
    return null;
}

fn enqueueWithReservation(
    self: *Interpreter,
    task: Microtask,
    reservation: ?*MicrotaskReservation,
) EvalError!void {
    const q = self.microtasks orelse return; // no queue wired → drop (shouldn't happen)
    // Under `parallel_js` a peer thread may drain this queue concurrently; the
    // lock makes the append atomic against the drain's pop. A no-op (single null
    // check) on the GIL-serialized default path.
    self.lockMicrotasks();
    defer self.unlockMicrotasks();
    if (reservation) |slot| {
        std.debug.assert(slot.active and slot.queue == q);
        q.appendInTransactionSlot(task);
        slot.active = false;
    } else {
        try q.append(self.arena, task);
    }
    promise_profile.recordMicrotaskEnqueue(task.kind == .thenable);
}

fn enqueue(self: *Interpreter, task: Microtask) EvalError!void {
    return enqueueWithReservation(self, task, null);
}

/// Run one reaction job: invoke the handler (or pass through) and settle the
/// dependent promise. A handler that throws rejects the dependent promise.
fn settleReaction(self: *Interpreter, r: *Reaction, fulfilled: bool, arg: Value) EvalError!void {
    if (r.result) |result| {
        if (fulfilled) try resolve(self, result, arg) else try reject(self, result, arg);
        return;
    }
    if (fulfilled) _ = try self.callValue(r.resolve, &.{arg}) else _ = try self.callValue(r.reject, &.{arg});
}

pub fn runJob(self: *Interpreter, task: *Microtask) EvalError!void {
    std.debug.assert(task.kind != .settlement_batch and task.kind != .transferred_batch);
    if (task.kind == .native_callback) {
        promise_profile.recordMicrotaskRun(false);
        if (task.native_callback) |callback| callback(task.native_callback_context);
        return;
    }
    if (task.kind == .job) {
        promise_profile.recordMicrotaskRun(false);
        _ = try self.callValueWithThis(task.job, &.{ task.job_first, task.job_second }, Value.undef());
        return;
    }
    if (task.kind == .next_tick) {
        promise_profile.recordMicrotaskRun(false);
        _ = try self.callValueWithThis(task.job, task.job_args, Value.undef());
        return;
    }
    if (task.kind == .callback) {
        promise_profile.recordMicrotaskRun(false);
        _ = try self.callValueWithThis(task.callback, &.{}, Value.undef());
        return;
    }
    if (task.kind == .thenable) {
        promise_profile.recordMicrotaskRun(true);
        if (task.payload.promise == null or !isPending(task.payload.promise.?)) return;
        const nr = try nativeResolveReject(self, task.payload.promise.?);
        const resolve_mark = try self.pushTempRoot(nr.resolve);
        defer self.restoreTempRoots(resolve_mark);
        const reject_mark = try self.pushTempRoot(nr.reject);
        defer self.restoreTempRoots(reject_mark);
        if (self.callValueWithThis(
            task.then_fn,
            &.{ self.tempRoot(resolve_mark, nr.resolve), self.tempRoot(reject_mark, nr.reject) },
            task.thenable,
        )) |_| {} else |err| {
            if (err == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                _ = try self.callValue(self.tempRoot(reject_mark, nr.reject), &.{reason});
            } else return err;
        }
        return;
    }
    promise_profile.recordMicrotaskRun(false);
    const r = &task.reaction;
    if (r.handler) |h| {
        const result = if (r.extra_argument) |extra|
            self.callValueWithThis(h, &.{ task.argument, extra }, Value.undef())
        else
            self.callValueWithThis(h, &.{task.argument}, Value.undef());
        if (result) |res| {
            if (r.detached) return;
            try settleReaction(self, r, true, res);
        } else |err| {
            if (r.detached) return err;
            if (err == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                try settleReaction(self, r, false, reason);
            } else return err;
        }
    } else {
        // Pass-through: a fulfill reaction with no handler forwards the value;
        // a reject reaction with no handler forwards the rejection.
        try settleReaction(self, r, task.fulfilled, task.argument);
    }
}
