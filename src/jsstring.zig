const std = @import("std");

/// A reference-counted, heap-allocated UTF-8 string backing the JavaScriptCore
/// `JSStringRef` C-API type. Unlike interpreter values (which live in the
/// Context arena), JSStrings have an explicit retain/release lifecycle because
/// the C API hands ownership across the boundary.
pub const JsString = struct {
    bytes: []u8,
    refcount: std.atomic.Value(usize),
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, utf8: []const u8) !*JsString {
        if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
        const self = try gpa.create(JsString);
        errdefer gpa.destroy(self);
        const buf = try gpa.dupe(u8, utf8);
        self.* = .{ .bytes = buf, .refcount = .init(1), .gpa = gpa };
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
            self.gpa.destroy(self);
        }
    }

    /// JSC's JSStringGetLength returns the number of UTF-16 code units. For
    /// ASCII this equals the byte length; astral code points count as 2.
    pub fn utf16Len(self: *const JsString) usize {
        var count: usize = 0;
        const view = std.unicode.Utf8View.initUnchecked(self.bytes);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            count += if (cp > 0xFFFF) 2 else 1;
        }
        return count;
    }
};

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

test "JSString retain refuses refcount overflow" {
    const s = try JsString.create(std.testing.allocator, "overflow");
    defer s.release();
    s.refcount.store(std.math.maxInt(usize), .release);
    try std.testing.expect(s.tryRetain() == null);
    try std.testing.expectEqual(std.math.maxInt(usize), s.refcount.load(.acquire));
    s.refcount.store(1, .release);
}
