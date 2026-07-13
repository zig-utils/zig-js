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
const jsthread = @import("jsthread.zig");

const Context = ContextMod.Context;
const Value = value.Value;
const alloc = std.heap.page_allocator;
const channel_queue_reserve_granularity = 64;

pub const ChannelLimits = struct {
    max_message_bytes: usize = 64 * 1024 * 1024,
    max_queued_bytes: usize = 256 * 1024 * 1024,
    max_queued_messages: usize = 1024,
};

const ChannelPushError = error{
    Closed,
    MessageTooLarge,
    QueueFull,
    OutOfMemory,
};

fn boundedWaitDuration(milliseconds: u64) std.Io.Duration {
    const signed = std.math.cast(i64, milliseconds) orelse std.math.maxInt(i64);
    return .fromMilliseconds(signed);
}

/// A FIFO of serialized messages with blocking pop. Closing wakes every
/// waiter; remaining messages are still poppable (drain-then-stop), and
/// `deinit` releases whatever was never consumed (including any SAB storage
/// references inside).
const Channel = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// FIFO message storage. `queue_head` is the first live entry; `pop`
    /// advances it and clears the list when drained, avoiding O(n)
    /// front-removal shifts in Worker-heavy host loops.
    queue: std.ArrayListUnmanaged([]u8) = .empty,
    queue_head: usize = 0,
    queued_bytes: usize = 0,
    closed: bool = false,
    limits: ChannelLimits = .{},
    queue_allocator: std.mem.Allocator = alloc,

    fn init(limits: ChannelLimits) Channel {
        return .{ .limits = limits };
    }

    fn liveMessages(ch: *const Channel) usize {
        return ch.queue.items.len - ch.queue_head;
    }

    fn hasQueued(ch: *const Channel) bool {
        return ch.queue_head < ch.queue.items.len;
    }

    fn clearQueue(ch: *Channel) void {
        std.debug.assert(!ch.hasQueued());
        std.debug.assert(ch.queued_bytes == 0);
        ch.queue.clearRetainingCapacity();
        ch.queue_head = 0;
    }

    fn compactQueueLocked(ch: *Channel) void {
        if (ch.queue_head == 0) return;
        const live = ch.liveMessages();
        std.mem.copyForwards([]u8, ch.queue.items[0..live], ch.queue.items[ch.queue_head..]);
        ch.queue.shrinkRetainingCapacity(live);
        ch.queue_head = 0;
    }

    fn ensureQueueCapacityLocked(ch: *Channel, additional: usize) !void {
        const needed = std.math.add(usize, ch.queue.items.len, additional) catch return error.OutOfMemory;
        if (needed <= ch.queue.capacity) return;
        ch.compactQueueLocked();
        const compacted_needed = std.math.add(usize, ch.queue.items.len, additional) catch return error.OutOfMemory;
        if (compacted_needed <= ch.queue.capacity) return;
        const extra = @max(additional, channel_queue_reserve_granularity);
        const target = std.math.add(usize, ch.queue.items.len, extra) catch return error.OutOfMemory;
        try ch.queue.ensureTotalCapacity(ch.queue_allocator, target);
    }

    fn rejectOwned(bytes: []u8, err: ChannelPushError) ChannelPushError {
        structured_clone.releaseSerialized(bytes);
        alloc.free(bytes);
        return err;
    }

    /// Takes ownership of `bytes` on both success and failure. A successful
    /// return means exactly one live FIFO entry owns the frame; every error
    /// releases the frame and its SAB manifest before returning.
    fn pushOwned(ch: *Channel, bytes: []u8) ChannelPushError!void {
        if (bytes.len > ch.limits.max_message_bytes)
            return rejectOwned(bytes, error.MessageTooLarge);
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        if (ch.closed) {
            ch.mutex.unlock(io);
            return rejectOwned(bytes, error.Closed);
        }
        if (ch.liveMessages() >= ch.limits.max_queued_messages) {
            ch.mutex.unlock(io);
            return rejectOwned(bytes, error.QueueFull);
        }
        const next_bytes = std.math.add(usize, ch.queued_bytes, bytes.len) catch {
            ch.mutex.unlock(io);
            return rejectOwned(bytes, error.QueueFull);
        };
        if (next_bytes > ch.limits.max_queued_bytes) {
            ch.mutex.unlock(io);
            return rejectOwned(bytes, error.QueueFull);
        }
        ch.ensureQueueCapacityLocked(1) catch {
            ch.mutex.unlock(io);
            return rejectOwned(bytes, error.OutOfMemory);
        };
        ch.queue.appendAssumeCapacity(bytes);
        ch.queued_bytes = next_bytes;
        jsthread.recordWorkerChannelPush();
        ch.cond.signal(io);
        ch.mutex.unlock(io);
    }

    /// Next message (caller frees), or null when the channel is closed and
    /// drained, or `timeout_ms` elapsed (null = wait indefinitely).
    fn pop(ch: *Channel, timeout_ms: ?u64) ?[]u8 {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        while (!ch.hasQueued()) {
            if (ch.closed) {
                jsthread.recordWorkerChannelEmptyPop();
                return null;
            }
            if (timeout_ms) |ms| if (ms == 0) {
                jsthread.recordWorkerChannelEmptyPop();
                return null;
            };
            ch.clearQueue();
            const tmo: std.Io.Timeout = if (timeout_ms) |ms| .{ .duration = .{
                .raw = boundedWaitDuration(ms),
                .clock = .awake,
            } } else .none;
            io_compat.conditionWaitTimeout(&ch.cond, io, &ch.mutex, tmo) catch |err| switch (err) {
                error.Timeout => if (!ch.hasQueued()) {
                    jsthread.recordWorkerChannelEmptyPop();
                    return null;
                } else break,
                error.Canceled => continue,
            };
        }
        const bytes = ch.queue.items[ch.queue_head];
        ch.queue.items[ch.queue_head] = undefined;
        ch.queue_head += 1;
        std.debug.assert(bytes.len <= ch.queued_bytes);
        ch.queued_bytes -= bytes.len;
        if (ch.queue_head == ch.queue.items.len) ch.clearQueue();
        jsthread.recordWorkerChannelPop();
        return bytes;
    }

    fn close(ch: *Channel) void {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        ch.closed = true;
        jsthread.recordWorkerChannelClose();
        ch.cond.broadcast(io);
    }

    fn deinit(ch: *Channel) void {
        for (ch.queue.items[ch.queue_head..]) |bytes| {
            structured_clone.releaseSerialized(bytes);
            alloc.free(bytes);
        }
        ch.queued_bytes = 0;
        ch.queue.deinit(ch.queue_allocator);
        ch.queue_head = 0;
    }
};

