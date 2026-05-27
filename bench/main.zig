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

    var machine = js.Interpreter{ .arena = a, .env = &ctx.env };
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < case.iters) : (i += 1) {
        _ = try js.vm.run(&machine, chunk);
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

    var machine = js.Interpreter{ .arena = a, .env = &ctx.env };
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < case.iters) : (i += 1) {
        _ = try machine.eval(prog);
    }
    return @intCast(nowNs(io) - t0);
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
}
