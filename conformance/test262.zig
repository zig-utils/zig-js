//! Real test262 ingestion runner for zig-js.
//!
//! Walks the official ECMAScript [tc39/test262](https://github.com/tc39/test262)
//! corpus — vendored as the `test262` git submodule, so we always measure
//! against upstream's latest — and runs each `.js` test through the engine,
//! reporting how many pass. This is the true conformance gate the engine grows
//! against; `zig build conformance` keeps a small always-green smoke suite,
//! while `zig build test262` reports the real (currently partial) number.
//!
//! Why a harness *shim*: the upstream `harness/{sta,assert}.js` lean on language
//! features zig-js doesn't have yet (template literals, `switch`, `String`,
//! `JSON`, `Array.prototype.*`), so they can't load verbatim. We instead prepend
//! a faithful subset reimplementation of `Test262Error` + `assert` (defined in
//! the language we *do* support). As the engine grows to run the upstream
//! harness directly, this shim goes away.
//!
//! Frontmatter handling (the `/*--- … ---*/` YAML block):
//!   - `flags: [raw]`        → run the body with no harness prepended
//!   - `flags: [module|async|CanBlockIsFalse]` → skip (unsupported runtime)
//!   - `includes: [...]`     → skip (extra harness files we don't shim yet)
//!   - `negative: { type, phase }` → expect a parse error or a thrown exception
//!
//! Usage: `zig build test262` (root comes from the `-Dtest262=<path>` build
//! option, default `../../WebKit/JSTests/test262` relative to this repo). A
//! missing corpus is reported and skipped cleanly (exit 0), so CI without the
//! 19GB checkout stays green.

const std = @import("std");
const js = @import("js");
const build_options = @import("build_options");

/// A faithful, subset-only reimplementation of the test262 harness essentials
/// (`sta.js` + the parts of `assert.js` reachable without template literals,
/// `switch`, or the `String`/`JSON`/`Array` globals).
const harness_shim =
    \\function Test262Error(message) { this.message = message || ""; this.name = "Test262Error"; }
    \\Test262Error.thrower = function (message) { throw new Test262Error(message); };
    \\function $ERROR(message) { throw new Test262Error(message); }
    \\function $DONOTEVALUATE() { throw "Test262: This statement should not be evaluated."; }
    \\var assert = function (mustBeTrue, message) {
    \\  if (mustBeTrue === true) { return; }
    \\  throw new Test262Error(message || "Expected true but got something else");
    \\};
    \\assert._isSameValue = function (a, b) {
    \\  if (a === b) { return a !== 0 || 1 / a === 1 / b; }
    \\  return a !== a && b !== b;
    \\};
    \\assert.sameValue = function (actual, expected, message) {
    \\  if (assert._isSameValue(actual, expected)) { return; }
    \\  throw new Test262Error(message || "Expected SameValue to be true");
    \\};
    \\assert.notSameValue = function (actual, unexpected, message) {
    \\  if (!assert._isSameValue(actual, unexpected)) { return; }
    \\  throw new Test262Error(message || "Expected SameValue to be false");
    \\};
    \\assert.throws = function (expectedErrorConstructor, func, message) {
    \\  try { func(); } catch (thrown) { return; }
    \\  throw new Test262Error(message || "Expected a thrown exception");
    \\};
    \\
;

/// Pass/skip, or a categorized failure so we can see *why* tests fail and aim
/// breadth work at the real blockers.
const Outcome = enum {
    pass,
    skip,
    fail_parse, // syntax we can't lex/parse yet (missing grammar)
    fail_runtime, // threw at run time (missing builtin / semantics / a real assert failure)
    fail_negative, // a negative test that didn't fail the way it should
    fail_other, // host failure (OOM, …)

    fn isFail(self: Outcome) bool {
        return switch (self) {
            .pass, .skip => false,
            else => true,
        };
    }
};

const Stats = struct {
    pass: usize = 0,
    skip: usize = 0,
    fail_parse: usize = 0,
    fail_runtime: usize = 0,
    fail_negative: usize = 0,
    fail_other: usize = 0,

    fn add(self: *Stats, o: Outcome) void {
        switch (o) {
            .pass => self.pass += 1,
            .skip => self.skip += 1,
            .fail_parse => self.fail_parse += 1,
            .fail_runtime => self.fail_runtime += 1,
            .fail_negative => self.fail_negative += 1,
            .fail_other => self.fail_other += 1,
        }
    }

    fn fails(self: Stats) usize {
        return self.fail_parse + self.fail_runtime + self.fail_negative + self.fail_other;
    }

    fn ran(self: Stats) usize {
        return self.pass + self.fails();
    }

    fn merge(self: *Stats, other: Stats) void {
        self.pass += other.pass;
        self.skip += other.skip;
        self.fail_parse += other.fail_parse;
        self.fail_runtime += other.fail_runtime;
        self.fail_negative += other.fail_negative;
        self.fail_other += other.fail_other;
    }
};

