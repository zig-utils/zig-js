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
var group_used: bool = false;

/// `[[CanBlock]]` of the *main* agent (host-set; spawned agents always may
/// block). The runner flips this for `CanBlockIsFalse` tests.
pub var main_can_block: bool = true;

threadlocal var t_agent: ?*Agent = null;

/// Non-null while the calling thread is a spawned agent.
pub fn currentAgent() ?*Agent {
    return t_agent;
}

/// Whether the calling agent may block in `Atomics.wait`.
pub fn canBlock() bool {
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
    group_used = true;
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
    run(a.src);
    const io = engineIo();
    group.mutex.lockUncancelable(io);
    a.done = true;
    group.cond.broadcast(io); // a broadcast rendezvous may be waiting on us
    group.mutex.unlock(io);
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
    group_used = true;
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
        group.cond.waitTimeout(io, &group.mutex, .{ .duration = .{
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
    group_used = true;
    group.reports.append(alloc, copy) catch alloc.free(copy);
    group.mutex.unlock(io);
}

/// Main side of `getReport()`: pop the oldest report into `into` (the
/// caller's arena), or null when none is pending.
pub fn takeReport(into: std.mem.Allocator) ?[]const u8 {
    if (!group_used) return null;
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
    if (!group_used) return;
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
    group_used = false;
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
};

const WaiterList = struct {
    tickets: std.ArrayListUnmanaged(*Ticket) = .empty,
};

var waiters: std.AutoHashMapUnmanaged(WaitKey, *WaiterList) = .empty;
var waiters_mutex: std.Io.Mutex = .init;
var waiters_used = std.atomic.Value(bool).init(false);

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
    const gop = waiters.getOrPut(alloc, .{ .storage = storage, .offset = offset }) catch {
        waiters_mutex.unlock(io);
        return .timed_out;
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = alloc.create(WaiterList) catch {
            _ = waiters.remove(.{ .storage = storage, .offset = offset });
            waiters_mutex.unlock(io);
            return .timed_out;
        };
        gop.value_ptr.*.* = .{};
    }
    const list = gop.value_ptr.*;
    var ticket = Ticket{};
    list.tickets.append(alloc, &ticket) catch {
        waiters_mutex.unlock(io);
        return .timed_out;
    };
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
        ticket.cond.waitTimeout(io, &waiters_mutex, deadline) catch |err| switch (err) {
            error.Timeout => {
                if (!ticket.woken) outcome = .timed_out;
                break;
            },
            error.Canceled => continue,
        };
    }
    // Unlink before returning — the ticket is stack memory.
    for (list.tickets.items, 0..) |t, i| {
        if (t == &ticket) {
            _ = list.tickets.orderedRemove(i);
            break;
        }
    }
    waiters_mutex.unlock(io);
    return outcome;
}

/// `Atomics.notify` core: wake up to `count` FIFO waiters; returns the number
/// actually woken.
pub fn notify(storage: *SharedBufferStorage, offset: usize, count: usize) usize {
    if (!waiters_used.load(.monotonic)) return 0;
    const io = engineIo();
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    const list = waiters.get(.{ .storage = storage, .offset = offset }) orelse return 0;
    var n: usize = 0;
    for (list.tickets.items) |t| {
        if (n >= count) break;
        if (!t.woken) {
            t.woken = true;
            t.cond.signal(io);
            n += 1;
        }
    }
    return n;
}

/// Teardown helper: wake every parked waiter (they observe `group.stopping`).
fn wakeAllWaiters() void {
    if (!waiters_used.load(.monotonic)) return;
    const io = engineIo();
    waiters_mutex.lockUncancelable(io);
    defer waiters_mutex.unlock(io);
    var it = waiters.valueIterator();
    while (it.next()) |list| {
        for (list.*.tickets.items) |t| {
            t.woken = true;
            t.cond.signal(io);
        }
    }
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
