//! Parse and compile growth runner for representative frontend complexity witnesses.
//! Source construction is outside the scored boundary; every job owns a fresh
//! arena and performs its complete parse, optional compile, and shape validation.
//!
//! Usage:
//!   frontend-parse-benchmark single <workload> <jobs> <samples> [--darwin-rusage]

const std = @import("std");
const builtin = @import("builtin");
const js = @import("js");

const warmup_calls = 10;

// Darwin's public proc_pid_rusage RUSAGE_INFO_V6 layout. This runner keeps the
// counters around only the parser boundary; process-wide `/usr/bin/time`
// counters also include source construction, warmup, and allocation replay.
const DarwinRusageInfoV6 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
    ri_flags: u64,
    ri_user_ptime: u64,
    ri_system_ptime: u64,
    ri_pinstructions: u64,
    ri_pcycles: u64,
    ri_energy_nj: u64,
    ri_penergy_nj: u64,
    ri_secure_time_in_system: u64,
    ri_secure_ptime_in_system: u64,
    ri_neural_footprint: u64,
    ri_lifetime_max_neural_footprint: u64,
    ri_interval_max_neural_footprint: u64,
    ri_conclave_footprint: u64,
    ri_page_wait_time_mach: u64,
    ri_page_cache_hits: u64,
    ri_reserved: [6]u64,
};
comptime {
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_instructions") == 248);
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_energy_nj") == 336);
    std.debug.assert(@offsetOf(DarwinRusageInfoV6, "ri_page_cache_hits") == 408);
    std.debug.assert(@sizeOf(DarwinRusageInfoV6) == 464);
}

const DarwinCounterSnapshot = struct {
    instructions: u64,
    cycles: u64,
    energy_nj: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    page_cache_hits: u64,
};

const rusage_info_v6 = 6;
extern "c" fn proc_pid_rusage(pid: std.c.pid_t, flavor: c_int, buffer: *anyopaque) c_int;
extern "c" fn zig_js_benchmark_thermal_state() i32;

fn darwinCounterSnapshot() !DarwinCounterSnapshot {
    if (builtin.os.tag != .macos) return error.DarwinRusageUnavailable;
    var info = std.mem.zeroes(DarwinRusageInfoV6);
    if (proc_pid_rusage(std.c.getpid(), rusage_info_v6, &info) != 0) return error.DarwinRusageUnavailable;
    return .{
        .instructions = info.ri_instructions,
        .cycles = info.ri_cycles,
        .energy_nj = info.ri_energy_nj,
        .package_idle_wakeups = info.ri_pkg_idle_wkups,
        .interrupt_wakeups = info.ri_interrupt_wkups,
        .pageins = info.ri_pageins,
        .page_cache_hits = info.ri_page_cache_hits,
    };
}

fn darwinThermalState() !i32 {
    if (builtin.os.tag != .macos) return error.DarwinThermalStateUnavailable;
    const state = zig_js_benchmark_thermal_state();
    if (state < 0 or state > 3) return error.DarwinThermalStateUnavailable;
    return state;
}

fn printDarwinCounterRow(
    writer: *std.Io.Writer,
    workload: []const u8,
    jobs: usize,
    sample: usize,
    before: DarwinCounterSnapshot,
    after: DarwinCounterSnapshot,
    thermal_before: i32,
    thermal_after: i32,
) !void {
    try writer.print("zig-js-darwin-rusage\tsingle\t{s}\t{d}\t{d}\tmeasured\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        workload,
        jobs,
        sample,
        after.instructions -| before.instructions,
        after.cycles -| before.cycles,
        after.energy_nj -| before.energy_nj,
        after.package_idle_wakeups -| before.package_idle_wakeups,
        after.interrupt_wakeups -| before.interrupt_wakeups,
        after.pageins -| before.pageins,
        after.page_cache_hits -| before.page_cache_hits,
        thermal_before,
        thermal_after,
    });
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn workloadWidth(name: []const u8) !usize {
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_unique_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_unique_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_unique_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_var_only_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_shadowed_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_parameter_shadow_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_destructure_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_nested_control_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_binding_inventory_forward_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_global_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_global_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_global_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_method_first_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_method_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_field_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_static_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_computed_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_superclass_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_class_frame_environment_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_clear_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_clear_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_clear_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_unrelated_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_first_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_destructure_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_catch_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_switch_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_repeated_body_nested_clear_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_clear_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_clear_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_clear_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_unrelated_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_first_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_for_of_clear_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_loop_capture_for_of_last_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_clear_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_clear_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_clear_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_unrelated_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_forward_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_self_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_declared_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_nested_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_class_field_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_compile_tdz_class_static_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_param_body_direct_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_param_body_nested_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_escaped_identifiers_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_escaped_identifiers_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_escaped_identifiers_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_unicode_identifiers_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_unicode_identifiers_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_unicode_identifiers_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_escaped_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_escaped_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_escaped_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_strings_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_strings_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_strings_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_strings_escaped_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_strings_escaped_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_strings_escaped_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_templates_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_templates_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_escaped_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_templates_escaped_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_templates_escaped_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_tagged_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_normalized_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_templates_normalized_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_templates_normalized_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_normalized_tagged_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_tagged_substitutions_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_templates_tagged_substitutions_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_templates_tagged_substitutions_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_separators_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_separators_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_separators_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_unseparated_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_decimal_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_decimal_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_decimal_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_decimal_separated_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_hex_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_hex_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_bigint_hex_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_modules_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_modules_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_modules_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_statement_locations_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_statement_locations_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_statement_locations_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_statement_locations_mixed_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_statement_locations_nested_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_statement_location_single_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_nested_functions_256")) return 256;
    if (std.mem.eql(u8, name, "representative_frontend_nested_functions_512")) return 512;
    if (std.mem.eql(u8, name, "representative_frontend_nested_functions_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_nested_functions_decoys_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_nested_functions_arguments_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_nested_arrows_arguments_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_regex_literals_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_regex_literals_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_regex_literals_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_regex_literals_unicode_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_regex_literals_annex_b_4096")) return 4096;
    return error.InvalidWorkload;
}

fn isStringWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_strings_");
}

fn isEscapedStringWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_strings_escaped_");
}

fn isTemplateWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_templates_");
}

fn isTaggedTemplateWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_templates_tagged_4096") or
        std.mem.eql(u8, name, "representative_frontend_templates_normalized_tagged_4096");
}

fn isEscapedTemplateWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_templates_escaped_");
}

fn isNormalizedTemplateWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_templates_normalized_");
}

fn isTaggedSubstitutionWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_templates_tagged_substitutions_");
}

fn isEscapedIdentifierWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_escaped_identifiers_");
}

fn isUnicodeIdentifierWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_unicode_identifiers_");
}

const BindingInventoryCompileShape = enum { unique, var_only, shadowed, parameter_shadow, destructure, nested_control, forward };
const TdzCompileShape = enum { clear, unrelated, forward, self, declared, nested, class_field, class_static };

const LoopCaptureCompileShape = enum { clear, unrelated, first, last, for_of_clear, for_of_last };

const RepeatedBodyCompileShape = enum { clear, unrelated, first, last, destructure_last, catch_last, switch_last, nested_clear };

const ClassFrameCompileShape = enum { global, method_first, method_last, field_last, static_last, computed_last, superclass_last, environment_last };

fn classFrameCompileShape(name: []const u8) ?ClassFrameCompileShape {
    const prefix = "representative_frontend_compile_class_frame_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const shape_end = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const shape = name[prefix.len..shape_end];
    if (std.mem.eql(u8, shape, "global")) return .global;
    if (std.mem.eql(u8, shape, "method_first")) return .method_first;
    if (std.mem.eql(u8, shape, "method_last")) return .method_last;
    if (std.mem.eql(u8, shape, "field_last")) return .field_last;
    if (std.mem.eql(u8, shape, "static_last")) return .static_last;
    if (std.mem.eql(u8, shape, "computed_last")) return .computed_last;
    if (std.mem.eql(u8, shape, "superclass_last")) return .superclass_last;
    if (std.mem.eql(u8, shape, "environment_last")) return .environment_last;
    return null;
}

fn repeatedBodyCompileShape(name: []const u8) ?RepeatedBodyCompileShape {
    const prefix = "representative_frontend_compile_repeated_body_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const shape_end = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const shape = name[prefix.len..shape_end];
    if (std.mem.eql(u8, shape, "clear")) return .clear;
    if (std.mem.eql(u8, shape, "unrelated")) return .unrelated;
    if (std.mem.eql(u8, shape, "first")) return .first;
    if (std.mem.eql(u8, shape, "last")) return .last;
    if (std.mem.eql(u8, shape, "destructure_last")) return .destructure_last;
    if (std.mem.eql(u8, shape, "catch_last")) return .catch_last;
    if (std.mem.eql(u8, shape, "switch_last")) return .switch_last;
    if (std.mem.eql(u8, shape, "nested_clear")) return .nested_clear;
    return null;
}

