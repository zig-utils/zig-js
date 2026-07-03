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
const stack_scan = @import("stack_scan.zig");
const value = @import("value.zig");
const strcell = @import("strcell.zig");
const interp = @import("interpreter.zig");
const ContextMod = @import("context.zig");
const gil_mod = @import("gil.zig");
const agent = @import("agent.zig");

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
    /// The live microtask queue for this JS thread. Worker queues are stack
    /// locals in `threadMain`; outstanding async tickets are transferred away
    /// before that stack frame exits.
    microtasks: ?*promise.MicrotaskQueue = null,
};

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
};

var contention_counters: ContentionCounters = .{};
var contention_stats_enabled: std.atomic.Value(bool) = .init(false);

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
    contention_stats_enabled.store(true, .release);
}

pub fn disableContentionStats() void {
    contention_stats_enabled.store(false, .release);
}

pub fn contentionStats() ContentionStats {
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
    };
}

inline fn bumpContention(comptime field: []const u8) void {
    if (!contention_stats_enabled.load(.monotonic)) return;
    _ = @field(contention_counters, field).fetchAdd(1, .monotonic);
}

pub fn currentThreadId() u64 {
    return if (t_current) |rec| rec.id else 0;
}

test "jsthread contention stats reset and snapshot" {
    disableContentionStats();
    bumpContention("lock_contentions");
    try std.testing.expectEqual(@as(u64, 0), contentionStats().events());

    resetContentionStats();
    try std.testing.expectEqual(@as(u64, 0), contentionStats().events());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().parks());

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

    const stats = contentionStats();
    try std.testing.expectEqual(@as(u64, 6), stats.events());
    try std.testing.expectEqual(@as(u64, 4), stats.parks());
    try std.testing.expectEqual(@as(u64, 2), stats.asyncWaits());
    try std.testing.expectEqual(@as(u64, 2), stats.asyncSettled());
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_empty);
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_jobs);
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_async_hold_jobs);
    try std.testing.expectEqual(@as(u64, 1), stats.task_pump_condition_jobs);

    resetContentionStats();
    try std.testing.expectEqual(@as(u64, 0), contentionStats().events());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().parks());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().asyncWaits());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().asyncSettled());
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_empty);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_jobs);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_async_hold_jobs);
    try std.testing.expectEqual(@as(u64, 0), contentionStats().task_pump_condition_jobs);
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
    const main_rec = try a.create(ThreadRecord);
    main_rec.* = .{ .id = 0, .gil = ctx.gil.?, .ctx = ctx, .done = true, .exited = true, .microtasks = &ctx.microtasks };
    main_rec.js_obj = try makeWrapper(ctx, main_rec);
    t_current = main_rec;
    try ctx.js_threads.append(ctx.gpa, main_rec);

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
    ctor.* = .{ .error_ctor = name, .private_data = @ptrCast(&ctx.env), .proto = base_v.asObj() };
    try interp.installNativeProps(a, rs, ctor, name, 1);
    const proto = try gc_mod.allocObj(a);
    proto.* = .{ .proto = base_proto_v.asObj() };
    const ro = value.PropAttr{ .writable = true, .enumerable = false, .configurable = true };
    try proto.setOwn(a, rs, "name", Value.str(name));
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
    const rec = try a.create(ThreadRecord);
    rec.* = .{ .id = g.next_thread_id, .gil = g, .ctx = ctx };
    g.next_thread_id += 1;
    rec.js_obj = makeWrapper(ctx, rec) catch return error.OutOfMemory;
    const call_args = try a.dupe(Value, if (args.len > 1) args[1..] else &.{});
    try ctx.js_threads.append(ctx.gpa, rec);

    rec.thread = std.Thread.spawn(.{ .stack_size = 64 << 20 }, threadMain, .{ rec, fn_v, call_args }) catch {
        rec.done = true;
        rec.exited = true;
        return self.throwError("Error", "Thread: could not spawn OS thread");
    };
    return Value.obj(rec.js_obj.?);
}

