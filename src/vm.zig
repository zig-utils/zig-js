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
const promise = @import("promise.zig");

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

/// A resumable execution state: the operand stack, completion accumulator, and
/// instruction pointer. For a normal call this lives on the host stack and is
/// thrown away when `run` returns; for a generator it lives in the `Generator`
/// and persists across `yield`/resume, which is what makes suspension faithful
/// (the whole operand stack is saved, so a `yield` can sit mid-expression).
pub const Exec = struct {
    stack: std.ArrayListUnmanaged(Value) = .empty,
    acc: Value = .undefined,
    ip: usize = 0,
    /// Active try/catch handlers, innermost last. Lives in `Exec` so it persists
    /// across a generator's `yield`/resume (a `yield` can sit inside a `try`).
    handlers: std.ArrayListUnmanaged(Handler) = .empty,
};

/// A live try handler: where to resume on a throw and the operand-stack depth
/// to unwind to first (everything pushed inside the `try` is discarded). A
/// throw goes to `catch_pc` if present (pushing the exception for the binding);
/// otherwise, if there's a `finally_pc`, it runs the finally carrying a "throw"
/// completion that is re-thrown after. `none` (u32 max) means that arm is absent.
pub const Handler = struct {
    catch_pc: u32,
    finally_pc: u32 = none,
    stack_depth: u32,

    pub const none: u32 = std.math.maxInt(u32);
};

/// A finally block's completion kind (the `kind` half of the record left on the
/// stack for `end_finally`): fall through, re-throw, or return.
const Completion = enum(u8) { normal = 0, throw = 1, ret = 2, break_ = 3, continue_ = 4 };

/// Unwind `exec.handlers` (innermost-first) to the next `finally`, carrying an
/// abrupt completion `[cval, kind]` so the finally runs and `end_finally`
/// re-propagates it. Returns the finally's PC, or null if none remains (the
/// caller performs the terminal action: return / jump-to-target / re-throw).
fn unwindToFinally(vm: *Interpreter, exec: *Exec, cval: Value, kind: Completion) !?u32 {
    while (exec.handlers.items.len > 0) {
        const h = exec.handlers.pop().?;
        if (h.finally_pc != Handler.none) {
            exec.stack.shrinkRetainingCapacity(h.stack_depth);
            try exec.stack.append(vm.arena, cval);
            try exec.stack.append(vm.arena, .{ .number = @floatFromInt(@intFromEnum(kind)) });
            return h.finally_pc;
        }
    }
    return null;
}

/// A suspended `function*` activation: its compiled body, persistent execution
/// state, and the `Environment` its body resolves names against (a child of the
/// closure, holding the params/locals across yields). Driven by `genNext`.
pub const Generator = struct {
    chunk: *Chunk,
    exec: Exec = .{},
    env: *Environment,
    this_value: Value = .undefined,
    home_object: ?*value.Object = null,
    super_ctor: ?*value.Object = null,
    started: bool = false,
    done: bool = false,
    suspended: bool = false,
    running: bool = false,
    /// An async function activation (vs a `function*`). It is driven by promise
    /// settlement rather than `.next()`: each `await` suspends like a `yield`,
    /// and `result` is the promise the call returned, settled on completion.
    is_async: bool = false,
    result: ?*value.Object = null,
    /// Whether the last suspension was an `await` (resume on promise settlement)
    /// or a `yield` (resume on the next request) — set by the suspend opcode so
    /// the async-generator driver can tell them apart.
    suspend_kind: enum { yield, await } = .yield,
    /// True while suspended at a `yield*` delegation point (`gen_yield_star`). A
    /// `.throw(e)`/`.return(v)` resume must then be *forwarded* to the inner
    /// iterator by the desugared loop (rather than injected/completed here), so
    /// the resume pushes `[value, kind]` and re-enters the body. Cleared at every
    /// plain `yield`/`await` (those resume points are not delegation points).
    delegating: bool = false,
    /// `async function*` activation: each `.next()`/`.return()`/`.throw()`
    /// enqueues a request (a result promise + an action) that the driver pumps.
    is_async_gen: bool = false,
    requests: std.ArrayListUnmanaged(AsyncGenRequest) = .empty,
    pumping: bool = false,
};

/// A queued async-generator request: how to resume the body and the promise to
/// settle with the resulting `{ value, done }` (or rejection).
pub const AsyncGenRequest = struct {
    kind: ResumeKind,
    value: Value,
    result: *value.Object,
};

/// Property-key string for a computed index: a Symbol uses its unique internal
/// encoding (matching the tree-walker's `memberKey`); everything else coerces
/// to string.
fn propKey(vm: *Interpreter, key: Value) EvalError![]const u8 {
    if (key == .object and key.object.is_symbol) return key.object.sym_key;
    return key.toString(vm.arena);
}

/// Run `chunk` to completion, returning the program's accumulator (for a
/// top-level chunk, `frame == null`) or the function's return value. `frame`
/// is the current activation for `load_local`/`load_upval`.
pub fn run(vm: *Interpreter, chunk: *Chunk, frame: ?*Frame) EvalError!Value {
    var exec = Exec{};
    return execLoop(vm, &exec, chunk, frame, null);
}

