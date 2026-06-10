//! Embedder-facing worker agents (Phase 5 of
//! https://github.com/zig-utils/zig-js/issues/1): one `Context` per OS
//! thread, message passing over the structured-clone byte stream (the
//! Phase-4 IR is exactly the `postMessage` wire format), cooperative
//! `terminate()` via the engines' step-checkpoint stop word, and `join`.
//!
//! Inside the worker realm the host installs `postMessage(value)` and
//! `close()`; after the worker script runs, a delivery loop parks on the
//! inbox and invokes `globalThis.onmessage({ data })` per message, draining
//! microtasks and async waiters between deliveries. Lifetime rules match the
//! agent module's: nothing from a worker arena crosses a boundary — only
//! serialized bytes (process-allocator-owned) and retained SAB storage.

const std = @import("std");
const value = @import("value.zig");
const interp = @import("interpreter.zig");
const ContextMod = @import("context.zig");
const structured_clone = @import("structured_clone.zig");
const agent = @import("agent.zig");

const Context = ContextMod.Context;
const Value = value.Value;
const alloc = std.heap.page_allocator;

/// A FIFO of serialized messages with blocking pop. Closing wakes every
/// waiter; remaining messages are still poppable (drain-then-stop), and
/// `deinit` releases whatever was never consumed (including any SAB storage
/// references inside).
const Channel = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    fn push(ch: *Channel, bytes: []u8) void {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        if (ch.closed) {
            structured_clone.releaseSerialized(bytes);
            alloc.free(bytes);
            return;
        }
        ch.queue.append(alloc, bytes) catch {
            structured_clone.releaseSerialized(bytes);
            alloc.free(bytes);
            return;
        };
        ch.cond.signal(io);
    }

    /// Next message (caller frees), or null when the channel is closed and
    /// drained, or `timeout_ms` elapsed (null = wait indefinitely).
    fn pop(ch: *Channel, timeout_ms: ?u64) ?[]u8 {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        while (ch.queue.items.len == 0) {
            if (ch.closed) return null;
            const tmo: std.Io.Timeout = if (timeout_ms) |ms| .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(ms)),
                .clock = .awake,
            } } else .none;
            ch.cond.waitTimeout(io, &ch.mutex, tmo) catch |err| switch (err) {
                error.Timeout => if (ch.queue.items.len == 0) return null else break,
                error.Canceled => continue,
            };
        }
        return ch.queue.orderedRemove(0);
    }

    fn close(ch: *Channel) void {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        ch.closed = true;
        ch.cond.broadcast(io);
    }

    fn deinit(ch: *Channel) void {
        for (ch.queue.items) |bytes| {
            structured_clone.releaseSerialized(bytes);
            alloc.free(bytes);
        }
        ch.queue.deinit(alloc);
    }
};

pub const Worker = struct {
    thread: ?std.Thread = null,
    /// main → worker messages.
    inbox: Channel = .{},
    /// worker → main messages.
    outbox: Channel = .{},
    /// The stop word the worker context's step checkpoints poll.
    stop: std.atomic.Value(bool) = .init(false),
    src: []const u8,

    /// Spawn a worker running `src` in a fresh realm on its own thread. The
    /// returned worker must be `terminate`d or have its inbox closed, then
    /// `join`ed and `destroy`ed by the caller.
    pub fn spawn(src: []const u8) error{OutOfMemory}!*Worker {
        const w = try alloc.create(Worker);
        errdefer alloc.destroy(w);
        w.* = .{ .src = try alloc.dupe(u8, src) };
        errdefer alloc.free(w.src);
        w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch return error.OutOfMemory;
        return w;
    }

    /// Main-side send: serialize `v` from `from`'s realm into the inbox.
    pub fn postMessage(w: *Worker, from: *interp.Interpreter, v: Value) value.HostError!void {
        const bytes = try structured_clone.serialize(from, alloc, v);
        w.inbox.push(bytes);
    }

    /// Main-side receive: the next worker→main message, deserialized into
    /// `into`'s realm. Null when the worker closed its side or `timeout_ms`
    /// elapsed.
    pub fn receive(w: *Worker, into: *interp.Interpreter, timeout_ms: ?u64) value.HostError!?Value {
        const bytes = w.outbox.pop(timeout_ms) orelse return null;
        defer alloc.free(bytes);
        return try structured_clone.deserialize(into, bytes);
    }

    /// Request termination: the stop word makes running JS throw at the next
    /// step checkpoint, and the closed inbox ends the delivery loop.
    pub fn terminate(w: *Worker) void {
        w.stop.store(true, .monotonic);
        w.inbox.close();
    }

    pub fn join(w: *Worker) void {
        if (w.thread) |t| {
            t.join();
            w.thread = null;
        }
    }

    /// Free the worker (must be joined first).
    pub fn destroy(w: *Worker) void {
        std.debug.assert(w.thread == null);
        w.inbox.deinit();
        w.outbox.deinit();
        alloc.free(w.src);
        alloc.destroy(w);
    }
};

