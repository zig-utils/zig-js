const std = @import("std");
const js = @import("js");

const IdentityCapacity = 256;
const CrashIdentityCapacity = 128;
const PosixMinimumPipeBuf = 512;
const CrashMagic: [8]u8 = "ZJCRASH1".*;
const crash_record_version: u32 = 1;
const crash_success_exit: c_int = 86;
const crash_write_failure_exit: c_int = 87;

const CrashRecord = extern struct {
    magic: [8]u8,
    version: u32,
    signal: u32,
    kind: u8,
    source_is_exact: u8,
    retired: u8,
    bytecode_present: u8,
    artifact_id: u64,
    pc: u64,
    pc_start: u64,
    pc_end: u64,
    native_offset: u64,
    function_identity: u64,
    script_id: u64,
    source_byte_offset: u64,
    source_line: u64,
    source_column: u64,
    bytecode_offset: u32,
    symbol_len: u16,
    function_len: u16,
    source_len: u16,
    reserved: u16,
    symbol_name: [CrashIdentityCapacity]u8,
    function_name: [CrashIdentityCapacity]u8,
    source_url: [CrashIdentityCapacity]u8,
};

comptime {
    if (@sizeOf(CrashRecord) > PosixMinimumPipeBuf)
        @compileError("crash record must fit in the POSIX minimum PIPE_BUF");
}

var signal_context: std.atomic.Value(usize) = .init(0);
var stop_sender: std.atomic.Value(bool) = .init(false);
var handler_calls: std.atomic.Value(usize) = .init(0);
var lookup_misses: std.atomic.Value(usize) = .init(0);
var buffer_failures: std.atomic.Value(usize) = .init(0);
var captured: std.atomic.Value(bool) = .init(false);
var captured_pc: usize = 0;
var captured_pc_start: usize = 0;
var captured_pc_end: usize = 0;
var captured_native_offset: usize = 0;
var captured_artifact_id: u64 = 0;
var captured_source_byte_offset: usize = 0;
var captured_source_line: usize = 0;
var captured_source_column: usize = 0;
var captured_bytecode_offset: ?u32 = null;
var captured_kind: js.jit.CodeKind = .baseline;
var captured_symbol_len: usize = 0;
var captured_function_len: usize = 0;
var captured_source_len: usize = 0;
var signal_symbol: [IdentityCapacity]u8 = undefined;
var signal_function: [IdentityCapacity]u8 = undefined;
var signal_source: [IdentityCapacity]u8 = undefined;

const signal_source_text =
    \\function signalTarget(limit) {
    \\  var total = 0;
    \\  var index = 0;
    \\  while (index < limit) {
    \\    total = total + 1;
    \\    index = index + 1;
    \\  }
    \\  return total;
    \\}
    \\signalTarget(32); signalTarget(32); signalTarget(32);
    \\signalTarget(32); signalTarget(32); signalTarget(32);
    \\signalTarget(32); signalTarget(32); signalTarget(32);
    \\signalTarget(32); signalTarget(32); signalTarget(32)
;
const signal_source_url = "native-observability-signal.js";

const PublisherCapture = struct {
    publications: std.atomic.Value(usize) = .init(0),
    unpublications: std.atomic.Value(usize) = .init(0),
    target_publications: std.atomic.Value(usize) = .init(0),

    fn interface(self: *PublisherCapture) js.jit.NativeCodePublisher {
        return .{
            .context = self,
            .publish_fn = publish,
            .unpublish_fn = unpublish,
        };
    }

    fn publish(
        context: ?*anyopaque,
        _: std.mem.Allocator,
        artifact: js.jit.NativeCodeArtifact,
    ) js.jit.NativeCodePublicationError!?*anyopaque {
        const self: *PublisherCapture = @ptrCast(@alignCast(context.?));
        _ = self.publications.fetchAdd(1, .release);
        if (std.mem.eql(u8, artifact.function_name, "signalTarget"))
            _ = self.target_publications.fetchAdd(1, .release);
        return self;
    }

    fn unpublish(context: ?*anyopaque, _: *anyopaque) void {
        const self: *PublisherCapture = @ptrCast(@alignCast(context.?));
        _ = self.unpublications.fetchAdd(1, .release);
    }
};

