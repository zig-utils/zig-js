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
const io_compat = @import("io_compat.zig");
const gc_mod = @import("gc.zig");
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
            io_compat.conditionWaitTimeout(&ch.cond, io, &ch.mutex, tmo) catch |err| switch (err) {
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

/// A module-graph entry point for a module worker. The host's `load`
/// callback runs on the worker thread, so it must be thread-safe (an
/// embedder-owned static module map is the canonical pattern); the source
/// strings it returns need only be valid for the duration of the call (they
/// are duped into the worker realm's arena). `entry_path`/`entry_source` are
/// owned by the worker.
const ModuleConfig = struct {
    entry_path: []const u8,
    entry_source: []const u8,
    host: ContextMod.Context.ModuleHost,
};

/// Embedder integration hook: a host with its own event loop sets this so it
/// is woken when the worker has main-side work pending (a queued message, or
/// the worker closing its outbox). `notify` may fire from the worker thread,
/// so it must be thread-safe and non-blocking — schedule a `receive` drain on
/// the worker's owning thread rather than draining inline.
pub const HostHooks = struct {
    ctx: *anyopaque,
    notify: *const fn (ctx: *anyopaque) void,
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
    /// When set, the worker evaluates a module graph instead of `src`.
    module: ?ModuleConfig = null,
    /// Optional embedder wake hook, loaded atomically (the worker thread reads
    /// it; the owning thread may install it after spawn). Pointer is owned by
    /// the embedder and must outlive the worker.
    hooks: std.atomic.Value(?*const HostHooks) = .init(null),

    /// Install (or clear) the embedder wake hook. The embedder should call
    /// this immediately after spawn and perform one initial `receive` drain,
    /// since a message posted before the hook lands fires no wake.
    pub fn setHostHooks(w: *Worker, hooks: ?*const HostHooks) void {
        w.hooks.store(hooks, .release);
    }

    fn notifyHost(w: *Worker) void {
        if (w.hooks.load(.acquire)) |h| h.notify(h.ctx);
    }

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

    /// Spawn a *module* worker: the realm evaluates the module graph rooted at
    /// `entry_path`/`entry_source`, resolving imports through `host` (whose
    /// `load` callback is invoked on the worker thread — it must be
    /// thread-safe). Module top-level code installs `globalThis.onmessage`,
    /// then the delivery loop runs as for a script worker.
    pub fn spawnModule(
        entry_path: []const u8,
        entry_source: []const u8,
        host: ContextMod.Context.ModuleHost,
    ) error{OutOfMemory}!*Worker {
        const w = try alloc.create(Worker);
        errdefer alloc.destroy(w);
        const path_copy = try alloc.dupe(u8, entry_path);
        errdefer alloc.free(path_copy);
        const src_copy = try alloc.dupe(u8, entry_source);
        errdefer alloc.free(src_copy);
        w.* = .{
            .src = &.{},
            .module = .{ .entry_path = path_copy, .entry_source = src_copy, .host = host },
        };
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

    /// Graceful shutdown: close the inbox so the delivery loop drains any
    /// remaining messages and exits, without the stop-flag interrupt that
    /// `terminate` injects into in-flight JS.
    pub fn close(w: *Worker) void {
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
        if (w.module) |mc| {
            alloc.free(mc.entry_path);
            alloc.free(mc.entry_source);
        } else {
            alloc.free(w.src);
        }
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

    if (w.module) |mc| {
        _ = ctx.evaluateModule(mc.entry_path, mc.entry_source, mc.host) catch {};
    } else {
        _ = ctx.evaluate(w.src) catch {};
    }

    // Delivery loop: park on the inbox, hand each message to onmessage.
    while (!w.stop.load(.monotonic)) {
        const bytes = w.inbox.pop(null) orelse break; // closed + drained
        defer alloc.free(bytes);
        var machine = ctx.interpreter();
        const data = structured_clone.deserialize(&machine, bytes) catch continue;
        const handler = machine.getProperty(Value.obj(ctx.global_object), "onmessage") catch continue;
        if (!handler.isObject()) continue;
        const event = machine.newObject() catch continue;
        machine.setProp(event.asObj(), "data", data) catch continue;
        _ = machine.callValueWithThis(handler, &.{event}, Value.undef()) catch {};
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
    }
    w.outbox.close();
    w.notifyHost(); // wake the embedder so its final `receive` sees the close
}

/// Worker-realm globals: `postMessage(value)` and `close()`. Each native
/// reaches its Worker through the function object's `private_data`.
fn installWorkerGlobals(ctx: *Context, w: *Worker) !void {
    const a = ctx.arena();
    inline for (.{
        .{ "postMessage", workerPostMessageFn },
        .{ "close", workerCloseFn },
    }) |entry| {
        const o = try gc_mod.allocObj(a);
        o.* = .{ .native = entry[1], .private_data = w };
        try ctx.env.put(entry[0], Value.obj(o));
        try ctx.global_object.setOwn(a, ctx.root_shape, entry[0], Value.obj(o));
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
    const w = workerOf(self) orelse return Value.undef();
    const v = if (args.len > 0) args[0] else Value.undef();
    const bytes = try structured_clone.serialize(self, alloc, v);
    w.outbox.push(bytes);
    w.notifyHost(); // wake the embedder's loop to drain via `receive`
    return Value.undef();
}

fn workerCloseFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *interp.Interpreter = @ptrCast(@alignCast(ctx));
    const w = workerOf(self) orelse return Value.undef();
    w.inbox.close(); // delivery loop drains the remaining messages, then exits
    return Value.undef();
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
        try std.testing.expect(done.isBoolean() and done.asBool());
    }
    for (workers) |w| {
        w.join();
        w.destroy();
    }
    // Every worker's Atomics.add landed in the one shared storage.
    const count = try ctx.evaluate("new Int32Array(globalThis.__msg.sab)[0]");
    try std.testing.expectEqual(@as(f64, 4), count.asNum());

    // Terminate a worker stuck in an infinite loop: the stop word fires at a
    // step checkpoint and the thread joins.
    const spinner = try Worker.spawn("for (;;) {}");
    spinner.terminate();
    spinner.join();
    spinner.destroy();
}

// A static, read-only module map shared with module workers. Read-only after
// construction, so the `load` callback is trivially thread-safe.
const StaticModules = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "helper.js",
            .source = "export const bump = (sab) => Atomics.add(new Int32Array(sab), 0, 1);",
        },
        .{
            .path = "entry.js",
            .source =
            \\import { bump } from "./helper.js";
            \\globalThis.onmessage = (e) => {
            \\  bump(e.data.sab);
            \\  postMessage({ done: true });
            \\  close();
            \\};
            ,
        },
    };

    fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        // Strip a leading "./" so "./helper.js" matches "helper.js".
        const name = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
        for (entries) |e| {
            if (std.mem.eql(u8, e.path, name)) {
                out_path.* = e.path;
                return e.source;
            }
        }
        return null;
    }

    fn host() ContextMod.Context.ModuleHost {
        return .{ .ctx = &host_ctx, .load = load };
    }
};

