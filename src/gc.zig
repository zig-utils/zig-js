//! The zig-js *binding* for the `zig-gc` precise tracing collector (issue #1
//! Phase 7; design in docs/threads/P7-gc-design.md). The collector
//! (`../zig-gc`) owns the mechanism; this file is the policy: how to enumerate
//! roots, how to trace each engine cell kind, and what to do when a cell dies.
//!
//! **Status: M1 — opt-in quiescent collection.** `Context.Options.enable_gc`
//! routes heap cells through `zig-gc`, and `Context.collectGarbage()` runs a
//! precise mark-sweep at quiescent points. Arbitrary mid-script collection and
//! some remaining side-storage migrations are still future work.
//!
//! Tracing surface and root set are derived from a full audit of the heap; see
//! the cell-kind table in P7-gc-design.md. Cells whose references all live in
//! `value.zig` (Object's own slots/proto/accessors) are traced here directly;
//! the type-erased side-cells (`js_func`→Function, `gen`→Generator, …) are cast
//! back to their concrete types and traced by the helpers below.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc");
const value = @import("value.zig");
const ast = @import("ast.zig");
const interp = @import("interpreter.zig");
const promise = @import("promise.zig");
const vm = @import("vm.zig");
const bytecode = @import("bytecode.zig");
const ContextMod = @import("context.zig");
const jsthread = @import("jsthread.zig");
const gc_runtime = @import("gc_runtime.zig");
const gc_relocation = @import("gc_relocation.zig");
const stack_scan = @import("stack_scan.zig");
const agent = @import("agent.zig");
const strcell = @import("strcell.zig");

const Value = value.Value;
const Object = value.Object;
const Shape = @import("shape.zig").Shape;
const Environment = interp.Environment;
const StringCell = strcell.StringCell;

var object_batch_cells_for_testing: std.atomic.Value(u64) = .init(0);
var relocation_verifications_for_testing: std.atomic.Value(u64) = .init(0);

pub fn objectBatchCellsForTesting() u64 {
    return object_batch_cells_for_testing.load(.monotonic);
}

pub fn relocationVerificationsForTesting() u64 {
    return relocation_verifications_for_testing.load(.monotonic);
}

/// The engine's GC cell taxonomy. Each `Heap.create(T, kind)` tags its cell so
/// `trace`/`finalize` dispatch without RTTI. AST nodes, bytecode chunks, and
/// `Shape`s are immutable and arena-permanent — they are *not* GC cells and
/// never appear here.
pub const CellKind = enum {
    object,
    string,
    environment,
    function,
    bound_fn,
    promise,
    generator,
    iter_helper,
    module_ns,
};

/// Mark a `Value` if it carries a heap reference. Objects always use the heap
/// in GC mode. Strings carry immutable ownership metadata because static,
/// arena, and intern-table cells intentionally coexist with managed cells.
pub inline fn markValue(v: anytype, val: Value) void {
    if (val.isObject()) {
        v.mark(val.asObj());
    } else if (val.isString()) {
        const cell = val.asStringCell();
        if (cell.isGcManaged()) v.mark(@constCast(cell));
    }
}

inline fn markValueOpt(v: anytype, val: ?Value) void {
    if (val) |x| markValue(v, x);
}

inline fn markWeakObject(v: anytype, slot: *?*Object) void {
    v.markWeak(@ptrCast(slot));
}

inline fn markManaged(v: anytype, cell: anytype) void {
    const Cell = @TypeOf(cell.*);
    if (Cell == interp.Environment) {
        if (cell.gc_managed) v.mark(cell);
        return;
    }
    if (Cell == promise.Promise) {
        if (cell.gc_owned) v.mark(cell);
        return;
    }
    @compileError("markManaged requires explicit ownership metadata for " ++ @typeName(Cell));
}

inline fn hasObjectBacking(flags: value.ObjectBackingFlags) bool {
    return flags.storage_state or
        flags.cold or
        flags.slots or
        flags.elements_state or
        flags.elements or
        flags.accessors or
        flags.key_order or
        flags.attrs or
        flags.holes or
        flags.weak_entries or
        flags.coll_index or
        flags.finalization_records or
        flags.typed_array or
        flags.data_view or
        flags.temporal or
        flags.arg_map_names or
        flags.arg_map_severed;
}

// ---- Per-kind tracers (public so a test binding can reuse them) -----------

/// Trace every strong reference out of an `Object`. WeakRef and WeakMap/WeakSet
/// keys are registered as weak edges so collection clears them when the target
/// is otherwise unreachable.
pub fn traceObject(o: *Object, v: anytype) void {
    // Single-word pointer fields. `proto` is the one that a *reachable* object's
    // mutator can rewrite post-creation (a `setPrototypeOf` reparent, which also
    // fires the insertion barrier to shade the new target); under a concurrent
    // mark we read it with a relaxed atomic load to be race-free per the memory
    // model (a plain mov on x86_64/arm64). The reparent sites pair this with an
    // atomic store. The construction link and proxy sidecar edges are written only at
    // creation, before the cell is published to the marker (the born-grey
    // hand-off establishes happens-before), so their payload reads are safe.
    // The cold pointer itself can also be installed lazily on an already-live
    // object, so snapshot it and all rare GC edges under `backing_lock`.
    const concurrent = v.concurrent();
    v.mark(if (concurrent) @atomicLoad(?*Object, &o.proto, .monotonic) else o.proto);
    const cold = o.traceColdSnapshot(concurrent);
    v.mark(cold.ctor_ref);
    v.mark(cold.proxy_target);
    v.mark(cold.proxy_handler);

    // Growable storage (slots/accessors behind `property_lock`, elements behind
    // `elements_lock`): under a *concurrent* mark (M3) the marker must read it
    // under the same lock the mutator takes, or a concurrent append/realloc
    // tears the slice. Under stop-the-world (M1) / GIL-held incremental (M2)
    // marking the world is quiescent during the read, so we skip the lock.
    if (concurrent) o.lockProperties();
    for (o.slotsItems()) |slot| markValue(v, slot);
    if (o.accessorsMap()) |acc| {
        var it = acc.valueIterator();
        while (it.next()) |a| {
            markValueOpt(v, a.get);
            markValueOpt(v, a.set);
            v.mark(a.descriptor_cell);
        }
    }
    if (o.cApiObjectOwner()) |owner| {
        var it = owner.custom_accessor_cells.valueIterator();
        while (it.next()) |cell| v.mark(cell.*);
    }
    if (concurrent) o.unlockProperties();

    if (o.is_weak and (o.is_map or o.is_set)) {
        // Weak collections register no interior weak slots here — keys are weak
        // (their liveness is read by `isLive` in the world-stopped finish pass,
        // `pruneDeadWeakEntries`) and values are ephemeron edges marked in
        // `traceObjectEphemeron` (also at finish). So `weak_entries` is never
        // read during the (possibly concurrent) mark — nothing tears against a
        // mutator append, and no `&entry.key` can dangle when the buffer grows.
    } else {
        if (concurrent) o.lockElements();
        for (o.elementsItems()) |el| markValue(v, el);
        if (concurrent) o.unlockElements();
    }
    markValueOpt(v, cold.boxed_primitive);
    markValueOpt(v, cold.async_context_callback);
    markValueOpt(v, cold.async_context);
    markValueOpt(v, cold.getter_setter_getter);
    markValueOpt(v, cold.getter_setter_setter);
    if (cold.weak_ref_target_slot) |slot| markWeakObject(v, slot); // stable cold-slot address
    if (o.behavior.is_finalization_registry) {
        if (cold.cold) |state| {
            markValue(v, state.finalization_callback);
            // Only `held` is a strong edge (mark it by value under the entry-storage
            // lock so a concurrent append can't tear the read). target/token are
            // weak — their liveness is decided by `isLive` at finish, not registered.
            if (concurrent) o.lockElements();
            if (state.finalization_records) |records|
                for (records.items) |*record| markValue(v, record.held);
            if (concurrent) o.unlockElements();
        }
    }

    // Type-erased side-cells.
    if (cold.js_function) |p| v.mark(@as(*interp.Function, @ptrCast(@alignCast(p))));
    if (cold.bound_function) |p| v.mark(@as(*interp.Interpreter.BoundFn, @ptrCast(@alignCast(p))));
    if (cold.promise_data) |p| v.mark(@as(*promise.Promise, @ptrCast(@alignCast(p))));
    if (cold.generator) |p| v.mark(@as(*vm.Generator, @ptrCast(@alignCast(p))));
    if (cold.iterator_helper) |p| v.mark(@as(*value.IterHelper, @ptrCast(@alignCast(p))));
    if (cold.module_ns) |p| v.mark(@as(*interp.ModuleNs, @ptrCast(@alignCast(p))));
    if (cold.arg_map_env) |p| v.mark(@as(*interp.Environment, @ptrCast(@alignCast(p))));
    promise.traceNativePrivateData(o, v);
    interp.traceNativePrivateData(o, v);
    jsthread.traceNativePrivateData(o, v);
    vm.traceNativePrivateData(o, v);
    // The viewed ArrayBuffer object keeps a TypedArray/DataView's storage alive.
    if (cold.typed_array) |ta| v.mark(ta.buffer);
    if (cold.data_view) |dv| v.mark(dv.buffer);
    // WebAssembly JS API rare-state edges (issue #141): the JS wrapper objects
    // keep their linked Module/exports/buffer/owner objects alive. The native
    // payload memory is registry-owned; live exception and GC-reference
    // wrappers trace the JavaScript values reachable through that memory.
    v.mark(cold.wasm.module_obj);
    for (cold.wasm.import_vals) |import_val| markValue(v, import_val);
    for (cold.wasm.table_refs) |*ref| markValue(v, .{ .bits = @constCast(ref).load(.acquire) });
    for (cold.wasm.global_refs) |ref| markValue(v, .{ .bits = ref.load(.acquire) });
    if (cold.wasm.global_ref) |ref| markValue(v, .{ .bits = ref.load(.acquire) });
    if (cold.wasm.exception) |exception| traceWasmException(v, exception);
    v.mark(cold.wasm.exports_obj);
    v.mark(cold.wasm.buffer_obj);
    v.mark(cold.wasm.owner_obj);
    if (cold.wasm.gc_ref) |reference| {
        const Marker = struct {
            fn mark(raw: *anyopaque, child: Value) void {
                const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                markValue(visitor, child);
            }
        };
        reference.trace(reference, @ptrCast(v), Marker.mark);
    }
    if (cold.wasm.gc_trace) |trace| if (cold.wasm.gc_trace_context) |trace_context| {
        const Marker = struct {
            fn mark(raw: *anyopaque, child: Value) void {
                const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                markValue(visitor, child);
            }
        };
        trace(trace_context, @ptrCast(v), Marker.mark);
    };
}

/// Rewrite the hot Object graph and property backing stores. Relocation is a
/// world-stopped commit: the backing, property, and element containers cannot
/// grow while this runs, and taking their mutator locks would be both redundant
/// and unsafe if a parked thread owned one. Weak collection elements are not
/// ordinary strong edges and are handled by #345 after weak liveness is final.
pub fn relocateObjectProperties(o: *Object, v: anytype) void {
    gc_relocation.rewriteOptionalSlot(v, Object, &o.proto);
    for (o.slotsItems()) |*slot| gc_relocation.rewriteValueSlot(v, slot);
    if (o.accessorsMap()) |accessors| {
        var it = accessors.valueIterator();
        while (it.next()) |accessor| {
            gc_relocation.rewriteOptionalValueSlot(v, &accessor.get);
            gc_relocation.rewriteOptionalValueSlot(v, &accessor.set);
            gc_relocation.rewriteOptionalSlot(v, Object, &accessor.descriptor_cell);
        }
    }
    if (o.cApiObjectOwner()) |owner| {
        var it = owner.custom_accessor_cells.valueIterator();
        while (it.next()) |cell|
            gc_relocation.rewriteRequiredSlot(v, Object, cell);
    }
    if (!(o.is_weak and (o.is_map or o.is_set)))
        for (o.elementsItems()) |*element| gc_relocation.rewriteValueSlot(v, element);
}

/// Rewrite the actual cold/rare union storage, never `TraceColdSnapshot` (which
/// is a by-value marker view). Weak/finalization and native/Wasm callbacks have
/// ordered semantics and remain isolated for #345.
pub fn relocateObjectRareStrong(o: *Object, v: anytype) void {
    if (o.behavior.is_getter_setter and !o.behavior.is_custom_getter_setter) {
        gc_relocation.rewriteValueSlot(v, &o.inline_slots[0]);
        gc_relocation.rewriteValueSlot(v, &o.inline_slots[1]);
    }
    const cold = o.coldState() orelse return;
    gc_relocation.rewriteOptionalSlot(v, anyopaque, &cold.arg_map_env);
    switch (cold.rare_tag.load(.acquire)) {
        .boxed_primitive => gc_relocation.rewriteValueSlot(v, &cold.rare.boxed_primitive.value),
        .module_ns => gc_relocation.rewriteOptionalSlot(v, anyopaque, &cold.rare.module_ns.ptr),
        .generator => gc_relocation.rewriteOptionalSlot(v, anyopaque, &cold.rare.generator.ptr),
        .iter_helper => gc_relocation.rewriteOptionalSlot(v, value.IterHelper, &cold.rare.iter_helper.ptr),
        .bound_function => gc_relocation.rewriteOptionalSlot(v, anyopaque, &cold.rare.bound_function.ptr),
        .async_context_frame => {
            gc_relocation.rewriteValueSlot(v, &cold.rare.async_context_frame.callback);
            gc_relocation.rewriteValueSlot(v, &cold.rare.async_context_frame.context);
        },
        .proxy => {
            gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.proxy.target);
            gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.proxy.handler);
        },
        .buffer_view => {
            if (cold.rare.buffer_view.typed_array) |typed|
                gc_relocation.rewriteRequiredSlot(v, Object, &typed.buffer);
            if (cold.rare.buffer_view.data_view) |data_view|
                gc_relocation.rewriteRequiredSlot(v, Object, &data_view.buffer);
        },
        .promise => gc_relocation.rewriteOptionalSlot(v, anyopaque, &cold.rare.promise.ptr),
        .constructor => gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.constructor.ptr),
        .js_function => gc_relocation.rewriteOptionalSlot(v, anyopaque, &cold.rare.js_function.ptr),
        .none,
        .primitive,
        .error_state,
        .date,
        .weak_ref,
        .host_callback,
        .temporal,
        .sparse_array,
        .regex,
        .wasm_module,
        .wasm_instance,
        .wasm_memory,
        .wasm_table,
        .wasm_global,
        .wasm_function,
        .wasm_tag,
        .wasm_exception,
        .wasm_gc_ref,
        => {},
    }
}

test "Object property relocation covers inline external accessor and dense storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root_shape = try Shape.createRoot(allocator);
    var old_objects: [16]Object = undefined;
    var new_objects: [16]Object = undefined;

    var external = Object{ .proto = &old_objects[5] };
    for ([_][]const u8{ "a", "b", "c", "d", "e" }, 0..) |name, index|
        try external.setOwn(allocator, root_shape, name, Value.obj(&old_objects[index]));
    try external.appendElement(allocator, Value.obj(&old_objects[6]));
    try external.appendElement(allocator, Value.obj(&old_objects[7]));
    try external.setAccessor(
        allocator,
        "accessor",
        Value.obj(&old_objects[8]),
        Value.obj(&old_objects[9]),
    );
    _ = external.installAccessorDescriptorCell(
        "accessor",
        Value.obj(&old_objects[8]),
        Value.obj(&old_objects[9]),
        &old_objects[10],
    );
    const Owner = value.CApiObjectOwner;
    const finishOwner = struct {
        fn finish(_: *Owner) void {}
    }.finish;
    var owner = Owner{
        .allocator = allocator,
        .class_ref = null,
        .finish_fn = finishOwner,
    };
    try external.setCApiObjectOwner(allocator, &owner);
    _ = try external.installCustomAccessorDescriptorCell("custom", &old_objects[11]);

    var inline_shape = Shape{
        .parent = null,
        .name = "b",
        .slot = 1,
        .count = 2,
        .arena = allocator,
    };
    var inline_object = Object{
        .shape = &inline_shape,
        .proto = &old_objects[14],
    };
    inline_object.inline_slots[0] = Value.obj(&old_objects[12]);
    inline_object.inline_slots[1] = Value.obj(&old_objects[13]);

    var weak_map = Object{ .is_weak = true, .is_map = true };
    try weak_map.appendElement(allocator, Value.obj(&old_objects[15]));

    const external_shape = external.shape;
    const external_storage = external.storageState();
    const accessor_storage = external.accessorsMap();
    const element_storage = external.elementsState();
    const inline_shape_pointer = inline_object.shape;

    const Plan = struct {
        old_objects: *[16]Object,
        new_objects: *[16]Object,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            return old;
        }
    };
    const plan = Plan{ .old_objects = &old_objects, .new_objects = &new_objects };
    relocateObjectProperties(&external, &plan);
    relocateObjectProperties(&inline_object, &plan);
    relocateObjectProperties(&weak_map, &plan);

    try std.testing.expectEqual(&new_objects[5], external.proto.?);
    for (external.slotsItems(), 0..) |slot, index|
        try std.testing.expectEqual(&new_objects[index], slot.asObj());
    try std.testing.expectEqual(&new_objects[6], external.elementsItems()[0].asObj());
    try std.testing.expectEqual(&new_objects[7], external.elementsItems()[1].asObj());
    const accessor = external.getAccessor("accessor").?;
    try std.testing.expectEqual(&new_objects[8], accessor.get.?.asObj());
    try std.testing.expectEqual(&new_objects[9], accessor.set.?.asObj());
    try std.testing.expectEqual(&new_objects[10], accessor.descriptor_cell.?);
    try std.testing.expectEqual(&new_objects[11], external.customAccessorDescriptorCell("custom").?);
    try std.testing.expectEqual(&new_objects[14], inline_object.proto.?);
    try std.testing.expectEqual(&new_objects[12], inline_object.slotsItems()[0].asObj());
    try std.testing.expectEqual(&new_objects[13], inline_object.slotsItems()[1].asObj());
    try std.testing.expectEqual(&old_objects[15], weak_map.elementsItems()[0].asObj());
    try std.testing.expectEqual(external_shape, external.shape);
    try std.testing.expectEqual(external_storage, external.storageState());
    try std.testing.expectEqual(accessor_storage, external.accessorsMap());
    try std.testing.expectEqual(element_storage, external.elementsState());
    try std.testing.expectEqual(&owner, external.cApiObjectOwner().?);
    try std.testing.expectEqual(inline_shape_pointer, inline_object.shape);
}

