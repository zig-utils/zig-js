//! WebAssembly MVP (wg-1.0) module IR shared by the decoder, validator,
//! execution engine, and JS API. Everything here is allocator-agnostic; a
//! decoded `Module` owns its memory through a single arena.

const std = @import("std");
const atomic = @import("atomic.zig");
const gc = @import("gc.zig");
const simd = @import("simd.zig");

pub const PAGE_SIZE: u32 = 65536;
pub const MAX_PAGES: u32 = 65536; // 4 GiB
pub const MAX_PAGES64: u64 = 1 << 48;

pub const Feature = enum {
    sign_extension_ops,
    nontrapping_float_to_int,
    multi_value,
    reference_types,
    bulk_memory,
    fixed_width_simd,
    threads,
    tail_calls,
    typed_function_references,
    gc,
    exception_handling,
    memory64,

    pub fn name(self: Feature) []const u8 {
        return switch (self) {
            .sign_extension_ops => "sign-extension-ops",
            .nontrapping_float_to_int => "nontrapping-float-to-int",
            .multi_value => "multi-value",
            .reference_types => "reference-types",
            .bulk_memory => "bulk-memory",
            .fixed_width_simd => "fixed-width-simd",
            .threads => "threads",
            .tail_calls => "tail-calls",
            .typed_function_references => "typed-function-references",
            .gc => "gc",
            .exception_handling => "exception-handling",
            .memory64 => "memory64",
        };
    }
};

