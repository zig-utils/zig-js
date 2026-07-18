//! Strict WebAssembly MVP (wg-1.0) validator.
//!
//! Consumes the IR from `types.zig` (produced by `decode.zig`) and enforces
//! wg-1.0 validation: module-level index/type checks plus the standard
//! abstract-interpretation algorithm over each function body. All failures
//! are `error.Invalid` with a deterministic `(offset, message)` diagnostic:
//! body errors carry the byte offset of the offending instruction
//! (`FuncBody.offsets`), module-level errors use `Diagnostic.no_offset`.

const std = @import("std");
const types = @import("types.zig");
const simd = @import("simd.zig");
const simd_meta = @import("simd_validate.zig");

pub const Error = error{Invalid};

fn unsupportedFeature(mod: *const types.Module, diag: *types.Diagnostic, feature: types.Feature) Error {
    return if (mod.features.enabled(feature))
        failModFmt(diag, "WebAssembly feature {s} is enabled but not implemented", .{feature.name()})
    else
        failModFmt(diag, "WebAssembly feature {s} is disabled", .{feature.name()});
}

pub fn validate(mod: *const types.Module, diag: *types.Diagnostic) Error!void {
    // 1. Type indices must resolve; reference value positions are opt-in.
    for (mod.types) |ft| {
        // MVP function types have at most one result; multi-value is opt-in.
        if (ft.results.len > 1 and !mod.features.multi_value) return failMod(diag, "invalid result arity");
        for (ft.params) |p| {
            if (p.isReference() and !mod.features.reference_types) return unsupportedFeature(mod, diag, .reference_types);
            if (p == .v128 and !mod.features.fixed_width_simd) return unsupportedFeature(mod, diag, .fixed_width_simd);
        }
        for (ft.results) |r| {
            if (r.isReference() and !mod.features.reference_types) return unsupportedFeature(mod, diag, .reference_types);
            if (r == .v128 and !mod.features.fixed_width_simd) return unsupportedFeature(mod, diag, .fixed_width_simd);
        }
    }
    for (mod.imports) |imp| switch (imp.desc) {
        .func => |t| if (t >= mod.types.len) return failMod(diag, "unknown type"),
        .global => |g| if (g.val.isReference() and !mod.features.reference_types) return unsupportedFeature(mod, diag, .reference_types),
        else => {},
    };
    for (mod.funcs) |t|
        if (t >= mod.types.len) return failMod(diag, "unknown type");

    // 2. MVP allows at most one table and one memory (imports + defined).
    if (mod.totalTables() > 1 and !mod.features.reference_types) return failMod(diag, "multiple tables");
    if (mod.totalMems() > 1) return failMod(diag, "multiple memories");

    // 3. Global initializers: typed constant expressions.
    for (mod.globals) |g| {
        if (g.type.val.isReference() and !mod.features.reference_types) return unsupportedFeature(mod, diag, .reference_types);
        if (g.type.val == .v128 and !mod.features.fixed_width_simd) return unsupportedFeature(mod, diag, .fixed_width_simd);
        try checkConstExpr(mod, g.init, g.type.val, diag);
    }
    for (mod.code) |body| {
        for (body.locals) |l| {
            if (l.isReference() and !mod.features.reference_types) return unsupportedFeature(mod, diag, .reference_types);
            if (l == .v128 and !mod.features.fixed_width_simd) return unsupportedFeature(mod, diag, .fixed_width_simd);
        }
    }

    // 4. Element segments.
    for (mod.elems) |e| {
        if (e.type.isReference() and !mod.features.reference_types and e.type != .funcref)
            return unsupportedFeature(mod, diag, .reference_types);
        switch (e.mode) {
            .active => |active| {
                if (active.table >= mod.totalTables())
                    return failModFmt(diag, "unknown table {d}", .{active.table});
                if (mod.tableType(active.table).elem != e.type)
                    return failMod(diag, "type mismatch");
                try checkConstExpr(mod, active.offset, .i32, diag);
            },
            .passive, .declarative => {},
        }
        for (e.init) |init| try checkConstExpr(mod, init, e.type, diag);
    }

    // 5. Data segments.
    for (mod.datas) |d| {
        switch (d.mode) {
            .active => |active| {
                if (active.mem >= mod.totalMems())
                    return failModFmt(diag, "unknown memory {d}", .{active.mem});
                try checkConstExpr(mod, active.offset, .i32, diag);
            },
            .passive => {},
        }
    }
    if (mod.data_count) |count|
        if (count != mod.datas.len) return failMod(diag, "data count and data section have inconsistent lengths");

    // 6. Exports: indices resolve and names are unique.
    for (mod.exports, 0..) |e, i| {
        switch (e.kind) {
            .func => if (e.index >= mod.totalFuncs())
                return failMod(diag, "unknown function"),
            .table => if (e.index >= mod.totalTables())
                return failModFmt(diag, "unknown table {d}", .{e.index}),
            .mem => if (e.index >= mod.totalMems())
                return failModFmt(diag, "unknown memory {d}", .{e.index}),
            .global => if (e.index >= mod.totalGlobals())
                return failMod(diag, "unknown global"),
        }
        for (mod.exports[0..i]) |prev|
            if (std.mem.eql(u8, prev.name, e.name))
                return failMod(diag, "duplicate export name");
    }

    // 7. Start function must exist and have type [] -> [].
    if (mod.start) |s| {
        if (s >= mod.totalFuncs()) return failMod(diag, "unknown function");
        const ft = mod.funcType(s);
        if (ft.params.len != 0 or ft.results.len != 0)
            return failMod(diag, "start function must have nullary type");
    }

    // 8. Function bodies.
    for (mod.funcs, mod.code) |typeidx, body|
        try validateFunc(mod, diag, mod.types[typeidx], body);
}

fn failMod(diag: *types.Diagnostic, comptime msg: []const u8) Error {
    diag.set(types.Diagnostic.no_offset, msg, .{});
    return error.Invalid;
}

fn failModFmt(diag: *types.Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set(types.Diagnostic.no_offset, fmt, args);
    return error.Invalid;
}

/// A constant expression of type `expected`. `global.get` may only refer to
/// imported, immutable globals of the right type (wg-1.0 rule).
fn checkConstExpr(
    mod: *const types.Module,
    expr: types.ConstExpr,
    expected: types.ValType,
    diag: *types.Diagnostic,
) Error!void {
    switch (expr) {
        .global => |gi| {
            if (gi >= mod.imported_globals) return failMod(diag, "unknown global");
            const gt = mod.globalType(gi);
            if (gt.mutable) return failMod(diag, "constant expression required");
            if (gt.val != expected) return failMod(diag, "type mismatch");
        },
        .ref_func => |funcidx| {
            if (funcidx >= mod.totalFuncs()) return failModFmt(diag, "unknown function {d}", .{funcidx});
            if (expected != .funcref) return failMod(diag, "type mismatch");
        },
        else => if (expr.valType() != expected)
            return failMod(diag, "type mismatch"),
    }
}

fn isDeclaredFunction(mod: *const types.Module, funcidx: u32) bool {
    for (mod.exports) |exported|
        if (exported.kind == .func and exported.index == funcidx) return true;
    for (mod.globals) |global| switch (global.init) {
        .ref_func => |declared| if (declared == funcidx) return true,
        else => {},
    };
    for (mod.elems) |elem|
        for (elem.init) |init| switch (init) {
            .ref_func => |declared| if (declared == funcidx) return true,
            else => {},
        };
    return false;
}

