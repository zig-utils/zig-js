//! AST → bytecode compiler for the tier-1 VM.
//!
//! Lowers the subset of the AST the VM executes directly. Anything outside that
//! subset (`throw`/`try`, computed method calls, member `++`/`--`) returns
//! `error.Unsupported`, which the Context treats as a signal to run the whole
//! program on the tree-walker instead. That keeps conformance flat while the
//! VM's coverage grows — the compiler is widened one node at a time, never the
//! semantics.
//!
//! Variable resolution happens here, at compile time: a function's parameters
//! and (function-scoped) declarations are assigned frame **slot** indices,
//! captured names become `(depth, slot)` **upvalues**, and anything not found in
//! an enclosing function is a **global** resolved by name against the
//! Environment. Top-level program variables are globals (they persist across
//! `evaluate` calls, like a real global object). Lexical slots carry explicit
//! TDZ/immutability checks; compile-time lexical scopes assign distinct slots to
//! same-named block bindings in the shared activation frame, while captured loop
//! heads use per-iteration declarative environments.

const std = @import("std");
const ast = @import("ast.zig");
const bc = @import("bytecode.zig");

const Node = ast.Node;
const Chunk = bc.Chunk;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const CompileError = error{ Unsupported, OutOfMemory };

/// Whether the result of a top-level expression statement becomes the program's
/// completion value (`program`) or is discarded (`function`).
const Mode = enum { program, function };

const Loop = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    continues: std.ArrayListUnmanaged(usize) = .empty,
    label: ?[]const u8 = null,
    /// A labeled non-loop statement is breakable but not continuable.
    is_loop: bool = true,
    /// A `switch` is breakable but not continuable: `break` targets it, but
    /// `continue` skips past it to the nearest enclosing loop.
    is_switch: bool = false,
    /// A label wrapper directly labels an iteration statement (possibly through
    /// more labels), so `continue label` resolves to that statement's loop.
    labels_iteration: bool = false,
    /// The `finally_depth` in effect where this loop/switch was entered. A
    /// `break`/`continue` targeting it needs an `abrupt_*` unwind only when it
    /// CROSSES a finally — i.e. the current finally_depth is deeper than this one.
    /// A loop that lives entirely inside a finally (same depth) breaks with a
    /// plain jump, so it does not disturb that finally's in-flight completion.
    finally_depth: u32 = 0,
    /// Activation-local environment depth at the target. A jump from a deeper
    /// repeated-body/block environment unwinds to this depth before resuming.
    environment_depth: u32 = 0,
};

const SlotBinding = struct {
    slot: u32,
    lexical: bool = false,
    immutable: bool = false,
    tdz_checked: bool = false,
    /// Sloppy simple-parameter binding whose storage is shared with one live
    /// arguments [[ParameterMap]] entry. Dedicated bytecodes keep the ordinary
    /// frame-slot hot path branch-free.
    mapped_parameter: bool = false,
    /// Captured loop-head lexicals live in a real declarative Environment
    /// Record so CreatePerIterationEnvironment can give closures fresh cells.
    /// They still participate in static name resolution, but emit name-based
    /// environment operations instead of frame-slot operations.
    environment: bool = false,
};

/// A function's local namespace: name → frame slot. Lexical bindings retain
/// their TDZ/immutability kind so identifier loads and assignments select the
/// checked opcodes; declarations themselves still use the unchecked store that
/// performs InitializeBinding.
const FnScope = struct {
    parent: ?*FnScope,
    /// Runtime Environment Records between this frame and its parent frame at
    /// closure creation. Frame slots are not present in `vm.env`, so dynamic
    /// name resolution must stop at this boundary before falling back to an
    /// enclosing non-deletable slot.
    parent_environment_depth: u32 = 0,
    names: std.StringHashMapUnmanaged(SlotBinding) = .{},
    lexical_scopes: std.ArrayListUnmanaged(*std.StringHashMapUnmanaged(SlotBinding)) = .empty,
    slot_names: std.ArrayListUnmanaged([]const u8) = .empty,
    count: u32 = 0,
    lexical_slots: std.ArrayListUnmanaged(u32) = .empty,
    tdz_checks: bool = false,

    fn addLocal(self: *FnScope, arena: std.mem.Allocator, name: []const u8, lexical: bool, immutable: bool) CompileError!u32 {
        if (self.names.get(name)) |binding| return binding.slot;
        return self.addBinding(arena, &self.names, name, lexical, immutable);
    }

    fn addBinding(self: *FnScope, arena: std.mem.Allocator, bindings: *std.StringHashMapUnmanaged(SlotBinding), name: []const u8, lexical: bool, immutable: bool) CompileError!u32 {
        const slot = self.count;
        const tdz_checked = lexical and self.tdz_checks;
        try bindings.put(arena, name, .{ .slot = slot, .lexical = lexical, .immutable = immutable, .tdz_checked = tdz_checked });
        if (tdz_checked) try self.lexical_slots.append(arena, slot);
        try self.slot_names.append(arena, name);
        self.count += 1;
        return slot;
    }

    fn pushLexicalScope(self: *FnScope, arena: std.mem.Allocator) CompileError!void {
        const bindings = try arena.create(std.StringHashMapUnmanaged(SlotBinding));
        bindings.* = .empty;
        try self.lexical_scopes.append(arena, bindings);
    }

    fn popLexicalScope(self: *FnScope) void {
        _ = self.lexical_scopes.pop();
    }

    fn currentLexicalScope(self: *FnScope) *std.StringHashMapUnmanaged(SlotBinding) {
        std.debug.assert(self.lexical_scopes.items.len != 0);
        return self.lexical_scopes.items[self.lexical_scopes.items.len - 1];
    }

    fn addLexical(self: *FnScope, arena: std.mem.Allocator, name: []const u8, immutable: bool) CompileError!u32 {
        const bindings = self.currentLexicalScope();
        if (bindings.get(name)) |binding| return binding.slot;
        return self.addBinding(arena, bindings, name, true, immutable);
    }

    fn addLexicalChecked(self: *FnScope, arena: std.mem.Allocator, name: []const u8, immutable: bool) CompileError!u32 {
        const bindings = self.currentLexicalScope();
        const slot = try self.addLexical(arena, name, immutable);
        const binding = bindings.getPtr(name).?;
        if (!binding.tdz_checked) {
            binding.tdz_checked = true;
            try self.lexical_slots.append(arena, slot);
        }
        return slot;
    }

    fn addEnvironmentLexical(self: *FnScope, arena: std.mem.Allocator, name: []const u8, immutable: bool) CompileError!void {
        const bindings = self.currentLexicalScope();
        if (bindings.contains(name)) return;
        try bindings.put(arena, name, .{
            .slot = 0,
            .lexical = true,
            .immutable = immutable,
            .tdz_checked = true,
            .environment = true,
        });
    }

    fn get(self: *const FnScope, name: []const u8) ?SlotBinding {
        var index = self.lexical_scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.lexical_scopes.items[index].get(name)) |binding| return binding;
        }
        return self.names.get(name);
    }
};

fn retainDebugLocalNames(arena: std.mem.Allocator, chunk: *Chunk, scope: *const FnScope) CompileError!void {
    chunk.debug_local_names = try arena.dupe([]const u8, scope.slot_names.items);
}

/// Every ordinary function that can observe its own arguments object receives
/// one activation-local slot. Nested arrows resolve that owner slot like any
/// other upvalue; arrows never manufacture an arguments binding themselves.
fn addArgumentsSlot(
    arena: std.mem.Allocator,
    scope: *FnScope,
    fnode: *const ast.FunctionNode,
) CompileError!?u32 {
    if (fnode.is_arrow or !fnode.uses_arguments) return null;
    // FunctionDeclarationInstantiation suppresses the implicit object when a
    // formal already owns the `arguments` binding.
    for (fnode.params) |param|
        if (param.pattern == null and std.mem.eql(u8, param.name, "arguments")) return null;
    return try scope.addLocal(arena, "arguments", false, false);
}

/// Mark each distinct sloppy simple formal and freeze its rightmost arguments
/// index. ECMA-262 CreateMappedArgumentsObject scans formals right-to-left: an
/// earlier duplicate remains an ordinary arguments element and only the last
/// occurrence aliases the single parameter binding.
fn configureMappedParameters(
    arena: std.mem.Allocator,
    scope: *FnScope,
    fnode: *const ast.FunctionNode,
    arguments_slot: ?u32,
) CompileError![]const u32 {
    if (fnode.is_arrow or fnode.is_strict or arguments_slot == null or fnode.params.len == 0) return &.{};

    const unmapped = std.math.maxInt(u32);
    const indices = try arena.alloc(u32, scope.count);
    @memset(indices, unmapped);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var index = fnode.params.len;
    while (index > 0) {
        index -= 1;
        const param = fnode.params[index];
        std.debug.assert(param.default == null and !param.is_rest and param.pattern == null);
        if (seen.contains(param.name)) continue;
        try seen.put(arena, param.name, {});
        const binding = scope.names.getPtr(param.name) orelse return error.Unsupported;
        binding.mapped_parameter = true;
        indices[binding.slot] = @intCast(index);
    }
    return indices;
}

/// Expression lowering may append compiler temporaries after parameter bindings
/// have been marked. Extend the immutable slot map to the final frame width so
/// VM validation covers every slot while ordinary non-mapped bytecodes remain
/// branch-free.
fn finalizeMappedParameterIndices(
    arena: std.mem.Allocator,
    scope: *const FnScope,
    initial: []const u32,
) CompileError![]const u32 {
    if (initial.len == 0 or initial.len == scope.count) return initial;
    std.debug.assert(initial.len < scope.count);
    const indices = try arena.alloc(u32, scope.count);
    @memset(indices, std.math.maxInt(u32));
    @memcpy(indices[0..initial.len], initial);
    return indices;
}

