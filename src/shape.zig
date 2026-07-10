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

pub const Shape = struct {
    /// The shape this one extends (null for the root/empty shape).
    parent: ?*Shape,
    /// The single property name this shape adds over `parent` (null at root).
    name: ?[]const u8,
    /// Slot index of `name` (meaningful only when `name != null`).
    slot: u32,
    /// Total number of properties described by this shape.
    count: u32,
    /// Edges to child shapes that add one more property, keyed by that name.
    /// Shared and cached so identical construction sequences converge.
    transitions: std.StringHashMapUnmanaged(*Shape) = .{},
    transition_lock: std.atomic.Mutex = .unlocked,
    arena: std.mem.Allocator,

    /// Create the empty root shape for a Context.
    pub fn createRoot(arena: std.mem.Allocator) std.mem.Allocator.Error!*Shape {
        const root = try arena.create(Shape);
        root.* = .{ .parent = null, .name = null, .slot = 0, .count = 0, .arena = arena };
        return root;
    }

    /// Find the slot for `name` in this shape, or null if absent. Walks the
    /// parent chain (O(property count)); small objects — the common case — are
    /// a few hops, and inline caches at access sites skip this on a hit.
    pub fn lookup(self: *Shape, name: []const u8) ?u32 {
        var s: ?*Shape = self;
        while (s) |sh| {
            if (sh.name) |n| {
                if (std.mem.eql(u8, n, name)) return sh.slot;
            }
            s = sh.parent;
        }
        return null;
    }

    /// The shape that results from adding `name` to this one. Cached: the same
    /// `name` added to the same shape always returns the same child, so objects
    /// share structure.
    pub fn transition(self: *Shape, name: []const u8) std.mem.Allocator.Error!*Shape {
        bumpShapeStat("transition_requests");
        self.lockTransitions();
        defer self.transition_lock.unlock();

        if (self.transitions.get(name)) |child| {
            bumpShapeStat("transition_hits");
            return child;
        }
        bumpShapeStat("transition_misses");
        const owned = try self.arena.dupe(u8, name);
        const child = try self.arena.create(Shape);
        child.* = .{
            .parent = self,
            .name = owned,
            .slot = self.count,
            .count = self.count + 1,
            .arena = self.arena,
        };
        try self.transitions.put(self.arena, owned, child);
        return child;
    }

    fn lockTransitions(self: *Shape) void {
        var spins: usize = 0;
        while (!self.transition_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                bumpShapeStat("transition_lock_yields");
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
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
    try std.testing.expectEqual(@as(usize, 1), root.transitions.count());
    try std.testing.expectEqual(@as(?u32, 0), children[0].lookup("shared"));
}
