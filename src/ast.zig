const std = @import("std");

pub const UnaryOp = enum { neg, pos, not, typeof, bit_not, void_op, to_string };

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
    in_op,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,
};

pub const LogicalOp = enum { @"and", @"or", nullish };

pub const DeclKind = enum { @"var", let, @"const" };

/// Shared shape for function declarations, function expressions, and arrow
/// functions. `is_expr_body` is true for concise arrow bodies (`x => x + 1`),
/// where `body` is an expression rather than a block.
/// A function parameter: a name, an optional default value (`a = 1`), and a
/// rest flag (`...rest`, which must be the last parameter).
pub const Param = struct {
    name: []const u8,
    default: ?*Node = null,
    is_rest: bool = false,
    /// A destructuring pattern parameter (`function f({a}, [b])`); when set,
    /// `name` is empty and the argument is bound against this pattern.
    pattern: ?*Node = null,
};

/// One property in an object destructuring pattern: `{ key: target = default }`.
/// `key_expr` non-null means a computed key. `target` is an identifier or a
/// nested pattern.
pub const ObjPatProp = struct {
    key: []const u8 = "",
    key_expr: ?*Node = null,
    target: *Node,
    default: ?*Node = null,
};

/// One element in an array destructuring pattern: `target = default` (null
/// `target` is an elision / hole).
pub const ArrPatElem = struct {
    target: ?*Node = null,
    default: ?*Node = null,
};

pub const FunctionNode = struct {
    name: []const u8 = "",
    params: []const Param,
    body: *Node,
    /// Exact source text of the function definition (first token through its
    /// closing `}` / concise-body expression), for `Function.prototype.toString`.
    /// Empty when not captured (toString then falls back to native syntax).
    source: []const u8 = "",
    is_expr_body: bool = false,
    /// Arrow functions don't get their own `arguments` (or `this`).
    is_arrow: bool = false,
    /// Explicit named function expressions have an internal immutable self-name
    /// binding. Method definitions and NamedEvaluation only set Function.name.
    has_name_binding: bool = false,
    /// `function*` / `*method()` — calling it returns a generator object whose
    /// body runs lazily on the suspendable VM.
    is_generator: bool = false,
    /// `async function` / `async () => …` / `async method()` — and, combined
    /// with `is_generator`, an async generator (`async function*`).
    is_async: bool = false,
    /// Strict-mode code: a `"use strict"` directive prologue, lexically inside
    /// strict code, or a class member (always strict). Gates sloppy-only
    /// behaviors like `this`-substitution.
    is_strict: bool = false,
};

/// A `class` member: a method (`func` is a `.function` node) or a field
/// (`is_field`, with an optional `field_init`). `is_ctor` marks the
/// `constructor`; `is_static` marks `static` members; computed names live in
/// `key_expr`.
pub const ClassMember = struct {
    key: []const u8 = "",
    key_expr: ?*Node = null,
    func: ?*Node = null,
    field_init: ?*Node = null,
    is_static: bool = false,
    is_ctor: bool = false,
    is_field: bool = false,
    accessor: AccessorKind = .none,
    /// `static { ... }` initialization block (run at class definition with
    /// `this` = the class).
    static_block: ?*Node = null,
};

/// Accessor flavor of an object-literal property or class member.
pub const AccessorKind = enum { none, get, set };

/// One entry in an object literal. The key is either a static string
/// (identifier / string / numeric literal, in `key`) or a computed expression
/// (`{ [expr]: v }`, in `key_expr`). `value` is the property value (a function
/// node for method shorthand). `accessor` marks `get`/`set` (then `value` is the
/// getter/setter function).
pub const Property = struct {
    key: []const u8 = "",
    key_expr: ?*Node = null,
    value: *Node,
    accessor: AccessorKind = .none,
    /// `{ ...expr }` spread property: copy `value`'s own enumerable properties
    /// into the object being built (`key`/`accessor` unused).
    is_spread: bool = false,
};

/// One `case <test>:` (or `default:` when `test` is null) clause of a switch.
/// `body` is the statement list that runs from this clause (with fall-through).
pub const SwitchCase = struct {
    /// null for the `default:` clause.
    @"test": ?*Node,
    body: []*Node,
};