/// Whether a node embeds a `yield` reachable without crossing a function
/// boundary. Loop-head assignment patterns use this to require resumable native
/// lowering instead of the Environment-only `bind_pattern` path.
fn nodeHasYield(node: *const ast.Node) bool {
    return switch (node.*) {
        .yield_expr => true,
        .function => false, // a nested function/arrow is its own yield scope
        .unary => |u| nodeHasYield(u.operand),
        .delete_expr => |d| nodeHasYield(d),
        .update => |u| nodeHasYield(u.target),
        .binary => |b| nodeHasYield(b.left) or nodeHasYield(b.right),
        .logical => |b| nodeHasYield(b.left) or nodeHasYield(b.right),
        .sequence => |s| nodeHasYield(s.first) or nodeHasYield(s.second),
        .assign => |a| nodeHasYield(a.target) or nodeHasYield(a.value),
        .op_assign => |a| nodeHasYield(a.target) or nodeHasYield(a.value),
        .logical_assign => |a| nodeHasYield(a.target) or nodeHasYield(a.value),
        .conditional => |c| nodeHasYield(c.cond) or nodeHasYield(c.consequent) or nodeHasYield(c.alternate),
        .await_expr => |a| nodeHasYield(a.argument),
        .import_call => |ic| nodeHasYield(ic.specifier) or (ic.options != null and nodeHasYield(ic.options.?)),
        .optional_chain => |c| nodeHasYield(c),
        .spread => |s| nodeHasYield(s),
        .member => |m| nodeHasYield(m.object) or (m.computed != null and nodeHasYield(m.computed.?)),
        .super_member => |m| (m.computed != null and nodeHasYield(m.computed.?)),
        .call => |c| blk: {
            if (nodeHasYield(c.callee)) break :blk true;
            for (c.args) |a| if (nodeHasYield(a)) break :blk true;
            break :blk false;
        },
        .new_expr => |c| blk: {
            if (nodeHasYield(c.callee)) break :blk true;
            for (c.args) |a| if (nodeHasYield(a)) break :blk true;
            break :blk false;
        },
        .tagged_template => |t| blk: {
            if (nodeHasYield(t.tag)) break :blk true;
            for (t.exprs) |e| if (nodeHasYield(e)) break :blk true;
            break :blk false;
        },
        .array_lit => |elems| blk: {
            for (elems) |e| if (nodeHasYield(e)) break :blk true;
            break :blk false;
        },
        .object_lit => |props| blk: {
            for (props) |p| {
                if (p.key_expr) |ke| if (nodeHasYield(ke)) break :blk true;
                if (nodeHasYield(p.value)) break :blk true;
            }
            break :blk false;
        },
        .arr_pattern => |p| blk: {
            for (p.elems) |e| {
                if (e.target) |t| if (nodeHasYield(t)) break :blk true;
                if (e.default) |d| if (nodeHasYield(d)) break :blk true;
            }
            if (p.rest) |r| if (nodeHasYield(r)) break :blk true;
            break :blk false;
        },
        .obj_pattern => |p| blk: {
            for (p.props) |pp| {
                if (pp.key_expr) |ke| if (nodeHasYield(ke)) break :blk true;
                if (pp.default) |d| if (nodeHasYield(d)) break :blk true;
                if (nodeHasYield(pp.target)) break :blk true;
            }
            if (p.rest) |rest| if (nodeHasYield(rest)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Whether a loop `body` declares a block-scoped (`let`/`const`) binding that a
/// closure in the body captures — which needs a fresh per-iteration binding the
/// VM's single flat frame slot can't provide (all iterations' closures would
/// share the last value). Descends into blocks/if/try/switch/labeled but NOT into
/// nested functions or nested loops (which manage their own body bindings).
/// Captured declarations can use a declarative environment at the block that
/// owns them. Nested loops establish their own repeated-body root.
fn repeatedBodyCapturesSupported(node: *const ast.Node, captures: *const RepeatedBodyCaptures) bool {
    return switch (node.*) {
        .var_decl => true,
        .decl_group => |declarations| blk: {
            for (declarations) |declaration|
                if (!repeatedBodyCapturesSupported(declaration, captures)) break :blk false;
            break :blk true;
        },
        .destructure_decl => |declaration| blk: {
            const captured = declaration.kind != .@"var" and captures.patternCaptured(declaration.pattern);
            break :blk !captured or patternSupportsEnvironmentNode(declaration.pattern);
        },
        .block => |statements| blk: {
            for (statements) |statement| if (!repeatedBodyCapturesSupported(statement, captures)) break :blk false;
            break :blk true;
        },
        .if_stmt => |statement| repeatedBodyCapturesSupported(statement.consequent, captures) and
            (if (statement.alternate) |alternate| repeatedBodyCapturesSupported(alternate, captures) else true),
        .labeled_stmt => |statement| repeatedBodyCapturesSupported(statement.body, captures),
        .try_stmt => |statement| blk: {
            const captured_catch = if (statement.catch_param) |catch_param| captures.catchPatternCaptured(catch_param) else false;
            if (captured_catch and !patternSupportsEnvironmentNode(statement.catch_param.?)) break :blk false;
            break :blk repeatedBodyCapturesSupported(statement.block, captures) and
                (if (statement.catch_block) |catch_block| repeatedBodyCapturesSupported(catch_block, captures) else true) and
                (if (statement.finally_block) |finally_block| repeatedBodyCapturesSupported(finally_block, captures) else true);
        },
        .switch_stmt => |statement| blk: {
            for (statement.cases) |case| for (case.body) |case_statement|
                if (!repeatedBodyCapturesSupported(case_statement, captures)) break :blk false;
            break :blk true;
        },
        // Nested iteration statements compile their own body with a new root.
        .while_stmt, .do_while_stmt, .for_stmt, .for_in => true,
        else => true,
    };
}

fn patternSupportsEnvironmentNode(pattern: *const ast.Node) bool {
    return switch (pattern.*) {
        .identifier => true,
        .obj_pattern => |object| blk: {
            for (object.props) |property| if (!patternSupportsEnvironmentNode(property.target)) break :blk false;
            if (object.rest) |rest| if (!patternSupportsEnvironmentNode(rest)) break :blk false;
            break :blk true;
        },
        .arr_pattern => |array| blk: {
            for (array.elems) |element| if (element.target) |target|
                if (!patternSupportsEnvironmentNode(target)) break :blk false;
            if (array.rest) |rest| if (!patternSupportsEnvironmentNode(rest)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

const CapturedBindingReferences = struct {
    names: *const std.StringHashMapUnmanaged(void),
};

/// Set-valued capture classification must visit the complete AST even after the
/// first match. Returning false after recording prevents the generic exhaustive
/// walk from short-circuiting while pre-reserved storage keeps matching infallible.
const RecordingCapturedBindingReferences = struct {
    names: *std.StringHashMapUnmanaged(bool),
    captured_count: *usize,
};

const LoopBindingNames = struct {
    single: ?[]const u8 = null,
    multiple: std.StringHashMapUnmanaged(void) = .{},

    fn add(self: *LoopBindingNames, arena: std.mem.Allocator, name: []const u8) CompileError!void {
        if (self.multiple.count() != 0) {
            try self.multiple.put(arena, name, {});
            return;
        }
        if (self.single) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
            try self.multiple.put(arena, existing, {});
            try self.multiple.put(arena, name, {});
            return;
        }
        self.single = name;
    }

    fn referencedByIn(self: *const LoopBindingNames, node: *const ast.Node, in_fn: bool) bool {
        if (self.multiple.count() == 0)
            return if (self.single) |name| nameRefInClosure(node, name, in_fn) else false;
        return nameRefInClosure(node, CapturedBindingReferences{ .names = &self.multiple }, in_fn);
    }

    fn referencedBy(self: *const LoopBindingNames, node: *const ast.Node) bool {
        return self.referencedByIn(node, false);
    }
};

const RepeatedBodyNameCaptures = struct {
    single: ?[]const u8 = null,
    single_captured: bool = false,
    multiple: std.StringHashMapUnmanaged(bool) = .{},
    captured_count: usize = 0,

    fn add(self: *RepeatedBodyNameCaptures, arena: std.mem.Allocator, name: []const u8) CompileError!void {
        if (self.multiple.count() != 0) {
            try self.multiple.put(arena, name, false);
            return;
        }
        if (self.single) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
            try self.multiple.put(arena, existing, false);
            try self.multiple.put(arena, name, false);
            return;
        }
        self.single = name;
    }

    fn classify(self: *RepeatedBodyNameCaptures, node: *const ast.Node) void {
        if (self.multiple.count() == 0) {
            self.single_captured = if (self.single) |name| nameRefInClosure(node, name, false) else false;
            return;
        }
        _ = nameRefInClosure(node, RecordingCapturedBindingReferences{
            .names = &self.multiple,
            .captured_count = &self.captured_count,
        }, false);
    }

    fn captures(self: *const RepeatedBodyNameCaptures, name: []const u8) bool {
        if (self.multiple.count() == 0)
            return self.single_captured and self.single != null and std.mem.eql(u8, self.single.?, name);
        return self.multiple.get(name) orelse false;
    }

    fn any(self: *const RepeatedBodyNameCaptures) bool {
        return self.single_captured or self.captured_count != 0;
    }
};

const RepeatedBodyCaptures = struct {
    bindings: RepeatedBodyNameCaptures = .{},
    captured_catch_patterns: std.AutoHashMapUnmanaged(*const ast.Node, void) = .{},

    fn init(arena: std.mem.Allocator, root: *const ast.Node) CompileError!RepeatedBodyCaptures {
        var captures: RepeatedBodyCaptures = .{};
        try collectRepeatedBodyBindings(arena, root, &captures);
        captures.bindings.classify(root);
        return captures;
    }

    fn nameCaptured(self: *const RepeatedBodyCaptures, name: []const u8) bool {
        return self.bindings.captures(name);
    }

    fn patternCaptured(self: *const RepeatedBodyCaptures, pattern: *const ast.Node) bool {
        return switch (pattern.*) {
            .identifier => |name| self.nameCaptured(name),
            .obj_pattern => |object| blk: {
                for (object.props) |property| if (self.patternCaptured(property.target)) break :blk true;
                if (object.rest) |rest| if (self.patternCaptured(rest)) break :blk true;
                break :blk false;
            },
            .arr_pattern => |array| blk: {
                for (array.elems) |element| if (element.target) |target|
                    if (self.patternCaptured(target)) break :blk true;
                if (array.rest) |rest| if (self.patternCaptured(rest)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn catchPatternCaptured(self: *const RepeatedBodyCaptures, pattern: *const ast.Node) bool {
        return self.captured_catch_patterns.contains(pattern);
    }

    fn any(self: *const RepeatedBodyCaptures) bool {
        return self.bindings.any() or self.captured_catch_patterns.count() != 0;
    }
};

fn collectPatternBindingNames(arena: std.mem.Allocator, pattern: *const ast.Node, names: anytype) CompileError!void {
    switch (pattern.*) {
        .identifier => |name| try names.add(arena, name),
        .obj_pattern => |object| {
            for (object.props) |property| try collectPatternBindingNames(arena, property.target, names);
            if (object.rest) |rest| try collectPatternBindingNames(arena, rest, names);
        },
        .arr_pattern => |array| {
            for (array.elems) |element| if (element.target) |target|
                try collectPatternBindingNames(arena, target, names);
            if (array.rest) |rest| try collectPatternBindingNames(arena, rest, names);
        },
        else => {},
    }
}

fn collectLoopBindingNames(arena: std.mem.Allocator, node: *const ast.Node, names: *LoopBindingNames) CompileError!void {
    switch (node.*) {
        .var_decl => |declaration| if (declaration.kind != .@"var") try names.add(arena, declaration.name),
        .destructure_decl => |declaration| if (declaration.kind != .@"var")
            try collectPatternBindingNames(arena, declaration.pattern, names),
        .decl_group => |declarations| for (declarations) |declaration|
            try collectLoopBindingNames(arena, declaration, names),
        else => {},
    }
}

fn forLoopCapturesLexical(arena: std.mem.Allocator, init_node: *const ast.Node, cond: ?*const ast.Node, update: ?*const ast.Node, body: *const ast.Node) CompileError!bool {
    var names: LoopBindingNames = .{};
    try collectLoopBindingNames(arena, init_node, &names);
    return names.referencedBy(init_node) or
        (if (cond) |condition| names.referencedBy(condition) else false) or
        (if (update) |increment| names.referencedBy(increment) else false) or
        names.referencedBy(body);
}

fn patternHasEvaluationExpressions(pattern: *const ast.Node) bool {
    return switch (pattern.*) {
        .identifier => false,
        .obj_pattern => |object| blk: {
            for (object.props) |property| {
                if (property.key_expr != null or property.default != null or patternHasEvaluationExpressions(property.target)) break :blk true;
            }
            if (object.rest) |rest| if (patternHasEvaluationExpressions(rest)) break :blk true;
            break :blk false;
        },
        .arr_pattern => |array| blk: {
            for (array.elems) |element| {
                if (element.default != null) break :blk true;
                if (element.target) |target| if (patternHasEvaluationExpressions(target)) break :blk true;
            }
            if (array.rest) |rest| if (patternHasEvaluationExpressions(rest)) break :blk true;
            break :blk false;
        },
        else => true,
    };
}

fn forOfCapturesLexical(arena: std.mem.Allocator, target: *const ast.Node, var_init: ?*const ast.Node, iterable: *const ast.Node, body: *const ast.Node) CompileError!bool {
    var names: LoopBindingNames = .{};
    try collectPatternBindingNames(arena, target, &names);
    return names.referencedBy(target) or
        (if (var_init) |initializer| names.referencedBy(initializer) else false) or
        names.referencedBy(iterable) or names.referencedBy(body);
}

/// Collect declarations owned by one repeated-body root. Nested loops establish
/// their own root; nested functions contain references but not declarations owned
/// by this iteration. Catch parameters have their own lexical scope, so each is
/// classified once against only its catch block and cached by pattern identity.
fn collectRepeatedBodyBindings(arena: std.mem.Allocator, node: *const ast.Node, captures: *RepeatedBodyCaptures) CompileError!void {
    switch (node.*) {
        .var_decl => |declaration| if (declaration.kind != .@"var")
            try captures.bindings.add(arena, declaration.name),
        .destructure_decl => |declaration| if (declaration.kind != .@"var")
            try collectPatternBindingNames(arena, declaration.pattern, &captures.bindings),
        .decl_group => |declarations| for (declarations) |declaration|
            try collectRepeatedBodyBindings(arena, declaration, captures),
        .block => |statements| for (statements) |statement|
            try collectRepeatedBodyBindings(arena, statement, captures),
        .if_stmt => |statement| {
            try collectRepeatedBodyBindings(arena, statement.consequent, captures);
            if (statement.alternate) |alternate| try collectRepeatedBodyBindings(arena, alternate, captures);
        },
        .labeled_stmt => |statement| try collectRepeatedBodyBindings(arena, statement.body, captures),
        .try_stmt => |statement| {
            try collectRepeatedBodyBindings(arena, statement.block, captures);
            if (statement.catch_block) |catch_block| {
                if (statement.catch_param) |catch_param| {
                    var catch_captures: RepeatedBodyNameCaptures = .{};
                    try collectPatternBindingNames(arena, catch_param, &catch_captures);
                    catch_captures.classify(catch_block);
                    if (catch_captures.any()) try captures.captured_catch_patterns.put(arena, catch_param, {});
                }
                try collectRepeatedBodyBindings(arena, catch_block, captures);
            }
            if (statement.finally_block) |finally_block|
                try collectRepeatedBodyBindings(arena, finally_block, captures);
        },
        .switch_stmt => |statement| for (statement.cases) |case| for (case.body) |case_statement|
            try collectRepeatedBodyBindings(arena, case_statement, captures),
        // Nested iteration statements own their declarations. Their references
        // still participate when the exhaustive root traversal runs below.
        .while_stmt, .do_while_stmt, .for_stmt, .for_in, .function, .func_decl => {},
        else => {},
    }
}

/// Exhaustive identifier-reference walk shared by exact-name capture queries and
/// the set-valued pending-TDZ query. `in_fn` tracks whether the current subtree
/// already sits (transitively) inside a function boundary: loop-capture callers
/// ignore plain body reads, while TDZ callers begin inside the current function.
/// Unlike `nodeHasYield` this descends INTO nested functions. The switch has no
/// `else`, so a new node kind cannot silently become a capture or TDZ false
/// negative. It deliberately ignores shadowing and treats deferred class bodies
/// as closures: over-matching selects checked bytecode or the correct-but-slower
/// tree-walker, never a wrong lowering.
const PendingLexicalReferences = struct {
    bindings: *const std.StringHashMapUnmanaged(Compiler.ShadowBind),
    declared: *const std.StringHashMapUnmanaged(void),
};

fn identifierReferenceMatches(query: anytype, identifier: []const u8) bool {
    return if (comptime @TypeOf(query) == PendingLexicalReferences) pending: {
        const binding = query.bindings.get(identifier) orelse break :pending false;
        break :pending binding.lexical and !query.declared.contains(identifier);
    } else if (comptime @TypeOf(query) == CapturedBindingReferences)
        query.names.contains(identifier)
    else if (comptime @TypeOf(query) == RecordingCapturedBindingReferences) recording: {
        if (query.names.getPtr(identifier)) |captured| if (!captured.*) {
            captured.* = true;
            query.captured_count.* += 1;
        };
        break :recording false;
    } else std.mem.eql(u8, identifier, query);
}

fn nameRefInClosure(node: *const ast.Node, name: anytype, in_fn: bool) bool {
    return switch (node.*) {
        .identifier => |id| in_fn and identifierReferenceMatches(name, id),

        .number, .bigint_lit, .string, .boolean, .null_lit, .undefined_lit, .elision, .this_expr, .new_target_expr, .regex_literal, .import_meta, .import_decl, .break_stmt, .continue_stmt, .debugger_stmt => false,

        // A nested function/arrow (expression or declaration): everything it (and
        // any deeper closure) references is captured — descend with `in_fn = true`.
        .function, .func_decl => |fnode| fnCaptures(fnode, name),

        .unary => |u| nameRefInClosure(u.operand, name, in_fn),
        .delete_expr => |d| nameRefInClosure(d, name, in_fn),
        .update => |u| nameRefInClosure(u.target, name, in_fn),
        .binary => |b| nameRefInClosure(b.left, name, in_fn) or nameRefInClosure(b.right, name, in_fn),
        .logical => |b| nameRefInClosure(b.left, name, in_fn) or nameRefInClosure(b.right, name, in_fn),
        .sequence => |s| nameRefInClosure(s.first, name, in_fn) or nameRefInClosure(s.second, name, in_fn),
        .assign => |a| nameRefInClosure(a.target, name, in_fn) or nameRefInClosure(a.value, name, in_fn),
        .op_assign => |a| nameRefInClosure(a.target, name, in_fn) or nameRefInClosure(a.value, name, in_fn),
        .logical_assign => |a| nameRefInClosure(a.target, name, in_fn) or nameRefInClosure(a.value, name, in_fn),
        .conditional => |c| nameRefInClosure(c.cond, name, in_fn) or nameRefInClosure(c.consequent, name, in_fn) or nameRefInClosure(c.alternate, name, in_fn),
        .yield_expr => |y| y.argument != null and nameRefInClosure(y.argument.?, name, in_fn),
        .await_expr => |a| nameRefInClosure(a.argument, name, in_fn),
        .class_expr => |c| blk: {
            // The superclass and computed member keys evaluate eagerly (current
            // `in_fn`); method bodies, field initializers, and static blocks run
            // deferred and so capture (`in_fn = true`).
            if (c.superclass) |sc| if (nameRefInClosure(sc, name, in_fn)) break :blk true;
            for (c.members) |m| {
                if (m.key_expr) |ke| if (nameRefInClosure(ke, name, in_fn)) break :blk true;
                if (m.func) |f| if (nameRefInClosure(f, name, in_fn)) break :blk true;
                if (m.field_init) |fi| if (nameRefInClosure(fi, name, true)) break :blk true;
                if (m.static_block) |sb| if (nameRefInClosure(sb, name, true)) break :blk true;
            }
            break :blk false;
        },
        .super_call => |args| blk: {
            for (args) |a| if (nameRefInClosure(a, name, in_fn)) break :blk true;
            break :blk false;
        },
        .super_member => |m| m.computed != null and nameRefInClosure(m.computed.?, name, in_fn),
        .call => |c| blk: {
            if (nameRefInClosure(c.callee, name, in_fn)) break :blk true;
            for (c.args) |a| if (nameRefInClosure(a, name, in_fn)) break :blk true;
            break :blk false;
        },
        .new_expr => |c| blk: {
            if (nameRefInClosure(c.callee, name, in_fn)) break :blk true;
            for (c.args) |a| if (nameRefInClosure(a, name, in_fn)) break :blk true;
            break :blk false;
        },
        .tagged_template => |t| blk: {
            if (nameRefInClosure(t.tag, name, in_fn)) break :blk true;
            for (t.exprs) |e| if (nameRefInClosure(e, name, in_fn)) break :blk true;
            break :blk false;
        },
        .member => |m| nameRefInClosure(m.object, name, in_fn) or (m.computed != null and nameRefInClosure(m.computed.?, name, in_fn)),
        .optional_chain => |c| nameRefInClosure(c, name, in_fn),
        .field_init_value => |v| nameRefInClosure(v, name, in_fn),
        .private_field_def => |p| nameRefInClosure(p.value, name, in_fn),
        .object_lit => |props| blk: {
            for (props) |p| {
                if (p.key_expr) |ke| if (nameRefInClosure(ke, name, in_fn)) break :blk true;
                if (nameRefInClosure(p.value, name, in_fn)) break :blk true;
            }
            break :blk false;
        },
        .array_lit => |elems| blk: {
            for (elems) |e| if (nameRefInClosure(e, name, in_fn)) break :blk true;
            break :blk false;
        },
        .spread => |s| nameRefInClosure(s, name, in_fn),
        .obj_pattern => |p| blk: {
            for (p.props) |pp| {
                if (pp.key_expr) |ke| if (nameRefInClosure(ke, name, in_fn)) break :blk true;
                if (nameRefInClosure(pp.target, name, in_fn)) break :blk true;
                if (pp.default) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            }
            if (p.rest) |r| if (nameRefInClosure(r, name, in_fn)) break :blk true;
            break :blk false;
        },
        .arr_pattern => |p| blk: {
            for (p.elems) |e| {
                if (e.target) |t| if (nameRefInClosure(t, name, in_fn)) break :blk true;
                if (e.default) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            }
            if (p.rest) |r| if (nameRefInClosure(r, name, in_fn)) break :blk true;
            break :blk false;
        },
        .var_decl => |d| d.init != null and nameRefInClosure(d.init.?, name, in_fn),
        .destructure_decl => |d| nameRefInClosure(d.pattern, name, in_fn) or nameRefInClosure(d.init, name, in_fn),
        .return_stmt => |r| r != null and nameRefInClosure(r.?, name, in_fn),
        .throw_stmt => |t| nameRefInClosure(t, name, in_fn),
        .try_stmt => |t| blk: {
            if (nameRefInClosure(t.block, name, in_fn)) break :blk true;
            if (t.catch_param) |cp| if (nameRefInClosure(cp, name, in_fn)) break :blk true;
            if (t.catch_block) |cb| if (nameRefInClosure(cb, name, in_fn)) break :blk true;
            if (t.finally_block) |fb| if (nameRefInClosure(fb, name, in_fn)) break :blk true;
            break :blk false;
        },
        .labeled_stmt => |l| nameRefInClosure(l.body, name, in_fn),
        .expr_stmt => |e| nameRefInClosure(e, name, in_fn),
        .block => |stmts| blk: {
            for (stmts) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            break :blk false;
        },
        .decl_group => |stmts| blk: {
            for (stmts) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            break :blk false;
        },
        .program => |stmts| blk: {
            for (stmts) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            break :blk false;
        },
        .if_stmt => |i| nameRefInClosure(i.cond, name, in_fn) or nameRefInClosure(i.consequent, name, in_fn) or (i.alternate != null and nameRefInClosure(i.alternate.?, name, in_fn)),
        .while_stmt => |s| nameRefInClosure(s.cond, name, in_fn) or nameRefInClosure(s.body, name, in_fn),
        .do_while_stmt => |s| nameRefInClosure(s.body, name, in_fn) or nameRefInClosure(s.cond, name, in_fn),
        .for_stmt => |f| blk: {
            if (f.init) |ini| if (nameRefInClosure(ini, name, in_fn)) break :blk true;
            if (f.cond) |c| if (nameRefInClosure(c, name, in_fn)) break :blk true;
            if (f.update) |u| if (nameRefInClosure(u, name, in_fn)) break :blk true;
            break :blk nameRefInClosure(f.body, name, in_fn);
        },
        .for_in => |f| blk: {
            if (nameRefInClosure(f.target, name, in_fn)) break :blk true;
            if (f.var_init) |vi| if (nameRefInClosure(vi, name, in_fn)) break :blk true;
            if (nameRefInClosure(f.iterable, name, in_fn)) break :blk true;
            break :blk nameRefInClosure(f.body, name, in_fn);
        },
        .switch_stmt => |sw| blk: {
            if (nameRefInClosure(sw.disc, name, in_fn)) break :blk true;
            for (sw.cases) |c| {
                if (c.@"test") |t| if (nameRefInClosure(t, name, in_fn)) break :blk true;
                for (c.body) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            }
            break :blk false;
        },
        .with_stmt => |w| nameRefInClosure(w.obj, name, in_fn) or nameRefInClosure(w.body, name, in_fn),
        .export_decl => |e| blk: {
            if (e.declaration) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            if (e.default_expr) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            break :blk false;
        },
        .import_call => |ic| nameRefInClosure(ic.specifier, name, in_fn) or (ic.options != null and nameRefInClosure(ic.options.?, name, in_fn)),
    };
}

/// A nested function/arrow captures `name` if its body — or any parameter default
/// or destructuring-pattern parameter (which execute in the function's own scope)
/// — references it. Always searched with `in_fn = true`.
fn fnCaptures(fnode: *const ast.FunctionNode, name: anytype) bool {
    for (fnode.params) |p| {
        if (p.default) |d| if (nameRefInClosure(d, name, true)) return true;
        if (p.pattern) |pat| if (nameRefInClosure(pat, name, true)) return true;
    }
    return nameRefInClosure(fnode.body, name, true);
}

/// Conservatively, does a statement subtree contain a construct that could leave a
/// `with` block ABRUPTLY (skipping the matching `exit_with`, which would leave the
/// VM's environment pointing at the popped with-record)? `with` bodies that might
/// `yield`/`return`/`throw`/`break`/`continue` are kept on the tree-walker. Stops at
/// nested function boundaries (their control flow is self-contained). Overly strict
/// (a `break` for an inner loop inside the `with` also bails), but always safe.
fn stmtCanEscapeAbruptly(node: *const ast.Node) bool {
    return switch (node.*) {
        .yield_expr, .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => true,
        .function => false,
        .block => |b| blk: {
            for (b) |s| if (stmtCanEscapeAbruptly(s)) break :blk true;
            break :blk false;
        },
        .if_stmt => |i| stmtCanEscapeAbruptly(i.consequent) or (i.alternate != null and stmtCanEscapeAbruptly(i.alternate.?)),
        .while_stmt => |s| stmtCanEscapeAbruptly(s.body),
        .do_while_stmt => |s| stmtCanEscapeAbruptly(s.body),
        .for_stmt => |f| stmtCanEscapeAbruptly(f.body),
        .for_in => |f| stmtCanEscapeAbruptly(f.body),
        .with_stmt => |w| stmtCanEscapeAbruptly(w.body),
        .labeled_stmt => |l| stmtCanEscapeAbruptly(l.body),
        .try_stmt => |t| stmtCanEscapeAbruptly(t.block) or
            (t.catch_block != null and stmtCanEscapeAbruptly(t.catch_block.?)) or
            (t.finally_block != null and stmtCanEscapeAbruptly(t.finally_block.?)),
        .switch_stmt => |sw| blk: {
            for (sw.cases) |c| for (c.body) |s| if (stmtCanEscapeAbruptly(s)) break :blk true;
            break :blk false;
        },
        // An expression statement may embed a `yield` (e.g. `x = yield`).
        else => nodeHasYield(node),
    };
}

fn labeledStatementTargetsIteration(node: *const ast.Node) bool {
    return switch (node.*) {
        .while_stmt, .do_while_stmt, .for_stmt, .for_in => true,
        .labeled_stmt => |statement| labeledStatementTargetsIteration(statement.body),
        else => false,
    };
}

fn stmtContainsFuncDecl(node: *const ast.Node) bool {
    return switch (node.*) {
        .func_decl => true,
        .function => false,
        .block => |b| blk: {
            for (b) |s| if (stmtContainsFuncDecl(s)) break :blk true;
            break :blk false;
        },
        .if_stmt => |i| stmtContainsFuncDecl(i.consequent) or (i.alternate != null and stmtContainsFuncDecl(i.alternate.?)),
        .while_stmt => |s| stmtContainsFuncDecl(s.body),
        .do_while_stmt => |s| stmtContainsFuncDecl(s.body),
        .for_stmt => |f| stmtContainsFuncDecl(f.body),
        .for_in => |f| stmtContainsFuncDecl(f.body),
        .with_stmt => |w| stmtContainsFuncDecl(w.body),
        .labeled_stmt => |l| stmtContainsFuncDecl(l.body),
        .try_stmt => |t| stmtContainsFuncDecl(t.block) or
            (t.catch_block != null and stmtContainsFuncDecl(t.catch_block.?)) or
            (t.finally_block != null and stmtContainsFuncDecl(t.finally_block.?)),
        .switch_stmt => |sw| blk: {
            for (sw.cases) |c| for (c.body) |s| if (stmtContainsFuncDecl(s)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn stmtListContainsNestedFuncDecl(stmts: []*Node) bool {
    for (stmts) |s| switch (s.*) {
        .func_decl => {},
        else => if (stmtContainsFuncDecl(s)) return true,
    };
    return false;
}

/// Whether deferred class member bodies reference any frame-slot name. Computed keys are
/// deliberately excluded: they execute eagerly as VM operations, so closures
/// created there capture frame slots normally. Methods, field initializers, and
/// static blocks execute later through `eval_class` and can only resolve names
/// available through its Environment chain.
fn classDeferredBodiesCaptureNames(members: []const ast.ClassMember, names: *const LoopBindingNames) bool {
    for (members) |m| {
        if (m.func) |func| if (names.referencedByIn(func, true)) return true;
        if (m.field_init) |init| if (names.referencedByIn(init, true)) return true;
        if (m.static_block) |block| if (names.referencedByIn(block, true)) return true;
    }
    return false;
}

/// `eval_class` can safely build deferred members from a VM activation when
/// none of them closes over a slot in that activation or an enclosing VM frame.
/// Global-only methods therefore remain bytecode-eligible; a real frame capture
/// still rejects the whole function before execution.
fn classDeferredBodiesCaptureFrame(arena: std.mem.Allocator, scope: *const FnScope, members: []const ast.ClassMember, class_name: []const u8) CompileError!bool {
    var frame_names: LoopBindingNames = .{};
    var current: ?*const FnScope = scope;
    while (current) |frame_scope| : (current = frame_scope.parent) {
        var names = frame_scope.names.keyIterator();
        while (names.next()) |name| {
            // Deferred class elements resolve the class's own name through the
            // class Environment, even when an outer frame slot has the same
            // spelling. That binding is therefore not a frame capture.
            if (class_name.len == 0 or !std.mem.eql(u8, name.*, class_name))
                try frame_names.add(arena, name.*);
        }
        for (frame_scope.lexical_scopes.items) |bindings| {
            var lexical = bindings.iterator();
            while (lexical.next()) |entry| {
                // Environment-backed bindings are exactly what eval_class can
                // capture through its live Environment chain. Only a real frame
                // slot remains unavailable to deferred class member evaluation.
                if (!entry.value_ptr.environment and
                    (class_name.len == 0 or !std.mem.eql(u8, entry.key_ptr.*, class_name)))
                    try frame_names.add(arena, entry.key_ptr.*);
            }
        }
    }
    return classDeferredBodiesCaptureNames(members, &frame_names);
}

fn functionHasBlockNestedFuncDecl(fnode: *const ast.FunctionNode) bool {
    if (fnode.is_expr_body) return false;
    return switch (fnode.body.*) {
        .block => |stmts| stmtListContainsNestedFuncDecl(stmts),
        else => stmtContainsFuncDecl(fnode.body),
    };
}

fn stmtHasDisposableDecl(node: *const ast.Node) bool {
    return switch (node.*) {
        .var_decl => |d| d.dispose != 0,
        .block => |stmts| stmtListHasDisposableDecl(stmts),
        .decl_group => |stmts| stmtListHasDisposableDecl(stmts),
        else => false,
    };
}

fn stmtListHasDisposableDecl(stmts: []*Node) bool {
    for (stmts) |s| if (stmtHasDisposableDecl(s)) return true;
    return false;
}

fn stmtContainsDisposableDeclDeep(node: *const ast.Node) bool {
    return switch (node.*) {
        .var_decl => |d| d.dispose != 0,
        .block, .decl_group, .program => |stmts| stmtListContainsDisposableDeclDeep(stmts),
        .if_stmt => |s| stmtContainsDisposableDeclDeep(s.consequent) or
            (if (s.alternate) |alt| stmtContainsDisposableDeclDeep(alt) else false),
        .while_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        .do_while_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        .for_stmt => |s| (if (s.init) |init| stmtContainsDisposableDeclDeep(init) else false) or
            stmtContainsDisposableDeclDeep(s.body),
        .for_in => |s| s.dispose != 0 or
            (if (s.var_init) |init| stmtContainsDisposableDeclDeep(init) else false) or
            stmtContainsDisposableDeclDeep(s.body),
        .switch_stmt => |s| blk: {
            for (s.cases) |case| if (stmtListContainsDisposableDeclDeep(case.body)) break :blk true;
            break :blk false;
        },
        .try_stmt => |t| stmtContainsDisposableDeclDeep(t.block) or
            (if (t.catch_block) |c| stmtContainsDisposableDeclDeep(c) else false) or
            (if (t.finally_block) |f| stmtContainsDisposableDeclDeep(f) else false),
        .labeled_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        .with_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        else => false,
    };
}

fn stmtListContainsDisposableDeclDeep(stmts: []*Node) bool {
    for (stmts) |s| if (stmtContainsDisposableDeclDeep(s)) return true;
    return false;
}

fn stmtHasAwaitUsingDecl(node: *const ast.Node) bool {
    return switch (node.*) {
        .var_decl => |d| d.dispose == 2,
        .decl_group => |stmts| stmtListHasAwaitUsingDecl(stmts),
        else => false,
    };
}

fn stmtListHasAwaitUsingDecl(stmts: []*Node) bool {
    for (stmts) |s| if (stmtHasAwaitUsingDecl(s)) return true;
    return false;
}

fn stmtAwaitUsingDeclCount(node: *const ast.Node) usize {
    return switch (node.*) {
        .var_decl => |d| if (d.dispose == 2) 1 else 0,
        .decl_group => |stmts| stmtListAwaitUsingDeclCount(stmts),
        else => 0,
    };
}

fn stmtListAwaitUsingDeclCount(stmts: []*Node) usize {
    var count: usize = 0;
    for (stmts) |s| count += stmtAwaitUsingDeclCount(s);
    return count;
}

fn stmtListCanEscapeAbruptly(stmts: []*Node) bool {
    for (stmts) |s| if (stmtCanEscapeAbruptly(s)) return true;
    return false;
}

/// Where a referenced name lives.
const Resolved = union(enum) {
    local: SlotBinding, // slot in the current frame
    upval: struct { depth: u32, environment_depth: u32, binding: SlotBinding }, // an enclosing function's frame
    environment: SlotBinding, // statically known declarative Environment binding
    global, // by name, against the Environment
};

pub const Compiler = struct {
    arena: std.mem.Allocator,
    chunk: *Chunk,
    mode: Mode,
    scope: ?*FnScope = null,
    loops: std.ArrayListUnmanaged(*Loop) = .empty,
    /// True while lowering a generator body, so `yield` may emit `gen_yield`.
    in_generator: bool = false,
    /// True while lowering an async function body, so `await` may suspend (it
    /// reuses `gen_yield`; the async driver resumes it on promise settlement).
    in_async: bool = false,
    /// Counter for synthesized activation-temp names (destructuring, `yield*`,
    /// and resolved references that must survive recursion or suspension).
    tmp_counter: u32 = 0,
    /// >0 while compiling inside a `try` that has a `finally`. A `return`/`break`/
    /// `continue` crossing it is lowered as `abrupt_*` so the finally still runs.
    finally_depth: u32 = 0,
    /// How many `finally` BLOCKS we are currently compiling the body of (nested).
    /// A `return` in a finally body does not cross THAT finally (it is already
    /// running), only enclosing ones — so a return is a tail-call candidate when
    /// `finally_depth == active_finally` (every counted finally is one we are
    /// inside the body of, none pending). Kept separate from `finally_depth` so
    /// break/continue abrupt-vs-plain accounting (which compares against a loop's
    /// captured `finally_depth`) is unaffected.
    active_finally: u32 = 0,
    /// Number of runtime declarative/with environments emitted above this
    /// activation's entry environment.
    environment_depth: u32 = 0,
    /// The single classification for the repeated loop body currently being
    /// lowered. Nested blocks reuse its exact captured-name and catch-pattern
    /// results instead of walking the root once per lexical declaration.
    repeated_body_captures: ?*const RepeatedBodyCaptures = null,
    /// >0 while compiling the body of a `try` whose catch handler is still live on
    /// the VM handler stack (the no-finally case). A call in tail position there
    /// must NOT be a tail call: the handler has to survive the call so a throw from
    /// the callee is caught, but the tail-pop would discard it. Suppresses TCO in
    /// compileTailExpr. (The finally case keeps the handler live via abrupt_return.)
    try_depth: u32 = 0,
    /// True while compiling a STRICT function body. Proper tail calls
    /// (PrepareForTailCall) are a strict-mode-only guarantee, so compileTailExpr
    /// only reuses the frame when this is set. A sloppy tail call must grow the
    /// stack like any call and eventually throw RangeError (matching the
    /// tree-walker) rather than looping forever on `function f(){ return f(); }`.
    is_strict: bool = false,
    /// Emit per-statement VM checkpoints for debugger-enabled suspendable code.
    debug_checkpoints: bool = false,
    /// Highest #706 scratch slot handed out by this compiler. Program chunks
    /// publish it on their Chunk so each execution allocates an Exec-owned,
    /// GC-rooted scratch array of exactly that size.
    scratch_count: u32 = 0,

    /// Compile a whole program into a fresh chunk. The chunk ends with `halt`;
    /// the VM returns its completion accumulator. Program scope is null, so all
    /// top-level bindings are globals.
    pub const ProgramRejection = enum {
        invalid_root,
        unsupported_lowering,
    };

    pub const ProgramAdmission = union(enum) {
        compiled: *Chunk,
        rejected: ProgramRejection,
    };

    pub fn admitProgram(arena: std.mem.Allocator, program: *Node) error{OutOfMemory}!ProgramAdmission {
        var rejection: ?ProgramRejection = null;
        const chunk = compileProgramInner(arena, program, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = chunk };
    }

    pub fn compileProgram(arena: std.mem.Allocator, program: *Node) CompileError!*Chunk {
        return switch (try admitProgram(arena, program)) {
            .compiled => |chunk| chunk,
            .rejected => error.Unsupported,
        };
    }

    fn programIsStrict(statements: []*Node) bool {
        for (statements) |statement| {
            if (statement.* != .expr_stmt or statement.expr_stmt.* != .string) return false;
            if (std.mem.eql(u8, statement.expr_stmt.string, "use strict")) return true;
        }
        return false;
    }

    fn compileProgramInner(arena: std.mem.Allocator, program: *Node, rejection: *?ProgramRejection) CompileError!*Chunk {
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        // Keep latent source-node checkpoints in every chunk. With no debugger
        // hook the VM performs no checkpoint work; retaining the metadata lets a
        // later attachment inspect already-compiled functions without rebuilding
        // their frame/upvalue layout.
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .program, .debug_checkpoints = true };
        if (program.* != .program) {
            rejection.* = .invalid_root;
            return error.Unsupported;
        }
        // The parser's program-level strict flag is represented by the leading
        // Directive Prologue in this AST. Carry it into effectful bytecodes so
        // strict DeletePropertyOrThrow behavior does not depend on the caller's
        // mutable interpreter mode.
        c.is_strict = programIsStrict(program.program);
        try c.compileStmtList(program.program);
        _ = try chunk.emit(.halt, 0);
        chunk.scratch_count = c.scratch_count;
        try chunk.finalize();
        return chunk;
    }

    /// Compile a `function*` body into its own chunk, run by the suspendable VM
    /// (`vm.genNext`). Unlike `compileFunction`, this uses **env-mode** (no frame
    /// scope): the body's parameters, locals, and free variables all resolve by
    /// name against the generator's `Environment`, bound at call time. That keeps
    /// a generator interoperable with the tree-walked code around it (shared
    /// environment) and lets `yield` suspend mid-expression by snapshotting the
    /// operand stack. Returns `error.Unsupported` for bodies (or parameter forms)
    /// outside the VM's lowered subset, so the generator is reported unsupported
    /// rather than run incorrectly.
    pub const GeneratorRejection = enum {
        expression_body,
        unsupported_lowering,
    };

    pub const GeneratorAdmission = union(enum) {
        compiled: *Chunk,
        rejected: GeneratorRejection,
    };

    pub fn admitGenerator(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) error{OutOfMemory}!GeneratorAdmission {
        var rejection: ?GeneratorRejection = null;
        const chunk = compileGeneratorInner(arena, fnode, debug_checkpoints, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = chunk };
    }

    pub fn compileGenerator(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) CompileError!*Chunk {
        return switch (try admitGenerator(arena, fnode, debug_checkpoints)) {
            .compiled => |chunk| chunk,
            .rejected => error.Unsupported,
        };
    }

    fn compileGeneratorInner(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool, rejection: *?GeneratorRejection) CompileError!*Chunk {
        // Parameters (including default/rest/destructuring) are bound at runtime
        // by `makeGenerator` into the generator's environment — env-mode name
        // resolution means the body's references resolve there — so the param
        // shape never blocks compilation; only the body must lower.
        if (fnode.is_expr_body) {
            rejection.* = .expression_body;
            return error.Unsupported; // generators always have a block body
        }
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        // An async generator body may also `await` (in_async enables await_op).
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = null, .in_generator = true, .in_async = fnode.is_async, .is_strict = fnode.is_strict, .debug_checkpoints = debug_checkpoints };
        try c.compileStmt(fnode.body); // body is a block
        _ = try chunk.emit(.ret_undef, 0);
        try chunk.finalize();
        return chunk;
    }

    /// Compile a plain `async function` body for the suspendable VM (env-mode,
    /// like a generator). `await` lowers to a suspend (`gen_yield`); the async
    /// driver promisifies the suspended value, resumes on settlement, and
    /// settles the function's result promise on completion.
    pub const AsyncRejection = enum {
        async_generator,
        unsupported_lowering,
    };

    pub const AsyncAdmission = union(enum) {
        compiled: *Chunk,
        rejected: AsyncRejection,
    };

    pub fn admitAsync(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) error{OutOfMemory}!AsyncAdmission {
        var rejection: ?AsyncRejection = null;
        const chunk = compileAsyncInner(arena, fnode, debug_checkpoints, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = chunk };
    }

    pub fn compileAsync(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) CompileError!*Chunk {
        return switch (try admitAsync(arena, fnode, debug_checkpoints)) {
            .compiled => |chunk| chunk,
            .rejected => error.Unsupported,
        };
    }

    fn compileAsyncInner(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool, rejection: *?AsyncRejection) CompileError!*Chunk {
        if (fnode.is_generator) {
            rejection.* = .async_generator;
            return error.Unsupported; // async generators not lowered yet
        }
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = null, .in_async = true, .is_strict = fnode.is_strict, .debug_checkpoints = debug_checkpoints };
        if (fnode.is_expr_body) {
            try c.compileExpr(fnode.body);
            _ = try chunk.emit(.ret, 0);
        } else {
            try c.compileStmt(fnode.body);
            _ = try chunk.emit(.ret_undef, 0);
        }
        try chunk.finalize();
        return chunk;
    }

    const ShadowBind = struct { count: u32 = 0, lexical: bool = false };

    fn shadowAdd(arena: std.mem.Allocator, m: *std.StringHashMapUnmanaged(ShadowBind), name: []const u8, lexical: bool) CompileError!void {
        if (name.len == 0) return;
        const gop = try m.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        if (lexical) gop.value_ptr.lexical = true;
    }

    fn shadowScanPattern(arena: std.mem.Allocator, m: *std.StringHashMapUnmanaged(ShadowBind), pattern: *Node, lexical: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try shadowAdd(arena, m, name, lexical),
            .obj_pattern => |p| {
                for (p.props) |prop| try shadowScanPattern(arena, m, prop.target, lexical);
                if (p.rest) |rest| try shadowScanPattern(arena, m, rest, lexical);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |t| try shadowScanPattern(arena, m, t, lexical);
                if (p.rest) |rest| try shadowScanPattern(arena, m, rest, lexical);
            },
            else => {},
        }
    }

    fn shadowScanStmt(arena: std.mem.Allocator, m: *std.StringHashMapUnmanaged(ShadowBind), node: *Node) CompileError!void {
        switch (node.*) {
            .var_decl => |d| try shadowAdd(arena, m, d.name, d.kind != .@"var"),
            .destructure_decl => |d| try shadowScanPattern(arena, m, d.pattern, d.kind != .@"var"),
            .func_decl => |f| try shadowAdd(arena, m, f.name, false), // nested fn has its own scope; don't descend
            .block => |stmts| for (stmts) |s| try shadowScanStmt(arena, m, s),
            .decl_group => |stmts| for (stmts) |s| try shadowScanStmt(arena, m, s),
            .if_stmt => |s| {
                try shadowScanStmt(arena, m, s.consequent);
                if (s.alternate) |a| try shadowScanStmt(arena, m, a);
            },
            .while_stmt => |s| try shadowScanStmt(arena, m, s.body),
            .do_while_stmt => |s| try shadowScanStmt(arena, m, s.body),
            .for_stmt => |f| {
                if (f.init) |i| try shadowScanStmt(arena, m, i);
                try shadowScanStmt(arena, m, f.body);
            },
            .for_in => |f| {
                if (f.decl_kind) |k| try shadowScanPattern(arena, m, f.target, k != .@"var");
                try shadowScanStmt(arena, m, f.body);
            },
            .switch_stmt => |s| for (s.cases) |c| for (c.body) |st| try shadowScanStmt(arena, m, st),
            .labeled_stmt => |s| try shadowScanStmt(arena, m, s.body),
            .try_stmt => |t| {
                try shadowScanStmt(arena, m, t.block);
                if (t.catch_param) |p| try shadowScanPattern(arena, m, p, true); // catch binding is lexical
                if (t.catch_block) |cb| try shadowScanStmt(arena, m, cb);
                if (t.finally_block) |fb| try shadowScanStmt(arena, m, fb);
            },
            else => {},
        }
    }

    const FunctionBindingInventory = struct {
        bindings: std.StringHashMapUnmanaged(ShadowBind) = .empty,
        has_lexical: bool = false,
        has_shadowing: bool = false,
    };

    /// Build the spelling-based binding inventory once for both shadow and TDZ
    /// classification. Distinct lexical bindings still receive distinct slots;
    /// repeated spellings conservatively enable checks for every lexical slot.
    fn functionBindingInventory(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!FunctionBindingInventory {
        var inventory: FunctionBindingInventory = .{};
        for (fnode.params) |param| try shadowAdd(arena, &inventory.bindings, param.name, false);
        if (!fnode.is_expr_body) try shadowScanStmt(arena, &inventory.bindings, fnode.body);
        var bindings = inventory.bindings.iterator();
        while (bindings.next()) |entry| if (entry.value_ptr.lexical) {
            inventory.has_lexical = true;
            if (entry.value_ptr.count >= 2) {
                inventory.has_shadowing = true;
                break;
            }
        };
        return inventory;
    }

    fn tdzDeclarePattern(arena: std.mem.Allocator, declared: *std.StringHashMapUnmanaged(void), pattern: *Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try declared.put(arena, name, {}),
            .obj_pattern => |p| {
                for (p.props) |prop| try tdzDeclarePattern(arena, declared, prop.target);
                if (p.rest) |rest| try tdzDeclarePattern(arena, declared, rest);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |t| try tdzDeclarePattern(arena, declared, t);
                if (p.rest) |rest| try tdzDeclarePattern(arena, declared, rest);
            },
            else => {},
        }
    }

    /// Binding positions do not read their identifiers, but computed property
    /// names and defaults execute before BindingInitialization completes. Walk
    /// only those evaluation regions so `let [x = x] = []` and a reference to a
    /// later lexical binding select TDZ-checked frame bytecodes without treating
    /// every declared name as a false-positive read.
    fn tdzPatternRefsPending(pattern: *Node, m: *const std.StringHashMapUnmanaged(ShadowBind), declared: *const std.StringHashMapUnmanaged(void)) bool {
        return switch (pattern.*) {
            .identifier => false,
            .obj_pattern => |object| blk: {
                for (object.props) |property| {
                    if (property.key_expr) |key| if (tdzRefsPending(key, m, declared)) break :blk true;
                    if (property.default) |default| if (tdzRefsPending(default, m, declared)) break :blk true;
                    if (tdzPatternRefsPending(property.target, m, declared)) break :blk true;
                }
                if (object.rest) |rest| if (tdzPatternRefsPending(rest, m, declared)) break :blk true;
                break :blk false;
            },
            .arr_pattern => |array| blk: {
                for (array.elems) |element| {
                    if (element.default) |default| if (tdzRefsPending(default, m, declared)) break :blk true;
                    if (element.target) |target| if (tdzPatternRefsPending(target, m, declared)) break :blk true;
                }
                if (array.rest) |rest| if (tdzPatternRefsPending(rest, m, declared)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn tdzRefsPending(node: *Node, m: *const std.StringHashMapUnmanaged(ShadowBind), declared: *const std.StringHashMapUnmanaged(void)) bool {
        // The query is the disjunction the old per-binding scans implemented:
        // visit each identifier once, then test exact pending-lexical membership.
        // Keeping the shared exhaustive walker means new AST node kinds still
        // fail compilation until both capture and TDZ classification handle them.
        return nameRefInClosure(node, PendingLexicalReferences{
            .bindings = m,
            .declared = declared,
        }, true);
    }

    fn tdzScanStmt(arena: std.mem.Allocator, node: *Node, m: *const std.StringHashMapUnmanaged(ShadowBind), declared: *std.StringHashMapUnmanaged(void)) CompileError!bool {
        switch (node.*) {
            .var_decl => |d| {
                if (d.init) |init| if (tdzRefsPending(init, m, declared)) return true;
                if (d.kind != .@"var") try declared.put(arena, d.name, {});
            },
            .destructure_decl => |d| {
                if (tdzRefsPending(d.init, m, declared)) return true;
                if (d.kind != .@"var" and tdzPatternRefsPending(d.pattern, m, declared)) return true;
                if (d.kind != .@"var") try tdzDeclarePattern(arena, declared, d.pattern);
            },
            .expr_stmt => |expr| return tdzRefsPending(expr, m, declared),
            .return_stmt => |maybe| if (maybe) |expr| return tdzRefsPending(expr, m, declared),
            .throw_stmt => |expr| return tdzRefsPending(expr, m, declared),
            .if_stmt => |stmt| {
                if (tdzRefsPending(stmt.cond, m, declared)) return true;
                if (try tdzScanStmt(arena, stmt.consequent, m, declared)) return true;
                if (stmt.alternate) |alternate| if (try tdzScanStmt(arena, alternate, m, declared)) return true;
            },
            .while_stmt => |stmt| {
                if (tdzRefsPending(stmt.cond, m, declared)) return true;
                return tdzScanStmt(arena, stmt.body, m, declared);
            },
            .do_while_stmt => |stmt| {
                if (try tdzScanStmt(arena, stmt.body, m, declared)) return true;
                return tdzRefsPending(stmt.cond, m, declared);
            },
            .for_stmt => |stmt| {
                if (stmt.init) |init| if (try tdzScanStmt(arena, init, m, declared)) return true;
                if (stmt.cond) |cond| if (tdzRefsPending(cond, m, declared)) return true;
                if (stmt.update) |update| if (tdzRefsPending(update, m, declared)) return true;
                return tdzScanStmt(arena, stmt.body, m, declared);
            },
            .for_in => |stmt| {
                if (tdzRefsPending(stmt.iterable, m, declared)) return true;
                if (stmt.decl_kind) |kind| if (kind != .@"var") try tdzDeclarePattern(arena, declared, stmt.target);
                return tdzScanStmt(arena, stmt.body, m, declared);
            },
            .block => |stmts| for (stmts) |stmt| {
                if (try tdzScanStmt(arena, stmt, m, declared)) return true;
            },
            .decl_group => |stmts| for (stmts) |stmt| {
                if (try tdzScanStmt(arena, stmt, m, declared)) return true;
            },
            .switch_stmt => |stmt| {
                if (tdzRefsPending(stmt.disc, m, declared)) return true;
                for (stmt.cases) |case| {
                    if (case.@"test") |test_node| if (tdzRefsPending(test_node, m, declared)) return true;
                    for (case.body) |body_stmt| if (try tdzScanStmt(arena, body_stmt, m, declared)) return true;
                }
            },
            .labeled_stmt => |stmt| return tdzScanStmt(arena, stmt.body, m, declared),
            .try_stmt => |stmt| {
                if (try tdzScanStmt(arena, stmt.block, m, declared)) return true;
                if (stmt.catch_param) |param| try tdzDeclarePattern(arena, declared, param);
                if (stmt.catch_block) |catch_block| if (try tdzScanStmt(arena, catch_block, m, declared)) return true;
                if (stmt.finally_block) |finally_block| if (try tdzScanStmt(arena, finally_block, m, declared)) return true;
            },
            .func_decl => |function_node| if (tdzRefsPending(function_node.body, m, declared)) return true,
            else => return tdzRefsPending(node, m, declared),
        }
        return false;
    }

    /// Classify functions that need runtime TDZ checks. The conservative scan is
    /// retained as a code-shape decision: only these chunks receive checked
    /// lexical opcodes, so ordinary initialized `let` loops keep their existing
    /// native-tier and quickening eligibility.
    fn functionHasTdzHazard(
        arena: std.mem.Allocator,
        fnode: *const ast.FunctionNode,
        bindings: *const std.StringHashMapUnmanaged(ShadowBind),
    ) CompileError!bool {
        if (fnode.is_expr_body) return false;
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        return tdzScanStmt(arena, fnode.body, bindings, &declared);
    }

    fn functionNeedsTdzChecks(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!bool {
        const binding_inventory = try functionBindingInventory(arena, fnode);
        if (binding_inventory.has_shadowing) return true;
        // With no lexical binding, no identifier can require a TDZ check. The
        // exhaustive inventory proves that negative without a second AST walk.
        if (!binding_inventory.has_lexical) return false;
        return functionHasTdzHazard(arena, fnode, &binding_inventory.bindings);
    }

    pub const PlainFunctionCode = struct {
        chunk: *Chunk,
        local_count: u32,
    };

    /// Stable audit reasons for plain functions that do not receive bytecode.
    /// Keep these semantic rather than AST-node-specific: profiles and admission
    /// inventories persist the tag names across compiler implementation changes.
    pub const PlainFunctionRejection = enum {
        generator_or_async,
        function_scope_disposal,
        block_nested_function_declaration,
        lexical_shadowing,
        temporal_dead_zone,
        parameter_prologue,
        unsupported_lowering,
    };

    pub const PlainFunctionAdmission = union(enum) {
        compiled: PlainFunctionCode,
        rejected: PlainFunctionRejection,
    };

    /// Classify a plain function without collapsing every semantic barrier into
    /// `error.Unsupported`. The legacy compile API below deliberately retains its
    /// error contract while tier inventories consume this stable result.
    pub fn admitPlainFunction(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) error{OutOfMemory}!PlainFunctionAdmission {
        var rejection: ?PlainFunctionRejection = null;
        const compiled = compilePlainFunctionInner(arena, fnode, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = compiled };
    }

    pub fn compilePlainFunction(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!PlainFunctionCode {
        return switch (try admitPlainFunction(arena, fnode)) {
            .compiled => |compiled| compiled,
            .rejected => error.Unsupported,
        };
    }

    fn rejectPlainFunction(rejection: *?PlainFunctionRejection, reason: PlainFunctionRejection) CompileError {
        rejection.* = reason;
        return error.Unsupported;
    }

    fn compilePlainFunctionInner(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, rejection: *?PlainFunctionRejection) CompileError!PlainFunctionCode {
        if (fnode.is_generator or fnode.is_async)
            return rejectPlainFunction(rejection, .generator_or_async);
        if (fnode.uses_direct_eval)
            return rejectPlainFunction(rejection, .unsupported_lowering);
        // Function-scope `using` resources are disposed at function exit. The
        // frame-mode VM only emits block-level DisposeResources today, so keep
        // these bodies on the tree-walker until function-exit disposal is lowered.
        if (!fnode.is_expr_body and stmtContainsDisposableDeclDeep(fnode.body))
            return rejectPlainFunction(rejection, .function_scope_disposal);
        // A function declaration nested in a block needs the tree-walker in BOTH
        // modes: strict scopes it to the block (a binding the flat slot model
        // can't isolate), and sloppy gives it Annex B.3.3 dual bindings — a block
        // lexical AND a function-scope var that is assigned the block binding's
        // value at the point the declaration is evaluated. The flat model has one
        // slot for the name, so it reports the block's final value instead of the
        // decl-time snapshot (e.g. a reassignment after the declaration leaks).
        if (functionHasBlockNestedFuncDecl(fnode))
            return rejectPlainFunction(rejection, .block_nested_function_declaration);
        // Shadowed lexicals receive distinct slots below. Conservatively check
        // every lexical in such a function until the TDZ scan itself is keyed by
        // binding identity rather than spelling.
        const tdz_checks = try functionNeedsTdzChecks(arena, fnode);
        const scope = try arena.create(FnScope);
        scope.* = .{ .parent = null, .tdz_checks = tdz_checks };
        const parameter_slots = try arena.alloc(u32, fnode.params.len);
        for (fnode.params, 0..) |p, index| {
            if (p.default != null or p.is_rest or p.pattern != null)
                return rejectPlainFunction(rejection, .parameter_prologue);
            parameter_slots[index] = try scope.addLocal(arena, p.name, false, false);
        }
        const arguments_slot = try addArgumentsSlot(arena, scope, fnode);
        if (!fnode.is_expr_body) try collectFunctionLocals(arena, scope, fnode.body);
        const mapped_parameter_indices = try configureMappedParameters(arena, scope, fnode, arguments_slot);

        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        chunk.param_count = @intCast(fnode.params.len);
        chunk.parameter_slots = parameter_slots;
        chunk.arguments_slot = arguments_slot;
        chunk.mapped_parameter_indices = mapped_parameter_indices;
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = scope, .is_strict = fnode.is_strict, .debug_checkpoints = true };
        if (fnode.is_expr_body) {
            try c.compileTailExpr(fnode.body);
        } else {
            try c.compileStmt(fnode.body);
            _ = try chunk.emit(.ret_undef, 0);
        }
        chunk.local_count = scope.count;
        chunk.mapped_parameter_indices = try finalizeMappedParameterIndices(arena, scope, mapped_parameter_indices);
        chunk.lexical_slots = scope.lexical_slots.items;
        try retainDebugLocalNames(arena, chunk, scope);
        try chunk.finalize();
        return .{ .chunk = chunk, .local_count = scope.count };
    }

    // ---- name resolution --------------------------------------------------

    fn resolve(self: *Compiler, name: []const u8) Resolved {
        var depth: u32 = 0;
        var environment_depth: u32 = 0;
        var scope = self.scope;
        while (scope) |sc| {
            if (sc.get(name)) |binding| {
                if (binding.environment) return .{ .environment = binding };
                return if (depth == 0) .{ .local = binding } else .{ .upval = .{
                    .depth = depth,
                    .environment_depth = environment_depth,
                    .binding = binding,
                } };
            }
            environment_depth += sc.parent_environment_depth;
            depth += 1;
            scope = sc.parent;
        }
        return .global;
    }

    /// Emit a load of `name` to the appropriate location (local / upvalue / global).
    fn emitLoad(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| _ = try self.chunk.emit(if (binding.mapped_parameter) .load_local_mapped else if (binding.tdz_checked) .load_local_lexical else .load_local, binding.slot),
            .upval => |u| _ = try self.chunk.emitAB(if (u.binding.mapped_parameter) .load_upval_mapped else if (u.binding.tdz_checked) .load_upval_lexical else .load_upval, u.depth, u.binding.slot),
            .environment, .global => _ = try self.chunk.emit(.load_var, try self.chunk.addName(name)),
        }
    }

    /// Emit a store to `name` (assignment); leaves the value on the stack.
    fn emitStore(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| _ = if (binding.mapped_parameter)
                try self.chunk.emit(.store_local_mapped, binding.slot)
            else
                try self.chunk.emitAB(if (binding.tdz_checked or binding.immutable) .store_local_lexical else .store_local, binding.slot, @intFromBool(binding.immutable)),
            .upval => |u| _ = if (u.binding.mapped_parameter)
                try self.chunk.emitAB(.store_upval_mapped, u.depth, u.binding.slot)
            else
                try self.chunk.emitAB(if (u.binding.tdz_checked or u.binding.immutable) .store_upval_lexical else .store_upval, u.depth, u.binding.slot | (if (u.binding.immutable) @as(u32, 1) << 31 else 0)),
            .environment, .global => _ = try self.chunk.emit(.store_var, try self.chunk.addName(name)),
        }
    }

    fn bindingReferencePlan(self: *Compiler, name: []const u8) CompileError!?u32 {
        const resolved = self.resolve(name);
        const fallback: bc.BindingReferenceFallback = switch (resolved) {
            .local => |binding| .{
                .op = if (binding.mapped_parameter)
                    .store_local_mapped
                else if (binding.tdz_checked or binding.immutable)
                    .store_local_lexical
                else
                    .store_local,
                .a = binding.slot,
                .b = @intFromBool(binding.immutable),
            },
            .upval => |upvalue| .{
                .op = if (upvalue.binding.mapped_parameter)
                    .store_upval_mapped
                else if (upvalue.binding.tdz_checked or upvalue.binding.immutable)
                    .store_upval_lexical
                else
                    .store_upval,
                .a = upvalue.depth,
                .b = upvalue.binding.slot | (if (upvalue.binding.immutable) @as(u32, 1) << 31 else 0),
            },
            // A full Environment walk never selects its static fallback: it
            // captures an exact Environment/global-object/unresolvable base.
            .environment, .global => .{ .op = .store_var },
        };
        const environment_depth: u32 = switch (resolved) {
            .local => self.environment_depth,
            .upval => |upvalue| self.environment_depth + upvalue.environment_depth,
            .environment, .global => bc.delete_name_full_environment_depth,
        };
        // With no intervening Environment Record, a frame/upvalue Reference is
        // already immutable compile-time state and needs no activation slot.
        if (environment_depth == 0) switch (resolved) {
            .local, .upval => return null,
            .environment, .global => {},
        };
        const name_index = try self.chunk.addName(name);
        const index = try self.chunk.addBindingReferencePlan(.{
            .name_index = name_index,
            .environment_depth = environment_depth,
            .fallback = fallback,
        });
        _ = try self.chunk.emit(.resolve_binding_ref, index);
        return index;
    }

    fn emitStoreBindingReference(self: *Compiler, index: u32) CompileError!void {
        _ = try self.chunk.emit(.store_binding_ref, index);
    }

    /// Emit a definition of `name` (var/let/const/function decl) with its value
    /// already on the stack; consumes the value.
    fn emitDefine(self: *Compiler, name: []const u8) CompileError!void {
        try self.emitDefineForce(name);
    }

    fn emitDefineForce(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| {
                _ = try self.chunk.emit(if (binding.mapped_parameter) .store_local_mapped else .store_local, binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(if (u.binding.mapped_parameter) .store_upval_mapped else .store_upval, u.depth, u.binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .environment => |binding| _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (binding.immutable) 2 else 1),
            .global => _ = try self.chunk.emitAB(.def_var, try self.chunk.addName(name), 2),
        }
    }

    /// `has_init` marks a `var x = init` (vs a bare `var x;`): only the
    /// initializer form may have its write redirected to a `with` object that
    /// provides `x` (ResolveBinding before PutValue) — a bare declaration never
    /// touches the `with` object.
    fn emitDefineKind(self: *Compiler, name: []const u8, kind: ast.DeclKind, has_init: bool) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| {
                _ = try self.chunk.emit(if (binding.mapped_parameter) .store_local_mapped else .store_local, binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(if (u.binding.mapped_parameter) .store_upval_mapped else .store_upval, u.depth, u.binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .environment => |binding| _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (binding.immutable) 2 else 1),
            .global => {
                const ni = try self.chunk.addName(name);
                // In env-mode (program / generator / async body) a `let`/`const`
                // binds in the current lexical environment via `def_lex` (tracking
                // const-ness and keeping it distinct from the variable scope's
                // `var`s); a `var` hoists to the variable scope via `def_var`.
                if (kind != .@"var")
                    _ = try self.chunk.emitAB(.def_lex, ni, if (kind == .@"const") 2 else 1)
                else
                    // Only a real `var x = init` (b == 1) may redirect to a `with`
                    // object; a non-program `let`/`const` reaching this branch is a
                    // fresh lexical binding and must never touch the `with` object.
                    _ = try self.chunk.emitAB(.def_var, ni, if (has_init and kind == .@"var") 1 else 0);
            },
        }
    }

    /// DeclarativeEnvironmentRecord creation happens before a block's first
    /// statement. Frame-mode bytecode models that by resetting every directly
    /// declared lexical slot to the realm's unique TDZ marker on each entry.
    /// The opcode is internal bookkeeping; the declaration's ordinary store is
    /// InitializeBinding, while later identifier assignments use checked stores.
    fn emitLexicalInitializer(self: *Compiler, name: []const u8) CompileError!void {
        if (self.scope == null) return;
        switch (self.resolve(name)) {
            .local => |binding| {
                if (!binding.tdz_checked) return;
                _ = try self.chunk.emit(.init_local_lexical, binding.slot);
            },
            .environment => {}, // its Environment Record is predeclared below
            else => return error.Unsupported,
        }
    }

    fn emitLexicalInitializersForNode(self: *Compiler, node: *Node) CompileError!void {
        switch (node.*) {
            .var_decl => |d| if (d.kind != .@"var") try self.emitLexicalInitializer(d.name),
            .destructure_decl => |d| if (d.kind != .@"var") try self.emitLexicalInitializersForPattern(d.pattern),
            .decl_group => |decls| for (decls) |decl| try self.emitLexicalInitializersForNode(decl),
            else => {},
        }
    }

    fn emitLexicalInitializersForList(self: *Compiler, stmts: []*Node) CompileError!void {
        if (self.scope == null) return;
        for (stmts) |stmt| try self.emitLexicalInitializersForNode(stmt);
    }

    fn predeclareLexicalNode(self: *Compiler, node: *Node) CompileError!void {
        const scope = self.scope orelse return;
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind != .@"var")
                    _ = try scope.addLexical(self.arena, decl.name, decl.kind == .@"const");
            },
            .destructure_decl => |decl| if (decl.kind != .@"var")
                try self.predeclareLexicalPattern(decl.pattern, decl.kind == .@"const"),
            .decl_group => |decls| for (decls) |decl| try self.predeclareLexicalNode(decl),
            else => {},
        }
    }

    fn predeclareLexicalList(self: *Compiler, stmts: []*Node) CompileError!void {
        if (self.scope == null) return;
        for (stmts) |stmt| try self.predeclareLexicalNode(stmt);
    }

    fn predeclareRepeatedBodyNode(self: *Compiler, node: *Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        const scope = self.scope orelse return;
        switch (node.*) {
            .var_decl => |declaration| {
                if (declaration.kind == .@"var") return;
                if (captures.nameCaptured(declaration.name))
                    try scope.addEnvironmentLexical(self.arena, declaration.name, declaration.kind == .@"const")
                else
                    _ = try scope.addLexical(self.arena, declaration.name, declaration.kind == .@"const");
            },
            .decl_group => |declarations| for (declarations) |declaration|
                try self.predeclareRepeatedBodyNode(declaration, captures),
            .destructure_decl => |declaration| {
                if (declaration.kind == .@"var") return;
                if (captures.patternCaptured(declaration.pattern))
                    try self.markEnvironmentLexicalPattern(declaration.pattern, declaration.kind == .@"const")
                else
                    try self.predeclareLexicalPattern(declaration.pattern, declaration.kind == .@"const");
            },
            else => {},
        }
    }

    fn predeclareRepeatedBodyList(self: *Compiler, stmts: []*Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        for (stmts) |statement| try self.predeclareRepeatedBodyNode(statement, captures);
    }

    fn emitDeclareRepeatedBodyNode(self: *Compiler, node: *const Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        switch (node.*) {
            .var_decl => |declaration| if (declaration.kind != .@"var" and captures.nameCaptured(declaration.name))
                try self.emitDeclareEnvironmentLexicalName(declaration.name, declaration.kind == .@"const"),
            .destructure_decl => |declaration| if (declaration.kind != .@"var" and captures.patternCaptured(declaration.pattern))
                try self.emitDeclareEnvironmentLexicalPattern(declaration.pattern, declaration.kind == .@"const"),
            .decl_group => |declarations| for (declarations) |declaration|
                try self.emitDeclareRepeatedBodyNode(declaration, captures),
            else => {},
        }
    }

    fn emitDeclareRepeatedBodyList(self: *Compiler, stmts: []*Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        for (stmts) |statement| try self.emitDeclareRepeatedBodyNode(statement, captures);
    }

    fn repeatedBodyNodeNeedsEnvironment(node: *const Node, captures: *const RepeatedBodyCaptures) bool {
        return switch (node.*) {
            .var_decl => |declaration| declaration.kind != .@"var" and captures.nameCaptured(declaration.name),
            .destructure_decl => |declaration| declaration.kind != .@"var" and captures.patternCaptured(declaration.pattern),
            .decl_group => |declarations| blk: {
                for (declarations) |declaration| if (repeatedBodyNodeNeedsEnvironment(declaration, captures)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn repeatedBodyListNeedsEnvironment(stmts: []*Node, captures: *const RepeatedBodyCaptures) bool {
        for (stmts) |statement| if (repeatedBodyNodeNeedsEnvironment(statement, captures)) return true;
        return false;
    }

    fn loopHeadSupportsEnvironment(node: *const Node) bool {
        return switch (node.*) {
            .var_decl => |decl| decl.kind != .@"var",
            .destructure_decl => |decl| decl.kind != .@"var" and patternSupportsEnvironment(decl.pattern),
            .decl_group => |decls| blk: {
                if (decls.len == 0) break :blk false;
                for (decls) |decl| if (!loopHeadSupportsEnvironment(decl)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    fn patternSupportsEnvironment(pattern: *const Node) bool {
        return patternSupportsEnvironmentNode(pattern);
    }

    fn markEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        const scope = self.scope orelse return;
        switch (pattern.*) {
            .identifier => |name| try scope.addEnvironmentLexical(self.arena, name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.markEnvironmentLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.markEnvironmentLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.markEnvironmentLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.markEnvironmentLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    fn predeclareCheckedLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        const scope = self.scope orelse return error.Unsupported;
        switch (pattern.*) {
            .identifier => |name| _ = try scope.addLexicalChecked(self.arena, name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.predeclareCheckedLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.predeclareCheckedLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.predeclareCheckedLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.predeclareCheckedLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    fn predeclareLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        const scope = self.scope orelse return error.Unsupported;
        switch (pattern.*) {
            .identifier => |name| _ = try scope.addLexical(self.arena, name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.predeclareLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.predeclareLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.predeclareLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.predeclareLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    fn emitLexicalInitializersForPattern(self: *Compiler, pattern: *const Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try self.emitLexicalInitializer(name),
            .obj_pattern => |object| {
                for (object.props) |property| try self.emitLexicalInitializersForPattern(property.target);
                if (object.rest) |rest| try self.emitLexicalInitializersForPattern(rest);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.emitLexicalInitializersForPattern(target);
                if (array.rest) |rest| try self.emitLexicalInitializersForPattern(rest);
            },
            else => return error.Unsupported,
        }
    }

    fn markEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        const scope = self.scope orelse return;
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try scope.addEnvironmentLexical(self.arena, decl.name, decl.kind == .@"const");
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.markEnvironmentLexicalPattern(decl.pattern, decl.kind == .@"const");
            },
            .decl_group => |decls| for (decls) |decl| try self.markEnvironmentLexicalNode(decl),
            else => return error.Unsupported,
        }
    }

    fn emitDeclareEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try self.emitDeclareEnvironmentLexicalName(name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.emitDeclareEnvironmentLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.emitDeclareEnvironmentLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.emitDeclareEnvironmentLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.emitDeclareEnvironmentLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    /// Create the loop-head DeclarativeEnvironmentRecord with every binding in
    /// its TDZ before any initializer/RHS evaluation. def_lex modes 3/4 consume
    /// the placeholder and install the realm TDZ marker as let/const.
    fn emitDeclareEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(decl.name), if (decl.kind == .@"const") 4 else 3);
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.emitDeclareEnvironmentLexicalPattern(decl.pattern, decl.kind == .@"const");
            },
            .decl_group => |decls| for (decls) |decl| try self.emitDeclareEnvironmentLexicalNode(decl),
            else => return error.Unsupported,
        }
    }

    fn emitLoadEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| _ = try self.chunk.emit(.load_var, try self.chunk.addName(name)),
            .obj_pattern => |object| {
                for (object.props) |property| try self.emitLoadEnvironmentLexicalPattern(property.target);
                if (object.rest) |rest| try self.emitLoadEnvironmentLexicalPattern(rest);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.emitLoadEnvironmentLexicalPattern(target);
                if (array.rest) |rest| try self.emitLoadEnvironmentLexicalPattern(rest);
            },
            else => return error.Unsupported,
        }
    }

    fn emitLoadEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                _ = try self.chunk.emit(.load_var, try self.chunk.addName(decl.name));
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.emitLoadEnvironmentLexicalPattern(decl.pattern);
            },
            .decl_group => |decls| for (decls) |decl| try self.emitLoadEnvironmentLexicalNode(decl),
            else => return error.Unsupported,
        }
    }

    fn emitDefineEnvironmentLexicalPatternReverse(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (immutable) 2 else 1),
            .obj_pattern => |object| {
                if (object.rest) |rest| try self.emitDefineEnvironmentLexicalPatternReverse(rest, immutable);
                var index = object.props.len;
                while (index > 0) {
                    index -= 1;
                    try self.emitDefineEnvironmentLexicalPatternReverse(object.props[index].target, immutable);
                }
            },
            .arr_pattern => |array| {
                if (array.rest) |rest| try self.emitDefineEnvironmentLexicalPatternReverse(rest, immutable);
                var index = array.elems.len;
                while (index > 0) {
                    index -= 1;
                    if (array.elems[index].target) |target|
                        try self.emitDefineEnvironmentLexicalPatternReverse(target, immutable);
                }
            },
            else => return error.Unsupported,
        }
    }

    fn emitDefineEnvironmentLexicalNodeReverse(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(decl.name), if (decl.kind == .@"const") 2 else 1);
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.emitDefineEnvironmentLexicalPatternReverse(decl.pattern, decl.kind == .@"const");
            },
            .decl_group => |decls| {
                var index = decls.len;
                while (index > 0) {
                    index -= 1;
                    try self.emitDefineEnvironmentLexicalNodeReverse(decls[index]);
                }
            },
            else => return error.Unsupported,
        }
    }

    fn emitEnterEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        try self.emitEnterEnvironment();
        try self.emitDeclareEnvironmentLexicalNode(node);
    }

    fn emitDeclareEnvironmentLexicalName(self: *Compiler, name: []const u8, immutable: bool) CompileError!void {
        _ = try self.chunk.emit(.load_undefined, 0);
        _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (immutable) 4 else 3);
    }

    fn emitFreshEnvironmentLexicalName(self: *Compiler, name: []const u8, immutable: bool) CompileError!void {
        try self.emitExitEnvironment();
        try self.emitEnterEnvironment();
        try self.emitDeclareEnvironmentLexicalName(name, immutable);
    }

    fn emitFreshEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        try self.emitExitEnvironment();
        try self.emitEnterEnvironment();
        try self.emitDeclareEnvironmentLexicalPattern(pattern, immutable);
    }

    fn patternUsesEnvironment(self: *Compiler, pattern: *const Node) bool {
        return switch (pattern.*) {
            .identifier => |name| switch (self.resolve(name)) {
                .environment => true,
                else => false,
            },
            .obj_pattern => |object| blk: {
                for (object.props) |property| if (!self.patternUsesEnvironment(property.target)) break :blk false;
                if (object.rest) |rest| if (!self.patternUsesEnvironment(rest)) break :blk false;
                break :blk true;
            },
            .arr_pattern => |array| blk: {
                for (array.elems) |element| if (element.target) |target|
                    if (!self.patternUsesEnvironment(target)) break :blk false;
                if (array.rest) |rest| if (!self.patternUsesEnvironment(rest)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    /// CreatePerIterationEnvironment for a classic for-head: snapshot the old
    /// bindings on the operand stack, replace the current Environment Record by
    /// a fresh child of the same outer environment, then initialize the fresh
    /// bindings in reverse stack order.
    fn emitRenewEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        try self.emitLoadEnvironmentLexicalNode(node);
        try self.emitExitEnvironment();
        try self.emitEnterEnvironment();
        try self.emitDefineEnvironmentLexicalNodeReverse(node);
    }

    fn nodeDeclaresLexical(node: *const Node) bool {
        return switch (node.*) {
            .var_decl => |decl| decl.kind != .@"var",
            .destructure_decl => |decl| decl.kind != .@"var",
            .decl_group => |decls| for (decls) |decl| {
                if (nodeDeclaresLexical(decl)) break true;
            } else false,
            else => false,
        };
    }

    fn pushLexicalScope(self: *Compiler) CompileError!void {
        if (self.scope) |scope| try scope.pushLexicalScope(self.arena);
    }

    fn popLexicalScope(self: *Compiler) void {
        if (self.scope) |scope| scope.popLexicalScope();
    }

    fn emitEnterEnvironment(self: *Compiler) CompileError!void {
        _ = try self.chunk.emit(.enter_block, 0);
        self.environment_depth += 1;
    }

    fn emitExitEnvironment(self: *Compiler) CompileError!void {
        std.debug.assert(self.environment_depth > 0);
        _ = try self.chunk.emit(.exit_block, 0);
        self.environment_depth -= 1;
    }

    fn emitEnterClassEnvironment(self: *Compiler) CompileError!void {
        _ = try self.chunk.emit(.enter_block, 1);
        self.environment_depth += 1;
    }

    fn emitExitClassEnvironment(self: *Compiler) CompileError!void {
        std.debug.assert(self.environment_depth > 0);
        _ = try self.chunk.emit(.exit_block, 1);
        self.environment_depth -= 1;
    }

    // ---- statements -------------------------------------------------------

    /// Compile a statement list with function-declaration hoisting: every
    /// `func_decl` is emitted (closure + define) first, so forward references
    /// like `bar(); function bar() {}` resolve, then the remaining statements
    /// run in order (func_decls skipped, so each binds exactly once).
    fn compileStmtList(self: *Compiler, stmts: []*Node) CompileError!void {
        for (stmts) |s| switch (s.*) {
            .func_decl => |fnode| {
                const fi = try self.compileFunction(s, fnode, false);
                _ = try self.chunk.emit(.make_closure, fi);
                try self.emitDefineForce(fnode.name);
            },
            else => {},
        };
        for (stmts) |s| {
            if (s.* == .func_decl) continue;
            try self.compileStmt(s);
        }
    }

    /// NamedEvaluation: if `value_node` is a bare anonymous function/class def
    /// (matching interpreter.isAnonFnDef), emit `name_anon` so the value now on
    /// the stack takes `name` as its Function.name — mirroring the tree-walker's
    /// maybeNameAnon so `var f = function(){}` / `{foo: function(){}}` / `x = () =>
    /// {}` name their functions on the VM too.
    fn emitNamedEval(self: *Compiler, value_node: *const Node, name: []const u8) CompileError!void {
        const anon = switch (value_node.*) {
            .function => |f| f.name.len == 0,
            .func_decl => |f| f.name.len == 0,
            .class_expr => |c| c.name.len == 0,
            else => false,
        };
        if (anon) _ = try self.chunk.emit(.name_anon, try self.chunk.addName(name));
    }

    fn compileStmt(self: *Compiler, node: *Node) CompileError!void {
        if (self.debug_checkpoints) try self.chunk.markDebugStatement(node);
        switch (node.*) {
            .var_decl => |d| {
                // BindingIdentifier evaluation creates the Reference before the
                // initializer. Only an activation-local Environment Record can
                // shadow this function's hoisted `var`, so ordinary declarations
                // retain their direct frame/global path.
                const binding_reference = if (d.kind == .@"var" and d.init != null and self.environment_depth != 0)
                    try self.bindingReferencePlan(d.name)
                else
                    null;
                if (d.init) |init_node| {
                    try self.compileExpr(init_node);
                    try self.emitNamedEval(init_node, d.name);
                } else {
                    _ = try self.chunk.emit(.load_undefined, 0);
                }
                // `using x = v;` / `await using x = v;`: keep a copy of the resource
                // to register for DisposeResources at the variable scope's exit.
                if (d.dispose != 0) _ = try self.chunk.emit(.dup, 0);
                if (binding_reference) |reference|
                    try self.emitStoreBindingReference(reference)
                else
                    try self.emitDefineKind(d.name, d.kind, d.init != null);
                if (d.dispose != 0) _ = try self.chunk.emit(.register_disposable, if (d.dispose == 2) 1 else 0);
            },
            .destructure_decl => |d| {
                const environment_pattern = self.scope != null and self.patternUsesEnvironment(d.pattern);
                if (self.scope != null) {
                    try self.compileExpr(d.init);
                    const src = try self.freshActivationTemp();
                    try self.emitDefineActivationTemp(src);
                    const mode: PatternMode = if (environment_pattern)
                        .{ .environment_lexical = d.kind == .@"const" }
                    else if (d.kind == .@"var")
                        .var_declaration
                    else
                        .lexical;
                    try self.compilePattern(d.pattern, src, mode);
                    return;
                }
                if (nodeHasYield(d.pattern)) {
                    if (d.kind != .@"var" or environment_pattern) return error.Unsupported;
                    try self.emitPatternVarDecls(d.pattern);
                    try self.compileDestructuringAssign(d.pattern, d.init);
                    _ = try self.chunk.emit(.pop, 0);
                    return;
                }
                try self.compileExpr(d.init);
                const pi = try self.chunk.addPattern(d.pattern);
                const mode: u32 = switch (d.kind) {
                    .@"var" => 0,
                    .let => 1,
                    .@"const" => 2,
                };
                _ = try self.chunk.emitAB(.bind_pattern, pi, mode);
            },
            .func_decl => |fnode| {
                const fi = try self.compileFunction(node, fnode, false);
                _ = try self.chunk.emit(.make_closure, fi);
                try self.emitDefineForce(fnode.name);
            },
            .return_stmt => |maybe| {
                // A `return` that crosses a PENDING finally (one not currently
                // executing) must run it first: `abrupt_return` unwinds the
                // handler stack, runs each finally carrying a return completion,
                // and returns once they finish — a bare `ret` would skip it. A
                // return directly in a finally BODY crosses only enclosing
                // finallys, so `finally_depth > active_finally` is the real
                // "pending finally to run" test (not `finally_depth > 0`).
                if (self.finally_depth > self.active_finally) {
                    if (maybe) |e| {
                        try self.compileExpr(e);
                        if (self.in_generator and self.in_async) _ = try self.chunk.emit(.await_op, 0);
                    } else {
                        _ = try self.chunk.emit(.load_undefined, 0);
                    }
                    _ = try self.chunk.emit(.abrupt_return, 0);
                } else if (maybe) |e| {
                    if (!self.in_generator and !self.in_async) {
                        try self.compileTailExpr(e);
                    } else {
                        try self.compileExpr(e);
                        if (self.in_generator and self.in_async) _ = try self.chunk.emit(.await_op, 0);
                        _ = try self.chunk.emit(.ret, 0);
                    }
                } else {
                    _ = try self.chunk.emit(.ret_undef, 0);
                }
            },
            .expr_stmt => |e| {
                // A function-body string ExpressionStatement is discarded.
                // Keep the two-instruction checkpoint/step shape for statement
                // hooks, but do not retain the `"use strict"` StringCell as a
                // movable constant: that otherwise makes every dynamically
                // strict call body ineligible for the native optimizer even
                // though the directive has no runtime value in function mode.
                if (self.mode == .function and e.* == .string and std.mem.eql(u8, e.string, "use strict"))
                    _ = try self.chunk.emit(.load_undefined, 0)
                else
                    try self.compileExpr(e);
                // TryStatement evaluation keeps the try/catch completion when a
                // finally completes normally; the finally body's own statement
                // values are discarded. `active_finally` is compile-time region
                // state, so no runtime completion scratch is introduced here.
                _ = try self.chunk.emit(if (self.mode == .program and self.active_finally == 0) .set_acc else .pop, 0);
            },
            .debugger_stmt => _ = try self.chunk.emit(.nop, 0),
            .block => |stmts| {
                try self.pushLexicalScope();
                defer self.popLexicalScope();
                const repeated_captures = self.repeated_body_captures;
                const captured_environment = if (repeated_captures) |captures|
                    repeatedBodyListNeedsEnvironment(stmts, captures)
                else
                    false;
                if (repeated_captures) |captures|
                    try self.predeclareRepeatedBodyList(stmts, captures)
                else
                    try self.predeclareLexicalList(stmts);
                const disposable_scope = self.scope == null and stmtListHasDisposableDecl(stmts);
                if (disposable_scope) {
                    // This first VM block-disposal slice handles normal completion.
                    // Abrupt exits stay on the tree-walker until they can unwind
                    // block resources like `finally`.
                    if (stmtListCanEscapeAbruptly(stmts)) return error.Unsupported;
                    try self.emitEnterEnvironment();
                }
                if (captured_environment and !disposable_scope) {
                    try self.emitEnterEnvironment();
                }
                if (captured_environment) try self.emitDeclareRepeatedBodyList(stmts, repeated_captures.?);
                try self.emitLexicalInitializersForList(stmts);
                try self.compileStmtList(stmts);
                if (captured_environment and !disposable_scope) try self.emitExitEnvironment();
                if (disposable_scope) {
                    const await_using_count = if (self.in_async) stmtListAwaitUsingDeclCount(stmts) else 0;
                    if (await_using_count == 0) {
                        _ = try self.chunk.emit(.dispose_scope, 0);
                    } else {
                        var i: usize = 0;
                        while (i < await_using_count) : (i += 1) {
                            _ = try self.chunk.emit(.dispose_scope, 1);
                            _ = try self.chunk.emit(.await_op, 0);
                            _ = try self.chunk.emit(.pop, 0);
                        }
                        _ = try self.chunk.emit(.dispose_scope, 0);
                    }
                    try self.emitExitEnvironment();
                }
            },
            .decl_group => |stmts| try self.compileStmtList(stmts),
            .if_stmt => |s| try self.compileIf(s.cond, s.consequent, s.alternate),
            .while_stmt => |s| try self.compileWhile(s.cond, s.body),
            .do_while_stmt => |s| try self.compileDoWhile(s.body, s.cond),
            .for_stmt => |f| try self.compileFor(f.init, f.cond, f.update, f.body),
            .break_stmt => |label| {
                const loop = self.currentBreakTarget(label) orelse return error.Unsupported;
                // Across a finally, the finally must run before the jump:
                // `abrupt_break` unwinds the handler stack running each enclosing
                // finally, then jumps to the (patched) break target. A direct jump
                // crossing a repeated-body environment unwinds to the target's
                // activation-local environment depth first.
                const op: bc.Op = if (self.finally_depth > loop.finally_depth)
                    .abrupt_break
                else if (self.environment_depth > loop.environment_depth)
                    .jump_env
                else
                    .jump;
                const j = try self.chunk.emitAB(op, 0, loop.environment_depth);
                try loop.breaks.append(self.arena, j);
            },
            .continue_stmt => |label| {
                const loop = self.currentContinueTarget(label) orelse return error.Unsupported;
                const op: bc.Op = if (self.finally_depth > loop.finally_depth)
                    .abrupt_continue
                else if (self.environment_depth > loop.environment_depth)
                    .jump_env
                else
                    .jump;
                const j = try self.chunk.emitAB(op, 0, loop.environment_depth);
                try loop.continues.append(self.arena, j);
            },
            .switch_stmt => |sw| try self.compileSwitch(sw.disc, sw.cases),
            .throw_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(.throw_op, 0);
            },
            .for_in => |f| {
                if (f.is_await and !self.in_async) return error.Unsupported;
                if (f.dispose != 0) return error.Unsupported; // `for (using x of …)` disposal → tree-walk
                try self.compileForOf(f.decl_kind, f.target, f.var_init, f.iterable, f.body, !f.is_of, f.is_await);
            },
            .try_stmt => |t| try self.compileTry(t),
            .labeled_stmt => |l| {
                const target = try self.pushLabel(l.label, labeledStatementTargetsIteration(l.body));
                try self.compileStmt(l.body);
                for (target.breaks.items) |j| self.chunk.patchToHere(j);
                self.popLoop();
            },
            .with_stmt => |w| {
                // `with (obj) body`: push an object Environment Record, run the body,
                // pop it. Only safe when the body can't leave abruptly (which would
                // skip exit_with) — otherwise keep the whole generator on the
                // tree-walker. Annex B block function declarations inside `with`
                // also need tree-walker source-order legacy binding updates.
                // The object expression itself may `yield` (evaluated before the push).
                if (stmtCanEscapeAbruptly(w.body) or stmtContainsFuncDecl(w.body)) return error.Unsupported;
                try self.compileExpr(w.obj);
                _ = try self.chunk.emit(.enter_with, 0);
                self.environment_depth += 1;
                try self.compileStmt(w.body);
                _ = try self.chunk.emit(.exit_with, 0);
                self.environment_depth -= 1;
            },
            else => return error.Unsupported,
        }
    }

    fn catchPatternUsesEnvironment(self: *Compiler, pattern: *Node, catch_block: *Node) bool {
        if (self.scope == null) return true;
        _ = catch_block;
        return if (self.repeated_body_captures) |captures| captures.catchPatternCaptured(pattern) else false;
    }

    /// Create every catch-pattern binding before BindingInitialization begins.
    /// Captured bindings need a real Environment Record so repeated catches give
    /// closures fresh cells; uncaptured function-local bindings stay in checked
    /// frame slots and are reset to TDZ on every entry.
    fn prepareCatchPattern(self: *Compiler, pattern: *Node, catch_block: *Node) CompileError!bool {
        const environment = self.catchPatternUsesEnvironment(pattern, catch_block);
        if (environment) {
            try self.markEnvironmentLexicalPattern(pattern, false);
            try self.emitEnterEnvironment();
            // A lone identifier is initialized immediately from the incoming
            // exception and cannot observe its own pre-initialization state.
            // Destructuring defaults/computed keys can observe sibling TDZs, so
            // only patterns need the predeclared marker-backed bindings.
            if (pattern.* != .identifier)
                try self.emitDeclareEnvironmentLexicalPattern(pattern, false);
        } else if (pattern.* == .identifier) {
            // A simple catch binding has no initializer expression that can
            // observe another binding in the catch scope, so it needs no TDZ
            // sentinel in a function-local frame slot.
            const scope = self.scope.?;
            _ = try scope.addLexical(self.arena, pattern.identifier, false);
        } else {
            try self.predeclareCheckedLexicalPattern(pattern, false);
            try self.emitLexicalInitializersForPattern(pattern);
        }
        return environment;
    }

    /// Consume the catch value on top of the operand stack and initialize a
    /// destructuring catch parameter from it in spec evaluation order.
    fn compileCatchPattern(self: *Compiler, pattern: *Node, environment: bool) CompileError!void {
        const source = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(source);
        const mode: PatternMode = if (environment) .{ .environment_lexical = false } else .lexical;
        if (pattern.* == .identifier)
            try self.compilePatternTarget(pattern, source, mode)
        else
            try self.compilePattern(pattern, source, mode);
    }

    /// `try { B } [catch (binding) { C }] [finally { F }]` for the generator
    /// VM. A handler records the catch and/or finally targets; the VM unwinds to
    /// it on a throw. Catch BindingInitialization is emitted as ordinary
    /// bytecode, including defaults, computed keys, nested patterns and rest.
    fn compileTry(self: *Compiler, t: *const ast.TryNode) CompileError!void {
        const none = std.math.maxInt(u32);

        if (t.finally_block == null) {
            // try/catch (no finally) — handler with a catch arm only.
            const catch_block = t.catch_block orelse return error.Unsupported;
            const ph = try self.chunk.emitAB(.push_handler, none, none);
            self.try_depth += 1;
            try self.compileStmt(t.block);
            self.try_depth -= 1;
            _ = try self.chunk.emit(.pop_handler, 0);
            const skip = try self.chunk.emit(.jump, 0);
            self.chunk.code.items[ph].a = @intCast(self.chunk.here());
            {
                try self.pushLexicalScope();
                defer self.popLexicalScope();
                if (t.catch_param) |p| {
                    const environment = try self.prepareCatchPattern(p, catch_block);
                    try self.compileCatchPattern(p, environment);
                    try self.compileStmt(catch_block);
                    if (environment) try self.emitExitEnvironment();
                } else {
                    _ = try self.chunk.emit(.pop, 0);
                    try self.compileStmt(catch_block);
                }
            }
            self.chunk.patchToHere(skip);
            return;
        }

        // A finally is present. Abrupt control flow carries both its eventual
        // target PC and target lexical-environment depth through the handler.
        self.finally_depth += 1;
        defer self.finally_depth -= 1;

        const ph = try self.chunk.emitAB(.push_handler, none, none); // catch/finally patched below
        try self.compileStmt(t.block);
        _ = try self.chunk.emit(.pop_handler, 0);
        _ = try self.chunk.emit(.push_completion, 0); // normal completion of the try body
        const to_fin_normal = try self.chunk.emit(.jump, 0);

        var catch_start: ?usize = null;
        var ph2: ?usize = null;
        if (t.catch_block) |cb| {
            try self.pushLexicalScope();
            defer self.popLexicalScope();
            catch_start = self.chunk.here();
            var catch_environment = false;
            if (t.catch_param) |p| {
                // BindingInitialization may allocate or call user code and throw.
                // Install the finally-only handler first. The catch-specific form
                // records the depth below the incoming exception, which the
                // binding consumes, so every abrupt completion resumes the
                // finally with a clean operand stack.
                ph2 = try self.chunk.emitAB(.push_handler_catch, none, none);
                catch_environment = try self.prepareCatchPattern(p, cb);
                try self.compileCatchPattern(p, catch_environment);
                try self.compileStmt(cb);
                _ = try self.chunk.emit(.pop_handler, 0);
                if (catch_environment) try self.emitExitEnvironment();
            } else {
                _ = try self.chunk.emit(.pop, 0);
                ph2 = try self.chunk.emitAB(.push_handler, none, none);
                try self.compileStmt(cb);
                _ = try self.chunk.emit(.pop_handler, 0);
            }
            _ = try self.chunk.emit(.push_completion, 0); // normal completion of the catch body
        }

        const fin = self.chunk.here();
        self.chunk.patchTo(to_fin_normal, fin);
        self.chunk.code.items[ph].a = if (catch_start) |cs| @intCast(cs) else none; // throw → catch, else finally
        self.chunk.code.items[ph].b = @intCast(fin);
        if (ph2) |p2| self.chunk.code.items[p2].b = @intCast(fin);
        // We are now compiling the finally BODY: mark it active (see
        // `active_finally`) so a tail `return f()` directly in the finally is a
        // proper tail call (test262 tco-finally / tco-catch-finally) rather than
        // an abrupt_return that grows the native stack — WITHOUT lowering
        // `finally_depth`, which break/continue inside the finally still need for
        // correct abrupt-vs-plain lowering against enclosing loops.
        self.active_finally += 1;
        {
            defer self.active_finally -= 1;
            try self.compileStmt(t.finally_block.?);
        }
        _ = try self.chunk.emit(.end_finally, 0);
    }

    /// `switch (disc) { case t: ... default: ... }` — evaluate the discriminant
    /// once, then a chain of strict-equality tests jumping to each clause body
    /// (fall-through preserved). `break` exits via the switch's break list;
    /// `default` is taken only after every case test fails.
    fn compileSwitch(self: *Compiler, disc: *Node, cases: []const ast.SwitchCase) CompileError!void {
        try self.compileExpr(disc);
        const d = try self.freshTemp();
        try self.emitDefine(d); // d = the discriminant value

        try self.pushLexicalScope();
        defer self.popLexicalScope();
        const repeated_captures = self.repeated_body_captures;
        var captured_environment = false;
        for (cases) |case| {
            if (repeated_captures) |captures| {
                try self.predeclareRepeatedBodyList(case.body, captures);
                captured_environment = captured_environment or repeatedBodyListNeedsEnvironment(case.body, captures);
            } else try self.predeclareLexicalList(case.body);
        }

        // The whole CaseBlock is one lexical scope. Its bindings enter the TDZ
        // after discriminant evaluation but before any case-test evaluation.
        if (captured_environment) {
            try self.emitEnterEnvironment();
            for (cases) |case| try self.emitDeclareRepeatedBodyList(case.body, repeated_captures.?);
        }
        if (self.scope != null) for (cases) |case| try self.emitLexicalInitializersForList(case.body);

        const sw = try self.pushLoop();
        sw.is_switch = true;
        const body_jumps = try self.arena.alloc(usize, cases.len);
        const default_marker = std.math.maxInt(usize);
        for (cases, 0..) |c, i| {
            if (c.@"test") |t| {
                try self.emitLoad(d);
                try self.compileExpr(t);
                _ = try self.chunk.emit(.eq_strict, 0);
                _ = try self.chunk.emit(.not, 0); // jump_if_false jumps when equal
                body_jumps[i] = try self.chunk.emit(.jump_if_false, 0);
            } else {
                body_jumps[i] = default_marker; // the `default:` clause
            }
        }
        // No case matched: jump to the default clause (if any) or past the end.
        const to_default = try self.chunk.emit(.jump, 0);
        var default_target: ?usize = null;
        for (cases, 0..) |c, i| {
            if (body_jumps[i] == default_marker) {
                default_target = self.chunk.here();
            } else {
                self.chunk.patchToHere(body_jumps[i]);
            }
            try self.compileStmtList(c.body);
        }
        const end = self.chunk.here();
        self.chunk.patchTo(to_default, default_target orelse end);
        for (sw.breaks.items) |j| self.chunk.patchTo(j, end);
        self.popLoop();
        if (captured_environment) try self.emitExitEnvironment();
    }

    fn compileIf(self: *Compiler, cond: *Node, consequent: *Node, alternate: ?*Node) CompileError!void {
        try self.compileExpr(cond);
        const to_else = try self.chunk.emit(.jump_if_false, 0);
        try self.compileStmt(consequent);
        if (alternate) |alt| {
            const to_end = try self.chunk.emit(.jump, 0);
            self.chunk.patchToHere(to_else);
            try self.compileStmt(alt);
            self.chunk.patchToHere(to_end);
        } else {
            self.chunk.patchToHere(to_else);
        }
    }

    fn compileRepeatedBody(self: *Compiler, body: *Node) CompileError!void {
        var captures = try RepeatedBodyCaptures.init(self.arena, body);
        if (!captures.any()) return self.compileStmt(body);
        if (!repeatedBodyCapturesSupported(body, &captures)) return error.Unsupported;
        const saved_captures = self.repeated_body_captures;
        self.repeated_body_captures = &captures;
        defer self.repeated_body_captures = saved_captures;
        try self.compileStmt(body);
    }

    fn compileWhile(self: *Compiler, cond: *Node, body: *Node) CompileError!void {
        const loop = try self.pushLoop();
        const cond_at = self.chunk.here();
        try self.compileExpr(cond);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        try self.compileRepeatedBody(body);
        _ = try self.chunk.emit(.jump, @intCast(cond_at));
        self.chunk.patchToHere(to_end);
        // `continue` re-tests the condition.
        for (loop.continues.items) |j| self.chunk.patchTo(j, cond_at);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
    }

    fn compileDoWhile(self: *Compiler, body: *Node, cond: *Node) CompileError!void {
        const loop = try self.pushLoop();
        const top = self.chunk.here();
        try self.compileRepeatedBody(body);
        const cont_at = self.chunk.here(); // `continue` re-tests the condition
        try self.compileExpr(cond);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(to_end);
        for (loop.continues.items) |j| self.chunk.patchTo(j, cont_at);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
    }

    fn compileFor(self: *Compiler, init_node: ?*Node, cond: ?*Node, update: ?*Node, body: *Node) CompileError!void {
        // A captured lexical head uses a real declarative Environment Record:
        // closures capture that record, and the update edge replaces it with a
        // value-copied record per CreatePerIterationEnvironment. Uncaptured heads
        // retain O(1) frame slots. Environment-backed patterns lower their
        // defaults and computed keys as bytecode in the active binding scope.
        if (init_node) |ini| if (stmtHasDisposableDecl(ini)) return error.Unsupported;
        const captured_head = if (init_node) |ini| try forLoopCapturesLexical(self.arena, ini, cond, update, body) else false;
        if (captured_head and !loopHeadSupportsEnvironment(init_node.?))
            return error.Unsupported;
        const lexical_scope = if (init_node) |init| nodeDeclaresLexical(init) else false;
        if (lexical_scope) {
            try self.pushLexicalScope();
            if (captured_head)
                try self.markEnvironmentLexicalNode(init_node.?)
            else
                try self.predeclareLexicalNode(init_node.?);
        }
        defer if (lexical_scope) self.popLexicalScope();
        const disposable_scope = self.scope == null and init_node != null and stmtHasDisposableDecl(init_node.?);
        if (disposable_scope) {
            if (stmtCanEscapeAbruptly(body)) return error.Unsupported;
            try self.emitEnterEnvironment();
        }
        if (captured_head) try self.emitEnterEnvironmentLexicalNode(init_node.?);
        if (init_node) |ini| {
            if (!captured_head) try self.emitLexicalInitializersForNode(ini);
            // The init clause is a declaration statement (var_decl, or a group of
            // them for multiple declarators) or a bare expression.
            if (ini.* == .var_decl or ini.* == .destructure_decl or ini.* == .block or ini.* == .decl_group) {
                try self.compileStmt(ini);
            } else {
                try self.compileExpr(ini);
                _ = try self.chunk.emit(.pop, 0);
            }
        }
        const loop = try self.pushLoop();
        const cond_at = self.chunk.here();
        var to_end: ?usize = null;
        if (cond) |c| {
            try self.compileExpr(c);
            to_end = try self.chunk.emit(.jump_if_false, 0);
        }
        try self.compileRepeatedBody(body);
        const update_at = self.chunk.here();
        if (captured_head) try self.emitRenewEnvironmentLexicalNode(init_node.?);
        if (update) |u| {
            try self.compileExpr(u);
            _ = try self.chunk.emit(.pop, 0);
        }
        _ = try self.chunk.emit(.jump, @intCast(cond_at));
        if (to_end) |t| self.chunk.patchToHere(t);
        // `continue` runs the update clause, then re-tests.
        for (loop.continues.items) |j| self.chunk.patchTo(j, update_at);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
        if (captured_head) try self.emitExitEnvironment();
        if (disposable_scope) {
            _ = try self.chunk.emit(.dispose_scope, 0);
            if (self.in_async and init_node != null and stmtHasAwaitUsingDecl(init_node.?)) {
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.await_op, 0);
                _ = try self.chunk.emit(.pop, 0);
            }
            try self.emitExitEnvironment();
        }
    }

    /// Bind the current loop value (on the stack) to a loop target — an
    /// identifier (fast path) or a destructuring pattern / member target (via
    /// `bind_pattern`, reusing the tree-walker's destructuring). `for-in` uses
    /// an engine-owned candidate array that is never exposed to user iterators.
    fn compileLoopBind(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, force_environment: bool, native_pattern: bool) CompileError!void {
        if (target.* == .identifier) {
            if (decl_kind != null) {
                if (force_environment) {
                    _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(target.identifier), if (decl_kind.? == .@"const") 2 else 1);
                } else try self.emitDefine(target.identifier);
            } else {
                try self.emitStore(target.identifier);
                _ = try self.chunk.emit(.pop, 0);
            }
            return;
        }
        if (native_pattern and decl_kind == null and (target.* == .member or target.* == .super_member)) {
            // Assignment targets are evaluated after the next iteration value
            // has been selected. Preserve that value in activation-local storage
            // while resolving the one-shot base/key Reference.
            const value_name = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(value_name);
            const reference = (try self.preEvalPatternAssignmentRef(target, .assignment_native)) orelse return error.Unsupported;
            try self.storePatternAssignmentRef(target, reference, value_name);
            return;
        }
        // An ASSIGNMENT target that embeds a `yield`/`await` (`for ([ x = yield ]
        // of …)`) must be lowered to bytecode so the suspend point is real — route
        // it through the yield-aware destructuring path instead of `bind_pattern`
        // (which defers to the tree-walker and can't suspend). The loop value is on
        // the stack; move it into a temp first. Patterns WITHOUT yield/await keep
        // using `bind_pattern`, which handles object-rest / fn-name NamedEvaluation /
        // iterator-close that the assignment lowering bails on.
        if (decl_kind == null and (target.* == .arr_pattern or target.* == .obj_pattern) and nodeHasYield(target)) {
            const src = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(src); // consume the loop value from the stack
            try self.compileAssignPattern(target, src);
            return;
        }
        if (force_environment and (native_pattern or patternHasEvaluationExpressions(target)) and (target.* == .arr_pattern or target.* == .obj_pattern)) {
            const src = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(src);
            try self.compilePattern(target, src, .{ .environment_lexical = decl_kind.? == .@"const" });
            return;
        }
        if (native_pattern and (target.* == .arr_pattern or target.* == .obj_pattern)) {
            const value_name = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(value_name);
            if (decl_kind) |kind| if (kind != .@"var")
                try self.emitLexicalInitializersForPattern(target);
            const mode: PatternMode = if (decl_kind) |kind|
                if (kind == .@"var") .var_declaration else .lexical
            else
                .assignment_native;
            try self.compilePattern(target, value_name, mode);
            return;
        }
        // `bind_pattern` destructures into the live environment. That is the
        // binding scope in env-mode and for a captured head whose static names
        // were deliberately mapped to the active per-iteration environment. An
        // ordinary slot-allocated pattern still falls back to the tree-walker.
        if (self.scope != null and !force_environment) return error.Unsupported;
        const pi = try self.chunk.addPattern(target);
        const mode: u32 = if (decl_kind) |k| switch (k) {
            .@"var" => 0,
            .let => 1,
            .@"const" => 2,
        } else 3;
        _ = try self.chunk.emitAB(.bind_pattern, pi, mode);
    }

    fn compileForOf(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, var_init: ?*Node, iterable: *Node, body: *Node, keys_first: bool, await_each: bool) CompileError!void {
        // A captured simple lexical target uses a fresh declarative Environment
        // Record for every iterator result. That is the ForIn/OfBodyEvaluation
        // binding cell the closure captures; an uncaptured identifier stays in a
        // frame slot. Environment-backed patterns lower defaults and computed
        // keys directly, so every iterator result initializes the fresh record.
        const captured_binding = if (decl_kind) |kind|
            kind != .@"var" and try forOfCapturesLexical(self.arena, target, var_init, iterable, body)
        else
            false;
        const program_lexical_binding = keys_first and self.scope == null and if (decl_kind) |kind| kind != .@"var" else false;
        const environment_binding = captured_binding or program_lexical_binding;
        if (environment_binding and !patternSupportsEnvironment(target)) return error.Unsupported;
        const lexical_scope = self.scope != null and if (decl_kind) |kind|
            kind != .@"var" and (target.* == .identifier or target.* == .arr_pattern or target.* == .obj_pattern)
        else
            false;
        if (lexical_scope) {
            try self.pushLexicalScope();
            if (captured_binding) {
                if (target.* == .identifier)
                    try self.scope.?.addEnvironmentLexical(self.arena, target.identifier, decl_kind.? == .@"const")
                else
                    try self.markEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
            } else if (target.* == .arr_pattern or target.* == .obj_pattern) {
                try self.predeclareCheckedLexicalPattern(target, decl_kind.? == .@"const");
            } else {
                _ = try self.scope.?.addLexical(self.arena, target.identifier, decl_kind.? == .@"const");
            }
        }
        defer if (lexical_scope) self.popLexicalScope();
        const it_name = try self.freshTemp();
        const r_name = try self.freshTemp();

        // ForIn/OfHeadEvaluation creates lexical head bindings before evaluating
        // the RHS, so `for (let x of x)` observes x's TDZ rather than an outer x.
        if (environment_binding) {
            try self.emitEnterEnvironment();
            if (target.* == .identifier)
                try self.emitDeclareEnvironmentLexicalName(target.identifier, decl_kind.? == .@"const")
            else
                try self.emitDeclareEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
        } else if (decl_kind) |kind| if (kind != .@"var") {
            if (target.* == .identifier)
                try self.emitLexicalInitializer(target.identifier)
            else if (target.* == .arr_pattern or target.* == .obj_pattern)
                try self.emitLexicalInitializersForPattern(target);
        };

        if (var_init) |ini| {
            try self.compileExpr(ini);
            try self.compileLoopBind(decl_kind, target, environment_binding, keys_first);
        }
        try self.compileExpr(iterable);
        if (keys_first) {
            try self.compileForInKeys(decl_kind, target, body, environment_binding);
            return;
        }
        // for-await uses the async-iterator protocol (Symbol.asyncIterator, else
        // a wrapped sync iterator) and awaits each `next()` result.
        _ = try self.chunk.emit(if (await_each) .async_iter_of else .iter_of, 0);
        try self.emitDefine(it_name);
        // GetIterator reads the iterator's `next` method exactly ONCE (it becomes
        // the Iterator Record's [[NextMethod]]); cache it so a `next` accessor is
        // not re-read each iteration.
        const next_name = try self.freshTemp();
        try self.emitLoad(it_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("next"));
        try self.emitDefine(next_name);

        const done_name = try self.freshTemp();
        // This flag tracks whether an abrupt completion must close the iterator.
        // It becomes false only after a successful `{ done:false }` result; a
        // throw from `next()`/`await next()` itself does not perform IteratorClose.
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitDefine(done_name);

        const none = std.math.maxInt(u32);
        const ph = try self.chunk.emitAB(.push_handler, none, none);
        // A `return` (or a labeled break/continue) crossing this for-of must run
        // IteratorClose — the handler's finally_pc. Route it through abrupt_return
        // like a finally by raising finally_depth. Bump BEFORE pushLoop so the loop
        // records the raised depth: a plain `break`/`continue` targeting THIS loop
        // stays a plain jump (it has its own explicit close block), while a return
        // or an outer-targeted break unwinds to the close handler.
        self.finally_depth += 1;
        const loop = try self.pushLoop();
        const top = self.chunk.here();
        // r = it.next()  (for-await: r = await it.next()) — the cached `next`,
        // invoked with this=it via call_with_this (no second property lookup).
        try self.emitLoad(next_name);
        try self.emitLoad(it_name);
        _ = try self.chunk.emitAB(.call_with_this, 0, 0);
        if (await_each) _ = try self.chunk.emit(.await_op, 0); // await the next() result
        _ = try self.chunk.emit(.assert_iter_result, 0); // IteratorNext: result must be an Object
        try self.emitDefine(r_name);
        // if (r.done) break  — `not` then jump_if_false exits exactly when done.
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
        _ = try self.chunk.emit(.not, 0);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        _ = try self.chunk.emit(.load_false, 0);
        try self.emitStore(done_name);
        _ = try self.chunk.emit(.pop, 0);
        if (captured_binding) {
            if (target.* == .identifier)
                try self.emitFreshEnvironmentLexicalName(target.identifier, decl_kind.? == .@"const")
            else
                try self.emitFreshEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
        }
        // bind r.value to the loop target (identifier or destructuring pattern)
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
        const native_pattern = self.scope != null and (target.* == .arr_pattern or target.* == .obj_pattern);
        try self.compileLoopBind(decl_kind, target, captured_binding, native_pattern);
        try self.compileRepeatedBody(body);
        const continue_target = self.chunk.here();
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitStore(done_name);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        // `continue` re-enters the loop at the top (next .next()) without
        // closing; clear the active-close flag first.
        for (loop.continues.items) |j| self.chunk.patchTo(j, continue_target);
        // Normal completion (the iterator reported `done`): it is already
        // exhausted, so it is NOT closed — control just exits the loop.
        self.chunk.patchToHere(to_end);
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitStore(done_name);
        _ = try self.chunk.emit(.pop, 0);
        // `break` is an abrupt completion, so it must run IteratorClose (which
        // throws if `return` is present-but-non-callable or returns a non-object).
        // The normal-done path above jumps over this close block.
        if (loop.breaks.items.len > 0) {
            const skip_close = try self.chunk.emit(.jump, 0);
            for (loop.breaks.items) |j| self.chunk.patchToHere(j);
            try self.emitLoad(it_name);
            if (await_each) try self.emitAsyncIteratorClose(false) else _ = try self.chunk.emit(.iter_close, 0);
            self.chunk.patchToHere(skip_close);
        }
        self.popLoop();
        self.finally_depth -= 1;
        _ = try self.chunk.emit(.pop_handler, 0);

        const after_finally = try self.chunk.emit(.jump, 0);
        self.chunk.code.items[ph].b = @intCast(self.chunk.here());
        try self.emitLoad(done_name);
        _ = try self.chunk.emit(.not, 0);
        const skip_close = try self.chunk.emit(.jump_if_false, 0);
        try self.emitLoad(it_name);
        if (await_each) try self.emitAsyncIteratorClose(true) else _ = try self.chunk.emit(.iter_close_completion, 0);
        self.chunk.patchToHere(skip_close);
        _ = try self.chunk.emit(.end_finally, 0);
        self.chunk.patchToHere(after_finally);
        if (captured_binding) try self.emitExitEnvironment();
    }

    /// Drive `for-in` without routing the engine-owned key snapshot through
    /// `%ArrayIteratorPrototype%`. The target, candidate array, and cursor remain
    /// as a three-word GC-scanned operand-stack state; this gives program chunks
    /// activation isolation without synthesized globals or #706 scratch. Each
    /// `enum_next` dispatch advances one candidate and performs its live presence
    /// check, preserving watchdog/debugger/GC/GIL polls for large snapshots.
    fn compileForInKeys(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, body: *Node, environment_binding: bool) CompileError!void {
        _ = try self.chunk.emit(.enum_keys, 0);
        const none = std.math.maxInt(u32);
        const handler = try self.chunk.emitAB(.push_handler, none, none);
        self.finally_depth += 1;
        const loop = try self.pushLoop();
        const top = self.chunk.here();

        _ = try self.chunk.emit(.enum_next, 0);
        const exhausted = try self.chunk.emit(.jump_if_false, 0);
        const missing = try self.chunk.emit(.jump_if_false, 0);

        if (environment_binding) {
            if (target.* == .identifier)
                try self.emitFreshEnvironmentLexicalName(target.identifier, decl_kind.? == .@"const")
            else
                try self.emitFreshEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
        }
        try self.compileLoopBind(decl_kind, target, environment_binding, true);
        try self.compileRepeatedBody(body);

        const continue_target = self.chunk.here();
        _ = try self.chunk.emit(.jump, @intCast(top));
        for (loop.continues.items) |jump| self.chunk.patchTo(jump, continue_target);

        // A deleted candidate leaves its key above the three-word state. Drop
        // it and dispatch the next candidate; exhaustion additionally leaves
        // the false `present` flag that preceded `has candidate`.
        self.chunk.patchToHere(missing);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(exhausted);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.pop, 0);

        const cleanup = self.chunk.here();
        for (loop.breaks.items) |jump| self.chunk.patchTo(jump, cleanup);
        self.popLoop();
        self.finally_depth -= 1;
        _ = try self.chunk.emit(.pop_handler, 0);
        for (0..3) |_| _ = try self.chunk.emit(.pop, 0);

        const after_finally = try self.chunk.emit(.jump, 0);
        self.chunk.code.items[handler].b = @intCast(self.chunk.here());
        _ = try self.chunk.emit(.enum_end_completion, 0);
        _ = try self.chunk.emit(.end_finally, 0);
        self.chunk.patchToHere(after_finally);
        if (environment_binding) try self.emitExitEnvironment();
    }

    fn emitAsyncIteratorClose(self: *Compiler, completion_aware: bool) CompileError!void {
        _ = try self.chunk.emit(if (completion_aware) .async_iter_close_completion else .async_iter_close, 0);
        const absent = try self.chunk.emit(.jump_if_false, 0);
        _ = try self.chunk.emit(.await_op, 0);
        _ = try self.chunk.emit(.assert_iter_result, 0);
        _ = try self.chunk.emit(.pop, 0);
        const after = try self.chunk.emit(.jump, 0);
        self.chunk.patchToHere(absent);
        _ = try self.chunk.emit(.pop, 0);
        self.chunk.patchToHere(after);
    }

    // ---- activation-local destructuring assignment -------------------------

    /// `pattern = value` as an expression. Evaluates `value`, leaves it on the
    /// stack as the result, and destructures it into `pattern`.
    fn compileDestructuringAssign(self: *Compiler, pattern: *Node, value: *Node) CompileError!void {
        try self.compileExpr(value); // [v]
        const src = try self.freshActivationTemp();
        _ = try self.chunk.emit(.dup, 0); // [v, v]
        try self.emitDefineActivationTemp(src); // [v]   (define consumes one copy)
        try self.compileAssignPattern(pattern, src);
        // `src` (the rhs value) remains on the stack as the expression result.
    }

    fn emitPatternVarDecls(self: *Compiler, pattern: *Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| {
                _ = try self.chunk.emit(.load_undefined, 0);
                try self.emitDefineKind(name, .@"var", false);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |target| try self.emitPatternVarDecls(target);
                if (p.rest) |rest| try self.emitPatternVarDecls(rest);
            },
            .obj_pattern => |p| {
                for (p.props) |prop| try self.emitPatternVarDecls(prop.target);
                if (p.rest) |rest| try self.emitPatternVarDecls(rest);
            },
            else => {},
        }
    }

    const PatternMode = union(enum) {
        assignment_native,
        var_declaration,
        lexical,
        environment_lexical: bool,
    };

    fn patternModeIsAssignment(mode: PatternMode) bool {
        return mode == .assignment_native;
    }

    fn compileAssignPattern(self: *Compiler, pattern: *Node, src: ActivationTemp) CompileError!void {
        // A compiled assignment must write the exact statically resolved
        // frame/upvalue/global target. `bind_pattern` delegates to the
        // tree-walker Environment chain and therefore cannot represent a plain
        // function's frame slots. Keep the complete pattern in bytecode in
        // every mode; ActivationTemp selects frame, Environment, or program
        // scratch storage without changing the evaluation algorithm.
        try self.compilePattern(pattern, src, .assignment_native);
    }

    fn compilePattern(self: *Compiler, pattern: *Node, src: ActivationTemp, mode: PatternMode) CompileError!void {
        switch (pattern.*) {
            .arr_pattern => |p| try self.compileArrayPattern(p.elems, p.rest, src, mode),
            .obj_pattern => |p| try self.compileObjectPattern(p.props, p.rest, src, mode),
            else => return error.Unsupported,
        }
    }

    /// Assign the value held in temp `val` to a destructuring target — an
    /// identifier, a member reference (whose base/key were already evaluated
    /// into `ref`), or a nested pattern.
    fn compilePatternTarget(self: *Compiler, target: *Node, val: ActivationTemp, mode: PatternMode) CompileError!void {
        switch (target.*) {
            .identifier => |name| {
                try self.emitLoadActivationTemp(val);
                switch (mode) {
                    .lexical => try self.emitDefineForce(name),
                    .var_declaration => try self.emitDefineKind(name, .@"var", true),
                    .environment_lexical => |immutable| {
                        _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (immutable) 2 else 1);
                    },
                    .assignment_native => {
                        try self.emitStore(name);
                        _ = try self.chunk.emit(.pop, 0);
                    },
                }
            },
            .arr_pattern, .obj_pattern => {
                // Nested binding and assignment patterns stay in the current
                // activation so defaults, computed keys, and statically
                // resolved targets share the enclosing bytecode state.
                try self.compilePattern(target, val, mode);
            },
            else => return error.Unsupported, // member handled separately (ordered ref eval)
        }
    }

    fn emitPatternDefault(self: *Compiler, default: *Node, target: *Node, val: ActivationTemp) CompileError!void {
        try self.compileExpr(default);
        if (target.* == .identifier) try self.emitNamedEval(default, target.identifier);
        try self.emitStoreActivationTempDiscard(val);
    }

    /// Pre-evaluate a member/super target's base (and computed key) into fresh
    /// temps BEFORE the iterator advances or object-rest copying begins. Returns
    /// null for identifier targets, which use the existing name-store path.
    const MemberRef = struct { obj: ActivationTemp, key: ?ActivationTemp };

    const PatternAssignmentRef = union(enum) {
        binding: u32,
        member: MemberRef,
        super: CompiledSuperRef,
    };

    /// Runtime class construction rewrites `#name` to its unique storage key
    /// before compiling method bodies. An unreplaced source name can still
    /// appear in an eagerly compiled computed class key; lowering it as an
    /// ordinary property would erase PrivateFieldGet's required brand check.
    fn addMemberName(self: *Compiler, name: []const u8) CompileError!u32 {
        if (value_mod.isRawPrivateName(name) and !value_mod.isPrivateKey(name))
            return error.Unsupported;
        return self.chunk.addName(try value_mod.encodeStringKey(self.arena, name));
    }
    fn preEvalPatternAssignmentRef(self: *Compiler, target: ?*Node, mode: PatternMode) CompileError!?PatternAssignmentRef {
        const t = target orelse return null;
        switch (t.*) {
            .identifier => |name| switch (mode) {
                .assignment_native, .var_declaration => if (try self.bindingReferencePlan(name)) |reference|
                    return .{ .binding = reference },
                .lexical, .environment_lexical => {},
            },
            .member => |m| {
                if (!patternModeIsAssignment(mode)) return null;
                const obj_tmp = try self.freshActivationTemp();
                try self.compileExpr(m.object);
                try self.emitDefineActivationTemp(obj_tmp);
                var key_tmp: ?ActivationTemp = null;
                if (m.computed) |ce| {
                    const kt = try self.freshActivationTemp();
                    try self.compileExpr(ce);
                    try self.emitDefineActivationTemp(kt);
                    key_tmp = kt;
                }
                return .{ .member = .{ .obj = obj_tmp, .key = key_tmp } };
            },
            .super_member => if (patternModeIsAssignment(mode))
                return .{ .super = try self.compileSuperRef(t, false, false) },
            else => return null,
        }
        return null;
    }

    /// Store `val` through an already-evaluated member or super Reference.
    fn storePatternAssignmentRef(self: *Compiler, target: *Node, ref: PatternAssignmentRef, val: ActivationTemp) CompileError!void {
        switch (ref) {
            .binding => |reference| {
                try self.emitLoadActivationTemp(val);
                try self.emitStoreBindingReference(reference);
                return;
            },
            .member => |member_ref| {
                const m = target.member;
                try self.emitLoadActivationTemp(member_ref.obj); // [obj]
                if (member_ref.key) |kt| {
                    try self.emitLoadActivationTemp(kt); // [obj, key]
                    try self.emitLoadActivationTemp(val); // [obj, key, val]
                    _ = try self.chunk.emit(.set_index, 0);
                } else {
                    try self.emitLoadActivationTemp(val); // [obj, val]
                    _ = try self.chunk.emit(.set_prop, try self.addMemberName(m.property));
                }
            },
            .super => |super_ref| {
                try self.emitLoadSuperRefBase(super_ref);
                try self.emitLoadActivationTemp(val);
                try self.emitSetSuperRef(super_ref);
            },
        }
        _ = try self.chunk.emit(.pop, 0); // discard the set result
    }

    /// `[ e0, e1, ... ] = src` (assignment form). Drives the
    /// iterator protocol, applies defaults (which may yield), and runs
    /// IteratorClose when destructuring stops before exhausting the iterator —
    /// on a normal early stop AND on an abrupt completion (a `yield` resumed
    /// with `.return()`/`.throw()` mid-destructure), via a finally handler.
    fn compileArrayPattern(self: *Compiler, elems: []const ast.ArrPatElem, rest: ?*Node, src: ActivationTemp, mode: PatternMode) CompileError!void {
        const none = std.math.maxInt(u32);
        try self.emitLoadActivationTemp(src);
        _ = try self.chunk.emit(.iter_of, 0);
        const it = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(it);
        // GetIterator caches [[NextMethod]] once. Reading `iterator.next` on
        // every element would repeat an observable getter and could call a
        // different method after user code mutates the iterator.
        const next_method = try self.freshActivationTemp();
        try self.emitLoadActivationTemp(it);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("next"));
        try self.emitDefineActivationTemp(next_method);
        const done = try self.freshActivationTemp();
        _ = try self.chunk.emit(.load_false, 0);
        try self.emitDefineActivationTemp(done);

        // Wrap the element/rest processing in a finally handler so any abrupt
        // completion (return/throw injected at an embedded yield) still closes
        // the iterator before propagating.
        const ph = try self.chunk.emitAB(.push_handler, none, none);
        try self.compileArrayPatternBody(elems, rest, it, next_method, done, mode);
        _ = try self.chunk.emit(.pop_handler, 0);
        _ = try self.chunk.emit(.push_completion, 0); // normal completion
        // The normal path falls straight into the finally body (which the abrupt
        // path also jumps to via finally_pc); `end_finally` then resumes the
        // pushed completion — fall through on normal, re-propagate on abrupt.
        self.chunk.code.items[ph].b = @intCast(self.chunk.here());
        try self.emitLoadActivationTemp(done);
        _ = try self.chunk.emit(.not, 0);
        const skip = try self.chunk.emit(.jump_if_false, 0);
        try self.emitLoadActivationTemp(it);
        // The pending [value, kind] completion remains below the iterator.
        // IteratorClose preserves an existing throw even when `return` itself
        // throws, while a close failure replaces a normal completion.
        _ = try self.chunk.emit(.iter_close_completion, 0);
        self.chunk.patchToHere(skip);
        _ = try self.chunk.emit(.end_finally, 0);
    }

    fn compileArrayPatternBody(self: *Compiler, elems: []const ast.ArrPatElem, rest: ?*Node, it: ActivationTemp, next_method: ActivationTemp, done: ActivationTemp, mode: PatternMode) CompileError!void {
        for (elems) |elem| {
            // Spec order: evaluate the target reference first, then step the
            // iterator. Member/super targets carry an observable reference eval.
            const ref = try self.preEvalPatternAssignmentRef(elem.target, mode);
            // ev = undefined; if (!done) { r = it.next(); if (r.done) done = true else ev = r.value }
            const ev = try self.freshActivationTemp();
            _ = try self.chunk.emit(.load_undefined, 0);
            try self.emitDefineActivationTemp(ev);
            try self.emitLoadActivationTemp(done);
            _ = try self.chunk.emit(.not, 0);
            const skip_step = try self.chunk.emit(.jump_if_false, 0); // skip when done
            {
                const r = try self.freshActivationTemp();
                // IteratorStepValue marks the iterator record done before
                // propagating an abrupt IteratorNext / IteratorComplete /
                // IteratorValue completion. Set the flag before those calls,
                // then clear it only after a value is obtained successfully;
                // the enclosing finally must not IteratorClose after a step
                // operation itself throws.
                _ = try self.chunk.emit(.load_true, 0);
                try self.emitStoreActivationTempDiscard(done);
                try self.emitLoadActivationTemp(next_method);
                try self.emitLoadActivationTemp(it);
                _ = try self.chunk.emit(.call_with_this, 0);
                try self.emitDefineActivationTemp(r);
                try self.emitLoadActivationTemp(r);
                _ = try self.chunk.emit(.assert_iter_result, 0);
                _ = try self.chunk.emit(.pop, 0);
                try self.emitLoadActivationTemp(r);
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
                const not_done = try self.chunk.emit(.jump_if_false, 0);
                _ = try self.chunk.emit(.load_true, 0);
                try self.emitStoreActivationTempDiscard(done);
                const after = try self.chunk.emit(.jump, 0);
                self.chunk.patchToHere(not_done);
                try self.emitLoadActivationTemp(r);
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
                try self.emitStoreActivationTempDiscard(ev);
                _ = try self.chunk.emit(.load_false, 0);
                try self.emitStoreActivationTempDiscard(done);
                self.chunk.patchToHere(after);
            }
            self.chunk.patchToHere(skip_step);
            // default: if (ev === undefined) ev = <default>   (may yield)
            if (elem.default) |d| {
                try self.emitLoadActivationTemp(ev);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const has_val = try self.chunk.emit(.jump_if_false, 0);
                if (elem.target) |target|
                    try self.emitPatternDefault(d, target, ev)
                else {
                    try self.compileExpr(d);
                    _ = try self.chunk.emit(.pop, 0);
                }
                self.chunk.patchToHere(has_val);
            }
            // assign ev to the target
            if (elem.target) |t| {
                if (ref) |reference|
                    try self.storePatternAssignmentRef(t, reference, ev)
                else
                    try self.compilePatternTarget(t, ev, mode);
            }
        }

        if (rest) |rest_target| {
            // Spec order: evaluate the rest target reference (may yield) BEFORE
            // collecting the remaining elements.
            const rref = try self.preEvalPatternAssignmentRef(rest_target, mode);
            // rest = []; while (!done) { r = it.next(); if (r.done) { done=true; break } rest.push(r.value) }
            const ra = try self.freshActivationTemp();
            _ = try self.chunk.emit(.new_array, 0);
            try self.emitDefineActivationTemp(ra);
            const top = self.chunk.here();
            try self.emitLoadActivationTemp(done);
            _ = try self.chunk.emit(.not, 0);
            const to_end = try self.chunk.emit(.jump_if_false, 0); // exit when done
            const r = try self.freshActivationTemp();
            _ = try self.chunk.emit(.load_true, 0);
            try self.emitStoreActivationTempDiscard(done);
            try self.emitLoadActivationTemp(next_method);
            try self.emitLoadActivationTemp(it);
            _ = try self.chunk.emit(.call_with_this, 0);
            try self.emitDefineActivationTemp(r);
            try self.emitLoadActivationTemp(r);
            _ = try self.chunk.emit(.assert_iter_result, 0);
            _ = try self.chunk.emit(.pop, 0);
            try self.emitLoadActivationTemp(r);
            _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
            const not_done = try self.chunk.emit(.jump_if_false, 0);
            _ = try self.chunk.emit(.load_true, 0);
            try self.emitStoreActivationTempDiscard(done);
            const to_end2 = try self.chunk.emit(.jump, 0);
            self.chunk.patchToHere(not_done);
            const rest_value = try self.freshActivationTemp();
            try self.emitLoadActivationTemp(r);
            _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
            try self.emitDefineActivationTemp(rest_value);
            _ = try self.chunk.emit(.load_false, 0);
            try self.emitStoreActivationTempDiscard(done);
            try self.emitLoadActivationTemp(ra);
            try self.emitLoadActivationTemp(rest_value);
            _ = try self.chunk.emit(.array_append, 0);
            _ = try self.chunk.emit(.pop, 0); // drop the array left by array_append
            _ = try self.chunk.emit(.jump, @intCast(top));
            self.chunk.patchToHere(to_end);
            self.chunk.patchToHere(to_end2);
            if (rref) |reference|
                try self.storePatternAssignmentRef(rest_target, reference, ra)
            else
                try self.compilePatternTarget(rest_target, ra, mode);
        }
        // The enclosing finally handler performs IteratorClose when `!done`.
    }

    /// `{ k0: t0 = d0, ... } = src` (assignment form).
    fn compileObjectPattern(self: *Compiler, props: []const ast.ObjPatProp, rest: ?*ast.Node, src: ActivationTemp, mode: PatternMode) CompileError!void {
        try self.emitLoadActivationTemp(src);
        _ = try self.chunk.emit(.require_object_coercible, 0);
        var excluded: std.ArrayListUnmanaged(ActivationTemp) = .empty;
        for (props) |prop| {
            // PropertyName (may be computed and yield), then the target reference.
            const key = try self.freshActivationTemp();
            if (prop.key_expr) |ke| {
                try self.compileExpr(ke);
                _ = try self.chunk.emit(.to_property_key, 0);
                try self.emitDefineActivationTemp(key);
            } else {
                const ci = try self.chunk.addConst(try Value.strAlloc(self.arena, try value_mod.encodeStringKey(self.arena, prop.key)));
                _ = try self.chunk.emit(.load_const, ci);
                try self.emitDefineActivationTemp(key);
            }
            try excluded.append(self.arena, key);

            const ref = try self.preEvalPatternAssignmentRef(prop.target, mode);
            const ev = try self.freshActivationTemp();
            // ev = src[key]
            try self.emitLoadActivationTemp(src);
            if (prop.key_expr != null) {
                try self.emitLoadActivationTemp(key);
                _ = try self.chunk.emit(.get_index, 0);
            } else {
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, prop.key)));
            }
            try self.emitDefineActivationTemp(ev);
            // default
            if (prop.default) |d| {
                try self.emitLoadActivationTemp(ev);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const has_val = try self.chunk.emit(.jump_if_false, 0);
                try self.emitPatternDefault(d, prop.target, ev);
                self.chunk.patchToHere(has_val);
            }
            if (ref) |reference|
                try self.storePatternAssignmentRef(prop.target, reference, ev)
            else
                try self.compilePatternTarget(prop.target, ev, mode);
        }
        if (rest) |rest_target| {
            // RestDestructuringAssignmentEvaluation evaluates the assignment
            // target before CopyDataProperties, but performs PutValue after the
            // copy. Preserve the raw computed key across that interval so its
            // expression runs before source getters while ToPropertyKey remains
            // deferred to the eventual store. The activation-owned temps also
            // precisely root the base/key across getter calls and moving GC.
            const rest_ref = try self.preEvalPatternAssignmentRef(rest_target, mode);
            try self.emitLoadActivationTemp(src);
            for (excluded.items) |key| try self.emitLoadActivationTemp(key);
            _ = try self.chunk.emit(.object_rest, @intCast(excluded.items.len));
            const rest_value = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(rest_value);
            if (rest_ref) |ref|
                try self.storePatternAssignmentRef(rest_target, ref, rest_value)
            else
                try self.compilePatternTarget(rest_target, rest_value, mode);
        }
    }

    // ---- expressions ------------------------------------------------------

    fn compileTailExpr(self: *Compiler, node: *Node) CompileError!void {
        // A live catch handler (still on the VM handler stack) must survive the
        // call, so nothing here is in tail position: evaluate normally and return
        // rather than emitting a tail call that would discard the handler and let a
        // throw from the callee escape the enclosing catch. (The finally case is
        // already routed through abrupt_return by return_stmt.)
        //
        // Proper tail calls are also a strict-mode-only guarantee (PrepareForTailCall
        // is not performed in sloppy mode), so a sloppy tail position grows the stack
        // like any call and eventually throws RangeError — reusing the frame would
        // turn `function f(){ return f(); }` into an infinite loop instead.
        if (self.try_depth > 0 or !self.is_strict) {
            try self.compileExpr(node);
            _ = try self.chunk.emit(.ret, 0);
            return;
        }
        switch (node.*) {
            .call => |c| {
                try self.compileTailCall(c);
            },
            .sequence => |s| {
                try self.compileExpr(s.first);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileTailExpr(s.second);
            },
            .logical => |l| {
                try self.compileExpr(l.left);
                switch (l.op) {
                    .@"and" => {
                        const short = try self.chunk.emit(.jump_if_false_peek, 0);
                        _ = try self.chunk.emit(.pop, 0);
                        try self.compileTailExpr(l.right);
                        self.chunk.patchToHere(short);
                        _ = try self.chunk.emit(.ret, 0);
                    },
                    .@"or" => {
                        const short = try self.chunk.emit(.jump_if_true_peek, 0);
                        _ = try self.chunk.emit(.pop, 0);
                        try self.compileTailExpr(l.right);
                        self.chunk.patchToHere(short);
                        _ = try self.chunk.emit(.ret, 0);
                    },
                    .nullish => {
                        const short = try self.chunk.emit(.jump_if_not_nullish_peek, 0);
                        _ = try self.chunk.emit(.pop, 0);
                        try self.compileTailExpr(l.right);
                        self.chunk.patchToHere(short);
                        _ = try self.chunk.emit(.ret, 0);
                    },
                }
            },
            .conditional => |c| {
                try self.compileExpr(c.cond);
                const to_else = try self.chunk.emit(.jump_if_false, 0);
                try self.compileTailExpr(c.consequent);
                self.chunk.patchToHere(to_else);
                try self.compileTailExpr(c.alternate);
            },
            .optional_chain => |inner| try self.compileOptionalChain(inner, true),
            .tagged_template => |t| try self.compileTaggedTemplate(node, t.tag, t.exprs, true),
            else => {
                try self.compileExpr(node);
                _ = try self.chunk.emit(.ret, 0);
            },
        }
    }

    fn compileTailCall(self: *Compiler, c: anytype) CompileError!void {
        const spread = hasSpread(c.args);
        if (c.callee.* == .super_member) {
            try self.compileSuperCall(c, true);
            return;
        }
        if (c.callee.* == .member and c.callee.member.computed == null) {
            // Fetch the method (RequireObjectCoercible on the receiver) BEFORE the
            // args, per spec order, then tail-call with this = recv.
            const m = c.callee.member;
            const ni = try self.addMemberName(m.property);
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            _ = try self.chunk.emit(.get_prop, ni);
            _ = try self.chunk.emit(.swap, 0);
            if (spread) {
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(.tail_call_with_this_spread, 0);
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            }
            return;
        }
        if (c.callee.* == .member) {
            const m = c.callee.member;
            if (m.optional or m.computed == null) return error.Unsupported;
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            try self.compileExpr(m.computed.?);
            _ = try self.chunk.emit(.get_index, 0);
            _ = try self.chunk.emit(.swap, 0);
            if (spread) {
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(.tail_call_with_this_spread, 0);
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            }
            return;
        }
        if (c.callee.* == .optional_chain and c.callee.optional_chain.* == .member) {
            try self.compileParenthesizedOptionalMemberReference(c.callee.optional_chain.member);
            _ = try self.chunk.emit(.swap, 0);
            if (spread) {
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(.tail_call_with_this_spread, 0);
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            }
            return;
        }
        const is_eval = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval");
        // Tail position does not relax direct eval's requirement to observe
        // slot-backed locals and the owning arguments binding. Env-mode chunks
        // retain tail_call_eval; frame-mode functions stay on the tree walker.
        if (self.scope != null and is_eval) return error.Unsupported;
        try self.compileExpr(c.callee);
        if (spread) {
            // A direct eval in a slot-backed function must observe that
            // function's locals. Keep the existing dynamic-environment barrier;
            // optional `eval?.(...)` remains indirect and lowers normally.
            if (is_eval) return error.Unsupported;
            try self.compileArgsArray(c.args);
            _ = try self.chunk.emit(.tail_call_spread, 0);
            return;
        }
        for (c.args) |arg| try self.compileExpr(arg);
        _ = try self.chunk.emit(if (is_eval) .tail_call_eval else .tail_call, @intCast(c.args.len));
    }

    const OptionalExit = struct {
        instruction: usize,
        /// Operands owned by this chain at the optional point. Values below
        /// these belong to the surrounding expression and must survive the
        /// short circuit unchanged.
        cleanup: u8,
    };

    fn emitOptionalExit(
        self: *Compiler,
        exits: *std.ArrayListUnmanaged(OptionalExit),
        cleanup: u8,
    ) CompileError!void {
        const instruction = try self.chunk.emit(.jump_if_nullish_peek, 0);
        try exits.append(self.arena, .{ .instruction = instruction, .cleanup = cleanup });
    }

    /// Complete an optional-chain control-flow region. The fallthrough path
    /// already has `result_arity` operands; every nullish exit discards only the
    /// values owned by the chain and synthesizes the same result shape. This is
    /// compile-time jump patching over the ordinary operand stack, not runtime
    /// exception/scratch state.
    fn finishOptionalRegion(
        self: *Compiler,
        exits: []const OptionalExit,
        result_arity: u8,
    ) CompileError!void {
        if (exits.len == 0) return;

        const skip_cleanup = try self.chunk.emit(.jump, 0);
        var targets: [3]?usize = .{ null, null, null };
        var joins: [3]?usize = .{ null, null, null };
        for (exits) |exit| {
            std.debug.assert(exit.cleanup > 0 and exit.cleanup < targets.len);
            if (targets[exit.cleanup] != null) continue;
            targets[exit.cleanup] = self.chunk.here();
            for (0..exit.cleanup) |_| _ = try self.chunk.emit(.pop, 0);
            for (0..result_arity) |_| _ = try self.chunk.emit(.load_undefined, 0);
            joins[exit.cleanup] = try self.chunk.emit(.jump, 0);
        }
        self.chunk.patchToHere(skip_cleanup);
        for (exits) |exit| self.chunk.patchTo(exit.instruction, targets[exit.cleanup].?);
        for (joins) |join| if (join) |instruction| self.chunk.patchToHere(instruction);
    }

    /// A nullish optional property reference is considered successfully
    /// deleted. Keep this distinct from ordinary optional-chain value lowering,
    /// whose short path synthesizes `undefined`.
    fn finishOptionalDeleteRegion(self: *Compiler, exits: []const OptionalExit) CompileError!void {
        if (exits.len == 0) return;

        const skip_cleanup = try self.chunk.emit(.jump, 0);
        var targets: [3]?usize = .{ null, null, null };
        var joins: [3]?usize = .{ null, null, null };
        for (exits) |exit| {
            std.debug.assert(exit.cleanup > 0 and exit.cleanup < targets.len);
            if (targets[exit.cleanup] != null) continue;
            targets[exit.cleanup] = self.chunk.here();
            for (0..exit.cleanup) |_| _ = try self.chunk.emit(.pop, 0);
            _ = try self.chunk.emit(.load_true, 0);
            joins[exit.cleanup] = try self.chunk.emit(.jump, 0);
        }
        self.chunk.patchToHere(skip_cleanup);
        for (exits) |exit| self.chunk.patchTo(exit.instruction, targets[exit.cleanup].?);
        for (joins) |join| if (join) |instruction| self.chunk.patchToHere(instruction);
    }

    fn compileDeleteMember(self: *Compiler, member: anytype, optional_chain: bool) CompileError!void {
        var exits: std.ArrayListUnmanaged(OptionalExit) = .empty;
        if (optional_chain) {
            try self.compileOptionalValue(member.object, &exits);
            if (member.optional) try self.emitOptionalExit(&exits, 1);
        } else {
            try self.compileExpr(member.object);
        }
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.delete_index, @intFromBool(self.is_strict));
        } else {
            _ = try self.chunk.emitAB(.delete_prop, try self.addMemberName(member.property), @intFromBool(self.is_strict));
        }
        if (optional_chain) try self.finishOptionalDeleteRegion(exits.items);
    }

    fn compileDelete(self: *Compiler, target: *Node) CompileError!void {
        switch (target.*) {
            .member => |member| try self.compileDeleteMember(member, false),
            .optional_chain => |inner| if (inner.* == .member)
                try self.compileDeleteMember(inner.member, true)
            else {
                // A non-reference is evaluated exactly once for side effects;
                // the Delete Operator result is unconditionally true.
                try self.compileExpr(target);
                _ = try self.chunk.emit(.pop, 0);
                _ = try self.chunk.emit(.load_true, 0);
            },
            .super_member => |member| {
                // Delete of a SuperReference always throws, but reference
                // construction performs GetThisBinding before evaluating a
                // computed key. The key is never coerced with ToPropertyKey.
                if (member.computed) |key| {
                    _ = try self.chunk.emit(.check_super_this, 0);
                    try self.compileExpr(key);
                    _ = try self.chunk.emit(.pop, 0);
                }
                _ = try self.chunk.emit(.delete_super, 0);
            },
            .identifier => |name| {
                switch (self.resolve(name)) {
                    // A frame slot is a declarative binding and cannot be deleted.
                    // Activation-local block/with records may still shadow it, so
                    // search exactly those records before taking the false fallback.
                    .local => {
                        if (self.environment_depth == 0)
                            _ = try self.chunk.emit(.load_false, 0)
                        else
                            _ = try self.chunk.emitAB(.delete_name, try self.chunk.addName(name), self.environment_depth);
                    },
                    .upval => |upvalue| {
                        const environment_depth = self.environment_depth + upvalue.environment_depth;
                        if (environment_depth == 0)
                            _ = try self.chunk.emit(.load_false, 0)
                        else
                            _ = try self.chunk.emitAB(.delete_name, try self.chunk.addName(name), environment_depth);
                    },
                    // Environment-backed suspendable locals and globals need full
                    // ResolveBinding/DeleteBinding semantics at execution time.
                    .environment, .global => _ = try self.chunk.emitAB(
                        .delete_name,
                        try self.chunk.addName(name),
                        bc.delete_name_full_environment_depth,
                    ),
                }
            },
            else => {
                try self.compileExpr(target);
                _ = try self.chunk.emit(.pop, 0);
                _ = try self.chunk.emit(.load_true, 0);
            },
        }
    }

    fn finishOptionalTailRegion(self: *Compiler, exits: []const OptionalExit) CompileError!void {
        var targets: [3]?usize = .{ null, null, null };
        for (exits) |exit| {
            std.debug.assert(exit.cleanup > 0 and exit.cleanup < targets.len);
            if (targets[exit.cleanup] != null) continue;
            targets[exit.cleanup] = self.chunk.here();
            for (0..exit.cleanup) |_| _ = try self.chunk.emit(.pop, 0);
            _ = try self.chunk.emit(.ret_undef, 0);
        }
        for (exits) |exit| self.chunk.patchTo(exit.instruction, targets[exit.cleanup].?);
    }

    fn compileOptionalChain(self: *Compiler, inner: *Node, is_tail: bool) CompileError!void {
        var exits: std.ArrayListUnmanaged(OptionalExit) = .empty;
        if (is_tail and inner.* == .call) {
            try self.compileOptionalCall(inner.call, &exits, true);
            try self.finishOptionalTailRegion(exits.items);
            return;
        }

        try self.compileOptionalValue(inner, &exits);
        if (is_tail) {
            _ = try self.chunk.emit(.ret, 0);
            try self.finishOptionalTailRegion(exits.items);
        } else {
            try self.finishOptionalRegion(exits.items, 1);
        }
    }

    /// Lower one node on an unparenthesized optional-chain spine. Recursive
    /// calls are limited to member bases and call callees: computed keys and
    /// arguments are ordinary nested expressions, and a nested optional_chain
    /// wrapper therefore correctly terminates the outer chain at parentheses.
    fn compileOptionalValue(
        self: *Compiler,
        node: *Node,
        exits: *std.ArrayListUnmanaged(OptionalExit),
    ) CompileError!void {
        switch (node.*) {
            .member => |member| {
                try self.compileOptionalValue(member.object, exits);
                if (member.optional) try self.emitOptionalExit(exits, 1);
                if (member.computed) |key| {
                    try self.compileExpr(key);
                    _ = try self.chunk.emit(.get_index, 0);
                } else {
                    _ = try self.chunk.emit(.get_prop, try self.addMemberName(member.property));
                }
            },
            .call => |call| try self.compileOptionalCall(call, exits, false),
            else => try self.compileExpr(node),
        }
    }

    /// Leave `[receiver, method]` on the operand stack. The member's base is
    /// checked before a computed key only for `?.[`; ordinary computed access
    /// retains its existing key-expression-before-RequireObjectCoercible order.
    fn compileOptionalMemberReference(
        self: *Compiler,
        member: anytype,
        exits: *std.ArrayListUnmanaged(OptionalExit),
    ) CompileError!void {
        try self.compileOptionalValue(member.object, exits);
        if (member.optional) try self.emitOptionalExit(exits, 1);
        _ = try self.chunk.emit(.dup, 0);
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.get_index, 0);
        } else {
            _ = try self.chunk.emit(.get_prop, try self.addMemberName(member.property));
        }
    }

    /// Parentheses terminate short-circuit propagation but preserve a member
    /// Reference for call `this` binding. Normalize the inner chain to two
    /// operands so `(base?.method)()` still calls with `this = base`, while a
    /// nullish base becomes an ordinary call of undefined (and therefore throws)
    /// unless the outer call is itself optional.
    fn compileParenthesizedOptionalMemberReference(
        self: *Compiler,
        member: anytype,
    ) CompileError!void {
        var inner_exits: std.ArrayListUnmanaged(OptionalExit) = .empty;
        try self.compileOptionalMemberReference(member, &inner_exits);
        try self.finishOptionalRegion(inner_exits.items, 2);
    }

    fn compileOptionalSuperReference(self: *Compiler, member: anytype) CompileError!void {
        // GetThisBinding precedes the computed key and the super lookup. Retain
        // that exact receiver below the method so an optional call can inspect
        // the method before argument evaluation and then bind the original this.
        _ = try self.chunk.emit(.load_this, 0);
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.super_get_index, 0);
        } else {
            _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, member.property)));
        }
    }

    fn compileOptionalCall(
        self: *Compiler,
        call: anytype,
        exits: *std.ArrayListUnmanaged(OptionalExit),
        is_tail: bool,
    ) CompileError!void {
        const spread = hasSpread(call.args);

        var has_receiver = false;
        if (call.callee.* == .member) {
            try self.compileOptionalMemberReference(call.callee.member, exits);
            has_receiver = true;
        } else if (call.callee.* == .optional_chain and call.callee.optional_chain.* == .member) {
            try self.compileParenthesizedOptionalMemberReference(call.callee.optional_chain.member);
            has_receiver = true;
        } else if (call.callee.* == .super_member) {
            try self.compileOptionalSuperReference(call.callee.super_member);
            has_receiver = true;
        } else {
            try self.compileOptionalValue(call.callee, exits);
        }

        if (call.optional) try self.emitOptionalExit(exits, if (has_receiver) 2 else 1);
        if (has_receiver) _ = try self.chunk.emit(.swap, 0); // [method, receiver]

        if (spread) {
            try self.compileArgsArray(call.args);
            _ = try self.chunk.emit(
                if (has_receiver)
                    if (is_tail) .tail_call_with_this_spread else .call_with_this_spread
                else if (is_tail)
                    .tail_call_spread
                else
                    .call_spread,
                0,
            );
            return;
        }

        for (call.args) |arg| try self.compileExpr(arg);
        _ = try self.chunk.emit(
            if (has_receiver)
                if (is_tail) .tail_call_with_this else .call_with_this
            else if (is_tail)
                .tail_call
            else
                .call,
            @intCast(call.args.len),
        );
    }

    fn compileSuperCall(self: *Compiler, call: anytype, is_tail: bool) CompileError!void {
        const member = call.callee.super_member;
        // SuperProperty obtains the current this binding before evaluating a
        // computed key. Retain that exact receiver below the lookup result so
        // inherited getters and the eventual call both observe it.
        _ = try self.chunk.emit(.load_this, 0);
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.super_get_index, 0);
        } else {
            _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, member.property)));
        }
        _ = try self.chunk.emit(.swap, 0); // [method, this]
        if (hasSpread(call.args)) {
            try self.compileArgsArray(call.args);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this_spread else .call_with_this_spread, 0);
            return;
        }
        for (call.args) |arg| try self.compileExpr(arg);
        _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, @intCast(call.args.len));
    }

    /// `tag`a${x}b`` → `tag(strings, x)`. The `template_object` opcode pushes the
    /// per-site cached+frozen GetTemplateObject strings array (shared with the
    /// tree-walker via the interpreter's `template_cache`, keyed by this AST
    /// node), so tiering no longer rebuilds/uncaches it — and a tail tagged
    /// template becomes a proper tail call (test262 tagged-template/tco-*).
    fn compileTaggedTemplate(self: *Compiler, site: *Node, tag: *Node, exprs: []*Node, is_tail: bool) CompileError!void {
        const ti = try self.chunk.addTemplate(site);
        const argc: u32 = @intCast(1 + exprs.len); // strings object + each substitution
        if (tag.* == .member and tag.member.computed == null and !tag.member.optional) {
            // `obj.tag`...`` → this = obj. Fetch the tag (RequireObjectCoercible +
            // any getter) BEFORE the arguments, per spec order.
            const m = tag.member;
            const ni = try self.addMemberName(m.property);
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            _ = try self.chunk.emit(.get_prop, ni);
            _ = try self.chunk.emit(.swap, 0); // [method, recv]
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        if (tag.* == .member) {
            const m = tag.member;
            if (m.optional or m.computed == null) return error.Unsupported;
            // MemberExpression evaluation completes before GetTemplateObject or
            // any substitution. Keep one receiver below the computed lookup so
            // the eventual tag call observes the original base as `this`.
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            try self.compileExpr(m.computed.?);
            _ = try self.chunk.emit(.get_index, 0);
            _ = try self.chunk.emit(.swap, 0); // [method, recv]
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        if (tag.* == .super_member) {
            // A super property Reference reads through the home object's parent
            // but calls with the current this binding, never the super base.
            const m = tag.super_member;
            if (m.computed) |key| {
                try self.compileExpr(key);
                _ = try self.chunk.emit(.super_get_index, 0);
            } else {
                _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, m.property)));
            }
            _ = try self.chunk.emit(.load_this, 0);
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        // Plain tag (identifier / call / …): this = undefined.
        try self.compileExpr(tag);
        _ = try self.chunk.emit(.template_object, ti);
        for (exprs) |e| try self.compileExpr(e);
        _ = try self.chunk.emit(if (is_tail) .tail_call else .call, argc);
    }

    fn compileExpr(self: *Compiler, node: *Node) CompileError!void {
        switch (node.*) {
            .number => |n| {
                const ci = try self.chunk.addConst(Value.num(n));
                _ = try self.chunk.emit(.load_const, ci);
            },
            .bigint_lit => |b| {
                const text = b.text orelse try std.fmt.allocPrint(self.arena, "{d}", .{b.value});
                _ = try self.chunk.emit(.load_bigint, try self.chunk.addName(text));
            },
            .string => |s| {
                const ci = try self.chunk.addConst(try Value.strAlloc(self.arena, s));
                _ = try self.chunk.emit(.load_const, ci);
            },
            .boolean => |b| _ = try self.chunk.emit(if (b) .load_true else .load_false, 0),
            .null_lit => _ = try self.chunk.emit(.load_null, 0),
            .undefined_lit => _ = try self.chunk.emit(.load_undefined, 0),
            .regex_literal => |r| {
                // A fresh RegExp per evaluation (so `yield /abc/i` works); pattern
                // and flags are stored as names and rebuilt at runtime.
                _ = try self.chunk.emitAB(.make_regex, try self.chunk.addName(r.pattern), try self.chunk.addName(r.flags));
            },
            .identifier => |name| try self.emitLoad(name),
            .unary => |u| {
                // `typeof <unresolved global>` must yield "undefined", not throw,
                // so a global-identifier operand loads non-throwingly.
                if (u.op == .typeof and u.operand.* == .identifier and
                    self.resolve(u.operand.identifier) == .global)
                {
                    _ = try self.chunk.emit(.load_var_or_undef, try self.chunk.addName(u.operand.identifier));
                    _ = try self.chunk.emit(.typeof_op, 0);
                    return;
                }
                try self.compileExpr(u.operand);
                _ = try self.chunk.emit(switch (u.op) {
                    .neg => .neg,
                    .pos => .pos,
                    .not => .not,
                    .typeof => .typeof_op,
                    .bit_not => .bit_not,
                    .void_op => .void_op,
                    .to_string => .to_string,
                }, 0);
            },
            .delete_expr => |target| try self.compileDelete(target),
            .binary => |b| {
                const op: bc.Op = switch (b.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    .pow => .pow,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .eq => .eq,
                    .neq => .neq,
                    .eq_strict => .eq_strict,
                    .neq_strict => .neq_strict,
                    .instanceof => .instance_of,
                    .in_op => .in_op,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shl => .shl,
                    .shr => .shr,
                    .ushr => .ushr,
                };
                if (b.op == .in_op and b.left.* == .identifier and value_mod.isRawPrivateName(b.left.identifier)) {
                    if (!value_mod.isPrivateKey(b.left.identifier)) return error.Unsupported;
                    try self.compileExpr(b.right);
                    _ = try self.chunk.emit(.private_in, try self.chunk.addName(b.left.identifier));
                    return;
                }
                try self.compileExpr(b.left);
                try self.compileExpr(b.right);
                _ = try self.chunk.emit(op, 0);
            },
            .sequence => |s| {
                try self.compileExpr(s.first);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileExpr(s.second);
            },
            .logical => |l| {
                try self.compileExpr(l.left);
                const peek: bc.Op = switch (l.op) {
                    .@"and" => .jump_if_false_peek,
                    .@"or" => .jump_if_true_peek,
                    // ECMA-262 CoalesceExpression evaluates the RHS only when
                    // the left value is null or undefined; falsy values remain
                    // on the stack as the expression result.
                    .nullish => .jump_if_not_nullish_peek,
                };
                const short = try self.chunk.emit(peek, 0);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileExpr(l.right);
                self.chunk.patchToHere(short);
            },
            .assign => |a| switch (a.target.*) {
                .identifier => |name| {
                    try self.compileExpr(a.value);
                    // NamedEvaluation names `x = function(){}` (a bare, unparenthesized
                    // identifier target); `(x) = …` is not an IdentifierRef.
                    if (!a.target_parenthesized) try self.emitNamedEval(a.value, name);
                    try self.emitStore(name);
                },
                .member => |m| {
                    try self.compileExpr(m.object);
                    if (m.computed) |ce| {
                        try self.compileExpr(ce);
                        try self.compileExpr(a.value);
                        _ = try self.chunk.emit(.set_index, 0);
                    } else {
                        try self.compileExpr(a.value);
                        const ni = try self.addMemberName(m.property);
                        _ = try self.chunk.emit(.set_prop, ni);
                    }
                },
                .super_member => try self.compileSuperAssign(a),
                // Destructuring assignment `[a,b] = v` / `{x} = v`. Keep the
                // complete operation in bytecode: frame-mode functions must
                // write their statically resolved slots, while resumable and
                // program chunks use Environment or scratch-backed activation
                // temps. The shared native lowering also preserves suspension
                // in defaults and computed keys.
                .arr_pattern, .obj_pattern => {
                    try self.compileDestructuringAssign(a.target, a.value);
                },
                else => return error.Unsupported,
            },
            // Logical assignment on a member target must resolve the reference
            // once across the read, short-circuit, and possible write.
            .logical_assign => |a| switch (a.target.*) {
                .member => try self.compileMemberLogicalAssign(a),
                .super_member => try self.compileSuperLogicalAssign(a),
                else => return error.Unsupported,
            },
            .op_assign => |oa| switch (oa.target.*) {
                // Identifier target: load the old value, apply the op, store back.
                // #732 owns the broader dynamic-`with` Reference path for
                // ordinary reads/compound/update/call expressions; #731 keeps
                // its activation-owned lowering scoped to destructuring and
                // simple `var` initialization.
                .identifier => |name| {
                    try self.emitLoad(name);
                    try self.compileExpr(oa.value);
                    _ = try self.chunk.emit(try compoundAssignmentOp(oa.op), 0);
                    try self.emitStore(name);
                },
                .member => try self.compileMemberCompoundAssign(oa),
                .super_member => try self.compileSuperCompoundAssign(oa),
                else => return error.Unsupported,
            },
            .conditional => |c| {
                try self.compileExpr(c.cond);
                const to_else = try self.chunk.emit(.jump_if_false, 0);
                try self.compileExpr(c.consequent);
                const to_end = try self.chunk.emit(.jump, 0);
                self.chunk.patchToHere(to_else);
                try self.compileExpr(c.alternate);
                self.chunk.patchToHere(to_end);
            },
            .function => |fnode| {
                const fi = try self.compileFunction(node, fnode, true);
                _ = try self.chunk.emit(.make_closure, fi);
            },
            .class_expr => |c| {
                // `eval_class` delegates deferred member bodies to the
                // tree-walker. Reject only when one actually reads a frame local;
                // global-only methods need no frame Environment and are safe.
                // (Env-mode generators already expose locals in that chain.)
                if (self.scope) |scope|
                    if (try classDeferredBodiesCaptureFrame(self.arena, scope, c.members, c.name)) return error.Unsupported;

                // ClassDefinitionEvaluation creates its lexical Environment before
                // evaluating heritage, and a named class binding is already in TDZ
                // there. Keep that Environment activation-local across suspended
                // heritage/computed names and through class construction.
                try self.pushLexicalScope();
                defer self.popLexicalScope();
                if (c.name.len > 0) if (self.scope) |scope|
                    try scope.addEnvironmentLexical(self.arena, c.name, true);
                try self.emitEnterClassEnvironment();
                if (c.name.len > 0) try self.emitDeclareEnvironmentLexicalName(c.name, true);

                const saved_strict = self.is_strict;
                self.is_strict = true;
                defer self.is_strict = saved_strict;
                var input_count: u32 = 0;
                if (c.superclass) |superclass| {
                    try self.compileExpr(superclass);
                    _ = try self.chunk.emit(.prepare_class_heritage, 0);
                    input_count = 2;
                }
                const computed_count = try self.compileClassComputedKeys(c.members);
                input_count = std.math.add(u32, input_count, computed_count) catch return error.OutOfMemory;
                _ = try self.chunk.emitAB(.eval_class, try self.chunk.addClass(node), input_count);
                try self.emitExitClassEnvironment();
            },
            .call => |c| {
                const spread = hasSpread(c.args);
                if (spread and c.optional) return error.Unsupported;
                if (c.callee.* == .super_member) {
                    try self.compileSuperCall(c, false);
                } else if (c.callee.* == .member and c.callee.member.computed == null) {
                    // `recv.name(args)`: bind `this = recv` at the call site.
                    const m = c.callee.member;
                    const ni = try self.addMemberName(m.property);
                    if (spread) {
                        if (m.optional) return error.Unsupported;
                        try self.compileExpr(m.object);
                        _ = try self.chunk.emit(.dup, 0);
                        _ = try self.chunk.emit(.get_prop, ni);
                        _ = try self.chunk.emit(.swap, 0);
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_with_this_spread, 0);
                    } else {
                        // Fetch the method (RequireObjectCoercible on the receiver +
                        // any getter) BEFORE the arguments, per spec order, then call
                        // with this = recv. Mirrors the computed-member path so a
                        // nullish receiver throws before an argument is evaluated.
                        try self.compileExpr(m.object);
                        _ = try self.chunk.emit(.dup, 0);
                        _ = try self.chunk.emit(.get_prop, ni);
                        _ = try self.chunk.emit(.swap, 0);
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else if (c.callee.* == .member) {
                    const m = c.callee.member;
                    if (m.optional or m.computed == null) return error.Unsupported;
                    try self.compileExpr(m.object);
                    _ = try self.chunk.emit(.dup, 0);
                    try self.compileExpr(m.computed.?);
                    _ = try self.chunk.emit(.get_index, 0);
                    _ = try self.chunk.emit(.swap, 0);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_with_this_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else if (c.callee.* == .optional_chain and c.callee.optional_chain.* == .member) {
                    try self.compileParenthesizedOptionalMemberReference(c.callee.optional_chain.member);
                    _ = try self.chunk.emit(.swap, 0);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_with_this_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else {
                    // A direct `eval(...)` inside a slot-based function must see the
                    // function's locals (and correct `this`/private names), which
                    // live in the environment only on the tree-walker — so bail to
                    // it. Generators/top level (scope == null, env-mode) are fine.
                    const is_eval = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval");
                    if (self.scope != null and is_eval)
                        return error.Unsupported;
                    try self.compileExpr(c.callee);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(if (is_eval) .call_eval_spread else .call_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        // A bare `eval(...)` in an env-mode body is a candidate direct
                        // eval (runs in this scope if the callee is the eval intrinsic).
                        _ = try self.chunk.emit(if (is_eval) .call_eval else .call, @intCast(c.args.len));
                    }
                }
            },
            .optional_chain => |inner| try self.compileOptionalChain(inner, false),
            .this_expr => _ = try self.chunk.emit(.load_this, 0),
            .new_target_expr => _ = try self.chunk.emit(.load_new_target, 0),
            .import_meta => _ = try self.chunk.emit(.load_import_meta, 0),
            .member => |m| {
                try self.compileExpr(m.object);
                if (m.computed) |ce| {
                    try self.compileExpr(ce);
                    _ = try self.chunk.emit(.get_index, 0);
                } else {
                    const ni = try self.addMemberName(m.property);
                    _ = try self.chunk.emit(.get_prop, ni);
                }
            },
            .super_member => |m| {
                // `super.x` / `super[e]` read: GetSuperBase + [[Get]] with `this`
                // receiver, via the super_get opcodes (home_object is live in the
                // generator frame). The call form is handled in the `.call` arm.
                if (m.computed) |ce| {
                    try self.compileExpr(ce);
                    _ = try self.chunk.emit(.super_get_index, 0);
                } else {
                    _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, m.property)));
                }
            },
            .new_expr => |n| {
                try self.compileExpr(n.callee);
                if (hasSpread(n.args)) {
                    try self.compileArgsArray(n.args);
                    _ = try self.chunk.emit(.new_spread, 0);
                } else {
                    for (n.args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.new_call, @intCast(n.args.len));
                }
            },
            .object_lit => |props| {
                _ = try self.chunk.emit(.new_object, 0);
                for (props) |p| {
                    // Object spread lowers everywhere (`init_spread` is the same
                    // CopyDataProperties helper the tree-walker uses), so a nested
                    // non-generator function that spreads (`*g(){ yield {...(()=>({...x}))()} }`)
                    // no longer bails the whole generator. Accessors share the
                    // same DefineProperty path in every bytecode mode.
                    if (p.is_spread or p.accessor != .none) {
                        if (p.is_spread) {
                            try self.compileExpr(p.value); // CopyDataProperties source
                            _ = try self.chunk.emit(.init_spread, 0);
                            continue;
                        }
                        // Getter/setter: push key, push the function, install.
                        if (p.key_expr) |ke| {
                            try self.compileExpr(ke);
                        } else {
                            const ci = try self.chunk.addConst(try Value.strAlloc(self.arena, p.key));
                            _ = try self.chunk.emit(.load_const, ci);
                        }
                        const gi = try self.compileFunction(p.value, p.value.function, false);
                        _ = try self.chunk.emit(.make_closure, gi);
                        _ = try self.chunk.emit(if (p.accessor == .get) .init_getter else .init_setter, 0);
                        continue;
                    }
                    if (p.key_expr) |ke| {
                        // Computed key: evaluate the key and run ToPropertyKey (its
                        // toString/valueOf) BEFORE the value, per the spec's
                        // PropertyDefinitionEvaluation order.
                        try self.compileExpr(ke);
                        _ = try self.chunk.emit(.to_property_key, 0);
                        try self.compileExpr(p.value);
                        _ = try self.chunk.emit(.init_prop_computed, 0);
                    } else {
                        try self.compileExpr(p.value);
                        if (p.proto_setter) {
                            _ = try self.chunk.emit(.init_proto, 0); // `__proto__: v` colon form
                        } else {
                            try self.emitNamedEval(p.value, p.key);
                            _ = try self.chunk.emit(.init_prop, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, p.key)));
                        }
                    }
                }
            },
            .array_lit => |elems| {
                _ = try self.chunk.emit(.new_array, 0);
                for (elems) |e| {
                    if (e.* == .elision) {
                        _ = try self.chunk.emit(.array_append_hole, 0); // `[,]` — a hole
                        continue;
                    }
                    if (e.* == .spread) {
                        try self.compileExpr(e.spread);
                        _ = try self.chunk.emit(.array_spread, 0);
                    } else {
                        try self.compileExpr(e);
                        _ = try self.chunk.emit(.array_append, 0);
                    }
                }
            },
            .update => |u| try self.compileUpdate(u.inc, u.prefix, u.target),
            .tagged_template => |t| try self.compileTaggedTemplate(node, t.tag, t.exprs, false),
            .yield_expr => |y| {
                if (!self.in_generator) return error.Unsupported;
                if (y.delegate) {
                    try self.compileYieldStar(y.argument.?);
                } else {
                    if (y.argument) |arg| try self.compileExpr(arg) else _ = try self.chunk.emit(.load_undefined, 0);
                    // AsyncGeneratorYield first `Await`s the operand, so e.g.
                    // `yield Promise.reject(e)` rejects the pending `next()`.
                    if (self.in_async) _ = try self.chunk.emit(.await_op, 0);
                    _ = try self.chunk.emit(.gen_yield, 0);
                }
            },
            // `await e` suspends like a yield; the async driver promisifies the
            // value and resumes with the settled result (or injects a throw).
            .await_expr => |a| {
                if (!self.in_async) return error.Unsupported;
                try self.compileExpr(a.argument);
                _ = try self.chunk.emit(.await_op, 0);
            },
            .import_call => |ic| {
                try self.compileExpr(ic.specifier);
                if (ic.options) |options|
                    try self.compileExpr(options)
                else
                    _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.import_call, try self.chunk.addName(ic.phase));
            },
            // Statement-only nodes never appear in expression position.
            else => return error.Unsupported,
        }
    }

    /// Prefix yields the new numeric value; postfix yields the old numeric value.
    fn compileUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        switch (target.*) {
            .identifier => |name| {
                // `++`/`--` are ToNumeric(old) ± 1, not `old + 1`: a raw `.add`
                // would string-concatenate a string operand and TypeError a
                // BigInt. The inc/dec opcodes add 1 of the numeric operand type.
                const step: bc.Op = if (inc) .inc else .dec;
                if (prefix) {
                    try self.emitLoad(name);
                    _ = try self.chunk.emit(step, 0);
                    try self.emitStore(name); // leaves the new value
                } else {
                    try self.emitLoad(name);
                    _ = try self.chunk.emit(.to_numeric, 0); // postfix result is the numeric old value
                    _ = try self.chunk.emit(.dup, 0); // keep the numeric old value
                    _ = try self.chunk.emit(step, 0);
                    try self.emitStore(name);
                    _ = try self.chunk.emit(.pop, 0); // discard the new value, leave the old
                }
            },
            .member => try self.compileMemberUpdate(inc, prefix, target),
            .super_member => try self.compileSuperUpdate(inc, prefix, target),
            else => return error.Unsupported,
        }
    }

    /// `yield* X`: delegate to `X`'s iterator per the spec's YieldStar algorithm
    /// (14.4.14 runtime semantics). The desugared loop dispatches on *how the
    /// delegating generator was resumed* — a `gen_yield_star` suspend pushes a
    /// `[value, kind]` pair on resume so the loop can forward `.throw(e)` to the
    /// inner `throw` method and `.return(v)` to the inner `return` method, not
    /// just relay `.next(v)`.
    ///
    /// Pseudocode (kind: 0 = next, 1 = throw, 2 = return):
    ///     it = GetIterator(X); recv_v = undefined; recv_k = 0
    ///     loop:
    ///       if recv_k == 0:  r = it.next(recv_v)
    ///       elif recv_k == 1:
    ///         m = GetMethod(it, "throw")
    ///         if m == undefined: IteratorClose(it); throw TypeError
    ///         r = m.call(it, recv_v)
    ///       else: // recv_k == 2
    ///         m = GetMethod(it, "return")
    ///         if m == undefined: return recv_v        // generator returns
    ///         r = m.call(it, recv_v)
    ///         if r.done: return r.value               // generator returns
    ///         goto yield
    ///       // (next / throw join)
    ///       if not IsObject(r): throw TypeError
    ///       if r.done: break with value r.value
    ///       yield: [recv_v, recv_k] = yield* r.value
    ///     // value of the whole expression:
    ///     r.value
    fn compileYieldStar(self: *Compiler, arg: *Node) CompileError!void {
        const async_d = self.in_async; // delegate to an async iterator?
        const it = try self.freshTemp(); // the iterator
        const r = try self.freshTemp(); // the last `{value, done}` result
        const recv_v = try self.freshTemp(); // value carried by the resume
        const recv_k = try self.freshTemp(); // resume kind: 0 next / 1 throw / 2 return
        const next_m = try self.freshTemp(); // the iterator's captured `next` method
        const m = try self.freshTemp(); // a GetMethod(it, throw|return) result
        const ch = self.chunk;
        const done_n = try ch.addName("done");
        const value_n = try ch.addName("value");

        // it = GetIterator(arg); recv_v = undefined; recv_k = 0 (start with `next`).
        try self.compileExpr(arg);
        _ = try ch.emit(if (async_d) .async_iter_of else .iter_of, 0);
        try self.emitDefine(it);
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("next"));
        try self.emitDefine(next_m);
        _ = try ch.emit(.load_undefined, 0);
        try self.emitDefine(recv_v);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(0)));
        try self.emitDefine(recv_k);

        const top = ch.here();
        // if (recv_k == 0) fall through to the `next` branch, else jump to throw/return.
        try self.emitLoad(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(0)));
        _ = try ch.emit(.eq_strict, 0);
        const to_nonnext = try ch.emit(.jump_if_false, 0);

        // --- next branch: r = next.call(it, recv_v) ---
        try self.emitLoad(next_m);
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        const to_join_a = try ch.emit(.jump, 0); // -> normal/throw join

        // --- recv_k == 1 ? throw branch : return branch ---
        ch.patchToHere(to_nonnext);
        try self.emitLoad(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(1)));
        _ = try ch.emit(.eq_strict, 0);
        const to_return = try ch.emit(.jump_if_false, 0);

        // --- throw branch ---
        // m = GetMethod(it, "throw")
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("throw"));
        try self.emitDefine(m);
        const to_has_throw = try self.emitJumpIfNotStrictlyNullish(m);
        // No `throw` method: IteratorClose(it) (call `return` if present, ignoring
        // its result) then throw a TypeError. Closing first lets the inner
        // iterator release resources, matching the spec.
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefine(m);
        const to_skip_close = try self.emitJumpIfNotStrictlyNullish(m);
        const to_after_close = try ch.emit(.jump, 0); // return absent: skip the call
        ch.patchToHere(to_skip_close);
        try self.emitLoad(m); // func
        try self.emitLoad(it); // this
        _ = try ch.emitAB(.call_with_this, 0, 0); // it.return()
        if (async_d) _ = try ch.emit(.await_op, 0);
        _ = try ch.emit(.pop, 0); // ignore the close result
        ch.patchToHere(to_after_close);
        // throw new TypeError(...)
        _ = try ch.emit(.load_var, try ch.addName("TypeError"));
        _ = try ch.emit(.load_const, try ch.addConst(Value.str("The iterator does not provide a 'throw' method")));
        _ = try ch.emit(.new_call, 1);
        _ = try ch.emit(.throw_op, 0);
        // has a `throw` method: r = m.call(it, recv_v)
        ch.patchToHere(to_has_throw);
        try self.emitLoad(m);
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        const to_join_b = try ch.emit(.jump, 0); // -> normal/throw join

        // --- return branch ---
        ch.patchToHere(to_return);
        // m = GetMethod(it, "return")
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefine(m);
        const to_has_return = try self.emitJumpIfNotStrictlyNullish(m);
        // No `return` method: the delegating generator itself returns recv_v
        // (Await it first in an async generator), running any enclosing finally.
        try self.emitLoad(recv_v);
        if (async_d) _ = try ch.emit(.await_op, 0);
        _ = try ch.emit(.abrupt_return, 0);
        // has a `return` method: r = m.call(it, recv_v)
        ch.patchToHere(to_has_return);
        try self.emitLoad(m);
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        try self.emitLoad(r);
        _ = try ch.emit(.assert_iter_result, 0);
        _ = try ch.emit(.pop, 0);
        // if (r.done) the delegating generator returns r.value; else yield it.
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, done_n);
        const to_return_yield = try ch.emit(.jump_if_false, 0);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, value_n);
        _ = try ch.emit(.abrupt_return, 0);

        // --- normal/throw join: validate r, branch on done ---
        ch.patchToHere(to_join_a);
        ch.patchToHere(to_join_b);
        try self.emitLoad(r);
        _ = try ch.emit(.assert_iter_result, 0);
        _ = try ch.emit(.pop, 0);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, done_n);
        const to_yield = try ch.emit(.jump_if_false, 0);
        const to_end = try ch.emit(.jump, 0); // done -> the whole expression's value

        // --- yield, then resume with [recv_v, recv_k] and loop ---
        // A *sync* generator's `yield*` yields the inner result object itself
        // (`GeneratorYield(innerResult)`), so its own `value`/`done` pass through
        // to the consumer untouched. An *async* generator yields IteratorValue
        // directly here; AsyncFromSyncIteratorContinuation already unwraps sync
        // iterator values, while a real async iterator's yielded promise value
        // must not be unwrapped.
        ch.patchToHere(to_yield);
        ch.patchToHere(to_return_yield);
        if (async_d) {
            try self.emitLoad(r);
            _ = try ch.emit(.get_prop, value_n);
        } else {
            try self.emitLoad(r); // yield the inner result object as-is
        }
        _ = try ch.emit(.gen_yield_star, 0); // resume pushes [value, kind] (kind on top)
        try self.emitStore(recv_k);
        _ = try ch.emit(.pop, 0);
        try self.emitStore(recv_v);
        _ = try ch.emit(.pop, 0);
        if (async_d) {
            // AsyncGeneratorYield resumes through
            // AsyncGeneratorUnwrapYieldResumption, which awaits the completion
            // value before yield* forwards it to next/throw/return handling.
            try self.emitLoad(recv_v);
            _ = try ch.emit(.await_op, 0);
            try self.emitStore(recv_v);
            _ = try ch.emit(.pop, 0);
        }
        _ = try ch.emit(.jump, @intCast(top));

        // yield* evaluates to the final `r.value` when the inner iterator is done.
        ch.patchToHere(to_end);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, value_n);
    }

    fn emitJumpIfNotStrictlyNullish(self: *Compiler, name: []const u8) CompileError!usize {
        const ch = self.chunk;

        try self.emitLoad(name);
        _ = try ch.emit(.load_undefined, 0);
        _ = try ch.emit(.eq_strict, 0);
        const to_check_null = try ch.emit(.jump_if_false, 0);
        const to_absent = try ch.emit(.jump, 0);

        ch.patchToHere(to_check_null);
        try self.emitLoad(name);
        _ = try ch.emit(.load_null, 0);
        _ = try ch.emit(.eq_strict, 0);
        const to_present = try ch.emit(.jump_if_false, 0);

        ch.patchToHere(to_absent);
        return to_present;
    }

    /// One resolved-reference temporary. Function activations keep named
    /// frame/Environment temps; program chunks have neither, so #706
    /// activation-local scratch slots on the running Exec hold them instead of
    /// synthesized global names, which nested or parallel evaluations of the
    /// same program could collide on.
    const ActivationTemp = union(enum) {
        named: []const u8,
        scratch: u32,
    };

    const CompiledMemberRef = struct {
        object: ActivationTemp,
        key: ?ActivationTemp,
        property: []const u8,
    };

    const CompiledSuperRef = struct {
        base: ActivationTemp,
        key: ?ActivationTemp,
        property: []const u8,
    };

    /// Resolve a SuperReference once. Computed references perform
    /// GetThisBinding before evaluating the key, capture GetSuperBase after the
    /// key expression, and optionally defer ToPropertyKey until PutValue (plain
    /// assignment). Activation-owned temps preserve both facts across a
    /// getter/RHS suspension without re-reading the mutable home prototype.
    fn compileSuperRef(
        self: *Compiler,
        target: *Node,
        require_base: bool,
        coerce_key: bool,
    ) CompileError!CompiledSuperRef {
        if (self.mode == .program or target.* != .super_member)
            return error.Unsupported;
        const member = target.super_member;

        var key: ?ActivationTemp = null;
        if (member.computed) |key_expr| {
            _ = try self.chunk.emit(.check_super_this, 0);
            try self.compileExpr(key_expr);
            if (!coerce_key) {
                const key_temp = try self.freshActivationTemp();
                try self.emitDefineActivationTemp(key_temp);
                key = key_temp;
            }
        }

        _ = try self.chunk.emit(.super_base, @intFromBool(require_base));
        const base = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(base);

        if (member.computed != null and coerce_key) {
            _ = try self.chunk.emit(.to_property_key, 0);
            const key_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(key_temp);
            key = key_temp;
        }
        return .{ .base = base, .key = key, .property = member.property };
    }

    fn emitLoadSuperRefBase(self: *Compiler, ref: CompiledSuperRef) CompileError!void {
        try self.emitLoadActivationTemp(ref.base);
        if (ref.key) |key| try self.emitLoadActivationTemp(key);
    }

    fn emitGetSuperRef(self: *Compiler, ref: CompiledSuperRef) CompileError!void {
        try self.emitLoadSuperRefBase(ref);
        _ = try self.chunk.emit(
            if (ref.key != null) .super_get_index_from else .super_get_from,
            if (ref.key != null) 0 else try self.addMemberName(ref.property),
        );
    }

    fn emitSetSuperRef(self: *Compiler, ref: CompiledSuperRef) CompileError!void {
        _ = try self.chunk.emitAB(
            if (ref.key != null) .super_set_index_from else .super_set_from,
            if (ref.key != null) @intFromBool(self.is_strict) else try self.addMemberName(ref.property),
            if (ref.key != null) 0 else @intFromBool(self.is_strict),
        );
    }

    fn compileSuperAssign(self: *Compiler, assignment: anytype) CompileError!void {
        // Assignment evaluates the SuperReference before the RHS but defers a
        // computed ToPropertyKey until PutValue. Capture the raw key and base,
        // then preserve the RHS while that one key coercion runs.
        const ref = try self.compileSuperRef(assignment.target, false, false);
        try self.compileExpr(assignment.value);
        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetSuperRef(ref);
    }

    fn compileSuperLogicalAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const ref = try self.compileSuperRef(assignment.target, true, true);
        try self.emitGetSuperRef(ref);
        const short = try self.chunk.emit(switch (assignment.op) {
            .@"and" => .jump_if_false_peek,
            .@"or" => .jump_if_true_peek,
            .nullish => .jump_if_not_nullish_peek,
        }, 0);

        _ = try self.chunk.emit(.pop, 0);
        try self.compileExpr(assignment.value);
        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetSuperRef(ref);
        self.chunk.patchToHere(short);
    }

    fn compileSuperCompoundAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const ref = try self.compileSuperRef(assignment.target, true, true);
        try self.emitGetSuperRef(ref);
        try self.compileExpr(assignment.value);
        _ = try self.chunk.emit(try compoundAssignmentOp(assignment.op), 0);

        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetSuperRef(ref);
    }

    fn compileMemberRef(self: *Compiler, target: *Node) CompileError!CompiledMemberRef {
        // Optional-chain targets keep their explicit unsupported admission: a
        // deleted/absent base must short-circuit the whole assignment instead
        // of throwing from RequireObjectCoercible, which this Reference shape
        // does not model yet.
        if (target.* != .member or target.member.optional)
            return error.Unsupported;
        const member = target.member;

        // Evaluate the Reference once. Frame-mode temps are real activation
        // slots so recursion cannot overwrite them; environment-mode temps live
        // in the generator/async activation and survive suspension; program
        // chunks hold theirs in #706 activation-local Exec scratch.
        const object = try self.freshActivationTemp();
        try self.compileExpr(member.object);
        try self.emitDefineActivationTemp(object);

        var key: ?ActivationTemp = null;
        if (member.computed) |key_expr| {
            // PropertyAccessors evaluates the key expression before checking
            // the base, but RequireObjectCoercible precedes observable
            // ToPropertyKey. Store the resulting key string so GetValue and
            // PutValue cannot invoke user coercion twice.
            try self.compileExpr(key_expr);
            try self.emitLoadActivationTemp(object);
            _ = try self.chunk.emit(.require_object_coercible, 1);
            _ = try self.chunk.emit(.to_property_key, 0);
            const key_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(key_temp);
            key = key_temp;
        }
        return .{ .object = object, .key = key, .property = member.property };
    }

    fn emitLoadMemberRefBase(self: *Compiler, ref: CompiledMemberRef) CompileError!void {
        try self.emitLoadActivationTemp(ref.object);
        if (ref.key) |key| try self.emitLoadActivationTemp(key);
    }

    fn emitGetMemberRef(self: *Compiler, ref: CompiledMemberRef) CompileError!void {
        try self.emitLoadMemberRefBase(ref);
        _ = try self.chunk.emit(
            if (ref.key != null) .get_index else .get_prop,
            if (ref.key != null) 0 else try self.addMemberName(ref.property),
        );
    }

    fn emitSetMemberRef(self: *Compiler, ref: CompiledMemberRef) CompileError!void {
        _ = try self.chunk.emit(
            if (ref.key != null) .set_index else .set_prop,
            if (ref.key != null) 0 else try self.addMemberName(ref.property),
        );
    }

    fn compileMemberLogicalAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const ref = try self.compileMemberRef(assignment.target);

        try self.emitGetMemberRef(ref);
        const short = try self.chunk.emit(switch (assignment.op) {
            .@"and" => .jump_if_false_peek,
            .@"or" => .jump_if_true_peek,
            .nullish => .jump_if_not_nullish_peek,
        }, 0);

        _ = try self.chunk.emit(.pop, 0);
        try self.emitLoadMemberRefBase(ref);
        // The suspendable VM snapshots its operand stack, so keeping the
        // resolved base/key below the RHS also roots the exact Reference across
        // yield/await without another environment lookup or allocation.
        try self.compileExpr(assignment.value);
        try self.emitSetMemberRef(ref);
        self.chunk.patchToHere(short);
    }

    fn compileMemberCompoundAssign(self: *Compiler, assignment: anytype) CompileError!void {
        // ECMA-262 Assignment Operators: Runtime Semantics: Evaluation resolves
        // lref and performs GetValue before evaluating the RHS, then applies the
        // binary operation before PutValue on that same Reference.
        const ref = try self.compileMemberRef(assignment.target);
        try self.emitGetMemberRef(ref);
        // Binary evaluation retains the pre-RHS old value on the suspendable
        // operand stack, matching GetValue before the RHS and rooting it across
        // yield/await.
        try self.compileExpr(assignment.value);
        _ = try self.chunk.emit(try compoundAssignmentOp(assignment.op), 0);

        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadMemberRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetMemberRef(ref);
    }

    fn compileMemberUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        // ECMA-262 Update Expressions resolves lhs once, then performs GetValue,
        // ToNumeric, the numeric-type-specific ±1, and PutValue in that order.
        const ref = try self.compileMemberRef(target);
        try self.emitGetMemberRef(ref);
        _ = try self.chunk.emit(.to_numeric, 0);

        var old: ?ActivationTemp = null;
        if (!prefix) {
            const old_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(old_temp);
            try self.emitLoadActivationTemp(old_temp);
            old = old_temp;
        }
        _ = try self.chunk.emit(if (inc) .inc else .dec, 0);
        const updated = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(updated);

        try self.emitLoadMemberRefBase(ref);
        try self.emitLoadActivationTemp(updated);
        try self.emitSetMemberRef(ref);
        if (!prefix) {
            _ = try self.chunk.emit(.pop, 0);
            try self.emitLoadActivationTemp(old.?);
        }
    }

    fn compileSuperUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        const ref = try self.compileSuperRef(target, true, true);
        try self.emitGetSuperRef(ref);
        _ = try self.chunk.emit(.to_numeric, 0);

        var old: ?ActivationTemp = null;
        if (!prefix) {
            const old_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(old_temp);
            try self.emitLoadActivationTemp(old_temp);
            old = old_temp;
        }
        _ = try self.chunk.emit(if (inc) .inc else .dec, 0);
        const updated = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(updated);

        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(updated);
        try self.emitSetSuperRef(ref);
        if (!prefix) {
            _ = try self.chunk.emit(.pop, 0);
            try self.emitLoadActivationTemp(old.?);
        }
    }

    fn compoundAssignmentOp(op: ast.BinaryOp) CompileError!bc.Op {
        return switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .shl => .shl,
            .shr => .shr,
            .ushr => .ushr,
            else => error.Unsupported,
        };
    }

    /// A unique, user-unreferenceable temp name (contains a NUL byte).
    fn freshTemp(self: *Compiler) CompileError![]const u8 {
        const n = self.tmp_counter;
        self.tmp_counter += 1;
        return std.fmt.allocPrint(self.arena, "\x00ys{d}", .{n});
    }

    fn freshActivationTemp(self: *Compiler) CompileError!ActivationTemp {
        // Program chunks have neither a frame nor a private activation
        // Environment (#706): a synthesized name would resolve against the
        // shared global environment, so nested or parallel evaluations of the
        // same program could collide on it. Bounded Exec-owned scratch slots
        // keep these temporaries activation-local instead.
        if (self.mode == .program) {
            const index = self.scratch_count;
            self.scratch_count += 1;
            return .{ .scratch = index };
        }
        const name = try self.freshTemp();
        if (self.scope) |scope| _ = try scope.addLocal(self.arena, name, false, false);
        return .{ .named = name };
    }

    fn emitDefineActivationTemp(self: *Compiler, temp: ActivationTemp) CompileError!void {
        switch (temp) {
            .named => |name| return self.emitDefineActivationTempNamed(name),
            .scratch => |index| _ = try self.chunk.emit(.scratch_store, index),
        }
    }

    fn emitDefineActivationTempNamed(self: *Compiler, name: []const u8) CompileError!void {
        if (self.scope != null) return self.emitDefine(name);
        // Env-mode generator/async functions have no frame slots. Keep compiler
        // state in their private activation Environment instead of `def_var`.
        _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), 1);
    }

    fn emitLoadActivationTemp(self: *Compiler, temp: ActivationTemp) CompileError!void {
        switch (temp) {
            .named => |name| return self.emitLoad(name),
            .scratch => |index| _ = try self.chunk.emit(.scratch_load, index),
        }
    }

    fn emitStoreActivationTempDiscard(self: *Compiler, temp: ActivationTemp) CompileError!void {
        switch (temp) {
            .named => |name| {
                try self.emitStore(name);
                _ = try self.chunk.emit(.pop, 0);
            },
            .scratch => |index| _ = try self.chunk.emit(.scratch_store, index),
        }
    }

    fn hasSpread(args: []const *Node) bool {
        for (args) |a| if (a.* == .spread) return true;
        return false;
    }

    fn compileClassComputedKeys(self: *Compiler, members: []const ast.ClassMember) CompileError!u32 {
        var count: u32 = 0;
        for (members) |m| {
            if (m.static_block != null) continue;
            if (m.key_expr) |ke| {
                try self.compileExpr(ke);
                count += 1;
            }
        }
        return count;
    }

    /// Build a fresh array holding a call/new's argument list, expanding any
    /// `...spread` element — for the variadic `*_spread` call opcodes.
    fn compileArgsArray(self: *Compiler, args: []const *Node) CompileError!void {
        _ = try self.chunk.emit(.new_array, 0);
        for (args) |a| {
            if (a.* == .spread) {
                try self.compileExpr(a.spread);
                _ = try self.chunk.emit(.array_spread, 0);
            } else {
                try self.compileExpr(a);
                _ = try self.chunk.emit(.array_append, 0);
            }
        }
    }

    fn compileFunction(
        self: *Compiler,
        definition_node: *const Node,
        fnode: *const ast.FunctionNode,
        named_expr: bool,
    ) CompileError!u32 {
        // Suspendable functions run env-mode and capture the enclosing scope BY
        // NAME (load_var). If the enclosing function is frame-mode (tiered), its
        // locals live in frame slots the suspendable function's Environment chain
        // can't see, so the capture would read a stale/global value. Force that
        // enclosing function to the tree-walker. A program/env-mode scope captures
        // correctly and can retain the compiled generator/async template.
        if ((fnode.is_generator or fnode.is_async) and self.scope != null) return error.Unsupported;
        if (!fnode.is_generator and !fnode.is_async and stmtHasDisposableDecl(fnode.body)) return error.Unsupported;
        if (!fnode.is_generator and functionHasBlockNestedFuncDecl(fnode)) return error.Unsupported;
        // Build this function's slot namespace: parameters first, then every
        // function-scoped declaration in the body (not descending into nested
        // functions). The scope chains to the enclosing function for upvalues.
        const scope = try self.arena.create(FnScope);
        const tdz_checks = !fnode.is_generator and try functionNeedsTdzChecks(self.arena, fnode);
        scope.* = .{
            .parent = self.scope,
            .parent_environment_depth = self.environment_depth,
            .tdz_checks = tdz_checks,
        };

        var template_admission: bc.FnTemplateAdmission = undefined;
        const sub: ?*Chunk = if (fnode.is_generator) blk: {
            const compiled = try Compiler.compileGenerator(self.arena, fnode, self.debug_checkpoints);
            template_admission = .generator_compiled;
            break :blk compiled;
        } else if (fnode.is_async) blk: {
            const compiled = try Compiler.compileAsync(self.arena, fnode, self.debug_checkpoints);
            template_admission = .async_compiled;
            break :blk compiled;
        } else blk: {
            if (fnode.uses_direct_eval) {
                if (self.scope == null) {
                    template_admission = .plain_unsupported_lowering;
                    break :blk null;
                }
                return error.Unsupported;
            }
            const compiled = try self.arena.create(Chunk);
            compiled.* = Chunk.init(self.arena);
            const parameter_slots = try self.arena.alloc(u32, fnode.params.len);
            for (fnode.params, 0..) |p, index| {
                // Default values and rest params need a runtime prologue the VM
                // doesn't emit yet. Generator-body env-mode closures can fall
                // back to the tree-walker because their names live in Environment
                // records. A top-level function can also keep a null chunk and
                // fall back independently because its captures resolve through
                // the global Environment rather than an enclosing VM frame.
                if (p.default != null or p.is_rest or p.pattern != null) {
                    if (self.scope == null) {
                        template_admission = .plain_parameter_prologue;
                        break :blk null;
                    }
                    return error.Unsupported;
                }
                parameter_slots[index] = try scope.addLocal(self.arena, p.name, false, false);
            }
            const arguments_slot = try addArgumentsSlot(self.arena, scope, fnode);
            if (!fnode.is_expr_body) try collectFunctionLocals(self.arena, scope, fnode.body);
            const mapped_parameter_indices = try configureMappedParameters(self.arena, scope, fnode, arguments_slot);

            compiled.param_count = @intCast(fnode.params.len);
            compiled.parameter_slots = parameter_slots;
            compiled.arguments_slot = arguments_slot;
            compiled.mapped_parameter_indices = mapped_parameter_indices;

            var sub_c = Compiler{ .arena = self.arena, .chunk = compiled, .mode = .function, .scope = scope, .is_strict = fnode.is_strict, .debug_checkpoints = self.debug_checkpoints };
            if (fnode.is_expr_body) {
                sub_c.compileExpr(fnode.body) catch |e| switch (e) {
                    error.Unsupported => {
                        if (self.scope == null) {
                            template_admission = .plain_unsupported_lowering;
                            break :blk null;
                        }
                        return error.Unsupported;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                _ = try compiled.emit(.ret, 0);
            } else {
                sub_c.compileStmt(fnode.body) catch |e| switch (e) {
                    error.Unsupported => {
                        if (self.scope == null) {
                            template_admission = .plain_unsupported_lowering;
                            break :blk null;
                        }
                        return error.Unsupported;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                }; // body is a block
                _ = try compiled.emit(.ret_undef, 0);
            }
            compiled.local_count = scope.count;
            compiled.mapped_parameter_indices = try finalizeMappedParameterIndices(self.arena, scope, mapped_parameter_indices);
            compiled.lexical_slots = scope.lexical_slots.items;
            try retainDebugLocalNames(self.arena, compiled, scope);
            try compiled.finalize();
            template_admission = .plain_compiled;
            break :blk compiled;
        };
        if (fnode.is_generator or fnode.is_async) {
            for (fnode.params) |p| _ = try scope.addLocal(self.arena, p.name, false, false);
        }
        const tmpl = try self.arena.create(bc.FnTemplate);
        tmpl.* = .{
            .name = fnode.name,
            .definition_node = definition_node,
            // A *named function expression* (not a declaration, not an inferred
            // name, not a method, not an arrow) self-binds its own name in an
            // enclosing immutable scope — recorded here so `make_closure` wraps
            // the closure env.
            .self_name = if (named_expr and fnode.has_name_binding and !fnode.is_arrow) fnode.name else "",
            .params = fnode.params,
            .is_expr_body = fnode.is_expr_body,
            .body = fnode.body,
            .source = fnode.source,
            .uses_arguments = fnode.uses_arguments,
            .uses_direct_eval = fnode.uses_direct_eval,
            .is_generator = fnode.is_generator,
            .is_async = fnode.is_async,
            .is_arrow = fnode.is_arrow,
            .is_method = fnode.is_method,
            .is_strict = fnode.is_strict,
            .admission = template_admission,
            .chunk = sub,
            .local_count = scope.count,
        };
        return self.chunk.addFn(tmpl);
    }

    // ---- loop bookkeeping -------------------------------------------------

    fn pushLoop(self: *Compiler) CompileError!*Loop {
        const loop = try self.arena.create(Loop);
        loop.* = .{ .finally_depth = self.finally_depth, .environment_depth = self.environment_depth };
        try self.loops.append(self.arena, loop);
        return loop;
    }

    fn pushLabel(self: *Compiler, label: []const u8, labels_iteration: bool) CompileError!*Loop {
        const target = try self.arena.create(Loop);
        target.* = .{
            .label = label,
            .is_loop = false,
            .labels_iteration = labels_iteration,
            .finally_depth = self.finally_depth,
            .environment_depth = self.environment_depth,
        };
        try self.loops.append(self.arena, target);
        return target;
    }

    fn popLoop(self: *Compiler) void {
        _ = self.loops.pop();
    }

    fn currentBreakTarget(self: *Compiler, label: ?[]const u8) ?*Loop {
        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            const target = self.loops.items[i];
            if (label) |needle| {
                if (target.label) |have| if (std.mem.eql(u8, have, needle)) return target;
            } else if (target.is_loop) {
                // An unlabeled `break` targets the innermost iteration statement or
                // switch (both carry is_loop), NOT an enclosing labeled block/stmt
                // wrapper (is_loop == false) — those are only labeled-break targets.
                return target;
            }
        }
        return null;
    }

    /// Resolve an unlabeled continue to the nearest iteration statement. A
    /// labeled continue first finds the label wrapper, verifies that it labels
    /// an iteration statement, then selects that statement's loop through any
    /// intervening label wrappers.
    fn currentContinueTarget(self: *Compiler, label: ?[]const u8) ?*Loop {
        if (label) |needle| {
            var label_index = self.loops.items.len;
            while (label_index > 0) {
                label_index -= 1;
                const target = self.loops.items[label_index];
                if (target.label) |have| if (std.mem.eql(u8, have, needle)) {
                    if (!target.labels_iteration) return null;
                    var loop_index = label_index + 1;
                    while (loop_index < self.loops.items.len) : (loop_index += 1) {
                        const loop = self.loops.items[loop_index];
                        if (loop.is_loop and !loop.is_switch) return loop;
                    }
                    return null;
                };
            }
            return null;
        }

        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            if (self.loops.items[i].is_loop and !self.loops.items[i].is_switch) return self.loops.items[i];
        }
        return null;
    }
};