test "worker channel pops FIFO without front shifts" {
    var ch = Channel{};
    defer ch.deinit();

    const first = try alloc.dupe(u8, &.{1});
    const second = try alloc.dupe(u8, &.{2});
    const third = try alloc.dupe(u8, &.{3});
    try ch.pushOwned(first);
    try ch.pushOwned(second);
    try ch.pushOwned(third);

    const got_first = ch.pop(0) orelse return error.TestUnexpectedResult;
    defer alloc.free(got_first);
    try std.testing.expectEqual(@as(u8, 1), got_first[0]);
    try std.testing.expectEqual(@as(usize, 1), ch.queue_head);
    try std.testing.expectEqual(@as(usize, 3), ch.queue.items.len);

    const got_second = ch.pop(0) orelse return error.TestUnexpectedResult;
    defer alloc.free(got_second);
    try std.testing.expectEqual(@as(u8, 2), got_second[0]);
    const got_third = ch.pop(0) orelse return error.TestUnexpectedResult;
    defer alloc.free(got_third);
    try std.testing.expectEqual(@as(u8, 3), got_third[0]);
    try std.testing.expectEqual(@as(usize, 0), ch.queue_head);
    try std.testing.expectEqual(@as(usize, 0), ch.queue.items.len);

    try std.testing.expect(ch.pop(0) == null);
    const late = try alloc.dupe(u8, &.{4});
    try ch.pushOwned(late);
    const got_late = ch.pop(0) orelse return error.TestUnexpectedResult;
    defer alloc.free(got_late);
    try std.testing.expectEqual(@as(u8, 4), got_late[0]);

    ch.close();
    try std.testing.expect(ch.pop(0) == null);
}

