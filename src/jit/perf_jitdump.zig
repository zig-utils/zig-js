//! Opt-in Linux perf jitdump publication.
//!
//! The writer follows `tools/perf/Documentation/jitdump-specification.txt`:
//! it creates the executable file mapping perf uses for discovery, appends
//! debug records before their matching load records, and closes the stream
//! only after every Owner using its Publisher has retired.

const std = @import("std");
const builtin = @import("builtin");
const observability = @import("native_observability.zig");

const magic: u32 = 0x4a695444; // "JiTD" in the producer's native endian.
const version: u32 = 1;

const RecordKind = enum(u32) {
    code_load = 0,
    code_move = 1,
    code_debug_info = 2,
    code_close = 3,
    code_unwinding_info = 4,
};

const FileHeader = extern struct {
    magic: u32,
    version: u32,
    total_size: u32,
    elf_machine: u32,
    reserved: u32,
    pid: u32,
    timestamp: u64,
    flags: u64,
};

const RecordHeader = extern struct {
    kind: RecordKind,
    total_size: u32,
    timestamp: u64,
};

const CodeLoad = extern struct {
    header: RecordHeader,
    pid: u32,
    tid: u32,
    vma: u64,
    code_address: u64,
    code_size: u64,
    code_index: u64,
};

const DebugInfo = extern struct {
    header: RecordHeader,
    code_address: u64,
    entry_count: u64,
};

const DebugEntry = extern struct {
    code_address: u64,
    line: u32,
    discriminator: u32,
};

comptime {
    if (@sizeOf(FileHeader) != 40 or @sizeOf(RecordHeader) != 16 or
        @sizeOf(CodeLoad) != 56 or @sizeOf(DebugInfo) != 32 or
        @sizeOf(DebugEntry) != 16)
        @compileError("jitdump records do not match the perf ABI");
}

pub const Stats = struct {
    load_records: u64,
    debug_records: u64,
    bytes_written: u64,
    closed: bool,
    failed: bool,
};