/// Abstract operand: a concrete numeric type or `unknown`, the bottom type
/// produced by the polymorphic stack after `unreachable`/branches.
const StackVal = enum { unknown, i32, i64, f32, f64, v128, funcref, externref };

fn stackVal(vt: types.ValType) StackVal {
    return switch (vt) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        .v128 => .v128,
        .funcref => .funcref,
        .externref => .externref,
    };
}

const FrameKind = enum { block, loop, if_ };

const Frame = struct {
    kind: FrameKind,
    params: []const types.ValType,
    results: []const types.ValType,
    height: usize,
    unreach: bool = false,
    saw_else: bool = false,

    /// Types a branch to this frame must supply: a `loop` restarts, so its
    /// result only applies to fallthrough; block/if branch with their result.
    fn branchTypes(self: Frame) []const types.ValType {
        return if (self.kind == .loop) self.params else self.results;
    }
};

const MemInfo = struct { t: types.ValType, log2_bytes: u32 };

const SimdDecoded = struct {
    op: simd.Op,
    memarg: ?types.Instr.MemArg = null,
    lane: ?u8 = null,
    shuffle: ?[16]u8 = null,
};

fn simdDecoded(instr: types.Instr) SimdDecoded {
    return switch (instr.imm) {
        .simd => |op| .{ .op = op },
        .simd_memarg => |value| .{ .op = value.op, .memarg = value.memarg },
        .simd_v128 => |value| .{ .op = value.op },
        .simd_shuffle => |value| .{ .op = value.op, .shuffle = value.lanes },
        .simd_lane => |value| .{ .op = value.op, .lane = value.lane },
        .simd_memarg_lane => |value| .{ .op = value.op, .memarg = value.memarg, .lane = value.lane },
        else => unreachable,
    };
}

fn memInfo(op: types.Op) MemInfo {
    return switch (op) {
        .i32_load => .{ .t = .i32, .log2_bytes = 2 },
        .i64_load => .{ .t = .i64, .log2_bytes = 3 },
        .f32_load => .{ .t = .f32, .log2_bytes = 2 },
        .f64_load => .{ .t = .f64, .log2_bytes = 3 },
        .i32_load8_s, .i32_load8_u => .{ .t = .i32, .log2_bytes = 0 },
        .i32_load16_s, .i32_load16_u => .{ .t = .i32, .log2_bytes = 1 },
        .i64_load8_s, .i64_load8_u => .{ .t = .i64, .log2_bytes = 0 },
        .i64_load16_s, .i64_load16_u => .{ .t = .i64, .log2_bytes = 1 },
        .i64_load32_s, .i64_load32_u => .{ .t = .i64, .log2_bytes = 2 },
        .i32_store => .{ .t = .i32, .log2_bytes = 2 },
        .i64_store => .{ .t = .i64, .log2_bytes = 3 },
        .f32_store => .{ .t = .f32, .log2_bytes = 2 },
        .f64_store => .{ .t = .f64, .log2_bytes = 3 },
        .i32_store8 => .{ .t = .i32, .log2_bytes = 0 },
        .i32_store16 => .{ .t = .i32, .log2_bytes = 1 },
        .i64_store8 => .{ .t = .i64, .log2_bytes = 0 },
        .i64_store16 => .{ .t = .i64, .log2_bytes = 1 },
        .i64_store32 => .{ .t = .i64, .log2_bytes = 2 },
        else => unreachable,
    };
}

