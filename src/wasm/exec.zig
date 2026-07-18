//! WebAssembly MVP (wg-1.0) execution engine: store, instantiation, and
//! interpreter.
//!
//! The store is host-agnostic: hosts create `MemoryInst`/`TableInst`/
//! `GlobalInst`/`ImportFunc` values and hand them to `instantiate`, which
//! wires up the module's full index spaces (imports first) and runs the
//! wg-1.0 instantiation algorithm (import checks, allocation, elem/data
//! segment application, optional start function). `invoke`/`callFuncInst`
//! run the interpreter with per-invocation state, so host imports may
//! re-enter wasm execution safely.
//!
//! Values on the operand stack and typed argument/result slots retain their
//! WebAssembly type. Numeric payloads are raw bits: i32 and f32 live in the
//! low 32 bits with the upper bits zero; i64 and f64 use all 64 bits. The
//! legacy `u64` invocation path is numeric-only.

const std = @import("std");
const js_value = @import("../value.zig");
const types = @import("types.zig");
const decode = @import("decode.zig");
const validate = @import("validate.zig");

const Allocator = std.mem.Allocator;
pub const ValueSlot = js_value.WasmSlot;
const WasmSlot = ValueSlot;

pub const ExecError = error{ OutOfMemory, Trap, Host };

pub const RootHooks = struct {
    ctx: *anyopaque,
    enter: *const fn (*anyopaque, *js_value.WasmExecutionRoots) error{OutOfMemory}!void,
    leave: *const fn (*anyopaque, *js_value.WasmExecutionRoots) void,
    checkpoint: *const fn (*anyopaque, *js_value.WasmExecutionRoots) void,
};

/// Host-imported function. `ctx` is host-owned (traced/freed by the host).
pub const ImportFunc = struct {
    ctx: *anyopaque,
    type: types.FuncType,
    call: *const fn (ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void,
    call_slots: ?*const fn (ctx: *anyopaque, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) error{ Trap, Host }!void = null,
    owner_instance: ?*Instance = null,
};

pub const FunctionHost = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, func: *FuncInst) js_value.HostError!js_value.Value,
};

pub const FuncInst = union(enum) {
    defined: struct { inst: *Instance, idx: u32 }, // idx into module-defined funcs (0-based after imports)
    imported: ImportFunc, // by value
};

pub const MemoryInst = struct {
    bytes: []u8,
    limits: types.Limits,
    gpa: Allocator,
    /// Host hook (WebAssembly JS API, issue #141): when set, `memoryGrow`
    /// calls it after the new bytes are in place and before the old bytes are
    /// freed, so the host can re-expose the grown buffer (e.g. swap a JS
    /// ArrayBuffer onto the fresh allocation). Returning false rolls the grow
    /// back failure-atomically. Null on the pure-wasm path.
    on_grow: ?*const fn (ctx: *anyopaque, mem: *MemoryInst) bool = null,
    on_grow_ctx: ?*anyopaque = null,

    pub fn pages(self: *const MemoryInst) u32 {
        return @intCast(self.bytes.len / types.PAGE_SIZE);
    }
};

pub const TableInst = struct {
    elems: []ValueSlot,
    type: types.ValType = .funcref,
    limits: types.Limits,
    gpa: Allocator,
    lock: std.atomic.Mutex = .unlocked,

    pub fn lockTable(self: *TableInst) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlockTable(self: *TableInst) void {
        self.lock.unlock();
    }
};

pub const GlobalInst = struct {
    type: types.GlobalType,
    value: ValueSlot,
    ref_root: std.atomic.Value(u64) = .init(js_value.Value.undef().bits),
    barrier_ctx: ?*anyopaque = null,
    barrier: ?*const fn (*anyopaque, ValueSlot) void = null,
};

pub const Imports = struct {
    funcs: []const ImportFunc = &.{}, // in import declaration order, per kind
    tables: []const *TableInst = &.{},
    mems: []const *MemoryInst = &.{},
    globals: []const *GlobalInst = &.{},
};

pub const LinkError = error{ OutOfMemory, Link, Trap, Host };

/// A fully instantiated module: full index spaces, imports first. `module`
/// is borrowed (NOT owned); internal slices live in the instance arena.
/// Defined tables/mems/globals are owned and freed by `destroyInstance`;
/// imported ones belong to the host.
pub const Instance = struct {
    module: *const types.Module,
    funcs: []*FuncInst,
    tables: []*TableInst,
    mems: []*MemoryInst,
    globals: []*GlobalInst,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    root_hooks: ?RootHooks = null,
    function_host: ?FunctionHost = null,
};

// ---------------------------------------------------------------------------
// Host-side constructors
// ---------------------------------------------------------------------------

pub fn createMemory(gpa: Allocator, min_pages: u32, max_pages: ?u32) error{OutOfMemory}!*MemoryInst {
    const m = try gpa.create(MemoryInst);
    errdefer gpa.destroy(m);
    m.* = .{
        .bytes = try gpa.alloc(u8, @as(usize, min_pages) * types.PAGE_SIZE),
        .limits = .{ .min = min_pages, .max = max_pages },
        .gpa = gpa,
    };
    @memset(m.bytes, 0);
    return m;
}

pub fn destroyMemory(gpa: Allocator, mem: *MemoryInst) void {
    gpa.free(mem.bytes);
    gpa.destroy(mem);
}

/// Grow by `delta` pages. Returns the previous page count, or -1 on
/// failure (limit exceeded or allocation failure); failure leaves the
/// memory untouched.
pub fn memoryGrow(mem: *MemoryInst, delta: u32) i32 {
    const old_pages = mem.pages();
    if (delta == 0) return @intCast(old_pages);
    const limit = @min(mem.limits.max orelse types.MAX_PAGES, types.MAX_PAGES);
    if (old_pages >= limit) return -1;
    if (delta > limit - old_pages) return -1;
    const new_len = @as(usize, old_pages + delta) * types.PAGE_SIZE;
    if (mem.on_grow) |cb| {
        // Host-observed grow: `realloc` may release the old bytes before the
        // hook could observe the grown buffer, so allocate fresh, publish the
        // new bytes, run the hook, and only then free the old slab.
        const fresh = mem.gpa.alloc(u8, new_len) catch return -1;
        @memcpy(fresh[0..mem.bytes.len], mem.bytes);
        @memset(fresh[mem.bytes.len..], 0);
        const old = mem.bytes;
        mem.bytes = fresh;
        if (!cb(mem.on_grow_ctx orelse @ptrCast(mem), mem)) {
            mem.bytes = old;
            mem.gpa.free(fresh);
            return -1;
        }
        mem.gpa.free(old);
        return @intCast(old_pages);
    }
    mem.bytes = mem.gpa.realloc(mem.bytes, new_len) catch return -1;
    @memset(mem.bytes[@as(usize, old_pages) * types.PAGE_SIZE ..], 0);
    return @intCast(old_pages);
}

pub fn createTable(gpa: Allocator, initial: u32, max: ?u32) error{OutOfMemory}!*TableInst {
    return createTableTyped(gpa, .funcref, initial, max);
}

pub fn createTableTyped(gpa: Allocator, elem_type: types.ValType, initial: u32, max: ?u32) error{OutOfMemory}!*TableInst {
    const t = try gpa.create(TableInst);
    errdefer gpa.destroy(t);
    t.* = .{
        .elems = try gpa.alloc(ValueSlot, initial),
        .type = elem_type,
        .limits = .{ .min = initial, .max = max },
        .gpa = gpa,
    };
    @memset(t.elems, nullTableSlot(elem_type));
    return t;
}

pub fn destroyTable(gpa: Allocator, tab: *TableInst) void {
    gpa.free(tab.elems);
    gpa.destroy(tab);
}

/// Grow by `delta` elements (null-initialized). Returns the previous
/// element count, or -1 on failure.
pub fn tableGrow(tab: *TableInst, delta: u32) i32 {
    return tableGrowWith(tab, delta, nullTableSlot(tab.type));
}

/// Grow and initialize new slots with `fill` while holding the table lock, so
/// a concurrent indirect call observes either the old table or the complete
/// grown table.
pub fn tableGrowWith(tab: *TableInst, delta: u32, fill: ValueSlot) i32 {
    tab.lockTable();
    defer tab.unlockTable();
    const old: u32 = @intCast(tab.elems.len);
    if (delta == 0) return @intCast(old);
    const limit = tab.limits.max orelse std.math.maxInt(u32);
    if (old >= limit) return -1;
    if (delta > limit - old) return -1;
    tab.elems = tab.gpa.realloc(tab.elems, old + delta) catch return -1;
    @memset(tab.elems[old..], fill);
    return @intCast(old);
}

fn nullTableSlot(elem_type: types.ValType) ValueSlot {
    return switch (elem_type) {
        .funcref => .{ .funcref = null },
        .externref => .{ .externref = js_value.Value.nul() },
        else => unreachable,
    };
}

fn funcFromSlot(slot: ValueSlot) ?*FuncInst {
    return if (slot.funcref) |func| @ptrCast(@alignCast(func)) else null;
}

pub fn createGlobal(gpa: Allocator, gt: types.GlobalType, value: u64) error{OutOfMemory}!*GlobalInst {
    return createGlobalSlot(gpa, gt, .{ .numeric = value });
}

pub fn createGlobalSlot(gpa: Allocator, gt: types.GlobalType, value: ValueSlot) error{OutOfMemory}!*GlobalInst {
    const g = try gpa.create(GlobalInst);
    g.* = .{ .type = gt, .value = value };
    publishGlobalValue(g, value);
    return g;
}

fn publishGlobalValue(global: *GlobalInst, slot: ValueSlot) void {
    const bits = switch (slot) {
        .externref => |ref| ref.bits,
        .numeric, .funcref => js_value.Value.undef().bits,
    };
    global.ref_root.store(bits, .release);
    if (global.barrier) |barrier| barrier(global.barrier_ctx.?, slot);
}

pub fn setGlobalValue(global: *GlobalInst, slot: ValueSlot) void {
    global.value = slot;
    publishGlobalValue(global, slot);
}

pub fn destroyGlobal(gpa: Allocator, g: *GlobalInst) void {
    gpa.destroy(g);
}

// ---------------------------------------------------------------------------
// Instantiation (wg-1.0)
// ---------------------------------------------------------------------------

/// Import limits compatibility: the provided instance must be at least as
/// large as declared, and a declared maximum must be matched by a provided
/// maximum within it.
fn limitsCompatible(actual: types.Limits, declared: types.Limits) bool {
    if (actual.min < declared.min) return false;
    if (declared.max) |dmax| {
        const amax = actual.max orelse return false;
        if (amax > dmax) return false;
    }
    return true;
}

fn evalConstExpr(inst: *const Instance, ce: types.ConstExpr) ValueSlot {
    return switch (ce) {
        .i32 => |v| .{ .numeric = @as(u32, @bitCast(v)) },
        .i64 => |v| .{ .numeric = @as(u64, @bitCast(v)) },
        .f32 => |bits| .{ .numeric = @as(u64, bits) },
        .f64 => |bits| .{ .numeric = bits },
        .global => |k| inst.globals[k].value,
        .ref_null => |ref_type| switch (ref_type) {
            .funcref => .{ .funcref = null },
            .externref => .{ .externref = js_value.Value.nul() },
            else => unreachable,
        },
        .ref_func => |funcidx| .{ .funcref = @ptrCast(inst.funcs[funcidx]) },
    };
}

