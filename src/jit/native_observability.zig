const std = @import("std");

pub const CodeKind = enum(u8) { baseline, optimizer };

/// Process-wide storage and lifecycle accounting for the opt-in GDB JIT
/// adapter. Lifetime counters are monotonic; live fields return to their prior
/// values after every registered artifact is retired.
pub const GdbJitStats = struct {
    live_registrations: usize,
    live_symfile_bytes: usize,
    live_unwind_bytes: usize,
    registrations: u64,
    unregistrations: u64,
};

/// Exact machine-frame contract emitted with an artifact. The plan describes
/// codegen facts rather than asking a publication backend to recognize opcodes.
pub const UnwindPlan = union(enum(u8)) {
    none,
    aarch64_leaf,
    aarch64_frame_pointer: struct {
        /// Offset of the final `ldp x29, x30, [sp], #16`; the following
        /// instruction is the artifact's sole `ret`.
        epilogue_offset: u32,
        /// Consecutive callee-saved registers starting at x19, pushed in pairs
        /// immediately after the frame record.
        saved_gpr_count: u8 = 0,
        /// Consecutive callee-saved registers starting at d8, pushed in pairs
        /// after the integer pairs.
        saved_float_count: u8 = 0,
    },
};

/// Exact source position attached to one native-PC change row. Lines and
/// columns use the engine's one-based inspector convention.
pub const SourcePosition = struct {
    byte_offset: usize,
    line: usize,
    column: usize,
};

/// One sorted native-PC change row. A null bytecode offset deliberately means
/// that the machine range is artifact plumbing (for example a prologue or
/// epilogue), not that a publisher should infer the nearest JavaScript site.
pub const PcLocation = struct {
    native_offset: u32,
    bytecode_offset: ?u32 = null,
    source: ?SourcePosition = null,
};

/// Immutable description of one generated artifact at the instant its native
/// mapping becomes reachable. Publishers must copy every slice they retain.
pub const Artifact = struct {
    kind: CodeKind,
    pc_start: usize,
    code: []const u8,
    symbol_name: []const u8,
    function_name: []const u8,
    function_identity: usize,
    script_id: u64,
    source_url: []const u8,
    source_byte_offset: usize,
    source_line: usize,
    source_column: usize,
    /// Sorted, artifact-relative PC rows. Publishers must copy this slice if
    /// they retain it after `publish_fn` returns.
    pc_locations: []const PcLocation = &.{},
    unwind: UnwindPlan = .none,
};

/// Caller-owned, non-overlapping storage for allocation-free native-PC lookup.
/// A successful lookup returns slices into these buffers; undersized storage
/// fails closed rather than truncating the identity a crash reporter persists.
pub const SignalSafeBuffers = struct {
    symbol_name: []u8,
    function_name: []u8,
    source_url: []u8,
};

/// Exact immutable artifact/source identity copied while an Owner registry read
/// lease protects the backing metadata from retirement.
pub const SignalSafeSnapshot = struct {
    artifact_id: u64,
    kind: CodeKind,
    pc_start: usize,
    pc_end: usize,
    native_offset: usize,
    retired: bool,
    symbol_name: []const u8,
    function_name: []const u8,
    function_identity: usize,
    script_id: u64,
    source_url: []const u8,
    source_byte_offset: usize,
    source_line: usize,
    source_column: usize,
    bytecode_offset: ?u32,
    source_is_exact: bool,
};

pub const SignalSafeLookupError = error{NativeIdentityBufferTooSmall};

/// Embedded in the artifact-owned metadata allocation. Writers serialize list
/// links, while readers use only lock-free word atomics and immutable fields.
pub const SignalSafeRegistryNode = struct {
    next: std.atomic.Value(usize) = .init(0),
    retired: std.atomic.Value(bool) = .init(false),
    artifact_id: u64,
    artifact: Artifact,
};

