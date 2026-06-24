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

    // test262 ingestion: `zig build test262 [-Dtest262=<root>]` runs the real
    // tc39/test262 corpus through the engine and reports the (partial) pass
    // rate. The default root is the pinned `test262` git submodule, so we always
    // measure against upstream's latest (run `git submodule update --remote` to
    // bump it).
    const t262_root = b.option([]const u8, "test262", "Path to the test262 corpus root") orelse
        "test262";
    const t262_options = b.addOptions();
    t262_options.addOption([]const u8, "root", t262_root);

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
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Benchmark the bytecode VM against the tree-walker");
    bench_step.dependOn(&run_bench.step);
}