pub const Features = struct {
    sign_extension_ops: bool = false,
    nontrapping_float_to_int: bool = false,
    multi_value: bool = false,
    reference_types: bool = false,
    bulk_memory: bool = false,
    fixed_width_simd: bool = false,
    threads: bool = false,
    tail_calls: bool = false,
    typed_function_references: bool = false,
    gc: bool = false,
    exception_handling: bool = false,
    memory64: bool = false,

    pub const DependencyFailure = struct {
        feature: Feature,
        required: Feature,
    };

    pub fn enabled(self: Features, feature: Feature) bool {
        return switch (feature) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn missingDependency(self: Features) ?DependencyFailure {
        if (self.typed_function_references and !self.reference_types)
            return .{ .feature = .typed_function_references, .required = .reference_types };
        if (self.gc and !self.typed_function_references)
            return .{ .feature = .gc, .required = .typed_function_references };
        if (self.exception_handling and !self.reference_types)
            return .{ .feature = .exception_handling, .required = .reference_types };
        return null;
    }
};

/// Deterministic diagnostic channel for decode/validate/link failures. The
/// message lives in a fixed buffer so error paths never allocate; `offset`
/// is the byte offset in the module binary (or `no_offset` for link-time).
pub const Diagnostic = struct {
    pub const no_offset: u32 = std.math.maxInt(u32);

    offset: u32 = no_offset,
    buf: [192]u8 = undefined,
    len: u8 = 0,

    pub fn set(self: *Diagnostic, offset: u32, comptime fmt: []const u8, args: anytype) void {
        self.offset = offset;
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            // Truncation keeps the diagnostic deterministic (and non-empty).
            break :blk self.buf[0..];
        };
        self.len = @intCast(s.len);
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Heap types use the low u32 range for concrete module type indices and a
/// disjoint high range for the ten abstract GC hierarchy nodes. This keeps
/// them compact, directly comparable, and allocation-free in every IR use.
pub const HeapType = enum(u64) {
    nofunc = (@as(u64, 1) << 32) | 0x73,
    noextern = (@as(u64, 1) << 32) | 0x72,
    none = (@as(u64, 1) << 32) | 0x71,
    func = (@as(u64, 1) << 32) | 0x70,
    extern_ = (@as(u64, 1) << 32) | 0x6F,
    any = (@as(u64, 1) << 32) | 0x6E,
    eq = (@as(u64, 1) << 32) | 0x6D,
    i31 = (@as(u64, 1) << 32) | 0x6C,
    struct_ = (@as(u64, 1) << 32) | 0x6B,
    array = (@as(u64, 1) << 32) | 0x6A,
    _,

    pub fn concrete(index: u32) HeapType {
        return @enumFromInt(index);
    }

    pub fn concreteIndex(self: HeapType) ?u32 {
        const raw = @intFromEnum(self);
        return if (raw <= std.math.maxInt(u32)) @intCast(raw) else null;
    }

    pub fn fromAbstractByte(byte: u8) ?HeapType {
        return switch (byte) {
            0x73 => .nofunc,
            0x72 => .noextern,
            0x71 => .none,
            0x70 => .func,
            0x6F => .extern_,
            0x6E => .any,
            0x6D => .eq,
            0x6C => .i31,
            0x6B => .struct_,
            0x6A => .array,
            else => null,
        };
    }

    pub fn abstractByte(self: HeapType) ?u8 {
        if (self.concreteIndex() != null) return null;
        const raw = @intFromEnum(self);
        if (raw >> 32 != 1) return null;
        return @truncate(raw);
    }
};

pub const RefType = struct {
    nullable: bool,
    heap: HeapType,
};

/// Value types retain their normative one-byte values for all short forms.
/// Explicit `(ref null? ht)` forms occupy a private disjoint encoding carrying
/// the complete heap type; this is IR-only and never leaks into the binary.
pub const ValType = enum(u64) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    v128 = 0x7B,
    nofuncref = 0x73,
    noexternref = 0x72,
    nullref = 0x71,
    exnref = 0x69,
    anyref = 0x6E,
    eqref = 0x6D,
    i31ref = 0x6C,
    structref = 0x6B,
    arrayref = 0x6A,
    externref = 0x6F,
    funcref = 0x70,
    _,

    const explicit_ref_base: u64 = @as(u64, 1) << 63;
    const nullable_bit: u64 = @as(u64, 1) << 62;
    const heap_mask: u64 = nullable_bit - 1;

    pub fn fromByte(b: u8) ?ValType {
        return switch (b) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            0x7B => .v128,
            0x73 => .nofuncref,
            0x72 => .noexternref,
            0x71 => .nullref,
            0x69 => .exnref,
            0x6E => .anyref,
            0x6D => .eqref,
            0x6C => .i31ref,
            0x6B => .structref,
            0x6A => .arrayref,
            0x6F => .externref,
            0x70 => .funcref,
            else => null,
        };
    }

    pub fn fromRef(ref_type: RefType) ValType {
        if (ref_type.nullable) {
            if (ref_type.heap.abstractByte()) |byte|
                return ValType.fromByte(byte).?;
        }
        const nullable = if (ref_type.nullable) nullable_bit else 0;
        return @enumFromInt(explicit_ref_base | nullable | @intFromEnum(ref_type.heap));
    }

    pub fn refType(self: ValType) ?RefType {
        const raw = @intFromEnum(self);
        if (raw & explicit_ref_base != 0) return .{
            .nullable = raw & nullable_bit != 0,
            .heap = @enumFromInt(raw & heap_mask),
        };
        const byte: u8 = std.math.cast(u8, raw) orelse return null;
        const heap = HeapType.fromAbstractByte(byte) orelse return null;
        return .{ .nullable = true, .heap = heap };
    }

    pub fn name(self: ValType) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
            .v128 => "v128",
            .exnref => "exnref",
            .funcref => "funcref",
            .externref => "externref",
            .nofuncref => "nofuncref",
            .noexternref => "noexternref",
            .nullref => "nullref",
            .anyref => "anyref",
            .eqref => "eqref",
            .i31ref => "i31ref",
            .structref => "structref",
            .arrayref => "arrayref",
            _ => "ref",
        };
    }

    pub fn isReference(self: ValType) bool {
        return self == .exnref or self.refType() != null;
    }

    pub fn isGcReference(self: ValType) bool {
        const ref_type = self.refType() orelse return false;
        return switch (ref_type.heap) {
            .func, .nofunc, .extern_, .noextern => false,
            else => true,
        };
    }
};

