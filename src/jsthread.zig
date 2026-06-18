//! The JS-visible `Thread` API (Phase 6 step 2 of
//! https://github.com/zig-utils/zig-js/issues/1; semantics copied from
//! oven-sh/WebKit#249, design in docs/threads/P6-thread-api.md).
//!
//! `new Thread(fn, ...args)` runs `fn` on another OS thread **in the same
//! realm** — same globalThis, same heap, same closures — serialized by the
//! Context's GIL (src/gil.zig). `t.join()` releases the GIL while parked and
//! returns fn's value or rethrows its actual exception object; each thread
//! drains its own microtask queue before publishing its result.
//! `Thread.current` is the calling thread's Thread object (main has id 0).
//! Installed only on `enable_threads` Contexts.

const std = @import("std");
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

pub const ThreadRecord = struct {
    id: u32,
    gil: *gil_mod.Gil,
    ctx: *Context,
    thread: ?std.Thread = null,
    /// GIL-protected; `done_cond` is waited through `Gil.wait`, so joiners
    /// release the lock while parked.
    done: bool = false,
    threw: bool = false,
    result: Value = Value.undef(),
    done_cond: std.Io.Condition = .init,
    /// The realm's wrapper object (`Thread.current` returns it).
    js_obj: ?*value.Object = null,
    /// Promises handed out by `asyncJoin` before completion; settled by the
    /// finishing thread (reactions run on the settling thread's queue — the
    /// PR's ordinary-promise rule; awaiters elsewhere observe the shared
    /// state via awaitValue's GIL-yield loop).
    pending_joins: std.ArrayListUnmanaged(*value.Object) = .empty,
};

threadlocal var t_current: ?*ThreadRecord = null;

pub fn currentThreadId() u64 {
    return if (t_current) |rec| rec.id else 0;
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
    main_rec.* = .{ .id = 0, .gil = ctx.gil.?, .ctx = ctx, .done = true };
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
    o.* = .{ .private_data = rec };
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
    const pd = this.asObj().private_data orelse return null;
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

    rec.thread = std.Thread.spawn(.{}, threadMain, .{ rec, fn_v, call_args }) catch {
        rec.done = true;
        return self.throwError("Error", "Thread: could not spawn OS thread");
    };
    return Value.obj(rec.js_obj.?);
}