pub const SignalSafeRegistry = struct {
    head: std.atomic.Value(usize) = .init(0),
    reader_epoch: std.atomic.Value(usize) = .init(0),
    readers: [2]std.atomic.Value(usize) = .{ .init(0), .init(0) },
    writer_lock: std.atomic.Mutex = .unlocked,

    pub fn register(self: *SignalSafeRegistry, node: *SignalSafeRegistryNode) void {
        while (!self.writer_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.writer_lock.unlock();
        node.next.store(self.head.load(.monotonic), .monotonic);
        self.head.store(@intFromPtr(node), .seq_cst);
    }

    pub fn unregister(self: *SignalSafeRegistry, node: *SignalSafeRegistryNode) void {
        while (!self.writer_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.writer_lock.unlock();
        var previous: ?*SignalSafeRegistryNode = null;
        var address = self.head.load(.monotonic);
        while (address != 0) {
            const current: *SignalSafeRegistryNode = @ptrFromInt(address);
            const next = current.next.load(.monotonic);
            if (current == node) {
                if (previous) |value|
                    value.next.store(next, .seq_cst)
                else
                    self.head.store(next, .seq_cst);
                break;
            }
            previous = current;
            address = next;
        }
        std.debug.assert(address != 0);

        // Flip reader generations after unlinking. Readers that may have seen
        // the removed link drain from the old slot; later crash lookups use the
        // other slot and therefore cannot starve executable retirement.
        const old_epoch = self.reader_epoch.load(.seq_cst);
        const new_epoch = old_epoch ^ 1;
        std.debug.assert(self.readers[new_epoch].load(.seq_cst) == 0);
        self.reader_epoch.store(new_epoch, .seq_cst);
        while (self.readers[old_epoch].load(.seq_cst) != 0) std.atomic.spinLoopHint();
        node.next.store(0, .monotonic);
    }

    /// Resolve one generated PC without locks, allocation, I/O, or borrowed
    /// return storage. This is suitable for a POSIX signal/crash callback when
    /// the caller supplies preallocated buffers and does only signal-safe work.
    pub fn lookup(
        self: *SignalSafeRegistry,
        pc: usize,
        buffers: SignalSafeBuffers,
    ) SignalSafeLookupError!?SignalSafeSnapshot {
        var reader_epoch: usize = undefined;
        while (true) {
            const candidate = self.reader_epoch.load(.seq_cst);
            _ = self.readers[candidate].fetchAdd(1, .seq_cst);
            if (self.reader_epoch.load(.seq_cst) == candidate) {
                reader_epoch = candidate;
                break;
            }
            _ = self.readers[candidate].fetchSub(1, .seq_cst);
        }
        defer _ = self.readers[reader_epoch].fetchSub(1, .seq_cst);

        var address = self.head.load(.seq_cst);
        while (address != 0) {
            const node: *const SignalSafeRegistryNode = @ptrFromInt(address);
            const artifact = node.artifact;
            const pc_end = artifact.pc_start + artifact.code.len;
            if (pc >= artifact.pc_start and pc < pc_end) {
                if (buffers.symbol_name.len < artifact.symbol_name.len or
                    buffers.function_name.len < artifact.function_name.len or
                    buffers.source_url.len < artifact.source_url.len)
                    return error.NativeIdentityBufferTooSmall;
                @memcpy(buffers.symbol_name[0..artifact.symbol_name.len], artifact.symbol_name);
                @memcpy(buffers.function_name[0..artifact.function_name.len], artifact.function_name);
                @memcpy(buffers.source_url[0..artifact.source_url.len], artifact.source_url);

                const native_offset = pc - artifact.pc_start;
                var bytecode_offset: ?u32 = null;
                var source_is_exact = false;
                var source_byte_offset = artifact.source_byte_offset;
                var source_line = artifact.source_line;
                var source_column = artifact.source_column;
                for (artifact.pc_locations) |location| {
                    if (location.native_offset > native_offset) break;
                    bytecode_offset = location.bytecode_offset;
                    source_is_exact = location.source != null;
                    if (location.source) |source| {
                        source_byte_offset = source.byte_offset;
                        source_line = source.line;
                        source_column = source.column;
                    } else {
                        source_byte_offset = artifact.source_byte_offset;
                        source_line = artifact.source_line;
                        source_column = artifact.source_column;
                    }
                }
                return .{
                    .artifact_id = node.artifact_id,
                    .kind = artifact.kind,
                    .pc_start = artifact.pc_start,
                    .pc_end = pc_end,
                    .native_offset = native_offset,
                    .retired = node.retired.load(.acquire),
                    .symbol_name = buffers.symbol_name[0..artifact.symbol_name.len],
                    .function_name = buffers.function_name[0..artifact.function_name.len],
                    .function_identity = artifact.function_identity,
                    .script_id = artifact.script_id,
                    .source_url = buffers.source_url[0..artifact.source_url.len],
                    .source_byte_offset = source_byte_offset,
                    .source_line = source_line,
                    .source_column = source_column,
                    .bytecode_offset = bytecode_offset,
                    .source_is_exact = source_is_exact,
                };
            }
            address = node.next.load(.seq_cst);
        }
        return null;
    }
};

pub const PublishError = std.mem.Allocator.Error || error{
    NativeSymbolObjectTooLarge,
    NativeUnwindInfoTooLarge,
    NativeCodePublicationFailed,
};

/// Embedder-selected external publication backend. Keeping this callback out
/// of the default engine link is important: the standard GDB JIT descriptor is
/// process-global, and an embeddable library must not collide with a host that
/// already owns it. The publisher and its context must outlive every Owner that
/// receives a copy. Callbacks run under the publishing Owner's lock, may run
/// concurrently for different Owners, and must not re-enter an Owner.
pub const Publisher = struct {
    context: ?*anyopaque = null,
    publish_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        artifact: Artifact,
    ) PublishError!?*anyopaque,
    unpublish_fn: *const fn (context: ?*anyopaque, token: *anyopaque) void,

    pub fn publish(
        self: Publisher,
        allocator: std.mem.Allocator,
        artifact: Artifact,
    ) PublishError!?Publication {
        const token = try self.publish_fn(self.context, allocator, artifact) orelse return null;
        return .{ .publisher = self, .token = token };
    }
};

/// Artifact-owned external publication token. `deinit` is deliberately
/// infallible because executable teardown cannot safely leave a stale PC range
/// registered after the mapping is released.
pub const Publication = struct {
    publisher: Publisher,
    token: *anyopaque,

    pub fn deinit(self: *Publication) void {
        self.publisher.unpublish_fn(self.publisher.context, self.token);
        self.* = undefined;
    }
};

test "signal-safe registry returns exact caller-owned identity" {
    var code: [16]u8 = @splat(0);
    const pc_start = @intFromPtr(&code);
    const locations = [_]PcLocation{
        .{ .native_offset = 0 },
        .{ .native_offset = 4, .bytecode_offset = 7, .source = .{ .byte_offset = 81, .line = 9, .column = 5 } },
        .{ .native_offset = 8 },
    };
    var registry = SignalSafeRegistry{};
    var node = SignalSafeRegistryNode{
        .artifact_id = 17,
        .artifact = .{
            .kind = .optimizer,
            .pc_start = pc_start,
            .code = &code,
            .symbol_name = "zig_js_optimizer_17_fixture",
            .function_name = "fixture",
            .function_identity = 0x501,
            .script_id = 23,
            .source_url = "fixture.js",
            .source_byte_offset = 3,
            .source_line = 2,
            .source_column = 1,
            .pc_locations = &locations,
        },
    };
    registry.register(&node);

    var symbol_buffer: [64]u8 = undefined;
    var function_buffer: [64]u8 = undefined;
    var source_buffer: [64]u8 = undefined;
    const exact = (try registry.lookup(pc_start + 4, .{
        .symbol_name = &symbol_buffer,
        .function_name = &function_buffer,
        .source_url = &source_buffer,
    })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 17), exact.artifact_id);
    try std.testing.expectEqual(CodeKind.optimizer, exact.kind);
    try std.testing.expectEqual(@as(usize, 4), exact.native_offset);
    try std.testing.expect(!exact.retired);
    try std.testing.expectEqualStrings("zig_js_optimizer_17_fixture", exact.symbol_name);
    try std.testing.expectEqualStrings("fixture", exact.function_name);
    try std.testing.expectEqualStrings("fixture.js", exact.source_url);
    try std.testing.expectEqual(@as(?u32, 7), exact.bytecode_offset);
    try std.testing.expect(exact.source_is_exact);
    try std.testing.expectEqual(@as(usize, 81), exact.source_byte_offset);
    try std.testing.expectEqual(@as(usize, 9), exact.source_line);
    try std.testing.expectEqual(@as(usize, 5), exact.source_column);

    var short_symbol: [1]u8 = undefined;
    try std.testing.expectError(error.NativeIdentityBufferTooSmall, registry.lookup(pc_start + 4, .{
        .symbol_name = &short_symbol,
        .function_name = &function_buffer,
        .source_url = &source_buffer,
    }));
    node.retired.store(true, .release);
    const retired = (try registry.lookup(pc_start + 8, .{
        .symbol_name = &symbol_buffer,
        .function_name = &function_buffer,
        .source_url = &source_buffer,
    })) orelse return error.TestUnexpectedResult;
    try std.testing.expect(retired.retired);
    try std.testing.expect(retired.bytecode_offset == null);
    try std.testing.expect(!retired.source_is_exact);
    try std.testing.expectEqual(@as(usize, 2), retired.source_line);

    registry.unregister(&node);
    try std.testing.expect((try registry.lookup(pc_start + 4, .{
        .symbol_name = &symbol_buffer,
        .function_name = &function_buffer,
        .source_url = &source_buffer,
    })) == null);
}
