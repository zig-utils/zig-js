//! External process observer for the unchanged Linux Debug+TSan shard (#1131).
//! This executable never links the engine or supplies JavaScript semantics.
const std = @import("std");
const builtin = @import("builtin");
const DarwinProcess = struct {
    // Native libproc.h / sys/proc_info.h platform ABI, not an engine record.
    // PROC_PGRP_ONLY=2, PROC_PIDT_SHORTBSDINFO=13 and sys/proc.h SZOMB=5.
    extern "c" fn proc_listpids(kind: u32, group: u32, buffer: *anyopaque, size: c_int) c_int;
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;
    const Info = extern struct {
        pid: u32,
        parent: u32,
        group: u32,
        status: u32,
        command: [16]u8,
        flags: u32,
        uid: u32,
        gid: u32,
        real_uid: u32,
        real_gid: u32,
        saved_uid: u32,
        saved_gid: u32,
        reserved: u32,
    };
    const FullInfo = extern struct {
        flags: u32,
        status: u32,
        exit_status: u32,
        pid: u32,
        parent: u32,
        uid: u32,
        gid: u32,
        real_uid: u32,
        real_gid: u32,
        saved_uid: u32,
        saved_gid: u32,
        reserved: u32,
        command: [16]u8,
        name: [32]u8,
        files: u32,
        group: u32,
        job_control: u32,
        terminal: u32,
        terminal_group: u32,
        nice: i32,
        start_seconds: u64,
        start_microseconds: u64,
    };
};

extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

const source = "b42c2c8fd93ba61b9ed7d9acd3c9a5663bb2efd6";
const fixture_sha256 = "926b8dd424cdbb6edbc82a12605d5165b750d386fb97387a6044e643a4e0ad2b";
const compiler_version = "0.18.0-dev.146+35accc06e";
const command = [_][]const u8{ "zig", "build", "test", "-Dtsan=true", "-Dunit-shard-index=1", "-Dunit-shard-count=4" };
const marker = "UNIT_TEST_STARTED\t78/721\t1/4\tcontext.test.captured frames: mapped canonical strings survive heap recovery";
const mib = 1024 * 1024;
const max_control = 65536;
const max_stream = 6 * mib;

// waitid is the native POSIX status interface. WNOWAIT keeps our child PID
// reserved until the owned process group has completed cleanup.
extern "c" fn waitid(id_type: c_uint, id: c_uint, info: *std.posix.siginfo_t, options: c_int) c_int;

// Signal handlers may only publish this flag. The observer performs all I/O,
// child cleanup and record writing after an acquire load in its normal loop.
var interrupted_signal: std.atomic.Value(u32) = .init(0);

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = interrupted_signal.cmpxchgStrong(0, @backingInt(sig), .release, .monotonic);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn sleepMs(io: std.Io, ms: i64) !void {
    try std.Io.sleep(io, .fromMilliseconds(ms), .awake);
}

const Record = enum {
    manifest,
    state,
    target,
    target_error,
    symbol_command,
    proc_error,
    backtrace_1,
    backtrace_2,
    backtrace_3,
    ready,
    result,
    debugger_probe,
    early_upload,

    fn filename(self: Record) []const u8 {
        return switch (self) {
            .target_error => "target-error.json",
            .symbol_command => "symbol-command.json",
            .proc_error => "proc-error.json",
            .backtrace_1 => "backtrace-1.json",
            .backtrace_2 => "backtrace-2.json",
            .backtrace_3 => "backtrace-3.json",
            .debugger_probe => "debugger-probe.json",
            .early_upload => "early-upload.json",
            .manifest => "manifest.json",
            .state => "state.json",
            .target => "target.json",
            .ready => "ready.json",
            .result => "result.json",
        };
    }
};

const Stream = enum {
    run,
    proc,
    build_processes,
    supervisor,

    fn filename(self: Stream) []const u8 {
        return switch (self) {
            .run => "run.log",
            .proc => "proc.jsonl",
            .build_processes => "build-processes.jsonl",
            .supervisor => "supervisor.log",
        };
    }

    fn cap(self: Stream) usize {
        return switch (self) {
            .run => max_stream,
            .proc => mib,
            .build_processes => mib / 2,
            .supervisor => 65536,
        };
    }
};

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    env: ?*const std.process.Environ.Map = null,

    fn path(self: Context, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, &.{ self.root, name });
    }

    fn save(self: Context, which: Record, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.gpa, value, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(bytes);
        if (bytes.len + 1 > max_control) return error.ControlRecordTooLarge;
        const name = try self.path(which.filename());
        defer self.gpa.free(name);
        const temporary = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{name});
        defer self.gpa.free(temporary);
        const file = try std.Io.Dir.cwd().createFile(self.io, temporary, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
        try file.writeStreamingAll(self.io, "\n");
        try std.Io.Dir.renameAbsolute(temporary, name, self.io);
    }

    fn append(self: Context, which: Stream, bytes: []const u8) !void {
        const name = try self.path(which.filename());
        defer self.gpa.free(name);
        const file = try std.Io.Dir.cwd().createFile(self.io, name, .{ .truncate = false });
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        const remaining = which.cap() -| size;
        if (remaining != 0) try file.writePositionalAll(self.io, bytes[0..@min(bytes.len, remaining)], size);
    }

    fn exists(self: Context, which: Record) bool {
        const name = self.path(which.filename()) catch return false;
        defer self.gpa.free(name);
        std.Io.Dir.cwd().access(self.io, name, .{}) catch return false;
        return true;
    }

    fn read(self: Context, name: []const u8, limit: usize) ![]u8 {
        const full = try self.path(name);
        defer self.gpa.free(full);
        return std.Io.Dir.cwd().readFileAlloc(self.io, full, self.gpa, .limited(limit));
    }

    fn appendJson(self: Context, which: Stream, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.gpa, value, .{ .emit_null_optional_fields = false });
        defer self.gpa.free(bytes);
        try self.append(which, bytes);
        try self.append(which, "\n");
    }
};

const Identity = struct {
    pid: std.posix.pid_t,
    state: []const u8,
    ppid: std.posix.pid_t,
    user_ticks: u64,
    system_ticks: u64,
    start_ticks: u64,
    rss_pages: i64,
    executable: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    binary_sha256: ?[]const u8 = null,
    wchan: ?[]const u8 = null,
    threads: ?[]const Identity = null,
    threads_capped: ?bool = null,
};

fn parseStat(pid: std.posix.pid_t, raw: []const u8) !Identity {
    // Linux permits spaces and parentheses inside comm; fields start after
    // the final closing parenthesis rather than the first whitespace.
    const end = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return error.MalformedProcStat;
    if (end + 2 >= raw.len or raw[end + 1] != ' ') return error.MalformedProcStat;
    var fields = std.mem.tokenizeAny(u8, raw[end + 2 ..], " \n\t");
    var wanted: [22][]const u8 = undefined;
    for (&wanted) |*field| field.* = fields.next() orelse return error.MalformedProcStat;
    const state = if (wanted[0].len == 1) switch (wanted[0][0]) {
        'R' => "R",
        'S' => "S",
        'D' => "D",
        'Z' => "Z",
        'T' => "T",
        't' => "t",
        'X' => "X",
        'I' => "I",
        'K' => "K",
        'W' => "W",
        'P' => "P",
        else => return error.MalformedProcStat,
    } else return error.MalformedProcStat;
    return .{
        .pid = pid,
        .state = state,
        .ppid = try std.fmt.parseInt(std.posix.pid_t, wanted[1], 10),
        .user_ticks = try std.fmt.parseInt(u64, wanted[11], 10),
        .system_ticks = try std.fmt.parseInt(u64, wanted[12], 10),
        .start_ticks = try std.fmt.parseInt(u64, wanted[19], 10),
        .rss_pages = try std.fmt.parseInt(i64, wanted[21], 10),
    };
}

fn readProcFileAlloc(dir: std.Io.Dir, io: std.Io, path: []const u8, gpa: std.mem.Allocator, limit: usize) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    // Procfs content is generated on read; its regular-file size can be zero.
    // Keep the existing reached-or-exceeded cap without using stat as EOF.
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemainingAlignedSentinel(gpa, .limited(limit), .of(u8), null) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn statRecord(ctx: Context, pid: std.posix.pid_t, base: []const u8) !Identity {
    const path = try std.fmt.allocPrint(ctx.gpa, "{s}/{d}/stat", .{ base, pid });
    defer ctx.gpa.free(path);
    const raw = try readProcFileAlloc(.cwd(), ctx.io, path, ctx.gpa, 65536);
    defer ctx.gpa.free(raw);
    return parseStat(pid, raw);
}

fn sameProcess(ctx: Context, identity: Identity) bool {
    const current = statRecord(ctx, identity.pid, "/proc") catch return false;
    return !std.mem.eql(u8, current.state, "Z") and current.start_ticks == identity.start_ticks;
}