/// One explicitly selected Linux perf stream. The caller must keep this value
/// at a stable address and must retire every Owner using `publisher()` before
/// calling `deinit`. The dump file intentionally remains on disk for
/// `perf inject --jit`; perf owns its eventual cleanup policy.
pub const Writer = struct {
    io: std.Io,
    file: std.Io.File,
    lock: std.atomic.Mutex = .unlocked,
    pid: u32,
    next_code_index: u64 = 1,
    load_records: u64 = 0,
    debug_records: u64 = 0,
    bytes_written: u64 = @sizeOf(FileHeader),
    closed: bool = false,
    failed: bool = false,

    pub const InitError = std.Io.File.OpenError || std.Io.File.Writer.Error ||
        std.posix.MMapError || error{ UnsupportedTarget, UnsupportedArchitecture };

    /// Create `jit-<pid>.dump` with exclusive semantics in `directory`.
    /// Exclusive creation prevents following a pre-existing symlink.
    pub fn init(directory: std.Io.Dir, io: std.Io) InitError!Writer {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedTarget;
        const pid: u32 = @intCast(std.os.linux.getpid());
        var name_buffer: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "jit-{d}.dump", .{pid}) catch unreachable;
        const file = try directory.createFile(io, name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
        });
        errdefer file.close(io);
        errdefer directory.deleteFile(io, name) catch {};

        const header: FileHeader = .{
            .magic = magic,
            .version = version,
            .total_size = @sizeOf(FileHeader),
            .elf_machine = try elfMachine(builtin.cpu.arch),
            .reserved = 0,
            .pid = pid,
            .timestamp = timestamp(io),
            .flags = 0,
        };
        try file.writeStreamingAll(io, std.mem.asBytes(&header));

        // perf discovers jitdump streams through this executable file mapping.
        // The mapping is only a notification vehicle and is never accessed.
        const marker = try std.posix.mmap(
            null,
            std.heap.page_size_min,
            .{ .READ = true, .EXEC = true },
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
        std.posix.munmap(marker);

        return .{ .io = io, .file = file, .pid = pid };
    }

    pub fn publisher(self: *Writer) observability.Publisher {
        return .{
            .context = self,
            .publish_fn = publish,
            .unpublish_fn = unpublish,
        };
    }

    pub fn snapshot(self: *Writer) Stats {
        self.acquire();
        defer self.lock.unlock();
        return .{
            .load_records = self.load_records,
            .debug_records = self.debug_records,
            .bytes_written = self.bytes_written,
            .closed = self.closed,
            .failed = self.failed,
        };
    }

    /// Emit the optional close marker, flush it, and release the descriptor.
    /// No Publisher callback may run after this function begins.
    pub fn deinit(self: *Writer) (std.Io.File.Writer.Error || std.Io.File.SyncError)!void {
        self.acquire();
        defer self.lock.unlock();
        std.debug.assert(!self.closed);
        self.closed = true;
        if (!self.failed) {
            const close_record: RecordHeader = .{
                .kind = .code_close,
                .total_size = @sizeOf(RecordHeader),
                .timestamp = timestamp(self.io),
            };
            self.file.writeStreamingAll(self.io, std.mem.asBytes(&close_record)) catch |err| {
                self.failed = true;
                self.file.close(self.io);
                return err;
            };
            self.bytes_written += @sizeOf(RecordHeader);
        }
        self.file.sync(self.io) catch |err| {
            self.failed = true;
            self.file.close(self.io);
            return err;
        };
        self.file.close(self.io);
    }

    fn acquire(self: *Writer) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn publish(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        artifact: observability.Artifact,
    ) observability.PublishError!?*anyopaque {
        const self: *Writer = @ptrCast(@alignCast(context.?));
        if (artifact.code.len == 0 or artifact.pc_start != @intFromPtr(artifact.code.ptr))
            return error.NativeCodePublicationFailed;

        self.acquire();
        defer self.lock.unlock();
        if (self.closed or self.failed) return error.NativeCodePublicationFailed;

        var encoded: std.ArrayListUnmanaged(u8) = .empty;
        defer encoded.deinit(allocator);
        var next_index = self.next_code_index;
        const counts = try appendArtifactRecords(
            &encoded,
            allocator,
            artifact,
            self.pid,
            linuxTid(),
            &next_index,
            timestamp(self.io),
        );
        self.file.writeStreamingAll(self.io, encoded.items) catch {
            self.failed = true;
            return error.NativeCodePublicationFailed;
        };
        self.next_code_index = next_index;
        self.load_records +|= counts.loads;
        self.debug_records +|= counts.debugs;
        self.bytes_written +|= encoded.items.len;

        // jitdump has no unload record. Later address reuse is disambiguated by
        // a newer timestamped LOAD/code_index; no artifact storage is retained.
        return self;
    }

    fn unpublish(_: ?*anyopaque, _: *anyopaque) void {}
};

const RecordCounts = struct { loads: u64 = 0, debugs: u64 = 0 };

