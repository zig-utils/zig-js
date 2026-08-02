//! Fail-closed audit for the repository dependency contract (#462).
//!
//! This tool deliberately uses only Zig's standard library. It compares every
//! discoverable dependency boundary with the checked inventory rather than
//! carrying a second allowlist in CI or in a shell wrapper.

const std = @import("std");

const inventory_path = "docs/.data/dependency-inventory-v1.json";
const tool_inventory_path = "docs/.data/tool-migration-inventory-v1.json";
const max_source_bytes = 16 * 1024 * 1024;

const DependencyClass = enum {
    zig_toolchain,
    standard_platform_interface,
    owner_maintained_local,
    owner_maintained_pinned_tooling,
    checksum_pinned_oracle,
    generated_data_acquisition_input,
    prohibited_unclassified,
};

const Status = enum { allowed, migration_required };

const Edge = struct {
    id: []const u8,
    class: DependencyClass,
    status: Status,
    scope: []const u8,
    locator: []const u8,
    pin: []const u8,
    license: []const u8,
    affects_runtime_semantics: bool,
    runtime_semantics: []const u8,
    migration_issue: ?u32 = null,
};

const BuildLink = struct { kind: []const u8, name: []const u8, count: usize, edge: []const u8 };
const NamedCount = struct { name: []const u8, count: usize, edge: []const u8 };
const ExtensionCount = struct { extension: []const u8, count: usize, edge: []const u8 };
const PathEdge = struct { path: []const u8, edge: []const u8 };
const OwnedSibling = struct { repository: []const u8, path: []const u8, revision: []const u8, occurrences: usize, edge: []const u8 };
const ProductionImport = struct { name: []const u8, external: bool, edge: ?[]const u8 = null };
const Submodule = struct { path: []const u8, url: []const u8, gitlink: []const u8, edge: []const u8 };
const PackageDependency = struct {
    manifest: []const u8,
    section: []const u8,
    name: []const u8,
    version: []const u8,
    lockfile: []const u8,
    locked_version: []const u8,
    integrity: []const u8,
    edge: []const u8,
    source_repository: ?[]const u8 = null,
};
const PackageScript = struct { manifest: []const u8, name: []const u8, command: []const u8, edge: []const u8 };
const PinnedDownload = struct { url: []const u8, sha256: []const u8, occurrences: usize, edge: []const u8 };
const PinnedCorpus = struct { url: []const u8, revision: []const u8, edge: []const u8 };

const Boundaries = struct {
    production_zig_paths: []const []const u8,
    owned_sibling_checkouts: []const OwnedSibling,
    production_imports: []const ProductionImport,
    build_links: []const BuildLink,
    system_commands: []const NamedCount,
    script_extensions: []const ExtensionCount,
    network_capable_scripts: []const PathEdge,
    submodules: []const Submodule,
    package_dependencies: []const PackageDependency,
    package_scripts: []const PackageScript,
    ci_actions: []const NamedCount,
    pinned_downloads: []const PinnedDownload,
    pinned_ci_corpora: []const PinnedCorpus,
};

const Inventory = struct {
    schema_version: u32,
    policy_id: []const u8,
    owner_issue: u32,
    classes: []const []const u8,
    edges: []const Edge,
    boundaries: Boundaries,
};

const ToolRuntime = enum { python, javascript, typescript, shell };
const MigrationTarget = enum { in_tree_zig, owned_zig_package, retain_bootstrap_glue };

const ContractProfile = struct {
    id: []const u8,
    exit_contract: []const u8,
    ordering: []const u8,
    diagnostics: []const u8,
    schema: []const u8,
    network: []const u8,
};

const ToolContract = struct {
    path: []const u8,
    runtime: ToolRuntime,
    role: []const u8,
    contract_profile: []const u8,
    inputs: []const []const u8,
    outputs: []const []const u8,
    subprocesses: []const []const u8,
    callers: []const []const u8,
    migration_target: MigrationTarget,
};

const ToolMigrationInventory = struct {
    schema_version: u32,
    policy_id: []const u8,
    owner_issue: u32,
    contract_profiles: []const ContractProfile,
    tools: []const ToolContract,
};

fn fail(comptime fmt: []const u8, args: anytype) error{DependencyAuditFailed} {
    std.debug.print("dependency audit: " ++ fmt ++ "\n", args);
    return error.DependencyAuditFailed;
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

fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_source_bytes));
}

fn nonEmptyStrings(values: []const []const u8) bool {
    if (values.len == 0) return false;
    for (values) |value| if (value.len == 0) return false;
    return true;
}