fn loopCaptureCompileShape(name: []const u8) ?LoopCaptureCompileShape {
    const prefix = "representative_frontend_compile_loop_capture_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const shape_end = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const shape = name[prefix.len..shape_end];
    if (std.mem.eql(u8, shape, "clear")) return .clear;
    if (std.mem.eql(u8, shape, "unrelated")) return .unrelated;
    if (std.mem.eql(u8, shape, "first")) return .first;
    if (std.mem.eql(u8, shape, "last")) return .last;
    if (std.mem.eql(u8, shape, "for_of_clear")) return .for_of_clear;
    if (std.mem.eql(u8, shape, "for_of_last")) return .for_of_last;
    return null;
}

fn bindingInventoryCompileShape(name: []const u8) ?BindingInventoryCompileShape {
    const prefix = "representative_frontend_compile_binding_inventory_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const shape_end = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const shape = name[prefix.len..shape_end];
    if (std.mem.eql(u8, shape, "unique")) return .unique;
    if (std.mem.eql(u8, shape, "var_only")) return .var_only;
    if (std.mem.eql(u8, shape, "shadowed")) return .shadowed;
    if (std.mem.eql(u8, shape, "parameter_shadow")) return .parameter_shadow;
    if (std.mem.eql(u8, shape, "destructure")) return .destructure;
    if (std.mem.eql(u8, shape, "nested_control")) return .nested_control;
    if (std.mem.eql(u8, shape, "forward")) return .forward;
    return null;
}

fn tdzCompileShape(name: []const u8) ?TdzCompileShape {
    const prefix = "representative_frontend_compile_tdz_";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const shape_end = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const shape = name[prefix.len..shape_end];
    if (std.mem.eql(u8, shape, "clear")) return .clear;
    if (std.mem.eql(u8, shape, "unrelated")) return .unrelated;
    if (std.mem.eql(u8, shape, "forward")) return .forward;
    if (std.mem.eql(u8, shape, "self")) return .self;
    if (std.mem.eql(u8, shape, "declared")) return .declared;
    if (std.mem.eql(u8, shape, "nested")) return .nested;
    if (std.mem.eql(u8, shape, "class_field")) return .class_field;
    if (std.mem.eql(u8, shape, "class_static")) return .class_static;
    return null;
}

fn isParamBodyDirectWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_param_body_direct_4096");
}

fn isParamBodyNestedWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_param_body_nested_4096");
}

fn isPrivateNameWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_private_names_");
}

fn isEscapedPrivateNameWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_private_names_escaped_");
}

fn isNumericWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_numeric_");
}

fn isSeparatedNumericWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_numeric_separators_");
}

fn isDecimalBigIntWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_bigint_decimal_");
}

fn isSeparatedDecimalBigIntWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_bigint_decimal_separated_4096");
}

fn isRadixBigIntWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_bigint_hex_");
}

fn isModuleWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_modules_");
}

fn isStatementLocationWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_statement_location");
}

fn isMixedStatementLocationWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_statement_locations_mixed_4096");
}

fn isSingleStatementLocationWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_statement_location_single_4096");
}

fn isNestedStatementLocationWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_statement_locations_nested_1024");
}

fn isNestedFunctionWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_nested_functions_");
}

fn isNestedFunctionDecoyWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_nested_functions_decoys_1024");
}

fn isNestedFunctionArgumentsWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_nested_functions_arguments_1024");
}

fn isNestedArrowArgumentsWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_nested_arrows_arguments_1024");
}

fn isRegexLiteralWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_regex_literals_");
}

fn isUnicodeRegexLiteralWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_regex_literals_unicode_4096");
}

fn isAnnexBRegexLiteralWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_regex_literals_annex_b_4096");
}

fn appendIndexedIdentifier(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, prefix: []const u8, index: usize) !void {
    try source.appendSlice(allocator, prefix);
    try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
}

fn appendTdzDeclarations(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, width: usize, first_self_reference: bool) !void {
    for (0..width) |index| {
        try source.appendSlice(allocator, "let ");
        try appendIndexedIdentifier(source, allocator, "lexical", index);
        try source.append(allocator, '=');
        if (first_self_reference and index == 0)
            try appendIndexedIdentifier(source, allocator, "lexical", index)
        else
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.append(allocator, ';');
    }
}

fn tdzCompileSource(allocator: std.mem.Allocator, width: usize, shape: TdzCompileShape) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function tdzWidth(){");
    switch (shape) {
        .unrelated => for (0..width) |index| {
            try appendIndexedIdentifier(&source, allocator, "unrelated", index);
            try source.append(allocator, ';');
        },
        .forward => {
            try appendIndexedIdentifier(&source, allocator, "lexical", width - 1);
            try source.append(allocator, ';');
        },
        .nested => {
            try source.appendSlice(allocator, "function capture(){return ");
            try appendIndexedIdentifier(&source, allocator, "lexical", width - 1);
            try source.appendSlice(allocator, ";}");
        },
        .class_field, .class_static => {
            try source.appendSlice(allocator, if (shape == .class_static) "class Holder{static field=" else "class Holder{field=");
            try appendIndexedIdentifier(&source, allocator, "lexical", width - 1);
            try source.appendSlice(allocator, ";}");
        },
        .clear, .self, .declared => {},
    }
    try appendTdzDeclarations(&source, allocator, width, shape == .self);
    if (shape == .declared) {
        try appendIndexedIdentifier(&source, allocator, "lexical", width - 1);
        try source.append(allocator, ';');
    }
    if (shape == .nested) try source.appendSlice(allocator, "return capture;");
    try source.append(allocator, '}');
    return source.items;
}

fn bindingInventoryCompileSource(
    allocator: std.mem.Allocator,
    width: usize,
    shape: BindingInventoryCompileShape,
) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function bindingInventory(");
    if (shape == .parameter_shadow) for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try appendIndexedIdentifier(&source, allocator, "parameter", index);
    };
    try source.appendSlice(allocator, "){");
    if (shape == .forward) {
        try appendIndexedIdentifier(&source, allocator, "binding", width - 1);
        try source.append(allocator, ';');
    }
    for (0..width) |index| switch (shape) {
        .unique, .var_only, .forward => {
            try source.appendSlice(allocator, if (shape == .var_only) "var " else "let ");
            try appendIndexedIdentifier(&source, allocator, "binding", index);
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "={d};", .{index}));
        },
        .shadowed => {
            try source.appendSlice(allocator, "{let shared=");
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
            try source.appendSlice(allocator, ";}");
        },
        .parameter_shadow => {
            try source.appendSlice(allocator, "{let ");
            try appendIndexedIdentifier(&source, allocator, "parameter", index);
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "={d};}}", .{index}));
        },
        .destructure => {
            try source.appendSlice(allocator, "let [");
            try appendIndexedIdentifier(&source, allocator, "binding", index);
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "]=[{d}];", .{index}));
        },
        .nested_control => {
            try source.appendSlice(allocator, "if(false){let ");
            try appendIndexedIdentifier(&source, allocator, "binding", index);
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "={d};}}", .{index}));
        },
    };
    try source.appendSlice(allocator, "return 0;}");
    return source.items;
}

fn appendClassFrameDeclarations(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, width: usize) !void {
    for (0..width) |index| {
        try source.appendSlice(allocator, "let ");
        try appendIndexedIdentifier(source, allocator, "frameBinding", index);
        try source.append(allocator, '=');
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d};", .{index}));
    }
}

fn classFrameCompileSource(allocator: std.mem.Allocator, width: usize, shape: ClassFrameCompileShape) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function classFrameWidth(){");
    if (shape == .environment_last) try source.appendSlice(allocator, "while(false){");
    try appendClassFrameDeclarations(&source, allocator, width);
    switch (shape) {
        .global => {
            try source.appendSlice(allocator, "class Holder{");
            for (0..width) |index| {
                try appendIndexedIdentifier(&source, allocator, "method", index);
                try source.appendSlice(allocator, "(){return ");
                try appendIndexedIdentifier(&source, allocator, "unrelated", index);
                try source.appendSlice(allocator, ";}");
            }
            try source.append(allocator, '}');
        },
        .method_first, .method_last, .environment_last => {
            try source.appendSlice(allocator, "class Holder{method(){return ");
            try appendIndexedIdentifier(&source, allocator, "frameBinding", if (shape == .method_first) 0 else width - 1);
            try source.appendSlice(allocator, ";}}");
        },
        .field_last => {
            try source.appendSlice(allocator, "class Holder{field=");
            try appendIndexedIdentifier(&source, allocator, "frameBinding", width - 1);
            try source.appendSlice(allocator, ";}");
        },
        .static_last => {
            try source.appendSlice(allocator, "class Holder{static{");
            try appendIndexedIdentifier(&source, allocator, "frameBinding", width - 1);
            try source.appendSlice(allocator, ";}}");
        },
        .computed_last => {
            try source.appendSlice(allocator, "class Holder{[");
            try appendIndexedIdentifier(&source, allocator, "frameBinding", width - 1);
            try source.appendSlice(allocator, "](){return 7;}}");
        },
        .superclass_last => {
            try source.appendSlice(allocator, "class Holder extends ");
            try appendIndexedIdentifier(&source, allocator, "frameBinding", width - 1);
            try source.appendSlice(allocator, "{}");
        },
    }
    if (shape == .environment_last)
        try source.appendSlice(allocator, "}return 7;}")
    else
        try source.appendSlice(allocator, "return Holder;}");
    return source.items;
}

