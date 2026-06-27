//! zig-js micro-benchmarks: bytecode VM vs tree-walk interpreter.
//!
//! Each case parses a setup snippet once (defining the functions under test),
//! then times N iterations of a "hot" snippet run two ways against the *same*
//! environment: compiled-and-run-on-the-VM versus walked by the interpreter.
//! It prints ns/op for each and the VM's speedup, so every future perf tier
//! (slots, NaN-boxing, shapes, JIT) can be measured against this baseline.
//!
//! `zig build bench`.

const std = @import("std");
const js = @import("js");

const Case = struct {
    name: []const u8,
    setup: []const u8,
    hot: []const u8,
    iters: usize,
};

const cases = [_]Case{
    .{
        .name = "fib(27) recursion",
        .setup = "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }",
        .hot = "fib(27)",
        .iters = 50,
    },
    .{
        .name = "tight loop sum to 100k",
        .setup = "function loop(n) { let s = 0; for (let i = 0; i < n; i = i + 1) { s = s + i; } return s; }",
        .hot = "loop(100000)",
        .iters = 200,
    },
    .{
        .name = "object property churn",
        .setup = "function work(n) { let o = { a: 0, b: 0 }; for (let i = 0; i < n; i = i + 1) { o.a = o.a + i; o.b = o.b + 1; } return o.a + o.b; }",
        .hot = "work(50000)",
        .iters = 200,
    },
    .{
        .name = "array push/sum",
        .setup = "function arr(n) { let xs = []; for (let i = 0; i < n; i = i + 1) { xs.push(i); } let s = 0; for (let j = 0; j < xs.length; j = j + 1) { s = s + xs[j]; } return s; }",
        .hot = "arr(20000)",
        .iters = 200,
    },
    .{
        // Linear recursion to depth ~500 — well past `stack_check_floor` (32),
        // so every call beyond the floor exercises the interpreter's
        // native-stack-pointer guard. This is the case that would surface any
        // serial-perf cost of the overflow guard the shallow benchmarks miss.
        .name = "deep recursion (depth 500)",
        .setup = "function deep(n) { return n <= 0 ? 0 : n + deep(n - 1); }",
        .hot = "deep(500)",
        .iters = 200,
    },
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

/// Time N iterations of `case.hot` executed on the VM, with `setup` run once.
fn timeVM(gpa: std.mem.Allocator, io: std.Io, case: Case) !u64 {
    const ctx = try js.Context.create(gpa);
    defer ctx.destroy();
    _ = try ctx.evaluate(case.setup);

    const a = ctx.arena();
    var parser = try js.Parser.init(a, case.hot);
    const prog = try parser.parseProgram();
    const chunk = try js.Compiler.compileProgram(a, prog);

    var machine = ctx.interpreter();
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < case.iters) : (i += 1) {
        _ = try js.vm.run(&machine, chunk, null);
    }
    return @intCast(nowNs(io) - t0);
}

/// Time N iterations of `case.hot` walked by the interpreter, `setup` run once.
fn timeTreeWalk(gpa: std.mem.Allocator, io: std.Io, case: Case) !u64 {
    const ctx = try js.Context.create(gpa);
    defer ctx.destroy();
    _ = try ctx.evaluate(case.setup);

    const a = ctx.arena();
    var parser = try js.Parser.init(a, case.hot);
    const prog = try parser.parseProgram();

    var machine = ctx.interpreter();
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < case.iters) : (i += 1) {
        _ = try machine.eval(prog);
    }
    return @intCast(nowNs(io) - t0);
}

/// Parallel throughput scaling: N JS `Thread`s each run an independent, shared-
/// state-free compute loop in one GIL-free context. If GIL removal delivers real
/// parallelism, wall-clock stays ~flat as N grows (up to core count), so the
/// scaling factor (throughput(N)/throughput(1)) approaches N. Under a GIL it
/// would stay ~1.0.
fn benchParallel(gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true }); // parallel by default
    defer ctx.destroy();
    _ = try ctx.evaluate(
        // `var` (function-scoped) avoids a fresh per-iteration `let` binding —
        // which under the GC-managed parallel engine is a GC cell per iteration,
        // pathologically slow until the GC gets a tight-loop alloc fast path
        // (tracked as remaining GC-maturity work). This loop is pure arithmetic,
        // so it isolates parallel *compute* scaling.
        \\globalThis.work = function(){ var s = 0; for (var i = 0; i < 2000000; i++) s = (s + i) % 1000003; return s; };
        \\globalThis.spawn = function(n){ let ts = []; for (let i = 0; i < n; i++) ts.push(new Thread(work)); let r = 0; for (const t of ts) r += t.join(); return r; };
    );
    const cores = std.Thread.getCpuCount() catch 4;
    std.debug.print("\nparallel throughput scaling — {d} cores, each thread a 4M-iter loop (no shared state)\n", .{cores});
    std.debug.print("{s:>8} {s:>14} {s:>10}\n", .{ "threads", "wall ns", "scaling" });
    var base: u64 = 1;
    for ([_]usize{ 1, 2, 4, 8 }) |n| {
        if (n > cores * 2) break;
        const src = try std.fmt.allocPrint(ctx.arena(), "spawn({d})", .{n});
        _ = try ctx.evaluate(src); // warm up (thread pool, JIT-of-bytecode, caches)
        const t0 = nowNs(io);
        _ = try ctx.evaluate(src);
        const dt: u64 = @intCast(nowNs(io) - t0);
        if (n == 1) base = @max(dt, 1);
        const scaling = @as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(base)) / @as(f64, @floatFromInt(@max(dt, 1)));
        std.debug.print("{d:>8} {d:>14} {d:>9.2}x\n", .{ n, dt, scaling });
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("zig-js benchmarks — bytecode VM vs tree-walk\n", .{});
    std.debug.print("============================================\n", .{});
    std.debug.print("{s:<28} {s:>12} {s:>12} {s:>9}\n", .{ "case", "vm ns/op", "tree ns/op", "speedup" });

    for (cases) |case| {
        const vm_ns = try timeVM(gpa, io, case);
        const tw_ns = try timeTreeWalk(gpa, io, case);
        const vm_per = vm_ns / case.iters;
        const tw_per = tw_ns / case.iters;
        const speedup = @as(f64, @floatFromInt(tw_per)) / @as(f64, @floatFromInt(@max(vm_per, 1)));
        std.debug.print("{s:<28} {d:>12} {d:>12} {d:>8.2}x\n", .{ case.name, vm_per, tw_per, speedup });
    }

    try benchParallel(gpa, io);
}
