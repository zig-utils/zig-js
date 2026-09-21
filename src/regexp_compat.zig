const std = @import("std");
const regex = @import("regex");

pub fn compileErrorMessage(reason: regex.CompileErrorReason) []const u8 {
    return switch (reason) {
        .missing_closing_parenthesis => "Invalid regular expression: missing )",
        .missing_character_class_terminator => "Invalid regular expression: missing terminating ] for character class",
        .quantifier_numbers_out_of_order => "Invalid regular expression: numbers out of order in {} quantifier",
        .nothing_to_repeat => "Invalid regular expression: nothing to repeat",
        .trailing_backslash => "Invalid regular expression: \\ at end of pattern",
        .invalid_group_specifier_name => "Invalid regular expression: invalid group specifier name",
        .range_out_of_order_in_character_class => "Invalid regular expression: range out of order in character class",
        .duplicate_group_specifier_name => "Invalid regular expression: duplicate group specifier name",
        .invalid_named_backreference => "Invalid regular expression: invalid \\k<> named backreference",
        .invalid_property_expression => "Invalid regular expression: invalid property expression",
        .invalid_escaped_character_for_unicode_pattern => "Invalid regular expression: invalid escaped character for Unicode pattern",
        .invalid_unicode_escape => "Invalid regular expression: invalid Unicode \\u escape",
        .invalid_unicode_code_point_escape => "Invalid regular expression: invalid Unicode code point \\u{} escape",
        .invalid_octal_escape_for_unicode_pattern => "Invalid regular expression: invalid octal escape for Unicode pattern",
        .invalid_range_in_character_class_for_unicode_pattern => "Invalid regular expression: invalid range in character class for Unicode pattern",
        .invalid_backreference_for_unicode_pattern => "Invalid regular expression: invalid backreference for Unicode pattern",
        .unrecognized_character_after_group_start => "Invalid regular expression: unrecognized character after (?",
        .unmatched_parentheses => "Invalid regular expression: unmatched parentheses",
    };
}

fn isLegacyClassEscape(c: u8) bool {
    return switch (c) {
        'd', 'D', 's', 'S', 'w', 'W' => true,
        else => false,
    };
}

pub const NormalizedPattern = struct {
    bytes: []const u8,
    owned: bool,

    pub fn borrowed(bytes: []const u8) NormalizedPattern {
        return .{ .bytes = bytes, .owned = false };
    }

    pub fn deinit(self: NormalizedPattern, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(@constCast(self.bytes));
    }
};

const NormalizedSize = struct {
    len: usize,
    changed: bool,
};

fn normalizedSize(pattern: []const u8) error{OutOfMemory}!NormalizedSize {
    var output_len = pattern.len;
    var changed = false;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\') {
            if (in_class and i + 1 < pattern.len and pattern[i + 1] == '-') {
                output_len = std.math.add(usize, output_len, 2) catch return error.OutOfMemory; // `\-` -> `\x2d`
                changed = true;
                i += 2;
                continue;
            }
            if (in_class and i + 2 < pattern.len and isLegacyClassEscape(pattern[i + 1]) and pattern[i + 2] == '-') {
                output_len = std.math.add(usize, output_len, 3) catch return error.OutOfMemory; // `\d-` -> `\d\x2d`
                changed = true;
                i += 3;
                continue;
            }
            i += @min(@as(usize, 2), pattern.len - i);
            continue;
        }
        if (in_class and c == '-' and i + 2 < pattern.len and pattern[i + 1] == '\\' and isLegacyClassEscape(pattern[i + 2])) {
            output_len = std.math.add(usize, output_len, 3) catch return error.OutOfMemory; // `-\d` -> `\x2d\d`
            changed = true;
            i += 1;
            continue;
        }
        if (c == '[') in_class = true else if (c == ']') in_class = false;
        i += 1;
    }
    return .{ .len = output_len, .changed = changed };
}

/// Annex B permits non-Unicode character class "ranges" where one side is a
/// class escape, treating the `-` as a literal union member. zig-regex rejects
/// those as invalid ranges, so compile an equivalent pattern with `\x2d`.
pub fn normalizeAnnexBClassRanges(allocator: std.mem.Allocator, pattern: []const u8) !NormalizedPattern {
    const size = try normalizedSize(pattern);
    if (!size.changed) return .borrowed(pattern);

    const out = try allocator.alloc(u8, size.len);
    errdefer allocator.free(out);
    var written: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\') {
            if (in_class and i + 1 < pattern.len and pattern[i + 1] == '-') {
                @memcpy(out[written .. written + 4], "\\x2d");
                written += 4;
                i += 2;
                continue;
            }
            if (in_class and i + 2 < pattern.len and isLegacyClassEscape(pattern[i + 1]) and pattern[i + 2] == '-') {
                @memcpy(out[written .. written + 2], pattern[i .. i + 2]);
                written += 2;
                @memcpy(out[written .. written + 4], "\\x2d");
                written += 4;
                i += 3;
                continue;
            }
            const end = @min(i + 2, pattern.len);
            @memcpy(out[written .. written + end - i], pattern[i..end]);
            written += end - i;
            i = end;
            continue;
        }
        if (in_class and c == '-' and i + 2 < pattern.len and pattern[i + 1] == '\\' and isLegacyClassEscape(pattern[i + 2])) {
            @memcpy(out[written .. written + 4], "\\x2d");
            written += 4;
            i += 1;
            continue;
        }
        out[written] = c;
        written += 1;
        if (c == '[') in_class = true else if (c == ']') in_class = false;
        i += 1;
    }
    std.debug.assert(written == out.len);
    return .{ .bytes = out, .owned = true };
}

test "Annex B class normalization borrows unchanged source and owns one exact rewrite" {
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    const unchanged_source = "literal-(?:[a-z]+|\\d{2,4})";
    const unchanged = try normalizeAnnexBClassRanges(fixed.allocator(), unchanged_source);
    try std.testing.expect(!unchanged.owned);
    try std.testing.expectEqual(@intFromPtr(unchanged_source.ptr), @intFromPtr(unchanged.bytes.ptr));

    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rewritten = try normalizeAnnexBClassRanges(measured.allocator(), "[\\d-a][a-\\s][\\--z]");
    defer rewritten.deinit(measured.allocator());
    try std.testing.expect(rewritten.owned);
    try std.testing.expectEqualStrings("[\\d\\x2da][a\\x2d\\s][\\x2d-z]", rewritten.bytes);
    try std.testing.expectEqual(@as(usize, 1), measured.allocations);
    try std.testing.expectEqual(rewritten.bytes.len, measured.allocated_bytes);

    var no_rewrite_memory: [0]u8 = .{};
    var no_rewrite = std.heap.FixedBufferAllocator.init(&no_rewrite_memory);
    try std.testing.expectError(error.OutOfMemory, normalizeAnnexBClassRanges(no_rewrite.allocator(), "[\\d-a]"));
}