fn appendArtifactRecords(
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
    pid: u32,
    tid: u32,
    next_code_index: *u64,
    record_timestamp: u64,
) observability.PublishError!RecordCounts {
    if (std.mem.indexOfScalar(u8, artifact.symbol_name, 0) != null or
        std.mem.indexOfScalar(u8, artifact.source_url, 0) != null)
        return error.NativeCodePublicationFailed;
    var counts = RecordCounts{};
    if (artifact.pc_locations.len == 0) {
        try appendLoad(output, allocator, artifact, pid, tid, next_code_index, record_timestamp, 0, artifact.code.len);
        counts.loads = 1;
        return counts;
    }

    if (artifact.pc_locations[0].native_offset != 0) {
        try appendLoad(
            output,
            allocator,
            artifact,
            pid,
            tid,
            next_code_index,
            record_timestamp,
            0,
            artifact.pc_locations[0].native_offset,
        );
        counts.loads = 1;
    }
    var previous_offset: u32 = 0;
    for (artifact.pc_locations, 0..) |location, index| {
        if (location.native_offset >= artifact.code.len or
            (index != 0 and location.native_offset <= previous_offset))
            return error.NativeCodePublicationFailed;
        previous_offset = location.native_offset;
        const end = if (index + 1 < artifact.pc_locations.len)
            artifact.pc_locations[index + 1].native_offset
        else
            std.math.cast(u32, artifact.code.len) orelse return error.NativeSymbolObjectTooLarge;
        if (end <= location.native_offset) return error.NativeCodePublicationFailed;
        if (location.source) |source| {
            if (artifact.source_url.len != 0) {
                try appendDebug(output, allocator, artifact, source, record_timestamp, location.native_offset);
                counts.debugs += 1;
            }
        }
        try appendLoad(
            output,
            allocator,
            artifact,
            pid,
            tid,
            next_code_index,
            record_timestamp,
            location.native_offset,
            end,
        );
        counts.loads += 1;
    }
    return counts;
}

fn appendDebug(
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
    source: observability.SourcePosition,
    record_timestamp: u64,
    native_offset: u32,
) observability.PublishError!void {
    if (source.line == 0) return error.NativeCodePublicationFailed;
    const fixed_size = std.math.add(usize, @sizeOf(DebugInfo), @sizeOf(DebugEntry)) catch
        return error.NativeSymbolObjectTooLarge;
    const name_size = std.math.add(usize, artifact.source_url.len, 1) catch
        return error.NativeSymbolObjectTooLarge;
    const total_size = std.math.add(usize, fixed_size, name_size) catch
        return error.NativeSymbolObjectTooLarge;
    const address = std.math.add(usize, artifact.pc_start, native_offset) catch
        return error.NativeCodePublicationFailed;
    const record: DebugInfo = .{
        .header = .{
            .kind = .code_debug_info,
            .total_size = std.math.cast(u32, total_size) orelse return error.NativeSymbolObjectTooLarge,
            .timestamp = record_timestamp,
        },
        .code_address = address,
        .entry_count = 1,
    };
    const entry: DebugEntry = .{
        .code_address = address,
        .line = std.math.cast(u32, source.line) orelse return error.NativeSymbolObjectTooLarge,
        // perf's field is a discriminator, not a source column. Columns remain
        // available through the owned registry rather than being mislabeled.
        .discriminator = 0,
    };
    try output.appendSlice(allocator, std.mem.asBytes(&record));
    try output.appendSlice(allocator, std.mem.asBytes(&entry));
    try output.appendSlice(allocator, artifact.source_url);
    try output.append(allocator, 0);
}

fn appendLoad(
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    artifact: observability.Artifact,
    pid: u32,
    tid: u32,
    next_code_index: *u64,
    record_timestamp: u64,
    start: usize,
    end: usize,
) observability.PublishError!void {
    if (end <= start or end > artifact.code.len or next_code_index.* == 0)
        return error.NativeCodePublicationFailed;
    const code = artifact.code[start..end];
    const name_size = std.math.add(usize, artifact.symbol_name.len, 1) catch
        return error.NativeSymbolObjectTooLarge;
    const fixed_size = std.math.add(usize, @sizeOf(CodeLoad), name_size) catch
        return error.NativeSymbolObjectTooLarge;
    const total_size = std.math.add(usize, fixed_size, code.len) catch
        return error.NativeSymbolObjectTooLarge;
    const address = std.math.add(usize, artifact.pc_start, start) catch
        return error.NativeCodePublicationFailed;
    const record: CodeLoad = .{
        .header = .{
            .kind = .code_load,
            .total_size = std.math.cast(u32, total_size) orelse return error.NativeSymbolObjectTooLarge,
            .timestamp = record_timestamp,
        },
        .pid = pid,
        .tid = tid,
        .vma = address,
        .code_address = address,
        .code_size = code.len,
        .code_index = next_code_index.*,
    };
    next_code_index.* +%= 1;
    if (next_code_index.* == 0) return error.NativeCodePublicationFailed;
    try output.appendSlice(allocator, std.mem.asBytes(&record));
    try output.appendSlice(allocator, artifact.symbol_name);
    try output.append(allocator, 0);
    try output.appendSlice(allocator, code);
}

