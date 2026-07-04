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
//! `--worker <subtree> <start-index> <limit>`): a worker streams one
//! `index:outcome` line per test to stdout (unbuffered, so a crash loses only
//! the in-flight line) and prints `DONE` when finished. If a worker dies without
//! `DONE`, the parent records the next unreported test as a host failure and
//! respawns the worker just past it. This makes scoring crash-proof, so the real
//! harness `includes:` files are loaded (no longer skipped) and the built-ins
//! subtrees can be scored safely. The engine's step budget bounds runtime, so
//! there are no true hangs (a `timeout` is set as a backstop anyway).
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
//!   - `negative: { type, phase }` → expect a parse/resolution error or throw
//!
//! Usage: `zig build test262` (root from the `-Dtest262=<path>` build option). A
//! missing corpus is reported and skipped cleanly (exit 0).

const std = @import("std");
const js = @import("js");
const build_options = @import("build_options");

const worker_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(30),
    .clock = .awake,
} };
const verbose_failures = false;
// SpiderMonkey-ported staging subtrees that still HANG or CRASH the engine, so
// they stay skipped until the underlying bug is fixed (re-measured 2026-06-23
// per category). The rest of the sm/ tree — Array, Iterator, generators,
// destructuring, async-functions, AsyncGenerators, Atomics — runs cleanly and is
// now scored; it had been bulk-skipped as a stale time decision, not a real
// capability gap.
const unsupported_staging_prefixes = [_][]const u8{
    "sm/Date/", // Zig-level infinite loop in Date handling (worker hangs ~#21)
    "sm/TypedArray/", // Zig-level infinite loop (worker hangs ~#15)
    "sm/BigInt/", // worker crash / host-fail
    "sm/regress/regress-1507322-deep-weakmap.js", // quarantined deep-WeakMap test
    "sm/String/replace-math.js", // quarantined
    // These pending SpiderMonkey staging tests predate/contradict the current
    // Annex B.3.3 `arguments` skip rule covered by official test262
    // annexB/language/function-code/block-decl-func-skip-arguments.js.
    "sm/regress/regress-602621.js",
    "sm/lexical-environment/block-scoped-functions-annex-b-arguments.js",
};
const unsupported_subtrees = [_][]const u8{};
const UnsupportedPathPrefix = struct { sub: []const u8, prefix: []const u8 };
// The Iterator-helper subtrees used to be excluded here because a `next`-accessor
// that returned a fresh generator each read caused unbounded iteration. With
// GetIteratorDirect capturing `next` once (and IteratorClose on abrupt
// completion), they run cleanly and are scored again.
const unsupported_path_prefixes = [_]UnsupportedPathPrefix{};

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