/// Allocate/link an instance and apply active segments without invoking its
/// start function. Embedders that must retain store mutations after a trapping
/// start (the JS API) take ownership here, then call `runStart` separately.
pub fn instantiateStore(gpa: Allocator, mod: *const types.Module, imports: Imports, diag: *types.Diagnostic) error{ OutOfMemory, Link }!*Instance {
    // 1. Import resolution.
    if (imports.funcs.len != mod.imported_funcs or
        imports.tables.len != mod.imported_tables or
        imports.mems.len != mod.imported_mems or
        imports.globals.len != mod.imported_globals)
    {
        diag.set(types.Diagnostic.no_offset, "inconsistent import count", .{});
        return error.Link;
    }
    {
        var ti: usize = 0;
        var mi: usize = 0;
        var gi: usize = 0;
        for (mod.imports) |imp| {
            switch (imp.desc) {
                .func => {},
                .table => |tt| {
                    if (imports.tables[ti].type != tt.elem or
                        !limitsCompatible(imports.tables[ti].limits, tt.limits))
                    {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    ti += 1;
                },
                .mem => |mt| {
                    if (!limitsCompatible(imports.mems[mi].limits, mt.limits)) {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    mi += 1;
                },
                .global => |gt| {
                    const ig = imports.globals[gi];
                    if (ig.type.val != gt.val or ig.type.mutable != gt.mutable) {
                        diag.set(types.Diagnostic.no_offset, "incompatible import type", .{});
                        return error.Link;
                    }
                    gi += 1;
                },
            }
        }
    }

    const inst = try gpa.create(Instance);
    inst.* = .{
        .module = mod,
        .funcs = &.{},
        .tables = &.{},
        .mems = &.{},
        .globals = &.{},
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    var created_tables: usize = 0;
    var created_mems: usize = 0;
    var created_globals: usize = 0;
    errdefer {
        for (inst.tables[inst.tables.len - created_tables ..]) |t| destroyTable(gpa, t);
        for (inst.mems[inst.mems.len - created_mems ..]) |m| destroyMemory(gpa, m);
        for (inst.globals[inst.globals.len - created_globals ..]) |g| destroyGlobal(gpa, g);
        inst.arena.deinit();
        gpa.destroy(inst);
    }
    const a = inst.arena.allocator();

    // Function index space: imported FuncInst copies, then defined ones.
    inst.funcs = try a.alloc(*FuncInst, mod.totalFuncs());
    var fi: usize = 0;
    for (imports.funcs) |imf| {
        const p = try a.create(FuncInst);
        p.* = .{ .imported = imf };
        p.imported.owner_instance = inst;
        inst.funcs[fi] = p;
        fi += 1;
    }
    for (0..mod.funcs.len) |j| {
        const p = try a.create(FuncInst);
        p.* = .{ .defined = .{ .inst = inst, .idx = @intCast(j) } };
        inst.funcs[fi] = p;
        fi += 1;
    }

    // 2. Allocate defined tables, memories, globals (imports first).
    inst.tables = try a.alloc(*TableInst, mod.totalTables());
    for (imports.tables, 0..) |t, k| inst.tables[k] = t;
    for (mod.tables, 0..) |tt, j| {
        const t = try createTableTyped(gpa, tt.elem, tt.limits.min, tt.limits.max);
        created_tables += 1;
        inst.tables[mod.imported_tables + j] = t;
    }

    inst.mems = try a.alloc(*MemoryInst, mod.totalMems());
    for (imports.mems, 0..) |m, k| inst.mems[k] = m;
    for (mod.mems, 0..) |mt, j| {
        const m = try createMemory(gpa, mt.limits.min, mt.limits.max);
        created_mems += 1;
        inst.mems[mod.imported_mems + j] = m;
    }

    inst.globals = try a.alloc(*GlobalInst, mod.totalGlobals());
    for (imports.globals, 0..) |g, k| inst.globals[k] = g;
    for (mod.globals, 0..) |gd, j| {
        const g = try createGlobalSlot(gpa, gd.type, evalConstExpr(inst, gd.init));
        created_globals += 1;
        inst.globals[mod.imported_globals + j] = g;
    }

    // 3. Preflight every active segment before mutating any store. A link
    // failure must leave imported memories and tables untouched; start-function
    // traps happen later and deliberately retain already-applied mutations.
    for (mod.elems) |e| {
        const tab = inst.tables[e.table];
        const start: u64 = @as(u32, @truncate(evalConstExpr(inst, e.offset).numericBits()));
        tab.lockTable();
        const table_len: u64 = @intCast(tab.elems.len);
        const available = if (start <= table_len) tab.elems.len - @as(usize, @intCast(start)) else 0;
        const in_bounds = start <= table_len and e.funcs.len <= available;
        tab.unlockTable();
        if (!in_bounds) {
            diag.set(types.Diagnostic.no_offset, "out of bounds table index", .{});
            return error.Link;
        }
    }
    for (mod.datas) |d| {
        const mem = inst.mems[d.mem];
        const start: u64 = @as(u32, @truncate(evalConstExpr(inst, d.offset).numericBits()));
        const memory_len: u64 = @intCast(mem.bytes.len);
        const available = if (start <= memory_len) mem.bytes.len - @as(usize, @intCast(start)) else 0;
        if (start > memory_len or d.bytes.len > available) {
            diag.set(types.Diagnostic.no_offset, "out of bounds memory index", .{});
            return error.Link;
        }
    }

    // 4. Apply element segments.
    for (mod.elems) |e| {
        const tab = inst.tables[e.table];
        const start: u64 = @as(u32, @truncate(evalConstExpr(inst, e.offset).numericBits()));
        tab.lockTable();
        for (e.funcs, 0..) |fidx, j| tab.elems[@intCast(start + j)] = .{ .funcref = @ptrCast(inst.funcs[fidx]) };
        tab.unlockTable();
    }

    // 5. Apply data segments.
    for (mod.datas) |d| {
        const mem = inst.mems[d.mem];
        const start: u64 = @as(u32, @truncate(evalConstExpr(inst, d.offset).numericBits()));
        const lo: usize = @intCast(start);
        @memcpy(mem.bytes[lo..][0..d.bytes.len], d.bytes);
    }

    return inst;
}

pub fn runStart(inst: *Instance, diag: *types.Diagnostic) ExecError!void {
    if (inst.module.start) |sidx| try invoke(inst, sidx, &.{}, &.{}, diag);
}

pub fn instantiate(gpa: Allocator, mod: *const types.Module, imports: Imports, diag: *types.Diagnostic) LinkError!*Instance {
    const inst = try instantiateStore(gpa, mod, imports, diag);
    errdefer destroyInstance(gpa, inst);
    try runStart(inst, diag);
    return inst;
}

pub fn destroyInstance(gpa: Allocator, inst: *Instance) void {
    const mod = inst.module;
    for (inst.tables[mod.imported_tables..]) |t| destroyTable(gpa, t);
    for (inst.mems[mod.imported_mems..]) |m| destroyMemory(gpa, m);
    for (inst.globals[mod.imported_globals..]) |g| destroyGlobal(gpa, g);
    inst.arena.deinit();
    gpa.destroy(inst);
}

// ---------------------------------------------------------------------------
// Invocation
// ---------------------------------------------------------------------------

/// Invoke any function in the instance's index space (incl. imported).
pub fn invoke(inst: *Instance, funcidx: u32, args: []const u64, results: []u64, diag: *types.Diagnostic) ExecError!void {
    if (funcidx >= inst.funcs.len) {
        diag.set(types.Diagnostic.no_offset, "unknown function", .{});
        return error.Trap;
    }
    return callFuncInst(inst.funcs[funcidx], args, results, diag);
}

pub fn invokeSlots(inst: *Instance, funcidx: u32, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    if (funcidx >= inst.funcs.len) {
        diag.set(types.Diagnostic.no_offset, "unknown function", .{});
        return error.Trap;
    }
    return callFuncInstSlots(inst.funcs[funcidx], args, results, diag);
}

/// Invoke a function instance obtained e.g. from a table (cross-instance).
pub fn callFuncInst(f: *const FuncInst, args: []const u64, results: []u64, diag: *types.Diagnostic) ExecError!void {
    const alloc = std.heap.page_allocator;
    const slot_args = try alloc.alloc(ValueSlot, args.len);
    defer alloc.free(slot_args);
    const slot_results = try alloc.alloc(ValueSlot, results.len);
    defer alloc.free(slot_results);
    for (args, 0..) |bits, i| slot_args[i] = .{ .numeric = bits };
    try callFuncInstSlots(f, slot_args, slot_results, diag);
    for (slot_results, 0..) |slot, i| results[i] = slot.numericBits();
}

fn slotMatchesType(slot: ValueSlot, val_type: types.ValType) bool {
    return switch (val_type) {
        .i32, .i64, .f32, .f64 => slot == .numeric,
        .funcref => slot == .funcref,
        .externref => slot == .externref,
    };
}

fn argumentsMatchSignature(signature: types.FuncType, args: []const ValueSlot, result_len: usize) bool {
    if (args.len != signature.params.len or result_len != signature.results.len) return false;
    for (args, signature.params) |slot, val_type|
        if (!slotMatchesType(slot, val_type)) return false;
    return true;
}

fn callNumericImport(alloc: Allocator, imp: *const ImportFunc, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    const raw_args = try alloc.alloc(u64, args.len);
    defer alloc.free(raw_args);
    const raw_results = try alloc.alloc(u64, results.len);
    defer alloc.free(raw_results);
    for (args, 0..) |slot, i| raw_args[i] = slot.numericBits();
    try imp.call(imp.ctx, raw_args, raw_results, diag);
    for (raw_results, 0..) |bits, i| results[i] = .{ .numeric = bits };
}

/// Invoke a function instance with unambiguous numeric/reference slots.
pub fn callFuncInstSlots(f: *const FuncInst, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    switch (f.*) {
        .imported => |*imp| {
            if (!argumentsMatchSignature(imp.type, args, results.len)) {
                diag.set(types.Diagnostic.no_offset, "function signature mismatch", .{});
                return error.Trap;
            }
            if (imp.call_slots) |call_slots|
                try call_slots(imp.ctx, args, results, diag)
            else
                try callNumericImport(std.heap.page_allocator, imp, args, results, diag);
            for (results, imp.type.results) |slot, val_type| {
                if (!slotMatchesType(slot, val_type)) {
                    diag.set(types.Diagnostic.no_offset, "function signature mismatch", .{});
                    return error.Trap;
                }
            }
        },
        .defined => try runDefinedSlots(f, args, results, diag),
    }
}

fn runDefinedSlots(f: *const FuncInst, args: []const ValueSlot, results: []ValueSlot, diag: *types.Diagnostic) ExecError!void {
    const def = f.defined;
    const fty = def.inst.module.types[def.inst.module.funcs[def.idx]];
    if (!argumentsMatchSignature(fty, args, results.len)) {
        diag.set(types.Diagnostic.no_offset, "function signature mismatch", .{});
        return error.Trap;
    }
    // Per-invocation state: reentrant by construction (a host import calling
    // back into wasm gets a fresh arena, stack, and frame set).
    var arena = std.heap.ArenaAllocator.init(def.inst.gpa);
    defer arena.deinit();
    var s: State = .{ .alloc = arena.allocator(), .diag = diag, .root_hooks = def.inst.root_hooks };
    if (s.root_hooks) |hooks| {
        try hooks.enter(hooks.ctx, &s.roots);
        defer hooks.leave(hooks.ctx, &s.roots);
    }
    try execute(&s, f, args, results);
}

// ---------------------------------------------------------------------------
// Interpreter
// ---------------------------------------------------------------------------

const MAX_FRAMES: usize = 1024;
const MAX_OPERAND_SLOTS: usize = 1 << 20;

const Label = struct {
    target_pc: u32, // loop -> body start; block/if -> pc past end
    stack_height: usize, // operand stack height when the label was pushed
    arity: usize, // values carried on branch (loop -> 0)
    is_loop: bool,
};

const Frame = struct {
    func: *const FuncInst, // always .defined
    pc: u32,
    locals_base: usize,
    stack_base: usize, // operand stack height at entry (params already consumed)
    label_base: usize, // label stack height at entry; function label sits here
    result_arity: usize,
};

const State = struct {
    alloc: Allocator, // per-invocation arena
    diag: *types.Diagnostic,
    stack: std.ArrayListUnmanaged(WasmSlot) = .empty,
    locals: std.ArrayListUnmanaged(WasmSlot) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    labels: std.ArrayListUnmanaged(Label) = .empty,
    roots: js_value.WasmExecutionRoots = .{},
    root_hooks: ?RootHooks = null,

    fn trap(s: *State, comptime msg: []const u8) error{Trap} {
        s.diag.set(types.Diagnostic.no_offset, msg, .{});
        return error.Trap;
    }
};

fn checkpoint(s: *State) void {
    s.roots.stack = s.stack.items;
    s.roots.locals = s.locals.items;
    if (s.root_hooks) |hooks| hooks.checkpoint(hooks.ctx, &s.roots);
}

fn push(s: *State, v: u64) ExecError!void {
    try pushSlot(s, .{ .numeric = v });
}

fn pushSlot(s: *State, slot: WasmSlot) ExecError!void {
    if (s.stack.items.len >= MAX_OPERAND_SLOTS) return s.trap("operand stack exhausted");
    try s.stack.append(s.alloc, slot);
}

fn pop(s: *State) u64 {
    return popSlot(s).numericBits();
}

fn popSlot(s: *State) WasmSlot {
    const v = s.stack.items[s.stack.items.len - 1];
    s.stack.items.len -= 1;
    return v;
}

fn pushI32(s: *State, v: u32) ExecError!void {
    try push(s, v);
}

fn pushI64(s: *State, v: u64) ExecError!void {
    try push(s, v);
}

fn pushF32(s: *State, v: f32) ExecError!void {
    try push(s, @as(u32, @bitCast(v)));
}

fn pushF64(s: *State, v: f64) ExecError!void {
    try push(s, @bitCast(v));
}

fn pushBool(s: *State, v: bool) ExecError!void {
    try push(s, @intFromBool(v));
}

fn popI32(s: *State) u32 {
    return @truncate(pop(s));
}

fn popF32(s: *State) f32 {
    return @bitCast(@as(u32, @truncate(pop(s))));
}

fn popF64(s: *State) f64 {
    return @bitCast(pop(s));
}

fn pushFrame(s: *State, f: *const FuncInst) ExecError!void {
    if (s.frames.items.len >= MAX_FRAMES) return s.trap("call stack exhausted");
    const def = f.defined;
    const mod = def.inst.module;
    const body = &mod.code[def.idx];
    const fty = mod.types[mod.funcs[def.idx]];
    // Params move from the operand stack into fresh locals; declared locals
    // follow, zero-initialized.
    const arg_start = s.stack.items.len - fty.params.len;
    const locals_base = s.locals.items.len;
    try s.locals.appendSlice(s.alloc, s.stack.items[arg_start..]);
    s.stack.items.len = arg_start;
    for (body.locals) |local_type| try s.locals.append(s.alloc, switch (local_type) {
        .i32, .i64, .f32, .f64 => .{ .numeric = 0 },
        .funcref => .{ .funcref = null },
        .externref => .{ .externref = js_value.Value.nul() },
    });
    try s.frames.append(s.alloc, .{
        .func = f,
        .pc = 0,
        .locals_base = locals_base,
        .stack_base = s.stack.items.len,
        .label_base = s.labels.items.len,
        .result_arity = fty.results.len,
    });
    // Implicit function-level label: branching to it returns.
    try s.labels.append(s.alloc, .{
        .target_pc = @intCast(body.instrs.len),
        .stack_height = s.stack.items.len,
        .arity = fty.results.len,
        .is_loop = false,
    });
}

/// Pop the current frame, moving its result values onto the caller's
/// operand stack.
fn returnFrame(s: *State) void {
    const fr = s.frames.items[s.frames.items.len - 1];
    const top = s.stack.items.len;
    std.mem.copyForwards(WasmSlot, s.stack.items[fr.stack_base..][0..fr.result_arity], s.stack.items[top - fr.result_arity ..]);
    s.stack.items.len = fr.stack_base + fr.result_arity;
    s.labels.items.len = fr.label_base;
    s.locals.items.len = fr.locals_base;
    s.frames.items.len -= 1;
}

/// Branch to the label `depth` levels out, carrying its arity of values.
/// A branch to the function-level label returns from the current frame.
fn branchTo(s: *State, depth: u32) void {
    const fr = &s.frames.items[s.frames.items.len - 1];
    const li = s.labels.items.len - 1 - depth;
    const lab = s.labels.items[li];
    const top = s.stack.items.len;
    std.mem.copyForwards(WasmSlot, s.stack.items[lab.stack_height..][0..lab.arity], s.stack.items[top - lab.arity ..]);
    s.stack.items.len = lab.stack_height + lab.arity;
    if (li == fr.label_base) {
        s.labels.items.len = fr.label_base;
        s.locals.items.len = fr.locals_base;
        s.frames.items.len -= 1;
    } else if (lab.is_loop) {
        s.labels.items.len = li + 1;
        fr.pc = lab.target_pc;
        checkpoint(s);
    } else {
        s.labels.items.len = li;
        fr.pc = lab.target_pc;
    }
}

fn callFunc(s: *State, f: *const FuncInst) ExecError!void {
    checkpoint(s);
    switch (f.*) {
        .defined => try pushFrame(s, f),
        .imported => |*imp| {
            const arg_start = s.stack.items.len - imp.type.params.len;
            const args = s.stack.items[arg_start..];
            const res = try s.alloc.alloc(ValueSlot, imp.type.results.len);
            if (!argumentsMatchSignature(imp.type, args, res.len))
                return s.trap("function signature mismatch");
            if (imp.call_slots) |call_slots|
                try call_slots(imp.ctx, args, res, s.diag)
            else
                try callNumericImport(s.alloc, imp, args, res, s.diag);
            for (res, imp.type.results) |slot, val_type|
                if (!slotMatchesType(slot, val_type)) return s.trap("function signature mismatch");
            s.stack.items.len = arg_start;
            for (res) |slot| try pushSlot(s, slot);
        },
    }
}

fn effAddr(s: *State, mem: *const MemoryInst, addr: u32, offset: u32, size: u64) ExecError!usize {
    const ea = @as(u64, addr) + offset;
    if (ea + size > mem.bytes.len) return s.trap("out of bounds memory access");
    return @intCast(ea);
}

// IEEE roundTiesToEven via the 2^52/2^23 add-subtract trick (valid in the
// default to-nearest-even rounding mode), with a sign fix for zero results
// (nearest(-0.5) is -0.0, not +0.0).
fn nearestF32(x: f32) f32 {
    const ax = @abs(x);
    if (!(ax < 8388608.0)) return x; // NaN, Inf, or already integral
    const m = std.math.copysign(@as(f32, 8388608.0), x);
    const r = (x + m) - m;
    return if (r == 0) std.math.copysign(@as(f32, 0.0), x) else r;
}

fn nearestF64(x: f64) f64 {
    const ax = @abs(x);
    if (!(ax < 4503599627370496.0)) return x; // NaN, Inf, or already integral
    const m = std.math.copysign(@as(f64, 4503599627370496.0), x);
    const r = (x + m) - m;
    return if (r == 0) std.math.copysign(@as(f64, 0.0), x) else r;
}

// fmin/fmax per the spec pseudo-code: NaN propagates; min(-0,+0) = -0,
// max(-0,+0) = +0.
fn fminF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

fn fmaxF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) b else a;
    return if (a > b) a else b;
}

fn fminF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

fn fmaxF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == b) return if (std.math.signbit(a)) b else a;
    return if (a > b) a else b;
}

// Truncations: range-check BEFORE @intFromFloat (which is UB out of range).
fn truncI32S(s: *State, x: anytype) ExecError!i32 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    const ok = if (@TypeOf(x) == f32)
        x >= -2147483648.0 and x < 2147483648.0
    else
        x > -2147483649.0 and x < 2147483648.0;
    if (ok) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncI32U(s: *State, x: anytype) ExecError!u32 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    if (x > -1.0 and x < 4294967296.0) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncI64S(s: *State, x: anytype) ExecError!i64 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    if (x >= -0x1p63 and x < 0x1p63) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncI64U(s: *State, x: anytype) ExecError!u64 {
    if (std.math.isNan(x)) return s.trap("invalid conversion to integer");
    if (x > -1.0 and x < 0x1p64) return @intFromFloat(x);
    return s.trap("integer overflow");
}

fn truncSatI32S(x: anytype) i32 {
    if (std.math.isNan(x)) return 0;
    if (x >= 2147483648.0) return std.math.maxInt(i32);
    const lower = if (@TypeOf(x) == f32) -2147483648.0 else -2147483649.0;
    if (x <= lower) return std.math.minInt(i32);
    return @intFromFloat(x);
}

fn truncSatI32U(x: anytype) u32 {
    if (std.math.isNan(x) or x <= -1.0) return 0;
    if (x >= 4294967296.0) return std.math.maxInt(u32);
    return @intFromFloat(x);
}

fn truncSatI64S(x: anytype) i64 {
    if (std.math.isNan(x)) return 0;
    if (x <= -0x1p63) return std.math.minInt(i64);
    if (x >= 0x1p63) return std.math.maxInt(i64);
    return @intFromFloat(x);
}

fn truncSatI64U(x: anytype) u64 {
    if (std.math.isNan(x) or x <= -1.0) return 0;
    if (x >= 0x1p64) return std.math.maxInt(u64);
    return @intFromFloat(x);
}

