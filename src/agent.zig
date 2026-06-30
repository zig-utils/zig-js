//! Real OS-thread agents for `$262.agent`, plus the blocking `Atomics.wait` /
//! `Atomics.notify` waiter table. Design: docs/threads/P2-agents.md (Phase 2
//! of https://github.com/zig-utils/zig-js/issues/1).
//!
//! Ownership rules (the Phase-2 lifetime contract):
//! - Everything here lives in the process-wide allocator, never in a realm
//!   arena: agent records, source copies, report strings, waiter lists.
//! - The only values that cross an agent boundary are SharedArrayBuffer
//!   storage references (retained per crossing) and report strings (copied
//!   in on `report`, copied out on `takeReport`).
//! - The group mutex guards all Group fields; the waiter mutex guards the
//!   waiter table; neither is ever held while running JS.

const std = @import("std");
const io_compat = @import("io_compat.zig");
const shared_buffer = @import("shared_buffer.zig");
const SharedBufferStorage = shared_buffer.SharedBufferStorage;

const alloc = std.heap.page_allocator;

// ---- engine-global blocking Io ---------------------------------------------
// This zig std's Mutex/Condition/sleep live behind `std.Io`; `Io.Threaded` is
// the blocking implementation (real futex waits with timeouts). One lazily-
// initialized instance serves the whole engine; we use only the futex/clock
// surface, never async/concurrent spawning.

var io_threaded: std.Io.Threaded = undefined;
var io_state = std.atomic.Value(u8).init(0); // 0 uninit / 1 initializing / 2 ready

pub fn engineIo() std.Io {
    while (true) {
        switch (io_state.load(.acquire)) {
            2 => return io_threaded.io(),
            0 => if (io_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                io_threaded = std.Io.Threaded.init(alloc, .{});
                io_state.store(2, .release);
                return io_threaded.io();
            },
            else => std.atomic.spinLoopHint(),
        }
    }
}

// ---- agent group ------------------------------------------------------------

pub const RunFn = *const fn (src: []const u8) void;

pub const Agent = struct {
    thread: ?std.Thread = null,
    /// Group-owned copy of the agent script.
    src: []const u8,
    /// Below: guarded by the group mutex.
    done: bool = false,
    acked_gen: u64 = 0,
};

const Group = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    agents: std.ArrayListUnmanaged(*Agent) = .empty,
    reports: std.ArrayListUnmanaged([]const u8) = .empty,
    bcast: ?*SharedBufferStorage = null, // holds its own reference while set
    bcast_gen: u64 = 0,
    stopping: bool = false,
};

var group: Group = .{};
/// Set by start/broadcast/report on the main thread; lets `reset` skip all
/// locking (and the Io bootstrap) for the overwhelmingly common test that
/// never touches agents.
var group_used = std.atomic.Value(bool).init(false);

threadlocal var t_agent: ?*Agent = null;

/// Non-null while the calling thread is a spawned agent.
pub fn currentAgent() ?*Agent {
    return t_agent;
}

/// Whether the calling agent may block in `Atomics.wait`. Spawned `$262.agent`
/// threads always may block; conformance runners set the main realm policy via
/// `Context.TestingOptions.main_can_block`.
pub fn canBlock(main_can_block: bool) bool {
    return t_agent != null or main_can_block;
}

