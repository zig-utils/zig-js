//! Strict WebAssembly MVP (wg-1.0) binary decoder.
//!
//! Produces the IR from `types.zig`. Every malformed input fails with
//! `error.Malformed` and a deterministic `(offset, message)` diagnostic;
//! allocation failure is the only other error. All module contents are
//! allocated from the module's arena, so `destroyModule` frees everything.

const std = @import("std");
const atomic = @import("atomic.zig");
const wasm_gc = @import("gc.zig");
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
    var last_order: u8 = 0;
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
            const order = sectionOrder(id) orelse return r.failAt(sec_off, "invalid section id", .{});
            if (order <= last_order) return r.failAt(sec_off, "unexpected content after last section", .{});
            last_order = order;
            switch (id) {
                1 => {
                    const decoded = try parseTypeSection(&r, a);
                    mod.types = decoded.types;
                    mod.rec_groups = decoded.rec_groups;
                },
                2 => mod.imports = try parseImportSection(&r, a, mod),
                3 => {
                    mod.funcs = try parseFuncSection(&r, a);
                    func_count = @intCast(mod.funcs.len);
                },
                4 => mod.tables = try parseTableSection(&r, a),
                5 => mod.mems = try parseMemorySection(&r, a),
                13 => {
                    if (!features.exception_handling) return r.unsupportedFeature(sec_off, .exception_handling);
                    mod.tags = try parseTagSection(&r, a);
                },
                6 => mod.globals = try parseGlobalSection(&r, a),
                7 => mod.exports = try parseExportSection(&r, a),
                8 => mod.start = try r.readU32Leb(),
                9 => mod.elems = try parseElemSection(&r, a),
                12 => {
                    if (!features.bulk_memory) return r.unsupportedFeature(sec_off, .bulk_memory);
                    mod.data_count = try r.readU32Leb();
                },
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

fn sectionOrder(id: u8) ?u8 {
    return switch (id) {
        1...5 => id,
        13 => 6,
        6...9 => id + 1,
        12 => 11,
        10 => 12,
        11 => 13,
        else => null,
    };
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

    /// Normative unsigned 64-bit LEB128. Memory64 uses this encoding for all
    /// limits and memarg offsets, including memory32 values whose validator
    /// subsequently constrains them to the i32 address range.
    fn readU64Leb(self: *Reader) DecodeError!u64 {
        const start = self.offset();
        var result: u64 = 0;
        var shift: u6 = 0;
        var i: u32 = 0;
        while (true) {
            const b = try self.readU8();
            if (i == 9) {
                if (b & 0x80 != 0) return self.failAt(start, "integer representation too long", .{});
                if (b & 0x7E != 0) return self.failAt(start, "integer too large", .{});
            }
            result |= @as(u64, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
            i += 1;
        }
        return result;
    }

    fn readMemArg(self: *Reader) DecodeError!types.Instr.MemArg {
        const flags_off = self.offset();
        const flags = try self.readU32Leb();
        const has_memory_index = flags & 0x40 != 0;
        if (has_memory_index and !self.features.multi_memory)
            return self.unsupportedFeature(flags_off, .multi_memory);
        const memory_index = if (has_memory_index) try self.readU32Leb() else 0;
        return .{
            .align_ = if (has_memory_index) flags - 0x40 else flags,
            .offset = try self.readU64Leb(),
            .memory_index = memory_index,
        };
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
            return self.failAt(off, "invalid UTF-8 encoding", .{});
        return try a.dupe(u8, raw);
    }

    fn readValType(self: *Reader) DecodeError!types.ValType {
        const off = self.offset();
        const b = try self.readU8();
        if (b == 0x63 or b == 0x64) {
            if (!self.features.typed_function_references)
                return self.unsupportedFeature(off, .typed_function_references);
            const ref_type: types.RefType = .{
                .nullable = b == 0x63,
                .heap = try self.readHeapType(),
            };
            const value_type = types.ValType.fromRef(ref_type);
            if (value_type.isExceptionReference() and !self.features.exception_handling)
                return self.unsupportedFeature(off, .exception_handling);
            if (value_type.isAbstractGcReference() and !self.features.gc)
                return self.unsupportedFeature(off, .gc);
            return value_type;
        }
        const value_type = types.ValType.fromByte(b) orelse
            return self.failAt(off, "invalid value type", .{});
        if (value_type.isExceptionReference() and !self.features.exception_handling)
            return self.unsupportedFeature(off, .exception_handling);
        if (value_type == .v128 and !self.features.fixed_width_simd)
            return self.unsupportedFeature(off, .fixed_width_simd);
        if ((value_type == .nofuncref or value_type == .noexternref or value_type == .nullexnref) and
            !self.features.typed_function_references)
            return self.unsupportedFeature(off, .typed_function_references);
        if (value_type.isAbstractGcReference() and !self.features.gc)
            return self.unsupportedFeature(off, .gc);
        return value_type;
    }

    fn readHeapType(self: *Reader) DecodeError!types.HeapType {
        const off = self.offset();
        const encoded = try self.readS33();
        if (encoded >= 0) {
            if (encoded > std.math.maxInt(u32)) return self.failAt(off, "invalid heap type", .{});
            return types.HeapType.concrete(@intCast(encoded));
        }
        const byte_signed = encoded + 0x80;
        if (byte_signed < 0 or byte_signed > std.math.maxInt(u8))
            return self.failAt(off, "invalid heap type", .{});
        const heap = types.HeapType.fromAbstractByte(@intCast(byte_signed)) orelse
            return self.failAt(off, "invalid heap type", .{});
        if ((heap == .exn or heap == .noexn) and !self.features.exception_handling)
            return self.unsupportedFeature(off, .exception_handling);
        return heap;
    }

    fn readTag(self: *Reader) DecodeError!types.Tag {
        const attribute_off = self.offset();
        if (try self.readU8() != 0)
            return self.failAt(attribute_off, "malformed tag attribute", .{});
        return .{ .type_index = try self.readU32Leb() };
    }

    fn readBlockType(self: *Reader, a: Allocator) DecodeError!types.BlockType {
        const off = self.offset();
        if (self.pos < self.limit and (self.bytes[self.pos] == 0x63 or self.bytes[self.pos] == 0x64)) {
            const result = try a.alloc(types.ValType, 1);
            result[0] = try self.readValType();
            return .{ .explicit_value = result };
        }
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
            -5 => if (self.features.fixed_width_simd)
                .{ .value = .v128 }
            else
                self.unsupportedFeature(off, .fixed_width_simd),
            -23 => if (self.features.exception_handling)
                .{ .value = .exnref }
            else
                self.unsupportedFeature(off, .exception_handling),
            -16 => if (self.features.reference_types)
                .{ .value = .funcref }
            else
                self.unsupportedFeature(off, .reference_types),
            -17 => if (self.features.reference_types)
                .{ .value = .externref }
            else
                self.unsupportedFeature(off, .reference_types),
            else => blk: {
                const byte_signed = v + 0x80;
                if (byte_signed < 0 or byte_signed > std.math.maxInt(u8))
                    return self.failAt(off, "invalid block type", .{});
                const decoded = types.ValType.fromByte(@intCast(byte_signed)) orelse
                    return self.failAt(off, "invalid block type", .{});
                if (decoded.isExceptionReference() and !self.features.exception_handling)
                    return self.unsupportedFeature(off, .exception_handling);
                if (decoded.isAbstractGcReference() and !self.features.gc)
                    return self.unsupportedFeature(off, .gc);
                break :blk .{ .value = decoded };
            },
        };
    }

    const LimitsKind = enum { table, memory };

    const DecodedLimits = struct {
        address: types.AddressType,
        limits: types.Limits,
        shared: bool,
    };

    fn readLimits(self: *Reader, kind: LimitsKind) DecodeError!DecodedLimits {
        const flag_off = self.offset();
        const flag = try self.readU8();
        if (flag > 0x07) return self.failAt(flag_off, "unsupported limits flag", .{});
        const shared = flag & 0x02 != 0;
        const address: types.AddressType = if (flag & 0x04 != 0) .i64 else .i32;
        if (shared and kind == .table) return self.failAt(flag_off, "unsupported limits flag", .{});
        if (shared and !self.features.threads) return self.unsupportedFeature(flag_off, .threads);
        if (address == .i64 and !self.features.memory64) return self.unsupportedFeature(flag_off, .memory64);

        const min_off = self.offset();
        const min: u64 = switch (address) {
            .i32 => try self.readU32Leb(),
            .i64 => try self.readU64Leb(),
        };
        const limit = if (kind == .memory) address.maxMemoryPages() else address.maxTableElements();
        if (min > limit) return if (kind == .memory)
            self.failAt(min_off, "memory size exceeds address type limit", .{})
        else
            self.failAt(min_off, "table size exceeds address type limit", .{});
        const maximum = if (flag & 0x01 != 0) blk: {
            const max_off = self.offset();
            const max: u64 = switch (address) {
                .i32 => try self.readU32Leb(),
                .i64 => try self.readU64Leb(),
            };
            if (max > limit) return if (kind == .memory)
                self.failAt(max_off, "memory size exceeds address type limit", .{})
            else
                self.failAt(max_off, "table size exceeds address type limit", .{});
            if (max < min) return self.failAt(max_off, "size minimum must not be greater than maximum", .{});
            break :blk max;
        } else null;
        return .{ .address = address, .limits = .{ .min = min, .max = maximum }, .shared = shared };
    }

    fn readMemoryType(self: *Reader) DecodeError!types.MemType {
        const decoded = try self.readLimits(.memory);
        return .{ .address = decoded.address, .limits = decoded.limits, .shared = decoded.shared };
    }

    fn readTableType(self: *Reader) DecodeError!types.TableType {
        const et_off = self.offset();
        const elem = try self.readValType();
        if (!elem.isReference()) return self.failAt(et_off, "invalid element type", .{});
        // MVP tables admit funcref, but externref is introduced by the
        // reference-types proposal.
        if (elem == .externref and !self.features.reference_types)
            return self.unsupportedFeature(et_off, .reference_types);
        const decoded = try self.readLimits(.table);
        return .{ .address = decoded.address, .elem = elem, .limits = decoded.limits };
    }

    fn readGlobalType(self: *Reader) DecodeError!types.GlobalType {
        const val = try self.readValType();
        const mut_off = self.offset();
        const m = try self.readU8();
        const mutable = switch (m) {
            0 => false,
            1 => true,
            else => return self.failAt(mut_off, "invalid mutability", .{}),
        };
        return .{ .val = val, .mutable = mutable };
    }

    /// MVP uses exactly one constant-producing instruction. GC extends this to
    /// a typed instruction sequence; keep its decoded offsets for diagnostics.
    fn readConstExpr(self: *Reader, a: Allocator) DecodeError!types.ConstExpr {
        if (self.features.gc) {
            const decoded = try decodeInstrs(self, a);
            return .{ .extended = .{ .instrs = decoded.instrs, .offsets = decoded.offsets } };
        }
        const op_off = self.offset();
        const op = try self.readU8();
        const expr: types.ConstExpr = switch (op) {
            0x41 => .{ .i32 = try self.readI32Leb() },
            0x42 => .{ .i64 = try self.readI64Leb() },
            0x43 => .{ .f32 = std.mem.readInt(u32, (try self.readBytes(4))[0..4], .little) },
            0x44 => .{ .f64 = std.mem.readInt(u64, (try self.readBytes(8))[0..8], .little) },
            0xFD => blk: {
                if (!self.features.fixed_width_simd)
                    return self.unsupportedFeature(op_off, .fixed_width_simd);
                const subopcode_off = self.offset();
                if (try self.readU32Leb() != 0x0C)
                    return self.failAt(subopcode_off, "constant expression required", .{});
                break :blk .{ .v128 = std.mem.readInt(u128, (try self.readBytes(16))[0..16], .little) };
            },
            0x23 => .{ .global = try self.readU32Leb() },
            0xD0 => blk: {
                if (!self.features.reference_types)
                    return self.unsupportedFeature(op_off, .reference_types);
                const type_off = self.offset();
                const ref_type = types.ValType.fromRef(.{ .nullable = true, .heap = try self.readHeapType() });
                if (ref_type.isAbstractGcReference() and !self.features.gc)
                    return self.unsupportedFeature(type_off, .gc);
                break :blk .{ .ref_null = ref_type };
            },
            0xD2 => blk: {
                if (!self.features.reference_types)
                    return self.unsupportedFeature(op_off, .reference_types);
                break :blk .{ .ref_func = try self.readU32Leb() };
            },
            else => return self.failAt(op_off, "constant expression required", .{}),
        };
        const end_off = self.offset();
        if (try self.readU8() != 0x0B)
            return self.failAt(end_off, "constant expression required", .{});
        return expr;
    }
};

const DecodedTypeSection = struct {
    types: []const types.DefType,
    rec_groups: []const types.RecGroup,
};

fn readFunctionType(r: *Reader, a: Allocator) DecodeError!types.FuncType {
    const pn = try r.readCount();
    const params = try a.alloc(types.ValType, pn);
    for (params) |*param| param.* = try r.readValType();
    const res_off = r.offset();
    const rn = try r.readCount();
    const results = try a.alloc(types.ValType, rn);
    for (results) |*result| result.* = try r.readValType();
    if (rn > 1 and !r.features.multi_value)
        return r.failAt(res_off, "invalid result arity", .{});
    return .{ .params = params, .results = results };
}

fn readStorageType(r: *Reader) DecodeError!types.StorageType {
    const off = r.offset();
    if (r.pos >= r.limit) return r.fail("unexpected end", .{});
    const byte = r.bytes[r.pos];
    if (byte == 0x78 or byte == 0x77) {
        if (!r.features.gc) return r.unsupportedFeature(off, .gc);
        r.pos += 1;
        return if (byte == 0x78) .i8 else .i16;
    }
    return .{ .value = try r.readValType() };
}

fn readFieldType(r: *Reader) DecodeError!types.FieldType {
    const storage = try readStorageType(r);
    const mut_off = r.offset();
    const mutability = try r.readU8();
    if (mutability > 1) return r.failAt(mut_off, "malformed mutability", .{});
    return .{ .storage = storage, .mutable = mutability == 1 };
}

fn readCompositeType(r: *Reader, a: Allocator, first: u8, off: u32) DecodeError!types.CompositeType {
    return switch (first) {
        0x60 => .{ .func = try readFunctionType(r, a) },
        0x5F => blk: {
            if (!r.features.gc) return r.unsupportedFeature(off, .gc);
            const count = try r.readCount();
            const fields = try a.alloc(types.FieldType, count);
            for (fields) |*field| field.* = try readFieldType(r);
            break :blk .{ .struct_ = .{ .fields = fields } };
        },
        0x5E => blk: {
            if (!r.features.gc) return r.unsupportedFeature(off, .gc);
            break :blk .{ .array = .{ .field = try readFieldType(r) } };
        },
        else => r.failAt(off, "invalid composite type", .{}),
    };
}

fn readSubType(r: *Reader, a: Allocator, first: u8, off: u32) DecodeError!types.SubType {
    if (first != 0x50 and first != 0x4F) return .{
        .final = true,
        .supertypes = &.{},
        .composite = try readCompositeType(r, a, first, off),
    };
    if (!r.features.gc) return r.unsupportedFeature(off, .gc);
    const super_count = try r.readCount();
    const supertypes = try a.alloc(u32, super_count);
    for (supertypes) |*supertype| supertype.* = try r.readU32Leb();
    const composite_off = r.offset();
    const composite_byte = try r.readU8();
    return .{
        .final = first == 0x4F,
        .supertypes = supertypes,
        .composite = try readCompositeType(r, a, composite_byte, composite_off),
    };
}

fn parseTypeSection(r: *Reader, a: Allocator) DecodeError!DecodedTypeSection {
    const entry_count = try r.readCount();
    var definitions: std.ArrayListUnmanaged(types.DefType) = .empty;
    var groups: std.ArrayListUnmanaged(types.RecGroup) = .empty;
    for (0..entry_count) |_| {
        const off = r.offset();
        const first = try r.readU8();
        const group_index: u32 = @intCast(groups.items.len);
        const start: u32 = @intCast(definitions.items.len);
        if (first == 0x4E) {
            if (!r.features.gc) return r.unsupportedFeature(off, .gc);
            const count = try r.readCount();
            for (0..count) |index| {
                const subtype_off = r.offset();
                const subtype_first = try r.readU8();
                try definitions.append(a, .{
                    .rec_group = group_index,
                    .rec_index = @intCast(index),
                    .subtype = try readSubType(r, a, subtype_first, subtype_off),
                });
            }
        } else {
            try definitions.append(a, .{
                .rec_group = group_index,
                .rec_index = 0,
                .subtype = try readSubType(r, a, first, off),
            });
        }
        try groups.append(a, .{ .start = start, .len = @intCast(definitions.items.len - start) });
    }
    return .{
        .types = try definitions.toOwnedSlice(a),
        .rec_groups = try groups.toOwnedSlice(a),
    };
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
                break :blk .{ .mem = try r.readMemoryType() };
            },
            3 => blk: {
                mod.imported_globals += 1;
                break :blk .{ .global = try r.readGlobalType() };
            },
            4 => blk: {
                if (!r.features.exception_handling) return r.unsupportedFeature(kind_off, .exception_handling);
                mod.imported_tags += 1;
                break :blk .{ .tag = try r.readTag() };
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
    for (tables) |*t| {
        if (r.features.typed_function_references and r.pos < r.limit and r.bytes[r.pos] == 0x40) {
            const marker_off = r.offset();
            _ = try r.readU8();
            if (try r.readU8() != 0)
                return r.failAt(marker_off, "zero flag expected", .{});
            t.* = try r.readTableType();
            t.init = try r.readConstExpr(a);
        } else {
            t.* = try r.readTableType();
        }
    }
    return tables;
}

fn parseMemorySection(r: *Reader, a: Allocator) DecodeError![]const types.MemType {
    const n = try r.readCount();
    const mems = try a.alloc(types.MemType, n);
    for (mems) |*m| m.* = try r.readMemoryType();
    return mems;
}

fn parseTagSection(r: *Reader, a: Allocator) DecodeError![]const types.Tag {
    const n = try r.readCount();
    const tags = try a.alloc(types.Tag, n);
    for (tags) |*tag| tag.* = try r.readTag();
    return tags;
}

fn parseGlobalSection(r: *Reader, a: Allocator) DecodeError![]const types.Global {
    const n = try r.readCount();
    const globals = try a.alloc(types.Global, n);
    for (globals) |*g| g.* = .{ .type = try r.readGlobalType(), .init = try r.readConstExpr(a) };
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
            4 => if (r.features.exception_handling) .tag else return r.unsupportedFeature(kind_off, .exception_handling),
            else => return r.failAt(kind_off, "invalid export kind", .{}),
        };
        e.* = .{ .name = name, .kind = kind, .index = try r.readU32Leb() };
    }
    return exps;
}