fn expectedRuntime(path: []const u8) ?ToolRuntime {
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".mjs")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts")) return .typescript;
    if (std.mem.endsWith(u8, path, ".sh")) return .shell;
    return null;
}

fn profileExists(inventory: ToolMigrationInventory, id: []const u8) bool {
    for (inventory.contract_profiles) |profile| {
        if (std.mem.eql(u8, profile.id, id)) return true;
    }
    return false;
}

fn toolIndex(inventory: ToolMigrationInventory, path: []const u8) ?usize {
    for (inventory.tools, 0..) |tool, i| {
        if (std.mem.eql(u8, tool.path, path)) return i;
    }
    return null;
}

fn callerListed(tool: ToolContract, path: []const u8) bool {
    for (tool.callers) |caller| if (std.mem.eql(u8, caller, path)) return true;
    return false;
}

fn isFilenameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

fn scriptExtensionLength(source: []const u8, dot: usize) ?usize {
    for ([_][]const u8{ ".py", ".mjs", ".ts", ".sh" }) |extension| {
        if (!std.mem.startsWith(u8, source[dot..], extension)) continue;
        const end = dot + extension.len;
        if (end == source.len or (!std.ascii.isAlphanumeric(source[end]) and source[end] != '_' and source[end] != '-')) return extension.len;
    }
    return null;
}

fn edgeExists(inventory: Inventory, id: []const u8) bool {
    for (inventory.edges) |edge| {
        if (std.mem.eql(u8, edge.id, id)) return true;
    }
    return false;
}

fn requireEdge(inventory: Inventory, id: []const u8) !void {
    if (!edgeExists(inventory, id)) return fail("boundary references unknown edge '{s}'", .{id});
}

fn auditInventory(inventory: Inventory) !void {
    if (inventory.schema_version != 1) return fail("unsupported schema {d}", .{inventory.schema_version});
    if (!std.mem.eql(u8, inventory.policy_id, "zig-js-owned-dependencies-v1"))
        return fail("unexpected policy id '{s}'", .{inventory.policy_id});
    if (inventory.owner_issue != 462) return fail("unexpected owner issue #{d}", .{inventory.owner_issue});
    const class_names = std.meta.fieldNames(DependencyClass);
    if (inventory.classes.len != class_names.len)
        return fail("class inventory has {d} entries, expected {d}", .{ inventory.classes.len, class_names.len });

    for (class_names) |class_name| {
        var seen = false;
        for (inventory.classes) |name| {
            if (std.mem.eql(u8, name, class_name)) seen = true;
        }
        if (!seen) return fail("class inventory omits '{s}'", .{class_name});
    }

    for (inventory.edges, 0..) |edge, i| {
        if (edge.id.len == 0 or edge.scope.len == 0 or edge.locator.len == 0 or edge.pin.len == 0 or edge.license.len == 0 or edge.runtime_semantics.len == 0)
            return fail("edge {d} has an empty required field", .{i});
        for (inventory.edges[0..i]) |prior| {
            if (std.mem.eql(u8, prior.id, edge.id)) return fail("duplicate edge id '{s}'", .{edge.id});
        }
        if (edge.class == .prohibited_unclassified and (edge.status != .migration_required or edge.migration_issue == null))
            return fail("prohibited edge '{s}' needs an owning migration issue", .{edge.id});
        if (edge.status == .migration_required and edge.migration_issue == null)
            return fail("migration edge '{s}' has no issue", .{edge.id});
    }

    for (inventory.boundaries.build_links) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.owned_sibling_checkouts) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.production_imports) |item| {
        if (item.external and item.edge == null) return fail("external import '{s}' has no edge", .{item.name});
        if (!item.external and item.edge != null) return fail("internal import '{s}' has an external edge", .{item.name});
        if (item.edge) |edge| try requireEdge(inventory, edge);
    }
    for (inventory.boundaries.system_commands) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.script_extensions) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.network_capable_scripts) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.submodules) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.package_dependencies) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.package_scripts) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.ci_actions) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.pinned_downloads) |item| try requireEdge(inventory, item.edge);
    for (inventory.boundaries.pinned_ci_corpora) |item| try requireEdge(inventory, item.edge);
}

fn auditZon(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const source = try read(gpa, io, "build.zig.zon");
    defer gpa.free(source);
    if (count(source, ".path = \"") != inventory.boundaries.production_zig_paths.len)
        return fail("build.zig.zon local path count drifted", .{});
    for (inventory.boundaries.production_zig_paths) |path| {
        const fragment = try std.fmt.allocPrint(gpa, ".path = \"{s}\"", .{path});
        defer gpa.free(fragment);
        if (count(source, fragment) != 1) return fail("build.zig.zon must contain exactly one '{s}'", .{fragment});
    }
    if (count(source, ".url =") != 0 or count(source, ".hash =") != 0)
        return fail("build.zig.zon may resolve only owned local-path dependencies", .{});
}

