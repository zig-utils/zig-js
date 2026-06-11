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
const value = @import("value.zig");
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
    result: Value = .undefined,
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

/// Install the `Thread` global into an `enable_threads` Context. Called by
/// `Context.createWith` while still single-threaded.
pub fn installThreadAPI(ctx: *Context) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;

    const proto = try a.create(value.Object);
    proto.* = .{};
    try interp.setNative(a, rs, proto, "join", 0, threadJoinFn);
    try interp.setNative(a, rs, proto, "asyncJoin", 0, threadAsyncJoinFn);
    try interp.setNativeGetter(a, rs, proto, "id", threadIdGetter);
    try setTag(ctx, proto, "Thread");

    const ctor = try a.create(value.Object);
    ctor.* = .{ .native = threadCtorFn, .native_ctor = true, .private_data = ctx };
    try ctor.setOwn(a, rs, "prototype", .{ .object = proto });
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try interp.setConstructor(a, rs, proto, ctor);
    try interp.setNativeGetter(a, rs, ctor, "current", threadCurrentGetter);
    try interp.setNative(a, rs, ctor, "restrict", 1, threadRestrictFn);

    try ctx.env.put("Thread", .{ .object = ctor });
    try ctx.global_object.setOwn(a, rs, "Thread", .{ .object = ctor });
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
    if (base_v != .object) return;
    const base_proto_v = base_v.object.getOwn("prototype") orelse return;
    if (base_proto_v != .object) return;

    const ctor = try a.create(value.Object);
    ctor.* = .{ .error_ctor = name, .private_data = @ptrCast(&ctx.env), .proto = base_v.object };
    try interp.installNativeProps(a, rs, ctor, name, 1);
    const proto = try a.create(value.Object);
    proto.* = .{ .proto = base_proto_v.object };
    const ro = value.PropAttr{ .writable = true, .enumerable = false, .configurable = true };
    try proto.setOwn(a, rs, "name", .{ .string = name });
    try proto.setAttr(a, "name", ro);
    try proto.setOwn(a, rs, "message", .{ .string = "" });
    try proto.setAttr(a, "message", ro);
    try proto.setOwn(a, rs, "constructor", .{ .object = ctor });
    try proto.setAttr(a, "constructor", ro);
    try ctor.setOwn(a, rs, "prototype", .{ .object = proto });
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try ctx.env.put(name, .{ .object = ctor });
    try ctx.global_object.setOwn(a, rs, name, .{ .object = ctor });
    try ctx.global_object.setAttr(a, name, .{ .writable = true, .enumerable = false, .configurable = true });
}

fn makeWrapper(ctx: *Context, rec: *ThreadRecord) !*value.Object {
    const a = ctx.arena();
    const o = try a.create(value.Object);
    o.* = .{ .private_data = rec };
    if (ctx.env.get("Thread")) |c| if (c == .object) {
        if (try threadProtoOf(ctx, c.object)) |p| o.proto = p;
    };
    return o;
}

fn threadProtoOf(ctx: *Context, ctor: *value.Object) !?*value.Object {
    var machine = ctx.interpreter();
    const p = try machine.getProperty(.{ .object = ctor }, "prototype");
    return if (p == .object) p.object else null;
}

var next_thread_id = std.atomic.Value(u32).init(1);

fn recordOf(self: *Interpreter, this: Value) ?*ThreadRecord {
    _ = self;
    if (this != .object) return null;
    const pd = this.object.private_data orelse return null;
    // Only Thread wrappers reach the Thread.prototype methods in practice;
    // the private_data brand is the check.
    if (this.object.proto == null) return null;
    return @ptrCast(@alignCast(pd));
}

/// `new Thread(fn, ...args)` — spawn fn on a new OS thread in this realm.
fn threadCtorFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    if (self.new_target == .undefined) return self.throwError("TypeError", "calling Thread constructor without new is invalid");
    const native = self.active_native orelse return self.throwError("TypeError", "Thread constructor lost its context");
    const ctx: *Context = @ptrCast(@alignCast(native.private_data.?));
    const g = ctx.gil orelse return self.throwError("TypeError", "Thread requires an enable_threads Context");

    const fn_v = if (args.len > 0) args[0] else Value.undefined;
    if (!fn_v.isCallable())
        return self.throwError("TypeError", "Thread constructor requires a callable argument");

    const a = ctx.arena();
    const rec = try a.create(ThreadRecord);
    rec.* = .{ .id = next_thread_id.fetchAdd(1, .monotonic), .gil = g, .ctx = ctx };
    rec.js_obj = makeWrapper(ctx, rec) catch return error.OutOfMemory;
    const call_args = try a.dupe(Value, if (args.len > 1) args[1..] else &.{});
    try ctx.js_threads.append(ctx.gpa, rec);

    rec.thread = std.Thread.spawn(.{}, threadMain, .{ rec, fn_v, call_args }) catch {
        rec.done = true;
        return self.throwError("Error", "Thread: could not spawn OS thread");
    };
    return .{ .object = rec.js_obj.? };
}

