const std = @import("std");

pub const UnaryOp = enum { neg, pos, not, typeof, bit_not };

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
    instanceof,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,
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

/// One `key: value` entry in an object literal. v1 keys are static strings
/// (identifier, string-literal, or numeric-literal keys, all stored as text).
pub const Property = struct {
    key: []const u8,
    value: *Node,
};

/// A `try { ... } catch (e) { ... } finally { ... }` statement. `catch_param`
/// is null for the optional-binding form (`catch { ... }`); `catch_block` and
/// `finally_block` are independently optional (at least one is present).
pub const TryNode = struct {
    block: *Node,
    catch_param: ?[]const u8,
    catch_block: ?*Node,
    finally_block: ?*Node,
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
    this_expr,
    unary: struct { op: UnaryOp, operand: *Node },
    /// `++x` / `x++` / `--x` / `x--`. `inc` selects +1 vs -1, `prefix` selects
    /// whether the expression yields the new (prefix) or old (postfix) value.
    update: struct { inc: bool, prefix: bool, target: *Node },
    binary: struct { op: BinaryOp, left: *Node, right: *Node },
    logical: struct { op: LogicalOp, left: *Node, right: *Node },
    assign: struct { target: *Node, value: *Node },
    conditional: struct { cond: *Node, consequent: *Node, alternate: *Node },
    function: *FunctionNode, // function/arrow expression -> a function value
    call: struct { callee: *Node, args: []*Node },
    new_expr: struct { callee: *Node, args: []*Node },
    /// `object.property` (computed == null) or `object[computed]`.
    member: struct { object: *Node, property: []const u8 = "", computed: ?*Node = null },
    object_lit: []Property,
    array_lit: []*Node,

    // statements
    var_decl: struct { kind: DeclKind, name: []const u8, init: ?*Node },
    func_decl: *FunctionNode, // `function name(...) {...}` -> binds name
    return_stmt: ?*Node,
    throw_stmt: *Node,
    try_stmt: *TryNode,
    break_stmt,
    continue_stmt,
    expr_stmt: *Node,
    block: []*Node,
    if_stmt: struct { cond: *Node, consequent: *Node, alternate: ?*Node },
    while_stmt: struct { cond: *Node, body: *Node },
    for_stmt: struct { init: ?*Node, cond: ?*Node, update: ?*Node, body: *Node },
    program: []*Node,
};
