//! AST-only Annex B block-function eligibility, shared by declaration planning
//! and runtime instantiation. The visitor owns candidate membership/storage;
//! this walk neither creates bindings nor enters nested function bodies.

const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NameStack = std.ArrayListUnmanaged([]const u8);

pub fn functionDeclaration(node: *Node) ?*Node {
    var current = node;
    while (current.* == .labeled_stmt) current = current.labeled_stmt.body;
    return if (current.* == .func_decl) current else null;
}

/// ECMA-262 B.3.2 (formerly B.3.3): determine the declarations whose evaluation
/// copies their block binding into the variable environment. Parameter names
/// and an actually created arguments binding exclude legacy candidates; eval
/// callers pass an empty parameter list instead of inheriting caller exclusions.
pub fn collect(
    comptime Error: type,
    allocator: std.mem.Allocator,
    statements: []const *Node,
    depth: u32,
    parameters: []const ast.Param,
    arguments_object_needed: bool,
    visitor: anytype,
) Error!void {
    var analysis = Analysis(Error, @TypeOf(visitor)){ .allocator = allocator, .visitor = visitor };
    defer analysis.names.deinit(allocator);
    for (parameters) |parameter| {
        if (parameter.pattern) |pattern|
            try analysis.appendPattern(pattern)
        else if (parameter.name.len != 0)
            try analysis.names.append(allocator, parameter.name);
    }
    if (arguments_object_needed and !analysis.contains("arguments"))
        try analysis.names.append(allocator, "arguments");
    try analysis.scanList(statements, depth);
}

fn Analysis(comptime Error: type, comptime Visitor: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        visitor: Visitor,
        names: NameStack = .empty,

        fn contains(self: *const Self, name: []const u8) bool {
            for (self.names.items) |blocked| if (std.mem.eql(u8, blocked, name)) return true;
            return false;
        }

        fn appendPattern(self: *Self, pattern: *Node) Error!void {
            switch (pattern.*) {
                .identifier => |name| try self.names.append(self.allocator, name),
                .obj_pattern => |object| {
                    for (object.props) |property| try self.appendPattern(property.target);
                    if (object.rest) |rest| try self.appendPattern(rest);
                },
                .arr_pattern => |array| {
                    for (array.elems) |element| if (element.target) |target| try self.appendPattern(target);
                    if (array.rest) |rest| try self.appendPattern(rest);
                },
                else => {},
            }
        }

        fn appendLexical(self: *Self, node: *Node) Error!void {
            switch (node.*) {
                .var_decl => |declaration| if (declaration.kind != .@"var")
                    try self.names.append(self.allocator, declaration.name),
                .decl_group => |group| for (group) |declaration| try self.appendLexical(declaration),
                .destructure_decl => |declaration| if (declaration.kind != .@"var")
                    try self.appendPattern(declaration.pattern),
                .class_expr => |class| if (class.name.len != 0) try self.names.append(self.allocator, class.name),
                // Async/generator declarations are lexical exclusions, never
                // legacy candidates. Ordinary functions are handled below so a
                // block's own candidates do not exclude one another.
                .func_decl => |function| if (function.is_generator or function.is_async)
                    try self.names.append(self.allocator, function.name),
                else => {},
            }
        }

        fn candidate(self: *Self, statement: *Node) Error!void {
            const node = functionDeclaration(statement) orelse return;
            const function = node.func_decl;
            if (!function.is_generator and !function.is_async and !self.contains(function.name))
                try self.visitor.add(node, function.name);
        }

        fn appendFunction(self: *Self, statement: *Node) Error!void {
            const node = functionDeclaration(statement) orelse return;
            const function = node.func_decl;
            if (!function.is_generator and !function.is_async)
                try self.names.append(self.allocator, function.name);
        }

        fn scanList(self: *Self, statements: []const *Node, depth: u32) Error!void {
            const base = self.names.items.len;
            defer self.names.shrinkRetainingCapacity(base);
            for (statements) |statement| try self.appendLexical(statement);
            if (depth != 0) {
                for (statements) |statement| try self.candidate(statement);
                // A block function excludes deeper same-named legacy vars,
                // while a variable-scope function declaration does not.
                for (statements) |statement| try self.appendFunction(statement);
            }
            for (statements) |statement| try self.scanStatement(statement, depth);
        }

        fn scanBranch(self: *Self, node: *Node, depth: u32) Error!void {
            switch (node.*) {
                .block => |statements| try self.scanList(statements, depth + 1),
                .func_decl => try self.candidate(node),
                else => try self.scanStatement(node, depth),
            }
        }

        fn scanStatement(self: *Self, node: *Node, depth: u32) Error!void {
            switch (node.*) {
                .block => |statements| try self.scanList(statements, depth + 1),
                .if_stmt => |statement| {
                    try self.scanBranch(statement.consequent, depth);
                    if (statement.alternate) |alternate| try self.scanBranch(alternate, depth);
                },
                .while_stmt => |statement| try self.scanBranch(statement.body, depth),
                .do_while_stmt => |statement| try self.scanBranch(statement.body, depth),
                .with_stmt => |statement| try self.scanBranch(statement.body, depth),
                .for_stmt => |statement| {
                    const base = self.names.items.len;
                    defer self.names.shrinkRetainingCapacity(base);
                    if (statement.init) |init| try self.appendLexical(init);
                    try self.scanBranch(statement.body, depth);
                },
                .for_in => |statement| {
                    const base = self.names.items.len;
                    defer self.names.shrinkRetainingCapacity(base);
                    if (statement.decl_kind) |kind| if (kind != .@"var") try self.appendPattern(statement.target);
                    try self.scanBranch(statement.body, depth);
                },
                .labeled_stmt => |statement| try self.scanBranch(statement.body, depth),
                .switch_stmt => |statement| {
                    const base = self.names.items.len;
                    defer self.names.shrinkRetainingCapacity(base);
                    // All cases share one CaseBlock, including declarations in
                    // cases that will not execute and tests before their case.
                    for (statement.cases) |case| for (case.body) |child| try self.appendLexical(child);
                    for (statement.cases) |case| for (case.body) |child| try self.candidate(child);
                    for (statement.cases) |case| for (case.body) |child| try self.appendFunction(child);
                    for (statement.cases) |case| for (case.body) |child| try self.scanStatement(child, depth + 1);
                },
                .try_stmt => |statement| {
                    try self.scanBranch(statement.block, depth);
                    if (statement.catch_block) |block| {
                        const base = self.names.items.len;
                        defer self.names.shrinkRetainingCapacity(base);
                        // Annex B.3.4 (formerly B.3.5) exempts a simple catch
                        // parameter, but not destructuring-bound catch names.
                        if (statement.catch_param) |parameter| if (parameter.* != .identifier)
                            try self.appendPattern(parameter);
                        try self.scanBranch(block, depth);
                    }
                    if (statement.finally_block) |block| try self.scanBranch(block, depth);
                },
                else => {},
            }
        }
    };
}

