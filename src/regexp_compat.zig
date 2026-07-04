const std = @import("std");

fn isLegacyClassEscape(c: u8) bool {
    return switch (c) {
        'd', 'D', 's', 'S', 'w', 'W' => true,
        else => false,
    };
}

/// Annex B permits non-Unicode character class "ranges" where one side is a
/// class escape, treating the `-` as a literal union member. zig-regex rejects
/// those as invalid ranges, so compile an equivalent pattern with `\x2d`.
pub fn normalizeAnnexBClassRanges(arena: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var changed = false;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\') {
            if (in_class and i + 2 < pattern.len and isLegacyClassEscape(pattern[i + 1]) and pattern[i + 2] == '-') {
                try out.appendSlice(arena, pattern[i .. i + 2]);
                try out.appendSlice(arena, "\\x2d");
                changed = true;
                i += 3;
                continue;
            }
            const end = @min(i + 2, pattern.len);
            try out.appendSlice(arena, pattern[i..end]);
            i = end;
            continue;
        }
        if (in_class and c == '-' and i + 2 < pattern.len and pattern[i + 1] == '\\' and isLegacyClassEscape(pattern[i + 2])) {
            try out.appendSlice(arena, "\\x2d");
            changed = true;
            i += 1;
            continue;
        }
        try out.append(arena, c);
        if (c == '[') in_class = true else if (c == ']') in_class = false;
        i += 1;
    }
    return if (changed) out.items else pattern;
}
