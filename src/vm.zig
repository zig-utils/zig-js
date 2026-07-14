//! Tier-1 bytecode VM for zig-js.
//!
//! Executes a compiled `Chunk` against an `Interpreter`'s live state — the same
//! `Environment` chain, `this`, `exception`, and helper routines the tree-walker
//! uses. That sharing is deliberate: the VM is a faster *execution strategy*,
//! not a second semantics. Variable access still goes through the environment
//! (turning names into slot indexes is the next perf tier); what we remove here
//! is AST recursion and per-node dispatch.
//!
//! Plain VM-to-VM calls use an explicit heap activation stack so logical JS
//! recursion does not consume the host stack. Tree-walk-only and native callees
//! are delegated to `Interpreter`; generator/async bodies retain their own
//! resumable execution state.

const std = @import("std");
const builtin = @import("builtin");
const gc_mod = @import("gc.zig");
const ast = @import("ast.zig");
const bc = @import("bytecode.zig");
const value = @import("value.zig");
const interp = @import("interpreter.zig");
const promise = @import("promise.zig");
const agent = @import("agent.zig");
const gc_runtime = @import("gc_runtime.zig");
const jit = @import("jit.zig");
const jit_compiler = @import("jit/compiler.zig");

const Value = value.Value;
const Chunk = bc.Chunk;
const Shape = @import("shape.zig").Shape;
const Interpreter = interp.Interpreter;
const Environment = interp.Environment;
const Function = interp.Function;
const EvalError = interp.EvalError;

const async_gen_request_reserve_granularity: usize = 16;
const native_tier_entry_threshold: u32 = 3;
const eager_native_tier_entry_threshold: u32 = 1;
const inline_call_depth_limit: u8 = 32;

