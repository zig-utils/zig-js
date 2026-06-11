//! The VM lock for shared-Context threads (Phase 6 of
//! https://github.com/zig-utils/zig-js/issues/1, design in
//! docs/threads/P6-thread-api.md). One mutex serializes all heap and
//! interpreter access in an `enable_threads` Context: exactly one thread
//! runs JS at a time (concurrency, not parallelism), which is what makes
//! arena allocation, shape transitions, and every existing invariant safe
//! with zero changes. Threads interleave at the engines' step checkpoints
//! (`yieldIfContended`) and at every blocking point (join, Condition.wait,
//! Atomics.wait, Lock contention), which release the lock while parked.

const std = @import("std");
const agent = @import("agent.zig");

pub const Gil = struct {
    mutex: std.Io.Mutex = .init,
    /// The holding thread (0 = unheld) — written only by the holder right
    /// after acquire / before release; read by debug asserts and only
    /// meaningful when the reader holds the lock.
    holder: std.atomic.Value(u64) = .init(0),
    /// Threads currently blocked in `acquire` — the step checkpoints' cheap
    /// "should I yield" signal.
    contenders: std.atomic.Value(u32) = .init(0),
    /// The realm's run-loop TASK queue (engine tasks: lock-grant deliveries),
    /// distinct from per-thread microtask queues. Parks pump it (a parked
    /// thread's run loop still serves tasks; each pumped task drains
    /// microtasks as its own turn) — the semantics the threads corpus pins.
    /// Entries are type-erased `*jsthread.HoldJob` (owned by their arena).
    tasks: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// Per-realm Thread-id allocator: ids in [1, 0x7ffe], monotonically
    /// fresh (no reuse before a rebias lands), main = 0.
    next_thread_id: u32 = 1,

    fn currentId() u64 {
        return @intCast(std.Thread.getCurrentId());
    }

    pub fn acquire(g: *Gil) void {
        const io = agent.engineIo();
        if (!g.mutex.tryLock()) {
            _ = g.contenders.fetchAdd(1, .monotonic);
            g.mutex.lockUncancelable(io);
            _ = g.contenders.fetchSub(1, .monotonic);
        }
        g.holder.store(currentId(), .monotonic);
    }

    pub fn release(g: *Gil) void {
        g.holder.store(0, .monotonic);
        g.mutex.unlock(agent.engineIo());
    }

    pub fn holds(g: *const Gil) bool {
        return g.holder.load(.monotonic) == currentId();
    }

    /// Step-checkpoint yield: hand the lock over only when someone is
    /// actually waiting (uncontended cost: one relaxed load).
    pub fn yieldIfContended(g: *Gil) void {
        if (g.contenders.load(.monotonic) == 0) return;
        g.release();
        std.Thread.yield() catch {};
        g.acquire();
    }

    /// Park on `cond` with the GIL as the condition's mutex: atomically
    /// releases the lock while waiting and reacquires before returning —
    /// the primitive under `join`, `Condition.wait`, and friends.
    pub fn wait(g: *Gil, cond: *std.Io.Condition) void {
        const io = agent.engineIo();
        g.holder.store(0, .monotonic);
        cond.waitUncancelable(io, &g.mutex);
        g.holder.store(currentId(), .monotonic);
    }

    /// `wait` with a deadline (property-Atomics timed waits). Reacquires the
    /// lock before returning either way.
    pub fn waitTimeout(g: *Gil, cond: *std.Io.Condition, timeout: std.Io.Timeout) error{Timeout}!void {
        const io = agent.engineIo();
        g.holder.store(0, .monotonic);
        defer g.holder.store(currentId(), .monotonic);
        cond.waitTimeout(io, &g.mutex, timeout) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            error.Canceled => {},
        };
    }
};

test "gil: mutual exclusion and contended yield handover" {
    var g = Gil{};
    const Worker = struct {
        fn run(gil: *Gil, counter: *u64) void {
            gil.acquire();
            defer gil.release();
            counter.* += 1; // data access is GIL-protected
        }
    };
    var counter: u64 = 0;

    // Plain mutual exclusion: four threads through the lock.
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &g, &counter });
    for (threads) |t| t.join();
    g.acquire();
    try std.testing.expect(g.holds());
    try std.testing.expectEqual(@as(u64, 4), counter);

    // Contended yield: while we hold, a fifth thread queues; one
    // yieldIfContended must hand the lock over and reacquire after it.
    const t5 = try std.Thread.spawn(.{}, Worker.run, .{ &g, &counter });
    while (g.contenders.load(.monotonic) == 0) std.atomic.spinLoopHint();
    g.yieldIfContended();
    try std.testing.expect(g.holds());
    try std.testing.expectEqual(@as(u64, 5), counter);
    g.release();
    try std.testing.expect(!g.holds());
    t5.join();
}
