//! Minimal system-JavaScriptCore shell adapter for the pinned Octane subset (#504).
//!
//! This executable links only the platform JavaScriptCore framework. It shares
//! the frozen source/result inventory with the zig-js adapter but owns its host
//! callbacks and result capture, so zig-js's JSC-shaped exports cannot interpose.

const std = @import("std");
const builtin = @import("builtin");
const octane = @import("independent_suite_octane.zig");

const max_source_bytes = 32 * 1024 * 1024;
const JSGlobalContextRef = ?*anyopaque;
const JSContextRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSObjectCallAsFunctionCallback = *const fn (
    JSContextRef,
    JSObjectRef,
    JSObjectRef,
    usize,
    [*c]const JSValueRef,
    [*c]JSValueRef,
) callconv(.c) JSValueRef;

extern fn JSGlobalContextCreate(global_object_class: ?*anyopaque) callconv(.c) JSGlobalContextRef;
extern fn JSGlobalContextRelease(ctx: JSGlobalContextRef) callconv(.c) void;
extern fn JSContextGetGlobalObject(ctx: JSContextRef) callconv(.c) JSObjectRef;
extern fn JSStringCreateWithUTF8CString(string: [*:0]const u8) callconv(.c) JSStringRef;
extern fn JSStringGetMaximumUTF8CStringSize(string: JSStringRef) callconv(.c) usize;
extern fn JSStringGetUTF8CString(string: JSStringRef, buffer: [*]u8, buffer_size: usize) callconv(.c) usize;
extern fn JSStringRelease(string: JSStringRef) callconv(.c) void;
extern fn JSValueIsString(ctx: JSContextRef, value: JSValueRef) callconv(.c) bool;
extern fn JSValueMakeUndefined(ctx: JSContextRef) callconv(.c) JSValueRef;
extern fn JSValueMakeString(ctx: JSContextRef, string: JSStringRef) callconv(.c) JSValueRef;
extern fn JSValueToStringCopy(ctx: JSContextRef, value: JSValueRef, exception: [*c]JSValueRef) callconv(.c) JSStringRef;
extern fn JSObjectMakeFunctionWithCallback(ctx: JSContextRef, name: JSStringRef, callback: JSObjectCallAsFunctionCallback) callconv(.c) JSObjectRef;
extern fn JSObjectSetProperty(ctx: JSContextRef, object: JSObjectRef, property_name: JSStringRef, value: JSValueRef, attributes: c_uint, exception: [*c]JSValueRef) callconv(.c) void;
extern fn JSEvaluateScript(
    ctx: JSContextRef,
    script: JSStringRef,
    this_object: JSObjectRef,
    source_url: JSStringRef,
    starting_line_number: c_int,
    exception: [*c]JSValueRef,
) callconv(.c) JSValueRef;

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

threadlocal var active_state: ?*AdapterState = null;

const ProcessSnapshot = struct {
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    peak_rss_bytes: u64,
};

const RawSample = struct {
    index: usize = 0,
    mode: []const u8 = "score",
    instrumentation_enabled: bool = false,
    outer_wall_ns: u64,
    cpu_user_ns: u64,
    cpu_system_ns: u64,
    peak_rss_bytes_before: u64,
    peak_rss_bytes_after: u64,
};

const Validation = struct {
    status: []const u8,
    expected_result_names: []const []const u8,
    observed_result_names: []const []const u8,
    final_score_count: usize,
};

const FrameworkIdentity = struct {
    bundle_path: []const u8 = "/System/Library/Frameworks/JavaScriptCore.framework",
    bundle_version: []const u8,
    os_build: []const u8,
    binary_status: []const u8 = "dyld_shared_cache",
    binary_path: ?[]const u8 = null,
    binary_sha256: ?[]const u8 = null,
    binary_boundary: []const u8 = "The current macOS system framework has no standalone JavaScriptCore image; executable framework code is supplied by the OS dyld shared cache and is pinned by OS build plus bundle version.",
};

const EngineIdentity = struct {
    id: []const u8 = "system-jsc",
    executable_path: []const u8,
    executable_sha256: []const u8,
    executable_role: []const u8 = "isolated adapter process linked only to the platform JavaScriptCore framework",
    version_output: []const u8,
    framework_version: []const u8,
    framework: FrameworkIdentity,
    adapter_source_revision: []const u8,
    argv: []const []const u8,
    environment: []const []const u8,
    separate_process: bool = true,
};