fn auditBuild(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const source = try read(gpa, io, "build.zig");
    defer gpa.free(source);

    var framework_total: usize = 0;
    var library_total: usize = 0;
    for (inventory.boundaries.build_links) |item| {
        const prefix = if (std.mem.eql(u8, item.kind, "framework")) "linkFramework(\"" else if (std.mem.eql(u8, item.kind, "system_library")) "linkSystemLibrary(\"" else return fail("unknown link kind '{s}'", .{item.kind});
        const fragment = try std.fmt.allocPrint(gpa, "{s}{s}\"", .{ prefix, item.name });
        defer gpa.free(fragment);
        const actual = count(source, fragment);
        if (actual != item.count) return fail("{s} count for '{s}' is {d}, expected {d}", .{ item.kind, item.name, actual, item.count });
        if (std.mem.eql(u8, item.kind, "framework")) framework_total += item.count else library_total += item.count;
    }
    if (count(source, "linkFramework(\"") != framework_total or count(source, "linkSystemLibrary(\"") != library_total)
        return fail("an unclassified framework or system-library link was added", .{});

    var actual_commands = std.StringHashMap(usize).init(gpa);
    defer actual_commands.deinit();
    const marker = "addSystemCommand(&.{";
    var rest = source;
    var command_total: usize = 0;
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        var cursor = at + marker.len;
        while (cursor < rest.len and std.ascii.isWhitespace(rest[cursor])) : (cursor += 1) {}
        if (cursor >= rest.len or rest[cursor] != '"') return fail("addSystemCommand has a non-literal executable", .{});
        const end = std.mem.indexOfScalarPos(u8, rest, cursor + 1, '"') orelse return fail("unterminated command executable", .{});
        const name = rest[cursor + 1 .. end];
        const entry = try actual_commands.getOrPut(name);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        command_total += 1;
        rest = rest[end + 1 ..];
    }
    var expected_total: usize = 0;
    for (inventory.boundaries.system_commands) |item| {
        const actual = actual_commands.get(item.name) orelse 0;
        if (actual != item.count) return fail("system command '{s}' occurs {d} times, expected {d}", .{ item.name, actual, item.count });
        expected_total += item.count;
    }
    if (command_total != expected_total or actual_commands.count() != inventory.boundaries.system_commands.len)
        return fail("an unclassified build subprocess was added", .{});

    const forbidden = [_][]const u8{ "std.http", "curl ", "wget ", "git clone", "https://", "http://" };
    for (forbidden) |token| {
        if (std.mem.indexOf(u8, source, token) != null) return fail("ordinary build graph contains network edge token '{s}'", .{token});
    }
}

fn objectPairCount(source: []const u8, section: []const u8) ?usize {
    const key_start = std.mem.indexOf(u8, source, section) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, key_start + section.len, '{') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, source, open + 1, '}') orelse return null;
    return count(source[open + 1 .. close], "\":");
}

