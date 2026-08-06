//! Opt-in implementation of the standard GDB JIT registration protocol.
//!
//! LLDB implements the same protocol. On macOS its GDB JIT loader accepts an
//! in-memory Mach-O object whose `__text` section file address is the already
//! published executable PC, so this adapter describes the engine-owned mapping
//! without copying, linking, or remapping executable code.

const std = @import("std");
const builtin = @import("builtin");
const observability = @import("native_observability.zig");

const Action = enum(u32) {
    no_action = 0,
    register = 1,
    unregister = 2,
};

const CodeEntry = extern struct {
    next_entry: ?*CodeEntry,
    prev_entry: ?*CodeEntry,
    symfile_addr: [*]const u8,
    symfile_size: u64,
};

const Descriptor = extern struct {
    version: u32,
    action_flag: Action,
    relevant_entry: ?*CodeEntry,
    first_entry: ?*CodeEntry,
};

/// These two exact external names are the debugger ABI. They are emitted only
/// when an embedder references this module's `publisher`; the default zig-js
/// library does not claim a process-global descriptor that may belong to its
/// host.
pub export var __jit_debug_descriptor: Descriptor = .{
    .version = 1,
    .action_flag = .no_action,
    .relevant_entry = null,
    .first_entry = null,
};

pub export fn __jit_debug_register_code() callconv(.c) void {
    // Debuggers place an internal breakpoint on this symbol. The memory clobber
    // keeps descriptor/list stores before the breakpoint-visible call.
    asm volatile ("" ::: .{ .memory = true });
}

var protocol_lock: std.atomic.Mutex = .unlocked;

fn lockProtocol() void {
    while (!protocol_lock.tryLock()) std.atomic.spinLoopHint();
}

const Registration = struct {
    allocator: std.mem.Allocator,
    symfile: []u8,
    unwind: ?UnwindRegistration,
    entry: CodeEntry,
};

const UnwindRegistration = struct {
    bytes: []align(8) u8,
    fde_offset: usize,

    fn fde(self: UnwindRegistration) *const anyopaque {
        return @ptrCast(&self.bytes[self.fde_offset]);
    }
};

const DwarfEhBases = extern struct {
    tbase: usize,
    dbase: usize,
    func: usize,
};

extern "c" fn __register_frame(fde: *const anyopaque) void;
extern "c" fn __deregister_frame(fde: *const anyopaque) void;
extern "c" fn _Unwind_Find_FDE(pc: *const anyopaque, bases: *DwarfEhBases) ?*const anyopaque;

pub fn publisher() observability.Publisher {
    return .{
        .publish_fn = publish,
        .unpublish_fn = unpublish,
    };
}

fn supportsMachOObject() bool {
    return builtin.os.tag == .macos and switch (builtin.cpu.arch) {
        .aarch64, .x86_64 => true,
        else => false,
    };
}

fn publish(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
) observability.PublishError!?*anyopaque {
    if (!supportsMachOObject()) return null;
    if (artifact.code.len == 0 or artifact.pc_start != @intFromPtr(artifact.code.ptr))
        return error.NativeCodePublicationFailed;

    const registration = try allocator.create(Registration);
    errdefer allocator.destroy(registration);
    const symfile = try createMachOObject(allocator, artifact);
    errdefer allocator.free(symfile);
    const unwind = try createEhFrame(allocator, artifact);
    errdefer if (unwind) |info| allocator.free(info.bytes);
    if (unwind) |info| __register_frame(info.fde());
    errdefer if (unwind) |info| __deregister_frame(info.fde());
    registration.* = .{
        .allocator = allocator,
        .symfile = symfile,
        .unwind = unwind,
        .entry = .{
            .next_entry = null,
            .prev_entry = null,
            .symfile_addr = symfile.ptr,
            .symfile_size = symfile.len,
        },
    };

    lockProtocol();
    defer protocol_lock.unlock();
    const entry = &registration.entry;
    entry.next_entry = __jit_debug_descriptor.first_entry;
    if (entry.next_entry) |next| next.prev_entry = entry;
    __jit_debug_descriptor.first_entry = entry;
    __jit_debug_descriptor.relevant_entry = entry;
    __jit_debug_descriptor.action_flag = .register;
    @call(.never_inline, __jit_debug_register_code, .{});
    __jit_debug_descriptor.action_flag = .no_action;
    __jit_debug_descriptor.relevant_entry = null;
    return registration;
}

fn unpublish(_: ?*anyopaque, opaque_registration: *anyopaque) void {
    const registration: *Registration = @ptrCast(@alignCast(opaque_registration));
    lockProtocol();
    const entry = &registration.entry;
    if (entry.prev_entry) |previous| {
        previous.next_entry = entry.next_entry;
    } else {
        std.debug.assert(__jit_debug_descriptor.first_entry == entry);
        __jit_debug_descriptor.first_entry = entry.next_entry;
    }
    if (entry.next_entry) |next| next.prev_entry = entry.prev_entry;
    __jit_debug_descriptor.relevant_entry = entry;
    __jit_debug_descriptor.action_flag = .unregister;
    @call(.never_inline, __jit_debug_register_code, .{});
    __jit_debug_descriptor.action_flag = .no_action;
    __jit_debug_descriptor.relevant_entry = null;
    protocol_lock.unlock();

    const allocator = registration.allocator;
    if (registration.unwind) |unwind| {
        __deregister_frame(unwind.fde());
        allocator.free(unwind.bytes);
    }
    allocator.free(registration.symfile);
    allocator.destroy(registration);
}

