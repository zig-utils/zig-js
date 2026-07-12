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
    force_gc: bool = false,
};

const Timing = struct {
    ns: u64,
    stats: js.jsthread.ContentionStats,
    shape: js.shape.ShapeStats,
};

const WorkerTiming = struct {
    ns: u64,
    stats: js.jsthread.ContentionStats,
};

const PromiseTiming = struct {
    ns: u64,
    contention: js.jsthread.ContentionStats,
    promise: js.promise_profile.PromiseStats,
};

const PromiseMode = enum {
    no_gil,
    gil,
    gil_gc,

    fn options(mode: PromiseMode) js.Context.Options {
        return switch (mode) {
            .no_gil => .{ .enable_threads = true },
            .gil => .{ .enable_threads = true, .gil = true },
            .gil_gc => .{ .enable_threads = true, .gil = true, .enable_gc = true },
        };
    }
};

const worker_message_batches = 160;
const worker_empty_receive_polls = 3000;
const worker_lifecycle_rounds = 12;
const worker_host_close_rounds = 12;
const worker_terminate_rounds = 12;

const promise_microtask_scenario = Scenario{
    .name = "promise microtasks",
    .setup =
    \\globalThis.worker = function(id) {
    \\  var settled = 0;
    \\  for (var i = 0; i < 256; i = i + 1) {
    \\    Promise.resolve(i + id).then(function(v) {
    \\      settled = settled + (v | 0);
    \\    });
    \\    Promise.resolve({ then: function(resolve) { resolve(id); } }).then(function(v) {
    \\      settled = settled + (v | 0);
    \\    });
    \\  }
    \\  drainMicrotasks();
    \\  return settled;
    \\};
    ,
    .rounds = 6,
};

const promise_reaction_scenario = Scenario{
    .name = "promise reactions",
    .setup =
    \\globalThis.worker = function(id) {
    \\  var settled = 0;
    \\  for (var i = 0; i < 512; i = i + 1) {
    \\    Promise.resolve(i + id).then(function(v) {
    \\      settled = settled + (v | 0);
    \\    });
    \\  }
    \\  drainMicrotasks();
    \\  return settled;
    \\};
    ,
    .rounds = 6,
};

const promise_thenable_scenario = Scenario{
    .name = "promise thenables",
    .setup =
    \\globalThis.worker = function(id) {
    \\  var settled = 0;
    \\  for (var i = 0; i < 512; i = i + 1) {
    \\    Promise.resolve({ then: function(resolve) { resolve(id + i); } }).then(function(v) {
    \\      settled = settled + (v | 0);
    \\    });
    \\  }
    \\  drainMicrotasks();
    \\  return settled;
    \\};
    ,
    .rounds = 6,
};

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
        .name = "mixed GC cell allocation",
        .setup =
        \\globalThis.worker = function(id) {
        \\  var keep = [];
        \\  for (var i = 0; i < 2500; i = i + 1) {
        \\    var box = { id: id, value: i, nested: { value: i + 1 } };
        \\    var fn = function() { return box.value + id; };
        \\    var promise = Promise.resolve(box);
        \\    keep.push([box, fn, promise]);
        \\  }
        \\  return keep.length;
        \\};
        ,
        .rounds = 3,
        .force_gc = true,
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
        .name = "condition asyncWait parked",
        .setup =
        \\globalThis.asyncParkCondLock = new Lock();
        \\globalThis.asyncParkCond = new Condition();
        \\globalThis.asyncParkCondBox = { ready: 0, seen: 0 };
        \\globalThis.worker = function(id) {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  if (workers <= 1) return id + 1;
        \\  var rounds = 30;
        \\  if (id === 0) {
        \\    for (var i = 0; i < rounds; i = i + 1) {
        \\      var need = (workers - 1) * (i + 1);
        \\      while (Atomics.load(asyncParkCondBox, 'ready') < need) {
        \\        var cur = Atomics.load(asyncParkCondBox, 'ready');
        \\        Atomics.wait(asyncParkCondBox, 'ready', cur, 100);
        \\      }
        \\      asyncParkCond.notifyAll();
        \\    }
        \\    return rounds;
        \\  }
        \\  for (var j = 0; j < rounds; j = j + 1) {
        \\    asyncParkCondLock.asyncHold(function() {
        \\      var wait = asyncParkCond.asyncWait(asyncParkCondLock);
        \\      Atomics.add(asyncParkCondBox, 'ready', 1);
        \\      Atomics.notify(asyncParkCondBox, 'ready');
        \\      return wait.then(function(release) {
        \\        asyncParkCondBox.seen = (asyncParkCondBox.seen | 0) + 1;
        \\        release();
        \\      });
        \\    });
        \\  }
        \\  return id + 1;
        \\};
        \\globalThis.__profileFlush = function() {
        \\  var workers = globalThis.__profileWorkers | 0;
        \\  for (var i = 0; i < workers * 30; i = i + 1)
        \\    asyncParkCond.notifyAll();
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
    const ctx = try js.Context.createWith(gpa, .{
        .enable_threads = true,
        .gil = gil,
        .enable_gc = scenario.force_gc,
    });
    defer ctx.destroy();
    try installHarness(ctx, scenario);

    const src = try std.fmt.allocPrint(ctx.arena(), "spawnBatch({d})", .{workers});
    _ = try ctx.evaluate(src);

    js.jsthread.resetContentionStats();
    js.shape.resetShapeStats();
    errdefer js.jsthread.disableContentionStats();
    errdefer js.shape.disableShapeStats();
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
    const shape = js.shape.shapeStats();
    js.jsthread.disableContentionStats();
    js.shape.disableShapeStats();
    return .{
        .ns = @intCast(nowNs(io) - t0),
        .stats = stats,
        .shape = shape,
    };
}