fn auditPackage(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const dependency_sections = [_][]const u8{ "dependencies", "devDependencies", "peerDependencies", "optionalDependencies", "overrides" };
    for (inventory.boundaries.package_dependencies, 0..) |item, item_index| {
        var first_manifest = true;
        for (inventory.boundaries.package_dependencies[0..item_index]) |prior| {
            if (std.mem.eql(u8, prior.manifest, item.manifest)) first_manifest = false;
        }
        if (!first_manifest) continue;
        const source = try read(gpa, io, item.manifest);
        defer gpa.free(source);
        for (dependency_sections) |section_name| {
            var expected: usize = 0;
            for (inventory.boundaries.package_dependencies) |candidate| {
                if (std.mem.eql(u8, candidate.manifest, item.manifest) and std.mem.eql(u8, candidate.section, section_name)) expected += 1;
            }
            const section = try std.fmt.allocPrint(gpa, "\"{s}\"", .{section_name});
            defer gpa.free(section);
            const actual = objectPairCount(source, section);
            if (expected == 0 and actual != null) return fail("{s} gained unclassified section {s}", .{ item.manifest, section });
            if (expected != 0 and (actual == null or actual.? != expected))
                return fail("{s} section {s} has {d} edges, expected {d}", .{ item.manifest, section, actual orelse 0, expected });
        }
    }
    for (inventory.boundaries.package_dependencies, 0..) |item, item_index| {
        var first_section = true;
        for (inventory.boundaries.package_dependencies[0..item_index]) |prior| {
            if (std.mem.eql(u8, prior.manifest, item.manifest) and std.mem.eql(u8, prior.section, item.section)) first_section = false;
        }
        const source = try read(gpa, io, item.manifest);
        defer gpa.free(source);
        if (first_section) {
            var expected: usize = 0;
            for (inventory.boundaries.package_dependencies) |candidate| {
                if (std.mem.eql(u8, candidate.manifest, item.manifest) and std.mem.eql(u8, candidate.section, item.section)) expected += 1;
            }
            const section = try std.fmt.allocPrint(gpa, "\"{s}\"", .{item.section});
            defer gpa.free(section);
            const actual = objectPairCount(source, section) orelse return fail("{s} omits section {s}", .{ item.manifest, section });
            if (actual != expected) return fail("{s} section {s} has {d} edges, expected {d}", .{ item.manifest, section, actual, expected });
        }
        const fragment = try std.fmt.allocPrint(gpa, "\"{s}\": \"{s}\"", .{ item.name, item.version });
        defer gpa.free(fragment);
        if (count(source, fragment) != 1) return fail("package edge '{s}' drifted in {s}", .{ item.name, item.manifest });

        const lock = try read(gpa, io, item.lockfile);
        defer gpa.free(lock);
        const locked = try std.fmt.allocPrint(gpa, "{s}@{s}", .{ item.name, item.locked_version });
        defer gpa.free(locked);
        if (std.mem.indexOf(u8, lock, locked) == null)
            return fail("locked resolution for '{s}' drifted in {s}", .{ item.name, item.lockfile });
        const owned_revision_prefix = "owned-revision:";
        if (std.mem.startsWith(u8, item.integrity, owned_revision_prefix)) {
            const repository = item.source_repository orelse
                return fail("owned package '{s}' omits source_repository", .{item.name});
            const revision = item.integrity[owned_revision_prefix.len..];
            var found = false;
            for (inventory.boundaries.owned_sibling_checkouts) |sibling| {
                if (std.mem.eql(u8, sibling.repository, repository) and std.mem.eql(u8, sibling.revision, revision)) {
                    found = true;
                    break;
                }
            }
            if (!found) return fail("owned package '{s}' has no matching exact CI checkout", .{item.name});
        } else if (std.mem.indexOf(u8, lock, item.integrity) == null) {
            return fail("integrity evidence for '{s}' drifted in {s}", .{ item.name, item.lockfile });
        }
    }

    for (inventory.boundaries.package_scripts, 0..) |item, item_index| {
        var first_manifest = true;
        for (inventory.boundaries.package_scripts[0..item_index]) |prior| {
            if (std.mem.eql(u8, prior.manifest, item.manifest)) first_manifest = false;
        }
        const source = try read(gpa, io, item.manifest);
        defer gpa.free(source);
        if (first_manifest) {
            const actual = objectPairCount(source, "\"scripts\"") orelse return fail("{s} omits scripts", .{item.manifest});
            var expected: usize = 0;
            for (inventory.boundaries.package_scripts) |candidate| {
                if (std.mem.eql(u8, candidate.manifest, item.manifest)) expected += 1;
            }
            if (actual != expected) return fail("{s} has {d} scripts, expected {d}", .{ item.manifest, actual, expected });
        }
        const fragment = try std.fmt.allocPrint(gpa, "\"{s}\": \"{s}\"", .{ item.name, item.command });
        defer gpa.free(fragment);
        if (count(source, fragment) != 1) return fail("package script '{s}' drifted in {s}", .{ item.name, item.manifest });
    }
}

fn hasScriptExtension(path: []const u8, inventory: Inventory, index: *usize) bool {
    for (inventory.boundaries.script_extensions, 0..) |item, i| {
        if (std.mem.endsWith(u8, path, item.extension)) {
            index.* = i;
            return true;
        }
    }
    return false;
}

fn isNetworkCapable(source: []const u8) bool {
    const tokens = [_][]const u8{ "curl", "urlopen(", "requests.get", "requests.post", "fetch(" };
    for (tokens) |token| if (std.mem.indexOf(u8, source, token) != null) return true;
    return false;
}

fn listedNetworkScript(path: []const u8, inventory: Inventory) bool {
    for (inventory.boundaries.network_capable_scripts) |item| {
        if (std.mem.eql(u8, item.path, path)) return true;
    }
    return false;
}

