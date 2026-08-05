//! Offline validator for the out-of-tree benchmark and engine inventory (#504).
//!
//! This gate validates pins and evidence boundaries only. It deliberately does
//! not acquire or execute a suite, so ordinary builds remain network-free and
//! no candidate can be mistaken for performance evidence.

const std = @import("std");

const inventory_path = "docs/.data/independent-suite-inventory-v1.json";
const max_inventory_bytes = 2 * 1024 * 1024;

const Disposition = enum { applicable_candidate, excluded };

const FilePin = struct {
    path: []const u8,
    sha256: []const u8,
};

const Source = struct {
    repository: []const u8,
    revision: []const u8,
    tree: []const u8,
};

const Maintenance = struct {
    status: []const u8,
    evidence: []const u8,
    claim_boundary: []const u8,
};

const Assessment = struct {
    determinism: []const u8,
    workload_coverage: []const u8,
    run_duration: []const u8,
    host_api_requirements: []const []const u8,
};

const License = struct {
    spdx: []const u8,
    path: []const u8,
    sha256: []const u8,
    per_row_audit_required: bool,
};

const Adapter = struct {
    status: []const u8,
    allowed_host_globals: []const []const u8,
    source_transform: bool,
    timed_boundary: []const u8,
    output_contract: []const u8,
};

const Row = struct {
    id: []const u8,
    upstream_results: []const []const u8,
    disposition: Disposition,
    files: []const FilePin,
    licenses: []const []const u8,
    host_requirements: []const []const u8,
    exclusion_reason: ?[]const u8 = null,
};

const Suite = struct {
    id: []const u8,
    title: []const u8,
    source: Source,
    maintenance: Maintenance,
    assessment: Assessment,
    top_level_license: License,
    harness_files: []const FilePin,
    adapter: Adapter,
    rows: []const Row,
};

const Engine = struct {
    id: []const u8,
    kind: []const u8,
    disposition: []const u8,
    adapter_status: []const u8,
    required_run_metadata: []const []const u8,
};

const Policy = struct {
    checkout_location: []const u8,
    acquisition_network: []const u8,
    execution_network: []const u8,
    ordinary_build_dependency: bool,
    runtime_dependency: bool,
    vendored_suite_files: bool,
    source_transforms: []const u8,
    row_policy: []const u8,
    publication_policy: []const u8,
};

const EvidenceContract = struct {
    retained_row_fields: []const []const u8,
    aggregate_policy: []const u8,
    host_adapter_policy: []const u8,
    engine_isolation: []const u8,
    child_schema_version: u32,
    collection_schema_version: u32,
    minimum_score_samples: u32,
    minimum_attribution_samples: u32,
    checkpoint_policy: []const u8,
    dispersion_policy: []const u8,
    aggregate_failure_policy: []const u8,
    publication_policy: []const u8,
};

const Inventory = struct {
    schema_version: u32,
    inventory_id: []const u8,
    status: []const u8,
    owner_issue: u32,
    policy: Policy,
    suites: []const Suite,
    engines: []const Engine,
    evidence_contract: EvidenceContract,
};

var diagnostics_enabled = true;

fn fail(comptime fmt: []const u8, args: anytype) error{IndependentSuiteInventoryFailed} {
    if (diagnostics_enabled) std.debug.print("independent-suite audit: " ++ fmt ++ "\n", args);
    return error.IndependentSuiteInventoryFailed;
}

