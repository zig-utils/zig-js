const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    _,

    fn fromBits(bits: u64) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(bits)));
    }

    fn fromInt32(value: i32) EncodedValue {
        return fromBits(0xfffe_0000_0000_0000 | @as(u64, @as(u32, @bitCast(value))));
    }

    fn cellPointer(value: EncodedValue) ?*anyopaque {
        const bits: u64 = @bitCast(@intFromEnum(value));
        if (bits == 0 or bits & 0xfffe_0000_0000_0002 != 0) return null;
        return @ptrFromInt(@as(usize, @intCast(bits)));
    }
};

const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};

const ZigString = extern struct { tagged_ptr: usize, len: usize };
const BunString = extern struct {
    tag: BunStringTag,
    value: extern union {
        zig_string: ZigString,
        wtf_string_impl: ?*anyopaque,
    },
};
const ExternColumnIdentifier = extern struct {
    tag: u8,
    value: extern union {
        index: u32,
        name: BunString,
    },
};

comptime {
    if (@sizeOf(BunString) != 24 or @alignOf(BunString) != 8 or
        @sizeOf(ExternColumnIdentifier) != 32 or @alignOf(ExternColumnIdentifier) != 8 or
        @offsetOf(ExternColumnIdentifier, "value") != 8)
        @compileError("pinned Bun SQL structure ABI drifted");
}

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSObjectMake(JSContextRef, ?*anyopaque, ?*anyopaque) JSObjectRef;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef, [*c]JSValueRef) JSValueRef;
extern "c" fn JSValueToNumber(JSContextRef, JSValueRef, [*c]JSValueRef) f64;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;
extern "c" fn JSC__JSCell__getObject(?*anyopaque) JSObjectRef;
extern "c" const JSC__JSObject__maxInlineCapacity: c_uint;
extern "c" fn JSC__createStructure(JSContextRef, ?*anyopaque, u32, [*c]const ExternColumnIdentifier) EncodedValue;
extern "c" fn JSC__createEmptyObjectWithStructure(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__putDirectOffset(?*anyopaque, EncodedValue, u32, EncodedValue) void;

fn fail(message: []const u8) noreturn {
    std.debug.print("Bun private SQL structure: {s}\n", .{message});
    std.process.exit(1);
}

fn bunString(bytes: []const u8) BunString {
    return .{
        .tag = .zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(bytes.ptr), .len = bytes.len } },
    };
}

fn numberProperty(context: JSContextRef, object: JSObjectRef, name: [*:0]const u8) f64 {
    const property = JSStringCreateWithUTF8CString(name) orelse fail("property string allocation failed");
    defer JSStringRelease(property);
    var exception: JSValueRef = null;
    const result = JSObjectGetProperty(context, object, property, &exception) orelse fail("property read failed");
    if (exception != null) fail("property read threw");
    return JSValueToNumber(context, result, &exception);
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const vm = JSC__JSGlobalObject__vm(context) orelse fail("VM lookup failed");
    const owner = JSObjectMake(context, null, null) orelse fail("owner creation failed");

    const id = "id";
    const value = "value";
    var names = [_]ExternColumnIdentifier{
        .{ .tag = 2, .value = .{ .name = bunString(id) } },
        .{ .tag = 1, .value = .{ .index = 0 } },
        .{ .tag = 0, .value = .{ .index = 0 } },
        .{ .tag = 2, .value = .{ .name = bunString(value) } },
    };
    if (JSC__JSObject__maxInlineCapacity != 62) fail("inline capacity mismatch");
    const structure = JSC__createStructure(context, owner, names.len, &names);
    if (structure == .empty or JSC__JSCell__getObject(structure.cellPointer()) != null)
        fail("opaque structure creation failed");
    const row = JSC__createEmptyObjectWithStructure(context, structure);
    const row_object = row.cellPointer() orelse fail("row construction failed");
    JSC__putDirectOffset(vm, row, 0, EncodedValue.fromInt32(411));
    JSC__putDirectOffset(vm, row, 1, EncodedValue.fromInt32(412));
    JSC__putDirectOffset(vm, row, 99, EncodedValue.fromInt32(-1));
    if (numberProperty(context, row_object, "id") != 411 or
        numberProperty(context, row_object, "value") != 412)
        fail("direct offset materialization mismatch");

    const empty_structure = JSC__createStructure(context, null, 0, null);
    if (empty_structure == .empty or JSC__createEmptyObjectWithStructure(context, empty_structure) == .empty)
        fail("zero-column/null-owner structure failed");
    std.debug.print("Bun private SQL structure: 4/4 symbols linked; runtime matrix passed\n", .{});
}
