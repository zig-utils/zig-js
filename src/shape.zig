//! Object shapes (a.k.a. hidden classes / maps) — tier-3 of the perf ladder.
//!
//! Instead of every object carrying its own name→value hashmap, objects that
//! are built the same way *share* a `Shape`: an immutable description of which
//! property names exist and at which flat `slots` index each lives. Adding a
//! property walks a transition edge to a child shape (created once, then cached
//! and shared), so objects with the same construction history end up pointing at
//! the same `Shape`. That sharing is what later makes inline caches monomorphic,
//! and it means object creation no longer allocates a per-object hashmap — just
//! a small `slots` array.
//!
//! Shapes live in the owning Context's arena (their property-name strings are
//! context-scoped), so a Context owns one root (empty) shape and every object
//! transitions out from there. The transition map is locked per shape: the
//! no-GIL default allows ordinary JS mutation in parallel, and the map does not
//! depend on the optional GIL fallback for convergence or hash-table integrity.

const std = @import("std");
const agent = @import("agent.zig");

pub const ShapeStats = struct {
    transition_requests: u64 = 0,
    transition_hits: u64 = 0,
    transition_misses: u64 = 0,
    transition_lock_yields: u64 = 0,
};

const ShapeCounters = struct {
    transition_requests: std.atomic.Value(u64) = .init(0),
    transition_hits: std.atomic.Value(u64) = .init(0),
    transition_misses: std.atomic.Value(u64) = .init(0),
    transition_lock_yields: std.atomic.Value(u64) = .init(0),
};

var shape_counters: ShapeCounters = .{};
var shape_stats_enabled: std.atomic.Value(bool) = .init(false);

pub fn resetShapeStats() void {
    shape_stats_enabled.store(false, .release);
    shape_counters.transition_requests.store(0, .release);
    shape_counters.transition_hits.store(0, .release);
    shape_counters.transition_misses.store(0, .release);
    shape_counters.transition_lock_yields.store(0, .release);
    shape_stats_enabled.store(true, .release);
}

pub fn disableShapeStats() void {
    shape_stats_enabled.store(false, .release);
}

pub fn shapeStats() ShapeStats {
    return .{
        .transition_requests = shape_counters.transition_requests.load(.acquire),
        .transition_hits = shape_counters.transition_hits.load(.acquire),
        .transition_misses = shape_counters.transition_misses.load(.acquire),
        .transition_lock_yields = shape_counters.transition_lock_yields.load(.acquire),
    };
}

inline fn bumpShapeStat(comptime field: []const u8) void {
    if (!shape_stats_enabled.load(.monotonic)) return;
    _ = @field(shape_counters, field).fetchAdd(1, .monotonic);
}

/// Immutable collision-free string map. Every update path-copies an AVL spine,
/// so a published root and all nodes reachable from it remain read-only forever.
/// Byte ordering gives a worst-case O(log entries) tree bound independently of
/// attacker-controlled hash collisions; comparisons themselves remain
/// proportional to the exact property-name bytes they distinguish.
fn PersistentStringTree(comptime ValueType: type) type {
    return struct {
        pub const Node = struct {
            left: ?*const Node,
            right: ?*const Node,
            key: []const u8,
            value: ValueType,
            height: u8,
        };

        fn height(node: ?*const Node) u8 {
            return if (node) |present| present.height else 0;
        }

        fn create(
            arena: std.mem.Allocator,
            left: ?*const Node,
            right: ?*const Node,
            key: []const u8,
            tree_value: ValueType,
        ) std.mem.Allocator.Error!*const Node {
            const node = try arena.create(Node);
            node.* = .{
                .left = left,
                .right = right,
                .key = key,
                .value = tree_value,
                .height = 1 + @max(height(left), height(right)),
            };
            return node;
        }

        fn assemble(
            arena: std.mem.Allocator,
            left: ?*const Node,
            right: ?*const Node,
            key: []const u8,
            tree_value: ValueType,
        ) std.mem.Allocator.Error!*const Node {
            const left_height: i16 = height(left);
            const right_height: i16 = height(right);
            const balance = left_height - right_height;
            if (balance > 1) {
                const branch = left.?;
                if (height(branch.left) >= height(branch.right)) {
                    const rotated_right = try create(arena, branch.right, right, key, tree_value);
                    return create(arena, branch.left, rotated_right, branch.key, branch.value);
                }
                const pivot = branch.right.?;
                const rotated_left = try create(arena, branch.left, pivot.left, branch.key, branch.value);
                const rotated_right = try create(arena, pivot.right, right, key, tree_value);
                return create(arena, rotated_left, rotated_right, pivot.key, pivot.value);
            }
            if (balance < -1) {
                const branch = right.?;
                if (height(branch.right) >= height(branch.left)) {
                    const rotated_left = try create(arena, left, branch.left, key, tree_value);
                    return create(arena, rotated_left, branch.right, branch.key, branch.value);
                }
                const pivot = branch.left.?;
                const rotated_left = try create(arena, left, pivot.left, key, tree_value);
                const rotated_right = try create(arena, pivot.right, branch.right, branch.key, branch.value);
                return create(arena, rotated_left, rotated_right, pivot.key, pivot.value);
            }
            return create(arena, left, right, key, tree_value);
        }

        pub fn put(
            arena: std.mem.Allocator,
            root: ?*const Node,
            key: []const u8,
            tree_value: ValueType,
        ) std.mem.Allocator.Error!*const Node {
            const current = root orelse return create(arena, null, null, key, tree_value);
            return switch (std.mem.order(u8, key, current.key)) {
                .lt => assemble(arena, try put(arena, current.left, key, tree_value), current.right, current.key, current.value),
                .gt => assemble(arena, current.left, try put(arena, current.right, key, tree_value), current.key, current.value),
                .eq => create(arena, current.left, current.right, key, tree_value),
            };
        }

        pub fn get(root: ?*const Node, key: []const u8) ?ValueType {
            var cursor = root;
            while (cursor) |current| {
                switch (std.mem.order(u8, key, current.key)) {
                    .lt => cursor = current.left,
                    .gt => cursor = current.right,
                    .eq => return current.value,
                }
            }
            return null;
        }

        pub fn getComparisonCount(root: ?*const Node, key: []const u8) usize {
            var cursor = root;
            var comparisons: usize = 0;
            while (cursor) |current| {
                comparisons += 1;
                switch (std.mem.order(u8, key, current.key)) {
                    .lt => cursor = current.left,
                    .gt => cursor = current.right,
                    .eq => return comparisons,
                }
            }
            return comparisons;
        }
    };
}

