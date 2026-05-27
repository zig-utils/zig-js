//! Tier-1 bytecode VM for zig-js.
//!
//! Executes a compiled `Chunk` against an `Interpreter`'s live state — the same
//! `Environment` chain, `this`, `exception`, and helper routines the tree-walker
//! uses. That sharing is deliberate: the VM is a faster *execution strategy*,
//! not a second semantics. Variable access still goes through the environment
//! (turning names into slot indexes is the next perf tier); what we remove here
//! is AST recursion and per-node dispatch.
//!
//! Calls recurse on the host stack: a VM-compiled callee runs in a nested `run`,
//! a tree-walk-only or native callee is delegated to `Interpreter`. Programs run
//! entirely in one mode (VM or tree-walk), so a VM frame only ever creates and
//! calls VM closures plus host natives.

const std = @import("std");
const bc = @import("bytecode.zig");
const value = @import("value.zig");
const interp = @import("interpreter.zig");

const Value = value.Value;
const Chunk = bc.Chunk;
const Interpreter = interp.Interpreter;
const Environment = interp.Environment;
const Function = interp.Function;
const EvalError = interp.EvalError;

/// A function activation's flat local store. `slots` holds parameters then
/// function-scoped declarations (indexes assigned by the compiler); `parent` is
/// the *defining* function's frame, walked to resolve upvalues. Heap-allocated
/// so a closure can outlive the call that created it. Globals live in the
/// Environment, not here.
pub const Frame = struct {
    slots: []Value,
    parent: ?*Frame,
};

