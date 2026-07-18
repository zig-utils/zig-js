//! JavaScript-facing WebAssembly MVP API (issue #141).
//!
//! This first store slice installs the namespace, WebAssembly error classes,
//! Module construction/reflection, validate(), Memory, and Global. Instance,
//! Table, and exported functions build on the same rare-state/store seams.

const std = @import("std");
const value = @import("../value.zig");
const shape = @import("../shape.zig");
const gc = @import("../gc.zig");
const interpreter = @import("../interpreter.zig");
const context = @import("../context.zig");
const types = @import("types.zig");
const decode = @import("decode.zig");
const validate_mod = @import("validate.zig");
const exec = @import("exec.zig");

const Value = value.Value;
const Object = value.Object;
const Interpreter = interpreter.Interpreter;
const Environment = interpreter.Environment;
const Shape = shape.Shape;

const ErrorDescriptor = struct { name: []const u8, proto: *Object };
const ModuleDescriptor = struct { proto: *Object, compile_error_proto: *Object };
const MemoryDescriptor = struct { proto: *Object };
const GlobalDescriptor = struct { proto: *Object };

const MemoryOwner = struct {
    store: *context.Context,
    mem: *exec.MemoryInst,
    wrapper: *Object,
};

const GlobalOwner = struct {
    glob: *exec.GlobalInst,
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

fn moduleConstructor(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    const descriptor: *ModuleDescriptor = @ptrCast(@alignCast(self.active_native.?.private_data.?));
    if (self.new_target.isUndefined()) return self.throwError("TypeError", "WebAssembly.Module must be called with new");
    if (args.len == 0) return self.throwError("TypeError", "WebAssembly.Module requires a BufferSource");
    const copy = try copyBufferSource(self, args[0]);
    defer copy.deinit();
    const owner = self.wasm_store_ctx orelse return self.throwError("TypeError", "WebAssembly store is unavailable");
    const store: *context.Context = @ptrCast(@alignCast(owner));
    var diag: types.Diagnostic = .{};
    const module = decode.decode(store.gpa, copy.bytes, &diag) catch |err| switch (err) {
        error.Malformed => return throwCompileError(self, descriptor.compile_error_proto, &diag),
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer decode.destroyModule(store.gpa, module);
    validate_mod.validate(module, &diag) catch
        return throwCompileError(self, descriptor.compile_error_proto, &diag);
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = try constructedPrototype(self, descriptor.proto) };
    try object.setWasmModule(self.arena, @ptrCast(module));
    try store.wasm_registry.append(store.gpa, .{ .module = @ptrCast(module) });
    return Value.obj(object);
}

fn validate(ctx: *anyopaque, _: Value, args: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    if (args.len == 0) return self.throwError("TypeError", "WebAssembly.validate requires a BufferSource");
    const copy = try copyBufferSource(self, args[0]);
    defer copy.deinit();
    const allocator = if (self.wasm_store_ctx) |store_ptr| (@as(*context.Context, @ptrCast(@alignCast(store_ptr)))).gpa else self.arena;
    var diag: types.Diagnostic = .{};
    const module = decode.decode(allocator, copy.bytes, &diag) catch |err| return switch (err) {
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

fn makeMemoryBuffer(self: *Interpreter, store: *context.Context, bytes: []u8) value.HostError!*Object {
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
    const self: *Interpreter = @ptrCast(@alignCast(owner.store.wasm_active_interp orelse return false));
    const fresh = makeMemoryBuffer(self, owner.store, mem.bytes) catch return false;
    const state = owner.wrapper.wasmMemory() orelse return false;
    const old_object = state.buffer_obj orelse return false;
    const old = old_object.arrayBuffer() orelse return false;
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
    const proto = try constructedPrototype(self, native.proto);
    const store = try storeFor(self);

    const mem = try exec.createMemory(store.gpa, initial, maximum);
    errdefer exec.destroyMemory(store.gpa, mem);
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = proto };
    const owner = try store.gpa.create(MemoryOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .store = store, .mem = mem, .wrapper = object };
    const buffer = try makeMemoryBuffer(self, store, mem.bytes);
    const state = try object.wasmMemoryState(self.arena);
    state.mem = @ptrCast(owner);
    state.buffer_obj = buffer;
    mem.on_grow = memoryDidGrow;
    mem.on_grow_ctx = @ptrCast(owner);
    try store.wasm_registry.append(store.gpa, .{ .memory = @ptrCast(owner) });
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
    const previous = owner.store.wasm_active_interp;
    owner.store.wasm_active_interp = @ptrCast(self);
    defer owner.store.wasm_active_interp = previous;
    const result = exec.memoryGrow(owner.mem, delta);
    if (result < 0) return self.throwError("RangeError", "WebAssembly.Memory could not grow");
    return Value.num(@floatFromInt(result));
}

fn globalTypeFromDescriptor(self: *Interpreter, descriptor: *Object) value.HostError!types.ValType {
    const raw = try self.getProperty(Value.obj(descriptor), "value");
    const name = try self.toStringV(raw);
    inline for ([_]types.ValType{ .i32, .i64, .f32, .f64 }) |kind| {
        if (std.mem.eql(u8, name, kind.name())) return kind;
    }
    return self.throwError("TypeError", "WebAssembly.Global descriptor has an unsupported value type");
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
        .funcref => unreachable,
    };
}

fn globalValue(self: *Interpreter, glob: *exec.GlobalInst) value.HostError!Value {
    return switch (glob.type.val) {
        .i32 => Value.num(@floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(glob.value)))))),
        .i64 => try self.makeBigInt(@as(i64, @bitCast(glob.value))),
        .f32 => Value.num(@as(f32, @bitCast(@as(u32, @truncate(glob.value))))),
        .f64 => Value.num(@bitCast(glob.value)),
        .funcref => unreachable,
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
        else => Value.num(0),
    };
    const bits = try coerceGlobalBits(self, kind, initial);
    const proto = try constructedPrototype(self, native.proto);
    const store = try storeFor(self);
    const glob = try exec.createGlobal(store.gpa, .{ .val = kind, .mutable = mutable }, bits);
    errdefer exec.destroyGlobal(store.gpa, glob);
    const owner = try store.gpa.create(GlobalOwner);
    errdefer store.gpa.destroy(owner);
    owner.* = .{ .glob = glob };
    const object = try gc.allocObj(self.arena);
    object.* = .{ .proto = proto };
    const state = try object.wasmGlobalState(self.arena);
    state.glob = @ptrCast(owner);
    try store.wasm_registry.append(store.gpa, .{ .global = @ptrCast(owner) });
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
    owner.glob.value = try coerceGlobalBits(self, owner.glob.type.val, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

fn globalValueOf(ctx: *anyopaque, this: Value, _: []const Value) value.HostError!Value {
    const self = activeInterpreter(ctx);
    return globalValue(self, (try globalFromThis(self, this, "WebAssembly.Global.prototype.valueOf requires a Global")).glob);
}

pub fn installWebAssembly(env: *Environment, rs: *Shape) value.HostError!void {
    const object_ctor = env.get("Object").?.asObj();
    const object_proto = object_ctor.getOwn("prototype").?.asObj();
    const function_proto = env.get("Function").?.asObj().getOwn("prototype").?.asObj();
    const error_proto = env.get("Error").?.asObj().getOwn("prototype").?.asObj();
    const namespace = try gc.allocObj(env.arena);
    namespace.* = .{ .proto = object_proto };

    var compile_error_proto: *Object = undefined;
    for ([_][]const u8{ "CompileError", "LinkError", "RuntimeError" }) |name| {
        const pair = try constructorPair(env, rs, name, 1, errorConstructor, error_proto, function_proto);
        try setData(env.arena, rs, pair.proto, "name", try Value.strAlloc(env.arena, name), .{ .writable = true, .enumerable = false, .configurable = true });
        try setData(env.arena, rs, pair.proto, "message", Value.str(""), .{ .writable = true, .enumerable = false, .configurable = true });
        const descriptor = try env.arena.create(ErrorDescriptor);
        descriptor.* = .{ .name = name, .proto = pair.proto };
        pair.ctor.private_data = descriptor;
        try setData(env.arena, rs, namespace, name, Value.obj(pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });
        if (std.mem.eql(u8, name, "CompileError")) compile_error_proto = pair.proto;
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

    const global_pair = try constructorPair(env, rs, "Global", 1, globalConstructor, object_proto, function_proto);
    const global_descriptor = try env.arena.create(GlobalDescriptor);
    global_descriptor.* = .{ .proto = global_pair.proto };
    global_pair.ctor.private_data = global_descriptor;
    try installAccessor(env.arena, rs, global_pair.proto, "value", globalValueGetter, globalValueSetter);
    try installMethod(env.arena, rs, global_pair.proto, "valueOf", 0, globalValueOf);
    try setData(env.arena, rs, namespace, "Global", Value.obj(global_pair.ctor), .{ .writable = true, .enumerable = false, .configurable = true });

    try installMethod(env.arena, rs, namespace, "validate", 1, validate);

    if (env.get("Symbol")) |symbol| if (symbol.isObject()) {
        if (symbol.asObj().getOwn("toStringTag")) |tag| if (tag.isObject()) {
            const key = tag.asObj().symbolKey();
            try setData(env.arena, rs, namespace, key, Value.str("WebAssembly"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, module_pair.proto, key, Value.str("WebAssembly.Module"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, memory_pair.proto, key, Value.str("WebAssembly.Memory"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, global_pair.proto, key, Value.str("WebAssembly.Global"), .{ .writable = false, .enumerable = false, .configurable = true });
        };
    };
    try env.put("WebAssembly", Value.obj(namespace));
}

pub fn teardownWasmStore(store: *context.Context) void {
    var index = store.wasm_registry.items.len;
    while (index > 0) {
        index -= 1;
        switch (store.wasm_registry.items[index]) {
            .module => |module_ptr| decode.destroyModule(store.gpa, @ptrCast(@alignCast(module_ptr))),
            .memory => |owner_ptr| {
                const owner: *MemoryOwner = @ptrCast(@alignCast(owner_ptr));
                exec.destroyMemory(store.gpa, owner.mem);
                store.gpa.destroy(owner);
            },
            .global => |owner_ptr| {
                const owner: *GlobalOwner = @ptrCast(@alignCast(owner_ptr));
                exec.destroyGlobal(store.gpa, owner.glob);
                store.gpa.destroy(owner);
            },
            .instance, .table => {}, // implemented by the next store slice
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
