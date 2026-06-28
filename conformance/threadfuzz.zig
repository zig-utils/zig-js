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