const Report = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "system-jsc-independent-suite-sample",
    suite: []const u8 = "octane-2-retired",
    suite_revision: []const u8 = "570ad1ccfe86e3eecba0636c8f932ac08edec517",
    suite_tree: []const u8 = "e40d5c8489d05e384f32ed064d1f5286e9c236f3",
    row: []const u8,
    licenses: []const []const u8,
    mode: []const u8 = "score",
    publication_status: []const u8 = "diagnostic_single_sample",
    engine: EngineIdentity,
    adapter: struct {
        id: []const u8 = "system-jsc-octane-minimal-shell-v1",
        host_globals: []const []const u8 = &.{ "load", "print" },
        source_transform: bool = false,
        loaded_sources: []const SourceIdentity,
    },
    status: []const u8,
    failure: ?[]const u8,
    skip_reason: ?[]const u8 = null,
    upstream_outputs: []const ProtocolEvent,
    auxiliary_outputs: []const AuxiliaryOutput,
    raw_samples: []const RawSample,
    dispersion: struct {
        status: []const u8 = "not_applicable_single_sample",
        sample_count: usize = 1,
        statistic: ?f64 = null,
    } = .{},
    validated_output: Validation,
    timed_boundary: struct {
        upstream: []const u8 = "Pinned Octane BenchmarkSuite.RunSingleBenchmark boundary: setup and teardown excluded; warmup unscored; each measurement runs for at least one second or the pinned minimum iteration count.",
        outer: []const u8 = "From immediately before system JSC JSGlobalContext creation through completion of the owned RunSuites driver; checkout verification, file reads, SHA-256 validation, JSON serialization, and context release are excluded.",
    } = .{},
    tier_attribution: struct {
        status: []const u8 = "unavailable_public_api",
        reason: []const u8 = "The system JavaScriptCore public C API exposes no exact per-context tier, compilation, deoptimization, or generated-code counters.",
    } = .{},
    gc: struct {
        status: []const u8 = "unavailable_public_api",
        reason: []const u8 = "The system JavaScriptCore public C API exposes no exact per-context allocation, heap, collection, or pause counters.",
    } = .{},
};

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
        std.debug.print("independent-suite JSC runner: {s} SHA-256 drift: expected {s}, got {s}\n", .{ path, expected_sha256, actual });
        return error.SourceChecksumMismatch;
    }
    return .{ .path = path, .sha256 = expected_sha256, .bytes = bytes };
}

fn makeString(gpa: std.mem.Allocator, bytes: []const u8) !JSStringRef {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNullSource;
    const sentinel = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(sentinel, bytes);
    defer gpa.free(sentinel);
    return JSStringCreateWithUTF8CString(sentinel.ptr) orelse error.JavaScriptCoreFailure;
}

fn copyValueString(gpa: std.mem.Allocator, ctx: JSContextRef, value: JSValueRef) ![]u8 {
    var exception: JSValueRef = null;
    const string = JSValueToStringCopy(ctx, value, &exception) orelse return error.JavaScriptCoreFailure;
    defer JSStringRelease(string);
    if (exception != null) return error.JavaScriptException;
    const capacity = JSStringGetMaximumUTF8CStringSize(string);
    const buffer = try gpa.alloc(u8, capacity);
    errdefer gpa.free(buffer);
    const written = JSStringGetUTF8CString(string, buffer.ptr, buffer.len);
    if (written == 0) return error.JavaScriptCoreFailure;
    return gpa.realloc(buffer, written - 1);
}

fn evaluate(gpa: std.mem.Allocator, ctx: JSContextRef, source: []const u8) !struct { value: JSValueRef, exception: JSValueRef } {
    const script = try makeString(gpa, source);
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const value = JSEvaluateScript(ctx, script, null, null, 1, &exception);
    return .{ .value = value, .exception = exception };
}

fn setAdapterException(gpa: std.mem.Allocator, ctx: JSContextRef, exception: [*c]JSValueRef, message: []const u8) void {
    if (exception == null) return;
    const string = makeString(gpa, message) catch return;
    defer JSStringRelease(string);
    exception[0] = JSValueMakeString(ctx, string);
}