fn execute(s: *State, entry: *const FuncInst, args: []const ValueSlot, results: []ValueSlot) ExecError!void {
    for (args) |slot| try pushSlot(s, slot);
    try pushFrame(s, entry);
    while (s.frames.items.len > 0) {
        const fr = &s.frames.items[s.frames.items.len - 1];
        const inst = fr.func.defined.inst;
        const mod = inst.module;
        const instr = mod.code[fr.func.defined.idx].instrs[fr.pc];
        fr.pc += 1;
        switch (instr.op) {
            .unreachable_ => return s.trap("unreachable"),
            .nop => {},
            .block => try s.labels.append(s.alloc, .{
                .target_pc = instr.imm.block.end_pc,
                .stack_height = s.stack.items.len - instr.imm.block.type.funcType(mod).?.params.len,
                .arity = instr.imm.block.type.funcType(mod).?.results.len,
                .is_loop = false,
            }),
            .loop => try s.labels.append(s.alloc, .{
                .target_pc = instr.imm.block.else_pc,
                .stack_height = s.stack.items.len - instr.imm.block.type.funcType(mod).?.params.len,
                .arity = instr.imm.block.type.funcType(mod).?.params.len,
                .is_loop = true,
            }),
            .if_ => {
                const b = instr.imm.block;
                if (popI32(s) != 0) {
                    try s.labels.append(s.alloc, .{
                        .target_pc = b.end_pc,
                        .stack_height = s.stack.items.len - b.type.funcType(mod).?.params.len,
                        .arity = b.type.funcType(mod).?.results.len,
                        .is_loop = false,
                    });
                } else if (b.else_pc == b.end_pc) {
                    fr.pc = b.end_pc; // no else arm: skip the whole if
                } else {
                    try s.labels.append(s.alloc, .{
                        .target_pc = b.end_pc,
                        .stack_height = s.stack.items.len - b.type.funcType(mod).?.params.len,
                        .arity = b.type.funcType(mod).?.results.len,
                        .is_loop = false,
                    });
                    fr.pc = b.else_pc;
                }
            },
            .else_ => {
                // The if-arm completed: discard its label, jump past `end`.
                s.labels.items.len -= 1;
                fr.pc = instr.imm.block.end_pc;
            },
            .end => {
                s.labels.items.len -= 1;
                if (s.labels.items.len == fr.label_base) returnFrame(s);
            },
            .br => branchTo(s, instr.imm.idx),
            .br_if => {
                if (popI32(s) != 0) branchTo(s, instr.imm.idx);
            },
            .br_table => {
                const i = popI32(s);
                const bt = instr.imm.br_table;
                branchTo(s, if (i < bt.targets.len) bt.targets[i] else bt.default);
            },
            .return_ => branchTo(s, @intCast(s.labels.items.len - 1 - fr.label_base)),
            .call => try callFunc(s, inst.funcs[instr.imm.idx]),
            .call_indirect => {
                const i = popI32(s);
                const immediate = instr.imm.call_indirect;
                const tab = inst.tables[immediate.table_index];
                tab.lockTable();
                const in_bounds = i < tab.elems.len;
                const target = if (in_bounds) funcFromSlot(tab.elems[i]) else null;
                tab.unlockTable();
                if (!in_bounds) return s.trap("undefined element");
                const callable = target orelse return s.trap("uninitialized element");
                const actual: types.FuncType = switch (callable.*) {
                    .defined => |d| d.inst.module.funcType(d.inst.module.imported_funcs + d.idx),
                    .imported => |im| im.type,
                };
                if (!types.funcTypeEql(mod.types[immediate.type_index], actual))
                    return s.trap("indirect call type mismatch");
                try callFunc(s, callable);
            },
            .drop => _ = popSlot(s),
            .select, .typed_select => {
                const c = popI32(s);
                const v2 = popSlot(s);
                const v1 = popSlot(s);
                try pushSlot(s, if (c != 0) v1 else v2);
            },
            .local_get => try pushSlot(s, s.locals.items[fr.locals_base + instr.imm.idx]),
            .local_set => s.locals.items[fr.locals_base + instr.imm.idx] = popSlot(s),
            .local_tee => s.locals.items[fr.locals_base + instr.imm.idx] = s.stack.items[s.stack.items.len - 1],
            .global_get => try pushSlot(s, inst.globals[instr.imm.idx].value),
            .global_set => setGlobalValue(inst.globals[instr.imm.idx], popSlot(s)),
            .table_get => {
                const index = popI32(s);
                const table = inst.tables[instr.imm.idx];
                table.lockTable();
                const in_bounds = index < table.elems.len;
                const table_entry = if (in_bounds) table.elems[index] else nullTableSlot(table.type);
                table.unlockTable();
                if (!in_bounds) return s.trap("undefined element");
                try pushSlot(s, table_entry);
            },
            .table_set => {
                const slot = popSlot(s);
                const index = popI32(s);
                const table = inst.tables[instr.imm.idx];
                table.lockTable();
                defer table.unlockTable();
                if (index >= table.elems.len) return s.trap("undefined element");
                table.elems[index] = slot;
            },
            .ref_null => try pushSlot(s, switch (instr.imm.type) {
                .funcref => .{ .funcref = null },
                .externref => .{ .externref = js_value.Value.nul() },
                else => unreachable,
            }),
            .ref_is_null => {
                const slot = popSlot(s);
                try pushBool(s, switch (slot) {
                    .funcref => |func| func == null,
                    .externref => |ref| ref.isNull(),
                    .numeric => unreachable,
                });
            },
            .ref_func => try pushSlot(s, .{ .funcref = @ptrCast(inst.funcs[instr.imm.idx]) }),
            .table_grow => {
                const delta = popI32(s);
                const slot = popSlot(s);
                try pushI32(s, @bitCast(tableGrowWith(inst.tables[instr.imm.idx], delta, slot)));
            },
            .table_size => {
                const table = inst.tables[instr.imm.idx];
                table.lockTable();
                const len: u32 = @intCast(table.elems.len);
                table.unlockTable();
                try pushI32(s, len);
            },
            .table_fill => {
                const count = popI32(s);
                const slot = popSlot(s);
                const start = popI32(s);
                const table = inst.tables[instr.imm.idx];
                table.lockTable();
                defer table.unlockTable();
                const end = @as(u64, start) + count;
                if (end > table.elems.len) return s.trap("out of bounds table access");
                @memset(table.elems[start..@intCast(end)], slot);
            },
            .i32_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                try pushI32(s, std.mem.readInt(u32, mem.bytes[ea..][0..4], .little));
            },
            .i64_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 8);
                try pushI64(s, std.mem.readInt(u64, mem.bytes[ea..][0..8], .little));
            },
            .f32_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                try push(s, std.mem.readInt(u32, mem.bytes[ea..][0..4], .little));
            },
            .f64_load => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 8);
                try push(s, std.mem.readInt(u64, mem.bytes[ea..][0..8], .little));
            },
            .i32_load8_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 1);
                try pushI32(s, @bitCast(@as(i32, @as(i8, @bitCast(mem.bytes[ea])))));
            },
            .i32_load8_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 1);
                try pushI32(s, mem.bytes[ea]);
            },
            .i32_load16_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 2);
                try pushI32(s, @bitCast(@as(i32, std.mem.readInt(i16, mem.bytes[ea..][0..2], .little))));
            },
            .i32_load16_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 2);
                try pushI32(s, std.mem.readInt(u16, mem.bytes[ea..][0..2], .little));
            },
            .i64_load8_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 1);
                try pushI64(s, @bitCast(@as(i64, @as(i8, @bitCast(mem.bytes[ea])))));
            },
            .i64_load8_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 1);
                try pushI64(s, mem.bytes[ea]);
            },
            .i64_load16_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 2);
                try pushI64(s, @bitCast(@as(i64, std.mem.readInt(i16, mem.bytes[ea..][0..2], .little))));
            },
            .i64_load16_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 2);
                try pushI64(s, std.mem.readInt(u16, mem.bytes[ea..][0..2], .little));
            },
            .i64_load32_s => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                try pushI64(s, @bitCast(@as(i64, std.mem.readInt(i32, mem.bytes[ea..][0..4], .little))));
            },
            .i64_load32_u => {
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                try pushI64(s, std.mem.readInt(u32, mem.bytes[ea..][0..4], .little));
            },
            .i32_store => {
                const v = popI32(s);
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                std.mem.writeInt(u32, mem.bytes[ea..][0..4], v, .little);
            },
            .i64_store => {
                const v = pop(s);
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 8);
                std.mem.writeInt(u64, mem.bytes[ea..][0..8], v, .little);
            },
            .f32_store => {
                const v = @as(u32, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                std.mem.writeInt(u32, mem.bytes[ea..][0..4], v, .little);
            },
            .f64_store => {
                const v = pop(s);
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 8);
                std.mem.writeInt(u64, mem.bytes[ea..][0..8], v, .little);
            },
            .i32_store8 => {
                const v = @as(u8, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 1);
                mem.bytes[ea] = v;
            },
            .i32_store16 => {
                const v = @as(u16, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 2);
                std.mem.writeInt(u16, mem.bytes[ea..][0..2], v, .little);
            },
            .i64_store8 => {
                const v = @as(u8, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 1);
                mem.bytes[ea] = v;
            },
            .i64_store16 => {
                const v = @as(u16, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 2);
                std.mem.writeInt(u16, mem.bytes[ea..][0..2], v, .little);
            },
            .i64_store32 => {
                const v = @as(u32, @truncate(pop(s)));
                const m = instr.imm.memarg;
                const mem = inst.mems[0];
                const ea = try effAddr(s, mem, popI32(s), m.offset, 4);
                std.mem.writeInt(u32, mem.bytes[ea..][0..4], v, .little);
            },
            .memory_size => try pushI32(s, inst.mems[0].pages()),
            .memory_grow => {
                const delta = popI32(s);
                checkpoint(s);
                const r = memoryGrow(inst.mems[0], delta);
                try pushI32(s, @bitCast(r));
            },
            .i32_const => try pushI32(s, @bitCast(instr.imm.i32)),
            .i64_const => try pushI64(s, @bitCast(instr.imm.i64)),
            .f32_const => try push(s, instr.imm.f32),
            .f64_const => try push(s, instr.imm.f64),
            .i32_eqz => try pushBool(s, popI32(s) == 0),
            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => {
                const bu = popI32(s);
                const au = popI32(s);
                const a: i32 = @bitCast(au);
                const b: i32 = @bitCast(bu);
                try pushBool(s, switch (instr.op) {
                    .i32_eq => au == bu,
                    .i32_ne => au != bu,
                    .i32_lt_s => a < b,
                    .i32_lt_u => au < bu,
                    .i32_gt_s => a > b,
                    .i32_gt_u => au > bu,
                    .i32_le_s => a <= b,
                    .i32_le_u => au <= bu,
                    .i32_ge_s => a >= b,
                    .i32_ge_u => au >= bu,
                    else => unreachable,
                });
            },
            .i64_eqz => try pushBool(s, pop(s) == 0),
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => {
                const bu = pop(s);
                const au = pop(s);
                const a: i64 = @bitCast(au);
                const b: i64 = @bitCast(bu);
                try pushBool(s, switch (instr.op) {
                    .i64_eq => au == bu,
                    .i64_ne => au != bu,
                    .i64_lt_s => a < b,
                    .i64_lt_u => au < bu,
                    .i64_gt_s => a > b,
                    .i64_gt_u => au > bu,
                    .i64_le_s => a <= b,
                    .i64_le_u => au <= bu,
                    .i64_ge_s => a >= b,
                    .i64_ge_u => au >= bu,
                    else => unreachable,
                });
            },
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => {
                const b = popF32(s);
                const a = popF32(s);
                try pushBool(s, switch (instr.op) {
                    .f32_eq => a == b,
                    .f32_ne => a != b,
                    .f32_lt => a < b,
                    .f32_gt => a > b,
                    .f32_le => a <= b,
                    .f32_ge => a >= b,
                    else => unreachable,
                });
            },
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => {
                const b = popF64(s);
                const a = popF64(s);
                try pushBool(s, switch (instr.op) {
                    .f64_eq => a == b,
                    .f64_ne => a != b,
                    .f64_lt => a < b,
                    .f64_gt => a > b,
                    .f64_le => a <= b,
                    .f64_ge => a >= b,
                    else => unreachable,
                });
            },
            .i32_clz => try pushI32(s, @clz(popI32(s))),
            .i32_ctz => try pushI32(s, @ctz(popI32(s))),
            .i32_popcnt => try pushI32(s, @popCount(popI32(s))),
            .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => {
                const bu = popI32(s);
                const au = popI32(s);
                const a: i32 = @bitCast(au);
                const b: i32 = @bitCast(bu);
                const r: u32 = switch (instr.op) {
                    .i32_add => au +% bu,
                    .i32_sub => au -% bu,
                    .i32_mul => au *% bu,
                    .i32_div_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i32) and b == -1) return s.trap("integer overflow");
                        break :blk @bitCast(@divTrunc(a, b));
                    },
                    .i32_div_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @divTrunc(au, bu);
                    },
                    .i32_rem_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i32) and b == -1) break :blk 0;
                        break :blk @bitCast(@rem(a, b));
                    },
                    .i32_rem_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @rem(au, bu);
                    },
                    .i32_and => au & bu,
                    .i32_or => au | bu,
                    .i32_xor => au ^ bu,
                    .i32_shl => au << @as(u5, @truncate(bu)),
                    .i32_shr_s => @bitCast(a >> @as(u5, @truncate(bu))),
                    .i32_shr_u => au >> @as(u5, @truncate(bu)),
                    .i32_rotl => std.math.rotl(u32, au, bu),
                    .i32_rotr => std.math.rotr(u32, au, bu),
                    else => unreachable,
                };
                try pushI32(s, r);
            },
            .i64_clz => try pushI64(s, @clz(pop(s))),
            .i64_ctz => try pushI64(s, @ctz(pop(s))),
            .i64_popcnt => try pushI64(s, @popCount(pop(s))),
            .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => {
                const bu = pop(s);
                const au = pop(s);
                const a: i64 = @bitCast(au);
                const b: i64 = @bitCast(bu);
                const r: u64 = switch (instr.op) {
                    .i64_add => au +% bu,
                    .i64_sub => au -% bu,
                    .i64_mul => au *% bu,
                    .i64_div_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i64) and b == -1) return s.trap("integer overflow");
                        break :blk @bitCast(@divTrunc(a, b));
                    },
                    .i64_div_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @divTrunc(au, bu);
                    },
                    .i64_rem_s => blk: {
                        if (b == 0) return s.trap("integer divide by zero");
                        if (a == std.math.minInt(i64) and b == -1) break :blk 0;
                        break :blk @bitCast(@rem(a, b));
                    },
                    .i64_rem_u => blk: {
                        if (bu == 0) return s.trap("integer divide by zero");
                        break :blk @rem(au, bu);
                    },
                    .i64_and => au & bu,
                    .i64_or => au | bu,
                    .i64_xor => au ^ bu,
                    .i64_shl => au << @as(u6, @truncate(bu)),
                    .i64_shr_s => @bitCast(a >> @as(u6, @truncate(bu))),
                    .i64_shr_u => au >> @as(u6, @truncate(bu)),
                    .i64_rotl => std.math.rotl(u64, au, bu),
                    .i64_rotr => std.math.rotr(u64, au, bu),
                    else => unreachable,
                };
                try pushI64(s, r);
            },
            .f32_abs => try push(s, pop(s) & 0x7FFF_FFFF),
            .f32_neg => try push(s, pop(s) ^ 0x8000_0000),
            .f32_ceil => try pushF32(s, @ceil(popF32(s))),
            .f32_floor => try pushF32(s, @floor(popF32(s))),
            .f32_trunc => try pushF32(s, @trunc(popF32(s))),
            .f32_nearest => try pushF32(s, nearestF32(popF32(s))),
            .f32_sqrt => try pushF32(s, @sqrt(popF32(s))),
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max => {
                const b = popF32(s);
                const a = popF32(s);
                try pushF32(s, switch (instr.op) {
                    .f32_add => a + b,
                    .f32_sub => a - b,
                    .f32_mul => a * b,
                    .f32_div => a / b,
                    .f32_min => fminF32(a, b),
                    .f32_max => fmaxF32(a, b),
                    else => unreachable,
                });
            },
            .f32_copysign => {
                const b = pop(s);
                const a = pop(s);
                try push(s, (a & 0x7FFF_FFFF) | (b & 0x8000_0000));
            },
            .f64_abs => try push(s, pop(s) & 0x7FFF_FFFF_FFFF_FFFF),
            .f64_neg => try push(s, pop(s) ^ 0x8000_0000_0000_0000),
            .f64_ceil => try pushF64(s, @ceil(popF64(s))),
            .f64_floor => try pushF64(s, @floor(popF64(s))),
            .f64_trunc => try pushF64(s, @trunc(popF64(s))),
            .f64_nearest => try pushF64(s, nearestF64(popF64(s))),
            .f64_sqrt => try pushF64(s, @sqrt(popF64(s))),
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max => {
                const b = popF64(s);
                const a = popF64(s);
                try pushF64(s, switch (instr.op) {
                    .f64_add => a + b,
                    .f64_sub => a - b,
                    .f64_mul => a * b,
                    .f64_div => a / b,
                    .f64_min => fminF64(a, b),
                    .f64_max => fmaxF64(a, b),
                    else => unreachable,
                });
            },
            .f64_copysign => {
                const b = pop(s);
                const a = pop(s);
                try push(s, (a & 0x7FFF_FFFF_FFFF_FFFF) | (b & 0x8000_0000_0000_0000));
            },
            .i32_wrap_i64 => try pushI32(s, @truncate(pop(s))),
            .i32_trunc_f32_s => try pushI32(s, @bitCast(try truncI32S(s, popF32(s)))),
            .i32_trunc_f32_u => try pushI32(s, try truncI32U(s, popF32(s))),
            .i32_trunc_f64_s => try pushI32(s, @bitCast(try truncI32S(s, popF64(s)))),
            .i32_trunc_f64_u => try pushI32(s, try truncI32U(s, popF64(s))),
            .i64_extend_i32_s => try pushI64(s, @bitCast(@as(i64, @as(i32, @bitCast(popI32(s)))))),
            .i64_extend_i32_u => try pushI64(s, popI32(s)),
            .i64_trunc_f32_s => try pushI64(s, @bitCast(try truncI64S(s, popF32(s)))),
            .i64_trunc_f32_u => try pushI64(s, try truncI64U(s, popF32(s))),
            .i64_trunc_f64_s => try pushI64(s, @bitCast(try truncI64S(s, popF64(s)))),
            .i64_trunc_f64_u => try pushI64(s, try truncI64U(s, popF64(s))),
            .f32_convert_i32_s => try pushF32(s, @floatFromInt(@as(i32, @bitCast(popI32(s))))),
            .f32_convert_i32_u => try pushF32(s, @floatFromInt(popI32(s))),
            .f32_convert_i64_s => try pushF32(s, @floatFromInt(@as(i64, @bitCast(pop(s))))),
            .f32_convert_i64_u => try pushF32(s, @floatFromInt(pop(s))),
            .f32_demote_f64 => try pushF32(s, @floatCast(popF64(s))),
            .f64_convert_i32_s => try pushF64(s, @floatFromInt(@as(i32, @bitCast(popI32(s))))),
            .f64_convert_i32_u => try pushF64(s, @floatFromInt(popI32(s))),
            .f64_convert_i64_s => try pushF64(s, @floatFromInt(@as(i64, @bitCast(pop(s))))),
            .f64_convert_i64_u => try pushF64(s, @floatFromInt(pop(s))),
            .f64_promote_f32 => try pushF64(s, @floatCast(popF32(s))),
            .i32_reinterpret_f32 => try pushI32(s, @bitCast(popF32(s))),
            .i64_reinterpret_f64 => try pushI64(s, @bitCast(popF64(s))),
            .f32_reinterpret_i32 => try pushF32(s, @bitCast(popI32(s))),
            .f64_reinterpret_i64 => try pushF64(s, @bitCast(pop(s))),
            .i32_extend8_s => {
                const value: i8 = @bitCast(@as(u8, @truncate(popI32(s))));
                try pushI32(s, @bitCast(@as(i32, value)));
            },
            .i32_extend16_s => {
                const value: i16 = @bitCast(@as(u16, @truncate(popI32(s))));
                try pushI32(s, @bitCast(@as(i32, value)));
            },
            .i64_extend8_s => {
                const value: i8 = @bitCast(@as(u8, @truncate(pop(s))));
                try pushI64(s, @bitCast(@as(i64, value)));
            },
            .i64_extend16_s => {
                const value: i16 = @bitCast(@as(u16, @truncate(pop(s))));
                try pushI64(s, @bitCast(@as(i64, value)));
            },
            .i64_extend32_s => {
                const value: i32 = @bitCast(@as(u32, @truncate(pop(s))));
                try pushI64(s, @bitCast(@as(i64, value)));
            },
            .i32_trunc_sat_f32_s => try pushI32(s, @bitCast(truncSatI32S(popF32(s)))),
            .i32_trunc_sat_f32_u => try pushI32(s, truncSatI32U(popF32(s))),
            .i32_trunc_sat_f64_s => try pushI32(s, @bitCast(truncSatI32S(popF64(s)))),
            .i32_trunc_sat_f64_u => try pushI32(s, truncSatI32U(popF64(s))),
            .i64_trunc_sat_f32_s => try pushI64(s, @bitCast(truncSatI64S(popF32(s)))),
            .i64_trunc_sat_f32_u => try pushI64(s, truncSatI64U(popF32(s))),
            .i64_trunc_sat_f64_s => try pushI64(s, @bitCast(truncSatI64S(popF64(s)))),
            .i64_trunc_sat_f64_u => try pushI64(s, truncSatI64U(popF64(s))),
        }
    }
    @memcpy(results, s.stack.items[s.stack.items.len - results.len ..]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const hdr = "\x00asm\x01\x00\x00\x00";
const talloc = std.testing.allocator;

const I32 = "\x7F";
const I64 = "\x7E";
const F32 = "\x7D";
const F64 = "\x7C";

const f32nan: u64 = 0x7FC00000;
const f64nan: u64 = 0x7FF8000000000000;

const RootHookProbe = struct {
    enters: usize = 0,
    leaves: usize = 0,
    checkpoints: usize = 0,

    fn enter(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) error{OutOfMemory}!void {
        const self: *RootHookProbe = @ptrCast(@alignCast(raw));
        self.enters += 1;
        std.debug.assert(roots.stack.len == 0 and roots.locals.len == 0);
    }

    fn leave(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *RootHookProbe = @ptrCast(@alignCast(raw));
        self.leaves += 1;
        std.debug.assert(roots.stack.len <= MAX_OPERAND_SLOTS);
    }

    fn checkpoint(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *RootHookProbe = @ptrCast(@alignCast(raw));
        self.checkpoints += 1;
        std.debug.assert(roots.stack.len <= MAX_OPERAND_SLOTS);
    }
};

fn rejectNumericReferenceCall(_: *anyopaque, _: []const u64, _: []u64, _: *types.Diagnostic) error{ Trap, Host }!void {
    return error.Trap;
}

fn echoReferenceSlot(_: *anyopaque, args: []const ValueSlot, results: []ValueSlot, _: *types.Diagnostic) error{ Trap, Host }!void {
    results[0] = args[0];
}

fn recordGlobalBarrier(raw: *anyopaque, slot: ValueSlot) void {
    const count: *usize = @ptrCast(@alignCast(raw));
    if (slot == .externref) count.* += 1;
}

const RootLivenessProbe = struct {
    externrefs: [4]usize = .{ 0, 0, 0, 0 },
    len: usize = 0,

    fn enter(_: *anyopaque, _: *js_value.WasmExecutionRoots) error{OutOfMemory}!void {}
    fn leave(_: *anyopaque, _: *js_value.WasmExecutionRoots) void {}
    fn checkpoint(raw: *anyopaque, roots: *js_value.WasmExecutionRoots) void {
        const self: *RootLivenessProbe = @ptrCast(@alignCast(raw));
        var count: usize = 0;
        for (roots.stack) |slot| if (slot == .externref) {
            count += 1;
        };
        for (roots.locals) |slot| if (slot == .externref) {
            count += 1;
        };
        self.externrefs[self.len] = count;
        self.len += 1;
    }
};

fn leb(comptime v: u64) []const u8 {
    comptime {
        var buf: []const u8 = &.{};
        var x = v;
        while (true) {
            var b: u8 = @truncate(x);
            x >>= 7;
            if (x != 0) b |= 0x80;
            buf = buf ++ &[_]u8{b};
            if (x == 0) break;
        }
        return buf;
    }
}

fn sleb(comptime v: i64) []const u8 {
    comptime {
        var buf: []const u8 = &.{};
        var x = v;
        while (true) {
            const b: u8 = @truncate(@as(u64, @bitCast(x)) & 0x7F);
            x >>= 7;
            const sign = (b & 0x40) != 0;
            if ((x == 0 and !sign) or (x == -1 and sign)) {
                buf = buf ++ &[_]u8{b};
                break;
            }
            buf = buf ++ &[_]u8{b | 0x80};
        }
        return buf;
    }
}

fn sec(comptime id: u8, comptime payload: []const u8) []const u8 {
    comptime return &[_]u8{id} ++ leb(payload.len) ++ payload;
}

fn ft(comptime params: []const u8, comptime results: []const u8) []const u8 {
    comptime return "\x60" ++ leb(params.len) ++ params ++ leb(results.len) ++ results;
}

fn ob(comptime op: types.Op) []const u8 {
    comptime {
        const raw = @intFromEnum(op);
        if (raw <= 0xFF) return &[_]u8{@intCast(raw)};
        std.debug.assert(raw >> 8 == 0xFC);
        return "\xFC" ++ leb(raw & 0xFF);
    }
}

fn typesSec(comptime defs: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(defs.len);
        for (defs) |d| payload = payload ++ d;
        return sec(1, payload);
    }
}

