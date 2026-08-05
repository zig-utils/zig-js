//! Minimal zig-js shell adapter for the pinned Octane subset (#504).
//!
//! The adapter accepts only the frozen `base.js` plus one applicable workload,
//! verifies both byte streams before entering the engine, exposes only `load`
//! and `print` as additional host globals, and emits one self-describing JSON
//! sample. It does not rewrite upstream source, timing, inputs, or iteration
//! counts. Checkout identity is verified by the build step before this process
//! starts; this executable repeats the file-level SHA-256 boundary itself.

const std = @import("std");
const builtin = @import("builtin");
const js = @import("js");
const octane = @import("independent_suite_octane.zig");

const max_source_bytes = 32 * 1024 * 1024;
const protocol_marker = octane.protocol_marker;
const base_path = octane.base_path;
const base_sha256 = octane.base_sha256;
const RowSpec = octane.RowSpec;

const LoadedSource = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: []const u8,
};

const SourceIdentity = struct {
    path: []const u8,
    sha256: []const u8,
};

const EventKind = enum { result, @"error", score };
const RunMode = enum { score, attribution };

const ProtocolEvent = struct {
    kind: EventKind,
    name: []const u8,
    value: []const u8,
};

const AuxiliaryOutput = struct {
    arguments: []const []const u8,
};

const AdapterState = struct {
    gpa: std.mem.Allocator,
    sources: [2]LoadedSource,
    context: ?*js.Context = null,
    load_index: usize = 0,
    events: std.ArrayList(ProtocolEvent) = .empty,
    auxiliary: std.ArrayList(AuxiliaryOutput) = .empty,
    failure: ?[]const u8 = null,

    fn deinit(self: *AdapterState, own_sources: bool) void {
        for (self.events.items) |event| {
            self.gpa.free(event.name);
            self.gpa.free(event.value);
        }
        self.events.deinit(self.gpa);
        for (self.auxiliary.items) |entry| {
            for (entry.arguments) |argument| self.gpa.free(argument);
            self.gpa.free(entry.arguments);
        }
        self.auxiliary.deinit(self.gpa);
        if (self.failure) |failure| self.gpa.free(failure);
        if (own_sources) for (self.sources) |source| self.gpa.free(source.bytes);
    }

    fn recordFailure(self: *AdapterState, comptime fmt: []const u8, args: anytype) !void {
        if (self.failure == null) self.failure = try std.fmt.allocPrint(self.gpa, fmt, args);
    }
};

const NamedCounter = struct {
    name: []const u8,
    value: u64,
};

const GcSummary = struct {
    enabled: bool,
    attribution_status: []const u8,
    live_bytes: usize,
    last_full_collection_bytes: usize,
    collections: usize,
    full_collections: usize,
    backing_allocations: ?u64,
    backing_allocation_bytes: ?u64,
    backing_peak_bytes: ?u64,
    gc_cell_allocations: ?u64,
    gc_cell_bytes: ?u64,
    minor_pause_count: ?usize,
    minor_pause_overflow: ?u64,
    minor_pause_ns_total: ?u64,
    minor_pause_ns_max: ?u64,
    full_pause_count: ?usize,
    full_pause_overflow: ?u64,
    full_pause_ns_total: ?u64,
    full_pause_ns_max: ?u64,
};

const ProcessSnapshot = struct {
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    peak_rss_bytes: u64,
};

const RawSample = struct {
    index: usize,
    mode: RunMode,
    instrumentation_enabled: bool,
    outer_wall_ns: u64,
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    peak_rss_bytes_before: u64,
    peak_rss_bytes_after: u64,
};

const Dispersion = struct {
    status: []const u8 = "not_applicable_single_sample",
    sample_count: usize = 1,
    statistic: ?f64 = null,
};

const Validation = struct {
    status: []const u8,
    expected_result_names: []const []const u8,
    observed_result_names: []const []const u8,
    final_score_count: usize,
};