fn auditScripts(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const actual = try gpa.alloc(usize, inventory.boundaries.script_extensions.len);
    defer gpa.free(actual);
    @memset(actual, 0);
    var network_count: usize = 0;

    for ([_][]const u8{ "tools", "scripts" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or std.mem.indexOf(u8, entry.path, "node_modules/") != null) continue;
            var extension_index: usize = undefined;
            if (!hasScriptExtension(entry.path, inventory, &extension_index)) continue;
            actual[extension_index] += 1;
            const path = try std.fs.path.join(gpa, &.{ root, entry.path });
            defer gpa.free(path);
            const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
            defer gpa.free(source);
            if (isNetworkCapable(source)) {
                network_count += 1;
                if (!listedNetworkScript(path, inventory)) return fail("network-capable script '{s}' is unclassified", .{path});
            }
        }
    }
    for (inventory.boundaries.script_extensions, 0..) |item, i| {
        if (actual[i] != item.count) return fail("script count for '{s}' is {d}, expected {d}", .{ item.extension, actual[i], item.count });
    }
    if (network_count != inventory.boundaries.network_capable_scripts.len)
        return fail("network-capable script inventory contains a stale entry", .{});
}

fn auditToolMigrationInventory(gpa: std.mem.Allocator, io: std.Io, inventory: ToolMigrationInventory) !void {
    if (inventory.schema_version != 1) return fail("unsupported tool-migration schema {d}", .{inventory.schema_version});
    if (!std.mem.eql(u8, inventory.policy_id, "zig-js-tool-migration-v1"))
        return fail("unexpected tool-migration policy id '{s}'", .{inventory.policy_id});
    if (inventory.owner_issue != 497) return fail("unexpected tool-migration owner issue #{d}", .{inventory.owner_issue});

    for (inventory.contract_profiles, 0..) |profile, i| {
        if (profile.id.len == 0 or profile.exit_contract.len == 0 or profile.ordering.len == 0 or profile.diagnostics.len == 0 or profile.schema.len == 0 or profile.network.len == 0)
            return fail("tool contract profile {d} has an empty required field", .{i});
        for (inventory.contract_profiles[0..i]) |prior| {
            if (std.mem.eql(u8, prior.id, profile.id)) return fail("duplicate tool contract profile '{s}'", .{profile.id});
        }
    }

    for (inventory.tools, 0..) |tool, i| {
        if (tool.path.len == 0 or tool.role.len == 0 or !nonEmptyStrings(tool.inputs) or !nonEmptyStrings(tool.outputs))
            return fail("tool contract {d} has an empty required field", .{i});
        if (tool.subprocesses.len != 0 and !nonEmptyStrings(tool.subprocesses))
            return fail("tool '{s}' has an empty subprocess", .{tool.path});
        if (!profileExists(inventory, tool.contract_profile))
            return fail("tool '{s}' references unknown contract profile '{s}'", .{ tool.path, tool.contract_profile });
        const runtime = expectedRuntime(tool.path) orelse return fail("tool '{s}' has an unsupported extension", .{tool.path});
        if (runtime != tool.runtime) return fail("tool '{s}' runtime does not match its extension", .{tool.path});
        if (!std.mem.startsWith(u8, tool.path, "tools/") and !std.mem.startsWith(u8, tool.path, "scripts/"))
            return fail("tool '{s}' is outside the audited roots", .{tool.path});
        for (inventory.tools[0..i]) |prior| {
            if (std.mem.eql(u8, prior.path, tool.path)) return fail("duplicate tool contract '{s}'", .{tool.path});
        }
        for (tool.callers, 0..) |caller, caller_index| {
            if (caller.len == 0 or std.mem.eql(u8, caller, tool.path) or std.mem.eql(u8, caller, tool_inventory_path))
                return fail("tool '{s}' has invalid caller '{s}'", .{ tool.path, caller });
            for (tool.callers[0..caller_index]) |prior| {
                if (std.mem.eql(u8, prior, caller)) return fail("tool '{s}' repeats caller '{s}'", .{ tool.path, caller });
            }
        }
    }

    const index_source = try gitIndexSource(gpa, io);
    defer gpa.free(index_source);
    if (index_source.len < 12 or !std.mem.eql(u8, index_source[0..4], "DIRC")) return fail("invalid git index", .{});
    const version = std.mem.readInt(u32, index_source[4..8], .big);
    if (version != 2) return fail("git index version {d} is not audited", .{version});
    const entries = std.mem.readInt(u32, index_source[8..12], .big);
    const actual_callers = try gpa.alloc(usize, inventory.tools.len);
    defer gpa.free(actual_callers);
    @memset(actual_callers, 0);
    const found_tools = try gpa.alloc(bool, inventory.tools.len);
    defer gpa.free(found_tools);
    @memset(found_tools, false);
    var tool_names = std.StringHashMap(usize).init(gpa);
    defer tool_names.deinit();
    for (inventory.tools, 0..) |tool, i| {
        const basename = std.fs.path.basename(tool.path);
        const entry = try tool_names.getOrPut(basename);
        if (entry.found_existing) return fail("tool basename '{s}' is ambiguous", .{basename});
        entry.value_ptr.* = i;
    }
    const matched_in_file = try gpa.alloc(bool, inventory.tools.len);
    defer gpa.free(matched_in_file);

    var cursor: usize = 12;
    var entry_index: u32 = 0;
    while (entry_index < entries) : (entry_index += 1) {
        if (cursor + 62 > index_source.len) return fail("truncated git index entry", .{});
        const name_start = cursor + 62;
        const name_end = std.mem.indexOfScalarPos(u8, index_source, name_start, 0) orelse return fail("unterminated git index path", .{});
        const path = index_source[name_start..name_end];
        const mode = std.mem.readInt(u32, index_source[cursor + 24 ..][0..4], .big);
        if (toolIndex(inventory, path)) |i| found_tools[i] = true;

        // Do not follow tracked symlinks while classifying call sites. The real
        // tracked target is audited directly, and following links would count
        // aliases such as AGENTS.md as a second caller of CLAUDE.md commands.
        if (mode != 0o120000 and !std.mem.eql(u8, path, tool_inventory_path)) {
            const source: ?[]u8 = read(gpa, io, path) catch |err| switch (err) {
                error.FileNotFound, error.IsDir => null,
                else => return err,
            };
            if (source) |text_source| {
                defer gpa.free(text_source);
                @memset(matched_in_file, false);
                var search_at: usize = 0;
                while (std.mem.indexOfScalarPos(u8, text_source, search_at, '.')) |dot| {
                    search_at = dot + 1;
                    const extension_len = scriptExtensionLength(text_source, dot) orelse continue;
                    var start = dot;
                    while (start != 0 and isFilenameByte(text_source[start - 1])) start -= 1;
                    const basename = text_source[start .. dot + extension_len];
                    const i = tool_names.get(basename) orelse continue;
                    if (matched_in_file[i]) continue;
                    const tool = inventory.tools[i];
                    if (std.mem.eql(u8, path, tool.path)) continue;
                    if (!callerListed(tool, path))
                        return fail("tool '{s}' has unclassified caller/reference '{s}'", .{ tool.path, path });
                    actual_callers[i] += 1;
                    matched_in_file[i] = true;
                }
            }
        }

        cursor += std.mem.alignForward(usize, name_end - cursor + 1, 8);
    }

    for (inventory.tools, 0..) |tool, i| {
        if (!found_tools[i]) return fail("tool inventory contains untracked or stale path '{s}'", .{tool.path});
        if (actual_callers[i] != tool.callers.len)
            return fail("tool '{s}' has {d} caller/reference files, expected {d}", .{ tool.path, actual_callers[i], tool.callers.len });
    }
}

