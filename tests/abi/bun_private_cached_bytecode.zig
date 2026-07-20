const std = @import("std");

const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};

const ZigString = extern struct { tagged_ptr: usize, len: usize };
const BunStringImpl = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*anyopaque,
};
const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringImpl,
};
const CachedBytecode = opaque {};

extern "c" fn generateCachedModuleByteCodeFromSourceCode(*const BunString, [*]const u8, usize, *?[*]u8, *usize, *?*CachedBytecode) bool;
extern "c" fn generateCachedCommonJSProgramByteCodeFromSourceCode(*const BunString, [*]const u8, usize, *?[*]u8, *usize, *?*CachedBytecode) bool;
extern "c" fn CachedBytecode__deref(*CachedBytecode) void;

fn fail(message: []const u8) noreturn {
    std.debug.print("Bun private cached bytecode: {s}\n", .{message});
    std.process.exit(1);
}

fn generate(kind: u8, url: *const BunString, source: []const u8) void {
    var bytes: ?[*]u8 = null;
    var len: usize = 0;
    var owner: ?*CachedBytecode = null;
    const ok = if (kind == 1)
        generateCachedModuleByteCodeFromSourceCode(url, source.ptr, source.len, &bytes, &len, &owner)
    else
        generateCachedCommonJSProgramByteCodeFromSourceCode(url, source.ptr, source.len, &bytes, &len, &owner);
    if (!ok or len <= source.len or !std.mem.eql(u8, bytes.?[0..8], "ZJSCBC01") or
        bytes.?[10] != kind or !std.mem.eql(u8, bytes.?[len - source.len .. len], source))
        fail("artifact mismatch");
    CachedBytecode__deref(owner.?);
}

pub fn main() void {
    const url_bytes = "file:///bun-cache.js";
    const url = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_bytes.ptr), .len = url_bytes.len } },
    };
    const source = "const cached = 42;";
    generate(1, &url, source);
    generate(2, &url, source);

    var bytes: ?[*]u8 = @ptrFromInt(1);
    var len: usize = 1;
    var owner: ?*CachedBytecode = @ptrFromInt(1);
    const invalid = "const = ;";
    if (generateCachedModuleByteCodeFromSourceCode(&url, invalid.ptr, invalid.len, &bytes, &len, &owner) or
        bytes != null or len != 0 or owner != null)
        fail("failure atomicity mismatch");
}