fn funcSec(comptime type_indices: []const u32) []const u8 {
    comptime {
        var payload: []const u8 = leb(type_indices.len);
        for (type_indices) |t| payload = payload ++ leb(t);
        return sec(3, payload);
    }
}

fn codeSec(comptime bodies: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(bodies.len);
        for (bodies) |b| {
            const full = "\x00" ++ b ++ "\x0B";
            payload = payload ++ leb(full.len) ++ full;
        }
        return sec(10, payload);
    }
}

fn codeSecL(comptime locals_decl: []const u8, comptime body: []const u8) []const u8 {
    comptime {
        const full = locals_decl ++ body ++ "\x0B";
        return sec(10, leb(1) ++ leb(full.len) ++ full);
    }
}

fn memSec(comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return sec(5, "\x01\x01" ++ leb(min) ++ leb(m));
        return sec(5, "\x01\x00" ++ leb(min));
    }
}

fn tableSec(comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return sec(4, "\x01\x70\x01" ++ leb(min) ++ leb(m));
        return sec(4, "\x01\x70\x00" ++ leb(min));
    }
}

fn glob(comptime vt: []const u8, comptime mutable: bool, comptime init: []const u8) []const u8 {
    comptime return vt ++ &[_]u8{@intFromBool(mutable)} ++ init ++ "\x0B";
}

fn globalSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |e| payload = payload ++ e;
        return sec(6, payload);
    }
}

fn i32c(comptime v: i32) []const u8 {
    comptime return "\x41" ++ sleb(v);
}

fn i64c(comptime v: i64) []const u8 {
    comptime return "\x42" ++ sleb(v);
}

fn f32c(comptime v: f32) []const u8 {
    comptime {
        const b: u32 = @bitCast(v);
        return "\x43" ++ &[_]u8{ @truncate(b), @truncate(b >> 8), @truncate(b >> 16), @truncate(b >> 24) };
    }
}

fn f64c(comptime v: f64) []const u8 {
    comptime {
        const b: u64 = @bitCast(v);
        return "\x44" ++ &[_]u8{
            @truncate(b),       @truncate(b >> 8),  @truncate(b >> 16), @truncate(b >> 24),
            @truncate(b >> 32), @truncate(b >> 40), @truncate(b >> 48), @truncate(b >> 56),
        };
    }
}

fn impName(comptime module: []const u8, comptime name: []const u8) []const u8 {
    comptime return leb(module.len) ++ module ++ leb(name.len) ++ name;
}

fn impFunc(comptime module: []const u8, comptime name: []const u8, comptime typeidx: u32) []const u8 {
    comptime return impName(module, name) ++ "\x00" ++ leb(typeidx);
}

fn impTable(comptime module: []const u8, comptime name: []const u8, comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return impName(module, name) ++ "\x01\x70\x01" ++ leb(min) ++ leb(m);
        return impName(module, name) ++ "\x01\x70\x00" ++ leb(min);
    }
}

fn impMem(comptime module: []const u8, comptime name: []const u8, comptime min: u32, comptime max: ?u32) []const u8 {
    comptime {
        if (max) |m| return impName(module, name) ++ "\x02\x01" ++ leb(min) ++ leb(m);
        return impName(module, name) ++ "\x02\x00" ++ leb(min);
    }
}

fn impGlobal(comptime module: []const u8, comptime name: []const u8, comptime vt: []const u8, comptime mutable: bool) []const u8 {
    comptime return impName(module, name) ++ "\x03" ++ vt ++ &[_]u8{@intFromBool(mutable)};
}

fn importSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |e| payload = payload ++ e;
        return sec(2, payload);
    }
}

fn elemSec0(comptime offset: i32, comptime funcs: []const u32) []const u8 {
    comptime {
        return sec(9, "\x01" ++ elemEntry0(offset, funcs));
    }
}

fn dataSec0(comptime offset: i32, comptime bytes: []const u8) []const u8 {
    comptime return sec(11, "\x01" ++ dataEntry0(offset, bytes));
}

fn elemEntry0(comptime offset: i32, comptime funcs: []const u32) []const u8 {
    comptime {
        var encoded: []const u8 = &.{};
        for (funcs) |index| encoded = encoded ++ leb(index);
        return "\x00" ++ i32c(offset) ++ "\x0B" ++ leb(funcs.len) ++ encoded;
    }
}

fn elemSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |entry| payload = payload ++ entry;
        return sec(9, payload);
    }
}

fn dataEntry0(comptime offset: i32, comptime bytes: []const u8) []const u8 {
    comptime return "\x00" ++ i32c(offset) ++ "\x0B" ++ leb(bytes.len) ++ bytes;
}

fn dataSec(comptime entries: []const []const u8) []const u8 {
    comptime {
        var payload: []const u8 = leb(entries.len);
        for (entries) |entry| payload = payload ++ entry;
        return sec(11, payload);
    }
}

fn startSec(comptime funcidx: u32) []const u8 {
    comptime return sec(8, leb(funcidx));
}

fn arithModule(comptime params: []const u8, comptime results: []const u8, comptime body: []const u8) []const u8 {
    comptime return hdr ++ typesSec(&.{ft(params, results)}) ++ funcSec(&.{0}) ++ codeSec(&.{body});
}

// Value bit-pattern helpers.
fn i32v(comptime v: i32) u64 {
    return @as(u32, @bitCast(v));
}

fn i64v(comptime v: i64) u64 {
    return @bitCast(v);
}

fn f32v(comptime v: f32) u64 {
    return @as(u32, @bitCast(v));
}

fn f64v(comptime v: f64) u64 {
    return @bitCast(v);
}

fn bitsToF32(v: u64) f32 {
    return @bitCast(@as(u32, @truncate(v)));
}

fn bitsToF64(v: u64) f64 {
    return @bitCast(v);
}

// Module / instance lifecycle helpers.
fn buildModule(bytes: []const u8, diag: *types.Diagnostic) !*types.Module {
    return buildModuleWithFeatures(bytes, .{}, diag);
}

fn buildModuleWithFeatures(bytes: []const u8, features: types.Features, diag: *types.Diagnostic) !*types.Module {
    const mod = try decode.decodeWithFeatures(talloc, bytes, features, diag);
    errdefer decode.destroyModule(talloc, mod);
    try validate.validate(mod, diag);
    return mod;
}

const Built = struct { mod: *types.Module, inst: *Instance };

fn build(comptime bytes: []const u8) !Built {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(bytes, &diag);
    errdefer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    return .{ .mod = mod, .inst = inst };
}

fn destroyBuilt(b: Built) void {
    destroyInstance(talloc, b.inst);
    decode.destroyModule(talloc, b.mod);
}

fn expectResults(comptime bytes: []const u8, funcidx: u32, args: []const u64, expected: []const u64) !void {
    return expectResultsWithFeatures(bytes, .{}, funcidx, args, expected);
}

fn expectResultsWithFeatures(comptime bytes: []const u8, features: types.Features, funcidx: u32, args: []const u64, expected: []const u64) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, features, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    const res = try talloc.alloc(u64, expected.len);
    defer talloc.free(res);
    try invoke(inst, funcidx, args, res, &diag);
    try std.testing.expectEqualSlices(u64, expected, res);
}

fn expectTrap(comptime bytes: []const u8, comptime nres: usize, funcidx: u32, args: []const u64, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    var res: [nres]u64 = undefined;
    try std.testing.expectError(error.Trap, invoke(inst, funcidx, args, &res, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
}

fn expectLink(comptime bytes: []const u8, imports: Imports, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    if (instantiate(talloc, mod, imports, &diag)) |inst| {
        destroyInstance(talloc, inst);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.Link, err);
        try std.testing.expectEqualStrings(msg, diag.message());
    }
}

fn binop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, b: u64, expected: u64) !void {
    const bytes = comptime arithModule(pt ++ pt, rt, "\x20\x00\x20\x01" ++ ob(op));
    try expectResults(bytes, 0, &.{ a, b }, &.{expected});
}

fn binopTrap(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, b: u64, msg: []const u8) !void {
    const bytes = comptime arithModule(pt ++ pt, rt, "\x20\x00\x20\x01" ++ ob(op));
    try expectTrap(bytes, 1, 0, &.{ a, b }, msg);
}

fn unop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, expected: u64) !void {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    try expectResults(bytes, 0, &.{a}, &.{expected});
}

fn unopWithFeatures(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, features: types.Features, a: u64, expected: u64) !void {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    try expectResultsWithFeatures(bytes, features, 0, &.{a}, &.{expected});
}

fn unopTrap(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, msg: []const u8) !void {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    try expectTrap(bytes, 1, 0, &.{a}, msg);
}

fn runBinop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64, b: u64) !u64 {
    const bytes = comptime arithModule(pt ++ pt, rt, "\x20\x00\x20\x01" ++ ob(op));
    var diag: types.Diagnostic = .{};
    const bld = try build(bytes);
    defer destroyBuilt(bld);
    var res: [1]u64 = .{0};
    try invoke(bld.inst, 0, &.{ a, b }, &res, &diag);
    return res[0];
}

fn runUnop(comptime op: types.Op, comptime pt: []const u8, comptime rt: []const u8, a: u64) !u64 {
    const bytes = comptime arithModule(pt, rt, "\x20\x00" ++ ob(op));
    var diag: types.Diagnostic = .{};
    const bld = try build(bytes);
    defer destroyBuilt(bld);
    var res: [1]u64 = .{0};
    try invoke(bld.inst, 0, &.{a}, &res, &diag);
    return res[0];
}

fn run1(inst: *Instance, funcidx: u32, args: []const u64) !u64 {
    var diag: types.Diagnostic = .{};
    var res: [1]u64 = .{0};
    try invoke(inst, funcidx, args, &res, &diag);
    return res[0];
}

fn run0(inst: *Instance, funcidx: u32, args: []const u64) !void {
    var diag: types.Diagnostic = .{};
    try invoke(inst, funcidx, args, &.{}, &diag);
}

fn runTrap(comptime nres: usize, inst: *Instance, funcidx: u32, args: []const u64, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    var res: [nres]u64 = undefined;
    try std.testing.expectError(error.Trap, invoke(inst, funcidx, args, &res, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
}

// -- Host-side constructors --------------------------------------------------

test "wasm.exec host constructors memory table global" {
    const mem = try createMemory(talloc, 1, 2);
    defer destroyMemory(talloc, mem);
    try std.testing.expectEqual(@as(usize, types.PAGE_SIZE), mem.bytes.len);
    try std.testing.expectEqual(@as(u8, 0), mem.bytes[123]);
    try std.testing.expectEqual(@as(u32, 1), mem.pages());
    try std.testing.expectEqual(@as(i32, 1), memoryGrow(mem, 1));
    try std.testing.expectEqual(@as(usize, 2 * types.PAGE_SIZE), mem.bytes.len);
    try std.testing.expectEqual(@as(u8, 0), mem.bytes[types.PAGE_SIZE + 5]);
    try std.testing.expectEqual(@as(i32, -1), memoryGrow(mem, 1)); // at max
    try std.testing.expectEqual(@as(i32, 2), memoryGrow(mem, 0));
    try std.testing.expectEqual(@as(i32, -1), memoryGrow(mem, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(usize, 2 * types.PAGE_SIZE), mem.bytes.len); // unchanged

    const tab = try createTable(talloc, 2, 3);
    defer destroyTable(talloc, tab);
    try std.testing.expectEqual(@as(usize, 2), tab.elems.len);
    try std.testing.expect(tab.elems[0] == .funcref and tab.elems[0].funcref == null);
    try std.testing.expectEqual(@as(i32, 2), tableGrow(tab, 1));
    try std.testing.expect(tab.elems[2] == .funcref and tab.elems[2].funcref == null);
    try std.testing.expectEqual(@as(i32, -1), tableGrow(tab, 1)); // at max
    try std.testing.expectEqual(@as(i32, 3), tableGrow(tab, 0));

    const g = try createGlobal(talloc, .{ .val = .i64, .mutable = true }, 0xDEADBEEF);
    defer destroyGlobal(talloc, g);
    try std.testing.expectEqual(types.GlobalType{ .val = .i64, .mutable = true }, g.type);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), g.value.numericBits());
    setGlobalValue(g, .{ .numeric = 7 });
    try std.testing.expectEqual(@as(u64, 7), g.value.numericBits());
}

// -- Instantiation: import resolution ----------------------------------------

const one_func_import = hdr ++ typesSec(&.{ft(I32, I32)}) ++ importSec(&.{impFunc("a", "f", 0)});

test "wasm.exec instantiate import count mismatch" {
    try expectLink(one_func_import, .{}, "inconsistent import count");
    var dummy: u8 = 0;
    const imf: ImportFunc = .{
        .ctx = @ptrCast(&dummy),
        .type = .{ .params = &.{.i32}, .results = &.{.i32} },
        .call = struct {
            fn f(ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
                _ = ctx;
                _ = args;
                _ = results;
                _ = diag;
            }
        }.f,
    };
    // Two provided for one declared is still an inconsistent count.
    try expectLink(one_func_import, .{ .funcs = &.{ imf, imf } }, "inconsistent import count");
}

test "wasm.exec instantiate incompatible table limits" {
    const mod_bytes = comptime (hdr ++ importSec(&.{impTable("a", "t", 2, null)}));
    const too_small = try createTable(talloc, 1, null);
    defer destroyTable(talloc, too_small);
    try expectLink(mod_bytes, .{ .tables = &.{too_small} }, "incompatible import type");
    const mod_max = comptime (hdr ++ importSec(&.{impTable("a", "t", 1, 2)}));
    const no_max = try createTable(talloc, 1, null);
    defer destroyTable(talloc, no_max);
    try expectLink(mod_max, .{ .tables = &.{no_max} }, "incompatible import type");
    const big_max = try createTable(talloc, 1, 3);
    defer destroyTable(talloc, big_max);
    try expectLink(mod_max, .{ .tables = &.{big_max} }, "incompatible import type");
}

test "wasm.exec instantiate incompatible memory limits" {
    const mod_min = comptime (hdr ++ importSec(&.{impMem("a", "m", 2, null)}));
    const too_small = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, too_small);
    try expectLink(mod_min, .{ .mems = &.{too_small} }, "incompatible import type");
    const mod_max = comptime (hdr ++ importSec(&.{impMem("a", "m", 1, 2)}));
    const no_max = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, no_max);
    try expectLink(mod_max, .{ .mems = &.{no_max} }, "incompatible import type");
    const big_max = try createMemory(talloc, 1, 3);
    defer destroyMemory(talloc, big_max);
    try expectLink(mod_max, .{ .mems = &.{big_max} }, "incompatible import type");
}

