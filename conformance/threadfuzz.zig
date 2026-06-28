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
    return switch (r.uintLessThan(u8, 14)) {
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
        else => "acc += sArr.length; ", // length read
    };
}

/// Generation knobs. The amplified profile raises thread count + loop length and
/// adds extra shared closures (the upvalue surface the first bug lived in), so
/// rare interleavings the default profile misses get many more chances to race.
const Cfg = struct {
    min_workers: usize,
    worker_span: usize, // workers = min_workers + rand(worker_span)
    loop_iters: usize,
    pub const default: Cfg = .{ .min_workers = 2, .worker_span = 5, .loop_iters = 1200 };
    pub const amplified: Cfg = .{ .min_workers = 6, .worker_span = 9, .loop_iters = 5000 };
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
        try buf.appendSlice(gpa, "} return acc; }\n");
    }
    try buf.appendSlice(gpa, "var ts = [];\n");
    w = 0;
    while (w < nworkers) : (w += 1) {
        const sp = try std.fmt.allocPrint(gpa, "ts.push(new Thread(w{d}));\n", .{w});
        defer gpa.free(sp);
        try buf.appendSlice(gpa, sp);
    }
    try buf.appendSlice(gpa, "var total = 0; for (const t of ts) total += t.join();\n(total | 0)\n");
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
        if (ctx.evaluate(src)) |_| {
            std.debug.print("ok: {s} completed\n", .{path});
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
    // `threadfuzz amplify <iters> <seed>`: high-contention profile (more threads,
    // longer loops) — the stress-amplification mode for surfacing rare races.
    var cfg = Cfg.default;
    var rest = first;
    if (first) |a| if (std.mem.eql(u8, a, "amplify")) {
        cfg = Cfg.amplified;
        iters = 60; // amplified programs are heavier; fewer per run
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
        const ctx = js.Context.createWith(gpa, .{ .enable_threads = true }) catch {
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