fn shaFile(ctx: Context, path: []const u8) ![64]u8 {
    const file = try std.Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var buffer: [mib]u8 = undefined;
    while (true) {
        const count = file.readStreaming(ctx.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hash.update(buffer[0..count]);
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

const FixtureStamp = struct {
    pid: std.posix.pid_t,
    group: std.posix.pid_t,
    start_major: u64,
    start_minor: u64,
    status: u32,
    flags: u32,
};

fn processStamp(ctx: Context, pid: std.posix.pid_t) !FixtureStamp {
    if (builtin.os.tag.isDarwin()) {
        var info: DarwinProcess.FullInfo = undefined;
        if (DarwinProcess.proc_pidinfo(pid, 3, 1, &info, @sizeOf(@TypeOf(info))) != @sizeOf(@TypeOf(info))) return error.ProcessIdentityUnavailable;
        if (info.pid != @as(u32, @intCast(pid))) return error.ProcessIdentityMismatch;
        return .{ .pid = pid, .group = @intCast(info.group), .start_major = info.start_seconds, .start_minor = info.start_microseconds, .status = info.status, .flags = info.flags };
    }
    const info = try statRecord(ctx, pid, "/proc");
    const group = getpgid(pid);
    if (group < 0) return error.ProcessIdentityUnavailable;
    return .{ .pid = pid, .group = group, .start_major = info.start_ticks, .start_minor = 0, .status = if (std.mem.eql(u8, info.state, "Z")) 5 else 1, .flags = 0 };
}

fn sameFixtureStamp(a: FixtureStamp, b: FixtureStamp) bool {
    return a.pid == b.pid and a.group == b.group and a.start_major == b.start_major and a.start_minor == b.start_minor;
}

fn writeFixtureStamp(init: std.process.Init, destination: []const u8) !void {
    const stamp = try processStamp(.{ .gpa = init.gpa, .io = init.io, .root = "." }, std.c.getpid());
    const bytes = try std.json.Stringify.valueAlloc(init.gpa, stamp, .{});
    defer init.gpa.free(bytes);
    const temporary = try std.fmt.allocPrint(init.gpa, "{s}.tmp", .{destination});
    defer init.gpa.free(temporary);
    const file = try std.Io.Dir.cwd().createFile(init.io, temporary, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, bytes);
    try std.Io.Dir.renameAbsolute(temporary, destination, init.io);
}

const GroupState = enum { complete, pending, signalable };

fn mergeGroupState(a: GroupState, b: GroupState) GroupState {
    if (a == .signalable or b == .signalable) return .signalable;
    if (a == .pending or b == .pending) return .pending;
    return .complete;
}

const DarwinMemberLookup = struct {
    returned: c_int,
    info: ?DarwinProcess.Info,
};

fn lookupDarwinMember(pid: std.posix.pid_t) !DarwinMemberLookup {
    var info: DarwinProcess.Info = undefined;
    // BSD information arg1 includes zombies. A normal lookup can lose its
    // reference before an exiting process has released its descriptors.
    const found = DarwinProcess.proc_pidinfo(pid, 13, 1, &info, @sizeOf(@TypeOf(info)));
    const lookup_errno = if (found != @sizeOf(@TypeOf(info))) std.posix.errno(-1) else .SUCCESS;
    if (found == @sizeOf(@TypeOf(info))) {
        if (info.pid != @as(u32, @intCast(pid))) return error.ProcessGroupIdentityMismatch;
        return .{ .returned = found, .info = info };
    }
    if (found <= 0 and lookup_errno == .SRCH) return .{ .returned = found, .info = null };
    return error.ProcessGroupInspectionFailed;
}

fn classifyDarwinMember(group: std.posix.pid_t, lookup: DarwinMemberLookup) GroupState {
    const info = lookup.info orelse return .pending;
    if (info.group != @as(u32, @intCast(group))) return .complete;
    // A terminal zombie may retain INEXIT. Its terminal state wins.
    if (info.status == 5) return .complete;
    if ((info.flags & 4) != 0) return .pending;
    return .signalable;
}

const OwnedChild = struct {
    child: std.process.Child,
    pipe: std.Io.File,
    pid: std.posix.pid_t,
    term: ?std.process.Child.Term = null,
    reaped: bool = false,
    pipe_open: bool = true,

    fn spawn(io: std.Io, argv: []const []const u8) !OwnedChild {
        const pair = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        const reader: std.Io.File = .{ .handle = pair[0], .flags = .{ .nonblocking = false } };
        const writer: std.Io.File = .{ .handle = pair[1], .flags = .{ .nonblocking = false } };
        errdefer reader.close(io);
        defer writer.close(io);
        const child = try std.process.spawn(io, .{ .argv = argv, .pgid = 0, .stdin = .ignore, .stdout = .{ .file = writer }, .stderr = .{ .file = writer } });
        return .{ .child = child, .pipe = reader, .pid = child.id.? };
    }

    fn pollTerm(self: *OwnedChild) !?std.process.Child.Term {
        if (self.term) |term| return term;
        var info: std.posix.siginfo_t = undefined;
        @memset(std.mem.asBytes(&info), 0);
        const no_wait: c_int = if (builtin.os.tag == .linux) 0x01000000 else if (builtin.os.tag.isDarwin()) 0x20 else @compileError("native observer requires Linux or Darwin waitid flags");
        while (true) {
            switch (std.posix.errno(waitid(1, @intCast(self.pid), &info, 4 | std.posix.W.NOHANG | no_wait))) {
                .SUCCESS => {
                    if (info.code == 0) return null;
                    const status = if (builtin.os.tag == .linux) info.fields.common.second.sigchld.status else info.status;
                    self.term = switch (info.code) {
                        1 => .{ .exited = @intCast(status) },
                        2, 3 => .{ .signal = @fromBackingInt(@intCast(status)) },
                        else => return error.UnexpectedChildExitDisposition,
                    };
                    return self.term;
                },
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn reap(self: *OwnedChild) !bool {
        if (self.reaped) return true;
        var status: c_int = 0;
        while (true) {
            const result = std.posix.system.waitpid(self.pid, &status, std.posix.W.NOHANG);
            switch (std.posix.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return false;
                    self.term = std.Io.Threaded.statusToTerm(@bitCast(status));
                    self.child.id = null;
                    self.reaped = true;
                    return true;
                },
                .INTR => continue,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        }
    }

    fn stop(self: *OwnedChild, io: std.Io) !void {
        if (self.reaped) return;
        // Keep the zombie leader as the PID/PGID anchor until every listed
        // member has completed exit. Lost lookup access is not completed exit.
        const first = nowMs(io) + 1000;
        var term_posted = false;
        while (nowMs(io) < first) {
            const state = try self.groupState(io);
            if (state == .complete) break;
            if (state == .signalable and !term_posted) {
                term_posted = try self.signalGroup(io, .TERM);
                continue;
            }
            try sleepMs(io, 10);
        }
        const final = nowMs(io) + 2000;
        var kill_posted = false;
        while (nowMs(io) < final) {
            const state = try self.groupState(io);
            if (state == .complete and try self.reap()) {
                return;
            }
            if (state == .signalable and !kill_posted) {
                kill_posted = try self.signalGroup(io, .KILL);
                continue;
            }
            try sleepMs(io, 10);
        }
        return error.OwnedChildReapTimeout;
    }

    fn signalGroup(self: *const OwnedChild, io: std.Io, signal: std.posix.SIG) !bool {
        std.posix.kill(-self.pid, signal) catch |err| switch (err) {
            error.ProcessNotFound => return false,
            // A signal can race with exit. An exiting member still keeps
            // cleanup pending, but a genuinely signalable member must not have
            // its permission failure hidden.
            error.PermissionDenied => {
                if (try self.groupState(io) == .signalable) return err;
                return false;
            },
            else => return err,
        };
        return true;
    }

    fn groupState(self: *const OwnedChild, io: std.Io) !GroupState {
        if (builtin.os.tag.isDarwin()) {
            var pids: [256]c_int = @splat(0);
            const size = DarwinProcess.proc_listpids(2, @intCast(self.pid), &pids, @sizeOf(@TypeOf(pids)));
            if (size <= 0 or @mod(size, @sizeOf(c_int)) != 0) return error.ProcessGroupInspectionFailed;
            if (size >= @sizeOf(@TypeOf(pids))) return error.ProcessGroupInspectionLimit;
            var state: GroupState = .complete;
            for (pids[0..@intCast(@divExact(size, @sizeOf(c_int)))]) |pid| {
                if (pid <= 0) continue;
                const lookup = try lookupDarwinMember(pid);
                const classification = classifyDarwinMember(self.pid, lookup);
                state = mergeGroupState(state, classification);
            }
            return state;
        }
        var directory = try std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
        defer directory.close(io);
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            _ = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
            var path_buffer: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "{s}/stat", .{entry.name});
            const raw = readProcFileAlloc(directory, io, path, std.heap.page_allocator, 65536) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer std.heap.page_allocator.free(raw);
            const end = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return error.MalformedProcStat;
            var fields = std.mem.tokenizeAny(u8, raw[end + 1 ..], " \n\t");
            const state = fields.next() orelse return error.MalformedProcStat;
            _ = fields.next() orelse return error.MalformedProcStat;
            const group = try std.fmt.parseInt(std.posix.pid_t, fields.next() orelse return error.MalformedProcStat, 10);
            if (group == self.pid and !std.mem.eql(u8, state, "Z") and !std.mem.eql(u8, state, "X")) return .signalable;
        }
        return .complete;
    }

    fn closePipe(self: *OwnedChild, io: std.Io) void {
        if (self.pipe_open) self.pipe.close(io);
        self.pipe_open = false;
    }

    fn readReady(self: *OwnedChild, buffer: []u8, timeout_ms: i32) !?[]u8 {
        if (!self.pipe_open) return null;
        var fds = [_]std.posix.pollfd{.{ .fd = self.pipe.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return null;
        const count = try std.posix.read(self.pipe.handle, buffer);
        return buffer[0..count];
    }
};

fn exitCode(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| -@as(i32, @intCast(@backingInt(sig))),
        .stopped => |sig| -@as(i32, @intCast(@backingInt(sig))),
        .unknown => 255,
    };
}

fn shellExit(code: i32) u8 {
    return @intCast(@min(255, if (code < 0) 128 - code else code));
}

fn safeUtf8(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    var at: usize = 0;
    while (at < bytes.len) {
        const count = std.unicode.utf8ByteSequenceLength(bytes[at]) catch 0;
        if (count == 0 or at + count > bytes.len or !std.unicode.utf8ValidateSlice(bytes[at..][0..count])) {
            try result.appendSlice(gpa, "\xef\xbf\xbd");
            at += 1;
        } else {
            try result.appendSlice(gpa, bytes[at..][0..count]);
            at += count;
        }
    }
    return result.toOwnedSlice(gpa);
}

const CommandResult = struct {
    args: []const []const u8,
    pid: std.posix.pid_t,
    exit: i32,
    timed_out: bool,
    output_capped: bool,
    witnesses: []const []const u8,
    elapsed_seconds: f64,
    output: []const u8,

    fn deinit(self: CommandResult, gpa: std.mem.Allocator) void {
        gpa.free(self.witnesses);
        gpa.free(self.output);
    }
};

fn boundedCommand(ctx: Context, argv: []const []const u8, timeout_ms: i64, cap: usize, witnesses: []const []const u8) !CommandResult {
    const started = nowMs(ctx.io);
    var child = try OwnedChild.spawn(ctx.io, argv);
    defer child.closePipe(ctx.io);
    errdefer child.stop(ctx.io) catch {};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(ctx.gpa);
    const found = try ctx.gpa.alloc(bool, witnesses.len);
    defer ctx.gpa.free(found);
    @memset(found, false);
    var suffix: [64]u8 = undefined;
    var suffix_len: usize = 0;
    var timed_out = false;
    var seen_bytes: usize = 0;
    while (child.pipe_open or try child.pollTerm() == null) {
        if (interrupted_signal.load(.acquire) != 0) return error.ObserverInterrupted;
        if (nowMs(ctx.io) - started >= timeout_ms) {
            timed_out = true;
            try child.stop(ctx.io);
            break;
        }
        var block: [4096]u8 = undefined;
        if (try child.readReady(&block, 100)) |bytes| {
            if (bytes.len == 0) {
                child.closePipe(ctx.io);
            } else {
                seen_bytes +|= bytes.len;
                try output.appendSlice(ctx.gpa, bytes[0..@min(bytes.len, cap -| output.items.len)]);
                var scan: [4160]u8 = undefined;
                @memcpy(scan[0..suffix_len], suffix[0..suffix_len]);
                @memcpy(scan[suffix_len..][0..bytes.len], bytes);
                const text = scan[0 .. suffix_len + bytes.len];
                for (witnesses, 0..) |word, index| if (std.mem.indexOf(u8, text, word) != null) {
                    found[index] = true;
                };
                suffix_len = @min(64, text.len);
                @memcpy(suffix[0..suffix_len], text[text.len - suffix_len ..]);
            }
        } else if (!child.pipe_open) {
            try sleepMs(ctx.io, 10);
        }
    }
    try child.stop(ctx.io);
    const term = child.term orelse return error.ChildStatusMissing;
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer matches.deinit(ctx.gpa);
    for (witnesses, found) |word, present| if (present) {
        try matches.append(ctx.gpa, word);
    };
    return .{
        .args = argv,
        .pid = child.pid,
        .exit = exitCode(term),
        .timed_out = timed_out,
        .output_capped = seen_bytes > cap,
        .witnesses = try matches.toOwnedSlice(ctx.gpa),
        .elapsed_seconds = @as(f64, @floatFromInt(nowMs(ctx.io) - started)) / 1000,
        .output = try safeUtf8(ctx.gpa, output.items),
    };
}

fn findExecutable(ctx: Context, name: []const u8) !?[]u8 {
    const path = if (ctx.env) |env| env.get("PATH") orelse "" else "";
    var pieces = std.mem.splitScalar(u8, path, ':');
    while (pieces.next()) |directory| {
        const candidate = try std.fs.path.join(ctx.gpa, &.{ if (directory.len == 0) "." else directory, name });
        std.Io.Dir.cwd().access(ctx.io, candidate, .{ .execute = true }) catch {
            ctx.gpa.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

fn readLink(ctx: Context, path: []const u8) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().readLink(ctx.io, path, &buffer);
    return ctx.gpa.dupe(u8, buffer[0..len]);
}

fn procPath(ctx: Context, pid: std.posix.pid_t, tail: []const u8) ![]u8 {
    return std.fmt.allocPrint(ctx.gpa, "/proc/{d}/{s}", .{ pid, tail });
}

fn procArguments(ctx: Context, pid: std.posix.pid_t) ![]const []const u8 {
    const path = try procPath(ctx, pid, "cmdline");
    defer ctx.gpa.free(path);
    const bytes = try readProcFileAlloc(.cwd(), ctx.io, path, ctx.gpa, 512 * 1024);
    defer ctx.gpa.free(bytes);
    return parseArguments(ctx, bytes);
}

fn parseArguments(ctx: Context, bytes: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\x00"), 0);
    while (fields.next()) |arg| try args.append(ctx.gpa, try safeUtf8(ctx.gpa, arg));
    return args.toOwnedSlice(ctx.gpa);
}

fn ownedProcesses(ctx: Context, leader: std.posix.pid_t) !std.AutoHashMap(std.posix.pid_t, Identity) {
    var all: std.AutoHashMap(std.posix.pid_t, Identity) = .init(ctx.gpa);
    defer all.deinit();
    var proc = try std.Io.Dir.cwd().openDir(ctx.io, "/proc", .{ .iterate = true });
    defer proc.close(ctx.io);
    var iterator = proc.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        const record = statRecord(ctx, pid, "/proc") catch continue;
        try all.put(pid, record);
    }
    var descendants: std.AutoHashMap(std.posix.pid_t, Identity) = .init(ctx.gpa);
    errdefer descendants.deinit();
    if (all.get(leader)) |record| try descendants.put(leader, record);
    var changed = true;
    while (changed) {
        changed = false;
        var records = all.iterator();
        while (records.next()) |item| {
            const record = item.value_ptr.*;
            if (!descendants.contains(record.pid) and descendants.contains(record.ppid)) {
                try descendants.put(record.pid, record);
                changed = true;
            }
        }
    }
    return descendants;
}

fn targetForMarker(ctx: Context, leader: std.posix.pid_t, pipe_inode: std.Io.File.INode) !Identity {
    var records = try ownedProcesses(ctx, leader);
    defer records.deinit();
    var selected: ?Identity = null;
    var iterator = records.iterator();
    while (iterator.next()) |entry| {
        const record = entry.value_ptr.*;
        if (record.pid == leader) continue;
        const exe_path = try procPath(ctx, record.pid, "exe");
        const executable = readLink(ctx, exe_path) catch continue;
        if (!std.mem.eql(u8, std.fs.path.basename(executable), "test")) continue;
        const stderr_path = try procPath(ctx, record.pid, "fd/2");
        const stderr_stat = std.Io.Dir.cwd().statFile(ctx.io, stderr_path, .{}) catch continue;
        if (stderr_stat.inode != pipe_inode) continue;
        if (selected != null) return error.AmbiguousNativeTestIdentity;
        var identity = record;
        identity.executable = executable;
        identity.args = try procArguments(ctx, record.pid);
        const hash = try shaFile(ctx, exe_path);
        identity.binary_sha256 = try ctx.gpa.dupe(u8, &hash);
        selected = identity;
    }
    const identity = selected orelse return error.MissingNativeTestIdentity;
    if (!sameProcess(ctx, identity)) return error.NativeTestExitedDuringBinding;
    return identity;
}

const BuildIdentity = struct { pid: std.posix.pid_t, start_ticks: u64, arguments_sha256: [32]u8 };

fn captureBuildProcesses(ctx: Context, leader: std.posix.pid_t, seen: *std.ArrayList(BuildIdentity)) !void {
    if (seen.items.len == 64) return;
    var records = try ownedProcesses(ctx, leader);
    defer records.deinit();
    var iterator = records.iterator();
    while (iterator.next()) |item| {
        const record = item.value_ptr.*;
        const exe_path = try procPath(ctx, record.pid, "exe");
        const executable = readLink(ctx, exe_path) catch continue;
        if (!std.mem.eql(u8, std.fs.path.basename(executable), "zig")) continue;
        const cmdline_path = try procPath(ctx, record.pid, "cmdline");
        const raw = readProcFileAlloc(.cwd(), ctx.io, cmdline_path, ctx.gpa, 512 * 1024) catch continue;
        const arguments = try parseArguments(ctx, raw);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
        var exists = false;
        for (seen.items) |prior| if (prior.pid == record.pid and prior.start_ticks == record.start_ticks and std.mem.eql(u8, &prior.arguments_sha256, &digest)) {
            exists = true;
            break;
        };
        if (exists) continue;
        try seen.append(std.heap.page_allocator, .{ .pid = record.pid, .start_ticks = record.start_ticks, .arguments_sha256 = digest });
        var identity = record;
        identity.executable = executable;
        identity.args = arguments;
        try ctx.appendJson(.build_processes, identity);
        if (seen.items.len == 64) break;
    }
}

fn procSample(ctx: Context, identity: Identity) !Identity {
    if (!sameProcess(ctx, identity)) return error.NativeTestExited;
    var record = try statRecord(ctx, identity.pid, "/proc");
    const path = try procPath(ctx, identity.pid, "task");
    var directory = try std.Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true });
    defer directory.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(ctx.io)) |entry| try names.append(ctx.gpa, try ctx.gpa.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var threads: std.ArrayList(Identity) = .empty;
    for (names.items) |name| {
        const pid = std.fmt.parseInt(std.posix.pid_t, name, 10) catch continue;
        var thread = statRecord(ctx, pid, path) catch continue;
        const wchan_path = try std.fs.path.join(ctx.gpa, &.{ path, name, "wchan" });
        const wchan = readProcFileAlloc(.cwd(), ctx.io, wchan_path, ctx.gpa, 65536) catch continue;
        thread.wchan = std.mem.trim(u8, wchan, " \n\r\t");
        try threads.append(ctx.gpa, thread);
        if (threads.items.len == 256) {
            record.threads_capped = true;
            break;
        }
    }
    record.threads = try threads.toOwnedSlice(ctx.gpa);
    return record;
}

fn debuggerArguments(gpa: std.mem.Allocator, prefix: []const []const u8, pid: std.posix.pid_t) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(gpa, prefix);
    try args.appendSlice(gpa, &.{ "--batch", "--nx", "--nh", "-iex", "set auto-load off", "-iex", "set debuginfod enabled off", "-ex", "set pagination off", "-ex", "set confirm off", "-ex", "set print frame-arguments none", "-ex", "set print entry-values no", "-ex" });
    try args.append(gpa, try std.fmt.allocPrint(gpa, "attach {d}", .{pid}));
    try args.appendSlice(gpa, &.{ "-ex", "thread apply all bt 32", "-ex", "detach", "-ex", "quit" });
    return args.toOwnedSlice(gpa);
}

fn debuggerProbe(ctx: Context) ![]const []const u8 {
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    var temporary = ctx;
    temporary.gpa = arena.allocator();
    const debugger = try findExecutable(temporary, "gdb") orelse {
        try ctx.save(.debugger_probe, .{ .available = false, .reason = "gdb absent" });
        return error.DebuggerUnavailable;
    };
    const version = try boundedCommand(temporary, &.{ debugger, "--version" }, 5000, 4096, &.{});
    var child = try OwnedChild.spawn(ctx.io, &.{ "sleep", "30" });
    defer child.closePipe(ctx.io);
    defer child.stop(ctx.io) catch {};
    const identity = try statRecord(ctx, child.pid, "/proc");
    const sudo = try findExecutable(temporary, "sudo");
    var attempts: std.ArrayList(CommandResult) = .empty;
    for (0..if (sudo != null) @as(usize, 2) else 1) |index| {
        const prefix: []const []const u8 = if (index == 0) &.{debugger} else &.{ sudo.?, "-n", debugger };
        const args = try debuggerArguments(temporary.gpa, prefix, child.pid);
        const result = try boundedCommand(temporary, args, 5000, 4096, &.{});
        try attempts.append(temporary.gpa, result);
        if (sameProcess(ctx, identity)) std.posix.kill(child.pid, .CONT) catch {};
        const success = result.exit == 0 and !result.timed_out and std.mem.indexOf(u8, result.output, "#0 ") != null and (std.mem.indexOf(u8, result.output, "detached") != null or std.mem.indexOf(u8, result.output, "Detached") != null);
        if (success) {
            try ctx.save(.debugger_probe, .{ .available = true, .version = version, .attempts = attempts.items });
            const owned = try ctx.gpa.alloc([]const u8, prefix.len);
            for (prefix, owned) |part, *target| target.* = try ctx.gpa.dupe(u8, part);
            return owned;
        }
    }
    try ctx.save(.debugger_probe, .{ .available = false, .version = version, .attempts = attempts.items });
    return error.DebuggerAttachFailed;
}

const SignalGuard = struct {
    term: std.posix.Sigaction,
    interrupt: std.posix.Sigaction,

    fn enter() SignalGuard {
        interrupted_signal.store(0, .release);
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        var result: SignalGuard = undefined;
        std.posix.sigaction(.TERM, &action, &result.term);
        std.posix.sigaction(.INT, &action, &result.interrupt);
        return result;
    }

    fn restore(self: SignalGuard) void {
        std.posix.sigaction(.TERM, &self.term, null);
        std.posix.sigaction(.INT, &self.interrupt, null);
    }
};

const MarkerFramer = struct {
    bytes: [65536]u8 = undefined,
    len: usize = 0,
    oversized: bool = false,

    fn consume(self: *MarkerFramer, block: []const u8) bool {
        var found = false;
        for (block) |byte| {
            if (byte == '\n') {
                if (!self.oversized and std.mem.eql(u8, self.bytes[0..self.len], marker)) found = true;
                self.len = 0;
                self.oversized = false;
            } else if (self.len == self.bytes.len) {
                self.oversized = true;
            } else {
                self.bytes[self.len] = byte;
                self.len += 1;
            }
        }
        return found;
    }
};

const ObserveOptions = struct {
    real_proc: bool = true,
    scan_builds: bool = true,
    install_signals: bool = true,
};

fn fixtureIdentity(pid: std.posix.pid_t) Identity {
    return .{ .pid = pid, .state = "R", .ppid = 0, .user_ticks = 0, .system_ticks = 0, .start_ticks = 0, .rss_pages = 0 };
}

fn observe(ctx: Context, argv: []const []const u8, debugger: ?[]const []const u8, options: ObserveOptions) !void {
    const signals = if (options.install_signals) SignalGuard.enter() else null;
    defer if (signals) |guard| guard.restore();
    var child = try OwnedChild.spawn(ctx.io, argv);
    defer child.closePipe(ctx.io);
    errdefer child.stop(ctx.io) catch {};
    const supervisor = if (options.real_proc) try statRecord(ctx, std.c.getpid(), "/proc") else fixtureIdentity(std.c.getpid());
    const child_identity = if (options.real_proc) try statRecord(ctx, child.pid, "/proc") else fixtureIdentity(child.pid);
    try ctx.save(.state, .{ .supervisor = supervisor, .command = child_identity });
    var target_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer target_arena.deinit();
    var target_ctx = ctx;
    target_ctx.gpa = target_arena.allocator();
    var framer: MarkerFramer = .{};
    var target: ?Identity = null;
    var observed_at: ?i64 = null;
    var next_sample: i64 = 0;
    var captures: usize = 0;
    var ready = false;
    var next_build_scan: i64 = 0;
    var seen_builds: std.ArrayList(BuildIdentity) = .empty;
    defer seen_builds.deinit(std.heap.page_allocator);
    while (child.pipe_open or try child.pollTerm() == null) {
        if (interrupted_signal.load(.acquire) != 0) {
            try child.stop(ctx.io);
            break;
        }
        if (options.scan_builds and observed_at == null and nowMs(ctx.io) >= next_build_scan) {
            var scan_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
            defer scan_arena.deinit();
            var scan_ctx = ctx;
            scan_ctx.gpa = scan_arena.allocator();
            try captureBuildProcesses(scan_ctx, child.pid, &seen_builds);
            next_build_scan = nowMs(ctx.io) + 1000;
        }
        var buffer: [65536]u8 = undefined;
        if (try child.readReady(&buffer, 100)) |block| {
            if (block.len == 0) {
                child.closePipe(ctx.io);
            } else {
                try ctx.append(.run, block);
                if (framer.consume(block) and observed_at == null) {
                    observed_at = nowMs(ctx.io);
                    const pipe_inode = (try child.pipe.stat(ctx.io)).inode;
                    const bound = targetForMarker(target_ctx, child.pid, pipe_inode) catch |err| blk: {
                        try ctx.save(.target_error, .{ .@"error" = @errorName(err) });
                        break :blk null;
                    };
                    if (bound) |identity| {
                        target = identity;
                        try ctx.save(.target, identity);
                        var symbol_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
                        defer symbol_arena.deinit();
                        var symbol_ctx = ctx;
                        symbol_ctx.gpa = symbol_arena.allocator();
                        const result = boundedCommand(symbol_ctx, &.{ "nm", "--no-sort", "--defined-only", identity.executable.? }, 5000, 0, &.{ "__tsan_init", "__tsan_read", "__tsan_write" }) catch |err| blk: {
                            try ctx.save(.target_error, .{ .@"error" = @errorName(err) });
                            break :blk null;
                        };
                        if (result) |value| try ctx.save(.symbol_command, value);
                    }
                }
            }
        } else if (!child.pipe_open) {
            try sleepMs(ctx.io, 10);
        }
        if (observed_at) |started| if (!ready) {
            const elapsed = nowMs(ctx.io) - started;
            if (target) |identity| {
                if (elapsed >= next_sample and elapsed < 120000) {
                    var sample_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
                    defer sample_arena.deinit();
                    var sample_ctx = ctx;
                    sample_ctx.gpa = sample_arena.allocator();
                    const sampled = procSample(sample_ctx, identity) catch |err| blk: {
                        if (err == error.NativeTestExited) {
                            try ctx.appendJson(.proc, .{ .elapsed_seconds = @as(f64, @floatFromInt(elapsed)) / 1000, .elapsed_process = "exited" });
                        } else try ctx.save(.proc_error, .{ .@"error" = @errorName(err) });
                        break :blk null;
                    };
                    if (sampled) |record| try sample_ctx.appendJson(.proc, .{
                        .elapsed_seconds = @as(f64, @floatFromInt(elapsed)) / 1000,
                        .pid = record.pid,
                        .state = record.state,
                        .ppid = record.ppid,
                        .user_ticks = record.user_ticks,
                        .system_ticks = record.system_ticks,
                        .start_ticks = record.start_ticks,
                        .rss_pages = record.rss_pages,
                        .threads = record.threads,
                        .threads_capped = record.threads_capped,
                    });
                    next_sample += 5000;
                }
                const offsets = [_]i64{ 10000, 60000, 110000 };
                if (captures < offsets.len and elapsed >= offsets[captures]) {
                    const record: Record = switch (captures) {
                        0 => .backtrace_1,
                        1 => .backtrace_2,
                        else => .backtrace_3,
                    };
                    if (debugger != null and sameProcess(ctx, identity)) {
                        var capture_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
                        defer capture_arena.deinit();
                        var capture_ctx = ctx;
                        capture_ctx.gpa = capture_arena.allocator();
                        const args = try debuggerArguments(capture_ctx.gpa, debugger.?, identity.pid);
                        const capture = boundedCommand(capture_ctx, args, 5000, 8192, &.{}) catch |err| blk: {
                            try ctx.save(record, .{ .elapsed_seconds = @as(f64, @floatFromInt(elapsed)) / 1000, .available = true, .@"error" = @errorName(err) });
                            break :blk null;
                        };
                        if (sameProcess(ctx, identity)) std.posix.kill(identity.pid, .CONT) catch {};
                        if (capture) |result| try ctx.save(record, .{ .elapsed_seconds = @as(f64, @floatFromInt(elapsed)) / 1000, .available = true, .debugger = result });
                    } else try ctx.save(record, .{ .elapsed_seconds = @as(f64, @floatFromInt(elapsed)) / 1000, .available = debugger != null, .reason = "debugger unavailable or target exited" });
                    captures += 1;
                }
            }
            if (elapsed >= 120000) {
                try ctx.save(.ready, .{ .reason = "observation window complete", .target_bound = target != null });
                ready = true;
            }
        };
    }
    try child.stop(ctx.io);
    const term = child.term orelse return error.ChildStatusMissing;
    const interrupted = interrupted_signal.load(.acquire);
    const values = [_]u32{interrupted};
    try ctx.save(.result, .{ .exit = exitCode(term), .interrupted = values[0..@intFromBool(interrupted != 0)], .target_bound = target != null });
    if (!ready) try ctx.save(.ready, .{ .reason = "command exited", .target_bound = target != null });
}

fn supervise(ctx: Context) !void {
    if (builtin.os.tag != .linux) return error.LinuxProcRequired;
    const signals = SignalGuard.enter();
    defer signals.restore();
    const revision = try boundedCommand(ctx, &.{ "git", "rev-parse", "HEAD" }, 5000, 4096, &.{});
    defer revision.deinit(ctx.gpa);
    const fixture = try shaFile(ctx, "src/fixtures/array-map-canonical-pressure.js");
    const compiler = try boundedCommand(ctx, &.{ "zig", "version" }, 5000, 4096, &.{});
    defer compiler.deinit(ctx.gpa);
    if (revision.exit != 0 or revision.timed_out or !std.mem.eql(u8, std.mem.trim(u8, revision.output, "\r\n \t"), source) or !std.mem.eql(u8, &fixture, fixture_sha256) or compiler.exit != 0 or compiler.timed_out or !std.mem.eql(u8, std.mem.trim(u8, compiler.output, "\r\n \t"), compiler_version)) return error.EngineFixtureOrCompilerMismatch;
    var host: std.c.utsname = undefined;
    if (std.c.uname(&host) != 0) return error.HostIdentityUnavailable;
    // _SC_CLK_TCK is 2 in the Linux libc interface used by this Linux-only mode.
    const ticks = std.c.sysconf(2);
    const page_bytes = std.c.sysconf(@backingInt(std.c._SC.PAGESIZE));
    if (ticks <= 0 or page_bytes <= 0) return error.HostAccountingUnavailable;
    try ctx.save(.manifest, .{
        .diagnostic_only = true,
        .source = std.mem.trim(u8, revision.output, "\r\n \t"),
        .fixture_sha256 = @as([]const u8, &fixture),
        .command = &command,
        .compiler = compiler,
        .host = [_][]const u8{ std.mem.sliceTo(&host.sysname, 0), std.mem.sliceTo(&host.nodename, 0), std.mem.sliceTo(&host.release, 0), std.mem.sliceTo(&host.version, 0), std.mem.sliceTo(&host.machine, 0) },
        .clock_ticks_per_second = ticks,
        .page_bytes = page_bytes,
        .evidence_limit_bytes = 10 * mib,
        .observation_seconds = 120,
        .backtrace_offsets_seconds = [_]u32{ 10, 60, 110 },
        .warning = "External debugger pauses add overhead. This is not elapsed-time qualification.",
    });
    const debugger = try debuggerProbe(ctx);
    defer {
        for (debugger) |part| ctx.gpa.free(part);
        ctx.gpa.free(debugger);
    }
    try observe(ctx, &command, debugger, .{ .install_signals = false });
}

fn echoNew(ctx: Context, offset: *u64) !void {
    const path = try ctx.path(Stream.run.filename());
    defer ctx.gpa.free(path);
    const file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(ctx.io);
    var bytes: [65536]u8 = undefined;
    while (true) {
        const count = try file.readPositional(ctx.io, &.{&bytes}, offset.*);
        if (count == 0) break;
        try std.Io.File.stdout().writeStreamingAll(ctx.io, bytes[0..count]);
        offset.* += count;
    }
}

fn monitor(ctx: Context, collect: bool) !u8 {
    const now = @divTrunc(std.Io.Clock.real.now(ctx.io).toMilliseconds(), 1000);
    const job_started = if (ctx.env) |env| if (env.get("UNIT78_JOB_STARTED_SECONDS")) |value| try std.fmt.parseInt(i64, value, 10) else now else now;
    const deadline = job_started + 2400;
    var offset: u64 = 0;
    while (true) {
        try echoNew(ctx, &offset);
        if (collect and ctx.exists(.ready)) return 0;
        if (ctx.exists(.result)) {
            const bytes = try ctx.read(Record.result.filename(), max_control);
            defer ctx.gpa.free(bytes);
            const result = try std.json.parseFromSlice(struct { exit: i32 }, ctx.gpa, bytes, .{ .ignore_unknown_fields = true });
            defer result.deinit();
            return if (collect) 0 else shellExit(result.value.exit);
        }
        if (ctx.exists(.state)) {
            const bytes = try ctx.read(Record.state.filename(), max_control);
            defer ctx.gpa.free(bytes);
            const state = try std.json.parseFromSlice(struct { supervisor: Identity }, ctx.gpa, bytes, .{ .ignore_unknown_fields = true });
            defer state.deinit();
            if (!sameProcess(ctx, state.value.supervisor)) return error.SupervisorDiedWithoutResult;
        }
        if (collect and @divTrunc(std.Io.Clock.real.now(ctx.io).toMilliseconds(), 1000) >= deadline) {
            try ctx.save(.early_upload, .{ .reason = "40-minute job observation cutoff; original command continues" });
            return 0;
        }
        try sleepMs(ctx.io, 250);
    }
}

fn start(ctx: Context) !void {
    const parent = std.fs.path.dirname(ctx.root) orelse return error.MissingEvidenceParent;
    try std.Io.Dir.cwd().createDirPath(ctx.io, parent);
    try std.Io.Dir.cwd().createDir(ctx.io, ctx.root, .default_dir);
    try ctx.append(.supervisor, "");
    const executable = try std.process.executablePathAlloc(ctx.io, ctx.gpa);
    defer ctx.gpa.free(executable);
    // Expected observer errors are written through the capped log API. A native
    // crash cannot grow a second uncapped stderr artifact or imply child success.
    _ = try std.process.spawn(ctx.io, .{ .argv = &.{ executable, "_supervise", ctx.root }, .pgid = 0, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    for (0..450) |_| {
        if (ctx.exists(.state)) return;
        try sleepMs(ctx.io, 100);
    }
    return error.SupervisorStartupFailed;
}

fn require(condition: bool, label: []const u8) !void {
    if (!condition) {
        std.debug.print("Observer self-test failed: {s}\n", .{label});
        return error.ObserverSelfTestFailed;
    }
}

fn makeSubContext(ctx: Context, name: []const u8) !Context {
    const root = try ctx.path(name);
    errdefer ctx.gpa.free(root);
    try std.Io.Dir.cwd().createDir(ctx.io, root, .default_dir);
    var child = ctx;
    child.root = root;
    return child;
}

fn requireReaped(pid: std.posix.pid_t) !void {
    var status: c_int = 0;
    const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
    try require(result == -1 and std.posix.errno(result) == .CHILD, "timed-out owned child was reaped exactly once");
}

const FixtureStartupStage = enum { lock_create, identity_publish, ready_write };
const FixtureStartupError = struct {
    version: u8 = 1,
    policy: []const u8,
    stage: FixtureStartupStage,
    error_name: []const u8,
    producer_pid: std.posix.pid_t,
    producer_group: ?std.posix.pid_t,

    // This labels diagnostic data only. It never authorizes a signal.
    fn matchesOwnedGroup(self: FixtureStartupError, leader: std.posix.pid_t) bool {
        return if (self.producer_group) |group| group == leader else false;
    }
};

// DEBUG-unit78-linux-readiness: failure-only sideband. Closed-output fixtures
// keep both output handles ignored; this record never authorizes a signal.
fn fixtureStartupError(init: std.process.Init, args: []const []const u8, stage: FixtureStartupStage, failure: anyerror) !void {
    if (args.len != 3) return;
    const policy = std.fs.path.basename(args[1]);
    if (!std.mem.eql(u8, policy, "term-open") and !std.mem.eql(u8, policy, "term-closed") and !std.mem.eql(u8, policy, "exit-closed")) return error.InvalidFixtureDiagnosticPolicy;
    if (!std.mem.eql(u8, std.fs.path.dirname(args[1]) orelse "", std.fs.path.dirname(args[2]) orelse "")) return error.InvalidFixtureDiagnosticPath;
    const group = getpgid(std.c.getpid());
    const record: FixtureStartupError = .{ .policy = policy, .stage = stage, .error_name = @errorName(failure), .producer_pid = std.c.getpid(), .producer_group = if (group >= 0) group else null };
    const bytes = try std.json.Stringify.valueAlloc(init.gpa, record, .{});
    defer init.gpa.free(bytes);
    if (bytes.len >= 2048) return error.FixtureDiagnosticTooLarge;
    const destination = try std.fmt.allocPrint(init.gpa, "{s}.startup-error.json", .{args[2]});
    defer init.gpa.free(destination);
    const temporary = try std.fmt.allocPrint(init.gpa, "{s}.tmp", .{destination});
    defer init.gpa.free(temporary);
    const file = try std.Io.Dir.cwd().createFile(init.io, temporary, .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, bytes);
    try std.Io.Dir.renameAbsolute(temporary, destination, init.io);
}

fn readFixtureDiagnostic(ctx: Context, path: []const u8, limit: usize) ![]u8 {
    if (!std.mem.eql(u8, std.fs.path.dirname(path) orelse "", ctx.root)) return error.InvalidFixtureDiagnosticPath;
    const file = try std.Io.Dir.cwd().openFile(ctx.io, path, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(ctx.io);
    const stat = try file.stat(ctx.io);
    if (stat.kind != .file or stat.nlink != 1) return error.InvalidFixtureDiagnosticFile;
    if (stat.size >= limit) return error.FixtureDiagnosticTooLarge;
    var reader = file.reader(ctx.io, &.{});
    return reader.interface.allocRemaining(ctx.gpa, .limited(limit));
}

fn readFixtureStartupError(ctx: Context, path: []const u8, policy: []const u8) !std.json.Parsed(FixtureStartupError) {
    const raw = try readFixtureDiagnostic(ctx, path, 2048);
    defer ctx.gpa.free(raw);
    const parsed = try std.json.parseFromSlice(FixtureStartupError, ctx.gpa, raw, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != 1 or !std.mem.eql(u8, parsed.value.policy, policy) or parsed.value.producer_pid <= 0) return error.InvalidFixtureDiagnosticIdentity;
    return parsed;
}

const FixtureReadinessStat = struct { attempts: usize = 0, size: ?u64 = null, error_name: ?[]const u8 = null };

fn reportFixtureReadinessFailure(init: std.process.Init, ctx: Context, policy: []const u8, child: *OwnedChild, identity_path: []const u8, last_stat: FixtureReadinessStat) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var diagnostic = ctx;
    diagnostic.gpa = arena.allocator();
    var status_error: ?[]const u8 = null;
    const term = child.pollTerm() catch |err| block: {
        status_error = @errorName(err);
        break :block null;
    };
    var output: [4096]u8 = undefined;
    var output_error: ?[]const u8 = null;
    const captured = child.readReady(&output, 0) catch |err| block: {
        output_error = @errorName(err);
        break :block null;
    };
    const output_bytes: []const u8 = captured orelse &.{};
    var identity_error: ?[]const u8 = null;
    const identity = readFixtureDiagnostic(diagnostic, identity_path, 4096) catch |err| block: {
        identity_error = @errorName(err);
        break :block null;
    };
    var identity_stamp: ?FixtureStamp = null;
    if (identity) |raw| {
        const parsed: ?std.json.Parsed(FixtureStamp) = std.json.parseFromSlice(FixtureStamp, diagnostic.gpa, raw, .{}) catch |err| block: {
            identity_error = @errorName(err);
            break :block null;
        };
        if (parsed) |value| identity_stamp = value.value;
    }
    const sideband_path = try std.fmt.allocPrint(diagnostic.gpa, "{s}.startup-error.json", .{identity_path});
    var startup_error: ?[]const u8 = null;
    const parsed_startup: ?std.json.Parsed(FixtureStartupError) = readFixtureStartupError(diagnostic, sideband_path, policy) catch |err| block: {
        startup_error = @errorName(err);
        break :block null;
    };
    defer if (parsed_startup) |value| value.deinit();
    const startup: ?FixtureStartupError = if (parsed_startup) |value| value.value else null;
    const output_hex = try diagnostic.gpa.alloc(u8, output_bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (output_bytes, 0..) |byte, index| {
        output_hex[index * 2] = alphabet[byte >> 4];
        output_hex[index * 2 + 1] = alphabet[byte & 15];
    }
    const report = .{
        .policy = policy,
        .owned_leader_pid = child.pid,
        .last_lock_stat = last_stat,
        .observed_parent_exit = if (term) |value| @as(?i32, exitCode(value)) else null,
        .waitid_error = status_error,
        .captured_output_hex = output_hex,
        .capture_at_limit = output_bytes.len == output.len,
        .capture_error = output_error,
        .identity_file_bytes = if (identity) |raw| @as(?usize, raw.len) else null,
        .identity_file = identity_stamp,
        .identity_file_error = identity_error,
        .identity_group_matches_owned_leader = if (identity_stamp) |value| value.group == child.pid else false,
        .startup_error = startup,
        .startup_record_error = startup_error,
        .startup_group_matches_owned_leader = if (startup) |value| value.matchesOwnedGroup(child.pid) else false,
    };
    const bytes = try std.json.Stringify.valueAlloc(diagnostic.gpa, report, .{});
    if (bytes.len >= 24576) return error.FixtureDiagnosticTooLarge;
    std.debug.print("[DEBUG-unit78-linux-readiness] {s}\n", .{bytes});
}

fn fixtureMain(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 0) return error.MissingFixtureMode;
    const mode = args[0];
    if (std.mem.eql(u8, mode, "flood")) {
        const block: [4096]u8 = @splat('x');
        var left: usize = 1000000;
        while (left != 0) {
            const take = @min(left, block.len);
            try std.Io.File.stdout().writeStreamingAll(init.io, block[0..take]);
            left -= take;
        }
    } else if (std.mem.eql(u8, mode, "sleep") or std.mem.eql(u8, mode, "silent-sleep")) {
        if (std.mem.eql(u8, mode, "sleep")) try std.Io.File.stdout().writeStreamingAll(init.io, "owned\n");
        try sleepMs(init.io, 30000);
    } else if (std.mem.eql(u8, mode, "stream-exit")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "prefix");
        try std.Io.File.stderr().writeStreamingAll(init.io, "suffix\n");
        std.process.exit(7);
    } else if (std.mem.eql(u8, mode, "signal")) {
        try std.posix.kill(std.c.getpid(), .TERM);
        return error.SignalDidNotTerminate;
    } else if (std.mem.eql(u8, mode, "marker")) {
        try std.Io.File.stderr().writeStreamingAll(init.io, marker ++ "\n");
        try sleepMs(init.io, 30000);
    } else if (std.mem.eql(u8, mode, "resistant-child")) {
        if (args.len != 2 and args.len != 3) return error.MissingFixtureLock;
        const ignored: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.TERM, &ignored, null);
        const file = std.Io.Dir.cwd().createFile(init.io, args[1], .{ .lock = .exclusive }) catch |err| {
            fixtureStartupError(init, args, .lock_create, err) catch {};
            return err;
        };
        defer file.close(init.io);
        if (args.len == 3) writeFixtureStamp(init, args[2]) catch |err| {
            fixtureStartupError(init, args, .identity_publish, err) catch {};
            return err;
        };
        file.writeStreamingAll(init.io, "ready\n") catch |err| {
            fixtureStartupError(init, args, .ready_write, err) catch {};
            return err;
        };
        try sleepMs(init.io, 30000);
    } else if (std.mem.eql(u8, mode, "resistant-parent")) {
        if (args.len != 4 and args.len != 5) return error.MissingFixtureLock;
        const closed = !std.mem.eql(u8, args[3], "term-open");
        const child_args: []const []const u8 = if (args.len == 5) &.{ args[1], "_fixture", "resistant-child", args[2], args[4] } else &.{ args[1], "_fixture", "resistant-child", args[2] };
        var child = try std.process.spawn(init.io, .{ .argv = child_args, .stdin = .ignore, .stdout = if (closed) .ignore else .inherit, .stderr = if (closed) .ignore else .inherit });
        if (std.mem.eql(u8, args[3], "exit-closed")) {
            const until = nowMs(init.io) + 5000;
            while (true) {
                const ready = std.Io.Dir.cwd().statFile(init.io, args[2], .{}) catch null;
                if (ready) |stat| if (stat.size != 0) break;
                if (nowMs(init.io) >= until) return error.ResistantFixtureNotReady;
                try sleepMs(init.io, 10);
            }
            std.process.exit(7);
        }
        _ = try child.wait(init.io);
    } else if (std.mem.eql(u8, mode, "nested-marker") or std.mem.eql(u8, mode, "nested-marker-pair")) {
        if (args.len != 2) return error.MissingFixtureExecutable;
        var first = try std.process.spawn(init.io, .{ .argv = &.{ args[1], "_fixture", "marker" }, .stdin = .ignore });
        if (std.mem.eql(u8, mode, "nested-marker-pair")) {
            var second = try std.process.spawn(init.io, .{ .argv = &.{ args[1], "_fixture", "marker" }, .stdin = .ignore });
            _ = try second.wait(init.io);
        }
        _ = try first.wait(init.io);
    } else return error.UnknownFixtureMode;
}

fn waitForMarkers(ctx: Context, child: *OwnedChild, wanted: usize) !void {
    const until = nowMs(ctx.io) + 5000;
    var count: usize = 0;
    var framer: MarkerFramer = .{};
    while (nowMs(ctx.io) < until) {
        var bytes: [4096]u8 = undefined;
        if (try child.readReady(&bytes, 100)) |block| {
            for (block) |byte| if (framer.consume(&.{byte})) {
                count += 1;
            };
            if (count == wanted) return;
            if (block.len == 0) break;
        }
    }
    return error.FixtureMarkerMissing;
}

const SelfTestCounts = struct { portable: usize, linux: usize };

fn selfTest(init: std.process.Init) !void {
    var random: [16]u8 = undefined;
    std.Io.random(init.io, &random);
    const root = try std.fmt.allocPrint(init.gpa, "/tmp/zig-js-unit78-observer-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer init.gpa.free(root);
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    errdefer std.Io.Dir.cwd().deleteTree(init.io, root) catch |err| std.debug.print("Observer self-test cleanup failed: {s}\n", .{@errorName(err)});
    const ctx: Context = .{ .gpa = init.gpa, .io = init.io, .root = root, .env = init.environ_map };
    const executable = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(executable);
    const counts = try selfTestBody(init, ctx, executable);
    try std.Io.Dir.cwd().deleteTree(init.io, root);
    std.debug.print("Observer self-test passed: portable={d}, Linux={d}, Linux-only excluded={d}. Parser/cap unit tests run separately.\n", .{ counts.portable, counts.linux, if (builtin.os.tag == .linux) @as(usize, 0) else 3 });
}

fn selfTestBody(init: std.process.Init, ctx: Context, executable: []const u8) !SelfTestCounts {
    var portable: usize = 0;
    var linux: usize = 0;

    for ([_][]const u8{ "term-open", "term-closed", "exit-closed" }) |policy| {
        const lock_path = try ctx.path(policy);
        defer init.gpa.free(lock_path);
        var sentinel = try OwnedChild.spawn(init.io, &.{ executable, "_fixture", "silent-sleep" });
        defer sentinel.closePipe(init.io);
        defer sentinel.stop(init.io) catch {};
        const identity_path = try ctx.path("descendant-identity.json");
        defer init.gpa.free(identity_path);
        var child = try OwnedChild.spawn(init.io, &.{ executable, "_fixture", "resistant-parent", executable, lock_path, policy, identity_path });
        defer child.closePipe(init.io);
        defer child.stop(init.io) catch {};
        const until = nowMs(init.io) + 5000;
        var last_stat: FixtureReadinessStat = .{};
        while (true) {
            last_stat.attempts += 1;
            const ready = std.Io.Dir.cwd().statFile(init.io, lock_path, .{}) catch |err| block: {
                last_stat.size = null;
                last_stat.error_name = @errorName(err);
                break :block null;
            };
            if (ready) |stat| {
                last_stat.size = stat.size;
                last_stat.error_name = null;
                if (stat.size != 0) break;
            }
            if (nowMs(init.io) >= until) {
                reportFixtureReadinessFailure(init, ctx, policy, &child, identity_path, last_stat) catch |err| std.debug.print("[DEBUG-unit78-linux-readiness] report failed: {s}\n", .{@errorName(err)});
                return error.ResistantFixtureNotReady;
            }
            try sleepMs(init.io, 10);
        }
        const lock_file = try std.Io.Dir.cwd().openFile(init.io, lock_path, .{ .mode = .read_write });
        defer lock_file.close(init.io);
        try require(!try lock_file.tryLock(init.io, .exclusive), "resistant descendant owns the actual kernel lock");
        const stamp_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, identity_path, init.gpa, .limited(4096));
        defer init.gpa.free(stamp_bytes);
        const parsed_stamp = try std.json.parseFromSlice(FixtureStamp, init.gpa, stamp_bytes, .{});
        defer parsed_stamp.deinit();
        const stamp = parsed_stamp.value;
        const current = try processStamp(ctx, stamp.pid);
        try require(sameFixtureStamp(stamp, current) and current.group == child.pid, "ready-time descendant PID/start/group identity");
        if (std.mem.eql(u8, policy, "exit-closed")) {
            const exited_until = nowMs(init.io) + 5000;
            while (try child.pollTerm() == null) {
                if (nowMs(init.io) >= exited_until) return error.ResistantLeaderDidNotExit;
                try sleepMs(init.io, 10);
            }
            var bytes: [16]u8 = undefined;
            const end = try child.readReady(&bytes, 100);
            try require(end != null and end.?.len == 0, "natural leader exit and closed descendant reach pipe EOF");
            child.closePipe(init.io);
            try require(exitCode(child.term.?) == 7, "original leader exit observed before cleanup");
            if (builtin.os.tag.isDarwin()) {
                const lookup = try lookupDarwinMember(child.pid);
                try require(lookup.returned == @sizeOf(DarwinProcess.Info) and lookup.info != null, "native exit-aware shortBSD lookup retains the unreaped leader");
                const info = lookup.info.?;
                try require(info.pid == @as(u32, @intCast(child.pid)) and info.group == @as(u32, @intCast(child.pid)) and info.status == 5, "native shortBSD arg1 exposes completed zombie PID/group/status");
            }
        }
        try child.stop(init.io);
        const released = try lock_file.tryLock(init.io, .exclusive);
        if (!released) {
            // Preserve the strict verdict. A lock does not authorize a group
            // signal after reaping; cleanup only a revalidated fixture PID.
            if (processStamp(ctx, stamp.pid)) |remaining| {
                if (sameFixtureStamp(stamp, remaining) and remaining.status != 5) {
                    std.posix.kill(remaining.pid, .KILL) catch |err| std.debug.print("Fixture cleanup signal failed: {s}\n", .{@errorName(err)});
                }
            } else |_| {}
        }
        try require(try sentinel.pollTerm() == null, "resistant group cleanup preserves unrelated sentinel");
        try requireReaped(child.pid);
        try require(released, "owned TERM-resistant descendant is terminated before stop returns");
        if (std.mem.eql(u8, policy, "exit-closed")) try require(exitCode(child.term.?) == 7, "group cleanup preserves already-observed original exit7");
        portable += 1;
    }

    {
        const bytes = try init.gpa.alloc(u8, 7 * mib);
        defer init.gpa.free(bytes);
        @memset(bytes, 'x');
        try ctx.append(.run, bytes);
        const path = try ctx.path(Stream.run.filename());
        defer init.gpa.free(path);
        try require((try std.Io.Dir.cwd().statFile(init.io, path, .{})).size == max_stream, "raw stream cap");
        try ctx.save(.manifest, .{ .safe = true });
        if (ctx.save(.manifest, .{ .oversized = bytes })) |_| return error.ControlLimitNotEnforced else |err| try require(err == error.ControlRecordTooLarge, "control record limit error identity");
        const saved = try ctx.read(Record.manifest.filename(), max_control);
        defer init.gpa.free(saved);
        const parsed = try std.json.parseFromSlice(struct { safe: bool }, init.gpa, saved, .{});
        defer parsed.deinit();
        try require(parsed.value.safe, "atomic record preserves previous value on rejection");
        const total = 6 * mib + mib + mib / 2 + 65536 + (std.meta.tags(Record).len + 1) * max_control;
        try require(total < 10 * mib, "complete fixed evidence inventory remains below10MiB");
        portable += 1;
    }
    {
        const result = try boundedCommand(ctx, &.{ executable, "_fixture", "sleep" }, 200, 4096, &.{});
        defer result.deinit(init.gpa);
        try require(result.timed_out and result.exit != 0 and std.mem.eql(u8, result.output, "owned\n"), "actual sleeping child times out with retained bytes");
        try requireReaped(result.pid);
        portable += 1;
    }
    {
        const result = try boundedCommand(ctx, &.{ executable, "_fixture", "flood" }, 5000, 99, &.{"xxxxx"});
        defer result.deinit(init.gpa);
        try require(result.exit == 0 and result.output.len == 99 and result.output_capped and result.witnesses.len == 1, "flood is drained beyond output cap and witnesses remain observable");
        portable += 1;
    }
    {
        var sentinel = try OwnedChild.spawn(init.io, &.{ executable, "_fixture", "silent-sleep" });
        defer sentinel.closePipe(init.io);
        defer sentinel.stop(init.io) catch {};
        const result = try boundedCommand(ctx, &.{ executable, "_fixture", "silent-sleep" }, 100, 99, &.{});
        defer result.deinit(init.gpa);
        try require(result.timed_out and try sentinel.pollTerm() == null, "cleanup leaves unrelated owned sentinel alive");
        try requireReaped(result.pid);
        portable += 1;
    }
    {
        const stream = try makeSubContext(ctx, "stream");
        defer init.gpa.free(stream.root);
        try observe(stream, &.{ executable, "_fixture", "stream-exit" }, null, .{ .real_proc = false, .scan_builds = false });
        const bytes = try stream.read(Stream.run.filename(), 128);
        defer init.gpa.free(bytes);
        try require(std.mem.eql(u8, bytes, "prefixsuffix\n"), "merged streams preserve bytes and ordering");
        try require(try monitor(stream, false) == 7, "collector propagates original exit7");
        portable += 1;
    }
    {
        const killed = try makeSubContext(ctx, "killed");
        defer init.gpa.free(killed.root);
        try observe(killed, &.{ executable, "_fixture", "signal" }, null, .{ .real_proc = false, .scan_builds = false });
        try require(try monitor(killed, false) == 128 + @backingInt(std.posix.SIG.TERM), "collector propagates actual TERM failure");
        portable += 1;
    }
    if (builtin.os.tag == .linux) {
        const fixture_exe = try ctx.path("test");
        defer init.gpa.free(fixture_exe);
        // This is only the harmless observer fixture executable, never an
        // engine/runtime copy or a substitute for the original test binary.
        try std.Io.Dir.copyFileAbsolute(executable, fixture_exe, init.io, .{ .replace = false });
        {
            var child = try OwnedChild.spawn(init.io, &.{ executable, "_fixture", "nested-marker", fixture_exe });
            defer child.closePipe(init.io);
            defer child.stop(init.io) catch {};
            try waitForMarkers(ctx, &child, 1);
            var arena: std.heap.ArenaAllocator = .init(init.gpa);
            defer arena.deinit();
            var child_ctx = ctx;
            child_ctx.gpa = arena.allocator();
            const inode = (try child.pipe.stat(init.io)).inode;
            const identity = try targetForMarker(child_ctx, child.pid, inode);
            try require(identity.pid != child.pid and sameProcess(child_ctx, identity), "actual descendant and stderr pipe bind uniquely");
            var stale = identity;
            stale.start_ticks += 1;
            try require(!sameProcess(child_ctx, stale), "start-tick mismatch refuses stale PID identity");
            if (targetForMarker(child_ctx, child.pid, inode + 1)) |_| return error.PipeIdentityNotEnforced else |err| try require(err == error.MissingNativeTestIdentity, "wrong stderr pipe rejected");
            linux += 1;
        }
        {
            var child = try OwnedChild.spawn(init.io, &.{ executable, "_fixture", "nested-marker-pair", fixture_exe });
            defer child.closePipe(init.io);
            defer child.stop(init.io) catch {};
            try waitForMarkers(ctx, &child, 2);
            var arena: std.heap.ArenaAllocator = .init(init.gpa);
            defer arena.deinit();
            var child_ctx = ctx;
            child_ctx.gpa = arena.allocator();
            if (targetForMarker(child_ctx, child.pid, (try child.pipe.stat(init.io)).inode)) |_| return error.AmbiguityNotEnforced else |err| try require(err == error.AmbiguousNativeTestIdentity, "two actual native descendants are not guessed");
            linux += 1;
        }
        {
            const dead = try makeSubContext(ctx, "dead-supervisor");
            defer init.gpa.free(dead.root);
            try dead.save(.state, .{ .supervisor = fixtureIdentity(std.math.maxInt(std.posix.pid_t)) });
            if (monitor(dead, false)) |_| return error.MissingSupervisorAccepted else |err| try require(err == error.SupervisorDiedWithoutResult, "dead supervisor never yields false original success");
            linux += 1;
        }
    }
    return .{ .portable = portable, .linux = linux };
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) return error.MissingMode;
    if (std.mem.eql(u8, argv[1], "_fixture")) return fixtureMain(init, argv[2..]);
    if (std.mem.eql(u8, argv[1], "self-test")) {
        if (argv.len != 2) return error.UnexpectedArgument;
        return selfTest(init);
    }
    if (argv.len != 3) return error.ExpectedEvidenceDirectory;
    const current = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(current);
    const root = try std.fs.path.resolve(init.gpa, &.{ current, argv[2] });
    defer init.gpa.free(root);
    const ctx: Context = .{ .gpa = init.gpa, .io = init.io, .root = root, .env = init.environ_map };
    const mode = argv[1];
    if (std.mem.eql(u8, mode, "start")) return start(ctx);
    if (std.mem.eql(u8, mode, "_supervise")) {
        supervise(ctx) catch |err| {
            const line = try std.fmt.allocPrint(init.gpa, "observer failed: {s}\n", .{@errorName(err)});
            defer init.gpa.free(line);
            try ctx.append(.supervisor, line);
            return err;
        };
        return;
    }
    if (std.mem.eql(u8, mode, "collect") or std.mem.eql(u8, mode, "wait")) std.process.exit(try monitor(ctx, std.mem.eql(u8, mode, "collect")));
    return error.UnknownMode;
}

test "native observer: reader regression bounded reader accepts an empty file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    const bytes = try readProcFileAlloc(tmp.dir, std.testing.io, "empty", std.testing.allocator, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "native observer: reader regression bounded reader preserves bytes across growth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const short = "a\x00b\xff\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "short", .data = short });
    const short_read = try readProcFileAlloc(tmp.dir, std.testing.io, "short", std.testing.allocator, 16);
    defer std.testing.allocator.free(short_read);
    try std.testing.expectEqualSlices(u8, short, short_read);
    var payload: [4097]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "growing", .data = &payload });
    const growing = try readProcFileAlloc(tmp.dir, std.testing.io, "growing", std.testing.allocator, payload.len + 1);
    defer std.testing.allocator.free(growing);
    try std.testing.expectEqualSlices(u8, &payload, growing);
}