/// Append-only concurrent exact string map. One writer per owning Shape is
/// already serialized by `transition_lock`; readers traverse immutable keys and
/// release-published forward links without taking that lock. SipHash-keyed
/// levels keep the expected search bound logarithmic even when property names
/// are attacker-controlled, while one node per edge avoids the AVL path-copy
/// amplification that made independent transition publishers saturate memory.
fn ConcurrentStringSkipList(comptime ValueType: type) type {
    return struct {
        pub const max_level: usize = 24;
        const Link = std.atomic.Value(?*const Node);
        const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);

        pub const Node = struct {
            next: [max_level]Link,
            key: []const u8,
            value: ValueType,
            height: u8,
        };

        pub const Head = struct {
            next: [max_level]Link,
            height: std.atomic.Value(u8) = .init(1),
            seed: [SipHash.key_length]u8,
        };

        fn emptyLinks() [max_level]Link {
            var links: [max_level]Link = undefined;
            for (&links) |*link| link.* = .init(null);
            return links;
        }

        pub fn createHead(arena: std.mem.Allocator, seed: [SipHash.key_length]u8) std.mem.Allocator.Error!*Head {
            const head = try arena.create(Head);
            head.* = .{ .next = emptyLinks(), .seed = seed };
            return head;
        }

        fn nodeHeight(head: *const Head, key: []const u8) u8 {
            const hash = SipHash.toInt(key, &head.seed);
            return @intCast(@min(@as(usize, @ctz(hash)) + 1, max_level));
        }

        pub fn get(head: ?*const Head, key: []const u8) ?ValueType {
            const list = head orelse return null;
            var predecessor: ?*const Node = null;
            var level: usize = list.height.load(.acquire);
            while (level > 0) {
                level -= 1;
                var cursor = if (predecessor) |node|
                    node.next[level].load(.acquire)
                else
                    list.next[level].load(.acquire);
                while (cursor) |node| {
                    switch (std.mem.order(u8, node.key, key)) {
                        .lt => {
                            predecessor = node;
                            cursor = node.next[level].load(.acquire);
                        },
                        .eq => return node.value,
                        .gt => break,
                    }
                }
            }
            return null;
        }

        /// Insert while the owning Shape's writer lock is held. No fallible work
        /// occurs after the node allocation, so allocation failure publishes no
        /// partial edge.
        pub fn put(
            arena: std.mem.Allocator,
            head: *Head,
            key: []const u8,
            list_value: ValueType,
        ) std.mem.Allocator.Error!void {
            var predecessors: [max_level]*Link = undefined;
            var predecessor: ?*const Node = null;
            const current_height: usize = head.height.load(.monotonic);
            for (current_height..max_level) |index| predecessors[index] = &head.next[index];
            var level = current_height;
            while (level > 0) {
                level -= 1;
                var link: *Link = if (predecessor) |node|
                    @constCast(&node.next[level])
                else
                    &head.next[level];
                var cursor = link.load(.acquire);
                while (cursor) |node| {
                    switch (std.mem.order(u8, node.key, key)) {
                        .lt => {
                            predecessor = node;
                            link = @constCast(&node.next[level]);
                            cursor = link.load(.acquire);
                        },
                        .eq => return,
                        .gt => break,
                    }
                }
                predecessors[level] = link;
            }

            const height = nodeHeight(head, key);
            const node = try arena.create(Node);
            node.* = .{ .next = emptyLinks(), .key = key, .value = list_value, .height = height };
            for (0..height) |index|
                node.next[index].store(predecessors[index].load(.monotonic), .monotonic);
            // Level zero makes the node reachable to every reader. Higher-level
            // links are accelerators and may appear afterward without affecting
            // exactness.
            for (0..height) |index| predecessors[index].store(node, .release);
            if (height > head.height.load(.monotonic)) head.height.store(height, .release);
        }

        pub fn getComparisonCount(head: ?*const Head, key: []const u8) usize {
            const list = head orelse return 0;
            var predecessor: ?*const Node = null;
            var comparisons: usize = 0;
            var level: usize = list.height.load(.acquire);
            while (level > 0) {
                level -= 1;
                var cursor = if (predecessor) |node|
                    node.next[level].load(.acquire)
                else
                    list.next[level].load(.acquire);
                while (cursor) |node| {
                    comparisons += 1;
                    switch (std.mem.order(u8, node.key, key)) {
                        .lt => {
                            predecessor = node;
                            cursor = node.next[level].load(.acquire);
                        },
                        .eq, .gt => break,
                    }
                    if (std.mem.eql(u8, node.key, key)) return comparisons;
                }
            }
            return comparisons;
        }
    };
}