fn handleSignal(_: std.posix.SIG, _: *const std.c.siginfo_t, raw_context: ?*anyopaque) callconv(.c) void {
    defer _ = handler_calls.fetchAdd(1, .release);
    if (captured.load(.acquire)) return;
    const context_address = signal_context.load(.acquire);
    if (context_address == 0) return;
    const registers = std.debug.cpu_context.fromPosixSignalContext(raw_context) orelse return;
    const pc: usize = @intCast(registers.pc);
    const context: *js.Context = @ptrFromInt(context_address);
    const snapshot = context.lookupNativeCodeSignalSafe(pc, .{
        .symbol_name = &signal_symbol,
        .function_name = &signal_function,
        .source_url = &signal_source,
    }) catch {
        _ = buffer_failures.fetchAdd(1, .monotonic);
        return;
    } orelse {
        _ = lookup_misses.fetchAdd(1, .monotonic);
        return;
    };
    if (!snapshot.source_is_exact or !std.mem.eql(u8, snapshot.function_name, "signalTarget")) return;

    captured_pc = pc;
    captured_pc_start = snapshot.pc_start;
    captured_pc_end = snapshot.pc_end;
    captured_native_offset = snapshot.native_offset;
    captured_artifact_id = snapshot.artifact_id;
    captured_source_byte_offset = snapshot.source_byte_offset;
    captured_source_line = snapshot.source_line;
    captured_source_column = snapshot.source_column;
    captured_bytecode_offset = snapshot.bytecode_offset;
    captured_kind = snapshot.kind;
    captured_symbol_len = snapshot.symbol_name.len;
    captured_function_len = snapshot.function_name.len;
    captured_source_len = snapshot.source_url.len;
    captured.store(true, .release);
}

fn handleFatalSignal(signal: std.posix.SIG, _: *const std.c.siginfo_t, raw_context: ?*anyopaque) callconv(.c) void {
    defer _ = handler_calls.fetchAdd(1, .release);
    const context_address = signal_context.load(.acquire);
    if (context_address == 0) return;
    const registers = std.debug.cpu_context.fromPosixSignalContext(raw_context) orelse return;
    const pc: usize = @intCast(registers.pc);
    const context: *js.Context = @ptrFromInt(context_address);
    var record = std.mem.zeroes(CrashRecord);
    const snapshot = context.lookupNativeCodeSignalSafe(pc, .{
        .symbol_name = &record.symbol_name,
        .function_name = &record.function_name,
        .source_url = &record.source_url,
    }) catch return orelse return;
    if (!snapshot.source_is_exact or !std.mem.eql(u8, snapshot.function_name, "signalTarget")) return;

    record.magic = CrashMagic;
    record.version = crash_record_version;
    record.signal = @backingInt(signal);
    record.kind = @backingInt(snapshot.kind);
    record.source_is_exact = @intFromBool(snapshot.source_is_exact);
    record.retired = @intFromBool(snapshot.retired);
    record.bytecode_present = @intFromBool(snapshot.bytecode_offset != null);
    record.artifact_id = snapshot.artifact_id;
    record.pc = pc;
    record.pc_start = snapshot.pc_start;
    record.pc_end = snapshot.pc_end;
    record.native_offset = snapshot.native_offset;
    record.function_identity = snapshot.function_identity;
    record.script_id = snapshot.script_id;
    record.source_byte_offset = snapshot.source_byte_offset;
    record.source_line = snapshot.source_line;
    record.source_column = snapshot.source_column;
    record.bytecode_offset = snapshot.bytecode_offset orelse 0;
    record.symbol_len = @intCast(snapshot.symbol_name.len);
    record.function_len = @intCast(snapshot.function_name.len);
    record.source_len = @intCast(snapshot.source_url.len);

    // stdout is a pipe opened by the parent before exec. One record is below
    // PIPE_BUF, so a successful blocking write transports it atomically.
    const bytes = std.mem.asBytes(&record);
    if (std.c.write(1, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len)))
        std.c._exit(crash_write_failure_exit);
    std.c._exit(crash_success_exit);
}

const SignalSender = struct {
    target: std.c.pthread_t,
    failed: std.atomic.Value(bool) = .init(false),
    sends: std.atomic.Value(usize) = .init(0),

    fn run(self: *SignalSender) void {
        while (!stop_sender.load(.acquire) and !captured.load(.acquire)) {
            const handled_before = handler_calls.load(.acquire);
            if (std.c.pthread_kill(self.target, .USR1) != 0) {
                self.failed.store(true, .release);
                return;
            }
            _ = self.sends.fetchAdd(1, .monotonic);
            // A successful send is not complete until its handler returns.
            // This keeps Context teardown safe even on a failing fixture path.
            while (handler_calls.load(.acquire) == handled_before)
                std.atomic.spinLoopHint();
        }
    }
};

