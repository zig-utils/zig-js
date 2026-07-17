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

/// Stable inspector identity is process-wide and never derived from a Worker
/// address. Zero remains the protocol's invalid/unset sentinel. Exhaustion is
/// terminal instead of wrapping and aliasing a live or historical target.
var next_inspector_target_id: std.atomic.Value(u64) = .init(1);

fn allocateInspectorTargetId() error{InspectorTargetIdExhausted}!u64 {
    var current = next_inspector_target_id.load(.monotonic);
    while (true) {
        if (current == 0) return error.InspectorTargetIdExhausted;
        const next = if (current == std.math.maxInt(u64)) 0 else current + 1;
        if (next_inspector_target_id.cmpxchgWeak(current, next, .monotonic, .monotonic)) |observed| {
            current = observed;
            continue;
        }
        return current;
    }
}

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
        return ch.popInterruptible(timeout_ms, null);
    }

    /// `interrupt` lets the worker's single event loop share this wait with its
    /// inspector command queue. A non-zero value returns null without consuming
    /// a message; the caller services commands and then re-enters the wait.
    fn popInterruptible(ch: *Channel, timeout_ms: ?u64, interrupt: ?*const std.atomic.Value(u32)) ?[]u8 {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        defer ch.mutex.unlock(io);
        while (!ch.hasQueued()) {
            if (interrupt) |pending| if (pending.load(.acquire) != 0) return null;
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

    fn wake(ch: *Channel) void {
        const io = agent.engineIo();
        ch.mutex.lockUncancelable(io);
        ch.cond.broadcast(io);
        ch.mutex.unlock(io);
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

pub const InspectorMessageCallback = *const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;
pub const InspectorPauseWaitHook = *const fn (ctx: *anyopaque) bool;

/// Type-erased bridge supplied by the C binding. Worker stays independent of
/// the protocol implementation; every backend call runs on the worker runtime
/// thread and therefore preserves Context affinity.
pub const InspectorBackend = struct {
    create: *const fn (
        ctx: *Context,
        callback: InspectorMessageCallback,
        user_data: ?*anyopaque,
        pause_wait_ctx: *anyopaque,
        pause_wait_hook: InspectorPauseWaitHook,
    ) ?*anyopaque,
    dispatch: *const fn (session: *anyopaque, message: []const u8) bool,
    release: *const fn (session: *anyopaque) void,
};

pub const InspectorEventKind = enum { message, detached };

pub const InspectorEvent = struct {
    kind: InspectorEventKind,
    message: []u8 = &.{},

    pub fn deinit(event: *InspectorEvent) void {
        if (event.message.len != 0) alloc.free(event.message);
        event.* = undefined;
    }
};

const InspectorEventQueue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(InspectorEvent) = .empty,
    head: usize = 0,
    closed: bool = false,

    fn push(q: *InspectorEventQueue, event: InspectorEvent) !void {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.closed) return error.Closed;
        try q.items.append(alloc, event);
        q.cond.signal(io);
    }

    fn pop(q: *InspectorEventQueue, timeout_ms: ?u64) ?InspectorEvent {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        while (q.head == q.items.items.len) {
            if (q.closed) return null;
            if (timeout_ms) |ms| if (ms == 0) return null;
            if (q.head != 0) {
                q.items.clearRetainingCapacity();
                q.head = 0;
            }
            const tmo: std.Io.Timeout = if (timeout_ms) |ms| .{ .duration = .{
                .raw = boundedWaitDuration(ms),
                .clock = .awake,
            } } else .none;
            io_compat.conditionWaitTimeout(&q.cond, io, &q.mutex, tmo) catch |err| switch (err) {
                error.Timeout => return null,
                error.Canceled => continue,
            };
        }
        const event = q.items.items[q.head];
        q.head += 1;
        if (q.head == q.items.items.len) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        }
        return event;
    }

    fn close(q: *InspectorEventQueue) void {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        q.closed = true;
        q.cond.broadcast(io);
        q.mutex.unlock(io);
    }

    fn deinit(q: *InspectorEventQueue) void {
        for (q.items.items[q.head..]) |*event| event.deinit();
        q.items.deinit(alloc);
    }
};

