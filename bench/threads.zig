//! Shared-realm Thread contention profile.
//!
//! `zig build threads-profile`
//!
//! This is a repeatable local profiler for issue #1's long-tail performance
//! work. It compares the shipping no-GIL default against the `.gil = true`
//! serialized fallback on the same workloads, so regressions in scaling or
//! newly-hot locks are visible without depending on wall-clock numbers alone.

const std = @import("std");
const js = @import("js");

const Scenario = struct {
    name: []const u8,
    setup: []const u8,
    rounds: usize,
};

const Timing = struct {
    ns: u64,
    stats: js.jsthread.ContentionStats,
};

const scenarios = [_]Scenario{
    .{
        .name = "independent compute",
        .setup =
        \\globalThis.worker = function(id) {
        \\  var s = id + 1;
        \\  for (var i = 0; i < 350000; i = i + 1)
        \\    s = (s + i + id) % 1000003;
        \\  return s;
        \\};
        ,
        .rounds = 5,
    },
    .{
        .name = "shared object props",
        .setup =
        \\globalThis.sharedObj = {};
        \\globalThis.worker = function(id) {
        \\  var acc = 0;
        \\  for (var i = 0; i < 6000; i = i + 1) {
        \\    var k = 'p' + ((i + id) & 31);
        \\    sharedObj[k] = (sharedObj[k] || 0) + 1;
        \\    acc = acc + (sharedObj[k] | 0);
        \\  }
        \\  return acc;
        \\};
        ,
        .rounds = 8,
    },
    .{
        .name = "shared array append",
        .setup =
        \\globalThis.sharedArray = [];
        \\globalThis.worker = function(id) {
        \\  var base = id * 5000;
        \\  for (var i = 0; i < 5000; i = i + 1)
        \\    sharedArray.push(base + i);
        \\  return sharedArray.length;
        \\};
        ,
        .rounds = 8,
    },
    .{
        .name = "typed-array atomics",
        .setup =
        \\globalThis.ab = new ArrayBuffer(4);
        \\globalThis.ia = new Int32Array(ab);
        \\globalThis.worker = function(id) {
        \\  var local = id;
        \\  for (var i = 0; i < 20000; i = i + 1)
        \\    local = local + Atomics.add(ia, 0, 1);
        \\  return local;
        \\};
        ,
        .rounds = 8,
    },
    .{
        .name = "lock contention",
        .setup =
        \\globalThis.lock = new Lock();
        \\globalThis.box = { n: 0 };
        \\globalThis.worker = function(id) {
        \\  var local = id;
        \\  for (var i = 0; i < 400; i = i + 1) {
        \\    lock.hold(function() {
        \\      var next = (box.n | 0) + 1;
        \\      for (var j = 0; j < 120; j = j + 1)
        \\        local = (local + next + j) % 1000003;
        \\      box.n = next;
        \\    });
        \\  }
        \\  return local;
        \\};
        ,
        .rounds = 5,
    },
    .{
        .name = "thread lifecycle",
        .setup =
        \\globalThis.worker = function(id) { return id + 1; };
        ,
        .rounds = 80,
    },
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn installHarness(ctx: *js.Context, scenario: Scenario) !void {
    _ = try ctx.evaluate(scenario.setup);
    _ = try ctx.evaluate(
        \\globalThis.spawnBatch = function(n) {
        \\  var ts = [];
        \\  for (var i = 0; i < n; i = i + 1)
        \\    ts.push(new Thread(worker, i));
        \\  var total = 0;
        \\  for (var j = 0; j < ts.length; j = j + 1)
        \\    total = total + ts[j].join();
        \\  return total;
        \\};
    );
}

fn timeScenario(gpa: std.mem.Allocator, io: std.Io, scenario: Scenario, workers: usize, gil: bool) !Timing {
    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true, .gil = gil });
    defer ctx.destroy();
    try installHarness(ctx, scenario);

    const src = try std.fmt.allocPrint(ctx.arena(), "spawnBatch({d})", .{workers});
    _ = try ctx.evaluate(src);

    js.jsthread.resetContentionStats();
    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < scenario.rounds) : (round += 1) {
        _ = try ctx.evaluate(src);
    }
    return .{
        .ns = @intCast(nowNs(io) - t0),
        .stats = js.jsthread.contentionStats(),
    };
}

fn printScenario(gpa: std.mem.Allocator, io: std.Io, scenario: Scenario, workers: []const usize) !void {
    std.debug.print("\n{s}\n", .{scenario.name});
    std.debug.print("{s:>8} {s:>14} {s:>14} {s:>12} {s:>12} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "threads",
        "no-gil ns",
        "gil ns",
        "no-gil x1",
        "vs gil",
        "ng events",
        "ng parks",
        "gil events",
        "gil parks",
    });

    var base_parallel: u64 = 1;
    for (workers) |n| {
        const parallel = try timeScenario(gpa, io, scenario, n, false);
        const gil = try timeScenario(gpa, io, scenario, n, true);
        const parallel_ns = parallel.ns;
        const gil_ns = gil.ns;
        if (n == workers[0]) base_parallel = @max(parallel_ns, 1);

        const scaling = @as(f64, @floatFromInt(n)) *
            @as(f64, @floatFromInt(base_parallel)) /
            @as(f64, @floatFromInt(@max(parallel_ns, 1)));
        const vs_gil = @as(f64, @floatFromInt(gil_ns)) /
            @as(f64, @floatFromInt(@max(parallel_ns, 1)));

        std.debug.print("{d:>8} {d:>14} {d:>14} {d:>11.2}x {d:>11.2}x {d:>10} {d:>10} {d:>10} {d:>10}\n", .{
            n,
            parallel_ns,
            gil_ns,
            scaling,
            vs_gil,
            parallel.stats.events(),
            parallel.stats.parks(),
            gil.stats.events(),
            gil.stats.parks(),
        });
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    const cores = std.Thread.getCpuCount() catch 4;
    const worker_counts = if (cores >= 8)
        &[_]usize{ 1, 2, 4, 8 }
    else if (cores >= 4)
        &[_]usize{ 1, 2, 4 }
    else
        &[_]usize{ 1, 2 };

    std.debug.print("zig-js shared-realm Thread contention profile\n", .{});
    std.debug.print("cores: {d}; no-GIL is Context.createWith(.{{ .enable_threads = true }}), serialized is .gil = true\n", .{cores});
    std.debug.print("events = logical contention (Lock/Condition/property wait/asyncHold); parks = timed wait/pump iterations including Thread.join\n", .{});

    for (scenarios) |scenario| try printScenario(gpa, io, scenario, worker_counts);
}
