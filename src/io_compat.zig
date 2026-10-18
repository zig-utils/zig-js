//! Compatibility shims for `std.Io` primitives that this engine's threading
//! code targets but that are absent from the pinned Zig 0.18-dev std on some
//! checkouts.
//!
//! `std.Io.Condition.waitTimeout` — a timed condition wait — is the one the
//! engine relies on (property/typed-array `Atomics.wait` deadlines, `Thread`
//! join timeouts, worker channel receives, the parallel `Lock` park). The
//! installed std ships `wait`/`waitUncancelable`/`signal`/`broadcast` on
//! `Condition` and a `waitTimeout` on `Io.Event`, but not on `Condition`.
//!
//! `conditionWaitTimeout` reproduces std's own `Condition.waitInner` exactly —
//! it registers in the condition's waiter count so `signal`/`broadcast` will
//! wake it, and consumes a pending signal on wake so a signal can't be stranded
//! — but blocks with `io.futexWaitTimeout` against an absolute deadline and
//! returns `error.Timeout` once that deadline has passed. Spurious futex
//! wakeups re-arm against the same (absolute) deadline rather than being
//! mistaken for a timeout; cancelation surfaces as `error.Canceled`. The mutex
//! is reacquired before returning on every path, matching `Condition.wait`.
//!
//! Swap every `cond.waitTimeout(io, &mutex, timeout)` call site to
//! `io_compat.conditionWaitTimeout(cond, io, &mutex, timeout)`. When a future
//! std restores `Condition.waitTimeout`, this file (and those call sites) can be
//! reverted mechanically.

const std = @import("std");

const Io = std.Io;
const Condition = std.Io.Condition;
const Mutex = std.Io.Mutex;

/// Sandboxed Apple hosts cannot replace their process. Construct the backend
/// with that policy before instantiating desktop process operations; preserve
/// the standard futex, clock, file and network operations used by the engine.
pub fn threadedIo(threaded: *std.Io.Threaded) Io {
    if (comptime switch (@import("builtin").os.tag) {
        .ios, .tvos, .visionos, .watchos => true,
        else => false,
    }) return sandboxedThreadedIo(threaded);
    return threaded.io();
}

fn sandboxedThreadedIo(threaded: *std.Io.Threaded) Io {
    const vtable = comptime blk: {
        var table = std.Io.Threaded.io(undefined).vtable.*;
        table.processReplace = processReplaceUnsupported;
        break :blk table;
    };
    return .{ .userdata = threaded, .vtable = &vtable };
}

fn processReplaceUnsupported(_: ?*anyopaque, _: std.process.ReplaceOptions) std.process.ReplaceError {
    return error.OperationUnsupported;
}

test "sandboxed engine Io refuses process replacement and retains blocking primitives" {
    var threaded: std.Io.Threaded = undefined;
    const io = sandboxedThreadedIo(&threaded);
    try std.testing.expectEqual(error.OperationUnsupported, std.process.replace(io, .{ .argv = &.{"/never-executed"} }));
    try std.testing.expectEqual(@as(?*anyopaque, &threaded), io.userdata);
    const standard = threaded.io();
    inline for (.{ "futexWait", "futexWake", "now", "sleep" }) |name| {
        try std.testing.expectEqual(@field(standard.vtable, name), @field(io.vtable, name));
    }
}

/// Error set matching what a real `Condition.waitTimeout` returns and what every
/// call site already switches on.
pub const WaitTimeoutError = error{ Timeout, Canceled };

/// Timed `Condition.wait`. See the file header for the rationale.
pub fn conditionWaitTimeout(
    cond: *Condition,
    io: Io,
    mutex: *Mutex,
    timeout: Io.Timeout,
) WaitTimeoutError!void {
    // Resolve to an absolute deadline once, so re-arming after a spurious
    // wakeup never extends the wait. `null` means no deadline (`.none`).
    const deadline: ?Io.Clock.Timestamp = timeout.toTimestamp(io);

    var epoch = cond.epoch.load(.acquire); // ordered before the state load below
    _ = cond.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);

    mutex.unlock(io);
    defer mutex.lockUncancelable(io);

    while (true) {
        const iter_timeout: Io.Timeout = if (deadline) |ts| .{ .deadline = ts } else .none;
        const wait_result = io.futexWaitTimeout(u32, &cond.epoch.raw, epoch, iter_timeout);

        epoch = cond.epoch.load(.acquire);

        // Consume a pending signal first — even on a timed-out/spurious/canceled
        // wake — so a concurrent `signal`/`broadcast` can't strand a signal in
        // the state with no waiter to take it (this also deregisters us).
        {
            var prev_state = cond.state.load(.monotonic);
            while (prev_state.signals > 0) {
                prev_state = cond.state.cmpxchgWeak(prev_state, .{
                    .waiters = prev_state.waiters - 1,
                    .signals = prev_state.signals - 1,
                }, .acquire, .monotonic) orelse return; // took a signal: a real wakeup
            }
        }

        // No signal available: cancelation, deadline, or a spurious wakeup.
        wait_result catch {
            _ = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
            return error.Canceled;
        };

        if (deadline) |ts| {
            const now_ts = Io.Clock.Timestamp.now(io, ts.clock);
            if (ts.compare(.lte, now_ts)) {
                _ = cond.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
                return error.Timeout;
            }
        }
        // Spurious wakeup with time still remaining: loop and re-wait.
    }
}
