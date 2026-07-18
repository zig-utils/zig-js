//! JavaScript-facing WebAssembly MVP API (issue #141).
//!
//! The namespace includes synchronous constructors/reflection and Promise-based
//! compilation/instantiation over the same context-owned native store.

const std = @import("std");
const value = @import("../value.zig");
const shape = @import("../shape.zig");
const gc = @import("../gc.zig");
const interpreter = @import("../interpreter.zig");
const context = @import("../context.zig");
const promise = @import("../promise.zig");
const stack_scan = @import("../stack_scan.zig");
const types = @import("types.zig");
const decode = @import("decode.zig");
const validate_mod = @import("validate.zig");
const exec = @import("exec.zig");

const Value = value.Value;
const Object = value.Object;
const Interpreter = interpreter.Interpreter;
const Environment = interpreter.Environment;
const Shape = shape.Shape;

/// The active JavaScript interpreter is invocation-local, not Context-global:
/// shared-realm Threads may enter the same Wasm store concurrently. Keeping
/// this pointer in TLS also preserves the existing reentrant call stack by
/// saving/restoring the prior value around every boundary.
threadlocal var active_wasm_interp: ?*anyopaque = null;

fn enterExecutionRoots(raw: *anyopaque, roots: *value.WasmExecutionRoots) error{OutOfMemory}!void {
    _ = raw;
    const machine: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return));
    try machine.pushWasmRoots(roots);
}

fn leaveExecutionRoots(raw: *anyopaque, roots: *value.WasmExecutionRoots) void {
    _ = raw;
    const machine: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return));
    machine.popWasmRoots(roots);
}

fn checkpointExecutionRoots(raw: *anyopaque, _: *value.WasmExecutionRoots) void {
    _ = raw;
    const machine: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return));
    machine.serviceGcSafepoint();
    if (machine.use_thread_gil) if (machine.gil) |g| g.yieldIfContended();
}

fn beginExecutionWait(raw: *anyopaque) void {
    const machine: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return));
    stack_scan.beginPark();
    if (machine.use_thread_gil and machine.gil != null) machine.gil.?.release();
    _ = raw;
}

fn endExecutionWait(raw: *anyopaque) void {
    const machine: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return));
    if (machine.use_thread_gil and machine.gil != null) machine.gil.?.acquire();
    stack_scan.endPark();
    _ = raw;
}

fn executionWaitInterrupted(raw: *anyopaque) bool {
    const store: *context.Context = @ptrCast(@alignCast(raw));
    return store.terminationRequested();
}

fn barrierGlobalReference(raw: *anyopaque, slot: exec.ValueSlot) void {
    const owner: *Object = @ptrCast(@alignCast(raw));
    if (slot == .externref) gc.barrierValueFrom(owner, slot.externref);
}

const ErrorDescriptor = struct { name: []const u8, proto: *Object };
const ModuleDescriptor = struct { proto: *Object, compile_error_proto: *Object };
const MemoryDescriptor = struct { proto: *Object };
const TableDescriptor = struct { proto: *Object };
const GlobalDescriptor = struct { proto: *Object };
const InstanceDescriptor = struct {
    proto: *Object,
    roots: *Object,
    function_proto: *Object,
    memory_proto: *Object,
    table_proto: *Object,
    global_proto: *Object,
    link_error_proto: *Object,
    runtime_error_proto: *Object,
};
const AsyncDescriptor = struct {
    module: *ModuleDescriptor,
    instance: *InstanceDescriptor,
};

const MemoryOwner = struct {
    store: *context.Context,
    mem: *exec.MemoryInst,
    wrapper: *Object,
    owns_native: bool = true,

    fn deinit(self: *MemoryOwner) void {
        if (self.mem.on_grow_ctx == @as(?*anyopaque, @ptrCast(self))) {
            self.mem.on_grow = null;
            self.mem.on_grow_ctx = null;
        }
        if (self.owns_native) exec.destroyMemory(self.store.gpa, self.mem);
        self.store.gpa.destroy(self);
    }
};

const GlobalOwner = struct {
    store: *context.Context,
    glob: *exec.GlobalInst,
    wrapper: *Object,
    owns_native: bool = true,

    fn deinit(self: *GlobalOwner) void {
        if (self.owns_native) exec.destroyGlobal(self.store.gpa, self.glob);
        self.store.gpa.destroy(self);
    }
};

const TableOwner = struct {
    store: *context.Context,
    arena: std.mem.Allocator,
    table: *exec.TableInst,
    wrapper: *Object,
    owns_native: bool = true,
    lock: std.atomic.Mutex = .unlocked,
    refs: []std.atomic.Value(u64),
    retired_refs: std.ArrayListUnmanaged([]std.atomic.Value(u64)) = .empty,

    fn lockOwner(self: *TableOwner) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockOwner(self: *TableOwner) void {
        self.lock.unlock();
    }

    fn deinit(self: *TableOwner) void {
        if (self.table.host) |host| {
            if (host.ctx == @as(*anyopaque, @ptrCast(self))) self.table.host = null;
        }
        for (self.retired_refs.items) |refs| self.store.gpa.free(refs);
        self.retired_refs.deinit(self.store.gpa);
        self.store.gpa.free(self.refs);
        if (self.owns_native) exec.destroyTable(self.store.gpa, self.table);
        self.store.gpa.destroy(self);
    }
};

fn tableHostLock(raw: *anyopaque) void {
    const owner: *TableOwner = @ptrCast(@alignCast(raw));
    owner.lockOwner();
}

fn tableHostUnlock(raw: *anyopaque) void {
    const owner: *TableOwner = @ptrCast(@alignCast(raw));
    owner.unlockOwner();
}

fn tableHostEnsureLen(raw: *anyopaque, new_len: usize) bool {
    const owner: *TableOwner = @ptrCast(@alignCast(raw));
    if (new_len <= owner.refs.len) return true;
    const fresh = allocateTableRefs(owner.store, new_len, Value.nul()) catch return false;
    for (owner.refs, 0..) |*old, i| fresh[i].store(old.load(.acquire), .monotonic);
    owner.retired_refs.ensureUnusedCapacity(owner.store.gpa, 1) catch {
        owner.store.gpa.free(fresh);
        return false;
    };
    owner.wrapper.setWasmTableRefs(owner.arena, fresh) catch {
        owner.store.gpa.free(fresh);
        return false;
    };
    owner.retired_refs.appendAssumeCapacity(owner.refs);
    owner.refs = fresh;
    return true;
}

fn mirroredFunctionMatches(value_: Value, raw_func: *anyopaque) bool {
    if (!value_.isObject()) return false;
    const state = value_.asObj().wasmFunction() orelse return false;
    const owner: *FunctionOwner = @ptrCast(@alignCast(state.func orelse return false));
    return owner.func == @as(*exec.FuncInst, @ptrCast(@alignCast(raw_func)));
}

fn tableHostSync(raw: *anyopaque, table: *exec.TableInst, start: usize, len: usize) void {
    const owner: *TableOwner = @ptrCast(@alignCast(raw));
    const end = @min(start + len, table.elems.len, owner.refs.len);
    for (table.elems[start..end], start..) |slot, index| switch (slot) {
        .externref => |ref| {
            owner.refs[index].store(ref.bits, .release);
            gc.barrierValueFrom(owner.wrapper, ref);
        },
        .funcref => |maybe_func| if (maybe_func) |func| {
            const current: Value = .{ .bits = owner.refs[index].load(.acquire) };
            if (!mirroredFunctionMatches(current, func))
                owner.refs[index].store(Value.nul().bits, .release);
        } else owner.refs[index].store(Value.nul().bits, .release),
        .numeric, .vector => unreachable,
    };
}

fn installTableHost(owner: *TableOwner) void {
    owner.table.host = .{
        .ctx = @ptrCast(owner),
        .lock = tableHostLock,
        .unlock = tableHostUnlock,
        .ensure_len = tableHostEnsureLen,
        .sync = tableHostSync,
    };
}

const FunctionOwner = struct {
    store: *context.Context,
    func: *exec.FuncInst,
    inst: *exec.Instance,
    function_type: types.FuncType,
    runtime_error_proto: *Object,
};

const JsImportBridge = struct {
    store: *context.Context,
    callable: Value,
    function_type: types.FuncType,
    inst: ?*exec.Instance = null,
};

const FunctionHostContext = struct {
    store: *context.Context,
    descriptor: *InstanceDescriptor,
    instance_object: *Object,
    inst: *exec.Instance,
    cache: []Value,
};

const InstanceOwner = struct {
    store: *context.Context,
    inst: *exec.Instance,
    bridges: []JsImportBridge,
    coerced_globals: []?*exec.GlobalInst,

    fn deinit(self: *InstanceOwner) void {
        exec.destroyInstance(self.store.gpa, self.inst);
        for (self.coerced_globals) |maybe_global|
            if (maybe_global) |global| exec.destroyGlobal(self.store.gpa, global);
        self.store.gpa.free(self.coerced_globals);
        self.store.gpa.free(self.bridges);
        self.store.gpa.destroy(self);
    }
};

fn setData(a: std.mem.Allocator, rs: *Shape, obj: *Object, name: []const u8, v: Value, attrs: value.PropAttr) !void {
    try obj.setOwn(a, rs, name, v);
    try obj.setAttr(a, name, attrs);
}

fn installMethod(a: std.mem.Allocator, rs: *Shape, obj: *Object, name: []const u8, arity: usize, native: value.NativeFn) !void {
    const method = try gc.allocObj(a);
    method.* = .{ .native = native };
    try interpreter.installNativeProps(a, rs, method, name, arity);
    try setData(a, rs, obj, name, Value.obj(method), .{ .writable = true, .enumerable = false, .configurable = true });
}

fn installMethodWithData(
    a: std.mem.Allocator,
    rs: *Shape,
    obj: *Object,
    name: []const u8,
    arity: usize,
    native: value.NativeFn,
    private_data: *anyopaque,
) !void {
    const method = try gc.allocObj(a);
    method.* = .{ .native = native, .private_data = private_data };
    try interpreter.installNativeProps(a, rs, method, name, arity);
    try setData(a, rs, obj, name, Value.obj(method), .{ .writable = true, .enumerable = false, .configurable = true });
}

fn installAccessor(a: std.mem.Allocator, rs: *Shape, obj: *Object, name: []const u8, getter: value.NativeFn, setter: ?value.NativeFn) !void {
    const get = try gc.allocObj(a);
    get.* = .{ .native = getter };
    try interpreter.installNativeProps(a, rs, get, try std.fmt.allocPrint(a, "get {s}", .{name}), 0);
    var set_value: ?Value = null;
    if (setter) |native| {
        const set = try gc.allocObj(a);
        set.* = .{ .native = native };
        try interpreter.installNativeProps(a, rs, set, try std.fmt.allocPrint(a, "set {s}", .{name}), 1);
        set_value = Value.obj(set);
    }
    try obj.setAccessor(a, name, Value.obj(get), set_value);
    try obj.setAttr(a, name, .{ .enumerable = false, .configurable = true });
}

fn constructorPair(
    env: *Environment,
    rs: *Shape,
    name: []const u8,
    arity: usize,
    native: value.NativeFn,
    parent_proto: *Object,
    function_proto: *Object,
) !struct { ctor: *Object, proto: *Object } {
    const proto = try gc.allocObj(env.arena);
    proto.* = .{ .proto = parent_proto };
    const ctor = try gc.allocObj(env.arena);
    ctor.* = .{ .native = native, .native_ctor = true, .proto = function_proto };
    try interpreter.installNativeProps(env.arena, rs, ctor, name, arity);
    try setData(env.arena, rs, ctor, "prototype", Value.obj(proto), .{ .writable = false, .enumerable = false, .configurable = false });
    try setData(env.arena, rs, proto, "constructor", Value.obj(ctor), .{ .writable = true, .enumerable = false, .configurable = true });
    return .{ .ctor = ctor, .proto = proto };
}

fn activeInterpreter(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn storeFor(self: *Interpreter) value.HostError!*context.Context {
    const raw = self.wasm_store_ctx orelse return self.throwError("TypeError", "WebAssembly store is unavailable");
    return @ptrCast(@alignCast(raw));
}

fn languageObject(v: Value) ?*Object {
    if (!v.isObject()) return null;
    const object = v.asObj();
    return if (object.is_bigint or object.is_symbol) null else object;
}

fn constructedPrototype(self: *Interpreter, fallback: *Object) value.HostError!*Object {
    const target = languageObject(self.new_target) orelse return fallback;
    return languageObject(try self.getProperty(Value.obj(target), "prototype")) orelse fallback;
}

fn requireDescriptor(self: *Interpreter, args: []const Value, name: []const u8) value.HostError!*Object {
    if (args.len == 0) return self.throwError("TypeError", name);
    return languageObject(args[0]) orelse return self.throwError("TypeError", name);
}

fn toIndexU32(self: *Interpreter, input: Value, maximum: u32, what: []const u8) value.HostError!u32 {
    const number = try self.toNumberV(input);
    const integer = if (std.math.isNan(number) or number == 0) 0 else @trunc(number);
    if (!std.math.isFinite(integer) or integer < 0 or integer > @as(f64, @floatFromInt(maximum)))
        return self.throwError("RangeError", what);
    return @intFromFloat(integer);
}

fn optionalMaximum(self: *Interpreter, descriptor: *Object, initial: u32, maximum: u32, what: []const u8) value.HostError!?u32 {
    const raw = try self.getProperty(Value.obj(descriptor), "maximum");
    if (raw.isUndefined()) return null;
    const result = try toIndexU32(self, raw, maximum, what);
    if (result < initial) return self.throwError("RangeError", what);
    return result;
}

fn errorConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const descriptor: *ErrorDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    const message = if (args.len == 0 or args[0].isUndefined()) "" else try self.toStringV(args[0]);
    return self.makeErrorWithProto(descriptor.name, message, descriptor.proto);
}

fn throwCompileError(self: *Interpreter, proto: *Object, diag: *const types.Diagnostic) value.HostError {
    const message = if (diag.offset == types.Diagnostic.no_offset)
        diag.message()
    else
        std.fmt.allocPrint(self.arena, "WebAssembly.Module(): {s} @+{d}", .{ diag.message(), diag.offset }) catch "WebAssembly.Module(): compilation failed";
    return self.throwErrorWithProto("CompileError", message, proto);
}

const BufferCopy = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    fn deinit(copy: BufferCopy) void {
        copy.allocator.free(copy.bytes);
    }
};

fn copyBufferSource(self: *Interpreter, input: Value) value.HostError!BufferCopy {
    if (!input.isObject()) return self.throwError("TypeError", "WebAssembly BufferSource must be an ArrayBuffer or ArrayBufferView");
    const object = input.asObj();
    var buffer: *value.ArrayBufferData = undefined;
    var offset: usize = 0;
    var len: usize = 0;
    if (object.typedArray()) |view| {
        buffer = view.buffer.arrayBuffer() orelse return self.throwError("TypeError", "invalid WebAssembly BufferSource");
        const current = view.currentLength() orelse return self.throwError("TypeError", "detached or out-of-bounds WebAssembly BufferSource");
        offset = view.byte_offset;
        len = current * view.kind.byteSize();
    } else if (object.dataView()) |view| {
        buffer = view.buffer.arrayBuffer() orelse return self.throwError("TypeError", "invalid WebAssembly BufferSource");
        len = view.currentByteLength() orelse return self.throwError("TypeError", "detached or out-of-bounds WebAssembly BufferSource");
        offset = view.byte_offset;
    } else if (object.arrayBuffer()) |array_buffer| {
        if (array_buffer.is_shared) return self.throwError("TypeError", "WebAssembly BufferSource cannot be a SharedArrayBuffer");
        if (array_buffer.isDetached()) return self.throwError("TypeError", "detached WebAssembly BufferSource");
        buffer = array_buffer;
        len = buffer.bytes().len;
    } else return self.throwError("TypeError", "WebAssembly BufferSource must be an ArrayBuffer or ArrayBufferView");

    const allocator = if (self.wasm_store_ctx) |store_ptr|
        (@as(*context.Context, @ptrCast(@alignCast(store_ptr)))).gpa
    else
        self.arena;
    buffer.lockBuffer();
    defer buffer.unlockBuffer();
    const live = buffer.bytes();
    if (offset > live.len or len > live.len - offset)
        return self.throwError("TypeError", "detached or out-of-bounds WebAssembly BufferSource");
    return .{ .bytes = try allocator.dupe(u8, live[offset .. offset + len]), .allocator = allocator };
}

