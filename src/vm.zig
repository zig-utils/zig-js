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

const async_gen_request_reserve_granularity: usize = 16;

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
    // Once a closure captures this frame (`makeClosure` walks the chain marking
    // `escaped`), its slots can be read/written concurrently: the defining
    // function via load/store_local on its own frame, and any escaped closure via
    // load/store_upval walking into it. So slot access on an escaped frame is
    // serialized by `slot_lock`. Non-escaped frames (the vast majority — never
    // captured) take no lock at all; and the whole thing is additionally gated on
    // the parallel flag, so the GIL/single-threaded engine pays nothing.
    escaped: std.atomic.Value(bool) = .init(false),
    slot_lock: std.atomic.Mutex = .unlocked,

    // `pub` so the GC's parallel root trace can take the same lock when it reads
    // an escaped frame's slots via a cross-thread captured-frame walk; see
    // `gc.traceInterpreterRoots`.
    pub inline fn lockSlots(self: *Frame, enabled: bool) bool {
        // `enabled` is the parallel-mode flag, hoisted out of the opcode loop by
        // the caller. When false (default engine) this is a single register branch.
        // Monotonic `escaped` is enough: a closure reaching this frame on another
        // thread already synchronized via the closure object's publication.
        if (!enabled or !self.escaped.load(.monotonic)) return false;
        var spins: usize = 0;
        while (!self.slot_lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
        return true;
    }
    pub fn unlockSlots(self: *Frame, held: bool) void {
        if (held) self.slot_lock.unlock();
    }

    /// Mark this frame and every ancestor as escaped — a closure capturing this
    /// frame can reach them all through the upvalue walk.
    fn markEscapedChain(self: *Frame) void {
        var f: ?*Frame = self;
        while (f) |fr| : (f = fr.parent) {
            if (fr.escaped.load(.monotonic)) break; // chain already marked
            fr.escaped.store(true, .release);
        }
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
    /// The activation frame this Exec is running (null for env-mode bodies:
    /// program/generator/async). Recorded so a mid-script collection can trace
    /// the frame's `slots` (and its captured-frame parent chain) as precise GC
    /// roots — like `stack`/`acc`, the slots are arena-backed and invisible to
    /// both the precise object graph and the conservative native-stack scan, so
    /// an object live only through a VM local would otherwise be swept.
    frame: ?*Frame = null,
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

fn looksLikeCompletionKind(v: Value) bool {
    if (!v.isNumber()) return false;
    const n = v.asNum();
    if (@trunc(n) != n) return false;
    return n >= 0 and n <= @as(f64, @floatFromInt(@intFromEnum(Completion.continue_)));
}

fn completionKindBelowTop(stack: *const std.ArrayListUnmanaged(Value)) ?Completion {
    if (stack.items.len == 0) return null;
    const v = stack.items[stack.items.len - 1];
    if (!looksLikeCompletionKind(v)) return null;
    return @enumFromInt(@as(u8, @intFromFloat(v.asNum())));
}

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
    import_meta_slot: ?*interp.ImportMetaSlot = null,
    module_referrer: []const u8 = "",
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
    requests_head: usize = 0,
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

    pub fn pendingRequests(self: *const Generator) []const AsyncGenRequest {
        if (self.requests_head >= self.requests.items.len) return self.requests.items[0..0];
        return self.requests.items[self.requests_head..];
    }

    fn hasPendingRequest(self: *const Generator) bool {
        return self.requests_head < self.requests.items.len;
    }

    fn compactRequests(self: *Generator) void {
        if (self.requests_head == 0) return;
        const pending = self.pendingRequests();
        if (pending.len > 0) std.mem.copyForwards(AsyncGenRequest, self.requests.items[0..pending.len], pending);
        self.requests.shrinkRetainingCapacity(pending.len);
        self.requests_head = 0;
    }

    fn reserveRequests(self: *Generator, fallback: std.mem.Allocator, additional: usize) !void {
        if (additional == 0) return;
        var spare = self.requests.capacity - self.requests.items.len;
        if (spare < additional and self.requests_head > 0) {
            self.compactRequests();
            spare = self.requests.capacity - self.requests.items.len;
        }
        if (spare >= additional) return;
        const extra = @max(additional, async_gen_request_reserve_granularity);
        try self.requests.ensureTotalCapacity(self.requestsAllocator(fallback), self.requests.items.len + extra);
    }

    fn appendRequest(self: *Generator, fallback: std.mem.Allocator, req: AsyncGenRequest) !void {
        try self.reserveRequests(fallback, 1);
        self.requests.appendAssumeCapacity(req);
    }

    fn frontRequest(self: *const Generator) ?AsyncGenRequest {
        if (!self.hasPendingRequest()) return null;
        return self.requests.items[self.requests_head];
    }

    fn popRequest(self: *Generator) ?AsyncGenRequest {
        if (!self.hasPendingRequest()) {
            self.requests.clearRetainingCapacity();
            self.requests_head = 0;
            return null;
        }
        const req = self.requests.items[self.requests_head];
        self.requests.items[self.requests_head] = undefined;
        self.requests_head += 1;
        if (self.requests_head == self.requests.items.len) {
            self.requests.clearRetainingCapacity();
            self.requests_head = 0;
        }
        return req;
    }
};

/// A queued async-generator request: how to resume the body and the promise to
/// settle with the resulting `{ value, done }` (or rejection).
pub const AsyncGenRequest = struct {
    kind: ResumeKind,
    value: Value,
    result: *value.Object,
};

test "async generator request queue uses a head cursor and compacting reserve" {
    var g = Generator{
        .chunk = undefined,
        .env = undefined,
    };
    defer g.requests.deinit(std.testing.allocator);

    const dummy_result: *value.Object = undefined;
    var i: usize = 0;
    while (i < async_gen_request_reserve_granularity) : (i += 1) {
        try g.appendRequest(std.testing.allocator, .{
            .kind = .send,
            .value = Value.num(@floatFromInt(i)),
            .result = dummy_result,
        });
    }

    const first_capacity = g.requests.capacity;
    try std.testing.expect(first_capacity >= async_gen_request_reserve_granularity);
    while (i < first_capacity) : (i += 1) {
        try g.appendRequest(std.testing.allocator, .{
            .kind = .send,
            .value = Value.num(@floatFromInt(i)),
            .result = dummy_result,
        });
    }
    try std.testing.expectEqual(first_capacity, g.pendingRequests().len);

    const first = g.popRequest().?;
    try std.testing.expectEqual(@as(f64, 0), first.value.asNum());
    try std.testing.expectEqual(@as(usize, 1), g.requests_head);
    try std.testing.expectEqual(first_capacity, g.requests.items.len);

    try g.appendRequest(std.testing.allocator, .{
        .kind = .return_,
        .value = Value.num(99),
        .result = dummy_result,
    });
    try std.testing.expectEqual(first_capacity, g.requests.capacity);
    try std.testing.expectEqual(@as(usize, 0), g.requests_head);
    try std.testing.expectEqual(first_capacity, g.requests.items.len);
    try std.testing.expectEqual(@as(f64, 1), g.frontRequest().?.value.asNum());
    try std.testing.expectEqual(@as(f64, 99), g.requests.items[g.requests.items.len - 1].value.asNum());

    var expected: f64 = 1;
    while (g.popRequest()) |req| {
        if (g.hasPendingRequest())
            try std.testing.expectEqual(expected, req.value.asNum())
        else
            try std.testing.expectEqual(@as(f64, 99), req.value.asNum());
        expected += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), g.requests_head);
    try std.testing.expectEqual(@as(usize, 0), g.requests.items.len);
    try std.testing.expectEqual(first_capacity, g.requests.capacity);
}

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
    // The trampoline is off inside `execLoop`: the top-level program and
    // generator/async bodies keep native `.call` dispatch (the `.call` opcode
    // only pushes activations when `driver_active`). A JS call made here still
    // enters `runFunction` → `runDriver`, so the *called* function's deep
    // recursion is trampolined; only this frame itself stays native.
    const saved_active = vm.driver_active;
    vm.driver_active = false;
    defer vm.driver_active = saved_active;
    // Register this operand stack as a precise GC root while it runs, so a
    // mid-script collection at a step checkpoint traces its live `Value`s (the
    // operand stack is arena-backed, invisible to the conservative native-stack
    // scan). No-op when the GC is off.
    exec.frame = frame; // so a mid-script collection roots this activation's slots
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
    // Parallel-mode flag hoisted out of the hot loop: in the default engine this
    // is false, so the per-opcode frame-slot lock check is a single predicted
    // register branch (no atomic load, no call) — load_local/store_local stay at
    // full speed.
    const frame_locking = bc.ic_seqlock_enabled.load(.monotonic);

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
            .swap => {
                const top = stack.items.len - 1;
                const tmp = stack.items[top];
                stack.items[top] = stack.items[top - 1];
                stack.items[top - 1] = tmp;
            },
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
                const val = stack.pop().?;
                // A `var x = init` (b == 1) whose name a `with` object provides
                // writes to that object: ResolveBinding runs before PutValue, and
                // the object Environment Record (honoring `@@unscopables`) shadows
                // the hoisted var binding, which is left untouched. Mirrors the
                // tree-walker's `assignWithObject` capture. A bare `var x;` (b == 0)
                // never redirects or overwrites an existing binding; force
                // definitions (b == 2, function declarations/internal temps) do.
                const wo: ?*value.Object = if (inst.b == 1) try vm.assignWithObject(name) else null;
                if (wo) |o| {
                    try vm.setMember(Value.obj(o), name, val);
                } else if (inst.b == 0 and vm.env.varScope().vars.contains(name)) {
                    // `var f; function f(){}` preserves the hoisted function value.
                } else {
                    try vm.globalDefine(name, val);
                }
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

            .load_local => {
                const cf = frame.?;
                const held = cf.lockSlots(frame_locking);
                const v = cf.slots[inst.a];
                cf.unlockSlots(held);
                try stack.append(stack_alloc, v);
            },
            .store_local => {
                const cf = frame.?;
                const v = stack.items[stack.items.len - 1]; // leaves value on the stack
                const held = cf.lockSlots(frame_locking);
                cf.slots[inst.a] = v;
                cf.unlockSlots(held);
            },
            .load_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                const held = f.lockSlots(frame_locking);
                const v = f.slots[inst.b];
                f.unlockSlots(held);
                try stack.append(stack_alloc, v);
            },
            .store_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                const v = stack.items[stack.items.len - 1]; // leaves value on the stack
                const held = f.lockSlots(frame_locking);
                f.slots[inst.b] = v;
                f.unlockSlots(held);
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
            .to_numeric => {
                try stack.append(stack_alloc, try vm.toNumericPrimitive(stack.pop().?));
            },
            .to_property_key => {
                // ToPropertyKey: coerce to the property-key string once (runs the
                // key's toString/valueOf), so a computed key's coercion happens
                // before the property value is evaluated.
                try stack.append(stack_alloc, Value.str(try propKey(vm, stack.pop().?)));
            },
            .inc, .dec => {
                // ToNumeric then ±1 of the operand's own numeric type, matching
                // the tree-walker's evalUpdate (so `"5"++` is 6, not "51", and a
                // BigInt increments as a BigInt rather than TypeError-ing on `+1`).
                const v = try vm.toNumericPrimitive(stack.pop().?);
                if (v.isObject() and v.asObj().is_bigint) {
                    const one = try vm.makeBigInt(1);
                    try stack.append(stack_alloc, try vm.applyBinary(if (inst.op == .inc) .add else .sub, v, one));
                } else {
                    const n = try vm.toNumberV(v);
                    try stack.append(stack_alloc, Value.num(if (inst.op == .inc) n + 1 else n - 1));
                }
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
                // Number-number fast path: when both operands are numbers the
                // result is computed inline, bit-for-bit identical to
                // Interpreter.applyBinary (interpreter.zig:13944-13967), skipping
                // its ToPrimitive / BigInt / string-concat dispatch. Bitwise,
                // shift, and `in` need ToInt32/object semantics, so they fall
                // through to the general path.
                const result: Value = fast: {
                    if (l.isNumber() and r.isNumber()) {
                        const a = l.asNum();
                        const b = r.asNum();
                        break :fast switch (inst.op) {
                            .add => Value.num(a + b),
                            .sub => Value.num(a - b),
                            .mul => Value.num(a * b),
                            .div => Value.num(a / b),
                            .mod => Value.num(@rem(a, b)),
                            .pow => if (std.math.isInf(b) and @abs(a) == 1)
                                Value.num(std.math.nan(f64))
                            else
                                Value.num(std.math.pow(f64, a, b)),
                            .lt => Value.boolVal(a < b),
                            .le => Value.boolVal(a <= b),
                            .gt => Value.boolVal(a > b),
                            .ge => Value.boolVal(a >= b),
                            .eq, .eq_strict => Value.boolVal(a == b),
                            .neq, .neq_strict => Value.boolVal(a != b),
                            // in_op / bit_and / bit_or / bit_xor / shl / shr / ushr
                            else => try vm.applyBinary(binOp(inst.op), l, r),
                        };
                    }
                    break :fast try vm.applyBinary(binOp(inst.op), l, r);
                };
                try stack.append(stack_alloc, result);
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
            .jump_if_nullish_peek => {
                const v = stack.items[stack.items.len - 1];
                if (v.isNull() or v.isUndefined()) ip = inst.a;
            },
            .jump_if_not_nullish_peek => {
                const v = stack.items[stack.items.len - 1];
                if (!v.isNull() and !v.isUndefined()) ip = inst.a;
            },

            .load_this => try stack.append(stack_alloc, vm.this_value),
            .load_new_target => try stack.append(stack_alloc, vm.new_target),
            .new_object => try stack.append(stack_alloc, try vm.newObject()),
            .new_array => try stack.append(stack_alloc, try vm.newArray()),
            .init_prop => {
                const v = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                // Object-literal property init is CreateDataPropertyOrThrow — a
                // direct own data property, NOT [[Set]] (so an own `__proto__`
                // shorthand/method/computed key does not trip the prototype setter).
                if (Interpreter.funcOf(v)) |f| {
                    if (f.is_method) f.home_object = obj.asObj();
                }
                try vm.defineLiteralDataProp(obj.asObj(), chunk.names.items[inst.a], v);
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
                // The key was already ToPropertyKey'd by `to_property_key` (emitted
                // before the value), so it sits below the value on the stack.
                const v = stack.pop().?;
                const key = stack.pop().?;
                const obj = stack.items[stack.items.len - 1]; // leave object on stack
                if (Interpreter.funcOf(v)) |f| {
                    if (f.is_method) f.home_object = obj.asObj();
                }
                try vm.defineLiteralDataProp(obj.asObj(), try propKey(vm, key), v); // CreateDataProperty (a computed `__proto__` is a normal own prop)
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
                        if (!o.is_array and o.accessors.load(.monotonic) == null and o.attrsMap() == null) {
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
                // RequireObjectCoercible before ToPropertyKey: `null[k]` is a
                // TypeError before the key's `toString` runs (matches the tree-walker).
                if (obj.isNull() or obj.isUndefined())
                    return vm.throwError("TypeError", "cannot read property of null or undefined");
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
            .enter_block => {
                const benv = try gc_mod.allocEnv(vm.arena);
                vm.initEnvironment(benv, vm.env, false);
                vm.env = benv;
                if (gen) |g| g.env = benv;
            },
            .exit_block => {
                vm.env = vm.env.parent.?;
                if (gen) |g| g.env = vm.env;
            },
            .dispose_scope => {
                if (inst.a == 1) {
                    if (vm.env.disposables.items.len > 0) {
                        if (try vm.disposeScopeAsyncStep(vm.env)) |awaited| {
                            try stack.append(stack_alloc, awaited);
                        } else {
                            try stack.append(stack_alloc, Value.undef());
                        }
                    } else {
                        try stack.append(stack_alloc, Value.undef());
                    }
                } else if (vm.env.disposables.items.len > 0 or vm.env.dispose_pending != null) {
                    if (try vm.disposeScope(vm.env, null)) |err| {
                        vm.exception = err;
                        return error.Throw;
                    }
                }
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
                if (gen) |g| g.env = wenv;
            },
            .exit_with => {
                vm.env = vm.env.parent.?;
                if (gen) |g| g.env = vm.env;
            },
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
                        if (!o.is_array and o.accessors.load(.monotonic) == null and o.attrsMap() == null) {
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
                // RequireObjectCoercible before ToPropertyKey (the RHS is already
                // evaluated); `null[k] = v` throws before the key's `toString` runs.
                if (obj.isNull() or obj.isUndefined())
                    return vm.throwError("TypeError", "Cannot set property of null or undefined");
                try vm.setMember(obj, try propKey(vm, key), v);
                try stack.append(stack_alloc, v);
            },
            .instance_of => {
                const r = stack.pop().?;
                const l = stack.pop().?;
                try stack.append(stack_alloc, Value.boolVal(try vm.instanceOf(l, r)));
            },
            .private_in => {
                const r = stack.pop().?;
                try stack.append(stack_alloc, Value.boolVal(try vm.privateIn(chunk.names.items[inst.a], r)));
            },

            .make_closure => try stack.append(stack_alloc, try makeClosure(vm, chunk.fns.items[inst.a], frame)),
            .call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                // Trampoline plain JS→JS calls under the driver: build the callee
                // activation, clear callee+args off this stack (the result lands
                // where the callee was), flush acc/ip, and yield to `runDriver`
                // via `pending_activation` instead of recursing natively.
                if (vm.driver_active) {
                    if (jsChunkFn(callee)) |func| {
                        const act = try buildActivation(vm, func, func.chunk.?, stack.items[base..], Value.undef(), Value.undef());
                        act.result_base = base - 1;
                        stack.shrinkRetainingCapacity(base - 1);
                        exec.acc = acc;
                        exec.ip = ip;
                        vm.pending_activation = act;
                        return acc; // driver reads `pending_activation` and ignores this value
                    }
                }
                const result = try callValue(vm, callee, stack.items[base..], Value.undef());
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(stack_alloc, result);
            },
            .tail_call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                if (vm.driver_active) {
                    if (jsChunkFn(callee)) |func| {
                        const act = try buildActivation(vm, func, func.chunk.?, stack.items[base..], Value.undef(), Value.undef());
                        stack.shrinkRetainingCapacity(base - 1);
                        exec.acc = acc;
                        exec.ip = ip;
                        vm.pending_activation = act;
                        vm.pending_tail_call = true;
                        return acc;
                    }
                }
                return try callValue(vm, callee, stack.items[base..], Value.undef());
            },
            .tail_call_eval => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                if (vm.driver_active and !vm.isDirectEvalCallee(callee)) {
                    if (jsChunkFn(callee)) |func| {
                        const act = try buildActivation(vm, func, func.chunk.?, stack.items[base..], Value.undef(), Value.undef());
                        stack.shrinkRetainingCapacity(base - 1);
                        exec.acc = acc;
                        exec.ip = ip;
                        vm.pending_activation = act;
                        vm.pending_tail_call = true;
                        return acc;
                    }
                }
                const saved = vm.direct_eval_call;
                vm.direct_eval_call = vm.isDirectEvalCallee(callee);
                const result = callValue(vm, callee, stack.items[base..], Value.undef()) catch |e| {
                    vm.direct_eval_call = saved;
                    return e;
                };
                vm.direct_eval_call = saved;
                return result;
            },
            .call_eval => {
                // A bare `eval(args)` call: mark it a DIRECT eval so, if the callee
                // is the eval intrinsic, the eval'd code runs in this body's scope
                // (sees its `let`/`var`/private names). Ignored if `eval` was shadowed.
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                const saved = vm.direct_eval_call;
                vm.direct_eval_call = vm.isDirectEvalCallee(callee);
                const result = callValue(vm, callee, stack.items[base..], Value.undef()) catch |e| {
                    vm.direct_eval_call = saved;
                    return e;
                };
                vm.direct_eval_call = saved;
                stack.shrinkRetainingCapacity(base - 1);
                try stack.append(stack_alloc, result);
            },
            .import_call => {
                const optionsv = stack.pop().?;
                const specv = stack.pop().?;
                try stack.append(stack_alloc, try vm.finishImportCall(specv, optionsv, chunk.names.items[inst.a]));
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
            .tail_call_method => {
                const argc = inst.b;
                const base = stack.items.len - argc;
                const recv = stack.items[base - 1];
                const args = stack.items[base..];
                const name = chunk.names.items[inst.a];
                const method = try vm.getProperty(recv, name);
                if (vm.driver_active) {
                    if (jsChunkFn(method)) |func| {
                        const act = try buildActivation(vm, func, func.chunk.?, args, recv, Value.undef());
                        stack.shrinkRetainingCapacity(base - 1);
                        exec.acc = acc;
                        exec.ip = ip;
                        vm.pending_activation = act;
                        vm.pending_tail_call = true;
                        return acc;
                    }
                }
                return try invokeMethod(vm, recv, name, args);
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
                if (try unwindToFinally(vm, gen, exec, target, kind)) |fpc| {
                    ip = fpc;
                } else {
                    // A break/continue *inside* a finally overrides that
                    // finally's active completion. With no outer finally to
                    // re-enter, discard the current [value, kind] record before
                    // jumping to the loop/label target.
                    if (stack.items.len >= 2 and looksLikeCompletionKind(stack.items[stack.items.len - 1]))
                        stack.shrinkRetainingCapacity(stack.items.len - 2);
                    ip = inst.a;
                }
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
            .tail_call_with_this => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const args = stack.items[base..];
                const this_val = stack.items[base - 1];
                const callee = stack.items[base - 2];
                if (vm.driver_active) {
                    if (jsChunkFn(callee)) |func| {
                        const act = try buildActivation(vm, func, func.chunk.?, args, this_val, Value.undef());
                        stack.shrinkRetainingCapacity(base - 2);
                        exec.acc = acc;
                        exec.ip = ip;
                        vm.pending_activation = act;
                        vm.pending_tail_call = true;
                        return acc;
                    }
                }
                return try callValue(vm, callee, args, this_val);
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
            .iter_close_completion => {
                const it = stack.pop().?;
                const is_throw = completionKindBelowTop(stack) == .throw;
                vm.iteratorClose(it) catch |e| {
                    if (!is_throw or e != error.Throw) return e;
                    vm.exception = stack.items[stack.items.len - 2];
                };
            },
            .async_iter_close, .async_iter_close_completion => {
                const it = stack.pop().?;
                const is_throw = inst.op == .async_iter_close_completion and completionKindBelowTop(stack) == .throw;
                const ret = vm.getProperty(it, "return") catch |e| {
                    if (!is_throw or e != error.Throw) return e;
                    vm.exception = stack.items[stack.items.len - 2];
                    try stack.append(stack_alloc, Value.undef());
                    try stack.append(stack_alloc, Value.boolVal(false));
                    continue;
                };
                if (ret.isUndefined() or ret.isNull()) {
                    try stack.append(stack_alloc, Value.undef());
                    try stack.append(stack_alloc, Value.boolVal(false));
                    continue;
                }
                if (!ret.isCallable()) {
                    if (is_throw) {
                        vm.exception = stack.items[stack.items.len - 2];
                        try stack.append(stack_alloc, Value.undef());
                        try stack.append(stack_alloc, Value.boolVal(false));
                        continue;
                    }
                    return vm.throwError("TypeError", "async iterator 'return' is not a function");
                }
                const r = vm.callValueWithThis(ret, &.{}, it) catch |e| {
                    if (!is_throw or e != error.Throw) return e;
                    vm.exception = stack.items[stack.items.len - 2];
                    try stack.append(stack_alloc, Value.undef());
                    try stack.append(stack_alloc, Value.boolVal(false));
                    continue;
                };
                try stack.append(stack_alloc, r);
                try stack.append(stack_alloc, Value.boolVal(true));
            },
            .eval_class => {
                const node = chunk.classes.items[inst.a];
                const c = node.class_expr;
                const count: usize = inst.b;
                const keys = try vm.arena.alloc(Value, count);
                var i = count;
                while (i > 0) {
                    i -= 1;
                    keys[i] = stack.pop().?;
                }
                try stack.append(stack_alloc, try vm.evalClassWithComputedKeys(c.name, c.inferred_name, c.superclass, c.members, c.source, keys));
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
    if (be.vars.contains("arguments")) {
        if (param_env.get("arguments")) |av| try be.put("arguments", av);
    }
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

    try genv.put("arguments", try vm.createArgumentsObject(func, args, genv));

    const bound_this = try bindThisForCall(vm, func, this_val);

    // Bind params into the generator's environment (handles default/rest/
    // destructuring). `bindParams` binds into `vm.env`, so point it at `genv`
    // for the duration. Defaults evaluate in the callee's this/super context, so
    // a generator method parameter can read `super.x`. Restore the caller state
    // afterward.
    const saved_env = vm.env;
    const saved_this = vm.this_value;
    const saved_home = vm.home_object;
    const saved_super = vm.super_ctor;
    const saved_this_initialized = vm.this_initialized;
    const saved_nt = vm.new_target;
    const saved_eval_nt = vm.direct_eval_new_target_allowed;
    const saved_cur_module = vm.cur_module;
    vm.env = genv;
    vm.this_value = bound_this;
    vm.home_object = func.home_object;
    vm.super_ctor = func.super_ctor;
    vm.this_initialized = true;
    vm.new_target = Value.undef();
    vm.direct_eval_new_target_allowed = true;
    vm.cur_module = func.module_referrer;
    defer {
        vm.env = saved_env;
        vm.this_value = saved_this;
        vm.home_object = saved_home;
        vm.super_ctor = saved_super;
        vm.this_initialized = saved_this_initialized;
        vm.new_target = saved_nt;
        vm.direct_eval_new_target_allowed = saved_eval_nt;
        vm.cur_module = saved_cur_module;
    }
    try vm.bindParams2(func.params, args, func.is_arrow);

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
        .import_meta_slot = func.import_meta_slot,
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
    const s_import_meta_slot = vm.import_meta_slot;
    const s_import_meta_obj = vm.import_meta_obj;
    const s_nt = vm.new_target;
    const s_eval_nt = vm.direct_eval_new_target_allowed;
    vm.env = g.env;
    vm.this_value = g.this_value;
    vm.home_object = g.home_object;
    vm.super_ctor = g.super_ctor;
    vm.import_meta_slot = g.import_meta_slot;
    vm.import_meta_obj = if (g.import_meta_slot) |slot| slot.obj else null;
    vm.new_target = Value.undef();
    vm.direct_eval_new_target_allowed = true;
    defer {
        vm.env = s_env;
        vm.this_value = s_this;
        vm.home_object = s_home;
        vm.super_ctor = s_super;
        vm.import_meta_slot = s_import_meta_slot;
        vm.import_meta_obj = s_import_meta_obj;
        vm.new_target = s_nt;
        vm.direct_eval_new_target_allowed = s_eval_nt;
    }

    try vm.stackGuard();
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
    const bound_this = bindThisForCall(vm, func, this_val) catch |err| {
        if (err != error.Throw) return err;
        const result = try promise.newPromise(vm);
        const rp: *promise.Promise = @ptrCast(@alignCast(result.promise.?));
        const reason = vm.exception;
        vm.exception = Value.undef();
        try promise.reject(vm, rp, reason);
        return Value.obj(result);
    };
    const saved_env = vm.env;
    const saved_this = vm.this_value;
    const saved_home = vm.home_object;
    const saved_super = vm.super_ctor;
    const saved_this_initialized = vm.this_initialized;
    const saved_nt = vm.new_target;
    const saved_eval_nt = vm.direct_eval_new_target_allowed;
    vm.env = genv;
    vm.this_value = bound_this;
    vm.home_object = func.home_object;
    vm.super_ctor = func.super_ctor;
    vm.this_initialized = true;
    vm.new_target = Value.undef();
    vm.direct_eval_new_target_allowed = true;
    defer {
        vm.env = saved_env;
        vm.this_value = saved_this;
        vm.home_object = saved_home;
        vm.super_ctor = saved_super;
        vm.this_initialized = saved_this_initialized;
        vm.new_target = saved_nt;
        vm.direct_eval_new_target_allowed = saved_eval_nt;
    }
    // An error thrown synchronously while evaluating parameter defaults (or
    // binding `this`) of an async function must settle the result promise as a
    // rejection, not propagate out of the call.
    const result = try promise.newPromise(vm);
    const rp: *promise.Promise = @ptrCast(@alignCast(result.promise.?));
    if (!func.is_arrow) try genv.put("arguments", try vm.createArgumentsObject(func, args, genv));
    vm.bindParams2(func.params, args, func.is_arrow) catch |err| {
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
        .module_referrer = func.module_referrer,
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

const AsyncDisposeCompletion = struct {
    gen: *Generator,
    index: usize,
    pending: ?Value,
    result_value: Value,
};

fn clearDisposables(env: *Environment) void {
    if (env.bindings_allocator != null) {
        env.disposables.deinit(env.bindingAllocator());
        env.disposables = .empty;
    } else {
        env.disposables.clearRetainingCapacity();
    }
}

fn suppressDisposeError(vm: *Interpreter, pending: ?Value, this_err: Value) EvalError!Value {
    return if (pending) |prev|
        try vm.makeErrorWithArgs("SuppressedError", &.{ this_err, prev })
    else
        this_err;
}

fn asyncDisposeResumeFulfilled(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const state: *AsyncDisposeCompletion = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try continueAsyncDisposal(vm, state, null);
    return Value.undef();
}

fn asyncDisposeResumeRejected(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const vm: *Interpreter = @ptrCast(@alignCast(ctx));
    const state: *AsyncDisposeCompletion = @ptrCast(@alignCast(vm.active_native.?.private_data.?));
    try continueAsyncDisposal(vm, state, if (args.len > 0) args[0] else Value.undef());
    return Value.undef();
}

fn scheduleAsyncDisposeContinuation(vm: *Interpreter, state: *AsyncDisposeCompletion, awaited_value: Value) EvalError!void {
    const wrapped = interp.promiseResolveValue(vm, awaited_value) catch |err| {
        if (err != error.Throw) return err;
        const reason = vm.exception;
        vm.exception = Value.undef();
        state.pending = try suppressDisposeError(vm, state.pending, reason);
        try continueAsyncDisposal(vm, state, null);
        return;
    };
    const onf = try gc_mod.allocObj(vm.arena);
    onf.* = .{ .native = asyncDisposeResumeFulfilled, .private_data = @ptrCast(state) };
    const onr = try gc_mod.allocObj(vm.arena);
    onr.* = .{ .native = asyncDisposeResumeRejected, .private_data = @ptrCast(state) };
    _ = try promise.then(vm, @ptrCast(@alignCast(wrapped.asObj().promise.?)), Value.obj(onf), Value.obj(onr));
}

fn continueAsyncDisposal(vm: *Interpreter, state: *AsyncDisposeCompletion, rejected: ?Value) EvalError!void {
    if (rejected) |reason| state.pending = try suppressDisposeError(vm, state.pending, reason);
    const env = state.gen.env;
    while (state.index > 0) {
        state.index -= 1;
        const d = env.disposables.items[state.index];
        var dispose_err: ?Value = null;
        if (d.method.isUndefined()) {
            if (d.is_async and d.await_result) {
                try scheduleAsyncDisposeContinuation(vm, state, Value.undef());
                return;
            }
        } else if (vm.callValueWithThis(d.method, &.{}, d.value)) |rv| {
            if (d.is_async and d.await_result) {
                try scheduleAsyncDisposeContinuation(vm, state, rv);
                return;
            }
        } else |e| {
            if (e != error.Throw) return e;
            dispose_err = vm.exception;
            vm.exception = Value.undef();
        }
        if (dispose_err) |this_err| state.pending = try suppressDisposeError(vm, state.pending, this_err);
    }
    clearDisposables(env);
    if (state.pending) |err| {
        try promise.reject(vm, resultPromise(state.gen), err);
    } else {
        try promise.resolve(vm, resultPromise(state.gen), state.result_value);
    }
}

fn completeAsyncWithDisposal(vm: *Interpreter, g: *Generator, result_value: Value, pending: ?Value) EvalError!void {
    const state = try vm.arena.create(AsyncDisposeCompletion);
    state.* = .{
        .gen = g,
        .index = g.env.disposables.items.len,
        .pending = pending,
        .result_value = result_value,
    };
    try continueAsyncDisposal(vm, state, null);
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
    const s_nt = vm.new_target;
    const s_eval_nt = vm.direct_eval_new_target_allowed;
    const s_cur_module = vm.cur_module;
    vm.env = g.env;
    vm.this_value = g.this_value;
    vm.home_object = g.home_object;
    vm.super_ctor = g.super_ctor;
    vm.new_target = Value.undef();
    vm.direct_eval_new_target_allowed = true;
    vm.cur_module = g.module_referrer;
    defer {
        vm.env = s_env;
        vm.this_value = s_this;
        vm.home_object = s_home;
        vm.super_ctor = s_super;
        vm.new_target = s_nt;
        vm.direct_eval_new_target_allowed = s_eval_nt;
        vm.cur_module = s_cur_module;
    }
    try vm.stackGuard();
    vm.depth += 1;
    defer vm.depth -= 1;

    const v = execLoop(vm, &g.exec, g.chunk, null, g) catch |e| {
        if (e != error.Throw) return e;
        g.done = true;
        const reason = vm.exception;
        vm.exception = Value.undef();
        // DisposeResources for the body's `using` resources, threading the error.
        if (g.env.disposables.items.len > 0) {
            try completeAsyncWithDisposal(vm, g, Value.undef(), reason);
            return;
        }
        try promise.reject(vm, resultPromise(g), reason);
        return;
    };
    if (g.suspended) {
        // `await v`: Await first performs PromiseResolve(%Promise%, v), which is
        // observable through a promise's `.constructor` getter, then resumes when
        // that wrapper settles.
        g.suspended = false;
        const awaited = interp.promiseResolveValue(vm, v) catch |err| {
            if (err != error.Throw) return err;
            const reason = vm.exception;
            vm.exception = Value.undef();
            g.done = true;
            try promise.reject(vm, resultPromise(g), reason);
            return;
        };
        const onf = try gc_mod.allocObj(vm.arena);
        onf.* = .{ .native = asyncOnFulfill, .private_data = @ptrCast(g) };
        const onr = try gc_mod.allocObj(vm.arena);
        onr.* = .{ .native = asyncOnReject, .private_data = @ptrCast(g) };
        _ = try promise.then(vm, @ptrCast(@alignCast(awaited.asObj().promise.?)), Value.obj(onf), Value.obj(onr));
        return;
    }
    g.done = true;
    // DisposeResources for the body's top-level `using` resources at completion.
    if (g.env.disposables.items.len > 0) {
        try completeAsyncWithDisposal(vm, g, v, null);
        return;
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
    try genv.put("arguments", try vm.createArgumentsObject(func, args, genv));
    const bound_this = try bindThisForCall(vm, func, this_val);
    const saved_env = vm.env;
    const saved_this = vm.this_value;
    const saved_home = vm.home_object;
    const saved_super = vm.super_ctor;
    const saved_this_initialized = vm.this_initialized;
    const saved_nt = vm.new_target;
    const saved_eval_nt = vm.direct_eval_new_target_allowed;
    vm.env = genv;
    vm.this_value = bound_this;
    vm.home_object = func.home_object;
    vm.super_ctor = func.super_ctor;
    vm.this_initialized = true;
    vm.new_target = Value.undef();
    vm.direct_eval_new_target_allowed = true;
    defer {
        vm.env = saved_env;
        vm.this_value = saved_this;
        vm.home_object = saved_home;
        vm.super_ctor = saved_super;
        vm.this_initialized = saved_this_initialized;
        vm.new_target = saved_nt;
        vm.direct_eval_new_target_allowed = saved_eval_nt;
    }
    try vm.bindParams2(func.params, args, func.is_arrow);
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
        .import_meta_slot = func.import_meta_slot,
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
        try g.appendRequest(vm.arena, .{ .kind = kind, .value = val, .result = rp });
        if (!g.pumping) {
            g.pumping = true;
            if (g.done)
                start_done = true
            else
                start_req = g.frontRequest();
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

const AgStep = union(enum) { awaited: Value, yielded: Value, returned: Value, returned_await: Value, threw: Value };

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
                } else return .{ .returned_await = val };
            },
        }
    } else switch (kind) {
        // Not yet started: `next` runs the body from the top, but `return`/`throw`
        // complete the generator immediately without ever executing the body.
        .send => {},
        .return_ => {
            g.done = true;
            return .{ .returned_await = val };
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
    const s_import_meta_slot = vm.import_meta_slot;
    const s_import_meta_obj = vm.import_meta_obj;
    const s_nt = vm.new_target;
    const s_eval_nt = vm.direct_eval_new_target_allowed;
    vm.env = g.env;
    vm.this_value = g.this_value;
    vm.home_object = g.home_object;
    vm.super_ctor = g.super_ctor;
    vm.import_meta_slot = g.import_meta_slot;
    vm.import_meta_obj = if (g.import_meta_slot) |slot| slot.obj else null;
    vm.new_target = Value.undef();
    vm.direct_eval_new_target_allowed = true;
    defer {
        vm.env = s_env;
        vm.this_value = s_this;
        vm.home_object = s_home;
        vm.super_ctor = s_super;
        vm.import_meta_slot = s_import_meta_slot;
        vm.import_meta_obj = s_import_meta_obj;
        vm.new_target = s_nt;
        vm.direct_eval_new_target_allowed = s_eval_nt;
    }
    try vm.stackGuard();
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
    if (!g.hasPendingRequest()) {
        g.pumping = false;
        return null;
    }
    return g.frontRequest();
}

fn agRemoveFrontAndContinue(vm: *Interpreter, g: *Generator) EvalError!void {
    var next_req: ?AsyncGenRequest = null;
    var drain_done = false;
    g.requests_mutex.lockUncancelable(agent.engineIo());
    _ = g.popRequest();
    if (g.done)
        drain_done = true
    else if (g.frontRequest()) |front|
        next_req = front
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
            const wrapped = interp.promiseResolveValue(vm, awaited) catch |err| {
                if (err != error.Throw) return err;
                const reason = vm.exception;
                vm.exception = Value.undef();
                return agStep(vm, g, .throw_, reason);
            };
            const onf = try gc_mod.allocObj(vm.arena);
            onf.* = .{ .native = agOnFulfill, .private_data = @ptrCast(g) };
            const onr = try gc_mod.allocObj(vm.arena);
            onr.* = .{ .native = agOnReject, .private_data = @ptrCast(g) };
            _ = try promise.then(vm, @ptrCast(@alignCast(wrapped.asObj().promise.?)), Value.obj(onf), Value.obj(onr));
        },
        .yielded => |v| {
            try promise.resolve(vm, @ptrCast(@alignCast(front.promise.?)), try makeIterResult(vm, v, false));
            try agRemoveFrontAndContinue(vm, g);
        },
        .returned => |v| {
            g.done = true;
            try promise.resolve(vm, @ptrCast(@alignCast(front.promise.?)), try makeIterResult(vm, v, true));
            try agRemoveFrontAndContinue(vm, g);
        },
        .returned_await => |v| {
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
    if (!g.hasPendingRequest()) {
        g.requests_mutex.unlock(agent.engineIo());
        return;
    }
    g.pumping = true;
    if (g.done)
        drain_done = true
    else
        req = g.frontRequest();
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
        const req = g.popRequest() orelse {
            g.pumping = false;
            g.requests_mutex.unlock(agent.engineIo());
            break;
        };
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
    _ = g.popRequest();
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
    _ = g.popRequest();
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
/// closure's upvalue source. Templates with a compiled `chunk` take the VM path;
/// env-mode templates may leave it null and use the tree-walker body fallback.
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
        .import_meta_slot = vm.import_meta_slot,
        .module_referrer = vm.cur_module,
        .chunk = if (tmpl.is_generator or tmpl.is_async) null else tmpl.chunk,
        .gen_chunk = if (tmpl.is_generator) tmpl.chunk else null,
        .frame = frame,
        .local_count = tmpl.local_count,
        .is_method = tmpl.is_method,
        // An arrow captures `this`/`new.target`/`super`/field-init context
        // LEXICALLY at creation — exactly like the tree-walker's makeFunction.
        .is_arrow = tmpl.is_arrow,
        .arrow_this = if (tmpl.is_arrow) vm.this_value else Value.undef(),
        .arrow_new_target = if (tmpl.is_arrow) vm.new_target else Value.undef(),
        .arrow_direct_eval_new_target_allowed = tmpl.is_arrow and vm.direct_eval_new_target_allowed,
        .arrow_in_derived_ctor = tmpl.is_arrow and vm.in_derived_ctor,
        .home_object = if (tmpl.is_arrow) vm.home_object else null,
        .super_ctor = if (tmpl.is_arrow) vm.super_ctor else null,
        .field_init_ctx = tmpl.is_arrow and vm.in_field_initializer,
    };
    // The closure can reach `frame` and all its ancestors via the upvalue walk,
    // so their slots may now be touched concurrently — mark the chain escaped so
    // load/store_{local,upval} serialize on those frames (no-GIL only).
    if (frame) |fr| fr.markEscapedChain();
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
                if (func.chunk) |fchunk| return runFunction(vm, func, fchunk, args, this_val, Value.undef());
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
            // Arrows, concise methods, generators, and async functions have no
            // [[Construct]] — `new` on them is a TypeError even though they carry a
            // bytecode chunk. Mirror the tree-walker's constructNT check before the
            // chunk shortcut (a plain-function chunk is the only constructible one).
            if (func.is_arrow or func.is_method or func.is_generator or func.is_async)
                return vm.throwError("TypeError", "value is not a constructor");
            if (func.chunk) |fchunk| {
                const this_val = try vm.newInstance(callee.asObj());
                const ret = try runFunction(vm, func, fchunk, args, this_val, callee);
                return if (ret.isObject()) ret else this_val;
            }
        }
    }
    return vm.construct(callee, args);
}

/// A single JS-chunk activation for the call trampoline: its own operand
/// `exec`, the bytecode `chunk`/`frame` it runs, and the *caller* VM state to
/// restore when it is popped. Deep JS→JS recursion pushes these onto an explicit
/// heap stack (`runDriver`) instead of the native call stack, so recursion is
/// bounded by the logical `max_call_depth` cap / heap rather than the OS stack.
const Activation = struct {
    exec: Exec = .{},
    chunk: *Chunk,
    frame: *Frame,
    // The operand-stack index in the *caller* where this call's result lands
    // (callee + args were popped off before the call ran). Unused for the
    // driver's initial activation.
    result_base: usize = 0,
    // Caller VM state, restored by `popActivation`.
    saved_this: Value,
    saved_strict: bool,
    saved_env: *Environment,
    saved_nt: Value,
    saved_ims: ?*interp.ImportMetaSlot,
    saved_imo: ?*value.Object,
    saved_cur_module: []const u8,
    saved_eval_nt: bool,
    saved_pm: ?*const std.StringHashMapUnmanaged([]const u8),
};

/// Allocate a callee activation (frame + slots from `args`), capture the caller
/// VM state into it, and install the callee's VM state. Does not run anything.
/// On a throw from `bindThisForCall` the caller state is restored before
/// propagating, so the caller is never left with the callee's state.
fn buildActivation(vm: *Interpreter, func: *Function, fchunk: *Chunk, args: []const Value, this_val: Value, new_target: Value) EvalError!*Activation {
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
    const act = try vm.arena.create(Activation);
    act.* = .{
        .chunk = fchunk,
        .frame = frame,
        .saved_this = vm.this_value,
        .saved_strict = vm.strict,
        .saved_env = vm.env,
        .saved_nt = vm.new_target,
        .saved_ims = vm.import_meta_slot,
        .saved_imo = vm.import_meta_obj,
        .saved_cur_module = vm.cur_module,
        .saved_eval_nt = vm.direct_eval_new_target_allowed,
        .saved_pm = vm.current_private_map,
    };
    if (!func.is_arrow) vm.current_private_map = func.private_map; // a direct eval here resolves the class's private names
    vm.strict = func.is_strict;
    // Free variables (globals, and a named function expression's self name)
    // resolve through `vm.env`; install the closure's defining environment.
    vm.env = func.closure;
    vm.new_target = if (func.is_arrow) func.arrow_new_target else new_target;
    vm.direct_eval_new_target_allowed = if (func.is_arrow) func.arrow_direct_eval_new_target_allowed else true;
    vm.import_meta_slot = func.import_meta_slot;
    vm.import_meta_obj = if (func.import_meta_slot) |slot| slot.obj else null;
    vm.cur_module = func.module_referrer;
    vm.this_value = bindThisForCall(vm, func, this_val) catch |e| {
        popActivation(vm, act);
        return e;
    };
    return act;
}

/// Restore the caller VM state captured by `buildActivation`.
fn popActivation(vm: *Interpreter, act: *Activation) void {
    vm.this_value = act.saved_this;
    vm.strict = act.saved_strict;
    vm.env = act.saved_env;
    vm.new_target = act.saved_nt;
    vm.import_meta_slot = act.saved_ims;
    vm.import_meta_obj = act.saved_imo;
    vm.cur_module = act.saved_cur_module;
    vm.direct_eval_new_target_allowed = act.saved_eval_nt;
    vm.current_private_map = act.saved_pm;
}

fn inheritCallerState(dst: *Activation, src: *const Activation) void {
    dst.saved_this = src.saved_this;
    dst.saved_strict = src.saved_strict;
    dst.saved_env = src.saved_env;
    dst.saved_nt = src.saved_nt;
    dst.saved_ims = src.saved_ims;
    dst.saved_imo = src.saved_imo;
    dst.saved_cur_module = src.saved_cur_module;
    dst.saved_eval_nt = src.saved_eval_nt;
    dst.saved_pm = src.saved_pm;
}

/// If `callee` is a plain JS-chunk function (not generator/async/native/bound/
/// proxy), return it — those are the calls the trampoline pushes onto its
/// activation stack. Everything else takes the native call path.
inline fn jsChunkFn(callee: Value) ?*Function {
    if (!callee.isObject()) return null;
    const erased = callee.asObj().js_func orelse return null;
    const func: *Function = @ptrCast(@alignCast(erased));
    if (func.is_generator or func.is_async) return null;
    if (func.chunk == null) return null;
    return func;
}

/// Unwind a throw over the activation stack: pop activations that have no
/// matching handler (restoring caller VM state and logical depth), and resume
/// the first that does at its catch/finally. Returns true when a handler was
/// found (the top activation is now positioned there), false when uncaught.
fn unwindThrow(vm: *Interpreter, acts: *std.ArrayListUnmanaged(*Activation)) EvalError!bool {
    while (acts.items.len > 0) {
        const cur = acts.items[acts.items.len - 1];
        if (cur.exec.handlers.items.len > 0) {
            const h = cur.exec.handlers.pop().?;
            cur.exec.stack.shrinkRetainingCapacity(h.stack_depth);
            try cur.exec.stack.append(vm.arena, vm.exception); // bind target for the catch
            if (h.catch_pc != Handler.none) {
                cur.exec.ip = h.catch_pc;
            } else {
                // No catch: run the finally carrying a "throw" completion.
                try cur.exec.stack.append(vm.arena, Value.num(@floatFromInt(@intFromEnum(Completion.throw))));
                cur.exec.ip = h.finally_pc;
            }
            return true;
        }
        vm.popExecRoot(&cur.exec);
        popActivation(vm, cur);
        _ = acts.pop();
        if (acts.items.len == 0) return false; // uncaught; initial depth owned by runFunction
        vm.depth -= 1; // a nested activation was discarded
    }
    return false;
}

/// Drive an explicit stack of JS-chunk activations for `initial` and any nested
/// plain JS→JS calls it makes, so deep recursion lives on the heap instead of
/// the OS call stack. Native-fn boundaries still recurse natively (bounded) and
/// re-enter here via a nested `runFunction`. Mirrors `execLoop`'s GC-root
/// registration and throw→handler unwinding, but over the activation stack.
/// `initial`'s logical depth is owned by `runFunction`; nested activations
/// account for their own here (and hit the `max_call_depth` ceiling, no longer
/// the native stack — the trampoline's whole point).
fn runDriver(vm: *Interpreter, initial: *Activation) EvalError!Value {
    const saved_active = vm.driver_active;
    vm.driver_active = true;
    defer vm.driver_active = saved_active;

    var acts: std.ArrayListUnmanaged(*Activation) = .empty;
    defer acts.deinit(vm.arena);
    initial.exec.frame = initial.frame;
    vm.pushExecRoot(&initial.exec);
    try acts.append(vm.arena, initial);

    while (acts.items.len > 0) {
        const cur = acts.items[acts.items.len - 1];
        const rv = runChunk(vm, &cur.exec, cur.chunk, cur.frame, null) catch |e| {
            if (e != error.Throw) {
                // OOM / OptShortCircuit: tear down all activations and propagate.
                while (acts.items.len > 0) {
                    const a = acts.items[acts.items.len - 1];
                    vm.popExecRoot(&a.exec);
                    popActivation(vm, a);
                    _ = acts.pop();
                    if (acts.items.len > 0) vm.depth -= 1;
                }
                return e;
            }
            if (try unwindThrow(vm, &acts)) continue; // resumed at a handler
            return error.Throw; // uncaught → propagate to the native caller
        };
        if (vm.pending_activation) |raw| {
            // A nested plain JS→JS call: push it instead of recursing natively.
            vm.pending_activation = null;
            const tail_call = vm.pending_tail_call;
            vm.pending_tail_call = false;
            const callee: *Activation = @ptrCast(@alignCast(raw));
            if (tail_call) {
                const current = acts.items[acts.items.len - 1];
                inheritCallerState(callee, current);
                vm.popExecRoot(&current.exec);
                _ = acts.pop();
            } else {
                if (vm.depth >= interp.max_call_depth) {
                    _ = vm.throwError("RangeError", "Maximum call stack size exceeded") catch {};
                    if (try unwindThrow(vm, &acts)) continue;
                    return error.Throw;
                }
                vm.depth += 1;
            }
            callee.exec.frame = callee.frame;
            vm.pushExecRoot(&callee.exec);
            try acts.append(vm.arena, callee);
            continue;
        }
        // A real return with value `rv`.
        vm.popExecRoot(&cur.exec);
        popActivation(vm, cur);
        _ = acts.pop();
        if (acts.items.len == 0) return rv; // initial returned; runFunction owns its depth
        vm.depth -= 1; // a nested activation completed
        const caller = acts.items[acts.items.len - 1];
        try caller.exec.stack.append(vm.arena, rv); // deliver result to the caller's operand stack
        // loop: resume `caller` at its flushed ip with `rv` on its stack
    }
    unreachable;
}

pub fn runFunction(vm: *Interpreter, func: *Function, fchunk: *Chunk, args: []const Value, this_val: Value, new_target: Value) EvalError!Value {
    try vm.stackGuard();
    vm.depth += 1;
    defer vm.depth -= 1;
    const act = try buildActivation(vm, func, fchunk, args, this_val, new_target);
    return runDriver(vm, act);
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

test "vm: recursive calls throw a catchable RangeError before native stack overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = try Parser.init(a,
        \\function recurse(n) { return recurse(n + 1); }
        \\recurse(0)
    );
    const prog = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(a, prog);
    var env = Environment{ .arena = a, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(a);
    try interp.installGlobals(&env, root_shape);
    var machine = Interpreter{ .arena = a, .env = &env, .root_shape = root_shape };

    try std.testing.expectError(error.Throw, run(&machine, chunk, null));
    const exception = machine.exception;
    try std.testing.expect(!exception.isUndefined());
    try std.testing.expect(exception.isObject());
    try std.testing.expectEqualStrings("RangeError", exception.asObj().error_name);
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

test "vm: generator new.target is undefined across eval and arrows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try vmRun(a,
        \\function *g() {
        \\  if (new.target !== undefined) yield "bad-new";
        \\  if (eval("new.target") !== undefined) yield "bad-eval";
        \\  if ((() => new.target)() !== undefined) yield "bad-arrow";
        \\  yield (() => new.target);
        \\}
        \\let f = g().next().value;
        \\typeof f === "function" && f() === undefined
    )).asBool());
}