/// One secure root secret feeds independently domain-separated transition-map
/// keys for this realm. Calling the host entropy source for every Shape fanout
/// made builtin installation spend material time in the OS CSPRNG. SipHash is
/// already the keyed map primitive; using it as the derivation PRF retains an
/// undisclosed 128-bit key per map while reducing secure entropy to one request
/// for the complete realm-owned Shape tree.
const TransitionKeySource = struct {
    const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);

    root_secret: [SipHash.key_length]u8,
    next_domain: std.atomic.Value(u64) = .init(0),

    fn claimDomain(self: *TransitionKeySource) std.mem.Allocator.Error!u64 {
        var current = self.next_domain.load(.monotonic);
        while (current != std.math.maxInt(u64)) {
            if (self.next_domain.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                current = observed;
                continue;
            }
            return current;
        }
        // Reusing a domain would repeat a transition-map key. No real realm can
        // allocate 2^64 maps, but the security invariant still fails closed.
        return error.OutOfMemory;
    }

    fn derive(self: *TransitionKeySource) std.mem.Allocator.Error![SipHash.key_length]u8 {
        const domain = try self.claimDomain();
        var input: [9]u8 = undefined;
        std.mem.writeInt(u64, input[0..8], domain, .little);

        var derived: [SipHash.key_length]u8 = undefined;
        input[8] = 0;
        std.mem.writeInt(u64, derived[0..8], SipHash.toInt(&input, &self.root_secret), .little);
        input[8] = 1;
        std.mem.writeInt(u64, derived[8..16], SipHash.toInt(&input, &self.root_secret), .little);
        return derived;
    }
};

/// Shape allocation and transition-key ownership have the same arena lifetime.
/// Keeping the allocator here lets every Shape carry one owner pointer instead
/// of growing each immutable Shape with both an allocator and a key-source
/// pointer.
const ShapeOwner = struct {
    arena: std.mem.Allocator,
    transition_keys: TransitionKeySource,
};