/// A `try { ... } catch (e) { ... } finally { ... }` statement. `catch_param`
/// is null for the optional-binding form (`catch { ... }`); `catch_block` and
/// `finally_block` are independently optional (at least one is present).
pub const TryNode = struct {
    block: *Node,
    /// The `catch (binding)` target — an identifier or destructuring pattern.
    /// Null for the optional-binding form (`catch { ... }`).
    catch_param: ?*Node,
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
    /// A `123n` BigInt literal (exact `i128` value).
    bigint_lit: i128,
    string: []const u8,
    boolean: bool,
    null_lit,
    undefined_lit,
    /// An array-literal elision (`[1, , 3]`) — a hole, not an `undefined` value.
    elision,
    identifier: []const u8,
    this_expr,
    /// `new.target` — the constructor when invoked via `new`, else undefined.
    new_target_expr,
    unary: struct { op: UnaryOp, operand: *Node },
    /// `delete operand` — removes an own property; evaluates to a boolean.
    delete_expr: *Node,
    /// `++x` / `x++` / `--x` / `x--`. `inc` selects +1 vs -1, `prefix` selects
    /// whether the expression yields the new (prefix) or old (postfix) value.
    update: struct { inc: bool, prefix: bool, target: *Node },
    binary: struct { op: BinaryOp, left: *Node, right: *Node },
    logical: struct { op: LogicalOp, left: *Node, right: *Node },
    /// The comma operator: evaluate `first` (discarded), then `second` (result).
    sequence: struct { first: *Node, second: *Node },
    assign: struct { target: *Node, value: *Node },
    conditional: struct { cond: *Node, consequent: *Node, alternate: *Node },
    function: *FunctionNode, // function/arrow expression -> a function value
    /// `yield [expr]` / `yield* expr` — only valid inside a generator body.
    /// `delegate` marks `yield*`. Evaluates to the value passed to the next
    /// `.next(v)` resume.
    yield_expr: struct { argument: ?*Node = null, delegate: bool = false },
    /// `await expr` — only valid inside an async function body.
    await_expr: struct { argument: *Node },
    class_expr: struct { name: []const u8, superclass: ?*Node, members: []ClassMember, source: []const u8 = "" },
    /// `super(args)` — call the superclass constructor on the current `this`.
    super_call: []*Node,
    /// `super.prop` / `super[expr]` — look up on the home object's prototype.
    super_member: struct { property: []const u8 = "", computed: ?*Node = null },
    call: struct { callee: *Node, args: []*Node, optional: bool = false },
    new_expr: struct { callee: *Node, args: []*Node },
    /// A tagged template `tag`a${x}b`` — calls `tag(strings, ...exprs)` where
    /// `strings` is the cooked-string array (with a `raw` array of the
    /// unescaped text). `cooked`/`raw` have one more element than `exprs`.
    tagged_template: struct { tag: *Node, cooked: [][]const u8, raw: [][]const u8, exprs: []*Node },
    /// `object.property` (computed == null) or `object[computed]`. `optional`
    /// marks `?.` access (short-circuits the chain when the object is nullish).
    member: struct { object: *Node, property: []const u8 = "", computed: ?*Node = null, optional: bool = false },
    /// Root of an optional chain (`a?.b.c`): catches the short-circuit and
    /// yields `undefined`.
    optional_chain: *Node,
    object_lit: []Property,
    array_lit: []*Node,
    regex_literal: struct { pattern: []const u8, flags: []const u8 },
    /// A `...expr` spread element, only valid inside an array literal or an
    /// argument list; the interpreter expands its iterable in place.
    spread: *Node,
    /// Destructuring binding patterns (used as a declaration/assignment target,
    /// never evaluated as an expression). `rest` names a `...rest` binding.
    obj_pattern: struct { props: []ObjPatProp, rest: ?[]const u8 },
    arr_pattern: struct { elems: []ArrPatElem, rest: ?*Node },

    // statements
    // `dispose`: 0 = ordinary declaration, 1 = `using` (sync), 2 = `await using`.
    var_decl: struct { kind: DeclKind, name: []const u8, init: ?*Node, dispose: u8 = 0 },
    destructure_decl: struct { kind: DeclKind, pattern: *Node, init: *Node },
    func_decl: *FunctionNode, // `function name(...) {...}` -> binds name
    return_stmt: ?*Node,
    throw_stmt: *Node,
    try_stmt: *TryNode,
    break_stmt: ?[]const u8, // optional target label
    continue_stmt: ?[]const u8,
    labeled_stmt: struct { label: []const u8, body: *Node },
    expr_stmt: *Node,
    block: []*Node,
    /// A transparent group of statements that does NOT open a new scope — used
    /// for multi-declarator declarations (`let a = 1, b = 2`), unlike `block`.
    decl_group: []*Node,
    if_stmt: struct { cond: *Node, consequent: *Node, alternate: ?*Node },
    while_stmt: struct { cond: *Node, body: *Node },
    do_while_stmt: struct { body: *Node, cond: *Node },
    for_stmt: struct { init: ?*Node, cond: ?*Node, update: ?*Node, body: *Node },
    /// `for (decl_kind target of/in iterable) body`. `decl_kind` null means the
    /// binding `target` is an existing variable/member (assigned, not declared);
    /// `target` may be an identifier, a destructuring pattern, or (for the
    /// assignment form) a member expression. `is_of` picks `for-of` (values) vs
    /// `for-in` (keys).
    for_in: struct { decl_kind: ?DeclKind, target: *Node, iterable: *Node, body: *Node, is_of: bool, is_await: bool = false },
    switch_stmt: struct { disc: *Node, cases: []SwitchCase },
    with_stmt: struct { obj: *Node, body: *Node },
    /// `import ... from "spec"` / `import "spec"`. `entries` carries each binding
    /// the import introduces (default/namespace/named); empty for a bare
    /// side-effect import.
    import_decl: struct { specifier: []const u8, entries: []ImportEntry },
    /// An `export` declaration in one of its forms (see `ExportNode`).
    export_decl: *ExportNode,
    /// `import(specifier)` / `import(specifier, options)` — dynamic import; an
    /// expression that evaluates to a promise for the module namespace.
    import_call: struct { specifier: *Node, options: ?*Node = null },
    /// `import.meta` — the meta-object of the surrounding module.
    import_meta,
    program: []*Node,
};

