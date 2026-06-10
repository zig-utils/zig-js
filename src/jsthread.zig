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

    const ctor = try a.create(value.Object);
    ctor.* = .{ .native = threadCtorFn, .native_ctor = true, .private_data = ctx };
    try ctor.setOwn(a, rs, "prototype", .{ .object = proto });
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try interp.setConstructor(a, rs, proto, ctor);
    try interp.setNativeGetter(a, rs, ctor, "current", threadCurrentGetter);

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
}

fn makeWrapper(ctx: *Context, rec: *ThreadRecord) !*value.Object {
    const a = ctx.arena();
    const o = try a.create(value.Object);
    o.* = .{ .private_data = rec };
    if (ctx.env.get("Thread")) |c| if (c == .object) {
        if (try threadProtoOf(ctx, c.object)) |p| o.proto = p;
    };
    try o.setOwn(a, ctx.root_shape, "id", .{ .number = @floatFromInt(rec.id) });
    try o.setAttr(a, "id", .{ .writable = false, .enumerable = false, .configurable = true });
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
    if (self.new_target == .undefined) return self.throwError("TypeError", "Constructor Thread requires 'new'");
    const native = self.active_native orelse return self.throwError("TypeError", "Thread constructor lost its context");
    const ctx: *Context = @ptrCast(@alignCast(native.private_data.?));
    const g = ctx.gil orelse return self.throwError("TypeError", "Thread requires an enable_threads Context");

    const fn_v = if (args.len > 0) args[0] else Value.undefined;
    if (!fn_v.isCallable())
        return self.throwError("TypeError", "Thread requires a callable function");

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
    // global object, and shapes (safe under the GIL) — but its own microtask
    // queue and async-waiter list, per the PR-249 rule that each thread
    // drains its own jobs before its join settles.
    var microtasks: std.ArrayListUnmanaged(@import("promise.zig").Microtask) = .empty;
    var async_waiters: std.ArrayListUnmanaged(interp.AsyncWaiterEntry) = .empty;
    var machine = rec.ctx.interpreter();
    machine.microtasks = &microtasks;
    machine.async_waiters = &async_waiters;
    if (machine.callValueWithThis(fn_v, args, .undefined)) |out| {
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        rec.result = out;
    } else |_| {
        machine.drainMicrotasks() catch {};
        rec.threw = true;
        rec.result = machine.exception;
    }
    rec.done = true;
    rec.done_cond.broadcast(agent.engineIo());
}

/// `Thread.prototype.join()` — park (GIL released) until the thread's fn has
/// returned and its queues drained; return its value or rethrow its
/// exception object.
fn threadJoinFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recordOf(self, this) orelse return self.throwError("TypeError", "Thread.prototype.join called on a non-Thread");
    while (!rec.done) rec.gil.wait(&rec.done_cond);
    if (rec.threw) {
        self.exception = rec.result;
        return error.Throw;
    }
    return rec.result;
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
    cond: std.Io.Condition = .init,
};

const CondRecord = struct {
    gil: *gil_mod.Gil,
    cond: std.Io.Condition = .init,
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
    try installCtor(ctx, "Lock", lockCtorFn, lock_proto);

    const cond_proto = try a.create(value.Object);
    cond_proto.* = .{};
    try interp.setNative(a, rs, cond_proto, "wait", 1, condWaitFn);
    try interp.setNative(a, rs, cond_proto, "notify", 0, condNotifyFn(false));
    try interp.setNative(a, rs, cond_proto, "notifyAll", 0, condNotifyFn(true));
    try installCtor(ctx, "Condition", condCtorFn, cond_proto);

    const tl_proto = try a.create(value.Object);
    tl_proto.* = .{};
    const getter = try a.create(value.Object);
    getter.* = .{ .native = tlValueGetFn };
    const setter = try a.create(value.Object);
    setter.* = .{ .native = tlValueSetFn };
    try tl_proto.setAccessor(a, "value", .{ .object = getter }, .{ .object = setter });
    try tl_proto.setAttr(a, "value", .{ .enumerable = false, .configurable = true });
    try installCtor(ctx, "ThreadLocal", tlCtorFn, tl_proto);
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
fn syncCtor(comptime T: type) value.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = this;
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
            if (self.new_target == .undefined) return self.throwError("TypeError", "Constructor requires 'new'");
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

const lockCtorFn = syncCtor(LockRecord);
const condCtorFn = syncCtor(CondRecord);
const tlCtorFn = syncCtor(TLRecord);

fn recOf(comptime T: type, this: Value) ?*T {
    if (this != .object) return null;
    const pd = this.object.private_data orelse return null;
    return @ptrCast(@alignCast(pd));
}

/// `Lock.prototype.hold(fn)` — acquire (parking GIL-released while
/// contended), run fn, release even when fn throws.
fn lockHoldFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(LockRecord, this) orelse return self.throwError("TypeError", "Lock.prototype.hold called on a non-Lock");
    const cb = if (args.len > 0) args[0] else Value.undefined;
    if (!cb.isCallable()) return self.throwError("TypeError", "Lock.hold requires a callable");
    while (rec.locked) rec.gil.wait(&rec.cond);
    rec.locked = true;
    const out = self.callValueWithThis(cb, &.{}, .undefined);
    rec.locked = false;
    rec.cond.signal(agent.engineIo());
    return out;
}

/// `Condition.prototype.wait(lock)` — atomically release the lock and park;
/// reacquire before returning. Spurious wakeups are permitted by spec, so
/// callers loop on their predicate.
fn condWaitFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.wait called on a non-Condition");
    const lock = recOf(LockRecord, if (args.len > 0) args[0] else .undefined) orelse
        return self.throwError("TypeError", "Condition.wait requires a Lock");
    if (!lock.locked) return self.throwError("TypeError", "Condition.wait: the lock is not held");
    // Atomic under the GIL: nothing else runs between the release below and
    // our park inside gil.wait (which registers before unlocking).
    lock.locked = false;
    lock.cond.signal(agent.engineIo());
    rec.gil.wait(&rec.cond);
    while (lock.locked) rec.gil.wait(&lock.cond);
    lock.locked = true;
    return .undefined;
}

fn condNotifyFn(comptime all: bool) value.NativeFn {
    return struct {
        fn call(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
            const rec = recOf(CondRecord, this) orelse return self.throwError("TypeError", "Condition.prototype.notify called on a non-Condition");
            if (all) rec.cond.broadcast(agent.engineIo()) else rec.cond.signal(agent.engineIo());
            return .undefined;
        }
    }.call;
}

fn tlValueGetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.value read on a non-ThreadLocal");
    return rec.map.get(currentTid()) orelse .undefined;
}

fn tlValueSetFn(ctx_ptr: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx_ptr));
    const rec = recOf(TLRecord, this) orelse return self.throwError("TypeError", "ThreadLocal.value set on a non-ThreadLocal");
    const v = if (args.len > 0) args[0] else Value.undefined;
    try rec.map.put(rec.arena, currentTid(), v);
    return .undefined;
}
