//! Strict WebAssembly MVP (wg-1.0) binary decoder.
//!
//! Produces the IR from `types.zig`. Every malformed input fails with
//! `error.Malformed` and a deterministic `(offset, message)` diagnostic;
//! allocation failure is the only other error. All module contents are
//! allocated from the module's arena, so `destroyModule` frees everything.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const DecodeError = error{ OutOfMemory, Malformed };

pub fn decode(gpa: Allocator, bytes: []const u8, diag: *types.Diagnostic) DecodeError!*types.Module {
    return decodeWithFeatures(gpa, bytes, .{}, diag);
}

pub fn decodeWithFeatures(gpa: Allocator, bytes: []const u8, features: types.Features, diag: *types.Diagnostic) DecodeError!*types.Module {
    if (features.missingDependency()) |failure| {
        diag.set(0, "WebAssembly feature {s} requires {s}", .{ failure.feature.name(), failure.required.name() });
        return error.Malformed;
    }
    const mod = try gpa.create(types.Module);
    errdefer gpa.destroy(mod);
    mod.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .features = features };
    errdefer mod.deinit();
    const a = mod.arena.allocator();

    var r: Reader = .{ .bytes = bytes, .limit = bytes.len, .diag = diag, .features = features };

    // Header: magic + version.
    const magic = try r.readBytes(4);
    if (!std.mem.eql(u8, magic, "\x00asm"))
        return r.failAt(0, "magic header not detected", .{});
    const version = try r.readBytes(4);
    if (std.mem.readInt(u32, version[0..4], .little) != 1)
        return r.failAt(4, "unknown binary version", .{});

    var custom: std.ArrayListUnmanaged(types.CustomSection) = .empty;
    var last_id: u8 = 0;
    var func_count: ?u32 = null;
    var code_count: ?u32 = null;

    while (r.pos < r.limit) {
        const sec_off = r.offset();
        const id = try r.readU8();
        const size_off = r.offset();
        const size = try r.readU32Leb();
        if (size > r.remaining())
            return r.failAt(size_off, "section size mismatch", .{});
        const saved_limit = r.limit;
        r.limit = r.pos + size;

        if (id == 0) {
            // Custom sections may appear anywhere, repeatedly.
            const name = try r.readName(a);
            const rest = try a.dupe(u8, r.bytes[r.pos..r.limit]);
            r.pos = r.limit;
            try custom.append(a, .{ .name = name, .bytes = rest, .offset = sec_off });
        } else {
            if (id > 12) return r.failAt(sec_off, "invalid section id", .{});
            if (id == 12) return r.unsupportedFeature(sec_off, .bulk_memory);
            if (id <= last_id) return r.failAt(sec_off, "unexpected content after last section", .{});
            last_id = id;
            switch (id) {
                1 => mod.types = try parseTypeSection(&r, a),
                2 => mod.imports = try parseImportSection(&r, a, mod),
                3 => {
                    mod.funcs = try parseFuncSection(&r, a);
                    func_count = @intCast(mod.funcs.len);
                },
                4 => mod.tables = try parseTableSection(&r, a),
                5 => mod.mems = try parseMemorySection(&r, a),
                6 => mod.globals = try parseGlobalSection(&r, a),
                7 => mod.exports = try parseExportSection(&r, a),
                8 => mod.start = try r.readU32Leb(),
                9 => mod.elems = try parseElemSection(&r, a),
                10 => {
                    mod.code = try parseCodeSection(&r, a);
                    code_count = @intCast(mod.code.len);
                },
                11 => mod.datas = try parseDataSection(&r, a),
                else => unreachable,
            }
            if (r.pos != r.limit)
                return r.fail("section size mismatch", .{});
        }
        r.limit = saved_limit;
    }

    const fc = func_count orelse 0;
    const cc = code_count orelse 0;
    if (fc != cc)
        return r.fail("function and code section have inconsistent lengths", .{});

    mod.custom_sections = try custom.toOwnedSlice(a);
    return mod;
}

pub fn destroyModule(gpa: Allocator, mod: *types.Module) void {
    mod.deinit();
    gpa.destroy(mod);
}

