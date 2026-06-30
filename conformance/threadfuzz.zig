//! Concurrent-JS fuzzer (issue #1).
//!
//! Each seed generates a random program that SHARES objects / arrays / closures /
//! typed-arrays across N JS `Thread`s, then runs it in a GIL-free parallel
//! context. The shared accesses are deliberately unsynchronized at the JS level
//! (lost updates are legal), so the *program values* race — but a correct engine
//! serializes the underlying state behind its per-object / binding / frame locks,
//! so it stays **ThreadSanitizer-clean**. Built with `-Dtsan`, any unsynchronized
//! ENGINE access (like the VM upvalue race a hand-written test caught) surfaces as
//! a data race; a UAF/torn read aborts; an unexpected throw is printed with the
//! seed for one-command reproduction (`threadfuzz 1 <seed>`).
//!
//! This industrializes the find-race loop instead of relying on hand-written cases.

const std = @import("std");
const js = @import("js");

const Worker = js.Worker;

const ModuleFuzzHost = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "helper.js",
            .source =
            \\export function addMany(sab, slot, n) {
            \\  const v = new Int32Array(sab);
            \\  for (let i = 0; i < n; i++) Atomics.add(v, slot, 1);
            \\}
            ,
        },
        .{
            .path = "entry.js",
            .source =
            \\import { addMany } from "./helper.js";
            \\globalThis.onmessage = (e) => {
            \\  const v = new Int32Array(e.data.sab);
            \\  Atomics.add(v, 2, 1);
            \\  Atomics.notify(v, 2);
            \\  while (Atomics.load(v, 1) === 0)
            \\    Atomics.wait(v, 1, 0, 100);
            \\  addMany(e.data.sab, 0, e.data.iters);
            \\  postMessage({ done: true, module: true });
            \\  close();
            \\};
            ,
        },
    };

    fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        const name = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
        for (entries) |e| {
            if (std.mem.eql(u8, e.path, name)) {
                out_path.* = e.path;
                return e.source;
            }
        }
        return null;
    }

    fn host() js.Context.ModuleHost {
        return .{ .ctx = &host_ctx, .load = load };
    }
};

const ModuleGraphFuzzHost = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "core.js",
            .source =
            \\export function addSlot(sab, slot, n) {
            \\  const v = new Int32Array(sab);
            \\  for (let i = 0; i < n; i++) Atomics.add(v, slot, 1);
            \\  return n;
            \\}
            ,
        },
        .{
            .path = "left.js",
            .source =
            \\import { addSlot } from "./core.js";
            \\export function left(sab, n) {
            \\  const ran = addSlot(sab, 0, n);
            \\  Atomics.add(new Int32Array(sab), 3, ran);
            \\  return ran;
            \\}
            ,
        },
        .{
            .path = "right.js",
            .source =
            \\import { addSlot } from "./core.js";
            \\export function right(sab, n) {
            \\  const ran = addSlot(sab, 0, n + 1);
            \\  Atomics.add(new Int32Array(sab), 3, ran);
            \\  return ran;
            \\}
            ,
        },
        .{
            .path = "join.js",
            .source =
            \\import { left } from "./left.js";
            \\import { right } from "./right.js";
            \\export function runGraph(sab, n) {
            \\  return left(sab, n) + right(sab, n);
            \\}
            ,
        },
        .{
            .path = "entry.js",
            .source =
            \\import { runGraph } from "./join.js";
            \\globalThis.onmessage = (e) => {
            \\  const v = new Int32Array(e.data.sab);
            \\  Atomics.add(v, 2, 1);
            \\  Atomics.notify(v, 2);
            \\  while (Atomics.load(v, 1) === 0)
            \\    Atomics.wait(v, 1, 0, 100);
            \\  const score = runGraph(e.data.sab, e.data.iters);
            \\  postMessage({ done: true, graph: true, score });
            \\  close();
            \\};
            ,
        },
    };

    fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        const name = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
        for (entries) |e| {
            if (std.mem.eql(u8, e.path, name)) {
                out_path.* = e.path;
                return e.source;
            }
        }
        return null;
    }

    fn host() js.Context.ModuleHost {
        return .{ .ctx = &host_ctx, .load = load };
    }
};

const ModuleFanoutFuzzHost = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "core.js",
            .source =
            \\export function addSlot(sab, slot, n) {
            \\  const v = new Int32Array(sab);
            \\  for (let i = 0; i < n; i++) Atomics.add(v, slot, 1);
            \\  return n;
            \\}
            ,
        },
        .{
            .path = "leaf-a.js",
            .source =
            \\import { addSlot } from "./core.js";
            \\export function leafA(sab, n) {
            \\  const ran = addSlot(sab, 0, n);
            \\  const v = new Int32Array(sab);
            \\  Atomics.add(v, 3, ran);
            \\  Atomics.add(v, 4, 1);
            \\  return ran;
            \\}
            ,
        },
        .{
            .path = "leaf-b.js",
            .source =
            \\import { addSlot } from "./core.js";
            \\export function leafB(sab, n) {
            \\  const ran = addSlot(sab, 0, n + 1);
            \\  const v = new Int32Array(sab);
            \\  Atomics.add(v, 3, ran);
            \\  Atomics.add(v, 4, 1);
            \\  return ran;
            \\}
            ,
        },
        .{
            .path = "leaf-c.js",
            .source =
            \\import { addSlot } from "./core.js";
            \\export function leafC(sab, n) {
            \\  const ran = addSlot(sab, 0, n + 2);
            \\  const v = new Int32Array(sab);
            \\  Atomics.add(v, 3, ran);
            \\  Atomics.add(v, 4, 1);
            \\  return ran;
            \\}
            ,
        },
        .{
            .path = "branch-left.js",
            .source =
            \\import { leafA } from "./leaf-a.js";
            \\import { leafB } from "./leaf-b.js";
            \\export function branchLeft(sab, n) {
            \\  return leafA(sab, n) + leafB(sab, n);
            \\}
            ,
        },
        .{
            .path = "branch-right.js",
            .source =
            \\import { leafB } from "./leaf-b.js";
            \\import { leafC } from "./leaf-c.js";
            \\export function branchRight(sab, n) {
            \\  return leafB(sab, n + 3) + leafC(sab, n);
            \\}
            ,
        },
        .{
            .path = "entry.js",
            .source =
            \\import { branchLeft } from "./branch-left.js";
            \\import { branchRight } from "./branch-right.js";
            \\function runFanout(sab, n) {
            \\  return branchLeft(sab, n) + branchRight(sab, n);
            \\}
            \\globalThis.onmessage = (e) => {
            \\  const v = new Int32Array(e.data.sab);
            \\  Atomics.add(v, 2, 1);
            \\  Atomics.notify(v, 2);
            \\  while (Atomics.load(v, 1) === 0)
            \\    Atomics.wait(v, 1, 0, 100);
            \\  const score = runFanout(e.data.sab, e.data.iters);
            \\  postMessage({ done: true, fanout: true, score });
            \\  close();
            \\};
            ,
        },
    };

    fn load(_: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        const name = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
        for (entries) |e| {
            if (std.mem.eql(u8, e.path, name)) {
                out_path.* = e.path;
                return e.source;
            }
        }
        return null;
    }

    fn host() js.Context.ModuleHost {
        return .{ .ctx = &host_ctx, .load = load };
    }
};

/// One random shared-state operation, emitted into a worker's loop body. Every
/// op targets the shared structures declared by `genProgram` and cannot throw.
fn op(r: std.Random) []const u8 {
    return switch (r.uintLessThan(u8, 18)) {
        0 => "sObj.a = i; ", // named-property write
        1 => "acc += sObj.b; ", // named-property read
        2 => "sObj.c = sObj.a + 1; ", // read+write
        3 => "sArr[i & 7] = i; ", // dense element write
        4 => "acc += sArr[i & 7]; ", // dense element read
        5 => "sArr.push(i & 3); sArr.pop(); ", // element grow/shrink
        6 => "Atomics.add(sI32, 0, 1); ", // synchronized RMW
        7 => "acc += Atomics.load(sI32, i & 7); ", // synchronized load
        8 => "acc += sClo.bump(); ", // closure upvalue RMW (escaped frame)
        9 => "acc += sClo.peek(); ", // closure upvalue read
        10 => "delete sObj.c; sObj.c = 0; ", // delete + re-add (shape churn)
        11 => "sObj['k' + (i & 3)] = i; ", // dynamic property add (shape transition)
        12 => "acc += (new sCtr(i)).v; ", // shared constructor reading an upvalue
        13 => "sMap.set(i & 7, i); ", // shared Map insert/update
        14 => "acc += (sMap.get(i & 3) || 0); ", // shared Map read
        15 => "sSet.add(i & 7); acc += sSet.size; ", // shared Set mutate + size
        16 => "sObj.gs = i; acc += sObj.gs; ", // accessor property (getter/setter funnel)
        else => "acc += sArr.length; ", // length read
    };
}

/// Broader, still self-contained operations for the production-hardening fuzzer
/// profile. These deliberately exercise exception/finally paths, nested thread
/// lifecycle, asyncJoin settlement, short waiter parks, restrict ownership, and
/// FinalizationRegistry registration. Each snippet catches its own expected
/// abrupt completions so the fuzzer oracle remains "no unexpected throw".
fn broadOp(r: std.Random) []const u8 {
    return switch (r.uintLessThan(u8, 10)) {
        0 => "try { if ((i & 31) === 0) throw new Error('fuzz-' + i); } catch (e) { acc += e.message.length; } finally { sObj.finallyCount = (sObj.finallyCount || 0) + 1; } ",
        1 => "if ((i & 255) === 0) { var nt = new Thread(function(x){ return x + 1; }, i & 7); acc += nt.join(); } ",
        2 => "if ((i & 255) === 1) { var ft = new Thread(function(){ throw 'xfuzz'; }); try { ft.join(); } catch (e) { acc += (e === 'xfuzz') ? 1 : 0; } } ",
        3 => "if ((i & 127) === 2) { var at = new Thread(function(x){ return x * 2; }, i & 3); at.asyncJoin().then(function(v){ sObj.asyncSeen = (sObj.asyncSeen || 0) + v; }, function(){ sObj.asyncErr = 1; }); acc += at.join(); } ",
        4 => "if ((i & 63) === 3) { Atomics.store(waitBox, 'flag', 1); Atomics.notify(waitBox, 'flag'); } ",
        5 => "if ((i & 63) === 4) { var wr = Atomics.wait(waitBox, 'flag', 0, 1); if (wr === 'ok' || wr === 'timed-out' || wr === 'not-equal') acc += 1; } ",
        6 => "if ((i & 127) === 5) { var wa = Atomics.waitAsync(waitBox, 'async', 0, 0); if (wa && wa.async && wa.value && wa.value.then) wa.value.then(function(){ sObj.waitAsyncSeen = 1; }); } ",
        7 => "if ((i & 127) === 6) { var local = { x: i }; Thread.restrict(local); acc += local.x & 3; } ",
        8 => "if ((i & 63) === 7 && registry) { (function(){ var target = { i: i, pad: 'x' + i }; registry.register(target, i & 7); })(); if ((i & 511) === 7 && typeof gc === 'function') gc(); } ",
        else => "if ((i & 255) === 8) { lifeLock.hold(function(){ lifeBox.count = (lifeBox.count || 0) + 1; }); lifeCond.notifyAll(); } ",
    };
}

/// Generation knobs. The amplified profile raises thread count + loop length and
/// adds extra shared closures (the upvalue surface the first bug lived in), so
/// rare interleavings the default profile misses get many more chances to race.
const Cfg = struct {
    min_workers: usize,
    worker_span: usize, // workers = min_workers + rand(worker_span)
    loop_iters: usize,
    broad_profile: bool = false,
    enable_gc: bool = false,
    pub const default: Cfg = .{ .min_workers = 2, .worker_span = 5, .loop_iters = 1200 };
    pub const amplified: Cfg = .{ .min_workers = 6, .worker_span = 9, .loop_iters = 5000 };
    pub const broad: Cfg = .{ .min_workers = 3, .worker_span = 4, .loop_iters = 700, .broad_profile = true, .enable_gc = true };
};