test "wasm.exec instantiate compatible larger imports succeed" {
    var diag: types.Diagnostic = .{};
    const mod_bytes = comptime (hdr ++ importSec(&.{ impTable("a", "t", 1, 3), impMem("a", "m", 1, 2) }));
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const tab = try createTable(talloc, 2, 3); // min 2 >= 1, max 3 <= 3
    defer destroyTable(talloc, tab);
    const mem = try createMemory(talloc, 2, 2); // min 2 >= 1, max 2 <= 2
    defer destroyMemory(talloc, mem);
    const inst = try instantiate(talloc, mod, .{ .tables = &.{tab}, .mems = &.{mem} }, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(tab, inst.tables[0]);
    try std.testing.expectEqual(mem, inst.mems[0]);
}

test "wasm.exec instantiate incompatible global type" {
    const mod_bytes = comptime (hdr ++ importSec(&.{impGlobal("a", "g", I32, false)}));
    const wrong_mut = try createGlobal(talloc, .{ .val = .i32, .mutable = true }, 0);
    defer destroyGlobal(talloc, wrong_mut);
    try expectLink(mod_bytes, .{ .globals = &.{wrong_mut} }, "incompatible import type");
    const wrong_val = try createGlobal(talloc, .{ .val = .i64, .mutable = false }, 0);
    defer destroyGlobal(talloc, wrong_val);
    try expectLink(mod_bytes, .{ .globals = &.{wrong_val} }, "incompatible import type");
}

var host_state: u32 = 0;

fn hostDouble(ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
    _ = ctx;
    _ = diag;
    results[0] = args[0] *% 2;
}

const double_import: ImportFunc = .{
    .ctx = @ptrCast(&host_state),
    .type = .{ .params = &.{.i32}, .results = &.{.i32} },
    .call = hostDouble,
};

// Kitchen sink: one import of each kind plus a defined func using them, an
// elem into the imported table, and a data segment into the imported memory.
const ks2_bytes = hdr ++
    typesSec(&.{ ft(I32, I32), ft(I32, I32) }) ++
    importSec(&.{ impFunc("a", "f", 0), impTable("a", "t", 1, null), impMem("a", "m", 1, null), impGlobal("a", "g", I32, false) }) ++
    funcSec(&.{1}) ++
    elemSec0(0, &.{1}) ++
    codeSec(&.{"\x20\x00\x10\x00\x23\x00\x6A"}) ++
    dataSec0(2, "Z");

test "wasm.exec instantiate resolves all import kinds" {
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(ks2_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const tab = try createTable(talloc, 1, null);
    defer destroyTable(talloc, tab);
    const mem = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, mem);
    const glob_inst = try createGlobal(talloc, .{ .val = .i32, .mutable = false }, 100);
    defer destroyGlobal(talloc, glob_inst);
    const inst = try instantiate(talloc, mod, .{
        .funcs = &.{double_import},
        .tables = &.{tab},
        .mems = &.{mem},
        .globals = &.{glob_inst},
    }, &diag);
    defer destroyInstance(talloc, inst);

    // Index spaces: imports first.
    try std.testing.expectEqual(@as(usize, 2), inst.funcs.len);
    try std.testing.expect(inst.funcs[0].* == .imported);
    try std.testing.expect(inst.funcs[1].* == .defined);
    try std.testing.expectEqual(tab, inst.tables[0]);
    try std.testing.expectEqual(mem, inst.mems[0]);
    try std.testing.expectEqual(glob_inst, inst.globals[0]);

    // Defined func: double(param) + imported global.
    try std.testing.expectEqual(@as(u64, 110), try run1(inst, 1, &.{5}));

    // Elem wrote the defined func into the imported table.
    try std.testing.expect(tab.elems[0] == .funcref);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(inst.funcs[1])), tab.elems[0].funcref.?);

    // Data wrote into the imported memory.
    try std.testing.expectEqual(@as(u8, 'Z'), mem.bytes[2]);

    // Imported FuncInst is directly callable through callFuncInst.
    var diag2: types.Diagnostic = .{};
    var res: [1]u64 = .{0};
    try callFuncInst(inst.funcs[0], &.{21}, &res, &diag2);
    try std.testing.expectEqual(@as(u64, 42), res[0]);
}

// -- Instantiation: globals, elems, datas, start ------------------------------

test "wasm.exec instantiate global initializers" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft("", I32), ft("", I64), ft("", F32), ft("", F64) }) ++
        funcSec(&.{ 0, 1, 2, 3 }) ++
        globalSec(&.{ glob(I32, true, i32c(42)), glob(I64, false, i64c(-7)), glob(F32, false, f32c(1.5)), glob(F64, true, f64c(-2.5)) }) ++
        codeSec(&.{ "\x23\x00", "\x23\x01", "\x23\x02", "\x23\x03" }));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(usize, 4), b.inst.globals.len);
    try std.testing.expectEqual(i32v(42), b.inst.globals[0].value.numericBits());
    try std.testing.expectEqual(i64v(-7), b.inst.globals[1].value.numericBits());
    try std.testing.expectEqual(f32v(1.5), b.inst.globals[2].value.numericBits());
    try std.testing.expectEqual(f64v(-2.5), b.inst.globals[3].value.numericBits());
    try std.testing.expectEqual(i32v(42), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(i64v(-7), try run1(b.inst, 1, &.{}));
    try std.testing.expectEqual(f32v(1.5), try run1(b.inst, 2, &.{}));
    try std.testing.expectEqual(f64v(-2.5), try run1(b.inst, 3, &.{}));
}

test "wasm.exec instantiate global init referencing imported global" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ft("", I32)}) ++
        importSec(&.{impGlobal("a", "g", I32, false)}) ++
        funcSec(&.{0}) ++
        globalSec(&.{glob(I32, false, "\x23\x00")}) ++
        codeSec(&.{"\x23\x01"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const imported = try createGlobal(talloc, .{ .val = .i32, .mutable = false }, 99);
    defer destroyGlobal(talloc, imported);
    const inst = try instantiate(talloc, mod, .{ .globals = &.{imported} }, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(@as(u64, 99), inst.globals[1].value.numericBits());
    try std.testing.expectEqual(@as(u64, 99), try run1(inst, 0, &.{}));
}

test "wasm.exec instantiate elem out of bounds is a link error" {
    const base = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++ tableSec(2, null));
    try expectLink(comptime (base ++ elemSec0(2, &.{0}) ++ codeSec(&.{""})), .{}, "out of bounds table index");
    try expectLink(comptime (base ++ elemSec0(1, &.{ 0, 0 }) ++ codeSec(&.{""})), .{}, "out of bounds table index");
}

test "wasm.exec instantiate data out of bounds is a link error" {
    const base = comptime (hdr ++ memSec(1, null));
    try expectLink(comptime (base ++ dataSec0(65535, "AB")), .{}, "out of bounds memory index");
    try expectLink(comptime (base ++ dataSec0(65536, "A")), .{}, "out of bounds memory index");
}

test "wasm.exec instantiate data at exact end succeeds" {
    const b = try build(hdr ++ memSec(1, null) ++ dataSec0(65535, "Q"));
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u8, 'Q'), b.inst.mems[0].bytes[65535]);
    // An empty segment at the exact end is in bounds.
    const b2 = try build(hdr ++ memSec(1, null) ++ dataSec0(65536, ""));
    defer destroyBuilt(b2);
}

test "wasm.exec link failure applies no earlier active segments" {
    var diag: types.Diagnostic = .{};
    const memory_module = try buildModule(comptime (hdr ++
        importSec(&.{impMem("a", "m", 1, null)}) ++
        dataSec(&.{ dataEntry0(0, "abc"), dataEntry0(65536, "x") })), &diag);
    defer decode.destroyModule(talloc, memory_module);
    const memory = try createMemory(talloc, 1, null);
    defer destroyMemory(talloc, memory);
    try std.testing.expectError(error.Link, instantiate(talloc, memory_module, .{ .mems = &.{memory} }, &diag));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, memory.bytes[0..3]);

    diag = .{};
    const table_module = try buildModule(comptime (hdr ++
        typesSec(&.{ft("", "")}) ++
        importSec(&.{impTable("a", "t", 1, null)}) ++
        funcSec(&.{0}) ++
        elemSec(&.{ elemEntry0(0, &.{0}), elemEntry0(1, &.{0}) }) ++
        codeSec(&.{""})), &diag);
    defer decode.destroyModule(talloc, table_module);
    const table = try createTable(talloc, 1, null);
    defer destroyTable(talloc, table);
    try std.testing.expectError(error.Link, instantiate(talloc, table_module, .{ .tables = &.{table} }, &diag));
    try std.testing.expect(table.elems[0] == .funcref and table.elems[0].funcref == null);
}

fn hostInc(ctx: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
    _ = args;
    _ = results;
    _ = diag;
    const c: *u32 = @ptrCast(@alignCast(ctx));
    c.* += 1;
}

test "wasm.exec instantiate start function runs" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ft("", "")}) ++
        importSec(&.{impFunc("a", "f", 0)}) ++
        funcSec(&.{0}) ++
        startSec(1) ++
        codeSec(&.{"\x10\x00"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    var counter: u32 = 0;
    const inc_import: ImportFunc = .{
        .ctx = @ptrCast(&counter),
        .type = .{ .params = &.{}, .results = &.{} },
        .call = hostInc,
    };
    const inst = try instantiate(talloc, mod, .{ .funcs = &.{inc_import} }, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "wasm.exec instantiate start trap propagates" {
    const mod_bytes = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++ startSec(0) ++ codeSec(&.{"\x00"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    try std.testing.expectError(error.Trap, instantiate(talloc, mod, .{}, &diag));
    try std.testing.expectEqualStrings("unreachable", diag.message());
}

// -- invoke: value types and reentrancy ---------------------------------------

test "wasm.exec invoke passes all value types bit-exact" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, I32), ft(I64, I64), ft(F32, F32), ft(F64, F64) }) ++
        funcSec(&.{ 0, 1, 2, 3 }) ++
        codeSec(&.{ "\x20\x00", "\x20\x00", "\x20\x00", "\x20\x00" }));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), try run1(b.inst, 0, &.{0xDEADBEEF}));
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF_CAFEBABE), try run1(b.inst, 1, &.{0xDEADBEEF_CAFEBABE}));
    try std.testing.expectEqual(@as(u64, 0x7FC00001), try run1(b.inst, 2, &.{0x7FC00001})); // NaN payload preserved
    try std.testing.expectEqual(@as(u64, 0x80000000), try run1(b.inst, 2, &.{0x80000000})); // -0.0 f32
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), try run1(b.inst, 3, &.{0x8000000000000000})); // -0.0 f64
}

const ReentCtx = struct {
    inst_b: *Instance,
    funcidx_b: u32,
};

fn hostReenter(ctx_raw: *anyopaque, args: []const u64, results: []u64, diag: *types.Diagnostic) error{ Trap, Host }!void {
    const ctx: *ReentCtx = @ptrCast(@alignCast(ctx_raw));
    var inner: types.Diagnostic = .{};
    invoke(ctx.inst_b, ctx.funcidx_b, args, results, &inner) catch |e| switch (e) {
        error.Trap => {
            diag.set(types.Diagnostic.no_offset, "{s}", .{inner.message()});
            return error.Trap;
        },
        error.OutOfMemory, error.Host => return error.Host,
    };
}

test "wasm.exec invoke reentrancy through host import" {
    // Module B: func 0 = x + 10.
    const b_bytes = comptime (hdr ++ typesSec(&.{ft(I32, I32)}) ++ funcSec(&.{0}) ++ codeSec(&.{"\x20\x00" ++ i32c(10) ++ "\x6A"}));
    const b = try build(b_bytes);
    defer destroyBuilt(b);

    // Module A: import "a"."f"; func 1 = f(x) + 1, where f re-enters B.
    const a_bytes = comptime (hdr ++
        typesSec(&.{ft(I32, I32)}) ++
        importSec(&.{impFunc("a", "f", 0)}) ++
        funcSec(&.{0}) ++
        codeSec(&.{"\x20\x00\x10\x00" ++ i32c(1) ++ "\x6A"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(a_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    var ctx: ReentCtx = .{ .inst_b = b.inst, .funcidx_b = 0 };
    const reent: ImportFunc = .{
        .ctx = @ptrCast(&ctx),
        .type = .{ .params = &.{.i32}, .results = &.{.i32} },
        .call = hostReenter,
    };
    const inst_a = try instantiate(talloc, mod, .{ .funcs = &.{reent} }, &diag);
    defer destroyInstance(talloc, inst_a);
    try std.testing.expectEqual(@as(u64, 16), try run1(inst_a, 1, &.{5}));
}

// -- Control flow ---------------------------------------------------------------

test "wasm.exec control nested blocks br with value" {
    const body = comptime ("\x02\x7F" ++ // block $a (result i32)
        "\x02\x40" ++ //   block $b
        "\x02\x40" ++ //     block $c
        i32c(7) ++ "\x0C\x02" ++ // i32.const 7; br 2 ($a)
        "\x0B" ++ //   end $c
        "\x0B" ++ //   end $b
        i32c(9) ++ //   unreachable const
        "\x0B"); // end $a
    try expectResults(comptime arithModule("", I32, body), 0, &.{}, &.{7});
}

test "wasm.exec control loop sum 1 to 10" {
    const body = comptime (i32c(10) ++ "\x21\x01" ++ // i = 10 (local 1)
        "\x03\x40" ++ // loop
        "\x20\x00\x20\x01\x6A\x21\x00" ++ // sum += i
        "\x20\x01" ++ i32c(1) ++ "\x6B\x22\x01" ++ // i -= 1 (tee)
        "\x0D\x00" ++ // br_if loop
        "\x0B" ++ // end loop
        "\x20\x00"); // sum
    const bytes = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ codeSecL("\x01\x02\x7F", body));
    try expectResults(bytes, 0, &.{}, &.{55});
}

test "wasm.exec control if else both arms" {
    const body = comptime ("\x20\x00\x04\x7F" ++ i32c(1) ++ "\x05" ++ i32c(2) ++ "\x0B");
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{1}, &.{1});
    try expectResults(bytes, 0, &.{0}, &.{2});
}

test "wasm.exec control if without else" {
    // (param i32) (result i32): if (empty) nop end; i32.const 7
    const body = comptime ("\x20\x00\x04\x40\x01\x0B" ++ i32c(7));
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{1}, &.{7});
    try expectResults(bytes, 0, &.{0}, &.{7});
}

test "wasm.exec control br_table dispatch" {
    // Targets are empty-arity blocks; each landing pad pushes its own value
    // and branches to the result-valued outer block.
    const body = comptime ("\x02\x7F" ++ // block $a (result i32)
        "\x02\x40" ++ //   block $d
        "\x02\x40" ++ //     block $b
        "\x02\x40" ++ //       block $c
        "\x20\x00" ++ "\x0E\x02\x00\x01\x02" ++ // local.get 0; br_table 0 1, default 2
        "\x0B" ++ //       end $c
        i32c(10) ++ "\x0C\x02" ++ // case 0 -> 10 (br $a)
        "\x0B" ++ //     end $b
        i32c(20) ++ "\x0C\x01" ++ // case 1 -> 20 (br $a)
        "\x0B" ++ //   end $d
        i32c(30) ++ // default -> 30 (falls into end $a)
        "\x0B"); // end $a
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{0}, &.{10});
    try expectResults(bytes, 0, &.{1}, &.{20});
    try expectResults(bytes, 0, &.{2}, &.{30});
    try expectResults(bytes, 0, &.{99}, &.{30});
}

test "wasm.exec control return mid function" {
    const body = comptime (i32c(42) ++ "\x0F" ++ i32c(0));
    try expectResults(comptime arithModule("", I32, body), 0, &.{}, &.{42});
}

test "wasm.exec control br_if not taken" {
    const body = comptime ("\x02\x7F" ++ // block (result i32)
        i32c(5) ++ "\x20\x00\x0D\x00" ++ "\x1A" ++ // const 5; br_if 0 (cond); drop
        i32c(6) ++ "\x0B");
    const bytes = comptime arithModule(I32, I32, body);
    try expectResults(bytes, 0, &.{1}, &.{5});
    try expectResults(bytes, 0, &.{0}, &.{6});
}

// -- Parametric ------------------------------------------------------------------

test "wasm.exec parametric drop and select" {
    try expectResults(comptime arithModule("", I32, i32c(5) ++ i32c(6) ++ "\x1A"), 0, &.{}, &.{5});
    const sel = "\x20\x00\x20\x01\x20\x02\x1B";
    const bytes = comptime arithModule(I32 ++ I32 ++ I32, I32, sel);
    try expectResults(bytes, 0, &.{ 11, 22, 1 }, &.{11});
    try expectResults(bytes, 0, &.{ 11, 22, 0 }, &.{22});
}

test "wasm.exec unreachable traps" {
    try expectTrap(comptime arithModule("", "", "\x00"), 0, 0, &.{}, "unreachable");
}

// -- i32 numerics ----------------------------------------------------------------

test "wasm.exec i32 arithmetic binops" {
    try binop(.i32_add, I32, I32, 1, 2, 3);
    try binop(.i32_add, I32, I32, 0xFFFFFFFF, 1, 0);
    try binop(.i32_add, I32, I32, 0x7FFFFFFF, 1, 0x80000000);
    try binop(.i32_sub, I32, I32, 3, 5, i32v(-2));
    try binop(.i32_sub, I32, I32, 0, 1, 0xFFFFFFFF);
    try binop(.i32_mul, I32, I32, 7, 6, 42);
    try binop(.i32_mul, I32, I32, 0x10000, 0x10000, 0);
    try binop(.i32_and, I32, I32, 0xFF00FF00, 0x0FF00FF0, 0x0F000F00);
    try binop(.i32_or, I32, I32, 0xFF00FF00, 0x0FF00FF0, 0xFFF0FFF0);
    try binop(.i32_xor, I32, I32, 0xFF00FF00, 0x0FF00FF0, 0xF0F0F0F0);
}

test "wasm.exec i32 div and rem" {
    try binop(.i32_div_s, I32, I32, 7, 2, 3);
    try binop(.i32_div_s, I32, I32, i32v(-7), 2, i32v(-3));
    try binop(.i32_div_s, I32, I32, 7, i32v(-2), i32v(-3));
    try binop(.i32_div_s, I32, I32, i32v(-7), i32v(-2), 3);
    try binop(.i32_div_s, I32, I32, i32v(std.math.minInt(i32)), 1, i32v(std.math.minInt(i32)));
    try binop(.i32_div_u, I32, I32, 7, 2, 3);
    try binop(.i32_div_u, I32, I32, 0xFFFFFFFF, 2, 0x7FFFFFFF);
    try binop(.i32_rem_s, I32, I32, 7, 2, 1);
    try binop(.i32_rem_s, I32, I32, i32v(-7), 2, i32v(-1)); // sign follows dividend
    try binop(.i32_rem_s, I32, I32, 7, i32v(-2), 1);
    try binop(.i32_rem_s, I32, I32, i32v(-7), i32v(-2), i32v(-1));
    try binop(.i32_rem_s, I32, I32, i32v(std.math.minInt(i32)), i32v(-1), 0); // no trap
    try binop(.i32_rem_u, I32, I32, 7, 2, 1);
    try binop(.i32_rem_u, I32, I32, 0xFFFFFFFF, 2, 1);
}

