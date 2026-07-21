const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Build tests with ThreadSanitizer") orelse false;

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

    // A static library exposing the implemented C API symbols. Some names are
    // JavaScriptCore-shaped for embedding convenience, but pre-stabilization API
    // cleanup should prefer clear zig-js semantics over inert compatibility shims.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig-js",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "gc", .module = gc_mod },
            },
        }),
    });
    const private_abi_consumer = b.option(
        []const u8,
        "private-abi-consumer",
        "Private ABI tag layout to compile: home or bun",
    ) orelse "home";
    const private_abi_is_bun = if (std.mem.eql(u8, private_abi_consumer, "home"))
        false
    else if (std.mem.eql(u8, private_abi_consumer, "bun"))
        true
    else
        std.debug.panic("unknown private-abi-consumer '{s}'; expected home or bun", .{private_abi_consumer});
    const private_abi_options = b.addOptions();
    private_abi_options.addOption(bool, "is_bun", private_abi_is_bun);
    mod.addOptions("private_abi_options", private_abi_options);
    lib.root_module.addOptions("private_abi_options", private_abi_options);

    // Focused Home and Bun fixtures may run together. Compile the opposite
    // private-tag profile once so neither fixture inherits the command-line
    // profile intended for the installed library.
    const fixture_private_abi_options = b.addOptions();
    fixture_private_abi_options.addOption(bool, "is_bun", !private_abi_is_bun);
    const fixture_private_lib = b.addLibrary(.{
        .linkage = .static,
        .name = if (private_abi_is_bun) "zig-js-private-home" else "zig-js-private-bun",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "gc", .module = gc_mod },
            },
        }),
    });
    fixture_private_lib.root_module.addOptions("private_abi_options", fixture_private_abi_options);
    const home_private_lib = if (private_abi_is_bun) fixture_private_lib else lib;
    const bun_private_lib = if (private_abi_is_bun) lib else fixture_private_lib;
    var installed_library: ?std.Build.LazyPath = null;
    var objc_bridge_object: ?std.Build.LazyPath = null;
    if (target.result.os.tag == .macos) {
        const compile_objc_bridge = b.addSystemCommand(&.{
            "xcrun",      "--sdk",    "macosx",                         "clang",
            "-fobjc-arc", "-fblocks", "-Wno-incomplete-implementation",
        });
        compile_objc_bridge.addPrefixedDirectoryArg("-I", b.path("include"));
        compile_objc_bridge.addArg("-c");
        compile_objc_bridge.addFileArg(b.path("src/objc_bridge.m"));
        compile_objc_bridge.addArg("-o");
        objc_bridge_object = compile_objc_bridge.addOutputFileArg("objc_bridge.o");

        const merge_library = b.addSystemCommand(&.{
            "python3",
            "tools/merge-static-library.py",
        });
        installed_library = merge_library.addOutputFileArg("libzig-js.a");
        merge_library.addArtifactArg(lib);
        merge_library.addFileArg(objc_bridge_object.?);
        b.getInstallStep().dependOn(&b.addInstallLibFile(installed_library.?, "libzig-js.a").step);
    } else {
        b.installArtifact(lib);
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    }).step);

    // Pinned public-C declaration/export drift gate plus small real-host ABI
    // checks. These stay separate from the world-sized Zig unit-test artifact.
    const c_api_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/verify-c-api.py",
    });
    const c_api_audit_step = b.step("c-api-audit", "Verify pinned JSC declarations, inventory, and Zig exports");
    c_api_audit_step.dependOn(&c_api_audit_cmd.step);

    const home_public_abi_profile = b.option(
        []const u8,
        "home-public-abi-profile",
        "Exact supported Home public C ABI profile ID",
    ) orelse "home-public-c-7ed99c02";
    const home_public_abi_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/verify-abi-profile.py",
        "--profile",
        home_public_abi_profile,
    });
    const home_source_root = b.option([]const u8, "home-source-root", "Optional pinned Home checkout to verify");
    if (home_source_root) |root| {
        home_public_abi_audit_cmd.addArgs(&.{ "--home-root", root });
    }
    const home_public_abi_audit_step = b.step(
        "home-public-abi-audit",
        "Verify the revision-pinned Home public C consumer profile",
    );
    home_public_abi_audit_step.dependOn(&home_public_abi_audit_cmd.step);

    const home_private_abi_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/home-private-abi.py",
        "--profile",
        b.option([]const u8, "home-private-abi-profile", "Exact supported Home private ABI profile ID") orelse "home-private-7ed99c02",
    });
    if (home_source_root) |root| home_private_abi_audit_cmd.addArgs(&.{ "--home-root", root });
    const home_private_abi_audit_step = b.step(
        "home-private-abi-audit",
        "Verify the pinned Home private extern-fn inventory",
    );
    home_private_abi_audit_step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_abi_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/bun-private-abi.py",
    });
    const bun_source_root = b.option([]const u8, "bun-source-root", "Optional pinned Bun checkout to verify");
    if (bun_source_root) |root| {
        bun_private_abi_audit_cmd.addArgs(&.{ "--bun-root", root });
    }
    const bun_private_abi_audit_step = b.step(
        "bun-private-abi-audit",
        "Verify the pinned Bun core private extern-fn inventory",
    );
    bun_private_abi_audit_step.dependOn(&bun_private_abi_audit_cmd.step);

    const private_jstype_abi_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/private-jstype-abi.py",
    });
    if (home_source_root) |root| {
        if (bun_source_root) |bun_root| {
            private_jstype_abi_audit_cmd.addArgs(&.{ "--home-root", root, "--bun-root", bun_root });
        }
    }
    const private_jstype_abi_audit_step = b.step(
        "private-jstype-abi-audit",
        "Verify pinned Home and Bun private JSType layouts",
    );
    private_jstype_abi_audit_step.dependOn(&private_jstype_abi_audit_cmd.step);

    const objc_api_audit_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/verify-objc-api.py",
    });
    const objc_api_audit_step = b.step("objc-api-audit", "Verify the pinned Objective-C JSC inventory");
    objc_api_audit_step.dependOn(&objc_api_audit_cmd.step);
    if (target.result.os.tag == .macos) {
        const objc_header_smoke = b.addSystemCommand(&.{
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-fsyntax-only",
            "-fobjc-arc",
            "-fblocks",
            "-Iinclude",
            "tests/objc_api_headers_smoke.m",
        });
        objc_header_smoke.step.dependOn(&objc_api_audit_cmd.step);
        const objc_header_step = b.step("test-objc-api-headers", "Compile the Objective-C bridge headers on macOS");
        objc_header_step.dependOn(&objc_header_smoke.step);

        const objc_runtime_smoke = b.addExecutable(.{
            .name = "objc-api-runtime-smoke",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        objc_runtime_smoke.root_module.addCSourceFile(.{
            .file = b.path("tests/objc_api_runtime_smoke.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks", "-Wno-arc-retain-cycles" },
        });
        objc_runtime_smoke.root_module.addIncludePath(b.path("include"));
        objc_runtime_smoke.root_module.addObjectFile(installed_library.?);
        objc_runtime_smoke.root_module.linkFramework("Foundation", .{});
        objc_runtime_smoke.root_module.linkSystemLibrary("ffi", .{});
        const run_objc_runtime_smoke = b.addRunArtifact(objc_runtime_smoke);
        run_objc_runtime_smoke.step.dependOn(&objc_api_audit_cmd.step);
        const objc_runtime_step = b.step("test-objc-api", "Compile, link, and run the Objective-C bridge host");
        objc_runtime_step.dependOn(&run_objc_runtime_smoke.step);

        const objc_lifetime_stress = b.addExecutable(.{
            .name = "objc-api-lifetime-stress",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        objc_lifetime_stress.root_module.addCSourceFile(.{
            .file = b.path("tests/objc_api_lifetime_stress.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks", "-Wno-arc-retain-cycles", "-Wno-objc-circular-container" },
        });
        objc_lifetime_stress.root_module.addIncludePath(b.path("include"));
        objc_lifetime_stress.root_module.addObjectFile(installed_library.?);
        objc_lifetime_stress.root_module.linkFramework("Foundation", .{});
        objc_lifetime_stress.root_module.linkSystemLibrary("ffi", .{});
        const run_objc_lifetime_stress = b.addRunArtifact(objc_lifetime_stress);
        run_objc_lifetime_stress.step.dependOn(&objc_api_audit_cmd.step);
        const objc_lifetime_step = b.step("test-objc-api-lifetime", "Stress Objective-C VM, wrapper, managed-reference, and autorelease teardown");
        objc_lifetime_step.dependOn(&run_objc_lifetime_stress.step);

        const objc_sanitized_stress = b.addSystemCommand(&.{
            "xcrun",                          "--sdk",                        "macosx",                 "clang",
            "-fobjc-arc",                     "-fblocks",                     "-Wno-arc-retain-cycles", "-Wno-objc-circular-container",
            "-Wno-incomplete-implementation", "-fsanitize=address,undefined",
        });
        objc_sanitized_stress.addPrefixedDirectoryArg("-I", b.path("include"));
        objc_sanitized_stress.addFileArg(b.path("tests/objc_api_lifetime_stress.m"));
        objc_sanitized_stress.addFileArg(b.path("src/objc_bridge.m"));
        objc_sanitized_stress.addArtifactArg(lib);
        objc_sanitized_stress.addArgs(&.{ "-lffi", "-framework", "Foundation", "-o" });
        const objc_sanitized_executable = objc_sanitized_stress.addOutputFileArg("objc-api-lifetime-sanitized");
        const run_objc_sanitized_stress = b.addSystemCommand(&.{"env"});
        run_objc_sanitized_stress.addFileArg(objc_sanitized_executable);
        const objc_sanitize_step = b.step("test-objc-api-sanitize", "Run Objective-C lifetime stress under ASan and UBSan");
        objc_sanitize_step.dependOn(&run_objc_sanitized_stress.step);

        const objc_leak_stress = b.addSystemCommand(&.{ "leaks", "-q", "--atExit", "--" });
        objc_leak_stress.addArtifactArg(objc_lifetime_stress);
        objc_leak_stress.step.dependOn(&objc_api_audit_cmd.step);
        const objc_leak_step = b.step("test-objc-api-leaks", "Run Objective-C lifetime stress under the macOS leak checker");
        objc_leak_step.dependOn(&objc_leak_stress.step);

        const objc_fault_injection = b.addSystemCommand(&.{
            "xcrun",                          "--sdk",                               "macosx", "clang", "-fobjc-arc", "-fblocks",
            "-Wno-incomplete-implementation", "-DZJS_OBJC_BRIDGE_FAULT_INJECTION=1",
        });
        objc_fault_injection.addPrefixedDirectoryArg("-I", b.path("include"));
        objc_fault_injection.addFileArg(b.path("tests/objc_api_fault_injection.m"));
        objc_fault_injection.addFileArg(b.path("src/objc_bridge.m"));
        objc_fault_injection.addArtifactArg(lib);
        objc_fault_injection.addArgs(&.{ "-lffi", "-framework", "Foundation", "-o" });
        const objc_fault_executable = objc_fault_injection.addOutputFileArg("objc-api-fault-injection");
        const run_objc_fault_injection = b.addSystemCommand(&.{"env"});
        run_objc_fault_injection.addFileArg(objc_fault_executable);
        const objc_fault_step = b.step("test-objc-api-faults", "Inject Objective-C bridge allocation and registration failures");
        objc_fault_step.dependOn(&run_objc_fault_injection.step);

        const objc_jsc_diff_cmd = b.addSystemCommand(&.{ "python3", "tools/objc-api-jsc-diff.py" });
        objc_jsc_diff_cmd.addFileArg(installed_library.?);
        const objc_jsc_diff_step = b.step("objc-api-jsc-diff", "Compare Objective-C bridge behavior with pinned system JSC");
        objc_jsc_diff_step.dependOn(&objc_jsc_diff_cmd.step);

        const objc_evidence_step = b.step("test-objc-api-evidence", "Run the complete Objective-C bridge evidence matrix");
        objc_evidence_step.dependOn(&objc_header_smoke.step);
        objc_evidence_step.dependOn(&run_objc_runtime_smoke.step);
        objc_evidence_step.dependOn(&objc_jsc_diff_cmd.step);
        objc_evidence_step.dependOn(&run_objc_lifetime_stress.step);
        objc_evidence_step.dependOn(&run_objc_sanitized_stress.step);
        objc_evidence_step.dependOn(&objc_leak_stress.step);
        objc_evidence_step.dependOn(&run_objc_fault_injection.step);
    }

    const c_api_c_smoke = b.addExecutable(.{
        .name = "c-api-smoke-c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_api_c_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/c_api_smoke.c") });
    c_api_c_smoke.root_module.addIncludePath(b.path("include"));
    c_api_c_smoke.root_module.linkLibrary(lib);
    const run_c_api_c_smoke = b.addRunArtifact(c_api_c_smoke);
    run_c_api_c_smoke.step.dependOn(&c_api_audit_cmd.step);

    const c_api_cpp_smoke = b.addExecutable(.{
        .name = "c-api-smoke-cpp",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true }),
    });
    c_api_cpp_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/c_api_smoke.cpp") });
    c_api_cpp_smoke.root_module.addIncludePath(b.path("include"));
    c_api_cpp_smoke.root_module.linkLibrary(lib);
    const run_c_api_cpp_smoke = b.addRunArtifact(c_api_cpp_smoke);
    run_c_api_cpp_smoke.step.dependOn(&c_api_audit_cmd.step);

    const c_api_inspector_smoke = b.addExecutable(.{
        .name = "c-api-inspector-smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_api_inspector_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/c_api_inspector_smoke.c") });
    c_api_inspector_smoke.root_module.addIncludePath(b.path("include"));
    c_api_inspector_smoke.root_module.linkLibrary(lib);
    const run_c_api_inspector_smoke = b.addRunArtifact(c_api_inspector_smoke);
    run_c_api_inspector_smoke.step.dependOn(&c_api_audit_cmd.step);

    const c_api_test_step = b.step("test-c-api", "Compile, link, and run C and C++ public-ABI hosts");
    c_api_test_step.dependOn(&run_c_api_c_smoke.step);
    c_api_test_step.dependOn(&run_c_api_cpp_smoke.step);
    c_api_test_step.dependOn(&run_c_api_inspector_smoke.step);

    const home_public_abi_fixture = b.addExecutable(.{
        .name = "home-public-abi-7ed99c02",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_public_c_7ed99c02.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    home_public_abi_fixture.root_module.linkLibrary(lib);
    const run_home_public_abi_fixture = b.addRunArtifact(home_public_abi_fixture);
    run_home_public_abi_fixture.step.dependOn(&home_public_abi_audit_cmd.step);
    const home_public_abi_test_step = b.step(
        "test-home-public-abi",
        "Compile, link, and run the pinned Home Zig C-ABI consumer",
    );
    home_public_abi_test_step.dependOn(&run_home_public_abi_fixture.step);

    const private_encoded_value_fixture = b.addExecutable(.{
        .name = "private-encoded-value-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_encoded_value_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    const run_private_encoded_value_fixture = b.addRunArtifact(private_encoded_value_fixture);
    const private_encoded_value_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/private_abi/encoded_value.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_private_encoded_value_tests = b.addRunArtifact(private_encoded_value_tests);
    const private_encoded_value_step = b.step(
        "test-private-abi-value",
        "Verify the pinned JSC64 EncodedJSValue boundary codec",
    );
    private_encoded_value_step.dependOn(&run_private_encoded_value_fixture.step);
    private_encoded_value_step.dependOn(&run_private_encoded_value_tests.step);

    const home_private_value_fixture = b.addExecutable(.{
        .name = "home-private-value-shims",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_private_value_shims.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_private_value_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_value_fixture = b.addRunArtifact(home_private_value_fixture);
    run_home_private_value_fixture.step.dependOn(&home_private_abi_audit_cmd.step);
    const home_private_abi_test_step = b.step(
        "test-home-private-abi",
        "Compile, link, and run implemented Home private-ABI slices",
    );
    home_private_abi_test_step.dependOn(&run_home_private_value_fixture.step);

    const bun_private_sql_structure_fixture = b.addExecutable(.{
        .name = "bun-private-sql-structure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_sql_structure.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = tsan,
        }),
    });
    bun_private_sql_structure_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_sql_structure_fixture = b.addRunArtifact(bun_private_sql_structure_fixture);
    run_bun_private_sql_structure_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_sql_structure_test_step = b.step(
        "test-bun-private-sql-structure",
        "Compile, link, and run Bun's private SQL Structure boundary",
    );
    bun_private_sql_structure_test_step.dependOn(&run_bun_private_sql_structure_fixture.step);

    const home_private_global_lifecycle_fixture = b.addExecutable(.{
        .name = "home-private-global-lifecycle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_private_global_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = tsan,
        }),
    });
    home_private_global_lifecycle_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_global_lifecycle_fixture = b.addRunArtifact(home_private_global_lifecycle_fixture);
    run_home_private_global_lifecycle_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_global_lifecycle_fixture = b.addExecutable(.{
        .name = "bun-private-global-lifecycle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_global_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = tsan,
        }),
    });
    bun_private_global_lifecycle_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_global_lifecycle_fixture = b.addRunArtifact(bun_private_global_lifecycle_fixture);
    run_bun_private_global_lifecycle_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_global_lifecycle_test_step = b.step(
        "test-private-global-lifecycle",
        "Compile, link, and run both pinned global-object lifecycle boundaries",
    );
    private_global_lifecycle_test_step.dependOn(&run_home_private_global_lifecycle_fixture.step);
    private_global_lifecycle_test_step.dependOn(&run_bun_private_global_lifecycle_fixture.step);

    const home_private_process_initialization_fixture = b.addExecutable(.{
        .name = "home-private-process-initialization",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_private_process_initialization.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = tsan,
        }),
    });
    home_private_process_initialization_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_process_initialization_fixture = b.addRunArtifact(home_private_process_initialization_fixture);
    run_home_private_process_initialization_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_process_initialization_fixture = b.addExecutable(.{
        .name = "bun-private-process-initialization",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_process_initialization.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = tsan,
        }),
    });
    bun_private_process_initialization_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_process_initialization_fixture = b.addRunArtifact(bun_private_process_initialization_fixture);
    run_bun_private_process_initialization_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_process_initialization_test_step = b.step(
        "test-private-process-initialization",
        "Compile, link, and run both pinned process initialization boundaries",
    );
    private_process_initialization_test_step.dependOn(&run_home_private_process_initialization_fixture.step);
    private_process_initialization_test_step.dependOn(&run_bun_private_process_initialization_fixture.step);

    const bun_private_abort_signal_fixture = b.addExecutable(.{
        .name = "bun-private-abort-signal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_abort_signal.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bun_private_abort_signal_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_abort_signal_fixture = b.addRunArtifact(bun_private_abort_signal_fixture);
    run_bun_private_abort_signal_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_abort_signal_test_step = b.step(
        "test-bun-private-abort-signal",
        "Compile, link, and run Bun's private AbortSignal timeout boundary",
    );
    bun_private_abort_signal_test_step.dependOn(&run_bun_private_abort_signal_fixture.step);

    const bun_private_cached_bytecode_fixture = b.addExecutable(.{
        .name = "bun-private-cached-bytecode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_cached_bytecode.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bun_private_cached_bytecode_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_cached_bytecode_fixture = b.addRunArtifact(bun_private_cached_bytecode_fixture);
    run_bun_private_cached_bytecode_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_cached_bytecode_test_step = b.step(
        "test-bun-private-cached-bytecode",
        "Compile, link, and run Bun's private cached-bytecode boundary",
    );
    bun_private_cached_bytecode_test_step.dependOn(&run_bun_private_cached_bytecode_fixture.step);

    const bun_private_vm_lifecycle_fixture = b.addExecutable(.{
        .name = "bun-private-vm-lifecycle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_vm_lifecycle.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_vm_lifecycle_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_vm_lifecycle_fixture = b.addRunArtifact(bun_private_vm_lifecycle_fixture);
    run_bun_private_vm_lifecycle_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_vm_lifecycle_test_step = b.step(
        "test-bun-private-vm-lifecycle",
        "Compile, link, and run Bun's private VM lifecycle boundary",
    );
    bun_private_vm_lifecycle_test_step.dependOn(&run_bun_private_vm_lifecycle_fixture.step);

    const home_private_hot_reload_fixture = b.addExecutable(.{
        .name = "home-private-hot-reload",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_hot_reload.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_private_hot_reload_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_hot_reload_fixture = b.addRunArtifact(home_private_hot_reload_fixture);
    run_home_private_hot_reload_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_hot_reload_fixture = b.addExecutable(.{
        .name = "bun-private-hot-reload",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_hot_reload.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_hot_reload_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_hot_reload_fixture = b.addRunArtifact(bun_private_hot_reload_fixture);
    run_bun_private_hot_reload_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_hot_reload_test_step = b.step(
        "test-private-hot-reload",
        "Compile, link, and run both pinned hot-reload inspector boundaries",
    );
    private_hot_reload_test_step.dependOn(&run_home_private_hot_reload_fixture.step);
    private_hot_reload_test_step.dependOn(&run_bun_private_hot_reload_fixture.step);

    const home_private_process_signal_fixture = b.addExecutable(.{
        .name = "home-private-process-signal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_process_signal.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    home_private_process_signal_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_process_signal_fixture = b.addRunArtifact(home_private_process_signal_fixture);
    run_home_private_process_signal_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_process_signal_fixture = b.addExecutable(.{
        .name = "bun-private-process-signal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_process_signal.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bun_private_process_signal_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_process_signal_fixture = b.addRunArtifact(bun_private_process_signal_fixture);
    run_bun_private_process_signal_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_process_signal_test_step = b.step(
        "test-private-process-signal",
        "Compile, link, and run both pinned process-signal boundaries",
    );
    private_process_signal_test_step.dependOn(&run_home_private_process_signal_fixture.step);
    private_process_signal_test_step.dependOn(&run_bun_private_process_signal_fixture.step);

    const home_private_script_execution_context_fixture = b.addExecutable(.{
        .name = "home-private-script-execution-context",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_private_script_execution_context.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_private_script_execution_context_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_script_execution_context_fixture = b.addRunArtifact(home_private_script_execution_context_fixture);
    run_home_private_script_execution_context_fixture.step.dependOn(&home_private_abi_audit_cmd.step);
    const home_private_script_execution_context_test_step = b.step(
        "test-home-private-script-execution-context",
        "Compile, link, and run Home's ScriptExecutionContext registry boundary",
    );
    home_private_script_execution_context_test_step.dependOn(&run_home_private_script_execution_context_fixture.step);

    const home_private_module_registry_shims_fixture = b.addExecutable(.{
        .name = "home-private-module-registry-shims",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_module_registry_shims.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_private_module_registry_shims_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_module_registry_shims_fixture = b.addRunArtifact(home_private_module_registry_shims_fixture);
    run_home_private_module_registry_shims_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_module_registry_shims_fixture = b.addExecutable(.{
        .name = "bun-private-module-registry-shims",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_module_registry_shims.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_module_registry_shims_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_module_registry_shims_fixture = b.addRunArtifact(bun_private_module_registry_shims_fixture);
    run_bun_private_module_registry_shims_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_module_registry_shims_test_step = b.step(
        "test-private-module-registry-shims",
        "Compile, link, and run both retired module-registry snapshot shims",
    );
    private_module_registry_shims_test_step.dependOn(&run_home_private_module_registry_shims_fixture.step);
    private_module_registry_shims_test_step.dependOn(&run_bun_private_module_registry_shims_fixture.step);

    const home_private_heap_snapshot_fixture = b.addExecutable(.{
        .name = "home-private-heap-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_private_heap_snapshot.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    home_private_heap_snapshot_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_heap_snapshot_fixture = b.addRunArtifact(home_private_heap_snapshot_fixture);
    run_home_private_heap_snapshot_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_heap_snapshot_fixture = b.addExecutable(.{
        .name = "bun-private-heap-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_heap_snapshot.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    bun_private_heap_snapshot_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_heap_snapshot_fixture = b.addRunArtifact(bun_private_heap_snapshot_fixture);
    run_bun_private_heap_snapshot_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_heap_snapshot_test_step = b.step(
        "test-private-heap-snapshot",
        "Compile, link, and run both pinned heap-snapshot ownership profiles",
    );
    private_heap_snapshot_test_step.dependOn(&run_home_private_heap_snapshot_fixture.step);
    private_heap_snapshot_test_step.dependOn(&run_bun_private_heap_snapshot_fixture.step);

    const home_private_cpu_profile_fixture = b.addExecutable(.{
        .name = "home-private-cpu-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/home_private_cpu_profile.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    home_private_cpu_profile_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_cpu_profile_fixture = b.addRunArtifact(home_private_cpu_profile_fixture);
    run_home_private_cpu_profile_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_cpu_profile_fixture = b.addExecutable(.{
        .name = "bun-private-cpu-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_cpu_profile.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    bun_private_cpu_profile_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_cpu_profile_fixture = b.addRunArtifact(bun_private_cpu_profile_fixture);
    run_bun_private_cpu_profile_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_cpu_profile_test_step = b.step(
        "test-private-cpu-profile",
        "Compile, link, and run both pinned CPU-profiler ownership profiles",
    );
    private_cpu_profile_test_step.dependOn(&run_home_private_cpu_profile_fixture.step);
    private_cpu_profile_test_step.dependOn(&run_bun_private_cpu_profile_fixture.step);

    const home_private_readable_stream_fixture = b.addExecutable(.{
        .name = "home-private-readable-stream",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_readable_stream.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    home_private_readable_stream_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_readable_stream_fixture = b.addRunArtifact(home_private_readable_stream_fixture);
    run_home_private_readable_stream_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_readable_stream_fixture = b.addExecutable(.{
        .name = "bun-private-readable-stream",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_readable_stream.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    bun_private_readable_stream_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_readable_stream_fixture = b.addRunArtifact(bun_private_readable_stream_fixture);
    run_bun_private_readable_stream_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_readable_stream_test_step = b.step(
        "test-private-readable-stream",
        "Compile, link, and run both pinned ReadableStream consumer profiles",
    );
    private_readable_stream_test_step.dependOn(&run_home_private_readable_stream_fixture.step);
    private_readable_stream_test_step.dependOn(&run_bun_private_readable_stream_fixture.step);

    const home_private_wasm_streaming_fixture = b.addExecutable(.{
        .name = "home-private-wasm-streaming-compiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_wasm_streaming_compiler.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    home_private_wasm_streaming_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_wasm_streaming_fixture = b.addRunArtifact(home_private_wasm_streaming_fixture);
    run_home_private_wasm_streaming_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_wasm_streaming_fixture = b.addExecutable(.{
        .name = "bun-private-wasm-streaming-compiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_wasm_streaming_compiler.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .link_libc = true,
        }),
    });
    bun_private_wasm_streaming_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_wasm_streaming_fixture = b.addRunArtifact(bun_private_wasm_streaming_fixture);
    run_bun_private_wasm_streaming_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_wasm_streaming_test_step = b.step(
        "test-private-wasm-streaming-compiler",
        "Compile, link, and run both pinned Wasm StreamingCompiler profiles",
    );
    private_wasm_streaming_test_step.dependOn(&run_home_private_wasm_streaming_fixture.step);
    private_wasm_streaming_test_step.dependOn(&run_bun_private_wasm_streaming_fixture.step);

    const home_private_error_code_fixture = b.addExecutable(.{
        .name = "home-private-error-code",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_error_code.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_private_error_code_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_error_code_fixture = b.addRunArtifact(home_private_error_code_fixture);
    run_home_private_error_code_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_error_code_fixture = b.addExecutable(.{
        .name = "bun-private-error-code",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_error_code.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_error_code_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_error_code_fixture = b.addRunArtifact(bun_private_error_code_fixture);
    run_bun_private_error_code_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_error_code_test_step = b.step(
        "test-private-error-code",
        "Compile, link, and run both pinned ErrorCode diagnostic boundaries",
    );
    private_error_code_test_step.dependOn(&run_home_private_error_code_fixture.step);
    private_error_code_test_step.dependOn(&run_bun_private_error_code_fixture.step);

    const home_private_inspector_agents_fixture = b.addExecutable(.{
        .name = "home-private-inspector-agents",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_inspector_agents.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    home_private_inspector_agents_fixture.root_module.linkLibrary(home_private_lib);
    const run_home_private_inspector_agents_fixture = b.addRunArtifact(home_private_inspector_agents_fixture);
    run_home_private_inspector_agents_fixture.step.dependOn(&home_private_abi_audit_cmd.step);

    const bun_private_inspector_agents_fixture = b.addExecutable(.{
        .name = "bun-private-inspector-agents",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_inspector_agents.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_inspector_agents_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_inspector_agents_fixture = b.addRunArtifact(bun_private_inspector_agents_fixture);
    run_bun_private_inspector_agents_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const private_inspector_agents_test_step = b.step(
        "test-private-inspector-agents",
        "Compile, link, and run both pinned lifecycle/test inspector-agent boundaries",
    );
    private_inspector_agents_test_step.dependOn(&run_home_private_inspector_agents_fixture.step);
    private_inspector_agents_test_step.dependOn(&run_bun_private_inspector_agents_fixture.step);

    const bun_private_property_iterator_fixture = b.addExecutable(.{
        .name = "bun-private-property-iterator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_property_iterator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_property_iterator_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_property_iterator_fixture = b.addRunArtifact(bun_private_property_iterator_fixture);
    run_bun_private_property_iterator_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_property_iterator_test_step = b.step(
        "test-bun-private-property-iterator",
        "Compile, link, and run Bun's private property-iterator boundary",
    );
    bun_private_property_iterator_test_step.dependOn(&run_bun_private_property_iterator_fixture.step);

    const bun_private_c_api_extensions_fixture = b.addExecutable(.{
        .name = "bun-private-c-api-extensions",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_c_api_extensions.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_c_api_extensions_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_c_api_extensions_fixture = b.addRunArtifact(bun_private_c_api_extensions_fixture);
    run_bun_private_c_api_extensions_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_c_api_extensions_test_step = b.step(
        "test-bun-private-c-api-extensions",
        "Compile, link, and run Bun's private call/proxy/async-context extensions",
    );
    bun_private_c_api_extensions_test_step.dependOn(&run_bun_private_c_api_extensions_fixture.step);

    const bun_private_array_buffer_fixture = b.addExecutable(.{
        .name = "bun-private-array-buffer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_array_buffer.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    bun_private_array_buffer_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_array_buffer_fixture = b.addRunArtifact(bun_private_array_buffer_fixture);
    run_bun_private_array_buffer_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_array_buffer_test_step = b.step(
        "test-bun-private-array-buffer",
        "Compile, link, and run Bun's private ArrayBuffer ownership boundary",
    );
    bun_private_array_buffer_test_step.dependOn(&run_bun_private_array_buffer_fixture.step);

    const bun_private_dom_form_data_fixture = b.addExecutable(.{
        .name = "bun-private-dom-form-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_dom_form_data.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_dom_form_data_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_dom_form_data_fixture = b.addRunArtifact(bun_private_dom_form_data_fixture);
    run_bun_private_dom_form_data_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_dom_form_data_test_step = b.step(
        "test-bun-private-dom-form-data",
        "Compile, link, and run Bun's private DOMFormData boundary",
    );
    bun_private_dom_form_data_test_step.dependOn(&run_bun_private_dom_form_data_fixture.step);

    const bun_private_fetch_headers_fixture = b.addExecutable(.{
        .name = "bun-private-fetch-headers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_fetch_headers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_fetch_headers_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_fetch_headers_fixture = b.addRunArtifact(bun_private_fetch_headers_fixture);
    run_bun_private_fetch_headers_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_fetch_headers_bridge_absent_fixture = b.addExecutable(.{
        .name = "bun-private-fetch-headers-bridge-absent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/bun_private_fetch_headers_bridge_absent.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bun_private_fetch_headers_bridge_absent_fixture.root_module.linkLibrary(bun_private_lib);
    const run_bun_private_fetch_headers_bridge_absent_fixture = b.addRunArtifact(bun_private_fetch_headers_bridge_absent_fixture);
    run_bun_private_fetch_headers_bridge_absent_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const bun_private_fetch_headers_test_step = b.step(
        "test-bun-private-fetch-headers",
        "Compile, link, and run Bun's private FetchHeaders boundary",
    );
    bun_private_fetch_headers_test_step.dependOn(&run_bun_private_fetch_headers_fixture.step);
    bun_private_fetch_headers_test_step.dependOn(&run_bun_private_fetch_headers_bridge_absent_fixture.step);

    const repeat_home_private_value_fixture = b.addRunArtifact(home_private_value_fixture);
    repeat_home_private_value_fixture.step.dependOn(&home_private_abi_audit_cmd.step);
    const repeat_bun_private_fetch_headers_fixture = b.addRunArtifact(bun_private_fetch_headers_fixture);
    repeat_bun_private_fetch_headers_fixture.step.dependOn(&bun_private_abi_audit_cmd.step);
    const mixed_private_abi_test_step = b.step(
        "test-private-abi-mixed-profiles",
        "Run repeated Home and Bun private fixtures together with isolated tag profiles",
    );
    mixed_private_abi_test_step.dependOn(&run_home_private_value_fixture.step);
    mixed_private_abi_test_step.dependOn(&repeat_home_private_value_fixture.step);
    mixed_private_abi_test_step.dependOn(&run_bun_private_fetch_headers_fixture.step);
    mixed_private_abi_test_step.dependOn(&repeat_bun_private_fetch_headers_fixture.step);

    const private_jstype_fixture = b.addExecutable(.{
        .name = "private-jstype-shims",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/private_jstype_shims.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    private_jstype_fixture.root_module.addOptions("private_abi_options", private_abi_options);
    private_jstype_fixture.root_module.linkLibrary(lib);
    const run_private_jstype_fixture = b.addRunArtifact(private_jstype_fixture);
    run_private_jstype_fixture.step.dependOn(&private_jstype_abi_audit_cmd.step);
    run_private_jstype_fixture.step.dependOn(if (private_abi_is_bun)
        &bun_private_abi_audit_cmd.step
    else
        &home_private_abi_audit_cmd.step);
    const private_jstype_test_step = b.step(
        "test-private-jstype",
        "Compile, link, and run the selected private JSType profile",
    );
    private_jstype_test_step.dependOn(&run_private_jstype_fixture.step);

    const c_api_value_diff = b.addExecutable(.{
        .name = "c-api-value-diff-zig-js",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_api_value_diff.root_module.addCSourceFile(.{ .file = b.path("tests/c_api_value_diff.c") });
    c_api_value_diff.root_module.addIncludePath(b.path("include"));
    c_api_value_diff.root_module.linkLibrary(lib);
    const c_api_context_group_diff = b.addExecutable(.{
        .name = "c-api-context-group-diff-zig-js",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    c_api_context_group_diff.root_module.addCSourceFile(.{ .file = b.path("tests/c_api_context_group_diff.c") });
    c_api_context_group_diff.root_module.addIncludePath(b.path("include"));
    c_api_context_group_diff.root_module.linkLibrary(lib);
    const c_api_jsc_diff_cmd = b.addSystemCommand(&.{ "python3", "tools/c-api-jsc-diff.py" });
    c_api_jsc_diff_cmd.addArtifactArg(c_api_value_diff);
    c_api_jsc_diff_cmd.addArtifactArg(c_api_context_group_diff);
    const c_api_jsc_diff_step = b.step("c-api-jsc-diff", "Compare the completed value C API against pinned system JSC");
    c_api_jsc_diff_step.dependOn(&c_api_jsc_diff_cmd.step);

    const wasm_exception_jsc_diff = b.addExecutable(.{
        .name = "wasm-exception-jsc-diff-zig-js",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    wasm_exception_jsc_diff.root_module.addCSourceFile(.{ .file = b.path("tests/wasm_exception_jsc_diff.c") });
    wasm_exception_jsc_diff.root_module.addIncludePath(b.path("include"));
    wasm_exception_jsc_diff.root_module.linkLibrary(lib);
    const wasm_exception_jsc_diff_cmd = b.addSystemCommand(&.{ "python3", "tools/wasm-exception-jsc-diff.py" });
    wasm_exception_jsc_diff_cmd.addArtifactArg(wasm_exception_jsc_diff);
    const wasm_exception_jsc_diff_step = b.step(
        "wasm-exception-jsc-diff",
        "Compare the WebAssembly exception JavaScript API with system JSC",
    );
    wasm_exception_jsc_diff_step.dependOn(&wasm_exception_jsc_diff_cmd.step);

    // Unit tests over the root module (engine core + C-API).
    // `-Dtsan` builds them under ThreadSanitizer — the concurrency gate for
    // the agent/worker/waiter machinery (issue #1).
    const test_filter = b.option([]const u8, "test-filter", "Only run unit tests whose name contains this substring");
    const unit_shard_index = b.option(usize, "unit-shard-index", "Run only this zero-based unit-test shard index") orelse null;
    const unit_shard_count = b.option(usize, "unit-shard-count", "Split unit tests across this many shards") orelse null;
    const tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .test_runner = .{
            .path = b.path("tools/unit_test_runner.zig"),
            .mode = .simple,
        },
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
    tests.root_module.addOptions("private_abi_options", private_abi_options);
    const wasm_test_options = b.addOptions();
    wasm_test_options.addOption([]const u8, "threads_benchmark_source", @embedFile("bench/wasm_threads_comparison.js"));
    tests.root_module.addOptions("wasm_test_options", wasm_test_options);
    const run_tests = b.addRunArtifact(tests);
    if (unit_shard_count) |count| {
        run_tests.setEnvironmentVariable("UNIT_SHARD_INDEX", b.fmt("{d}", .{unit_shard_index orelse 0}));
        run_tests.setEnvironmentVariable("UNIT_SHARD_COUNT", b.fmt("{d}", .{count}));
    }

    const test_step = b.step("test", "Run zig-js unit tests");
    test_step.dependOn(&run_tests.step);

    // Small production JIT test root for tight development loops. Unlike
    // `-Dtest-filter` on the full root, distinct filters here do not relink the
    // Context/C-API/Worker/world-sized integration artifact (#53). It uses the
    // same target, optimization, sanitizer, dependencies, and test runner;
    // the full step remains the integration gate.
    const focused_jit_tests = b.addTest(.{
        .filters = if (test_filter) |f| &.{f} else &.{},
        .test_runner = .{
            .path = b.path("tools/unit_test_runner.zig"),
            .mode = .simple,
        },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/focused_jit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "gc", .module = gc_mod },
            },
        }),
    });
    focused_jit_tests.root_module.addOptions("private_abi_options", private_abi_options);
    const run_focused_jit_tests = b.addRunArtifact(focused_jit_tests);
    const focused_jit_step = b.step("test-jit", "Run focused production baseline-JIT tests");
    focused_jit_step.dependOn(&run_focused_jit_tests.step);

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

    // Upstream WebAssembly wg-1.0 corpus evaluator. `tools/wasm-spec.py`
    // converts each pinned WAST file with the revision-matched WABT tool and
    // invokes this executable in an isolated Context. Keeping conversion in the
    // orchestrator makes every command and non-applicable text-format assertion
    // visible in the checked-in machine-readable inventory.
    const wasm_spec_eval = b.addExecutable(.{
        .name = "wasm-spec-eval",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/wasm_spec_eval.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    const wasm_spec_eval_install = b.addInstallArtifact(wasm_spec_eval, .{});
    const wasm_spec_eval_step = b.step("wasm-spec-eval", "Build the upstream WebAssembly corpus evaluator");
    wasm_spec_eval_step.dependOn(&wasm_spec_eval_install.step);
    // Native WebAssembly wg-1.0 spec runner: `zig build wasm-spec` executes
    // the packed upstream suite (tests/wasm/spec/{manifest.json,modules.bin})
    // through the engine's real JS WebAssembly API and prints the
    // machine-readable pass/fail/skip inventory. The runner re-executes itself
    // once per .wast file (WASM_SPEC_WORKER=<file>) for crash isolation.
    // `-Dwasm-spec-filter=<substr>` runs only matching files;
    // `-Dwasm-spec-out=<path>` also writes the aggregate inventory JSON.
    // Compatibility: the CI smoke gate invokes this step with
    // `-Dwast2json=<path>` (accepted, unused — the packed artifacts already
    // embed converter output, so no converter is needed at run time) and
    // `-Dwasm-spec-inventory=<path>` (alias of `-Dwasm-spec-out`).
    const wasm_spec_filter = b.option([]const u8, "wasm-spec-filter", "wasm-spec: run only files whose name contains this substring") orelse "";
    const wasm_spec_out_compat = b.option([]const u8, "wasm-spec-inventory", "wasm-spec: alias of -Dwasm-spec-out (CI smoke gate compatibility)") orelse "";
    _ = b.option([]const u8, "wast2json", "wasm-spec: accepted for CI compatibility; the packed runner needs no converter at run time") orelse "";
    const wasm_spec_out = b.option([]const u8, "wasm-spec-out", "wasm-spec: also write the aggregate inventory JSON to this path") orelse wasm_spec_out_compat;
    const wasm_spec_options = b.addOptions();
    wasm_spec_options.addOption([]const u8, "filter", wasm_spec_filter);
    wasm_spec_options.addOption([]const u8, "out", wasm_spec_out);
    const wasm_spec = b.addExecutable(.{
        .name = "wasm-spec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/wasm_spec.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    wasm_spec.root_module.addOptions("build_options", wasm_spec_options);
    const run_wasm_spec = b.addRunArtifact(wasm_spec);
    const wasm_spec_step = b.step("wasm-spec", "Run the pinned WebAssembly wg-1.0 spec suite and emit the pass/fail/skip inventory");
    wasm_spec_step.dependOn(&run_wasm_spec.step);
    const wasm_spec_install = b.addInstallArtifact(wasm_spec, .{});
    const wasm_spec_bin_step = b.step("wasm-spec-bin", "Build the wasm-spec runner exe only (no run)");
    wasm_spec_bin_step.dependOn(&wasm_spec_install.step);

    const wasm_core_3_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/wasm-spec.py",
        "--profile",
        "core-3",
        "--converter",
        b.option([]const u8, "wasm-core-3-converter", "Path to pinned wasm-tools 1.253.0") orelse "wasm-tools",
    });
    if (b.option([]const u8, "wasm-core-3-filter", "Run only Core 3 corpus paths containing this substring")) |filter| {
        wasm_core_3_cmd.addArgs(&.{ "--filter", filter });
    }
    if (b.option([]const u8, "wasm-core-3-inventory", "Core 3 inventory output path")) |inventory| {
        wasm_core_3_cmd.addArgs(&.{ "--inventory", inventory });
    }
    wasm_core_3_cmd.step.dependOn(&wasm_spec_eval_install.step);
    const wasm_core_3_step = b.step(
        "wasm-core-3",
        "Run the exact pinned WebAssembly Core 3 corpus and emit its inventory",
    );
    wasm_core_3_step.dependOn(&wasm_core_3_cmd.step);

    const wasm_core_main_shadow_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/wasm-spec.py",
        "--profile",
        "core-main-shadow",
        "--spec-root",
        b.option([]const u8, "wasm-core-main-shadow-root", "Path to the exact pinned upstream-main WebAssembly spec checkout") orelse "wasm-spec-main",
        "--converter",
        b.option([]const u8, "wasm-core-main-shadow-converter", "Path to pinned wasm-tools 1.253.0") orelse "wasm-tools",
    });
    if (b.option(bool, "wasm-core-main-shadow-changed-only", "Run only Core files changed from the stable WG3 baseline") orelse false) {
        wasm_core_main_shadow_cmd.addArg("--changed-only");
    }
    if (b.option([]const u8, "wasm-core-main-shadow-filter", "Run only upstream-main Core paths containing this substring")) |filter| {
        wasm_core_main_shadow_cmd.addArgs(&.{ "--filter", filter });
    }
    if (b.option([]const u8, "wasm-core-main-shadow-inventory", "Upstream-main shadow inventory output path")) |inventory| {
        wasm_core_main_shadow_cmd.addArgs(&.{ "--inventory", inventory });
    }
    wasm_core_main_shadow_cmd.step.dependOn(&wasm_spec_eval_install.step);
    const wasm_core_main_shadow_step = b.step(
        "wasm-core-main-shadow",
        "Run the exact-SHA WebAssembly upstream-main shadow corpus without changing stable scores",
    );
    wasm_core_main_shadow_step.dependOn(&wasm_core_main_shadow_cmd.step);

    const wasm_feature_profiles_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/wasm-feature-profiles.py",
    });
    const wasm_conformance_matrix_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/wasm-conformance-matrix.py",
    });
    const wasm_feature_profiles_step = b.step(
        "wasm-feature-profiles-check",
        "Validate the pinned WebAssembly feature/profile registry",
    );
    wasm_feature_profiles_step.dependOn(&wasm_feature_profiles_cmd.step);
    wasm_feature_profiles_step.dependOn(&wasm_conformance_matrix_cmd.step);

    const release_compatibility_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/release-compatibility.py",
    });
    const release_compatibility_step = b.step(
        "release-compatibility-check",
        "Validate the #134 compatibility matrix and README removal gate",
    );
    release_compatibility_step.dependOn(&release_compatibility_cmd.step);

    const gc_relocation_inventory_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/gc-relocation-inventory.py",
    });
    const gc_relocation_inventory_step = b.step(
        "gc-relocation-inventory-check",
        "Validate the moving-GC pointer and relocation contract",
    );
    gc_relocation_inventory_step.dependOn(&gc_relocation_inventory_cmd.step);

    const release_ready_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/release-compatibility.py",
        "--release",
    });
    const release_ready_step = b.step(
        "release-ready",
        "Require every #134 compatibility gate to be green",
    );
    release_ready_step.dependOn(&release_ready_cmd.step);

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

    // VM/concurrency semantic gates use an executable so importing the
    // production interpreter does not recursively link every inline unit test.
    // `-Dtest-filter` is a runtime case selector here, so changing it reuses
    // the same compiled binary instead of creating another cache-heavy image.
    const focused_engine_tests = b.addExecutable(.{
        .name = "focused-engine-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/focused_engine_tests.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "js", .module = threads_js_mod }},
        }),
    });
    for ([_]struct { step_name: []const u8, suite: []const u8, description: []const u8 }{
        .{ .step_name = "test-vm", .suite = "vm", .description = "Run focused production bytecode/VM semantic tests" },
        .{ .step_name = "test-concurrency", .suite = "concurrency", .description = "Run focused production concurrency semantic tests" },
    }) |spec| {
        const run_focused_engine_tests = b.addRunArtifact(focused_engine_tests);
        run_focused_engine_tests.addArg(spec.suite);
        if (test_filter) |filter| run_focused_engine_tests.addArg(filter);
        const focused_step = b.step(spec.step_name, spec.description);
        focused_step.dependOn(&run_focused_engine_tests.step);
    }
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
    const threads_shard_index = b.option(usize, "threads-shard-index", "Run only this zero-based threads-test shard index") orelse null;
    const threads_shard_count = b.option(usize, "threads-shard-count", "Split threads-test cases across this many shards") orelse null;
    if (threads_parallel_js) {
        run_threads_test.addArg("parallel-js");
    }
    if (threads_sweep) {
        run_threads_test.addArg("sweep");
    } else if (threads_case) |case| {
        run_threads_test.addArgs(&.{ "one", case });
    }
    if (threads_shard_count) |count| {
        run_threads_test.addArgs(&.{
            "shard",
            b.fmt("{d}", .{threads_shard_index orelse 0}),
            b.fmt("{d}", .{count}),
        });
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
        "--check-inventory",
        "--self-test-inventory",
    });
    const threads_reference_audit_step = b.step("threads-reference-audit", "Audit remaining reference-only PR-249 files");
    threads_reference_audit_step.dependOn(&threads_reference_audit_cmd.step);

    const threads_reference_probes_cmd = b.addSystemCommand(&.{
        "python3",
        "tools/threads-reference-audit.py",
        "--fail-on-uncategorized",
        "--run-probes",
        "--expect-current-blockers",
        "--skip-timeout-probes",
        "--probe-timeout",
        "20",
    });
    const threads_reference_probes_step = b.step("threads-reference-probes", "Verify quick PR-249 reference-only promotion blockers");
    threads_reference_probes_step.dependOn(&threads_reference_probes_cmd.step);

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
    const fuzz_midgc = b.option(bool, "fuzz-midgc", "threadfuzz: mid-script parallel GC wait-pump, microtask churn, finalization asyncJoin/unregister cleanup, waitAsync/finalization cleanup, Condition.asyncWait/finalization cleanup, asyncHold throw/finalization cleanup, late asyncJoin fulfillment/rejection cleanup, creator-owned buffers plus script/module Worker clone/finalization cleanup, nested Thread asyncJoin cleanup, ThreadLocal lifecycle/finalization/termination cleanup and Thread.restrict lifecycle/finalization, sync-wait cleanup including property waitAsync timeout/live tickets plus script/module retained-SAB Worker overlap and same-primitive burst release, sync timeout exit, Atomics.Mutex.lockIfAvailable acquire/timeout cleanup, Atomics.Condition.wait notify/reacquire cleanup, asyncHold release/waiter cleanup, teardown-termination, promise-publication, script/module Worker/SAB cleanup, script/module Worker/thread finalization cleanup, Worker exception cleanup, Worker close/terminate drain/drop, script/module Worker terminate/finalization cleanup, script/module Worker Thread teardown cleanup, script/module Worker Condition.asyncWait teardown cleanup, script/module Worker waitAsync teardown cleanup, script/module Worker ThreadLocal/asyncHold teardown cleanup, and weak-collection cleanup profile") orelse false;
    const fuzz_lifecycle = b.option(bool, "fuzz-lifecycle", "threadfuzz: deterministic concurrent multi-context create/destroy, resizable ArrayBuffer/DataView no-GIL races, termination, pending reaction teardown, Worker/module-worker graph overlap, Worker/module-worker exception/finalization cleanup and script/module terminate/finalization plus terminate/thread teardown including script/module condition async plus script/module ThreadLocal/asyncHold/waiter teardown, ThreadLocal cleanup, ThreadLocal plus asyncHold release/waiter cleanup, and script/module waitAsync cleanup, Atomics.Mutex/Condition token waits plus lockIfAvailable acquire/timeout paths, script/module Worker/thread/finalization scheduling, asyncHold/Condition.asyncWait barging and cleanup, asyncHold throw/release/waiter cleanup, Promise microtask churn, late asyncJoin fulfillment/rejection cleanup, creator-owned buffer and script/module Worker clone/finalization lifetime, nested Thread asyncJoin cleanup, Thread.restrict/ThreadLocal isolation, Thread.restrict/ThreadLocal finalization cleanup, waitAsync/finalization cleanup, finalization cleanup/waiter/unregister, and exact script/module Worker close/terminate drain/drop lifecycle profile") orelse false;
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
    const diag_install = b.addInstallArtifact(diag, .{});
    const diag_bin_step = b.step("diag-bin", "Build the diagnostic runner exe only (no run)");
    diag_bin_step.dependOn(&diag_install.step);

    // THROWAWAY negative-axis (missing early-error) diagnostic.
    const negdiag = b.addExecutable(.{
        .name = "negdiag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("conformance/negdiag.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "js", .module = mod }},
        }),
    });
    negdiag.root_module.addOptions("build_options", t262_options);
    const negdiag_install = b.addInstallArtifact(negdiag, .{});
    const negdiag_bin_step = b.step("negdiag-bin", "Build the negative-axis diagnostic exe only (no run)");
    negdiag_bin_step.dependOn(&negdiag_install.step);

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

    // Reproducible engine comparison against the system JavaScriptCore. The
    // runners are deliberately separate executables so zig-js's JSC-shaped C
    // exports cannot interpose on the real framework symbols. The Python driver
    // only orchestrates runs, validates checksums, and renders raw/report data.
    const comparison_harness_test = b.addSystemCommand(&.{ "python3", "tools/test_benchmark_comparison.py" });
    const comparison_publication_test = b.addSystemCommand(&.{ "python3", "tools/test_benchmark_publication.py" });
    const generation_harness_test = b.addSystemCommand(&.{ "python3", "tools/test_gc_generation_benchmark.py" });
    const comparison_harness_test_step = b.step("benchmark-comparison-test", "Test benchmark matrix validation without running benchmarks");
    comparison_harness_test_step.dependOn(&comparison_harness_test.step);
    comparison_harness_test_step.dependOn(&comparison_publication_test.step);
    comparison_harness_test_step.dependOn(&generation_harness_test.step);

    const comparison_step = b.step("benchmark-comparison", "Compare zig-js direct/independent/shared throughput with system JavaScriptCore (macOS)");
    const comparison_bin_step = b.step("benchmark-comparison-bin", "Build the zig-js and system-JSC comparison runners (macOS)");
    if (target.result.os.tag == .macos) {
        const comparison_zig_js = b.addExecutable(.{
            .name = "bench-comparison-zig-js",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/comparison_zig_js.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
                .imports = &.{.{ .name = "js", .module = bench_js_mod }},
            }),
        });
        const comparison_jsc = b.addExecutable(.{
            .name = "bench-comparison-jsc",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/comparison_jsc.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        comparison_jsc.root_module.linkFramework("JavaScriptCore", .{});

        const run_comparison = b.addSystemCommand(&.{ "python3", "tools/benchmark-comparison.py" });
        run_comparison.addArtifactArg(comparison_zig_js);
        run_comparison.addArtifactArg(comparison_jsc);
        if (b.option(usize, "benchmark-comparison-samples", "Full comparison samples per matrix row")) |samples| {
            run_comparison.addArgs(&.{ "--samples", b.fmt("{d}", .{samples}) });
        }
        if (b.option([]const u8, "benchmark-comparison-lanes", "Comma-separated comparison lane counts above one")) |lanes| {
            run_comparison.addArgs(&.{ "--lanes", lanes });
        }
        if (b.option(bool, "benchmark-comparison-quick", "Run one reduced-size comparison sample for harness validation") orelse false)
            run_comparison.addArg("--quick");
        if (b.option([]const u8, "benchmark-comparison-raw-out", "Write raw comparison samples to this TSV path")) |path| {
            run_comparison.addArgs(&.{ "--raw-out", path });
        }
        if (b.option([]const u8, "benchmark-comparison-markdown-out", "Write the rendered comparison report to this Markdown path")) |path| {
            run_comparison.addArgs(&.{ "--markdown-out", path });
        }
        comparison_step.dependOn(&run_comparison.step);

        const run_wasm_threads_benchmark = b.addSystemCommand(&.{ "python3", "tools/wasm-threads-benchmark.py" });
        run_wasm_threads_benchmark.addArtifactArg(comparison_zig_js);
        run_wasm_threads_benchmark.addArtifactArg(comparison_jsc);
        if (b.option(usize, "wasm-threads-benchmark-samples", "WebAssembly Threads samples per matrix row")) |samples| {
            run_wasm_threads_benchmark.addArgs(&.{ "--samples", b.fmt("{d}", .{samples}) });
        }
        if (b.option([]const u8, "wasm-threads-benchmark-lanes", "Comma-separated even WebAssembly Threads worker counts")) |lanes| {
            run_wasm_threads_benchmark.addArgs(&.{ "--lanes", lanes });
        }
        if (b.option(bool, "wasm-threads-benchmark-quick", "Run one reduced WebAssembly Threads sample") orelse false)
            run_wasm_threads_benchmark.addArg("--quick");
        if (b.option([]const u8, "wasm-threads-benchmark-raw-out", "Write raw WebAssembly Threads samples to this TSV path")) |path| {
            run_wasm_threads_benchmark.addArgs(&.{ "--raw-out", path });
        }
        if (b.option([]const u8, "wasm-threads-benchmark-markdown-out", "Write the WebAssembly Threads report to this Markdown path")) |path| {
            run_wasm_threads_benchmark.addArgs(&.{ "--markdown-out", path });
        }
        const wasm_threads_benchmark_step = b.step("wasm-threads-benchmark", "Benchmark WebAssembly atomic and wait/notify scaling with the system-JSC boundary");
        wasm_threads_benchmark_step.dependOn(&run_wasm_threads_benchmark.step);

        const install_comparison_zig_js = b.addInstallArtifact(comparison_zig_js, .{});
        const install_comparison_jsc = b.addInstallArtifact(comparison_jsc, .{});
        comparison_bin_step.dependOn(&install_comparison_zig_js.step);
        comparison_bin_step.dependOn(&install_comparison_jsc.step);
    } else {
        const unsupported = b.addFail("benchmark-comparison requires the macOS system JavaScriptCore framework");
        comparison_step.dependOn(&unsupported.step);
        comparison_bin_step.dependOn(&unsupported.step);
        const wasm_threads_unsupported = b.addFail("wasm-threads-benchmark requires the macOS system JavaScriptCore framework");
        const wasm_threads_benchmark_step = b.step("wasm-threads-benchmark", "Benchmark WebAssembly atomic and wait/notify scaling with the system-JSC boundary");
        wasm_threads_benchmark_step.dependOn(&wasm_threads_unsupported.step);
    }

    // Thread contention profile: compare the no-GIL shared-realm default against
    // the `.gil = true` fallback across hot shared structures. This is a local
    // performance tool, not a correctness gate.
    const threads_profile_debug = b.option(bool, "threads-profile-debug", "Build threads-profile in Debug mode for crash diagnosis") orelse false;
    const threads_profile = b.addExecutable(.{
        .name = "threads-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/threads.zig"),
            .target = target,
            .optimize = if (threads_profile_debug) .Debug else .ReleaseFast,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_threads_profile = b.addRunArtifact(threads_profile);
    const threads_profile_case = b.option([]const u8, "threads-profile-case", "Run one exact threads-profile scenario name");
    const threads_profile_max_workers = b.option(usize, "threads-profile-max-workers", "Cap worker-count rows in threads-profile");
    if (threads_profile_case) |case| {
        run_threads_profile.addArg(case);
    } else if (threads_profile_max_workers != null) {
        run_threads_profile.addArg("");
    }
    if (threads_profile_max_workers) |max_workers| run_threads_profile.addArg(b.fmt("{d}", .{max_workers}));
    const threads_profile_step = b.step("threads-profile", "Profile no-GIL Thread contention, async waits, and .gil fallback cost");
    threads_profile_step.dependOn(&run_threads_profile.step);

    // Internal mid-script parallel-GC telemetry. Kept separate from the broad
    // contention matrix so collector convergence can be profiled in isolation.
    const midgc_profile = b.addExecutable(.{
        .name = "midgc-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/midgc.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_midgc_profile = b.addRunArtifact(midgc_profile);
    const midgc_profile_step = b.step("midgc-profile", "Profile internal mid-script parallel-GC convergence and pause telemetry");
    midgc_profile_step.dependOn(&run_midgc_profile.step);

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
    const gc_profile_case = b.option([]const u8, "gc-profile-case", "Run one exact gc-profile table name");
    if (gc_profile_case) |case| run_gc_profile.addArg(case);
    const gc_profile_step = b.step("gc-profile", "Profile GC allocation and Context lifecycle costs");
    gc_profile_step.dependOn(&run_gc_profile.step);

    // Reproducible fragmentation evidence for explicit stop-the-world
    // compaction. The Python driver alternates control/compact process order,
    // validates the heap/checksum contract, and optionally preserves raw TSV.
    const gc_compaction_runner = b.addExecutable(.{
        .name = "gc-compaction-benchmark-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gc_compaction.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_gc_compaction = b.addSystemCommand(&.{ "python3", "tools/gc-compaction-benchmark.py" });
    run_gc_compaction.addArtifactArg(gc_compaction_runner);
    if (b.option(usize, "gc-compaction-benchmark-samples", "GC compaction samples per mode")) |samples|
        run_gc_compaction.addArgs(&.{ "--samples", b.fmt("{d}", .{samples}) });
    if (b.option(bool, "gc-compaction-benchmark-quick", "Run one reduced GC compaction sample") orelse false)
        run_gc_compaction.addArg("--quick");
    if (b.option([]const u8, "gc-compaction-benchmark-raw-out", "Write raw GC compaction samples to this TSV path")) |path|
        run_gc_compaction.addArgs(&.{ "--raw-out", path });
    if (b.option([]const u8, "gc-compaction-benchmark-markdown-out", "Write the GC compaction report to this Markdown path")) |path|
        run_gc_compaction.addArgs(&.{ "--markdown-out", path });
    const gc_compaction_step = b.step("gc-compaction-benchmark", "Benchmark retained backing and pause cost after explicit compaction");
    gc_compaction_step.dependOn(&run_gc_compaction.step);

    // Reproducible age/trigger-policy evidence for the generational nursery.
    // The Python driver alternates policy order, validates exact checksums and
    // byte conservation, and can preserve the raw TSV plus generated report.
    const gc_generation_runner = b.addExecutable(.{
        .name = "gc-generation-benchmark-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/gc_generation.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{.{ .name = "js", .module = bench_js_mod }},
        }),
    });
    const run_gc_generation = b.addSystemCommand(&.{ "python3", "tools/gc-generation-benchmark.py" });
    run_gc_generation.addArtifactArg(gc_generation_runner);
    if (b.option(usize, "gc-generation-benchmark-samples", "GC generation samples per matrix row")) |samples|
        run_gc_generation.addArgs(&.{ "--samples", b.fmt("{d}", .{samples}) });
    if (b.option(bool, "gc-generation-benchmark-quick", "Run one reduced GC generation matrix") orelse false)
        run_gc_generation.addArg("--quick");
    if (b.option([]const u8, "gc-generation-benchmark-raw-out", "Write raw GC generation samples to this TSV path")) |path|
        run_gc_generation.addArgs(&.{ "--raw-out", path });
    if (b.option([]const u8, "gc-generation-benchmark-markdown-out", "Write the GC generation report to this Markdown path")) |path|
        run_gc_generation.addArgs(&.{ "--markdown-out", path });
    if (b.option(bool, "gc-generation-benchmark-update-readme", "Regenerate the README GC generation headline") orelse false)
        run_gc_generation.addArgs(&.{ "--readme", "README.md" });
    const gc_generation_step = b.step("gc-generation-benchmark", "Benchmark nursery ages, triggers, pauses, and no-GIL rendezvous");
    gc_generation_step.dependOn(&run_gc_generation.step);
}