/// Hoist only function-scoped declarations. Lexical declarations are allocated
/// when their exact block/loop/switch/catch scope is entered during compilation,
/// so same-spelled bindings receive distinct activation slots.
fn collectFunctionLocals(arena: std.mem.Allocator, scope: *FnScope, node: *Node) CompileError!void {
    switch (node.*) {
        .var_decl => |d| {
            if (d.kind == .@"var") _ = try scope.addLocal(arena, d.name, false, false);
        },
        .destructure_decl => |d| if (d.kind == .@"var") {
            var collector = FunctionLocalBindingCollector{ .scope = scope };
            try collectPatternBindingNames(arena, d.pattern, &collector);
        },
        .func_decl => |f| _ = try scope.addLocal(arena, f.name, false, false),
        .block => |stmts| for (stmts) |s| try collectFunctionLocals(arena, scope, s),
        .decl_group => |stmts| for (stmts) |s| try collectFunctionLocals(arena, scope, s),
        .if_stmt => |s| {
            try collectFunctionLocals(arena, scope, s.consequent);
            if (s.alternate) |alt| try collectFunctionLocals(arena, scope, alt);
        },
        .while_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .do_while_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .for_stmt => |f| {
            if (f.init) |ini| try collectFunctionLocals(arena, scope, ini);
            try collectFunctionLocals(arena, scope, f.body);
        },
        .for_in => |f| {
            if (f.decl_kind) |kind| {
                if (kind == .@"var") {
                    var collector = FunctionLocalBindingCollector{ .scope = scope };
                    try collectPatternBindingNames(arena, f.target, &collector);
                }
            }
            try collectFunctionLocals(arena, scope, f.body);
        },
        .switch_stmt => |s| for (s.cases) |c| for (c.body) |st| try collectFunctionLocals(arena, scope, st),
        .labeled_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .try_stmt => |t| {
            try collectFunctionLocals(arena, scope, t.block);
            if (t.catch_block) |cb| try collectFunctionLocals(arena, scope, cb);
            if (t.finally_block) |fb| try collectFunctionLocals(arena, scope, fb);
        },
        // Expressions (incl. nested function/arrow literals) declare no names in
        // this function's scope. `var` inside these statement forms is hoisted to
        // the function scope, matching the tree-walker's hoistVarsIn.
        else => {},
    }
}

