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
}
