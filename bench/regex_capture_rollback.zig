//! Exact-parent cost controls for zig-regex's bounded-repeat capture rollback.
//! Compile this same source against each dependency revision with ReleaseFast
//! and libc. This is a regex-library microbenchmark, not a JavaScript score.
const std = @import("std");
const builtin = @import("builtin");
const Regex = @import("regex").Regex;

const Row = struct {
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    expected_end: usize,
    expected_capture: []const u8,
};

const input64 = "abababababababababababababababababababababababababababababababab";
const rows = [_]Row{
    .{ .name = "max_bound", .pattern = "(?=a)(a|b){1,64}", .input = input64, .expected_end = 64, .expected_capture = "b" },
    .{ .name = "failed_extra", .pattern = "(?=a)(a|b){1,64}", .input = input64[0..62], .expected_end = 62, .expected_capture = "b" },
    .{ .name = "exact_bound_control", .pattern = "(?=a)(a|b){64}", .input = input64, .expected_end = 64, .expected_capture = "b" },
    .{ .name = "lazy_control", .pattern = "(?=a)(a|b){1,64}?", .input = input64, .expected_end = 1, .expected_capture = "a" },
};

fn monotonicNs() !u64 {
    const clock: std.c.clockid_t = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => .UPTIME_RAW,
        else => .MONOTONIC,
    };
    var stamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock, &stamp) != 0) return error.ClockUnavailable;
    return @as(u64, @intCast(stamp.sec)) * 1_000_000_000 + @as(u64, @intCast(stamp.nsec));
}

fn checkedMatch(matcher: *Regex.Matcher, row: Row) !u64 {
    var match = (try matcher.findFrom(row.input, 0)) orelse return error.MissingMatch;
    defer match.deinit(std.heap.c_allocator);
    if (match.start != 0 or match.end != row.expected_end or
        !std.mem.eql(u8, match.slice, row.input[0..row.expected_end]) or
        match.captures.len != 1 or match.captures_present.len != 1 or
        !match.captures_present[0] or
        !std.mem.eql(u8, match.captures[0], row.expected_capture)) return error.WrongMatch;
    return @as(u64, @intCast(match.end)) * 257 + match.captures[0][0];
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const name = args.next() orelse return error.MissingRow;
    const iterations = try std.fmt.parseInt(usize, args.next() orelse return error.MissingIterations, 10);
    if (iterations == 0 or iterations > 1_000_000 or args.next() != null) return error.InvalidArguments;
    const row = for (rows) |candidate| {
        if (std.mem.eql(u8, name, candidate.name)) break candidate;
    } else return error.UnknownRow;

    var regex = try Regex.compileWithFlags(std.heap.c_allocator, row.pattern, .{ .ecmascript = true });
    defer regex.deinit();
    if (regex.engine_type != .backtracking) return error.WrongEngine;
    var matcher = regex.matcher();
    defer matcher.deinit();
    // Compilation, allocator startup, and these ten matching warmups are outside
    // the timer. Validation and result destruction are inside it on both sides.
    for (0..10) |_| _ = try checkedMatch(&matcher, row);
    const start = try monotonicNs();
    var checksum: u64 = 0;
    for (0..iterations) |_| checksum += try checkedMatch(&matcher, row);
    const elapsed = (try monotonicNs()) - start;
    std.debug.print("SAMPLE\t{s}\t{d}\t{d}\t{d}\n", .{ row.name, iterations, elapsed, checksum });
}
