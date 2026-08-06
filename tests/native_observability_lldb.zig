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
    baseline_pc: std.atomic.Value(usize) = .init(0),
    optimizer_pc: std.atomic.Value(usize) = .init(0),
    baseline_source_rows: std.atomic.Value(usize) = .init(0),
    optimizer_source_rows: std.atomic.Value(usize) = .init(0),
    publication_count: std.atomic.Value(usize) = .init(0),
    unpublication_count: std.atomic.Value(usize) = .init(0),

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
        const expected_kind: ?js.jit.CodeKind = if (std.mem.eql(u8, artifact.function_name, "observedBaseline"))
            .baseline
        else if (std.mem.eql(u8, artifact.function_name, "observedOptimizer"))
            .optimizer
        else
            null;
        if (expected_kind) |kind| {
            if (artifact.kind != kind) return error.NativeCodePublicationFailed;
            if (!std.mem.eql(u8, artifact.source_url, "native-observability-fixture.js"))
                return error.NativeCodePublicationFailed;
            var source_rows: usize = 0;
            for (artifact.pc_locations) |entry| if (entry.source != null) {
                source_rows += 1;
            };
            if (source_rows == 0) return error.NativeCodePublicationFailed;
            switch (artifact.kind) {
                .baseline => self.baseline_source_rows.store(source_rows, .release),
                .optimizer => self.optimizer_source_rows.store(source_rows, .release),
            }
        }
        const token = try self.inner.publish_fn(self.inner.context, allocator, artifact) orelse return null;
        var bases: DwarfEhBases = .{ .tbase = 0, .dbase = 0, .func = 0 };
        const pc: *const anyopaque = @ptrFromInt(artifact.pc_start);
        const fde = _Unwind_Find_FDE(pc, &bases);
        if (fde == null or bases.func != artifact.pc_start) {
            self.inner.unpublish_fn(self.inner.context, token);
            return error.NativeCodePublicationFailed;
        }
        if (expected_kind) |kind| switch (kind) {
            .baseline => self.baseline_pc.store(artifact.pc_start, .release),
            .optimizer => self.optimizer_pc.store(artifact.pc_start, .release),
        };
        _ = self.publication_count.fetchAdd(1, .release);
        return token;
    }

    fn unpublish(context: ?*anyopaque, token: *anyopaque) void {
        const self: *TrackingPublisher = @ptrCast(@alignCast(context.?));
        self.inner.unpublish_fn(self.inner.context, token);
        _ = self.unpublication_count.fetchAdd(1, .release);
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
    const source =
        \\function observedBaseline(n) {
        \\  var doubled = n + n;
        \\  var shifted = doubled - 3;
        \\  return shifted * 2;
        \\}
        \\observedBaseline(100); observedBaseline(100);
        \\function observedOptimizer(box, n) {
        \\  return box.value + n;
        \\}
        \\var observedBox = { value: 40 };
        \\observedOptimizer(observedBox, 1); observedOptimizer(observedBox, 1);
        \\observedOptimizer(observedBox, 1); observedOptimizer(observedBox, 1);
        \\observedOptimizer(observedBox, 1); observedOptimizer(observedBox, 1);
        \\observedOptimizer(observedBox, 1); observedOptimizer(observedBox, 1);
        \\observedOptimizer(observedBox, 1); observedOptimizer(observedBox, 2)
    ;
    const result = evaluate: {
        const script = try context.registerDebugScript(
            source,
            "native-observability-fixture.js",
            20,
        );
        const saved_script_id = context.debug_script_id;
        const saved_start_line = context.debug_script_start_line;
        defer {
            context.debug_script_id = saved_script_id;
            context.debug_script_start_line = saved_start_line;
        }
        context.debug_script_id = script.id;
        context.debug_script_start_line = script.start_line;
        break :evaluate try context.evaluate(source);
    };
    if (result.asNum() != 42) return error.TestUnexpectedResult;
    const warmed = try context.evaluate("observedBaseline(101)");
    if (warmed.asNum() != 398) return error.TestUnexpectedWarmResult;
    if (context.jit_owner.stats().live_artifacts == 0) return error.TestMissingNativeArtifact;
    if (tracking.publication_count.load(.acquire) < 2) return error.TestMissingUnwindRegistration;
    if (tracking.baseline_source_rows.load(.acquire) == 0) return error.TestMissingBaselineSourceRows;
    if (tracking.optimizer_source_rows.load(.acquire) == 0) return error.TestMissingOptimizerSourceRows;
    const native = try context.evaluate("observedOptimizer(observedBox, 3)");
    if (native.asNum() != 43) return error.TestUnexpectedNativeResult;
    context.destroy();
    if (tracking.unpublication_count.load(.acquire) != tracking.publication_count.load(.acquire))
        return error.TestUnexpectedResult;
    var bases: DwarfEhBases = undefined;
    if (_Unwind_Find_FDE(@ptrFromInt(tracking.baseline_pc.load(.acquire)), &bases) != null)
        return error.TestUnexpectedBaselineUnwindRegistration;
    if (_Unwind_Find_FDE(@ptrFromInt(tracking.optimizer_pc.load(.acquire)), &bases) != null)
        return error.TestUnexpectedOptimizerUnwindRegistration;
    @call(.never_inline, native_observability_after_unregister, .{});
}
