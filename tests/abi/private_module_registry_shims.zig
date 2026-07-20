const std = @import("std");

const JSContextRef = ?*anyopaque;

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSGlobalObject__throwOutOfMemoryError(JSContextRef) void;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn Zig__GlobalObject__getModuleRegistryMap(JSContextRef) ?*anyopaque;
extern "c" fn Zig__GlobalObject__resetModuleRegistryMap(JSContextRef, ?*anyopaque) bool;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

pub fn main() void {
    if (Zig__GlobalObject__getModuleRegistryMap(null) != null) fail("null global produced a legacy registry Map");
    if (Zig__GlobalObject__getModuleRegistryMap(@ptrFromInt(1)) != null) fail("opaque global produced a legacy registry Map");
    if (Zig__GlobalObject__resetModuleRegistryMap(null, null)) fail("null snapshot restore succeeded");
    if (Zig__GlobalObject__resetModuleRegistryMap(@ptrFromInt(1), @ptrFromInt(2))) fail("opaque snapshot restore succeeded");

    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    JSGlobalObject__throwOutOfMemoryError(context);
    if (!JSGlobalObject__hasException(context)) fail("failed to install pending exception");
    if (Zig__GlobalObject__getModuleRegistryMap(context) != null) fail("legacy registry Map unexpectedly exists");
    if (Zig__GlobalObject__resetModuleRegistryMap(context, @ptrFromInt(2))) fail("retired snapshot restore succeeded");
    if (!JSGlobalObject__hasException(context)) fail("retired shims changed pending exception state");
    JSGlobalObject__clearException(context);
}