fn threadMain(rec: *ThreadRecord, fn_v: Value, args: []const Value) void {
    const g = rec.gil;
    defer markThreadExited(rec);
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
    // A per-thread interpreter over the SHARED realm: same arena, environment,
    // global object, and shapes (safe under the GIL), with its own job queues.
    // join() performs the joiner's completion checkpoint before observing the
    // result, which is the only cross-thread microtask drain point.
    // Heap-allocate the per-thread microtask queue (arena-owned, freed at realm
    // teardown) instead of putting it on this thread's native stack. A peer
    // settling a cross-thread promise appends into this queue under
    // `microtask_lock`, growing its ArrayList header; on the stack that write
    // races the collector's CONSERVATIVE scan of this thread's stack (the blind
    // word scan can't take `microtask_lock`). Off the stack the header is never
    // conservatively scanned, and the queued tasks stay precisely rooted via
    // `machine.microtasks` in `traceInterpreterRoots` (which holds the lock).
    const microtasks = rec.ctx.arena().create(promise.MicrotaskQueue) catch {
        var pj = publishThreadCompletion(rec, true, Value.undef());
        pj.deinit(rec.ctx.arena());
        return;
    };
    microtasks.* = .{};
    var async_waiters: std.ArrayListUnmanaged(interp.AsyncWaiterEntry) = .empty;
    rec.microtasks = microtasks;
    var machine = rec.ctx.interpreter();
    rec.ctx.pushActiveInterpreter(&machine) catch {
        var pending_joins = publishThreadCompletion(rec, true, Value.undef());
        pending_joins.deinit(rec.ctx.arena());
        return;
    };
    defer rec.ctx.popActiveInterpreter(&machine);
    machine.microtasks = microtasks;
    machine.async_waiters = &async_waiters;
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
        result = out;
    } else |_| {
        machine.drainMicrotasks() catch {};
        if (async_waiters.items.len > 0) {
            agent.abandonAsync(@ptrCast(&async_waiters));
            async_waiters.clearRetainingCapacity();
        }
        threw = true;
        result = machine.exception;
    }
    // Settle asyncJoin promises on this (the settling) thread, then drain
    // the reactions it just queued. `publishThreadCompletion` snapshots the
    // pending join list under `join_mutex`; JS/promise work runs after release.
    if (rec.ctx.parallel_js) g.acquire();
    defer if (rec.ctx.parallel_js) g.release();
    var pending_joins = publishThreadCompletion(rec, threw, result);
    defer pending_joins.deinit(rec.ctx.arena());
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
    // Serialized with peer enqueues by `microtask_lock` (no-op when null, i.e.
    // GIL mode).
    {
        machine.lockMicrotasks();
        defer machine.unlockMicrotasks();
        if (!microtasks.isEmpty()) {
            rec.ctx.microtasks.appendPendingSlice(rec.ctx.arena(), microtasks) catch {};
            microtasks.clearRetainingCapacity();
        }
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
    rec.done = true;
    rec.done_cond.broadcast(io);
    return pending;
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
    if (!rec.done and !self.main_can_block) {
        rec.join_mutex.unlock(io);
        return self.throwError("TypeError", "Thread.prototype.join cannot block the current thread");
    }
    var join_mutex_locked = true;
    errdefer if (join_mutex_locked) rec.join_mutex.unlock(io);
    while (!rec.done) try parkPumpThreadJoin(self, rec);
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

const LockRecord = struct {
    brand: SyncBrand = sync_brand_lock,
    gil: *gil_mod.Gil,
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

    fn appendPending(self: *LockRecord, arena: std.mem.Allocator, job: *HoldJob) !void {
        try self.pending.append(arena, job);
    }

    fn pushFrontPending(self: *LockRecord, arena: std.mem.Allocator, job: *HoldJob) !void {
        if (self.pending_front.items.len == 0 and self.pending_head > 0) {
            self.pending_head -= 1;
            self.pending.items[self.pending_head] = job;
            return;
        }
        try self.pending_front.append(arena, job);
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

    fn appendWaiter(self: *CondRecord, arena: std.mem.Allocator, entry: CondEntry) !void {
        try self.queue.append(arena, entry);
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
    }
    fn unlockMap(self: *TLRecord) void {
        self.map_lock.unlock();
    }
};

const UnlockTokenRecord = struct {
    brand: SyncBrand = sync_brand_unlock_token,
    lock: ?*LockRecord = null,
};

inline fn traceThreadValue(v: anytype, val: Value) void {
    if (val.isObject()) v.mark(val.asObj());
}

fn traceHoldJob(job: *HoldJob, v: anytype) void {
    v.mark(job.outer);
    if (job.cb) |cb| traceThreadValue(v, cb);
}

fn barrierHoldJob(job: *HoldJob) void {
    gc_mod.barrierCell(@ptrCast(job.outer));
    if (job.cb) |cb| gc_mod.barrierValue(cb);
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
        .asynchronous => |w| v.mark(w.outer),
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
            traceLockRecordRoots(st.lock, v);
        },
        .jsthread_thread, .jsthread_unlock_token, .none => {},
    }
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
    try proto.setOwn(a, ctx.root_shape, k, Value.str(name));
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
            waitOnLockCond(self, rec, .{ .duration = .{
                .raw = .fromNanoseconds(tick_ns),
                .clock = .awake,
            } });
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
    const ticket = self.arena.create(SyncCondTicket) catch |err| {
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
        waitOnCondRecord(self, rec, .{ .duration = .{
            .raw = .fromNanoseconds(tick_ns),
            .clock = .awake,
        } });
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
    var woken: std.ArrayListUnmanaged(CondEntry) = .empty;
    defer woken.deinit(self.arena);
    rec.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) rec.mutex.unlock(io);
    const available = rec.queue.items.len - rec.queue_head;
    try woken.ensureTotalCapacity(self.arena, @min(count, available));
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
        woken.appendAssumeCapacity(entry);
        n += 1;
    }

    if (sync_count == 0) {
        // Async-only notifications do not need the sync notifyAll handoff.
        // Deliver their lock regrants outside the condition queue mutex so
        // regrant bookkeeping and realm task enqueueing do not lengthen the
        // condition critical section.
        rec.mutex.unlock(io);
        locked = false;
        wakeAsyncCondWaiters(self, woken.items);
        return n;
    }
    rec.sync_handoff_pending = sync_count;

    // Mixed wakeups keep the old ordering shape: async regrants are prepared
    // before the sync handoff wait, while the condition mutex still serializes
    // the notify operation.
    wakeAsyncCondWaiters(self, woken.items);
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
    rec.lockMap();
    defer rec.unlockMap();
    try rec.map.put(rec.arena, currentTid(), v);
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
        v.asObj().proxy_target == null and
        v.asObj().typed_array == null and
        v.asObj().data_view == null;
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
    if (!o.is_array or o.is_arguments or o.accessors.load(.monotonic) != null or o.attrsMap() != null) return null;
    return i;
}

