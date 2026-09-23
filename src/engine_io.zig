//! Process-wide blocking I/O used by engine synchronization primitives.
//!
//! The runtime uses only the futex/clock surface. Keeping the singleton in a
//! neutral module lets low-level resource coordination park threads without
//! importing the agent host and creating a dependency cycle.

const std = @import("std");

var threaded: std.Io.Threaded = undefined;
var state = std.atomic.Value(u8).init(0); // 0 uninit / 1 initializing / 2 ready

pub fn get() std.Io {
    while (true) {
        switch (state.load(.acquire)) {
            2 => return threaded.io(),
            0 => if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
                state.store(2, .release);
                return threaded.io();
            },
            else => std.atomic.spinLoopHint(),
        }
    }
}
