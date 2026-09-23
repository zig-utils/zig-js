//! Fail-closed reconciliation for the production OS-thread inventory (#978).

const std = @import("std");

const inventory_path = "docs/.data/runtime-thread-inventory-v1.json";
const max_source_bytes = 16 * 1024 * 1024;
const direct_spawn = "std.Thread.spawn";
const typed_spawn = "runtime_threads.spawn(";

const SourceCount = struct { path: []const u8, count: usize };
const Resource = struct {
    id: []const u8,
    purpose: []const u8,
    call_sites: []const SourceCount,
    owner: []const u8,
    multiplicity: []const u8,
    admission: []const u8,
    stack_policy: []const u8,
    blocking: []const u8,
    shutdown: []const u8,
    scratch_memory: []const u8,
    coordinator_status: []const u8,
};
const SynchronousSubsystem = struct { id: []const u8, path: []const u8, status: []const u8 };
const Inventory = struct {
    schema_version: u32,
    policy_id: []const u8,
    owner_issue: u32,
    resources: []const Resource,
    synchronous_subsystems: []const SynchronousSubsystem,
    test_only_direct_spawns: []const SourceCount,
};

fn fail(comptime fmt: []const u8, args: anytype) error{RuntimeThreadAuditFailed} {
    std.debug.print("runtime-thread audit: " ++ fmt ++ "\n", args);
    return error.RuntimeThreadAuditFailed;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
    }
    return total;
}

const DirectScopes = struct { production: usize = 0, test_only: usize = 0 };

fn classifyDirectSpawns(gpa: std.mem.Allocator, source: []const u8) !DirectScopes {
    const zsource = try gpa.dupeSentinel(u8, source, 0);
    defer gpa.free(zsource);
    var tokenizer = std.zig.Tokenizer.init(zsource);
    var depth: usize = 0;
    var test_depth: ?usize = null;
    var pending_test = false;
    var prior: [4][]const u8 = .{ "", "", "", "" };
    var result: DirectScopes = .{};
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        const text = zsource[token.loc.start..token.loc.end];
        if (std.mem.eql(u8, text, "spawn") and
            std.mem.eql(u8, prior[0], "std") and std.mem.eql(u8, prior[1], ".") and
            std.mem.eql(u8, prior[2], "Thread") and std.mem.eql(u8, prior[3], "."))
        {
            if (test_depth == null) result.production += 1 else result.test_only += 1;
        }

        if (token.tag == .keyword_test and depth == 0) pending_test = true;
        if (token.tag == .l_brace) {
            depth += 1;
            if (pending_test and depth == 1) {
                test_depth = depth;
                pending_test = false;
            }
        } else if (token.tag == .r_brace) {
            if (depth == 0) return fail("source has an unmatched closing brace", .{});
            depth -= 1;
            if (test_depth) |start| {
                if (depth < start) test_depth = null;
            }
        }
        prior = .{ prior[1], prior[2], prior[3], text };
    }
    return result;
}

fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_source_bytes));
}

fn nonEmpty(resource: Resource) bool {
    return resource.id.len > 0 and resource.purpose.len > 0 and resource.call_sites.len > 0 and
        resource.owner.len > 0 and resource.multiplicity.len > 0 and resource.admission.len > 0 and
        resource.stack_policy.len > 0 and resource.blocking.len > 0 and resource.shutdown.len > 0 and
        resource.scratch_memory.len > 0 and resource.coordinator_status.len > 0;
}

fn listedDirect(inventory: Inventory, path: []const u8) ?usize {
    for (inventory.test_only_direct_spawns, 0..) |item, index| {
        if (std.mem.eql(u8, item.path, path)) return index;
    }
    return null;
}

fn auditInventory(inventory: Inventory) !void {
    if (inventory.schema_version != 1) return fail("unsupported schema {d}", .{inventory.schema_version});
    if (!std.mem.eql(u8, inventory.policy_id, "zig-js-runtime-threads-v1"))
        return fail("unexpected policy id '{s}'", .{inventory.policy_id});
    if (inventory.owner_issue != 978) return fail("unexpected owner issue #{d}", .{inventory.owner_issue});
    if (inventory.resources.len == 0) return fail("resource inventory is empty", .{});
    for (inventory.resources, 0..) |resource, i| {
        if (!nonEmpty(resource)) return fail("resource {d} has an empty required field", .{i});
        for (inventory.resources[0..i]) |prior| {
            if (std.mem.eql(u8, prior.id, resource.id)) return fail("duplicate resource id '{s}'", .{resource.id});
        }
        for (resource.call_sites) |site| {
            if (!std.mem.startsWith(u8, site.path, "src/") or site.count == 0)
                return fail("resource '{s}' has invalid call site", .{resource.id});
        }
    }
    for (inventory.test_only_direct_spawns, 0..) |item, i| {
        if (!std.mem.startsWith(u8, item.path, "src/") or item.count == 0)
            return fail("test-only direct-spawn entry {d} is invalid", .{i});
        for (inventory.test_only_direct_spawns[0..i]) |prior| {
            if (std.mem.eql(u8, prior.path, item.path)) return fail("duplicate test-only path '{s}'", .{item.path});
        }
    }
    const required_sync = [_][]const u8{ "jit_compilation", "wasm_compilation" };
    if (inventory.synchronous_subsystems.len != required_sync.len)
        return fail("synchronous subsystem inventory has {d} entries, expected {d}", .{ inventory.synchronous_subsystems.len, required_sync.len });
    for (required_sync) |required| {
        var found = false;
        for (inventory.synchronous_subsystems) |subsystem| {
            if (subsystem.path.len == 0 or subsystem.status.len == 0) return fail("synchronous subsystem has an empty field", .{});
            if (std.mem.eql(u8, subsystem.id, required)) found = true;
        }
        if (!found) return fail("synchronous subsystem inventory omits '{s}'", .{required});
    }
}