test "native observer: reader regression bounded reader rejects reached or exceeded caps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const limit = 257;
    const payload: [limit + 1]u8 = @splat('x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "below", .data = payload[0 .. limit - 1] });
    const below = try readProcFileAlloc(tmp.dir, std.testing.io, "below", std.testing.allocator, limit);
    defer std.testing.allocator.free(below);
    try std.testing.expectEqualSlices(u8, payload[0 .. limit - 1], below);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "at", .data = payload[0..limit] });
    try std.testing.expectError(error.StreamTooLong, readProcFileAlloc(tmp.dir, std.testing.io, "at", std.testing.allocator, limit));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "above", .data = &payload });
    try std.testing.expectError(error.StreamTooLong, readProcFileAlloc(tmp.dir, std.testing.io, "above", std.testing.allocator, limit));
}

test "native observer: reader regression bounded reader preserves missing-file errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, readProcFileAlloc(tmp.dir, std.testing.io, "missing", std.testing.allocator, 16));
}

test "native observer: reader regression hashes an empty file through EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .root = root };
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "empty", .data = "" });
    const path = try ctx.path("empty");
    defer gpa.free(path);
    const digest = try shaFile(ctx, path);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &digest);
}

test "native observer: reader regression hashes abc through EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .root = root };
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "abc", .data = "abc" });
    const path = try ctx.path("abc");
    defer gpa.free(path);
    const digest = try shaFile(ctx, path);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &digest);
}