fn auditSubmodules(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const source = try read(gpa, io, ".gitmodules");
    defer gpa.free(source);
    if (count(source, "[submodule \"") != inventory.boundaries.submodules.len)
        return fail("submodule count drifted", .{});
    for (inventory.boundaries.submodules) |item| {
        const path_fragment = try std.fmt.allocPrint(gpa, "path = {s}", .{item.path});
        defer gpa.free(path_fragment);
        const url_fragment = try std.fmt.allocPrint(gpa, "url = {s}", .{item.url});
        defer gpa.free(url_fragment);
        if (count(source, path_fragment) != 1 or count(source, url_fragment) == 0)
            return fail("submodule '{s}' path or URL drifted", .{item.path});
        if (item.gitlink.len != 40) return fail("submodule '{s}' has a non-SHA-1 gitlink", .{item.path});
    }
    try auditGitIndex(gpa, io, inventory);
}

fn gitIndexSource(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return read(gpa, io, ".git/index") catch {
        const dot_git = try read(gpa, io, ".git");
        defer gpa.free(dot_git);
        const prefix = "gitdir: ";
        if (!std.mem.startsWith(u8, dot_git, prefix)) return fail("cannot resolve git index", .{});
        const dir = std.mem.trim(u8, dot_git[prefix.len..], " \t\r\n");
        const path = try std.fs.path.join(gpa, &.{ dir, "index" });
        defer gpa.free(path);
        return read(gpa, io, path);
    };
}