fn moduleFromValue(self: *Interpreter, input: Value) value.HostError!*types.Module {
    if (!input.isObject()) return self.throwError("TypeError", "WebAssembly.Module method requires a Module");
    const erased = input.asObj().wasmModule() orelse return self.throwError("TypeError", "WebAssembly.Module method requires a Module");
    return @ptrCast(@alignCast(erased));
}

fn compileModuleObject(
    self: *Interpreter,
    input: Value,
    descriptor: *ModuleDescriptor,
    prototype: *Object,
) value.HostError!Value {
    const copy = try copyBufferSource(self, input);
    defer copy.deinit();
    const owner = self.wasm_store_ctx orelse return self.throwError("TypeError", "WebAssembly store is unavailable");
    const store: *context.Context = @ptrCast(@alignCast(owner));
    var diag: types.Diagnostic = .{};
    const module = decode.decodeWithFeatures(store.gpa, copy.bytes, store.wasm_features, &diag) catch |err| switch (err) {
        error.Malformed => return throwCompileError(self, descriptor.compile_error_proto, &diag),
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer decode.destroyModule(store.gpa, module);
    validate_mod.validate(module, &diag) catch
        return throwCompileError(self, descriptor.compile_error_proto, &diag);
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = prototype };
    try object.setWasmModule(self.arena, @ptrCast(module));
    try store.appendWasmOwned(.{ .module = @ptrCast(module) });
    return Value.obj(object);
}

fn moduleConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const descriptor: *ModuleDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "WebAssembly.Module must be called with new");
    if (args.len == 0) return self.throwError("TypeError", "WebAssembly.Module requires a BufferSource");
    return compileModuleObject(self, args[0], descriptor, try constructedPrototype(self, descriptor.proto));
}

fn validate(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    if (args.len == 0) return self.throwError("TypeError", "WebAssembly.validate requires a BufferSource");
    const copy = try copyBufferSource(self, args[0]);
    defer copy.deinit();
    const store = if (self.wasm_store_ctx) |store_ptr| @as(?*context.Context, @ptrCast(@alignCast(store_ptr))) else null;
    const allocator = if (store) |owner| owner.gpa else self.arena;
    var diag: types.Diagnostic = .{};
    const module = decode.decodeWithFeatures(allocator, copy.bytes, if (store) |owner| owner.wasm_features else .{}, &diag) catch |err| return switch (err) {
        error.Malformed => Value.boolVal(false),
        error.OutOfMemory => error.OutOfMemory,
    };
    defer decode.destroyModule(allocator, module);
    validate_mod.validate(module, &diag) catch return Value.boolVal(false);
    return Value.boolVal(true);
}

fn appendDescriptor(self: *Interpreter, array: *Object, fields: []const struct { []const u8, []const u8 }) value.HostError!void {
    const item = (try self.newObject()).asObj();
    for (fields) |field| try self.setProp(item, field[0], try Value.strAlloc(self.arena, field[1]));
    try array.appendElement(self.arena, Value.obj(item));
}

fn moduleImports(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const module = try moduleFromValue(self, if (args.len > 0) args[0] else Value.undef());
    const result = (try self.newArray()).asObj();
    for (module.imports) |entry| try appendDescriptor(self, result, &.{ .{ "module", entry.module }, .{ "name", entry.name }, .{ "kind", entry.desc.kind().name() } });
    return Value.obj(result);
}

fn moduleExports(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const module = try moduleFromValue(self, if (args.len > 0) args[0] else Value.undef());
    const result = (try self.newArray()).asObj();
    for (module.exports) |entry| try appendDescriptor(self, result, &.{ .{ "name", entry.name }, .{ "kind", entry.kind.name() } });
    return Value.obj(result);
}

fn moduleCustomSections(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const module = try moduleFromValue(self, if (args.len > 0) args[0] else Value.undef());
    const requested = try self.toStringV(if (args.len > 1) args[1] else Value.undef());
    const result = (try self.newArray()).asObj();
    for (module.custom_sections) |section| {
        if (!std.mem.eql(u8, section.name, requested)) continue;
        const buffer = try self.makeArrayBuffer(section.bytes.len);
        @memcpy(buffer.arrayBuffer().?.bytes(), section.bytes);
        try result.appendElement(self.arena, Value.obj(buffer));
    }
    return Value.obj(result);
}

fn makeMemoryBuffer(self: *Interpreter, store: *context.Context, mem: *exec.MemoryInst) value.HostError!*Object {
    if (mem.shared_storage) |storage| {
        const buffer = try interpreter.makeSharedArrayBufferWrapper(self, storage.retain());
        const data = buffer.arrayBuffer().?;
        // WebAssembly exposes a fixed-length SAB snapshot. A successful grow
        // installs a fresh wrapper over this same storage; this wrapper keeps
        // its present length forever and is never detached.
        data.shared_fixed_byte_length = mem.bytes().len;
        data.max_byte_length = null;
        data.is_wasm_memory = true;
        buffer.setExtensible(false);
        return buffer;
    }
    const bytes = mem.bytes();
    const owner = try store.createExternalBufferOwner(
        if (bytes.len == 0) null else @ptrCast(bytes.ptr),
        null,
        null,
    );
    const buffer = try self.makeExternalArrayBuffer(bytes, owner);
    buffer.arrayBuffer().?.is_wasm_memory = true;
    return buffer;
}

fn memoryDidGrow(raw: *anyopaque, mem: *exec.MemoryInst) bool {
    const owner: *MemoryOwner = @ptrCast(@alignCast(raw));
    if (owner.mem != mem) return false;
    const self: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return false));
    const fresh = makeMemoryBuffer(self, owner.store, mem) catch return false;
    const state = owner.wrapper.wasmMemory() orelse return false;
    const old_object = state.buffer_obj orelse return false;
    const old = old_object.arrayBuffer() orelse return false;
    if (mem.isShared()) {
        // Shared memory growth never detaches the historical buffer. The new
        // fixed-length wrapper aliases the same Shared Data Block at the new
        // length, exactly as the Threads JS API requires.
        state.buffer_obj = fresh;
        gc.barrierCellFrom(owner.wrapper, fresh);
        return true;
    }
    // Generated native handles promise stable backing ownership. The private
    // conversion rejects Memory buffers, but keep this defensive boundary so a
    // future caller cannot retire bytes underneath an already-issued handle.
    if (old.native_handle.load(.acquire) != null) return false;

    // The replacement is fully allocated before the old view changes, so an
    // OOM leaves the memory and its buffer identity untouched.
    old.lockBuffer();
    old.swapLocalData(&.{});
    old.setDetached(true);
    old.unlockBuffer();
    state.buffer_obj = fresh;
    gc.barrierCellFrom(owner.wrapper, fresh);
    return true;
}

fn memoryFromThis(self: *Interpreter, this: Value, operation: []const u8) value.HostError!*MemoryOwner {
    const object = languageObject(this) orelse return self.throwError("TypeError", operation);
    const state = object.wasmMemory() orelse return self.throwError("TypeError", operation);
    return @ptrCast(@alignCast(state.mem orelse return self.throwError("TypeError", operation)));
}

fn memoryConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const native: *MemoryDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "WebAssembly.Memory must be called with new");
    const descriptor = try requireDescriptor(self, args, "WebAssembly.Memory requires a descriptor object");
    const raw_initial = try self.getProperty(Value.obj(descriptor), "initial");
    if (raw_initial.isUndefined()) return self.throwError("TypeError", "WebAssembly.Memory descriptor requires initial");
    const initial = try toIndexU32(self, raw_initial, types.MAX_PAGES, "WebAssembly.Memory initial is out of range");
    const maximum = try optionalMaximum(self, descriptor, initial, types.MAX_PAGES, "WebAssembly.Memory maximum is out of range");
    const shared = (try self.getProperty(Value.obj(descriptor), "shared")).toBoolean();
    if (shared and maximum == null)
        return self.throwError("TypeError", "shared WebAssembly.Memory requires a maximum");
    const proto = try constructedPrototype(self, native.proto);
    const store = try storeFor(self);

    const mem = try exec.createMemoryTyped(store.gpa, initial, maximum, shared);
    errdefer exec.destroyMemory(store.gpa, mem);
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = proto };
    const owner = try store.gpa.create(MemoryOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .mem = mem, .wrapper = object };
    const buffer = try makeMemoryBuffer(self, store, mem);
    const state = try object.wasmMemoryState(self.arena);
    state.mem = @ptrCast(owner);
    state.buffer_obj = buffer;
    mem.on_grow = memoryDidGrow;
    mem.on_grow_ctx = @ptrCast(owner);
    try store.appendWasmOwned(.{ .memory = @ptrCast(owner) });
    return Value.obj(object);
}

fn memoryBufferGetter(ctx: *anyopaque, this: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const object = languageObject(this) orelse return self.throwError("TypeError", "WebAssembly.Memory.prototype.buffer getter requires a Memory");
    const state = object.wasmMemory() orelse return self.throwError("TypeError", "WebAssembly.Memory.prototype.buffer getter requires a Memory");
    _ = state.mem orelse return self.throwError("TypeError", "WebAssembly.Memory.prototype.buffer getter requires a Memory");
    return Value.obj(state.buffer_obj orelse return self.throwError("TypeError", "WebAssembly.Memory buffer is unavailable"));
}

fn memoryGrow(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const owner = try memoryFromThis(self, this, "WebAssembly.Memory.prototype.grow requires a Memory");
    const delta = try toIndexU32(self, if (args.len > 0) args[0] else Value.undef(), std.math.maxInt(u32), "WebAssembly.Memory grow delta is out of range");
    const previous = active_wasm_interp;
    active_wasm_interp = @ptrCast(self);
    defer active_wasm_interp = previous;
    const result = exec.memoryGrow(owner.mem, delta);
    if (result < 0) return self.throwError("RangeError", "WebAssembly.Memory could not grow");
    return Value.num(@floatFromInt(result));
}

const TableRef = struct {
    value: Value,
    slot: exec.ValueSlot,
};

fn tableRefFromValue(self: *Interpreter, store: *context.Context, elem_type: types.ValType, input: Value) value.HostError!TableRef {
    if (elem_type == .externref) return .{ .value = input, .slot = .{ .externref = input } };
    if (input.isNull()) return .{ .value = Value.nul(), .slot = .{ .funcref = null } };
    const object = languageObject(input) orelse return self.throwError("TypeError", "WebAssembly.Table value must be null or a WebAssembly function");
    const state = object.wasmFunction() orelse return self.throwError("TypeError", "WebAssembly.Table value must be null or a WebAssembly function");
    const owner: *FunctionOwner = @ptrCast(@alignCast(state.func orelse return self.throwError("TypeError", "WebAssembly function is unavailable")));
    if (owner.store != store) return self.throwError("TypeError", "WebAssembly function belongs to a different store");
    return .{ .value = input, .slot = .{ .funcref = @ptrCast(owner.func) } };
}

fn tableFromThis(self: *Interpreter, this: Value, operation: []const u8) value.HostError!*TableOwner {
    const object = languageObject(this) orelse return self.throwError("TypeError", operation);
    const state = object.wasmTable() orelse return self.throwError("TypeError", operation);
    return @ptrCast(@alignCast(state.table orelse return self.throwError("TypeError", operation)));
}

fn allocateTableRefs(store: *context.Context, len: usize, fill: Value) value.HostError![]std.atomic.Value(u64) {
    const refs = try store.gpa.alloc(std.atomic.Value(u64), len);
    for (refs) |*ref| ref.* = .init(fill.bits);
    return refs;
}

fn tableConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const native: *TableDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "WebAssembly.Table must be called with new");
    const descriptor = try requireDescriptor(self, args, "WebAssembly.Table requires a descriptor object");
    const element = try self.toStringV(try self.getProperty(Value.obj(descriptor), "element"));
    const store = try storeFor(self);
    const elem_type: types.ValType = if (std.mem.eql(u8, element, "anyfunc") or std.mem.eql(u8, element, "funcref"))
        .funcref
    else if (std.mem.eql(u8, element, "externref") and store.wasm_features.reference_types)
        .externref
    else
        return self.throwError("TypeError", "WebAssembly.Table descriptor has an unsupported element type");
    const raw_initial = try self.getProperty(Value.obj(descriptor), "initial");
    if (raw_initial.isUndefined()) return self.throwError("TypeError", "WebAssembly.Table descriptor requires initial");
    const initial = try toIndexU32(self, raw_initial, std.math.maxInt(u32), "WebAssembly.Table initial is out of range");
    const maximum = try optionalMaximum(self, descriptor, initial, std.math.maxInt(u32), "WebAssembly.Table maximum is out of range");
    const proto = try constructedPrototype(self, native.proto);
    const fill = try tableRefFromValue(self, store, elem_type, if (args.len > 1) args[1] else Value.nul());

    const table = try exec.createTableTyped(store.gpa, elem_type, initial, maximum);
    errdefer exec.destroyTable(store.gpa, table);
    @memset(table.elems, fill.slot);
    const refs = try allocateTableRefs(store, initial, fill.value);
    errdefer store.gpa.free(refs);
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = proto };
    const owner = try store.gpa.create(TableOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .arena = self.arena, .table = table, .wrapper = object, .refs = refs };
    installTableHost(owner);
    const state = try object.wasmTableState(self.arena);
    state.table = @ptrCast(owner);
    state.refs = refs;
    try store.appendWasmOwned(.{ .table = @ptrCast(owner) });
    if (fill.value.isObject()) gc.barrierValueFrom(object, fill.value);
    return Value.obj(object);
}

fn tableLengthGetter(ctx: *anyopaque, this: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const owner = try tableFromThis(self, this, "WebAssembly.Table.prototype.length getter requires a Table");
    owner.lockOwner();
    defer owner.unlockOwner();
    return Value.num(@floatFromInt(owner.refs.len));
}

fn tableGet(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const owner = try tableFromThis(self, this, "WebAssembly.Table.prototype.get requires a Table");
    const index = try toIndexU32(self, if (args.len > 0) args[0] else Value.undef(), std.math.maxInt(u32), "WebAssembly.Table index is out of range");
    while (true) {
        owner.lockOwner();
        owner.table.lockTable();
        if (index >= owner.table.elems.len) {
            owner.table.unlockTable();
            owner.unlockOwner();
            return self.throwError("RangeError", "WebAssembly.Table index is out of bounds");
        }
        const slot = owner.table.elems[index];
        const mirrored: Value = .{ .bits = owner.refs[index].load(.acquire) };
        owner.table.unlockTable();
        owner.unlockOwner();
        switch (slot) {
            .externref => return slot.externref,
            .funcref => |maybe_func| {
                const func = maybe_func orelse return Value.nul();
                if (mirroredFunctionMatches(mirrored, func)) return mirrored;
                const previous = active_wasm_interp;
                active_wasm_interp = @ptrCast(self);
                const resolved = wasmSlotToJs(self, .funcref, slot, null) catch |err| {
                    active_wasm_interp = previous;
                    return err;
                };
                active_wasm_interp = previous;
                owner.lockOwner();
                owner.table.lockTable();
                const unchanged = index < owner.table.elems.len and
                    owner.table.elems[index] == .funcref and
                    owner.table.elems[index].funcref == func;
                if (unchanged) owner.refs[index].store(resolved.bits, .release);
                owner.table.unlockTable();
                owner.unlockOwner();
                if (unchanged) {
                    gc.barrierValueFrom(owner.wrapper, resolved);
                    return resolved;
                }
            },
            .numeric, .vector => unreachable,
        }
    }
}