fn attrUnlocked(o: *const value.Object, key: []const u8) value.PropAttr {
    if (o.attrsMap()) |m| {
        if (m.get(key)) |a| return a;
    }
    return .{};
}

fn accessorUnlocked(o: *const value.Object, key: []const u8) bool {
    if (o.accessors.load(.monotonic)) |m| return m.get(key) != null;
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
        if (namedSlotUnlocked(o, key)) |slot| return o.slots.items[slot];
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
        const old = o.slots.items[slot];
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
        const old = o.slots.items[slot];
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
        const old = o.slots.items[slot];
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
// sync tickets are page-allocator owned and unlinked before wait returns,
// while async tickets are page-allocator owned until settlement.
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
const prop_alloc = std.heap.page_allocator;

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

/// `Atomics.waitAsync(obj, key, expected, timeout)` — the property path.
/// Settlement: a notify resolves "ok" on the notifying thread; expiry
/// resolves "timed-out" from the awaiters' poll points.
pub fn propWaitAsync(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].asObj();
    const key_tmp = try self.keyOf(argAt(args, 1));
    const expected = argAt(args, 2);
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.waitAsync: object has no own data property");
    const res = (try self.newObject()).asObj();
    if (!sameValueZero(cur, expected)) {
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("not-equal"));
        return Value.obj(res);
    }
    if (timeout_ns != null and timeout_ns.? == 0) {
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("timed-out"));
        return Value.obj(res);
    }
    const microtasks = self.microtasks orelse
        return self.throwError("Error", "Atomics.waitAsync requires a microtask queue");
    const p_obj = try promise.newPromise(self);
    const key = prop_alloc.dupe(u8, key_tmp) catch return error.OutOfMemory;
    const t = prop_alloc.create(PropAsyncTicket) catch {
        prop_alloc.free(key);
        return error.OutOfMemory;
    };
    var queued = false;
    errdefer if (!queued) {
        prop_alloc.free(key);
        prop_alloc.destroy(t);
    };
    const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    t.* = .{
        .obj = o,
        .key = key,
        .deadline_ns = if (timeout_ns) |ns| now + ns else null,
        .promise = p_obj,
        .microtasks = microtasks,
        .thread = t_current,
        .owner = @ptrCast(self.gil.?),
    };
    const g = self.gil.?;
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
    g.prop_async.append(prop_alloc, @ptrCast(t)) catch {
        g.unlockPropWaiters();
        locked = false;
        return error.OutOfMemory;
    };
    queued = true;
    bumpContention("property_wait_async_enqueued");
    try self.setProp(res, "async", Value.boolVal(true));
    try self.setProp(res, "value", Value.obj(p_obj));
    return Value.obj(res);
}