const TestCandidates = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(*const Node) = .empty,

    pub fn add(self: *@This(), node: *const Node, _: []const u8) std.mem.Allocator.Error!void {
        try self.nodes.append(self.allocator, node);
    }
};

test "Annex B shared analysis preserves exact declaration identities and exclusions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try @import("parser.zig").Parser.init(allocator,
        \\function owner(parameter, { destructured }) {
        \\  { function parameter() {} function destructured() {} function arguments() {} }
        \\  { let lexical; { function lexical() {} } }
        \\  { let unused, { grouped } = {}; { function grouped() {} } }
        \\  { function outer() {} { function outer() {} } }
        \\  { function duplicate() {} function duplicate() {} }
        \\  { label: function labeled() {} }
        \\  if (true) function branch() {}
        \\  for (let loop = 0; loop < 1; loop++) { function loop() {} }
        \\  for (let item of []) { function item() {} }
        \\  try {} catch (simple) { { function simple() {} } }
        \\  try {} catch ({ pattern }) { { function pattern() {} } }
        \\  switch (0) {
        \\    case 0: function switched() {} { function switched() {} } break;
        \\    case 1: let blocked; { function blocked() {} }
        \\  }
        \\  { function* generator() {} { function generator() {} } }
        \\  { async function asynchronous() {} { function asynchronous() {} } }
        \\  function nested() { { function invisible() {} } }
        \\}
    );
    const program = try parser.parseProgram();
    const owner = program.program[0].func_decl;
    var candidates = TestCandidates{ .allocator = allocator };
    try collect(std.mem.Allocator.Error, allocator, owner.body.block, 0, owner.params, true, &candidates);
    const expected = [_][]const u8{ "outer", "duplicate", "duplicate", "labeled", "branch", "simple", "switched" };
    try std.testing.expectEqual(expected.len, candidates.nodes.items.len);
    for (expected, candidates.nodes.items) |name, node| try std.testing.expectEqualStrings(name, node.func_decl.name);
    try std.testing.expect(candidates.nodes.items[1] != candidates.nodes.items[2]);
}

fn testAllocationFailures(allocator: std.mem.Allocator, statements: []const *Node) !void {
    var candidates = TestCandidates{ .allocator = allocator };
    defer candidates.nodes.deinit(allocator);
    try collect(std.mem.Allocator.Error, allocator, statements, 0, &.{}, false, &candidates);
    try std.testing.expectEqual(@as(usize, 3), candidates.nodes.items.len);
}

test "Annex B shared analysis propagates every scratch and visitor allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(arena.allocator(),
        \\{ let a, b, c, d, e, f, g, h, i, j; function first() {} }
        \\try {} catch ({ x, y, z }) { { function second() {} } }
        \\switch (0) { case 0: function third() {} }
    );
    const program = try parser.parseProgram();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAllocationFailures, .{program.program});
}

test "Annex B shared analysis keeps eval exclusions and function-top depth explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try @import("parser.zig").Parser.init(allocator,
        \\function owner(parameter) {
        \\  function top() {}
        \\  { function parameter() {} function arguments() {} function available() {} }
        \\}
    );
    const program = try parser.parseProgram();
    const owner = program.program[0].func_decl;
    var invocation = TestCandidates{ .allocator = allocator };
    try collect(std.mem.Allocator.Error, allocator, owner.body.block, 0, owner.params, true, &invocation);
    try std.testing.expectEqual(@as(usize, 1), invocation.nodes.items.len);
    try std.testing.expectEqualStrings("available", invocation.nodes.items[0].func_decl.name);

    var evaluation = TestCandidates{ .allocator = allocator };
    try collect(std.mem.Allocator.Error, allocator, owner.body.block, 0, &.{}, false, &evaluation);
    const expected = [_][]const u8{ "parameter", "arguments", "available" };
    try std.testing.expectEqual(expected.len, evaluation.nodes.items.len);
    for (expected, evaluation.nodes.items) |name, node| try std.testing.expectEqualStrings(name, node.func_decl.name);
    try std.testing.expectEqual(invocation.nodes.items[0], evaluation.nodes.items[2]);
}