fn hexSha(bytes: []const u8, output: *[40]u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        output[i * 2] = digits[byte >> 4];
        output[i * 2 + 1] = digits[byte & 0xf];
    }
}

fn knownPackageManifest(path: []const u8, dependencies: []const PackageDependency) bool {
    for (dependencies) |item| if (std.mem.eql(u8, item.manifest, path)) return true;
    return false;
}

fn uniquePackageManifestCount(dependencies: []const PackageDependency) usize {
    var total: usize = 0;
    for (dependencies, 0..) |item, i| {
        var first = true;
        for (dependencies[0..i]) |prior| {
            if (std.mem.eql(u8, prior.manifest, item.manifest)) first = false;
        }
        if (first) total += 1;
    }
    return total;
}

fn auditGitIndex(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const submodules = inventory.boundaries.submodules;
    const source = try gitIndexSource(gpa, io);
    defer gpa.free(source);
    if (source.len < 12 or !std.mem.eql(u8, source[0..4], "DIRC")) return fail("invalid git index", .{});
    const version = std.mem.readInt(u32, source[4..8], .big);
    if (version != 2) return fail("git index version {d} is not audited", .{version});
    const entries = std.mem.readInt(u32, source[8..12], .big);
    var found = try gpa.alloc(bool, submodules.len);
    defer gpa.free(found);
    @memset(found, false);
    var package_manifests: usize = 0;
    var zon_manifests: usize = 0;
    var cursor: usize = 12;
    var entry_index: u32 = 0;
    while (entry_index < entries) : (entry_index += 1) {
        if (cursor + 62 > source.len) return fail("truncated git index entry", .{});
        const name_start = cursor + 62;
        const name_end = std.mem.indexOfScalarPos(u8, source, name_start, 0) orelse return fail("unterminated git index path", .{});
        const path = source[name_start..name_end];
        if (std.mem.endsWith(u8, path, "package.json")) {
            if (!knownPackageManifest(path, inventory.boundaries.package_dependencies))
                return fail("tracked package manifest '{s}' is unclassified", .{path});
            package_manifests += 1;
        }
        if (std.mem.endsWith(u8, path, "build.zig.zon")) zon_manifests += 1;
        for (submodules, 0..) |item, i| {
            if (!std.mem.eql(u8, path, item.path)) continue;
            var actual: [40]u8 = undefined;
            hexSha(source[cursor + 40 .. cursor + 60], &actual);
            if (!std.mem.eql(u8, &actual, item.gitlink)) return fail("submodule '{s}' gitlink is {s}, expected {s}", .{ item.path, actual, item.gitlink });
            found[i] = true;
        }
        const entry_len = std.mem.alignForward(usize, name_end - cursor + 1, 8);
        cursor += entry_len;
    }
    for (submodules, 0..) |item, i| if (!found[i]) return fail("submodule '{s}' is absent from the git index", .{item.path});
    const expected_package_manifests = uniquePackageManifestCount(inventory.boundaries.package_dependencies);
    if (package_manifests != expected_package_manifests)
        return fail("tracked package manifest count is {d}, expected {d}", .{ package_manifests, expected_package_manifests });
    if (zon_manifests != 1) return fail("tracked build.zig.zon count is {d}, expected 1", .{zon_manifests});
}