fn appendRepeatedBodyNames(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, width: usize) !void {
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try appendIndexedIdentifier(source, allocator, "bodyBinding", index);
    }
}

fn appendRepeatedBodyDeclarations(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, width: usize) !void {
    for (0..width) |index| {
        try source.appendSlice(allocator, "let ");
        try appendIndexedIdentifier(source, allocator, "bodyBinding", index);
        try source.append(allocator, '=');
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d};", .{index}));
    }
}

fn appendRepeatedBodyCapture(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, index: usize) !void {
    try source.appendSlice(allocator, "(function(){return ");
    try appendIndexedIdentifier(source, allocator, "bodyBinding", index);
    try source.appendSlice(allocator, ";});");
}

fn repeatedBodyCompileSource(allocator: std.mem.Allocator, width: usize, shape: RepeatedBodyCompileShape) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function repeatedBodyWidth(){while(false){");
    switch (shape) {
        .destructure_last => {
            try source.appendSlice(allocator, "let [");
            try appendRepeatedBodyNames(&source, allocator, width);
            try source.appendSlice(allocator, "]=[];");
            try appendRepeatedBodyCapture(&source, allocator, width - 1);
        },
        .catch_last => {
            try source.appendSlice(allocator, "try{throw [];}catch([");
            try appendRepeatedBodyNames(&source, allocator, width);
            try source.appendSlice(allocator, "]){");
            try appendRepeatedBodyCapture(&source, allocator, width - 1);
            try source.append(allocator, '}');
        },
        .switch_last => {
            try source.appendSlice(allocator, "switch(0){case 0:");
            try appendRepeatedBodyDeclarations(&source, allocator, width);
            try appendRepeatedBodyCapture(&source, allocator, width - 1);
            try source.append(allocator, '}');
        },
        .nested_clear => {
            try source.appendSlice(allocator, "while(false){");
            try appendRepeatedBodyDeclarations(&source, allocator, width);
            try source.append(allocator, '}');
        },
        .clear, .unrelated, .first, .last => {
            try appendRepeatedBodyDeclarations(&source, allocator, width);
            switch (shape) {
                .unrelated => {
                    try source.appendSlice(allocator, "(function(){return [");
                    for (0..width) |index| {
                        if (index != 0) try source.append(allocator, ',');
                        try appendIndexedIdentifier(&source, allocator, "unrelated", index);
                    }
                    try source.appendSlice(allocator, "];});");
                },
                .first, .last => try appendRepeatedBodyCapture(&source, allocator, if (shape == .first) 0 else width - 1),
                .clear => {},
                else => unreachable,
            }
        },
    }
    try source.appendSlice(allocator, "}return 7;}");
    return source.items;
}

fn appendLoopBindingNames(source: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, width: usize, initializer: bool) !void {
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try appendIndexedIdentifier(source, allocator, "loopBinding", index);
        if (initializer) {
            try source.append(allocator, '=');
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        }
    }
}

fn loopCaptureCompileSource(allocator: std.mem.Allocator, width: usize, shape: LoopCaptureCompileShape) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function loopCaptureWidth(){for(let ");
    const for_of = shape == .for_of_clear or shape == .for_of_last;
    if (for_of) try source.append(allocator, '[');
    try appendLoopBindingNames(&source, allocator, width, !for_of);
    if (for_of) {
        try source.appendSlice(allocator, "] of [[]]){");
    } else {
        try source.appendSlice(allocator, ";false;){");
    }
    switch (shape) {
        .unrelated => for (0..width) |index| {
            try appendIndexedIdentifier(&source, allocator, "unrelated", index);
            try source.append(allocator, ';');
        },
        .first, .last, .for_of_last => {
            try source.appendSlice(allocator, "(function(){return ");
            try appendIndexedIdentifier(&source, allocator, "loopBinding", if (shape == .first) 0 else width - 1);
            try source.appendSlice(allocator, ";});");
        },
        .clear, .for_of_clear => {},
    }
    try source.appendSlice(allocator, "}return 7;}");
    return source.items;
}

const ParamBodyShape = enum { ordinary, direct_lexical, nested_lexical };

fn strictFunctionSource(allocator: std.mem.Allocator, width: usize, escaped: bool, body_shape: ParamBodyShape) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function strictWidth(");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.appendSlice(allocator, if (escaped) "paramet\\u0065r" else "parameter");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
    }
    try source.appendSlice(allocator, switch (body_shape) {
        .ordinary => "){\"use strict\";return 7;}",
        .direct_lexical => "){\"use strict\";let bodyOnly=1;return bodyOnly;}",
        // A nested lexical binding may shadow a parameter; it is outside the
        // function body's direct LexicallyDeclaredNames conflict set.
        .nested_lexical => "){\"use strict\";{let parameter0=1;}return 7;}",
    });
    return source.items;
}

// Cycle valid Unicode 17 ID_Start values from Greek, CJK, astral Deseret, and
// Other_ID_Start, followed by a combining ID_Continue mark. Source construction
// happens once before all warmup and scored parser boundaries.
const unicode_identifier_prefixes = [_][]const u8{
    "π\u{0301}parameter",
    "变量\u{0301}parameter",
    "\u{10400}\u{0301}parameter",
    "℘\u{0301}parameter",
};

fn unicodeIdentifierSource(allocator: std.mem.Allocator, width: usize) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function unicodeWidth(");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.appendSlice(allocator, unicode_identifier_prefixes[index % unicode_identifier_prefixes.len]);
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
    }
    try source.appendSlice(allocator, "){\"use strict\";return 7;}");
    return source.items;
}

fn privateClassSource(allocator: std.mem.Allocator, width: usize, escaped: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "class PrivateWidth {");
    for (0..width) |index| {
        try source.appendSlice(allocator, if (escaped) "#fi\\u0065ld" else "#field");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d};", .{index}));
    }
    try source.appendSlice(allocator, "}");
    return source.items;
}

fn stringLiteralSource(allocator: std.mem.Allocator, width: usize, escaped: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var stringCorpus = [");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        // The escaped control decodes to the exact same value; only its first
        // `l` is spelled as a Unicode escape. Source construction is outside
        // every warmup and timed parse boundary.
        try source.appendSlice(allocator, if (escaped) "'\\u006citeral-" else "'literal-");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, "-abcdefghijklmnopqrstuvwxyz0123456789'");
    }
    try source.appendSlice(allocator, "];\n");
    return source.items;
}

fn templateLiteralSource(
    allocator: std.mem.Allocator,
    width: usize,
    escaped: bool,
    normalized: bool,
    tagged: bool,
) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var templateCorpus = [");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        if (tagged) try source.appendSlice(allocator, "tag");
        if (normalized) {
            // Exercise both TRV reductions in every element: CRLF -> LF and
            // lone CR -> LF. Source construction stays outside the timed parse.
            try source.appendSlice(allocator, "`line\r\nliteral-");
        } else {
            try source.appendSlice(allocator, if (escaped) "`\\u006citeral-" else "`literal-");
        }
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, if (normalized)
            "\rtail-abcdefghijklmnopqrstuvwxyz0123456789`"
        else
            "-abcdefghijklmnopqrstuvwxyz0123456789`");
    }
    try source.appendSlice(allocator, "];\n");
    return source.items;
}

fn taggedSubstitutionSource(allocator: std.mem.Allocator, width: usize) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var templateCorpus = tag`");
    for (0..width) |index| {
        try source.appendSlice(allocator, "quasi-");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, "-abcdefghijklmnopqrstuvwxyz${");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.append(allocator, '}');
    }
    try source.appendSlice(allocator, "quasi-");
    try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{width}));
    try source.appendSlice(allocator, "-abcdefghijklmnopqrstuvwxyz`;\n");
    return source.items;
}

fn numericLiteralSource(allocator: std.mem.Allocator, width: usize, separated: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var numericCorpus = [");
    var digits_buffer: [32]u8 = undefined;
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{100_000_000_000 + index});
        if (!separated) {
            try source.appendSlice(allocator, digits);
            continue;
        }
        for (digits, 0..) |digit, position| {
            if (position != 0 and (digits.len - position) % 3 == 0)
                try source.append(allocator, '_');
            try source.append(allocator, digit);
        }
    }
    try source.appendSlice(allocator, "];\n");
    return source.items;
}

fn decimalBigIntDigit(position: usize) u8 {
    if (position == 0) return '9';
    return '0' + @as(u8, @intCast((position *% 7 +% 3) % 10));
}

fn decimalBigIntSource(allocator: std.mem.Allocator, width: usize, separated: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var decimalBigInt = ");
    for (0..width) |position| {
        if (separated and position != 0 and (width - position) % 3 == 0)
            try source.append(allocator, '_');
        try source.append(allocator, decimalBigIntDigit(position));
    }
    try source.appendSlice(allocator, "n;\n");
    return source.items;
}

fn validatedDecimalBigIntChecksum(text: []const u8) !usize {
    var checksum: u32 = 2_166_136_261;
    for (text, 0..) |digit, position| {
        if (digit != decimalBigIntDigit(position)) return error.InvalidProgram;
        checksum = (checksum ^ digit) *% 16_777_619;
    }
    return @as(usize, checksum) + text.len;
}