fn timestamp(io: std.Io) u64 {
    return @intCast(@max(std.Io.Timestamp.now(io, .awake).nanoseconds, 0));
}

fn linuxTid() u32 {
    if (comptime builtin.os.tag == .linux) return @intCast(std.os.linux.gettid());
    return 0;
}

fn elfMachine(arch: std.Target.Cpu.Arch) error{UnsupportedArchitecture}!u32 {
    return switch (arch) {
        .x86_64 => 62, // EM_X86_64
        .aarch64 => 183, // EM_AARCH64
        else => error.UnsupportedArchitecture,
    };
}

test "perf jitdump encodes exact source and unmapped spans" {
    var code = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const locations = [_]observability.PcLocation{
        .{ .native_offset = 0 },
        .{ .native_offset = 2, .bytecode_offset = 7, .source = .{ .byte_offset = 10, .line = 23, .column = 4 } },
        .{ .native_offset = 6 },
    };
    const artifact: observability.Artifact = .{
        .kind = .optimizer,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "zig_js_optimizer_4_target",
        .function_name = "target",
        .function_identity = 9,
        .script_id = 3,
        .source_url = "target.js",
        .source_byte_offset = 0,
        .source_line = 20,
        .source_column = 1,
        .pc_locations = &locations,
    };
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var next_index: u64 = 1;
    const counts = try appendArtifactRecords(&bytes, std.testing.allocator, artifact, 41, 42, &next_index, 99);
    try std.testing.expectEqual(@as(u64, 3), counts.loads);
    try std.testing.expectEqual(@as(u64, 1), counts.debugs);
    try std.testing.expectEqual(@as(u64, 4), next_index);

    var cursor: usize = 0;
    const first_load: *align(1) const CodeLoad = @ptrCast(&bytes.items[cursor]);
    try std.testing.expectEqual(RecordKind.code_load, first_load.header.kind);
    try std.testing.expectEqual(@as(u64, 2), first_load.code_size);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&code)), first_load.code_address);
    cursor += first_load.header.total_size;

    const debug: *align(1) const DebugInfo = @ptrCast(&bytes.items[cursor]);
    try std.testing.expectEqual(RecordKind.code_debug_info, debug.header.kind);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&code) + 2), debug.code_address);
    const entry: *align(1) const DebugEntry = @ptrCast(&bytes.items[cursor + @sizeOf(DebugInfo)]);
    try std.testing.expectEqual(@as(u32, 23), entry.line);
    try std.testing.expectEqual(@as(u32, 0), entry.discriminator);
    cursor += debug.header.total_size;

    const mapped_load: *align(1) const CodeLoad = @ptrCast(&bytes.items[cursor]);
    try std.testing.expectEqual(RecordKind.code_load, mapped_load.header.kind);
    try std.testing.expectEqual(@as(u64, 4), mapped_load.code_size);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&code) + 2), mapped_load.code_address);
    cursor += mapped_load.header.total_size;
    const final_load: *align(1) const CodeLoad = @ptrCast(&bytes.items[cursor]);
    try std.testing.expectEqual(RecordKind.code_load, final_load.header.kind);
    try std.testing.expectEqual(@as(u64, 2), final_load.code_size);
    cursor += final_load.header.total_size;
    try std.testing.expectEqual(bytes.items.len, cursor);
}