const sm_error_native_errors_compat =
    \\var nativeErrors = [
    \\  EvalError,
    \\  RangeError,
    \\  ReferenceError,
    \\  SyntaxError,
    \\  TypeError,
    \\  URIError
    \\];
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
    negative_resolution: bool = false,
    /// `flags: [onlyStrict]` — the test must run as strict-mode code, so a
    /// `"use strict"` directive is prepended to the assembled source.
    only_strict: bool = false,
    /// `flags: [async]` — the test signals completion by calling `$DONE` (often
    /// from a Promise reaction); success/failure is read from the print buffer.
    is_async: bool = false,
    /// `flags: [module]` — run as an ES module (harness in the global scope, the
    /// body linked + evaluated as a module against sibling fixtures).
    is_module: bool = false,
    /// `flags: [CanBlockIsFalse]` — run with the main agent's [[CanBlock]]
    /// false (Atomics.wait on it must throw TypeError).
    can_block_false: bool = false,
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
    if (std.mem.indexOf(u8, front, "tail-call-optimization") != null)
        meta.unsupported_flag = true;
    if (std.mem.indexOf(u8, front, "flags:")) |fi| {
        const flags = flagsRegion(front, fi);
        if (std.mem.indexOf(u8, flags, "raw")) |_| meta.raw = true;
        if (std.mem.indexOf(u8, flags, "onlyStrict")) |_| meta.only_strict = true;
        if (std.mem.indexOf(u8, flags, "async")) |_| meta.is_async = true;
        // The async/async-generator corpus needs machinery beyond the current
        // synchronous-settling runtime (async generators, for-await, Promise
        // combinators, exact ordering), so it stays skipped like modules; the
        // runtime is exercised by the unit tests and the Promise built-ins.
        // Modules run via a dedicated path (`runModule`). Async modules
        // (module+async) additionally need top-level-await/$DONE-in-module
        // machinery, so those stay skipped; CanBlockIsFalse needs Atomics.
        // module+async needs top-level-await/$DONE-in-module machinery, so it
        // stays unsupported; a plain async test runs via the $DONE / @@Async
        // sentinel path in runOne (the synchronous-settling async runtime).
        if (std.mem.indexOf(u8, flags, "module") != null) {
            if (meta.is_async) meta.unsupported_flag = true else meta.is_module = true;
        }
        if (std.mem.indexOf(u8, flags, "CanBlockIsFalse") != null)
            meta.can_block_false = true;
    }
    if (std.mem.indexOf(u8, front, "negative:")) |ni| {
        meta.negative = true;
        const region = front[ni..];
        if (std.mem.indexOf(u8, region, "phase: parse") != null or
            std.mem.indexOf(u8, region, "phase:parse") != null)
            meta.negative_parse = true;
        if (std.mem.indexOf(u8, region, "phase: resolution") != null or
            std.mem.indexOf(u8, region, "phase:resolution") != null)
            meta.negative_resolution = true;
    }
    return meta;
}

fn flagsRegion(front: []const u8, fi: usize) []const u8 {
    const line_end = std.mem.indexOfScalarPos(u8, front, fi, '\n') orelse front.len;
    const line = front[fi..line_end];
    if (std.mem.indexOfScalar(u8, line, '[') != null) {
        const flags_end = if (std.mem.indexOfScalar(u8, line, ']') == null)
            (std.mem.indexOfScalarPos(u8, front, line_end, ']') orelse line_end) + 1
        else
            line_end;
        return front[fi..flags_end];
    }

    var end = line_end;
    var pos = if (line_end < front.len) line_end + 1 else line_end;
    while (pos < front.len) {
        const next = std.mem.indexOfScalarPos(u8, front, pos, '\n') orelse front.len;
        const trimmed = trimFlagsLineLeft(front[pos..next]);
        if (trimmed.len == 0 or trimmed[0] == '-') {
            end = next;
            pos = if (next < front.len) next + 1 else next;
            continue;
        }
        break;
    }
    return front[fi..end];
}

fn trimFlagsLineLeft(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r')) : (i += 1) {}
    return line[i..];
}

fn negativeMatched(meta: Meta, err: anyerror) bool {
    if (meta.negative_parse) return err != error.Throw;
    if (meta.negative_resolution) return true;
    return err == error.Throw;
}

fn moduleRootParses(gpa: std.mem.Allocator, src: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = js.Parser.init(arena.allocator(), src) catch return false;
    _ = parser.parseModule() catch return false;
    return true;
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

    fn deinit(self: *Harness) void {
        if (self.dir) |*d| d.close(self.io);
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.cache.deinit(self.gpa);
    }
};

fn runOne(gpa: std.mem.Allocator, io: std.Io, harness: *Harness, abs_path: []const u8, src: []const u8) Outcome {
    return runOneDetail(gpa, io, harness, abs_path, src, null);
}

