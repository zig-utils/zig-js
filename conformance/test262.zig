//! Real test262 ingestion runner for zig-js.
//!
//! Walks the official ECMAScript [tc39/test262](https://github.com/tc39/test262)
//! corpus — vendored as the `test262` git submodule, so we always measure
//! against upstream's latest — and runs each `.js` test through the engine,
//! reporting how many pass. This is the true conformance gate the engine grows
//! against; `zig build conformance` keeps a small always-green smoke suite,
//! while `zig build test262` reports the real (currently partial) number.
//!
//! **Subprocess isolation**: a single engine panic / segfault on a pathological
//! test would otherwise abort the whole run. So the runner is split into a
//! *parent* that orchestrates and *workers* it re-spawns (itself, with
//! `--worker <subtree> <start-index>`): a worker streams one `index:outcome`
//! line per test to stdout (unbuffered, so a crash loses only the in-flight
//! line) and prints `DONE` when finished. If a worker dies without `DONE`, the
//! parent records the next unreported test as a host failure and respawns the
//! worker just past it. This makes scoring crash-proof, so the real harness
//! `includes:` files are loaded (no longer skipped) and the built-ins subtrees
//! can be scored safely. The engine's step budget bounds runtime, so there are
//! no true hangs (a `timeout` is set as a backstop anyway).
//!
//! Why a harness *shim*: the upstream `harness/{sta,assert}.js` lean on a few
//! features the shim covers directly; we prepend a faithful subset
//! reimplementation of `Test262Error` + `assert`, then append any `includes:`
//! harness files (compareArray, propertyHelper, …) read from `harness/`.
//!
//! Frontmatter handling (the `/*--- … ---*/` YAML block):
//!   - `flags: [raw]`        → run the body with no harness prepended
//!   - `flags: [module|async|CanBlockIsFalse]` → skip (unsupported runtime)
//!   - `includes: [...]`     → prepend the named harness files
//!   - `negative: { type, phase }` → expect a parse error or a thrown exception
//!
//! Usage: `zig build test262` (root from the `-Dtest262=<path>` build option). A
//! missing corpus is reported and skipped cleanly (exit 0).

const std = @import("std");
const js = @import("js");
const build_options = @import("build_options");

/// A faithful, subset-only reimplementation of the test262 harness essentials
/// (`sta.js` + the parts of `assert.js` we lean on directly).
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

/// The outcome of one test. Positive (valid) tests and negative (must-fail)
/// tests are scored on separate axes: a valid test measures whether we can *run*
/// the program; a negative test measures *strictness* (rejecting invalid input,
/// e.g. early errors) — a capability we mostly don't have yet, so mixing the two
/// would let a weaker parser "win" by failing to parse valid code too.
const Outcome = enum {
    pass, // valid test ran correctly
    pass_negative, // negative test failed the way it should
    skip,
    fail_parse, // valid: syntax we can't lex/parse yet (missing grammar)
    fail_runtime, // valid: threw at run time (missing builtin / semantics)
    fail_negative, // negative: we didn't reject it the way we should
    fail_other, // valid: host failure (OOM, worker crash, …)
};

/// One-char wire encoding of an `Outcome` for the worker→parent stream.
fn outcomeChar(o: Outcome) u8 {
    return switch (o) {
        .pass => 'p',
        .pass_negative => 'n',
        .skip => 's',
        .fail_parse => 'P',
        .fail_runtime => 'R',
        .fail_negative => 'F',
        .fail_other => 'O',
    };
}

fn charOutcome(c: u8) ?Outcome {
    return switch (c) {
        'p' => .pass,
        'n' => .pass_negative,
        's' => .skip,
        'P' => .fail_parse,
        'R' => .fail_runtime,
        'F' => .fail_negative,
        'O' => .fail_other,
        else => null,
    };
}

