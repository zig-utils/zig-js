const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;

/// Bounded interpreter-local ownership for compiled programs and mutable
/// matcher scratch. A lease pins its entry across reentrant JavaScript calls;
/// when all entries are pinned, the new program stays transient rather than
/// weakening the bound or invalidating an outer operation.
pub const Cache = struct {
    pub const capacity = 64;

    const Entry = struct {
        source: []const u8,
        flags: []const u8,
        identity: u64,
        program: *Regex,
        matcher: ?Regex.Matcher = null,
        pins: usize = 0,
    };

    allocator: std.mem.Allocator,
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    pub const Lease = struct {
        const Cached = struct { cache: *Cache, index: usize };
        const Transient = struct {
            allocator: std.mem.Allocator,
            program: *Regex,
            matcher: ?Regex.Matcher = null,
        };

        owner: union(enum) {
            cached: Cached,
            transient: Transient,
            released,
        },

        pub fn program(self: *Lease) *Regex {
            return switch (self.owner) {
                .cached => |cached| cached.cache.entries[cached.index].program,
                .transient => |*transient| transient.program,
                .released => unreachable,
            };
        }

        pub fn allocator(self: *Lease) std.mem.Allocator {
            return self.program().allocator;
        }

        pub fn matcher(self: *Lease) *Regex.Matcher {
            return switch (self.owner) {
                .cached => |cached| blk: {
                    const entry = &cached.cache.entries[cached.index];
                    if (entry.matcher == null) entry.matcher = entry.program.matcher();
                    break :blk &entry.matcher.?;
                },
                .transient => |*transient| blk: {
                    if (transient.matcher == null) transient.matcher = transient.program.matcher();
                    break :blk &transient.matcher.?;
                },
                .released => unreachable,
            };
        }

        pub fn release(self: *Lease) void {
            switch (self.owner) {
                .cached => |cached| {
                    const entry = &cached.cache.entries[cached.index];
                    std.debug.assert(entry.pins > 0);
                    entry.pins -= 1;
                },
                .transient => |*transient| {
                    if (transient.matcher) |*scratch| scratch.deinit();
                    transient.program.deinit();
                    transient.allocator.destroy(transient.program);
                },
                .released => return,
            }
            self.owner = .released;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        const allocator = self.allocator;
        for (self.entries[0..self.len]) |*entry| {
            std.debug.assert(entry.pins == 0);
            self.destroyEntry(entry);
        }
        self.* = .init(allocator);
    }

    fn destroyEntry(self: *Cache, entry: *Entry) void {
        if (entry.matcher) |*matcher| matcher.deinit();
        entry.program.deinit();
        self.allocator.destroy(entry.program);
    }

    fn matches(entry: *const Entry, source: []const u8, flags: []const u8, identity: u64) bool {
        if (!std.mem.eql(u8, entry.flags, flags) or !std.mem.eql(u8, entry.source, source)) return false;
        // Thompson programs are immutable and reusable by value. Backtracking
        // programs embed mutable search state and stay isolated per RegExp.
        return entry.program.engine_type == .thompson_nfa or entry.identity == identity;
    }

    pub fn acquire(self: *Cache, source: []const u8, flags: []const u8, identity: u64) ?Lease {
        for (self.entries[0..self.len], 0..) |*entry, index| {
            if (!matches(entry, source, flags, identity)) continue;
            // A callback may recursively use the same RegExp while its outer
            // operation still owns matcher state. Skip pinned matches so the
            // recursive operation gets an independent cached or transient
            // program/matcher pair instead of corrupting the outer search.
            if (entry.pins != 0) continue;
            entry.pins = 1;
            return .{ .owner = .{ .cached = .{ .cache = self, .index = index } } };
        }
        return null;
    }

    /// Adopt one successfully compiled program. Ownership always transfers:
    /// either an unpinned slot owns it, or the returned transient lease does.
    pub fn adopt(self: *Cache, source: []const u8, flags: []const u8, identity: u64, program: *Regex) Lease {
        var index: ?usize = null;
        if (self.len < capacity) {
            index = self.len;
            self.len += 1;
        } else {
            for (0..capacity) |offset| {
                const candidate = (self.next + offset) % capacity;
                if (self.entries[candidate].pins != 0) continue;
                self.destroyEntry(&self.entries[candidate]);
                index = candidate;
                break;
            }
        }
        const target = index orelse return .{ .owner = .{ .transient = .{
            .allocator = self.allocator,
            .program = program,
        } } };
        self.entries[target] = .{
            .source = source,
            .flags = flags,
            .identity = identity,
            .program = program,
            .pins = 1,
        };
        self.next = (target + 1) % capacity;
        return .{ .owner = .{ .cached = .{ .cache = self, .index = target } } };
    }

    pub fn matcherCount(self: *const Cache) usize {
        var count: usize = 0;
        for (self.entries[0..self.len]) |entry| if (entry.matcher != null) {
            count += 1;
        };
        return count;
    }

    pub fn hasVmMatcher(self: *const Cache) bool {
        for (self.entries[0..self.len]) |entry| {
            if (entry.matcher) |matcher| if (matcher.vm_cell != null) return true;
        }
        return false;
    }
};

test "RegExp program cache compares complete immutable keys by value" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const program = try std.testing.allocator.create(Regex);
    program.* = try Regex.compileWithFlags(std.testing.allocator, "a", .{ .ecmascript = true });
    var lease = cache.adopt("a\x00b", "gi", 1, program);
    lease.release();
    var hit = cache.acquire("a\x00b", "gi", 2).?;
    defer hit.release();
    try std.testing.expect(cache.acquire("a\x00b", "gi", 2) == null);
    try std.testing.expect(cache.acquire("a", "gi", 2) == null);
    try std.testing.expect(cache.acquire("a\x00c", "gi", 2) == null);
    try std.testing.expect(cache.acquire("a\x00b", "g", 2) == null);
}