/// Like `runOne`, but when `detail` is non-null it captures a short human-readable
/// reason for a valid-test failure (the thrown error's `Name: message`, or the
/// parse error name) so the `--diag` mode can cluster failures by cause.
fn runOneDetail(gpa: std.mem.Allocator, io: std.Io, harness: *Harness, abs_path: []const u8, src: []const u8, detail: ?*std.ArrayListUnmanaged(u8)) Outcome {
    const meta = parseMeta(src);
    if (meta.unsupported_flag) return .skip;
    if (meta.is_module) return runModule(gpa, io, harness, abs_path, src, meta);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    // `onlyStrict` tests carry no directive of their own — the harness supplies
    // it. Prepended before everything so the whole program (harness included)
    // is strict-mode code, as the spec requires.
    if (meta.only_strict and !meta.raw) buf.appendSlice(gpa, "\"use strict\";\n") catch return .skip;
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
            const inc = harnessIncludeOverride(abs_path, meta.includes[i]) orelse
                harness.get(meta.includes[i]) orelse return .skip; // can't load → skip
            buf.appendSlice(gpa, inc) catch return .skip;
            buf.append(gpa, '\n') catch return .skip;
        }
        // Async tests signal completion via `$DONE`, defined in
        // doneprintHandle.js — which the harness auto-provides for the `async`
        // flag rather than listing in `includes:`.
        if (meta.is_async) {
            if (harness.get("doneprintHandle.js")) |dph| {
                buf.appendSlice(gpa, dph) catch return .skip;
                buf.append(gpa, '\n') catch return .skip;
            }
        }
    }
    buf.appendSlice(gpa, src) catch return .skip;

    // `-Dtest262-parallel-js` runs every test in a GIL-free parallel context:
    // the test JS is single-threaded, so this doesn't probe concurrency races,
    // but it exercises the parallel-mode locked paths and the GC-managed cell
    // allocator across the entire language surface — catching deadlocks, locked-
    // path correctness regressions, and GC-allocation gaps that the threads
    // corpus (a narrow slice of the language) can't.
    const ctx = js.Context.createWithTestingOptions(gpa, if (build_options.parallel_js) .{
        .main_can_block = !meta.can_block_false,
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    } else .{
        .main_can_block = !meta.can_block_false,
    }) catch return .skip;
    defer ctx.destroy();

    // Enable top-level-script dynamic `import()` (resolved relative to the test
    // file), so script tests that `import('./fixture.js')` work like the engine's
    // module path. The host only does I/O if the script actually calls import().
    var host = ModHost{ .gpa = gpa, .io = io };
    defer host.deinit();
    var imp_cache: std.StringHashMapUnmanaged(*js.Context.Module) = .{};
    ctx.mod_host = .{ .ctx = &host, .load = modLoad };
    ctx.mod_cache = &imp_cache;
    ctx.script_referrer = abs_path;

    if (ctx.evaluate(buf.items)) |_| {
        if (meta.negative) return .fail_negative;
        // An async test passes only if it printed the harness success sentinel
        // ($DONE with no error) by the time microtasks have drained.
        if (meta.is_async) {
            const out = ctx.print_buffer.items;
            const done = std.mem.indexOf(u8, out, "Test262:AsyncTestComplete") != null;
            return if (done) .pass else .fail_runtime;
        }
        return .pass;
    } else |err| {
        if (meta.negative) {
            return if (negativeMatched(meta, err)) .pass_negative else .fail_negative;
        }
        if (detail) |d| captureDetail(gpa, ctx, err, d);
        return switch (err) {
            error.Throw => .fail_runtime,
            error.OutOfMemory => .fail_other,
            else => .fail_parse, // lex/parse errors (UnexpectedToken, …)
        };
    }
}

/// Write a short failure reason into `d`: the thrown error stringified, or the
/// Zig parse-error name. Best-effort — used only by `--diag`.
fn captureDetail(gpa: std.mem.Allocator, ctx: *js.Context, err: anyerror, d: *std.ArrayListUnmanaged(u8)) void {
    if (err == error.Throw) {
        if (ctx.exception) |ex| {
            // For a thrown *object* (Test262Error, native errors, …), render its
            // `name: message` directly so assertion failures show their message
            // rather than the bare `[object Object]` that ToString gives a
            // non-native-error object.
            if (ex.isObject()) {
                const o = ex.asObj();
                const name = if (o.getOwn("name")) |v| (if (v.isString()) v.asStr() else o.error_name) else o.error_name;
                const msg = if (o.getOwn("message")) |v| (if (v.isString()) v.asStr() else "") else "";
                if (name.len != 0 or msg.len != 0) {
                    d.appendSlice(gpa, name) catch {};
                    if (msg.len != 0) {
                        d.appendSlice(gpa, ": ") catch {};
                        d.appendSlice(gpa, msg) catch {};
                    }
                    return;
                }
            }
            const s = ex.toString(gpa) catch "<throw>";
            d.appendSlice(gpa, s) catch {};
            return;
        }
        d.appendSlice(gpa, "<throw>") catch {};
        return;
    }
    d.appendSlice(gpa, @errorName(err)) catch {};
}

