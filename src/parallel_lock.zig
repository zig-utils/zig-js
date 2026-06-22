//! GIL-free mutual-exclusion lock — the reference primitive for the
//! coordination-primitive rewrite (issue #1, Phase 7 / M3, the critical path).
//!
//! Today `Atomics.Mutex`/`Lock` (`src/jsthread.zig` `LockRecord`) protect their
//! state with the GIL and park via `g.waitTimeout(&rec.cond, …)` — the per-record
//! condvar waited on with the *GIL* as its mutex. That cannot survive the GIL
//! drop: a condvar needs the waiter and notifier to share one mutex, and the GIL
//! also has to be released-while-parked for the GIL'd model. The fix (see
//! `docs/threads/P7-gil-removal.md`) is to give each waitable its own
//! `std.Io.Mutex`+`std.Io.Condition`.
//!
//! This is that mechanism, standalone and validated, so the production migration
//! of `acquireLock`/`releaseLock` follows a proven reference rather than being
//! debugged in place. Crucially, with a real per-record mutex the protocol is the
//! *standard* condvar pattern — the mutex gives true atomicity, so the GIL'd
//! version's `sync_generation` handoff dance is unnecessary for correctness (it
//! existed only because the GIL serialized everything and the state was checked
//! across GIL yields). It still models the production semantics that matter:
//! mutual exclusion, reentrancy detection (a nested same-thread hold throws
//! rather than self-deadlocking), and bounded `lockIfAvailable`-style timeouts.

const std = @import("std");
const io_compat = @import("io_compat.zig");
const builtin = @import("builtin");
const agent = @import("agent.zig");

pub const AcquireResult = enum {
    acquired,
    /// The timeout elapsed before the lock became available (`lockIfAvailable`).
    timed_out,
    /// The calling thread already holds the lock — acquiring again would
    /// self-deadlock, so the JS layer turns this into a TypeError.
    reentrant,
};

pub const ParallelLock = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    locked: bool = false,
    /// Holding thread id (0 = unheld), read/written only under `mutex`.
    holder: u64 = 0,

    fn tid() u64 {
        return @intCast(std.Thread.getCurrentId());
    }

    /// Acquire the lock. `timeout_ns == null` blocks until acquired; a value
    /// bounds the wait (0 = try-only). The wait is a textbook condvar loop:
    /// `cond.wait` releases `mutex` while parked and reacquires on wake, so the
    /// `locked` re-check and the `locked = true` publish are atomic under `mutex`
    /// — real mutual exclusion with no GIL.
    pub fn acquire(self: *ParallelLock, io: std.Io, timeout_ns: ?u64) AcquireResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const me = tid();
        if (self.locked and self.holder == me) return .reentrant;
        if (timeout_ns) |ns| {
            if (self.locked and ns == 0) return .timed_out;
            const deadline: i96 = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, @intCast(ns));
            while (self.locked) {
                const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
                if (now >= deadline) return .timed_out;
                const remaining: u64 = @intCast(deadline - now);
                io_compat.conditionWaitTimeout(&self.cond, io, &self.mutex, .{ .duration = .{
                    .raw = .fromNanoseconds(remaining),
                    .clock = .awake,
                } }) catch {};
            }
        } else {
            while (self.locked) self.cond.waitUncancelable(io, &self.mutex);
        }
        self.locked = true;
        self.holder = me;
        return .acquired;
    }

    /// Release the lock. Returns false if the caller is not the current holder
    /// (the JS layer turns that into a TypeError). Signals one waiter.
    pub fn release(self: *ParallelLock, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.locked or self.holder != tid()) return false;
        self.locked = false;
        self.holder = 0;
        self.cond.signal(io);
        return true;
    }
};

test "ParallelLock: mutual exclusion under parallel threads, no GIL" {
    // N threads each acquire the lock, increment a shared counter M times in the
    // critical section, and release — all with no GIL, parking on the lock's own
    // mutex+condvar. If the lock serializes correctly the counter is exactly N*M
    // (every increment in a critical section, none lost). TSan-clean proves the
    // condvar park/wake + the `locked`/`holder` handoff are race-free.
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = agent.engineIo();
    const nthreads = 4;
    const per = 5000;
    const Shared = struct {
        lock: ParallelLock = .{},
        io: std.Io,
        counter: u64 = 0, // mutated only inside the critical section
        fn run(s: *@This()) void {
            var i: usize = 0;
            while (i < per) : (i += 1) {
                std.debug.assert(s.lock.acquire(s.io, null) == .acquired);
                s.counter += 1; // no atomics: correctness comes from the lock
                std.debug.assert(s.lock.release(s.io));
            }
        }
    };
    var shared = Shared{ .io = io };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool) |*th| th.* = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    for (&pool) |*th| th.join();
    try std.testing.expectEqual(@as(u64, nthreads * per), shared.counter);
}

test "ParallelLock: reentrancy is detected, not self-deadlocked" {
    const io = agent.engineIo();
    var lock = ParallelLock{};
    try std.testing.expectEqual(AcquireResult.acquired, lock.acquire(io, null));
    // A second acquire on the same thread must report reentrancy (the JS layer
    // throws) rather than block forever.
    try std.testing.expectEqual(AcquireResult.reentrant, lock.acquire(io, null));
    try std.testing.expect(lock.release(io));
    // After release the lock is free again.
    try std.testing.expectEqual(AcquireResult.acquired, lock.acquire(io, null));
    try std.testing.expect(lock.release(io));
}

test "ParallelLock: lockIfAvailable-style timeout while held by a peer" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = agent.engineIo();
    const Shared = struct {
        lock: ParallelLock = .{},
        io: std.Io,
        held: std.atomic.Value(bool) = .init(false),
        release_now: std.atomic.Value(bool) = .init(false),
        fn holder(s: *@This()) void {
            std.debug.assert(s.lock.acquire(s.io, null) == .acquired);
            s.held.store(true, .release);
            while (!s.release_now.load(.acquire)) std.atomic.spinLoopHint();
            std.debug.assert(s.lock.release(s.io));
        }
    };
    var shared = Shared{ .io = io };
    const t = try std.Thread.spawn(.{}, Shared.holder, .{&shared});
    while (!shared.held.load(.acquire)) std.atomic.spinLoopHint();
    // The lock is held by the peer: a 0-timeout try fails, and a short timed
    // wait times out rather than blocking forever.
    try std.testing.expectEqual(AcquireResult.timed_out, shared.lock.acquire(io, 0));
    try std.testing.expectEqual(AcquireResult.timed_out, shared.lock.acquire(io, 2 * std.time.ns_per_ms));
    shared.release_now.store(true, .release);
    t.join();
    // Now free: it acquires.
    try std.testing.expectEqual(AcquireResult.acquired, shared.lock.acquire(io, null));
    try std.testing.expect(shared.lock.release(io));
}