fn timePromiseScenario(gpa: std.mem.Allocator, io: std.Io, workers: usize, mode: PromiseMode, scenario: Scenario) !PromiseTiming {
    const ctx = try js.Context.createWith(gpa, mode.options());
    defer ctx.destroy();
    try installHarness(ctx, scenario);

    const src = try std.fmt.allocPrint(ctx.arena(), "spawnBatch({d})", .{workers});
    _ = try ctx.evaluate(src);

    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < scenario.rounds) : (round += 1) {
        _ = try ctx.evaluate(src);
    }
    const elapsed: u64 = @intCast(nowNs(io) - t0);

    // Keep the timing pass free of profiler-induced cross-thread atomic
    // contention. The count pass immediately below runs the same warmed
    // scenario in the same Context, but its counters are used only for
    // attribution columns, not for the `ns` columns.
    js.jsthread.resetContentionStats();
    js.promise_profile.resetPromiseStats();
    errdefer js.jsthread.disableContentionStats();
    errdefer js.promise_profile.disablePromiseStats();
    round = 0;
    while (round < scenario.rounds) : (round += 1) {
        _ = try ctx.evaluate(src);
    }
    const contention = js.jsthread.contentionStats();
    const promise = js.promise_profile.promiseStats();
    js.jsthread.disableContentionStats();
    js.promise_profile.disablePromiseStats();
    return .{
        .ns = elapsed,
        .contention = contention,
        .promise = promise,
    };
}