fn parseElemSection(r: *Reader, a: Allocator) DecodeError![]const types.Elem {
    const legacy_func_type = types.ValType.fromRef(.{ .nullable = false, .heap = .func });
    const n = try r.readCount();
    const elems = try a.alloc(types.Elem, n);
    for (elems) |*e| {
        const kind_off = r.offset();
        const kind = try r.readU32Leb();
        e.* = switch (kind) {
            0 => .{
                .type = legacy_func_type,
                .mode = .{ .active = .{ .table = 0, .offset = try r.readConstExpr(a) } },
                .init = try readFuncElemInit(r, a),
                .legacy_func_indices = true,
            },
            1 => blk: {
                if (!r.features.bulk_memory) return r.unsupportedFeature(kind_off, .bulk_memory);
                try readElemKind(r);
                break :blk .{
                    .type = legacy_func_type,
                    .mode = .passive,
                    .init = try readFuncElemInit(r, a),
                    .legacy_func_indices = true,
                };
            },
            2 => blk: {
                if (!r.features.bulk_memory) return r.unsupportedFeature(kind_off, .bulk_memory);
                const table = try r.readU32Leb();
                const offset = try r.readConstExpr(a);
                try readElemKind(r);
                break :blk .{
                    .type = legacy_func_type,
                    .mode = .{ .active = .{ .table = table, .offset = offset } },
                    .init = try readFuncElemInit(r, a),
                    .legacy_func_indices = true,
                };
            },
            3 => blk: {
                if (!r.features.bulk_memory) return r.unsupportedFeature(kind_off, .bulk_memory);
                try readElemKind(r);
                break :blk .{
                    .type = legacy_func_type,
                    .mode = .declarative,
                    .init = try readFuncElemInit(r, a),
                    .legacy_func_indices = true,
                };
            },
            4 => blk: {
                if (!r.features.reference_types) return r.unsupportedFeature(kind_off, .reference_types);
                break :blk .{
                    .type = .funcref,
                    .mode = .{ .active = .{ .table = 0, .offset = try r.readConstExpr(a) } },
                    .init = try readExprElemInit(r, a),
                };
            },
            5 => blk: {
                if (!r.features.reference_types) return r.unsupportedFeature(kind_off, .reference_types);
                const elem_type = try r.readValType();
                if (!elem_type.isReference()) return r.failAt(kind_off, "reference type expected", .{});
                break :blk .{ .type = elem_type, .mode = .passive, .init = try readExprElemInit(r, a) };
            },
            6 => blk: {
                if (!r.features.reference_types) return r.unsupportedFeature(kind_off, .reference_types);
                const table = try r.readU32Leb();
                const offset = try r.readConstExpr(a);
                const elem_type = try r.readValType();
                if (!elem_type.isReference()) return r.failAt(kind_off, "reference type expected", .{});
                break :blk .{
                    .type = elem_type,
                    .mode = .{ .active = .{ .table = table, .offset = offset } },
                    .init = try readExprElemInit(r, a),
                };
            },
            7 => blk: {
                if (!r.features.reference_types) return r.unsupportedFeature(kind_off, .reference_types);
                const elem_type = try r.readValType();
                if (!elem_type.isReference()) return r.failAt(kind_off, "reference type expected", .{});
                break :blk .{ .type = elem_type, .mode = .declarative, .init = try readExprElemInit(r, a) };
            },
            else => return r.failAt(kind_off, "malformed element segment kind", .{}),
        };
    }
    return elems;
}