fn genProgram(seed: u64, buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, cfg: Cfg) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    try buf.appendSlice(gpa,
        \\var sObj = { a: 0, b: 0, c: 0 };
        \\var sArr = [0, 0, 0, 0, 0, 0, 0, 0];
        \\var sBuf = new ArrayBuffer(64);
        \\var sI32 = new Int32Array(sBuf);
        \\var sClo = (function(){ var n = 0; return { bump(){ return ++n; }, peek(){ return n; } }; })();
        \\var sCtr = (function(){ var k = 100; return function Box(x){ this.v = x + k; }; })();
        \\var sMap = new Map(); var sSet = new Set();
        \\var sObj_gs = 0; Object.defineProperty(sObj, 'gs', { get(){ return sObj_gs; }, set(x){ sObj_gs = x; }, configurable: true });
        \\var waitBox = { flag: 0, async: 0, ready: 0 };
        \\var lifeLock = new Lock(); var lifeCond = new Condition(); var lifeBox = { count: 0 };
        \\var cleanupSeen = 0;
        \\var registry = (typeof FinalizationRegistry === 'function') ? new FinalizationRegistry(function(held){ cleanupSeen += held; }) : null;
        \\
    );
    const nworkers = cfg.min_workers + r.uintLessThan(usize, cfg.worker_span);
    var w: usize = 0;
    while (w < nworkers) : (w += 1) {
        const head = try std.fmt.allocPrint(gpa, "function w{d}(){{ var acc = 0; for (var i = 0; i < {d}; i++) {{ ", .{ w, cfg.loop_iters });
        defer gpa.free(head);
        try buf.appendSlice(gpa, head);
        const nops = 3 + r.uintLessThan(usize, 7);
        var o: usize = 0;
        while (o < nops) : (o += 1) try buf.appendSlice(gpa, op(r));
        if (cfg.broad_profile) {
            const nbroad = 2 + r.uintLessThan(usize, 4);
            var bo: usize = 0;
            while (bo < nbroad) : (bo += 1) try buf.appendSlice(gpa, broadOp(r));
        }
        try buf.appendSlice(gpa, "} return acc; }\n");
    }
    try buf.appendSlice(gpa, "var ts = [];\n");
    w = 0;
    while (w < nworkers) : (w += 1) {
        const sp = try std.fmt.allocPrint(gpa, "ts.push(new Thread(w{d}));\n", .{w});
        defer gpa.free(sp);
        try buf.appendSlice(gpa, sp);
    }
    try buf.appendSlice(gpa, "var total = 0; for (const t of ts) total += t.join();\n");
    if (cfg.broad_profile) try appendBroadSidecars(buf, gpa);
    try buf.appendSlice(gpa, "(total | 0)\n");
}

fn appendBroadSidecars(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
    try buf.appendSlice(gpa,
        \\// Broad-profile sidecars: deterministic lifecycle/waiter/cleanup
        \\// witnesses attached to each random program.
        \\{
        \\  var waiterBox = { flag: 0, ready: 0 };
        \\  var wt = new Thread(function(){
        \\    Atomics.store(waiterBox, 'ready', 1);
        \\    Atomics.notify(waiterBox, 'ready');
        \\    return Atomics.wait(waiterBox, 'flag', 0, 20);
        \\  });
        \\  while (Atomics.load(waiterBox, 'ready') === 0)
        \\    Atomics.wait(waiterBox, 'ready', 0, 1);
        \\  Atomics.store(waiterBox, 'flag', 1);
        \\  Atomics.notify(waiterBox, 'flag');
        \\  var wr = wt.join();
        \\  if (wr !== 'ok' && wr !== 'not-equal' && wr !== 'timed-out')
        \\    throw new Error('bad property wait result: ' + wr);
        \\}
        \\{
        \\  var lk = new Lock();
        \\  var cv = new Condition();
        \\  var box = { ready: 0, entered: 0, sleep: 0 };
        \\  var nt = new Thread(function(){
        \\    while (Atomics.load(box, 'entered') === 0)
        \\      Atomics.wait(box, 'sleep', 0, 1);
        \\    lk.hold(function(){ box.ready = 1; });
        \\    return cv.notifyAll();
        \\  });
        \\  lk.hold(function(){
        \\    Atomics.store(box, 'entered', 1);
        \\    while (!box.ready) cv.wait(lk);
        \\  });
        \\  var nw = nt.join();
        \\  if (nw !== 1 && nw !== 0) throw new Error('bad condition wake count');
        \\}
        \\{
        \\  var done = 0;
        \\  var aj = new Thread(function(){ return { value: 17 }; });
        \\  aj.asyncJoin().then(function(v){ done += v.value; }, function(){ done = -1000; });
        \\  var joined = aj.join();
        \\  if (joined.value !== 17) throw new Error('bad asyncJoin identity result');
        \\}
        \\if (registry && typeof gc === 'function') {
        \\  (function(){
        \\    for (var k = 0; k < 24; k++) registry.register({ k: k, p: 'cleanup' + k }, 1);
        \\  })();
        \\  gc();
        \\  registry.cleanupSome(function(held){ cleanupSeen += held; });
        \\}
        \\
    );
}

/// A *deterministic* program: N workers each apply `per` `Atomics.add`s to two
/// shared slots, so the final slot values are exactly computable. Returns the
/// expected encoded result; a lost/torn atomic update makes the engine return a
/// different number — a correctness bug the "no-throw" oracle can't see. (The
/// default fuzzer's shared writes are intentionally racy, so their result is not
/// checkable; only synchronized atomics give a verifiable oracle.)
fn genVerify(seed: u64, buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !f64 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const nworkers = 2 + r.uintLessThan(usize, 7); // 2..8
    const per = 200 + r.uintLessThan(usize, 1800); // 200..1999
    try buf.appendSlice(gpa,
        \\var vbuf = new ArrayBuffer(32); var via = new Int32Array(vbuf);
        \\
    );
    const head = try std.fmt.allocPrint(
        gpa,
        "function w(){{ for (var i = 0; i < {d}; i++) {{ Atomics.add(via, 0, 1); Atomics.add(via, 1, 3); }} }}\n",
        .{per},
    );
    defer gpa.free(head);
    try buf.appendSlice(gpa, head);
    try buf.appendSlice(gpa, "var ts = [];\n");
    var w: usize = 0;
    while (w < nworkers) : (w += 1) try buf.appendSlice(gpa, "ts.push(new Thread(w));\n");
    try buf.appendSlice(gpa,
        \\for (const t of ts) t.join();
        \\(Atomics.load(via, 0) + Atomics.load(via, 1) * 100000)
        \\
    );
    // slot0 = nworkers*per, slot1 = nworkers*per*3 → encoded:
    const total: f64 = @floatFromInt(nworkers * per);
    return total + total * 3.0 * 100000.0;
}

/// Teardown stress: every spawned Thread publishes that it reached a blocking or
/// long-running state, then the main script throws without joining. Context
/// teardown must request termination, wake parked peers, and join abandoned OS
/// threads without deadlock or UAF.
fn genTerminationStorm(seed: u64, buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 5);
    try buf.appendSlice(gpa,
        \\var gate = { go: 0, ready: 0 };
        \\var lock = new Lock();
        \\var cond = new Condition();
        \\var box = { open: false };
        \\var ts = [];
        \\function ready() {
        \\  Atomics.add(gate, 'ready', 1);
        \\  Atomics.notify(gate, 'ready');
        \\}
        \\
    );
    var i: usize = 0;
    while (i < nthreads) : (i += 1) {
        try buf.appendSlice(gpa, switch (r.uintLessThan(u8, 3)) {
            0 =>
            \\ts.push(new Thread(function(){
            \\  ready();
            \\  while (Atomics.load(gate, 'go') === 0)
            \\    Atomics.wait(gate, 'go', 0, 10000);
            \\  return 1;
            \\}));
            \\
            ,
            1 =>
            \\ts.push(new Thread(function(){
            \\  ready();
            \\  lock.hold(function(){
            \\    while (!box.open) cond.wait(lock);
            \\  });
            \\  return 2;
            \\}));
            \\
            ,
            else =>
            \\ts.push(new Thread(function(){
            \\  ready();
            \\  for (;;) {}
            \\}));
            \\
            ,
        });
    }
    const tail = try std.fmt.allocPrint(
        gpa,
        \\while (Atomics.load(gate, 'ready') < {d})
        \\  Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\throw new Error('threadfuzz termination storm {d}');
        \\
    ,
        .{ nthreads, seed },
    );
    defer gpa.free(tail);
    try buf.appendSlice(gpa, tail);
}

fn runTerminationStorm(gpa: std.mem.Allocator, seed: u64) !bool {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try genTerminationStorm(seed, &buf, gpa);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    if (ctx.evaluate(buf.items)) |_| {
        std.debug.print("seed {d}: termination storm returned normally\n", .{seed});
        return false;
    } else |err| {
        if (err != error.Throw) {
            std.debug.print("seed {d}: termination storm failed with {s}\n", .{ seed, @errorName(err) });
            return false;
        }
    }
    return true;
}

fn runWorkerThreadOverlap(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const nworkers = 2 + r.uintLessThan(usize, 4);
    const nthreads = 2 + r.uintLessThan(usize, 5);
    const worker_iters = 200 + r.uintLessThan(usize, 500);
    const thread_iters = 200 + r.uintLessThan(usize, 700);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg = ctx.evaluate("globalThis.__msg = { sab: new SharedArrayBuffer(16) }; globalThis.__msg") catch |err| {
        std.debug.print("seed {d}: cannot create lifecycle SAB: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src = try std.fmt.allocPrint(
        gpa,
        \\globalThis.onmessage = (e) => {{
        \\  const v = new Int32Array(e.data.sab);
        \\  Atomics.add(v, 2, 1);
        \\  Atomics.notify(v, 2);
        \\  while (Atomics.load(v, 1) === 0)
        \\    Atomics.wait(v, 1, 0, 100);
        \\  for (let i = 0; i < {d}; i++)
        \\    Atomics.add(v, 0, 1);
        \\  postMessage({{ done: true }});
        \\  close();
        \\}};
        \\
    ,
        .{worker_iters},
    );
    defer gpa.free(worker_src);

    var workers: std.ArrayListUnmanaged(*Worker) = .empty;
    defer workers.deinit(gpa);
    var cleanup_workers = true;
    defer if (cleanup_workers) {
        for (workers.items) |w| {
            w.terminate();
            w.join();
            w.destroy();
        }
    };

    var wi: usize = 0;
    while (wi < nworkers) : (wi += 1) {
        const w = Worker.spawn(worker_src) catch {
            std.debug.print("seed {d}: worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: worker postMessage failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\const v = new Int32Array(globalThis.__msg.sab);
        \\const ts = [];
        \\for (let t = 0; t < {d}; t++) {{
        \\  ts.push(new Thread(function(){{
        \\    const local = new Int32Array(globalThis.__msg.sab);
        \\    while (Atomics.load(local, 1) === 0)
        \\      ;
        \\    for (let i = 0; i < {d}; i++)
        \\      Atomics.add(local, 0, 1);
        \\    return 1;
        \\  }}));
        \\}}
        \\let spins = 0;
        \\while (Atomics.load(v, 2) < {d} && spins++ < 10000000)
        \\  ;
        \\if (Atomics.load(v, 2) < {d})
        \\  throw new Error('workers not ready for overlap');
        \\Atomics.store(v, 1, 1);
        \\Atomics.notify(v, 1, {d});
        \\let joined = 0;
        \\for (const t of ts) joined += t.join();
        \\joined;
        \\
    ,
        .{ nthreads, thread_iters, nworkers, nworkers, nworkers + nthreads + 4 },
    );
    defer gpa.free(js_src);

    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: overlap JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: overlap joined {d} threads, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, nthreads });
        return false;
    }

    for (workers.items) |w| {
        const reply = (w.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: worker receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        }) orelse {
            std.debug.print("seed {d}: worker receive timed out\n", .{seed});
            return false;
        };
        const done = machine.getProperty(reply, "done") catch |err| {
            std.debug.print("seed {d}: cannot read worker reply: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!done.isBoolean() or !done.asBool()) {
            std.debug.print("seed {d}: bad worker reply\n", .{seed});
            return false;
        }
    }

    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    const count = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__msg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read overlap counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const expected: f64 = @floatFromInt(nworkers * worker_iters + nthreads * thread_iters);
    if (!count.isNumber() or count.asNum() != expected) {
        std.debug.print("seed {d}: overlap counter got {d}, expected {d}\n", .{ seed, if (count.isNumber()) count.asNum() else -1, expected });
        return false;
    }
    return true;
}