fn tableSet(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const owner = try tableFromThis(self, this, "WebAssembly.Table.prototype.set requires a Table");
    const index = try toIndexU32(self, if (args.len > 0) args[0] else Value.undef(), std.math.maxInt(u32), "WebAssembly.Table index is out of range");
    owner.lockOwner();
    const in_bounds = index < owner.refs.len;
    owner.unlockOwner();
    if (!in_bounds) return self.throwError("RangeError", "WebAssembly.Table index is out of bounds");
    const replacement = try tableRefFromValue(self, owner.store, owner.table.type, if (args.len > 1) args[1] else Value.nul());
    owner.lockOwner();
    defer owner.unlockOwner();
    owner.table.lockTable();
    owner.table.elems[index] = replacement.slot;
    owner.table.unlockTable();
    owner.refs[index].store(replacement.value.bits, .release);
    gc.barrierValueFrom(owner.wrapper, replacement.value);
    return Value.undef();
}

fn tableGrow(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const owner = try tableFromThis(self, this, "WebAssembly.Table.prototype.grow requires a Table");
    const delta = try toIndexU32(self, if (args.len > 0) args[0] else Value.undef(), std.math.maxInt(u32), "WebAssembly.Table grow delta is out of range");
    const fill = try tableRefFromValue(self, owner.store, owner.table.type, if (args.len > 1) args[1] else Value.nul());
    owner.lockOwner();
    defer owner.unlockOwner();
    const old_len: u32 = @intCast(owner.refs.len);
    const limit = owner.table.limits.max orelse std.math.maxInt(u32);
    if (delta > limit - old_len)
        return self.throwError("RangeError", "WebAssembly.Table could not grow");
    if (delta == 0) return Value.num(@floatFromInt(old_len));

    const fresh = try allocateTableRefs(owner.store, @as(usize, old_len) + delta, fill.value);
    errdefer owner.store.gpa.free(fresh);
    for (owner.refs, 0..) |*old, i| fresh[i].store(old.load(.acquire), .monotonic);
    try owner.retired_refs.ensureUnusedCapacity(owner.store.gpa, 1);
    if (exec.tableGrowWith(owner.table, delta, fill.slot) < 0)
        return self.throwError("RangeError", "WebAssembly.Table could not grow");
    owner.retired_refs.appendAssumeCapacity(owner.refs);
    owner.refs = fresh;
    owner.wrapper.setWasmTableRefs(self.arena, fresh) catch unreachable;
    gc.barrierValueFrom(owner.wrapper, fill.value);
    return Value.num(@floatFromInt(old_len));
}

fn globalTypeFromDescriptor(self: *Interpreter, descriptor: *Object) value.HostError!types.ValType {
    const raw = try self.getProperty(Value.obj(descriptor), "value");
    const name = try self.toStringV(raw);
    inline for ([_]types.ValType{ .i32, .i64, .f32, .f64 }) |kind| {
        if (std.mem.eql(u8, name, kind.name())) return kind;
    }
    if (std.mem.eql(u8, name, "externref") and (try storeFor(self)).wasm_features.reference_types)
        return .externref;
    return self.throwError("TypeError", "WebAssembly.Global descriptor has an unsupported value type");
}

fn coerceGlobalSlot(self: *Interpreter, kind: types.ValType, input: Value) value.HostError!exec.ValueSlot {
    return switch (kind) {
        .externref => .{ .externref = input },
        .funcref => unreachable,
        .v128 => self.throwError("TypeError", "v128 value cannot cross the JavaScript Global boundary"),
        .i32, .i64, .f32, .f64 => .{ .numeric = try coerceGlobalBits(self, kind, input) },
    };
}

fn coerceGlobalBits(self: *Interpreter, kind: types.ValType, input: Value) value.HostError!u64 {
    return switch (kind) {
        .i32 => @as(u64, @as(u32, @bitCast(Value.num(try self.toNumberV(input)).toInt32()))),
        .i64 => blk: {
            const bigint = try self.toBigIntValue(input);
            const ctor = self.env.get("BigInt") orelse return self.throwError("TypeError", "BigInt is unavailable");
            const as_int_n = try self.getProperty(ctor, "asIntN");
            const narrowed = try self.callValue(as_int_n, &.{ Value.num(64), bigint });
            const signed: i64 = @intCast(narrowed.asObj().bigIntValue());
            break :blk @bitCast(signed);
        },
        .f32 => @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(try self.toNumberV(input)))))),
        .f64 => @bitCast(try self.toNumberV(input)),
        .funcref, .externref, .v128 => unreachable,
    };
}

fn wasmBitsToJs(self: *Interpreter, kind: types.ValType, bits: u64) value.HostError!Value {
    return switch (kind) {
        .i32 => Value.num(@floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(bits)))))),
        .i64 => try self.makeBigInt(@as(i64, @bitCast(bits))),
        .f32 => Value.num(@as(f32, @bitCast(@as(u32, @truncate(bits))))),
        .f64 => Value.num(@bitCast(bits)),
        .funcref, .externref, .v128 => self.throwError("TypeError", "value type cannot cross this numeric function boundary"),
    };
}

fn functionInstance(func: *exec.FuncInst, fallback: ?*exec.Instance) ?*exec.Instance {
    return switch (func.*) {
        .defined => |defined| defined.inst,
        .imported => |imported| imported.owner_instance orelse fallback,
    };
}

fn wasmSlotToJs(self: *Interpreter, kind: types.ValType, slot: exec.ValueSlot, fallback: ?*exec.Instance) value.HostError!Value {
    return switch (kind) {
        .i32, .i64, .f32, .f64 => wasmBitsToJs(self, kind, slot.numericBits()),
        .v128 => self.throwError("TypeError", "v128 value cannot cross the JavaScript function boundary"),
        .externref => slot.externref,
        .funcref => if (slot.funcref) |raw| blk: {
            const func: *exec.FuncInst = @ptrCast(@alignCast(raw));
            const inst = functionInstance(func, fallback) orelse
                return self.throwError("TypeError", "WebAssembly function reference has no owning instance");
            const host = inst.function_host orelse
                return self.throwError("TypeError", "WebAssembly function reference is unavailable");
            break :blk try host.resolve(host.ctx, func);
        } else Value.nul(),
    };
}

fn jsToWasmSlot(self: *Interpreter, store: *context.Context, kind: types.ValType, input: Value) value.HostError!exec.ValueSlot {
    return switch (kind) {
        .i32, .i64, .f32, .f64 => .{ .numeric = try coerceGlobalBits(self, kind, input) },
        .v128 => return self.throwError("TypeError", "v128 value cannot cross the JavaScript function boundary"),
        .externref => .{ .externref = input },
        .funcref => (try tableRefFromValue(self, store, .funcref, input)).slot,
    };
}

fn resolveFunctionReference(raw: *anyopaque, func: *exec.FuncInst) value.HostError!Value {
    const host: *FunctionHostContext = @ptrCast(@alignCast(raw));
    const self: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return error.OutOfMemory));
    for (host.inst.funcs, 0..) |candidate, index| {
        if (candidate != func) continue;
        return functionValueFor(
            self,
            host.descriptor,
            host.store,
            host.instance_object,
            host.inst,
            host.cache,
            @intCast(index),
            "wasm-function",
        );
    }
    return self.throwError("TypeError", "WebAssembly function reference is unavailable");
}

fn jsImportCall(raw: *anyopaque, args: []const u64, results: []u64, _: *types.Diagnostic) error{ Trap, Host }!void {
    const bridge: *JsImportBridge = @ptrCast(@alignCast(raw));
    const self: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return error.Host));
    const js_args = bridge.store.gpa.alloc(Value, args.len) catch return error.Host;
    defer bridge.store.gpa.free(js_args);
    for (args, bridge.function_type.params, 0..) |bits, kind, i|
        js_args[i] = wasmBitsToJs(self, kind, bits) catch return error.Host;
    const result = self.callValueWithThis(bridge.callable, js_args, Value.undef()) catch return error.Host;
    if (bridge.function_type.results.len == 1) {
        results[0] = coerceGlobalBits(self, bridge.function_type.results[0], result) catch return error.Host;
    } else if (bridge.function_type.results.len > 1) {
        var values: std.ArrayListUnmanaged(Value) = .empty;
        self.spreadInto(&values, result) catch return error.Host;
        if (values.items.len != bridge.function_type.results.len) {
            _ = self.throwError("TypeError", "WebAssembly multi-value import returned the wrong number of values") catch {};
            return error.Host;
        }
        for (bridge.function_type.results, values.items, 0..) |kind, item, i|
            results[i] = coerceGlobalBits(self, kind, item) catch return error.Host;
    }
}

fn jsImportCallSlots(raw: *anyopaque, args: []const exec.ValueSlot, results: []exec.ValueSlot, _: *types.Diagnostic) error{ Trap, Host }!void {
    const bridge: *JsImportBridge = @ptrCast(@alignCast(raw));
    const self: *Interpreter = @ptrCast(@alignCast(active_wasm_interp orelse return error.Host));
    const js_args = bridge.store.gpa.alloc(Value, args.len) catch return error.Host;
    defer bridge.store.gpa.free(js_args);
    for (args, bridge.function_type.params, 0..) |slot, kind, i|
        js_args[i] = wasmSlotToJs(self, kind, slot, bridge.inst) catch return error.Host;

    const result = self.callValueWithThis(bridge.callable, js_args, Value.undef()) catch return error.Host;
    if (bridge.function_type.results.len == 0) return;
    if (bridge.function_type.results.len == 1) {
        results[0] = jsToWasmSlot(self, bridge.store, bridge.function_type.results[0], result) catch return error.Host;
        return;
    }

    var values: std.ArrayListUnmanaged(Value) = .empty;
    self.spreadInto(&values, result) catch return error.Host;
    if (values.items.len != bridge.function_type.results.len) {
        _ = self.throwError("TypeError", "WebAssembly multi-value import returned the wrong number of values") catch {};
        return error.Host;
    }
    for (bridge.function_type.results, values.items, 0..) |kind, item, i|
        results[i] = jsToWasmSlot(self, bridge.store, kind, item) catch return error.Host;
}

fn wasmExportCall(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const function_state = self.active_native.?.wasmFunction() orelse return self.throwError("TypeError", "WebAssembly function is unavailable");
    const owner: *FunctionOwner = @ptrCast(@alignCast(function_state.func orelse return self.throwError("TypeError", "WebAssembly function is unavailable")));
    const slot_args = try owner.store.gpa.alloc(exec.ValueSlot, owner.function_type.params.len);
    defer owner.store.gpa.free(slot_args);
    const slot_results = try owner.store.gpa.alloc(exec.ValueSlot, owner.function_type.results.len);
    defer owner.store.gpa.free(slot_results);
    for (owner.function_type.params, 0..) |kind, i|
        slot_args[i] = try jsToWasmSlot(self, owner.store, kind, if (i < args.len) args[i] else Value.undef());

    var diag: types.Diagnostic = .{};
    const previous = active_wasm_interp;
    active_wasm_interp = @ptrCast(self);
    defer active_wasm_interp = previous;
    exec.callFuncInstSlots(owner.func, slot_args, slot_results, &diag) catch |err| switch (err) {
        error.Trap => return self.throwErrorWithProto("RuntimeError", diag.message(), owner.runtime_error_proto),
        error.Host => return if (!self.exception.isUndefined()) error.Throw else error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (slot_results.len == 0) return Value.undef();
    if (slot_results.len == 1)
        return wasmSlotToJs(self, owner.function_type.results[0], slot_results[0], owner.inst);
    const result = (try self.newArray()).asObj();
    for (owner.function_type.results, slot_results) |kind, slot|
        try result.appendElement(self.arena, try wasmSlotToJs(self, kind, slot, owner.inst));
    return Value.obj(result);
}

fn rawSlotString(self: *Interpreter, kind: types.ValType, slot: exec.ValueSlot) value.HostError!Value {
    const normalized: u128 = switch (kind) {
        .i32, .f32 => @as(u32, @truncate(slot.numericBits())),
        .i64, .f64 => slot.numericBits(),
        .v128 => slot.vectorBits(),
        .funcref, .externref => return self.throwError("TypeError", "reference value has no raw bit encoding"),
    };
    return Value.strOwned(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{normalized}));
}

fn rawSlotFromString(self: *Interpreter, kind: types.ValType, text: []const u8) value.HostError!exec.ValueSlot {
    return switch (kind) {
        .i32, .i64, .f32, .f64 => .{ .numeric = std.fmt.parseInt(u64, text, 10) catch
            return self.throwError("TypeError", "raw WebAssembly arguments must be unsigned decimal bits") },
        .v128 => .{ .vector = std.fmt.parseInt(u128, text, 10) catch
            return self.throwError("TypeError", "raw WebAssembly arguments must be unsigned decimal bits") },
        .funcref, .externref => self.throwError("TypeError", "reference value has no raw bit encoding"),
    };
}

/// Test/conformance-only escape hatch installed by `Context.TestingOptions`.
/// The first argument is a WebAssembly exported function or Global; remaining
/// function arguments are unsigned decimal strings containing raw value
/// bits. Returning a decimal string avoids every JS floating-point conversion.
fn wasmSpecInvokeBits(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    if (args.len == 0) return self.throwError("TypeError", "raw WebAssembly target is required");
    const target = languageObject(args[0]) orelse return self.throwError("TypeError", "raw WebAssembly target is invalid");

    if (target.wasmFunction()) |function_state| {
        const owner: *FunctionOwner = @ptrCast(@alignCast(function_state.func orelse return self.throwError("TypeError", "WebAssembly function is unavailable")));
        if (args.len - 1 != owner.function_type.params.len)
            return self.throwError("TypeError", "raw WebAssembly argument count mismatch");
        const raw_args = try owner.store.gpa.alloc(exec.ValueSlot, owner.function_type.params.len);
        defer owner.store.gpa.free(raw_args);
        const raw_results = try owner.store.gpa.alloc(exec.ValueSlot, owner.function_type.results.len);
        defer owner.store.gpa.free(raw_results);
        for (args[1..], 0..) |argument, i| {
            const text = try self.toStringV(argument);
            raw_args[i] = try rawSlotFromString(self, owner.function_type.params[i], text);
        }

        var diag: types.Diagnostic = .{};
        const previous = active_wasm_interp;
        active_wasm_interp = @ptrCast(self);
        defer active_wasm_interp = previous;
        exec.callFuncInstSlots(owner.func, raw_args, raw_results, &diag) catch |err| switch (err) {
            error.Trap => return self.throwErrorWithProto("RuntimeError", diag.message(), owner.runtime_error_proto),
            error.Host => return if (!self.exception.isUndefined()) error.Throw else error.OutOfMemory,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (raw_results.len == 0) return Value.undef();
        if (raw_results.len == 1)
            return rawSlotString(self, owner.function_type.results[0], raw_results[0]);
        const result = (try self.newArray()).asObj();
        for (owner.function_type.results, raw_results) |kind, slot|
            try result.appendElement(self.arena, try rawSlotString(self, kind, slot));
        return Value.obj(result);
    }

    if (target.wasmGlobal()) |global_state| {
        if (args.len != 1) return self.throwError("TypeError", "raw WebAssembly Global takes no arguments");
        const owner: *GlobalOwner = @ptrCast(@alignCast(global_state.glob orelse return self.throwError("TypeError", "WebAssembly global is unavailable")));
        return rawSlotString(self, owner.glob.type.val, owner.glob.value);
    }
    return self.throwError("TypeError", "raw WebAssembly target must be an exported function or Global");
}

fn globalValue(self: *Interpreter, glob: *exec.GlobalInst) value.HostError!Value {
    return switch (glob.type.val) {
        .i32 => Value.num(@floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(glob.value.numericBits())))))),
        .i64 => try self.makeBigInt(@as(i64, @bitCast(glob.value.numericBits()))),
        .f32 => Value.num(@as(f32, @bitCast(@as(u32, @truncate(glob.value.numericBits()))))),
        .f64 => Value.num(@bitCast(glob.value.numericBits())),
        .externref => glob.value.externref,
        .funcref => unreachable,
        .v128 => self.throwError("TypeError", "v128 value cannot cross the JavaScript Global boundary"),
    };
}

