const std = @import("std");
const Regex = @import("regex").Regex;

/// Interpreter-local lookup of immutable, context-arena-owned programs. Keys
/// borrow the RegExp's arena-owned source/flag bytes, not GC-managed objects.
/// Eviction drops only a lookup entry: live RegExp objects and matcher scratch
/// can still refer to that program. Neither programs nor keys are freed here.
///
/// Keep the lookup bounded independently of dynamically constructed patterns.
/// A miss always compiles normally; the cache changes no acceptance semantics.
/// The dependency's backtracking program embeds mutable captures/search state,
/// so only Thompson programs (including immutable one-pass plans) are reusable.
pub const Cache = struct {
    pub const capacity = 64;
    const Entry = struct { source: []const u8, flags: []const u8, program: *Regex };

    entries: [capacity]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    pub fn get(self: *const Cache, source: []const u8, flags: []const u8) ?*Regex {
        for (self.entries[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.flags, flags) and std.mem.eql(u8, entry.source, source))
                return entry.program;
        }
        return null;
    }

    /// Called only after a miss and successful compilation. No fallible work
    /// remains when publishing a program, and invalid patterns are never cached.
    pub fn insert(self: *Cache, source: []const u8, flags: []const u8, program: *Regex) void {
        if (program.engine_type != .thompson_nfa) return;
        self.entries[self.next] = .{ .source = source, .flags = flags, .program = program };
        self.len = @min(self.len + 1, capacity);
        self.next = (self.next + 1) % capacity;
    }
};

test "RegExp program cache compares complete source and flags by value" {
    var cache: Cache = .{};
    var program: Regex = undefined; // Only engine_type is inspected.
    program.engine_type = .thompson_nfa;
    var source = [_]u8{ 'a', 0, 'b' };
    cache.insert(&source, "gi", &program);
    try std.testing.expectEqual(&program, cache.get("a\x00b", "gi").?);
    try std.testing.expect(cache.get("a", "gi") == null);
    try std.testing.expect(cache.get("a\x00c", "gi") == null);
    try std.testing.expect(cache.get("a\x00b", "g") == null);
    try std.testing.expect(cache.get("a\x00b", "gu") == null);
}

test "RegExp program cache eviction does not destroy a borrowed program" {
    var cache: Cache = .{};
    var program = try Regex.compileWithFlags(std.testing.allocator, "a", .{ .ecmascript = true });
    defer program.deinit();
    cache.insert("a", "", &program);
    var keys: [Cache.capacity][1]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        key.* = .{@intCast(i)};
        cache.insert(key, "", &program);
    }
    try std.testing.expectEqual(Cache.capacity, cache.len);
    try std.testing.expect(cache.get("a", "") == null);
    try std.testing.expectEqual(&program, cache.get(&keys[0], "").?);
    try std.testing.expect(try program.isMatch("a"));
}

test "RegExp program caches are independent between interpreters" {
    var first: Cache = .{};
    var second: Cache = .{};
    var a: Regex = undefined;
    var b: Regex = undefined;
    a.engine_type = .thompson_nfa;
    b.engine_type = .thompson_nfa;
    first.insert("a", "g", &a);
    try std.testing.expect(second.get("a", "g") == null);
    second.insert("a", "g", &b);
    try std.testing.expectEqual(&a, first.get("a", "g").?);
    try std.testing.expectEqual(&b, second.get("a", "g").?);
}

test "RegExp program cache does not alias mutable backtracking state" {
    var cache: Cache = .{};
    var program = try Regex.compileWithFlags(std.testing.allocator, "(a)\\1", .{ .ecmascript = true });
    defer program.deinit();
    try std.testing.expectEqual(.backtracking, program.engine_type);
    cache.insert("(a)\\1", "", &program);
    try std.testing.expect(cache.get("(a)\\1", "") == null);
    try std.testing.expectEqual(@as(usize, 0), cache.len);
}
