//! Shared-realm Thread contention and isolated Worker profile.
//!
//! `zig build threads-profile`
//!
//! This is a repeatable local profiler for issue #1's long-tail performance
//! work. The shared-realm section compares the shipping no-GIL default against
//! the `.gil = true` serialized fallback on the same workloads, so regressions
//! in scaling or newly-hot locks are visible without depending on wall-clock
//! numbers alone. The Worker section separately attributes structured-clone
//! message traffic and spawn/post/receive/join/destroy lifecycle cost.

const std = @import("std");
const js = @import("js");

const Scenario = struct {
    name: []const u8,
    setup: []const u8,
    rounds: usize,
    flush_tasks_after: bool = false,
};

const Timing = struct {
    ns: u64,
    stats: js.jsthread.ContentionStats,
};

const worker_message_batches = 160;
const worker_empty_receive_polls = 3000;
const worker_lifecycle_rounds = 12;

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
        .name = "property wait/notify",
        .setup =
        \\globalThis.propBox = { epoch: 0, ready: 0 };
        \\globalThis.worker = function(id) {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  if (workers <= 1) return id + 1;
        \\  var rounds = 180;
        \\  if (id === 0) {
        \\    for (var i = 0; i < rounds; i = i + 1) {
        \\      var need = (workers - 1) * (i + 1);
        \\      while (Atomics.load(propBox, 'ready') < need)
        \\        ;
        \\      Atomics.store(propBox, 'epoch', i + 1);
        \\      Atomics.notify(propBox, 'epoch', workers);
        \\    }
        \\    return rounds;
        \\  }
        \\  var score = 0;
        \\  for (var j = 0; j < rounds; j = j + 1) {
        \\    var target = j + 1;
        \\    Atomics.add(propBox, 'ready', 1);
        \\    Atomics.notify(propBox, 'ready');
        \\    while (Atomics.load(propBox, 'epoch') < target) {
        \\      var cur = Atomics.load(propBox, 'epoch');
        \\      var r = Atomics.wait(propBox, 'epoch', cur, 100);
        \\      if (r === 'ok' || r === 'not-equal' || r === 'timed-out') score = score + 1;
        \\    }
        \\  }
        \\  return score;
        \\};
        ,
        .rounds = 5,
    },
    .{
        .name = "condition wait/notify",
        .setup =
        \\globalThis.condLock = new Lock();
        \\globalThis.cond = new Condition();
        \\globalThis.condBox = { epoch: 0, ready: 0 };
        \\globalThis.worker = function(id) {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  if (workers <= 1) return id + 1;
        \\  var rounds = 120;
        \\  if (id === 0) {
        \\    for (var i = 0; i < rounds; i = i + 1) {
        \\      var need = (workers - 1) * (i + 1);
        \\      while (Atomics.load(condBox, 'ready') < need)
        \\        ;
        \\      condLock.hold(function() {
        \\        condBox.epoch = i + 1;
        \\        cond.notifyAll();
        \\      });
        \\    }
        \\    return rounds;
        \\  }
        \\  var score = 0;
        \\  for (var j = 0; j < rounds; j = j + 1) {
        \\    condLock.hold(function() {
        \\      var target = j + 1;
        \\      Atomics.add(condBox, 'ready', 1);
        \\      Atomics.notify(condBox, 'ready');
        \\      while (condBox.epoch < target)
        \\        cond.wait(condLock);
        \\      score = score + condBox.epoch;
        \\    });
        \\  }
        \\  return score;
        \\};
        ,
        .rounds = 5,
    },
    .{
        .name = "property waitAsync timeout",
        .setup =
        \\globalThis.propAsyncBox = { slot: 0, seen: 0 };
        \\globalThis.worker = function(id) {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  var tickets = workers <= 1 ? 6 : 18;
        \\  for (var i = 0; i < tickets; i = i + 1) {
        \\    var r = Atomics.waitAsync(propAsyncBox, 'slot', 0, 1);
        \\    if (r.async) {
        \\      r.value.then(function(v) {
        \\        if (v === 'timed-out') Atomics.add(propAsyncBox, 'seen', 1);
        \\      });
        \\    }
        \\  }
        \\  return id + 1;
        \\};
        ,
        .rounds = 5,
    },
    .{
        .name = "condition asyncWait",
        .setup =
        \\globalThis.asyncCondLock = new Lock();
        \\globalThis.asyncCond = new Condition();
        \\globalThis.asyncCondBox = { ready: 0, seen: 0 };
        \\globalThis.worker = function(id) {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  if (workers <= 1) return id + 1;
        \\  var rounds = 30;
        \\  if (id === 0) {
        \\    for (var i = 0; i < rounds; i = i + 1) {
        \\      var need = (workers - 1) * (i + 1);
        \\      while (Atomics.load(asyncCondBox, 'ready') < need)
        \\        ;
        \\      asyncCond.notifyAll();
        \\    }
        \\    return rounds;
        \\  }
        \\  for (var j = 0; j < rounds; j = j + 1) {
        \\    asyncCondLock.asyncHold(function() {
        \\      var wait = asyncCond.asyncWait(asyncCondLock);
        \\      Atomics.add(asyncCondBox, 'ready', 1);
        \\      Atomics.notify(asyncCondBox, 'ready');
        \\      return wait.then(function(release) {
        \\        asyncCondBox.seen = (asyncCondBox.seen | 0) + 1;
        \\        release();
        \\      });
        \\    });
        \\  }
        \\  return id + 1;
        \\};
        \\globalThis.__profileFlush = function() {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  for (var i = 0; i < workers * 30; i = i + 1)
        \\    asyncCond.notifyAll();
        \\};
        ,
        .rounds = 5,
        .flush_tasks_after = true,
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
        .name = "asyncHold delivery",
        .setup =
        \\globalThis.asyncLock = new Lock();
        \\globalThis.asyncBox = { n: 0 };
        \\globalThis.worker = function(id) {
        \\  for (var i = 0; i < 50; i = i + 1) {
        \\    asyncLock.asyncHold(function() {
        \\      asyncBox.n = (asyncBox.n | 0) + 1;
        \\      return asyncBox.n;
        \\    });
        \\  }
        \\  return id + 1;
        \\};
        ,
        .rounds = 10,
    },
    .{
        .name = "asyncHold observed callbacks",
        .setup =
        \\globalThis.asyncLock = new Lock();
        \\globalThis.asyncBox = { n: 0, seen: 0 };
        \\globalThis.worker = function(id) {
        \\  for (var i = 0; i < 35; i = i + 1) {
        \\    asyncLock.asyncHold(function() {
        \\      asyncBox.n = (asyncBox.n | 0) + 1;
        \\      return asyncBox.n;
        \\    }).then(function(v) {
        \\      asyncBox.seen = (asyncBox.seen | 0) + (v > 0 ? 1 : 0);
        \\    });
        \\  }
        \\  return id + 1;
        \\};
        ,
        .rounds = 10,
    },
    .{
        .name = "asyncHold release functions",
        .setup =
        \\globalThis.asyncLock = new Lock();
        \\globalThis.asyncBox = { n: 0 };
        \\globalThis.worker = function(id) {
        \\  for (var i = 0; i < 35; i = i + 1) {
        \\    asyncLock.asyncHold().then(function(release) {
        \\      asyncBox.n = (asyncBox.n | 0) + 1;
        \\      release();
        \\    });
        \\  }
        \\  return id + 1;
        \\};
        ,
        .rounds = 10,
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
        \\  globalThis.__profileWorkers = n;
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
    errdefer js.jsthread.disableContentionStats();
    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < scenario.rounds) : (round += 1) {
        _ = try ctx.evaluate(src);
    }
    if (scenario.flush_tasks_after) {
        _ = try ctx.evaluate("if (typeof __profileFlush === 'function') __profileFlush();");
        var machine = ctx.interpreter();
        js.jsthread.pumpTasks(&machine);
        try machine.drainMicrotasks();
    }
    const stats = js.jsthread.contentionStats();
    js.jsthread.disableContentionStats();
    return .{
        .ns = @intCast(nowNs(io) - t0),
        .stats = stats,
    };
}