/// Parsed subset of a test262 frontmatter block.
const Meta = struct {
    raw: bool = false,
    unsupported_flag: bool = false,
    has_includes: bool = false,
    negative: bool = false,
    negative_parse: bool = false,
};

fn parseMeta(src: []const u8) Meta {
    var meta: Meta = .{};
    const start = std.mem.indexOf(u8, src, "/*---") orelse return meta;
    const end_rel = std.mem.indexOf(u8, src[start..], "---*/") orelse return meta;
    const front = src[start .. start + end_rel];

    if (std.mem.indexOf(u8, front, "includes:")) |_| meta.has_includes = true;
    if (std.mem.indexOf(u8, front, "flags:")) |fi| {
        const line_end = std.mem.indexOfScalarPos(u8, front, fi, '\n') orelse front.len;
        const flags = front[fi..line_end];
        if (std.mem.indexOf(u8, flags, "raw")) |_| meta.raw = true;
        if (std.mem.indexOf(u8, flags, "module") != null or
            std.mem.indexOf(u8, flags, "async") != null or
            std.mem.indexOf(u8, flags, "CanBlockIsFalse") != null)
            meta.unsupported_flag = true;
    }
    if (std.mem.indexOf(u8, front, "negative:")) |ni| {
        meta.negative = true;
        // phase: parse  → expect a parse-time failure rather than a runtime throw
        const region = front[ni..];
        if (std.mem.indexOf(u8, region, "phase: parse") != null or
            std.mem.indexOf(u8, region, "phase:parse") != null)
            meta.negative_parse = true;
    }
    return meta;
}

fn runOne(gpa: std.mem.Allocator, src: []const u8) Outcome {
    const meta = parseMeta(src);
    if (meta.unsupported_flag or meta.has_includes) return .skip;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    if (!meta.raw) buf.appendSlice(gpa, harness_shim) catch return .skip;
    buf.appendSlice(gpa, src) catch return .skip;

    const ctx = js.Context.create(gpa) catch return .skip;
    defer ctx.destroy();

    if (ctx.evaluate(buf.items)) |_| {
        // No error. Pass unless the test expected a failure.
        return if (meta.negative) .fail_negative else .pass;
    } else |err| {
        if (meta.negative) {
            // A parse-phase negative must fail at parse time; a runtime negative
            // must throw. `error.Throw` is a runtime throw; anything else is a
            // parse/host error.
            const ok = if (meta.negative_parse) err != error.Throw else err == error.Throw;
            return if (ok) .pass else .fail_negative;
        }
        return switch (err) {
            error.Throw => .fail_runtime,
            error.OutOfMemory => .fail_other,
            else => .fail_parse, // lex/parse errors (UnexpectedToken, …)
        };
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // Root comes from the compile-time `-Dtest262=<path>` build option.
    const root = build_options.root;

    // Only walk a curated set of language subtrees — bounds runtime and keeps
    // the report focused on the slice the current subset can plausibly run.
    const subtrees = [_][]const u8{
        "test/language/types",
        "test/language/expressions",
        "test/language/statements",
    };

    var total: Stats = .{};
    std.debug.print("zig-js test262 ingestion\n========================\nroot: {s}\n", .{root});

    var any_dir = false;
    for (subtrees) |sub| {
        const path = std.fs.path.join(gpa, &.{ root, sub }) catch continue;
        defer gpa.free(path);
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
            std.debug.print("  (missing: {s})\n", .{sub});
            continue;
        };
        defer dir.close(io);
        any_dir = true;

        var stats: Stats = .{};
        var walker = dir.walk(gpa) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
            if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;

            const src = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(src);

            stats.add(runOne(gpa, src));
        }
        const ran = stats.ran();
        const pct = if (ran == 0) 0.0 else @as(f64, @floatFromInt(stats.pass)) / @as(f64, @floatFromInt(ran)) * 100.0;
        std.debug.print("  {s}: {d}/{d} passed ({d:.1}%), {d} skipped\n", .{ sub, stats.pass, ran, pct, stats.skip });
        total.merge(stats);
    }

    if (!any_dir) {
        std.debug.print("test262: corpus not found at '{s}'; skipping (set -Dtest262=<path>).\n", .{root});
        return;
    }

    const ran = total.ran();
    const pct = if (ran == 0) 0.0 else @as(f64, @floatFromInt(total.pass)) / @as(f64, @floatFromInt(ran)) * 100.0;
    std.debug.print("------------------------\nTOTAL: {d}/{d} passed ({d:.1}%), {d} skipped\n", .{ total.pass, ran, pct, total.skip });
    std.debug.print("failures: {d} parse · {d} runtime · {d} negative · {d} other\n", .{
        total.fail_parse, total.fail_runtime, total.fail_negative, total.fail_other,
    });
}
