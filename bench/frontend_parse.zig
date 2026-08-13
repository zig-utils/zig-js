//! Parser-only growth runner for representative frontend complexity witnesses.
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
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_strict_params_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_escaped_identifiers_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_escaped_identifiers_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_escaped_identifiers_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_private_names_escaped_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_strings_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_strings_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_strings_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_strings_escaped_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_templates_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_templates_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_escaped_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_templates_tagged_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_separators_1024")) return 1024;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_separators_2048")) return 2048;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_separators_4096")) return 4096;
    if (std.mem.eql(u8, name, "representative_frontend_numeric_unseparated_4096")) return 4096;
    return error.InvalidWorkload;
}

fn isStringWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_strings_");
}

fn isTemplateWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_templates_");
}

fn isTaggedTemplateWorkload(name: []const u8) bool {
    return std.mem.eql(u8, name, "representative_frontend_templates_tagged_4096");
}

fn isEscapedIdentifierWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_escaped_identifiers_");
}

fn isPrivateNameWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_private_names_");
}

fn isNumericWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_numeric_");
}

fn isSeparatedNumericWorkload(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "representative_frontend_numeric_separators_");
}

fn strictFunctionSource(allocator: std.mem.Allocator, width: usize, escaped: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "function strictWidth(");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        try source.appendSlice(allocator, if (escaped) "paramet\\u0065r" else "parameter");
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

fn templateLiteralSource(allocator: std.mem.Allocator, width: usize, escaped: bool, tagged: bool) ![]const u8 {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(allocator, "var templateCorpus = [");
    for (0..width) |index| {
        if (index != 0) try source.append(allocator, ',');
        if (tagged) try source.appendSlice(allocator, "tag");
        try source.appendSlice(allocator, if (escaped) "`\\u006citeral-" else "`literal-");
        try source.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{index}));
        try source.appendSlice(allocator, "-abcdefghijklmnopqrstuvwxyz0123456789`");
    }
    try source.appendSlice(allocator, "];\n");
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

fn parseOnce(allocator: std.mem.Allocator, source: []const u8, workload: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = try js.Parser.init(arena.allocator(), source);
    const program = try parser.parseProgram();
    const declaration = program.program[0];
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
    if (isStringWorkload(workload) or isTemplateWorkload(workload)) {
        if (declaration.* != .var_decl) return error.InvalidProgram;
        const init_expr = declaration.var_decl.init orelse return error.InvalidProgram;
        if (init_expr.* != .array_lit) return error.InvalidProgram;
        var checksum = init_expr.array_lit.len;
        for (init_expr.array_lit) |element| {
            if (isTaggedTemplateWorkload(workload)) {
                if (element.* != .tagged_template) return error.InvalidProgram;
                if (element.tagged_template.cooked.len != 1 or element.tagged_template.raw.len != 1 or element.tagged_template.exprs.len != 0)
                    return error.InvalidProgram;
                checksum += (element.tagged_template.cooked[0] orelse return error.InvalidProgram).len;
            } else {
                if (element.* != .string) return error.InvalidProgram;
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
    if (!isEscapedIdentifierWorkload(workload)) return declaration.func_decl.params.len + 7;
    var checksum = declaration.func_decl.params.len + 7;
    for (declaration.func_decl.params, 0..) |param, index| {
        if (param.name.len < "parameter".len or !std.mem.eql(u8, param.name[0.."parameter".len], "parameter"))
            return error.InvalidProgram;
        if (try std.fmt.parseUnsigned(usize, param.name["parameter".len..], 10) != index)
            return error.InvalidProgram;
        checksum += param.name.len;
    }
    return checksum;
}

fn runJobs(allocator: std.mem.Allocator, source: []const u8, jobs: usize, workload: []const u8) !usize {
    var checksum: usize = 0;
    for (0..jobs) |_| checksum += try parseOnce(allocator, source, workload);
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
    const source = if (private_name_workload)
        try privateClassSource(
            init.arena.allocator(),
            width,
            std.mem.eql(u8, workload, "representative_frontend_private_names_escaped_4096"),
        )
    else if (string_workload)
        try stringLiteralSource(
            init.arena.allocator(),
            width,
            std.mem.eql(u8, workload, "representative_frontend_strings_escaped_4096"),
        )
    else if (template_workload)
        try templateLiteralSource(
            init.arena.allocator(),
            width,
            std.mem.eql(u8, workload, "representative_frontend_templates_escaped_4096"),
            isTaggedTemplateWorkload(workload),
        )
    else if (numeric_workload)
        try numericLiteralSource(
            init.arena.allocator(),
            width,
            isSeparatedNumericWorkload(workload),
        )
    else
        try strictFunctionSource(init.arena.allocator(), width, isEscapedIdentifierWorkload(workload));
    for (0..warmup_calls) |_| _ = try runJobs(init.gpa, source, @max(@as(usize, 1), jobs / 10), workload);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (0..samples) |sample| {
        const thermal_before = if (darwin_rusage) try darwinThermalState() else undefined;
        const counters_before = if (darwin_rusage) try darwinCounterSnapshot() else undefined;
        const started = nowNs(init.io);
        const checksum = try runJobs(init.gpa, source, jobs, workload);
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
            var measured = std.testing.FailingAllocator.init(init.gpa, .{});
            const allocation_checksum = try runJobs(measured.allocator(), source, jobs, workload);
            if (allocation_checksum != checksum) return error.InvalidProgram;
            try stdout.print("zig-js-frontend-allocations\tsingle\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
                workload,
                jobs,
                sample,
                measured.allocations + measured.resize_index,
                measured.allocated_bytes,
            });
        }
    }
    try stdout.flush();
}