pub const Shape = struct {
    /// The shape this one extends (null for the root/empty shape).
    parent: ?*Shape,
    /// The single property name this shape adds over `parent` (null at root).
    name: ?[]const u8,
    /// Slot index of `name` (meaningful only when `name != null`).
    slot: u32,
    /// Whether this operation removes `name` instead of publishing its slot.
    /// The first matching operation while walking toward the root wins.
    deleted: bool,
    /// Physical slot span described by this shape. Deletion transitions retain
    /// stable offsets; re-adding a deleted name reuses its prior slot.
    count: u32,
    /// Exact live named-data property count after this operation.
    live_count: u32,
    /// Number of immutable operations from the root. Unlike `count`, this also
    /// includes tombstones and re-adds, so Objects can bound historical lookup
    /// work independently of their physical slot span.
    depth: u32,
    /// Deep shapes carry a persistent exact name -> latest-operation index.
    /// Shallow shapes retain the compact parent-chain representation.
    lookup_root: ?*const LookupTree.Node = null,
    /// Transition fanout is an append-only, keyed skip list. Readers acquire
    /// published links without locking; the existing per-Shape writer lock
    /// serializes insertion and same-name convergence.
    transition_head: std.atomic.Value(?*TransitionList.Head) = .init(null),
    transition_count: std.atomic.Value(usize) = .init(0),
    transition_lock: std.atomic.Mutex = .unlocked,
    owner: *ShapeOwner,

    const lookup_index_threshold: u32 = 32;

    const TransitionLockResult = union(enum) {
        locked,
        cached: *Shape,
    };

    /// Create the empty root shape for a Context.
    pub fn createRoot(arena: std.mem.Allocator) std.mem.Allocator.Error!*Shape {
        var root_secret: [TransitionKeySource.SipHash.key_length]u8 = undefined;
        // Algorithmic-complexity protection fails closed when the host has no
        // secure entropy, matching attacker-controlled collection hashes.
        agent.engineIo().randomSecure(&root_secret) catch return error.OutOfMemory;
        return createRootWithSeed(arena, root_secret);
    }

    fn createRootWithSeed(arena: std.mem.Allocator, root_secret: [TransitionKeySource.SipHash.key_length]u8) std.mem.Allocator.Error!*Shape {
        const owner = try arena.create(ShapeOwner);
        errdefer arena.destroy(owner);
        owner.* = .{
            .arena = arena,
            .transition_keys = .{ .root_secret = root_secret },
        };
        const root = try arena.create(Shape);
        root.* = .{ .parent = null, .name = null, .slot = 0, .deleted = false, .count = 0, .live_count = 0, .depth = 0, .owner = owner };
        return root;
    }

    pub const LookupState = union(enum) {
        absent,
        deleted: u32,
        present: u32,
    };

    const LookupTree = PersistentStringTree(LookupState);
    const TransitionList = ConcurrentStringSkipList(*Shape);

    pub fn lookupState(self: *Shape, name: []const u8) LookupState {
        if (self.lookup_root) |root|
            return LookupTree.get(root, name) orelse .absent;
        var shape: ?*Shape = self;
        while (shape) |current| {
            if (current.name) |candidate| {
                if (std.mem.eql(u8, candidate, name))
                    return if (current.deleted) .{ .deleted = current.slot } else .{ .present = current.slot };
            }
            shape = current.parent;
        }
        return .absent;
    }

    /// Find the slot for `name` in this shape, or null if absent. Small shapes
    /// walk a compact parent chain; deep shapes use the immutable exact AVL.
    /// Inline caches at stable access sites skip either path on a hit.
    pub fn lookup(self: *Shape, name: []const u8) ?u32 {
        return switch (self.lookupState(name)) {
            .present => |slot| slot,
            .absent, .deleted => null,
        };
    }

    /// Resolve a small compile-time field set with one newest-to-oldest walk of
    /// a shallow immutable Shape. `classify` must return an exact field index,
    /// not a hash-only identity. Deep shapes deliberately decline this bounded
    /// path and retain their persistent-tree lookups at the caller.
    pub fn classifiedLookupStatesShallow(
        self: *Shape,
        comptime field_count: usize,
        comptime classify: anytype,
        out: *[field_count]LookupState,
    ) bool {
        comptime std.debug.assert(field_count > 0 and field_count <= 64);
        if (self.depth > lookup_index_threshold) return false;
        @memset(out, .absent);
        var resolved: u64 = 0;
        var shape: ?*Shape = self;
        while (shape) |current| : (shape = current.parent) {
            const name = current.name orelse continue;
            const index = classify(name) orelse continue;
            if (index >= field_count) return false;
            const bit = @as(u64, 1) << @intCast(index);
            if (resolved & bit != 0) continue;
            out[index] = if (current.deleted)
                .{ .deleted = current.slot }
            else
                .{ .present = current.slot };
            resolved |= bit;
        }
        return true;
    }

    /// The shape that results from adding `name` to this one. Cached: the same
    /// `name` added to the same shape always returns the same child, so objects
    /// share structure.
    pub fn transition(self: *Shape, name: []const u8) std.mem.Allocator.Error!*Shape {
        return self.transitionFromState(name, self.lookupState(name));
    }

    pub fn transitionFromState(self: *Shape, name: []const u8, state: LookupState) std.mem.Allocator.Error!*Shape {
        if (state == .present) return self;
        // An immediate delete/re-add is an exact undo: return to the immutable
        // parent shape and create no historical shape or slot capacity.
        if (state == .deleted and self.deleted and self.name != null and std.mem.eql(u8, self.name.?, name))
            return self.parent.?;
        bumpShapeStat("transition_requests");

        if (self.findTransitionCached(name)) |child| {
            bumpShapeStat("transition_hits");
            return child;
        }

        switch (self.lockTransitionsOrCached(name)) {
            .locked => {},
            .cached => |child| {
                bumpShapeStat("transition_hits");
                return child;
            },
        }
        defer self.transition_lock.unlock();

        if (self.findTransitionCached(name)) |child| {
            bumpShapeStat("transition_hits");
            return child;
        }
        bumpShapeStat("transition_misses");
        const arena = self.owner.arena;
        const owned = try arena.dupe(u8, name);
        const child = try arena.create(Shape);
        const slot = switch (state) {
            .deleted => |deleted_slot| deleted_slot,
            .absent => self.count,
            .present => unreachable,
        };
        const lookup_root = try self.nextLookupRoot(owned, slot, false);
        child.* = .{
            .parent = self,
            .name = owned,
            .slot = slot,
            .deleted = false,
            .count = if (state == .absent) self.count + 1 else self.count,
            .live_count = self.live_count + 1,
            .depth = self.depth + 1,
            .lookup_root = lookup_root,
            .owner = self.owner,
        };
        try self.publishTransition(child);
        return child;
    }

    /// Shape token for removing a present property while retaining its stable
    /// physical slot. Deleting the most recently added operation can return its
    /// parent directly; all other deletion shapes are cached like additions.
    pub fn deleteTransition(self: *Shape, name: []const u8) std.mem.Allocator.Error!?*Shape {
        const slot = switch (self.lookupState(name)) {
            .present => |present_slot| present_slot,
            .absent, .deleted => return null,
        };
        if (!self.deleted and self.name != null and std.mem.eql(u8, self.name.?, name))
            return self.parent;

        if (self.findTransitionCached(name)) |child| return child;
        switch (self.lockTransitionsOrCached(name)) {
            .locked => {},
            .cached => |child| return child,
        }
        defer self.transition_lock.unlock();
        if (self.findTransitionCached(name)) |child| return child;

        const arena = self.owner.arena;
        const owned = try arena.dupe(u8, name);
        const child = try arena.create(Shape);
        const lookup_root = try self.nextLookupRoot(owned, slot, true);
        child.* = .{
            .parent = self,
            .name = owned,
            .slot = slot,
            .deleted = true,
            .count = self.count,
            .live_count = self.live_count - 1,
            .depth = self.depth + 1,
            .lookup_root = lookup_root,
            .owner = self.owner,
        };
        try self.publishTransition(child);
        return child;
    }

    fn findTransitionCached(self: *Shape, name: []const u8) ?*Shape {
        return TransitionList.get(self.transition_head.load(.acquire), name);
    }

    fn publishTransition(self: *Shape, child: *Shape) std.mem.Allocator.Error!void {
        const arena = self.owner.arena;
        const existing = self.transition_head.load(.monotonic);
        const head = existing orelse try TransitionList.createHead(arena, try self.owner.transition_keys.derive());
        try TransitionList.put(arena, head, child.name.?, child);
        if (existing == null) self.transition_head.store(head, .release);
        _ = self.transition_count.fetchAdd(1, .release);
    }

    pub fn transitionCount(self: *const Shape) usize {
        return @constCast(&self.transition_count).load(.acquire);
    }

    fn stateForOperation(shape: *const Shape) LookupState {
        return if (shape.deleted) .{ .deleted = shape.slot } else .{ .present = shape.slot };
    }

    fn nextLookupRoot(
        self: *Shape,
        owned_name: []const u8,
        slot: u32,
        deleted: bool,
    ) std.mem.Allocator.Error!?*const LookupTree.Node {
        const child_depth = self.depth + 1;
        if (child_depth < lookup_index_threshold) return null;
        const next_state: LookupState = if (deleted) .{ .deleted = slot } else .{ .present = slot };
        if (child_depth > lookup_index_threshold)
            return try LookupTree.put(self.owner.arena, self.lookup_root.?, owned_name, next_state);

        var operations: [lookup_index_threshold - 1]*Shape = undefined;
        var count: usize = 0;
        var cursor: ?*Shape = self;
        while (cursor) |operation| : (cursor = operation.parent) {
            if (operation.name == null) break;
            operations[count] = operation;
            count += 1;
        }
        std.debug.assert(count == lookup_index_threshold - 1);

        var root: ?*const LookupTree.Node = null;
        while (count > 0) {
            count -= 1;
            const operation = operations[count];
            root = try LookupTree.put(self.owner.arena, root, operation.name.?, stateForOperation(operation));
        }
        return try LookupTree.put(self.owner.arena, root, owned_name, next_state);
    }

    pub fn lookupComparisonCountForTesting(self: *const Shape, name: []const u8) usize {
        if (self.lookup_root) |root| return LookupTree.getComparisonCount(root, name);
        var comparisons: usize = 0;
        var cursor: ?*const Shape = self;
        while (cursor) |operation| : (cursor = operation.parent) {
            if (operation.name) |candidate| {
                comparisons += 1;
                if (std.mem.eql(u8, candidate, name)) break;
            }
        }
        return comparisons;
    }

    pub fn lookupIndexHeightForTesting(self: *const Shape) u8 {
        return if (self.lookup_root) |root| root.height else 0;
    }

    pub fn transitionComparisonCountForTesting(self: *const Shape, name: []const u8) usize {
        return TransitionList.getComparisonCount(self.transition_head.load(.acquire), name);
    }

    pub fn transitionIndexHeightForTesting(self: *const Shape) u8 {
        return if (self.transition_head.load(.acquire)) |head| head.height.load(.acquire) else 0;
    }

    fn lockTransitionsOrCached(self: *Shape, name: []const u8) TransitionLockResult {
        var spins: usize = 0;
        while (!self.transition_lock.tryLock()) : (spins += 1) {
            if (self.findTransitionCached(name)) |child| return .{ .cached = child };
            if ((spins & 0xff) == 0) {
                bumpShapeStat("transition_lock_yields");
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
        return .locked;
    }
};

test "shape transitions share structure and assign sequential slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try Shape.createRoot(a);

    const sa = try root.transition("a");
    const sab = try sa.transition("b");
    try std.testing.expectEqual(@as(?u32, 0), sab.lookup("a"));
    try std.testing.expectEqual(@as(?u32, 1), sab.lookup("b"));
    try std.testing.expectEqual(@as(?u32, null), sab.lookup("c"));

    // Building {a,b} again converges on the very same shapes (monomorphism).
    const sa2 = try root.transition("a");
    const sab2 = try sa2.transition("b");
    try std.testing.expectEqual(sab, sab2);
}

test "transition map keys are deterministic and domain separated for a fixed realm seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const seed = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

    const first_root = try Shape.createRootWithSeed(arena.allocator(), seed);
    const first_zero = try first_root.owner.transition_keys.derive();
    const first_one = try first_root.owner.transition_keys.derive();
    try std.testing.expect(!std.mem.eql(u8, &first_zero, &first_one));

    const second_root = try Shape.createRootWithSeed(arena.allocator(), seed);
    try std.testing.expectEqualSlices(u8, &first_zero, &(try second_root.owner.transition_keys.derive()));
    try std.testing.expectEqualSlices(u8, &first_one, &(try second_root.owner.transition_keys.derive()));
}

