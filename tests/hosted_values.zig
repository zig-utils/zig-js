const std = @import("std");
const js = @import("js");

pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    var threaded = std.Io.Threaded.init(heap.allocator(), .{});
    defer threaded.deinit();
    const context = try js.Context.createWith(heap.allocator(), .{
        .enable_gc = true,
        .enable_jit = true,
        .heap_limit_bytes = 64 * 1024 * 1024,
    });
    defer context.destroy();
    const callback = try context.evaluateProtected(
        "(function(){ let frames = 0; return function(bytes, step) { bytes[0] += step; return ++frames; }; })()",
    );
    defer _ = context.unprotectValue(callback);
    const buffer = try context.createHostValue(.{ .typed_array = .{ .kind = .u8, .bytes = &.{ 1, 2, 3 } } });
    defer _ = context.unprotectValue(buffer);
    const step = try context.createHostValue(.{ .number = 2 });
    defer _ = context.unprotectValue(step);
    for (0..100) |index| {
        const result = try context.callProtected(callback, null, &.{ buffer, step });
        try std.testing.expectEqual(@as(f64, @floatFromInt(index + 1)), result.get().asNum());
        try std.testing.expect(context.unprotectValue(result));
        context.collectGarbage();
        if (index % 10 == 0) {
            const compaction = context.compactGarbage();
            try std.testing.expect(compaction.status != .unsupported);
        }
    }
    var bytes: [3]u8 = undefined;
    try context.copyTypedArrayBytes(buffer, 0, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 201, 2, 3 }, &bytes);
    try context.writeTypedArrayBytes(buffer, 1, &.{ 9, 8 });
    try context.copyTypedArrayBytes(buffer, 0, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 201, 9, 8 }, &bytes);
    try std.testing.expectError(error.OutOfBounds, context.copyTypedArrayBytes(buffer, 2, &bytes));
    try std.testing.expectError(error.InvalidBuffer, context.copyTypedArrayBytes(step, 0, &bytes));
    try std.testing.expectError(error.InvalidBuffer, context.createHostValue(.{ .typed_array = .{ .kind = .f64, .bytes = &.{1} } }));
    try std.testing.expectError(error.InvalidString, context.createHostValue(.{ .string = &.{0xff} }));
    const receiver = try context.evaluateProtected("({ total: 7 })");
    defer _ = context.unprotectValue(receiver);
    const with_receiver = try context.evaluateProtected("(function(step){ return this.total + step; })");
    defer _ = context.unprotectValue(with_receiver);
    const received = try context.callProtected(with_receiver, receiver, &.{step});
    try std.testing.expectEqual(@as(f64, 9), received.get().asNum());
    try std.testing.expect(context.unprotectValue(received));
    const subview = try context.evaluateProtected("new Uint16Array(new Uint8Array([1,2,3,4,5,6]).buffer, 2, 1)");
    defer _ = context.unprotectValue(subview);
    var word: [2]u8 = undefined;
    try context.copyTypedArrayBytes(subview, 0, &word);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, &word);
    const detached = try context.evaluateProtected("(function(){ let b = new ArrayBuffer(3); let v = new Uint8Array(b); b.transfer(); return v; })()");
    defer _ = context.unprotectValue(detached);
    try std.testing.expectError(error.InvalidBuffer, context.copyTypedArrayBytes(detached, 0, &bytes));
    const shrunk = try context.evaluateProtected("(function(){ let b = new ArrayBuffer(6, { maxByteLength: 8 }); let v = new Uint8Array(b, 3, 3); b.resize(2); return v; })()");
    defer _ = context.unprotectValue(shrunk);
    try std.testing.expectError(error.InvalidBuffer, context.copyTypedArrayBytes(shrunk, 0, &bytes));
    const immutable = try context.evaluateProtected("new Uint8Array(new ArrayBuffer(3).transferToImmutable())");
    defer _ = context.unprotectValue(immutable);
    try std.testing.expectError(error.InvalidBuffer, context.writeTypedArrayBytes(immutable, 0, &.{1}));
    const noncallable = try context.createHostValue(.{ .number = 4 });
    defer _ = context.unprotectValue(noncallable);
    try std.testing.expectError(error.Throw, context.callProtected(noncallable, null, &.{}));
    const string = try context.createHostValue(.{ .string = "retained string" });
    defer _ = context.unprotectValue(string);
    const lexical_admissions_before = context.bytecodeAdmissionSnapshot().count(.program_policy_lexical_declaration);
    const relocating = try context.evaluateProtected(
        \\globalThis.hostedDiscard = [];
        \\for (var dead = 0; dead < 2048; dead = dead + 1)
        \\  hostedDiscard.push({ dead: dead, child: { marker: dead + 1 } });
        \\function hostedSpin(n) {
        \\  var total = 0, i = 0;
        \\  while (i < n) { total = total + i; i = i + 1; }
        \\  return total;
        \\}
        \\for (var warm = 0; warm < 12; warm = warm + 1) hostedSpin(64);
        \\hostedDiscard = null;
        \\(function(){ let closed = { marker: 19 }; return function(text, bytes) {
        \\  hostedSpin(20000);
        \\  if (text !== 'retained string' || bytes[0] !== 201 || this.total !== 7) throw 'stale arguments';
        \\  return closed.marker;
        \\}; })()
    );
    defer _ = context.unprotectValue(relocating);
    try std.testing.expectEqual(lexical_admissions_before + 1, context.bytecodeAdmissionSnapshot().count(.program_policy_lexical_declaration));
    context.collectGarbage();
    try std.testing.expect(context.requestGarbageCompaction());
    const relocated = try context.callProtected(relocating, receiver, &.{ string, buffer });
    try std.testing.expectEqual(@as(f64, 19), relocated.get().asNum());
    try std.testing.expect(context.unprotectValue(relocated));
    // The lexical source policy deliberately admitted this warm-up to the tree
    // walker. A host frame cannot turn that into a moving native checkpoint.
    try std.testing.expect(context.gc_compaction_requested.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), context.tierAttributionSnapshot().baseline_publications);
    const quiescent = context.compactGarbage();
    try std.testing.expectEqual(js.Context.GcHeap.CompactionStatus.compacted, quiescent.status);
    try std.testing.expect(quiescent.moved_cells > 0);
    std.debug.print("hosted values: lexical-policy call deferred movement; quiescent compaction moved {d} cells\n", .{quiescent.moved_cells});
    const after_movement = try context.callProtected(relocating, receiver, &.{ string, buffer });
    try std.testing.expectEqual(@as(f64, 19), after_movement.get().asNum());
    try std.testing.expect(context.unprotectValue(after_movement));
    // An ordinary var-only program takes the maintained VM/native admission
    // path. No forced testing tier or product admission override is used.
    const warm_native = try context.evaluateProtected(
        \\function hostedSpin(n) {
        \\  var total = 0;
        \\  var i = 0;
        \\  while (i < n) { total = total + i; i = i + 1; }
        \\  return total;
        \\}
        \\for (var warmNative = 0; warmNative < 12; warmNative = warmNative + 1) hostedSpin(64);
        \\0
    );
    try std.testing.expect(context.unprotectValue(warm_native));
    const native_callback = try context.evaluateProtected(
        \\globalThis.hostedDiscard = [];
        \\for (var nativeDead = 0; nativeDead < 2048; nativeDead = nativeDead + 1)
        \\  hostedDiscard.push({ dead: nativeDead, child: { marker: nativeDead + 1 } });
        \\hostedDiscard = null;
        \\(function(){ let closed = { marker: 19 }; return function(text, bytes) {
        \\  hostedSpin(20000);
        \\  if (text !== 'retained string' || bytes[0] !== 201 || this.total !== 7) throw 'stale native arguments';
        \\  return closed.marker;
        \\}; })()
    );
    defer _ = context.unprotectValue(native_callback);
    context.collectGarbage();
    const callback_address_before = @intFromPtr(native_callback.get().asObj());
    try std.testing.expect(context.requestGarbageCompaction());
    const native_result = try context.callProtected(native_callback, receiver, &.{ string, buffer });
    try std.testing.expectEqual(@as(f64, 19), native_result.get().asNum());
    try std.testing.expect(context.unprotectValue(native_result));
    if (js.jit.supported) {
        try std.testing.expect(context.tierAttributionSnapshot().baseline_publications > 0);
        try std.testing.expect(!context.gc_compaction_requested.load(.acquire));
        try std.testing.expect(callback_address_before != @intFromPtr(native_callback.get().asObj()));
        std.debug.print("hosted values: native checkpoint moved the retained callback during invocation\n", .{});
    } else {
        try std.testing.expect(context.gc_compaction_requested.load(.acquire));
        const after_call = context.compactGarbage();
        try std.testing.expectEqual(js.Context.GcHeap.CompactionStatus.compacted, after_call.status);
        try std.testing.expect(after_call.moved_cells > 0);
        std.debug.print("hosted values: target has no native moving checkpoint; quiescent compaction moved {d} cells\n", .{after_call.moved_cells});
    }
    // A callable Proxy can execute an accessor before call arguments have
    // reached parameter bindings. Its input snapshot must survive that moving
    // checkpoint as well as checkpoints inside an ordinary function body.
    const proxy_source =
        \\globalThis.hostedDiscard = [];
        \\for (var proxyDead = 0; proxyDead < 2048; proxyDead = proxyDead + 1)
        \\  hostedDiscard.push({ dead: proxyDead, child: { marker: proxyDead + 1 } });
        \\hostedDiscard = null;
        \\(function(){
        \\  var target = function(text, bytes) {
        \\    if (text !== 'proxy retained string' || bytes[0] !== 43 || this.total !== 11)
        \\      throw 'stale proxy arguments';
        \\    return 61;
        \\  };
        \\  var handler = { marker: 73, get apply() {
        \\    hostedSpin(20000);
        \\    if (globalThis.hostedProxyWithoutTrap) return undefined;
        \\    return function(fn, receiver, args) {
        \\      if (this.marker !== 73 || fn !== target) throw 'stale proxy target or handler';
        \\      return Reflect.apply(fn, receiver, args);
        \\    };
        \\  } };
        \\  return new Proxy(target, handler);
        \\})()
    ;
    const proxy_callback = try context.evaluateProtected(proxy_source);
    defer _ = context.unprotectValue(proxy_callback);
    const proxy_text = try context.createHostValue(.{ .string = "proxy retained string" });
    defer _ = context.unprotectValue(proxy_text);
    const proxy_bytes = try context.createHostValue(.{ .typed_array = .{ .kind = .u8, .bytes = &.{43} } });
    defer _ = context.unprotectValue(proxy_bytes);
    const proxy_receiver = try context.evaluateProtected("({total: 11})");
    defer _ = context.unprotectValue(proxy_receiver);
    context.collectGarbage();
    const proxy_address_before = @intFromPtr(proxy_callback.get().asObj());
    try std.testing.expect(context.requestGarbageCompaction());
    const proxy_result = try context.callProtected(proxy_callback, proxy_receiver, &.{ proxy_text, proxy_bytes });
    try std.testing.expectEqual(@as(f64, 61), proxy_result.get().asNum());
    try std.testing.expect(context.unprotectValue(proxy_result));
    if (js.jit.supported) {
        try std.testing.expect(!context.gc_compaction_requested.load(.acquire));
        try std.testing.expect(proxy_address_before != @intFromPtr(proxy_callback.get().asObj()));
        std.debug.print("hosted values: Proxy apply getter moved its retained inputs before argument binding\n", .{});
    } else {
        try std.testing.expect(context.gc_compaction_requested.load(.acquire));
        const proxy_quiescent = context.compactGarbage();
        try std.testing.expectEqual(js.Context.GcHeap.CompactionStatus.compacted, proxy_quiescent.status);
        try std.testing.expect(proxy_quiescent.moved_cells > 0);
    }
    const prepare_absent_trap = try context.evaluateProtected("globalThis.hostedProxyWithoutTrap = true; 0");
    try std.testing.expect(context.unprotectValue(prepare_absent_trap));
    // Allocate a new callback after the discarded cells. The previous callback
    // may already occupy its final compacted address and is not a move oracle.
    const absent_callback = try context.evaluateProtected(proxy_source);
    defer _ = context.unprotectValue(absent_callback);
    context.collectGarbage();
    const absent_address_before = @intFromPtr(absent_callback.get().asObj());
    try std.testing.expect(context.requestGarbageCompaction());
    const absent_result = try context.callProtected(absent_callback, proxy_receiver, &.{ proxy_text, proxy_bytes });
    try std.testing.expectEqual(@as(f64, 61), absent_result.get().asNum());
    try std.testing.expect(context.unprotectValue(absent_result));
    if (js.jit.supported) {
        try std.testing.expect(!context.gc_compaction_requested.load(.acquire));
        try std.testing.expect(absent_address_before != @intFromPtr(absent_callback.get().asObj()));
    } else {
        try std.testing.expect(context.gc_compaction_requested.load(.acquire));
        const absent_quiescent = context.compactGarbage();
        try std.testing.expectEqual(js.Context.GcHeap.CompactionStatus.compacted, absent_quiescent.status);
        try std.testing.expect(absent_quiescent.moved_cells > 0);
    }
    const revocation = try context.evaluateProtected(
        \\(function() {
        \\  var record;
        \\  var handler = { marker: 5, get apply() {
        \\    record.revoke();
        \\    return function(target, receiver, args) {
        \\      return this.marker + Reflect.apply(target, receiver, args);
        \\    };
        \\  } };
        \\  record = Proxy.revocable(function(value) { return this.base + value; }, handler);
        \\  return Reflect.apply(record.proxy, {base: 7}, [9]);
        \\})()
    );
    try std.testing.expectEqual(@as(f64, 21), revocation.get().asNum());
    try std.testing.expect(context.unprotectValue(revocation));
    const throwing = try context.evaluateProtected("(function(){ throw 'frame failed'; })");
    defer _ = context.unprotectValue(throwing);
    const retained_before_failure = context.protected_values.items.len;
    for (0..20) |_| {
        try std.testing.expectError(error.Throw, context.callProtected(throwing, null, &.{}));
        try std.testing.expect(context.exception.?.isString());
        try std.testing.expectEqual(retained_before_failure, context.protected_values.items.len);
    }
    const foreign = try js.Context.create(heap.allocator());
    defer foreign.destroy();
    const foreign_value = try foreign.protectValue(js.Value.num(1));
    defer _ = foreign.unprotectValue(foreign_value);
    try std.testing.expectError(error.InvalidHandle, context.callProtected(callback, null, &.{foreign_value}));
    const fabricated: *js.Context.ProtectedValue = @ptrFromInt(1);
    try std.testing.expectError(error.InvalidHandle, context.callProtected(fabricated, null, &.{}));
    try std.testing.expect(!context.unprotectValue(fabricated));
    const checkpoint = try context.evaluateProtected(
        "globalThis.hostedTimer = 0; var hostedAbort = AbortSignal.timeout(100); setTimeout(function(){ hostedTimer = 7; }, 100).unref(); (function(){ return hostedTimer + (hostedAbort.aborted ? 1 : 0); })",
    );
    defer _ = context.unprotectValue(checkpoint);
    try std.testing.expectEqual(@as(f64, 0), context.global_object.getOwn("hostedTimer").?.asNum());
    try std.Io.sleep(threaded.io(), .fromMilliseconds(150), .awake);
    const checkpoint_result = try context.callProtected(checkpoint, null, &.{});
    try std.testing.expectEqual(@as(f64, 8), checkpoint_result.get().asNum());
    try std.testing.expect(context.unprotectValue(checkpoint_result));
    const schedule_job = try context.evaluateProtected("globalThis.hostedMicrotask = 0; (function(){ Promise.resolve().then(function(){ hostedMicrotask = 3; }); return 1; })");
    defer _ = context.unprotectValue(schedule_job);
    const read_job = try context.evaluateProtected("(function(){ return hostedMicrotask; })");
    defer _ = context.unprotectValue(read_job);
    const scheduled = try context.callProtected(schedule_job, null, &.{});
    try std.testing.expect(context.unprotectValue(scheduled));
    const settled = try context.callProtected(read_job, null, &.{});
    try std.testing.expectEqual(@as(f64, 3), settled.get().asNum());
    try std.testing.expect(context.unprotectValue(settled));
    // evaluateModule's supplied host is scoped to that evaluation. Install the
    // existing persistent loader explicitly for later retained invocations.
    _ = try context.provideModuleLoaderSource("host:child", "export const answer = 11;");
    const importing = try context.evaluateProtected("globalThis.hostedImportValue = 0; (function(){ return import('host:child').then(function(m){ hostedImportValue = m.answer; }); })");
    defer _ = context.unprotectValue(importing);
    const read_import = try context.evaluateProtected("(function(){ return hostedImportValue; })");
    defer _ = context.unprotectValue(read_import);
    const promise = try context.callProtected(importing, null, &.{});
    try std.testing.expect(context.unprotectValue(promise));
    const imported = try context.callProtected(read_import, null, &.{});
    try std.testing.expectEqual(@as(f64, 11), imported.get().asNum());
    try std.testing.expect(context.unprotectValue(imported));
    const shared = try js.Context.createWith(heap.allocator(), .{ .enable_threads = true });
    defer shared.destroy();
    try std.testing.expectError(error.UnsupportedHostMode, shared.createHostValue(.undefined));
    var failing = std.testing.FailingAllocator.init(heap.allocator(), .{});
    const constrained = try js.Context.createWith(failing.allocator(), .{ .enable_gc = true, .heap_limit_bytes = 4 * 1024 * 1024 });
    defer constrained.destroy();
    const constrained_callback = try constrained.evaluateProtected("(function(){ return 42; })");
    defer _ = constrained.unprotectValue(constrained_callback);
    failing.fail_index = failing.alloc_index;
    const retained_before_oom = constrained.protected_values.items.len;
    try std.testing.expectError(error.OutOfMemory, constrained.callProtected(constrained_callback, null, &.{}));
    try std.testing.expectEqual(retained_before_oom, constrained.protected_values.items.len);
    failing.fail_index = std.math.maxInt(usize);
    const recovered = try constrained.callProtected(constrained_callback, null, &.{});
    try std.testing.expectEqual(@as(f64, 42), recovered.get().asNum());
    try std.testing.expect(constrained.unprotectValue(recovered));
    try std.testing.expectError(error.OutOfMemory, constrained.evaluateProtected("new Uint8Array(16 * 1024 * 1024)"));
    try std.testing.expect(constrained.heapBudgetStats().?.peak_bytes <= 4 * 1024 * 1024);
    const Probe = struct {
        fn wrongThread(ctx: *js.Context) !void {
            try std.testing.expectError(error.WrongThread, ctx.createHostValue(.undefined));
        }
        fn terminate(ctx: *js.Context, io: std.Io) void {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            ctx.requestTermination();
        }
    };
    const wrong_thread = try std.Thread.spawn(.{}, Probe.wrongThread, .{context});
    wrong_thread.join();
    const spinning = try context.evaluateProtected("(function(){ for (;;) {} })");
    defer _ = context.unprotectValue(spinning);
    const terminator = try std.Thread.spawn(.{}, Probe.terminate, .{ context, threaded.io() });
    defer terminator.join();
    try std.testing.expectError(error.Terminated, context.callProtected(spinning, null, &.{}));
    try std.testing.expectError(error.Terminated, context.callProtected(callback, null, &.{}));
    std.debug.print("hosted values: 100 retained frames, GC/compaction, typed buffer copy/mutation, receiver, 20 throws, invalid input, wrong thread and interruption passed\n", .{});
}
