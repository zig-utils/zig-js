const std = @import("std");

/// A reference-counted, heap-allocated UTF-8 string backing the JavaScriptCore
/// `JSStringRef` C-API type. Unlike interpreter values (which live in the
/// Context arena), JSStrings have an explicit retain/release lifecycle because
/// the C API hands ownership across the boundary.
pub const JsString = struct {
    bytes: []u8,
    refcount: usize,
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, utf8: []const u8) !*JsString {
        const self = try gpa.create(JsString);
        errdefer gpa.destroy(self);
        const buf = try gpa.dupe(u8, utf8);
        self.* = .{ .bytes = buf, .refcount = 1, .gpa = gpa };
        return self;
    }

    pub fn retain(self: *JsString) void {
        self.refcount += 1;
    }

    pub fn release(self: *JsString) void {
        std.debug.assert(self.refcount > 0);
        self.refcount -= 1;
        if (self.refcount == 0) {
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