/// Run `chunk` to completion, returning the program's accumulator (for a
/// top-level chunk, `frame == null`) or the function's return value. `frame`
/// is the current activation for `load_local`/`load_upval`.
pub fn run(vm: *Interpreter, chunk: *Chunk, frame: ?*Frame) EvalError!Value {
    var stack: std.ArrayListUnmanaged(Value) = .empty;
    var acc: Value = .undefined;
    var ip: usize = 0;
    const code = chunk.code.items;

    while (ip < code.len) {
        const inst = code[ip];
        ip += 1;
        switch (inst.op) {
            .load_const => try stack.append(vm.arena, chunk.consts.items[inst.a]),
            .load_undefined => try stack.append(vm.arena, .undefined),
            .load_null => try stack.append(vm.arena, .null),
            .load_true => try stack.append(vm.arena, .{ .boolean = true }),
            .load_false => try stack.append(vm.arena, .{ .boolean = false }),
            .pop => _ = stack.pop(),
            .dup => try stack.append(vm.arena, stack.items[stack.items.len - 1]),
            .set_acc => acc = stack.pop().?,

            .load_var => {
                const name = chunk.names.items[inst.a];
                const v = vm.env.get(name) orelse return vm.throwError("ReferenceError", name);
                try stack.append(vm.arena, v);
            },
            .store_var => {
                const name = chunk.names.items[inst.a];
                try vm.env.assign(name, stack.items[stack.items.len - 1]); // assignment leaves its value
            },
            .def_var => {
                const name = chunk.names.items[inst.a];
                try vm.env.put(name, stack.pop().?);
            },

            .load_local => try stack.append(vm.arena, frame.?.slots[inst.a]),
            .store_local => frame.?.slots[inst.a] = stack.items[stack.items.len - 1], // leaves value
            .load_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                try stack.append(vm.arena, f.slots[inst.b]);
            },
            .store_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                f.slots[inst.b] = stack.items[stack.items.len - 1]; // leaves value
            },

            .neg => {
                const v = stack.pop().?;
                try stack.append(vm.arena, .{ .number = -v.toNumber() });
            },
            .pos => {
                const v = stack.pop().?;
                try stack.append(vm.arena, .{ .number = v.toNumber() });
            },
            .not => {
                const v = stack.pop().?;
                try stack.append(vm.arena, .{ .boolean = !v.toBoolean() });
            },
            .typeof_op => {
                const v = stack.pop().?;
                try stack.append(vm.arena, .{ .string = v.typeOf() });
            },
            .bit_not => {
                const v = stack.pop().?;
                try stack.append(vm.arena, .{ .number = @floatFromInt(~v.toInt32()) });
            },
            .void_op => {
                _ = stack.pop().?;
                try stack.append(vm.arena, .undefined);
            },

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => {
                const r = stack.pop().?;
                const l = stack.pop().?;
                try stack.append(vm.arena, try vm.applyBinary(binOp(inst.op), l, r));
            },

            .jump => ip = inst.a,
            .jump_if_false => if (!stack.pop().?.toBoolean()) {
                ip = inst.a;
            },
            .jump_if_true_peek => if (stack.items[stack.items.len - 1].toBoolean()) {
                ip = inst.a;
            },
            .jump_if_false_peek => if (!stack.items[stack.items.len - 1].toBoolean()) {
                ip = inst.a;
            },

            .load_this => try stack.append(vm.arena, vm.this_value),
            .new_object => try stack.append(vm.arena, try vm.newObject()),
            .new_array => try stack.append(vm.arena, try vm.newArray()),
            .init_prop => {
                const v = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                try vm.setMember(obj, chunk.names.items[inst.a], v);
            },
            .array_append => {
                const v = stack.pop().?;
                const arr = stack.items[stack.items.len - 1];
                try arr.object.elements.append(vm.arena, v);
            },
            .get_prop => {
                const obj = stack.pop().?;
                const name = chunk.names.items[inst.a];
                var result: Value = undefined;
                fast: {
                    // Inline cache: plain (non-array) objects with a shape.
                    if (obj == .object and !obj.object.is_array) {
                        const o = obj.object;
                        const ic = &chunk.ics[ip - 1];
                        if (o.shape != null and o.shape == ic.shape) {
                            result = o.slots.items[ic.slot];
                            break :fast;
                        }
                        if (o.shape) |sh| {
                            if (sh.lookup(name)) |slot| {
                                ic.shape = sh;
                                ic.slot = slot;
                                result = o.slots.items[slot];
                                break :fast;
                            }
                        }
                        result = .undefined; // own-property miss on a plain object
                        break :fast;
                    }
                    result = try vm.getProperty(obj, name); // arrays, strings, null/undefined
                }
                try stack.append(vm.arena, result);
            },
            .get_index => {
                const key = stack.pop().?;
                const obj = stack.pop().?;
                try stack.append(vm.arena, try vm.getProperty(obj, try key.toString(vm.arena)));
            },
            .set_prop => {
                const v = stack.pop().?;
                const obj = stack.pop().?;
                const name = chunk.names.items[inst.a];
                fast: {
                    // Inline cache hits only update an existing slot; adding a
                    // property transitions the shape, so it goes the slow path.
                    if (obj == .object and !obj.object.is_array) {
                        const o = obj.object;
                        const ic = &chunk.ics[ip - 1];
                        if (o.shape != null and o.shape == ic.shape) {
                            o.slots.items[ic.slot] = v;
                            break :fast;
                        }
                        if (o.shape) |sh| {
                            if (sh.lookup(name)) |slot| {
                                ic.shape = sh;
                                ic.slot = slot;
                                o.slots.items[slot] = v;
                                break :fast;
                            }
                        }
                    }
                    try vm.setMember(obj, name, v);
                }
                try stack.append(vm.arena, v); // assignment yields the value
            },
            .set_index => {
                const v = stack.pop().?;
                const key = stack.pop().?;
                const obj = stack.pop().?;
                try vm.setMember(obj, try key.toString(vm.arena), v);
                try stack.append(vm.arena, v);
            },
            .instance_of => {
                const r = stack.pop().?;
                const l = stack.pop().?;
                try stack.append(vm.arena, .{ .boolean = try vm.instanceOf(l, r) });
            },

            .make_closure => try stack.append(vm.arena, try makeClosure(vm, chunk.fns.items[inst.a], frame)),
            .call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                const result = try callValue(vm, callee, stack.items[base..], .undefined);
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(vm.arena, result);
            },
            .call_method => {
                const argc = inst.b;
                const base = stack.items.len - argc;
                const recv = stack.items[base - 1];
                const args = stack.items[base..];
                const name = chunk.names.items[inst.a];
                const result = if (try vm.arrayBuiltin(recv, name, args)) |r|
                    r
                else
                    try callValue(vm, try vm.getProperty(recv, name), args, recv);
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(vm.arena, result);
            },
            .new_call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                const result = try construct(vm, callee, stack.items[base..]);
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(vm.arena, result);
            },

            .ret => return stack.pop().?,
            .ret_undef => return .undefined,
            .halt => return acc,
        }
    }
    return acc;
}