test "Object rare strong relocation mutates every active managed payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var old_objects: [8]Object = undefined;
    var new_objects: [8]Object = undefined;
    var rare_objects: [12]Object = undefined;
    for (&rare_objects) |*object| object.* = .{};
    var old_environment: Environment = undefined;
    var new_environment: Environment = undefined;
    var old_module_namespace: interp.ModuleNs = undefined;
    var new_module_namespace: interp.ModuleNs = undefined;
    var old_generator: vm.Generator = undefined;
    var new_generator: vm.Generator = undefined;
    var old_helper: value.IterHelper = undefined;
    var new_helper: value.IterHelper = undefined;
    var old_bound: interp.Interpreter.BoundFn = undefined;
    var new_bound: interp.Interpreter.BoundFn = undefined;
    var old_promise: promise.Promise = undefined;
    var new_promise: promise.Promise = undefined;
    var old_function: interp.Function = undefined;
    var new_function: interp.Function = undefined;

    try rare_objects[0].setBoxedPrimitive(allocator, Value.obj(&old_objects[0]));
    rare_objects[0].coldState().?.arg_map_env = @ptrCast(&old_environment);
    try rare_objects[1].setModuleNs(allocator, @ptrCast(&old_module_namespace));
    try rare_objects[2].setGenerator(allocator, @ptrCast(&old_generator));
    try rare_objects[3].setIteratorHelper(allocator, &old_helper);
    try rare_objects[4].setBoundFunction(allocator, @ptrCast(&old_bound));
    try rare_objects[5].setProxyState(allocator, &old_objects[1], &old_objects[2]);
    var array_buffer: value.ArrayBufferData = undefined;
    var typed_array = value.TypedArrayData{
        .buffer = &old_objects[3],
        .byte_offset = 0,
        .length = 0,
        .kind = .u8,
    };
    var data_view = value.DataViewData{
        .buffer = &old_objects[4],
        .byte_offset = 0,
        .byte_length = 0,
    };
    try rare_objects[6].setArrayBuffer(allocator, &array_buffer);
    try rare_objects[6].setTypedArray(allocator, &typed_array);
    try rare_objects[6].setDataView(allocator, &data_view);
    try rare_objects[7].setPromiseData(allocator, @ptrCast(&old_promise));
    try rare_objects[8].setCtorRef(allocator, &old_objects[5]);
    try rare_objects[9].setJsFunction(allocator, @ptrCast(&old_function));
    rare_objects[10].setGetterSetterCellData(.ordinary(
        Value.obj(&old_objects[6]),
        Value.obj(&old_objects[7]),
    ));
    try rare_objects[11].setAsyncContextFrame(
        allocator,
        Value.obj(&old_objects[0]),
        Value.obj(&old_objects[7]),
    );

    const Plan = struct {
        old_objects: *[8]Object,
        new_objects: *[8]Object,
        old_environment: *Environment,
        new_environment: *Environment,
        old_module_namespace: *interp.ModuleNs,
        new_module_namespace: *interp.ModuleNs,
        old_generator: *vm.Generator,
        new_generator: *vm.Generator,
        old_helper: *value.IterHelper,
        new_helper: *value.IterHelper,
        old_bound: *interp.Interpreter.BoundFn,
        new_bound: *interp.Interpreter.BoundFn,
        old_promise: *promise.Promise,
        new_promise: *promise.Promise,
        old_function: *interp.Function,
        new_function: *interp.Function,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            inline for (.{
                .{ self.old_environment, self.new_environment },
                .{ self.old_module_namespace, self.new_module_namespace },
                .{ self.old_generator, self.new_generator },
                .{ self.old_helper, self.new_helper },
                .{ self.old_bound, self.new_bound },
                .{ self.old_promise, self.new_promise },
                .{ self.old_function, self.new_function },
            }) |pair|
                if (old == @as(*anyopaque, @ptrCast(pair[0]))) return @ptrCast(pair[1]);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_environment = &old_environment,
        .new_environment = &new_environment,
        .old_module_namespace = &old_module_namespace,
        .new_module_namespace = &new_module_namespace,
        .old_generator = &old_generator,
        .new_generator = &new_generator,
        .old_helper = &old_helper,
        .new_helper = &new_helper,
        .old_bound = &old_bound,
        .new_bound = &new_bound,
        .old_promise = &old_promise,
        .new_promise = &new_promise,
        .old_function = &old_function,
        .new_function = &new_function,
    };
    for (&rare_objects) |*object| relocateObjectRareStrong(object, &plan);

    try std.testing.expectEqual(&new_objects[0], rare_objects[0].boxedPrimitive().?.asObj());
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&new_environment)), rare_objects[0].coldState().?.arg_map_env);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_module_namespace)), rare_objects[1].moduleNs().?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_generator)), rare_objects[2].generator().?);
    try std.testing.expectEqual(&new_helper, rare_objects[3].iteratorHelper().?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_bound)), rare_objects[4].boundFunction().?);
    try std.testing.expectEqual(&new_objects[1], rare_objects[5].proxyTarget().?);
    try std.testing.expectEqual(&new_objects[2], rare_objects[5].proxyHandler().?);
    try std.testing.expectEqual(&array_buffer, rare_objects[6].arrayBuffer().?);
    try std.testing.expectEqual(&new_objects[3], rare_objects[6].typedArray().?.buffer);
    try std.testing.expectEqual(&new_objects[4], rare_objects[6].dataView().?.buffer);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_promise)), rare_objects[7].promiseData().?);
    try std.testing.expectEqual(&new_objects[5], rare_objects[8].ctorRef().?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_function)), rare_objects[9].jsFunction().?);
    const getter_setter = rare_objects[10].getterSetterCellData().?;
    try std.testing.expectEqual(&new_objects[6], getter_setter.getterValue().?.asObj());
    try std.testing.expectEqual(&new_objects[7], getter_setter.setterValue().?.asObj());
    const async_context_frame = rare_objects[11].asyncContextFrame().?;
    try std.testing.expectEqual(&new_objects[0], async_context_frame.callback.asObj());
    try std.testing.expectEqual(&new_objects[7], async_context_frame.context.asObj());
}

test "Wasm relocation: Object rare state rewrites every JavaScript-bearing slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var old_objects: [19]Object = undefined;
    var new_objects: [19]Object = undefined;
    var wrappers: [8]Object = undefined;
    for (&wrappers) |*wrapper| wrapper.* = .{};

    var instance_imports = [_]Value{Value.obj(&old_objects[1])};
    var instance_global = std.atomic.Value(u64).init(Value.obj(&old_objects[3]).rawBits());
    var instance_global_refs = [_]*std.atomic.Value(u64){&instance_global};
    var instance_hidden = Value.obj(&old_objects[4]);
    const HiddenRoots = struct {
        fn trace(raw: *anyopaque, visitor: *anyopaque, mark: value.WasmGcMarkValueFn) void {
            const slot: *Value = @ptrCast(@alignCast(raw));
            mark(visitor, slot.*);
        }

        fn relocate(raw: *anyopaque, visitor: *anyopaque, rewrite: value.WasmGcRewriteValueFn) void {
            const slot: *Value = @ptrCast(@alignCast(raw));
            rewrite(visitor, slot);
        }
    };
    var instance_gc = value.WasmInstanceGcState{
        .global_refs = &instance_global_refs,
        .context = &instance_hidden,
        .trace = HiddenRoots.trace,
        .relocate = HiddenRoots.relocate,
    };
    const instance = try wrappers[0].wasmInstanceState(allocator);
    instance.module_obj = &old_objects[0];
    instance.import_vals = &instance_imports;
    instance.exports_obj = &old_objects[2];
    instance.gc_state = &instance_gc;

    const memory = try wrappers[1].wasmMemoryState(allocator);
    memory.buffer_obj = &old_objects[5];
    memory.owner_obj = &old_objects[6];

    var table_ref = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(Value.obj(&old_objects[7]).rawBits())};
    const table = try wrappers[2].wasmTableState(allocator);
    table.refs = &table_ref;
    table.owner_obj = &old_objects[8];

    var global_ref = std.atomic.Value(u64).init(Value.obj(&old_objects[9]).rawBits());
    const global = try wrappers[3].wasmGlobalState(allocator);
    global.ref = &global_ref;
    global.owner_obj = &old_objects[10];
    (try wrappers[4].wasmFunctionState(allocator)).owner_obj = &old_objects[11];
    (try wrappers[5].wasmTagState(allocator)).owner_obj = &old_objects[12];

    var payload_values = [_]Value{Value.obj(&old_objects[13])};
    var exception_payload = [_]value.WasmSlot{.{ .externref = Value.obj(&old_objects[14]) }};
    var exception_externrefs = [_]Value{Value.obj(&old_objects[14])};
    var dummy_tag: u8 = 0;
    var dummy_owner: u8 = 0;
    var exception = value.WasmException{
        .tag = &dummy_tag,
        .payload = &exception_payload,
        .externrefs = &exception_externrefs,
        .owner = &dummy_owner,
        .wrapper = .init(&old_objects[15]),
        .js_exception = Value.obj(&old_objects[16]),
        .is_js_exception = true,
    };
    const exception_state = try wrappers[6].wasmExceptionState(allocator);
    exception_state.exception = &exception;
    exception_state.payload_values = &payload_values;
    exception_state.owner_obj = &old_objects[17];

    var aggregate_hidden = Value.obj(&old_objects[18]);
    const Aggregate = struct {
        fn trace(reference: *value.WasmGcRef, visitor: *anyopaque, mark: value.WasmGcMarkValueFn) void {
            const slot: *Value = @ptrCast(@alignCast(reference.context));
            mark(visitor, slot.*);
        }

        fn relocate(reference: *value.WasmGcRef, visitor: *anyopaque, rewrite: value.WasmGcRewriteValueFn) void {
            const slot: *Value = @ptrCast(@alignCast(reference.context));
            rewrite(visitor, slot);
        }
    };
    var aggregate = value.WasmGcRef{
        .context = &aggregate_hidden,
        .trace = Aggregate.trace,
        .relocate = Aggregate.relocate,
    };
    (try wrappers[7].wasmGcReferenceState(allocator)).reference = &aggregate;

    const Plan = struct {
        old_objects: *[19]Object,
        new_objects: *[19]Object,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            return old;
        }
    };
    const plan = Plan{ .old_objects = &old_objects, .new_objects = &new_objects };
    for (&wrappers) |*wrapper| relocateObjectWasmState(wrapper, &plan);

    try std.testing.expectEqual(&new_objects[0], instance.module_obj.?);
    try std.testing.expectEqual(&new_objects[1], instance_imports[0].asObj());
    try std.testing.expectEqual(&new_objects[2], instance.exports_obj.?);
    try std.testing.expectEqual(&new_objects[3], Value.fromRawBits(instance_global.load(.acquire)).asObj());
    try std.testing.expectEqual(&new_objects[4], instance_hidden.asObj());
    try std.testing.expectEqual(&new_objects[5], memory.buffer_obj.?);
    try std.testing.expectEqual(&new_objects[6], memory.owner_obj.?);
    try std.testing.expectEqual(&new_objects[7], Value.fromRawBits(table_ref[0].load(.acquire)).asObj());
    try std.testing.expectEqual(&new_objects[8], table.owner_obj.?);
    try std.testing.expectEqual(&new_objects[9], Value.fromRawBits(global_ref.load(.acquire)).asObj());
    try std.testing.expectEqual(&new_objects[10], global.owner_obj.?);
    try std.testing.expectEqual(&new_objects[11], wrappers[4].wasmFunction().?.owner_obj.?);
    try std.testing.expectEqual(&new_objects[12], wrappers[5].wasmTag().?.owner_obj.?);
    try std.testing.expectEqual(&new_objects[13], payload_values[0].asObj());
    try std.testing.expectEqual(&new_objects[14], exception_payload[0].externref.asObj());
    try std.testing.expectEqual(&new_objects[14], exception_externrefs[0].asObj());
    try std.testing.expectEqual(&new_objects[15], exception.wrapper.load(.acquire).?);
    try std.testing.expectEqual(&new_objects[16], exception.js_exception.asObj());
    try std.testing.expectEqual(&new_objects[17], exception_state.owner_obj.?);
    try std.testing.expectEqual(&new_objects[18], aggregate_hidden.asObj());
}

fn traceWasmException(v: anytype, exception: *const value.WasmException) void {
    const Marker = struct {
        fn mark(raw: *anyopaque, child: Value) void {
            const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
            markValue(visitor, child);
        }
    };
    if (exception.wrapper.load(.acquire)) |wrapper| v.mark(wrapper);
    if (exception.is_js_exception) markValue(v, exception.js_exception);
    for (exception.externrefs) |root| markValue(v, root);
    for (exception.payload) |slot| switch (slot) {
        .externref, .hostref => |root| markValue(v, root),
        .gcref => |reference| if (reference) |root| root.trace(root, @ptrCast(v), Marker.mark),
        .externalized_gcref => |root| root.trace(root, @ptrCast(v), Marker.mark),
        .exnref => |nested| if (nested) |child| traceWasmException(v, child),
        .numeric, .vector, .funcref, .i31ref, .externalized_i31 => {},
    };
}

fn relocateWasmException(v: anytype, exception: *value.WasmException) void {
    const Rewriter = struct {
        fn rewrite(raw: *anyopaque, slot: *Value) void {
            const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
            gc_relocation.rewriteValueSlot(visitor, slot);
        }
    };
    if (exception.wrapper.load(.acquire)) |wrapper| {
        var wrapped = Value.obj(wrapper);
        gc_relocation.rewriteValueSlot(v, &wrapped);
        exception.wrapper.store(wrapped.asObj(), .release);
    }
    if (exception.is_js_exception)
        gc_relocation.rewriteValueSlot(v, &exception.js_exception);
    for (@constCast(exception.externrefs)) |*root|
        gc_relocation.rewriteValueSlot(v, root);
    for (@constCast(exception.payload)) |*slot| switch (slot.*) {
        .externref, .hostref => |*root| gc_relocation.rewriteValueSlot(v, root),
        .gcref => |reference| if (reference) |root|
            root.relocate(root, @ptrCast(@constCast(v)), Rewriter.rewrite),
        .externalized_gcref => |root| root.relocate(root, @ptrCast(@constCast(v)), Rewriter.rewrite),
        .exnref => |nested| if (nested) |child| relocateWasmException(v, child),
        .numeric, .vector, .funcref, .i31ref, .externalized_i31 => {},
    };
}

pub fn relocateObjectWasmState(o: *Object, v: anytype) void {
    const cold = o.coldState() orelse return;
    const Rewriter = struct {
        fn rewrite(raw: *anyopaque, slot: *Value) void {
            const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
            gc_relocation.rewriteValueSlot(visitor, slot);
        }
    };
    switch (cold.rare_tag.load(.acquire)) {
        .wasm_instance => {
            const state = &cold.rare.wasm_instance;
            gc_relocation.rewriteOptionalSlot(v, Object, &state.module_obj);
            for (@constCast(state.import_vals)) |*import_value|
                gc_relocation.rewriteValueSlot(v, import_value);
            gc_relocation.rewriteOptionalSlot(v, Object, &state.exports_obj);
            if (state.gc_state) |gc_state| {
                for (gc_state.global_refs) |reference|
                    gc_relocation.rewriteAtomicValueSlot(v, reference);
                if (gc_state.relocate) |relocate| if (gc_state.context) |context|
                    relocate(context, @ptrCast(@constCast(v)), Rewriter.rewrite);
            }
        },
        .wasm_memory => {
            gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.wasm_memory.buffer_obj);
            gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.wasm_memory.owner_obj);
        },
        .wasm_table => {
            const state = &cold.rare.wasm_table;
            for (@constCast(state.refs)) |*reference|
                gc_relocation.rewriteAtomicValueSlot(v, reference);
            gc_relocation.rewriteOptionalSlot(v, Object, &state.owner_obj);
            if (state.gc_relocate) |relocate| if (state.gc_context) |gc_context|
                relocate(gc_context, @ptrCast(@constCast(v)), Rewriter.rewrite);
        },
        .wasm_global => {
            const state = &cold.rare.wasm_global;
            if (state.ref) |reference|
                gc_relocation.rewriteAtomicValueSlot(v, reference);
            gc_relocation.rewriteOptionalSlot(v, Object, &state.owner_obj);
            if (state.gc_relocate) |relocate| if (state.gc_context) |gc_context|
                relocate(gc_context, @ptrCast(@constCast(v)), Rewriter.rewrite);
        },
        .wasm_function => gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.wasm_function.owner_obj),
        .wasm_tag => gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.wasm_tag.owner_obj),
        .wasm_exception => {
            const state = &cold.rare.wasm_exception;
            for (@constCast(state.payload_values)) |*payload|
                gc_relocation.rewriteValueSlot(v, payload);
            if (state.exception) |exception| relocateWasmException(v, exception);
            gc_relocation.rewriteOptionalSlot(v, Object, &state.owner_obj);
        },
        .wasm_gc_ref => if (cold.rare.wasm_gc_ref.reference) |reference|
            reference.relocate(reference, @ptrCast(@constCast(v)), Rewriter.rewrite),
        .none,
        .primitive,
        .error_state,
        .date,
        .module_ns,
        .weak_ref,
        .host_callback,
        .boxed_primitive,
        .generator,
        .iter_helper,
        .bound_function,
        .async_context_frame,
        .proxy,
        .buffer_view,
        .temporal,
        .promise,
        .constructor,
        .sparse_array,
        .js_function,
        .regex,
        .wasm_module,
        => {},
    }
}

pub fn traceObjectEphemeron(o: *Object, v: anytype) void {
    if (!(o.is_weak and o.is_map)) return;
    const cold = o.coldState() orelse return;
    for (cold.weak_entries.items) |entry| {
        if (v.isMarked(entry.key)) markValue(v, entry.value);
    }
}

/// World-stopped finish pass (afterWeak): drop weak entries whose key died and
/// mark finalization records whose target died as ready. Liveness is read
/// directly from `heap.isLive` (the mark bit) rather than from a pre-registered
/// interior weak slot — so this is correct even when the mark ran concurrently
/// with a mutator that grew `weak_entries`/`finalization_records`. Behaviorally
/// identical to the old markWeak-then-null-then-prune for the stop-the-world and
/// GIL-held paths (a dead key/target is exactly an unmarked managed cell).
pub fn pruneDeadWeakEntries(o: *Object, heap: anytype) bool {
    if (!(o.is_weak and (o.is_map or o.is_set)) and !o.behavior.is_finalization_registry) return false;
    o.lockElements();
    defer o.unlockElements();

    var cleanup_ready = false;
    if (o.is_weak and (o.is_map or o.is_set)) {
        const cold = o.coldState() orelse return false;
        var i: usize = 0;
        while (i < cold.weak_entries.items.len) {
            if (!heap.isLive(cold.weak_entries.items[i].key)) {
                o.weakEntrySwapRemoveAtUnlocked(i);
            } else {
                i += 1;
            }
        }
    }
    if (o.behavior.is_finalization_registry) {
        const cold = o.coldState() orelse return cleanup_ready;
        const records = cold.finalization_records orelse return cleanup_ready;
        for (records.items) |*record| {
            // Once a record is ready, its target may have been swept in an
            // earlier cycle; never ask the heap about that stale pointer again.
            if (!record.ready and !heap.isLive(record.target)) {
                record.ready = true;
                record.target = null;
                cleanup_ready = true;
            }
            // A dead unregister token can never match a future unregister; drop it.
            if (record.token != null and !heap.isLive(record.token)) record.token = null;
        }
    }
    return cleanup_ready;
}

/// Run after weak clearing/pruning and sweep, before old live payloads are
/// released. Every remaining weak key/target/token is live; ready finalization
/// targets are null so a swept address is never offered to the forwarding map.
pub fn relocateObjectWeakState(o: *Object, v: anytype) void {
    const cold = o.coldState() orelse return;
    if (cold.hasRare(.weak_ref))
        gc_relocation.rewriteOptionalSlot(v, Object, &cold.rare.weak_ref.target);
    if (o.is_weak and (o.is_map or o.is_set)) {
        // The pointer-keyed lookup table is only a cache; clear its old-address
        // keys. Linear lookup remains correct and later mutations repopulate it.
        cold.weak_index.clearRetainingCapacity();
        for (cold.weak_entries.items) |*entry| {
            gc_relocation.rewriteOptionalSlot(v, anyopaque, &entry.key);
            gc_relocation.rewriteValueSlot(v, &entry.value);
        }
    }
    if (!o.behavior.is_finalization_registry) return;
    gc_relocation.rewriteValueSlot(v, &cold.finalization_callback);
    if (cold.finalization_records) |records| for (records.items) |*record| {
        if (record.ready) {
            // A ready record's target was swept before relocation.
            record.target = null;
        } else {
            gc_relocation.rewriteOptionalSlot(v, anyopaque, &record.target);
        }
        gc_relocation.rewriteValueSlot(v, &record.held);
        gc_relocation.rewriteOptionalSlot(v, anyopaque, &record.token);
    };
}

pub fn relocateObjectNativePrivateData(o: *Object, v: anytype) void {
    promise.relocateNativePrivateData(o, v);
    interp.relocateNativePrivateData(o, v);
    jsthread.relocateNativePrivateData(o, v);
    vm.relocateNativePrivateData(o, v);
}

/// Complete Object-cell rewrite in the same semantic layers as `traceObject`.
/// Weak pruning runs before the collector enters relocation, so the weak pass
/// only rewrites live targets (or already-cleared finalization targets).
pub fn relocateObject(o: *Object, v: anytype) void {
    relocateObjectProperties(o, v);
    relocateObjectRareStrong(o, v);
    relocateObjectWeakState(o, v);
    relocateObjectNativePrivateData(o, v);
    relocateObjectWasmState(o, v);
}

/// StringCell payloads contain bytes/ownership metadata but no managed edge.
pub fn relocateString(_: *StringCell, _: anytype) void {}

test "weak and finalization relocation never resolves dead targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var old_objects: [10]Object = undefined;
    var new_objects: [10]Object = undefined;

    var weak_ref = Object{ .behavior = .{ .is_weak_ref = true } };
    try weak_ref.setWeakRefTarget(allocator, &old_objects[0]);
    var weak_map = Object{ .is_weak = true, .is_map = true };
    try weak_map.weakEntrySet(
        allocator,
        @ptrCast(&old_objects[1]),
        Value.obj(&old_objects[2]),
    );
    try std.testing.expect(weak_map.coldState().?.weak_index.count() > 0);

    var registry = Object{ .behavior = .{ .is_finalization_registry = true } };
    try registry.finRecordAppend(allocator, .{
        .target = @ptrCast(&old_objects[3]),
        .held = Value.obj(&old_objects[4]),
        .token = @ptrCast(&old_objects[5]),
    });
    try registry.finRecordAppend(allocator, .{
        .target = @ptrCast(&old_objects[6]),
        .held = Value.obj(&old_objects[7]),
        .token = @ptrCast(&old_objects[8]),
    });
    registry.coldState().?.finalization_callback = Value.obj(&old_objects[9]);

    const Liveness = struct {
        dead_target: *Object,
        dead_token: *Object,

        pub fn isLive(self: *const @This(), cell: ?*anyopaque) bool {
            const pointer = cell orelse return false;
            return pointer != @as(*anyopaque, @ptrCast(self.dead_target)) and
                pointer != @as(*anyopaque, @ptrCast(self.dead_token));
        }
    };
    const liveness = Liveness{
        .dead_target = &old_objects[6],
        .dead_token = &old_objects[8],
    };
    try std.testing.expect(pruneDeadWeakEntries(&registry, &liveness));
    const records = registry.coldState().?.finalization_records.?;
    try std.testing.expect(!records.items[0].ready);
    try std.testing.expect(records.items[1].ready);
    try std.testing.expectEqual(@as(?*anyopaque, null), records.items[1].target);
    try std.testing.expectEqual(@as(?*anyopaque, null), records.items[1].token);

    const Plan = struct {
        old_objects: *[10]Object,
        new_objects: *[10]Object,
        forbidden: *Object,
        resolved_forbidden: bool = false,

        pub fn resolve(self: *@This(), old: *anyopaque) *anyopaque {
            if (old == @as(*anyopaque, @ptrCast(self.forbidden))) {
                self.resolved_forbidden = true;
                return @ptrCast(&self.new_objects[6]);
            }
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            return old;
        }
    };
    var plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .forbidden = &old_objects[6],
    };
    relocateObjectWeakState(&weak_ref, &plan);
    relocateObjectWeakState(&weak_map, &plan);
    relocateObjectWeakState(&registry, &plan);

    try std.testing.expectEqual(&new_objects[0], weak_ref.weakRefTarget().?);
    const weak_entry = weak_map.coldState().?.weak_entries.items[0];
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_objects[1])), weak_entry.key.?);
    try std.testing.expectEqual(&new_objects[2], weak_entry.value.asObj());
    try std.testing.expectEqual(@as(usize, 0), weak_map.coldState().?.weak_index.count());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_objects[3])), records.items[0].target.?);
    try std.testing.expectEqual(&new_objects[4], records.items[0].held.asObj());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_objects[5])), records.items[0].token.?);
    try std.testing.expectEqual(@as(?*anyopaque, null), records.items[1].target);
    try std.testing.expectEqual(&new_objects[7], records.items[1].held.asObj());
    try std.testing.expectEqual(@as(?*anyopaque, null), records.items[1].token);
    try std.testing.expectEqual(&new_objects[9], registry.finalizationCallback().asObj());
    try std.testing.expect(!plan.resolved_forbidden);
}