/// A block signature is either one of the compact inline forms or a function
/// type index. The latter supplies both block parameters and results.
pub const BlockType = union(enum) {
    empty,
    value: ValType,
    type_index: u32,

    pub fn funcType(self: BlockType, mod: *const Module) ?FuncType {
        return switch (self) {
            .empty => .{ .params = &.{}, .results = &.{} },
            .value => |value| .{ .params = &.{}, .results = switch (value) {
                .i32 => &.{.i32},
                .i64 => &.{.i64},
                .f32 => &.{.f32},
                .f64 => &.{.f64},
                .v128 => &.{.v128},
                .exnref => &.{.exnref},
                .externref => &.{.externref},
                .funcref => &.{.funcref},
                .nofuncref => &.{.nofuncref},
                .noexternref => &.{.noexternref},
                .nullref => &.{.nullref},
                .anyref => &.{.anyref},
                .eqref => &.{.eqref},
                .i31ref => &.{.i31ref},
                .structref => &.{.structref},
                .arrayref => &.{.arrayref},
                else => return null,
            } },
            .type_index => |index| mod.funcTypeAt(index),
        };
    }
};

pub const AddressType = enum {
    i32,
    i64,

    pub fn valType(self: AddressType) ValType {
        return switch (self) {
            .i32 => .i32,
            .i64 => .i64,
        };
    }

    pub fn maxMemoryPages(self: AddressType) u64 {
        return switch (self) {
            .i32 => MAX_PAGES,
            .i64 => MAX_PAGES64,
        };
    }

    pub fn maxTableElements(self: AddressType) u64 {
        return switch (self) {
            .i32 => std.math.maxInt(u32),
            .i64 => std.math.maxInt(u64),
        };
    }

    /// The bulk copy length uses the narrower of the source and destination
    /// address types.
    pub fn min(a: AddressType, b: AddressType) AddressType {
        return if (a == .i32 or b == .i32) .i32 else .i64;
    }
};

pub const Limits = struct {
    min: u64,
    max: ?u64 = null,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

pub const StorageType = union(enum) {
    value: ValType,
    i8,
    i16,

    pub fn unpacked(self: StorageType) ValType {
        return switch (self) {
            .value => |value| value,
            .i8, .i16 => .i32,
        };
    }
};

pub const FieldType = struct {
    storage: StorageType,
    mutable: bool,
};

pub const StructType = struct {
    fields: []const FieldType,
};

pub const ArrayType = struct {
    field: FieldType,
};

pub const CompositeType = union(enum) {
    func: FuncType,
    struct_: StructType,
    array: ArrayType,
};

pub const SubType = struct {
    final: bool,
    supertypes: []const u32,
    composite: CompositeType,
};

pub const DefType = struct {
    rec_group: u32,
    rec_index: u32,
    subtype: SubType,

    pub fn funcType(self: DefType) ?FuncType {
        return switch (self.subtype.composite) {
            .func => |function| function,
            else => null,
        };
    }
};

pub const RecGroup = struct {
    start: u32,
    len: u32,
};

pub fn funcTypeEql(a: FuncType, b: FuncType) bool {
    return std.mem.eql(ValType, a.params, b.params) and
        std.mem.eql(ValType, a.results, b.results);
}

pub const GlobalType = struct {
    val: ValType,
    mutable: bool,
};

/// A tag declaration references a function type whose results must be empty;
/// its parameters are the exception payload types. The leading binary
/// attribute byte is fixed at zero and is therefore not retained in the IR.
pub const Tag = struct {
    type_index: u32,
};

pub const TableType = struct {
    address: AddressType = .i32,
    elem: ValType = .funcref,
    limits: Limits,
    /// Defined tables may provide a typed-function-references initializer;
    /// imported tables leave this null.
    init: ?ConstExpr = null,
};

pub const MemType = struct {
    address: AddressType = .i32,
    limits: Limits,
    shared: bool = false,
};

pub const ImportDesc = union(enum) {
    func: u32, // type index
    table: TableType,
    mem: MemType,
    global: GlobalType,
    tag: Tag,

    pub fn kind(self: ImportDesc) ExternalKind {
        return switch (self) {
            .func => .func,
            .table => .table,
            .mem => .mem,
            .global => .global,
            .tag => .tag,
        };
    }
};

pub const ExternalKind = enum(u8) {
    func = 0,
    table = 1,
    mem = 2,
    global = 3,
    tag = 4,

    pub fn name(self: ExternalKind) []const u8 {
        return switch (self) {
            .func => "function",
            .table => "table",
            .mem => "memory",
            .global => "global",
            .tag => "tag",
        };
    }
};

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    desc: ImportDesc,
};