/// Map a binary opcode back to the shared `ast.BinaryOp`. The opcode set mirrors
/// the operator set 1:1 (minus `instanceof`, which the compiler never emits).
fn binOp(op: bc.Op) @import("ast.zig").BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .eq => .eq,
        .neq => .neq,
        .eq_strict => .eq_strict,
        .neq_strict => .neq_strict,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .ushr => .ushr,
        else => unreachable,
    };
}

/// Build a Function value from a template, capturing the current `frame` as the
/// closure's upvalue source. Tagged with the compiled `chunk` so calls take the
/// VM path; `closure` (the global env) is kept only to satisfy the shared type.
fn makeClosure(vm: *Interpreter, tmpl: *bc.FnTemplate, frame: ?*Frame) EvalError!Value {
    const func = try vm.arena.create(Function);
    func.* = .{
        .params = tmpl.params,
        .body = tmpl.body,
        .is_expr_body = tmpl.is_expr_body,
        .closure = vm.env,
        .name = tmpl.name,
        .chunk = tmpl.chunk,
        .frame = frame,
        .local_count = tmpl.local_count,
    };
    const obj = try vm.arena.create(value.Object);
    obj.* = .{ .js_func = @ptrCast(func) };
    return .{ .object = obj };
}

/// Invoke `callee` with `args` and an explicit `this`. A VM-compiled function
/// runs in a nested VM frame; everything else (natives, error constructors,
/// tree-walk closures) is handed to the interpreter.
fn callValue(vm: *Interpreter, callee: Value, args: []const Value, this_val: Value) EvalError!Value {
    if (callee == .object) {
        if (callee.object.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            if (func.chunk) |fchunk| return runFunction(vm, func, fchunk, args, this_val);
        }
    }
    return vm.callValueWithThis(callee, args, this_val);
}

/// `new callee(args)`. A VM-compiled constructor runs on the VM with a fresh
/// `this` (tagged for `instanceof`); error constructors and tree-walk functions
/// are delegated to the interpreter.
fn construct(vm: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
    if (callee == .object) {
        if (callee.object.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            if (func.chunk) |fchunk| {
                const this_obj = try vm.arena.create(value.Object);
                this_obj.* = .{ .ctor_ref = callee.object };
                const this_val: Value = .{ .object = this_obj };
                const ret = try runFunction(vm, func, fchunk, args, this_val);
                return if (ret == .object) ret else this_val;
            }
        }
    }
    return vm.construct(callee, args);
}

fn runFunction(vm: *Interpreter, func: *Function, fchunk: *Chunk, args: []const Value, this_val: Value) EvalError!Value {
    // Allocate the activation frame: slots default to undefined, the first
    // `params.len` are filled from the arguments. Globals stay in `vm.env`.
    const slots = try vm.arena.alloc(Value, func.local_count);
    @memset(slots, .undefined);
    for (func.params, 0..) |_, i| {
        if (i < args.len) slots[i] = args[i];
    }
    const frame = try vm.arena.create(Frame);
    frame.* = .{
        .slots = slots,
        .parent = if (func.frame) |fp| @ptrCast(@alignCast(fp)) else null,
    };

    const saved_this = vm.this_value;
    vm.this_value = this_val;
    defer vm.this_value = saved_this;
    return run(vm, fchunk, frame);
}

// ---------------------------------------------------------------------------
// Tests — compile a program and execute it *on the VM* (no tree-walk fallback),
// so these assert the bytecode path itself, not just end-to-end behavior.
// ---------------------------------------------------------------------------