test "wasm.exec i32 div and rem traps" {
    try binopTrap(.i32_div_s, I32, I32, 1, 0, "integer divide by zero");
    try binopTrap(.i32_div_s, I32, I32, i32v(std.math.minInt(i32)), i32v(-1), "integer overflow");
    try binopTrap(.i32_div_u, I32, I32, 1, 0, "integer divide by zero");
    try binopTrap(.i32_rem_s, I32, I32, 5, 0, "integer divide by zero");
    try binopTrap(.i32_rem_u, I32, I32, 5, 0, "integer divide by zero");
}

test "wasm.exec i32 shifts and rotates" {
    try binop(.i32_shl, I32, I32, 1, 31, 0x80000000);
    try binop(.i32_shl, I32, I32, 1, 33, 2); // count masked mod 32
    try binop(.i32_shl, I32, I32, 0xFFFFFFFF, 37, 0xFFFFFFE0);
    try binop(.i32_shr_s, I32, I32, 0x80000000, 31, 0xFFFFFFFF);
    try binop(.i32_shr_s, I32, I32, 0x80000000, 33, 0xC0000000);
    try binop(.i32_shr_u, I32, I32, 0x80000000, 31, 1);
    try binop(.i32_shr_u, I32, I32, 0x80000000, 33, 0x40000000);
    try binop(.i32_rotl, I32, I32, 0x12345678, 8, 0x34567812);
    try binop(.i32_rotl, I32, I32, 0x12345678, 40, 0x34567812);
    try binop(.i32_rotr, I32, I32, 0x12345678, 8, 0x78123456);
    try binop(.i32_rotr, I32, I32, 0x12345678, 40, 0x78123456);
}

test "wasm.exec i32 clz ctz popcnt" {
    try unop(.i32_clz, I32, I32, 0, 32);
    try unop(.i32_clz, I32, I32, 1, 31);
    try unop(.i32_clz, I32, I32, 0x80000000, 0);
    try unop(.i32_clz, I32, I32, 0x00F00000, 8);
    try unop(.i32_ctz, I32, I32, 0, 32);
    try unop(.i32_ctz, I32, I32, 0x80000000, 31);
    try unop(.i32_ctz, I32, I32, 1, 0);
    try unop(.i32_ctz, I32, I32, 0x00F00000, 20);
    try unop(.i32_popcnt, I32, I32, 0, 0);
    try unop(.i32_popcnt, I32, I32, 0xFFFFFFFF, 32);
    try unop(.i32_popcnt, I32, I32, 0x55555555, 16);
}

test "wasm.exec i32 comparisons" {
    try unop(.i32_eqz, I32, I32, 0, 1);
    try unop(.i32_eqz, I32, I32, 42, 0);
    try binop(.i32_eq, I32, I32, 5, 5, 1);
    try binop(.i32_eq, I32, I32, 5, 6, 0);
    try binop(.i32_ne, I32, I32, 5, 6, 1);
    try binop(.i32_lt_s, I32, I32, i32v(-1), 1, 1);
    try binop(.i32_lt_s, I32, I32, 1, i32v(-1), 0);
    try binop(.i32_lt_u, I32, I32, 0xFFFFFFFF, 1, 0);
    try binop(.i32_lt_u, I32, I32, 1, 2, 1);
    try binop(.i32_gt_s, I32, I32, 1, i32v(-1), 1);
    try binop(.i32_gt_u, I32, I32, 0xFFFFFFFF, 1, 1);
    try binop(.i32_le_s, I32, I32, i32v(-1), i32v(-1), 1);
    try binop(.i32_le_u, I32, I32, 1, 1, 1);
    try binop(.i32_ge_s, I32, I32, 0, i32v(-1), 1);
    try binop(.i32_ge_u, I32, I32, 1, 0, 1);
}

// -- i64 numerics ----------------------------------------------------------------

test "wasm.exec i64 arithmetic binops" {
    try binop(.i64_add, I64, I64, 1, 2, 3);
    try binop(.i64_add, I64, I64, 0xFFFFFFFFFFFFFFFF, 1, 0);
    try binop(.i64_sub, I64, I64, 0, 1, 0xFFFFFFFFFFFFFFFF);
    try binop(.i64_mul, I64, I64, 0x100000000, 0x100000000, 0);
    try binop(.i64_and, I64, I64, 0xFF00FF00FF00FF00, 0x0FF00FF00FF00FF0, 0x0F000F000F000F00);
    try binop(.i64_or, I64, I64, 0xFF00FF00FF00FF00, 0x0FF00FF00FF00FF0, 0xFFF0FFF0FFF0FFF0);
    try binop(.i64_xor, I64, I64, 0xFF00FF00FF00FF00, 0x0FF00FF00FF00FF0, 0xF0F0F0F0F0F0F0F0);
}

test "wasm.exec i64 div and rem" {
    try binop(.i64_div_s, I64, I64, i64v(-7), 2, i64v(-3));
    try binop(.i64_div_s, I64, I64, 7, i64v(-2), i64v(-3));
    try binop(.i64_div_s, I64, I64, i64v(-7), i64v(-2), 3);
    try binop(.i64_div_u, I64, I64, 0xFFFFFFFFFFFFFFFF, 2, 0x7FFFFFFFFFFFFFFF);
    try binop(.i64_rem_s, I64, I64, i64v(-7), 2, i64v(-1));
    try binop(.i64_rem_s, I64, I64, 7, i64v(-2), 1);
    try binop(.i64_rem_s, I64, I64, i64v(std.math.minInt(i64)), i64v(-1), 0); // no trap
    try binop(.i64_rem_u, I64, I64, 7, 2, 1);
}

test "wasm.exec i64 div and rem traps" {
    try binopTrap(.i64_div_s, I64, I64, 1, 0, "integer divide by zero");
    try binopTrap(.i64_div_s, I64, I64, i64v(std.math.minInt(i64)), i64v(-1), "integer overflow");
    try binopTrap(.i64_div_u, I64, I64, 1, 0, "integer divide by zero");
    try binopTrap(.i64_rem_s, I64, I64, 5, 0, "integer divide by zero");
    try binopTrap(.i64_rem_u, I64, I64, 5, 0, "integer divide by zero");
}

test "wasm.exec i64 shifts and rotates" {
    try binop(.i64_shl, I64, I64, 1, 63, 0x8000000000000000);
    try binop(.i64_shl, I64, I64, 1, 65, 2); // count masked mod 64
    try binop(.i64_shr_s, I64, I64, 0x8000000000000000, 63, 0xFFFFFFFFFFFFFFFF);
    try binop(.i64_shr_s, I64, I64, 0x8000000000000000, 65, 0xC000000000000000);
    try binop(.i64_shr_u, I64, I64, 0x8000000000000000, 63, 1);
    try binop(.i64_shr_u, I64, I64, 0x8000000000000000, 65, 0x4000000000000000);
    try binop(.i64_rotl, I64, I64, 0x123456789ABCDEF0, 16, 0x56789ABCDEF01234);
    try binop(.i64_rotl, I64, I64, 0x123456789ABCDEF0, 80, 0x56789ABCDEF01234);
    try binop(.i64_rotr, I64, I64, 0x123456789ABCDEF0, 16, 0xDEF0123456789ABC);
}

test "wasm.exec i64 clz ctz popcnt" {
    try unop(.i64_clz, I64, I64, 0, 64);
    try unop(.i64_clz, I64, I64, 1, 63);
    try unop(.i64_clz, I64, I64, 0x8000000000000000, 0);
    try unop(.i64_ctz, I64, I64, 0, 64);
    try unop(.i64_ctz, I64, I64, 0x8000000000000000, 63);
    try unop(.i64_popcnt, I64, I64, 0, 0);
    try unop(.i64_popcnt, I64, I64, 0xFFFFFFFFFFFFFFFF, 64);
    try unop(.i64_popcnt, I64, I64, 0x5555555555555555, 32);
}

test "wasm.exec i64 comparisons" {
    try unop(.i64_eqz, I64, I32, 0, 1);
    try unop(.i64_eqz, I64, I32, 7, 0);
    try binop(.i64_eq, I64, I32, 5, 5, 1);
    try binop(.i64_ne, I64, I32, 5, 6, 1);
    try binop(.i64_lt_s, I64, I32, i64v(-1), 1, 1);
    try binop(.i64_lt_u, I64, I32, 0xFFFFFFFFFFFFFFFF, 1, 0);
    try binop(.i64_gt_s, I64, I32, 1, i64v(-1), 1);
    try binop(.i64_gt_u, I64, I32, 0xFFFFFFFFFFFFFFFF, 1, 1);
    try binop(.i64_le_s, I64, I32, i64v(-1), i64v(-1), 1);
    try binop(.i64_le_u, I64, I32, 1, 1, 1);
    try binop(.i64_ge_s, I64, I32, 0, i64v(-1), 1);
    try binop(.i64_ge_u, I64, I32, 1, 0, 1);
}

// -- f32 numerics ----------------------------------------------------------------

test "wasm.exec f32 arithmetic" {
    try binop(.f32_add, F32, F32, f32v(1.5), f32v(2.25), f32v(3.75));
    try binop(.f32_add, F32, F32, f32v(0.1), f32v(0.2), f32v(@as(f32, 0.1) + @as(f32, 0.2)));
    try binop(.f32_sub, F32, F32, f32v(5.5), f32v(2.0), f32v(3.5));
    try binop(.f32_mul, F32, F32, f32v(1.5), f32v(4.0), f32v(6.0));
    try binop(.f32_div, F32, F32, f32v(7.0), f32v(2.0), f32v(3.5));
    try unop(.f32_abs, F32, F32, f32v(-1.5), f32v(1.5));
    try unop(.f32_abs, F32, F32, 0x80000000, 0); // abs(-0.0) = +0.0
    try unop(.f32_neg, F32, F32, f32v(1.5), f32v(-1.5));
    try unop(.f32_neg, F32, F32, 0, 0x80000000); // neg(+0.0) = -0.0
    try binop(.f32_copysign, F32, F32, f32v(1.5), f32v(-2.0), f32v(-1.5));
    try binop(.f32_copysign, F32, F32, f32v(1.5), 0x80000000, f32v(-1.5));
    try binop(.f32_copysign, F32, F32, f32v(-1.5), 0, f32v(1.5));
    try unop(.f32_sqrt, F32, F32, f32v(4.0), f32v(2.0));
    try unop(.f32_sqrt, F32, F32, f32v(2.0), f32v(@sqrt(@as(f32, 2.0))));
    try std.testing.expect(std.math.isNan(bitsToF32(try runUnop(.f32_sqrt, F32, F32, f32v(-1.0)))));
}

test "wasm.exec f32 ceil floor trunc" {
    try unop(.f32_ceil, F32, F32, f32v(1.5), f32v(2.0));
    try unop(.f32_ceil, F32, F32, f32v(-1.5), f32v(-1.0));
    try unop(.f32_ceil, F32, F32, f32v(1.0), f32v(1.0));
    try unop(.f32_floor, F32, F32, f32v(1.5), f32v(1.0));
    try unop(.f32_floor, F32, F32, f32v(-1.5), f32v(-2.0));
    try unop(.f32_trunc, F32, F32, f32v(1.5), f32v(1.0));
    try unop(.f32_trunc, F32, F32, f32v(-1.5), f32v(-1.0));
}

test "wasm.exec f32 nearest ties to even" {
    try unop(.f32_nearest, F32, F32, f32v(0.5), f32v(0.0));
    try unop(.f32_nearest, F32, F32, f32v(1.5), f32v(2.0));
    try unop(.f32_nearest, F32, F32, f32v(2.5), f32v(2.0));
    try unop(.f32_nearest, F32, F32, f32v(-2.5), f32v(-2.0));
    try unop(.f32_nearest, F32, F32, f32v(-0.5), 0x80000000); // -0.0
    try unop(.f32_nearest, F32, F32, f32v(3.5), f32v(4.0));
    try unop(.f32_nearest, F32, F32, f32v(8388607.5), f32v(8388608.0)); // largest non-integral f32
    try unop(.f32_nearest, F32, F32, f32v(-8388607.5), f32v(-8388608.0));
    try unop(.f32_nearest, F32, F32, f32v(16777216.0), f32v(16777216.0));
}

test "wasm.exec f32 min max nan and signed zero" {
    try binop(.f32_min, F32, F32, f32v(1.5), f32v(2.5), f32v(1.5));
    try binop(.f32_min, F32, F32, f32v(2.5), f32v(1.5), f32v(1.5));
    try binop(.f32_max, F32, F32, f32v(1.5), f32v(2.5), f32v(2.5));
    try binop(.f32_min, F32, F32, 0x80000000, 0, 0x80000000); // min(-0,+0) = -0
    try binop(.f32_min, F32, F32, 0, 0x80000000, 0x80000000);
    try binop(.f32_max, F32, F32, 0x80000000, 0, 0); // max(-0,+0) = +0
    try binop(.f32_max, F32, F32, 0, 0x80000000, 0);
    try std.testing.expect(std.math.isNan(bitsToF32(try runBinop(.f32_min, F32, F32, f32nan, f32v(1.0)))));
    try std.testing.expect(std.math.isNan(bitsToF32(try runBinop(.f32_min, F32, F32, f32v(1.0), f32nan))));
    try std.testing.expect(std.math.isNan(bitsToF32(try runBinop(.f32_max, F32, F32, f32nan, f32nan))));
}

test "wasm.exec f32 comparisons" {
    try binop(.f32_eq, F32, I32, f32v(1.5), f32v(1.5), 1);
    try binop(.f32_eq, F32, I32, f32nan, f32v(1.0), 0);
    try binop(.f32_eq, F32, I32, f32nan, f32nan, 0);
    try binop(.f32_eq, F32, I32, 0x80000000, 0, 1); // -0.0 == +0.0
    try binop(.f32_ne, F32, I32, f32nan, f32v(1.0), 1);
    try binop(.f32_ne, F32, I32, f32v(1.0), f32v(1.0), 0);
    try binop(.f32_lt, F32, I32, f32v(1.0), f32v(1.5), 1);
    try binop(.f32_lt, F32, I32, f32nan, f32v(1.0), 0);
    try binop(.f32_gt, F32, I32, f32v(1.5), f32v(1.0), 1);
    try binop(.f32_gt, F32, I32, f32v(1.0), f32nan, 0);
    try binop(.f32_le, F32, I32, f32v(1.5), f32v(1.5), 1);
    try binop(.f32_ge, F32, I32, f32v(1.5), f32v(1.5), 1);
    try binop(.f32_ge, F32, I32, f32v(1.0), f32v(1.5), 0);
}

// -- f64 numerics ----------------------------------------------------------------

test "wasm.exec f64 arithmetic" {
    try binop(.f64_add, F64, F64, f64v(1.5), f64v(2.25), f64v(3.75));
    try binop(.f64_add, F64, F64, f64v(0.1), f64v(0.2), f64v(@as(f64, 0.1) + @as(f64, 0.2)));
    try binop(.f64_sub, F64, F64, f64v(5.5), f64v(2.0), f64v(3.5));
    try binop(.f64_mul, F64, F64, f64v(1.5), f64v(4.0), f64v(6.0));
    try binop(.f64_div, F64, F64, f64v(7.0), f64v(2.0), f64v(3.5));
    try unop(.f64_abs, F64, F64, f64v(-1.5), f64v(1.5));
    try unop(.f64_abs, F64, F64, 0x8000000000000000, 0);
    try unop(.f64_neg, F64, F64, f64v(1.5), f64v(-1.5));
    try unop(.f64_neg, F64, F64, 0, 0x8000000000000000);
    try binop(.f64_copysign, F64, F64, f64v(1.5), f64v(-2.0), f64v(-1.5));
    try binop(.f64_copysign, F64, F64, f64v(1.5), 0x8000000000000000, f64v(-1.5));
    try unop(.f64_sqrt, F64, F64, f64v(4.0), f64v(2.0));
    try unop(.f64_sqrt, F64, F64, f64v(2.0), f64v(@sqrt(2.0)));
    try std.testing.expect(std.math.isNan(bitsToF64(try runUnop(.f64_sqrt, F64, F64, f64v(-1.0)))));
}

test "wasm.exec f64 ceil floor trunc" {
    try unop(.f64_ceil, F64, F64, f64v(1.5), f64v(2.0));
    try unop(.f64_ceil, F64, F64, f64v(-1.5), f64v(-1.0));
    try unop(.f64_floor, F64, F64, f64v(1.5), f64v(1.0));
    try unop(.f64_floor, F64, F64, f64v(-1.5), f64v(-2.0));
    try unop(.f64_trunc, F64, F64, f64v(1.5), f64v(1.0));
    try unop(.f64_trunc, F64, F64, f64v(-1.5), f64v(-1.0));
}

test "wasm.exec f64 nearest ties to even" {
    try unop(.f64_nearest, F64, F64, f64v(0.5), f64v(0.0));
    try unop(.f64_nearest, F64, F64, f64v(1.5), f64v(2.0));
    try unop(.f64_nearest, F64, F64, f64v(2.5), f64v(2.0));
    try unop(.f64_nearest, F64, F64, f64v(-2.5), f64v(-2.0));
    try unop(.f64_nearest, F64, F64, f64v(-0.5), 0x8000000000000000); // -0.0
    try unop(.f64_nearest, F64, F64, f64v(3.5), f64v(4.0));
    try unop(.f64_nearest, F64, F64, f64v(8388609.5), f64v(8388610.0));
    try unop(.f64_nearest, F64, F64, f64v(4503599627370495.5), f64v(4503599627370496.0)); // tie below 2^52
    try unop(.f64_nearest, F64, F64, f64v(9007199254740992.0), f64v(9007199254740992.0));
}

test "wasm.exec f64 min max nan and signed zero" {
    try binop(.f64_min, F64, F64, f64v(1.5), f64v(2.5), f64v(1.5));
    try binop(.f64_max, F64, F64, f64v(1.5), f64v(2.5), f64v(2.5));
    try binop(.f64_min, F64, F64, 0x8000000000000000, 0, 0x8000000000000000); // min(-0,+0) = -0
    try binop(.f64_max, F64, F64, 0x8000000000000000, 0, 0); // max(-0,+0) = +0
    try std.testing.expect(std.math.isNan(bitsToF64(try runBinop(.f64_min, F64, F64, f64nan, f64v(1.0)))));
    try std.testing.expect(std.math.isNan(bitsToF64(try runBinop(.f64_max, F64, F64, f64v(1.0), f64nan))));
}

