//! Script code cache: the parsed tree of a script, stored in a file named by a
//! digest of the script's exact source, so a later evaluation of the same
//! source (the next launch of an app evaluating the same bundle) builds its
//! tree from the file instead of lexing and parsing the text again.
//!
//! An entry is reused only when every part of its identity matches:
//!   - the format version and a fingerprint of the tree's type layout, so an
//!     engine whose AST changed shape never reads an older layout;
//!   - the identity (path, size, mtime, inode) of the running executable, so
//!     any rebuilt binary, whose parser may produce different trees for the
//!     same text, starts from a cold cache;
//!   - the source's length and full SHA-256 digest;
//!   - a checksum over the payload, against torn or corrupted files.
//! Decoding is bounds-checked throughout (offsets stay inside the source, tags
//! name real variants, references name earlier objects of the same type), and
//! any mismatch is a miss: the entry is removed and the script parses as if
//! there were no cache. A miss after a successful parse writes a fresh entry,
//! atomically (temporary file, then rename), so a concurrent reader sees either
//! the old entry, the new one, or none.
//!
//! The cache directory must be private to the embedding application, as for
//! any code cache: an entry is trusted to describe a tree the parser produced.
//!
//! Only parse results are cached. The tree is serialized right after parsing,
//! before execution: evaluation may later bake one-time values into the tree.

const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const stack_scan = @import("stack_scan.zig");

const Node = ast.Node;
const StatementLocation = parser_mod.StatementLocation;

/// Raise when the encoding changes without a change to the AST types.
pub const format_version: u32 = 1;

/// Scripts shorter than this parse faster than a cache file is opened.
pub const min_source_len: usize = 32 * 1024;

const magic = "ZJSAST\x00\x01".*;
const extension = ".zjsast";

/// What a parse produces that evaluation needs afterwards.
pub const Parsed = struct {
    program: *Node,
    statement_locations: []const StatementLocation,
    strict: bool,
};

const Header = extern struct {
    magic: [8]u8,
    format_version: u32,
    reserved: u32,
    fingerprint: u64,
    executable: u64,
    source_len: u64,
    source_digest: [32]u8,
    payload_len: u64,
    payload_checksum: u64,
};

pub const Digest = [32]u8;

pub fn digestSource(source: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return digest;
}

/// `<dir>/<first 16 digest bytes in hex>.zjsast`.
fn entryPath(buf: []u8, dir: []const u8, digest: *const Digest) ?[]const u8 {
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return std.fmt.bufPrint(buf, "{s}/{s}" ++ extension, .{ dir, &hex }) catch null;
}

// ---- identity ---------------------------------------------------------------

/// A fingerprint of every type the encoding walks: field names, field types,
/// enum values, in declaration order. Anonymous struct names vary between
/// compilations, so structures are described by their fields, never names;
/// pointers name their (named) pointee, whose layout `pointee_types` lists.
const type_fingerprint: u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var text: []const u8 = std.fmt.comptimePrint("v{d};", .{format_version});
    for (pointee_types) |T| text = text ++ @typeName(T) ++ "=" ++ signature(T, false) ++ ";";
    text = text ++ signature(StatementLocation, false);
    break :blk std.hash.Wyhash.hash(0x5a4a_5343_4153_5400, text);
};

const pointee_types = [_]type{ Node, ast.FunctionNode, ast.TryNode, ast.ExportNode };

fn pointeeIndex(comptime T: type) u32 {
    inline for (pointee_types, 0..) |P, index| if (P == T) return index;
    @compileError("script cache: unexpected pointee type " ++ @typeName(T));
}

