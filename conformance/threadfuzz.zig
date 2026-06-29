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
        replies += 1;
    }
    if (replies < extra_pings + 1) {
        std.debug.print("seed {d}: graceful worker lost queued replies ({d} < {d})\n", .{ seed, replies, extra_pings + 1 });
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
    terminator.destroy();
    cleanup_terminator = false;
    graceful.join();
    graceful.destroy();
    cleanup_graceful = false;

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

fn runMidScriptWaitPumpGc(gpa: std.mem.Allocator, seed: u64) !bool {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6d69_6467_635f_7761);
    const r = prng.random();
    const rounds = 8 + r.uintLessThan(usize, 8);
    const per_round = 650 + r.uintLessThan(usize, 500);
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
        \\  const gate = {{ state: 0, propReady: 0, condReady: 0, holderReady: 0, lockReady: 0, releaseLock: 0, lockDone: 0 }};
        \\  const condLock = new Lock();
        \\  const cond = new Condition();
        \\  const heldLock = new Lock();
        \\  globalThis.__midgcCleanupCount = 0;
        \\  globalThis.__midgcCleanupSum = 0;
        \\  globalThis.__midgcRegistry = (typeof FinalizationRegistry === 'function')
        \\    ? new FinalizationRegistry(function(held) {{
        \\        globalThis.__midgcCleanupCount = globalThis.__midgcCleanupCount + 1;
        \\        globalThis.__midgcCleanupSum = globalThis.__midgcCleanupSum + held;
        \\      }})
        \\    : null;
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
        \\    heldLock.hold(() => {{ Atomics.store(gate, 'lockDone', 1); }});
        \\    return 1;
        \\  }});
        \\  while (Atomics.load(gate, 'propReady') === 0)
        \\    Atomics.wait(gate, 'propReady', 0, 1);
        \\  while (Atomics.load(gate, 'condReady') === 0)
        \\    Atomics.wait(gate, 'condReady', 0, 1);
        \\  while (Atomics.load(gate, 'lockReady') === 0)
        \\    Atomics.wait(gate, 'lockReady', 0, 1);
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
        \\  condLock.hold(() => {{
        \\    Atomics.store(gate, 'state', 1);
        \\    Atomics.notify(gate, 'state');
        \\    cond.notifyAll();
        \\  }});
        \\  Atomics.store(gate, 'releaseLock', 1);
        \\  Atomics.notify(gate, 'releaseLock');
        \\  const wr = propWaiter.join();
        \\  if (wr !== 'ok' && wr !== 'timed-out') throw new Error('bad property wait result: ' + wr);
        \\  if (condWaiter.join() !== 1) throw new Error('bad condition waiter');
        \\  if (holder.join() !== 1) throw new Error('bad lock holder');
        \\  if (lockWaiter.join() !== 1 || Atomics.load(gate, 'lockDone') !== 1) throw new Error('bad lock waiter');
        \\  return keep.length;
        \\}})();
        \\
    ,
        .{ wait_timeout_ms, wait_timeout_ms, rounds, per_round, per_round, spin_iters },
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
    // Worker/thread SAB overlap, module-worker/thread overlap, mixed
    // close/terminate/postMessage ordering, worker handler exception recovery,
    // Thread exception identity across join/asyncJoin while waiters are parked,
    // and cross-thread FinalizationRegistry cleanup. The oracle is not "no
    // throw":
    // termination storms must throw from the main script and still tear down
    // cleanly, overlap must produce exact synchronized counter values, and
    // close/terminate races must drain/drop messages according to channel
    // lifetime rules, thrown worker handlers must not poison later deliveries,
    // thread exceptions must keep identity through blocking and async joiners
    // while waiters resume cleanly, and cleanup delivery must match exact
    // count/sum oracles.
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
            if (!(try runWorkerCloseTerminateRace(gpa, seed))) lfail += 1;
            if (!(try runWorkerExceptionRecovery(gpa, seed))) lfail += 1;
            if (!(try runThreadExceptionWaiterInterleaving(gpa, seed))) lfail += 1;
            if (!(try runFinalizationCleanupInterleaving(gpa, seed))) lfail += 1;
        }
        std.debug.print("threadfuzz lifecycle: {d} programs from seed {d}, {d} failures\n", .{ iters * 7, base_seed, lfail });
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