const FunctionLocalBindingCollector = struct {
    scope: *FnScope,

    fn add(self: *FunctionLocalBindingCollector, arena: std.mem.Allocator, name: []const u8) CompileError!void {
        _ = try self.scope.addLocal(arena, name, false, false);
    }
};

test "compiler preserves a first-statement debugger checkpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?@import("parser.zig").SourceLocation = null;
    var parser = try @import("parser.zig").Parser.initWithDiagnostic(
        arena.allocator(),
        "debugger; 1;",
        &diagnostic,
    );
    const program = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(arena.allocator(), program);
    try std.testing.expect(chunk.code.items.len >= 2);
    try std.testing.expectEqual(bc.Op.nop, chunk.code.items[0].op);
    try std.testing.expect(chunk.debug_nodes[0] != null);
    try std.testing.expect(chunk.debug_nodes[0].?.* == .debugger_stmt);
}

test "compiler checks hoisted function closure over later lexical TDZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function outer(){ function f(){ return x; } f(); let x; }",
    );
    const program = try parser.parseProgram();
    const outer = program.program[0].func_decl;

    const compiled = try Compiler.compilePlainFunction(arena.allocator(), outer);
    var saw_init = false;
    var saw_captured_check = false;
    for (compiled.chunk.code.items) |inst| {
        if (inst.op == .init_local_lexical) saw_init = true;
    }
    for (compiled.chunk.fns.items) |template| if (template.chunk) |chunk| {
        for (chunk.code.items) |inst| {
            if (inst.op == .load_upval_lexical) saw_captured_check = true;
        }
    };
    try std.testing.expect(saw_init);
    try std.testing.expect(saw_captured_check);
}