const TimedBoundary = struct {
    upstream: []const u8 = "Pinned Octane BenchmarkSuite.RunSingleBenchmark boundary: setup and teardown excluded; warmup unscored; each measurement runs for at least one second or the pinned minimum iteration count.",
    outer: []const u8 = "From immediately before zig-js Context creation through completion of the owned RunSuites driver; checkout verification, file reads, SHA-256 validation, JSON serialization, and Context destruction are excluded.",
};

const EngineIdentity = struct {
    id: []const u8 = "zig-js",
    executable_path: []const u8,
    executable_sha256: []const u8,
    source_revision: ?[]const u8,
    version_output: []const u8 = "zig-js repository-built independent-suite runner schema 1",
    argv: []const []const u8,
    environment: []const []const u8,
    separate_process: bool = true,
};

const TierReport = struct {
    status: []const u8,
    execution: []const NamedCounter,
    admissions: []const NamedCounter,
    timing: ?@TypeOf((@as(js.Context.TierAttributionSnapshot, undefined)).timing),
    baseline_publications: ?u64,
    optimizer_publications: ?u64,
    generated_code_bytes: ?usize,
};

const Report = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "zig-js-independent-suite-sample",
    suite: []const u8 = "octane-2-retired",
    suite_revision: []const u8 = "570ad1ccfe86e3eecba0636c8f932ac08edec517",
    suite_tree: []const u8 = "e40d5c8489d05e384f32ed064d1f5286e9c236f3",
    row: []const u8,
    licenses: []const []const u8,
    mode: RunMode,
    publication_status: []const u8 = "diagnostic_single_sample",
    engine: EngineIdentity,
    adapter: struct {
        id: []const u8 = "zig-js-octane-minimal-shell-v1",
        host_globals: []const []const u8 = &.{ "load", "print" },
        source_transform: bool = false,
        evaluation_step_budget: []const u8 = "18446744073709551615",
        termination_boundary: []const u8 = "external_process_timeout",
        loaded_sources: []const SourceIdentity,
    },
    status: []const u8,
    failure: ?[]const u8,
    skip_reason: ?[]const u8 = null,
    upstream_outputs: []const ProtocolEvent,
    auxiliary_outputs: []const AuxiliaryOutput,
    raw_samples: []const RawSample,
    dispersion: Dispersion = .{},
    validated_output: Validation,
    timed_boundary: TimedBoundary = .{},
    tier_attribution: TierReport,
    gc: GcSummary,
};

fn rowById(id: []const u8) ?*const RowSpec {
    return octane.rowById(id);
}

fn digestHex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn readPinnedSource(gpa: std.mem.Allocator, io: std.Io, checkout: []const u8, path: []const u8, expected_sha256: []const u8) !LoadedSource {
    const joined = try std.fs.path.join(gpa, &.{ checkout, path });
    defer gpa.free(joined);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, joined, gpa, .limited(max_source_bytes));
    errdefer gpa.free(bytes);
    const actual = digestHex(bytes);
    if (!std.mem.eql(u8, &actual, expected_sha256)) {
        std.debug.print("independent-suite runner: {s} SHA-256 drift: expected {s}, got {s}\n", .{ path, expected_sha256, actual });
        return error.SourceChecksumMismatch;
    }
    return .{ .path = path, .sha256 = expected_sha256, .bytes = bytes };
}

fn nativeState(self: *js.Interpreter) ?*AdapterState {
    const native = self.active_native orelse return null;
    return @ptrCast(@alignCast(native.private_data orelse return null));
}

fn loadNative(raw: *anyopaque, _: js.Value, args: []const js.Value) js.HostError!js.Value {
    const self: *js.Interpreter = @ptrCast(@alignCast(raw));
    const state = nativeState(self) orelse return self.throwError("InternalError", "load adapter state is unavailable");
    if (args.len != 1 or !args[0].isString()) return self.throwError("TypeError", "load requires one string path");
    if (state.load_index >= state.sources.len) {
        state.recordFailure("unexpected extra load('{s}')", .{args[0].asStr()}) catch return error.OutOfMemory;
        return self.throwError("Error", "independent-suite load set is exhausted");
    }
    const source = state.sources[state.load_index];
    if (!std.mem.eql(u8, args[0].asStr(), source.path)) {
        state.recordFailure("load order/path mismatch: expected '{s}', got '{s}'", .{ source.path, args[0].asStr() }) catch return error.OutOfMemory;
        return self.throwError("Error", "independent-suite load path is not pinned");
    }
    state.load_index += 1;

    const context = state.context orelse return self.throwError("InternalError", "load context is unavailable");
    _ = context.evaluate(source.bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Throw => return error.Throw,
        else => return self.throwError("SyntaxError", @errorName(err)),
    };
    return js.Value.undef();
}