test "vm: generator destructuring declaration defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("foo|bar|0,2", (try vmRun(a,
        \\function *g() {
        \\  var [a = "foo", b = `bar`, ...rest] = [];
        \\  yield a + "|" + b + "|" + rest.length;
        \\  var [{ x: [c = "no"] }] = [{ x: [2, 3] }];
        \\  yield c;
        \\}
        \\let it = g();
        \\it.next().value + "," + it.next().value
    )).asStr());
    try std.testing.expectEqualStrings("need|got", (try vmRun(a,
        \\function *g() {
        \\  var [a = yield "need"] = [];
        \\  yield a;
        \\}
        \\let it = g();
        \\it.next().value + "|" + it.next("got").value
    )).asStr());
}

test "vm: generator return closes suspended for-of iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try vmRun(a,
        \\var returnCalled = 0;
        \\var iter = {};
        \\iter[Symbol.iterator] = function () { return this; };
        \\iter.next = function () { return { value: 10, done: false }; };
        \\iter.return = function () { returnCalled++; return {}; };
        \\function *g() {
        \\  for (const x of iter) {
        \\    yield x;
        \\  }
        \\}
        \\var it = g();
        \\var first = it.next();
        \\var finished = it.return("stop");
        \\first.value === 10 && finished.value === "stop" && finished.done === true && returnCalled === 1
    )).asBool());
}