test "native observer: reader regression reads live Linux stat identity" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: Context = .{ .gpa = arena.allocator(), .io = std.testing.io, .root = "." };
    const pid = std.c.getpid();
    const identity = try statRecord(ctx, pid, "/proc");
    try std.testing.expectEqual(pid, identity.pid);
    try std.testing.expectEqual(std.c.getppid(), identity.ppid);
    try std.testing.expect(identity.start_ticks > 0);
    try std.testing.expect(sameProcess(ctx, identity));
}

test "native observer: reader regression reads live Linux command arguments" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: Context = .{ .gpa = arena.allocator(), .io = std.testing.io, .root = "." };
    const arguments = try procArguments(ctx, std.c.getpid());
    try std.testing.expect(arguments.len > 0);
    try std.testing.expect(arguments[0].len > 0);
    const executable = try std.process.executablePathAlloc(ctx.io, ctx.gpa);
    try std.testing.expectEqualStrings(std.fs.path.basename(executable), std.fs.path.basename(arguments[0]));
    for (arguments) |argument| try std.testing.expect(std.mem.indexOfScalar(u8, argument, 0) == null);
}

test "native observer: reader regression samples live Linux task records" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: Context = .{ .gpa = arena.allocator(), .io = std.testing.io, .root = "." };
    const pid = std.c.getpid();
    const identity = try statRecord(ctx, pid, "/proc");
    const sample = try procSample(ctx, identity);
    try std.testing.expectEqual(pid, sample.pid);
    try std.testing.expectEqual(identity.start_ticks, sample.start_ticks);
    const threads = sample.threads orelse return error.MissingLiveProcThreads;
    try std.testing.expect(threads.len > 0);
    var found_main = false;
    for (threads) |thread| {
        try std.testing.expect(thread.start_ticks > 0);
        const wchan = thread.wchan orelse return error.MissingLiveProcWchan;
        try std.testing.expect(wchan.len > 0);
        if (thread.pid == pid) found_main = true;
    }
    try std.testing.expect(found_main);
}

