//! Typed creation boundary for every OS thread the production engine owns.
//!
//! The kind is intentionally behavior-neutral today. It makes ownership
//! auditable now and is the stable admission point for #502's resource
//! coordinator without changing stack, scheduling, or lifecycle semantics.

const std = @import("std");

pub const Kind = enum {
    test262_agent,
    concurrent_gc_marker,
    javascript_thread,
    script_worker,
    module_worker,
    execution_watchdog,
};

pub fn spawn(
    comptime kind: Kind,
    config: std.Thread.SpawnConfig,
    comptime function: anytype,
    args: anytype,
) !std.Thread {
    _ = kind;
    return std.Thread.spawn(config, function, args);
}