const FuncValidator = struct {
    mod: *const types.Module,
    diag: *types.Diagnostic,
    params: []const types.ValType,
    locals: []const types.ValType, // declared locals (params excluded)
    instrs: []const types.Instr,
    offsets: []const u32,
    pc: usize = 0,
    opds: []StackVal,
    op_len: usize = 0,
    frames: []Frame,
    fr_len: usize = 0,

    fn fail(self: *FuncValidator, comptime msg: []const u8) Error {
        self.diag.set(self.offsets[self.pc], msg, .{});
        return error.Invalid;
    }

    fn push(self: *FuncValidator, v: StackVal) void {
        self.opds[self.op_len] = v;
        self.op_len += 1;
    }

    /// Popping from a frame-height stack in an unreachable frame yields the
    /// polymorphic bottom type; in a reachable frame it is an underflow.
    fn pop(self: *FuncValidator) Error!StackVal {
        const f = &self.frames[self.fr_len - 1];
        if (self.op_len == f.height) {
            if (f.unreach) return .unknown;
            return self.fail("type mismatch");
        }
        self.op_len -= 1;
        return self.opds[self.op_len];
    }

    fn popExpect(self: *FuncValidator, t: types.ValType) Error!void {
        const v = try self.pop();
        if (v != .unknown and v != stackVal(t)) return self.fail("type mismatch");
    }

    fn popTypes(self: *FuncValidator, values: []const types.ValType) Error!void {
        var i = values.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(values[i]);
        }
    }

    /// Check a type sequence against the current operands without consuming or
    /// concretizing polymorphic-bottom values. Used by br_table, whose targets
    /// all inspect the same pre-branch stack.
    fn checkTypes(self: *FuncValidator, values: []const types.ValType) Error!void {
        const f = &self.frames[self.fr_len - 1];
        var cursor = self.op_len;
        var i = values.len;
        while (i > 0) {
            i -= 1;
            const actual: StackVal = if (cursor == f.height) blk: {
                if (!f.unreach) return self.fail("type mismatch");
                break :blk .unknown;
            } else blk: {
                cursor -= 1;
                break :blk self.opds[cursor];
            };
            if (actual != .unknown and actual != stackVal(values[i]))
                return self.fail("type mismatch");
        }
    }

    fn pushTypes(self: *FuncValidator, values: []const types.ValType) void {
        for (values) |value| self.push(stackVal(value));
    }

    fn pushFrame(self: *FuncValidator, kind: FrameKind, ft: types.FuncType) Error!void {
        try self.popTypes(ft.params);
        self.frames[self.fr_len] = .{ .kind = kind, .params = ft.params, .results = ft.results, .height = self.op_len };
        self.fr_len += 1;
        self.pushTypes(ft.params);
    }

    /// End-of-frame rule: the operands above the frame height must be exactly
    /// the frame results (count + types, tolerating unreachable).
    fn popFrame(self: *FuncValidator) Error!Frame {
        std.debug.assert(self.fr_len > 0);
        const f = self.frames[self.fr_len - 1];
        try self.popTypes(f.results);
        if (self.op_len != f.height) return self.fail("type mismatch");
        self.fr_len -= 1;
        return f;
    }

    fn setUnreachable(self: *FuncValidator) void {
        const f = &self.frames[self.fr_len - 1];
        self.op_len = f.height;
        f.unreach = true;
    }

    fn target(self: *FuncValidator, depth: u32) Error!Frame {
        if (depth >= self.fr_len) return self.fail("unknown label");
        return self.frames[self.fr_len - 1 - depth];
    }

    fn localType(self: *FuncValidator, idx: u32) ?types.ValType {
        const i: usize = idx;
        if (i < self.params.len) return self.params[i];
        const li = i - self.params.len;
        if (li < self.locals.len) return self.locals[li];
        return null;
    }

    fn memAccess(self: *FuncValidator, memarg: types.Instr.MemArg, log2_bytes: u32) Error!void {
        if (self.mod.totalMems() == 0) return self.fail("unknown memory 0");
        if (memarg.align_ > log2_bytes)
            return self.fail("alignment must not be larger than natural");
    }

    fn callFunc(self: *FuncValidator, ft: types.FuncType) Error!void {
        var i = ft.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(ft.params[i]);
        }
        self.pushTypes(ft.results);
    }

    // Signature helpers.
    fn unop(self: *FuncValidator, t: types.ValType) Error!void {
        try self.popExpect(t);
        self.push(stackVal(t));
    }
    fn binop(self: *FuncValidator, t: types.ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        self.push(stackVal(t));
    }
    fn testop(self: *FuncValidator, t: types.ValType) Error!void {
        try self.popExpect(t);
        self.push(.i32);
    }
    fn relop(self: *FuncValidator, t: types.ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        self.push(.i32);
    }
    fn cvtop(self: *FuncValidator, from: types.ValType, to: types.ValType) Error!void {
        try self.popExpect(from);
        self.push(stackVal(to));
    }

    fn validateSimd(self: *FuncValidator, instr: types.Instr) Error!void {
        const decoded = simdDecoded(instr);
        if (decoded.memarg) |memarg|
            try self.memAccess(memarg, simd_meta.naturalAlignment(decoded.op).?);
        if (decoded.lane) |lane|
            if (lane >= simd_meta.laneLimit(decoded.op).?) return self.fail("invalid lane index");
        if (decoded.shuffle) |lanes|
            for (lanes) |lane| if (lane >= 32) return self.fail("invalid lane index");

        switch (simd_meta.shape(decoded.op)) {
            .load => {
                try self.popExpect(.i32);
                self.push(.v128);
            },
            .store, .lane_store => {
                try self.popExpect(.v128);
                try self.popExpect(.i32);
            },
            .lane_load => {
                try self.popExpect(.v128);
                try self.popExpect(.i32);
                self.push(.v128);
            },
            .const_ => self.push(.v128),
            .unary => {
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .binary => {
                try self.popExpect(.v128);
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .ternary => {
                try self.popExpect(.v128);
                try self.popExpect(.v128);
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .test_ => {
                try self.popExpect(.v128);
                self.push(.i32);
            },
            .shift => {
                try self.popExpect(.i32);
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .splat_i32 => {
                try self.popExpect(.i32);
                self.push(.v128);
            },
            .splat_i64 => {
                try self.popExpect(.i64);
                self.push(.v128);
            },
            .splat_f32 => {
                try self.popExpect(.f32);
                self.push(.v128);
            },
            .splat_f64 => {
                try self.popExpect(.f64);
                self.push(.v128);
            },
            .extract_i32 => {
                try self.popExpect(.v128);
                self.push(.i32);
            },
            .extract_i64 => {
                try self.popExpect(.v128);
                self.push(.i64);
            },
            .extract_f32 => {
                try self.popExpect(.v128);
                self.push(.f32);
            },
            .extract_f64 => {
                try self.popExpect(.v128);
                self.push(.f64);
            },
            .replace_i32 => {
                try self.popExpect(.i32);
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .replace_i64 => {
                try self.popExpect(.i64);
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .replace_f32 => {
                try self.popExpect(.f32);
                try self.popExpect(.v128);
                self.push(.v128);
            },
            .replace_f64 => {
                try self.popExpect(.f64);
                try self.popExpect(.v128);
                self.push(.v128);
            },
        }
    }

    fn run(self: *FuncValidator) Error!void {
        while (self.pc < self.instrs.len) : (self.pc += 1) {
            const instr = self.instrs[self.pc];
            switch (instr.op) {
                .unreachable_ => self.setUnreachable(),
                .nop => {},
                .block => try self.pushFrame(.block, instr.imm.block.type.funcType(self.mod) orelse return self.fail("unknown type")),
                .loop => try self.pushFrame(.loop, instr.imm.block.type.funcType(self.mod) orelse return self.fail("unknown type")),
                .if_ => {
                    try self.popExpect(.i32);
                    try self.pushFrame(.if_, instr.imm.block.type.funcType(self.mod) orelse return self.fail("unknown type"));
                },
                .else_ => {
                    // The decoder guarantees structure; stay defensive.
                    if (self.fr_len == 0)
                        return self.fail("else opcode without matching if");
                    const f = &self.frames[self.fr_len - 1];
                    if (f.kind != .if_ or f.saw_else)
                        return self.fail("else opcode without matching if");
                    // The if-arm must produce the frame results.
                    try self.popTypes(f.results);
                    if (self.op_len != f.height) return self.fail("type mismatch");
                    self.op_len = f.height;
                    f.unreach = false;
                    f.saw_else = true;
                    self.pushTypes(f.params);
                },
                .end => {
                    const f = try self.popFrame();
                    // An if with a result but no else can never produce the
                    // result when the condition is false.
                    if (f.kind == .if_ and !std.mem.eql(types.ValType, f.params, f.results) and !f.saw_else)
                        return self.fail("type mismatch");
                    if (self.fr_len == 0) {
                        // Function end: the decoder guarantees this is the
                        // final instruction.
                        std.debug.assert(self.pc == self.instrs.len - 1);
                    } else self.pushTypes(f.results);
                },
                .br => {
                    const f = try self.target(instr.imm.idx);
                    try self.popTypes(f.branchTypes());
                    self.setUnreachable();
                },
                .br_if => {
                    try self.popExpect(.i32);
                    const f = try self.target(instr.imm.idx);
                    const branch_types = f.branchTypes();
                    try self.popTypes(branch_types);
                    self.pushTypes(branch_types);
                },
                .br_table => {
                    const bt = instr.imm.br_table;
                    try self.popExpect(.i32);
                    // Validate each target against the same operand stack.
                    // Rechecking the target operands preserves concrete type
                    // agreement on reachable paths, while the
                    // polymorphic bottom after `unreachable` can meet labels
                    // with different result types as Core 2 permits.
                    const def = try self.target(bt.default);
                    for (bt.targets) |t| {
                        const target_frame = try self.target(t);
                        const branch_types = target_frame.branchTypes();
                        if (branch_types.len != def.branchTypes().len)
                            return self.fail("type mismatch");
                        try self.checkTypes(branch_types);
                    }
                    try self.checkTypes(def.branchTypes());
                    self.setUnreachable();
                },
                .return_ => {
                    // Branch to the outermost (function) frame.
                    try self.popTypes(self.frames[0].results);
                    self.setUnreachable();
                },
                .call => {
                    const idx = instr.imm.idx;
                    if (idx >= self.mod.totalFuncs())
                        return self.fail("unknown function");
                    try self.callFunc(self.mod.funcType(idx));
                },
                .call_indirect => {
                    const tidx = instr.imm.call_indirect.type_index;
                    const tableidx = instr.imm.call_indirect.table_index;
                    if (tidx >= self.mod.types.len) return self.fail("unknown type");
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    if (self.mod.tableType(tableidx).elem != .funcref) return self.fail("type mismatch");
                    try self.popExpect(.i32);
                    try self.callFunc(self.mod.types[tidx]);
                },
                .drop => _ = try self.pop(),
                .select => {
                    try self.popExpect(.i32);
                    const t1 = try self.pop();
                    const t2 = try self.pop();
                    // Numeric operands only (funcref never reaches the stack);
                    // unknown unifies with the other side.
                    if (t1 != .unknown and t2 != .unknown and t1 != t2)
                        return self.fail("type mismatch");
                    const selected = if (t1 != .unknown) t1 else t2;
                    if (selected == .funcref or selected == .externref)
                        return self.fail("type mismatch");
                    self.push(selected);
                },
                .typed_select => {
                    try self.popExpect(.i32);
                    try self.popExpect(instr.imm.type);
                    try self.popExpect(instr.imm.type);
                    self.push(stackVal(instr.imm.type));
                },
                .local_get => {
                    const t = self.localType(instr.imm.idx) orelse
                        return self.fail("unknown local");
                    self.push(stackVal(t));
                },
                .local_set => {
                    const t = self.localType(instr.imm.idx) orelse
                        return self.fail("unknown local");
                    try self.popExpect(t);
                },
                .local_tee => {
                    const t = self.localType(instr.imm.idx) orelse
                        return self.fail("unknown local");
                    try self.popExpect(t);
                    self.push(stackVal(t));
                },
                .global_get => {
                    const idx = instr.imm.idx;
                    if (idx >= self.mod.totalGlobals()) return self.fail("unknown global");
                    self.push(stackVal(self.mod.globalType(idx).val));
                },
                .global_set => {
                    const idx = instr.imm.idx;
                    if (idx >= self.mod.totalGlobals()) return self.fail("unknown global");
                    const gt = self.mod.globalType(idx);
                    if (!gt.mutable) return self.fail("global is immutable");
                    try self.popExpect(gt.val);
                },
                .table_get => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    try self.popExpect(.i32);
                    self.push(stackVal(self.mod.tableType(tableidx).elem));
                },
                .table_set => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    try self.popExpect(self.mod.tableType(tableidx).elem);
                    try self.popExpect(.i32);
                },
                .ref_null => self.push(stackVal(instr.imm.type)),
                .ref_is_null => {
                    const ref = try self.pop();
                    if (ref != .unknown and ref != .funcref and ref != .externref)
                        return self.fail("type mismatch");
                    self.push(.i32);
                },
                .ref_func => {
                    if (instr.imm.idx >= self.mod.totalFuncs()) return self.fail("unknown function");
                    if (!isDeclaredFunction(self.mod, instr.imm.idx)) return self.fail("undeclared function reference");
                    self.push(.funcref);
                },
                .table_grow => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    try self.popExpect(.i32);
                    try self.popExpect(self.mod.tableType(tableidx).elem);
                    self.push(.i32);
                },
                .table_size => {
                    if (instr.imm.idx >= self.mod.totalTables())
                        return if (instr.imm.idx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    self.push(.i32);
                },
                .table_fill => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    try self.popExpect(.i32);
                    try self.popExpect(self.mod.tableType(tableidx).elem);
                    try self.popExpect(.i32);
                },
                .memory_init => {
                    const immediate = instr.imm.indices;
                    if (self.mod.data_count == null) return self.fail("data count section required");
                    if (immediate.first >= self.mod.datas.len) return self.fail("unknown data segment");
                    if (immediate.second >= self.mod.totalMems()) return self.fail("unknown memory");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                },
                .data_drop => {
                    if (self.mod.data_count == null) return self.fail("data count section required");
                    if (instr.imm.idx >= self.mod.datas.len) return self.fail("unknown data segment");
                },
                .memory_copy => {
                    const immediate = instr.imm.indices;
                    if (immediate.first >= self.mod.totalMems() or immediate.second >= self.mod.totalMems())
                        return self.fail("unknown memory");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                },
                .memory_fill => {
                    if (instr.imm.idx >= self.mod.totalMems()) return self.fail("unknown memory");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                },
                .table_init => {
                    const immediate = instr.imm.indices;
                    if (immediate.first >= self.mod.elems.len) return self.fail("unknown element segment");
                    if (immediate.second >= self.mod.totalTables()) return self.fail("unknown table");
                    if (self.mod.elems[immediate.first].type != self.mod.tableType(immediate.second).elem)
                        return self.fail("type mismatch");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                },
                .elem_drop => {
                    if (instr.imm.idx >= self.mod.elems.len) return self.fail("unknown element segment");
                },
                .table_copy => {
                    const immediate = instr.imm.indices;
                    if (immediate.first >= self.mod.totalTables() or immediate.second >= self.mod.totalTables())
                        return self.fail("unknown table");
                    if (self.mod.tableType(immediate.first).elem != self.mod.tableType(immediate.second).elem)
                        return self.fail("type mismatch");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                },
                .i32_load, .i64_load, .f32_load, .f64_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => {
                    const info = memInfo(instr.op);
                    try self.memAccess(instr.imm.memarg, info.log2_bytes);
                    try self.popExpect(.i32);
                    self.push(stackVal(info.t));
                },
                .i32_store, .i64_store, .f32_store, .f64_store, .i32_store8, .i32_store16, .i64_store8, .i64_store16, .i64_store32 => {
                    const info = memInfo(instr.op);
                    try self.memAccess(instr.imm.memarg, info.log2_bytes);
                    try self.popExpect(info.t);
                    try self.popExpect(.i32);
                },
                .memory_size => {
                    if (self.mod.totalMems() == 0) return self.fail("unknown memory 0");
                    self.push(.i32);
                },
                .memory_grow => {
                    if (self.mod.totalMems() == 0) return self.fail("unknown memory 0");
                    try self.popExpect(.i32);
                    self.push(.i32);
                },
                .i32_const => self.push(.i32),
                .i64_const => self.push(.i64),
                .f32_const => self.push(.f32),
                .f64_const => self.push(.f64),
                .simd => try self.validateSimd(instr),
                .i32_eqz => try self.testop(.i32),
                .i64_eqz => try self.testop(.i64),
                .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => try self.relop(.i32),
                .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => try self.relop(.i64),
                .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => try self.relop(.f32),
                .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => try self.relop(.f64),
                .i32_clz, .i32_ctz, .i32_popcnt => try self.unop(.i32),
                .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => try self.binop(.i32),
                .i64_clz, .i64_ctz, .i64_popcnt => try self.unop(.i64),
                .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => try self.binop(.i64),
                .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => try self.unop(.f32),
                .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => try self.binop(.f32),
                .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => try self.unop(.f64),
                .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => try self.binop(.f64),
                .i32_wrap_i64 => try self.cvtop(.i64, .i32),
                .i32_trunc_f32_s, .i32_trunc_f32_u => try self.cvtop(.f32, .i32),
                .i32_trunc_f64_s, .i32_trunc_f64_u => try self.cvtop(.f64, .i32),
                .i64_extend_i32_s, .i64_extend_i32_u => try self.cvtop(.i32, .i64),
                .i64_trunc_f32_s, .i64_trunc_f32_u => try self.cvtop(.f32, .i64),
                .i64_trunc_f64_s, .i64_trunc_f64_u => try self.cvtop(.f64, .i64),
                .f32_convert_i32_s, .f32_convert_i32_u => try self.cvtop(.i32, .f32),
                .f32_convert_i64_s, .f32_convert_i64_u => try self.cvtop(.i64, .f32),
                .f32_demote_f64 => try self.cvtop(.f64, .f32),
                .f64_convert_i32_s, .f64_convert_i32_u => try self.cvtop(.i32, .f64),
                .f64_convert_i64_s, .f64_convert_i64_u => try self.cvtop(.i64, .f64),
                .f64_promote_f32 => try self.cvtop(.f32, .f64),
                .i32_reinterpret_f32 => try self.cvtop(.f32, .i32),
                .i64_reinterpret_f64 => try self.cvtop(.f64, .i64),
                .f32_reinterpret_i32 => try self.cvtop(.i32, .f32),
                .f64_reinterpret_i64 => try self.cvtop(.i64, .f64),
                .i32_extend8_s, .i32_extend16_s => try self.unop(.i32),
                .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => try self.unop(.i64),
                .i32_trunc_sat_f32_s, .i32_trunc_sat_f32_u => try self.cvtop(.f32, .i32),
                .i32_trunc_sat_f64_s, .i32_trunc_sat_f64_u => try self.cvtop(.f64, .i32),
                .i64_trunc_sat_f32_s, .i64_trunc_sat_f32_u => try self.cvtop(.f32, .i64),
                .i64_trunc_sat_f64_s, .i64_trunc_sat_f64_u => try self.cvtop(.f64, .i64),
            }
        }
        // The final `end` closed the function frame exactly at instrs.len.
        std.debug.assert(self.fr_len == 0);
    }
};

fn validateFunc(
    mod: *const types.Module,
    diag: *types.Diagnostic,
    ft: types.FuncType,
    body: types.FuncBody,
) Error!void {
    // Both stacks are bounded by the instruction count: each instruction
    // pushes at most one operand and opens at most one control frame. The
    // validate() signature carries no allocator, so use the page allocator;
    // OOM surfaces as Invalid only on truly pathological modules.
    const n = body.instrs.len + 1;
    var max_arity: usize = 1;
    for (mod.types) |signature|
        max_arity = @max(max_arity, signature.params.len, signature.results.len);
    const operand_slots = std.math.mul(usize, n, max_arity) catch
        return failMod(diag, "out of memory");
    const alloc = std.heap.page_allocator;
    const opds = alloc.alloc(StackVal, operand_slots) catch return failMod(diag, "out of memory");
    defer alloc.free(opds);
    const frames = alloc.alloc(Frame, n) catch return failMod(diag, "out of memory");
    defer alloc.free(frames);

    var v: FuncValidator = .{
        .mod = mod,
        .diag = diag,
        .params = ft.params,
        .locals = body.locals,
        .instrs = body.instrs,
        .offsets = body.offsets,
        .opds = opds,
        .frames = frames,
    };
    try v.pushFrame(.block, .{ .params = &.{}, .results = ft.results });
    try v.run();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const decode = @import("decode.zig");

const hdr = "\x00asm\x01\x00\x00\x00";

/// Comptime u32 LEB128 encoding, for hand-assembled test modules.
fn lebLen(comptime v: usize) usize {
    comptime {
        var n: usize = 1;
        var x = v;
        while (x >= 0x80) : (n += 1) x >>= 7;
        return n;
    }
}

fn lebCt(comptime v: usize) *const [lebLen(v)]u8 {
    comptime {
        var arr: [lebLen(v)]u8 = undefined;
        var x = v;
        for (&arr) |*p| {
            var b: u8 = @intCast(x & 0x7F);
            x >>= 7;
            if (x != 0) b |= 0x80;
            p.* = b;
        }
        return &arr;
    }
}

/// Comptime section wrapper: id ++ size ++ payload.
fn sec(comptime id: u8, comptime payload: []const u8) []const u8 {
    return comptime &[_]u8{id} ++ lebCt(payload.len) ++ payload;
}

/// Code-section body: size ++ locals ++ instrs.
fn codeBody(comptime locals: []const u8, comptime instrs: []const u8) []const u8 {
    return comptime lebCt(locals.len + instrs.len) ++ locals ++ instrs;
}

/// Whole code section holding one local-less function body.
fn code1(comptime instrs: []const u8) []const u8 {
    return comptime sec(10, "\x01" ++ codeBody("\x00", instrs));
}

const type_void = sec(1, "\x01\x60\x00\x00"); // () -> ()
const type_i32 = sec(1, "\x01\x60\x00\x01\x7F"); // () -> i32
const func0 = sec(3, "\x01\x00"); // one func of type 0
const table1 = sec(4, "\x01\x70\x00\x01"); // funcref min 1
const mem1 = sec(5, "\x01\x00\x01"); // min 1

fn expectValid(comptime bytes: []const u8) !void {
    return expectValidWithFeatures(bytes, .{});
}

fn expectValidWithFeatures(comptime bytes: []const u8, features: types.Features) !void {
    var diag: types.Diagnostic = .{};
    const mod = try decode.decodeWithFeatures(std.testing.allocator, bytes, features, &diag);
    defer decode.destroyModule(std.testing.allocator, mod);
    try validate(mod, &diag);
}

/// Module-level failure: message + no_offset.
fn expectInvalid(comptime bytes: []const u8, msg: []const u8) !void {
    return expectInvalidWithFeatures(bytes, .{}, msg);
}

fn expectInvalidWithFeatures(comptime bytes: []const u8, features: types.Features, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    const mod = try decode.decodeWithFeatures(std.testing.allocator, bytes, features, &diag);
    defer decode.destroyModule(std.testing.allocator, mod);
    try std.testing.expectError(error.Invalid, validate(mod, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
    try std.testing.expectEqual(types.Diagnostic.no_offset, diag.offset);
}

/// Body failure: message + the byte offset of instr `instridx` of func `funcidx`.
fn expectInvalidAt(comptime bytes: []const u8, funcidx: usize, instridx: usize, msg: []const u8) !void {
    return expectInvalidAtWithFeatures(bytes, .{}, funcidx, instridx, msg);
}

fn expectInvalidAtWithFeatures(comptime bytes: []const u8, features: types.Features, funcidx: usize, instridx: usize, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    const mod = try decode.decodeWithFeatures(std.testing.allocator, bytes, features, &diag);
    defer decode.destroyModule(std.testing.allocator, mod);
    const off = mod.code[funcidx].offsets[instridx];
    try std.testing.expectError(error.Invalid, validate(mod, &diag));
    try std.testing.expectEqualStrings(msg, diag.message());
    try std.testing.expectEqual(off, diag.offset);
}

test "wasm.validate empty module" {
    try expectValid(hdr);
}

test "wasm.validate fixed-width SIMD v128 signatures locals and control" {
    const bytes = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7B\x01\x7B") ++ // (v128) -> v128
        sec(3, "\x01\x00") ++
        sec(10, "\x01" ++ codeBody("\x01\x01\x7B", "\x02\x7B\x00\x0B\x1A\x20\x00\x0B")));
    try expectValidWithFeatures(bytes, .{ .fixed_width_simd = true });
}

test "wasm.validate fixed-width SIMD instruction signatures and immediates" {
    const zero = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const returns_vector = comptime (hdr ++
        sec(1, "\x01\x60\x00\x01\x7B") ++
        func0 ++ code1("\xFD\x0C" ++ zero ++ "\x0B"));
    try expectValidWithFeatures(returns_vector, .{ .fixed_width_simd = true });

    const bad_lane = comptime (hdr ++ type_void ++ func0 ++
        code1("\xFD\x0C" ++ zero ++ "\xFD\x15\x10\x1A\x0B"));
    try expectInvalidAtWithFeatures(bad_lane, .{ .fixed_width_simd = true }, 0, 1, "invalid lane index");

    const bad_memory_lane = comptime (hdr ++ type_void ++ func0 ++ mem1 ++
        code1("\x41\x00\xFD\x0C" ++ zero ++ "\xFD\x57\x00\x00\x02\x1A\x0B"));
    try expectInvalidAtWithFeatures(bad_memory_lane, .{ .fixed_width_simd = true }, 0, 2, "invalid lane index");

    const bad_alignment = comptime (hdr ++ type_void ++ func0 ++ mem1 ++
        code1("\x41\x00\xFD\x00\x05\x00\x1A\x0B"));
    try expectInvalidAtWithFeatures(bad_alignment, .{ .fixed_width_simd = true }, 0, 1, "alignment must not be larger than natural");

    const bad_operands = comptime (hdr ++ type_void ++ func0 ++
        code1("\x41\x00\x41\x00\xFD\x6E\x1A\x0B"));
    try expectInvalidAtWithFeatures(bad_operands, .{ .fixed_width_simd = true }, 0, 2, "type mismatch");
}

// Function 1 (type () -> i32, locals 2 x i32): block/loop/if-else results,
// br/br_if/br_table, calls (imported + recursive), call_indirect,
// loads/stores/grow/size, globals, select, unreachable-polymorphic tails.
const ks_body1 =
    "\x41\x00" ++ // i32.const 0
    "\x21\x00" ++ // local.set 0
    "\x23\x00" ++ // global.get 0 (imported immutable i32)
    "\x24\x01" ++ // global.set 1 (defined mutable i32)
    "\x41\x00" ++ // i32.const 0
    "\x41\x04" ++ // i32.const 4
    "\x36\x02\x00" ++ // i32.store align=2 offset=0
    "\x41\x00" ++ // i32.const 0
    "\x28\x02\x00" ++ // i32.load align=2 offset=0
    "\x22\x00" ++ // local.tee 0
    "\x1A" ++ // drop
    "\x3F\x00" ++ // memory.size
    "\x1A" ++ // drop
    "\x41\x01" ++ // i32.const 1
    "\x40\x00" ++ // memory.grow
    "\x1A" ++ // drop
    "\x10\x00" ++ // call 0 (imported () -> ())
    "\x02\x7F" ++ // block (result i32)
    "\x41\x07" ++ //   i32.const 7
    "\x41\x00" ++ //   i32.const 0
    "\x0D\x00" ++ //   br_if 0 (keeps the 7)
    "\x1A" ++ //   drop
    "\x03\x40" ++ //   loop
    "\x41\x01" ++ //     i32.const 1
    "\x45" ++ //       i32.eqz
    "\x0D\x00" ++ //     br_if 0 (loop: branch arity 0)
    "\x0B" ++ //   end
    "\x41\x03" ++ //   i32.const 3
    "\x41\x02" ++ //   i32.const 2
    "\x6A" ++ //     i32.add
    "\x0C\x00" ++ //   br 0
    "\x0B" ++ // end
    "\x04\x7F" ++ // if (result i32)
    "\x41\x0A" ++ //   i32.const 10
    "\x05" ++ // else
    "\x41\x14" ++ //   i32.const 20
    "\x0B" ++ // end
    "\x1A" ++ // drop
    "\x02\x40" ++ // block
    "\x02\x40" ++ //   block
    "\x02\x40" ++ //     block
    "\x41\x00" ++ //       i32.const 0
    "\x0E\x02\x00\x01\x02" ++ // br_table [0 1] default 2
    "\x0B" ++ //     end
    "\x0B" ++ //   end
    "\x0B" ++ // end
    "\x02\x7C" ++ // block (result f64)
    "\x00" ++ //   unreachable
    "\x0C\x00" ++ //   br 0 (polymorphic f64 supply)
    "\x44\x00\x00\x00\x00\x00\x00\xF0\x3F" ++ // f64.const 1.0
    "\x0B" ++ // end
    "\x1A" ++ // drop
    "\x41\x01" ++ // i32.const 1
    "\x41\x02" ++ // i32.const 2
    "\x41\x01" ++ // i32.const 1
    "\x1B" ++ // select
    "\x1A" ++ // drop
    "\x20\x00" ++ // local.get 0
    "\x42\x09" ++ // i64.const 9
    "\x41\x00" ++ // i32.const 0 (table index)
    "\x11\x01\x00" ++ // call_indirect (type 1)
    "\x1A" ++ // drop
    "\x10\x01" ++ // call 1 (recursive)
    "\x00" ++ // unreachable
    "\x6A" ++ // i32.add (polymorphic operands)
    "\x0B"; // end (func)

// Function 2 (type (i32, i64) -> i32): params as locals, i64 compare, i32 add.
const ks_body2 =
    "\x20\x00" ++ // local.get 0
    "\x20\x01" ++ // local.get 1
    "\x50" ++ // i64.eqz
    "\x6A" ++ // i32.add
    "\x44\x00\x00\x00\x00\x00\x00\xF0\x3F" ++ // f64.const 1.0
    "\x1A" ++ // drop
    "\x0B"; // end

const ks_bytes = hdr ++
    sec(1, "\x03\x60\x00\x00\x60\x02\x7F\x7E\x01\x7F\x60\x00\x01\x7F") ++ // ()->(), (i32,i64)->i32, ()->i32
    sec(2, "\x04\x01a\x01f\x00\x00" ++ // func "a"."f" : type 0
        "\x01a\x01t\x01\x70\x00\x01" ++ // table "a"."t" : funcref min 1
        "\x01a\x01m\x02\x00\x01" ++ // mem "a"."m" : min 1
        "\x01a\x01g\x03\x7F\x00") ++ // global "a"."g" : i32 const
    sec(3, "\x02\x02\x01") ++ // funcs: type 2, type 1
    sec(6, "\x01\x7F\x01\x23\x00\x0B") ++ // global: i32 mut = global.get 0
    sec(7, "\x04\x02f1\x00\x01\x01t\x01\x00\x01m\x02\x00\x01g\x03\x01") ++ // exports
    sec(8, "\x00") ++ // start: func 0 (imported, nullary)
    sec(9, "\x01\x00\x41\x00\x0B\x02\x01\x02") ++ // elem: table 0, off 0, [1 2]
    sec(10, "\x02" ++ codeBody("\x01\x02\x7F", ks_body1) ++ codeBody("\x00", ks_body2)) ++
    sec(11, "\x01\x00\x23\x00\x0B\x02AB"); // data: mem 0, off global.get 0, "AB"

test "wasm.validate kitchen sink module" {
    try expectValid(ks_bytes);
}

test "wasm.validate type mismatch on i32.add with f32 operands" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++
        code1("\x43\x00\x00\x80\x3F" ++ "\x43\x00\x00\x00\x40" ++ "\x6A\x0B"));
    try expectInvalidAt(bytes, 0, 2, "type mismatch");
}

test "wasm.validate operand stack underflow" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ code1("\x6A\x0B"));
    try expectInvalidAt(bytes, 0, 0, "type mismatch");
}