/// One binding introduced by an `import` declaration.
///   `import d from "m"`            → { imported: "default",  local: "d" }
///   `import * as ns from "m"`      → { imported: "*",        local: "ns" }
///   `import { a as b } from "m"`   → { imported: "a",        local: "b" }
pub const ImportEntry = struct {
    imported: []const u8,
    local: []const u8,
};

/// An `export` declaration. Exactly one shape is populated:
///   `export <var/let/const/function/class>`  → `declaration` set (also a local binding).
///   `export default <expr|decl>`             → `default_expr` set.
///   `export { a, b as c }`                   → `entries` set, `from` empty.
///   `export { a as b } from "m"`             → `entries` set, `from` set (re-export).
///   `export * from "m"`                      → `star` true, `from` set.
///   `export * as ns from "m"`                → `star` true, `star_as` set, `from` set.
pub const ExportNode = struct {
    declaration: ?*Node = null,
    default_expr: ?*Node = null,
    /// For `export default function f(){}` / `class C{}`: the local name bound,
    /// so the declaration is hoisted/bound in addition to the "default" export.
    default_name: []const u8 = "",
    entries: []ExportEntry = &.{},
    from: []const u8 = "",
    star: bool = false,
    star_as: []const u8 = "",
};

/// One name exported by an `export { ... }` clause.
///   `export { a }`              → { local: "a", exported: "a" }
///   `export { a as b }`         → { local: "a", exported: "b" }
///   `export { a as b } from "m"`→ { imported: "a", exported: "b" } (local empty)
pub const ExportEntry = struct {
    local: []const u8 = "",
    imported: []const u8 = "",
    exported: []const u8,
};
