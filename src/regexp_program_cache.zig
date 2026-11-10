const std = @import("std");
const regex = @import("regex");
const Regex = regex.Regex;

/// Bounded interpreter-local ownership for compiled programs and mutable
/// matcher scratch. A lease pins its entry across reentrant JavaScript calls;
/// when all entries are pinned, the new program stays transient rather than
/// weakening the bound or invalidating an outer operation.
///
/// Programs are shared by source and flags. A regexp literal is a fresh
/// RegExp object every time it is evaluated, so keying by object would
/// recompile a hot literal on every call. Sharing is safe for backtracking
/// programs too: their search state is reset at the start of every match,
/// and the pin keeps a reentrant use off a program an outer one is using.
pub const Cache = struct {
    /// Real code cycles through more distinct patterns than a small table
    /// holds: a utility-class compiler runs ~80 literals per class list, and
    /// round-robin eviction of a cyclic working set larger than the table
    /// misses on every lookup. A compiled program is a few KB.
    pub const capacity = 256;

    // Retired results must not make every cache entry retain its largest
    // search. Keep small hot-match storage, while releasing one-off peaks.
    // Live results and persistent matcher scratch have separate lifetimes.
    const max_retained_result_bytes: usize = 64 * 1024;

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
        // A result may outlive its lease or another search on that lease.
        // Reclaim its storage and permit eviction only after the last retires.
        live_results: usize = 0,
        released_transient: bool = false,

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
        }

        fn setRuntimeAllocator(self: *OwnedProgram, allocator: std.mem.Allocator) void {
            const compiled = self.regex.?;
            compiled.allocator = allocator;
            if (compiled.backtrack_engine) |*engine| engine.allocator = allocator;
        }

        fn beginMatch(self: *OwnedProgram) std.mem.Allocator {
            const allocator = self.result_arena.allocator();
            self.setRuntimeAllocator(allocator);
            return allocator;
        }

        fn finishMatchAttempt(self: *OwnedProgram, matched: bool) void {
            if (matched) {
                self.live_results += 1;
            } else if (self.live_results == 0) self.resetResults();
        }

        fn retireResult(self: *OwnedProgram) void {
            std.debug.assert(self.live_results > 0);
            self.live_results -= 1;
            if (self.live_results != 0) return;
            if (self.released_transient) self.deinit() else self.resetResults();
        }

        fn resetResults(self: *OwnedProgram) void {
            _ = self.result_arena.reset(.{ .retain_with_limit = max_retained_result_bytes });
        }

        fn reset(self: *OwnedProgram) void {
            std.debug.assert(self.regex != null);
            std.debug.assert(self.live_results == 0);
            _ = self.compile_arena.reset(.retain_capacity);
            _ = self.matcher_arena.reset(.retain_capacity);
            self.resetResults();
            self.regex = null;
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
        /// `keyHash(source, flags)`, compared before the bytes on every lookup.
        hash: u64,
        source: []const u8,
        flags: []const u8,
        owned: *OwnedProgram,
        // Matcher state is substantially larger than the key/program metadata.
        // Its arena-owned header is created on first use and never moved while
        // leases or live captures retain this entry.
        matcher: ?*Regex.Matcher = null,
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

            pub fn deinit(self: *OwnedMatch) void {
                self.value.deinit(self.allocator);
                self.owner.retireResult();
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

        fn matcher(self: *Lease) !*Regex.Matcher {
            return switch (self.owner) {
                .cached => |cached| blk: {
                    const entry = &cached.cache.entries[cached.index];
                    if (entry.matcher == null) {
                        const allocator = entry.owned.matcher_arena.allocator();
                        const scratch = try allocator.create(Regex.Matcher);
                        scratch.* = entry.owned.regex.?.matcherWithScratchAllocator(allocator);
                        entry.matcher = scratch;
                    }
                    break :blk entry.matcher.?;
                },
                .transient => |*transient| blk: {
                    if (transient.matcher == null) transient.matcher = transient.owned.regex.?.matcherWithScratchAllocator(transient.owned.matcher_arena.allocator());
                    break :blk &transient.matcher.?;
                },
                .released => unreachable,
            };
        }

        pub fn find(self: *Lease, input: []const u8) !?OwnedMatch {
            const owned_program = self.owned();
            const allocator = owned_program.beginMatch();
            errdefer owned_program.finishMatchAttempt(false);
            const found = try (try self.matcher()).find(input);
            owned_program.finishMatchAttempt(found != null);
            return if (found) |match| .{
                .value = match,
                .allocator = allocator,
                .owner = owned_program,
            } else null;
        }

        pub fn findFrom(self: *Lease, input: []const u8, start: usize) !?OwnedMatch {
            const owned_program = self.owned();
            const allocator = owned_program.beginMatch();
            errdefer owned_program.finishMatchAttempt(false);
            const found = try (try self.matcher()).findFrom(input, start);
            owned_program.finishMatchAttempt(found != null);
            return if (found) |match| .{
                .value = match,
                .allocator = allocator,
                .owner = owned_program,
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
                    transient.owned.released_transient = true;
                    if (transient.owned.live_results == 0) transient.owned.deinit();
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
        if (entry.matcher) |matcher| matcher.deinit();
        entry.owned.deinit();
    }

    fn keyHash(source: []const u8, flags: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(flags);
        hasher.update(&.{0});
        hasher.update(source);
        return hasher.final();
    }

    fn matches(entry: *const Entry, hash: u64, source: []const u8, flags: []const u8) bool {
        return entry.hash == hash and std.mem.eql(u8, entry.flags, flags) and std.mem.eql(u8, entry.source, source);
    }

    fn inUse(entry: *const Entry) bool {
        return entry.pins != 0 or entry.owned.live_results != 0;
    }

    pub fn acquire(self: *Cache, source: []const u8, flags: []const u8) ?Lease {
        const hash = keyHash(source, flags);
        for (&self.entries, self.occupied, 0..) |*entry, occupied, index| {
            if (!occupied) continue;
            if (!matches(entry, hash, source, flags)) continue;
            // A callback may recursively use the same RegExp while its outer
            // operation still owns matcher state. Skip pinned matches so the
            // recursive operation gets an independent cached or transient
            // program/matcher pair instead of corrupting the outer search.
            if (inUse(entry)) continue;
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
            if (inUse(entry)) continue;
            if (entry.matcher) |matcher| matcher.deinit();
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
    pub fn adopt(self: *Cache, source: []const u8, flags: []const u8, owned: *OwnedProgram) Lease {
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
                if (inUse(&self.entries[candidate])) continue;
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
            .hash = keyHash(source, flags),
            .source = source,
            .flags = flags,
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

test "RegExp program cache cold matching fits a bounded allocator" {
    var bytes: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    const allocator = fixed.allocator();
    const cache = try allocator.create(Cache);
    defer allocator.destroy(cache);
    cache.* = Cache.init(allocator);
    defer cache.deinit();
    const owned = try compileOwned(allocator, "memory");
    var lease = cache.adopt("memory", "", owned);
    defer lease.release();
    var found = (try lease.find("out of memory")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("memory", found.value.slice);
    try std.testing.expectEqual(@as(usize, 1), cache.len);
}

test "RegExp program cache compares complete immutable keys by value" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const program = try compileOwned(std.testing.allocator, "a");
    var lease = cache.adopt("a\x00b", "gi", program);
    lease.release();
    var hit = cache.acquire("a\x00b", "gi").?;
    defer hit.release();
    try std.testing.expect(cache.acquire("a\x00b", "gi") == null);
    try std.testing.expect(cache.acquire("a", "gi") == null);
    try std.testing.expect(cache.acquire("a\x00c", "gi") == null);
    try std.testing.expect(cache.acquire("a\x00b", "g") == null);
}

test "RegExp program cache retries matcher setup after allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const program = try compileOwned(allocator, "memory");
    var lease = cache.adopt("memory", "", program);
    defer lease.release();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, lease.find("out of memory"));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), cache.matcherCount());
    try std.testing.expectEqual(@as(usize, 0), program.live_results);
    failing.fail_index = std.math.maxInt(usize);
    var found = (try lease.find("out of memory")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("memory", found.value.slice);
    try std.testing.expectEqual(@as(usize, 1), cache.matcherCount());
}

test "RegExp program cache reclaims an unpinned eviction" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var keys: [Cache.capacity + 1][4]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        std.mem.writeInt(u32, key, @intCast(i), .little);
        const program = try compileOwned(std.testing.allocator, "a");
        var lease = cache.adopt(key, "", program);
        lease.release();
    }
    try std.testing.expectEqual(Cache.capacity, cache.len);
    try std.testing.expect(cache.acquire(&keys[0], "") == null);
    var newest = cache.acquire(&keys[Cache.capacity], "").?;
    newest.release();
}

test "RegExp program cache shares a backtracking program by value, never while it is pinned" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const program = try compileOwned(std.testing.allocator, "(a+)b\\1");
    try std.testing.expectEqual(.backtracking, program.regex.?.engine_type);
    var lease = cache.adopt("(a+)b\\1", "", program);
    const shared = lease.program();
    {
        var found = (try lease.find("xaabaa")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("aa", found.value.captures[0]);
    }
    // An outer match still holds it: a reentrant use must compile its own.
    try std.testing.expect(cache.acquire("(a+)b\\1", "") == null);
    lease.release();

    // Released, a later RegExp with the same source gets the same program, and
    // the earlier search's captures do not leak into the new one.
    var later = cache.acquire("(a+)b\\1", "").?;
    defer later.release();
    try std.testing.expectEqual(shared, later.program());
    var found = (try later.find("abab")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("aba", found.value.slice);
    try std.testing.expectEqualStrings("a", found.value.captures[0]);
    try std.testing.expect((try later.find("aab")) == null);
}

test "RegExp program cache recycles an unpinned arena without moving pinned leases" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var keys: [Cache.capacity][4]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        std.mem.writeInt(u32, key, @intCast(i), .little);
        var lease = cache.adopt(key, "", try compileOwned(std.testing.allocator, "a"));
        lease.release();
    }
    var pinned = cache.acquire(&keys[0], "").?;
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
    var lease = cache.adopt("(a+?)(b)", "", try compileOwned(std.testing.allocator, "(a+?)(b)"));
    defer lease.release();
    for (0..128) |_| {
        var found = (try lease.find("aaab")).?;
        defer found.deinit();
        try std.testing.expectEqualStrings("aaab", found.value.slice);
        try std.testing.expectEqualStrings("aaa", found.value.captures[0]);
        try std.testing.expectEqualStrings("b", found.value.captures[1]);
    }
}