fn isHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn nonEmptyStrings(values: []const []const u8) bool {
    if (values.len == 0) return false;
    for (values) |value| if (value.len == 0) return false;
    return true;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn validateFilePin(suite_id: []const u8, file: FilePin) !void {
    if (file.path.len == 0 or std.fs.path.isAbsolute(file.path) or std.mem.indexOf(u8, file.path, "..") != null)
        return fail("suite '{s}' has invalid relative file path '{s}'", .{ suite_id, file.path });
    if (!isHex(file.sha256, 64)) return fail("suite '{s}' file '{s}' lacks an exact SHA-256", .{ suite_id, file.path });
}

fn validateInventory(inventory: Inventory) !void {
    if (inventory.schema_version != 1 or !std.mem.eql(u8, inventory.inventory_id, "zig-js-independent-suite-inventory-v1"))
        return fail("schema identity drift", .{});
    if (!std.mem.eql(u8, inventory.status, "frozen_candidate_inventory") or inventory.owner_issue != 504)
        return fail("inventory ownership/status drift", .{});

    const policy = inventory.policy;
    if (!std.mem.eql(u8, policy.checkout_location, "operator_path_outside_repository") or
        !std.mem.eql(u8, policy.acquisition_network, "explicit_operator_only") or
        !std.mem.eql(u8, policy.execution_network, "forbidden") or
        policy.ordinary_build_dependency or policy.runtime_dependency or policy.vendored_suite_files or
        !std.mem.eql(u8, policy.source_transforms, "forbidden"))
        return fail("out-of-tree/offline dependency boundary drift", .{});
    if (policy.row_policy.len == 0 or policy.publication_policy.len == 0)
        return fail("inventory policy explanation is incomplete", .{});

    if (inventory.suites.len < 2) return fail("candidate inventory needs at least two independently sourced suites", .{});
    var applicable_results: usize = 0;
    var excluded_results: usize = 0;
    for (inventory.suites, 0..) |suite, suite_index| {
        if (suite.id.len == 0 or suite.title.len == 0 or suite.rows.len == 0)
            return fail("suite {d} has an empty required field", .{suite_index});
        for (inventory.suites[0..suite_index]) |prior| if (std.mem.eql(u8, prior.id, suite.id))
            return fail("duplicate suite id '{s}'", .{suite.id});
        if (!std.mem.startsWith(u8, suite.source.repository, "https://github.com/") or
            !std.mem.endsWith(u8, suite.source.repository, ".git") or
            !isHex(suite.source.revision, 40) or !isHex(suite.source.tree, 40))
            return fail("suite '{s}' source is not exact", .{suite.id});
        if (suite.maintenance.status.len == 0 or !std.mem.startsWith(u8, suite.maintenance.evidence, "https://") or suite.maintenance.claim_boundary.len == 0)
            return fail("suite '{s}' maintenance/claim boundary is incomplete", .{suite.id});
        if (suite.assessment.determinism.len == 0 or suite.assessment.workload_coverage.len == 0 or
            suite.assessment.run_duration.len == 0 or !nonEmptyStrings(suite.assessment.host_api_requirements))
            return fail("suite '{s}' candidate assessment is incomplete", .{suite.id});
        if (suite.top_level_license.spdx.len == 0 or !suite.top_level_license.per_row_audit_required)
            return fail("suite '{s}' top-level license is incomplete", .{suite.id});
        try validateFilePin(suite.id, .{ .path = suite.top_level_license.path, .sha256 = suite.top_level_license.sha256 });
        if (suite.harness_files.len == 0) return fail("suite '{s}' has no pinned harness files", .{suite.id});
        for (suite.harness_files) |file| try validateFilePin(suite.id, file);
        if (suite.adapter.status.len == 0 or suite.adapter.source_transform or suite.adapter.timed_boundary.len == 0 or suite.adapter.output_contract.len == 0)
            return fail("suite '{s}' adapter boundary is invalid", .{suite.id});

        var result_names: std.StringHashMap(void) = .init(std.heap.page_allocator);
        defer result_names.deinit();
        var suite_applicable_results: usize = 0;
        for (suite.rows, 0..) |row, row_index| {
            if (row.id.len == 0 or !nonEmptyStrings(row.upstream_results) or !nonEmptyStrings(row.licenses))
                return fail("suite '{s}' row {d} has an empty required field", .{ suite.id, row_index });
            for (suite.rows[0..row_index]) |prior| if (std.mem.eql(u8, prior.id, row.id))
                return fail("suite '{s}' repeats row id '{s}'", .{ suite.id, row.id });
            for (row.upstream_results) |result| {
                const entry = try result_names.getOrPut(result);
                if (entry.found_existing) return fail("suite '{s}' repeats upstream result '{s}'", .{ suite.id, result });
                if (row.disposition == .applicable_candidate) {
                    applicable_results += 1;
                    suite_applicable_results += 1;
                } else excluded_results += 1;
            }
            for (row.files) |file| try validateFilePin(suite.id, file);
            switch (row.disposition) {
                .applicable_candidate => {
                    if (row.files.len == 0 or row.exclusion_reason != null)
                        return fail("suite '{s}' applicable row '{s}' is incomplete or carries an exclusion", .{ suite.id, row.id });
                    for (row.licenses) |license| if (std.mem.eql(u8, license, "NOASSERTION"))
                        return fail("suite '{s}' applicable row '{s}' has unresolved licensing", .{ suite.id, row.id });
                },
                .excluded => if (row.exclusion_reason == null or row.exclusion_reason.?.len == 0)
                    return fail("suite '{s}' excluded row '{s}' has no reason", .{ suite.id, row.id }),
            }
        }
        if (std.mem.eql(u8, suite.id, "octane-2-retired")) {
            if (result_names.count() != 17 or suite_applicable_results != 6)
                return fail("Octane inventory has {d} results / {d} candidates, expected 17 / 6", .{ result_names.count(), suite_applicable_results });
            if (!std.mem.eql(u8, suite.adapter.status, "minimal_shell_v1_implemented") or
                suite.adapter.allowed_host_globals.len != 2 or
                !contains(suite.adapter.allowed_host_globals, "load") or !contains(suite.adapter.allowed_host_globals, "print"))
                return fail("Octane minimal shell adapter boundary drift", .{});
        } else if (std.mem.eql(u8, suite.id, "jetstream-3-alpha")) {
            if (suite_applicable_results != 0) return fail("JetStream alpha cannot gain an applicable row in frozen V1", .{});
        } else return fail("unrecognized suite '{s}' in frozen V1", .{suite.id});
    }
    if (applicable_results == 0 or excluded_results == 0)
        return fail("inventory must distinguish applicable and excluded results", .{});

    const expected_engines = [_][]const u8{ "zig-js", "system-jsc", "v8", "spidermonkey", "quickjs" };
    if (inventory.engines.len != expected_engines.len) return fail("engine inventory size drift", .{});
    for (expected_engines) |id| {
        var found = false;
        for (inventory.engines, 0..) |engine, engine_index| {
            if (!std.mem.eql(u8, engine.id, id)) continue;
            found = true;
            if (engine.kind.len == 0 or engine.disposition.len == 0 or engine.adapter_status.len == 0)
                return fail("engine '{s}' classification is incomplete", .{id});
            if (std.mem.eql(u8, id, "zig-js") and !std.mem.eql(u8, engine.adapter_status, "minimal_shell_v1_implemented"))
                return fail("zig-js independent-suite adapter status drift", .{});
            if (!contains(engine.required_run_metadata, "executable_path") or
                !contains(engine.required_run_metadata, "executable_sha256") or
                !contains(engine.required_run_metadata, "version_output") or
                !contains(engine.required_run_metadata, "argv") or
                !contains(engine.required_run_metadata, "environment"))
                return fail("engine '{s}' pin contract is incomplete", .{id});
            for (inventory.engines[0..engine_index]) |prior| if (std.mem.eql(u8, prior.id, id))
                return fail("duplicate engine id '{s}'", .{id});
        }
        if (!found) return fail("engine inventory omits '{s}'", .{id});
    }

    const evidence = inventory.evidence_contract;
    for ([_][]const u8{ "suite", "row", "engine", "status", "failure", "skip_reason", "raw_samples", "dispersion", "validated_output", "timed_boundary" }) |field| {
        if (!contains(evidence.retained_row_fields, field)) return fail("evidence contract omits '{s}'", .{field});
    }
    if (evidence.aggregate_policy.len == 0 or evidence.host_adapter_policy.len == 0 or evidence.engine_isolation.len == 0)
        return fail("evidence boundary is incomplete", .{});
    if (evidence.child_schema_version != 1 or evidence.collection_schema_version != 1 or
        evidence.minimum_score_samples < 2 or evidence.minimum_attribution_samples < 1)
        return fail("independent-suite collection schema/sample contract drift", .{});
    if (evidence.checkpoint_policy.len == 0 or evidence.dispersion_policy.len == 0 or
        evidence.aggregate_failure_policy.len == 0 or evidence.publication_policy.len == 0)
        return fail("independent-suite collection evidence policy is incomplete", .{});
}

fn parseAndValidate(gpa: std.mem.Allocator, source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Inventory, gpa, source, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try validateInventory(parsed.value);
}

fn trimLine(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn runGit(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const completed = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .expand_arg0 = .expand,
    }) catch |err| return fail("cannot run bounded git command: {t}", .{err});
    defer gpa.free(completed.stderr);
    switch (completed.term) {
        .exited => |code| if (code != 0) {
            defer gpa.free(completed.stdout);
            return fail("git command failed ({d}): {s}", .{ code, trimLine(completed.stderr) });
        },
        else => {
            defer gpa.free(completed.stdout);
            return fail("git command did not exit normally", .{});
        },
    }
    return completed.stdout;
}