fn threadMain(rec: *ThreadRecord, fn_v: Value, args: []const Value) void {
    const g = rec.gil;
    g.acquire();
    defer g.release();
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
    g.registerPark(stack_scan.parkRecord());
    defer g.unregisterPark(stack_scan.parkRecord());
    t_current = rec;
    // A per-thread interpreter over the SHARED realm: same arena, environment,
    // global object, and shapes (safe under the GIL), with its own job queues.
    // join() performs the joiner's completion checkpoint before observing the
    // result, which is the only cross-thread microtask drain point.
    var microtasks: std.ArrayListUnmanaged(@import("promise.zig").Microtask) = .empty;
    var async_waiters: std.ArrayListUnmanaged(interp.AsyncWaiterEntry) = .empty;
    var machine = rec.ctx.interpreter();
    rec.ctx.pushActiveInterpreter(&machine) catch {
        rec.threw = true;
        rec.result = Value.undef();
        rec.done = true;
        rec.done_cond.broadcast(agent.engineIo());
        return;
    };
    defer rec.ctx.popActiveInterpreter(&machine);
    machine.microtasks = &microtasks;
    machine.async_waiters = &async_waiters;
    if (machine.callValueWithThis(fn_v, args, Value.undef())) |out| {
        machine.drainMicrotasks() catch {};
        pumpTasks(&machine);
        machine.settleAsyncWaiters();
        rec.result = out;
    } else |_| {
        machine.drainMicrotasks() catch {};
        rec.threw = true;
        rec.result = machine.exception;
    }
    // Settle asyncJoin promises on this (the settling) thread, then drain
    // the reactions it just queued.
    for (rec.pending_joins.items) |p_obj| {
        if (promise.promiseOf(Value.obj(p_obj))) |pp| {
            if (rec.threw)
                promise.reject(&machine, pp, rec.result) catch {}
            else
                promise.resolve(&machine, pp, rec.result) catch {};
        }
    }
    rec.pending_joins.clearRetainingCapacity();
    machine.drainMicrotasks() catch {};
    rec.done = true;
    rec.done_cond.broadcast(agent.engineIo());
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
    if (!rec.done and !self.main_can_block)
        return self.throwError("TypeError", "Thread.prototype.join cannot block the current thread");
    while (!rec.done) try parkPump(self, rec.gil, &rec.done_cond);
    self.drainMicrotasks() catch {};
    if (rec.threw) {
        self.exception = rec.result;
        return error.Throw;
    }
    return rec.result;
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
// per-thread storage for any JS value. All parking goes through `Gil.wait`,
// so the VM lock is never held while blocked.

const SyncBrand = usize;
const sync_brand_lock: SyncBrand = 0x6a73_7468_6c6f_636b;
const sync_brand_condition: SyncBrand = 0x6a73_7468_636f_6e64;
const sync_brand_thread_local: SyncBrand = 0x6a73_7468_746c_736c;
const sync_brand_unlock_token: SyncBrand = 0x6a73_7468_7574_6f6b;

const LockRecord = struct {
    brand: SyncBrand = sync_brand_lock,
    gil: *gil_mod.Gil,
    locked: bool = false,
    /// Holding thread (0 = unheld) — recursion detection: a nested hold on
    /// the same thread must throw, not self-deadlock.
    holder: u64 = 0,
    cond: std.Io.Condition = .init,
    /// Queued asyncHold jobs, granted FIFO at release time.
    pending: std.ArrayListUnmanaged(*HoldJob) = .empty,
    /// An async grant exists but its job hasn't run yet (D6: a
    /// granted-but-UNDELIVERED hold is NOT "held" — consuming it would
    /// unlock the lock under the not-yet-run fn).
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
};

/// A parked sync waiter's ticket (on the waiting thread's stack; unlinked
/// before wait returns).
const SyncCondTicket = struct {
    woken: bool = false,
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
    cond: std.Io.Condition = .init,
    /// ONE FIFO domain for sync and async waiters (4.3: notify wakes them
    /// uniformly in arrival order — cross-kind).
    queue: std.ArrayListUnmanaged(CondEntry) = .empty,
};

const TLRecord = struct {
    brand: SyncBrand = sync_brand_thread_local,
    gil: *gil_mod.Gil,
    arena: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
};

const UnlockTokenRecord = struct {
    brand: SyncBrand = sync_brand_unlock_token,
    lock: ?*LockRecord = null,
};

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
            o.* = .{ .private_data = rec };
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

fn recOf(comptime T: type, this: Value) ?*T {
    if (!this.isObject()) return null;
    const pd = this.asObj().private_data orelse return null;
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

fn acquireLock(self: *Interpreter, rec: *LockRecord, timeout_ns: ?u64, err_name: []const u8) value.HostError!AcquireResult {
    if (rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid())) {
        if (timeout_ns != null and timeout_ns.? == 0) return .timed_out;
        return self.throwError("TypeError", err_name);
    }
    if (rec.locked or rec.sync_waiting > 0) {
        if (timeout_ns != null and timeout_ns.? == 0) return .timed_out;
        if (!self.main_can_block)
            return self.throwError("TypeError", err_name);
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
            try parkPump(self, rec.gil, &rec.cond);
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
        obj.* = .{ .private_data = rec };
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
    obj.* = .{ .private_data = rec };
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
    if (!lock.locked or lock.holder != currentTid())
        return self.throwError("TypeError", "Atomics.Mutex.UnlockToken does not own the mutex");
    rec.lock = null;
    lockRelease(self, lock);
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
        if (rec.locked and rec.holder == currentTid()) lockRelease(self, rec);
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
            if (rec.locked and rec.holder == currentTid()) lockRelease(self, rec);
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
    if (rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid()))
        return self.throwError("Error", "Lock is not recursive");
    _ = try acquireLock(self, rec, null, "Lock.prototype.hold cannot block the current thread");
    const out = self.callValueWithThis(cb, &.{}, Value.undef());
    // Epilogue guard: a termination thrown from a cond.wait inside cb left
    // the lock unheld (D9) — releasing here would corrupt the lock state.
    if (rec.locked and rec.holder == currentTid()) lockRelease(self, rec);
    return out;
}

fn lockLockedGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.locked called on incompatible receiver");
    return Value.boolVal(rec.locked);
}