test "vm: generator finally break preserves outer return completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 42), (try vmRun(a,
        \\function *g() {
        \\  try {
        \\    return 42;
        \\  } finally {
        \\    do try {
        \\      return 43;
        \\    } finally {
        \\      break;
        \\    } while (0);
        \\  }
        \\}
        \\g().next().value
    )).asNum());
    try std.testing.expectEqual(@as(f64, 43), (try vmRun(a,
        \\function *g() {
        \\  L: try {
        \\    return 42;
        \\  } finally {
        \\    break L;
        \\  }
        \\  return 43;
        \\}
        \\g().next().value
    )).asNum());
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

test "vm: `var x = init` inside `with` resolves the binding through the with object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ResolveBinding finds the `with` object's own `a`, so the initializer's
    // PutValue writes there — the hoisted `var a` is left untouched.
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(a,
        \\var o = { a: 1 }; with (o) { var a = 9; } o.a
    )).asNum());
    // The outer hoisted `a` keeps its value (the write did NOT fall through).
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(a,
        \\var o = { a: 1 }; var a = 1; with (o) { var a = 9; } a
    )).asNum());
    // A bare `var a;` (no initializer, b == 0) never redirects: no PutValue.
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(a,
        \\var o = { a: 1 }; with (o) { var a; } o.a
    )).asNum());
    // No own property → the write targets the outer/global var, as before.
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(a,
        \\var a = 1; with ({}) { var a = 9; } a
    )).asNum());
    // `[Symbol.unscopables]` hides `a` from `with` scope, so the write falls
    // through to the outer var and the object property is untouched.
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(a,
        \\var o = { a: 1 }; o[Symbol.unscopables] = { a: true };
        \\with (o) { var a = 9; } o.a
    )).asNum());
}

test "vm: compiler lowers try/catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), (try vmRun(a,
        \\let x = 0;
        \\try { throw 3; } catch (e) { x = e; }
        \\x
    )).asNum());
}