test "native observer: captured Darwin exit states cannot become false group completion" {
    // The attributed failure listed group44367 and returned SRCH while PID44371
    // still had status2/INEXIT flags16404 and held its original kernel lock.
    const group: std.posix.pid_t = 44367;
    const missing: DarwinMemberLookup = .{ .returned = 0, .info = null };
    try std.testing.expectEqual(GroupState.pending, classifyDarwinMember(group, missing));
    var info: DarwinProcess.Info = undefined;
    @memset(std.mem.asBytes(&info), 0);
    info.pid = 44371;
    info.group = 44367;
    info.status = 2;
    info.flags = 16404;
    try std.testing.expectEqual(GroupState.pending, classifyDarwinMember(group, .{ .returned = 64, .info = info }));
    info.status = 5;
    try std.testing.expectEqual(GroupState.complete, classifyDarwinMember(group, .{ .returned = 64, .info = info }));
    info.status = 2;
    info.flags = 0;
    const runnable = classifyDarwinMember(group, .{ .returned = 64, .info = info });
    try std.testing.expectEqual(GroupState.signalable, runnable);
    try std.testing.expectEqual(GroupState.signalable, mergeGroupState(.pending, runnable));
    try std.testing.expectEqual(GroupState.signalable, mergeGroupState(runnable, .pending));
    try std.testing.expectEqual(GroupState.pending, mergeGroupState(.complete, .pending));
    try std.testing.expectEqual(GroupState.complete, mergeGroupState(.complete, .complete));
    info.group = 99999;
    try std.testing.expectEqual(GroupState.complete, classifyDarwinMember(group, .{ .returned = 64, .info = info }));
}