fn auditSources(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !struct { typed: usize, test_only: usize } {
    const direct_seen = try gpa.alloc(bool, inventory.test_only_direct_spawns.len);
    defer gpa.free(direct_seen);
    @memset(direct_seen, false);
    const typed_seen = try gpa.alloc(usize, inventory.resources.len);
    defer gpa.free(typed_seen);
    @memset(typed_seen, 0);
    var typed_total: usize = 0;
    var direct_total: usize = 0;
    var wrapper_direct: usize = 0;

    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
        defer gpa.free(source);
        const path = try std.fs.path.join(gpa, &.{ "src", entry.path });
        defer gpa.free(path);

        const direct = count(source, direct_spawn);
        const scopes = try classifyDirectSpawns(gpa, source);
        if (direct != scopes.production + scopes.test_only)
            return fail("token-aware direct-spawn count drift in '{s}': {d} textual, {d} tokenized", .{ path, direct, scopes.production + scopes.test_only });
        if (std.mem.eql(u8, path, "src/runtime_threads.zig")) {
            if (scopes.production != 1 or scopes.test_only != 0)
                return fail("runtime thread boundary has invalid production/test direct-spawn split", .{});
            wrapper_direct = direct;
        } else if (direct != 0) {
            if (scopes.production != 0)
                return fail("'{s}' retains {d} direct spawns outside top-level tests", .{ path, scopes.production });
            const inventory_index = listedDirect(inventory, path) orelse
                return fail("'{s}' has {d} unclassified direct production/test spawn tokens", .{ path, direct });
            if (direct != inventory.test_only_direct_spawns[inventory_index].count)
                return fail("test-only direct spawns in '{s}' are {d}, expected {d}", .{ path, direct, inventory.test_only_direct_spawns[inventory_index].count });
            direct_seen[inventory_index] = true;
            direct_total += direct;
        }

        typed_total += count(source, typed_spawn);
        for (inventory.resources, 0..) |resource, resource_index| {
            const pattern = try std.fmt.allocPrint(gpa, "runtime_threads.spawn(.{s}", .{resource.id});
            defer gpa.free(pattern);
            const found = count(source, pattern);
            if (found == 0) continue;
            var expected: usize = 0;
            for (resource.call_sites) |site| {
                if (std.mem.eql(u8, site.path, path)) expected += site.count;
            }
            if (found != expected)
                return fail("typed resource '{s}' occurs {d} times in '{s}', expected {d}", .{ resource.id, found, path, expected });
            typed_seen[resource_index] += found;
        }
    }
    if (wrapper_direct != 1) return fail("runtime thread boundary contains {d} direct spawn calls, expected 1", .{wrapper_direct});
    for (direct_seen, inventory.test_only_direct_spawns) |seen, item| {
        if (!seen) return fail("test-only direct-spawn inventory contains stale path '{s}'", .{item.path});
    }
    var expected_typed_total: usize = 0;
    for (inventory.resources, 0..) |resource, i| {
        var expected: usize = 0;
        for (resource.call_sites) |site| {
            expected += site.count;
        }
        if (typed_seen[i] != expected)
            return fail("typed resource '{s}' occurs {d} times, expected {d}", .{ resource.id, typed_seen[i], expected });
        expected_typed_total += expected;
    }
    if (typed_total != expected_typed_total)
        return fail("typed spawn boundary has {d} calls but only {d} are classified", .{ typed_total, expected_typed_total });
    return .{ .typed = typed_total, .test_only = direct_total };
}

pub fn main(init: std.process.Init) !void {
    const source = try read(init.gpa, init.io, inventory_path);
    defer init.gpa.free(source);
    const parsed = try std.json.parseFromSlice(Inventory, init.gpa, source, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try auditInventory(parsed.value);
    const result = try auditSources(init.gpa, init.io, parsed.value);
    std.debug.print("runtime-thread audit ok: {d} production call sites across {d} resource classes; {d} reviewed test-only direct spawns\n", .{
        result.typed,
        parsed.value.resources.len,
        result.test_only,
    });
}