fn threadMain(rec: *ThreadRecord, fn_v: Value, args: []const Value) void {
    const g = rec.gil;
    g.acquire();
    defer g.release();
    t_current = rec;
    // A per-thread interpreter over the SHARED realm: same arena, environment,
    // global object, and shapes (safe under the GIL), with its own job queues.
    // join() performs the joiner's completion checkpoint before observing the
    // result, which is the only cross-thread microtask drain point.
    var microtasks: std.ArrayListUnmanaged(@import("promise.zig").Microtask) = .empty;
    var async_waiters: std.ArrayListUnmanaged(interp.AsyncWaiterEntry) = .empty;
    var machine = rec.ctx.interpreter();
    machine.microtasks = &microtasks;
    machine.async_waiters = &async_waiters;
    if (machine.callValueWithThis(fn_v, args, .undefined)) |out| {
        machine.drainMicrotasks() catch {};
        pumpTasks(&machine);
        machine.settleAsyncWaiters();
        rec.result = out;
    } else |_| {
        machine.drainMicrotasks() catch {};
        rec.threw = true;
        rec.result = machine.exception;
    }
    rec.done = true;
    // Settle asyncJoin promises on this (the settling) thread, then drain
    // the reactions it just queued.
    for (rec.pending_joins.items) |p_obj| {
        if (promise.promiseOf(.{ .object = p_obj })) |pp| {
            if (rec.threw)
                promise.reject(&machine, pp, rec.result) catch {}
            else
                promise.resolve(&machine, pp, rec.result) catch {};
        }
    }
    rec.pending_joins.clearRetainingCapacity();
    machine.drainMicrotasks() catch {};
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
    if (!rec.done and !agent.main_can_block)
        return self.throwError("TypeError", "Thread.prototype.join cannot block the current thread");
    while (!rec.done) parkPump(self, rec.gil, &rec.done_cond);
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
    return .{ .number = @floatFromInt(rec.id) };
}

fn threadCurrentGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    _ = self;
    const rec = t_current orelse return .undefined;
    return .{ .object = rec.js_obj.? };
}

// ---- Lock / Condition / ThreadLocal (Phase 6 step 3) -----------------------
// PR-249 semantics: Lock is non-recursive with a `hold(fn)` discipline
// (release is finally-equivalent); Condition.wait(lock) atomically releases
// the lock and parks (spurious wakeups allowed); ThreadLocal.value is
// per-thread storage for any JS value. All parking goes through `Gil.wait`,
// so the VM lock is never held while blocked.

const LockRecord = struct {
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
};

const CondRecord = struct {
    gil: *gil_mod.Gil,
    cond: std.Io.Condition = .init,
    /// JS-level waiters currently parked (GIL-protected) and how many of
    /// them already have an unconsumed wake — notify must report exactly how
    /// many it woke, and back-to-back notifies must not overcount.
    waiting: usize = 0,
    signalled: usize = 0,
    /// asyncWait waiters, woken FIFO after the parked ones.
    async_waiting: std.ArrayListUnmanaged(*AsyncCondWaiter) = .empty,
};

const TLRecord = struct {
    gil: *gil_mod.Gil,
    arena: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
};

fn currentTid() u64 {
    return @intCast(std.Thread.getCurrentId());
}