test "compiler pending lexical query preserves TDZ classifications" {
    const cases = [_]struct { source: []const u8, hazardous: bool }{
        .{ .source = "function f(){ let value = 1; return value; }", .hazardous = false },
        .{ .source = "function f(){ unrelated; let value = 1; }", .hazardous = false },
        .{ .source = "function f(){ value; let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ let value = value; }", .hazardous = true },
        .{ .source = "function f(){ let [value] = []; }", .hazardous = false },
        .{ .source = "function f(){ let [value = value] = []; }", .hazardous = true },
        .{ .source = "function f(){ let [value = later] = []; let later = 1; }", .hazardous = true },
        .{ .source = "function f(){ let earlier = 1; let [value = earlier] = []; }", .hazardous = false },
        .{ .source = "function f(){ let { [later]: value } = {}; let later = 1; }", .hazardous = true },
        .{ .source = "function f(){ function read(){ return value; } let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ class Box { field = value; } let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ class Box { static field = value; } let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ let value = 1; class Box { field = value; } }", .hazardous = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const binding_inventory = try Compiler.functionBindingInventory(arena.allocator(), program.program[0].func_decl);
        try std.testing.expectEqual(
            case.hazardous,
            try Compiler.functionHasTdzHazard(
                arena.allocator(),
                program.program[0].func_decl,
                &binding_inventory.bindings,
            ),
        );
    }
}

test "compiler plain function binding inventory preserves lexical and shadow classifications" {
    const cases = [_]struct { source: []const u8, has_lexical: bool, has_shadowing: bool }{
        .{ .source = "function f(parameter){ var local; }", .has_lexical = false, .has_shadowing = false },
        .{ .source = "function f(){ let local; }", .has_lexical = true, .has_shadowing = false },
        .{ .source = "function f(){ let [first, second] = []; }", .has_lexical = true, .has_shadowing = false },
        .{ .source = "function f(){ { let local; } { let local; } }", .has_lexical = true, .has_shadowing = true },
        .{ .source = "function f(parameter){ { let parameter; } }", .has_lexical = true, .has_shadowing = true },
        .{ .source = "function f(){ try {} catch (caught) {} }", .has_lexical = true, .has_shadowing = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const inventory = try Compiler.functionBindingInventory(arena.allocator(), program.program[0].func_decl);
        try std.testing.expectEqual(case.has_lexical, inventory.has_lexical);
        try std.testing.expectEqual(case.has_shadowing, inventory.has_shadowing);
    }
}

test "compiler loop binding query preserves capture classifications" {
    const cases = [_]struct { source: []const u8, captured: bool }{
        .{ .source = "function f(){ for (let first = 0; false;) {} }", .captured = false },
        .{ .source = "function f(){ for (let first = 0, last = 1; false;) { (function(){ return unrelated; }); } }", .captured = false },
        .{ .source = "function f(){ for (let first = 0, last = 1; false;) { (function(){ return first; }); } }", .captured = true },
        .{ .source = "function f(){ for (let first = 0, last = 1; false;) { (function(){ return last; }); } }", .captured = true },
        .{ .source = "function f(){ for (let first = function(){ return last; }, last = 1; false;) {} }", .captured = true },
        .{ .source = "function f(){ for (let value = 0; (function(){ return value; });) {} }", .captured = true },
        .{ .source = "function f(){ for (let value = 0; false; (function(){ return value; })) {} }", .captured = true },
        .{ .source = "function f(){ for (let [value, read = function(){ return value; }] = []; false;) {} }", .captured = true },
        .{ .source = "function f(){ for (let value = 0; false;) { class Box { field = value; } } }", .captured = true },
        .{ .source = "function f(){ for (let value of []) { value; } }", .captured = false },
        .{ .source = "function f(){ for (let value of [function(){ return value; }]) {} }", .captured = true },
        .{ .source = "function f(){ for (let [first, last] of []) { (function(){ return last; }); } }", .captured = true },
        .{ .source = "function f(){ for (let value of []) { for (;;) { (function(){ return value; }); } } }", .captured = true },
        // Shadowing remains deliberately conservative, matching the previous
        // exact-name scans until the classifier owns full lexical resolution.
        .{ .source = "function f(){ for (let value of []) { (function(value){ return value; }); } }", .captured = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const body = program.program[0].func_decl.body.block[0];
        const captured = switch (body.*) {
            .for_stmt => |loop| try forLoopCapturesLexical(arena.allocator(), loop.init.?, loop.cond, loop.update, loop.body),
            .for_in => |loop| try forOfCapturesLexical(arena.allocator(), loop.target, loop.var_init, loop.iterable, loop.body),
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.captured, captured);
    }
}

test "compiler repeated body query preserves capture classifications" {
    const cases = [_]struct {
        source: []const u8,
        first: bool = false,
        last: bool = false,
        catch_binding: bool = false,
        any: bool,
    }{
        .{ .source = "function f(){ while(false){ let first=0; let last=1; } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (function(){ return unrelated; }); } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (function(){ return first; }); } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (function(){ return last; }); } }", .last = true, .any = true },
        .{ .source = "function f(){ while(false){ let [first,last]=[]; (function(){ return last; }); } }", .last = true, .any = true },
        .{ .source = "function f(){ while(false){ if(false){ let first=0; (function(){ return first; }); } } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ switch(0){ case 0: let last=1; (function(){ return last; }); } } }", .last = true, .any = true },
        .{ .source = "function f(){ while(false){ try{ let first=0; (function(){ return first; }); }finally{} } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ try{}catch([first,last]){ (function(){ return last; }); } } }", .catch_binding = true, .any = true },
        .{ .source = "function f(){ while(false){ while(false){ let first=0; (function(){ return first; }); } } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; while(false){ (function(){ return first; }); } } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ let last=1; class Box{ field=last; } } }", .last = true, .any = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const statement = program.program[0].func_decl.body.block[0];
        if (statement.* != .while_stmt) return error.TestUnexpectedResult;
        const body = statement.while_stmt.body;
        const captures = try RepeatedBodyCaptures.init(arena.allocator(), body);
        try std.testing.expectEqual(case.first, captures.nameCaptured("first"));
        try std.testing.expectEqual(case.last, captures.nameCaptured("last"));
        try std.testing.expectEqual(case.any, captures.any());
        if (case.catch_binding) {
            if (body.* != .block or body.block.len != 1 or body.block[0].* != .try_stmt)
                return error.TestUnexpectedResult;
            try std.testing.expect(captures.catchPatternCaptured(body.block[0].try_stmt.catch_param.?));
        }
    }
}

test "compiler reports stable plain-function admission reasons" {
    const cases = [_]struct {
        source: []const u8,
        expected: Compiler.PlainFunctionRejection,
    }{
        .{ .source = "function* f(){}", .expected = .generator_or_async },
        .{ .source = "function f(){ using resource = source; }", .expected = .function_scope_disposal },
        .{ .source = "function f(){ { function nested(){} } }", .expected = .block_nested_function_declaration },
        .{ .source = "function f(value = 1){}", .expected = .parameter_prologue },
        .{ .source = "function f(){ return eval('1'); }", .expected = .unsupported_lowering },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const admission = try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl);
        switch (admission) {
            .compiled => return error.TestUnexpectedResult,
            .rejected => |reason| try std.testing.expectEqual(case.expected, reason),
        }
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(arena.allocator(), "function f(holder, value){ holder.value += value; return holder.value + 1; }");
    const program = try parser.parseProgram();
    const admission = try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl);
    switch (admission) {
        .compiled => |compiled| try std.testing.expect(compiled.chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }

    var shadow_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer shadow_arena.deinit();
    var shadow_parser = try @import("parser.zig").Parser.init(
        shadow_arena.allocator(),
        "function f(value){ { let value = 1; } { const value = 2; } return value; }",
    );
    const shadow_program = try shadow_parser.parseProgram();
    const shadow_compiled = try Compiler.compilePlainFunction(shadow_arena.allocator(), shadow_program.program[0].func_decl);
    try std.testing.expectEqual(@as(u32, 3), shadow_compiled.local_count);
    try std.testing.expectEqual(@as(usize, 2), shadow_compiled.chunk.lexical_slots.len);
    for (shadow_compiled.chunk.debug_local_names) |name| try std.testing.expectEqualStrings("value", name);

    var tdz_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tdz_arena.deinit();
    var tdz_parser = try @import("parser.zig").Parser.init(
        tdz_arena.allocator(),
        "function f(){ function read(){ return value; } read(); let value = 1; value = 2; const fixed = 3; fixed = 4; }",
    );
    const tdz_program = try tdz_parser.parseProgram();
    const tdz_admission = try Compiler.admitPlainFunction(tdz_arena.allocator(), tdz_program.program[0].func_decl);
    const tdz_chunk = switch (tdz_admission) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_init = false;
    var saw_checked_local_store = false;
    for (tdz_chunk.code.items) |inst| {
        if (inst.op == .init_local_lexical) saw_init = true;
        if (inst.op == .store_local_lexical) saw_checked_local_store = true;
    }
    try std.testing.expect(saw_init);
    try std.testing.expect(saw_checked_local_store);

    var hot_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer hot_arena.deinit();
    var hot_parser = try @import("parser.zig").Parser.init(
        hot_arena.allocator(),
        "function hot(limit){ let total = 0; for (let i = 0; i < limit; i = i + 1) total = total + i; return total; }",
    );
    const hot_program = try hot_parser.parseProgram();
    const hot_compiled = try Compiler.compilePlainFunction(hot_arena.allocator(), hot_program.program[0].func_decl);
    for (hot_compiled.chunk.code.items) |inst| switch (inst.op) {
        .init_local_lexical, .load_local_lexical, .load_upval_lexical, .store_local_lexical, .store_upval_lexical => return error.TestUnexpectedResult,
        else => {},
    };
}

test "compiler admits global-only class members and rejects frame captures" {
    const admitted = [_][]const u8{
        "function f(seed){ class Box { constructor(value){ this.value = value; } read(){ return this.value; } } return new Box(seed).read(); }",
        "function f(seed){ class Box { [seed](){ return 7; } } return Box; }",
        "function f(){ while(false){ let seed=1; class Box { read(){ return seed; } } } return 7; }",
    };
    for (admitted) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => |compiled| try std.testing.expect(compiled.chunk.code.items.len != 0),
            .rejected => return error.TestUnexpectedResult,
        }
    }

    const rejected = [_][]const u8{
        "function f(seed){ class Box { read(){ return seed; } } return new Box().read(); }",
        "function f(seed){ class Box { field=seed; } return Box; }",
        "function f(seed){ class Box { static { seed; } } return Box; }",
    };
    for (rejected) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => return error.TestUnexpectedResult,
            .rejected => |reason| try std.testing.expectEqual(Compiler.PlainFunctionRejection.unsupported_lowering, reason),
        }
    }

    var private_key_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer private_key_arena.deinit();
    var private_key_parser = try @import("parser.zig").Parser.init(
        private_key_arena.allocator(),
        "function f(){ class Box { #value; [globalThis.#value] = 1; } }",
    );
    const private_key_program = try private_key_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(private_key_arena.allocator(), private_key_program.program[0].func_decl)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.PlainFunctionRejection.unsupported_lowering, reason),
    }
}