fn signature(comptime T: type, comptime by_name: bool) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "b",
        .void => "v",
        .int => |info| std.fmt.comptimePrint("{c}{d}", .{ if (info.signedness == .signed) 'i' else 'u', info.bits }),
        .float => |info| std.fmt.comptimePrint("f{d}", .{info.bits}),
        .optional => |info| "?" ++ signature(info.child, true),
        .pointer => |info| switch (info.size) {
            .one => "*" ++ @typeName(info.child),
            .slice => "[]" ++ signature(info.child, true),
            else => @compileError("script cache: unsupported pointer in " ++ @typeName(T)),
        },
        .@"enum" => |info| blk: {
            var text: []const u8 = "e{";
            for (info.field_names, info.field_values) |name, tag| text = text ++ name ++ std.fmt.comptimePrint("={d},", .{tag});
            break :blk text ++ "}";
        },
        .@"struct" => |info| blk: {
            if (by_name and isPointee(T)) break :blk @typeName(T);
            var text: []const u8 = "s{";
            for (info.field_names, info.field_types) |name, Field| text = text ++ name ++ ":" ++ signature(Field, true) ++ ",";
            break :blk text ++ "}";
        },
        .@"union" => |info| blk: {
            if (by_name and isPointee(T)) break :blk @typeName(T);
            var text: []const u8 = "u{";
            for (info.field_names, info.field_types) |name, Field| text = text ++ name ++ ":" ++ signature(Field, true) ++ ",";
            break :blk text ++ "}";
        },
        else => @compileError("script cache: unsupported type " ++ @typeName(T)),
    };
}

fn isPointee(comptime T: type) bool {
    for (pointee_types) |P| if (P == T) return true;
    return false;
}

var executable_identity = std.atomic.Value(u64).init(0);

/// The running executable's path, size, mtime and inode, hashed once per
/// process. Zero when it cannot be determined, which disables the cache.
pub fn executableIdentity(io: std.Io) u64 {
    const known = executable_identity.load(.acquire);
    if (known != 0) return known;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.process.executablePath(io, &path_buf) catch return 0;
    const path = path_buf[0..len];
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    var hasher = std.hash.Wyhash.init(0x6578_6563_7574_6162);
    hasher.update(path);
    hasher.update(std.mem.asBytes(&stat.size));
    const mtime: i128 = stat.mtime.nanoseconds;
    hasher.update(std.mem.asBytes(&mtime));
    const inode: u64 = @intCast(stat.inode);
    hasher.update(std.mem.asBytes(&inode));
    const identity = hasher.final() | 1;
    executable_identity.store(identity, .release);
    return identity;
}

// ---- encoding ---------------------------------------------------------------

const EncodeError = error{ OutOfMemory, TooDeep };