/// Install Lock/Condition/ThreadLocal alongside Thread (same Context).
fn installSyncAPI(ctx: *Context) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;

    const lock_proto = try a.create(value.Object);
    lock_proto.* = .{};
    try interp.setNative(a, rs, lock_proto, "hold", 1, lockHoldFn);
    try interp.setNative(a, rs, lock_proto, "asyncHold", 1, lockAsyncHoldFn);
    try interp.setNativeGetter(a, rs, lock_proto, "locked", lockLockedGetter);
    try setTag(ctx, lock_proto, "Lock");
    try installCtor(ctx, "Lock", lockCtorFn, lock_proto);

    const cond_proto = try a.create(value.Object);
    cond_proto.* = .{};
    try interp.setNative(a, rs, cond_proto, "wait", 1, condWaitFn);
    try interp.setNative(a, rs, cond_proto, "notify", 0, condNotifyFn(false));
    try interp.setNative(a, rs, cond_proto, "notifyAll", 0, condNotifyFn(true));
    try interp.setNative(a, rs, cond_proto, "asyncWait", 1, condAsyncWaitFn);
    try setTag(ctx, cond_proto, "Condition");
    try installCtor(ctx, "Condition", condCtorFn, cond_proto);

    const tl_proto = try a.create(value.Object);
    tl_proto.* = .{};
    const getter = try a.create(value.Object);
    getter.* = .{ .native = tlValueGetFn };
    const setter = try a.create(value.Object);
    setter.* = .{ .native = tlValueSetFn };
    try tl_proto.setAccessor(a, "value", .{ .object = getter }, .{ .object = setter });
    try tl_proto.setAttr(a, "value", .{ .enumerable = false, .configurable = true });
    try setTag(ctx, tl_proto, "ThreadLocal");
    try installCtor(ctx, "ThreadLocal", tlCtorFn, tl_proto);
}

/// `Symbol.toStringTag` on a prototype (the corpus checks "[object Lock]").
fn setTag(ctx: *Context, proto: *value.Object, name: []const u8) !void {
    var machine = ctx.interpreter();
    const k = machine.wellKnownSymbolKey("toStringTag") orelse return;
    const a = ctx.arena();
    try proto.setOwn(a, ctx.root_shape, k, .{ .string = name });
    try proto.setAttr(a, k, .{ .writable = false, .enumerable = false, .configurable = true });
}

fn installCtor(ctx: *Context, name: []const u8, f: value.NativeFn, proto: *value.Object) !void {
    const a = ctx.arena();
    const rs = ctx.root_shape;
    const ctor = try a.create(value.Object);
    ctor.* = .{ .native = f, .native_ctor = true, .private_data = ctx };
    try ctor.setOwn(a, rs, "prototype", .{ .object = proto });
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try interp.setConstructor(a, rs, proto, ctor);
    try ctx.env.put(name, .{ .object = ctor });
    try ctx.global_object.setOwn(a, rs, name, .{ .object = ctor });
    try ctx.global_object.setAttr(a, name, .{ .writable = true, .enumerable = false, .configurable = true });
}

/// Shared ctor shape: a fresh instance whose private_data is a record of `T`.
fn syncCtor(comptime T: type, comptime ctor_name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = this;
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
            if (self.new_target == .undefined) return self.throwError("TypeError", "calling " ++ ctor_name ++ " constructor without new is invalid");
            const native = self.active_native orelse return self.throwError("TypeError", "constructor lost its context");
            const ctx: *Context = @ptrCast(@alignCast(native.private_data.?));
            const g = ctx.gil orelse return self.throwError("TypeError", "requires an enable_threads Context");
            const a = ctx.arena();
            const rec = try a.create(T);
            rec.* = if (T == TLRecord) .{ .gil = g, .arena = a } else .{ .gil = g };
            const o = try a.create(value.Object);
            o.* = .{ .private_data = rec };
            const p = try self.getProperty(.{ .object = native }, "prototype");
            if (p == .object) o.proto = p.object;
            return .{ .object = o };
        }
    }.call;
}

const lockCtorFn = syncCtor(LockRecord, "Lock");
const condCtorFn = syncCtor(CondRecord, "Condition");
const tlCtorFn = syncCtor(TLRecord, "ThreadLocal");

fn recOf(comptime T: type, this: Value) ?*T {
    if (this != .object) return null;
    const pd = this.object.private_data orelse return null;
    return @ptrCast(@alignCast(pd));
}