test "worker channel reserves capacity chunks and compacts dead prefixes" {
    var ch = Channel{};
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 0), ch.queue.capacity);
    const first = try alloc.dupe(u8, &.{1});
    try ch.pushOwned(first);
    try std.testing.expect(ch.queue.capacity >= channel_queue_reserve_granularity);
    try std.testing.expectEqual(@as(usize, 1), ch.queue.items.len);

    const first_capacity = ch.queue.capacity;
    var i: usize = 1;
    while (i < first_capacity) : (i += 1) {
        const msg = try alloc.dupe(u8, &.{@intCast(i & 0xff)});
        try ch.pushOwned(msg);
    }
    try std.testing.expectEqual(first_capacity, ch.queue.capacity);
    try std.testing.expectEqual(first_capacity, ch.queue.items.len);

    const popped = ch.pop(0) orelse return error.TestUnexpectedResult;
    alloc.free(popped);
    const extra = try alloc.dupe(u8, &.{0xff});
    try ch.pushOwned(extra);
    try std.testing.expectEqual(first_capacity, ch.queue.capacity);
    try std.testing.expectEqual(@as(usize, 0), ch.queue_head);

    const growth = try alloc.dupe(u8, &.{0xfe});
    try ch.pushOwned(growth);
    try std.testing.expect(ch.queue.capacity > first_capacity);

    while (ch.pop(0)) |bytes| alloc.free(bytes);
}

test "worker channel enforces exact message and byte limits" {
    var ch = Channel.init(.{
        .max_message_bytes = 2,
        .max_queued_bytes = 3,
        .max_queued_messages = 2,
    });
    defer ch.deinit();

    try std.testing.expectError(error.MessageTooLarge, ch.pushOwned(try alloc.dupe(u8, &.{ 1, 2, 3 })));
    try std.testing.expectEqual(@as(usize, 0), ch.liveMessages());
    try std.testing.expectEqual(@as(usize, 0), ch.queued_bytes);

    try ch.pushOwned(try alloc.dupe(u8, &.{ 1, 2 }));
    try ch.pushOwned(try alloc.dupe(u8, &.{3}));
    try std.testing.expectEqual(@as(usize, 2), ch.liveMessages());
    try std.testing.expectEqual(@as(usize, 3), ch.queued_bytes);
    try std.testing.expectError(error.QueueFull, ch.pushOwned(try alloc.dupe(u8, &.{4})));

    const first = ch.pop(0) orelse return error.TestUnexpectedResult;
    defer alloc.free(first);
    try std.testing.expectEqual(@as(usize, 1), ch.liveMessages());
    try std.testing.expectEqual(@as(usize, 1), ch.queued_bytes);
    try ch.pushOwned(try alloc.dupe(u8, &.{ 4, 5 }));
    try std.testing.expectEqual(@as(usize, 3), ch.queued_bytes);

    ch.close();
    try std.testing.expectError(error.Closed, ch.pushOwned(try alloc.dupe(u8, &.{6})));
    while (ch.pop(0)) |bytes| alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), ch.liveMessages());
    try std.testing.expectEqual(@as(usize, 0), ch.queued_bytes);
}