fn globalFromThis(self: *Interpreter, this: Value, operation: []const u8) value.HostError!*GlobalOwner {
    const object = languageObject(this) orelse return self.throwError("TypeError", operation);
    const state = object.wasmGlobal() orelse return self.throwError("TypeError", operation);
    return @ptrCast(@alignCast(state.glob orelse return self.throwError("TypeError", operation)));
}

fn globalConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const native: *GlobalDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "WebAssembly.Global must be called with new");
    const descriptor = try requireDescriptor(self, args, "WebAssembly.Global requires a descriptor object");
    const kind = try globalTypeFromDescriptor(self, descriptor);
    const mutable = (try self.getProperty(Value.obj(descriptor), "mutable")).toBoolean();
    const initial = if (args.len > 1) args[1] else switch (kind) {
        .i64 => try self.makeBigInt(0),
        .externref => Value.nul(),
        else => Value.num(0),
    };
    const slot = try coerceGlobalSlot(self, kind, initial);
    const proto = try constructedPrototype(self, native.proto);
    const store = try storeFor(self);
    const glob = try exec.createGlobalSlot(store.gpa, .{ .val = kind, .mutable = mutable }, slot);
    errdefer exec.destroyGlobal(store.gpa, glob);
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = proto };
    const owner = try store.gpa.create(GlobalOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .glob = glob, .wrapper = object };
    const state = try object.wasmGlobalState(self.arena);
    state.glob = @ptrCast(owner);
    state.ref = &glob.ref_root;
    glob.barrier_ctx = @ptrCast(object);
    glob.barrier = barrierGlobalReference;
    try store.appendWasmOwned(.{ .global = @ptrCast(owner) });
    return Value.obj(object);
}

fn globalValueGetter(ctx: *anyopaque, this: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    return globalValue(self, (try globalFromThis(self, this, "WebAssembly.Global.prototype.value getter requires a Global")).glob);
}

fn globalValueSetter(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const owner = try globalFromThis(self, this, "WebAssembly.Global.prototype.value setter requires a Global");
    if (!owner.glob.type.mutable) return self.throwError("TypeError", "WebAssembly.Global is immutable");
    exec.setGlobalValue(owner.glob, try coerceGlobalSlot(self, owner.glob.type.val, if (args.len > 0) args[0] else Value.undef()));
    return Value.undef();
}

fn globalValueOf(ctx: *anyopaque, this: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    return globalValue(self, (try globalFromThis(self, this, "WebAssembly.Global.prototype.valueOf requires a Global")).glob);
}

const ResolvedImports = struct {
    store: *context.Context,
    funcs: []exec.ImportFunc,
    tables: []*exec.TableInst,
    mems: []*exec.MemoryInst,
    globals: []*exec.GlobalInst,
    bridges: []JsImportBridge,
    coerced_globals: []?*exec.GlobalInst,
    values: []Value,
    table_values: []Value,
    mem_values: []Value,
    global_values: []Value,

    fn deinitTemps(self: *ResolvedImports) void {
        self.store.gpa.free(self.funcs);
        self.store.gpa.free(self.tables);
        self.store.gpa.free(self.mems);
        self.store.gpa.free(self.globals);
    }
};

fn throwWasmWithProto(self: *Interpreter, name: []const u8, message: []const u8, proto: *Object) value.HostError {
    return self.throwErrorWithProto(name, message, proto);
}

fn resolveImports(self: *Interpreter, store: *context.Context, module: *types.Module, import_object: Value, link_proto: *Object) value.HostError!ResolvedImports {
    if (!import_object.isUndefined() and languageObject(import_object) == null)
        return self.throwError("TypeError", "WebAssembly imports must be an object");
    if (module.imports.len > 0 and import_object.isUndefined())
        return self.throwError("TypeError", "WebAssembly.Instance requires an imports object");
    const funcs = try store.gpa.alloc(exec.ImportFunc, module.imported_funcs);
    errdefer store.gpa.free(funcs);
    const tables = try store.gpa.alloc(*exec.TableInst, module.imported_tables);
    errdefer store.gpa.free(tables);
    const mems = try store.gpa.alloc(*exec.MemoryInst, module.imported_mems);
    errdefer store.gpa.free(mems);
    const globals = try store.gpa.alloc(*exec.GlobalInst, module.imported_globals);
    errdefer store.gpa.free(globals);
    const bridges = try store.gpa.alloc(JsImportBridge, module.imported_funcs);
    errdefer store.gpa.free(bridges);
    const coerced_globals = try store.gpa.alloc(?*exec.GlobalInst, module.imported_globals);
    @memset(coerced_globals, null);
    errdefer {
        for (coerced_globals) |maybe_global|
            if (maybe_global) |global| exec.destroyGlobal(store.gpa, global);
        store.gpa.free(coerced_globals);
    }
    const values = try self.arena.alloc(Value, module.imports.len);
    const table_values = try self.arena.alloc(Value, module.imported_tables);
    const mem_values = try self.arena.alloc(Value, module.imported_mems);
    const global_values = try self.arena.alloc(Value, module.imported_globals);

    var fi: usize = 0;
    var ti: usize = 0;
    var mi: usize = 0;
    var gi: usize = 0;
    for (module.imports, 0..) |entry, import_index| {
        const namespace_value = try self.getProperty(import_object, entry.module);
        const namespace = languageObject(namespace_value) orelse
            return throwWasmWithProto(self, "LinkError", "WebAssembly import module is not an object", link_proto);
        const imported = try self.getProperty(Value.obj(namespace), entry.name);
        values[import_index] = imported;
        switch (entry.desc) {
            .func => |type_index| {
                if (!imported.isCallable()) return throwWasmWithProto(self, "LinkError", "WebAssembly function import is not callable", link_proto);
                if (imported.isObject()) if (imported.asObj().wasmFunction()) |state| {
                    const owner: *FunctionOwner = @ptrCast(@alignCast(state.func orelse return throwWasmWithProto(self, "LinkError", "WebAssembly function import is unavailable", link_proto)));
                    if (owner.store != store or !types.funcTypeEql(owner.function_type, module.types[type_index]))
                        return throwWasmWithProto(self, "LinkError", "incompatible WebAssembly function import type", link_proto);
                };
                bridges[fi] = .{ .store = store, .callable = imported, .function_type = module.types[type_index] };
                funcs[fi] = .{
                    .ctx = @ptrCast(&bridges[fi]),
                    .type = module.types[type_index],
                    .call = jsImportCall,
                    .call_slots = jsImportCallSlots,
                };
                fi += 1;
            },
            .table => {
                const object = languageObject(imported) orelse return throwWasmWithProto(self, "LinkError", "WebAssembly table import is not a Table", link_proto);
                const state = object.wasmTable() orelse return throwWasmWithProto(self, "LinkError", "WebAssembly table import is not a Table", link_proto);
                const owner: *TableOwner = @ptrCast(@alignCast(state.table orelse return throwWasmWithProto(self, "LinkError", "WebAssembly table import is unavailable", link_proto)));
                if (owner.store != store) return throwWasmWithProto(self, "LinkError", "WebAssembly table import belongs to another store", link_proto);
                tables[ti] = owner.table;
                table_values[ti] = imported;
                ti += 1;
            },
            .mem => {
                const object = languageObject(imported) orelse return throwWasmWithProto(self, "LinkError", "WebAssembly memory import is not a Memory", link_proto);
                const state = object.wasmMemory() orelse return throwWasmWithProto(self, "LinkError", "WebAssembly memory import is not a Memory", link_proto);
                const owner: *MemoryOwner = @ptrCast(@alignCast(state.mem orelse return throwWasmWithProto(self, "LinkError", "WebAssembly memory import is unavailable", link_proto)));
                if (owner.store != store) return throwWasmWithProto(self, "LinkError", "WebAssembly memory import belongs to another store", link_proto);
                mems[mi] = owner.mem;
                mem_values[mi] = imported;
                mi += 1;
            },
            .global => |global_type| {
                if (languageObject(imported)) |object| {
                    if (object.wasmGlobal()) |state| {
                        const owner: *GlobalOwner = @ptrCast(@alignCast(state.glob orelse return throwWasmWithProto(self, "LinkError", "WebAssembly global import is unavailable", link_proto)));
                        if (owner.store != store) return throwWasmWithProto(self, "LinkError", "WebAssembly global import belongs to another store", link_proto);
                        globals[gi] = owner.glob;
                        global_values[gi] = imported;
                        gi += 1;
                        continue;
                    }
                }
                if (global_type.mutable)
                    return throwWasmWithProto(self, "LinkError", "mutable WebAssembly global import requires a Global", link_proto);
                const primitive_matches = switch (global_type.val) {
                    .i32, .f32, .f64 => imported.isNumber(),
                    .i64 => imported.isObject() and imported.asObj().is_bigint,
                    .externref => true,
                    .funcref, .v128 => false,
                };
                if (!primitive_matches)
                    return throwWasmWithProto(self, "LinkError", "incompatible WebAssembly global import type", link_proto);
                const global = try exec.createGlobalSlot(
                    store.gpa,
                    global_type,
                    try coerceGlobalSlot(self, global_type.val, imported),
                );
                coerced_globals[gi] = global;
                globals[gi] = global;
                global_values[gi] = Value.undef();
                gi += 1;
            },
        }
    }
    return .{
        .store = store,
        .funcs = funcs,
        .tables = tables,
        .mems = mems,
        .globals = globals,
        .bridges = bridges,
        .coerced_globals = coerced_globals,
        .values = values,
        .table_values = table_values,
        .mem_values = mem_values,
        .global_values = global_values,
    };
}

fn functionValueFor(
    self: *Interpreter,
    descriptor: *InstanceDescriptor,
    store: *context.Context,
    instance_object: *Object,
    inst: *exec.Instance,
    cache: []Value,
    index: u32,
    display_name: []const u8,
) value.HostError!Value {
    if (!cache[index].isUndefined()) return cache[index];
    const function_type = inst.module.funcType(index);
    var function_name = display_name;
    if (std.mem.eql(u8, display_name, "wasm-function")) for (inst.module.exports) |entry| {
        if (entry.kind == .func and entry.index == index) {
            function_name = entry.name;
            break;
        }
    };
    const object = try gc.allocObj(self.arena);
    object.* = .{ .native = wasmExportCall, .proto = descriptor.function_proto };
    try interpreter.installNativeProps(self.arena, self.root_shape, object, function_name, function_type.params.len);
    const owner = try self.arena.create(FunctionOwner);
    owner.* = .{
        .store = store,
        .func = inst.funcs[index],
        .inst = inst,
        .function_type = function_type,
        .runtime_error_proto = descriptor.runtime_error_proto,
    };
    const state = try object.wasmFunctionState(self.arena);
    state.func = @ptrCast(owner);
    state.owner_obj = instance_object;
    cache[index] = Value.obj(object);
    return cache[index];
}

fn wrapDefinedMemory(self: *Interpreter, descriptor: *InstanceDescriptor, store: *context.Context, instance_object: *Object, mem: *exec.MemoryInst) value.HostError!Value {
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = descriptor.memory_proto };
    const owner = try store.gpa.create(MemoryOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .mem = mem, .wrapper = object, .owns_native = false };
    const buffer = try makeMemoryBuffer(self, store, mem);
    const state = try object.wasmMemoryState(self.arena);
    state.mem = @ptrCast(owner);
    state.buffer_obj = buffer;
    state.owner_obj = instance_object;
    try store.appendWasmOwned(.{ .memory = @ptrCast(owner) });
    mem.on_grow = memoryDidGrow;
    mem.on_grow_ctx = @ptrCast(owner);
    return Value.obj(object);
}

fn wrapDefinedGlobal(self: *Interpreter, descriptor: *InstanceDescriptor, store: *context.Context, instance_object: *Object, glob: *exec.GlobalInst) value.HostError!Value {
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = descriptor.global_proto };
    const owner = try store.gpa.create(GlobalOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .glob = glob, .wrapper = object, .owns_native = false };
    const state = try object.wasmGlobalState(self.arena);
    state.glob = @ptrCast(owner);
    state.ref = &glob.ref_root;
    state.owner_obj = instance_object;
    try store.appendWasmOwned(.{ .global = @ptrCast(owner) });
    return Value.obj(object);
}

fn wrapDefinedTable(
    self: *Interpreter,
    descriptor: *InstanceDescriptor,
    store: *context.Context,
    instance_object: *Object,
    inst: *exec.Instance,
    table: *exec.TableInst,
    function_cache: []Value,
) value.HostError!Value {
    const refs = try allocateTableRefs(store, table.elems.len, Value.nul());
    errdefer store.gpa.free(refs);
    for (table.elems, 0..) |slot, i| switch (slot) {
        .externref => |ref| refs[i].store(ref.bits, .monotonic),
        .funcref => |raw_func| if (raw_func) |raw| {
            const entry: *exec.FuncInst = @ptrCast(@alignCast(raw));
            var func_index: ?u32 = null;
            for (inst.funcs, 0..) |candidate, index| if (candidate == entry) {
                func_index = @intCast(index);
                break;
            };
            if (func_index) |index| {
                const exported = try functionValueFor(self, descriptor, store, instance_object, inst, function_cache, index, "wasm-function");
                refs[i].store(exported.bits, .monotonic);
            }
        },
        .numeric, .vector => unreachable,
    };
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = descriptor.table_proto };
    const owner = try store.gpa.create(TableOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .arena = self.arena, .table = table, .wrapper = object, .owns_native = false, .refs = refs };
    const state = try object.wasmTableState(self.arena);
    state.table = @ptrCast(owner);
    state.refs = refs;
    state.owner_obj = instance_object;
    try store.appendWasmOwned(.{ .table = @ptrCast(owner) });
    installTableHost(owner);
    return Value.obj(object);
}

