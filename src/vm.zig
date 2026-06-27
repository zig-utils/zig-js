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
const gc_mod = @import("gc.zig");
const bc = @import("bytecode.zig");
const value = @import("value.zig");
const interp = @import("interpreter.zig");
const promise = @import("promise.zig");
const agent = @import("agent.zig");

const Value = value.Value;
const Chunk = bc.Chunk;
const Interpreter = interp.Interpreter;
const Environment = interp.Environment;
const Function = interp.Function;
const EvalError = interp.EvalError;

fn bindThisForCall(vm: *Interpreter, func: *Function, this_val: Value) EvalError!Value {
    if (func.is_arrow) return func.arrow_this;
    if (func.is_strict) return this_val;
    if (this_val.isNull() or this_val.isUndefined()) {
        if (vm.env.get("globalThis")) |gt| if (gt.isObject()) return gt;
        return if (vm.global_object) |g| Value.obj(g) else this_val;
    }
    if (!this_val.isObject() or this_val.asObj().is_symbol or this_val.asObj().is_bigint)
        return Value.obj(try vm.toObject(this_val));
    return this_val;
}

/// A function activation's flat local store. `slots` holds parameters then
/// function-scoped declarations (indexes assigned by the compiler); `parent` is
/// the *defining* function's frame, walked to resolve upvalues. Heap-allocated
/// so a closure can outlive the call that created it. Globals live in the
/// Environment, not here.
pub const Frame = struct {
    slots: []Value,
    parent: ?*Frame,
    // A closure shared across threads resolves its upvalues to one defining
    // frame, so concurrent load_upval/store_upval read+write the same slot —
    // serialize them here (the binding_lock analogue for VM frames). Gated on
    // the parallel flag, so the default engine takes no lock.
    upval_lock: std.atomic.Mutex = .unlocked,

    fn lockUpval(self: *Frame) void {
        if (!bc.ic_seqlock_enabled.load(.acquire)) return;
        var spins: usize = 0;
        while (!self.upval_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }
    fn unlockUpval(self: *Frame) void {
        if (!bc.ic_seqlock_enabled.load(.acquire)) return;
        self.upval_lock.unlock();
    }
};

/// A resumable execution state: the operand stack, completion accumulator, and
/// instruction pointer. For a normal call this lives on the host stack and is
/// thrown away when `run` returns; for a generator it lives in the `Generator`
/// and persists across `yield`/resume, which is what makes suspension faithful
/// (the whole operand stack is saved, so a `yield` can sit mid-expression).
pub const Exec = struct {
    stack: std.ArrayListUnmanaged(Value) = .empty,
    acc: Value = Value.undef(),
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
fn unwindToFinally(vm: *Interpreter, gen: ?*Generator, exec: *Exec, cval: Value, kind: Completion) !?u32 {
    const stack_alloc = generatorStackAllocator(vm, gen);
    while (exec.handlers.items.len > 0) {
        const h = exec.handlers.pop().?;
        if (h.finally_pc != Handler.none) {
            exec.stack.shrinkRetainingCapacity(h.stack_depth);
            try exec.stack.append(stack_alloc, cval);
            try exec.stack.append(stack_alloc, Value.num(@floatFromInt(@intFromEnum(kind))));
            return h.finally_pc;
        }
    }
    return null;
}

/// A suspended `function*` activation: its compiled body, persistent execution
/// state, and the `Environment` its body resolves names against (a child of the
/// closure, holding the params/locals across yields). Driven by `genNext`.
pub const Generator = struct {
    pub const BackingFlags = packed struct {
        stack: bool = false,
        handlers: bool = false,
        requests: bool = false,
    };

    backing_allocator: ?std.mem.Allocator = null,
    backing_stores_live: ?*usize = null,
    backing_flags: BackingFlags = .{},
    // `backingFor` is reached from both the request path (`requests_mutex`) and
    // the resume path (`resume_mutex`); under `parallel_js` an enqueue on one
    // thread races a resume on another on the packed `backing_flags` byte. Its
    // own lock serializes the lazy flag-set (rare — once per backing kind).
    backing_lock: std.atomic.Mutex = .unlocked,
    chunk: *Chunk,
    exec: Exec = .{},
    env: *Environment,
    this_value: Value = Value.undef(),
    home_object: ?*value.Object = null,
    super_ctor: ?*value.Object = null,
    started: bool = false,
    done: bool = false,
    suspended: bool = false,
    resume_mutex: std.Io.Mutex = .init,
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
    requests_mutex: std.Io.Mutex = .init,
    requests: std.ArrayListUnmanaged(AsyncGenRequest) = .empty,
    pumping: bool = false,

    fn backingFor(self: *Generator, fallback: std.mem.Allocator, comptime field: []const u8) std.mem.Allocator {
        const a = self.backing_allocator orelse return fallback;
        var spins: usize = 0;
        while (!self.backing_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        defer self.backing_lock.unlock();
        if (!@field(self.backing_flags, field)) {
            @field(self.backing_flags, field) = true;
            if (self.backing_stores_live) |live| _ = @atomicRmw(usize, live, .Add, 1, .monotonic);
        }
        return a;
    }

    pub fn stackAllocator(self: *Generator, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "stack");
    }

    pub fn handlersAllocator(self: *Generator, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "handlers");
    }

    pub fn requestsAllocator(self: *Generator, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.backingFor(fallback, "requests");
    }
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
    // ToPropertyKey: an object key is first ToPrimitive(key, string) — running its
    // `[Symbol.toPrimitive]`/`toString`/`valueOf` — and a Symbol key is registered
    // so it round-trips through getOwnPropertySymbols/proxy traps. Shared with the
    // tree-walker so a computed `{[obj]: …}` / `o[obj]` coerces identically.
    return vm.keyOf(key);
}

fn generatorStackAllocator(vm: *Interpreter, gen: ?*Generator) std.mem.Allocator {
    return if (gen) |g| g.stackAllocator(vm.arena) else vm.arena;
}

fn generatorHandlersAllocator(vm: *Interpreter, gen: ?*Generator) std.mem.Allocator {
    return if (gen) |g| g.handlersAllocator(vm.arena) else vm.arena;
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
    // Register this operand stack as a precise GC root while it runs, so a
    // mid-script collection at a step checkpoint traces its live `Value`s (the
    // operand stack is arena-backed, invisible to the conservative native-stack
    // scan). No-op when the GC is off.
    vm.pushExecRoot(exec);
    defer vm.popExecRoot(exec);
    // Run the instruction stream; if a throw escapes and an active handler can
    // catch it, unwind to that handler's catch block and resume. Otherwise the
    // throw propagates to the caller (uncaught — the generator/function ends).
    while (true) {
        return runChunk(vm, exec, chunk, frame, gen) catch |e| {
            if (e == error.Throw and exec.handlers.items.len > 0) {
                const stack_alloc = generatorStackAllocator(vm, gen);
                const h = exec.handlers.pop().?;
                exec.stack.shrinkRetainingCapacity(h.stack_depth);
                if (h.catch_pc != Handler.none) {
                    try exec.stack.append(stack_alloc, vm.exception); // bind target for the catch
                    exec.ip = h.catch_pc;
                } else {
                    // No catch: run the finally carrying a "throw" completion,
                    // which `end_finally` re-throws once the finally completes.
                    try exec.stack.append(stack_alloc, vm.exception);
                    try exec.stack.append(stack_alloc, Value.num(@floatFromInt(@intFromEnum(Completion.throw))));
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
    const stack_alloc = generatorStackAllocator(vm, gen);
    const handlers_alloc = generatorHandlersAllocator(vm, gen);
    var acc: Value = exec.acc;
    var ip: usize = exec.ip;
    const code = chunk.code.items;

    while (ip < code.len) {
        vm.steps += 1;
        if (vm.steps > interp.max_steps) return vm.throwError("RangeError", "evaluation step budget exceeded");
        if ((vm.steps & 1023) == 0) {
            if (vm.stop_flag) |sf| if (sf.load(.monotonic))
                return vm.throwError("Error", "worker terminated");
            if (vm.use_thread_gil) if (vm.gil) |g| g.yieldIfContended();
            // Mid-script GC: flush the live accumulator/ip into `exec` so the
            // precise tracer (which roots `exec.stack`/`exec.acc`) sees the
            // current operand state, then run a guarded collection. No-op when
            // the GC is off (`gc_safepoint_fn == null`).
            if (vm.gc_safepoint_fn != null) {
                exec.acc = acc;
                exec.ip = ip;
                vm.serviceGcSafepoint();
            }
        }
        const inst = code[ip];
        ip += 1;
        switch (inst.op) {
            .load_const => try stack.append(stack_alloc, chunk.consts.items[inst.a]),
            .load_bigint => try stack.append(stack_alloc, try vm.makeBigIntText(chunk.names.items[inst.a])),
            .load_undefined => try stack.append(stack_alloc, Value.undef()),
            .load_null => try stack.append(stack_alloc, Value.nul()),
            .load_true => try stack.append(stack_alloc, Value.boolVal(true)),
            .load_false => try stack.append(stack_alloc, Value.boolVal(false)),
            .pop => _ = stack.pop(),
            .dup => try stack.append(stack_alloc, stack.items[stack.items.len - 1]),
            .set_acc => acc = stack.pop().?,

            .load_var => {
                // `lookupIdent` is `env.get` plus `with`-object resolution (honoring
                // `Symbol.unscopables`); identical to `env.get` when no `with` is on
                // the chain, so this is a no-op for ordinary generator/async bodies.
                const name = chunk.names.items[inst.a];
                const v = (try vm.lookupIdent(name)) orelse (try vm.globalProp(name)) orelse return vm.throwError("ReferenceError", name);
                try stack.append(stack_alloc, v);
            },
            .load_var_or_undef => {
                const name = chunk.names.items[inst.a];
                try stack.append(stack_alloc, (try vm.lookupIdent(name)) orelse (try vm.globalProp(name)) orelse Value.undef());
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

            .load_local => try stack.append(stack_alloc, frame.?.slots[inst.a]),
            .store_local => frame.?.slots[inst.a] = stack.items[stack.items.len - 1], // leaves value
            .load_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                f.lockUpval();
                const v = f.slots[inst.b];
                f.unlockUpval();
                try stack.append(stack_alloc, v);
            },
            .store_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                const v = stack.items[stack.items.len - 1]; // leaves value on the stack
                f.lockUpval();
                f.slots[inst.b] = v;
                f.unlockUpval();
            },

            .neg => {
                const v = try vm.toNumericPrimitive(stack.pop().?);
                if (v.isObject() and v.asObj().is_bigint)
                    try stack.append(stack_alloc, try interp.negateBigIntObject(vm, v.asObj()))
                else
                    try stack.append(stack_alloc, Value.num(-(try vm.toNumberV(v))));
            },
            .pos => {
                const v = try vm.toNumericPrimitive(stack.pop().?);
                if (v.isObject() and v.asObj().is_bigint)
                    return vm.throwError("TypeError", "Cannot convert a BigInt value to a number");
                try stack.append(stack_alloc, Value.num(try vm.toNumberV(v)));
            },
            .not => {
                const v = stack.pop().?;
                try stack.append(stack_alloc, Value.boolVal(!v.toBoolean()));
            },
            .typeof_op => {
                const v = stack.pop().?;
                try stack.append(stack_alloc, Value.str(v.typeOf()));
            },
            .bit_not => {
                const v = try vm.toNumericPrimitive(stack.pop().?);
                if (v.isObject() and v.asObj().is_bigint)
                    try stack.append(stack_alloc, try interp.bitNotBigIntObject(vm, v.asObj()))
                else
                    try stack.append(stack_alloc, Value.num(@floatFromInt(~Value.num(try vm.toNumberV(v)).toInt32())));
            },
            .void_op => {
                _ = stack.pop().?;
                try stack.append(stack_alloc, Value.undef());
            },
            .to_string => {
                const v = stack.pop().?;
                try stack.append(stack_alloc, Value.str(try vm.toStringV(v)));
            },

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict, .in_op, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => {
                const r = stack.pop().?;
                const l = stack.pop().?;
                try stack.append(stack_alloc, try vm.applyBinary(binOp(inst.op), l, r));
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

            .load_this => try stack.append(stack_alloc, vm.this_value),
            .new_object => try stack.append(stack_alloc, try vm.newObject()),
            .new_array => try stack.append(stack_alloc, try vm.newArray()),
            .init_prop => {
                const v = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                // Object-literal property init is CreateDataPropertyOrThrow — a
                // direct own data property, NOT [[Set]] (so an own `__proto__`
                // shorthand/method/computed key does not trip the prototype setter).
                try vm.setProp(obj.asObj(), chunk.names.items[inst.a], v);
            },
            .init_proto => {
                const v = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                // Only an Object or null sets [[Prototype]]; a Symbol/BigInt (also
                // object-tagged) or any other value is discarded.
                if (v.isObject() and !v.asObj().is_symbol and !v.asObj().is_bigint)
                    obj.asObj().proto = v.asObj()
                else if (v.isNull()) obj.asObj().proto = null;
            },
            .init_prop_computed => {
                const key = stack.pop().?;
                const v = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                try vm.setProp(obj.asObj(), try propKey(vm, key), v); // CreateDataProperty (a computed `__proto__` is a normal own prop)
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
                try arr.asObj().elements.append(arr.asObj().elementsAllocator(vm.arena), v);
            },
            .array_append_hole => {
                // An array-literal elision: a slot that reads as absent (skipped by
                // iteration, `in`, etc.) but counts toward length.
                const arr = stack.items[stack.items.len - 1].asObj();
                try arr.markHole(vm.arena, arr.elements.items.len);
                try arr.elements.append(arr.elementsAllocator(vm.arena), Value.undef());
            },
            .get_prop => {
                const obj = stack.pop().?;
                const name = chunk.names.items[inst.a];
                var result: Value = undefined;
                fast: {
                    // Inline cache: plain (non-array) objects with a shape and
                    // no accessor/attribute overrides (those need the full
                    // [[Get]] path: getters + the prototype walk).
                    if (obj.isObject()) {
                        const o = obj.asObj();
                        o.lockProperties();
                        defer o.unlockProperties();
                        if (!o.is_array and o.accessors == null and o.attrs == null) {
                            const ic = &chunk.ics[ip - 1];
                            if (ic.lookupSlot(o.shape)) |sl| {
                                result = o.slots.items[sl];
                                break :fast;
                            }
                            if (o.shape) |sh| {
                                if (sh.lookup(name)) |slot| {
                                    ic.record(sh, slot);
                                    result = o.slots.items[slot];
                                    break :fast;
                                }
                            }
                        }
                        // own miss → fall through to full [[Get]] (prototype walk
                        // + `.constructor` fallback), not a bare undefined.
                    }
                    result = try vm.getProperty(obj, name); // arrays, strings, proto chain, null/undefined
                }
                try stack.append(stack_alloc, result);
            },
            .get_index => {
                const key = stack.pop().?;
                const obj = stack.pop().?;
                try stack.append(stack_alloc, try vm.getProperty(obj, try propKey(vm, key)));
            },
            .super_get => {
                // `super.name`: GetSuperBase = home_object.[[Prototype]]; read with
                // the current `this` as receiver (so an inherited getter sees it).
                const home = vm.home_object orelse return vm.throwError("SyntaxError", "'super' outside a method");
                const parent = home.proto orelse return vm.throwError("TypeError", "Cannot read property of null (super)");
                const name = chunk.names.items[inst.a];
                try stack.append(stack_alloc, try vm.getPropertyWithReceiver(Value.obj(parent), name, vm.this_value));
            },
            .super_get_index => {
                const key = stack.pop().?;
                const home = vm.home_object orelse return vm.throwError("SyntaxError", "'super' outside a method");
                const parent = home.proto orelse return vm.throwError("TypeError", "Cannot read property of null (super)");
                try stack.append(stack_alloc, try vm.getPropertyWithReceiver(Value.obj(parent), try propKey(vm, key), vm.this_value));
            },
            .enter_with => {
                // `with (obj)`: push an object Environment Record. ToObject(obj)
                // boxes a primitive; null/undefined throw (only those, not every
                // non-object). `vm.env` is restored by `exit_with` at block end.
                const obj = try vm.toObject(stack.pop().?);
                const wenv = try gc_mod.allocEnv(vm.arena);
                vm.initEnvironment(wenv, vm.env, false);
                wenv.with_object = obj;
                vm.env = wenv;
            },
            .exit_with => vm.env = vm.env.parent.?,
            .make_regex => {
                // A regex literal is a fresh RegExp object on each evaluation.
                const pattern = chunk.names.items[inst.a];
                const flags = chunk.names.items[inst.b];
                try stack.append(stack_alloc, try vm.makeRegex(pattern, flags));
            },
            .register_disposable => {
                // `using x = v;` / `await using x = v;` — register `v` for disposal
                // at the end of the current variable scope (run by the body-exit
                // DisposeResources pass). `a == 1` selects [Symbol.asyncDispose].
                try vm.addDisposable(stack.pop().?, inst.a == 1);
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
                    if (obj.isObject()) {
                        const o = obj.asObj();
                        o.lockProperties();
                        defer o.unlockProperties();
                        if (!o.is_array and o.accessors == null and o.attrs == null) {
                            const ic = &chunk.ics[ip - 1];
                            if (ic.lookupSlot(o.shape)) |sl| {
                                gc_mod.barrierValue(v); // IC fast-path slot store
                                o.slots.items[sl] = v;
                                break :fast;
                            }
                            if (o.shape) |sh| {
                                if (sh.lookup(name)) |slot| {
                                    ic.record(sh, slot);
                                    gc_mod.barrierValue(v); // IC fast-path slot store
                                    o.slots.items[slot] = v;
                                    break :fast;
                                }
                            }
                        }
                    }
                    try vm.setMember(obj, name, v);
                }
                try stack.append(stack_alloc, v); // assignment yields the value
            },
            .set_index => {
                const v = stack.pop().?;
                const key = stack.pop().?;
                const obj = stack.pop().?;
                try vm.setMember(obj, try propKey(vm, key), v);
                try stack.append(stack_alloc, v);
            },
            .instance_of => {
                const r = stack.pop().?;
                const l = stack.pop().?;
                try stack.append(stack_alloc, Value.boolVal(try vm.instanceOf(l, r)));
            },

            .make_closure => try stack.append(stack_alloc, try makeClosure(vm, chunk.fns.items[inst.a], frame)),
            .call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                const result = try callValue(vm, callee, stack.items[base..], Value.undef());
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(stack_alloc, result);
            },
            .call_eval => {
                // A bare `eval(args)` call: mark it a DIRECT eval so, if the callee
                // is the eval intrinsic, the eval'd code runs in this body's scope
                // (sees its `let`/`var`/private names). Ignored if `eval` was shadowed.
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                const saved = vm.direct_eval_call;
                vm.direct_eval_call = true;
                const result = callValue(vm, callee, stack.items[base..], Value.undef()) catch |e| {
                    vm.direct_eval_call = saved;
                    return e;
                };
                vm.direct_eval_call = saved;
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(stack_alloc, result);
            },
            .call_method => {
                const argc = inst.b;
                const base = stack.items.len - argc;
                const recv = stack.items[base - 1];
                const args = stack.items[base..];
                const name = chunk.names.items[inst.a];
                const result = try invokeMethod(vm, recv, name, args);
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(stack_alloc, result);
            },
            .new_call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                const result = try construct(vm, callee, stack.items[base..]);
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(stack_alloc, result);
            },
            .call_spread => {
                const args_arr = stack.pop().?;
                const callee = stack.pop().?;
                try stack.append(stack_alloc, try callValue(vm, callee, args_arr.asObj().elements.items, Value.undef()));
            },
            .call_method_spread => {
                const args_arr = stack.pop().?;
                const recv = stack.pop().?;
                const name = chunk.names.items[inst.a];
                const args = args_arr.asObj().elements.items;
                const result = try invokeMethod(vm, recv, name, args);
                try stack.append(stack_alloc, result);
            },
            .new_spread => {
                const args_arr = stack.pop().?;
                const callee = stack.pop().?;
                try stack.append(stack_alloc, try construct(vm, callee, args_arr.asObj().elements.items));
            },

            .ret => return stack.pop().?,
            .ret_undef => return Value.undef(),
            .abrupt_return => {
                // A return that must run enclosing `finally` blocks first: unwind
                // to the nearest finally carrying a "return" completion (which
                // `end_finally` re-propagates), or return directly if none.
                const rv = stack.pop().?;
                if (try unwindToFinally(vm, gen, exec, rv, .ret)) |fpc| ip = fpc else return rv;
            },
            .abrupt_break, .abrupt_continue => {
                // A break/continue that crosses a `finally`: run the enclosing
                // finally(s) first, then jump to the (patched) loop target. The
                // target PC rides through as the completion value.
                const kind: Completion = if (inst.op == .abrupt_break) .break_ else .continue_;
                const target: Value = Value.num(@floatFromInt(inst.a));
                if (try unwindToFinally(vm, gen, exec, target, kind)) |fpc| ip = fpc else ip = inst.a;
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
                try stack.append(stack_alloc, res);
            },
            .assert_iter_result => {
                // Type(result) must be Object — a Symbol/BigInt is object-tagged here
                // but is not an Object.
                const r = stack.items[stack.items.len - 1];
                if (!r.isObject() or r.asObj().is_symbol or r.asObj().is_bigint)
                    return vm.throwError("TypeError", "iterator result is not an object");
            },
            .iter_of => {
                const v = stack.pop().?;
                try stack.append(stack_alloc, try vm.iteratorOf(v));
            },
            .async_iter_of => {
                const v = stack.pop().?;
                try stack.append(stack_alloc, try vm.asyncIteratorOf(v));
            },
            .enum_keys => {
                const v = stack.pop().?;
                try stack.append(stack_alloc, try vm.forInKeysArray(v));
            },
            .iter_close => {
                const it = stack.pop().?;
                try vm.iteratorClose(it);
            },
            .array_spread => {
                const iterable = stack.pop().?;
                // The array stays on the stack (peeked); append the iterable's
                // elements into it.
                try vm.spreadInto(&stack.items[stack.items.len - 1].asObj().elements, iterable);
            },
            .throw_op => {
                vm.exception = stack.pop().?;
                return error.Throw;
            },
            .push_handler => try exec.handlers.append(handlers_alloc, .{
                .catch_pc = inst.a,
                .finally_pc = inst.b,
                .stack_depth = @intCast(stack.items.len),
            }),
            .pop_handler => _ = exec.handlers.pop(),
            .push_completion => {
                // [value, kind] — value is undefined for a normal completion.
                try stack.append(stack_alloc, Value.undef());
                try stack.append(stack_alloc, Value.num(@floatFromInt(inst.a)));
            },
            .end_finally => {
                const kind: Completion = @enumFromInt(@as(u8, @intFromFloat(stack.pop().?.asNum())));
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
                        if (try unwindToFinally(vm, gen, exec, cval, .ret)) |fpc| ip = fpc else return cval;
                    },
                    .break_, .continue_ => {
                        if (try unwindToFinally(vm, gen, exec, cval, kind)) |fpc| ip = fpc else ip = @intFromFloat(cval.asNum());
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
    try vm.setMember(o, "done", Value.boolVal(done));
    return o;
}

/// A function body's lexical Environment Record, distinct from its variable
/// environment `var_env` (FunctionDeclarationInstantiation steps 30–32 / 34): the
/// body's `let`/`const` live here, so they don't collide with `var`s in `var_env`
/// and a direct `eval`'s `var` can detect a conflict (`{ let x; eval('var x') }` is
/// a SyntaxError). A child block scope (not a variable scope), so `var` still hoists
/// out to `var_env`.
fn bodyLexicalEnv(vm: *Interpreter, var_env: *Environment) EvalError!*Environment {
    const le = try gc_mod.allocEnv(vm.arena);
    vm.initEnvironment(le, var_env, false);
    return le;
}

/// FunctionDeclarationInstantiation step 27: when the formals contain a parameter
/// expression (a default value), the body gets a variable environment distinct
/// from the parameter environment `param_env`, so a closure created in the
/// parameter list cannot see the body's `var`s. Returns `param_env` unchanged when
/// there is no default. The caller must have `vm.env == param_env` on entry; on
/// return `vm.env` is the chosen body env (the caller restores it via its defer).
fn paramsBodyVarEnv(vm: *Interpreter, func: *Function, param_env: *Environment) EvalError!*Environment {
    if (func.body.* != .block) return param_env;
    var has_param_expr = false;
    for (func.params) |p| if (p.default != null) {
        has_param_expr = true;
        break;
    };
    if (!has_param_expr) {
        // Params and body share one env; hoist the body's `var` names into it so a
        // reference before the declaration (e.g. inside a `with`) resolves to the
        // local binding (undefined) rather than falling through to an outer scope.
        try vm.hoistVarNames(func.body.block);
        return param_env;
    }
    const be = try gc_mod.allocEnv(vm.arena);
    vm.initEnvironment(be, param_env, true);
    vm.env = be;
    try vm.hoistVarNames(func.body.block);
    // A body `var` that names a simple parameter inherits the parameter's value.
    for (func.params) |p| {
        if (p.pattern == null and !p.is_rest and be.vars.contains(p.name)) {
            if (param_env.get(p.name)) |pv| try be.put(p.name, pv);
        }
    }
    return be;
}

/// Build the generator object produced by calling a `function*`. The body is
/// not run yet; it runs lazily on the first `.next()`.
pub fn makeGenerator(vm: *Interpreter, func: *Function, args: []const Value, this_val: Value) EvalError!Value {
    const chunk = func.gen_chunk orelse
        return vm.throwError("TypeError", "generator body uses syntax not yet supported by the VM");

    // The generator's scope: a child of the closure, so free variables resolve
    // outward while params/locals live here and persist across yields.
    const genv = try gc_mod.allocEnv(vm.arena);
    vm.initEnvironment(genv, func.closure, true);

    const args_obj = try vm.newArray(); // generators are never arrow functions
    for (args) |av| try args_obj.asObj().elements.append(args_obj.asObj().elementsAllocator(vm.arena), av);
    try genv.put("arguments", args_obj);

    // Bind params into the generator's environment (handles default/rest/
    // destructuring). `bindParams` binds into `vm.env`, so point it at `genv`
    // for the duration — defaults are evaluated now, at generator creation,
    // per spec. Restore the caller's env afterward.
    const saved_env = vm.env;
    vm.env = genv;
    defer vm.env = saved_env;
    try vm.bindParams2(func.params, args, func.is_arrow);
    const bound_this = try bindThisForCall(vm, func, this_val);

    // A generator whose parameter list contains an expression (a default value)
    // gets a body variable environment distinct from the parameter environment, so
    // a closure created in the parameter list can't see the body's `var`s (and
    // vice-versa). Body `var`s hoist into `body_env`; a body `var` naming a simple
    // parameter inherits that parameter's bound value. Mirrors `callPlain`. With no
    // default, params and body share `genv`.
    const body_env = try paramsBodyVarEnv(vm, func, genv);
    const lexical_env = try bodyLexicalEnv(vm, body_env);

    const g = try gc_mod.allocGenerator(vm.arena);
    g.* = .{
        .chunk = chunk,
        .env = lexical_env,
        .this_value = bound_this,
        .home_object = func.home_object,
        .super_ctor = func.super_ctor,
    };
    gc_mod.initGeneratorBacking(g);
    const obj = try gc_mod.allocObj(vm.arena);
    obj.* = .{ .gen = @ptrCast(g) };
    // The instance's [[Prototype]] is the generator function's own `.prototype`
    // object (whose own [[Prototype]] is %GeneratorPrototype%), per
    // OrdinaryCreateFromConstructor. Falls back to %GeneratorPrototype% directly
    // if `.prototype` was reassigned to a non-object. Either way `.next()` keeps
    // using the callMethod fast path.
    set_proto: {
        if (func.obj) |fobj| {
            const fp = try vm.getProperty(Value.obj(fobj), "prototype");
            // GetPrototypeFromConstructor: only an *Object* `.prototype` is used;
            // a Symbol/BigInt (object-tagged here) is "not Object" and falls back.
            if (fp.isObject() and !fp.asObj().is_symbol and !fp.asObj().is_bigint) {
                obj.proto = fp.asObj();
                break :set_proto;
            }
        }
        if (vm.env.get("\x00GenProto")) |p| if (p.isObject()) {
            obj.proto = p.asObj();
        };
    }
    return Value.obj(obj);
}

/// How a generator is being resumed: a normal `.next(v)`, a `.throw(e)` that
/// injects an exception at the suspend point, or a `.return(v)` that completes it.
const ResumeKind = enum { send, throw_, return_ };

/// The numeric tag a delegation resume (`gen_yield_star`) pushes alongside the
/// resume value, so the desugared `yield*` loop can branch on how it was resumed:
/// 0 = `.next(v)`, 1 = `.throw(e)`, 2 = `.return(v)`.
fn resumeKindNum(kind: ResumeKind) Value {
    return Value.num(switch (kind) {
        .send => 0,
        .throw_ => 1,
        .return_ => 2,
    });
}

/// Shared driver for `.next`/`.throw`/`.return`. Restores the generator's
/// context, applies the resume action at the suspend point, runs the VM to the
/// next `yield` (or completion), then restores the caller's context.
fn genResume(vm: *Interpreter, gen_obj: *value.Object, kind: ResumeKind, val: Value) EvalError!Value {
    const g: *Generator = @ptrCast(@alignCast(gen_obj.gen.?));
    if (!g.resume_mutex.tryLock()) return vm.throwError("TypeError", "generator is already running");
    defer g.resume_mutex.unlock(agent.engineIo());
    if (g.running) return vm.throwError("TypeError", "generator is already running");

    // A completed (or not-yet-started) generator handles each kind without
    // re-entering the body.
    if (g.done) return switch (kind) {
        .send => makeIterResult(vm, Value.undef(), true),
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
        try g.exec.stack.append(g.stackAllocator(vm.arena), val);
        try g.exec.stack.append(g.stackAllocator(vm.arena), resumeKindNum(kind));
    } else {
        // Suspended at a `yield`: apply the resume action.
        switch (kind) {
            .send => try g.exec.stack.append(g.stackAllocator(vm.arena), val), // becomes the yield's value
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
                    try g.exec.stack.append(g.stackAllocator(vm.arena), val); // completion value
                    try g.exec.stack.append(g.stackAllocator(vm.arena), Value.num(@floatFromInt(@intFromEnum(Completion.ret))));
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
        // DisposeResources for the body's `using` resources, threading the thrown value.
        if (e == error.Throw and g.env.disposables.items.len > 0) {
            const body_err = vm.exception;
            if (vm.disposeScope(g.env, body_err) catch null) |de| vm.exception = de;
        }
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
    // DisposeResources for the body's top-level `using` resources at generator end.
    if (g.env.disposables.items.len > 0) {
        if (try vm.disposeScope(g.env, null)) |de| {
            vm.exception = de;
            return error.Throw;
        }
    }
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
        try g.exec.stack.append(g.stackAllocator(vm.arena), e); // catch binding
        g.exec.ip = h.catch_pc;
    } else {
        try g.exec.stack.append(g.stackAllocator(vm.arena), e); // finally completion value
        try g.exec.stack.append(g.stackAllocator(vm.arena), Value.num(@floatFromInt(@intFromEnum(Completion.throw))));
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
    const genv = try gc_mod.allocEnv(vm.arena);
    vm.initEnvironment(genv, func.closure, true);
    const args_obj = try vm.newArray();
    for (args) |av| try args_obj.asObj().elements.append(args_obj.asObj().elementsAllocator(vm.arena), av);
    try genv.put("arguments", args_obj);
    const saved_env = vm.env;
    vm.env = genv;
    defer vm.env = saved_env;
    // An error thrown synchronously while evaluating parameter defaults (or
    // binding `this`) of an async function must settle the result promise as a
    // rejection, not propagate out of the call.
    const result = try promise.newPromise(vm);
    const rp: *promise.Promise = @ptrCast(@alignCast(result.promise.?));
    vm.bindParams2(func.params, args, func.is_arrow) catch |err| {
        if (err != error.Throw) return err;
        const reason = vm.exception;
        vm.exception = Value.undef();
        try promise.reject(vm, rp, reason);
        return Value.obj(result);
    };
    const bound_this = bindThisForCall(vm, func, this_val) catch |err| {
        if (err != error.Throw) return err;
        const reason = vm.exception;
        vm.exception = Value.undef();
        try promise.reject(vm, rp, reason);
        return Value.obj(result);
    };
    // Separate body var-env + body-var hoisting (see makeGenerator); without the
    // hoist a `with` in the body resolves a not-yet-declared `var` to an outer scope.
    const body_env = try paramsBodyVarEnv(vm, func, genv);
    const lexical_env = try bodyLexicalEnv(vm, body_env);

    const g = try gc_mod.allocGenerator(vm.arena);
    g.* = .{
        .chunk = chunk,
        .env = lexical_env,
        .this_value = bound_this,
        .home_object = func.home_object,
        .super_ctor = func.super_ctor,
        .is_async = true,
        .result = result,
    };
    gc_mod.initGeneratorBacking(g);
    try asyncDrive(vm, g, .send, Value.undef());
    return Value.obj(g.result.?);
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
            .send => try g.exec.stack.append(g.stackAllocator(vm.arena), val), // the awaited value
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
        var reason = vm.exception;
        vm.exception = Value.undef();
        // DisposeResources for the body's `using` resources, threading the error.
        if (g.env.disposables.items.len > 0) {
            if (vm.disposeScope(g.env, reason) catch null) |de| reason = de;
        }
        try promise.reject(vm, resultPromise(g), reason);
        return;
    };
    if (g.suspended) {
        // `await v`: resume when `Promise.resolve(v)` settles.
        g.suspended = false;
        const awaited = try promise.newPromise(vm);
        try promise.resolve(vm, @ptrCast(@alignCast(awaited.promise.?)), v);
        const onf = try gc_mod.allocObj(vm.arena);
        onf.* = .{ .native = asyncOnFulfill, .private_data = @ptrCast(g) };
        const onr = try gc_mod.allocObj(vm.arena);
        onr.* = .{ .native = asyncOnReject, .private_data = @ptrCast(g) };
        _ = try promise.then(vm, @ptrCast(@alignCast(awaited.promise.?)), Value.obj(onf), Value.obj(onr));
        return;
    }
    g.done = true;
    // DisposeResources for the body's top-level `using` resources at completion.
    if (g.env.disposables.items.len > 0) {
        if (vm.disposeScope(g.env, null) catch null) |de| {
            try promise.reject(vm, resultPromise(g), de);
            return;
        }
    }
    try promise.resolve(vm, resultPromise(g), v);
}

fn asyncOnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try asyncDrive(vm, g, .send, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

fn asyncOnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try asyncDrive(vm, g, .throw_, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
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
    const genv = try gc_mod.allocEnv(vm.arena);
    vm.initEnvironment(genv, func.closure, true);
    const args_obj = try vm.newArray();
    for (args) |av| try args_obj.asObj().elements.append(args_obj.asObj().elementsAllocator(vm.arena), av);
    try genv.put("arguments", args_obj);
    const saved_env = vm.env;
    vm.env = genv;
    defer vm.env = saved_env;
    try vm.bindParams2(func.params, args, func.is_arrow);
    const bound_this = try bindThisForCall(vm, func, this_val);
    // Separate body var-env when the params contain a default (see makeGenerator).
    const body_env = try paramsBodyVarEnv(vm, func, genv);
    const lexical_env = try bodyLexicalEnv(vm, body_env);

    const g = try gc_mod.allocGenerator(vm.arena);
    g.* = .{
        .chunk = chunk,
        .env = lexical_env,
        .this_value = bound_this,
        .home_object = func.home_object,
        .super_ctor = func.super_ctor,
        .is_async_gen = true,
    };
    gc_mod.initGeneratorBacking(g);
    const obj = try gc_mod.allocObj(vm.arena);
    obj.* = .{ .gen = @ptrCast(g) };
    // The instance's [[Prototype]] is the async-generator function's own
    // `.prototype` object, whose own [[Prototype]] is %AsyncGeneratorPrototype%
    // (itself chaining to %AsyncIteratorPrototype% for the helper methods), per
    // OrdinaryCreateFromConstructor. Falls back to %AsyncGeneratorPrototype% if
    // `.prototype` was reassigned to a non-object. `next`/`return`/`throw` are
    // still served by the gen special-case in `builtinMethod`.
    set_proto: {
        if (func.obj) |fobj| {
            const fp = try vm.getProperty(Value.obj(fobj), "prototype");
            // GetPrototypeFromConstructor: only an *Object* `.prototype` is used;
            // a Symbol/BigInt (object-tagged here) is "not Object" and falls back.
            if (fp.isObject() and !fp.asObj().is_symbol and !fp.asObj().is_bigint) {
                obj.proto = fp.asObj();
                break :set_proto;
            }
        }
        if (vm.env.get("\x00AsyncGenProto")) |p| if (p.isObject()) {
            obj.proto = p.asObj();
        };
    }
    return Value.obj(obj);
}

/// `asyncGen.next/return/throw(v)` — enqueue a request and return a promise for
/// its `{ value, done }`. Pumping starts if no request is already in flight.
pub fn asyncGenRequest(vm: *Interpreter, gen_obj: *value.Object, kind: ResumeKind, val: Value) EvalError!Value {
    const g: *Generator = @ptrCast(@alignCast(gen_obj.gen.?));
    const rp = try promise.newPromise(vm);
    // Incremental-GC barrier: the request's value + result promise are stored
    // into the live generator cell (which may already be marked).
    gc_mod.barrierValue(val);
    gc_mod.barrierCell(@ptrCast(rp));
    var start_req: ?AsyncGenRequest = null;
    var start_done = false;
    g.requests_mutex.lockUncancelable(agent.engineIo());
    {
        errdefer g.requests_mutex.unlock(agent.engineIo());
        try g.requests.append(g.requestsAllocator(vm.arena), .{ .kind = kind, .value = val, .result = rp });
        if (!g.pumping) {
            g.pumping = true;
            if (g.done)
                start_done = true
            else
                start_req = g.requests.items[0];
        }
    }
    g.requests_mutex.unlock(agent.engineIo());
    // A completed generator never resumes: each new request settles immediately
    // (next/return → `{done:true}`, throw → reject) rather than re-running the
    // body from its final instruction pointer.
    if (start_done)
        try agDrainDone(vm, g)
    else if (start_req) |req|
        try agStep(vm, g, req.kind, req.value);
    return Value.obj(rp);
}

const AgStep = union(enum) { awaited: Value, yielded: Value, returned: Value, threw: Value };

/// Resume the async-generator body once and report why it stopped.
fn agResume(vm: *Interpreter, g: *Generator, kind: ResumeKind, val: Value) EvalError!AgStep {
    if (g.started and g.delegating) {
        // `yield*` delegation point: forward the resume to the inner iterator.
        g.delegating = false;
        try g.exec.stack.append(g.stackAllocator(vm.arena), val);
        try g.exec.stack.append(g.stackAllocator(vm.arena), resumeKindNum(kind));
    } else if (g.started) {
        switch (kind) {
            .send => try g.exec.stack.append(g.stackAllocator(vm.arena), val),
            .throw_ => if (!try injectThrowAt(vm, g, val)) return .{ .threw = val },
            .return_ => {
                // Run an enclosing finally if any; else the generator returns.
                var fin: ?u32 = null;
                var keep_handlers: usize = g.exec.handlers.items.len;
                var stack_depth: u32 = 0;
                var i = g.exec.handlers.items.len;
                while (i > 0) {
                    i -= 1;
                    const h = g.exec.handlers.items[i];
                    if (h.finally_pc != Handler.none) {
                        fin = h.finally_pc;
                        keep_handlers = i;
                        stack_depth = h.stack_depth;
                        break;
                    }
                }
                if (fin) |fpc| {
                    g.exec.handlers.shrinkRetainingCapacity(keep_handlers);
                    g.exec.stack.shrinkRetainingCapacity(stack_depth);
                    try g.exec.stack.append(g.stackAllocator(vm.arena), val);
                    try g.exec.stack.append(g.stackAllocator(vm.arena), Value.num(@floatFromInt(@intFromEnum(Completion.ret))));
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
        var reason = vm.exception;
        vm.exception = Value.undef();
        // DisposeResources for the body's `using` resources, threading the error.
        if (g.env.disposables.items.len > 0) {
            if (vm.disposeScope(g.env, reason) catch null) |de| reason = de;
        }
        return .{ .threw = reason };
    };
    if (g.suspended) {
        g.suspended = false;
        return if (g.suspend_kind == .await) .{ .awaited = v } else .{ .yielded = v };
    }
    // DisposeResources for the body's top-level `using` resources at completion.
    if (g.env.disposables.items.len > 0) {
        if (vm.disposeScope(g.env, null) catch null) |de| return .{ .threw = de };
    }
    return .{ .returned = v };
}

/// Drive the front request to its next stop, settling its promise (yield/
/// return/throw) or wiring an await continuation.
fn agFront(g: *Generator) ?AsyncGenRequest {
    g.requests_mutex.lockUncancelable(agent.engineIo());
    defer g.requests_mutex.unlock(agent.engineIo());
    if (g.requests.items.len == 0) {
        g.pumping = false;
        return null;
    }
    return g.requests.items[0];
}

fn agRemoveFrontAndContinue(vm: *Interpreter, g: *Generator) EvalError!void {
    var next_req: ?AsyncGenRequest = null;
    var drain_done = false;
    g.requests_mutex.lockUncancelable(agent.engineIo());
    if (g.requests.items.len > 0) _ = g.requests.orderedRemove(0);
    if (g.done)
        drain_done = true
    else if (g.requests.items.len > 0)
        next_req = g.requests.items[0]
    else
        g.pumping = false;
    g.requests_mutex.unlock(agent.engineIo());
    if (drain_done)
        try agDrainDone(vm, g)
    else if (next_req) |req|
        try agStep(vm, g, req.kind, req.value);
}

fn agStep(vm: *Interpreter, g: *Generator, kind: ResumeKind, val: Value) EvalError!void {
    if (agFront(g) == null) return;
    const step = try agResume(vm, g, kind, val);
    const front_req = agFront(g) orelse return;
    const front = front_req.result;
    switch (step) {
        .awaited => |awaited| {
            const ap = try promise.newPromise(vm);
            try promise.resolve(vm, @ptrCast(@alignCast(ap.promise.?)), awaited);
            const onf = try gc_mod.allocObj(vm.arena);
            onf.* = .{ .native = agOnFulfill, .private_data = @ptrCast(g) };
            const onr = try gc_mod.allocObj(vm.arena);
            onr.* = .{ .native = agOnReject, .private_data = @ptrCast(g) };
            _ = try promise.then(vm, @ptrCast(@alignCast(ap.promise.?)), Value.obj(onf), Value.obj(onr));
        },
        .yielded => |v| {
            try promise.resolve(vm, @ptrCast(@alignCast(front.promise.?)), try makeIterResult(vm, v, false));
            try agRemoveFrontAndContinue(vm, g);
        },
        .returned => |v| {
            // AsyncGeneratorAwaitReturn: await the return value, then resolve the
            // request as a done result (the front request stays queued until the
            // await callback settles it).
            const can_resume_abrupt = g.started and !g.done;
            const wrapped = interp.promiseResolveValue(vm, v) catch |err| {
                if (err != error.Throw) return err;
                const reason = vm.exception;
                vm.exception = Value.undef();
                if (can_resume_abrupt) return agStep(vm, g, .throw_, reason);
                g.done = true;
                try promise.reject(vm, @ptrCast(@alignCast(front.promise.?)), reason);
                try agRemoveFrontAndContinue(vm, g);
                return;
            };
            g.done = true;
            const onf = try gc_mod.allocObj(vm.arena);
            onf.* = .{ .native = agReturnFulfill, .private_data = @ptrCast(g) };
            const onr = try gc_mod.allocObj(vm.arena);
            onr.* = .{ .native = agReturnReject, .private_data = @ptrCast(g) };
            _ = try promise.then(vm, @ptrCast(@alignCast(wrapped.asObj().promise.?)), Value.obj(onf), Value.obj(onr));
        },
        .threw => |e| {
            g.done = true;
            try promise.reject(vm, @ptrCast(@alignCast(front.promise.?)), e);
            try agRemoveFrontAndContinue(vm, g);
        },
    }
}

fn agPumpNext(vm: *Interpreter, g: *Generator) EvalError!void {
    var req: ?AsyncGenRequest = null;
    var drain_done = false;
    g.requests_mutex.lockUncancelable(agent.engineIo());
    if (g.pumping) {
        g.requests_mutex.unlock(agent.engineIo());
        return;
    }
    if (g.requests.items.len == 0) {
        g.requests_mutex.unlock(agent.engineIo());
        return;
    }
    g.pumping = true;
    if (g.done)
        drain_done = true
    else
        req = g.requests.items[0];
    g.requests_mutex.unlock(agent.engineIo());
    if (drain_done)
        try agDrainDone(vm, g)
    else if (req) |r|
        try agStep(vm, g, r.kind, r.value);
}

fn agDoneReturnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const result: *value.Object = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try promise.resolve(vm, @ptrCast(@alignCast(result.promise.?)), try makeIterResult(vm, if (args.len > 0) args[0] else Value.undef(), true));
    return Value.undef();
}

fn agDoneReturnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const result: *value.Object = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try promise.reject(vm, @ptrCast(@alignCast(result.promise.?)), if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

fn settleAsyncGeneratorDoneReturn(vm: *Interpreter, result: *value.Object, value_v: Value) EvalError!void {
    const wrapped = interp.promiseResolveValue(vm, value_v) catch |err| {
        if (err != error.Throw) return err;
        const reason = vm.exception;
        vm.exception = Value.undef();
        try promise.reject(vm, @ptrCast(@alignCast(result.promise.?)), reason);
        return;
    };
    const onf = try gc_mod.allocObj(vm.arena);
    onf.* = .{ .native = agDoneReturnFulfill, .private_data = @ptrCast(result) };
    const onr = try gc_mod.allocObj(vm.arena);
    onr.* = .{ .native = agDoneReturnReject, .private_data = @ptrCast(result) };
    _ = try promise.then(vm, @ptrCast(@alignCast(wrapped.asObj().promise.?)), Value.obj(onf), Value.obj(onr));
}

/// Once the generator is done, settle every still-queued request: a `next`
/// yields `{ undefined, done:true }`, a `return` its value, a `throw` rejects.
fn agDrainDone(vm: *Interpreter, g: *Generator) EvalError!void {
    while (true) {
        g.requests_mutex.lockUncancelable(agent.engineIo());
        if (g.requests.items.len == 0) {
            g.pumping = false;
            g.requests_mutex.unlock(agent.engineIo());
            break;
        }
        const req = g.requests.orderedRemove(0);
        g.requests_mutex.unlock(agent.engineIo());
        switch (req.kind) {
            .throw_ => try promise.reject(vm, @ptrCast(@alignCast(req.result.promise.?)), req.value),
            .return_ => try settleAsyncGeneratorDoneReturn(vm, req.result, req.value),
            .send => try promise.resolve(vm, @ptrCast(@alignCast(req.result.promise.?)), try makeIterResult(vm, Value.undef(), true)),
        }
    }
}

/// AsyncGeneratorAwaitReturn fulfilled: the (awaited) return value resolves the
/// front request as a done iterator result, then any queued requests drain.
fn agReturnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    const front_req = agFront(g) orelse return Value.undef();
    const front = front_req.result;
    try promise.resolve(vm, @ptrCast(@alignCast(front.promise.?)), try makeIterResult(vm, if (args.len > 0) args[0] else Value.undef(), true));
    g.requests_mutex.lockUncancelable(agent.engineIo());
    if (g.requests.items.len > 0) _ = g.requests.orderedRemove(0);
    g.requests_mutex.unlock(agent.engineIo());
    try agDrainDone(vm, g);
    return Value.undef();
}

/// AsyncGeneratorAwaitReturn rejected: the await threw → reject the front request.
fn agReturnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    const front_req = agFront(g) orelse return Value.undef();
    const front = front_req.result;
    try promise.reject(vm, @ptrCast(@alignCast(front.promise.?)), if (args.len > 0) args[0] else Value.undef());
    g.requests_mutex.lockUncancelable(agent.engineIo());
    if (g.requests.items.len > 0) _ = g.requests.orderedRemove(0);
    g.requests_mutex.unlock(agent.engineIo());
    try agDrainDone(vm, g);
    return Value.undef();
}

fn agOnFulfill(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try agStep(vm, g, .send, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

fn agOnReject(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const g: *Generator = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try agStep(vm, g, .throw_, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

/// Trace engine-owned `private_data` carried by VM async resume callbacks.
/// Host callbacks remain opaque; this recognizes only native functions
/// allocated in this file.
pub fn traceNativePrivateData(o: *value.Object, v: anytype) void {
    const nf = o.native orelse return;
    const pd = o.private_data orelse return;
    if (nf == asyncOnFulfill or nf == asyncOnReject or
        nf == agOnFulfill or nf == agOnReject or
        nf == agReturnFulfill or nf == agReturnReject)
    {
        const g: *Generator = @ptrCast(@alignCast(pd));
        v.mark(g);
        return;
    }
    if (nf == agDoneReturnFulfill or nf == agDoneReturnReject) {
        const result: *value.Object = @ptrCast(@alignCast(pd));
        v.mark(result);
    }
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
    const func = try gc_mod.allocFunction(vm.arena);
    // A named function expression binds its own name as an immutable binding in
    // a fresh scope enclosing the body, so the body can recurse via that name and
    // can't rebind it. `runFunction` installs `func.closure` as `vm.env` for the
    // call, so the body's free-variable lookups resolve the self name here.
    const closure_env = if (tmpl.self_name.len > 0) blk: {
        const fenv = try gc_mod.allocEnv(vm.arena);
        vm.initEnvironment(fenv, vm.env, false);
        break :blk fenv;
    } else vm.env;
    func.* = .{
        .params = tmpl.params,
        .body = tmpl.body,
        .is_expr_body = tmpl.is_expr_body,
        .closure = closure_env,
        .name = tmpl.name,
        .source = tmpl.source,
        .is_generator = tmpl.is_generator,
        .is_async = tmpl.is_async,
        .is_strict = tmpl.is_strict,
        .chunk = if (tmpl.is_generator or tmpl.is_async) null else tmpl.chunk,
        .gen_chunk = if (tmpl.is_generator) tmpl.chunk else null,
        .frame = frame,
        .local_count = tmpl.local_count,
    };
    const obj = try gc_mod.allocObj(vm.arena);
    const fproto: ?*value.Object = blk: {
        const tag: ?[]const u8 = if (tmpl.is_generator and tmpl.is_async)
            "\x00AsyncGenFuncProto"
        else if (tmpl.is_generator)
            "\x00GenFuncProto"
        else if (tmpl.is_async)
            "\x00AsyncFuncProto"
        else
            null;
        if (tag) |t| if (vm.env.get(t)) |v| if (v.isObject()) break :blk v.asObj();
        break :blk vm.functionProto();
    };
    obj.* = .{ .js_func = @ptrCast(func), .proto = fproto };
    func.obj = obj;
    try interp.installFunctionProps(vm.arena, vm.root_shape, obj, tmpl.params, tmpl.name);
    if (tmpl.self_name.len > 0) try closure_env.putFnName(tmpl.self_name, Value.obj(obj));
    return Value.obj(obj);
}

/// Invoke `callee` with `args` and an explicit `this`. A VM-compiled function
/// runs in a nested VM frame; everything else (natives, error constructors,
/// tree-walk closures) is handed to the interpreter.
fn callValue(vm: *Interpreter, callee: Value, args: []const Value, this_val: Value) EvalError!Value {
    if (callee.isObject()) {
        if (callee.asObj().js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            if (!func.is_generator and !func.is_async) {
                if (func.chunk) |fchunk| return runFunction(vm, func, fchunk, args, this_val);
            }
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
    if (method.isObject() and method.asObj().isCallableObject())
        return callValue(vm, method, args, recv);
    if (try vm.builtinMethod(recv, name, args)) |r| return r;
    return callValue(vm, method, args, recv);
}

/// `new callee(args)`. A VM-compiled constructor runs on the VM with a fresh
/// `this` (tagged for `instanceof`); error constructors and tree-walk functions
/// are delegated to the interpreter.
fn construct(vm: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
    if (callee.isObject()) {
        if (callee.asObj().js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            if (func.chunk) |fchunk| {
                const this_val = try vm.newInstance(callee.asObj());
                const ret = try runFunction(vm, func, fchunk, args, this_val);
                return if (ret.isObject()) ret else this_val;
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
    @memset(slots, Value.undef());
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
    const saved_pm = vm.current_private_map;
    if (!func.is_arrow) vm.current_private_map = func.private_map; // a direct eval here resolves the class's private names
    vm.strict = func.is_strict;
    // Free variables (globals, and a named function expression's self name)
    // resolve through `vm.env`; install the closure's defining environment so a
    // named function expression's own immutable binding is visible in its body.
    // For ordinary functions `func.closure` is the global env (unchanged).
    vm.env = func.closure;
    vm.this_value = try bindThisForCall(vm, func, this_val);
    defer {
        vm.this_value = saved_this;
        vm.strict = saved_strict;
        vm.env = saved_env;
        vm.current_private_map = saved_pm;
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
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(a, "1 + 2 * 3")).asNum());
    try std.testing.expectEqual(@as(f64, 1024), (try vmRun(a, "2 ** 10")).asNum());
    try std.testing.expect((try vmRun(a, "3 > 2 && 2 >= 2")).asBool());
    try std.testing.expect((try vmRun(a, "false || 1 === 1")).asBool());
    try std.testing.expectEqualStrings("ab1", (try vmRun(a, "'a' + 'b' + 1")).asStr());
}

test "vm: vars, while loop, ternary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 15), (try vmRun(a,
        \\let x = 0; let i = 1;
        \\while (i <= 5) { x = x + i; i = i + 1; }
        \\x
    )).asNum());
    try std.testing.expectEqual(@as(f64, 10), (try vmRun(a, "true ? 10 : 20")).asNum());
}

test "vm: functions, recursion, closures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 42), (try vmRun(a,
        \\function add(x, y) { return x + y; }
        \\add(40, 2)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 120), (try vmRun(a,
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\fact(5)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 15), (try vmRun(a,
        \\function mk(x) { return function (y) { return x + y; }; }
        \\mk(10)(5)
    )).asNum());
}

test "vm: generator calls from bytecode are lazy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("object", (try vmRun(a,
        \\function *g() { throw new Error("body ran"); }
        \\typeof g()
    )).asStr());
}

test "vm: if/else and short-circuit value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(a, "let v = 0; if (3 > 2) { v = 1; } else { v = 2; } v")).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try vmRun(a, "0 || 5")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try vmRun(a, "0 && 5")).asNum());
}

test "vm: objects, arrays, members, this, new, instanceof on the VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), (try vmRun(a, "let o = { x: 1, y: 2 }; o.x + o.y")).asNum());
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(a, "let o = {}; o.a = 4; o['b'] = 5; o.a + o['b']")).asNum());
    try std.testing.expectEqual(@as(f64, 30), (try vmRun(a, "let xs = [10, 20, 30]; xs[2]")).asNum());
    try std.testing.expectEqual(@as(f64, 4), (try vmRun(a, "let xs = [1]; xs.push(2); xs.push(3); xs.push(4); xs.length")).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(a, "function P(x, y) { this.x = x; this.y = y; } let p = new P(3, 4); p.x + p.y")).asNum());
    try std.testing.expect((try vmRun(a, "function P(x) { this.x = x; } (new P(1)) instanceof P")).asBool());
    try std.testing.expectEqual(@as(f64, 10), (try vmRun(a, "let o = { n: 10, get: function () { return this.n; } }; o.get()")).asNum());
}

test "vm: for loop with ++ and compound assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 45), (try vmRun(a, "let s = 0; for (let i = 0; i < 10; i++) { s += i; } s")).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try vmRun(a, "let x = 5; let y = x++; y")).asNum());
    try std.testing.expectEqual(@as(f64, 6), (try vmRun(a, "let x = 5; let y = ++x; y")).asNum());
}

test "vm: compiler still falls back for try/catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = try Parser.init(a, "try { throw 1; } catch (e) {}");
    const prog = try parser.parseProgram();
    try std.testing.expectError(error.Unsupported, Compiler.compileProgram(a, prog));
}