/// Cursor over the module bytes with a hard `limit` (section- or body-local
/// end) so a misdeclared size can never spill into the following bytes.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    limit: usize,
    diag: *types.Diagnostic,
    features: types.Features,

    fn offset(self: *const Reader) u32 {
        return @intCast(@min(self.pos, std.math.maxInt(u32)));
    }

    fn remaining(self: *const Reader) usize {
        return self.limit - self.pos;
    }

    fn fail(self: *Reader, comptime fmt: []const u8, args: anytype) DecodeError {
        self.diag.set(self.offset(), fmt, args);
        return error.Malformed;
    }

    fn failAt(self: *Reader, off: u32, comptime fmt: []const u8, args: anytype) DecodeError {
        self.diag.set(off, fmt, args);
        return error.Malformed;
    }

    fn unsupportedFeature(self: *Reader, off: u32, feature: types.Feature) DecodeError {
        return if (self.features.enabled(feature))
            self.failAt(off, "WebAssembly feature {s} is enabled but not implemented", .{feature.name()})
        else
            self.failAt(off, "WebAssembly feature {s} is disabled", .{feature.name()});
    }

    fn readU8(self: *Reader) DecodeError!u8 {
        if (self.pos >= self.limit) return self.fail("unexpected end", .{});
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, n: usize) DecodeError![]const u8 {
        if (n > self.remaining()) return self.fail("unexpected end", .{});
        const s = self.bytes[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    /// u32 LEB128: at most 5 bytes, unused high bits of the last byte zero.
    fn readU32Leb(self: *Reader) DecodeError!u32 {
        const start = self.offset();
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: u32 = 0;
        while (true) {
            const b = try self.readU8();
            if (i == 4) {
                if (b & 0x80 != 0) return self.failAt(start, "integer representation too long", .{});
                if (b & 0x70 != 0) return self.failAt(start, "integer too large", .{});
            }
            result |= @as(u32, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
            i += 1;
        }
        return result;
    }

    /// Signed LEB128 of `bits`-bit range; unused high bits of the last byte
    /// must be a sign-extension of the value's sign bit.
    fn readSignedLeb(self: *Reader, comptime bits: u32) DecodeError!i64 {
        const max_bytes = comptime (bits + 6) / 7;
        const last_used = comptime bits - 7 * (max_bytes - 1);
        const sign_bit: u8 = @truncate((@as(u16, 1) << @intCast(last_used - 1)));
        const rest_mask: u8 = 0x7F & ~@as(u8, @truncate((@as(u16, 1) << @intCast(last_used)) - 1));
        const start = self.offset();
        var result: i64 = 0;
        var shift: u6 = 0;
        var i: u32 = 0;
        while (true) {
            const b = try self.readU8();
            if (i == max_bytes - 1) {
                if (b & 0x80 != 0) return self.failAt(start, "integer representation too long", .{});
                if (b & sign_bit != 0) {
                    if (b & rest_mask != rest_mask) return self.failAt(start, "integer too large", .{});
                } else {
                    if (b & rest_mask != 0) return self.failAt(start, "integer too large", .{});
                }
            }
            result |= @as(i64, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
            i += 1;
        }
        const s: u32 = shift;
        if (s + 7 < 64 and (result & (@as(i64, 1) << @as(u6, @intCast(s + 6)))) != 0)
            result |= @as(i64, -1) << @as(u6, @intCast(s + 7));
        return result;
    }

    fn readI32Leb(self: *Reader) DecodeError!i32 {
        return @intCast(try self.readSignedLeb(32));
    }

    fn readI64Leb(self: *Reader) DecodeError!i64 {
        return self.readSignedLeb(64);
    }

    fn readS33(self: *Reader) DecodeError!i64 {
        return self.readSignedLeb(33);
    }

    /// Vector element count, guarded so an attacker-controlled count can
    /// never drive an allocation larger than the remaining input.
    fn readCount(self: *Reader) DecodeError!u32 {
        const off = self.offset();
        const n = try self.readU32Leb();
        if (@as(usize, n) > self.remaining())
            return self.failAt(off, "length out of bounds", .{});
        return n;
    }

    fn readName(self: *Reader, a: Allocator) DecodeError![]const u8 {
        const off = self.offset();
        const len = try self.readU32Leb();
        if (@as(usize, len) > self.remaining())
            return self.failAt(off, "length out of bounds", .{});
        const raw = self.bytes[self.pos..][0..len];
        self.pos += len;
        if (!std.unicode.utf8ValidateSlice(raw))
            return self.failAt(off, "malformed UTF-8 encoding", .{});
        return try a.dupe(u8, raw);
    }

    fn readValType(self: *Reader) DecodeError!types.ValType {
        const off = self.offset();
        const b = try self.readU8();
        return types.ValType.fromByte(b) orelse
            self.failAt(off, "invalid value type", .{});
    }

    fn readBlockType(self: *Reader) DecodeError!types.BlockType {
        const off = self.offset();
        const v = try self.readS33();
        if (v == -64) return .empty;
        if (v >= 0) {
            if (!self.features.multi_value) return self.unsupportedFeature(off, .multi_value);
            if (v > std.math.maxInt(u32)) return self.failAt(off, "invalid block type", .{});
            return .{ .type_index = @intCast(v) };
        }
        return switch (v) {
            -1 => .{ .value = .i32 },
            -2 => .{ .value = .i64 },
            -3 => .{ .value = .f32 },
            -4 => .{ .value = .f64 },
            // -16 (funcref) and anything else: not an MVP block type.
            else => self.failAt(off, "invalid block type", .{}),
        };
    }

    const LimitsKind = enum { table, memory };

    fn readLimits(self: *Reader, kind: LimitsKind) DecodeError!types.Limits {
        const flag_off = self.offset();
        const flag = try self.readU8();
        switch (flag) {
            0x00 => {
                const min_off = self.offset();
                const min = try self.readU32Leb();
                if (kind == .memory and min > types.MAX_PAGES)
                    return self.failAt(min_off, "memory size must be at most 65536 pages (4GiB)", .{});
                return .{ .min = min };
            },
            0x01 => {
                const min_off = self.offset();
                const min = try self.readU32Leb();
                if (kind == .memory and min > types.MAX_PAGES)
                    return self.failAt(min_off, "memory size must be at most 65536 pages (4GiB)", .{});
                const max_off = self.offset();
                const max = try self.readU32Leb();
                if (kind == .memory and max > types.MAX_PAGES)
                    return self.failAt(max_off, "memory size must be at most 65536 pages (4GiB)", .{});
                if (max < min)
                    return self.failAt(max_off, "size minimum must not be greater than maximum", .{});
                return .{ .min = min, .max = max };
            },
            else => {
                if (kind == .memory and flag >= 0x02 and flag <= 0x07) {
                    if (flag & 0x02 != 0 and !self.features.threads)
                        return self.unsupportedFeature(flag_off, .threads);
                    if (flag & 0x04 != 0 and !self.features.memory64)
                        return self.unsupportedFeature(flag_off, .memory64);
                    return self.unsupportedFeature(flag_off, if (flag & 0x04 != 0) .memory64 else .threads);
                }
                return self.failAt(flag_off, "unsupported limits flag", .{});
            },
        }
    }

    fn readTableType(self: *Reader) DecodeError!types.TableType {
        const et_off = self.offset();
        const et = try self.readU8();
        if (et != 0x70) return self.failAt(et_off, "invalid element type", .{});
        return .{ .limits = try self.readLimits(.table) };
    }

    fn readGlobalType(self: *Reader) DecodeError!types.GlobalType {
        const val = try self.readValType();
        const mut_off = self.offset();
        const m = try self.readU8();
        const mutable = switch (m) {
            0 => false,
            1 => true,
            else => return self.failAt(mut_off, "malformed mutability", .{}),
        };
        return .{ .val = val, .mutable = mutable };
    }

    /// MVP constant expression: exactly one constant-producing instruction
    /// followed by `end`.
    fn readConstExpr(self: *Reader) DecodeError!types.ConstExpr {
        const op_off = self.offset();
        const op = try self.readU8();
        const expr: types.ConstExpr = switch (op) {
            0x41 => .{ .i32 = try self.readI32Leb() },
            0x42 => .{ .i64 = try self.readI64Leb() },
            0x43 => .{ .f32 = std.mem.readInt(u32, (try self.readBytes(4))[0..4], .little) },
            0x44 => .{ .f64 = std.mem.readInt(u64, (try self.readBytes(8))[0..8], .little) },
            0x23 => .{ .global = try self.readU32Leb() },
            else => return self.failAt(op_off, "constant expression required", .{}),
        };
        const end_off = self.offset();
        if (try self.readU8() != 0x0B)
            return self.failAt(end_off, "constant expression required", .{});
        return expr;
    }
};

fn parseTypeSection(r: *Reader, a: Allocator) DecodeError![]const types.FuncType {
    const n = try r.readCount();
    const ts = try a.alloc(types.FuncType, n);
    for (ts) |*t| {
        const off = r.offset();
        if (try r.readU8() != 0x60)
            return r.failAt(off, "invalid function type", .{});
        const pn = try r.readCount();
        const params = try a.alloc(types.ValType, pn);
        for (params) |*p| p.* = try r.readValType();
        const res_off = r.offset();
        const rn = try r.readCount();
        const results = try a.alloc(types.ValType, rn);
        for (results) |*p| p.* = try r.readValType();
        if (rn > 1 and !r.features.multi_value)
            return r.unsupportedFeature(res_off, .multi_value);
        t.* = .{ .params = params, .results = results };
    }
    return ts;
}

fn parseImportSection(r: *Reader, a: Allocator, mod: *types.Module) DecodeError![]const types.Import {
    const n = try r.readCount();
    const imps = try a.alloc(types.Import, n);
    for (imps) |*imp| {
        const module = try r.readName(a);
        const name = try r.readName(a);
        const kind_off = r.offset();
        const kind = try r.readU8();
        const desc: types.ImportDesc = switch (kind) {
            0 => blk: {
                mod.imported_funcs += 1;
                break :blk .{ .func = try r.readU32Leb() };
            },
            1 => blk: {
                mod.imported_tables += 1;
                break :blk .{ .table = try r.readTableType() };
            },
            2 => blk: {
                mod.imported_mems += 1;
                break :blk .{ .mem = .{ .limits = try r.readLimits(.memory) } };
            },
            3 => blk: {
                mod.imported_globals += 1;
                break :blk .{ .global = try r.readGlobalType() };
            },
            else => return r.failAt(kind_off, "invalid import kind", .{}),
        };
        imp.* = .{ .module = module, .name = name, .desc = desc };
    }
    return imps;
}

fn parseFuncSection(r: *Reader, a: Allocator) DecodeError![]const u32 {
    const n = try r.readCount();
    const funcs = try a.alloc(u32, n);
    for (funcs) |*f| f.* = try r.readU32Leb();
    return funcs;
}

fn parseTableSection(r: *Reader, a: Allocator) DecodeError![]const types.TableType {
    const n = try r.readCount();
    const tables = try a.alloc(types.TableType, n);
    for (tables) |*t| t.* = try r.readTableType();
    return tables;
}

fn parseMemorySection(r: *Reader, a: Allocator) DecodeError![]const types.MemType {
    const n = try r.readCount();
    const mems = try a.alloc(types.MemType, n);
    for (mems) |*m| m.* = .{ .limits = try r.readLimits(.memory) };
    return mems;
}

fn parseGlobalSection(r: *Reader, a: Allocator) DecodeError![]const types.Global {
    const n = try r.readCount();
    const globals = try a.alloc(types.Global, n);
    for (globals) |*g| g.* = .{ .type = try r.readGlobalType(), .init = try r.readConstExpr() };
    return globals;
}

fn parseExportSection(r: *Reader, a: Allocator) DecodeError![]const types.Export {
    const n = try r.readCount();
    const exps = try a.alloc(types.Export, n);
    for (exps) |*e| {
        const name = try r.readName(a);
        const kind_off = r.offset();
        const kind: types.ExternalKind = switch (try r.readU8()) {
            0 => .func,
            1 => .table,
            2 => .mem,
            3 => .global,
            else => return r.failAt(kind_off, "invalid export kind", .{}),
        };
        e.* = .{ .name = name, .kind = kind, .index = try r.readU32Leb() };
    }
    return exps;
}

fn parseElemSection(r: *Reader, a: Allocator) DecodeError![]const types.Elem {
    const n = try r.readCount();
    const elems = try a.alloc(types.Elem, n);
    for (elems) |*e| {
        const table = try r.readU32Leb();
        const offset = try r.readConstExpr();
        const fn_count = try r.readCount();
        const funcs = try a.alloc(u32, fn_count);
        for (funcs) |*f| f.* = try r.readU32Leb();
        e.* = .{ .table = table, .offset = offset, .funcs = funcs };
    }
    return elems;
}

fn parseDataSection(r: *Reader, a: Allocator) DecodeError![]const types.Data {
    const n = try r.readCount();
    const datas = try a.alloc(types.Data, n);
    for (datas) |*d| {
        const mem = try r.readU32Leb();
        const offset = try r.readConstExpr();
        const len = try r.readCount();
        const bytes = try a.dupe(u8, try r.readBytes(len));
        d.* = .{ .mem = mem, .offset = offset, .bytes = bytes };
    }
    return datas;
}

fn parseCodeSection(r: *Reader, a: Allocator) DecodeError![]const types.FuncBody {
    const n = try r.readCount();
    const bodies = try a.alloc(types.FuncBody, n);
    for (bodies) |*body| {
        const size_off = r.offset();
        const body_size = try r.readU32Leb();
        if (body_size > r.remaining())
            return r.failAt(size_off, "unexpected end of section or function", .{});
        const saved_limit = r.limit;
        r.limit = r.pos + body_size;
        body.* = try decodeOneBody(r, a);
        if (r.pos != r.limit)
            return r.fail("junk after last expression", .{});
        r.limit = saved_limit;
    }
    return bodies;
}

fn decodeOneBody(r: *Reader, a: Allocator) DecodeError!types.FuncBody {
    // Locals: vec of (count, valtype) groups, expanded in declaration order.
    const group_count = try r.readCount();
    var locals: std.ArrayListUnmanaged(types.ValType) = .empty;
    var total: u64 = 0;
    var g: u32 = 0;
    while (g < group_count) : (g += 1) {
        const cnt_off = r.offset();
        const cnt = try r.readU32Leb();
        const t = try r.readValType();
        total += cnt;
        if (total > std.math.maxInt(u32))
            return r.failAt(cnt_off, "too many locals", .{});
        try locals.appendNTimes(a, t, cnt);
    }
    const code = try decodeInstrs(r, a);
    return .{
        .locals = try locals.toOwnedSlice(a),
        .instrs = code.instrs,
        .offsets = code.offsets,
    };
}

const ControlFrame = struct {
    op: types.Op, // block / loop / if_
    pc: u32, // instr index of the opening instruction
    seen_else: bool = false,
    else_pc: u32 = 0, // instr index of the else_ instruction
};

/// Decode one function-body expression. Emits every instruction (structured
/// control included) and patches jump targets per the contract in types.zig.
/// Returns after the `end` that terminates the function body.
fn decodeInstrs(r: *Reader, a: Allocator) DecodeError!struct { instrs: []types.Instr, offsets: []u32 } {
    var instrs: std.ArrayListUnmanaged(types.Instr) = .empty;
    var offsets: std.ArrayListUnmanaged(u32) = .empty;
    var ctrl: std.ArrayListUnmanaged(ControlFrame) = .empty;

    while (true) {
        if (r.pos >= r.limit)
            return r.fail("unexpected end of section or function", .{});
        const instr_off = r.offset();
        const b = try r.readU8();
        const op = types.Op.fromByte(b) orelse proposal: {
            if (b == 0xFB) return r.unsupportedFeature(instr_off, .gc);
            if (b == 0xFC) {
                const subopcode = try r.readU32Leb();
                if (subopcode <= 7) {
                    if (!r.features.nontrapping_float_to_int)
                        return r.unsupportedFeature(instr_off, .nontrapping_float_to_int);
                    break :proposal types.Op.fromFC(subopcode).?;
                }
                if (subopcode <= 14) return r.unsupportedFeature(instr_off, .bulk_memory);
                if (subopcode <= 17) return r.unsupportedFeature(instr_off, .reference_types);
                return r.failAt(instr_off, "invalid 0xfc subopcode {d}", .{subopcode});
            }
            if (b == 0xFD) return r.unsupportedFeature(instr_off, .fixed_width_simd);
            if (b == 0xFE) return r.unsupportedFeature(instr_off, .threads);
            if (b >= 0xC0 and b <= 0xC4) return r.unsupportedFeature(instr_off, .sign_extension_ops);
            if (b == 0x12 or b == 0x13) return r.unsupportedFeature(instr_off, .tail_calls);
            if (b == 0x14 or b == 0x15) return r.unsupportedFeature(instr_off, .typed_function_references);
            if (b == 0x06 or b == 0x07 or b == 0x08 or b == 0x09 or b == 0x18 or b == 0x19)
                return r.unsupportedFeature(instr_off, .exception_handling);
            return r.failAt(instr_off, "invalid opcode 0x{x:0>2}", .{b});
        };
        if (b >= 0xC0 and b <= 0xC4 and !r.features.sign_extension_ops)
            return r.unsupportedFeature(instr_off, .sign_extension_ops);
        var instr: types.Instr = .{ .op = op };
        switch (op) {
            .block, .loop, .if_ => {
                const bt = try r.readBlockType();
                instr.imm = .{ .block = .{ .type = bt, .else_pc = 0, .end_pc = 0 } };
                try ctrl.append(a, .{ .op = op, .pc = @intCast(instrs.items.len) });
            },
            .else_ => {
                if (ctrl.items.len == 0)
                    return r.failAt(instr_off, "else opcode without matching if", .{});
                const top = &ctrl.items[ctrl.items.len - 1];
                if (top.op != .if_ or top.seen_else)
                    return r.failAt(instr_off, "else opcode without matching if", .{});
                top.seen_else = true;
                top.else_pc = @intCast(instrs.items.len);
                instr.imm = .{ .block = .{ .type = .empty, .else_pc = 0, .end_pc = 0 } };
            },
            .end => {
                try instrs.append(a, instr);
                try offsets.append(a, instr_off);
                if (ctrl.items.len == 0) {
                    // The function body's final end terminates decoding.
                    return .{
                        .instrs = try instrs.toOwnedSlice(a),
                        .offsets = try offsets.toOwnedSlice(a),
                    };
                }
                const frame = ctrl.items[ctrl.items.len - 1];
                ctrl.items.len -= 1;
                const end_pc: u32 = @intCast(instrs.items.len);
                const open = &instrs.items[frame.pc];
                switch (frame.op) {
                    .block => {
                        open.imm.block.else_pc = end_pc;
                        open.imm.block.end_pc = end_pc;
                    },
                    .loop => {
                        open.imm.block.else_pc = frame.pc + 1;
                        open.imm.block.end_pc = end_pc;
                    },
                    .if_ => {
                        open.imm.block.end_pc = end_pc;
                        if (frame.seen_else) {
                            open.imm.block.else_pc = frame.else_pc + 1;
                            instrs.items[frame.else_pc].imm.block.end_pc = end_pc;
                        } else {
                            open.imm.block.else_pc = end_pc;
                        }
                    },
                    else => unreachable,
                }
                continue;
            },
            .br, .br_if, .call, .local_get, .local_set, .local_tee, .global_get, .global_set => {
                instr.imm = .{ .idx = try r.readU32Leb() };
            },
            .call_indirect => {
                const typeidx = try r.readU32Leb();
                const z_off = r.offset();
                if (try r.readU8() != 0x00)
                    return r.failAt(z_off, "zero byte expected", .{});
                instr.imm = .{ .idx = typeidx };
            },
            .br_table => {
                const cnt = try r.readCount();
                const targets = try a.alloc(u32, cnt);
                for (targets) |*t| t.* = try r.readU32Leb();
                instr.imm = .{ .br_table = .{ .targets = targets, .default = try r.readU32Leb() } };
            },
            .memory_size, .memory_grow => {
                const z_off = r.offset();
                if (try r.readU8() != 0x00)
                    return r.failAt(z_off, "zero byte expected", .{});
            },
            .i32_const => instr.imm = .{ .i32 = try r.readI32Leb() },
            .i64_const => instr.imm = .{ .i64 = try r.readI64Leb() },
            .f32_const => instr.imm = .{ .f32 = std.mem.readInt(u32, (try r.readBytes(4))[0..4], .little) },
            .f64_const => instr.imm = .{ .f64 = std.mem.readInt(u64, (try r.readBytes(8))[0..8], .little) },
            else => {
                const v = @intFromEnum(op);
                if (v >= 0x28 and v <= 0x3E) {
                    instr.imm = .{ .memarg = .{
                        .align_ = try r.readU32Leb(),
                        .offset = try r.readU32Leb(),
                    } };
                }
            },
        }
        try instrs.append(a, instr);
        try offsets.append(a, instr_off);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const hdr = "\x00asm\x01\x00\x00\x00";
/// Function section declaring one function of type 0 (type section is not
/// needed: decoding does not resolve indices).
const func_sec_1 = "\x03\x02\x01\x00";

fn expectMalformed(bytes: []const u8, off: u32, msg: []const u8) !void {
    return expectMalformedWithFeatures(bytes, .{}, off, msg);
}

fn expectMalformedWithFeatures(bytes: []const u8, features: types.Features, off: u32, msg: []const u8) !void {
    var diag: types.Diagnostic = .{};
    if (decodeWithFeatures(std.testing.allocator, bytes, features, &diag)) |mod| {
        destroyModule(std.testing.allocator, mod);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.Malformed, err);
        try std.testing.expectEqualStrings(msg, diag.message());
        try std.testing.expectEqual(off, diag.offset);
    }
}

test "wasm.decode empty module" {
    var diag: types.Diagnostic = .{};
    const mod = try decode(std.testing.allocator, hdr, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(@as(usize, 0), mod.types.len);
    try std.testing.expectEqual(@as(usize, 0), mod.imports.len);
    try std.testing.expectEqual(@as(usize, 0), mod.funcs.len);
    try std.testing.expectEqual(@as(usize, 0), mod.tables.len);
    try std.testing.expectEqual(@as(usize, 0), mod.mems.len);
    try std.testing.expectEqual(@as(usize, 0), mod.globals.len);
    try std.testing.expectEqual(@as(usize, 0), mod.exports.len);
    try std.testing.expectEqual(@as(?u32, null), mod.start);
    try std.testing.expectEqual(@as(usize, 0), mod.elems.len);
    try std.testing.expectEqual(@as(usize, 0), mod.datas.len);
    try std.testing.expectEqual(@as(usize, 0), mod.code.len);
    try std.testing.expectEqual(@as(usize, 0), mod.custom_sections.len);
    try std.testing.expectEqual(@as(u32, 0), mod.imported_funcs);
    try std.testing.expectEqual(@as(u32, 0), mod.imported_tables);
    try std.testing.expectEqual(@as(u32, 0), mod.imported_mems);
    try std.testing.expectEqual(@as(u32, 0), mod.imported_globals);
}

// Function body for the kitchen-sink module: 2 local groups, then an
// expression exercising nested block/loop/if-else, all const forms, a
// br_table, call_indirect, memory ops, and br.
const ks_body =
    "\x02\x02\x7F\x01\x7C" ++ // locals: (2 x i32), (1 x f64)
    "\x02\x40" ++ // 0:  block (empty)
    "\x03\x40" ++ // 1:    loop (empty)
    "\x41\x00" ++ // 2:      i32.const 0
    "\x04\x7F" ++ // 3:      if (result i32)
    "\x41\x01" ++ // 4:        i32.const 1
    "\x05" ++ // 5:      else
    "\x42\x7E" ++ // 6:        i64.const -2
    "\x1A" ++ // 7:        drop
    "\x0B" ++ // 8:      end (if)
    "\x0E\x02\x00\x01\x01" ++ // 9: br_table [0, 1] default 1
    "\x0B" ++ // 10:   end (loop)
    "\x43\x00\x00\xC0\x3F" ++ // 11: f32.const 1.5
    "\x1A" ++ // 12:   drop
    "\x44\x00\x00\x00\x00\x00\x00\x04\xC0" ++ // 13: f64.const -2.5
    "\x1A" ++ // 14:   drop
    "\x41\x00" ++ // 15:   i32.const 0
    "\x28\x02\x04" ++ // 16:   i32.load align=2 offset=4
    "\x3A\x00\x00" ++ // 17:   i32.store8 align=0 offset=0
    "\x3F\x00" ++ // 18:   memory.size
    "\x40\x00" ++ // 19:   memory.grow
    "\x1A" ++ // 20:   drop
    "\x41\x00" ++ // 21:   i32.const 0
    "\x11\x00\x00" ++ // 22:   call_indirect (type 0)
    "\x1A" ++ // 23:   drop
    "\x0C\x00" ++ // 24:   br 0
    "\x0B" ++ // 25: end (block)
    "\x41\x2A" ++ // 26: i32.const 42
    "\x0B"; // 27: end (func)

const ks_bytes = hdr ++
    "\x00\x05\x02hixy" ++ // custom "hi" = "xy"
    "\x01\x0A\x02\x60\x00\x00\x60\x02\x7F\x7E\x01\x7F" ++ // type: ()->(), (i32,i64)->i32
    "\x02\x1E\x04" ++
    "\x01\x61\x01\x66\x00\x00" ++ // import func "a"."f" : type 0
    "\x01\x61\x01\x74\x01\x70\x00\x01" ++ // import table "a"."t" : funcref min 1
    "\x01\x61\x01\x6D\x02\x01\x01\x02" ++ // import mem "a"."m" : min 1 max 2
    "\x01\x61\x01\x67\x03\x7F\x00" ++ // import global "a"."g" : i32 const
    "\x03\x02\x01\x01" ++ // func: one function of type 1
    "\x04\x05\x01\x70\x01\x01\x03" ++ // table: funcref min 1 max 3
    "\x05\x03\x01\x00\x01" ++ // memory: min 1
    "\x06\x0E\x02\x7E\x00\x42\x2A\x0B\x7D\x01\x43\x00\x00\xC0\x3F\x0B" ++ // globals
    "\x07\x11\x04\x01\x66\x00\x01\x01\x74\x01\x00\x01\x6D\x02\x00\x01\x67\x03\x00" ++ // exports
    "\x08\x01\x01" ++ // start: func 1
    "\x09\x07\x01\x00\x41\x00\x0B\x01\x01" ++ // elem: table 0, offset 0, [func 1]
    "\x0A\x45\x01\x43" ++ ks_body ++ // code
    "\x0B\x08\x01\x00\x41\x04\x0B\x02\x41\x42" ++ // data: mem 0, offset 4, "AB"
    "\x00\x04\x03zzz"; // custom "zzz" (empty payload)

test "wasm.decode kitchen sink module" {
    var diag: types.Diagnostic = .{};
    const mod = try decode(std.testing.allocator, ks_bytes, &diag);
    defer destroyModule(std.testing.allocator, mod);

    // Types.
    try std.testing.expectEqual(@as(usize, 2), mod.types.len);
    try std.testing.expectEqualDeep(&[_]types.ValType{}, mod.types[0].params);
    try std.testing.expectEqualDeep(&[_]types.ValType{}, mod.types[0].results);
    try std.testing.expectEqualDeep(&[_]types.ValType{ .i32, .i64 }, mod.types[1].params);
    try std.testing.expectEqualDeep(&[_]types.ValType{.i32}, mod.types[1].results);

    // Imports + per-kind counts.
    try std.testing.expectEqual(@as(usize, 4), mod.imports.len);
    try std.testing.expectEqualStrings("a", mod.imports[0].module);
    try std.testing.expectEqualStrings("f", mod.imports[0].name);
    try std.testing.expectEqualDeep(types.ImportDesc{ .func = 0 }, mod.imports[0].desc);
    try std.testing.expectEqualDeep(types.ImportDesc{ .table = .{ .limits = .{ .min = 1, .max = null } } }, mod.imports[1].desc);
    try std.testing.expectEqualDeep(types.ImportDesc{ .mem = .{ .limits = .{ .min = 1, .max = 2 } } }, mod.imports[2].desc);
    try std.testing.expectEqualDeep(types.ImportDesc{ .global = .{ .val = .i32, .mutable = false } }, mod.imports[3].desc);
    try std.testing.expectEqual(@as(u32, 1), mod.imported_funcs);
    try std.testing.expectEqual(@as(u32, 1), mod.imported_tables);
    try std.testing.expectEqual(@as(u32, 1), mod.imported_mems);
    try std.testing.expectEqual(@as(u32, 1), mod.imported_globals);
    try std.testing.expectEqual(@as(u32, 2), mod.totalFuncs());

    // Defined funcs/tables/mems.
    try std.testing.expectEqualDeep(&[_]u32{1}, mod.funcs);
    try std.testing.expectEqualDeep(&[_]types.TableType{.{ .limits = .{ .min = 1, .max = 3 } }}, mod.tables);
    try std.testing.expectEqualDeep(&[_]types.MemType{.{ .limits = .{ .min = 1, .max = null } }}, mod.mems);

    // Globals (types + init const-exprs).
    try std.testing.expectEqual(@as(usize, 2), mod.globals.len);
    try std.testing.expectEqualDeep(types.GlobalType{ .val = .i64, .mutable = false }, mod.globals[0].type);
    try std.testing.expectEqualDeep(types.ConstExpr{ .i64 = 42 }, mod.globals[0].init);
    try std.testing.expectEqualDeep(types.GlobalType{ .val = .f32, .mutable = true }, mod.globals[1].type);
    try std.testing.expectEqualDeep(types.ConstExpr{ .f32 = 0x3FC00000 }, mod.globals[1].init);

    // Exports.
    try std.testing.expectEqual(@as(usize, 4), mod.exports.len);
    try std.testing.expectEqualStrings("f", mod.exports[0].name);
    try std.testing.expectEqual(types.ExternalKind.func, mod.exports[0].kind);
    try std.testing.expectEqual(@as(u32, 1), mod.exports[0].index);
    try std.testing.expectEqualStrings("t", mod.exports[1].name);
    try std.testing.expectEqual(types.ExternalKind.table, mod.exports[1].kind);
    try std.testing.expectEqual(@as(u32, 0), mod.exports[1].index);
    try std.testing.expectEqualStrings("m", mod.exports[2].name);
    try std.testing.expectEqual(types.ExternalKind.mem, mod.exports[2].kind);
    try std.testing.expectEqual(@as(u32, 0), mod.exports[2].index);
    try std.testing.expectEqualStrings("g", mod.exports[3].name);
    try std.testing.expectEqual(types.ExternalKind.global, mod.exports[3].kind);
    try std.testing.expectEqual(@as(u32, 0), mod.exports[3].index);

    // Start / elem / data.
    try std.testing.expectEqual(@as(?u32, 1), mod.start);
    try std.testing.expectEqual(@as(usize, 1), mod.elems.len);
    try std.testing.expectEqual(@as(u32, 0), mod.elems[0].table);
    try std.testing.expectEqualDeep(types.ConstExpr{ .i32 = 0 }, mod.elems[0].offset);
    try std.testing.expectEqualDeep(&[_]u32{1}, mod.elems[0].funcs);
    try std.testing.expectEqual(@as(usize, 1), mod.datas.len);
    try std.testing.expectEqual(@as(u32, 0), mod.datas[0].mem);
    try std.testing.expectEqualDeep(types.ConstExpr{ .i32 = 4 }, mod.datas[0].offset);
    try std.testing.expectEqualSlices(u8, "AB", mod.datas[0].bytes);

    // Custom sections (recorded with module offsets).
    try std.testing.expectEqual(@as(usize, 2), mod.custom_sections.len);
    try std.testing.expectEqualStrings("hi", mod.custom_sections[0].name);
    try std.testing.expectEqualSlices(u8, "xy", mod.custom_sections[0].bytes);
    try std.testing.expectEqual(@as(u32, 8), mod.custom_sections[0].offset);
    try std.testing.expectEqualStrings("zzz", mod.custom_sections[1].name);
    try std.testing.expectEqual(@as(usize, 0), mod.custom_sections[1].bytes.len);
    try std.testing.expectEqual(@as(u32, @intCast(ks_bytes.len - 6)), mod.custom_sections[1].offset);

    // Code: expanded locals, instruction count, per-instruction offsets.
    try std.testing.expectEqual(@as(usize, 1), mod.code.len);
    const body = mod.code[0];
    try std.testing.expectEqualDeep(&[_]types.ValType{ .i32, .i32, .f64 }, body.locals);
    try std.testing.expectEqual(@as(usize, 28), body.instrs.len);
    try std.testing.expectEqual(@as(usize, 28), body.offsets.len);
    for (body.instrs, body.offsets) |ins, off| {
        try std.testing.expectEqual(@as(u8, @intCast(@intFromEnum(ins.op))), ks_bytes[@as(usize, off)]);
    }

    // Patched jump targets.
    try std.testing.expectEqualDeep(types.Instr.Imm{ .block = .{ .type = .empty, .else_pc = 26, .end_pc = 26 } }, body.instrs[0].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .block = .{ .type = .empty, .else_pc = 2, .end_pc = 11 } }, body.instrs[1].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .block = .{ .type = .{ .value = .i32 }, .else_pc = 6, .end_pc = 9 } }, body.instrs[3].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .block = .{ .type = .empty, .else_pc = 0, .end_pc = 9 } }, body.instrs[5].imm);
    try std.testing.expectEqual(types.Op.end, body.instrs[8].op);
    try std.testing.expectEqualDeep(types.Instr.Imm.none, body.instrs[8].imm);
    try std.testing.expectEqual(types.Op.end, body.instrs[10].op);
    try std.testing.expectEqual(types.Op.end, body.instrs[25].op);
    try std.testing.expectEqual(types.Op.end, body.instrs[27].op);

    // Immediates.
    try std.testing.expectEqualDeep(types.Instr.Imm{ .i32 = 0 }, body.instrs[2].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .i64 = -2 }, body.instrs[6].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .br_table = .{ .targets = &[_]u32{ 0, 1 }, .default = 1 } }, body.instrs[9].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .f32 = 0x3FC00000 }, body.instrs[11].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .f64 = 0xC004000000000000 }, body.instrs[13].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .memarg = .{ .align_ = 2, .offset = 4 } }, body.instrs[16].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .memarg = .{ .align_ = 0, .offset = 0 } }, body.instrs[17].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm.none, body.instrs[18].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm.none, body.instrs[19].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .idx = 0 }, body.instrs[22].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .idx = 0 }, body.instrs[24].imm);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .i32 = 42 }, body.instrs[26].imm);
}