fn printPromiseProfile(gpa: std.mem.Allocator, io: std.Io, workers: []const usize, scenario: Scenario) !void {
    std.debug.print("\n{s} profile\n", .{scenario.name});
    std.debug.print("gil+gc = serialized fallback with GC-managed cells; ns columns are uninstrumented warmed timings; enq/pop/run = counted microtask queue enqueues, pops, and job runs; qlock/qyld = counted queue-lock acquisitions / yield-backed contention; plock/pyld = counted Promise-state lock acquisitions / yield-backed contention; aacq/acnt/aspn = counted LockedArena acquisitions / contended acquisitions / failed spin attempts; rxn/thn split reaction from thenable jobs; rpair/cap = resolving-function pairs / NewPromiseCapability executors; pnew/pcell/pobj/rfn = Promise creations / state cells / wrapper objects / resolving-function objects; rgr/qgr/bgr = reaction-list / microtask-queue / drain-batch growth\n", .{});
    std.debug.print("{s:>8} {s:>14} {s:>14} {s:>14} {s:>12} {s:>12} {s:>12}", .{
        "threads",
        "no-gil ns",
        "gil ns",
        "gil+gc ns",
        "no-gil x1",
        "vs gil",
        "vs gil+gc",
    });
    std.debug.print(" {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10}", .{
        "ng enq",
        "ng pop",
        "ng run",
        "ng qlock",
        "ng qyld",
        "ng plock",
        "ng pyld",
        "ng aacq",
        "ng acnt",
        "ng aspn",
        "ng rxn",
        "ng thn",
        "ng rpair",
        "ng cap",
        "ng pnew",
        "ng pcell",
        "ng pobj",
        "ng rfn",
        "ng rgr",
        "ng qgr",
        "ng bgr",
        "ng events",
    });
    std.debug.print(" {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10}\n", .{
        "gil enq",
        "gil pop",
        "gil run",
        "gil qlock",
        "gil qyld",
        "gil plock",
        "gil pyld",
        "gil aacq",
        "gil acnt",
        "gil aspn",
        "gil rxn",
        "gil thn",
        "gil rpair",
        "gil cap",
        "gil pnew",
        "gil pcell",
        "gil pobj",
        "gil rfn",
        "gil rgr",
        "gil qgr",
        "gil bgr",
        "gil events",
    });

    var base_parallel: u64 = 1;
    for (workers) |n| {
        const parallel = try timePromiseScenario(gpa, io, n, .no_gil, scenario);
        const gil = try timePromiseScenario(gpa, io, n, .gil, scenario);
        const gil_gc = try timePromiseScenario(gpa, io, n, .gil_gc, scenario);
        const parallel_ns = parallel.ns;
        const gil_ns = gil.ns;
        const gil_gc_ns = gil_gc.ns;
        if (n == workers[0]) base_parallel = @max(parallel_ns, 1);

        const scaling = @as(f64, @floatFromInt(n)) *
            @as(f64, @floatFromInt(base_parallel)) /
            @as(f64, @floatFromInt(@max(parallel_ns, 1)));
        const vs_gil = @as(f64, @floatFromInt(gil_ns)) /
            @as(f64, @floatFromInt(@max(parallel_ns, 1)));
        const vs_gil_gc = @as(f64, @floatFromInt(gil_gc_ns)) /
            @as(f64, @floatFromInt(@max(parallel_ns, 1)));

        std.debug.print("{d:>8} {d:>14} {d:>14} {d:>14} {d:>11.2}x {d:>11.2}x {d:>11.2}x", .{
            n,
            parallel_ns,
            gil_ns,
            gil_gc_ns,
            scaling,
            vs_gil,
            vs_gil_gc,
        });
        std.debug.print(" {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10}", .{
            parallel.promise.microtask_enqueues,
            parallel.promise.microtask_pops,
            parallel.promise.jobsRun(),
            parallel.promise.microtask_lock_acquires,
            parallel.promise.microtask_lock_yields,
            parallel.promise.promise_lock_acquires,
            parallel.promise.promise_lock_yields,
            parallel.contention.arena_lock_acquires,
            parallel.contention.arena_lock_contentions,
            parallel.contention.arena_lock_spins,
            parallel.promise.reaction_jobs_run,
            parallel.promise.thenable_jobs_run,
            parallel.promise.resolving_function_pairs,
            parallel.promise.capability_executors,
            parallel.promise.promises_created,
            parallel.promise.promise_state_cells,
            parallel.promise.promise_wrapper_objects,
            parallel.promise.resolving_function_objects,
            parallel.promise.reaction_list_grows,
            parallel.promise.microtask_queue_grows,
            parallel.promise.microtask_batch_grows,
            parallel.contention.events(),
        });
        std.debug.print(" {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10}\n", .{
            gil.promise.microtask_enqueues,
            gil.promise.microtask_pops,
            gil.promise.jobsRun(),
            gil.promise.microtask_lock_acquires,
            gil.promise.microtask_lock_yields,
            gil.promise.promise_lock_acquires,
            gil.promise.promise_lock_yields,
            gil.contention.arena_lock_acquires,
            gil.contention.arena_lock_contentions,
            gil.contention.arena_lock_spins,
            gil.promise.reaction_jobs_run,
            gil.promise.thenable_jobs_run,
            gil.promise.resolving_function_pairs,
            gil.promise.capability_executors,
            gil.promise.promises_created,
            gil.promise.promise_state_cells,
            gil.promise.promise_wrapper_objects,
            gil.promise.resolving_function_objects,
            gil.promise.reaction_list_grows,
            gil.promise.microtask_queue_grows,
            gil.promise.microtask_batch_grows,
            gil.contention.events(),
        });
    }
}

