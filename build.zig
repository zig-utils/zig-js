const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Homegrown regex engine, used to back JS RegExp.
    const regex_dep = b.dependency("zig_regex", .{ .target = target, .optimize = optimize });
    const regex_mod = regex_dep.module("regex");

    // Precise tracing GC (issue #1 Phase 7). Opt-in contexts route heap cells
    // through it; src/gc.zig supplies the engine binding. See P7-gc-design.md.
    const gc_dep = b.dependency("zig_gc", .{ .target = target, .optimize = optimize });
    const gc_mod = gc_dep.module("gc");

    // The importable module: `@import("js")` once a consumer adds this package.
    const mod = b.addModule("js", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "gc", .module = gc_mod },
        },
    });

    // A static library exposing the JavaScriptCore C-API drop-in symbols
    // (JSGlobalContextCreate, JSEvaluateScript, ...). Linking this in place of
    // the system `JavaScriptCore` framework makes the engine a drop-in.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig-js",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "gc", .module = gc_mod },
            },
        }),
    });
    b.installArtifact(lib);

    // Unit tests over the root module (engine core + C-API).
    // `-Dtsan` builds them under ThreadSanitizer — the concurrency gate for
    // the agent/worker/waiter machinery (issue #1).
    const tsan = b.option(bool, "tsan", "Build unit tests with ThreadSanitizer") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose name contains this substring");
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "gc", .module = gc_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zig-js unit tests");
    test_step.dependOn(&run_tests.step);

    // Conformance runner: `zig build conformance` reports the pass percentage
    // over the curated (test262-style) suite.
    const conformance = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    const run_conformance = b.addRunArtifact(conformance);
    const conformance_step = b.step("conformance", "Run the JS conformance suite");
    conformance_step.dependOn(&run_conformance.step);

    // Threads corpus: `zig build threads-test` runs the vendored WebKit
    // PR-249 thread tests (the green allowlist) against the Phase-6 API.
    // `-Dtsan` builds the corpus *and the engine it links* under
    // ThreadSanitizer — the issue #1 "whole-corpus TSan run" gate. It uses a
    // dedicated TSan-instrumented copy of the `js` module so the other
    // consumers of the shared `mod` are unaffected; off by default it is `mod`.
    const threads_js_mod = if (tsan) b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = true,
        .imports = &.{
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "gc", .module = gc_mod },
        },
    }) else mod;
    const threads_test = b.addExecutable(.{
        .name = "threads-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/threads_test.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "js", .module = threads_js_mod }},
        }),
    });
    const run_threads_test = b.addRunArtifact(threads_test);
    const threads_case = b.option([]const u8, "threads-case", "Run one vendored thread test path") orelse null;
    const threads_sweep = b.option(bool, "threads-sweep", "Run every vendored default-gate thread test") orelse false;
    const threads_parallel_js = b.option(bool, "threads-parallel-js", "Run threaded PR-249 cases with the test-only parallel_js GIL-removal mode") orelse false;
    if (threads_parallel_js) {
        run_threads_test.addArg("parallel-js");
    }
    if (threads_sweep) {
        run_threads_test.addArg("sweep");
    } else if (threads_case) |case| {
        run_threads_test.addArgs(&.{ "one", case });
    }
    const threads_test_step = b.step("threads-test", "Run the vendored PR-249 threads corpus allowlist");
    threads_test_step.dependOn(&run_threads_test.step);

    // Compile-only: install the threads-test exe to zig-out/bin without running
    // it, so CI's whole-corpus no-GIL TSan sweep can invoke it directly at a
    // stable path — `zig build threads-test-bin -Dtsan=true` then
    // `./zig-out/bin/threads-test parallel-js one <path>` per case. Per-case
    // isolation sidesteps the cumulative-load OOM of a single allowlist-in-one-process
    // TSan run (TSan shadow memory grows across the whole allowlist).
    const threads_test_install = b.addInstallArtifact(threads_test, .{});
    const threads_test_bin_step = b.step("threads-test-bin", "Build the threads-test exe only (no run)");
    threads_test_bin_step.dependOn(&threads_test_install.step);

    const threads_reference_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/threads-reference-audit.py",
        "--fail-on-uncategorized",
    });
    const threads_reference_audit_step = b.step("threads-reference-audit", "Audit remaining reference-only PR-249 files");
    threads_reference_audit_step.dependOn(&threads_reference_audit_cmd.step);

    // Concurrent-JS fuzzer: `zig build threadfuzz [-Dtsan] [-Dfuzz-iters=N] [-Dfuzz-seed=S]`.
    // Generates random programs that share objects/arrays/closures/typed-arrays
    // across JS Threads and runs each in a GIL-free parallel context. Under
    // `-Dtsan` any unsynchronized engine access surfaces as a data race; it
    // links the same TSan-instrumented `js` module as the corpus gate. The
    // exe also installs to zig-out/bin so CI can shard seed ranges per-process
    // (TSan shadow memory grows across a long single-process run).
    const fuzz_iters = b.option(usize, "fuzz-iters", "threadfuzz: number of programs to generate") orelse 200;
    const fuzz_seed = b.option(usize, "fuzz-seed", "threadfuzz: base RNG seed") orelse 1;
    const fuzz_amplify = b.option(bool, "fuzz-amplify", "threadfuzz: high-contention profile (more threads, longer loops)") orelse false;
    const fuzz_broad = b.option(bool, "fuzz-broad", "threadfuzz: broad semantic profile (exceptions, waiters, cleanup, lifecycle)") orelse false;
    const fuzz_midgc = b.option(bool, "fuzz-midgc", "threadfuzz: mid-script parallel GC wait-pump, microtask churn, late asyncJoin fulfillment/rejection cleanup, creator-owned buffers, nested Thread asyncJoin cleanup, ThreadLocal finalization/termination cleanup and Thread.restrict finalization, sync-wait cleanup including property waitAsync timeout/live tickets plus retained-SAB Worker overlap and same-primitive burst release, sync timeout exit, Atomics.Mutex.lockIfAvailable acquire/timeout cleanup, Atomics.Condition.wait notify/reacquire cleanup, asyncHold release/waiter cleanup, teardown-termination, promise-publication, script/module Worker/SAB cleanup, Worker exception cleanup, Worker close/terminate drain/drop, and weak-collection cleanup profile") orelse false;
    const fuzz_lifecycle = b.option(bool, "fuzz-lifecycle", "threadfuzz: deterministic resizable ArrayBuffer/DataView no-GIL races, termination, pending reaction teardown, Worker/module-worker graph overlap, Worker/module-worker exception/finalization cleanup and terminate/thread teardown including condition async, ThreadLocal cleanup, and script/module waitAsync cleanup, Atomics.Mutex/Condition token waits plus lockIfAvailable acquire/timeout paths, Worker/thread/finalization scheduling, asyncHold/Condition.asyncWait barging and cleanup, asyncHold throw/release/waiter cleanup, Promise microtask churn, late asyncJoin fulfillment/rejection cleanup, creator-owned buffer and script/module Worker clone/finalization lifetime, nested Thread asyncJoin cleanup, Thread.restrict/ThreadLocal isolation, Thread.restrict/ThreadLocal finalization cleanup, waitAsync/finalization cleanup, finalization cleanup/waiter/unregister, and exact script/module Worker close/terminate drain/drop lifecycle profile") orelse false;
    const fuzz_verify = b.option(bool, "fuzz-verify", "threadfuzz: deterministic-correctness mode (predict + check each result)") orelse false;
    const threadfuzz = b.addExecutable(.{
        .name = "threadfuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/threadfuzz.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "js", .module = threads_js_mod }},
        }),
    });
    const run_threadfuzz = b.addRunArtifact(threadfuzz);
    if (fuzz_verify) run_threadfuzz.addArg("verify") else if (fuzz_lifecycle) run_threadfuzz.addArg("lifecycle") else if (fuzz_midgc) run_threadfuzz.addArg("midgc") else if (fuzz_broad) run_threadfuzz.addArg("broad") else if (fuzz_amplify) run_threadfuzz.addArg("amplify");
    run_threadfuzz.addArgs(&.{ b.fmt("{d}", .{fuzz_iters}), b.fmt("{d}", .{fuzz_seed}) });
    const threadfuzz_step = b.step("threadfuzz", "Fuzz GIL-free parallel execution with random concurrent programs");
    threadfuzz_step.dependOn(&run_threadfuzz.step);
    const threadfuzz_install = b.addInstallArtifact(threadfuzz, .{});
    const threadfuzz_bin_step = b.step("threadfuzz-bin", "Build the threadfuzz exe only (no run)");
    threadfuzz_bin_step.dependOn(&threadfuzz_install.step);

    // test262 ingestion: `zig build test262 [-Dtest262=<root>]` runs the real
    // tc39/test262 corpus through the engine and reports the (partial) pass
    // rate. The default root is the pinned `test262` git submodule, so we always
    // measure against upstream's latest (run `git submodule update --remote` to
    // bump it).
    const t262_root = b.option([]const u8, "test262", "Path to the test262 corpus root") orelse
        "test262";
    const t262_parallel = b.option(bool, "test262-parallel-js", "Run every test262 test in a GIL-free parallel context (exercises the parallel-mode locks + the GC across the whole language surface)") orelse false;
    const t262_options = b.addOptions();
    t262_options.addOption([]const u8, "root", t262_root);
    t262_options.addOption(bool, "parallel_js", t262_parallel);

    const test262 = b.addExecutable(.{
        .name = "test262",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/test262.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    test262.root_module.addOptions("build_options", t262_options);
    const run_test262 = b.addRunArtifact(test262);
    const test262_step = b.step("test262", "Run the real test262 corpus and report pass rate");
    test262_step.dependOn(&run_test262.step);

    // Compile-only: build the test262 runner exe without running the corpus, so
    // the `--worker`/`--diag` binary can be rebuilt fast during development.
    const test262_install = b.addInstallArtifact(test262, .{});
    const test262_bin_step = b.step("test262-bin", "Build the test262 runner exe only (no run)");
    test262_bin_step.dependOn(&test262_install.step);

    // THROWAWAY parse-failure diagnostic.
    const diag = b.addExecutable(.{
        .name = "diag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/diag.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    diag.root_module.addOptions("build_options", t262_options);
    const run_diag = b.addRunArtifact(diag);
    const diag_step = b.step("diag", "Throwaway parse-failure diagnostic");
    diag_step.dependOn(&run_diag.step);

    // Benchmarks: `zig build bench` times the VM against the tree-walker.
    // ReleaseFast so the numbers reflect real performance, not Debug overhead.
    const bench_js_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "gc", .module = gc_mod },
        },
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Benchmark the bytecode VM against the tree-walker");
    bench_step.dependOn(&run_bench.step);

    // Thread contention profile: compare the no-GIL shared-realm default against
    // the `.gil = true` fallback across hot shared structures. This is a local
    // performance tool, not a correctness gate.
    const threads_profile = b.addExecutable(.{
        .name = "threads-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/threads.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_threads_profile = b.addRunArtifact(threads_profile);
    const threads_profile_step = b.step("threads-profile", "Profile no-GIL Thread contention, async waits, and .gil fallback cost");
    threads_profile_step.dependOn(&run_threads_profile.step);

    // GC allocation/lifecycle profile: compare arena, explicit-GC, no-GIL
    // threaded GC, and `.gil = true` lifecycle costs. Local performance tool.
    const gc_profile = b.addExecutable(.{
        .name = "gc-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gc.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_gc_profile = b.addRunArtifact(gc_profile);
    const gc_profile_step = b.step("gc-profile", "Profile GC allocation and Context lifecycle costs");
    gc_profile_step.dependOn(&run_gc_profile.step);
}
