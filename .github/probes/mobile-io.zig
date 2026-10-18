const std = @import("std");
const backend = @import("backend");

// Export the complete vtable so target compilation must instantiate its actual
// operations, including those absent on sandboxed Apple platforms.
export fn zigjsMobileIoVTable() usize {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return @intFromPtr(backend.threadedIo(&threaded).vtable);
}