test "transition map domains remain unique under concurrent allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const seed: [TransitionKeySource.SipHash.key_length]u8 = @splat(0x5a);
    const root = try Shape.createRootWithSeed(arena.allocator(), seed);

    const Worker = struct {
        fn run(source: *TransitionKeySource, out: *[TransitionKeySource.SipHash.key_length]u8) void {
            out.* = source.derive() catch @panic("transition key derivation failed");
        }
    };
    var keys: [16][TransitionKeySource.SipHash.key_length]u8 = undefined;
    var threads: [keys.len]std.Thread = undefined;
    for (&threads, &keys) |*thread, *key|
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &root.owner.transition_keys, key });
    for (threads) |thread| thread.join();

    for (keys, 0..) |key, index| {
        for (keys[index + 1 ..]) |other|
            try std.testing.expect(!std.mem.eql(u8, &key, &other));
    }
    try std.testing.expectEqual(@as(u64, keys.len), root.owner.transition_keys.next_domain.load(.monotonic));
}

test "shape deletion transitions preserve slots and undo immediate re-adds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Shape.createRoot(arena.allocator());
    const a = try root.transition("a");
    const ab = try a.transition("b");
    const abc = try ab.transition("c");

    const without_b = (try abc.deleteTransition("b")).?;
    try std.testing.expectEqual(@as(?u32, null), without_b.lookup("b"));
    try std.testing.expectEqual(@as(?u32, 0), without_b.lookup("a"));
    try std.testing.expectEqual(@as(?u32, 2), without_b.lookup("c"));
    try std.testing.expectEqual(@as(u32, 3), without_b.count);
    try std.testing.expectEqual(@as(u32, 2), without_b.live_count);
    try std.testing.expectEqual(without_b, (try abc.deleteTransition("b")).?);

    const restored = try without_b.transition("b");
    try std.testing.expectEqual(abc, restored);
    try std.testing.expectEqual(@as(?u32, 1), restored.lookup("b"));

    // The newest add can be removed by returning directly to its parent; its
    // physical tail slot no longer belongs to the resulting shape.
    const without_c = (try abc.deleteTransition("c")).?;
    try std.testing.expectEqual(ab, without_c);
    try std.testing.expectEqual(@as(u32, 2), without_c.count);
    try std.testing.expectEqual(@as(u32, 2), without_c.live_count);
}