const RadixBigIntInput = struct {
    source: []const u8,
    expected_decimal: []const u8,
};

fn hexBigIntDigit(position: usize) u8 {
    if (position == 0) return 'f';
    return "0123456789abcdef"[(position *% 11 +% 5) % 16];
}

fn radixBigIntSource(allocator: std.mem.Allocator, width: usize) !RadixBigIntInput {
    const digits = try allocator.alloc(u8, width);
    for (digits, 0..) |*digit, position| digit.* = hexBigIntDigit(position);

    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var radixBigInt = 0x");
    try source.appendSlice(allocator, digits);
    try source.appendSlice(allocator, "n;\n");

    // This independent std oracle runs once during source preparation, before
    // warmup and every scored parser boundary.
    var oracle = try std.math.big.int.Managed.init(allocator);
    defer oracle.deinit();
    try oracle.setString(16, digits);
    return .{
        .source = source.items,
        .expected_decimal = try oracle.toString(allocator, 10, .lower),
    };
}

fn moduleSource(allocator: std.mem.Allocator, width: usize) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "import {");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.appendSlice(allocator, "value");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, " as imported");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
    }
    try source.appendSlice(allocator, "} from './dependency.js'; export {");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.appendSlice(allocator, "imported");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, " as value");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
    }
    try source.appendSlice(allocator, "}; export const marker = 1;\n");
    return source.items;
}

const statement_location_prefix = "/*location*/ ";

fn statementLocationTerminator(index: usize, mixed: bool) []const u8 {
    if (!mixed) return "\n";
    return switch (index % 5) {
        0 => "\n",
        1 => "\r\n",
        2 => "\r",
        3 => "\xe2\x80\xa8",
        else => "\xe2\x80\xa9",
    };
}

fn statementLocationSource(allocator: std.mem.Allocator, width: usize, mixed: bool, nested: bool, single: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    if (single) {
        try source.appendSlice(allocator, "var locationCorpus = [");
        for (0..width) |index| {
            if (index != 0) try source.append(allocator, ',');
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        }
        try source.appendSlice(allocator, "];\n");
        return source.items;
    }
    if (nested) {
        for (0..width) |index| {
            try source.appendSlice(allocator, "if (true) {\n  statement");
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
            try source.appendSlice(allocator, ";\n}\n");
        }
        return source.items;
    }
    for (0..width) |index| {
        if (mixed and index % 2 == 1) try source.appendSlice(allocator, statement_location_prefix);
        try source.appendSlice(allocator, "statement");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.append(allocator, ';');
        try source.appendSlice(allocator, statementLocationTerminator(index, mixed));
    }
    return source.items;
}

fn nestedFunctionSource(
    allocator: std.mem.Allocator,
    depth: usize,
    decoys: bool,
    innermost_arguments: bool,
) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    for (0..depth) |index| {
        try source.appendSlice(allocator, "function level");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, "(){");
    }
    try source.appendSlice(allocator, if (innermost_arguments) "return arguments.length;" else "return 7;");
    var remaining = depth;
    while (remaining > 0) {
        remaining -= 1;
        if (remaining + 1 < depth) {
            try source.appendSlice(allocator, "return level");
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d};", .{remaining + 1}));
        }
        // Put lexical decoys after the nested definition and return. The parent
        // must scan through its full child range before finding this text; it is
        // still ordinary parsed source and remains inside every scored boundary.
        if (decoys) try source.appendSlice(allocator, "var evaluation=0;\"arguments eval retrieval\";/* arguments eval */");
        try source.append(allocator, '}');
    }
    try source.appendSlice(allocator, "level0;\n");
    return source.items;
}

fn nestedArrowArgumentsSource(allocator: std.mem.Allocator, depth: usize) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function arrowOwner(){return ");
    for (0..depth) |_| try source.appendSlice(allocator, "()=>");
    try source.appendSlice(allocator, "arguments.length;}arrowOwner;\n");
    return source.items;
}

fn regexLiteralSource(allocator: std.mem.Allocator, width: usize, unicode: bool, annex_b: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var regexCorpus = [");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        if (annex_b) {
            // Annex B treats the class-escape range endpoint as a union with a
            // literal hyphen. This control must take the compatibility rewrite.
            try source.appendSlice(allocator, "/annex-");
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
            try source.appendSlice(allocator, "-[\\d-a]+/");
        } else if (unicode) {
            // Equal literal count and comparable pattern shape, but `u` makes
            // Annex B normalization inapplicable.
            try source.appendSlice(allocator, "/unicode-");
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
            try source.appendSlice(allocator, "-[a-z]+/u");
        } else {
            try source.appendSlice(allocator, "/literal-");
            try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
            try source.appendSlice(allocator, "-(?:[a-z]+|\\d{2,4})/gi");
        }
    }
    try source.appendSlice(allocator, "];\n");
    return source.items;
}

fn indexedName(name: []const u8, prefix: []const u8, index: usize) !bool {
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    return (try std.fmt.parseUnsigned(usize, name[prefix.len..], 10)) == index;
}

fn validatedRadixBigIntChecksum(text: []const u8, expected: []const u8) !usize {
    if (!std.mem.eql(u8, text, expected)) return error.InvalidProgram;
    var checksum: u32 = 2_166_136_261;
    for (text) |digit| checksum = (checksum ^ digit) *% 16_777_619;
    return @as(usize, checksum) + text.len;
}

fn validateNestedFunctionProgram(program: anytype, source: []const u8, workload: []const u8, depth: usize) !usize {
    if (program.program.len != 2) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl) return error.InvalidProgram;
    const marker = program.program[1];
    if (marker.* != .expr_stmt or marker.expr_stmt.* != .identifier or
        !std.mem.eql(u8, marker.expr_stmt.identifier, "level0"))
        return error.InvalidProgram;

    const decoys = isNestedFunctionDecoyWorkload(workload);
    const innermost_arguments = isNestedFunctionArgumentsWorkload(workload);
    var function = declaration.func_decl;
    var expected_start: usize = 0;
    var previous_source_len = source.len + 1;
    var checksum = program.program.len + depth + marker.expr_stmt.identifier.len;
    for (0..depth) |index| {
        var name_buffer: [64]u8 = undefined;
        const expected_name = try std.fmt.bufPrint(&name_buffer, "level{d}", .{index});
        var prefix_buffer: [96]u8 = undefined;
        const expected_prefix = try std.fmt.bufPrint(&prefix_buffer, "function {s}(){{", .{expected_name});
        if (!std.mem.startsWith(u8, source[expected_start..], expected_prefix) or
            @intFromPtr(function.source.ptr) != @intFromPtr(source.ptr) + expected_start or
            !std.mem.eql(u8, function.name, expected_name) or function.params.len != 0 or
            function.body.* != .block or function.source.len >= previous_source_len or
            function.source.len == 0 or function.source[function.source.len - 1] != '}')
            return error.InvalidProgram;
        const current_source_len = function.source.len;
        // The no-keyword growth rows must keep the internal proof exact on both
        // sides of the A/B. Decoy and innermost-use rows intentionally allow the
        // conservative parent and exact candidate to differ in outer metadata;
        // their observable AST/source checksum remains identical.
        if (!decoys and !innermost_arguments and function.uses_arguments)
            return error.InvalidProgram;

        const body = function.body.block;
        const leaf = index + 1 == depth;
        const expected_body_len = @as(usize, if (leaf) 1 else 2) + 2 * @as(usize, @intFromBool(decoys));
        if (body.len != expected_body_len) return error.InvalidProgram;
        const returned = switch (body[if (leaf) 0 else 1].*) {
            .return_stmt => |value| value orelse return error.InvalidProgram,
            else => return error.InvalidProgram,
        };
        if (leaf) {
            if (innermost_arguments) {
                if (!function.uses_arguments or returned.* != .member or
                    returned.member.object.* != .identifier or
                    !std.mem.eql(u8, returned.member.object.identifier, "arguments") or
                    !std.mem.eql(u8, returned.member.property, "length"))
                    return error.InvalidProgram;
            } else if (returned.* != .number or returned.number != 7) {
                return error.InvalidProgram;
            }
        } else {
            if (body[0].* != .func_decl or returned.* != .identifier) return error.InvalidProgram;
            var next_name_buffer: [64]u8 = undefined;
            const next_name = try std.fmt.bufPrint(&next_name_buffer, "level{d}", .{index + 1});
            if (!std.mem.eql(u8, returned.identifier, next_name)) return error.InvalidProgram;
            function = body[0].func_decl;
        }
        if (decoys) {
            const binding = body[body.len - 2];
            if (binding.* != .var_decl or !std.mem.eql(u8, binding.var_decl.name, "evaluation") or
                binding.var_decl.init == null or binding.var_decl.init.?.* != .number or
                binding.var_decl.init.?.number != 0)
                return error.InvalidProgram;
            const decoy = body[body.len - 1];
            if (decoy.* != .expr_stmt or decoy.expr_stmt.* != .string or
                !std.mem.eql(u8, decoy.expr_stmt.string, "arguments eval retrieval"))
                return error.InvalidProgram;
        }
        checksum += expected_start + expected_name.len + current_source_len + body.len + index;
        expected_start += expected_prefix.len;
        previous_source_len = current_source_len;
    }
    return checksum + source.len;
}

