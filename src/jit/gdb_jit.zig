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

fn createMachOObject(
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
) observability.PublishError![]u8 {
    const macho = std.macho;
    const segment_size = @sizeOf(macho.segment_command_64) + @sizeOf(macho.section_64);
    const commands_size = segment_size + @sizeOf(macho.symtab_command);
    const text_offset = try alignSize(@sizeOf(macho.mach_header_64) + commands_size, 16);
    const text_end = try addSize(text_offset, artifact.code.len);
    const symbol_offset = try alignSize(text_end, @alignOf(macho.nlist_64));
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
        .ncmds = 2,
        .sizeofcmds = @intCast(commands_size),
    };
    writeStruct(bytes, 0, header);

    const segment_offset = @sizeOf(macho.mach_header_64);
    const segment: macho.segment_command_64 = .{
        .cmdsize = @intCast(segment_size),
        .segname = @splat(0),
        .vmaddr = artifact.pc_start,
        .vmsize = artifact.code.len,
        .fileoff = text_offset,
        .filesize = artifact.code.len,
        .maxprot = .{ .READ = true, .EXEC = true },
        .initprot = .{ .READ = true, .EXEC = true },
        .nsects = 1,
    };
    writeStruct(bytes, segment_offset, segment);

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

    const symtab_offset = segment_offset + segment_size;
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