test "classified shallow lookup preserves newest deletion state and bounds depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Shape.createRoot(arena.allocator());
    const a = try root.transition("alpha");
    const ab = try a.transition("beta");
    const abc = try ab.transition("gamma");
    const without_b = (try abc.deleteTransition("beta")).?;
    const classify = struct {
        fn field(name: []const u8) ?usize {
            if (std.mem.eql(u8, name, "alpha")) return 0;
            if (std.mem.eql(u8, name, "beta")) return 1;
            if (std.mem.eql(u8, name, "gamma")) return 2;
            return null;
        }
    }.field;

    var states: [3]Shape.LookupState = undefined;
    try std.testing.expect(without_b.classifiedLookupStatesShallow(3, classify, &states));
    try std.testing.expectEqual(@as(Shape.LookupState, .{ .present = 0 }), states[0]);
    try std.testing.expectEqual(@as(Shape.LookupState, .{ .deleted = 1 }), states[1]);
    try std.testing.expectEqual(@as(Shape.LookupState, .{ .present = 2 }), states[2]);

    const restored = try without_b.transition("beta");
    try std.testing.expect(restored.classifiedLookupStatesShallow(3, classify, &states));
    try std.testing.expectEqual(@as(Shape.LookupState, .{ .present = 1 }), states[1]);

    var deep = restored;
    var key_storage: [32]u8 = undefined;
    for (0..Shape.lookup_index_threshold) |index| {
        const key = try std.fmt.bufPrint(&key_storage, "extra-{d}", .{index});
        deep = try deep.transition(key);
    }
    try std.testing.expect(!deep.classifiedLookupStatesShallow(3, classify, &states));
}

