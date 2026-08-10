//! Small semantic gates for frontend, VM, and concurrency development (#53,
//! #494).
//!
//! This is an executable rather than a Zig test root: importing `vm.zig`
//! through `zig test` recursively discovers the interpreter, Thread, Context,
//! and C-API integration tests. Executable builds use the exact production
//! `js` module without linking hundreds of unrelated test declarations.

const std = @import("std");
const js = @import("js");

const Case = struct {
    name: []const u8,
    source: []const u8,
    expected: f64,
};

const ErrorCase = struct {
    name: []const u8,
    source: []const u8,
};

const frontend_cases = [_]Case{
    .{
        .name = "operator precedence",
        .source = "1 + 2 * 3",
        .expected = 7,
    },
    .{
        .name = "automatic semicolon insertion",
        .source = "let x = 1\nx + 2",
        .expected = 3,
    },
    .{
        .name = "nested destructuring binding",
        .source = "let { a, b: { c } } = { a: 4, b: { c: 5 } }; a + c",
        .expected = 9,
    },
    .{
        .name = "template interpolation",
        .source = "let x = 3; `v${x}` === 'v3' ? 1 : 0",
        .expected = 1,
    },
    .{
        .name = "class private field",
        .source = "class C { #x = 7; get() { return this.#x; } } new C().get()",
        .expected = 7,
    },
    .{
        .name = "optional chain with nullish fallback",
        .source = "let o = null; (o?.x ?? 41) + 1",
        .expected = 42,
    },
    .{
        .name = "regexp literal",
        .source = "/a+/.test('aaa') ? 1 : 0",
        .expected = 1,
    },
};

const frontend_error_cases = [_]ErrorCase{
    .{
        .name = "duplicate lexical binding rejected",
        .source = "let x; let x;",
    },
    .{
        .name = "top-level new target rejected",
        .source = "new.target",
    },
    .{
        .name = "parenthesized destructuring target rejected",
        .source = "({ a }) = { a: 1 };",
    },
    .{
        .name = "undeclared private name rejected",
        .source = "class C { #x; read(o) { return o.#missing; } }",
    },
    .{
        .name = "malformed for-of head rejected",
        .source = "for (let x = 0 of []) {}",
    },
};

const vm_cases = [_]Case{
    .{
        .name = "numeric loop",
        .source = "let s = 0; for (let i = 0; i < 1000; i++) s += i % 17; s",
        .expected = 7979,
    },
    .{
        .name = "packed array loop",
        .source = "let a = [1, 2, 3, 4]; let s = 0; for (let i = 0; i < 2000; i++) s += a[i & 3]; s",
        .expected = 5000,
    },
    .{
        .name = "property loop",
        .source = "let o = { x: 1, y: 2 }; let s = 0; for (let i = 0; i < 1000; i++) { o.x++; s += o.y; } o.x + s",
        .expected = 3001,
    },
    .{
        .name = "recursive calls",
        .source = "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(12)",
        .expected = 144,
    },
};

const jit_cases = [_]Case{
    .{
        .name = "guarded remainder loop",
        .source = "function f(n) { let s = 0; for (let i = 0; i < n; i++) s += i % 17; return s; } f(1000)",
        .expected = 7979,
    },
    .{
        .name = "fractional guard fallback",
        .source = "function f(n) { let x = 0; for (let i = 0; i < n; i++) x++; return x; } f(1000) + f(2.5)",
        .expected = 1003,
    },
    .{
        .name = "constant function tier",
        .source = "function c() { return 42; } let s = 0; for (let i = 0; i < 1000; i++) s += c(); s",
        .expected = 42000,
    },
};

const runtime_cases = [_]Case{
    .{
        .name = "JSON hostile nesting is catchable",
        .source =
        \\function rejectsDepth(text) {
        \\  try { JSON.parse(text); return false; }
        \\  catch (error) { return error instanceof RangeError && error.message === "Maximum call stack size exceeded"; }
        \\}
        \\let shallow = "[".repeat(96) + "7" + "]".repeat(96);
        \\let value = JSON.parse(shallow);
        \\for (let i = 0; i < 96; i++) value = value[0];
        \\let revived = JSON.parse(shallow, function (key, child) { return child; });
        \\for (let i = 0; i < 96; i++) revived = revived[0];
        \\let syntax = false;
        \\try { JSON.parse("[1,"); } catch (error) { syntax = error instanceof SyntaxError; }
        \\let arrays = rejectsDepth("[".repeat(50000) + "0" + "]".repeat(50000));
        \\let objects = rejectsDepth("{\"v\":".repeat(50000) + "0" + "}".repeat(50000));
        \\let mixed = rejectsDepth("[{\"v\":".repeat(20000) + "0" + "}]".repeat(20000));
        \\let raw = false;
        \\try { JSON.rawJSON("[".repeat(50000) + "0" + "]".repeat(50000)); }
        \\catch (error) { raw = error instanceof RangeError && error.message === "Maximum call stack size exceeded"; }
        \\value === 7 && revived === 7 && syntax && arrays && objects && mixed && raw ? 1 : 0
        ,
        .expected = 1,
    },
};

