const std = @import("std");

pub const UnaryOp = enum { neg, pos, not, typeof };

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    lt,
    le,
    gt,
    ge,
    eq,
    neq,
    eq_strict,
    neq_strict,
};

pub const LogicalOp = enum { @"and", @"or" };

pub const DeclKind = enum { @"var", let, @"const" };

/// Shared shape for function declarations, function expressions, and arrow
/// functions. `is_expr_body` is true for concise arrow bodies (`x => x + 1`),
/// where `body` is an expression rather than a block.
pub const FunctionNode = struct {
    name: []const u8 = "",
    params: []const []const u8,
    body: *Node,
    is_expr_body: bool = false,
};

/// A unified AST node for the v1 subset. Expressions and statements share one
/// union because the tree-walk interpreter evaluates both to a `Value`
/// (statements generally produce `undefined`, except expression statements
/// which carry the completion value JSEvaluateScript returns).
pub const Node = union(enum) {
    // expressions
    number: f64,
    string: []const u8,
    boolean: bool,
    null_lit,
    undefined_lit,
    identifier: []const u8,
    unary: struct { op: UnaryOp, operand: *Node },
    binary: struct { op: BinaryOp, left: *Node, right: *Node },
    logical: struct { op: LogicalOp, left: *Node, right: *Node },
    assign: struct { name: []const u8, value: *Node },
    conditional: struct { cond: *Node, consequent: *Node, alternate: *Node },
    function: *FunctionNode, // function/arrow expression -> a function value
    call: struct { callee: *Node, args: []*Node },

    // statements
    var_decl: struct { kind: DeclKind, name: []const u8, init: ?*Node },
    func_decl: *FunctionNode, // `function name(...) {...}` -> binds name
    return_stmt: ?*Node,
    expr_stmt: *Node,
    block: []*Node,
    if_stmt: struct { cond: *Node, consequent: *Node, alternate: ?*Node },
    while_stmt: struct { cond: *Node, body: *Node },
    program: []*Node,
};
