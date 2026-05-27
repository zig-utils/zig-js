//! zig-js conformance runner (test262-style).
//!
//! Runs a curated suite of `.js` snippets through the engine, injecting native
//! `assert(cond[, msg])` / `assertEq(actual, expected)` builtins, and reports a
//! pass percentage. This is the conformance gate the engine grows against.
//!
//! Today the suite is engine-native (assertion-based) because real test262 files
//! lean on `throw` / `Test262Error` / object member access, which are the next
//! milestones. Once those land, this runner ingests
//! `~/Code/WebKit/JSTests/test262` directly: prepend `harness/{sta,assert}.js`,
//! evaluate, and pass when no exception (or the expected one for negatives).

const std = @import("std");
const js = @import("js");

const Value = js.Value;

// Single-threaded harness state, reset before each case.
var failed: bool = false;
var fail_msg: []const u8 = "";

fn jsAssert(args: []const Value) Value {
    if (args.len < 1 or !args[0].toBoolean()) {
        failed = true;
        fail_msg = if (args.len >= 2 and args[1] == .string) args[1].string else "assertion failed";
    }
    return .undefined;
}

fn jsAssertEq(args: []const Value) Value {
    const ok = args.len >= 2 and js.strictEquals(args[0], args[1]);
    if (!ok) {
        failed = true;
        fail_msg = "assertEq mismatch";
    }
    return .undefined;
}

const Case = struct { name: []const u8, src: []const u8 };

const cases = [_]Case{
    .{ .name = "arithmetic precedence", .src = "assert(1 + 2 * 3 === 7);" },
    .{ .name = "string concatenation", .src = "assert('a' + 'b' + 1 === 'ab1');" },
    .{ .name = "comparison + logical", .src = "assert(3 > 2 && 2 >= 2);" },
    .{ .name = "strict equality", .src = "assert(1 === 1 && 1 !== 2);" },
    .{ .name = "loose equality coercion", .src = "assert(1 == '1'); assert(!(1 == '2'));" },
    .{ .name = "typeof", .src = "assert(typeof 'x' === 'string'); assert(typeof 1 === 'number');" },
    .{ .name = "ternary", .src = "assertEq(true ? 10 : 20, 10);" },
    .{ .name = "unary ops", .src = "assert(-(-5) === 5); assert(!false);" },
    .{ .name = "exponentiation", .src = "assertEq(2 ** 10, 1024);" },
    .{ .name = "var + while loop", .src = "let x = 0; let i = 1; while (i <= 5) { x = x + i; i = i + 1; } assertEq(x, 15);" },
    .{ .name = "if / else", .src = "let v = 0; if (3 > 2) { v = 1; } else { v = 2; } assertEq(v, 1);" },
    .{ .name = "function declaration", .src = "function add(a, b) { return a + b; } assertEq(add(40, 2), 42);" },
    .{ .name = "recursion (factorial)", .src = "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } assertEq(fact(5), 120);" },
    .{ .name = "closures", .src = "function mk(x) { return function (y) { return x + y; }; } assertEq(mk(10)(5), 15);" },
    .{ .name = "arrow function", .src = "let sq = x => x * x; assertEq(sq(6), 36);" },
    .{ .name = "arrow IIFE", .src = "assertEq(((x) => x * x)(5), 25);" },
    .{ .name = "closure counter", .src = "function c() { let n = 0; return function () { n = n + 1; return n; }; } let f = c(); f(); f(); assertEq(f(), 3);" },
    .{ .name = "lexical scope", .src = "let a = 1; function outer() { let a = 2; function inner() { return a; } return inner(); } assertEq(outer(), 2);" },
};

fn defineNative(ctx: *js.Context, name: []const u8, f: js.NativeFn) !void {
    const obj = try ctx.arena().create(js.Object);
    obj.* = .{ .native = f };
    try ctx.env.put(name, .{ .object = obj });
}

fn runCase(case: Case) bool {
    failed = false;
    fail_msg = "";
    const ctx = js.Context.create(std.heap.page_allocator) catch return false;
    defer ctx.destroy();
    defineNative(ctx, "assert", jsAssert) catch return false;
    defineNative(ctx, "assertEq", jsAssertEq) catch return false;

    _ = ctx.evaluate(case.src) catch |err| {
        fail_msg = @errorName(err);
        return false;
    };
    return !failed;
}

pub fn main() void {
    var passed: usize = 0;
    std.debug.print("zig-js conformance suite\n========================\n", .{});
    for (cases) |case| {
        if (runCase(case)) {
            passed += 1;
            std.debug.print("  PASS  {s}\n", .{case.name});
        } else {
            std.debug.print("  FAIL  {s}  ({s})\n", .{ case.name, fail_msg });
        }
    }
    const total = cases.len;
    const pct = @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(total)) * 100.0;
    std.debug.print("------------------------\n{d}/{d} passed ({d:.1}%)\n", .{ passed, total, pct });
}