pub fn traceEnv(e: *Environment, v: anytype) void {
    // `vars`/`disposables`/`aliases` are mutated by binding writes; under a
    // concurrent mark read them under the same `binding_lock` those writers take
    // (or a `put` rehash / append could tear the iteration). `parent`/`with_object`
    // are set at env creation and never rewritten, so they need no lock.
    const concurrent = v.concurrent();
    if (concurrent) e.lockBindings();
    var vit = e.vars.valueIterator();
    while (vit.next()) |val| markValue(v, val.*);
    for (e.disposables.items) |d| {
        markValue(v, d.value);
        markValue(v, d.method);
    }
    if (e.dispose_pending) |pending| markValue(v, pending);
    var ait = e.aliases.valueIterator();
    while (ait.next()) |a| markManaged(v, a.env);
    if (e.object_proto_intrinsic) |o| v.mark(o);
    if (concurrent) e.unlockBindings();
    if (e.parent) |p| markManaged(v, p);
    if (e.with_object) |o| v.mark(o);
}

/// Relocation is committed only while every mutator is stopped, so the
/// arena/backing-owned hash tables and disposable list are stable and must not
/// take `binding_lock` while their payload slots are rewritten.
pub fn relocateEnv(e: *Environment, v: anytype) void {
    var values = e.vars.valueIterator();
    while (values.next()) |slot| gc_relocation.rewriteValueSlot(v, slot);
    for (e.disposables.items) |*disposable| {
        gc_relocation.rewriteValueSlot(v, &disposable.value);
        gc_relocation.rewriteValueSlot(v, &disposable.method);
    }
    gc_relocation.rewriteOptionalValueSlot(v, &e.dispose_pending);
    var aliases = e.aliases.valueIterator();
    while (aliases.next()) |alias|
        gc_relocation.rewriteRequiredSlot(v, Environment, &alias.env);
    gc_relocation.rewriteOptionalSlot(v, Object, &e.object_proto_intrinsic);
    gc_relocation.rewriteOptionalSlot(v, Environment, &e.parent);
    gc_relocation.rewriteOptionalSlot(v, Object, &e.with_object);
}

test "Environment relocation rewrites every managed binding slot" {
    var old_objects: [6]Object = undefined;
    var new_objects: [6]Object = undefined;
    var old_environments = [_]Environment{
        .{ .arena = std.testing.allocator, .gc_managed = true },
        .{ .arena = std.testing.allocator, .gc_managed = true },
    };
    var new_environments = [_]Environment{
        .{ .arena = std.testing.allocator, .gc_managed = true },
        .{ .arena = std.testing.allocator, .gc_managed = true },
    };
    var environment = Environment{
        .arena = std.testing.allocator,
        .gc_managed = true,
        .dispose_pending = Value.obj(&old_objects[3]),
        .object_proto_intrinsic = &old_objects[4],
        .parent = &old_environments[0],
        .with_object = &old_objects[5],
    };
    defer environment.vars.deinit(std.testing.allocator);
    defer environment.disposables.deinit(std.testing.allocator);
    defer environment.aliases.deinit(std.testing.allocator);
    try environment.vars.put(std.testing.allocator, "binding", Value.obj(&old_objects[0]));
    try environment.disposables.append(std.testing.allocator, .{
        .value = Value.obj(&old_objects[1]),
        .method = Value.obj(&old_objects[2]),
        .is_async = true,
    });
    try environment.aliases.put(std.testing.allocator, "imported", .{
        .env = &old_environments[1],
        .name = "exported",
    });

    const Plan = struct {
        old_objects: *[6]Object,
        new_objects: *[6]Object,
        old_environments: *[2]Environment,
        new_environments: *[2]Environment,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            for (self.old_environments, 0..) |*candidate, index|
                if (old == @as(*anyopaque, @ptrCast(candidate)))
                    return @ptrCast(&self.new_environments[index]);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_environments = &old_environments,
        .new_environments = &new_environments,
    };
    relocateEnv(&environment, &plan);

    try std.testing.expectEqual(&new_objects[0], environment.vars.get("binding").?.asObj());
    try std.testing.expectEqual(&new_objects[1], environment.disposables.items[0].value.asObj());
    try std.testing.expectEqual(&new_objects[2], environment.disposables.items[0].method.asObj());
    try std.testing.expect(environment.disposables.items[0].is_async);
    try std.testing.expectEqual(&new_objects[3], environment.dispose_pending.?.asObj());
    try std.testing.expectEqual(&new_objects[4], environment.object_proto_intrinsic.?);
    try std.testing.expectEqual(&new_environments[0], environment.parent.?);
    const alias = environment.aliases.get("imported").?;
    try std.testing.expectEqual(&new_environments[1], alias.env);
    try std.testing.expectEqualStrings("exported", alias.name);
    try std.testing.expectEqual(&new_objects[5], environment.with_object.?);
}

fn finalizeEnv(e: *Environment) void {
    const a = e.bindings_allocator orelse return;
    var vit = e.vars.keyIterator();
    while (vit.next()) |key| e.freeBindingName(key.*);
    e.vars.deinit(a);
    e.vars = .{};

    var cit = e.consts.keyIterator();
    while (cit.next()) |key| e.freeBindingName(key.*);
    e.consts.deinit(a);
    e.consts = .{};

    var fit = e.fn_names.keyIterator();
    while (fit.next()) |key| e.freeBindingName(key.*);
    e.fn_names.deinit(a);
    e.fn_names = .{};

    var dit = e.deletable.keyIterator();
    while (dit.next()) |key| e.freeBindingName(key.*);
    e.deletable.deinit(a);
    e.deletable = .{};

    var ait = e.aliases.iterator();
    while (ait.next()) |entry| {
        e.freeBindingName(entry.key_ptr.*);
        e.freeBindingName(entry.value_ptr.name);
    }
    e.aliases.deinit(a);
    e.aliases = .{};

    e.disposables.deinit(a);
    e.disposables = .empty;
}

fn finalizeObjectBacking(o: *Object, a: std.mem.Allocator) usize {
    var released: usize = 0;
    const storage = o.storageState().?;
    const flags = storage.backing_flags;

    if (flags.slots) {
        const state = o.slotsState().?;
        state.list.deinit(a);
        a.destroy(state);
        storage.slots.store(null, .release);
        released += 1;
    }
    if (flags.elements) {
        o.elementsState().?.list.deinit(a);
        o.elementsState().?.list = .empty;
        released += 1;
    }
    if (flags.elements_state) {
        a.destroy(o.elementsState().?);
        storage.elements.store(null, .release);
        released += 1;
    }
    if (flags.accessors) {
        if (o.accessorsMap()) |acc| {
            var it = acc.keyIterator();
            while (it.next()) |key| a.free(key.*);
            acc.deinit(a);
            a.destroy(acc);
            o.coldState().?.accessors.store(null, .monotonic);
        }
        released += 1;
    }
    // `private_brands` reuses the "accessors" backing (see Object.addPrivateBrand)
    // but is a separate map pointer the finalizer must also release, or a GC-
    // collected branded object leaks its table + struct. Its keys are borrowed
    // private-name slices (put without copying), so unlike attrs/accessors we do
    // not free the keys.
    if (o.privateBrands()) |pb| {
        pb.deinit(a);
        a.destroy(pb);
        o.clearPrivateBrands();
    }
    if (flags.key_order) {
        if (o.keyOrder()) |ord| {
            for (ord.items) |key| a.free(key);
            ord.deinit(a);
            a.destroy(ord);
            o.coldState().?.key_order.store(null, .monotonic);
        }
        released += 1;
    }
    if (flags.attrs) {
        if (o.attrsMap()) |attrs| {
            var it = attrs.keyIterator();
            while (it.next()) |key| a.free(key.*);
            attrs.deinit(a);
            a.destroy(attrs);
            o.coldState().?.attrs = null;
        }
        released += 1;
    }
    if (flags.holes) {
        if (o.holesMap()) |holes| {
            holes.deinit(a);
            a.destroy(holes);
            o.clearHolesMap();
        }
        released += 1;
    }
    if (flags.weak_entries) {
        const cold = o.coldState().?;
        cold.weak_entries.deinit(a);
        cold.weak_entries = .empty;
        cold.weak_index.deinit(a);
        cold.weak_index = .empty;
        released += 1;
    }
    if (flags.coll_index) {
        const cold = o.coldState().?;
        cold.coll_index.deinit(a);
        cold.coll_index = .empty;
        released += 1;
    }
    if (flags.finalization_records) {
        if (o.coldState().?.finalization_records) |records| {
            records.deinit(a);
            a.destroy(records);
            o.coldState().?.finalization_records = null;
        }
        released += 1;
    }
    if (flags.typed_array) {
        if (o.typedArray()) |ta| {
            a.destroy(ta);
            o.clearTypedArray();
        }
        released += 1;
    }
    if (flags.data_view) {
        if (o.dataView()) |dv| {
            a.destroy(dv);
            o.clearDataView();
        }
        released += 1;
    }
    if (flags.temporal) {
        if (o.temporalData()) |t| {
            a.destroy(t);
            o.clearTemporalData();
        }
        released += 1;
    }
    if (flags.arg_map_names) {
        a.free(o.coldState().?.arg_map_names);
        o.coldState().?.arg_map_names = &.{};
        released += 1;
    }
    if (flags.arg_map_severed) {
        a.free(o.coldState().?.arg_map_severed);
        o.coldState().?.arg_map_severed = &.{};
        released += 1;
    }
    if (flags.cold) {
        a.destroy(o.coldState().?);
        storage.cold.store(null, .release);
        released += 1;
    }

    if (flags.storage_state) {
        o.storage.store(null, .release);
        storage.owner_allocator.destroy(storage);
        released += 1;
    }
    return released;
}

pub fn traceFunction(f: *interp.Function, v: anytype) void {
    markManaged(v, f.closure);
    v.mark(f.realm_global);
    v.mark(f.home_object);
    v.mark(f.super_ctor);
    v.mark(f.obj);
    if (f.import_meta_slot) |slot| if (slot.obj) |o| v.mark(o);
    markValue(v, f.arrow_this);
    markValue(v, f.arrow_new_target);
    if (f.this_cell) |cell| markValue(v, cell.value);
    for (f.with_stack) |object| v.mark(object);
    // `params`/`body`/`source`/`chunk` are immutable arena/AST — not cells.
}

/// Rewrite the same complete Function edge set that `traceFunction` marks.
/// The function record, import-meta slot, shared this cell, and with-stack
/// allocation are arena-owned containers; only their managed payloads move.
pub fn relocateFunction(f: *interp.Function, v: anytype) void {
    gc_relocation.rewriteRequiredSlot(v, Environment, &f.closure);
    gc_relocation.rewriteOptionalSlot(v, Object, &f.realm_global);
    gc_relocation.rewriteOptionalSlot(v, Object, &f.home_object);
    gc_relocation.rewriteOptionalSlot(v, Object, &f.super_ctor);
    gc_relocation.rewriteOptionalSlot(v, Object, &f.obj);
    if (f.import_meta_slot) |slot|
        gc_relocation.rewriteOptionalSlot(v, Object, &slot.obj);
    gc_relocation.rewriteValueSlot(v, &f.arrow_this);
    gc_relocation.rewriteValueSlot(v, &f.arrow_new_target);
    if (f.this_cell) |cell| gc_relocation.rewriteValueSlot(v, &cell.value);
    for (f.with_stack) |*object|
        gc_relocation.rewriteRequiredSlot(v, Object, object);
}

test "Function marking and relocation cover every managed field" {
    var old_environment = Environment{
        .arena = std.testing.allocator,
        .gc_managed = true,
    };
    var new_environment = Environment{
        .arena = std.testing.allocator,
        .gc_managed = true,
    };
    var old_objects: [10]Object = undefined;
    var new_objects: [10]Object = undefined;
    var body: ast.Node = .undefined_lit;
    var import_meta = interp.ImportMetaSlot{ .obj = &old_objects[4] };
    var this_cell = interp.ThisCell{
        .value = Value.obj(&old_objects[7]),
        .initialized = true,
    };
    var with_stack = [_]*Object{ &old_objects[8], &old_objects[9] };
    var function = interp.Function{
        .params = &.{},
        .body = &body,
        .is_expr_body = true,
        .closure = &old_environment,
        .realm_global = &old_objects[0],
        .home_object = &old_objects[1],
        .super_ctor = &old_objects[2],
        .obj = &old_objects[3],
        .import_meta_slot = &import_meta,
        .arrow_this = Value.obj(&old_objects[5]),
        .arrow_new_target = Value.obj(&old_objects[6]),
        .this_cell = &this_cell,
        .with_stack = &with_stack,
    };

    const TraceVisitor = struct {
        seen: std.AutoHashMap(usize, void),

        fn mark(self: *@This(), maybe_cell: anytype) void {
            const cell = switch (@typeInfo(@TypeOf(maybe_cell))) {
                .optional => maybe_cell orelse return,
                .pointer => maybe_cell,
                else => @compileError("Function trace test expects a cell pointer"),
            };
            self.seen.put(@intFromPtr(cell), {}) catch @panic("trace test allocation failed");
        }
    };
    var trace = TraceVisitor{ .seen = .init(std.testing.allocator) };
    defer trace.seen.deinit();
    traceFunction(&function, &trace);
    try std.testing.expect(trace.seen.contains(@intFromPtr(&old_environment)));
    for (&old_objects) |*object|
        try std.testing.expect(trace.seen.contains(@intFromPtr(object)));
    try std.testing.expectEqual(@as(usize, 11), trace.seen.count());

    const Plan = struct {
        old_environment: *Environment,
        new_environment: *Environment,
        old_objects: *[10]Object,
        new_objects: *[10]Object,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            if (old == @as(*anyopaque, @ptrCast(self.old_environment)))
                return @ptrCast(self.new_environment);
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            return old;
        }
    };
    const plan = Plan{
        .old_environment = &old_environment,
        .new_environment = &new_environment,
        .old_objects = &old_objects,
        .new_objects = &new_objects,
    };
    relocateFunction(&function, &plan);

    try std.testing.expectEqual(&new_environment, function.closure);
    try std.testing.expectEqual(&new_objects[0], function.realm_global.?);
    try std.testing.expectEqual(&new_objects[1], function.home_object.?);
    try std.testing.expectEqual(&new_objects[2], function.super_ctor.?);
    try std.testing.expectEqual(&new_objects[3], function.obj.?);
    try std.testing.expectEqual(&new_objects[4], import_meta.obj.?);
    try std.testing.expectEqual(&new_objects[5], function.arrow_this.asObj());
    try std.testing.expectEqual(&new_objects[6], function.arrow_new_target.asObj());
    try std.testing.expectEqual(&new_objects[7], this_cell.value.asObj());
    try std.testing.expectEqual(&new_objects[8], with_stack[0]);
    try std.testing.expectEqual(&new_objects[9], with_stack[1]);
    try std.testing.expect(Binding.traceOldOnMinor(.function));
}

pub fn traceBoundFn(b: *interp.Interpreter.BoundFn, v: anytype) void {
    markValue(v, b.target);
    markValue(v, b.this);
    for (b.args) |a| markValue(v, a);
}

pub fn relocateBoundFn(b: *interp.Interpreter.BoundFn, v: anytype) void {
    gc_relocation.rewriteValueSlot(v, &b.target);
    gc_relocation.rewriteValueSlot(v, &b.this);
    for (@constCast(b.args)) |*argument|
        gc_relocation.rewriteValueSlot(v, argument);
}

pub fn tracePromise(p: *promise.Promise, v: anytype) void {
    p.lockState();
    defer p.unlockState();
    markValue(v, p.value);
    if (p.wrapper) |wrapper| v.mark(wrapper);
    if (p.awaiting_async_activation) |activation|
        v.mark(@as(*vm.Generator, @ptrCast(@alignCast(activation))));
    if (p.async_forward_to) |forward| markManaged(v, forward);
    if (p.on_fulfill_inline) |r| traceReaction(r, v);
    if (p.on_reject_inline) |r| traceReaction(r, v);
    for (p.on_fulfill.items) |r| traceReaction(r, v);
    for (p.on_reject.items) |r| traceReaction(r, v);
}

inline fn traceReaction(r: promise.Reaction, v: anytype) void {
    markValueOpt(v, r.handler);
    markValueOpt(v, r.extra_argument);
    if (r.retained_async_activation) |activation|
        v.mark(@as(*vm.Generator, @ptrCast(@alignCast(activation))));
    if (r.detached) return;
    if (r.result) |result| {
        markManaged(v, result);
    } else {
        markValue(v, r.resolve);
        markValue(v, r.reject);
    }
}

inline fn relocateReaction(r: *promise.Reaction, v: anytype) void {
    gc_relocation.rewriteOptionalValueSlot(v, &r.handler);
    gc_relocation.rewriteOptionalValueSlot(v, &r.extra_argument);
    gc_relocation.rewriteOptionalSlot(v, anyopaque, &r.retained_async_activation);
    if (r.detached) return;
    if (r.result) |_| {
        gc_relocation.rewriteOptionalSlot(v, promise.Promise, &r.result);
    } else {
        gc_relocation.rewriteValueSlot(v, &r.resolve);
        gc_relocation.rewriteValueSlot(v, &r.reject);
    }
}

/// Promise relocation happens after all mutators are stopped. Taking the
/// Promise state lock here could deadlock on a parked owner and is unnecessary:
/// the state and both reaction buffers are stable for the entire commit.
pub fn relocatePromise(p: *promise.Promise, v: anytype) void {
    gc_relocation.rewriteValueSlot(v, &p.value);
    gc_relocation.rewriteOptionalSlot(v, Object, &p.wrapper);
    gc_relocation.rewriteOptionalSlot(v, anyopaque, &p.awaiting_async_activation);
    gc_relocation.rewriteOptionalSlot(v, promise.Promise, &p.async_forward_to);
    if (p.on_fulfill_inline) |*reaction| relocateReaction(reaction, v);
    if (p.on_reject_inline) |*reaction| relocateReaction(reaction, v);
    for (p.on_fulfill.items) |*reaction| relocateReaction(reaction, v);
    for (p.on_reject.items) |*reaction| relocateReaction(reaction, v);
}

