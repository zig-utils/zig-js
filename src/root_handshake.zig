//! Ragged (soft-handshake) root publication for parallel mid-script GC
//! (issue #1, Phase 7 / M3).
//!
//! Background — why not a stop-the-world barrier. The first attempt at
//! collecting mid-script while multiple mutators run *without* the GIL used a
//! global STW barrier: at a safepoint every mutator blocked until all had
//! arrived, then the collector ran. That deadlocked. A mutator spinning to
//! *acquire* a per-structure lock (e.g. `Object.property_lock`) cannot reach
//! its safepoint, and the thread holding that lock had already blocked at the
//! barrier — so the lock was never released and the barrier never completed
//! (`docs/threads/P7-gc-design.md`). The defect is fundamental to any protocol
//! that blocks a mutator at a point where it may transitively hold a lock.
//!
//! This primitive removes the blocking. The collector *requests* roots; each
//! mutator, at its own safepoint (between bytecodes, where it provably holds no
//! per-structure lock), scans its own native stack + precise VM roots, feeds
//! them to the marker, acknowledges, and **keeps running**. No mutator ever
//! waits for another, so a mutator can always make forward progress to release
//! any lock it holds. Only the collector waits — on a monotonically increasing
//! ack counter that running mutators are guaranteed to advance.
//!
//! Each mutator scans *its own* stack rather than having the collector scan a
//! foreign one: a running thread's stack changes underfoot, so only the owner
//! can scan it soundly without first freezing it (which is the blocking we are
//! avoiding). Parked threads are handled separately — their stacks are frozen
//! and already published via `gil.zig`'s park records.
//!
//! Single-collector assumption: cycle ids come from a process-global monotonic
//! counter, so a handshake never reuses an id even across multiple `Context`s
//! sharing this thread's `published` slot.

const std = @import("std");
const builtin = @import("builtin");

/// Process-global source of unique cycle ids. Starts at 1 so 0 means "no
/// request" / "never published".
var next_cycle: std.atomic.Value(u64) = .init(1);

pub const RootHandshake = struct {
    /// Cycle id the collector currently wants roots for; 0 when idle.
    request: std.atomic.Value(u64) = .init(0),
    /// Mutators that have published for the current request.
    acks: std.atomic.Value(u32) = .init(0),
    /// Mutators the collector expects to publish for this request.
    expected: std.atomic.Value(u32) = .init(0),

    /// The cycle this thread last published for. Per-thread; compared against
    /// the (globally unique) request id, so it disambiguates across handshakes.
    threadlocal var published: u64 = 0;

    /// Collector: open a request expecting `expected_mutators` running threads
    /// to publish. Returns the unique cycle id. The `request` store is `release`
    /// so a mutator that acquire-loads it also observes the reset acks/expected.
    pub fn open(self: *RootHandshake, expected_mutators: u32) u64 {
        const cycle = next_cycle.fetchAdd(1, .monotonic);
        self.acks.store(0, .monotonic);
        self.expected.store(expected_mutators, .monotonic);
        self.request.store(cycle, .release);
        return cycle;
    }

    /// Mutator at a safepoint: if a fresh request is pending and this thread has
    /// not yet published for it, run `publish(arg)` then acknowledge. Bounded
    /// and non-blocking — returns at once when nothing is pending. The caller
    /// must hold no per-structure lock here (safepoints are between bytecodes).
    ///
    /// The ack `fetchAdd` is `release` and `waitForRoots` acquire-loads the same
    /// counter, so the collector observes every write `publish` made (the marks)
    /// before it counts the ack.
    pub fn serviceSafepoint(self: *RootHandshake, arg: anytype, comptime publish: fn (@TypeOf(arg)) void) void {
        const req = self.request.load(.acquire);
        if (req == 0 or published == req) return;
        publish(arg);
        published = req;
        _ = self.acks.fetchAdd(1, .release);
    }

    /// Collector: spin until every expected mutator has published. Sound to spin
    /// because running mutators never block, so they reach their safepoints and
    /// ack; only already-parked mutators (counted out of `expected`) won't, and
    /// their roots are published via the park-record path instead.
    pub fn waitForRoots(self: *const RootHandshake) void {
        while (self.acks.load(.acquire) < self.expected.load(.acquire))
            std.atomic.spinLoopHint();
    }

    /// Whether all expected mutators have published (non-blocking poll).
    pub fn allPublished(self: *const RootHandshake) bool {
        return self.acks.load(.acquire) >= self.expected.load(.acquire);
    }

    /// Collector: close the request once roots are gathered.
    pub fn close(self: *RootHandshake) void {
        self.request.store(0, .release);
    }
};