fn bindThisForCall(vm: *Interpreter, func: *Function, this_val: Value) EvalError!Value {
    if (func.is_arrow) return func.arrow_this;
    if (func.is_strict) return this_val;
    if (this_val.isNull() or this_val.isUndefined()) {
        if (func.realm_global) |global| return Value.obj(global);
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

/// The VM operand stack has a much hotter append path than a general-purpose
/// ArrayList: almost every bytecode instruction pushes at least one Value. The
/// standard unmanaged append calls ensureTotalCapacity even when capacity is
/// already available; profiles attributed roughly a third of arithmetic VM
/// samples to that call/check boundary. Keep ArrayList growth semantics on the
/// rare full-capacity path, but make the common append one inlined comparison
/// and one store.
const OperandStack = struct {
    items: []Value = &.{},
    capacity: usize = 0,

    pub const empty: OperandStack = .{};

    pub inline fn append(self: *OperandStack, allocator: std.mem.Allocator, item: Value) std.mem.Allocator.Error!void {
        if (self.items.len == self.capacity) try self.grow(allocator);
        self.items.len += 1;
        self.items[self.items.len - 1] = item;
    }

    noinline fn grow(self: *OperandStack, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        var list: std.ArrayListUnmanaged(Value) = .{
            .items = self.items,
            .capacity = self.capacity,
        };
        try list.ensureTotalCapacity(allocator, self.items.len + 1);
        self.items = list.items;
        self.capacity = list.capacity;
    }

    pub inline fn pop(self: *OperandStack) ?Value {
        if (self.items.len == 0) return null;
        const item = self.items[self.items.len - 1];
        self.items.len -= 1;
        return item;
    }

    pub inline fn shrinkRetainingCapacity(self: *OperandStack, new_len: usize) void {
        std.debug.assert(new_len <= self.items.len);
        self.items.len = new_len;
    }

    pub inline fn clearRetainingCapacity(self: *OperandStack) void {
        self.items.len = 0;
    }

    pub fn deinit(self: *OperandStack, allocator: std.mem.Allocator) void {
        var list: std.ArrayListUnmanaged(Value) = .{
            .items = self.items,
            .capacity = self.capacity,
        };
        list.deinit(allocator);
        self.* = .empty;
    }
};

/// A resumable execution state: the operand stack, completion accumulator, and
/// instruction pointer. For a normal call this lives on the host stack and is
/// thrown away when `run` returns; for a generator it lives in the `Generator`
/// and persists across `yield`/resume, which is what makes suspension faithful
/// (the whole operand stack is saved, so a `yield` can sit mid-expression).
pub const Exec = struct {
    stack: OperandStack = .empty,
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

fn completionKindBelowTop(stack: *const OperandStack) ?Completion {
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
    /// Resume ownership. Ordinary generators also hold `resume_mutex` to
    /// preserve the re-entrant TypeError; async functions use this atomic as a
    /// release/acquire handoff between promise jobs drained by different
    /// shared-realm threads.
    running: std.atomic.Value(bool) = .init(false),
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

    fn lockRequests(self: *Generator) void {
        self.requests_mutex.lockUncancelable(agent.engineIo());
        gc_runtime.enterTraceSensitiveLock();
    }

    fn unlockRequests(self: *Generator) void {
        gc_runtime.leaveTraceSensitiveLock();
        self.requests_mutex.unlock(agent.engineIo());
    }

    fn claimAsyncResume(self: *Generator) void {
        var spins: usize = 0;
        while (self.running.cmpxchgWeak(false, true, .acquire, .monotonic) != null) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }

    fn releaseAsyncResume(self: *Generator) void {
        self.running.store(false, .release);
    }

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

test "async generator request lock is trace-sensitive" {
    var g = Generator{
        .chunk = undefined,
        .env = undefined,
    };

    try std.testing.expect(!gc_runtime.inTraceSensitiveLock());
    g.lockRequests();
    defer g.unlockRequests();
    try std.testing.expect(gc_runtime.inTraceSensitiveLock());
}

test "async function resume ownership is a release acquire handoff" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var g: Generator = undefined;
    g.running = .init(false);
    var completed: usize = 0;
    const Runner = struct {
        fn run(gen: *Generator, count: *usize) void {
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                gen.claimAsyncResume();
                count.* += 1;
                gen.releaseAsyncResume();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Runner.run, .{ &g, &completed });
    for (&threads) |*thread| thread.join();
    try std.testing.expectEqual(@as(usize, 4000), completed);
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

/// Number remainder keeps the full IEEE/ECMAScript path for zero (including
/// negative zero), negative/fractional values, infinities, and large integers.
/// Hot loop counters and positive small moduli can use integer remainder,
/// avoiding the out-of-line fmod call while producing the same exact Number.
inline fn numberRemainder(a: f64, b: f64) f64 {
    const max_u32: f64 = @floatFromInt(std.math.maxInt(u32));
    if (a > 0 and a <= max_u32 and b > 0 and b <= max_u32 and @trunc(a) == a and @trunc(b) == b) {
        const lhs: u32 = @intFromFloat(a);
        const rhs: u32 = @intFromFloat(b);
        return @floatFromInt(lhs % rhs);
    }
    return @rem(a, b);
}

inline fn exactNonNegativeU32(number: f64, allow_zero: bool) ?u32 {
    if (!std.math.isFinite(number) or @trunc(number) != number or
        number < @as(f64, if (allow_zero) 0 else 1) or
        number > @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return null;
    return @intFromFloat(number);
}

/// ToInt32 over an already-numeric quick-path value. Small exact unsigned
/// values are the overwhelmingly common case and need neither Value boxing nor
/// the generic modulo calculation; every other Number retains the full
/// ECMAScript conversion.
inline fn quickNumberToInt32(number: f64) i32 {
    if (exactNonNegativeU32(number, true)) |integer| return @bitCast(integer);
    return @bitCast(Value.uint32FromF64(number));
}

const max_quick_property_instructions: usize = 20;
const max_quick_property_stack: usize = 8;
const max_quick_property_ops: usize = 8;

const QuickPropertyUpdate = struct {
    extra_steps: u8,
    next_ip: usize,
};

const QuickPropertyOperand = struct {
    local: u32,
    instruction: u32,
};

const QuickNumericOp = union(enum) {
    constant: f64,
    local: u32,
    property: QuickPropertyOperand,
    add,
    sub,
    mul,
    div,
    mod,
};

const QuickLoopTail = struct {
    counter_local: u32,
    delta: f64,
    arithmetic: bc.Op,
    bound: f64,
    comparison: bc.Op,
    body_ip: u32,
    exit_ip: u32,
};

const QuickPropertyLocalMod = struct {
    property: QuickPropertyOperand,
    local: u32,
    modulus: f64,
};

const QuickPropertyConstant = struct {
    property: QuickPropertyOperand,
    constant: f64,
};

const QuickPropertyPair = struct {
    left: QuickPropertyOperand,
    right: QuickPropertyOperand,
};

const QuickPropertySpecialization = union(enum) {
    generic,
    property_local_add_mod: QuickPropertyLocalMod,
    property_add_constant: QuickPropertyConstant,
    property_pair_add: QuickPropertyPair,
    property_pair_sub: QuickPropertyPair,
};

const QuickResolvedSlots = struct {
    first: usize,
    second: usize,
    target: usize,
};

const QuickPropertyPlan = struct {
    target_local: u32,
    target_instruction: u32,
    ops: [max_quick_property_ops]QuickNumericOp,
    op_count: u8,
    executed: u8,
    next_ip: u32,
    tail: ?QuickLoopTail,
    specialization: QuickPropertySpecialization,
    resolved_shape: ?*Shape,
    resolved_read_slots: [2]u32,
    resolved_target_slot: u32,
};

const QuickPropertyKernelPlan = union(enum) {
    unsupported,
    four_property_loop: struct {
        object_local: u32,
        counter_local: u32,
        bound: f64,
        modulus: f64,
        property_increment: f64,
        counter_increment: f64,
        read_instructions: [6]u32,
        write_instructions: [4]u32,
        exit_ip: u32,
    },
};

const QuickPropertyKernelUpdate = struct {
    extra_steps: u64,
    next_ip: usize,
};

const QuickPackedArraySumLoop = struct {
    index_local: u32,
    array_local: u32,
    total_local: u32,
    increment: f64,
};

const max_quick_array_expression_ops = 16;
const max_quick_array_expression_stack = 8;

const QuickArrayNumericOp = union(enum) {
    constant: f64,
    local: u32,
    add,
    sub,
    mul,
    div,
    mod,
    bit_and,
};

const QuickArrayBound = union(enum) {
    constant: f64,
    local: u32,
};

const QuickArrayAdd3BitAnd = struct {
    locals: [3]u32,
    mask: i32,
};

const QuickArrayExpressionSpecialization = union(enum) {
    generic,
    add3_bit_and: QuickArrayAdd3BitAnd,
};

const QuickPackedArrayPushLoop = struct {
    index_local: u32,
    array_local: u32,
    bound: QuickArrayBound,
    increment: f64,
    get_prop_instruction: u32,
    ops: [max_quick_array_expression_ops]QuickArrayNumericOp,
    op_count: u8,
    specialization: QuickArrayExpressionSpecialization,
    executed: u8,
};

const QuickPolymorphicPropertyLoop = struct {
    index_local: u32,
    array_local: u32,
    object_local: u32,
    value_local: u32,
    checksum_local: u32,
    extra_local: u32,
    bound: QuickArrayBound,
    selector_mask: i32,
    modulus: f64,
    checksum_mask: i32,
    increment: f64,
    get_prop_instruction: u32,
    set_prop_instruction: u32,
    exit_ip: u32,
};

const QuickObjectAllocationLoop = struct {
    counter_local: u32,
    array_local: u32,
    index_local: u32,
    displaced_local: u32,
    value_local: u32,
    fresh_local: u32,
    total_local: u32,
    extra_local: u32,
    bound: QuickArrayBound,
    selector_mask: i32,
    stamp_mask: i32,
    checksum_mask: i32,
    modulus: f64,
    increment: u32,
    displaced_property_instruction: u32,
    literal_instructions: [3]u32,
    exit_ip: u32,
    /// Isolated-mode cache of the immutable validated literal descriptor. A
    /// Chunk can cross realm entry, so the root shape is the exact cache key.
    prepared_root_shape: ?*Shape = null,
    prepared_literal_shape: ?value.PreparedInlineLiteralShape = null,
};

const QuickArrayPlan = union(enum) {
    unsupported,
    packed_sum: QuickPackedArraySumLoop,
    packed_push: QuickPackedArrayPushLoop,
    polymorphic_property: QuickPolymorphicPropertyLoop,
    object_allocation: QuickObjectAllocationLoop,
};

const max_quick_leaf_ops = 16;
const max_quick_leaf_stack = 8;

const QuickLeafOp = union(enum) {
    argument: u8,
    constant: f64,
    captured_local,
    receiver_property,
    add,
    sub,
    mul,
    div,
    mod,
};

const QuickLeafAddMod = struct {
    left: u8,
    right: u8,
    modulus: f64,
};

const QuickLeafReceiverAddMod = struct {
    first: u8,
    second: u8,
    modulus: f64,
};

const QuickLeafCapturedAddMod = struct {
    argument: u8,
    modulus: f64,
};

const QuickLeafSpecialization = union(enum) {
    generic,
    add_mod: QuickLeafAddMod,
    captured_add_mod: QuickLeafCapturedAddMod,
    receiver_add_mod: QuickLeafReceiverAddMod,
};

const QuickNumericLeaf = struct {
    ops: [max_quick_leaf_ops]QuickLeafOp,
    op_count: u8,
    executed: u8,
    captured_local: ?u32,
    receiver_property_instruction: ?u32,
    specialization: QuickLeafSpecialization,
};

const QuickLeafPlan = union(enum) {
    unsupported,
    numeric: QuickNumericLeaf,
};

const QuickCallCallee = union(enum) {
    global_instruction: u32,
    local: u32,
    method: struct {
        receiver_local: u32,
        get_prop_instruction: u32,
    },
    closure_template: u32,
};

const QuickNumericCallLoop = struct {
    index_local: u32,
    value_local: u32,
    bound: QuickArrayBound,
    increment: f64,
    callee: QuickCallCallee,
    caller_steps: u8,
    exit_ip: u32,
};

const QuickCallLoopPlan = union(enum) {
    unsupported,
    numeric_leaf: QuickNumericCallLoop,
};

const QuickCallLoopUpdate = struct {
    extra_steps: u64,
    next_ip: usize,
};

const QuickGlobalBinding = union(enum) {
    object: struct {
        env: *Environment,
        object: *value.Object,
        shape: *Shape,
        slot: u32,
    },
    environment: struct {
        start: *Environment,
        binding: *Environment,
        name: []const u8,
    },
};

const QuickAddRecurrence = struct {
    threshold: u16,
    first_delta: u16,
    second_delta: u16,
    binding_instruction: u32,
};

const QuickObservableAddRecurrence = struct {
    threshold: u16,
    first_delta: u16,
    second_delta: u16,
    first_binding_instruction: u32,
    second_binding_instruction: u32,
    counter_read_instruction: u32,
    counter_write_instruction: u32,
    counter_name: u32,
    counter_increment: f64,
};

const QuickRecurrencePlan = union(enum) {
    unsupported,
    add: QuickAddRecurrence,
    observable_add: QuickObservableAddRecurrence,
};

// Test-only observations enforce that the optimized path remains reachable.
// The fetchAdd call is compile-time removed from production builds.
var quick_property_update_hits: std.atomic.Value(u64) = .init(0);
var quick_property_loop_tail_hits: std.atomic.Value(u64) = .init(0);
var quick_property_specialized_hits: std.atomic.Value(u64) = .init(0);
var quick_property_kernel_hits: std.atomic.Value(u64) = .init(0);
var quick_property_plan_decode_attempts: std.atomic.Value(u64) = .init(0);
var quick_dense_array_index_hits: std.atomic.Value(u64) = .init(0);
var quick_dense_array_store_hits: std.atomic.Value(u64) = .init(0);
var quick_array_length_hits: std.atomic.Value(u64) = .init(0);
var quick_array_prototype_data_hits: std.atomic.Value(u64) = .init(0);
var quick_array_push_hits: std.atomic.Value(u64) = .init(0);
var quick_packed_array_sum_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_packed_array_push_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_packed_array_specialized_expression_hits: std.atomic.Value(u64) = .init(0);
var quick_polymorphic_property_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_object_allocation_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_object_literal_shape_preparations: std.atomic.Value(u64) = .init(0);

pub fn quickObjectAllocationLoopHitsForTesting() u64 {
    std.debug.assert(builtin.is_test);
    return quick_object_allocation_loop_hits.load(.monotonic);
}

var quick_global_binding_hits: std.atomic.Value(u64) = .init(0);
var quick_literal_transition_hits: std.atomic.Value(u64) = .init(0);
var quick_native_direct_call_hits: std.atomic.Value(u64) = .init(0);
var quick_numeric_call_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_numeric_arguments_call_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_numeric_arguments_direct_call_hits: std.atomic.Value(u64) = .init(0);
var quick_numeric_closure_call_loop_hits: std.atomic.Value(u64) = .init(0);
var quick_reusable_immediate_closure_hits: std.atomic.Value(u64) = .init(0);
var quick_numeric_method_call_loop_hits: std.atomic.Value(u64) = .init(0);
var fast_number_bitwise_hits: std.atomic.Value(u64) = .init(0);
var quick_numeric_call_loop_test_enabled: std.atomic.Value(bool) = .init(true);
var quick_numeric_recurrence_hits: std.atomic.Value(u64) = .init(0);
var quick_observable_recurrence_hits: std.atomic.Value(u64) = .init(0);

inline fn quickPlainObject(value_: Value) ?*value.Object {
    if (!value_.isObject()) return null;
    const object = value_.asObj();
    if (object.is_array or object.accessors.load(.monotonic) != null or object.attrsMap() != null) return null;
    return object;
}

/// Resolve a direct data property on an Array prototype without walking the
/// full generic [[Get]] machinery. In shared mode both the receiver's own-data
/// exclusion and the prototype slot read are short property-lock snapshots;
/// the IC itself uses its seqlock publication mode.
fn quickArrayPrototypeData(
    chunk: *Chunk,
    instruction: usize,
    array: *value.Object,
    name: []const u8,
    parallel_sync: bool,
) ?Value {
    if (parallel_sync) array.lockProperties();
    const plain_receiver = array.accessors.load(.monotonic) == null and array.attrsMap() == null;
    const own_data = if (plain_receiver) if (array.shape) |shape| shape.lookup(name) else null else null;
    if (parallel_sync) array.unlockProperties();
    if (!plain_receiver or own_data != null) return null;

    const prototype = array.protoAtomic() orelse return null;
    if (prototype.proxy_handler != null or prototype.proxy_revoked) return null;
    if (parallel_sync) prototype.lockProperties();
    defer if (parallel_sync) prototype.unlockProperties();
    if (prototype.accessors.load(.monotonic) != null) return null;
    if (instruction >= chunk.ics.len) return null;
    const ic = &chunk.ics[instruction];
    const slot = ic.lookupSlotMode(prototype.shape, parallel_sync) orelse slot: {
        const shape = prototype.shape orelse return null;
        const resolved = shape.lookup(name) orelse return null;
        ic.recordMode(shape, resolved, parallel_sync);
        break :slot resolved;
    };
    if (slot >= prototype.slots.items.len) return null;
    return prototype.slots.items[slot];
}

inline fn quickArrayIndex(key: Value) ?usize {
    if (!key.isNumber()) return null;
    const number = key.asNum();
    if (!std.math.isFinite(number) or number < 0 or number >= 4294967295 or @trunc(number) != number) return null;
    return @intFromFloat(number);
}

inline fn quickDenseArrayStore(vm: *Interpreter, receiver: Value, key: Value, stored: Value) EvalError!bool {
    if (!receiver.isObject()) return false;
    const index = quickArrayIndex(key) orelse return false;
    const object = receiver.asObj();
    if (!object.is_array or object.is_arguments or object.proxy_handler != null or object.proxy_revoked or
        object.accessors.load(.monotonic) != null or object.attrsMap() != null or
        object.has_indexed_property.load(.monotonic))
        return false;
    try vm.checkRestricted(object);
    return object.replaceDenseElement(index, stored);
}

fn specializeQuickArrayExpression(ops: []const QuickArrayNumericOp) QuickArrayExpressionSpecialization {
    if (ops.len == 7) {
        const first = switch (ops[0]) {
            .local => |local| local,
            else => return .generic,
        };
        const second = switch (ops[1]) {
            .local => |local| local,
            else => return .generic,
        };
        if (ops[2] != .add) return .generic;
        const third = switch (ops[3]) {
            .local => |local| local,
            else => return .generic,
        };
        if (ops[4] != .add) return .generic;
        const mask = switch (ops[5]) {
            .constant => |number| number,
            else => return .generic,
        };
        if (ops[6] != .bit_and) return .generic;
        return .{ .add3_bit_and = .{
            .locals = .{ first, second, third },
            .mask = Value.num(mask).toInt32(),
        } };
    }
    return .generic;
}

fn compileQuickPackedArrayPushLoop(chunk: *Chunk, start: usize) ?QuickPackedArrayPushLoop {
    const code = chunk.code.items;
    if (start + 16 > code.len or
        code[start].op != .load_local or
        (code[start + 1].op != .load_const and code[start + 1].op != .load_local) or
        code[start + 2].op != .lt or
        code[start + 3].op != .jump_if_false or
        code[start + 4].op != .load_local or
        code[start + 5].op != .dup or
        code[start + 6].op != .get_prop or code[start + 6].a >= chunk.names.items.len or
        !std.mem.eql(u8, chunk.names.items[code[start + 6].a], "push") or
        code[start + 7].op != .swap)
        return null;

    const bound: QuickArrayBound = switch (code[start + 1].op) {
        .load_local => .{ .local = code[start + 1].a },
        .load_const => constant: {
            if (code[start + 1].a >= chunk.consts.items.len) return null;
            const value_ = chunk.consts.items[code[start + 1].a];
            if (!value_.isNumber()) return null;
            break :constant .{ .constant = value_.asNum() };
        },
        else => unreachable,
    };

    var ops: [max_quick_array_expression_ops]QuickArrayNumericOp = undefined;
    var op_count: usize = 0;
    var depth: usize = 0;
    var cursor = start + 8;
    while (cursor < code.len and code[cursor].op != .call_with_this) : (cursor += 1) {
        if (op_count == ops.len) return null;
        const op: QuickArrayNumericOp = switch (code[cursor].op) {
            .load_local => local: {
                depth += 1;
                break :local .{ .local = code[cursor].a };
            },
            .load_const => constant: {
                if (code[cursor].a >= chunk.consts.items.len) return null;
                const value_ = chunk.consts.items[code[cursor].a];
                if (!value_.isNumber()) return null;
                depth += 1;
                break :constant .{ .constant = value_.asNum() };
            },
            .add, .sub, .mul, .div, .mod, .bit_and => binary: {
                if (depth < 2) return null;
                depth -= 1;
                break :binary switch (code[cursor].op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    .bit_and => .bit_and,
                    else => unreachable,
                };
            },
            else => return null,
        };
        if (depth > max_quick_array_expression_stack) return null;
        ops[op_count] = op;
        op_count += 1;
    }
    if (cursor >= code.len or code[cursor].a != 1 or depth != 1 or cursor + 8 > code.len) return null;
    const exit = cursor + 8;
    const index_local = code[start].a;
    if (code[start + 3].a != exit or
        code[cursor + 1].op != .pop or
        code[cursor + 2].op != .load_local or code[cursor + 2].a != index_local or
        code[cursor + 3].op != .load_const or code[cursor + 3].a >= chunk.consts.items.len or
        code[cursor + 4].op != .add or
        code[cursor + 5].op != .store_local or code[cursor + 5].a != index_local or
        code[cursor + 6].op != .pop or
        code[cursor + 7].op != .jump or code[cursor + 7].a != start)
        return null;
    const increment = chunk.consts.items[code[cursor + 3].a];
    if (!increment.isNumber() or exit - start > std.math.maxInt(u8)) return null;
    return .{
        .index_local = index_local,
        .array_local = code[start + 4].a,
        .bound = bound,
        .increment = increment.asNum(),
        .get_prop_instruction = @intCast(start + 6),
        .ops = ops,
        .op_count = @intCast(op_count),
        .specialization = specializeQuickArrayExpression(ops[0..op_count]),
        .executed = @intCast(exit - start),
    };
}

fn compileQuickPolymorphicPropertyLoop(chunk: *Chunk, start: usize) ?QuickPolymorphicPropertyLoop {
    const code = chunk.code.items;
    if (start + 38 > code.len) return null;
    const expected = [_]bc.Op{
        .load_local, .load_const,  .lt,          .jump_if_false,
        .load_local, .load_local,  .load_const,  .bit_and,
        .get_index,  .store_local, .pop,         .load_local,
        .get_prop,   .load_local,  .add,         .load_local,
        .add,        .load_const,  .mod,         .store_local,
        .pop,        .load_local,  .load_local,  .set_prop,
        .pop,        .load_local,  .load_local,  .load_const,
        .bit_and,    .add,         .store_local, .pop,
        .load_local, .load_const,  .add,         .store_local,
        .pop,        .jump,
    };
    for (expected, 0..) |op, offset|
        if (offset != 1 and code[start + offset].op != op) return null;

    const index_local = code[start].a;
    const object_local = code[start + 9].a;
    const value_local = code[start + 19].a;
    const checksum_local = code[start + 25].a;
    const locals = [_]u32{
        index_local,    code[start + 4].a,  object_local, value_local,
        checksum_local, code[start + 15].a,
    };
    for (locals, 0..) |local, left|
        for (locals[left + 1 ..]) |other| if (local == other) return null;
    if (code[start + 3].a != start + expected.len or
        code[start + 5].a != index_local or
        code[start + 11].a != object_local or code[start + 21].a != object_local or
        code[start + 13].a != index_local or
        code[start + 22].a != value_local or code[start + 26].a != value_local or
        code[start + 30].a != checksum_local or
        code[start + 32].a != index_local or code[start + 35].a != index_local or
        code[start + 37].a != start or
        code[start + 12].a >= chunk.names.items.len or code[start + 23].a >= chunk.names.items.len or
        !std.mem.eql(u8, chunk.names.items[code[start + 12].a], chunk.names.items[code[start + 23].a]))
        return null;

    const bound: QuickArrayBound = switch (code[start + 1].op) {
        .load_local => .{ .local = code[start + 1].a },
        .load_const => constant: {
            if (code[start + 1].a >= chunk.consts.items.len) return null;
            const value_ = chunk.consts.items[code[start + 1].a];
            if (!value_.isNumber()) return null;
            break :constant .{ .constant = value_.asNum() };
        },
        else => return null,
    };
    switch (bound) {
        .local => |local| for (locals[0..5]) |modified| {
            if (local == modified) return null;
        },
        .constant => {},
    }
    const constant_instructions = [_]usize{ start + 6, start + 17, start + 27, start + 33 };
    var constants: [4]f64 = undefined;
    for (constant_instructions, 0..) |instruction, index| {
        const constant_index = code[instruction].a;
        if (constant_index >= chunk.consts.items.len or !chunk.consts.items[constant_index].isNumber()) return null;
        constants[index] = chunk.consts.items[constant_index].asNum();
    }
    return .{
        .index_local = index_local,
        .array_local = code[start + 4].a,
        .object_local = object_local,
        .value_local = value_local,
        .checksum_local = checksum_local,
        .extra_local = code[start + 15].a,
        .bound = bound,
        .selector_mask = Value.num(constants[0]).toInt32(),
        .modulus = constants[1],
        .checksum_mask = Value.num(constants[2]).toInt32(),
        .increment = constants[3],
        .get_prop_instruction = @intCast(start + 12),
        .set_prop_instruction = @intCast(start + 23),
        .exit_ip = @intCast(start + expected.len),
    };
}

fn compileQuickObjectAllocationLoop(chunk: *Chunk, start: usize) ?QuickObjectAllocationLoop {
    const code = chunk.code.items;
    const expected = [_]bc.Op{
        .load_local, .load_const, .lt,          .jump_if_false, .load_local,  .load_const,  .bit_and,     .store_local,
        .pop,        .load_local, .load_local,  .get_index,     .store_local, .pop,         .load_local,  .get_prop,
        .load_local, .add,        .load_local,  .add,           .load_const,  .mod,         .store_local, .pop,
        .new_object, .load_local, .init_prop,   .load_local,    .load_const,  .bit_and,     .init_prop,   .load_local,
        .get_prop,   .init_prop,  .store_local, .pop,           .load_local,  .load_local,  .load_local,  .set_index,
        .pop,        .load_local, .load_local,  .get_prop,      .load_local,  .get_prop,    .add,         .load_local,
        .get_prop,   .add,        .load_const,  .bit_and,       .add,         .store_local, .pop,         .load_local,
        .load_const, .add,        .store_local, .pop,           .jump,
    };
    if (start + expected.len > code.len) return null;
    for (expected, 0..) |op, offset|
        if (offset != 1 and code[start + offset].op != op) return null;

    const counter_local = code[start].a;
    const index_local = code[start + 7].a;
    const array_local = code[start + 9].a;
    const displaced_local = code[start + 12].a;
    const extra_local = code[start + 18].a;
    const value_local = code[start + 22].a;
    const fresh_local = code[start + 34].a;
    const total_local = code[start + 41].a;
    const locals = [_]u32{
        counter_local, index_local, array_local, displaced_local,
        extra_local,   value_local, fresh_local, total_local,
    };
    for (locals, 0..) |local, left|
        for (locals[left + 1 ..]) |other| if (local == other) return null;

    if (code[start + 3].a != start + expected.len or
        code[start + 4].a != counter_local or code[start + 10].a != index_local or
        code[start + 14].a != displaced_local or code[start + 16].a != counter_local or
        code[start + 25].a != value_local or code[start + 27].a != counter_local or
        code[start + 31].a != displaced_local or code[start + 36].a != array_local or
        code[start + 37].a != index_local or code[start + 38].a != fresh_local or
        code[start + 42].a != fresh_local or code[start + 44].a != fresh_local or
        code[start + 47].a != fresh_local or code[start + 53].a != total_local or
        code[start + 55].a != counter_local or code[start + 58].a != counter_local or
        code[start + 60].a != start)
        return null;
    if (!propertyNamesMatch(chunk, &.{ start + 15, start + 32 }) or
        !propertyNamesMatch(chunk, &.{ start + 26, start + 43 }) or
        !propertyNamesMatch(chunk, &.{ start + 30, start + 45 }) or
        !propertyNamesMatch(chunk, &.{ start + 33, start + 48 }))
        return null;

    const literal_name_instructions = [_]usize{ start + 26, start + 30, start + 33 };
    for (literal_name_instructions, 0..) |instruction, left| {
        if (code[instruction].a >= chunk.names.items.len) return null;
        const name = chunk.names.items[code[instruction].a];
        for (literal_name_instructions[left + 1 ..]) |other_instruction| {
            if (code[other_instruction].a >= chunk.names.items.len or
                std.mem.eql(u8, name, chunk.names.items[code[other_instruction].a])) return null;
        }
    }

    const bound: QuickArrayBound = switch (code[start + 1].op) {
        .load_local => .{ .local = code[start + 1].a },
        .load_const => constant: {
            if (code[start + 1].a >= chunk.consts.items.len) return null;
            const value_ = chunk.consts.items[code[start + 1].a];
            if (!value_.isNumber()) return null;
            break :constant .{ .constant = value_.asNum() };
        },
        else => return null,
    };
    switch (bound) {
        .local => |local| for (locals) |modified| {
            if (local == modified and local != extra_local) return null;
        },
        .constant => {},
    }

    const constant_instructions = [_]usize{ start + 5, start + 20, start + 28, start + 50, start + 56 };
    var constants: [constant_instructions.len]f64 = undefined;
    for (constant_instructions, 0..) |instruction, index| {
        const constant_index = code[instruction].a;
        if (constant_index >= chunk.consts.items.len or !chunk.consts.items[constant_index].isNumber()) return null;
        constants[index] = chunk.consts.items[constant_index].asNum();
    }
    return .{
        .counter_local = counter_local,
        .array_local = array_local,
        .index_local = index_local,
        .displaced_local = displaced_local,
        .value_local = value_local,
        .fresh_local = fresh_local,
        .total_local = total_local,
        .extra_local = extra_local,
        .bound = bound,
        .selector_mask = Value.num(constants[0]).toInt32(),
        .modulus = constants[1],
        .stamp_mask = Value.num(constants[2]).toInt32(),
        .checksum_mask = Value.num(constants[3]).toInt32(),
        .increment = exactNonNegativeU32(constants[4], false) orelse return null,
        .displaced_property_instruction = @intCast(start + 15),
        .literal_instructions = .{ @intCast(start + 26), @intCast(start + 30), @intCast(start + 33) },
        .exit_ip = @intCast(start + expected.len),
    };
}

fn compileQuickArrayPlan(chunk: *Chunk, start: usize) QuickArrayPlan {
    if (compileQuickObjectAllocationLoop(chunk, start)) |allocation|
        return .{ .object_allocation = allocation };
    if (compileQuickPolymorphicPropertyLoop(chunk, start)) |property|
        return .{ .polymorphic_property = property };
    if (compileQuickPackedArrayPushLoop(chunk, start)) |push| return .{ .packed_push = push };
    const code = chunk.code.items;
    if (start + 18 > code.len) return .unsupported;
    const index_local = code[start].a;
    const array_local = code[start + 1].a;
    const total_local = code[start + 5].a;
    if (code[start].op != .load_local or
        code[start + 1].op != .load_local or
        code[start + 2].op != .get_prop or code[start + 2].a >= chunk.names.items.len or
        !std.mem.eql(u8, chunk.names.items[code[start + 2].a], "length") or
        code[start + 3].op != .lt or
        code[start + 4].op != .jump_if_false or code[start + 4].a != start + 18 or
        code[start + 5].op != .load_local or
        code[start + 6].op != .load_local or code[start + 6].a != array_local or
        code[start + 7].op != .load_local or code[start + 7].a != index_local or
        code[start + 8].op != .get_index or
        code[start + 9].op != .add or
        code[start + 10].op != .store_local or code[start + 10].a != total_local or
        code[start + 11].op != .pop or
        code[start + 12].op != .load_local or code[start + 12].a != index_local or
        code[start + 13].op != .load_const or code[start + 13].a >= chunk.consts.items.len or
        code[start + 14].op != .add or
        code[start + 15].op != .store_local or code[start + 15].a != index_local or
        code[start + 16].op != .pop or
        code[start + 17].op != .jump or code[start + 17].a != start)
        return .unsupported;
    const increment = chunk.consts.items[code[start + 13].a];
    if (!increment.isNumber()) return .unsupported;
    return .{ .packed_sum = .{
        .index_local = index_local,
        .array_local = array_local,
        .total_local = total_local,
        .increment = increment.asNum(),
    } };
}

fn quickArrayPlan(chunk: *Chunk, start: usize, parallel_sync: bool) ?*QuickArrayPlan {
    if (start >= chunk.quick_array_plans.len) return null;
    const slot = &chunk.quick_array_plans[start];
    if (if (parallel_sync) @atomicLoad(?*anyopaque, slot, .acquire) else slot.*) |raw|
        return @ptrCast(@alignCast(raw));
    const plan = chunk.arena.create(QuickArrayPlan) catch return null;
    plan.* = compileQuickArrayPlan(chunk, start);
    if (parallel_sync) {
        if (@cmpxchgStrong(?*anyopaque, slot, null, plan, .acq_rel, .acquire)) |published|
            return @ptrCast(@alignCast(published));
    } else {
        slot.* = plan;
    }
    return plan;
}

const QuickArrayLoopUpdate = struct {
    extra_steps: u64,
    next_ip: usize,
};

inline fn quickArrayNumericLocal(push: *const QuickPackedArrayPushLoop, frame: *Frame, index_value: Value, raw_local: u32) ?f64 {
    const local: usize = @intCast(raw_local);
    if (local >= frame.slots.len) return null;
    const operand = if (raw_local == push.index_local) index_value else frame.slots[local];
    return if (operand.isNumber()) operand.asNum() else null;
}

inline fn quickArrayNumericExpression(push: *const QuickPackedArrayPushLoop, frame: *Frame, index_value: Value) ?Value {
    switch (push.specialization) {
        .add3_bit_and => |specialized| {
            const first = quickArrayNumericLocal(push, frame, index_value, specialized.locals[0]) orelse return null;
            const second = quickArrayNumericLocal(push, frame, index_value, specialized.locals[1]) orelse return null;
            const third = quickArrayNumericLocal(push, frame, index_value, specialized.locals[2]) orelse return null;
            const sum = Value.num((first + second) + third).toInt32();
            return Value.num(@floatFromInt(sum & specialized.mask));
        },
        .generic => {},
    }
    var numbers: [max_quick_array_expression_stack]f64 = undefined;
    var depth: usize = 0;
    for (push.ops[0..push.op_count]) |op| switch (op) {
        .constant => |number| {
            numbers[depth] = number;
            depth += 1;
        },
        .local => |raw_local| {
            numbers[depth] = quickArrayNumericLocal(push, frame, index_value, raw_local) orelse return null;
            depth += 1;
        },
        .add, .sub, .mul, .div, .mod, .bit_and => {
            const rhs = numbers[depth - 1];
            const lhs = numbers[depth - 2];
            depth -= 1;
            numbers[depth - 1] = switch (op) {
                .add => lhs + rhs,
                .sub => lhs - rhs,
                .mul => lhs * rhs,
                .div => lhs / rhs,
                .mod => numberRemainder(lhs, rhs),
                .bit_and => @floatFromInt(Value.num(lhs).toInt32() & Value.num(rhs).toInt32()),
                else => unreachable,
            };
        },
    };
    return if (depth == 1) Value.num(numbers[0]) else null;
}

fn quickArrayBoundValue(bound: QuickArrayBound, frame: *Frame) ?Value {
    return switch (bound) {
        .constant => |number| Value.num(number),
        .local => |raw_local| value_: {
            const local: usize = @intCast(raw_local);
            if (local >= frame.slots.len or !frame.slots[local].isNumber()) break :value_ null;
            break :value_ frame.slots[local];
        },
    };
}

inline fn quickGlobalBindingValue(chunk: *Chunk, instruction: usize, vm: *Interpreter) ?Value {
    if (instruction >= chunk.quick_global_bindings.len) return null;
    const raw = chunk.quick_global_bindings[instruction] orelse return null;
    const cache: *QuickGlobalBinding = @ptrCast(@alignCast(raw));
    return switch (cache.*) {
        .object => |object_cache| value_: {
            if (vm.env != object_cache.env or vm.global_object != object_cache.object or
                object_cache.object.shape != object_cache.shape)
                break :value_ null;
            const slot: usize = @intCast(object_cache.slot);
            if (slot >= object_cache.object.slots.items.len) break :value_ null;
            break :value_ object_cache.object.slots.items[slot];
        },
        .environment => |environment_cache| if (vm.env == environment_cache.start)
            environment_cache.binding.getLocal(environment_cache.name)
        else
            null,
    };
}

fn recordQuickGlobalBinding(chunk: *Chunk, instruction: usize, vm: *Interpreter, name: []const u8) void {
    if (chunk.quick_global_bindings.len == 0) {
        const caches = chunk.arena.alloc(?*anyopaque, chunk.code.items.len) catch return;
        @memset(caches, null);
        chunk.quick_global_bindings = caches;
    }
    if (instruction >= chunk.quick_global_bindings.len) return;
    const cache: *QuickGlobalBinding = if (chunk.quick_global_bindings[instruction]) |raw|
        @ptrCast(@alignCast(raw))
    else cache: {
        const created = chunk.arena.create(QuickGlobalBinding) catch return;
        chunk.quick_global_bindings[instruction] = created;
        break :cache created;
    };

    const start = vm.env;
    if (start.parent == null and start.with_object == null) object: {
        start.lockBindings();
        const is_live_global_data = start.aliases.get(name) == null and
            start.vars.contains(name) and
            !start.consts.contains(name) and
            !start.lexicals.contains(name) and
            !start.deletable.contains(name);
        start.unlockBindings();
        if (!is_live_global_data) break :object;
        const object = vm.global_object orelse break :object;
        if (object.proxy_handler != null or object.proxy_revoked or object.getAccessor(name) != null) break :object;
        const shape = object.shape orelse break :object;
        const slot = shape.lookup(name) orelse break :object;
        if (slot >= object.slots.items.len) break :object;
        cache.* = .{ .object = .{ .env = start, .object = object, .shape = shape, .slot = slot } };
        return;
    }

    // Evaluated scripts may put a transparent declarative environment between
    // a function closure and the realm root. Cache the exact environment record
    // rather than assuming root-object storage. `getLocal` keeps the value live
    // under the binding lock; deletion makes the cache miss. `with` and module
    // aliases retain full identifier resolution because they can run user code
    // or redirect to another environment.
    var cursor: ?*Environment = start;
    while (cursor) |env| : (cursor = env.parent) {
        if (env.with_object != null) return;
        env.lockBindings();
        const alias = env.aliases.contains(name);
        const found = env.vars.contains(name);
        env.unlockBindings();
        if (alias) return;
        if (found) {
            cache.* = .{ .environment = .{ .start = start, .binding = env, .name = name } };
            return;
        }
    }
    // Leave the allocated cache unreachable if this binding cannot be guarded.
    chunk.quick_global_bindings[instruction] = null;
}

fn quickCallLoopBound(chunk: *Chunk, instruction: usize) ?QuickArrayBound {
    const code = chunk.code.items;
    if (instruction >= code.len) return null;
    return switch (code[instruction].op) {
        .load_local => .{ .local = code[instruction].a },
        .load_const => constant: {
            if (code[instruction].a >= chunk.consts.items.len) return null;
            const value_ = chunk.consts.items[code[instruction].a];
            if (!value_.isNumber()) return null;
            break :constant .{ .constant = value_.asNum() };
        },
        else => null,
    };
}

fn compileQuickDirectCallLoopPlan(chunk: *Chunk, start: usize) QuickCallLoopPlan {
    const code = chunk.code.items;
    if (start + 16 > code.len) return .unsupported;
    const expected = [_]bc.Op{
        .load_local,  .load_const,  .lt,         .jump_if_false,
        .load_var,    .load_local,  .load_local, .call,
        .store_local, .pop,         .load_local, .load_const,
        .add,         .store_local, .pop,        .jump,
    };
    // A local loop bound is equally safe; only the second instruction differs.
    for (expected, 0..) |op, offset| {
        if (offset == 1) {
            if (code[start + offset].op != .load_const and code[start + offset].op != .load_local) return .unsupported;
        } else if (offset == 4) {
            if (code[start + offset].op != .load_var and code[start + offset].op != .load_local) return .unsupported;
        } else if (code[start + offset].op != op) return .unsupported;
    }

    const index_local = code[start].a;
    const value_local = code[start + 5].a;
    if (code[start + 3].a != start + 16 or
        code[start + 6].a != index_local or
        code[start + 7].a != 2 or
        code[start + 8].a != value_local or
        code[start + 10].a != index_local or
        code[start + 11].a >= chunk.consts.items.len or
        code[start + 13].a != index_local or
        code[start + 15].a != start)
        return .unsupported;
    const increment = chunk.consts.items[code[start + 11].a];
    if (!increment.isNumber()) return .unsupported;
    const bound = quickCallLoopBound(chunk, start + 1) orelse return .unsupported;
    const callee: QuickCallCallee = switch (code[start + 4].op) {
        .load_var => global: {
            if (code[start + 4].a >= chunk.names.items.len) return .unsupported;
            break :global .{ .global_instruction = @intCast(start + 4) };
        },
        .load_local => local: {
            if (code[start + 4].a >= chunk.local_count) return .unsupported;
            break :local .{ .local = code[start + 4].a };
        },
        else => unreachable,
    };
    return .{ .numeric_leaf = .{
        .index_local = index_local,
        .value_local = value_local,
        .bound = bound,
        .increment = increment.asNum(),
        .callee = callee,
        .caller_steps = 16,
        .exit_ip = @intCast(start + 16),
    } };
}

fn compileQuickMethodCallLoopPlan(chunk: *Chunk, start: usize) QuickCallLoopPlan {
    const code = chunk.code.items;
    if (start + 19 > code.len) return .unsupported;
    const expected = [_]bc.Op{
        .load_local,     .load_const,  .lt,   .jump_if_false, .load_local,
        .dup,            .get_prop,    .swap, .load_local,    .load_local,
        .call_with_this, .store_local, .pop,  .load_local,    .load_const,
        .add,            .store_local, .pop,  .jump,
    };
    for (expected, 0..) |op, offset| {
        if (offset == 1) {
            if (code[start + offset].op != .load_const and code[start + offset].op != .load_local) return .unsupported;
        } else if (code[start + offset].op != op) return .unsupported;
    }

    const index_local = code[start].a;
    const receiver_local = code[start + 4].a;
    const value_local = code[start + 8].a;
    if (code[start + 3].a != start + 19 or
        receiver_local >= chunk.local_count or
        code[start + 6].a >= chunk.names.items.len or
        code[start + 9].a != index_local or
        code[start + 10].a != 2 or
        code[start + 11].a != value_local or
        code[start + 13].a != index_local or
        code[start + 14].a >= chunk.consts.items.len or
        code[start + 16].a != index_local or
        code[start + 18].a != start)
        return .unsupported;
    const increment = chunk.consts.items[code[start + 14].a];
    if (!increment.isNumber()) return .unsupported;
    const bound = quickCallLoopBound(chunk, start + 1) orelse return .unsupported;
    return .{ .numeric_leaf = .{
        .index_local = index_local,
        .value_local = value_local,
        .bound = bound,
        .increment = increment.asNum(),
        .callee = .{ .method = .{
            .receiver_local = receiver_local,
            .get_prop_instruction = @intCast(start + 6),
        } },
        .caller_steps = 19,
        .exit_ip = @intCast(start + 19),
    } };
}

fn compileQuickClosureCallLoopPlan(chunk: *Chunk, start: usize) QuickCallLoopPlan {
    const code = chunk.code.items;
    if (start + 18 > code.len) return .unsupported;
    var closure_creations: usize = 0;
    for (code) |instruction| closure_creations += @intFromBool(instruction.op == .make_closure);
    // An escaped caller frame is safe only when this immediate-call loop is its
    // sole source of closures. A checkpoint-spanning ordinary iteration may
    // then mark the frame escaped, but the exact trace below proves that closure
    // is stored in a local, called once, and never exposed to another thread.
    if (closure_creations != 1) return .unsupported;
    const expected = [_]bc.Op{
        .load_local, .load_const, .lt,         .jump_if_false, .make_closure, .store_local,
        .pop,        .load_local, .load_local, .call,          .store_local,  .pop,
        .load_local, .load_const, .add,        .store_local,   .pop,          .jump,
    };
    for (expected, 0..) |op, offset| {
        if (offset == 1) {
            if (code[start + offset].op != .load_const and code[start + offset].op != .load_local) return .unsupported;
        } else if (code[start + offset].op != op) return .unsupported;
    }

    const index_local = code[start].a;
    const template_index = code[start + 4].a;
    const closure_local = code[start + 5].a;
    const value_local = code[start + 10].a;
    if (code[start + 3].a != start + 18 or
        template_index >= chunk.fns.items.len or
        closure_local >= chunk.local_count or
        code[start + 7].a != closure_local or
        code[start + 8].a != index_local or
        code[start + 9].a != 1 or
        code[start + 12].a != index_local or
        code[start + 13].a >= chunk.consts.items.len or
        code[start + 15].a != index_local or
        code[start + 17].a != start)
        return .unsupported;
    const template = chunk.fns.items[template_index];
    if (template.self_name.len != 0 or template.uses_arguments or template.is_generator or template.is_async or
        template.is_arrow or template.is_method or template.params.len != 1 or template.chunk == null)
        return .unsupported;
    const increment = chunk.consts.items[code[start + 13].a];
    if (!increment.isNumber()) return .unsupported;
    const bound = quickCallLoopBound(chunk, start + 1) orelse return .unsupported;
    return .{ .numeric_leaf = .{
        .index_local = index_local,
        .value_local = value_local,
        .bound = bound,
        .increment = increment.asNum(),
        .callee = .{ .closure_template = template_index },
        .caller_steps = 18,
        .exit_ip = @intCast(start + 18),
    } };
}

fn compileQuickCallLoopPlan(chunk: *Chunk, start: usize) QuickCallLoopPlan {
    const direct = compileQuickDirectCallLoopPlan(chunk, start);
    switch (direct) {
        .unsupported => {},
        else => return direct,
    }
    const method = compileQuickMethodCallLoopPlan(chunk, start);
    switch (method) {
        .unsupported => {},
        else => return method,
    }
    return compileQuickClosureCallLoopPlan(chunk, start);
}

fn quickCallLoopPlan(chunk: *Chunk, start: usize, parallel_sync: bool) ?*QuickCallLoopPlan {
    if (start >= chunk.quick_call_plans.len) return null;
    const slot = &chunk.quick_call_plans[start];
    if (if (parallel_sync) @atomicLoad(?*anyopaque, slot, .acquire) else slot.*) |raw|
        return @ptrCast(@alignCast(raw));
    const plan = chunk.arena.create(QuickCallLoopPlan) catch return null;
    plan.* = compileQuickCallLoopPlan(chunk, start);
    if (parallel_sync) {
        if (@cmpxchgStrong(?*anyopaque, slot, null, plan, .acq_rel, .acquire)) |published|
            return @ptrCast(@alignCast(published));
    } else {
        slot.* = plan;
    }
    return plan;
}

fn specializeQuickLeaf(ops: []const QuickLeafOp) QuickLeafSpecialization {
    if (ops.len == 5 and ops[0] == .captured_local and ops[2] == .add and ops[4] == .mod) {
        const argument = switch (ops[1]) {
            .argument => |argument| argument,
            else => return .generic,
        };
        const modulus = switch (ops[3]) {
            .constant => |constant| constant,
            else => return .generic,
        };
        return .{ .captured_add_mod = .{ .argument = argument, .modulus = modulus } };
    }
    if (ops.len == 7 and ops[0] == .receiver_property and ops[2] == .add and ops[4] == .add and ops[6] == .mod) {
        const first = switch (ops[1]) {
            .argument => |argument| argument,
            else => return .generic,
        };
        const second = switch (ops[3]) {
            .argument => |argument| argument,
            else => return .generic,
        };
        const modulus = switch (ops[5]) {
            .constant => |constant| constant,
            else => return .generic,
        };
        return .{ .receiver_add_mod = .{ .first = first, .second = second, .modulus = modulus } };
    }
    if (ops.len != 5) return .generic;
    const left = switch (ops[0]) {
        .argument => |argument| argument,
        else => return .generic,
    };
    const right = switch (ops[1]) {
        .argument => |argument| argument,
        else => return .generic,
    };
    if (ops[2] != .add) return .generic;
    const modulus = switch (ops[3]) {
        .constant => |constant| constant,
        else => return .generic,
    };
    if (ops[4] != .mod) return .generic;
    return .{ .add_mod = .{ .left = left, .right = right, .modulus = modulus } };
}

fn compileQuickLeafPlan(chunk: *Chunk) QuickLeafPlan {
    if (chunk.param_count == 0 or chunk.param_count > max_quick_leaf_stack or chunk.local_count != chunk.param_count)
        return .unsupported;
    var ops: [max_quick_leaf_ops]QuickLeafOp = undefined;
    var op_count: usize = 0;
    var depth: usize = 0;
    var captured_local: ?u32 = null;
    var receiver_property_instruction: ?u32 = null;
    var instruction: usize = 0;
    while (instruction < chunk.code.items.len) {
        const inst = chunk.code.items[instruction];
        if (inst.op == .ret) {
            if (depth != 1 or instruction + 1 > std.math.maxInt(u8)) return .unsupported;
            if (instruction + 1 < chunk.code.items.len and
                (instruction + 2 != chunk.code.items.len or chunk.code.items[instruction + 1].op != .ret_undef))
                return .unsupported;
            return .{ .numeric = .{
                .ops = ops,
                .op_count = @intCast(op_count),
                .executed = @intCast(instruction + 1),
                .captured_local = captured_local,
                .receiver_property_instruction = receiver_property_instruction,
                .specialization = specializeQuickLeaf(ops[0..op_count]),
            } };
        }
        if (op_count == ops.len) return .unsupported;
        const op: QuickLeafOp = switch (inst.op) {
            .load_local => argument: {
                if (inst.a >= chunk.param_count or depth == max_quick_leaf_stack) return .unsupported;
                depth += 1;
                break :argument .{ .argument = @intCast(inst.a) };
            },
            .load_const => constant: {
                if (inst.a >= chunk.consts.items.len or !chunk.consts.items[inst.a].isNumber() or depth == max_quick_leaf_stack)
                    return .unsupported;
                depth += 1;
                break :constant .{ .constant = chunk.consts.items[inst.a].asNum() };
            },
            .load_this => receiver: {
                if (instruction + 1 >= chunk.code.items.len or
                    chunk.code.items[instruction + 1].op != .get_prop or
                    chunk.code.items[instruction + 1].a >= chunk.names.items.len or
                    depth == max_quick_leaf_stack or
                    receiver_property_instruction != null)
                    return .unsupported;
                instruction += 1;
                receiver_property_instruction = @intCast(instruction);
                depth += 1;
                break :receiver .receiver_property;
            },
            .load_upval => captured: {
                if (inst.a != 1 or depth == max_quick_leaf_stack or captured_local != null) return .unsupported;
                captured_local = inst.b;
                depth += 1;
                break :captured .captured_local;
            },
            .add, .sub, .mul, .div, .mod => binary: {
                if (depth < 2) return .unsupported;
                depth -= 1;
                break :binary switch (inst.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    else => unreachable,
                };
            },
            else => return .unsupported,
        };
        ops[op_count] = op;
        op_count += 1;
        instruction += 1;
    }
    return .unsupported;
}

fn appendQuickArgumentsExpression(
    node: *const ast.Node,
    argument_count: usize,
    ops: *[max_quick_leaf_ops]QuickLeafOp,
    op_count: *usize,
    executed: *usize,
) bool {
    executed.* += 1;
    const op: QuickLeafOp = switch (node.*) {
        .number => |number| .{ .constant = number },
        .member => |member| argument: {
            if (member.optional or member.object.* != .identifier or
                !std.mem.eql(u8, member.object.identifier, "arguments"))
                return false;
            const computed = member.computed orelse return false;
            if (computed.* != .number) return false;
            const number = computed.number;
            if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or
                number >= @as(f64, @floatFromInt(argument_count)))
                return false;
            // The ordinary tree walker evaluates the member, `arguments`
            // identifier, and numeric key as three AST steps.
            executed.* += 2;
            break :argument .{ .argument = @intFromFloat(number) };
        },
        .binary => |binary| binary: {
            if (!appendQuickArgumentsExpression(binary.left, argument_count, ops, op_count, executed) or
                !appendQuickArgumentsExpression(binary.right, argument_count, ops, op_count, executed))
                return false;
            break :binary switch (binary.op) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .mod => .mod,
                else => return false,
            };
        },
        else => return false,
    };
    if (op_count.* == max_quick_leaf_ops) return false;
    ops[op_count.*] = op;
    op_count.* += 1;
    return true;
}

/// Compile a non-arrow leaf that observes only static numeric reads from its
/// own `arguments` object. With no writes, calls, dynamic keys, or escaping
/// references in the accepted AST, those reads are exactly the incoming values
/// and the per-call exotic object can remain scalar-replaced.
fn compileQuickArgumentsLeaf(function: *const Function, argument_count: usize) ?QuickNumericLeaf {
    if (!function.uses_arguments or function.is_arrow or function.params.len != argument_count) return null;
    for (function.params) |parameter|
        if (parameter.default != null or parameter.is_rest or parameter.pattern != null) return null;

    var executed: usize = 0;
    const expression = if (function.is_expr_body) function.body else expression: {
        if (function.body.* != .block or function.body.block.len != 1) return null;
        const statement = function.body.block[0];
        if (statement.* != .return_stmt) return null;
        const returned = statement.return_stmt orelse return null;
        executed = 2; // block + return statement
        break :expression returned;
    };
    var ops: [max_quick_leaf_ops]QuickLeafOp = undefined;
    var op_count: usize = 0;
    if (!appendQuickArgumentsExpression(expression, argument_count, &ops, &op_count, &executed) or
        op_count == 0 or executed > std.math.maxInt(u8))
        return null;

    return .{
        .ops = ops,
        .op_count = @intCast(op_count),
        .executed = @intCast(executed),
        .captured_local = null,
        .receiver_property_instruction = null,
        .specialization = specializeQuickLeaf(ops[0..op_count]),
    };
}

fn tryQuickArgumentsCall(vm: *Interpreter, function: *const Function, values: []const Value) EvalError!?Value {
    if (values.len > max_quick_leaf_stack) return null;
    const leaf = compileQuickArgumentsLeaf(function, values.len) orelse return null;
    var arguments: [max_quick_leaf_stack]f64 = undefined;
    for (values, 0..) |value_, index| {
        if (!value_.isNumber()) return null;
        arguments[index] = value_.asNum();
    }
    const result = evaluateQuickLeaf(&leaf, arguments[0..values.len], null, null) orelse return null;
    // The call bytecode itself was already counted by the dispatch loop. Retain
    // every AST step the side-effect-free tree-walker leaf would have executed,
    // including any stop/GIL/GC checkpoint crossed within the call.
    try advanceQuickObservableSteps(vm, leaf.executed);
    if (builtin.is_test) _ = quick_numeric_arguments_direct_call_hits.fetchAdd(1, .monotonic);
    return Value.num(result);
}

fn quickLeafPlan(chunk: *Chunk, parallel_sync: bool) ?*QuickLeafPlan {
    if (if (parallel_sync) @atomicLoad(?*anyopaque, &chunk.quick_leaf_plan, .acquire) else chunk.quick_leaf_plan) |raw|
        return @ptrCast(@alignCast(raw));
    const plan = chunk.arena.create(QuickLeafPlan) catch return null;
    plan.* = compileQuickLeafPlan(chunk);
    if (parallel_sync) {
        if (@cmpxchgStrong(?*anyopaque, &chunk.quick_leaf_plan, null, plan, .acq_rel, .acquire)) |published|
            return @ptrCast(@alignCast(published));
    } else {
        chunk.quick_leaf_plan = plan;
    }
    return plan;
}

fn quickImmutableLocalBinding(vm: *Interpreter, name: []const u8) ?Value {
    var cursor: ?*Environment = vm.env;
    while (cursor) |env| : (cursor = env.parent) {
        if (env.with_object != null) return null;
        env.lockBindings();
        const alias = env.aliases.contains(name);
        const binding = env.vars.get(name);
        const immutable = binding != null and env.consts.contains(name);
        env.unlockBindings();
        if (alias) return null;
        if (binding) |callee| return if (immutable) callee else null;
    }
    return null;
}

fn evaluateQuickLeaf(
    leaf: *const QuickNumericLeaf,
    arguments: []const f64,
    captured_value: ?f64,
    receiver_property: ?f64,
) ?f64 {
    switch (leaf.specialization) {
        .add_mod => |specialized| {
            if (specialized.left >= arguments.len or specialized.right >= arguments.len) return null;
            return numberRemainder(arguments[specialized.left] + arguments[specialized.right], specialized.modulus);
        },
        .captured_add_mod => |specialized| {
            if (specialized.argument >= arguments.len) return null;
            return numberRemainder(
                (captured_value orelse return null) + arguments[specialized.argument],
                specialized.modulus,
            );
        },
        .receiver_add_mod => |specialized| {
            if (specialized.first >= arguments.len or specialized.second >= arguments.len) return null;
            const property = receiver_property orelse return null;
            return numberRemainder(
                (property + arguments[specialized.first]) + arguments[specialized.second],
                specialized.modulus,
            );
        },
        .generic => {},
    }
    var stack: [max_quick_leaf_stack]f64 = undefined;
    var depth: usize = 0;
    for (leaf.ops[0..leaf.op_count]) |op| switch (op) {
        .argument => |argument| {
            if (argument >= arguments.len) return null;
            stack[depth] = arguments[argument];
            depth += 1;
        },
        .constant => |constant| {
            stack[depth] = constant;
            depth += 1;
        },
        .captured_local => {
            stack[depth] = captured_value orelse return null;
            depth += 1;
        },
        .receiver_property => {
            stack[depth] = receiver_property orelse return null;
            depth += 1;
        },
        .add, .sub, .mul, .div, .mod => {
            const rhs = stack[depth - 1];
            const lhs = stack[depth - 2];
            depth -= 1;
            stack[depth - 1] = switch (op) {
                .add => lhs + rhs,
                .sub => lhs - rhs,
                .mul => lhs * rhs,
                .div => lhs / rhs,
                .mod => numberRemainder(lhs, rhs),
                else => unreachable,
            };
        },
    };
    return if (depth == 1) stack[0] else null;
}

/// Read the exact own data slot proved by a warmed IC. Shared mode snapshots
/// shape and value under the receiver lock; accessors, proxies, attributes,
/// arrays, prototype hits, and shape misses retain ordinary [[Get]].
fn quickOwnDataPropertyValue(
    chunk: *Chunk,
    instruction: usize,
    receiver: Value,
    parallel_sync: bool,
) ?Value {
    if (!receiver.isObject()) return null;
    const object = receiver.asObj();
    if (parallel_sync) object.lockProperties();
    defer if (parallel_sync) object.unlockProperties();
    if (object.is_array or object.proxy_handler != null or object.proxy_revoked or
        object.accessors.load(.monotonic) != null or object.attrsMap() != null)
        return null;
    const slot = quickPropertySlotMode(chunk, instruction, object, parallel_sync) orelse return null;
    return object.slots.items[slot];
}

fn quickReceiverPropertyNumber(
    chunk: *Chunk,
    instruction: usize,
    receiver: Value,
    parallel_sync: bool,
) ?f64 {
    const property = quickOwnDataPropertyValue(chunk, instruction, receiver, parallel_sync) orelse return null;
    return if (property.isNumber()) property.asNum() else null;
}

fn tryQuickNumericCallLoop(
    vm: *Interpreter,
    chunk: *Chunk,
    plan: *const QuickCallLoopPlan,
    frame: *Frame,
    start: usize,
    max_extra_steps: u64,
    parallel_sync: bool,
) EvalError!?QuickCallLoopUpdate {
    if (builtin.is_test and !quick_numeric_call_loop_test_enabled.load(.monotonic)) return null;
    const loop = switch (plan.*) {
        .unsupported => return null,
        .numeric_leaf => |loop| loop,
    };
    const closure_loop = switch (loop.callee) {
        .closure_template => true,
        else => false,
    };
    if (frame.escaped.load(.monotonic) and !closure_loop) return null;
    const index_slot: usize = @intCast(loop.index_local);
    const value_slot: usize = @intCast(loop.value_local);
    if (index_slot >= frame.slots.len or value_slot >= frame.slots.len) return null;
    if (!frame.slots[index_slot].isNumber() or !frame.slots[value_slot].isNumber()) return null;
    const bound = quickArrayBoundValue(loop.bound, frame) orelse return null;
    var index = frame.slots[index_slot].asNum();
    var current = frame.slots[value_slot].asNum();
    if (!(index < bound.asNum())) return null;

    var method_receiver: ?Value = null;
    var method_get_instruction: ?usize = null;
    var callee: ?Value = null;
    var callee_chunk: ?*Chunk = null;
    var argument_count: usize = 2;
    var captured_frame: ?*Frame = null;
    switch (loop.callee) {
        .local => |raw_slot| {
            const slot: usize = @intCast(raw_slot);
            if (slot >= frame.slots.len) return null;
            callee = frame.slots[slot];
        },
        .global_instruction => |raw_instruction| {
            const instruction: usize = @intCast(raw_instruction);
            if (instruction >= chunk.code.items.len) return null;
            const binding_name_index = chunk.code.items[instruction].a;
            if (binding_name_index >= chunk.names.items.len) return null;
            callee = if (parallel_sync)
                quickImmutableLocalBinding(vm, chunk.names.items[binding_name_index]) orelse return null
            else
                quickGlobalBindingValue(chunk, instruction, vm) orelse return null;
        },
        .method => |method| {
            const receiver_slot: usize = @intCast(method.receiver_local);
            if (receiver_slot >= frame.slots.len) return null;
            const receiver = frame.slots[receiver_slot];
            const instruction: usize = @intCast(method.get_prop_instruction);
            callee = quickOwnDataPropertyValue(chunk, instruction, receiver, parallel_sync) orelse return null;
            method_receiver = receiver;
            method_get_instruction = instruction;
        },
        .closure_template => |raw_template_index| {
            const template_index: usize = @intCast(raw_template_index);
            if (template_index >= chunk.fns.items.len) return null;
            const template = chunk.fns.items[template_index];
            if (template.self_name.len != 0 or template.uses_arguments or template.is_generator or template.is_async or
                template.is_arrow or template.is_method or template.params.len != 1)
                return null;
            callee_chunk = template.chunk orelse return null;
            argument_count = 1;
            captured_frame = frame;
        },
    }
    var arguments_leaf: QuickNumericLeaf = undefined;
    var arguments_leaf_active = false;
    const leaf: *const QuickNumericLeaf = if (captured_frame != null) leaf: {
        const compiled = callee_chunk.?;
        if (compiled.param_count != argument_count) return null;
        const leaf_plan = quickLeafPlan(compiled, parallel_sync) orelse return null;
        break :leaf switch (leaf_plan.*) {
            .unsupported => return null,
            .numeric => |*numeric| numeric,
        };
    } else leaf: {
        const function = jsPlainFunction(callee.?) orelse return null;
        if (function.is_class_constructor or function.params.len != argument_count) return null;
        if (function.uses_arguments) {
            arguments_leaf = compileQuickArgumentsLeaf(function, argument_count) orelse return null;
            arguments_leaf_active = true;
            break :leaf &arguments_leaf;
        }
        const compiled = function.chunk orelse return null;
        if (compiled.param_count != argument_count) return null;
        callee_chunk = compiled;
        const leaf_plan = quickLeafPlan(compiled, parallel_sync) orelse return null;
        break :leaf switch (leaf_plan.*) {
            .unsupported => return null,
            .numeric => |*numeric| numeric,
        };
    };
    if (captured_frame != null) {
        if (leaf.captured_local == null or leaf.receiver_property_instruction != null) return null;
    } else if (leaf.captured_local != null or (leaf.receiver_property_instruction != null and method_receiver == null)) {
        return null;
    }
    var stable_receiver_property: ?f64 = null;
    if (!parallel_sync) if (leaf.receiver_property_instruction) |raw_instruction| {
        stable_receiver_property = quickReceiverPropertyNumber(
            callee_chunk.?,
            raw_instruction,
            method_receiver.?,
            false,
        ) orelse return null;
    };
    const steps_per_iteration = @as(u64, loop.caller_steps) + @as(u64, leaf.executed);
    const max_iterations = (max_extra_steps + 1) / steps_per_iteration;
    if (max_iterations == 0) return null;
    try vm.stackGuard();

    var iterations: u64 = 0;
    while (iterations < max_iterations and index < bound.asNum()) : (iterations += 1) {
        const next_index = index + loop.increment;
        const completes_loop = !(next_index < bound.asNum());
        const completed_extra_steps = (iterations + 1) * steps_per_iteration - 1 +
            (if (completes_loop) @as(u64, 4) else 0);
        if (completed_extra_steps > max_extra_steps) break;
        if (parallel_sync) if (method_get_instruction) |instruction| {
            const live_method = quickOwnDataPropertyValue(chunk, instruction, method_receiver.?, true) orelse return null;
            if (live_method.rawBits() != callee.?.rawBits()) return null;
        };
        var receiver_property = stable_receiver_property;
        if (parallel_sync) if (leaf.receiver_property_instruction) |raw_instruction| {
            receiver_property = quickReceiverPropertyNumber(
                callee_chunk.?,
                raw_instruction,
                method_receiver.?,
                true,
            ) orelse return null;
        };
        var captured_value: ?f64 = null;
        if (leaf.captured_local) |raw_slot| {
            const slot: usize = @intCast(raw_slot);
            if (slot >= captured_frame.?.slots.len) return null;
            if (slot == value_slot) {
                captured_value = current;
            } else {
                const value_ = captured_frame.?.slots[slot];
                if (!value_.isNumber()) return null;
                captured_value = value_.asNum();
            }
        }
        const arguments = [2]f64{ current, index };
        const argument_slice = if (argument_count == 1) arguments[1..2] else arguments[0..2];
        current = evaluateQuickLeaf(leaf, argument_slice, captured_value, receiver_property) orelse return null;
        index = next_index;
    }
    if (iterations == 0) return null;
    const completes_loop = !(index < bound.asNum());
    frame.slots[value_slot] = Value.num(current);
    frame.slots[index_slot] = Value.num(index);
    if (builtin.is_test) {
        _ = quick_numeric_call_loop_hits.fetchAdd(1, .monotonic);
        if (arguments_leaf_active) _ = quick_numeric_arguments_call_loop_hits.fetchAdd(1, .monotonic);
        switch (loop.callee) {
            .closure_template => _ = quick_numeric_closure_call_loop_hits.fetchAdd(1, .monotonic),
            .method => _ = quick_numeric_method_call_loop_hits.fetchAdd(1, .monotonic),
            else => {},
        }
    }
    return .{
        .extra_steps = iterations * steps_per_iteration - 1 + (if (completes_loop) @as(u64, 4) else 0),
        .next_ip = if (completes_loop) loop.exit_ip else start,
    };
}

/// Reuse the one materialized closure on checkpoint-spanning fallback
/// iterations of a proved immediate-call loop. The structural plan requires a
/// single closure site in the caller, and the numeric leaf accepts only the
/// captured scalar expression, so neither identity nor the function object can
/// be observed between the local store and call. All other closure creation
/// retains the ordinary fresh-object path.
fn quickReusableImmediateClosure(
    chunk: *Chunk,
    instruction: usize,
    frame: *Frame,
    parallel_sync: bool,
) ?Value {
    if (instruction < 4) return null;
    const start = instruction - 4;
    const plan = quickCallLoopPlan(chunk, start, parallel_sync) orelse return null;
    const loop = switch (plan.*) {
        .unsupported => return null,
        .numeric_leaf => |loop| loop,
    };
    const template_index = switch (loop.callee) {
        .closure_template => |template_index| template_index,
        else => return null,
    };
    if (template_index >= chunk.fns.items.len or chunk.code.items[instruction].a != template_index) return null;
    const callee_chunk = chunk.fns.items[template_index].chunk orelse return null;
    const leaf_plan = quickLeafPlan(callee_chunk, parallel_sync) orelse return null;
    const leaf = switch (leaf_plan.*) {
        .unsupported => return null,
        .numeric => |*leaf| leaf,
    };
    if (leaf.captured_local == null or leaf.receiver_property_instruction != null) return null;

    const closure_slot: usize = @intCast(chunk.code.items[start + 5].a);
    if (closure_slot >= frame.slots.len) return null;
    const held = frame.lockSlots(parallel_sync);
    defer frame.unlockSlots(held);
    const candidate = frame.slots[closure_slot];
    const function = jsChunkFn(candidate) orelse return null;
    if (function.frame != @as(?*anyopaque, @ptrCast(frame)) or function.chunk != callee_chunk) return null;
    if (builtin.is_test) _ = quick_reusable_immediate_closure_hits.fetchAdd(1, .monotonic);
    return candidate;
}

fn exactU16(value_: Value, allow_zero: bool) ?u16 {
    if (!value_.isNumber()) return null;
    const number = value_.asNum();
    if (!std.math.isFinite(number) or @trunc(number) != number or number < @as(f64, if (allow_zero) 0 else 1) or number > std.math.maxInt(u16))
        return null;
    return @intFromFloat(number);
}

fn compileQuickObservableRecurrencePlan(chunk: *Chunk) ?QuickObservableAddRecurrence {
    const code = chunk.code.items;
    if (chunk.param_count != 2 or chunk.local_count != 2 or code.len != 28) return null;
    const expected = [_]bc.Op{
        .load_local, .load_local, .get_prop,   .load_const,    .add,        .set_prop, .pop,
        .load_local, .load_const, .lt,         .jump_if_false, .load_local, .jump,     .load_var,
        .load_local, .load_const, .sub,        .load_local,    .call,       .load_var, .load_local,
        .load_const, .sub,        .load_local, .call,          .add,        .ret,      .ret_undef,
    };
    for (expected, 0..) |op, instruction| if (code[instruction].op != op) return null;
    if (code[0].a != 1 or code[1].a != 1 or
        code[7].a != 0 or code[10].a != 13 or code[11].a != 0 or code[12].a != 26 or
        code[14].a != 0 or code[17].a != 1 or code[18].a != 2 or
        code[20].a != 0 or code[23].a != 1 or code[24].a != 2 or
        code[2].a >= chunk.names.items.len or code[5].a >= chunk.names.items.len or
        code[13].a >= chunk.names.items.len or code[19].a >= chunk.names.items.len or
        code[3].a >= chunk.consts.items.len or code[8].a >= chunk.consts.items.len or
        code[15].a >= chunk.consts.items.len or code[21].a >= chunk.consts.items.len or
        !std.mem.eql(u8, chunk.names.items[code[2].a], chunk.names.items[code[5].a]) or
        !std.mem.eql(u8, chunk.names.items[code[13].a], chunk.names.items[code[19].a]))
        return null;
    const counter_increment = chunk.consts.items[code[3].a];
    if (!counter_increment.isNumber()) return null;
    const threshold = exactU16(chunk.consts.items[code[8].a], false) orelse return null;
    const first_delta = exactU16(chunk.consts.items[code[15].a], false) orelse return null;
    const second_delta = exactU16(chunk.consts.items[code[21].a], false) orelse return null;
    if (first_delta > threshold or second_delta > threshold) return null;
    return .{
        .threshold = threshold,
        .first_delta = first_delta,
        .second_delta = second_delta,
        .first_binding_instruction = 13,
        .second_binding_instruction = 19,
        .counter_read_instruction = 2,
        .counter_write_instruction = 5,
        .counter_name = code[2].a,
        .counter_increment = counter_increment.asNum(),
    };
}

fn compileQuickRecurrencePlan(chunk: *Chunk) QuickRecurrencePlan {
    if (compileQuickObservableRecurrencePlan(chunk)) |observable|
        return .{ .observable_add = observable };
    const code = chunk.code.items;
    if (chunk.param_count != 1 or chunk.local_count != 1 or code.len != 19) return .unsupported;
    const expected = [_]bc.Op{
        .load_local, .load_const, .lt,  .jump_if_false, .load_local, .jump,       .load_var,
        .load_local, .load_const, .sub, .call,          .load_var,   .load_local, .load_const,
        .sub,        .call,       .add, .ret,           .ret_undef,
    };
    for (expected, 0..) |op, instruction| if (code[instruction].op != op) return .unsupported;
    if (code[0].a != 0 or code[3].a != 6 or code[4].a != 0 or code[5].a != 17 or
        code[7].a != 0 or code[10].a != 1 or code[12].a != 0 or code[15].a != 1 or
        code[1].a >= chunk.consts.items.len or code[8].a >= chunk.consts.items.len or code[13].a >= chunk.consts.items.len or
        code[6].a >= chunk.names.items.len or code[11].a >= chunk.names.items.len or
        !std.mem.eql(u8, chunk.names.items[code[6].a], chunk.names.items[code[11].a]))
        return .unsupported;
    const threshold = exactU16(chunk.consts.items[code[1].a], false) orelse return .unsupported;
    const first_delta = exactU16(chunk.consts.items[code[8].a], false) orelse return .unsupported;
    const second_delta = exactU16(chunk.consts.items[code[13].a], false) orelse return .unsupported;
    if (first_delta > threshold or second_delta > threshold) return .unsupported;
    return .{ .add = .{
        .threshold = threshold,
        .first_delta = first_delta,
        .second_delta = second_delta,
        .binding_instruction = 6,
    } };
}

fn quickRecurrencePlan(chunk: *Chunk, parallel_sync: bool) ?*QuickRecurrencePlan {
    if (parallel_sync) {
        if (@atomicLoad(?*anyopaque, &chunk.quick_recurrence_plan, .acquire)) |raw|
            return @ptrCast(@alignCast(raw));
    } else if (chunk.quick_recurrence_plan) |raw| {
        return @ptrCast(@alignCast(raw));
    }
    const plan = chunk.arena.create(QuickRecurrencePlan) catch return null;
    plan.* = compileQuickRecurrencePlan(chunk);
    if (parallel_sync) {
        if (@cmpxchgStrong(?*anyopaque, &chunk.quick_recurrence_plan, null, plan, .acq_rel, .acquire)) |published|
            return @ptrCast(@alignCast(published));
    } else {
        chunk.quick_recurrence_plan = plan;
    }
    return plan;
}

fn addRecurrenceSteps(first: u64, second: u64) u64 {
    const cap = interp.max_steps + 1;
    const children = std.math.add(u64, first, second) catch return cap;
    return @min(std.math.add(u64, children, 16) catch cap, cap);
}

fn advanceQuickSteps(vm: *Interpreter, requested: u64) EvalError!void {
    var remaining = requested;
    while (remaining != 0) {
        const until_checkpoint = 1024 - (vm.steps & 1023);
        const advance = @min(remaining, until_checkpoint);
        vm.steps += advance;
        remaining -= advance;
        if (vm.steps > interp.max_steps)
            return vm.throwError("RangeError", "evaluation step budget exceeded");
        if ((vm.steps & 1023) == 0) {
            if (vm.stop_flag) |flag| if (flag.load(.monotonic))
                return vm.throwError("Error", "worker terminated");
            if (vm.use_thread_gil) if (vm.gil) |gil| gil.yieldIfContended();
            if (vm.gc_safepoint_fn != null) vm.serviceGcSafepoint();
        }
    }
}

inline fn advanceQuickObservableSteps(vm: *Interpreter, requested: u64) EvalError!void {
    const end = std.math.add(u64, vm.steps, requested) catch return advanceQuickSteps(vm, requested);
    if (end <= interp.max_steps and (vm.steps >> 10) == (end >> 10)) {
        vm.steps = end;
        return;
    }
    return advanceQuickSteps(vm, requested);
}

fn runQuickObservableRecurrence(
    vm: *Interpreter,
    recurrence: QuickObservableAddRecurrence,
    state: *value.Object,
    counter_slot: usize,
    input: u16,
) EvalError!f64 {
    // Execute every logical invocation and counter mutation. Only the bytecode
    // dispatch and activation materialization are compiled away; checkpoint and
    // step positions stay identical to the 28-instruction function body.
    try advanceQuickObservableSteps(vm, 6); // property update through set_prop
    const updated_counter = Value.num(state.slots.items[counter_slot].asNum() + recurrence.counter_increment);
    gc_mod.barrierValueFrom(state, updated_counter);
    state.slots.items[counter_slot] = updated_counter;
    try advanceQuickObservableSteps(vm, 5); // pop + condition + branch
    if (input < recurrence.threshold) {
        try advanceQuickObservableSteps(vm, 3); // value arm + jump + return
        return @floatFromInt(input);
    }

    try advanceQuickObservableSteps(vm, 6); // first callee/arguments/call
    const first = try runQuickObservableRecurrence(vm, recurrence, state, counter_slot, input - recurrence.first_delta);
    try advanceQuickObservableSteps(vm, 6); // second callee/arguments/call
    const second = try runQuickObservableRecurrence(vm, recurrence, state, counter_slot, input - recurrence.second_delta);
    try advanceQuickObservableSteps(vm, 2); // add + return
    return first + second;
}

fn quickParallelCounterRead(vm: *Interpreter, state: *value.Object, name: []const u8) EvalError!Value {
    state.lockProperties();
    if (!state.is_array and state.proxy_handler == null and !state.proxy_revoked and
        state.accessors.load(.monotonic) == null and state.attrsMap() == null)
    {
        if (state.shape) |shape| if (shape.lookup(name)) |slot| if (slot < state.slots.items.len) {
            const result = state.slots.items[slot];
            state.unlockProperties();
            return result;
        };
    }
    state.unlockProperties();
    return vm.getProperty(Value.obj(state), name);
}

fn quickParallelCounterWrite(vm: *Interpreter, state: *value.Object, name: []const u8, updated: Value) EvalError!void {
    state.lockProperties();
    if (!state.is_array and state.proxy_handler == null and !state.proxy_revoked and
        state.accessors.load(.monotonic) == null and state.attrsMap() == null)
    {
        if (state.shape) |shape| if (shape.lookup(name)) |slot| if (slot < state.slots.items.len) {
            gc_mod.barrierValueFrom(state, updated);
            state.slots.items[slot] = updated;
            state.unlockProperties();
            return;
        };
    }
    state.unlockProperties();
    try vm.setMember(Value.obj(state), name, updated);
}

fn runQuickObservableRecurrenceParallel(
    vm: *Interpreter,
    recurrence: QuickObservableAddRecurrence,
    state: *value.Object,
    counter_name: []const u8,
    input: u16,
) EvalError!f64 {
    try advanceQuickObservableSteps(vm, 3); // through get_prop
    const current = try quickParallelCounterRead(vm, state, counter_name);
    try advanceQuickObservableSteps(vm, 2); // constant + add
    const increment = Value.num(recurrence.counter_increment);
    const updated = if (current.isNumber())
        Value.num(current.asNum() + recurrence.counter_increment)
    else
        try vm.applyBinary(.add, current, increment);
    try advanceQuickObservableSteps(vm, 1); // set_prop
    try quickParallelCounterWrite(vm, state, counter_name, updated);
    try advanceQuickObservableSteps(vm, 5); // pop + condition + branch
    if (input < recurrence.threshold) {
        try advanceQuickObservableSteps(vm, 3);
        return @floatFromInt(input);
    }

    try advanceQuickObservableSteps(vm, 6);
    const first = try runQuickObservableRecurrenceParallel(vm, recurrence, state, counter_name, input - recurrence.first_delta);
    try advanceQuickObservableSteps(vm, 6);
    const second = try runQuickObservableRecurrenceParallel(vm, recurrence, state, counter_name, input - recurrence.second_delta);
    try advanceQuickObservableSteps(vm, 2);
    return first + second;
}

inline fn quickRecurrenceCalleeMatches(vm: *Interpreter, chunk: *Chunk, instruction: u32, func: *Function, parallel_sync: bool) bool {
    if (instruction < chunk.code.items.len) {
        const name_index = chunk.code.items[instruction].a;
        if (name_index < chunk.names.items.len) {
            const name = chunk.names.items[name_index];
            if (func.closure.isFnName(name)) {
                const live = func.closure.getLocal(name) orelse return false;
                const function_object = func.obj orelse return false;
                return live.isObject() and live.asObj() == function_object;
            }
        }
    }
    if (parallel_sync) return false;
    const live = quickGlobalBindingValue(chunk, instruction, vm) orelse return false;
    const function_object = func.obj orelse return false;
    return live.isObject() and live.asObj() == function_object;
}

fn quickRecurrenceNeededDepth(input: u16, threshold: u16, first_delta: u16, second_delta: u16) u32 {
    const minimum_delta = @min(first_delta, second_delta);
    return if (input < threshold)
        1
    else
        @as(u32, (input - threshold) / minimum_delta) + 2;
}

fn tryQuickNumericRecurrence(vm: *Interpreter, func: *Function, args: []const Value, parallel_sync: bool) EvalError!?Value {
    const chunk = func.chunk orelse return null;
    const plan = quickRecurrencePlan(chunk, parallel_sync) orelse return null;
    return switch (plan.*) {
        .unsupported => null,
        .add => |recurrence| pure: {
            if (args.len == 0) break :pure null;
            const input = exactU16(args[0], true) orelse break :pure null;
            if (input > 255 or !quickRecurrenceCalleeMatches(vm, chunk, recurrence.binding_instruction, func, parallel_sync))
                break :pure null;
            const needed_depth = quickRecurrenceNeededDepth(input, recurrence.threshold, recurrence.first_delta, recurrence.second_delta);
            if (vm.depth + needed_depth > interp.max_call_depth) break :pure null;

            var results: [256]f64 = undefined;
            var steps: [256]u64 = undefined;
            var n: usize = 0;
            while (n <= input) : (n += 1) {
                if (n < recurrence.threshold) {
                    results[n] = @floatFromInt(n);
                    steps[n] = 7;
                } else {
                    const first = n - recurrence.first_delta;
                    const second = n - recurrence.second_delta;
                    results[n] = results[first] + results[second];
                    steps[n] = addRecurrenceSteps(steps[first], steps[second]);
                }
            }
            try advanceQuickSteps(vm, steps[input]);
            if (builtin.is_test) _ = quick_numeric_recurrence_hits.fetchAdd(1, .monotonic);
            break :pure Value.num(results[input]);
        },
        .observable_add => |recurrence| observable: {
            if (args.len < 2) break :observable null;
            const input = exactU16(args[0], true) orelse break :observable null;
            if (input > 255 or
                !quickRecurrenceCalleeMatches(vm, chunk, recurrence.first_binding_instruction, func, parallel_sync) or
                !quickRecurrenceCalleeMatches(vm, chunk, recurrence.second_binding_instruction, func, parallel_sync))
                break :observable null;
            if (!args[1].isObject()) break :observable null;
            const state = args[1].asObj();
            if (state.is_symbol or state.is_bigint) break :observable null;
            const needed_depth = quickRecurrenceNeededDepth(input, recurrence.threshold, recurrence.first_delta, recurrence.second_delta);
            if (needed_depth > inline_call_depth_limit or vm.depth + needed_depth > interp.max_call_depth)
                break :observable null;

            const result = if (parallel_sync) parallel: {
                if (recurrence.first_binding_instruction >= chunk.code.items.len) break :observable null;
                const self_name = chunk.code.items[recurrence.first_binding_instruction].a;
                if (self_name >= chunk.names.items.len or !func.closure.isFnName(chunk.names.items[self_name]))
                    break :observable null;
                if (recurrence.counter_name >= chunk.names.items.len) break :observable null;
                break :parallel try runQuickObservableRecurrenceParallel(
                    vm,
                    recurrence,
                    state,
                    chunk.names.items[recurrence.counter_name],
                    input,
                );
            } else isolated: {
                const plain_state = quickPlainObject(args[1]) orelse break :observable null;
                if (plain_state.proxy_handler != null or plain_state.proxy_revoked or plain_state.is_symbol or plain_state.is_bigint)
                    break :observable null;
                const read_slot = quickPropertySlot(chunk, recurrence.counter_read_instruction, plain_state) orelse break :observable null;
                const write_slot = quickPropertySlot(chunk, recurrence.counter_write_instruction, plain_state) orelse break :observable null;
                if (read_slot != write_slot or quickSlotNumber(plain_state, read_slot) == null) break :observable null;
                break :isolated try runQuickObservableRecurrence(vm, recurrence, plain_state, read_slot, input);
            };
            if (builtin.is_test) _ = quick_observable_recurrence_hits.fetchAdd(1, .monotonic);
            break :observable Value.num(result);
        },
    };
}

fn tryQuickObjectAllocationLoop(
    vm: *Interpreter,
    chunk: *Chunk,
    allocation: *QuickObjectAllocationLoop,
    frame: *Frame,
    start: usize,
    max_extra_steps: u64,
    parallel_sync: bool,
) EvalError!?QuickArrayLoopUpdate {
    if (parallel_sync or frame.escaped.load(.monotonic)) return null;
    const counter_slot: usize = @intCast(allocation.counter_local);
    const array_slot: usize = @intCast(allocation.array_local);
    const index_slot: usize = @intCast(allocation.index_local);
    const displaced_slot: usize = @intCast(allocation.displaced_local);
    const value_slot: usize = @intCast(allocation.value_local);
    const fresh_slot: usize = @intCast(allocation.fresh_local);
    const total_slot: usize = @intCast(allocation.total_local);
    const extra_slot: usize = @intCast(allocation.extra_local);
    for ([_]usize{ counter_slot, array_slot, index_slot, displaced_slot, value_slot, fresh_slot, total_slot, extra_slot }) |slot|
        if (slot >= frame.slots.len) return null;

    const array_value = frame.slots[array_slot];
    if (!array_value.isObject()) return null;
    const array = array_value.asObj();
    if (!array.is_array or array.is_arguments or array.proxy_handler != null or array.proxy_revoked or
        array.accessors.load(.monotonic) != null or array.attrsMap() != null or array.holes != null or
        array.has_indexed_property.load(.monotonic) or array.array_len > array.elements.items.len)
        return null;
    if (!frame.slots[counter_slot].isNumber() or !frame.slots[total_slot].isNumber() or
        !frame.slots[extra_slot].isNumber()) return null;
    const bound_value = quickArrayBoundValue(allocation.bound, frame) orelse return null;
    var counter_integer = exactNonNegativeU32(frame.slots[counter_slot].asNum(), true) orelse return null;
    var counter: f64 = @floatFromInt(counter_integer);
    var total = frame.slots[total_slot].asNum();
    const extra = frame.slots[extra_slot].asNum();
    const bound = bound_value.asNum();
    if (!(counter < bound)) return null;

    for (allocation.literal_instructions) |instruction|
        if (instruction >= chunk.ics.len) return null;
    const literal_shape = prepared: {
        if (allocation.prepared_root_shape == vm.root_shape) {
            if (allocation.prepared_literal_shape) |cached| break :prepared cached;
        }
        const first_transition = chunk.ics[allocation.literal_instructions[0]].lookupLiteralTransitionMode(vm.root_shape, false) orelse return null;
        const second_transition = chunk.ics[allocation.literal_instructions[1]].lookupLiteralTransitionMode(first_transition.shape, false) orelse return null;
        const third_transition = chunk.ics[allocation.literal_instructions[2]].lookupLiteralTransitionMode(second_transition.shape, false) orelse return null;
        const resolved = value.Object.prepareInlineLiteralShape(vm.root_shape, third_transition.shape, 3) orelse return null;
        allocation.prepared_literal_shape = resolved;
        allocation.prepared_root_shape = vm.root_shape;
        if (builtin.is_test) _ = quick_object_literal_shape_preparations.fetchAdd(1, .monotonic);
        break :prepared resolved;
    };

    const steps_per_iteration: u64 = 61;
    const max_iterations = (max_extra_steps + 1) / steps_per_iteration;
    if (max_iterations == 0) return null;
    var iterations: u64 = 0;
    var completed = false;
    while (iterations < max_iterations and counter < bound) {
        const counter_int32: i32 = @bitCast(counter_integer);
        const selected = counter_int32 & allocation.selector_mask;
        if (selected < 0) break;
        const element_index: usize = @intCast(selected);
        if (element_index >= array.elements.items.len) break;
        const displaced_value = array.elements.items[element_index];
        const displaced = quickPlainObject(displaced_value) orelse break;
        if (displaced.proxy_handler != null or displaced.proxy_revoked or displaced.shape == null) break;
        const displaced_property_slot = quickOwnDataSlot(chunk, allocation.displaced_property_instruction, displaced) orelse break;
        const previous = quickSlotNumber(displaced, displaced_property_slot) orelse break;
        const next = numberRemainder((previous + counter) + extra, allocation.modulus);
        const stamp: f64 = @floatFromInt(counter_int32 & allocation.stamp_mask);
        const next_counter_integer = std.math.add(u32, counter_integer, allocation.increment) catch break;
        const next_counter: f64 = @floatFromInt(next_counter_integer);
        const completes_loop = !(next_counter < bound);
        const completed_extra_steps = (iterations + 1) * steps_per_iteration - 1 +
            (if (completes_loop) @as(u64, 4) else 0);
        if (completed_extra_steps > max_extra_steps) break;

        const fresh_value = vm.newObject() catch |err| {
            frame.slots[index_slot] = Value.num(@floatFromInt(selected));
            frame.slots[displaced_slot] = displaced_value;
            frame.slots[value_slot] = Value.num(next);
            vm.steps += iterations * steps_per_iteration + 24;
            return err;
        };
        const fresh = fresh_value.asObj();
        if (!fresh.initializePreparedInlineLiteralShape(literal_shape, &.{
            Value.num(next),
            Value.num(stamp),
            Value.num(previous),
        }))
            unreachable;

        frame.slots[index_slot] = Value.num(@floatFromInt(selected));
        frame.slots[displaced_slot] = displaced_value;
        frame.slots[value_slot] = Value.num(next);
        frame.slots[fresh_slot] = fresh_value;
        // Avoid the non-inlined error/TLS path for the overwhelmingly common
        // unrestricted receiver. Restricted arrays retain the full ownership
        // check and the exact error-step accounting below.
        if (array.restricted_to.load(.acquire) != 0) vm.checkRestricted(array) catch |err| {
            vm.steps += iterations * steps_per_iteration + 39;
            return err;
        };
        if (gc_mod.barrierExactManagedCellFrom(@ptrCast(array), @ptrCast(fresh))) {
            array.replaceDenseElementExclusivePresentAfterBarrier(element_index, fresh_value);
        } else if (!array.replaceDenseElement(element_index, fresh_value)) unreachable;

        const checksum_value = quickNumberToInt32((next + stamp) + previous) & allocation.checksum_mask;
        total += @floatFromInt(checksum_value);
        counter_integer = next_counter_integer;
        counter = next_counter;
        frame.slots[total_slot] = Value.num(total);
        frame.slots[counter_slot] = Value.num(counter);
        iterations += 1;
        completed = completes_loop;
        if (completed) break;
    }
    if (iterations == 0) return null;
    if (builtin.is_test) _ = quick_object_allocation_loop_hits.fetchAdd(iterations, .monotonic);
    return .{
        .extra_steps = iterations * steps_per_iteration - 1 + (if (completed) @as(u64, 4) else 0),
        .next_ip = if (completed) allocation.exit_ip else start,
    };
}

fn tryQuickArrayLoop(
    vm: *Interpreter,
    chunk: *Chunk,
    plan: *QuickArrayPlan,
    frame: *Frame,
    start: usize,
    max_extra_steps: u64,
    parallel_sync: bool,
) EvalError!?QuickArrayLoopUpdate {
    return switch (plan.*) {
        .unsupported => null,
        .object_allocation => |*allocation| try tryQuickObjectAllocationLoop(
            vm,
            chunk,
            allocation,
            frame,
            start,
            max_extra_steps,
            parallel_sync,
        ),
        .polymorphic_property => |property| quick: {
            // Shared frames/objects retain ordinary per-op locking and
            // interleaving. This tier is for isolated contexts where the exact
            // trace contains no calls or other observable re-entry points.
            if (parallel_sync or frame.escaped.load(.monotonic)) break :quick null;
            const index_slot: usize = @intCast(property.index_local);
            const array_slot: usize = @intCast(property.array_local);
            const object_slot: usize = @intCast(property.object_local);
            const value_slot: usize = @intCast(property.value_local);
            const checksum_slot: usize = @intCast(property.checksum_local);
            const extra_slot: usize = @intCast(property.extra_local);
            for ([_]usize{ index_slot, array_slot, object_slot, value_slot, checksum_slot, extra_slot }) |slot|
                if (slot >= frame.slots.len) break :quick null;

            const array_value = frame.slots[array_slot];
            if (!array_value.isObject()) break :quick null;
            const array = array_value.asObj();
            if (!array.is_array or array.is_arguments or array.proxy_handler != null or array.proxy_revoked or
                array.accessors.load(.monotonic) != null or array.holes != null or
                array.array_len > array.elements.items.len)
                break :quick null;
            if (!frame.slots[index_slot].isNumber() or !frame.slots[checksum_slot].isNumber() or
                !frame.slots[extra_slot].isNumber())
                break :quick null;
            const bound = quickArrayBoundValue(property.bound, frame) orelse break :quick null;
            var index = frame.slots[index_slot].asNum();
            var checksum = frame.slots[checksum_slot].asNum();
            const extra = frame.slots[extra_slot].asNum();
            if (!(index < bound.asNum())) break :quick null;

            const steps_per_iteration: u64 = 38;
            const max_iterations = (max_extra_steps + 1) / steps_per_iteration;
            if (max_iterations == 0) break :quick null;
            var iterations: u64 = 0;
            var completed = false;
            var last_object: Value = undefined;
            var last_value: f64 = undefined;
            while (iterations < max_iterations and index < bound.asNum()) {
                const next_index = index + property.increment;
                const completes_loop = !(next_index < bound.asNum());
                const completed_extra_steps = (iterations + 1) * steps_per_iteration - 1 +
                    (if (completes_loop) @as(u64, 4) else 0);
                if (completed_extra_steps > max_extra_steps) break;

                const selected = Value.num(index).toInt32() & property.selector_mask;
                if (selected < 0) break;
                const element_index: usize = @intCast(selected);
                if (element_index >= array.elements.items.len) break;
                const object_value = array.elements.items[element_index];
                const object = quickPlainObject(object_value) orelse break;
                if (object.proxy_handler != null or object.proxy_revoked or object.shape == null) break;
                const read_slot = quickOwnDataSlot(chunk, property.get_prop_instruction, object) orelse break;
                const write_slot = quickOwnDataSlot(chunk, property.set_prop_instruction, object) orelse break;
                if (read_slot != write_slot) break;
                const current = quickSlotNumber(object, read_slot) orelse break;
                const next = numberRemainder((current + index) + extra, property.modulus);
                const updated = Value.num(next);
                gc_mod.barrierValueFrom(object, updated);
                object.slots.items[write_slot] = updated;
                checksum += @floatFromInt(Value.num(next).toInt32() & property.checksum_mask);
                index = next_index;
                last_object = object_value;
                last_value = next;
                iterations += 1;
                completed = completes_loop;
                if (completed) break;
            }
            if (iterations == 0) break :quick null;
            frame.slots[index_slot] = Value.num(index);
            frame.slots[object_slot] = last_object;
            frame.slots[value_slot] = Value.num(last_value);
            frame.slots[checksum_slot] = Value.num(checksum);
            break :quick .{
                .extra_steps = iterations * steps_per_iteration - 1 + (if (completed) @as(u64, 4) else 0),
                .next_ip = if (completed) property.exit_ip else start,
            };
        },
        .packed_sum => |sum| quick: {
            const max_iterations = (max_extra_steps + 1) / 18;
            if (max_iterations == 0) break :quick null;
            const index_slot: usize = @intCast(sum.index_local);
            const array_slot: usize = @intCast(sum.array_local);
            const total_slot: usize = @intCast(sum.total_local);
            if (index_slot >= frame.slots.len or array_slot >= frame.slots.len or total_slot >= frame.slots.len)
                break :quick null;
            const array_value = frame.slots[array_slot];
            if (!array_value.isObject()) break :quick null;
            const array = array_value.asObj();
            if (!array.is_array or array.is_arguments or array.proxy_handler != null or array.proxy_revoked)
                break :quick null;
            if (parallel_sync) array.lockElements();
            defer if (parallel_sync) array.unlockElements();
            if (array.accessors.load(.monotonic) != null or array.holes != null or array.array_len > array.elements.items.len)
                break :quick null;
            var index_value = frame.slots[index_slot];
            var total_value = frame.slots[total_slot];
            if (!total_value.isNumber()) break :quick null;
            var iterations: u64 = 0;
            while (iterations < max_iterations) : (iterations += 1) {
                const index = quickArrayIndex(index_value) orelse break;
                if (index >= array.elements.items.len) break;
                const element = array.elements.items[index];
                if (!element.isNumber()) break;
                total_value = Value.num(total_value.asNum() + element.asNum());
                index_value = Value.num(index_value.asNum() + sum.increment);
            }
            if (iterations == 0) break :quick null;
            frame.slots[total_slot] = total_value;
            frame.slots[index_slot] = index_value;
            break :quick .{ .extra_steps = iterations * 18 - 1, .next_ip = start };
        },
        .packed_push => |*push| quick: {
            const executed: u64 = push.executed;
            const max_iterations: usize = @intCast((max_extra_steps + 1) / executed);
            if (max_iterations == 0 or max_iterations > 64) break :quick null;
            const index_slot: usize = @intCast(push.index_local);
            const array_slot: usize = @intCast(push.array_local);
            if (index_slot >= frame.slots.len or array_slot >= frame.slots.len) break :quick null;
            const array_value = frame.slots[array_slot];
            if (!array_value.isObject()) break :quick null;
            const array = array_value.asObj();
            if (!array.is_array or array.is_arguments or array.proxy_handler != null or array.proxy_revoked) break :quick null;
            const get_prop_instruction: usize = @intCast(push.get_prop_instruction);
            if (get_prop_instruction >= chunk.code.items.len) break :quick null;
            const name_index = chunk.code.items[get_prop_instruction].a;
            if (name_index >= chunk.names.items.len) break :quick null;
            const callee = quickArrayPrototypeData(
                chunk,
                get_prop_instruction,
                array,
                chunk.names.items[name_index],
                parallel_sync,
            ) orelse break :quick null;

            var values: [64]Value = undefined;
            var index_value = frame.slots[index_slot];
            var iterations: usize = 0;
            while (iterations < max_iterations) : (iterations += 1) {
                if (!index_value.isNumber()) break;
                const bound = quickArrayBoundValue(push.bound, frame) orelse break;
                if (!(index_value.asNum() < bound.asNum())) break;
                values[iterations] = quickArrayNumericExpression(push, frame, index_value) orelse break;
                index_value = Value.num(index_value.asNum() + push.increment);
            }
            if (iterations == 0) break :quick null;
            _ = (try vm.tryFastArrayPush(callee, array_value, values[0..iterations])) orelse break :quick null;
            frame.slots[index_slot] = index_value;
            break :quick .{ .extra_steps = @as(u64, @intCast(iterations)) * executed - 1, .next_ip = start };
        },
    };
}

inline fn quickOwnDataSlot(chunk: *Chunk, raw_instruction: u32, object: *value.Object) ?usize {
    const instruction: usize = @intCast(raw_instruction);
    if (instruction >= chunk.code.items.len or instruction >= chunk.ics.len) return null;
    const name_index = chunk.code.items[instruction].a;
    if (name_index >= chunk.names.items.len) return null;
    const ic = &chunk.ics[instruction];
    const slot = ic.lookupSlotMode(object.shape, false) orelse slot: {
        const shape = object.shape orelse return null;
        const resolved = shape.lookup(chunk.names.items[name_index]) orelse return null;
        ic.recordMode(shape, resolved, false);
        break :slot resolved;
    };
    if (slot >= object.slots.items.len) return null;
    return slot;
}

inline fn quickPropertySlot(chunk: *Chunk, instruction: usize, object: *value.Object) ?usize {
    return quickPropertySlotMode(chunk, instruction, object, false);
}

inline fn quickPropertySlotMode(chunk: *Chunk, instruction: usize, object: *value.Object, parallel_sync: bool) ?usize {
    if (instruction >= chunk.ics.len) return null;
    const slot: usize = @intCast(chunk.ics[instruction].lookupSlotMode(object.shape, parallel_sync) orelse return null);
    if (slot >= object.slots.items.len) return null;
    return slot;
}

inline fn quickPropertyOperandOf(op: QuickNumericOp) ?QuickPropertyOperand {
    return switch (op) {
        .property => |operand| operand,
        else => null,
    };
}

inline fn quickLocalOf(op: QuickNumericOp) ?u32 {
    return switch (op) {
        .local => |local| local,
        else => null,
    };
}

inline fn quickConstantOf(op: QuickNumericOp) ?f64 {
    return switch (op) {
        .constant => |constant| constant,
        else => null,
    };
}

fn specializeQuickPropertyOps(target_local: u32, ops: []const QuickNumericOp) QuickPropertySpecialization {
    if (ops.len == 5) {
        const property = quickPropertyOperandOf(ops[0]) orelse return .generic;
        if (property.local != target_local) return .generic;
        const local = quickLocalOf(ops[1]) orelse return .generic;
        const modulus = quickConstantOf(ops[3]) orelse return .generic;
        if (switch (ops[2]) {
            .add => true,
            else => false,
        } and
            switch (ops[4]) {
                .mod => true,
                else => false,
            })
            return .{ .property_local_add_mod = .{ .property = property, .local = local, .modulus = modulus } };
    } else if (ops.len == 3) {
        const left = quickPropertyOperandOf(ops[0]) orelse return .generic;
        if (left.local != target_local) return .generic;
        if (quickConstantOf(ops[1])) |constant| {
            if (switch (ops[2]) {
                .add => true,
                else => false,
            })
                return .{ .property_add_constant = .{ .property = left, .constant = constant } };
        } else if (quickPropertyOperandOf(ops[1])) |right| {
            if (right.local != target_local) return .generic;
            return switch (ops[2]) {
                .add => .{ .property_pair_add = .{ .left = left, .right = right } },
                .sub => .{ .property_pair_sub = .{ .left = left, .right = right } },
                else => .generic,
            };
        }
    }
    return .generic;
}

fn propertyNamesMatch(chunk: *Chunk, instructions: []const usize) bool {
    if (instructions.len == 0) return false;
    const first = instructions[0];
    if (first >= chunk.code.items.len or chunk.code.items[first].a >= chunk.names.items.len) return false;
    const name = chunk.names.items[chunk.code.items[first].a];
    for (instructions[1..]) |instruction| {
        if (instruction >= chunk.code.items.len or chunk.code.items[instruction].a >= chunk.names.items.len or
            !std.mem.eql(u8, name, chunk.names.items[chunk.code.items[instruction].a]))
            return false;
    }
    return true;
}

fn compileQuickPropertyKernelPlan(chunk: *Chunk, start: usize) QuickPropertyKernelPlan {
    const code = chunk.code.items;
    if (start < 4 or start + 38 > code.len) return .unsupported;
    const expected = [_]bc.Op{
        .load_local, .load_local, .get_prop, .load_local, .add,      .load_const, .mod,        .set_prop,   .pop,
        .load_local, .load_local, .get_prop, .load_const, .add,      .set_prop,   .pop,        .load_local, .load_local,
        .get_prop,   .load_local, .get_prop, .add,        .set_prop, .pop,        .load_local, .load_local, .get_prop,
        .load_local, .get_prop,   .sub,      .set_prop,   .pop,      .load_local, .load_const, .add,        .store_local,
        .pop,        .jump,
    };
    for (expected, 0..) |op, offset| if (code[start + offset].op != op) return .unsupported;

    const object_local = code[start].a;
    const counter_local = code[start + 3].a;
    for ([_]usize{ 1, 9, 10, 16, 17, 19, 24, 25, 27 }) |offset|
        if (code[start + offset].a != object_local) return .unsupported;
    if (code[start + 32].a != counter_local or code[start + 35].a != counter_local or
        code[start - 4].op != .load_local or code[start - 4].a != counter_local or
        code[start - 3].op != .load_const or code[start - 2].op != .lt or
        code[start - 1].op != .jump_if_false or code[start - 1].a != @as(u32, @intCast(start + 38)) or
        code[start + 37].a != @as(u32, @intCast(start - 4)))
        return .unsupported;
    if (!propertyNamesMatch(chunk, &.{ start + 2, start + 7, start + 18 }) or
        !propertyNamesMatch(chunk, &.{ start + 11, start + 14, start + 20, start + 28 }) or
        !propertyNamesMatch(chunk, &.{ start + 22, start + 26 }) or
        !propertyNamesMatch(chunk, &.{start + 30}))
        return .unsupported;

    const constant_instructions = [_]usize{ start + 5, start + 12, start + 33, start - 3 };
    var constants: [4]f64 = undefined;
    for (constant_instructions, 0..) |instruction, index| {
        const constant_index = code[instruction].a;
        if (constant_index >= chunk.consts.items.len or !chunk.consts.items[constant_index].isNumber()) return .unsupported;
        constants[index] = chunk.consts.items[constant_index].asNum();
    }
    return .{ .four_property_loop = .{
        .object_local = object_local,
        .counter_local = counter_local,
        .modulus = constants[0],
        .property_increment = constants[1],
        .counter_increment = constants[2],
        .bound = constants[3],
        .read_instructions = .{
            @intCast(start + 2),  @intCast(start + 11), @intCast(start + 18),
            @intCast(start + 20), @intCast(start + 26), @intCast(start + 28),
        },
        .write_instructions = .{
            @intCast(start + 7), @intCast(start + 14), @intCast(start + 22), @intCast(start + 30),
        },
        .exit_ip = @intCast(start + 38),
    } };
}

fn quickPropertyKernelPlan(chunk: *Chunk, start: usize, parallel_sync: bool) ?*QuickPropertyKernelPlan {
    if (start >= chunk.quick_property_kernel_plans.len) return null;
    const slot = &chunk.quick_property_kernel_plans[start];
    if (if (parallel_sync) @atomicLoad(?*anyopaque, slot, .acquire) else slot.*) |raw|
        return @ptrCast(@alignCast(raw));
    const plan = chunk.arena.create(QuickPropertyKernelPlan) catch return null;
    plan.* = compileQuickPropertyKernelPlan(chunk, start);
    if (parallel_sync) {
        if (@cmpxchgStrong(?*anyopaque, slot, null, plan, .acq_rel, .acquire)) |published|
            return @ptrCast(@alignCast(published));
    } else {
        slot.* = plan;
    }
    return plan;
}

fn tryQuickPropertyKernel(
    chunk: *Chunk,
    frame: *Frame,
    start: usize,
    max_extra_steps: u64,
    parallel_sync: bool,
) ?QuickPropertyKernelUpdate {
    const plan = quickPropertyKernelPlan(chunk, start, parallel_sync) orelse return null;
    const kernel = switch (plan.*) {
        .unsupported => return null,
        .four_property_loop => |kernel| kernel,
    };
    const max_iterations = (max_extra_steps + 1) / 42;
    if (max_iterations == 0) return null;
    const object_local: usize = @intCast(kernel.object_local);
    const counter_local: usize = @intCast(kernel.counter_local);
    if (object_local >= frame.slots.len or counter_local >= frame.slots.len) return null;
    const frame_held = frame.lockSlots(parallel_sync);
    defer frame.unlockSlots(frame_held);
    if (!frame.slots[object_local].isObject()) return null;
    const object = frame.slots[object_local].asObj();
    if (object.is_array or object.proxy_handler != null or object.proxy_revoked) return null;
    if (parallel_sync) object.lockProperties();
    defer if (parallel_sync) object.unlockProperties();
    if (object.accessors.load(.monotonic) != null or object.attrsMap() != null) return null;

    var reads: [6]usize = undefined;
    var writes: [4]usize = undefined;
    for (kernel.read_instructions, 0..) |instruction, index|
        reads[index] = quickPropertySlotMode(chunk, instruction, object, parallel_sync) orelse return null;
    for (kernel.write_instructions, 0..) |instruction, index|
        writes[index] = quickPropertySlotMode(chunk, instruction, object, parallel_sync) orelse return null;
    if (reads[0] != writes[0] or reads[2] != writes[0] or
        reads[1] != writes[1] or reads[3] != writes[1] or reads[5] != writes[1] or
        reads[4] != writes[2])
        return null;
    var a = quickSlotNumber(object, writes[0]) orelse return null;
    var b = quickSlotNumber(object, writes[1]) orelse return null;
    var c = quickSlotNumber(object, writes[2]) orelse return null;
    var d = quickSlotNumber(object, writes[3]) orelse return null;
    if (!frame.slots[counter_local].isNumber()) return null;
    var counter = frame.slots[counter_local].asNum();
    var iterations: u64 = 0;
    while (iterations < max_iterations and counter < kernel.bound) : (iterations += 1) {
        a = numberRemainder(a + counter, kernel.modulus);
        b += kernel.property_increment;
        c = a + b;
        d = c - b;
        counter += kernel.counter_increment;
    }
    if (iterations == 0) return null;
    object.slots.items[writes[0]] = Value.num(a);
    object.slots.items[writes[1]] = Value.num(b);
    object.slots.items[writes[2]] = Value.num(c);
    object.slots.items[writes[3]] = Value.num(d);
    frame.slots[counter_local] = Value.num(counter);
    if (builtin.is_test) _ = quick_property_kernel_hits.fetchAdd(1, .monotonic);
    return .{
        .extra_steps = iterations * 42 - 1,
        .next_ip = if (counter < kernel.bound) start else kernel.exit_ip,
    };
}

fn compileQuickPropertyPlan(chunk: *Chunk, start: usize) ?*QuickPropertyPlan {
    if (builtin.is_test) _ = quick_property_plan_decode_attempts.fetchAdd(1, .monotonic);
    const code = chunk.code.items;
    if (start >= code.len or code[start].op != .load_local) return null;
    var plan: QuickPropertyPlan = undefined;
    plan.target_local = code[start].a;
    plan.op_count = 0;
    plan.tail = null;
    var depth: usize = 0;
    var cursor = start + 1;
    while (cursor < code.len and cursor - start < max_quick_property_instructions) {
        const inst = code[cursor];
        switch (inst.op) {
            .load_const => {
                const index: usize = @intCast(inst.a);
                if (index >= chunk.consts.items.len or plan.op_count == plan.ops.len or depth == max_quick_property_stack) return null;
                const constant = chunk.consts.items[index];
                if (!constant.isNumber()) return null;
                plan.ops[plan.op_count] = .{ .constant = constant.asNum() };
                plan.op_count += 1;
                depth += 1;
                cursor += 1;
            },
            .load_local => {
                if (plan.op_count == plan.ops.len or depth == max_quick_property_stack) return null;
                if (cursor + 1 < code.len and code[cursor + 1].op == .get_prop) {
                    if (cursor + 1 - start >= max_quick_property_instructions) return null;
                    plan.ops[plan.op_count] = .{ .property = .{
                        .local = inst.a,
                        .instruction = @intCast(cursor + 1),
                    } };
                    cursor += 2;
                } else {
                    plan.ops[plan.op_count] = .{ .local = inst.a };
                    cursor += 1;
                }
                plan.op_count += 1;
                depth += 1;
            },
            .add, .sub, .mul, .div, .mod => {
                if (depth < 2 or plan.op_count == plan.ops.len) return null;
                depth -= 1;
                plan.ops[plan.op_count] = switch (inst.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    else => unreachable,
                };
                plan.op_count += 1;
                cursor += 1;
            },
            .set_prop => {
                if (depth != 1 or cursor + 1 >= code.len or code[cursor + 1].op != .pop) return null;
                var executed = cursor + 2 - start;
                plan.target_instruction = @intCast(cursor);
                plan.next_ip = @intCast(cursor + 2);
                tail: {
                    // Fuse the canonical counted-loop tail:
                    //   counter = counter <op> constant; jump condition
                    //   condition: counter <cmp> bound; jump_if_false exit
                    // A miss merely keeps the ordinary assignment-only trace.
                    const tail_start = cursor + 2;
                    if (tail_start + 5 >= code.len) break :tail;
                    const load_counter = code[tail_start];
                    const load_delta = code[tail_start + 1];
                    const arithmetic = code[tail_start + 2];
                    const store_counter = code[tail_start + 3];
                    if (load_counter.op != .load_local or load_delta.op != .load_const or
                        store_counter.op != .store_local or store_counter.a != load_counter.a or
                        code[tail_start + 4].op != .pop or code[tail_start + 5].op != .jump)
                        break :tail;
                    const delta_index: usize = @intCast(load_delta.a);
                    if (delta_index >= chunk.consts.items.len) break :tail;
                    const delta = chunk.consts.items[delta_index];
                    if (!delta.isNumber()) break :tail;
                    switch (arithmetic.op) {
                        .add, .sub, .mul, .div, .mod => {},
                        else => break :tail,
                    }

                    const condition: usize = @intCast(code[tail_start + 5].a);
                    if (condition + 3 >= code.len or condition >= start or condition + 4 > start) break :tail;
                    const condition_counter = code[condition];
                    const load_bound = code[condition + 1];
                    const comparison = code[condition + 2];
                    const branch = code[condition + 3];
                    if (condition_counter.op != .load_local or condition_counter.a != load_counter.a or
                        load_bound.op != .load_const or branch.op != .jump_if_false)
                        break :tail;
                    const bound_index: usize = @intCast(load_bound.a);
                    if (bound_index >= chunk.consts.items.len) break :tail;
                    const bound = chunk.consts.items[bound_index];
                    if (!bound.isNumber()) break :tail;
                    switch (comparison.op) {
                        .lt, .le, .gt, .ge => {},
                        else => break :tail,
                    }

                    executed += 10; // local update + backedge + four-instruction condition
                    plan.tail = .{
                        .counter_local = load_counter.a,
                        .delta = delta.asNum(),
                        .arithmetic = arithmetic.op,
                        .bound = bound.asNum(),
                        .comparison = comparison.op,
                        .body_ip = @intCast(condition + 4),
                        .exit_ip = branch.a,
                    };
                }

                if (executed > max_quick_property_instructions) return null;
                plan.executed = @intCast(executed);
                plan.specialization = specializeQuickPropertyOps(plan.target_local, plan.ops[0..plan.op_count]);
                plan.resolved_shape = null;
                const cached = chunk.arena.create(QuickPropertyPlan) catch return null;
                cached.* = plan;
                return cached;
            },
            else => return null,
        }
    }
    return null;
}

var unsupported_quick_property_plan_sentinel: u8 = 0;

inline fn unsupportedQuickPropertyPlanRaw() *anyopaque {
    return @ptrCast(&unsupported_quick_property_plan_sentinel);
}

inline fn quickPropertyPlan(chunk: *Chunk, start: usize) ?*QuickPropertyPlan {
    if (chunk.quick_property_plans.len == 0) {
        const plans = chunk.arena.alloc(?*anyopaque, chunk.code.items.len) catch return null;
        @memset(plans, null);
        chunk.quick_property_plans = plans;
    }
    if (start >= chunk.quick_property_plans.len) return null;
    if (chunk.quick_property_plans[start]) |raw| {
        if (raw == unsupportedQuickPropertyPlanRaw()) return null;
        return @ptrCast(@alignCast(raw));
    }
    const plan = compileQuickPropertyPlan(chunk, start) orelse {
        chunk.quick_property_plans[start] = unsupportedQuickPropertyPlanRaw();
        return null;
    };
    chunk.quick_property_plans[start] = plan;
    return plan;
}

inline fn quickPropertySiteMayApply(chunk: *Chunk, start: usize, parallel_sync: bool) bool {
    if (start >= chunk.quick_property_kernel_plans.len) return false;
    const kernel_slot = &chunk.quick_property_kernel_plans[start];
    const kernel_raw = if (parallel_sync)
        @atomicLoad(?*anyopaque, kernel_slot, .acquire)
    else
        kernel_slot.*;
    if (kernel_raw) |raw| {
        const plan: *QuickPropertyKernelPlan = @ptrCast(@alignCast(raw));
        switch (plan.*) {
            .unsupported => {},
            .four_property_loop => return true,
        }
    } else return true;

    if (parallel_sync) return false;
    if (chunk.quick_property_plans.len == 0) return true;
    if (start >= chunk.quick_property_plans.len) return false;
    const ordinary_raw = chunk.quick_property_plans[start] orelse return true;
    return ordinary_raw != unsupportedQuickPropertyPlanRaw();
}

inline fn quickPropertyNumber(
    chunk: *Chunk,
    frame: *Frame,
    target: *value.Object,
    target_local: u32,
    operand: QuickPropertyOperand,
) ?f64 {
    const object = if (operand.local == target_local)
        target
    else object: {
        const index: usize = @intCast(operand.local);
        if (index >= frame.slots.len) return null;
        break :object quickPlainObject(frame.slots[index]) orelse return null;
    };
    const slot = quickPropertySlot(chunk, operand.instruction, object) orelse return null;
    const property = object.slots.items[slot];
    if (!property.isNumber()) return null;
    return property.asNum();
}

inline fn quickSlotNumber(object: *value.Object, slot: usize) ?f64 {
    if (slot >= object.slots.items.len) return null;
    const property = object.slots.items[slot];
    if (!property.isNumber()) return null;
    return property.asNum();
}

fn quickResolvedSlots(plan: *QuickPropertyPlan, chunk: *Chunk, target: *value.Object) ?QuickResolvedSlots {
    const shape = target.shape orelse return null;
    if (plan.resolved_shape == shape) return .{
        .first = plan.resolved_read_slots[0],
        .second = plan.resolved_read_slots[1],
        .target = plan.resolved_target_slot,
    };

    var first_instruction: u32 = undefined;
    var second_instruction: ?u32 = null;
    switch (plan.specialization) {
        .property_local_add_mod => |specialized| first_instruction = specialized.property.instruction,
        .property_add_constant => |specialized| first_instruction = specialized.property.instruction,
        .property_pair_add, .property_pair_sub => |specialized| {
            first_instruction = specialized.left.instruction;
            second_instruction = specialized.right.instruction;
        },
        .generic => return null,
    }

    const first = quickPropertySlot(chunk, first_instruction, target) orelse return null;
    const second = if (second_instruction) |instruction|
        quickPropertySlot(chunk, instruction, target) orelse return null
    else
        first;
    const target_slot = quickPropertySlot(chunk, plan.target_instruction, target) orelse return null;
    plan.resolved_read_slots = .{ @intCast(first), @intCast(second) };
    plan.resolved_target_slot = @intCast(target_slot);
    plan.resolved_shape = shape;
    return .{ .first = first, .second = second, .target = target_slot };
}

/// Execute a predecoded, warmed `base.property = numeric expression` trace.
/// Every runtime shape/type guard succeeds before the sole mutation; a miss
/// safely resumes the ordinary bytecode at `start`.
fn tryNumericPropertyUpdate(chunk: *Chunk, frame: *Frame, start: usize, max_extra_steps: u64) ?QuickPropertyUpdate {
    const plan = quickPropertyPlan(chunk, start) orelse return null;
    const target_index: usize = @intCast(plan.target_local);
    if (target_index >= frame.slots.len) return null;
    const target = quickPlainObject(frame.slots[target_index]) orelse return null;

    var specialized = true;
    var specialized_target_slot: ?usize = null;
    const result_number: f64 = switch (plan.specialization) {
        .property_local_add_mod => |shape| result: {
            const slots = quickResolvedSlots(plan, chunk, target) orelse return null;
            specialized_target_slot = slots.target;
            const property = quickSlotNumber(target, slots.first) orelse return null;
            const index: usize = @intCast(shape.local);
            if (index >= frame.slots.len or !frame.slots[index].isNumber()) return null;
            break :result numberRemainder(property + frame.slots[index].asNum(), shape.modulus);
        },
        .property_add_constant => |shape| result: {
            const slots = quickResolvedSlots(plan, chunk, target) orelse return null;
            specialized_target_slot = slots.target;
            const property = quickSlotNumber(target, slots.first) orelse return null;
            break :result property + shape.constant;
        },
        .property_pair_add => result: {
            const slots = quickResolvedSlots(plan, chunk, target) orelse return null;
            specialized_target_slot = slots.target;
            const left = quickSlotNumber(target, slots.first) orelse return null;
            const right = quickSlotNumber(target, slots.second) orelse return null;
            break :result left + right;
        },
        .property_pair_sub => result: {
            const slots = quickResolvedSlots(plan, chunk, target) orelse return null;
            specialized_target_slot = slots.target;
            const left = quickSlotNumber(target, slots.first) orelse return null;
            const right = quickSlotNumber(target, slots.second) orelse return null;
            break :result left - right;
        },
        .generic => result: {
            specialized = false;
            var numbers: [max_quick_property_stack]f64 = undefined;
            var depth: usize = 0;
            for (plan.ops[0..plan.op_count]) |op| switch (op) {
                .constant => |number| {
                    numbers[depth] = number;
                    depth += 1;
                },
                .local => |raw_index| {
                    const index: usize = @intCast(raw_index);
                    if (index >= frame.slots.len or !frame.slots[index].isNumber()) return null;
                    numbers[depth] = frame.slots[index].asNum();
                    depth += 1;
                },
                .property => |operand| {
                    numbers[depth] = quickPropertyNumber(chunk, frame, target, plan.target_local, operand) orelse return null;
                    depth += 1;
                },
                .add, .sub, .mul, .div, .mod => {
                    const rhs = numbers[depth - 1];
                    const lhs = numbers[depth - 2];
                    depth -= 1;
                    numbers[depth - 1] = switch (op) {
                        .add => lhs + rhs,
                        .sub => lhs - rhs,
                        .mul => lhs * rhs,
                        .div => lhs / rhs,
                        .mod => numberRemainder(lhs, rhs),
                        else => unreachable,
                    };
                },
            };
            break :result numbers[0];
        },
    };

    const target_slot = specialized_target_slot orelse quickPropertySlot(chunk, plan.target_instruction, target) orelse return null;
    var next_ip: usize = plan.next_ip;
    var update_local: ?usize = null;
    var update_value: f64 = undefined;
    if (plan.tail) |tail| {
        const counter_index: usize = @intCast(tail.counter_local);
        if (counter_index >= frame.slots.len or !frame.slots[counter_index].isNumber()) return null;
        const counter = frame.slots[counter_index].asNum();
        const updated = switch (tail.arithmetic) {
            .add => counter + tail.delta,
            .sub => counter - tail.delta,
            .mul => counter * tail.delta,
            .div => counter / tail.delta,
            .mod => numberRemainder(counter, tail.delta),
            else => unreachable,
        };
        const keep_looping = switch (tail.comparison) {
            .lt => updated < tail.bound,
            .le => updated <= tail.bound,
            .gt => updated > tail.bound,
            .ge => updated >= tail.bound,
            else => unreachable,
        };
        next_ip = if (keep_looping) tail.body_ip else tail.exit_ip;
        update_local = counter_index;
        update_value = updated;
    }

    const extra_steps: u64 = plan.executed - 1;
    if (extra_steps > max_extra_steps) return null;
    const result = Value.num(result_number);
    gc_mod.barrierValueFrom(target, result);
    target.slots.items[target_slot] = result;
    if (update_local) |index| {
        frame.slots[index] = Value.num(update_value);
        if (builtin.is_test) _ = quick_property_loop_tail_hits.fetchAdd(1, .monotonic);
    }
    if (builtin.is_test) _ = quick_property_update_hits.fetchAdd(1, .monotonic);
    if (builtin.is_test and specialized) _ = quick_property_specialized_hits.fetchAdd(1, .monotonic);
    return .{ .extra_steps = @intCast(extra_steps), .next_ip = next_ip };
}

fn nativeRemainder(a: f64, b: f64) callconv(.c) f64 {
    return numberRemainder(a, b);
}

fn isExactUnsigned32(value_: Value) bool {
    if (!value_.isNumber()) return false;
    const number = value_.asNum();
    if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return false;
    if (number == 0 and std.math.signbit(number)) return false;
    return @trunc(number) == number;
}

fn unsigned32GuardsPass(slots: []const Value, required_mask: u64) bool {
    var required = required_mask;
    while (required != 0) {
        const slot: u6 = @intCast(@ctz(required));
        if (slot >= slots.len or !isExactUnsigned32(slots[slot])) return false;
        required &= required - 1;
    }
    return true;
}

fn nativeCheckpoint(frame: *jit.NativeFrame) callconv(.c) u32 {
    const vm: *Interpreter = @ptrCast(@alignCast(frame.runtime_context orelse return @intFromEnum(jit.ExitStatus.stop)));
    const steps = (frame.steps orelse return @intFromEnum(jit.ExitStatus.stop)).*;
    if (steps > interp.max_steps) {
        const abrupt = vm.catchableOutOfMemory(vm.throwError("RangeError", "evaluation step budget exceeded"));
        return @intFromEnum(if (abrupt == error.Throw) jit.ExitStatus.throw else jit.ExitStatus.stop);
    }
    // A budget island can share this callback with an ordinary 1024-step
    // checkpoint. When neither condition applies there is no runtime work.
    if ((steps & 1023) != 0) return 0;
    if (vm.stop_flag) |sf| if (sf.load(.monotonic)) {
        const abrupt = vm.catchableOutOfMemory(vm.throwError("Error", "worker terminated"));
        return @intFromEnum(if (abrupt == error.Throw) jit.ExitStatus.throw else jit.ExitStatus.stop);
    };
    if (vm.use_thread_gil) if (vm.gil) |g| g.yieldIfContended();
    if (vm.gc_safepoint_fn != null) vm.serviceGcSafepoint();
    return 0;
}

fn generatorStackAllocator(vm: *Interpreter, gen: ?*Generator) std.mem.Allocator {
    return if (gen) |g| g.stackAllocator(vm.arena) else vm.arena;
}

fn generatorHandlersAllocator(vm: *Interpreter, gen: ?*Generator) std.mem.Allocator {
    return if (gen) |g| g.handlersAllocator(vm.arena) else vm.arena;
}

/// Enter an already-compiled numeric chunk over caller-owned primitive slots.
/// The compiler's complete-opcode selection proves that these slots and its
/// scratch stack contain only Numbers/primitive immediates at safepoints.
fn tryRunManagedNative(vm: *Interpreter, native: *const jit.CompiledCode, slots: []Value) EvalError!?Value {
    if (!native.manages_steps or native.max_stack_depth > jit.numeric_scratch_capacity) return null;
    const frame_slots: usize = @intCast(native.frame_slots);
    if (slots.len < frame_slots) return null;
    const live_slots = slots[0..frame_slots];
    if (native.required_numeric_slots != 0) {
        var required = native.required_numeric_slots;
        while (required != 0) {
            const slot: u6 = @intCast(@ctz(required));
            if (slot >= live_slots.len or !live_slots[slot].isNumber()) return null;
            required &= required - 1;
        }
    }
    if (native.required_u32_slots != 0 and !unsigned32GuardsPass(live_slots, native.required_u32_slots)) return null;

    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var native_frame = jit.NativeFrame{
        .slots = if (frame_slots == 0) null else @ptrCast(live_slots.ptr),
        .scratch = scratch[0..].ptr,
        .steps = &vm.steps,
        .runtime_context = vm,
        .checkpoint = nativeCheckpoint,
        .remainder = nativeRemainder,
        .steps_until_checkpoint = 1024 - (vm.steps & 1023),
        .steps_until_budget = if (vm.steps <= interp.max_steps) interp.max_steps - vm.steps else 0,
    };
    return switch (native.run(&native_frame)) {
        .complete => Value.fromRawBits(native_frame.result_bits),
        .throw => error.Throw,
        .stop => error.OutOfMemory,
        .side_exit => null,
    };
}

/// Run `chunk` to completion, returning the program's accumulator (for a
/// top-level chunk, `frame == null`) or the function's return value. `frame`
/// is the current activation for `load_local`/`load_upval`.
pub fn run(vm: *Interpreter, chunk: *Chunk, frame: ?*Frame) EvalError!Value {
    var exec = Exec{};
    return execLoop(vm, &exec, chunk, frame, null);
}

fn tryRunNative(vm: *Interpreter, exec: *Exec, chunk: *Chunk, frame: ?*Frame, gen: ?*Generator) EvalError!?Value {
    if (gen != null or exec.ip != 0 or exec.stack.items.len != 0 or exec.handlers.items.len != 0) return null;
    const owner = vm.jit_owner orelse return null;

    var code = chunk.tier.loadCode();
    // Candidate numeric chunks compile on their first call: a substantial loop
    // repays the baseline compiler cost immediately, and cold contexts have no
    // second call. Object/call-heavy chunks retain the ordinary hot threshold
    // so their first invocation does not pay analysis for a known opcode miss.
    const tier_threshold = if (jit_compiler.isCandidate(chunk))
        eager_native_tier_entry_threshold
    else
        native_tier_entry_threshold;
    if (code == null and chunk.tier.observeEntry(tier_threshold)) {
        var compiled = jit_compiler.compile(chunk) catch {
            chunk.tier.publishRejected();
            return null;
        };
        const owned = owner.adopt(compiled) catch {
            compiled.deinit();
            chunk.tier.publishRejected();
            return null;
        };
        chunk.tier.publishReady(owned);
        code = owned;
    }
    const native = code orelse return null;

    if (native.manages_steps) {
        const current_frame = frame;
        if (native.frame_slots > 0) {
            const cf = current_frame orelse return null;
            if (cf.slots.len < native.frame_slots or cf.escaped.load(.monotonic)) return null;
        }
        return try tryRunManagedNative(vm, native, if (current_frame) |cf| cf.slots else &.{});
    }

    // Preserve runChunk's exact step/checkpoint contract. A native entry may
    // cover an interval only when it neither exceeds the budget nor crosses a
    // 1024-step termination/GIL/GC checkpoint; those rare boundaries stay in
    // bytecode and are retried on the next clean entry.
    const instruction_count: u64 = native.bytecode_steps;
    const end_steps = std.math.add(u64, vm.steps, instruction_count) catch return null;
    if (end_steps > interp.max_steps or (vm.steps >> 10) != (end_steps >> 10)) return null;
    const saved_steps = vm.steps;
    vm.steps = end_steps;

    var native_frame = jit.NativeFrame{};
    return switch (native.run(&native_frame)) {
        .complete => Value.fromRawBits(native_frame.result_bits),
        else => {
            vm.steps = saved_steps;
            return null;
        },
    };
}

/// A ready numeric leaf has no object/upvalue/`this`/eval opcode and its native
/// metadata guards every parameter representation before doing observable
/// work. Run it over bounded stack slots so a hot ordinary call avoids building
/// and recycling a heap activation. Extra arguments stay rooted on the caller's
/// operand stack; only formal parameters are copied, matching buildActivation.
fn tryRunNativeDirectCall(vm: *Interpreter, func: *Function, args: []const Value) EvalError!?Value {
    if (vm.jit_owner == null) return null;
    if (func.is_class_constructor or func.uses_arguments) return null;
    const chunk = func.chunk orelse return null;
    const native = chunk.tier.loadCode() orelse return null;
    if (!native.manages_steps) return null;
    const slot_count: usize = @intCast(native.frame_slots);
    if (slot_count != func.local_count or slot_count > 64 or native.frame_slots != chunk.local_count) return null;

    var slots: [64]Value = @splat(Value.undef());
    const parameter_count = @min(func.params.len, slot_count);
    const copy_count = @min(args.len, parameter_count);
    @memcpy(slots[0..copy_count], args[0..copy_count]);

    try vm.stackGuard();
    vm.depth += 1;
    defer vm.depth -= 1;
    const result = try tryRunManagedNative(vm, native, slots[0..slot_count]);
    if (builtin.is_test and result != null) _ = quick_native_direct_call_hits.fetchAdd(1, .monotonic);
    return result;
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
    if (try tryRunNative(vm, exec, chunk, frame, gen)) |result| return result;
    // Run the instruction stream; if a throw escapes and an active handler can
    // catch it, unwind to that handler's catch block and resume. Otherwise the
    // throw propagates to the caller (uncaught — the generator/function ends).
    while (true) {
        return runChunk(vm, exec, chunk, frame, gen) catch |e| {
            const abrupt = if (exec.handlers.items.len > 0) vm.catchableOutOfMemory(e) else e;
            if (abrupt == error.Throw and exec.handlers.items.len > 0) {
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
            return abrupt;
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
    // is false, so frame slots and monomorphic property IC hits avoid locks and
    // repeated atomic mode loads. Shared/concurrent-GC contexts enable the flag
    // before executing any chunk and retain the synchronized paths below.
    const parallel_sync = bc.ic_seqlock_enabled.load(.monotonic);

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
                if (!parallel_sync) {
                    if (quickGlobalBindingValue(chunk, ip - 1, vm)) |cached| {
                        try stack.append(stack_alloc, cached);
                        if (builtin.is_test) _ = quick_global_binding_hits.fetchAdd(1, .monotonic);
                        continue;
                    }
                }
                const v = (try vm.lookupIdent(name)) orelse (try vm.globalProp(name)) orelse return vm.throwError("ReferenceError", name);
                if (!parallel_sync) recordQuickGlobalBinding(chunk, ip - 1, vm, name);
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
                const start = ip - 1;
                const quick_loop_candidates = if (start < chunk.quick_loop_candidates.len)
                    chunk.quick_loop_candidates[start]
                else
                    0;
                if (stack.items.len == 0 and (quick_loop_candidates & bc.quick_call_loop_candidate) != 0) {
                    if (quickCallLoopPlan(chunk, start, parallel_sync)) |plan| {
                        const steps_until_checkpoint = 1024 - (vm.steps & 1023);
                        const steps_until_budget = interp.max_steps - vm.steps;
                        const max_extra_steps = @min(steps_until_checkpoint - 1, steps_until_budget);
                        if (try tryQuickNumericCallLoop(vm, chunk, plan, cf, start, max_extra_steps, parallel_sync)) |quick| {
                            vm.steps += quick.extra_steps;
                            ip = quick.next_ip;
                            continue;
                        }
                    }
                }
                if (stack.items.len == 0 and (quick_loop_candidates & bc.quick_array_loop_candidate) != 0) {
                    if (quickArrayPlan(chunk, start, parallel_sync)) |plan| {
                        const steps_until_checkpoint = 1024 - (vm.steps & 1023);
                        const steps_until_budget = interp.max_steps - vm.steps;
                        const max_extra_steps = @min(steps_until_checkpoint - 1, steps_until_budget);
                        if (try tryQuickArrayLoop(vm, chunk, plan, cf, start, max_extra_steps, parallel_sync)) |quick| {
                            vm.steps += quick.extra_steps;
                            ip = quick.next_ip;
                            if (builtin.is_test) switch (plan.*) {
                                .packed_sum => _ = quick_packed_array_sum_loop_hits.fetchAdd(1, .monotonic),
                                .packed_push => |push| {
                                    _ = quick_packed_array_push_loop_hits.fetchAdd(1, .monotonic);
                                    switch (push.specialization) {
                                        .add3_bit_and => _ = quick_packed_array_specialized_expression_hits.fetchAdd(1, .monotonic),
                                        .generic => {},
                                    }
                                },
                                .polymorphic_property => _ = quick_polymorphic_property_loop_hits.fetchAdd(1, .monotonic),
                                .object_allocation => {},
                                .unsupported => {},
                            };
                            continue;
                        }
                    }
                }
                // A quick property assignment must start with an object-valued
                // base and then a numeric RHS load. Keep the recognizer call off
                // ordinary numeric locals (including the arithmetic JIT side
                // exits), and off the inner `load_local; get_prop` read pair.
                const may_start_quick_property = ip < code.len and quickPropertySiteMayApply(chunk, start, parallel_sync) and
                    switch (code[ip].op) {
                        .load_const, .load_local => true,
                        else => false,
                    };
                if (may_start_quick_property) property: {
                    const held = cf.lockSlots(parallel_sync);
                    const quick_property_base = cf.slots[inst.a].isObject();
                    cf.unlockSlots(held);
                    if (!quick_property_base) break :property;
                    const steps_until_checkpoint = 1024 - (vm.steps & 1023);
                    const steps_until_budget = interp.max_steps - vm.steps;
                    const max_extra_steps = @min(steps_until_checkpoint - 1, steps_until_budget);
                    if (tryQuickPropertyKernel(chunk, cf, start, max_extra_steps, parallel_sync)) |quick| {
                        vm.steps += quick.extra_steps;
                        ip = quick.next_ip;
                        continue;
                    }
                    if (!parallel_sync) {
                        if (tryNumericPropertyUpdate(chunk, cf, start, max_extra_steps)) |quick| {
                            vm.steps += quick.extra_steps;
                            ip = quick.next_ip;
                            continue;
                        }
                    }
                }
                const held = cf.lockSlots(parallel_sync);
                const v = cf.slots[inst.a];
                cf.unlockSlots(held);
                try stack.append(stack_alloc, v);
            },
            .store_local => {
                const cf = frame.?;
                const v = stack.items[stack.items.len - 1]; // leaves value on the stack
                const held = cf.lockSlots(parallel_sync);
                cf.slots[inst.a] = v;
                cf.unlockSlots(held);
            },
            .load_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                const held = f.lockSlots(parallel_sync);
                const v = f.slots[inst.b];
                f.unlockSlots(held);
                try stack.append(stack_alloc, v);
            },
            .store_upval => {
                var f = frame.?;
                var d = inst.a;
                while (d > 0) : (d -= 1) f = f.parent.?;
                const v = stack.items[stack.items.len - 1]; // leaves value on the stack
                const held = f.lockSlots(parallel_sync);
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
                try stack.append(stack_alloc, try Value.strAlloc(vm.arena, try propKey(vm, stack.pop().?)));
            },
            .name_anon => {
                // NamedEvaluation: name the bare anonymous function/class value on
                // top of the stack (the compiler emits this only for such a value).
                try vm.nameAnonValue(stack.items[stack.items.len - 1], chunk.names.items[inst.a]);
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
                try stack.append(stack_alloc, try Value.strAlloc(vm.arena, v.typeOf()));
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
                try stack.append(stack_alloc, try Value.strAlloc(vm.arena, try vm.toStringV(v)));
            },

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict, .in_op, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => {
                const r = stack.pop().?;
                const l = stack.pop().?;
                // Number-number fast path: when both operands are numbers the
                // result is computed inline, bit-for-bit identical to
                // Interpreter.applyBinary, skipping its ToPrimitive / BigInt /
                // string-concat dispatch. Bitwise and shift operators still run
                // the exact ToInt32/ToUint32 conversions below; only `in` needs
                // the general object path.
                const result: Value = fast: {
                    if (l.isNumber() and r.isNumber()) {
                        const a = l.asNum();
                        const b = r.asNum();
                        if (builtin.is_test) switch (inst.op) {
                            .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => _ = fast_number_bitwise_hits.fetchAdd(1, .monotonic),
                            else => {},
                        };
                        break :fast switch (inst.op) {
                            .add => Value.num(a + b),
                            .sub => Value.num(a - b),
                            .mul => Value.num(a * b),
                            .div => Value.num(a / b),
                            .mod => Value.num(numberRemainder(a, b)),
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
                            .bit_and => Value.num(@floatFromInt(l.toInt32() & r.toInt32())),
                            .bit_or => Value.num(@floatFromInt(l.toInt32() | r.toInt32())),
                            .bit_xor => Value.num(@floatFromInt(l.toInt32() ^ r.toInt32())),
                            .shl => shift: {
                                const amount: u5 = @intCast(r.toUint32() & 31);
                                break :shift Value.num(@floatFromInt(@as(i32, @bitCast(l.toUint32() << amount))));
                            },
                            .shr => shift: {
                                const amount: u5 = @intCast(r.toUint32() & 31);
                                break :shift Value.num(@floatFromInt(l.toInt32() >> amount));
                            },
                            .ushr => shift: {
                                const amount: u5 = @intCast(r.toUint32() & 31);
                                break :shift Value.num(@floatFromInt(l.toUint32() >> amount));
                            },
                            // `in` requires an object RHS even for numeric inputs.
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
                const object = obj.asObj();
                const key = chunk.names.items[inst.a];
                const base_shape = object.shape orelse vm.root_shape;
                const cache = &chunk.ics[ip - 1];
                if (cache.lookupLiteralTransitionMode(base_shape, parallel_sync)) |transition| {
                    if (try object.applyLiteralTransition(vm.arena, vm.root_shape, transition.shape, transition.slot, v, parallel_sync)) {
                        if (builtin.is_test) _ = quick_literal_transition_hits.fetchAdd(1, .monotonic);
                        continue;
                    }
                }
                try vm.defineLiteralDataProp(object, key, v);
                if (object.shape) |child| {
                    if (child.parent == base_shape and child.name != null and std.mem.eql(u8, child.name.?, key))
                        cache.recordMode(child, child.slot, parallel_sync);
                }
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
                try arr.asObj().appendElement(vm.arena, v);
            },
            .array_append_hole => {
                // An array-literal elision: a slot that reads as absent (skipped by
                // iteration, `in`, etc.) but counts toward length.
                const arr = stack.items[stack.items.len - 1].asObj();
                try arr.appendArrayHole(vm.arena);
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
                        if (o.is_array and !o.is_arguments and o.proxy_handler == null and !o.proxy_revoked and
                            std.mem.eql(u8, name, "length"))
                        {
                            const length = if (parallel_sync) o.arrayLength() else @max(o.elements.items.len, o.array_len);
                            result = Value.num(@floatFromInt(length));
                            if (builtin.is_test) _ = quick_array_length_hits.fetchAdd(1, .monotonic);
                            break :fast;
                        }
                        // Ordinary arrays normally have no named own properties;
                        // their methods are direct data properties on
                        // Array.prototype. Cache that prototype shape/slot while
                        // retaining the observable own-property and accessor
                        // checks. A replaced method value is read from the live
                        // slot, and any shape transition invalidates the cache.
                        if (o.is_array and !o.is_arguments and o.proxy_handler == null and !o.proxy_revoked) {
                            if (quickArrayPrototypeData(chunk, ip - 1, o, name, parallel_sync)) |data| {
                                result = data;
                                if (builtin.is_test) _ = quick_array_prototype_data_hits.fetchAdd(1, .monotonic);
                                break :fast;
                            }
                        }
                        if (parallel_sync) o.lockProperties();
                        defer if (parallel_sync) o.unlockProperties();
                        if (!o.is_array and o.accessors.load(.monotonic) == null and o.attrsMap() == null) {
                            const ic = &chunk.ics[ip - 1];
                            if (ic.lookupSlotMode(o.shape, parallel_sync)) |sl| {
                                result = o.slots.items[sl];
                                break :fast;
                            }
                            if (o.shape) |sh| {
                                if (sh.lookup(name)) |slot| {
                                    ic.recordMode(sh, slot, parallel_sync);
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
                fast: {
                    // A present dense element has no observable coercion,
                    // accessor, hole, or prototype work. Shared arrays take a
                    // short element-lock snapshot; isolated arrays read their
                    // stable allocation directly.
                    if (obj.isObject()) {
                        const o = obj.asObj();
                        if (o.is_array and !o.is_arguments and o.proxy_handler == null and !o.proxy_revoked) {
                            if (quickArrayIndex(key)) |index| {
                                const element = if (parallel_sync)
                                    o.denseElement(index)
                                else if (o.accessors.load(.monotonic) == null and o.holes == null and index < o.elements.items.len)
                                    o.elements.items[index]
                                else
                                    null;
                                if (element) |present| {
                                    try stack.append(stack_alloc, present);
                                    if (builtin.is_test) _ = quick_dense_array_index_hits.fetchAdd(1, .monotonic);
                                    break :fast;
                                }
                            }
                        }
                    }
                    try stack.append(stack_alloc, try vm.getProperty(obj, try propKey(vm, key)));
                }
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
                        if (parallel_sync) o.lockProperties();
                        defer if (parallel_sync) o.unlockProperties();
                        if (!o.is_array and o.accessors.load(.monotonic) == null and o.attrsMap() == null) {
                            const ic = &chunk.ics[ip - 1];
                            if (ic.lookupSlotMode(o.shape, parallel_sync)) |sl| {
                                gc_mod.barrierValueFrom(o, v); // IC fast-path slot store
                                o.slots.items[sl] = v;
                                break :fast;
                            }
                            if (o.shape) |sh| {
                                if (sh.lookup(name)) |slot| {
                                    ic.recordMode(sh, slot, parallel_sync);
                                    gc_mod.barrierValueFrom(o, v); // IC fast-path slot store
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
                if (try quickDenseArrayStore(vm, obj, key, v)) {
                    if (builtin.is_test) _ = quick_dense_array_store_hits.fetchAdd(1, .monotonic);
                    try stack.append(stack_alloc, v);
                    continue;
                }
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

            .make_closure => {
                const closure = if (frame) |cf|
                    quickReusableImmediateClosure(chunk, ip - 1, cf, parallel_sync) orelse
                        try makeClosure(vm, chunk.fns.items[inst.a], frame)
                else
                    try makeClosure(vm, chunk.fns.items[inst.a], frame);
                try stack.append(stack_alloc, closure);
            },
            .call => {
                const argc = inst.a;
                const base = stack.items.len - argc;
                const callee = stack.items[base - 1];
                if (jsPlainFunction(callee)) |function| {
                    if (try tryQuickArgumentsCall(vm, function, stack.items[base..])) |result| {
                        stack.shrinkRetainingCapacity(base - 1);
                        try stack.append(stack_alloc, result);
                        continue;
                    }
                }
                if (jsChunkFn(callee)) |func| {
                    if (try tryQuickNumericRecurrence(vm, func, stack.items[base..], parallel_sync)) |result| {
                        stack.shrinkRetainingCapacity(base - 1);
                        try stack.append(stack_alloc, result);
                        continue;
                    }
                    if (try tryRunNativeDirectCall(vm, func, stack.items[base..])) |result| {
                        stack.shrinkRetainingCapacity(base - 1);
                        try stack.append(stack_alloc, result);
                        continue;
                    }
                    if (!parallel_sync and func.vm_inline_calls_safe and !vm.vm_inline_calls_disabled) {
                        const result = if (vm.vm_inline_call_depth < inline_call_depth_limit)
                            try runInlineFunction(vm, func, func.chunk.?, stack.items[base..], Value.undef(), Value.undef())
                        else
                            try callValueWithInlineCallsDisabled(vm, callee, stack.items[base..], Value.undef());
                        stack.shrinkRetainingCapacity(base - 1);
                        try stack.append(stack_alloc, result);
                        continue;
                    }
                }
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
                const args = try args_arr.asObj().internalElementsSnapshot(vm.arena);
                try stack.append(stack_alloc, try callValue(vm, callee, args, Value.undef()));
            },
            .call_method_spread => {
                const args_arr = stack.pop().?;
                const recv = stack.pop().?;
                const name = chunk.names.items[inst.a];
                const args = try args_arr.asObj().internalElementsSnapshot(vm.arena);
                const result = try invokeMethod(vm, recv, name, args);
                try stack.append(stack_alloc, result);
            },
            .new_spread => {
                const args_arr = stack.pop().?;
                const callee = stack.pop().?;
                const args = try args_arr.asObj().internalElementsSnapshot(vm.arena);
                try stack.append(stack_alloc, try construct(vm, callee, args));
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
                const fast_array_push = try vm.tryFastArrayPush(callee, this_val, args);
                const res = fast_array_push orelse blk: {
                    break :blk try callValue(vm, callee, args, this_val);
                };
                if (builtin.is_test and fast_array_push != null)
                    _ = quick_array_push_hits.fetchAdd(1, .monotonic);
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
            .template_object => {
                const node = chunk.templates.items[inst.a];
                try stack.append(stack_alloc, Value.obj(try vm.getTemplateObject(node)));
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
    if (g.running.load(.monotonic)) return vm.throwError("TypeError", "generator is already running");

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

    g.running.store(true, .monotonic);
    defer g.running.store(false, .monotonic);
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
    // Consecutive awaits may be drained by different shared-realm threads. An
    // already-settled next await can run while the prior drive is in its return
    // tail, so claim the activation with an acquire CAS and publish all state
    // with a release store. The wait is only for that tail handoff: promise
    // reactions are jobs, never inline callbacks into a still-executing await.
    g.claimAsyncResume();
    defer g.releaseAsyncResume();
    if (g.done) return;
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
    gc_mod.barrierValueFrom(g, val);
    gc_mod.barrierCellFrom(g, @ptrCast(rp));
    var start_req: ?AsyncGenRequest = null;
    var start_done = false;
    g.lockRequests();
    {
        errdefer g.unlockRequests();
        try g.appendRequest(vm.arena, .{ .kind = kind, .value = val, .result = rp });
        if (!g.pumping) {
            g.pumping = true;
            if (g.done)
                start_done = true
            else
                start_req = g.frontRequest();
        }
    }
    g.unlockRequests();
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
    g.lockRequests();
    defer g.unlockRequests();
    if (!g.hasPendingRequest()) {
        g.pumping = false;
        return null;
    }
    return g.frontRequest();
}

fn agRemoveFrontAndContinue(vm: *Interpreter, g: *Generator) EvalError!void {
    var next_req: ?AsyncGenRequest = null;
    var drain_done = false;
    g.lockRequests();
    _ = g.popRequest();
    if (g.done)
        drain_done = true
    else if (g.frontRequest()) |front|
        next_req = front
    else
        g.pumping = false;
    g.unlockRequests();
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
    g.lockRequests();
    if (g.pumping) {
        g.unlockRequests();
        return;
    }
    if (!g.hasPendingRequest()) {
        g.unlockRequests();
        return;
    }
    g.pumping = true;
    if (g.done)
        drain_done = true
    else
        req = g.frontRequest();
    g.unlockRequests();
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
        g.lockRequests();
        const req = g.popRequest() orelse {
            g.pumping = false;
            g.unlockRequests();
            break;
        };
        g.unlockRequests();
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
    g.lockRequests();
    _ = g.popRequest();
    g.unlockRequests();
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
    g.lockRequests();
    _ = g.popRequest();
    g.unlockRequests();
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
        .realm_global = interp.functionRealmGlobal(closure_env, vm.global_object),
        .name = tmpl.name,
        .source = tmpl.source,
        .uses_arguments = tmpl.uses_arguments,
        .is_generator = tmpl.is_generator,
        .is_async = tmpl.is_async,
        .is_strict = tmpl.is_strict,
        .import_meta_slot = vm.import_meta_slot,
        .module_referrer = vm.cur_module,
        .chunk = if (tmpl.is_generator or tmpl.is_async) null else tmpl.chunk,
        .vm_inline_calls_safe = if (tmpl.chunk) |compiled| interp.vmChunkAllowsInlineCalls(compiled) else false,
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
    /// Full backing store retained when `frame.slots` is narrowed for a call.
    /// Keeping capacity here lets a later activation with no more locals reuse
    /// the same allocation.
    slot_storage: []Value,
    next_free: ?*Activation = null,
    // The operand-stack index in the *caller* where this call's result lands
    // (callee + args were popped off before the call ran). Unused for the
    // driver's initial activation.
    result_base: usize = 0,
    // Caller VM state, restored by `popActivation`.
    saved_this: Value,
    saved_strict: bool,
    saved_env: *Environment,
    saved_global: ?*value.Object,
    saved_nt: Value,
    saved_ims: ?*interp.ImportMetaSlot,
    saved_imo: ?*value.Object,
    saved_cur_module: []const u8,
    saved_eval_nt: bool,
    saved_pm: ?*const std.StringHashMapUnmanaged([]const u8),
};

/// Return an inactive activation whose frame was never captured. The pool is
/// interpreter-local, so independent contexts and shared-realm threads never
/// contend on it. Arena allocations cannot be individually freed; recycling
/// here avoids retaining one frame/slot/Exec allocation for every completed JS
/// call until Context teardown.
fn releaseActivation(vm: *Interpreter, act: *Activation) void {
    if (act.frame.escaped.load(.monotonic)) return;
    act.exec.stack.clearRetainingCapacity();
    act.exec.handlers.clearRetainingCapacity();
    act.exec.acc = Value.undef();
    act.exec.ip = 0;
    act.exec.frame = null;
    act.next_free = if (vm.vm_activation_free) |raw| @ptrCast(@alignCast(raw)) else null;
    vm.vm_activation_free = act;
}

fn acquireActivation(vm: *Interpreter, local_count: usize) EvalError!*Activation {
    if (vm.vm_activation_free) |raw| {
        const act: *Activation = @ptrCast(@alignCast(raw));
        if (act.slot_storage.len >= local_count) {
            vm.vm_activation_free = act.next_free;
            act.next_free = null;
            act.frame.slots = act.slot_storage[0..local_count];
            act.frame.parent = null;
            act.frame.escaped.store(false, .monotonic);
            @memset(act.frame.slots, Value.undef());
            return act;
        }
    }

    const slots = try vm.arena.alloc(Value, local_count);
    @memset(slots, Value.undef());
    const frame = try vm.arena.create(Frame);
    frame.* = .{ .slots = slots, .parent = null };
    const act = try vm.arena.create(Activation);
    act.* = .{
        .chunk = undefined,
        .frame = frame,
        .slot_storage = slots,
        .saved_this = undefined,
        .saved_strict = undefined,
        .saved_env = undefined,
        .saved_global = undefined,
        .saved_nt = undefined,
        .saved_ims = undefined,
        .saved_imo = undefined,
        .saved_cur_module = undefined,
        .saved_eval_nt = undefined,
        .saved_pm = undefined,
    };
    vm.vm_activation_allocations += 1;
    return act;
}

/// Allocate a callee activation (frame + slots from `args`), capture the caller
/// VM state into it, and install the callee's VM state. Does not run anything.
/// On a throw from `bindThisForCall` the caller state is restored before
/// propagating, so the caller is never left with the callee's state.
fn buildActivation(vm: *Interpreter, func: *Function, fchunk: *Chunk, args: []const Value, this_val: Value, new_target: Value) EvalError!*Activation {
    const act = try acquireActivation(vm, func.local_count);
    const exec = act.exec;
    const frame = act.frame;
    const slot_storage = act.slot_storage;
    const slots = frame.slots;
    for (func.params, 0..) |_, i| {
        if (i < args.len) slots[i] = args[i];
    }
    act.* = .{
        .exec = exec,
        .chunk = fchunk,
        .frame = frame,
        .slot_storage = slot_storage,
        .next_free = null,
        .saved_this = vm.this_value,
        .saved_strict = vm.strict,
        .saved_env = vm.env,
        .saved_global = vm.global_object,
        .saved_nt = vm.new_target,
        .saved_ims = vm.import_meta_slot,
        .saved_imo = vm.import_meta_obj,
        .saved_cur_module = vm.cur_module,
        .saved_eval_nt = vm.direct_eval_new_target_allowed,
        .saved_pm = vm.current_private_map,
    };
    frame.* = .{
        .slots = slots,
        .parent = if (func.frame) |fp| @ptrCast(@alignCast(fp)) else null,
    };
    if (!func.is_arrow) vm.current_private_map = func.private_map; // a direct eval here resolves the class's private names
    vm.strict = func.is_strict;
    // Free variables (globals, and a named function expression's self name)
    // resolve through `vm.env`; install the closure's defining environment.
    vm.env = func.closure;
    if (func.realm_global) |global| vm.global_object = global;
    vm.new_target = if (func.is_arrow) func.arrow_new_target else new_target;
    vm.direct_eval_new_target_allowed = if (func.is_arrow) func.arrow_direct_eval_new_target_allowed else true;
    vm.import_meta_slot = func.import_meta_slot;
    vm.import_meta_obj = if (func.import_meta_slot) |slot| slot.obj else null;
    vm.cur_module = func.module_referrer;
    vm.this_value = bindThisForCall(vm, func, this_val) catch |e| {
        popActivation(vm, act);
        releaseActivation(vm, act);
        return e;
    };
    return act;
}

/// Restore the caller VM state captured by `buildActivation`.
fn popActivation(vm: *Interpreter, act: *Activation) void {
    vm.this_value = act.saved_this;
    vm.strict = act.saved_strict;
    vm.env = act.saved_env;
    vm.global_object = act.saved_global;
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
    dst.saved_global = src.saved_global;
    dst.saved_nt = src.saved_nt;
    dst.saved_ims = src.saved_ims;
    dst.saved_imo = src.saved_imo;
    dst.saved_cur_module = src.saved_cur_module;
    dst.saved_eval_nt = src.saved_eval_nt;
    dst.saved_pm = src.saved_pm;
}

/// Execute a shallow ordinary VM call directly, retaining the same activation,
/// root registration, handler unwinding, step accounting, and state restoration
/// as a driver-owned activation. The depth bound keeps native stack use fixed;
/// the boundary call disables this path while a nested heap driver handles the
/// remainder of a deep chain.
fn runInlineFunction(vm: *Interpreter, func: *Function, fchunk: *Chunk, args: []const Value, this_val: Value, new_target: Value) EvalError!Value {
    try vm.stackGuard();
    vm.depth += 1;
    defer vm.depth -= 1;
    const act = try buildActivation(vm, func, fchunk, args, this_val, new_target);
    defer {
        popActivation(vm, act);
        releaseActivation(vm, act);
    }
    vm.vm_inline_call_depth += 1;
    defer vm.vm_inline_call_depth -= 1;
    return execLoop(vm, &act.exec, fchunk, act.frame, null);
}

fn callValueWithInlineCallsDisabled(vm: *Interpreter, callee: Value, args: []const Value, this_val: Value) EvalError!Value {
    const saved = vm.vm_inline_calls_disabled;
    vm.vm_inline_calls_disabled = true;
    defer vm.vm_inline_calls_disabled = saved;
    return callValue(vm, callee, args, this_val);
}

/// If `callee` is a plain JS-chunk function (not generator/async/native/bound/
/// proxy), return it — those are the calls the trampoline pushes onto its
/// activation stack. Everything else takes the native call path.
inline fn jsPlainFunction(callee: Value) ?*Function {
    if (!callee.isObject()) return null;
    const erased = callee.asObj().js_func orelse return null;
    const func: *Function = @ptrCast(@alignCast(erased));
    if (func.is_generator or func.is_async) return null;
    return func;
}

inline fn jsChunkFn(callee: Value) ?*Function {
    const func = jsPlainFunction(callee) orelse return null;
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
        releaseActivation(vm, cur);
        if (acts.items.len == 0) return false; // uncaught; initial depth owned by runFunction
        vm.depth -= 1; // a nested activation was discarded
    }
    return false;
}

fn activationStackHasHandler(acts: *const std.ArrayListUnmanaged(*Activation)) bool {
    for (acts.items) |act| {
        if (act.exec.handlers.items.len > 0) return true;
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
        const outcome: EvalError!Value = if (try tryRunNative(vm, &cur.exec, cur.chunk, cur.frame, null)) |native_result|
            native_result
        else
            runChunk(vm, &cur.exec, cur.chunk, cur.frame, null);
        const rv = outcome catch |e| {
            const abrupt = if (activationStackHasHandler(&acts)) vm.catchableOutOfMemory(e) else e;
            if (abrupt != error.Throw) {
                // OOM / OptShortCircuit: tear down all activations and propagate.
                while (acts.items.len > 0) {
                    const a = acts.items[acts.items.len - 1];
                    vm.popExecRoot(&a.exec);
                    popActivation(vm, a);
                    _ = acts.pop();
                    releaseActivation(vm, a);
                    if (acts.items.len > 0) vm.depth -= 1;
                }
                return abrupt;
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
                releaseActivation(vm, current);
            } else {
                if (vm.depth >= interp.max_call_depth) {
                    releaseActivation(vm, callee);
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
        releaseActivation(vm, cur);
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
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(a, "4294967295 % 2")).asNum());
    try std.testing.expectEqual(@as(f64, 1.5), (try vmRun(a, "5.5 % 2")).asNum());
    try std.testing.expectEqual(@as(f64, -1), (try vmRun(a, "-5 % 2")).asNum());
    const negative_zero = (try vmRun(a, "-0 % 3")).asNum();
    try std.testing.expect(negative_zero == 0 and std.math.signbit(negative_zero));
    try std.testing.expect((try vmRun(a, "3 > 2 && 2 >= 2")).asBool());
    try std.testing.expect((try vmRun(a, "false || 1 === 1")).asBool());
    try std.testing.expectEqualStrings("ab1", (try vmRun(a, "'a' + 'b' + 1")).asStr());
}

test "vm: number bitwise dispatch preserves conversions and coercion fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hits_before = fast_number_bitwise_hits.load(.monotonic);
    try std.testing.expectEqual(@as(f64, 255), (try vmRun(a, "4294967295 & 255")).asNum());
    try std.testing.expectEqual(@as(f64, 2147483647), (try vmRun(a, "-1 >>> 1")).asNum());
    try std.testing.expectEqual(@as(f64, -1), (try vmRun(a, "2147483648 >> 31")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try vmRun(a, "1 << 33")).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try vmRun(a, "NaN | 5")).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try vmRun(a, "Infinity ^ 3")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try vmRun(a, "-0 | 0")).asNum());
    try std.testing.expect(fast_number_bitwise_hits.load(.monotonic) >= hits_before + 7);

    const fast_hits = fast_number_bitwise_hits.load(.monotonic);
    try std.testing.expectEqual(@as(f64, 21), (try vmRun(a,
        \\let log = '';
        \\let lhs = { valueOf: function () { log = log + 'l'; return 6; } };
        \\let rhs = { valueOf: function () { log = log + 'r'; return 3; } };
        \\let result = lhs & rhs;
        \\result * 10 + (log === 'lr' ? 1 : 0)
    )).asNum());
    try std.testing.expect((try vmRun(a, "(6n & 3n) === 2n")).asBool());
    try std.testing.expect((try vmRun(a, "let threw = false; try { 1n & 1; } catch (e) { threw = true; } threw")).asBool());
    try std.testing.expect((try vmRun(a, "let threw = false; try { Symbol() & 1; } catch (e) { threw = true; } threw")).asBool());
    try std.testing.expectEqual(fast_hits, fast_number_bitwise_hits.load(.monotonic));
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

test "vm: hot primitive constant function tiers through native entry" {
    if (!jit.supported or @import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "function answer() { return 42; } answer()");
    const program = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(allocator, program);

    var owner = jit.Owner.init(std.testing.allocator);
    defer owner.deinit();
    var env = Environment{ .arena = allocator, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&env, root_shape);
    var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape, .jit_owner = &owner };

    var previous_steps: u64 = 0;
    var expected_delta: u64 = 0;
    for (0..3) |iteration| {
        try std.testing.expectEqual(@as(f64, 42), (try run(&machine, chunk, null)).asNum());
        const delta = machine.steps - previous_steps;
        if (iteration == 0) expected_delta = delta else try std.testing.expectEqual(expected_delta, delta);
        previous_steps = machine.steps;
    }

    const function_chunk = chunk.fns.items[0].chunk.?;
    try std.testing.expectEqual(@as(u32, 0), function_chunk.param_count);
    try std.testing.expectEqual(@as(u32, 0), function_chunk.local_count);
    try std.testing.expectEqual(jit.TierState.ready, function_chunk.tier.loadState());
    try std.testing.expectEqual(@as(u32, 2), function_chunk.tier.loadCode().?.bytecode_steps);
    try std.testing.expectEqual(jit.TierState.rejected, chunk.tier.loadState());

    // Crossing an interpreter checkpoint stays in bytecode even after native
    // publication, preserving the exact step at which termination/GIL/GC work
    // would be observed.
    machine.steps = 1022;
    try std.testing.expectEqual(@as(f64, 42), (try run(&machine, function_chunk, null)).asNum());
    try std.testing.expectEqual(@as(u64, 1024), machine.steps);
}

test "vm: speculative unsigned parameter guards are exact" {
    var slots = [_]Value{
        Value.num(0),
        Value.num(42),
        Value.num(@floatFromInt(std.math.maxInt(u32))),
    };
    try std.testing.expect(unsigned32GuardsPass(&slots, 0b111));
    try std.testing.expect(unsigned32GuardsPass(&slots, 0));

    const rejected = [_]f64{
        -0.0,
        -1,
        1.5,
        std.math.nan(f64),
        std.math.inf(f64),
        @as(f64, @floatFromInt(@as(u64, std.math.maxInt(u32)) + 1)),
    };
    for (rejected) |number| {
        slots[1] = Value.num(number);
        try std.testing.expect(!unsigned32GuardsPass(&slots, 0b010));
    }
    slots[1] = Value.str("not a number");
    try std.testing.expect(!unsigned32GuardsPass(&slots, 0b010));
    try std.testing.expect(!unsigned32GuardsPass(&slots, @as(u64, 1) << 7));
}

test "vm: numeric baseline tier preserves steps and non-number fallback" {
    if (!jit.supported or @import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\function sum(n) {
        \\  var total = 0;
        \\  for (var i = 0; i < n; i = i + 1) total = total + i;
        \\  return total;
        \\}
        \\function addOne(x) { return x + 1; }
        \\function remainder(a, b) { return a % b; }
        \\function below(a, b) { if (a < b) return 1; return 0; }
    );
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);

    var owner = jit.Owner.init(std.testing.allocator);
    defer owner.deinit();
    var env = Environment{ .arena = allocator, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&env, root_shape);
    var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape, .jit_owner = &owner };

    const sum_chunk = root.fns.items[0].chunk.?;
    var sum_slots = [_]Value{ Value.num(10), Value.undef(), Value.undef() };
    var sum_frame = Frame{ .slots = &sum_slots, .parent = null };
    var expected_steps: u64 = 0;
    for (0..3) |iteration| {
        sum_slots = .{ Value.num(10), Value.undef(), Value.undef() };
        if (iteration == 2) machine.steps = 1023; // native entry must service the first-op checkpoint
        const start_steps = machine.steps;
        try std.testing.expectEqual(@as(f64, 45), (try run(&machine, sum_chunk, &sum_frame)).asNum());
        const delta = machine.steps - start_steps;
        if (iteration == 0) expected_steps = delta else try std.testing.expectEqual(expected_steps, delta);
    }
    try std.testing.expectEqual(jit.TierState.ready, sum_chunk.tier.loadState());
    try std.testing.expect(sum_chunk.tier.loadCode().?.manages_steps);

    const add_chunk = root.fns.items[1].chunk.?;
    var add_slots = [_]Value{Value.num(0)};
    var add_frame = Frame{ .slots = &add_slots, .parent = null };
    for (1..4) |n| {
        add_slots[0] = Value.num(@floatFromInt(n));
        try std.testing.expectEqual(@as(f64, @floatFromInt(n + 1)), (try run(&machine, add_chunk, &add_frame)).asNum());
    }
    try std.testing.expectEqual(jit.TierState.ready, add_chunk.tier.loadState());
    add_slots[0] = Value.str("x");
    const fallback = try run(&machine, add_chunk, &add_frame);
    try std.testing.expect(fallback.isString());
    try std.testing.expectEqualStrings("x1", fallback.asStr());

    const remainder_chunk = root.fns.items[2].chunk.?;
    var remainder_slots = [_]Value{ Value.num(0), Value.num(1) };
    var remainder_frame = Frame{ .slots = &remainder_slots, .parent = null };
    const warmup = [_][3]f64{
        .{ 5, 2, 1 },
        .{ 8, 3, 2 },
        .{ 9, 4, 1 },
    };
    for (warmup) |case| {
        remainder_slots = .{ Value.num(case[0]), Value.num(case[1]) };
        try std.testing.expectEqual(case[2], (try run(&machine, remainder_chunk, &remainder_frame)).asNum());
    }
    try std.testing.expectEqual(jit.TierState.ready, remainder_chunk.tier.loadState());
    remainder_slots = .{ Value.num(-5), Value.num(2) };
    try std.testing.expectEqual(@as(f64, -1), (try run(&machine, remainder_chunk, &remainder_frame)).asNum());
    remainder_slots = .{ Value.num(5.5), Value.num(2) };
    try std.testing.expectEqual(@as(f64, 1.5), (try run(&machine, remainder_chunk, &remainder_frame)).asNum());
    remainder_slots = .{ Value.num(std.math.nan(f64)), Value.num(2) };
    try std.testing.expect(std.math.isNan((try run(&machine, remainder_chunk, &remainder_frame)).asNum()));

    const below_chunk = root.fns.items[3].chunk.?;
    var below_slots = [_]Value{ Value.num(1), Value.num(2) };
    var below_frame = Frame{ .slots = &below_slots, .parent = null };
    try std.testing.expectEqual(@as(f64, 1), (try run(&machine, below_chunk, &below_frame)).asNum());
    below_slots = .{ Value.num(2), Value.num(1) };
    try std.testing.expectEqual(@as(f64, 0), (try run(&machine, below_chunk, &below_frame)).asNum());
    below_slots = .{ Value.num(2), Value.num(2) };
    try std.testing.expectEqual(@as(f64, 0), (try run(&machine, below_chunk, &below_frame)).asNum());
    try std.testing.expectEqual(jit.TierState.ready, below_chunk.tier.loadState());
    below_slots = .{ Value.num(std.math.nan(f64)), Value.num(2) };
    try std.testing.expectEqual(@as(f64, 0), (try run(&machine, below_chunk, &below_frame)).asNum());
    // Force every early instruction distance through the exact replay path;
    // comparison flags must never survive a runtime checkpoint callback.
    for (1..10) |distance| {
        machine.steps = 1024 - distance;
        below_slots = .{ Value.num(1), Value.num(2) };
        try std.testing.expectEqual(@as(f64, 1), (try run(&machine, below_chunk, &below_frame)).asNum());
    }

    // The native budget countdown must throw before the exact first instruction
    // beyond the limit, even when that step is not a 1024-step checkpoint.
    sum_slots = .{ Value.num(10), Value.undef(), Value.undef() };
    machine.steps = interp.max_steps - 1;
    try std.testing.expectError(error.Throw, run(&machine, sum_chunk, &sum_frame));
    try std.testing.expectEqual(interp.max_steps + 1, machine.steps);
}

test "vm: numeric call-loop quickening preserves guards and exact steps" {
    if (!jit.supported or @import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function step(a, b) { return (a + b) % 101; }
        \\function exercise(limit) {
        \\  var local_step = step;
        \\  var value = 7;
        \\  for (var i = 0; i < limit; i = i + 1) value = local_step(value, i);
        \\  return value;
        \\}
        \\var first = exercise(300);
        \\var mutable = function (a, b) { return a + b; };
        \\var before = mutable(5, 2) + mutable(6, 3);
        \\mutable = function (a, b) { return a - b; };
        \\var after = mutable(-5, 2) + mutable(1.5, 2);
        \\function methodStep(a, b) { return (this.bias + a + b) % 101; }
        \\function exerciseMethod(receiver, limit) {
        \\  var value = 11;
        \\  for (var i = 0; i < limit; i = i + 1) value = receiver.step(value, i);
        \\  return value;
        \\}
        \\var receiver = { bias: 3, step: methodStep };
        \\var methodFirst = exerciseMethod(receiver, 300);
        \\receiver.step = function (a, b) { return this.bias + a - b; };
        \\var methodSecond = exerciseMethod(receiver, 10);
        \\function exerciseClosure(limit) {
        \\  var seed = 13;
        \\  for (var i = 0; i < limit; i = i + 1) {
        \\    var closure = function (delta) { return (seed + delta) % 101; };
        \\    seed = closure(i);
        \\  }
        \\  return seed;
        \\}
        \\var closureFirst = exerciseClosure(300);
        \\var closureSecond = exerciseClosure(10);
        \\function argumentsStep(a, b) { return (arguments[0] + arguments[1]) % 101; }
        \\function exerciseArguments(limit) {
        \\  var localStep = argumentsStep;
        \\  var value = 17;
        \\  for (var i = 0; i < limit; i = i + 1) value = localStep(value, i);
        \\  return value;
        \\}
        \\var argumentsFirst = exerciseArguments(300);
        \\var argumentsSecond = exerciseArguments(10);
        \\first + exercise(10) + before * 1000 + after * 10000 + methodFirst * 100000 + methodSecond + closureFirst * 10000000 + closureSecond + argumentsFirst * 1000000000 + argumentsSecond
    ;
    var parser = try Parser.init(allocator, source);
    const program = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(allocator, program);
    var call_loop_supported = false;
    var leaf_supported = false;
    var closure_loop_supported = false;
    var captured_leaf_supported = false;
    var method_loop_supported = false;
    var receiver_leaf_supported = false;
    for (chunk.fns.items) |template| {
        const function_chunk = template.chunk orelse continue;
        switch (compileQuickLeafPlan(function_chunk)) {
            .numeric => |leaf| {
                leaf_supported = true;
                captured_leaf_supported = captured_leaf_supported or leaf.captured_local != null;
                receiver_leaf_supported = receiver_leaf_supported or leaf.receiver_property_instruction != null;
            },
            .unsupported => {},
        }
        for (function_chunk.fns.items) |nested_template| {
            const nested_chunk = nested_template.chunk orelse continue;
            switch (compileQuickLeafPlan(nested_chunk)) {
                .numeric => |leaf| {
                    leaf_supported = true;
                    captured_leaf_supported = captured_leaf_supported or leaf.captured_local != null;
                    receiver_leaf_supported = receiver_leaf_supported or leaf.receiver_property_instruction != null;
                },
                .unsupported => {},
            }
        }
        for (function_chunk.code.items, 0..) |_, instruction| {
            if (instruction >= function_chunk.quick_loop_candidates.len or
                (function_chunk.quick_loop_candidates[instruction] & bc.quick_call_loop_candidate) == 0) continue;
            switch (compileQuickCallLoopPlan(function_chunk, instruction)) {
                .numeric_leaf => |loop| {
                    call_loop_supported = true;
                    switch (loop.callee) {
                        .closure_template => closure_loop_supported = true,
                        .method => method_loop_supported = true,
                        else => {},
                    }
                },
                .unsupported => {},
            }
        }
    }
    try std.testing.expect(call_loop_supported);
    try std.testing.expect(leaf_supported);
    try std.testing.expect(closure_loop_supported);
    try std.testing.expect(captured_leaf_supported);
    try std.testing.expect(method_loop_supported);
    try std.testing.expect(receiver_leaf_supported);

    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    bc.ic_seqlock_enabled.store(true, .monotonic);
    const old_call_loop_enabled = quick_numeric_call_loop_test_enabled.load(.monotonic);
    defer quick_numeric_call_loop_test_enabled.store(old_call_loop_enabled, .monotonic);
    quick_numeric_call_loop_test_enabled.store(true, .monotonic);

    var owner = jit.Owner.init(std.testing.allocator);
    defer owner.deinit();
    var fast_env = Environment{ .arena = allocator, .fn_scope = true };
    const fast_root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&fast_env, fast_root_shape);
    const fast_global = try gc_mod.allocObj(allocator);
    fast_global.* = .{};
    try fast_env.put("globalThis", Value.obj(fast_global));
    try interp.mirrorGlobalsOnto(&fast_env, fast_global, fast_root_shape);
    var fast = Interpreter{
        .arena = allocator,
        .env = &fast_env,
        .root_shape = fast_root_shape,
        .global_object = fast_global,
        .this_value = Value.obj(fast_global),
        .jit_owner = &owner,
    };
    const hits_before = quick_native_direct_call_hits.load(.monotonic);
    const loop_hits_before = quick_numeric_call_loop_hits.load(.monotonic);
    const arguments_loop_hits_before = quick_numeric_arguments_call_loop_hits.load(.monotonic);
    const arguments_direct_hits_before = quick_numeric_arguments_direct_call_hits.load(.monotonic);
    const closure_loop_hits_before = quick_numeric_closure_call_loop_hits.load(.monotonic);
    const reusable_closure_hits_before = quick_reusable_immediate_closure_hits.load(.monotonic);
    const method_loop_hits_before = quick_numeric_method_call_loop_hits.load(.monotonic);
    const fast_result = try run(&fast, chunk, null);
    try std.testing.expect(quick_native_direct_call_hits.load(.monotonic) > hits_before);
    try std.testing.expect(quick_numeric_call_loop_hits.load(.monotonic) > loop_hits_before);
    try std.testing.expect(quick_numeric_arguments_call_loop_hits.load(.monotonic) > arguments_loop_hits_before);
    try std.testing.expect(quick_numeric_arguments_direct_call_hits.load(.monotonic) > arguments_direct_hits_before);
    try std.testing.expect(quick_numeric_closure_call_loop_hits.load(.monotonic) > closure_loop_hits_before);
    try std.testing.expect(quick_reusable_immediate_closure_hits.load(.monotonic) > reusable_closure_hits_before);
    try std.testing.expect(quick_numeric_method_call_loop_hits.load(.monotonic) > method_loop_hits_before);

    // Reuse the exact compiled source with the native tier disabled. The ready
    // code belongs to `owner`, but the VM-level disable switch must still force
    // ordinary activations and produce the same value and logical step count.
    var slow_env = Environment{ .arena = allocator, .fn_scope = true };
    const slow_root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&slow_env, slow_root_shape);
    const slow_global = try gc_mod.allocObj(allocator);
    slow_global.* = .{};
    try slow_env.put("globalThis", Value.obj(slow_global));
    try interp.mirrorGlobalsOnto(&slow_env, slow_global, slow_root_shape);
    var slow = Interpreter{
        .arena = allocator,
        .env = &slow_env,
        .root_shape = slow_root_shape,
        .global_object = slow_global,
        .this_value = Value.obj(slow_global),
    };
    quick_numeric_call_loop_test_enabled.store(false, .monotonic);
    const slow_result = try run(&slow, chunk, null);
    try std.testing.expectEqual(fast_result.rawBits(), slow_result.rawBits());
    try std.testing.expectEqual(fast.steps, slow.steps);
}

test "vm: completed non-escaping recursive activations reuse bounded storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = try Parser.init(a,
        \\function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
        \\var total = 0;
        \\for (var i = 0; i < 50; i = i + 1) total = total + fib(10);
        \\total
    );
    const prog = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(a, prog);
    var env = Environment{ .arena = a, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(a);
    try interp.installGlobals(&env, root_shape);
    var machine = Interpreter{ .arena = a, .env = &env, .root_shape = root_shape };

    try std.testing.expectEqual(@as(f64, 2750), (try run(&machine, chunk, null)).asNum());
    // fib(10) needs only its live recursion depth. Repeating it 50 times must
    // not retain one arena allocation per completed call.
    try std.testing.expect(machine.vm_activation_allocations <= 12);
}

test "vm: recursive calls throw a catchable RangeError before native stack overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = try Parser.init(a,
        \\function recurse(n) { return 1 + recurse(n + 1); }
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

test "vm: fixed-name object literals cache shape transitions across realms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\function build(limit) {
        \\  let total = 0;
        \\  for (let i = 0; i < limit; i = i + 1) {
        \\    let object = { "0": i, a: i + 1, a: i + 2, __proto__: null, ["b"]: i + 3,
        \\      c: i + 4, d: i + 5, e: i + 6, f: i + 7 };
        \\    total = total + object[0] + object.a + object.b + object.c + object.d + object.e + object.f;
        \\    if (object.__proto__ !== undefined) total = total + 1000000;
        \\  }
        \\  return total;
        \\}
        \\function *accessorReplacement() {
        \\  let calls = 0;
        \\  let object = { get x() { calls = calls + 1; return 1; }, x: 7 };
        \\  yield object.x * 10 + calls;
        \\}
        \\build(20) + accessorReplacement().next().value
    );
    const program = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(allocator, program);

    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    var hits = quick_literal_transition_hits.load(.monotonic);
    var steps: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |parallel, run_index| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape };
        try std.testing.expectEqual(@as(f64, 1940), (try run(&machine, chunk, null)).asNum());
        steps[run_index] = machine.steps;
        const next_hits = quick_literal_transition_hits.load(.monotonic);
        try std.testing.expect(next_hits > hits);
        hits = next_hits;
    }
    try std.testing.expectEqual(steps[0], steps[1]);
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

test "vm: sloppy recursive calls retain their function realm global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\var original = globalThis;
        \\function recur(n) { return n > 0 ? recur(n - 1) : this; }
        \\globalThis = { replacement: true };
        \\var retained = recur(3) === original;
        \\globalThis = original;
        \\retained
    );
    const program = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(allocator, program);
    var env = Environment{ .arena = allocator, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&env, root_shape);
    const global = try gc_mod.allocObj(allocator);
    global.* = .{};
    try env.put("globalThis", Value.obj(global));
    var machine = Interpreter{
        .arena = allocator,
        .env = &env,
        .root_shape = root_shape,
        .global_object = global,
        .this_value = Value.obj(global),
    };

    try std.testing.expect((try run(&machine, chunk, null)).asBool());
    try std.testing.expectEqual(global, machine.global_object.?);
}

test "vm: caches live global function bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\var switchAt = 2;
        \\function recur(n) {
        \\  if (n === switchAt) recur = function () { return 10; };
        \\  return n < 1 ? 0 : recur(n - 1) + 1;
        \\}
        \\var original = recur;
        \\original(3)
    ;
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    const hits_before = quick_global_binding_hits.load(.monotonic);
    var isolated_hits: u64 = undefined;
    for ([_]bool{ false, true }) |parallel| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var parser = try Parser.init(allocator, source);
        const program = try parser.parseProgram();
        const chunk = try Compiler.compileProgram(allocator, program);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        const global = try gc_mod.allocObj(allocator);
        global.* = .{};
        try env.put("globalThis", Value.obj(global));
        try interp.mirrorGlobalsOnto(&env, global, root_shape);
        var machine = Interpreter{
            .arena = allocator,
            .env = &env,
            .root_shape = root_shape,
            .global_object = global,
            .this_value = Value.obj(global),
        };
        try std.testing.expectEqual(@as(f64, 12), (try run(&machine, chunk, null)).asNum());
        if (!parallel) {
            try std.testing.expect(quick_global_binding_hits.load(.monotonic) > hits_before);
            isolated_hits = quick_global_binding_hits.load(.monotonic);
        } else {
            try std.testing.expectEqual(isolated_hits, quick_global_binding_hits.load(.monotonic));
        }
    }
}

test "vm: quickens guarded pure numeric recurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
        \\var saved = fib;
        \\var first = fib(8);
        \\fib = function () { return 100; };
        \\first + saved(3)
    ;
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    const hits_before = quick_numeric_recurrence_hits.load(.monotonic);
    var isolated_hits: u64 = undefined;
    var run_steps: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |parallel, run_index| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var parser = try Parser.init(allocator, source);
        const program = try parser.parseProgram();
        const chunk = try Compiler.compileProgram(allocator, program);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        const global = try gc_mod.allocObj(allocator);
        global.* = .{};
        try env.put("globalThis", Value.obj(global));
        try interp.mirrorGlobalsOnto(&env, global, root_shape);
        var machine = Interpreter{
            .arena = allocator,
            .env = &env,
            .root_shape = root_shape,
            .global_object = global,
            .this_value = Value.obj(global),
        };
        try std.testing.expectEqual(@as(f64, 221), (try run(&machine, chunk, null)).asNum());
        run_steps[run_index] = machine.steps;
        if (!parallel) {
            try std.testing.expect(quick_numeric_recurrence_hits.load(.monotonic) > hits_before);
            isolated_hits = quick_numeric_recurrence_hits.load(.monotonic);
        } else {
            try std.testing.expectEqual(isolated_hits, quick_numeric_recurrence_hits.load(.monotonic));
        }
    }
    try std.testing.expectEqual(run_steps[1], run_steps[0]);
}

test "vm: compiles observable numeric recurrence without eliding calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function recur(n, state) {
        \\  state.calls = state.calls + 1;
        \\  return n < 2 ? n : recur(n - 1, state) + recur(n - 2, state);
        \\}
        \\var state = { calls: 0 };
        \\var saved = recur;
        \\var first = recur(8, state);
        \\var accessorState = { raw: 0 };
        \\Object.defineProperty(accessorState, "calls", {
        \\  get: function () { return this.raw; },
        \\  set: function (value) { this.raw = value; }
        \\});
        \\var accessorResult = recur(3, accessorState);
        \\recur = function (n, state) { state.calls = state.calls + 1000; return 100; };
        \\var second = saved(3, state);
        \\first + accessorResult + accessorState.raw + second + state.calls
    ;
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    const hits_before = quick_observable_recurrence_hits.load(.monotonic);
    var isolated_hits: u64 = undefined;
    var run_steps: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |parallel, run_index| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var parser = try Parser.init(allocator, source);
        const program = try parser.parseProgram();
        const chunk = try Compiler.compileProgram(allocator, program);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        const global = try gc_mod.allocObj(allocator);
        global.* = .{};
        try env.put("globalThis", Value.obj(global));
        try interp.mirrorGlobalsOnto(&env, global, root_shape);
        var machine = Interpreter{
            .arena = allocator,
            .env = &env,
            .root_shape = root_shape,
            .global_object = global,
            .this_value = Value.obj(global),
        };
        // fib(8) performs all 67 observable calls. The accessor-backed state
        // takes the generic path and observes all five fib(3) mutations. After
        // replacement, saved(3) executes once and its two live calls add 1000.
        try std.testing.expectEqual(@as(f64, 2296), (try run(&machine, chunk, null)).asNum());
        run_steps[run_index] = machine.steps;
        if (!parallel) {
            try std.testing.expect(quick_observable_recurrence_hits.load(.monotonic) > hits_before);
            isolated_hits = quick_observable_recurrence_hits.load(.monotonic);
        } else {
            try std.testing.expectEqual(isolated_hits, quick_observable_recurrence_hits.load(.monotonic));
        }
    }
    try std.testing.expectEqual(run_steps[1], run_steps[0]);

    // An immutable named-function-expression self binding is safe to compile
    // in shared mode: no worker can replace the recursive callee out from under
    // another. The counter path still performs every synchronized property
    // read and write.
    const named_source =
        \\var recur = function recur(n, state) {
        \\  state.calls = state.calls + 1;
        \\  return n < 2 ? n : recur(n - 1, state) + recur(n - 2, state);
        \\};
        \\var state = { calls: 0 };
        \\recur(8, state) + state.calls
    ;
    const shared_hits_before = quick_observable_recurrence_hits.load(.monotonic);
    var named_parser = try Parser.init(allocator, named_source);
    const named_program = try named_parser.parseProgram();
    const named_chunk = try Compiler.compileProgram(allocator, named_program);
    var named_env = Environment{ .arena = allocator, .fn_scope = true };
    const named_root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&named_env, named_root_shape);
    const named_global = try gc_mod.allocObj(allocator);
    named_global.* = .{};
    try named_env.put("globalThis", Value.obj(named_global));
    try interp.mirrorGlobalsOnto(&named_env, named_global, named_root_shape);
    var named_machine = Interpreter{
        .arena = allocator,
        .env = &named_env,
        .root_shape = named_root_shape,
        .global_object = named_global,
        .this_value = Value.obj(named_global),
    };
    try std.testing.expectEqual(@as(f64, 88), (try run(&named_machine, named_chunk, null)).asNum());
    try std.testing.expect(quick_observable_recurrence_hits.load(.monotonic) > shared_hits_before);
}