fn runModuleWorkerThreadOverlap(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9e37_79b9_7f4a_7c15);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 4);
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const worker_iters = 120 + r.uintLessThan(usize, 260);
    const thread_iters = 150 + r.uintLessThan(usize, 320);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: module overlap context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__moduleMsg = {{ sab: new SharedArrayBuffer(16), iters: {d} }}; globalThis.__moduleMsg",
        .{worker_iters},
    );
    defer gpa.free(msg_src);
    const msg = ctx.evaluate(msg_src) catch |err| {
        std.debug.print("seed {d}: cannot create module overlap SAB: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    var workers: std.ArrayListUnmanaged(*Worker) = .empty;
    defer workers.deinit(gpa);
    var cleanup_workers = true;
    defer if (cleanup_workers) {
        for (workers.items) |w| {
            w.terminate();
            w.join();
            w.destroy();
        }
    };

    var wi: usize = 0;
    while (wi < nworkers) : (wi += 1) {
        const w = Worker.spawnModule("entry.js", ModuleFuzzHost.entries[1].source, ModuleFuzzHost.host()) catch {
            std.debug.print("seed {d}: module worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: module worker postMessage failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\const mv = new Int32Array(globalThis.__moduleMsg.sab);
        \\const mts = [];
        \\for (let t = 0; t < {d}; t++) {{
        \\  mts.push(new Thread(function(){{
        \\    const local = new Int32Array(globalThis.__moduleMsg.sab);
        \\    while (Atomics.load(local, 1) === 0) ;
        \\    for (let i = 0; i < {d}; i++) Atomics.add(local, 0, 1);
        \\    return 1;
        \\  }}));
        \\}}
        \\let spins = 0;
        \\while (Atomics.load(mv, 2) < {d} && spins++ < 10000000) ;
        \\if (Atomics.load(mv, 2) < {d}) throw new Error('module workers not ready');
        \\Atomics.store(mv, 1, 1);
        \\Atomics.notify(mv, 1, {d});
        \\let joined = 0;
        \\for (const t of mts) joined += t.join();
        \\joined;
        \\
    ,
        .{ nthreads, thread_iters, nworkers, nworkers, nworkers + nthreads + 4 },
    );
    defer gpa.free(js_src);

    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module overlap JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: module overlap joined {d} threads, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, nthreads });
        return false;
    }

    for (workers.items) |w| {
        const reply = (w.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: module worker receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        }) orelse {
            std.debug.print("seed {d}: module worker receive timed out\n", .{seed});
            return false;
        };
        const done = machine.getProperty(reply, "done") catch |err| {
            std.debug.print("seed {d}: cannot read module worker reply: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!done.isBoolean() or !done.asBool()) {
            std.debug.print("seed {d}: bad module worker reply\n", .{seed});
            return false;
        }
    }

    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    const count = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read module overlap counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const expected: f64 = @floatFromInt(nworkers * worker_iters + nthreads * thread_iters);
    if (!count.isNumber() or count.asNum() != expected) {
        std.debug.print("seed {d}: module overlap counter got {d}, expected {d}\n", .{ seed, if (count.isNumber()) count.asNum() else -1, expected });
        return false;
    }
    return true;
}