fn copyArguments(state: *AdapterState, self: *js.Interpreter, args: []const js.Value) js.HostError![]const []const u8 {
    const copied = state.gpa.alloc([]const u8, args.len) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (copied[0..initialized]) |argument| state.gpa.free(argument);
        state.gpa.free(copied);
    }
    for (args, 0..) |argument, index| {
        const text = try self.toStringV(argument);
        copied[index] = state.gpa.dupe(u8, text) catch return error.OutOfMemory;
        initialized += 1;
    }
    return copied;
}

fn printNative(raw: *anyopaque, _: js.Value, args: []const js.Value) js.HostError!js.Value {
    const self: *js.Interpreter = @ptrCast(@alignCast(raw));
    const state = nativeState(self) orelse return self.throwError("InternalError", "print adapter state is unavailable");
    const copied = try copyArguments(state, self, args);
    if (copied.len > 0 and std.mem.eql(u8, copied[0], protocol_marker)) {
        if (copied.len != 4) {
            try state.recordFailure("malformed result-capture print with {d} arguments", .{copied.len});
            for (copied) |argument| state.gpa.free(argument);
            state.gpa.free(copied);
            return self.throwError("Error", "malformed independent-suite result capture");
        }
        const kind = std.meta.stringToEnum(EventKind, copied[1]) orelse {
            try state.recordFailure("unknown result-capture kind '{s}'", .{copied[1]});
            for (copied) |argument| state.gpa.free(argument);
            state.gpa.free(copied);
            return self.throwError("Error", "unknown independent-suite result kind");
        };
        const name = copied[2];
        const event_value = copied[3];
        state.gpa.free(copied[0]);
        state.gpa.free(copied[1]);
        state.gpa.free(copied);
        state.events.append(state.gpa, .{ .kind = kind, .name = name, .value = event_value }) catch {
            state.gpa.free(name);
            state.gpa.free(event_value);
            return error.OutOfMemory;
        };
    } else {
        state.auxiliary.append(state.gpa, .{ .arguments = copied }) catch {
            for (copied) |argument| state.gpa.free(argument);
            state.gpa.free(copied);
            return error.OutOfMemory;
        };
    }
    return js.Value.undef();
}

fn defineNative(ctx: *js.Context, name: []const u8, function: js.NativeFn, state: *AdapterState) !void {
    const saved = js.gc.setActiveContext(ctx);
    defer js.gc.restoreActiveContext(saved);
    const object = try js.gc.allocObj(ctx.arena());
    object.* = .{ .native = function, .private_data = @ptrCast(state) };
    const function_value = js.Value.obj(object);
    try ctx.env.put(name, function_value);
    const global = ctx.env.get("globalThis") orelse return error.InvalidGlobalObject;
    if (!global.isObject()) return error.InvalidGlobalObject;
    try global.asObj().setOwn(ctx.arena(), ctx.root_shape, name, function_value);
}

fn driverSource(gpa: std.mem.Allocator, row: RowSpec) ![]u8 {
    _ = row;
    return std.fmt.allocPrint(gpa,
        \\BenchmarkSuite.RunSuites({{
        \\  NotifyResult: function(name, result) {{ print("{s}", "result", name, result); }},
        \\  NotifyError: function(name, error) {{
        \\    var detail = String(error);
        \\    try {{ if (error && typeof error.stack === "string") detail = error.stack; }} catch (_) {{}}
        \\    print("{s}", "error", name, detail);
        \\  }},
        \\  NotifyScore: function(score) {{ print("{s}", "score", "selected-geometric-aggregate", score); }}
        \\}});
    , .{ protocol_marker, protocol_marker, protocol_marker });
}