test "Promise relocation rewrites inline and overflow reaction graphs" {
    var old_objects: [14]Object = undefined;
    var new_objects: [14]Object = undefined;
    var old_promises: [3]promise.Promise = .{ .{}, .{}, .{} };
    var new_promises: [3]promise.Promise = .{ .{}, .{}, .{} };
    var old_generators: [5]vm.Generator = undefined;
    var new_generators: [5]vm.Generator = undefined;
    var fulfill_overflow = [_]promise.Reaction{.{
        .handler = Value.obj(&old_objects[8]),
        .extra_argument = Value.obj(&old_objects[9]),
        .retained_async_activation = &old_generators[3],
        .result = &old_promises[2],
    }};
    var reject_overflow = [_]promise.Reaction{.{
        .handler = Value.obj(&old_objects[10]),
        .extra_argument = Value.obj(&old_objects[11]),
        .retained_async_activation = &old_generators[4],
        .resolve = Value.obj(&old_objects[12]),
        .reject = Value.obj(&old_objects[13]),
    }};
    var state = promise.Promise{
        .value = Value.obj(&old_objects[0]),
        .wrapper = &old_objects[1],
        .awaiting_async_activation = &old_generators[0],
        .async_forward_to = &old_promises[0],
        .on_fulfill_inline = .{
            .handler = Value.obj(&old_objects[2]),
            .extra_argument = Value.obj(&old_objects[3]),
            .retained_async_activation = &old_generators[1],
            .result = &old_promises[1],
        },
        .on_reject_inline = .{
            .handler = Value.obj(&old_objects[4]),
            .extra_argument = Value.obj(&old_objects[5]),
            .retained_async_activation = &old_generators[2],
            .resolve = Value.obj(&old_objects[6]),
            .reject = Value.obj(&old_objects[7]),
        },
        .on_fulfill = .{ .items = &fulfill_overflow, .capacity = fulfill_overflow.len },
        .on_reject = .{ .items = &reject_overflow, .capacity = reject_overflow.len },
    };

    const Plan = struct {
        old_objects: *[14]Object,
        new_objects: *[14]Object,
        old_promises: *[3]promise.Promise,
        new_promises: *[3]promise.Promise,
        old_generators: *[5]vm.Generator,
        new_generators: *[5]vm.Generator,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            for (self.old_promises, 0..) |*candidate, index|
                if (old == @as(*anyopaque, @ptrCast(candidate)))
                    return @ptrCast(&self.new_promises[index]);
            for (self.old_generators, 0..) |*candidate, index|
                if (old == @as(*anyopaque, @ptrCast(candidate)))
                    return @ptrCast(&self.new_generators[index]);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_promises = &old_promises,
        .new_promises = &new_promises,
        .old_generators = &old_generators,
        .new_generators = &new_generators,
    };
    relocatePromise(&state, &plan);

    try std.testing.expectEqual(&new_objects[0], state.value.asObj());
    try std.testing.expectEqual(&new_objects[1], state.wrapper.?);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_generators[0])), state.awaiting_async_activation.?);
    try std.testing.expectEqual(&new_promises[0], state.async_forward_to.?);
    const fulfill_inline = state.on_fulfill_inline.?;
    try std.testing.expectEqual(&new_objects[2], fulfill_inline.handler.?.asObj());
    try std.testing.expectEqual(&new_objects[3], fulfill_inline.extra_argument.?.asObj());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_generators[1])), fulfill_inline.retained_async_activation.?);
    try std.testing.expectEqual(&new_promises[1], fulfill_inline.result.?);
    const reject_inline = state.on_reject_inline.?;
    try std.testing.expectEqual(&new_objects[4], reject_inline.handler.?.asObj());
    try std.testing.expectEqual(&new_objects[5], reject_inline.extra_argument.?.asObj());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_generators[2])), reject_inline.retained_async_activation.?);
    try std.testing.expectEqual(&new_objects[6], reject_inline.resolve.asObj());
    try std.testing.expectEqual(&new_objects[7], reject_inline.reject.asObj());
    try std.testing.expectEqual(&new_objects[8], fulfill_overflow[0].handler.?.asObj());
    try std.testing.expectEqual(&new_objects[9], fulfill_overflow[0].extra_argument.?.asObj());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_generators[3])), fulfill_overflow[0].retained_async_activation.?);
    try std.testing.expectEqual(&new_promises[2], fulfill_overflow[0].result.?);
    try std.testing.expectEqual(&new_objects[10], reject_overflow[0].handler.?.asObj());
    try std.testing.expectEqual(&new_objects[11], reject_overflow[0].extra_argument.?.asObj());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&new_generators[4])), reject_overflow[0].retained_async_activation.?);
    try std.testing.expectEqual(&new_objects[12], reject_overflow[0].resolve.asObj());
    try std.testing.expectEqual(&new_objects[13], reject_overflow[0].reject.asObj());
}

inline fn traceMicrotask(mt: promise.Microtask, v: anytype) void {
    switch (mt.kind) {
        .reaction => {
            traceReaction(mt.reaction, v);
            markValue(v, mt.argument);
        },
        .thenable => {
            markValue(v, mt.thenable);
            markValue(v, mt.then_fn);
            if (mt.promise) |p| markManaged(v, p);
        },
        .callback => markValue(v, mt.callback),
        .native_callback => {},
        .job => {
            markValue(v, mt.job);
            markValue(v, mt.job_first);
            markValue(v, mt.job_second);
        },
        .next_tick => {
            markValue(v, mt.job);
            for (mt.job_args) |argument| markValue(v, argument);
        },
    }
}

inline fn relocateMicrotask(mt: *promise.Microtask, v: anytype) void {
    switch (mt.kind) {
        .reaction => {
            relocateReaction(&mt.reaction, v);
            gc_relocation.rewriteValueSlot(v, &mt.argument);
        },
        .thenable => {
            gc_relocation.rewriteValueSlot(v, &mt.thenable);
            gc_relocation.rewriteValueSlot(v, &mt.then_fn);
            gc_relocation.rewriteOptionalSlot(v, promise.Promise, &mt.promise);
        },
        .callback => gc_relocation.rewriteValueSlot(v, &mt.callback),
        .native_callback => {},
        .job => {
            gc_relocation.rewriteValueSlot(v, &mt.job);
            gc_relocation.rewriteValueSlot(v, &mt.job_first);
            gc_relocation.rewriteValueSlot(v, &mt.job_second);
        },
        .next_tick => {
            gc_relocation.rewriteValueSlot(v, &mt.job);
            for (@constCast(mt.job_args)) |*argument|
                gc_relocation.rewriteValueSlot(v, argument);
        },
    }
}

pub fn traceGenerator(g: *vm.Generator, v: anytype) void {
    v.mark(g.env);
    for (g.exec.stack.items) |s| markValue(v, s);
    markValue(v, g.exec.acc);
    var frame = g.exec.frame;
    while (frame) |current| : (frame = current.parent)
        for (current.slots) |slot| markValue(v, slot);
    markValue(v, g.this_value);
    v.mark(g.home_object);
    v.mark(g.super_ctor);
    if (g.import_meta_slot) |slot| v.mark(slot.obj);
    v.mark(g.result);
    if (g.async_parent_promise) |parent| markManaged(v, parent);
    for (g.pendingRequests()) |req| {
        markValue(v, req.value);
        v.mark(req.result);
    }
}

/// Generator tracing is deferred to the world-stopped finish pass during a
/// concurrent mark; relocation runs at that same boundary, so no mutator can
/// race these arena-owned stacks, frames, or request records.
pub fn relocateGenerator(g: *vm.Generator, v: anytype) void {
    gc_relocation.rewriteRequiredSlot(v, Environment, &g.env);
    for (g.exec.stack.items) |*slot| gc_relocation.rewriteValueSlot(v, slot);
    gc_relocation.rewriteValueSlot(v, &g.exec.acc);
    var frame = g.exec.frame;
    while (frame) |current| : (frame = current.parent)
        for (current.slots) |*slot| gc_relocation.rewriteValueSlot(v, slot);
    gc_relocation.rewriteValueSlot(v, &g.this_value);
    gc_relocation.rewriteOptionalSlot(v, Object, &g.home_object);
    gc_relocation.rewriteOptionalSlot(v, Object, &g.super_ctor);
    if (g.import_meta_slot) |slot|
        gc_relocation.rewriteOptionalSlot(v, Object, &slot.obj);
    gc_relocation.rewriteOptionalSlot(v, Object, &g.result);
    gc_relocation.rewriteOptionalSlot(v, promise.Promise, &g.async_parent_promise);
    for (@constCast(g.pendingRequests())) |*request| {
        gc_relocation.rewriteValueSlot(v, &request.value);
        gc_relocation.rewriteRequiredSlot(v, Object, &request.result);
    }
}

fn finalizeGenerator(g: *vm.Generator, a: std.mem.Allocator, live: *usize) void {
    const flags = g.backing_flags;
    var released: usize = 0;
    if (flags.stack) {
        g.exec.stack.deinit(a);
        g.exec.stack = .empty;
        released += 1;
    }
    if (flags.handlers) {
        g.exec.handlers.deinit(a);
        g.exec.handlers = .empty;
        released += 1;
    }
    if (flags.requests) {
        g.requests.deinit(a);
        g.requests = .empty;
        g.requests_head = 0;
        released += 1;
    }
    if (released > 0) {
        _ = @atomicRmw(usize, live, .Sub, released, .monotonic);
    }
    g.backing_flags = .{};
    g.backing_allocator = null;
    g.backing_stores_live = null;
}

pub fn traceIterHelper(h: *value.IterHelper, v: anytype) void {
    markValue(v, h.src);
    markValue(v, h.next_method);
    markValue(v, h.func);
    markValueOpt(v, h.inner);
    markValue(v, h.inner_next);
    markValue(v, h.padding);
}

pub fn relocateIterHelper(h: *value.IterHelper, v: anytype) void {
    gc_relocation.rewriteValueSlot(v, &h.src);
    gc_relocation.rewriteValueSlot(v, &h.next_method);
    gc_relocation.rewriteValueSlot(v, &h.func);
    gc_relocation.rewriteOptionalValueSlot(v, &h.inner);
    gc_relocation.rewriteValueSlot(v, &h.inner_next);
    gc_relocation.rewriteValueSlot(v, &h.padding);
}

test "Generator and IteratorHelper marking and relocation cover every managed slot" {
    var old_objects: [20]Object = undefined;
    var new_objects: [20]Object = undefined;
    var old_environment = Environment{ .arena = std.testing.allocator, .gc_managed = true };
    var new_environment = Environment{ .arena = std.testing.allocator, .gc_managed = true };
    var old_promise = promise.Promise{ .gc_owned = true };
    var new_promise = promise.Promise{ .gc_owned = true };
    var chunk: bytecode.Chunk = undefined;
    var stack = [_]Value{
        Value.obj(&old_objects[0]),
        Value.obj(&old_objects[1]),
    };
    var parent_frame_slots = [_]Value{Value.obj(&old_objects[3])};
    var child_frame_slots = [_]Value{Value.obj(&old_objects[4])};
    var parent_frame = vm.Frame{ .slots = &parent_frame_slots, .parent = null };
    var child_frame = vm.Frame{ .slots = &child_frame_slots, .parent = &parent_frame };
    var import_meta = interp.ImportMetaSlot{ .obj = &old_objects[8] };
    var requests = [_]vm.AsyncGenRequest{
        .{ .kind = .send, .value = Value.obj(&old_objects[10]), .result = &old_objects[11] },
        .{ .kind = .return_, .value = Value.obj(&old_objects[12]), .result = &old_objects[13] },
    };
    var generator = vm.Generator{
        .chunk = &chunk,
        .exec = .{
            .stack = .{ .items = &stack, .capacity = stack.len },
            .acc = Value.obj(&old_objects[2]),
            .frame = &child_frame,
        },
        .env = &old_environment,
        .this_value = Value.obj(&old_objects[5]),
        .home_object = &old_objects[6],
        .super_ctor = &old_objects[7],
        .import_meta_slot = &import_meta,
        .result = &old_objects[9],
        .async_parent_promise = &old_promise,
        .requests = .{ .items = &requests, .capacity = requests.len },
    };
    var helper = value.IterHelper{
        .src = Value.obj(&old_objects[14]),
        .next_method = Value.obj(&old_objects[15]),
        .kind = .map,
        .func = Value.obj(&old_objects[16]),
        .inner = Value.obj(&old_objects[17]),
        .inner_next = Value.obj(&old_objects[18]),
        .padding = Value.obj(&old_objects[19]),
    };

    const TraceVisitor = struct {
        seen: std.AutoHashMap(usize, void),

        fn mark(self: *@This(), maybe_cell: anytype) void {
            const cell = switch (@typeInfo(@TypeOf(maybe_cell))) {
                .optional => maybe_cell orelse return,
                .pointer => maybe_cell,
                else => @compileError("Generator trace test expects a cell pointer"),
            };
            self.seen.put(@intFromPtr(cell), {}) catch @panic("trace test allocation failed");
        }
    };
    var trace = TraceVisitor{ .seen = .init(std.testing.allocator) };
    defer trace.seen.deinit();
    traceGenerator(&generator, &trace);
    try std.testing.expect(trace.seen.contains(@intFromPtr(&old_environment)));
    try std.testing.expect(trace.seen.contains(@intFromPtr(&old_promise)));
    for (old_objects[0..14]) |*object|
        try std.testing.expect(trace.seen.contains(@intFromPtr(object)));
    try std.testing.expectEqual(@as(usize, 16), trace.seen.count());

    const Plan = struct {
        old_objects: *[20]Object,
        new_objects: *[20]Object,
        old_environment: *Environment,
        new_environment: *Environment,
        old_promise: *promise.Promise,
        new_promise: *promise.Promise,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            if (old == @as(*anyopaque, @ptrCast(self.old_environment)))
                return @ptrCast(self.new_environment);
            if (old == @as(*anyopaque, @ptrCast(self.old_promise)))
                return @ptrCast(self.new_promise);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_environment = &old_environment,
        .new_environment = &new_environment,
        .old_promise = &old_promise,
        .new_promise = &new_promise,
    };
    relocateGenerator(&generator, &plan);
    relocateIterHelper(&helper, &plan);

    try std.testing.expectEqual(&new_environment, generator.env);
    try std.testing.expectEqual(&new_objects[0], stack[0].asObj());
    try std.testing.expectEqual(&new_objects[1], stack[1].asObj());
    try std.testing.expectEqual(&new_objects[2], generator.exec.acc.asObj());
    try std.testing.expectEqual(&new_objects[3], parent_frame_slots[0].asObj());
    try std.testing.expectEqual(&new_objects[4], child_frame_slots[0].asObj());
    try std.testing.expectEqual(&new_objects[5], generator.this_value.asObj());
    try std.testing.expectEqual(&new_objects[6], generator.home_object.?);
    try std.testing.expectEqual(&new_objects[7], generator.super_ctor.?);
    try std.testing.expectEqual(&new_objects[8], import_meta.obj.?);
    try std.testing.expectEqual(&new_objects[9], generator.result.?);
    try std.testing.expectEqual(&new_promise, generator.async_parent_promise.?);
    try std.testing.expectEqual(&new_objects[10], requests[0].value.asObj());
    try std.testing.expectEqual(&new_objects[11], requests[0].result);
    try std.testing.expectEqual(&new_objects[12], requests[1].value.asObj());
    try std.testing.expectEqual(&new_objects[13], requests[1].result);
    try std.testing.expectEqual(&new_objects[14], helper.src.asObj());
    try std.testing.expectEqual(&new_objects[15], helper.next_method.asObj());
    try std.testing.expectEqual(&new_objects[16], helper.func.asObj());
    try std.testing.expectEqual(&new_objects[17], helper.inner.?.asObj());
    try std.testing.expectEqual(&new_objects[18], helper.inner_next.asObj());
    try std.testing.expectEqual(&new_objects[19], helper.padding.asObj());
}

pub fn traceModuleNs(m: *interp.ModuleNs, v: anytype) void {
    for (m.envs) |e| v.mark(e);
}

pub fn relocateModuleNs(m: *interp.ModuleNs, v: anytype) void {
    for (m.envs) |*environment|
        gc_relocation.rewriteRequiredSlot(v, Environment, environment);
}

test "BoundFunction and module namespace relocation rewrites every managed slot" {
    var old_objects: [4]Object = undefined;
    var new_objects: [4]Object = undefined;
    var old_environments = [_]Environment{
        .{ .arena = std.testing.allocator, .gc_managed = true },
        .{ .arena = std.testing.allocator, .gc_managed = true },
    };
    var new_environments = [_]Environment{
        .{ .arena = std.testing.allocator, .gc_managed = true },
        .{ .arena = std.testing.allocator, .gc_managed = true },
    };
    var bound_arguments = [_]Value{
        Value.obj(&old_objects[2]),
        Value.obj(&old_objects[3]),
    };
    var bound = interp.Interpreter.BoundFn{
        .target = Value.obj(&old_objects[0]),
        .this = Value.obj(&old_objects[1]),
        .args = &bound_arguments,
    };
    var namespace_environments = [_]*Environment{
        &old_environments[0],
        &old_environments[1],
    };
    var namespace_names = [_][]const u8{ "first", "second" };
    var namespace_locals = [_][]const u8{ "localFirst", "localSecond" };
    var namespace = interp.ModuleNs{
        .names = &namespace_names,
        .envs = &namespace_environments,
        .locals = &namespace_locals,
        .tag_key = "Symbol.toStringTag",
        .deferred = true,
        .defer_module = @ptrFromInt(@alignOf(usize)),
    };
    const names_pointer = namespace.names.ptr;
    const locals_pointer = namespace.locals.ptr;
    const deferred_module = namespace.defer_module;

    const Plan = struct {
        old_objects: *[4]Object,
        new_objects: *[4]Object,
        old_environments: *[2]Environment,
        new_environments: *[2]Environment,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            for (self.old_environments, 0..) |*environment, index|
                if (old == @as(*anyopaque, @ptrCast(environment)))
                    return @ptrCast(&self.new_environments[index]);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_environments = &old_environments,
        .new_environments = &new_environments,
    };
    relocateBoundFn(&bound, &plan);
    relocateModuleNs(&namespace, &plan);

    try std.testing.expectEqual(&new_objects[0], bound.target.asObj());
    try std.testing.expectEqual(&new_objects[1], bound.this.asObj());
    try std.testing.expectEqual(&new_objects[2], bound_arguments[0].asObj());
    try std.testing.expectEqual(&new_objects[3], bound_arguments[1].asObj());
    try std.testing.expectEqual(&new_environments[0], namespace_environments[0]);
    try std.testing.expectEqual(&new_environments[1], namespace_environments[1]);
    try std.testing.expectEqual(names_pointer, namespace.names.ptr);
    try std.testing.expectEqual(locals_pointer, namespace.locals.ptr);
    try std.testing.expectEqual(deferred_module, namespace.defer_module);
}

pub fn traceModuleGraph(cache: *std.StringHashMapUnmanaged(*ContextMod.Context.Module), v: anytype) void {
    var it = cache.valueIterator();
    while (it.next()) |mp| {
        const m = mp.*;
        v.mark(m.env);
        if (m.ns) |ns| v.mark(ns);
        if (m.deferred_ns) |ns| v.mark(ns);
        if (m.import_meta_slot.obj) |o| v.mark(o);
        if (m.eval_error) |err| markValue(v, err);
        if (m.completion_promise) |completion| markManaged(v, completion);
        for (m.dynamic_waiters.items) |waiter| {
            markManaged(v, waiter.capability);
            v.mark(waiter.namespace);
        }
    }
}

pub fn relocateModuleGraph(cache: *std.StringHashMapUnmanaged(*ContextMod.Context.Module), v: anytype) void {
    var it = cache.valueIterator();
    while (it.next()) |module_pointer| {
        const module = module_pointer.*;
        gc_relocation.rewriteRequiredSlot(v, Environment, &module.env);
        gc_relocation.rewriteOptionalSlot(v, Object, &module.ns);
        gc_relocation.rewriteOptionalSlot(v, Object, &module.deferred_ns);
        gc_relocation.rewriteOptionalSlot(v, Object, &module.import_meta_slot.obj);
        gc_relocation.rewriteOptionalValueSlot(v, &module.eval_error);
        gc_relocation.rewriteOptionalSlot(v, promise.Promise, &module.completion_promise);
        for (module.dynamic_waiters.items) |*waiter| {
            gc_relocation.rewriteRequiredSlot(v, promise.Promise, &waiter.capability);
            gc_relocation.rewriteRequiredSlot(v, Object, &waiter.namespace);
        }
    }
}

