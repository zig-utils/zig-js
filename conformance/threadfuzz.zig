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

const ModuleTerminateFuzzHost = struct {
    const Entry = struct { path: []const u8, source: []const u8 };
    var host_ctx: u8 = 0;
    const entries = [_]Entry{
        .{
            .path = "spin.js",
            .source =
            \\export function spin(v) {
            \\  for (;;) Atomics.add(v, 1, 1);
            \\}
            ,
        },
        .{
            .path = "entry.js",
            .source =
            \\import { spin } from "./spin.js";
            \\globalThis.onmessage = (e) => {
            \\  const v = new Int32Array(e.data.sab);
            \\  Atomics.add(v, 0, 1);
            \\  Atomics.notify(v, 0);
            \\  spin(v);
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

fn runWorkerExceptionFinalizationCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7765_7863_6669_6e63);
    const r = prng.random();
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const per_thread = 6 + r.uintLessThan(usize, 8);
    const pings = 2 + r.uintLessThan(usize, 5);

    var expected_join_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 55_000;
        expected_join_sum += base + per_thread + id;
        expected_cleanup_count += per_thread;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) expected_cleanup_sum += base + i;
    }
    var expected_worker_total: i64 = 1; // handler-throw message increments once.
    var pi: usize = 0;
    while (pi < pings) : (pi += 1) expected_worker_total += @intCast(20 + pi);
    const expected_thread_counter = nthreads * per_thread;

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker exception/finalization context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    _ = ctx.evaluate(
        \\globalThis.__workerExcFinSab = new SharedArrayBuffer(32);
        \\globalThis.__workerExcFinMsg = function(cmd, id) {
        \\  return { sab: globalThis.__workerExcFinSab, cmd, id };
        \\};
        \\1
    ) catch |err| {
        std.debug.print("seed {d}: cannot create worker exception/finalization message factory: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  if (e.data.cmd === 'throw') {
        \\    Atomics.add(v, 0, 1);
        \\    Atomics.notify(v, 0);
        \\    throw new Error('expected worker exception/finalization throw');
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
        std.debug.print("seed {d}: worker exception/finalization spawn failed\n", .{seed});
        return false;
    };
    var cleanup_worker = true;
    defer if (cleanup_worker) {
        w.terminate();
        w.join();
        w.destroy();
    };

    const throw_msg = ctx.evaluate("__workerExcFinMsg('throw', 0)") catch |err| {
        std.debug.print("seed {d}: cannot make worker exception/finalization throw message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    w.postMessage(&machine, throw_msg) catch |err| {
        std.debug.print("seed {d}: worker exception/finalization throw post failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    pi = 0;
    while (pi < pings) : (pi += 1) {
        const msg_src = try std.fmt.allocPrint(gpa, "__workerExcFinMsg('ping', {d})", .{20 + pi});
        defer gpa.free(msg_src);
        const ping_msg = ctx.evaluate(msg_src) catch |err| {
            std.debug.print("seed {d}: cannot make worker exception/finalization ping message: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        w.postMessage(&machine, ping_msg) catch |err| {
            std.debug.print("seed {d}: worker exception/finalization ping post failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }
    const close_msg = ctx.evaluate("__workerExcFinMsg('close', 0)") catch |err| {
        std.debug.print("seed {d}: cannot make worker exception/finalization close message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    w.postMessage(&machine, close_msg) catch |err| {
        std.debug.print("seed {d}: worker exception/finalization close post failed: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    w.close();

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerExcFinCleanupCount = 0;
        \\  globalThis.__workerExcFinCleanupSum = 0;
        \\  globalThis.__workerExcFinOracle = 0;
        \\  globalThis.__workerExcFinRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__workerExcFinCleanupCount++;
        \\    globalThis.__workerExcFinCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__workerExcFinRegistry;
        \\  const v = new Int32Array(globalThis.__workerExcFinSab);
        \\  const threads = [];
        \\  let asyncSum = 0;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      const local = new Int32Array(globalThis.__workerExcFinSab);
        \\      const base = (id + 1) * 55000;
        \\      for (let i = 0; i < per; i++) {{
        \\        Atomics.add(local, 1, 1);
        \\        let target = {{ id, i, payload: 'worker-exception-finalization-' + id + '-' + i }};
        \\        registry.register(target, base + i);
        \\        target = null;
        \\      }}
        \\      Atomics.add(local, 2, 1);
        \\      return base + per + id;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (value) => {{ asyncSum += value; }},
        \\      () => {{ asyncSum = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  let joinSum = 0;
        \\  for (const t of threads) joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad worker exception/finalization join sum ' + joinSum);
        \\  if (Atomics.load(v, 1) !== {d})
        \\    throw new Error('bad worker exception/finalization thread counter ' + Atomics.load(v, 1));
        \\  if (Atomics.load(v, 2) !== {d})
        \\    throw new Error('bad worker exception/finalization done count ' + Atomics.load(v, 2));
        \\  threads.length = 0;
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSum !== {d})
        \\      throw new Error('bad worker exception/finalization async sum ' + asyncSum);
        \\    globalThis.__workerExcFinOracle = 1;
        \\  }});
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{ nthreads, per_thread, expected_join_sum, expected_thread_counter, nthreads, expected_join_sum },
    );
    defer gpa.free(js_src);
    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker exception/finalization JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: worker exception/finalization joined got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__workerExcFinOracle") catch |err| {
        std.debug.print("seed {d}: cannot read worker exception/finalization oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: worker exception/finalization oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }

    var replies: usize = 0;
    var saw_close = false;
    while (true) {
        const reply = w.receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: worker exception/finalization receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        } orelse break;
        const closed = machine.getProperty(reply, "closed") catch js.Value.undef();
        if (closed.isBoolean() and closed.asBool()) {
            const total = machine.getProperty(reply, "total") catch |err| {
                std.debug.print("seed {d}: cannot read worker exception/finalization close total: {s}\n", .{ seed, @errorName(err) });
                return false;
            };
            if (!total.isNumber() or total.asNum() != @as(f64, @floatFromInt(expected_worker_total))) {
                std.debug.print("seed {d}: worker exception/finalization close total got {d}, expected {d}\n", .{ seed, if (total.isNumber()) total.asNum() else -1, expected_worker_total });
                return false;
            }
            saw_close = true;
            continue;
        }
        const ack = machine.getProperty(reply, "ack") catch |err| {
            std.debug.print("seed {d}: cannot read worker exception/finalization ack: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const after = machine.getProperty(reply, "after") catch |err| {
            std.debug.print("seed {d}: cannot read worker exception/finalization after: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!ack.isNumber() or !after.isNumber()) {
            std.debug.print("seed {d}: worker exception/finalization reply missing numeric fields\n", .{seed});
            return false;
        }
        replies += 1;
    }
    if (replies != pings or !saw_close) {
        std.debug.print("seed {d}: worker exception/finalization replies={d}/{d} saw_close={}\n", .{ seed, replies, pings, saw_close });
        return false;
    }
    w.join();
    w.destroy();
    cleanup_worker = false;

    const worker_total = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__workerExcFinSab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read worker exception/finalization worker counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!worker_total.isNumber() or worker_total.asNum() != @as(f64, @floatFromInt(expected_worker_total))) {
        std.debug.print("seed {d}: worker exception/finalization worker counter got {d}, expected {d}\n", .{ seed, if (worker_total.isNumber()) worker_total.asNum() else -1, expected_worker_total });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerExcFinRegistry.cleanupSome();
        \\  if (globalThis.__workerExcFinCleanupCount !== {d})
        \\    throw new Error('bad worker exception/finalization cleanup count: ' + globalThis.__workerExcFinCleanupCount);
        \\  if (globalThis.__workerExcFinCleanupSum !== {d})
        \\    throw new Error('bad worker exception/finalization cleanup sum: ' + globalThis.__workerExcFinCleanupSum);
        \\  return globalThis.__workerExcFinCleanupCount;
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
        std.debug.print("seed {d}: worker exception/finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: worker exception/finalization cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
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

fn runWorkerTerminateFinalizationInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7465_726d_5f66_696e);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 3);
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const per_thread = 7 + r.uintLessThan(usize, 12);

    var expected_join_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 40_000;
        expected_join_sum += base + per_thread + id;
        expected_cleanup_count += per_thread;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) expected_cleanup_sum += base + i;
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker terminate/finalization context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg = ctx.evaluate(
        \\globalThis.__workerTermFinMsg = { sab: new SharedArrayBuffer(40) };
        \\globalThis.__workerTermFinMsg
    ) catch |err| {
        std.debug.print("seed {d}: cannot create worker terminate/finalization message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  Atomics.add(v, 0, 1);
        \\  Atomics.notify(v, 0);
        \\  for (;;) {
        \\    Atomics.add(v, 4, 1);
        \\  }
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
            std.debug.print("seed {d}: worker terminate/finalization worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: worker terminate/finalization postMessage failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const ready_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const v = new Int32Array(globalThis.__workerTermFinMsg.sab);
        \\  let spins = 0;
        \\  while (Atomics.load(v, 0) < {d} && spins++ < 10000000)
        \\    Atomics.wait(v, 0, Atomics.load(v, 0), 1);
        \\  if (Atomics.load(v, 0) !== {d})
        \\    throw new Error('worker terminate/finalization workers not ready: ' + Atomics.load(v, 0));
        \\  return Atomics.load(v, 0);
        \\}})();
        \\
    ,
        .{ nworkers, nworkers },
    );
    defer gpa.free(ready_src);
    const ready = ctx.evaluate(ready_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker terminate/finalization readiness threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!ready.isNumber() or ready.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: worker terminate/finalization ready got {d}, expected {d}\n", .{ seed, if (ready.isNumber()) ready.asNum() else -1, nworkers });
        return false;
    }

    const js_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerTermFinCleanupCount = 0;
        \\  globalThis.__workerTermFinCleanupSum = 0;
        \\  globalThis.__workerTermFinOracle = 0;
        \\  globalThis.__workerTermFinRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__workerTermFinCleanupCount++;
        \\    globalThis.__workerTermFinCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__workerTermFinRegistry;
        \\  const v = new Int32Array(globalThis.__workerTermFinMsg.sab);
        \\  const threads = [];
        \\  let asyncSum = 0;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per) => {{
        \\      const local = new Int32Array(globalThis.__workerTermFinMsg.sab);
        \\      const base = (id + 1) * 40000;
        \\      for (let i = 0; i < per; i++) {{
        \\        Atomics.add(local, 2, 1);
        \\        let target = {{ id, i, sab: globalThis.__workerTermFinMsg.sab }};
        \\        registry.register(target, base + i);
        \\        target = null;
        \\      }}
        \\      Atomics.add(local, 3, 1);
        \\      return base + per + id;
        \\    }}, id, {d});
        \\    t.asyncJoin().then(
        \\      (value) => {{ asyncSum += value; }},
        \\      () => {{ asyncSum = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  let joinSum = 0;
        \\  for (const t of threads) joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad worker terminate/finalization join sum ' + joinSum);
        \\  if (Atomics.load(v, 2) !== {d})
        \\    throw new Error('bad worker terminate/finalization thread counter ' + Atomics.load(v, 2));
        \\  if (Atomics.load(v, 3) !== {d})
        \\    throw new Error('bad worker terminate/finalization thread done count ' + Atomics.load(v, 3));
        \\  threads.length = 0;
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSum !== {d})
        \\      throw new Error('bad worker terminate/finalization async sum ' + asyncSum);
        \\    globalThis.__workerTermFinOracle = 1;
        \\  }});
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{ nthreads, per_thread, expected_join_sum, nthreads * per_thread, nthreads, expected_join_sum },
    );
    defer gpa.free(js_src);

    const joined = ctx.evaluate(js_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker terminate/finalization JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: worker terminate/finalization joined got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__workerTermFinOracle") catch |err| {
        std.debug.print("seed {d}: cannot read worker terminate/finalization oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: worker terminate/finalization oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }

    for (workers.items) |w| {
        w.terminate();
        w.join();
        const reply = w.receive(&machine, 0) catch |err| {
            std.debug.print("seed {d}: worker terminate/finalization receive after terminate failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (reply != null) {
            std.debug.print("seed {d}: worker terminate/finalization delivered a post-terminate reply\n", .{seed});
            return false;
        }
        w.destroy();
    }
    cleanup_workers = false;

    const counter = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__workerTermFinMsg.sab), 2)") catch |err| {
        std.debug.print("seed {d}: cannot read worker terminate/finalization counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!counter.isNumber() or counter.asNum() != @as(f64, @floatFromInt(nthreads * per_thread))) {
        std.debug.print("seed {d}: worker terminate/finalization counter got {d}, expected {d}\n", .{ seed, if (counter.isNumber()) counter.asNum() else -1, nthreads * per_thread });
        return false;
    }
    const worker_ready = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__workerTermFinMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read worker terminate/finalization ready counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!worker_ready.isNumber() or worker_ready.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: worker terminate/finalization worker ready got {d}, expected {d}\n", .{ seed, if (worker_ready.isNumber()) worker_ready.asNum() else -1, nworkers });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerTermFinRegistry.cleanupSome();
        \\  if (globalThis.__workerTermFinCleanupCount !== {d})
        \\    throw new Error('bad worker terminate/finalization cleanup count: ' + globalThis.__workerTermFinCleanupCount);
        \\  if (globalThis.__workerTermFinCleanupSum !== {d})
        \\    throw new Error('bad worker terminate/finalization cleanup sum: ' + globalThis.__workerTermFinCleanupSum);
        \\  return globalThis.__workerTermFinCleanupCount;
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
        std.debug.print("seed {d}: worker terminate/finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: worker terminate/finalization cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runWorkerTerminateThreadTeardownInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7774_6572_6d5f_7464);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 2);
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const ncleanup = 10 + r.uintLessThan(usize, 10);
    const seed_marker = seed % 10_000;
    const cleanup_base = 410_000 + seed_marker;
    const reject_base = 420_000 + seed_marker;

    var expected_cleanup_sum: usize = 0;
    var ci: usize = 0;
    while (ci < ncleanup) : (ci += 1) expected_cleanup_sum += cleanup_base + ci;
    var expected_reject_sum: usize = 0;
    var ti: usize = 0;
    while (ti < nthreads) : (ti += 1) expected_reject_sum += reject_base + ti;

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker terminate/thread teardown context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const setup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerTermThreadMsg = {{ sab: new SharedArrayBuffer(32) }};
        \\  globalThis.__workerTermThreadRejectScore = 0;
        \\  globalThis.__workerTermThreadRejectCount = 0;
        \\  globalThis.__workerTermThreadCleanupCount = 0;
        \\  globalThis.__workerTermThreadCleanupSum = 0;
        \\  globalThis.__workerTermThreadRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__workerTermThreadCleanupCount++;
        \\    globalThis.__workerTermThreadCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__workerTermThreadRegistry;
        \\  for (let i = 0; i < {d}; i++) {{
        \\    let target = {{ i, seed: {d}, label: 'worker-terminate-thread-teardown-cleanup-' + i }};
        \\    registry.register(target, {d} + i);
        \\    target = null;
        \\  }}
        \\  return {d};
        \\}})();
        \\
    ,
        .{ ncleanup, seed, cleanup_base, ncleanup },
    );
    defer gpa.free(setup_src);
    const setup_result = ctx.evaluate(setup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker terminate/thread teardown setup threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!setup_result.isNumber() or setup_result.asNum() != @as(f64, @floatFromInt(ncleanup))) {
        std.debug.print("seed {d}: worker terminate/thread teardown setup got {d}, expected {d}\n", .{ seed, if (setup_result.isNumber()) setup_result.asNum() else -1, ncleanup });
        return false;
    }
    ctx.collectGarbage();

    const msg = ctx.evaluate("globalThis.__workerTermThreadMsg") catch |err| {
        std.debug.print("seed {d}: cannot read worker terminate/thread teardown message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  Atomics.add(v, 0, 1);
        \\  Atomics.notify(v, 0);
        \\  for (;;) {
        \\    Atomics.add(v, 1, 1);
        \\  }
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
            std.debug.print("seed {d}: worker terminate/thread teardown worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: worker terminate/thread teardown post failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const ready_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const v = new Int32Array(globalThis.__workerTermThreadMsg.sab);
        \\  let spins = 0;
        \\  while (Atomics.load(v, 0) < {d} && spins++ < 10000000)
        \\    Atomics.wait(v, 0, Atomics.load(v, 0), 1);
        \\  if (Atomics.load(v, 0) !== {d})
        \\    throw new Error('worker terminate/thread teardown workers not ready: ' + Atomics.load(v, 0));
        \\  if (Atomics.load(v, 1) <= 0)
        \\    throw new Error('worker terminate/thread teardown workers did not spin');
        \\  return Atomics.load(v, 0);
        \\}})();
        \\
    ,
        .{ nworkers, nworkers },
    );
    defer gpa.free(ready_src);
    const ready = ctx.evaluate(ready_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker terminate/thread teardown readiness threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!ready.isNumber() or ready.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: worker terminate/thread teardown ready got {d}, expected {d}\n", .{ seed, if (ready.isNumber()) ready.asNum() else -1, nworkers });
        return false;
    }

    const fail_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const gate = {{ ready: 0, stop: 0 }};
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const reactionRoot = {{
        \\      marker: {d} + id,
        \\      nested: {{ seed: {d}, label: 'worker-terminate-thread-teardown-asyncJoin-root' }},
        \\    }};
        \\    const t = new Thread((gate) => {{
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      while (Atomics.load(gate, 'stop') === 0)
        \\        Atomics.wait(gate, 'stop', 0, 1000);
        \\      return -1;
        \\    }}, gate);
        \\    t.asyncJoin().then(
        \\      () => {{ globalThis.__workerTermThreadRejectScore = -1000000; }},
        \\      (e) => {{
        \\        if (e && reactionRoot.marker === {d} + id && reactionRoot.nested.seed === {d}) {{
        \\          globalThis.__workerTermThreadRejectScore += reactionRoot.marker;
        \\          globalThis.__workerTermThreadRejectCount++;
        \\        }} else {{
        \\          globalThis.__workerTermThreadRejectScore = -1000000;
        \\        }}
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  throw new Error('threadfuzz worker terminate/thread teardown {d}');
        \\}})();
        \\
    ,
        .{ nthreads, reject_base, seed, reject_base, seed, nthreads, seed },
    );
    defer gpa.free(fail_src);
    if (ctx.evaluate(fail_src)) |_| {
        std.debug.print("seed {d}: worker terminate/thread teardown failure script returned normally\n", .{seed});
        return false;
    } else |err| {
        if (err != error.Throw) {
            std.debug.print("seed {d}: worker terminate/thread teardown failed with {s}\n", .{ seed, @errorName(err) });
            return false;
        }
    }

    _ = ctx.evaluate("$drainRunLoop()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker terminate/thread teardown drain threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const check_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  if (globalThis.__workerTermThreadRejectScore !== {d})
        \\    throw new Error('bad worker terminate/thread teardown reject score ' + globalThis.__workerTermThreadRejectScore);
        \\  if (globalThis.__workerTermThreadRejectCount !== {d})
        \\    throw new Error('bad worker terminate/thread teardown reject count ' + globalThis.__workerTermThreadRejectCount);
        \\  globalThis.__workerTermThreadRegistry.cleanupSome();
        \\  if (globalThis.__workerTermThreadCleanupCount !== {d})
        \\    throw new Error('bad worker terminate/thread teardown cleanup count ' + globalThis.__workerTermThreadCleanupCount);
        \\  if (globalThis.__workerTermThreadCleanupSum !== {d})
        \\    throw new Error('bad worker terminate/thread teardown cleanup sum ' + globalThis.__workerTermThreadCleanupSum);
        \\  return globalThis.__workerTermThreadRejectCount + globalThis.__workerTermThreadCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_reject_sum, nthreads, ncleanup, expected_cleanup_sum },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker terminate/thread teardown check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != @as(f64, @floatFromInt(nthreads + ncleanup))) {
        std.debug.print("seed {d}: worker terminate/thread teardown checked got {d}, expected {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1, nthreads + ncleanup });
        return false;
    }

    for (workers.items) |w| {
        w.terminate();
        w.join();
        const reply = w.receive(&machine, 0) catch |err| {
            std.debug.print("seed {d}: worker terminate/thread teardown receive after terminate failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (reply != null) {
            std.debug.print("seed {d}: worker terminate/thread teardown delivered a post-terminate reply\n", .{seed});
            return false;
        }
        w.destroy();
    }
    cleanup_workers = false;

    const worker_ready = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__workerTermThreadMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read worker terminate/thread teardown ready counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!worker_ready.isNumber() or worker_ready.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: worker terminate/thread teardown worker ready got {d}, expected {d}\n", .{ seed, if (worker_ready.isNumber()) worker_ready.asNum() else -1, nworkers });
        return false;
    }
    return true;
}

fn runModuleWorkerTerminateThreadTeardownInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d6f_6474_6572_6d74);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 2);
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const ncleanup = 10 + r.uintLessThan(usize, 10);
    const seed_marker = seed % 10_000;
    const cleanup_base = 430_000 + seed_marker;
    const reject_base = 440_000 + seed_marker;

    var expected_cleanup_sum: usize = 0;
    var ci: usize = 0;
    while (ci < ncleanup) : (ci += 1) expected_cleanup_sum += cleanup_base + ci;
    var expected_reject_sum: usize = 0;
    var ti: usize = 0;
    while (ti < nthreads) : (ti += 1) expected_reject_sum += reject_base + ti;

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: module worker terminate/thread teardown context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const setup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__moduleTermThreadMsg = {{ sab: new SharedArrayBuffer(32) }};
        \\  globalThis.__moduleTermThreadRejectScore = 0;
        \\  globalThis.__moduleTermThreadRejectCount = 0;
        \\  globalThis.__moduleTermThreadCleanupCount = 0;
        \\  globalThis.__moduleTermThreadCleanupSum = 0;
        \\  globalThis.__moduleTermThreadRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__moduleTermThreadCleanupCount++;
        \\    globalThis.__moduleTermThreadCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__moduleTermThreadRegistry;
        \\  for (let i = 0; i < {d}; i++) {{
        \\    let target = {{ i, seed: {d}, label: 'module-worker-terminate-thread-teardown-cleanup-' + i }};
        \\    registry.register(target, {d} + i);
        \\    target = null;
        \\  }}
        \\  return {d};
        \\}})();
        \\
    ,
        .{ ncleanup, seed, cleanup_base, ncleanup },
    );
    defer gpa.free(setup_src);
    const setup_result = ctx.evaluate(setup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module worker terminate/thread teardown setup threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!setup_result.isNumber() or setup_result.asNum() != @as(f64, @floatFromInt(ncleanup))) {
        std.debug.print("seed {d}: module worker terminate/thread teardown setup got {d}, expected {d}\n", .{ seed, if (setup_result.isNumber()) setup_result.asNum() else -1, ncleanup });
        return false;
    }
    ctx.collectGarbage();

    const msg = ctx.evaluate("globalThis.__moduleTermThreadMsg") catch |err| {
        std.debug.print("seed {d}: cannot read module worker terminate/thread teardown message: {s}\n", .{ seed, @errorName(err) });
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
        const w = Worker.spawnModule("entry.js", ModuleTerminateFuzzHost.entries[1].source, ModuleTerminateFuzzHost.host()) catch {
            std.debug.print("seed {d}: module worker terminate/thread teardown worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: module worker terminate/thread teardown post failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const ready_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const v = new Int32Array(globalThis.__moduleTermThreadMsg.sab);
        \\  let spins = 0;
        \\  while (Atomics.load(v, 0) < {d} && spins++ < 10000000)
        \\    Atomics.wait(v, 0, Atomics.load(v, 0), 1);
        \\  if (Atomics.load(v, 0) !== {d})
        \\    throw new Error('module worker terminate/thread teardown workers not ready: ' + Atomics.load(v, 0));
        \\  spins = 0;
        \\  while (Atomics.load(v, 1) <= 0 && spins++ < 10000000)
        \\    ;
        \\  if (Atomics.load(v, 1) <= 0)
        \\    throw new Error('module worker terminate/thread teardown workers did not spin');
        \\  return Atomics.load(v, 0);
        \\}})();
        \\
    ,
        .{ nworkers, nworkers },
    );
    defer gpa.free(ready_src);
    const ready = ctx.evaluate(ready_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module worker terminate/thread teardown readiness threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!ready.isNumber() or ready.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: module worker terminate/thread teardown ready got {d}, expected {d}\n", .{ seed, if (ready.isNumber()) ready.asNum() else -1, nworkers });
        return false;
    }

    const fail_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const gate = {{ ready: 0, stop: 0 }};
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const reactionRoot = {{
        \\      marker: {d} + id,
        \\      nested: {{ seed: {d}, label: 'module-worker-terminate-thread-teardown-asyncJoin-root' }},
        \\    }};
        \\    const t = new Thread((gate) => {{
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      while (Atomics.load(gate, 'stop') === 0)
        \\        Atomics.wait(gate, 'stop', 0, 1000);
        \\      return -1;
        \\    }}, gate);
        \\    t.asyncJoin().then(
        \\      () => {{ globalThis.__moduleTermThreadRejectScore = -1000000; }},
        \\      (e) => {{
        \\        if (e && reactionRoot.marker === {d} + id && reactionRoot.nested.seed === {d}) {{
        \\          globalThis.__moduleTermThreadRejectScore += reactionRoot.marker;
        \\          globalThis.__moduleTermThreadRejectCount++;
        \\        }} else {{
        \\          globalThis.__moduleTermThreadRejectScore = -1000000;
        \\        }}
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  throw new Error('threadfuzz module worker terminate/thread teardown {d}');
        \\}})();
        \\
    ,
        .{ nthreads, reject_base, seed, reject_base, seed, nthreads, seed },
    );
    defer gpa.free(fail_src);
    if (ctx.evaluate(fail_src)) |_| {
        std.debug.print("seed {d}: module worker terminate/thread teardown failure script returned normally\n", .{seed});
        return false;
    } else |err| {
        if (err != error.Throw) {
            std.debug.print("seed {d}: module worker terminate/thread teardown failed with {s}\n", .{ seed, @errorName(err) });
            return false;
        }
    }

    _ = ctx.evaluate("$drainRunLoop()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module worker terminate/thread teardown drain threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const check_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  if (globalThis.__moduleTermThreadRejectScore !== {d})
        \\    throw new Error('bad module worker terminate/thread teardown reject score ' + globalThis.__moduleTermThreadRejectScore);
        \\  if (globalThis.__moduleTermThreadRejectCount !== {d})
        \\    throw new Error('bad module worker terminate/thread teardown reject count ' + globalThis.__moduleTermThreadRejectCount);
        \\  globalThis.__moduleTermThreadRegistry.cleanupSome();
        \\  if (globalThis.__moduleTermThreadCleanupCount !== {d})
        \\    throw new Error('bad module worker terminate/thread teardown cleanup count ' + globalThis.__moduleTermThreadCleanupCount);
        \\  if (globalThis.__moduleTermThreadCleanupSum !== {d})
        \\    throw new Error('bad module worker terminate/thread teardown cleanup sum ' + globalThis.__moduleTermThreadCleanupSum);
        \\  return globalThis.__moduleTermThreadRejectCount + globalThis.__moduleTermThreadCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_reject_sum, nthreads, ncleanup, expected_cleanup_sum },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: module worker terminate/thread teardown check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != @as(f64, @floatFromInt(nthreads + ncleanup))) {
        std.debug.print("seed {d}: module worker terminate/thread teardown checked got {d}, expected {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1, nthreads + ncleanup });
        return false;
    }

    for (workers.items) |w| {
        w.terminate();
        w.join();
        const reply = w.receive(&machine, 0) catch |err| {
            std.debug.print("seed {d}: module worker terminate/thread teardown receive after terminate failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (reply != null) {
            std.debug.print("seed {d}: module worker terminate/thread teardown delivered a post-terminate reply\n", .{seed});
            return false;
        }
        w.destroy();
    }
    cleanup_workers = false;

    const worker_ready = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__moduleTermThreadMsg.sab), 0)") catch |err| {
        std.debug.print("seed {d}: cannot read module worker terminate/thread teardown ready counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!worker_ready.isNumber() or worker_ready.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: module worker terminate/thread teardown worker ready got {d}, expected {d}\n", .{ seed, if (worker_ready.isNumber()) worker_ready.asNum() else -1, nworkers });
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

fn runWaitAsyncFinalizationCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7761_6669_6e61_6c73);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 4);
    const per_thread = 6 + r.uintLessThan(usize, 8);
    const wait_timeout_ms = 1200 + r.uintLessThan(usize, 800);

    var expected_wait_score: usize = 0;
    var expected_join_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 30_000;
        expected_wait_score += base + id;
        expected_cleanup_count += per_thread + 1;
        expected_cleanup_sum += base + 100_000;
        var local_sum: usize = 0;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) {
            local_sum += base + i;
            expected_cleanup_sum += base + i;
        }
        expected_join_sum += local_sum + id + 1;
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: waitAsync/finalization context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__waitAsyncFinCleanupCount = 0;
        \\  globalThis.__waitAsyncFinCleanupSum = 0;
        \\  globalThis.__waitAsyncFinWaitScore = 0;
        \\  globalThis.__waitAsyncFinAsyncJoinScore = 0;
        \\  globalThis.__waitAsyncFinRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__waitAsyncFinCleanupCount++;
        \\    globalThis.__waitAsyncFinCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__waitAsyncFinRegistry;
        \\  const view = new Int32Array(new SharedArrayBuffer({d} * 4));
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const base = (id + 1) * 30000;
        \\    let mainTarget = {{ id, kind: 'main-waitAsync-finalization' }};
        \\    registry.register(mainTarget, base + 100000);
        \\    mainTarget = null;
        \\    const reactionRoot = {{ marker: base + id, nested: {{ label: 'waitAsync-finalization-root', seed: {d} }} }};
        \\    const waiter = Atomics.waitAsync(view, id, 0, {d});
        \\    if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\      throw new Error('bad waitAsync/finalization pending shape');
        \\    waiter.value.then(
        \\      (v) => {{
        \\        if (v === 'ok' && reactionRoot.marker === base + id && reactionRoot.nested.seed === {d})
        \\          globalThis.__waitAsyncFinWaitScore += reactionRoot.marker;
        \\        else
        \\          globalThis.__waitAsyncFinWaitScore = -1000000;
        \\      }},
        \\      () => {{ globalThis.__waitAsyncFinWaitScore = -1000000; }});
        \\    const t = new Thread((view, id, per, registry) => {{
        \\      const base = (id + 1) * 30000;
        \\      let localSum = 0;
        \\      for (let i = 0; i < per; i++) {{
        \\        let target = {{ id, i, payload: 'waitAsync-finalization-' + id + '-' + i }};
        \\        registry.register(target, base + i);
        \\        localSum += base + i;
        \\        target = null;
        \\      }}
        \\      Atomics.store(view, id, 1);
        \\      const notified = Atomics.notify(view, id);
        \\      if (notified !== 1)
        \\        throw new Error('waitAsync/finalization notify got ' + notified);
        \\      return localSum + id + notified;
        \\    }}, view, id, {d}, registry);
        \\    t.asyncJoin().then(
        \\      (v) => {{ globalThis.__waitAsyncFinAsyncJoinScore += v; }},
        \\      () => {{ globalThis.__waitAsyncFinAsyncJoinScore = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  let joinSum = 0;
        \\  for (const t of threads)
        \\    joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad waitAsync/finalization join sum ' + joinSum);
        \\  threads.length = 0;
        \\  globalThis.__waitAsyncFinCheck = function(expectedWait, expectedJoin) {{
        \\    if (globalThis.__waitAsyncFinWaitScore !== expectedWait)
        \\      throw new Error('bad waitAsync/finalization wait score ' + globalThis.__waitAsyncFinWaitScore);
        \\    if (globalThis.__waitAsyncFinAsyncJoinScore !== expectedJoin)
        \\      throw new Error('bad waitAsync/finalization asyncJoin score ' + globalThis.__waitAsyncFinAsyncJoinScore);
        \\    return 1;
        \\  }};
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{ nthreads, nthreads, seed, wait_timeout_ms, seed, per_thread, expected_join_sum },
    );
    defer gpa.free(src);

    const joined = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: waitAsync/finalization JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: waitAsync/finalization joined got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }

    const check_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__waitAsyncFinCheck({d}, {d})",
        .{ expected_wait_score, expected_join_sum },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: waitAsync/finalization check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != 1) {
        std.debug.print("seed {d}: waitAsync/finalization check got {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1 });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__waitAsyncFinRegistry.cleanupSome();
        \\  if (globalThis.__waitAsyncFinCleanupCount !== {d})
        \\    throw new Error('bad waitAsync/finalization cleanup count ' + globalThis.__waitAsyncFinCleanupCount);
        \\  if (globalThis.__waitAsyncFinCleanupSum !== {d})
        \\    throw new Error('bad waitAsync/finalization cleanup sum ' + globalThis.__waitAsyncFinCleanupSum);
        \\  return globalThis.__waitAsyncFinCleanupCount;
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
        std.debug.print("seed {d}: waitAsync/finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: waitAsync/finalization cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runMicrotaskChurnLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6372_6f74_6173);
    const r = prng.random();
    const nthreads = 3 + r.uintLessThan(usize, 3);
    const per_thread = 8 + r.uintLessThan(usize, 8);

    var expected_join_sum: usize = 0;
    var expected_wait_score: usize = 0;
    var expected_async_hold_score: usize = 0;
    var expected_release_score: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 20_000;
        var i: usize = 0;
        var local_sum: usize = 0;
        while (i < per_thread) : (i += 1) {
            local_sum += base + i;
            expected_cleanup_sum += base + 3_000 + i;
            expected_async_hold_score += base + 1_000 + i;
            expected_release_score += base + 2_000 + i;
        }
        expected_join_sum += local_sum + id + 1;
        expected_wait_score += base + 5_000 + id;
        expected_cleanup_count += per_thread;
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: microtask churn lifecycle context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__microtaskChurnJoinScore = 0;
        \\  globalThis.__microtaskChurnWaitScore = 0;
        \\  globalThis.__microtaskChurnAsyncHoldScore = 0;
        \\  globalThis.__microtaskChurnReleaseScore = 0;
        \\  globalThis.__microtaskChurnCleanupCount = 0;
        \\  globalThis.__microtaskChurnCleanupSum = 0;
        \\  globalThis.__microtaskChurnRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__microtaskChurnCleanupCount++;
        \\    globalThis.__microtaskChurnCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__microtaskChurnRegistry;
        \\  const view = new Int32Array(new SharedArrayBuffer({d} * 4));
        \\  const lock = new Lock();
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const base = (id + 1) * 20000;
        \\    const waitRoot = {{ marker: base + 5000 + id, seed: {d}, label: 'microtask-churn-wait-root' }};
        \\    const waiter = Atomics.waitAsync(view, id, 0, 2000);
        \\    if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\      throw new Error('bad microtask churn waitAsync shape');
        \\    waiter.value.then(
        \\      (v) => {{
        \\        if (v === 'ok' && waitRoot.seed === {d})
        \\          globalThis.__microtaskChurnWaitScore += waitRoot.marker;
        \\        else
        \\          globalThis.__microtaskChurnWaitScore = -1000000;
        \\      }},
        \\      () => {{ globalThis.__microtaskChurnWaitScore = -1000000; }});
        \\    const t = new Thread((view, id, per, registry) => {{
        \\      const base = (id + 1) * 20000;
        \\      let localSum = 0;
        \\      for (let i = 0; i < per; i++) {{
        \\        let target = {{ id, i, payload: 'microtask-churn-cleanup-' + id + '-' + i }};
        \\        registry.register(target, base + 3000 + i);
        \\        target = null;
        \\        localSum += base + i;
        \\      }}
        \\      Atomics.store(view, id, 1);
        \\      const notified = Atomics.notify(view, id);
        \\      if (notified !== 1)
        \\        throw new Error('microtask churn notify got ' + notified);
        \\      return localSum + id + notified;
        \\    }}, view, id, {d}, registry);
        \\    t.asyncJoin().then(
        \\      (v) => {{ globalThis.__microtaskChurnJoinScore += v; }},
        \\      () => {{ globalThis.__microtaskChurnJoinScore = -1000000; }});
        \\    threads.push(t);
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const cbMarker = base + 1000 + i;
        \\      lock.asyncHold(() => cbMarker).then(
        \\        (v) => {{
        \\          if (v === cbMarker)
        \\            globalThis.__microtaskChurnAsyncHoldScore += v;
        \\          else
        \\            globalThis.__microtaskChurnAsyncHoldScore = -1000000;
        \\        }},
        \\        () => {{ globalThis.__microtaskChurnAsyncHoldScore = -1000000; }});
        \\      const releaseMarker = base + 2000 + i;
        \\      lock.asyncHold().then(
        \\        (release) => {{
        \\          if (typeof release !== 'function') {{
        \\            globalThis.__microtaskChurnReleaseScore = -1000000;
        \\          }} else {{
        \\            globalThis.__microtaskChurnReleaseScore += releaseMarker;
        \\            release();
        \\          }}
        \\        }},
        \\        () => {{ globalThis.__microtaskChurnReleaseScore = -1000000; }});
        \\    }}
        \\  }}
        \\  let joinSum = 0;
        \\  for (const t of threads)
        \\    joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad microtask churn join sum ' + joinSum);
        \\  threads.length = 0;
        \\  globalThis.__microtaskChurnCheck = function(expectedJoin, expectedWait, expectedAsyncHold, expectedRelease) {{
        \\    if (globalThis.__microtaskChurnJoinScore !== expectedJoin)
        \\      throw new Error('bad microtask churn asyncJoin score ' + globalThis.__microtaskChurnJoinScore + '/' + expectedJoin);
        \\    if (globalThis.__microtaskChurnWaitScore !== expectedWait)
        \\      throw new Error('bad microtask churn waitAsync score ' + globalThis.__microtaskChurnWaitScore + '/' + expectedWait);
        \\    if (globalThis.__microtaskChurnAsyncHoldScore !== expectedAsyncHold)
        \\      throw new Error('bad microtask churn asyncHold score ' + globalThis.__microtaskChurnAsyncHoldScore + '/' + expectedAsyncHold);
        \\    if (globalThis.__microtaskChurnReleaseScore !== expectedRelease)
        \\      throw new Error('bad microtask churn release score ' + globalThis.__microtaskChurnReleaseScore + '/' + expectedRelease);
        \\    return 1;
        \\  }};
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{
            nthreads,
            nthreads,
            seed,
            seed,
            per_thread,
            per_thread,
            expected_join_sum,
        },
    );
    defer gpa.free(src);

    const joined = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: microtask churn lifecycle JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: microtask churn lifecycle join got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }

    _ = ctx.evaluate("$drainRunLoop()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: microtask churn drain loop threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const check_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__microtaskChurnCheck({d}, {d}, {d}, {d})",
        .{ expected_join_sum, expected_wait_score, expected_async_hold_score, expected_release_score },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: microtask churn check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != 1) {
        std.debug.print("seed {d}: microtask churn check got {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1 });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__microtaskChurnRegistry.cleanupSome();
        \\  if (globalThis.__microtaskChurnCleanupCount !== {d})
        \\    throw new Error('bad microtask churn cleanup count ' + globalThis.__microtaskChurnCleanupCount + '/' + {d});
        \\  if (globalThis.__microtaskChurnCleanupSum !== {d})
        \\    throw new Error('bad microtask churn cleanup sum ' + globalThis.__microtaskChurnCleanupSum + '/' + {d});
        \\  return globalThis.__microtaskChurnCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_count, expected_cleanup_sum, expected_cleanup_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: microtask churn cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: microtask churn cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runCreatorOwnedBufferLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6372_6561_746f_7262);
    const r = prng.random();
    const ncreators = 2 + r.uintLessThan(usize, 3);
    const per_buffer = 12 + r.uintLessThan(usize, 12);
    const read_rounds = 8 + r.uintLessThan(usize, 8);
    const seed_marker = seed % 10_000;

    var payload_sum: usize = 0;
    var id: usize = 0;
    while (id < ncreators) : (id += 1) {
        const base = 510_000 + seed_marker + id * 10_000;
        var i: usize = 0;
        while (i < per_buffer) : (i += 1) payload_sum += base + i;
    }
    const expected_total = payload_sum * (3 + 2 * read_rounds);

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: creator-owned buffer lifecycle context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const bundles = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const creator = new Thread((id, per, seedMarker) => {{
        \\      const base = 510000 + seedMarker + id * 10000;
        \\      const sab = new SharedArrayBuffer(per * 4);
        \\      const ab = new ArrayBuffer(per * 4);
        \\      const movable = new ArrayBuffer(per * 4);
        \\      const sv = new Int32Array(sab);
        \\      const av = new Int32Array(ab);
        \\      const mv = new Int32Array(movable);
        \\      let sum = 0;
        \\      for (let i = 0; i < per; i++) {{
        \\        const v = base + i;
        \\        sv[i] = v;
        \\        av[i] = v;
        \\        mv[i] = v;
        \\        sum += v;
        \\      }}
        \\      return {{ id, sab, ab, movable, sum, base }};
        \\    }}, id, {d}, {d});
        \\    bundles.push(creator.join());
        \\  }}
        \\  let total = 0;
        \\  for (const b of bundles) {{
        \\    const sv = new Int32Array(b.sab);
        \\    const av = new Int32Array(b.ab);
        \\    let local = 0;
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const expected = b.base + i;
        \\      if (sv[i] !== expected)
        \\        throw new Error('creator-owned SAB lost word ' + i + '/' + sv[i] + '/' + expected);
        \\      if (av[i] !== expected)
        \\        throw new Error('creator-owned AB lost word ' + i + '/' + av[i] + '/' + expected);
        \\      local += sv[i] + av[i];
        \\    }}
        \\    if (local !== b.sum * 2)
        \\      throw new Error('bad creator-owned main checksum ' + local + '/' + (b.sum * 2));
        \\    total += local;
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  const readers = [];
        \\  for (const b of bundles) {{
        \\    readers.push(new Thread((bundle, per, rounds) => {{
        \\      const sv = new Int32Array(bundle.sab);
        \\      const av = new Int32Array(bundle.ab);
        \\      let seen = 0;
        \\      for (let round = 0; round < rounds; round++) {{
        \\        for (let i = 0; i < per; i++) {{
        \\          const expected = bundle.base + i;
        \\          const s = sv[i];
        \\          const a = av[i];
        \\          if (s !== expected || a !== expected)
        \\            throw new Error('sibling reader saw creator-owned buffer corruption');
        \\          seen += s + a;
        \\        }}
        \\        let junk = [];
        \\        for (let j = 0; j < 32; j++)
        \\          junk.push({{ round, j, bundle }});
        \\        junk = null;
        \\      }}
        \\      return seen;
        \\    }}, b, {d}, {d}));
        \\  }}
        \\  for (const reader of readers)
        \\    total += reader.join();
        \\  if (typeof gc === 'function') gc();
        \\  for (const b of bundles) {{
        \\    const copy = b.movable.transfer();
        \\    if (b.movable.byteLength !== 0)
        \\      throw new Error('creator-owned movable buffer did not detach');
        \\    const cv = new Int32Array(copy);
        \\    let copySum = 0;
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const expected = b.base + i;
        \\      if (cv[i] !== expected)
        \\        throw new Error('creator-owned transferred copy lost word');
        \\      copySum += cv[i];
        \\    }}
        \\    if (copySum !== b.sum)
        \\      throw new Error('bad creator-owned transferred checksum ' + copySum + '/' + b.sum);
        \\    total += copySum;
        \\  }}
        \\  return total;
        \\}})();
        \\
    ,
        .{
            ncreators,
            per_buffer,
            seed_marker,
            per_buffer,
            per_buffer,
            read_rounds,
            per_buffer,
        },
    );
    defer gpa.free(src);

    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: creator-owned buffer lifecycle JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != @as(f64, @floatFromInt(expected_total))) {
        std.debug.print("seed {d}: creator-owned buffer lifecycle got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected_total });
        return false;
    }
    ctx.collectGarbage();
    return true;
}