test "vm: quickens packed dense numeric array reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = quick_dense_array_index_hits.load(.monotonic);
    const stores_before = quick_dense_array_store_hits.load(.monotonic);
    const lengths_before = quick_array_length_hits.load(.monotonic);
    const prototype_data_before = quick_array_prototype_data_hits.load(.monotonic);
    const pushes_before = quick_array_push_hits.load(.monotonic);
    const sum_loops_before = quick_packed_array_sum_loop_hits.load(.monotonic);
    const push_loops_before = quick_packed_array_push_loop_hits.load(.monotonic);
    const specialized_expressions_before = quick_packed_array_specialized_expression_hits.load(.monotonic);
    try std.testing.expectEqual(@as(f64, 6), (try vmRun(allocator,
        \\function sum(values) {
        \\  let total = 0;
        \\  for (let i = 0; i < values.length; i = i + 1) total = total + values[i];
        \\  return total;
        \\}
        \\sum([1, 2, 3])
    )).asNum());
    try std.testing.expectEqual(@as(f64, 4), (try vmRun(allocator,
        \\let values = [1, 2, 3]; values.length + values[0]
    )).asNum());
    try std.testing.expect(quick_dense_array_index_hits.load(.monotonic) > before);
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(allocator,
        \\let values = [1, 2]; values[1] = 8; values[0] + values[1]
    )).asNum());
    try std.testing.expect(quick_dense_array_store_hits.load(.monotonic) > stores_before);
    const stores_after = quick_dense_array_store_hits.load(.monotonic);
    try std.testing.expect(quick_array_length_hits.load(.monotonic) > lengths_before);
    try std.testing.expect(quick_packed_array_sum_loop_hits.load(.monotonic) > sum_loops_before);
    const sum_loops_after = quick_packed_array_sum_loop_hits.load(.monotonic);

    try std.testing.expectEqual(@as(f64, 2), (try vmRun(allocator,
        \\let values = []; values.push(1); values.push(2); values.length
    )).asNum());
    try std.testing.expect(quick_array_prototype_data_hits.load(.monotonic) > prototype_data_before);
    try std.testing.expect(quick_array_push_hits.load(.monotonic) > pushes_before);
    try std.testing.expectEqual(@as(f64, 806), (try vmRun(allocator,
        \\function fill(limit, job, lane) {
        \\  let values = [];
        \\  for (let i = 0; i < limit; i = i + 1) values.push((i + job + lane) & 7);
        \\  return values.length * 100 + values[3];
        \\}
        \\fill(8, 2, 1)
    )).asNum());
    try std.testing.expect(quick_packed_array_push_loop_hits.load(.monotonic) > push_loops_before);
    try std.testing.expect(quick_packed_array_specialized_expression_hits.load(.monotonic) > specialized_expressions_before);
    const push_loops_after = quick_packed_array_push_loop_hits.load(.monotonic);
    const pushes_after = quick_array_push_hits.load(.monotonic);

    // Holes and indexed accessors remain observable and must take [[Get]].
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(allocator,
        \\let values = [1, , 3]; Array.prototype[1] = 9; values[1]
    )).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(allocator,
        \\let values = [1]; Object.defineProperty(values, "0", { get: function () { return 7; } }); values[0]
    )).asNum());
    try std.testing.expectEqual(@as(f64, 13), (try vmRun(allocator,
        \\function sum(values) {
        \\  let total = 0;
        \\  for (let i = 0; i < values.length; i = i + 1) total = total + values[i];
        \\  return total;
        \\}
        \\Array.prototype[1] = 9; sum([1, , 3])
    )).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(allocator,
        \\function sum(values) {
        \\  let total = 0;
        \\  for (let i = 0; i < values.length; i = i + 1) total = total + values[i];
        \\  return total;
        \\}
        \\let values = [1]; Object.defineProperty(values, "0", { get: function () { return 7; } }); sum(values)
    )).asNum());
    try std.testing.expectEqual(sum_loops_after, quick_packed_array_sum_loop_hits.load(.monotonic));

    // Accessors, descriptors, holes, and Proxies retain ordinary [[Set]].
    try std.testing.expectEqual(@as(f64, 71), (try vmRun(allocator,
        \\let seen = 0; let values = [1];
        \\Object.defineProperty(values, "0", { set: function (value) { seen = value; } });
        \\values[0] = 7; seen * 10 + values.length
    )).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(allocator,
        \\let values = [1]; Object.defineProperty(values, "0", { writable: false });
        \\values[0] = 7; values[0]
    )).asNum());
    try std.testing.expectEqual(@as(f64, 71), (try vmRun(allocator,
        \\let seen = 0; Object.defineProperty(Array.prototype, "0", {
        \\  set: function (value) { seen = value; }, configurable: true
        \\});
        \\let values = [,]; values[0] = 7; seen * 10 + values.length
    )).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try vmRun(allocator,
        \\let seen = 0; let values = new Proxy([1], {
        \\  set: function (target, key, value) { seen = value; return true; }
        \\});
        \\values[0] = 7; seen
    )).asNum());
    try std.testing.expectEqual(stores_after, quick_dense_array_store_hits.load(.monotonic));

    // Own overrides and prototype accessors remain observable.
    try std.testing.expectEqual(@as(f64, 99), (try vmRun(allocator,
        \\let values = []; values.push = function () { return 99; }; values.push(1)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 77), (try vmRun(allocator,
        \\Object.defineProperty(Array.prototype, "push", {
        \\  get: function () { return function () { return 77; }; }, configurable: true
        \\});
        \\let values = []; values.push(1)
    )).asNum());
    try std.testing.expectEqual(pushes_after, quick_array_push_hits.load(.monotonic));
    try std.testing.expectEqual(@as(f64, 60), (try vmRun(allocator,
        \\function fill() {
        \\  let calls = 0;
        \\  let values = [];
        \\  values.push = function (value) { calls = calls + value; };
        \\  for (let i = 0; i < 3; i = i + 1) values.push(i + 1);
        \\  return calls * 10 + values.length;
        \\}
        \\fill()
    )).asNum());
    try std.testing.expectEqual(push_loops_after, quick_packed_array_push_loop_hits.load(.monotonic));

    // An indexed prototype setter must observe push's ordinary [[Set]].
    try std.testing.expectEqual(@as(f64, 71), (try vmRun(allocator,
        \\let seen = 0;
        \\Object.defineProperty(Array.prototype, "0", {
        \\  set: function (value) { seen = value; }, configurable: true
        \\});
        \\let values = []; values.push(7); seen * 10 + values.length
    )).asNum());
    try std.testing.expectEqual(pushes_after, quick_array_push_hits.load(.monotonic));
}