fn readElemKind(r: *Reader) DecodeError!void {
    const off = r.offset();
    if (try r.readU8() != 0) return r.failAt(off, "malformed element kind", .{});
}

fn readFuncElemInit(r: *Reader, a: Allocator) DecodeError![]const types.ConstExpr {
    const count = try r.readCount();
    const init = try a.alloc(types.ConstExpr, count);
    for (init) |*entry| entry.* = .{ .ref_func = try r.readU32Leb() };
    return init;
}

fn readExprElemInit(r: *Reader, a: Allocator) DecodeError![]const types.ConstExpr {
    const count = try r.readCount();
    const init = try a.alloc(types.ConstExpr, count);
    for (init) |*entry| entry.* = try r.readConstExpr(a);
    return init;
}

fn parseDataSection(r: *Reader, a: Allocator) DecodeError![]const types.Data {
    const n = try r.readCount();
    const datas = try a.alloc(types.Data, n);
    for (datas) |*d| {
        const kind_off = r.offset();
        const kind = try r.readU32Leb();
        const mode: types.DataMode = switch (kind) {
            0 => .{ .active = .{ .mem = 0, .offset = try r.readConstExpr(a) } },
            1 => blk: {
                if (!r.features.bulk_memory) return r.unsupportedFeature(kind_off, .bulk_memory);
                break :blk .passive;
            },
            2 => blk: {
                if (!r.features.bulk_memory) return r.unsupportedFeature(kind_off, .bulk_memory);
                break :blk .{ .active = .{ .mem = try r.readU32Leb(), .offset = try r.readConstExpr(a) } };
            },
            else => return r.failAt(kind_off, "malformed data segment kind", .{}),
        };
        const len = try r.readCount();
        const bytes = try a.dupe(u8, try r.readBytes(len));
        d.* = .{ .mode = mode, .bytes = bytes };
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
    // Parse and bound every declaration before expanding any group. A hostile
    // first count may fit u32 by itself but must not force a multi-gigabyte
    // allocation before a later group proves the total malformed.
    const LocalDecl = struct { count: u32, value_type: types.ValType };
    const group_count = try r.readCount();
    var groups: std.ArrayListUnmanaged(LocalDecl) = .empty;
    defer groups.deinit(a);
    var total: u64 = 0;
    var g: u32 = 0;
    while (g < group_count) : (g += 1) {
        const cnt_off = r.offset();
        const cnt = try r.readU32Leb();
        const t = try r.readValType();
        total += cnt;
        if (total > std.math.maxInt(u32))
            return r.failAt(cnt_off, "too many locals", .{});
        try groups.append(a, .{ .count = cnt, .value_type = t });
    }
    const locals = try a.alloc(types.ValType, @intCast(total));
    errdefer a.free(locals);
    var start: usize = 0;
    for (groups.items) |group| {
        const end = start + group.count;
        @memset(locals[start..end], group.value_type);
        start = end;
    }
    const code = try decodeInstrs(r, a);
    return .{
        .locals = locals,
        .instrs = code.instrs,
        .offsets = code.offsets,
    };
}

const ControlFrame = struct {
    op: types.Op, // block / loop / if_ / try_table
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
                if (subopcode <= 14) {
                    if (!r.features.bulk_memory)
                        return r.unsupportedFeature(instr_off, .bulk_memory);
                    break :proposal types.Op.fromFC(subopcode).?;
                }
                if (subopcode <= 17) {
                    if (!r.features.reference_types)
                        return r.unsupportedFeature(instr_off, .reference_types);
                    break :proposal types.Op.fromFC(subopcode).?;
                }
                return r.failAt(instr_off, "invalid 0xfc subopcode {d}", .{subopcode});
            }
            if (b == 0xFD) {
                if (!r.features.fixed_width_simd)
                    return r.unsupportedFeature(instr_off, .fixed_width_simd);
                break :proposal .simd;
            }
            if (b == 0xFE) return r.unsupportedFeature(instr_off, .threads);
            if (b >= 0xC0 and b <= 0xC4) return r.unsupportedFeature(instr_off, .sign_extension_ops);
            return r.failAt(instr_off, "invalid opcode 0x{x:0>2}", .{b});
        };
        if (b >= 0xC0 and b <= 0xC4 and !r.features.sign_extension_ops)
            return r.unsupportedFeature(instr_off, .sign_extension_ops);
        if (op == .simd and !r.features.fixed_width_simd)
            return r.unsupportedFeature(instr_off, .fixed_width_simd);
        if (op == .atomic and !r.features.threads)
            return r.unsupportedFeature(instr_off, .threads);
        if ((op == .return_call or op == .return_call_indirect or op == .return_call_ref) and !r.features.tail_calls)
            return r.unsupportedFeature(instr_off, .tail_calls);
        if ((op == .throw or op == .throw_ref or op == .try_table) and !r.features.exception_handling)
            return r.unsupportedFeature(instr_off, .exception_handling);
        if ((op == .gc or op == .ref_eq or op == .ref_as_non_null) and !r.features.gc)
            return r.unsupportedFeature(instr_off, .gc);
        if ((op == .br_on_null or op == .br_on_non_null or op == .call_ref or op == .return_call_ref) and
            !r.features.typed_function_references)
            return r.unsupportedFeature(instr_off, .typed_function_references);
        if ((op == .typed_select or op == .table_get or op == .table_set or
            op == .ref_null or op == .ref_is_null or op == .ref_func or
            op == .table_grow or op == .table_size or op == .table_fill) and
            !r.features.reference_types)
            return r.unsupportedFeature(instr_off, .reference_types);
        var instr: types.Instr = .{ .op = op };
        switch (op) {
            .block, .loop, .if_ => {
                const bt = try r.readBlockType(a);
                instr.imm = .{ .block = .{ .type = bt, .else_pc = 0, .end_pc = 0 } };
                try ctrl.append(a, .{ .op = op, .pc = @intCast(instrs.items.len) });
            },
            .try_table => {
                const block_type = try r.readBlockType(a);
                const catch_count = try r.readCount();
                const catches = try a.alloc(types.Instr.Catch, catch_count);
                for (catches) |*catch_clause| {
                    const kind_off = r.offset();
                    catch_clause.* = switch (try r.readU8()) {
                        0 => .{ .catch_tag = .{
                            .tag_index = try r.readU32Leb(),
                            .label_index = try r.readU32Leb(),
                        } },
                        1 => .{ .catch_ref = .{
                            .tag_index = try r.readU32Leb(),
                            .label_index = try r.readU32Leb(),
                        } },
                        2 => .{ .catch_all = try r.readU32Leb() },
                        3 => .{ .catch_all_ref = try r.readU32Leb() },
                        else => return r.failAt(kind_off, "invalid catch kind", .{}),
                    };
                }
                instr.imm = .{ .try_table = .{
                    .block = .{ .type = block_type, .else_pc = 0, .end_pc = 0 },
                    .catches = catches,
                } };
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
                    .block, .try_table => {
                        const block = if (frame.op == .block)
                            &open.imm.block
                        else
                            &open.imm.try_table.block;
                        block.else_pc = end_pc;
                        block.end_pc = end_pc;
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
            .br,
            .br_if,
            .br_on_null,
            .br_on_non_null,
            .call,
            .return_call,
            .call_ref,
            .return_call_ref,
            .throw,
            .local_get,
            .local_set,
            .local_tee,
            .global_get,
            .global_set,
            .table_get,
            .table_set,
            .ref_func,
            .table_grow,
            .table_size,
            .table_fill,
            .data_drop,
            .memory_fill,
            .elem_drop,
            => {
                instr.imm = .{ .idx = try r.readU32Leb() };
            },
            .memory_init, .memory_copy, .table_init, .table_copy => {
                instr.imm = .{ .indices = .{
                    .first = try r.readU32Leb(),
                    .second = try r.readU32Leb(),
                } };
            },
            .call_indirect => {
                const typeidx = try r.readU32Leb();
                const tableidx = if (r.features.reference_types)
                    try r.readU32Leb()
                else blk: {
                    const z_off = r.offset();
                    if (try r.readU8() != 0x00)
                        return r.failAt(z_off, "zero flag expected", .{});
                    break :blk 0;
                };
                instr.imm = .{ .call_indirect = .{ .type_index = typeidx, .table_index = tableidx } };
            },
            .return_call_indirect => {
                // The pinned tail-call binary grammar always encodes both
                // typeidx and tableidx, in that order.
                instr.imm = .{ .call_indirect = .{
                    .type_index = try r.readU32Leb(),
                    .table_index = try r.readU32Leb(),
                } };
            },
            .typed_select => {
                const count_off = r.offset();
                const count = try r.readU32Leb();
                if (count != 1) return r.failAt(count_off, "typed select requires exactly one result type", .{});
                instr.imm = .{ .type = try r.readValType() };
            },
            .ref_null => {
                const type_off = r.offset();
                // The selected exception proposal retains its exnref immediate
                // alongside GC's heap-type form.
                if (r.pos < r.limit and r.bytes[r.pos] == @intFromEnum(types.ValType.exnref)) {
                    if (!r.features.exception_handling)
                        return r.unsupportedFeature(type_off, .exception_handling);
                    r.pos += 1;
                    instr.imm = .{ .type = .exnref };
                } else {
                    const heap = try r.readHeapType();
                    const ref_type = types.ValType.fromRef(.{ .nullable = true, .heap = heap });
                    if (ref_type.isAbstractGcReference() and !r.features.gc)
                        return r.unsupportedFeature(type_off, .gc);
                    instr.imm = .{ .type = ref_type };
                }
            },
            .br_table => {
                const cnt = try r.readCount();
                const targets = try a.alloc(u32, cnt);
                for (targets) |*t| t.* = try r.readU32Leb();
                instr.imm = .{ .br_table = .{ .targets = targets, .default = try r.readU32Leb() } };
            },
            .memory_size, .memory_grow => {
                if (r.features.multi_memory) {
                    instr.imm = .{ .idx = try r.readU32Leb() };
                } else {
                    const z_off = r.offset();
                    if (try r.readU8() != 0x00)
                        return r.failAt(z_off, "zero flag expected", .{});
                }
            },
            .i32_const => instr.imm = .{ .i32 = try r.readI32Leb() },
            .i64_const => instr.imm = .{ .i64 = try r.readI64Leb() },
            .f32_const => instr.imm = .{ .f32 = std.mem.readInt(u32, (try r.readBytes(4))[0..4], .little) },
            .f64_const => instr.imm = .{ .f64 = std.mem.readInt(u64, (try r.readBytes(8))[0..8], .little) },
            .gc => {
                const subopcode_off = r.offset();
                const gc_op = wasm_gc.Op.fromSubopcode(try r.readU32Leb()) orelse
                    return r.failAt(subopcode_off, "invalid 0xfb subopcode", .{});
                switch (gc_op.immediate()) {
                    .none => instr.imm = .{ .gc = gc_op },
                    .type_index => instr.imm = .{ .gc_type = .{
                        .op = gc_op,
                        .type_index = try r.readU32Leb(),
                    } },
                    .type_field => instr.imm = .{ .gc_type_field = .{
                        .op = gc_op,
                        .type_index = try r.readU32Leb(),
                        .field_index = try r.readU32Leb(),
                    } },
                    .type_count, .two_indices => instr.imm = .{ .gc_two_indices = .{
                        .op = gc_op,
                        .first = try r.readU32Leb(),
                        .second = try r.readU32Leb(),
                    } },
                    .heap_type => instr.imm = .{ .gc_heap = .{
                        .op = gc_op,
                        .heap = try r.readHeapType(),
                    } },
                    .cast_branch => {
                        const flags_off = r.offset();
                        const flags = try r.readU8();
                        if (flags > 3) return r.failAt(flags_off, "malformed cast flags", .{});
                        instr.imm = .{ .gc_cast_branch = .{
                            .op = gc_op,
                            .source_nullable = flags & 1 != 0,
                            .target_nullable = flags & 2 != 0,
                            .label_index = try r.readU32Leb(),
                            .source_heap = try r.readHeapType(),
                            .target_heap = try r.readHeapType(),
                        } };
                    },
                }
            },
            .simd => {
                const subopcode_off = r.offset();
                const simd_op = @import("simd.zig").Op.fromSubopcode(try r.readU32Leb()) orelse
                    return r.failAt(subopcode_off, "invalid 0xfd subopcode", .{});
                if (simd_op.isRelaxed() and !r.features.relaxed_simd)
                    return r.unsupportedFeature(subopcode_off, .relaxed_simd);
                switch (simd_op.immediate()) {
                    .none => instr.imm = .{ .simd = simd_op },
                    .memarg => instr.imm = .{ .simd_memarg = .{ .op = simd_op, .memarg = try r.readMemArg() } },
                    .v128 => instr.imm = .{ .simd_v128 = .{
                        .op = simd_op,
                        .bits = std.mem.readInt(u128, (try r.readBytes(16))[0..16], .little),
                    } },
                    .lane16 => {
                        var lanes: [16]u8 = undefined;
                        @memcpy(&lanes, try r.readBytes(16));
                        instr.imm = .{ .simd_shuffle = .{ .op = simd_op, .lanes = lanes } };
                    },
                    .lane => instr.imm = .{ .simd_lane = .{ .op = simd_op, .lane = try r.readU8() } },
                    .memarg_lane => instr.imm = .{ .simd_memarg_lane = .{
                        .op = simd_op,
                        .memarg = try r.readMemArg(),
                        .lane = try r.readU8(),
                    } },
                }
            },
            .atomic => {
                const subopcode_off = r.offset();
                const atomic_op = atomic.Op.fromSubopcode(try r.readU32Leb()) orelse
                    return r.failAt(subopcode_off, "invalid 0xfe subopcode", .{});
                switch (atomic_op.immediate()) {
                    .memarg => instr.imm = .{ .atomic_memarg = .{
                        .op = atomic_op,
                        .memarg = try r.readMemArg(),
                    } },
                    .fence => {
                        const reserved_off = r.offset();
                        if (try r.readU8() != 0)
                            return r.failAt(reserved_off, "zero flag expected", .{});
                        instr.imm = .{ .atomic = atomic_op };
                    },
                }
            },
            else => {
                const v = @intFromEnum(op);
                if (v >= 0x28 and v <= 0x3E) {
                    instr.imm = .{ .memarg = try r.readMemArg() };
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

fn testLebLen(comptime v: usize) usize {
    comptime {
        var n: usize = 1;
        var x = v;
        while (x >= 0x80) : (n += 1) x >>= 7;
        return n;
    }
}

fn testLeb(comptime v: usize) *const [testLebLen(v)]u8 {
    comptime {
        var bytes: [testLebLen(v)]u8 = undefined;
        var x = v;
        for (&bytes) |*byte| {
            byte.* = @intCast(x & 0x7F);
            x >>= 7;
            if (x != 0) byte.* |= 0x80;
        }
        return &bytes;
    }
}

fn testSection(comptime id: u8, comptime payload: []const u8) []const u8 {
    return comptime &[_]u8{id} ++ testLeb(payload.len) ++ payload;
}

fn testCode(comptime instrs: []const u8) []const u8 {
    const body = comptime "\x00" ++ instrs;
    return comptime testSection(10, "\x01" ++ testLeb(body.len) ++ body);
}

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
    try std.testing.expectEqual(@as(?u32, null), mod.data_count);
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
    try std.testing.expectEqualDeep(&[_]types.ValType{}, mod.types[0].funcType().?.params);
    try std.testing.expectEqualDeep(&[_]types.ValType{}, mod.types[0].funcType().?.results);
    try std.testing.expectEqualDeep(&[_]types.ValType{ .i32, .i64 }, mod.types[1].funcType().?.params);
    try std.testing.expectEqualDeep(&[_]types.ValType{.i32}, mod.types[1].funcType().?.results);

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
    try std.testing.expectEqual(
        types.ValType.fromRef(.{ .nullable = false, .heap = .func }),
        mod.elems[0].type,
    );
    try std.testing.expect(mod.elems[0].legacy_func_indices);
    const elem_active = mod.elems[0].mode.active;
    try std.testing.expectEqual(@as(u32, 0), elem_active.table);
    try std.testing.expectEqualDeep(types.ConstExpr{ .i32 = 0 }, elem_active.offset);
    try std.testing.expectEqualDeep(&[_]types.ConstExpr{.{ .ref_func = 1 }}, mod.elems[0].init);
    try std.testing.expectEqual(@as(usize, 1), mod.datas.len);
    const data_active = mod.datas[0].mode.active;
    try std.testing.expectEqual(@as(u32, 0), data_active.mem);
    try std.testing.expectEqualDeep(types.ConstExpr{ .i32 = 4 }, data_active.offset);
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
    try std.testing.expectEqualDeep(
        types.Instr.Imm{ .call_indirect = .{ .type_index = 0, .table_index = 0 } },
        body.instrs[22].imm,
    );
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
    try expectMalformed(hdr ++ "\x0D\x00", 8, "WebAssembly feature exception-handling is disabled");
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
    // v128 is feature-gated in value positions.
    try expectMalformed(hdr ++ "\x01\x05\x01\x60\x01\x7B\x00", 13, "WebAssembly feature fixed-width-simd is disabled");
    // Two results = multi-value proposal.
    try expectMalformed(hdr ++ "\x01\x06\x01\x60\x00\x02\x7F\x7F", 13, "invalid result arity");
    // Exception-handling exnref and tag external kind are exact feature gates.
    try expectMalformed(hdr ++ "\x01\x05\x01\x60\x01\x69\x00", 13, "WebAssembly feature exception-handling is disabled");
    try expectMalformed(hdr ++ "\x02\x06\x01\x01\x61\x01\x62\x04", 15, "WebAssembly feature exception-handling is disabled");
    try expectMalformed(hdr ++ "\x07\x05\x01\x01\x65\x04\x00", 13, "WebAssembly feature exception-handling is disabled");
    // Global mutability 2.
    try expectMalformed(hdr ++ "\x06\x06\x01\x7F\x02\x41\x00\x0B", 12, "invalid mutability");
    // Table element type 0x6F.
    try expectMalformed(hdr ++ "\x02\x09\x01\x01\x61\x01\x74\x01\x6F\x00\x01", 16, "WebAssembly feature reference-types is disabled");
    // Limits flag 0x03 is shared memory with a maximum.
    try expectMalformed(hdr ++ "\x05\x02\x01\x03", 11, "WebAssembly feature threads is disabled");
    // Memory min 65537 pages.
    try expectMalformed(hdr ++ "\x05\x05\x01\x00\x81\x80\x04", 12, "memory size exceeds address type limit");
    // Memory max < min.
    try expectMalformed(hdr ++ "\x05\x04\x01\x01\x02\x01", 13, "size minimum must not be greater than maximum");
    // Table max < min.
    try expectMalformed(hdr ++ "\x04\x05\x01\x70\x01\x02\x01", 14, "size minimum must not be greater than maximum");
    // Non-UTF-8 import module name.
    try expectMalformed(hdr ++ "\x02\x07\x01\x01\xFF\x01\x62\x00\x00", 11, "invalid UTF-8 encoding");
    // Function/code section count mismatch, both directions.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x01\x00", 15, "function and code section have inconsistent lengths");
    try expectMalformed(hdr ++ "\x0A\x04\x01\x02\x00\x0B", 14, "function and code section have inconsistent lengths");
}

test "wasm.decode threads shared limits and atomic immediates" {
    var diag: types.Diagnostic = .{};
    const shared = try decodeWithFeatures(
        std.testing.allocator,
        hdr ++ "\x05\x04\x01\x03\x01\x02",
        .{ .threads = true },
        &diag,
    );
    defer destroyModule(std.testing.allocator, shared);
    try std.testing.expectEqualDeep(
        types.MemType{ .limits = .{ .min = 1, .max = 2 }, .shared = true },
        shared.mems[0],
    );

    const atomic_module = hdr ++
        "\x01\x06\x01\x60\x01\x7F\x01\x7F" ++
        "\x03\x02\x01\x00" ++
        "\x05\x04\x01\x03\x01\x01" ++
        "\x0A\x0A\x01\x08\x00\x20\x00\xFE\x10\x02\x00\x0B";
    const decoded = try decodeWithFeatures(std.testing.allocator, atomic_module, .{ .threads = true }, &diag);
    defer destroyModule(std.testing.allocator, decoded);
    const immediate = decoded.code[0].instrs[1].imm.atomic_memarg;
    try std.testing.expectEqual(atomic.Op.i32_atomic_load, immediate.op);
    try std.testing.expectEqualDeep(types.Instr.MemArg{ .align_ = 2, .offset = 0 }, immediate.memarg);

    const fence_module = hdr ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x03\x02\x01\x00" ++
        "\x0A\x07\x01\x05\x00\xFE\x03\x00\x0B";
    const fence = try decodeWithFeatures(std.testing.allocator, fence_module, .{ .threads = true }, &diag);
    defer destroyModule(std.testing.allocator, fence);
    try std.testing.expectEqual(atomic.Op.memory_atomic_fence, fence.code[0].instrs[0].imm.atomic);

    try expectMalformedWithFeatures(
        fence_module[0 .. fence_module.len - 2] ++ "\x01\x0B",
        .{ .threads = true },
        fence_module.len - 2,
        "zero flag expected",
    );
    try expectMalformedWithFeatures(
        hdr ++ func_sec_1 ++ "\x0A\x07\x01\x05\x00\xFE\x04\x00\x0B",
        .{ .threads = true },
        18,
        "invalid 0xfe subopcode",
    );
}

test "wasm.decode memory64 limits table64 and u64 memarg offsets" {
    const offset_4g = "\x80\x80\x80\x80\x10";
    const bytes = comptime (hdr ++
        func_sec_1 ++
        testSection(4, "\x01\x70\x05\x01\x82\x01") ++
        testSection(5, "\x01\x05\x01\x82\x01") ++
        testCode("\x42\x00\x28\x02" ++ offset_4g ++ "\x0B"));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .memory64 = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);

    try std.testing.expectEqual(types.AddressType.i64, mod.tables[0].address);
    try std.testing.expectEqualDeep(types.Limits{ .min = 1, .max = 130 }, mod.tables[0].limits);
    try std.testing.expectEqual(types.AddressType.i64, mod.mems[0].address);
    try std.testing.expectEqualDeep(types.Limits{ .min = 1, .max = 130 }, mod.mems[0].limits);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), mod.code[0].instrs[1].imm.memarg.offset);
}

test "wasm.decode memory64 feature gates and malformed u64 limits" {
    try expectMalformed(
        comptime (hdr ++ testSection(5, "\x01\x04\x01")),
        11,
        "WebAssembly feature memory64 is disabled",
    );
    try expectMalformed(
        comptime (hdr ++ testSection(4, "\x01\x70\x04\x01")),
        12,
        "WebAssembly feature memory64 is disabled",
    );

    const too_long = comptime (hdr ++ testSection(
        5,
        "\x01\x04\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00",
    ));
    try expectMalformedWithFeatures(too_long, .{ .memory64 = true }, 12, "integer representation too long");

    const too_many_pages = comptime (hdr ++ testSection(
        5,
        "\x01\x04\x81\x80\x80\x80\x80\x80\x40",
    ));
    try expectMalformedWithFeatures(too_many_pages, .{ .memory64 = true }, 12, "memory size exceeds address type limit");

    const too_large = comptime (hdr ++ testSection(
        5,
        "\x01\x04\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02",
    ));
    try expectMalformedWithFeatures(too_large, .{ .memory64 = true }, 12, "integer too large");
}

test "wasm.decode memory32 limits reject u32-overlong encodings" {
    try expectMalformed(
        hdr ++ "\x05\x0A\x02\x00\x01\x00\x82\x80\x80\x80\x80\x00",
        14,
        "integer representation too long",
    );
}

test "wasm.decode multi-memory indices and feature gate" {
    const bytes = comptime (hdr ++
        func_sec_1 ++
        testSection(5, "\x02\x00\x01\x00\x01") ++
        testCode(
            "\x41\x00" ++ // i32.const 0
                "\x28\x42\x01\x00" ++ // i32.load memory 1, align 2, offset 0
                "\x3F\x01" ++ // memory.size 1
                "\x40\x01" ++ // memory.grow 1
                "\x0B",
        ));
    try expectMalformedWithFeatures(bytes, .{}, 27, "WebAssembly feature multi-memory is disabled");

    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .multi_memory = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(@as(usize, 2), mod.mems.len);
    try std.testing.expectEqualDeep(
        types.Instr.MemArg{ .align_ = 2, .offset = 0, .memory_index = 1 },
        mod.code[0].instrs[1].imm.memarg,
    );
    try std.testing.expectEqual(@as(u32, 1), mod.code[0].instrs[2].imm.idx);
    try std.testing.expectEqual(@as(u32, 1), mod.code[0].instrs[3].imm.idx);
}

test "wasm.decode concrete function references do not require GC" {
    const features: types.Features = .{
        .reference_types = true,
        .typed_function_references = true,
    };
    const concrete = comptime (hdr ++
        testSection(1, "\x01\x60\x00\x00") ++
        testSection(4, "\x01\x63\x00\x00\x01"));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, concrete, features, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(types.HeapType.concrete(0), mod.tables[0].elem.refType().?.heap);

    const abstract_gc = comptime (hdr ++ testSection(4, "\x01\x63\x6B\x00\x01"));
    try expectMalformedWithFeatures(
        abstract_gc,
        features,
        11,
        "WebAssembly feature gc is disabled",
    );
}

fn decodeMemory64WithFailingAllocator(gpa: Allocator) !void {
    const bytes = comptime (hdr ++
        testSection(4, "\x01\x70\x05\x01\x82\x01") ++
        testSection(5, "\x01\x05\x01\x82\x01"));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(gpa, bytes, .{ .memory64 = true }, &diag);
    defer destroyModule(gpa, mod);
    try std.testing.expectEqual(types.AddressType.i64, mod.mems[0].address);
    try std.testing.expectEqual(types.AddressType.i64, mod.tables[0].address);
}

test "wasm.decode memory64 allocation failures are rollback safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeMemory64WithFailingAllocator,
        .{},
    );
}