fn loadCallback(
    ctx: JSContextRef,
    _: JSObjectRef,
    _: JSObjectRef,
    argument_count: usize,
    arguments: [*c]const JSValueRef,
    exception: [*c]JSValueRef,
) callconv(.c) JSValueRef {
    const state = active_state orelse return JSValueMakeUndefined(ctx);
    if (argument_count != 1 or !JSValueIsString(ctx, arguments[0])) {
        state.recordFailure("load requires one string path", .{}) catch {};
        setAdapterException(state.gpa, ctx, exception, "independent-suite load requires one string path");
        return JSValueMakeUndefined(ctx);
    }
    const path = copyValueString(state.gpa, ctx, arguments[0]) catch {
        state.recordFailure("load path conversion failed", .{}) catch {};
        setAdapterException(state.gpa, ctx, exception, "independent-suite load path conversion failed");
        return JSValueMakeUndefined(ctx);
    };
    defer state.gpa.free(path);
    if (state.load_index >= state.sources.len) {
        state.recordFailure("unexpected extra load('{s}')", .{path}) catch {};
        setAdapterException(state.gpa, ctx, exception, "independent-suite load set is exhausted");
        return JSValueMakeUndefined(ctx);
    }
    const source = state.sources[state.load_index];
    if (!std.mem.eql(u8, path, source.path)) {
        state.recordFailure("load order/path mismatch: expected '{s}', got '{s}'", .{ source.path, path }) catch {};
        setAdapterException(state.gpa, ctx, exception, "independent-suite load path is not pinned");
        return JSValueMakeUndefined(ctx);
    }
    state.load_index += 1;
    const result = evaluate(state.gpa, ctx, source.bytes) catch {
        state.recordFailure("cannot evaluate pinned source '{s}'", .{source.path}) catch {};
        setAdapterException(state.gpa, ctx, exception, "cannot evaluate pinned independent-suite source");
        return JSValueMakeUndefined(ctx);
    };
    if (result.exception) |js_exception| {
        const text = copyValueString(state.gpa, ctx, js_exception) catch state.gpa.dupe(u8, "JavaScript exception") catch null;
        if (text) |owned| {
            defer state.gpa.free(owned);
            state.recordFailure("{s}", .{owned}) catch {};
        } else state.recordFailure("JavaScript exception", .{}) catch {};
        if (exception != null) exception[0] = js_exception;
    }
    return JSValueMakeUndefined(ctx);
}

fn printCallback(
    ctx: JSContextRef,
    _: JSObjectRef,
    _: JSObjectRef,
    argument_count: usize,
    arguments: [*c]const JSValueRef,
    exception: [*c]JSValueRef,
) callconv(.c) JSValueRef {
    const state = active_state orelse return JSValueMakeUndefined(ctx);
    const copied = state.gpa.alloc([]const u8, argument_count) catch return JSValueMakeUndefined(ctx);
    var initialized: usize = 0;
    while (initialized < argument_count) : (initialized += 1) {
        copied[initialized] = copyValueString(state.gpa, ctx, arguments[initialized]) catch {
            for (copied[0..initialized]) |argument| state.gpa.free(argument);
            state.gpa.free(copied);
            state.recordFailure("print argument conversion failed", .{}) catch {};
            setAdapterException(state.gpa, ctx, exception, "independent-suite print conversion failed");
            return JSValueMakeUndefined(ctx);
        };
    }
    if (copied.len > 0 and std.mem.eql(u8, copied[0], octane.protocol_marker)) {
        if (copied.len != 4) {
            state.recordFailure("malformed result-capture print with {d} arguments", .{copied.len}) catch {};
            for (copied) |argument| state.gpa.free(argument);
            state.gpa.free(copied);
            setAdapterException(state.gpa, ctx, exception, "malformed independent-suite result capture");
            return JSValueMakeUndefined(ctx);
        }
        const kind = std.meta.stringToEnum(EventKind, copied[1]) orelse {
            state.recordFailure("unknown result-capture kind '{s}'", .{copied[1]}) catch {};
            for (copied) |argument| state.gpa.free(argument);
            state.gpa.free(copied);
            setAdapterException(state.gpa, ctx, exception, "unknown independent-suite result kind");
            return JSValueMakeUndefined(ctx);
        };
        const name = copied[2];
        const value = copied[3];
        state.gpa.free(copied[0]);
        state.gpa.free(copied[1]);
        state.gpa.free(copied);
        state.events.append(state.gpa, .{ .kind = kind, .name = name, .value = value }) catch {
            state.gpa.free(name);
            state.gpa.free(value);
            return JSValueMakeUndefined(ctx);
        };
    } else state.auxiliary.append(state.gpa, .{ .arguments = copied }) catch {
        for (copied) |argument| state.gpa.free(argument);
        state.gpa.free(copied);
    };
    return JSValueMakeUndefined(ctx);
}