fn removeSyncCondTicket(rec: *CondRecord, ticket: *SyncCondTicket) void {
    for (rec.queue.items, 0..) |entry, i| {
        switch (entry) {
            .sync => |t| if (t == ticket) {
                _ = rec.queue.orderedRemove(i);
                return;
            },
            else => {},
        }
    }
}

fn condWaitCore(self: *Interpreter, rec: *CondRecord, lock: *LockRecord, timeout_ns: ?u64) value.HostError!bool {
    if (!lock.locked or lock.holder != currentTid())
        return self.throwError("TypeError", "Condition wait requires the lock to be held by the caller");
    if ((timeout_ns == null or timeout_ns.? != 0) and !self.main_can_block)
        return self.throwError("TypeError", "Condition wait cannot block the current thread");
    // Atomic under the GIL: nothing else runs between the release below and
    // our enqueue+park (parks register before the VM lock drops).
    lockRelease(self, lock);
    // Arena-allocated, NOT stack: the notifier's consume-loop reads the
    // ticket after this frame may have returned (a stack ticket dangles —
    // it read clobbered memory and spun forever).
    const ticket = try self.arena.create(SyncCondTicket);
    ticket.* = .{};
    try rec.queue.append(self.arena, .{ .sync = ticket });
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
                removeSyncCondTicket(rec, ticket);
                switch (try acquireLock(self, lock, null, "Condition wait cannot reacquire the lock")) {
                    .acquired => return false,
                    .timed_out => unreachable,
                }
            }
        }
        try parkPump(self, rec.gil, &rec.cond);
    }
    // Re-register on the lock BEFORE acking the wake, so notifyAll's
    // consume-loop guarantees FIFO against async regrants.
    ticket.consumed = true;
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
    if (!lock.locked or lock.holder != currentTid())
        return self.throwError("TypeError", "Condition.prototype.wait requires the lock to be held by the caller");
    if (!self.main_can_block)
        return self.throwError("TypeError", "Condition.prototype.wait cannot block the current thread");
    _ = try condWaitCore(self, rec, lock, null);
    return Value.undef();
}

fn condNotify(self: *Interpreter, rec: *CondRecord, count: usize) value.HostError!usize {
    // ONE FIFO domain: wake in arrival order regardless of kind.
    var n: usize = 0;
    var woken_sync: std.ArrayListUnmanaged(*SyncCondTicket) = .empty;
    defer woken_sync.deinit(self.arena);
    while (rec.queue.items.len > 0 and n < count) {
        const entry = rec.queue.orderedRemove(0);
        switch (entry) {
            .sync => |t| {
                t.woken = true;
                woken_sync.append(self.arena, t) catch {};
            },
            .asynchronous => |w| wakeAsyncCondWaiter(self, w),
        }
        n += 1;
    }
    if (woken_sync.items.len > 0) rec.cond.broadcast(agent.engineIo());
    // Depth-free handoff (notify-all-shared-lock) + FIFO against
    // async regrants (condition-async-wait): loop until every woken
    // sync waiter has re-registered on its lock.
    if (self.gil) |g| {
        var pending = true;
        while (pending) {
            pending = false;
            for (woken_sync.items) |t| {
                if (!t.consumed) pending = true;
            }
            if (!pending) break;
            g.release();
            // A real sleep, not a bare yield: the woken waiter must
            // win the GIL to ack, and a tight relock loop can starve
            // it indefinitely (no mutex fairness).
            std.Io.sleep(agent.engineIo(), .fromMilliseconds(1), .awake) catch {};
            g.acquire();
        }
    }
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
    const rec = recOf(CondRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Atomics.Condition.wait requires a Condition argument");
    const lock = try lockFromToken(self, if (args.len > 1) args[1] else Value.undef(), "Atomics.Condition.wait requires a locked UnlockToken");
    _ = try condWaitCore(self, rec, lock, null);
    return Value.undef();
}

fn conditionStaticWaitForFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, if (args.len > 0) args[0] else Value.undef()) orelse
        return self.throwError("TypeError", "Atomics.Condition.waitFor requires a Condition argument");
    const lock = try lockFromToken(self, if (args.len > 1) args[1] else Value.undef(), "Atomics.Condition.waitFor requires a locked UnlockToken");
    const timeout_v = if (args.len > 2) args[2] else Value.undef();
    if (timeout_v.isUndefined())
        return self.throwError("TypeError", "Atomics.Condition.waitFor requires a timeout");
    const timeout_ns = try timeoutMillisToNs(try self.toNumberV(timeout_v));
    const pred = if (args.len > 3) args[3] else Value.undef();
    if (!pred.isUndefined() and !pred.isCallable())
        return self.throwError("TypeError", "Atomics.Condition.waitFor predicate must be callable");

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
    return rec.map.get(currentTid()) orelse Value.undef();
}