fn printScenario(gpa: std.mem.Allocator, io: std.Io, scenario: Scenario, workers: []const usize) !void {
    std.debug.print("\n{s}\n", .{scenario.name});
    std.debug.print("{s:>8} {s:>14} {s:>14} {s:>12} {s:>12}" ++
        " {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>10}", .{
        "threads",
        "no-gil ns",
        "gil ns",
        "no-gil x1",
        "vs gil",
        "ng events",
        "ng shape",
        "ng newsh",
        "ng syld",
        "ng aacq",
        "ng acnt",
        "ng aspn",
        "ng eacq",
        "ng ecnt",
        "ng espn",
        "ng lcnt",
        "ng aq",
        "ng parks",
        "ng joins",
        "ng lock",
        "ng cond",
        "ng prop",
        "ng waitus",
    });
    std.debug.print(" {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}", .{
        "ng jus",
        "ng lus",
        "ng cus",
        "ng pus",
        "ng async",
        "ng done",
        "ng caw",
        "ng cad",
        "ng paw",
        "ng pad",
        "ng empty",
        "ng jobs",
        "ng hold",
        "ng cjob",
    });
    std.debug.print(" {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "gil events",
        "gil shape",
        "gil newsh",
        "gil syld",
        "gil aacq",
        "gil acnt",
        "gil aspn",
        "gil eacq",
        "gil ecnt",
        "gil espn",
        "gil lcnt",
        "gil aq",
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
        "gil caw",
        "gil cad",
        "gil paw",
        "gil pad",
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
            " {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10}", .{
            n,
            parallel_ns,
            gil_ns,
            scaling,
            vs_gil,
            parallel.stats.events(),
            parallel.shape.transition_requests,
            parallel.shape.transition_misses,
            parallel.shape.transition_lock_yields,
            parallel.stats.arena_lock_acquires,
            parallel.stats.arena_lock_contentions,
            parallel.stats.arena_lock_spins,
            parallel.stats.env_lock_acquires,
            parallel.stats.env_lock_contentions,
            parallel.stats.env_lock_spins,
            parallel.stats.lock_contentions,
            parallel.stats.async_hold_queued,
            parallel.stats.parks(),
            parallel.stats.thread_join_parks,
        });
        std.debug.print(" {d:>9} {d:>9} {d:>9} {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>10} {d:>10}", .{
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
            parallel.stats.condition_async_waits,
            parallel.stats.condition_async_settled,
            parallel.stats.property_wait_async_enqueued,
            parallel.stats.property_wait_async_settled,
            parallel.stats.task_pump_empty,
            parallel.stats.task_pump_jobs,
            parallel.stats.task_pump_async_hold_jobs,
            parallel.stats.task_pump_condition_jobs,
        });
        std.debug.print(" {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10}", .{
            gil.stats.events(),
            gil.shape.transition_requests,
            gil.shape.transition_misses,
            gil.shape.transition_lock_yields,
            gil.stats.arena_lock_acquires,
            gil.stats.arena_lock_contentions,
            gil.stats.arena_lock_spins,
            gil.stats.env_lock_acquires,
            gil.stats.env_lock_contentions,
            gil.stats.env_lock_spins,
            gil.stats.lock_contentions,
            gil.stats.async_hold_queued,
            gil.stats.parks(),
            gil.stats.thread_join_parks,
        });
        std.debug.print(" {d:>9} {d:>9} {d:>9} {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>9} {d:>9} {d:>9} {d:>9} {d:>10} {d:>10} {d:>10} {d:>10}\n", .{
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
            gil.stats.condition_async_waits,
            gil.stats.condition_async_settled,
            gil.stats.property_wait_async_enqueued,
            gil.stats.property_wait_async_settled,
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
) !WorkerTiming {
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

    js.jsthread.resetContentionStats();
    errdefer js.jsthread.disableContentionStats();
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
    const stats = js.jsthread.contentionStats();
    js.jsthread.disableContentionStats();

    for (workers) |w| w.close();
    for (workers) |w| {
        w.join();
        w.destroy();
    }
    return .{ .ns = ns, .stats = stats };
}

fn timeWorkerMessages(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, batches: usize) !WorkerTiming {
    return timeWorkerMessagesKind(gpa, io, worker_count, batches, false);
}

fn timeModuleWorkerMessages(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, batches: usize) !WorkerTiming {
    return timeWorkerMessagesKind(gpa, io, worker_count, batches, true);
}

fn timeWorkerEmptyReceivesKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    polls: usize,
    comptime module_worker: bool,
) !WorkerTiming {
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

    js.jsthread.resetContentionStats();
    errdefer js.jsthread.disableContentionStats();
    const t0 = nowNs(io);
    var round: usize = 0;
    while (round < polls) : (round += 1) {
        for (workers) |w| {
            if ((try w.receive(&machine, 0)) != null) return error.UnexpectedWorkerReply;
        }
    }
    const ns: u64 = @intCast(nowNs(io) - t0);
    const stats = js.jsthread.contentionStats();
    js.jsthread.disableContentionStats();

    for (workers) |w| w.terminate();
    for (workers) |w| {
        w.join();
        w.destroy();
    }
    return .{ .ns = ns, .stats = stats };
}

fn timeWorkerEmptyReceives(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, polls: usize) !WorkerTiming {
    return timeWorkerEmptyReceivesKind(gpa, io, worker_count, polls, false);
}

fn timeModuleWorkerEmptyReceives(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, polls: usize) !WorkerTiming {
    return timeWorkerEmptyReceivesKind(gpa, io, worker_count, polls, true);
}

fn timeWorkerLifecycleKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    rounds: usize,
    comptime module_worker: bool,
) !WorkerTiming {
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

    js.jsthread.resetContentionStats();
    errdefer js.jsthread.disableContentionStats();
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
    const ns: u64 = @intCast(nowNs(io) - t0);
    const stats = js.jsthread.contentionStats();
    js.jsthread.disableContentionStats();
    return .{ .ns = ns, .stats = stats };
}