test "native observer: proc stat accepts parenthesis inside process names" {
    const value = try parseStat(123, "123 (a strange ) name) S 1 0 0 0 0 0 0 0 0 0 12 13 0 0 0 0 0 0 19 0 21");
    try std.testing.expectEqual(@as(u64, 19), value.start_ticks);
    try std.testing.expectEqual(@as(u64, 12), value.user_ticks);
    try std.testing.expectEqual(@as(i64, 21), value.rss_pages);
    try std.testing.expectError(error.MalformedProcStat, parseStat(123, "123 missing fields"));
}

test "native observer: exit and invalid UTF8 dispositions remain explicit" {
    try std.testing.expectEqual(@as(u8, 7), shellExit(7));
    try std.testing.expectEqual(@as(u8, 143), shellExit(-15));
    const encoded = try safeUtf8(std.testing.allocator, "a\xffb");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a\xef\xbf\xbdb", encoded);
}

test "native observer: complete marker framing rejects partial and oversized lines" {
    var framer: MarkerFramer = .{};
    try std.testing.expect(!framer.consume(marker[0..17]));
    try std.testing.expect(framer.consume(marker[17..] ++ "\n"));
    try std.testing.expect(!framer.consume("prefix" ++ marker ++ "\n"));
    const huge = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    try std.testing.expect(!framer.consume(huge));
    try std.testing.expect(!framer.consume(marker ++ "\n"));
    try std.testing.expect(framer.consume(marker ++ "\n"));
}