test "realm root relocation rewrites microtask variants and module graph" {
    var old_objects: [16]Object = undefined;
    var new_objects: [16]Object = undefined;
    var old_promises: [4]promise.Promise = .{ .{}, .{}, .{}, .{} };
    var new_promises: [4]promise.Promise = .{ .{}, .{}, .{}, .{} };
    var old_environment = Environment{ .arena = std.testing.allocator, .gc_managed = true };
    var new_environment = Environment{ .arena = std.testing.allocator, .gc_managed = true };
    var next_tick_args = [_]Value{ Value.obj(&old_objects[9]), Value.obj(&old_objects[10]) };
    var tasks = [_]promise.Microtask{
        .{
            .reaction = .{ .handler = Value.obj(&old_objects[0]), .result = &old_promises[0] },
            .argument = Value.obj(&old_objects[1]),
            .fulfilled = true,
        },
        .{
            .kind = .thenable,
            .reaction = undefined,
            .argument = Value.undef(),
            .fulfilled = true,
            .thenable = Value.obj(&old_objects[2]),
            .then_fn = Value.obj(&old_objects[3]),
            .promise = &old_promises[1],
        },
        .{
            .kind = .callback,
            .reaction = undefined,
            .argument = Value.undef(),
            .fulfilled = true,
            .callback = Value.obj(&old_objects[4]),
        },
        .{
            .kind = .job,
            .reaction = undefined,
            .argument = Value.undef(),
            .fulfilled = true,
            .job = Value.obj(&old_objects[5]),
            .job_first = Value.obj(&old_objects[6]),
            .job_second = Value.obj(&old_objects[7]),
        },
        .{
            .kind = .next_tick,
            .reaction = undefined,
            .argument = Value.undef(),
            .fulfilled = true,
            .job = Value.obj(&old_objects[8]),
            .job_args = &next_tick_args,
        },
    };

    var module = ContextMod.Context.Module{
        .path = "entry.js",
        .items = &.{},
        .env = &old_environment,
        .ns = &old_objects[11],
        .deferred_ns = &old_objects[12],
        .import_meta_slot = .{ .obj = &old_objects[13] },
        .eval_error = Value.obj(&old_objects[14]),
        .completion_promise = &old_promises[2],
    };
    defer module.dynamic_waiters.deinit(std.testing.allocator);
    try module.dynamic_waiters.append(std.testing.allocator, .{
        .capability = &old_promises[3],
        .namespace = &old_objects[15],
    });
    var modules: std.StringHashMapUnmanaged(*ContextMod.Context.Module) = .{};
    defer modules.deinit(std.testing.allocator);
    try modules.put(std.testing.allocator, "entry.js", &module);

    const Plan = struct {
        old_objects: *[16]Object,
        new_objects: *[16]Object,
        old_promises: *[4]promise.Promise,
        new_promises: *[4]promise.Promise,
        old_environment: *Environment,
        new_environment: *Environment,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            for (self.old_promises, 0..) |*state, index|
                if (old == @as(*anyopaque, @ptrCast(state)))
                    return @ptrCast(&self.new_promises[index]);
            if (old == @as(*anyopaque, @ptrCast(self.old_environment)))
                return @ptrCast(self.new_environment);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_promises = &old_promises,
        .new_promises = &new_promises,
        .old_environment = &old_environment,
        .new_environment = &new_environment,
    };
    for (&tasks) |*task| relocateMicrotask(task, &plan);
    relocateModuleGraph(&modules, &plan);

    try std.testing.expectEqual(&new_objects[0], tasks[0].reaction.handler.?.asObj());
    try std.testing.expectEqual(&new_promises[0], tasks[0].reaction.result.?);
    try std.testing.expectEqual(&new_objects[1], tasks[0].argument.asObj());
    try std.testing.expectEqual(&new_objects[2], tasks[1].thenable.asObj());
    try std.testing.expectEqual(&new_objects[3], tasks[1].then_fn.asObj());
    try std.testing.expectEqual(&new_promises[1], tasks[1].promise.?);
    try std.testing.expectEqual(&new_objects[4], tasks[2].callback.asObj());
    try std.testing.expectEqual(&new_objects[5], tasks[3].job.asObj());
    try std.testing.expectEqual(&new_objects[6], tasks[3].job_first.asObj());
    try std.testing.expectEqual(&new_objects[7], tasks[3].job_second.asObj());
    try std.testing.expectEqual(&new_objects[8], tasks[4].job.asObj());
    try std.testing.expectEqual(&new_objects[9], next_tick_args[0].asObj());
    try std.testing.expectEqual(&new_objects[10], next_tick_args[1].asObj());
    try std.testing.expectEqual(&new_environment, module.env);
    try std.testing.expectEqual(&new_objects[11], module.ns.?);
    try std.testing.expectEqual(&new_objects[12], module.deferred_ns.?);
    try std.testing.expectEqual(&new_objects[13], module.import_meta_slot.obj.?);
    try std.testing.expectEqual(&new_objects[14], module.eval_error.?.asObj());
    try std.testing.expectEqual(&new_promises[2], module.completion_promise.?);
    try std.testing.expectEqual(&new_promises[3], module.dynamic_waiters.items[0].capability);
    try std.testing.expectEqual(&new_objects[15], module.dynamic_waiters.items[0].namespace);
}

pub fn traceInterpreterRoots(machine: *interp.Interpreter, v: anytype) void {
    markManaged(v, machine.env);
    traceEnv(machine.env, v);
    // Active VM operand stacks: arena-backed, so their live `Value`s are
    // invisible to both the precise object graph and the conservative native
    // stack scan. The VM flushes `acc`/`ip` into each `Exec` at the safepoint
    // before collecting, so these reads are current.
    for (machine.gc_execs.items) |exec| {
        for (exec.stack.items) |s| markValue(v, s);
        markValue(v, exec.acc);
        // The activation's frame slots (and its captured-frame parent chain for
        // upvalues) are arena-backed locals — invisible to both the precise
        // object graph and the native-stack scan, exactly like the operand stack
        // above. Without tracing them an object live only through a VM local is
        // swept mid-collection (a use-after-free that surfaces as a garbage
        // `restricted_to` ⇒ spurious ConcurrentAccessError).
        //
        // Once a closure captures a frame it is marked `escaped`, and the VM
        // serializes its slots with `slot_lock` (see `store_local`/`load_upval`).
        // A cross-thread closure makes this parent-chain walk reach a *running*
        // peer's live escaped frame, so under a concurrent/parallel trace the
        // read must take that same lock or it races the mutator's slot store.
        // Gated on `v.concurrent()` + `escaped`: a stop-the-world trace (no
        // mutator running) and never-captured frames (the vast majority) lock
        // nothing.
        const lock_slots = v.concurrent();
        var fr: ?*vm.Frame = exec.frame;
        while (fr) |f| : (fr = f.parent) {
            const held = f.lockSlots(lock_slots);
            for (f.slots) |slot| markValue(v, slot);
            f.unlockSlots(held);
        }
    }
    for (machine.gc_wasm_roots.items) |roots| traceWasmExecutionRoots(roots, v);
    if (machine.microtasks) |q| {
        machine.lockMicrotasks();
        for (q.pendingItems()) |mt| traceMicrotask(mt, v);
        machine.unlockMicrotasks();
    }
    if (machine.next_ticks) |q| {
        machine.lockJobQueue(q);
        for (q.pendingItems()) |mt| traceMicrotask(mt, v);
        machine.unlockJobQueue(q);
    }
    if (machine.current_microtask) |mt| traceMicrotask(mt, v);
    for (machine.current_microtask_batch) |mt| traceMicrotask(mt, v);
    for (machine.current_hold_jobs) |job| jsthread.traceHoldJobRoot(job, v);
    if (machine.async_waiters) |waiters| {
        machine.lockRealm();
        defer machine.unlockRealm();
        for (waiters.items) |aw| markValue(v, aw.promise);
    }
    // NOTE: the shared realm `finalization_cleanup_jobs` is intentionally NOT
    // traced here. Unlike the per-thread lists above, every interpreter's
    // `finalization_cleanup_jobs` aliases the one Context-owned queue, which the
    // collector already traces under `realm_lock` in `Binding.traceRoots` at
    // begin + every `concurrentMarkRound` re-scan + finish. Reading it here (off
    // the collector thread, at a mutator's publish safepoint) took no lock and
    // raced `drainFinalizationCleanupJobs`'s clear — a crash the parallel marker
    // only reaches once collections actually converge. See `Binding.traceRoots`.
    for (machine.gc_env_roots.items) |env| {
        markManaged(v, env);
        traceEnv(env, v);
    }
    for (machine.gc_temp_roots.items) |root| markValue(v, root);
    for (machine.gc_object_reserve.items) |object| v.mark(object);
    var literal_it = machine.string_literal_cache.valueIterator();
    while (literal_it.next()) |literal| markValue(v, literal.*);
    var template_it = machine.template_cache.valueIterator();
    while (template_it.next()) |template| markValue(v, template.*);
    if (machine.tdz_marker) |o| v.mark(o);
    if (machine.global_object) |o| v.mark(o);
    var sym_it = machine.symbols.valueIterator();
    while (sym_it.next()) |sym| v.mark(sym.*);
    if (machine.import_meta_slot) |slot| {
        if (slot.obj) |o| v.mark(o);
    } else if (machine.import_meta_obj) |o| v.mark(o);
    markValue(v, machine.ret_value);
    markValue(v, machine.this_value);
    markValue(v, machine.exception);
    markValue(v, machine.new_target);
    if (machine.active_native) |o| v.mark(o);
    if (machine.active_function) |o| v.mark(o);
    var call_frame = machine.active_call_frame;
    while (call_frame) |fr| : (call_frame = fr.caller) {
        v.mark(fr.func_obj);
        if (fr.arguments) |args| markValue(v, args);
    }
    // Inspector frames point at the real lexical environments and `this`
    // values used by suspended execution. Keep every caller scope alive during
    // the synchronous paused callback, including closure calls whose caller
    // environment is not in the callee's lexical parent chain.
    var debug_frame = machine.debug_call_frame;
    while (debug_frame) |fr| : (debug_frame = fr.caller) {
        markManaged(v, fr.environment);
        traceEnv(fr.environment, v);
        markValue(v, fr.this_value);
    }
    if (machine.debug_top_level_environment) |env| {
        markManaged(v, env);
        traceEnv(env, v);
    }
    if (machine.home_object) |o| v.mark(o);
    if (machine.super_ctor) |o| v.mark(o);
    for (machine.with_stack.items) |o| v.mark(o);
}

/// Mutating companion to `traceInterpreterRoots`. The collector calls this
/// only after all interpreters have published and parked, so queue/frame/root
/// containers are stable and no mutator lock is taken here.
pub fn relocateInterpreterRoots(machine: *interp.Interpreter, v: anytype) void {
    gc_relocation.rewriteRequiredSlot(v, Environment, &machine.env);
    relocateEnv(machine.env, v);
    for (machine.gc_execs.items) |exec| {
        for (exec.stack.items) |*slot| gc_relocation.rewriteValueSlot(v, slot);
        gc_relocation.rewriteValueSlot(v, &exec.acc);
        var frame = exec.frame;
        while (frame) |current| : (frame = current.parent)
            for (current.slots) |*slot| gc_relocation.rewriteValueSlot(v, slot);
    }
    for (machine.gc_wasm_roots.items) |roots| relocateWasmExecutionRoots(roots, v);
    if (machine.microtasks) |queue|
        for (@constCast(queue.pendingItems())) |*task| relocateMicrotask(task, v);
    if (machine.next_ticks) |queue|
        for (@constCast(queue.pendingItems())) |*task| relocateMicrotask(task, v);
    if (machine.current_microtask) |*task| relocateMicrotask(task, v);
    for (@constCast(machine.current_microtask_batch)) |*task| relocateMicrotask(task, v);
    for (machine.current_hold_jobs) |job| jsthread.relocateHoldJobRoot(job, v);
    if (machine.async_waiters) |waiters|
        for (waiters.items) |*waiter| gc_relocation.rewriteValueSlot(v, &waiter.promise);
    for (machine.gc_env_roots.items) |*environment| {
        gc_relocation.rewriteRequiredSlot(v, Environment, environment);
        relocateEnv(environment.*, v);
    }
    for (machine.gc_temp_roots.items) |*root| gc_relocation.rewriteValueSlot(v, root);
    for (machine.gc_object_reserve.items) |*object|
        gc_relocation.rewriteRequiredSlot(v, Object, object);
    var literal_it = machine.string_literal_cache.valueIterator();
    while (literal_it.next()) |literal| gc_relocation.rewriteValueSlot(v, literal);
    var template_it = machine.template_cache.valueIterator();
    while (template_it.next()) |template| gc_relocation.rewriteValueSlot(v, template);
    gc_relocation.rewriteOptionalSlot(v, Object, &machine.tdz_marker);
    gc_relocation.rewriteOptionalSlot(v, Object, &machine.global_object);
    var symbol_it = machine.symbols.valueIterator();
    while (symbol_it.next()) |symbol|
        gc_relocation.rewriteRequiredSlot(v, Object, symbol);
    if (machine.import_meta_slot) |slot| {
        gc_relocation.rewriteOptionalSlot(v, Object, &slot.obj);
    } else {
        gc_relocation.rewriteOptionalSlot(v, Object, &machine.import_meta_obj);
    }
    gc_relocation.rewriteValueSlot(v, &machine.ret_value);
    gc_relocation.rewriteValueSlot(v, &machine.this_value);
    gc_relocation.rewriteValueSlot(v, &machine.exception);
    gc_relocation.rewriteValueSlot(v, &machine.new_target);
    gc_relocation.rewriteOptionalSlot(v, Object, &machine.active_native);
    gc_relocation.rewriteOptionalSlot(v, Object, &machine.active_function);
    var call_frame = machine.active_call_frame;
    while (call_frame) |frame| : (call_frame = frame.caller) {
        gc_relocation.rewriteRequiredSlot(v, Object, &frame.func_obj);
        gc_relocation.rewriteOptionalValueSlot(v, &frame.arguments);
    }
    var debug_frame = machine.debug_call_frame;
    while (debug_frame) |frame| : (debug_frame = frame.caller) {
        gc_relocation.rewriteRequiredSlot(v, Environment, &frame.environment);
        relocateEnv(frame.environment, v);
        gc_relocation.rewriteValueSlot(v, &frame.this_value);
    }
    gc_relocation.rewriteOptionalSlot(v, Environment, &machine.debug_top_level_environment);
    if (machine.debug_top_level_environment) |environment| relocateEnv(environment, v);
    gc_relocation.rewriteOptionalSlot(v, Object, &machine.home_object);
    gc_relocation.rewriteOptionalSlot(v, Object, &machine.super_ctor);
    for (machine.with_stack.items) |*object|
        gc_relocation.rewriteRequiredSlot(v, Object, object);
}

test "realm root relocation rewrites active interpreter containers" {
    const context = try ContextMod.Context.create(std.testing.allocator);
    defer context.destroy();
    var machine = context.interpreter();
    var old_objects: [21]Object = undefined;
    var new_objects: [21]Object = undefined;
    var old_environment = Environment{ .arena = std.testing.allocator, .gc_managed = true };
    var new_environment = Environment{ .arena = std.testing.allocator, .gc_managed = true };

    machine.ret_value = Value.obj(&old_objects[0]);
    machine.this_value = Value.obj(&old_objects[1]);
    machine.exception = Value.obj(&old_objects[2]);
    machine.new_target = Value.obj(&old_objects[3]);
    machine.tdz_marker = &old_objects[4];
    machine.global_object = &old_objects[5];
    machine.active_native = &old_objects[6];
    machine.active_function = &old_objects[7];
    machine.home_object = &old_objects[8];
    machine.super_ctor = &old_objects[9];
    var import_meta = interp.ImportMetaSlot{ .obj = &old_objects[10] };
    machine.import_meta_slot = &import_meta;
    try machine.gc_temp_roots.append(machine.arena, Value.obj(&old_objects[11]));
    try machine.gc_object_reserve.append(machine.arena, &old_objects[12]);
    try machine.with_stack.append(machine.arena, &old_objects[13]);
    var literal_node: ast.Node = .undefined_lit;
    try machine.string_literal_cache.put(machine.arena, &literal_node, Value.obj(&old_objects[14]));
    try machine.symbols.put(machine.arena, "root-symbol", &old_objects[15]);

    var operand_stack = [_]Value{ Value.obj(&old_objects[16]), Value.obj(&old_objects[17]) };
    var frame_slots = [_]Value{Value.obj(&old_objects[19])};
    var frame = vm.Frame{ .slots = &frame_slots, .parent = null };
    var execution = vm.Exec{
        .stack = .{ .items = &operand_stack, .capacity = operand_stack.len },
        .acc = Value.obj(&old_objects[18]),
        .frame = &frame,
    };
    try machine.gc_execs.append(machine.arena, &execution);
    try machine.gc_env_roots.append(machine.arena, &old_environment);
    var debug_frame = interp.DebugCallFrame{
        .function_name = "debug",
        .environment = &old_environment,
        .this_value = Value.obj(&old_objects[20]),
        .strict = true,
    };
    machine.debug_call_frame = &debug_frame;
    machine.debug_top_level_environment = &old_environment;

    const Plan = struct {
        old_objects: *[21]Object,
        new_objects: *[21]Object,
        old_environment: *Environment,
        new_environment: *Environment,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            if (old == @as(*anyopaque, @ptrCast(self.old_environment)))
                return @ptrCast(self.new_environment);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_environment = &old_environment,
        .new_environment = &new_environment,
    };
    relocateInterpreterRoots(&machine, &plan);

    try std.testing.expectEqual(&new_objects[0], machine.ret_value.asObj());
    try std.testing.expectEqual(&new_objects[1], machine.this_value.asObj());
    try std.testing.expectEqual(&new_objects[2], machine.exception.asObj());
    try std.testing.expectEqual(&new_objects[3], machine.new_target.asObj());
    try std.testing.expectEqual(&new_objects[4], machine.tdz_marker.?);
    try std.testing.expectEqual(&new_objects[5], machine.global_object.?);
    try std.testing.expectEqual(&new_objects[6], machine.active_native.?);
    try std.testing.expectEqual(&new_objects[7], machine.active_function.?);
    try std.testing.expectEqual(&new_objects[8], machine.home_object.?);
    try std.testing.expectEqual(&new_objects[9], machine.super_ctor.?);
    try std.testing.expectEqual(&new_objects[10], import_meta.obj.?);
    try std.testing.expectEqual(&new_objects[11], machine.gc_temp_roots.items[0].asObj());
    try std.testing.expectEqual(&new_objects[12], machine.gc_object_reserve.items[0]);
    try std.testing.expectEqual(&new_objects[13], machine.with_stack.items[0]);
    try std.testing.expectEqual(&new_objects[14], machine.string_literal_cache.get(&literal_node).?.asObj());
    try std.testing.expectEqual(&new_objects[15], machine.symbols.get("root-symbol").?);
    try std.testing.expectEqual(&new_objects[16], operand_stack[0].asObj());
    try std.testing.expectEqual(&new_objects[17], operand_stack[1].asObj());
    try std.testing.expectEqual(&new_objects[18], execution.acc.asObj());
    try std.testing.expectEqual(&new_objects[19], frame_slots[0].asObj());
    try std.testing.expectEqual(&new_environment, machine.gc_env_roots.items[0]);
    try std.testing.expectEqual(&new_environment, debug_frame.environment);
    try std.testing.expectEqual(&new_objects[20], debug_frame.this_value.asObj());
    try std.testing.expectEqual(&new_environment, machine.debug_top_level_environment.?);
}