/// `$262.agent.start(src)`: spawn the agent thread NOW (it runs `src` in a
/// fresh realm via `run` and typically parks in `receiveBroadcast`). This is
/// the ordering the blocking-wait corpus requires — agents make progress
/// while the main agent blocks or spins.
pub fn start(src: []const u8, run: RunFn) error{OutOfMemory}!void {
    const io = engineIo();
    const a = try alloc.create(Agent);
    errdefer alloc.destroy(a);
    a.* = .{ .src = try alloc.dupe(u8, src) };
    errdefer alloc.free(a.src);
    group.mutex.lockUncancelable(io);
    group_used.store(true, .monotonic);
    group.agents.append(alloc, a) catch {
        group.mutex.unlock(io);
        return error.OutOfMemory;
    };
    group.mutex.unlock(io);
    a.thread = std.Thread.spawn(.{}, agentMain, .{ a, run }) catch {
        // Spawn failure: record the agent as already done so broadcast never
        // waits on it (the record stays in the list for reset to free).
        group.mutex.lockUncancelable(io);
        a.done = true;
        group.cond.broadcast(io);
        group.mutex.unlock(io);
        return error.OutOfMemory;
    };
}

fn agentMain(a: *Agent, run: RunFn) void {
    t_agent = a;
    _ = live_agents.fetchAdd(1, .monotonic);
    run(a.src);
    _ = live_agents.fetchSub(1, .monotonic);
    const io = engineIo();
    group.mutex.lockUncancelable(io);
    a.done = true;
    group.cond.broadcast(io); // a broadcast rendezvous may be waiting on us
    group.mutex.unlock(io);
    // An async harvester waiting on "some agent might still notify me" must
    // re-evaluate now that this agent is gone.
    waiters_mutex.lockUncancelable(io);
    waiters_cond.broadcast(io);
    waiters_mutex.unlock(io);
}

/// Agent side of `receiveBroadcast`: park until a broadcast generation this
/// agent hasn't seen, then return the storage with one reference for the
/// caller (null when the group is tearing down, or on the main agent).
pub fn parkUntilBroadcast() ?*SharedBufferStorage {
    const a = t_agent orelse return null;
    const io = engineIo();
    group.mutex.lockUncancelable(io);
    defer group.mutex.unlock(io);
    while (group.bcast_gen == a.acked_gen and !group.stopping) {
        group.cond.waitUncancelable(io, &group.mutex);
    }
    if (group.stopping) return null;
    const s = group.bcast orelse return null;
    a.acked_gen = group.bcast_gen;
    group.cond.broadcast(io); // wake the rendezvous in `broadcast`
    return s.retain();
}

/// Main side of `broadcast(sab)`: publish the storage, wake every parked
/// agent, and block until each live agent has acked this generation (per
/// test262 INTERPRETING.md). A generous cap keeps a wedged agent from
/// hanging the parent forever — the per-test runner timeout is the backstop.
pub fn broadcast(storage: *SharedBufferStorage) void {
    const io = engineIo();
    group.mutex.lockUncancelable(io);
    defer group.mutex.unlock(io);
    group_used.store(true, .monotonic);
    if (group.bcast) |old| old.release();
    group.bcast = storage.retain();
    group.bcast_gen += 1;
    group.cond.broadcast(io);
    var rounds: usize = 0;
    while (!group.stopping) {
        var pending: usize = 0;
        for (group.agents.items) |a| {
            if (!a.done and a.acked_gen < group.bcast_gen) pending += 1;
        }
        if (pending == 0) break;
        io_compat.conditionWaitTimeout(&group.cond, io, &group.mutex, .{ .duration = .{
            .raw = .fromSeconds(10),
            .clock = .awake,
        } }) catch {
            rounds += 1;
            if (rounds >= 2) break; // ~20s of silence: proceed without the ack
        };
    }
}

/// Agent side of `report(msg)`: copy into the group (the agent's arena dies
/// with the agent).
pub fn report(msg: []const u8) void {
    const io = engineIo();
    const copy = alloc.dupe(u8, msg) catch return;
    group.mutex.lockUncancelable(io);
    group_used.store(true, .monotonic);
    group.reports.append(alloc, copy) catch alloc.free(copy);
    group.mutex.unlock(io);
}