test "wasm.validate unknown local" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ code1("\x20\x00\x0B"));
    try expectInvalidAt(bytes, 0, 0, "unknown local");
}

test "wasm.validate global.set on immutable global" {
    const glob = comptime sec(6, "\x01\x7F\x00\x41\x00\x0B"); // i32 const = 0
    const bytes = comptime (hdr ++ type_void ++ func0 ++ glob ++
        code1("\x41\x01\x24\x00\x0B"));
    try expectInvalidAt(bytes, 0, 1, "global is immutable");
}

test "wasm.validate unknown global" {
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ code1("\x23\x00\x0B"), 0, 0, "unknown global");
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ code1("\x24\x00\x0B"), 0, 0, "unknown global");
}

test "wasm.validate unknown type index" {
    // Import func descriptor references type 1, but there is no type section.
    try expectInvalid(hdr ++ sec(2, "\x01\x01a\x01f\x00\x01"), "unknown type");
    // Function section references type 5.
    try expectInvalid(hdr ++ sec(3, "\x01\x05") ++ code1("\x0B"), "unknown type");
    // call_indirect references type 5 with only type 0 present.
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ table1 ++
        code1("\x41\x00\x11\x05\x00\x0B"), 0, 1, "unknown type");
}

test "wasm.validate call_indirect without table" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ code1("\x41\x00\x11\x00\x00\x0B"));
    try expectInvalidAt(bytes, 0, 1, "unknown table 0");
}