test "RegExp program cache reclaims an unpinned eviction" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var keys: [Cache.capacity + 1][4]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        std.mem.writeInt(u32, key, @intCast(i), .little);
        const program = try std.testing.allocator.create(Regex);
        program.* = try Regex.compileWithFlags(std.testing.allocator, "a", .{ .ecmascript = true });
        var lease = cache.adopt(key, "", @intCast(i), program);
        lease.release();
    }
    try std.testing.expectEqual(Cache.capacity, cache.len);
    try std.testing.expect(cache.acquire(&keys[0], "", 0) == null);
    var newest = cache.acquire(&keys[Cache.capacity], "", Cache.capacity).?;
    newest.release();
}

test "RegExp program cache isolates mutable backtracking programs by identity" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const program = try std.testing.allocator.create(Regex);
    program.* = try Regex.compileWithFlags(std.testing.allocator, "(a)\\1", .{ .ecmascript = true });
    try std.testing.expectEqual(.backtracking, program.engine_type);
    var lease = cache.adopt("(a)\\1", "", 41, program);
    lease.release();

    try std.testing.expect(cache.acquire("(a)\\1", "", 42) == null);
    var same_object = cache.acquire("(a)\\1", "", 41).?;
    same_object.release();
}

test "RegExp program cache uses a transient lease when every slot is pinned" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var leases: [Cache.capacity]Cache.Lease = undefined;
    var keys: [Cache.capacity + 1][4]u8 = undefined;
    for (&leases, 0..) |*lease, i| {
        std.mem.writeInt(u32, &keys[i], @intCast(i), .little);
        const program = try std.testing.allocator.create(Regex);
        program.* = try Regex.compileWithFlags(std.testing.allocator, "a", .{ .ecmascript = true });
        lease.* = cache.adopt(&keys[i], "", @intCast(i), program);
    }
    std.mem.writeInt(u32, &keys[Cache.capacity], Cache.capacity, .little);
    const extra = try std.testing.allocator.create(Regex);
    extra.* = try Regex.compileWithFlags(std.testing.allocator, "b", .{ .ecmascript = true });
    var transient = cache.adopt(&keys[Cache.capacity], "", Cache.capacity, extra);
    switch (transient.owner) {
        .transient => {},
        else => return error.TestUnexpectedResult,
    }
    transient.release();
    for (&leases) |*lease| lease.release();
}
