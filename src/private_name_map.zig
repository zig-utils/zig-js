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

/// Immutable runtime PrivateEnvironment. Each evaluated class owns only its
/// PrivateBoundIdentifiers and points to the enclosing environment, matching
/// the specification's lexical chain without flattening inherited bindings.
/// The chain survives parsing and is carried by closures, suspended VM
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
    parent: ?*const Self = null,

    pub fn init(seed: u64) Self {
        return .{ .context = .{ .seed = seed } };
    }

    pub fn initChild(seed: u64, parent: ?*const Self) Self {
        return .{ .context = .{ .seed = seed }, .parent = parent };
    }

    pub fn put(self: *Self, allocator: std.mem.Allocator, key: []const u8, binding: Binding) std.mem.Allocator.Error!void {
        try self.index.putContext(allocator, key, binding, self.context);
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        var environment: ?*const Self = self;
        while (environment) |current| : (environment = current.parent)
            if (current.index.getContext(key, current.context)) |binding| return binding.storage_key;
        return null;
    }

    /// Resolve diagnostics from the evaluation-unique storage key retained in
    /// rewritten AST/bytecode back to the private element's declaration kind.
    pub fn kindForStorageKey(self: *const Self, storage_key: []const u8) ?Kind {
        var environment: ?*const Self = self;
        while (environment) |current| : (environment = current.parent) {
            var entries = current.index.iterator();
            while (entries.next()) |entry|
                if (std.mem.eql(u8, entry.value_ptr.storage_key, storage_key))
                    return entry.value_ptr.kind;
        }
        return null;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn containsOwn(self: *const Self, key: []const u8) bool {
        return self.index.containsContext(key, self.context);
    }

    pub fn ownCount(self: *const Self) usize {
        return self.index.count();
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.index.deinit(allocator);
    }
};

test "runtime private name maps preserve secure placement and lexical parents" {
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

    var child = PrivateNameMap.initChild(keyed_seed + 1, &keyed);
    try child.put(allocator, names.items[0], .{ .storage_key = "shadow\x001", .kind = .method_or_accessor });
    try std.testing.expectEqualStrings("shadow\x001", child.get(names.items[0]).?);
    try std.testing.expectEqualStrings(keyed.get(names.items[1]).?, child.get(names.items[1]).?);
    try std.testing.expectEqual(PrivateNameMap.Kind.method_or_accessor, child.kindForStorageKey("shadow\x001").?);
    try std.testing.expectEqual(PrivateNameMap.Kind.field, child.kindForStorageKey(keyed.get(names.items[0]).?).?);
    try std.testing.expectEqual(@as(usize, 1), child.ownCount());
    try std.testing.expect(keyed.contains(names.items[0]));

    var unavailable: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var failed = PrivateNameMap.init(keyed_seed);
    try std.testing.expectError(error.OutOfMemory, failed.put(unavailable.allocator(), "#first", .{ .storage_key = "private\x001", .kind = .field }));
    try std.testing.expectEqual(@as(usize, 0), failed.ownCount());
    try std.testing.expectEqual(@as(usize, 0), failed.index.capacity());
}