test "RegExp program cache keeps lazy DFA scratch across result resets" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var lease = cache.adopt("(ab+)", "", try compileOwned(std.testing.allocator, "(ab+)"));
    defer lease.release();

    // A shared global RegExp can first be observed with nonzero lastIndex in
    // one interpreter, priming only VM scratch. A later zero start lazily
    // creates the DFA; resetting that match result must not free the DFA.
    var from_middle = (try lease.findFrom("xxabbb", 2)).?;
    from_middle.deinit();
    var first = (try lease.findFrom("xxabbb", 0)).?;
    first.deinit();
    var reused = (try lease.findFrom("xxabbb", 0)).?;
    defer reused.deinit();
    try std.testing.expectEqualStrings("abbb", reused.value.slice);
    try std.testing.expectEqualStrings("abbb", reused.value.captures[0]);
}

test "RegExp program cache uses a transient lease when every slot is pinned" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var leases: [Cache.capacity]Cache.Lease = undefined;
    var keys: [Cache.capacity + 1][4]u8 = undefined;
    for (&leases, 0..) |*lease, i| {
        std.mem.writeInt(u32, &keys[i], @intCast(i), .little);
        const program = try compileOwned(std.testing.allocator, "a");
        lease.* = cache.adopt(&keys[i], "", program);
    }
    std.mem.writeInt(u32, &keys[Cache.capacity], Cache.capacity, .little);
    const extra = try compileOwned(std.testing.allocator, "b");
    var transient = cache.adopt(&keys[Cache.capacity], "", extra);
    switch (transient.owner) {
        .transient => {},
        else => return error.TestUnexpectedResult,
    }
    var live = (try transient.find("b")).?;
    transient.release();
    try std.testing.expectEqualStrings("b", live.value.slice);
    live.deinit();
    for (&leases) |*lease| lease.release();
}