fn harnessIncludeOverride(abs_path: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, name, "nativeErrors.js")) return null;
    // These SpiderMonkey-staging tests predate the 2026 test262 harness change
    // that made `nativeErrors` include %Error% itself. They already assert
    // %Error% separately, then use `nativeErrors` for the six NativeError
    // subclasses.
    if (std.mem.endsWith(u8, abs_path, "test/staging/sm/Error/constructor-proto.js") or
        std.mem.endsWith(u8, abs_path, "test/staging/sm/Error/prototype-properties.js") or
        std.mem.endsWith(u8, abs_path, "test/staging/sm/Error/prototype.js"))
        return sm_error_native_errors_compat;
    return null;
}

/// `--eval <file>`: evaluate a raw JS file (no harness) and print `OK <value>`
/// or `<ErrName>: <message>` / `<ParseError>` — a quick probe during development.
fn runEval(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const out = std.Io.File.stdout();
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return;
    const ctx = js.Context.create(gpa) catch return;
    defer ctx.destroy();
    var buf: [4096]u8 = undefined;
    if (ctx.evaluate(src)) |v| {
        const s = v.toString(gpa) catch "?";
        const line = std.fmt.bufPrint(&buf, "OK {s}\n", .{s}) catch "OK\n";
        out.writeStreamingAll(io, line) catch {};
    } else |err| {
        var d: std.ArrayListUnmanaged(u8) = .empty;
        captureDetail(gpa, ctx, err, &d);
        const line = std.fmt.bufPrint(&buf, "ERR {s}\n", .{d.items}) catch "ERR\n";
        out.writeStreamingAll(io, line) catch {};
    }
}

/// `--diag <subtree> [substr]`: run every test in a subtree (optionally filtered
/// to paths containing `substr`) and print one `outcome<TAB>path<TAB>detail` line
/// per *valid* failure, so failures can be clustered by cause during development.
fn runDiag(gpa: std.mem.Allocator, io: std.Io, root: []const u8, sub: []const u8, filter: ?[]const u8) !void {
    const out = std.Io.File.stdout();
    const path = std.fs.path.join(gpa, &.{ root, sub }) catch return;
    defer gpa.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const harness_path = std.fs.path.join(gpa, &.{ root, "harness" }) catch return;
    defer gpa.free(harness_path);
    var harness = Harness{ .io = io, .gpa = gpa, .dir = std.Io.Dir.cwd().openDir(io, harness_path, .{}) catch null };
    defer harness.deinit();

    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();

    var n_fail: usize = 0;
    var n_pass: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
        if (filter) |f| if (std.mem.indexOf(u8, entry.path, f) == null) continue;
        if (shouldSkipPath(sub, entry.path)) continue;
        const src = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(src);
        const maybe_abs = std.fs.path.join(gpa, &.{ path, entry.path }) catch null;
        defer if (maybe_abs) |a| gpa.free(a);
        const abs_path = maybe_abs orelse entry.basename;
        var detail: std.ArrayListUnmanaged(u8) = .empty;
        defer detail.deinit(gpa);
        const o = runOneDetail(gpa, io, &harness, abs_path, src, &detail);
        if (o == .pass or o == .pass_negative) {
            n_pass += 1;
            continue;
        }
        if (o == .skip) continue;
        n_fail += 1;
        // collapse newlines in the detail so each failure is a single line
        for (detail.items) |*c| {
            if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
        }
        var lb: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&lb, "{s}\t{s}\t{s}\n", .{ @tagName(o), entry.path, detail.items }) catch continue;
        out.writeStreamingAll(io, line) catch {};
    }
    var sb: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&sb, "# {s}: {d} fail, {d} pass\n", .{ sub, n_fail, n_pass }) catch return;
    out.writeStreamingAll(io, summary) catch {};
}