/// Main side of `getReport()`: pop the oldest report into `into` (the
/// caller's arena), or null when none is pending.
pub fn takeReport(into: std.mem.Allocator) ?[]const u8 {
    if (!group_used.load(.monotonic)) return null;
    const io = engineIo();
    group.mutex.lockUncancelable(io);
    defer group.mutex.unlock(io);
    if (group.reports.items.len == 0) return null;
    const r = group.reports.orderedRemove(0);
    defer alloc.free(r);
    return into.dupe(u8, r) catch null;
}

/// Tear down the group between tests (called when a fresh main realm installs
/// `$262`): stop signal, wake every parked agent and Atomics waiter, join the
/// agent threads, release everything. Terminating joins rely on (a) every
/// blocking point polling `stopping` and (b) the interpreter's step budget;
/// the runner's per-worker timeout is the last line of defense.
pub fn reset() void {
    if (!group_used.load(.monotonic)) return;
    const io = engineIo();
    group.mutex.lockUncancelable(io);
    group.stopping = true;
    group.cond.broadcast(io);
    group.mutex.unlock(io);
    wakeAllWaiters();
    for (group.agents.items) |a| {
        if (a.thread) |t| t.join();
    }
    group.mutex.lockUncancelable(io);
    for (group.agents.items) |a| {
        alloc.free(a.src);
        alloc.destroy(a);
    }
    group.agents.clearAndFree(alloc);
    for (group.reports.items) |r| alloc.free(r);
    group.reports.clearAndFree(alloc);
    if (group.bcast) |s| s.release();
    group.bcast = null;
    group.bcast_gen = 0;
    group.stopping = false;
    group_used.store(false, .monotonic);
    group.mutex.unlock(io);
}

// ---- host clock helpers ------------------------------------------------------

/// `$262.agent.sleep(ms)` — really sleep.
pub fn sleepMs(ms: f64) void {
    if (!(ms > 0)) return; // NaN/negative/zero: no wait
    const io = engineIo();
    const capped = @min(ms, 60_000.0); // one test must not outlive the runner watchdog
    std.Io.sleep(io, .fromMilliseconds(@intFromFloat(capped)), .awake) catch {};
}

var mono_base = std.atomic.Value(i64).init(0);

/// `$262.agent.monotonicNow()` — a monotonic millisecond clock shared by all
/// agents (timeout tests measure spans across agents). Zero-based at first
/// use so values stay small and exact in an f64.
pub fn monotonicNowMs() f64 {
    const io = engineIo();
    const now: i64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    var base = mono_base.load(.monotonic);
    if (base == 0) {
        _ = mono_base.cmpxchgStrong(0, now, .monotonic, .monotonic);
        base = mono_base.load(.monotonic);
    }
    return @floatFromInt(@divTrunc(@max(0, now - base), std.time.ns_per_ms));
}

// ---- Atomics waiter table ----------------------------------------------------
// One FIFO waiter list per (storage, byte offset); the table mutex is the
// spec's per-list "critical section" (re-validate the element under it, then
// park). Tickets live on the waiting thread's stack and are unlinked before
// `wait` returns, so no allocation outlives the waiter.

const WaitKey = struct { storage: *SharedBufferStorage, offset: usize };

const Ticket = struct {
    cond: std.Io.Condition = .init,
    woken: bool = false,
    linked: bool = false,
    /// Async (`Atomics.waitAsync`) tickets are heap-allocated, carry their
    /// owner realm and deadline, and are harvested by the owner's drain loop
    /// rather than parking a thread. Sync tickets live on the waiter's stack.
    is_async: bool = false,
    owner: ?*const anyopaque = null,
    async_id: u64 = 0,
    /// Absolute `.awake`-clock nanoseconds; null waits forever.
    deadline_ns: ?i96 = null,
};

const WaiterList = struct {
    tickets: std.ArrayListUnmanaged(*Ticket) = .empty,
};