pub const Export = struct {
    name: []const u8,
    kind: ExternalKind,
    index: u32,
};

/// A constant initializer. MVP expressions use one of the compact cases;
/// proposal profiles may retain a decoded instruction sequence so validation
/// and execution share the same GC instruction representation as functions.
pub const ConstExpr = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32, // raw bits
    f64: u64, // raw bits
    v128: u128, // raw lane bits
    global: u32, // imported global index
    ref_null: ValType,
    ref_func: u32,
    extended: struct {
        instrs: []const Instr,
        offsets: []const u32,
    },

    pub fn valType(self: ConstExpr) ValType {
        return switch (self) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .v128 => .v128,
            .global => unreachable, // resolved against the import list
            .ref_null => |ref_type| ref_type,
            .ref_func => .funcref,
            .extended => unreachable, // resolved by instruction validation
        };
    }
};

pub const Global = struct {
    type: GlobalType,
    init: ConstExpr,
};

pub const ElemMode = union(enum) {
    passive,
    declarative,
    active: struct {
        table: u32,
        offset: ConstExpr,
    },
};

pub const Elem = struct {
    type: ValType,
    mode: ElemMode,
    init: []const ConstExpr,
};

pub const DataMode = union(enum) {
    passive,
    active: struct {
        mem: u32,
        offset: ConstExpr,
    },
};

pub const Data = struct {
    mode: DataMode,
    bytes: []const u8,
};

pub const CustomSection = struct {
    name: []const u8,
    bytes: []const u8, // payload after the name
    offset: u32, // byte offset of the section id in the module
};

