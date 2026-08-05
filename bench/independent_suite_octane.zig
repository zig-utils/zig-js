//! Shared frozen Octane adapter boundary for the isolated engine runners (#504).

const std = @import("std");

pub const protocol_marker = "__zig_js_independent_suite_v1__";
pub const base_path = "base.js";
pub const base_sha256 = "216612c2e7096a02b3e52b57e9cf9351bbaf180d60938d5c60b85fd756232733";

pub const RowSpec = struct {
    id: []const u8,
    path: []const u8,
    sha256: []const u8,
    licenses: []const []const u8,
    result_names: []const []const u8,
};

pub const rows = [_]RowSpec{
    .{ .id = "richards", .path = "richards.js", .sha256 = "1246a64a24b931158bf01c24640343259fa74b0226e73bad630bd1f686aa0fa7", .licenses = &.{"BSD-3-Clause"}, .result_names = &.{"Richards"} },
    .{ .id = "regexp", .path = "regexp.js", .sha256 = "a292d6047900c5296ea9e2628453832cc3bfe397e49fddade8aff7b5876c8263", .licenses = &.{"BSD-3-Clause"}, .result_names = &.{"RegExp"} },
    .{ .id = "splay", .path = "splay.js", .sha256 = "f9a6a60d8f205908f5542ad1180abc1902dcdab3dcb4278017c5ce179ee123f7", .licenses = &.{"BSD-3-Clause"}, .result_names = &.{ "Splay", "SplayLatency" } },
    .{ .id = "navier_stokes", .path = "navier-stokes.js", .sha256 = "27926de809451c60b0c49a4185c08f97081310d0db166a30c1d202fb656556a2", .licenses = &.{"MIT"}, .result_names = &.{"NavierStokes"} },
    .{ .id = "box2d", .path = "box2d.js", .sha256 = "83b10c280f004e7b156a9e04d09ce4109892ea92788f7c6c963f7fadf29c7bd4", .licenses = &.{"Zlib"}, .result_names = &.{"Box2D"} },
};

pub fn rowById(id: []const u8) ?*const RowSpec {
    for (&rows) |*row| if (std.mem.eql(u8, row.id, id)) return row;
    return null;
}

test "frozen Octane rows remain unique and complete" {
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    for (rows, 0..) |row, index| {
        try std.testing.expect(row.id.len != 0 and row.path.len != 0 and row.sha256.len == 64);
        try std.testing.expect(row.licenses.len != 0 and row.result_names.len != 0);
        for (rows[0..index]) |prior| try std.testing.expect(!std.mem.eql(u8, row.id, prior.id));
    }
}