fn timeWorkerLifecycle(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !WorkerTiming {
    return timeWorkerLifecycleKind(gpa, io, worker_count, rounds, false);
}

fn timeModuleWorkerLifecycle(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !WorkerTiming {
    return timeWorkerLifecycleKind(gpa, io, worker_count, rounds, true);
}

fn timeWorkerHostCloseDrainKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    rounds: usize,
    comptime module_worker: bool,
) !WorkerTiming {
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

    js.jsthread.resetContentionStats();
    errdefer js.jsthread.disableContentionStats();
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
    const ns: u64 = @intCast(nowNs(io) - t0);
    const stats = js.jsthread.contentionStats();
    js.jsthread.disableContentionStats();
    return .{ .ns = ns, .stats = stats };
}

fn timeWorkerHostCloseDrain(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !WorkerTiming {
    return timeWorkerHostCloseDrainKind(gpa, io, worker_count, rounds, false);
}

fn timeModuleWorkerHostCloseDrain(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !WorkerTiming {
    return timeWorkerHostCloseDrainKind(gpa, io, worker_count, rounds, true);
}

fn timeWorkerTerminateKind(
    gpa: std.mem.Allocator,
    io: std.Io,
    worker_count: usize,
    rounds: usize,
    comptime module_worker: bool,
) !WorkerTiming {
    const src = "for (;;) {}";

    const workers = try gpa.alloc(*js.Worker, worker_count);
    defer gpa.free(workers);

    js.jsthread.resetContentionStats();
    errdefer js.jsthread.disableContentionStats();
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
    const ns: u64 = @intCast(nowNs(io) - t0);
    const stats = js.jsthread.contentionStats();
    js.jsthread.disableContentionStats();
    return .{ .ns = ns, .stats = stats };
}

fn timeWorkerTerminate(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !WorkerTiming {
    return timeWorkerTerminateKind(gpa, io, worker_count, rounds, false);
}

fn timeModuleWorkerTerminate(gpa: std.mem.Allocator, io: std.Io, worker_count: usize, rounds: usize) !WorkerTiming {
    return timeWorkerTerminateKind(gpa, io, worker_count, rounds, true);
}

fn workerChannelOps(stats: js.jsthread.ContentionStats) u64 {
    return stats.worker_channel_pushes + stats.worker_channel_pops +
        stats.worker_channel_empty_pops + stats.worker_channel_closes;
}

fn printWorkerMessageProfile(gpa: std.mem.Allocator, io: std.Io, workers: []const usize) !void {
    std.debug.print("\nWorker message profile\n", .{});
    std.debug.print("isolated Worker API: one Context per OS thread, structured-clone inbox/outbox, no shared-realm .gil fallback\n", .{});
    std.debug.print("script rows use Worker.spawn(source); module rows use Worker.spawnModule(entry.js) with a tiny import graph\n", .{});
    std.debug.print("{s:>8} {s:>8} {s:>14} {s:>12} {s:>9} {s:>9} {s:>14} {s:>12} {s:>10}\n", .{
        "workers",
        "kind",
        "message ns",
        "ns/msg",
        "push",
        "pop",
        "empty recv ns",
        "ns/poll",
        "null",
    });

    for (workers) |n| {
        const total_messages: u64 = @intCast(n * worker_message_batches);
        const total_empty_receives: u64 = @intCast(n * worker_empty_receive_polls);

        const script_message_ns = try timeWorkerMessages(gpa, io, n, worker_message_batches);
        const script_empty_receive_ns = try timeWorkerEmptyReceives(gpa, io, n, worker_empty_receive_polls);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>9} {d:>9} {d:>14} {d:>12} {d:>10}\n", .{
            n,
            "script",
            script_message_ns.ns,
            script_message_ns.ns / @max(total_messages, 1),
            script_message_ns.stats.worker_channel_pushes,
            script_message_ns.stats.worker_channel_pops,
            script_empty_receive_ns.ns,
            script_empty_receive_ns.ns / @max(total_empty_receives, 1),
            script_empty_receive_ns.stats.worker_channel_empty_pops,
        });

        const module_message_ns = try timeModuleWorkerMessages(gpa, io, n, worker_message_batches);
        const module_empty_receive_ns = try timeModuleWorkerEmptyReceives(gpa, io, n, worker_empty_receive_polls);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>9} {d:>9} {d:>14} {d:>12} {d:>10}\n", .{
            n,
            "module",
            module_message_ns.ns,
            module_message_ns.ns / @max(total_messages, 1),
            module_message_ns.stats.worker_channel_pushes,
            module_message_ns.stats.worker_channel_pops,
            module_empty_receive_ns.ns,
            module_empty_receive_ns.ns / @max(total_empty_receives, 1),
            module_empty_receive_ns.stats.worker_channel_empty_pops,
        });
    }
}