const Encoder = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator,
    source: []const u8,
    ids: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    next_id: u32 = 0,
    stack_floor: usize,

    fn deinit(self: *Encoder) void {
        self.out.deinit(self.gpa);
        self.ids.deinit(self.gpa);
    }

    fn varint(self: *Encoder, raw: u64) EncodeError!void {
        var rest = raw;
        while (rest >= 0x80) : (rest >>= 7) try self.out.append(self.gpa, @as(u8, @truncate(rest)) | 0x80);
        try self.out.append(self.gpa, @truncate(rest));
    }

    fn string(self: *Encoder, text: []const u8) EncodeError!void {
        if (text.len == 0) return self.out.append(self.gpa, 2);
        const base = @intFromPtr(self.source.ptr);
        const at = @intFromPtr(text.ptr);
        if (at >= base and at + text.len <= base + self.source.len) {
            try self.out.append(self.gpa, 0);
            try self.varint(at - base);
            try self.varint(text.len);
        } else {
            try self.out.append(self.gpa, 1);
            try self.varint(text.len);
            try self.out.appendSlice(self.gpa, text);
        }
    }

    fn value(self: *Encoder, comptime T: type, item: T) EncodeError!void {
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try self.out.append(self.gpa, @intFromBool(item)),
            .int => |info| {
                if (info.bits > 64) {
                    const Wide = @Int(.unsigned, info.bits);
                    var raw: Wide = if (info.signedness == .signed)
                        @bitCast((item << 1) ^ (item >> (info.bits - 1)))
                    else
                        item;
                    while (raw >= 0x80) : (raw >>= 7) try self.out.append(self.gpa, @as(u8, @truncate(raw)) | 0x80);
                    try self.out.append(self.gpa, @truncate(raw));
                } else if (info.signedness == .signed) {
                    const wide: i64 = item;
                    try self.varint(@bitCast((wide << 1) ^ (wide >> 63)));
                } else try self.varint(item);
            },
            .float => try self.out.appendSlice(self.gpa, std.mem.asBytes(&item)),
            .@"enum" => try self.varint(@intFromEnum(item)),
            .optional => |info| if (item) |present| {
                try self.out.append(self.gpa, 1);
                try self.value(info.child, present);
            } else try self.out.append(self.gpa, 0),
            .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| try self.value(Field, @field(item, name)),
            .@"union" => {
                try self.varint(@intFromEnum(std.meta.activeTag(item)));
                switch (item) {
                    inline else => |payload| try self.value(@TypeOf(payload), payload),
                }
            },
            .pointer => |info| switch (info.size) {
                .one => try self.pointer(info.child, item),
                .slice => {
                    if (info.sentinel_ptr != null) @compileError("script cache: sentinel slice");
                    if (info.child == u8) return self.string(item);
                    try self.varint(item.len);
                    for (item) |element| try self.value(info.child, element);
                },
                else => @compileError("script cache: unsupported pointer"),
            },
            else => @compileError("script cache: unsupported type " ++ @typeName(T)),
        }
    }

    /// Objects are numbered in first-visit order; a repeated pointer encodes
    /// as a reference, so shared subtrees keep their identity.
    fn pointer(self: *Encoder, comptime Child: type, target: *const Child) EncodeError!void {
        _ = comptime pointeeIndex(Child);
        if (stack_scan.stackAddress() <= self.stack_floor) return error.TooDeep;
        const entry = try self.ids.getOrPut(self.gpa, @intFromPtr(target));
        if (entry.found_existing) return self.varint(@as(u64, entry.value_ptr.*) + 1);
        entry.value_ptr.* = self.next_id;
        self.next_id += 1;
        try self.varint(0);
        try self.value(Child, target.*);
    }
};