test "realm root relocation rewrites Context registries and embedder handles" {
    const context = try ContextMod.Context.create(std.testing.allocator);
    defer context.destroy();

    var old_objects: [18]Object = undefined;
    var new_objects: [18]Object = undefined;
    var old_promises: [2]promise.Promise = .{ .{}, .{} };
    var new_promises: [2]promise.Promise = .{ .{}, .{} };

    const saved_global = context.global_object;
    const saved_tdz = context.tdz_marker;
    const saved_constructors = context.c_api_builtin_constructors;
    const saved_oom = context.reserved_thread_oom_error;
    const saved_private_exception = context.private_pending_exception_root;
    const saved_async_context = context.private_async_context;
    const saved_exception = context.exception;
    defer {
        context.global_object = saved_global;
        context.tdz_marker = saved_tdz;
        context.c_api_builtin_constructors = saved_constructors;
        context.reserved_thread_oom_error = saved_oom;
        context.private_pending_exception_root = saved_private_exception;
        context.private_async_context = saved_async_context;
        context.exception = saved_exception;
        _ = context.env.removeVar("__gc_relocation_context_root__");
    }
    context.global_object = &old_objects[0];
    context.tdz_marker = &old_objects[1];
    context.c_api_builtin_constructors[0] = Value.obj(&old_objects[2]);
    context.reserved_thread_oom_error = Value.obj(&old_objects[3]);
    context.private_pending_exception_root = Value.obj(&old_objects[4]);
    context.private_async_context = Value.obj(&old_objects[16]);
    context.exception = Value.obj(&old_objects[17]);
    try context.env.put("__gc_relocation_context_root__", Value.obj(&old_objects[5]));

    var microtask_items = [_]promise.Microtask{.{
        .kind = .callback,
        .reaction = undefined,
        .argument = Value.undef(),
        .fulfilled = false,
        .callback = Value.obj(&old_objects[6]),
    }};
    var next_tick_items = [_]promise.Microtask{.{
        .kind = .callback,
        .reaction = undefined,
        .argument = Value.undef(),
        .fulfilled = false,
        .callback = Value.obj(&old_objects[7]),
    }};
    const saved_microtasks = context.microtasks.items;
    const saved_microtask_head = context.microtasks.head;
    const saved_next_ticks = context.next_ticks.items;
    const saved_next_tick_head = context.next_ticks.head;
    defer {
        context.microtasks.items = saved_microtasks;
        context.microtasks.head = saved_microtask_head;
        context.next_ticks.items = saved_next_ticks;
        context.next_ticks.head = saved_next_tick_head;
    }
    context.microtasks.items = .{ .items = &microtask_items, .capacity = microtask_items.len };
    context.microtasks.head = 0;
    context.next_ticks.items = .{ .items = &next_tick_items, .capacity = next_tick_items.len };
    context.next_ticks.head = 0;

    var unhandled = [_]*promise.Promise{&old_promises[0]};
    var handled = [_]*promise.Promise{&old_promises[1]};
    var async_waiters = [_]interp.AsyncWaiterEntry{.{ .id = 1, .promise = Value.obj(&old_objects[8]) }};
    var timer_args = [_]Value{Value.obj(&old_objects[10])};
    var timer = ContextMod.Context.TimerRecord{
        .id = 1,
        .owner = &context.microtasks,
        .callback = Value.obj(&old_objects[9]),
        .args = &timer_args,
        .delay_ns = 0,
        .deadline_ns = 0,
        .sequence = 1,
        .repeat = false,
    };
    var timers = [_]*ContextMod.Context.TimerRecord{&timer};
    var finalization_jobs = [_]*Object{&old_objects[11]};
    const PrototypeFinish = struct {
        fn finish(_: *value.CApiClassPrototypeOwner) void {}
    };
    var prototype_owner = value.CApiClassPrototypeOwner{
        .class_ref = undefined,
        .object = &old_objects[12],
        .finish_fn = PrototypeFinish.finish,
    };
    var prototypes = [_]*value.CApiClassPrototypeOwner{&prototype_owner};
    var boxed = Value.obj(&old_objects[13]);
    var handles = [_]ContextMod.Context.CApiHandle{.{ .ref = &boxed, .count = 1 }};
    var strong_root = ContextMod.Context.PrivateStrongRoot{ .value = Value.obj(&old_objects[14]) };
    var strong_roots = [_]*ContextMod.Context.PrivateStrongRoot{&strong_root};
    var weak_root = ContextMod.Context.PrivateWeakRoot{};
    weak_root.target.store(&old_objects[15], .release);
    var weak_roots = [_]*ContextMod.Context.PrivateWeakRoot{&weak_root};

    const saved_unhandled = context.unhandled_rejections;
    const saved_handled = context.handled_rejections;
    const saved_async_waiters = context.async_waiters;
    const saved_timers = context.timers;
    const saved_finalization_jobs = context.finalization_cleanup_jobs;
    const saved_prototypes = context.c_api_class_prototypes;
    const saved_handles = context.c_api_handles;
    const saved_strong_roots = context.private_strong_roots;
    const saved_weak_roots = context.private_weak_roots;
    defer {
        context.unhandled_rejections = saved_unhandled;
        context.handled_rejections = saved_handled;
        context.async_waiters = saved_async_waiters;
        context.timers = saved_timers;
        context.finalization_cleanup_jobs = saved_finalization_jobs;
        context.c_api_class_prototypes = saved_prototypes;
        context.c_api_handles = saved_handles;
        context.private_strong_roots = saved_strong_roots;
        context.private_weak_roots = saved_weak_roots;
    }
    context.unhandled_rejections = .{ .items = &unhandled, .capacity = unhandled.len };
    context.handled_rejections = .{ .items = &handled, .capacity = handled.len };
    context.async_waiters = .{ .items = &async_waiters, .capacity = async_waiters.len };
    context.timers = .{ .items = &timers, .capacity = timers.len };
    context.finalization_cleanup_jobs = .{ .items = &finalization_jobs, .capacity = finalization_jobs.len };
    context.c_api_class_prototypes = .{ .items = &prototypes, .capacity = prototypes.len };
    context.c_api_handles = .{ .items = &handles, .capacity = handles.len };
    context.private_strong_roots = .{ .items = &strong_roots, .capacity = strong_roots.len };
    context.private_weak_roots = .{ .items = &weak_roots, .capacity = weak_roots.len };

    const Plan = struct {
        old_objects: *[18]Object,
        new_objects: *[18]Object,
        old_promises: *[2]promise.Promise,
        new_promises: *[2]promise.Promise,

        pub fn resolve(self: *const @This(), old: *anyopaque) *anyopaque {
            for (self.old_objects, 0..) |*object, index|
                if (old == @as(*anyopaque, @ptrCast(object)))
                    return @ptrCast(&self.new_objects[index]);
            for (self.old_promises, 0..) |*promise_cell, index|
                if (old == @as(*anyopaque, @ptrCast(promise_cell)))
                    return @ptrCast(&self.new_promises[index]);
            return old;
        }
    };
    const plan = Plan{
        .old_objects = &old_objects,
        .new_objects = &new_objects,
        .old_promises = &old_promises,
        .new_promises = &new_promises,
    };
    relocateContextRoots(context, &plan);

    try std.testing.expectEqual(&new_objects[0], context.global_object);
    try std.testing.expectEqual(&new_objects[1], context.tdz_marker);
    try std.testing.expectEqual(&new_objects[2], context.c_api_builtin_constructors[0].asObj());
    try std.testing.expectEqual(&new_objects[3], context.reserved_thread_oom_error.?.asObj());
    try std.testing.expectEqual(&new_objects[4], context.private_pending_exception_root.?.asObj());
    try std.testing.expectEqual(&new_objects[16], context.private_async_context.asObj());
    try std.testing.expectEqual(&new_objects[5], context.env.get("__gc_relocation_context_root__").?.asObj());
    try std.testing.expectEqual(&new_objects[6], microtask_items[0].callback.asObj());
    try std.testing.expectEqual(&new_objects[7], next_tick_items[0].callback.asObj());
    try std.testing.expectEqual(&new_promises[0], context.unhandled_rejections.items[0]);
    try std.testing.expectEqual(&new_promises[1], context.handled_rejections.items[0]);
    try std.testing.expectEqual(&new_objects[8], async_waiters[0].promise.asObj());
    try std.testing.expectEqual(&new_objects[9], timer.callback.asObj());
    try std.testing.expectEqual(&new_objects[10], timer_args[0].asObj());
    try std.testing.expectEqual(&new_objects[11], context.finalization_cleanup_jobs.items[0]);
    try std.testing.expectEqual(&new_objects[12], prototype_owner.object);
    try std.testing.expectEqual(&new_objects[13], boxed.asObj());
    try std.testing.expectEqual(&new_objects[14], strong_root.value.asObj());
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&new_objects[15])), weak_root.target.load(.acquire));
    try std.testing.expectEqual(&new_objects[17], context.exception.?.asObj());
}

fn traceWasmSlot(slot: value.WasmSlot, v: anytype) void {
    switch (slot) {
        .externref, .hostref => |root| markValue(v, root),
        .exnref => |exception| if (exception) |ex|
            for (ex.externrefs) |root| markValue(v, root),
        .gcref => |reference| if (reference) |root| {
            const Marker = struct {
                fn mark(raw: *anyopaque, child: Value) void {
                    const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                    markValue(visitor, child);
                }
            };
            root.trace(root, @ptrCast(v), Marker.mark);
        },
        .externalized_gcref => |root| root.trace(root, @ptrCast(v), struct {
            fn mark(raw: *anyopaque, child: Value) void {
                const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                markValue(visitor, child);
            }
        }.mark),
        .numeric, .vector, .funcref, .i31ref, .externalized_i31 => {},
    }
}

fn traceWasmExecutionRoots(roots: *const value.WasmExecutionRoots, v: anytype) void {
    for (roots.stack) |slot| traceWasmSlot(slot, v);
    for (roots.locals) |slot| traceWasmSlot(slot, v);
    for (roots.exceptions) |exception|
        for (exception.externrefs) |root| markValue(v, root);
}

fn relocateWasmSlot(slot: *value.WasmSlot, v: anytype) void {
    const Rewriter = struct {
        fn rewrite(raw: *anyopaque, root: *Value) void {
            const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
            gc_relocation.rewriteValueSlot(visitor, root);
        }
    };
    switch (slot.*) {
        .externref, .hostref => |*root| gc_relocation.rewriteValueSlot(v, root),
        .exnref => |exception| if (exception) |root| relocateWasmException(v, root),
        .gcref => |reference| if (reference) |root|
            root.relocate(root, @ptrCast(@constCast(v)), Rewriter.rewrite),
        .externalized_gcref => |root| root.relocate(root, @ptrCast(@constCast(v)), Rewriter.rewrite),
        .numeric, .vector, .funcref, .i31ref, .externalized_i31 => {},
    }
}

fn relocateWasmExecutionRoots(roots: *value.WasmExecutionRoots, v: anytype) void {
    for (@constCast(roots.stack)) |*slot| relocateWasmSlot(slot, v);
    for (@constCast(roots.locals)) |*slot| relocateWasmSlot(slot, v);
    for (roots.exceptions) |exception| relocateWasmException(v, exception);
}

/// A `Visitor`-shaped adapter that routes every root it is handed through the
/// insertion write barrier (`gc_runtime.barrier` → the active heap's
/// `writeBarrier`) instead of the marker-private `mark_stack`. This is how a
/// *running* mutator publishes its own roots into a concurrent parallel mark
/// (issue #1 M3): the barrier shades each cell grey and hands it to the marker
/// through the lock-guarded `barrier_buf`, which is the only mutator→marker
/// channel that is safe to touch off the collector thread. Marking is idempotent
/// (a re-shaded cell's CAS just fails), so publishing already-marked roots is
/// cheap. The transitive trace is the marker's job — this only greys the cells
/// the interpreter holds *directly*.
const RootPublishVisitor = struct {
    pub fn mark(_: *RootPublishVisitor, cell: ?*anyopaque) void {
        gc_runtime.barrier(cell);
    }
    // Roots are strong; weak edges are reconciled by the marker at the
    // world-stopped finish, so a publishing mutator must not shade them.
    pub fn markWeak(_: *RootPublishVisitor, _: *?*anyopaque) void {}
    pub fn markWeakAtomic(_: *RootPublishVisitor, _: *std.atomic.Value(?*anyopaque)) void {}
    // The interpreter root set is precise; no conservative words to publish.
    pub fn markConservativeWord(_: *RootPublishVisitor, _: usize) void {}
    pub fn markConservativeWords(_: *RootPublishVisitor, _: [*]const usize, _: usize) void {}
    pub fn deferToFinish(_: *RootPublishVisitor, _: *anyopaque) void {}
    // Always true: publication only happens during a concurrent mark, and this
    // makes `traceEnv` read binding tables under `binding_lock` for the HB edge.
    pub fn concurrent(_: *RootPublishVisitor) bool {
        return true;
    }
    // `barrier` validates the cell itself (magic check), so accept any pointer.
    pub fn isManaged(_: *RootPublishVisitor, cell: ?*anyopaque) bool {
        return cell != null;
    }
    pub fn isMarked(_: *RootPublishVisitor, _: ?*anyopaque) bool {
        return false;
    }
};

/// Publish a running interpreter's precise roots into the active concurrent
/// marker, **from the thread that owns `machine`, at a GC safepoint** (between
/// bytecodes, holding no per-structure lock). Each root cell is shaded through
/// the insertion barrier (`barrier_buf`), so the collector thread can keep
/// draining without ever reading this thread's live VM/native stack. Only the
/// owner can scan its own running stack soundly — this is the per-mutator side
/// of the parallel-GC root handshake (`src/root_handshake.zig`).
pub fn publishInterpreterRoots(machine: *interp.Interpreter) void {
    var pv = RootPublishVisitor{};
    traceInterpreterRoots(machine, &pv);
}

/// Rewrite every precise Context root after weak pruning and while all realm
/// mutators are stopped. Native stacks discovered conservatively are pinned by
/// the relocation plan rather than rewritten here; all typed realm-owned slots
/// mirror `Binding.traceRoots` below.
pub fn relocateContextRoots(ctx: *ContextMod.Context, v: anytype) void {
    gc_relocation.rewriteRequiredSlot(v, Object, &ctx.global_object);
    gc_relocation.rewriteRequiredSlot(v, Object, &ctx.tdz_marker);
    for (&ctx.c_api_builtin_constructors) |*constructor|
        gc_relocation.rewriteValueSlot(v, constructor);
    gc_relocation.rewriteOptionalValueSlot(v, &ctx.reserved_thread_oom_error);
    gc_relocation.rewriteOptionalValueSlot(v, &ctx.private_pending_exception_root);
    gc_relocation.rewriteValueSlot(v, &ctx.private_async_context);
    relocateEnv(&ctx.env, v);

    for (ctx.microtasks.pendingItems()) |*task| relocateMicrotask(task, v);
    for (ctx.next_ticks.pendingItems()) |*task| relocateMicrotask(task, v);

    for (ctx.unhandled_rejections.items) |*rejected|
        gc_relocation.rewriteRequiredSlot(v, promise.Promise, rejected);
    for (ctx.handled_rejections.items) |*handled|
        gc_relocation.rewriteRequiredSlot(v, promise.Promise, handled);
    relocateModuleGraph(&ctx.module_registry, v);
    if (ctx.mod_cache) |cache|
        if (cache != &ctx.module_registry) relocateModuleGraph(cache, v);
    for (ctx.async_waiters.items) |*waiter|
        gc_relocation.rewriteValueSlot(v, &waiter.promise);
    for (ctx.timers.items) |timer| {
        gc_relocation.rewriteValueSlot(v, &timer.callback);
        for (timer.args) |*argument| gc_relocation.rewriteValueSlot(v, argument);
    }
    for (ctx.finalization_cleanup_jobs.items) |*registry|
        gc_relocation.rewriteRequiredSlot(v, Object, registry);
    for (ctx.c_api_class_prototypes.items) |prototype|
        gc_relocation.rewriteRequiredSlot(v, Object, &prototype.object);
    for (ctx.c_api_handles.items) |handle| {
        // Each stable Boxed handle aliases its first field (`Value`).
        const slot: *Value = @ptrCast(@alignCast(handle.ref));
        gc_relocation.rewriteValueSlot(v, slot);
    }
    for (ctx.protected_values.items) |handle|
        gc_relocation.rewriteValueSlot(v, &handle.value);
    for (ctx.private_strong_roots.items) |root|
        gc_relocation.rewriteValueSlot(v, &root.value);
    for (ctx.private_weak_roots.items) |root|
        gc_relocation.rewriteAtomicPointerSlot(v, &root.target);

    if (ctx.gil) |g| jsthread.relocateGilTaskRoots(g, v);
    for (ctx.js_threads.items) |record|
        jsthread.relocateThreadRecordRoots(record, v);
    for (ctx.active_interpreters.items) |machine|
        relocateInterpreterRoots(machine, v);
    if (ctx.gil) |g| for (g.prop_async.items) |raw|
        jsthread.relocatePropAsyncTicketRoot(raw, v);
    gc_relocation.rewriteOptionalValueSlot(v, &ctx.exception);
}

fn StalePointerVisitor(comptime PlanPointer: type) type {
    return struct {
        plan: PlanPointer,

        fn check(self: *@This(), cell: ?*anyopaque) void {
            const pointer = cell orelse return;
            std.debug.assert(!self.plan.moved(pointer));
        }

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            self.check(cell);
        }
        pub fn markWeak(self: *@This(), slot: *?*anyopaque) void {
            self.check(slot.*);
        }
        pub fn markWeakAtomic(self: *@This(), slot: *std.atomic.Value(?*anyopaque)) void {
            self.check(slot.load(.acquire));
        }
        pub fn isMarked(self: *@This(), cell: ?*anyopaque) bool {
            self.check(cell);
            return cell != null;
        }
        pub fn isManaged(self: *@This(), cell: ?*anyopaque) bool {
            self.check(cell);
            return cell != null;
        }
        pub fn concurrent(_: *@This()) bool {
            return false;
        }
        pub fn deferToFinish(self: *@This(), cell: *anyopaque) void {
            self.check(cell);
        }
        pub fn markConservativeWord(_: *@This(), _: usize) void {}
        pub fn markConservativeWords(_: *@This(), _: [*]const usize, _: usize) void {}
    };
}

fn verifyObjectWeakRelocation(o: *Object, v: anytype) void {
    const cold = o.coldState() orelse return;
    if (o.is_weak and (o.is_map or o.is_set)) {
        std.debug.assert(cold.weak_index.count() == 0);
        for (cold.weak_entries.items) |entry| {
            v.mark(entry.key);
            markValue(v, entry.value);
        }
    }
    if (o.behavior.is_finalization_registry) {
        if (cold.finalization_records) |records| for (records.items) |record| {
            v.mark(record.target);
            markValue(v, record.held);
            v.mark(record.token);
        };
    }
}

fn verifyObjectWasmRelocation(o: *Object, v: anytype) void {
    const cold = o.coldState() orelse return;
    const Verifier = struct {
        fn verify(gc_context: ?*anyopaque, callback: ?value.WasmGcTraceRootsFn, visitor: @TypeOf(v)) void {
            const context = gc_context orelse return;
            const verify_callback = callback orelse return;
            const Marker = struct {
                fn mark(raw: *anyopaque, child: Value) void {
                    const stale_visitor: @TypeOf(visitor) = @ptrCast(@alignCast(raw));
                    markValue(stale_visitor, child);
                }
            };
            verify_callback(context, @ptrCast(visitor), Marker.mark);
        }
    };
    switch (cold.rare_tag.load(.acquire)) {
        .wasm_table => Verifier.verify(cold.rare.wasm_table.gc_context, cold.rare.wasm_table.gc_verify, v),
        .wasm_global => Verifier.verify(cold.rare.wasm_global.gc_context, cold.rare.wasm_global.gc_verify, v),
        else => {},
    }
}

// ---- The binding the collector instantiates over -------------------------