test "wasm.decode malformed header" {
    try expectMalformed("\x00asx\x01\x00\x00\x00", 0, "magic header not detected");
    try expectMalformed("\x00asm\x02\x00\x00\x00", 4, "unknown binary version");
    try expectMalformed("\x00asm\x01", 4, "unexpected end");
    try expectMalformed("", 0, "unexpected end");
}

test "wasm.decode malformed leb128" {
    // Section size LEB cut off mid-continuation.
    try expectMalformed(hdr ++ "\x01\x80", 10, "unexpected end");
    // 6-byte u32 (continuation still set on the 5th byte).
    try expectMalformed(hdr ++ "\x01\x80\x80\x80\x80\x80\x01", 9, "integer representation too long");
    // 5th byte carries bits beyond 32.
    try expectMalformed(hdr ++ "\x01\x80\x80\x80\x80\x10", 9, "integer too large");
    // Hostile vector count (2^32-1 types, no payload).
    try expectMalformed(hdr ++ "\x01\x05\xFF\xFF\xFF\xFF\x0F", 10, "length out of bounds");
}

test "wasm.decode malformed section framing" {
    try expectMalformed(hdr ++ "\x0D\x00", 8, "invalid section id");
    try expectMalformed(hdr ++ "\x0C\x01\x00", 8, "WebAssembly feature bulk-memory is disabled");
    try expectMalformed(hdr ++ "\x01\x01\x00" ++ "\x01\x01\x00", 11, "unexpected content after last section");
    try expectMalformed(hdr ++ "\x03\x01\x00" ++ "\x01\x01\x00", 11, "unexpected content after last section");
    try expectMalformed(hdr ++ "\x01\x7F\x00", 9, "section size mismatch");
    try expectMalformed(hdr ++ "\x01\x02\x00\x00", 11, "section size mismatch");
    // Custom section payload too small for its own name.
    try expectMalformed(hdr ++ "\x00\x03\x05hi", 10, "length out of bounds");
    try expectMalformed(hdr ++ "\x00\x00", 10, "unexpected end");
}