fn timevalNs(value: std.c.timeval) u64 {
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(value.usec)) * std.time.ns_per_us;
}

fn processSnapshot() ProcessSnapshot {
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    const rss_scale: u64 = if (builtin.os.tag == .linux) 1024 else 1;
    return .{
        .cpu_user_ns = timevalNs(usage.utime),
        .cpu_system_ns = timevalNs(usage.stime),
        .peak_rss_bytes = @as(u64, @intCast(usage.maxrss)) * rss_scale,
    };
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

const PauseAggregate = struct { total: u64, max: u64 };

fn pauseSummary(samples: anytype) PauseAggregate {
    var result = PauseAggregate{ .total = 0, .max = 0 };
    for (samples.values[0..samples.len]) |sample| {
        result.total += sample;
        result.max = @max(result.max, sample);
    }
    return result;
}

fn validateOutputs(gpa: std.mem.Allocator, state: *AdapterState, row: RowSpec) !struct { valid: bool, observed: []const []const u8, score_count: usize } {
    var observed: std.ArrayList([]const u8) = .empty;
    errdefer observed.deinit(gpa);
    var score_count: usize = 0;
    var result_index: usize = 0;
    var valid = state.failure == null and state.load_index == state.sources.len;
    if (state.load_index != state.sources.len) try state.recordFailure("adapter loaded {d} of {d} pinned sources", .{ state.load_index, state.sources.len });

    for (state.events.items) |event| switch (event.kind) {
        .@"error" => {
            valid = false;
            try state.recordFailure("upstream row '{s}' failed: {s}", .{ event.name, event.value });
        },
        .score => {
            score_count += 1;
            const score = std.fmt.parseFloat(f64, event.value) catch {
                valid = false;
                continue;
            };
            if (!std.math.isFinite(score) or score <= 0) valid = false;
        },
        .result => {
            try observed.append(gpa, event.name);
            if (result_index >= row.result_names.len or !std.mem.eql(u8, event.name, row.result_names[result_index])) valid = false;
            const score = std.fmt.parseFloat(f64, event.value) catch {
                valid = false;
                result_index += 1;
                continue;
            };
            if (!std.math.isFinite(score) or score <= 0) valid = false;
            result_index += 1;
        },
    };
    if (result_index != row.result_names.len or score_count != 1) valid = false;
    if (!valid and state.failure == null) try state.recordFailure(
        "output contract mismatch: expected {d} ordered results and one score, observed {d} results and {d} scores",
        .{ row.result_names.len, result_index, score_count },
    );
    return .{ .valid = valid, .observed = try observed.toOwnedSlice(gpa), .score_count = score_count };
}

fn exceptionText(gpa: std.mem.Allocator, ctx: *js.Context, err: anyerror) ![]u8 {
    var name: []const u8 = @errorName(err);
    var message: []const u8 = "";
    if (ctx.exception) |exception| {
        if (exception.isObject()) {
            const object = exception.asObj();
            if (object.errorName().len != 0) name = object.errorName();
            if (object.getOwn("name")) |value| {
                if (value.isString()) name = value.asStr();
            }
            if (object.getOwn("message")) |value| {
                if (value.isString()) message = value.asStr();
            }
        } else if (exception.isString()) {
            name = "ThrownString";
            message = exception.asStr();
        }
    }
    return std.fmt.allocPrint(gpa, "{s}: {s}", .{ name, message });
}

fn executableIdentity(gpa: std.mem.Allocator, io: std.Io) !struct { path: []u8, sha256: []u8 } {
    const path = try std.process.executablePathAlloc(io, gpa);
    errdefer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    const digest = digestHex(bytes);
    return .{ .path = path, .sha256 = try gpa.dupe(u8, &digest) };
}

fn sourceRevision(value: []const u8) ?[]const u8 {
    if (value.len != 40) return null;
    for (value) |byte| if (!std.ascii.isHex(byte)) return null;
    return value;
}

fn trimLine(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn runGit(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const completed = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .expand_arg0 = .expand,
    });
    defer gpa.free(completed.stderr);
    switch (completed.term) {
        .exited => |code| if (code != 0) {
            defer gpa.free(completed.stdout);
            std.debug.print("independent-suite runner: git command failed ({d}): {s}\n", .{ code, trimLine(completed.stderr) });
            return error.SourceIdentityUnavailable;
        },
        else => {
            defer gpa.free(completed.stdout);
            return error.SourceIdentityUnavailable;
        },
    }
    return completed.stdout;
}