/// `Lock.prototype.hold(fn)` — acquire (parking GIL-released while
/// contended), run fn, release even when fn throws.
fn lockHoldFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.hold called on incompatible receiver");
    const cb = if (args.len > 0) args[0] else Value.undefined;
    if (!cb.isCallable()) return self.throwError("TypeError", "Lock.prototype.hold requires a callable argument");
    if (rec.locked and (rec.holder == currentTid() or rec.async_runner == currentTid()))
        return self.throwError("Error", "Lock is not recursive");
    // tryLock-first: only a CONTENDED hold blocks, so only it gates.
    if (rec.locked and !agent.main_can_block)
        return self.throwError("TypeError", "Lock.prototype.hold cannot block the current thread");
    rec.sync_waiting += 1;
    while (rec.locked) parkPump(self, rec.gil, &rec.cond);
    rec.sync_waiting -= 1;
    rec.locked = true;
    rec.holder = currentTid();
    const out = self.callValueWithThis(cb, &.{}, .undefined);
    lockRelease(self, rec);
    return out;
}

fn lockLockedGetter(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.locked called on incompatible receiver");
    return .{ .boolean = rec.locked };
}

/// `Condition.prototype.wait(lock)` — atomically release the lock and park;
/// reacquire before returning. Spurious wakeups are permitted by spec, so
/// callers loop on their predicate.
fn condWaitFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.wait called on incompatible receiver");
    const lock = recOf(LockRecord, if (args.len > 0) args[0] else .undefined) orelse
        return self.throwError("TypeError", "Condition.prototype.wait requires a Lock argument");
    if (!lock.locked or lock.holder != currentTid())
        return self.throwError("TypeError", "Condition.prototype.wait requires the lock to be held by the caller");
    if (!agent.main_can_block)
        return self.throwError("TypeError", "Condition.prototype.wait cannot block the current thread");
    // Atomic under the GIL: nothing else runs between the release below and
    // our park inside gil.wait (which registers before unlocking).
    lockRelease(self, lock);
    rec.waiting += 1;
    while (rec.signalled == 0) parkPump(self, rec.gil, &rec.cond);
    rec.waiting -= 1;
    rec.signalled -= 1;
    lock.sync_waiting += 1;
    while (lock.locked) parkPump(self, rec.gil, &lock.cond);
    lock.sync_waiting -= 1;
    lock.locked = true;
    lock.holder = currentTid();
    return .undefined;
}

fn condNotifyFn(comptime all: bool) value.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
            const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.notify called on incompatible receiver");
            const wakeable = rec.waiting - rec.signalled;
            if (all) {
                rec.signalled = rec.waiting;
                rec.cond.broadcast(agent.engineIo());
                var n = wakeable;
                while (rec.async_waiting.items.len > 0) {
                    wakeAsyncCondWaiter(self, rec.async_waiting.orderedRemove(0));
                    n += 1;
                }
                // The corpus's scheduling contracts: notifyAll performs an
                // unconditional depth-free GIL handoff (notify-all-shared-
                // lock), and FIFO between woken sync waiters and async
                // waiters (condition-async-wait) requires every issued wake
                // to be CONSUMED before the notifier proceeds — a woken
                // waiter re-registers on the lock within a single GIL hold,
                // so once `signalled` drains, the sync waiters are queued
                // ahead of any async regrant.
                if (self.gil) |g| {
                    while (rec.signalled > 0) {
                        g.release();
                        std.Thread.yield() catch {};
                        g.acquire();
                    }
                }
                return .{ .number = @floatFromInt(n) };
            }
            if (wakeable > 0) {
                rec.signalled += 1;
                rec.cond.signal(agent.engineIo());
                return .{ .number = 1 };
            }
            if (rec.async_waiting.items.len > 0) {
                wakeAsyncCondWaiter(self, rec.async_waiting.orderedRemove(0));
                return .{ .number = 1 };
            }
            return .{ .number = 0 };
        }
    }.call;
}

fn tlValueGetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.prototype.value called on incompatible receiver");
    return rec.map.get(currentTid()) orelse .undefined;
}

fn tlValueSetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.prototype.value called on incompatible receiver");
    const v = if (args.len > 0) args[0] else Value.undefined;
    try rec.map.put(rec.arena, currentTid(), v);
    return .undefined;
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
    return self.gil != null and v == .object and v.object.typed_array == null;
}

fn sameValueZero(a: Value, b: Value) bool {
    if (a == .number and b == .number)
        return a.number == b.number or (std.math.isNan(a.number) and std.math.isNan(b.number));
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
    if (interp.objectHasOwn(o, key)) return self.getProperty(.{ .object = o }, key);
    return self.throwError("TypeError", what);
}