test "compiler lowers prepared class heritage across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var ProgramClass = class ProgramNamed extends ProgramBase {}; function plain(Base){ return class Named extends Base { [key()](){} }; } function shadow(Named){ return class Named extends Named { static self(){ return Named; } }; } function* generated(Base){ return class Generated extends (yield Base) { [yield \"key\"](){} }; } async function awaited(Base){ return class Awaited extends (await Base) { [await key()](){} }; } async function* asyncGenerated(Base){ return class AsyncGenerated extends (yield Base) {}; }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 6), program.program.len);

    const program_chunk = switch (try Compiler.admitProgram(arena.allocator(), program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var program_prepares: usize = 0;
    for (program_chunk.code.items) |instruction| {
        if (instruction.op == .prepare_class_heritage) {
            program_prepares += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), program_prepares);

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[1].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const shadow = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[3].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[4].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const async_generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[5].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };

    for ([_]*Chunk{ program_chunk, plain, shadow, generated, awaited, async_generated }) |chunk| {
        var class_phase: u8 = 0;
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .enter_block => if (instruction.a != 0) {
                try std.testing.expectEqual(@as(u8, 0), class_phase);
                class_phase = 1;
            },
            .prepare_class_heritage => {
                try std.testing.expectEqual(@as(u8, 1), class_phase);
                class_phase = 2;
            },
            .eval_class => {
                try std.testing.expectEqual(@as(u8, 2), class_phase);
                try std.testing.expect(instruction.b >= 2);
                class_phase = 3;
            },
            .exit_block => if (instruction.a != 0) {
                try std.testing.expectEqual(@as(u8, 3), class_phase);
                class_phase = 4;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(u8, 4), class_phase);
    }

    // The inner class binding, not the same-spelled parameter, resolves while
    // heritage is evaluated and therefore observes the class TDZ at runtime.
    var shadow_loads_environment = false;
    for (shadow.code.items) |instruction| if (instruction.op == .load_var) {
        if (std.mem.eql(u8, shadow.names.items[instruction.a], "Named")) shadow_loads_environment = true;
    };
    try std.testing.expect(shadow_loads_environment);
}

