//! Host re-entry must not reset a bounded interpreter's Script allowance.
const std = @import("std");
const js = @import("js");

fn hostScript(raw: *anyopaque, _: js.Value, args: []const js.Value) js.HostError!js.Value {
    const machine: *js.Interpreter = @ptrCast(@alignCast(raw));
    const ctx: *js.Context = @ptrCast(@alignCast(machine.gc_realm_context.?));
    return ctx.evaluate(args[0].asStr()) catch |err| switch (err) {
        error.Throw => {
            machine.exception = ctx.exception.?;
            return error.Throw;
        },
        else => return error.OutOfMemory,
    };
}

pub fn run(gpa: std.mem.Allocator) !usize {
    for ([_]bool{ false, true }) |bytecode| {
        const ctx = try js.Context.createWithTestingOptions(gpa, .{
            .step_budget = 2000,
            .bytecode_execution_mode = if (bytecode) .required else .tree_walker,
        });
        defer ctx.destroy();
        var installer = ctx.interpreter();
        defer installer.deinit();
        const function = try installer.newObject();
        function.asObj().native = hostScript;
        try ctx.global_object.setOwn(ctx.arena(), ctx.root_shape, "hostScript", function);
        if ((try ctx.evaluate("hostScript('3 + 4')")).asNum() != 7)
            return error.WrongNestedCompletion;
        if (ctx.evaluate(
            "var calls=0;for(var round=0;round<20;round++){hostScript('for(var inner=0;inner<100;inner++){}');calls++;}calls",
        )) |_| {
            return error.NestedScriptResetBudget;
        } else |err| {
            if (err != error.Throw) return err;
            const exception = ctx.exception orelse return error.MissingBudgetException;
            if (!exception.isObject() or !std.mem.eql(u8, exception.asObj().errorName(), "RangeError"))
                return error.WrongBudgetException;
        }
        // A new top-level host entry starts a fresh allowance after failure.
        if ((try ctx.evaluate("7")).asNum() != 7) return error.FreshEntryFailed;
        std.debug.print("reentrant script {s}: nested completion, RangeError and fresh host entry passed\n", .{
            if (bytecode) "required-bytecode" else "tree-walker",
        });
    }
    return 2;
}