/// Decoded instruction. Control instructions carry pre-resolved jump
/// targets so the interpreter never re-scans the body.
pub const Instr = struct {
    op: Op,
    imm: Imm = .none,

    pub const Imm = union(enum) {
        none: void,
        /// local / global / function / type index, or br depth.
        idx: u32,
        type: ValType,
        call_indirect: CallIndirect,
        i32: i32,
        i64: i64,
        f32: u32, // raw bits
        f64: u64, // raw bits
        memarg: MemArg,
        /// `block`: end_pc = pc past `end`; else_pc unused.
        /// `loop`: else_pc = loop body start pc; end_pc = pc past `end`.
        /// `if_`: else_pc = pc past `else` (or past `end` when no else),
        ///        end_pc = pc past `end`.
        block: Block,
        try_table: TryTable,
        br_table: BrTable,
        indices: Indices,
        simd: simd.Op,
        simd_memarg: SimdMemArg,
        simd_v128: SimdV128,
        simd_shuffle: SimdShuffle,
        simd_lane: SimdLane,
        simd_memarg_lane: SimdMemArgLane,
        atomic: atomic.Op,
        atomic_memarg: AtomicMemArg,
        gc: gc.Op,
        gc_type: GcType,
        gc_type_field: GcTypeField,
        gc_two_indices: GcTwoIndices,
        gc_heap: GcHeap,
        gc_cast_branch: GcCastBranch,
    };

    pub const MemArg = struct {
        align_: u32,
        offset: u64,
    };

    pub const CallIndirect = struct {
        type_index: u32,
        table_index: u32,
    };

    pub const Indices = struct {
        first: u32,
        second: u32,
    };

    pub const SimdMemArg = struct { op: simd.Op, memarg: MemArg };
    pub const SimdV128 = struct { op: simd.Op, bits: u128 };
    pub const SimdShuffle = struct { op: simd.Op, lanes: [16]u8 };
    pub const SimdLane = struct { op: simd.Op, lane: u8 };
    pub const SimdMemArgLane = struct { op: simd.Op, memarg: MemArg, lane: u8 };
    pub const AtomicMemArg = struct { op: atomic.Op, memarg: MemArg };
    pub const GcType = struct { op: gc.Op, type_index: u32 };
    pub const GcTypeField = struct { op: gc.Op, type_index: u32, field_index: u32 };
    pub const GcTwoIndices = struct { op: gc.Op, first: u32, second: u32 };
    pub const GcHeap = struct { op: gc.Op, heap: HeapType };
    pub const GcCastBranch = struct {
        op: gc.Op,
        source_nullable: bool,
        target_nullable: bool,
        label_index: u32,
        source_heap: HeapType,
        target_heap: HeapType,
    };

    pub const Block = struct {
        type: BlockType,
        else_pc: u32,
        end_pc: u32,
    };

    pub const BrTable = struct {
        /// Label depths; the branch operand index selects one, out-of-range
        /// selects `default`.
        targets: []const u32,
        default: u32,
    };

    pub const TaggedCatch = struct {
        tag_index: u32,
        label_index: u32,
    };

    pub const Catch = union(enum) {
        catch_tag: TaggedCatch,
        catch_ref: TaggedCatch,
        catch_all: u32,
        catch_all_ref: u32,

        pub fn labelIndex(self: Catch) u32 {
            return switch (self) {
                .catch_tag, .catch_ref => |tagged| tagged.label_index,
                .catch_all, .catch_all_ref => |label_index| label_index,
            };
        }
    };

    pub const TryTable = struct {
        block: Block,
        catches: []const Catch,
    };
};