fn syncImportedTables(
    self: *Interpreter,
    descriptor: *InstanceDescriptor,
    store: *context.Context,
    instance_object: *Object,
    inst: *exec.Instance,
    resolved: *ResolvedImports,
    function_cache: []Value,
) value.HostError!void {
    for (resolved.table_values) |table_value| {
        const table_object = table_value.asObj();
        const owner: *TableOwner = @ptrCast(@alignCast(table_object.wasmTable().?.table.?));
        owner.lockOwner();
        const native_snapshot = store.gpa.alloc(exec.ValueSlot, owner.table.elems.len) catch {
            owner.unlockOwner();
            return error.OutOfMemory;
        };
        owner.table.lockTable();
        @memcpy(native_snapshot, owner.table.elems);
        owner.table.unlockTable();
        owner.unlockOwner();
        defer store.gpa.free(native_snapshot);
        for (native_snapshot, 0..) |slot, element_index| {
            if (slot == .externref) {
                owner.lockOwner();
                if (element_index < owner.refs.len)
                    owner.refs[element_index].store(slot.externref.bits, .release);
                owner.unlockOwner();
                gc.barrierValueFrom(table_object, slot.externref);
                continue;
            }
            const raw_func = slot.funcref orelse continue;
            const func: *exec.FuncInst = @ptrCast(@alignCast(raw_func));
            var function_index: ?u32 = null;
            for (inst.funcs, 0..) |candidate, index| if (candidate == func) {
                function_index = @intCast(index);
                break;
            };
            const index = function_index orelse continue;
            const function_value = try functionValueFor(self, descriptor, store, instance_object, inst, function_cache, index, "wasm-function");
            owner.lockOwner();
            owner.table.lockTable();
            const still_current = element_index < owner.table.elems.len and
                owner.table.elems[element_index] == .funcref and
                owner.table.elems[element_index].funcref == raw_func;
            owner.table.unlockTable();
            if (still_current and element_index < owner.refs.len)
                owner.refs[element_index].store(function_value.bits, .release);
            owner.unlockOwner();
            if (still_current) gc.barrierValueFrom(table_object, function_value);
        }
    }
}

fn instantiateModuleObject(
    self: *Interpreter,
    module_value: Value,
    import_object: Value,
    descriptor: *InstanceDescriptor,
    prototype: *Object,
) value.HostError!Value {
    const module_object = languageObject(module_value) orelse return self.throwError("TypeError", "WebAssembly.Instance requires a Module");
    const module: *types.Module = @ptrCast(@alignCast(module_object.wasmModule() orelse return self.throwError("TypeError", "WebAssembly.Instance requires a Module")));
    const store = try storeFor(self);
    var resolved = try resolveImports(self, store, module, import_object, descriptor.link_error_proto);
    defer resolved.deinitTemps();
    var bridges_owned = false;
    defer if (!bridges_owned) store.gpa.free(resolved.bridges);
    var coerced_globals_owned = false;
    defer if (!coerced_globals_owned) {
        for (resolved.coerced_globals) |maybe_global|
            if (maybe_global) |global| exec.destroyGlobal(store.gpa, global);
        store.gpa.free(resolved.coerced_globals);
    };

    var diag: types.Diagnostic = .{};
    const previous = active_wasm_interp;
    active_wasm_interp = @ptrCast(self);
    defer active_wasm_interp = previous;
    const inst = exec.instantiateStore(store.gpa, module, .{
        .funcs = resolved.funcs,
        .tables = resolved.tables,
        .mems = resolved.mems,
        .globals = resolved.globals,
    }, &diag) catch |err| {
        return switch (err) {
            error.Link => throwWasmWithProto(self, "LinkError", diag.message(), descriptor.link_error_proto),
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    inst.root_hooks = .{
        .ctx = @ptrCast(store),
        .enter = enterExecutionRoots,
        .leave = leaveExecutionRoots,
        .checkpoint = checkpointExecutionRoots,
        .begin_wait = beginExecutionWait,
        .end_wait = endExecutionWait,
        .wait_interrupted = executionWaitInterrupted,
    };
    var inst_transferred = false;
    defer if (!inst_transferred) exec.destroyInstance(store.gpa, inst);

    const owner = try store.gpa.create(InstanceOwner);
    var owner_registered = false;
    defer if (!owner_registered) store.gpa.destroy(owner);
    owner.* = .{
        .store = store,
        .inst = inst,
        .bridges = resolved.bridges,
        .coerced_globals = resolved.coerced_globals,
    };
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = prototype };
    const state = try object.wasmInstanceState(self.arena);
    state.inst = @ptrCast(owner);
    state.module_obj = module_object;
    state.import_vals = resolved.values;
    const global_refs = try self.arena.alloc(*std.atomic.Value(u64), inst.globals.len);
    for (inst.globals, 0..) |global, i| global_refs[i] = &global.ref_root;
    state.global_refs = global_refs;
    for (inst.globals[module.imported_globals..]) |global| {
        global.barrier_ctx = @ptrCast(object);
        global.barrier = barrierGlobalReference;
    }
    try descriptor.roots.appendInternalElement(self.arena, Value.obj(object));
    try store.appendWasmOwned(.{ .instance = @ptrCast(owner) });
    owner_registered = true;
    inst_transferred = true;
    bridges_owned = true;
    coerced_globals_owned = true;

    const function_cache = try self.arena.alloc(Value, module.totalFuncs());
    const table_cache = try self.arena.alloc(Value, module.totalTables());
    const memory_cache = try self.arena.alloc(Value, module.totalMems());
    const global_cache = try self.arena.alloc(Value, module.totalGlobals());
    @memset(function_cache, Value.undef());
    @memset(table_cache, Value.undef());
    @memset(memory_cache, Value.undef());
    @memset(global_cache, Value.undef());
    const function_host = try self.arena.create(FunctionHostContext);
    function_host.* = .{
        .store = store,
        .descriptor = descriptor,
        .instance_object = object,
        .inst = inst,
        .cache = function_cache,
    };
    inst.function_host = .{ .ctx = @ptrCast(function_host), .resolve = resolveFunctionReference };
    for (resolved.bridges) |*bridge| bridge.inst = inst;
    for (resolved.table_values, 0..) |entry, i| table_cache[i] = entry;
    for (resolved.mem_values, 0..) |entry, i| memory_cache[i] = entry;
    for (resolved.global_values, 0..) |entry, i| global_cache[i] = entry;
    exec.applyActiveSegments(inst, &diag) catch {
        // Core 2 store mutations from earlier active segments survive a later
        // instantiation trap. The already-registered hidden instance keeps any
        // functions written into imported tables callable.
        try syncImportedTables(self, descriptor, store, object, inst, &resolved, function_cache);
        return throwWasmWithProto(self, "RuntimeError", diag.message(), descriptor.runtime_error_proto);
    };
    try syncImportedTables(self, descriptor, store, object, inst, &resolved, function_cache);

    exec.runStart(inst, &diag) catch |err| return switch (err) {
        error.Trap => throwWasmWithProto(self, "RuntimeError", diag.message(), descriptor.runtime_error_proto),
        error.Host => if (!self.exception.isUndefined()) error.Throw else error.OutOfMemory,
        error.OutOfMemory => error.OutOfMemory,
    };

    const exports = try gc.allocObj(self.arena);
    exports.* = .{ .proto = null };
    for (module.exports) |entry| {
        const exported = switch (entry.kind) {
            .func => try functionValueFor(self, descriptor, store, object, inst, function_cache, entry.index, entry.name),
            .table => blk: {
                if (table_cache[entry.index].isUndefined())
                    table_cache[entry.index] = try wrapDefinedTable(self, descriptor, store, object, inst, inst.tables[entry.index], function_cache);
                break :blk table_cache[entry.index];
            },
            .mem => blk: {
                if (memory_cache[entry.index].isUndefined())
                    memory_cache[entry.index] = try wrapDefinedMemory(self, descriptor, store, object, inst.mems[entry.index]);
                break :blk memory_cache[entry.index];
            },
            .global => blk: {
                if (global_cache[entry.index].isUndefined())
                    global_cache[entry.index] = try wrapDefinedGlobal(self, descriptor, store, object, inst.globals[entry.index]);
                break :blk global_cache[entry.index];
            },
        };
        try setData(self.arena, self.root_shape, exports, entry.name, exported, .{ .writable = false, .enumerable = true, .configurable = false });
    }
    exports.setExtensible(false);
    state.exports_obj = exports;
    gc.barrierCellFrom(object, exports);
    return Value.obj(object);
}

fn instanceConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const descriptor: *InstanceDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "WebAssembly.Instance must be called with new");
    if (args.len == 0) return self.throwError("TypeError", "WebAssembly.Instance requires a Module");
    return instantiateModuleObject(
        self,
        args[0],
        if (args.len > 1) args[1] else Value.undef(),
        descriptor,
        try constructedPrototype(self, descriptor.proto),
    );
}

fn instanceExportsGetter(ctx: *anyopaque, this: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const object = languageObject(this) orelse return self.throwError("TypeError", "WebAssembly.Instance.prototype.exports getter requires an Instance");
    const state = object.wasmInstance() orelse return self.throwError("TypeError", "WebAssembly.Instance.prototype.exports getter requires an Instance");
    _ = state.inst orelse return self.throwError("TypeError", "WebAssembly.Instance is unavailable");
    return Value.obj(state.exports_obj orelse return self.throwError("TypeError", "WebAssembly.Instance exports are unavailable"));
}

fn rejectAsyncFailure(self: *Interpreter, target: *promise.Promise, failure: value.HostError) value.HostError!void {
    if (failure != error.Throw) return failure;
    const reason = self.exception;
    self.exception = Value.undef();
    try promise.reject(self, target, reason);
}

fn stableBufferSource(self: *Interpreter, input: Value) value.HostError!Value {
    const copy = try copyBufferSource(self, input);
    defer copy.deinit();
    const stable = try self.makeArrayBuffer(copy.bytes.len);
    @memcpy(stable.arrayBuffer().?.bytes(), copy.bytes);
    return Value.obj(stable);
}

fn queueAsyncJob(
    self: *Interpreter,
    native: value.NativeFn,
    descriptor: *AsyncDescriptor,
    elements: []const Value,
) value.HostError!void {
    const job = try gc.allocObj(self.arena);
    job.* = .{ .native = native, .private_data = descriptor };
    for (elements) |element| try job.appendInternalElement(self.arena, element);
    try promise.enqueueCallback(self, Value.obj(job));
}

fn asyncCompile(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const descriptor: *AsyncDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    const promise_object = try promise.newPromise(self);
    const target = promise.promiseOf(Value.obj(promise_object)).?;
    const stable = stableBufferSource(self, if (args.len > 0) args[0] else Value.undef()) catch |failure| {
        try rejectAsyncFailure(self, target, failure);
        return Value.obj(promise_object);
    };
    try queueAsyncJob(self, asyncCompileJob, descriptor, &.{ Value.obj(promise_object), stable });
    return Value.obj(promise_object);
}

fn asyncCompileJob(ctx: *anyopaque, _: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const job = self.active_native.?;
    const descriptor: *AsyncDescriptor = @ptrCast(@alignCast(job.private_data.?));
    const target = promise.promiseOf(job.elementAt(0).?).?;
    const result = compileModuleObject(self, job.elementAt(1).?, descriptor.module, descriptor.module.proto) catch |failure| {
        try rejectAsyncFailure(self, target, failure);
        return Value.undef();
    };
    try promise.resolve(self, target, result);
    return Value.undef();
}

fn asyncInstantiate(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const descriptor: *AsyncDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    const promise_object = try promise.newPromise(self);
    const target = promise.promiseOf(Value.obj(promise_object)).?;
    const source = if (args.len > 0) args[0] else Value.undef();
    const imports = if (args.len > 1) args[1] else Value.undef();
    if (source.isObject() and source.asObj().wasmModule() != null) {
        if (!imports.isUndefined() and languageObject(imports) == null) {
            const failure = self.throwError("TypeError", "WebAssembly imports must be an object");
            try rejectAsyncFailure(self, target, failure);
            return Value.obj(promise_object);
        }
        try queueAsyncJob(self, asyncInstantiateModuleJob, descriptor, &.{ Value.obj(promise_object), source, imports });
        return Value.obj(promise_object);
    }
    const stable = stableBufferSource(self, source) catch |failure| {
        try rejectAsyncFailure(self, target, failure);
        return Value.obj(promise_object);
    };
    if (!imports.isUndefined() and languageObject(imports) == null) {
        const failure = self.throwError("TypeError", "WebAssembly imports must be an object");
        try rejectAsyncFailure(self, target, failure);
        return Value.obj(promise_object);
    }
    try queueAsyncJob(self, asyncInstantiateBytesJob, descriptor, &.{ Value.obj(promise_object), stable, imports });
    return Value.obj(promise_object);
}

fn asyncInstantiateModuleJob(ctx: *anyopaque, _: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const job = self.active_native.?;
    const descriptor: *AsyncDescriptor = @ptrCast(@alignCast(job.private_data.?));
    const target = promise.promiseOf(job.elementAt(0).?).?;
    const instance = instantiateModuleObject(
        self,
        job.elementAt(1).?,
        job.elementAt(2).?,
        descriptor.instance,
        descriptor.instance.proto,
    ) catch |failure| {
        try rejectAsyncFailure(self, target, failure);
        return Value.undef();
    };
    try promise.resolve(self, target, instance);
    return Value.undef();
}

fn asyncInstantiateBytesJob(ctx: *anyopaque, _: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const job = self.active_native.?;
    const descriptor: *AsyncDescriptor = @ptrCast(@alignCast(job.private_data.?));
    const target = promise.promiseOf(job.elementAt(0).?).?;
    const module = compileModuleObject(self, job.elementAt(1).?, descriptor.module, descriptor.module.proto) catch |failure| {
        try rejectAsyncFailure(self, target, failure);
        return Value.undef();
    };
    const instance = instantiateModuleObject(
        self,
        module,
        job.elementAt(2).?,
        descriptor.instance,
        descriptor.instance.proto,
    ) catch |failure| {
        try rejectAsyncFailure(self, target, failure);
        return Value.undef();
    };
    const result = try self.newObject();
    try self.setProp(result.asObj(), "module", module);
    try self.setProp(result.asObj(), "instance", instance);
    try promise.resolve(self, target, result);
    return Value.undef();
}