fn reserveCfi(storage: []u8, cursor: usize, count: usize) observability.PublishError!void {
    if (cursor > storage.len or count > storage.len - cursor) return error.NativeUnwindInfoTooLarge;
}

fn writeCfiByte(storage: []u8, cursor: *usize, value: u8) observability.PublishError!void {
    try reserveCfi(storage, cursor.*, 1);
    storage[cursor.*] = value;
    cursor.* += 1;
}

fn writeCfiUleb(storage: []u8, cursor: *usize, input: u32) observability.PublishError!void {
    var value = input;
    while (true) {
        var byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        try writeCfiByte(storage, cursor, byte);
        if (value == 0) return;
    }
}

fn writeCfiAdvance(storage: []u8, cursor: *usize, delta: u32) observability.PublishError!void {
    if (delta <= 0x3f) {
        try writeCfiByte(storage, cursor, 0x40 | @as(u8, @intCast(delta)));
    } else if (delta <= std.math.maxInt(u8)) {
        try writeCfiByte(storage, cursor, 0x02); // DW_CFA_advance_loc1
        try writeCfiByte(storage, cursor, @intCast(delta));
    } else if (delta <= std.math.maxInt(u16)) {
        try writeCfiByte(storage, cursor, 0x03); // DW_CFA_advance_loc2
        try reserveCfi(storage, cursor.*, 2);
        std.mem.writeInt(u16, storage[cursor.*..][0..2], @intCast(delta), .little);
        cursor.* += 2;
    } else {
        try writeCfiByte(storage, cursor, 0x04); // DW_CFA_advance_loc4
        try reserveCfi(storage, cursor.*, 4);
        std.mem.writeInt(u32, storage[cursor.*..][0..4], delta, .little);
        cursor.* += 4;
    }
}

fn writeCfiOffset(storage: []u8, cursor: *usize, register: u8, factor: u8) observability.PublishError!void {
    if (register <= 0x3f) {
        try writeCfiByte(storage, cursor, 0x80 | register); // DW_CFA_offset
    } else {
        try writeCfiByte(storage, cursor, 0x05); // DW_CFA_offset_extended
        try writeCfiUleb(storage, cursor, register);
    }
    try writeCfiUleb(storage, cursor, factor);
}

fn writeCfiSameValue(storage: []u8, cursor: *usize, register: u8) observability.PublishError!void {
    try writeCfiByte(storage, cursor, 0x08); // DW_CFA_same_value
    try writeCfiUleb(storage, cursor, register);
}

fn addUnwindSize(a: usize, b: usize) observability.PublishError!usize {
    return std.math.add(usize, a, b) catch error.NativeUnwindInfoTooLarge;
}

fn alignUnwindSize(value: usize, alignment: usize) observability.PublishError!usize {
    const added = try addUnwindSize(value, alignment - 1);
    return added & ~(alignment - 1);
}