var waiters: std.AutoHashMapUnmanaged(WaitKey, *WaiterList) = .empty;
var waiters_mutex: std.Io.Mutex = .init;
/// Signaled when an async ticket settles (notify or teardown), waking the
/// owner's harvest loop.
var waiters_cond: std.Io.Condition = .init;
var waiters_used = std.atomic.Value(bool).init(false);
/// Agents whose threads are still running — an infinite-deadline async ticket
/// can only ever settle if one of these (or a notify already in flight) exists.
var live_agents = std.atomic.Value(usize).init(0);

/// The waiter list for (storage, offset), created on demand. Caller holds
/// `waiters_mutex`. Null on allocation failure.
fn listFor(key: WaitKey) ?*WaiterList {
    const gop = waiters.getOrPut(alloc, key) catch return null;
    if (!gop.found_existing) {
        gop.value_ptr.* = alloc.create(WaiterList) catch {
            _ = waiters.remove(key);
            return null;
        };
        gop.value_ptr.*.* = .{};
    }
    return gop.value_ptr.*;
}

pub const WaitOutcome = enum { ok, not_equal, timed_out };

/// Blocking `Atomics.wait` core. `T` is i32 or i64; `offset` is the element's
/// byte offset into the storage; `timeout_ns` null means wait forever.
pub fn wait(storage: *SharedBufferStorage, offset: usize, comptime T: type, expected: T, timeout_ns: ?u64) WaitOutcome {
    const io = engineIo();
    waiters_used.store(true, .monotonic);
    waiters_mutex.lockUncancelable(io);
    // The spec's critical section: re-read the element after taking the list
    // lock so a notify between the caller's load and our park can't be lost.
    const p: *T = @ptrCast(@alignCast(storage.slab + offset));
    if (@atomicLoad(T, p, .seq_cst) != expected) {
        waiters_mutex.unlock(io);
        return .not_equal;
    }
    if (group.stopping) {
        waiters_mutex.unlock(io);
        return .timed_out;
    }
    const list = listFor(.{ .storage = storage, .offset = offset }) orelse {
        waiters_mutex.unlock(io);
        return .timed_out;
    };
    var ticket = Ticket{};
    list.tickets.append(alloc, &ticket) catch {
        waiters_mutex.unlock(io);
        return .timed_out;
    };
    ticket.linked = true;
    const deadline: std.Io.Timeout = if (timeout_ns) |ns| (std.Io.Timeout{ .duration = .{
        .raw = .fromNanoseconds(ns),
        .clock = .awake,
    } }).toDeadline(io) else .none;
    var outcome: WaitOutcome = .ok;
    while (!ticket.woken) {
        if (group.stopping) {
            outcome = .timed_out;
            break;
        }
        io_compat.conditionWaitTimeout(&ticket.cond, io, &waiters_mutex, deadline) catch |err| switch (err) {
            error.Timeout => {
                if (!ticket.woken) outcome = .timed_out;
                break;
            },
            error.Canceled => continue,
        };
    }
    // Unlink before returning — unless notify/teardown already unlinked the
    // stack ticket before signaling us.
    if (ticket.linked) unlinkTicket(list, &ticket);
    waiters_mutex.unlock(io);
    return outcome;
}

fn unlinkTicket(list: *WaiterList, ticket: *Ticket) void {
    var removed = false;
    var write: usize = 0;
    for (list.tickets.items, 0..) |t, read| {
        if (t == ticket) {
            removed = true;
            continue;
        }
        if (write != read) list.tickets.items[write] = t;
        write += 1;
    }
    if (removed) {
        ticket.linked = false;
        list.tickets.shrinkRetainingCapacity(write);
    }
}

