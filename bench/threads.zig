//! Shared-realm Thread contention and isolated Worker profile.
//!
//! `zig build threads-profile`
//!
//! This is a repeatable local profiler for issue #1's long-tail performance
//! work. The shared-realm section compares the shipping no-GIL default against
//! the `.gil = true` serialized fallback on the same workloads, so regressions
//! in scaling or newly-hot locks are visible without depending on wall-clock
//! numbers alone. The Worker section separately attributes structured-clone
//! message traffic, empty receive polling, and self-close / host-close /
//! terminate teardown cost.

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
const worker_host_close_rounds = 12;
const worker_terminate_rounds = 12;

const ModuleMessageProfileHost = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "ops.js",
            .source =
            \\export function reply(v) { return v + 1; }
            ,
        },
        .{
            .path = "entry.js",
            .source =
            \\import { reply } from "./ops.js";
            \\globalThis.onmessage = function(e) {
            \\  postMessage(reply(e.data));
            \\};
            ,
        },
    };

    fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        const name = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, name)) {
                out_path.* = entry.path;
                return entry.source;
            }
        }
        return null;
    }

    fn host() js.Context.ModuleHost {
        return .{ .ctx = &host_ctx, .load = load };
    }
};

const ModuleLifecycleProfileHost = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "ops.js",
            .source =
            \\export function reply(v) { return v + 1; }
            ,
        },
        .{
            .path = "entry.js",
            .source =
            \\import { reply } from "./ops.js";
            \\globalThis.onmessage = function(e) {
            \\  postMessage(reply(e.data));
            \\  close();
            \\};
            ,
        },
    };

    fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        const name = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, name)) {
                out_path.* = entry.path;
                return entry.source;
            }
        }
        return null;
    }

    fn host() js.Context.ModuleHost {
        return .{ .ctx = &host_ctx, .load = load };
    }
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
        .name = "condition asyncWait multi-lock",
        .setup =
        \\globalThis.asyncMultiCond = new Condition();
        \\globalThis.asyncMultiLocks = [new Lock(), new Lock(), new Lock(), new Lock()];
        \\globalThis.asyncMultiBox = { ready: 0, seen: 0 };
        \\globalThis.worker = function(id) {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  if (workers <= 1) return id + 1;
        \\  var rounds = 24;
        \\  if (id === 0) {
        \\    for (var i = 0; i < rounds; i = i + 1) {
        \\      var need = (workers - 1) * (i + 1);
        \\      while (Atomics.load(asyncMultiBox, 'ready') < need)
        \\        ;
        \\      asyncMultiCond.notifyAll();
        \\    }
        \\    return rounds;
        \\  }
        \\  var lock = asyncMultiLocks[id & 3];
        \\  for (var j = 0; j < rounds; j = j + 1) {
        \\    lock.asyncHold(function() {
        \\      var wait = asyncMultiCond.asyncWait(lock);
        \\      Atomics.add(asyncMultiBox, 'ready', 1);
        \\      Atomics.notify(asyncMultiBox, 'ready');
        \\      return wait.then(function(release) {
        \\        asyncMultiBox.seen = (asyncMultiBox.seen | 0) + 1;
        \\        release();
        \\      });
        \\    });
        \\  }
        \\  return id + 1;
        \\};
        \\globalThis.__profileFlush = function() {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  for (var i = 0; i < workers * 24; i = i + 1)
        \\    asyncMultiCond.notifyAll();
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

fn nsToUs(ns: u64) u64 {
    return ns / 1_000;
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
        " {s:>10} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}", .{
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
        "ng waitus",
        "ng jus",
        "ng lus",
        "ng cus",
        "ng pus",
        "ng async",
        "ng done",
        "ng empty",
        "ng jobs",
        "ng hold",
        "ng cjob",
    });
    std.debug.print(" {s:>10} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "gil events",
        "gil parks",
        "gil joins",
        "gil lock",
        "gil cond",
        "gil prop",
        "gil waitus",
        "gil jus",
        "gil lus",
        "gil cus",
        "gil pus",
        "gil async",
        "gil done",
        "gil empty",
        "gil jobs",
        "gil hold",
        "gil cjob",
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
            " {d:>10} {d:>10} {d:>10} {d:>9} {d:>9} {d:>9} {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10}", .{
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
            nsToUs(parallel.stats.waitNs()),
            nsToUs(parallel.stats.thread_join_wait_ns),
            nsToUs(parallel.stats.lock_wait_ns),
            nsToUs(parallel.stats.condition_wait_ns),
            nsToUs(parallel.stats.property_wait_ns),
            parallel.stats.asyncWaits(),
            parallel.stats.asyncSettled(),
            parallel.stats.task_pump_empty,
            parallel.stats.task_pump_jobs,
            parallel.stats.task_pump_async_hold_jobs,
            parallel.stats.task_pump_condition_jobs,
        });
        std.debug.print(" {d:>10} {d:>10} {d:>10} {d:>9} {d:>9} {d:>9} {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10}\n", .{
            gil.stats.events(),
            gil.stats.parks(),
            gil.stats.thread_join_parks,
            gil.stats.lock_wait_parks,
            gil.stats.condition_wait_parks,
            gil.stats.property_wait_parks,
            nsToUs(gil.stats.waitNs()),
            nsToUs(gil.stats.thread_join_wait_ns),
            nsToUs(gil.stats.lock_wait_ns),
            nsToUs(gil.stats.condition_wait_ns),
            nsToUs(gil.stats.property_wait_ns),
            gil.stats.asyncWaits(),
            gil.stats.asyncSettled(),
            gil.stats.task_pump_empty,
            gil.stats.task_pump_jobs,
            gil.stats.task_pump_async_hold_jobs,
            gil.stats.task_pump_condition_jobs,
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

fn spawnProfileWorker(comptime module_worker: bool, src: []const u8) !*js.Worker {
    return if (module_worker)
        try js.Worker.spawnModule("entry.js", src, ModuleMessageProfileHost.host())
    else
        try js.Worker.spawn(src);
}

fn spawnLifecycleWorker(comptime module_worker: bool, src: []const u8) !*js.Worker {
    return if (module_worker)
        try js.Worker.spawnModule("entry.js", src, ModuleLifecycleProfileHost.host())
    else
        try js.Worker.spawn(src);
}

fn timeWorkerMessagesKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    batches: usize,
    comptime module_worker: bool,
) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {
        \\  postMessage(e.data + 1);
        \\};
    ;
    const worker_src = if (module_worker) ModuleMessageProfileHost.entries[1].source else src;

    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    var spawned: usize = 0;
    errdefer cleanupWorkers(workers[0..spawned]);
    while (spawned < worker_count) : (spawned += 1) {
        workers[spawned] = try spawnProfileWorker(module_worker, worker_src);
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

fn timeWorkerMessages(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, batches: usize) !u64 {
    return timeWorkerMessagesKind(gpa, io, worker_count, batches, false);
}

fn timeModuleWorkerMessages(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, batches: usize) !u64 {
    return timeWorkerMessagesKind(gpa, io, worker_count, batches, true);
}

fn timeWorkerEmptyReceivesKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    polls: usize,
    comptime module_worker: bool,
) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {};
    ;
    const worker_src = if (module_worker) ModuleMessageProfileHost.entries[1].source else src;

    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    var spawned: usize = 0;
    errdefer cleanupWorkers(workers[0..spawned]);
    while (spawned < worker_count) : (spawned += 1) {
        workers[spawned] = try spawnProfileWorker(module_worker, worker_src);
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

fn timeWorkerEmptyReceives(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, polls: usize) !u64 {
    return timeWorkerEmptyReceivesKind(gpa, io, worker_count, polls, false);
}

fn timeModuleWorkerEmptyReceives(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, polls: usize) !u64 {
    return timeWorkerEmptyReceivesKind(gpa, io, worker_count, polls, true);
}

fn timeWorkerLifecycleKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    rounds: usize,
    comptime module_worker: bool,
) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {
        \\  postMessage(e.data + 1);
        \\  close();
        \\};
    ;
    const worker_src = if (module_worker) ModuleLifecycleProfileHost.entries[1].source else src;

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
            workers[spawned] = try spawnLifecycleWorker(module_worker, worker_src);
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

fn timeWorkerLifecycle(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    return timeWorkerLifecycleKind(gpa, io, worker_count, rounds, false);
}

fn timeModuleWorkerLifecycle(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    return timeWorkerLifecycleKind(gpa, io, worker_count, rounds, true);
}

fn timeWorkerHostCloseDrainKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    rounds: usize,
    comptime module_worker: bool,
) !u64 {
    const src =
        \\globalThis.onmessage = function(e) {
        \\  postMessage(e.data + 1);
        \\};
    ;
    const worker_src = if (module_worker) ModuleMessageProfileHost.entries[1].source else src;

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
            workers[spawned] = try spawnProfileWorker(module_worker, worker_src);
        }

        const base = round * worker_count * 2;
        for (workers, 0..) |w, i| {
            try w.postMessage(&machine, js.Value.num(@floatFromInt(base + i * 2)));
            try w.postMessage(&machine, js.Value.num(@floatFromInt(base + i * 2 + 1)));
            w.close();
        }
        for (workers, 0..) |w, i| {
            const expected_first: f64 = @floatFromInt(base + i * 2 + 1);
            const expected_second: f64 = @floatFromInt(base + i * 2 + 2);
            const first = (try w.receive(&machine, 10_000)) orelse return error.WorkerTimeout;
            try expectWorkerReply(first, expected_first);
            const second = (try w.receive(&machine, 10_000)) orelse return error.WorkerTimeout;
            try expectWorkerReply(second, expected_second);
            if ((try w.receive(&machine, 10_000)) != null) return error.UnexpectedWorkerReply;
        }
        for (workers) |w| {
            w.join();
            w.destroy();
        }
    }
    return @intCast(nowNs(io) - t0);
}

