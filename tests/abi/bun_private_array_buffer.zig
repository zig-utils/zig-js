const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    _,

    fn isCell(value: EncodedValue) bool {
        const bits: u64 = @bitCast(@intFromEnum(value));
        return value != .empty and bits & 0xfffe_0000_0000_0002 == 0;
    }

    fn cellPointer(value: EncodedValue) JSObjectRef {
        if (!value.isCell()) return null;
        return @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(@intFromEnum(value))))));
    }
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSObjectGetTypedArrayBytesPtr(JSContextRef, JSObjectRef, [*c]JSValueRef) ?*anyopaque;
extern "c" fn JSObjectGetTypedArrayLength(JSContextRef, JSObjectRef, [*c]JSValueRef) usize;
extern "c" fn JSObjectGetArrayBufferBytesPtr(JSContextRef, JSObjectRef, [*c]JSValueRef) ?*anyopaque;
extern "c" fn JSObjectGetArrayBufferByteLength(JSContextRef, JSObjectRef, [*c]JSValueRef) usize;
extern "c" fn JSBuffer__isBuffer(JSContextRef, EncodedValue) bool;

// Exact declarations consumed by Bun's pinned src/jsc/array_buffer.zig.
extern "c" fn Bun__createArrayBufferForCopy(JSContextRef, ?*const anyopaque, usize) EncodedValue;
extern "c" fn Bun__allocUint8ArrayForCopy(JSContextRef, usize, **anyopaque) EncodedValue;
extern "c" fn Bun__allocArrayBufferForCopy(JSContextRef, usize, **anyopaque) EncodedValue;
extern "c" fn JSArrayBuffer__fromDefaultAllocator(JSContextRef, [*]u8, usize) EncodedValue;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    var exception: JSValueRef = null;

    var source = [_]u8{ 1, 2, 3, 4 };
    const copied = Bun__createArrayBufferForCopy(context, &source, source.len);
    const copied_raw = JSObjectGetArrayBufferBytesPtr(context, copied.cellPointer(), &exception) orelse
        fail("copied ArrayBuffer bytes lookup failed");
    const copied_bytes = @as([*]u8, @ptrCast(copied_raw))[0..source.len];
    if (exception != null or JSObjectGetArrayBufferByteLength(context, copied.cellPointer(), &exception) != source.len or
        !std.mem.eql(u8, copied_bytes, &source))
        fail("copied ArrayBuffer shape/content mismatch");
    source[0] = 99;
    if (copied_bytes[0] != 1) fail("copied ArrayBuffer aliases its source");

    var uint8_raw: *anyopaque = @ptrFromInt(1);
    const uint8 = Bun__allocUint8ArrayForCopy(context, 4, &uint8_raw);
    const uint8_bytes = JSObjectGetTypedArrayBytesPtr(context, uint8.cellPointer(), &exception) orelse
        fail("allocated Uint8Array bytes lookup failed");
    if (exception != null or uint8_bytes != uint8_raw or
        JSObjectGetTypedArrayLength(context, uint8.cellPointer(), &exception) != 4 or
        JSBuffer__isBuffer(context, uint8))
        fail("allocated Uint8Array shape/pointer mismatch");
    @as([*]u8, @ptrCast(uint8_raw))[1] = 42;
    if (@as([*]const u8, @ptrCast(uint8_bytes))[1] != 42)
        fail("allocated Uint8Array pointer did not expose its backing");

    var buffer_raw: *anyopaque = @ptrFromInt(1);
    const buffer = Bun__allocArrayBufferForCopy(context, 3, &buffer_raw);
    const buffer_bytes = JSObjectGetTypedArrayBytesPtr(context, buffer.cellPointer(), &exception) orelse
        fail("allocated Buffer bytes lookup failed");
    if (exception != null or buffer_bytes != buffer_raw or
        JSObjectGetTypedArrayLength(context, buffer.cellPointer(), &exception) != 3 or
        !JSBuffer__isBuffer(context, buffer))
        fail("historically named ArrayBuffer allocator did not return Bun Buffer storage");

    const adopted_raw = std.c.malloc(3) orelse fail("default-allocator allocation failed");
    const adopted_input = @as([*]u8, @ptrCast(adopted_raw))[0..3];
    @memcpy(adopted_input, &[_]u8{ 7, 8, 9 });
    const adopted = JSArrayBuffer__fromDefaultAllocator(context, adopted_input.ptr, adopted_input.len);
    const adopted_bytes = JSObjectGetArrayBufferBytesPtr(context, adopted.cellPointer(), &exception) orelse
        fail("adopted ArrayBuffer bytes lookup failed");
    if (exception != null or adopted_bytes != adopted_raw or
        JSObjectGetArrayBufferByteLength(context, adopted.cellPointer(), &exception) != adopted_input.len or
        !std.mem.eql(u8, @as([*]const u8, @ptrCast(adopted_bytes))[0..3], adopted_input))
        fail("default-allocator ArrayBuffer adoption mismatch");

    var empty_sentinel: u8 = 0;
    const empty = JSArrayBuffer__fromDefaultAllocator(context, @ptrCast(&empty_sentinel), 0);
    if (exception != null or JSObjectGetArrayBufferByteLength(context, empty.cellPointer(), &exception) != 0)
        fail("empty default-allocator ArrayBuffer mismatch");
}
