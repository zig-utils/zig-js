const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;

/// Bounded interpreter-local ownership for compiled programs and mutable
/// matcher scratch. A lease pins its entry across reentrant JavaScript calls;
/// when all entries are pinned, the new program stays transient rather than
/// weakening the bound or invalidating an outer operation.
pub const Cache = struct {
    pub const capacity = 64;

    /// Compilation performs many small allocations whose lifetimes are exactly
    /// the program lifetime. Keep those in a per-program arena so eviction is
    /// one batch release. Separate retained-capacity arenas keep matcher scratch
    /// stable while allowing each later match result to be reclaimed in bulk.
    pub const OwnedProgram = struct {
        compile_arena: std.heap.ArenaAllocator,
        matcher_arena: std.heap.ArenaAllocator,
        result_arena: std.heap.ArenaAllocator,
        backing_allocator: std.mem.Allocator,
        regex: ?*Regex = null,
        matcher_primed: bool = false,

        pub fn create(backing: std.mem.Allocator) !*OwnedProgram {
            const owned = try backing.create(OwnedProgram);
            owned.* = .{
                .compile_arena = .init(backing),
                .matcher_arena = .init(backing),
                .result_arena = .init(backing),
                .backing_allocator = backing,
            };
            return owned;
        }

        pub fn compileAllocator(self: *OwnedProgram) std.mem.Allocator {
            return self.compile_arena.allocator();
        }

        pub fn publish(self: *OwnedProgram, compiled: *Regex) void {
            std.debug.assert(self.regex == null);
            self.regex = compiled;
            // The immutable graph remains in compile_arena. Prime persistent
            // matcher scratch separately from the resettable result arena.
            self.setRuntimeAllocator(self.matcher_arena.allocator());
        }

        fn setRuntimeAllocator(self: *OwnedProgram, allocator: std.mem.Allocator) void {
            const compiled = self.regex.?;
            compiled.allocator = allocator;
            if (compiled.backtrack_engine) |*engine| engine.allocator = allocator;
        }

        fn beginMatch(self: *OwnedProgram) struct { allocator: std.mem.Allocator, reset_result: bool } {
            if (!self.matcher_primed) {
                self.setRuntimeAllocator(self.matcher_arena.allocator());
                return .{ .allocator = self.matcher_arena.allocator(), .reset_result = false };
            }
            self.setRuntimeAllocator(self.result_arena.allocator());
            return .{ .allocator = self.result_arena.allocator(), .reset_result = true };
        }

        fn finishMatchAttempt(self: *OwnedProgram, reset_result: bool, matched: bool) void {
            self.matcher_primed = true;
            if (reset_result and !matched) _ = self.result_arena.reset(.retain_capacity);
        }

        fn reset(self: *OwnedProgram) void {
            std.debug.assert(self.regex != null);
            _ = self.compile_arena.reset(.retain_capacity);
            _ = self.matcher_arena.reset(.retain_capacity);
            _ = self.result_arena.reset(.retain_capacity);
            self.regex = null;
            self.matcher_primed = false;
        }

        pub fn deinit(self: *OwnedProgram) void {
            const backing = self.backing_allocator;
            // Do not call Regex.deinit: its immutable fields were allocated by
            // compile_arena, while its runtime allocator points at one of the
            // other arenas. Releasing all three owns the complete graph.
            self.result_arena.deinit();
            self.matcher_arena.deinit();
            self.compile_arena.deinit();
            backing.destroy(self);
        }
    };

    const Entry = struct {
        source: []const u8,
        flags: []const u8,
        identity: u64,
        owned: *OwnedProgram,
        matcher: ?Regex.Matcher = null,
        pins: usize = 0,
    };

    allocator: std.mem.Allocator,
    entries: [capacity]Entry = undefined,
    occupied: [capacity]bool = @splat(false),
    len: usize = 0,
    next: usize = 0,

    pub const Lease = struct {
        const Cached = struct { cache: *Cache, index: usize };
        const Transient = struct {
            owned: *OwnedProgram,
            matcher: ?Regex.Matcher = null,
        };

        owner: union(enum) {
            cached: Cached,
            transient: Transient,
            released,
        },

        pub const OwnedMatch = struct {
            value: regex.Match,
            allocator: std.mem.Allocator,
            owner: *OwnedProgram,
            reset_result: bool,

            pub fn deinit(self: *OwnedMatch) void {
                self.value.deinit(self.allocator);
                if (self.reset_result) _ = self.owner.result_arena.reset(.retain_capacity);
            }
        };

        fn owned(self: *Lease) *OwnedProgram {
            return switch (self.owner) {
                .cached => |cached| cached.cache.entries[cached.index].owned,
                .transient => |*transient| transient.owned,
                .released => unreachable,
            };
        }

        pub fn program(self: *Lease) *Regex {
            return switch (self.owner) {
                .cached => |cached| cached.cache.entries[cached.index].owned.regex.?,
                .transient => |*transient| transient.owned.regex.?,
                .released => unreachable,
            };
        }

        fn matcher(self: *Lease) *Regex.Matcher {
            return switch (self.owner) {
                .cached => |cached| blk: {
                    const entry = &cached.cache.entries[cached.index];
                    if (entry.matcher == null) entry.matcher = entry.owned.regex.?.matcher();
                    break :blk &entry.matcher.?;
                },
                .transient => |*transient| blk: {
                    if (transient.matcher == null) transient.matcher = transient.owned.regex.?.matcher();
                    break :blk &transient.matcher.?;
                },
                .released => unreachable,
            };
        }

        pub fn find(self: *Lease, input: []const u8) !?OwnedMatch {
            const owned_program = self.owned();
            const attempt = owned_program.beginMatch();
            const found = self.matcher().find(input) catch |err| {
                owned_program.finishMatchAttempt(attempt.reset_result, false);
                return err;
            };
            owned_program.finishMatchAttempt(attempt.reset_result, found != null);
            return if (found) |match| .{
                .value = match,
                .allocator = attempt.allocator,
                .owner = owned_program,
                .reset_result = attempt.reset_result,
            } else null;
        }

        pub fn findFrom(self: *Lease, input: []const u8, start: usize) !?OwnedMatch {
            const owned_program = self.owned();
            const attempt = owned_program.beginMatch();
            const found = self.matcher().findFrom(input, start) catch |err| {
                owned_program.finishMatchAttempt(attempt.reset_result, false);
                return err;
            };
            owned_program.finishMatchAttempt(attempt.reset_result, found != null);
            return if (found) |match| .{
                .value = match,
                .allocator = attempt.allocator,
                .owner = owned_program,
                .reset_result = attempt.reset_result,
            } else null;
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
                    transient.owned.deinit();
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
        for (&self.entries, self.occupied) |*entry, occupied| {
            if (!occupied) continue;
            std.debug.assert(entry.pins == 0);
            destroyEntry(entry);
        }
        self.* = .init(allocator);
    }

    fn destroyEntry(entry: *Entry) void {
        if (entry.matcher) |*matcher| matcher.deinit();
        entry.owned.deinit();
    }

    fn matches(entry: *const Entry, source: []const u8, flags: []const u8, identity: u64) bool {
        if (!std.mem.eql(u8, entry.flags, flags) or !std.mem.eql(u8, entry.source, source)) return false;
        // Thompson programs are immutable and reusable by value. Backtracking
        // programs embed mutable search state and stay isolated per RegExp.
        return entry.owned.regex.?.engine_type == .thompson_nfa or entry.identity == identity;
    }

    pub fn acquire(self: *Cache, source: []const u8, flags: []const u8, identity: u64) ?Lease {
        for (&self.entries, self.occupied, 0..) |*entry, occupied, index| {
            if (!occupied) continue;
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

    /// Return resettable compile storage for a miss. Stable occupied slots keep
    /// outstanding lease indices valid; an unpinned full-cache victim becomes
    /// a hole and is filled by `adopt` after compilation succeeds.
    pub fn ownerForMiss(self: *Cache) !*OwnedProgram {
        if (self.len < capacity) return OwnedProgram.create(self.allocator);
        for (0..capacity) |offset| {
            const candidate = (self.next + offset) % capacity;
            if (!self.occupied[candidate]) continue;
            const entry = &self.entries[candidate];
            if (entry.pins != 0) continue;
            if (entry.matcher) |*matcher| matcher.deinit();
            const owned = entry.owned;
            owned.reset();
            self.occupied[candidate] = false;
            self.len -= 1;
            self.next = candidate;
            return owned;
        }
        return OwnedProgram.create(self.allocator);
    }

    /// Adopt one successfully compiled program. Ownership always transfers:
    /// either an unpinned slot owns it, or the returned transient lease does.
    pub fn adopt(self: *Cache, source: []const u8, flags: []const u8, identity: u64, owned: *OwnedProgram) Lease {
        var index: ?usize = null;
        if (self.len < capacity) {
            for (0..capacity) |offset| {
                const candidate = (self.next + offset) % capacity;
                if (self.occupied[candidate]) continue;
                index = candidate;
                break;
            }
        } else {
            for (0..capacity) |offset| {
                const candidate = (self.next + offset) % capacity;
                if (self.entries[candidate].pins != 0) continue;
                destroyEntry(&self.entries[candidate]);
                self.occupied[candidate] = false;
                self.len -= 1;
                index = candidate;
                break;
            }
        }
        const target = index orelse return .{ .owner = .{ .transient = .{
            .owned = owned,
        } } };
        self.entries[target] = .{
            .source = source,
            .flags = flags,
            .identity = identity,
            .owned = owned,
            .pins = 1,
        };
        self.occupied[target] = true;
        self.len += 1;
        self.next = (target + 1) % capacity;
        return .{ .owner = .{ .cached = .{ .cache = self, .index = target } } };
    }

    pub fn matcherCount(self: *const Cache) usize {
        var count: usize = 0;
        for (self.entries, self.occupied) |entry, occupied| if (occupied and entry.matcher != null) {
            count += 1;
        };
        return count;
    }

    pub fn hasVmMatcher(self: *const Cache) bool {
        for (self.entries, self.occupied) |entry, occupied| {
            if (!occupied) continue;
            if (entry.matcher) |matcher| if (matcher.vm_cell != null) return true;
        }
        return false;
    }
};

fn compileOwned(backing: std.mem.Allocator, pattern: []const u8) !*Cache.OwnedProgram {
    const owned = try Cache.OwnedProgram.create(backing);
    errdefer owned.deinit();
    const compile_allocator = owned.compileAllocator();
    const program = try compile_allocator.create(Regex);
    program.* = try Regex.compileWithFlags(compile_allocator, pattern, .{ .ecmascript = true });
    owned.publish(program);
    return owned;
}

test "RegExp program cache compares complete immutable keys by value" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const program = try compileOwned(std.testing.allocator, "a");
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
        const program = try compileOwned(std.testing.allocator, "a");
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
    const program = try compileOwned(std.testing.allocator, "(a)\\1");
    try std.testing.expectEqual(.backtracking, program.regex.?.engine_type);
    var lease = cache.adopt("(a)\\1", "", 41, program);
    lease.release();

    try std.testing.expect(cache.acquire("(a)\\1", "", 42) == null);
    var same_object = cache.acquire("(a)\\1", "", 41).?;
    same_object.release();
}

test "RegExp program cache recycles an unpinned arena without moving pinned leases" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var keys: [Cache.capacity][4]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        std.mem.writeInt(u32, key, @intCast(i), .little);
        var lease = cache.adopt(key, "", @intCast(i), try compileOwned(std.testing.allocator, "a"));
        lease.release();
    }
    var pinned = cache.acquire(&keys[0], "", 0).?;
    const pinned_program = pinned.program();
    const recycled = try cache.ownerForMiss();
    try std.testing.expect(recycled.regex == null);
    try std.testing.expectEqual(pinned_program, pinned.program());
    try std.testing.expectEqual(Cache.capacity - 1, cache.len);
    recycled.deinit();
    pinned.release();
}