/// `Atomics.notify` core: wake up to `count` FIFO waiters (sync and async
/// alike, in list order); returns the number actually woken.
pub fn notify(storage: *SharedBufferStorage, offset: usize, count: usize) usize {
    if (!waiters_used.load(.monotonic)) return 0;
    const io = engineIo();
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    const list = waiters.get(.{ .storage = storage, .offset = offset }) orelse return 0;
    var n: usize = 0;
    var any_async = false;
    var write: usize = 0;
    for (list.tickets.items, 0..) |t, read| {
        var keep = true;
        if (n < count and !t.woken) {
            t.woken = true;
            if (t.is_async) {
                any_async = true;
            } else {
                t.linked = false;
                t.cond.signal(io);
                keep = false;
            }
            n += 1;
        }
        if (keep) {
            if (write != read) list.tickets.items[write] = t;
            write += 1;
        }
    }
    if (write != list.tickets.items.len) list.tickets.shrinkRetainingCapacity(write);
    if (any_async) waiters_cond.broadcast(io);
    return n;
}

// ---- Atomics.waitAsync ------------------------------------------------------
// An async ticket parks no thread: it sits in the same FIFO list (so notify
// ordering across wait/waitAsync is the spec's), and the owning realm's drain
// loop harvests settlements (notify or deadline) and resolves the promises.

pub const AsyncEnqueue = union(enum) { not_equal, timed_out, enqueued: u64 };
pub const Settled = struct { id: u64, outcome: WaitOutcome };

var async_id_counter = std.atomic.Value(u64).init(1);

/// Register an async waiter. `owner` identifies the realm that will harvest
/// it (a stable pointer for the realm's lifetime). Returns `not_equal` /
/// `timed_out` for the spec's synchronous early-outs.
pub fn waitAsyncEnqueue(storage: *SharedBufferStorage, offset: usize, comptime T: type, expected: T, timeout_ns: ?u64, owner: *const anyopaque) AsyncEnqueue {
    const io = engineIo();
    waiters_used.store(true, .monotonic);
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    const p: *T = @ptrCast(@alignCast(storage.slab + offset));
    if (@atomicLoad(T, p, .seq_cst) != expected) return .not_equal;
    if (timeout_ns) |ns| if (ns == 0) return .timed_out;
    if (group.stopping) return .timed_out;
    const list = listFor(.{ .storage = storage, .offset = offset }) orelse return .timed_out;
    const t = alloc.create(Ticket) catch return .timed_out;
    const id = async_id_counter.fetchAdd(1, .monotonic);
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    t.* = .{
        .linked = true,
        .is_async = true,
        .owner = owner,
        .async_id = id,
        .deadline_ns = if (timeout_ns) |ns| now + ns else null,
    };
    list.tickets.append(alloc, t) catch {
        alloc.destroy(t);
        return .timed_out;
    };
    return .{ .enqueued = id };
}

/// Block until at least one of `owner`'s async tickets settles (woken by a
/// notify, deadline passed, or group teardown), collect all currently-settled
/// ones into `out`, and return the count. Returns 0 when the owner has no
/// outstanding tickets — or when none can ever settle (every remaining ticket
/// has an infinite deadline and no agent thread is alive to notify it; the
/// owner should then `abandonAsync` and leave those promises pending).
pub fn harvestAsync(owner: *const anyopaque, out: []Settled) usize {
    if (!waiters_used.load(.monotonic)) return 0;
    const io = engineIo();
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    while (true) {
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        var n: usize = 0;
        var outstanding: usize = 0;
        var nearest: ?i96 = null;
        var it = waiters.valueIterator();
        while (it.next()) |listp| {
            const list = listp.*;
            var write: usize = 0;
            for (list.tickets.items, 0..) |t, read| {
                var keep = true;
                if (t.is_async and t.owner == owner) {
                    const expired = t.deadline_ns != null and t.deadline_ns.? <= now;
                    if ((t.woken or expired or group.stopping) and n < out.len) {
                        out[n] = .{ .id = t.async_id, .outcome = if (t.woken) .ok else .timed_out };
                        n += 1;
                        t.linked = false;
                        alloc.destroy(t);
                        keep = false;
                    } else {
                        outstanding += 1;
                        if (t.deadline_ns) |d| nearest = if (nearest) |m| @min(m, d) else d;
                    }
                }
                if (keep) {
                    if (write != read) list.tickets.items[write] = t;
                    write += 1;
                }
            }
            if (write != list.tickets.items.len) list.tickets.shrinkRetainingCapacity(write);
        }
        if (n > 0 or outstanding == 0) return n;
        if (!group.stopping and nearest == null and live_agents.load(.monotonic) == 0) return 0;
        const wait_ns: u64 = if (nearest) |d| @intCast(@max(1, d - now)) else 100 * std.time.ns_per_ms;
        io_compat.conditionWaitTimeout(&waiters_cond, io, &waiters_mutex, .{ .duration = .{
            .raw = .fromNanoseconds(wait_ns),
            .clock = .awake,
        } }) catch {};
    }
}