fn defineFunction(gpa: std.mem.Allocator, ctx: JSContextRef, name: []const u8, callback: JSObjectCallAsFunctionCallback) !void {
    const js_name = try makeString(gpa, name);
    defer JSStringRelease(js_name);
    const function = JSObjectMakeFunctionWithCallback(ctx, js_name, callback) orelse return error.JavaScriptCoreFailure;
    var exception: JSValueRef = null;
    JSObjectSetProperty(ctx, JSContextGetGlobalObject(ctx), js_name, function, 0, &exception);
    if (exception != null) return error.JavaScriptException;
}

fn driverSource(gpa: std.mem.Allocator) ![]u8 {
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
    , .{ octane.protocol_marker, octane.protocol_marker, octane.protocol_marker });
}

fn validateOutputs(gpa: std.mem.Allocator, state: *AdapterState, row: octane.RowSpec) !struct { valid: bool, observed: []const []const u8, score_count: usize } {
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

fn timevalNs(value: std.c.timeval) u64 {
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.usec)) * std.time.ns_per_us;
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

fn executableIdentity(gpa: std.mem.Allocator, io: std.Io) !struct { path: []u8, sha256: []u8 } {
    const path = try std.process.executablePathAlloc(io, gpa);
    errdefer gpa.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    const digest = digestHex(bytes);
    return .{ .path = path, .sha256 = try gpa.dupe(u8, &digest) };
}

fn trimLine(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn runCommand(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
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
            return error.IdentityCommandFailed;
        },
        else => {
            defer gpa.free(completed.stdout);
            return error.IdentityCommandFailed;
        },
    }
    return completed.stdout;
}

fn verifySourceIdentity(gpa: std.mem.Allocator, io: std.Io, revision: []const u8) !void {
    if (revision.len != 40) return error.InvalidSourceRevision;
    for (revision) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSourceRevision;
    const head_raw = try runCommand(gpa, io, &.{ "git", "rev-parse", "HEAD" });
    defer gpa.free(head_raw);
    if (!std.mem.eql(u8, trimLine(head_raw), revision)) return error.SourceRevisionMismatch;
    const status_raw = try runCommand(gpa, io, &.{ "git", "status", "--porcelain=v1", "--untracked-files=all" });
    defer gpa.free(status_raw);
    if (trimLine(status_raw).len != 0) return error.DirtySourceWorktree;
}

fn verifyEnvironment(environ: *std.process.Environ.Map) !void {
    for ([_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "TZ", .value = "UTC" },
        .{ .name = "LC_ALL", .value = "C" },
        .{ .name = "LANG", .value = "C" },
    }) |entry| if (!std.mem.eql(u8, environ.get(entry.name) orelse return error.EnvironmentMismatch, entry.value)) return error.EnvironmentMismatch;
}

fn frameworkIdentity(gpa: std.mem.Allocator, io: std.Io) !struct { version: []u8, os_build: []u8, output: []u8 } {
    const version_raw = try runCommand(gpa, io, &.{ "/usr/bin/plutil", "-extract", "CFBundleVersion", "raw", "/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist" });
    defer gpa.free(version_raw);
    const build_raw = try runCommand(gpa, io, &.{ "/usr/bin/sw_vers", "-buildVersion" });
    defer gpa.free(build_raw);
    const version = try gpa.dupe(u8, trimLine(version_raw));
    errdefer gpa.free(version);
    const os_build = try gpa.dupe(u8, trimLine(build_raw));
    errdefer gpa.free(os_build);
    return .{
        .version = version,
        .os_build = os_build,
        .output = try std.fmt.allocPrint(gpa, "system JavaScriptCore framework {s}; macOS build {s}; dyld shared cache", .{ version, os_build }),
    };
}