test "compiler admits captured super assignments and updates" {
    const cases = [_]struct { source: []const u8, set_op: bc.Op }{
        .{ .source = "class Derived extends Base { method(){ return super.value = 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super[key()] = 1; } }", .set_op = .super_set_index_from },
        .{ .source = "class Derived extends Base { method(){ return super.value ??= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value &&= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value ||= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super[key()] += 1; } }", .set_op = .super_set_index_from },
        .{ .source = "class Derived extends Base { method(){ return super.value -= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value *= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value /= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value %= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value **= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value &= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value |= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value ^= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value <<= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value >>= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value >>>= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value++; } }", .set_op = .super_set_from },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const declaration = program.program[0];
        if (declaration.* != .var_decl or declaration.var_decl.init == null)
            return error.TestUnexpectedResult;
        const class = declaration.var_decl.init.?;
        if (class.* != .class_expr or class.class_expr.members.len != 1 or class.class_expr.members[0].func == null)
            return error.TestUnexpectedResult;
        const method = class.class_expr.members[0].func.?;
        if (method.* != .function) return error.TestUnexpectedResult;
        switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
            .compiled => |compiled| {
                var saw_set = false;
                for (compiled.chunk.code.items) |instruction|
                    saw_set = saw_set or instruction.op == case.set_op;
                try std.testing.expect(saw_set);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }
}

test "compiler admits computed and super tagged template references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function tagged(holder, key, value){ \"use strict\"; return holder[key]`a${value}b`; }",
    );
    const program = try parser.parseProgram();
    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_member = false;
    for (plain.code.items) |inst| if (inst.op == .tail_call_with_this) {
        saw_tail_member = true;
    };
    try std.testing.expect(saw_tail_member);

    var class_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "class Derived extends Base { method(value){ \"use strict\"; return super.tag`a${value}b`; } *generated(){ return super[yield \"key\"]`g${yield \"value\"}z`; } async awaited(){ return super[await Promise.resolve(\"tag\")]`p${await Promise.resolve(1)}q`; } }",
    );
    const class_program = try class_parser.parseProgram();
    const declaration = class_program.program[0];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 3)
        return error.TestUnexpectedResult;

    const method = class.class_expr.members[0].func orelse return error.TestUnexpectedResult;
    const method_chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_super = false;
    for (method_chunk.code.items) |inst| if (inst.op == .tail_call_with_this) {
        saw_tail_super = true;
    };
    try std.testing.expect(saw_tail_super);

    const generated = class.class_expr.members[1].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitGenerator(arena.allocator(), generated.function, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
    const awaited = class.class_expr.members[2].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitAsync(arena.allocator(), awaited.function, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers super calls in tail and receiver-aware spread positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "class Derived extends Base { named(value){ return super.method(value); } computed(key, value){ return super[key](value); } *spread(args){ var value = super[\"method\"](...args); yield value; } *suspended(){ var value = super[yield \"key\"](yield \"argument\"); return value; } tailSpread(args){ return super.method(...args); } tailSpreadComputed(key, args){ return super[key](...args); } }",
    );
    const program = try parser.parseProgram();
    const declaration = program.program[0];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 6)
        return error.TestUnexpectedResult;

    for (class.class_expr.members[0..2]) |member| {
        const method = member.func orelse return error.TestUnexpectedResult;
        const chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
            .compiled => |compiled| compiled.chunk,
            .rejected => return error.TestUnexpectedResult,
        };
        var saw_super_tail = false;
        for (chunk.code.items) |inst| if (inst.op == .tail_call_with_this) {
            saw_super_tail = true;
        };
        try std.testing.expect(saw_super_tail);
    }

    const spread = class.class_expr.members[2].func orelse return error.TestUnexpectedResult;
    const spread_chunk = switch (try Compiler.admitGenerator(arena.allocator(), spread.function, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_receiver_spread = false;
    for (spread_chunk.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_receiver_spread = true;
    };
    try std.testing.expect(saw_receiver_spread);

    const suspended = class.class_expr.members[3].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitGenerator(arena.allocator(), suspended.function, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }

    for (class.class_expr.members[4..6]) |member| {
        const tail_spread = member.func orelse return error.TestUnexpectedResult;
        switch (try Compiler.admitPlainFunction(arena.allocator(), tail_spread.function)) {
            .compiled => |compiled| {
                var saw_tail_spread = false;
                for (compiled.chunk.code.items) |inst| if (inst.op == .tail_call_with_this_spread) {
                    saw_tail_spread = true;
                };
                try std.testing.expect(saw_tail_spread);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }
}

test "compiler lowers ordinary spread calls and constructors across tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(fn, holder, key, args){ var direct = fn(0, ...args, 3); var named = holder.method(...args); var computed = holder[key](...args); var constructed = new fn(...args); return direct + named + computed + constructed.value; } async function awaited(fn, holder, key, args){ var direct = fn(...await Promise.resolve(args)); var computed = holder[await Promise.resolve(key)](...args); var constructed = new fn(...args); return direct + computed + constructed.value; } function tail(args){ \"use strict\"; return tail(...args); } function evalBarrier(args){ var value = eval(...args); return value; } function optional(holder, args){ var value = holder.method?.(...args); return value; } class Derived extends Base { spread(args){ var value = super.method(...args); return value; } async awaited(args){ var value = super[await Promise.resolve(\"method\")](...args); return value; } }",
    );
    const program = try parser.parseProgram();
    if (program.program.len != 6) return error.TestUnexpectedResult;

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var calls: usize = 0;
    var receiver_calls: usize = 0;
    var constructors: usize = 0;
    for (plain.code.items) |inst| switch (inst.op) {
        .call_spread => calls += 1,
        .call_with_this_spread => receiver_calls += 1,
        .new_spread => constructors += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 2), receiver_calls);
    try std.testing.expectEqual(@as(usize, 1), constructors);

    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    calls = 0;
    receiver_calls = 0;
    constructors = 0;
    for (awaited.code.items) |inst| switch (inst.op) {
        .call_spread => calls += 1,
        .call_with_this_spread => receiver_calls += 1,
        .new_spread => constructors += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), receiver_calls);
    try std.testing.expectEqual(@as(usize, 1), constructors);

    const tail = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_spread = false;
    for (tail.code.items) |inst| if (inst.op == .tail_call_spread) {
        saw_tail_spread = true;
    };
    try std.testing.expect(saw_tail_spread);

    switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[3].func_decl)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.PlainFunctionRejection.unsupported_lowering, reason),
    }

    const optional = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[4].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_optional_receiver_spread = false;
    for (optional.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_optional_receiver_spread = true;
    };
    try std.testing.expect(saw_optional_receiver_spread);

    const declaration = program.program[5];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;
    const super_plain = class.class_expr.members[0].func orelse return error.TestUnexpectedResult;
    const super_plain_chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), super_plain.function)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_plain_super_spread = false;
    for (super_plain_chunk.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_plain_super_spread = true;
    };
    try std.testing.expect(saw_plain_super_spread);
    const super_async = class.class_expr.members[1].func orelse return error.TestUnexpectedResult;
    const super_async_chunk = switch (try Compiler.admitAsync(arena.allocator(), super_async.function, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_async_super_spread = false;
    for (super_async_chunk.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_async_super_spread = true;
    };
    try std.testing.expect(saw_async_super_spread);

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var spreadProgramResult = spreadProgramFn(1, ...spreadProgramArgs, 3); var spreadProgramConstructed = new spreadProgramFn(...spreadProgramArgs); var spreadProgramEval = eval(...spreadProgramEvalArgs);",
    );
    const spread_program = try program_parser.parseProgram();
    const program_chunk = switch (try Compiler.admitProgram(arena.allocator(), spread_program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_program_call = false;
    var saw_program_eval = false;
    var saw_program_constructor = false;
    for (program_chunk.code.items) |inst| switch (inst.op) {
        .call_spread => saw_program_call = true,
        .call_eval_spread => saw_program_eval = true,
        .new_spread => saw_program_constructor = true,
        else => {},
    };
    try std.testing.expect(saw_program_call and saw_program_eval and saw_program_constructor);
}

test "compiler lowers proper tail calls with spread arguments across tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function direct(fn, args){ \"use strict\"; return fn(0, ...args, 3); } function named(holder, args){ \"use strict\"; return holder.method(...args); } function computed(holder, key, args){ \"use strict\"; return holder[key](...args); } function optional(holder, args){ \"use strict\"; return holder?.method?.(...args); } function parenthesized(holder, args){ \"use strict\"; return (holder?.method)(...args); } function optionalEval(args){ \"use strict\"; return eval?.(...args); } function evalSpreadBarrier(args){ \"use strict\"; var local = 1; return eval(...args); } function evalFixedBarrier(){ \"use strict\"; var local = 1; return eval(\"local\"); } function* generated(fn, args){ \"use strict\"; yield 0; return fn(...args); } function* generatedEval(args){ \"use strict\"; yield 0; return eval(...args); } async function awaited(fn, args){ \"use strict\"; await 0; return fn(...args); } async function* asyncGenerated(fn, args){ \"use strict\"; yield 0; return fn(...args); } function sloppy(fn, args){ return fn(...args); }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 13), program.program.len);

    for (program.program[0..6], 0..) |declaration, index| {
        const chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), declaration.func_decl)) {
            .compiled => |compiled| compiled.chunk,
            .rejected => return error.TestUnexpectedResult,
        };
        const expected: bc.Op = if (index == 0 or index == 5) .tail_call_spread else .tail_call_with_this_spread;
        var saw_expected = false;
        for (chunk.code.items) |inst| if (inst.op == expected) {
            saw_expected = true;
        };
        try std.testing.expect(saw_expected);
    }

    // Spread and fixed-arity direct eval both require the function's dynamic
    // environment; tail position cannot make frame-local bindings observable.
    for (program.program[6..8]) |declaration| switch (try Compiler.admitPlainFunction(arena.allocator(), declaration.func_decl)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.PlainFunctionRejection.unsupported_lowering, reason),
    };

    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[8].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated_eval = switch (try Compiler.admitGenerator(arena.allocator(), program.program[9].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[10].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const async_generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[11].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var concise_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var concise = async (fn, args) => fn(...args);",
    );
    const concise_program = try concise_parser.parseModule();
    const concise_node = concise_program.program[0].var_decl.init orelse return error.TestUnexpectedResult;
    if (concise_node.* != .function) return error.TestUnexpectedResult;
    try std.testing.expect(concise_node.function.is_strict and concise_node.function.is_expr_body);
    const concise = switch (try Compiler.admitAsync(arena.allocator(), concise_node.function, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    // ECMA-262 §15.10.1 IsInTailPosition, steps 4-7, excludes generator,
    // async-function, async-generator, and async concise bodies. Their return
    // wrappers keep ordinary spread operations even for a strict
    // return-position call.
    for ([_]*Chunk{ generated, awaited, async_generated, concise }) |chunk| {
        var saw_ordinary_spread = false;
        for (chunk.code.items) |inst| switch (inst.op) {
            .call_spread => saw_ordinary_spread = true,
            .tail_call_spread => return error.TestUnexpectedResult,
            else => {},
        };
        try std.testing.expect(saw_ordinary_spread);
    }
    var saw_eval_spread = false;
    for (generated_eval.code.items) |inst| switch (inst.op) {
        .call_eval_spread => saw_eval_spread = true,
        .tail_call_spread => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_eval_spread);

    const sloppy = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[12].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_ordinary_spread = false;
    var saw_return = false;
    for (sloppy.code.items) |inst| switch (inst.op) {
        .call_spread => saw_ordinary_spread = true,
        .ret => saw_return = true,
        .tail_call_spread => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_ordinary_spread and saw_return);
}

test "compiler lowers optional chains across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(holder, key, args){ var read = holder?.[key]?.value; var called = holder?.method?.(...args); return read ?? called; } function tail(holder){ \"use strict\"; return holder?.method?.(); } function tailSpread(holder, args){ \"use strict\"; return holder?.method?.(...args); } function* generated(holder){ return holder?.[yield \"key\"]?.(yield \"argument\")?.value; } async function awaited(holder){ return holder?.[await Promise.resolve(\"method\")]?.(await Promise.resolve(1))?.value; }",
    );
    const program = try parser.parseProgram();
    if (program.program.len != 5) return error.TestUnexpectedResult;

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var nullish_exits: usize = 0;
    var receiver_spreads: usize = 0;
    for (plain.code.items) |inst| switch (inst.op) {
        .jump_if_nullish_peek => nullish_exits += 1,
        .call_with_this_spread => receiver_spreads += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), nullish_exits);
    try std.testing.expectEqual(@as(usize, 1), receiver_spreads);

    const tail = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[1].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_call = false;
    var saw_short_return = false;
    for (tail.code.items) |inst| switch (inst.op) {
        .tail_call_with_this => saw_tail_call = true,
        .ret_undef => saw_short_return = true,
        else => {},
    };
    try std.testing.expect(saw_tail_call and saw_short_return);

    switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| {
            var saw_tail_spread = false;
            var saw_optional_short_return = false;
            for (compiled.chunk.code.items) |inst| switch (inst.op) {
                .tail_call_with_this_spread => saw_tail_spread = true,
                .ret_undef => saw_optional_short_return = true,
                else => {},
            };
            try std.testing.expect(saw_tail_spread and saw_optional_short_return);
        },
        .rejected => return error.TestUnexpectedResult,
    }
    switch (try Compiler.admitGenerator(arena.allocator(), program.program[3].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
    switch (try Compiler.admitAsync(arena.allocator(), program.program[4].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var optionalProgram = optionalProgramHolder?.method?.(1)?.value;",
    );
    const optional_program = try program_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), optional_program)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers owned for-in enumeration across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(object, holder){ var out = ''; for (var key in object) out += key; for (holder.key in object) break; for (const [first] in object) out += first; return out; } function* generated(object){ for (let key in object) yield key; } async function awaited(object){ var out = ''; for (const key in object) { await 0; out += key; } return out; }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), program.program.len);

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[2].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    for ([_]*Chunk{ plain, generated, awaited }) |chunk| {
        var snapshots: usize = 0;
        var live_checks: usize = 0;
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .enum_keys => snapshots += 1,
            .enum_next => live_checks += 1,
            else => {},
        };
        try std.testing.expect(snapshots > 0);
        try std.testing.expectEqual(snapshots, live_checks);
    }

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var forInProgram = '', holder = {}; for (var key in forInProgramObject) forInProgram += key; for (const [first] in forInProgramObject) forInProgram += first; for (holder.key in forInProgramObject) break;",
    );
    const program_node = try program_parser.parseProgram();
    const program_chunk = switch (try Compiler.admitProgram(arena.allocator(), program_node)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_program_snapshot = false;
    var saw_program_live_check = false;
    for (program_chunk.code.items) |instruction| switch (instruction.op) {
        .enum_keys => saw_program_snapshot = true,
        .enum_next => saw_program_live_check = true,
        else => {},
    };
    try std.testing.expect(saw_program_snapshot and saw_program_live_check);
    try std.testing.expect(program_chunk.scratch_count > 0);
}