/// A tiny stateful binding the collector instantiates over: it just wraps the
/// `*Context` whose roots it traces, so the heap's `ctx: *Binding` indirects to
/// the realm. (Keeping the collector's `Binding`-is-the-ctx contract unchanged
/// means no edit to the shared `zig-gc` library.) Trace logic is the free
/// functions above; root/finalize read `self.context`.
pub const Binding = struct {
    context: *ContextMod.Context,

    pub const Kind = CellKind;

    pub fn recoverAllocationFailure(self: *Binding) bool {
        return self.context.collectForAllocationFailure(currentInterpreter());
    }

    /// Optional zig-gc fast membership hook. The reusable cell backing can
    /// validate an allocation-start address without touching candidate memory;
    /// zig-gc still checks live header magic and retains its hash/list fallback
    /// for delegated allocations and bindings without this hook.
    pub fn ownsCellAllocation(self: *Binding, allocation: *anyopaque) bool {
        const backing = self.context.gc_cell_backing orelse return false;
        return backing.ownsCellAllocation(allocation);
    }

    /// Publish owned-slot classification only after zig-gc has initialized the
    /// complete header. The backing's bucket lock supplies the release/acquire
    /// edge to conservative classifiers on peer threads.
    pub fn publishCellAllocation(self: *Binding, allocation: *anyopaque, total: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.publishCellAllocation(allocation, total);
    }

    /// Amortize publication synchronization for the VM's same-size object
    /// allocation batches while preserving the same header-before-bit order.
    pub fn publishCellAllocationBatch(self: *Binding, payloads: []*anyopaque, total: usize, payload_offset: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.publishCellAllocationBatch(payloads, total, payload_offset);
    }

    /// Withdraw classification before zig-gc clears/finalizes/reuses a header.
    pub fn unpublishCellAllocation(self: *Binding, allocation: *anyopaque, total: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.unpublishCellAllocation(allocation, total);
    }

    /// A successful eligible-size allocation necessarily came from the cell
    /// slab: this backing fails rather than delegating when slab growth OOMs.
    pub fn usesOwnedCellStorage(_: *Binding, total: usize) bool {
        return ContextMod.GcCellBacking.usesCellSlab(total);
    }

    /// Optional zig-gc batch-backing hook. Same-kind cell batches share one
    /// size-class lock while their slabs remain private; zig-gc still owns all
    /// header initialization and metadata publication.
    pub fn allocateCellBatch(self: *Binding, total: usize, out: []*anyopaque) usize {
        const backing = self.context.gc_cell_backing orelse return 0;
        return backing.allocateCellBatch(total, out);
    }

    pub fn reserveRelocationCell(self: *Binding, total: usize) ?*anyopaque {
        const backing = self.context.gc_cell_backing orelse return null;
        return backing.reserveRelocationCell(total);
    }

    pub fn releaseRelocationReservation(self: *Binding, allocation: *anyopaque, total: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.releaseRelocationReservation(allocation, total);
    }

    pub fn commitRelocationCell(self: *Binding, old: *anyopaque, new: *anyopaque, total: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.commitRelocationCell(old, new, total);
    }

    /// Optional zig-gc sweep hook. Dead cells are already finalized and
    /// unlinked; return a bounded same-size run under one backing lock.
    pub fn freeCellStorageBatch(self: *Binding, total: usize, allocations: []*anyopaque) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.freeCellStorageBatch(total, allocations);
    }

    /// Optional zig-gc weak-pass gate. Runtime constructors publish the
    /// Context's monotonic bit before weak semantic state becomes observable.
    pub fn hasWeakWork(self: *Binding) bool {
        return self.context.gc_weak_work.load(.acquire);
    }

    pub fn classifyConservativeInterior(self: *Binding, address: usize) gc.InteriorOwnership {
        const backing = self.context.gc_cell_backing orelse return .outside;
        return backing.classifyConservativeInterior(address);
    }

    pub fn allCellsUseOwnedStorage(_: *Binding) bool {
        return true;
    }

    /// `Context.compactGarbage` opens this token only after rejecting every
    /// unrewritable native/JIT/conservative boundary. The backing then selects
    /// only tail cells that can move into a smaller dense chunk prefix; pinned
    /// prefix cells still use the exact rewrite dispatch below for their edges.
    pub fn canRelocate(self: *Binding, cell: *anyopaque, _: Kind) bool {
        if (!self.context.gc_relocation_active.load(.acquire)) return false;
        const backing = self.context.gc_cell_backing orelse return false;
        return backing.shouldRelocateCell(cell);
    }

    pub fn relocateRoots(self: *Binding, v: anytype) void {
        relocateContextRoots(self.context, v);
    }

    pub fn relocateCell(_: *Binding, cell: *anyopaque, kind: Kind, v: anytype) void {
        switch (kind) {
            .object => relocateObject(@ptrCast(@alignCast(cell)), v),
            .string => relocateString(@ptrCast(@alignCast(cell)), v),
            .environment => relocateEnv(@ptrCast(@alignCast(cell)), v),
            .function => relocateFunction(@ptrCast(@alignCast(cell)), v),
            .bound_fn => relocateBoundFn(@ptrCast(@alignCast(cell)), v),
            .promise => relocatePromise(@ptrCast(@alignCast(cell)), v),
            .generator => relocateGenerator(@ptrCast(@alignCast(cell)), v),
            .iter_helper => relocateIterHelper(@ptrCast(@alignCast(cell)), v),
            .module_ns => relocateModuleNs(@ptrCast(@alignCast(cell)), v),
        }
    }

    pub fn verifyRelocationRoots(self: *Binding, plan: anytype) void {
        var verifier = StalePointerVisitor(@TypeOf(plan)){ .plan = plan };
        self.traceRoots(&verifier);
        if (builtin.is_test) _ = relocation_verifications_for_testing.fetchAdd(1, .monotonic);
    }

    pub fn verifyRelocationCell(_: *Binding, cell: *anyopaque, kind: Kind, plan: anytype) void {
        var verifier = StalePointerVisitor(@TypeOf(plan)){ .plan = plan };
        Binding.trace(cell, kind, &verifier);
        if (kind == .object) {
            const object: *Object = @ptrCast(@alignCast(cell));
            traceObjectEphemeron(object, &verifier);
            verifyObjectWeakRelocation(object, &verifier);
            verifyObjectWasmRelocation(object, &verifier);
        }
        if (builtin.is_test) _ = relocation_verifications_for_testing.fetchAdd(1, .monotonic);
    }

    /// Persistent roots reachable from the realm plus registered active
    /// Interpreter execution roots at quiescent checkpoints.
    pub fn traceRoots(self: *Binding, v: anytype) void {
        const ctx = self.context;
        // Mid-script collection: conservatively root the collecting thread's
        // live native stack + spilled callee-saved registers, which hold the
        // tree-walker's `Value` locals and the VM's transient accumulator. Only
        // enabled (`gc_scan_native_stack`) for a guarded mid-script collect;
        // quiescent collection keeps it off and stays precise. See
        // `stack_scan.zig` and docs/threads/P7-gc-design.md.
        const par: ?*interp.Interpreter = ctx.gc_par_collector.load(.acquire);
        if (ctx.gc_scan_native_stack) {
            _ = stack_scan.scan(v);
            // Plus every parked peer thread's published range (the multi-thread
            // safepoint protocol): their stacks are frozen. Skipped under a
            // *parallel* collection: there, a parked peer is traced precisely via
            // `gc_parked` (below), and its park record's `beginPark`/`endPark`
            // flip too fast to scan race-free without the GIL it doesn't hold.
            if (par == null and ctx.gc_scan_parked_stacks) if (ctx.gil) |g| {
                const me = stack_scan.parkRecord();
                for (g.park_records.items) |rec| {
                    if (rec == me) continue;
                    if (stack_scan.isParked(rec)) stack_scan.scanRecord(rec, v);
                }
            };
        }
        // Under a *parallel* collection (`par` set, the elected collector
        // interpreter) we read each shared realm list under the same lock its
        // mutators take, and trace only the collector's own interpreter + parked
        // peers precisely — running peers self-publish their roots through the
        // insertion barrier (see `Context.driveParallelCollection`).
        v.mark(ctx.global_object);
        v.mark(ctx.tdz_marker);
        for (ctx.c_api_builtin_constructors) |constructor| markValue(v, constructor);
        if (ctx.reserved_thread_oom_error) |err| markValue(v, err);
        if (ctx.private_pending_exception_root) |err| markValue(v, err);
        markValue(v, ctx.private_async_context);
        traceEnv(&ctx.env, v); // the global environment is embedded by value (binding_lock)

        if (par != null) ctx.lockMicrotasks();
        for (ctx.microtasks.pendingItems()) |mt| traceMicrotask(mt, v);
        if (par != null) ctx.unlockMicrotasks();
        if (par != null) ctx.next_ticks.acquire();
        for (ctx.next_ticks.pendingItems()) |mt| traceMicrotask(mt, v);
        if (par != null) ctx.next_ticks.release();

        // `async_waiters` + public `timers` + protected/C-API handles +
        // `finalization_cleanup_jobs` share `realm_lock` (taken by their
        // mutators only under parallel_js).
        ctx.realmLock();
        for (ctx.unhandled_rejections.items) |rejected| markManaged(v, rejected);
        for (ctx.handled_rejections.items) |handled| markManaged(v, handled);
        traceModuleGraph(&ctx.module_registry, v);
        if (ctx.mod_cache) |cache|
            if (cache != &ctx.module_registry) traceModuleGraph(cache, v);
        for (ctx.async_waiters.items) |aw| markValue(v, aw.promise);
        for (ctx.timers.items) |timer| {
            markValue(v, timer.callback);
            for (timer.args) |arg| markValue(v, arg);
        }
        for (ctx.finalization_cleanup_jobs.items) |registry| v.mark(registry);
        for (ctx.c_api_class_prototypes.items) |prototype| v.mark(prototype.object);
        for (ctx.c_api_handles.items) |h| {
            // each ref is a `*Boxed` ({ value: Value }), so the pointer aliases `*Value`.
            const vp: *const Value = @ptrCast(@alignCast(h.ref));
            markValue(v, vp.*);
        }
        for (ctx.protected_values.items) |handle| markValue(v, handle.value);
        for (ctx.private_strong_roots.items) |root| markValue(v, root.value);
        for (ctx.private_weak_roots.items) |root| v.markWeakAtomic(&root.target);
        ctx.realmUnlock();

        if (ctx.gil) |g| jsthread.traceGilTaskRoots(g, v);

        if (par != null) if (ctx.gil) |g| g.lockApi();
        for (ctx.js_threads.items) |rec| {
            const io = agent.engineIo();
            rec.join_mutex.lockUncancelable(io);
            defer rec.join_mutex.unlock(io);
            markValue(v, rec.result);
            if (rec.js_obj) |o| v.mark(o);
            for (rec.pending_joins.items) |pending| v.mark(pending.promise);
            for (rec.settling_joins.items) |pending| v.mark(pending.promise);
        }
        if (par != null) if (ctx.gil) |g| g.unlockApi();

        ctx.lockActiveInterpreters();
        for (ctx.active_interpreters.items) |machine| {
            // In a parallel collection, trace directly only interpreters whose
            // VM stack is *stable*: the collector's own (at its safepoint) and any
            // peer blocked in native park code (`gc_parked` — frozen, not running
            // JS). A *running* peer's stack changes underfoot, so it publishes its
            // own roots through the barrier at a safepoint instead.
            if (par) |collector| {
                if (machine != collector) {
                    // Fast path: a running peer self-publishes; never read its
                    // live stack. The unlocked load is a hint — re-checked below.
                    if (!machine.gc_parked.load(.acquire)) continue;
                    // Looks parked. Pin the frozen state under `gc_root_lock` and
                    // re-check: the owner clears `gc_parked` under the same lock
                    // before it resumes, so if it still reads `true` here the peer
                    // cannot wake and mutate its operand stack / frame slots until
                    // we release. Without this pin the direct read races the
                    // owner's `store_local`/operand-stack writes on wake — the data
                    // race behind the red TSan gate. See `Interpreter.gc_root_lock`.
                    machine.lockGcRoots();
                    defer machine.unlockGcRoots();
                    if (!machine.gc_parked.load(.acquire)) continue; // raced to running
                    traceInterpreterRoots(machine, v);
                    continue;
                }
            }
            traceInterpreterRoots(machine, v);
        }
        ctx.unlockActiveInterpreters();

        if (ctx.gil) |g| {
            g.lockPropWaiters();
            defer g.unlockPropWaiters();
            for (g.prop_async.items) |raw| {
                const t: *jsthread.PropAsyncTicket = @ptrCast(@alignCast(raw));
                v.mark(t.obj);
                v.mark(t.promise);
            }
        }
        // `ctx.exception` is the host/join hand-off slot — redundant with each
        // active interpreter's own `exception` (traced above) and mutated by
        // peers without a lock, so skip it under a parallel collection.
        if (par == null) markValue(v, ctx.exception orelse Value.undef());
    }

    pub fn trace(cell: *anyopaque, kind: Kind, v: anytype) void {
        // `generator` and `iter_helper` have mutable storage that is too
        // entangled to read safely while the mutator runs (a running generator's
        // `exec` is the live VM stack; an iterator helper's `inner`/`padding`
        // update around JS callbacks and `inner` is a 16-byte `?Value`). Under a
        // concurrent mark, defer their tracing to the world-stopped finish (the
        // cell is already marked, so it survives; its edges are found at finish).
        // Object/Environment/Promise are synchronized for concurrent tracing
        // directly (per-structure locks / atomic slots), so they trace inline.
        if (v.concurrent() and (kind == .generator or kind == .iter_helper)) {
            v.deferToFinish(cell);
            return;
        }
        switch (kind) {
            .object => traceObject(@ptrCast(@alignCast(cell)), v),
            .string => {},
            .environment => traceEnv(@ptrCast(@alignCast(cell)), v),
            .function => traceFunction(@ptrCast(@alignCast(cell)), v),
            .bound_fn => traceBoundFn(@ptrCast(@alignCast(cell)), v),
            .promise => tracePromise(@ptrCast(@alignCast(cell)), v),
            .generator => traceGenerator(@ptrCast(@alignCast(cell)), v),
            .iter_helper => traceIterHelper(@ptrCast(@alignCast(cell)), v),
            .module_ns => traceModuleNs(@ptrCast(@alignCast(cell)), v),
        }
    }

    /// Object and Environment mutations are funneled through owner-aware
    /// barriers. Mutable type-erased side cells have a wider set of lifecycle
    /// writes, so quiescent minor GC conservatively rescans those old kinds.
    /// Function cells are rescanned too: most edges are immutable after
    /// publication, but a captured derived-constructor `this_cell.value` is
    /// initialized by `super()` and can therefore acquire a young object.
    pub fn traceOldOnMinor(kind: Kind) bool {
        return kind != .object and kind != .string and kind != .environment;
    }

    pub fn traceEphemeron(self: *Binding, cell: *anyopaque, kind: Kind, v: anytype) void {
        _ = self;
        switch (kind) {
            .object => traceObjectEphemeron(@ptrCast(@alignCast(cell)), v),
            else => {},
        }
    }

    pub fn afterWeak(self: *Binding, cell: *anyopaque, kind: Kind) void {
        switch (kind) {
            .object => {
                const o: *Object = @ptrCast(@alignCast(cell));
                // The heap running this collection is the Context's own (afterWeak
                // only fires mid-collect), and marks are still valid (pre-sweep).
                const heap = self.context.gc orelse return;
                if (pruneDeadWeakEntries(o, heap)) self.context.queueFinalizationRegistryCleanup(o);
            },
            else => {},
        }
    }

    pub fn afterWeakRoots(self: *Binding) void {
        self.context.runPrivateWeakFinalizers();
    }

    /// Drain embedder callbacks only after zig-gc has completed sweep, released
    /// its allocation lock, and restored allocation publication. Cell
    /// finalizers themselves merely enqueue stable Context-owned records.
    pub fn afterSweep(self: *Binding) void {
        self.context.runDeferredPostSweepCallbacks();
    }

    /// A cell is being reclaimed. Arena-mode `ArrayBufferData` is released with
    /// the arena, but GC-mode buffers own their metadata and non-shared byte
    /// slabs individually. A SharedArrayBuffer wrapper owns one realm retain
    /// that must be released when the wrapper cell dies.
    pub fn finalize(self: *Binding, cell: *anyopaque, kind: Kind) void {
        if (self.context.gc_finalizer_stats_out) |stats| stats.addKind(kind);
        switch (kind) {
            .object => {
                const o: *Object = @ptrCast(@alignCast(cell));
                if (o.cApiObjectOwner()) |owner| self.context.queueCApiObjectFinish(owner);
                if (o.wasmGcReference()) |state| {
                    if (state.root) |root| if (state.release) |release| release(root, o);
                    state.root = null;
                    state.reference = null;
                }
                if (o.wasmException()) |state| {
                    if (state.exception) |exception|
                        _ = exception.wrapper.cmpxchgStrong(o, null, .acq_rel, .acquire);
                    state.exception = null;
                }
                // Buffer metadata now lives in the cold sidecar. Release it
                // before finalizeObjectBacking destroys that sidecar.
                if (o.arrayBuffer()) |ab| {
                    if (self.context.gc_finalizer_stats_out) |stats| {
                        stats.array_buffers += 1;
                        if (ab.shared != null) stats.shared_array_buffers += 1;
                    }
                    if (ab.native_handle.swap(null, .acq_rel)) |handle| handle.releaseWrapper();
                    if (ab.shared) |storage| {
                        const sab_released = self.context.sab_retains.releaseTracked(storage);
                        std.debug.assert(sab_released);
                        if (sab_released) ab.shared = null;
                    } else if (ab.external_owner) |owner| {
                        self.context.queueExternalOwnerRelease(owner);
                        ab.external_owner = null;
                    } else if (ab.gc_owned and ab.local_data.len > 0) {
                        self.context.gpa.rawFree(ab.local_data, .@"8", @returnAddress());
                        _ = @atomicRmw(usize, &self.context.gc_array_buffer_bytes_live, .Sub, ab.local_data.len, .monotonic);
                        ab.local_data = &.{};
                    }
                    if (ab.gc_owned) {
                        self.context.gpa.destroy(ab);
                        o.clearArrayBuffer();
                    }
                }
                const backing_flags = o.backingFlagsSnapshot();
                if (hasObjectBacking(backing_flags) or o.privateBrands() != null) {
                    const released = finalizeObjectBacking(o, o.backingAllocatorIfActive() orelse self.context.gpa);
                    if (released > 0) {
                        if (self.context.gc_finalizer_stats_out) |stats| stats.object_backing_releases += released;
                        _ = @atomicRmw(usize, &self.context.gc_object_backing_stores_live, .Sub, released, .monotonic);
                    }
                }
            },
            .string => {
                const string: *StringCell = @ptrCast(@alignCast(cell));
                if (string.externalOwner()) |owner| {
                    self.context.queueExternalStringRelease(owner);
                    string.setExternalOwner(null);
                }
                if (string.bytes.len > 0) self.context.gpa.free(@constCast(string.bytes));
                _ = @atomicRmw(usize, &self.context.gc_string_bytes_live, .Sub, string.bytes.len, .monotonic);
                string.bytes = &.{};
                string.setGcManaged(false);
            },
            .environment => finalizeEnv(@ptrCast(@alignCast(cell))),
            .generator => finalizeGenerator(
                @ptrCast(@alignCast(cell)),
                self.context.gpa,
                &self.context.gc_generator_backing_stores_live,
            ),
            .promise => {
                const p: *promise.Promise = @ptrCast(@alignCast(cell));
                if (p.gc_owned) {
                    const count = p.on_fulfill.items.len + p.on_reject.items.len +
                        @intFromBool(p.on_fulfill_inline != null) + @intFromBool(p.on_reject_inline != null);
                    if (self.context.gc_finalizer_stats_out) |stats| stats.promise_reactions += count;
                    p.on_fulfill.deinit(self.context.gpa);
                    p.on_reject.deinit(self.context.gpa);
                    p.on_fulfill_inline = null;
                    p.on_reject_inline = null;
                    p.on_fulfill = .empty;
                    p.on_reject = .empty;
                    if (count > 0) {
                        _ = @atomicRmw(usize, &self.context.gc_promise_reactions_live, .Sub, count, .monotonic);
                    }
                }
            },
            else => {},
        }
    }
};

/// The engine's GC heap type. `Context` holds one behind `enable_gc`.
pub const Heap = gc.Heap(Binding);

test "GC relocation binding dispatch is complete" {
    var object = Object{};
    object.initInlineSlots();
    var binding = Binding{ .context = undefined };
    const IdentityPlan = struct {
        pub fn resolve(_: *const @This(), old: *anyopaque) *anyopaque {
            return old;
        }
    };
    const plan = IdentityPlan{};

    binding.relocateCell(&object, .object, &plan);
    try std.testing.expect(@hasDecl(Binding, "canRelocate"));
    try std.testing.expect(@hasDecl(Binding, "relocateRoots"));
    try std.testing.expect(@hasDecl(Binding, "relocateCell"));
}

test "Object fits the 128-byte GC slab and cold sidecar fits 256 bytes" {
    // The raw payload can differ across target ABIs even when the allocator
    // selects the same slab. Keep the production invariant target-independent.
    try std.testing.expect(@sizeOf(Object) <= 128);
    // Auto-layout may reorder the cold fields across compiler revisions. Its
    // GC allocation class below is the production invariant, not one raw size.
    try std.testing.expectEqual(@as(usize, 128), Heap.cellAllocationBytes(Object));
    try std.testing.expect(Heap.cellAllocationBytes(value.ObjectColdState) <= 256);
}

fn managedCellType(comptime kind: CellKind) type {
    return switch (kind) {
        .object => Object,
        .string => StringCell,
        .environment => Environment,
        .function => interp.Function,
        .bound_fn => interp.Interpreter.BoundFn,
        .promise => promise.Promise,
        .generator => vm.Generator,
        .iter_helper => value.IterHelper,
        .module_ns => interp.ModuleNs,
    };
}

comptime {
    if (Heap.cellAllocationBytes(Object) > 512)
        @compileError("Object payload no longer fits the 512-byte GC slab");
    for (@typeInfo(CellKind).@"enum".field_values) |raw_kind| {
        const Cell = managedCellType(@enumFromInt(raw_kind));
        if (!ContextMod.GcCellBacking.usesCellSlab(Heap.cellAllocationBytes(Cell)))
            @compileError("GC cell exceeds owned slab storage: " ++ @typeName(Cell));
    }
}

/// Allocate an `Object` cell through the GC heap when present (tagged
/// `.object`), else from the arena — today's engine. `heap_erased` is
/// `Context.gc` passed type-erased so `interpreter.zig` need not name the Heap
/// type (keeping the gc↔interpreter import edge to plain functions). The
/// returned payload is default-initialized so pointer slots are safe even for
/// allocation sites that fill fields incrementally.
pub fn allocObject(heap_erased: ?*anyopaque, arena: std.mem.Allocator) std.mem.Allocator.Error!*Object {
    if (heap_erased) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        const o = try heap.create(Object, .object);
        o.* = .{};
        o.initInlineSlots();
        return o;
    }
    const o = try arena.create(Object);
    o.* = .{};
    o.initInlineSlots();
    return o;
}

/// Allocate and default-initialize a same-kind prefix for callers that can
/// consume several objects before their next safepoint. GC-backed heaps
/// publish the prefix under one metadata lock; arena mode preserves the same
/// short-prefix/OOM ordering by returning prior successful allocations before
/// retrying the failed position on the next call.
pub fn allocObjectBatch(heap_erased: ?*anyopaque, arena: std.mem.Allocator, out: []*Object) std.mem.Allocator.Error!usize {
    if (out.len == 0) return 0;
    if (heap_erased) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        const count = try heap.createBatch(Object, .object, out);
        for (out[0..count]) |o| {
            o.* = .{};
            o.initInlineSlots();
        }
        if (builtin.is_test) _ = object_batch_cells_for_testing.fetchAdd(count, .monotonic);
        return count;
    }

    var count: usize = 0;
    while (count < out.len) {
        const o = arena.create(Object) catch |err| {
            if (count == 0) return err;
            break;
        };
        o.* = .{};
        o.initInlineSlots();
        out[count] = o;
        count += 1;
    }
    return count;
}

/// The GC heap whose cells the *current thread* allocates into, or null for the
/// arena. Each shared-realm thread sets it to the same context heap on entry;
/// it is set/restored at the realm's allocation entry points — `createWith`
/// for intrinsics, `evaluate`/`evaluateModule` for execution. This lets every
/// scattered `*.create(value.Object)` site funnel through `allocObj(arena)`
/// without threading the heap pointer through hundreds of signatures.
threadlocal var active_heap: ?*anyopaque = null;
threadlocal var active_interpreter: ?*interp.Interpreter = null;

/// Install `h` as this thread's active heap, returning the previous value (so
/// nested entry points can restore it). Pass null for the arena engine.
pub fn setActiveHeap(h: ?*anyopaque) ?*anyopaque {
    const prev = active_heap;
    active_heap = h;
    if (h) |raw| {
        const heap: *Heap = @ptrCast(@alignCast(raw));
        _ = strcell.setActiveManagedFactory(.{
            .context = raw,
            .create = allocManagedString,
            .create_owned = allocManagedStringOwned,
        });
        // Non-cell object side stores do not need the GC cell slab classifier in
        // single-mutator GC mode. True-parallel JS keeps the synchronized wrapper
        // because the embedder's allocator may not be thread-safe.
        const backing_allocator = if (heap.ctx.context.parallel_js) heap.backing else heap.ctx.context.gpa;
        _ = gc_runtime.setActive(.{ .object_backing = .{
            .allocator = backing_allocator,
            .stores_live = &heap.ctx.context.gc_object_backing_stores_live,
        } });
        _ = gc_runtime.setBarrier(raw, barrierThunk, weakBarrierThunk);
    } else {
        _ = strcell.setActiveManagedFactory(null);
        _ = gc_runtime.setActive(.{});
        _ = gc_runtime.setBarrier(null, null, null);
    }
    return prev;
}

fn finishManagedString(heap: *Heap, bytes: []u8) std.mem.Allocator.Error!*StringCell {
    errdefer heap.ctx.context.gpa.free(bytes);
    const cell = try heap.create(StringCell, .string);
    cell.* = .{ .bytes = bytes, .hash = strcell.hashBytes(bytes) };
    cell.setGcManaged(true);
    _ = @atomicRmw(usize, &heap.ctx.context.gc_string_bytes_live, .Add, bytes.len, .monotonic);
    return cell;
}