test "wasm.validate memory access without memory" {
    try expectInvalidAt(hdr ++ type_void ++ func0 ++
        code1("\x41\x00\x28\x02\x00\x1A\x0B"), 0, 1, "unknown memory 0");
    try expectInvalidAt(hdr ++ type_void ++ func0 ++
        code1("\x41\x00\x41\x01\x36\x02\x00\x0B"), 0, 2, "unknown memory 0");
}

test "wasm.validate alignment must not be larger than natural" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ mem1 ++
        code1("\x41\x00\x28\x03\x00\x1A\x0B")); // i32.load align=3: 8 > 4
    try expectInvalidAt(bytes, 0, 1, "alignment must not be larger than natural");
}

test "wasm.validate unknown label" {
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ code1("\x0C\x01\x0B"), 0, 0, "unknown label");
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ code1("\x41\x00\x0D\x02\x0B"), 0, 1, "unknown label");
    try expectInvalidAt(hdr ++ type_void ++ func0 ++
        code1("\x41\x00\x0E\x01\x00\x05\x0B"), 0, 1, "unknown label");
}

test "wasm.validate br to valued block with empty stack" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ code1("\x02\x7F\x0C\x00\x0B\x0B"));
    try expectInvalidAt(bytes, 0, 1, "type mismatch");
}