fn createEhFrame(
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
) observability.PublishError!?UnwindRegistration {
    if (artifact.unwind == .none) return null;
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64)
        return error.NativeCodePublicationFailed;

    // Darwin's dynamic-FDE API requires PC-relative function addressing. This
    // is the canonical clang CIE for AArch64: zR, code alignment 1, data
    // alignment -8, LR column 30, pcrel native-pointer FDE locations, and an
    // initial CFA of WSP+0.
    const cie = [_]u8{
        0x10, 0x00, 0x00, 0x00, // record length
        0x00, 0x00, 0x00, 0x00, // CIE id
        0x01, 'z', 'R', 0x00, // version and augmentation
        0x01, 0x78, 0x1e, // code alignment, -8 data alignment, LR
        0x01, 0x10, // augmentation length and DW_EH_PE_pcrel|absptr
        0x0c, 0x1f, 0x00, // DW_CFA_def_cfa WSP+0
    };
    var cfi_storage: [160]u8 = undefined;
    var cfi_len: usize = 0;
    switch (artifact.unwind) {
        .none => unreachable,
        .aarch64_leaf => {},
        .aarch64_frame_pointer => |frame| {
            const epilogue_offset: usize = frame.epilogue_offset;
            if (epilogue_offset < 8 or epilogue_offset > artifact.code.len or
                artifact.code.len - epilogue_offset != 8 or
                frame.saved_gpr_count > 10 or frame.saved_gpr_count % 2 != 0 or
                frame.saved_float_count > 8 or frame.saved_float_count % 2 != 0)
                return error.NativeCodePublicationFailed;
            const prologue = [_]u8{
                0x44, // advance 4: stp x29/x30 has completed
                0x0e, 0x10, // CFA offset 16
                0x9d, 0x02, // x29 at CFA-16
                0x9e, 0x01, // x30 at CFA-8
                0x44, // advance 4: mov x29,sp has completed
                0x0d, 0x1d, // CFA register x29
            };
            @memcpy(cfi_storage[0..prologue.len], &prologue);
            cfi_len = prologue.len;
            var current_pc: u32 = 8;
            var pair_index: u8 = 0;
            while (pair_index < frame.saved_gpr_count / 2) : (pair_index += 1) {
                try writeCfiAdvance(&cfi_storage, &cfi_len, 4);
                current_pc += 4;
                const first_register = 19 + pair_index * 2;
                try writeCfiOffset(&cfi_storage, &cfi_len, first_register, 4 + pair_index * 2);
                try writeCfiOffset(&cfi_storage, &cfi_len, first_register + 1, 3 + pair_index * 2);
            }
            pair_index = 0;
            while (pair_index < frame.saved_float_count / 2) : (pair_index += 1) {
                try writeCfiAdvance(&cfi_storage, &cfi_len, 4);
                current_pc += 4;
                const first_register = 72 + pair_index * 2; // DWARF d8 starts at 64 + 8
                try writeCfiOffset(
                    &cfi_storage,
                    &cfi_len,
                    first_register,
                    frame.saved_gpr_count + 4 + pair_index * 2,
                );
                try writeCfiOffset(
                    &cfi_storage,
                    &cfi_len,
                    first_register + 1,
                    frame.saved_gpr_count + 3 + pair_index * 2,
                );
            }
            const return_offset = std.math.add(usize, epilogue_offset, 4) catch
                return error.NativeUnwindInfoTooLarge;
            if (return_offset < current_pc) return error.NativeCodePublicationFailed;
            const advance = std.math.cast(u32, return_offset - current_pc) orelse
                return error.NativeUnwindInfoTooLarge;
            try writeCfiAdvance(&cfi_storage, &cfi_len, advance);
            try writeCfiByte(&cfi_storage, &cfi_len, 0x0c); // DW_CFA_def_cfa
            try writeCfiUleb(&cfi_storage, &cfi_len, 31); // WSP
            try writeCfiUleb(&cfi_storage, &cfi_len, 0);
            try writeCfiSameValue(&cfi_storage, &cfi_len, 29);
            try writeCfiSameValue(&cfi_storage, &cfi_len, 30);
            for (0..frame.saved_gpr_count) |index|
                try writeCfiSameValue(&cfi_storage, &cfi_len, @intCast(19 + index));
            for (0..frame.saved_float_count) |index|
                try writeCfiSameValue(&cfi_storage, &cfi_len, @intCast(72 + index));
        },
    }

    const fde_offset = cie.len;
    const fde_fixed_size = 4 + 4 + 8 + 8 + 1;
    const unaligned_size = try addUnwindSize(fde_offset, try addUnwindSize(fde_fixed_size, cfi_len));
    const total_size = try alignUnwindSize(unaligned_size, 8);
    const bytes = try allocator.alignedAlloc(u8, .@"8", total_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0); // trailing zero bytes are DW_CFA_nop padding
    @memcpy(bytes[0..cie.len], &cie);

    const fde_length = total_size - fde_offset - 4;
    std.mem.writeInt(u32, bytes[fde_offset..][0..4], try u32Offset(fde_length), .little);
    // In .eh_frame the CIE pointer is the positive distance from this field to
    // the beginning of the CIE.
    std.mem.writeInt(u32, bytes[fde_offset + 4 ..][0..4], try u32Offset(fde_offset + 4), .little);
    const initial_location_offset = fde_offset + 8;
    const initial_location_address = @intFromPtr(&bytes[initial_location_offset]);
    const pc_delta = @as(i128, @intCast(artifact.pc_start)) - @as(i128, @intCast(initial_location_address));
    const pc_relative = std.math.cast(i64, pc_delta) orelse return error.NativeUnwindInfoTooLarge;
    std.mem.writeInt(i64, bytes[initial_location_offset..][0..8], pc_relative, .little);
    std.mem.writeInt(u64, bytes[fde_offset + 16 ..][0..8], artifact.code.len, .little);
    bytes[fde_offset + 24] = 0; // z augmentation payload length
    @memcpy(bytes[fde_offset + 25 ..][0..cfi_len], cfi_storage[0..cfi_len]);
    return .{ .bytes = bytes, .fde_offset = fde_offset };
}

fn addSize(a: usize, b: usize) observability.PublishError!usize {
    return std.math.add(usize, a, b) catch error.NativeSymbolObjectTooLarge;
}

fn alignSize(value: usize, alignment: usize) observability.PublishError!usize {
    const added = try addSize(value, alignment - 1);
    return added & ~(alignment - 1);
}

fn u32Offset(value: usize) observability.PublishError!u32 {
    return std.math.cast(u32, value) orelse error.NativeSymbolObjectTooLarge;
}

fn machoName(comptime value: []const u8) [16]u8 {
    if (value.len > 16) @compileError("Mach-O name is longer than 16 bytes");
    var result: [16]u8 = @splat(0);
    @memcpy(result[0..value.len], value);
    return result;
}

fn writeStruct(bytes: []u8, offset: usize, value: anytype) void {
    const source = std.mem.asBytes(&value);
    @memcpy(bytes[offset..][0..source.len], source);
}

fn appendInt(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    comptime T: type,
    value: T,
) observability.PublishError!void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .little);
    try list.appendSlice(allocator, &encoded);
}

fn appendUleb(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    input: u64,
) observability.PublishError!void {
    var value = input;
    while (true) {
        var byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        try list.append(allocator, byte);
        if (value == 0) return;
    }
}

fn appendSleb(
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    input: i64,
) observability.PublishError!void {
    var value = input;
    while (true) {
        var byte: u8 = @intCast(@as(u64, @bitCast(value)) & 0x7f);
        const sign_bit = byte & 0x40;
        value >>= 7;
        const done = (value == 0 and sign_bit == 0) or (value == -1 and sign_bit != 0);
        if (!done) byte |= 0x80;
        try list.append(allocator, byte);
        if (done) return;
    }
}