const gc_features: types.Features = .{
    .reference_types = true,
    .typed_function_references = true,
    .gc = true,
};

const gc_type_bytes = hdr ++ testSection(1,
    // Two type-section entries expanding to three indexed definitions.
    "\x02" ++
        // rec { sub (struct (field i8 const) (field (ref null 0) var));
        //       sub final 0 (array (field (ref any) const)) }
        "\x4E\x02" ++
        "\x50\x00\x5F\x02\x78\x00\x63\x00\x01" ++
        "\x4F\x01\x00\x5E\x64\x6E\x00" ++
        // Shorthand final function: (anyref, (ref 1)) -> funcref.
        "\x60\x02\x6E\x64\x01\x01\x63\x70");

test "wasm.decode GC recursive subtypes fields and heap references" {
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, gc_type_bytes, gc_features, &diag);
    defer destroyModule(std.testing.allocator, mod);

    try std.testing.expectEqual(@as(usize, 3), mod.types.len);
    try std.testing.expectEqual(@as(usize, 2), mod.rec_groups.len);
    try std.testing.expectEqualDeep(types.RecGroup{ .start = 0, .len = 2 }, mod.rec_groups[0]);
    try std.testing.expectEqualDeep(types.RecGroup{ .start = 2, .len = 1 }, mod.rec_groups[1]);

    const struct_type = mod.types[0];
    try std.testing.expect(!struct_type.subtype.final);
    try std.testing.expectEqual(@as(usize, 0), struct_type.subtype.supertypes.len);
    const fields = struct_type.subtype.composite.struct_.fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].storage == .i8 and !fields[0].mutable);
    const field_ref = fields[1].storage.value.refType().?;
    try std.testing.expect(field_ref.nullable);
    try std.testing.expectEqual(@as(?u32, 0), field_ref.heap.concreteIndex());
    try std.testing.expect(fields[1].mutable);

    const array_type = mod.types[1];
    try std.testing.expect(array_type.subtype.final);
    try std.testing.expectEqualSlices(u32, &.{0}, array_type.subtype.supertypes);
    const array_ref = array_type.subtype.composite.array.field.storage.value.refType().?;
    try std.testing.expect(!array_ref.nullable);
    try std.testing.expectEqual(types.HeapType.any, array_ref.heap);

    const function_type = mod.types[2].funcType().?;
    try std.testing.expectEqualSlices(types.ValType, &.{
        .anyref,
        types.ValType.fromRef(.{ .nullable = false, .heap = types.HeapType.concrete(1) }),
    }, function_type.params);
    try std.testing.expectEqualSlices(types.ValType, &.{.funcref}, function_type.results);
}

