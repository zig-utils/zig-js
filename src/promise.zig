//! Promises + the microtask queue for zig-js.
//!
//! A `Promise` is a `value.Object` whose `promise` field points at a `Promise`
//! state record (pending/fulfilled/rejected + recorded reactions). Settling a
//! promise enqueues a `Reaction` job per recorded reaction onto the Context's
//! microtask queue, which `Context.evaluate` drains after the main script (and
//! which `await` drains inline until the awaited promise settles — the
//! synchronous-settling model: faithful for values, not for exact ordering).
//!
//! Operates on a type-erased `*Interpreter` (the same cycle-break the VM and
//! generators use); the interpreter casts back when dispatching.

const std = @import("std");
const gc_runtime = @import("gc_runtime.zig");
const gc_mod = @import("gc.zig");
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

pub const Promise = struct {
    lock: std.atomic.Mutex = .unlocked,
    state: State = .pending,
    value: Value = Value.undef(),
    /// Reaction list buffers are owned by the GC backing allocator when this
    /// promise cell is GC-owned; arena contexts keep the legacy arena path.
    gc_owned: bool = false,
    /// The overwhelmingly common pending-promise shape has one fulfill and one
    /// reject reaction. Keep that pair inline and allocate overflow lists only
    /// when more reactions are registered.
    on_fulfill_inline: ?Reaction = null,
    on_reject_inline: ?Reaction = null,
    on_fulfill: std.ArrayListUnmanaged(Reaction) = .empty,
    on_reject: std.ArrayListUnmanaged(Reaction) = .empty,

    pub fn lockState(self: *Promise) void {
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
        gc_runtime.enterTraceSensitiveLock();
    }

    pub fn unlockState(self: *Promise) void {
        gc_runtime.leaveTraceSensitiveLock();
        self.lock.unlock();
    }
};

/// A queued reaction job: run `reaction.handler(argument)` and settle
/// `reaction.result` accordingly (a pass-through when `handler` is null).
pub const Microtask = struct {
    kind: enum { reaction, thenable, callback } = .reaction,
    reaction: Reaction,
    argument: Value,
    fulfilled: bool, // whether the source settled fulfilled (vs rejected)
    thenable: Value = Value.undef(),
    then_fn: Value = Value.undef(),
    promise: ?*Promise = null,
    /// `.callback` jobs (HTML queueMicrotask): the function to invoke with no
    /// arguments. Settles no promise; a throw propagates as a reported exception.
    callback: Value = Value.undef(),
};

pub const MicrotaskQueue = struct {
    items: std.ArrayListUnmanaged(Microtask) = .empty,
    head: usize = 0,
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
        self.items.appendAssumeCapacity(task);
        _ = self.generation.fetchAdd(1, .release);
    }

    pub fn appendPendingSlice(self: *MicrotaskQueue, a: std.mem.Allocator, other: *MicrotaskQueue) !void {
        const pending = other.pendingItems();
        try self.reserve(a, pending.len);
        self.items.appendSliceAssumeCapacity(pending);
        if (pending.len > 0) _ = self.generation.fetchAdd(@intCast(pending.len), .release);
    }

    fn reserve(self: *MicrotaskQueue, a: std.mem.Allocator, additional: usize) !void {
        if (additional == 0) return;
        const spare = self.items.capacity - self.items.items.len;
        if (spare >= additional) return;
        const extra = @max(additional, microtask_queue_reserve_granularity);
        promise_profile.recordMicrotaskQueueGrow();
        try self.items.ensureTotalCapacity(a, self.items.items.len + extra);
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
    try q.appendPendingSlice(a, &source);
    try std.testing.expectEqual(@as(u64, 5), q.enqueueGeneration());
    try std.testing.expectEqual(@as(usize, 1), q.pendingLen());
    try std.testing.expectEqual(@as(f64, 6), q.pop().?.argument.asNum());
}

test "MicrotaskQueue lock is trace-sensitive" {
    var q = MicrotaskQueue{};

    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    q.acquire();
    defer q.release();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
}