fn appendLineSetAddress(
    program: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    address: usize,
) observability.PublishError!void {
    try program.append(allocator, std.dwarf.LNS.extended_op);
    try appendUleb(program, allocator, 1 + @sizeOf(u64));
    try program.append(allocator, std.dwarf.LNE.set_address);
    try appendInt(
        program,
        allocator,
        u64,
        std.math.cast(u64, address) orelse return error.NativeSymbolObjectTooLarge,
    );
}

fn appendLineEndSequence(
    program: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) observability.PublishError!void {
    try program.append(allocator, std.dwarf.LNS.extended_op);
    try appendUleb(program, allocator, 1);
    try program.append(allocator, std.dwarf.LNE.end_sequence);
}

const DwarfSections = struct {
    allocator: std.mem.Allocator,
    abbrev: []u8,
    info: []u8,
    line: []u8,

    fn deinit(self: *DwarfSections) void {
        self.allocator.free(self.abbrev);
        self.allocator.free(self.info);
        self.allocator.free(self.line);
        self.* = undefined;
    }
};

fn createDwarfSections(
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
) observability.PublishError!?DwarfSections {
    var has_source = false;
    var previous_offset: ?u32 = null;
    for (artifact.pc_locations) |entry| {
        if (entry.native_offset >= artifact.code.len or
            (previous_offset != null and entry.native_offset <= previous_offset.?))
            return error.NativeCodePublicationFailed;
        previous_offset = entry.native_offset;
        if (entry.source) |source| {
            if (source.line == 0 or source.column == 0) return error.NativeCodePublicationFailed;
            has_source = true;
        }
    }
    if (!has_source or artifact.source_url.len == 0) return null;
    if (std.mem.indexOfScalar(u8, artifact.source_url, 0) != null)
        return error.NativeCodePublicationFailed;

    const abbrev_template = [_]u8{
        1, // abbreviation code
        std.dwarf.TAG.compile_unit,
        std.dwarf.CHILDREN.no,
        std.dwarf.AT.name,
        std.dwarf.FORM.string,
        std.dwarf.AT.stmt_list,
        std.dwarf.FORM.sec_offset,
        std.dwarf.AT.low_pc,
        std.dwarf.FORM.addr,
        std.dwarf.AT.high_pc,
        std.dwarf.FORM.data8,
        0,
        0, // end attributes
        0, // end abbreviation table
    };
    const abbrev = try allocator.dupe(u8, &abbrev_template);
    errdefer allocator.free(abbrev);

    var info: std.ArrayListUnmanaged(u8) = .empty;
    errdefer info.deinit(allocator);
    var die_size = try addSize(1, artifact.source_url.len);
    die_size = try addSize(die_size, 1);
    die_size = try addSize(die_size, @sizeOf(u32));
    die_size = try addSize(die_size, @sizeOf(u64));
    die_size = try addSize(die_size, @sizeOf(u64));
    const info_unit_size = try addSize(2 + 4 + 1, die_size);
    try appendInt(&info, allocator, u32, try u32Offset(info_unit_size));
    try appendInt(&info, allocator, u16, 4); // DWARF v4
    try appendInt(&info, allocator, u32, 0); // abbreviation section offset
    try info.append(allocator, @intCast(@sizeOf(usize)));
    try appendUleb(&info, allocator, 1);
    try info.appendSlice(allocator, artifact.source_url);
    try info.append(allocator, 0);
    try appendInt(&info, allocator, u32, 0); // line table offset
    try appendInt(
        &info,
        allocator,
        u64,
        std.math.cast(u64, artifact.pc_start) orelse return error.NativeSymbolObjectTooLarge,
    );
    try appendInt(
        &info,
        allocator,
        u64,
        std.math.cast(u64, artifact.code.len) orelse return error.NativeSymbolObjectTooLarge,
    ); // high_pc is a size in DWARF v4

    var line_header: std.ArrayListUnmanaged(u8) = .empty;
    defer line_header.deinit(allocator);
    try line_header.appendSlice(allocator, &.{
        1, // minimum instruction length
        1, // maximum operations per instruction
        1, // default is_stmt
        @bitCast(@as(i8, -5)), // line base
        14, // line range
        13, // opcode base
        0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1, // standard opcode operand counts
        0, // end include directories
    });
    try line_header.appendSlice(allocator, artifact.source_url);
    try line_header.append(allocator, 0);
    try appendUleb(&line_header, allocator, 0); // directory index
    try appendUleb(&line_header, allocator, 0); // modification time
    try appendUleb(&line_header, allocator, 0); // file size
    try line_header.append(allocator, 0); // end file table

    var line_program: std.ArrayListUnmanaged(u8) = .empty;
    defer line_program.deinit(allocator);
    var sequence_active = false;
    var current_line: i64 = 1;
    var current_column: u64 = 0;
    for (artifact.pc_locations) |entry| {
        const address = try addSize(artifact.pc_start, entry.native_offset);
        if (entry.source) |source| {
            if (!sequence_active) {
                sequence_active = true;
                current_line = 1;
                current_column = 0;
            }
            try appendLineSetAddress(&line_program, allocator, address);
            const source_line = std.math.cast(i64, source.line) orelse
                return error.NativeSymbolObjectTooLarge;
            const line_delta = source_line - current_line;
            if (line_delta != 0) {
                try line_program.append(allocator, std.dwarf.LNS.advance_line);
                try appendSleb(&line_program, allocator, line_delta);
                current_line = source_line;
            }
            const source_column = std.math.cast(u64, source.column) orelse
                return error.NativeSymbolObjectTooLarge;
            if (source_column != current_column) {
                try line_program.append(allocator, std.dwarf.LNS.set_column);
                try appendUleb(&line_program, allocator, source_column);
                current_column = source_column;
            }
            try line_program.append(allocator, std.dwarf.LNS.copy);
        } else if (sequence_active) {
            try appendLineSetAddress(&line_program, allocator, address);
            try appendLineEndSequence(&line_program, allocator);
            sequence_active = false;
        }
    }
    if (sequence_active) {
        try appendLineSetAddress(
            &line_program,
            allocator,
            try addSize(artifact.pc_start, artifact.code.len),
        );
        try appendLineEndSequence(&line_program, allocator);
    }

    var line: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line.deinit(allocator);
    const line_unit_size = try addSize(
        2 + 4 + line_header.items.len,
        line_program.items.len,
    );
    try appendInt(&line, allocator, u32, try u32Offset(line_unit_size));
    try appendInt(&line, allocator, u16, 4); // DWARF v4
    try appendInt(&line, allocator, u32, try u32Offset(line_header.items.len));
    try line.appendSlice(allocator, line_header.items);
    try line.appendSlice(allocator, line_program.items);

    const owned_info = try info.toOwnedSlice(allocator);
    errdefer allocator.free(owned_info);
    const owned_line = try line.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .abbrev = abbrev,
        .info = owned_info,
        .line = owned_line,
    };
}

