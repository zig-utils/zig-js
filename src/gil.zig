//! The VM lock for shared-Context threads (Phase 6 of
//! https://github.com/zig-utils/zig-js/issues/1, design in
//! docs/threads/P6-thread-api.md). One mutex serializes all heap and
//! interpreter access in an `enable_threads` Context: exactly one thread
//! runs JS at a time (concurrency, not parallelism), which is what makes
//! arena allocation, shape transitions, and every existing invariant safe
//! with zero changes. Threads interleave at the engines' step checkpoints
//! (`yieldIfContended`) and at every blocking point (join, Condition.wait,
//! Atomics.wait, Lock contention), which release the lock while parked.

const std = @import("std");
const io_compat = @import("io_compat.zig");
const agent = @import("agent.zig");
const stack_scan = @import("stack_scan.zig");

pub const Gil = struct {
    mutex: std.Io.Mutex = .init,
    /// The holding thread (0 = unheld) — written only by the holder right
    /// after acquire / before release; read by debug asserts and only
    /// meaningful when the reader holds the lock.
    holder: std.atomic.Value(u64) = .init(0),
    /// Threads currently blocked in `acquire` — the step checkpoints' cheap
    /// "should I yield" signal.
    contenders: std.atomic.Value(u32) = .init(0),
    /// The realm's run-loop TASK queue (engine tasks: lock-grant deliveries),
    /// distinct from per-thread microtask queues. Parks pump it (a parked
    /// thread's run loop still serves tasks; each pumped task drains
    /// microtasks as its own turn) — the semantics the threads corpus pins.
    /// Entries are type-erased `*jsthread.HoldJob` (owned by their arena).
    /// `tasks_head` is the first pending entry; dequeue advances it and clears
    /// the list when the queue drains, avoiding O(n) front-removal shifts.
    tasks: std.ArrayListUnmanaged(*anyopaque) = .empty,
    tasks_head: usize = 0,
    /// Cheap empty-queue signal for park/pump hot paths. The authoritative
    /// queue remains `tasks` under `api_lock`; this lets sync waiters skip the
    /// lock entirely when no task has been enqueued.
    tasks_queued: std.atomic.Value(usize) = .init(0),
    /// Property-mode `Atomics.wait` waiters for this realm. Entries are
    /// type-erased `*jsthread.PropTicket` and live on waiting thread stacks.
    prop_waiters: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// Property-mode `Atomics.waitAsync` tickets for this realm. Entries are
    /// type-erased `*jsthread.PropAsyncTicket` and are page-allocator owned.
    prop_async: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// Serializes the property-mode `Atomics.wait` / `notify` / `waitAsync`
    /// waiter tables independently from the context GIL. Sync waits use this as
    /// the condition-variable mutex, so notify cannot race enqueue/unlink once
    /// `parallel_js` drops the execution-path GIL.
    prop_mutex: std.Io.Mutex = .init,
    /// Per-realm Thread-id allocator: ids in [1, 0x7ffe], monotonically
    /// fresh (no reuse before a rebias lands), main = 0.
    next_thread_id: u32 = 1,
    /// Conservative-scan park records for every thread that runs JS in this
    /// realm (the main thread plus each spawned `Thread`). A thread registers
    /// its threadlocal record on entry and unregisters on exit, both under the
    /// GIL. During a mid-script collection the GIL-holding collector walks this
    /// list to root every *parked* thread's native stack + registers — the
    /// multi-thread safepoint protocol (issue #1 Phase 7). Mutated and read only
    /// under the GIL, so no extra lock is needed.
    park_records: std.ArrayListUnmanaged(*stack_scan.ParkScan) = .empty,
    /// Backing allocator for `park_records` (the Context's gpa).
    park_alloc: ?std.mem.Allocator = null,
    /// Serializes the cross-realm GlobalSymbolRegistry get-or-create
    /// (`Symbol.for` / lazy registry creation). The registry is a check-then-act
    /// over shared object storage: without this, two threads calling
    /// `Symbol.for(k)` could both miss the lookup and register distinct symbols
    /// (or both create a fresh registry), breaking the `Symbol.for(k) ===
    /// Symbol.for(k)` invariant. Held only across the (rare) registry mutation.
    symbol_registry_lock: std.atomic.Mutex = .unlocked,

    /// Serializes the threading-API shared bookkeeping that today is protected
    /// only by the GIL: the `Thread` id allocator (`next_thread_id`), the live
    /// `Context.js_threads` cap-check + append transaction, and the run-loop /
    /// waiter queues below. Once the GIL is dropped during bytecode these
    /// operations still need a single mutual-exclusion point — e.g. two
    /// concurrent `Thread` constructions must not both pass the live cap or
    /// claim the same id. Held only across the (rare) bookkeeping mutation.
    api_lock: std.atomic.Mutex = .unlocked,

    /// Serializes shared-realm lazy materialization that is a check-then-act over
    /// shared object storage — chiefly a function's lazily-installed `.prototype`
    /// (`Interpreter.protoObject`). Without it two threads `new`-ing the same
    /// not-yet-materialized constructor (or reading its `.prototype`) could both
    /// miss the slot and install *distinct* prototype objects, breaking
    /// `F.prototype === F.prototype` and instance-prototype identity. Used with
    /// double-checked locking, so it is taken only on the (one-time) install.
    lazy_init_lock: std.atomic.Mutex = .unlocked,

    /// Lock/unlock the GlobalSymbolRegistry critical section (spin lock, like the
    /// per-structure locks). Non-recursive: a single critical section must take
    /// it exactly once.
    pub fn lockSymbolRegistry(g: *Gil) void {
        spinLock(&g.symbol_registry_lock);
    }
    pub fn unlockSymbolRegistry(g: *Gil) void {
        g.symbol_registry_lock.unlock();
    }

    /// Lock/unlock the shared-realm lazy-materialization critical section
    /// (double-checked locking; non-recursive).
    pub fn lockLazyInit(g: *Gil) void {
        spinLock(&g.lazy_init_lock);
    }
    pub fn unlockLazyInit(g: *Gil) void {
        g.lazy_init_lock.unlock();
    }

    /// Lock/unlock the threading-API bookkeeping critical section. Non-recursive.
    pub fn lockApi(g: *Gil) void {
        spinLock(&g.api_lock);
    }
    pub fn unlockApi(g: *Gil) void {
        g.api_lock.unlock();
    }

    pub fn enqueueTask(g: *Gil, a: std.mem.Allocator, task: *anyopaque) !void {
        g.lockApi();
        defer g.unlockApi();
        try g.tasks.append(a, task);
        _ = g.tasks_queued.fetchAdd(1, .release);
    }

    pub fn dequeueTask(g: *Gil) ?*anyopaque {
        g.lockApi();
        defer g.unlockApi();

        if (g.tasks_head >= g.tasks.items.len) {
            g.tasks.clearRetainingCapacity();
            g.tasks_head = 0;
            g.tasks_queued.store(0, .release);
            return null;
        }

        const item = g.tasks.items[g.tasks_head];
        g.tasks.items[g.tasks_head] = undefined;
        g.tasks_head += 1;
        _ = g.tasks_queued.fetchSub(1, .release);
        if (g.tasks_head == g.tasks.items.len) {
            g.tasks.clearRetainingCapacity();
            g.tasks_head = 0;
        }
        return item;
    }

    /// Lock/unlock the property-mode Atomics waiter table. No JS or promise
    /// settlement runs while this mutex is held.
    pub fn lockPropWaiters(g: *Gil) void {
        g.prop_mutex.lockUncancelable(agent.engineIo());
    }
    pub fn unlockPropWaiters(g: *Gil) void {
        g.prop_mutex.unlock(agent.engineIo());
    }

    fn spinLock(m: *std.atomic.Mutex) void {
        var spins: usize = 0;
        while (!m.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }

    fn currentId() u64 {
        return @intCast(std.Thread.getCurrentId());
    }

    /// Register this thread's park record. Call under the GIL once per thread
    /// that will run JS in the realm.
    pub fn registerPark(g: *Gil, rec: *stack_scan.ParkScan) void {
        const a = g.park_alloc orelse return;
        for (g.park_records.items) |existing| if (existing == rec) return;
        g.park_records.append(a, rec) catch {};
    }

    /// Unregister this thread's park record. Call under the GIL before the
    /// thread's final GIL release / before its stack is torn down.
    pub fn unregisterPark(g: *Gil, rec: *stack_scan.ParkScan) void {
        var i: usize = g.park_records.items.len;
        while (i > 0) {
            i -= 1;
            if (g.park_records.items[i] == rec) {
                _ = g.park_records.orderedRemove(i);
                return;
            }
        }
    }

    /// Whether every registered thread other than the caller is currently
    /// parked-and-published. When true, the GIL holder can safely run a
    /// mid-script collection that scans those parked stacks; when false, some
    /// thread released the GIL without publishing a scan range (or is mid
    /// startup), so the collector must not collect (it would miss live roots).
    pub fn allOthersParked(g: *const Gil) bool {
        const me = stack_scan.parkRecord();
        for (g.park_records.items) |rec| {
            if (rec == me) continue;
            if (!stack_scan.isParked(rec)) return false;
        }
        return true;
    }

    pub fn acquire(g: *Gil) void {
        const io = agent.engineIo();
        if (!g.mutex.tryLock()) {
            _ = g.contenders.fetchAdd(1, .monotonic);
            g.mutex.lockUncancelable(io);
            _ = g.contenders.fetchSub(1, .monotonic);
        }
        g.holder.store(currentId(), .monotonic);
    }

    pub fn release(g: *Gil) void {
        g.holder.store(0, .monotonic);
        g.mutex.unlock(agent.engineIo());
    }

    pub fn holds(g: *const Gil) bool {
        return g.holder.load(.monotonic) == currentId();
    }

    /// Step-checkpoint yield: hand the lock over only when someone is
    /// actually waiting (uncontended cost: one relaxed load).
    pub fn yieldIfContended(g: *Gil) void {
        if (g.contenders.load(.monotonic) == 0) return;
        // Publish a scan range before handing off: while we spin/reacquire, a
        // thread that takes the lock may collect and must see this stack.
        stack_scan.beginPark();
        defer stack_scan.endPark();
        g.release();
        while (g.contenders.load(.acquire) != 0) {
            std.Thread.yield() catch {};
        }
        g.acquire();
    }

    /// Park on `cond` with the GIL as the condition's mutex: atomically
    /// releases the lock while waiting and reacquires before returning —
    /// the primitive under `join`, `Condition.wait`, and friends.
    pub fn wait(g: *Gil, cond: *std.Io.Condition) void {
        const io = agent.engineIo();
        // Publish before the GIL drops inside the condition wait; clear after
        // it is reacquired (so a collector on another thread can root us).
        stack_scan.beginPark();
        defer stack_scan.endPark();
        g.holder.store(0, .monotonic);
        cond.waitUncancelable(io, &g.mutex);
        g.holder.store(currentId(), .monotonic);
    }

    /// `wait` with a deadline (property-Atomics timed waits). Reacquires the
    /// lock before returning either way.
    pub fn waitTimeout(g: *Gil, cond: *std.Io.Condition, timeout: std.Io.Timeout) error{Timeout}!void {
        const io = agent.engineIo();
        stack_scan.beginPark();
        defer stack_scan.endPark();
        g.holder.store(0, .monotonic);
        defer g.holder.store(currentId(), .monotonic);
        io_compat.conditionWaitTimeout(cond, io, &g.mutex, timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => {},
        };
    }
};

test "gil: mutual exclusion and contended yield handover" {
    var g = Gil{};
    const Worker = struct {
        fn run(gil: *Gil, counter: *u64) void {
            gil.acquire();
            defer gil.release();
            counter.* += 1; // data access is GIL-protected
        }
    };
    var counter: u64 = 0;

    // Plain mutual exclusion: four threads through the lock.
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &g, &counter });
    for (threads) |t| t.join();
    g.acquire();
    try std.testing.expect(g.holds());
    try std.testing.expectEqual(@as(u64, 4), counter);

    // Contended yield: while we hold, a fifth thread queues; one
    // yieldIfContended must hand the lock over and reacquire after it.
    const t5 = try std.Thread.spawn(.{}, Worker.run, .{ &g, &counter });
    while (g.contenders.load(.monotonic) == 0) std.atomic.spinLoopHint();
    g.yieldIfContended();
    try std.testing.expect(g.holds());
    try std.testing.expectEqual(@as(u64, 5), counter);
    g.release();
    try std.testing.expect(!g.holds());
    t5.join();
}

