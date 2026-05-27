const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The importable module: `@import("js")` once a consumer adds this package.
    const mod = b.addModule("js", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
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
        }),
    });
    b.installArtifact(lib);

    // Unit tests over the root module (engine core + C-API).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
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
    if (b.args) |args| run_test262.addArgs(args);
    const test262_step = b.step("test262", "Run the real test262 corpus and report pass rate");
    test262_step.dependOn(&run_test262.step);

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
