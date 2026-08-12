//! Parser-only growth runner for representative frontend complexity witnesses.
//!
//! Usage:
//!   frontend-parse-benchmark single <workload> <jobs> <samples>

const std = @import("std");
const js = @import("js");

const warmup_calls = 10;

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
    if (args.len != 5 or !std.mem.eql(u8, args[1], "single")) return error.InvalidArguments;
    const workload = args[2];
    const jobs = try std.fmt.parseUnsigned(usize, args[3], 10);
    const samples = try std.fmt.parseUnsigned(usize, args[4], 10);
    if (jobs == 0 or samples == 0) return error.InvalidArguments;

    const width = try workloadWidth(workload);
    const string_workload = isStringWorkload(workload);
    const template_workload = isTemplateWorkload(workload);
    const private_name_workload = isPrivateNameWorkload(workload);
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
    else
        try strictFunctionSource(init.arena.allocator(), width, isEscapedIdentifierWorkload(workload));
    for (0..warmup_calls) |_| _ = try runJobs(init.gpa, source, @max(@as(usize, 1), jobs / 10), workload);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (0..samples) |sample| {
        const started = nowNs(init.io);
        const checksum = try runJobs(init.gpa, source, jobs, workload);
        const elapsed: u64 = @intCast(nowNs(init.io) - started);
        try stdout.print("zig-js\tsingle\t{s}\t1\t{d}\t{d}\t{d}\t{d}\n", .{
            workload, jobs, sample, elapsed, checksum,
        });
    }
    try stdout.flush();
}