const FatalSignalSender = struct {
    target: std.c.pthread_t,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *FatalSignalSender) void {
        while (!stop_sender.load(.acquire)) {
            const handled_before = handler_calls.load(.acquire);
            if (std.c.pthread_kill(self.target, .ABRT) != 0) {
                self.failed.store(true, .release);
                return;
            }
            // Returning handlers sampled host code. Wait before delivering the
            // next fatal signal so only one handler can hold a registry lease.
            while (handler_calls.load(.acquire) == handled_before)
                std.atomic.spinLoopHint();
        }
    }
};

fn createWarmedContext(publisher: *PublisherCapture) !*js.Context {
    const context = try js.Context.createWith(std.heap.page_allocator, .{
        .native_code_publisher = publisher.interface(),
    });
    errdefer context.destroy();
    const script = try context.registerDebugScript(signal_source_text, signal_source_url, 100);
    const saved_script_id = context.debug_script_id;
    const saved_start_line = context.debug_script_start_line;
    context.debug_script_id = script.id;
    context.debug_script_start_line = script.start_line;
    const warmed = context.evaluate(signal_source_text) catch |err| {
        context.debug_script_id = saved_script_id;
        context.debug_script_start_line = saved_start_line;
        return err;
    };
    context.debug_script_id = saved_script_id;
    context.debug_script_start_line = saved_start_line;
    if (warmed.asNum() != 32) return error.TestUnexpectedWarmResult;
    if (publisher.target_publications.load(.acquire) == 0) return error.TestMissingNativeArtifact;
    return context;
}

fn runSignalSample() !void {
    var old_action: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.SIGINFO,
    };
    std.posix.sigaction(.USR1, &action, &old_action);
    defer std.posix.sigaction(.USR1, &old_action, null);

    var publisher = PublisherCapture{};
    const context = try createWarmedContext(&publisher);
    errdefer context.destroy();

    signal_context.store(@intFromPtr(context), .release);
    var sender = SignalSender{ .target = std.c.pthread_self() };
    var thread = try std.Thread.spawn(.{}, SignalSender.run, .{&sender});
    var joined = false;
    defer if (!joined) {
        stop_sender.store(true, .release);
        thread.join();
    };

    var attempts: usize = 0;
    while (!captured.load(.acquire) and attempts < 256) : (attempts += 1) {
        const result = try context.evaluate("signalTarget(2000000)");
        if (result.asNum() != 2000000) return error.TestUnexpectedNativeResult;
    }
    stop_sender.store(true, .release);
    thread.join();
    joined = true;
    signal_context.store(0, .release);

    if (sender.failed.load(.acquire)) return error.TestSignalDeliveryFailed;
    if (!captured.load(.acquire)) return error.TestMissingGeneratedPcSample;
    if (buffer_failures.load(.acquire) != 0) return error.TestIdentityBufferTooSmall;
    if (sender.sends.load(.acquire) == 0 or handler_calls.load(.acquire) == 0)
        return error.TestMissingSignalDelivery;
    if (captured_artifact_id == 0 or captured_pc < captured_pc_start or captured_pc >= captured_pc_end)
        return error.TestInvalidArtifactIdentity;
    if (captured_pc != captured_pc_start + captured_native_offset)
        return error.TestInvalidNativeOffset;
    if (captured_bytecode_offset == null or captured_source_byte_offset == 0)
        return error.TestMissingSourceIdentity;
    if (captured_source_line < 101 or captured_source_line > 107 or captured_source_column == 0)
        return error.TestInvalidSourceIdentity;
    if (!std.mem.eql(u8, signal_function[0..captured_function_len], "signalTarget"))
        return error.TestInvalidFunctionIdentity;
    if (!std.mem.eql(u8, signal_source[0..captured_source_len], "native-observability-signal.js"))
        return error.TestInvalidSourceIdentity;
    const symbol = signal_symbol[0..captured_symbol_len];
    const expected_prefix = switch (captured_kind) {
        .baseline => "zig_js_baseline_",
        .optimizer => "zig_js_optimizer_",
    };
    if (!std.mem.startsWith(u8, symbol, expected_prefix) or
        !std.mem.endsWith(u8, symbol, "_signalTarget"))
        return error.TestInvalidSymbolIdentity;

    context.destroy();
    if (publisher.publications.load(.acquire) == 0 or
        publisher.unpublications.load(.acquire) != publisher.publications.load(.acquire))
        return error.TestUnexpectedPublicationLifetime;
}