test "wasm.validate br_table arity mismatch" {
    // Inner block branches with arity 0, outer (result i32) with arity 1.
    const bytes = comptime (hdr ++ type_void ++ func0 ++
        code1("\x02\x7F\x02\x40\x41\x00\x0E\x01\x00\x01\x0B\x0B\x0B"));
    try expectInvalidAt(bytes, 0, 3, "type mismatch");
}

test "wasm.validate br_table accepts polymorphic bottom across result types" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ code1("\x02\x7C" ++ // block (result f64)
        "\x02\x7D" ++ // block (result f32)
        "\x00" ++ // unreachable: polymorphic bottom
        "\x41\x01" ++ // br_table selector
        "\x0E\x02\x00\x01\x01" ++ // targets inner/outer, default outer
        "\x0B" ++ // inner end
        "\x1A" ++ // drop f32
        "\x44\x00\x00\x00\x00\x00\x00\x00\x00" ++ // f64.const 0
        "\x0B" ++ // outer end
        "\x1A" ++ // drop f64
        "\x0B"));
    try expectValid(bytes);
}

test "wasm.validate if with result requires else" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++
        code1("\x41\x01\x04\x7F\x41\x02\x0B\x0B"));
    try expectInvalidAt(bytes, 0, 3, "type mismatch");
}