pub fn installWebAssembly(env: *Environment, rs: *Shape) value.HostError!void {
    const object_ctor = env.get("Object").?.asObj();
    const object_proto = object_ctor.getOwn("prototype").?.asObj();
    const function_proto = env.get("Function").?.asObj().getOwn("prototype").?.asObj();
    const error_proto = env.get("Error").?.asObj().getOwn("prototype").?.asObj();
    const namespace = try gc.allocObj(env.arena);
    namespace.* = .{ .proto = object_proto };

    var compile_error_proto: *Object = undefined;
    var link_error_proto: *Object = undefined;
    var runtime_error_proto: *Object = undefined;
    for ([_][]const u8{ "CompileError", "LinkError", "RuntimeError" }) |name| {
        const pair = try constructorPair(env, rs, name, 1, errorConstructor, error_proto, function_proto);
        try setData(env.arena, rs, pair.proto, "name", try Value.strAlloc(env.arena, name), .{ .writable = true, .enumerable = false, .configurable = true });
        try setData(env.arena, rs, pair.proto, "message", Value.str(""), .{ .writable = true, .enumerable = false, .configurable = true });
        const descriptor = try env.arena.create(ErrorDescriptor);
        descriptor.* = .{ .name = name, .proto = pair.proto };
        pair.ctor.private_data = descriptor;
        try setData(env.arena, rs, namespace, name, Value.obj(pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });
        if (std.mem.eql(u8, name, "CompileError")) compile_error_proto = pair.proto;
        if (std.mem.eql(u8, name, "LinkError")) link_error_proto = pair.proto;
        if (std.mem.eql(u8, name, "RuntimeError")) runtime_error_proto = pair.proto;
    }

    const module_pair = try constructorPair(env, rs, "Module", 1, moduleConstructor, object_proto, function_proto);
    const module_descriptor = try env.arena.create(ModuleDescriptor);
    module_descriptor.* = .{ .proto = module_pair.proto, .compile_error_proto = compile_error_proto };
    module_pair.ctor.private_data = module_descriptor;
    try installMethod(env.arena, rs, module_pair.ctor, "imports", 1, moduleImports);
    try installMethod(env.arena, rs, module_pair.ctor, "exports", 1, moduleExports);
    try installMethod(env.arena, rs, module_pair.ctor, "customSections", 2, moduleCustomSections);
    try setData(env.arena, rs, namespace, "Module", Value.obj(module_pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    const memory_pair = try constructorPair(env, rs, "Memory", 1, memoryConstructor, object_proto, function_proto);
    const memory_descriptor = try env.arena.create(MemoryDescriptor);
    memory_descriptor.* = .{ .proto = memory_pair.proto };
    memory_pair.ctor.private_data = memory_descriptor;
    try installAccessor(env.arena, rs, memory_pair.proto, "buffer", memoryBufferGetter, null);
    try installMethod(env.arena, rs, memory_pair.proto, "grow", 1, memoryGrow);
    try setData(env.arena, rs, namespace, "Memory", Value.obj(memory_pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    const table_pair = try constructorPair(env, rs, "Table", 1, tableConstructor, object_proto, function_proto);
    const table_descriptor = try env.arena.create(TableDescriptor);
    table_descriptor.* = .{ .proto = table_pair.proto };
    table_pair.ctor.private_data = table_descriptor;
    try installAccessor(env.arena, rs, table_pair.proto, "length", tableLengthGetter, null);
    try installMethod(env.arena, rs, table_pair.proto, "get", 1, tableGet);
    try installMethod(env.arena, rs, table_pair.proto, "set", 2, tableSet);
    try installMethod(env.arena, rs, table_pair.proto, "grow", 1, tableGrow);
    try setData(env.arena, rs, namespace, "Table", Value.obj(table_pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    const global_pair = try constructorPair(env, rs, "Global", 1, globalConstructor, object_proto, function_proto);
    const global_descriptor = try env.arena.create(GlobalDescriptor);
    global_descriptor.* = .{ .proto = global_pair.proto };
    global_pair.ctor.private_data = global_descriptor;
    try installAccessor(env.arena, rs, global_pair.proto, "value", globalValueGetter, globalValueSetter);
    try installMethod(env.arena, rs, global_pair.proto, "valueOf", 0, globalValueOf);
    try setData(env.arena, rs, namespace, "Global", Value.obj(global_pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    const instance_pair = try constructorPair(env, rs, "Instance", 1, instanceConstructor, object_proto, function_proto);
    const instance_roots = try gc.allocObj(env.arena);
    instance_roots.* = .{};
    try namespace.appendInternalElement(env.arena, Value.obj(instance_roots));
    const instance_descriptor = try env.arena.create(InstanceDescriptor);
    instance_descriptor.* = .{
        .proto = instance_pair.proto,
        .roots = instance_roots,
        .function_proto = function_proto,
        .memory_proto = memory_pair.proto,
        .table_proto = table_pair.proto,
        .global_proto = global_pair.proto,
        .link_error_proto = link_error_proto,
        .runtime_error_proto = runtime_error_proto,
    };
    instance_pair.ctor.private_data = instance_descriptor;
    try installAccessor(env.arena, rs, instance_pair.proto, "exports", instanceExportsGetter, null);
    try setData(env.arena, rs, namespace, "Instance", Value.obj(instance_pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    const async_descriptor = try env.arena.create(AsyncDescriptor);
    async_descriptor.* = .{ .module = module_descriptor, .instance = instance_descriptor };
    try installMethodWithData(env.arena, rs, namespace, "compile", 1, asyncCompile, async_descriptor);
    try installMethodWithData(env.arena, rs, namespace, "instantiate", 1, asyncInstantiate, async_descriptor);
    try installMethod(env.arena, rs, namespace, "validate", 1, validate);

    if (env.get("Symbol")) |symbol| if (symbol.isObject()) {
        if (symbol.asObj().getOwn("toStringTag")) |tag| if (tag.isObject()) {
            const key = tag.asObj().symbolKey();
            try setData(env.arena, rs, namespace, key, Value.str("WebAssembly"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, module_pair.proto, key, Value.str("WebAssembly.Module"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, memory_pair.proto, key, Value.str("WebAssembly.Memory"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, table_pair.proto, key, Value.str("WebAssembly.Table"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, global_pair.proto, key, Value.str("WebAssembly.Global"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, instance_pair.proto, key, Value.str("WebAssembly.Instance"), .{ .writable = false, .enumerable = false, .configurable = true });
        };
    };
    try env.put("WebAssembly", Value.obj(namespace));
}

pub fn installSpecHarness(env: *Environment, rs: *Shape) value.HostError!void {
    const function = try gc.allocObj(env.arena);
    function.* = .{ .native = wasmSpecInvokeBits };
    try interpreter.installNativeProps(env.arena, rs, function, "__wasmSpecInvokeBits", 1);
    try env.put("__wasmSpecInvokeBits", Value.obj(function));
}

pub fn teardownWasmStore(store: *context.Context) void {
    var index = store.wasm_registry.items.len;
    while (index > 0) {
        index -= 1;
        switch (store.wasm_registry.items[index]) {
            .module => |module_ptr| decode.destroyModule(store.gpa, @ptrCast(@alignCast(module_ptr))),
            .memory => |owner_ptr| {
                const owner: *MemoryOwner = @ptrCast(@alignCast(owner_ptr));
                owner.deinit();
            },
            .global => |owner_ptr| {
                const owner: *GlobalOwner = @ptrCast(@alignCast(owner_ptr));
                owner.deinit();
            },
            .table => |owner_ptr| {
                const owner: *TableOwner = @ptrCast(@alignCast(owner_ptr));
                owner.deinit();
            },
            .instance => |owner_ptr| {
                const owner: *InstanceOwner = @ptrCast(@alignCast(owner_ptr));
                owner.deinit();
            },
        }
    }
    store.wasm_registry.clearRetainingCapacity();
}

test "wasm api installs errors validates and reflects Module" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    const result = try store.evaluate(
        \\const bytes = new Uint8Array([0,97,115,109,1,0,0,0]);
        \\const m = new WebAssembly.Module(bytes);
        \\WebAssembly.validate(bytes) && !WebAssembly.validate(new Uint8Array([0])) &&
        \\m instanceof WebAssembly.Module && WebAssembly.Module.imports(m).length === 0 &&
        \\WebAssembly.Module.exports(m).length === 0 && WebAssembly.Module.customSections(m, 'x').length === 0 &&
        \\new WebAssembly.CompileError('x') instanceof Error && String(new WebAssembly.CompileError('x')) === 'CompileError: x' &&
        \\Object.getPrototypeOf(WebAssembly.CompileError.prototype) === Error.prototype &&
        \\Object.prototype.toString.call(WebAssembly) === '[object WebAssembly]' &&
        \\Object.prototype.toString.call(m) === '[object WebAssembly.Module]';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());

    const boundaries = try store.evaluate(
        \\let callType = false, compileType = false;
        \\const ok = new Uint8Array([0,97,115,109,1,0,0,0]);
        \\try { WebAssembly.Module(ok); } catch (e) { callType = e instanceof TypeError; }
        \\try { new WebAssembly.Module(new Uint8Array([0])); } catch (e) { compileType = e instanceof WebAssembly.CompileError && e.message.includes('@+0'); }
        \\const custom = new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0,0,4,1,120,97,98]));
        \\const sections = WebAssembly.Module.customSections(custom, 'x');
        \\callType && compileType && sections.length === 1 && sections[0].byteLength === 2;
    );
    try std.testing.expect(boundaries.isBoolean() and boundaries.asBool());
}

test "wasm api corpus harness invokes float functions bit-exactly" {
    const ordinary = try context.Context.create(std.testing.allocator);
    defer ordinary.destroy();
    const hidden = try ordinary.evaluate("typeof __wasmSpecInvokeBits === 'undefined'");
    try std.testing.expect(hidden.isBoolean() and hidden.asBool());

    const store = try context.Context.createWithTestingOptions(std.testing.allocator, .{ .wasm_spec_bit_exact = true });
    defer store.destroy();
    const result = try store.evaluate(
        \\var bytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,11,2,96,1,125,1,125,96,1,124,1,124,
        \\  3,3,2,0,1,
        \\  7,13,2,3,102,51,50,0,0,3,102,54,52,0,1,
        \\  10,11,2,4,0,32,0,11,4,0,32,0,11
        \\]);
        \\var exports = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
        \\__wasmSpecInvokeBits(exports.f32, '2143289345') === '2143289345' &&
        \\__wasmSpecInvokeBits(exports.f64, '9221120237041090561') === '9221120237041090561';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api corpus harness preserves raw v128 functions and globals" {
    const store = try context.Context.createWithTestingOptions(std.testing.allocator, .{
        .wasm_spec_bit_exact = true,
        .wasm_features = .{ .fixed_width_simd = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\var bytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,6,1,96,1,123,1,123,
        \\  3,2,1,0,
        \\  6,22,1,123,0,253,12,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,11,
        \\  7,9,2,1,102,0,0,1,103,3,0,
        \\  10,6,1,4,0,32,0,11
        \\]);
        \\var exports = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
        \\var bits = '340282366920938463463374607431768211455';
        \\let opaqueFunction = false, opaqueGlobal = false;
        \\try { exports.f(); } catch (error) { opaqueFunction = error instanceof TypeError; }
        \\try { exports.g.value; } catch (error) { opaqueGlobal = error instanceof TypeError; }
        \\__wasmSpecInvokeBits(exports.f, bits) === bits &&
        \\__wasmSpecInvokeBits(exports.g) === bits && opaqueFunction && opaqueGlobal;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api Context options gate post-MVP features explicitly" {
    try std.testing.expectError(
        error.InvalidWasmFeatures,
        context.Context.createWith(std.testing.allocator, .{ .wasm_features = .{ .gc = true } }),
    );

    const store = try context.Context.createWith(std.testing.allocator, .{
        .wasm_features = .{ .bulk_memory = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\var bytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,4,1,96,0,0,
        \\  3,2,1,0,
        \\  5,3,1,0,1,
        \\  7,16,2,3,114,117,110,0,0,6,109,101,109,111,114,121,2,0,
        \\  12,1,1,
        \\  10,17,1,15,0,65,0,65,0,65,3,252,8,0,0,252,9,0,11,
        \\  11,6,1,1,3,88,89,90
        \\]);
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
        \\instance.exports.run();
        \\const view = new Uint8Array(instance.exports.memory.buffer);
        \\let dropped = false;
        \\try { instance.exports.run(); } catch (error) { dropped = error instanceof WebAssembly.RuntimeError; }
        \\view[0] === 88 && view[1] === 89 && view[2] === 90 && dropped;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api executes opted-in Core 2.0 numeric operations" {
    const bytes_source =
        \\var bytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,11,2,96,1,127,1,127,96,1,124,1,126,
        \\  3,3,2,0,1,
        \\  7,12,2,2,115,120,0,0,3,115,97,116,0,1,
        \\  10,14,2,5,0,32,0,192,11,6,0,32,0,252,6,11
        \\]);
    ;

    const ordinary = try context.Context.create(std.testing.allocator);
    defer ordinary.destroy();
    const disabled = try ordinary.evaluate(bytes_source ++
        \\WebAssembly.validate(bytes) === false && (() => {
        \\  try { new WebAssembly.Module(bytes); } catch (error) {
        \\    return error instanceof WebAssembly.CompileError && error.message.includes('sign-extension-ops is disabled');
        \\  }
        \\  return false;
        \\})();
    );
    try std.testing.expect(disabled.isBoolean() and disabled.asBool());

    const enabled = try context.Context.createWith(std.testing.allocator, .{
        .wasm_features = .{
            .sign_extension_ops = true,
            .nontrapping_float_to_int = true,
        },
    });
    defer enabled.destroy();
    const executed = try enabled.evaluate(bytes_source ++
        \\const exports = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports;
        \\WebAssembly.validate(bytes) && exports.sx(128) === -128 &&
        \\exports.sat(NaN) === 0n && exports.sat(Infinity) === 9223372036854775807n;
    );
    try std.testing.expect(executed.isBoolean() and executed.asBool());
}

test "wasm api returns opted-in multi-value exports as arrays" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .wasm_features = .{ .multi_value = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\const bytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,6,1,96,0,2,127,126,
        \\  3,2,1,0,
        \\  7,8,1,4,112,97,105,114,0,0,
        \\  10,8,1,6,0,65,7,66,9,11
        \\]);
        \\const pair = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports.pair();
        \\Array.isArray(pair) && pair.length === 2 && pair[0] === 7 && pair[1] === 9n;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api converts iterable multi-value imports and checks arity" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .wasm_features = .{ .multi_value = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\const bytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,6,1,96,0,2,127,126,
        \\  2,12,1,3,101,110,118,4,112,97,105,114,0,0,
        \\  3,2,1,0,
        \\  7,8,1,4,112,97,105,114,0,1,
        \\  10,6,1,4,0,16,0,11
        \\]);
        \\const good = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        \\  env: { pair: () => new Set([3, 4n]) }
        \\}).exports.pair();
        \\const producerBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,6,1,96,0,2,127,126,3,2,1,0,
        \\  7,8,1,4,112,97,105,114,0,0,
        \\  10,8,1,6,0,65,7,66,9,11
        \\]);
        \\const producer = new WebAssembly.Instance(new WebAssembly.Module(producerBytes));
        \\const linked = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        \\  env: { pair: producer.exports.pair }
        \\}).exports.pair();
        \\let arity = false;
        \\try {
        \\  new WebAssembly.Instance(new WebAssembly.Module(bytes), {
        \\    env: { pair: () => [1] }
        \\  }).exports.pair();
        \\} catch (error) {
        \\  arity = error instanceof TypeError && error.message.includes('wrong number of values');
        \\}
        \\Array.isArray(good) && good[0] === 3 && good[1] === 4n &&
        \\Array.isArray(linked) && linked[0] === 7 && linked[1] === 9n && arity;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api compile snapshots bytes and rejects asynchronously" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    _ = try store.evaluate(
        \\globalThis.asyncCompile = { order: ['before'] };
        \\const source = new Uint8Array([0,97,115,109,1,0,0,0]);
        \\let validThrew = false, invalidThrew = false, typeThrew = false;
        \\try {
        \\  const pending = WebAssembly.compile(source);
        \\  asyncCompile.isPromise = pending instanceof Promise;
        \\  pending.then(module => {
        \\    asyncCompile.module = module instanceof WebAssembly.Module;
        \\    asyncCompile.order.push('fulfilled');
        \\  });
        \\} catch (_) { validThrew = true; }
        \\source[0] = 1;
        \\try {
        \\  const invalid = WebAssembly.compile(new Uint8Array([0]));
        \\  invalid.then(
        \\    () => { asyncCompile.invalid = false; },
        \\    error => { asyncCompile.invalid = error instanceof WebAssembly.CompileError; },
        \\  );
        \\} catch (_) { invalidThrew = true; }
        \\try {
        \\  const wrong = WebAssembly.compile(1);
        \\  wrong.then(
        \\    () => { asyncCompile.type = false; },
        \\    error => { asyncCompile.type = error instanceof TypeError; },
        \\  );
        \\} catch (_) { typeThrew = true; }
        \\asyncCompile.sync = !validThrew && !invalidThrew && !typeThrew;
        \\asyncCompile.order.push('after');
    );
    const result = try store.evaluate(
        \\asyncCompile.sync && asyncCompile.isPromise && asyncCompile.module &&
        \\asyncCompile.invalid && asyncCompile.type &&
        \\asyncCompile.order.join(',') === 'before,after,fulfilled';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api instantiate supports Module and byte Promise overloads" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    _ = try store.evaluate(
        \\globalThis.asyncInstantiate = { order: ['before'] };
        \\const addBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
        \\const addModule = new WebAssembly.Module(addBytes);
        \\const modulePromise = WebAssembly.instantiate(addModule);
        \\const bytesPromise = WebAssembly.instantiate(addBytes);
        \\asyncInstantiate.promises = modulePromise instanceof Promise && bytesPromise instanceof Promise;
        \\modulePromise.then(instance => {
        \\  asyncInstantiate.module = instance instanceof WebAssembly.Instance && instance.exports.add(20, 22) === 42;
        \\});
        \\bytesPromise.then(result => {
        \\  asyncInstantiate.bytes = result.module instanceof WebAssembly.Module &&
        \\    result.instance instanceof WebAssembly.Instance && result.instance.exports.add(19, 23) === 42;
        \\});
        \\let primitiveThrew = false;
        \\try {
        \\  WebAssembly.instantiate(addModule, null).then(
        \\    () => { asyncInstantiate.primitive = false; },
        \\    error => { asyncInstantiate.primitive = error instanceof TypeError; },
        \\  );
        \\} catch (_) { primitiveThrew = true; }
        \\const importBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,14,1,3,101,110,118,6,97,110,115,119,101,114,0,0,7,10,1,6,97,110,115,119,101,114,0,0]);
        \\const importModule = new WebAssembly.Module(importBytes);
        \\const imports = { get env() {
        \\  asyncInstantiate.order.push('get');
        \\  return { answer() { return 42; } };
        \\} };
        \\WebAssembly.instantiate(importModule, imports).then(instance => {
        \\  asyncInstantiate.linked = instance.exports.answer() === 42;
        \\});
        \\WebAssembly.instantiate(new Uint8Array([0])).then(
        \\  () => { asyncInstantiate.compileError = false; },
        \\  error => { asyncInstantiate.compileError = error instanceof WebAssembly.CompileError; },
        \\);
        \\WebAssembly.instantiate(importModule).then(
        \\  () => { asyncInstantiate.missingImports = false; },
        \\  error => { asyncInstantiate.missingImports = error instanceof TypeError; },
        \\);
        \\WebAssembly.instantiate(importModule, { env: { answer: 1 } }).then(
        \\  () => { asyncInstantiate.linkError = false; },
        \\  error => { asyncInstantiate.linkError = error instanceof WebAssembly.LinkError; },
        \\);
        \\asyncInstantiate.primitiveThrew = primitiveThrew;
        \\asyncInstantiate.order.push('after');
    );
    const result = try store.evaluate(
        \\asyncInstantiate.promises && asyncInstantiate.module && asyncInstantiate.bytes &&
        \\asyncInstantiate.primitive && !asyncInstantiate.primitiveThrew && asyncInstantiate.linked &&
        \\asyncInstantiate.compileError && asyncInstantiate.missingImports && asyncInstantiate.linkError &&
        \\asyncInstantiate.order.join(',') === 'before,after,get';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());

    const constructor_boundary = try store.evaluate(
        \\let primitive = false, missing = false;
        \\try { new WebAssembly.Instance(addModule, 1); } catch (error) { primitive = error instanceof TypeError; }
        \\try { new WebAssembly.Instance(importModule); } catch (error) { missing = error instanceof TypeError; }
        \\primitive && missing;
    );
    try std.testing.expect(constructor_boundary.isBoolean() and constructor_boundary.asBool());
}

