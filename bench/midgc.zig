//! Internal mid-script parallel-GC convergence profile.
//!
//! `zig build midgc-profile`

const std = @import("std");
const js = @import("js");

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    const ctx = try js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    });
    defer ctx.destroy();

    const source =
        \\(() => {
        \\  const threads = [];
        \\  for (let t = 0; t < 4; t++) threads.push(new Thread(() => {
        \\    const keep = [];
        \\    for (let round = 0; round < 8; round++) {
        \\      for (let i = 0; i < 700; i++) {
        \\        const value = { thread: t, round, i, nested: { value: i + round } };
        \\        if ((i & 127) === 0) keep.push(value);
        \\      }
        \\      let spin = 0;
        \\      for (let i = 0; i < 6000; i++) spin = (spin + i + round) & 0x3fffffff;
        \\      if (spin < 0) keep.push(spin);
        \\    }
        \\    return keep.length;
        \\  }));
        \\  let total = 0;
        \\  for (const thread of threads) total += thread.join();
        \\  return total;
        \\})()
    ;

    const started = nowNs(io);
    var runs: usize = 0;
    while (runs < 8) : (runs += 1) {
        _ = try ctx.evaluate(source);
        if (ctx.gc_par_collections.load(.monotonic) > 0 and runs >= 2) break;
    }
    const elapsed: u64 = @intCast(nowNs(io) - started);

    std.debug.print("zig-js mid-script parallel GC telemetry (internal testing policy)\n", .{});
    std.debug.print(
        "{s:>6} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>11} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>11} {s:>9} {s:>11} {s:>12}\n",
        .{ "runs", "attempts", "sweeps", "aborts", "pub-abort", "rnd-abort", "generations", "wait-poll", "wait-max", "fin-retry", "retry-max", "born-grow", "ext-rnd", "deferred", "run-peer", "park-peer", "published", "backoff", "pause-us", "pause-max-us" },
    );
    std.debug.print(
        "{d:>6} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>11} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>11} {d:>9} {d:>11} {d:>12}  wall={d} us\n",
        .{
            runs + 1,
            ctx.gc_par_attempts.load(.monotonic),
            ctx.gc_par_collections.load(.monotonic),
            ctx.gc_par_aborts.load(.monotonic),
            ctx.gc_par_publication_timeout_aborts.load(.monotonic),
            ctx.gc_par_round_limit_aborts.load(.monotonic),
            ctx.gc_par_generations.load(.monotonic),
            ctx.gc_par_publication_wait_iterations.load(.monotonic),
            ctx.gc_par_publication_wait_iterations_max.load(.monotonic),
            ctx.gc_par_finish_retries.load(.monotonic),
            ctx.gc_par_finish_retries_max.load(.monotonic),
            ctx.gc_par_born_growth_rounds.load(.monotonic),
            ctx.gc_par_round_extension_rounds.load(.monotonic),
            ctx.gc_par_deferred_rounds.load(.monotonic),
            ctx.gc_par_running_peer_requests.load(.monotonic),
            ctx.gc_par_parked_peer_observations.load(.monotonic),
            ctx.gc_par_peer_publications.load(.monotonic),
            ctx.gc_par_backoff_skips.load(.monotonic),
            ctx.gc_par_pause_ns_total.load(.monotonic) / 1_000,
            ctx.gc_par_pause_ns_max.load(.monotonic) / 1_000,
            elapsed / 1_000,
        },
    );
}