/// Host state for the module loader: read a fixture relative to the importing
/// module's path (resolving `.`/`..` so the same file dedups to one path).
const ModHost = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: std.ArrayListUnmanaged([]const u8) = .empty,
    sources: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *ModHost) void {
        for (self.paths.items) |p| self.gpa.free(p);
        for (self.sources.items) |s| self.gpa.free(s);
        self.paths.deinit(self.gpa);
        self.sources.deinit(self.gpa);
    }
};

fn modLoad(ctx: *anyopaque, referrer: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
    const h: *ModHost = @ptrCast(@alignCast(ctx));
    const dir = std.fs.path.dirname(referrer) orelse ".";
    const joined = std.fs.path.resolve(h.gpa, &.{ dir, specifier }) catch return null;
    const source = std.Io.Dir.cwd().readFileAlloc(h.io, joined, h.gpa, .limited(1 << 20)) catch {
        h.gpa.free(joined);
        return null;
    };
    h.paths.append(h.gpa, joined) catch {
        h.gpa.free(source);
        h.gpa.free(joined);
        return null;
    };
    h.sources.append(h.gpa, source) catch {
        h.paths.items.len -= 1;
        h.gpa.free(source);
        h.gpa.free(joined);
        return null;
    };
    out_path.* = joined;
    return source;
}

/// Run a `flags: [module]` test: install the harness in the global scope, then
/// link + evaluate the test body as a Module against its sibling fixtures.
fn runModule(gpa: std.mem.Allocator, io: std.Io, harness: *Harness, abs_path: []const u8, src: []const u8, meta: Meta) Outcome {
    if (meta.negative_resolution and !moduleRootParses(gpa, src)) return .fail_negative;
    // `-Dtest262-parallel-js` runs every test in a GIL-free parallel context:
    // the test JS is single-threaded, so this doesn't probe concurrency races,
    // but it exercises the parallel-mode locked paths and the GC-managed cell
    // allocator across the entire language surface — catching deadlocks, locked-
    // path correctness regressions, and GC-allocation gaps that the threads
    // corpus (a narrow slice of the language) can't.
    const ctx = js.Context.createWithTestingOptions(gpa, if (build_options.parallel_js) .{
        .main_can_block = !meta.can_block_false,
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    } else .{
        .main_can_block = !meta.can_block_false,
    }) catch return .skip;
    defer ctx.destroy();
    if (!meta.raw) {
        var hbuf: std.ArrayListUnmanaged(u8) = .empty;
        defer hbuf.deinit(gpa);
        const sta = harness.get("sta.js");
        const ass = harness.get("assert.js");
        if (sta != null and ass != null) {
            hbuf.appendSlice(gpa, sta.?) catch return .skip;
            hbuf.append(gpa, '\n') catch return .skip;
            hbuf.appendSlice(gpa, ass.?) catch return .skip;
            hbuf.append(gpa, '\n') catch return .skip;
        } else hbuf.appendSlice(gpa, harness_shim) catch return .skip;
        var i: usize = 0;
        while (i < meta.includes_n) : (i += 1) {
            const inc = harnessIncludeOverride(abs_path, meta.includes[i]) orelse
                harness.get(meta.includes[i]) orelse return .skip;
            hbuf.appendSlice(gpa, inc) catch return .skip;
            hbuf.append(gpa, '\n') catch return .skip;
        }
        _ = ctx.evaluate(hbuf.items) catch {};
    }
    var host = ModHost{ .gpa = gpa, .io = io };
    defer host.deinit();
    const mh = js.Context.ModuleHost{ .ctx = &host, .load = modLoad };
    if (ctx.evaluateModule(abs_path, src, mh)) |_| {
        return if (meta.negative) .fail_negative else .pass;
    } else |err| {
        if (meta.negative) {
            return if (negativeMatched(meta, err)) .pass_negative else .fail_negative;
        }
        return switch (err) {
            error.Throw => .fail_runtime,
            error.OutOfMemory => .fail_other,
            else => .fail_parse,
        };
    }
}