test "perf jitdump rejects unsorted or out of range PC maps" {
    var code = [_]u8{ 1, 2, 3, 4 };
    const locations = [_]observability.PcLocation{
        .{ .native_offset = 2 },
        .{ .native_offset = 2 },
    };
    const artifact: observability.Artifact = .{
        .kind = .baseline,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "bad",
        .function_name = "bad",
        .function_identity = 1,
        .script_id = 1,
        .source_url = "bad.js",
        .source_byte_offset = 0,
        .source_line = 1,
        .source_column = 1,
        .pc_locations = &locations,
    };
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var next_index: u64 = 1;
    try std.testing.expectError(
        error.NativeCodePublicationFailed,
        appendArtifactRecords(&bytes, std.testing.allocator, artifact, 1, 1, &next_index, 1),
    );
}

test "perf jitdump keeps a leading unmapped span and rejects embedded NUL" {
    var code = [_]u8{ 1, 2, 3, 4 };
    const locations = [_]observability.PcLocation{
        .{ .native_offset = 2, .bytecode_offset = 1, .source = .{ .byte_offset = 1, .line = 2, .column = 1 } },
    };
    var artifact: observability.Artifact = .{
        .kind = .baseline,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "leading",
        .function_name = "leading",
        .function_identity = 1,
        .script_id = 1,
        .source_url = "leading.js",
        .source_byte_offset = 0,
        .source_line = 1,
        .source_column = 1,
        .pc_locations = &locations,
    };
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var next_index: u64 = 1;
    const counts = try appendArtifactRecords(&bytes, std.testing.allocator, artifact, 1, 1, &next_index, 1);
    try std.testing.expectEqual(@as(u64, 2), counts.loads);
    try std.testing.expectEqual(@as(u64, 1), counts.debugs);
    const prefix: *align(1) const CodeLoad = @ptrCast(&bytes.items[0]);
    try std.testing.expectEqual(@as(u64, 2), prefix.code_size);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&code)), prefix.code_address);

    bytes.clearRetainingCapacity();
    next_index = 1;
    artifact.symbol_name = "bad\x00symbol";
    try std.testing.expectError(
        error.NativeCodePublicationFailed,
        appendArtifactRecords(&bytes, std.testing.allocator, artifact, 1, 1, &next_index, 1),
    );
}

test "perf jitdump uses declared ELF machine values" {
    try std.testing.expectEqual(@as(u32, 62), try elfMachine(.x86_64));
    try std.testing.expectEqual(@as(u32, 183), try elfMachine(.aarch64));
    try std.testing.expectError(error.UnsupportedArchitecture, elfMachine(.wasm32));
}

test "perf jitdump Linux writer owns discovery and close lifecycle" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var writer = Writer.init(temporary.dir, std.testing.io) catch |err| switch (err) {
        // The adapter must report a noexec filesystem rather than silently
        // producing a dump that perf cannot discover.
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    var code = [_]u8{ 0xc3, 0x90 };
    const artifact: observability.Artifact = .{
        .kind = .baseline,
        .pc_start = @intFromPtr(&code),
        .code = &code,
        .symbol_name = "zig_js_baseline_1_linuxFixture",
        .function_name = "linuxFixture",
        .function_identity = 1,
        .script_id = 1,
        .source_url = "linux-fixture.js",
        .source_byte_offset = 0,
        .source_line = 1,
        .source_column = 1,
    };
    var publication = (try writer.publisher().publish(std.testing.allocator, artifact)) orelse
        return error.TestExpectedPublication;
    publication.deinit();
    const before_close = writer.snapshot();
    try std.testing.expectEqual(@as(u64, 1), before_close.load_records);
    try std.testing.expectEqual(@as(u64, 0), before_close.debug_records);
    try std.testing.expect(!before_close.closed and !before_close.failed);
    try writer.deinit();
    const after_close = writer.snapshot();
    try std.testing.expect(after_close.closed and !after_close.failed);
    try std.testing.expectEqual(before_close.bytes_written + @sizeOf(RecordHeader), after_close.bytes_written);
}