/// Every recognized opcode in the current binary and validation profiles.
/// Direct opcodes use their binary byte; prefixed opcodes use the prefix as the
/// high byte and the subopcode as the low byte. The decoder still applies the
/// owning feature gate before emitting any post-MVP instruction.
pub const Op = enum(u16) {
    // Control
    unreachable_ = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    if_ = 0x04,
    else_ = 0x05,
    throw = 0x08,
    throw_ref = 0x0A,
    end = 0x0B,
    br = 0x0C,
    br_if = 0x0D,
    br_table = 0x0E,
    return_ = 0x0F,
    call = 0x10,
    call_indirect = 0x11,
    return_call = 0x12,
    return_call_indirect = 0x13,
    try_table = 0x1F,
    // Parametric
    drop = 0x1A,
    select = 0x1B,
    typed_select = 0x1C,
    // Variable
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,
    table_get = 0x25,
    table_set = 0x26,
    // Memory
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2A,
    f64_load = 0x2B,
    i32_load8_s = 0x2C,
    i32_load8_u = 0x2D,
    i32_load16_s = 0x2E,
    i32_load16_u = 0x2F,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3A,
    i32_store16 = 0x3B,
    i64_store8 = 0x3C,
    i64_store16 = 0x3D,
    i64_store32 = 0x3E,
    memory_size = 0x3F,
    memory_grow = 0x40,
    // Constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,
    // i32 comparisons
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4A,
    i32_gt_u = 0x4B,
    i32_le_s = 0x4C,
    i32_le_u = 0x4D,
    i32_ge_s = 0x4E,
    i32_ge_u = 0x4F,
    // i64 comparisons
    i64_eqz = 0x50,
    i64_eq = 0x51,
    i64_ne = 0x52,
    i64_lt_s = 0x53,
    i64_lt_u = 0x54,
    i64_gt_s = 0x55,
    i64_gt_u = 0x56,
    i64_le_s = 0x57,
    i64_le_u = 0x58,
    i64_ge_s = 0x59,
    i64_ge_u = 0x5A,
    // f32 comparisons
    f32_eq = 0x5B,
    f32_ne = 0x5C,
    f32_lt = 0x5D,
    f32_gt = 0x5E,
    f32_le = 0x5F,
    f32_ge = 0x60,
    // f64 comparisons
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,
    // i32 arithmetic
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6A,
    i32_sub = 0x6B,
    i32_mul = 0x6C,
    i32_div_s = 0x6D,
    i32_div_u = 0x6E,
    i32_rem_s = 0x6F,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,
    // i64 arithmetic
    i64_clz = 0x79,
    i64_ctz = 0x7A,
    i64_popcnt = 0x7B,
    i64_add = 0x7C,
    i64_sub = 0x7D,
    i64_mul = 0x7E,
    i64_div_s = 0x7F,
    i64_div_u = 0x80,
    i64_rem_s = 0x81,
    i64_rem_u = 0x82,
    i64_and = 0x83,
    i64_or = 0x84,
    i64_xor = 0x85,
    i64_shl = 0x86,
    i64_shr_s = 0x87,
    i64_shr_u = 0x88,
    i64_rotl = 0x89,
    i64_rotr = 0x8A,
    // f32 arithmetic
    f32_abs = 0x8B,
    f32_neg = 0x8C,
    f32_ceil = 0x8D,
    f32_floor = 0x8E,
    f32_trunc = 0x8F,
    f32_nearest = 0x90,
    f32_sqrt = 0x91,
    f32_add = 0x92,
    f32_sub = 0x93,
    f32_mul = 0x94,
    f32_div = 0x95,
    f32_min = 0x96,
    f32_max = 0x97,
    f32_copysign = 0x98,
    // f64 arithmetic
    f64_abs = 0x99,
    f64_neg = 0x9A,
    f64_ceil = 0x9B,
    f64_floor = 0x9C,
    f64_trunc = 0x9D,
    f64_nearest = 0x9E,
    f64_sqrt = 0x9F,
    f64_add = 0xA0,
    f64_sub = 0xA1,
    f64_mul = 0xA2,
    f64_div = 0xA3,
    f64_min = 0xA4,
    f64_max = 0xA5,
    f64_copysign = 0xA6,
    // Conversions
    i32_wrap_i64 = 0xA7,
    i32_trunc_f32_s = 0xA8,
    i32_trunc_f32_u = 0xA9,
    i32_trunc_f64_s = 0xAA,
    i32_trunc_f64_u = 0xAB,
    i64_extend_i32_s = 0xAC,
    i64_extend_i32_u = 0xAD,
    i64_trunc_f32_s = 0xAE,
    i64_trunc_f32_u = 0xAF,
    i64_trunc_f64_s = 0xB0,
    i64_trunc_f64_u = 0xB1,
    f32_convert_i32_s = 0xB2,
    f32_convert_i32_u = 0xB3,
    f32_convert_i64_s = 0xB4,
    f32_convert_i64_u = 0xB5,
    f32_demote_f64 = 0xB6,
    f64_convert_i32_s = 0xB7,
    f64_convert_i32_u = 0xB8,
    f64_convert_i64_s = 0xB9,
    f64_convert_i64_u = 0xBA,
    f64_promote_f32 = 0xBB,
    i32_reinterpret_f32 = 0xBC,
    i64_reinterpret_f64 = 0xBD,
    f32_reinterpret_i32 = 0xBE,
    f64_reinterpret_i64 = 0xBF,
    // Sign-extension operations
    i32_extend8_s = 0xC0,
    i32_extend16_s = 0xC1,
    i64_extend8_s = 0xC2,
    i64_extend16_s = 0xC3,
    i64_extend32_s = 0xC4,
    // Reference types
    ref_null = 0xD0,
    ref_is_null = 0xD1,
    ref_func = 0xD2,
    ref_eq = 0xD3,
    ref_as_non_null = 0xD4,
    gc = 0xFB,
    simd = 0xFD,
    atomic = 0xFE,
    // Nontrapping float-to-integer conversions (0xfc prefix)
    i32_trunc_sat_f32_s = 0xFC00,
    i32_trunc_sat_f32_u = 0xFC01,
    i32_trunc_sat_f64_s = 0xFC02,
    i32_trunc_sat_f64_u = 0xFC03,
    i64_trunc_sat_f32_s = 0xFC04,
    i64_trunc_sat_f32_u = 0xFC05,
    i64_trunc_sat_f64_s = 0xFC06,
    i64_trunc_sat_f64_u = 0xFC07,
    memory_init = 0xFC08,
    data_drop = 0xFC09,
    memory_copy = 0xFC0A,
    memory_fill = 0xFC0B,
    table_init = 0xFC0C,
    elem_drop = 0xFC0D,
    table_copy = 0xFC0E,
    table_grow = 0xFC0F,
    table_size = 0xFC10,
    table_fill = 0xFC11,

    pub fn fromByte(b: u8) ?Op {
        return std.enums.fromInt(Op, @as(u16, b));
    }

    pub fn fromFC(subopcode: u32) ?Op {
        if (subopcode > 0xFF) return null;
        return std.enums.fromInt(Op, 0xFC00 | @as(u16, @intCast(subopcode)));
    }
};