fn printScenario(gpa: std.mem.Allocator, io: std.Io, scenario: Scenario, workers: []const usize) !void {
    std.debug.print("\n{s}\n", .{scenario.name});
    std.debug.print("{s:>8} {s:>14} {s:>14} {s:>12} {s:>12}" ++
        " {s:>10} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}" ++
        " {s:>10} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "threads",
        "no-gil ns",
        "gil ns",
        "no-gil x1",
        "vs gil",
        "ng events",
        "ng parks",
        "ng joins",
        "ng lock",
        "ng cond",
        "ng prop",
        "ng async",
        "ng done",
        "ng empty",
        "ng jobs",
        "gil events",
        "gil parks",
        "gil joins",
        "gil lock",
        "gil cond",
        "gil prop",
        "gil async",
        "gil done",
        "gil empty",
        "gil jobs",
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

        std.debug.print("{d:>8} {d:>14} {d:>14} {d:>11.2}x {d:>11.2}x" ++
            " {d:>10} {d:>10} {d:>10} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>10} {d:>10}" ++
            " {d:>10} {d:>10} {d:>10} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>10} {d:>10}\n", .{
            n,
            parallel_ns,
            gil_ns,
            scaling,
            vs_gil,
            parallel.stats.events(),
            parallel.stats.parks(),
            parallel.stats.thread_join_parks,
            parallel.stats.lock_wait_parks,
            parallel.stats.condition_wait_parks,
            parallel.stats.property_wait_parks,
            parallel.stats.asyncWaits(),
            parallel.stats.asyncSettled(),
            parallel.stats.task_pump_empty,
            parallel.stats.task_pump_jobs,
            gil.stats.events(),
            gil.stats.parks(),
            gil.stats.thread_join_parks,
            gil.stats.lock_wait_parks,
            gil.stats.condition_wait_parks,
            gil.stats.property_wait_parks,
            gil.stats.asyncWaits(),
            gil.stats.asyncSettled(),
            gil.stats.task_pump_empty,
            gil.stats.task_pump_jobs,
        });
    }
}