test "wasm.decode malformed declarations" {
    // Type section: 0x7B is not a value type.
    try expectMalformed(hdr ++ "\x01\x05\x01\x60\x01\x7B\x00", 13, "invalid value type");
    // Two results = multi-value proposal.
    try expectMalformed(hdr ++ "\x01\x06\x01\x60\x00\x02\x7F\x7F", 13, "WebAssembly feature multi-value is disabled");
    // Import kind 4.
    try expectMalformed(hdr ++ "\x02\x06\x01\x01\x61\x01\x62\x04", 15, "invalid import kind");
    // Export kind 4.
    try expectMalformed(hdr ++ "\x07\x05\x01\x01\x65\x04\x00", 13, "invalid export kind");
    // Global mutability 2.
    try expectMalformed(hdr ++ "\x06\x06\x01\x7F\x02\x41\x00\x0B", 12, "malformed mutability");
    // Table element type 0x6F.
    try expectMalformed(hdr ++ "\x02\x09\x01\x01\x61\x01\x74\x01\x6F\x00\x01", 16, "invalid element type");
    // Limits flag 0x03 is shared memory with a maximum.
    try expectMalformed(hdr ++ "\x05\x02\x01\x03", 11, "WebAssembly feature threads is disabled");
    // Memory min 65537 pages.
    try expectMalformed(hdr ++ "\x05\x05\x01\x00\x81\x80\x04", 12, "memory size must be at most 65536 pages (4GiB)");
    // Memory max < min.
    try expectMalformed(hdr ++ "\x05\x04\x01\x01\x02\x01", 13, "size minimum must not be greater than maximum");
    // Table max < min.
    try expectMalformed(hdr ++ "\x04\x05\x01\x70\x01\x02\x01", 14, "size minimum must not be greater than maximum");
    // Non-UTF-8 import module name.
    try expectMalformed(hdr ++ "\x02\x07\x01\x01\xFF\x01\x62\x00\x00", 11, "malformed UTF-8 encoding");
    // Function/code section count mismatch, both directions.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x01\x00", 15, "function and code section have inconsistent lengths");
    try expectMalformed(hdr ++ "\x0A\x04\x01\x02\x00\x0B", 14, "function and code section have inconsistent lengths");
}

