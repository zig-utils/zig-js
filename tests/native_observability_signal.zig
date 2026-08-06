const std = @import("std");
const js = @import("js");

const IdentityCapacity = 256;

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

pub fn main() !void {
    if (!js.jit.supported) return error.UnsupportedTarget;

    var old_action: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .sigaction = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.c.SA.SIGINFO,
    };
    std.posix.sigaction(.USR1, &action, &old_action);
    defer std.posix.sigaction(.USR1, &old_action, null);

    var publisher = PublisherCapture{};
    const context = try js.Context.createWith(std.heap.page_allocator, .{
        .native_code_publisher = publisher.interface(),
    });
    errdefer context.destroy();
    const source =
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
    const script = try context.registerDebugScript(source, "native-observability-signal.js", 100);
    const saved_script_id = context.debug_script_id;
    const saved_start_line = context.debug_script_start_line;
    context.debug_script_id = script.id;
    context.debug_script_start_line = script.start_line;
    const warmed = context.evaluate(source) catch |err| {
        context.debug_script_id = saved_script_id;
        context.debug_script_start_line = saved_start_line;
        return err;
    };
    context.debug_script_id = saved_script_id;
    context.debug_script_start_line = saved_start_line;
    if (warmed.asNum() != 32) return error.TestUnexpectedWarmResult;
    if (publisher.target_publications.load(.acquire) == 0) return error.TestMissingNativeArtifact;

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