test "RegExp program cache keeps released leases with live results out of eviction" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();
    var lease = cache.adopt("(a+?)!", "", try compileOwned(allocator, "(a+?)!"));
    var live = (try lease.find("aaa!")).?;
    lease.release();
    try std.testing.expect(cache.acquire("(a+?)!", "") == null);
    var keys: [Cache.capacity][4]u8 = undefined;
    for (&keys, 0..) |*key, i| {
        std.mem.writeInt(u32, key, @intCast(i), .little);
        var other = cache.adopt(key, "", try compileOwned(allocator, "b"));
        other.release();
    }
    const recycled = try cache.ownerForMiss();
    recycled.deinit();
    try std.testing.expectEqualStrings("aaa", live.value.captures[0]);
    live.deinit();
    var reused = cache.acquire("(a+?)!", "").?;
    defer reused.release();
    var found = (try reused.find("a!")).?;
    defer found.deinit();
    try std.testing.expectEqualStrings("a", found.value.captures[0]);
}

test "RegExp program cache releases oversized result scratch after a live capture retires" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();
    // A greedy capture with a backreference keeps real alternatives live.
    // Lazy scans now recycle dead states instead of forcing an oversized arena.
    const pattern = "a(.+)!(?:\\1)?";
    const owned = try compileOwned(allocator, pattern);
    var lease = cache.adopt(pattern, "", owned);
    defer lease.release();
    const input = try allocator.alloc(u8, 8192);
    defer allocator.free(input);
    @memset(input, 'x');
    input[0] = 'a';
    input[input.len - 1] = '!';
    var found = (try lease.find(input)).?;
    try std.testing.expectEqualStrings(input[1 .. input.len - 1], found.value.captures[0]);
    try std.testing.expect(owned.result_arena.queryCapacity() > 64 * 1024);
    found.deinit();
    try std.testing.expect(owned.result_arena.queryCapacity() <= 64 * 1024);
    var again = (try lease.find("aok!")).?;
    defer again.deinit();
    try std.testing.expectEqualStrings("ok", again.value.captures[0]);
}

test "RegExp program cache releases oversized result scratch after misses and errors" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();
    const owned = try compileOwned(allocator, "a(.+?)!");
    var lease = cache.adopt("a(.+?)!", "", owned);
    defer lease.release();
    const input = try allocator.alloc(u8, 8192);
    defer allocator.free(input);
    @memset(input, 'x');
    input[0] = 'a';
    try std.testing.expect((try lease.find(input)) == null);
    try std.testing.expect(owned.result_arena.queryCapacity() <= 64 * 1024);
    lease.program().backtrack_engine.?.max_steps = 10000;
    try std.testing.expectError(error.Timeout, lease.find(input));
    try std.testing.expect(owned.result_arena.queryCapacity() <= 64 * 1024);
    lease.program().backtrack_engine.?.max_steps = 10000000;
    var recovered = (try lease.find("aok!")).?;
    defer recovered.deinit();
    try std.testing.expectEqualStrings("ok", recovered.value.captures[0]);
}