fn createMachOObject(
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
) observability.PublishError![]u8 {
    const macho = std.macho;
    var dwarf = try createDwarfSections(allocator, artifact);
    defer if (dwarf) |*sections| sections.deinit();
    const dwarf_section_count: usize = if (dwarf != null) 3 else 0;
    const text_segment_size = @sizeOf(macho.segment_command_64) + @sizeOf(macho.section_64);
    const dwarf_segment_size = if (dwarf != null)
        @sizeOf(macho.segment_command_64) + dwarf_section_count * @sizeOf(macho.section_64)
    else
        0;
    const commands_size = text_segment_size + dwarf_segment_size + @sizeOf(macho.symtab_command);
    const text_offset = try alignSize(@sizeOf(macho.mach_header_64) + commands_size, 16);
    const text_end = try addSize(text_offset, artifact.code.len);
    var contents_end = text_end;
    const abbrev_offset = contents_end;
    if (dwarf) |sections| contents_end = try addSize(contents_end, sections.abbrev.len);
    const info_offset = contents_end;
    if (dwarf) |sections| contents_end = try addSize(contents_end, sections.info.len);
    const line_offset = contents_end;
    if (dwarf) |sections| contents_end = try addSize(contents_end, sections.line.len);
    const symbol_offset = try alignSize(contents_end, @alignOf(macho.nlist_64));
    const string_offset = try addSize(symbol_offset, @sizeOf(macho.nlist_64));
    // Mach-O external C symbols carry one object-format underscore.
    const string_size = try addSize(3, artifact.symbol_name.len);
    const total_size = try addSize(string_offset, string_size);
    _ = try u32Offset(total_size);

    const bytes = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    const cpu = switch (builtin.cpu.arch) {
        .aarch64 => .{ macho.CPU_TYPE_ARM64, macho.CPU_SUBTYPE_ARM_ALL },
        .x86_64 => .{ macho.CPU_TYPE_X86_64, macho.CPU_SUBTYPE_X86_64_ALL },
        else => unreachable,
    };
    const header: macho.mach_header_64 = .{
        .cputype = cpu[0],
        .cpusubtype = cpu[1],
        .filetype = macho.MH_OBJECT,
        .ncmds = if (dwarf != null) 3 else 2,
        .sizeofcmds = @intCast(commands_size),
    };
    writeStruct(bytes, 0, header);

    const segment_offset = @sizeOf(macho.mach_header_64);
    const text_segment: macho.segment_command_64 = .{
        .cmdsize = @intCast(text_segment_size),
        .segname = machoName("__TEXT"),
        .vmaddr = artifact.pc_start,
        .vmsize = artifact.code.len,
        .fileoff = text_offset,
        .filesize = artifact.code.len,
        .maxprot = .{ .READ = true, .EXEC = true },
        .initprot = .{ .READ = true, .EXEC = true },
        .nsects = 1,
    };
    writeStruct(bytes, segment_offset, text_segment);

    const section_offset = segment_offset + @sizeOf(macho.segment_command_64);
    const section: macho.section_64 = .{
        .sectname = machoName("__text"),
        .segname = machoName("__TEXT"),
        .addr = artifact.pc_start,
        .size = artifact.code.len,
        .offset = try u32Offset(text_offset),
        .@"align" = switch (builtin.cpu.arch) {
            .aarch64 => 2,
            .x86_64 => 0,
            else => unreachable,
        },
        .flags = macho.S_REGULAR | macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
    };
    writeStruct(bytes, section_offset, section);

    if (dwarf) |sections| {
        const dwarf_segment_offset = segment_offset + text_segment_size;
        const dwarf_size = contents_end - text_end;
        const dwarf_segment: macho.segment_command_64 = .{
            .cmdsize = @intCast(dwarf_segment_size),
            .segname = machoName("__DWARF"),
            .vmaddr = 0,
            .vmsize = dwarf_size,
            .fileoff = abbrev_offset,
            .filesize = dwarf_size,
            .maxprot = .{ .READ = true },
            .initprot = .{ .READ = true },
            .nsects = @intCast(dwarf_section_count),
        };
        writeStruct(bytes, dwarf_segment_offset, dwarf_segment);
        const first_dwarf_section = dwarf_segment_offset + @sizeOf(macho.segment_command_64);
        const debug_sections = [_]struct {
            name: [16]u8,
            address: usize,
            offset: usize,
            contents: []const u8,
        }{
            .{ .name = machoName("__debug_abbrev"), .address = 0, .offset = abbrev_offset, .contents = sections.abbrev },
            .{ .name = machoName("__debug_info"), .address = sections.abbrev.len, .offset = info_offset, .contents = sections.info },
            .{ .name = machoName("__debug_line"), .address = sections.abbrev.len + sections.info.len, .offset = line_offset, .contents = sections.line },
        };
        for (debug_sections, 0..) |debug, index| {
            const debug_section: macho.section_64 = .{
                .sectname = debug.name,
                .segname = machoName("__DWARF"),
                // Keep DWARF addresses segment-relative. The GDB JIT loader
                // remaps them to their backing symfile bytes; generated-code
                // addresses would make LLDB read past the executable mapping.
                .addr = debug.address,
                .size = debug.contents.len,
                .offset = try u32Offset(debug.offset),
                .flags = macho.S_REGULAR | macho.S_ATTR_DEBUG,
            };
            writeStruct(
                bytes,
                first_dwarf_section + index * @sizeOf(macho.section_64),
                debug_section,
            );
            @memcpy(bytes[debug.offset..][0..debug.contents.len], debug.contents);
        }
    }

    const symtab_offset = segment_offset + text_segment_size + dwarf_segment_size;
    const symtab: macho.symtab_command = .{
        .symoff = try u32Offset(symbol_offset),
        .nsyms = 1,
        .stroff = try u32Offset(string_offset),
        .strsize = try u32Offset(string_size),
    };
    writeStruct(bytes, symtab_offset, symtab);

    @memcpy(bytes[text_offset..text_end], artifact.code);
    const symbol: macho.nlist_64 = .{
        .n_strx = 1,
        .n_type = .{ .bits = .{ .ext = true, .type = .sect, .pext = false, .is_stab = 0 } },
        .n_sect = 1,
        .n_desc = .{
            .arm_thumb_def = false,
            .referenced_dynamically = false,
            .discarded_or_no_dead_strip = false,
            .weak_ref = false,
            .weak_def_or_ref_to_weak = false,
            .symbol_resolver = false,
            .alt_entry = false,
        },
        .n_value = artifact.pc_start,
    };
    writeStruct(bytes, symbol_offset, symbol);
    bytes[string_offset] = 0;
    bytes[string_offset + 1] = '_';
    @memcpy(bytes[string_offset + 2 ..][0..artifact.symbol_name.len], artifact.symbol_name);
    return bytes;
}