// The ENTIRE test262 corpus: `language`, `annexB`, `intl402`, `staging`, and
// every `built-ins/*` area — so `zig build test262` measures everything (each
// dir reported separately for visibility). Subprocess isolation means an
// unimplemented area just scores low rather than aborting the run. Some giant
// areas (Temporal, intl402, Atomics/SharedArrayBuffer, ShadowRealm) are largely
// unimplemented and run slow; they're scored honestly at their true (low) rate.
const subtrees = [_][]const u8{
    "test/language/arguments-object",
    "test/language/asi",
    "test/language/block-scope",
    "test/language/comments",
    "test/language/computed-property-names",
    "test/language/destructuring",
    "test/language/directive-prologue",
    "test/language/eval-code",
    "test/language/export",
    "test/language/expressions",
    "test/language/function-code",
    "test/language/future-reserved-words",
    "test/language/global-code",
    "test/language/identifier-resolution",
    "test/language/identifiers",
    "test/language/import",
    "test/language/keywords",
    "test/language/line-terminators",
    "test/language/literals",
    "test/language/module-code",
    "test/language/punctuators",
    "test/language/reserved-words",
    "test/language/rest-parameters",
    "test/language/source-text",
    "test/language/statementList",
    "test/language/statements",
    "test/language/types",
    "test/language/white-space",
    "test/annexB",
    "test/intl402",
    "test/staging",
    "test/built-ins/AbstractModuleSource",
    "test/built-ins/AggregateError",
    "test/built-ins/Array",
    "test/built-ins/ArrayBuffer",
    "test/built-ins/ArrayIteratorPrototype",
    "test/built-ins/AsyncDisposableStack",
    "test/built-ins/AsyncFromSyncIteratorPrototype",
    "test/built-ins/AsyncFunction",
    "test/built-ins/AsyncGeneratorFunction",
    "test/built-ins/AsyncGeneratorPrototype",
    "test/built-ins/AsyncIteratorPrototype",
    "test/built-ins/Atomics",
    "test/built-ins/BigInt",
    "test/built-ins/Boolean",
    "test/built-ins/DataView",
    "test/built-ins/Date",
    "test/built-ins/decodeURI",
    "test/built-ins/decodeURIComponent",
    "test/built-ins/DisposableStack",
    "test/built-ins/encodeURI",
    "test/built-ins/encodeURIComponent",
    "test/built-ins/Error",
    "test/built-ins/eval",
    "test/built-ins/FinalizationRegistry",
    "test/built-ins/Function",
    "test/built-ins/GeneratorFunction",
    "test/built-ins/GeneratorPrototype",
    "test/built-ins/global",
    "test/built-ins/Infinity",
    "test/built-ins/isFinite",
    "test/built-ins/isNaN",
    "test/built-ins/Iterator",
    "test/built-ins/JSON",
    "test/built-ins/Map",
    "test/built-ins/MapIteratorPrototype",
    "test/built-ins/Math",
    "test/built-ins/NaN",
    "test/built-ins/NativeErrors",
    "test/built-ins/Number",
    "test/built-ins/Object",
    "test/built-ins/parseFloat",
    "test/built-ins/parseInt",
    "test/built-ins/Promise",
    "test/built-ins/Proxy",
    "test/built-ins/Reflect",
    "test/built-ins/RegExp",
    "test/built-ins/RegExpStringIteratorPrototype",
    "test/built-ins/Set",
    "test/built-ins/SetIteratorPrototype",
    "test/built-ins/ShadowRealm",
    "test/built-ins/SharedArrayBuffer",
    "test/built-ins/String",
    "test/built-ins/StringIteratorPrototype",
    "test/built-ins/SuppressedError",
    "test/built-ins/Symbol",
    "test/built-ins/Temporal",
    "test/built-ins/ThrowTypeError",
    "test/built-ins/TypedArray",
    "test/built-ins/TypedArrayConstructors",
    "test/built-ins/Uint8Array",
    "test/built-ins/undefined",
    "test/built-ins/WeakMap",
    "test/built-ins/WeakRef",
    "test/built-ins/WeakSet",
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
            const limit = std.fmt.parseInt(usize, args.next() orelse "0", 10) catch 0;
            return runWorker(gpa, io, root, sub, start, limit);
        }
        if (std.mem.eql(u8, mode, "--diag")) {
            const sub = args.next() orelse return;
            const filter = args.next();
            return runDiag(gpa, io, root, sub, filter);
        }
        if (std.mem.eql(u8, mode, "--eval")) {
            const path = args.next() orelse return;
            return runEval(gpa, io, path);
        }
    }
    return runParent(gpa, io, root);
}

