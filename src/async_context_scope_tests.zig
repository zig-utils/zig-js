//! Focused production-module probe: a job must restore its caller on every exit.
const std = @import("std");
const Context = @import("context.zig").Context;
const Interpreter = @import("interpreter.zig").Interpreter;
const value = @import("value.zig");
const promise = @import("promise.zig");
const gc_engine = @import("gc.zig");
const Value = value.Value;

const State = struct { throwing: bool, saw_context: bool = false };
fn callback(raw: *anyopaque, _: Value, _: []const Value) value.HostError!Value {
    const machine: *Interpreter = @ptrCast(@alignCast(raw));
    const state: *State = @ptrCast(@alignCast(machine.active_native.?.private_data.?));
    state.saw_context = machine.getAsyncContext().isNumber() and machine.getAsyncContext().asNum() == 22;
    machine.setAsyncContext(Value.num(99));
    if (state.throwing) {
        machine.exception = Value.str("expected job failure");
        return error.Throw;
    }
    return Value.undef();
}

pub fn main() !void {
    const ctx = try Context.createWith(std.heap.smp_allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    const saved_context = gc_engine.setActiveContext(ctx);
    defer gc_engine.restoreActiveContext(saved_context);
    var machine = ctx.interpreter();
    try ctx.pushActiveInterpreter(&machine);
    defer ctx.popActiveInterpreter(&machine);
    const scope = machine.enterAsyncContextScope();
    defer scope.leave();
    const fn_value = try machine.newObject();
    fn_value.asObj().native = callback;
    for ([_]bool{ false, true }) |throwing| {
        var state = State{ .throwing = throwing };
        fn_value.asObj().private_data = @ptrCast(&state);
        machine.setAsyncContext(Value.num(11));
        var task = promise.Microtask{
            .kind = .callback,
            .reaction = undefined,
            .argument = Value.undef(),
            .fulfilled = true,
            .callback = fn_value,
            .async_context = Value.num(22),
        };
        var publication = try promise.PreparedSettlement.prepare(&machine, machine.microtasks.?);
        defer publication.cancel(&machine);
        var threw = false;
        promise.runJob(&machine, &task, &publication) catch |err| {
            if (err != error.Throw) return err;
            threw = true;
        };
        if (threw != throwing or !state.saw_context or !machine.getAsyncContext().isNumber() or machine.getAsyncContext().asNum() != 11)
            return error.AsyncContextScopeNotRestored;
        machine.exception = Value.undef();
    }
    std.debug.print("OK 2 job scopes restore after normal and abrupt completion\n", .{});
}