test "vm: quickens isolated polymorphic own-data property loops with exact steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    const sources = [_][]const u8{
        \\function kernel(objects, lane) {
        \\  let checksum = 0;
        \\  for (let i = 0; i < 32; i = i + 1) {
        \\    let object = objects[i & 3];
        \\    let next = (object.value + i + lane) % 1000003;
        \\    object.value = next;
        \\    checksum = checksum + (next & 1023);
        \\  }
        \\  return checksum + objects[0].value + objects[1].value + objects[2].value + objects[3].value;
        \\}
        \\kernel([{ value: 1, a: 0 }, { b: 0, value: 2 }, { c: 0, d: 0, value: 3 }, { e: 0, f: 0, g: 0, value: 4 }], 2)
        ,
        \\let calls = 0; let backing = 2;
        \\let objects = [{ value: 1, a: 0 }, { b: 0, value: 2 }, { c: 0, d: 0, value: 3 }, { e: 0, f: 0, g: 0, value: 4 }];
        \\Object.defineProperty(objects[1], "value", {
        \\  get: function () { calls = calls + 1; return backing; },
        \\  set: function (value) { calls = calls + 1; backing = value; }
        \\});
        \\function kernel(objects, lane) {
        \\  let checksum = 0;
        \\  for (let i = 0; i < 32; i = i + 1) {
        \\    let object = objects[i & 3];
        \\    let next = (object.value + i + lane) % 1000003;
        \\    object.value = next;
        \\    checksum = checksum + (next & 1023);
        \\  }
        \\  return checksum + calls * 100000 + objects[0].value + backing + objects[2].value + objects[3].value;
        \\}
        \\kernel(objects, 2)
        ,
    };
    const hits_before = quick_polymorphic_property_loop_hits.load(.monotonic);
    var hits = hits_before;
    for (sources) |source| {
        var results: [2]Value = undefined;
        var steps: [2]u64 = undefined;
        for ([_]bool{ false, true }, 0..) |parallel, run_index| {
            bc.ic_seqlock_enabled.store(parallel, .monotonic);
            var parser = try Parser.init(allocator, source);
            const program = try parser.parseProgram();
            const chunk = try Compiler.compileProgram(allocator, program);
            var env = Environment{ .arena = allocator, .fn_scope = true };
            const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
            try interp.installGlobals(&env, root_shape);
            var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape };
            results[run_index] = try run(&machine, chunk, null);
            steps[run_index] = machine.steps;
            const next_hits = quick_polymorphic_property_loop_hits.load(.monotonic);
            if (parallel)
                try std.testing.expectEqual(hits, next_hits)
            else
                try std.testing.expect(next_hits > hits);
            hits = next_hits;
        }
        try std.testing.expectEqual(results[1].rawBits(), results[0].rawBits());
        try std.testing.expectEqual(steps[1], steps[0]);
    }
    try std.testing.expect(hits > hits_before);
}