fn runSample(
    gpa: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    row: octane.RowSpec,
    sources: [2]LoadedSource,
    own_sources: bool,
    revision: []const u8,
    argv: []const []const u8,
) !bool {
    var state = AdapterState{ .gpa = gpa, .sources = sources };
    defer state.deinit(own_sources);
    const driver = try driverSource(gpa);
    defer gpa.free(driver);
    const identity = try executableIdentity(gpa, io);
    defer gpa.free(identity.path);
    defer gpa.free(identity.sha256);
    const framework = try frameworkIdentity(gpa, io);
    defer gpa.free(framework.version);
    defer gpa.free(framework.os_build);
    defer gpa.free(framework.output);

    const before = processSnapshot();
    const started = nowNs(io);
    const ctx = JSGlobalContextCreate(null) orelse return error.JavaScriptCoreFailure;
    defer JSGlobalContextRelease(ctx);
    active_state = &state;
    defer active_state = null;
    try defineFunction(gpa, ctx, "load", loadCallback);
    try defineFunction(gpa, ctx, "print", printCallback);
    for (sources) |source| {
        const statement = try std.fmt.allocPrint(gpa, "load(\"{s}\");", .{source.path});
        defer gpa.free(statement);
        const result = try evaluate(gpa, ctx, statement);
        if (result.exception) |exception| {
            if (state.failure == null) state.failure = copyValueString(gpa, ctx, exception) catch try gpa.dupe(u8, "JavaScript exception");
            break;
        }
    }
    if (state.failure == null) {
        const result = try evaluate(gpa, ctx, driver);
        if (result.exception) |exception| state.failure = copyValueString(gpa, ctx, exception) catch try gpa.dupe(u8, "JavaScript exception");
    }
    const elapsed: u64 = @intCast(nowNs(io) - started);
    const after = processSnapshot();
    const validation = try validateOutputs(gpa, &state, row);
    defer gpa.free(validation.observed);

    const loaded_sources = [_]SourceIdentity{
        .{ .path = sources[0].path, .sha256 = sources[0].sha256 },
        .{ .path = sources[1].path, .sha256 = sources[1].sha256 },
    };
    const raw_samples = [_]RawSample{.{
        .outer_wall_ns = elapsed,
        .cpu_user_ns = after.cpu_user_ns -| before.cpu_user_ns,
        .cpu_system_ns = after.cpu_system_ns -| before.cpu_system_ns,
        .peak_rss_bytes_before = before.peak_rss_bytes,
        .peak_rss_bytes_after = after.peak_rss_bytes,
    }};
    const environment = [_][]const u8{ "TZ=UTC", "LC_ALL=C", "LANG=C", "network=forbidden" };
    const report = Report{
        .row = row.id,
        .licenses = row.licenses,
        .engine = .{
            .executable_path = identity.path,
            .executable_sha256 = identity.sha256,
            .version_output = framework.output,
            .framework_version = framework.version,
            .framework = .{ .bundle_version = framework.version, .os_build = framework.os_build },
            .adapter_source_revision = revision,
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
    };
    const json = try std.json.Stringify.valueAlloc(gpa, report, .{});
    defer gpa.free(json);
    try writer.writeAll(json);
    try writer.writeByte('\n');
    return validation.valid;
}

fn selfTest(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, argv: []const []const u8) !bool {
    const row = octane.RowSpec{
        .id = "adapter_self_test",
        .path = "fixture.js",
        .sha256 = "self-test",
        .licenses = &.{"repository-owned"},
        .result_names = &.{"Fixture"},
    };
    const sources = [2]LoadedSource{
        .{ .path = octane.base_path, .sha256 = "self-test", .bytes = "var BenchmarkSuite = { RunSuites: function(runner) { runner.NotifyResult('Fixture', '123'); runner.NotifyScore('456'); } };" },
        .{ .path = row.path, .sha256 = "self-test", .bytes = "var fixtureWorkloadBytesAreUnchanged = 1;" },
    };
    return runSample(gpa, io, writer, row, sources, false, "self-test", argv);
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
        try stdout.writeAll("independent-suite system JSC adapter self-test: passed\n");
        try stdout.flush();
        if (!valid) std.process.exit(1);
        return;
    }
    if (argv.len != 4) {
        std.debug.print("usage: independent-suite-jsc <verified-octane-checkout> <row> <zig-js-adapter-revision>\nrows: richards, regexp, splay, navier_stokes, box2d\n", .{});
        std.process.exit(2);
    }
    const row = octane.rowById(argv[2]) orelse {
        std.debug.print("independent-suite JSC runner: unknown or excluded row '{s}'\n", .{argv[2]});
        std.process.exit(2);
    };
    try verifyEnvironment(init.environ_map);
    try verifySourceIdentity(init.gpa, init.io, argv[3]);
    const checkout = try std.Io.Dir.cwd().realPathFileAlloc(init.io, argv[1], init.gpa);
    defer init.gpa.free(checkout);
    var sources_handed_off = false;
    const base = try readPinnedSource(init.gpa, init.io, checkout, octane.base_path, octane.base_sha256);
    errdefer if (!sources_handed_off) init.gpa.free(base.bytes);
    const workload = try readPinnedSource(init.gpa, init.io, checkout, row.path, row.sha256);
    errdefer if (!sources_handed_off) init.gpa.free(workload.bytes);
    const sources = [2]LoadedSource{ base, workload };
    sources_handed_off = true;
    const valid = try runSample(init.gpa, init.io, stdout, row.*, sources, true, argv[3], argv);
    try stdout.flush();
    if (!valid) std.process.exit(1);
}