test "wasm api Memory grows failure-atomically and detaches the old buffer" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    const result = try store.evaluate(
        \\const memory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
        \\const old = memory.buffer;
        \\const bytes = new Uint8Array(old);
        \\bytes[0] = 0x2a; bytes[65535] = 0x7f;
        \\const previous = memory.grow(1);
        \\const grown = memory.buffer;
        \\let limit = false, transfer = false;
        \\try { memory.grow(1); } catch (e) { limit = e instanceof RangeError && memory.buffer === grown; }
        \\try { grown.transfer(); } catch (e) { transfer = e instanceof TypeError && !grown.detached; }
        \\let clone = false, hostDetach = false;
        \\try { structuredClone(grown, { transfer: [grown] }); } catch (e) { clone = e.name === 'DataCloneError' && !grown.detached; }
        \\try { $262.detachArrayBuffer(grown); } catch (e) { hostDetach = e instanceof TypeError && !grown.detached; }
        \\previous === 1 && old.detached && old.byteLength === 0 && grown !== old &&
        \\grown.byteLength === 131072 && new Uint8Array(grown)[0] === 0x2a &&
        \\new Uint8Array(grown)[65535] === 0x7f && limit && transfer && clone && hostDetach &&
        \\memory instanceof WebAssembly.Memory &&
        \\Object.prototype.toString.call(memory) === '[object WebAssembly.Memory]';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());

    const boundaries = try store.evaluate(
        \\let missing = false, ordering = [];
        \\try { new WebAssembly.Memory({}); } catch (e) { missing = e instanceof TypeError; }
        \\try { new WebAssembly.Memory({ get initial() { ordering.push('i'); return 2; }, get maximum() { ordering.push('m'); return 1; } }); } catch (e) { ordering.push(e instanceof RangeError ? 'r' : 'x'); }
        \\class DerivedMemory extends WebAssembly.Memory {}
        \\const derived = new DerivedMemory({ initial: 0 });
        \\missing && ordering.join('') === 'imr' && derived instanceof DerivedMemory;
    );
    try std.testing.expect(boundaries.isBoolean() and boundaries.asBool());
}

test "wasm api shared Memory preserves fixed historical buffers and aliases backing" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .enable_threads = true,
        .wasm_features = .{ .threads = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\let missingMaximum = false, order = [];
        \\try { new WebAssembly.Memory({ initial: 1, shared: true }); }
        \\catch (e) { missingMaximum = e instanceof TypeError; }
        \\const memory = new WebAssembly.Memory({
        \\  get initial() { order.push('initial'); return 1; },
        \\  get maximum() { order.push('maximum'); return 2; },
        \\  get shared() { order.push('shared'); return {}; },
        \\});
        \\const oldBuffer = memory.buffer;
        \\const oldBytes = new Uint8Array(oldBuffer);
        \\oldBytes[19] = 73;
        \\const previous = memory.grow(1);
        \\const newBuffer = memory.buffer;
        \\const newBytes = new Uint8Array(newBuffer);
        \\const identity = oldBuffer !== newBuffer && oldBuffer.byteLength === 65536 &&
        \\  newBuffer.byteLength === 131072;
        \\newBytes[19] = 91;
        \\const oldClone = structuredClone(oldBuffer);
        \\const newClone = structuredClone(newBuffer);
        \\newBytes[20] = 37;
        \\const thread = new Thread(buffer => {
        \\  const bytes = new Uint8Array(buffer);
        \\  bytes[21] = 55;
        \\  return buffer.byteLength;
        \\}, oldBuffer);
        \\const threadVisible = thread.join() === 65536 && newBytes[21] === 55;
        \\let cloneFixed = oldClone.byteLength === 65536 && newClone.byteLength === 131072 &&
        \\  new Uint8Array(oldClone)[20] === 37;
        \\try { oldClone.grow(131072); cloneFixed = false; }
        \\catch (e) { cloneFixed = cloneFixed && e instanceof TypeError; }
        \\let limit = false;
        \\try { memory.grow(1); } catch (e) { limit = e instanceof RangeError; }
        \\Number(missingMaximum) +
        \\2 * Number(order.join(',') === 'initial,maximum,shared') +
        \\4 * Number(previous === 1 && identity) +
        \\8 * Number(oldBytes[19] === 91) +
        \\16 * Number(Object.prototype.toString.call(oldBuffer) === '[object SharedArrayBuffer]') +
        \\32 * Number(Object.isFrozen(oldBuffer) && Object.isFrozen(newBuffer)) +
        \\64 * Number(limit) +
        \\128 * Number(cloneFixed) +
        \\256 * Number(threadVisible);
    );
    try std.testing.expectEqual(@as(f64, 511), result.asNum());

    const defined_and_imported = try store.evaluate(
        \\const definedBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  5,4,1,3,1,2,
        \\  7,10,1,6,109,101,109,111,114,121,2,0,
        \\]);
        \\const importedBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  2,16,1,3,101,110,118,6,109,101,109,111,114,121,2,3,1,2,
        \\]);
        \\const defined = new WebAssembly.Instance(new WebAssembly.Module(definedBytes));
        \\const shared = defined.exports.memory;
        \\const linked = new WebAssembly.Instance(
        \\  new WebAssembly.Module(importedBytes), { env: { memory: shared } });
        \\let mismatch = false;
        \\try {
        \\  new WebAssembly.Instance(new WebAssembly.Module(importedBytes), {
        \\    env: { memory: new WebAssembly.Memory({ initial: 1, maximum: 2 }) },
        \\  });
        \\} catch (e) { mismatch = e instanceof WebAssembly.LinkError; }
        \\linked instanceof WebAssembly.Instance &&
        \\Object.prototype.toString.call(shared.buffer) === '[object SharedArrayBuffer]' && mismatch;
    );
    try std.testing.expect(defined_and_imported.isBoolean() and defined_and_imported.asBool());
}

test "wasm api atomic exports scale across no-GIL Threads and wake waiters" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .enable_threads = true,
        .wasm_features = .{ .threads = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\const atomicModule = new WebAssembly.Module(new Uint8Array([
        \\  0,97,115,109,1,0,0,0,1,16,3,96,1,127,1,127,96,0,1,127,96,2,127,126,
        \\  1,127,3,5,4,0,1,2,0,5,4,1,3,1,2,7,39,5,6,109,101,109,111,114,121,
        \\  2,0,3,97,100,100,0,0,4,108,111,97,100,0,1,4,119,97,105,116,0,2,6,110,
        \\  111,116,105,102,121,0,3,10,45,4,10,0,65,0,32,0,254,30,2,0,11,8,0,65,
        \\  0,254,16,2,0,11,12,0,65,0,32,0,32,1,254,1,2,0,11,10,0,65,0,32,0,254,
        \\  0,2,0,11,
        \\]));
        \\const atomic = new WebAssembly.Instance(atomicModule).exports;
        \\const workers = [];
        \\for (let i = 0; i < 8; i++) workers.push(new Thread(() => {
        \\  for (let j = 0; j < 1000; j++) atomic.add(1);
        \\}));
        \\for (const worker of workers) worker.join();
        \\const count = atomic.load();
        \\const jsView = new Int32Array(atomic.memory.buffer);
        \\const differential = Atomics.load(jsView, 0) === count &&
        \\  Atomics.add(jsView, 0, 7) === count && atomic.load() === count + 7 &&
        \\  atomic.add(-7) === count + 7 && Atomics.load(jsView, 0) === count;
        \\const waiter = new Thread(() => atomic.wait(count, 1000000000n));
        \\let woke = 0;
        \\while (woke === 0) woke = atomic.notify(1);
        \\const waitResult = waiter.join();
        \\count === 8000 && differential && woke === 1 && waitResult === 0;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api Global converts numeric values and enforces mutability" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    const result = try store.evaluate(
        \\const i32 = new WebAssembly.Global({ value: 'i32', mutable: true }, 4294967295);
        \\const i64 = new WebAssembly.Global({ value: 'i64', mutable: true }, 18446744073709551615n);
        \\const f32 = new WebAssembly.Global({ value: 'f32', mutable: true }, 1.337);
        \\const fixed = new WebAssembly.Global({ value: 'f64' }, 3.5);
        \\const rounded = Math.fround(1.337);
        \\const first = i32.value === -1 && i64.value === -1n && f32.value === rounded && +fixed === 3.5;
        \\i32.value = 4294967297; i64.value = 9223372036854775808n; f32.value = -0;
        \\let immutable = false, wrong = false;
        \\try { fixed.value = 4; } catch (e) { immutable = e instanceof TypeError && fixed.value === 3.5; }
        \\try { new WebAssembly.Global({ value: 'v128' }); } catch (e) { wrong = e instanceof TypeError; }
        \\class DerivedGlobal extends WebAssembly.Global {}
        \\const derived = new DerivedGlobal({ value: 'i32' }, 7);
        \\first && i32.value === 1 && i64.value === -9223372036854775808n && Object.is(f32.value, -0) &&
        \\immutable && wrong && derived instanceof DerivedGlobal && +derived === 7 && i32 instanceof WebAssembly.Global &&
        \\Object.prototype.toString.call(i32) === '[object WebAssembly.Global]';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api Memory buffer survives precise GC and growth" {
    const store = try context.Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer store.destroy();
    const before = try store.evaluate(
        \\globalThis.wasmMemoryRoot = new WebAssembly.Memory({ initial: 1, maximum: 3 });
        \\new Uint8Array(wasmMemoryRoot.buffer)[123] = 91;
        \\wasmMemoryRoot.buffer.byteLength;
    );
    try std.testing.expectEqual(@as(f64, 65536), before.asNum());
    store.collectGarbage();
    const after = try store.evaluate(
        \\const old = wasmMemoryRoot.buffer;
        \\wasmMemoryRoot.grow(1) === 1 && old.detached &&
        \\new Uint8Array(wasmMemoryRoot.buffer)[123] === 91;
    );
    try std.testing.expect(after.isBoolean() and after.asBool());
    store.collectGarbage();
}

test "wasm api Table preserves null references across set and grow" {
    const store = try context.Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer store.destroy();
    const result = try store.evaluate(
        \\const table = new WebAssembly.Table({ element: 'anyfunc', initial: 2, maximum: 4 });
        \\const first = table.length === 2 && table.get(0) === null && table.get(1) === null;
        \\table.set(1, null);
        \\const previous = table.grow(2, null);
        \\let bounds = false, type = false, limit = false;
        \\try { table.get(4); } catch (e) { bounds = e instanceof RangeError; }
        \\try { table.set(0, function () {}); } catch (e) { type = e instanceof TypeError; }
        \\try { table.grow(1); } catch (e) { limit = e instanceof RangeError && table.length === 4; }
        \\class DerivedTable extends WebAssembly.Table {}
        \\const derived = new DerivedTable({ element: 'anyfunc', initial: 0 });
        \\first && previous === 2 && table.length === 4 && table.get(2) === null &&
        \\bounds && type && limit && derived instanceof DerivedTable &&
        \\Object.prototype.toString.call(table) === '[object WebAssembly.Table]';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
    store.collectGarbage();
}

test "wasm api externref Table and Global preserve identity and reclaim exactly" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .enable_gc = true,
        .wasm_features = .{ .reference_types = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\globalThis.externTarget = { tag: 73 };
        \\globalThis.externWeak = new WeakRef(externTarget);
        \\globalThis.externTable = new WebAssembly.Table(
        \\  { element: 'externref', initial: 2, maximum: 4 }, externTarget);
        \\globalThis.externGlobal = new WebAssembly.Global(
        \\  { value: 'externref', mutable: true }, externTarget);
        \\const previous = externTable.grow(1, externTarget);
        \\const same = previous === 2 && externTable.get(0) === externTarget &&
        \\  externTable.get(2) === externTarget && externGlobal.value === externTarget;
        \\externTable.set(1, 42);
        \\externTable.get(1) === 42 && same;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());

    _ = try store.evaluate("globalThis.externTarget = undefined");
    store.collectGarbage();
    try std.testing.expect((try store.evaluate("externWeak.deref()?.tag === 73")).asBool());

    _ = try store.evaluate(
        \\externTable.set(0, undefined);
        \\externTable.set(2, undefined);
        \\externGlobal.value = undefined;
        \\0;
    );
    store.collectGarbage();
    try std.testing.expect((try store.evaluate("externWeak.deref() === undefined")).asBool());
}