/// The instruction loop. `exec` holds the (resumable) stack/acc/ip; `gen` is
/// non-null only when running a generator body, enabling the `gen_yield` opcode
/// to snapshot `exec` and suspend. For a normal call `gen` is null and
/// `gen_yield` never appears (the compiler emits it only into generator chunks).
fn execLoop(vm: *Interpreter, exec: *Exec, chunk: *Chunk, frame: ?*Frame, gen: ?*Generator) EvalError!Value {
    // Run the instruction stream; if a throw escapes and an active handler can
    // catch it, unwind to that handler's catch block and resume. Otherwise the
    // throw propagates to the caller (uncaught — the generator/function ends).
    while (true) {
        return runChunk(vm, exec, chunk, frame, gen) catch |e| {
            if (e == error.Throw and exec.handlers.items.len > 0) {
                const h = exec.handlers.pop().?;
                exec.stack.shrinkRetainingCapacity(h.stack_depth);
                if (h.catch_pc != Handler.none) {
                    try exec.stack.append(vm.arena, vm.exception); // bind target for the catch
                    exec.ip = h.catch_pc;
                } else {
                    // No catch: run the finally carrying a "throw" completion,
                    // which `end_finally` re-throws once the finally completes.
                    try exec.stack.append(vm.arena, vm.exception);
                    try exec.stack.append(vm.arena, .{ .number = @floatFromInt(@intFromEnum(Completion.throw)) });
                    exec.ip = h.finally_pc;
                }
                continue;
            }
            return e;
        };
    }
}