test "Mach-O publication registers exact executable section and stable symbol" {
    if (!supportsMachOObject()) return error.SkipZigTest;
    const code = [_]u8{ 0xc0, 0x03, 0x5f, 0xd6 };
    const interface = publisher();
    var publication = (try interface.publish(std.testing.allocator, .{
        .kind = .baseline,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "zig_js_baseline_7_observedNative",
        .function_name = "observedNative",
        .function_identity = 11,
        .script_id = 13,
        .source_url = "fixture.js",
        .source_byte_offset = 17,
        .source_line = 2,
        .source_column = 3,
    })) orelse return error.TestUnexpectedResult;
    defer publication.deinit();

    const registration: *Registration = @ptrCast(@alignCast(publication.token));
    try std.testing.expectEqual(&registration.entry, __jit_debug_descriptor.first_entry.?);
    try std.testing.expectEqual(Action.no_action, __jit_debug_descriptor.action_flag);
    const header = std.mem.bytesToValue(std.macho.mach_header_64, registration.symfile[0..@sizeOf(std.macho.mach_header_64)]);
    try std.testing.expectEqual(std.macho.MH_OBJECT, header.filetype);
    const section_offset = @sizeOf(std.macho.mach_header_64) + @sizeOf(std.macho.segment_command_64);
    const section = std.mem.bytesToValue(std.macho.section_64, registration.symfile[section_offset..][0..@sizeOf(std.macho.section_64)]);
    const segment = std.mem.bytesToValue(
        std.macho.segment_command_64,
        registration.symfile[@sizeOf(std.macho.mach_header_64)..][0..@sizeOf(std.macho.segment_command_64)],
    );
    try std.testing.expectEqual(@as(u32, 1), segment.nsects);
    try std.testing.expectEqual(@intFromPtr(&code), section.addr);
    try std.testing.expectEqual(code.len, section.size);
    const symtab_offset = section_offset + @sizeOf(std.macho.section_64);
    const symtab = std.mem.bytesToValue(std.macho.symtab_command, registration.symfile[symtab_offset..][0..@sizeOf(std.macho.symtab_command)]);
    const symbol = std.mem.bytesToValue(std.macho.nlist_64, registration.symfile[symtab.symoff..][0..@sizeOf(std.macho.nlist_64)]);
    try std.testing.expectEqual(@intFromPtr(&code), symbol.n_value);
    try std.testing.expectEqualStrings(
        "\x00_zig_js_baseline_7_observedNative\x00",
        registration.symfile[symtab.stroff..][0..symtab.strsize],
    );
}