fn validateNestedArrowArgumentsProgram(program: anytype, source: []const u8, depth: usize) !usize {
    if (program.program.len != 2) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl or !std.mem.eql(u8, declaration.func_decl.name, "arrowOwner") or
        !declaration.func_decl.uses_arguments or declaration.func_decl.body.* != .block or
        declaration.func_decl.body.block.len != 1 or
        @intFromPtr(declaration.func_decl.source.ptr) != @intFromPtr(source.ptr))
        return error.InvalidProgram;
    const marker = program.program[1];
    if (marker.* != .expr_stmt or marker.expr_stmt.* != .identifier or
        !std.mem.eql(u8, marker.expr_stmt.identifier, "arrowOwner"))
        return error.InvalidProgram;
    var expression = switch (declaration.func_decl.body.block[0].*) {
        .return_stmt => |value| value orelse return error.InvalidProgram,
        else => return error.InvalidProgram,
    };
    var checksum = source.len + declaration.func_decl.source.len + marker.expr_stmt.identifier.len;
    for (0..depth) |index| {
        if (expression.* != .function or !expression.function.is_arrow or
            expression.function.params.len != 0 or !expression.function.is_expr_body)
            return error.InvalidProgram;
        checksum += expression.function.source.len + index;
        expression = expression.function.body;
    }
    if (expression.* != .member or expression.member.object.* != .identifier or
        !std.mem.eql(u8, expression.member.object.identifier, "arguments") or
        !std.mem.eql(u8, expression.member.property, "length"))
        return error.InvalidProgram;
    return checksum;
}

const AllocationObservation = struct {
    requests: usize = 0,
    allocated_bytes: usize = 0,
};

fn foldChecksum(seed: usize, value: usize) usize {
    const modulus = 1_000_000_007;
    return ((seed * 131) % modulus + value % modulus) % modulus;
}

fn foldBytes(seed_start: usize, bytes: []const u8) usize {
    var seed = seed_start;
    for (bytes) |byte| seed = foldChecksum(seed, byte);
    return seed;
}

fn foldChunk(seed_start: usize, chunk: anytype) usize {
    var seed = foldChecksum(seed_start, chunk.code.items.len);
    seed = foldChecksum(seed, chunk.consts.items.len);
    seed = foldChecksum(seed, chunk.names.items.len);
    seed = foldChecksum(seed, chunk.fns.items.len);
    seed = foldChecksum(seed, chunk.lexical_slots.len);
    for (chunk.code.items) |instruction| {
        seed = foldChecksum(seed, @backingInt(instruction.op));
        seed = foldChecksum(seed, instruction.a);
        seed = foldChecksum(seed, instruction.b);
    }
    for (chunk.names.items) |name| seed = foldBytes(seed, name);
    for (chunk.lexical_slots) |slot| seed = foldChecksum(seed, slot);
    for (chunk.fns.items) |template| {
        seed = foldBytes(seed, template.name);
        seed = foldChecksum(seed, @backingInt(template.admission));
        if (template.chunk) |nested| seed = foldChunk(seed, nested);
    }
    return seed;
}

fn chunkHasOp(chunk: anytype, target: js.bytecode.Op) bool {
    for (chunk.code.items) |instruction| if (instruction.op == target) return true;
    for (chunk.fns.items) |template| if (template.chunk) |nested|
        if (chunkHasOp(nested, target)) return true;
    return false;
}

fn validateBindingInventoryCompileProgram(
    allocator: std.mem.Allocator,
    program: anytype,
    source: []const u8,
    width: usize,
    shape: BindingInventoryCompileShape,
) !usize {
    if (program.* != .program or program.program.len != 1) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl or
        !std.mem.eql(u8, declaration.func_decl.name, "bindingInventory"))
        return error.InvalidProgram;
    const expected_params = if (shape == .parameter_shadow) width else 0;
    if (declaration.func_decl.params.len != expected_params) return error.InvalidProgram;
    const admission = try js.Compiler.admitPlainFunction(allocator, declaration.func_decl);
    const expected_rejection = shape == .destructure;
    const code = switch (admission) {
        .compiled => |compiled| if (expected_rejection) return error.InvalidProgram else compiled,
        .rejected => |reason| {
            if (!expected_rejection or reason != .unsupported_lowering) return error.InvalidProgram;
            var checksum = foldChecksum(source.len, width);
            checksum = foldChecksum(checksum, @backingInt(shape));
            return foldChecksum(checksum, @backingInt(reason));
        },
    };
    const expected_locals = width + expected_params;
    const checked_inventory = shape == .shadowed or shape == .parameter_shadow or shape == .forward;
    if (code.local_count != expected_locals or
        code.chunk.lexical_slots.len != (if (checked_inventory) width else 0) or
        chunkHasOp(code.chunk, .init_local_lexical) != checked_inventory)
        return error.InvalidProgram;
    const has_checked_load = chunkHasOp(code.chunk, .load_local_lexical) or
        chunkHasOp(code.chunk, .load_upval_lexical);
    if (has_checked_load != (shape == .forward)) return error.InvalidProgram;
    var checksum = foldChecksum(source.len, width);
    checksum = foldChecksum(checksum, @backingInt(shape));
    checksum = foldChecksum(checksum, code.local_count);
    return foldChunk(checksum, code.chunk);
}

fn validateTdzCompileProgram(
    allocator: std.mem.Allocator,
    program: anytype,
    source: []const u8,
    width: usize,
    shape: TdzCompileShape,
) !usize {
    if (program.* != .program or program.program.len != 1) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl or !std.mem.eql(u8, declaration.func_decl.name, "tdzWidth"))
        return error.InvalidProgram;
    const admission = try js.Compiler.admitPlainFunction(allocator, declaration.func_decl);
    const class_deferred = shape == .class_field or shape == .class_static;
    const code = switch (admission) {
        .rejected => |reason| {
            if (!class_deferred or reason != .unsupported_lowering) return error.InvalidProgram;
            var checksum = foldChecksum(source.len, width);
            checksum = foldChecksum(checksum, @backingInt(shape));
            return foldChecksum(checksum, @backingInt(reason));
        },
        .compiled => |compiled| compiled,
    };
    if (class_deferred) return error.InvalidProgram;
    const hazardous = shape == .forward or shape == .self or shape == .nested;
    const expected_locals = width + @intFromBool(shape == .nested);
    if (code.local_count != expected_locals or
        code.chunk.lexical_slots.len != (if (hazardous) width else 0))
        return error.InvalidProgram;
    const has_initializer = chunkHasOp(code.chunk, .init_local_lexical);
    const has_checked_load = chunkHasOp(code.chunk, .load_local_lexical) or
        chunkHasOp(code.chunk, .load_upval_lexical);
    if (has_initializer != hazardous or has_checked_load != hazardous) return error.InvalidProgram;
    var checksum = foldChecksum(source.len, width);
    checksum = foldChecksum(checksum, @backingInt(shape));
    checksum = foldChecksum(checksum, code.local_count);
    return foldChunk(checksum, code.chunk);
}

fn validateLoopCaptureCompileProgram(
    allocator: std.mem.Allocator,
    program: anytype,
    source: []const u8,
    width: usize,
    shape: LoopCaptureCompileShape,
) !usize {
    if (program.* != .program or program.program.len != 1) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl or !std.mem.eql(u8, declaration.func_decl.name, "loopCaptureWidth"))
        return error.InvalidProgram;
    const admission = try js.Compiler.admitPlainFunction(allocator, declaration.func_decl);
    const unsupported_control = shape == .for_of_clear;
    const code = switch (admission) {
        .rejected => |reason| {
            if (!unsupported_control or reason != .unsupported_lowering) return error.InvalidProgram;
            var checksum = foldChecksum(source.len, width);
            checksum = foldChecksum(checksum, @backingInt(shape));
            return foldChecksum(checksum, @backingInt(reason));
        },
        .compiled => |compiled| compiled,
    };
    if (unsupported_control) return error.InvalidProgram;
    const captured = shape == .first or shape == .last or shape == .for_of_last;
    const has_environment = chunkHasOp(code.chunk, .enter_block) and
        chunkHasOp(code.chunk, .exit_block) and chunkHasOp(code.chunk, .def_lex);
    if (has_environment != captured or (!captured and code.local_count < width)) return error.InvalidProgram;
    var checksum = foldChecksum(source.len, width);
    checksum = foldChecksum(checksum, @backingInt(shape));
    checksum = foldChecksum(checksum, code.local_count);
    return foldChunk(checksum, code.chunk);
}

