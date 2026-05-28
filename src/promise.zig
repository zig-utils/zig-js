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
const value = @import("value.zig");
const interp = @import("interpreter.zig");

const Value = value.Value;
const Object = value.Object;
const Interpreter = interp.Interpreter;
const EvalError = interp.EvalError;

pub const State = enum { pending, fulfilled, rejected };

/// A `.then` reaction: when the source promise settles, `handler` (the
/// onFulfilled/onRejected callback, or null for pass-through) is run and its
/// outcome resolves/rejects `result` (the promise `.then` returned).
pub const Reaction = struct {
    handler: ?Value,
    result: *Promise,
};

pub const Promise = struct {
    state: State = .pending,
    value: Value = .undefined,
    on_fulfill: std.ArrayListUnmanaged(Reaction) = .empty,
    on_reject: std.ArrayListUnmanaged(Reaction) = .empty,
    /// Guards the executor's resolve/reject so only the first call wins.
    resolved: bool = false,
};

/// A queued reaction job: run `reaction.handler(argument)` and settle
/// `reaction.result` accordingly (a pass-through when `handler` is null).
pub const Microtask = struct {
    reaction: Reaction,
    argument: Value,
    fulfilled: bool, // whether the source settled fulfilled (vs rejected)
};

/// Shared aggregation state for the combinators (`Promise.all`/`allSettled`/
/// `any`). `result` is the combined promise; `values` the in-order results
/// array; `remaining` counts inputs not yet settled; `kind` selects how each
/// element's outcome is recorded.
pub const Combine = struct {
    result: *Promise,
    values: *Object,
    remaining: usize,
    kind: enum { all, all_settled, any },
};

/// A per-element reaction's captured context: which `Combine` it belongs to and
/// the element's index (so results land in order). Stored on the closure's
/// `private_data`.
pub const Elem = struct {
    combine: *Combine,
    index: usize,
    is_reject: bool,
};

pub fn promiseOf(v: Value) ?*Promise {
    if (v == .object) {
        if (v.object.promise) |p| return @ptrCast(@alignCast(p));
    }
    return null;
}

/// Allocate a fresh pending Promise object (proto = `Promise.prototype`).
pub fn newPromise(self: *Interpreter) EvalError!*Object {
    const p = try self.arena.create(Promise);
    p.* = .{};
    const obj = try self.arena.create(Object);
    obj.* = .{ .promise = @ptrCast(p) };
    if (self.env.get("Promise")) |ctor| {
        if (ctor == .object) obj.proto = try self.protoObject(ctor.object);
    }
    return obj;
}

/// Fulfill `p` with `v` (no-op if already settled). If `v` is itself a thenable,
/// adopt its state instead (resolution).
pub fn resolve(self: *Interpreter, p: *Promise, v: Value) EvalError!void {
    if (p.state != .pending) return;
    // Thenable assimilation: resolving with a promise/thenable chains to it.
    if (promiseOf(v)) |inner| {
        // `await`/`then` on the inner: when it settles, settle `p`.
        const reaction_f = Reaction{ .handler = null, .result = p };
        const reaction_r = Reaction{ .handler = null, .result = p };
        switch (inner.state) {
            .pending => {
                try inner.on_fulfill.append(self.arena, reaction_f);
                try inner.on_reject.append(self.arena, reaction_r);
            },
            .fulfilled => try enqueue(self, .{ .reaction = reaction_f, .argument = inner.value, .fulfilled = true }),
            .rejected => try enqueue(self, .{ .reaction = reaction_r, .argument = inner.value, .fulfilled = false }),
        }
        return;
    }
    p.state = .fulfilled;
    p.value = v;
    for (p.on_fulfill.items) |r| try enqueue(self, .{ .reaction = r, .argument = v, .fulfilled = true });
    p.on_fulfill.clearRetainingCapacity();
    p.on_reject.clearRetainingCapacity();
}

/// Reject `p` with `reason` (no-op if already settled).
pub fn reject(self: *Interpreter, p: *Promise, reason: Value) EvalError!void {
    if (p.state != .pending) return;
    p.state = .rejected;
    p.value = reason;
    for (p.on_reject.items) |r| try enqueue(self, .{ .reaction = r, .argument = reason, .fulfilled = false });
    p.on_fulfill.clearRetainingCapacity();
    p.on_reject.clearRetainingCapacity();
}

/// `p.then(onFulfilled, onRejected)` → a new promise settled by running the
/// matching handler when `p` settles (pass-through if the handler is absent).
pub fn then(self: *Interpreter, p: *Promise, on_f: Value, on_r: Value) EvalError!Value {
    const result = try newPromise(self);
    const rp: *Promise = @ptrCast(@alignCast(result.promise.?));
    const fh: ?Value = if (on_f.isCallable()) on_f else null;
    const rh: ?Value = if (on_r.isCallable()) on_r else null;
    const react_f = Reaction{ .handler = fh, .result = rp };
    const react_r = Reaction{ .handler = rh, .result = rp };
    switch (p.state) {
        .pending => {
            try p.on_fulfill.append(self.arena, react_f);
            try p.on_reject.append(self.arena, react_r);
        },
        .fulfilled => try enqueue(self, .{ .reaction = react_f, .argument = p.value, .fulfilled = true }),
        .rejected => try enqueue(self, .{ .reaction = react_r, .argument = p.value, .fulfilled = false }),
    }
    return .{ .object = result };
}

fn enqueue(self: *Interpreter, task: Microtask) EvalError!void {
    const q = self.microtasks orelse return; // no queue wired → drop (shouldn't happen)
    try q.append(self.arena, task);
}

/// Run one reaction job: invoke the handler (or pass through) and settle the
/// dependent promise. A handler that throws rejects the dependent promise.
pub fn runJob(self: *Interpreter, task: Microtask) EvalError!void {
    const r = task.reaction;
    if (r.handler) |h| {
        if (self.callValueWithThis(h, &.{task.argument}, .undefined)) |res| {
            try resolve(self, r.result, res);
        } else |err| {
            if (err == error.Throw) {
                const reason = self.exception;
                self.exception = .undefined;
                try reject(self, r.result, reason);
            } else return err;
        }
    } else {
        // Pass-through: a fulfill reaction with no handler forwards the value;
        // a reject reaction with no handler forwards the rejection.
        if (task.fulfilled) try resolve(self, r.result, task.argument) else try reject(self, r.result, task.argument);
    }
}