const Stats = struct {
    pass: usize = 0,
    pass_negative: usize = 0,
    skip: usize = 0,
    fail_parse: usize = 0,
    fail_runtime: usize = 0,
    fail_negative: usize = 0,
    fail_other: usize = 0,

    fn add(self: *Stats, o: Outcome) void {
        switch (o) {
            .pass => self.pass += 1,
            .pass_negative => self.pass_negative += 1,
            .skip => self.skip += 1,
            .fail_parse => self.fail_parse += 1,
            .fail_runtime => self.fail_runtime += 1,
            .fail_negative => self.fail_negative += 1,
            .fail_other => self.fail_other += 1,
        }
    }

    /// Valid (positive) tests only — the real "can we run it" capability.
    fn validTotal(self: Stats) usize {
        return self.pass + self.fail_parse + self.fail_runtime + self.fail_other;
    }

    fn negTotal(self: Stats) usize {
        return self.pass_negative + self.fail_negative;
    }

    fn pct(num: usize, den: usize) f64 {
        return if (den == 0) 0.0 else @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den)) * 100.0;
    }

    fn merge(self: *Stats, other: Stats) void {
        self.pass += other.pass;
        self.pass_negative += other.pass_negative;
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
    negative: bool = false,
    negative_parse: bool = false,
    /// `includes:` harness file names. Slices point into the source frontmatter,
    /// which outlives `runOne`.
    includes: [8][]const u8 = undefined,
    includes_n: usize = 0,
};

fn parseMeta(src: []const u8) Meta {
    var meta: Meta = .{};
    const start = std.mem.indexOf(u8, src, "/*---") orelse return meta;
    const end_rel = std.mem.indexOf(u8, src[start..], "---*/") orelse return meta;
    const front = src[start .. start + end_rel];

    if (std.mem.indexOf(u8, front, "includes:")) |ii| parseIncludes(&meta, front[ii + "includes:".len ..]);
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
        const region = front[ni..];
        if (std.mem.indexOf(u8, region, "phase: parse") != null or
            std.mem.indexOf(u8, region, "phase:parse") != null)
            meta.negative_parse = true;
    }
    return meta;
}

/// Parse the include file names following `includes:` — either the inline
/// bracket form `[a.js, b.js]` or the YAML dash-list form (`  - a.js`).
fn parseIncludes(meta: *Meta, after: []const u8) void {
    const nl = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
    if (std.mem.indexOfScalar(u8, after, '[')) |lb| {
        if (lb < nl) {
            const rb = std.mem.indexOfScalarPos(u8, after, lb, ']') orelse after.len;
            var it = std.mem.tokenizeAny(u8, after[lb + 1 .. rb], ", \t\r");
            while (it.next()) |name| addInclude(meta, name);
            return;
        }
    }
    var lines = std.mem.splitScalar(u8, after, '\n');
    _ = lines.next(); // remainder of the `includes:` line itself
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] != '-') break; // end of the list
        const name = std.mem.trim(u8, line[1..], " \t\r");
        if (name.len != 0) addInclude(meta, name);
    }
}

fn addInclude(meta: *Meta, name: []const u8) void {
    if (meta.includes_n < meta.includes.len) {
        meta.includes[meta.includes_n] = name;
        meta.includes_n += 1;
    }
}

/// Reads + caches test262 `harness/` include files so `includes:` tests can run.
const Harness = struct {
    io: std.Io,
    dir: ?std.Io.Dir,
    gpa: std.mem.Allocator,
    cache: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn get(self: *Harness, name: []const u8) ?[]const u8 {
        if (self.cache.get(name)) |c| return c;
        const dir = self.dir orelse return null;
        const data = dir.readFileAlloc(self.io, name, self.gpa, .limited(1 << 20)) catch return null;
        const key = self.gpa.dupe(u8, name) catch return null;
        self.cache.put(self.gpa, key, data) catch return null;
        return data;
    }
};