/// The instruction loop proper. Operates on `exec.stack` directly so the
/// operand stack is always current when a throw unwinds (and persists across a
/// generator's yield/resume). Returns the completion value or propagates a throw.
fn runChunk(vm: *Interpreter, exec: *Exec, chunk: *Chunk, frame: ?*Frame, gen: ?*Generator) EvalError!Value {
    const stack = &exec.stack;
    var acc: Value = exec.acc;
    var ip: usize = exec.ip;
    const code = chunk.code.items;

    while (ip < code.len) {
        vm.steps += 1;
        if (vm.steps > interp.max_steps) return vm.throwError("RangeError", "evaluation step budget exceeded");
        if ((vm.steps & 1023) == 0) {
            if (vm.stop_flag) |sf| if (sf.load(.monotonic))
                return vm.throwError("Error", "worker terminated");
            if (vm.gil) |g| g.yieldIfContended();
        }
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
                const v = vm.env.get(name) orelse vm.globalProp(name) orelse return vm.throwError("ReferenceError", name);
                try stack.append(vm.arena, v);
            },
            .load_var_or_undef => {
                const name = chunk.names.items[inst.a];
                try stack.append(vm.arena, vm.env.get(name) orelse vm.globalProp(name) orelse .undefined);
            },
            .store_var => {
                const name = chunk.names.items[inst.a];
                try vm.assignVarVM(name, stack.items[stack.items.len - 1]); // assignment leaves its value
            },
            .def_var => {
                const name = chunk.names.items[inst.a];
                try vm.globalDefine(name, stack.pop().?);
            },
            .def_lex => {
                const name = chunk.names.items[inst.a];
                try vm.defineLexicalVM(name, stack.pop().?, inst.b == 2);
            },
            .bind_pattern => {
                // Reuse the tree-walker's destructuring over the live env (a=pattern
                // index, b=mode: 0 var, 1 let, 2 const, 3 assign).
                const pat = chunk.patterns.items[inst.a];
                const v = stack.pop().?;
                try vm.bindPatternVM(pat, v, inst.b);
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
            .to_string => {
                const v = stack.pop().?;
                try stack.append(vm.arena, .{ .string = try vm.toStringV(v) });
            },

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict, .in_op, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => {
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
            .init_prop_computed => {
                const key = stack.pop().?;
                const v = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                try vm.setMember(obj, try propKey(vm, key), v);
            },
            .init_spread => {
                const src = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                try vm.spreadDataProps(obj, src);
            },
            .init_getter, .init_setter => {
                const fn_val = stack.pop().?;
                const key = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                try vm.vmInitAccessor(obj, key, fn_val, inst.op == .init_getter);
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
                    // Inline cache: plain (non-array) objects with a shape and
                    // no accessor/attribute overrides (those need the full
                    // [[Get]] path: getters + the prototype walk).
                    if (obj == .object and !obj.object.is_array and obj.object.accessors == null and obj.object.attrs == null) {
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
                        // own miss → fall through to full [[Get]] (prototype walk
                        // + `.constructor` fallback), not a bare undefined.
                    }
                    result = try vm.getProperty(obj, name); // arrays, strings, proto chain, null/undefined
                }
                try stack.append(vm.arena, result);
            },
            .get_index => {
                const key = stack.pop().?;
                const obj = stack.pop().?;
                try stack.append(vm.arena, try vm.getProperty(obj, try propKey(vm, key)));
            },
            .set_prop => {
                const v = stack.pop().?;
                const obj = stack.pop().?;
                const name = chunk.names.items[inst.a];
                fast: {
                    // Inline cache hits only update an existing slot; adding a
                    // property transitions the shape, so it goes the slow path.
                    // Objects with accessor/attribute overrides also take the
                    // slow path ([[Set]] honors setters + non-writable).
                    if (obj == .object and !obj.object.is_array and obj.object.accessors == null and obj.object.attrs == null) {
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
                try vm.setMember(obj, try propKey(vm, key), v);
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
                const result = try invokeMethod(vm, recv, name, args);
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
            .call_spread => {
                const args_arr = stack.pop().?;
                const callee = stack.pop().?;
                try stack.append(vm.arena, try callValue(vm, callee, args_arr.object.elements.items, .undefined));
            },
            .call_method_spread => {
                const args_arr = stack.pop().?;
                const recv = stack.pop().?;
                const name = chunk.names.items[inst.a];
                const args = args_arr.object.elements.items;
                const result = try invokeMethod(vm, recv, name, args);
                try stack.append(vm.arena, result);
            },
            .new_spread => {
                const args_arr = stack.pop().?;
                const callee = stack.pop().?;
                try stack.append(vm.arena, try construct(vm, callee, args_arr.object.elements.items));
            },

            .ret => return stack.pop().?,
            .ret_undef => return .undefined,
            .abrupt_return => {
                // A return that must run enclosing `finally` blocks first: unwind
                // to the nearest finally carrying a "return" completion (which
                // `end_finally` re-propagates), or return directly if none.
                const rv = stack.pop().?;
                if (try unwindToFinally(vm, exec, rv, .ret)) |fpc| ip = fpc else return rv;
            },
            .abrupt_break, .abrupt_continue => {
                // A break/continue that crosses a `finally`: run the enclosing
                // finally(s) first, then jump to the (patched) loop target. The
                // target PC rides through as the completion value.
                const kind: Completion = if (inst.op == .abrupt_break) .break_ else .continue_;
                const target: Value = .{ .number = @floatFromInt(inst.a) };
                if (try unwindToFinally(vm, exec, target, kind)) |fpc| ip = fpc else ip = inst.a;
            },

            .gen_yield, .await_op, .gen_yield_star => {
                const v = stack.pop().?;
                if (gen) |g| {
                    // Snapshot the resumable state and hand the yielded/awaited
                    // value back to the driver. The next resume pushes the sent
                    // value (this expression's result) and continues at `ip`.
                    // `stack`/`handlers` already live in `exec` (operated on by
                    // pointer), so only `acc`/`ip` need writing back here.
                    exec.acc = acc;
                    exec.ip = ip;
                    g.suspended = true;
                    g.suspend_kind = if (inst.op == .await_op) .await else .yield;
                    // A `yield*` delegation point must intercept throw()/return()
                    // and forward them to the inner iterator; any other suspend
                    // point handles them itself (inject / complete).
                    g.delegating = inst.op == .gen_yield_star;
                    return v;
                }
                return vm.throwError("SyntaxError", "yield outside a generator");
            },
            .call_with_this => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const args = stack.items[base..];
                const this_val = stack.items[base - 1];
                const callee = stack.items[base - 2];
                const res = try callValue(vm, callee, args, this_val);
                stack.shrinkRetainingCapacity(base - 2);
                try stack.append(vm.arena, res);
            },
            .assert_iter_result => {
                if (stack.items[stack.items.len - 1] != .object)
                    return vm.throwError("TypeError", "iterator result is not an object");
            },
            .iter_of => {
                const v = stack.pop().?;
                try stack.append(vm.arena, try vm.iteratorOf(v));
            },
            .async_iter_of => {
                const v = stack.pop().?;
                try stack.append(vm.arena, try vm.asyncIteratorOf(v));
            },
            .enum_keys => {
                const v = stack.pop().?;
                try stack.append(vm.arena, try vm.forInKeysArray(v));
            },
            .iter_close => {
                const it = stack.pop().?;
                try vm.iteratorClose(it);
            },
            .array_spread => {
                const iterable = stack.pop().?;
                // The array stays on the stack (peeked); append the iterable's
                // elements into it.
                try vm.spreadInto(&stack.items[stack.items.len - 1].object.elements, iterable);
            },
            .throw_op => {
                vm.exception = stack.pop().?;
                return error.Throw;
            },
            .push_handler => try exec.handlers.append(vm.arena, .{
                .catch_pc = inst.a,
                .finally_pc = inst.b,
                .stack_depth = @intCast(stack.items.len),
            }),
            .pop_handler => _ = exec.handlers.pop(),
            .push_completion => {
                // [value, kind] — value is undefined for a normal completion.
                try stack.append(vm.arena, .undefined);
                try stack.append(vm.arena, .{ .number = @floatFromInt(inst.a) });
            },
            .end_finally => {
                const kind: Completion = @enumFromInt(@as(u8, @intFromFloat(stack.pop().?.number)));
                const cval = stack.pop().?;
                switch (kind) {
                    .normal => {}, // fall through past the finally
                    .throw => {
                        vm.exception = cval;
                        return error.Throw; // re-thrown to the next handler
                    },
                    // An abrupt completion re-propagates through any *further*
                    // enclosing finally before terminating, so nested finallys all
                    // run (return value / break-or-continue target rides as cval).
                    .ret => {
                        if (try unwindToFinally(vm, exec, cval, .ret)) |fpc| ip = fpc else return cval;
                    },
                    .break_, .continue_ => {
                        if (try unwindToFinally(vm, exec, cval, kind)) |fpc| ip = fpc else ip = @intFromFloat(cval.number);
                    },
                }
            },

            .halt => return acc,
        }
    }
    return acc;
}

// ---------------------------------------------------------------------------
// Generators: calling a `function*` builds a `Generator` (via `makeGenerator`),
// and `.next(v)`/`.return(v)`/`.throw(e)` drive it. Each resume restores the
// generator's `this`/env/home/super, runs the VM loop until the next `yield`
// (or completion), then restores the caller's context.
// ---------------------------------------------------------------------------

/// `{ value, done }` — the IteratorResult every generator method returns.
fn makeIterResult(vm: *Interpreter, v: Value, done: bool) EvalError!Value {
    const o = try vm.newObject();
    try vm.setMember(o, "value", v);
    try vm.setMember(o, "done", .{ .boolean = done });
    return o;
}

/// Build the generator object produced by calling a `function*`. The body is
/// not run yet; it runs lazily on the first `.next()`.
pub fn makeGenerator(vm: *Interpreter, func: *Function, args: []const Value, this_val: Value) EvalError!Value {
    const chunk = func.gen_chunk orelse
        return vm.throwError("TypeError", "generator body uses syntax not yet supported by the VM");

    // The generator's scope: a child of the closure, so free variables resolve
    // outward while params/locals live here and persist across yields.
    const genv = try vm.arena.create(Environment);
    genv.* = .{ .arena = vm.arena, .parent = func.closure, .fn_scope = true };

    const args_obj = try vm.newArray(); // generators are never arrow functions
    for (args) |av| try args_obj.object.elements.append(vm.arena, av);
    try genv.put("arguments", args_obj);

    // Bind params into the generator's environment (handles default/rest/
    // destructuring). `bindParams` binds into `vm.env`, so point it at `genv`
    // for the duration — defaults are evaluated now, at generator creation,
    // per spec. Restore the caller's env afterward.
    const saved_env = vm.env;
    vm.env = genv;
    defer vm.env = saved_env;
    try vm.bindParams(func.params, args);

    const g = try vm.arena.create(Generator);
    g.* = .{
        .chunk = chunk,
        .env = genv,
        .this_value = this_val,
        .home_object = func.home_object,
        .super_ctor = func.super_ctor,
    };
    const obj = try vm.arena.create(value.Object);
    obj.* = .{ .gen = @ptrCast(g) };
    // The instance's [[Prototype]] is the generator function's own `.prototype`
    // object (whose own [[Prototype]] is %GeneratorPrototype%), per
    // OrdinaryCreateFromConstructor. Falls back to %GeneratorPrototype% directly
    // if `.prototype` was reassigned to a non-object. Either way `.next()` keeps
    // using the callMethod fast path.
    set_proto: {
        if (func.obj) |fobj| {
            const fp = try vm.getProperty(.{ .object = fobj }, "prototype");
            if (fp == .object) {
                obj.proto = fp.object;
                break :set_proto;
            }
        }
        if (vm.env.get("\x00GenProto")) |p| if (p == .object) {
            obj.proto = p.object;
        };
    }
    return .{ .object = obj };
}

/// How a generator is being resumed: a normal `.next(v)`, a `.throw(e)` that
/// injects an exception at the suspend point, or a `.return(v)` that completes it.
const ResumeKind = enum { send, throw_, return_ };

/// The numeric tag a delegation resume (`gen_yield_star`) pushes alongside the
/// resume value, so the desugared `yield*` loop can branch on how it was resumed:
/// 0 = `.next(v)`, 1 = `.throw(e)`, 2 = `.return(v)`.
fn resumeKindNum(kind: ResumeKind) Value {
    return .{ .number = switch (kind) {
        .send => 0,
        .throw_ => 1,
        .return_ => 2,
    } };
}

/// Shared driver for `.next`/`.throw`/`.return`. Restores the generator's
/// context, applies the resume action at the suspend point, runs the VM to the
/// next `yield` (or completion), then restores the caller's context.
fn genResume(vm: *Interpreter, gen_obj: *value.Object, kind: ResumeKind, val: Value) EvalError!Value {
    const g: *Generator = @ptrCast(@alignCast(gen_obj.gen.?));
    if (g.running) return vm.throwError("TypeError", "generator is already running");

    // A completed (or not-yet-started) generator handles each kind without
    // re-entering the body.
    if (g.done) return switch (kind) {
        .send => makeIterResult(vm, .undefined, true),
        .return_ => makeIterResult(vm, val, true),
        .throw_ => blk: {
            vm.exception = val;
            break :blk error.Throw;
        },
    };
    if (!g.started) {
        switch (kind) {
            .send => {}, // fall through to start the body at the top
            .return_ => {
                g.done = true;
                return makeIterResult(vm, val, true);
            },
            .throw_ => {
                g.done = true;
                vm.exception = val;
                return error.Throw;
            },
        }
    } else if (g.delegating) {
        // Suspended at a `yield*` delegation point: forward the resume to the
        // inner iterator by handing the desugared loop `[value, kind]` and
        // re-entering the body, whatever the resume kind.
        g.delegating = false;
        try g.exec.stack.append(vm.arena, val);
        try g.exec.stack.append(vm.arena, resumeKindNum(kind));
    } else {
        // Suspended at a `yield`: apply the resume action.
        switch (kind) {
            .send => try g.exec.stack.append(vm.arena, val), // becomes the yield's value
            .return_ => {
                // If the suspend point is inside a `try` with a `finally`, run
                // that finally (carrying a "return" completion) before the
                // generator completes; otherwise complete immediately.
                var fin: ?u32 = null;
                while (g.exec.handlers.items.len > 0) {
                    const h = g.exec.handlers.pop().?;
                    if (h.finally_pc != Handler.none) {
                        g.exec.stack.shrinkRetainingCapacity(h.stack_depth);
                        fin = h.finally_pc;
                        break;
                    }
                }
                if (fin) |fpc| {
                    try g.exec.stack.append(vm.arena, val); // completion value
                    try g.exec.stack.append(vm.arena, .{ .number = @floatFromInt(@intFromEnum(Completion.ret)) });
                    g.exec.ip = fpc;
                    // fall through to run the finally via execLoop
                } else {
                    g.done = true;
                    return makeIterResult(vm, val, true);
                }
            },
            .throw_ => {
                // Inject the exception at the suspend point: unwind to the
                // generator's own nearest handler, or finish if there is none.
                if (!try injectThrowAt(vm, g, val)) {
                    g.done = true;
                    vm.exception = val;
                    return error.Throw;
                }
            },
        }
    }

    g.running = true;
    defer g.running = false;
    g.started = true;
    g.suspended = false;

    const s_env = vm.env;
    const s_this = vm.this_value;
    const s_home = vm.home_object;
    const s_super = vm.super_ctor;
    vm.env = g.env;
    vm.this_value = g.this_value;
    vm.home_object = g.home_object;
    vm.super_ctor = g.super_ctor;
    defer {
        vm.env = s_env;
        vm.this_value = s_this;
        vm.home_object = s_home;
        vm.super_ctor = s_super;
    }

    if (vm.depth >= interp.max_call_depth) return vm.throwError("RangeError", "Maximum call stack size exceeded");
    vm.depth += 1;
    defer vm.depth -= 1;

    const v = execLoop(vm, &g.exec, g.chunk, null, g) catch |e| {
        g.done = true; // a thrown generator is finished
        return e;
    };
    if (g.suspended) {
        // A `yield*` delegation point (`gen_yield_star` sets `delegating`) yields
        // the inner iterator's result object *as-is* (`GeneratorYield(innerResult)`);
        // a plain `yield` yields a raw value that we wrap into `{ value, done }`.
        if (g.delegating) return v;
        return makeIterResult(vm, v, false);
    }
    g.done = true;
    return makeIterResult(vm, v, true); // `v` is the body's return value
}

pub fn asyncGenObj(gen_obj: *value.Object) bool {
    const g: *Generator = @ptrCast(@alignCast(gen_obj.gen.?));
    return g.is_async_gen;
}

/// `gen.next(sent)`: resume the body, `sent` becoming the value of the resumed
/// `yield` (ignored on the first call, which starts at the top). An async
/// generator instead enqueues the request and returns a promise.
pub fn genNext(vm: *Interpreter, gen_obj: *value.Object, sent: Value) EvalError!Value {
    if (asyncGenObj(gen_obj)) return asyncGenRequest(vm, gen_obj, .send, sent);
    return genResume(vm, gen_obj, .send, sent);
}

/// `gen.return(v)`: finish the generator, yielding `{ value: v, done: true }`.
pub fn genReturn(vm: *Interpreter, gen_obj: *value.Object, v: Value) EvalError!Value {
    if (asyncGenObj(gen_obj)) return asyncGenRequest(vm, gen_obj, .return_, v);
    return genResume(vm, gen_obj, .return_, v);
}

/// `gen.throw(e)`: inject `e` at the suspend point so an enclosing `try`/`catch`
/// in the generator can handle it; otherwise the generator finishes and `e`
/// propagates to the caller.
pub fn genThrow(vm: *Interpreter, gen_obj: *value.Object, e: Value) EvalError!Value {
    if (asyncGenObj(gen_obj)) return asyncGenRequest(vm, gen_obj, .throw_, e);
    return genResume(vm, gen_obj, .throw_, e);
}

/// Route a thrown value `e` to the suspended activation's nearest handler:
/// jump to its catch block (pushing `e`), or run its finally with a "throw"
/// completion. Returns false when there's no handler (the caller propagates).
fn injectThrowAt(vm: *Interpreter, g: *Generator, e: Value) EvalError!bool {
    if (g.exec.handlers.items.len == 0) return false;
    const h = g.exec.handlers.pop().?;
    g.exec.stack.shrinkRetainingCapacity(h.stack_depth);
    if (h.catch_pc != Handler.none) {
        try g.exec.stack.append(vm.arena, e); // catch binding
        g.exec.ip = h.catch_pc;
    } else {
        try g.exec.stack.append(vm.arena, e); // finally completion value
        try g.exec.stack.append(vm.arena, .{ .number = @floatFromInt(@intFromEnum(Completion.throw)) });
        g.exec.ip = h.finally_pc;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Async functions: a plain `async function` compiled to a suspendable body is
// run as an activation driven by promise settlement. Calling it builds the
// activation and a result promise, runs to the first `await` (or completion),
// and returns the promise; each awaited value's settlement resumes the body.
// ---------------------------------------------------------------------------

/// Call a VM-compiled async function: build the activation, start it, and
/// return its result promise.
pub fn runAsync(vm: *Interpreter, func: *Function, args: []const Value, this_val: Value) EvalError!Value {
    const chunk = func.async_chunk.?;
    const genv = try vm.arena.create(Environment);
    genv.* = .{ .arena = vm.arena, .parent = func.closure, .fn_scope = true };
    const args_obj = try vm.newArray();
    for (args) |av| try args_obj.object.elements.append(vm.arena, av);
    try genv.put("arguments", args_obj);
    const saved_env = vm.env;
    vm.env = genv;
    defer vm.env = saved_env;
    try vm.bindParams(func.params, args);

    const g = try vm.arena.create(Generator);
    g.* = .{
        .chunk = chunk,
        .env = genv,
        .this_value = this_val,
        .home_object = func.home_object,
        .super_ctor = func.super_ctor,
        .is_async = true,
        .result = try promise.newPromise(vm),
    };
    try asyncDrive(vm, g, .send, .undefined);
    return .{ .object = g.result.? };
}

fn resultPromise(g: *Generator) *promise.Promise {
    return @ptrCast(@alignCast(g.result.?.promise.?));
}

/// Run the async activation until its next `await` or completion, then settle
/// its result promise (on return/throw) or wire resume reactions (on await).
fn asyncDrive(vm: *Interpreter, g: *Generator, kind: ResumeKind, val: Value) EvalError!void {
    if (g.done or g.running) return;
    if (g.started) {
        switch (kind) {
            .send => try g.exec.stack.append(vm.arena, val), // the awaited value
            .throw_ => {
                // An awaited rejection: route to a handler, else reject the result.
                if (!try injectThrowAt(vm, g, val)) {
                    g.done = true;
                    try promise.reject(vm, resultPromise(g), val);
                    return;
                }
            },
            .return_ => {},
        }
    }
    g.started = true;
    g.running = true;
    defer g.running = false;
    g.suspended = false;

    const s_env = vm.env;
    const s_this = vm.this_value;
    const s_home = vm.home_object;
    const s_super = vm.super_ctor;
    vm.env = g.env;
    vm.this_value = g.this_value;
    vm.home_object = g.home_object;
    vm.super_ctor = g.super_ctor;
    defer {
        vm.env = s_env;
        vm.this_value = s_this;
        vm.home_object = s_home;
        vm.super_ctor = s_super;
    }
    if (vm.depth >= interp.max_call_depth) return vm.throwError("RangeError", "Maximum call stack size exceeded");
    vm.depth += 1;
    defer vm.depth -= 1;

    const v = execLoop(vm, &g.exec, g.chunk, null, g) catch |e| {
        if (e != error.Throw) return e;
        g.done = true;
        const reason = vm.exception;
        vm.exception = .undefined;
        try promise.reject(vm, resultPromise(g), reason);
        return;
    };
    if (g.suspended) {
        // `await v`: resume when `Promise.resolve(v)` settles.
        g.suspended = false;
        const awaited = try promise.newPromise(vm);
        try promise.resolve(vm, @ptrCast(@alignCast(awaited.promise.?)), v);
        const onf = try vm.arena.create(value.Object);
        onf.* = .{ .native = asyncOnFulfill, .private_data = @ptrCast(g) };
        const onr = try vm.arena.create(value.Object);
        onr.* = .{ .native = asyncOnReject, .private_data = @ptrCast(g) };
        _ = try promise.then(vm, @ptrCast(@alignCast(awaited.promise.?)), .{ .object = onf }, .{ .object = onr });
        return;
    }
    g.done = true;
    try promise.resolve(vm, resultPromise(g), v);
}

fn asyncOnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try asyncDrive(vm, g, .send, if (args.len > 0) args[0] else .undefined);
    return .undefined;
}

fn asyncOnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try asyncDrive(vm, g, .throw_, if (args.len > 0) args[0] else .undefined);
    return .undefined;
}

// ---------------------------------------------------------------------------
// Async generators: `async function*` — a generator whose body may both `yield`
// and `await`, and whose `.next()`/`.return()`/`.throw()` each return a promise.
// Requests are queued and pumped one at a time; a `yield` settles the current
// request's promise with `{ value, done:false }`, an `await` suspends until the
// awaited value settles (then the same request continues), and completion
// settles with `{ value, done:true }`.
// ---------------------------------------------------------------------------

/// Build the async-generator object produced by calling an `async function*`.
pub fn makeAsyncGenerator(vm: *Interpreter, func: *Function, args: []const Value, this_val: Value) EvalError!Value {
    const chunk = func.gen_chunk orelse
        return vm.throwError("TypeError", "async generator body uses syntax not yet supported by the VM");
    const genv = try vm.arena.create(Environment);
    genv.* = .{ .arena = vm.arena, .parent = func.closure, .fn_scope = true };
    const args_obj = try vm.newArray();
    for (args) |av| try args_obj.object.elements.append(vm.arena, av);
    try genv.put("arguments", args_obj);
    const saved_env = vm.env;
    vm.env = genv;
    defer vm.env = saved_env;
    try vm.bindParams(func.params, args);

    const g = try vm.arena.create(Generator);
    g.* = .{
        .chunk = chunk,
        .env = genv,
        .this_value = this_val,
        .home_object = func.home_object,
        .super_ctor = func.super_ctor,
        .is_async_gen = true,
    };
    const obj = try vm.arena.create(value.Object);
    obj.* = .{ .gen = @ptrCast(g) };
    // The instance's [[Prototype]] is the async-generator function's own
    // `.prototype` object, whose own [[Prototype]] is %AsyncGeneratorPrototype%
    // (itself chaining to %AsyncIteratorPrototype% for the helper methods), per
    // OrdinaryCreateFromConstructor. Falls back to %AsyncGeneratorPrototype% if
    // `.prototype` was reassigned to a non-object. `next`/`return`/`throw` are
    // still served by the gen special-case in `builtinMethod`.
    set_proto: {
        if (func.obj) |fobj| {
            const fp = try vm.getProperty(.{ .object = fobj }, "prototype");
            if (fp == .object) {
                obj.proto = fp.object;
                break :set_proto;
            }
        }
        if (vm.env.get("\x00AsyncGenProto")) |p| if (p == .object) {
            obj.proto = p.object;
        };
    }
    return .{ .object = obj };
}

/// `asyncGen.next/return/throw(v)` — enqueue a request and return a promise for
/// its `{ value, done }`. Pumping starts if no request is already in flight.
pub fn asyncGenRequest(vm: *Interpreter, gen_obj: *value.Object, kind: ResumeKind, val: Value) EvalError!Value {
    const g: *Generator = @ptrCast(@alignCast(gen_obj.gen.?));
    const rp = try promise.newPromise(vm);
    const was_idle = g.requests.items.len == 0;
    try g.requests.append(vm.arena, .{ .kind = kind, .value = val, .result = rp });
    // A completed generator never resumes: each new request settles immediately
    // (next/return → `{done:true}`, throw → reject) rather than re-running the
    // body from its final instruction pointer.
    if (g.done) {
        if (was_idle) try agDrainDone(vm, g);
    } else if (was_idle) try agStep(vm, g, kind, val);
    return .{ .object = rp };
}

const AgStep = union(enum) { awaited: Value, yielded: Value, returned: Value, threw: Value };

/// Resume the async-generator body once and report why it stopped.
fn agResume(vm: *Interpreter, g: *Generator, kind: ResumeKind, val: Value) EvalError!AgStep {
    if (g.started and g.delegating) {
        // `yield*` delegation point: forward the resume to the inner iterator.
        g.delegating = false;
        try g.exec.stack.append(vm.arena, val);
        try g.exec.stack.append(vm.arena, resumeKindNum(kind));
    } else if (g.started) {
        switch (kind) {
            .send => try g.exec.stack.append(vm.arena, val),
            .throw_ => if (!try injectThrowAt(vm, g, val)) return .{ .threw = val },
            .return_ => {
                // Run an enclosing finally if any; else the generator returns.
                var fin: ?u32 = null;
                while (g.exec.handlers.items.len > 0) {
                    const h = g.exec.handlers.pop().?;
                    if (h.finally_pc != Handler.none) {
                        g.exec.stack.shrinkRetainingCapacity(h.stack_depth);
                        fin = h.finally_pc;
                        break;
                    }
                }
                if (fin) |fpc| {
                    try g.exec.stack.append(vm.arena, val);
                    try g.exec.stack.append(vm.arena, .{ .number = @floatFromInt(@intFromEnum(Completion.ret)) });
                    g.exec.ip = fpc;
                } else return .{ .returned = val };
            },
        }
    } else switch (kind) {
        // Not yet started: `next` runs the body from the top, but `return`/`throw`
        // complete the generator immediately without ever executing the body.
        .send => {},
        .return_ => {
            g.done = true;
            return .{ .returned = val };
        },
        .throw_ => {
            g.done = true;
            return .{ .threw = val };
        },
    }
    g.started = true;
    g.suspended = false;
    const s_env = vm.env;
    const s_this = vm.this_value;
    const s_home = vm.home_object;
    const s_super = vm.super_ctor;
    vm.env = g.env;
    vm.this_value = g.this_value;
    vm.home_object = g.home_object;
    vm.super_ctor = g.super_ctor;
    defer {
        vm.env = s_env;
        vm.this_value = s_this;
        vm.home_object = s_home;
        vm.super_ctor = s_super;
    }
    if (vm.depth >= interp.max_call_depth) return vm.throwError("RangeError", "Maximum call stack size exceeded");
    vm.depth += 1;
    defer vm.depth -= 1;

    const v = execLoop(vm, &g.exec, g.chunk, null, g) catch |e| {
        if (e != error.Throw) return e;
        const reason = vm.exception;
        vm.exception = .undefined;
        return .{ .threw = reason };
    };
    if (g.suspended) {
        g.suspended = false;
        return if (g.suspend_kind == .await) .{ .awaited = v } else .{ .yielded = v };
    }
    return .{ .returned = v };
}

/// Drive the front request to its next stop, settling its promise (yield/
/// return/throw) or wiring an await continuation.
fn agStep(vm: *Interpreter, g: *Generator, kind: ResumeKind, val: Value) EvalError!void {
    const step = try agResume(vm, g, kind, val);
    const front = g.requests.items[0].result;
    switch (step) {
        .awaited => |awaited| {
            const ap = try promise.newPromise(vm);
            try promise.resolve(vm, @ptrCast(@alignCast(ap.promise.?)), awaited);
            const onf = try vm.arena.create(value.Object);
            onf.* = .{ .native = agOnFulfill, .private_data = @ptrCast(g) };
            const onr = try vm.arena.create(value.Object);
            onr.* = .{ .native = agOnReject, .private_data = @ptrCast(g) };
            _ = try promise.then(vm, @ptrCast(@alignCast(ap.promise.?)), .{ .object = onf }, .{ .object = onr });
        },
        .yielded => |v| {
            try promise.resolve(vm, @ptrCast(@alignCast(front.promise.?)), try makeIterResult(vm, v, false));
            _ = g.requests.orderedRemove(0);
            try agPumpNext(vm, g);
        },
        .returned => |v| {
            // AsyncGeneratorAwaitReturn: await the return value, then resolve the
            // request as a done result (the front request stays queued until the
            // await callback settles it).
            g.done = true;
            const ap = try promise.newPromise(vm);
            try promise.resolve(vm, @ptrCast(@alignCast(ap.promise.?)), v);
            const onf = try vm.arena.create(value.Object);
            onf.* = .{ .native = agReturnFulfill, .private_data = @ptrCast(g) };
            const onr = try vm.arena.create(value.Object);
            onr.* = .{ .native = agReturnReject, .private_data = @ptrCast(g) };
            _ = try promise.then(vm, @ptrCast(@alignCast(ap.promise.?)), .{ .object = onf }, .{ .object = onr });
        },
        .threw => |e| {
            g.done = true;
            try promise.reject(vm, @ptrCast(@alignCast(front.promise.?)), e);
            _ = g.requests.orderedRemove(0);
            try agDrainDone(vm, g);
        },
    }
}

fn agPumpNext(vm: *Interpreter, g: *Generator) EvalError!void {
    if (g.done) return agDrainDone(vm, g);
    if (g.requests.items.len == 0) return;
    const req = g.requests.items[0];
    try agStep(vm, g, req.kind, req.value);
}

/// Once the generator is done, settle every still-queued request: a `next`
/// yields `{ undefined, done:true }`, a `return` its value, a `throw` rejects.
fn agDrainDone(vm: *Interpreter, g: *Generator) EvalError!void {
    while (g.requests.items.len > 0) {
        const req = g.requests.orderedRemove(0);
        switch (req.kind) {
            .throw_ => try promise.reject(vm, @ptrCast(@alignCast(req.result.promise.?)), req.value),
            .return_ => try promise.resolve(vm, @ptrCast(@alignCast(req.result.promise.?)), try makeIterResult(vm, req.value, true)),
            .send => try promise.resolve(vm, @ptrCast(@alignCast(req.result.promise.?)), try makeIterResult(vm, .undefined, true)),
        }
    }
}

/// AsyncGeneratorAwaitReturn fulfilled: the (awaited) return value resolves the
/// front request as a done iterator result, then any queued requests drain.
fn agReturnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    if (g.requests.items.len == 0) return .undefined;
    const front = g.requests.items[0].result;
    try promise.resolve(vm, @ptrCast(@alignCast(front.promise.?)), try makeIterResult(vm, if (args.len > 0) args[0] else .undefined, true));
    _ = g.requests.orderedRemove(0);
    try agDrainDone(vm, g);
    return .undefined;
}