test "native observer: startup diagnostics own returned strings and label group mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .root = root };
    const cases = [_]struct { name: []const u8, raw: []const u8, matches: bool }{
        .{ .name = "owned.json", .raw = "{\"version\":1,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":123,\"producer_group\":321}", .matches = true },
        .{ .name = "unrelated.json", .raw = "{\"version\":1,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":123,\"producer_group\":999}", .matches = false },
        .{ .name = "no-group.json", .raw = "{\"version\":1,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":123,\"producer_group\":null}", .matches = false },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(ctx.io, .{ .sub_path = case.name, .data = case.raw });
        const path = try std.fs.path.join(gpa, &.{ root, case.name });
        defer gpa.free(path);
        const parsed = try readFixtureStartupError(ctx, path, "term-closed");
        defer parsed.deinit();
        // readFixtureStartupError has already freed its raw file buffer.
        try std.testing.expectEqualStrings("term-closed", parsed.value.policy);
        try std.testing.expectEqualStrings("IsDir", parsed.value.error_name);
        try std.testing.expectEqual(@as(std.posix.pid_t, 123), parsed.value.producer_pid);
        try std.testing.expectEqual(case.matches, parsed.value.matchesOwnedGroup(321));
    }
}

test "native observer: startup diagnostic reader enforces actual file ownership and cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .root = root };
    const raw = "{\"version\":1,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":123,\"producer_group\":321}";
    const missing = try std.fs.path.join(gpa, &.{ root, "missing.json" });
    defer gpa.free(missing);
    try std.testing.expectError(error.FileNotFound, readFixtureStartupError(ctx, missing, "term-closed"));
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "valid.json", .data = raw });
    try tmp.dir.symLink(ctx.io, "valid.json", "symbolic.json", .{});
    const symbolic = try std.fs.path.join(gpa, &.{ root, "symbolic.json" });
    defer gpa.free(symbolic);
    try std.testing.expectError(error.SymLinkLoop, readFixtureStartupError(ctx, symbolic, "term-closed"));
    try std.Io.Dir.hardLink(tmp.dir, "valid.json", tmp.dir, "hard.json", ctx.io, .{});
    const hard = try std.fs.path.join(gpa, &.{ root, "hard.json" });
    defer gpa.free(hard);
    try std.testing.expectError(error.InvalidFixtureDiagnosticFile, readFixtureStartupError(ctx, hard, "term-closed"));
    const oversized: [2048]u8 = @splat(' ');
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "oversized.json", .data = &oversized });
    const oversized_path = try std.fs.path.join(gpa, &.{ root, "oversized.json" });
    defer gpa.free(oversized_path);
    try std.testing.expectError(error.FixtureDiagnosticTooLarge, readFixtureStartupError(ctx, oversized_path, "term-closed"));
    var below_cap: [2047]u8 = @splat(' ');
    @memcpy(below_cap[0..raw.len], raw);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "below-cap.json", .data = &below_cap });
    const below_cap_path = try std.fs.path.join(gpa, &.{ root, "below-cap.json" });
    defer gpa.free(below_cap_path);
    const accepted = try readFixtureStartupError(ctx, below_cap_path, "term-closed");
    defer accepted.deinit();
    try std.testing.expectEqualStrings("IsDir", accepted.value.error_name);
    try tmp.dir.createDir(ctx.io, "other", .default_dir);
    try tmp.dir.writeFile(ctx.io, .{ .sub_path = "other/outside.json", .data = raw });
    const outside = try std.fs.path.join(gpa, &.{ root, "other/outside.json" });
    defer gpa.free(outside);
    try std.testing.expectError(error.InvalidFixtureDiagnosticPath, readFixtureStartupError(ctx, outside, "term-closed"));
}