fn printWorkerTeardownProfile(gpa: std.mem.Allocator, io: std.Io, workers: []const usize) !void {
    std.debug.print("\nWorker teardown profile\n", .{});
    std.debug.print("self-close = handler calls close(); host-close = owner closes inbox after queuing two messages and drains replies; terminate = stop-flag interrupt of spinning code\n", .{});
    std.debug.print("{s:>8} {s:>8} {s:>14} {s:>12} {s:>10} {s:>14} {s:>12} {s:>10} {s:>14} {s:>12} {s:>10} {s:>12}\n", .{
        "workers",
        "kind",
        "self close ns",
        "ns/worker",
        "self ops",
        "host close ns",
        "ns/worker",
        "host ops",
        "terminate ns",
        "ns/worker",
        "term ops",
        "spawns",
    });

    for (workers) |n| {
        const close_spawns: u64 = @intCast(n * worker_lifecycle_rounds);
        const host_close_spawns: u64 = @intCast(n * worker_host_close_rounds);
        const terminate_spawns: u64 = @intCast(n * worker_terminate_rounds);

        const script_self_close_ns = try timeWorkerLifecycle(gpa, io, n, worker_lifecycle_rounds);
        const script_host_close_ns = try timeWorkerHostCloseDrain(gpa, io, n, worker_host_close_rounds);
        const script_terminate_ns = try timeWorkerTerminate(gpa, io, n, worker_terminate_rounds);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>10} {d:>14} {d:>12} {d:>10} {d:>14} {d:>12} {d:>10} {d:>12}\n", .{
            n,
            "script",
            script_self_close_ns.ns,
            script_self_close_ns.ns / @max(close_spawns, 1),
            workerChannelOps(script_self_close_ns.stats),
            script_host_close_ns.ns,
            script_host_close_ns.ns / @max(host_close_spawns, 1),
            workerChannelOps(script_host_close_ns.stats),
            script_terminate_ns.ns,
            script_terminate_ns.ns / @max(terminate_spawns, 1),
            workerChannelOps(script_terminate_ns.stats),
            terminate_spawns,
        });

        const module_self_close_ns = try timeModuleWorkerLifecycle(gpa, io, n, worker_lifecycle_rounds);
        const module_host_close_ns = try timeModuleWorkerHostCloseDrain(gpa, io, n, worker_host_close_rounds);
        const module_terminate_ns = try timeModuleWorkerTerminate(gpa, io, n, worker_terminate_rounds);
        std.debug.print("{d:>8} {s:>8} {d:>14} {d:>12} {d:>10} {d:>14} {d:>12} {d:>10} {d:>14} {d:>12} {d:>10} {d:>12}\n", .{
            n,
            "module",
            module_self_close_ns.ns,
            module_self_close_ns.ns / @max(close_spawns, 1),
            workerChannelOps(module_self_close_ns.stats),
            module_host_close_ns.ns,
            module_host_close_ns.ns / @max(host_close_spawns, 1),
            workerChannelOps(module_host_close_ns.stats),
            module_terminate_ns.ns,
            module_terminate_ns.ns / @max(terminate_spawns, 1),
            workerChannelOps(module_terminate_ns.stats),
            terminate_spawns,
        });
    }
}

