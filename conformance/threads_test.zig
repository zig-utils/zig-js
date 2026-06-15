//! Runner for the vendored WebKit PR-249 threads corpus
//! (reference/webkit-249/threads-tests/) against the Phase-6 Thread API —
//! `zig build threads-test`. Each file runs in a fresh `enable_threads`
//! Context with the corpus's own assert.js + harness.js preloaded (their
//! `load()` becomes a no-op; the files are read from the reference tree, not
//! copied — see reference/webkit-249/README.md licensing notes).
//!
//! The allowlist below is the green set; it grows as API surface lands.
//! Files needing machinery a GIL'd tree-walker structurally lacks (some JIT/GC
//! stress, WebAssembly, and $vm hooks) stay reference-only.

const std = @import("std");
const js = @import("js");

const corpus_root = "reference/webkit-249/threads-tests";

const allowlist = [_][]const u8{
    "smoke.js",
    "api/condition-basic.js",
    "api/condition-async-wait.js",
    "api/condition-wait-termination.js",
    "api/lock-basic.js",
    "api/lock-async-hold.js",
    "api/lock-hold-termination.js",
    "api/park-no-microtask-drain.js",
    "api/thread-basic.js",
    "api/thread-ctor-errors.js",
    "api/thread-exc.js",
    "api/thread-id-bounds.js",
    "api/thread-restrict.js",
    "api/blocking-gate.js",
    "api/thread-lifecycle.js",
    "api/threadlocal-basic.js",
    "api/wasm-refused-sd7.js",
    "lifecycle/create-basics.js",
    "lifecycle/current-and-id.js",
    "lifecycle/exceptions-cross-join.js",
    "lifecycle/join-semantics.js",
    "lifecycle/nested-threads.js",
    "lifecycle/restrict.js",
    "lifecycle/restrict-foreign-access.js",
    "lifecycle/return-values.js",
    "lifecycle/async-join.js",
    "arrays/copy-on-write.js",
    "arrays/holes.js",
    "arrays/push-resize-multithread.js",
    "arrays/shared-element-read-write.js",
    "arrays/typed-arrays-sab.js",
    "bench/array-element-read.js",
    "bench/array-element-write.js",
    "bench/flat-butterfly-read.js",
    "bench/flat-butterfly-write.js",
    "bench/inline-property-read.js",
    "bench/inline-property-write.js",
    "bench/megamorphic-access.js",
    "bench/transition-heavy-constructor.js",
    "cve/mc-aint-terminate-notify-park-race.js",
    "cve/mc-code-deferred-fire-stale-window.js",
    "cve/mc-code-sleep-through-jettison-isb.js",
    "cve/mc-df-delete-reuse.js",
    "cve/mc-df-segmented-length.js",
    "cve/mc-df-ta-detach-resize.js",
    "cve/mc-df-wasm-compile-race.js",
    "cve/mc-dos-waiter-table-storm.js",
    "cve/mc-gc-blocked-native-roots.js",
    "cve/mc-gc-finreg-cross-thread-gc.js",
    "cve/mc-gc-thread-shell-finalizer-storm.js",
    "cve/mc-grow-wasm-relocating-grow.js",
    "cve/mc-hand-dead-registrant-settle.js",
    "cve/mc-hand-restrict-claim.js",
    "cve/mc-init-lazy-global-first-touch.js",
    "cve/mc-init-rope-resolve-race.js",
    "cve/mc-int-resizable-tail-quarantine.js",
    "cve/mc-life-detach-quarantine-storm.js",
    "cve/mc-life-sab-refchurn.js",
    "cve/mc-life-wasm-grow-relocate.js",
    "cve/mc-lock-cow-materialize-race.js",
    "cve/mc-lock-n3-install-vs-owner-add.js",
    "cve/mc-prim-arraybuffer-transfer-vs-atomics.js",
    "cve/mc-prim-async-generator-resume-claim.js",
    "cve/mc-prim-generator-claim-leak-stack-overflow.js",
    "cve/mc-prim-generator-resume-claim.js",
    "cve/mc-prim-indexed-missing-define-race.js",
    "cve/mc-reent-coercion-order.js",
    "cve/mc-reent-store-missing-indexed-define-race.js",
    "cve/mc-safe-regexp-tts-watchdog.js",
    "cve/mc-safe-spin-vs-classa-stop.js",
    "cve/mc-tdwn-exit-vs-settle.js",
    "cve/mc-tdwn-tid-recycle-storm.js",
    "cve/mc-tdwn-vm-teardown-unjoined.js",
    "cve/mc-tear-date-cache.js",
    "cve/mc-tear-generator-resume.js",
    "cve/mc-tear-rope-resolve-race.js",
    "cve/mc-val-atom-identity.js",
    "cve/mc-val-llint-cache-storm.js",
    "cve/mc-val-multislot-clone.js",
    "cve/mc-wait-property-wait-lost-wakeup.js",
    "gc-stress/conservative-scan-register.js",
    "gc-stress/havebadtime-vs-indexed-fastpath.js",
    "gc-stress/watchpoint-storm.js",
    "gc-stress/zombie-uaf-canary.js",
    "jit/construction-shared-constructor.js",
    "jit/fires-per-sec.js",
    "jit/ftl-direct-tailcall-dataic-arg-clobber.js",
    "jit/ftl-osr-entry-catch-loop-amplifier.js",
    "jit/golden-disasm-corpus.js",
    "jit/int-gate-epoch-reclaim.js",
    "jit/int-gate-fire-vs-execute.js",
    "jit/int-gate-direct-call-relink.js",
    "jit/int-gate-jettison-vs-execute.js",
    "jit/int-gate-stop-budget.js",
    "jit/shared-arraystorage-stress.js",
    "jit/spawned-thread-butterfly-stress.js",
    "jit/tag-discipline.js",
    "jit/tid-tag-3-threads.js",
    "atomics/property-cas-delete-undefined-sentinel-u5.js",
    "atomics/property-cas-dictionary-delete-u5.js",
    "atomics/property-cas-samevaluezero.js",
    "atomics/property-cas-storm-u28-flat.js",
    "atomics/property-cas-storm-u5-as.js",
    "atomics/property-errors.js",
    "atomics/property-load-store.js",
    "atomics/property-rmw.js",
    "atomics/property-store-missing-define-race.js",
    "atomics/property-wait-notify.js",
    "atomics/property-wait-termination.js",
    "atomics/property-waitasync-timeout.js",
    "atomics/property-wtr-isolation.js",
    "atomics/ta-path-unchanged.js",
    "atomics/ta-wait-thread-gate.js",
    "sync/atomics-futex-lock.js",
    "sync/atomics-object-basic.js",
    "sync/condition-notify-all-multi-waiter.js",
    "sync/condition-notify-all-shared-lock.js",
    "sync/condition-notify-all.js",
    "sync/condition-wait-notify.js",
    "sync/condition-worker-waiter.js",
    "sync/lock-async-hold.js",
    "sync/lock-hold-basic.js",
    "sync/lock-hold-mutual-exclusion.js",
    "sync/thread-local-isolation.js",
    "shared-objects/dictionary-mode.js",
    "shared-objects/frozen-sealed.js",
    "shared-objects/getters-setters.js",
    "shared-objects/property-add.js",
    "shared-objects/property-delete.js",
    "shared-objects/property-read-write.js",
    "shared-objects/prototype-chain.js",
    "races/counter-atomics.js",
    "races/counter-lock.js",
    "races/forin-enumerator-cache.js",
    "races/join-storm.js",
    "races/transition-vs-read.js",
    "races/transition-vs-write.js",
    "races/wait-notify-storm.js",
    "heap-access-blocking.js",
    "heap-allocation-storm.js",
    "heap-bench-allocation.js",
    "heap-client-churn.js",
    "heap-deferral-storm.js",
    "heap-epoch-reclaim.js",
    "heap-iss-revert.js",
    "heap-option-off.js",
    "heap-precise-storm.js",
    "heap-stop-interleavings.js",
    "invariants/delete-quarantine-dictionary.js",
    "invariants/delete-quarantine.js",
    "invariants/no-lost-elements.js",
    "invariants/no-lost-properties-same-name.js",
    "invariants/no-lost-properties.js",
    "invariants/no-time-travel.js",
    "invariants/no-torn-shapes.js",
    "objectmodel/i03-array-resize-cas.js",
    "objectmodel/i03-as-shift-unshift.js",
    "objectmodel/i03-as-sparse-holes.js",
    "objectmodel/i03-b2-stay-flat-growth-vs-sw-flip.js",
    "objectmodel/i03-convert-grow-gc-read.js",
    "objectmodel/i03-cow-materialize-race.js",
    "objectmodel/i03-i37-same-shape-add-storm.js",
    "objectmodel/i03-n2-inline-add-races.js",
    "objectmodel/i03-n3-first-install-races.js",
    "objectmodel/i03-pa-global-races.js",
    "objectmodel/i03-quarantine-readd-across-gc.js",
    "objectmodel/i03-restart-locked-vs-conversion.js",
    "objectmodel/i03-selftest.js",
    "objectmodel/i03-shared-double.js",
    "objectmodel/i03-single-threaded-flag-on.js",
    "objectmodel/i03-single-threaded-no-change.js",
    "objectmodel/i03-stale-spine-reader-vs-grow.js",
    "objectmodel/i03-stress-force-segmented.js",
    "objectmodel/i03-stress-force-sw.js",
    "objectmodel/i03-t1-vs-sw-flip.js",
    "objectmodel/i03-t5-racing-growers.js",
    "objectmodel/i03-visit-range-outofline.js",
    "objectmodel/i08-named-vs-indexed-first-install.js",
    "semantics/atom-rope-torture.js",
    "semantics/date-cache-churn.js",
    "semantics/frozen-seal-race.js",
    "semantics/ic-delete_by_id-vs-transition.js",
    "semantics/ic-get_by_id-vs-transition.js",
    "semantics/ic-get_by_val-vs-transition.js",
    "semantics/ic-in_by_id-vs-transition.js",
    "semantics/ic-instanceof-vs-transition.js",
    "semantics/ic-put_by_id-vs-transition.js",
    "semantics/ic-put_by_val-vs-transition.js",
    "semantics/private-fields-shared.js",
    "semantics/proto-cycle-race.js",
    "semantics/regexp-lastindex-shared.js",
    "semantics/symbol-registry-cross-thread.js",
    "semantics/termination-storm.js",
    "scaling/lock-fairness.js",
    "scaling/map-heavy.js",
    "scaling/raytrace-like.js",
    "scaling/richards-like.js",
    "scaling/splay-like.js",
    "scaling/string-heavy.js",
    "vmstate/all-flags-identity.js",
    "vmstate/exception-state-per-thread.js",
    "vmstate/flags-off-baseline.js",
    "vmstate/microtask-ordering.js",
    "vmstate/regexp-churn-threads.js",
    "vmstate/stack-limits-per-thread.js",
    "vmstate/structure-churn-dictionary.js",
    "vmstate/structure-churn-threads.js",
    "vmstate/structure-lock-single-thread.js",
    "vmstate/vmlite-single-thread-identity.js",
};