const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;

/// Compile + run on the VM, asserting the program was within the compiler's
/// supported subset (i.e. it really exercised the bytecode path).
fn vmRun(arena: std.mem.Allocator, src: []const u8) !Value {
    var parser = try Parser.init(arena, src);
    const prog = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(arena, prog);
    var env = Environment{ .arena = arena };
    try interp.installGlobals(&env);
    const root_shape = try @import("shape.zig").Shape.createRoot(arena);
    var machine = Interpreter{ .arena = arena, .env = &env, .root_shape = root_shape };
    return run(&machine, chunk, null);
}

test "vm: arithmetic, precedence, comparison, logical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(a, "1 + 2 * 3")).number);
    try std.testing.expectEqual(@as(f64, 1024), (try vmRun(a, "2 ** 10")).number);
    try std.testing.expect((try vmRun(a, "3 > 2 && 2 >= 2")).boolean);
    try std.testing.expect((try vmRun(a, "false || 1 === 1")).boolean);
    try std.testing.expectEqualStrings("ab1", (try vmRun(a, "'a' + 'b' + 1")).string);
}

test "vm: vars, while loop, ternary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 15), (try vmRun(a,
        \\let x = 0; let i = 1;
        \\while (i <= 5) { x = x + i; i = i + 1; }
        \\x
    )).number);
    try std.testing.expectEqual(@as(f64, 10), (try vmRun(a, "true ? 10 : 20")).number);
}

test "vm: functions, recursion, closures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 42), (try vmRun(a,
        \\function add(x, y) { return x + y; }
        \\add(40, 2)
    )).number);
    try std.testing.expectEqual(@as(f64, 120), (try vmRun(a,
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\fact(5)
    )).number);
    try std.testing.expectEqual(@as(f64, 15), (try vmRun(a,
        \\function mk(x) { return function (y) { return x + y; }; }
        \\mk(10)(5)
    )).number);
}

test "vm: if/else and short-circuit value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(a, "let v = 0; if (3 > 2) { v = 1; } else { v = 2; } v")).number);
    try std.testing.expectEqual(@as(f64, 5), (try vmRun(a, "0 || 5")).number);
    try std.testing.expectEqual(@as(f64, 0), (try vmRun(a, "0 && 5")).number);
}

test "vm: objects, arrays, members, this, new, instanceof on the VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), (try vmRun(a, "let o = { x: 1, y: 2 }; o.x + o.y")).number);
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(a, "let o = {}; o.a = 4; o['b'] = 5; o.a + o['b']")).number);
    try std.testing.expectEqual(@as(f64, 30), (try vmRun(a, "let xs = [10, 20, 30]; xs[2]")).number);
    try std.testing.expectEqual(@as(f64, 4), (try vmRun(a, "let xs = [1]; xs.push(2); xs.push(3); xs.push(4); xs.length")).number);
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(a, "function P(x, y) { this.x = x; this.y = y; } let p = new P(3, 4); p.x + p.y")).number);
    try std.testing.expect((try vmRun(a, "function P(x) { this.x = x; } (new P(1)) instanceof P")).boolean);
    try std.testing.expectEqual(@as(f64, 10), (try vmRun(a, "let o = { n: 10, get: function () { return this.n; } }; o.get()")).number);
}

test "vm: for loop with ++ and compound assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 45), (try vmRun(a, "let s = 0; for (let i = 0; i < 10; i++) { s += i; } s")).number);
    try std.testing.expectEqual(@as(f64, 5), (try vmRun(a, "let x = 5; let y = x++; y")).number);
    try std.testing.expectEqual(@as(f64, 6), (try vmRun(a, "let x = 5; let y = ++x; y")).number);
}

test "vm: compiler still falls back for try/catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = try Parser.init(a, "try { throw 1; } catch (e) {}");
    const prog = try parser.parseProgram();
    try std.testing.expectError(error.Unsupported, Compiler.compileProgram(a, prog));
}