fn tlValueSetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.prototype.value called on incompatible receiver");
    const v = if (args.len > 0) args[0] else Value.undef();
    try rec.map.put(rec.arena, currentTid(), v);
    return Value.undef();
}

// ---- Atomics on plain object properties (Phase 6 step 4) -------------------
// PR-249 SPEC-api 4.5, spec'd line-by-line by
// reference/webkit-249/threads-tests/atomics/property-*.js: each op is one
// SeqCst step on an OWN DATA property (trivially so under the GIL). Values
// are NOT coerced (any JS value round-trips by identity); load and the RMW
// family require an existing own data property (absent/accessor/inherited
// throw); store writes through preserving attributes and may create a fresh
// default-attribute property on an extensible object; compareExchange is
// SameValueZero; wait/notify key on (object, property). Property mode only
// exists in enable_threads Contexts, so the test262-visible TypedArray path
// is untouched.

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
    if (o.accessors) |m| return m.get(key) != null;
    return false;
}

fn ownDataOrThrow(self: *Interpreter, o: *value.Object, key: []const u8, what: []const u8) value.HostError!Value {
    if (isAccessor(o, key)) return self.throwError("TypeError", what);
    if (o.getOwn(key)) |v| return v;
    // Array dense elements (and other index-shaped own data) live outside the
    // shape slots; the generic own check + [[Get]] covers them (one step
    // under the GIL either way).
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
    return ownDataOrThrow(self, o, key, "Atomics.load: object has no own property");
}

pub fn propStore(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
    const v = argAt(args, 2);
    if (isAccessor(o, key)) return self.throwError("TypeError", "Atomics.store: property is an accessor");
    if (interp.objectHasOwn(o, key)) {
        try writableOrThrow(self, o, key, "Atomics.store: property is not writable");
    } else if (!o.extensible) {
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
    const old = try ownDataOrThrow(self, o, key, "Atomics.exchange: object has no own data property");
    try writableOrThrow(self, o, key, "Atomics.exchange: property is not writable");
    try self.setMember(Value.obj(o), key, argAt(args, 2));
    return old;
}

pub fn propCompareExchange(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].asObj();
    const key = try self.keyOf(argAt(args, 1));
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
// The context GIL serializes the list; tickets live on waiting thread stacks
// and are unlinked before wait returns.
const PropTicket = struct {
    obj: *value.Object,
    key: []const u8,
    cond: std.Io.Condition = .init,
    woken: bool = false,
};
const prop_alloc = std.heap.page_allocator;

pub const PropAsyncTicket = struct {
    obj: *value.Object,
    key: []const u8,
    deadline_ns: ?i96,
    promise: *value.Object,
    /// The realm's gil pointer — the abandon token at Context.destroy.
    owner: *const anyopaque,
};

/// `Atomics.waitAsync(obj, key, expected, timeout)` — the property path.
/// Settlement: a notify resolves "ok" on the notifying thread; expiry
/// resolves "timed-out" from the awaiters' poll points.
pub fn propWaitAsync(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].asObj();
    const key_tmp = try self.keyOf(argAt(args, 1));
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.waitAsync: object has no own data property");
    const res = (try self.newObject()).asObj();
    if (!sameValueZero(cur, argAt(args, 2))) {
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("not-equal"));
        return Value.obj(res);
    }
    if (timeout_ns != null and timeout_ns.? == 0) {
        try self.setProp(res, "async", Value.boolVal(false));
        try self.setProp(res, "value", Value.str("timed-out"));
        return Value.obj(res);
    }
    const p_obj = try promise.newPromise(self);
    const t = prop_alloc.create(PropAsyncTicket) catch return error.OutOfMemory;
    const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    t.* = .{
        .obj = o,
        .key = try self.arena.dupe(u8, key_tmp),
        .deadline_ns = if (timeout_ns) |ns| now + ns else null,
        .promise = p_obj,
        .owner = @ptrCast(self.gil.?),
    };
    const g = self.gil.?;
    g.prop_async.append(self.arena, @ptrCast(t)) catch {
        prop_alloc.destroy(t);
        return error.OutOfMemory;
    };
    try self.setProp(res, "async", Value.boolVal(true));
    try self.setProp(res, "value", Value.obj(p_obj));
    return Value.obj(res);
}