fn runWorkerCreatorOwnedBufferLifecycleInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x776f_726b_6372_6561);
    const r = prng.random();
    const ncreators = 2 + r.uintLessThan(usize, 3);
    const nworkers = 1 + r.uintLessThan(usize, 2);
    const per_buffer = 12 + r.uintLessThan(usize, 12);
    const seed_marker = seed % 10_000;

    var payload_sum: usize = 0;
    var expected_by_worker = [_]usize{ 0, 0 };
    var assigned_by_worker = [_]usize{ 0, 0 };
    var id: usize = 0;
    while (id < ncreators) : (id += 1) {
        const base = 540_000 + seed_marker + id * 10_000;
        var local: usize = 0;
        var i: usize = 0;
        while (i < per_buffer) : (i += 1) local += base + i;
        payload_sum += local;
        expected_by_worker[id % nworkers] += local * 3;
        assigned_by_worker[id % nworkers] += 1;
    }
    const expected_main_total = payload_sum * 3;
    const expected_worker_total = payload_sum * 3;
    const expected_transfer_total = payload_sum;

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: worker creator-owned buffer context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__workerCreatorBundles = [];
        \\  const bundles = globalThis.__workerCreatorBundles;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const creator = new Thread((id, per, seedMarker) => {{
        \\      const base = 540000 + seedMarker + id * 10000;
        \\      const sab = new SharedArrayBuffer(per * 4);
        \\      const ab = new ArrayBuffer(per * 4);
        \\      const movable = new ArrayBuffer(per * 4);
        \\      const sv = new Int32Array(sab);
        \\      const av = new Int32Array(ab);
        \\      const mv = new Int32Array(movable);
        \\      let sum = 0;
        \\      for (let i = 0; i < per; i++) {{
        \\        const v = base + i;
        \\        sv[i] = v;
        \\        av[i] = v;
        \\        mv[i] = v;
        \\        sum += v;
        \\      }}
        \\      return {{ id, sab, ab, movable, sum, base }};
        \\    }}, id, {d}, {d});
        \\    bundles.push(creator.join());
        \\  }}
        \\  let total = 0;
        \\  for (const b of bundles) {{
        \\    const sv = new Int32Array(b.sab);
        \\    const av = new Int32Array(b.ab);
        \\    const mv = new Int32Array(b.movable);
        \\    let local = 0;
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const expected = b.base + i;
        \\      if (sv[i] !== expected || av[i] !== expected || mv[i] !== expected)
        \\        throw new Error('worker creator-owned buffer lost word before Worker clone');
        \\      local += sv[i] + av[i] + mv[i];
        \\    }}
        \\    if (local !== b.sum * 3)
        \\      throw new Error('bad worker creator-owned main checksum ' + local + '/' + (b.sum * 3));
        \\    total += local;
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  globalThis.__workerCreatorBufferMsg = function(index) {{
        \\    const b = bundles[index];
        \\    return {{ cmd: 'check', id: b.id, sab: b.sab, ab: b.ab, movable: b.movable, sum: b.sum, base: b.base, per: {d} }};
        \\  }};
        \\  globalThis.__workerCreatorBufferFinish = function() {{
        \\    let transferTotal = 0;
        \\    for (const b of bundles) {{
        \\      const copy = b.movable.transfer();
        \\      if (b.movable.byteLength !== 0)
        \\        throw new Error('worker creator-owned movable buffer did not detach');
        \\      const cv = new Int32Array(copy);
        \\      let copySum = 0;
        \\      for (let i = 0; i < {d}; i++) {{
        \\        const expected = b.base + i;
        \\        if (cv[i] !== expected)
        \\          throw new Error('worker creator-owned transferred copy lost word');
        \\        copySum += cv[i];
        \\      }}
        \\      if (copySum !== b.sum)
        \\        throw new Error('bad worker creator-owned transferred checksum ' + copySum + '/' + b.sum);
        \\      transferTotal += copySum;
        \\    }}
        \\    return transferTotal;
        \\  }};
        \\  return total;
        \\}})();
        \\
    ,
        .{
            ncreators,
            per_buffer,
            seed_marker,
            per_buffer,
            per_buffer,
            per_buffer,
        },
    );
    defer gpa.free(src);

    const main_total = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker creator-owned buffer JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!main_total.isNumber() or main_total.asNum() != @as(f64, @floatFromInt(expected_main_total))) {
        std.debug.print("seed {d}: worker creator-owned main got {d}, expected {d}\n", .{ seed, if (main_total.isNumber()) main_total.asNum() else -1, expected_main_total });
        return false;
    }

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  if (e.data.cmd === 'close') {
        \\    postMessage({ closed: true });
        \\    close();
        \\    return;
        \\  }
        \\  const b = e.data;
        \\  const sv = new Int32Array(b.sab);
        \\  const av = new Int32Array(b.ab);
        \\  const mv = new Int32Array(b.movable);
        \\  let seen = 0;
        \\  for (let i = 0; i < b.per; i++) {
        \\    const expected = b.base + i;
        \\    if (sv[i] !== expected || av[i] !== expected || mv[i] !== expected)
        \\      throw new Error('Worker saw creator-owned buffer corruption');
        \\    seen += sv[i] + av[i] + mv[i];
        \\  }
        \\  if (seen !== b.sum * 3)
        \\    throw new Error('bad Worker creator-owned checksum ' + seen + '/' + (b.sum * 3));
        \\  postMessage({ id: b.id, seen, sabBytes: b.sab.byteLength, abBytes: b.ab.byteLength, movableBytes: b.movable.byteLength });
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
            std.debug.print("seed {d}: worker creator-owned spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
    }

    id = 0;
    while (id < ncreators) : (id += 1) {
        const msg_src = try std.fmt.allocPrint(gpa, "globalThis.__workerCreatorBufferMsg({d})", .{id});
        defer gpa.free(msg_src);
        const msg = ctx.evaluate(msg_src) catch |err| {
            std.debug.print("seed {d}: cannot make worker creator-owned message: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        workers.items[id % nworkers].postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: worker creator-owned post failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }
    const close_msg = ctx.evaluate("({ cmd: 'close' })") catch |err| {
        std.debug.print("seed {d}: cannot make worker creator-owned close message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    for (workers.items) |w| {
        w.postMessage(&machine, close_msg) catch |err| {
            std.debug.print("seed {d}: worker creator-owned close post failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    var worker_total: usize = 0;
    wi = 0;
    while (wi < nworkers) : (wi += 1) {
        var replies: usize = 0;
        var closed = false;
        var local_seen: usize = 0;
        const expected_replies = assigned_by_worker[wi] + 1;
        while (replies < expected_replies) : (replies += 1) {
            const reply = (workers.items[wi].receive(&machine, 10_000) catch |err| {
                std.debug.print("seed {d}: worker creator-owned receive failed: {s}\n", .{ seed, @errorName(err) });
                return false;
            }) orelse {
                std.debug.print("seed {d}: worker creator-owned receive timed out\n", .{seed});
                return false;
            };
            const closed_value = machine.getProperty(reply, "closed") catch js.Value.undef();
            if (closed_value.isBoolean() and closed_value.asBool()) {
                closed = true;
                continue;
            }
            const seen = machine.getProperty(reply, "seen") catch |err| {
                std.debug.print("seed {d}: cannot read worker creator-owned seen: {s}\n", .{ seed, @errorName(err) });
                return false;
            };
            const sab_bytes = machine.getProperty(reply, "sabBytes") catch |err| {
                std.debug.print("seed {d}: cannot read worker creator-owned sab bytes: {s}\n", .{ seed, @errorName(err) });
                return false;
            };
            const ab_bytes = machine.getProperty(reply, "abBytes") catch |err| {
                std.debug.print("seed {d}: cannot read worker creator-owned ab bytes: {s}\n", .{ seed, @errorName(err) });
                return false;
            };
            const movable_bytes = machine.getProperty(reply, "movableBytes") catch |err| {
                std.debug.print("seed {d}: cannot read worker creator-owned movable bytes: {s}\n", .{ seed, @errorName(err) });
                return false;
            };
            if (!seen.isNumber() or !sab_bytes.isNumber() or !ab_bytes.isNumber() or !movable_bytes.isNumber() or
                sab_bytes.asNum() != @as(f64, @floatFromInt(per_buffer * 4)) or
                ab_bytes.asNum() != @as(f64, @floatFromInt(per_buffer * 4)) or
                movable_bytes.asNum() != @as(f64, @floatFromInt(per_buffer * 4)))
            {
                std.debug.print("seed {d}: bad worker creator-owned reply shape\n", .{seed});
                return false;
            }
            local_seen += @intFromFloat(seen.asNum());
        }
        if (!closed or local_seen != expected_by_worker[wi]) {
            std.debug.print("seed {d}: worker creator-owned local seen={d}/{d} closed={}\n", .{ seed, local_seen, expected_by_worker[wi], closed });
            return false;
        }
        worker_total += local_seen;
    }
    if (worker_total != expected_worker_total) {
        std.debug.print("seed {d}: worker creator-owned total got {d}, expected {d}\n", .{ seed, worker_total, expected_worker_total });
        return false;
    }
    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    ctx.collectGarbage();
    const transfer_total = ctx.evaluate("globalThis.__workerCreatorBufferFinish()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: worker creator-owned finish threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!transfer_total.isNumber() or transfer_total.asNum() != @as(f64, @floatFromInt(expected_transfer_total))) {
        std.debug.print("seed {d}: worker creator-owned transfer got {d}, expected {d}\n", .{ seed, if (transfer_total.isNumber()) transfer_total.asNum() else -1, expected_transfer_total });
        return false;
    }
    return true;
}

fn runTerminationPendingReactionInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7465_726d_7265_6163);
    const r = prng.random();
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const seed_marker = seed % 10_000;
    var expected_reject_score: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        expected_reject_score += (id + 1) * 90_000 + seed_marker;
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: termination pending-reaction context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__termPendingRejectScore = 0;
        \\  globalThis.__termPendingRejectCount = 0;
        \\  const sab = new SharedArrayBuffer({d} * 4);
        \\  const view = new Int32Array(sab);
        \\  globalThis.__termPendingView = view;
        \\  const gate = {{ ready: 0, waitSettled: 0 }};
        \\  globalThis.__termPendingGate = gate;
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const joinRoot = {{
        \\      marker: (id + 1) * 90000 + {d},
        \\      nested: {{ seed: {d}, label: 'termination-asyncJoin-reaction-root' }},
        \\    }};
        \\    const t = new Thread((sab, gate, id, seedMarker) => {{
        \\      const view = new Int32Array(sab);
        \\      const waitRoot = {{
        \\        marker: (id + 1) * 70000 + seedMarker,
        \\        nested: {{ label: 'termination-waitAsync-reaction-root' }},
        \\      }};
        \\      const waiter = Atomics.waitAsync(view, id, 0);
        \\      if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\        throw new Error('bad termination waitAsync pending shape');
        \\      waiter.value.then(
        \\        () => {{
        \\          if (waitRoot.marker === (id + 1) * 70000 + seedMarker)
        \\            Atomics.add(gate, 'waitSettled', 1);
        \\          else
        \\            Atomics.store(gate, 'waitSettled', -1000000);
        \\        }},
        \\        () => {{ Atomics.store(gate, 'waitSettled', -1000000); }});
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      for (;;) {{}}
        \\    }}, sab, gate, id, {d});
        \\    t.asyncJoin().then(
        \\      () => {{ globalThis.__termPendingRejectScore = -1000000; }},
        \\      (e) => {{
        \\        if (e && joinRoot.marker === (id + 1) * 90000 + {d} &&
        \\            joinRoot.nested.seed === {d}) {{
        \\          globalThis.__termPendingRejectScore += joinRoot.marker;
        \\          globalThis.__termPendingRejectCount++;
        \\        }} else {{
        \\          globalThis.__termPendingRejectScore = -1000000;
        \\        }}
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  if (typeof gc === 'function') gc();
        \\  throw new Error('threadfuzz termination pending reactions {d}');
        \\}})();
        \\
    ,
        .{ nthreads, nthreads, seed_marker, seed, seed_marker, seed_marker, seed, nthreads, seed },
    );
    defer gpa.free(src);

    if (ctx.evaluate(src)) |_| {
        std.debug.print("seed {d}: termination pending-reaction script returned normally\n", .{seed});
        return false;
    } else |err| {
        if (err != error.Throw) {
            std.debug.print("seed {d}: termination pending-reaction failed with {s}\n", .{ seed, @errorName(err) });
            return false;
        }
    }

    const score = ctx.evaluate("globalThis.__termPendingRejectScore") catch |err| {
        std.debug.print("seed {d}: cannot read termination pending-reaction score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!score.isNumber() or score.asNum() != @as(f64, @floatFromInt(expected_reject_score))) {
        std.debug.print("seed {d}: termination pending-reaction score got {d}, expected {d}\n", .{ seed, if (score.isNumber()) score.asNum() else -1, expected_reject_score });
        return false;
    }
    const count = ctx.evaluate("globalThis.__termPendingRejectCount") catch |err| {
        std.debug.print("seed {d}: cannot read termination pending-reaction count: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!count.isNumber() or count.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: termination pending-reaction count got {d}, expected {d}\n", .{ seed, if (count.isNumber()) count.asNum() else -1, nthreads });
        return false;
    }

    const notify_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  let notified = 0;
        \\  for (let id = 0; id < {d}; id++)
        \\    notified += Atomics.notify(globalThis.__termPendingView, id);
        \\  if (Atomics.load(globalThis.__termPendingGate, 'waitSettled') !== 0)
        \\    throw new Error('termination waitAsync reaction ran unexpectedly');
        \\  return notified;
        \\}})();
        \\
    ,
        .{nthreads},
    );
    defer gpa.free(notify_src);
    const notified = ctx.evaluate(notify_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: termination pending-reaction notify check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!notified.isNumber() or notified.asNum() != 0) {
        std.debug.print("seed {d}: termination pending-reaction leaked {d} waitAsync tickets\n", .{ seed, if (notified.isNumber()) notified.asNum() else -1 });
        return false;
    }
    return true;
}