/// Drop every async ticket belonging to `owner` (its realm is done; the
/// promises stay forever pending — the host's prerogative for unsettleable
/// waits).
pub fn abandonAsync(owner: *const anyopaque) void {
    if (!waiters_used.load(.monotonic)) return;
    const io = engineIo();
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    var it = waiters.valueIterator();
    while (it.next()) |listp| {
        const list = listp.*;
        var write: usize = 0;
        for (list.tickets.items, 0..) |t, read| {
            var keep = true;
            if (t.is_async and t.owner == owner) {
                t.linked = false;
                alloc.destroy(t);
                keep = false;
            }
            if (keep) {
                if (write != read) list.tickets.items[write] = t;
                write += 1;
            }
        }
        if (write != list.tickets.items.len) list.tickets.shrinkRetainingCapacity(write);
    }
}

/// Teardown helper: wake every parked sync waiter (they observe
/// `group.stopping`) and poke async harvesters (they collect under the same
/// flag).
fn wakeAllWaiters() void {
    if (!waiters_used.load(.monotonic)) return;
    const io = engineIo();
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    var it = waiters.valueIterator();
    while (it.next()) |list| {
        var write: usize = 0;
        for (list.*.tickets.items, 0..) |t, read| {
            if (t.is_async) {
                if (write != read) list.*.tickets.items[write] = t;
                write += 1;
                continue; // harvest sees group.stopping
            }
            t.woken = true;
            t.linked = false;
            t.cond.signal(io);
        }
        if (write != list.*.tickets.items.len) list.*.tickets.shrinkRetainingCapacity(write);
    }
    waiters_cond.broadcast(io);
}