test "Promise reactions keep first entry inline then reserve overflow chunks" {
    const a = std.testing.allocator;
    var live: usize = 0;
    var machine = Interpreter{
        .arena = a,
        .env = undefined,
        .root_shape = undefined,
        .gc_backing = a,
        .gc_promise_reactions_live = &live,
    };
    var p = Promise{ .gc_owned = true };
    defer p.on_fulfill.deinit(reactionAllocator(&machine));

    const reaction = Reaction{
        .handler = null,
        .resolve = Value.undef(),
        .reject = Value.undef(),
    };
    try appendReactionUnlocked(&machine, &p, &p.on_fulfill_inline, &p.on_fulfill, reaction);
    try std.testing.expect(p.on_fulfill_inline != null);
    try std.testing.expectEqual(@as(usize, 0), p.on_fulfill.capacity);
    try std.testing.expectEqual(@as(usize, 1), live);

    try appendReactionUnlocked(&machine, &p, &p.on_fulfill_inline, &p.on_fulfill, reaction);
    try std.testing.expect(p.on_fulfill.capacity >= reaction_list_reserve_granularity);
    try std.testing.expectEqual(@as(usize, 1), p.on_fulfill.items.len);
    try std.testing.expectEqual(@as(usize, 2), live);

    const first_capacity = p.on_fulfill.capacity;
    while (p.on_fulfill.items.len < first_capacity) {
        try appendReactionUnlocked(&machine, &p, &p.on_fulfill_inline, &p.on_fulfill, reaction);
    }
    try std.testing.expectEqual(first_capacity, p.on_fulfill.items.len);
    try std.testing.expectEqual(first_capacity, p.on_fulfill.capacity);
    try std.testing.expectEqual(first_capacity + 1, live);

    try appendReactionUnlocked(&machine, &p, &p.on_fulfill_inline, &p.on_fulfill, reaction);
    try std.testing.expectEqual(first_capacity + 1, p.on_fulfill.items.len);
    try std.testing.expect(p.on_fulfill.capacity > first_capacity);
    try std.testing.expectEqual(first_capacity + 2, live);

    popReactionUnlocked(&machine, &p, &p.on_fulfill_inline, &p.on_fulfill);
    try std.testing.expectEqual(first_capacity, p.on_fulfill.items.len);
    try std.testing.expectEqual(first_capacity + 1, live);
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
    const state = resolvingStateObject(fnobj) orelse return Value.undef();
    const target = resolvingTarget(state) orelse return Value.undef();
    if (state.promise_resolving_already) return Value.undef();
    state.promise_resolving_already = true;
    try resolve(self, target, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

fn rejectThunk(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return Value.undef();
    const state = resolvingStateObject(fnobj) orelse return Value.undef();
    const target = resolvingTarget(state) orelse return Value.undef();
    if (state.promise_resolving_already) return Value.undef();
    state.promise_resolving_already = true;
    try reject(self, target, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

pub fn promiseOf(v: Value) ?*Promise {
    if (v.isObject()) {
        if (v.asObj().promise) |p| return @ptrCast(@alignCast(p));
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

/// Allocate a fresh pending Promise object (proto = `Promise.prototype`).
pub fn newPromise(self: *Interpreter) EvalError!*Object {
    const p = try gc_mod.allocPromise(self.arena);
    promise_profile.recordPromiseStateCell();
    p.* = .{ .gc_owned = gc_mod.allocationsAreManaged() };
    const obj = try gc_mod.allocObj(self.arena);
    promise_profile.recordPromiseWrapperObject();
    obj.* = .{ .promise = @ptrCast(p) };
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
    const p: *Promise = @ptrCast(@alignCast(obj.promise.?));
    p.state = state;
    gc_mod.barrierValueFrom(p, v);
    p.value = v;
    return obj;
}

inline fn reactionAllocator(self: *Interpreter) std.mem.Allocator {
    return self.gc_backing orelse self.arena;
}

fn noteReactionAdded(self: *Interpreter, p: *Promise) void {
    if (!p.gc_owned) return;
    if (self.gc_promise_reactions_live) |live| _ = @atomicRmw(usize, live, .Add, 1, .monotonic);
}

fn noteReactionsRemoved(self: *Interpreter, p: *Promise, count: usize) void {
    if (!p.gc_owned or count == 0) return;
    if (self.gc_promise_reactions_live) |live| {
        _ = @atomicRmw(usize, live, .Sub, count, .monotonic);
    }
}

fn reserveReactionListUnlocked(self: *Interpreter, list: *std.ArrayListUnmanaged(Reaction), additional: usize) EvalError!void {
    if (additional == 0) return;
    const spare = list.capacity - list.items.len;
    if (spare >= additional) return;
    const extra = @max(additional, reaction_list_reserve_granularity);
    promise_profile.recordReactionListGrow();
    try list.ensureTotalCapacity(reactionAllocator(self), list.items.len + extra);
}

fn appendReactionUnlocked(
    self: *Interpreter,
    p: *Promise,
    inline_slot: *?Reaction,
    list: *std.ArrayListUnmanaged(Reaction),
    r: Reaction,
) EvalError!void {
    // Incremental-GC barrier: the reaction's callbacks are stored into the live
    // promise cell (which may already be marked black). Shade them.
    if (r.handler) |h| gc_mod.barrierValueFrom(p, h);
    if (r.result) |result| {
        gc_mod.barrierCellFrom(p, @ptrCast(result));
    } else {
        gc_mod.barrierValueFrom(p, r.resolve);
        gc_mod.barrierValueFrom(p, r.reject);
    }
    if (inline_slot.* == null) {
        inline_slot.* = r;
        noteReactionAdded(self, p);
        return;
    }
    try reserveReactionListUnlocked(self, list, 1);
    list.appendAssumeCapacity(r);
    noteReactionAdded(self, p);
}

fn popReactionUnlocked(self: *Interpreter, p: *Promise, inline_slot: *?Reaction, list: *std.ArrayListUnmanaged(Reaction)) void {
    if (list.items.len > 0) {
        _ = list.pop();
    } else {
        inline_slot.* = null;
    }
    noteReactionsRemoved(self, p, 1);
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

fn disposeMovedReactions(self: *Interpreter, p: *Promise, fulfill: *std.ArrayListUnmanaged(Reaction), reject_list: *std.ArrayListUnmanaged(Reaction), count: usize) void {
    if (p.gc_owned) {
        const a = reactionAllocator(self);
        fulfill.deinit(a);
        reject_list.deinit(a);
    }
    noteReactionsRemoved(self, p, count);
}

fn settle(self: *Interpreter, p: *Promise, state: State, v: Value) EvalError!void {
    std.debug.assert(state != .pending);

    var fulfill: std.ArrayListUnmanaged(Reaction) = .empty;
    var reject_list: std.ArrayListUnmanaged(Reaction) = .empty;
    var fulfill_inline: ?Reaction = null;
    var reject_inline: ?Reaction = null;
    var removed_count: usize = 0;

    p.lockState();
    if (p.state != .pending) {
        p.unlockState();
        return;
    }
    p.state = state;
    gc_mod.barrierValueFrom(p, v); // settlement value stored into the live promise cell
    p.value = v;
    fulfill_inline = p.on_fulfill_inline;
    reject_inline = p.on_reject_inline;
    fulfill = p.on_fulfill;
    reject_list = p.on_reject;
    removed_count = fulfill.items.len + reject_list.items.len +
        @intFromBool(fulfill_inline != null) + @intFromBool(reject_inline != null);
    p.unlockState();

    errdefer {
        p.lockState();
        p.on_fulfill_inline = null;
        p.on_reject_inline = null;
        p.on_fulfill = .empty;
        p.on_reject = .empty;
        p.unlockState();
        disposeMovedReactions(self, p, &fulfill, &reject_list, removed_count);
    }
    const selected_inline = if (state == .fulfilled) fulfill_inline else reject_inline;
    const selected = if (state == .fulfilled) fulfill.items else reject_list.items;
    if (selected_inline) |r| try enqueue(self, .{ .reaction = r, .argument = v, .fulfilled = state == .fulfilled });
    for (selected) |r| try enqueue(self, .{ .reaction = r, .argument = v, .fulfilled = state == .fulfilled });
    p.lockState();
    p.on_fulfill_inline = null;
    p.on_reject_inline = null;
    p.on_fulfill = .empty;
    p.on_reject = .empty;
    p.unlockState();
    disposeMovedReactions(self, p, &fulfill, &reject_list, removed_count);
}

/// Fulfill `p` with `v` (no-op if already settled). If `v` is itself a thenable,
/// adopt its state instead (resolution).
pub fn resolve(self: *Interpreter, p: *Promise, v: Value) EvalError!void {
    if (!isPending(p)) return;
    if (promiseOf(v)) |inner| if (inner == p) {
        const err = try self.makeError("TypeError", "Cannot resolve promise with itself");
        try reject(self, p, err);
        return;
    };
    // Thenable assimilation: `then` is read synchronously from every object
    // resolution (including native promises and arrays), then invoked from the
    // queued PromiseResolveThenableJob.
    if (v.isObject()) {
        const then_fn = self.getProperty(v, "then") catch |err| {
            if (err == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                try reject(self, p, reason);
                return;
            }
            return err;
        };
        if (then_fn.isCallable()) {
            try enqueue(self, .{
                .kind = .thenable,
                .reaction = undefined,
                .argument = Value.undef(),
                .fulfilled = true,
                .thenable = v,
                .then_fn = then_fn,
                .promise = p,
            });
            return;
        }
    }
    try settle(self, p, .fulfilled, v);
}

/// Reject `p` with `reason` (no-op if already settled).
pub fn reject(self: *Interpreter, p: *Promise, reason: Value) EvalError!void {
    try settle(self, p, .rejected, reason);
}

/// `p.then(onFulfilled, onRejected)` → a new promise settled by running the
/// matching handler when `p` settles (pass-through if the handler is absent).
/// Native resolve/reject closures over `p`'s state (a capability whose promise
/// is the native `p`). Used wherever the result is an intrinsic promise.
pub fn nativeResolveReject(self: *Interpreter, p: *Promise) EvalError!struct { resolve: Value, reject: Value } {
    promise_profile.recordResolvingFunctionPair();
    const res = try gc_mod.allocObj(self.arena);
    promise_profile.recordResolvingFunctionObject();
    res.* = .{ .native = resolveThunk, .private_data = @ptrCast(p) };
    try interp.installNativeProps(self.arena, self.root_shape, res, "", 1);
    const rej = try gc_mod.allocObj(self.arena);
    promise_profile.recordResolvingFunctionObject();
    rej.* = .{ .native = rejectThunk, .private_data = @ptrCast(res) };
    try interp.installNativeProps(self.arena, self.root_shape, rej, "", 1);
    return .{ .resolve = Value.obj(res), .reject = Value.obj(rej) };
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
}

pub fn then(self: *Interpreter, p: *Promise, on_f: Value, on_r: Value) EvalError!Value {
    const result = try newPromise(self);
    const rp: *Promise = @ptrCast(@alignCast(result.promise.?));
    try performThenResult(self, p, on_f, on_r, rp);
    return Value.obj(result);
}

fn performThenReactions(self: *Interpreter, p: *Promise, react_f: Reaction, react_r: Reaction) EvalError!void {
    p.lockState();
    errdefer p.unlockState();
    const snap = .{ .state = p.state, .value = p.value };
    switch (snap.state) {
        .pending => {
            try appendReactionUnlocked(self, p, &p.on_fulfill_inline, &p.on_fulfill, react_f);
            errdefer popReactionUnlocked(self, p, &p.on_fulfill_inline, &p.on_fulfill);
            try appendReactionUnlocked(self, p, &p.on_reject_inline, &p.on_reject, react_r);
            p.unlockState();
            return;
        },
        .fulfilled, .rejected => {},
    }
    p.unlockState();

    switch (snap.state) {
        .pending => unreachable,
        .fulfilled => try enqueue(self, .{ .reaction = react_f, .argument = snap.value, .fulfilled = true }),
        .rejected => try enqueue(self, .{ .reaction = react_r, .argument = snap.value, .fulfilled = false }),
    }
}

/// Queue a bare callback microtask (HTML `queueMicrotask`). Runs on the same
/// checkpoint as Promise reactions, in FIFO order relative to them.
pub fn enqueueCallback(self: *Interpreter, callback: Value) EvalError!void {
    try enqueue(self, .{ .kind = .callback, .reaction = undefined, .argument = Value.undef(), .fulfilled = true, .callback = callback });
}

fn enqueue(self: *Interpreter, task: Microtask) EvalError!void {
    const q = self.microtasks orelse return; // no queue wired → drop (shouldn't happen)
    // Under `parallel_js` a peer thread may drain this queue concurrently; the
    // lock makes the append atomic against the drain's pop. A no-op (single null
    // check) on the GIL-serialized default path.
    self.lockMicrotasks();
    defer self.unlockMicrotasks();
    try q.append(self.arena, task);
    promise_profile.recordMicrotaskEnqueue(task.kind == .thenable);
}

/// Run one reaction job: invoke the handler (or pass through) and settle the
/// dependent promise. A handler that throws rejects the dependent promise.
fn settleReaction(self: *Interpreter, r: Reaction, fulfilled: bool, arg: Value) EvalError!void {
    if (r.result) |result| {
        if (fulfilled) try resolve(self, result, arg) else try reject(self, result, arg);
        return;
    }
    if (fulfilled) _ = try self.callValue(r.resolve, &.{arg}) else _ = try self.callValue(r.reject, &.{arg});
}

pub fn runJob(self: *Interpreter, task: Microtask) EvalError!void {
    if (task.kind == .callback) {
        promise_profile.recordMicrotaskRun(false);
        _ = try self.callValueWithThis(task.callback, &.{}, Value.undef());
        return;
    }
    if (task.kind == .thenable) {
        promise_profile.recordMicrotaskRun(true);
        const p = task.promise orelse return;
        if (!isPending(p)) return;
        const nr = try nativeResolveReject(self, p);
        if (self.callValueWithThis(task.then_fn, &.{ nr.resolve, nr.reject }, task.thenable)) |_| {} else |err| {
            if (err == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                _ = try self.callValue(nr.reject, &.{reason});
            } else return err;
        }
        return;
    }
    promise_profile.recordMicrotaskRun(false);
    const r = task.reaction;
    if (r.handler) |h| {
        if (self.callValueWithThis(h, &.{task.argument}, Value.undef())) |res| {
            try settleReaction(self, r, true, res);
        } else |err| {
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
