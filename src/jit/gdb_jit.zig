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
    entry: CodeEntry,
};

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
    registration.* = .{
        .allocator = allocator,
        .symfile = symfile,
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
    allocator.free(registration.symfile);
    allocator.destroy(registration);
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