test "waiter table: wait blocks until notify; not-equal early-out" {
    const s = try SharedBufferStorage.create(8, null);
    defer s.release();
    const p: *i32 = @ptrCast(@alignCast(s.slab));
    @atomicStore(i32, p, 7, .seq_cst);

    // Mismatch never blocks.
    try std.testing.expectEqual(WaitOutcome.not_equal, wait(s, 0, i32, 8, null));
    // Timeout path.
    try std.testing.expectEqual(WaitOutcome.timed_out, wait(s, 0, i32, 7, 5 * std.time.ns_per_ms));

    const Waker = struct {
        fn run(storage: *SharedBufferStorage) void {
            // Poll until the waiter is parked, then notify it.
            const io = engineIo();
            var woken: usize = 0;
            while (woken == 0) {
                std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
                woken = notify(storage, 0, 1);
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Waker.run, .{s});
    try std.testing.expectEqual(WaitOutcome.ok, wait(s, 0, i32, 7, 2 * std.time.ns_per_s));
    t.join();
}

test "waiter table notify unlinks sync tickets and preserves async FIFO tail" {
    const s = try SharedBufferStorage.create(8, null);
    defer s.release();
    const key = WaitKey{ .storage = s, .offset = 4 };
    var owner: u8 = 0;
    var sync1 = Ticket{ .linked = true };
    var async1 = Ticket{ .linked = true, .is_async = true, .owner = &owner, .async_id = 1 };
    var sync2 = Ticket{ .linked = true };

    const io = engineIo();
    waiters_used.store(true, .monotonic);
    waiters_mutex.lockUncancelable(io);
    const list = listFor(key) orelse {
        waiters_mutex.unlock(io);
        return error.TestUnexpectedResult;
    };
    list.tickets.append(alloc, &sync1) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    list.tickets.append(alloc, &async1) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    list.tickets.append(alloc, &sync2) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    waiters_mutex.unlock(io);

    try std.testing.expectEqual(@as(usize, 2), notify(s, key.offset, 2));

    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    const kept = waiters.get(key) orelse return error.TestUnexpectedResult;
    defer {
        kept.tickets.deinit(alloc);
        _ = waiters.remove(key);
        alloc.destroy(kept);
    }
    try std.testing.expect(sync1.woken);
    try std.testing.expect(!sync1.linked);
    try std.testing.expect(async1.woken);
    try std.testing.expect(async1.linked);
    try std.testing.expect(!sync2.woken);
    try std.testing.expect(sync2.linked);
    try std.testing.expectEqual(@as(usize, 2), kept.tickets.items.len);
    try std.testing.expect(kept.tickets.items[0] == &async1);
    try std.testing.expect(kept.tickets.items[1] == &sync2);
}

test "waiter table harvestAsync stable-compacts settled owner tickets" {
    const s = try SharedBufferStorage.create(8, null);
    defer s.release();
    const key = WaitKey{ .storage = s, .offset = 8 };
    var owner: u8 = 0;
    var other_owner: u8 = 0;
    var sync_tail = Ticket{ .linked = true };

    const io = engineIo();
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const settled = try alloc.create(Ticket);
    const other = try alloc.create(Ticket);
    const expired = try alloc.create(Ticket);
    const pending = try alloc.create(Ticket);
    settled.* = .{ .linked = true, .is_async = true, .owner = &owner, .async_id = 11, .woken = true };
    other.* = .{ .linked = true, .is_async = true, .owner = &other_owner, .async_id = 22, .woken = true };
    expired.* = .{ .linked = true, .is_async = true, .owner = &owner, .async_id = 33, .deadline_ns = now - 1 };
    pending.* = .{ .linked = true, .is_async = true, .owner = &owner, .async_id = 44, .deadline_ns = now + std.time.ns_per_s };

    waiters_used.store(true, .monotonic);
    waiters_mutex.lockUncancelable(io);
    const list = listFor(key) orelse {
        waiters_mutex.unlock(io);
        return error.TestUnexpectedResult;
    };
    list.tickets.append(alloc, settled) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    list.tickets.append(alloc, other) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    list.tickets.append(alloc, expired) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    list.tickets.append(alloc, pending) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    list.tickets.append(alloc, &sync_tail) catch {
        waiters_mutex.unlock(io);
        return error.OutOfMemory;
    };
    waiters_mutex.unlock(io);

    var out: [4]Settled = undefined;
    const n = harvestAsync(&owner, out[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 11), out[0].id);
    try std.testing.expectEqual(WaitOutcome.ok, out[0].outcome);
    try std.testing.expectEqual(@as(u64, 33), out[1].id);
    try std.testing.expectEqual(WaitOutcome.timed_out, out[1].outcome);

    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    const kept = waiters.get(key) orelse return error.TestUnexpectedResult;
    defer {
        alloc.destroy(other);
        alloc.destroy(pending);
        kept.tickets.deinit(alloc);
        _ = waiters.remove(key);
        alloc.destroy(kept);
    }
    try std.testing.expectEqual(@as(usize, 3), kept.tickets.items.len);
    try std.testing.expect(kept.tickets.items[0] == other);
    try std.testing.expect(kept.tickets.items[1] == pending);
    try std.testing.expect(kept.tickets.items[2] == &sync_tail);
    try std.testing.expect(other.linked);
    try std.testing.expect(pending.linked);
}