test "shape deletion transitions converge under concurrent same-name removal" {
    const root = try Shape.createRoot(std.heap.page_allocator);
    const a = try root.transition("a");
    const ab = try a.transition("b");
    const abc = try ab.transition("c");

    const Worker = struct {
        fn run(shape: *Shape, out: **Shape) void {
            out.* = (shape.deleteTransition("b") catch @panic("shape delete transition failed")) orelse @panic("missing property");
        }
    };
    var children: [8]*Shape = undefined;
    var threads: [children.len]std.Thread = undefined;
    for (&threads, &children) |*thread, *child| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ abc, child });
    for (threads) |thread| thread.join();
    for (children[1..]) |child| try std.testing.expectEqual(children[0], child);
}

test "shape transition stats reset and snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try Shape.createRoot(a);

    disableShapeStats();
    _ = try root.transition("off");
    try std.testing.expectEqual(@as(u64, 0), shapeStats().transition_requests);

    resetShapeStats();
    const one = try root.transition("a");
    const two = try root.transition("a");
    try std.testing.expectEqual(one, two);

    const stats = shapeStats();
    try std.testing.expectEqual(@as(u64, 2), stats.transition_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.transition_hits);
    try std.testing.expectEqual(@as(u64, 1), stats.transition_misses);

    resetShapeStats();
    try std.testing.expectEqual(@as(u64, 0), shapeStats().transition_requests);
    try std.testing.expectEqual(@as(u64, 0), shapeStats().transition_hits);
    try std.testing.expectEqual(@as(u64, 0), shapeStats().transition_misses);
    try std.testing.expectEqual(@as(u64, 0), shapeStats().transition_lock_yields);
    disableShapeStats();
}

test "shape transition lock wait observes published cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try Shape.createRoot(a);

    const owned = try a.dupe(u8, "shared");
    const child = try a.create(Shape);
    child.* = .{
        .parent = root,
        .name = owned,
        .slot = 0,
        .deleted = false,
        .count = 1,
        .live_count = 1,
        .depth = 1,
        .owner = root.owner,
    };
    try root.publishTransition(child);

    try std.testing.expect(root.transition_lock.tryLock());
    defer root.transition_lock.unlock();

    switch (root.lockTransitionsOrCached("shared")) {
        .cached => |got| try std.testing.expectEqual(child, got),
        .locked => return error.ExpectedCachedTransition,
    }
}

test "shape transitions converge under concurrent same-name insertion" {
    const root = try Shape.createRoot(std.heap.page_allocator);

    const Worker = struct {
        fn run(shape: *Shape, out: **Shape) void {
            out.* = shape.transition("shared") catch @panic("shape transition failed");
        }
    };

    var children: [8]*Shape = undefined;
    var threads: [children.len]std.Thread = undefined;
    for (&threads, &children) |*t, *child| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ root, child });
    }
    for (threads) |t| t.join();

    for (children[1..]) |child| try std.testing.expectEqual(children[0], child);
    try std.testing.expectEqual(@as(usize, 1), root.transitionCount());
    try std.testing.expectEqual(@as(?u32, 0), children[0].lookup("shared"));
}