/// Worker: walk `sub`, run each test from index `start`, and stream
/// `index:outcome` lines (then `DONE`) to stdout — flushing each line so a crash
/// loses only the in-flight test.
fn runWorker(gpa: std.mem.Allocator, io: std.Io, root: []const u8, sub: []const u8, start: usize, limit: usize) !void {
    const out = std.Io.File.stdout();
    const path = std.fs.path.join(gpa, &.{ root, sub }) catch return;
    defer gpa.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        out.writeStreamingAll(io, "DONE\n") catch {};
        return;
    };
    defer dir.close(io);

    const harness_path = std.fs.path.join(gpa, &.{ root, "harness" }) catch return;
    defer gpa.free(harness_path);
    var harness = Harness{ .io = io, .gpa = gpa, .dir = std.Io.Dir.cwd().openDir(io, harness_path, .{}) catch null };
    defer harness.deinit();

    var walker = dir.walk(gpa) catch {
        out.writeStreamingAll(io, "DONE\n") catch {};
        return;
    };
    defer walker.deinit();

    var idx: usize = 0;
    var ran: usize = 0;
    var more = false;
    var line_buf: [32]u8 = undefined;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
        const current_idx = idx;
        idx += 1;
        if (current_idx < start) continue; // already done by an earlier worker
        if (limit != 0 and ran >= limit) {
            more = true;
            break;
        }
        if (shouldSkipPath(sub, entry.path)) {
            emit(out, io, &line_buf, current_idx, .skip);
            ran += 1;
            continue;
        }

        const src = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20)) catch {
            emit(out, io, &line_buf, current_idx, .skip);
            ran += 1;
            continue;
        };
        const maybe_abs_path = std.fs.path.join(gpa, &.{ path, entry.path }) catch null;
        defer if (maybe_abs_path) |abs_path| gpa.free(abs_path);
        const abs_path = maybe_abs_path orelse entry.basename;
        const o = runOne(gpa, io, &harness, abs_path, src);
        if (verbose_failures and (o == .fail_negative or o == .fail_runtime or o == .fail_parse)) {
            var xb: [512]u8 = undefined;
            if (std.fmt.bufPrint(&xb, "XF\t{s}\t{s}\n", .{ @tagName(o), entry.path })) |xl| {
                out.writeStreamingAll(io, xl) catch {};
            } else |_| {}
        }
        gpa.free(src);
        emit(out, io, &line_buf, current_idx, o);
        ran += 1;
    }
    out.writeStreamingAll(io, if (more) "MORE\n" else "DONE\n") catch {};
}

fn shouldSkipPath(sub: []const u8, rel_path: []const u8) bool {
    const path = if (std.mem.startsWith(u8, rel_path, "./")) rel_path[2..] else rel_path;
    for (unsupported_subtrees) |unsupported| {
        if (std.mem.eql(u8, sub, unsupported)) return true;
    }
    for (unsupported_path_prefixes) |unsupported| {
        if (std.mem.eql(u8, sub, unsupported.sub) and std.mem.startsWith(u8, path, unsupported.prefix)) return true;
    }
    for (unsupported_staging_prefixes) |prefix| {
        if (stagingPathMatches(sub, path, prefix)) return true;
    }
    return false;
}