fn printWorkerProfile(gpa: std.mem.Allocator, io: std.Io, workers: []const usize) !void {
    try printWorkerMessageProfile(gpa, io, workers);
    try printWorkerTeardownProfile(gpa, io, workers);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const scenario_filter = args.next();

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
    std.debug.print("shape/newsh/syld = hidden-class transition requests / newly-created child shapes / transition-lock yields\n", .{});
    std.debug.print("lcnt/aq = direct contended Lock.hold attempts / queued Lock.asyncHold grants, split out from events\n", .{});
    std.debug.print("joins = Thread.join timed wait/pump iterations, separated from other park sources for lifecycle attribution\n", .{});
    std.debug.print("lock/cond/prop = park iterations attributed to contended Lock.hold, Condition.wait, and property Atomics.wait\n", .{});
    std.debug.print("waitus/jus/lus/cus/pus = total native wait microseconds, then join/lock/condition/property wait microseconds\n", .{});
    std.debug.print("async/done = aggregate async waiter registrations/settlements; caw/cad and paw/pad split Condition.asyncWait versus property waitAsync\n", .{});
    std.debug.print("empty/jobs = run-loop task-pump empty fast-path hits / delivered grant jobs; hold/cjob split asyncHold vs Condition.asyncWait reacquire jobs\n", .{});
    std.debug.print("focused filters: worker messages, worker teardown, promise microtasks, promise reactions, promise thenables\n", .{});

    if (scenario_filter) |filter| {
        if (std.mem.eql(u8, filter, "worker messages")) {
            try printWorkerMessageProfile(gpa, io, worker_counts);
            return;
        }
        if (std.mem.eql(u8, filter, "worker teardown")) {
            try printWorkerTeardownProfile(gpa, io, worker_counts);
            return;
        }
        if (std.mem.eql(u8, filter, "promise microtasks")) {
            try printPromiseProfile(gpa, io, worker_counts, promise_microtask_scenario);
            return;
        }
        if (std.mem.eql(u8, filter, "promise reactions")) {
            try printPromiseProfile(gpa, io, worker_counts, promise_reaction_scenario);
            return;
        }
        if (std.mem.eql(u8, filter, "promise thenables")) {
            try printPromiseProfile(gpa, io, worker_counts, promise_thenable_scenario);
            return;
        }
    }

    var matched = scenario_filter == null;
    for (scenarios) |scenario| {
        if (scenario_filter) |filter| {
            if (!std.mem.eql(u8, scenario.name, filter)) continue;
            matched = true;
        }
        try printScenario(gpa, io, scenario, worker_counts);
    }
    if (scenario_filter == null) try printWorkerProfile(gpa, io, worker_counts);
    if (!matched) {
        std.debug.print("unknown threads-profile scenario: {s}\n", .{scenario_filter.?});
        return error.UnknownProfileScenario;
    }
}