fn settlePropAsync(self: *Interpreter, t: *PropAsyncTicket, outcome: []const u8) void {
    if (promise.promiseOf(Value.obj(t.promise))) |pp| {
        promise.resolve(self, pp, Value.str(outcome)) catch {};
    }
    prop_alloc.destroy(t);
}

/// Resolve expired property waitAsync tickets — called from the awaiters'
/// poll points (awaitValue's GIL-handover loop, the drain tail).
pub fn pollPropAsync(self: *Interpreter) void {
    const g = self.gil orelse return;
    if (g.prop_async.items.len == 0) return;
    const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    var i: usize = 0;
    while (i < g.prop_async.items.len) {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(g.prop_async.items[i]));
        if (t.deadline_ns != null and t.deadline_ns.? <= now) {
            _ = g.prop_async.orderedRemove(i);
            settlePropAsync(self, t, "timed-out");
            continue;
        }
        i += 1;
    }
}

/// Earliest finite property `Atomics.waitAsync` deadline in this realm, or
/// null when there are no finite timers to keep the shell alive for.
pub fn nextPropAsyncDeadline(self: *Interpreter) ?i96 {
    const g = self.gil orelse return null;
    var nearest: ?i96 = null;
    for (g.prop_async.items) |raw| {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(raw));
        if (t.deadline_ns) |d| nearest = if (nearest) |m| @min(m, d) else d;
    }
    return nearest;
}