pub const FuncBody = struct {
    /// Expanded locals (params excluded), declaration order.
    locals: []const ValType,
    instrs: []const Instr,
    /// Byte offset of each instruction within the module, for diagnostics.
    offsets: []const u32,
};

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    features: Features = .{},

    types: []const DefType = &.{},
    rec_groups: []const RecGroup = &.{},
    imports: []const Import = &.{},
    /// Type indices of module-defined functions (imports excluded).
    funcs: []const u32 = &.{},
    tables: []const TableType = &.{},
    mems: []const MemType = &.{},
    tags: []const Tag = &.{},
    globals: []const Global = &.{},
    exports: []const Export = &.{},
    start: ?u32 = null,
    elems: []const Elem = &.{},
    datas: []const Data = &.{},
    data_count: ?u32 = null,
    code: []const FuncBody = &.{},
    custom_sections: []const CustomSection = &.{},

    // Import counts per kind (prefix of each index space is imported).
    imported_funcs: u32 = 0,
    imported_tables: u32 = 0,
    imported_mems: u32 = 0,
    imported_tags: u32 = 0,
    imported_globals: u32 = 0,

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
    }

    pub fn totalFuncs(self: *const Module) u32 {
        return self.imported_funcs + @as(u32, @intCast(self.funcs.len));
    }

    pub fn totalTables(self: *const Module) u32 {
        return self.imported_tables + @as(u32, @intCast(self.tables.len));
    }

    pub fn totalMems(self: *const Module) u32 {
        return self.imported_mems + @as(u32, @intCast(self.mems.len));
    }

    pub fn totalGlobals(self: *const Module) u32 {
        return self.imported_globals + @as(u32, @intCast(self.globals.len));
    }

    pub fn totalTags(self: *const Module) u32 {
        return self.imported_tags + @as(u32, @intCast(self.tags.len));
    }

    pub fn funcTypeAt(self: *const Module, typeidx: u32) ?FuncType {
        if (typeidx >= self.types.len) return null;
        return self.types[typeidx].funcType();
    }

    /// Type of any tag in the index space (imports precede definitions).
    pub fn tagType(self: *const Module, tagidx: u32) FuncType {
        var i: u32 = tagidx;
        for (self.imports) |imp| switch (imp.desc) {
            .tag => |tag| {
                if (i == 0) return self.funcTypeAt(tag.type_index).?;
                i -= 1;
            },
            else => {},
        };
        return self.funcTypeAt(self.tags[i].type_index).?;
    }

    /// Type of any function in the index space (imported or defined).
    pub fn funcType(self: *const Module, funcidx: u32) FuncType {
        var i: u32 = funcidx;
        for (self.imports) |imp| {
            switch (imp.desc) {
                .func => |t| {
                    if (i == 0) return self.funcTypeAt(t).?;
                    i -= 1;
                },
                else => {},
            }
        }
        return self.funcTypeAt(self.funcs[i]).?;
    }

    /// Global type of any global in the index space (imported or defined).
    pub fn globalType(self: *const Module, globalidx: u32) GlobalType {
        var i: u32 = globalidx;
        for (self.imports) |imp| {
            switch (imp.desc) {
                .global => |g| {
                    if (i == 0) return g;
                    i -= 1;
                },
                else => {},
            }
        }
        return self.globals[i].type;
    }

    /// Table type at any table index (imports precede module-defined tables).
    pub fn tableType(self: *const Module, tableidx: u32) TableType {
        var i: u32 = tableidx;
        for (self.imports) |imp| {
            switch (imp.desc) {
                .table => |table| {
                    if (i == 0) return table;
                    i -= 1;
                },
                else => {},
            }
        }
        return self.tables[i];
    }

    /// Memory type at any memory index (imports precede module-defined memories).
    pub fn memoryType(self: *const Module, memidx: u32) MemType {
        var i: u32 = memidx;
        for (self.imports) |imp| {
            switch (imp.desc) {
                .mem => |memory| {
                    if (i == 0) return memory;
                    i -= 1;
                },
                else => {},
            }
        }
        return self.mems[i];
    }
};