test "persistent exact string tree balances single and double rotations" {
    const Tree = PersistentStringTree(u32);
    const orders = [_][5][]const u8{
        .{ "a", "b", "c", "d", "e" },
        .{ "e", "d", "c", "b", "a" },
        .{ "c", "a", "b", "e", "d" },
        .{ "c", "e", "d", "a", "b" },
    };
    for (orders) |order| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var root: ?*const Tree.Node = null;
        for (order, 0..) |key, index| root = try Tree.put(arena.allocator(), root, key, @intCast(index));
        try std.testing.expect(root.?.height <= 3);
        for (order, 0..) |key, index| try std.testing.expectEqual(@as(?u32, @intCast(index)), Tree.get(root, key));
        try std.testing.expectEqual(@as(?u32, null), Tree.get(root, "missing"));
    }
}

test "deep shape lookup is exact and logarithmically bounded without hashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Shape.createRoot(arena.allocator());
    var shape = root;

    var key_storage: [32]u8 = undefined;
    for (0..4096) |index| {
        const key = std.fmt.bufPrint(&key_storage, "property-{d:0>4}", .{index}) catch unreachable;
        shape = try shape.transition(key);
    }

    const height = shape.lookupIndexHeightForTesting();
    try std.testing.expect(height > 0);
    try std.testing.expect(height <= 16);
    for (0..4096) |index| {
        const key = std.fmt.bufPrint(&key_storage, "property-{d:0>4}", .{index}) catch unreachable;
        try std.testing.expectEqual(@as(?u32, @intCast(index)), shape.lookup(key));
        try std.testing.expect(shape.lookupComparisonCountForTesting(key) <= height);
    }
    try std.testing.expectEqual(@as(?u32, null), shape.lookup("property-missing"));
    try std.testing.expect(shape.lookupComparisonCountForTesting("property-missing") <= height);

    const without_middle = (try shape.deleteTransition("property-2048")).?;
    try std.testing.expectEqual(@as(?u32, null), without_middle.lookup("property-2048"));
    try std.testing.expectEqual(@as(?u32, 4095), without_middle.lookup("property-4095"));
    const restored = try without_middle.transition("property-2048");
    try std.testing.expectEqual(shape, restored);
    try std.testing.expectEqual(@as(?u32, 2048), restored.lookup("property-2048"));
}

test "shape transition fanout is exact and keyed-logarithmic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try Shape.createRoot(arena.allocator());
    var children: [2048]*Shape = undefined;
    var key_storage: [32]u8 = undefined;

    for (&children, 0..) |*child, index| {
        const key = std.fmt.bufPrint(&key_storage, "fanout-{d:0>4}", .{index}) catch unreachable;
        child.* = try root.transition(key);
    }
    try std.testing.expectEqual(children.len, root.transitionCount());
    const height = root.transitionIndexHeightForTesting();
    try std.testing.expect(height > 0);
    try std.testing.expect(height <= 24);

    for (children, 0..) |expected, index| {
        const key = std.fmt.bufPrint(&key_storage, "fanout-{d:0>4}", .{index}) catch unreachable;
        try std.testing.expectEqual(expected, try root.transition(key));
        try std.testing.expect(root.transitionComparisonCountForTesting(key) <= 128);
    }
    try std.testing.expect(root.transitionComparisonCountForTesting("fanout-missing") <= 128);
}

fn exerciseDeepShapeAllocationFailures(backing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const root = try Shape.createRoot(arena.allocator());
    var shape = root;
    var key_storage: [32]u8 = undefined;

    for (0..96) |index| {
        const key = std.fmt.bufPrint(&key_storage, "oom-{d:0>3}", .{index}) catch unreachable;
        const before_transitions = shape.transitionCount();
        shape = shape.transition(key) catch |err| {
            // A failed index insertion cannot publish either the child edge or a
            // lookup result backed by the caller's borrowed key.
            try std.testing.expectEqual(before_transitions, shape.transitionCount());
            try std.testing.expectEqual(@as(?u32, null), shape.lookup(key));
            return err;
        };
    }
    for (0..96) |index| {
        const key = std.fmt.bufPrint(&key_storage, "oom-{d:0>3}", .{index}) catch unreachable;
        try std.testing.expectEqual(@as(?u32, @intCast(index)), shape.lookup(key));
    }
}

test "deep shape indexes roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeepShapeAllocationFailures,
        .{},
    );
}