fn runTerminationWaiterCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7465_726d_7763_6c6e);
    const r = prng.random();
    const nwait = 4 + r.uintLessThan(usize, 5);
    const ncleanup = 10 + r.uintLessThan(usize, 10);
    const seed_marker = seed % 10_000;
    const wait_base = 330_000 + seed_marker;
    const async_cond_marker = 340_000 + seed_marker;
    const reject_marker = 350_000 + seed_marker;
    const cleanup_base = 360_000 + seed_marker;

    var expected_wait_score: usize = 0;
    var wi: usize = 0;
    while (wi < nwait) : (wi += 1) expected_wait_score += wait_base + wi;
    var expected_cleanup_sum: usize = 0;
    var ci: usize = 0;
    while (ci < ncleanup) : (ci += 1) expected_cleanup_sum += cleanup_base + ci;

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: termination waiter/cleanup context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const setup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__termWaitCleanupWaitScore = 0;
        \\  globalThis.__termWaitCleanupWaitCount = 0;
        \\  globalThis.__termWaitCleanupCondScore = 0;
        \\  globalThis.__termWaitCleanupCondCount = 0;
        \\  globalThis.__termWaitCleanupRejectScore = 0;
        \\  globalThis.__termWaitCleanupRejectCount = 0;
        \\  globalThis.__termWaitCleanupCount = 0;
        \\  globalThis.__termWaitCleanupSum = 0;
        \\  globalThis.__termWaitCleanupRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__termWaitCleanupCount++;
        \\    globalThis.__termWaitCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__termWaitCleanupRegistry;
        \\  (() => {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      let target = {{ i, seed: {d}, payload: 'termination-waiter-cleanup-' + i }};
        \\      registry.register(target, {d} + i);
        \\      target = null;
        \\    }}
        \\  }})();
        \\  return {d};
        \\}})();
        \\
    ,
        .{ ncleanup, seed, cleanup_base, ncleanup },
    );
    defer gpa.free(setup_src);
    const setup_result = ctx.evaluate(setup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: termination waiter/cleanup setup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!setup_result.isNumber() or setup_result.asNum() != @as(f64, @floatFromInt(ncleanup))) {
        std.debug.print("seed {d}: termination waiter/cleanup setup got {d}, expected {d}\n", .{ seed, if (setup_result.isNumber()) setup_result.asNum() else -1, ncleanup });
        return false;
    }
    ctx.collectGarbage();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  const gate = {{ spinReady: 0, asyncCondReady: 0, stop: 0 }};
        \\  const waitBox = {{ prop: 0 }};
        \\  const condLock = new Lock();
        \\  const cond = new Condition();
        \\  const asyncCondRoot = {{ marker: {d}, nested: {{ seed: {d}, label: 'termination-async-condition-root' }} }};
        \\  condLock.asyncHold().then((release) => {{
        \\    if (typeof release !== 'function')
        \\      throw new Error('bad termination waiter cleanup initial async hold');
        \\    const ticket = cond.asyncWait(condLock);
        \\    Atomics.store(gate, 'asyncCondReady', 1);
        \\    Atomics.notify(gate, 'asyncCondReady');
        \\    return ticket;
        \\  }}).then((release) => {{
        \\    if (typeof release !== 'function')
        \\      throw new Error('bad termination waiter cleanup async condition reacquire');
        \\    if (asyncCondRoot.marker === {d} && asyncCondRoot.nested.seed === {d}) {{
        \\      globalThis.__termWaitCleanupCondScore += asyncCondRoot.marker;
        \\      globalThis.__termWaitCleanupCondCount++;
        \\    }} else {{
        \\      globalThis.__termWaitCleanupCondScore = -1000000;
        \\    }}
        \\    release();
        \\  }}, () => {{
        \\    globalThis.__termWaitCleanupCondScore = -1000000;
        \\  }});
        \\  for (let i = 0; i < {d}; i++) {{
        \\    const marker = {d} + i;
        \\    const waitRoot = {{ marker, nested: {{ seed: {d}, label: 'termination-property-waitAsync-root-' + i }} }};
        \\    const waiter = Atomics.waitAsync(waitBox, 'prop', 0, 2 + (i % 4));
        \\    if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\      throw new Error('bad termination property waitAsync pending shape');
        \\    waiter.value.then(
        \\      (v) => {{
        \\        if (v === 'timed-out' && waitRoot.marker === marker && waitRoot.nested.seed === {d}) {{
        \\          globalThis.__termWaitCleanupWaitScore += waitRoot.marker;
        \\          globalThis.__termWaitCleanupWaitCount++;
        \\        }} else {{
        \\          globalThis.__termWaitCleanupWaitScore = -1000000;
        \\        }}
        \\      }},
        \\      () => {{ globalThis.__termWaitCleanupWaitScore = -1000000; }});
        \\  }}
        \\  const spinnerRoot = {{ marker: {d}, nested: {{ seed: {d}, label: 'termination-asyncJoin-cleanup-root' }} }};
        \\  const spinner = new Thread((gate) => {{
        \\    Atomics.store(gate, 'spinReady', 1);
        \\    Atomics.notify(gate, 'spinReady');
        \\    while (Atomics.load(gate, 'stop') === 0)
        \\      Atomics.wait(gate, 'stop', 0, 5);
        \\    return -1;
        \\  }}, gate);
        \\  globalThis.__termWaitCleanupSpinner = spinner;
        \\  globalThis.__termWaitCleanupJoinPromise = spinner.asyncJoin();
        \\  globalThis.__termWaitCleanupJoinReaction = globalThis.__termWaitCleanupJoinPromise.then(
        \\    () => {{ globalThis.__termWaitCleanupRejectScore = -1000000; }},
        \\    (e) => {{
        \\      if (e && spinnerRoot.marker === {d} && spinnerRoot.nested.seed === {d}) {{
        \\        globalThis.__termWaitCleanupRejectScore += spinnerRoot.marker;
        \\        globalThis.__termWaitCleanupRejectCount++;
        \\      }} else {{
        \\        globalThis.__termWaitCleanupRejectScore = -1000000;
        \\      }}
        \\    }});
        \\  while (Atomics.load(gate, 'asyncCondReady') === 0)
        \\    Atomics.wait(gate, 'asyncCondReady', 0, 1);
        \\  while (Atomics.load(gate, 'spinReady') === 0)
        \\    Atomics.wait(gate, 'spinReady', 0, 1);
        \\  drainMicrotasks();
        \\  condLock.hold(() => {{
        \\    const notified = cond.notifyAll();
        \\    if (notified !== 1)
        \\      throw new Error('termination waiter cleanup cond notify got ' + notified);
        \\  }});
        \\  throw new Error('threadfuzz termination waiter cleanup {d}');
        \\}})();
        \\
    ,
        .{
            async_cond_marker,
            seed,
            async_cond_marker,
            seed,
            nwait,
            wait_base,
            seed,
            seed,
            reject_marker,
            seed,
            reject_marker,
            seed,
            seed,
        },
    );
    defer gpa.free(src);

    if (ctx.evaluate(src)) |_| {
        std.debug.print("seed {d}: termination waiter/cleanup script returned normally\n", .{seed});
        return false;
    } else |err| {
        if (err != error.Throw) {
            std.debug.print("seed {d}: termination waiter/cleanup failed with {s}\n", .{ seed, @errorName(err) });
            return false;
        }
    }

    _ = ctx.evaluate("$drainRunLoop()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: termination waiter/cleanup drain turn threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const check_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  if (globalThis.__termWaitCleanupWaitScore !== {d})
        \\    throw new Error('bad termination waiter cleanup waitAsync score ' + globalThis.__termWaitCleanupWaitScore);
        \\  if (globalThis.__termWaitCleanupWaitCount !== {d})
        \\    throw new Error('bad termination waiter cleanup waitAsync count ' + globalThis.__termWaitCleanupWaitCount);
        \\  if (globalThis.__termWaitCleanupCondScore !== {d})
        \\    throw new Error('bad termination waiter cleanup condition score ' + globalThis.__termWaitCleanupCondScore);
        \\  if (globalThis.__termWaitCleanupCondCount !== 1)
        \\    throw new Error('bad termination waiter cleanup condition count ' + globalThis.__termWaitCleanupCondCount);
        \\  if (globalThis.__termWaitCleanupRejectScore !== {d})
        \\    throw new Error('bad termination waiter cleanup asyncJoin reject score ' + globalThis.__termWaitCleanupRejectScore);
        \\  if (globalThis.__termWaitCleanupRejectCount !== 1)
        \\    throw new Error('bad termination waiter cleanup asyncJoin reject count ' + globalThis.__termWaitCleanupRejectCount);
        \\  let joinThrew = 0;
        \\  try {{
        \\    globalThis.__termWaitCleanupSpinner.join();
        \\  }} catch (e) {{
        \\    if (e) joinThrew = 1;
        \\  }}
        \\  if (joinThrew !== 1)
        \\    throw new Error('termination waiter cleanup spinner was not terminated');
        \\  globalThis.__termWaitCleanupRegistry.cleanupSome();
        \\  if (globalThis.__termWaitCleanupCount !== {d})
        \\    throw new Error('bad termination waiter cleanup finalization count ' + globalThis.__termWaitCleanupCount + '/' + {d});
        \\  if (globalThis.__termWaitCleanupSum !== {d})
        \\    throw new Error('bad termination waiter cleanup finalization sum ' + globalThis.__termWaitCleanupSum + '/' + {d});
        \\  return globalThis.__termWaitCleanupCount;
        \\}})();
        \\
    ,
        .{
            expected_wait_score,
            nwait,
            async_cond_marker,
            reject_marker,
            ncleanup,
            ncleanup,
            expected_cleanup_sum,
            expected_cleanup_sum,
        },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: termination waiter/cleanup check JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != @as(f64, @floatFromInt(ncleanup))) {
        std.debug.print("seed {d}: termination waiter/cleanup got {d}, expected {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1, ncleanup });
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

fn runThreadLocalFinalizationCleanupInterleaving(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x746c_735f_6669_6e61);
    const r = prng.random();
    const nthreads = 2 + r.uintLessThan(usize, 4);
    const held_base = 50_000 + r.uintLessThan(usize, 10_000);

    var expected_join_sum: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        expected_join_sum += id + 1;
        expected_cleanup_sum += held_base + id;
    }

    const ctx = js.Context.createWith(gpa, .{ .enable_threads = true, .enable_gc = true }) catch {
        std.debug.print("seed {d}: ThreadLocal finalization context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const setup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__tlsFinCleanupCount = 0;
        \\  globalThis.__tlsFinCleanupSum = 0;
        \\  globalThis.__tlsFinRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__tlsFinCleanupCount++;
        \\    globalThis.__tlsFinCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__tlsFinRegistry;
        \\  const tls = new ThreadLocal();
        \\  const gate = globalThis.__tlsFinGate = {{ go: 0, ready: 0 }};
        \\  const threads = globalThis.__tlsFinThreads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    threads.push(new Thread((id) => {{
        \\      let target = {{ id, seed: {d}, payload: 'threadlocal-finalization-' + id }};
        \\      tls.value = target;
        \\      registry.register(target, {d} + id);
        \\      target = null;
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      while (Atomics.load(gate, 'go') === 0)
        \\        Atomics.wait(gate, 'go', 0, 100);
        \\      const held = tls.value;
        \\      if (!held || held.id !== id || held.seed !== {d})
        \\        throw new Error('ThreadLocal finalization root lost for ' + id);
        \\      tls.value = undefined;
        \\      return held.id + 1;
        \\    }}, id));
        \\  }}
        \\  let spins = 0;
        \\  while (Atomics.load(gate, 'ready') < {d}) {{
        \\    if (++spins > 10000000)
        \\      throw new Error('ThreadLocal finalization workers not ready: ' + Atomics.load(gate, 'ready'));
        \\  }}
        \\  globalThis.__tlsFinRegistry.cleanupSome();
        \\  if (globalThis.__tlsFinCleanupCount !== 0)
        \\    throw new Error('ThreadLocal finalization cleanup was queued before resume: ' + globalThis.__tlsFinCleanupCount);
        \\  Atomics.store(gate, 'go', 1);
        \\  Atomics.notify(gate, 'go', {d});
        \\  let joinSum = 0;
        \\  for (const t of threads)
        \\    joinSum += t.join();
        \\  if (joinSum !== {d})
        \\    throw new Error('bad ThreadLocal finalization join sum ' + joinSum);
        \\  globalThis.__tlsFinThreads = null;
        \\  return joinSum;
        \\}})();
        \\
    ,
        .{ nthreads, seed, held_base, seed, nthreads, nthreads, expected_join_sum },
    );
    defer gpa.free(setup_src);

    const joined = ctx.evaluate(setup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: ThreadLocal finalization JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!joined.isNumber() or joined.asNum() != @as(f64, @floatFromInt(expected_join_sum))) {
        std.debug.print("seed {d}: ThreadLocal finalization join got {d}, expected {d}\n", .{ seed, if (joined.isNumber()) joined.asNum() else -1, expected_join_sum });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__tlsFinRegistry.cleanupSome();
        \\  if (globalThis.__tlsFinCleanupCount !== {d})
        \\    throw new Error('bad ThreadLocal finalization cleanup count ' + globalThis.__tlsFinCleanupCount);
        \\  if (globalThis.__tlsFinCleanupSum !== {d})
        \\    throw new Error('bad ThreadLocal finalization cleanup sum ' + globalThis.__tlsFinCleanupSum);
        \\  return globalThis.__tlsFinCleanupCount;
        \\}})();
        \\
    ,
        .{ nthreads, expected_cleanup_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: ThreadLocal finalization cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: ThreadLocal finalization cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, nthreads });
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
    const thread_result_expected = async_base + 8192;
    const thread_throw_expected = async_base + 12288;
    const wait_async_expected = async_base + 16384;
    const async_join_result_expected = async_base + 20480;
    const async_join_throw_expected = async_base + 24576;
    const async_hold_throw_expected = async_base + 28672;
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
        \\  const gate = {{ state: 0, propReady: 0, condReady: 0, holderReady: 0, lockReady: 0, releaseLock: 0, lockDone: 0, asyncDone: 0, asyncSecondDone: 0, asyncRejectDone: 0, asyncCondReady: 0, asyncCondDone: 0, tlsReady: 0, tlsRelease: 0, resultReady: 0, thrownReady: 0, joinResultReady: 0, joinResultRelease: 0, joinThrowReady: 0, joinThrowRelease: 0 }};
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
        \\  globalThis.__midgcAsyncHoldRejectScore = 0;
        \\  let asyncRejectThen = 0;
        \\  let asyncRejectSeen = 0;
        \\  const asyncThrowAllocs = 32 + (asyncRoot.nested.base & 63);
        \\  const asyncRejectGrant = asyncTaskLock.asyncHold(() => {{
        \\    const throwKeep = [];
        \\    for (let a = 0; a < asyncThrowAllocs; a++)
        \\      throwKeep.push({{ a, root: asyncRoot, payload: 'async-grant-throw-' + a }});
        \\    asyncRejectSeen = throwKeep.length;
        \\    throw {{ marker: asyncRoot.nested.base + 28672, nested: {{ root: asyncRoot, label: 'async-grant-throw-midgc-root' }}, count: throwKeep.length }};
        \\  }});
        \\  asyncRejectGrant.then(
        \\    () => {{
        \\      asyncRejectThen = -1;
        \\      globalThis.__midgcAsyncHoldRejectScore = -1;
        \\      Atomics.store(gate, 'asyncRejectDone', 1);
        \\      Atomics.notify(gate, 'asyncRejectDone');
        \\    }},
        \\    (e) => {{
        \\      if (!e || e.marker !== asyncRoot.nested.base + 28672 || e.nested.root.nested.base !== asyncRoot.nested.base ||
        \\          e.count !== asyncThrowAllocs || asyncRejectSeen !== asyncThrowAllocs) {{
        \\        asyncRejectThen = -2;
        \\        globalThis.__midgcAsyncHoldRejectScore = -2;
        \\      }} else {{
        \\        asyncRejectThen = e.marker;
        \\        globalThis.__midgcAsyncHoldRejectScore = e.marker;
        \\      }}
        \\      Atomics.store(gate, 'asyncRejectDone', 1);
        \\      Atomics.notify(gate, 'asyncRejectDone');
        \\    }});
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
        \\  const waitAsyncView = new Int32Array(new SharedArrayBuffer(4));
        \\  globalThis.__midgcWaitAsyncScore = 0;
        \\  (() => {{
        \\    const waitRoot = {{ marker: {d}, nested: {{ root: asyncRoot, label: 'waitAsync-midgc-root' }} }};
        \\    const waiter = Atomics.waitAsync(waitAsyncView, 0, 0);
        \\    if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\      throw new Error('bad midgc waitAsync pending shape');
        \\    waiter.value.then((v) => {{
        \\      if (v !== 'ok' || waitRoot.marker !== {d} || waitRoot.nested.root.nested.base !== {d})
        \\        globalThis.__midgcWaitAsyncScore = -1;
        \\      else
        \\        globalThis.__midgcWaitAsyncScore = waitRoot.marker;
        \\    }}, () => {{
        \\      globalThis.__midgcWaitAsyncScore = -2;
        \\    }});
        \\  }})();
        \\  globalThis.__midgcCleanupCount = 0;
        \\  globalThis.__midgcCleanupSum = 0;
        \\  globalThis.__midgcUnregisterCount = 0;
        \\  globalThis.__midgcUnregisterSum = 0;
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
        \\  const resultThread = new Thread(() => {{
        \\    const result = {{ marker: {d}, nested: {{ root: asyncRoot, label: 'thread-result-midgc-root' }} }};
        \\    Atomics.store(gate, 'resultReady', 1);
        \\    Atomics.notify(gate, 'resultReady');
        \\    return result;
        \\  }});
        \\  const thrownThread = new Thread(() => {{
        \\    const reason = {{ marker: {d}, nested: {{ root: asyncRoot, label: 'thread-throw-midgc-root' }} }};
        \\    Atomics.store(gate, 'thrownReady', 1);
        \\    Atomics.notify(gate, 'thrownReady');
        \\    throw reason;
        \\  }});
        \\  globalThis.__midgcAsyncJoinScore = 0;
        \\  const asyncJoinResultMarker = asyncRoot.nested.base + 20480;
        \\  const asyncJoinThrowMarker = asyncRoot.nested.base + 24576;
        \\  const pendingJoinResultThread = new Thread(() => {{
        \\    const result = {{ marker: asyncJoinResultMarker, nested: {{ root: asyncRoot, label: 'pending-asyncJoin-result-midgc-root' }} }};
        \\    Atomics.store(gate, 'joinResultReady', 1);
        \\    Atomics.notify(gate, 'joinResultReady');
        \\    while (Atomics.load(gate, 'joinResultRelease') === 0)
        \\      Atomics.wait(gate, 'joinResultRelease', 0, 1000);
        \\    return result;
        \\  }});
        \\  (() => {{
        \\    const reactionRoot = {{ marker: asyncJoinResultMarker, nested: {{ root: asyncRoot, label: 'pending-asyncJoin-result-reaction-root' }} }};
        \\    pendingJoinResultThread.asyncJoin().then((v) => {{
        \\      if (!v || v.marker !== asyncJoinResultMarker || v.nested.root.nested.base !== asyncRoot.nested.base ||
        \\          reactionRoot.marker !== asyncJoinResultMarker || reactionRoot.nested.root.nested.base !== asyncRoot.nested.base)
        \\        globalThis.__midgcAsyncJoinScore = -1;
        \\      else
        \\        globalThis.__midgcAsyncJoinScore = reactionRoot.marker;
        \\    }}, () => {{
        \\      globalThis.__midgcAsyncJoinScore = -2;
        \\    }});
        \\  }})();
        \\  globalThis.__midgcAsyncJoinRejectScore = 0;
        \\  const pendingJoinThrowThread = new Thread(() => {{
        \\    const reason = {{ marker: asyncJoinThrowMarker, nested: {{ root: asyncRoot, label: 'pending-asyncJoin-throw-midgc-root' }} }};
        \\    Atomics.store(gate, 'joinThrowReady', 1);
        \\    Atomics.notify(gate, 'joinThrowReady');
        \\    while (Atomics.load(gate, 'joinThrowRelease') === 0)
        \\      Atomics.wait(gate, 'joinThrowRelease', 0, 1000);
        \\    throw reason;
        \\  }});
        \\  (() => {{
        \\    const reactionRoot = {{ marker: asyncJoinThrowMarker, nested: {{ root: asyncRoot, label: 'pending-asyncJoin-throw-reaction-root' }} }};
        \\    pendingJoinThrowThread.asyncJoin().then(() => {{
        \\      globalThis.__midgcAsyncJoinRejectScore = -1;
        \\    }}, (e) => {{
        \\      if (!e || e.marker !== asyncJoinThrowMarker || e.nested.root.nested.base !== asyncRoot.nested.base ||
        \\          reactionRoot.marker !== asyncJoinThrowMarker || reactionRoot.nested.root.nested.base !== asyncRoot.nested.base)
        \\        globalThis.__midgcAsyncJoinRejectScore = -2;
        \\      else
        \\        globalThis.__midgcAsyncJoinRejectScore = reactionRoot.marker;
        \\    }});
        \\  }})();
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
        \\  while (Atomics.load(gate, 'resultReady') === 0)
        \\    Atomics.wait(gate, 'resultReady', 0, 1);
        \\  while (Atomics.load(gate, 'thrownReady') === 0)
        \\    Atomics.wait(gate, 'thrownReady', 0, 1);
        \\  while (Atomics.load(gate, 'joinResultReady') === 0)
        \\    Atomics.wait(gate, 'joinResultReady', 0, 1);
        \\  while (Atomics.load(gate, 'joinThrowReady') === 0)
        \\    Atomics.wait(gate, 'joinThrowReady', 0, 1);
        \\  while (Atomics.load(gate, 'asyncCondReady') === 0)
        \\    Atomics.wait(gate, 'asyncCondReady', 0, 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const cell = {{ round, i, nested: {{ v: i + round }}, text: 'midgc-' + round + '-' + i }};
        \\      keep.push(cell);
        \\      if (globalThis.__midgcRegistry && ((i + round) & 31) === 0)
        \\        globalThis.__midgcRegistry.register({{ ephemeral: i, round }}, round * {d} + i + 1);
        \\      if (globalThis.__midgcRegistry && ((i + round) & 63) === 7) {{
        \\        const token = {{ token: 'midgc-unregister', round, i }};
        \\        globalThis.__midgcRegistry.register({{ ephemeral: 'unregistered', i, round }}, 1000000 + round * {d} + i + 1, token);
        \\        if (!globalThis.__midgcRegistry.unregister(token))
        \\          throw new Error('midgc unregister token was not found');
        \\        globalThis.__midgcUnregisterCount = globalThis.__midgcUnregisterCount + 1;
        \\        globalThis.__midgcUnregisterSum = globalThis.__midgcUnregisterSum + round * {d} + i + 1;
        \\      }}
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
        \\  let asyncRejectSpins = 0;
        \\  while (Atomics.load(gate, 'asyncRejectDone') === 0 && asyncRejectSpins++ < 10000000) ;
        \\  if (Atomics.load(gate, 'asyncRejectDone') !== 1)
        \\    throw new Error('rejected asyncHold grant was not pumped during mid-script GC pressure');
        \\  if (asyncRejectThen !== asyncRoot.nested.base + 28672)
        \\    throw new Error('bad rejected asyncHold midgc score: ' + asyncRejectThen);
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
        \\  Atomics.store(waitAsyncView, 0, 1);
        \\  if (Atomics.notify(waitAsyncView, 0) !== 1)
        \\    throw new Error('midgc waitAsync waiter was not queued');
        \\  Atomics.store(gate, 'releaseLock', 1);
        \\  Atomics.notify(gate, 'releaseLock');
        \\  Atomics.store(gate, 'tlsRelease', 1);
        \\  Atomics.notify(gate, 'tlsRelease');
        \\  Atomics.store(gate, 'joinResultRelease', 1);
        \\  Atomics.notify(gate, 'joinResultRelease');
        \\  Atomics.store(gate, 'joinThrowRelease', 1);
        \\  Atomics.notify(gate, 'joinThrowRelease');
        \\  const wr = propWaiter.join();
        \\  if (wr !== 'ok' && wr !== 'timed-out') throw new Error('bad property wait result: ' + wr);
        \\  if (condWaiter.join() !== 1) throw new Error('bad condition waiter');
        \\  if (holder.join() !== 1) throw new Error('bad lock holder');
        \\  const lockJoin = lockWaiter.join();
        \\  if (lockJoin !== 1 || Atomics.load(gate, 'lockDone') !== 1) throw new Error('bad lock waiter');
        \\  globalThis.__midgcTlsHold = tlsWaiter.join();
        \\  if (!globalThis.__midgcTlsHold || globalThis.__midgcTlsHold.marker !== {d})
        \\    throw new Error('bad ThreadLocal midgc return');
        \\  globalThis.__midgcThreadResultHold = resultThread.join();
        \\  if (!globalThis.__midgcThreadResultHold ||
        \\      globalThis.__midgcThreadResultHold.marker !== {d} ||
        \\      globalThis.__midgcThreadResultHold.nested.root.nested.base !== {d})
        \\    throw new Error('bad completed Thread result midgc root');
        \\  globalThis.__midgcAsyncJoinResultHold = pendingJoinResultThread.join();
        \\  if (!globalThis.__midgcAsyncJoinResultHold ||
        \\      globalThis.__midgcAsyncJoinResultHold.marker !== asyncJoinResultMarker ||
        \\      globalThis.__midgcAsyncJoinResultHold.nested.root.nested.base !== asyncRoot.nested.base)
        \\    throw new Error('bad pending asyncJoin result midgc root');
        \\  try {{
        \\    pendingJoinThrowThread.join();
        \\  }} catch (e) {{
        \\    if (e.marker !== asyncJoinThrowMarker || e.nested.root.nested.base !== asyncRoot.nested.base)
        \\      throw new Error('bad pending asyncJoin thrown midgc root');
        \\    globalThis.__midgcAsyncJoinThrowHold = e;
        \\  }}
        \\  try {{
        \\    thrownThread.join();
        \\  }} catch (e) {{
        \\    if (e.marker !== {d} || e.nested.root.nested.base !== {d})
        \\      throw new Error('bad thrown Thread completion midgc root');
        \\    globalThis.__midgcThreadThrowHold = e;
        \\    return keep.length;
        \\  }}
        \\  throw new Error('thrown Thread completed normally');
        \\}})();
        \\
    ,
        .{
            async_base,
            async_allocs,
            async_second_allocs,
            async_cond_allocs,
            wait_async_expected,
            wait_async_expected,
            async_base,
            tls_expected,
            tls_expected + 111,
            wait_timeout_ms,
            tls_expected,
            thread_result_expected,
            thread_throw_expected,
            wait_timeout_ms,
            wait_timeout_ms,
            rounds,
            per_round,
            per_round,
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
            thread_result_expected,
            async_base,
            thread_throw_expected,
            async_base,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const expected: f64 = @floatFromInt(rounds * per_round);
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var expected_unregister_count: usize = 0;
    var expected_unregister_sum: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var i: usize = 0;
        while (i < per_round) : (i += 1) {
            if (((i + round) & 31) == 0) {
                expected_cleanup_count += 1;
                expected_cleanup_sum += round * per_round + i + 1;
            }
            if (((i + round) & 63) == 7) {
                expected_unregister_count += 1;
                expected_unregister_sum += round * per_round + i + 1;
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
    const wait_async_score = ctx.evaluate("globalThis.__midgcWaitAsyncScore") catch |err| {
        std.debug.print("seed {d}: cannot read midgc waitAsync score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!wait_async_score.isNumber() or wait_async_score.asNum() != @as(f64, @floatFromInt(wait_async_expected))) {
        std.debug.print("seed {d}: midgc waitAsync score got {d}, expected {d}\n", .{ seed, if (wait_async_score.isNumber()) wait_async_score.asNum() else -1, wait_async_expected });
        return false;
    }
    const async_join_score = ctx.evaluate("globalThis.__midgcAsyncJoinScore") catch |err| {
        std.debug.print("seed {d}: cannot read midgc asyncJoin score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!async_join_score.isNumber() or async_join_score.asNum() != @as(f64, @floatFromInt(async_join_result_expected))) {
        std.debug.print("seed {d}: midgc asyncJoin score got {d}, expected {d}\n", .{ seed, if (async_join_score.isNumber()) async_join_score.asNum() else -1, async_join_result_expected });
        return false;
    }
    const async_join_reject_score = ctx.evaluate("globalThis.__midgcAsyncJoinRejectScore") catch |err| {
        std.debug.print("seed {d}: cannot read midgc asyncJoin reject score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!async_join_reject_score.isNumber() or async_join_reject_score.asNum() != @as(f64, @floatFromInt(async_join_throw_expected))) {
        std.debug.print("seed {d}: midgc asyncJoin reject score got {d}, expected {d}\n", .{ seed, if (async_join_reject_score.isNumber()) async_join_reject_score.asNum() else -1, async_join_throw_expected });
        return false;
    }
    const async_hold_reject_score = ctx.evaluate("globalThis.__midgcAsyncHoldRejectScore") catch |err| {
        std.debug.print("seed {d}: cannot read midgc asyncHold reject score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!async_hold_reject_score.isNumber() or async_hold_reject_score.asNum() != @as(f64, @floatFromInt(async_hold_throw_expected))) {
        std.debug.print("seed {d}: midgc asyncHold reject score got {d}, expected {d}\n", .{ seed, if (async_hold_reject_score.isNumber()) async_hold_reject_score.asNum() else -1, async_hold_throw_expected });
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
        \\  if (globalThis.__midgcUnregisterCount !== {d})
        \\    throw new Error('midgc unregister count ' + globalThis.__midgcUnregisterCount);
        \\  if (globalThis.__midgcUnregisterSum !== {d})
        \\    throw new Error('midgc unregister sum ' + globalThis.__midgcUnregisterSum);
        \\  return globalThis.__midgcCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_sum, expected_unregister_count, expected_unregister_sum },
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

fn runMidScriptSyncWaitCleanupGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6473_796e_6377);
    const r = prng.random();
    const rounds = 8 + r.uintLessThan(usize, 6);
    const per_round = 700 + r.uintLessThan(usize, 350);
    const spin_iters = 2500 + r.uintLessThan(usize, 4000);
    const wait_timeout_ms = 1100 + r.uintLessThan(usize, 700);
    const seed_marker = seed % 10_000;
    const prop_marker = 310_000 + seed_marker;
    const cond_marker = 320_000 + seed_marker;
    const lock_marker = 330_000 + seed_marker;
    const cleanup_base = 340_000 + seed_marker;

    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var round_i: usize = 0;
    while (round_i < rounds) : (round_i += 1) {
        var i: usize = 0;
        while (i < per_round) : (i += 1) {
            if (((i + round_i) & 15) == 3) {
                expected_cleanup_count += 1;
                expected_cleanup_sum += cleanup_base + round_i * per_round + i;
            }
        }
    }

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc sync-wait cleanup context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcSyncCleanupCount = 0;
        \\  globalThis.__midgcSyncCleanupSum = 0;
        \\  globalThis.__midgcSyncRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__midgcSyncCleanupCount++;
        \\    globalThis.__midgcSyncCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__midgcSyncRegistry;
        \\  const gate = {{ prop: 0, propReady: 0, condReady: 0, condOpen: false, lockHeld: 0, lockReady: 0, lockRelease: 0, lockDone: 0 }};
        \\  const condLock = new Lock();
        \\  const cond = new Condition();
        \\  const heldLock = new Lock();
        \\  const root = {{ seed: {d}, tag: 'midgc-sync-wait-cleanup-root' }};
        \\  const propThread = new Thread((gate, marker, seedMarker, timeout) => {{
        \\    const localRoot = {{ marker, nested: {{ seed: seedMarker, label: 'midgc-property-sync-wait-root' }} }};
        \\    Atomics.store(gate, 'propReady', 1);
        \\    Atomics.notify(gate, 'propReady');
        \\    const r = Atomics.wait(gate, 'prop', 0, timeout);
        \\    if (r !== 'ok' && r !== 'not-equal' && r !== 'timed-out')
        \\      throw new Error('bad midgc property wait result ' + r);
        \\    return localRoot;
        \\  }}, gate, {d}, {d}, {d});
        \\  const condThread = new Thread((gate, marker, seedMarker) => {{
        \\    const localRoot = {{ marker, nested: {{ seed: seedMarker, label: 'midgc-condition-sync-wait-root' }} }};
        \\    condLock.hold(() => {{
        \\      Atomics.store(gate, 'condReady', 1);
        \\      Atomics.notify(gate, 'condReady');
        \\      while (!gate.condOpen)
        \\        cond.wait(condLock);
        \\    }});
        \\    return localRoot;
        \\  }}, gate, {d}, {d});
        \\  const holder = new Thread((gate) => {{
        \\    heldLock.hold(() => {{
        \\      Atomics.store(gate, 'lockHeld', 1);
        \\      Atomics.notify(gate, 'lockHeld');
        \\      while (Atomics.load(gate, 'lockRelease') === 0)
        \\        Atomics.wait(gate, 'lockRelease', 0, {d});
        \\    }});
        \\    return 1;
        \\  }}, gate);
        \\  while (Atomics.load(gate, 'lockHeld') === 0)
        \\    Atomics.wait(gate, 'lockHeld', 0, 1);
        \\  const lockThread = new Thread((gate, marker, seedMarker) => {{
        \\    const localRoot = {{ marker, nested: {{ seed: seedMarker, label: 'midgc-contended-lock-wait-root' }} }};
        \\    Atomics.store(gate, 'lockReady', 1);
        \\    Atomics.notify(gate, 'lockReady');
        \\    heldLock.hold(() => {{
        \\      Atomics.store(gate, 'lockDone', 1);
        \\    }});
        \\    return localRoot;
        \\  }}, gate, {d}, {d});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\  while (Atomics.load(gate, 'lockReady') === 0)
        \\    Atomics.wait(gate, 'lockReady', 0, 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      keep.push({{
        \\        round,
        \\        i,
        \\        nested: {{ root, value: i + round }},
        \\        text: 'midgc-sync-wait-cleanup-' + round + '-' + i,
        \\      }});
        \\      if (((i + round) & 15) === 3)
        \\        registry.register({{ ephemeral: i, round, root }}, {d} + round * {d} + i);
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ impossible: true }});
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  Atomics.store(gate, 'prop', 1);
        \\  Atomics.notify(gate, 'prop');
        \\  condLock.hold(() => {{
        \\    gate.condOpen = true;
        \\    cond.notifyAll();
        \\  }});
        \\  Atomics.store(gate, 'lockRelease', 1);
        \\  Atomics.notify(gate, 'lockRelease');
        \\  const propRoot = propThread.join();
        \\  const condRoot = condThread.join();
        \\  if (holder.join() !== 1)
        \\    throw new Error('bad midgc sync-wait lock holder');
        \\  const lockRoot = lockThread.join();
        \\  if (!propRoot || propRoot.marker !== {d} || propRoot.nested.seed !== {d})
        \\    throw new Error('bad midgc property sync-wait root');
        \\  if (!condRoot || condRoot.marker !== {d} || condRoot.nested.seed !== {d})
        \\    throw new Error('bad midgc condition sync-wait root');
        \\  if (!lockRoot || lockRoot.marker !== {d} || lockRoot.nested.seed !== {d} ||
        \\      Atomics.load(gate, 'lockDone') !== 1)
        \\    throw new Error('bad midgc contended-lock sync-wait root');
        \\  return keep.length;
        \\}})();
        \\
    ,
        .{
            seed_marker,
            prop_marker,
            seed_marker,
            wait_timeout_ms,
            cond_marker,
            seed_marker,
            wait_timeout_ms,
            lock_marker,
            seed_marker,
            rounds,
            per_round,
            cleanup_base,
            per_round,
            spin_iters,
            prop_marker,
            seed_marker,
            cond_marker,
            seed_marker,
            lock_marker,
            seed_marker,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const expected: f64 = @floatFromInt(rounds * per_round);
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc sync-wait cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != expected) {
        std.debug.print("seed {d}: midgc sync-wait cleanup result got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc sync-wait cleanup did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc sync-wait cleanup did not finish a parallel collection\n", .{seed});
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcSyncRegistry.cleanupSome();
        \\  if (globalThis.__midgcSyncCleanupCount !== {d})
        \\    throw new Error('midgc sync-wait cleanup count ' + globalThis.__midgcSyncCleanupCount + '/' + {d});
        \\  if (globalThis.__midgcSyncCleanupSum !== {d})
        \\    throw new Error('midgc sync-wait cleanup sum ' + globalThis.__midgcSyncCleanupSum + '/' + {d});
        \\  return globalThis.__midgcSyncCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_count, expected_cleanup_sum, expected_cleanup_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc sync-wait cleanup check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: midgc sync-wait cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runMidScriptWeakCollectionGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6477_6561_6b63);
    const r = prng.random();
    const rounds = 7 + r.uintLessThan(usize, 5);
    const per_round = 480 + r.uintLessThan(usize, 320);
    const spin_iters = 2200 + r.uintLessThan(usize, 3600);
    const wait_timeout_ms = 1100 + r.uintLessThan(usize, 700);
    const seed_marker = seed % 10_000;
    const prop_marker = 350_000 + seed_marker;
    const cond_marker = 360_000 + seed_marker;
    const lock_marker = 370_000 + seed_marker;
    const live_base = 380_000 + seed_marker;
    const dead_map_base = 390_000 + seed_marker;
    const dead_set_base = 400_000 + seed_marker;
    const direct_cleanup_base = 410_000 + seed_marker;
    const unregister_base = 420_000 + seed_marker;

    var expected_live_count: usize = 0;
    var expected_live_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var expected_unregister_count: usize = 0;
    var expected_unregister_sum: usize = 0;
    var round_i: usize = 0;
    while (round_i < rounds) : (round_i += 1) {
        var i: usize = 0;
        while (i < per_round) : (i += 1) {
            const idx = round_i * per_round + i;
            if (((i + round_i) & 7) == 0) {
                expected_live_count += 1;
                expected_live_sum += live_base + idx;
            } else {
                expected_cleanup_count += 2;
                expected_cleanup_sum += dead_map_base + idx;
                expected_cleanup_sum += dead_set_base + idx;
            }
            if (((i + round_i) & 15) == 3) {
                expected_cleanup_count += 1;
                expected_cleanup_sum += direct_cleanup_base + idx;
            }
            if (((i + round_i) & 31) == 5) {
                expected_unregister_count += 1;
                expected_unregister_sum += unregister_base + idx;
            }
        }
    }

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc weak collection context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcWeakCleanupCount = 0;
        \\  globalThis.__midgcWeakCleanupSum = 0;
        \\  globalThis.__midgcWeakUnregisterCount = 0;
        \\  globalThis.__midgcWeakUnregisterSum = 0;
        \\  globalThis.__midgcWeakDeadRefs = [];
        \\  globalThis.__midgcWeakLiveRefs = [];
        \\  globalThis.__midgcWeakKeys = [];
        \\  const registry = new FinalizationRegistry((held) => {{
        \\    globalThis.__midgcWeakCleanupCount++;
        \\    globalThis.__midgcWeakCleanupSum += held;
        \\  }});
        \\  globalThis.__midgcWeakRegistry = registry;
        \\  const wm = new WeakMap();
        \\  const ws = new WeakSet();
        \\  globalThis.__midgcWeakMap = wm;
        \\  globalThis.__midgcWeakSet = ws;
        \\  const gate = {{ prop: 0, propReady: 0, condReady: 0, condOpen: false, lockHeld: 0, lockReady: 0, lockRelease: 0, lockDone: 0 }};
        \\  const condLock = new Lock();
        \\  const cond = new Condition();
        \\  const heldLock = new Lock();
        \\  const root = {{ seed: {d}, tag: 'midgc-weak-collection-root' }};
        \\  const propThread = new Thread((gate, marker, seedMarker, timeout) => {{
        \\    const localRoot = {{ marker, nested: {{ seed: seedMarker, label: 'midgc-weak-property-root' }} }};
        \\    Atomics.store(gate, 'propReady', 1);
        \\    Atomics.notify(gate, 'propReady');
        \\    const r = Atomics.wait(gate, 'prop', 0, timeout);
        \\    if (r !== 'ok' && r !== 'not-equal' && r !== 'timed-out')
        \\      throw new Error('bad midgc weak property wait result ' + r);
        \\    return localRoot;
        \\  }}, gate, {d}, {d}, {d});
        \\  const condThread = new Thread((gate, marker, seedMarker) => {{
        \\    const localRoot = {{ marker, nested: {{ seed: seedMarker, label: 'midgc-weak-condition-root' }} }};
        \\    condLock.hold(() => {{
        \\      Atomics.store(gate, 'condReady', 1);
        \\      Atomics.notify(gate, 'condReady');
        \\      while (!gate.condOpen)
        \\        cond.wait(condLock);
        \\    }});
        \\    return localRoot;
        \\  }}, gate, {d}, {d});
        \\  const holder = new Thread((gate) => {{
        \\    heldLock.hold(() => {{
        \\      Atomics.store(gate, 'lockHeld', 1);
        \\      Atomics.notify(gate, 'lockHeld');
        \\      while (Atomics.load(gate, 'lockRelease') === 0)
        \\        Atomics.wait(gate, 'lockRelease', 0, {d});
        \\    }});
        \\    return 1;
        \\  }}, gate);
        \\  while (Atomics.load(gate, 'lockHeld') === 0)
        \\    Atomics.wait(gate, 'lockHeld', 0, 1);
        \\  const lockThread = new Thread((gate, marker, seedMarker) => {{
        \\    const localRoot = {{ marker, nested: {{ seed: seedMarker, label: 'midgc-weak-lock-root' }} }};
        \\    Atomics.store(gate, 'lockReady', 1);
        \\    Atomics.notify(gate, 'lockReady');
        \\    heldLock.hold(() => {{
        \\      Atomics.store(gate, 'lockDone', 1);
        \\    }});
        \\    return localRoot;
        \\  }}, gate, {d}, {d});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\  while (Atomics.load(gate, 'lockReady') === 0)
        \\    Atomics.wait(gate, 'lockReady', 0, 1);
        \\  const keep = [];
        \\  let liveSum = 0;
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const idx = round * {d} + i;
        \\      keep.push({{ round, i, nested: {{ root, value: i + round }}, text: 'midgc-weak-' + round + '-' + i }});
        \\      if (((i + round) & 7) === 0) {{
        \\        const key = {{ kind: 'live-key', idx, root }};
        \\        const value = {{ marker: {d} + idx, nested: {{ root, label: 'live-weakmap-value' }} }};
        \\        wm.set(key, value);
        \\        ws.add(key);
        \\        globalThis.__midgcWeakKeys.push(key);
        \\        globalThis.__midgcWeakLiveRefs.push(new WeakRef(value));
        \\        liveSum += value.marker;
        \\      }} else {{
        \\        const deadMapKey = {{ kind: 'dead-map-key', idx, root }};
        \\        const deadMapValue = {{ marker: {d} + idx, nested: {{ root, label: 'dead-weakmap-value' }} }};
        \\        wm.set(deadMapKey, deadMapValue);
        \\        registry.register(deadMapValue, deadMapValue.marker);
        \\        globalThis.__midgcWeakDeadRefs.push(new WeakRef(deadMapValue));
        \\        const deadSetValue = {{ marker: {d} + idx, nested: {{ root, label: 'dead-weakset-value' }} }};
        \\        ws.add(deadSetValue);
        \\        registry.register(deadSetValue, deadSetValue.marker);
        \\        globalThis.__midgcWeakDeadRefs.push(new WeakRef(deadSetValue));
        \\      }}
        \\      if (((i + round) & 15) === 3)
        \\        registry.register({{ kind: 'direct-cleanup', idx, root }}, {d} + idx);
        \\      if (((i + round) & 31) === 5) {{
        \\        const token = {{ kind: 'unregister-token', idx, root }};
        \\        registry.register({{ kind: 'unregistered-target', idx, root }}, {d} + idx, token);
        \\        if (!registry.unregister(token))
        \\          throw new Error('midgc weak unregister token was not found ' + idx);
        \\        globalThis.__midgcWeakUnregisterCount++;
        \\        globalThis.__midgcWeakUnregisterSum += {d} + idx;
        \\      }}
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ impossible: true }});
        \\  }}
        \\  if (liveSum !== {d})
        \\    throw new Error('bad midgc weak live construction sum ' + liveSum + '/' + {d});
        \\  if (typeof gc === 'function') gc();
        \\  Atomics.store(gate, 'prop', 1);
        \\  Atomics.notify(gate, 'prop');
        \\  condLock.hold(() => {{
        \\    gate.condOpen = true;
        \\    cond.notifyAll();
        \\  }});
        \\  Atomics.store(gate, 'lockRelease', 1);
        \\  Atomics.notify(gate, 'lockRelease');
        \\  const propRoot = propThread.join();
        \\  const condRoot = condThread.join();
        \\  if (holder.join() !== 1)
        \\    throw new Error('bad midgc weak lock holder');
        \\  const lockRoot = lockThread.join();
        \\  if (!propRoot || propRoot.marker !== {d} || propRoot.nested.seed !== {d})
        \\    throw new Error('bad midgc weak property root');
        \\  if (!condRoot || condRoot.marker !== {d} || condRoot.nested.seed !== {d})
        \\    throw new Error('bad midgc weak condition root');
        \\  if (!lockRoot || lockRoot.marker !== {d} || lockRoot.nested.seed !== {d} ||
        \\      Atomics.load(gate, 'lockDone') !== 1)
        \\    throw new Error('bad midgc weak contended-lock root');
        \\  let postSweepLiveSum = 0;
        \\  for (let k = 0; k < globalThis.__midgcWeakKeys.length; k++) {{
        \\    const key = globalThis.__midgcWeakKeys[k];
        \\    if (!ws.has(key))
        \\      throw new Error('live WeakSet key missing ' + k);
        \\    const value = wm.get(key);
        \\    const refValue = globalThis.__midgcWeakLiveRefs[k].deref();
        \\    if (!value || !refValue || value !== refValue || value.marker !== refValue.marker)
        \\      throw new Error('live WeakMap value missing ' + k);
        \\    postSweepLiveSum += value.marker;
        \\  }}
        \\  if (postSweepLiveSum !== {d})
        \\    throw new Error('bad midgc weak live post-sweep sum ' + postSweepLiveSum + '/' + {d});
        \\  return globalThis.__midgcWeakKeys.length;
        \\}})();
        \\
    ,
        .{
            seed_marker,
            prop_marker,
            seed_marker,
            wait_timeout_ms,
            cond_marker,
            seed_marker,
            wait_timeout_ms,
            lock_marker,
            seed_marker,
            rounds,
            per_round,
            per_round,
            live_base,
            dead_map_base,
            dead_set_base,
            direct_cleanup_base,
            unregister_base,
            unregister_base,
            spin_iters,
            expected_live_sum,
            expected_live_sum,
            prop_marker,
            seed_marker,
            cond_marker,
            seed_marker,
            lock_marker,
            seed_marker,
            expected_live_sum,
            expected_live_sum,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc weak collection JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != @as(f64, @floatFromInt(expected_live_count))) {
        std.debug.print("seed {d}: midgc weak collection live count got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected_live_count });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc weak collection did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc weak collection did not finish a parallel collection\n", .{seed});
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcWeakRegistry.cleanupSome();
        \\  let liveSum = 0;
        \\  for (let k = 0; k < globalThis.__midgcWeakKeys.length; k++) {{
        \\    const key = globalThis.__midgcWeakKeys[k];
        \\    const value = globalThis.__midgcWeakMap.get(key);
        \\    const refValue = globalThis.__midgcWeakLiveRefs[k].deref();
        \\    if (!globalThis.__midgcWeakSet.has(key) || !value || !refValue || value !== refValue)
        \\      throw new Error('midgc weak live value missing after quiescent GC ' + k);
        \\    liveSum += value.marker;
        \\  }}
        \\  let cleared = 0;
        \\  for (let k = 0; k < globalThis.__midgcWeakDeadRefs.length; k++) {{
        \\    if (globalThis.__midgcWeakDeadRefs[k].deref() === undefined)
        \\      cleared++;
        \\  }}
        \\  if (liveSum !== {d})
        \\    throw new Error('midgc weak live sum after cleanup ' + liveSum + '/' + {d});
        \\  if (cleared !== globalThis.__midgcWeakDeadRefs.length)
        \\    throw new Error('midgc weak dead refs cleared ' + cleared + '/' + globalThis.__midgcWeakDeadRefs.length);
        \\  if (globalThis.__midgcWeakCleanupCount !== {d})
        \\    throw new Error('midgc weak cleanup count ' + globalThis.__midgcWeakCleanupCount + '/' + {d});
        \\  if (globalThis.__midgcWeakCleanupSum !== {d})
        \\    throw new Error('midgc weak cleanup sum ' + globalThis.__midgcWeakCleanupSum + '/' + {d});
        \\  if (globalThis.__midgcWeakUnregisterCount !== {d})
        \\    throw new Error('midgc weak unregister count ' + globalThis.__midgcWeakUnregisterCount + '/' + {d});
        \\  if (globalThis.__midgcWeakUnregisterSum !== {d})
        \\    throw new Error('midgc weak unregister sum ' + globalThis.__midgcWeakUnregisterSum + '/' + {d});
        \\  return cleared;
        \\}})();
        \\
    ,
        .{
            expected_live_sum,
            expected_live_sum,
            expected_cleanup_count,
            expected_cleanup_count,
            expected_cleanup_sum,
            expected_cleanup_sum,
            expected_unregister_count,
            expected_unregister_count,
            expected_unregister_sum,
            expected_unregister_sum,
        },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc weak collection cleanup check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const expected_dead_refs = (rounds * per_round - expected_live_count) * 2;
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_dead_refs))) {
        std.debug.print("seed {d}: midgc weak collection cleared got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_dead_refs });
        return false;
    }
    return true;
}

fn runMidScriptTerminationReactionGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6474_6572_6d72);
    const r = prng.random();
    const nthreads = 2 + r.uintLessThan(usize, 3);
    const rounds = 10 + r.uintLessThan(usize, 6);
    const per_round = 900 + r.uintLessThan(usize, 500);
    const seed_marker = seed % 10_000;

    var expected_reject_score: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        expected_reject_score += (id + 1) * 110_000 + seed_marker;
    }

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc termination-reaction context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcTermRejectScore = 0;
        \\  globalThis.__midgcTermRejectCount = 0;
        \\  const sab = new SharedArrayBuffer({d} * 4);
        \\  const view = new Int32Array(sab);
        \\  globalThis.__midgcTermView = view;
        \\  const gate = {{ ready: 0, waitSettled: 0, park: 0 }};
        \\  globalThis.__midgcTermGate = gate;
        \\  const threads = [];
        \\  const root = {{ seed: {d}, tag: 'midgc-termination-root' }};
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const joinRoot = {{
        \\      marker: (id + 1) * 110000 + {d},
        \\      nested: {{ root, label: 'midgc-termination-asyncJoin-root' }},
        \\    }};
        \\    const t = new Thread((sab, gate, id, seedMarker) => {{
        \\      const view = new Int32Array(sab);
        \\      const waitRoot = {{
        \\        marker: (id + 1) * 130000 + seedMarker,
        \\        nested: {{ label: 'midgc-termination-waitAsync-root' }},
        \\      }};
        \\      const waiter = Atomics.waitAsync(view, id, 0);
        \\      if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\        throw new Error('bad midgc termination waitAsync pending shape');
        \\      waiter.value.then(
        \\        () => {{
        \\          if (waitRoot.marker === (id + 1) * 130000 + seedMarker)
        \\            Atomics.add(gate, 'waitSettled', 1);
        \\          else
        \\            Atomics.store(gate, 'waitSettled', -1000000);
        \\        }},
        \\        () => {{ Atomics.store(gate, 'waitSettled', -1000000); }});
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      while (Atomics.load(gate, 'park') === 0)
        \\        Atomics.wait(gate, 'park', 0, 10000);
        \\      return waitRoot;
        \\    }}, sab, gate, id, {d});
        \\    t.asyncJoin().then(
        \\      () => {{ globalThis.__midgcTermRejectScore = -1000000; }},
        \\      (e) => {{
        \\        if (e && joinRoot.marker === (id + 1) * 110000 + {d} &&
        \\            joinRoot.nested.root.seed === {d}) {{
        \\          globalThis.__midgcTermRejectScore += joinRoot.marker;
        \\          globalThis.__midgcTermRejectCount++;
        \\        }} else {{
        \\          globalThis.__midgcTermRejectScore = -1000000;
        \\        }}
        \\      }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      keep.push({{
        \\        round,
        \\        i,
        \\        nested: {{ root, value: i + round }},
        \\        text: 'midgc-termination-' + round + '-' + i,
        \\      }});
        \\    }}
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  throw new Error('threadfuzz midgc termination reactions {d} ' + keep.length);
        \\}})();
        \\
    ,
        .{ nthreads, seed, nthreads, seed_marker, seed_marker, seed_marker, seed, nthreads, rounds, per_round, seed },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    if (ctx.evaluate(src)) |_| {
        std.debug.print("seed {d}: midgc termination-reaction script returned normally\n", .{seed});
        return false;
    } else |err| {
        if (err != error.Throw) {
            std.debug.print("seed {d}: midgc termination-reaction failed with {s}\n", .{ seed, @errorName(err) });
            return false;
        }
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc termination-reaction did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc termination-reaction did not finish a parallel collection\n", .{seed});
        return false;
    }

    const score = ctx.evaluate("globalThis.__midgcTermRejectScore") catch |err| {
        std.debug.print("seed {d}: cannot read midgc termination-reaction score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!score.isNumber() or score.asNum() != @as(f64, @floatFromInt(expected_reject_score))) {
        std.debug.print("seed {d}: midgc termination-reaction score got {d}, expected {d}\n", .{ seed, if (score.isNumber()) score.asNum() else -1, expected_reject_score });
        return false;
    }
    const count = ctx.evaluate("globalThis.__midgcTermRejectCount") catch |err| {
        std.debug.print("seed {d}: cannot read midgc termination-reaction count: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!count.isNumber() or count.asNum() != @as(f64, @floatFromInt(nthreads))) {
        std.debug.print("seed {d}: midgc termination-reaction count got {d}, expected {d}\n", .{ seed, if (count.isNumber()) count.asNum() else -1, nthreads });
        return false;
    }

    const notify_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  let notified = 0;
        \\  for (let id = 0; id < {d}; id++)
        \\    notified += Atomics.notify(globalThis.__midgcTermView, id);
        \\  if (Atomics.load(globalThis.__midgcTermGate, 'waitSettled') !== 0)
        \\    throw new Error('midgc termination waitAsync reaction ran unexpectedly');
        \\  return notified;
        \\}})();
        \\
    ,
        .{nthreads},
    );
    defer gpa.free(notify_src);
    const notified = ctx.evaluate(notify_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc termination-reaction notify check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!notified.isNumber() or notified.asNum() != 0) {
        std.debug.print("seed {d}: midgc termination-reaction leaked {d} waitAsync tickets\n", .{ seed, if (notified.isNumber()) notified.asNum() else -1 });
        return false;
    }
    return true;
}

fn runMidScriptPromisePublicationGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6470_726f_6d67);
    const r = prng.random();
    const rounds = 9 + r.uintLessThan(usize, 7);
    const per_round = 850 + r.uintLessThan(usize, 450);
    const spin_iters = 3000 + r.uintLessThan(usize, 5000);
    const wait_timeout_ms = 1200 + r.uintLessThan(usize, 900);
    const return_wait_timeout_ms = 500 + r.uintLessThan(usize, 400);
    const seed_marker = seed % 10_000;
    const return_child_marker = 200_000 + seed_marker;
    const return_async_marker = 210_000 + seed_marker;
    const return_join_marker = 220_000 + seed_marker;
    const throw_reject_marker = 230_000 + seed_marker;
    const throw_join_marker = 240_000 + seed_marker;
    const reject_async_marker = 250_000 + seed_marker;
    const reject_join_marker = 260_000 + seed_marker;
    const then_async_marker = 270_000 + seed_marker;
    const then_join_marker = 280_000 + seed_marker;
    const expected_score = return_async_marker + return_join_marker + throw_reject_marker +
        reject_async_marker + reject_join_marker + then_async_marker + then_join_marker;

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc promise-publication context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcPromiseScore = 0;
        \\  globalThis.__midgcPromiseJoinThrow = 0;
        \\  globalThis.__midgcPromiseThrowPromiseSeen = 0;
        \\  globalThis.__midgcPromiseRejectPromiseSeen = 0;
        \\  globalThis.__midgcPromiseThenableCalls = 0;
        \\  const sab = new SharedArrayBuffer(8);
        \\  const view = new Int32Array(sab);
        \\  const gate = {{ prop: 0, propReady: 0, condReady: 0, condOpen: false, returnReady: 0, throwReady: 0, rejectReady: 0, releaseReject: 0, thenReady: 0, releaseThen: 0 }};
        \\  const lock = new Lock();
        \\  const cond = new Condition();
        \\  const root = {{ seed: {d}, tag: 'midgc-promise-publication-root' }};
        \\  const rejectAsyncMarker = 250000 + root.seed;
        \\  const rejectJoinMarker = 260000 + root.seed;
        \\  const thenAsyncMarker = 270000 + root.seed;
        \\  const thenJoinMarker = 280000 + root.seed;
        \\  const thenableValueMarker = 290000 + root.seed;
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
        \\  const returnedThread = new Thread((sab, gate, marker, seedMarker) => {{
        \\    const view = new Int32Array(sab);
        \\    const localRoot = {{
        \\      marker,
        \\      nested: {{ seed: seedMarker, label: 'midgc-returned-promise-child-root' }},
        \\    }};
        \\    const waiter = Atomics.waitAsync(view, 0, 0, {d});
        \\    if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\      throw new Error('bad midgc returned waitAsync pending shape');
        \\    Atomics.store(gate, 'returnReady', 1);
        \\    Atomics.notify(gate, 'returnReady');
        \\    return waiter.value.then((v) => {{
        \\      if (v !== 'timed-out' || localRoot.marker !== marker || localRoot.nested.seed !== seedMarker)
        \\        throw new Error('bad midgc returned promise child root');
        \\      return v;
        \\    }});
        \\  }}, sab, gate, {d}, {d});
        \\  const asyncJoinRoot = {{
        \\    marker: {d},
        \\    nested: {{ root, label: 'midgc-returned-promise-asyncJoin-root' }},
        \\  }};
        \\  returnedThread.asyncJoin().then(
        \\    (v) => {{
        \\      if (v === 'timed-out' && asyncJoinRoot.marker === {d} &&
        \\          asyncJoinRoot.nested.root.seed === {d})
        \\        globalThis.__midgcPromiseScore += asyncJoinRoot.marker;
        \\      else
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\    }},
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }});
        \\  const throwThread = new Thread((gate, marker, seedMarker) => {{
        \\    const reason = {{
        \\      marker,
        \\      nested: {{ seed: seedMarker, label: 'midgc-thrown-publication-root' }},
        \\      promise: Promise.resolve(marker + 7),
        \\    }};
        \\    Atomics.store(gate, 'throwReady', 1);
        \\    Atomics.notify(gate, 'throwReady');
        \\    throw reason;
        \\  }}, gate, {d}, {d});
        \\  const rejectedThread = new Thread((gate, marker, seedMarker) => {{
        \\    const reason = {{
        \\      marker,
        \\      nested: {{ seed: seedMarker, label: 'midgc-rejected-return-root' }},
        \\      promise: Promise.resolve(marker + 7),
        \\    }};
        \\    Atomics.store(gate, 'rejectReady', 1);
        \\    Atomics.notify(gate, 'rejectReady');
        \\    while (Atomics.load(gate, 'releaseReject') === 0)
        \\      Atomics.wait(gate, 'releaseReject', 0, 10000);
        \\    return Promise.reject(reason);
        \\  }}, gate, rejectJoinMarker, root.seed);
        \\  const rejectAsyncRoot = {{
        \\    marker: rejectAsyncMarker,
        \\    nested: {{ root, label: 'midgc-rejected-return-asyncJoin-root' }},
        \\  }};
        \\  rejectedThread.asyncJoin().then(
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }},
        \\    (e) => {{
        \\      if (e && e.marker === rejectJoinMarker && e.nested.seed === root.seed &&
        \\          rejectAsyncRoot.marker === rejectAsyncMarker &&
        \\          rejectAsyncRoot.nested.root.seed === root.seed) {{
        \\        globalThis.__midgcPromiseScore += rejectAsyncRoot.marker;
        \\        e.promise.then((v) => {{
        \\          if (v === rejectJoinMarker + 7)
        \\            globalThis.__midgcPromiseRejectPromiseSeen++;
        \\          else
        \\            globalThis.__midgcPromiseScore = -1000000;
        \\        }});
        \\      }} else {{
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\      }}
        \\    }});
        \\  const thenableThread = new Thread((gate, valueMarker, seedMarker) => {{
        \\    const localRoot = {{
        \\      marker: valueMarker,
        \\      nested: {{ seed: seedMarker, label: 'midgc-user-thenable-root' }},
        \\    }};
        \\    const thenable = {{
        \\      marker: valueMarker,
        \\      nested: {{ seed: seedMarker, label: 'midgc-user-thenable-result' }},
        \\      then(resolve, reject) {{
        \\        globalThis.__midgcPromiseThenableCalls++;
        \\        if (localRoot.marker === valueMarker && localRoot.nested.seed === seedMarker)
        \\          resolve(valueMarker);
        \\        else
        \\          reject({{ marker: -1 }});
        \\      }},
        \\    }};
        \\    Atomics.store(gate, 'thenReady', 1);
        \\    Atomics.notify(gate, 'thenReady');
        \\    while (Atomics.load(gate, 'releaseThen') === 0)
        \\      Atomics.wait(gate, 'releaseThen', 0, 10000);
        \\    return thenable;
        \\  }}, gate, thenableValueMarker, root.seed);
        \\  const thenAsyncRoot = {{
        \\    marker: thenAsyncMarker,
        \\    nested: {{ root, label: 'midgc-user-thenable-asyncJoin-root' }},
        \\  }};
        \\  thenableThread.asyncJoin().then(
        \\    (v) => {{
        \\      if (v === thenableValueMarker && thenAsyncRoot.marker === thenAsyncMarker &&
        \\          thenAsyncRoot.nested.root.seed === root.seed)
        \\        globalThis.__midgcPromiseScore += thenAsyncRoot.marker;
        \\      else
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\    }},
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }});
        \\  while (Atomics.load(gate, 'returnReady') === 0)
        \\    Atomics.wait(gate, 'returnReady', 0, 1);
        \\  while (Atomics.load(gate, 'throwReady') === 0)
        \\    Atomics.wait(gate, 'throwReady', 0, 1);
        \\  while (Atomics.load(gate, 'rejectReady') === 0)
        \\    Atomics.wait(gate, 'rejectReady', 0, 1);
        \\  while (Atomics.load(gate, 'thenReady') === 0)
        \\    Atomics.wait(gate, 'thenReady', 0, 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      keep.push({{
        \\        round,
        \\        i,
        \\        nested: {{ root, value: i + round }},
        \\        text: 'midgc-promise-publication-' + round + '-' + i,
        \\      }});
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ never: true }});
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  const joinedPromise = returnedThread.join();
        \\  if (!(joinedPromise instanceof Promise))
        \\    throw new Error('midgc join did not return child promise');
        \\  const joinRoot = {{
        \\    marker: {d},
        \\    nested: {{ root, label: 'midgc-returned-promise-join-root' }},
        \\  }};
        \\  joinedPromise.then(
        \\    (v) => {{
        \\      if (v === 'timed-out' && joinRoot.marker === {d} &&
        \\          joinRoot.nested.root.seed === {d})
        \\        globalThis.__midgcPromiseScore += joinRoot.marker;
        \\      else
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\    }},
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }});
        \\  const rejectRoot = {{
        \\    marker: {d},
        \\    nested: {{ root, label: 'midgc-throw-asyncJoin-root' }},
        \\  }};
        \\  throwThread.asyncJoin().then(
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }},
        \\    (e) => {{
        \\      if (e && e.marker === {d} && e.nested.seed === {d} &&
        \\          rejectRoot.marker === {d} && rejectRoot.nested.root.seed === {d}) {{
        \\        globalThis.__midgcPromiseScore += rejectRoot.marker;
        \\        e.promise.then((v) => {{
        \\          if (v === {d})
        \\            globalThis.__midgcPromiseThrowPromiseSeen = 1;
        \\          else
        \\            globalThis.__midgcPromiseScore = -1000000;
        \\        }});
        \\      }} else {{
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\      }}
        \\    }});
        \\  try {{
        \\    throwThread.join();
        \\    throw new Error('midgc throw thread completed normally');
        \\  }} catch (e) {{
        \\    if (!e || e.marker !== {d} || e.nested.seed !== {d})
        \\      throw new Error('bad midgc thrown publication join root');
        \\    globalThis.__midgcPromiseJoinThrow = e.marker;
        \\  }}
        \\  Atomics.store(gate, 'releaseReject', 1);
        \\  Atomics.notify(gate, 'releaseReject');
        \\  const rejectedJoined = rejectedThread.join();
        \\  if (!(rejectedJoined instanceof Promise))
        \\    throw new Error('midgc join did not return rejected child promise');
        \\  const rejectJoinRoot = {{
        \\    marker: rejectJoinMarker,
        \\    nested: {{ root, label: 'midgc-rejected-return-join-root' }},
        \\  }};
        \\  rejectedJoined.then(
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }},
        \\    (e) => {{
        \\      if (e && e.marker === rejectJoinMarker && e.nested.seed === root.seed &&
        \\          rejectJoinRoot.marker === rejectJoinMarker &&
        \\          rejectJoinRoot.nested.root.seed === root.seed) {{
        \\        globalThis.__midgcPromiseScore += rejectJoinRoot.marker;
        \\        e.promise.then((v) => {{
        \\          if (v === rejectJoinMarker + 7)
        \\            globalThis.__midgcPromiseRejectPromiseSeen++;
        \\          else
        \\            globalThis.__midgcPromiseScore = -1000000;
        \\        }});
        \\      }} else {{
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\      }}
        \\    }});
        \\  Atomics.store(gate, 'releaseThen', 1);
        \\  Atomics.notify(gate, 'releaseThen');
        \\  const joinedThenable = thenableThread.join();
        \\  if (!joinedThenable || typeof joinedThenable.then !== 'function' ||
        \\      joinedThenable.marker !== thenableValueMarker ||
        \\      joinedThenable.nested.seed !== root.seed)
        \\    throw new Error('midgc join did not return child thenable');
        \\  const thenJoinRoot = {{
        \\    marker: thenJoinMarker,
        \\    nested: {{ root, label: 'midgc-user-thenable-join-root' }},
        \\  }};
        \\  Promise.resolve(joinedThenable).then(
        \\    (v) => {{
        \\      if (v === thenableValueMarker && thenJoinRoot.marker === thenJoinMarker &&
        \\          thenJoinRoot.nested.root.seed === root.seed)
        \\        globalThis.__midgcPromiseScore += thenJoinRoot.marker;
        \\      else
        \\        globalThis.__midgcPromiseScore = -1000000;
        \\    }},
        \\    () => {{ globalThis.__midgcPromiseScore = -1000000; }});
        \\  Atomics.store(gate, 'prop', 1);
        \\  Atomics.notify(gate, 'prop');
        \\  lock.hold(() => {{
        \\    gate.condOpen = true;
        \\    cond.notifyAll();
        \\  }});
        \\  const propResult = propWaiter.join();
        \\  if (propResult !== 'ok' && propResult !== 'not-equal' && propResult !== 'timed-out')
        \\    throw new Error('bad midgc promise-publication property result: ' + propResult);
        \\  if (condWaiter.join() !== 'cond-ok')
        \\    throw new Error('midgc promise-publication condition waiter did not resume');
        \\  return keep.length;
        \\}})();
        \\
    ,
        .{
            seed_marker,
            wait_timeout_ms,
            return_wait_timeout_ms,
            return_child_marker,
            seed_marker,
            return_async_marker,
            return_async_marker,
            seed_marker,
            throw_join_marker,
            seed_marker,
            rounds,
            per_round,
            spin_iters,
            return_join_marker,
            return_join_marker,
            seed_marker,
            throw_reject_marker,
            throw_join_marker,
            seed_marker,
            throw_reject_marker,
            seed_marker,
            throw_join_marker + 7,
            throw_join_marker,
            seed_marker,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const expected: f64 = @floatFromInt(rounds * per_round);
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc promise-publication JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != expected) {
        std.debug.print("seed {d}: midgc promise-publication result got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc promise-publication did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc promise-publication did not finish a parallel collection\n", .{seed});
        return false;
    }
    const score = ctx.evaluate("globalThis.__midgcPromiseScore") catch |err| {
        std.debug.print("seed {d}: cannot read midgc promise-publication score: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!score.isNumber() or score.asNum() != @as(f64, @floatFromInt(expected_score))) {
        std.debug.print("seed {d}: midgc promise-publication score got {d}, expected {d}\n", .{ seed, if (score.isNumber()) score.asNum() else -1, expected_score });
        return false;
    }
    const thrown = ctx.evaluate("globalThis.__midgcPromiseJoinThrow") catch |err| {
        std.debug.print("seed {d}: cannot read midgc promise-publication thrown marker: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!thrown.isNumber() or thrown.asNum() != @as(f64, @floatFromInt(throw_join_marker))) {
        std.debug.print("seed {d}: midgc promise-publication thrown marker got {d}, expected {d}\n", .{ seed, if (thrown.isNumber()) thrown.asNum() else -1, throw_join_marker });
        return false;
    }
    const promise_seen = ctx.evaluate("globalThis.__midgcPromiseThrowPromiseSeen") catch |err| {
        std.debug.print("seed {d}: cannot read midgc promise-publication thrown promise marker: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!promise_seen.isNumber() or promise_seen.asNum() != 1) {
        std.debug.print("seed {d}: midgc promise-publication thrown promise marker got {d}\n", .{ seed, if (promise_seen.isNumber()) promise_seen.asNum() else -1 });
        return false;
    }
    const reject_promise_seen = ctx.evaluate("globalThis.__midgcPromiseRejectPromiseSeen") catch |err| {
        std.debug.print("seed {d}: cannot read midgc promise-publication rejected promise marker: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!reject_promise_seen.isNumber() or reject_promise_seen.asNum() != 2) {
        std.debug.print("seed {d}: midgc promise-publication rejected promise marker got {d}\n", .{ seed, if (reject_promise_seen.isNumber()) reject_promise_seen.asNum() else -1 });
        return false;
    }
    const thenable_calls = ctx.evaluate("globalThis.__midgcPromiseThenableCalls") catch |err| {
        std.debug.print("seed {d}: cannot read midgc promise-publication thenable calls: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!thenable_calls.isNumber() or thenable_calls.asNum() != 2) {
        std.debug.print("seed {d}: midgc promise-publication thenable calls got {d}\n", .{ seed, if (thenable_calls.isNumber()) thenable_calls.asNum() else -1 });
        return false;
    }
    return true;
}

fn runMidScriptMicrotaskChurnGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6467_636d_7175);
    const r = prng.random();
    const nthreads = 2 + r.uintLessThan(usize, 3);
    const per_thread = 6 + r.uintLessThan(usize, 7);
    const rounds = 8 + r.uintLessThan(usize, 5);
    const per_round = 650 + r.uintLessThan(usize, 350);
    const spin_iters = 2200 + r.uintLessThan(usize, 3000);
    const seed_marker = seed % 10_000;
    const root_marker = 470_000 + seed_marker;

    var expected_promise_score: usize = 0;
    var expected_wait_score: usize = 0;
    var expected_join_score: usize = 0;
    var expected_async_hold_score: usize = 0;
    var expected_release_score: usize = 0;
    var expected_join_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = 480_000 + seed_marker + id * 20_000;
        expected_promise_score += base + 100;
        expected_wait_score += base + 200;
        expected_join_score += base + 300;
        expected_join_sum += base + 300;
        expected_cleanup_count += per_thread;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) {
            expected_async_hold_score += base + 1_000 + i;
            expected_release_score += base + 2_000 + i;
            expected_cleanup_sum += base + 3_000 + i;
        }
    }

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc microtask-churn context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcMicrotaskPromiseScore = 0;
        \\  globalThis.__midgcMicrotaskWaitScore = 0;
        \\  globalThis.__midgcMicrotaskJoinScore = 0;
        \\  globalThis.__midgcMicrotaskAsyncHoldScore = 0;
        \\  globalThis.__midgcMicrotaskReleaseScore = 0;
        \\  globalThis.__midgcMicrotaskJoinObserved = 0;
        \\  globalThis.__midgcMicrotaskCleanupCount = 0;
        \\  globalThis.__midgcMicrotaskCleanupSum = 0;
        \\  globalThis.__midgcMicrotaskRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__midgcMicrotaskCleanupCount++;
        \\    globalThis.__midgcMicrotaskCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__midgcMicrotaskRegistry;
        \\  const root = {{ marker: {d}, nested: {{ seed: {d}, label: 'midgc-microtask-root' }} }};
        \\  const view = new Int32Array(new SharedArrayBuffer({d} * 4));
        \\  const lock = new Lock();
        \\  const gate = {{ ready: 0 }};
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const base = 480000 + {d} + id * 20000;
        \\    const promiseMarker = base + 100;
        \\    Promise.resolve(root).then(
        \\      (v) => {{
        \\        if (v.marker === {d} && v.nested.seed === {d})
        \\          globalThis.__midgcMicrotaskPromiseScore += promiseMarker;
        \\        else
        \\          globalThis.__midgcMicrotaskPromiseScore = -1000000;
        \\      }},
        \\      () => {{ globalThis.__midgcMicrotaskPromiseScore = -1000000; }});
        \\    const waitRoot = {{ marker: base + 200, nested: {{ root, label: 'midgc-microtask-wait-root' }} }};
        \\    const waiter = Atomics.waitAsync(view, id, 0, 10000);
        \\    if (waiter.async !== true || !(waiter.value instanceof Promise))
        \\      throw new Error('bad midgc microtask waitAsync pending shape');
        \\    waiter.value.then(
        \\      (v) => {{
        \\        if (v === 'ok' && waitRoot.nested.root.marker === {d})
        \\          globalThis.__midgcMicrotaskWaitScore += waitRoot.marker;
        \\        else
        \\          globalThis.__midgcMicrotaskWaitScore = -1000000;
        \\      }},
        \\      () => {{ globalThis.__midgcMicrotaskWaitScore = -1000000; }});
        \\    const joinRoot = {{ marker: base + 300, nested: {{ root, label: 'midgc-microtask-asyncJoin-root' }} }};
        \\    const t = new Thread((view, gate, id, per, seedMarker, registry) => {{
        \\      const base = 480000 + seedMarker + id * 20000;
        \\      let local = {{ marker: base + 300, nested: {{ seed: seedMarker, label: 'midgc-microtask-thread-root' }} }};
        \\      for (let i = 0; i < per; i++) {{
        \\        let target = {{ id, i, local, payload: 'midgc-microtask-cleanup-' + id + '-' + i }};
        \\        registry.register(target, base + 3000 + i);
        \\        target = null;
        \\      }}
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      Atomics.store(view, id, 1);
        \\      const notified = Atomics.notify(view, id);
        \\      if (notified !== 1)
        \\        throw new Error('midgc microtask notify got ' + notified);
        \\      return local;
        \\    }}, view, gate, id, {d}, {d}, registry);
        \\    t.asyncJoin().then(
        \\      (v) => {{
        \\        if (v && v.marker === joinRoot.marker &&
        \\            joinRoot.nested.root.marker === {d} &&
        \\            v.nested.seed === {d})
        \\          globalThis.__midgcMicrotaskJoinScore += joinRoot.marker;
        \\        else
        \\          globalThis.__midgcMicrotaskJoinScore = -1000000;
        \\      }},
        \\      () => {{ globalThis.__midgcMicrotaskJoinScore = -1000000; }});
        \\    threads.push(t);
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const cbRoot = {{ marker: base + 1000 + i, nested: {{ root, label: 'midgc-microtask-asyncHold-root' }} }};
        \\      lock.asyncHold(() => cbRoot).then(
        \\        (v) => {{
        \\          if (v.marker === cbRoot.marker && v.nested.root.marker === {d})
        \\            globalThis.__midgcMicrotaskAsyncHoldScore += v.marker;
        \\          else
        \\            globalThis.__midgcMicrotaskAsyncHoldScore = -1000000;
        \\        }},
        \\        () => {{ globalThis.__midgcMicrotaskAsyncHoldScore = -1000000; }});
        \\      const releaseRoot = {{ marker: base + 2000 + i, nested: {{ root, label: 'midgc-microtask-release-root' }} }};
        \\      lock.asyncHold().then(
        \\        (release) => {{
        \\          if (typeof release !== 'function' || releaseRoot.nested.root.marker !== {d}) {{
        \\            globalThis.__midgcMicrotaskReleaseScore = -1000000;
        \\          }} else {{
        \\            globalThis.__midgcMicrotaskReleaseScore += releaseRoot.marker;
        \\            release();
        \\          }}
        \\        }},
        \\        () => {{ globalThis.__midgcMicrotaskReleaseScore = -1000000; }});
        \\    }}
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      keep.push({{
        \\        round,
        \\        i,
        \\        nested: {{ root, value: i + round }},
        \\        text: 'midgc-microtask-churn-' + round + '-' + i,
        \\      }});
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ impossible: true }});
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  for (const t of threads) {{
        \\    const joined = t.join();
        \\    if (!joined || joined.nested.seed !== {d})
        \\      throw new Error('bad midgc microtask joined root');
        \\    globalThis.__midgcMicrotaskJoinObserved += joined.marker;
        \\  }}
        \\  globalThis.__midgcMicrotaskCheck = function(expectedPromise, expectedWait, expectedJoin, expectedAsyncHold, expectedRelease, expectedJoinObserved) {{
        \\    if (globalThis.__midgcMicrotaskPromiseScore !== expectedPromise)
        \\      throw new Error('bad midgc microtask promise score ' + globalThis.__midgcMicrotaskPromiseScore + '/' + expectedPromise);
        \\    if (globalThis.__midgcMicrotaskWaitScore !== expectedWait)
        \\      throw new Error('bad midgc microtask waitAsync score ' + globalThis.__midgcMicrotaskWaitScore + '/' + expectedWait);
        \\    if (globalThis.__midgcMicrotaskJoinScore !== expectedJoin)
        \\      throw new Error('bad midgc microtask asyncJoin score ' + globalThis.__midgcMicrotaskJoinScore + '/' + expectedJoin);
        \\    if (globalThis.__midgcMicrotaskAsyncHoldScore !== expectedAsyncHold)
        \\      throw new Error('bad midgc microtask asyncHold score ' + globalThis.__midgcMicrotaskAsyncHoldScore + '/' + expectedAsyncHold);
        \\    if (globalThis.__midgcMicrotaskReleaseScore !== expectedRelease)
        \\      throw new Error('bad midgc microtask release score ' + globalThis.__midgcMicrotaskReleaseScore + '/' + expectedRelease);
        \\    if (globalThis.__midgcMicrotaskJoinObserved !== expectedJoinObserved)
        \\      throw new Error('bad midgc microtask joined score ' + globalThis.__midgcMicrotaskJoinObserved + '/' + expectedJoinObserved);
        \\    return 1;
        \\  }};
        \\  return keep.length;
        \\}})();
        \\
    ,
        .{
            root_marker,
            seed_marker,
            nthreads,
            nthreads,
            seed_marker,
            root_marker,
            seed_marker,
            root_marker,
            per_thread,
            seed_marker,
            root_marker,
            seed_marker,
            per_thread,
            root_marker,
            root_marker,
            nthreads,
            rounds,
            per_round,
            spin_iters,
            seed_marker,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const expected: f64 = @floatFromInt(rounds * per_round);
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc microtask-churn JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != expected) {
        std.debug.print("seed {d}: midgc microtask-churn result got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc microtask-churn did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc microtask-churn did not finish a parallel collection\n", .{seed});
        return false;
    }

    _ = ctx.evaluate("$drainRunLoop()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc microtask-churn drain loop threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const check_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__midgcMicrotaskCheck({d}, {d}, {d}, {d}, {d}, {d})",
        .{ expected_promise_score, expected_wait_score, expected_join_score, expected_async_hold_score, expected_release_score, expected_join_sum },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc microtask-churn check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != 1) {
        std.debug.print("seed {d}: midgc microtask-churn check got {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1 });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcMicrotaskRegistry.cleanupSome();
        \\  if (globalThis.__midgcMicrotaskCleanupCount !== {d})
        \\    throw new Error('bad midgc microtask cleanup count ' + globalThis.__midgcMicrotaskCleanupCount + '/' + {d});
        \\  if (globalThis.__midgcMicrotaskCleanupSum !== {d})
        \\    throw new Error('bad midgc microtask cleanup sum ' + globalThis.__midgcMicrotaskCleanupSum + '/' + {d});
        \\  return globalThis.__midgcMicrotaskCleanupCount;
        \\}})();
        \\
    ,
        .{ expected_cleanup_count, expected_cleanup_count, expected_cleanup_sum, expected_cleanup_sum },
    );
    defer gpa.free(cleanup_src);
    const cleaned = ctx.evaluate(cleanup_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc microtask-churn cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: midgc microtask-churn cleanup got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
        return false;
    }
    return true;
}

fn runMidScriptCreatorOwnedBufferGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6467_6362_7566);
    const r = prng.random();
    const ncreators = 2 + r.uintLessThan(usize, 3);
    const per_buffer = 12 + r.uintLessThan(usize, 12);
    const rounds = 8 + r.uintLessThan(usize, 5);
    const per_round = 650 + r.uintLessThan(usize, 350);
    const spin_iters = 2200 + r.uintLessThan(usize, 3000);
    const seed_marker = seed % 10_000;

    var payload_sum: usize = 0;
    var id: usize = 0;
    while (id < ncreators) : (id += 1) {
        const base = 530_000 + seed_marker + id * 10_000;
        var i: usize = 0;
        while (i < per_buffer) : (i += 1) payload_sum += base + i;
    }
    const expected_total = payload_sum * 3;
    const expected_async_score = payload_sum * 2;

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc creator-owned buffer context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcCreatorBufferAsyncScore = 0;
        \\  globalThis.__midgcCreatorBufferAsyncCount = 0;
        \\  const gate = {{ ready: 0 }};
        \\  const root = {{ seed: {d}, tag: 'midgc-creator-owned-buffer-root' }};
        \\  const threads = [];
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((gate, id, per, seedMarker) => {{
        \\      const base = 530000 + seedMarker + id * 10000;
        \\      const sab = new SharedArrayBuffer(per * 4);
        \\      const ab = new ArrayBuffer(per * 4);
        \\      const movable = new ArrayBuffer(per * 4);
        \\      const sv = new Int32Array(sab);
        \\      const av = new Int32Array(ab);
        \\      const mv = new Int32Array(movable);
        \\      let sum = 0;
        \\      for (let i = 0; i < per; i++) {{
        \\        const v = base + i;
        \\        sv[i] = v;
        \\        av[i] = v;
        \\        mv[i] = v;
        \\        sum += v;
        \\      }}
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      return {{ id, sab, ab, movable, sum, base, root: {{ seed: seedMarker, label: 'midgc-creator-buffer-result' }} }};
        \\    }}, gate, id, {d}, {d});
        \\    t.asyncJoin().then(
        \\      (bundle) => {{
        \\        const sv = new Int32Array(bundle.sab);
        \\        const av = new Int32Array(bundle.ab);
        \\        let local = 0;
        \\        for (let i = 0; i < {d}; i++) {{
        \\          const expected = bundle.base + i;
        \\          if (sv[i] !== expected || av[i] !== expected || bundle.root.seed !== {d}) {{
        \\            globalThis.__midgcCreatorBufferAsyncScore = -1000000;
        \\            return;
        \\          }}
        \\          local += sv[i] + av[i];
        \\        }}
        \\        globalThis.__midgcCreatorBufferAsyncScore += local;
        \\        globalThis.__midgcCreatorBufferAsyncCount++;
        \\      }},
        \\      () => {{ globalThis.__midgcCreatorBufferAsyncScore = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  const keep = [];
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      keep.push({{
        \\        round,
        \\        i,
        \\        nested: {{ root, seed: {d}, value: i + round }},
        \\        text: 'midgc-creator-buffer-' + round + '-' + i,
        \\      }});
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ impossible: true }});
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  let total = 0;
        \\  for (const t of threads) {{
        \\    const bundle = t.join();
        \\    const sv = new Int32Array(bundle.sab);
        \\    const av = new Int32Array(bundle.ab);
        \\    let local = 0;
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const expected = bundle.base + i;
        \\      if (sv[i] !== expected)
        \\        throw new Error('midgc creator-owned SAB lost word ' + i + '/' + sv[i] + '/' + expected);
        \\      if (av[i] !== expected)
        \\        throw new Error('midgc creator-owned AB lost word ' + i + '/' + av[i] + '/' + expected);
        \\      local += sv[i] + av[i];
        \\    }}
        \\    if (local !== bundle.sum * 2)
        \\      throw new Error('bad midgc creator-owned main checksum ' + local + '/' + (bundle.sum * 2));
        \\    total += local;
        \\    const copy = bundle.movable.transfer();
        \\    if (bundle.movable.byteLength !== 0)
        \\      throw new Error('midgc creator-owned movable buffer did not detach');
        \\    const cv = new Int32Array(copy);
        \\    let copySum = 0;
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const expected = bundle.base + i;
        \\      if (cv[i] !== expected)
        \\        throw new Error('midgc creator-owned transferred copy lost word');
        \\      copySum += cv[i];
        \\    }}
        \\    if (copySum !== bundle.sum)
        \\      throw new Error('bad midgc creator-owned transferred checksum ' + copySum + '/' + bundle.sum);
        \\    total += copySum;
        \\  }}
        \\  globalThis.__midgcCreatorBufferCheck = function(expectedScore, expectedCount) {{
        \\    if (globalThis.__midgcCreatorBufferAsyncScore !== expectedScore)
        \\      throw new Error('bad midgc creator-owned async score ' + globalThis.__midgcCreatorBufferAsyncScore + '/' + expectedScore);
        \\    if (globalThis.__midgcCreatorBufferAsyncCount !== expectedCount)
        \\      throw new Error('bad midgc creator-owned async count ' + globalThis.__midgcCreatorBufferAsyncCount + '/' + expectedCount);
        \\    return 1;
        \\  }};
        \\  return total;
        \\}})();
        \\
    ,
        .{
            seed_marker,
            ncreators,
            per_buffer,
            seed_marker,
            per_buffer,
            seed_marker,
            ncreators,
            rounds,
            per_round,
            seed_marker,
            spin_iters,
            per_buffer,
            per_buffer,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc creator-owned buffer JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != @as(f64, @floatFromInt(expected_total))) {
        std.debug.print("seed {d}: midgc creator-owned buffer got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected_total });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc creator-owned buffer did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc creator-owned buffer did not finish a parallel collection\n", .{seed});
        return false;
    }

    _ = ctx.evaluate("$drainRunLoop()") catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc creator-owned buffer drain loop threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    const check_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__midgcCreatorBufferCheck({d}, {d})",
        .{ expected_async_score, ncreators },
    );
    defer gpa.free(check_src);
    const checked = ctx.evaluate(check_src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc creator-owned buffer check threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!checked.isNumber() or checked.asNum() != 1) {
        std.debug.print("seed {d}: midgc creator-owned buffer check got {d}\n", .{ seed, if (checked.isNumber()) checked.asNum() else -1 });
        return false;
    }
    return true;
}

fn runMidScriptWorkerCleanupGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6477_6f72_6b63);
    const r = prng.random();
    const nworkers = 1 + r.uintLessThan(usize, 2);
    const nthreads = 2 + r.uintLessThan(usize, 3);
    const per_thread = 6 + r.uintLessThan(usize, 8);
    const worker_iters = 700 + r.uintLessThan(usize, 500);
    const rounds = 8 + r.uintLessThan(usize, 5);
    const per_round = 650 + r.uintLessThan(usize, 350);
    const spin_iters = 2200 + r.uintLessThan(usize, 3000);
    const seed_marker = seed % 10_000;
    const cleanup_base = 450_000 + seed_marker;

    var expected_join_sum: usize = 0;
    var expected_cleanup_count: usize = 0;
    var expected_cleanup_sum: usize = 0;
    var id: usize = 0;
    while (id < nthreads) : (id += 1) {
        const base = (id + 1) * 460_000 + seed_marker;
        expected_join_sum += base + per_thread + id;
        expected_cleanup_count += per_thread;
        var i: usize = 0;
        while (i < per_thread) : (i += 1) expected_cleanup_sum += base + i;
    }
    var round_i: usize = 0;
    while (round_i < rounds) : (round_i += 1) {
        var i: usize = 0;
        while (i < per_round) : (i += 1) {
            if (((i + round_i) & 31) == 11) {
                expected_cleanup_count += 1;
                expected_cleanup_sum += cleanup_base + round_i * per_round + i;
            }
        }
    }

    const ctx = js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    }) catch {
        std.debug.print("seed {d}: midgc worker-cleanup context creation failed\n", .{seed});
        return false;
    };
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const msg_src = try std.fmt.allocPrint(
        gpa,
        "globalThis.__midgcWorkerCleanupMsg = {{ sab: new SharedArrayBuffer(32), iters: {d} }}; globalThis.__midgcWorkerCleanupMsg",
        .{worker_iters},
    );
    defer gpa.free(msg_src);
    const msg = ctx.evaluate(msg_src) catch |err| {
        std.debug.print("seed {d}: cannot create midgc worker-cleanup message: {s}\n", .{ seed, @errorName(err) });
        return false;
    };

    const worker_src =
        \\globalThis.onmessage = (e) => {
        \\  const v = new Int32Array(e.data.sab);
        \\  Atomics.add(v, 0, 1);
        \\  Atomics.notify(v, 0);
        \\  while (Atomics.load(v, 1) === 0)
        \\    Atomics.wait(v, 1, 0, 100);
        \\  let local = 0;
        \\  for (let i = 0; i < e.data.iters; i++) {
        \\    local += i & 1;
        \\    Atomics.add(v, 2, 1);
        \\    if ((i & 127) === 0)
        \\      Atomics.add(v, 3, 1);
        \\  }
        \\  postMessage({ done: true, local, after: Atomics.add(v, 4, 1) + 1 });
        \\  close();
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
            std.debug.print("seed {d}: midgc worker-cleanup worker spawn failed\n", .{seed});
            return false;
        };
        try workers.append(gpa, w);
        w.postMessage(&machine, msg) catch |err| {
            std.debug.print("seed {d}: midgc worker-cleanup post failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
    }

    const src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcWorkerCleanupCount = 0;
        \\  globalThis.__midgcWorkerCleanupSum = 0;
        \\  globalThis.__midgcWorkerCleanupOracle = 0;
        \\  globalThis.__midgcWorkerCleanupRegistry = new FinalizationRegistry((held) => {{
        \\    globalThis.__midgcWorkerCleanupCount++;
        \\    globalThis.__midgcWorkerCleanupSum += held;
        \\  }});
        \\  const registry = globalThis.__midgcWorkerCleanupRegistry;
        \\  const v = new Int32Array(globalThis.__midgcWorkerCleanupMsg.sab);
        \\  const gate = {{ ready: 0, release: 0 }};
        \\  const threads = [];
        \\  let asyncSum = 0;
        \\  for (let id = 0; id < {d}; id++) {{
        \\    const t = new Thread((id, per, seedMarker) => {{
        \\      const local = new Int32Array(globalThis.__midgcWorkerCleanupMsg.sab);
        \\      const base = (id + 1) * 460000 + seedMarker;
        \\      const root = {{
        \\        marker: base + per + id,
        \\        nested: {{ seed: seedMarker, label: 'midgc-worker-cleanup-thread-root' }},
        \\      }};
        \\      for (let i = 0; i < per; i++) {{
        \\        Atomics.add(local, 2, 1);
        \\        let target = {{ id, i, root, payload: 'midgc-worker-cleanup-thread-' + id + '-' + i }};
        \\        registry.register(target, base + i);
        \\        target = null;
        \\      }}
        \\      Atomics.add(gate, 'ready', 1);
        \\      Atomics.notify(gate, 'ready');
        \\      while (Atomics.load(gate, 'release') === 0)
        \\        Atomics.wait(gate, 'release', 0, 1000);
        \\      if (root.nested.seed !== seedMarker)
        \\        throw new Error('bad midgc worker-cleanup thread root seed');
        \\      return root;
        \\    }}, id, {d}, {d});
        \\    t.asyncJoin().then(
        \\      (root) => {{
        \\        if (root && root.nested && root.nested.seed === {d})
        \\          asyncSum += root.marker;
        \\        else
        \\          asyncSum = -1000000;
        \\      }},
        \\      () => {{ asyncSum = -1000000; }});
        \\    threads.push(t);
        \\  }}
        \\  while (Atomics.load(gate, 'ready') < {d})
        \\    Atomics.wait(gate, 'ready', Atomics.load(gate, 'ready'), 1);
        \\  while (Atomics.load(v, 0) < {d})
        \\    Atomics.wait(v, 0, Atomics.load(v, 0), 1);
        \\  Atomics.store(v, 1, 1);
        \\  Atomics.notify(v, 1, {d});
        \\  let activeSpins = 0;
        \\  while (Atomics.load(v, 3) === 0 && activeSpins++ < 10000000)
        \\    ;
        \\  if (Atomics.load(v, 3) === 0)
        \\    throw new Error('midgc worker-cleanup workers did not run concurrently');
        \\  const keep = [];
        \\  const root = {{ seed: {d}, tag: 'midgc-worker-cleanup-main-root' }};
        \\  for (let round = 0; round < {d}; round++) {{
        \\    for (let i = 0; i < {d}; i++) {{
        \\      keep.push({{
        \\        round,
        \\        i,
        \\        nested: {{ root, value: i + round }},
        \\        text: 'midgc-worker-cleanup-' + round + '-' + i,
        \\      }});
        \\      if (((i + round) & 31) === 11)
        \\        registry.register({{ ephemeral: i, round, root }}, {d} + round * {d} + i);
        \\    }}
        \\    let spin = 0;
        \\    for (let j = 0; j < {d}; j++) spin = (spin + j + round) & 0x3fffffff;
        \\    if (spin < 0) keep.push({{ impossible: true }});
        \\  }}
        \\  if (typeof gc === 'function') gc();
        \\  Atomics.store(gate, 'release', 1);
        \\  Atomics.notify(gate, 'release', {d});
        \\  let joinSum = 0;
        \\  for (const t of threads) {{
        \\    const rootResult = t.join();
        \\    if (!rootResult || rootResult.nested.seed !== {d})
        \\      throw new Error('bad midgc worker-cleanup joined root');
        \\    joinSum += rootResult.marker;
        \\  }}
        \\  if (joinSum !== {d})
        \\    throw new Error('bad midgc worker-cleanup join sum ' + joinSum);
        \\  Promise.resolve().then(() => {{
        \\    if (asyncSum !== {d})
        \\      throw new Error('bad midgc worker-cleanup async sum ' + asyncSum);
        \\    globalThis.__midgcWorkerCleanupOracle = 1;
        \\  }});
        \\  return keep.length;
        \\}})();
        \\
    ,
        .{
            nthreads,
            per_thread,
            seed_marker,
            seed_marker,
            nthreads,
            nworkers,
            nworkers + nthreads + 4,
            seed_marker,
            rounds,
            per_round,
            cleanup_base,
            per_round,
            spin_iters,
            nthreads + 4,
            seed_marker,
            expected_join_sum,
            expected_join_sum,
        },
    );
    defer gpa.free(src);

    const before_attempts = ctx.gc_par_attempts.load(.monotonic);
    const before_collections = ctx.gc_par_collections.load(.monotonic);
    const expected: f64 = @floatFromInt(rounds * per_round);
    const result = ctx.evaluate(src) catch |err| {
        const msg_txt = if (ctx.exception) |ex| blk: {
            var render = ctx.interpreter();
            break :blk render.toStringV(ex) catch "<unstringifiable>";
        } else "<none>";
        std.debug.print("seed {d}: midgc worker-cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!result.isNumber() or result.asNum() != expected) {
        std.debug.print("seed {d}: midgc worker-cleanup result got {d}, expected {d}\n", .{ seed, if (result.isNumber()) result.asNum() else -1, expected });
        return false;
    }
    if (ctx.gc_par_attempts.load(.monotonic) <= before_attempts) {
        std.debug.print("seed {d}: midgc worker-cleanup did not attempt a parallel collection\n", .{seed});
        return false;
    }
    if (ctx.gc_par_collections.load(.monotonic) <= before_collections) {
        std.debug.print("seed {d}: midgc worker-cleanup did not finish a parallel collection\n", .{seed});
        return false;
    }
    const oracle = ctx.evaluate("globalThis.__midgcWorkerCleanupOracle") catch |err| {
        std.debug.print("seed {d}: cannot read midgc worker-cleanup oracle: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!oracle.isNumber() or oracle.asNum() != 1) {
        std.debug.print("seed {d}: midgc worker-cleanup oracle got {d}\n", .{ seed, if (oracle.isNumber()) oracle.asNum() else -1 });
        return false;
    }

    const expected_worker_local: f64 = @floatFromInt(worker_iters / 2);
    var replies: usize = 0;
    while (replies < nworkers) : (replies += 1) {
        const reply = (workers.items[replies].receive(&machine, 10_000) catch |err| {
            std.debug.print("seed {d}: midgc worker-cleanup receive failed: {s}\n", .{ seed, @errorName(err) });
            return false;
        }) orelse {
            std.debug.print("seed {d}: midgc worker-cleanup receive timed out\n", .{seed});
            return false;
        };
        const done = machine.getProperty(reply, "done") catch |err| {
            std.debug.print("seed {d}: cannot read midgc worker-cleanup done: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const local = machine.getProperty(reply, "local") catch |err| {
            std.debug.print("seed {d}: cannot read midgc worker-cleanup local: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        const after = machine.getProperty(reply, "after") catch |err| {
            std.debug.print("seed {d}: cannot read midgc worker-cleanup after: {s}\n", .{ seed, @errorName(err) });
            return false;
        };
        if (!done.isBoolean() or !done.asBool() or !local.isNumber() or local.asNum() != expected_worker_local or !after.isNumber() or after.asNum() < 1 or after.asNum() > @as(f64, @floatFromInt(nworkers))) {
            std.debug.print("seed {d}: bad midgc worker-cleanup reply\n", .{seed});
            return false;
        }
    }
    for (workers.items) |w| {
        w.join();
        w.destroy();
    }
    cleanup_workers = false;

    const expected_counter: f64 = @floatFromInt(nworkers * worker_iters + nthreads * per_thread);
    const counter = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__midgcWorkerCleanupMsg.sab), 2)") catch |err| {
        std.debug.print("seed {d}: cannot read midgc worker-cleanup counter: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!counter.isNumber() or counter.asNum() != expected_counter) {
        std.debug.print("seed {d}: midgc worker-cleanup counter got {d}, expected {d}\n", .{ seed, if (counter.isNumber()) counter.asNum() else -1, expected_counter });
        return false;
    }
    const worker_done = ctx.evaluate("Atomics.load(new Int32Array(globalThis.__midgcWorkerCleanupMsg.sab), 4)") catch |err| {
        std.debug.print("seed {d}: cannot read midgc worker-cleanup worker done: {s}\n", .{ seed, @errorName(err) });
        return false;
    };
    if (!worker_done.isNumber() or worker_done.asNum() != @as(f64, @floatFromInt(nworkers))) {
        std.debug.print("seed {d}: midgc worker-cleanup worker done got {d}, expected {d}\n", .{ seed, if (worker_done.isNumber()) worker_done.asNum() else -1, nworkers });
        return false;
    }

    ctx.collectGarbage();
    const cleanup_src = try std.fmt.allocPrint(
        gpa,
        \\(() => {{
        \\  globalThis.__midgcWorkerCleanupRegistry.cleanupSome();
        \\  if (globalThis.__midgcWorkerCleanupCount !== {d})
        \\    throw new Error('bad midgc worker-cleanup cleanup count: ' + globalThis.__midgcWorkerCleanupCount);
        \\  if (globalThis.__midgcWorkerCleanupSum !== {d})
        \\    throw new Error('bad midgc worker-cleanup cleanup sum: ' + globalThis.__midgcWorkerCleanupSum);
        \\  return globalThis.__midgcWorkerCleanupCount;
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
        std.debug.print("seed {d}: midgc worker-cleanup cleanup JS threw {s}: {s}\n", .{ seed, @errorName(err), msg_txt });
        return false;
    };
    if (!cleaned.isNumber() or cleaned.asNum() != @as(f64, @floatFromInt(expected_cleanup_count))) {
        std.debug.print("seed {d}: midgc worker-cleanup cleaned got {d}, expected {d}\n", .{ seed, if (cleaned.isNumber()) cleaned.asNum() else -1, expected_cleanup_count });
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
    // `threadfuzz tlsfinal <iters> <seed>`: focused lifecycle repro for
    // ThreadLocal values registered for finalization across park/resume/cleanup.
    if (first) |a| if (std.mem.eql(u8, a, "tlsfinal")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var tfail: usize = 0;
        var ti: usize = 0;
        while (ti < iters) : (ti += 1) {
            const seed = base_seed +% ti;
            if (!(try runThreadLocalFinalizationCleanupInterleaving(gpa, seed))) tfail += 1;
        }
        std.debug.print("threadfuzz tlsfinal: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, tfail });
        if (tfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz waitasyncfinal <iters> <seed>`: focused lifecycle repro for
    // typed-array waitAsync settlement plus asyncJoin and finalization cleanup.
    if (first) |a| if (std.mem.eql(u8, a, "waitasyncfinal")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var wfail: usize = 0;
        var wi: usize = 0;
        while (wi < iters) : (wi += 1) {
            const seed = base_seed +% wi;
            if (!(try runWaitAsyncFinalizationCleanupInterleaving(gpa, seed))) wfail += 1;
        }
        std.debug.print("threadfuzz waitasyncfinal: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, wfail });
        if (wfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz microtaskchurn <iters> <seed>`: focused lifecycle repro for
    // Promise reaction queue churn across asyncHold, waitAsync, asyncJoin, and
    // finalization cleanup.
    if (first) |a| if (std.mem.eql(u8, a, "microtaskchurn")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mcfail: usize = 0;
        var mci: usize = 0;
        while (mci < iters) : (mci += 1) {
            const seed = base_seed +% mci;
            if (!(try runMicrotaskChurnLifecycleInterleaving(gpa, seed))) mcfail += 1;
        }
        std.debug.print("threadfuzz microtaskchurn: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mcfail });
        if (mcfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz creatorbuffers <iters> <seed>`: focused lifecycle repro for
    // SharedArrayBuffer and ArrayBuffer storage created by a child Thread,
    // observed after the creator exits, then read/transferred under GC pressure.
    if (first) |a| if (std.mem.eql(u8, a, "creatorbuffers")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var cbfail: usize = 0;
        var cbi: usize = 0;
        while (cbi < iters) : (cbi += 1) {
            const seed = base_seed +% cbi;
            if (!(try runCreatorOwnedBufferLifecycleInterleaving(gpa, seed))) cbfail += 1;
        }
        std.debug.print("threadfuzz creatorbuffers: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, cbfail });
        if (cbfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz workercreatorbuffers <iters> <seed>`: focused lifecycle
    // repro for child-created SAB/ArrayBuffer storage crossing isolated Worker
    // structured-clone after the creator Thread exits.
    if (first) |a| if (std.mem.eql(u8, a, "workercreatorbuffers")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var wcbfail: usize = 0;
        var wcbi: usize = 0;
        while (wcbi < iters) : (wcbi += 1) {
            const seed = base_seed +% wcbi;
            if (!(try runWorkerCreatorOwnedBufferLifecycleInterleaving(gpa, seed))) wcbfail += 1;
        }
        std.debug.print("threadfuzz workercreatorbuffers: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, wcbfail });
        if (wcbfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz termreact <iters> <seed>`: focused lifecycle repro for
    // teardown termination while asyncJoin reactions and child-owned typed-array
    // waitAsync tickets are still pending.
    if (first) |a| if (std.mem.eql(u8, a, "termreact")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var trfail: usize = 0;
        var tri: usize = 0;
        while (tri < iters) : (tri += 1) {
            const seed = base_seed +% tri;
            if (!(try runTerminationPendingReactionInterleaving(gpa, seed))) trfail += 1;
        }
        std.debug.print("threadfuzz termreact: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, trfail });
        if (trfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz termcleanup <iters> <seed>`: focused lifecycle repro for
    // teardown termination while property waitAsync timeouts, async condition
    // reacquire, pending asyncJoin rejection, and finalization cleanup jobs are
    // all live in the same realm.
    if (first) |a| if (std.mem.eql(u8, a, "termcleanup")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var tcfail: usize = 0;
        var tci: usize = 0;
        while (tci < iters) : (tci += 1) {
            const seed = base_seed +% tci;
            if (!(try runTerminationWaiterCleanupInterleaving(gpa, seed))) tcfail += 1;
        }
        std.debug.print("threadfuzz termcleanup: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, tcfail });
        if (tcfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz workercleanup <iters> <seed>`: focused lifecycle repro for
    // Worker handler exception recovery while shared-realm Threads register
    // FinalizationRegistry records on the same retained SAB.
    if (first) |a| if (std.mem.eql(u8, a, "workercleanup")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var wcfail: usize = 0;
        var wci: usize = 0;
        while (wci < iters) : (wci += 1) {
            const seed = base_seed +% wci;
            if (!(try runWorkerExceptionFinalizationCleanupInterleaving(gpa, seed))) wcfail += 1;
        }
        std.debug.print("threadfuzz workercleanup: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, wcfail });
        if (wcfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz workertermteardown <iters> <seed>`: focused lifecycle repro
    // for isolated Worker termination while a shared-realm top-level failure
    // tears down parked Threads, pending asyncJoin reactions, and cleanup jobs.
    if (first) |a| if (std.mem.eql(u8, a, "workertermteardown")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var wtfail: usize = 0;
        var wti: usize = 0;
        while (wti < iters) : (wti += 1) {
            const seed = base_seed +% wti;
            if (!(try runWorkerTerminateThreadTeardownInterleaving(gpa, seed))) wtfail += 1;
        }
        std.debug.print("threadfuzz workertermteardown: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, wtfail });
        if (wtfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz moduletermteardown <iters> <seed>`: focused lifecycle repro
    // for module Worker termination while a shared-realm top-level failure
    // tears down parked Threads, pending asyncJoin reactions, and cleanup jobs.
    if (first) |a| if (std.mem.eql(u8, a, "moduletermteardown")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mtfail: usize = 0;
        var mti: usize = 0;
        while (mti < iters) : (mti += 1) {
            const seed = base_seed +% mti;
            if (!(try runModuleWorkerTerminateThreadTeardownInterleaving(gpa, seed))) mtfail += 1;
        }
        std.debug.print("threadfuzz moduletermteardown: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mtfail });
        if (mtfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgcterm <iters> <seed>`: focused mid-script parallel-GC
    // repro for teardown termination while asyncJoin reactions and child-owned
    // typed-array waitAsync tickets are still pending.
    if (first) |a| if (std.mem.eql(u8, a, "midgcterm")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mtfail: usize = 0;
        var mti: usize = 0;
        while (mti < iters) : (mti += 1) {
            const seed = base_seed +% mti;
            if (!(try runMidScriptTerminationReactionGc(gpa, seed))) mtfail += 1;
        }
        std.debug.print("threadfuzz midgcterm: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mtfail });
        if (mtfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgcsync <iters> <seed>`: focused mid-script parallel-GC
    // repro for parked property waits, Condition waits, and contended Lock
    // waiters keeping stack roots alive while cleanup records are collected.
    if (first) |a| if (std.mem.eql(u8, a, "midgcsync")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var msfail: usize = 0;
        var msi: usize = 0;
        while (msi < iters) : (msi += 1) {
            const seed = base_seed +% msi;
            if (!(try runMidScriptSyncWaitCleanupGc(gpa, seed))) msfail += 1;
        }
        std.debug.print("threadfuzz midgcsync: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, msfail });
        if (msfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgcpromise <iters> <seed>`: focused mid-script
    // parallel-GC repro for child-returned waitAsync/rejected-promise/user-
    // thenable assimilation and thrown-object publication through thread
    // completion records.
    if (first) |a| if (std.mem.eql(u8, a, "midgcpromise")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mpfail: usize = 0;
        var mpi: usize = 0;
        while (mpi < iters) : (mpi += 1) {
            const seed = base_seed +% mpi;
            if (!(try runMidScriptPromisePublicationGc(gpa, seed))) mpfail += 1;
        }
        std.debug.print("threadfuzz midgcpromise: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mpfail });
        if (mpfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgcmicrotask <iters> <seed>`: focused mid-script
    // parallel-GC repro for pending Promise, waitAsync, asyncJoin, asyncHold
    // callback/release, and cleanup roots that all settle after a finishing
    // sweep.
    if (first) |a| if (std.mem.eql(u8, a, "midgcmicrotask")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mmfail: usize = 0;
        var mmi: usize = 0;
        while (mmi < iters) : (mmi += 1) {
            const seed = base_seed +% mmi;
            if (!(try runMidScriptMicrotaskChurnGc(gpa, seed))) mmfail += 1;
        }
        std.debug.print("threadfuzz midgcmicrotask: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mmfail });
        if (mmfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgccreatorbuffers <iters> <seed>`: focused mid-script
    // parallel-GC repro for child-created SAB/ArrayBuffer storage rooted
    // through unjoined Thread completion records and delayed asyncJoin
    // observers across a finishing sweep.
    if (first) |a| if (std.mem.eql(u8, a, "midgccreatorbuffers")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mcbfail: usize = 0;
        var mcbi: usize = 0;
        while (mcbi < iters) : (mcbi += 1) {
            const seed = base_seed +% mcbi;
            if (!(try runMidScriptCreatorOwnedBufferGc(gpa, seed))) mcbfail += 1;
        }
        std.debug.print("threadfuzz midgccreatorbuffers: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mcbfail });
        if (mcbfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgcworker <iters> <seed>`: focused mid-script
    // parallel-GC repro for isolated Workers running on a retained SAB while
    // shared-realm Threads publish cleanup roots through a finishing sweep.
    if (first) |a| if (std.mem.eql(u8, a, "midgcworker")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mwfail: usize = 0;
        var mwi: usize = 0;
        while (mwi < iters) : (mwi += 1) {
            const seed = base_seed +% mwi;
            if (!(try runMidScriptWorkerCleanupGc(gpa, seed))) mwfail += 1;
        }
        std.debug.print("threadfuzz midgcworker: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mwfail });
        if (mwfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgcweak <iters> <seed>`: focused mid-script parallel-GC
    // repro for WeakMap/WeakSet dead-key pruning, live ephemeron values, and
    // FinalizationRegistry unregister compaction while sync peers are parked.
    if (first) |a| if (std.mem.eql(u8, a, "midgcweak")) {
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch 1;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mwcfail: usize = 0;
        var mwci: usize = 0;
        while (mwci < iters) : (mwci += 1) {
            const seed = base_seed +% mwci;
            if (!(try runMidScriptWeakCollectionGc(gpa, seed))) mwcfail += 1;
        }
        std.debug.print("threadfuzz midgcweak: {d} programs from seed {d}, {d} failures\n", .{ iters, base_seed, mwcfail });
        if (mwcfail != 0) std.process.exit(1);
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
    // Worker/thread/finalization scheduling plus Worker termination interleaved
    // with finalization cleanup on a retained SAB, Worker termination while
    // shared-realm top-level failure tears down parked Threads, pending
    // asyncJoin reactions, and cleanup jobs, Worker handler exception recovery
    // while shared-realm Threads register finalization cleanup records on the
    // same retained SAB,
    // Thread exception identity and returned waitAsync promise assimilation
    // across join/asyncJoin while waiters are parked, cross-thread
    // FinalizationRegistry cleanup, FinalizationRegistry cleanup interleaved
    // with join/asyncJoin and unregister tokens, cleanup
    // delivery after parked property/condition waiters resume, typed-array
    // waitAsync settlement interleaved with asyncJoin and finalization cleanup,
    // Promise reaction queue churn from asyncHold, waitAsync, asyncJoin, and
    // finalization cleanup,
    // creator-owned SAB/ArrayBuffer storage crossing isolated Worker
    // structured-clone after creator Thread exit,
    // teardown termination with pending asyncJoin reactions and child-owned
    // typed-array waitAsync tickets, teardown termination with property
    // waitAsync timeouts, async condition reacquire, asyncJoin rejection, and
    // cleanup jobs pending together,
    // ThreadLocal-stored FinalizationRegistry records across park/resume/cleanup,
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
    // counter plus exact cleanup delivery, terminating spinning Workers must
    // not disturb exact shared-realm finalization cleanup on the retained SAB
    // or top-level-failure Thread teardown with pending asyncJoin cleanup,
    // worker handler exception recovery must compose with exact shared-realm
    // cleanup delivery on the retained SAB,
    // thread exceptions must keep identity
    // through blocking and async joiners,
    // thread-returned waitAsync promises must settle through join/asyncJoin
    // while waiters resume cleanly, cleanup delivery must match exact count/sum
    // oracles when thread results are observed through both join paths, when
    // unregister tokens suppress some records, after parked property and
    // condition waiters resume, and while typed-array waitAsync promise
    // reactions and asyncJoin reactions settle together, while asyncHold
    // callback and release-function reactions churn the same queue, when
    // child-created SAB/ArrayBuffer storage outlives its creator Thread and is
    // read/transferred under GC pressure and crosses isolated Worker
    // structured-clone after creator exit, plus when teardown
    // termination rejects pending asyncJoin reactions and abandons child-owned
    // typed-array waitAsync tickets, and when teardown termination overlaps
    // property waitAsync timeout compaction, async condition reacquire,
    // asyncJoin rejection, and pending cleanup jobs; asyncHold barging must
    // deliver a pending
    // no-fn grant after a sync hold legally overtakes it; ThreadLocal values must stay
    // per-thread across normal, throwing, nested, async-joined, and
    // finalization-cleanup lifecycles; module Worker termination must compose
    // with the same shared-realm teardown/reaction/cleanup oracle.
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
            if (!(try runWorkerTerminateFinalizationInterleaving(gpa, seed))) lfail += 1;
            if (!(try runWorkerTerminateThreadTeardownInterleaving(gpa, seed))) lfail += 1;
            if (!(try runModuleWorkerTerminateThreadTeardownInterleaving(gpa, seed))) lfail += 1;
            if (!(try runWorkerExceptionFinalizationCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadExceptionWaiterInterleaving(gpa, seed))) lfail += 1;
            if (!(try runReturnedWaitAsyncLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationAsyncJoinCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationWaiterCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runWaitAsyncFinalizationCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runMicrotaskChurnLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runCreatorOwnedBufferLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runWorkerCreatorOwnedBufferLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runTerminationPendingReactionInterleaving(gpa, seed))) lfail += 1;
            if (!(try runTerminationWaiterCleanupInterleaving(gpa, seed))) lfail += 1;
            if (!(try runAsyncHoldBargingLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadRestrictLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadLocalLifecycleInterleaving(gpa, seed))) lfail += 1;
            if (!(try runThreadLocalFinalizationCleanupInterleaving(gpa, seed))) lfail += 1;
        }
        std.debug.print("threadfuzz lifecycle: {d} programs from seed {d}, {d} failures\n", .{ iters * 27, base_seed, lfail });
        if (lfail != 0) std.process.exit(1);
        return;
    };
    // `threadfuzz midgc <iters> <seed>`: targeted mid-script parallel-GC
    // profile. Each seed blocks peers in property `Atomics.wait`,
    // `Condition.wait`, and contended `Lock` acquisition while allocation
    // pressure triggers the experimental collector. Hidden ThreadLocal values,
    // typed-array waitAsync reactions, rejected asyncHold reactions, pending
    // asyncJoin reactions, child-returned waitAsync/rejected-promise/user-
    // thenable assimilation, pending Promise/microtask reaction roots across
    // asyncHold, waitAsync, asyncJoin, and cleanup delivery,
    // child-created SAB/ArrayBuffer storage rooted through unjoined Thread
    // completion records and delayed asyncJoin observers,
    // completed-but-unjoined Thread results and thrown
    // objects, sync-wait peer stack roots with finalization cleanup, WeakMap/
    // WeakSet dead-key cleanup with live ephemeron values and unregister-token
    // suppression, isolated Worker/SAB progress while shared-realm cleanup roots are swept, and
    // teardown termination with pending asyncJoin/waitAsync roots must survive
    // that window. The oracle requires exact program completion or expected
    // termination and at least one finishing parallel sweep.
    if (first) |a| if (std.mem.eql(u8, a, "midgc")) {
        iters = 20;
        if (args.next()) |b| iters = std.fmt.parseInt(usize, b, 10) catch iters;
        if (args.next()) |b| base_seed = std.fmt.parseInt(u64, b, 10) catch 1;
        var mfail: usize = 0;
        var mi: usize = 0;
        while (mi < iters) : (mi += 1) {
            const seed = base_seed +% mi;
            if (!(try runMidScriptWaitPumpGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptTerminationReactionGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptPromisePublicationGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptMicrotaskChurnGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptCreatorOwnedBufferGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptSyncWaitCleanupGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptWorkerCleanupGc(gpa, seed))) mfail += 1;
            if (!(try runMidScriptWeakCollectionGc(gpa, seed))) mfail += 1;
        }
        std.debug.print("threadfuzz midgc: {d} programs from seed {d}, {d} failures\n", .{ iters * 8, base_seed, mfail });
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