test "wasm feature dependency validation is deterministic" {
    try std.testing.expectEqual(@as(?Features.DependencyFailure, null), (Features{}).missingDependency());
    try std.testing.expectEqualDeep(
        Features.DependencyFailure{ .feature = .gc, .required = .typed_function_references },
        (Features{ .reference_types = true, .gc = true }).missingDependency().?,
    );
    try std.testing.expectEqualDeep(
        Features.DependencyFailure{ .feature = .typed_function_references, .required = .reference_types },
        (Features{ .typed_function_references = true }).missingDependency().?,
    );
    try std.testing.expectEqual(@as(?Features.DependencyFailure, null), (Features{
        .reference_types = true,
        .typed_function_references = true,
        .gc = true,
    }).missingDependency());
}

test "op encoding is total over MVP bytes" {
    // Spot-check encodings that matter for a total decoder map.
    try std.testing.expectEqual(Op.i32_load, Op.fromByte(0x28).?);
    try std.testing.expectEqual(Op.f64_promote_f32, Op.fromByte(0xBB).?);
    try std.testing.expectEqual(Op.memory_grow, Op.fromByte(0x40).?);
    // Proposal prefixes and gaps are not MVP ops. 0xFC (misc/bulk-memory)
    // remains unmapped; 0xFD is the recognized SIMD prefix op.
    try std.testing.expectEqual(@as(?Op, null), Op.fromByte(0xFC));
    try std.testing.expectEqual(Op.simd, Op.fromByte(0xFD).?);
}

test "diagnostic truncation stays deterministic" {
    const long = @as([500]u8, @splat('x'));
    var d: Diagnostic = .{};
    d.set(7, "{s}", .{long});
    try std.testing.expectEqual(@as(u32, 7), d.offset);
    try std.testing.expect(d.message().len <= d.buf.len);
}