test "native observer: startup schema rejects actual malformed and mismatched records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(root);
    const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .root = root };
    const cases = [_]struct { name: []const u8, raw: []const u8, expected: anyerror }{
        .{ .name = "malformed.json", .raw = "{", .expected = error.UnexpectedEndOfInput },
        .{ .name = "version.json", .raw = "{\"version\":2,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":123,\"producer_group\":321}", .expected = error.InvalidFixtureDiagnosticIdentity },
        .{ .name = "policy.json", .raw = "{\"version\":1,\"policy\":\"term-open\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":123,\"producer_group\":321}", .expected = error.InvalidFixtureDiagnosticIdentity },
        .{ .name = "zero-pid.json", .raw = "{\"version\":1,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":0,\"producer_group\":321}", .expected = error.InvalidFixtureDiagnosticIdentity },
        .{ .name = "negative-pid.json", .raw = "{\"version\":1,\"policy\":\"term-closed\",\"stage\":\"identity_publish\",\"error_name\":\"IsDir\",\"producer_pid\":-1,\"producer_group\":321}", .expected = error.InvalidFixtureDiagnosticIdentity },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(ctx.io, .{ .sub_path = case.name, .data = case.raw });
        const path = try std.fs.path.join(gpa, &.{ root, case.name });
        defer gpa.free(path);
        try std.testing.expectError(case.expected, readFixtureStartupError(ctx, path, "term-closed"));
    }
}
