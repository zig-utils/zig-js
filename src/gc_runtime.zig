const std = @import("std");

pub const ObjectBackingState = struct {
    allocator: std.mem.Allocator,
    stores_live: ?*usize,
};

pub const State = struct {
    object_backing: ?ObjectBackingState = null,
};

threadlocal var active_object_backing: ?ObjectBackingState = null;

pub fn setActive(state: State) State {
    const prev = State{ .object_backing = active_object_backing };
    active_object_backing = state.object_backing;
    return prev;
}

pub fn activeObjectBacking() ?ObjectBackingState {
    return active_object_backing;
}