fn settlePropAsync(self: *Interpreter, t: *PropAsyncTicket, outcome: []const u8) void {
    bumpContention("property_wait_async_settled");
    if (promise.promiseOf(Value.obj(t.promise))) |pp| {
        const saved_microtasks = self.microtasks;
        if (t.thread) |rec| {
            const io = agent.engineIo();
            rec.join_mutex.lockUncancelable(io);
            const target = if (rec.microtasks == t.microtasks) t.microtasks else &rec.ctx.microtasks;
            self.microtasks = target;
            promise.resolve(self, pp, Value.str(outcome)) catch {};
            self.microtasks = saved_microtasks;
            rec.join_mutex.unlock(io);
        } else {
            self.microtasks = t.microtasks;
            promise.resolve(self, pp, Value.str(outcome)) catch {};
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
            settle.append(prop_alloc, t) catch {
                if (write != read) g.prop_async.items[write] = raw;
                write += 1;
                continue;
            };
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
    const g = self.gil.?;
    g.lockPropWaiters();
    var linked = false;
    defer {
        if (linked) removePropTicketLocked(g, ticket);
        g.unlockPropWaiters();
    }
    const cur_locked = try ownDataOrThrow(self, o, key_tmp, "Atomics.wait: object has no own data property");
    if (!sameValueZero(cur_locked, expected)) return Value.str("not-equal");
    g.prop_waiters.append(prop_alloc, @ptrCast(ticket)) catch return error.OutOfMemory;
    ticket.queued = true;
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
        waitPropTicketTimeout(self, g, ticket, .{ .duration = .{
            .raw = .fromNanoseconds(tick_ns),
            .clock = .awake,
        } }) catch {};
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
    var settle: std.ArrayListUnmanaged(*PropAsyncTicket) = .empty;
    defer settle.deinit(prop_alloc);
    g.lockPropWaiters();
    var locked = true;
    defer if (locked) g.unlockPropWaiters();
    n += notifyPropWaitersLocked(g, o, key, count, io);
    if (n < count) {
        const limit = count - n;
        const async_matches = countPropAsyncMatchesLocked(g, o, key, limit);
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
        rec.pending_joins.append(self.arena, .{ .promise = p_obj, .microtasks = microtasks, .owner = t_current }) catch |err| {
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
    const plain = o.js_func == null and o.native == null and o.callback == null and o.bound == null and
        o.gen == null and o.proxy_target == null and !o.proxy_revoked and
        o != (self.global_object orelse o) and
        o.typed_array == null and o.data_view == null and o.array_buffer == null and
        !o.is_date and !o.is_regex and !o.is_map and !o.is_set and !o.is_weak and
        o.promise == null and !o.is_symbol and !o.is_bigint and o.module_ns == null and
        o.weak_ref_target == null and !o.is_arguments and !o.is_error and
        o.prim == null and o.error_ctor == null and o.getOwn("constructor") == null;
    if (!plain) return self.throwError("TypeError", "cannot restrict this object");
    const tid: u64 = @intCast(std.Thread.getCurrentId());
    // Claim via CAS 0→tid so two concurrent restricts can't both win.
    if (o.restricted_to.cmpxchgStrong(0, tid, .acq_rel, .acquire)) |owner| {
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
    if (rec.done) return;

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
    io_compat.conditionWaitTimeout(&rec.done_cond, io, &rec.join_mutex, .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } }) catch {};
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