test "worker channel reports queue metadata allocation failure" {
    var no_memory: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_memory);
    var ch = Channel{ .queue_allocator = failing.allocator() };
    defer ch.deinit();

    try std.testing.expectError(error.OutOfMemory, ch.pushOwned(try alloc.dupe(u8, &.{1})));
    try std.testing.expectEqual(@as(usize, 0), ch.liveMessages());
    try std.testing.expectEqual(@as(usize, 0), ch.queued_bytes);
}

test "worker wait timeout clamps unrepresentable milliseconds" {
    try std.testing.expectEqual(
        std.math.maxInt(i64),
        boundedWaitDuration(std.math.maxInt(u64)).toMilliseconds(),
    );
}

test "worker postMessage surfaces channel rejection" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const limited = try Worker.spawnWith("", .{
        .inbox_limits = .{ .max_message_bytes = 1 },
    });
    defer {
        limited.close();
        limited.join();
        limited.destroy();
    }
    try std.testing.expectError(error.Throw, limited.postMessage(&machine, Value.undef()));

    const closed = try Worker.spawn("");
    defer {
        closed.close();
        closed.join();
        closed.destroy();
    }
    closed.close();
    try std.testing.expectError(error.Throw, closed.postMessage(&machine, Value.undef()));
}

test "worker-global postMessage throws on channel rejection" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();
    const signal = try ctx.evaluate("globalThis.__workerLimitSignal = new SharedArrayBuffer(4)");
    const w = try Worker.spawnWith(
        \\globalThis.onmessage = (e) => {
        \\  let result = 2;
        \\  try { postMessage(1); } catch (err) { if (err instanceof RangeError) result = 1; }
        \\  Atomics.store(new Int32Array(e.data), 0, result);
        \\  close();
        \\};
    , .{ .outbox_limits = .{ .max_message_bytes = 1 } });
    defer {
        w.close();
        w.join();
        w.destroy();
    }
    try w.postMessage(&machine, signal);
    w.join();
    const observed = try ctx.evaluate("Atomics.load(new Int32Array(__workerLimitSignal), 0)");
    try std.testing.expectEqual(@as(f64, 1), observed.asNum());
}

