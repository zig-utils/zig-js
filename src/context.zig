const std = @import("std");
const interp = @import("interpreter.zig");
const value = @import("value.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const Shape = @import("shape.zig").Shape;
const Parser = @import("parser.zig").Parser;

pub const RunError = interp.EvalError || @import("parser.zig").ParseError;

/// An isolated engine instance — the homegrown analogue of a JSC
/// `JSGlobalContextRef`. Owns an arena for all interpreter-lived allocations
/// (AST, strings, objects, boxed values) and a persistent global environment
/// so variables survive across `evaluate` calls, like a real global context.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    env: interp.Environment,
    global_object: *value.Object,
    /// The empty root shape every object in this context transitions from.
    root_shape: *Shape,
    exception: ?value.Value = null,

    pub fn create(gpa: std.mem.Allocator) !*Context {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena_state.deinit();
            gpa.destroy(arena_state);
        }
        const a = arena_state.allocator();

        const global_obj = try a.create(value.Object);
        global_obj.* = .{};

        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .env = .{ .arena = a },
            .global_object = global_obj,
            .root_shape = try Shape.createRoot(a),
        };
        try interp.installGlobals(&self.env, self.root_shape);
        return self;
    }

    /// An interpreter bound to this context's arena, globals, and shape tree.
    pub fn interpreter(self: *Context) interp.Interpreter {
        return .{ .arena = self.arena(), .env = &self.env, .root_shape = self.root_shape };
    }

    pub fn destroy(self: *Context) void {
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.gpa.destroy(self);
    }

    pub fn arena(self: *Context) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Lex + parse + run `source`, returning the completion value. On an
    /// uncaught JS exception this returns `error.Throw` and leaves the thrown
    /// value in `self.exception` for the caller (e.g. the C-API boundary).
    ///
    /// Fast path: compile to bytecode and run on the VM. Programs that use
    /// constructs the compiler doesn't lower yet fall back to the tree-walker,
    /// so behavior is identical either way — the VM just handles the hot subset.
    pub fn evaluate(self: *Context, source: []const u8) RunError!value.Value {
        const a = self.arena();
        var parser = try Parser.init(a, source);
        const prog = try parser.parseProgram();
        var machine = self.interpreter();
        self.exception = null;

        if (compiler.Compiler.compileProgram(a, prog)) |chunk| {
            return vm.run(&machine, chunk, null) catch |err| {
                if (err == error.Throw) self.exception = machine.exception;
                return err;
            };
        } else |err| switch (err) {
            error.Unsupported => {}, // fall through to the tree-walker
            error.OutOfMemory => return error.OutOfMemory,
        }

        return machine.eval(prog) catch |err| {
            if (err == error.Throw) self.exception = machine.exception;
            return err;
        };
    }
};

test "context persists globals across evaluations" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate("var counter = 41;");
    const v = try ctx.evaluate("counter = counter + 1;");
    try std.testing.expectEqual(@as(f64, 42), v.number);
}