fn workerMain(w: *Worker) void {
    const ctx = Context.create(alloc) catch {
        w.outbox.close();
        return;
    };
    defer ctx.destroy();
    ctx.stop_flag = &w.stop;
    installWorkerGlobals(ctx, w) catch {
        w.outbox.close();
        return;
    };

    _ = ctx.evaluate(w.src) catch {};

    // Delivery loop: park on the inbox, hand each message to onmessage.
    while (!w.stop.load(.monotonic)) {
        const bytes = w.inbox.pop(null) orelse break; // closed + drained
        defer alloc.free(bytes);
        var machine = ctx.interpreter();
        const data = structured_clone.deserialize(&machine, bytes) catch continue;
        const handler = machine.getProperty(.{ .object = ctx.global_object }, "onmessage") catch continue;
        if (handler != .object) continue;
        const event = machine.newObject() catch continue;
        machine.setProp(event.object, "data", data) catch continue;
        _ = machine.callValueWithThis(handler, &.{event}, .undefined) catch {};
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
    }
    w.outbox.close();
}

/// Worker-realm globals: `postMessage(value)` and `close()`. Each native
/// reaches its Worker through the function object's `private_data`.
fn installWorkerGlobals(ctx: *Context, w: *Worker) !void {
    const a = ctx.arena();
    inline for (.{
        .{ "postMessage", workerPostMessageFn },
        .{ "close", workerCloseFn },
    }) |entry| {
        const o = try a.create(value.Object);
        o.* = .{ .native = entry[1], .private_data = w };
        try ctx.env.put(entry[0], .{ .object = o });
        try ctx.global_object.setOwn(a, ctx.root_shape, entry[0], .{ .object = o });
        try ctx.global_object.setAttr(a, entry[0], .{ .writable = true, .enumerable = false, .configurable = true });
    }
}

fn workerOf(self: *interp.Interpreter) ?*Worker {
    const native = self.active_native orelse return null;
    return @ptrCast(@alignCast(native.private_data orelse return null));
}

fn workerPostMessageFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *interp.Interpreter = @ptrCast(@alignCast(ctx));
    const w = workerOf(self) orelse return .undefined;
    const v = if (args.len > 0) args[0] else Value.undefined;
    const bytes = try structured_clone.serialize(self, alloc, v);
    w.outbox.push(bytes);
    return .undefined;
}

fn workerCloseFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *interp.Interpreter = @ptrCast(@alignCast(ctx));
    const w = workerOf(self) orelse return .undefined;
    w.inbox.close(); // delivery loop drains the remaining messages, then exits
    return .undefined;
}

test "workers: 4-way round trip, shared SAB counter, terminate mid-loop" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();

    // The shared message: a SAB every worker bumps, plus a tag.
    const msg = try ctx.evaluate(
        \\globalThis.__msg = { sab: new SharedArrayBuffer(8) };
        \\globalThis.__msg
    );

    const echo_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  Atomics.add(v, 0, 1);
        \\  postMessage({ done: true });
        \\  close();
        \\};
    ;
    var workers: [4]*Worker = undefined;
    for (&workers) |*slot| slot.* = try Worker.spawn(echo_src);
    for (workers) |w| try w.postMessage(&machine, msg);
    for (workers) |w| {
        const reply = (try w.receive(&machine, 10_000)) orelse return error.TestUnexpectedResult;
        const done = try machine.getProperty(reply, "done");
        try std.testing.expect(done == .boolean and done.boolean);
    }
    for (workers) |w| {
        w.join();
        w.destroy();
    }
    // Every worker's Atomics.add landed in the one shared storage.
    const count = try ctx.evaluate("new Int32Array(globalThis.__msg.sab)[0]");
    try std.testing.expectEqual(@as(f64, 4), count.number);

    // Terminate a worker stuck in an infinite loop: the stop word fires at a
    // step checkpoint and the thread joins.
    const spinner = try Worker.spawn("for (;;) {}");
    spinner.terminate();
    spinner.join();
    spinner.destroy();
}