fn validateRepeatedBodyCompileProgram(
    allocator: std.mem.Allocator,
    program: anytype,
    source: []const u8,
    width: usize,
    shape: RepeatedBodyCompileShape,
) !usize {
    if (program.* != .program or program.program.len != 1) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl or !std.mem.eql(u8, declaration.func_decl.name, "repeatedBodyWidth"))
        return error.InvalidProgram;
    const admission = try js.Compiler.admitPlainFunction(allocator, declaration.func_decl);
    const code = switch (admission) {
        .rejected => return error.InvalidProgram,
        .compiled => |compiled| compiled,
    };
    const captured = shape == .first or shape == .last or shape == .destructure_last or
        shape == .catch_last or shape == .switch_last;
    const has_environment = chunkHasOp(code.chunk, .enter_block) and
        chunkHasOp(code.chunk, .exit_block) and chunkHasOp(code.chunk, .def_lex);
    if (has_environment != captured or (!captured and code.local_count < width)) return error.InvalidProgram;
    var checksum = foldChecksum(source.len, width);
    checksum = foldChecksum(checksum, @backingInt(shape));
    checksum = foldChecksum(checksum, code.local_count);
    return foldChunk(checksum, code.chunk);
}

fn validateClassFrameCompileProgram(
    allocator: std.mem.Allocator,
    program: anytype,
    source: []const u8,
    width: usize,
    shape: ClassFrameCompileShape,
) !usize {
    if (program.* != .program or program.program.len != 1) return error.InvalidProgram;
    const declaration = program.program[0];
    if (declaration.* != .func_decl or !std.mem.eql(u8, declaration.func_decl.name, "classFrameWidth"))
        return error.InvalidProgram;
    const admission = try js.Compiler.admitPlainFunction(allocator, declaration.func_decl);
    const frame_capture = shape == .method_first or shape == .method_last or
        shape == .field_last or shape == .static_last;
    const expected_rejection = frame_capture or shape == .superclass_last;
    switch (admission) {
        .rejected => |reason| {
            if (!expected_rejection or reason != .unsupported_lowering) return error.InvalidProgram;
            var checksum = foldChecksum(source.len, width);
            checksum = foldChecksum(checksum, @backingInt(shape));
            return foldChecksum(checksum, @backingInt(reason));
        },
        .compiled => |code| {
            if (expected_rejection or (shape != .environment_last and code.local_count < width))
                return error.InvalidProgram;
            var checksum = foldChecksum(source.len, width);
            checksum = foldChecksum(checksum, @backingInt(shape));
            checksum = foldChecksum(checksum, code.local_count);
            return foldChunk(checksum, code.chunk);
        },
    }
}