fn gitAt(gpa: std.mem.Allocator, io: std.Io, checkout: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", checkout });
    try argv.appendSlice(gpa, args);
    return runGit(gpa, io, argv.items);
}

fn isWithin(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, path, parent)) return true;
    if (!std.mem.startsWith(u8, path, parent) or path.len <= parent.len) return false;
    return std.fs.path.isSep(path[parent.len]);
}

fn verifyFile(gpa: std.mem.Allocator, io: std.Io, checkout: []const u8, suite_id: []const u8, file: FilePin) !void {
    const path = try std.fs.path.join(gpa, &.{ checkout, file.path });
    defer gpa.free(path);
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err|
        return fail("suite '{s}' cannot read pinned file '{s}': {t}", .{ suite_id, file.path, err });
    defer gpa.free(source);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, file.sha256))
        return fail("suite '{s}' file '{s}' SHA-256 drift: expected {s}, got {s}", .{ suite_id, file.path, file.sha256, actual });
}

fn verifyCheckout(gpa: std.mem.Allocator, io: std.Io, inventory: Inventory, suite_id: []const u8, checkout_arg: []const u8) !usize {
    var suite: ?Suite = null;
    for (inventory.suites) |candidate| {
        if (std.mem.eql(u8, candidate.id, suite_id)) suite = candidate;
    }
    const selected = suite orelse return fail("unknown suite id '{s}'", .{suite_id});

    const checkout = std.Io.Dir.cwd().realPathFileAlloc(io, checkout_arg, gpa) catch |err|
        return fail("cannot resolve checkout '{s}': {t}", .{ checkout_arg, err });
    defer gpa.free(checkout);

    const common_dir_raw = try gitAt(gpa, io, ".", &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    defer gpa.free(common_dir_raw);
    const common_dir = trimLine(common_dir_raw);
    const repository_root = std.fs.path.dirname(common_dir) orelse return fail("cannot resolve zig-js repository root from '{s}'", .{common_dir});
    if (isWithin(checkout, repository_root))
        return fail("suite checkout '{s}' is inside zig-js repository '{s}'", .{ checkout, repository_root });

    const remote_raw = try gitAt(gpa, io, checkout, &.{ "remote", "get-url", "origin" });
    defer gpa.free(remote_raw);
    if (!std.mem.eql(u8, trimLine(remote_raw), selected.source.repository))
        return fail("suite '{s}' origin drift: expected {s}, got {s}", .{ suite_id, selected.source.repository, trimLine(remote_raw) });

    const identity_raw = try gitAt(gpa, io, checkout, &.{ "rev-parse", "HEAD", "HEAD^{tree}" });
    defer gpa.free(identity_raw);
    var lines = std.mem.splitScalar(u8, trimLine(identity_raw), '\n');
    const revision = lines.next() orelse "";
    const tree = lines.next() orelse "";
    if (lines.next() != null or !std.mem.eql(u8, revision, selected.source.revision) or !std.mem.eql(u8, tree, selected.source.tree))
        return fail("suite '{s}' identity drift: expected {s}/{s}, got {s}/{s}", .{ suite_id, selected.source.revision, selected.source.tree, revision, tree });

    const status_raw = try gitAt(gpa, io, checkout, &.{ "status", "--porcelain=v1", "--untracked-files=all" });
    defer gpa.free(status_raw);
    if (trimLine(status_raw).len != 0) return fail("suite '{s}' checkout is dirty: {s}", .{ suite_id, trimLine(status_raw) });

    var verified: usize = 0;
    try verifyFile(gpa, io, checkout, suite_id, .{ .path = selected.top_level_license.path, .sha256 = selected.top_level_license.sha256 });
    verified += 1;
    for (selected.harness_files) |file| {
        try verifyFile(gpa, io, checkout, suite_id, file);
        verified += 1;
    }
    for (selected.rows) |row| for (row.files) |file| {
        try verifyFile(gpa, io, checkout, suite_id, file);
        verified += 1;
    };
    return verified;
}

pub fn main(init: std.process.Init) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, inventory_path, init.gpa, .limited(max_inventory_bytes));
    defer init.gpa.free(source);
    const parsed = try std.json.parseFromSlice(Inventory, init.gpa, source, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try validateInventory(parsed.value);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    if (args.next()) |command| {
        if (!std.mem.eql(u8, command, "--verify-checkout")) {
            std.debug.print("usage: independent-suite-audit [--verify-checkout <suite-id> <path>]\n", .{});
            std.process.exit(2);
        }
        const suite_id = args.next() orelse {
            std.debug.print("independent-suite audit: --verify-checkout requires a suite id and path\n", .{});
            std.process.exit(2);
        };
        const checkout = args.next() orelse {
            std.debug.print("independent-suite audit: --verify-checkout requires a suite id and path\n", .{});
            std.process.exit(2);
        };
        if (args.next() != null) {
            std.debug.print("independent-suite audit: unexpected trailing argument\n", .{});
            std.process.exit(2);
        }
        const files = try verifyCheckout(init.gpa, init.io, parsed.value, suite_id, checkout);
        std.debug.print("independent-suite checkout ok: {s} at exact revision/tree with {d} pinned files\n", .{ suite_id, files });
        return;
    }
    std.debug.print("independent-suite audit ok: frozen candidate suites, 17 Octane results, and 5 engine pin contracts classified\n", .{});
}