fn auditCi(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const source = try read(gpa, io, ".github/workflows/ci.yml");
    defer gpa.free(source);
    var sibling_occurrences: usize = 0;
    for (inventory.boundaries.owned_sibling_checkouts) |item| {
        const fragment = try std.fmt.allocPrint(
            gpa,
            "repository: {s}\n          path: {s}\n          ref: {s}",
            .{ item.repository, item.path, item.revision },
        );
        defer gpa.free(fragment);
        const actual = count(source, fragment);
        if (actual != item.occurrences)
            return fail("owned sibling {s}@{s} occurs {d} times, expected {d}", .{ item.repository, item.revision, actual, item.occurrences });
        sibling_occurrences += item.occurrences;
    }
    if (count(source, "repository: ") != sibling_occurrences)
        return fail("CI contains an unclassified owned sibling checkout", .{});

    var action_occurrences: usize = 0;
    for (inventory.boundaries.ci_actions) |item| {
        const fragment = try std.fmt.allocPrint(gpa, "uses: {s}", .{item.name});
        defer gpa.free(fragment);
        const actual = count(source, fragment);
        if (actual != item.count) return fail("CI action '{s}' occurs {d} times, expected {d}", .{ item.name, actual, item.count });
        action_occurrences += item.count;
    }
    if (count(source, "uses: ") != action_occurrences) return fail("CI contains an unclassified action", .{});

    var download_occurrences: usize = 0;
    for (inventory.boundaries.pinned_downloads) |item| {
        const urls = count(source, item.url);
        const hashes = count(source, item.sha256);
        if (urls != item.occurrences or hashes != item.occurrences)
            return fail("download pin '{s}' occurs URL/hash {d}/{d}, expected {d}/{d}", .{ item.url, urls, hashes, item.occurrences, item.occurrences });
        download_occurrences += item.occurrences;
    }
    if (count(source, "releases/download/") != download_occurrences)
        return fail("CI contains an unclassified release download", .{});

    for (inventory.boundaries.pinned_ci_corpora) |item| {
        const remote = try std.fmt.allocPrint(gpa, "remote add origin {s}", .{item.url});
        defer gpa.free(remote);
        var rest = source;
        var matched = false;
        while (std.mem.indexOf(u8, rest, remote)) |at| {
            const end = @min(rest.len, at + remote.len + 500);
            if (std.mem.indexOf(u8, rest[at..end], item.revision) != null) {
                matched = true;
                break;
            }
            rest = rest[at + remote.len ..];
        }
        if (!matched) return fail("CI corpus {s}@{s} is not pinned beside its remote", .{ item.url, item.revision });
    }
    if (count(source, "remote add origin https://github.com/WebAssembly/") != inventory.boundaries.pinned_ci_corpora.len)
        return fail("CI contains an unclassified WebAssembly corpus checkout", .{});
}

fn auditProductionSources(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory) !void {
    const imports_found = try gpa.alloc(bool, inventory.boundaries.production_imports.len);
    defer gpa.free(imports_found);
    @memset(imports_found, false);
    for ([_][]const u8{ "src", "bench" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
            defer gpa.free(source);
            for ([_][]const u8{ "std.http.Client", "std.DynLib", "dlopen(", "LoadLibrary(" }) |token| {
                if (std.mem.indexOf(u8, source, token) != null)
                    return fail("{s}/{s} adds dynamic/network dependency token '{s}'", .{ root, entry.path, token });
            }
            const marker = "@import(\"";
            var rest = source;
            while (std.mem.indexOf(u8, rest, marker)) |at| {
                const start = at + marker.len;
                const end = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse return fail("unterminated import in {s}/{s}", .{ root, entry.path });
                const name = rest[start..end];
                if (std.mem.indexOfScalar(u8, name, '/') == null and !std.mem.endsWith(u8, name, ".zig")) {
                    var matched = false;
                    for (inventory.boundaries.production_imports, 0..) |item, i| {
                        if (std.mem.eql(u8, item.name, name)) {
                            imports_found[i] = true;
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) return fail("{s}/{s} imports unclassified module '{s}'", .{ root, entry.path, name });
                }
                rest = rest[end + 1 ..];
            }
        }
    }
    for (inventory.boundaries.production_imports, 0..) |item, i| {
        if (!imports_found[i]) return fail("production import inventory contains stale module '{s}'", .{item.name});
    }
}

pub fn main(init: std.process.Init) !void {
    const inventory_source = try read(init.gpa, init.io, inventory_path);
    defer init.gpa.free(inventory_source);
    const parsed = try std.json.parseFromSlice(Inventory, init.gpa, inventory_source, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const inventory = parsed.value;

    const tool_inventory_source = try read(init.gpa, init.io, tool_inventory_path);
    defer init.gpa.free(tool_inventory_source);
    const parsed_tools = try std.json.parseFromSlice(ToolMigrationInventory, init.gpa, tool_inventory_source, .{ .allocate = .alloc_always });
    defer parsed_tools.deinit();
    const tool_inventory = parsed_tools.value;

    try auditInventory(inventory);
    try auditZon(init.gpa, init.io, inventory);
    try auditBuild(init.gpa, init.io, inventory);
    try auditPackage(init.gpa, init.io, inventory);
    try auditScripts(init.gpa, init.io, inventory);
    try auditToolMigrationInventory(init.gpa, init.io, tool_inventory);
    try auditSubmodules(init.gpa, init.io, inventory);
    try auditCi(init.gpa, init.io, inventory);
    try auditProductionSources(init.gpa, init.io, inventory);

    std.debug.print("dependency audit ok: {d} classified edges, {d} migration targets, {d} classified repository tools\n", .{
        inventory.edges.len,
        count(inventory_source, "\"status\": \"migration_required\""),
        tool_inventory.tools.len,
    });
}
