const std = @import("std");
const js = @import("js");

const DwarfEhBases = extern struct {
    tbase: usize,
    dbase: usize,
    func: usize,
};

extern "c" fn _Unwind_Find_FDE(pc: *const anyopaque, bases: *DwarfEhBases) ?*const anyopaque;

const TrackingPublisher = struct {
    inner: js.jit.NativeCodePublisher,
    last_pc: std.atomic.Value(usize) = .init(0),
    registered: std.atomic.Value(bool) = .init(false),
    unregistered: std.atomic.Value(bool) = .init(false),

    fn interface(self: *TrackingPublisher) js.jit.NativeCodePublisher {
        return .{
            .context = self,
            .publish_fn = publish,
            .unpublish_fn = unpublish,
        };
    }

    fn publish(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        artifact: js.jit.NativeCodeArtifact,
    ) js.jit.NativeCodePublicationError!?*anyopaque {
        const self: *TrackingPublisher = @ptrCast(@alignCast(context.?));
        const token = try self.inner.publish_fn(self.inner.context, allocator, artifact) orelse return null;
        var bases: DwarfEhBases = .{ .tbase = 0, .dbase = 0, .func = 0 };
        const pc: *const anyopaque = @ptrFromInt(artifact.pc_start);
        const fde = _Unwind_Find_FDE(pc, &bases);
        if (fde == null or bases.func != artifact.pc_start) {
            self.inner.unpublish_fn(self.inner.context, token);
            return error.NativeCodePublicationFailed;
        }
        self.last_pc.store(artifact.pc_start, .release);
        self.registered.store(true, .release);
        return token;
    }

    fn unpublish(context: ?*anyopaque, token: *anyopaque) void {
        const self: *TrackingPublisher = @ptrCast(@alignCast(context.?));
        const pc = self.last_pc.load(.acquire);
        self.inner.unpublish_fn(self.inner.context, token);
        if (pc == 0) return;
        var bases: DwarfEhBases = undefined;
        self.unregistered.store(_Unwind_Find_FDE(@ptrFromInt(pc), &bases) == null, .release);
    }
};

export fn native_observability_after_unregister() callconv(.c) void {
    asm volatile ("" ::: .{ .memory = true });
}

pub fn main() !void {
    if (!js.jit.supported) return error.UnsupportedTarget;

    var tracking = TrackingPublisher{ .inner = js.jit.gdbJitPublisher() };
    const context = try js.Context.createWith(std.heap.page_allocator, .{
        .native_code_publisher = tracking.interface(),
    });
    errdefer context.destroy();
    const result = try context.evaluate(
        \\function observedNative(n) {
        \\  var total = 0;
        \\  var i = 0;
        \\  while (i < n) { total = total + i; i = i + 1; }
        \\  return total;
        \\}
        \\observedNative(100)
    );
    if (result.asNum() != 4950) return error.TestUnexpectedResult;
    const warmed = try context.evaluate("observedNative(101)");
    if (warmed.asNum() != 5050) return error.TestUnexpectedWarmResult;
    if (context.jit_owner.stats().live_artifacts == 0) return error.TestMissingNativeArtifact;
    if (!tracking.registered.load(.acquire)) return error.TestMissingUnwindRegistration;
    const native = try context.evaluate("observedNative(102)");
    if (native.asNum() != 5151) return error.TestUnexpectedNativeResult;
    context.destroy();
    if (!tracking.unregistered.load(.acquire)) return error.TestUnexpectedResult;
    @call(.never_inline, native_observability_after_unregister, .{});
}