fn timeWorkerHostCloseDrain(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    return timeWorkerHostCloseDrainKind(gpa, io, worker_count, rounds, false);
}

fn timeModuleWorkerHostCloseDrain(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    return timeWorkerHostCloseDrainKind(gpa, io, worker_count, rounds, true);
}

fn timeWorkerTerminateKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    rounds: usize,
    comptime module_worker: bool,
) !u64 {
    const src = "for (;;) {}";

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var spawned: usize = 0;
        errdefer cleanupWorkers(workers[0..spawned]);
        while (spawned < worker_count) : (spawned += 1) {
            workers[spawned] = if (module_worker)
                try js.Worker.spawnModule("entry.js", src, ModuleLifecycleProfileHost.host())
            else
                try js.Worker.spawn(src);
        }
        for (workers) |w| w.terminate();
        for (workers) |w| {
            w.join();
            w.destroy();
        }
    }
    return @intCast(nowNs(io) - t0);
}

fn timeWorkerTerminate(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    return timeWorkerTerminateKind(gpa, io, worker_count, rounds, false);
}

fn timeModuleWorkerTerminate(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !u64 {
    return timeWorkerTerminateKind(gpa, io, worker_count, rounds, true);
}

fn printWorkerProfile(gpa: std.mem.Allocator, io: std.Io, workers: []const usize) !void {
    std.debug.print("\nWorker message profile\n", .{});
    std.debug.print("isolated Worker API: one Context per OS thread, structured-clone inbox/outbox, no shared-realm .gil fallback\n", .{});
    std.debug.print("script rows use Worker.spawn(source); module rows use Worker.spawnModule(entry.js) with a tiny import graph\n", .{});
    std.debug.print("{s:>8} {s:>8} {s:>14} {s:>12} {s:>14} {s:>12}\n", .{
        "workers",
        "kind",
        "message ns",
        "ns/msg",
        "empty recv ns",
        "ns/poll",
    });

    for (workers) |n| {
        const total_messages: u64 = @intCast(n * worker_message_batches);
        const total_empty_receives: u64 = @intCast(n * worker_empty_receive_polls);

        const script_message_ns = try timeWorkerMessages(gpa, io, n, worker_message_batches);
        const script_empty_receive_ns = try timeWorkerEmptyReceives(gpa, io, n, worker_empty_receive_polls);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>14} {d:>12}\n", .{
            n,
            "script",
            script_message_ns,
            script_message_ns / @max(total_messages, 1),
            script_empty_receive_ns,
            script_empty_receive_ns / @max(total_empty_receives, 1),
        });

        const module_message_ns = try timeModuleWorkerMessages(gpa, io, n, worker_message_batches);
        const module_empty_receive_ns = try timeModuleWorkerEmptyReceives(gpa, io, n, worker_empty_receive_polls);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>14} {d:>12}\n", .{
            n,
            "module",
            module_message_ns,
            module_message_ns / @max(total_messages, 1),
            module_empty_receive_ns,
            module_empty_receive_ns / @max(total_empty_receives, 1),
        });
    }

    std.debug.print("\nWorker teardown profile\n", .{});
    std.debug.print("self-close = handler calls close(); host-close = owner closes inbox after queuing two messages and drains replies; terminate = stop-flag interrupt of spinning code\n", .{});
    std.debug.print("{s:>8} {s:>8} {s:>14} {s:>12} {s:>14} {s:>12} {s:>14} {s:>12} {s:>12}\n", .{
        "workers",
        "kind",
        "self close ns",
        "ns/worker",
        "host close ns",
        "ns/worker",
        "terminate ns",
        "ns/worker",
        "spawns",
    });

    for (workers) |n| {
        const close_spawns: u64 = @intCast(n * worker_lifecycle_rounds);
        const host_close_spawns: u64 = @intCast(n * worker_host_close_rounds);
        const terminate_spawns: u64 = @intCast(n * worker_terminate_rounds);

        const script_self_close_ns = try timeWorkerLifecycle(gpa, io, n, worker_lifecycle_rounds);
        const script_host_close_ns = try timeWorkerHostCloseDrain(gpa, io, n, worker_host_close_rounds);
        const script_terminate_ns = try timeWorkerTerminate(gpa, io, n, worker_terminate_rounds);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>14} {d:>12} {d:>14} {d:>12} {d:>12}\n", .{
            n,
            "script",
            script_self_close_ns,
            script_self_close_ns / @max(close_spawns, 1),
            script_host_close_ns,
            script_host_close_ns / @max(host_close_spawns, 1),
            script_terminate_ns,
            script_terminate_ns / @max(terminate_spawns, 1),
            terminate_spawns,
        });

        const module_self_close_ns = try timeModuleWorkerLifecycle(gpa, io, n, worker_lifecycle_rounds);
        const module_host_close_ns = try timeModuleWorkerHostCloseDrain(gpa, io, n, worker_host_close_rounds);
        const module_terminate_ns = try timeModuleWorkerTerminate(gpa, io, n, worker_terminate_rounds);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>14} {d:>12} {d:>14} {d:>12} {d:>12}\n", .{
            n,
            "module",
            module_self_close_ns,
            module_self_close_ns / @max(close_spawns, 1),
            module_host_close_ns,
            module_host_close_ns / @max(host_close_spawns, 1),
            module_terminate_ns,
            module_terminate_ns / @max(terminate_spawns, 1),
            terminate_spawns,
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
    std.debug.print("waitus/jus/lus/cus/pus = total native wait microseconds, then join/lock/condition/property wait microseconds\n", .{});
    std.debug.print("async/done = Condition.asyncWait and property waitAsync registrations / completed condition reacquires plus settled property waitAsync tickets\n", .{});
    std.debug.print("empty/jobs = run-loop task-pump empty fast-path hits / delivered grant jobs; hold/cjob split asyncHold vs Condition.asyncWait reacquire jobs\n", .{});

    for (scenarios) |scenario| try printScenario(gpa, io, scenario, worker_counts);
    try printWorkerProfile(gpa, io, worker_counts);
}