test "wasm.validate if else arms type mismatch" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++
        code1("\x41\x01\x04\x7F\x41\x02\x05\x43\x00\x00\x80\x3F\x0B\x0B"));
    try expectInvalidAt(bytes, 0, 5, "type mismatch");
}

test "wasm.validate too many values at function end" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++ code1("\x41\x01\x41\x02\x0B"));
    try expectInvalidAt(bytes, 0, 2, "type mismatch");
}

test "wasm.validate missing result at function end" {
    const bytes = comptime (hdr ++ type_i32 ++ func0 ++ code1("\x01\x0B"));
    try expectInvalidAt(bytes, 0, 1, "type mismatch");
}

test "wasm.validate duplicate export name" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++
        sec(7, "\x02\x01x\x00\x00\x01x\x00\x00") ++ code1("\x0B"));
    try expectInvalid(bytes, "duplicate export name");
}

test "wasm.validate export index out of range" {
    try expectInvalid(hdr ++ type_void ++ func0 ++
        sec(7, "\x01\x01x\x00\x01") ++ code1("\x0B"), "unknown function");
    try expectInvalid(hdr ++ sec(7, "\x01\x01w\x01\x00"), "unknown table 0");
    try expectInvalid(hdr ++ sec(7, "\x01\x01y\x02\x00"), "unknown memory 0");
    try expectInvalid(hdr ++ sec(7, "\x01\x01z\x03\x00"), "unknown global");
}

test "wasm.validate start function" {
    // Wrong type: () -> i32 is not nullary.
    try expectInvalid(hdr ++ type_i32 ++ func0 ++ sec(8, "\x00") ++
        code1("\x41\x00\x0B"), "start function must have nullary type");
    // Out of range.
    try expectInvalid(hdr ++ type_void ++ func0 ++ sec(8, "\x05") ++
        code1("\x0B"), "unknown function");
}

test "wasm.validate multiple memories" {
    try expectInvalid(hdr ++ sec(5, "\x02\x00\x01\x00\x01"), "multiple memories");
    try expectInvalid(hdr ++ sec(2, "\x01\x01a\x01m\x02\x00\x01") ++
        sec(5, "\x01\x00\x01"), "multiple memories");
}

test "wasm.validate multiple tables" {
    const defined = comptime (hdr ++ sec(4, "\x02\x70\x00\x01\x70\x00\x01"));
    try expectInvalid(defined, "multiple tables");
    try expectValidWithFeatures(defined, .{ .reference_types = true });
    try expectInvalid(hdr ++ sec(2, "\x01\x01a\x01t\x01\x70\x00\x01") ++
        sec(4, "\x01\x70\x00\x01"), "multiple tables");
}

test "wasm.validate reference values instructions and typed tables" {
    const body =
        "\xD0\x6F\x21\x00" ++ // local 0 = ref.null externref
        "\x20\x00\xD1\x1A" ++ // ref.is_null(local 0); drop
        "\x41\x00\xD0\x6F\x26\x01" ++ // table.set externref table 1
        "\x41\x00\x25\x01\xD1\x1A" ++ // table.get 1; ref.is_null; drop
        "\xD2\x00\xD0\x70\x41\x01\x1C\x01\x70\x1A" ++ // typed funcref select
        "\xD0\x70\x41\x01\xFC\x0F\x00\x1A" ++ // table.grow 0; drop old size
        "\xFC\x10\x00\x1A" ++ // table.size 0; drop
        "\x41\x00\xD0\x70\x41\x01\xFC\x11\x00" ++ // table.fill 0
        "\x41\x00\x11\x00\x00" ++ // call_indirect type 0 table 0
        "\x0B";
    const bytes = comptime hdr ++
        type_void ++ func0 ++
        sec(4, "\x02\x70\x00\x01\x6F\x00\x01") ++
        sec(6, "\x02\x70\x00\xD2\x00\x0B\x6F\x00\xD0\x6F\x0B") ++
        sec(10, "\x01" ++ codeBody("\x01\x01\x6F", body));
    try expectValidWithFeatures(bytes, .{ .reference_types = true });
}

test "wasm.validate reference instruction types and indices" {
    const tables = comptime sec(4, "\x02\x70\x00\x01\x6F\x00\x01");
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ tables ++ code1("\x41\x00\x25\x02\x1A\x0B"),
        .{ .reference_types = true },
        0,
        1,
        "unknown table",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ tables ++ code1("\x41\x00\x11\x00\x01\x0B"),
        .{ .reference_types = true },
        0,
        1,
        "type mismatch",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ tables ++ code1("\xD2\x01\x1A\x0B"),
        .{ .reference_types = true },
        0,
        0,
        "unknown function",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ tables ++ code1("\xD0\x6F\xD0\x6F\x41\x00\x1B\x1A\x0B"),
        .{ .reference_types = true },
        0,
        3,
        "type mismatch",
    );
}