pub const InspectorClient = struct {
    worker: *Worker,
    id: u64,
    owner_thread: std.Thread.Id,
    events: InspectorEventQueue = .{},
    transport_closed: std.atomic.Value(bool) = .init(false),

    pub fn isOwnerThread(client: *const InspectorClient) bool {
        return client.owner_thread == std.Thread.getCurrentId();
    }
};

const InspectorCommandKind = enum { attach, dispatch, detach };

const InspectorCommand = struct {
    kind: InspectorCommandKind,
    client: *InspectorClient,
    message: []u8 = &.{},

    fn deinit(command: *InspectorCommand) void {
        if (command.message.len != 0) alloc.free(command.message);
        command.* = undefined;
    }
};

const InspectorCommandQueue = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(InspectorCommand) = .empty,
    head: usize = 0,
    pending: std.atomic.Value(u32) = .init(0),
    closed: bool = false,

    fn push(q: *InspectorCommandQueue, command: InspectorCommand) !void {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.closed) return error.Closed;
        try q.items.append(alloc, command);
        _ = q.pending.fetchAdd(1, .release);
        q.cond.signal(io);
    }

    fn pop(q: *InspectorCommandQueue, block: bool, abort_wait: *const std.atomic.Value(bool)) ?InspectorCommand {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        while (q.head == q.items.items.len) {
            if (!block or q.closed or abort_wait.load(.acquire)) return null;
            if (q.head != 0) {
                q.items.clearRetainingCapacity();
                q.head = 0;
            }
            q.cond.wait(io, &q.mutex) catch continue;
        }
        const command = q.items.items[q.head];
        q.head += 1;
        _ = q.pending.fetchSub(1, .acq_rel);
        if (q.head == q.items.items.len) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        }
        return command;
    }

    fn wake(q: *InspectorCommandQueue) void {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        q.cond.broadcast(io);
        q.mutex.unlock(io);
    }

    fn close(q: *InspectorCommandQueue) void {
        const io = agent.engineIo();
        q.mutex.lockUncancelable(io);
        q.closed = true;
        q.cond.broadcast(io);
        q.mutex.unlock(io);
    }

    fn deinit(q: *InspectorCommandQueue) void {
        for (q.items.items[q.head..]) |*command| {
            command.client.transport_closed.store(true, .release);
            command.client.events.close();
            command.deinit();
        }
        q.items.deinit(alloc);
    }
};