test "wasm.decode malformed code bodies" {
    // 0x06 is an exception-handling proposal opcode.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\x06", 17, "WebAssembly feature exception-handling is disabled");
    // Proposal prefixes.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x06\x01\x04\x00\xFC\x00\x0B", 17, "WebAssembly feature nontrapping-float-to-int is disabled");
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\xFD", 17, "WebAssembly feature fixed-width-simd is disabled");
    // call_indirect reserved byte must be zero.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x06\x01\x04\x00\x11\x00\x01", 19, "zero byte expected");
    // memory.grow reserved byte must be zero.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x40\x01", 18, "zero byte expected");
    // Non-negative block type = type index (multi-value proposal).
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x02\x01", 18, "WebAssembly feature multi-value is disabled");
    // funcref is not an MVP block type.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x02\x70", 18, "invalid block type");
    // else with an empty control stack.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\x05", 17, "else opcode without matching if");
    // Body limit reached with a block still open.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x02\x40", 19, "unexpected end of section or function");
    // Body limit reached with no final end at all.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x41\x00", 19, "unexpected end of section or function");
    // Trailing junk after the body's final end.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x0B\x01", 18, "junk after last expression");
    // Two local groups of 0xFFFFFFFF each overflow the u32 locals range.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x0F\x01\x0D\x02\xFF\xFF\xFF\xFF\x0F\x7F\xFF\xFF\xFF\xFF\x0F\x7F", 23, "too many locals");
}