test "compiler lowers property deletion across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(holder, key){ var named = delete holder.value; var computed = delete holder[key]; var optional = delete holder?.[key]?.value; var terminated = delete (holder?.value).nested; var nonref = delete sideEffect(); return named && computed && optional && terminated && nonref; } function* generated(holder){ \"use strict\"; return delete holder?.[yield \"key\"]; } async function awaited(holder){ \"use strict\"; return delete holder?.[await getKey()]; } function binding(name){ return delete name; } class Derived extends Base { method(){ return delete super.value; } computed(){ return delete super[yieldKey()]; } }",
    );
    const program = try parser.parseProgram();
    if (program.program.len != 5) return error.TestUnexpectedResult;

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var named_deletes: usize = 0;
    var computed_deletes: usize = 0;
    var optional_exits: usize = 0;
    for (plain.code.items) |inst| switch (inst.op) {
        .delete_prop => named_deletes += 1,
        .delete_index => computed_deletes += 1,
        .jump_if_nullish_peek => optional_exits += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), named_deletes);
    try std.testing.expectEqual(@as(usize, 1), computed_deletes);
    try std.testing.expect(optional_exits >= 2);

    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_generator_delete = false;
    for (generated.code.items) |inst| if (inst.op == .delete_index) {
        saw_generator_delete = true;
        try std.testing.expectEqual(@as(u32, 1), inst.a);
    };
    try std.testing.expect(saw_generator_delete);

    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[2].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_async_delete = false;
    for (awaited.code.items) |inst| if (inst.op == .delete_index) {
        saw_async_delete = true;
        try std.testing.expectEqual(@as(u32, 1), inst.a);
    };
    try std.testing.expect(saw_async_delete);

    const binding = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[3].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_local_false = false;
    for (binding.code.items) |inst| switch (inst.op) {
        .load_false => saw_local_false = true,
        .delete_name => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_local_false);
    const declaration = program.program[4];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;
    for (class.class_expr.members) |member| {
        const method = member.func orelse return error.TestUnexpectedResult;
        switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
            .compiled => |compiled| {
                var saw_super_delete = false;
                for (compiled.chunk.code.items) |inst| {
                    if (inst.op == .delete_super) saw_super_delete = true;
                }
                try std.testing.expect(saw_super_delete);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "\"use strict\"; var deleteProgramHolder = { value: 1 }; var deleteProgramResult = delete deleteProgramHolder.value;",
    );
    const delete_program = try program_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), delete_program)) {
        .compiled => |chunk| {
            var saw_program_delete = false;
            for (chunk.code.items) |inst| if (inst.op == .delete_prop) {
                saw_program_delete = true;
                try std.testing.expectEqual(@as(u32, 1), inst.b);
            };
            try std.testing.expect(saw_program_delete);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler gives arguments owners precise frame slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function own(value){ \"use strict\"; return arguments[0] + arguments.length; } function outer(value){ \"use strict\"; var ownLength = arguments.length; var arrow = () => arguments[0]; function inner(other){ \"use strict\"; return arguments[0]; } return ownLength + arrow() + inner(value); } var holder = { method(value){ \"use strict\"; return arguments[0]; } }; function Constructor(value){ \"use strict\"; this.value = arguments[0]; } function sloppy(value){ value = arguments[0] + 1; arguments[0] = value + 1; return value + arguments[0]; } function sloppyOuter(value){ var arrow = () => { value = value + 1; return value + arguments[0]; }; return arrow(); } function parameterArguments(arguments){ arguments = arguments + 1; return arguments; } function evalOwner(){ \"use strict\"; return eval(\"arguments[0]\"); } function evalReference(){ \"use strict\"; return eval; }",
    );
    const program = try parser.parseProgram();
    const chunk = switch (try Compiler.admitProgram(arena.allocator(), program)) {
        .compiled => |compiled| compiled,
        .rejected => return error.TestUnexpectedResult,
    };

    const Helper = struct {
        fn named(owner: *Chunk, name: []const u8) ?*bc.FnTemplate {
            for (owner.fns.items) |template| if (std.mem.eql(u8, template.name, name)) return template;
            return null;
        }

        fn expectOwnArguments(template: *bc.FnTemplate) !u32 {
            const compiled = template.chunk orelse return error.TestUnexpectedResult;
            const slot = compiled.arguments_slot orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(compiled.param_count, slot);
            try std.testing.expect(slot < compiled.local_count);
            try std.testing.expectEqualStrings("arguments", compiled.debug_local_names[slot]);
            var saw_load = false;
            for (compiled.code.items) |instruction| {
                if (instruction.op == .load_local and instruction.a == slot) saw_load = true;
            }
            try std.testing.expect(saw_load);
            return slot;
        }
    };

    _ = try Helper.expectOwnArguments(Helper.named(chunk, "own") orelse return error.TestUnexpectedResult);
    _ = try Helper.expectOwnArguments(Helper.named(chunk, "method") orelse return error.TestUnexpectedResult);
    _ = try Helper.expectOwnArguments(Helper.named(chunk, "Constructor") orelse return error.TestUnexpectedResult);

    const outer_template = Helper.named(chunk, "outer") orelse return error.TestUnexpectedResult;
    const outer_slot = try Helper.expectOwnArguments(outer_template);
    const outer_chunk = outer_template.chunk.?;
    const inner_template = Helper.named(outer_chunk, "inner") orelse return error.TestUnexpectedResult;
    _ = try Helper.expectOwnArguments(inner_template);

    var arrow_template: ?*bc.FnTemplate = null;
    for (outer_chunk.fns.items) |template| if (template.is_arrow) {
        arrow_template = template;
        break;
    };
    const arrow_chunk = (arrow_template orelse return error.TestUnexpectedResult).chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, null), arrow_chunk.arguments_slot);
    var saw_outer_arguments = false;
    for (arrow_chunk.code.items) |instruction| {
        if (instruction.op == .load_upval and instruction.a == 1 and instruction.b == outer_slot)
            saw_outer_arguments = true;
    }
    try std.testing.expect(saw_outer_arguments);

    const sloppy = Helper.named(chunk, "sloppy") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bc.FnTemplateAdmission.plain_compiled, sloppy.admission);
    const sloppy_chunk = sloppy.chunk orelse return error.TestUnexpectedResult;
    const sloppy_arguments_slot = sloppy_chunk.arguments_slot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sloppy_chunk.local_count, sloppy_chunk.mapped_parameter_indices.len);
    try std.testing.expectEqual(@as(u32, 0), sloppy_chunk.mapped_parameter_indices[0]);
    try std.testing.expectEqual(std.math.maxInt(u32), sloppy_chunk.mapped_parameter_indices[sloppy_arguments_slot]);
    var saw_mapped_load = false;
    var saw_mapped_store = false;
    for (sloppy_chunk.code.items) |instruction| switch (instruction.op) {
        .load_local_mapped => saw_mapped_load = true,
        .store_local_mapped => saw_mapped_store = true,
        else => {},
    };
    try std.testing.expect(saw_mapped_load and saw_mapped_store);

    const sloppy_outer = Helper.named(chunk, "sloppyOuter") orelse return error.TestUnexpectedResult;
    const sloppy_outer_chunk = sloppy_outer.chunk orelse return error.TestUnexpectedResult;
    var sloppy_arrow: ?*bc.FnTemplate = null;
    for (sloppy_outer_chunk.fns.items) |template| if (template.is_arrow) {
        sloppy_arrow = template;
        break;
    };
    const sloppy_arrow_chunk = (sloppy_arrow orelse return error.TestUnexpectedResult).chunk orelse return error.TestUnexpectedResult;
    var saw_mapped_upvalue_load = false;
    var saw_mapped_upvalue_store = false;
    for (sloppy_arrow_chunk.code.items) |instruction| switch (instruction.op) {
        .load_upval_mapped => saw_mapped_upvalue_load = true,
        .store_upval_mapped => saw_mapped_upvalue_store = true,
        else => {},
    };
    try std.testing.expect(saw_mapped_upvalue_load and saw_mapped_upvalue_store);

    const parameter_arguments = Helper.named(chunk, "parameterArguments") orelse return error.TestUnexpectedResult;
    const parameter_arguments_chunk = parameter_arguments.chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, null), parameter_arguments_chunk.arguments_slot);
    try std.testing.expectEqual(@as(usize, 0), parameter_arguments_chunk.mapped_parameter_indices.len);

    const eval_owner = Helper.named(chunk, "evalOwner") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bc.FnTemplateAdmission.plain_unsupported_lowering, eval_owner.admission);
    try std.testing.expect(eval_owner.uses_direct_eval);
    try std.testing.expect(!eval_owner.uses_arguments);
    try std.testing.expectEqual(@as(?*Chunk, null), eval_owner.chunk);

    const eval_reference = Helper.named(chunk, "evalReference") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!eval_reference.uses_direct_eval);
    try std.testing.expect(!eval_reference.uses_arguments);
    try std.testing.expectEqual(@as(?u32, null), eval_reference.chunk.?.arguments_slot);
}

test "compiler bounds identifier deletion before frame bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function* generated(name){ yield 0; return delete name; } async function awaited(name){ await 0; return delete name; } function outer(name, holder){ var nested; with (holder) { nested = function(){ return delete name; }; } return nested; } function deepOuter(name, first){ var middle; with (first) { middle = function(second){ var nested; with (second) { nested = function(){ return delete name; }; } return nested; }; } return middle; } delete missingGlobalName;",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), program.program.len);

    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[0].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    for ([_]*Chunk{ generated, awaited }) |chunk| {
        var saw_full_delete = false;
        for (chunk.code.items) |inst| if (inst.op == .delete_name) {
            saw_full_delete = true;
            try std.testing.expectEqual(bc.delete_name_full_environment_depth, inst.b);
        };
        try std.testing.expect(saw_full_delete);
    }

    const outer = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), outer.fns.items.len);
    const nested = outer.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    var saw_bounded_delete = false;
    for (nested.code.items) |inst| if (inst.op == .delete_name) {
        saw_bounded_delete = true;
        try std.testing.expectEqual(@as(u32, 1), inst.b);
    };
    try std.testing.expect(saw_bounded_delete);

    const deep_outer = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[3].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), deep_outer.fns.items.len);
    const middle = deep_outer.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), middle.fns.items.len);
    const deep_nested = middle.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    var saw_deep_bounded_delete = false;
    for (deep_nested.code.items) |inst| if (inst.op == .delete_name) {
        saw_deep_bounded_delete = true;
        try std.testing.expectEqual(@as(u32, 2), inst.b);
    };
    try std.testing.expect(saw_deep_bounded_delete);

    const compiled_program = switch (try Compiler.admitProgram(arena.allocator(), program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_program_delete = false;
    for (compiled_program.code.items) |inst| if (inst.op == .delete_name) {
        saw_program_delete = true;
        try std.testing.expectEqual(bc.delete_name_full_environment_depth, inst.b);
    };
    try std.testing.expect(saw_program_delete);

    var arguments_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plainArguments(){ return delete arguments; }",
    );
    const arguments_program = try arguments_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(arena.allocator(), arguments_program.program[0].func_decl)) {
        .compiled => |compiled| {
            var saw_local_false = false;
            for (compiled.chunk.code.items) |inst| switch (inst.op) {
                .load_false => saw_local_false = true,
                .delete_name => return error.TestUnexpectedResult,
                else => {},
            };
            try std.testing.expect(saw_local_false);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers import.meta across module function tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "export function plain(){ return import.meta; } export function* generated(){ yield import.meta; return import.meta; } export async function awaited(){ await 0; return import.meta; }",
    );
    const program = try parser.parseModule();
    try std.testing.expectEqual(@as(usize, 3), program.program.len);

    const functions = try arena.allocator().alloc(*const ast.FunctionNode, program.program.len);
    for (program.program, functions) |item, *function| {
        if (item.* != .export_decl) return error.TestUnexpectedResult;
        const declaration = item.export_decl.declaration orelse return error.TestUnexpectedResult;
        if (declaration.* != .func_decl) return error.TestUnexpectedResult;
        function.* = declaration.func_decl;
    }

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), functions[0])) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated = switch (try Compiler.admitGenerator(arena.allocator(), functions[1], true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), functions[2], true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };

    for ([_]*Chunk{ plain, generated, awaited }) |chunk| {
        var import_meta_loads: usize = 0;
        for (chunk.code.items) |instruction|
            if (instruction.op == .load_import_meta) {
                import_meta_loads += 1;
            };
        try std.testing.expect(import_meta_loads > 0);
    }
}

test "compiler lowers plain-function destructuring assignments without bind_pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function assign(source, holder){ let first, nested, tail, result; result = ([first, { value: nested = 3, ...holder.rest }, ...tail] = source); return result === source ? first + nested + tail.length : -1; }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };

    var saw_iterator = false;
    var saw_object_rest = false;
    var saw_frame_store = false;
    for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
        .bind_pattern => return error.TestUnexpectedResult,
        .iter_of => saw_iterator = true,
        .object_rest => saw_object_rest = true,
        .store_local, .store_local_lexical => saw_frame_store = true,
        else => {},
    };
    try std.testing.expect(saw_iterator);
    try std.testing.expect(saw_object_rest);
    try std.testing.expect(saw_frame_store);

    var closure_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function outer(source){ let captured; function assign(){ ([captured, globalTarget] = source); } return assign; }",
    );
    const closure_program = try closure_parser.parseProgram();
    const closure_compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), closure_program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_upvalue_store = false;
    var saw_global_store = false;
    for (closure_compiled.chunk.fns.items) |template| if (template.chunk) |chunk| {
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .bind_pattern => return error.TestUnexpectedResult,
            .store_upval, .store_upval_lexical => saw_upvalue_store = true,
            .store_var, .store_binding_ref => saw_global_store = true,
            else => {},
        };
    };
    try std.testing.expect(saw_upvalue_store);
    try std.testing.expect(saw_global_store);

    var with_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function assign(source, object){ with (object) { ([value] = source); } }",
    );
    const with_program = try with_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(arena.allocator(), with_program.program[0].func_decl)) {
        .compiled => |result| {
            try std.testing.expect(result.chunk.binding_reference_plans.items.len > 0);
            var saw_resolve = false;
            var saw_store = false;
            for (result.chunk.code.items) |instruction| switch (instruction.op) {
                .resolve_binding_ref => saw_resolve = true,
                .store_binding_ref => saw_store = true,
                .bind_pattern => return error.TestUnexpectedResult,
                else => {},
            };
            try std.testing.expect(saw_resolve and saw_store);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers plain-function destructuring declarations without bind_pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function declare(source){ var [first, { value: nested = 3, ...rest }, ...tail] = source; { let { extra: lexical = fixed } = rest; const [fixed] = tail; return first + nested + lexical + fixed; } }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };

    var saw_iterator = false;
    var saw_object_rest = false;
    var saw_frame_store = false;
    var saw_lexical_init = false;
    for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
        .bind_pattern => return error.TestUnexpectedResult,
        .iter_of => saw_iterator = true,
        .object_rest => saw_object_rest = true,
        .store_local, .store_local_lexical, .store_local_mapped => saw_frame_store = true,
        .init_local_lexical => saw_lexical_init = true,
        else => {},
    };
    try std.testing.expect(saw_iterator);
    try std.testing.expect(saw_object_rest);
    try std.testing.expect(saw_frame_store);
    try std.testing.expect(saw_lexical_init);

    var loop_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function loop(values){ for (var [first, second] of values) {} return first + second; }",
    );
    const loop_program = try loop_parser.parseProgram();
    const loop_compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), loop_program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(loop_compiled.local_count >= 3);
    for (loop_compiled.chunk.code.items) |instruction|
        if (instruction.op == .bind_pattern) return error.TestUnexpectedResult;

    var with_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function declare(source, object){ with (object) { var [value] = source; } }",
    );
    const with_program = try with_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(arena.allocator(), with_program.program[0].func_decl)) {
        .compiled => |result| {
            try std.testing.expect(result.chunk.binding_reference_plans.items.len > 0);
            var saw_resolve = false;
            var saw_store = false;
            for (result.chunk.code.items) |instruction| switch (instruction.op) {
                .resolve_binding_ref => saw_resolve = true,
                .store_binding_ref => saw_store = true,
                .bind_pattern => return error.TestUnexpectedResult,
                else => {},
            };
            try std.testing.expect(saw_resolve and saw_store);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler reports stable program admission reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var invalid_parser = try @import("parser.zig").Parser.init(arena.allocator(), "1;");
    const invalid_program = try invalid_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), invalid_program.program[0])) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.ProgramRejection.invalid_root, reason),
    }

    // Member references at top level lower through #706 activation-local
    // scratch: every admitted program using them must declare scratch slots
    // and move temporaries through the dedicated opcodes.
    const scratch_sources = [_][]const u8{
        "var holder = { value: 1 }; holder.value += 1;",
        "var holder = {}; holder.value++;",
        "var holder = { key: 2 }; holder[holder.key] ??= 3;",
    };
    for (scratch_sources) |source| {
        var scratch_parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const scratch_program = try scratch_parser.parseProgram();
        const chunk = switch (try Compiler.admitProgram(arena.allocator(), scratch_program)) {
            .compiled => |compiled| compiled,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expect(chunk.scratch_count > 0);
        var stores: usize = 0;
        var loads: usize = 0;
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .scratch_store => stores += 1,
            .scratch_load => loads += 1,
            else => {},
        };
        try std.testing.expect(stores > 0 and loads > 0);
    }

    // Explicit disposal remains a tree-walk-only boundary.
    const unsupported_sources = [_][]const u8{
        "for (using x of []) break;",
    };
    for (unsupported_sources) |source| {
        var unsupported_parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const unsupported_program = try unsupported_parser.parseProgram();
        switch (try Compiler.admitProgram(arena.allocator(), unsupported_program)) {
            .compiled => return error.TestUnexpectedResult,
            .rejected => |reason| try std.testing.expectEqual(Compiler.ProgramRejection.unsupported_lowering, reason),
        }
    }

    var compiled_parser = try @import("parser.zig").Parser.init(arena.allocator(), "null ?? 1;");
    const compiled_program = try compiled_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), compiled_program)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler reports stable generator admission reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var invalid_parser = try @import("parser.zig").Parser.init(arena.allocator(), "function* invalid(){}");
    const invalid_program = try invalid_parser.parseProgram();
    const invalid = invalid_program.program[0].func_decl;
    invalid.is_expr_body = true;
    switch (try Compiler.admitGenerator(arena.allocator(), invalid, true)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.GeneratorRejection.expression_body, reason),
    }

    var unsupported_parser = try @import("parser.zig").Parser.init(arena.allocator(), "function* unsupported(){ for (using x of []) break; }");
    const unsupported_program = try unsupported_parser.parseProgram();
    switch (try Compiler.admitGenerator(arena.allocator(), unsupported_program.program[0].func_decl, true)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.GeneratorRejection.unsupported_lowering, reason),
    }

    var compiled_parser = try @import("parser.zig").Parser.init(arena.allocator(), "function* compiled(){ var holder = { value: 1 }; return holder[yield \"key\"]++; }");
    const compiled_program = try compiled_parser.parseProgram();
    switch (try Compiler.admitGenerator(arena.allocator(), compiled_program.program[0].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler reports stable async admission reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var generator_parser = try @import("parser.zig").Parser.init(arena.allocator(), "async function* invalid(){}");
    const generator_program = try generator_parser.parseProgram();
    switch (try Compiler.admitAsync(arena.allocator(), generator_program.program[0].func_decl, true)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.AsyncRejection.async_generator, reason),
    }

    var unsupported_parser = try @import("parser.zig").Parser.init(arena.allocator(), "async function unsupported(){ for (using x of []) break; }");
    const unsupported_program = try unsupported_parser.parseProgram();
    switch (try Compiler.admitAsync(arena.allocator(), unsupported_program.program[0].func_decl, true)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.AsyncRejection.unsupported_lowering, reason),
    }

    var compiled_parser = try @import("parser.zig").Parser.init(arena.allocator(), "async function compiled(){ var holder = { value: 1 }; return ++holder[await Promise.resolve(\"value\")]; }");
    const compiled_program = try compiled_parser.parseProgram();
    switch (try Compiler.admitAsync(arena.allocator(), compiled_program.program[0].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}