/// AsyncGeneratorAwaitReturn rejected: the await threw → reject the front request.
fn agReturnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    if (g.requests.items.len == 0) return .undefined;
    const front = g.requests.items[0].result;
    try promise.reject(vm, @ptrCast(@alignCast(front.promise.?)), if (args.len > 0) args[0] else .undefined);
    _ = g.requests.orderedRemove(0);
    try agDrainDone(vm, g);
    return .undefined;
}

fn agOnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try agStep(vm, g, .send, if (args.len > 0) args[0] else .undefined);
    return .undefined;
}

fn agOnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try agStep(vm, g, .throw_, if (args.len > 0) args[0] else .undefined);
    return .undefined;
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
        .in_op => .in_op,
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
    // A named function expression binds its own name as an immutable binding in
    // a fresh scope enclosing the body, so the body can recurse via that name and
    // can't rebind it. `runFunction` installs `func.closure` as `vm.env` for the
    // call, so the body's free-variable lookups resolve the self name here.
    const closure_env = if (tmpl.self_name.len > 0) blk: {
        const fenv = try vm.arena.create(interp.Environment);
        fenv.* = .{ .arena = vm.arena, .parent = vm.env };
        break :blk fenv;
    } else vm.env;
    func.* = .{
        .params = tmpl.params,
        .body = tmpl.body,
        .is_expr_body = tmpl.is_expr_body,
        .closure = closure_env,
        .name = tmpl.name,
        .source = tmpl.source,
        .chunk = tmpl.chunk,
        .frame = frame,
        .local_count = tmpl.local_count,
    };
    const obj = try vm.arena.create(value.Object);
    obj.* = .{ .js_func = @ptrCast(func), .proto = vm.functionProto() };
    try interp.installFunctionProps(vm.arena, vm.root_shape, obj, tmpl.params, tmpl.name);
    if (tmpl.self_name.len > 0) try closure_env.putFnName(tmpl.self_name, .{ .object = obj });
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

