const std = @import("std");

pub const CodeKind = enum(u8) { baseline, optimizer };

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
    unwind: UnwindPlan = .none,
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