fn decodeGcTypesWithFailingAllocator(gpa: Allocator) !void {
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(gpa, gc_type_bytes, gc_features, &diag);
    defer destroyModule(gpa, mod);
    try std.testing.expectEqual(@as(usize, 3), mod.types.len);
}

test "wasm.decode GC type allocation failures are rollback safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeGcTypesWithFailingAllocator,
        .{},
    );
}

test "wasm.decode GC type gates and malformed fields are deterministic" {
    try expectMalformedWithFeatures(
        gc_type_bytes,
        .{ .reference_types = true, .typed_function_references = true },
        11,
        "WebAssembly feature gc is disabled",
    );
    const bad_mutability = comptime (hdr ++ testSection(1, "\x01\x5F\x01\x7F\x02"));
    try expectMalformedWithFeatures(bad_mutability, gc_features, 14, "malformed mutability");
    const bad_composite = comptime (hdr ++ testSection(1, "\x01\x50\x00\x5D"));
    try expectMalformedWithFeatures(bad_composite, gc_features, 13, "invalid composite type");
}

fn decodedGcOp(instr: types.Instr) wasm_gc.Op {
    return switch (instr.imm) {
        .gc => |op| op,
        .gc_type => |value| value.op,
        .gc_type_field => |value| value.op,
        .gc_two_indices => |value| value.op,
        .gc_heap => |value| value.op,
        .gc_cast_branch => |value| value.op,
        else => unreachable,
    };
}

