const std = @import("std");

pub const usage =
    \\usage: test262 [mode]
    \\
    \\With no mode, run the complete configured corpus.
    \\
    \\  --help
    \\  --diag <subtree> [path-substring]
    \\  --eval <file> [tree|vm]
    \\  --vm-witness <test.js> [test.js ...]
    \\  --vm-witness-subtree <subtree> [path-substring]
    \\  --list-skips
    \\  --list-excluded
    \\  --drive-subtree <subtree>                 (internal)
    \\  --worker <subtree> <start-index> <limit>  (internal)
    \\
;

/// Which tier `--eval` forces. `automatic` is the engine's own admission
/// policy; `tree` and `vm` pin the tree walker and required bytecode, which is
/// how a tier divergence found by `--vm-witness-subtree` gets reduced to a
/// minimal script.
pub const EvalMode = enum { automatic, tree, vm };

pub const Command = union(enum) {
    parent,
    help,
    worker: struct { subtree: []const u8, start: usize, limit: usize },
    drive_subtree: []const u8,
    diag: struct { subtree: []const u8, filter: ?[]const u8 },
    eval: struct { path: []const u8, mode: EvalMode },
    vm_witness: []const []const u8,
    vm_witness_subtree: struct { subtree: []const u8, filter: ?[]const u8 },
    list_skips,
    list_excluded,
};

pub fn parse(args: []const []const u8) error{InvalidArguments}!Command {
    if (args.len == 0) return .parent;
    const mode = args[0];
    if (std.mem.eql(u8, mode, "--help"))
        return if (args.len == 1) .help else error.InvalidArguments;
    if (std.mem.eql(u8, mode, "--worker")) {
        if (args.len != 4) return error.InvalidArguments;
        return .{ .worker = .{
            .subtree = args[1],
            .start = std.fmt.parseUnsigned(usize, args[2], 10) catch return error.InvalidArguments,
            .limit = std.fmt.parseUnsigned(usize, args[3], 10) catch return error.InvalidArguments,
        } };
    }
    if (std.mem.eql(u8, mode, "--drive-subtree"))
        return if (args.len == 2) .{ .drive_subtree = args[1] } else error.InvalidArguments;
    if (std.mem.eql(u8, mode, "--diag")) {
        if (args.len != 2 and args.len != 3) return error.InvalidArguments;
        return .{ .diag = .{ .subtree = args[1], .filter = if (args.len == 3) args[2] else null } };
    }
    if (std.mem.eql(u8, mode, "--eval")) {
        if (args.len == 2) return .{ .eval = .{ .path = args[1], .mode = .automatic } };
        if (args.len == 3) {
            const forced: EvalMode = if (std.mem.eql(u8, args[2], "tree"))
                .tree
            else if (std.mem.eql(u8, args[2], "vm"))
                .vm
            else
                return error.InvalidArguments;
            return .{ .eval = .{ .path = args[1], .mode = forced } };
        }
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, mode, "--vm-witness-subtree")) {
        if (args.len != 2 and args.len != 3) return error.InvalidArguments;
        return .{ .vm_witness_subtree = .{ .subtree = args[1], .filter = if (args.len == 3) args[2] else null } };
    }
    if (std.mem.eql(u8, mode, "--vm-witness"))
        return if (args.len >= 2) .{ .vm_witness = args[1..] } else error.InvalidArguments;
    if (std.mem.eql(u8, mode, "--list-skips"))
        return if (args.len == 1) .list_skips else error.InvalidArguments;
    if (std.mem.eql(u8, mode, "--list-excluded"))
        return if (args.len == 1) .list_excluded else error.InvalidArguments;
    return error.InvalidArguments;
}

fn expectTag(expected: std.meta.Tag(Command), args: []const []const u8) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(try parse(args)));
}

test "test262 CLI preserves the intentional no-argument full run" {
    try expectTag(.parent, &.{});
}

test "test262 CLI recognizes every exact mode contract" {
    try expectTag(.help, &.{"--help"});
    const worker = (try parse(&.{ "--worker", "test/language", "17", "4" })).worker;
    try std.testing.expectEqualStrings("test/language", worker.subtree);
    try std.testing.expectEqual(@as(usize, 17), worker.start);
    try std.testing.expectEqual(@as(usize, 4), worker.limit);
    try expectTag(.drive_subtree, &.{ "--drive-subtree", "test/language" });
    const diagnostic = (try parse(&.{ "--diag", "test/language", "class" })).diag;
    try std.testing.expectEqualStrings("class", diagnostic.filter.?);
    try std.testing.expect((try parse(&.{ "--diag", "test/language" })).diag.filter == null);
    try expectTag(.eval, &.{ "--eval", "probe.js" });
    try std.testing.expectEqual(EvalMode.automatic, (try parse(&.{ "--eval", "probe.js" })).eval.mode);
    try std.testing.expectEqual(EvalMode.tree, (try parse(&.{ "--eval", "probe.js", "tree" })).eval.mode);
    try std.testing.expectEqual(EvalMode.vm, (try parse(&.{ "--eval", "probe.js", "vm" })).eval.mode);
    const witnesses = (try parse(&.{ "--vm-witness", "one.js", "two.js" })).vm_witness;
    try std.testing.expectEqual(@as(usize, 2), witnesses.len);
    try expectTag(.vm_witness_subtree, &.{ "--vm-witness-subtree", "test/language" });
    try expectTag(.vm_witness_subtree, &.{ "--vm-witness-subtree", "test/language", "for" });
    try expectTag(.list_skips, &.{"--list-skips"});
    try expectTag(.list_excluded, &.{"--list-excluded"});
}

test "test262 CLI usage documents every accepted named mode" {
    for ([_][]const u8{
        "--help",
        "--worker",
        "--drive-subtree",
        "--diag",
        "--eval",
        "--vm-witness",
        "--vm-witness-subtree",
        "--list-skips",
        "--list-excluded",
    }) |mode| try std.testing.expect(std.mem.indexOf(u8, usage, mode) != null);
}

test "test262 CLI rejects unknown incomplete malformed and trailing arguments" {
    const invalid = [_][]const []const u8{
        &.{"--unknown"},
        &.{ "--help", "extra" },
        &.{"--worker"},
        &.{ "--worker", "test/language", "bad", "4" },
        &.{ "--worker", "test/language", "0", "bad" },
        &.{ "--drive-subtree", "test/language", "extra" },
        &.{"--diag"},
        &.{ "--diag", "test/language", "filter", "extra" },
        &.{"--eval"},
        &.{ "--eval", "probe.js", "bogus-mode" },
        &.{ "--eval", "probe.js", "vm", "extra" },
        &.{"--vm-witness"},
        &.{"--vm-witness-subtree"},
        &.{ "--vm-witness-subtree", "test/language", "for", "extra" },
        &.{ "--list-skips", "extra" },
        &.{ "--list-excluded", "extra" },
    };
    for (invalid) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
}
