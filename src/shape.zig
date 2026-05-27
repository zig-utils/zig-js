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
//! transitions out from there.

const std = @import("std");

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
        if (self.transitions.get(name)) |child| return child;
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
