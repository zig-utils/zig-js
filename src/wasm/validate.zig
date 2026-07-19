//! Strict WebAssembly MVP (wg-1.0) validator.
//!
//! Consumes the IR from `types.zig` (produced by `decode.zig`) and enforces
//! wg-1.0 validation: module-level index/type checks plus the standard
//! abstract-interpretation algorithm over each function body. All failures
//! are `error.Invalid` with a deterministic `(offset, message)` diagnostic:
//! body errors carry the byte offset of the offending instruction
//! (`FuncBody.offsets`), module-level errors use `Diagnostic.no_offset`.

const std = @import("std");
const atomic = @import("atomic.zig");
const gc = @import("gc.zig");
const types = @import("types.zig");
const simd = @import("simd.zig");
const simd_meta = @import("simd_validate.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{Invalid};

fn unsupportedFeature(mod: *const types.Module, diag: *types.Diagnostic, feature: types.Feature) Error {
    return if (mod.features.enabled(feature))
        failModFmt(diag, "WebAssembly feature {s} is enabled but not implemented", .{feature.name()})
    else
        failModFmt(diag, "WebAssembly feature {s} is disabled", .{feature.name()});
}

fn validateValType(mod: *const types.Module, value_type: types.ValType, diag: *types.Diagnostic) Error!void {
    if (value_type == .exnref and !mod.features.exception_handling)
        return unsupportedFeature(mod, diag, .exception_handling);
    if (value_type == .v128 and !mod.features.fixed_width_simd)
        return unsupportedFeature(mod, diag, .fixed_width_simd);
    const ref_type = value_type.refType() orelse return;
    const explicit_reference = @intFromEnum(value_type) > std.math.maxInt(u32);
    if ((explicit_reference or value_type == .nofuncref or value_type == .noexternref) and
        !mod.features.typed_function_references)
        return unsupportedFeature(mod, diag, .typed_function_references);
    if (value_type.isGcReference()) {
        if (!mod.features.gc) return unsupportedFeature(mod, diag, .gc);
    } else if (!mod.features.reference_types) {
        return unsupportedFeature(mod, diag, .reference_types);
    }
    if (ref_type.heap.concreteIndex()) |index|
        if (index >= mod.types.len) return failMod(diag, "unknown type");
}

fn compositeKind(definition: types.DefType) enum { func, struct_, array } {
    return switch (definition.subtype.composite) {
        .func => .func,
        .struct_ => .struct_,
        .array => .array,
    };
}

fn topHeapType(mod: *const types.Module, heap: types.HeapType) types.HeapType {
    if (heap.concreteIndex()) |index| return switch (compositeKind(mod.types[index])) {
        .func => .func,
        .struct_, .array => .any,
    };
    return switch (heap) {
        .func, .nofunc => .func,
        .extern_, .noextern => .extern_,
        .any, .eq, .i31, .struct_, .array, .none => .any,
        else => unreachable,
    };
}

fn groupContains(group: types.RecGroup, index: u32) bool {
    return index >= group.start and index - group.start < group.len;
}

fn heapTypeEquivalentInGroups(
    mod: *const types.Module,
    a: types.HeapType,
    b: types.HeapType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    if (a.concreteIndex()) |a_index| {
        const b_index = b.concreteIndex() orelse return false;
        const a_internal = groupContains(a_group, a_index);
        const b_internal = groupContains(b_group, b_index);
        if (a_internal or b_internal)
            return a_internal and b_internal and a_index - a_group.start == b_index - b_group.start;
        return definedTypeEquivalentDepth(mod, a_index, b_index, depth + 1);
    }
    return a == b;
}

fn valTypeEquivalentInGroups(
    mod: *const types.Module,
    a: types.ValType,
    b: types.ValType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    if (a == b) return true;
    const a_ref = a.refType() orelse return false;
    const b_ref = b.refType() orelse return false;
    return a_ref.nullable == b_ref.nullable and
        heapTypeEquivalentInGroups(mod, a_ref.heap, b_ref.heap, a_group, b_group, depth);
}

fn storageTypeEquivalentInGroups(
    mod: *const types.Module,
    a: types.StorageType,
    b: types.StorageType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    return switch (a) {
        .i8 => b == .i8,
        .i16 => b == .i16,
        .value => |a_value| switch (b) {
            .value => |b_value| valTypeEquivalentInGroups(mod, a_value, b_value, a_group, b_group, depth),
            else => false,
        },
    };
}

fn compositeTypeEquivalentInGroups(
    mod: *const types.Module,
    a: types.CompositeType,
    b: types.CompositeType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    return switch (a) {
        .func => |a_func| switch (b) {
            .func => |b_func| blk: {
                if (a_func.params.len != b_func.params.len or a_func.results.len != b_func.results.len)
                    break :blk false;
                for (a_func.params, b_func.params) |a_param, b_param|
                    if (!valTypeEquivalentInGroups(mod, a_param, b_param, a_group, b_group, depth)) break :blk false;
                for (a_func.results, b_func.results) |a_result, b_result|
                    if (!valTypeEquivalentInGroups(mod, a_result, b_result, a_group, b_group, depth)) break :blk false;
                break :blk true;
            },
            else => false,
        },
        .struct_ => |a_struct| switch (b) {
            .struct_ => |b_struct| blk: {
                if (a_struct.fields.len != b_struct.fields.len) break :blk false;
                for (a_struct.fields, b_struct.fields) |a_field, b_field| {
                    if (a_field.mutable != b_field.mutable or
                        !storageTypeEquivalentInGroups(mod, a_field.storage, b_field.storage, a_group, b_group, depth))
                        break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .array => |a_array| switch (b) {
            .array => |b_array| a_array.field.mutable == b_array.field.mutable and
                storageTypeEquivalentInGroups(mod, a_array.field.storage, b_array.field.storage, a_group, b_group, depth),
            else => false,
        },
    };
}

fn definedTypeEquivalentDepth(mod: *const types.Module, a_index: u32, b_index: u32, depth: usize) bool {
    if (a_index == b_index) return true;
    if (a_index >= mod.types.len or b_index >= mod.types.len or depth > mod.rec_groups.len) return false;
    const a_definition = mod.types[a_index];
    const b_definition = mod.types[b_index];
    if (a_definition.rec_group >= mod.rec_groups.len or b_definition.rec_group >= mod.rec_groups.len)
        return false;
    const a_group = mod.rec_groups[a_definition.rec_group];
    const b_group = mod.rec_groups[b_definition.rec_group];
    if (a_definition.rec_index != b_definition.rec_index or a_group.len != b_group.len) return false;

    for (0..a_group.len) |rec_index| {
        const a_subtype = mod.types[a_group.start + rec_index].subtype;
        const b_subtype = mod.types[b_group.start + rec_index].subtype;
        if (a_subtype.final != b_subtype.final or a_subtype.supertypes.len != b_subtype.supertypes.len)
            return false;
        for (a_subtype.supertypes, b_subtype.supertypes) |a_super, b_super|
            if (!heapTypeEquivalentInGroups(
                mod,
                types.HeapType.concrete(a_super),
                types.HeapType.concrete(b_super),
                a_group,
                b_group,
                depth,
            )) return false;
        if (!compositeTypeEquivalentInGroups(
            mod,
            a_subtype.composite,
            b_subtype.composite,
            a_group,
            b_group,
            depth,
        )) return false;
    }
    return true;
}

fn definedTypeEquivalent(mod: *const types.Module, a_index: u32, b_index: u32) bool {
    return definedTypeEquivalentDepth(mod, a_index, b_index, 0);
}

fn heapTypeEquivalentAcrossGroups(
    a_mod: *const types.Module,
    b_mod: *const types.Module,
    a: types.HeapType,
    b: types.HeapType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    if (a.concreteIndex()) |a_index| {
        const b_index = b.concreteIndex() orelse return false;
        const a_internal = groupContains(a_group, a_index);
        const b_internal = groupContains(b_group, b_index);
        if (a_internal or b_internal)
            return a_internal and b_internal and a_index - a_group.start == b_index - b_group.start;
        return definedTypeEquivalentAcrossDepth(a_mod, a_index, b_mod, b_index, depth + 1);
    }
    return a == b;
}

fn valTypeEquivalentAcrossGroups(
    a_mod: *const types.Module,
    b_mod: *const types.Module,
    a: types.ValType,
    b: types.ValType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    const a_ref = a.refType() orelse return a == b;
    const b_ref = b.refType() orelse return false;
    return a_ref.nullable == b_ref.nullable and heapTypeEquivalentAcrossGroups(
        a_mod,
        b_mod,
        a_ref.heap,
        b_ref.heap,
        a_group,
        b_group,
        depth,
    );
}

fn storageTypeEquivalentAcrossGroups(
    a_mod: *const types.Module,
    b_mod: *const types.Module,
    a: types.StorageType,
    b: types.StorageType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    return switch (a) {
        .i8 => b == .i8,
        .i16 => b == .i16,
        .value => |a_value| switch (b) {
            .value => |b_value| valTypeEquivalentAcrossGroups(a_mod, b_mod, a_value, b_value, a_group, b_group, depth),
            else => false,
        },
    };
}

fn compositeTypeEquivalentAcrossGroups(
    a_mod: *const types.Module,
    b_mod: *const types.Module,
    a: types.CompositeType,
    b: types.CompositeType,
    a_group: types.RecGroup,
    b_group: types.RecGroup,
    depth: usize,
) bool {
    return switch (a) {
        .func => |a_func| switch (b) {
            .func => |b_func| blk: {
                if (a_func.params.len != b_func.params.len or a_func.results.len != b_func.results.len)
                    break :blk false;
                for (a_func.params, b_func.params) |a_param, b_param|
                    if (!valTypeEquivalentAcrossGroups(a_mod, b_mod, a_param, b_param, a_group, b_group, depth)) break :blk false;
                for (a_func.results, b_func.results) |a_result, b_result|
                    if (!valTypeEquivalentAcrossGroups(a_mod, b_mod, a_result, b_result, a_group, b_group, depth)) break :blk false;
                break :blk true;
            },
            else => false,
        },
        .struct_ => |a_struct| switch (b) {
            .struct_ => |b_struct| blk: {
                if (a_struct.fields.len != b_struct.fields.len) break :blk false;
                for (a_struct.fields, b_struct.fields) |a_field, b_field| {
                    if (a_field.mutable != b_field.mutable or
                        !storageTypeEquivalentAcrossGroups(a_mod, b_mod, a_field.storage, b_field.storage, a_group, b_group, depth))
                        break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .array => |a_array| switch (b) {
            .array => |b_array| a_array.field.mutable == b_array.field.mutable and
                storageTypeEquivalentAcrossGroups(a_mod, b_mod, a_array.field.storage, b_array.field.storage, a_group, b_group, depth),
            else => false,
        },
    };
}

fn definedTypeEquivalentAcrossDepth(
    a_mod: *const types.Module,
    a_index: u32,
    b_mod: *const types.Module,
    b_index: u32,
    depth: usize,
) bool {
    if (a_mod == b_mod) return definedTypeEquivalentDepth(a_mod, a_index, b_index, depth);
    if (a_index >= a_mod.types.len or b_index >= b_mod.types.len or
        depth > a_mod.rec_groups.len + b_mod.rec_groups.len) return false;
    const a_definition = a_mod.types[a_index];
    const b_definition = b_mod.types[b_index];
    if (a_definition.rec_group >= a_mod.rec_groups.len or b_definition.rec_group >= b_mod.rec_groups.len)
        return false;
    const a_group = a_mod.rec_groups[a_definition.rec_group];
    const b_group = b_mod.rec_groups[b_definition.rec_group];
    if (a_definition.rec_index != b_definition.rec_index or a_group.len != b_group.len) return false;

    for (0..a_group.len) |rec_index| {
        const a_subtype = a_mod.types[a_group.start + rec_index].subtype;
        const b_subtype = b_mod.types[b_group.start + rec_index].subtype;
        if (a_subtype.final != b_subtype.final or a_subtype.supertypes.len != b_subtype.supertypes.len)
            return false;
        for (a_subtype.supertypes, b_subtype.supertypes) |a_super, b_super|
            if (!heapTypeEquivalentAcrossGroups(
                a_mod,
                b_mod,
                types.HeapType.concrete(a_super),
                types.HeapType.concrete(b_super),
                a_group,
                b_group,
                depth,
            )) return false;
        if (!compositeTypeEquivalentAcrossGroups(
            a_mod,
            b_mod,
            a_subtype.composite,
            b_subtype.composite,
            a_group,
            b_group,
            depth,
        )) return false;
    }
    return true;
}

pub fn definedTypesEquivalentAcross(a_mod: *const types.Module, a_index: u32, b_mod: *const types.Module, b_index: u32) bool {
    return definedTypeEquivalentAcrossDepth(a_mod, a_index, b_mod, b_index, 0);
}

pub fn valTypesEquivalentAcross(a_mod: *const types.Module, a: types.ValType, b_mod: *const types.Module, b: types.ValType) bool {
    const a_ref = a.refType() orelse return a == b;
    const b_ref = b.refType() orelse return false;
    if (a_ref.nullable != b_ref.nullable) return false;
    if (a_ref.heap.concreteIndex()) |a_index| {
        const b_index = b_ref.heap.concreteIndex() orelse return false;
        return definedTypesEquivalentAcross(a_mod, a_index, b_mod, b_index);
    }
    return a_ref.heap == b_ref.heap;
}

pub fn funcTypesEquivalentAcross(a_mod: *const types.Module, a: types.FuncType, b_mod: *const types.Module, b: types.FuncType) bool {
    if (a.params.len != b.params.len or a.results.len != b.results.len) return false;
    for (a.params, b.params) |a_param, b_param|
        if (!valTypesEquivalentAcross(a_mod, a_param, b_mod, b_param)) return false;
    for (a.results, b.results) |a_result, b_result|
        if (!valTypesEquivalentAcross(a_mod, a_result, b_mod, b_result)) return false;
    return true;
}

pub fn heapTypeMatchesAcross(
    sub_mod: *const types.Module,
    sub: types.HeapType,
    super_mod: *const types.Module,
    super: types.HeapType,
) bool {
    if (sub.concreteIndex()) |start| {
        if (start >= sub_mod.types.len) return false;
        var index = start;
        while (true) {
            const definition = sub_mod.types[index];
            if (super.concreteIndex()) |wanted| {
                if (definedTypesEquivalentAcross(sub_mod, index, super_mod, wanted)) return true;
            } else switch (compositeKind(definition)) {
                .func => if (super == .func) return true,
                .struct_ => if (super == .struct_ or super == .eq or super == .any) return true,
                .array => if (super == .array or super == .eq or super == .any) return true,
            }
            if (definition.subtype.supertypes.len == 0) return false;
            index = definition.subtype.supertypes[0];
            if (index >= sub_mod.types.len) return false;
        }
    }
    if (super.concreteIndex()) |wanted| {
        if (wanted >= super_mod.types.len) return false;
        return switch (sub) {
            .nofunc => compositeKind(super_mod.types[wanted]) == .func,
            .none => compositeKind(super_mod.types[wanted]) != .func,
            else => false,
        };
    }
    return heapTypeMatches(sub_mod, sub, super);
}

/// Nominal heap matching from the pinned GC proposal. Concrete definitions
/// follow their declared (earlier) supertype chain; abstract nodes form the
/// three disjoint function, external, and internal hierarchies.
pub fn heapTypeMatches(mod: *const types.Module, sub: types.HeapType, super: types.HeapType) bool {
    if (sub == super) return true;

    if (sub.concreteIndex()) |start| {
        if (start >= mod.types.len) return false;
        var index = start;
        while (true) {
            const definition = mod.types[index];
            if (super.concreteIndex()) |wanted| {
                if (definedTypeEquivalent(mod, index, wanted)) return true;
            } else switch (compositeKind(definition)) {
                .func => if (super == .func) return true,
                .struct_ => if (super == .struct_ or super == .eq or super == .any) return true,
                .array => if (super == .array or super == .eq or super == .any) return true,
            }
            if (definition.subtype.supertypes.len == 0) return false;
            index = definition.subtype.supertypes[0];
            if (index >= mod.types.len) return false;
        }
    }

    if (super.concreteIndex()) |wanted| {
        if (wanted >= mod.types.len) return false;
        return switch (sub) {
            .nofunc => compositeKind(mod.types[wanted]) == .func,
            .none => compositeKind(mod.types[wanted]) != .func,
            else => false,
        };
    }

    return switch (sub) {
        .nofunc => super == .func,
        .noextern => super == .extern_,
        .none => super == .i31 or super == .struct_ or super == .array or super == .eq or super == .any,
        .i31 => super == .eq or super == .any,
        .struct_, .array => super == .eq or super == .any,
        .eq => super == .any,
        else => false,
    };
}

fn refTypeMatches(mod: *const types.Module, sub: types.RefType, super: types.RefType) bool {
    if (sub.nullable and !super.nullable) return false;
    return heapTypeMatches(mod, sub.heap, super.heap);
}

fn valTypeMatches(mod: *const types.Module, sub: types.ValType, super: types.ValType) bool {
    if (sub == super) return true;
    const sub_ref = sub.refType() orelse return false;
    const super_ref = super.refType() orelse return false;
    return refTypeMatches(mod, sub_ref, super_ref);
}

fn valTypeDefaultable(value_type: types.ValType) bool {
    const reference = value_type.refType() orelse return true;
    return reference.nullable;
}

fn storageTypeMatches(mod: *const types.Module, sub: types.StorageType, super: types.StorageType) bool {
    return switch (sub) {
        .i8 => super == .i8,
        .i16 => super == .i16,
        .value => |sub_value| switch (super) {
            .value => |super_value| valTypeMatches(mod, sub_value, super_value),
            else => false,
        },
    };
}

fn fieldTypeMatches(mod: *const types.Module, sub: types.FieldType, super: types.FieldType) bool {
    if (sub.mutable != super.mutable) return false;
    if (!storageTypeMatches(mod, sub.storage, super.storage)) return false;
    return !sub.mutable or storageTypeMatches(mod, super.storage, sub.storage);
}

fn compositeTypeMatches(mod: *const types.Module, sub: types.CompositeType, super: types.CompositeType) bool {
    return switch (sub) {
        .func => |sub_func| switch (super) {
            .func => |super_func| blk: {
                if (sub_func.params.len != super_func.params.len or sub_func.results.len != super_func.results.len)
                    break :blk false;
                // Function parameters are contravariant; results covariant.
                for (sub_func.params, super_func.params) |sub_param, super_param|
                    if (!valTypeMatches(mod, super_param, sub_param)) break :blk false;
                for (sub_func.results, super_func.results) |sub_result, super_result|
                    if (!valTypeMatches(mod, sub_result, super_result)) break :blk false;
                break :blk true;
            },
            else => false,
        },
        .struct_ => |sub_struct| switch (super) {
            .struct_ => |super_struct| blk: {
                if (sub_struct.fields.len < super_struct.fields.len) break :blk false;
                for (sub_struct.fields[0..super_struct.fields.len], super_struct.fields) |sub_field, super_field|
                    if (!fieldTypeMatches(mod, sub_field, super_field)) break :blk false;
                break :blk true;
            },
            else => false,
        },
        .array => |sub_array| switch (super) {
            .array => |super_array| fieldTypeMatches(mod, sub_array.field, super_array.field),
            else => false,
        },
    };
}

fn validateValTypeVisible(
    mod: *const types.Module,
    value_type: types.ValType,
    visible_types: u32,
    diag: *types.Diagnostic,
) Error!void {
    try validateValType(mod, value_type, diag);
    if (value_type.refType()) |reference|
        if (reference.heap.concreteIndex()) |index|
            if (index >= visible_types) return failMod(diag, "unknown type");
}

fn validateStorageTypeVisible(
    mod: *const types.Module,
    storage: types.StorageType,
    visible_types: u32,
    diag: *types.Diagnostic,
) Error!void {
    switch (storage) {
        .value => |value| try validateValTypeVisible(mod, value, visible_types, diag),
        .i8, .i16 => {},
    }
}

fn validateCompositeType(
    mod: *const types.Module,
    composite: types.CompositeType,
    visible_types: u32,
    diag: *types.Diagnostic,
) Error!void {
    switch (composite) {
        .func => |function| {
            if (function.results.len > 1 and !mod.features.multi_value)
                return failMod(diag, "invalid result arity");
            for (function.params) |param| try validateValTypeVisible(mod, param, visible_types, diag);
            for (function.results) |result| try validateValTypeVisible(mod, result, visible_types, diag);
        },
        .struct_ => |structure| for (structure.fields) |field|
            try validateStorageTypeVisible(mod, field.storage, visible_types, diag),
        .array => |array| try validateStorageTypeVisible(mod, array.field.storage, visible_types, diag),
    }
}

fn validateDefinedTypes(mod: *const types.Module, diag: *types.Diagnostic) Error!void {
    var next_definition: u32 = 0;
    for (mod.rec_groups, 0..) |group, group_index| {
        if (group.start != next_definition or group.start > mod.types.len or group.len > mod.types.len - group.start)
            return failMod(diag, "invalid recursive type group");
        for (0..group.len) |rec_index| {
            const definition = mod.types[group.start + rec_index];
            if (definition.rec_group != group_index or definition.rec_index != rec_index)
                return failMod(diag, "invalid recursive type group");
        }
        next_definition += group.len;
    }
    if (next_definition != mod.types.len) return failMod(diag, "invalid recursive type group");
    for (mod.types, 0..) |definition, index_usize| {
        const index: u32 = @intCast(index_usize);
        if (!mod.features.gc and (definition.funcType() == null or definition.subtype.supertypes.len != 0))
            return unsupportedFeature(mod, diag, .gc);
        const group = mod.rec_groups[definition.rec_group];
        try validateCompositeType(mod, definition.subtype.composite, group.start + group.len, diag);
        if (definition.subtype.supertypes.len > 1)
            return failMod(diag, "multiple supertypes");
        for (definition.subtype.supertypes) |super_index| {
            if (super_index >= index or super_index >= mod.types.len)
                return failMod(diag, "invalid supertype index");
            const super = mod.types[super_index];
            if (super.subtype.final) return failMod(diag, "cannot subtype final type");
            if (!compositeTypeMatches(mod, definition.subtype.composite, super.subtype.composite))
                return failMod(diag, "type mismatch");
        }
    }
}

pub fn validate(mod: *const types.Module, diag: *types.Diagnostic) Error!void {
    validateWithAllocator(mod, diag, std.heap.page_allocator) catch |err| switch (err) {
        error.OutOfMemory => return failMod(diag, "out of memory"),
        error.Invalid => return error.Invalid,
    };
}

fn validateWithAllocator(mod: *const types.Module, diag: *types.Diagnostic, allocator: Allocator) (Error || Allocator.Error)!void {
    // 1. Type indices must resolve; reference value positions are opt-in.
    try validateDefinedTypes(mod, diag);
    for (mod.imports) |imp| switch (imp.desc) {
        .func => |t| {
            if (t >= mod.types.len) return failMod(diag, "unknown type");
            if (mod.funcTypeAt(t) == null) return failMod(diag, "type mismatch");
        },
        .global => |g| try validateValType(mod, g.val, diag),
        .tag => |tag| try validateTagType(mod, tag, diag),
        else => {},
    };
    for (mod.funcs) |t| {
        if (t >= mod.types.len) return failMod(diag, "unknown type");
        if (mod.funcTypeAt(t) == null) return failMod(diag, "type mismatch");
    }
    for (mod.tags) |tag| try validateTagType(mod, tag, diag);

    // 2. MVP allows at most one table and one memory (imports + defined).
    if (mod.totalTables() > 1 and !mod.features.reference_types) return failMod(diag, "multiple tables");
    if (mod.totalMems() > 1) return failMod(diag, "multiple memories");
    for (0..mod.totalTables()) |tableidx| {
        const elem_type = mod.tableType(@intCast(tableidx)).elem;
        if (elem_type != .funcref) try validateValType(mod, elem_type, diag);
    }
    for (mod.tables) |table|
        if (table.init) |init|
            try checkConstExpr(mod, init, table.elem, mod.imported_globals, diag, allocator);
    for (0..mod.totalMems()) |memidx| {
        const memory = mod.memoryType(@intCast(memidx));
        if (memory.shared and memory.limits.max == null)
            return failMod(diag, "shared memory must have maximum");
    }

    // 3. Global initializers: typed constant expressions.
    for (mod.globals, 0..) |g, index| {
        try validateValType(mod, g.type.val, diag);
        try checkConstExpr(
            mod,
            g.init,
            g.type.val,
            mod.imported_globals + @as(u32, @intCast(index)),
            diag,
            allocator,
        );
    }
    for (mod.code) |body| {
        for (body.locals) |local|
            try validateValType(mod, local, diag);
    }

    // 4. Element segments.
    for (mod.elems) |e| {
        // MVP element segments use the implicit funcref type without opting
        // into the later reference-types feature.
        if (e.type != .funcref) try validateValType(mod, e.type, diag);
        switch (e.mode) {
            .active => |active| {
                if (active.table >= mod.totalTables())
                    return failModFmt(diag, "unknown table {d}", .{active.table});
                if (!valTypeMatches(mod, e.type, mod.tableType(active.table).elem))
                    return failMod(diag, "type mismatch");
                try checkConstExpr(mod, active.offset, mod.tableType(active.table).address.valType(), mod.totalGlobals(), diag, allocator);
            },
            .passive, .declarative => {},
        }
        for (e.init) |init| try checkConstExpr(mod, init, e.type, mod.totalGlobals(), diag, allocator);
    }

    // 5. Data segments.
    for (mod.datas) |d| {
        switch (d.mode) {
            .active => |active| {
                if (active.mem >= mod.totalMems())
                    return failModFmt(diag, "unknown memory {d}", .{active.mem});
                try checkConstExpr(mod, active.offset, mod.memoryType(active.mem).address.valType(), mod.totalGlobals(), diag, allocator);
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
            .tag => if (e.index >= mod.totalTags())
                return failMod(diag, "unknown tag"),
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
        try validateFunc(mod, diag, mod.funcTypeAt(typeidx).?, body, allocator);
}

fn validateTagType(mod: *const types.Module, tag: types.Tag, diag: *types.Diagnostic) Error!void {
    if (!mod.features.exception_handling) return unsupportedFeature(mod, diag, .exception_handling);
    if (tag.type_index >= mod.types.len) return failMod(diag, "unknown type");
    const function_type = mod.funcTypeAt(tag.type_index) orelse return failMod(diag, "type mismatch");
    if (function_type.results.len != 0)
        return failMod(diag, "non-empty tag result type");
}

fn failMod(diag: *types.Diagnostic, comptime msg: []const u8) Error {
    diag.set(types.Diagnostic.no_offset, msg, .{});
    return error.Invalid;
}

fn failModFmt(diag: *types.Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.set(types.Diagnostic.no_offset, fmt, args);
    return error.Invalid;
}

/// A constant expression of type `expected`. MVP `global.get` is import-only;
/// GC expressions may also see immutable module globals declared earlier.
fn checkConstExpr(
    mod: *const types.Module,
    expr: types.ConstExpr,
    expected: types.ValType,
    visible_globals: u32,
    diag: *types.Diagnostic,
    allocator: Allocator,
) (Error || Allocator.Error)!void {
    switch (expr) {
        .global => |gi| {
            if (gi >= mod.imported_globals) return failMod(diag, "unknown global");
            const gt = mod.globalType(gi);
            if (gt.mutable) return failMod(diag, "constant expression required");
            if (!valTypeMatches(mod, gt.val, expected)) return failMod(diag, "type mismatch");
        },
        .ref_func => |funcidx| {
            if (funcidx >= mod.totalFuncs()) return failModFmt(diag, "unknown function {d}", .{funcidx});
            const result_type = if (mod.features.typed_function_references)
                types.ValType.fromRef(.{ .nullable = false, .heap = .concrete(mod.funcTypeIndex(funcidx)) })
            else
                types.ValType.funcref;
            if (!valTypeMatches(mod, result_type, expected)) return failMod(diag, "type mismatch");
        },
        .extended => |extended| try checkExtendedConstExpr(mod, extended, expected, visible_globals, diag, allocator),
        else => if (!valTypeMatches(mod, expr.valType(), expected))
            return failMod(diag, "type mismatch"),
    }
}

fn gcConstOp(instr: types.Instr) ?gc.Op {
    return switch (instr.imm) {
        .gc => |op| op,
        .gc_type => |immediate| immediate.op,
        .gc_two_indices => |immediate| immediate.op,
        else => null,
    };
}

fn isExtendedConstInstruction(instr: types.Instr) bool {
    return switch (instr.op) {
        .i32_const,
        .i64_const,
        .f32_const,
        .f64_const,
        .global_get,
        .ref_null,
        .ref_func,
        .end,
        => true,
        .simd => switch (instr.imm) {
            .simd_v128 => |immediate| immediate.op == .v128_const,
            else => false,
        },
        .gc => switch (gcConstOp(instr) orelse return false) {
            .ref_i31,
            .struct_new,
            .struct_new_default,
            .array_new,
            .array_new_default,
            .array_new_fixed,
            .any_convert_extern,
            .extern_convert_any,
            => true,
            else => false,
        },
        else => false,
    };
}

fn checkExtendedConstExpr(
    mod: *const types.Module,
    extended: anytype,
    expected: types.ValType,
    visible_globals: u32,
    diag: *types.Diagnostic,
    allocator: Allocator,
) (Error || Allocator.Error)!void {
    for (extended.instrs, 0..) |instr, index| {
        if (!isExtendedConstInstruction(instr) or (instr.op == .end and index != extended.instrs.len - 1)) {
            diag.set(extended.offsets[index], "constant expression required", .{});
            return error.Invalid;
        }
        if (instr.op == .global_get) {
            const global_index = instr.imm.idx;
            if (global_index >= visible_globals) {
                diag.set(extended.offsets[index], "unknown global", .{});
                return error.Invalid;
            }
            if (mod.globalType(global_index).mutable) {
                diag.set(extended.offsets[index], "constant expression required", .{});
                return error.Invalid;
            }
        }
    }

    const slots = extended.instrs.len + 1;
    const opds = try allocator.alloc(StackVal, slots);
    defer allocator.free(opds);
    const frames = try allocator.alloc(Frame, slots);
    defer allocator.free(frames);
    var v: FuncValidator = .{
        .mod = mod,
        .diag = diag,
        .params = &.{},
        .locals = &.{},
        .locals_init = &.{},
        .init_stack = &.{},
        .instrs = extended.instrs,
        .offsets = extended.offsets,
        .opds = opds,
        .frames = frames,
    };
    try v.pushFrame(.block, .{ .params = &.{}, .results = &.{expected} });
    try v.run();
}

fn constExprDeclaresFunction(expr: types.ConstExpr, funcidx: u32) bool {
    return switch (expr) {
        .ref_func => |declared| declared == funcidx,
        .extended => |extended| for (extended.instrs) |instr| {
            if (instr.op == .ref_func and instr.imm.idx == funcidx) break true;
        } else false,
        else => false,
    };
}

fn isDeclaredFunction(mod: *const types.Module, funcidx: u32) bool {
    for (mod.exports) |exported|
        if (exported.kind == .func and exported.index == funcidx) return true;
    for (mod.tables) |table|
        if (table.init) |init|
            if (constExprDeclaresFunction(init, funcidx)) return true;
    for (mod.globals) |global|
        if (constExprDeclaresFunction(global.init, funcidx)) return true;
    for (mod.elems) |elem|
        for (elem.init) |init|
            if (constExprDeclaresFunction(init, funcidx)) return true;
    return false;
}

/// Abstract operand: a concrete numeric type or `unknown`, the bottom type
/// produced by the polymorphic stack after `unreachable`/branches.
const StackVal = enum(u64) {
    unknown = 0,
    i32 = @intFromEnum(types.ValType.i32),
    i64 = @intFromEnum(types.ValType.i64),
    f32 = @intFromEnum(types.ValType.f32),
    f64 = @intFromEnum(types.ValType.f64),
    v128 = @intFromEnum(types.ValType.v128),
    funcref = @intFromEnum(types.ValType.funcref),
    exnref = @intFromEnum(types.ValType.exnref),
    externref = @intFromEnum(types.ValType.externref),
    _,
};

fn stackVal(vt: types.ValType) StackVal {
    return @enumFromInt(@intFromEnum(vt));
}

const FrameKind = enum { block, loop, if_, try_table };

const Frame = struct {
    kind: FrameKind,
    params: []const types.ValType,
    results: []const types.ValType,
    height: usize,
    init_height: usize,
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

const AtomicDecoded = struct {
    op: atomic.Op,
    memarg: ?types.Instr.MemArg = null,
};

fn atomicDecoded(instr: types.Instr) AtomicDecoded {
    return switch (instr.imm) {
        .atomic => |op| .{ .op = op },
        .atomic_memarg => |value| .{ .op = value.op, .memarg = value.memarg },
        else => unreachable,
    };
}

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
    locals_init: []bool,
    init_stack: []u32,
    init_len: usize = 0,
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
        if (v != .unknown and !valTypeMatches(self.mod, @enumFromInt(@intFromEnum(v)), t))
            return self.fail("type mismatch");
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
            if (actual != .unknown and !valTypeMatches(self.mod, @enumFromInt(@intFromEnum(actual)), values[i]))
                return self.fail("type mismatch");
        }
    }

    fn pushTypes(self: *FuncValidator, values: []const types.ValType) void {
        for (values) |value| self.push(stackVal(value));
    }

    fn pushFrame(self: *FuncValidator, kind: FrameKind, ft: types.FuncType) Error!void {
        try self.popTypes(ft.params);
        self.frames[self.fr_len] = .{
            .kind = kind,
            .params = ft.params,
            .results = ft.results,
            .height = self.op_len,
            .init_height = self.init_len,
        };
        self.fr_len += 1;
        self.pushTypes(ft.params);
    }

    fn resetLocals(self: *FuncValidator, height: usize) void {
        while (self.init_len > height) {
            self.init_len -= 1;
            self.locals_init[self.init_stack[self.init_len]] = false;
        }
    }

    fn setLocalInitialized(self: *FuncValidator, index: u32) void {
        if (self.locals_init[index]) return;
        self.locals_init[index] = true;
        self.init_stack[self.init_len] = index;
        self.init_len += 1;
    }

    /// End-of-frame rule: the operands above the frame height must be exactly
    /// the frame results (count + types, tolerating unreachable).
    fn popFrame(self: *FuncValidator) Error!Frame {
        std.debug.assert(self.fr_len > 0);
        const f = self.frames[self.fr_len - 1];
        try self.popTypes(f.results);
        if (self.op_len != f.height) return self.fail("type mismatch");
        self.resetLocals(f.init_height);
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

    fn catchTagType(self: *FuncValidator, tag_index: u32) Error!types.FuncType {
        if (tag_index >= self.mod.totalTags()) return self.fail("unknown tag");
        return self.mod.tagType(tag_index);
    }

    fn validateCatch(self: *FuncValidator, catch_clause: types.Instr.Catch) Error!void {
        const target_frame = try self.target(catch_clause.labelIndex());
        const target_types = target_frame.branchTypes();
        switch (catch_clause) {
            .catch_tag => |tagged| {
                const tag_type = try self.catchTagType(tagged.tag_index);
                if (!std.mem.eql(types.ValType, target_types, tag_type.params))
                    return self.fail("type mismatch");
            },
            .catch_ref => |tagged| {
                const tag_type = try self.catchTagType(tagged.tag_index);
                if (target_types.len != tag_type.params.len + 1 or target_types[target_types.len - 1] != .exnref or
                    !std.mem.eql(types.ValType, target_types[0..tag_type.params.len], tag_type.params))
                    return self.fail("type mismatch");
            },
            .catch_all => if (target_types.len != 0) return self.fail("type mismatch"),
            .catch_all_ref => if (target_types.len != 1 or target_types[0] != .exnref)
                return self.fail("type mismatch"),
        }
    }

    fn memAddressType(self: *FuncValidator, memidx: u32) Error!types.ValType {
        if (memidx >= self.mod.totalMems())
            return if (memidx == 0) self.fail("unknown memory 0") else self.fail("unknown memory");
        return self.mod.memoryType(memidx).address.valType();
    }

    fn memAccess(self: *FuncValidator, memarg: types.Instr.MemArg, log2_bytes: u32) Error!types.ValType {
        if (self.mod.totalMems() == 0) return self.fail("unknown memory 0");
        const address = self.mod.memoryType(0).address;
        if (address == .i32 and memarg.offset > std.math.maxInt(u32))
            return self.fail("memory offset exceeds address type");
        if (memarg.align_ > log2_bytes)
            return self.fail("alignment must not be larger than natural");
        return address.valType();
    }

    fn callFunc(self: *FuncValidator, ft: types.FuncType) Error!void {
        var i = ft.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(ft.params[i]);
        }
        self.pushTypes(ft.results);
    }

    fn tailCallFunc(self: *FuncValidator, ft: types.FuncType) Error!void {
        if (!std.mem.eql(types.ValType, ft.results, self.frames[0].results))
            return self.fail("type mismatch");
        try self.popTypes(ft.params);
        self.setUnreachable();
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

    fn concreteRef(index: u32, nullable: bool) types.ValType {
        return types.ValType.fromRef(.{ .nullable = nullable, .heap = types.HeapType.concrete(index) });
    }

    fn structType(self: *FuncValidator, index: u32) Error!types.StructType {
        if (index >= self.mod.types.len) return self.fail("unknown type");
        return switch (self.mod.types[index].subtype.composite) {
            .struct_ => |structure| structure,
            else => self.fail("type mismatch"),
        };
    }

    fn arrayType(self: *FuncValidator, index: u32) Error!types.ArrayType {
        if (index >= self.mod.types.len) return self.fail("unknown type");
        return switch (self.mod.types[index].subtype.composite) {
            .array => |array| array,
            else => self.fail("type mismatch"),
        };
    }

    fn requireDefaultable(self: *FuncValidator, value_type: types.ValType) Error!void {
        if (!valTypeDefaultable(value_type)) return self.fail("type is not defaultable");
    }

    fn requireNumericOrVector(self: *FuncValidator, value_type: types.ValType) Error!void {
        switch (value_type) {
            .i32, .i64, .f32, .f64, .v128 => {},
            else => return self.fail("type mismatch"),
        }
    }

    fn requirePlainOrPacked(self: *FuncValidator, op: gc.Op, storage: types.StorageType) Error!void {
        const is_packed = storage == .i8 or storage == .i16;
        const extended = switch (op) {
            .struct_get_s, .struct_get_u, .array_get_s, .array_get_u => true,
            else => false,
        };
        if (is_packed != extended) return self.fail("type mismatch");
    }

    fn popReference(self: *FuncValidator) Error!?types.RefType {
        const value = try self.pop();
        if (value == .unknown) return null;
        const value_type: types.ValType = @enumFromInt(@intFromEnum(value));
        return value_type.refType() orelse self.fail("type mismatch");
    }

    fn validateRefEq(self: *FuncValidator) Error!void {
        const eqref = types.ValType.fromRef(.{ .nullable = true, .heap = .eq });
        try self.popExpect(eqref);
        try self.popExpect(eqref);
        self.push(.i32);
    }

    fn validateRefAsNonNull(self: *FuncValidator) Error!void {
        const reference = try self.popReference() orelse {
            self.push(.unknown);
            return;
        };
        self.push(stackVal(types.ValType.fromRef(.{ .nullable = false, .heap = reference.heap })));
    }

    fn validateBrOnNull(self: *FuncValidator, depth: u32) Error!void {
        const target_frame = try self.target(depth);
        const branch_types = target_frame.branchTypes();
        const reference = try self.popReference() orelse {
            try self.popTypes(branch_types);
            self.pushTypes(branch_types);
            self.push(.unknown);
            return;
        };
        try self.popTypes(branch_types);
        self.pushTypes(branch_types);
        self.push(stackVal(types.ValType.fromRef(.{ .nullable = false, .heap = reference.heap })));
    }

    fn validateBrOnNonNull(self: *FuncValidator, depth: u32) Error!void {
        const target_frame = try self.target(depth);
        const branch_types = target_frame.branchTypes();
        if (branch_types.len == 0) return self.fail("type mismatch");
        const label_reference = branch_types[branch_types.len - 1].refType() orelse
            return self.fail("type mismatch");
        if (label_reference.nullable) return self.fail("type mismatch");
        try self.popExpect(types.ValType.fromRef(.{
            .nullable = true,
            .heap = label_reference.heap,
        }));
        const prefix = branch_types[0 .. branch_types.len - 1];
        try self.popTypes(prefix);
        self.pushTypes(prefix);
    }

    fn validateGc(self: *FuncValidator, instr: types.Instr) Error!void {
        const op: gc.Op = switch (instr.imm) {
            .gc => |value| value,
            .gc_type => |value| value.op,
            .gc_type_field => |value| value.op,
            .gc_two_indices => |value| value.op,
            .gc_heap => |value| value.op,
            .gc_cast_branch => |value| value.op,
            else => unreachable,
        };
        switch (op) {
            .struct_new, .struct_new_default => {
                const type_index = instr.imm.gc_type.type_index;
                const structure = try self.structType(type_index);
                if (op == .struct_new) {
                    var index = structure.fields.len;
                    while (index > 0) {
                        index -= 1;
                        try self.popExpect(structure.fields[index].storage.unpacked());
                    }
                } else for (structure.fields) |field| {
                    try self.requireDefaultable(field.storage.unpacked());
                }
                self.push(stackVal(concreteRef(type_index, false)));
            },
            .struct_get, .struct_get_s, .struct_get_u => {
                const immediate = instr.imm.gc_type_field;
                const structure = try self.structType(immediate.type_index);
                if (immediate.field_index >= structure.fields.len) return self.fail("unknown field");
                const field = structure.fields[immediate.field_index];
                try self.requirePlainOrPacked(op, field.storage);
                try self.popExpect(concreteRef(immediate.type_index, true));
                self.push(stackVal(field.storage.unpacked()));
            },
            .struct_set => {
                const immediate = instr.imm.gc_type_field;
                const structure = try self.structType(immediate.type_index);
                if (immediate.field_index >= structure.fields.len) return self.fail("unknown field");
                const field = structure.fields[immediate.field_index];
                if (!field.mutable) return self.fail("field is immutable");
                try self.popExpect(field.storage.unpacked());
                try self.popExpect(concreteRef(immediate.type_index, true));
            },
            .array_new, .array_new_default, .array_new_fixed => {
                const immediate = if (op == .array_new_fixed)
                    instr.imm.gc_two_indices
                else
                    types.Instr.GcTwoIndices{ .op = op, .first = instr.imm.gc_type.type_index, .second = 0 };
                const array = try self.arrayType(immediate.first);
                switch (op) {
                    .array_new => {
                        try self.popExpect(.i32);
                        try self.popExpect(array.field.storage.unpacked());
                    },
                    .array_new_default => {
                        try self.requireDefaultable(array.field.storage.unpacked());
                        try self.popExpect(.i32);
                    },
                    .array_new_fixed => {
                        var count = immediate.second;
                        while (count > 0) : (count -= 1)
                            try self.popExpect(array.field.storage.unpacked());
                    },
                    else => unreachable,
                }
                self.push(stackVal(concreteRef(immediate.first, false)));
            },
            .array_new_data, .array_new_elem => {
                const immediate = instr.imm.gc_two_indices;
                const array = try self.arrayType(immediate.first);
                if (op == .array_new_data) {
                    try self.requireNumericOrVector(array.field.storage.unpacked());
                    if (immediate.second >= self.mod.datas.len) return self.fail("unknown data segment");
                } else {
                    const field_value = switch (array.field.storage) {
                        .value => |value| value,
                        else => return self.fail("type mismatch"),
                    };
                    if (immediate.second >= self.mod.elems.len) return self.fail("unknown element segment");
                    if (!valTypeMatches(self.mod, self.mod.elems[immediate.second].type, field_value))
                        return self.fail("type mismatch");
                }
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                self.push(stackVal(concreteRef(immediate.first, false)));
            },
            .array_get, .array_get_s, .array_get_u => {
                const immediate = instr.imm.gc_type;
                const array = try self.arrayType(immediate.type_index);
                try self.requirePlainOrPacked(op, array.field.storage);
                try self.popExpect(.i32);
                try self.popExpect(concreteRef(immediate.type_index, true));
                self.push(stackVal(array.field.storage.unpacked()));
            },
            .array_set => {
                const immediate = instr.imm.gc_type;
                const array = try self.arrayType(immediate.type_index);
                if (!array.field.mutable) return self.fail("field is immutable");
                try self.popExpect(array.field.storage.unpacked());
                try self.popExpect(.i32);
                try self.popExpect(concreteRef(immediate.type_index, true));
            },
            .array_len => {
                try self.popExpect(types.ValType.fromRef(.{ .nullable = true, .heap = .array }));
                self.push(.i32);
            },
            .array_fill => {
                const immediate = instr.imm.gc_type;
                const array = try self.arrayType(immediate.type_index);
                if (!array.field.mutable) return self.fail("field is immutable");
                try self.popExpect(.i32);
                try self.popExpect(array.field.storage.unpacked());
                try self.popExpect(.i32);
                try self.popExpect(concreteRef(immediate.type_index, true));
            },
            .array_copy => {
                const immediate = instr.imm.gc_two_indices;
                const destination = try self.arrayType(immediate.first);
                const source = try self.arrayType(immediate.second);
                if (!destination.field.mutable) return self.fail("field is immutable");
                if (!storageTypeMatches(self.mod, source.field.storage, destination.field.storage))
                    return self.fail("type mismatch");
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(concreteRef(immediate.second, true));
                try self.popExpect(.i32);
                try self.popExpect(concreteRef(immediate.first, true));
            },
            .array_init_data, .array_init_elem => {
                const immediate = instr.imm.gc_two_indices;
                const array = try self.arrayType(immediate.first);
                if (!array.field.mutable) return self.fail("field is immutable");
                if (op == .array_init_data) {
                    try self.requireNumericOrVector(array.field.storage.unpacked());
                    if (immediate.second >= self.mod.datas.len) return self.fail("unknown data segment");
                } else {
                    const field_value = switch (array.field.storage) {
                        .value => |value| value,
                        else => return self.fail("type mismatch"),
                    };
                    if (immediate.second >= self.mod.elems.len) return self.fail("unknown element segment");
                    if (!valTypeMatches(self.mod, self.mod.elems[immediate.second].type, field_value))
                        return self.fail("type mismatch");
                }
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(concreteRef(immediate.first, true));
            },
            .ref_test, .ref_test_null, .ref_cast, .ref_cast_null => {
                const immediate = instr.imm.gc_heap;
                if (immediate.heap.concreteIndex()) |index|
                    if (index >= self.mod.types.len) return self.fail("unknown type");
                const target_ref = types.RefType{
                    .nullable = op == .ref_test_null or op == .ref_cast_null,
                    .heap = immediate.heap,
                };
                try self.popExpect(types.ValType.fromRef(.{
                    .nullable = true,
                    .heap = topHeapType(self.mod, target_ref.heap),
                }));
                if (op == .ref_test or op == .ref_test_null) {
                    self.push(.i32);
                } else {
                    self.push(stackVal(types.ValType.fromRef(target_ref)));
                }
            },
            .br_on_cast, .br_on_cast_fail => {
                const immediate = instr.imm.gc_cast_branch;
                if (immediate.source_heap.concreteIndex()) |index|
                    if (index >= self.mod.types.len) return self.fail("unknown type");
                if (immediate.target_heap.concreteIndex()) |index|
                    if (index >= self.mod.types.len) return self.fail("unknown type");
                const source_ref: types.RefType = .{
                    .nullable = immediate.source_nullable,
                    .heap = immediate.source_heap,
                };
                const target_ref: types.RefType = .{
                    .nullable = immediate.target_nullable,
                    .heap = immediate.target_heap,
                };
                if (!refTypeMatches(self.mod, target_ref, source_ref)) return self.fail("type mismatch");

                const branch_frame = try self.target(immediate.label_index);
                const branch_types = branch_frame.branchTypes();
                if (branch_types.len == 0) return self.fail("type mismatch");
                const branch_reference = branch_types[branch_types.len - 1].refType() orelse
                    return self.fail("type mismatch");
                const difference_ref: types.RefType = .{
                    .nullable = source_ref.nullable and !target_ref.nullable,
                    .heap = source_ref.heap,
                };
                const value_on_branch = if (op == .br_on_cast) target_ref else difference_ref;
                if (!refTypeMatches(self.mod, value_on_branch, branch_reference))
                    return self.fail("type mismatch");

                try self.popExpect(types.ValType.fromRef(source_ref));
                const prefix = branch_types[0 .. branch_types.len - 1];
                try self.popTypes(prefix);
                self.pushTypes(prefix);
                const fallthrough = if (op == .br_on_cast) difference_ref else target_ref;
                self.push(stackVal(types.ValType.fromRef(fallthrough)));
            },
            .any_convert_extern, .extern_convert_any => {
                const source = try self.popReference() orelse {
                    self.push(.unknown);
                    return;
                };
                const expected: types.HeapType = if (op == .any_convert_extern) .extern_ else .any;
                if (!heapTypeMatches(self.mod, source.heap, expected)) return self.fail("type mismatch");
                const result: types.HeapType = if (op == .any_convert_extern) .any else .extern_;
                self.push(stackVal(types.ValType.fromRef(.{ .nullable = source.nullable, .heap = result })));
            },
            .ref_i31 => {
                try self.popExpect(.i32);
                self.push(stackVal(types.ValType.fromRef(.{ .nullable = false, .heap = .i31 })));
            },
            .i31_get_s, .i31_get_u => {
                try self.popExpect(types.ValType.fromRef(.{ .nullable = true, .heap = .i31 }));
                self.push(.i32);
            },
        }
    }

    fn validateSimd(self: *FuncValidator, instr: types.Instr) Error!void {
        const decoded = simdDecoded(instr);
        const address_type = if (decoded.memarg) |memarg|
            try self.memAccess(memarg, simd_meta.naturalAlignment(decoded.op).?)
        else
            types.ValType.i32;
        if (decoded.lane) |lane|
            if (lane >= simd_meta.laneLimit(decoded.op).?) return self.fail("invalid lane index");
        if (decoded.shuffle) |lanes|
            for (lanes) |lane| if (lane >= 32) return self.fail("invalid lane index");

        switch (simd_meta.shape(decoded.op)) {
            .load => {
                try self.popExpect(address_type);
                self.push(.v128);
            },
            .store, .lane_store => {
                try self.popExpect(.v128);
                try self.popExpect(address_type);
            },
            .lane_load => {
                try self.popExpect(.v128);
                try self.popExpect(address_type);
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

    fn validateAtomic(self: *FuncValidator, instr: types.Instr) Error!void {
        const decoded = atomicDecoded(instr);
        var address_type: types.ValType = .i32;
        if (decoded.memarg) |memarg| {
            address_type = try self.memAccess(memarg, decoded.op.naturalAlignment().?);
            if (memarg.align_ != decoded.op.naturalAlignment().?)
                return self.fail("atomic alignment must be natural");
        }
        switch (decoded.op.shape()) {
            .notify => {
                try self.popExpect(.i32);
                try self.popExpect(address_type);
                self.push(.i32);
            },
            .wait32 => {
                try self.popExpect(.i64);
                try self.popExpect(.i32);
                try self.popExpect(address_type);
                self.push(.i32);
            },
            .wait64 => {
                try self.popExpect(.i64);
                try self.popExpect(.i64);
                try self.popExpect(address_type);
                self.push(.i32);
            },
            .fence => {},
            .load_i32 => {
                try self.popExpect(address_type);
                self.push(.i32);
            },
            .load_i64 => {
                try self.popExpect(address_type);
                self.push(.i64);
            },
            .store_i32 => {
                try self.popExpect(.i32);
                try self.popExpect(address_type);
            },
            .store_i64 => {
                try self.popExpect(.i64);
                try self.popExpect(address_type);
            },
            .rmw_i32 => {
                try self.popExpect(.i32);
                try self.popExpect(address_type);
                self.push(.i32);
            },
            .rmw_i64 => {
                try self.popExpect(.i64);
                try self.popExpect(address_type);
                self.push(.i64);
            },
            .cmpxchg_i32 => {
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(address_type);
                self.push(.i32);
            },
            .cmpxchg_i64 => {
                try self.popExpect(.i64);
                try self.popExpect(.i64);
                try self.popExpect(address_type);
                self.push(.i64);
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
                .try_table => {
                    const immediate = instr.imm.try_table;
                    for (immediate.catches) |catch_clause| try self.validateCatch(catch_clause);
                    try self.pushFrame(
                        .try_table,
                        immediate.block.type.funcType(self.mod) orelse return self.fail("unknown type"),
                    );
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
                    self.resetLocals(f.init_height);
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
                .br_on_null => try self.validateBrOnNull(instr.imm.idx),
                .br_on_non_null => try self.validateBrOnNonNull(instr.imm.idx),
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
                .throw => {
                    const tag_index = instr.imm.idx;
                    const tag_type = try self.catchTagType(tag_index);
                    try self.popTypes(tag_type.params);
                    self.setUnreachable();
                },
                .throw_ref => {
                    try self.popExpect(.exnref);
                    self.setUnreachable();
                },
                .call => {
                    const idx = instr.imm.idx;
                    if (idx >= self.mod.totalFuncs())
                        return self.fail("unknown function");
                    try self.callFunc(self.mod.funcType(idx));
                },
                .return_call => {
                    const idx = instr.imm.idx;
                    if (idx >= self.mod.totalFuncs())
                        return self.fail("unknown function");
                    try self.tailCallFunc(self.mod.funcType(idx));
                },
                .call_indirect => {
                    const tidx = instr.imm.call_indirect.type_index;
                    const tableidx = instr.imm.call_indirect.table_index;
                    if (tidx >= self.mod.types.len) return self.fail("unknown type");
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    const table_reference = self.mod.tableType(tableidx).elem.refType() orelse
                        return self.fail("type mismatch");
                    if (!heapTypeMatches(self.mod, table_reference.heap, .func)) return self.fail("type mismatch");
                    try self.popExpect(self.mod.tableType(tableidx).address.valType());
                    try self.callFunc(self.mod.funcTypeAt(tidx) orelse return self.fail("type mismatch"));
                },
                .return_call_indirect => {
                    const tidx = instr.imm.call_indirect.type_index;
                    const tableidx = instr.imm.call_indirect.table_index;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    const table_reference = self.mod.tableType(tableidx).elem.refType() orelse
                        return self.fail("type mismatch");
                    if (!heapTypeMatches(self.mod, table_reference.heap, .func)) return self.fail("type mismatch");
                    if (tidx >= self.mod.types.len) return self.fail("unknown type");
                    try self.popExpect(self.mod.tableType(tableidx).address.valType());
                    try self.tailCallFunc(self.mod.funcTypeAt(tidx) orelse return self.fail("type mismatch"));
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
                    if (selected != .unknown) {
                        const selected_type: types.ValType = @enumFromInt(@intFromEnum(selected));
                        if (selected_type.isReference()) return self.fail("type mismatch");
                    }
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
                    if (!self.locals_init[instr.imm.idx]) return self.fail("uninitialized local");
                    self.push(stackVal(t));
                },
                .local_set => {
                    const t = self.localType(instr.imm.idx) orelse
                        return self.fail("unknown local");
                    try self.popExpect(t);
                    self.setLocalInitialized(instr.imm.idx);
                },
                .local_tee => {
                    const t = self.localType(instr.imm.idx) orelse
                        return self.fail("unknown local");
                    try self.popExpect(t);
                    self.setLocalInitialized(instr.imm.idx);
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
                    try self.popExpect(self.mod.tableType(tableidx).address.valType());
                    self.push(stackVal(self.mod.tableType(tableidx).elem));
                },
                .table_set => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    try self.popExpect(self.mod.tableType(tableidx).elem);
                    try self.popExpect(self.mod.tableType(tableidx).address.valType());
                },
                .ref_null => self.push(stackVal(instr.imm.type)),
                .ref_is_null => {
                    const ref = try self.pop();
                    if (ref != .unknown) {
                        const ref_type: types.ValType = @enumFromInt(@intFromEnum(ref));
                        if (!ref_type.isReference()) return self.fail("type mismatch");
                    }
                    self.push(.i32);
                },
                .ref_func => {
                    if (instr.imm.idx >= self.mod.totalFuncs()) return self.fail("unknown function");
                    if (!isDeclaredFunction(self.mod, instr.imm.idx)) return self.fail("undeclared function reference");
                    const result_type = if (self.mod.features.typed_function_references)
                        types.ValType.fromRef(.{
                            .nullable = false,
                            .heap = .concrete(self.mod.funcTypeIndex(instr.imm.idx)),
                        })
                    else
                        types.ValType.funcref;
                    self.push(stackVal(result_type));
                },
                .table_grow => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    const address_type = self.mod.tableType(tableidx).address.valType();
                    try self.popExpect(address_type);
                    try self.popExpect(self.mod.tableType(tableidx).elem);
                    self.push(stackVal(address_type));
                },
                .table_size => {
                    if (instr.imm.idx >= self.mod.totalTables())
                        return if (instr.imm.idx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    self.push(stackVal(self.mod.tableType(instr.imm.idx).address.valType()));
                },
                .table_fill => {
                    const tableidx = instr.imm.idx;
                    if (tableidx >= self.mod.totalTables())
                        return if (tableidx == 0) self.fail("unknown table 0") else self.fail("unknown table");
                    const address_type = self.mod.tableType(tableidx).address.valType();
                    try self.popExpect(address_type);
                    try self.popExpect(self.mod.tableType(tableidx).elem);
                    try self.popExpect(address_type);
                },
                .memory_init => {
                    const immediate = instr.imm.indices;
                    if (self.mod.data_count == null) return self.fail("data count section required");
                    if (immediate.first >= self.mod.datas.len) return self.fail("unknown data segment");
                    if (immediate.second >= self.mod.totalMems()) return self.fail("unknown memory");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(self.mod.memoryType(immediate.second).address.valType());
                },
                .data_drop => {
                    if (self.mod.data_count == null) return self.fail("data count section required");
                    if (instr.imm.idx >= self.mod.datas.len) return self.fail("unknown data segment");
                },
                .memory_copy => {
                    const immediate = instr.imm.indices;
                    if (immediate.first >= self.mod.totalMems() or immediate.second >= self.mod.totalMems())
                        return self.fail("unknown memory");
                    const destination = self.mod.memoryType(immediate.first).address;
                    const source = self.mod.memoryType(immediate.second).address;
                    try self.popExpect(types.AddressType.min(destination, source).valType());
                    try self.popExpect(source.valType());
                    try self.popExpect(destination.valType());
                },
                .memory_fill => {
                    if (instr.imm.idx >= self.mod.totalMems()) return self.fail("unknown memory");
                    const address_type = self.mod.memoryType(instr.imm.idx).address.valType();
                    try self.popExpect(address_type);
                    try self.popExpect(.i32);
                    try self.popExpect(address_type);
                },
                .table_init => {
                    const immediate = instr.imm.indices;
                    if (immediate.first >= self.mod.elems.len) return self.fail("unknown element segment");
                    if (immediate.second >= self.mod.totalTables()) return self.fail("unknown table");
                    if (!valTypeMatches(self.mod, self.mod.elems[immediate.first].type, self.mod.tableType(immediate.second).elem))
                        return self.fail("type mismatch");
                    try self.popExpect(.i32);
                    try self.popExpect(.i32);
                    try self.popExpect(self.mod.tableType(immediate.second).address.valType());
                },
                .elem_drop => {
                    if (instr.imm.idx >= self.mod.elems.len) return self.fail("unknown element segment");
                },
                .table_copy => {
                    const immediate = instr.imm.indices;
                    if (immediate.first >= self.mod.totalTables() or immediate.second >= self.mod.totalTables())
                        return self.fail("unknown table");
                    if (!valTypeMatches(self.mod, self.mod.tableType(immediate.second).elem, self.mod.tableType(immediate.first).elem))
                        return self.fail("type mismatch");
                    const destination = self.mod.tableType(immediate.first).address;
                    const source = self.mod.tableType(immediate.second).address;
                    try self.popExpect(types.AddressType.min(destination, source).valType());
                    try self.popExpect(source.valType());
                    try self.popExpect(destination.valType());
                },
                .i32_load, .i64_load, .f32_load, .f64_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => {
                    const info = memInfo(instr.op);
                    const address_type = try self.memAccess(instr.imm.memarg, info.log2_bytes);
                    try self.popExpect(address_type);
                    self.push(stackVal(info.t));
                },
                .i32_store, .i64_store, .f32_store, .f64_store, .i32_store8, .i32_store16, .i64_store8, .i64_store16, .i64_store32 => {
                    const info = memInfo(instr.op);
                    const address_type = try self.memAccess(instr.imm.memarg, info.log2_bytes);
                    try self.popExpect(info.t);
                    try self.popExpect(address_type);
                },
                .memory_size => {
                    const address_type = try self.memAddressType(0);
                    self.push(stackVal(address_type));
                },
                .memory_grow => {
                    const address_type = try self.memAddressType(0);
                    try self.popExpect(address_type);
                    self.push(stackVal(address_type));
                },
                .i32_const => self.push(.i32),
                .i64_const => self.push(.i64),
                .f32_const => self.push(.f32),
                .f64_const => self.push(.f64),
                .gc => try self.validateGc(instr),
                .ref_eq => try self.validateRefEq(),
                .ref_as_non_null => try self.validateRefAsNonNull(),
                .simd => try self.validateSimd(instr),
                .atomic => try self.validateAtomic(instr),
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
    allocator: Allocator,
) (Error || Allocator.Error)!void {
    // Both stacks are bounded by the instruction count: each instruction
    // pushes at most one operand and opens at most one control frame. The
    const n = body.instrs.len + 1;
    var max_arity: usize = 1;
    for (mod.types) |definition| {
        if (definition.funcType()) |signature|
            max_arity = @max(max_arity, signature.params.len, signature.results.len);
    }
    const operand_slots = std.math.mul(usize, n, max_arity) catch return error.OutOfMemory;
    const opds = try allocator.alloc(StackVal, operand_slots);
    defer allocator.free(opds);
    const frames = try allocator.alloc(Frame, n);
    defer allocator.free(frames);
    const local_count = ft.params.len + body.locals.len;
    const locals_init = try allocator.alloc(bool, local_count);
    defer allocator.free(locals_init);
    const init_stack = try allocator.alloc(u32, local_count);
    defer allocator.free(init_stack);
    for (locals_init, 0..) |*initialized, index| {
        initialized.* = index < ft.params.len or valTypeDefaultable(body.locals[index - ft.params.len]);
    }

    var v: FuncValidator = .{
        .mod = mod,
        .diag = diag,
        .params = ft.params,
        .locals = body.locals,
        .locals_init = locals_init,
        .init_stack = init_stack,
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

test "wasm.validate threads shared limits and atomic signatures" {
    const features: types.Features = .{ .threads = true };
    const shared_without_max = hdr ++ "\x05\x03\x01\x02\x01";
    try expectInvalidWithFeatures(shared_without_max, features, "shared memory must have maximum");

    const atomic_load = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7F\x01\x7F") ++ func0 ++
        sec(5, "\x01\x03\x01\x01") ++
        code1("\x20\x00\xFE\x10\x02\x00\x0B"));
    try expectValidWithFeatures(atomic_load, features);

    const bad_alignment = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7F\x01\x7F") ++ func0 ++
        sec(5, "\x01\x03\x01\x01") ++
        code1("\x20\x00\xFE\x10\x01\x00\x0B"));
    try expectInvalidAtWithFeatures(bad_alignment, features, 0, 1, "atomic alignment must be natural");

    const fence_without_memory = comptime (hdr ++ type_void ++ func0 ++ code1("\xFE\x03\x00\x0B"));
    try expectValidWithFeatures(fence_without_memory, features);

    // Notify and wait validate against an ordinary memory; wait traps at runtime
    // when that memory is not shared, as the threads specification requires.
    const wait_unshared = comptime (hdr ++
        sec(1, "\x01\x60\x03\x7F\x7F\x7E\x01\x7F") ++ func0 ++ mem1 ++
        code1("\x20\x00\x20\x01\x20\x02\xFE\x01\x02\x00\x0B"));
    try expectValidWithFeatures(wait_unshared, features);
}

test "wasm.validate memory64 memory instructions and offsets" {
    const features: types.Features = .{ .memory64 = true };
    const memory64 = comptime sec(5, "\x01\x04\x01");
    const offset_4g = "\x80\x80\x80\x80\x10";

    const load = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7E\x01\x7F") ++ func0 ++ memory64 ++
        code1("\x20\x00\x28\x02" ++ offset_4g ++ "\x0B"));
    try expectValidWithFeatures(load, features);

    const wrong_load_address = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7F\x01\x7F") ++ func0 ++ memory64 ++
        code1("\x20\x00\x28\x02\x00\x0B"));
    try expectInvalidAtWithFeatures(wrong_load_address, features, 0, 1, "type mismatch");

    const memory32_wide_offset = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7F\x01\x7F") ++ func0 ++ mem1 ++
        code1("\x20\x00\x28\x02" ++ offset_4g ++ "\x0B"));
    try expectInvalidAt(memory32_wide_offset, 0, 1, "memory offset exceeds address type");

    const size = comptime (hdr ++
        sec(1, "\x01\x60\x00\x01\x7E") ++ func0 ++ memory64 ++ code1("\x3F\x00\x0B"));
    try expectValidWithFeatures(size, features);

    const grow = comptime (hdr ++
        sec(1, "\x01\x60\x01\x7E\x01\x7E") ++ func0 ++ memory64 ++
        code1("\x20\x00\x40\x00\x0B"));
    try expectValidWithFeatures(grow, features);
}

test "wasm.validate memory64 table instructions and active offsets" {
    const features: types.Features = .{ .memory64 = true };
    const table64 = comptime sec(4, "\x01\x70\x04\x01");
    const memory64 = comptime sec(5, "\x01\x04\x01");

    const table_size = comptime (hdr ++
        sec(1, "\x01\x60\x00\x01\x7E") ++ func0 ++ table64 ++ code1("\xFC\x10\x00\x0B"));
    try expectValidWithFeatures(table_size, .{ .memory64 = true, .reference_types = true });

    const indirect = comptime (hdr ++ type_void ++ func0 ++ table64 ++
        code1("\x42\x00\x11\x00\x00\x0B"));
    try expectValidWithFeatures(indirect, features);

    const wrong_indirect_address = comptime (hdr ++ type_void ++ func0 ++ table64 ++
        code1("\x41\x00\x11\x00\x00\x0B"));
    try expectInvalidAtWithFeatures(wrong_indirect_address, features, 0, 1, "type mismatch");

    const active_data = comptime (hdr ++ memory64 ++ sec(11, "\x01\x00\x42\x00\x0B\x00"));
    try expectValidWithFeatures(active_data, features);
    const wrong_data_offset = comptime (hdr ++ memory64 ++ sec(11, "\x01\x00\x41\x00\x0B\x00"));
    try expectInvalidWithFeatures(wrong_data_offset, features, "type mismatch");

    const active_element = comptime (hdr ++ table64 ++ sec(9, "\x01\x00\x42\x00\x0B\x00"));
    try expectValidWithFeatures(active_element, features);
    const wrong_element_offset = comptime (hdr ++ table64 ++ sec(9, "\x01\x00\x41\x00\x0B\x00"));
    try expectInvalidWithFeatures(wrong_element_offset, features, "type mismatch");
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

test "wasm.validate exception tag declarations imports and exports" {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const payload_type = comptime sec(1, "\x01\x60\x02\x7F\x7D\x00");
    const valid = comptime (hdr ++ payload_type ++
        sec(2, "\x01\x01m\x01t\x04\x00\x00") ++
        sec(13, "\x01\x00\x00") ++
        sec(7, "\x02\x01i\x04\x00\x01d\x04\x01"));
    try expectValidWithFeatures(valid, features);

    try expectInvalidWithFeatures(
        hdr ++ payload_type ++ sec(13, "\x01\x00\x01"),
        features,
        "unknown type",
    );
    const result_type = comptime sec(1, "\x01\x60\x00\x01\x7F");
    try expectInvalidWithFeatures(
        hdr ++ result_type ++ sec(13, "\x01\x00\x00"),
        features,
        "non-empty tag result type",
    );
    try expectInvalidWithFeatures(
        hdr ++ payload_type ++ sec(7, "\x01\x01t\x04\x00"),
        features,
        "unknown tag",
    );
}

test "wasm.validate modern exception instructions and catch branch types" {
    const features: types.Features = .{ .reference_types = true, .exception_handling = true };
    const type_and_function = comptime (sec(
        1,
        "\x02\x60\x01\x7F\x00\x60\x00\x01\x7F",
    ) ++ sec(3, "\x01\x01"));
    const tag = comptime sec(13, "\x01\x00\x00");
    const caught_payload = comptime (hdr ++ type_and_function ++ tag ++ code1(
        "\x1F\x40\x01\x00\x00\x00" ++ // catch tag 0 -> function label
            "\x41\x07\x08\x00\x0B" ++ // throw tag 0 with i32 payload
            "\x41\x09\x0B", // ordinary path result
    ));
    try expectValidWithFeatures(caught_payload, features);

    const catch_ref_features: types.Features = .{
        .multi_value = true,
        .reference_types = true,
        .exception_handling = true,
    };
    const caught_payload_ref = comptime (hdr ++
        sec(1, "\x02\x60\x01\x7F\x00\x60\x00\x02\x7F\x69") ++
        sec(3, "\x01\x01") ++ tag ++ code1(
        "\x1F\x40\x01\x01\x00\x00" ++ // catch_ref tag 0 -> function label
            "\x41\x07\x08\x00\x0B" ++
            "\x41\x09\xD0\x69\x0B",
    ));
    try expectValidWithFeatures(caught_payload_ref, catch_ref_features);

    const catch_all = comptime (hdr ++ type_void ++ func0 ++
        sec(13, "\x01\x00\x00") ++ code1(
        "\x1F\x40\x01\x02\x00\x08\x00\x0B\x0B",
    ));
    try expectValidWithFeatures(catch_all, features);

    const catch_all_ref = comptime (hdr ++
        sec(1, "\x02\x60\x00\x00\x60\x00\x01\x69") ++
        sec(3, "\x01\x01") ++ sec(13, "\x01\x00\x00") ++ code1(
        "\x1F\x40\x01\x03\x00\x08\x00\x0B\xD0\x69\x0B",
    ));
    try expectValidWithFeatures(catch_all_ref, features);

    const inline_exnref_block = comptime (hdr ++
        sec(1, "\x01\x60\x00\x01\x69") ++ func0 ++
        code1("\x1F\x69\x00\xD0\x69\x0B\x0B"));
    try expectValidWithFeatures(inline_exnref_block, features);

    const throw_ref = comptime (hdr ++
        sec(1, "\x01\x60\x01\x69\x00") ++ func0 ++
        code1("\x20\x00\x0A\x0B"));
    try expectValidWithFeatures(throw_ref, features);

    const unknown_tag = comptime (hdr ++ type_and_function ++ tag ++ code1(
        "\x1F\x40\x01\x00\x01\x00\x41\x00\x0B\x41\x00\x0B",
    ));
    try expectInvalidAtWithFeatures(unknown_tag, features, 0, 0, "unknown tag");

    const unknown_label = comptime (hdr ++ type_and_function ++ tag ++ code1(
        "\x1F\x40\x01\x00\x00\x01\x41\x00\x0B\x41\x00\x0B",
    ));
    try expectInvalidAtWithFeatures(unknown_label, features, 0, 0, "unknown label");

    const bad_catch_ref_type = comptime (hdr ++ type_and_function ++ tag ++ code1(
        "\x1F\x40\x01\x01\x00\x00\x41\x00\x0B\x41\x00\x0B",
    ));
    try expectInvalidAtWithFeatures(bad_catch_ref_type, features, 0, 0, "type mismatch");

    const bad_throw_payload = comptime (hdr ++
        sec(1, "\x02\x60\x01\x7F\x00\x60\x00\x00") ++ sec(3, "\x01\x01") ++
        sec(13, "\x01\x00\x00") ++ code1("\x08\x00\x0B"));
    try expectInvalidAtWithFeatures(bad_throw_payload, features, 0, 0, "type mismatch");

    const bad_throw_ref = comptime (hdr ++ type_void ++ func0 ++
        code1("\x41\x00\x0A\x0B"));
    try expectInvalidAtWithFeatures(bad_throw_ref, features, 0, 1, "type mismatch");

    const polymorphic_throw = comptime (hdr ++
        sec(1, "\x02\x60\x01\x7F\x00\x60\x00\x00") ++ sec(3, "\x01\x01") ++
        sec(13, "\x01\x00\x00") ++ code1("\x00\x08\x00\x0B"));
    try expectValidWithFeatures(polymorphic_throw, features);
}

test "wasm.validate tail calls accept direct indirect and polymorphic stacks" {
    const features: types.Features = .{ .tail_calls = true };
    const direct = comptime (hdr ++ type_i32 ++ sec(3, "\x02\x00\x00") ++ sec(
        10,
        "\x02" ++ codeBody("\x00", "\x41\x07\x0B") ++ codeBody("\x00", "\x12\x00\x0B"),
    ));
    try expectValidWithFeatures(direct, features);

    const indirect = comptime (hdr ++ type_i32 ++ func0 ++ table1 ++
        code1("\x41\x00\x13\x00\x00\x0B"));
    try expectValidWithFeatures(indirect, features);

    const param_and_result_types = comptime sec(
        1,
        "\x02\x60\x01\x7E\x01\x7F\x60\x00\x01\x7F",
    ); // (i64) -> i32, () -> i32
    const unreachable_direct = comptime (hdr ++ param_and_result_types ++
        sec(3, "\x02\x00\x01") ++ sec(
        10,
        "\x02" ++ codeBody("\x00", "\x41\x00\x0B") ++ codeBody("\x00", "\x00\x12\x00\x0B"),
    ));
    try expectValidWithFeatures(unreachable_direct, features);

    const indirect_params = comptime (hdr ++ param_and_result_types ++
        sec(3, "\x01\x01") ++ table1 ++
        code1("\x42\x00\x41\x00\x13\x00\x00\x0B"));
    try expectValidWithFeatures(indirect_params, features);

    // Values below the callee operands are discarded by the polymorphic tail.
    const extra_stack = comptime (hdr ++ type_i32 ++ sec(3, "\x02\x00\x00") ++ sec(
        10,
        "\x02" ++ codeBody("\x00", "\x41\x00\x0B") ++ codeBody("\x00", "\x42\x00\x12\x00\x0B"),
    ));
    try expectValidWithFeatures(extra_stack, features);
}

test "wasm.validate tail calls enforce results operands tables and indices" {
    const features: types.Features = .{ .tail_calls = true };
    const mismatched_results = comptime (hdr ++
        sec(1, "\x02\x60\x00\x01\x7E\x60\x00\x01\x7F") ++
        sec(3, "\x02\x00\x01") ++ sec(
        10,
        "\x02" ++ codeBody("\x00", "\x42\x00\x0B") ++ codeBody("\x00", "\x12\x00\x0B"),
    ));
    try expectInvalidAtWithFeatures(mismatched_results, features, 1, 0, "type mismatch");
    const mismatched_indirect_results = comptime (hdr ++
        sec(1, "\x02\x60\x00\x01\x7E\x60\x00\x01\x7F") ++
        sec(3, "\x01\x01") ++ table1 ++
        code1("\x41\x00\x13\x00\x00\x0B"));
    try expectInvalidAtWithFeatures(mismatched_indirect_results, features, 0, 1, "type mismatch");

    const param_and_result_types = comptime sec(
        1,
        "\x02\x60\x01\x7E\x01\x7F\x60\x00\x01\x7F",
    );
    const missing_param = comptime (hdr ++ param_and_result_types ++
        sec(3, "\x02\x00\x01") ++ sec(
        10,
        "\x02" ++ codeBody("\x00", "\x41\x00\x0B") ++ codeBody("\x00", "\x12\x00\x0B"),
    ));
    try expectInvalidAtWithFeatures(missing_param, features, 1, 0, "type mismatch");
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ code1("\x12\x01\x0B"),
        features,
        0,
        0,
        "unknown function",
    );

    const bad_indirect_operand = comptime (hdr ++ param_and_result_types ++
        sec(3, "\x01\x01") ++ table1 ++
        code1("\x44\x00\x00\x00\x00\x00\x00\x00\x00\x41\x00\x13\x00\x00\x0B"));
    try expectInvalidAtWithFeatures(bad_indirect_operand, features, 0, 2, "type mismatch");
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ code1("\x41\x00\x13\x00\x00\x0B"),
        features,
        0,
        1,
        "unknown table 0",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ table1 ++ code1("\x41\x00\x13\x01\x00\x0B"),
        features,
        0,
        1,
        "unknown type",
    );
    try expectInvalidAtWithFeatures(
        hdr ++ type_void ++ func0 ++ table1 ++ code1("\x41\x00\x13\x00\x01\x0B"),
        features,
        0,
        1,
        "unknown table",
    );

    const externref_table = comptime (hdr ++ type_void ++ func0 ++
        sec(4, "\x01\x6F\x00\x01") ++ code1("\x41\x00\x13\x00\x00\x0B"));
    try expectInvalidAtWithFeatures(
        externref_table,
        .{ .tail_calls = true, .reference_types = true },
        0,
        1,
        "type mismatch",
    );
}

test "wasm.validate unknown function call" {
    try expectInvalidAt(hdr ++ type_void ++ func0 ++ code1("\x10\x03\x0B"), 0, 0, "unknown function");
}

const gc_validation_features: types.Features = .{
    .reference_types = true,
    .typed_function_references = true,
    .gc = true,
};

const gc_validation_allocation_bytes = hdr ++
    sec(1, "\x02\x5E\x7F\x01\x60\x00\x00") ++
    sec(3, "\x01\x01") ++
    code1("\x41\x01\xFB\x07\x00\xFB\x0F\x1A\x0B");

fn validateGcWithFailingAllocator(allocator: Allocator) !void {
    var diag: types.Diagnostic = .{};
    const mod = try decode.decodeWithFeatures(
        std.testing.allocator,
        gc_validation_allocation_bytes,
        gc_validation_features,
        &diag,
    );
    defer decode.destroyModule(std.testing.allocator, mod);
    try validateWithAllocator(mod, &diag, allocator);
}

test "wasm.validate GC allocation failures are rollback safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        validateGcWithFailingAllocator,
        .{},
    );
}

test "wasm.validate GC subtype chains are iterative and bounded" {
    const depth = 512;
    var definitions: [depth]types.DefType = undefined;
    var supertype_storage: [depth - 1][1]u32 = undefined;
    var groups: [depth]types.RecGroup = undefined;
    for (&definitions, 0..) |*definition, index| {
        const supertypes: []const u32 = if (index == 0)
            &.{}
        else blk: {
            supertype_storage[index - 1][0] = @intCast(index - 1);
            break :blk &supertype_storage[index - 1];
        };
        definition.* = .{
            .rec_group = @intCast(index),
            .rec_index = 0,
            .subtype = .{
                .final = false,
                .supertypes = supertypes,
                .composite = .{ .struct_ = .{ .fields = &.{} } },
            },
        };
        groups[index] = .{ .start = @intCast(index), .len = 1 };
    }
    var mod: types.Module = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .features = gc_validation_features,
        .types = &definitions,
        .rec_groups = &groups,
    };
    defer mod.deinit();
    var diag: types.Diagnostic = .{};
    try validateDefinedTypes(&mod, &diag);
    try std.testing.expect(heapTypeMatches(&mod, types.HeapType.concrete(depth - 1), types.HeapType.concrete(0)));
}

test "wasm.validate GC aggregate scalar cast and conversion signatures" {
    const type_section = comptime sec(1, "\x03" ++
        // type 0: (struct (field i32 const) (field i8 var))
        "\x5F\x02\x7F\x00\x78\x01" ++
        // type 1: (array (field i32 var))
        "\x5E\x7F\x01" ++
        // type 2: () -> ()
        "\x60\x00\x00");
    const function_section = comptime sec(3, "\x01\x02");
    const body =
        // struct.new, struct.new_default, packed struct.get_s, struct.set
        "\x41\x00\x41\x01\xFB\x00\x00\x1A" ++
        "\xFB\x01\x00\x1A" ++
        "\x41\x00\x41\x01\xFB\x00\x00\xFB\x03\x00\x01\x1A" ++
        "\x41\x00\x41\x01\xFB\x00\x00\x41\x02\xFB\x05\x00\x01" ++
        // array.new/default/fixed, array.get/set/len/fill
        "\x41\x07\x41\x03\xFB\x06\x01\x1A" ++
        "\x41\x03\xFB\x07\x01\x1A" ++
        "\x41\x01\x41\x02\xFB\x08\x01\x02\x1A" ++
        "\x41\x01\xFB\x07\x01\x41\x00\xFB\x0B\x01\x1A" ++
        "\x41\x01\xFB\x07\x01\x41\x00\x41\x09\xFB\x0E\x01" ++
        "\x41\x01\xFB\x07\x01\xFB\x0F\x1A" ++
        "\x41\x03\xFB\x07\x01\x41\x00\x41\x09\x41\x02\xFB\x10\x01" ++
        // i31, equality, non-null assertion, tests/casts, extern conversions
        "\x41\x7F\xFB\x1C\xFB\x1D\x1A" ++
        "\x41\x00\xFB\x1C\x41\x01\xFB\x1C\xD3\x1A" ++
        "\xD0\x6E\xD4\x1A" ++
        "\x41\x00\xFB\x1C\xFB\x14\x6C\x1A" ++
        "\x41\x00\xFB\x1C\xFB\x16\x6C\x1A" ++
        "\xD0\x6F\xFB\x1A\x1A" ++
        "\xD0\x6E\xFB\x1B\x1A\x0B";
    const bytes = comptime (hdr ++ type_section ++ function_section ++ code1(body));
    try expectValidWithFeatures(bytes, gc_validation_features);
}

test "wasm.validate GC array segment copy and initialization signatures" {
    const type_section = comptime sec(1, "\x03" ++
        "\x5E\x7F\x01" ++ // type 0: mutable i32 array
        "\x5E\x70\x01" ++ // type 1: mutable funcref array
        "\x60\x00\x00"); // type 2: () -> ()
    const function_section = comptime sec(3, "\x01\x02");
    const element_section = comptime sec(9, "\x01\x01\x00\x01\x00");
    const data_section = comptime sec(11, "\x01\x01\x01A");
    const body =
        // array.new_data and array.new_elem
        "\x41\x00\x41\x01\xFB\x09\x00\x00\x1A" ++
        "\x41\x00\x41\x01\xFB\x0A\x01\x00\x1A" ++
        // array.copy dst/dst-offset/src/src-offset/length
        "\x41\x01\xFB\x07\x00\x41\x00" ++
        "\x41\x01\xFB\x07\x00\x41\x00\x41\x01\xFB\x11\x00\x00" ++
        // array.init_data and array.init_elem
        "\x41\x01\xFB\x07\x00\x41\x00\x41\x00\x41\x01\xFB\x12\x00\x00" ++
        "\x41\x01\xFB\x07\x01\x41\x00\x41\x00\x41\x01\xFB\x13\x01\x00\x0B";
    const bytes = comptime (hdr ++ type_section ++ function_section ++ element_section ++
        code1(body) ++ data_section);
    var features = gc_validation_features;
    features.bulk_memory = true;
    try expectValidWithFeatures(bytes, features);

    const precise_ref_func = comptime (hdr ++
        sec(1, "\x03\x60\x00\x00\x5E\x64\x00\x00\x60\x00\x00") ++
        sec(3, "\x02\x00\x02") ++
        sec(7, "\x01\x01f\x00\x00") ++
        sec(10, "\x02" ++
            codeBody("\x00", "\x0B") ++
            codeBody("\x00", "\xD2\x00\x41\x01\xFB\x06\x01\x1A\x0B")));
    try expectValidWithFeatures(precise_ref_func, gc_validation_features);
}

test "wasm.validate GC nominal subtypes finality and field variance" {
    const valid = comptime (hdr ++ sec(1, "\x02" ++
        "\x50\x00\x5F\x01\x7F\x00" ++
        "\x50\x01\x00\x5F\x02\x7F\x00\x7F\x00"));
    try expectValidWithFeatures(valid, gc_validation_features);

    const final_parent = comptime (hdr ++ sec(1, "\x02" ++
        "\x4F\x00\x5F\x00" ++
        "\x50\x01\x00\x5F\x00"));
    try expectInvalidWithFeatures(final_parent, gc_validation_features, "cannot subtype final type");

    const future_parent = comptime (hdr ++ sec(1, "\x01\x50\x01\x00\x5F\x00"));
    try expectInvalidWithFeatures(future_parent, gc_validation_features, "invalid supertype index");

    const mutable_mismatch = comptime (hdr ++ sec(1, "\x02" ++
        "\x50\x00\x5F\x01\x7F\x01" ++
        "\x50\x01\x00\x5F\x01\x7E\x01"));
    try expectInvalidWithFeatures(mutable_mismatch, gc_validation_features, "type mismatch");
}

test "wasm.validate GC canonical recursive type identity" {
    const equivalent_types = comptime sec(1, "\x03" ++
        // Separate singleton recursive groups with the same closed shape.
        "\x5F\x01\x63\x00\x00" ++
        "\x5F\x01\x63\x01\x00" ++
        "\x60\x00\x00");
    const function_section = comptime sec(3, "\x01\x02");
    const equivalent_cast = comptime (hdr ++ equivalent_types ++ function_section ++
        code1("\xD0\x00\xFB\x00\x00\xFB\x16\x01\x1A\x0B"));
    try expectValidWithFeatures(equivalent_cast, gc_validation_features);

    const distinct_types = comptime sec(1, "\x03" ++
        "\x5F\x01\x63\x00\x00" ++
        "\x5F\x01\x7F\x00" ++
        "\x60\x00\x00");
    const distinct_cast = comptime (hdr ++ distinct_types ++ function_section ++
        code1("\xD0\x00\xFB\x00\x00\xFB\x16\x01\x1A\x0B"));
    try expectInvalidAtWithFeatures(distinct_cast, gc_validation_features, 0, 2, "type mismatch");

    const illegal_forward_reference = comptime (hdr ++ sec(1, "\x02" ++
        "\x5F\x01\x63\x01\x00" ++
        "\x5F\x00"));
    try expectInvalidWithFeatures(illegal_forward_reference, gc_validation_features, "unknown type");

    const legal_group_reference = comptime (hdr ++ sec(1, "\x01\x4E\x02" ++
        "\x5F\x01\x63\x01\x00" ++
        "\x5F\x00"));
    try expectValidWithFeatures(legal_group_reference, gc_validation_features);
}

test "wasm.validate GC canonical identity crosses module-local indices" {
    const a_bytes = comptime (hdr ++ sec(1, "\x01\x5F\x01\x63\x00\x00"));
    const b_bytes = comptime (hdr ++ sec(1, "\x02\x60\x00\x00\x5F\x01\x63\x01\x00"));
    const distinct_bytes = comptime (hdr ++ sec(1, "\x02\x60\x00\x00\x5F\x01\x7F\x00"));
    var diag: types.Diagnostic = .{};
    const a = try decode.decodeWithFeatures(std.testing.allocator, a_bytes, gc_validation_features, &diag);
    defer decode.destroyModule(std.testing.allocator, a);
    const b = try decode.decodeWithFeatures(std.testing.allocator, b_bytes, gc_validation_features, &diag);
    defer decode.destroyModule(std.testing.allocator, b);
    const distinct = try decode.decodeWithFeatures(std.testing.allocator, distinct_bytes, gc_validation_features, &diag);
    defer decode.destroyModule(std.testing.allocator, distinct);

    try std.testing.expect(definedTypesEquivalentAcross(a, 0, b, 1));
    try std.testing.expect(definedTypesEquivalentAcross(b, 1, a, 0));
    try std.testing.expect(!definedTypesEquivalentAcross(a, 0, distinct, 1));
}

test "wasm.validate GC packed access mutability and defaultability" {
    const struct_types = comptime sec(1, "\x02\x5F\x01\x7F\x00\x60\x00\x00");
    const struct_function = comptime sec(3, "\x01\x01");
    const packed_get = comptime (hdr ++ struct_types ++ struct_function ++
        code1("\x41\x00\xFB\x00\x00\xFB\x03\x00\x00\x1A\x0B"));
    try expectInvalidAtWithFeatures(packed_get, gc_validation_features, 0, 2, "type mismatch");

    const immutable_set = comptime (hdr ++ struct_types ++ struct_function ++
        code1("\x41\x00\xFB\x00\x00\x41\x01\xFB\x05\x00\x00\x0B"));
    try expectInvalidAtWithFeatures(immutable_set, gc_validation_features, 0, 3, "field is immutable");

    const array_types = comptime sec(1, "\x02\x5E\x64\x00\x01\x60\x00\x00");
    const array_function = comptime sec(3, "\x01\x01");
    const nondefaultable = comptime (hdr ++ array_types ++ array_function ++
        code1("\x41\x00\xFB\x07\x00\x1A\x0B"));
    try expectInvalidAtWithFeatures(nondefaultable, gc_validation_features, 0, 1, "type is not defaultable");

    const local_decl = "\x01\x01\x64\x00";
    const initialized_local = comptime (hdr ++ array_types ++ array_function ++
        sec(10, "\x01" ++ codeBody(local_decl, "\xFB\x08\x00\x00\x21\x00\x20\x00\x1A\x0B")));
    try expectValidWithFeatures(initialized_local, gc_validation_features);

    const unset_local = comptime (hdr ++ array_types ++ array_function ++
        sec(10, "\x01" ++ codeBody(local_decl, "\x20\x00\x1A\x0B")));
    try expectInvalidAtWithFeatures(unset_local, gc_validation_features, 0, 0, "uninitialized local");

    const block_local = comptime (hdr ++ array_types ++ array_function ++
        sec(10, "\x01" ++ codeBody(local_decl, "\x02\x40\xFB\x08\x00\x00\x21\x00\x0B\x20\x00\x1A\x0B")));
    try expectInvalidAtWithFeatures(block_local, gc_validation_features, 0, 4, "uninitialized local");
}

test "wasm.validate GC cast branches refine fallthrough types" {
    const br_on_cast = comptime (hdr ++ type_void ++ func0 ++ code1("\x02\x6D" ++
        "\x41\x00\xFB\x1C" ++
        "\xFB\x18\x00\x00\x6C\x6C" ++
        "\x0B\x1A\x0B"));
    try expectValidWithFeatures(br_on_cast, gc_validation_features);

    const br_on_cast_fail = comptime (hdr ++ type_void ++ func0 ++ code1("\x02\x6E" ++
        "\xD0\x6C" ++
        "\xFB\x19\x01\x00\x6C\x6C" ++
        "\x0B\x1A\x0B"));
    try expectValidWithFeatures(br_on_cast_fail, gc_validation_features);

    const br_on_null = comptime (hdr ++ type_void ++ func0 ++
        code1("\x02\x40\xD0\x6E\xD5\x00\x1A\x0B\x0B"));
    try expectValidWithFeatures(br_on_null, gc_validation_features);

    const br_on_non_null = comptime (hdr ++ type_void ++ func0 ++
        code1("\x02\x64\x6E\xD0\x6E\xD6\x00\x41\x00\xFB\x1C\x0B\x1A\x0B"));
    try expectValidWithFeatures(br_on_non_null, gc_validation_features);

    const nullable_label = comptime (hdr ++ type_void ++ func0 ++
        code1("\x02\x63\x6E\xD0\x6E\xD6\x00\x41\x00\xFB\x1C\x0B\x1A\x0B"));
    try expectInvalidAtWithFeatures(nullable_label, gc_validation_features, 0, 2, "type mismatch");

    // A conditional branch join retypes its preserved prefix to the label
    // signature. The concrete struct reference therefore becomes `anyref`
    // and cannot be consumed by struct.get on the fallthrough path.
    const joined_prefix = comptime (hdr ++
        sec(1, "\x02\x5F\x01\x7F\x00\x60\x00\x02\x6E\x6E") ++
        sec(3, "\x01\x01") ++
        code1("\x41\x00\xFB\x00\x00\xD0\x6E\xFB\x18\x01\x00\x6E\x6C" ++
            "\x1A\xFB\x02\x00\x00\x1A\x00\x0B"));
    try expectInvalidAtWithFeatures(joined_prefix, .{
        .multi_value = true,
        .reference_types = true,
        .typed_function_references = true,
        .gc = true,
    }, 0, 5, "type mismatch");
}

test "wasm.validate GC ref tests accept operands below the target type" {
    const bytes = comptime (hdr ++
        sec(1, "\x03\x50\x00\x5F\x00\x50\x01\x00\x5F\x01\x7F\x00\x60\x00\x00") ++
        sec(3, "\x01\x02") ++
        code1("\xD0\x01\xFB\x15\x00\x1A\x0B"));
    try expectValidWithFeatures(bytes, gc_validation_features);
}