fn cleanupWorkers(workers: []const *js.Worker) void {
    for (workers) |w| w.terminate();
    for (workers) |w| {
        w.join();
        w.destroy();
    }
}

fn expectWorkerReply(reply: js.Value, expected: f64) !void {
    if (!reply.isNumber() or reply.asNum() != expected) return error.UnexpectedWorkerReply;
}

fn timeWorkerMessages(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, batches: usize) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {
        \\  postMessage(e.data + 1);
        \\};
    ;

    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    var spawned: usize = 0;
    errdefer cleanupWorkers(workers[0..spawned]);
    while (spawned < worker_count) : (spawned += 1) {
        workers[spawned] = try js.Worker.spawn(src);
    }

    // Warm each worker so the timed section is dominated by message traffic,
    // not first-delivery startup.
    for (workers) |w| try w.postMessage(&machine, js.Value.num(0));
    for (workers) |w| {
        const reply = (try w.receive(&machine, 10_000)) orelse return error.WorkerTimeout;
        try expectWorkerReply(reply, 1);
    }

    const t0 = nowNs(io);
    var batch: usize = 0;
    while (batch < batches) : (batch += 1) {
        const base = batch * worker_count;
        for (workers, 0..) |w, i| {
            try w.postMessage(&machine, js.Value.num(@floatFromInt(base + i)));
        }
        for (workers, 0..) |w, i| {
            const reply = (try w.receive(&machine, 10_000)) orelse return error.WorkerTimeout;
            const expected: f64 = @floatFromInt(base + i + 1);
            try expectWorkerReply(reply, expected);
        }
    }
    const ns: u64 = @intCast(nowNs(io) - t0);

    for (workers) |w| w.close();
    for (workers) |w| {
        w.join();
        w.destroy();
    }
    return ns;
}