fn writableOrThrow(self: *Interpreter, o: *value.Object, key: []const u8, what: []const u8) value.HostError!void {
    if (!o.getAttr(key).writable) return self.throwError("TypeError", what);
}

fn argAt(args: []const Value, i: usize) Value {
    return if (args.len > i) args[i] else .undefined;
}

pub fn propLoad(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].object;
    const key = try self.keyOf(argAt(args, 1));
    return ownDataOrThrow(self, o, key, "Atomics.load: object has no own property");
}

pub fn propStore(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].object;
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
    try self.setMember(.{ .object = o }, key, v);
    return v;
}

pub fn propExchange(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].object;
    const key = try self.keyOf(argAt(args, 1));
    const old = try ownDataOrThrow(self, o, key, "Atomics.exchange: object has no own data property");
    try writableOrThrow(self, o, key, "Atomics.exchange: property is not writable");
    try self.setMember(.{ .object = o }, key, argAt(args, 2));
    return old;
}

pub fn propCompareExchange(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].object;
    const key = try self.keyOf(argAt(args, 1));
    const old = try ownDataOrThrow(self, o, key, "Atomics.compareExchange: object has no own data property");
    // The writability rule throws unconditionally — even when the compare
    // would fail.
    try writableOrThrow(self, o, key, "Atomics.compareExchange: property is not writable");
    if (sameValueZero(old, argAt(args, 2)))
        try self.setMember(.{ .object = o }, key, argAt(args, 3));
    return old;
}

pub const PropRmwOp = enum { add, sub, and_, or_, xor };

pub fn propRmw(self: *Interpreter, op: PropRmwOp, args: []const Value) value.HostError!Value {
    const o = args[0].object;
    const key = try self.keyOf(argAt(args, 1));
    const old = try ownDataOrThrow(self, o, key, "Atomics RMW: object has no own data property");
    try writableOrThrow(self, o, key, "Atomics RMW: property is not writable");
    if (old != .number) return self.throwError("TypeError", "Atomics RMW: stored value is not a number");
    const operand = try self.toNumberV(argAt(args, 2));
    const result: f64 = switch (op) {
        .add => old.number + operand,
        .sub => old.number - operand,
        // Bitwise ops use JS ToInt32 semantics on both sides.
        .and_ => @floatFromInt(jsInt32(old.number) & jsInt32(operand)),
        .or_ => @floatFromInt(jsInt32(old.number) | jsInt32(operand)),
        .xor => @floatFromInt(jsInt32(old.number) ^ jsInt32(operand)),
    };
    try self.setMember(.{ .object = o }, key, .{ .number = result });
    return old;
}

fn jsInt32(n: f64) i32 {
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const wrapped = @mod(@trunc(n), 4294967296.0);
    const u: u32 = @intFromFloat(if (wrapped < 0) wrapped + 4294967296.0 else wrapped);
    return @bitCast(u);
}

// One global FIFO of property waiters (GIL-serialized; tickets live on the
// waiting thread's stack and are unlinked before wait returns).
const PropTicket = struct {
    obj: *value.Object,
    key: []const u8,
    cond: std.Io.Condition = .init,
    woken: bool = false,
};
var prop_waiters: std.ArrayListUnmanaged(*PropTicket) = .empty;
const prop_alloc = std.heap.page_allocator;

const PropAsyncTicket = struct {
    obj: *value.Object,
    key: []const u8,
    deadline_ns: ?i96,
    promise: *value.Object,
    /// The realm's gil pointer — the abandon token at Context.destroy.
    owner: *const anyopaque,
};
var prop_async: std.ArrayListUnmanaged(*PropAsyncTicket) = .empty;

/// `Atomics.waitAsync(obj, key, expected, timeout)` — the property path.
/// Settlement: a notify resolves "ok" on the notifying thread; expiry
/// resolves "timed-out" from the awaiters' poll points.
pub fn propWaitAsync(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].object;
    const key_tmp = try self.keyOf(argAt(args, 1));
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.waitAsync: object has no own data property");
    const res = (try self.newObject()).object;
    if (!sameValueZero(cur, argAt(args, 2))) {
        try self.setProp(res, "async", .{ .boolean = false });
        try self.setProp(res, "value", .{ .string = "not-equal" });
        return .{ .object = res };
    }
    if (timeout_ns != null and timeout_ns.? == 0) {
        try self.setProp(res, "async", .{ .boolean = false });
        try self.setProp(res, "value", .{ .string = "timed-out" });
        return .{ .object = res };
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
    prop_async.append(prop_alloc, t) catch {
        prop_alloc.destroy(t);
        return error.OutOfMemory;
    };
    try self.setProp(res, "async", .{ .boolean = true });
    try self.setProp(res, "value", .{ .object = p_obj });
    return .{ .object = res };
}