fn parseOnce(
    allocator: std.mem.Allocator,
    source: []const u8,
    workload: []const u8,
    expected_radix_bigint: ?[]const u8,
    observation: ?*AllocationObservation,
) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var measured = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var scratch_measured = std.testing.FailingAllocator.init(allocator, .{});
    defer if (observation) |value| {
        value.requests += measured.allocations + measured.resize_index +
            scratch_measured.allocations + scratch_measured.resize_index;
        value.allocated_bytes += measured.allocated_bytes + scratch_measured.allocated_bytes;
    };
    const parser_allocator = if (observation != null) measured.allocator() else arena.allocator();
    const scratch_allocator = if (observation != null) scratch_measured.allocator() else allocator;
    var parser = try js.Parser.initWithScratch(parser_allocator, scratch_allocator, source);
    const program = if (isModuleWorkload(workload)) try parser.parseModule() else try parser.parseProgram();
    if (classFrameCompileShape(workload)) |shape|
        return validateClassFrameCompileProgram(parser_allocator, program, source, try workloadWidth(workload), shape);
    if (repeatedBodyCompileShape(workload)) |shape|
        return validateRepeatedBodyCompileProgram(parser_allocator, program, source, try workloadWidth(workload), shape);
    if (loopCaptureCompileShape(workload)) |shape|
        return validateLoopCaptureCompileProgram(parser_allocator, program, source, try workloadWidth(workload), shape);
    if (tdzCompileShape(workload)) |shape|
        return validateTdzCompileProgram(parser_allocator, program, source, try workloadWidth(workload), shape);
    if (bindingInventoryCompileShape(workload)) |shape|
        return validateBindingInventoryCompileProgram(parser_allocator, program, source, try workloadWidth(workload), shape);
    if (isParamBodyDirectWorkload(workload) or isParamBodyNestedWorkload(workload)) {
        const width = try workloadWidth(workload);
        if (program.* != .program or program.program.len != 1) return error.InvalidProgram;
        const declaration = program.program[0];
        if (declaration.* != .func_decl or declaration.func_decl.params.len != width or
            declaration.func_decl.body.* != .block or declaration.func_decl.body.block.len != 3)
            return error.InvalidProgram;
        const lexical = declaration.func_decl.body.block[1];
        const lexical_name = if (isParamBodyNestedWorkload(workload)) nested: {
            if (lexical.* != .block or lexical.block.len != 1 or lexical.block[0].* != .var_decl or
                lexical.block[0].var_decl.kind != .let or
                !std.mem.eql(u8, lexical.block[0].var_decl.name, "parameter0"))
                return error.InvalidProgram;
            break :nested lexical.block[0].var_decl.name;
        } else direct: {
            if (lexical.* != .var_decl or lexical.var_decl.kind != .let or
                !std.mem.eql(u8, lexical.var_decl.name, "bodyOnly"))
                return error.InvalidProgram;
            break :direct lexical.var_decl.name;
        };
        return source.len + width + declaration.func_decl.body.block.len + lexical_name.len;
    }
    if (isNestedArrowArgumentsWorkload(workload))
        return validateNestedArrowArgumentsProgram(program, source, try workloadWidth(workload));
    if (isNestedFunctionWorkload(workload))
        return validateNestedFunctionProgram(program, source, workload, try workloadWidth(workload));
    if (isStatementLocationWorkload(workload)) {
        const width = try workloadWidth(workload);
        if (isSingleStatementLocationWorkload(workload)) {
            if (program.program.len != 1 or parser.statement_locations.items.len != 1)
                return error.InvalidProgram;
            const declaration = program.program[0];
            if (declaration.* != .var_decl) return error.InvalidProgram;
            const initializer = declaration.var_decl.init orelse return error.InvalidProgram;
            if (initializer.* != .array_lit or initializer.array_lit.len != width)
                return error.InvalidProgram;
            var checksum = width + parser.statement_locations.items.len;
            for (initializer.array_lit, 0..) |element, index| {
                if (element.* != .number or element.number != @as(f64, @floatFromInt(index)))
                    return error.InvalidProgram;
                checksum += index;
            }
            const location = parser.statement_locations.items[0];
            if (location.node != declaration or location.location.byte_offset != 0 or
                location.location.line != 1 or location.location.column != 1)
                return error.InvalidProgram;
            return checksum;
        }

        if (isNestedStatementLocationWorkload(workload)) {
            if (program.program.len != width or parser.statement_locations.items.len != width * 3)
                return error.InvalidProgram;
            const inner_prefix = "if (true) {\n  ";
            const block_offset = "if (true) ".len;
            var checksum = program.program.len + parser.statement_locations.items.len;
            var expected_offset: usize = 0;
            for (program.program, 0..) |statement, index| {
                if (statement.* != .if_stmt or statement.if_stmt.consequent.* != .block or
                    statement.if_stmt.consequent.block.len != 1)
                    return error.InvalidProgram;
                const inner = statement.if_stmt.consequent.block[0];
                if (inner.* != .expr_stmt) return error.InvalidProgram;
                const identifier = switch (inner.expr_stmt.*) {
                    .identifier => |name| name,
                    else => return error.InvalidProgram,
                };
                if (!try indexedName(identifier, "statement", index)) return error.InvalidProgram;
                const inner_location = parser.statement_locations.items[index * 3];
                const block_location = parser.statement_locations.items[index * 3 + 1];
                const outer_location = parser.statement_locations.items[index * 3 + 2];
                if (inner_location.node != inner or block_location.node != statement.if_stmt.consequent or
                    outer_location.node != statement or
                    inner_location.location.byte_offset != expected_offset + inner_prefix.len or
                    inner_location.location.line != index * 3 + 2 or inner_location.location.column != 3 or
                    block_location.location.byte_offset != expected_offset + block_offset or
                    block_location.location.line != index * 3 + 1 or block_location.location.column != block_offset + 1 or
                    outer_location.location.byte_offset != expected_offset or
                    outer_location.location.line != index * 3 + 1 or outer_location.location.column != 1)
                    return error.InvalidProgram;
                checksum += identifier.len + inner_location.location.byte_offset + inner_location.location.line +
                    block_location.location.byte_offset + block_location.location.column +
                    outer_location.location.byte_offset + outer_location.location.line + index;
                expected_offset += inner_prefix.len + "statement".len + std.fmt.count("{d}", .{index}) + ";\n}\n".len;
            }
            if (expected_offset != source.len) return error.InvalidProgram;
            return checksum;
        }

        const mixed = isMixedStatementLocationWorkload(workload);
        if (program.program.len != width or parser.statement_locations.items.len != width)
            return error.InvalidProgram;
        var checksum = program.program.len + parser.statement_locations.items.len;
        var expected_offset: usize = 0;
        for (program.program, parser.statement_locations.items, 0..) |statement, location, index| {
            const prefix_len = if (mixed and index % 2 == 1) statement_location_prefix.len else 0;
            if (statement.* != .expr_stmt) return error.InvalidProgram;
            const identifier = switch (statement.expr_stmt.*) {
                .identifier => |name| name,
                else => return error.InvalidProgram,
            };
            if (!try indexedName(identifier, "statement", index) or location.node != statement or
                location.location.byte_offset != expected_offset + prefix_len or
                location.location.line != index + 1 or location.location.column != prefix_len + 1)
                return error.InvalidProgram;
            checksum += identifier.len + location.location.byte_offset + location.location.line +
                location.location.column + index;
            expected_offset += prefix_len + "statement".len + std.fmt.count("{d}", .{index}) + 1 +
                statementLocationTerminator(index, mixed).len;
        }
        if (expected_offset != source.len) return error.InvalidProgram;
        return checksum;
    }
    if (isModuleWorkload(workload)) {
        const width = try workloadWidth(workload);
        if (program.program.len != 3 or parser.statement_locations.items.len != 1)
            return error.InvalidProgram;
        const import_node = program.program[0];
        const export_node = program.program[1];
        const marker_node = program.program[2];
        if (import_node.* != .import_decl or export_node.* != .export_decl or marker_node.* != .export_decl)
            return error.InvalidProgram;
        const import_decl = import_node.import_decl;
        const export_decl = export_node.export_decl;
        if (!std.mem.eql(u8, import_decl.specifier, "./dependency.js") or
            import_decl.entries.len != width or export_decl.entries.len != width or export_decl.from.len != 0)
            return error.InvalidProgram;
        var checksum = program.program.len + parser.statement_locations.items.len +
            import_decl.specifier.len + import_decl.entries.len + export_decl.entries.len;
        for (0..width) |index| {
            const imported = import_decl.entries[index];
            const exported = export_decl.entries[index];
            if (!try indexedName(imported.imported, "value", index) or
                !try indexedName(imported.local, "imported", index) or imported.namespace or
                !try indexedName(exported.local, "imported", index) or
                !try indexedName(exported.exported, "value", index) or exported.imported.len != 0)
                return error.InvalidProgram;
            checksum += imported.imported.len + imported.local.len + exported.local.len + exported.exported.len + index;
        }
        const marker = marker_node.export_decl.declaration orelse return error.InvalidProgram;
        if (marker.* != .var_decl or marker.var_decl.kind != .@"const" or
            !std.mem.eql(u8, marker.var_decl.name, "marker")) return error.InvalidProgram;
        const initializer = marker.var_decl.init orelse return error.InvalidProgram;
        if (initializer.* != .number or initializer.number != 1) return error.InvalidProgram;
        const location = parser.statement_locations.items[0];
        if (location.node != marker or location.location.line != 1 or
            location.location.column <= 1 or location.location.byte_offset == 0)
            return error.InvalidProgram;
        checksum += marker.var_decl.name.len + @as(usize, @intFromFloat(initializer.number)) +
            location.location.byte_offset + location.location.column;
        return checksum;
    }
    const declaration = program.program[0];
    if (isRegexLiteralWorkload(workload)) {
        if (program.program.len != 1 or declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .array_lit or init_expr.array_lit.len != try workloadWidth(workload))
            return error.InvalidProgram;
        const unicode = isUnicodeRegexLiteralWorkload(workload);
        const annex_b = isAnnexBRegexLiteralWorkload(workload);
        const prefix = if (annex_b) "annex-" else if (unicode) "unicode-" else "literal-";
        const suffix = if (annex_b) "-[\\d-a]+" else if (unicode) "-[a-z]+" else "-(?:[a-z]+|\\d{2,4})";
        const flags = if (unicode) "u" else if (annex_b) "" else "gi";
        var checksum = init_expr.array_lit.len;
        for (init_expr.array_lit, 0..) |element, index| {
            if (element.* != .regex_literal or
                !std.mem.startsWith(u8, element.regex_literal.pattern, prefix) or
                !std.mem.endsWith(u8, element.regex_literal.pattern, suffix) or
                !std.mem.eql(u8, element.regex_literal.flags, flags))
                return error.InvalidProgram;
            const index_text = element.regex_literal.pattern[prefix.len .. element.regex_literal.pattern.len - suffix.len];
            if (try std.fmt.parseUnsigned(usize, index_text, 10) != index)
                return error.InvalidProgram;
            checksum += element.regex_literal.pattern.len + element.regex_literal.flags.len + index;
        }
        return checksum;
    }
    if (isRadixBigIntWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .bigint_lit) return error.InvalidProgram;
        const text = init_expr.bigint_lit.text orelse return error.InvalidProgram;
        return validatedRadixBigIntChecksum(text, expected_radix_bigint orelse return error.InvalidProgram);
    }
    if (isDecimalBigIntWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .bigint_lit) return error.InvalidProgram;
        const text = init_expr.bigint_lit.text orelse return error.InvalidProgram;
        if (text.len != try workloadWidth(workload)) return error.InvalidProgram;
        return validatedDecimalBigIntChecksum(text);
    }
    if (isPrivateNameWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .class_expr) return error.InvalidProgram;
        var checksum = init_expr.class_expr.members.len;
        for (init_expr.class_expr.members, 0..) |member, index| {
            if (!member.is_field or member.key_expr != null or member.key.len < "#field".len or
                !std.mem.eql(u8, member.key[0.."#field".len], "#field")) return error.InvalidProgram;
            if (try std.fmt.parseUnsigned(usize, member.key["#field".len..], 10) != index)
                return error.InvalidProgram;
            checksum += member.key.len;
        }
        return checksum;
    }
    if (isTaggedSubstitutionWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .tagged_template) return error.InvalidProgram;
        const template = init_expr.tagged_template;
        const width = try workloadWidth(workload);
        if (template.cooked.len != width + 1 or template.raw.len != width + 1 or template.exprs.len != width)
            return error.InvalidProgram;
        const prefix = "quasi-";
        const suffix = "-abcdefghijklmnopqrstuvwxyz";
        var checksum = template.cooked.len + template.raw.len + template.exprs.len;
        for (template.cooked, template.raw, 0..) |cooked_optional, raw, index| {
            const cooked = cooked_optional orelse return error.InvalidProgram;
            if (!std.mem.eql(u8, cooked, raw) or
                @intFromPtr(cooked.ptr) != @intFromPtr(raw.ptr) or
                !std.mem.startsWith(u8, cooked, prefix) or
                !std.mem.endsWith(u8, cooked, suffix)) return error.InvalidProgram;
            const index_text = cooked[prefix.len .. cooked.len - suffix.len];
            if (try std.fmt.parseUnsigned(usize, index_text, 10) != index)
                return error.InvalidProgram;
            checksum += cooked.len;
        }
        for (template.exprs, 0..) |expression, index| {
            if (expression.* != .number or expression.number != @as(f64, @floatFromInt(index)))
                return error.InvalidProgram;
            checksum += index;
        }
        return checksum;
    }
    if (isStringWorkload(workload) or isTemplateWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .array_lit) return error.InvalidProgram;
        var checksum = init_expr.array_lit.len;
        for (init_expr.array_lit, 0..) |element, index| {
            if (isTaggedTemplateWorkload(workload)) {
                if (element.* != .tagged_template) return error.InvalidProgram;
                if (element.tagged_template.cooked.len != 1 or element.tagged_template.raw.len != 1 or element.tagged_template.exprs.len != 0)
                    return error.InvalidProgram;
                const cooked = element.tagged_template.cooked[0] orelse return error.InvalidProgram;
                const raw = element.tagged_template.raw[0];
                const prefix = if (isNormalizedTemplateWorkload(workload)) "line\nliteral-" else "literal-";
                const suffix = if (isNormalizedTemplateWorkload(workload))
                    "\ntail-abcdefghijklmnopqrstuvwxyz0123456789"
                else
                    "-abcdefghijklmnopqrstuvwxyz0123456789";
                if (!std.mem.eql(u8, cooked, raw) or cooked.len <= prefix.len + suffix.len or
                    !std.mem.startsWith(u8, cooked, prefix) or
                    !std.mem.endsWith(u8, cooked, suffix)) return error.InvalidProgram;
                const index_text = cooked[prefix.len .. cooked.len - suffix.len];
                if (try std.fmt.parseUnsigned(usize, index_text, 10) != index)
                    return error.InvalidProgram;
                checksum += cooked.len;
            } else {
                if (element.* != .string) return error.InvalidProgram;
                if (isStringWorkload(workload)) {
                    const prefix = "literal-";
                    const suffix = "-abcdefghijklmnopqrstuvwxyz0123456789";
                    if (element.string.len <= prefix.len + suffix.len or
                        !std.mem.startsWith(u8, element.string, prefix) or
                        !std.mem.endsWith(u8, element.string, suffix)) return error.InvalidProgram;
                    const index_text = element.string[prefix.len .. element.string.len - suffix.len];
                    if (try std.fmt.parseUnsigned(usize, index_text, 10) != index)
                        return error.InvalidProgram;
                }
                if (isTemplateWorkload(workload)) {
                    const prefix = if (isNormalizedTemplateWorkload(workload)) "line\nliteral-" else "literal-";
                    const suffix = if (isNormalizedTemplateWorkload(workload))
                        "\ntail-abcdefghijklmnopqrstuvwxyz0123456789"
                    else
                        "-abcdefghijklmnopqrstuvwxyz0123456789";
                    if (element.string.len <= prefix.len + suffix.len or
                        !std.mem.startsWith(u8, element.string, prefix) or
                        !std.mem.endsWith(u8, element.string, suffix)) return error.InvalidProgram;
                    const index_text = element.string[prefix.len .. element.string.len - suffix.len];
                    if (try std.fmt.parseUnsigned(usize, index_text, 10) != index)
                        return error.InvalidProgram;
                }
                checksum += element.string.len;
            }
        }
        return checksum;
    }
    if (isNumericWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .array_lit or init_expr.array_lit.len == 0) return error.InvalidProgram;
        var checksum: usize = init_expr.array_lit.len;
        for (init_expr.array_lit, 0..) |element, index| {
            if (element.* != .number) return error.InvalidProgram;
            const expected = 100_000_000_000 + index;
            if (element.number != @as(f64, @floatFromInt(expected))) return error.InvalidProgram;
            checksum += @intFromFloat(element.number);
        }
        return checksum;
    }
    if (declaration.* != .func_decl) return error.InvalidProgram;
    if (!isEscapedIdentifierWorkload(workload) and !isUnicodeIdentifierWorkload(workload))
        return declaration.func_decl.params.len + 7;
    var checksum = declaration.func_decl.params.len + 7;
    for (declaration.func_decl.params, 0..) |param, index| {
        const prefix = if (isUnicodeIdentifierWorkload(workload))
            unicode_identifier_prefixes[index % unicode_identifier_prefixes.len]
        else
            "parameter";
        if (param.name.len < prefix.len or !std.mem.eql(u8, param.name[0..prefix.len], prefix))
            return error.InvalidProgram;
        if (try std.fmt.parseUnsigned(usize, param.name[prefix.len..], 10) != index)
            return error.InvalidProgram;
        checksum += param.name.len;
    }
    return checksum;
}