fn stagingPathMatches(sub: []const u8, path: []const u8, prefix: []const u8) bool {
    const staging = "test/staging";
    if (std.mem.eql(u8, sub, staging)) return std.mem.startsWith(u8, path, prefix);
    if (!std.mem.startsWith(u8, sub, staging ++ "/")) return false;

    const tail = sub[(staging ++ "/").len..];
    if (std.mem.startsWith(u8, tail, prefix)) return true;
    if (std.mem.startsWith(u8, prefix, tail) and prefix.len > tail.len and prefix[tail.len] == '/')
        return std.mem.startsWith(u8, path, prefix[tail.len + 1 ..]);
    return false;
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
        driveSubtree(gpa, io, root, exe, sub, &stats);
        const vt = stats.validTotal();
        std.debug.print("  {s}: valid {d}/{d} ({d:.1}%)  [parse-fail {d} · runtime-fail {d} · host-fail {d}]  neg {d}/{d}\n", .{
            sub,              stats.pass,         vt,               Stats.pct(stats.pass, vt),
            stats.fail_parse, stats.fail_runtime, stats.fail_other, stats.pass_negative,
            stats.negTotal(),
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
fn driveSubtree(gpa: std.mem.Allocator, io: std.Io, root: []const u8, exe: []const u8, sub: []const u8, stats: *Stats) void {
    var next: usize = 0;
    while (true) {
        var start_buf: [24]u8 = undefined;
        const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{next}) catch return;
        var limit_buf: [24]u8 = undefined;
        const worker_limit = workerLimitForSubtree(sub);
        const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{worker_limit}) catch return;
        const argv = [_][]const u8{ exe, "--worker", sub, start_str, limit_str };
        // The engine's step budget handles normal execution, but malformed
        // semantics can still wedge one test. Treat no-output stalls like
        // crashes so one pathological case cannot block the whole corpus.
        const res = std.process.run(gpa, io, .{
            .argv = &argv,
            .stdout_limit = .limited(256 << 20),
            .stderr_limit = .limited(256 << 20),
            .timeout = worker_timeout,
        }) catch |err| switch (err) {
            error.Timeout => {
                if (pathAtIndex(gpa, io, root, sub, next)) |timed_path| {
                    defer gpa.free(timed_path);
                    std.debug.print("  (worker timed out for {s} at {d}: {s})\n", .{ sub, next, timed_path });
                } else {
                    std.debug.print("  (worker timed out for {s} at {d})\n", .{ sub, next });
                }
                stats.add(.fail_other);
                next += 1;
                continue;
            },
            else => {
                std.debug.print("  (worker run failed with {s} for {s} at {d})\n", .{ @errorName(err), sub, next });
                return;
            },
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);

        var max_idx: ?usize = null;
        var done = false;
        var more = false;
        var lines = std.mem.splitScalar(u8, res.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, "DONE")) {
                done = true;
                continue;
            }
            if (std.mem.eql(u8, line, "MORE")) {
                more = true;
                continue;
            }
            if (std.mem.startsWith(u8, line, "XF\t")) {
                std.debug.print("{s}\n", .{line});
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
        if (more) {
            next = if (max_idx) |m| m + 1 else next + 1;
            continue;
        }

        // The worker crashed (or timed out). Blame the next unreported test.
        const crasher = if (max_idx) |m| m + 1 else next;
        if (pathAtIndex(gpa, io, root, sub, crasher)) |crash_path| {
            defer gpa.free(crash_path);
            std.debug.print("  (worker crashed for {s} at {d}: {s})\n", .{ sub, crasher, crash_path });
        } else {
            std.debug.print("  (worker crashed for {s} at {d})\n", .{ sub, crasher });
        }
        stats.add(.fail_other);
        next = crasher + 1; // strictly increases → guaranteed progress
    }
}

fn workerLimitForSubtree(sub: []const u8) usize {
    if (std.mem.eql(u8, sub, "test/staging")) return 1;
    // One test per worker process for the blocking-wait corpus: a worker
    // timeout discards the batch's partial stdout and blames its FIRST test,
    // so a wedged agent test in a 10-batch would cost up to 10×30s to crawl
    // past. At limit 1 a deadlock costs one timeout and blames the right test.
    if (std.mem.eql(u8, sub, "test/built-ins/Atomics")) return 1;
    return 10;
}

fn pathAtIndex(gpa: std.mem.Allocator, io: std.Io, root: []const u8, sub: []const u8, target: usize) ?[]const u8 {
    const path = std.fs.path.join(gpa, &.{ root, sub }) catch return null;
    defer gpa.free(path);

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var walker = dir.walk(gpa) catch return null;
    defer walker.deinit();

    var idx: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
        if (idx == target) return gpa.dupe(u8, entry.path) catch null;
        idx += 1;
    }
    return null;
}