test "RootHandshake: collector gathers every running mutator's roots without blocking them" {
    // Reproduces the exact hazard the STW barrier deadlocked on: mutators
    // repeatedly take and release a contended structure lock while servicing
    // safepoints. With the ragged handshake the collector must still gather an
    // ack from every mutator — none can be stuck holding the lock, because
    // serviceSafepoint never blocks. TSan-clean proves the publish→ack→observe
    // ordering is race-free.
    if (builtin.single_threaded) return error.SkipZigTest;

    const nworkers = 4;
    const Shared = struct {
        hs: RootHandshake = .{},
        lock: std.atomic.Mutex = .unlocked, // the same spin-lock type as the per-structure locks
        guarded: u64 = 0, // mutated only under `lock`
        published_mask: std.atomic.Value(u32) = .init(0), // bit i set once worker i publishes
        go: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
    };
    const WorkerCtx = struct {
        s: *Shared,
        idx: usize,
        fn publish(wc: *@This()) void {
            // The mutator's own root-publication work for this cycle.
            _ = wc.s.published_mask.fetchOr(@as(u32, 1) << @intCast(wc.idx), .release);
        }
        fn run(wc: *@This()) void {
            while (!wc.s.go.load(.acquire)) std.atomic.spinLoopHint();
            // Loop until the collector says stop, so every worker is guaranteed
            // to reach safepoints *after* the request is opened.
            while (!wc.s.stop.load(.acquire)) {
                // Contended "mutation" under the structure lock (spin to acquire,
                // exactly as the per-structure locks do).
                while (!wc.s.lock.tryLock()) std.atomic.spinLoopHint();
                wc.s.guarded += 1;
                wc.s.lock.unlock();
                // Safepoint: between mutations, holding no lock.
                wc.s.hs.serviceSafepoint(wc, @This().publish);
            }
        }
    };

    var shared = Shared{};
    var ctxs: [nworkers]WorkerCtx = undefined;
    for (&ctxs, 0..) |*c, i| c.* = .{ .s = &shared, .idx = i };
    var pool: [nworkers]std.Thread = undefined;
    for (&pool, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctxs[i]});

    // Collector: let the workers spin up, open a request, gather all roots.
    shared.go.store(true, .release);
    const cycle = shared.hs.open(nworkers);
    try std.testing.expect(cycle != 0);
    shared.hs.waitForRoots(); // must return — no deadlock despite lock contention
    shared.hs.close();
    shared.stop.store(true, .release);
    for (&pool) |*th| th.join();

    // Every mutator published exactly its own roots; the collector saw them all.
    try std.testing.expectEqual(@as(u32, nworkers), shared.hs.acks.load(.acquire));
    const all_bits: u32 = (@as(u32, 1) << nworkers) - 1;
    try std.testing.expectEqual(all_bits, shared.published_mask.load(.acquire));
    try std.testing.expect(shared.guarded > 0); // real contended work happened
}

test "RootHandshake: idle safepoints are no-ops and reopened cycles re-collect" {
    // With no open request, serviceSafepoint must do nothing (the common case —
    // a safepoint with no collection pending). After a cycle completes, opening
    // a fresh cycle re-collects from the same thread (distinct cycle id beats
    // the per-thread `published` guard).
    var hs = RootHandshake{};
    var calls: usize = 0;
    const Cb = struct {
        fn publish(p: *usize) void {
            p.* += 1;
        }
    };

    // Idle: no request → no publish.
    hs.serviceSafepoint(&calls, Cb.publish);
    try std.testing.expectEqual(@as(usize, 0), calls);

    // Cycle 1: one publish, idempotent within the cycle.
    _ = hs.open(1);
    hs.serviceSafepoint(&calls, Cb.publish);
    hs.serviceSafepoint(&calls, Cb.publish); // already published this cycle
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(hs.allPublished());
    hs.close();

    // Idle again.
    hs.serviceSafepoint(&calls, Cb.publish);
    try std.testing.expectEqual(@as(usize, 1), calls);

    // Cycle 2: fresh id → publishes again.
    _ = hs.open(1);
    hs.serviceSafepoint(&calls, Cb.publish);
    try std.testing.expectEqual(@as(usize, 2), calls);
    hs.close();
}