test "checked independent-suite inventory validates" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, inventory_path, std.testing.allocator, .limited(max_inventory_bytes));
    defer std.testing.allocator.free(source);
    try parseAndValidate(std.testing.allocator, source);
}

test "pins and exclusion reasons fail closed" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, inventory_path, std.testing.allocator, .limited(max_inventory_bytes));
    defer std.testing.allocator.free(source);

    diagnostics_enabled = false;
    defer diagnostics_enabled = true;

    const bad_pin = try std.mem.replaceOwned(u8, std.testing.allocator, source, "570ad1ccfe86e3eecba0636c8f932ac08edec517", "unpinned");
    defer std.testing.allocator.free(bad_pin);
    try std.testing.expectError(error.IndependentSuiteInventoryFailed, parseAndValidate(std.testing.allocator, bad_pin));

    const bad_exclusion = try std.mem.replaceOwned(u8, std.testing.allocator, source, "External execution is permitted, but the first subset does not yet specify GPL notice retention in its evidence package.", "");
    defer std.testing.allocator.free(bad_exclusion);
    try std.testing.expectError(error.IndependentSuiteInventoryFailed, parseAndValidate(std.testing.allocator, bad_exclusion));
}

test "checkout containment rejects the repository and accepts siblings" {
    try std.testing.expect(isWithin("/work/zig-js", "/work/zig-js"));
    try std.testing.expect(isWithin("/work/zig-js/external", "/work/zig-js"));
    try std.testing.expect(!isWithin("/work/zig-js-other", "/work/zig-js"));
    try std.testing.expect(!isWithin("/tmp/octane", "/work/zig-js"));
}