fn runJobs(
    allocator: std.mem.Allocator,
    source: []const u8,
    jobs: usize,
    workload: []const u8,
    expected_radix_bigint: ?[]const u8,
) !usize {
    var checksum: usize = 0;
    for (0..jobs) |_| checksum += try parseOnce(allocator, source, workload, expected_radix_bigint, null);
    return checksum;
}

fn observeJobAllocations(
    allocator: std.mem.Allocator,
    source: []const u8,
    jobs: usize,
    workload: []const u8,
    expected_radix_bigint: ?[]const u8,
    observation: *AllocationObservation,
) !usize {
    var checksum: usize = 0;
    for (0..jobs) |_| checksum += try parseOnce(allocator, source, workload, expected_radix_bigint, observation);
    return checksum;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if ((args.len != 5 and args.len != 6) or !std.mem.eql(u8, args[1], "single")) return error.InvalidArguments;
    const darwin_rusage = args.len == 6 and std.mem.eql(u8, args[5], "--darwin-rusage");
    if (args.len == 6 and !darwin_rusage) return error.InvalidArguments;
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    if (jobs == 0 or samples == 0) return error.InvalidArguments;

    const width = try workloadWidth(workload);
    const string_workload = isStringWorkload(workload);
    const template_workload = isTemplateWorkload(workload);
    const private_name_workload = isPrivateNameWorkload(workload);
    const numeric_workload = isNumericWorkload(workload);
    const decimal_bigint_workload = isDecimalBigIntWorkload(workload);
    const radix_bigint_workload = isRadixBigIntWorkload(workload);
    const module_workload = isModuleWorkload(workload);
    const statement_location_workload = isStatementLocationWorkload(workload);
    const nested_function_workload = isNestedFunctionWorkload(workload);
    const nested_arrow_workload = isNestedArrowArgumentsWorkload(workload);
    const regex_literal_workload = isRegexLiteralWorkload(workload);
    const class_frame_compile_shape = classFrameCompileShape(workload);
    const repeated_body_compile_shape = repeatedBodyCompileShape(workload);
    const loop_capture_compile_shape = loopCaptureCompileShape(workload);
    const tdz_compile_shape = tdzCompileShape(workload);
    const binding_inventory_compile_shape = bindingInventoryCompileShape(workload);
    var expected_radix_bigint: ?[]const u8 = null;
    const source = if (class_frame_compile_shape) |shape|
        try classFrameCompileSource(init.arena.allocator(), width, shape)
    else if (repeated_body_compile_shape) |shape|
        try repeatedBodyCompileSource(init.arena.allocator(), width, shape)
    else if (loop_capture_compile_shape) |shape|
        try loopCaptureCompileSource(init.arena.allocator(), width, shape)
    else if (tdz_compile_shape) |shape|
        try tdzCompileSource(init.arena.allocator(), width, shape)
    else if (binding_inventory_compile_shape) |shape|
        try bindingInventoryCompileSource(init.arena.allocator(), width, shape)
    else if (regex_literal_workload)
        try regexLiteralSource(
            init.arena.allocator(),
            width,
            isUnicodeRegexLiteralWorkload(workload),
            isAnnexBRegexLiteralWorkload(workload),
        )
    else if (nested_arrow_workload)
        try nestedArrowArgumentsSource(init.arena.allocator(), width)
    else if (nested_function_workload)
        try nestedFunctionSource(
            init.arena.allocator(),
            width,
            isNestedFunctionDecoyWorkload(workload),
            isNestedFunctionArgumentsWorkload(workload),
        )
    else if (statement_location_workload)
        try statementLocationSource(
            init.arena.allocator(),
            width,
            isMixedStatementLocationWorkload(workload),
            isNestedStatementLocationWorkload(workload),
            isSingleStatementLocationWorkload(workload),
        )
    else if (module_workload)
        try moduleSource(init.arena.allocator(), width)
    else if (isTaggedSubstitutionWorkload(workload))
        try taggedSubstitutionSource(init.arena.allocator(), width)
    else if (private_name_workload)
        try privateClassSource(
            init.arena.allocator(),
            width,
            isEscapedPrivateNameWorkload(workload),
        )
    else if (string_workload)
        try stringLiteralSource(
            init.arena.allocator(),
            width,
            isEscapedStringWorkload(workload),
        )
    else if (template_workload)
        try templateLiteralSource(
            init.arena.allocator(),
            width,
            isEscapedTemplateWorkload(workload),
            isNormalizedTemplateWorkload(workload),
            isTaggedTemplateWorkload(workload),
        )
    else if (numeric_workload)
        try numericLiteralSource(
            init.arena.allocator(),
            width,
            isSeparatedNumericWorkload(workload),
        )
    else if (decimal_bigint_workload)
        try decimalBigIntSource(
            init.arena.allocator(),
            width,
            isSeparatedDecimalBigIntWorkload(workload),
        )
    else if (radix_bigint_workload) source: {
        const prepared = try radixBigIntSource(init.arena.allocator(), width);
        expected_radix_bigint = prepared.expected_decimal;
        break :source prepared.source;
    } else if (isUnicodeIdentifierWorkload(workload))
        try unicodeIdentifierSource(init.arena.allocator(), width)
    else
        try strictFunctionSource(
            init.arena.allocator(),
            width,
            isEscapedIdentifierWorkload(workload),
            if (isParamBodyDirectWorkload(workload))
                .direct_lexical
            else if (isParamBodyNestedWorkload(workload))
                .nested_lexical
            else
                .ordinary,
        );
    // Compiler witnesses are intentionally cold/dynamic compilation rows. Two
    // complete untimed jobs settle process startup without turning repeated
    // attacker-sized classifier walks into an unreported timing boundary.
    const workload_warmups: usize = if (binding_inventory_compile_shape != null or tdz_compile_shape != null or loop_capture_compile_shape != null or repeated_body_compile_shape != null or class_frame_compile_shape != null) 2 else warmup_calls;
    for (0..workload_warmups) |_| _ = try runJobs(init.gpa, source, @max(@as(usize, 1), jobs / 10), workload, expected_radix_bigint);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (0..samples) |sample| {
        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const started = nowNs(init.io);
        const checksum = try runJobs(init.gpa, source, jobs, workload, expected_radix_bigint);
        const elapsed: u64 = @intCast(nowNs(init.io) - started);
        const counters_after = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const thermal_after = if (darwin_rusage) try darwinThermalState() else undefined;
        try stdout.print("zig-js\tsingle\t{s}\t1\t{d}\t{d}\t{d}\t{d}\n", .{
            workload, jobs, sample, elapsed, checksum,
        });
        if (darwin_rusage) {
            try printDarwinCounterRow(stdout, workload, jobs, sample, counters_before, counters_after, thermal_before, thermal_after);

            // Allocation observation is an untimed replay of identical work so
            // counting overhead cannot contaminate wall or hardware counters.
            var allocation_observation: AllocationObservation = .{};
            const allocation_checksum = try observeJobAllocations(init.gpa, source, jobs, workload, expected_radix_bigint, &allocation_observation);
            if (allocation_checksum != checksum) return error.InvalidProgram;
            try stdout.print("zig-js-frontend-allocations\tsingle\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
                workload,
                jobs,
                sample,
                allocation_observation.requests,
                allocation_observation.allocated_bytes,
            });
        }
    }
    try stdout.flush();
}