fn verifySourceIdentity(gpa: std.mem.Allocator, io: std.Io, revision: []const u8) !void {
    if (sourceRevision(revision) == null) return error.InvalidSourceRevision;
    const head_raw = try runGit(gpa, io, &.{ "git", "rev-parse", "HEAD" });
    defer gpa.free(head_raw);
    if (!std.mem.eql(u8, trimLine(head_raw), revision)) {
        std.debug.print("independent-suite runner: source revision mismatch: expected HEAD {s}, got {s}\n", .{ revision, trimLine(head_raw) });
        return error.SourceRevisionMismatch;
    }
    const status_raw = try runGit(gpa, io, &.{ "git", "status", "--porcelain=v1", "--untracked-files=all" });
    defer gpa.free(status_raw);
    if (trimLine(status_raw).len != 0) {
        std.debug.print("independent-suite runner: zig-js worktree is dirty: {s}\n", .{trimLine(status_raw)});
        return error.DirtySourceWorktree;
    }
}

fn verifyEnvironment(environ: *std.process.Environ.Map) !void {
    const required = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "TZ", .value = "UTC" },
        .{ .name = "LC_ALL", .value = "C" },
        .{ .name = "LANG", .value = "C" },
    };
    for (required) |entry| {
        const actual = environ.get(entry.name) orelse {
            std.debug.print("independent-suite runner: required environment {s}={s} is unset\n", .{ entry.name, entry.value });
            return error.EnvironmentMismatch;
        };
        if (!std.mem.eql(u8, actual, entry.value)) {
            std.debug.print("independent-suite runner: required environment {s}={s}, got {s}\n", .{ entry.name, entry.value, actual });
            return error.EnvironmentMismatch;
        }
    }
}

