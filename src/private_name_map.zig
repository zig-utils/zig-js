const std = @import("std");

const SecureStringHashContext = struct {
    seed: u64,

    pub fn hash(context: @This(), value: []const u8) u64 {
        return std.hash.Wyhash.hash(context.seed, value);
    }

    pub fn eql(_: @This(), left: []const u8, right: []const u8) bool {
        return std.mem.eql(u8, left, right);
    }
};

/// Immutable runtime PrivateEnvironment mapping. Each evaluated class owns its
/// context: the map survives parsing and is carried by closures, suspended VM
/// activations, exception handlers, and direct eval.
pub const PrivateNameMap = struct {
    const Self = @This();
    pub const Kind = enum { field, method_or_accessor };
    pub const Binding = struct {
        storage_key: []const u8,
        kind: Kind,
    };
    const Index = std.HashMapUnmanaged(
        []const u8,
        Binding,
        SecureStringHashContext,
        std.hash_map.default_max_load_percentage,
    );

    index: Index = .empty,
    context: SecureStringHashContext,

    pub fn init(seed: u64) Self {
        return .{ .context = .{ .seed = seed } };
    }

    /// A nested-class shadowing filter contains the same lexical names and is
    /// invocation-local, so reuse the installed context instead of consuming
    /// entropy for a transient clone.
    pub fn emptyClone(self: *const Self) Self {
        return .{ .context = self.context };
    }

    pub fn put(self: *Self, allocator: std.mem.Allocator, key: []const u8, binding: Binding) std.mem.Allocator.Error!void {
        try self.index.putContext(allocator, key, binding, self.context);
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        return if (self.index.getContext(key, self.context)) |binding| binding.storage_key else null;
    }

    /// Resolve diagnostics from the evaluation-unique storage key retained in
    /// rewritten AST/bytecode back to the private element's declaration kind.
    pub fn kindForStorageKey(self: *const Self, storage_key: []const u8) ?Kind {
        var entries = self.index.iterator();
        while (entries.next()) |entry|
            if (std.mem.eql(u8, entry.value_ptr.storage_key, storage_key))
                return entry.value_ptr.kind;
        return null;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.index.containsContext(key, self.context);
    }

    pub fn remove(self: *Self, key: []const u8) bool {
        return self.index.removeContext(key, self.context);
    }

    pub fn count(self: *const Self) usize {
        return self.index.count();
    }

    pub fn iterator(self: *const Self) Index.Iterator {
        return self.index.iterator();
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.index.deinit(allocator);
    }
};

test "runtime private name maps key placement and preserve clone context" {
    const target_mask: u64 = 1023;
    const collision_count = 32;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var suffix: usize = 0;
    while (names.items.len != collision_count) : (suffix += 1) {
        const name = try std.fmt.allocPrint(allocator, "#collision{d}", .{suffix});
        if ((std.hash.Wyhash.hash(0, name) & target_mask) == 0)
            try names.append(allocator, name);
    }

    const keyed_seed = 0x5052_4956_4154_4502;
    var keyed = PrivateNameMap.init(keyed_seed);
    var occupied: [target_mask + 1]bool = @splat(false);
    var occupied_count: usize = 0;
    for (names.items, 0..) |name, index| {
        try std.testing.expectEqual(@as(u64, 0), std.hash.Wyhash.hash(0, name) & target_mask);
        const bucket = std.hash.Wyhash.hash(keyed_seed, name) & target_mask;
        if (!occupied[bucket]) {
            occupied[bucket] = true;
            occupied_count += 1;
        }
        try keyed.put(allocator, name, .{
            .storage_key = try std.fmt.allocPrint(allocator, "private\x00{d}", .{index}),
            .kind = if (index % 2 == 0) .field else .method_or_accessor,
        });
    }
    try std.testing.expect(occupied_count > collision_count / 2);
    for (names.items) |name| try std.testing.expect(keyed.contains(name));

    var shadow = keyed.emptyClone();
    try std.testing.expectEqual(keyed.context.seed, shadow.context.seed);
    var entries = keyed.iterator();
    while (entries.next()) |entry| try shadow.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    try std.testing.expect(shadow.remove(names.items[0]));
    try std.testing.expect(!shadow.contains(names.items[0]));
    try std.testing.expect(keyed.contains(names.items[0]));

    var unavailable: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var failed = PrivateNameMap.init(keyed_seed);
    try std.testing.expectError(error.OutOfMemory, failed.put(unavailable.allocator(), "#first", .{ .storage_key = "private\x001", .kind = .field }));
    try std.testing.expectEqual(@as(usize, 0), failed.count());
    try std.testing.expectEqual(@as(usize, 0), failed.index.capacity());
}