test "vm: quickens fixed-shape object allocation loops with exact steps and guarded fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const kernel =
        \\function allocate(items, limit, extra) {
        \\  let total = 0;
        \\  let cursor = 0;
        \\  while (cursor < limit) {
        \\    let selected = cursor & 7;
        \\    let old = items[selected];
        \\    let next = (old.seed + cursor + extra) % 1009;
        \\    let replacement = { seed: next, mark: cursor & 3, prior: old.seed };
        \\    items[selected] = replacement;
        \\    total = total + ((replacement.seed + replacement.mark + replacement.prior) & 31);
        \\    cursor = cursor + 1;
        \\  }
        \\  return total;
        \\}
    ;
    const source = try std.fmt.allocPrint(allocator,
        \\{s}
        \\let items = [
        \\  {{ seed: 1, mark: 0, prior: 0 }}, {{ seed: 2, mark: 0, prior: 0 }},
        \\  {{ seed: 3, mark: 0, prior: 0 }}, {{ seed: 4, mark: 0, prior: 0 }},
        \\  {{ seed: 5, mark: 0, prior: 0 }}, {{ seed: 6, mark: 0, prior: 0 }},
        \\  {{ seed: 7, mark: 0, prior: 0 }}, {{ seed: 8, mark: 0, prior: 0 }}
        \\];
        \\allocate(items, 96, 2)
    , .{kernel});
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    const hits_before = quick_object_allocation_loop_hits.load(.monotonic);
    const preparations_before = quick_object_literal_shape_preparations.load(.monotonic);
    var hits = hits_before;
    var results: [2]Value = undefined;
    var steps: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |parallel, run_index| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var parser = try Parser.init(allocator, source);
        const program = try parser.parseProgram();
        const chunk = try Compiler.compileProgram(allocator, program);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape };
        results[run_index] = try run(&machine, chunk, null);
        steps[run_index] = machine.steps;
        const next_hits = quick_object_allocation_loop_hits.load(.monotonic);
        if (parallel) {
            try std.testing.expectEqual(hits, next_hits);
        } else {
            try std.testing.expect(next_hits > hits);
            try std.testing.expect(next_hits - hits > 16);
            try std.testing.expectEqual(
                preparations_before + 1,
                quick_object_literal_shape_preparations.load(.monotonic),
            );
        }
        hits = next_hits;
    }
    try std.testing.expectEqual(
        preparations_before + 1,
        quick_object_literal_shape_preparations.load(.monotonic),
    );
    try std.testing.expectEqual(results[1].rawBits(), results[0].rawBits());
    try std.testing.expectEqual(steps[1], steps[0]);

    bc.ic_seqlock_enabled.store(false, .monotonic);
    const fallback_hits = quick_object_allocation_loop_hits.load(.monotonic);
    const guarded_counter_kernel =
        \\function allocateFrom(items, limit, extra, cursor) {
        \\  let total = 0;
        \\  while (cursor < limit) {
        \\    let selected = cursor & 0;
        \\    let old = items[selected];
        \\    let next = (old.seed + cursor + extra) % 1009;
        \\    let replacement = { seed: next, mark: cursor & 0, prior: old.seed };
        \\    items[selected] = replacement;
        \\    total = total + ((replacement.seed + replacement.mark + replacement.prior) & 31);
        \\    cursor = cursor + 1;
        \\  }
        \\  return total;
        \\}
    ;
    const guarded_counter_cases = [_]struct { limit: []const u8, start: []const u8 }{
        .{ .limit = "1.5", .start = "0.5" },
        .{ .limit = "0", .start = "-1" },
        .{ .limit = "4294967297", .start = "4294967296" },
    };
    for (guarded_counter_cases) |case| {
        const guarded_result = try vmRun(allocator, try std.fmt.allocPrint(
            allocator,
            "{s}\nallocateFrom([{{ seed: 1, mark: 0, prior: 0 }}], {s}, 2, {s})",
            .{ guarded_counter_kernel, case.limit, case.start },
        ));
        try std.testing.expect(guarded_result.isNumber());
        try std.testing.expectEqual(fallback_hits, quick_object_allocation_loop_hits.load(.monotonic));
    }
    try std.testing.expectEqual(@as(f64, 2), (try vmRun(allocator, try std.fmt.allocPrint(allocator,
        \\{s}
        \\let calls = 0;
        \\let items = [{{ seed: 1, mark: 0, prior: 0 }}];
        \\allocate(items, 1, 0);
        \\let observed = {{}};
        \\Object.defineProperty(observed, "seed", {{ get: function () {{ calls = calls + 1; return 3; }} }});
        \\items[0] = observed;
        \\allocate(items, 1, 0);
        \\calls
    , .{kernel}))).asNum());
    try std.testing.expectEqual(fallback_hits, quick_object_allocation_loop_hits.load(.monotonic));
    try std.testing.expectEqual(@as(f64, 1), (try vmRun(allocator, try std.fmt.allocPrint(allocator,
        \\{s}
        \\let stores = 0;
        \\let target = [{{ seed: 1, mark: 0, prior: 0 }}];
        \\allocate(target, 1, 0);
        \\let items = new Proxy(target, {{ set: function (object, key, value) {{ stores = stores + 1; object[key] = value; return true; }} }});
        \\allocate(items, 1, 0);
        \\stores
    , .{kernel}))).asNum());
    try std.testing.expectEqual(fallback_hits, quick_object_allocation_loop_hits.load(.monotonic));
}