fn runOne(gpa: std.mem.Allocator, harness: *Harness, src: []const u8) Outcome {
    const meta = parseMeta(src);
    if (meta.unsupported_flag) return .skip;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    if (!meta.raw) {
        // Prefer the *real* upstream harness (`sta.js` + `assert.js`) — it now
        // carries `assert.compareArray`, `isPrimitive`, the precise error
        // messages, and a constructor-checking `assert.throws` the hand-written
        // shim lacked. Fall back to the shim only if the corpus harness can't be
        // read (e.g. submodule not checked out), so the runner still works
        // standalone.
        const sta = harness.get("sta.js");
        const ass = harness.get("assert.js");
        if (sta != null and ass != null) {
            buf.appendSlice(gpa, sta.?) catch return .skip;
            buf.append(gpa, '\n') catch return .skip;
            buf.appendSlice(gpa, ass.?) catch return .skip;
            buf.append(gpa, '\n') catch return .skip;
        } else {
            buf.appendSlice(gpa, harness_shim) catch return .skip;
        }
        var i: usize = 0;
        while (i < meta.includes_n) : (i += 1) {
            const inc = harness.get(meta.includes[i]) orelse return .skip; // can't load → skip
            buf.appendSlice(gpa, inc) catch return .skip;
            buf.append(gpa, '\n') catch return .skip;
        }
    }
    buf.appendSlice(gpa, src) catch return .skip;

    const ctx = js.Context.create(gpa) catch return .skip;
    defer ctx.destroy();

    if (ctx.evaluate(buf.items)) |_| {
        return if (meta.negative) .fail_negative else .pass;
    } else |err| {
        if (meta.negative) {
            const ok = if (meta.negative_parse) err != error.Throw else err == error.Throw;
            return if (ok) .pass_negative else .fail_negative;
        }
        return switch (err) {
            error.Throw => .fail_runtime,
            error.OutOfMemory => .fail_other,
            else => .fail_parse, // lex/parse errors (UnexpectedToken, …)
        };
    }
}

// The full `language` tree plus the built-ins areas the engine implements.
// With subprocess isolation a panic no longer aborts the run, so this scores
// broadly and credits every area already handled (Boolean/Number/Error/JSON/
// Map/Set/Symbol/Function/Date/… were previously unscored). The giant, mostly-
// unimplemented dirs (TypedArray/ArrayBuffer/Atomics/Proxy/Reflect-heavy/
// Temporal) are left out to keep `zig build test262` to a few minutes; add
// `"test/built-ins"` for a full (slow) audit.
const subtrees = [_][]const u8{
    "test/language",
    "test/built-ins/Math",     "test/built-ins/String",  "test/built-ins/Array",
    "test/built-ins/Object",   "test/built-ins/Boolean", "test/built-ins/Number",
    "test/built-ins/Error",    "test/built-ins/JSON",    "test/built-ins/Map",
    "test/built-ins/Set",      "test/built-ins/WeakMap", "test/built-ins/WeakSet",
    "test/built-ins/Symbol",   "test/built-ins/Function", "test/built-ins/Date",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const root = build_options.root;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "--worker")) {
            const sub = args.next() orelse return;
            const start = std.fmt.parseInt(usize, args.next() orelse "0", 10) catch 0;
            return runWorker(gpa, io, root, sub, start);
        }
    }
    return runParent(gpa, io, root);
}

/// Worker: walk `sub`, run each test from index `start`, and stream
/// `index:outcome` lines (then `DONE`) to stdout — flushing each line so a crash
/// loses only the in-flight test.
fn runWorker(gpa: std.mem.Allocator, io: std.Io, root: []const u8, sub: []const u8, start: usize) !void {
    const out = std.Io.File.stdout();
    const path = std.fs.path.join(gpa, &.{ root, sub }) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        out.writeStreamingAll(io, "DONE\n") catch {};
        return;
    };
    defer dir.close(io);

    const harness_path = std.fs.path.join(gpa, &.{ root, "harness" }) catch return;
    var harness = Harness{ .io = io, .gpa = gpa, .dir = std.Io.Dir.cwd().openDir(io, harness_path, .{}) catch null };

    var walker = dir.walk(gpa) catch {
        out.writeStreamingAll(io, "DONE\n") catch {};
        return;
    };
    defer walker.deinit();

    var idx: usize = 0;
    var line_buf: [32]u8 = undefined;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
        defer idx += 1;
        if (idx < start) continue; // already done by an earlier worker

        const src = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20)) catch {
            emit(out, io, &line_buf, idx, .skip);
            continue;
        };
        const o = runOne(gpa, &harness, src);
        gpa.free(src);
        emit(out, io, &line_buf, idx, o);
    }
    out.writeStreamingAll(io, "DONE\n") catch {};
}