fn allocManagedString(
    raw: *anyopaque,
    _: std.mem.Allocator,
    source: []const u8,
) std.mem.Allocator.Error!*StringCell {
    const heap: *Heap = @ptrCast(@alignCast(raw));
    const bytes = try strcell.canonicalizeSurrogates(heap.ctx.context.gpa, source);
    return finishManagedString(heap, bytes);
}

fn allocManagedStringOwned(
    raw: *anyopaque,
    source_allocator: std.mem.Allocator,
    source: []u8,
) std.mem.Allocator.Error!*StringCell {
    const heap: *Heap = @ptrCast(@alignCast(raw));
    const target_allocator = heap.ctx.context.gpa;
    if (source_allocator.ptr == target_allocator.ptr and
        source_allocator.vtable == target_allocator.vtable and
        std.mem.indexOfScalar(u8, source, 0xED) == null)
    {
        return finishManagedString(heap, source);
    }
    defer source_allocator.free(source);
    const bytes = try strcell.canonicalizeSurrogates(target_allocator, source);
    return finishManagedString(heap, bytes);
}

/// Whether the current thread's cell-allocation funnels target the GC heap.
/// Callers use this immediately after allocation to persist exact ownership on
/// cell types that can also be embedded in a Context or allocated by an arena.
pub inline fn allocationsAreManaged() bool {
    return active_heap != null;
}

/// Install the interpreter currently executing JS on this thread. Allocation
/// failure recovery uses this only as an internal safepoint-owned capability:
/// if no interpreter is active, GC cell OOM recovery remains fail-closed.
pub fn setActiveInterpreter(machine: ?*interp.Interpreter) ?*interp.Interpreter {
    const prev = active_interpreter;
    active_interpreter = machine;
    return prev;
}

pub fn currentInterpreter() ?*interp.Interpreter {
    return active_interpreter;
}

/// Type-erased entry the `gc_runtime` shim calls at reference-store sites. The
/// heap maintains both the nursery remembered set and the incremental/full mark
/// invariant; see `gc_runtime.barrierFrom`.
fn barrierThunk(raw_heap: *anyopaque, owner: ?*anyopaque, cell: ?*anyopaque) void {
    const heap: *Heap = @ptrCast(@alignCast(raw_heap));
    heap.writeBarrierFrom(owner, cell);
}

fn weakBarrierThunk(raw_heap: *anyopaque, owner: ?*anyopaque) void {
    const heap: *Heap = @ptrCast(@alignCast(raw_heap));
    heap.writeBarrierWeak(owner);
}

/// Insertion write barrier for a stored `Value`. Objects and heap-managed
/// runtime strings carry cells; static/arena/interned strings are filtered.
/// Call at every post-creation store of a reference into a live GC cell.
pub inline fn barrierValue(v: Value) void {
    if (v.isObject()) {
        gc_runtime.barrier(@ptrCast(v.asObj()));
    } else if (v.isString()) {
        const cell = v.asStringCell();
        if (cell.isGcManaged()) gc_runtime.barrier(@constCast(cell));
    }
}

pub inline fn barrierValueFrom(owner: ?*anyopaque, v: Value) void {
    if (v.isObject()) {
        gc_runtime.barrierFrom(owner, @ptrCast(v.asObj()));
    } else if (v.isString()) {
        const cell = v.asStringCell();
        if (cell.isGcManaged()) gc_runtime.barrierFrom(owner, @constCast(cell));
    }
}

/// Insertion write barrier for a stored cell pointer (Object/Environment/…).
pub inline fn barrierCell(cell: ?*anyopaque) void {
    gc_runtime.barrier(cell);
}

pub inline fn barrierCellFrom(owner: ?*anyopaque, cell: ?*anyopaque) void {
    gc_runtime.barrierFrom(owner, cell);
}

/// Barrier an edge whose owner and child are known exact live payloads from the
/// active heap. Returns false in arena mode so callers can retain their generic
/// store path. The strict zig-gc entry avoids classifying either pointer through
/// the tolerant live-payload index.
pub inline fn barrierExactManagedCellFrom(owner: *anyopaque, cell: *anyopaque) bool {
    const raw = active_heap orelse return false;
    const heap: *Heap = @ptrCast(@alignCast(raw));
    heap.writeBarrierFromManaged(owner, cell);
    return true;
}

pub inline fn barrierWeak(owner: ?*anyopaque) void {
    gc_runtime.barrierWeak(owner);
}

/// Allocate an `Object` cell from the thread's active GC heap (tagged
/// `.object`), or `arena` when the GC is off. The dominant allocation funnel:
/// the migrated `*.create(value.Object)` sites call this with the allocator
/// they already had in scope as the fallback.
pub fn allocObj(arena: std.mem.Allocator) std.mem.Allocator.Error!*Object {
    if (active_heap) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        const o = try heap.create(Object, .object);
        o.* = .{};
        o.initInlineSlots();
        return o;
    }
    const o = try arena.create(Object);
    o.* = .{};
    o.initInlineSlots();
    return o;
}

/// Per-side-cell allocation funnels — same thread-local-active-heap rule as
/// `allocObj`, each tagged with its own `CellKind` so `trace`/`finalize`
/// dispatch correctly. These make the *cell* heap uniform (every heap object a
/// GC cell), the prerequisite for sound quiescent-point collection. Known
/// runtime side buffers owned by these cells are now either traced as ordinary
/// fields or recorded as GC-owned backing stores and released by finalizers.
fn allocCell(comptime T: type, kind: CellKind, arena: std.mem.Allocator) std.mem.Allocator.Error!*T {
    if (active_heap) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        return heap.create(T, kind);
    }
    return arena.create(T);
}

pub fn allocEnv(arena: std.mem.Allocator) std.mem.Allocator.Error!*Environment {
    return allocCell(Environment, .environment, arena);
}
pub fn allocFunction(arena: std.mem.Allocator) std.mem.Allocator.Error!*interp.Function {
    return allocCell(interp.Function, .function, arena);
}
pub fn allocPromise(arena: std.mem.Allocator) std.mem.Allocator.Error!*promise.Promise {
    return allocCell(promise.Promise, .promise, arena);
}
pub fn allocGenerator(arena: std.mem.Allocator) std.mem.Allocator.Error!*vm.Generator {
    const g = try allocCell(vm.Generator, .generator, arena);
    initGeneratorBacking(g);
    return g;
}

pub fn initGeneratorBacking(g: *vm.Generator) void {
    if (active_heap) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        g.backing_allocator = heap.ctx.context.gpa;
        g.backing_stores_live = &heap.ctx.context.gc_generator_backing_stores_live;
    }
}
pub fn allocBoundFn(arena: std.mem.Allocator) std.mem.Allocator.Error!*interp.Interpreter.BoundFn {
    return allocCell(interp.Interpreter.BoundFn, .bound_fn, arena);
}
pub fn allocIterHelper(arena: std.mem.Allocator) std.mem.Allocator.Error!*value.IterHelper {
    return allocCell(value.IterHelper, .iter_helper, arena);
}
pub fn allocModuleNs(arena: std.mem.Allocator) std.mem.Allocator.Error!*interp.ModuleNs {
    return allocCell(interp.ModuleNs, .module_ns, arena);
}

// ---------------------------------------------------------------------------
// Test — validate the real `traceObject` logic against real `value.Object`s,
// driven by a minimal test binding (roots are a list, not a Context). Proves
// the binding traces proto/slots/accessors and reclaims cycles + garbage.
// ---------------------------------------------------------------------------

const TestEngine = struct {
    pub const Kind = CellKind;
    gpa: std.mem.Allocator,
    roots: std.ArrayListUnmanaged(*Object) = .empty,

    pub fn traceRoots(self: *TestEngine, v: anytype) void {
        for (self.roots.items) |o| v.mark(o);
    }
    pub fn trace(cell: *anyopaque, kind: @This().Kind, v: anytype) void {
        // The test only builds .object cells; reuse the production tracer.
        std.debug.assert(kind == .object);
        traceObject(@ptrCast(@alignCast(cell)), v);
    }
    /// A dying Object owns its slots/elements/accessors backing memory (the GC
    /// frees only the cell itself), so finalize releases them — the same
    /// responsibility M1's real finalize carries for non-arena sub-allocations.
    pub fn finalize(self: *TestEngine, cell: *anyopaque, kind: @This().Kind) void {
        std.debug.assert(kind == .object);
        const o: *Object = @ptrCast(@alignCast(cell));
        if (o.slotsState()) |state| {
            state.list.deinit(self.gpa);
            self.gpa.destroy(state);
        }
        if (o.elementsState()) |state| {
            state.list.deinit(self.gpa);
            self.gpa.destroy(state);
        }
        if (o.accessorsMap()) |acc| {
            acc.deinit(self.gpa);
            self.gpa.destroy(acc);
        }
        if (o.coldState()) |cold| self.gpa.destroy(cold);
        if (o.storageState()) |storage| self.gpa.destroy(storage);
    }
};

test "gc binding: real Object graph — proto/slots/accessors survive, garbage swept" {
    const a = std.testing.allocator;
    var eng = TestEngine{ .gpa = a };
    defer eng.roots.deinit(a);

    var heap = gc.Heap(TestEngine).init(a, &eng);
    defer heap.deinit(); // finalizes every survivor (freeing its slots/accessors)

    // root --slot--> child --proto--> gp ; gp --slot--> root (cycle).
    const root = try heap.create(Object, .object);
    root.* = .{};
    const child = try heap.create(Object, .object);
    child.* = .{};
    const gp = try heap.create(Object, .object);
    gp.* = .{};
    const garbage = try heap.create(Object, .object);
    garbage.* = .{};

    var occupied_shape = Shape{
        .parent = null,
        .name = "edge",
        .slot = 0,
        .count = 1,
        .arena = a,
    };
    root.shape = &occupied_shape;
    root.inline_slots[0] = Value.obj(child);
    child.proto = gp;
    gp.shape = &occupied_shape;
    gp.inline_slots[0] = Value.obj(root); // cycle back to the root
    // `garbage` is unreferenced.
    try eng.roots.append(a, root);
    try std.testing.expectEqual(@as(usize, 4), heap.live_cells);

    heap.collect();
    // root, child, gp reachable; garbage collected (finalize freed its memory).
    try std.testing.expectEqual(@as(usize, 3), heap.live_cells);

    // Accessor edges are traced too: attach one to a fresh rooted object.
    const holder = try heap.create(Object, .object);
    holder.* = .{};
    const acc_target = try heap.create(Object, .object);
    acc_target.* = .{};
    const map = try a.create(std.StringHashMapUnmanaged(value.Accessor));
    map.* = .{};
    try map.put(a, "x", .{ .get = Value.obj(acc_target), .set = null });
    const holder_cold = try holder.ensureCold(a);
    holder_cold.accessors.store(map, .monotonic);
    try eng.roots.append(a, holder);

    heap.collect();
    // root-set {root,child,gp,holder,acc_target} all live; nothing new dies.
    try std.testing.expectEqual(@as(usize, 5), heap.live_cells);

    // Drop every root → everything is garbage; finalize frees each cell's memory.
    eng.roots.clearRetainingCapacity();
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.live_cells);
}

test "gc pruneDeadWeakEntries removes dead weak keys with unordered tail removal" {
    const a = std.testing.allocator;
    var live_key: u8 = 1;
    var dead_key_a: u8 = 2;
    var dead_key_b: u8 = 3;

    var cold = value.ObjectColdState{};
    var storage = value.ObjectStorageState{ .owner_allocator = a };
    storage.cold.store(&cold, .monotonic);
    var o = Object{ .is_weak = true, .is_map = true, .storage = .init(&storage) };
    defer cold.weak_entries.deinit(a);
    try cold.weak_entries.append(a, .{ .key = @ptrCast(&dead_key_a), .value = Value.num(10) });
    try cold.weak_entries.append(a, .{ .key = @ptrCast(&dead_key_b), .value = Value.num(20) });
    try cold.weak_entries.append(a, .{ .key = @ptrCast(&live_key), .value = Value.num(30) });

    const FakeHeap = struct {
        live: ?*anyopaque,
        pub fn isLive(self: *const @This(), ptr: ?*anyopaque) bool {
            return ptr != null and ptr == self.live;
        }
    };
    const heap = FakeHeap{ .live = @ptrCast(&live_key) };

    try std.testing.expect(!pruneDeadWeakEntries(&o, &heap));
    try std.testing.expectEqual(@as(usize, 1), cold.weak_entries.items.len);
    try std.testing.expectEqual(@intFromPtr(&live_key), @intFromPtr(cold.weak_entries.items[0].key.?));
}

test "gc traces only the active microtask variant" {
    const Recorder = struct {
        marked: [8]?*anyopaque = .{ null, null, null, null, null, null, null, null },
        len: usize = 0,

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            const p = cell orelse return;
            self.marked[self.len] = p;
            self.len += 1;
        }

        fn contains(self: *const @This(), cell: *anyopaque) bool {
            for (self.marked[0..self.len]) |marked| {
                if (marked == cell) return true;
            }
            return false;
        }
    };

    var reaction_handler = Object{};
    var reaction_argument = Object{};
    var thenable = Object{};
    var then_fn = Object{};
    var inactive_argument = Object{};
    var reaction_result = promise.Promise{ .gc_owned = true };
    var thenable_result = promise.Promise{ .gc_owned = true };
    var inactive_result = promise.Promise{ .gc_owned = true };

    var reaction_marks = Recorder{};
    traceMicrotask(.{
        .kind = .reaction,
        .reaction = .{ .handler = Value.obj(&reaction_handler), .result = &reaction_result },
        .argument = Value.obj(&reaction_argument),
        .fulfilled = true,
        .thenable = Value.obj(&thenable),
        .then_fn = Value.obj(&then_fn),
        .promise = &inactive_result,
    }, &reaction_marks);
    try std.testing.expect(reaction_marks.contains(&reaction_handler));
    try std.testing.expect(reaction_marks.contains(&reaction_argument));
    try std.testing.expect(reaction_marks.contains(&reaction_result));
    try std.testing.expect(!reaction_marks.contains(&thenable));
    try std.testing.expect(!reaction_marks.contains(&then_fn));
    try std.testing.expect(!reaction_marks.contains(&inactive_result));

    var thenable_marks = Recorder{};
    traceMicrotask(.{
        .kind = .thenable,
        .reaction = .{ .handler = Value.obj(&reaction_handler), .result = &inactive_result },
        .argument = Value.obj(&inactive_argument),
        .fulfilled = true,
        .thenable = Value.obj(&thenable),
        .then_fn = Value.obj(&then_fn),
        .promise = &thenable_result,
    }, &thenable_marks);
    try std.testing.expect(thenable_marks.contains(&thenable));
    try std.testing.expect(thenable_marks.contains(&then_fn));
    try std.testing.expect(thenable_marks.contains(&thenable_result));
    try std.testing.expect(!thenable_marks.contains(&reaction_handler));
    try std.testing.expect(!thenable_marks.contains(&inactive_argument));
    try std.testing.expect(!thenable_marks.contains(&inactive_result));

    var next_tick_callback = Object{};
    var next_tick_first = Object{};
    var next_tick_second = Object{};
    const next_tick_args = [_]Value{ Value.obj(&next_tick_first), Value.obj(&next_tick_second) };
    var next_tick_marks = Recorder{};
    traceMicrotask(.{
        .kind = .next_tick,
        .reaction = undefined,
        .argument = Value.obj(&inactive_argument),
        .fulfilled = true,
        .job = Value.obj(&next_tick_callback),
        .job_args = &next_tick_args,
    }, &next_tick_marks);
    try std.testing.expect(next_tick_marks.contains(&next_tick_callback));
    try std.testing.expect(next_tick_marks.contains(&next_tick_first));
    try std.testing.expect(next_tick_marks.contains(&next_tick_second));
    try std.testing.expect(!next_tick_marks.contains(&inactive_argument));
}

test "Wasm relocation: direct and exception-payload execution roots" {
    const Recorder = struct {
        marked: [7]?*anyopaque = .{ null, null, null, null, null, null, null },
        len: usize = 0,

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            const ptr = cell orelse return;
            self.marked[self.len] = ptr;
            self.len += 1;
        }

        fn contains(self: *const @This(), cell: *anyopaque) bool {
            for (self.marked[0..self.len]) |marked|
                if (marked == cell) return true;
            return false;
        }
    };

    var stack_ref = Object{};
    var local_ref = Object{};
    var numeric_only = Object{};
    var funcref_only = Object{};
    var nested_ref = Object{};
    var pending_ref = Object{};
    var aggregate_ref = Object{};
    var host_ref = Object{};
    var new_stack_ref = Object{};
    var new_local_ref = Object{};
    var new_nested_ref = Object{};
    var new_pending_ref = Object{};
    var new_aggregate_ref = Object{};
    var new_host_ref = Object{};
    var dummy_tag: u8 = 0;
    var dummy_owner: u8 = 0;
    var aggregate_value = Value.obj(&aggregate_ref);
    const AggregateTrace = struct {
        fn trace(reference: *value.WasmGcRef, raw: *anyopaque, mark: value.WasmGcMarkValueFn) void {
            const child: *Value = @ptrCast(@alignCast(reference.context));
            mark(raw, child.*);
        }

        fn relocate(reference: *value.WasmGcRef, raw: *anyopaque, rewrite: value.WasmGcRewriteValueFn) void {
            const child: *Value = @ptrCast(@alignCast(reference.context));
            rewrite(raw, child);
        }
    };
    var aggregate_header: value.WasmGcRef = .{
        .context = @ptrCast(&aggregate_value),
        .trace = AggregateTrace.trace,
        .relocate = AggregateTrace.relocate,
    };
    var nested_payload = [_]value.WasmSlot{.{ .externref = Value.obj(&nested_ref) }};
    var nested_externrefs = [_]Value{Value.obj(&nested_ref)};
    var nested_exception: value.WasmException = .{
        .tag = @ptrCast(&dummy_tag),
        .payload = &nested_payload,
        .externrefs = &nested_externrefs,
        .owner = @ptrCast(&dummy_owner),
    };
    var pending_payload = [_]value.WasmSlot{.{ .externref = Value.obj(&pending_ref) }};
    var pending_externrefs = [_]Value{Value.obj(&pending_ref)};
    var pending_exception: value.WasmException = .{
        .tag = @ptrCast(&dummy_tag),
        .payload = &pending_payload,
        .externrefs = &pending_externrefs,
        .owner = @ptrCast(&dummy_owner),
    };
    var stack = [_]value.WasmSlot{
        .{ .numeric = @intFromPtr(&numeric_only) },
        .{ .funcref = @ptrCast(&funcref_only) },
        .{ .externref = Value.obj(&stack_ref) },
        .{ .exnref = &nested_exception },
        .{ .gcref = &aggregate_header },
        .{ .hostref = Value.obj(&host_ref) },
        .{ .externalized_gcref = &aggregate_header },
    };
    var locals = [_]value.WasmSlot{.{ .externref = Value.obj(&local_ref) }};
    var roots: value.WasmExecutionRoots = .{
        .stack = &stack,
        .locals = &locals,
        .exceptions = &.{&pending_exception},
    };
    var recorder: Recorder = .{};
    traceWasmExecutionRoots(&roots, &recorder);
    try std.testing.expect(recorder.contains(&stack_ref));
    try std.testing.expect(recorder.contains(&local_ref));
    try std.testing.expect(recorder.contains(&nested_ref));
    try std.testing.expect(recorder.contains(&pending_ref));
    try std.testing.expect(recorder.contains(&aggregate_ref));
    try std.testing.expect(recorder.contains(&host_ref));
    try std.testing.expect(!recorder.contains(&numeric_only));
    try std.testing.expect(!recorder.contains(&funcref_only));

    const Plan = struct {
        old: [6]*Object,
        new: [6]*Object,

        pub fn resolve(self: *const @This(), pointer: *anyopaque) *anyopaque {
            for (self.old, self.new) |old, new|
                if (pointer == @as(*anyopaque, @ptrCast(old))) return @ptrCast(new);
            return pointer;
        }
    };
    const plan = Plan{
        .old = .{ &stack_ref, &local_ref, &nested_ref, &pending_ref, &aggregate_ref, &host_ref },
        .new = .{ &new_stack_ref, &new_local_ref, &new_nested_ref, &new_pending_ref, &new_aggregate_ref, &new_host_ref },
    };
    relocateWasmExecutionRoots(&roots, &plan);
    try std.testing.expectEqual(&new_stack_ref, stack[2].externref.asObj());
    try std.testing.expectEqual(&new_nested_ref, nested_payload[0].externref.asObj());
    try std.testing.expectEqual(&new_nested_ref, nested_externrefs[0].asObj());
    try std.testing.expectEqual(&new_aggregate_ref, aggregate_value.asObj());
    try std.testing.expectEqual(&new_host_ref, stack[5].hostref.asObj());
    try std.testing.expectEqual(&new_local_ref, locals[0].externref.asObj());
    try std.testing.expectEqual(&new_pending_ref, pending_payload[0].externref.asObj());
    try std.testing.expectEqual(&new_pending_ref, pending_externrefs[0].asObj());
    try std.testing.expectEqual(@intFromPtr(&numeric_only), stack[0].numeric);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&funcref_only)), stack[1].funcref);
}