test "wasm.decode feature gates distinguish disabled dependency and pending implementation" {
    try expectMalformedWithFeatures(
        hdr ++ func_sec_1 ++ "\x0A\x06\x01\x04\x00\xFC\x08\x0B",
        .{ .bulk_memory = true },
        17,
        "WebAssembly feature bulk-memory is enabled but not implemented",
    );
    try expectMalformedWithFeatures(
        hdr,
        .{ .gc = true },
        0,
        "WebAssembly feature gc requires typed-function-references",
    );
}

test "wasm.decode multi-value signatures and type-index blocks" {
    const bytes = hdr ++
        "\x01\x06\x01\x60\x00\x02\x7F\x7E" ++
        func_sec_1 ++ "\x0A\x0B\x01\x09\x00\x02\x00\x41\x07\x42\x09\x0B\x0B";
    try expectMalformed(bytes, 13, "WebAssembly feature multi-value is disabled");

    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .multi_value = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(@as(usize, 2), mod.types[0].results.len);
    try std.testing.expectEqual(types.BlockType{ .type_index = 0 }, mod.code[0].instrs[0].imm.block.type);
}

test "wasm.decode sign-extension operations require and honor their feature" {
    const bytes = hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\xC0\x0B";
    try expectMalformed(bytes, 17, "WebAssembly feature sign-extension-ops is disabled");

    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .sign_extension_ops = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(types.Op.i32_extend8_s, mod.code[0].instrs[0].op);
}

test "wasm.decode nontrapping conversions require and honor their feature" {
    const bytes = hdr ++ func_sec_1 ++ "\x0A\x06\x01\x04\x00\xFC\x07\x0B";
    try expectMalformed(bytes, 17, "WebAssembly feature nontrapping-float-to-int is disabled");

    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .nontrapping_float_to_int = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(types.Op.i64_trunc_sat_f64_u, mod.code[0].instrs[0].op);
}

test "wasm.decode malformed constant expressions" {
    // nop is not a constant expression.
    try expectMalformed(hdr ++ "\x06\x04\x01\x7F\x00\x01", 13, "constant expression required");
    // i32.const not followed by end.
    try expectMalformed(hdr ++ "\x06\x06\x01\x7F\x00\x41\x00\x01", 15, "constant expression required");
}