const gc_instruction_bytes =
    "\xD3\xD4" ++
    "\xFB\x00\x01\xFB\x01\x01" ++
    "\xFB\x02\x01\x02\xFB\x03\x01\x02\xFB\x04\x01\x02\xFB\x05\x01\x02" ++
    "\xFB\x06\x01\xFB\x07\x01\xFB\x08\x01\x03\xFB\x09\x01\x02\xFB\x0A\x01\x02" ++
    "\xFB\x0B\x01\xFB\x0C\x01\xFB\x0D\x01\xFB\x0E\x01\xFB\x0F" ++
    "\xFB\x10\x01\xFB\x11\x01\x02\xFB\x12\x01\x02\xFB\x13\x01\x02" ++
    "\xFB\x14\x6E\xFB\x15\x6E\xFB\x16\x6D\xFB\x17\x6D" ++
    "\xFB\x18\x03\x04\x6E\x6D\xFB\x19\x00\x05\x70\x73" ++
    "\xFB\x1A\xFB\x1B\xFB\x1C\xFB\x1D\xFB\x1E\x0B";

test "wasm.decode every pinned GC opcode and immediate" {
    const bytes = comptime (hdr ++ func_sec_1 ++ testCode(gc_instruction_bytes));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, gc_features, &diag);
    defer destroyModule(std.testing.allocator, mod);
    const instrs = mod.code[0].instrs;
    try std.testing.expectEqual(types.Op.ref_eq, instrs[0].op);
    try std.testing.expectEqual(types.Op.ref_as_non_null, instrs[1].op);
    for (instrs[2..33], 0..) |instr, subopcode| {
        try std.testing.expectEqual(types.Op.gc, instr.op);
        try std.testing.expectEqual(@as(u8, @intCast(subopcode)), @intFromEnum(decodedGcOp(instr)));
    }
    try std.testing.expectEqual(types.Op.end, instrs[33].op);
    try std.testing.expectEqualDeep(
        types.Instr.GcTypeField{ .op = .struct_get, .type_index = 1, .field_index = 2 },
        instrs[4].imm.gc_type_field,
    );
    try std.testing.expectEqualDeep(
        types.Instr.GcTwoIndices{ .op = .array_new_fixed, .first = 1, .second = 3 },
        instrs[10].imm.gc_two_indices,
    );
    const cast = instrs[26].imm.gc_cast_branch;
    try std.testing.expect(cast.source_nullable and cast.target_nullable);
    try std.testing.expectEqual(@as(u32, 4), cast.label_index);
    try std.testing.expectEqual(types.HeapType.any, cast.source_heap);
    try std.testing.expectEqual(types.HeapType.eq, cast.target_heap);
}

test "wasm.decode GC opcode gates and malformed immediates are deterministic" {
    const one = comptime (hdr ++ func_sec_1 ++ testCode("\xFB\x00\x00\x0B"));
    try expectMalformedWithFeatures(
        one,
        .{ .reference_types = true, .typed_function_references = true },
        17,
        "WebAssembly feature gc is disabled",
    );
    const reserved = comptime (hdr ++ func_sec_1 ++ testCode("\xFB\x1F\x0B"));
    try expectMalformedWithFeatures(reserved, gc_features, 18, "invalid 0xfb subopcode");
    const cast_flags = comptime (hdr ++ func_sec_1 ++ testCode("\xFB\x18\x04\x00\x6E\x6D\x0B"));
    try expectMalformedWithFeatures(cast_flags, gc_features, 19, "malformed cast flags");
}