test "vm: shared array fast paths retain observable overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    bc.ic_seqlock_enabled.store(true, .monotonic);

    const reads_before = quick_dense_array_index_hits.load(.monotonic);
    const lengths_before = quick_array_length_hits.load(.monotonic);
    const prototype_before = quick_array_prototype_data_hits.load(.monotonic);
    const pushes_before = quick_array_push_hits.load(.monotonic);
    try std.testing.expectEqual(@as(f64, 5), (try vmRun(allocator,
        \\let values = []; values.push(1); values.push(2);
        \\values.length + values[0] + values[1]
    )).asNum());
    try std.testing.expect(quick_dense_array_index_hits.load(.monotonic) > reads_before);
    try std.testing.expect(quick_array_length_hits.load(.monotonic) > lengths_before);
    try std.testing.expect(quick_array_prototype_data_hits.load(.monotonic) > prototype_before);
    try std.testing.expect(quick_array_push_hits.load(.monotonic) > pushes_before);

    try std.testing.expectEqual(@as(f64, 99), (try vmRun(allocator,
        \\let values = []; values.push = function () { return 99; }; values.push(1)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 77), (try vmRun(allocator,
        \\Object.defineProperty(Array.prototype, "push", {
        \\  get: function () { return function () { return 77; }; }, configurable: true
        \\});
        \\let values = []; values.push(1)
    )).asNum());
}