test "wasm.exec f64 comparisons" {
    try binop(.f64_eq, F64, I32, f64v(1.5), f64v(1.5), 1);
    try binop(.f64_eq, F64, I32, f64nan, f64nan, 0);
    try binop(.f64_eq, F64, I32, 0x8000000000000000, 0, 1);
    try binop(.f64_ne, F64, I32, f64nan, f64v(1.0), 1);
    try binop(.f64_lt, F64, I32, f64v(1.0), f64v(1.5), 1);
    try binop(.f64_lt, F64, I32, f64v(1.0), f64nan, 0);
    try binop(.f64_gt, F64, I32, f64v(1.5), f64v(1.0), 1);
    try binop(.f64_le, F64, I32, f64v(1.5), f64v(1.5), 1);
    try binop(.f64_ge, F64, I32, f64v(1.0), f64v(1.5), 0);
}

// -- Conversions -----------------------------------------------------------------

test "wasm.exec conversions wrap and extend" {
    try unop(.i32_wrap_i64, I64, I32, 0x1_0000_0005, 5);
    try unop(.i32_wrap_i64, I64, I32, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF);
    try unop(.i64_extend_i32_s, I32, I64, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF);
    try unop(.i64_extend_i32_s, I32, I64, 0x7FFFFFFF, 0x7FFFFFFF);
    try unop(.i64_extend_i32_u, I32, I64, 0xFFFFFFFF, 0xFFFFFFFF);
    try unop(.i64_extend_i32_u, I32, I64, 0x80000000, 0x80000000);
}

test "wasm.exec sign-extension operations" {
    const features: types.Features = .{ .sign_extension_ops = true };
    try unopWithFeatures(.i32_extend8_s, I32, I32, features, 0x00000080, 0xFFFFFF80);
    try unopWithFeatures(.i32_extend8_s, I32, I32, features, 0xFFFFFF7F, 0x0000007F);
    try unopWithFeatures(.i32_extend16_s, I32, I32, features, 0x00008000, 0xFFFF8000);
    try unopWithFeatures(.i32_extend16_s, I32, I32, features, 0xFFFF7FFF, 0x00007FFF);
    try unopWithFeatures(.i64_extend8_s, I64, I64, features, 0x80, 0xFFFFFFFFFFFFFF80);
    try unopWithFeatures(.i64_extend16_s, I64, I64, features, 0x8000, 0xFFFFFFFFFFFF8000);
    try unopWithFeatures(.i64_extend32_s, I64, I64, features, 0x80000000, 0xFFFFFFFF80000000);
    try unopWithFeatures(.i64_extend32_s, I64, I64, features, 0xFFFFFFFF7FFFFFFF, 0x000000007FFFFFFF);
}

test "wasm.exec nontrapping float-to-integer conversions" {
    const features: types.Features = .{ .nontrapping_float_to_int = true };

    try unopWithFeatures(.i32_trunc_sat_f32_s, F32, I32, features, f32nan, 0);
    try unopWithFeatures(.i32_trunc_sat_f32_s, F32, I32, features, f32v(-1.9), i32v(-1));
    try unopWithFeatures(.i32_trunc_sat_f32_s, F32, I32, features, f32v(-std.math.inf(f32)), i32v(std.math.minInt(i32)));
    try unopWithFeatures(.i32_trunc_sat_f32_u, F32, I32, features, f32v(std.math.inf(f32)), std.math.maxInt(u32));

    try unopWithFeatures(.i32_trunc_sat_f64_s, F64, I32, features, f64v(-2147483648.9), i32v(std.math.minInt(i32)));
    try unopWithFeatures(.i32_trunc_sat_f64_s, F64, I32, features, f64v(2147483648.0), std.math.maxInt(i32));
    try unopWithFeatures(.i32_trunc_sat_f64_u, F64, I32, features, f64v(-0.9), 0);
    try unopWithFeatures(.i32_trunc_sat_f64_u, F64, I32, features, f64v(4294967296.0), std.math.maxInt(u32));

    try unopWithFeatures(.i64_trunc_sat_f32_s, F32, I64, features, f32v(-std.math.inf(f32)), i64v(std.math.minInt(i64)));
    try unopWithFeatures(.i64_trunc_sat_f32_u, F32, I64, features, f32v(std.math.inf(f32)), std.math.maxInt(u64));
    try unopWithFeatures(.i64_trunc_sat_f64_s, F64, I64, features, f64nan, 0);
    try unopWithFeatures(.i64_trunc_sat_f64_s, F64, I64, features, f64v(0x1p63), i64v(std.math.maxInt(i64)));
    try unopWithFeatures(.i64_trunc_sat_f64_u, F64, I64, features, f64v(-1.0), 0);
    try unopWithFeatures(.i64_trunc_sat_f64_u, F64, I64, features, f64v(0x1p64), std.math.maxInt(u64));
}

test "wasm.exec multi-value type-index block" {
    const bytes = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x0B");
    try expectResultsWithFeatures(bytes, .{ .multi_value = true }, 0, &.{}, &.{ 7, 9 });
}

test "wasm.exec multi-value loop carries parameters" {
    const body = "\x20\x00\x03\x00\x21\x00\x20\x00\x41\x01\x6B\x22\x00\x20\x00\x0D\x00\x0B";
    const bytes = comptime arithModule(I32, I32, body);
    try expectResultsWithFeatures(bytes, .{ .multi_value = true }, 0, &.{3}, &.{0});
}

test "wasm.exec multi-value branches calls and implicit else" {
    const features: types.Features = .{ .multi_value = true };

    const branch = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x0C\x00\x00\x0B");
    try expectResultsWithFeatures(branch, features, 0, &.{}, &.{ 7, 9 });

    const branch_if = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x41\x01\x0D\x00\x0B");
    try expectResultsWithFeatures(branch_if, features, 0, &.{}, &.{ 7, 9 });

    const branch_table = comptime arithModule("", I32 ++ I64, "\x02\x00\x41\x07\x42\x09\x41\x00\x0E\x01\x00\x00\x0B");
    try expectResultsWithFeatures(branch_table, features, 0, &.{}, &.{ 7, 9 });

    const implicit_else = comptime arithModule(I32, I32, "\x20\x00\x20\x00\x04\x00\x0B");
    try expectResultsWithFeatures(implicit_else, features, 0, &.{5}, &.{5});
    try expectResultsWithFeatures(implicit_else, features, 0, &.{0}, &.{0});

    const call = comptime (hdr ++ typesSec(&.{ft("", I32 ++ I64)}) ++ funcSec(&.{ 0, 0 }) ++
        codeSec(&.{ "\x41\x07\x42\x09", "\x10\x00" }));
    try expectResultsWithFeatures(call, features, 1, &.{}, &.{ 7, 9 });

    const return_ = comptime arithModule("", I32 ++ I64, "\x41\x07\x42\x09\x0F\x00");
    try expectResultsWithFeatures(return_, features, 0, &.{}, &.{ 7, 9 });
}

test "wasm.exec execution root hooks balance across checkpoints and traps" {
    const loop = comptime arithModule(I32, "", "\x03\x40\x20\x00\x41\x01\x6B\x22\x00\x0D\x00\x0B");
    var built = try build(loop);
    defer destroyBuilt(built);
    var probe: RootHookProbe = .{};
    built.inst.root_hooks = .{
        .ctx = @ptrCast(&probe),
        .enter = RootHookProbe.enter,
        .leave = RootHookProbe.leave,
        .checkpoint = RootHookProbe.checkpoint,
    };
    var diag: types.Diagnostic = .{};
    try invoke(built.inst, 0, &.{2}, &.{}, &diag);
    try std.testing.expectEqual(@as(usize, 1), probe.enters);
    try std.testing.expectEqual(@as(usize, 1), probe.leaves);
    try std.testing.expectEqual(@as(usize, 1), probe.checkpoints);

    const trap = comptime arithModule("", "", "\x00");
    var trapping = try build(trap);
    defer destroyBuilt(trapping);
    trapping.inst.root_hooks = built.inst.root_hooks;
    try std.testing.expectError(error.Trap, invoke(trapping.inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqual(@as(usize, 2), probe.enters);
    try std.testing.expectEqual(@as(usize, 2), probe.leaves);
}

test "wasm.exec typed invocation preserves references and rejects numeric aliases" {
    var diag: types.Diagnostic = .{};
    var object = js_value.Object{};
    const extern_import: FuncInst = .{ .imported = .{
        .ctx = @ptrCast(&object),
        .type = .{ .params = &.{.externref}, .results = &.{.externref} },
        .call = rejectNumericReferenceCall,
        .call_slots = echoReferenceSlot,
    } };
    var extern_result: [1]ValueSlot = undefined;
    try callFuncInstSlots(
        &extern_import,
        &.{.{ .externref = js_value.Value.obj(&object) }},
        &extern_result,
        &diag,
    );
    try std.testing.expect(extern_result[0] == .externref);
    try std.testing.expect(extern_result[0].externref.asObj() == &object);
    var raw_result: [1]u64 = undefined;
    try std.testing.expectError(
        error.Trap,
        callFuncInst(&extern_import, &.{@intFromPtr(&object)}, &raw_result, &diag),
    );
    try std.testing.expectEqualStrings("function signature mismatch", diag.message());

    var function_marker: u8 = 0;
    const funcref_import: FuncInst = .{ .imported = .{
        .ctx = @ptrCast(&function_marker),
        .type = .{ .params = &.{.funcref}, .results = &.{.funcref} },
        .call = rejectNumericReferenceCall,
        .call_slots = echoReferenceSlot,
    } };
    var funcref_result: [1]ValueSlot = undefined;
    try callFuncInstSlots(
        &funcref_import,
        &.{.{ .funcref = @ptrCast(&function_marker) }},
        &funcref_result,
        &diag,
    );
    try std.testing.expect(funcref_result[0] == .funcref);
    try std.testing.expect(funcref_result[0].funcref.? == @as(*anyopaque, @ptrCast(&function_marker)));
}

test "wasm.exec reference instructions and table operations" {
    const body = comptime i32c(0) ++ "\xD2\x00\x26\x00" ++ // table[0] = ref.func 0
        i32c(0) ++ "\x25\x00\xD1\x45" ++ // !ref.is_null(table[0]) => 1
        "\xFC\x10\x00" ++ i32c(2) ++ "\x46\x6A" ++ // table.size == 2
        "\xD0\x70" ++ i32c(1) ++ "\xFC\x0F\x00" ++ i32c(2) ++ "\x46\x6A" ++ // grow returns 2
        i32c(0) ++ "\xD0\x70" ++ i32c(1) ++ "\xFC\x11\x00" ++ // fill slot 0 with null
        i32c(0) ++ "\x25\x00\xD1\x6A"; // ref.is_null(table[0]) => 1
    const bytes = comptime hdr ++
        typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ tableSec(2, 4) ++ codeSec(&.{body});
    try expectResultsWithFeatures(bytes, .{ .reference_types = true }, 0, &.{}, &.{4});
}

test "wasm.exec externref tables preserve arbitrary identity" {
    const body = comptime i32c(0) ++ "\x20\x00\x26\x00" ++ i32c(0) ++ "\x25\x00";
    const bytes = comptime hdr ++
        typesSec(&.{ft("\x6F", "\x6F")}) ++ funcSec(&.{0}) ++
        sec(4, "\x01\x6F\x01\x01\x03") ++ codeSec(&.{body});
    var diag: types.Diagnostic = .{};
    const mod = try buildModuleWithFeatures(bytes, .{ .reference_types = true }, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);

    var object = js_value.Object{};
    var results: [1]ValueSlot = undefined;
    try invokeSlots(inst, 0, &.{.{ .externref = js_value.Value.obj(&object) }}, &results, &diag);
    try std.testing.expect(results[0] == .externref);
    try std.testing.expect(results[0].externref.asObj() == &object);
    try std.testing.expect(inst.tables[0].elems[0] == .externref);
    try std.testing.expect(inst.tables[0].elems[0].externref.asObj() == &object);
    try std.testing.expectEqual(@as(i32, 1), tableGrowWith(inst.tables[0], 1, results[0]));
    try std.testing.expect(inst.tables[0].elems[1].externref.asObj() == &object);
}

test "wasm.exec global reference roots publish overwrite and barrier state" {
    var object = js_value.Object{};
    const global = try createGlobalSlot(
        talloc,
        .{ .val = .externref, .mutable = true },
        .{ .externref = js_value.Value.obj(&object) },
    );
    defer destroyGlobal(talloc, global);
    try std.testing.expectEqual(js_value.Value.obj(&object).bits, global.ref_root.load(.acquire));

    var barriers: usize = 0;
    global.barrier_ctx = @ptrCast(&barriers);
    global.barrier = recordGlobalBarrier;
    setGlobalValue(global, .{ .externref = js_value.Value.obj(&object) });
    try std.testing.expectEqual(@as(usize, 1), barriers);
    setGlobalValue(global, .{ .numeric = 7 });
    try std.testing.expectEqual(js_value.Value.undef().bits, global.ref_root.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), barriers);
}

test "wasm.exec execution roots refresh after pop and local overwrite" {
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    var probe: RootLivenessProbe = .{};
    var diag: types.Diagnostic = .{};
    var state: State = .{
        .alloc = arena.allocator(),
        .diag = &diag,
        .root_hooks = .{
            .ctx = @ptrCast(&probe),
            .enter = RootLivenessProbe.enter,
            .leave = RootLivenessProbe.leave,
            .checkpoint = RootLivenessProbe.checkpoint,
        },
    };
    var object = js_value.Object{};
    try pushSlot(&state, .{ .externref = js_value.Value.obj(&object) });
    checkpoint(&state);
    _ = popSlot(&state);
    checkpoint(&state);
    try state.locals.append(state.alloc, .{ .externref = js_value.Value.obj(&object) });
    checkpoint(&state);
    state.locals.items[0] = .{ .numeric = 0 };
    checkpoint(&state);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1, 0 }, &probe.externrefs);
}

test "wasm.exec conversions trunc f32 to int" {
    try unop(.i32_trunc_f32_s, F32, I32, f32v(1.5), 1);
    try unop(.i32_trunc_f32_s, F32, I32, f32v(-1.5), i32v(-1));
    try unop(.i32_trunc_f32_s, F32, I32, f32v(2147483520.0), 2147483520);
    try unop(.i32_trunc_f32_s, F32, I32, f32v(-2147483648.0), i32v(std.math.minInt(i32)));
    try unop(.i32_trunc_f32_u, F32, I32, f32v(4294967040.0), 4294967040);
    try unop(.i32_trunc_f32_u, F32, I32, f32v(-0.5), 0);
    try unop(.i32_trunc_f32_u, F32, I32, f32v(0.999), 0);
    try unop(.i64_trunc_f32_s, F32, I64, f32v(9223371487098961920.0), 9223371487098961920);
    try unop(.i64_trunc_f32_s, F32, I64, f32v(-9223372036854775808.0), i64v(std.math.minInt(i64)));
    try unop(.i64_trunc_f32_u, F32, I64, f32v(18446742974197923840.0), 18446742974197923840);
}

test "wasm.exec conversions trunc f64 to int" {
    try unop(.i32_trunc_f64_s, F64, I32, f64v(1.5), 1);
    try unop(.i32_trunc_f64_s, F64, I32, f64v(2147483647.9), 2147483647);
    try unop(.i32_trunc_f64_s, F64, I32, f64v(-2147483648.9999), i32v(std.math.minInt(i32)));
    try unop(.i32_trunc_f64_u, F64, I32, f64v(4294967295.9), 4294967295);
    try unop(.i32_trunc_f64_u, F64, I32, f64v(-0.9), 0);
    try unop(.i64_trunc_f64_s, F64, I64, f64v(9223372036854774784.0), 9223372036854774784);
    try unop(.i64_trunc_f64_s, F64, I64, f64v(-9223372036854775808.0), i64v(std.math.minInt(i64)));
    try unop(.i64_trunc_f64_u, F64, I64, f64v(18446744073709549568.0), 18446744073709549568);
}