fn runModuleWorkerGraphOverlap(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6eed_5eed_914d_a7a5);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 3);
    const nthreads = 1 + r.uintLessThan(usize, 4);
    const worker_iters = 80 + r.uintLessThan(usize, 220);
    const thread_iters = 90 + r.uintLessThan(usize, 260);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: module graph context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__moduleGraphMsg = {{ sab: new SharedArrayBuffer(16), iters: {d} }}; globalThis.__moduleGraphMsg",
        .{worker_iters},
    );
    defer gpa.free(msg_src);
    const msg = ctx.evaluate(msg_src) catch |err| {
        std.debug.print("seed {d}: cannot create module graph SAB: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    var workers: std.ArrayListUnmanaged(*Worker) = .empty;
    defer workers.deinit(gpa);
    var cleanup_workers = true;
    defer if (cleanup_workers) {
        for (workers.items) |w| {
            w.terminate();
            w.join();
            w.destroy();
        }
    };

    var wi: usize = 0;
    while (wi < nworkers) : (wi += 1) {
        const w = Worker.spawnModule("entry.js", ModuleGraphFuzzHost.entries[4].source, ModuleGraphFuzzHost.host()) catch {
            std.debug.print("seed {d}: graph module worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: graph module postMessage failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\const gv = new Int32Array(globalThis.__moduleGraphMsg.sab);
        \\const gts = [];
        \\for (let t = 0; t < {d}; t++) {{
        \\  gts.push(new Thread(function(){{
        \\    const local = new Int32Array(globalThis.__moduleGraphMsg.sab);
        \\    while (Atomics.load(local, 1) === 0) ;
        \\    for (let i = 0; i < {d}; i++) Atomics.add(local, 0, 1);
        \\    return 1;
        \\  }}));
        \\}}
        \\let spins = 0;
        \\while (Atomics.load(gv, 2) < {d} && spins++ < 10000000) ;
        \\if (Atomics.load(gv, 2) < {d}) throw new Error('graph module workers not ready');
        \\Atomics.store(gv, 1, 1);
        \\Atomics.notify(gv, 1, {d});
        \\let joined = 0;
        \\for (const t of gts) joined += t.join();
        \\joined;
        \\
    ,
        .{ nthreads, thread_iters, nworkers, nworkers, nworkers + nthreads + 4 },
    );
    defer gpa.free(js_src);

    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module graph JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: module graph joined {d} threads, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, nthreads });
        return false;
    }

    const worker_score: f64 = @floatFromInt(2 * worker_iters + 1);
    for (workers.items) |w| {
        const reply = (w.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: graph module receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        }) orelse {
            std.debug.print("seed {d}: graph module receive timed out\n", .{seed});
            return false;
        };
        const done = machine.getProperty(reply, "done") catch |err| {
            std.debug.print("seed {d}: cannot read graph module done: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const graph = machine.getProperty(reply, "graph") catch |err| {
            std.debug.print("seed {d}: cannot read graph module flag: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const score = machine.getProperty(reply, "score") catch |err| {
            std.debug.print("seed {d}: cannot read graph module score: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!done.isBoolean() or !done.asBool() or !graph.isBoolean() or !graph.asBool() or !score.isNumber() or score.asNum() != worker_score) {
            std.debug.print("seed {d}: bad graph module reply\n", .{seed});
            return false;
        }
    }

    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    const count = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleGraphMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read module graph counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const module_only = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleGraphMsg.sab), 3)") catch |err| {
        std.debug.print("seed {d}: cannot read module graph score counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const expected_worker: f64 = @floatFromInt(nworkers * (2 * worker_iters + 1));
    const expected_total = expected_worker + @as(f64, @floatFromInt(nthreads * thread_iters));
    if (!count.isNumber() or count.asNum() != expected_total) {
        std.debug.print("seed {d}: module graph counter got {d}, expected {d}\n", .{ seed, if (count.isNumber()) count.asNum() else -1, expected_total });
        return false;
    }
    if (!module_only.isNumber() or module_only.asNum() != expected_worker) {
        std.debug.print("seed {d}: module graph module-only counter got {d}, expected {d}\n", .{ seed, if (module_only.isNumber()) module_only.asNum() else -1, expected_worker });
        return false;
    }
    return true;
}

fn runModuleWorkerFanoutOverlap(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0xfade_100d_5eed_2026);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 3);
    const nthreads = 1 + r.uintLessThan(usize, 4);
    const worker_iters = 70 + r.uintLessThan(usize, 180);
    const thread_iters = 80 + r.uintLessThan(usize, 220);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: module fanout context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__moduleFanoutMsg = {{ sab: new SharedArrayBuffer(24), iters: {d} }}; globalThis.__moduleFanoutMsg",
        .{worker_iters},
    );
    defer gpa.free(msg_src);
    const msg = ctx.evaluate(msg_src) catch |err| {
        std.debug.print("seed {d}: cannot create module fanout SAB: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    var workers: std.ArrayListUnmanaged(*Worker) = .empty;
    defer workers.deinit(gpa);
    var cleanup_workers = true;
    defer if (cleanup_workers) {
        for (workers.items) |w| {
            w.terminate();
            w.join();
            w.destroy();
        }
    };

    var wi: usize = 0;
    while (wi < nworkers) : (wi += 1) {
        const w = Worker.spawnModule("entry.js", ModuleFanoutFuzzHost.entries[6].source, ModuleFanoutFuzzHost.host()) catch {
            std.debug.print("seed {d}: fanout module worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: fanout module postMessage failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\const fv = new Int32Array(globalThis.__moduleFanoutMsg.sab);
        \\const fts = [];
        \\for (let t = 0; t < {d}; t++) {{
        \\  fts.push(new Thread(function(){{
        \\    const local = new Int32Array(globalThis.__moduleFanoutMsg.sab);
        \\    while (Atomics.load(local, 1) === 0) ;
        \\    for (let i = 0; i < {d}; i++) Atomics.add(local, 0, 1);
        \\    return 1;
        \\  }}));
        \\}}
        \\let spins = 0;
        \\while (Atomics.load(fv, 2) < {d} && spins++ < 10000000) ;
        \\if (Atomics.load(fv, 2) < {d}) throw new Error('fanout module workers not ready');
        \\Atomics.store(fv, 1, 1);
        \\Atomics.notify(fv, 1, {d});
        \\let joined = 0;
        \\for (const t of fts) joined += t.join();
        \\joined;
        \\
    ,
        .{ nthreads, thread_iters, nworkers, nworkers, nworkers + nthreads + 4 },
    );
    defer gpa.free(js_src);

    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module fanout JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: module fanout joined {d} threads, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, nthreads });
        return false;
    }

    const worker_score: f64 = @floatFromInt(4 * worker_iters + 7);
    for (workers.items) |w| {
        const reply = (w.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: fanout module receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        }) orelse {
            std.debug.print("seed {d}: fanout module receive timed out\n", .{seed});
            return false;
        };
        const done = machine.getProperty(reply, "done") catch |err| {
            std.debug.print("seed {d}: cannot read fanout module done: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const fanout = machine.getProperty(reply, "fanout") catch |err| {
            std.debug.print("seed {d}: cannot read fanout module flag: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const score = machine.getProperty(reply, "score") catch |err| {
            std.debug.print("seed {d}: cannot read fanout module score: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!done.isBoolean() or !done.asBool() or !fanout.isBoolean() or !fanout.asBool() or !score.isNumber() or score.asNum() != worker_score) {
            std.debug.print("seed {d}: bad fanout module reply\n", .{seed});
            return false;
        }
    }

    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    const count = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleFanoutMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read module fanout counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const module_only = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleFanoutMsg.sab), 3)") catch |err| {
        std.debug.print("seed {d}: cannot read module fanout score counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const leaf_calls = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleFanoutMsg.sab), 4)") catch |err| {
        std.debug.print("seed {d}: cannot read module fanout leaf-call counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const expected_worker: f64 = @floatFromInt(nworkers * (4 * worker_iters + 7));
    const expected_total = expected_worker + @as(f64, @floatFromInt(nthreads * thread_iters));
    const expected_leaf_calls: f64 = @floatFromInt(nworkers * 4);
    if (!count.isNumber() or count.asNum() != expected_total) {
        std.debug.print("seed {d}: module fanout counter got {d}, expected {d}\n", .{ seed, if (count.isNumber()) count.asNum() else -1, expected_total });
        return false;
    }
    if (!module_only.isNumber() or module_only.asNum() != expected_worker) {
        std.debug.print("seed {d}: module fanout module-only counter got {d}, expected {d}\n", .{ seed, if (module_only.isNumber()) module_only.asNum() else -1, expected_worker });
        return false;
    }
    if (!leaf_calls.isNumber() or leaf_calls.asNum() != expected_leaf_calls) {
        std.debug.print("seed {d}: module fanout leaf calls got {d}, expected {d}\n", .{ seed, if (leaf_calls.isNumber()) leaf_calls.asNum() else -1, expected_leaf_calls });
        return false;
    }
    return true;
}

fn runWorkerCloseTerminateRace(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0xd1b5_4a32_d192_ed03);
    const r = prng.random();
    const extra_pings = 1 + r.uintLessThan(usize, 4);

    const ctx = js.Context.createWith(gpa, .{ .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker race context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    _ = ctx.evaluate(
        \\globalThis.__raceSab = new SharedArrayBuffer(16);
        \\globalThis.__raceMsg = function(cmd, id) {
        \\  return { sab: globalThis.__raceSab, cmd: cmd, id: id };
        \\};
    ) catch |err| {
        std.debug.print("seed {d}: cannot create worker race messages: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  if (e.data.cmd === 'spin') {
        \\    Atomics.add(v, 1, 1);
        \\    Atomics.notify(v, 1);
        \\    for (;;) {}
        \\  }
        \\  Atomics.add(v, 0, 1);
        \\  postMessage({ ack: e.data.id, cmd: e.data.cmd });
        \\  if (e.data.cmd === 'close') close();
        \\};
    ;

    const graceful = Worker.spawn(worker_src) catch {
        std.debug.print("seed {d}: graceful worker spawn failed\n", .{seed});
        return false;
    };
    var cleanup_graceful = true;
    defer if (cleanup_graceful) {
        graceful.terminate();
        graceful.join();
        graceful.destroy();
    };
    const terminator = Worker.spawn(worker_src) catch {
        std.debug.print("seed {d}: terminator worker spawn failed\n", .{seed});
        return false;
    };
    var cleanup_terminator = true;
    defer if (cleanup_terminator) {
        terminator.terminate();
        terminator.join();
        terminator.destroy();
    };

    var i: usize = 0;
    while (i < extra_pings) : (i += 1) {
        const src = try std.fmt.allocPrint(gpa, "__raceMsg('ping', {d})", .{i});
        defer gpa.free(src);
        const msg = ctx.evaluate(src) catch |err| {
            std.debug.print("seed {d}: cannot make ping message: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        graceful.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: graceful post ping failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }
    const close_msg = ctx.evaluate("__raceMsg('close', 1000)") catch |err| {
        std.debug.print("seed {d}: cannot make close message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    graceful.postMessage(&machine, close_msg) catch |err| {
        std.debug.print("seed {d}: graceful post close failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    graceful.close();
    const dropped_msg = ctx.evaluate("__raceMsg('dropped', 2000)") catch |err| {
        std.debug.print("seed {d}: cannot make dropped message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    graceful.postMessage(&machine, dropped_msg) catch |err| {
        std.debug.print("seed {d}: graceful post after close failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    var replies: usize = 0;
    var ack_sum: f64 = 0;
    while (true) {
        const reply = graceful.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: graceful receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        } orelse break;
        const ack = machine.getProperty(reply, "ack") catch |err| {
            std.debug.print("seed {d}: cannot read graceful ack: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!ack.isNumber()) {
            std.debug.print("seed {d}: graceful reply without numeric ack\n", .{seed});
            return false;
        }
        const expected_ack: f64 = if (replies < extra_pings) @floatFromInt(replies) else 1000;
        if (ack.asNum() != expected_ack) {
            std.debug.print("seed {d}: graceful FIFO ack got {d}, expected {d}\n", .{ seed, ack.asNum(), expected_ack });
            return false;
        }
        ack_sum += ack.asNum();
        replies += 1;
    }
    const expected_replies = extra_pings + 1;
    if (replies != expected_replies) {
        std.debug.print("seed {d}: graceful worker drain/drop reply count got {d}, expected {d}\n", .{ seed, replies, expected_replies });
        return false;
    }
    const expected_ack_sum = 1000 + (@as(f64, @floatFromInt(extra_pings * (extra_pings - 1))) / 2);
    if (ack_sum != expected_ack_sum) {
        std.debug.print("seed {d}: graceful worker ack sum got {d}, expected {d}\n", .{ seed, ack_sum, expected_ack_sum });
        return false;
    }

    const spin_msg = ctx.evaluate("__raceMsg('spin', 3000)") catch |err| {
        std.debug.print("seed {d}: cannot make spin message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    terminator.postMessage(&machine, spin_msg) catch |err| {
        std.debug.print("seed {d}: terminator post spin failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    _ = ctx.evaluate(
        \\{
        \\  const v = new Int32Array(globalThis.__raceSab);
        \\  let spins = 0;
        \\  while (Atomics.load(v, 1) === 0 && spins++ < 10000000) ;
        \\  if (Atomics.load(v, 1) === 0) throw new Error('terminator worker did not enter spin');
        \\}
    ) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: terminator readiness failed {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    terminator.terminate();
    const after_term = ctx.evaluate("__raceMsg('after-terminate', 4000)") catch |err| {
        std.debug.print("seed {d}: cannot make after-terminate message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    terminator.postMessage(&machine, after_term) catch |err| {
        std.debug.print("seed {d}: terminator post after terminate failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    terminator.join();
    const after_term_reply = terminator.receive(&machine, 0) catch |err| {
        std.debug.print("seed {d}: terminator receive after join failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (after_term_reply != null) {
        std.debug.print("seed {d}: terminator delivered a post-terminate reply\n", .{seed});
        return false;
    }
    terminator.destroy();
    cleanup_terminator = false;
    graceful.join();
    graceful.destroy();
    cleanup_graceful = false;

    const delivered = ctx.evaluate("new Int32Array(globalThis.__raceSab)[0]") catch |err| {
        std.debug.print("seed {d}: cannot read worker race delivery counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!delivered.isNumber() or delivered.asNum() != @as(f64, @floatFromInt(expected_replies))) {
        std.debug.print("seed {d}: worker race delivery counter got {d}, expected {d}\n", .{ seed, if (delivered.isNumber()) delivered.asNum() else -1, expected_replies });
        return false;
    }

    return true;
}

fn runWorkerExceptionRecovery(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6578_776f_726b_6572);
    const r = prng.random();
    const pings = 2 + r.uintLessThan(usize, 4);

    const ctx = js.Context.createWith(gpa, .{ .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker exception context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    _ = ctx.evaluate(
        \\globalThis.__workerExceptionSab = new SharedArrayBuffer(16);
        \\globalThis.__workerExceptionMsg = function(cmd, id) {
        \\  return { sab: globalThis.__workerExceptionSab, cmd: cmd, id: id };
        \\};
    ) catch |err| {
        std.debug.print("seed {d}: cannot create worker exception messages: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  if (e.data.cmd === 'throw') {
        \\    Atomics.add(v, 0, 1);
        \\    throw new Error('expected worker handler throw');
        \\  }
        \\  if (e.data.cmd === 'ping') {
        \\    const after = Atomics.add(v, 0, e.data.id) + e.data.id;
        \\    postMessage({ ack: e.data.id, after });
        \\    return;
        \\  }
        \\  if (e.data.cmd === 'close') {
        \\    postMessage({ closed: true, total: Atomics.load(v, 0) });
        \\    close();
        \\  }
        \\};
    ;

    const w = Worker.spawn(worker_src) catch {
        std.debug.print("seed {d}: worker exception spawn failed\n", .{seed});
        return false;
    };
    var cleanup_worker = true;
    defer if (cleanup_worker) {
        w.terminate();
        w.join();
        w.destroy();
    };

    const throw_msg = ctx.evaluate("__workerExceptionMsg('throw', 1)") catch |err| {
        std.debug.print("seed {d}: cannot make worker throw message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    w.postMessage(&machine, throw_msg) catch |err| {
        std.debug.print("seed {d}: post worker throw failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    var expected_total: i64 = 1;
    var i: usize = 0;
    while (i < pings) : (i += 1) {
        const id: i64 = @intCast(10 + i);
        expected_total += id;
        const src = try std.fmt.allocPrint(gpa, "__workerExceptionMsg('ping', {d})", .{id});
        defer gpa.free(src);
        const msg = ctx.evaluate(src) catch |err| {
            std.debug.print("seed {d}: cannot make worker ping message: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: post worker ping failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }
    const close_msg = ctx.evaluate("__workerExceptionMsg('close', 0)") catch |err| {
        std.debug.print("seed {d}: cannot make worker close message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    w.postMessage(&machine, close_msg) catch |err| {
        std.debug.print("seed {d}: post worker close failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    w.close();

    var replies: usize = 0;
    var saw_close = false;
    while (true) {
        const reply = w.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: worker exception receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        } orelse break;
        const closed = machine.getProperty(reply, "closed") catch js.Value.undef();
        if (closed.isBoolean() and closed.asBool()) {
            const total = machine.getProperty(reply, "total") catch |err| {
                std.debug.print("seed {d}: cannot read worker close total: {s}\n", .{ seed, @errorName(err) });
                return false;
            };
            if (!total.isNumber() or total.asNum() != @as(f64, @floatFromInt(expected_total))) {
                std.debug.print("seed {d}: worker close total got {d}, expected {d}\n", .{ seed, if (total.isNumber()) total.asNum() else -1, expected_total });
                return false;
            }
            saw_close = true;
            continue;
        }
        const ack = machine.getProperty(reply, "ack") catch |err| {
            std.debug.print("seed {d}: cannot read worker exception ack: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const after = machine.getProperty(reply, "after") catch |err| {
            std.debug.print("seed {d}: cannot read worker exception counter: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!ack.isNumber() or !after.isNumber()) {
            std.debug.print("seed {d}: worker exception reply missing numeric fields\n", .{seed});
            return false;
        }
        replies += 1;
    }
    if (replies != pings or !saw_close) {
        std.debug.print("seed {d}: worker exception replies={d}/{d} saw_close={}\n", .{ seed, replies, pings, saw_close });
        return false;
    }

    w.join();
    w.destroy();
    cleanup_worker = false;
    return true;
}

fn runWorkerThreadFinalizationInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6372_6f73_735f_6669);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 3);
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const worker_iters = 90 + r.uintLessThan(usize, 180);
    const per_thread = 8 + r.uintLessThan(usize, 10);

    var expected_join_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 30_000;
        expected_join_sum += base + per_thread + id;
        expected_cleanup_count += per_thread;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) expected_cleanup_sum += base + i;
    }
    const expected_counter = nworkers * worker_iters + nthreads * per_thread;

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker/thread finalization context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__workerThreadFinMsg = {{ sab: new SharedArrayBuffer(32), iters: {d}, close: true }}; globalThis.__workerThreadFinMsg",
        .{worker_iters},
    );
    defer gpa.free(msg_src);
    const msg = ctx.evaluate(msg_src) catch |err| {
        std.debug.print("seed {d}: cannot create worker/thread finalization message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  Atomics.add(v, 2, 1);
        \\  Atomics.notify(v, 2);
        \\  while (Atomics.load(v, 1) === 0)
        \\    Atomics.wait(v, 1, 0, 100);
        \\  for (let i = 0; i < e.data.iters; i++)
        \\    Atomics.add(v, 0, 1);
        \\  postMessage({ done: true, after: Atomics.add(v, 3, 1) + 1 });
        \\  if (e.data.close) close();
        \\};
    ;

    var workers: std.ArrayListUnmanaged(*Worker) = .empty;
    defer workers.deinit(gpa);
    var cleanup_workers = true;
    defer if (cleanup_workers) {
        for (workers.items) |w| {
            w.terminate();
            w.join();
            w.destroy();
        }
    };

    var wi: usize = 0;
    while (wi < nworkers) : (wi += 1) {
        const w = Worker.spawn(worker_src) catch {
            std.debug.print("seed {d}: worker/thread finalization worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: worker/thread finalization postMessage failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerThreadFinCleanupCount = 0;
        \\  globalThis.__workerThreadFinCleanupSum = 0;
        \\  globalThis.__workerThreadFinOracle = 0;
        \\  globalThis.__workerThreadFinRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__workerThreadFinCleanupCount++;
        \\    globalThis.__workerThreadFinCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__workerThreadFinRegistry;
        \\  const v = new Int32Array(globalThis.__workerThreadFinMsg.sab);
        \\  const threads = [];
        \\  let asyncSum = 0;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      const local = new Int32Array(globalThis.__workerThreadFinMsg.sab);
        \\      const base = (id + 1) * 30000;
        \\      for (let i = 0; i < per; i++) {{
        \\        Atomics.add(local, 0, 1);
        \\        let target = {{ id, i, payload: 'worker-thread-fin-' + id + '-' + i }};
        \\        registry.register(target, base + i);
        \\        target = null;
        \\      }}
        \\      Atomics.add(local, 4, 1);
        \\      return base + per + id;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (value) => {{ asyncSum += value; }},
        \\      () => {{ asyncSum = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(v, 2) < {d})
        \\    Atomics.wait(v, 2, Atomics.load(v, 2), 1);
        \\  Atomics.store(v, 1, 1);
        \\  Atomics.notify(v, 1, {d});
        \\  let joinSum = 0;
        \\  for (const t of threads) joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad worker/thread finalization join sum ' + joinSum);
        \\  if (Atomics.load(v, 4) !== {d})
        \\    throw new Error('bad worker/thread finalization thread done count ' + Atomics.load(v, 4));
        \\  threads.length = 0;
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSum !== {d})
        \\      throw new Error('bad worker/thread finalization async sum ' + asyncSum);
        \\    globalThis.__workerThreadFinOracle = 1;
        \\  }});
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{ nthreads, per_thread, nworkers, nworkers + nthreads + 4, expected_join_sum, nthreads, expected_join_sum },
    );
    defer gpa.free(js_src);

    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker/thread finalization JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: worker/thread finalization joined got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__workerThreadFinOracle") catch |err| {
        std.debug.print("seed {d}: cannot read worker/thread finalization oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: worker/thread finalization oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }

    var replies: usize = 0;
    while (replies < nworkers) : (replies += 1) {
        const reply = (workers.items[replies].receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: worker/thread finalization receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        }) orelse {
            std.debug.print("seed {d}: worker/thread finalization receive timed out\n", .{seed});
            return false;
        };
        const done = machine.getProperty(reply, "done") catch |err| {
            std.debug.print("seed {d}: cannot read worker/thread finalization done: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const after = machine.getProperty(reply, "after") catch |err| {
            std.debug.print("seed {d}: cannot read worker/thread finalization after: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!done.isBoolean() or !done.asBool() or !after.isNumber() or after.asNum() < 1 or after.asNum() > @as(f64, @floatFromInt(nworkers))) {
            std.debug.print("seed {d}: bad worker/thread finalization reply\n", .{seed});
            return false;
        }
    }
    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    const counter = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__workerThreadFinMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read worker/thread finalization counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!counter.isNumber() or counter.asNum() != @as(f64, @floatFromInt(expected_counter))) {
        std.debug.print("seed {d}: worker/thread finalization counter got {d}, expected {d}\n", .{ seed, if (counter.isNumber()) counter.asNum() else -1, expected_counter });
        return false;
    }
    const worker_done = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__workerThreadFinMsg.sab), 3)") catch |err| {
        std.debug.print("seed {d}: cannot read worker/thread finalization worker done: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!worker_done.isNumber() or worker_done.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: worker/thread finalization worker done got {d}, expected {d}\n", .{ seed, if (worker_done.isNumber()) worker_done.asNum() else -1, nworkers });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerThreadFinRegistry.cleanupSome();
        \\  if (globalThis.__workerThreadFinCleanupCount !== {d})
        \\    throw new Error('bad worker/thread finalization cleanup count: ' + globalThis.__workerThreadFinCleanupCount);
        \\  if (globalThis.__workerThreadFinCleanupSum !== {d})
        \\    throw new Error('bad worker/thread finalization cleanup sum: ' + globalThis.__workerThreadFinCleanupSum);
        \\  return globalThis.__workerThreadFinCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker/thread finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: worker/thread finalization cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runThreadExceptionWaiterInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7468_7265_6164_6578);
    const r = prng.random();
    const wait_timeout_ms = 1500 + r.uintLessThan(usize, 1000);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: thread exception/waiter context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__threadExceptionWaiterOracle = 0;
        \\  const marker = {d};
        \\  const boom = {{ marker, nested: {{ identity: 'same object' }} }};
        \\  const gate = {{ state: 0, propReady: 0, condReady: 0, condOpen: false }};
        \\  const lock = new Lock();
        \\  const cond = new Condition();
        \\  const propWaiter = new Thread(() => {{
        \\    Atomics.store(gate, 'propReady', 1);
        \\    Atomics.notify(gate, 'propReady');
        \\    return Atomics.wait(gate, 'state', 0, {d});
        \\  }});
        \\  const condWaiter = new Thread(() => {{
        \\    lock.hold(() => {{
        \\      Atomics.store(gate, 'condReady', 1);
        \\      Atomics.notify(gate, 'condReady');
        \\      while (!gate.condOpen) cond.wait(lock);
        \\    }});
        \\    return 'cond-ok';
        \\  }});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\
        \\  let earlyRejectScore = 0;
        \\  const failing = new Thread(() => {{ throw boom; }});
        \\  const p1 = failing.asyncJoin();
        \\  const p2 = failing.asyncJoin();
        \\  p1.then(
        \\    () => {{ earlyRejectScore = -1000; }},
        \\    (e) => {{ if (e === boom && e.nested.identity === 'same object') earlyRejectScore += 1; }});
        \\  p2.then(
        \\    () => {{ earlyRejectScore = -1000; }},
        \\    (e) => {{ if (e === boom && e.marker === marker) earlyRejectScore += 10; }});
        \\
        \\  let joinIdentity = 0;
        \\  try {{
        \\    failing.join();
        \\  }} catch (e) {{
        \\    joinIdentity = (e === boom && e.nested === boom.nested) ? 1 : -1;
        \\  }}
        \\  if (joinIdentity !== 1)
        \\    throw new Error('join did not rethrow by identity');
        \\
        \\  const relay = new Thread(() => {{
        \\    try {{
        \\      failing.join();
        \\      return 'bad';
        \\    }} catch (e) {{
        \\      return e;
        \\    }}
        \\  }});
        \\  if (relay.join() !== boom)
        \\    throw new Error('joiner thread did not receive the same exception object');
        \\
        \\  let lateReject = 0;
        \\  failing.asyncJoin().then(
        \\    () => {{ lateReject = -1000; }},
        \\    (e) => {{ if (e === boom) lateReject = 1; }});
        \\
        \\  Atomics.store(gate, 'state', 1);
        \\  Atomics.notify(gate, 'state');
        \\  lock.hold(() => {{
        \\    gate.condOpen = true;
        \\    cond.notifyAll();
        \\  }});
        \\  const propResult = propWaiter.join();
        \\  if (propResult !== 'ok' && propResult !== 'not-equal')
        \\    throw new Error('bad property waiter result: ' + propResult);
        \\  if (condWaiter.join() !== 'cond-ok')
        \\    throw new Error('condition waiter did not resume cleanly');
        \\
        \\  Promise.resolve().then(() => {{
        \\    if (earlyRejectScore !== 11)
        \\      throw new Error('early asyncJoin rejection score ' + earlyRejectScore);
        \\    if (lateReject !== 1)
        \\      throw new Error('late asyncJoin rejection score ' + lateReject);
        \\    globalThis.__threadExceptionWaiterOracle = 1;
        \\  }});
        \\  return marker;
        \\}})();
        \\
    ,
        .{ seed, wait_timeout_ms },
    );
    defer gpa.free(src);

    const marker = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: thread exception/waiter JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!marker.isNumber() or marker.asNum() != @as(f64, @floatFromInt(seed))) {
        std.debug.print("seed {d}: thread exception/waiter marker got {d}\n", .{ seed, if (marker.isNumber()) marker.asNum() else -1 });
        return false;
    }

    const oracle = ctx.evaluate("globalThis.__threadExceptionWaiterOracle") catch |err| {
        std.debug.print("seed {d}: cannot read thread exception/waiter oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: thread exception/waiter oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }
    return true;
}

fn runReturnedWaitAsyncLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7761_6974_6173_796e);
    const r = prng.random();
    const wait_timeout_ms = 20 + r.uintLessThan(usize, 30);
    const parked_timeout_ms = 1200 + r.uintLessThan(usize, 800);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: returned waitAsync lifecycle context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__returnedWaitAsyncOracle = 0;
        \\  const sab = new SharedArrayBuffer(16);
        \\  const gate = {{ prop: 0, propReady: 0, condReady: 0, condOpen: false }};
        \\  const lock = new Lock();
        \\  const cond = new Condition();
        \\  const propWaiter = new Thread(() => {{
        \\    Atomics.store(gate, 'propReady', 1);
        \\    Atomics.notify(gate, 'propReady');
        \\    return Atomics.wait(gate, 'prop', 0, {d});
        \\  }});
        \\  const condWaiter = new Thread(() => {{
        \\    lock.hold(() => {{
        \\      Atomics.store(gate, 'condReady', 1);
        \\      Atomics.notify(gate, 'condReady');
        \\      while (!gate.condOpen) cond.wait(lock);
        \\    }});
        \\    return 'cond-ok';
        \\  }});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\
        \\  const t = new Thread(() => {{
        \\    const view = new Int32Array(sab);
        \\    const ne = Atomics.waitAsync(view, 0, 1);
        \\    if (ne.async !== false || ne.value !== 'not-equal')
        \\      throw new Error('bad waitAsync not-equal fast path');
        \\    const pending = Atomics.waitAsync(view, 1, 0, {d});
        \\    if (pending.async !== true || !(pending.value instanceof Promise))
        \\      throw new Error('bad waitAsync pending shape');
        \\    return pending.value;
        \\  }});
        \\
        \\  t.asyncJoin().then(
        \\    (v) => {{
        \\      if (v !== 'timed-out')
        \\        throw new Error('asyncJoin did not assimilate waitAsync result: ' + v);
        \\      globalThis.__returnedWaitAsyncOracle += 11;
        \\    }},
        \\    () => {{ globalThis.__returnedWaitAsyncOracle = -1000; }});
        \\
        \\  const joined = t.join();
        \\  if (!(joined instanceof Promise))
        \\    throw new Error('join did not return the thread-returned Promise');
        \\  joined.then(
        \\    (v) => {{
        \\      if (v !== 'timed-out')
        \\        throw new Error('joined waitAsync promise resolved to ' + v);
        \\      globalThis.__returnedWaitAsyncOracle += 100;
        \\    }},
        \\    () => {{ globalThis.__returnedWaitAsyncOracle = -1000; }});
        \\
        \\  Atomics.store(gate, 'prop', 1);
        \\  Atomics.notify(gate, 'prop');
        \\  lock.hold(() => {{
        \\    gate.condOpen = true;
        \\    cond.notifyAll();
        \\  }});
        \\  const propResult = propWaiter.join();
        \\  if (propResult !== 'ok' && propResult !== 'not-equal')
        \\    throw new Error('bad returned-waitAsync property waiter result: ' + propResult);
        \\  if (condWaiter.join() !== 'cond-ok')
        \\    throw new Error('returned-waitAsync condition waiter did not resume cleanly');
        \\  return 1;
        \\}})();
        \\
    ,
        .{ parked_timeout_ms, wait_timeout_ms },
    );
    defer gpa.free(src);

    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: returned waitAsync lifecycle JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != 1) {
        std.debug.print("seed {d}: returned waitAsync lifecycle result got {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1 });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__returnedWaitAsyncOracle") catch |err| {
        std.debug.print("seed {d}: cannot read returned waitAsync oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 111) {
        std.debug.print("seed {d}: returned waitAsync oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }
    return true;
}

fn runFinalizationCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6669_6e61_6c69_7a65);
    const r = prng.random();
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const per_thread = 12 + r.uintLessThan(usize, 12);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: finalization context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__finCleanupCount = 0;
        \\  globalThis.__finCleanupSum = 0;
        \\  globalThis.__finRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__finCleanupCount++;
        \\    globalThis.__finCleanupSum += held;
        \\  }});
        \\  function registerRange(base) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      let target = {{ base, i, pad: 'cleanup-' + base + '-' + i }};
        \\      globalThis.__finRegistry.register(target, base + i);
        \\      target = null;
        \\    }}
        \\    return {d};
        \\  }}
        \\  const threads = [];
        \\
    ,
        .{ per_thread, per_thread },
    );
    defer gpa.free(src);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, src);
    var expected_count: usize = 0;
    var expected_sum: usize = 0;
    var i: usize = 0;
    while (i < nthreads) : (i += 1) {
        const base = (i + 1) * 1000;
        expected_count += per_thread;
        expected_sum += per_thread * base + (per_thread * (per_thread - 1)) / 2;
        const line = try std.fmt.allocPrint(gpa, "  threads.push(new Thread(registerRange, {d}));\n", .{base});
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
    const tail = try std.fmt.allocPrint(
        gpa,
        \\  let joined = 0;
        \\  for (const t of threads) joined += t.join();
        \\  if (joined !== {d}) throw new Error('bad finalization registration count: ' + joined);
        \\  return joined;
        \\}})();
        \\
    ,
        .{expected_count},
    );
    defer gpa.free(tail);
    try buf.appendSlice(gpa, tail);

    const registered = ctx.evaluate(buf.items) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!registered.isNumber() or registered.asNum() != @as(f64, @floatFromInt(expected_count))) {
        std.debug.print("seed {d}: finalization registered got {d}, expected {d}\n", .{ seed, if (registered.isNumber()) registered.asNum() else -1, expected_count });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__finRegistry.cleanupSome();
        \\  if (globalThis.__finCleanupCount !== {d})
        \\    throw new Error('bad cleanup count: ' + globalThis.__finCleanupCount);
        \\  if (globalThis.__finCleanupSum !== {d})
        \\    throw new Error('bad cleanup sum: ' + globalThis.__finCleanupSum);
        \\  return globalThis.__finCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_count, expected_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_count))) {
        std.debug.print("seed {d}: finalization cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_count });
        return false;
    }
    return true;
}

fn runFinalizationAsyncJoinCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6173_796e_635f_6669);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 4);
    const per_thread = 10 + r.uintLessThan(usize, 10);

    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var expected_success_sum: usize = 0;
    var expected_reject_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 10_000;
        var local_sum: usize = 0;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) {
            if ((i & 3) == 0) continue;
            local_sum += base + i;
            expected_cleanup_sum += base + i;
            expected_cleanup_count += 1;
        }
        if ((id & 1) == 0) {
            expected_success_sum += local_sum + id;
        } else {
            expected_reject_sum += local_sum + id;
        }
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: finalization asyncJoin context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__finAsyncCleanupCount = 0;
        \\  globalThis.__finAsyncCleanupSum = 0;
        \\  globalThis.__finAsyncJoinOracle = 0;
        \\  globalThis.__finAsyncCleanupRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__finAsyncCleanupCount++;
        \\    globalThis.__finAsyncCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__finAsyncCleanupRegistry;
        \\  const threads = [];
        \\  let asyncSuccess = 0;
        \\  let asyncReject = 0;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      let localSum = 0;
        \\      const base = (id + 1) * 10000;
        \\      for (let i = 0; i < per; i++) {{
        \\        let target = {{ id, i, payload: 'fin-async-' + id + '-' + i }};
        \\        let token = {{ id, i }};
        \\        registry.register(target, base + i, token);
        \\        if ((i & 3) === 0) {{
        \\          if (!registry.unregister(token))
        \\            throw new Error('unregister missed token ' + id + '/' + i);
        \\        }} else {{
        \\          localSum += base + i;
        \\        }}
        \\        target = null;
        \\        token = null;
        \\      }}
        \\      if ((id & 1) === 1)
        \\        throw {{ id, sum: localSum + id, tag: 'fin-async-reject' }};
        \\      return localSum + id;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (v) => {{ asyncSuccess += v; }},
        \\      (e) => {{
        \\        if (e && e.tag === 'fin-async-reject')
        \\          asyncReject += e.sum;
        \\        else
        \\          asyncReject = -1000000;
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  let joinSuccess = 0;
        \\  let joinReject = 0;
        \\  for (let id = 0; id < threads.length; id++) {{
        \\    try {{
        \\      const v = threads[id].join();
        \\      if ((id & 1) !== 0)
        \\        throw new Error('odd finalization worker returned');
        \\      joinSuccess += v;
        \\    }} catch (e) {{
        \\      if ((id & 1) === 0)
        \\        throw e;
        \\      if (!e || e.id !== id || e.tag !== 'fin-async-reject')
        \\        throw new Error('bad finalization rejection for ' + id);
        \\      joinReject += e.sum;
        \\    }}
        \\  }}
        \\  if (joinSuccess !== {d})
        \\    throw new Error('bad finalization join success sum ' + joinSuccess);
        \\  if (joinReject !== {d})
        \\    throw new Error('bad finalization join reject sum ' + joinReject);
        \\  threads.length = 0;
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSuccess !== {d})
        \\      throw new Error('bad finalization async success sum ' + asyncSuccess);
        \\    if (asyncReject !== {d})
        \\      throw new Error('bad finalization async reject sum ' + asyncReject);
        \\    globalThis.__finAsyncJoinOracle = 1;
        \\  }});
        \\  return joinSuccess + joinReject;
        \\}})();
        \\
    ,
        .{ nthreads, per_thread, expected_success_sum, expected_reject_sum, expected_success_sum, expected_reject_sum },
    );
    defer gpa.free(src);

    const joined = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: finalization asyncJoin JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const expected_joined = expected_success_sum + expected_reject_sum;
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_joined))) {
        std.debug.print("seed {d}: finalization asyncJoin joined got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_joined });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__finAsyncJoinOracle") catch |err| {
        std.debug.print("seed {d}: cannot read finalization asyncJoin oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: finalization asyncJoin oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }

    ctx.collectGarbage();
    const check_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  // Keep the registry reachable through cleanup delivery, but prove that
        \\  // unregister-token records never become cleanup jobs.
        \\  globalThis.__finAsyncCleanupRegistry.cleanupSome();
        \\  if (globalThis.__finAsyncCleanupCount !== {d})
        \\    throw new Error('bad finalization async cleanup count: ' + globalThis.__finAsyncCleanupCount);
        \\  if (globalThis.__finAsyncCleanupSum !== {d})
        \\    throw new Error('bad finalization async cleanup sum: ' + globalThis.__finAsyncCleanupSum);
        \\  return globalThis.__finAsyncCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_sum },
    );
    defer gpa.free(check_src);
    const cleaned = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: finalization async cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: finalization async cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runFinalizationWaiterCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7761_6974_6669_6e63);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 4);
    const per_thread = 8 + r.uintLessThan(usize, 10);
    const wait_timeout_ms = 1200 + r.uintLessThan(usize, 800);

    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var expected_join_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 20_000;
        expected_join_sum += base + per_thread + id;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) {
            expected_cleanup_count += 1;
            expected_cleanup_sum += base + i;
        }
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: finalization waiter cleanup context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__finWaiterCleanupCount = 0;
        \\  globalThis.__finWaiterCleanupSum = 0;
        \\  globalThis.__finWaiterOracle = 0;
        \\  globalThis.__finWaiterRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__finWaiterCleanupCount++;
        \\    globalThis.__finWaiterCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__finWaiterRegistry;
        \\  const gate = {{ prop: 0, propReady: 0, condReady: 0, condOpen: false }};
        \\  const lock = new Lock();
        \\  const cond = new Condition();
        \\  const propWaiter = new Thread(() => {{
        \\    Atomics.store(gate, 'propReady', 1);
        \\    Atomics.notify(gate, 'propReady');
        \\    return Atomics.wait(gate, 'prop', 0, {d});
        \\  }});
        \\  const condWaiter = new Thread(() => {{
        \\    lock.hold(() => {{
        \\      Atomics.store(gate, 'condReady', 1);
        \\      Atomics.notify(gate, 'condReady');
        \\      while (!gate.condOpen) cond.wait(lock);
        \\    }});
        \\    return 'cond-open';
        \\  }});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\  const threads = [];
        \\  let asyncSum = 0;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      const base = (id + 1) * 20000;
        \\      for (let i = 0; i < per; i++) {{
        \\        let target = {{ id, i, payload: 'fin-waiter-' + id + '-' + i }};
        \\        registry.register(target, base + i);
        \\        target = null;
        \\      }}
        \\      return base + per + id;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (v) => {{ asyncSum += v; }},
        \\      () => {{ asyncSum = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  let joinSum = 0;
        \\  for (const t of threads)
        \\    joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad finalization waiter join sum ' + joinSum);
        \\  Atomics.store(gate, 'prop', 1);
        \\  Atomics.notify(gate, 'prop');
        \\  lock.hold(() => {{
        \\    gate.condOpen = true;
        \\    cond.notifyAll();
        \\  }});
        \\  const propResult = propWaiter.join();
        \\  if (propResult !== 'ok' && propResult !== 'not-equal' && propResult !== 'timed-out')
        \\    throw new Error('bad finalization waiter property result: ' + propResult);
        \\  if (condWaiter.join() !== 'cond-open')
        \\    throw new Error('finalization waiter condition did not resume');
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSum !== {d})
        \\      throw new Error('bad finalization waiter async sum ' + asyncSum);
        \\    globalThis.__finWaiterOracle = 1;
        \\  }});
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{ wait_timeout_ms, nthreads, per_thread, expected_join_sum, expected_join_sum },
    );
    defer gpa.free(src);

    const joined = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: finalization waiter cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: finalization waiter cleanup joined got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__finWaiterOracle") catch |err| {
        std.debug.print("seed {d}: cannot read finalization waiter oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: finalization waiter oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }

    ctx.collectGarbage();
    const check_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__finWaiterRegistry.cleanupSome();
        \\  if (globalThis.__finWaiterCleanupCount !== {d})
        \\    throw new Error('bad finalization waiter cleanup count: ' + globalThis.__finWaiterCleanupCount);
        \\  if (globalThis.__finWaiterCleanupSum !== {d})
        \\    throw new Error('bad finalization waiter cleanup sum: ' + globalThis.__finWaiterCleanupSum);
        \\  return globalThis.__finWaiterCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_sum },
    );
    defer gpa.free(check_src);
    const cleaned = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: finalization waiter cleanup check JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: finalization waiter cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runThreadRestrictLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7265_7374_7269_6374);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 4);
    const per_thread = 8 + r.uintLessThan(usize, 12);

    var expected_success_sum: usize = 0;
    var expected_reject_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        if ((id & 1) == 0) {
            expected_success_sum += per_thread + id * 10_000;
        } else {
            expected_reject_sum += per_thread + id;
        }
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: Thread.restrict lifecycle context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__restrictLifecycleOracle = 0;
        \\  const mainBox = {{ seed: {d}, owner: 'main' }};
        \\  Thread.restrict(mainBox);
        \\  let asyncSuccess = 0;
        \\  let asyncReject = 0;
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      let rejectedMain = 0;
        \\      try {{
        \\        mainBox.seed;
        \\      }} catch (e) {{
        \\        if (e instanceof ConcurrentAccessError)
        \\          rejectedMain = 1;
        \\        else
        \\          throw e;
        \\      }}
        \\      if (rejectedMain !== 1)
        \\        throw new Error('restricted main object was readable from worker ' + id);
        \\      const local = {{ id, count: 0, tag: 'restrict-' + id }};
        \\      Thread.restrict(local);
        \\      for (let i = 0; i < per; i++)
        \\        local.count = local.count + 1;
        \\      const nested = new Thread((box) => {{
        \\        try {{
        \\          box.count;
        \\          return -1;
        \\        }} catch (e) {{
        \\          return e instanceof ConcurrentAccessError ? 1 : -2;
        \\        }}
        \\      }}, local);
        \\      if (nested.join() !== 1)
        \\        throw new Error('nested thread read restricted local ' + id);
        \\      if ((id & 1) === 1)
        \\        throw {{ id, count: local.count, score: local.count + id, tag: 'restrict-reject' }};
        \\      return local.count + id * 10000;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (v) => {{ asyncSuccess += v; }},
        \\      (e) => {{
        \\        if (e && e.tag === 'restrict-reject' && e.count === {d})
        \\          asyncReject += e.score;
        \\        else
        \\          asyncReject = -1000000;
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  if (mainBox.seed !== {d})
        \\    throw new Error('main restricted object changed');
        \\  let joinSuccess = 0;
        \\  let joinReject = 0;
        \\  for (let id = 0; id < threads.length; id++) {{
        \\    try {{
        \\      const v = threads[id].join();
        \\      if ((id & 1) !== 0)
        \\        throw new Error('odd restricted worker returned normally');
        \\      joinSuccess += v;
        \\    }} catch (e) {{
        \\      if ((id & 1) === 0)
        \\        throw e;
        \\      if (!e || e.id !== id || e.count !== {d} || e.tag !== 'restrict-reject')
        \\        throw new Error('bad restricted worker rejection for ' + id);
        \\      joinReject += e.score;
        \\    }}
        \\  }}
        \\  if (joinSuccess !== {d})
        \\    throw new Error('bad Thread.restrict join success sum ' + joinSuccess);
        \\  if (joinReject !== {d})
        \\    throw new Error('bad Thread.restrict join reject sum ' + joinReject);
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSuccess !== {d})
        \\      throw new Error('bad Thread.restrict async success sum ' + asyncSuccess);
        \\    if (asyncReject !== {d})
        \\      throw new Error('bad Thread.restrict async reject sum ' + asyncReject);
        \\    globalThis.__restrictLifecycleOracle = 1;
        \\  }});
        \\  return joinSuccess + joinReject;
        \\}})();
        \\
    ,
        .{
            seed,
            nthreads,
            per_thread,
            per_thread,
            seed,
            per_thread,
            expected_success_sum,
            expected_reject_sum,
            expected_success_sum,
            expected_reject_sum,
        },
    );
    defer gpa.free(src);

    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: Thread.restrict lifecycle JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const expected_return = expected_success_sum + expected_reject_sum;
    if (!result.isNumber() or result.asNum() != @as(f64, @floatFromInt(expected_return))) {
        std.debug.print("seed {d}: Thread.restrict lifecycle got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected_return });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__restrictLifecycleOracle") catch |err| {
        std.debug.print("seed {d}: cannot read Thread.restrict lifecycle oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: Thread.restrict lifecycle oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }
    return true;
}

fn runThreadLocalLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x746c_735f_6c69_6665);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 4);
    const per_thread = 8 + r.uintLessThan(usize, 12);

    var expected_success_sum: usize = 0;
    var expected_reject_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        if ((id & 1) == 0) {
            expected_success_sum += per_thread + id * 100_000;
        } else {
            expected_reject_sum += id + 1;
        }
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: ThreadLocal lifecycle context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__tlsLifecycleOracle = 0;
        \\  const tls = new ThreadLocal();
        \\  const mainMarker = {{ seed: {d}, owner: 'main' }};
        \\  tls.value = mainMarker;
        \\  let asyncScore = 0;
        \\  let rejectScore = 0;
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      if (tls.value !== undefined)
        \\        throw new Error('fresh thread inherited ThreadLocal value');
        \\      const local = {{ id, count: 0, tag: 'tls-' + id }};
        \\      tls.value = local;
        \\      for (let i = 0; i < per; i++) {{
        \\        if (tls.value !== local)
        \\          throw new Error('ThreadLocal changed under thread ' + id);
        \\        tls.value.count = tls.value.count + 1;
        \\        if (i === (per >> 1)) {{
        \\          const nested = new Thread(() => tls.value === undefined ? 1 : -1);
        \\          if (nested.join() !== 1)
        \\            throw new Error('nested thread saw parent ThreadLocal');
        \\        }}
        \\      }}
        \\      if ((id & 1) === 1)
        \\        throw local;
        \\      return tls.value.count + id * 100000;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (v) => {{ asyncScore += v; }},
        \\      (e) => {{
        \\        if (e && e.id === id && e.count === {d} && e.tag === 'tls-' + id)
        \\          rejectScore += id + 1;
        \\        else
        \\          rejectScore = -1000000;
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  let successSum = 0;
        \\  let caughtRejectSum = 0;
        \\  for (let id = 0; id < threads.length; id++) {{
        \\    try {{
        \\      const v = threads[id].join();
        \\      if ((id & 1) !== 0)
        \\        throw new Error('odd ThreadLocal worker returned normally');
        \\      successSum += v;
        \\    }} catch (e) {{
        \\      if ((id & 1) === 0)
        \\        throw e;
        \\      if (!e || e.id !== id || e.count !== {d} || e.tag !== 'tls-' + id)
        \\        throw new Error('bad ThreadLocal thrown object for ' + id);
        \\      caughtRejectSum += id + 1;
        \\    }}
        \\  }}
        \\  if (tls.value !== mainMarker)
        \\    throw new Error('main ThreadLocal value was overwritten');
        \\  if (successSum !== {d})
        \\    throw new Error('bad ThreadLocal success sum ' + successSum);
        \\  if (caughtRejectSum !== {d})
        \\    throw new Error('bad ThreadLocal reject sum ' + caughtRejectSum);
        \\  Promise.resolve().then(() => {{
        \\    if (asyncScore !== {d})
        \\      throw new Error('bad ThreadLocal asyncJoin success score ' + asyncScore);
        \\    if (rejectScore !== {d})
        \\      throw new Error('bad ThreadLocal asyncJoin reject score ' + rejectScore);
        \\    globalThis.__tlsLifecycleOracle = 1;
        \\  }});
        \\  return successSum + caughtRejectSum;
        \\}})();
        \\
    ,
        .{ seed, nthreads, per_thread, per_thread, per_thread, expected_success_sum, expected_reject_sum, expected_success_sum, expected_reject_sum },
    );
    defer gpa.free(src);

    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: ThreadLocal lifecycle JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const expected_return = expected_success_sum + expected_reject_sum;
    if (!result.isNumber() or result.asNum() != @as(f64, @floatFromInt(expected_return))) {
        std.debug.print("seed {d}: ThreadLocal lifecycle got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected_return });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__tlsLifecycleOracle") catch |err| {
        std.debug.print("seed {d}: cannot read ThreadLocal lifecycle oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: ThreadLocal lifecycle oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }
    return true;
}

fn runAsyncHoldBargingLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    }) catch {
        std.debug.print("seed {d}: asyncHold barging lifecycle context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(async () => {{
        \\  const marker = {d};
        \\  const lock = new Lock();
        \\  let ticket;
        \\  let score = 0;
        \\  lock.hold(() => {{
        \\    const t = new Thread(() => lock.asyncHold());
        \\    ticket = t.join();
        \\    if (!(ticket instanceof Promise))
        \\      throw new Error('asyncHold barging join did not return a Promise');
        \\    score += 1;
        \\  }});
        \\  let barged = false;
        \\  lock.hold(() => {{
        \\    barged = true;
        \\    score += 10;
        \\  }});
        \\  if (!barged)
        \\    throw new Error('sync hold did not barge before async ticket delivery');
        \\  const release = await ticket;
        \\  if (typeof release !== 'function')
        \\    throw new Error('asyncHold barging ticket did not resolve to release function');
        \\  if (!lock.locked)
        \\    throw new Error('asyncHold barging ticket was not granted');
        \\  release();
        \\  if (lock.locked)
        \\    throw new Error('asyncHold barging release did not unlock');
        \\  return marker + score + 100;
        \\}})()
        \\
    ,
        .{seed},
    );
    defer gpa.free(src);

    const promise_value = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: asyncHold barging lifecycle JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    var machine = ctx.interpreter();
    const result = machine.awaitValue(promise_value) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: asyncHold barging await failed {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const expected = seed + 111;
    if (!result.isNumber() or result.asNum() != @as(f64, @floatFromInt(expected))) {
        std.debug.print("seed {d}: asyncHold barging got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected });
        return false;
    }
    return true;
}

fn runMidScriptWaitPumpGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6467_635f_7761);
    const r = prng.random();
    const rounds = 8 + r.uintLessThan(usize, 8);
    const per_round = 650 + r.uintLessThan(usize, 500);
    const async_allocs = 96 + r.uintLessThan(usize, 96);
    const async_second_allocs = 48 + r.uintLessThan(usize, 80);
    const async_cond_allocs = 48 + r.uintLessThan(usize, 80);
    const async_base = seed & 1023;
    const async_expected = async_base + async_allocs;
    const async_second_expected = async_base + 1024 + async_second_allocs;
    const async_cond_expected = async_base + 2048 + async_cond_allocs;
    const tls_expected = async_base + 4096;
    const spin_iters = 4000 + r.uintLessThan(usize, 6000);
    const wait_timeout_ms = 1200 + r.uintLessThan(usize, 900);

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const gate = {{ state: 0, propReady: 0, condReady: 0, holderReady: 0, lockReady: 0, releaseLock: 0, lockDone: 0, asyncDone: 0, asyncSecondDone: 0, asyncCondReady: 0, asyncCondDone: 0, tlsReady: 0, tlsRelease: 0 }};
        \\  const condLock = new Lock();
        \\  const cond = new Condition();
        \\  const heldLock = new Lock();
        \\  const asyncTaskLock = new Lock();
        \\  const asyncCondLock = new Lock();
        \\  const asyncCond = new Condition();
        \\  const tls = new ThreadLocal();
        \\  const asyncRoot = {{ nested: {{ base: {d} }}, label: 'async-midgc-root' }};
        \\  let asyncScore = 0;
        \\  let asyncThen = 0;
        \\  let asyncSecondScore = 0;
        \\  let asyncSecondThen = 0;
        \\  let asyncCondScore = 0;
        \\  let asyncCondThen = 0;
        \\  const asyncGrant = asyncTaskLock.asyncHold(() => {{
        \\    const taskKeep = [];
        \\    for (let a = 0; a < {d}; a++)
        \\      taskKeep.push({{ a, root: asyncRoot, payload: 'async-grant-' + a }});
        \\    asyncScore = asyncRoot.nested.base + taskKeep.length;
        \\    Atomics.store(gate, 'asyncDone', 1);
        \\    Atomics.notify(gate, 'asyncDone');
        \\    return asyncScore;
        \\  }});
        \\  asyncGrant.then(
        \\    (v) => {{ asyncThen = v; }},
        \\    () => {{ asyncThen = -1; }});
        \\  const asyncSecondGrant = asyncTaskLock.asyncHold(() => {{
        \\    const taskKeep = [];
        \\    for (let a = 0; a < {d}; a++)
        \\      taskKeep.push({{ a, root: asyncRoot, payload: 'async-grant-second-' + a }});
        \\    asyncSecondScore = asyncRoot.nested.base + 1024 + taskKeep.length;
        \\    Atomics.store(gate, 'asyncSecondDone', 1);
        \\    Atomics.notify(gate, 'asyncSecondDone');
        \\    return asyncSecondScore;
        \\  }});
        \\  asyncSecondGrant.then(
        \\    (v) => {{ asyncSecondThen = v; }},
        \\    () => {{ asyncSecondThen = -1; }});
        \\  const asyncCondTicket = asyncCondLock.asyncHold().then((release) => {{
        \\    if (typeof release !== 'function')
        \\      throw new Error('bad async condition initial release');
        \\    const ticket = asyncCond.asyncWait(asyncCondLock);
        \\    Atomics.store(gate, 'asyncCondReady', 1);
        \\    Atomics.notify(gate, 'asyncCondReady');
        \\    return ticket;
        \\  }}).then((release) => {{
        \\    if (typeof release !== 'function')
        \\      throw new Error('bad async condition reacquire release');
        \\    const condKeep = [];
        \\    for (let c = 0; c < {d}; c++)
        \\      condKeep.push({{ c, root: asyncRoot, payload: 'async-cond-' + c }});
        \\    asyncCondScore = asyncRoot.nested.base + 2048 + condKeep.length;
        \\    release();
        \\    asyncCondThen = asyncCondScore;
        \\    Atomics.store(gate, 'asyncCondDone', 1);
        \\    Atomics.notify(gate, 'asyncCondDone');
        \\    return asyncCondScore;
        \\  }}, () => {{
        \\    asyncCondThen = -1;
        \\    Atomics.store(gate, 'asyncCondDone', 1);
        \\    Atomics.notify(gate, 'asyncCondDone');
        \\  }});
        \\  globalThis.__midgcCleanupCount = 0;
        \\  globalThis.__midgcCleanupSum = 0;
        \\  globalThis.__midgcRegistry = (typeof FinalizationRegistry === 'function')
        \\    ? new FinalizationRegistry(function(held) {{
        \\        globalThis.__midgcCleanupCount = globalThis.__midgcCleanupCount + 1;
        \\        globalThis.__midgcCleanupSum = globalThis.__midgcCleanupSum + held;
        \\      }})
        \\    : null;
        \\  const tlsWaiter = new Thread(() => {{
        \\    let target = {{ marker: {d}, nested: {{ label: 'threadlocal-midgc-root' }} }};
        \\    tls.value = target;
        \\    if (globalThis.__midgcRegistry)
        \\      globalThis.__midgcRegistry.register(target, {d});
        \\    target = null;
        \\    Atomics.store(gate, 'tlsReady', 1);
        \\    Atomics.notify(gate, 'tlsReady');
        \\    while (Atomics.load(gate, 'tlsRelease') === 0)
        \\      Atomics.wait(gate, 'tlsRelease', 0, {d});
        \\    const kept = tls.value;
        \\    if (!kept || kept.marker !== {d})
        \\      throw new Error('ThreadLocal midgc root was not preserved');
        \\    return kept;
        \\  }});
        \\  const propWaiter = new Thread(() => {{
        \\    Atomics.store(gate, 'propReady', 1);
        \\    Atomics.notify(gate, 'propReady');
        \\    return Atomics.wait(gate, 'state', 0, {d});
        \\  }});
        \\  const condWaiter = new Thread(() => {{
        \\    condLock.hold(() => {{
        \\      Atomics.store(gate, 'condReady', 1);
        \\      Atomics.notify(gate, 'condReady');
        \\      while (Atomics.load(gate, 'state') === 0) cond.wait(condLock);
        \\    }});
        \\    return 1;
        \\  }});
        \\  const holder = new Thread(() => {{
        \\    heldLock.hold(() => {{
        \\      Atomics.store(gate, 'holderReady', 1);
        \\      Atomics.notify(gate, 'holderReady');
        \\      while (Atomics.load(gate, 'releaseLock') === 0)
        \\        Atomics.wait(gate, 'releaseLock', 0, {d});
        \\    }});
        \\    return 1;
        \\  }});
        \\  while (Atomics.load(gate, 'holderReady') === 0)
        \\    Atomics.wait(gate, 'holderReady', 0, 1);
        \\  const lockWaiter = new Thread(() => {{
        \\    Atomics.store(gate, 'lockReady', 1);
        \\    Atomics.notify(gate, 'lockReady');
        \\    heldLock.hold(() => {{
        \\      Atomics.store(gate, 'lockDone', 1);
        \\    }});
        \\    return 1;
        \\  }});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\  while (Atomics.load(gate, 'lockReady') === 0)
        \\    Atomics.wait(gate, 'lockReady', 0, 1);
        \\  while (Atomics.load(gate, 'tlsReady') === 0)
        \\    Atomics.wait(gate, 'tlsReady', 0, 1);
        \\  while (Atomics.load(gate, 'asyncCondReady') === 0)
        \\    Atomics.wait(gate, 'asyncCondReady', 0, 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const cell = {{ round, i, nested: {{ v: i + round }}, text: 'midgc-' + round + '-' + i }};
        \\      keep.push(cell);
        \\      if (globalThis.__midgcRegistry && ((i + round) & 31) === 0)
        \\        globalThis.__midgcRegistry.register({{ ephemeral: i, round }}, round * {d} + i + 1);
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ never: true }});
        \\  }}
        \\  let asyncSpins = 0;
        \\  while (Atomics.load(gate, 'asyncDone') === 0 && asyncSpins++ < 10000000) ;
        \\  if (Atomics.load(gate, 'asyncDone') !== 1)
        \\    throw new Error('asyncHold grant was not pumped during mid-script GC pressure');
        \\  if (asyncScore !== {d} || asyncThen !== {d})
        \\    throw new Error('bad asyncHold midgc score: ' + asyncScore + '/' + asyncThen);
        \\  let asyncSecondSpins = 0;
        \\  while (Atomics.load(gate, 'asyncSecondDone') === 0 && asyncSecondSpins++ < 10000000) ;
        \\  if (Atomics.load(gate, 'asyncSecondDone') !== 1)
        \\    throw new Error('queued asyncHold grant was not pumped during mid-script GC pressure');
        \\  if (asyncSecondScore !== {d} || asyncSecondThen !== {d})
        \\    throw new Error('bad queued asyncHold midgc score: ' + asyncSecondScore + '/' + asyncSecondThen);
        \\  condLock.hold(() => {{
        \\    Atomics.store(gate, 'state', 1);
        \\    Atomics.notify(gate, 'state');
        \\    cond.notifyAll();
        \\  }});
        \\  if (asyncCond.notifyAll() !== 1)
        \\  {{
        \\    throw new Error('async condition waiter was not queued');
        \\  }}
        \\  let asyncCondSpins = 0;
        \\  while (Atomics.load(gate, 'asyncCondDone') === 0 && asyncCondSpins++ < 2000)
        \\    Atomics.wait(gate, 'asyncCondDone', 0, 1);
        \\  if (Atomics.load(gate, 'asyncCondDone') !== 1)
        \\    throw new Error('async condition waiter did not reacquire during midgc test');
        \\  if (asyncCondScore !== {d} || asyncCondThen !== {d})
        \\    throw new Error('bad async condition midgc score: ' + asyncCondScore + '/' + asyncCondThen);
        \\  Atomics.store(gate, 'releaseLock', 1);
        \\  Atomics.notify(gate, 'releaseLock');
        \\  Atomics.store(gate, 'tlsRelease', 1);
        \\  Atomics.notify(gate, 'tlsRelease');
        \\  const wr = propWaiter.join();
        \\  if (wr !== 'ok' && wr !== 'timed-out') throw new Error('bad property wait result: ' + wr);
        \\  if (condWaiter.join() !== 1) throw new Error('bad condition waiter');
        \\  if (holder.join() !== 1) throw new Error('bad lock holder');
        \\  const lockJoin = lockWaiter.join();
        \\  if (lockJoin !== 1 || Atomics.load(gate, 'lockDone') !== 1) throw new Error('bad lock waiter');
        \\  globalThis.__midgcTlsHold = tlsWaiter.join();
        \\  if (!globalThis.__midgcTlsHold || globalThis.__midgcTlsHold.marker !== {d})
        \\    throw new Error('bad ThreadLocal midgc return');
        \\  if (asyncCondTicket instanceof Promise === false) throw new Error('bad async condition promise');
        \\  return keep.length;
        \\}})();
        \\
    ,
        .{
            async_base,
            async_allocs,
            async_second_allocs,
            async_cond_allocs,
            tls_expected,
            tls_expected + 111,
            wait_timeout_ms,
            tls_expected,
            wait_timeout_ms,
            wait_timeout_ms,
            rounds,
            per_round,
            per_round,
            spin_iters,
            async_expected,
            async_expected,
            async_second_expected,
            async_second_expected,
            async_cond_expected,
            async_cond_expected,
            tls_expected,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const expected: f64 = @floatFromInt(rounds * per_round);
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var i: usize = 0;
        while (i < per_round) : (i += 1) {
            if (((i + round) & 31) == 0) {
                expected_cleanup_count += 1;
                expected_cleanup_sum += round * per_round + i + 1;
            }
        }
    }
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != expected) {
        std.debug.print("seed {d}: midgc result got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc did not finish a parallel collection\n", .{seed});
        return false;
    }
    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  if (globalThis.__midgcRegistry)
        \\    globalThis.__midgcRegistry.cleanupSome(function(held) {{
        \\      globalThis.__midgcCleanupCount = globalThis.__midgcCleanupCount + 1;
        \\      globalThis.__midgcCleanupSum = globalThis.__midgcCleanupSum + held;
        \\    }});
        \\  if (globalThis.__midgcCleanupCount !== {d})
        \\    throw new Error('midgc cleanup count ' + globalThis.__midgcCleanupCount);
        \\  if (globalThis.__midgcCleanupSum !== {d})
        \\    throw new Error('midgc cleanup sum ' + globalThis.__midgcCleanupSum);
        \\  return globalThis.__midgcCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: midgc cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator; // thread-safe; contexts manage their own GC
    var iters: usize = 200;
    var base_seed: u64 = 1;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    const first = args.next();
    // `threadfuzz file <path>`: run one JS file in a parallel context (repro mode).
    if (first) |a| if (std.mem.eql(u8, a, "file")) {
        const path = args.next() orelse {
            std.debug.print("usage: threadfuzz file <path.js>\n", .{});
            std.process.exit(2);
        };
        const src = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(1 << 20)) catch |e| {
            std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(e) });
            std.process.exit(2);
        };
        const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
        defer ctx.destroy();
        if (ctx.evaluate(src)) |v| {
            var machine = ctx.interpreter();
            const rendered = machine.toStringV(v) catch "<unstringifiable>";
            std.debug.print("ok: {s} => {s}\n", .{ path, rendered });
        } else |e| {
            const msg = if (ctx.exception) |ex| blk: {
                var machine = ctx.interpreter();
                break :blk machine.toStringV(ex) catch "<unstringifiable>";
            } else "<none>";
            std.debug.print("throw {s}: {s}\n", .{ @errorName(e), msg });
            std.process.exit(1);
        }
        return;
    };
    // `threadfuzz verify <iters> <seed>`: deterministic-correctness mode — each
    // generated program's exact result is predicted and checked, catching
    // wrong-value (lost/torn atomic) bugs the no-throw oracle misses.
    if (first) |a| if (std.mem.eql(u8, a, "verify")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 200;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var vfail: usize = 0;
        var vi: usize = 0;
        while (vi < iters) : (vi += 1) {
            const seed = base_seed +% vi;
            var vbuf: std.ArrayListUnmanaged(u8) = .empty;
            defer vbuf.deinit(gpa);
            const expected = try genVerify(seed, &vbuf, gpa);
            const ctx = js.Context.createWith(gpa, .{ .enable_threads = true }) catch {
                std.debug.print("seed {d}: context creation failed\n", .{seed});
                vfail += 1;
                continue;
            };
            defer ctx.destroy();
            if (ctx.evaluate(vbuf.items)) |v| {
                const got = if (v.isNumber()) v.asNum() else -1;
                if (got != expected) {
                    std.debug.print("seed {d}: WRONG RESULT got {d} expected {d} (lost atomic update)\n", .{ seed, got, expected });
                    vfail += 1;
                }
            } else |e| {
                std.debug.print("seed {d}: unexpected throw {s}\n", .{ seed, @errorName(e) });
                vfail += 1;
            }
        }
        std.debug.print("threadfuzz verify: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, vfail });
        if (vfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz lifecycle <iters> <seed>`: deterministic termination storms,
    // Worker/thread SAB overlap, simple, diamond, and fanout/rejoin
    // module-worker/thread overlap, exact Worker close/terminate/postMessage
    // FIFO drain/drop ordering, worker handler exception recovery,
    // Worker/thread/finalization scheduling,
    // Thread exception identity and returned waitAsync promise assimilation
    // across join/asyncJoin while waiters are parked, cross-thread
    // FinalizationRegistry cleanup, FinalizationRegistry cleanup interleaved
    // with join/asyncJoin and unregister tokens, cleanup
    // delivery after parked property/condition waiters resume,
    // asyncHold barging delivery after a deterministic queued ticket,
    // Thread.restrict lifecycle isolation, and ThreadLocal isolation across
    // nested threads plus throwing and async-joined workers. The oracle is not "no
    // throw":
    // termination storms must throw from the main script and still tear down
    // cleanly, overlap must produce exact synchronized counter values, and
    // close/terminate races must drain queued messages in FIFO order, drop
    // post-close messages, and keep post-terminate receives closed; thrown
    // worker handlers must not poison later deliveries,
    // Worker/thread/finalization scheduling must preserve the retained-SAB
    // counter plus exact cleanup delivery, thread exceptions must keep identity
    // through blocking and async joiners,
    // thread-returned waitAsync promises must settle through join/asyncJoin
    // while waiters resume cleanly, cleanup delivery must match exact count/sum
    // oracles when thread results are observed through both join paths, when
    // unregister tokens suppress some records, and after parked property and
    // condition waiters resume; asyncHold barging must deliver a pending
    // no-fn grant after a sync hold legally overtakes it; ThreadLocal values must stay
    // per-thread across normal, throwing, nested, and async-joined lifecycles.
    if (first) |a| if (std.mem.eql(u8, a, "lifecycle")) {
        iters = 60;
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch iters;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var lfail: usize = 0;
        var li: usize = 0;
        while (li < iters) : (li += 1) {
            const seed = base_seed +% li;
            if (!(try runTerminationStorm(gpa, seed))) lfail += 1;
            if (!(try runWorkerThreadOverlap(gpa, seed))) lfail += 1;
            if (!(try runModuleWorkerThreadOverlap(gpa, seed))) lfail += 1;
            if (!(try runModuleWorkerGraphOverlap(gpa, seed))) lfail += 1;
            if (!(try runModuleWorkerFanoutOverlap(gpa, seed))) lfail += 1;
            if (!(try runWorkerCloseTerminateRace(gpa, seed))) lfail += 1;
            if (!(try runWorkerExceptionRecovery(gpa, seed))) lfail += 1;
            if (!(try runWorkerThreadFinalizationInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadExceptionWaiterInterleaving(gpa, seed))) lfail += 1;
            if (!(try runReturnedWaitAsyncLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationAsyncJoinCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationWaiterCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runAsyncHoldBargingLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadRestrictLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadLocalLifecycleInterleaving(gpa, seed))) lfail += 1;
        }
        std.debug.print("threadfuzz lifecycle: {d} programs from seed {d}, {d} failures\n", .{ iters * 16, base_seed, lfail });
        if (lfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgc <iters> <seed>`: targeted mid-script parallel-GC
    // profile. Each seed blocks peers in property `Atomics.wait`,
    // `Condition.wait`, and contended `Lock` acquisition while allocation
    // pressure triggers the experimental collector. The oracle requires exact
    // program completion and at least one finishing parallel sweep.
    if (first) |a| if (std.mem.eql(u8, a, "midgc")) {
        iters = 20;
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch iters;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mfail: usize = 0;
        var mi: usize = 0;
        while (mi < iters) : (mi += 1) {
            const seed = base_seed +% mi;
            if (!(try runMidScriptWaitPumpGc(gpa, seed))) mfail += 1;
        }
        std.debug.print("threadfuzz midgc: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mfail });
        if (mfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz amplify <iters> <seed>`: high-contention profile (more threads,
    // longer loops) — the stress-amplification mode for surfacing rare races.
    // `threadfuzz broad <iters> <seed>`: wider semantic profile — exceptions,
    // lifecycle/asyncJoin, waiters, FinalizationRegistry cleanup, and lock/cond
    // edges. It is intentionally cheaper than amplify but enables GC.
    var cfg = Cfg.default;
    var rest = first;
    if (first) |a| if (std.mem.eql(u8, a, "amplify")) {
        cfg = Cfg.amplified;
        iters = 60; // amplified programs are heavier; fewer per run
        rest = args.next();
    } else if (std.mem.eql(u8, a, "broad")) {
        cfg = Cfg.broad;
        iters = 80; // broader programs include sidecars + GC; keep the gate cheap
        rest = args.next();
    };
    if (rest) |a| iters = std.fmt.parseInt(usize, a, 10) catch iters;
    if (args.next()) |a| base_seed = std.fmt.parseInt(u64, a, 10) catch 1;

    var failures: usize = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const seed = base_seed +% i;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        try genProgram(seed, &buf, gpa, cfg);
        const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = cfg.enable_gc }) catch {
            std.debug.print("seed {d}: context creation failed\n", .{seed});
            failures += 1;
            continue;
        };
        defer ctx.destroy();
        if (ctx.evaluate(buf.items)) |_| {
            // ok — completed (no deadlock), engine TSan-clean if built with -Dtsan
        } else |e| {
            const msg = if (ctx.exception) |ex| blk: {
                var machine = ctx.interpreter();
                break :blk machine.toStringV(ex) catch "<unstringifiable>";
            } else "<none>";
            std.debug.print("seed {d}: unexpected throw {s}: {s}\n", .{ seed, @errorName(e), msg });
            failures += 1;
        }
    }
    std.debug.print("threadfuzz: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, failures });
    if (failures != 0) std.process.exit(1);
}