const ActiveInspectorSession = struct {
    client: *InspectorClient,
    backend_session: *anyopaque,
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
    const storage = sab.asObj().arrayBuffer().?.shared.?;
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
    pub const InspectorTargetKind = enum(c_uint) {
        script = 0,
        module = 1,
    };

    pub const InspectorTargetState = enum(c_uint) {
        starting = 0,
        running = 1,
        closing = 2,
        closed = 3,
    };

    pub const Options = struct {
        inbox_limits: ChannelLimits = .{},
        outbox_limits: ChannelLimits = .{},
        inspector_backend: ?*const InspectorBackend = null,
    };

    thread: ?std.Thread = null,
    owner_thread: std.Thread.Id,
    inspector_target_id: u64,
    inspector_target_kind: InspectorTargetKind,
    inspector_target_state: std.atomic.Value(InspectorTargetState) = .init(.starting),
    inspector_backend: ?*const InspectorBackend = null,
    inspector_commands: InspectorCommandQueue = .{},
    inspector_sessions: std.ArrayListUnmanaged(ActiveInspectorSession) = .empty,
    inspector_context: ?*Context = null,
    next_inspector_session_id: u64 = 1,
    inspector_wait_abort: std.atomic.Value(bool) = .init(false),
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

    pub fn inspectorTargetState(w: *const Worker) InspectorTargetState {
        return w.inspector_target_state.load(.acquire);
    }

    fn beginClosing(w: *Worker) void {
        var current = w.inspector_target_state.load(.acquire);
        while (current == .starting or current == .running) {
            if (w.inspector_target_state.cmpxchgWeak(current, .closing, .acq_rel, .acquire)) |observed| {
                current = observed;
                continue;
            }
            return;
        }
    }

    fn notifyHost(w: *Worker) void {
        if (w.hooks.load(.acquire)) |h| h.notify(h.ctx);
    }

    fn enqueueInspectorCommand(w: *Worker, kind: InspectorCommandKind, client: *InspectorClient, message: []const u8) !void {
        const copy: []u8 = if (message.len == 0) @constCast(&.{}) else try alloc.dupe(u8, message);
        errdefer if (copy.len != 0) alloc.free(copy);
        try w.inspector_commands.push(.{ .kind = kind, .client = client, .message = copy });
        w.inbox.wake();
    }

    pub fn createInspectorClient(w: *Worker) !*InspectorClient {
        if (!w.isOwnerThread() or w.inspector_backend == null) return error.InspectorUnavailable;
        const state = w.inspectorTargetState();
        if (state == .closing or state == .closed) return error.WorkerClosed;
        if (w.next_inspector_session_id == 0) return error.InspectorSessionIdExhausted;
        const client = try alloc.create(InspectorClient);
        errdefer alloc.destroy(client);
        client.* = .{
            .worker = w,
            .id = w.next_inspector_session_id,
            .owner_thread = w.owner_thread,
        };
        w.next_inspector_session_id = if (w.next_inspector_session_id == std.math.maxInt(u64)) 0 else w.next_inspector_session_id + 1;
        try w.enqueueInspectorCommand(.attach, client, "");
        return client;
    }

    pub fn dispatchInspector(client: *InspectorClient, message: []const u8) bool {
        if (!client.isOwnerThread() or message.len == 0 or client.transport_closed.load(.acquire)) return false;
        client.worker.enqueueInspectorCommand(.dispatch, client, message) catch return false;
        return true;
    }

    pub fn receiveInspector(client: *InspectorClient, timeout_ms: ?u64) ?InspectorEvent {
        if (!client.isOwnerThread()) return null;
        return client.events.pop(timeout_ms);
    }

    pub fn releaseInspectorClient(client: *InspectorClient) void {
        if (!client.isOwnerThread()) return;
        if (!client.transport_closed.load(.acquire)) {
            client.worker.enqueueInspectorCommand(.detach, client, "") catch {
                client.transport_closed.store(true, .release);
                client.events.close();
            };
            while (client.events.pop(null)) |event_value| {
                var event = event_value;
                const detached = event.kind == .detached;
                event.deinit();
                if (detached) break;
            }
        }
        client.transport_closed.store(true, .release);
        client.events.close();
        client.events.deinit();
        alloc.destroy(client);
    }

    /// Spawn a worker running `src` in a fresh realm on its own thread. The
    /// returned worker must be `terminate`d or have its inbox closed, then
    /// `join`ed and `destroy`ed by the caller.
    pub fn spawn(src: []const u8) error{ OutOfMemory, InspectorTargetIdExhausted }!*Worker {
        return spawnWith(src, .{});
    }

    pub fn spawnWith(src: []const u8, options: Options) error{ OutOfMemory, InspectorTargetIdExhausted }!*Worker {
        const w = try alloc.create(Worker);
        errdefer alloc.destroy(w);
        w.* = .{
            .owner_thread = std.Thread.getCurrentId(),
            .inspector_target_id = try allocateInspectorTargetId(),
            .inspector_target_kind = .script,
            .inspector_backend = options.inspector_backend,
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
    ) error{ OutOfMemory, InspectorTargetIdExhausted }!*Worker {
        return spawnModuleWith(entry_path, entry_source, host, .{});
    }

    pub fn spawnModuleWith(
        entry_path: []const u8,
        entry_source: []const u8,
        host: ContextMod.Context.ModuleHost,
        options: Options,
    ) error{ OutOfMemory, InspectorTargetIdExhausted }!*Worker {
        const w = try alloc.create(Worker);
        errdefer alloc.destroy(w);
        const path_copy = try alloc.dupe(u8, entry_path);
        errdefer alloc.free(path_copy);
        const src_copy = try alloc.dupe(u8, entry_source);
        errdefer alloc.free(src_copy);
        w.* = .{
            .owner_thread = std.Thread.getCurrentId(),
            .inspector_target_id = try allocateInspectorTargetId(),
            .inspector_target_kind = .module,
            .inspector_backend = options.inspector_backend,
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
        w.beginClosing();
        w.inspector_wait_abort.store(true, .release);
        w.stop.store(true, .monotonic);
        w.inbox.close();
        w.inspector_commands.wake();
    }

    /// Graceful shutdown: close the inbox so the delivery loop drains any
    /// remaining messages and exits, without the stop-flag interrupt that
    /// `terminate` injects into in-flight JS.
    pub fn close(w: *Worker) void {
        w.beginClosing();
        w.inspector_wait_abort.store(true, .release);
        w.inbox.close();
        w.inspector_commands.wake();
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
        w.inspector_commands.close();
        w.inspector_commands.deinit();
        w.inspector_sessions.deinit(alloc);
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

fn inspectorEventSink(message: [*]const u8, message_len: usize, user_data: ?*anyopaque) callconv(.c) void {
    const client: *InspectorClient = @ptrCast(@alignCast(user_data orelse return));
    const copy = alloc.dupe(u8, message[0..message_len]) catch {
        client.transport_closed.store(true, .release);
        client.events.close();
        return;
    };
    client.events.push(.{ .kind = .message, .message = copy }) catch {
        alloc.free(copy);
        client.transport_closed.store(true, .release);
        client.events.close();
    };
}

fn activeInspectorSessionIndex(w: *Worker, client: *InspectorClient) ?usize {
    for (w.inspector_sessions.items, 0..) |session, index| {
        if (session.client == client) return index;
    }
    return null;
}

fn finishInspectorClient(client: *InspectorClient, reason: []const u8) void {
    if (!client.transport_closed.load(.acquire)) {
        const message = std.fmt.allocPrint(
            alloc,
            "{{\"method\":\"Inspector.detached\",\"params\":{{\"reason\":\"{s}\"}}}}",
            .{reason},
        ) catch null;
        if (message) |owned| client.events.push(.{ .kind = .message, .message = owned }) catch alloc.free(owned);
        client.events.push(.{ .kind = .detached }) catch {};
    }
    client.transport_closed.store(true, .release);
    client.events.close();
}

fn serviceInspectorCommand(w: *Worker, ctx: *Context, block: bool) bool {
    var command = w.inspector_commands.pop(block, &w.inspector_wait_abort) orelse return false;
    defer command.deinit();
    const backend = w.inspector_backend orelse {
        finishInspectorClient(command.client, "worker inspector backend is unavailable");
        return true;
    };
    switch (command.kind) {
        .attach => {
            if (command.client.transport_closed.load(.acquire)) return true;
            const session = backend.create(
                ctx,
                inspectorEventSink,
                command.client,
                w,
                workerInspectorPauseWait,
            ) orelse {
                finishInspectorClient(command.client, "worker inspector attach failed");
                return true;
            };
            w.inspector_sessions.append(alloc, .{
                .client = command.client,
                .backend_session = session,
            }) catch {
                backend.release(session);
                finishInspectorClient(command.client, "worker inspector attach ran out of memory");
            };
        },
        .dispatch => {
            const index = activeInspectorSessionIndex(w, command.client) orelse {
                finishInspectorClient(command.client, "worker inspector session is not attached");
                return true;
            };
            _ = backend.dispatch(w.inspector_sessions.items[index].backend_session, command.message);
        },
        .detach => {
            if (activeInspectorSessionIndex(w, command.client)) |index| {
                const session = w.inspector_sessions.swapRemove(index);
                backend.release(session.backend_session);
            }
            finishInspectorClient(command.client, "worker inspector session released");
        },
    }
    return true;
}

fn serviceInspectorCommands(w: *Worker, ctx: *Context) void {
    while (serviceInspectorCommand(w, ctx, false)) {}
}

fn workerInspectorStatementCheckpoint(ctx: *anyopaque, _: *interp.Interpreter) void {
    const w: *Worker = @ptrCast(@alignCast(ctx));
    const runtime = w.inspector_context orelse return;
    serviceInspectorCommands(w, runtime);
}

fn workerInspectorPauseWait(ctx: *anyopaque) bool {
    const w: *Worker = @ptrCast(@alignCast(ctx));
    const runtime = w.inspector_context orelse return false;
    return serviceInspectorCommand(w, runtime, true);
}

fn closeWorkerInspector(w: *Worker) void {
    w.inspector_commands.close();
    const backend = w.inspector_backend;
    while (w.inspector_sessions.pop()) |session| {
        if (backend) |implementation| implementation.release(session.backend_session);
        finishInspectorClient(session.client, "worker target closed");
    }
    // Pending attaches never acquired a backend session, but their public
    // handles must still wake and become safely releasable.
    while (w.inspector_commands.pop(false, &w.inspector_wait_abort)) |command_value| {
        var command = command_value;
        finishInspectorClient(command.client, "worker target closed before command dispatch");
        command.deinit();
    }
    w.inspector_context = null;
}

fn closePendingInspectorCommands(w: *Worker) void {
    w.inspector_commands.close();
    while (w.inspector_commands.pop(false, &w.inspector_wait_abort)) |command_value| {
        var command = command_value;
        finishInspectorClient(command.client, "worker target closed before command dispatch");
        command.deinit();
    }
}

fn workerMain(w: *Worker) void {
    defer {
        closePendingInspectorCommands(w);
        w.outbox.close();
        w.inspector_target_state.store(.closed, .release);
        w.notifyHost(); // final receive observes the closed target and outbox
    }
    const ctx = Context.create(alloc) catch {
        return;
    };
    if (w.inspector_backend != null) ctx.initCApiRef();
    defer {
        if (w.inspector_backend != null) std.debug.assert(ctx.releaseCApiRef());
        ctx.destroy();
    }
    w.inspector_context = ctx;
    defer closeWorkerInspector(w);
    ctx.stop_flag = &w.stop;
    if (w.inspector_backend != null) {
        ctx.host_statement_ctx = w;
        ctx.host_statement_hook = workerInspectorStatementCheckpoint;
        serviceInspectorCommands(w, ctx);
    }
    installWorkerGlobals(ctx, w) catch {
        return;
    };
    _ = w.inspector_target_state.cmpxchgStrong(.starting, .running, .release, .monotonic);

    if (w.module) |mc| {
        _ = ctx.evaluateModule(mc.entry_path, mc.entry_source, mc.host) catch {};
    } else {
        const script_url = std.fmt.allocPrint(ctx.arena(), "worker://{d}/script", .{w.inspector_target_id}) catch return;
        const script = ctx.registerDebugScript(w.src, script_url, 1) catch return;
        ctx.debug_script_id = script.id;
        ctx.debug_script_start_line = script.start_line;
        _ = ctx.evaluate(w.src) catch {};
        ctx.debug_script_id = 0;
        ctx.debug_script_start_line = 1;
    }

    // Delivery loop: park on the inbox, hand each message to onmessage.
    while (!w.stop.load(.monotonic)) {
        serviceInspectorCommands(w, ctx);
        const bytes = w.inbox.popInterruptible(null, &w.inspector_commands.pending) orelse {
            if (w.inspector_commands.pending.load(.acquire) != 0) continue;
            break; // inbox closed + drained
        };
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
    w.close(); // delivery loop drains queued messages and paused transport wakes
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

test "workers: inspector target ids are stable and lifecycle is atomic" {
    const first = try Worker.spawn("");
    defer first.destroy();
    const second = try Worker.spawn("");
    defer second.destroy();

    try std.testing.expect(first.inspector_target_id != 0);
    try std.testing.expect(second.inspector_target_id != 0);
    try std.testing.expect(first.inspector_target_id != second.inspector_target_id);
    try std.testing.expectEqual(Worker.InspectorTargetKind.script, first.inspector_target_kind);
    try std.testing.expectEqual(Worker.InspectorTargetKind.script, second.inspector_target_kind);

    var spins: usize = 0;
    while (first.inspectorTargetState() == .starting and spins < 100_000) : (spins += 1) {
        if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(Worker.InspectorTargetState.running, first.inspectorTargetState());

    first.terminate();
    try std.testing.expect(first.inspectorTargetState() == .closing or first.inspectorTargetState() == .closed);
    first.join();
    try std.testing.expectEqual(Worker.InspectorTargetState.closed, first.inspectorTargetState());

    second.close();
    second.join();
    try std.testing.expectEqual(Worker.InspectorTargetState.closed, second.inspectorTargetState());
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

test "module workers publish module inspector target metadata" {
    const w = try Worker.spawnModule("entry.js", StaticModules.entries[1].source, StaticModules.host());
    defer w.destroy();
    try std.testing.expect(w.inspector_target_id != 0);
    try std.testing.expectEqual(Worker.InspectorTargetKind.module, w.inspector_target_kind);
    w.close();
    w.join();
    try std.testing.expectEqual(Worker.InspectorTargetState.closed, w.inspectorTargetState());
}

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