test "wasm.validate ref.func requires a module-level declaration" {
    const body = comptime code1("\xD2\x00\x1A\x0B");
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ body,
        .{ .reference_types = true },
        0,
        0,
        "undeclared function reference",
    );
    try expectValidWithFeatures(
        hdr ++ type_void ++ func0 ++ table1 ++
            sec(9, "\x01\x00\x41\x00\x0B\x01\x00") ++ body,
        .{ .reference_types = true },
    );
}

test "wasm.validate bulk memory instructions and passive segments" {
    const body =
        "\x41\x00\x41\x00\x41\x01\xFC\x08\x00\x00" ++
        "\xFC\x09\x00" ++
        "\x41\x01\x41\x00\x41\x01\xFC\x0A\x00\x00" ++
        "\x41\x02\x41\x7F\x41\x01\xFC\x0B\x00" ++
        "\x41\x00\x41\x00\x41\x01\xFC\x0C\x00\x00" ++
        "\xFC\x0D\x00" ++
        "\x41\x00\x41\x00\x41\x01\xFC\x0E\x00\x00\x0B";
    const bytes = comptime hdr ++ type_void ++ func0 ++ table1 ++ mem1 ++
        sec(9, "\x01\x01\x00\x01\x00") ++
        sec(12, "\x01") ++ code1(body) ++ sec(11, "\x01\x01\x01A");
    try expectValidWithFeatures(bytes, .{ .bulk_memory = true, .reference_types = true });
}

test "wasm.validate bulk memory indices DataCount types and operands" {
    const features: types.Features = .{ .bulk_memory = true, .reference_types = true };
    try expectInvalidWithFeatures(
        hdr ++ sec(12, "\x01") ++ sec(11, "\x00"),
        features,
        "data count and data section have inconsistent lengths",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ mem1 ++
            code1("\x41\x00\x41\x00\x41\x00\xFC\x08\x00\x00\x0B") ++
            sec(11, "\x01\x01\x00"),
        features,
        0,
        3,
        "data count section required",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ mem1 ++ sec(12, "\x01") ++
            code1("\x41\x00\x41\x00\x41\x00\xFC\x08\x01\x00\x0B") ++
            sec(11, "\x01\x01\x00"),
        features,
        0,
        3,
        "unknown data segment",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ sec(4, "\x01\x6F\x00\x01") ++
            sec(9, "\x01\x01\x00\x01\x00") ++
            code1("\x41\x00\x41\x00\x41\x00\xFC\x0C\x00\x00\x0B"),
        features,
        0,
        3,
        "type mismatch",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ mem1 ++
            code1("\x41\x00\x43\x00\x00\x00\x00\x41\x00\xFC\x0B\x00\x0B"),
        features,
        0,
        3,
        "type mismatch",
    );
}

test "wasm.validate sign-extension operand types" {
    const i64_to_i32 = comptime (hdr ++ sec(1, "\x01\x60\x01\x7E\x01\x7F") ++ func0 ++ code1("\x20\x00\xC0\x0B"));
    try expectInvalidAtWithFeatures(i64_to_i32, .{ .sign_extension_ops = true }, 0, 1, "type mismatch");
}

test "wasm.validate multi-value type-index block" {
    const bytes = comptime (hdr ++
        sec(1, "\x01\x60\x00\x02\x7F\x7E") ++ func0 ++
        code1("\x02\x00\x41\x07\x42\x09\x0B\x0B"));
    try expectValidWithFeatures(bytes, .{ .multi_value = true });
}

test "wasm.validate multi-value loop parameters and branch vectors" {
    const loop = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7F\x01\x7F") ++ func0 ++
        code1("\x20\x00\x03\x00\x21\x00\x20\x00\x41\x01\x6B\x22\x00\x20\x00\x0D\x00\x0B\x0B"));
    try expectValidWithFeatures(loop, .{ .multi_value = true });

    const bad_type_index = comptime (hdr ++ type_void ++ func0 ++ code1("\x02\x01\x0B\x0B"));
    try expectInvalidAtWithFeatures(bad_type_index, .{ .multi_value = true }, 0, 0, "unknown type");
}

test "wasm.validate nontrapping conversion operand types" {
    const i32_to_i64 = comptime (hdr ++ sec(1, "\x01\x60\x01\x7F\x01\x7E") ++ func0 ++ code1("\x20\x00\xFC\x07\x0B"));
    try expectInvalidAtWithFeatures(i32_to_i64, .{ .nontrapping_float_to_int = true }, 0, 1, "type mismatch");
}

test "wasm.validate elem unknown function" {
    const bytes = comptime (hdr ++ table1 ++ sec(9, "\x01\x00\x41\x00\x0B\x01\x07"));
    try expectInvalid(bytes, "unknown function 7");
}

test "wasm.validate elem unknown table and bad offset type" {
    try expectInvalid(hdr ++ sec(9, "\x01\x00\x41\x00\x0B\x00"), "unknown table 0");
    // Offset must be an i32 constant expression.
    try expectInvalid(hdr ++ table1 ++
        sec(9, "\x01\x00\x42\x00\x0B\x00"), "type mismatch");
}

test "wasm.validate data unknown memory and bad offset type" {
    try expectInvalid(hdr ++ sec(11, "\x01\x00\x41\x00\x0B\x01A"), "unknown memory 0");
    try expectInvalid(hdr ++ mem1 ++
        sec(11, "\x01\x00\x42\x00\x0B\x01A"), "type mismatch");
}

test "wasm.validate global init type mismatch" {
    // Declared i64, initialized with i32.const.
    try expectInvalid(hdr ++ sec(6, "\x01\x7E\x00\x41\x00\x0B"), "type mismatch");
}

test "wasm.validate global init of mutable imported global" {
    const bytes = comptime (hdr ++
        sec(2, "\x01\x01a\x01g\x03\x7F\x01") ++ // import i32 mut global
        sec(6, "\x01\x7F\x00\x23\x00\x0B")); // i32 = global.get 0
    try expectInvalid(bytes, "constant expression required");
}

test "wasm.validate global init unknown global" {
    // References another defined global (index 1 is not imported).
    try expectInvalid(hdr ++
        sec(6, "\x02\x7F\x00\x23\x01\x0B\x7F\x00\x41\x00\x0B"), "unknown global");
    // Out of range entirely.
    try expectInvalid(hdr ++ sec(6, "\x01\x7F\x00\x23\x09\x0B"), "unknown global");
}

test "wasm.validate select operand mismatch" {
    const bytes = comptime (hdr ++ type_void ++ func0 ++
        code1("\x41\x01\x43\x00\x00\x80\x3F\x41\x00\x1B\x0B"));
    try expectInvalidAt(bytes, 0, 3, "type mismatch");
}

test "wasm.validate memory.grow and memory.size without memory" {
    try expectInvalidAt(hdr ++ type_void ++ func0 ++
        code1("\x41\x01\x40\x00\x1A\x0B"), 0, 1, "unknown memory 0");
    try expectInvalidAt(hdr ++ type_void ++ func0 ++
        code1("\x3F\x00\x1A\x0B"), 0, 0, "unknown memory 0");
}

test "wasm.validate unknown function call" {
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ code1("\x10\x03\x0B"), 0, 0, "unknown function");
}