test "worker queue rejection releases SAB frame ownership" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();
    const sab = try ctx.evaluate("new SharedArrayBuffer(8)");
    const storage = sab.asObj().array_buffer.?.shared.?;
    const retain_count = storage.retainCount();
    const w = try Worker.spawnWith("", .{
        .inbox_limits = .{ .max_queued_bytes = 0 },
    });
    defer {
        w.close();
        w.join();
        w.destroy();
    }
    try std.testing.expectError(error.Throw, w.postMessage(&machine, sab));
    try std.testing.expectEqual(retain_count, storage.retainCount());
}

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
    pub const Options = struct {
        inbox_limits: ChannelLimits = .{},
        outbox_limits: ChannelLimits = .{},
    };

    thread: ?std.Thread = null,
    owner_thread: std.Thread.Id,
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

    /// Worker handles are owned by the thread that spawned them. The channels
    /// are synchronized, but the thread handle, host hook installation, and
    /// destroy lifecycle are single-owner.
    pub fn isOwnerThread(w: *const Worker) bool {
        return std.Thread.getCurrentId() == w.owner_thread;
    }

    fn notifyHost(w: *Worker) void {
        if (w.hooks.load(.acquire)) |h| h.notify(h.ctx);
    }

    /// Spawn a worker running `src` in a fresh realm on its own thread. The
    /// returned worker must be `terminate`d or have its inbox closed, then
    /// `join`ed and `destroy`ed by the caller.
    pub fn spawn(src: []const u8) error{OutOfMemory}!*Worker {
        return spawnWith(src, .{});
    }

    pub fn spawnWith(src: []const u8, options: Options) error{OutOfMemory}!*Worker {
        const w = try alloc.create(Worker);
        errdefer alloc.destroy(w);
        w.* = .{
            .owner_thread = std.Thread.getCurrentId(),
            .inbox = Channel.init(options.inbox_limits),
            .outbox = Channel.init(options.outbox_limits),
            .src = try alloc.dupe(u8, src),
        };
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
        return spawnModuleWith(entry_path, entry_source, host, .{});
    }

    pub fn spawnModuleWith(
        entry_path: []const u8,
        entry_source: []const u8,
        host: ContextMod.Context.ModuleHost,
        options: Options,
    ) error{OutOfMemory}!*Worker {
        const w = try alloc.create(Worker);
        errdefer alloc.destroy(w);
        const path_copy = try alloc.dupe(u8, entry_path);
        errdefer alloc.free(path_copy);
        const src_copy = try alloc.dupe(u8, entry_source);
        errdefer alloc.free(src_copy);
        w.* = .{
            .owner_thread = std.Thread.getCurrentId(),
            .inbox = Channel.init(options.inbox_limits),
            .outbox = Channel.init(options.outbox_limits),
            .src = &.{},
            .module = .{ .entry_path = path_copy, .entry_source = src_copy, .host = host },
        };
        w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch return error.OutOfMemory;
        return w;
    }

    /// Main-side send: serialize `v` from `from`'s realm into the inbox.
    pub fn postMessage(w: *Worker, from: *interp.Interpreter, v: Value) value.HostError!void {
        const bytes = try serializeForChannel(&w.inbox, from, v);
        try enqueueOwned(&w.inbox, from, bytes);
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

fn serializeForChannel(ch: *Channel, self: *interp.Interpreter, v: Value) value.HostError![]u8 {
    return structured_clone.serializeWithLimit(self, alloc, v, ch.limits.max_message_bytes) catch |err| switch (err) {
        error.MessageTooLarge => self.throwError("RangeError", "Worker message exceeds the channel message limit"),
        error.OutOfMemory => error.OutOfMemory,
        error.Throw => error.Throw,
        error.OptShortCircuit => error.OptShortCircuit,
    };
}

fn enqueueOwned(ch: *Channel, self: *interp.Interpreter, bytes: []u8) value.HostError!void {
    ch.pushOwned(bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Closed => self.throwError("TypeError", "Worker message channel is closed"),
        error.MessageTooLarge => self.throwError("RangeError", "Worker message exceeds the channel message limit"),
        error.QueueFull => self.throwError("RangeError", "Worker message channel capacity exceeded"),
    };
}

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
    const bytes = try serializeForChannel(&w.outbox, self, v);
    try enqueueOwned(&w.outbox, self, bytes);
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
        \\globalThis.onmessage = (e) => {
        \\  postMessage(e.data);
        \\  if (e.data < 0) close();
        \\};
    );
    w.setHostHooks(&hooks);

    const pings = 4;
    var i: usize = 0;
    while (i < pings) : (i += 1) {
        try w.postMessage(&machine, Value.num(@floatFromInt(i)));
    }
    try w.postMessage(&machine, Value.num(-1));

    var replies: usize = 0;
    while (true) {
        const reply = (try w.receive(&machine, 10_000)) orelse break;
        const expected: f64 = if (replies < pings) @floatFromInt(replies) else -1;
        try std.testing.expect(reply.isNumber());
        try std.testing.expectEqual(expected, reply.asNum());
        replies += 1;
    }
    w.join();
    w.destroy();

    try std.testing.expectEqual(@as(usize, pings + 1), replies);
    // The worker fires the hook once per reply message and once more when the
    // outbox closes, so embedders using an event loop get a final drain wake.
    try std.testing.expectEqual(@as(u32, pings + 2), sink.woken.load(.acquire));
}

test "workers: host hook wakes on terminate outbox close" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();

    var sink = HookSink{};
    var hooks = HostHooks{ .ctx = &sink, .notify = HookSink.notify };

    const w = try Worker.spawn("for (;;) {}");
    w.setHostHooks(&hooks);
    w.terminate();
    w.join();
    try std.testing.expect((try w.receive(&machine, 0)) == null);
    w.destroy();

    try std.testing.expectEqual(@as(u32, 1), sink.woken.load(.acquire));
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
