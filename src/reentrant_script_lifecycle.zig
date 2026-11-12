//! A nested Script must return before the outer caller releases its child.
const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;
const Interpreter = @import("interpreter.zig").Interpreter;
const value = @import("value.zig");
const gc_engine = @import("gc.zig");
extern "c" fn alarm(seconds: c_uint) c_uint;

fn hostScript(raw: *anyopaque, _: value.Value, args: []const value.Value) value.HostError!value.Value {
    const machine: *Interpreter = @ptrCast(@alignCast(raw));
    const ctx: *Context = @ptrCast(@alignCast(machine.gc_realm_context.?));
    return ctx.evaluate(args[0].asStr()) catch |err| switch (err) {
        error.Throw => {
            machine.exception = ctx.exception.?;
            return error.Throw;
        },
        else => return error.OutOfMemory,
    };
}

fn run(serialized: bool) !void {
    const ctx = try Context.createWith(std.heap.page_allocator, .{ .enable_threads = true, .gil = serialized });
    defer ctx.destroy();
    {
        // Native heap setup obeys serialized Context ownership too.
        if (serialized) ctx.gil.?.acquire();
        defer if (serialized) ctx.gil.?.release();
        const saved_context = gc_engine.setActiveContext(ctx);
        defer gc_engine.restoreActiveContext(saved_context);
        var installer = ctx.interpreter();
        defer installer.deinit();
        const function = try installer.newObject();
        function.asObj().native = hostScript;
        try ctx.global_object.setOwn(ctx.arena(), ctx.root_shape, "hostScript", function);
    }
    const result = try ctx.evaluate(
        \\globalThis.releaseFlag=new Int32Array(new SharedArrayBuffer(4));
        \\var child=new Thread(()=>{var deadline=Date.now()+3000;
        \\  while(Atomics.load(releaseFlag,0)===0&&Date.now()<deadline){}
        \\  return Atomics.load(releaseFlag,0);
        \\});
        \\var inner=hostScript('23');
        \\Atomics.store(releaseFlag,0,1);Atomics.notify(releaseFlag,0);
        \\inner===23&&child.join()===1;
    );
    if (!result.isBoolean() or !result.asBool()) return error.PrematureScriptKeepalive;
    std.debug.print("reentrant Script {s} lifecycle: caller resumed and child returned 1\n", .{
        if (serialized) "GIL" else "no-GIL",
    });
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next();
    if (args.next() != null) return error.InvalidMode;
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) _ = alarm(30);
    defer {
        if (builtin.os.tag == .macos or builtin.os.tag == .linux) _ = alarm(0);
    }
    if (mode) |name| {
        if (std.mem.eql(u8, name, "gil")) return run(true);
        if (std.mem.eql(u8, name, "no-gil")) return run(false);
        return error.InvalidMode;
    }
    try run(false);
    try run(true);
}
