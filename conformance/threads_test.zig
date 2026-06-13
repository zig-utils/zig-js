//! Runner for the vendored WebKit PR-249 threads corpus
//! (reference/webkit-249/threads-tests/) against the Phase-6 Thread API —
//! `zig build threads-test`. Each file runs in a fresh `enable_threads`
//! Context with the corpus's own assert.js + harness.js preloaded (their
//! `load()` becomes a no-op; the files are read from the reference tree, not
//! copied — see reference/webkit-249/README.md licensing notes).
//!
//! The allowlist below is the green set; it grows as API surface lands.
//! Files needing machinery a GIL'd tree-walker structurally lacks (JIT/GC
//! stress, $vm hooks) stay reference-only.

const std = @import("std");
const js = @import("js");

const corpus_root = "reference/webkit-249/threads-tests";

const allowlist = [_][]const u8{
    "api/condition-basic.js",
    "api/condition-async-wait.js",
    "api/condition-wait-termination.js",
    "api/lock-basic.js",
    "api/lock-async-hold.js",
    "api/park-no-microtask-drain.js",
    "api/thread-basic.js",
    "api/thread-ctor-errors.js",
    "api/thread-exc.js",
    "api/thread-id-bounds.js",
    "api/thread-restrict.js",
    "api/blocking-gate.js",
    "api/thread-lifecycle.js",
    "api/threadlocal-basic.js",
    "atomics/property-cas-samevaluezero.js",
    "atomics/property-errors.js",
    "atomics/property-load-store.js",
    "atomics/property-rmw.js",
    "atomics/property-wait-notify.js",
    "atomics/property-waitasync-timeout.js",
    "sync/atomics-futex-lock.js",
    "sync/atomics-object-basic.js",
    "sync/condition-notify-all-multi-waiter.js",
    "sync/condition-notify-all-shared-lock.js",
    "sync/condition-notify-all.js",
    "sync/condition-wait-notify.js",
    "sync/condition-worker-waiter.js",
    "sync/lock-hold-basic.js",
    "sync/lock-hold-mutual-exclusion.js",
    "sync/thread-local-isolation.js",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    // `zig build threads-test -Dthreads-sweep=true` runs every api/atomics/sync file
    // instead of the green allowlist (a panicking file kills the run — use
    // `-Dthreads-case=<path>` to probe a single file safely).
    var sweep = false;
    var one: ?[]const u8 = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    if (args.next()) |a| {
        if (std.mem.eql(u8, a, "sweep")) sweep = true;
        if (std.mem.eql(u8, a, "one")) one = args.next();
    }

    var dir = cwd.openDir(io, corpus_root, .{}) catch {
        std.debug.print("threads-test: corpus not found at {s} (run from the repo root)\n", .{corpus_root});
        return error.CorpusMissing;
    };
    defer dir.close(io);

    const assert_src = try dir.readFileAlloc(io, "resources/assert.js", gpa, .limited(1 << 20));
    defer gpa.free(assert_src);
    const harness_src = try dir.readFileAlloc(io, "harness.js", gpa, .limited(1 << 20));
    defer gpa.free(harness_src);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        if (sweep) for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    if (sweep) {
        for ([_][]const u8{ "api", "atomics", "sync" }) |sub| {
            var d = dir.openDir(io, sub, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".js")) continue;
                const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.name });
                try names.append(gpa, full);
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    } else if (one) |path| {
        try names.append(gpa, path);
    } else {
        try names.appendSlice(gpa, &allowlist);
    }

    var failed: usize = 0;
    for (names.items) |name| {
        const test_src = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch {
            std.debug.print("  MISS  {s}\n", .{name});
            failed += 1;
            continue;
        };
        defer gpa.free(test_src);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        // Their `load(path)` becomes a no-op: everything it would pull in is
        // concatenated below in dependency order. asyncTestStart/Passed are
        // jsc-shell builtins in their setup; the shim counts and the runner
        // verifies the balance after the drain tail.
        try buf.appendSlice(gpa,
            \\const load = () => {};
            \\globalThis.__asyncExpected = null;
            \\globalThis.__asyncPassed = 0;
            \\const asyncTestStart = (n) => { globalThis.__asyncExpected = n; };
            \\const asyncTestPassed = () => { globalThis.__asyncPassed++; };
            \\
        );
        try buf.appendSlice(gpa, assert_src);
        try buf.appendSlice(gpa, "\n");
        try buf.appendSlice(gpa, harness_src);
        try buf.appendSlice(gpa, "\n");
        try buf.appendSlice(gpa, test_src);

        // Per-file configs, mirroring their run-tests.sh / //@ runDefault
        // lines: blocking-gate runs can-block-is-false; thread-id-bounds runs
        // --maxJSThreads=4; condition-wait-termination runs --watchdog=500
        // with the termination throw as its PASSING outcome.
        const options = js.Context.Options{
            .enable_threads = true,
            .main_can_block = !std.mem.endsWith(u8, name, "blocking-gate.js"),
            .max_js_threads = if (std.mem.endsWith(u8, name, "thread-id-bounds.js")) 4 else null,
        };
        const expect_termination = std.mem.endsWith(u8, name, "condition-wait-termination.js");
        const ctx = js.Context.createWith(gpa, options) catch {
            std.debug.print("  FAIL  {s} (context)\n", .{name});
            failed += 1;
            continue;
        };
        defer ctx.destroy();

        // The 500ms watchdog: arms a stop flag the engine's park quanta and
        // step checkpoints poll (the engine's termination request).
        var stop = std.atomic.Value(bool).init(false);
        var watchdog: ?std.Thread = null;
        if (expect_termination) {
            ctx.stop_flag = &stop;
            const Dog = struct {
                fn run(flag: *std.atomic.Value(bool)) void {
                    std.Io.sleep(js.agent.engineIo(), .fromMilliseconds(500), .awake) catch {};
                    flag.store(true, .monotonic);
                }
            };
            watchdog = std.Thread.spawn(.{}, Dog.run, .{&stop}) catch null;
        }
        defer if (watchdog) |w| w.join();
        if (ctx.evaluate(buf.items)) |_| {
            if (expect_termination) {
                failed += 1;
                std.debug.print("  FAIL  {s}: returned normally under termination\n", .{name});
                continue;
            }
            const balanced = ctx.evaluate("__asyncExpected === null || __asyncPassed >= __asyncExpected") catch js.Value.undefined;
            if (balanced == .boolean and balanced.boolean) {
                std.debug.print("  PASS  {s}\n", .{name});
            } else {
                failed += 1;
                std.debug.print("  FAIL  {s}: async completions not reached\n", .{name});
            }
        } else |_| {
            if (expect_termination) {
                // The watchdog-exception-ok contract: the termination throw IS
                // the pass; the D9-violation paths print FAILURE first.
                if (std.mem.indexOf(u8, ctx.print_buffer.items, "FAILURE") == null) {
                    std.debug.print("  PASS  {s}\n", .{name});
                } else {
                    failed += 1;
                    std.debug.print("  FAIL  {s}: D9 violated\n", .{name});
                }
                continue;
            }
            failed += 1;
            // Stringifying the exception can run JS (Error.prototype.toString):
            // hold the GIL like any other entry into the realm.
            if (ctx.gil) |g| g.acquire();
            const msg = if (ctx.exception) |e| descr: {
                var machine = ctx.interpreter();
                break :descr machine.toStringV(e) catch "?";
            } else "?";
            std.debug.print("  FAIL  {s}: {s}\n", .{ name, msg });
            if (ctx.gil) |g| g.release();
        }
    }
    std.debug.print("------------------------\n{d}/{d} corpus files passed\n", .{ names.items.len - failed, names.items.len });
    if (failed != 0 and !sweep) return error.CorpusFailures;
}