/// Drop tickets of a dying realm (their promises die with the arena).
pub fn abandonPropAsync(g: *gil_mod.Gil) void {
    const owner: *const anyopaque = @ptrCast(g);
    var i: usize = 0;
    while (i < g.prop_async.items.len) {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(g.prop_async.items[i]));
        if (t.owner == owner) {
            prop_alloc.destroy(t);
            _ = g.prop_async.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn propWait(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].asObj();
    const key_tmp = try self.keyOf(argAt(args, 1));
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.wait: object has no own data property");
    if (!sameValueZero(cur, argAt(args, 2))) return Value.str("not-equal");
    if (timeout_ns != null and timeout_ns.? == 0) return Value.str("timed-out");
    if (!self.main_can_block)
        return self.throwError("TypeError", "Atomics.wait cannot be called from the current thread.");
    const key = try self.arena.dupe(u8, key_tmp);
    var ticket = PropTicket{ .obj = o, .key = key };
    const g = self.gil.?;
    g.prop_waiters.append(self.arena, @ptrCast(&ticket)) catch return error.OutOfMemory;
    defer for (g.prop_waiters.items, 0..) |raw, i| {
        const t: *PropTicket = @ptrCast(@alignCast(raw));
        if (t == &ticket) {
            _ = g.prop_waiters.orderedRemove(i);
            break;
        }
    };
    const deadline_ns: ?i96 = if (timeout_ns) |ns|
        std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds + ns
    else
        null;
    while (!ticket.woken) {
        pumpTasks(self);
        if (self.stop_flag) |sf| if (sf.load(.monotonic))
            return self.throwError("Error", "worker terminated");
        if (ticket.woken) break;
        var tick_ns: u64 = 5 * std.time.ns_per_ms;
        if (deadline_ns) |d| {
            const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
            if (d <= now) return Value.str("timed-out");
            tick_ns = @min(tick_ns, @as(u64, @intCast(d - now)));
        }
        g.waitTimeout(&ticket.cond, .{ .duration = .{
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
    for (g.prop_waiters.items) |raw| {
        const t: *PropTicket = @ptrCast(@alignCast(raw));
        if (n >= count) break;
        if (!t.woken and t.obj == o and std.mem.eql(u8, t.key, key)) {
            t.woken = true;
            t.cond.signal(io);
            n += 1;
        }
    }
    var i: usize = 0;
    while (i < g.prop_async.items.len and n < count) {
        const t: *PropAsyncTicket = @ptrCast(@alignCast(g.prop_async.items[i]));
        if (t.obj == o and std.mem.eql(u8, t.key, key)) {
            _ = g.prop_async.orderedRemove(i);
            settlePropAsync(self, t, "ok"); // settling-thread rule
            n += 1;
            continue;
        }
        i += 1;
    }
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
    if (rec.done) {
        if (rec.threw) try promise.reject(self, pp, rec.result) else try promise.resolve(self, pp, rec.result);
    } else {
        try rec.pending_joins.append(self.arena, p_obj);
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
    if (o.restricted_to) |owner| {
        if (owner != tid)
            return self.throwError("ConcurrentAccessError", "Thread.restrict called from a non-owning thread");
        return v; // owner double-restrict is a no-op returning o
    }
    o.restricted_to = tid;
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

const HoldJob = struct {
    lock: *LockRecord,
    outer: *value.Object,
    /// User fn (with-fn arity), or null = resolve with a release() function.
    cb: ?Value,
};

const ReleaseState = struct { lock: *LockRecord, used: bool = false };

/// `holder` value for an asyncHold grant: the hold belongs to the JOB, not
/// to any thread — a same-thread sync `hold` must read as CONTENDED (block
/// or gate), never as recursive.
const async_holder: u64 = std.math.maxInt(u64);

/// Centralized release: hand the lock to the next queued asyncHold job
/// (granted on this, the releasing thread), else open it and wake a parked
/// hold.
fn lockRelease(self: *Interpreter, rec: *LockRecord) void {
    if (rec.sync_waiting > 0) {
        rec.locked = false;
        rec.holder = 0;
        rec.sync_generation +%= 1;
        rec.cond.signal(agent.engineIo());
        return;
    }
    if (rec.pending.items.len > 0) {
        const job = rec.pending.orderedRemove(0);
        rec.locked = false;
        rec.holder = 0;
        rec.grant_pending = false;
        enqueueHoldJob(self, job) catch {};
        return;
    }
    rec.locked = false;
    rec.holder = 0;
    rec.cond.signal(agent.engineIo());
}

/// Queue `job` on the realm's run-loop TASK queue (gil.tasks). Tasks are
/// pumped at the drain tail and at every park — a grant delivery must make
/// progress even while its granting thread is blocked (the corpus's
/// waitUntil/sleepMs rendezvous depend on it).
fn enqueueHoldJob(self: *Interpreter, job: *HoldJob) value.HostError!void {
    const g = self.gil orelse return;
    try g.tasks.append(self.arena, @ptrCast(job));
}

/// Pump the realm's run-loop tasks: run each pending grant delivery as its
/// own turn (draining the pumping thread's microtasks after each). Called
/// from the drain tail and from every parking point.
pub fn pumpTasks(self: *Interpreter) void {
    const g = self.gil orelse return;
    while (g.tasks.items.len > 0) {
        const raw = g.tasks.orderedRemove(0);
        const job: *HoldJob = @ptrCast(@alignCast(raw));
        runHoldJob(self, job) catch {};
        self.drainMicrotasks() catch {};
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

fn runHoldJob(self: *Interpreter, job: *HoldJob) value.HostError!void {
    const outer_pp = promise.promiseOf(Value.obj(job.outer)).?;
    if (!job.lock.locked) {
        job.lock.locked = true;
        job.lock.holder = async_holder;
    } else if (!job.lock.grant_pending or job.lock.holder != async_holder) {
        try job.lock.pending.insert(self.arena, 0, job);
        return;
    }
    // The grant is now DELIVERED.
    job.lock.grant_pending = false;
    if (job.cb) |cb| {
        // A live with-fn grant is async-held by the thread running fn (D12):
        // cond.asyncWait may consume it, but sync cond.wait still requires a
        // genuine sync hold.
        job.lock.async_runner = currentTid();
        const out = self.callValueWithThis(cb, &.{}, Value.undef());
        // fn may itself have consumed the hold (same-thread asyncWait, I23);
        // only release when this grant still owns the lock.
        if (job.lock.locked and job.lock.async_runner == currentTid()) {
            job.lock.async_runner = 0;
            lockRelease(self, job.lock); // implicit release, throw or not
        }
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
    const st = try self.arena.create(ReleaseState);
    st.* = .{ .lock = job.lock };
    job.lock.active_release = st;
    const rel = try gc_mod.allocObj(self.arena);
    rel.* = .{ .native = releaseFnNative, .private_data = st };
    try promise.resolve(self, outer_pp, Value.obj(rel));
}

fn releaseFnNative(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const native = self.active_native orelse return Value.undef();
    const st: *ReleaseState = @ptrCast(@alignCast(native.private_data.?));
    if (st.used) return self.throwError("Error", "Lock release function called more than once");
    st.used = true;
    if (st.lock.active_release == st) st.lock.active_release = null;
    lockRelease(self, st.lock);
    return Value.undef();
}

/// `Lock.prototype.asyncHold(fn?)`.
fn lockAsyncHoldFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.asyncHold called on incompatible receiver");
    const cb = if (args.len > 0) args[0] else Value.undef();
    if (!cb.isUndefined() and !cb.isCallable())
        return self.throwError("TypeError", "Lock.prototype.asyncHold requires a callable argument when one is provided");
    if (rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid()))
        return self.throwError("Error", "Lock is not recursive");
    const outer = try promise.newPromise(self);
    const job = try self.arena.create(HoldJob);
    job.* = .{ .lock = rec, .outer = outer, .cb = if (cb.isUndefined()) null else cb };
    if (!rec.locked) {
        rec.locked = true; // the grant happens at registration (5.5a)
        rec.holder = async_holder;
        rec.grant_pending = true;
        try enqueueHoldJob(self, job);
    } else {
        try rec.pending.append(self.arena, job);
    }
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
    if (!lock.locked or lock.grant_pending)
        return self.throwError("TypeError", "Condition.prototype.asyncWait requires the lock to be held");
    if (lock.active_release) |st| {
        st.used = true; // consume: the original release() now throws
        lock.active_release = null;
    } else if (lock.async_runner == currentTid()) {
        lock.async_runner = 0;
    } else if (lock.holder != currentTid()) {
        return self.throwError("TypeError", "Condition.prototype.asyncWait requires the lock to be held");
    }
    const outer = try promise.newPromise(self);
    const w = try self.arena.create(AsyncCondWaiter);
    w.* = .{ .lock = lock, .outer = outer };
    try rec.queue.append(self.arena, .{ .asynchronous = w });
    lockRelease(self, lock);
    return Value.obj(outer);
}

/// Notify-side wake of an async cond waiter: the wake is a no-fn asyncHold
/// grant — the promise resolves holding the lock again, with a release()
/// function (the corpus consumes `p.then(release => ...)`).
fn wakeAsyncCondWaiter(self: *Interpreter, w: *AsyncCondWaiter) void {
    const job = self.arena.create(HoldJob) catch return;
    job.* = .{ .lock = w.lock, .outer = w.outer, .cb = null };
    if (!w.lock.locked) {
        w.lock.locked = true;
        w.lock.holder = async_holder;
        w.lock.grant_pending = true;
        enqueueHoldJob(self, job) catch {};
    } else {
        w.lock.pending.append(self.arena, job) catch {};
    }
}
