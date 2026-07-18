//! JavaScript-facing WebAssembly MVP API (issue #141).
//!
//! This first store slice installs the namespace, WebAssembly error classes,
//! Module construction/reflection, and validate(). Instance and the mutable
//! store objects build on the same rare-state and context registry seams.

const std = @import("std");
const value = @import("../value.zig");
const shape = @import("../shape.zig");
const gc = @import("../gc.zig");
const interpreter = @import("../interpreter.zig");
const context = @import("../context.zig");
const types = @import("types.zig");
const decode = @import("decode.zig");
const validate_mod = @import("validate.zig");

const Value = value.Value;
const Object = value.Object;
const Interpreter = interpreter.Interpreter;
const Environment = interpreter.Environment;
const Shape = shape.Shape;

const ErrorDescriptor = struct { name: []const u8, proto: *Object };
const ModuleDescriptor = struct { proto: *Object, compile_error_proto: *Object };

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
    object.* = .{ .proto = descriptor.proto };
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
    try installMethod(env.arena, rs, namespace, "validate", 1, validate);

    if (env.get("Symbol")) |symbol| if (symbol.isObject()) {
        if (symbol.asObj().getOwn("toStringTag")) |tag| if (tag.isObject()) {
            const key = tag.asObj().symbolKey();
            try setData(env.arena, rs, namespace, key, Value.str("WebAssembly"), .{ .writable = false, .enumerable = false, .configurable = true });
            try setData(env.arena, rs, module_pair.proto, key, Value.str("WebAssembly.Module"), .{ .writable = false, .enumerable = false, .configurable = true });
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
            .instance, .memory, .table, .global => {}, // implemented by the next store slice
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