/// `recv.name(args)` — mirrors the tree-walker's `callMethod`: a real (possibly
/// user-overridden) method property on the receiver/prototype chain wins over the
/// engine's native fast-path, which remains the implementation of the unshadowed
/// intrinsics and the fallback for synthesized-only method names.
fn invokeMethod(vm: *Interpreter, recv: Value, name: []const u8, args: []const Value) EvalError!Value {
    const method = try vm.getProperty(recv, name);
    if (method == .object and method.object.isCallableObject())
        return callValue(vm, method, args, recv);
    if (try vm.builtinMethod(recv, name, args)) |r| return r;
    return callValue(vm, method, args, recv);
}

/// `new callee(args)`. A VM-compiled constructor runs on the VM with a fresh
/// `this` (tagged for `instanceof`); error constructors and tree-walk functions
/// are delegated to the interpreter.
fn construct(vm: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
    if (callee == .object) {
        if (callee.object.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            if (func.chunk) |fchunk| {
                const this_val = try vm.newInstance(callee.object);
                const ret = try runFunction(vm, func, fchunk, args, this_val);
                return if (ret == .object) ret else this_val;
            }
        }
    }
    return vm.construct(callee, args);
}

fn runFunction(vm: *Interpreter, func: *Function, fchunk: *Chunk, args: []const Value, this_val: Value) EvalError!Value {
    if (vm.depth >= interp.max_call_depth) return vm.throwError("RangeError", "Maximum call stack size exceeded");
    vm.depth += 1;
    defer vm.depth -= 1;

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
    const saved_strict = vm.strict;
    const saved_env = vm.env;
    vm.strict = func.is_strict;
    // Free variables (globals, and a named function expression's self name)
    // resolve through `vm.env`; install the closure's defining environment so a
    // named function expression's own immutable binding is visible in its body.
    // For ordinary functions `func.closure` is the global env (unchanged).
    vm.env = func.closure;
    // Sloppy-mode this-substitution (matches the tree-walker): a non-strict,
    // non-arrow function called with null/undefined `this` sees the global object.
    vm.this_value = if (!func.is_strict and !func.is_arrow and (this_val == .null or this_val == .undefined))
        (if (vm.global_object) |g| Value{ .object = g } else this_val)
    else
        this_val;
    defer {
        vm.this_value = saved_this;
        vm.strict = saved_strict;
        vm.env = saved_env;
    }
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
    var env = Environment{ .arena = arena, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(arena);
    try interp.installGlobals(&env, root_shape);
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