test "gil: task queue is FIFO without front shifts" {
    var g = Gil{};
    const a = std.testing.allocator;

    var one: u8 = 1;
    var two: u8 = 2;
    var three: u8 = 3;

    try g.enqueueTask(a, @ptrCast(&one));
    try g.enqueueTask(a, @ptrCast(&two));
    try g.enqueueTask(a, @ptrCast(&three));
    defer g.tasks.deinit(a);

    try std.testing.expectEqual(@as(usize, 3), g.tasks_queued.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), g.tasks_head);
    try std.testing.expectEqual(@as(usize, 3), g.tasks.items.len);

    try std.testing.expectEqual(@intFromPtr(&one), @intFromPtr(g.dequeueTask().?));
    try std.testing.expectEqual(@as(usize, 2), g.tasks_queued.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), g.tasks_head);
    try std.testing.expectEqual(@as(usize, 3), g.tasks.items.len);

    try std.testing.expectEqual(@intFromPtr(&two), @intFromPtr(g.dequeueTask().?));
    try std.testing.expectEqual(@intFromPtr(&three), @intFromPtr(g.dequeueTask().?));
    try std.testing.expectEqual(@as(usize, 0), g.tasks_queued.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), g.tasks_head);
    try std.testing.expectEqual(@as(usize, 0), g.tasks.items.len);
    try std.testing.expectEqual(@as(?*anyopaque, null), g.dequeueTask());
}