test "vm: packed array sum quickening preserves bytecode steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function sum(values) {
        \\  let total = 0;
        \\  for (let i = 0; i < values.length; i = i + 1) total = total + values[i];
        \\  return total;
        \\}
        \\function fill() {
        \\  let values = [];
        \\  for (let i = 1; i < 9; i = i + 1) values.push(i);
        \\  return values;
        \\}
        \\sum(fill())
    ;
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    var steps: [2]u64 = undefined;
    var sum_hits = quick_packed_array_sum_loop_hits.load(.monotonic);
    var push_hits = quick_packed_array_push_loop_hits.load(.monotonic);
    for ([_]bool{ false, true }, 0..) |parallel, run_index| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var parser = try Parser.init(allocator, source);
        const program = try parser.parseProgram();
        const chunk = try Compiler.compileProgram(allocator, program);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape };
        try std.testing.expectEqual(@as(f64, 36), (try run(&machine, chunk, null)).asNum());
        steps[run_index] = machine.steps;
        const next_sum_hits = quick_packed_array_sum_loop_hits.load(.monotonic);
        const next_push_hits = quick_packed_array_push_loop_hits.load(.monotonic);
        try std.testing.expect(next_sum_hits > sum_hits);
        try std.testing.expect(next_push_hits > push_hits);
        sum_hits = next_sum_hits;
        push_hits = next_push_hits;
    }
    try std.testing.expectEqual(steps[1], steps[0]);
}