// An embedder loop integration: the wake hook bumps a counter the owning
// thread can poll instead of blocking in `receive`.
const HookSink = struct {
    woken: std.atomic.Value(u32) = .init(0),
    fn notify(ctx: *anyopaque) void {
        const self: *HookSink = @ptrCast(@alignCast(ctx));
        _ = self.woken.fetchAdd(1, .acq_rel);
    }
};

test "workers: host hook wakes on message and on outbox close" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();

    var sink = HookSink{};
    var hooks = HostHooks{ .ctx = &sink, .notify = HookSink.notify };

    const w = try Worker.spawn(
        \\globalThis.onmessage = (e) => { postMessage(e.data * 2); close(); };
    );
    w.setHostHooks(&hooks);
    try w.postMessage(&machine, Value.num(21));

    // The worker fires the hook for the reply message and again at outbox close.
    const reply = (try w.receive(&machine, 10_000)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 42), reply.asNum());
    w.join();
    w.destroy();
    try std.testing.expect(sink.woken.load(.acquire) >= 1);
}

test "workers: module-graph worker resolves imports and round-trips a message" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg = try ctx.evaluate(
        \\globalThis.__msg = { sab: new SharedArrayBuffer(8) };
        \\globalThis.__msg
    );

    const w = try Worker.spawnModule("entry.js", StaticModules.entries[1].source, StaticModules.host());
    try w.postMessage(&machine, msg);
    const reply = (try w.receive(&machine, 10_000)) orelse return error.TestUnexpectedResult;
    const done = try machine.getProperty(reply, "done");
    try std.testing.expect(done.isBoolean() and done.asBool());
    w.join();
    w.destroy();

    // The imported `bump` ran against the shared storage.
    const count = try ctx.evaluate("new Int32Array(globalThis.__msg.sab)[0]");
    try std.testing.expectEqual(@as(f64, 1), count.asNum());
}