fn runCrashChild() !void {
    var old_action: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handleFatalSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.SIGINFO,
    };
    std.posix.sigaction(.ABRT, &action, &old_action);
    defer std.posix.sigaction(.ABRT, &old_action, null);

    var publisher = PublisherCapture{};
    const context = try createWarmedContext(&publisher);
    errdefer context.destroy();
    signal_context.store(@intFromPtr(context), .release);
    var sender = FatalSignalSender{ .target = std.c.pthread_self() };
    var thread = try std.Thread.spawn(.{}, FatalSignalSender.run, .{&sender});
    var joined = false;
    defer if (!joined) {
        stop_sender.store(true, .release);
        thread.join();
    };

    var attempts: usize = 0;
    while (attempts < 256) : (attempts += 1) {
        const result = try context.evaluate("signalTarget(2000000)");
        if (result.asNum() != 2000000) return error.TestUnexpectedNativeResult;
    }
    stop_sender.store(true, .release);
    thread.join();
    joined = true;
    signal_context.store(0, .release);
    if (sender.failed.load(.acquire)) return error.TestSignalDeliveryFailed;
    return error.TestMissingFatalGeneratedPcSample;
}

fn runCrashParent(gpa: std.mem.Allocator, io: std.Io) !void {
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    const completed = try std.process.run(gpa, io, .{
        .argv = &.{ executable, "--crash-child" },
        .stdout_limit = .limited(@sizeOf(CrashRecord)),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(completed.stdout);
    defer gpa.free(completed.stderr);
    switch (completed.term) {
        .exited => |code| if (code != crash_success_exit) return error.TestCrashChildExit,
        else => return error.TestCrashChildTermination,
    }
    if (completed.stdout.len != @sizeOf(CrashRecord)) return error.TestCrashRecordSize;
    if (completed.stderr.len != 0) return error.TestCrashChildStderr;

    var record: CrashRecord = undefined;
    @memcpy(std.mem.asBytes(&record), completed.stdout);
    if (!std.mem.eql(u8, &record.magic, &CrashMagic) or record.version != crash_record_version)
        return error.TestCrashRecordHeader;
    if (record.signal != @backingInt(std.posix.SIG.ABRT) or record.source_is_exact != 1 or record.retired != 0)
        return error.TestCrashRecordState;
    if (record.artifact_id == 0 or record.function_identity == 0 or record.script_id == 0)
        return error.TestCrashRecordIdentity;
    if (record.pc < record.pc_start or record.pc >= record.pc_end or
        record.pc != record.pc_start + record.native_offset)
        return error.TestCrashRecordRange;
    if (record.bytecode_present != 1 or record.source_byte_offset == 0 or
        record.source_line < 101 or record.source_line > 107 or record.source_column == 0)
        return error.TestCrashRecordSource;
    if (record.symbol_len == 0 or record.symbol_len > CrashIdentityCapacity or
        record.function_len > CrashIdentityCapacity or record.source_len > CrashIdentityCapacity)
        return error.TestCrashRecordLengths;
    const function_name = record.function_name[0..record.function_len];
    const source_url = record.source_url[0..record.source_len];
    if (!std.mem.eql(u8, function_name, "signalTarget") or
        !std.mem.eql(u8, source_url, signal_source_url))
        return error.TestCrashRecordNames;
    const symbol_name = record.symbol_name[0..record.symbol_len];
    const expected_prefix = if (record.kind == @backingInt(js.jit.CodeKind.baseline))
        "zig_js_baseline_"
    else if (record.kind == @backingInt(js.jit.CodeKind.optimizer))
        "zig_js_optimizer_"
    else
        return error.TestCrashRecordKind;
    if (!std.mem.startsWith(u8, symbol_name, expected_prefix) or
        !std.mem.endsWith(u8, symbol_name, "_signalTarget"))
        return error.TestCrashRecordSymbol;
}

pub fn main(init: std.process.Init) !void {
    if (!js.jit.supported) return error.UnsupportedTarget;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next();
    if (args.next() != null) return error.TestUnexpectedArgument;
    if (mode == null) return runSignalSample();
    if (std.mem.eql(u8, mode.?, "--crash-child")) return runCrashChild();
    if (std.mem.eql(u8, mode.?, "--crash-parent")) return runCrashParent(init.gpa, init.io);
    return error.TestUnexpectedArgument;
}