fn runsWithoutThreadGlobal(name: []const u8) bool {
    return std.mem.eql(u8, name, "objectmodel/i03-single-threaded-no-change.js") or
        std.mem.eql(u8, name, "vmstate/flags-off-baseline.js") or
        std.mem.eql(u8, name, "vmstate/vmlite-single-thread-identity.js");
}

fn usesBenchHarness(name: []const u8) bool {
    return (std.mem.startsWith(u8, name, "bench/") and !std.mem.endsWith(u8, name, "/harness.js")) or
        std.mem.eql(u8, name, "heap-bench-allocation.js") or
        std.mem.eql(u8, name, "jit/construction-shared-constructor.js") or
        std.mem.eql(u8, name, "jit/fires-per-sec.js");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    // `zig build threads-test -Dthreads-sweep=true` runs every default-gate
    // directory file instead of the green allowlist (a panicking file kills the run — use
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
    const bench_harness_src = try dir.readFileAlloc(io, "bench/harness.js", gpa, .limited(1 << 20));
    defer gpa.free(bench_harness_src);
    const scaling_harness_src = try dir.readFileAlloc(io, "scaling/harness.js", gpa, .limited(1 << 20));
    defer gpa.free(scaling_harness_src);
    const vmstate_workload_src = try dir.readFileAlloc(io, "vmstate/resources/workload.js", gpa, .limited(1 << 20));
    defer gpa.free(vmstate_workload_src);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        if (sweep) for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    if (sweep) {
        for ([_][]const u8{ "api", "arrays", "atomics", "bench", "lifecycle", "races", "scaling", "shared-objects", "sync" }) |sub| {
            var d = dir.openDir(io, sub, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".js")) continue;
                if (std.mem.eql(u8, entry.name, "harness.js")) continue;
                const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.name });
                try names.append(gpa, full);
            }
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    } else if (one) |paths| {
        var it = std.mem.splitScalar(u8, paths, ',');
        while (it.next()) |path| {
            if (path.len != 0) try names.append(gpa, path);
        }
    } else {
        try names.appendSlice(gpa, &allowlist);
    }

    var failed: usize = 0;
    for (names.items) |name| {
        // Keep corpus cases hermetic: defers in this block run at the end of
        // each file, so completed JS threads are OS-joined and all per-context
        // waiter tables/buffers are released before the next file starts.
        {
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
            if (usesBenchHarness(name)) {
                try buf.appendSlice(gpa, bench_harness_src);
                try buf.appendSlice(gpa, "\n");
                try buf.appendSlice(gpa,
                    \\// Runner-local bench sizing: the external bench gate owns
                    \\// timings; the default corpus checks deterministic results.
                    \\reportBench = function(name, fn, expected) {
                    \\  var measured = fn();
                    \\  if (measured != expected) throw "Error: bad result during benchmark of " + name + ": " + measured;
                    \\  print("BENCH " + name + " 0.000");
                    \\};
                    \\
                );
            }
            if (std.mem.startsWith(u8, name, "scaling/") and !std.mem.endsWith(u8, name, "/harness.js")) {
                try buf.appendSlice(gpa, scaling_harness_src);
                try buf.appendSlice(gpa, "\n");
            }
            if (std.mem.startsWith(u8, name, "vmstate/") and std.mem.indexOf(u8, test_src, "resources/workload.js") != null) {
                try buf.appendSlice(gpa, vmstate_workload_src);
                try buf.appendSlice(gpa, "\n");
            }
            try buf.appendSlice(gpa, test_src);

            // Per-file configs, mirroring their run-tests.sh / //@ runDefault
            // lines: blocking-gate runs can-block-is-false; thread-id-bounds runs
            // --maxJSThreads=4; *-termination runs --watchdog=500 with the
            // termination throw as its PASSING outcome.
            const enable_threads = !runsWithoutThreadGlobal(name);
            const options = js.Context.TestingOptions{
                .enable_threads = enable_threads,
                .enable_gc = std.mem.indexOf(u8, test_src, "gc()") != null,
                .main_can_block = !std.mem.endsWith(u8, name, "blocking-gate.js"),
                .max_js_threads = if (std.mem.endsWith(u8, name, "thread-id-bounds.js")) 4 else null,
            };
            const directive = test_src[0 .. std.mem.indexOfScalar(u8, test_src, '\n') orelse test_src.len];
            const expect_termination = std.mem.endsWith(u8, name, "-termination.js") or
                std.mem.indexOf(u8, directive, "--watchdog-exception-ok") != null;
            const ctx = js.Context.createWithTestingOptions(gpa, options) catch {
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
                var balanced = false;
                for (0..3000) |_| {
                    const status = ctx.evaluate("drainMicrotasks(); __asyncExpected === null || __asyncPassed >= __asyncExpected") catch js.Value.undefined;
                    if (status == .boolean and status.boolean) {
                        balanced = true;
                        break;
                    }
                    std.Io.sleep(js.agent.engineIo(), .fromMilliseconds(10), .awake) catch {};
                }
                if (balanced) {
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
                if (ctx.exception) |e| {
                    if (e == .string and std.mem.eql(u8, e.string, "__zigjs_threads_quit__")) {
                        std.debug.print("  PASS  {s}\n", .{name});
                        continue;
                    }
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
    }
    std.debug.print("------------------------\n{d}/{d} corpus files passed\n", .{ names.items.len - failed, names.items.len });
    if (failed != 0 and !sweep) return error.CorpusFailures;
}