test "vm: quickens warmed numeric property update traces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    bc.ic_seqlock_enabled.store(false, .monotonic);
    var parser = try Parser.init(allocator,
        \\function update() {
        \\  const object = { a: 1, b: 2 };
        \\  let i = 0;
        \\  while (i < 4) {
        \\    object.a = object.a + i;
        \\    object.b = object.a + object.b;
        \\    i = i + 1;
        \\  }
        \\  return object.a * 100 + object.b;
        \\}
    );
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    var env = Environment{ .arena = allocator, .fn_scope = true };
    const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
    try interp.installGlobals(&env, root_shape);
    var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape };
    _ = try run(&machine, root, null);

    const function_value = env.get("update").?;
    const function = Interpreter.funcOf(function_value).?;
    const function_chunk = function.chunk.?;
    const before = quick_property_update_hits.load(.monotonic);
    const loop_tails_before = quick_property_loop_tail_hits.load(.monotonic);
    const specialized_before = quick_property_specialized_hits.load(.monotonic);
    var expected_steps: u64 = 0;
    for (0..3) |iteration| {
        if (iteration == 2) machine.steps = 1018;
        const start_steps = machine.steps;
        try std.testing.expectEqual(@as(f64, 716), (try runFunction(
            &machine,
            function,
            function_chunk,
            &.{},
            Value.undef(),
            Value.undef(),
        )).asNum());
        const elapsed_steps = machine.steps - start_steps;
        if (iteration == 0)
            expected_steps = elapsed_steps
        else
            try std.testing.expectEqual(expected_steps, elapsed_steps);
    }
    try std.testing.expect(quick_property_update_hits.load(.monotonic) > before);
    try std.testing.expect(quick_property_loop_tail_hits.load(.monotonic) > loop_tails_before);
    try std.testing.expect(quick_property_specialized_hits.load(.monotonic) > specialized_before);
    var cached_plan = false;
    for (function_chunk.quick_property_plans) |plan| cached_plan = cached_plan or plan != null;
    try std.testing.expect(cached_plan);
}

test "vm: caches unsupported isolated property quickening plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\function lookup(array, index) { return array[index]; }
    );
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const function_chunk = root.fns.items[0].chunk.?;

    var candidate: ?usize = null;
    for (function_chunk.code.items, 0..) |instruction, index| {
        if (instruction.op == .load_local and index + 2 < function_chunk.code.items.len and
            function_chunk.code.items[index + 1].op == .load_local and
            function_chunk.code.items[index + 2].op == .get_index)
        {
            candidate = index;
            break;
        }
    }
    const start = candidate orelse return error.TestUnexpectedResult;
    try std.testing.expect(quickPropertyKernelPlan(function_chunk, start, true) != null);
    try std.testing.expect(!quickPropertySiteMayApply(function_chunk, start, true));
    try std.testing.expect(quickPropertySiteMayApply(function_chunk, start, false));
    const attempts_before = quick_property_plan_decode_attempts.load(.monotonic);
    try std.testing.expect(quickPropertyPlan(function_chunk, start) == null);
    try std.testing.expectEqual(attempts_before + 1, quick_property_plan_decode_attempts.load(.monotonic));
    try std.testing.expect(function_chunk.quick_property_plans[start].? == unsupportedQuickPropertyPlanRaw());
    try std.testing.expect(quickPropertyPlan(function_chunk, start) == null);
    try std.testing.expectEqual(attempts_before + 1, quick_property_plan_decode_attempts.load(.monotonic));
}

test "vm: fuses warmed four-property loops with exact bytecode steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function kernel() {
        \\  const object = { a: 0, b: 1, c: 2, d: 3 };
        \\  let i = 0;
        \\  while (i < 8) {
        \\    object.a = (object.a + i) % 1000003;
        \\    object.b = object.b + 1;
        \\    object.c = object.a + object.b;
        \\    object.d = object.c - object.b;
        \\    i = i + 1;
        \\  }
        \\  return object.a * 1000000 + object.b * 10000 + object.c * 100 + object.d;
        \\}
        \\kernel()
    ;
    const old_parallel = bc.ic_seqlock_enabled.load(.monotonic);
    defer bc.ic_seqlock_enabled.store(old_parallel, .monotonic);
    const hits_before = quick_property_kernel_hits.load(.monotonic);
    var results: [2]f64 = undefined;
    var steps: [2]u64 = undefined;
    var kernel_hits = hits_before;
    for ([_]bool{ false, true }, 0..) |parallel, run_index| {
        bc.ic_seqlock_enabled.store(parallel, .monotonic);
        var parser = try Parser.init(allocator, source);
        const program = try parser.parseProgram();
        const chunk = try Compiler.compileProgram(allocator, program);
        var env = Environment{ .arena = allocator, .fn_scope = true };
        const root_shape = try @import("shape.zig").Shape.createRoot(allocator);
        try interp.installGlobals(&env, root_shape);
        var machine = Interpreter{ .arena = allocator, .env = &env, .root_shape = root_shape };
        results[run_index] = (try run(&machine, chunk, null)).asNum();
        steps[run_index] = machine.steps;
        const next_hits = quick_property_kernel_hits.load(.monotonic);
        try std.testing.expect(next_hits > kernel_hits);
        kernel_hits = next_hits;
    }
    try std.testing.expectEqual(results[1], results[0]);
    try std.testing.expectEqual(steps[1], steps[0]);

    // A structurally identical loop with an observable accessor must retain
    // ordinary per-operation [[Get]]/[[Set]] behavior in synchronized mode.
    try std.testing.expectEqual(@as(f64, 9), (try vmRun(allocator,
        \\function accessorKernel() {
        \\  let calls = 0; let backing = 0;
        \\  const object = { a: 0, b: 1, c: 2, d: 3 };
        \\  Object.defineProperty(object, "a", {
        \\    get: function () { calls = calls + 1; return backing; },
        \\    set: function (value) { calls = calls + 1; backing = value; }
        \\  });
        \\  let i = 0;
        \\  while (i < 3) {
        \\    object.a = (object.a + i) % 1000003;
        \\    object.b = object.b + 1;
        \\    object.c = object.a + object.b;
        \\    object.d = object.c - object.b;
        \\    i = i + 1;
        \\  }
        \\  return calls;
        \\}
        \\accessorKernel()
    )).asNum());
    try std.testing.expectEqual(kernel_hits, quick_property_kernel_hits.load(.monotonic));
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