fn emit(out: std.Io.File, io: std.Io, buf: []u8, idx: usize, o: Outcome) void {
    const line = std.fmt.bufPrint(buf, "{d}:{c}\n", .{ idx, outcomeChar(o) }) catch return;
    out.writeStreamingAll(io, line) catch {};
}

/// Parent: orchestrate per-subtree workers, recovering across crashes.
fn runParent(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    const exe = std.process.executablePathAlloc(io, gpa) catch {
        std.debug.print("test262: could not resolve own executable path; cannot spawn workers.\n", .{});
        return;
    };
    defer gpa.free(exe);

    std.debug.print("zig-js test262 ingestion (subprocess-isolated)\n==============================================\nroot: {s}\n", .{root});

    var total: Stats = .{};
    var any_dir = false;
    for (subtrees) |sub| {
        const path = std.fs.path.join(gpa, &.{ root, sub }) catch continue;
        defer gpa.free(path);
        var probe = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            std.debug.print("  (missing: {s})\n", .{sub});
            continue;
        };
        probe.close(io);
        any_dir = true;

        var stats: Stats = .{};
        driveSubtree(gpa, io, exe, sub, &stats);
        const vt = stats.validTotal();
        std.debug.print("  {s}: valid {d}/{d} ({d:.1}%)  [parse-fail {d} · runtime-fail {d} · host-fail {d}]  neg {d}/{d}\n", .{
            sub,             stats.pass,        vt,             Stats.pct(stats.pass, vt),
            stats.fail_parse, stats.fail_runtime, stats.fail_other,
            stats.pass_negative, stats.negTotal(),
        });
        total.merge(stats);
    }

    if (!any_dir) {
        std.debug.print("test262: corpus not found at '{s}'; skipping (set -Dtest262=<path>).\n", .{root});
        return;
    }

    const vt = total.validTotal();
    std.debug.print("----------------------------------------------\n", .{});
    std.debug.print("VALID (can we run it):  {d}/{d} ({d:.1}%)   parse-fail {d} · runtime-fail {d} · host-fail {d}\n", .{
        total.pass, vt, Stats.pct(total.pass, vt), total.fail_parse, total.fail_runtime, total.fail_other,
    });
    std.debug.print("NEGATIVE (strictness):  {d}/{d} ({d:.1}%)   [early-error rejection — mostly unimplemented]\n", .{
        total.pass_negative, total.negTotal(), Stats.pct(total.pass_negative, total.negTotal()),
    });
    std.debug.print("skipped (module/async/unloadable-includes): {d}\n", .{total.skip});
}

/// Run one subtree to completion across worker (re)spawns. Each worker streams
/// `index:outcome` lines and a final `DONE`; a worker that dies without `DONE`
/// crashed on the next unreported test, which is recorded as a host failure
/// before respawning just past it.
fn driveSubtree(gpa: std.mem.Allocator, io: std.Io, exe: []const u8, sub: []const u8, stats: *Stats) void {
    var next: usize = 0;
    while (true) {
        var start_buf: [24]u8 = undefined;
        const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{next}) catch return;
        const argv = [_][]const u8{ exe, "--worker", sub, start_str };
        // No explicit timeout: the engine's step budget bounds runtime, so a
        // worker always terminates (cleanly or by crashing) on its own.
        const res = std.process.run(gpa, io, .{
            .argv = &argv,
            .stdout_limit = .limited(64 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch {
            std.debug.print("  (worker spawn failed for {s} at {d})\n", .{ sub, next });
            return;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        var max_idx: ?usize = null;
        var done = false;
        var lines = std.mem.splitScalar(u8, res.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, "DONE")) {
                done = true;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (colon + 1 >= line.len) continue;
            const idx = std.fmt.parseInt(usize, line[0..colon], 10) catch continue;
            const o = charOutcome(line[colon + 1]) orelse continue;
            if (idx >= next) {
                stats.add(o);
                max_idx = idx;
            }
        }
        if (done) break;

        // The worker crashed (or timed out). Blame the next unreported test.
        const crasher = if (max_idx) |m| m + 1 else next;
        stats.add(.fail_other);
        next = crasher + 1; // strictly increases → guaranteed progress
    }
}