fn settlePropAsync(self: *Interpreter, t: *PropAsyncTicket, outcome: []const u8) void {
    if (promise.promiseOf(.{ .object = t.promise })) |pp| {
        promise.resolve(self, pp, .{ .string = outcome }) catch {};
    }
    prop_alloc.destroy(t);
}

/// Resolve expired property waitAsync tickets — called from the awaiters'
/// poll points (awaitValue's GIL-handover loop, the drain tail).
pub fn pollPropAsync(self: *Interpreter) void {
    if (prop_async.items.len == 0) return;
    const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
    var i: usize = 0;
    while (i < prop_async.items.len) {
        const t = prop_async.items[i];
        if (t.deadline_ns != null and t.deadline_ns.? <= now) {
            _ = prop_async.orderedRemove(i);
            settlePropAsync(self, t, "timed-out");
            continue;
        }
        i += 1;
    }
}

/// Drop tickets of a dying realm (their promises die with the arena).
pub fn abandonPropAsync(owner: *const anyopaque) void {
    var i: usize = 0;
    while (i < prop_async.items.len) {
        if (prop_async.items[i].owner == owner) {
            prop_alloc.destroy(prop_async.items[i]);
            _ = prop_async.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn propWait(self: *Interpreter, args: []const Value, timeout_ns: ?u64) value.HostError!Value {
    const o = args[0].object;
    const key_tmp = try self.keyOf(argAt(args, 1));
    const cur = try ownDataOrThrow(self, o, key_tmp, "Atomics.wait: object has no own data property");
    if (!sameValueZero(cur, argAt(args, 2))) return .{ .string = "not-equal" };
    if (timeout_ns != null and timeout_ns.? == 0) return .{ .string = "timed-out" };
    if (!agent.main_can_block)
        return self.throwError("TypeError", "Atomics.wait cannot be called from the current thread.");
    const key = try self.arena.dupe(u8, key_tmp);
    var ticket = PropTicket{ .obj = o, .key = key };
    prop_waiters.append(prop_alloc, &ticket) catch return error.OutOfMemory;
    defer for (prop_waiters.items, 0..) |t, i| {
        if (t == &ticket) {
            _ = prop_waiters.orderedRemove(i);
            break;
        }
    };
    const g = self.gil.?;
    const deadline_ns: ?i96 = if (timeout_ns) |ns|
        std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds + ns
    else
        null;
    while (!ticket.woken) {
        pumpTasks(self);
        if (ticket.woken) break;
        var tick_ns: u64 = 5 * std.time.ns_per_ms;
        if (deadline_ns) |d| {
            const now = std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds;
            if (d <= now) return .{ .string = "timed-out" };
            tick_ns = @min(tick_ns, @as(u64, @intCast(d - now)));
        }
        g.waitTimeout(&ticket.cond, .{ .duration = .{
            .raw = .fromNanoseconds(tick_ns),
            .clock = .awake,
        } }) catch {};
    }
    return .{ .string = "ok" };
}

pub fn propNotify(self: *Interpreter, args: []const Value) value.HostError!Value {
    const o = args[0].object;
    const key = try self.keyOf(argAt(args, 1));
    var count: usize = std.math.maxInt(usize);
    if (args.len > 2 and args[2] != .undefined) {
        const n = try self.toNumberV(args[2]);
        if (std.math.isNan(n) or n <= 0) count = 0 else if (n != std.math.inf(f64) and n < 1e18) count = @intFromFloat(@trunc(n));
    }
    const io = agent.engineIo();
    var n: usize = 0;
    for (prop_waiters.items) |t| {
        if (n >= count) break;
        if (!t.woken and t.obj == o and std.mem.eql(u8, t.key, key)) {
            t.woken = true;
            t.cond.signal(io);
            n += 1;
        }
    }
    var i: usize = 0;
    while (i < prop_async.items.len and n < count) {
        const t = prop_async.items[i];
        if (t.obj == o and std.mem.eql(u8, t.key, key)) {
            _ = prop_async.orderedRemove(i);
            settlePropAsync(self, t, "ok"); // settling-thread rule
            n += 1;
            continue;
        }
        i += 1;
    }
    return .{ .number = @floatFromInt(n) };
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
    const pp = promise.promiseOf(.{ .object = p_obj }).?;
    if (rec.done) {
        if (rec.threw) try promise.reject(self, pp, rec.result) else try promise.resolve(self, pp, rec.result);
    } else {
        try rec.pending_joins.append(self.arena, p_obj);
    }
    return .{ .object = p_obj };
}

/// `Thread.restrict(obj)` — pin `obj` to the calling thread; any enforced
/// access from another thread throws ConcurrentAccessError. The restrictable
/// set is an allowlist: plain objects and plain arrays (everything exotic —
/// callables, proxies, the global, views/buffers, collections, dates,
/// regexps, errors, builtin prototypes — is refused, per the corpus).
fn threadRestrictFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const v = if (args.len > 0) args[0] else Value.undefined;
    if (v != .object) return self.throwError("TypeError", "cannot restrict this object");
    const o = v.object;
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

/// Pump-then-park tick: serve pending run-loop tasks, then wait on `cond`
/// briefly (tasks have no dedicated wakeup; parked pumpers poll).
fn parkPump(self: *Interpreter, g: *gil_mod.Gil, cond: *std.Io.Condition) void {
    pumpTasks(self);
    g.waitTimeout(cond, .{ .duration = .{
        .raw = .fromMilliseconds(5),
        .clock = .awake,
    } }) catch {};
}

fn runHoldJob(self: *Interpreter, job: *HoldJob) value.HostError!void {
    const outer_pp = promise.promiseOf(.{ .object = job.outer }).?;
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
        const out = self.callValueWithThis(cb, &.{}, .undefined);
        // fn may itself have consumed the hold (same-thread asyncWait, I23);
        // only release when this grant still owns the lock.
        if (job.lock.locked and job.lock.async_runner == currentTid()) {
            job.lock.async_runner = 0;
            lockRelease(self, job.lock); // implicit release, throw or not
        }
        if (out) |v| {
            try promise.resolve(self, outer_pp, v);
        } else |_| {
            try promise.reject(self, outer_pp, self.exception);
        }
        return;
    }
    // no-fn arity: resolve with a once-only release() function.
    const st = try self.arena.create(ReleaseState);
    st.* = .{ .lock = job.lock };
    job.lock.active_release = st;
    const rel = try self.arena.create(value.Object);
    rel.* = .{ .native = releaseFnNative, .private_data = st };
    try promise.resolve(self, outer_pp, .{ .object = rel });
}

fn releaseFnNative(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const native = self.active_native orelse return .undefined;
    const st: *ReleaseState = @ptrCast(@alignCast(native.private_data.?));
    if (st.used) return self.throwError("Error", "Lock release function called more than once");
    st.used = true;
    if (st.lock.active_release == st) st.lock.active_release = null;
    lockRelease(self, st.lock);
    return .undefined;
}

/// `Lock.prototype.asyncHold(fn?)`.
fn lockAsyncHoldFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.asyncHold called on incompatible receiver");
    const cb = if (args.len > 0) args[0] else Value.undefined;
    if (cb != .undefined and !cb.isCallable())
        return self.throwError("TypeError", "Lock.prototype.asyncHold requires a callable argument when one is provided");
    const outer = try promise.newPromise(self);
    const job = try self.arena.create(HoldJob);
    job.* = .{ .lock = rec, .outer = outer, .cb = if (cb == .undefined) null else cb };
    if (!rec.locked) {
        rec.locked = true; // the grant happens at registration (5.5a)
        rec.holder = async_holder;
        rec.grant_pending = true;
        try enqueueHoldJob(self, job);
    } else {
        try rec.pending.append(self.arena, job);
    }
    return .{ .object = outer };
}

const AsyncCondWaiter = struct { lock: *LockRecord, outer: *value.Object };

/// `Condition.prototype.asyncWait(lock)` — releases the lock, parks as an
/// async waiter; the promise resolves holding the lock again.
fn condAsyncWaitFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.asyncWait called on incompatible receiver");
    const lock = recOf(LockRecord, if (args.len > 0) args[0] else .undefined) orelse
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
    try rec.async_waiting.append(self.arena, w);
    lockRelease(self, lock);
    return .{ .object = outer };
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