test "wasm.decode malformed code bodies" {
    // The pinned proposal uses 0x08/0x0a/0x1f; legacy 0x06 is invalid.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\x06", 17, "invalid opcode 0x06");
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\x08", 17, "WebAssembly feature exception-handling is disabled");
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\x0A", 17, "WebAssembly feature exception-handling is disabled");
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\x1F", 17, "WebAssembly feature exception-handling is disabled");
    // Proposal prefixes.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x06\x01\x04\x00\xFC\x00\x0B", 17, "WebAssembly feature nontrapping-float-to-int is disabled");
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x04\x01\x02\x00\xFD", 17, "WebAssembly feature fixed-width-simd is disabled");
    // call_indirect reserved byte must be zero.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x06\x01\x04\x00\x11\x00\x01", 19, "zero flag expected");
    // memory.grow reserved byte must be zero.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x40\x01", 18, "zero flag expected");
    // Non-negative block type = type index (multi-value proposal).
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x02\x01", 18, "WebAssembly feature multi-value is disabled");
    // funcref is not an MVP block type.
    try expectMalformed(hdr ++ func_sec_1 ++ "\x0A\x05\x01\x03\x00\x02\x70", 18, "WebAssembly feature reference-types is disabled");
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

test "wasm.decode tail-call opcodes feature gate and immediates" {
    const bytes = comptime (hdr ++ func_sec_1 ++ testCode(
        "\x12\x81\x01" ++ // return_call function 129
            "\x13\x82\x01\x03" ++ // return_call_indirect type 130, table 3
            "\x0B",
    ));
    try expectMalformed(bytes, 17, "WebAssembly feature tail-calls is disabled");

    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .tail_calls = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(@as(usize, 3), mod.code[0].instrs.len);
    try std.testing.expectEqual(types.Op.return_call, mod.code[0].instrs[0].op);
    try std.testing.expectEqual(@as(u32, 129), mod.code[0].instrs[0].imm.idx);
    try std.testing.expectEqual(types.Op.return_call_indirect, mod.code[0].instrs[1].op);
    try std.testing.expectEqualDeep(
        types.Instr.CallIndirect{ .type_index = 130, .table_index = 3 },
        mod.code[0].instrs[1].imm.call_indirect,
    );

    try expectMalformedWithFeatures(
        comptime (hdr ++ func_sec_1 ++ testCode("\x13\x00")),
        .{ .tail_calls = true },
        19,
        "unexpected end",
    );
}

test "wasm.decode typed function call opcodes feature gates and immediates" {
    const call_bytes = comptime (hdr ++ func_sec_1 ++ testCode("\x14\x83\x01\x0B"));
    try expectMalformed(call_bytes, 17, "WebAssembly feature typed-function-references is disabled");

    var diag: types.Diagnostic = .{};
    const call_mod = try decodeWithFeatures(
        std.testing.allocator,
        call_bytes,
        .{ .reference_types = true, .typed_function_references = true },
        &diag,
    );
    defer destroyModule(std.testing.allocator, call_mod);
    try std.testing.expectEqual(types.Op.call_ref, call_mod.code[0].instrs[0].op);
    try std.testing.expectEqual(@as(u32, 131), call_mod.code[0].instrs[0].imm.idx);

    const tail_bytes = comptime (hdr ++ func_sec_1 ++ testCode("\x15\x84\x01\x0B"));
    try expectMalformedWithFeatures(
        tail_bytes,
        .{ .reference_types = true, .typed_function_references = true },
        17,
        "WebAssembly feature tail-calls is disabled",
    );
    const tail_mod = try decodeWithFeatures(
        std.testing.allocator,
        tail_bytes,
        .{ .tail_calls = true, .reference_types = true, .typed_function_references = true },
        &diag,
    );
    defer destroyModule(std.testing.allocator, tail_mod);
    try std.testing.expectEqual(types.Op.return_call_ref, tail_mod.code[0].instrs[0].op);
    try std.testing.expectEqual(@as(u32, 132), tail_mod.code[0].instrs[0].imm.idx);
}

test "wasm.decode modern exception instruction immediates and catches" {
    const bytes = comptime (hdr ++ func_sec_1 ++ testCode(
        "\x1F\x40\x04" ++ // try_table empty, four catches
            "\x00\x81\x01\x01" ++ // catch tag 129 -> label 1
            "\x01\x02\x03" ++ // catch_ref tag 2 -> label 3
            "\x02\x04" ++ // catch_all -> label 4
            "\x03\x05" ++ // catch_all_ref -> label 5
            "\x08\x07" ++ // throw tag 7
            "\x0A" ++ // throw_ref
            "\x0B\x0B",
    ));
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, features, &diag);
    defer destroyModule(std.testing.allocator, mod);

    const instrs = mod.code[0].instrs;
    try std.testing.expectEqual(@as(usize, 5), instrs.len);
    try std.testing.expectEqual(types.Op.try_table, instrs[0].op);
    const try_table = instrs[0].imm.try_table;
    try std.testing.expectEqual(types.BlockType.empty, try_table.block.type);
    try std.testing.expectEqual(@as(u32, 4), try_table.block.end_pc);
    try std.testing.expectEqual(@as(usize, 4), try_table.catches.len);
    try std.testing.expectEqualDeep(
        types.Instr.Catch{ .catch_tag = .{ .tag_index = 129, .label_index = 1 } },
        try_table.catches[0],
    );
    try std.testing.expectEqualDeep(
        types.Instr.Catch{ .catch_ref = .{ .tag_index = 2, .label_index = 3 } },
        try_table.catches[1],
    );
    try std.testing.expectEqualDeep(types.Instr.Catch{ .catch_all = 4 }, try_table.catches[2]);
    try std.testing.expectEqualDeep(types.Instr.Catch{ .catch_all_ref = 5 }, try_table.catches[3]);
    try std.testing.expectEqualDeep(types.Instr.Imm{ .idx = 7 }, instrs[1].imm);
    try std.testing.expectEqual(types.Op.throw_ref, instrs[2].op);

    const malformed = comptime (hdr ++ func_sec_1 ++ testCode("\x1F\x40\x01\x04"));
    try expectMalformedWithFeatures(malformed, features, 20, "invalid catch kind");
}

test "wasm.decode Core 3 explicit exception heap references" {
    const bytes = comptime (hdr ++ testSection(
        1,
        "\x01\x60\x04" ++
            "\x64\x69" ++ // (ref exn)
            "\x63\x69" ++ // (ref null exn) / exnref
            "\x63\x74" ++ // (ref null noexn) / nullexnref
            "\x74" ++ // nullexnref shorthand
            "\x00",
    ));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(
        std.testing.allocator,
        bytes,
        .{
            .reference_types = true,
            .typed_function_references = true,
            .exception_handling = true,
        },
        &diag,
    );
    defer destroyModule(std.testing.allocator, mod);
    const params = mod.funcTypeAt(0).?.params;
    try std.testing.expectEqual(@as(usize, 4), params.len);
    try std.testing.expectEqualDeep(
        types.RefType{ .nullable = false, .heap = .exn },
        params[0].refType().?,
    );
    try std.testing.expectEqual(types.ValType.exnref, params[1]);
    try std.testing.expectEqual(types.ValType.nullexnref, params[2]);
    try std.testing.expectEqual(types.ValType.nullexnref, params[3]);
}

test "wasm.decode fixed-width SIMD opcode inventory and immediates" {
    const lanes = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F";
    const bytes = comptime (hdr ++ func_sec_1 ++ testCode("\xFD\x0C" ++ lanes ++ // v128.const
        "\xFD\x00\x04\x07" ++ // v128.load align=4 offset=7
        "\xFD\x15\x0F" ++ // i8x16.extract_lane_s 15
        "\xFD\x54\x00\x00\x0F" ++ // v128.load8_lane 15
        "\xFD\x0D" ++ lanes ++ // i8x16.shuffle identity
        "\x0B"));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .fixed_width_simd = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    const instrs = mod.code[0].instrs;
    try std.testing.expectEqual(@as(usize, 6), instrs.len);
    try std.testing.expectEqual(@as(u128, 0x0F0E0D0C0B0A09080706050403020100), instrs[0].imm.simd_v128.bits);
    try std.testing.expectEqualDeep(types.Instr.MemArg{ .align_ = 4, .offset = 7 }, instrs[1].imm.simd_memarg.memarg);
    try std.testing.expectEqual(@as(u8, 15), instrs[2].imm.simd_lane.lane);
    try std.testing.expectEqual(@as(u8, 15), instrs[3].imm.simd_memarg_lane.lane);
    try std.testing.expectEqualSlices(u8, lanes, &instrs[4].imm.simd_shuffle.lanes);
}

test "wasm.decode fixed-width SIMD rejects reserved and oversized subopcodes" {
    try expectMalformedWithFeatures(
        comptime (hdr ++ func_sec_1 ++ testCode("\xFD\x9A\x01")),
        .{ .fixed_width_simd = true },
        18,
        "invalid 0xfd subopcode",
    );
    try expectMalformedWithFeatures(
        comptime (hdr ++ func_sec_1 ++ testCode("\xFD\x94\x02")),
        .{ .fixed_width_simd = true },
        18,
        "invalid 0xfd subopcode",
    );
}

test "wasm.decode relaxed SIMD inventory and feature gate" {
    const bytes = comptime (hdr ++ func_sec_1 ++ testCode(
        "\xFD\x80\x02" ++ // i8x16.relaxed_swizzle (0x100)
            "\xFD\x93\x02" ++ // i32x4.relaxed_dot_i8x16_i7x16_add_s (0x113)
            "\x0B",
    ));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(
        std.testing.allocator,
        bytes,
        .{ .fixed_width_simd = true, .relaxed_simd = true },
        &diag,
    );
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(@import("simd.zig").Op.i8x16_relaxed_swizzle, mod.code[0].instrs[0].imm.simd);
    try std.testing.expectEqual(@import("simd.zig").Op.i32x4_relaxed_dot_i8x16_i7x16_add_s, mod.code[0].instrs[1].imm.simd);

    try expectMalformedWithFeatures(
        bytes,
        .{ .fixed_width_simd = true },
        18,
        "WebAssembly feature relaxed-simd is disabled",
    );
    try expectMalformedWithFeatures(
        hdr,
        .{ .relaxed_simd = true },
        0,
        "WebAssembly feature relaxed-simd requires fixed-width-simd",
    );
}

test "wasm.decode feature gates distinguish disabled features and dependencies" {
    try expectMalformedWithFeatures(
        hdr,
        .{ .gc = true },
        0,
        "WebAssembly feature gc requires typed-function-references",
    );

    const exceptions: types.Features = .{
        .reference_types = true,
        .exception_handling = true,
    };
    var diag: types.Diagnostic = .{};
    const exnref = try decodeWithFeatures(
        std.testing.allocator,
        hdr ++ "\x01\x05\x01\x60\x01\x69\x00",
        exceptions,
        &diag,
    );
    defer destroyModule(std.testing.allocator, exnref);
    try std.testing.expectEqual(types.ValType.exnref, exnref.types[0].funcType().?.params[0]);
}