test "RegExp program cache reuses matcher and result arenas across hot matches" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var lease = cache.adopt("(a+?)(b)", "", 1, try compileOwned(std.testing.allocator, "(a+?)(b)"));
    defer lease.release();
    for (0..128) |_| {
        var found = (try lease.find("aaab")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("aaab", found.value.slice);
        try std.testing.expectEqualStrings("aaa", found.value.captures[0]);
        try std.testing.expectEqualStrings("b", found.value.captures[1]);
    }
}

test "RegExp program cache uses a transient lease when every slot is pinned" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var leases: [Cache.capacity]Cache.Lease = undefined;
    var keys: [Cache.capacity + 1][4]u8 = undefined;
    for (&leases, 0..) |*lease, i| {
        std.mem.writeInt(u32, &keys[i], @intCast(i), .little);
        const program = try compileOwned(std.testing.allocator, "a");
        lease.* = cache.adopt(&keys[i], "", @intCast(i), program);
    }
    std.mem.writeInt(u32, &keys[Cache.capacity], Cache.capacity, .little);
    const extra = try compileOwned(std.testing.allocator, "b");
    var transient = cache.adopt(&keys[Cache.capacity], "", Cache.capacity, extra);
    switch (transient.owner) {
        .transient => {},
        else => return error.TestUnexpectedResult,
    }
    transient.release();
    for (&leases) |*lease| lease.release();
}