fn readTestUleb(bytes: []const u8, cursor: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (cursor.* < bytes.len) {
        const byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return result;
        if (shift > 56) return error.TestUnexpectedResult;
        shift += 7;
    }
    return error.TestUnexpectedResult;
}

fn readTestSleb(bytes: []const u8, cursor: *usize) !i64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    var byte: u8 = 0;
    while (cursor.* < bytes.len) {
        byte = bytes[cursor.*];
        cursor.* += 1;
        result |= @as(u64, byte & 0x7f) << @intCast(shift);
        shift += 7;
        if (byte & 0x80 == 0) break;
        if (shift >= 64) return error.TestUnexpectedResult;
    } else return error.TestUnexpectedResult;
    if (shift < 64 and byte & 0x40 != 0)
        result |= @as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(shift));
    return @bitCast(result);
}

test "Mach-O publication emits exact DWARF rows and closes unmapped ranges" {
    if (!supportsMachOObject()) return error.SkipZigTest;
    const code: [20]u8 align(4) = @splat(0);
    const source_url = "native-observability-fixture.js";
    const interface = publisher();
    var publication = (try interface.publish(std.testing.allocator, .{
        .kind = .baseline,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "zig_js_baseline_12_sourceFixture",
        .function_name = "sourceFixture",
        .function_identity = 12,
        .script_id = 17,
        .source_url = source_url,
        .source_byte_offset = 9,
        .source_line = 2,
        .source_column = 3,
        .pc_locations = &.{
            .{ .native_offset = 0 },
            .{ .native_offset = 4, .bytecode_offset = 2, .source = .{ .byte_offset = 9, .line = 2, .column = 3 } },
            .{ .native_offset = 8, .bytecode_offset = 7, .source = .{ .byte_offset = 21, .line = 5, .column = 1 } },
            .{ .native_offset = 12 },
            .{ .native_offset = 16, .bytecode_offset = 11, .source = .{ .byte_offset = 44, .line = 8, .column = 2 } },
        },
    })) orelse return error.TestUnexpectedResult;
    defer publication.deinit();

    const registration: *Registration = @ptrCast(@alignCast(publication.token));
    const header_size = @sizeOf(std.macho.mach_header_64);
    const segment = std.mem.bytesToValue(
        std.macho.segment_command_64,
        registration.symfile[header_size..][0..@sizeOf(std.macho.segment_command_64)],
    );
    try std.testing.expectEqual(@as(u32, 1), segment.nsects);
    const first_section = header_size + @sizeOf(std.macho.segment_command_64);
    const text_segment_size = @sizeOf(std.macho.segment_command_64) + @sizeOf(std.macho.section_64);
    const dwarf_segment_offset = header_size + text_segment_size;
    const dwarf_segment = std.mem.bytesToValue(
        std.macho.segment_command_64,
        registration.symfile[dwarf_segment_offset..][0..@sizeOf(std.macho.segment_command_64)],
    );
    try std.testing.expectEqualStrings("__DWARF", std.mem.sliceTo(&dwarf_segment.segname, 0));
    try std.testing.expectEqual(@as(u32, 3), dwarf_segment.nsects);
    const first_dwarf_section = dwarf_segment_offset + @sizeOf(std.macho.segment_command_64);
    const expected_names = [_][]const u8{ "__text", "__debug_abbrev", "__debug_info", "__debug_line" };
    var sections: [4]std.macho.section_64 = undefined;
    for (&sections, 0..) |*section, index| {
        const offset = if (index == 0)
            first_section
        else
            first_dwarf_section + (index - 1) * @sizeOf(std.macho.section_64);
        section.* = std.mem.bytesToValue(
            std.macho.section_64,
            registration.symfile[offset..][0..@sizeOf(std.macho.section_64)],
        );
        try std.testing.expectEqualStrings(expected_names[index], section.sectName());
        if (index != 0) {
            try std.testing.expectEqualStrings("__DWARF", section.segName());
            try std.testing.expect(section.isDebug());
        }
    }

    const line_section = sections[3];
    const line_start: usize = line_section.offset;
    const line_size: usize = @intCast(line_section.size);
    const line = registration.symfile[line_start..][0..line_size];
    try std.testing.expectEqual(line.len - 4, std.mem.readInt(u32, line[0..4], .little));
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, line[4..6], .little));
    const header_length: usize = std.mem.readInt(u32, line[6..10], .little);
    var cursor = 10 + header_length;
    var address: usize = 0;
    var source_line: i64 = 1;
    var column: u64 = 0;
    const Row = struct { address: usize, line: i64, column: u64, end_sequence: bool };
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(std.testing.allocator);
    while (cursor < line.len) {
        const opcode = line[cursor];
        cursor += 1;
        if (opcode == std.dwarf.LNS.extended_op) {
            const payload_length = try readTestUleb(line, &cursor);
            const payload_end = cursor + @as(usize, @intCast(payload_length));
            if (payload_end > line.len or cursor == payload_end) return error.TestUnexpectedResult;
            const extended = line[cursor];
            cursor += 1;
            switch (extended) {
                std.dwarf.LNE.set_address => {
                    if (payload_end - cursor != @sizeOf(u64)) return error.TestUnexpectedResult;
                    address = @intCast(std.mem.readInt(u64, line[cursor..][0..8], .little));
                },
                std.dwarf.LNE.end_sequence => {
                    try rows.append(std.testing.allocator, .{
                        .address = address,
                        .line = source_line,
                        .column = column,
                        .end_sequence = true,
                    });
                    address = 0;
                    source_line = 1;
                    column = 0;
                },
                else => return error.TestUnexpectedResult,
            }
            cursor = payload_end;
            continue;
        }
        switch (opcode) {
            std.dwarf.LNS.advance_line => source_line += try readTestSleb(line, &cursor),
            std.dwarf.LNS.set_column => column = try readTestUleb(line, &cursor),
            std.dwarf.LNS.copy => try rows.append(std.testing.allocator, .{
                .address = address,
                .line = source_line,
                .column = column,
                .end_sequence = false,
            }),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqualSlices(Row, &.{
        .{ .address = @intFromPtr(&code) + 4, .line = 2, .column = 3, .end_sequence = false },
        .{ .address = @intFromPtr(&code) + 8, .line = 5, .column = 1, .end_sequence = false },
        .{ .address = @intFromPtr(&code) + 12, .line = 5, .column = 1, .end_sequence = true },
        .{ .address = @intFromPtr(&code) + 16, .line = 8, .column = 2, .end_sequence = false },
        .{ .address = @intFromPtr(&code) + code.len, .line = 8, .column = 2, .end_sequence = true },
    }, rows.items);
}

test "Darwin publication registers and retires exact AArch64 dynamic FDE" {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const code align(4) = [_]u8{
        0xfd, 0x7b, 0xbf, 0xa9, // stp x29, x30, [sp, #-16]!
        0xfd, 0x03, 0x00, 0x91, // mov x29, sp
        0x1f, 0x20, 0x03, 0xd5, // nop
        0xfd, 0x7b, 0xc1, 0xa8, // ldp x29, x30, [sp], #16
        0xc0, 0x03, 0x5f, 0xd6, // ret
    };
    const interface = publisher();
    var publication = (try interface.publish(std.testing.allocator, .{
        .kind = .baseline,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "zig_js_baseline_9_unwindFixture",
        .function_name = "unwindFixture",
        .function_identity = 9,
        .script_id = 9,
        .source_url = "unwind-fixture.js",
        .source_byte_offset = 0,
        .source_line = 1,
        .source_column = 1,
        .unwind = .{ .aarch64_frame_pointer = .{ .epilogue_offset = 12 } },
    })) orelse return error.TestUnexpectedResult;

    const registration: *Registration = @ptrCast(@alignCast(publication.token));
    const unwind = registration.unwind orelse return error.TestUnexpectedResult;
    var bases: DwarfEhBases = undefined;
    try std.testing.expectEqual(unwind.fde(), _Unwind_Find_FDE(@ptrCast(&code), &bases).?);
    try std.testing.expectEqual(@intFromPtr(&code), bases.func);
    const expected_cfi = [_]u8{
        0x44, 0x0e, 0x10, 0x9d, 0x02, 0x9e, 0x01, 0x44, 0x0d, 0x1d,
        0x48, 0x0c, 0x1f, 0x00, 0x08, 0x1d, 0x08, 0x1e,
    };
    try std.testing.expectEqualSlices(
        u8,
        &expected_cfi,
        unwind.bytes[unwind.fde_offset + 25 ..][0..expected_cfi.len],
    );

    publication.deinit();
    try std.testing.expect(_Unwind_Find_FDE(@ptrCast(&code), &bases) == null);
}

test "Mach-O publication unlink removes the debugger entry before storage release" {
    if (!supportsMachOObject()) return error.SkipZigTest;
    const code = [_]u8{ 0xc0, 0x03, 0x5f, 0xd6 };
    const interface = publisher();
    var publication = (try interface.publish(std.testing.allocator, .{
        .kind = .optimizer,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "zig_js_optimizer_8_retired",
        .function_name = "retired",
        .function_identity = 1,
        .script_id = 1,
        .source_url = "",
        .source_byte_offset = 0,
        .source_line = 1,
        .source_column = 1,
    })) orelse return error.TestUnexpectedResult;
    try std.testing.expect(__jit_debug_descriptor.first_entry != null);
    publication.deinit();
    try std.testing.expect(__jit_debug_descriptor.first_entry == null);
    try std.testing.expectEqual(Action.no_action, __jit_debug_descriptor.action_flag);
}

fn churnPublications() void {
    const code = [_]u8{ 0xc0, 0x03, 0x5f, 0xd6 };
    const interface = publisher();
    for (0..64) |_| {
        var publication = (interface.publish(std.heap.page_allocator, .{
            .kind = .baseline,
            .pc_start = @intFromPtr(&code),
            .code = &code,
            .symbol_name = "zig_js_baseline_9_concurrent",
            .function_name = "concurrent",
            .function_identity = 1,
            .script_id = 1,
            .source_url = "",
            .source_byte_offset = 0,
            .source_line = 1,
            .source_column = 1,
            .unwind = if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
                .aarch64_leaf
            else
                .none,
        }) catch @panic("publication allocation failed")) orelse @panic("publication unsupported");
        publication.deinit();
    }
}

test "Mach-O publication list serializes concurrent register and unregister" {
    if (!supportsMachOObject() or builtin.single_threaded) return error.SkipZigTest;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, churnPublications, .{});
    for (&threads) |*thread| thread.join();
    try std.testing.expect(__jit_debug_descriptor.first_entry == null);
    try std.testing.expectEqual(Action.no_action, __jit_debug_descriptor.action_flag);
}