fn timeWorkerEmptyReceives(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, polls: usize) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {};
    ;

    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    var spawned: usize = 0;
    errdefer cleanupWorkers(workers[0..spawned]);
    while (spawned < worker_count) : (spawned += 1) {
        workers[spawned] = try js.Worker.spawn(src);
    }

    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < polls) : (round += 1) {
        for (workers) |w| {
            if ((try w.receive(&machine, 0)) != null) return error.UnexpectedWorkerReply;
        }
    }
    const ns: u64 = @intCast(nowNs(io) - t0);

    for (workers) |w| w.terminate();
    for (workers) |w| {
        w.join();
        w.destroy();
    }
    return ns;
}

fn timeWorkerLifecycle(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {
        \\  postMessage(e.data + 1);
        \\  close();
        \\};
    ;

    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var spawned: usize = 0;
        errdefer cleanupWorkers(workers[0..spawned]);
        while (spawned < worker_count) : (spawned += 1) {
            workers[spawned] = try js.Worker.spawn(src);
        }

        const base = round * worker_count;
        for (workers) |w| try w.postMessage(&machine, js.Value.num(@floatFromInt(base)));
        for (workers) |w| {
            const reply = (try w.receive(&machine, 10_000)) orelse return error.WorkerTimeout;
            const expected: f64 = @floatFromInt(base + 1);
            try expectWorkerReply(reply, expected);
        }
        for (workers) |w| {
            w.join();
            w.destroy();
        }
    }
    return @intCast(nowNs(io) - t0);
}

fn printWorkerProfile(gpa: std.mem.Allocator, io: std.Io, workers: []const usize) !void {
    std.debug.print("\nWorker message/lifecycle profile\n", .{});
    std.debug.print("isolated Worker API: one Context per OS thread, structured-clone inbox/outbox, no shared-realm .gil fallback\n", .{});
    std.debug.print("{s:>8} {s:>14} {s:>12} {s:>14} {s:>12} {s:>14} {s:>12} {s:>12}\n", .{
        "workers",
        "message ns",
        "ns/msg",
        "empty recv ns",
        "ns/poll",
        "lifecycle ns",
        "ns/worker",
        "spawns",
    });

    for (workers) |n| {
        const message_ns = try timeWorkerMessages(gpa, io, n, worker_message_batches);
        const total_messages: u64 = @intCast(n * worker_message_batches);
        const empty_receive_ns = try timeWorkerEmptyReceives(gpa, io, n, worker_empty_receive_polls);
        const total_empty_receives: u64 = @intCast(n * worker_empty_receive_polls);
        const lifecycle_ns = try timeWorkerLifecycle(gpa, io, n, worker_lifecycle_rounds);
        const total_spawns: u64 = @intCast(n * worker_lifecycle_rounds);

        std.debug.print("{d:>8} {d:>14} {d:>12} {d:>14} {d:>12} {d:>14} {d:>12} {d:>12}\n", .{
            n,
            message_ns,
            message_ns / @max(total_messages, 1),
            empty_receive_ns,
            empty_receive_ns / @max(total_empty_receives, 1),
            lifecycle_ns,
            lifecycle_ns / @max(total_spawns, 1),
            total_spawns,
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
    std.debug.print("joins = Thread.join timed wait/pump iterations, separated from other park sources for lifecycle attribution\n", .{});
    std.debug.print("lock/cond/prop = park iterations attributed to contended Lock.hold, Condition.wait, and property Atomics.wait\n", .{});
    std.debug.print("async/done = Condition.asyncWait and property waitAsync registrations / completed condition reacquires plus settled property waitAsync tickets\n", .{});
    std.debug.print("empty/jobs = run-loop task-pump empty fast-path hits / delivered asyncHold jobs\n", .{});

    for (scenarios) |scenario| try printScenario(gpa, io, scenario, worker_counts);
    try printWorkerProfile(gpa, io, worker_counts);
}
