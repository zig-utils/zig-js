const std = @import("std");

/// A reference-counted, heap-allocated UTF-8 string backing the JavaScriptCore
/// `JSStringRef` C-API type. Unlike interpreter values (which live in the
/// Context arena), JSStrings have an explicit retain/release lifecycle because
/// the C API hands ownership across the boundary.
pub const JsString = struct {
    bytes: []u8,
    /// Stable UTF-16 storage for JSStringGetCharactersPtr. It is allocated
    /// eagerly so the borrowed pointer remains valid for the retained lifetime
    /// of this immutable string and is safe to read from any thread.
    utf16: []u16,
    refcount: std.atomic.Value(usize),
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, utf8: []const u8) !*JsString {
        if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
        const self = try gpa.create(JsString);
        errdefer gpa.destroy(self);
        const buf = try gpa.dupe(u8, utf8);
        errdefer gpa.free(buf);
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, utf8);
        self.* = .{ .bytes = buf, .utf16 = utf16, .refcount = .init(1), .gpa = gpa };
        return self;
    }

    /// Create from raw UTF-16 code units. JavaScript strings may contain lone
    /// surrogates, so retain the original units exactly; the UTF-8 view uses
    /// U+FFFD for those units when a C caller requests UTF-8 conversion.
    pub fn createUtf16(gpa: std.mem.Allocator, units: []const u16) !*JsString {
        const self = try gpa.create(JsString);
        errdefer gpa.destroy(self);
        const utf16 = try gpa.dupe(u16, units);
        errdefer gpa.free(utf16);
        const bytes = try utf16ToUtf8ReplacingUnpaired(gpa, units);
        self.* = .{ .bytes = bytes, .utf16 = utf16, .refcount = .init(1), .gpa = gpa };
        return self;
    }

    pub fn retain(self: *JsString) *JsString {
        return self.tryRetain() orelse @panic("JSString refcount overflow");
    }

    pub fn tryRetain(self: *JsString) ?*JsString {
        var current = self.refcount.load(.monotonic);
        while (true) {
            if (current == std.math.maxInt(usize)) return null;
            if (self.refcount.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                current = observed;
                continue;
            }
            return self;
        }
    }

    pub fn release(self: *JsString) void {
        const prev = self.refcount.fetchSub(1, .release);
        std.debug.assert(prev > 0);
        if (prev == 1) {
            _ = self.refcount.load(.acquire);
            self.gpa.free(self.bytes);
            self.gpa.free(self.utf16);
            self.gpa.destroy(self);
        }
    }

    /// JSC's JSStringGetLength returns the number of UTF-16 code units. For
    /// ASCII this equals the byte length; astral code points count as 2.
    pub fn utf16Len(self: *const JsString) usize {
        return self.utf16.len;
    }
};

fn utf16ToUtf8ReplacingUnpaired(gpa: std.mem.Allocator, units: []const u16) ![]u8 {
    const max_len = try std.math.mul(usize, units.len, 3);
    const scratch = try gpa.alloc(u8, max_len);
    defer gpa.free(scratch);

    var input: usize = 0;
    var output: usize = 0;
    while (input < units.len) {
        const first = units[input];
        var codepoint: u21 = first;
        if (first >= 0xD800 and first <= 0xDBFF) {
            if (input + 1 < units.len and units[input + 1] >= 0xDC00 and units[input + 1] <= 0xDFFF) {
                const high: u32 = first - 0xD800;
                const low: u32 = units[input + 1] - 0xDC00;
                codepoint = @intCast(0x10000 + (high << 10) + low);
                input += 1;
            } else {
                codepoint = 0xFFFD;
            }
        } else if (first >= 0xDC00 and first <= 0xDFFF) {
            codepoint = 0xFFFD;
        }

        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
        @memcpy(scratch[output .. output + encoded_len], encoded[0..encoded_len]);
        output += encoded_len;
        input += 1;
    }
    return gpa.dupe(u8, scratch[0..output]);
}

test "JSString retain/release is atomic across threads" {
    const s = try JsString.create(std.testing.allocator, "thread-safe string");
    defer s.release();

    const iterations = 10_000;
    const Worker = struct {
        fn run(str: *JsString) void {
            for (0..iterations) |_| {
                const held = str.retain();
                if (held.bytes.len == 0) @panic("lost JSString bytes");
                held.release();
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{s});
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 1), s.refcount.load(.acquire));
    try std.testing.expectEqual(@as(usize, 18), s.utf16Len());
}

test "JSString rejects invalid UTF-8 before unchecked length walks" {
    try std.testing.expectError(error.InvalidUtf8, JsString.create(std.testing.allocator, "bad\xc0utf8"));
}

test "JSString preserves raw UTF-16 including lone surrogates" {
    const units = [_]u16{ 'A', 0xD83D, 0xDE00, 0xD800, 'Z' };
    const s = try JsString.createUtf16(std.testing.allocator, &units);
    defer s.release();
    try std.testing.expectEqualSlices(u16, &units, s.utf16);
    try std.testing.expectEqualStrings("A😀�Z", s.bytes);
}

test "JSString retain refuses refcount overflow" {
    const s = try JsString.create(std.testing.allocator, "overflow");
    defer s.release();
    s.refcount.store(std.math.maxInt(usize), .release);
    try std.testing.expect(s.tryRetain() == null);
    try std.testing.expectEqual(std.math.maxInt(usize), s.refcount.load(.acquire));
    s.refcount.store(1, .release);
}