test "wasm.decode exception tags sections imports and exports" {
    const bytes = comptime (hdr ++
        testSection(1, "\x02\x60\x02\x7F\x7D\x00\x60\x00\x01\x7F") ++
        testSection(2, "\x01\x01m\x01t\x04\x00\x00") ++
        testSection(13, "\x01\x00\x00") ++
        testSection(7, "\x02\x01i\x04\x00\x01d\x04\x01"));
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, features, &diag);
    defer destroyModule(std.testing.allocator, mod);

    try std.testing.expectEqual(@as(u32, 1), mod.imported_tags);
    try std.testing.expectEqual(@as(usize, 1), mod.tags.len);
    try std.testing.expectEqual(@as(u32, 0), mod.tags[0].type_index);
    try std.testing.expectEqualDeep(types.ImportDesc{ .tag = .{ .type_index = 0 } }, mod.imports[0].desc);
    try std.testing.expectEqual(types.ExternalKind.tag, mod.exports[0].kind);
    try std.testing.expectEqual(@as(u32, 1), mod.exports[1].index);
    try std.testing.expectEqual(@as(u32, 2), mod.totalTags());
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .f32 }, mod.tagType(0).params);
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .f32 }, mod.tagType(1).params);

    const malformed_attribute = comptime (hdr ++ testSection(13, "\x01\x01\x00"));
    try expectMalformedWithFeatures(malformed_attribute, features, 11, "malformed tag attribute");
}

test "wasm.decode bulk memory segment forms DataCount order and immediates" {
    const elem_payload =
        "\x08" ++
        "\x00\x41\x00\x0B\x01\x00" ++
        "\x01\x00\x01\x00" ++
        "\x02\x01\x41\x00\x0B\x00\x01\x00" ++
        "\x03\x00\x01\x00" ++
        "\x04\x41\x00\x0B\x01\xD2\x00\x0B" ++
        "\x05\x70\x01\xD0\x70\x0B" ++
        "\x06\x01\x41\x00\x0B\x6F\x01\xD0\x6F\x0B" ++
        "\x07\x70\x01\xD2\x00\x0B";
    const bulk_ops =
        "\xFC\x08\x02\x01" ++
        "\xFC\x09\x02" ++
        "\xFC\x0A\x01\x00" ++
        "\xFC\x0B\x01" ++
        "\xFC\x0C\x03\x01" ++
        "\xFC\x0D\x03" ++
        "\xFC\x0E\x01\x00\x0B";
    const data_payload =
        "\x03" ++
        "\x00\x41\x00\x0B\x01A" ++
        "\x01\x01B" ++
        "\x02\x01\x41\x01\x0B\x01C";
    const bytes = comptime hdr ++ func_sec_1 ++ testSection(9, elem_payload) ++
        testSection(12, "\x03") ++ testCode(bulk_ops) ++ testSection(11, data_payload);
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{
        .bulk_memory = true,
        .reference_types = true,
    }, &diag);
    defer destroyModule(std.testing.allocator, mod);

    try std.testing.expectEqual(@as(?u32, 3), mod.data_count);
    try std.testing.expectEqual(@as(usize, 8), mod.elems.len);
    const non_null_funcref = types.ValType.fromRef(.{ .nullable = false, .heap = .func });
    for (mod.elems[0..4]) |elem| {
        try std.testing.expectEqual(non_null_funcref, elem.type);
        try std.testing.expect(elem.legacy_func_indices);
    }
    for (mod.elems[4..]) |elem| try std.testing.expect(!elem.legacy_func_indices);
    try std.testing.expectEqual(std.meta.Tag(types.ElemMode).active, std.meta.activeTag(mod.elems[0].mode));
    try std.testing.expectEqual(std.meta.Tag(types.ElemMode).passive, std.meta.activeTag(mod.elems[1].mode));
    try std.testing.expectEqual(std.meta.Tag(types.ElemMode).declarative, std.meta.activeTag(mod.elems[3].mode));
    try std.testing.expectEqual(types.ValType.externref, mod.elems[6].type);
    try std.testing.expectEqualDeep(types.ConstExpr{ .ref_null = .externref }, mod.elems[6].init[0]);
    try std.testing.expectEqual(@as(usize, 3), mod.datas.len);
    try std.testing.expectEqual(std.meta.Tag(types.DataMode).active, std.meta.activeTag(mod.datas[0].mode));
    try std.testing.expectEqual(std.meta.Tag(types.DataMode).passive, std.meta.activeTag(mod.datas[1].mode));
    try std.testing.expectEqualSlices(u8, "C", mod.datas[2].bytes);

    const instrs = mod.code[0].instrs;
    try std.testing.expectEqual(types.Op.memory_init, instrs[0].op);
    try std.testing.expectEqualDeep(types.Instr.Indices{ .first = 2, .second = 1 }, instrs[0].imm.indices);
    try std.testing.expectEqual(types.Op.data_drop, instrs[1].op);
    try std.testing.expectEqual(types.Op.memory_copy, instrs[2].op);
    try std.testing.expectEqual(types.Op.memory_fill, instrs[3].op);
    try std.testing.expectEqual(types.Op.table_init, instrs[4].op);
    try std.testing.expectEqualDeep(types.Instr.Indices{ .first = 3, .second = 1 }, instrs[4].imm.indices);
    try std.testing.expectEqual(types.Op.elem_drop, instrs[5].op);
    try std.testing.expectEqual(types.Op.table_copy, instrs[6].op);

    const code_only = comptime testCode("\x0B");
    const out_of_order = comptime hdr ++ code_only ++ testSection(12, "\x00");
    try expectMalformedWithFeatures(
        out_of_order,
        .{ .bulk_memory = true },
        @intCast(hdr.len + code_only.len),
        "unexpected content after last section",
    );
}

test "wasm.decode multi-value signatures and type-index blocks" {
    const bytes = hdr ++
        "\x01\x06\x01\x60\x00\x02\x7F\x7E" ++
        func_sec_1 ++ "\x0A\x0B\x01\x09\x00\x02\x00\x41\x07\x42\x09\x0B\x0B";
    try expectMalformed(bytes, 13, "invalid result arity");

    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .multi_value = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(@as(usize, 2), mod.types[0].funcType().?.results.len);
    try std.testing.expectEqual(types.BlockType{ .type_index = 0 }, mod.code[0].instrs[0].imm.block.type);
}

test "wasm.decode explicit reference block result" {
    const bytes = hdr ++ func_sec_1 ++
        "\x0A\x09\x01\x07\x00\x02\x64\x6E\x00\x0B\x0B";
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{
        .reference_types = true,
        .typed_function_references = true,
        .gc = true,
    }, &diag);
    defer destroyModule(std.testing.allocator, mod);

    const block_type = mod.code[0].instrs[0].imm.block.type;
    try std.testing.expectEqualSlices(
        types.ValType,
        &.{types.ValType.fromRef(.{ .nullable = false, .heap = .any })},
        block_type.explicit_value,
    );
}

test "wasm.decode branch on reference nullability" {
    const bytes = comptime (hdr ++ func_sec_1 ++ testCode("\xD5\x00\xD6\x01\x0B"));
    var diag: types.Diagnostic = .{};
    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{
        .reference_types = true,
        .typed_function_references = true,
    }, &diag);
    defer destroyModule(std.testing.allocator, mod);

    try std.testing.expectEqual(types.Op.br_on_null, mod.code[0].instrs[0].op);
    try std.testing.expectEqual(@as(u32, 0), mod.code[0].instrs[0].imm.idx);
    try std.testing.expectEqual(types.Op.br_on_non_null, mod.code[0].instrs[1].op);
    try std.testing.expectEqual(@as(u32, 1), mod.code[0].instrs[1].imm.idx);
}

test "wasm.decode reference instructions tables and constant expressions" {
    const instrs =
        "\xD0\x70" ++ // ref.null funcref
        "\xD1" ++ // ref.is_null
        "\x1A" ++ // drop
        "\xD2\x00" ++ // ref.func 0
        "\x1A" ++ // drop
        "\x25\x01" ++ // table.get 1
        "\x26\x01" ++ // table.set 1
        "\x1C\x01\x6F" ++ // select (result externref)
        "\x11\x00\x01" ++ // call_indirect type 0 table 1
        "\xFC\x0F\x01" ++ // table.grow 1
        "\xFC\x10\x01" ++ // table.size 1
        "\xFC\x11\x01" ++ // table.fill 1
        "\x0B";
    const bytes = comptime hdr ++
        testSection(1, "\x01\x60\x00\x00") ++
        func_sec_1 ++
        testSection(4, "\x02\x70\x00\x01\x6F\x00\x02") ++
        testSection(6, "\x02\x70\x00\xD0\x70\x0B\x70\x00\xD2\x00\x0B") ++
        testCode(instrs);

    var diag: types.Diagnostic = .{};
    try std.testing.expectError(error.Malformed, decode(std.testing.allocator, bytes, &diag));
    try std.testing.expectEqualStrings("WebAssembly feature reference-types is disabled", diag.message());

    const mod = try decodeWithFeatures(std.testing.allocator, bytes, .{ .reference_types = true }, &diag);
    defer destroyModule(std.testing.allocator, mod);
    try std.testing.expectEqual(types.ValType.funcref, mod.tables[0].elem);
    try std.testing.expectEqual(types.ValType.externref, mod.tables[1].elem);
    try std.testing.expectEqualDeep(types.ConstExpr{ .ref_null = .funcref }, mod.globals[0].init);
    try std.testing.expectEqualDeep(types.ConstExpr{ .ref_func = 0 }, mod.globals[1].init);
    const decoded = mod.code[0].instrs;
    try std.testing.expectEqual(types.ValType.funcref, decoded[0].imm.type);
    try std.testing.expectEqual(@as(u32, 1), decoded[5].imm.idx);
    try std.testing.expectEqual(types.ValType.externref, decoded[7].imm.type);
    try std.testing.expectEqualDeep(
        types.Instr.CallIndirect{ .type_index = 0, .table_index = 1 },
        decoded[8].imm.call_indirect,
    );
    try std.testing.expectEqual(@as(u32, 1), decoded[9].imm.idx);
    try std.testing.expectEqual(@as(u32, 1), decoded[10].imm.idx);
    try std.testing.expectEqual(@as(u32, 1), decoded[11].imm.idx);
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