const concurrency_cases = [_]Case{
    .{
        .name = "atomic increments",
        .source =
        \\const sab = new SharedArrayBuffer(4);
        \\const v = new Int32Array(sab);
        \\const threads = [];
        \\for (let i = 0; i < 4; i++) threads.push(new Thread(view => {
        \\  for (let j = 0; j < 500; j++) Atomics.add(view, 0, 1);
        \\}, v));
        \\for (const thread of threads) thread.join();
        \\v[0]
        ,
        .expected = 2000,
    },
    .{
        .name = "distinct property publication",
        .source =
        \\const o = { a: 0, b: 0 };
        \\const a = new Thread(value => { value.a = 11; }, o);
        \\const b = new Thread(value => { value.b = 31; }, o);
        \\a.join(); b.join(); o.a + o.b
        ,
        .expected = 42,
    },
    .{
        .name = "join chain",
        .source =
        \\const a = new Thread(() => 1);
        \\const b = new Thread(() => a.join() + 1);
        \\const c = new Thread(() => b.join() + 1);
        \\c.join()
        ,
        .expected = 3,
    },
};

fn matchesFilter(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.mem.indexOf(u8, name, filter) != null;
}

fn evaluateNumber(gpa: std.mem.Allocator, case: Case, enable_jit: bool, enable_threads: bool) !f64 {
    const ctx = try js.Context.createWith(gpa, .{
        .enable_jit = enable_jit,
        .enable_threads = enable_threads,
    });
    defer ctx.destroy();
    const result = ctx.evaluate(case.source) catch |err| {
        std.debug.print("focused engine test '{s}' threw {s}\n", .{ case.name, @errorName(err) });
        return error.FocusedTestFailed;
    };
    if (!result.isNumber()) {
        std.debug.print("focused engine test '{s}' returned a non-number\n", .{case.name});
        return error.FocusedTestFailed;
    }
    return result.asNum();
}

fn expectCase(gpa: std.mem.Allocator, case: Case, enable_jit: bool, enable_threads: bool) !void {
    const actual = try evaluateNumber(gpa, case, enable_jit, enable_threads);
    if (actual != case.expected) {
        std.debug.print("focused engine test '{s}': got {d}, expected {d}\n", .{ case.name, actual, case.expected });
        return error.FocusedTestFailed;
    }
}

fn runCases(gpa: std.mem.Allocator, cases: []const Case, filter: []const u8, enable_jit: bool, enable_threads: bool) !usize {
    var ran: usize = 0;
    for (cases) |case| {
        if (!matchesFilter(case.name, filter)) continue;
        try expectCase(gpa, case, enable_jit, enable_threads);
        ran += 1;
    }
    return ran;
}

fn runErrorCases(gpa: std.mem.Allocator, cases: []const ErrorCase, filter: []const u8) !usize {
    var ran: usize = 0;
    for (cases) |case| {
        if (!matchesFilter(case.name, filter)) continue;
        const ctx = try js.Context.create(gpa);
        defer ctx.destroy();
        if (ctx.evaluate(case.source)) |_| {
            std.debug.print("focused frontend test '{s}' unexpectedly parsed\n", .{case.name});
            return error.FocusedTestFailed;
        } else |_| {}
        ran += 1;
    }
    return ran;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const suite = args.next() orelse return error.MissingSuite;
    const filter = args.next() orelse "";
    const gpa = std.heap.page_allocator;

    const ran = if (std.mem.eql(u8, suite, "frontend")) blk: {
        const valid = try runCases(gpa, &frontend_cases, filter, false, false);
        const invalid = try runErrorCases(gpa, &frontend_error_cases, filter);
        break :blk valid + invalid;
    } else if (std.mem.eql(u8, suite, "vm"))
        try runCases(gpa, &vm_cases, filter, false, false)
    else if (std.mem.eql(u8, suite, "runtime"))
        try runCases(gpa, &runtime_cases, filter, false, false)
    else if (std.mem.eql(u8, suite, "jit")) blk: {
        const interpreted = try runCases(gpa, &jit_cases, filter, false, false);
        const native = try runCases(gpa, &jit_cases, filter, true, false);
        if (interpreted != native) return error.FocusedTestFailed;
        break :blk native;
    } else if (std.mem.eql(u8, suite, "concurrency"))
        try runCases(gpa, &concurrency_cases, filter, true, true)
    else
        return error.UnknownSuite;

    if (ran == 0) {
        std.debug.print("focused engine suite '{s}' matched no cases for filter '{s}'\n", .{ suite, filter });
        return error.NoMatchingCases;
    }
    std.debug.print("focused engine {s}: {d} case{s} passed\n", .{ suite, ran, if (ran == 1) "" else "s" });
}