fn runSample(
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    row: RowSpec,
    sources: [2]LoadedSource,
    own_sources: bool,
    mode: RunMode,
    revision: []const u8,
    argv: []const []const u8,
) !bool {
    var state = AdapterState{ .gpa = gpa, .sources = sources };
    defer state.deinit(own_sources);
    const driver = try driverSource(gpa, row);
    defer gpa.free(driver);
    const identity = try executableIdentity(gpa, io);
    defer gpa.free(identity.path);
    defer gpa.free(identity.sha256);

    const before = processSnapshot();
    const started = nowNs(io);
    // The pinned rows are finite, while the product default is an embedder
    // runaway guard. The collector owns termination for this isolated harness
    // with a per-process timeout, uniformly across rows and modes.
    const ctx = try js.Context.createWithTestingOptions(std.heap.c_allocator, .{
        .enable_gc = true,
        .profile_execution_tiers = mode == .attribution,
        .step_budget = std.math.maxInt(u64),
    });
    defer ctx.destroy();
    state.context = ctx;
    try defineNative(ctx, "load", loadNative, &state);
    try defineNative(ctx, "print", printNative, &state);
    var evaluation_ok = true;
    for (sources) |source| {
        const statement = try std.fmt.allocPrint(gpa, "load(\"{s}\");", .{source.path});
        defer gpa.free(statement);
        if (ctx.evaluate(statement)) |_| {} else |err| {
            evaluation_ok = false;
            if (state.failure == null) state.failure = try exceptionText(gpa, ctx, err);
            break;
        }
    }
    if (evaluation_ok) {
        if (ctx.evaluate(driver)) |_| {} else |err| {
            if (state.failure == null) state.failure = try exceptionText(gpa, ctx, err);
        }
    }
    const elapsed: u64 = @intCast(nowNs(io) - started);
    const after = processSnapshot();
    const snapshot = ctx.tierAttributionSnapshot();
    const minor = pauseSummary(snapshot.runtime.minor_pauses);
    const full = pauseSummary(snapshot.runtime.full_pauses);
    const validation = try validateOutputs(gpa, &state, row);
    defer gpa.free(validation.observed);

    var execution: [std.meta.fieldNames(js.ExecutionTierMetric).len]NamedCounter = undefined;
    inline for (std.meta.fieldNames(js.ExecutionTierMetric), std.meta.tags(js.ExecutionTierMetric), 0..) |name, metric, index|
        execution[index] = .{ .name = name, .value = snapshot.execution.count(metric) };
    var admissions: [std.meta.fieldNames(js.BytecodeAdmissionReason).len]NamedCounter = undefined;
    inline for (std.meta.fieldNames(js.BytecodeAdmissionReason), std.meta.tags(js.BytecodeAdmissionReason), 0..) |name, reason, index|
        admissions[index] = .{ .name = name, .value = snapshot.admissions.count(reason) };

    const loaded_sources = [_]SourceIdentity{
        .{ .path = sources[0].path, .sha256 = sources[0].sha256 },
        .{ .path = sources[1].path, .sha256 = sources[1].sha256 },
    };
    const raw_samples = [_]RawSample{.{
        .index = 0,
        .mode = mode,
        .instrumentation_enabled = mode == .attribution,
        .outer_wall_ns = elapsed,
        .cpu_user_ns = after.cpu_user_ns -| before.cpu_user_ns,
        .cpu_system_ns = after.cpu_system_ns -| before.cpu_system_ns,
        .peak_rss_bytes_before = before.peak_rss_bytes,
        .peak_rss_bytes_after = after.peak_rss_bytes,
    }};
    const environment = [_][]const u8{
        "TZ=UTC",
        "LC_ALL=C",
        "LANG=C",
        "network=forbidden",
    };
    const allocation = snapshot.runtime.allocation;
    const report = Report{
        .row = row.id,
        .licenses = row.licenses,
        .mode = mode,
        .engine = .{
            .executable_path = identity.path,
            .executable_sha256 = identity.sha256,
            .source_revision = sourceRevision(revision),
            .argv = argv,
            .environment = &environment,
        },
        .adapter = .{ .loaded_sources = &loaded_sources },
        .status = if (validation.valid) "passed" else "failed",
        .failure = state.failure,
        .upstream_outputs = state.events.items,
        .auxiliary_outputs = state.auxiliary.items,
        .raw_samples = &raw_samples,
        .validated_output = .{
            .status = if (validation.valid) "passed" else "failed",
            .expected_result_names = row.result_names,
            .observed_result_names = validation.observed,
            .final_score_count = validation.score_count,
        },
        .tier_attribution = .{
            .status = if (mode == .attribution) "measured" else "not_measured_scored_path",
            .execution = if (mode == .attribution) &execution else &.{},
            .admissions = &admissions,
            .timing = if (mode == .attribution) snapshot.timing else null,
            .baseline_publications = if (mode == .attribution) snapshot.baseline_publications else null,
            .optimizer_publications = if (mode == .attribution) snapshot.optimizer_publications else null,
            .generated_code_bytes = if (mode == .attribution) snapshot.generated_code_bytes else null,
        },
        .gc = .{
            .enabled = true,
            .attribution_status = if (mode == .attribution) "measured" else "not_measured_scored_path",
            .live_bytes = snapshot.heap.live_bytes,
            .last_full_collection_bytes = snapshot.heap.last_full_collection_bytes,
            .collections = snapshot.heap.collections,
            .full_collections = snapshot.heap.full_collections,
            .backing_allocations = if (mode == .attribution) allocation.backing_allocations else null,
            .backing_allocation_bytes = if (mode == .attribution) allocation.backing_allocation_bytes else null,
            .backing_peak_bytes = if (mode == .attribution) allocation.backing_peak_bytes else null,
            .gc_cell_allocations = if (mode == .attribution) allocation.gc_cell_allocations else null,
            .gc_cell_bytes = if (mode == .attribution) allocation.gc_cell_bytes else null,
            .minor_pause_count = if (mode == .attribution) snapshot.runtime.minor_pauses.len else null,
            .minor_pause_overflow = if (mode == .attribution) snapshot.runtime.minor_pauses.overflow else null,
            .minor_pause_ns_total = if (mode == .attribution) minor.total else null,
            .minor_pause_ns_max = if (mode == .attribution) minor.max else null,
            .full_pause_count = if (mode == .attribution) snapshot.runtime.full_pauses.len else null,
            .full_pause_overflow = if (mode == .attribution) snapshot.runtime.full_pauses.overflow else null,
            .full_pause_ns_total = if (mode == .attribution) full.total else null,
            .full_pause_ns_max = if (mode == .attribution) full.max else null,
        },
    };
    const json = try std.json.Stringify.valueAlloc(gpa, report, .{});
    defer gpa.free(json);
    try writer.writeAll(json);
    try writer.writeByte('\n');
    return validation.valid;
}