test "wasm.exec conversions trunc traps" {
    try unopTrap(.i32_trunc_f32_s, F32, I32, f32v(2147483648.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_s, F32, I32, f32v(-2147483904.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_s, F32, I32, f32nan, "invalid conversion to integer");
    try unopTrap(.i32_trunc_f32_u, F32, I32, f32v(4294967296.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_u, F32, I32, f32v(-1.0), "integer overflow");
    try unopTrap(.i32_trunc_f32_u, F32, I32, f32nan, "invalid conversion to integer");
    try unopTrap(.i32_trunc_f64_s, F64, I32, f64v(2147483648.0), "integer overflow");
    try unopTrap(.i32_trunc_f64_s, F64, I32, f64v(-2147483649.0), "integer overflow");
    try unopTrap(.i32_trunc_f64_s, F64, I32, f64nan, "invalid conversion to integer");
    try unopTrap(.i32_trunc_f64_u, F64, I32, f64v(4294967296.0), "integer overflow");
    try unopTrap(.i32_trunc_f64_u, F64, I32, f64v(-1.0), "integer overflow");
    try unopTrap(.i64_trunc_f32_s, F32, I64, f32v(9223372036854775808.0), "integer overflow");
    try unopTrap(.i64_trunc_f32_s, F32, I64, f32nan, "invalid conversion to integer");
    try unopTrap(.i64_trunc_f32_u, F32, I64, f32v(18446744073709551616.0), "integer overflow");
    try unopTrap(.i64_trunc_f32_u, F32, I64, f32v(-1.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_s, F64, I64, f64v(9223372036854775808.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_s, F64, I64, f64v(-9223372036854777856.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_s, F64, I64, f64nan, "invalid conversion to integer");
    try unopTrap(.i64_trunc_f64_u, F64, I64, f64v(18446744073709551616.0), "integer overflow");
    try unopTrap(.i64_trunc_f64_u, F64, I64, f64v(-1.0), "integer overflow");
}

test "wasm.exec conversions int to float" {
    try unop(.f32_convert_i32_s, I32, F32, i32v(-1), f32v(-1.0));
    try unop(.f32_convert_i32_s, I32, F32, 16777217, f32v(16777216.0)); // tie to even
    try unop(.f32_convert_i32_s, I32, F32, 16777219, f32v(16777220.0)); // tie to even
    try unop(.f32_convert_i32_u, I32, F32, 0xFFFFFFFF, f32v(4294967296.0));
    try unop(.f32_convert_i64_s, I64, F32, 4611686018427387905, f32v(4611686018427387904.0));
    try unop(.f32_convert_i64_u, I64, F32, 0xFFFFFFFFFFFFFFFF, f32v(18446744073709551616.0));
    try unop(.f64_convert_i32_s, I32, F64, i32v(-3), f64v(-3.0));
    try unop(.f64_convert_i32_u, I32, F64, 0xFFFFFFFF, f64v(4294967295.0));
    try unop(.f64_convert_i64_s, I64, F64, 9007199254740993, f64v(9007199254740992.0)); // tie to even
    try unop(.f64_convert_i64_u, I64, F64, 0xFFFFFFFFFFFFFFFF, f64v(18446744073709551616.0));
}

test "wasm.exec conversions demote promote reinterpret" {
    try unop(.f32_demote_f64, F64, F32, f64v(1.5), f32v(1.5));
    try unop(.f32_demote_f64, F64, F32, f64v(0.1), f32v(@floatCast(@as(f64, 0.1))));
    try unop(.f64_promote_f32, F32, F64, f32v(0.1), f64v(@as(f32, 0.1)));
    try unop(.f64_promote_f32, F32, F64, f32v(-2.5), f64v(-2.5));
    try unop(.i32_reinterpret_f32, F32, I32, f32v(1.5), 0x3FC00000);
    try unop(.f32_reinterpret_i32, I32, F32, 0x3FC00000, 0x3FC00000);
    try unop(.i64_reinterpret_f64, F64, I64, f64v(-2.5), f64v(-2.5));
    try unop(.f64_reinterpret_i64, I64, F64, 0xC004000000000000, 0xC004000000000000);
    // Reinterpret round-trips preserve exact bits, incl. NaN payloads.
    try unop(.f32_reinterpret_i32, I32, F32, 0x7FC00001, 0x7FC00001);
    try unop(.f64_reinterpret_i64, I64, F64, 0x7FF8000000000001, 0x7FF8000000000001);
}

// -- Memory ----------------------------------------------------------------------

const ld0 = "\x20\x00";
const ld01 = "\x20\x00\x20\x01";

const mem_types: []const []const u8 = &.{
    ft(I32, I32), ft(I32, I32), ft(I32, I32), ft(I32, I32), ft(I32, I32), // 0-4: i32 loads
    ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), ft(I32, I64), // 5-11: i64 loads
    ft(I32, F32), ft(I32, F64), // 12-13: float loads
    ft(I32 ++ I32, ""), ft(I32 ++ I32, ""), ft(I32 ++ I32, ""), // 14-16: i32 stores
    ft(I32 ++ I64, ""), ft(I32 ++ I64, ""), ft(I32 ++ I64, ""), ft(I32 ++ I64, ""), // 17-20: i64 stores
    ft(I32 ++ F32, ""), ft(I32 ++ F64, ""), // 21-22: float stores
    ft(I32, I32), // 23: i32.load with offset=4
};

const mem_bodies: []const []const u8 = &.{
    ld0 ++ "\x2C\x00\x00", // 0: i32.load8_s
    ld0 ++ "\x2D\x00\x00", // 1: i32.load8_u
    ld0 ++ "\x2E\x00\x00", // 2: i32.load16_s
    ld0 ++ "\x2F\x00\x00", // 3: i32.load16_u
    ld0 ++ "\x28\x00\x00", // 4: i32.load
    ld0 ++ "\x30\x00\x00", // 5: i64.load8_s
    ld0 ++ "\x31\x00\x00", // 6: i64.load8_u
    ld0 ++ "\x32\x00\x00", // 7: i64.load16_s
    ld0 ++ "\x33\x00\x00", // 8: i64.load16_u
    ld0 ++ "\x34\x00\x00", // 9: i64.load32_s
    ld0 ++ "\x35\x00\x00", // 10: i64.load32_u
    ld0 ++ "\x29\x00\x00", // 11: i64.load
    ld0 ++ "\x2A\x00\x00", // 12: f32.load
    ld0 ++ "\x2B\x00\x00", // 13: f64.load
    ld01 ++ "\x36\x00\x00", // 14: i32.store
    ld01 ++ "\x3A\x00\x00", // 15: i32.store8
    ld01 ++ "\x3B\x00\x00", // 16: i32.store16
    ld01 ++ "\x37\x00\x00", // 17: i64.store
    ld01 ++ "\x3C\x00\x00", // 18: i64.store8
    ld01 ++ "\x3D\x00\x00", // 19: i64.store16
    ld01 ++ "\x3E\x00\x00", // 20: i64.store32
    ld01 ++ "\x38\x00\x00", // 21: f32.store
    ld01 ++ "\x39\x00\x00", // 22: f64.store
    ld0 ++ "\x28\x00\x04", // 23: i32.load offset=4
};

const mem_mod_bytes = hdr ++
    typesSec(mem_types) ++
    funcSec(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 }) ++
    memSec(1, null) ++
    codeSec(mem_bodies);

fn memInstance() !Built {
    return build(mem_mod_bytes);
}

test "wasm.exec memory little endian widths" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 14, &.{ 0, 0x04030201 }); // i32.store
    try std.testing.expectEqual(@as(u64, 0x01), try run1(b.inst, 1, &.{0}));
    try std.testing.expectEqual(@as(u64, 0x02), try run1(b.inst, 1, &.{1}));
    try std.testing.expectEqual(@as(u64, 0x03), try run1(b.inst, 1, &.{2}));
    try std.testing.expectEqual(@as(u64, 0x04), try run1(b.inst, 1, &.{3}));
    try std.testing.expectEqual(@as(u64, 0x0201), try run1(b.inst, 3, &.{0})); // i32.load16_u
    try std.testing.expectEqual(@as(u64, 0x04030201), try run1(b.inst, 4, &.{0}));
}

test "wasm.exec memory sign and zero extension" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 15, &.{ 10, 0x80 }); // i32.store8
    try std.testing.expectEqual(i32v(-128), try run1(b.inst, 0, &.{10})); // i32.load8_s
    try std.testing.expectEqual(@as(u64, 128), try run1(b.inst, 1, &.{10})); // i32.load8_u
    try run0(b.inst, 16, &.{ 12, 0x8001 }); // i32.store16
    try std.testing.expectEqual(@as(u64, 0xFFFF8001), try run1(b.inst, 2, &.{12})); // i32.load16_s
    try std.testing.expectEqual(@as(u64, 0x8001), try run1(b.inst, 3, &.{12})); // i32.load16_u

    try run0(b.inst, 17, &.{ 16, 0x8070605040302010 }); // i64.store
    try std.testing.expectEqual(@as(u64, 0x10), try run1(b.inst, 6, &.{16})); // i64.load8_u
    try std.testing.expectEqual(@as(u64, 0x2010), try run1(b.inst, 8, &.{16})); // i64.load16_u
    try std.testing.expectEqual(@as(u64, 0x40302010), try run1(b.inst, 10, &.{16})); // i64.load32_u
    try std.testing.expectEqual(@as(u64, 0x8070605040302010), try run1(b.inst, 11, &.{16}));
    try run0(b.inst, 17, &.{ 24, 0xFFFFFFFF80000000 });
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF80000000), try run1(b.inst, 9, &.{24})); // i64.load32_s
    try std.testing.expectEqual(@as(u64, 0x80000000), try run1(b.inst, 10, &.{24})); // i64.load32_u
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFF80), try run1(b.inst, 5, &.{27})); // i64.load8_s of 0x80
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFF8000), try run1(b.inst, 7, &.{26})); // i64.load16_s of 0x8000
}

test "wasm.exec memory float load store" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 21, &.{ 32, 0x3FC00000 }); // f32.store 1.5
    try std.testing.expectEqual(@as(u64, 0x3FC00000), try run1(b.inst, 12, &.{32}));
    try std.testing.expectEqual(@as(u64, 0x3FC00000), try run1(b.inst, 4, &.{32})); // raw i32 view
    try run0(b.inst, 22, &.{ 40, 0xC004000000000000 }); // f64.store -2.5
    try std.testing.expectEqual(@as(u64, 0xC004000000000000), try run1(b.inst, 13, &.{40}));
    try std.testing.expectEqual(@as(u64, 0xC004000000000000), try run1(b.inst, 11, &.{40}));
}

test "wasm.exec memory unaligned access" {
    const b = try memInstance();
    defer destroyBuilt(b);
    try run0(b.inst, 14, &.{ 3, 0xAABBCCDD });
    try std.testing.expectEqual(@as(u64, 0xAABBCCDD), try run1(b.inst, 4, &.{3}));
    try run0(b.inst, 17, &.{ 5, 0x1122334455667788 });
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), try run1(b.inst, 11, &.{5}));
    try std.testing.expectEqual(@as(u64, 0x7788CCDD), try run1(b.inst, 10, &.{3})); // overlapping unaligned
}

test "wasm.exec memory out of bounds traps at exact boundary" {
    const b = try memInstance();
    defer destroyBuilt(b);
    // One page: len = 65536. ea + size == len is legal; +1 traps.
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 4, &.{65532})); // i32.load, last legal
    try runTrap(1, b.inst, 4, &.{65533}, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 11, &.{65528})); // i64.load, last legal
    try runTrap(1, b.inst, 11, &.{65529}, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 1, &.{65535})); // i32.load8_u, last legal
    try runTrap(1, b.inst, 1, &.{65536}, "out of bounds memory access");
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 3, &.{65534})); // i32.load16_u, last legal
    try runTrap(1, b.inst, 3, &.{65535}, "out of bounds memory access");
    // memarg offset participates in the bounds check.
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 23, &.{65528})); // 65528+4+4 == 65536
    try runTrap(1, b.inst, 23, &.{65529}, "out of bounds memory access");
    // Effective address arithmetic is 64-bit: no 32-bit wraparound.
    try runTrap(1, b.inst, 23, &.{0xFFFFFFFF}, "out of bounds memory access");
    try runTrap(1, b.inst, 4, &.{0xFFFFFFFE}, "out of bounds memory access");
    // Stores bounds-check too.
    try runTrap(0, b.inst, 14, &.{ 65533, 0 }, "out of bounds memory access");
    try runTrap(0, b.inst, 15, &.{ 65536, 0 }, "out of bounds memory access");
    try run0(b.inst, 14, &.{ 65532, 0xDEADBEEF }); // last legal store
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), try run1(b.inst, 4, &.{65532}));
}

const grow_mod_bytes = hdr ++
    typesSec(&.{ ft("", I32), ft(I32, I32), ft(I32, I32) }) ++
    funcSec(&.{ 0, 1, 2 }) ++
    memSec(1, 3) ++
    codeSec(&.{ "\x3F\x00", "\x20\x00\x40\x00", ld0 ++ "\x28\x00\x00" });

test "wasm.exec memory grow and size" {
    const b = try build(grow_mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 1), try run1(b.inst, 0, &.{})); // size
    try std.testing.expectEqual(@as(u64, 1), try run1(b.inst, 1, &.{1})); // grow(1) -> old size
    try std.testing.expectEqual(@as(u64, 2), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(@as(u64, 0), try run1(b.inst, 2, &.{2 * 65536 - 4})); // grown pages are zero-filled
    try std.testing.expectEqual(@as(u64, 2), try run1(b.inst, 1, &.{1})); // grow to max
    try std.testing.expectEqual(@as(u64, 3), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), try run1(b.inst, 1, &.{1})); // beyond max -> -1
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), try run1(b.inst, 1, &.{std.math.maxInt(u32)})); // huge delta -> -1
    try std.testing.expectEqual(@as(u64, 3), try run1(b.inst, 0, &.{})); // size unchanged after failures
    try std.testing.expectEqual(@as(u64, 3), try run1(b.inst, 1, &.{0})); // grow(0) -> current size
}

test "wasm.exec memory data segment bytes" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft(I32, I32), ft(I32, I32) }) ++
        funcSec(&.{ 0, 1 }) ++
        memSec(1, null) ++
        codeSec(&.{ ld0 ++ "\x2D\x00\x00", ld0 ++ "\x28\x00\x00" }) ++
        dataSec0(4, "ABCD"));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 'A'), try run1(b.inst, 0, &.{4}));
    try std.testing.expectEqual(@as(u64, 'D'), try run1(b.inst, 0, &.{7}));
    try std.testing.expectEqual(@as(u64, 0x44434241), try run1(b.inst, 1, &.{4})); // little-endian "ABCD"
}

// -- call_indirect ---------------------------------------------------------------

const ci_bytes = hdr ++
    typesSec(&.{ ft("", I32), ft(I32, I32), ft(I32 ++ I32, I32) }) ++
    funcSec(&.{ 0, 1, 2 }) ++
    tableSec(2, null) ++
    elemSec0(0, &.{0}) ++
    codeSec(&.{
        i32c(77), // 0: () -> 77
        "\x20\x00\x11\x00\x00", // 1: (i32 index) -> call_indirect type 0
        "\x20\x00\x20\x01\x11\x01\x00", // 2: (i32 param, i32 index) -> call_indirect type 1
    });

test "wasm.exec call_indirect happy path" {
    const b = try build(ci_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(@as(u64, 77), try run1(b.inst, 1, &.{0}));
}

test "wasm.exec call_indirect traps" {
    const b = try build(ci_bytes);
    defer destroyBuilt(b);
    try runTrap(1, b.inst, 1, &.{1}, "uninitialized element"); // elem wrote only index 0
    try runTrap(1, b.inst, 1, &.{2}, "undefined element");
    try runTrap(1, b.inst, 1, &.{99}, "undefined element");
    try runTrap(1, b.inst, 2, &.{ 0, 0 }, "indirect call type mismatch"); // ()->i32 entry vs (i32)->i32
}

test "wasm.exec call_indirect cross-instance shared table" {
    // Module A defines func () -> 77; module B imports a table and calls
    // through it. The shared TableInst is host-owned: B's destroyInstance
    // must not free it, and B is destroyed before A (its table references
    // A's FuncInst).
    const a_bytes = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ codeSec(&.{i32c(77)}));
    const a = try build(a_bytes);
    defer destroyBuilt(a);
    const tab = try createTable(talloc, 1, null);
    defer destroyTable(talloc, tab);
    tab.elems[0] = .{ .funcref = @ptrCast(a.inst.funcs[0]) };

    const b_bytes = comptime (hdr ++
        typesSec(&.{ft("", I32)}) ++
        importSec(&.{impTable("a", "t", 1, null)}) ++
        funcSec(&.{0}) ++
        codeSec(&.{i32c(0) ++ "\x11\x00\x00"}));
    var diag: types.Diagnostic = .{};
    const bmod = try buildModule(b_bytes, &diag);
    defer decode.destroyModule(talloc, bmod);
    const binst = try instantiate(talloc, bmod, .{ .tables = &.{tab} }, &diag);
    defer destroyInstance(talloc, binst);
    try std.testing.expectEqual(@as(u64, 77), try run1(binst, 0, &.{}));
}

test "wasm.exec call_indirect selects an explicit table across instances" {
    const a_bytes = comptime (hdr ++ typesSec(&.{ft("", I32)}) ++ funcSec(&.{0}) ++ codeSec(&.{i32c(91)}));
    const a = try build(a_bytes);
    defer destroyBuilt(a);
    const decoy = try createTable(talloc, 1, null);
    defer destroyTable(talloc, decoy);
    const target = try createTable(talloc, 1, null);
    defer destroyTable(talloc, target);
    target.elems[0] = .{ .funcref = @ptrCast(a.inst.funcs[0]) };

    const b_bytes = comptime (hdr ++
        typesSec(&.{ft("", I32)}) ++
        importSec(&.{ impTable("a", "decoy", 1, null), impTable("a", "target", 1, null) }) ++
        funcSec(&.{0}) ++
        codeSec(&.{i32c(0) ++ "\x11\x00\x01"}));
    var diag: types.Diagnostic = .{};
    const bmod = try buildModuleWithFeatures(b_bytes, .{ .reference_types = true }, &diag);
    defer decode.destroyModule(talloc, bmod);
    const binst = try instantiate(talloc, bmod, .{ .tables = &.{ decoy, target } }, &diag);
    defer destroyInstance(talloc, binst);
    try std.testing.expectEqual(@as(u64, 91), try run1(binst, 0, &.{}));
}

// -- Globals ---------------------------------------------------------------------

test "wasm.exec globals get and set" {
    const mod_bytes = comptime (hdr ++
        typesSec(&.{ ft("", I32), ft(I32, I32), ft("", I64), ft("", F32), ft("", F64) }) ++
        funcSec(&.{ 0, 1, 2, 3, 4 }) ++
        globalSec(&.{ glob(I32, true, i32c(42)), glob(I64, false, i64c(-7)), glob(F32, true, f32c(1.5)), glob(F64, false, f64c(-2.5)) }) ++
        codeSec(&.{
            "\x23\x00", // 0: global.get 0
            "\x20\x00\x24\x00\x23\x00", // 1: global.set 0; global.get 0
            "\x23\x01", // 2: global.get 1
            "\x23\x02", // 3: global.get 2
            "\x23\x03", // 4: global.get 3
        }));
    const b = try build(mod_bytes);
    defer destroyBuilt(b);
    try std.testing.expectEqual(i32v(42), try run1(b.inst, 0, &.{}));
    try std.testing.expectEqual(i32v(7), try run1(b.inst, 1, &.{7}));
    try std.testing.expectEqual(i32v(7), try run1(b.inst, 0, &.{})); // mutation persists
    try std.testing.expectEqual(i64v(-7), try run1(b.inst, 2, &.{}));
    try std.testing.expectEqual(f32v(1.5), try run1(b.inst, 3, &.{}));
    try std.testing.expectEqual(f64v(-2.5), try run1(b.inst, 4, &.{}));
}

// -- Stack exhaustion --------------------------------------------------------------

test "wasm.exec call stack exhaustion traps without crashing" {
    const mod_bytes = comptime (hdr ++ typesSec(&.{ft("", "")}) ++ funcSec(&.{0}) ++ codeSec(&.{"\x10\x00"}));
    var diag: types.Diagnostic = .{};
    const mod = try buildModule(mod_bytes, &diag);
    defer decode.destroyModule(talloc, mod);
    const inst = try instantiate(talloc, mod, .{}, &diag);
    defer destroyInstance(talloc, inst);
    try std.testing.expectError(error.Trap, invoke(inst, 0, &.{}, &.{}, &diag));
    try std.testing.expectEqualStrings("call stack exhausted", diag.message());
}
