//! Shared-realm thread coordination state (Phase 6/7 of
//! https://github.com/zig-utils/zig-js/issues/1, design in
//! docs/threads/P6-thread-api.md). `Context.createWith(.{ .enable_threads =
//! true })` runs no-GIL/parallel by default; `.gil = true` uses the legacy VM
//! lock path. The same struct also owns per-realm task queues, waiter tables,
//! API bookkeeping locks, and park records used by both modes.

const std = @import("std");
const io_compat = @import("io_compat.zig");
const agent = @import("agent.zig");
const gc_runtime = @import("gc_runtime.zig");
const stack_scan = @import("stack_scan.zig");

pub const Gil = struct {
    const task_queue_reserve_granularity: usize = 64;
    const park_record_reserve_granularity: usize = 16;

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
    /// type-erased `*jsthread.PropTicket` and are page-allocator owned for the
    /// duration of the blocking wait.
    prop_waiters: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// Property-mode `Atomics.waitAsync` tickets for this realm. Entries are
    /// type-erased `*jsthread.PropAsyncTicket` and allocated with `prop_alloc`.
    prop_async: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// Allocator for property-mode waiter metadata (`prop_waiters`,
    /// `prop_async`, ticket key copies, and settlement scratch). Threaded
    /// contexts overwrite this with their Context allocator so
    /// `heap_limit_bytes` covers property Atomics waiter pressure; the
    /// page-allocator default keeps standalone unit tests ergonomic.
    prop_alloc: std.mem.Allocator = std.heap.page_allocator,
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
        try g.ensureTaskCapacityLocked(a, 1);
        g.tasks.appendAssumeCapacity(task);
        g.tasks_queued.store(g.queuedTaskCountLocked(), .release);
    }

    pub fn enqueueTaskBurst(g: *Gil, a: std.mem.Allocator, tasks: []const *anyopaque) !void {
        if (tasks.len == 0) return;
        g.lockApi();
        defer g.unlockApi();
        try g.ensureTaskCapacityLocked(a, tasks.len);
        g.tasks.appendSliceAssumeCapacity(tasks);
        g.tasks_queued.store(g.queuedTaskCountLocked(), .release);
    }

    fn ensureTaskCapacityLocked(g: *Gil, a: std.mem.Allocator, additional: usize) !void {
        const needed = g.tasks.items.len + additional;
        if (needed <= g.tasks.capacity) return;
        const extra = @max(additional, task_queue_reserve_granularity);
        gc_runtime.enterTraceSensitiveLock();
        defer gc_runtime.leaveTraceSensitiveLock();
        try g.tasks.ensureTotalCapacity(a, g.tasks.items.len + extra);
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
        if (g.tasks_head == g.tasks.items.len) {
            g.tasks.clearRetainingCapacity();
            g.tasks_head = 0;
        }
        g.tasks_queued.store(g.queuedTaskCountLocked(), .release);
        return item;
    }

    pub fn dequeueTaskBurst(g: *Gil, out: []*anyopaque) usize {
        if (out.len == 0) return 0;
        g.lockApi();
        defer g.unlockApi();

        if (g.tasks_head >= g.tasks.items.len) {
            g.tasks.clearRetainingCapacity();
            g.tasks_head = 0;
            g.tasks_queued.store(0, .release);
            return 0;
        }

        const available = g.tasks.items.len - g.tasks_head;
        const n = @min(out.len, available);
        @memcpy(out[0..n], g.tasks.items[g.tasks_head..][0..n]);
        @memset(g.tasks.items[g.tasks_head..][0..n], undefined);
        g.tasks_head += n;
        if (g.tasks_head == g.tasks.items.len) {
            g.tasks.clearRetainingCapacity();
            g.tasks_head = 0;
        }
        g.tasks_queued.store(g.queuedTaskCountLocked(), .release);
        return n;
    }

    fn queuedTaskCountLocked(g: *const Gil) usize {
        if (g.tasks_head >= g.tasks.items.len) return 0;
        return g.tasks.items.len - g.tasks_head;
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

    test "Gil task burst enqueue preserves FIFO and queued hint" {
        var g = Gil{};
        defer g.tasks.deinit(std.testing.allocator);

        var one: u8 = 1;
        var two: u8 = 2;
        var three: u8 = 3;
        try g.enqueueTaskBurst(std.testing.allocator, &.{
            @ptrCast(&one),
            @ptrCast(&two),
        });
        try std.testing.expectEqual(@as(usize, 2), g.tasks_queued.load(.acquire));
        try std.testing.expect(g.tasks.capacity >= Gil.task_queue_reserve_granularity);
        try g.enqueueTaskBurst(std.testing.allocator, &.{@ptrCast(&three)});
        try std.testing.expectEqual(@as(usize, 3), g.tasks_queued.load(.acquire));

        var out: [4]*anyopaque = undefined;
        const n = g.dequeueTaskBurst(&out);
        try std.testing.expectEqual(@as(usize, 3), n);
        try std.testing.expectEqual(@intFromPtr(&one), @intFromPtr(out[0]));
        try std.testing.expectEqual(@intFromPtr(&two), @intFromPtr(out[1]));
        try std.testing.expectEqual(@intFromPtr(&three), @intFromPtr(out[2]));
        try std.testing.expectEqual(@as(usize, 0), g.tasks_queued.load(.acquire));
    }

    /// Register this thread's park record. Call under the GIL once per thread
    /// that will run JS in the realm.
    pub fn registerPark(g: *Gil, rec: *stack_scan.ParkScan) void {
        const a = g.park_alloc orelse return;
        for (g.park_records.items) |existing| if (existing == rec) return;
        g.ensureParkRecordCapacityLocked(a, 1) catch return;
        g.park_records.appendAssumeCapacity(rec);
    }

    fn ensureParkRecordCapacityLocked(g: *Gil, a: std.mem.Allocator, additional: usize) !void {
        const spare = g.park_records.capacity - g.park_records.items.len;
        if (spare >= additional) return;
        const extra = @max(additional, park_record_reserve_granularity);
        try g.park_records.ensureTotalCapacity(a, g.park_records.items.len + extra);
    }

    /// Unregister this thread's park record. Call under the GIL before the
    /// thread's final GIL release / before its stack is torn down.
    pub fn unregisterPark(g: *Gil, rec: *stack_scan.ParkScan) void {
        var i: usize = g.park_records.items.len;
        while (i > 0) {
            i -= 1;
            if (g.park_records.items[i] == rec) {
                _ = g.park_records.swapRemove(i);
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

    test "Gil park records reserve capacity chunks and unregister by swap" {
        const a = std.testing.allocator;
        var g = Gil{ .park_alloc = a };
        defer g.park_records.deinit(a);

        var first = stack_scan.ParkScan{};
        g.registerPark(&first);
        try std.testing.expectEqual(@as(usize, 1), g.park_records.items.len);
        try std.testing.expect(g.park_records.capacity >= Gil.park_record_reserve_granularity);

        g.registerPark(&first);
        try std.testing.expectEqual(@as(usize, 1), g.park_records.items.len);

        const first_capacity = g.park_records.capacity;
        var records = try a.alloc(stack_scan.ParkScan, first_capacity + 1);
        defer a.free(records);
        @memset(records, .{});

        var i: usize = 0;
        while (g.park_records.items.len < first_capacity) : (i += 1) {
            g.registerPark(&records[i]);
        }
        try std.testing.expectEqual(first_capacity, g.park_records.items.len);
        try std.testing.expectEqual(first_capacity, g.park_records.capacity);

        g.registerPark(&records[i]);
        try std.testing.expectEqual(first_capacity + 1, g.park_records.items.len);
        try std.testing.expect(g.park_records.capacity > first_capacity);

        const removed = g.park_records.items[1];
        const tail = g.park_records.items[g.park_records.items.len - 1];
        g.unregisterPark(removed);
        try std.testing.expectEqual(first_capacity, g.park_records.items.len);
        try std.testing.expectEqual(@intFromPtr(tail), @intFromPtr(g.park_records.items[1]));

        while (g.park_records.items.len > 0) {
            g.unregisterPark(g.park_records.items[0]);
        }
        try std.testing.expectEqual(@as(usize, 0), g.park_records.items.len);
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

    /// Non-blocking acquire: on success records ownership and returns true; on
    /// contention returns false without touching `holder`. Lets a caller that
    /// must stay GC-cooperative (the terminating-thread teardown pump) retry
    /// while servicing the parallel-collector root handshake between attempts,
    /// instead of blocking opaque in `acquire` where it would publish nothing.
    pub fn tryAcquire(g: *Gil) bool {
        if (!g.mutex.tryLock()) return false;
        g.holder.store(currentId(), .monotonic);
        return true;
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

test "gil: task queue is FIFO without front shifts" {
    var g = Gil{};
    const a = std.testing.allocator;

    var one: u8 = 1;
    var two: u8 = 2;
    var three: u8 = 3;

    try g.enqueueTask(a, @ptrCast(&one));
    try std.testing.expect(g.tasks.capacity >= Gil.task_queue_reserve_granularity);
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

    try g.enqueueTask(a, @ptrCast(&one));
    try g.enqueueTask(a, @ptrCast(&two));
    try g.enqueueTask(a, @ptrCast(&three));

    var burst: [2]*anyopaque = undefined;
    try std.testing.expectEqual(@as(usize, 2), g.dequeueTaskBurst(&burst));
    try std.testing.expectEqual(@intFromPtr(&one), @intFromPtr(burst[0]));
    try std.testing.expectEqual(@intFromPtr(&two), @intFromPtr(burst[1]));
    try std.testing.expectEqual(@as(usize, 1), g.tasks_queued.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), g.dequeueTaskBurst(&burst));
    try std.testing.expectEqual(@intFromPtr(&three), @intFromPtr(burst[0]));
    try std.testing.expectEqual(@as(usize, 0), g.tasks_queued.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), g.tasks_head);
    try std.testing.expectEqual(@as(usize, 0), g.tasks.items.len);
    try std.testing.expectEqual(@as(usize, 0), g.dequeueTaskBurst(&burst));
}

test "gil: task queue growth is trace-sensitive" {
    var g = Gil{};
    var probe = TraceSensitiveAllocProbe{ .inner = std.testing.allocator };
    const a = probe.allocator();
    defer g.tasks.deinit(a);

    var task: u8 = 1;
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    try g.enqueueTask(a, @ptrCast(&task));
    try std.testing.expect(probe.saw_trace_sensitive_alloc);
    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
}