fn selfTest(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, argv: []const []const u8) !bool {
    const fixture_row = RowSpec{
        .id = "adapter_self_test",
        .path = "fixture.js",
        .sha256 = "self-test",
        .licenses = &.{"repository-owned"},
        .result_names = &.{"Fixture"},
    };
    const fixture_base =
        \\var BenchmarkSuite = {
        \\  RunSuites: function(runner) {
        \\    runner.NotifyResult("Fixture", "123");
        \\    runner.NotifyScore("456");
        \\  }
        \\};
    ;
    const fixture_workload = "var fixtureWorkloadBytesAreUnchanged = 1;";
    const sources = [2]LoadedSource{
        .{ .path = base_path, .sha256 = "self-test", .bytes = fixture_base },
        .{ .path = fixture_row.path, .sha256 = "self-test", .bytes = fixture_workload },
    };
    const scored = try runSample(gpa, io, writer, fixture_row, sources, false, .score, "self-test", argv);
    const attributed = try runSample(gpa, io, writer, fixture_row, sources, false, .attribution, "self-test", argv);
    return scored and attributed;
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--self-test")) {
        var discard_buffer: [4096]u8 = undefined;
        var discarding = std.Io.Writer.Discarding.init(&discard_buffer);
        const valid = try selfTest(init.gpa, init.io, &discarding.writer, argv);
        try stdout.writeAll("independent-suite zig-js adapter self-test: score and attribution modes passed\n");
        try stdout.flush();
        if (!valid) std.process.exit(1);
        return;
    }
    if (argv.len != 5) {
        std.debug.print("usage: independent-suite-zig-js <verified-octane-checkout> <row> <score|attribution> <zig-js-revision>\nrows: richards, regexp, splay, navier_stokes, box2d\n", .{});
        std.process.exit(2);
    }
    const row = rowById(argv[2]) orelse {
        std.debug.print("independent-suite runner: unknown or excluded row '{s}'\n", .{argv[2]});
        std.process.exit(2);
    };
    const mode = std.meta.stringToEnum(RunMode, argv[3]) orelse {
        std.debug.print("independent-suite runner: unknown mode '{s}'\n", .{argv[3]});
        std.process.exit(2);
    };
    try verifyEnvironment(init.environ_map);
    try verifySourceIdentity(init.gpa, init.io, argv[4]);
    const checkout = try std.Io.Dir.cwd().realPathFileAlloc(init.io, argv[1], init.gpa);
    defer init.gpa.free(checkout);
    var sources_handed_off = false;
    const base = try readPinnedSource(init.gpa, init.io, checkout, base_path, base_sha256);
    errdefer if (!sources_handed_off) init.gpa.free(base.bytes);
    const workload = try readPinnedSource(init.gpa, init.io, checkout, row.path, row.sha256);
    errdefer if (!sources_handed_off) init.gpa.free(workload.bytes);
    const sources = [2]LoadedSource{ base, workload };
    // `runSample` owns both buffers from this point, including on error.
    sources_handed_off = true;
    const valid = try runSample(init.gpa, init.io, stdout, row.*, sources, true, mode, argv[4], argv);
    try stdout.flush();
    if (!valid) std.process.exit(1);
}