/// Serialize `parsed` for `source`. Null when the tree nests too deeply for
/// the encoder's native stack; such a script simply is not cached.
pub fn encode(gpa: std.mem.Allocator, io: std.Io, source: []const u8, digest: *const Digest, parsed: Parsed) error{OutOfMemory}!?[]u8 {
    const executable = executableIdentity(io);
    if (executable == 0) return null;
    var encoder = Encoder{ .gpa = gpa, .source = source, .stack_floor = stack_scan.nestingStackFloor() };
    defer encoder.deinit();
    try encoder.out.appendNTimes(gpa, 0, @sizeOf(Header));
    encoder.pointer(Node, parsed.program) catch |err| switch (err) {
        error.TooDeep => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    encoder.value(bool, parsed.strict) catch |err| switch (err) {
        error.TooDeep => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    encoder.value([]const StatementLocation, parsed.statement_locations) catch |err| switch (err) {
        error.TooDeep => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const payload = encoder.out.items[@sizeOf(Header)..];
    const header = Header{
        .magic = magic,
        .format_version = format_version,
        .reserved = 0,
        .fingerprint = type_fingerprint,
        .executable = executable,
        .source_len = source.len,
        .source_digest = digest.*,
        .payload_len = payload.len,
        .payload_checksum = std.hash.Wyhash.hash(type_fingerprint, payload),
    };
    @memcpy(encoder.out.items[0..@sizeOf(Header)], std.mem.asBytes(&header));
    return try encoder.out.toOwnedSlice(gpa);
}

// ---- decoding ---------------------------------------------------------------

const DecodeError = error{ OutOfMemory, Corrupt };

const Decoder = struct {
    bytes: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    source: []const u8,
    objects: std.ArrayListUnmanaged(Object) = .empty,
    stack_floor: usize,

    const Object = struct { address: usize, type_index: u32 };

    fn byte(self: *Decoder) DecodeError!u8 {
        if (self.pos >= self.bytes.len) return error.Corrupt;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn wide(self: *Decoder, comptime Int: type) DecodeError!Int {
        var result: Int = 0;
        var shift: u32 = 0;
        while (true) {
            const next = try self.byte();
            if (shift >= @bitSizeOf(Int)) return error.Corrupt;
            const bits: Int = next & 0x7f;
            if (shift > 0 and (bits >> @intCast(@bitSizeOf(Int) - shift)) != 0) return error.Corrupt;
            result |= bits << @intCast(shift);
            if (next & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn varint(self: *Decoder) DecodeError!u64 {
        if (self.pos < self.bytes.len and self.bytes[self.pos] < 0x80) {
            defer self.pos += 1;
            return self.bytes[self.pos];
        }
        return self.wide(u64);
    }

    /// The enum value whose integer is `raw`. Enums numbered 0..n-1, as
    /// every enum the tree uses is, decode with one range check.
    fn enumValue(comptime E: type, raw: u64) DecodeError!E {
        const values = @typeInfo(E).@"enum".field_values;
        const dense = comptime blk: {
            for (values, 0..) |tag, index| if (tag != index) break :blk false;
            break :blk true;
        };
        if (dense) {
            if (raw >= values.len) return error.Corrupt;
            return @enumFromInt(raw);
        }
        inline for (values) |tag| if (tag == raw) return @enumFromInt(tag);
        return error.Corrupt;
    }

    fn length(self: *Decoder) DecodeError!usize {
        const len = std.math.cast(usize, try self.varint()) orelse return error.Corrupt;
        // Every encoded element takes at least one byte.
        if (len > self.bytes.len - self.pos) return error.Corrupt;
        return len;
    }

    fn string(self: *Decoder) DecodeError![]const u8 {
        switch (try self.byte()) {
            0 => {
                const offset = std.math.cast(usize, try self.varint()) orelse return error.Corrupt;
                const len = std.math.cast(usize, try self.varint()) orelse return error.Corrupt;
                if (offset > self.source.len or len > self.source.len - offset) return error.Corrupt;
                return self.source[offset..][0..len];
            },
            1 => {
                const len = try self.length();
                defer self.pos += len;
                return try self.arena.dupe(u8, self.bytes[self.pos..][0..len]);
            },
            2 => return "",
            else => return error.Corrupt,
        }
    }

    fn value(self: *Decoder, comptime T: type) DecodeError!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return switch (try self.byte()) {
                0 => false,
                1 => true,
                else => error.Corrupt,
            },
            .int => |info| {
                if (info.bits > 64) {
                    const Wide = @Int(.unsigned, info.bits);
                    const raw = try self.wide(Wide);
                    if (info.signedness == .unsigned) return raw;
                    return @bitCast((raw >> 1) ^ (0 -% (raw & 1)));
                }
                const raw = try self.varint();
                if (info.signedness == .unsigned) return std.math.cast(T, raw) orelse error.Corrupt;
                const signed: i64 = @bitCast((raw >> 1) ^ (0 -% (raw & 1)));
                return std.math.cast(T, signed) orelse error.Corrupt;
            },
            .float => {
                if (self.bytes.len - self.pos < @sizeOf(T)) return error.Corrupt;
                defer self.pos += @sizeOf(T);
                return @bitCast(self.bytes[self.pos..][0..@sizeOf(T)].*);
            },
            .@"enum" => return enumValue(T, try self.varint()),
            .optional => |info| return switch (try self.byte()) {
                0 => null,
                1 => try self.value(info.child),
                else => error.Corrupt,
            },
            .@"struct" => |info| {
                var result: T = undefined;
                inline for (info.field_names, info.field_types) |name, Field| @field(result, name) = try self.value(Field);
                return result;
            },
            .@"union" => |info| switch (try enumValue(info.tag_type.?, try self.varint())) {
                inline else => |tag| return @unionInit(T, @tagName(tag), try self.value(@FieldType(T, @tagName(tag)))),
            },
            .pointer => |info| switch (info.size) {
                .one => return self.pointer(T, info.child),
                .slice => {
                    if (info.child == u8) return self.string();
                    const len = try self.length();
                    const items = try self.arena.alloc(info.child, len);
                    for (items) |*item| item.* = try self.value(info.child);
                    return items;
                },
                else => @compileError("script cache: unsupported pointer"),
            },
            else => @compileError("script cache: unsupported type " ++ @typeName(T)),
        }
    }

    fn pointer(self: *Decoder, comptime Ptr: type, comptime Child: type) DecodeError!Ptr {
        const type_index = comptime pointeeIndex(Child);
        if (stack_scan.stackAddress() <= self.stack_floor) return error.Corrupt;
        const reference = try self.varint();
        if (reference != 0) {
            const index = std.math.cast(usize, reference - 1) orelse return error.Corrupt;
            if (index >= self.objects.items.len) return error.Corrupt;
            const object = self.objects.items[index];
            if (object.type_index != type_index) return error.Corrupt;
            return @ptrFromInt(object.address);
        }
        const target = try self.arena.create(Child);
        try self.objects.append(self.gpa, .{ .address = @intFromPtr(target), .type_index = type_index });
        target.* = try self.value(Child);
        return target;
    }
};

/// Rebuild the tree stored in `entry` for `source`, allocating it in `arena`.
/// Null when the entry does not match this source, engine and executable, or
/// fails any structural check.
pub fn decode(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, source: []const u8, digest: *const Digest, entry: []const u8) error{OutOfMemory}!?Parsed {
    if (entry.len < @sizeOf(Header)) return null;
    var header: Header = undefined;
    @memcpy(std.mem.asBytes(&header), entry[0..@sizeOf(Header)]);
    const executable = executableIdentity(io);
    if (!std.mem.eql(u8, &header.magic, &magic) or header.format_version != format_version or
        header.fingerprint != type_fingerprint or executable == 0 or header.executable != executable or
        header.source_len != source.len or !std.mem.eql(u8, &header.source_digest, digest) or
        header.payload_len != entry.len - @sizeOf(Header))
        return null;
    const payload = entry[@sizeOf(Header)..];
    if (std.hash.Wyhash.hash(type_fingerprint, payload) != header.payload_checksum) return null;
    var decoder = Decoder{ .bytes = payload, .arena = arena, .gpa = gpa, .source = source, .stack_floor = stack_scan.nestingStackFloor() };
    defer decoder.objects.deinit(gpa);
    const parsed = decodeParts(&decoder) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Corrupt => return null,
    };
    if (decoder.pos != payload.len or parsed.program.* != .program) return null;
    return parsed;
}

fn decodeParts(decoder: *Decoder) DecodeError!Parsed {
    const program = try decoder.pointer(*Node, Node);
    const strict = try decoder.value(bool);
    const locations = try decoder.value([]const StatementLocation);
    return .{ .program = program, .statement_locations = locations, .strict = strict };
}

// ---- files ------------------------------------------------------------------

/// The cached tree for `source` in `dir`, or null. An entry that exists but
/// does not match is deleted so the caller's fresh parse can replace it.
pub fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, dir: []const u8, source: []const u8, digest: *const Digest) error{OutOfMemory}!?Parsed {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = entryPath(&path_buf, dir, digest) orelse return null;
    const entry = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(entry);
    if (try decode(arena, gpa, io, source, digest, entry)) |parsed| return parsed;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return null;
}

/// Store the tree for `source` in `dir`. Best effort: any failure leaves no
/// entry behind.
pub fn store(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, source: []const u8, digest: *const Digest, parsed: Parsed) void {
    const encoded = (encode(gpa, io, source, digest, parsed) catch return) orelse return;
    defer gpa.free(encoded);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = entryPath(&path_buf, dir, digest) orelse return;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buf, "{s}.{s}.tmp", .{ path, &std.fmt.bytesToHex(nonce, .lower) }) catch return;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch {};
    cwd.writeFile(io, .{ .sub_path = temp, .data = encoded }) catch {
        cwd.deleteFile(io, temp) catch {};
        return;
    };
    cwd.rename(temp, cwd, path, io) catch cwd.deleteFile(io, temp) catch {};
}