test "wasm api reference-valued exports and imports preserve canonical identity" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .wasm_features = .{ .multi_value = true, .reference_types = true },
    });
    defer store.destroy();
    const result = try store.evaluate(
        \\const identityBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,11,2,96,1,111,1,111,96,1,112,1,112,
        \\  3,3,2,0,1,
        \\  7,13,2,3,101,120,116,0,0,3,102,117,110,0,1,
        \\  10,11,2,4,0,32,0,11,4,0,32,0,11
        \\]);
        \\const identity = new WebAssembly.Instance(new WebAssembly.Module(identityBytes));
        \\const marker = { tag: 81 };
        \\const ext = identity.exports.ext;
        \\const fun = identity.exports.fun;
        \\let rejected = false;
        \\try { fun(function ordinary() {}); } catch (e) { rejected = e instanceof TypeError; }
        \\const importBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,6,1,96,1,111,1,111,
        \\  2,12,1,3,101,110,118,4,101,99,104,111,0,0,
        \\  3,2,1,0,
        \\  7,7,1,3,114,117,110,0,1,
        \\  10,8,1,6,0,32,0,16,0,11
        \\]);
        \\let seen;
        \\const linked = new WebAssembly.Instance(new WebAssembly.Module(importBytes), {
        \\  env: { echo(value) { seen = value; return value; } }
        \\});
        \\const funImportBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,6,1,96,1,112,1,112,
        \\  2,12,1,3,101,110,118,4,101,99,104,111,0,0,
        \\  3,2,1,0,
        \\  7,7,1,3,114,117,110,0,1,
        \\  10,8,1,6,0,32,0,16,0,11
        \\]);
        \\let seenFun;
        \\const funLinked = new WebAssembly.Instance(new WebAssembly.Module(funImportBytes), {
        \\  env: { echo(value) { seenFun = value; return value; } }
        \\});
        \\const mixedBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,8,1,96,2,111,112,2,112,111,
        \\  3,2,1,0,
        \\  7,7,1,3,114,117,110,0,0,
        \\  10,8,1,6,0,32,1,32,0,11
        \\]);
        \\const mixed = new WebAssembly.Instance(new WebAssembly.Module(mixedBytes)).exports.run;
        \\const mixedResult = mixed(marker, ext);
        \\const mixedImportBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,8,1,96,2,111,112,2,112,111,
        \\  2,12,1,3,101,110,118,4,115,119,97,112,0,0,
        \\  3,2,1,0,
        \\  7,7,1,3,114,117,110,0,1,
        \\  10,10,1,8,0,32,0,32,1,16,0,11
        \\]);
        \\const mixedLinked = new WebAssembly.Instance(new WebAssembly.Module(mixedImportBytes), {
        \\  env: { swap(object, fn) { return [fn, object]; } }
        \\});
        \\const mixedImportResult = mixedLinked.exports.run(marker, ext);
        \\ext(marker) === marker && fun(ext) === ext && fun(null) === null && rejected &&
        \\  linked.exports.run(marker) === marker && seen === marker &&
        \\  funLinked.exports.run(ext) === ext && seenFun === ext &&
        \\  mixedResult[0] === ext && mixedResult[1] === marker &&
        \\  mixedImportResult[0] === ext && mixedImportResult[1] === marker;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api bulk table mutations synchronize identity and precise roots" {
    const store = try context.Context.createWith(std.testing.allocator, .{
        .enable_gc = true,
        .wasm_features = .{ .bulk_memory = true, .reference_types = true },
    });
    defer store.destroy();
    const initial = try store.evaluate(
        \\const externBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,4,1,96,0,0,
        \\  2,29,2,3,101,110,118,4,100,101,115,116,1,111,0,1,3,101,110,118,6,115,111,117,114,99,101,1,111,0,1,
        \\  3,4,3,0,0,0,
        \\  7,22,3,3,114,117,110,0,0,5,99,108,101,97,114,0,1,4,103,114,111,119,0,2,
        \\  10,37,3,12,0,65,0,65,0,65,1,252,14,0,1,11,11,0,65,0,208,111,65,1,252,17,0,11,10,0,208,111,65,1,252,15,0,26,11
        \\]);
        \\globalThis.bulkDest = new WebAssembly.Table({ element: 'externref', initial: 1 });
        \\globalThis.bulkSource = new WebAssembly.Table({ element: 'externref', initial: 1 });
        \\let marker = { bulk: 92 };
        \\globalThis.bulkWeak = new WeakRef(marker);
        \\bulkSource.set(0, marker);
        \\globalThis.bulkInstance = new WebAssembly.Instance(new WebAssembly.Module(externBytes), {
        \\  env: { dest: bulkDest, source: bulkSource }
        \\});
        \\bulkInstance.exports.run();
        \\bulkInstance.exports.grow();
        \\const copied = bulkDest.get(0) === marker && bulkDest.length === 2 && bulkDest.get(1) === null;
        \\bulkSource.set(0, null);
        \\marker = null;
        \\const funBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,8,2,96,0,1,127,96,0,0,
        \\  2,11,1,3,101,110,118,1,116,1,112,0,1,
        \\  3,3,2,0,1,
        \\  7,12,2,1,102,0,0,4,105,110,105,116,0,1,
        \\  9,5,1,1,0,1,0,
        \\  10,19,2,4,0,65,42,11,12,0,65,0,65,0,65,1,252,12,0,0,11
        \\]);
        \\const funTable = new WebAssembly.Table({ element: 'funcref', initial: 1 });
        \\const funInstance = new WebAssembly.Instance(new WebAssembly.Module(funBytes), { env: { t: funTable } });
        \\funInstance.exports.init();
        \\const funCopyBytes = new Uint8Array([
        \\  0,97,115,109,1,0,0,0,
        \\  1,4,1,96,0,0,
        \\  2,29,2,3,101,110,118,4,100,101,115,116,1,112,0,1,3,101,110,118,6,115,111,117,114,99,101,1,112,0,1,
        \\  3,2,1,0,
        \\  7,7,1,3,114,117,110,0,0,
        \\  10,14,1,12,0,65,0,65,0,65,1,252,14,0,1,11
        \\]);
        \\const funDest = new WebAssembly.Table({ element: 'funcref', initial: 1 });
        \\const funSource = new WebAssembly.Table({ element: 'funcref', initial: 1 });
        \\funSource.set(0, funInstance.exports.f);
        \\const copyingInstance = new WebAssembly.Instance(new WebAssembly.Module(funCopyBytes), {
        \\  env: { dest: funDest, source: funSource }
        \\});
        \\copyingInstance.exports.run();
        \\copied && funTable.get(0) === funInstance.exports.f && funTable.get(0)() === 42 &&
        \\  funDest.get(0) === funInstance.exports.f;
    );
    try std.testing.expect(initial.isBoolean() and initial.asBool());
    store.collectGarbage();
    const retained = try store.evaluate("bulkWeak.deref() !== undefined && bulkDest.get(0) === bulkWeak.deref()");
    try std.testing.expect(retained.isBoolean() and retained.asBool());
    _ = try store.evaluate("bulkInstance.exports.clear()");
    store.collectGarbage();
    const reclaimed = try store.evaluate("bulkWeak.deref() === undefined && bulkDest.get(0) === null");
    try std.testing.expect(reclaimed.isBoolean() and reclaimed.asBool());
}

test "wasm api Instance exports callable functions and preserves Table identity" {
    const store = try context.Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer store.destroy();
    const result = try store.evaluate(
        \\const addBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
        \\const instance = new WebAssembly.Instance(new WebAssembly.Module(addBytes));
        \\const add = instance.exports.add;
        \\const table = new WebAssembly.Table({ element: 'anyfunc', initial: 1, maximum: 2 });
        \\table.set(0, add);
        \\const previous = table.grow(1, add);
        \\add(20, 22) === 42 && add.length === 2 && add.name === 'add' &&
        \\table.get(0) === add && table.get(1) === add && previous === 1 &&
        \\instance instanceof WebAssembly.Instance && Object.getPrototypeOf(instance.exports) === null &&
        \\!Object.isExtensible(instance.exports) &&
        \\Object.prototype.toString.call(instance) === '[object WebAssembly.Instance]';
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
    store.collectGarbage();
    const after_gc = try store.evaluate("instance.exports.add(40, 2) === 42 && table.get(0) === instance.exports.add");
    try std.testing.expect(after_gc.isBoolean() and after_gc.asBool());
}

test "wasm api Instance links JS functions and preserves exceptions and import identity" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    const result = try store.evaluate(
        \\const importExportBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,14,1,3,101,110,118,6,97,110,115,119,101,114,0,0,7,10,1,6,97,110,115,119,101,114,0,0]);
        \\const imported = function answer() { return 41; };
        \\const linked = new WebAssembly.Instance(new WebAssembly.Module(importExportBytes), { env: { answer: imported } });
        \\const memoryImportBytes = new Uint8Array([0,97,115,109,1,0,0,0,2,13,1,3,101,110,118,3,109,101,109,2,1,1,2,7,7,1,3,109,101,109,2,0]);
        \\const memory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
        \\const memoryLinked = new WebAssembly.Instance(new WebAssembly.Module(memoryImportBytes), { env: { mem: memory } });
        \\const tableElemBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,2,14,1,3,101,110,118,3,116,97,98,1,112,1,1,1,3,2,1,0,7,5,1,1,102,0,0,9,7,1,0,65,0,11,1,0,10,6,1,4,0,65,42,11]);
        \\const importedTable = new WebAssembly.Table({ element: 'anyfunc', initial: 1, maximum: 1 });
        \\const tableLinked = new WebAssembly.Instance(new WebAssembly.Module(tableElemBytes), { env: { tab: importedTable } });
        \\const startBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,12,1,3,101,110,118,4,98,111,111,109,0,0,8,1,0]);
        \\const marker = new Error('marker'); let same = false, link = false;
        \\try { new WebAssembly.Instance(new WebAssembly.Module(startBytes), { env: { boom() { throw marker; } } }); } catch (e) { same = e === marker; }
        \\try { new WebAssembly.Instance(new WebAssembly.Module(importExportBytes), { env: { answer: 1 } }); } catch (e) { link = e instanceof WebAssembly.LinkError; }
        \\linked.exports.answer() === 41 && linked.exports.answer !== imported &&
        \\memoryLinked.exports.mem === memory && importedTable.get(0) === tableLinked.exports.f &&
        \\importedTable.get(0)() === 42 && same && link;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api exported traps become RuntimeError" {
    const store = try context.Context.create(std.testing.allocator);
    defer store.destroy();
    const result = try store.evaluate(
        \\const trapBytes = new Uint8Array([0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,7,8,1,4,116,114,97,112,0,0,10,5,1,3,0,0,11]);
        \\const trap = new WebAssembly.Instance(new WebAssembly.Module(trapBytes)).exports.trap;
        \\let runtime = false;
        \\try { trap(); } catch (e) { runtime = e instanceof WebAssembly.RuntimeError && e.message.includes('unreachable'); }
        \\runtime;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
}

test "wasm api trapping start retains applied store mutations" {
    const store = try context.Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer store.destroy();
    const setup = try store.evaluate(
        \\const storeBytes = new Uint8Array([
        \\  0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,0x01,0x05,0x01,0x60,0x00,0x01,0x7f,0x03,
        \\  0x03,0x02,0x00,0x00,0x04,0x04,0x01,0x70,0x00,0x01,0x05,0x03,0x01,0x00,0x01,0x07,
        \\  0x31,0x04,0x06,0x6d,0x65,0x6d,0x6f,0x72,0x79,0x02,0x00,0x05,0x74,0x61,0x62,0x6c,
        \\  0x65,0x01,0x00,0x0d,0x67,0x65,0x74,0x20,0x6d,0x65,0x6d,0x6f,0x72,0x79,0x5b,0x30,
        \\  0x5d,0x00,0x00,0x0c,0x67,0x65,0x74,0x20,0x74,0x61,0x62,0x6c,0x65,0x5b,0x30,0x5d,
        \\  0x00,0x01,0x0a,0x11,0x02,0x07,0x00,0x41,0x00,0x2d,0x00,0x00,0x0b,0x07,0x00,0x41,
        \\  0x00,0x11,0x00,0x00,0x0b
        \\]);
        \\const failingBytes = new Uint8Array([
        \\  0x00,0x61,0x73,0x6d,0x01,0x00,0x00,0x00,0x01,0x08,0x02,0x60,0x00,0x01,0x7f,0x60,
        \\  0x00,0x00,0x02,0x1b,0x02,0x02,0x4d,0x73,0x06,0x6d,0x65,0x6d,0x6f,0x72,0x79,0x02,
        \\  0x00,0x01,0x02,0x4d,0x73,0x05,0x74,0x61,0x62,0x6c,0x65,0x01,0x70,0x00,0x01,0x03,
        \\  0x03,0x02,0x00,0x01,0x08,0x01,0x01,0x09,0x07,0x01,0x00,0x41,0x00,0x0b,0x01,0x00,
        \\  0x0a,0x0c,0x02,0x06,0x00,0x41,0xad,0xbd,0x03,0x0b,0x03,0x00,0x00,0x0b,0x0b,0x0b,
        \\  0x01,0x00,0x41,0x00,0x0b,0x05,0x68,0x65,0x6c,0x6c,0x6f
        \\]);
        \\globalThis.startTrapStore = new WebAssembly.Instance(new WebAssembly.Module(storeBytes));
        \\let trapped = false;
        \\try {
        \\  new WebAssembly.Instance(new WebAssembly.Module(failingBytes), { Ms: startTrapStore.exports });
        \\} catch (error) { trapped = error instanceof WebAssembly.RuntimeError; }
        \\trapped;
    );
    try std.testing.expect(setup.isBoolean() and setup.asBool());
    store.collectGarbage();
    const retained = try store.evaluate(
        \\startTrapStore.exports['get memory[0]']() === 104 &&
        \\startTrapStore.exports['get table[0]']() === 0xdead;
    );
    try std.testing.expect(retained.isBoolean() and retained.asBool());
}

test "wasm api Instance wraps defined Memory Table and Global stores" {
    const store = try context.Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer store.destroy();
    const result = try store.evaluate(
        \\const memoryBytes = new Uint8Array([0,97,115,109,1,0,0,0,5,4,1,1,1,2,7,10,1,6,109,101,109,111,114,121,2,0]);
        \\const tableBytes = new Uint8Array([0,97,115,109,1,0,0,0,4,5,1,112,1,1,2,7,5,1,1,116,1,0]);
        \\const globalBytes = new Uint8Array([0,97,115,109,1,0,0,0,6,6,1,127,1,65,7,11,7,5,1,1,103,3,0]);
        \\const memory = new WebAssembly.Instance(new WebAssembly.Module(memoryBytes)).exports.memory;
        \\const table = new WebAssembly.Instance(new WebAssembly.Module(tableBytes)).exports.t;
        \\const global = new WebAssembly.Instance(new WebAssembly.Module(globalBytes)).exports.g;
        \\new Uint8Array(memory.buffer)[9] = 33;
        \\const old = memory.buffer;
        \\global.value = 9;
        \\memory instanceof WebAssembly.Memory && memory.grow(1) === 1 && old.detached &&
        \\new Uint8Array(memory.buffer)[9] === 33 && table instanceof WebAssembly.Table &&
        \\table.length === 1 && table.get(0) === null && global instanceof WebAssembly.Global && global.value === 9;
    );
    try std.testing.expect(result.isBoolean() and result.asBool());
    store.collectGarbage();
}
