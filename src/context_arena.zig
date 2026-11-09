//! Context-lifetime storage. Bounded realms must not turn a small request into
//! an unaffordable speculative reserve; the child allocator remains the quota
//! authority. Calls are single-owner or serialized by Context's LockedArena.
const std = @import("std");

pub const GrowthBudget = struct {
    context: *anyopaque,
    remaining: *const fn (*anyopaque) usize,
};

pub const ContextArena = union(enum) {
    unbounded: std.heap.ArenaAllocator,
    bounded: BoundedArena,

    pub fn init(child: std.mem.Allocator, budget: ?GrowthBudget) ContextArena {
        return if (budget) |limit| .{ .bounded = .{ .child = child, .budget = limit } } else .{ .unbounded = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *ContextArena) void {
        switch (self.*) {
            inline else => |*arena| arena.deinit(),
        }
    }

    pub fn allocator(self: *ContextArena) std.mem.Allocator {
        return switch (self.*) {
            inline else => |*arena| arena.allocator(),
        };
    }

    /// Committed payload capacity, excluding block headers, as for std's arena.
    pub fn queryCapacity(self: *ContextArena) usize {
        return switch (self.*) {
            inline else => |*arena| arena.queryCapacity(),
        };
    }
};

const BoundedArena = struct {
    const Block = struct { next: ?*Block, size: usize, used: usize };
    child: std.mem.Allocator,
    budget: GrowthBudget,
    head: ?*Block = null,
    capacity: usize = 0,

    fn deinit(self: *BoundedArena) void {
        var block = self.head;
        while (block) |current| {
            block = current.next;
            self.child.rawFree(@as([*]u8, @ptrCast(current))[0..current.size], .of(Block), @returnAddress());
        }
        self.head = null;
        self.capacity = 0;
    }

    fn queryCapacity(self: *BoundedArena) usize {
        return self.capacity;
    }
    fn allocator(self: *BoundedArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn fit(block: *Block, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const capacity = block.size - @sizeOf(Block);
        const cursor = @intFromPtr(block) + @sizeOf(Block) + block.used;
        const mask = alignment.toByteUnits() - 1;
        const padding = (0 -% cursor) & mask;
        if (padding > capacity - block.used or len > capacity - block.used - padding) return null;
        block.used += padding + len;
        return @ptrFromInt(cursor + padding);
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BoundedArena = @ptrCast(@alignCast(raw));
        if (self.head) |head| if (fit(head, len, alignment)) |memory| return memory;
        const payload = std.math.add(usize, len, alignment.toByteUnits() - 1) catch return null;
        const minimum = std.math.add(usize, @sizeOf(Block), payload) catch return null;
        const previous = if (self.head) |head| head.size - @sizeOf(Block) else 0;
        const growth = std.math.add(usize, previous, previous / 2) catch minimum;
        var size = @max(minimum, if (self.head == null) @as(usize, 4096) else growth);
        // The hint can race with other Context allocations. It is never an
        // admission check: the child owns the hard cap and recovery collection.
        // Avoid spending the last quota bytes on unused geometric capacity.
        if (size > self.budget.remaining(self.budget.context)) size = minimum;
        var memory = self.child.rawAlloc(size, .of(Block), ret_addr);
        if (memory == null and size != minimum) {
            // Speculative reserve failed, not the client's actual request. A
            // smaller complete block remains valid even after a stale hint or
            // backing-allocator fragmentation. Genuine exhaustion still fails.
            size = minimum;
            memory = self.child.rawAlloc(size, .of(Block), ret_addr);
        }
        const allocated = memory orelse return null;
        const block: *Block = @ptrCast(@alignCast(allocated));
        block.* = .{ .next = self.head, .size = size, .used = 0 };
        self.head = block;
        self.capacity += size - @sizeOf(Block);
        // The complete minimum includes alignment padding regardless of the
        // backing address, so publication cannot be followed by a failed fit.
        return fit(block, len, alignment).?;
    }

    fn tail(self: *BoundedArena, memory: []u8) ?*Block {
        const head = self.head orelse return null;
        const start = @intFromPtr(head) + @sizeOf(Block);
        const address = @intFromPtr(memory.ptr);
        if (address < start or address > start + head.used or memory.len != start + head.used - address) return null;
        return head;
    }

    fn resize(raw: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *BoundedArena = @ptrCast(@alignCast(raw));
        if (self.tail(memory)) |head| {
            const offset = @intFromPtr(memory.ptr) - @intFromPtr(head) - @sizeOf(Block);
            if (new_len > head.size - @sizeOf(Block) - offset) return false;
            head.used = offset + new_len;
            return true;
        }
        // Shrinking an older allocation remains valid but cannot reclaim
        // storage past newer pointers, just as for the standard arena.
        return new_len <= memory.len;
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(raw, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(raw: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *BoundedArena = @ptrCast(@alignCast(raw));
        if (self.tail(memory)) |head| head.used -= memory.len;
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};

// A real backing allocator with a byte quota and no in-place growth. This
// exercises the arena's public Allocator contract independently of GC policy.
const TestBacking = struct {
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    hint: ?usize = null,
    fail_next: bool = false,

    fn remaining(raw: *anyopaque) usize {
        const self: *TestBacking = @ptrCast(@alignCast(raw));
        return self.hint orelse (self.limit - self.used);
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TestBacking = @ptrCast(@alignCast(raw));
        if (self.fail_next) {
            self.fail_next = false;
            return null;
        }
        if (len > self.limit - self.used) return null;
        const ptr = std.testing.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.used += len;
        self.peak = @max(self.peak, self.used);
        return ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TestBacking = @ptrCast(@alignCast(raw));
        self.used -= memory.len;
        std.testing.allocator.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn allocator(self: *TestBacking) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn budget(self: *TestBacking) GrowthBudget {
        return .{ .context = self, .remaining = remaining };
    }
};

test "Context arena: small requests use remaining quota without geometric amplification" {
    var backing: TestBacking = .{ .limit = 14000 };
    var arena = ContextArena.init(backing.allocator(), backing.budget());
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try allocator.alloc(u8, 6000);
    @memset(first, 0x57);
    const second = try allocator.alloc(u8, 6000);
    @memset(second, 0xa3);
    const small = try allocator.alloc(u8, 512);
    @memset(small, 0x6b);
    try std.testing.expectEqual(@as(u8, 0x57), first[0]);
    try std.testing.expectEqual(@as(u8, 0x57), first[first.len - 1]);
    try std.testing.expectEqual(@as(u8, 0xa3), second[second.len - 1]);
    try std.testing.expect(backing.peak <= backing.limit);
    try std.testing.expect(arena.queryCapacity() >= first.len + second.len + small.len);
}

test "Context arena: stale optimistic and pessimistic budget hints never grant quota" {
    for ([_]usize{ 0, std.math.maxInt(usize) }) |hint| {
        var backing: TestBacking = .{ .limit = 14000, .hint = hint };
        {
            var arena = ContextArena.init(backing.allocator(), backing.budget());
            defer arena.deinit();
            const allocator = arena.allocator();
            const first = try allocator.alloc(u8, 6000);
            @memset(first, 0x73);
            const second = try allocator.alloc(u8, 6000);
            @memset(second, 0x59);
            try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 3000));
            try std.testing.expectEqual(@as(u8, 0x73), first[first.len - 1]);
            try std.testing.expectEqual(@as(u8, 0x59), second[second.len - 1]);
            try std.testing.expect(backing.peak <= backing.limit);
        }
        try std.testing.expectEqual(@as(usize, 0), backing.used);
    }
}

test "Context arena: over-aligned allocations retain their full contents across block growth" {
    var backing: TestBacking = .{ .limit = 128 * 1024 };
    {
        var arena = ContextArena.init(backing.allocator(), backing.budget());
        defer arena.deinit();
        const allocator = arena.allocator();
        var addresses: [5][*]u8 = undefined;
        for ([_]std.mem.Alignment{ .@"1", .@"8", .@"64", .fromByteUnits(4096), .fromByteUnits(8192) }, 0..) |alignment, index| {
            const memory = allocator.rawAlloc(257, alignment, @returnAddress()) orelse return error.OutOfMemory;
            addresses[index] = memory;
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(memory) % alignment.toByteUnits());
            @memset(memory[0..257], @intCast(index + 1));
        }
        _ = try allocator.alloc(u8, 32 * 1024);
        for (addresses, 0..) |memory, index| for (memory[0..257]) |byte| {
            try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte);
        };
        try std.testing.expect(arena.queryCapacity() >= 5 * 257 + 32 * 1024);
        try std.testing.expect(backing.used > arena.queryCapacity());
    }
    try std.testing.expectEqual(@as(usize, 0), backing.used);
}

test "Context arena: resize remap and free never move existing pointers" {
    var backing: TestBacking = .{ .limit = 64 * 1024 };
    var arena = ContextArena.init(backing.allocator(), backing.budget());
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try allocator.alloc(u8, 128);
    @memset(first, 0x36);
    const original = first.ptr;
    try std.testing.expect(allocator.resize(first, 256));
    var grown: []u8 = original[0..256];
    const remapped = allocator.remap(grown, 320) orelse return error.OutOfMemory;
    try std.testing.expectEqual(original, remapped.ptr);
    grown = remapped;
    const newer = try allocator.alloc(u8, 16);
    try std.testing.expect(!allocator.resize(grown, 321));
    try std.testing.expect(allocator.remap(grown, 321) == null);
    try std.testing.expect(allocator.resize(grown, 64));
    for (first[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0x36), byte);
    allocator.free(newer);
    const reused = try allocator.alloc(u8, 16);
    try std.testing.expectEqual(newer.ptr, reused.ptr);
    allocator.free(reused);
    const capacity = arena.queryCapacity();
    const latest = try allocator.alloc(u8, 128);
    try std.testing.expect(allocator.resize(latest, 80));
    const tail = try allocator.alloc(u8, 24);
    try std.testing.expectEqual(@intFromPtr(latest.ptr) + 80, @intFromPtr(tail.ptr));
    try std.testing.expectEqual(capacity, arena.queryCapacity());
}

test "Context arena: backing failures and oversized requests publish no block" {
    var backing: TestBacking = .{ .limit = 10000 };
    {
        var arena = ContextArena.init(backing.allocator(), backing.budget());
        defer arena.deinit();
        const allocator = arena.allocator();
        const first = try allocator.alloc(u8, 4000);
        @memset(first, 0xc1);
        const capacity = arena.queryCapacity();
        const used = backing.used;
        try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 9000));
        try std.testing.expect(allocator.rawAlloc(std.math.maxInt(usize), .@"8", @returnAddress()) == null);
        try std.testing.expectEqual(used, backing.used);
        try std.testing.expectEqual(capacity, arena.queryCapacity());
        for (first) |byte| try std.testing.expectEqual(@as(u8, 0xc1), byte);
    }
    try std.testing.expectEqual(@as(usize, 0), backing.used);
    var exhausted: TestBacking = .{ .limit = 16 };
    var empty = ContextArena.init(exhausted.allocator(), exhausted.budget());
    defer empty.deinit();
    try std.testing.expectError(error.OutOfMemory, empty.allocator().alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 0), empty.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), exhausted.used);
}

test "Context arena: failed speculative reserve retries a complete minimum block" {
    var backing: TestBacking = .{ .limit = 4096, .fail_next = true };
    {
        var arena = ContextArena.init(backing.allocator(), backing.budget());
        defer arena.deinit();
        const memory = try arena.allocator().alloc(u8, 128);
        @memset(memory, 0x96);
        try std.testing.expectEqual(@as(usize, 128), memory.len);
        try std.testing.expect(arena.queryCapacity() >= memory.len);
        try std.testing.expect(backing.used < 4096);
    }
    try std.testing.expectEqual(@as(usize, 0), backing.used);
}

test "Context arena: unbounded allocations retain storage across growth" {
    var arena = ContextArena.init(std.testing.allocator, null);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retained: [3][]u8 = undefined;
    var requested: usize = 0;
    for ([_]usize{ 64, 8000, 32000 }, 0..) |size, index| {
        const memory = try allocator.alloc(u8, size);
        retained[index] = memory;
        @memset(memory, @intCast(index + 1));
        requested += memory.len;
        try std.testing.expect(arena.queryCapacity() >= requested);
    }
    for (retained, 0..) |memory, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), memory[0]);
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), memory[memory.len - 1]);
    }
}
