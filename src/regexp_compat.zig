const std = @import("std");

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
