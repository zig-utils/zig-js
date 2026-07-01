const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const regex = @import("regex");

const Token = lex.Token;
const TokenKind = lex.TokenKind;
const Node = ast.Node;

pub const ParseError = lex.LexError || error{ UnexpectedToken, ExpectedToken, InvalidAssignmentTarget };

/// Recursive-descent + precedence-climbing parser producing an arena-allocated
/// AST for the v1 subset (expressions, var/let/const, if/else, while, blocks).
pub const Parser = struct {
    tokens: []Token,
    pos: usize = 0,
    arena: std.mem.Allocator,
    /// The original source text, so function definitions can capture their exact
    /// source span for `Function.prototype.toString`.
    source: []const u8 = "",
    /// True while parsing a generator body, so `yield` is recognized as a yield
    /// expression rather than an identifier. Saved/restored around each function.
    in_generator: bool = false,
    /// True while parsing an async function body, so `await` is recognized as an
    /// await expression rather than an identifier. Saved/restored per function.
    in_async: bool = false,
    /// Inside a class body (so a private name `#x` is in scope) — gates the
    /// `#field in obj` brand check, which is a syntax error outside any class.
    in_class: bool = false,
    /// Set when parsing a direct eval whose caller is inside a class element: the
    /// eval'd code may reference the enclosing class's private names, so the
    /// "every used private name must be declared here" check is skipped (the host
    /// resolves them against the class's private map and the runtime brand-checks).
    eval_private_allowed: bool = false,
    /// True while parsing strict-mode code: the program (or an enclosing
    /// function) had a `"use strict"` directive prologue, a function body has
    /// its own such directive, or we're inside a class (always strict). Inherited
    /// by nested functions. Recorded on each `FunctionNode.is_strict`.
    strict: bool = false,
    /// Strictness of the most recently parsed function body, read by the caller
    /// to stamp `FunctionNode.is_strict` (since `parseFnBody` restores `strict`).
    last_fn_strict: bool = false,
    /// Syntactic-context depths for early errors: `return` requires a function,
    /// unlabeled `break` a loop/switch, unlabeled `continue` a loop. A function
    /// boundary resets the loop/switch depths (you can't break across it).
    fn_depth: u32 = 0,
    iter_depth: u32 = 0,
    switch_depth: u32 = 0,
    /// Depth of syntax contexts where `new.target` is allowed. Ordinary
    /// functions/methods introduce one; arrows only inherit an outer one.
    new_target_depth: u32 = 0,
    /// True when parsing a Module (via `parseModule`): top-level `import` and
    /// `export` declarations are recognized, and the body is implicitly strict.
    module: bool = false,
    /// When false (the default), `scanSuperAndArgs` also flags an `arguments`
    /// reference — used for class field initializers, where `arguments` is an
    /// early error. Set true to scan only for SuperCall (e.g. a method body,
    /// where `arguments` is legal).
    scan_allow_arguments: bool = false,
    /// When true, `scanSuperAndArgs` also flags a SuperProperty (`super.x`) —
    /// used to validate indirect-eval code, which is global and may contain no
    /// `super` at all (a direct eval from a field initializer leaves this false,
    /// since `super.prop` is permitted there).
    scan_forbid_super_property: bool = false,
    /// When true, `scanSuperAndArgs` descends into the eagerly evaluated pieces
    /// of nested class expressions (heritage, computed names, field initializers,
    /// and static blocks). Global/method scans leave this false so a class body
    /// remains its own syntactic context.
    scan_descend_class_expr: bool = false,
    /// When true, `scanSuperAndArgs` flags a YieldExpression — used to enforce
    /// the early error "FormalParameters of a generator must not contain a
    /// YieldExpression" (e.g. `function* g(a = yield) {}`).
    scan_forbid_yield: bool = false,
    /// When true, `scanSuperAndArgs` flags an AwaitExpression — used to enforce
    /// the early error "FormalParameters of an async function/arrow must not
    /// contain an AwaitExpression" (e.g. `async function f(a = await x) {}`).
    scan_forbid_await: bool = false,
    /// Array literals (parsed as a cover for array patterns) that ended with a
    /// trailing comma right after a rest element (`[...x,]`). Legal in a literal
    /// but not in the destructuring refinement, so `litToPattern` rejects them.
    /// Keyed by node pointer; only consulted during pattern conversion, so a
    /// stale entry for an array used as a plain literal is simply never checked.
    rest_trailing_comma_arrays: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    /// Object literals carrying a CoverInitializedName (`{ a = 1 }`), which is
    /// valid ONLY when the object is later refined to an assignment pattern.
    /// `litToPattern` removes an entry on conversion; any left when the
    /// Script/Module finishes parsing was used as a real object literal — an
    /// early SyntaxError (`({ a = 1 })`, `f({ a = 1 })`).
    pending_cover_inits: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    /// Object literals with two or more `__proto__: value` colon properties,
    /// which is an early error for a real object literal but legal when the object
    /// is refined to a pattern (where `__proto__` is just a property key).
    /// Same lifecycle as `pending_cover_inits`.
    pending_proto_dup: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    /// Expression nodes that were wrapped in parentheses, keyed by node address
    /// so the mark is true pointer identity rather than any structural hashing.
    /// A parenthesized
    /// array/object literal is not a valid destructuring assignment target
    /// (`({}) = 1`, `([a]) = b`), so `litToPattern` rejects one; a parenthesized
    /// identifier/member stays a valid target and is routed around litToPattern.
    paren_wrapped: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Identifier name for the just-parsed parenthesized target in `(... ) =`.
    /// This feeds NamedEvaluation, where `(f) = function(){}` must not name the
    /// anonymous function even though the parenthesized identifier remains a valid
    /// assignment target.
    paren_assign_target_name: ?[]const u8 = null,
    /// The `[~In]` grammar parameter: true while parsing a classic `for (init;…)`
    /// init expression, where a top-level `in` (binary or `#x in obj`) is
    /// forbidden so it can't be confused with a for-in head. Reset to `[+In]`
    /// inside any bracketing construct (parens, `[]`, `{}`, call args, computed
    /// member, conditional branches).
    no_in: bool = false,
    /// Set for the single statement that is the body of an `if`/loop/`with` or a
    /// `label:` item — a Statement position, where a LexicalDeclaration is not
    /// allowed. `let` there must be an ordinary identifier (so `if (x) let\ny=1`
    /// is `let;` + `y=1` via ASI), not the start of a `let`-declaration. Consumed
    /// (read and cleared) at the top of parseStatement so it applies only to that
    /// one statement and never leaks into a nested block's StatementList.
    suppress_let_decl: bool = false,
    /// True where a `using`/`await using` declaration statement is permitted: the
    /// StatementList of a Block (incl. function bodies, which parse via
    /// parseBlock) and the top level of a Module. It is NOT permitted at the top
    /// level of a Script or directly in a switch CaseClause/DefaultClause (a
    /// nested Block there re-enables it). The for-of head is a separate path.
    using_allowed: bool = false,
    /// Active labels in the current function body. A function boundary resets
    /// these because `break`/`continue` cannot target labels outside the
    /// function it appears in.
    active_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Labels immediately wrapping the next statement. If that statement is an
    /// iteration statement, those labels become valid labeled-continue targets.
    pending_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Labels of currently enclosing iteration statements.
    continue_labels: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(arena: std.mem.Allocator, source: []const u8) ParseError!Parser {
        var lx = lex.Lexer.init(arena, source);
        var list: std.ArrayListUnmanaged(Token) = .empty;
        while (true) {
            const t = try lx.next();
            try list.append(arena, t);
            if (t.kind == .eof) break;
        }
        return .{ .tokens = list.items, .arena = arena, .source = source };
    }

    /// Source slice from the start position of the token at `start_pos` through
    /// the end of the most recently consumed token (`self.pos - 1`). Used to
    /// capture a function's exact definition text for `Function.prototype.toString`.
    fn sourceFrom(self: *Parser, start_pos: usize) []const u8 {
        if (self.source.len == 0 or self.pos == 0) return "";
        const lo = self.tokens[start_pos].pos;
        const hi = self.tokens[self.pos - 1].end;
        if (lo > hi or hi > self.source.len) return "";
        return self.source[lo..hi];
    }

    fn cur(self: *Parser) Token {
        return self.tokens[self.pos];
    }
    fn containsLineTerminator(bytes: []const u8) bool {
        if (std.mem.indexOfScalar(u8, bytes, '\n') != null) return true;
        if (std.mem.indexOfScalar(u8, bytes, '\r') != null) return true;
        var i: usize = 0;
        while (i + 2 < bytes.len) : (i += 1) {
            if (bytes[i] == 0xe2 and bytes[i + 1] == 0x80 and
                (bytes[i + 2] == 0xa8 or bytes[i + 2] == 0xa9))
                return true;
        }
        return false;
    }

    fn hasLineTerminatorBefore(self: *Parser, ahead: usize) bool {
        const idx = self.pos + ahead;
        if (idx == 0 or idx >= self.tokens.len) return false;
        const gap = self.source[self.tokens[idx - 1].end..self.tokens[idx].pos];
        return containsLineTerminator(gap);
    }

    /// Whether no line terminator separates the token `ahead` positions away from
    /// the one just before it (the restricted-production check, e.g. `using` may
    /// not be followed by a newline before its binding identifier).
    fn noNewlineBefore(self: *Parser, ahead: usize) bool {
        return !self.hasLineTerminatorBefore(ahead);
    }

    fn consumeStatementTerminator(self: *Parser) ParseError!void {
        if (self.match(.semicolon)) return;
        if (self.check(.eof) or self.check(.rbrace)) return;
        if (self.hasLineTerminatorBefore(0)) return;
        return ParseError.UnexpectedToken;
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.cur().kind == kind;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        if (!self.match(kind)) return ParseError.ExpectedToken;
    }

    fn isKeyword(t: Token, word: []const u8) bool {
        return t.kind == .identifier and std.mem.eql(u8, t.text, word);
    }

    /// The current token is the contextual keyword `word` (an identifier token).
    /// A contextual keyword written with a Unicode escape (`from`) is never
    /// the keyword — it is an ordinary identifier — so an escaped form never
    /// matches (e.g. `import {} from "x"` is a SyntaxError).
    fn isContextual(self: *Parser, word: []const u8) bool {
        return !self.cur().escaped_identifier and isKeyword(self.cur(), word);
    }
    /// Alias of `isContextual` for readability at peek sites.
    fn checkContextual(self: *Parser, word: []const u8) bool {
        return self.isContextual(word);
    }
    /// Consume a contextual keyword `word` or fail.
    fn expectContextual(self: *Parser, word: []const u8) ParseError!void {
        if (!self.isContextual(word)) return ParseError.UnexpectedToken;
        _ = self.advance();
    }
    /// The token `ahead` positions from the cursor has kind `kind`.
    fn peekIs(self: *Parser, ahead: usize, kind: TokenKind) bool {
        const idx = self.pos + ahead;
        if (idx >= self.tokens.len) return false;
        return self.tokens[idx].kind == kind;
    }

    /// A label after `break`/`continue` on the same logical line.
    fn optionalLabel(self: *Parser) ?[]const u8 {
        if (self.hasLineTerminatorBefore(0)) return null;
        if (self.check(.identifier) and !self.isForbiddenLabelName(self.cur().text)) {
            return self.advance().text;
        }
        return null;
    }

    fn labelListContains(labels: []const []const u8, label: []const u8) bool {
        for (labels) |candidate| {
            if (std.mem.eql(u8, candidate, label)) return true;
        }
        return false;
    }

    fn statementCanInheritPendingLabels(self: *Parser) bool {
        const t = self.cur();
        if (t.kind != .identifier) return false;
        if (std.mem.eql(u8, t.text, "while") or
            std.mem.eql(u8, t.text, "do") or
            std.mem.eql(u8, t.text, "for"))
            return true;
        return self.peekKind(1) == .colon and !self.isForbiddenLabelName(t.text);
    }

    /// Keywords that can NEVER be a binding identifier, in any mode (the
    /// unconditional ReservedWords). Excludes the contextual ones — `let`,
    /// `yield`, `await`, `static`, `async`, `of`, `get`/`set`, `implements`,
    /// `undefined`, `eval`/`arguments`, … — which are legal binding names in at
    /// least some contexts, so this never false-rejects them.
    fn isAlwaysReservedBinding(text: []const u8) bool {
        const words = [_][]const u8{
            "break",    "case",    "catch",  "class",      "const", "continue",
            "debugger", "default", "delete", "do",         "else",  "enum",
            "export",   "extends", "false",  "finally",    "for",   "function",
            "if",       "import",  "in",     "instanceof", "new",   "null",
            "return",   "super",   "switch", "this",       "throw", "true",
            "try",      "typeof",  "var",    "void",       "while", "with",
        };
        for (words) |w| if (std.mem.eql(u8, text, w)) return true;
        return false;
    }

    fn isReservedWord(text: []const u8) bool {
        const words = [_][]const u8{
            "true",   "false",   "null",    "this",       "typeof",
            "void",   "new",     "in",      "instanceof", "function",
            "return", "var",     "let",     "const",      "if",
            "else",   "while",   "do",      "for",        "switch",
            "case",   "default", "break",   "continue",   "throw",
            "try",    "catch",   "finally", "delete",     "class",
            "enum",   "export",  "extends", "import",     "super",
            "yield",
        };
        for (words) |w| {
            if (std.mem.eql(u8, text, w)) return true;
        }
        return false;
    }

    fn isStrictReservedBinding(text: []const u8) bool {
        const words = [_][]const u8{
            "implements", "interface", "let",    "package", "private",
            "protected",  "public",    "static", "yield",
        };
        for (words) |w| if (std.mem.eql(u8, text, w)) return true;
        return false;
    }

    fn isForbiddenBindingName(self: *Parser, text: []const u8) bool {
        return isAlwaysReservedBinding(text) or
            ((self.module or self.in_async) and std.mem.eql(u8, text, "await")) or
            (self.in_generator and std.mem.eql(u8, text, "yield")) or
            (self.strict and (isStrictReservedBinding(text) or isEvalOrArguments(text)));
    }

    fn isForbiddenLabelName(self: *Parser, text: []const u8) bool {
        return isAlwaysReservedBinding(text) or
            ((self.module or self.in_async) and std.mem.eql(u8, text, "await")) or
            (self.in_generator and std.mem.eql(u8, text, "yield")) or
            (self.strict and isStrictReservedBinding(text));
    }

    fn isEscapedReservedWord(self: *Parser, t: Token) bool {
        return t.kind == .identifier and t.escaped_identifier and
            (isAlwaysReservedBinding(t.text) or (self.strict and isStrictReservedBinding(t.text)));
    }

    fn letDeclAhead(self: *Parser) bool {
        // A `let` written with a Unicode escape (`let`) is never the keyword,
        // so it cannot begin a LexicalDeclaration — it is an ordinary identifier.
        if (self.cur().escaped_identifier) return false;
        if (!isKeyword(self.cur(), "let")) return false;
        return switch (self.peekKind(1)) {
            .lbrace => self.noNewlineBefore(1),
            .lbracket => true,
            // `let` followed by a BindingIdentifier begins a LexicalDeclaration.
            // The contextual keywords `let`/`yield`/`await` are BindingIdentifiers
            // (then rejected as bound names where illegal), so `let let`/`let yield`
            // is a declaration — not `let` the identifier followed by an operator
            // keyword (`let in x`, `let instanceof X`), which stays an expression.
            .identifier => blk: {
                const t1 = self.tokens[self.pos + 1].text;
                break :blk !isReservedWord(t1) or std.mem.eql(u8, t1, "let") or
                    std.mem.eql(u8, t1, "yield") or std.mem.eql(u8, t1, "await");
            },
            else => false,
        };
    }

    fn alloc(self: *Parser, node: Node) ParseError!*Node {
        const p = try self.arena.create(Node);
        p.* = node;
        return p;
    }

    fn markParenWrapped(self: *Parser, node: *Node) ParseError!void {
        try self.paren_wrapped.put(self.arena, @intFromPtr(node), {});
    }

    fn isParenWrapped(self: *Parser, node: *Node) bool {
        return self.paren_wrapped.contains(@intFromPtr(node));
    }

    fn parenWrappedIdentifierBefore(self: *Parser, pos: usize, name: []const u8) bool {
        if (pos == 0 or self.tokens[pos - 1].kind != .rparen) return false;
        var i = pos;
        var depth: usize = 0;
        var saw_ident = false;
        var ident_matches = false;
        while (i > 0) {
            i -= 1;
            const t = self.tokens[i];
            switch (t.kind) {
                .rparen => depth += 1,
                .lparen => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) return saw_ident and ident_matches;
                },
                .identifier => {
                    if (depth != 1 or saw_ident) return false;
                    saw_ident = true;
                    ident_matches = std.mem.eql(u8, t.text, name);
                },
                else => if (depth == 1) return false,
            }
        }
        return false;
    }

    /// NamedEvaluation (applied at parse time): an *anonymous* function/class
    /// literal bound to a name takes that name (`var f = function(){}` ⇒
    /// `f.name === "f"`). Doing it on the AST means it holds whether the program
    /// runs on the VM or the tree-walker. A named function expression keeps its
    /// own name. (Runtime sites — destructuring/param defaults — name anon
    /// values too, for the dynamic cases this can't see.)
    fn nameAnon(node: *Node, name: []const u8) void {
        if (name.len == 0) return;
        switch (node.*) {
            .function => |f| {
                if (f.name.len == 0) f.name = name;
            },
            .class_expr => {
                if (node.class_expr.name.len == 0) node.class_expr.inferred_name = name;
            },
            else => {},
        }
    }

    // ----- program / statements -------------------------------------------

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        // A top-level `"use strict"` directive prologue makes the whole program
        // (and every function in it, by inheritance) strict.
        var i: usize = self.pos;
        while (i < self.tokens.len and self.tokens[i].kind == .string) {
            if (std.mem.eql(u8, self.tokens[i].text, "use strict")) {
                self.strict = true;
                break;
            }
            i += 1;
            if (i < self.tokens.len and self.tokens[i].kind == .semicolon) i += 1;
        }
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.eof)) {
            try stmts.append(self.arena, try self.parseStatement());
        }
        // Early error: no duplicate lexically-declared names in a scope.
        try self.checkLexicalDupes(stmts.items, false);
        if (!self.eval_private_allowed) try self.checkPrivateUsesInProgram(stmts.items);
        // A CoverInitializedName (`{ a = 1 }`) never refined to a pattern is an
        // early error.
        if (self.pending_cover_inits.count() > 0 or self.pending_proto_dup.count() > 0) return ParseError.UnexpectedToken;
        return self.alloc(.{ .program = stmts.items });
    }

    /// Early-error check (13.2.1.1 et al.): a scope's lexically-declared names
    /// (`let`/`const`/`class`, plus block-level `function`s) must be unique. This
    /// flags only *same-scope* duplicates — always a SyntaxError — so valid
    /// shadowing in nested scopes is never rejected. `funcs_lexical` is true for a
    /// block/switch scope (where a function declaration is lexical) and false for
    /// a function-body/script top level (where it is var-scoped). Incomplete
    /// traversal only misses errors; it never produces a false positive.
    fn checkLexicalDupes(self: *Parser, stmts: []const *Node, funcs_lexical: bool) ParseError!void {
        // name → is the declaration "rigid"? A let/const/class — or an async/
        // generator function — is rigid: any same-name collision is an error.
        // Two *plain* function declarations in a sloppy block are allowed
        // (Annex B.3.3), so a collision is reported only when a rigid one is
        // involved — which keeps the check free of false positives.
        var seen: std.StringHashMapUnmanaged(bool) = .empty;
        for (stmts) |s| {
            switch (s.*) {
                .var_decl => |d| if (d.kind != .@"var") try self.addDecl(&seen, d.name, true),
                .destructure_decl => |d| if (d.kind != .@"var") {
                    var names: std.ArrayListUnmanaged([]const u8) = .empty;
                    try self.addPatternNames(&names, d.pattern);
                    for (names.items) |n| try self.addDecl(&seen, n, true);
                },
                .decl_group => |g| for (g) |d2| {
                    if (d2.* == .var_decl and d2.var_decl.kind != .@"var") try self.addDecl(&seen, d2.var_decl.name, true);
                    if (d2.* == .destructure_decl and d2.destructure_decl.kind != .@"var") {
                        var names: std.ArrayListUnmanaged([]const u8) = .empty;
                        try self.addPatternNames(&names, d2.destructure_decl.pattern);
                        for (names.items) |n| try self.addDecl(&seen, n, true);
                    }
                },
                // A block-level function declaration is "rigid" (no duplicate
                // allowed) when it is a generator/async — or in strict mode, which
                // has no Annex B.3.3 plain-function duplicate allowance, so
                // `{ function f(){} function f(){} }` is a strict SyntaxError.
                .func_decl => |fnode| if (funcs_lexical and fnode.name.len > 0)
                    try self.addDecl(&seen, fnode.name, fnode.is_async or fnode.is_generator or self.strict),
                else => {},
            }
        }
        // Early error (Block 14.2.1, Script 16.1.1, FunctionBody 15.2.1): a scope's
        // LexicallyDeclaredNames must not intersect its VarDeclaredNames — e.g.
        // `{ var f; const f }` or `let x; { var x; }`. Var names hoist out of nested
        // blocks/control-flow (but not functions), so collect them across the
        // subtree. At a function/script scope, top-level function declarations are
        // themselves var-scoped, so they participate too.
        if (seen.count() > 0) {
            var var_names: std.StringHashMapUnmanaged(void) = .empty;
            for (stmts) |s| try self.collectVarNames(s, &var_names);
            if (!funcs_lexical) for (stmts) |s| {
                if (s.* == .func_decl and s.func_decl.name.len > 0)
                    try var_names.put(self.arena, s.func_decl.name, {});
            };
            var it = seen.iterator();
            while (it.next()) |entry| {
                if (var_names.contains(entry.key_ptr.*)) return ParseError.UnexpectedToken;
            }
        }
        for (stmts) |s| try self.recurseScope(s);
    }

    /// Early error (15.2.1 etc.): no element of a function's parameter BoundNames
    /// may also occur in the LexicallyDeclaredNames of its body —
    /// `function f(a){ let a; }`, `(a) => { const a = 1; }`, `({ m(a){ class a{} } })`
    /// are all SyntaxErrors. (A body `var a`/`function a(){}` is VarDeclared, not
    /// Lexical, so it may legally shadow a parameter, and a `let a` nested in an
    /// inner block has its own scope.) Applies to every function, method, and
    /// block-body arrow. The body of an expression-bodied arrow has no
    /// declarations, so nothing to check.
    fn checkParamBodyConflict(self: *Parser, params: []const ast.Param, body: *Node) ParseError!void {
        if (body.* != .block) return;
        var pnames: std.StringHashMapUnmanaged(void) = .empty;
        for (params) |p| {
            if (p.pattern) |pat| {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, pat);
                for (names.items) |n| if (n.len > 0) try pnames.put(self.arena, n, {});
            } else if (p.name.len > 0) try pnames.put(self.arena, p.name, {});
        }
        if (pnames.count() == 0) return;
        for (body.block) |s| switch (s.*) {
            .var_decl => |d| if (d.kind != .@"var" and pnames.contains(d.name)) return ParseError.UnexpectedToken,
            .destructure_decl => |d| if (d.kind != .@"var") {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |n| if (pnames.contains(n)) return ParseError.UnexpectedToken;
            },
            .decl_group => |g| for (g) |d2| {
                if (d2.* == .var_decl and d2.var_decl.kind != .@"var" and pnames.contains(d2.var_decl.name)) return ParseError.UnexpectedToken;
                if (d2.* == .destructure_decl and d2.destructure_decl.kind != .@"var") {
                    var names: std.ArrayListUnmanaged([]const u8) = .empty;
                    try self.addPatternNames(&names, d2.destructure_decl.pattern);
                    for (names.items) |n| if (pnames.contains(n)) return ParseError.UnexpectedToken;
                }
            },
            .class_expr => |c| if (c.name.len > 0 and pnames.contains(c.name)) return ParseError.UnexpectedToken,
            else => {},
        };
    }

    /// Collect VarDeclaredNames reachable from `node` without crossing a function
    /// boundary: `var` declarations (incl. destructuring and `for` heads) hoist out
    /// of nested blocks and control-flow statements, so recurse through those but
    /// not into nested functions/classes. Block-level function declarations are
    /// *not* collected (they are lexical to their block per the static semantics).
    fn collectVarNames(self: *Parser, node: *Node, out: *std.StringHashMapUnmanaged(void)) ParseError!void {
        switch (node.*) {
            .var_decl => |d| if (d.kind == .@"var" and d.name.len > 0) try out.put(self.arena, d.name, {}),
            .destructure_decl => |d| if (d.kind == .@"var") try self.putPatternVarNames(d.pattern, out),
            .decl_group => |g| for (g) |d2| try self.collectVarNames(d2, out),
            .block => |b| for (b) |s| try self.collectVarNames(s, out),
            .if_stmt => |i| {
                try self.collectVarNames(i.consequent, out);
                if (i.alternate) |a| try self.collectVarNames(a, out);
            },
            .while_stmt => |w| try self.collectVarNames(w.body, out),
            .do_while_stmt => |w| try self.collectVarNames(w.body, out),
            .for_stmt => |f| {
                if (f.init) |ini| try self.collectVarNames(ini, out);
                try self.collectVarNames(f.body, out);
            },
            .for_in => |f| {
                if (f.decl_kind) |k| if (k == .@"var") try self.putPatternVarNames(f.target, out);
                try self.collectVarNames(f.body, out);
            },
            .labeled_stmt => |l| try self.collectVarNames(l.body, out),
            .try_stmt => |t| {
                try self.collectVarNames(t.block, out);
                if (t.catch_block) |c| try self.collectVarNames(c, out);
                if (t.finally_block) |fb| try self.collectVarNames(fb, out);
            },
            .switch_stmt => |sw| for (sw.cases) |cs| for (cs.body) |s| try self.collectVarNames(s, out),
            // func_decl / function / class bodies are separate var scopes.
            else => {},
        }
    }

    fn putPatternVarNames(self: *Parser, pattern: *Node, out: *std.StringHashMapUnmanaged(void)) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, pattern);
        for (names.items) |n| if (n.len > 0) try out.put(self.arena, n, {});
    }

    /// A lexical binding target's BoundNames must be unique (`let [x, x]` etc.).
    /// The BoundNames of a *lexical* (`let`/`const`/`using`) for-in/of head must
    /// be unique and must not contain `let` — `for (let [x, x] of …)` and
    /// `for (const let of …)` are both early errors. Called only for lexical
    /// heads (plain `var` permits both).
    fn checkNoDuplicateBindings(self: *Parser, target: *Node) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, target);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (names.items) |n| {
            if (n.len == 0) continue;
            if (std.mem.eql(u8, n, "let")) return ParseError.UnexpectedToken;
            if (seen.contains(n)) return ParseError.UnexpectedToken;
            try seen.put(self.arena, n, {});
        }
    }

    /// A lexical for-in/of head's BoundNames must not also appear among the
    /// VarDeclaredNames of the loop body — `for (const x of []) { var x; }` is an
    /// early error (the body's `var` would redeclare the per-iteration lexical
    /// binding). Called only for lexical heads.
    fn checkForHeadVarConflict(self: *Parser, target: *Node, body: *Node) ParseError!void {
        var head: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&head, target);
        if (head.items.len == 0) return;
        var vars: std.StringHashMapUnmanaged(void) = .empty;
        try self.collectVarNames(body, &vars);
        for (head.items) |n| if (n.len > 0 and vars.contains(n)) return ParseError.UnexpectedToken;
    }

    /// Collect the BoundNames of a *lexical* (`let`/`const`/`using`) declaration
    /// node (single binding, destructuring, or `decl_group` of several). A `var`
    /// declaration contributes nothing (its names are VarDeclaredNames).
    fn collectLexicalDeclNames(self: *Parser, decl: *Node, out: *std.ArrayListUnmanaged([]const u8)) ParseError!void {
        switch (decl.*) {
            .var_decl => |d| if (d.kind != .@"var" and d.name.len > 0) try out.append(self.arena, d.name),
            .destructure_decl => |d| if (d.kind != .@"var") try self.addPatternNames(out, d.pattern),
            .decl_group => |g| for (g) |d2| try self.collectLexicalDeclNames(d2, out),
            else => {},
        }
    }

    /// A classic `for (lexical-decl; …) Statement`'s BoundNames must not also be
    /// VarDeclaredNames of the body: `for (let x; …) { var x; }` is an early error.
    fn checkForHeadDeclVarConflict(self: *Parser, decl: *Node, body: *Node) ParseError!void {
        var head: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.collectLexicalDeclNames(decl, &head);
        if (head.items.len == 0) return;
        var vars: std.StringHashMapUnmanaged(void) = .empty;
        try self.collectVarNames(body, &vars);
        for (head.items) |n| if (n.len > 0 and vars.contains(n)) return ParseError.UnexpectedToken;
    }

    fn addDecl(self: *Parser, seen: *std.StringHashMapUnmanaged(bool), name: []const u8, rigid: bool) ParseError!void {
        if (seen.get(name)) |existing_rigid| {
            // A collision is an early error unless BOTH are plain functions.
            if (rigid or existing_rigid) return ParseError.UnexpectedToken;
            return; // plain-function vs plain-function: allowed
        }
        try seen.put(self.arena, name, rigid);
    }

    /// Descend into a statement's nested scopes, running `checkLexicalDupes` at
    /// each new lexical scope.
    fn recurseScope(self: *Parser, node: *Node) ParseError!void {
        switch (node.*) {
            .block => |b| try self.checkLexicalDupes(b, true),
            .if_stmt => |i| {
                try self.recurseScope(i.consequent);
                if (i.alternate) |a| try self.recurseScope(a);
            },
            .while_stmt => |w| try self.recurseScope(w.body),
            .do_while_stmt => |w| try self.recurseScope(w.body),
            .for_stmt => |f| try self.recurseScope(f.body),
            .for_in => |f| try self.recurseScope(f.body),
            .labeled_stmt => |l| try self.recurseScope(l.body),
            .try_stmt => |t| {
                try self.recurseScope(t.block);
                if (t.catch_block) |c| try self.recurseScope(c);
                if (t.finally_block) |fb| try self.recurseScope(fb);
            },
            .switch_stmt => |sw| {
                // The whole switch is one lexical (block) scope spanning all cases.
                var combined: std.ArrayListUnmanaged(*Node) = .empty;
                for (sw.cases) |cs| try combined.appendSlice(self.arena, cs.body);
                try self.checkLexicalDupes(combined.items, true);
            },
            .func_decl => |fnode| try self.recurseFnBody(fnode),
            // A class/function used as an initializer carries its own body scopes.
            .var_decl => |d| if (d.init) |ini| try self.recurseScope(ini),
            .function => |fnode| try self.recurseFnBody(fnode),
            .class_expr => |c| for (c.members) |m| {
                if (m.func) |mf| if (mf.* == .function) try self.recurseFnBody(mf.function);
            },
            .expr_stmt => |e| try self.recurseScope(e),
            else => {},
        }
    }

    /// A function body is a fresh function scope: its top-level function
    /// declarations are var-scoped (not lexical), so `funcs_lexical = false`.
    fn recurseFnBody(self: *Parser, fnode: *ast.FunctionNode) ParseError!void {
        if (fnode.body.* == .block) try self.checkLexicalDupes(fnode.body.block, false);
    }

    fn addModuleLexicalName(
        self: *Parser,
        lexical: *std.StringHashMapUnmanaged(void),
        vars: *std.StringHashMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        if (name.len == 0) return;
        if (lexical.contains(name) or vars.contains(name)) return ParseError.UnexpectedToken;
        try lexical.put(self.arena, name, {});
    }

    fn addModuleVarName(
        self: *Parser,
        lexical: *std.StringHashMapUnmanaged(void),
        vars: *std.StringHashMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        if (name.len == 0) return;
        if (lexical.contains(name)) return ParseError.UnexpectedToken;
        try vars.put(self.arena, name, {});
    }

    fn addPatternNames(
        self: *Parser,
        out: *std.ArrayListUnmanaged([]const u8),
        pattern: *Node,
    ) ParseError!void {
        switch (pattern.*) {
            .identifier => |name| try out.append(self.arena, name),
            .obj_pattern => |p| {
                for (p.props) |prop| try self.addPatternNames(out, prop.target);
                if (p.rest) |r| if (r.* == .identifier) try out.append(self.arena, r.identifier);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |target|
                    try self.addPatternNames(out, target);
                if (p.rest) |rest| try self.addPatternNames(out, rest);
            },
            else => {},
        }
    }

    fn collectModuleDeclNames(
        self: *Parser,
        node: *Node,
        lexical: *std.StringHashMapUnmanaged(void),
        vars: *std.StringHashMapUnmanaged(void),
    ) ParseError!void {
        switch (node.*) {
            .import_decl => |i| for (i.entries) |entry|
                try self.addModuleLexicalName(lexical, vars, entry.local),
            .export_decl => |e| {
                if (e.declaration) |decl| try self.collectModuleDeclNames(decl, lexical, vars);
                if (e.default_name.len > 0) try self.addModuleLexicalName(lexical, vars, e.default_name);
            },
            .var_decl => |d| {
                if (d.kind == .@"var")
                    try self.addModuleVarName(lexical, vars, d.name)
                else
                    try self.addModuleLexicalName(lexical, vars, d.name);
            },
            .decl_group => |group| for (group) |decl|
                try self.collectModuleDeclNames(decl, lexical, vars),
            .destructure_decl => |d| {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |name| {
                    if (d.kind == .@"var")
                        try self.addModuleVarName(lexical, vars, name)
                    else
                        try self.addModuleLexicalName(lexical, vars, name);
                }
            },
            .func_decl => |f| try self.addModuleLexicalName(lexical, vars, f.name),
            else => {},
        }
    }

    fn addExportedName(
        self: *Parser,
        exported: *std.StringHashMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        if (name.len == 0) return;
        if (exported.contains(name)) return ParseError.UnexpectedToken;
        try exported.put(self.arena, name, {});
    }

    fn collectDeclExportedNames(
        self: *Parser,
        exported: *std.StringHashMapUnmanaged(void),
        decl: *Node,
    ) ParseError!void {
        switch (decl.*) {
            .var_decl => |d| try self.addExportedName(exported, d.name),
            .decl_group => |group| for (group) |item| try self.collectDeclExportedNames(exported, item),
            .destructure_decl => |d| {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |name| try self.addExportedName(exported, name);
            },
            .func_decl => |f| try self.addExportedName(exported, f.name),
            else => {},
        }
    }

    fn collectExportedNames(
        self: *Parser,
        exported: *std.StringHashMapUnmanaged(void),
        node: *Node,
    ) ParseError!void {
        if (node.* != .export_decl) return;
        const e = node.export_decl;
        if (e.default_expr != null) try self.addExportedName(exported, "default");
        if (e.star_as.len > 0) try self.addExportedName(exported, e.star_as);
        for (e.entries) |entry| try self.addExportedName(exported, entry.exported);
        if (e.declaration) |decl| try self.collectDeclExportedNames(exported, decl);
    }

    fn checkLocalExportedBindings(
        node: *Node,
        lexical: *const std.StringHashMapUnmanaged(void),
        vars: *const std.StringHashMapUnmanaged(void),
    ) ParseError!void {
        if (node.* != .export_decl) return;
        const e = node.export_decl;
        if (e.from.len != 0) return;
        for (e.entries) |entry| {
            if (!lexical.contains(entry.local) and !vars.contains(entry.local))
                return ParseError.UnexpectedToken;
        }
    }

    fn checkModuleEarlyErrors(self: *Parser, stmts: []const *Node) ParseError!void {
        var lexical: std.StringHashMapUnmanaged(void) = .empty;
        var vars: std.StringHashMapUnmanaged(void) = .empty;
        var exported: std.StringHashMapUnmanaged(void) = .empty;
        for (stmts) |stmt| {
            try self.collectModuleDeclNames(stmt, &lexical, &vars);
            try self.collectExportedNames(&exported, stmt);
        }
        for (stmts) |stmt| try checkLocalExportedBindings(stmt, &lexical, &vars);
        for (stmts) |stmt| try self.recurseScope(stmt);
        try self.checkPrivateUsesInProgram(stmts);
    }

    fn wtf8SurrogateAt(s: []const u8, i: usize) ?u16 {
        if (i + 2 >= s.len) return null;
        if (s[i] != 0xed) return null;
        if (s[i + 1] < 0xa0 or s[i + 1] > 0xbf) return null;
        if ((s[i + 2] & 0xc0) != 0x80) return null;
        const cp = (@as(u16, s[i] & 0x0f) << 12) |
            (@as(u16, s[i + 1] & 0x3f) << 6) |
            @as(u16, s[i + 2] & 0x3f);
        if (cp < 0xd800 or cp > 0xdfff) return null;
        return cp;
    }

    fn isHighSurrogate(unit: u16) bool {
        return unit >= 0xd800 and unit <= 0xdbff;
    }

    fn isLowSurrogate(unit: u16) bool {
        return unit >= 0xdc00 and unit <= 0xdfff;
    }

    fn utf8SeqLen(bytes: []const u8, i: usize) usize {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return 1;
        if (i + n > bytes.len) return 1;
        return if (std.unicode.utf8ValidateSlice(bytes[i .. i + n])) n else 1;
    }

    fn isWellFormedStringValue(s: []const u8) bool {
        var i: usize = 0;
        while (i < s.len) {
            if (wtf8SurrogateAt(s, i)) |first| {
                if (isHighSurrogate(first)) {
                    if (wtf8SurrogateAt(s, i + 3)) |second| if (isLowSurrogate(second)) {
                        i += 6;
                        continue;
                    };
                }
                return false;
            }
            i += utf8SeqLen(s, i);
        }
        return true;
    }

    /// Parse the token stream as a Module: a Module is always strict, and its
    /// top level additionally permits `import`/`export` declarations.
    pub fn parseModule(self: *Parser) ParseError!*Node {
        self.module = true;
        self.strict = true;
        // HTML-like comments (Annex B B.1.3) are Script-only; a Module must reject
        // `<!--` / `-->`. `init` tokenized with them enabled (the Script default),
        // so re-tokenize the source with them disabled before parsing the module.
        try self.retokenizeWithoutHtmlComments();
        // A Module is an async context for `await` at the top level (top-level
        // await). Nested non-async functions reset this via `parseFnBody`.
        self.in_async = true;
        // Module top level permits `using`/`await using` (unlike a Script's).
        self.using_allowed = true;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.eof)) {
            try stmts.append(self.arena, try self.parseModuleItem());
        }
        try self.checkModuleEarlyErrors(stmts.items);
        if (self.pending_cover_inits.count() > 0 or self.pending_proto_dup.count() > 0) return ParseError.UnexpectedToken;
        return self.alloc(.{ .program = stmts.items });
    }

    /// Re-tokenize `self.source` with HTML-like comments disabled (Module goal)
    /// and reset the cursor. Safe to call before any token has been consumed.
    fn retokenizeWithoutHtmlComments(self: *Parser) ParseError!void {
        var lx = lex.Lexer.initOptions(self.arena, self.source, false);
        var list: std.ArrayListUnmanaged(Token) = .empty;
        while (true) {
            const t = try lx.next();
            try list.append(self.arena, t);
            if (t.kind == .eof) break;
        }
        self.tokens = list.items;
        self.pos = 0;
    }

    /// A ModuleItem: an `import`/`export` declaration or an ordinary statement.
    fn parseModuleItem(self: *Parser) ParseError!*Node {
        const t = self.cur();
        if (t.kind == .identifier) {
            // `import` declaration — but `import(` (dynamic) and `import.meta`
            // are expressions, so only treat it as a declaration otherwise.
            if (std.mem.eql(u8, t.text, "import") and !self.peekIs(1, .lparen) and !self.peekIs(1, .dot))
                return self.parseImportDecl();
            if (std.mem.eql(u8, t.text, "export")) return self.parseExportDecl();
        }
        return self.parseStatement();
    }

    /// `import "spec";` | `import default, * as ns, { a as b } from "spec";`
    fn parseImportDecl(self: *Parser) ParseError!*Node {
        _ = self.advance(); // `import`
        var entries: std.ArrayListUnmanaged(ast.ImportEntry) = .empty;
        // Bare side-effect import: `import "spec";`
        if (self.check(.string)) {
            const spec = self.advance().text;
            const at = try self.parseImportAttributesOpt();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = &.{}, .attr_type = at } });
        }
        // Source-phase import: `import source x from "mod"`. The contextual
        // keyword is only recognized when a binding and following `from` are
        // present, so `import source from "mod"` remains a default import.
        if (self.checkContextual("source") and self.peekKind(1) == .identifier and self.peekIsKeyword(2, "from")) {
            _ = self.advance(); // source
            const name = self.advance().text;
            if (self.isForbiddenBindingName(name)) return ParseError.UnexpectedToken;
            try entries.append(self.arena, .{ .imported = "source", .local = name });
            try self.expectContextual("from");
            const spec = if (self.check(.string)) self.advance().text else return ParseError.UnexpectedToken;
            const at = try self.parseImportAttributesOpt();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = entries.items, .attr_type = at } });
        }
        // Deferred namespace import: `import defer * as ns from "m"`. `defer` is
        // a contextual keyword recognized only when followed by `*` (otherwise it
        // is an ordinary default-import binding name, e.g. `import defer from …`).
        const deferred = self.checkContextual("defer") and self.peekKind(1) == .star;
        if (deferred) _ = self.advance(); // consume `defer`
        // Default binding: `import name ...`
        if (self.check(.identifier) and !std.mem.eql(u8, self.cur().text, "from")) {
            const name = self.advance().text;
            if (self.isForbiddenBindingName(name)) return ParseError.UnexpectedToken;
            try entries.append(self.arena, .{ .imported = "default", .local = name });
            _ = self.match(.comma);
        }
        // `* as ns` namespace, or `{ ... }` named bindings.
        if (self.check(.star)) {
            _ = self.advance();
            try self.expectContextual("as");
            const ns = self.advance().text;
            if (self.isForbiddenBindingName(ns)) return ParseError.UnexpectedToken;
            try entries.append(self.arena, .{ .imported = "*", .local = ns });
        } else if (self.check(.lbrace)) {
            try self.parseNamedImports(&entries);
        }
        try self.expectContextual("from");
        const spec = if (self.check(.string)) self.advance().text else return ParseError.UnexpectedToken;
        const at = try self.parseImportAttributesOpt();
        try self.consumeStatementTerminator();
        return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = entries.items, .attr_type = at, .deferred = deferred } });
    }

    /// Static import attributes: `with { key: "value", ... }`. Validates the
    /// clause shape and duplicate keys, and returns the value of the `type`
    /// attribute (`""` when absent) — which selects the imported module's type
    /// (e.g. `"json"`).
    fn parseImportAttributesOpt(self: *Parser) ParseError![]const u8 {
        if (!self.checkContextual("with")) return "";
        _ = self.advance();
        try self.expect(.lbrace);
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        var type_value: []const u8 = "";
        while (!self.check(.rbrace)) {
            const key = try self.moduleExportName();
            if (keys.contains(key)) return ParseError.UnexpectedToken;
            try keys.put(self.arena, key, {});
            try self.expect(.colon);
            if (!self.check(.string)) return ParseError.UnexpectedToken;
            const val = self.advance().text;
            if (std.mem.eql(u8, key, "type")) type_value = val;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        return type_value;
    }

    /// `{ a, b as c, "str" as d }` import bindings.
    fn parseNamedImports(self: *Parser, entries: *std.ArrayListUnmanaged(ast.ImportEntry)) ParseError!void {
        try self.expect(.lbrace);
        while (!self.check(.rbrace)) {
            const imported_is_string = self.cur().kind == .string;
            const imported = try self.moduleExportName();
            var local = imported;
            if (self.checkContextual("as")) {
                _ = self.advance();
                if (!self.check(.identifier)) return ParseError.UnexpectedToken;
                local = self.advance().text;
            } else if (imported_is_string) {
                return ParseError.UnexpectedToken;
            }
            if (self.isForbiddenBindingName(local)) return ParseError.UnexpectedToken;
            try entries.append(self.arena, .{ .imported = imported, .local = local });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
    }

    /// `export` in all its forms.
    fn parseExportDecl(self: *Parser) ParseError!*Node {
        _ = self.advance(); // `export`
        const node = try self.arena.create(ast.ExportNode);
        node.* = .{};

        if (self.check(.star)) {
            // `export * from "m"` / `export * as ns from "m"`
            _ = self.advance();
            node.star = true;
            if (self.checkContextual("as")) {
                _ = self.advance();
                node.star_as = try self.moduleExportName();
            }
            try self.expectContextual("from");
            node.from = self.advance().text;
            _ = try self.parseImportAttributesOpt(); // export-from attributes: validated, not yet typed
            try self.consumeStatementTerminator();
            return self.alloc(.{ .export_decl = node });
        }
        if (self.check(.lbrace)) {
            // `export { a, b as c }` [from "m"]
            var entries: std.ArrayListUnmanaged(ast.ExportEntry) = .empty;
            var referenced_module_export_name = false;
            _ = self.advance(); // `{`
            while (!self.check(.rbrace)) {
                if (self.cur().kind == .string) referenced_module_export_name = true;
                const first = try self.moduleExportName();
                var exported = first;
                if (self.checkContextual("as")) {
                    _ = self.advance();
                    exported = try self.moduleExportName();
                }
                try entries.append(self.arena, .{ .local = first, .exported = exported });
                if (!self.match(.comma)) break;
            }
            try self.expect(.rbrace);
            if (self.checkContextual("from")) {
                _ = self.advance();
                node.from = self.advance().text;
                _ = try self.parseImportAttributesOpt(); // re-export attributes: validated, not yet typed
                // Re-export: the names are imported from the source module, not local.
                for (entries.items) |*e| {
                    e.imported = e.local;
                    e.local = "";
                }
            } else if (referenced_module_export_name) {
                return ParseError.UnexpectedToken;
            }
            node.entries = entries.items;
            try self.consumeStatementTerminator();
            return self.alloc(.{ .export_decl = node });
        }
        if (self.isContextual("default")) {
            _ = self.advance(); // `default`
            // `export default function/class …` binds a (possibly anonymous) name.
            if (self.isContextual("function") or (self.isContextual("async") and !self.cur().escaped_identifier and self.peekIsKeyword(1, "function"))) {
                // `export default function …` may be anonymous, so parse it as a
                // function *expression* (which permits no name).
                const is_async = self.isContextual("async");
                const decl = try self.parseFunctionExpr(is_async);
                decl.function.is_default_export_decl = true;
                node.default_expr = decl;
                node.default_name = decl.function.name;
                return self.alloc(.{ .export_decl = node });
            }
            if (self.isContextual("class")) {
                const cls = try self.parseClassExpr();
                node.default_expr = cls;
                node.default_name = cls.class_expr.name;
                return self.alloc(.{ .export_decl = node });
            }
            // `export default AssignmentExpression;`
            node.default_expr = try self.parseAssignment();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .export_decl = node });
        }
        // `export <declaration>` — var/let/const/function/class. The declaration
        // also binds locally; its bound names become exports.
        const decl = try self.parseStatement();
        node.declaration = decl;
        return self.alloc(.{ .export_decl = node });
    }

    /// A ModuleExportName: an identifier or a string literal (ES2022).
    fn moduleExportName(self: *Parser) ParseError![]const u8 {
        const t = self.cur();
        if (t.kind != .identifier and t.kind != .string) return ParseError.UnexpectedToken;
        if (t.kind == .string and !isWellFormedStringValue(t.text)) return ParseError.UnexpectedToken;
        return self.advance().text;
    }

    fn parseStatement(self: *Parser) ParseError!*Node {
        // Consume the Statement-only marker: it applies to exactly this statement
        // (suppressing `let`-declaration recognition), never to a nested block.
        const suppress_let = self.suppress_let_decl;
        self.suppress_let_decl = false;
        // Empty statement: a bare `;` (also the trailing `;` after a class /
        // function declaration). Evaluates to a no-op (empty block).
        if (self.check(.semicolon)) {
            _ = self.advance();
            return self.alloc(.{ .block = &[_]*Node{} });
        }
        // A decorated class declaration: `@dec class C {…}`.
        if (self.check(.at)) {
            try self.parseDecorators();
            const cls = try self.parseClassExpr();
            if (cls.class_expr.name.len > 0)
                return self.alloc(.{ .var_decl = .{ .kind = .let, .name = cls.class_expr.name, .init = cls } });
            _ = self.match(.semicolon);
            return self.alloc(.{ .expr_stmt = cls });
        }
        const t = self.cur();
        if (t.kind == .identifier) {
            if (self.isEscapedReservedWord(t)) return ParseError.UnexpectedToken;
            if (std.mem.eql(u8, t.text, "var")) return self.parseVarDecl(.@"var");
            if (std.mem.eql(u8, t.text, "let") and !t.escaped_identifier) {
                if (suppress_let) {
                    // Statement position (body of if/loop/with, label item): a
                    // LexicalDeclaration is not allowed, so `let` is an ordinary
                    // identifier — EXCEPT `let [`, the restricted ExpressionStatement
                    // production, which is a SyntaxError even with an intervening
                    // LineTerminator (the restriction has no [no LineTerminator]).
                    if (self.peekKind(1) == .lbracket) return ParseError.UnexpectedToken;
                } else if (self.letDeclAhead()) return self.parseVarDecl(.let);
            }
            if (std.mem.eql(u8, t.text, "const")) return self.parseVarDecl(.@"const");
            // `using x = e, …;` (explicit resource management): a block-scoped,
            // initializer-required declaration — parsed like `const` (disposal at
            // scope exit is not yet implemented). `using` not followed (on the
            // same line) by a binding identifier is an ordinary expression.
            if (std.mem.eql(u8, t.text, "using") and self.peekKind(1) == .identifier and
                self.noNewlineBefore(1) and !isReservedWord(self.tokens[self.pos + 1].text))
            {
                // A `using` declaration is only valid in a Block/function body or
                // at Module top level — not at Script top level or in a switch
                // CaseClause/DefaultClause.
                if (!self.using_allowed) return ParseError.UnexpectedToken;
                return self.parseVarDeclDispose(.@"const", 1);
            }
            if (std.mem.eql(u8, t.text, "await") and self.peekIsKeyword(1, "using") and
                self.peekKind(2) == .identifier and self.noNewlineBefore(2))
            {
                if (!self.using_allowed) return ParseError.UnexpectedToken;
                _ = self.advance(); // await
                return self.parseVarDeclDispose(.@"const", 2);
            }
            if (std.mem.eql(u8, t.text, "if")) return self.parseIf();
            if (std.mem.eql(u8, t.text, "while")) return self.parseWhile();
            if (std.mem.eql(u8, t.text, "do")) return self.parseDoWhile();
            if (std.mem.eql(u8, t.text, "for")) return self.parseFor();
            if (std.mem.eql(u8, t.text, "switch")) return self.parseSwitch();
            if (std.mem.eql(u8, t.text, "with")) {
                if (self.strict) return ParseError.UnexpectedToken; // `with` is forbidden in strict mode
                _ = self.advance();
                try self.expect(.lparen);
                const obj = try self.parseExpression();
                try self.expect(.rparen);
                const body = try self.parseSubStatement(.loop_with);
                return self.alloc(.{ .with_stmt = .{ .obj = obj, .body = body } });
            }
            if (std.mem.eql(u8, t.text, "function")) return self.parseFunctionDecl(false);
            // `async function …` declaration (contextual keyword: `async`
            // immediately followed by `function`). `async [no LineTerminator here]
            // function` — a newline after `async` ends the statement, so `async`
            // becomes an ordinary identifier expression and `function …` is a
            // separate declaration. `async` followed by anything else is also an
            // ordinary expression statement (async arrow / identifier).
            if (std.mem.eql(u8, t.text, "async") and !t.escaped_identifier and self.peekIsKeyword(1, "function") and self.noNewlineBefore(1)) return self.parseFunctionDecl(true);
            if (std.mem.eql(u8, t.text, "return")) return self.parseReturn();
            if (std.mem.eql(u8, t.text, "throw")) return self.parseThrow();
            if (std.mem.eql(u8, t.text, "try")) return self.parseTry();
            if (std.mem.eql(u8, t.text, "debugger")) {
                _ = self.advance();
                try self.consumeStatementTerminator();
                return self.alloc(.{ .block = &[_]*Node{} });
            }
            if (std.mem.eql(u8, t.text, "class")) {
                // `class C {...}` declaration binds C; anonymous class is an expr.
                const cls = try self.parseClassExpr();
                if (cls.class_expr.name.len > 0) {
                    return self.alloc(.{ .var_decl = .{ .kind = .let, .name = cls.class_expr.name, .init = cls } });
                }
                _ = self.match(.semicolon);
                return self.alloc(.{ .expr_stmt = cls });
            }
            if (std.mem.eql(u8, t.text, "break")) {
                _ = self.advance();
                const label = self.optionalLabel();
                _ = self.match(.semicolon);
                // Unlabeled `break` requires an enclosing loop or switch.
                if (label == null and self.iter_depth == 0 and self.switch_depth == 0) return ParseError.UnexpectedToken;
                if (label) |name| {
                    if (!labelListContains(self.active_labels.items, name)) return ParseError.UnexpectedToken;
                }
                return self.alloc(.{ .break_stmt = label });
            }
            if (std.mem.eql(u8, t.text, "continue")) {
                _ = self.advance();
                const label = self.optionalLabel();
                _ = self.match(.semicolon);
                // `continue` requires an enclosing loop (labeled or not).
                if (self.iter_depth == 0) return ParseError.UnexpectedToken;
                if (label) |name| {
                    if (!labelListContains(self.continue_labels.items, name)) return ParseError.UnexpectedToken;
                }
                return self.alloc(.{ .continue_stmt = label });
            }
            // Labeled statement: `label: stmt` (identifier directly followed by `:`).
            if (self.peekKind(1) == .colon and !self.isForbiddenLabelName(t.text)) {
                _ = self.advance(); // label
                _ = self.advance(); // ':'
                if (labelListContains(self.active_labels.items, t.text)) return ParseError.UnexpectedToken;
                try self.active_labels.append(self.arena, t.text);
                defer self.active_labels.items.len -= 1;
                const saved_pending = self.pending_labels.items.len;
                try self.pending_labels.append(self.arena, t.text);
                if (!self.statementCanInheritPendingLabels()) {
                    self.pending_labels.items.len = saved_pending;
                }
                defer self.pending_labels.items.len = saved_pending;
                const body = try self.parseSubStatement(.label_item);
                return self.alloc(.{ .labeled_stmt = .{ .label = t.text, .body = body } });
            }
        }
        if (t.kind == .lbrace) return self.parseBlock();

        const expr = try self.parseExpression();
        try self.consumeStatementTerminator();
        return self.alloc(.{ .expr_stmt = expr });
    }

    /// The position a single-statement body occupies, which governs whether a
    /// plain `function` declaration is allowed there (Annex B.3.2/B.3.4).
    const SubStmtCtx = enum {
        /// The consequent/alternate of an `if`. Annex B.3.4 permits a *direct*
        /// (unlabeled) sloppy `function` declaration here, but not a labeled one.
        if_clause,
        /// The body of a loop or `with`. No `function` declaration is allowed.
        loop_with,
        /// The item of a `label:`. Annex B.3.2 permits a sloppy `function`
        /// declaration (and nested labels ending in one).
        label_item,
    };

    /// A labeled statement, after peeling any number of labels, whose innermost
    /// item is a plain `function` declaration — the LabelledItem-is-a-function
    /// case from Annex B.3.2.
    fn labeledEndsInFunc(node: *Node) bool {
        var n = node;
        while (n.* == .labeled_stmt) n = n.labeled_stmt.body;
        return n.* == .func_decl;
    }

    /// Parse the single-statement body of an `if`/`else`, loop, `with`, or
    /// labeled statement. The grammar allows a Statement there, NOT a
    /// Declaration: a lexical declaration (`let`/`const`/`using`) or a class
    /// declaration in that position is an early SyntaxError in every mode.
    ///
    /// A plain `function` declaration is special. In strict mode it is always a
    /// SyntaxError. In sloppy mode Annex B permits it as the *direct* body of an
    /// `if`/`else` clause (B.3.4) or as a `label:` item (B.3.2) — but never as a
    /// loop/`with` body, and a *labeled* function is never permitted as an
    /// `if`/loop/`with` body. Generator/async function declarations are never
    /// allowed in any single-statement position. (Plain `var` is allowed.) The
    /// check inspects what `parseStatement` actually produced, so `let`/`using`
    /// used as an identifier — which `parseStatement` parses as an expression —
    /// is never mistaken for a declaration.
    fn parseSubStatement(self: *Parser, ctx: SubStmtCtx) ParseError!*Node {
        // A Statement position: `let` here is an identifier, not a declaration.
        self.suppress_let_decl = true;
        const stmt = try self.parseStatement();
        switch (stmt.*) {
            .var_decl => |d| if (d.kind != .@"var") return ParseError.UnexpectedToken,
            .destructure_decl => |d| if (d.kind != .@"var") return ParseError.UnexpectedToken,
            .func_decl => |f| {
                if (f.is_generator or f.is_async) return ParseError.UnexpectedToken;
                if (self.strict) return ParseError.UnexpectedToken;
                if (ctx == .loop_with) return ParseError.UnexpectedToken;
            },
            // A labeled function is only legal as a `label:` item (B.3.2), not as
            // the body of an `if`/loop/`with` (`if (x) lbl: function f(){}`).
            .labeled_stmt => if (ctx != .label_item and labeledEndsInFunc(stmt)) return ParseError.UnexpectedToken,
            else => {},
        }
        return stmt;
    }

    /// Convert an array/object *literal* on the LHS of `=` into a destructuring
    /// pattern (the cover-grammar reinterpretation).
    fn litToPattern(self: *Parser, node: *Node) ParseError!*Node {
        // A parenthesized array/object literal can't be a destructuring target.
        if (self.isParenWrapped(node)) return ParseError.InvalidAssignmentTarget;
        switch (node.*) {
            .array_lit => |elems| {
                // `[...x,]` — a trailing comma after the rest element is invalid in
                // an array assignment pattern.
                if (self.rest_trailing_comma_arrays.contains(node)) return ParseError.InvalidAssignmentTarget;
                var out: std.ArrayListUnmanaged(ast.ArrPatElem) = .empty;
                var rest: ?*Node = null;
                for (elems) |e| {
                    // A rest element (`...x`) must be last: nothing — not another
                    // element, elision, or rest — may follow it.
                    if (rest != null) return ParseError.InvalidAssignmentTarget;
                    if (e.* == .elision) {
                        try out.append(self.arena, .{}); // elision / hole in `[ , a ] = …`
                    } else if (e.* == .spread) {
                        rest = try self.exprToTarget(e.spread);
                    } else if (e.* == .assign) {
                        try out.append(self.arena, .{ .target = try self.exprToTarget(e.assign.target), .default = e.assign.value });
                    } else {
                        try out.append(self.arena, .{ .target = try self.exprToTarget(e) });
                    }
                }
                return self.alloc(.{ .arr_pattern = .{ .elems = out.items, .rest = rest } });
            },
            .object_lit => |props| {
                // This object is being refined to a pattern, so a
                // CoverInitializedName it carries is legal (it becomes a default),
                // and duplicate `__proto__` keys are legal (just property names).
                _ = self.pending_cover_inits.remove(node);
                _ = self.pending_proto_dup.remove(node);
                var out: std.ArrayListUnmanaged(ast.ObjPatProp) = .empty;
                var rest_target: ?*ast.Node = null;
                var seen_spread = false;
                for (props) |p| {
                    // An object rest property (`...rest`) must be the last member.
                    if (seen_spread) return ParseError.InvalidAssignmentTarget;
                    if (p.is_spread) {
                        seen_spread = true;
                        // An object rest target must be a simple assignment target
                        // (an identifier or member) — `({...import.meta} = x)`,
                        // `({...(a+b)} = x)`, `({...[a]} = x)` are SyntaxErrors.
                        if (p.value.* != .identifier and p.value.* != .member and p.value.* != .super_member) return ParseError.InvalidAssignmentTarget;
                        if (p.value.* == .identifier and self.isForbiddenBindingName(p.value.identifier)) return ParseError.UnexpectedToken;
                        rest_target = try self.exprToTarget(p.value);
                    } else if (p.value.* == .assign) {
                        try out.append(self.arena, .{ .key = p.key, .key_expr = p.key_expr, .target = try self.exprToTarget(p.value.assign.target), .default = p.value.assign.value });
                    } else {
                        try out.append(self.arena, .{ .key = p.key, .key_expr = p.key_expr, .target = try self.exprToTarget(p.value) });
                    }
                }
                return self.alloc(.{ .obj_pattern = .{ .props = out.items, .rest = rest_target } });
            },
            else => return ParseError.InvalidAssignmentTarget,
        }
    }

    fn exprToTarget(self: *Parser, node: *Node) ParseError!*Node {
        return switch (node.*) {
            .identifier => {
                if (self.isForbiddenBindingName(node.identifier)) return ParseError.UnexpectedToken;
                return node;
            },
            .member, .super_member => node,
            .array_lit, .object_lit => try self.litToPattern(node),
            // Already a destructuring pattern — e.g. a nested assignment element
            // `[ {} = yield ]` whose inner `{} = …` was converted on the way up.
            .obj_pattern, .arr_pattern => node,
            else => ParseError.InvalidAssignmentTarget,
        };
    }

    // ----- destructuring binding patterns ---------------------------------

    /// A binding target: an identifier or a nested object/array pattern.
    fn parseBindingTarget(self: *Parser) ParseError!*Node {
        if (self.check(.lbrace)) return self.parseObjectPattern();
        if (self.check(.lbracket)) return self.parseArrayPattern();
        const name = self.advance();
        if (name.kind != .identifier) return ParseError.UnexpectedToken;
        if (self.isForbiddenBindingName(name.text)) return ParseError.UnexpectedToken;
        return self.alloc(.{ .identifier = name.text });
    }

    fn parseObjectPattern(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        var props: std.ArrayListUnmanaged(ast.ObjPatProp) = .empty;
        var rest: ?*Node = null;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.ellipsis)) {
                const r = self.advance();
                // A BindingRestProperty target is a plain BindingIdentifier.
                if (r.kind != .identifier) return ParseError.UnexpectedToken;
                rest = try self.alloc(.{ .identifier = r.text });
                break;
            }
            var key: []const u8 = "";
            var key_expr: ?*Node = null;
            if (self.match(.lbracket)) {
                key_expr = try self.parseAssignment();
                try self.expect(.rbracket);
            } else {
                const kt = self.advance();
                key = switch (kt.kind) {
                    .identifier, .string => kt.text,
                    .number => try std.fmt.allocPrint(self.arena, "{d}", .{kt.number}),
                    else => return ParseError.UnexpectedToken,
                };
            }
            // `{ key }` shorthand, or `{ key: target }`. A shorthand binds the
            // key as a BindingIdentifier, so it must not be a reserved word
            // (`{ break }`, `{ this }`, …) — including one spelled with a Unicode
            // escape, since `key` holds the decoded text.
            const target = if (self.match(.colon))
                try self.parseBindingTarget()
            else blk: {
                if (self.isForbiddenBindingName(key)) return ParseError.UnexpectedToken;
                break :blk try self.alloc(.{ .identifier = key });
            };
            const default = if (self.match(.assign)) try self.parseAssignment() else null;
            try props.append(self.arena, .{ .key = key, .key_expr = key_expr, .target = target, .default = default });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .obj_pattern = .{ .props = props.items, .rest = rest } });
    }

    fn parseArrayPattern(self: *Parser) ParseError!*Node {
        try self.expect(.lbracket);
        var elems: std.ArrayListUnmanaged(ast.ArrPatElem) = .empty;
        var rest: ?*Node = null;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            if (self.check(.comma)) { // elision / hole
                try elems.append(self.arena, .{});
                _ = self.advance();
                continue;
            }
            if (self.match(.ellipsis)) {
                rest = try self.parseBindingTarget();
                break;
            }
            const target = try self.parseBindingTarget();
            const default = if (self.match(.assign)) try self.parseAssignment() else null;
            try elems.append(self.arena, .{ .target = target, .default = default });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbracket);
        return self.alloc(.{ .arr_pattern = .{ .elems = elems.items, .rest = rest } });
    }

    fn parseVarDecl(self: *Parser, kind: ast.DeclKind) ParseError!*Node {
        return self.parseVarDeclDispose(kind, 0);
    }

    /// `dispose`: 0 = ordinary `var`/`let`/`const`, 1 = `using`, 2 = `await using`.
    fn parseVarDeclDispose(self: *Parser, kind: ast.DeclKind, dispose: u8) ParseError!*Node {
        _ = self.advance(); // var/let/const/using
        // Destructuring declaration: `let {a, b} = obj` / `let [x, y] = arr`.
        // A `using` binding must be a plain identifier (no pattern).
        if (self.check(.lbrace) or self.check(.lbracket)) {
            if (dispose != 0) return ParseError.UnexpectedToken;
            const pattern = try self.parseBindingTarget();
            try self.expect(.assign);
            const init_expr = try self.parseAssignment();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .destructure_decl = .{ .kind = kind, .pattern = pattern, .init = init_expr } });
        }
        // One or more comma-separated declarators: `let a, b = 1, c`.
        var decls: std.ArrayListUnmanaged(*Node) = .empty;
        while (true) {
            const name_tok = self.advance();
            if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
            // A reserved word may not be a binding name — including when spelled
            // with `\u` escapes (the lexer hands us the decoded text).
            if (self.isForbiddenBindingName(name_tok.text)) return ParseError.UnexpectedToken;
            // A lexical declaration's (let/const/using) BoundNames may not contain
            // `let`, in every mode — `let let`, `const x, let`.
            if (kind != .@"var" and std.mem.eql(u8, name_tok.text, "let")) return ParseError.UnexpectedToken;
            var init_expr: ?*Node = null;
            if (self.match(.assign)) {
                init_expr = try self.parseAssignment();
                nameAnon(init_expr.?, name_tok.text);
            } else if (kind == .@"const" or dispose != 0) {
                // `const` and `using` declarations require an initializer.
                return ParseError.UnexpectedToken;
            }
            try decls.append(self.arena, try self.alloc(.{ .var_decl = .{ .kind = kind, .name = name_tok.text, .init = init_expr, .dispose = dispose } }));
            if (!self.match(.comma)) break;
        }
        try self.consumeStatementTerminator();
        // A single declarator stays a bare var_decl; multiples become a
        // transparent declaration group (NOT a block — no new scope).
        if (decls.items.len == 1) return decls.items[0];
        return self.alloc(.{ .decl_group = decls.items });
    }

    fn parseBlock(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        // A Block's StatementList permits `using`/`await using` declarations.
        const saved_using = self.using_allowed;
        self.using_allowed = true;
        defer self.using_allowed = saved_using;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            try stmts.append(self.arena, try self.parseStatement());
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .block = stmts.items });
    }

    fn parseIf(self: *Parser) ParseError!*Node {
        _ = self.advance(); // if
        try self.expect(.lparen);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        const cons = try self.parseSubStatement(.if_clause);
        var alt: ?*Node = null;
        if (isKeyword(self.cur(), "else")) {
            _ = self.advance();
            alt = try self.parseSubStatement(.if_clause);
        }
        return self.alloc(.{ .if_stmt = .{ .cond = cond, .consequent = cons, .alternate = alt } });
    }

    /// Parse a loop body, tracking that `break`/`continue` are now legal.
    fn parseLoopBody(self: *Parser) ParseError!*Node {
        const saved_pending = self.pending_labels.items.len;
        const saved_continue = self.continue_labels.items.len;
        for (self.pending_labels.items) |label|
            try self.continue_labels.append(self.arena, label);
        self.pending_labels.items.len = 0;
        self.iter_depth += 1;
        defer {
            self.iter_depth -= 1;
            self.pending_labels.items.len = saved_pending;
            self.continue_labels.items.len = saved_continue;
        }
        return self.parseSubStatement(.loop_with);
    }

    fn parseWhile(self: *Parser) ParseError!*Node {
        _ = self.advance(); // while
        try self.expect(.lparen);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseLoopBody();
        return self.alloc(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseDoWhile(self: *Parser) ParseError!*Node {
        _ = self.advance(); // do
        const body = try self.parseLoopBody();
        if (!isKeyword(self.cur(), "while")) return ParseError.ExpectedToken;
        _ = self.advance(); // while
        try self.expect(.lparen);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        _ = self.match(.semicolon);
        return self.alloc(.{ .do_while_stmt = .{ .body = body, .cond = cond } });
    }

    fn parseFor(self: *Parser) ParseError!*Node {
        _ = self.advance(); // for
        // `for await (x of asyncIterable)` — only inside an async function.
        var is_await = false;
        if (self.in_async and isKeyword(self.cur(), "await")) {
            _ = self.advance();
            is_await = true;
        }
        try self.expect(.lparen);

        // Detect `for (... in/of ...)`. Save position so we can fall back to a
        // classic `for (init; cond; update)` if it isn't an iteration form.
        const save = self.pos;
        var decl_kind: ?ast.DeclKind = null;
        var is_using = false;
        var dispose: u8 = 0; // 1 = `using`, 2 = `await using` (for a for-of head)
        if (isKeyword(self.cur(), "var")) {
            decl_kind = .@"var";
            _ = self.advance();
        } else if (self.letDeclAhead()) {
            decl_kind = .let;
            _ = self.advance();
        } else if (isKeyword(self.cur(), "const")) {
            decl_kind = .@"const";
            _ = self.advance();
        } else if (isKeyword(self.cur(), "using") and self.peekKind(1) == .identifier and
            !self.peekIsKeyword(1, "of") and self.noNewlineBefore(1))
        {
            // `for (using x of …)` (but `for (using of …)` has `using` as the var).
            decl_kind = .@"const";
            is_using = true;
            dispose = 1;
            _ = self.advance();
        } else if (isKeyword(self.cur(), "await") and self.peekIsKeyword(1, "using") and
            self.peekKind(2) == .identifier and self.noNewlineBefore(1) and self.noNewlineBefore(2))
        {
            // `for (await using x of …)`; `x` may itself be the contextual name
            // `of`, so consume both declaration keywords before parsing target.
            decl_kind = .@"const";
            is_using = true;
            dispose = 2;
            _ = self.advance(); // await
            _ = self.advance(); // using
        }
        const classic_using_of_decl =
            self.pos == save and
            isKeyword(self.cur(), "using") and
            self.peekIsKeyword(1, "of") and
            self.peekKind(2) == .assign;
        const classic_async_of_arrow =
            self.pos == save and
            isKeyword(self.cur(), "async") and
            self.peekIsKeyword(1, "of") and
            self.peekKind(2) == .arrow;
        // `for (async of …)` — a plain for-of forbids a bare, unescaped `async`
        // token directly before `of` (lookahead restriction). `for await`,
        // a parenthesized `(async)`, and an escaped `async` are all unaffected,
        // and `for (async of => …)` is the async-arrow classic form above.
        if (!is_await and self.pos == save and decl_kind == null and
            isKeyword(self.cur(), "async") and !self.cur().escaped_identifier and
            self.peekIsKeyword(1, "of") and self.peekKind(2) != .arrow)
            return ParseError.UnexpectedToken;
        // Iteration form `for ([decl] target in/of iterable)`, where `target`
        // is an identifier, a destructuring pattern, or (assignment form) a
        // member expression. Parse a target, then require `in`/`of`; otherwise
        // rewind to `save` and parse a classic `for(;;)`.
        if (!classic_using_of_decl and !classic_async_of_arrow) if (self.tryForTarget(decl_kind) catch null) |target| {
            var var_init: ?*Node = null;
            if (!self.strict and decl_kind != null and decl_kind.? == .@"var" and target.* == .identifier and self.match(.assign)) {
                const saved_no_in = self.no_in;
                self.no_in = true;
                var_init = try self.parseExpression();
                self.no_in = saved_no_in;
                nameAnon(var_init.?, target.identifier);
            }
            // `in`/`of` written with a Unicode escape (`of`) is never the
            // contextual keyword, so it cannot introduce an iteration head.
            const at_iter = !self.cur().escaped_identifier and
                (isKeyword(self.cur(), "in") or isKeyword(self.cur(), "of"));
            if (at_iter) {
                // A lexical (`let`/`const`) for-in/of head binds the target's names
                // and must have no duplicates: `for (let [x, x] of …)` is an error.
                if (decl_kind) |k| if (k != .@"var") try self.checkNoDuplicateBindings(target);
                const is_of = isKeyword(self.advance(), "of"); // consume in/of
                // A `using`/`await using` head is valid only in a for-of/-await-of,
                // never a for-in: `for (using x in obj)` is a SyntaxError.
                if (is_using and !is_of) return ParseError.UnexpectedToken;
                if (var_init != null and is_of) return ParseError.UnexpectedToken;
                // `for-in` takes an Expression, `for-of` an AssignmentExpression.
                const iterable = if (is_of) try self.parseAssignment() else try self.parseExpression();
                try self.expect(.rparen);
                const body = try self.parseLoopBody();
                if (decl_kind) |k| if (k != .@"var") try self.checkForHeadVarConflict(target, body);
                return self.alloc(.{ .for_in = .{
                    .decl_kind = decl_kind,
                    .target = target,
                    .var_init = var_init,
                    .iterable = iterable,
                    .body = body,
                    .is_of = is_of,
                    .is_await = is_await,
                    .dispose = dispose,
                } });
            }
        };
        self.pos = save; // not an iteration form — rewind and parse a classic for

        var init_node: ?*Node = null;
        if (self.match(.semicolon)) {
            // empty initializer
        } else if (isKeyword(self.cur(), "var")) {
            init_node = try self.parseVarDecl(.@"var"); // consumes the ';'
        } else if (self.letDeclAhead()) {
            init_node = try self.parseVarDecl(.let);
        } else if (isKeyword(self.cur(), "const")) {
            init_node = try self.parseVarDecl(.@"const");
        } else if (isKeyword(self.cur(), "using") and self.peekKind(1) == .identifier and self.noNewlineBefore(1)) {
            // `for (using x = e; …)` — a using declaration head (the `using of`
            // lookahead restriction applies only to for-of, not the classic for).
            init_node = try self.parseVarDeclDispose(.@"const", 1);
        } else if (isKeyword(self.cur(), "await") and self.peekIsKeyword(1, "using") and
            self.peekKind(2) == .identifier and self.noNewlineBefore(1) and self.noNewlineBefore(2))
        {
            _ = self.advance(); // await
            init_node = try self.parseVarDeclDispose(.@"const", 2);
        } else {
            // A classic for-init is `[~In]`: a top-level `in` is forbidden here.
            self.no_in = true;
            init_node = try self.parseExpression();
            self.no_in = false;
            try self.expect(.semicolon);
        }
        var cond: ?*Node = null;
        if (!self.check(.semicolon)) cond = try self.parseExpression();
        try self.expect(.semicolon);
        var update: ?*Node = null;
        if (!self.check(.rparen)) update = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseLoopBody();
        if (init_node) |ini| try self.checkForHeadDeclVarConflict(ini, body);
        return self.alloc(.{ .for_stmt = .{ .init = init_node, .cond = cond, .update = update, .body = body } });
    }

    /// Parse a `for-in`/`for-of` loop target (the part between the optional
    /// declaration keyword and `in`/`of`): an identifier, a destructuring
    /// pattern, or — in the assignment form (no `decl_kind`) — a member
    /// expression. Returns null when the head clearly isn't an iteration target
    /// (so the caller falls back to a classic `for(;;)`).
    fn tryForTarget(self: *Parser, decl_kind: ?ast.DeclKind) ParseError!?*Node {
        if (self.check(.lbrace) or self.check(.lbracket)) {
            if (decl_kind != null) return try self.parseBindingTarget();
            const start = self.pos;
            // Assignment form: an array/object literal cover is a destructuring
            // target only when the head is immediately an in/of form. Otherwise
            // let a classic for initializer parse the left-hand-side expression.
            const node = try self.parsePostfix();
            if (node.* == .member or node.* == .super_member) return node;
            if (isKeyword(self.cur(), "in") or isKeyword(self.cur(), "of")) return try self.litToPattern(node);
            self.pos = start;
            return null;
        }
        if (decl_kind != null) {
            // A declaration binds a single BindingIdentifier.
            if (self.check(.identifier)) {
                const name = self.cur().text;
                if (self.isForbiddenBindingName(name)) return ParseError.UnexpectedToken;
                return try self.alloc(.{ .identifier = self.advance().text });
            }
            return null;
        }
        // Assignment form: a LeftHandSideExpression that must be a valid
        // assignment target. Anything else (a call, `this`, a literal, …) makes
        // this not an iteration form, so the caller rewinds and it becomes a
        // syntax error in the classic-`for` path.
        const node = try self.parsePostfix();
        return switch (node.*) {
            .identifier, .member, .super_member => node,
            .call => if (!self.strict) node else null,
            else => null,
        };
    }

    fn parseSwitch(self: *Parser) ParseError!*Node {
        _ = self.advance(); // switch
        try self.expect(.lparen);
        const disc = try self.parseExpression();
        try self.expect(.rparen);
        try self.expect(.lbrace);
        // Inside a switch, unlabeled `break` is legal (but not `continue`).
        self.switch_depth += 1;
        // A CaseClause/DefaultClause StatementList forbids `using`/`await using`
        // (only a nested Block re-enables it); the discriminant/case tests are
        // expressions, so resetting here is safe.
        const saved_using = self.using_allowed;
        self.using_allowed = false;
        defer {
            self.switch_depth -= 1;
            self.using_allowed = saved_using;
        }
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        // A CaseBlock may contain at most one DefaultClause (early error 13.12.1).
        var seen_default = false;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            var test_expr: ?*Node = null;
            if (isKeyword(self.cur(), "case")) {
                _ = self.advance();
                test_expr = try self.parseExpression();
            } else if (isKeyword(self.cur(), "default")) {
                if (seen_default) return ParseError.UnexpectedToken;
                seen_default = true;
                _ = self.advance();
            } else return ParseError.UnexpectedToken;
            try self.expect(.colon);
            // Statements until the next case/default/closing brace.
            var body: std.ArrayListUnmanaged(*Node) = .empty;
            while (!self.check(.rbrace) and !self.check(.eof) and
                !isKeyword(self.cur(), "case") and !isKeyword(self.cur(), "default"))
            {
                try body.append(self.arena, try self.parseStatement());
            }
            try cases.append(self.arena, .{ .@"test" = test_expr, .body = body.items });
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .switch_stmt = .{ .disc = disc, .cases = cases.items } });
    }

    fn parseReturn(self: *Parser) ParseError!*Node {
        // `return` is only valid inside a function body.
        if (self.fn_depth == 0) return ParseError.UnexpectedToken;
        _ = self.advance(); // return
        var arg: ?*Node = null;
        if (!self.hasLineTerminatorBefore(0) and !self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof)) {
            arg = try self.parseExpression();
        }
        _ = self.match(.semicolon);
        return self.alloc(.{ .return_stmt = arg });
    }

    fn parseThrow(self: *Parser) ParseError!*Node {
        _ = self.advance(); // throw
        if (self.hasLineTerminatorBefore(0)) return ParseError.UnexpectedToken;
        const arg = try self.parseExpression();
        _ = self.match(.semicolon);
        return self.alloc(.{ .throw_stmt = arg });
    }

    /// Catch-clause early errors (14.15.1): the CatchParameter's BoundNames must
    /// be unique (`catch ([x, x]) {}`) and must not also appear in the catch
    /// block's LexicallyDeclaredNames — a `let`/`const`/`class` or a block-level
    /// function declaration that reuses a catch-bound name (`catch (e) { let e; }`,
    /// `catch (e) { function e(){} }`) is a SyntaxError. (Annex B.3.5 still lets a
    /// body `var` match a simple catch parameter, so `var` is not checked here.)
    fn checkCatchClause(self: *Parser, param: *Node, block: *Node) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, param);
        var bound: std.StringHashMapUnmanaged(void) = .empty;
        for (names.items) |n| {
            if (n.len == 0) continue;
            if (bound.contains(n)) return ParseError.UnexpectedToken;
            try bound.put(self.arena, n, {});
        }
        if (bound.count() == 0 or block.* != .block) return;
        for (block.block) |s| switch (s.*) {
            .var_decl => |d| if (d.kind != .@"var" and bound.contains(d.name)) return ParseError.UnexpectedToken,
            .destructure_decl => |d| if (d.kind != .@"var") {
                var bn: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&bn, d.pattern);
                for (bn.items) |n| if (bound.contains(n)) return ParseError.UnexpectedToken;
            },
            .decl_group => |g| for (g) |d2| {
                if (d2.* == .var_decl and d2.var_decl.kind != .@"var" and bound.contains(d2.var_decl.name)) return ParseError.UnexpectedToken;
            },
            .func_decl => |fnode| if (fnode.name.len > 0 and bound.contains(fnode.name)) return ParseError.UnexpectedToken,
            .class_expr => |c| if (c.name.len > 0 and bound.contains(c.name)) return ParseError.UnexpectedToken,
            else => {},
        };
    }

    fn parseTry(self: *Parser) ParseError!*Node {
        _ = self.advance(); // try
        const block = try self.parseBlock();
        var catch_param: ?*Node = null;
        var catch_block: ?*Node = null;
        var finally_block: ?*Node = null;
        if (isKeyword(self.cur(), "catch")) {
            _ = self.advance();
            if (self.match(.lparen)) {
                catch_param = try self.parseBindingTarget(); // identifier or destructuring pattern
                try self.expect(.rparen);
            }
            catch_block = try self.parseBlock();
            if (catch_param) |p| try self.checkCatchClause(p, catch_block.?);
        }
        if (isKeyword(self.cur(), "finally")) {
            _ = self.advance();
            finally_block = try self.parseBlock();
        }
        if (catch_block == null and finally_block == null) return ParseError.UnexpectedToken;
        const node = try self.arena.create(ast.TryNode);
        node.* = .{ .block = block, .catch_param = catch_param, .catch_block = catch_block, .finally_block = finally_block };
        return self.alloc(.{ .try_stmt = node });
    }

    /// Parse `(p1, p2 = default, ...rest)` into a slice of parameters.
    fn parseParamList(self: *Parser) ParseError![]const ast.Param {
        try self.expect(.lparen);
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            const is_rest = self.match(.ellipsis);
            // Destructuring parameter: `function f({a}, [b])`, and rest
            // destructuring: `function f(...[a], ...{a})` (no default allowed
            // on a rest element, and it must be last).
            if (self.check(.lbrace) or self.check(.lbracket)) {
                const pat = try self.parseBindingTarget();
                const default = if (!is_rest and self.match(.assign)) try self.parseAssignment() else null;
                try params.append(self.arena, .{ .name = "", .pattern = pat, .default = default, .is_rest = is_rest });
                if (is_rest) break; // a rest parameter must be last
                if (!self.match(.comma)) break;
                continue;
            }
            const p = self.advance();
            if (p.kind != .identifier) return ParseError.UnexpectedToken;
            if (self.isForbiddenBindingName(p.text)) return ParseError.UnexpectedToken;
            var default: ?*Node = null;
            if (!is_rest and self.match(.assign)) default = try self.parseAssignment();
            try params.append(self.arena, .{ .name = p.text, .default = default, .is_rest = is_rest });
            if (is_rest) break; // a rest parameter must be last
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return params.items;
    }

    /// Parse a function/method's formal parameter list in that function's own
    /// [Yield, Await] context: a generator's parameters are [+Yield] and an async
    /// function's are [+Await], so `yield`/`await` is a reserved word there
    /// (`function* g(yield) {}`, `async function f(await) {}` are errors) and a
    /// YieldExpression/AwaitExpression among the parameter defaults
    /// (`function* g(a = yield) {}`, `async function f(a = await x) {}`) is the
    /// early error "FormalParameters Contains Yield/AwaitExpression". A function
    /// nested in a generator/async function gets its OWN context (it does not
    /// inherit), so `yield`/`await` is an ordinary identifier in its parameters
    /// again. (Arrows, which DO inherit, use parseParamList directly instead.)
    fn parseFunctionParamList(self: *Parser, is_gen: bool, is_async: bool) ParseError![]const ast.Param {
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.new_target_depth += 1;
        self.in_async = is_async;
        self.in_generator = is_gen;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
            self.new_target_depth -= 1;
        }
        const params = try self.parseParamList();
        if (is_gen or is_async) {
            const saved_allow = self.scan_allow_arguments;
            const saved_fy = self.scan_forbid_yield;
            const saved_fa = self.scan_forbid_await;
            self.scan_allow_arguments = true; // only Yield/AwaitExpression is the concern here
            self.scan_forbid_yield = is_gen;
            self.scan_forbid_await = is_async;
            defer {
                self.scan_allow_arguments = saved_allow;
                self.scan_forbid_yield = saved_fy;
                self.scan_forbid_await = saved_fa;
            }
            for (params) |p| if (p.default) |d| try self.scanSuperAndArgs(d);
        }
        return params;
    }

    fn isEvalOrArguments(name: []const u8) bool {
        return std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments");
    }

    fn isAnnexBCallAssignmentTarget(node: *const Node) bool {
        return node.* == .call;
    }

    /// A getter takes no parameters; a setter takes exactly one (non-rest)
    /// parameter. Otherwise it's a SyntaxError. `func` is a `.function` node.
    fn validateAccessor(func: *Node, kind: ast.AccessorKind) ParseError!void {
        const params = func.function.params;
        switch (kind) {
            .get => if (params.len != 0) return ParseError.UnexpectedToken,
            .set => if (params.len != 1 or params[0].is_rest) return ParseError.UnexpectedToken,
            .none => {},
        }
    }

    /// Strict-mode early errors on a formal parameter list: a parameter named
    /// `eval`/`arguments`, or any duplicate parameter name, is a SyntaxError.
    fn validateStrictParams(params: []const ast.Param) ParseError!void {
        for (params, 0..) |p, i| {
            if (p.pattern != null) continue;
            if (std.mem.eql(u8, p.name, "eval") or std.mem.eql(u8, p.name, "arguments"))
                return ParseError.UnexpectedToken;
            if (isStrictReservedBinding(p.name)) return ParseError.UnexpectedToken;
            for (params[0..i]) |q| {
                if (q.pattern == null and std.mem.eql(u8, q.name, p.name)) return ParseError.UnexpectedToken;
            }
        }
    }

    /// UniqueFormalParameters: duplicate simple parameter names are an early
    /// error for arrow functions and method definitions in EVERY mode (unlike
    /// ordinary functions, which permit them in sloppy mode with a simple param
    /// list). Mirrors the duplicate-name scan in validateStrictParams; pattern
    /// params are not simple names and are skipped (their own binding-dup rule is
    /// separate), so no valid parameter list is rejected.
    fn checkDuplicateParams(self: *Parser, params: []const ast.Param) ParseError!void {
        // BoundNames of the parameter list must contain no duplicates — including
        // names bound inside destructuring patterns, so `([a], {a}) => {}` and
        // `({a, a}) => {}` are early errors.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (params) |p| {
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            if (p.pattern) |pat| try self.addPatternNames(&names, pat) else if (p.name.len > 0) try names.append(self.arena, p.name);
            for (names.items) |n| {
                if (seen.contains(n)) return ParseError.UnexpectedToken;
                try seen.put(self.arena, n, {});
            }
        }
    }

    /// A "simple parameter list" contains only single BindingIdentifiers — no
    /// defaults, rest, or destructuring. A function whose body opens with its
    /// OWN "use strict" directive must have a simple parameter list, an early
    /// error in every mode; this reports whether the list is non-simple.
    fn hasNonSimpleParams(params: []const ast.Param) bool {
        for (params) |p| {
            if (p.pattern != null or p.is_rest or p.default != null) return true;
        }
        return false;
    }

    /// An ordinary `function`/`function*`/`async function[*]` has no
    /// [[HomeObject]] and no `super` binding, so a SuperCall (`super()`) or
    /// SuperProperty (`super.x`) anywhere in its parameters or body — including
    /// inside a nested arrow, which inherits the absent binding — is an early
    /// SyntaxError (`arguments` stays legal). The scan stops at nested ordinary
    /// functions/classes/methods, which establish their own `super`.
    fn forbidSuperInFunction(self: *Parser, body: *Node, params: []const ast.Param) ParseError!void {
        const saved_args = self.scan_allow_arguments;
        const saved_prop = self.scan_forbid_super_property;
        self.scan_allow_arguments = true;
        self.scan_forbid_super_property = true;
        defer {
            self.scan_allow_arguments = saved_args;
            self.scan_forbid_super_property = saved_prop;
        }
        for (params) |p| if (p.default) |d| try self.scanSuperAndArgs(d);
        try self.scanSuperAndArgs(body);
    }

    fn parseFunctionDecl(self: *Parser, is_async: bool) ParseError!*Node {
        const start = self.pos;
        if (is_async) _ = self.advance(); // async
        _ = self.advance(); // function
        const is_gen = self.match(.star); // `function*` / `async function*`
        const name_tok = self.advance();
        if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
        if (self.isForbiddenBindingName(name_tok.text)) return ParseError.UnexpectedToken;
        const params = try self.parseFunctionParamList(is_gen, is_async);
        const own_use_strict = self.peekUseStrict();
        // This function's strictness: inherited OR its own "use strict" prologue.
        // Captured BEFORE parseFnBody, which clobbers `last_fn_strict` when it
        // parses nested functions (so it can't be used to stamp THIS function).
        const fn_strict = self.strict or own_use_strict;
        const body = try self.parseFnBody(is_gen, is_async);
        if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
        if (fn_strict and (isStrictReservedBinding(name_tok.text) or isEvalOrArguments(name_tok.text))) return ParseError.UnexpectedToken;
        if (fn_strict) try validateStrictParams(params);
        try self.forbidSuperInFunction(body, params);
        // A generator/async function, or ANY function with a non-simple parameter
        // list (a default/rest/destructuring), has UniqueFormalParameters:
        // duplicate names are an error in every mode. Only a plain function with a
        // simple list permits sloppy duplicates (handled by validateStrictParams
        // in strict mode).
        if (is_gen or is_async or hasNonSimpleParams(params)) try self.checkDuplicateParams(params);
        try self.checkParamBodyConflict(params, body);
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name_tok.text, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = fn_strict };
        return self.alloc(.{ .func_decl = fnode });
    }

    /// `function [name](params) { body }` in expression position.
    fn parseFunctionExpr(self: *Parser, is_async: bool) ParseError!*Node {
        const start = self.pos;
        if (is_async) _ = self.advance(); // async
        _ = self.advance(); // function
        const is_gen = self.match(.star); // `function*` / `async function*`
        var name: []const u8 = "";
        if (self.check(.identifier) and !std.mem.eql(u8, self.cur().text, "")) {
            // Optional name (anything that isn't the opening paren).
            if (!self.check(.lparen)) {
                // A FunctionExpression's name is a BindingIdentifier scoped to the
                // function's OWN [Yield, Await] (a generator expr uses [+Yield],
                // a plain function expr [~Yield]), not the surrounding context —
                // so `function* g(){ (function yield(){}) }` is valid.
                const saved_gen = self.in_generator;
                const saved_async = self.in_async;
                self.in_generator = is_gen;
                self.in_async = is_async;
                const forbidden = self.isForbiddenBindingName(self.cur().text);
                self.in_generator = saved_gen;
                self.in_async = saved_async;
                if (forbidden) return ParseError.UnexpectedToken;
                name = self.advance().text;
            }
        }
        const params = try self.parseFunctionParamList(is_gen, is_async);
        const own_use_strict = self.peekUseStrict();
        const fn_strict = self.strict or own_use_strict; // captured before parseFnBody (see parseFunctionDecl)
        const body = try self.parseFnBody(is_gen, is_async);
        if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
        if (fn_strict and name.len > 0 and (isStrictReservedBinding(name) or isEvalOrArguments(name))) return ParseError.UnexpectedToken;
        if (fn_strict) try validateStrictParams(params);
        try self.forbidSuperInFunction(body, params);
        // A generator/async function, or ANY function with a non-simple parameter
        // list (a default/rest/destructuring), has UniqueFormalParameters:
        // duplicate names are an error in every mode. Only a plain function with a
        // simple list permits sloppy duplicates (handled by validateStrictParams
        // in strict mode).
        if (is_gen or is_async or hasNonSimpleParams(params)) try self.checkDuplicateParams(params);
        try self.checkParamBodyConflict(params, body);
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .has_name_binding = name.len > 0, .is_generator = is_gen, .is_async = is_async, .is_strict = fn_strict };
        return self.alloc(.{ .function = fnode });
    }

    /// Parse a function/method `{ body }`, recognizing `yield`/`await` as yield/
    /// await expressions iff `is_gen`/`is_async`. A function body opens fresh
    /// generator/async contexts (an inner non-generator function nested in a
    /// generator does not see `yield` as a keyword), restored on the way out.
    fn parseFnBody(self: *Parser, is_gen: bool, is_async: bool) ParseError!*Node {
        const saved_gen = self.in_generator;
        const saved_async = self.in_async;
        const saved_strict = self.strict;
        const saved_iter = self.iter_depth;
        const saved_switch = self.switch_depth;
        const saved_active_labels = self.active_labels.items.len;
        const saved_pending_labels = self.pending_labels.items.len;
        const saved_continue_labels = self.continue_labels.items.len;
        self.in_generator = is_gen;
        self.in_async = is_async;
        // A function body opens a fresh control-flow context: `return` is now
        // legal and `break`/`continue` can't target an outer loop/switch.
        self.fn_depth += 1;
        self.new_target_depth += 1;
        self.iter_depth = 0;
        self.switch_depth = 0;
        self.active_labels.items.len = 0;
        self.pending_labels.items.len = 0;
        self.continue_labels.items.len = 0;
        // A function is strict if it lexically inherits strictness or its own
        // body opens with a `"use strict"` directive prologue. Detect it up
        // front so nested functions parsed within inherit correctly.
        self.strict = saved_strict or self.peekUseStrict();
        self.last_fn_strict = self.strict;
        // A function body is `[+In]`, even nested in a for-init's `[~In]` context.
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer {
            self.in_generator = saved_gen;
            self.in_async = saved_async;
            self.strict = saved_strict;
            self.fn_depth -= 1;
            self.new_target_depth -= 1;
            self.iter_depth = saved_iter;
            self.switch_depth = saved_switch;
            self.active_labels.items.len = saved_active_labels;
            self.pending_labels.items.len = saved_pending_labels;
            self.continue_labels.items.len = saved_continue_labels;
            self.no_in = saved_no_in;
        }
        return self.parseBlock();
    }

    /// Does a `"use strict"` directive lead the body about to be parsed? The
    /// current token is the opening `{`; a directive prologue is a leading run of
    /// string-literal expression statements, so scan those (skipping the `{` and
    /// statement-separating `;`) and stop at the first non-directive token.
    fn peekUseStrict(self: *Parser) bool {
        var i = self.pos;
        if (i >= self.tokens.len or self.tokens[i].kind != .lbrace) return false;
        i += 1;
        while (i < self.tokens.len and self.tokens[i].kind == .string) {
            const t = self.tokens[i];
            // A "use strict" directive must be the EXACT source `'use strict'` /
            // `"use strict"` — no escapes or line continuations. The decoded text
            // matching isn't enough (`'use \strict'` decodes to "use strict" but
            // is not a directive), so require the raw lexeme to be just the quoted
            // text: end - pos == text.len + 2 (the two quote characters).
            if (std.mem.eql(u8, t.text, "use strict") and t.end - t.pos == t.text.len + 2) return true;
            i += 1;
            if (i < self.tokens.len and self.tokens[i].kind == .semicolon) i += 1;
        }
        return false;
    }

    /// `yield [expr]` / `yield* expr`. Only reached inside a generator body.
    fn parseYield(self: *Parser) ParseError!*Node {
        _ = self.advance(); // yield
        // `yield [no LineTerminator here] * AssignmentExpression`: a `*` on the
        // next line is not part of the yield, so `yield \n * x` is a SyntaxError
        // (the orphaned `*` fails to parse as the yield's operand below).
        const delegate = self.noNewlineBefore(0) and self.match(.star);
        var arg: ?*Node = null;
        // `yield [no LineTerminator here] AssignmentExpression`: a newline after a
        // plain `yield` ends it (the next line is a separate statement), so
        // `yield \n x` yields undefined. `yield*` always takes an operand (its
        // newline restriction, before the `*`, was already enforced above).
        if (delegate or (self.noNewlineBefore(0) and self.startsExpression())) {
            arg = if (self.check(.slash)) try self.parseRegexLiteralFromSlash() else try self.parseAssignment();
        }
        return self.alloc(.{ .yield_expr = .{ .argument = arg, .delegate = delegate } });
    }

    fn parseRegexLiteralFromSlash(self: *Parser) ParseError!*Node {
        const start = self.cur().pos;
        var i = start + 1;
        var in_class = false;
        while (i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (c == '\n' or c == '\r') return ParseError.UnexpectedToken;
            if (c == '\\') {
                i += 1;
                if (i >= self.source.len) return ParseError.UnexpectedToken;
                continue;
            }
            if (c == '[') {
                in_class = true;
                continue;
            }
            if (c == ']') {
                in_class = false;
                continue;
            }
            if (c == '/' and !in_class) {
                const pattern = self.source[start + 1 .. i];
                var end = i + 1;
                while (end < self.source.len and isIdentifierPartByte(self.source[end])) : (end += 1) {}
                const flags = self.source[i + 1 .. end];
                try validateRegexLiteral(self.arena, pattern, flags);
                while (self.pos < self.tokens.len and self.tokens[self.pos].pos < end) self.pos += 1;
                return self.alloc(.{ .regex_literal = .{ .pattern = pattern, .flags = flags } });
            }
        }
        return ParseError.UnexpectedToken;
    }

    fn isIdentifierPartByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
    }

    /// Whether the current token can begin an expression (used to decide if a
    /// bare `yield`/`return` has an operand). Conservative: treats clause
    /// terminators as non-starters.
    fn startsExpression(self: *Parser) bool {
        return switch (self.cur().kind) {
            .rparen, .rbracket, .rbrace, .comma, .semicolon, .colon, .eof => false,
            else => true,
        };
    }

    // ----- expressions ----------------------------------------------------

    fn parseExpression(self: *Parser) ParseError!*Node {
        var e = try self.parseAssignment();
        // The comma operator (only at true expression positions — arg lists,
        // array/object elements, and declarators use parseAssignment directly).
        while (self.check(.comma)) {
            _ = self.advance();
            const rhs = try self.parseAssignment();
            e = try self.alloc(.{ .sequence = .{ .first = e, .second = rhs } });
        }
        return e;
    }

    fn parseAssignment(self: *Parser) ParseError!*Node {
        // `yield` is an AssignmentExpression-level production inside generators.
        if (self.in_generator and isKeyword(self.cur(), "yield")) return self.parseYield();
        // Async arrows: `async x => ...` and `async (a, b) => ...`. (`async` here
        // is a contextual keyword; a `=>` must follow its parameter list.)
        // An escaped `async` (`async`) is never the contextual keyword, so it
        // cannot begin an async arrow; a LineTerminator after `async` also breaks
        // the `async [no LineTerminator here] ArrowParameters` form (`async\n(x)=>`
        // is a call, not an arrow).
        if (isKeyword(self.cur(), "async") and !self.cur().escaped_identifier and self.noNewlineBefore(1)) {
            const start = self.pos;
            if (self.peekKind(1) == .identifier and self.peekKind(2) == .arrow and
                !isAlwaysReservedBinding(self.tokens[self.pos + 1].text) and
                !(self.strict and isStrictReservedBinding(self.tokens[self.pos + 1].text)))
            {
                _ = self.advance(); // async
                const param = self.advance().text;
                // An async arrow's parameter is [+Await]: `await` is reserved.
                if (std.mem.eql(u8, param, "await")) return ParseError.UnexpectedToken;
                const params = try self.arena.dupe(ast.Param, &.{.{ .name = param }});
                return self.parseArrowBody(params, true, start);
            }
            if (self.peekKind(1) == .lparen and self.arrowAheadAt(self.pos + 1)) {
                _ = self.advance(); // async
                const params = try self.parseAsyncArrowParams();
                return self.parseArrowBody(params, true, start);
            }
        }
        // Arrow functions: `x => ...` and `(a, b) => ...`.
        if (self.check(.identifier) and self.peekKind(1) == .arrow) {
            const start = self.pos;
            // No LineTerminator is allowed between the parameter and `=>`
            // (the `[no LineTerminator here]` ASI restriction): `x \n => x` is a
            // SyntaxError. The single binding must also be a legal name (not
            // `eval`/`arguments`/a reserved word in the current strict/[Yield,
            // Await] context).
            if (!self.noNewlineBefore(1)) return ParseError.UnexpectedToken;
            const param = self.advance().text;
            if (self.isForbiddenBindingName(param)) return ParseError.UnexpectedToken;
            const params = try self.arena.dupe(ast.Param, &.{.{ .name = param }});
            return self.parseArrowBody(params, false, start);
        }
        if (self.check(.lparen) and self.arrowAhead()) {
            const start = self.pos;
            const params = try self.parseParamList();
            // An arrow inherits [Yield]/[Await], so a YieldExpression (in a
            // generator) or AwaitExpression (in an async function/module) among
            // its parameter defaults is an early error: `function* g(){ (x =
            // yield) => {}; }`.
            if (self.in_generator or self.in_async or self.module) {
                const sa = self.scan_allow_arguments;
                const sy = self.scan_forbid_yield;
                const sfa = self.scan_forbid_await;
                self.scan_allow_arguments = true;
                self.scan_forbid_yield = self.in_generator;
                self.scan_forbid_await = self.in_async or self.module;
                defer {
                    self.scan_allow_arguments = sa;
                    self.scan_forbid_yield = sy;
                    self.scan_forbid_await = sfa;
                }
                for (params) |p| if (p.default) |d| try self.scanSuperAndArgs(d);
            }
            return self.parseArrowBody(params, false, start);
        }

        const left = try self.parseConditional();
        if (self.check(.assign)) {
            // An array/object literal on the LHS is a destructuring pattern.
            const target = switch (left.*) {
                .identifier, .member, .super_member => left,
                .call => if (!self.strict and isAnnexBCallAssignmentTarget(left)) left else return ParseError.InvalidAssignmentTarget,
                .array_lit, .object_lit => try self.litToPattern(left),
                else => return ParseError.InvalidAssignmentTarget,
            };
            // Strict mode forbids assigning to `eval`/`arguments`.
            if (self.strict and target.* == .identifier and isEvalOrArguments(target.identifier))
                return ParseError.UnexpectedToken;
            // A parenthesized LHS (`(f) = function(){}`) is not an IdentifierRef,
            // so NamedEvaluation does not apply — the function stays anonymous.
            const assign_pos = self.pos;
            const lhs_paren = self.isParenWrapped(target) or
                (target.* == .identifier and self.paren_assign_target_name != null and std.mem.eql(u8, target.identifier, self.paren_assign_target_name.?)) or
                (target.* == .identifier and self.parenWrappedIdentifierBefore(assign_pos, target.identifier));
            self.paren_assign_target_name = null;
            _ = self.advance();
            const value = try self.parseAssignment();
            if (target.* == .identifier and !lhs_paren) nameAnon(value, target.identifier); // `f = function(){}`
            return self.alloc(.{ .assign = .{ .target = target, .value = value, .target_parenthesized = lhs_paren } });
        }
        // Compound assignment `a op= b` desugars to `a = a op b`.
        const compound: ?ast.BinaryOp = switch (self.cur().kind) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .percent_eq => .mod,
            .star_star_eq => .pow,
            .shl_eq => .shl,
            .shr_eq => .shr,
            .ushr_eq => .ushr,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            else => null,
        };
        if (compound) |op| {
            if (left.* != .identifier and left.* != .member and left.* != .super_member and
                (self.strict or !isAnnexBCallAssignmentTarget(left)))
                return ParseError.InvalidAssignmentTarget;
            if (self.strict and left.* == .identifier and isEvalOrArguments(left.identifier))
                return ParseError.UnexpectedToken;
            _ = self.advance();
            const rhs = try self.parseAssignment();
            return self.alloc(.{ .op_assign = .{ .target = left, .op = op, .value = rhs } });
        }
        // Logical assignment: `a &&= b` -> `a && (a = b)`, etc. (short-circuiting).
        const logassign: ?ast.LogicalOp = switch (self.cur().kind) {
            .amp_amp_eq => .@"and",
            .pipe_pipe_eq => .@"or",
            .qq_eq => .nullish,
            else => null,
        };
        if (logassign) |op| {
            if (left.* != .identifier and left.* != .member and left.* != .super_member) return ParseError.InvalidAssignmentTarget;
            if (self.strict and left.* == .identifier and isEvalOrArguments(left.identifier))
                return ParseError.UnexpectedToken;
            _ = self.advance();
            const rhs = try self.parseAssignment();
            // A member target must resolve its reference (base + computed key)
            // exactly once, so it gets a dedicated node. An identifier target has
            // no such hazard, so it keeps the `a && (a = b)` desugaring (which
            // also gives the anonymous-RHS NamedEvaluation for free).
            if (left.* != .identifier)
                return self.alloc(.{ .logical_assign = .{ .target = left, .op = op, .value = rhs } });
            const set = try self.alloc(.{ .assign = .{ .target = left, .value = rhs } });
            return self.alloc(.{ .logical = .{ .op = op, .left = left, .right = set } });
        }
        return left;
    }

    fn peekKind(self: *Parser, ahead: usize) TokenKind {
        const idx = self.pos + ahead;
        return if (idx < self.tokens.len) self.tokens[idx].kind else .eof;
    }

    /// True if the token `ahead` of the cursor is an identifier with text `word`
    /// (i.e. one of the contextual keywords the lexer emits as identifiers).
    fn peekIsKeyword(self: *Parser, ahead: usize, word: []const u8) bool {
        const idx = self.pos + ahead;
        if (idx >= self.tokens.len) return false;
        const t = self.tokens[idx];
        return t.kind == .identifier and std.mem.eql(u8, t.text, word);
    }

    /// True when an `async` modifier begins a method/property: `async name(...)`,
    /// `async *gen(...)`, or `async [computed](...)`. A bare `async` property
    /// (`{ async }`, `{ async: 1 }`, `{ async() {} }`) is *not* a modifier.
    fn asyncMethodAhead(self: *Parser) bool {
        // An escaped `async` (`async`) is never the contextual keyword, and a
        // LineTerminator after `async` breaks the `async [no LineTerminator here]
        // MethodName` form (`async` then becomes a property/field name).
        if (self.cur().escaped_identifier) return false;
        if (!isKeyword(self.cur(), "async")) return false;
        if (!self.noNewlineBefore(1)) return false;
        return switch (self.peekKind(1)) {
            .identifier, .string, .number, .private_name, .lbracket, .star => true,
            else => false,
        };
    }

    /// Precondition: current token is `(`. Returns true if its matching `)` is
    /// immediately followed by `=>` (i.e. this is an arrow parameter list, not
    /// a parenthesized expression).
    fn arrowAhead(self: *Parser) bool {
        return self.arrowAheadAt(self.pos);
    }

    /// Like `arrowAhead`, but scanning a `(` that begins at token index `start`
    /// (used to peek past an `async` modifier: `async (params) => …`).
    fn arrowAheadAt(self: *Parser, start: usize) bool {
        var depth: usize = 0;
        var i = start;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lparen => depth += 1,
                .rparen => {
                    depth -= 1;
                    if (depth == 0) {
                        const next = if (i + 1 < self.tokens.len) self.tokens[i + 1].kind else .eof;
                        return next == .arrow;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    /// Parse an async arrow's `( params )` as [+Await] — `await` is reserved as a
    /// binding and an AwaitExpression among the defaults is the early error
    /// "FormalParameters Contains AwaitExpression" — while leaving the enclosing
    /// [Yield] context intact (an arrow inherits it, unlike an ordinary function).
    fn parseAsyncArrowParams(self: *Parser) ParseError![]const ast.Param {
        const saved_async = self.in_async;
        self.in_async = true;
        defer self.in_async = saved_async;
        const params = try self.parseParamList();
        const saved_allow = self.scan_allow_arguments;
        const saved_fa = self.scan_forbid_await;
        self.scan_allow_arguments = true;
        self.scan_forbid_await = true;
        defer {
            self.scan_allow_arguments = saved_allow;
            self.scan_forbid_await = saved_fa;
        }
        for (params) |p| if (p.default) |d| try self.scanSuperAndArgs(d);
        return params;
    }

    fn parseArrowBody(self: *Parser, params: []const ast.Param, is_async: bool, start: usize) ParseError!*Node {
        // No LineTerminator is allowed between the parameter list and `=>`
        // (`() \n => {}` is a SyntaxError).
        if (!self.noNewlineBefore(0)) return ParseError.UnexpectedToken;
        try self.expect(.arrow);
        try self.checkDuplicateParams(params); // arrows forbid duplicate params in all modes

        const fnode = try self.arena.create(ast.FunctionNode);
        // An arrow's body opens its own async context (so `await` inside an
        // `async () => …` is recognized), restored on exit.
        const saved_async = self.in_async;
        const saved_strict = self.strict;
        const saved_iter = self.iter_depth;
        const saved_switch = self.switch_depth;
        const saved_no_in = self.no_in; // an arrow body is `[+In]`
        self.in_async = is_async;
        self.fn_depth += 1;
        self.iter_depth = 0;
        self.switch_depth = 0;
        self.no_in = false;
        defer {
            self.in_async = saved_async;
            self.strict = saved_strict;
            self.fn_depth -= 1;
            self.iter_depth = saved_iter;
            self.switch_depth = saved_switch;
            self.no_in = saved_no_in;
        }
        if (self.check(.lbrace)) {
            const own_use_strict = self.peekUseStrict();
            if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
            self.strict = saved_strict or own_use_strict;
            fnode.* = .{ .params = params, .body = try self.parseBlock(), .is_expr_body = false, .is_arrow = true, .is_async = is_async, .is_strict = self.strict };
            try self.checkParamBodyConflict(params, fnode.body);
        } else {
            fnode.* = .{ .params = params, .body = try self.parseAssignment(), .is_expr_body = true, .is_arrow = true, .is_async = is_async, .is_strict = saved_strict };
        }
        fnode.source = self.sourceFrom(start);
        return self.alloc(.{ .function = fnode });
    }

    fn parseConditional(self: *Parser) ParseError!*Node {
        const cond = try self.parseBinary(0);
        if (self.match(.question)) {
            // The consequent of `?:` is always `[+In]`; the alternate inherits the
            // outer `[?In]` (so in a for-init `true ? 0 : 0 in {}` is an error).
            const saved_no_in = self.no_in;
            self.no_in = false;
            const cons = try self.parseAssignment();
            self.no_in = saved_no_in;
            try self.expect(.colon);
            const alt = try self.parseAssignment();
            return self.alloc(.{ .conditional = .{ .cond = cond, .consequent = cons, .alternate = alt } });
        }
        return cond;
    }

    const BinInfo = struct { bp: u8, binary: ?ast.BinaryOp = null, logical: ?ast.LogicalOp = null, right_assoc: bool = false };

    /// Binding info for the current token, including keyword operators
    /// (`instanceof`) that the lexer emits as plain identifiers. Binding powers
    /// follow JS precedence: `||` < `&&` < `|` < `^` < `&` < equality <
    /// relational < shift < additive < multiplicative < `**`.
    fn curBinInfo(self: *Parser) ?BinInfo {
        if (isKeyword(self.cur(), "instanceof")) return .{ .bp = 7, .binary = .instanceof };
        // `[~In]` (classic for-init): a top-level `in` is not a binary operator.
        if (!self.no_in and isKeyword(self.cur(), "in")) return .{ .bp = 7, .binary = .in_op };
        return binInfo(self.cur().kind);
    }

    fn binInfo(kind: TokenKind) ?BinInfo {
        return switch (kind) {
            .qq => .{ .bp = 1, .logical = .nullish },
            .pipe_pipe => .{ .bp = 1, .logical = .@"or" },
            .amp_amp => .{ .bp = 2, .logical = .@"and" },
            .pipe => .{ .bp = 3, .binary = .bit_or },
            .caret => .{ .bp = 4, .binary = .bit_xor },
            .amp => .{ .bp = 5, .binary = .bit_and },
            .eq => .{ .bp = 6, .binary = .eq },
            .neq => .{ .bp = 6, .binary = .neq },
            .eq_strict => .{ .bp = 6, .binary = .eq_strict },
            .neq_strict => .{ .bp = 6, .binary = .neq_strict },
            .lt => .{ .bp = 7, .binary = .lt },
            .le => .{ .bp = 7, .binary = .le },
            .gt => .{ .bp = 7, .binary = .gt },
            .ge => .{ .bp = 7, .binary = .ge },
            .shl => .{ .bp = 8, .binary = .shl },
            .shr => .{ .bp = 8, .binary = .shr },
            .ushr => .{ .bp = 8, .binary = .ushr },
            .plus => .{ .bp = 9, .binary = .add },
            .minus => .{ .bp = 9, .binary = .sub },
            .star => .{ .bp = 10, .binary = .mul },
            .slash => .{ .bp = 10, .binary = .div },
            .percent => .{ .bp = 10, .binary = .mod },
            .star_star => .{ .bp = 11, .binary = .pow, .right_assoc = true },
            else => null,
        };
    }

    fn parseBinary(self: *Parser, min_bp: u8) ParseError!*Node {
        // `#field in obj`: a private name is a valid primary only as the LHS of
        // `in` (a private brand check) — a RelationalExpression (bp 7). It can't
        // be the right operand of another relational op (`#a in #b in c` has the
        // middle `#b` in RHS position), so only recognize it when a relational
        // expression may start here (min_bp <= 7). Represent it as an identifier
        // whose text keeps the leading `#` so the interpreter can recognize it.
        var left = if (min_bp <= 7 and self.in_class and !self.no_in and self.check(.private_name) and self.peekIsKeyword(1, "in"))
            try self.alloc(.{ .identifier = self.advance().text })
        else
            try self.parseUnary();
        // `??` may not be combined with `||`/`&&` without parentheses
        // (CoalesceExpression and LogicalORExpression are distinct productions):
        // `a ?? b || c`, `a && b ?? c` are SyntaxErrors. Track, within this single
        // precedence level, whether a `??` and an `||`/`&&` both appear — a
        // parenthesized operand parses in a nested call, so it never trips this.
        var seen_coalesce = false;
        var seen_logical = false;
        while (self.curBinInfo()) |info| {
            if (info.bp < min_bp) break;
            if (info.logical) |lop| {
                if (lop == .nullish) {
                    if (seen_logical) return ParseError.UnexpectedToken;
                    seen_coalesce = true;
                } else {
                    if (seen_coalesce) return ParseError.UnexpectedToken;
                    seen_logical = true;
                }
            }
            _ = self.advance();
            // A `??` operand is a BitwiseORExpression, so it binds tighter than
            // `&&`/`||` — parse the right side above the logical level so an
            // unparenthesized `a ?? b && c` leaves `&& c` for the loop to reject.
            const next_min: u8 = if (info.logical == .nullish) 3 else if (info.right_assoc) info.bp else info.bp + 1;
            const right = try self.parseBinary(next_min);
            if (info.logical) |lop| {
                left = try self.alloc(.{ .logical = .{ .op = lop, .left = left, .right = right } });
            } else {
                left = try self.alloc(.{ .binary = .{ .op = info.binary.?, .left = left, .right = right } });
            }
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        // `await expr` — a unary operator, only inside an async function body.
        // An escaped `await` (`await`) is never the keyword (the leftover
        // identifier is then rejected as a reserved reference in its context).
        if (self.in_async and !self.cur().escaped_identifier and isKeyword(self.cur(), "await")) {
            _ = self.advance();
            const operand = if (self.check(.slash)) try self.parseRegexLiteralFromSlash() else try self.parseUnary();
            try self.rejectExponentAfterUnary();
            return self.alloc(.{ .await_expr = .{ .argument = operand } });
        }
        if (self.check(.plus_plus) or self.check(.minus_minus)) {
            const inc = self.cur().kind == .plus_plus;
            _ = self.advance();
            const operand = try self.parseUnary();
            // The operand of a prefix `++`/`--` must be a simple assignment
            // target (identifier or member access) — `++import(x)`, `++f()`,
            // `++1` are early SyntaxErrors.
            if (operand.* != .identifier and operand.* != .member and operand.* != .super_member and
                (self.strict or !isAnnexBCallAssignmentTarget(operand)))
                return ParseError.InvalidAssignmentTarget;
            // Strict mode forbids updating `eval`/`arguments` (they are not valid
            // assignment targets): `"use strict"; ++eval;` is a SyntaxError.
            if (self.strict and operand.* == .identifier and isEvalOrArguments(operand.identifier))
                return ParseError.UnexpectedToken;
            return self.alloc(.{ .update = .{ .inc = inc, .prefix = true, .target = operand } });
        }
        const t = self.cur();
        if (isKeyword(t, "delete")) {
            _ = self.advance();
            const operand = try self.parseUnary();
            // Strict mode: `delete` of an unqualified identifier is a SyntaxError.
            if (self.strict and operand.* == .identifier) return ParseError.UnexpectedToken;
            // `delete` of a private member reference (`delete obj.#x`, even when
            // parenthesized) is always an early SyntaxError.
            if (operand.* == .member and operand.member.property.len > 0 and operand.member.property[0] == '#')
                return ParseError.UnexpectedToken;
            try self.rejectExponentAfterUnary();
            return self.alloc(.{ .delete_expr = operand });
        }
        const op: ?ast.UnaryOp = switch (t.kind) {
            .minus => .neg,
            .plus => .pos,
            .bang => .not,
            .tilde => .bit_not,
            else => if (isKeyword(t, "typeof"))
                ast.UnaryOp.typeof
            else if (isKeyword(t, "void"))
                ast.UnaryOp.void_op
            else
                null,
        };
        if (op) |o| {
            _ = self.advance();
            const operand = try self.parseUnary();
            try self.rejectExponentAfterUnary();
            return self.alloc(.{ .unary = .{ .op = o, .operand = operand } });
        }
        return self.parsePostfix();
    }

    /// `ExponentiationExpression : UpdateExpression ** ...` — the left operand of
    /// `**` must be an UpdateExpression, never an unparenthesized UnaryExpression.
    /// So a `**` immediately following a just-parsed unary operator's operand
    /// (`-x ** 2`, `typeof x ** 2`, `await x ** 2`) is an early SyntaxError;
    /// parenthesizing (`(-x) ** 2`) or using an UpdateExpression (`++x ** 2`)
    /// avoids it. (Prefix `++`/`--` do not call this — they are UpdateExpressions.)
    fn rejectExponentAfterUnary(self: *Parser) ParseError!void {
        if (self.check(.star_star)) return ParseError.UnexpectedToken;
    }

    fn parsePostfix(self: *Parser) ParseError!*Node {
        const e = try self.parsePrimary();
        const m = try self.parseMemberTail(e);
        if ((self.check(.plus_plus) or self.check(.minus_minus)) and !self.hasLineTerminatorBefore(0)) {
            // A postfix `++`/`--` target must be a simple assignment target —
            // `import(x)++`, `f()++`, `1++` are early SyntaxErrors.
            if (m.* != .identifier and m.* != .member and m.* != .super_member and
                (self.strict or !isAnnexBCallAssignmentTarget(m)))
                return ParseError.InvalidAssignmentTarget;
            // Strict mode forbids updating `eval`/`arguments`: `"use strict";
            // eval++;` is a SyntaxError.
            if (self.strict and m.* == .identifier and isEvalOrArguments(m.identifier))
                return ParseError.UnexpectedToken;
            const inc = self.cur().kind == .plus_plus;
            _ = self.advance();
            return self.alloc(.{ .update = .{ .inc = inc, .prefix = false, .target = m } });
        }
        return m;
    }

    /// Consume a chain of `.prop`, `[expr]`, `?.…`, and `(args)` operators on `e`.
    fn parseMemberTail(self: *Parser, start: *Node) ParseError!*Node {
        var e = start;
        var has_optional = false;
        while (true) {
            if (self.match(.dot)) {
                const name = self.advance();
                if (name.kind != .identifier and name.kind != .private_name) return ParseError.UnexpectedToken;
                if (name.kind == .private_name and !self.in_class) return ParseError.UnexpectedToken;
                e = try self.alloc(.{ .member = .{ .object = e, .property = name.text } });
            } else if (self.match(.question_dot)) {
                has_optional = true;
                if (self.check(.lparen)) {
                    const args = try self.parseArgs();
                    e = try self.alloc(.{ .call = .{ .callee = e, .args = args, .optional = true } });
                } else if (self.match(.lbracket)) {
                    const saved_no_in = self.no_in; // a computed key is `[+In]`
                    self.no_in = false;
                    const idx = try self.parseExpression();
                    self.no_in = saved_no_in;
                    try self.expect(.rbracket);
                    e = try self.alloc(.{ .member = .{ .object = e, .computed = idx, .optional = true } });
                } else {
                    const name = self.advance();
                    if (name.kind != .identifier and name.kind != .private_name) return ParseError.UnexpectedToken;
                    if (name.kind == .private_name and !self.in_class) return ParseError.UnexpectedToken;
                    e = try self.alloc(.{ .member = .{ .object = e, .property = name.text, .optional = true } });
                }
            } else if (self.match(.lbracket)) {
                const saved_no_in = self.no_in; // a computed key is `[+In]`
                self.no_in = false;
                const idx = try self.parseExpression();
                self.no_in = saved_no_in;
                try self.expect(.rbracket);
                e = try self.alloc(.{ .member = .{ .object = e, .computed = idx } });
            } else if (self.check(.lparen)) {
                const args = try self.parseArgs();
                e = try self.alloc(.{ .call = .{ .callee = e, .args = args } });
            } else if (self.check(.template)) {
                // A tagged template may not appear in an optional chain
                // (`a?.b`tmpl`` is a SyntaxError) — short-circuiting a tag call is
                // disallowed.
                if (has_optional) return ParseError.UnexpectedToken;
                // Tagged template: `tag`...`` — call `tag` with the cooked-string
                // array (carrying `raw`) and the substitution values.
                const tmpl = self.advance();
                e = try self.parseTaggedTemplate(e, tmpl.text);
            } else break;
        }
        if (has_optional) e = try self.alloc(.{ .optional_chain = e });
        return e;
    }

    fn parseArgs(self: *Parser) ParseError![]*Node {
        try self.expect(.lparen);
        const saved_no_in = self.no_in; // arguments are `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var args: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            try args.append(self.arena, try self.parseSpreadable());
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return args.items;
    }

    /// An array element or call argument, which may be a `...spread`.
    fn parseSpreadable(self: *Parser) ParseError!*Node {
        if (self.match(.ellipsis)) return self.alloc(.{ .spread = try self.parseAssignment() });
        return self.parseAssignment();
    }

    /// `new Callee(args)` — the callee is a member expression *without* a call
    /// (the first `(...)` is the constructor's argument list). Any trailing
    /// `.prop` / call chain is handled by the enclosing `parseMemberTail`.
    fn parseNew(self: *Parser) ParseError!*Node {
        _ = self.advance(); // new
        if (self.in_async and isKeyword(self.cur(), "await")) return ParseError.UnexpectedToken;
        // `new.target` meta-property.
        if (self.match(.dot)) {
            const m = self.advance();
            // `target` is a contextual keyword here — it may not be escaped
            // (`new.target` is a SyntaxError).
            if (m.kind != .identifier or m.escaped_identifier or !std.mem.eql(u8, m.text, "target")) return ParseError.UnexpectedToken;
            if (self.new_target_depth == 0) return ParseError.UnexpectedToken;
            return self.alloc(.new_target_expr);
        }
        const parenthesized_callee = self.check(.lparen);
        var callee = if (parenthesized_callee) blk: {
            _ = self.advance();
            const expr = try self.parseExpression();
            try self.expect(.rparen);
            break :blk expr;
        } else try self.parsePrimary();
        // `new import(...)` is a SyntaxError: an ImportCall is a CallExpression,
        // not a valid MemberExpression operand for `new`. A parenthesized
        // ImportCall is a CoverParenthesizedExpression PrimaryExpression and is
        // therefore valid syntax (`new (import(x))`), failing later at runtime.
        // (`import.meta` parses to `.import_meta`, so `new import.meta.x()` is
        // unaffected.)
        if (!parenthesized_callee and callee.* == .import_call) return ParseError.UnexpectedToken;
        while (true) {
            if (self.match(.dot)) {
                const name = self.advance();
                if (name.kind != .identifier) return ParseError.UnexpectedToken;
                callee = try self.alloc(.{ .member = .{ .object = callee, .property = name.text } });
            } else if (self.match(.lbracket)) {
                const idx = try self.parseExpression();
                try self.expect(.rbracket);
                callee = try self.alloc(.{ .member = .{ .object = callee, .computed = idx } });
            } else if (self.check(.template)) {
                // `new tag`tmpl`` parses as `new (tag`tmpl`)`: a tagged template is a
                // MemberExpression, so it binds to the `new` operand (the tag call
                // happens first, then `new` constructs its result).
                const tmpl = self.advance();
                callee = try self.parseTaggedTemplate(callee, tmpl.text);
            } else break;
        }
        const args: []*Node = if (self.check(.lparen)) try self.parseArgs() else &.{};
        return self.alloc(.{ .new_expr = .{ .callee = callee, .args = args } });
    }

    /// Desugar a template literal's raw inner text into string concatenation:
    /// `` `a${x}b` `` becomes `("a" + x) + "b"`. The leading string makes the
    /// whole chain string-typed, so JS `+` applies ToString to each expression —
    /// exactly untagged-template semantics. Works on the tree-walker and the VM
    /// for free (it's just `add` nodes).
    /// Normalize template line terminators (the TRV rules): `<CR><LF>` and a
    /// lone `<CR>` both become a single `<LF>`. `<LS>`/`<PS>` are left as-is.
    fn normalizeTemplateRaw(arena: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\r') == null) return raw;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\r') {
                try out.append(arena, '\n');
                if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1; // CRLF → one LF
            } else try out.append(arena, raw[i]);
        }
        return out.items;
    }

    fn parseTemplate(self: *Parser, raw_in: []const u8) ParseError!*Node {
        const raw = try normalizeTemplateRaw(self.arena, raw_in);
        var node: ?*Node = null;
        var lit: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                try validateTemplateEscape(raw, i + 1);
                i = try lex.appendEscape(self.arena, &lit, raw, i + 1);
            } else if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                // Flush the literal run so far, then parse the substitution.
                node = try self.concatStr(node, lit.items);
                lit = .empty;
                const expr_start = i + 2;
                const expr_end = substEnd(raw, expr_start);
                var sub = try Parser.init(self.arena, raw[expr_start..expr_end]);
                // A `${ }` substitution inherits the enclosing parsing context, so
                // `yield`/`await`/`#x`/strict-mode keywords are recognized inside a
                // template in a generator/async/class/strict/module body.
                sub.in_generator = self.in_generator;
                sub.in_async = self.in_async;
                sub.in_class = self.in_class;
                sub.strict = self.strict;
                sub.module = self.module;
                sub.eval_private_allowed = self.eval_private_allowed;
                node = try self.concatExpr(node, try sub.parseExpression());
                i = if (expr_end < raw.len) expr_end + 1 else expr_end; // skip `}`
            } else {
                try lit.append(self.arena, c);
                i += 1;
            }
        }
        return self.concatStr(node, lit.items);
    }

    /// Split a template's raw inner text into the cooked quasis (escapes
    /// decoded), the raw quasis (text verbatim), and the substitution
    /// expressions, then build a `tagged_template` node. There is always one
    /// more quasi than substitution.
    fn parseTaggedTemplate(self: *Parser, tag: *Node, raw_in: []const u8) ParseError!*Node {
        const raw = try normalizeTemplateRaw(self.arena, raw_in);
        var cooked: std.ArrayListUnmanaged(?[]const u8) = .empty;
        var raws: std.ArrayListUnmanaged([]const u8) = .empty;
        var exprs: std.ArrayListUnmanaged(*Node) = .empty;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        // A quasi that holds an invalid escape has an `undefined` cooked value
        // (tolerated in a tagged template); track that per quasi and flush null.
        var span_invalid = false;
        var raw_start: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                validateTemplateEscape(raw, i + 1) catch {
                    span_invalid = true;
                };
                i = try lex.appendEscape(self.arena, &buf, raw, i + 1);
            } else if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                try cooked.append(self.arena, if (span_invalid) null else try buf.toOwnedSlice(self.arena));
                try raws.append(self.arena, raw[raw_start..i]);
                buf = .empty;
                span_invalid = false;
                const expr_start = i + 2;
                const expr_end = substEnd(raw, expr_start);
                var sub = try Parser.init(self.arena, raw[expr_start..expr_end]);
                // A `${ }` substitution inherits the enclosing parsing context, so
                // `yield`/`await`/`#x`/strict-mode keywords are recognized inside a
                // template in a generator/async/class/strict/module body.
                sub.in_generator = self.in_generator;
                sub.in_async = self.in_async;
                sub.in_class = self.in_class;
                sub.strict = self.strict;
                sub.module = self.module;
                sub.eval_private_allowed = self.eval_private_allowed;
                try exprs.append(self.arena, try sub.parseExpression());
                i = if (expr_end < raw.len) expr_end + 1 else expr_end; // skip `}`
                raw_start = i;
            } else {
                try buf.append(self.arena, c);
                i += 1;
            }
        }
        try cooked.append(self.arena, if (span_invalid) null else try buf.toOwnedSlice(self.arena));
        try raws.append(self.arena, raw[raw_start..]);
        return self.alloc(.{ .tagged_template = .{ .tag = tag, .cooked = cooked.items, .raw = raws.items, .exprs = exprs.items } });
    }

    fn validateTemplateEscape(raw: []const u8, i: usize) ParseError!void {
        if (lex.lineTerminatorLen(raw, i) != null) return;
        if (i >= raw.len) return ParseError.UnexpectedToken;
        switch (raw[i]) {
            'x' => {
                if (i + 2 >= raw.len or templateHexVal(raw[i + 1]) == null or templateHexVal(raw[i + 2]) == null)
                    return ParseError.UnexpectedToken;
            },
            'u' => {
                if (i + 1 < raw.len and raw[i + 1] == '{') {
                    var j = i + 2;
                    var cp: u32 = 0;
                    var any = false;
                    while (j < raw.len and raw[j] != '}') : (j += 1) {
                        const h = templateHexVal(raw[j]) orelse return ParseError.UnexpectedToken;
                        cp = cp * 16 + h;
                        if (cp > 0x10FFFF) return ParseError.UnexpectedToken;
                        any = true;
                    }
                    if (!any or j >= raw.len or raw[j] != '}') return ParseError.UnexpectedToken;
                } else {
                    if (i + 4 >= raw.len) return ParseError.UnexpectedToken;
                    for (raw[i + 1 .. i + 5]) |c| if (templateHexVal(c) == null) return ParseError.UnexpectedToken;
                }
            },
            '0' => if (i + 1 < raw.len and std.ascii.isDigit(raw[i + 1])) return ParseError.UnexpectedToken,
            '1'...'9' => return ParseError.UnexpectedToken,
            else => {},
        }
    }

    fn templateHexVal(c: u8) ?u32 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn concatStr(self: *Parser, node: ?*Node, bytes: []const u8) ParseError!*Node {
        const s = try self.alloc(.{ .string = try self.arena.dupe(u8, bytes) });
        if (node) |n| return self.alloc(.{ .binary = .{ .op = .add, .left = n, .right = s } });
        return s;
    }

    fn concatExpr(self: *Parser, node: ?*Node, expr: *Node) ParseError!*Node {
        // A template substitution is ToString'd (string hint), not coerced via
        // `+` (default hint) — so `${ {valueOf,toString} }` uses toString.
        const coerced = try self.alloc(.{ .unary = .{ .op = .to_string, .operand = expr } });
        if (node) |n| return self.alloc(.{ .binary = .{ .op = .add, .left = n, .right = coerced } });
        return coerced;
    }

    /// A SuperCall (`super()`) is only legal in a derived class constructor, so
    /// one inside an object-literal method (concise method, getter, or setter) —
    /// in its body or a parameter default — is an early SyntaxError. A
    /// SuperProperty (`super.x`) and an `arguments` reference remain legal in a
    /// method, so only `super()` is rejected. Non-method property values
    /// (`{ m: function(){} }`, shorthands, spreads) have their own bindings and
    /// are not scanned.
    fn checkMethodNoSuperCall(self: *Parser, value: *Node) ParseError!void {
        if (value.* != .function or !value.function.is_method) return;
        const f = value.function;
        const saved_args = self.scan_allow_arguments;
        const saved_prop = self.scan_forbid_super_property;
        self.scan_allow_arguments = true; // `arguments` is legal in a method body
        self.scan_forbid_super_property = false; // `super.x` is legal in a method
        defer {
            self.scan_allow_arguments = saved_args;
            self.scan_forbid_super_property = saved_prop;
        }
        try self.scanSuperAndArgs(f.body);
        for (f.params) |p| if (p.default) |d| try self.scanSuperAndArgs(d);
    }

    fn parseObjectLiteral(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        const saved_no_in = self.no_in; // object property values are `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var has_cover_init = false;
        var proto_colon_count: u32 = 0;
        var props: std.ArrayListUnmanaged(ast.Property) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            // Spread property `{ ...expr }`.
            if (self.match(.ellipsis)) {
                const e = try self.parseAssignment();
                try props.append(self.arena, .{ .value = e, .is_spread = true });
                if (!self.match(.comma)) break;
                continue;
            }
            // The first token of this member, so a method/accessor can capture its
            // exact source span for `Function.prototype.toString`.
            const member_start = self.pos;
            // Async method shorthand `{ async m() {} }` / `{ async *m() {} }`.
            const async_method = self.asyncMethodAhead();
            if (async_method) _ = self.advance(); // async
            // Generator method shorthand `{ *m() {} }` / `{ *[expr]() {} }`.
            const gen_method = self.match(.star);
            // Computed key: `{ [expr]: v }`.
            if (self.match(.lbracket)) {
                const key_expr = try self.parseAssignment();
                try self.expect(.rbracket);
                if (self.check(.lparen)) {
                    const fnode = try self.parseMethodTail("", gen_method, async_method, member_start);
                    try props.append(self.arena, .{ .key_expr = key_expr, .value = fnode });
                } else {
                    try self.expect(.colon);
                    try props.append(self.arena, .{ .key_expr = key_expr, .value = try self.parseAssignment() });
                }
                if (!self.match(.comma)) break;
                continue;
            }
            // Accessor: `get x() {}` / `set x(v) {}` (get/set followed by a key).
            // An escaped `get`/`set` (`get`) is never the contextual keyword.
            if (!async_method and !gen_method and !self.cur().escaped_identifier and (isKeyword(self.cur(), "get") or isKeyword(self.cur(), "set")) and self.propNameAhead()) {
                const kind: ast.AccessorKind = if (isKeyword(self.cur(), "get")) .get else .set;
                _ = self.advance(); // get/set
                const pn = try self.parsePropertyName();
                // A private name (`#x`) is only a valid member name in a class
                // body, never in an object literal accessor (`({ get #x(){} })`).
                if (pn.key.len > 0 and pn.key[0] == '#') return ParseError.UnexpectedToken;
                const func = try self.parseMethodTail(pn.key, false, false, member_start);
                try validateAccessor(func, kind);
                try props.append(self.arena, .{ .key = pn.key, .key_expr = pn.expr, .value = func, .accessor = kind });
                if (!self.match(.comma)) break;
                continue;
            }
            const key_tok = self.advance();
            const key: []const u8 = switch (key_tok.kind) {
                .identifier, .string => key_tok.text,
                // A BigInt literal key (`1n`) is ToString'd from its exact value,
                // not the lossy f64.
                .number => if (key_tok.is_bigint)
                    (key_tok.bigint_text orelse try std.fmt.allocPrint(self.arena, "{d}", .{key_tok.bigint}))
                else
                    // A numeric LiteralPropertyName is ToString'd via Number::toString
                    // (so `0.0000001` keys as "1e-7", `1.0` as "1"), not Zig's `{d}`.
                    try value_mod.numberToString(self.arena, key_tok.number),
                else => return ParseError.UnexpectedToken,
            };
            var val: *Node = undefined;
            var is_proto_colon = false;
            if (self.check(.lparen)) {
                // Method shorthand `{ m(args) { ... } }` -> a function value.
                val = try self.parseMethodTail(key, gen_method, async_method, member_start);
            } else if (gen_method or async_method) {
                // A `*`/`async` modifier must introduce a method (a `(params){…}`
                // must follow the name): `({ *foo })`, `({ async async })` are
                // SyntaxErrors, not a property/shorthand named `foo`/`async`.
                return ParseError.UnexpectedToken;
            } else if (self.match(.colon)) {
                // `__proto__: value` (identifier or string key, not computed) is a
                // prototype setter; two of them in one literal is an early error.
                if (std.mem.eql(u8, key, "__proto__")) {
                    proto_colon_count += 1;
                    is_proto_colon = true;
                }
                val = try self.parseAssignment();
                // The proto-setter form does NOT NamedEvaluate its value
                // (`{__proto__: function(){}}` leaves the function unnamed).
                if (!is_proto_colon) nameAnon(val, key); // `{ m: function(){} }` ⇒ name "m"
            } else if (key_tok.kind == .identifier) {
                if (isAlwaysReservedBinding(key) or (self.strict and isStrictReservedBinding(key)))
                    return ParseError.UnexpectedToken;
                // A `{ yield }`/`{ await }` shorthand is an identifier reference/
                // binding, so `yield` is forbidden in a generator and `await` in
                // an async function/module/static block.
                if (self.in_generator and std.mem.eql(u8, key, "yield")) return ParseError.UnexpectedToken;
                if ((self.in_async or self.module) and std.mem.eql(u8, key, "await")) return ParseError.UnexpectedToken;
                const ident = try self.alloc(.{ .identifier = key });
                // Shorthand `{ a }`, or `{ a = default }` (a destructuring
                // default surfaced via the cover grammar).
                if (self.match(.assign)) {
                    // `{ a = default }` — a CoverInitializedName, valid only if
                    // this object is refined to an assignment pattern.
                    has_cover_init = true;
                    val = try self.alloc(.{ .assign = .{ .target = ident, .value = try self.parseAssignment() } });
                } else {
                    val = ident;
                }
            } else return ParseError.ExpectedToken;
            try props.append(self.arena, .{ .key = key, .value = val, .proto_setter = is_proto_colon });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        for (props.items) |p| try self.checkMethodNoSuperCall(p.value);
        const node = try self.alloc(.{ .object_lit = props.items });
        if (has_cover_init) try self.pending_cover_inits.put(self.arena, node, {});
        if (proto_colon_count >= 2) try self.pending_proto_dup.put(self.arena, node, {});
        return node;
    }

    /// `super(args)` or `super.prop` / `super[expr]`. (`super.m(args)` is a
    /// super_member that the enclosing member-tail turns into a call.)
    fn parseSuper(self: *Parser) ParseError!*Node {
        _ = self.advance(); // super
        if (self.check(.lparen)) {
            const args = try self.parseArgs();
            return self.alloc(.{ .super_call = args });
        }
        if (self.match(.dot)) {
            const name = self.advance();
            if (name.kind != .identifier) return ParseError.UnexpectedToken;
            return self.alloc(.{ .super_member = .{ .property = name.text } });
        }
        if (self.match(.lbracket)) {
            const idx = try self.parseExpression();
            try self.expect(.rbracket);
            return self.alloc(.{ .super_member = .{ .computed = idx } });
        }
        return ParseError.UnexpectedToken;
    }

    /// `import(specifier ,opt)` / `import(specifier, options ,opt)` (dynamic
    /// import) or `import.meta`. The `import` keyword has already been peeked but
    /// not consumed.
    fn parseImportExpr(self: *Parser) ParseError!*Node {
        _ = self.advance(); // `import`
        // `import(spec, options)` arguments are `[+In]` (the `( … )` resets it).
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var phase: []const u8 = "";
        if (self.match(.dot)) {
            const m = self.advance();
            if (m.kind != .identifier) return ParseError.UnexpectedToken;
            // `import.meta` — meta-property. `import.source(x)` / `import.defer(x)`
            // — the source-phase-import / import-defer proposals; parse them as a
            // phased dynamic import (the phase doesn't change the AST here).
            // `import.meta` is only valid in Module code (a Script — including
            // eval, which is always Script goal — is a SyntaxError), and `meta`
            // may not be spelled with a Unicode escape.
            if (std.mem.eql(u8, m.text, "meta")) {
                if (!self.module or m.escaped_identifier) return ParseError.UnexpectedToken;
                return self.alloc(.import_meta);
            }
            if (std.mem.eql(u8, m.text, "source") or std.mem.eql(u8, m.text, "defer")) {
                phase = m.text; // phased dynamic import; fall through to the call form
            } else return ParseError.UnexpectedToken;
        }
        try self.expect(.lparen);
        // ImportCall requires exactly one AssignmentExpression specifier (no
        // empty `import()`, no leading spread), plus an optional second options
        // argument, plus an optional trailing comma.
        if (self.check(.rparen) or self.check(.ellipsis)) return ParseError.UnexpectedToken;
        const spec = try self.parseAssignment();
        var options: ?*Node = null;
        if (self.match(.comma)) {
            if (!self.check(.rparen)) {
                if (self.check(.ellipsis)) return ParseError.UnexpectedToken;
                options = try self.parseAssignment();
                _ = self.match(.comma); // optional trailing comma after 2nd arg
            }
        }
        try self.expect(.rparen);
        return self.alloc(.{ .import_call = .{ .specifier = spec, .options = options, .phase = phase } });
    }

    /// True when the next token starts a property name — used to tell an
    /// accessor (`get x`) from a method/property literally named `get`.
    fn propNameAhead(self: *Parser) bool {
        return switch (self.peekKind(1)) {
            // `private_name` lets `get #x()`/`set #x()` parse as accessors rather
            // than a method literally named `get`/`set`.
            .identifier, .string, .number, .lbracket, .private_name => true,
            else => false,
        };
    }

    /// Parse a property/method name: identifier/string/number, or a computed
    /// `[expr]`. Returns the static key (or "" if computed) and the computed expr.
    fn parsePropertyName(self: *Parser) ParseError!struct { key: []const u8, expr: ?*Node } {
        if (self.match(.lbracket)) {
            const e = try self.parseAssignment();
            try self.expect(.rbracket);
            return .{ .key = "", .expr = e };
        }
        const t = self.advance();
        const key: []const u8 = switch (t.kind) {
            .identifier, .string, .private_name => t.text,
            // A BigInt literal key (`1n`) is ToString'd from its exact value.
            .number => if (t.is_bigint)
                (t.bigint_text orelse try std.fmt.allocPrint(self.arena, "{d}", .{t.bigint}))
            else
                // ToString'd via Number::toString (`0.0000001` → "1e-7"), not `{d}`.
                try value_mod.numberToString(self.arena, t.number),
            else => return ParseError.UnexpectedToken,
        };
        return .{ .key = key, .expr = null };
    }

    /// `class [Name] { members }`. v1: constructor, instance methods, static
    /// methods, computed method names. `extends`/`super`/accessors are deferred
    /// (return a parse error, so such tests simply stay unparsed for now).
    /// Parse a leading decorator list `@dec @ns.x @call(args) @(expr)` and discard
    /// it (the syntax is accepted; decorator application is not implemented).
    fn parseDecorators(self: *Parser) ParseError!void {
        while (self.check(.at)) {
            _ = self.advance(); // @
            if (self.match(.lparen)) {
                _ = try self.parseExpression();
                try self.expect(.rparen);
            } else {
                if (!self.check(.identifier) and !self.check(.private_name)) return ParseError.UnexpectedToken;
                _ = self.advance(); // IdentifierReference
                while (self.check(.dot)) {
                    _ = self.advance();
                    if (!self.check(.identifier) and !self.check(.private_name)) return ParseError.UnexpectedToken;
                    _ = self.advance();
                }
                if (self.check(.lparen)) _ = try self.parseArgs(); // DecoratorCallExpression
            }
        }
    }

    fn parseClassExpr(self: *Parser) ParseError!*Node {
        const start = self.pos;
        _ = self.advance(); // class
        // A class body (computed names, field initializers, method bodies) is
        // `[+In]`, even when the class expression appears in a for-init's `[~In]`.
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        // All parts of a class — its name, heritage, and body — are strict mode
        // code, so `class C extends (function(){ with({}); })() {}` is a
        // SyntaxError (a `with` in the heritage). Set strict before parsing them.
        const saved_strict = self.strict;
        self.strict = true;
        defer self.strict = saved_strict;
        var name: []const u8 = "";
        if (self.check(.identifier) and !isKeyword(self.cur(), "extends")) {
            // A class's BindingIdentifier is strict-mode code (`class let {}`,
            // `class yield {}`, `class await {}` in a module, … are SyntaxErrors);
            // `self.strict` is already forced true above.
            if (self.isForbiddenBindingName(self.cur().text)) return ParseError.UnexpectedToken;
            name = self.advance().text;
        }
        var superclass: ?*Node = null;
        if (isKeyword(self.cur(), "extends")) {
            _ = self.advance();
            // Superclass is a LeftHandSide expression (allow member/call chains).
            superclass = try self.parseUnary();
        }
        try self.expect(.lbrace);
        const saved_in_class = self.in_class;
        self.in_class = true;
        defer self.in_class = saved_in_class;
        var members: std.ArrayListUnmanaged(ast.ClassMember) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.semicolon)) continue; // stray semicolons allowed
            // A class element may carry a leading decorator list (parsed and
            // discarded; decorators precede `static`).
            if (self.check(.at)) try self.parseDecorators();
            var is_static = false;
            // An escaped `static` (`static`) is never the contextual keyword.
            if (isKeyword(self.cur(), "static") and !self.cur().escaped_identifier and self.peekKind(1) != .semicolon and self.peekKind(1) != .lparen and self.peekKind(1) != .assign) {
                is_static = true;
                _ = self.advance();
            }
            // `static { ... }` initialization block. It is its own scope with
            // `new.target` but no `yield`/`return`/`arguments`, and a SuperCall is
            // forbidden (SuperProperty is allowed). The body is [+Await], so
            // `await` is reserved (no `let await`, `class await {}`, `await;`) and
            // an AwaitExpression is the ContainsAwait early error.
            if (is_static and self.check(.lbrace)) {
                const saved_async = self.in_async;
                const saved_gen = self.in_generator;
                const saved_fn = self.fn_depth;
                const saved_iter = self.iter_depth;
                const saved_switch = self.switch_depth;
                const saved_active = self.active_labels.items.len;
                const saved_pending = self.pending_labels.items.len;
                const saved_continue = self.continue_labels.items.len;
                self.in_async = true; // [+Await]: `await` reserved in a static block
                self.in_generator = false;
                self.fn_depth = 0; // `return` is a SyntaxError in a static block
                // A static block is a fresh control-flow boundary: `break`/
                // `continue` may not target a loop/switch/label outside it.
                self.iter_depth = 0;
                self.switch_depth = 0;
                self.active_labels.items.len = 0;
                self.pending_labels.items.len = 0;
                self.continue_labels.items.len = 0;
                self.new_target_depth += 1;
                defer {
                    self.in_async = saved_async;
                    self.in_generator = saved_gen;
                    self.fn_depth = saved_fn;
                    self.iter_depth = saved_iter;
                    self.switch_depth = saved_switch;
                    self.active_labels.items.len = saved_active;
                    self.pending_labels.items.len = saved_pending;
                    self.continue_labels.items.len = saved_continue;
                    self.new_target_depth -= 1;
                }
                const block = try self.parseBlock();
                // No super()/arguments, and no AwaitExpression (ContainsAwait).
                const saved_fa = self.scan_forbid_await;
                const saved_class_scan = self.scan_descend_class_expr;
                self.scan_forbid_await = true;
                self.scan_descend_class_expr = true;
                defer {
                    self.scan_forbid_await = saved_fa;
                    self.scan_descend_class_expr = saved_class_scan;
                }
                for (block.block) |s| try self.scanSuperAndArgs(s);
                try self.checkLexicalDupes(block.block, true); // own lexical scope
                try members.append(self.arena, .{ .is_static = true, .static_block = block });
                continue;
            }
            // The method's source span for `Function.prototype.toString` starts at
            // its name/`get`/`set`/`async`/`*` — *after* any `static` (which is part
            // of the ClassElement, not the MethodDefinition's [[SourceText]]).
            const member_start = self.pos;
            // Async method: `async m() {}` / `static async m() {}` / `async *m() {}`.
            const async_method = self.asyncMethodAhead();
            if (async_method) _ = self.advance(); // async
            // Generator method: `*m() {}` / `static *m() {}` / `async *m() {}`.
            const gen_method = self.match(.star);
            // Accessor: `get x() {}` / `set x(v) {}`. An escaped `get`/`set`
            // (`get`) is never the contextual keyword.
            if (!async_method and !gen_method and !self.cur().escaped_identifier and (isKeyword(self.cur(), "get") or isKeyword(self.cur(), "set")) and self.propNameAhead()) {
                const kind: ast.AccessorKind = if (isKeyword(self.cur(), "get")) .get else .set;
                _ = self.advance(); // get/set
                const apn = try self.parsePropertyName();
                const func = try self.parseMethodTail(apn.key, false, false, member_start);
                try validateAccessor(func, kind);
                try members.append(self.arena, .{ .key = apn.key, .key_expr = apn.expr, .func = func, .is_static = is_static, .accessor = kind });
                continue;
            }
            // `accessor x` auto-accessor field (decorators proposal). `accessor`
            // is a contextual keyword only when an unescaped `accessor` is
            // followed, with no LineTerminator, by a property name — otherwise it
            // is itself the element name (`accessor;`, `accessor = 1`,
            // `accessor(){}`). Accepted and parsed as a field.
            const saw_auto_accessor = !async_method and !gen_method and isKeyword(self.cur(), "accessor") and
                !self.cur().escaped_identifier and self.noNewlineBefore(1) and self.propNameAhead();
            if (saw_auto_accessor) {
                _ = self.advance(); // accessor
            }
            const pn = try self.parsePropertyName();
            if (self.check(.lparen)) {
                // Method.
                const func = try self.parseMethodTail(pn.key, gen_method, async_method, member_start);
                const is_ctor = !is_static and !gen_method and !async_method and pn.expr == null and std.mem.eql(u8, pn.key, "constructor");
                try members.append(self.arena, .{ .key = pn.key, .key_expr = pn.expr, .func = func, .is_static = is_static, .is_ctor = is_ctor });
            } else {
                // Field: `x;` or `x = init;`.
                const init_expr = if (self.match(.assign)) try self.parseAssignment() else null;
                // A FieldDefinition must be terminated by `;`, the closing `}`, or
                // ASI (a LineTerminator before the next element): `class C { x y }`
                // and `class C { #x #y }` are SyntaxErrors.
                if (!self.match(.semicolon) and !self.check(.rbrace) and self.noNewlineBefore(0))
                    return ParseError.UnexpectedToken;
                // Early error (15.7.1): a field Initializer may not contain a
                // SuperCall or an `arguments` reference.
                if (init_expr) |ie| {
                    const saved_class_scan = self.scan_descend_class_expr;
                    self.scan_descend_class_expr = true;
                    defer self.scan_descend_class_expr = saved_class_scan;
                    try self.scanSuperAndArgs(ie);
                }
                try members.append(self.arena, .{
                    .key = pn.key,
                    .key_expr = pn.expr,
                    .field_init = init_expr,
                    .is_static = is_static,
                    .is_field = true,
                    .is_auto_accessor = saw_auto_accessor and !(pn.expr == null and pn.key.len > 0 and pn.key[0] == '#'),
                });
            }
        }
        try self.expect(.rbrace);
        try self.checkPrivateNames(members.items);
        try self.checkClassMemberErrors(members.items, superclass != null);
        return self.alloc(.{ .class_expr = .{ .name = name, .superclass = superclass, .members = members.items, .source = self.sourceFrom(start) } });
    }

    /// Class element early errors (15.7.1) beyond private-name uniqueness:
    ///   - a SuperCall (`super()`) is allowed only in a derived class's
    ///     constructor; any other method/accessor/non-derived constructor body
    ///     containing one is a SyntaxError;
    ///   - a static element named `prototype` (non-computed, non-private) is a
    ///     SyntaxError;
    ///   - a `constructor` element that is an accessor, generator, or async
    ///     method is a SyntaxError (the constructor must be a plain method).
    fn checkClassMemberErrors(self: *Parser, members: []const ast.ClassMember, has_superclass: bool) ParseError!void {
        // A class may define at most one constructor.
        var ctor_count: usize = 0;
        for (members) |m| if (m.is_ctor) {
            ctor_count += 1;
        };
        if (ctor_count > 1) return ParseError.UnexpectedToken;
        for (members) |m| {
            const named = m.key_expr == null and m.key.len > 0;
            const not_private = named and m.key[0] != '#';
            if (m.is_static and not_private and std.mem.eql(u8, m.key, "prototype"))
                return ParseError.UnexpectedToken;
            // A field — instance or static — may not be named `constructor`
            // (15.7.1). A non-computed, non-private `constructor` field, however
            // its name is spelled (identifier or string literal), is an error.
            if (m.is_field and not_private and std.mem.eql(u8, m.key, "constructor"))
                return ParseError.UnexpectedToken;
            if (m.is_field) continue;
            const mf = m.func orelse continue;
            if (mf.* != .function) continue;
            const fnode = mf.function;
            if (!m.is_static and not_private and std.mem.eql(u8, m.key, "constructor") and
                (m.accessor != .none or fnode.is_generator or fnode.is_async))
                return ParseError.UnexpectedToken;
            // SuperCall is permitted only in the derived constructor.
            const is_derived_ctor = m.is_ctor and has_superclass;
            if (!is_derived_ctor) {
                const saved = self.scan_allow_arguments;
                self.scan_allow_arguments = true; // `arguments` is legal in a method body
                defer self.scan_allow_arguments = saved;
                try self.scanSuperAndArgs(fnode.body);
                for (fnode.params) |p| {
                    if (p.default) |d| try self.scanSuperAndArgs(d);
                }
            }
        }
    }

    /// Early error: a class may not declare the same private name twice, except
    /// for a single `get`/`set` pair at the same placement (both static or both
    /// instance). Any other repeat — get/get, set/set, method/method,
    /// field/anything, or a get+set split across static and instance — is a
    /// SyntaxError.
    fn checkPrivateNames(self: *Parser, members: []const ast.ClassMember) ParseError!void {
        for (members, 0..) |m, i| {
            if (m.key_expr != null or m.key.len == 0 or m.key[0] != '#') continue;
            // A private name may not be `#constructor` (in any element form).
            if (std.mem.eql(u8, m.key, "#constructor")) return ParseError.UnexpectedToken;
            for (members[0..i]) |prev| {
                if (prev.key_expr != null or !std.mem.eql(u8, prev.key, m.key)) continue;
                // A complementary get/set pair at the same placement is the only
                // allowed repeat.
                const pair = ((m.accessor == .get and prev.accessor == .set) or
                    (m.accessor == .set and prev.accessor == .get)) and
                    m.is_static == prev.is_static and !m.is_field and !prev.is_field;
                if (!pair) return ParseError.UnexpectedToken;
            }
        }
        _ = self;
    }

    /// Whether the (eval) program's top-level declarations bind the name
    /// `arguments` — a `var` (hoisted out of nested blocks/control-flow, but not
    /// functions) or a top-level lexical / function / class declaration. Used to
    /// reject a direct eval that declares `arguments` inside a non-arrow
    /// function's parameter expression scope (an early error).
    pub fn evalDeclaresArguments(self: *Parser, stmts: []const *Node) ParseError!bool {
        var vars: std.StringHashMapUnmanaged(void) = .empty;
        for (stmts) |s| try self.collectVarNames(s, &vars);
        if (vars.contains("arguments")) return true;
        // Top-level lexical / function / class named `arguments`.
        for (stmts) |s| switch (s.*) {
            .var_decl => |d| if (d.kind != .@"var" and std.mem.eql(u8, d.name, "arguments")) return true,
            .destructure_decl => |d| if (d.kind != .@"var") {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |n| if (std.mem.eql(u8, n, "arguments")) return true;
            },
            .decl_group => |g| for (g) |d2| {
                if (d2.* == .var_decl and d2.var_decl.kind != .@"var" and std.mem.eql(u8, d2.var_decl.name, "arguments")) return true;
            },
            .func_decl => |f| if (std.mem.eql(u8, f.name, "arguments")) return true,
            .class_expr => |c| if (std.mem.eql(u8, c.name, "arguments")) return true,
            else => {},
        };
        return false;
    }

    /// Validate eval'd code against the syntactic restrictions it inherits:
    /// every top-level statement is scanned for a SuperCall (always forbidden in
    /// these eval contexts), plus an `arguments` reference (when
    /// `!allow_arguments`, e.g. a direct eval inside a class field initializer)
    /// and/or a SuperProperty (when `forbid_super_property`, e.g. an indirect
    /// eval, which is global code). Recurses into arrow bodies but stops at
    /// ordinary functions/classes, matching the static `Contains` semantics.
    /// Returns error.UnexpectedToken on a violation (the caller maps it to a
    /// SyntaxError *before* any of the eval'd code runs).
    pub fn scanEvalContext(self: *Parser, stmts: []const *Node, allow_arguments: bool, forbid_super_property: bool) ParseError!void {
        self.scan_allow_arguments = allow_arguments;
        self.scan_forbid_super_property = forbid_super_property;
        self.scan_descend_class_expr = !allow_arguments and !forbid_super_property;
        defer {
            self.scan_allow_arguments = false;
            self.scan_forbid_super_property = false;
            self.scan_descend_class_expr = false;
        }
        for (stmts) |s| try self.scanSuperAndArgs(s);
    }

    /// Scan an expression/statement subtree for a SuperCall (`super()`), and —
    /// unless `scan_allow_arguments` is set — an `arguments` reference. Used for
    /// two early errors: a class field Initializer may contain neither (15.7.1),
    /// and a method body other than a derived constructor may not contain a
    /// SuperCall. Conservative — recurses through operators and *arrow* bodies
    /// (which bind neither) but stops at ordinary functions/classes (which have
    /// their own bindings), so it never rejects valid code.
    fn scanSuperAndArgs(self: *Parser, node: *Node) ParseError!void {
        switch (node.*) {
            .identifier => |name| if (!self.scan_allow_arguments and std.mem.eql(u8, name, "arguments")) return ParseError.UnexpectedToken,
            .super_call => return ParseError.UnexpectedToken,
            .unary => |u| try self.scanSuperAndArgs(u.operand),
            .delete_expr => |t| try self.scanSuperAndArgs(t),
            .update => |u| try self.scanSuperAndArgs(u.target),
            .await_expr => |a| {
                if (self.scan_forbid_await) return ParseError.UnexpectedToken;
                try self.scanSuperAndArgs(a.argument);
            },
            .yield_expr => |y| {
                if (self.scan_forbid_yield) return ParseError.UnexpectedToken;
                if (y.argument) |arg| try self.scanSuperAndArgs(arg);
            },
            .spread => |v| try self.scanSuperAndArgs(v),
            .optional_chain => |c| try self.scanSuperAndArgs(c),
            .binary => |b| {
                try self.scanSuperAndArgs(b.left);
                try self.scanSuperAndArgs(b.right);
            },
            .logical => |l| {
                try self.scanSuperAndArgs(l.left);
                try self.scanSuperAndArgs(l.right);
            },
            .sequence => |s| {
                try self.scanSuperAndArgs(s.first);
                try self.scanSuperAndArgs(s.second);
            },
            .assign => |a| {
                try self.scanSuperAndArgs(a.target);
                try self.scanSuperAndArgs(a.value);
            },
            .op_assign => |a| {
                try self.scanSuperAndArgs(a.target);
                try self.scanSuperAndArgs(a.value);
            },
            .conditional => |c| {
                try self.scanSuperAndArgs(c.cond);
                try self.scanSuperAndArgs(c.consequent);
                try self.scanSuperAndArgs(c.alternate);
            },
            .super_member => |m| {
                if (self.scan_forbid_super_property) return ParseError.UnexpectedToken;
                if (m.computed) |computed| try self.scanSuperAndArgs(computed);
            },
            .call => |c| {
                try self.scanSuperAndArgs(c.callee);
                for (c.args) |arg| try self.scanSuperAndArgs(arg);
            },
            .new_expr => |n| {
                try self.scanSuperAndArgs(n.callee);
                for (n.args) |arg| try self.scanSuperAndArgs(arg);
            },
            .tagged_template => |t| {
                try self.scanSuperAndArgs(t.tag);
                for (t.exprs) |expr| try self.scanSuperAndArgs(expr);
            },
            .member => |m| {
                try self.scanSuperAndArgs(m.object);
                if (m.computed) |computed| try self.scanSuperAndArgs(computed);
            },
            .object_lit => |props| for (props) |prop| {
                if (prop.key_expr) |key_expr| try self.scanSuperAndArgs(key_expr);
                try self.scanSuperAndArgs(prop.value);
            },
            .array_lit => |items| for (items) |item| try self.scanSuperAndArgs(item),
            // Arrow functions do NOT bind their own `arguments`/`super`, so a
            // `super()`/`arguments` inside one is still the field's — recurse into
            // arrow params' defaults and body. Ordinary functions/classes have
            // their own bindings and are not descended into.
            .function => |f| if (f.is_arrow) {
                for (f.params) |p| if (p.default) |d| try self.scanSuperAndArgs(d);
                if (self.scan_forbid_await or self.scan_forbid_yield) return;
                try self.scanSuperAndArgs(f.body);
            },
            .class_expr => |c| if (self.scan_descend_class_expr) {
                if (c.superclass) |sc| try self.scanSuperAndArgs(sc);
                for (c.members) |m| {
                    if (m.key_expr) |key_expr| try self.scanSuperAndArgs(key_expr);
                    if (m.field_init) |field_init| try self.scanSuperAndArgs(field_init);
                    if (m.static_block) |static_block| try self.scanSuperAndArgs(static_block);
                }
            },
            // Statement nodes (an arrow's block body):
            .block => |stmts| for (stmts) |s| try self.scanSuperAndArgs(s),
            .expr_stmt => |e| try self.scanSuperAndArgs(e),
            .return_stmt => |r| if (r) |v| try self.scanSuperAndArgs(v),
            .throw_stmt => |t| try self.scanSuperAndArgs(t),
            .var_decl => |d| if (d.init) |ini| try self.scanSuperAndArgs(ini),
            .destructure_decl => |d| try self.scanSuperAndArgs(d.init),
            .decl_group => |g| for (g) |d2| try self.scanSuperAndArgs(d2),
            .if_stmt => |i| {
                try self.scanSuperAndArgs(i.cond);
                try self.scanSuperAndArgs(i.consequent);
                if (i.alternate) |a| try self.scanSuperAndArgs(a);
            },
            .while_stmt => |w| {
                try self.scanSuperAndArgs(w.cond);
                try self.scanSuperAndArgs(w.body);
            },
            .do_while_stmt => |w| {
                try self.scanSuperAndArgs(w.body);
                try self.scanSuperAndArgs(w.cond);
            },
            .for_stmt => |fo| {
                if (fo.init) |ini| try self.scanSuperAndArgs(ini);
                if (fo.cond) |c| try self.scanSuperAndArgs(c);
                if (fo.update) |u| try self.scanSuperAndArgs(u);
                try self.scanSuperAndArgs(fo.body);
            },
            .for_in => |fo| {
                if (fo.var_init) |ini| try self.scanSuperAndArgs(ini);
                try self.scanSuperAndArgs(fo.iterable);
                try self.scanSuperAndArgs(fo.body);
            },
            .labeled_stmt => |l| try self.scanSuperAndArgs(l.body),
            .try_stmt => |t| {
                try self.scanSuperAndArgs(t.block);
                if (t.catch_block) |c| try self.scanSuperAndArgs(c);
                if (t.finally_block) |fb| try self.scanSuperAndArgs(fb);
            },
            .switch_stmt => |sw| {
                try self.scanSuperAndArgs(sw.disc);
                for (sw.cases) |cs| {
                    if (cs.@"test") |t| try self.scanSuperAndArgs(t);
                    for (cs.body) |s| try self.scanSuperAndArgs(s);
                }
            },
            // .func_decl and any other node: stop. Nested ordinary functions and
            // class bodies have their own `arguments`/`super`; descending outside
            // the explicit class-expression scan mode could only produce false
            // positives.
            else => {},
        }
    }

    fn isPrivateNameText(name: []const u8) bool {
        return name.len > 0 and name[0] == '#';
    }

    fn requirePrivateName(
        self: *Parser,
        declared: *std.StringHashMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        _ = self;
        if (isPrivateNameText(name) and !declared.contains(name)) return ParseError.UnexpectedToken;
    }

    fn checkPrivateUsesInPattern(
        self: *Parser,
        declared: *std.StringHashMapUnmanaged(void),
        pattern: *Node,
    ) ParseError!void {
        switch (pattern.*) {
            .obj_pattern => |p| for (p.props) |prop| {
                if (prop.key_expr) |key_expr| try self.checkPrivateUsesInNode(declared, key_expr);
                if (prop.default) |default| try self.checkPrivateUsesInNode(declared, default);
                try self.checkPrivateUsesInPattern(declared, prop.target);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| {
                    if (elem.target) |target| try self.checkPrivateUsesInPattern(declared, target);
                    if (elem.default) |default| try self.checkPrivateUsesInNode(declared, default);
                }
                if (p.rest) |rest| try self.checkPrivateUsesInPattern(declared, rest);
            },
            else => {},
        }
    }

    fn checkPrivateUsesInParams(
        self: *Parser,
        declared: *std.StringHashMapUnmanaged(void),
        params: []const ast.Param,
    ) ParseError!void {
        for (params) |param| {
            if (param.pattern) |pattern| try self.checkPrivateUsesInPattern(declared, pattern);
            if (param.default) |default| try self.checkPrivateUsesInNode(declared, default);
        }
    }

    fn checkPrivateUsesInNode(
        self: *Parser,
        declared: *std.StringHashMapUnmanaged(void),
        node: *Node,
    ) ParseError!void {
        switch (node.*) {
            .identifier => |name| try self.requirePrivateName(declared, name),
            .unary => |u| try self.checkPrivateUsesInNode(declared, u.operand),
            .delete_expr => |target| try self.checkPrivateUsesInNode(declared, target),
            .update => |u| try self.checkPrivateUsesInNode(declared, u.target),
            .binary => |b| {
                try self.checkPrivateUsesInNode(declared, b.left);
                try self.checkPrivateUsesInNode(declared, b.right);
            },
            .logical => |l| {
                try self.checkPrivateUsesInNode(declared, l.left);
                try self.checkPrivateUsesInNode(declared, l.right);
            },
            .sequence => |s| {
                try self.checkPrivateUsesInNode(declared, s.first);
                try self.checkPrivateUsesInNode(declared, s.second);
            },
            .assign => |a| {
                try self.checkPrivateUsesInNode(declared, a.target);
                try self.checkPrivateUsesInNode(declared, a.value);
            },
            .op_assign => |a| {
                try self.checkPrivateUsesInNode(declared, a.target);
                try self.checkPrivateUsesInNode(declared, a.value);
            },
            .conditional => |c| {
                try self.checkPrivateUsesInNode(declared, c.cond);
                try self.checkPrivateUsesInNode(declared, c.consequent);
                try self.checkPrivateUsesInNode(declared, c.alternate);
            },
            .function => |f| {
                try self.checkPrivateUsesInParams(declared, f.params);
                try self.checkPrivateUsesInNode(declared, f.body);
            },
            .yield_expr => |y| if (y.argument) |arg| try self.checkPrivateUsesInNode(declared, arg),
            .await_expr => |a| try self.checkPrivateUsesInNode(declared, a.argument),
            .super_call => |args| for (args) |arg| try self.checkPrivateUsesInNode(declared, arg),
            .super_member => |m| if (m.computed) |computed| try self.checkPrivateUsesInNode(declared, computed),
            .call => |c| {
                try self.checkPrivateUsesInNode(declared, c.callee);
                for (c.args) |arg| try self.checkPrivateUsesInNode(declared, arg);
            },
            .new_expr => |n| {
                try self.checkPrivateUsesInNode(declared, n.callee);
                for (n.args) |arg| try self.checkPrivateUsesInNode(declared, arg);
            },
            .tagged_template => |t| {
                try self.checkPrivateUsesInNode(declared, t.tag);
                for (t.exprs) |expr| try self.checkPrivateUsesInNode(declared, expr);
            },
            .member => |m| {
                try self.checkPrivateUsesInNode(declared, m.object);
                try self.requirePrivateName(declared, m.property);
                if (m.computed) |computed| try self.checkPrivateUsesInNode(declared, computed);
            },
            .optional_chain => |chain| try self.checkPrivateUsesInNode(declared, chain),
            .object_lit => |props| for (props) |prop| {
                if (prop.key_expr) |key_expr| try self.checkPrivateUsesInNode(declared, key_expr);
                try self.checkPrivateUsesInNode(declared, prop.value);
            },
            .array_lit => |items| for (items) |item| try self.checkPrivateUsesInNode(declared, item),
            .spread => |value| try self.checkPrivateUsesInNode(declared, value),
            .obj_pattern, .arr_pattern => try self.checkPrivateUsesInPattern(declared, node),
            .var_decl => |d| if (d.init) |init_expr| try self.checkPrivateUsesInNode(declared, init_expr),
            .destructure_decl => |d| {
                try self.checkPrivateUsesInPattern(declared, d.pattern);
                try self.checkPrivateUsesInNode(declared, d.init);
            },
            .func_decl => |f| {
                try self.checkPrivateUsesInParams(declared, f.params);
                try self.checkPrivateUsesInNode(declared, f.body);
            },
            .return_stmt => |ret| if (ret) |value| try self.checkPrivateUsesInNode(declared, value),
            .throw_stmt => |value| try self.checkPrivateUsesInNode(declared, value),
            .try_stmt => |t| {
                try self.checkPrivateUsesInNode(declared, t.block);
                if (t.catch_param) |param| try self.checkPrivateUsesInPattern(declared, param);
                if (t.catch_block) |catch_block| try self.checkPrivateUsesInNode(declared, catch_block);
                if (t.finally_block) |finally_block| try self.checkPrivateUsesInNode(declared, finally_block);
            },
            .expr_stmt => |expr| try self.checkPrivateUsesInNode(declared, expr),
            .block => |stmts| for (stmts) |stmt| try self.checkPrivateUsesInNode(declared, stmt),
            .decl_group => |decls| for (decls) |decl| try self.checkPrivateUsesInNode(declared, decl),
            .if_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.cond);
                try self.checkPrivateUsesInNode(declared, stmt.consequent);
                if (stmt.alternate) |alt| try self.checkPrivateUsesInNode(declared, alt);
            },
            .while_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.cond);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .do_while_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.body);
                try self.checkPrivateUsesInNode(declared, stmt.cond);
            },
            .for_stmt => |stmt| {
                if (stmt.init) |init_node| try self.checkPrivateUsesInNode(declared, init_node);
                if (stmt.cond) |cond| try self.checkPrivateUsesInNode(declared, cond);
                if (stmt.update) |update| try self.checkPrivateUsesInNode(declared, update);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .for_in => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.target);
                if (stmt.var_init) |ini| try self.checkPrivateUsesInNode(declared, ini);
                try self.checkPrivateUsesInNode(declared, stmt.iterable);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .switch_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.disc);
                for (stmt.cases) |case| {
                    if (case.@"test") |case_test| try self.checkPrivateUsesInNode(declared, case_test);
                    for (case.body) |body| try self.checkPrivateUsesInNode(declared, body);
                }
            },
            .with_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.obj);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .export_decl => |e| {
                if (e.declaration) |decl| try self.checkPrivateUsesInNode(declared, decl);
                if (e.default_expr) |expr| try self.checkPrivateUsesInNode(declared, expr);
            },
            .import_call => |i| {
                try self.checkPrivateUsesInNode(declared, i.specifier);
                if (i.options) |options| try self.checkPrivateUsesInNode(declared, options);
            },
            .class_expr => |c| {
                // The heritage (`extends <expr>`) is evaluated in the ENCLOSING
                // private environment, not the class's own — so a private name
                // there must already be in scope (`class C extends class { x =
                // this.#foo; } { #foo; }` is a SyntaxError). The members,
                // conversely, see the class's own private names too.
                if (c.superclass) |sc| try self.checkPrivateUsesInNode(declared, sc);
                try self.checkPrivateNameUses(declared, c.members);
            },
            else => {},
        }
    }

    fn checkPrivateUsesInProgram(self: *Parser, stmts: []const *Node) ParseError!void {
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        for (stmts) |stmt| try self.checkPrivateUsesInNode(&declared, stmt);
    }

    fn checkPrivateNameUses(
        self: *Parser,
        inherited: *std.StringHashMapUnmanaged(void),
        members: []const ast.ClassMember,
    ) ParseError!void {
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        var it = inherited.iterator();
        while (it.next()) |entry| try declared.put(self.arena, entry.key_ptr.*, {});
        for (members) |member| {
            if (member.key_expr == null and isPrivateNameText(member.key))
                try declared.put(self.arena, member.key, {});
        }
        for (members) |member| {
            if (member.key_expr) |key_expr| try self.checkPrivateUsesInNode(&declared, key_expr);
            if (member.func) |func| try self.checkPrivateUsesInNode(&declared, func);
            if (member.field_init) |field_init| try self.checkPrivateUsesInNode(&declared, field_init);
            if (member.static_block) |static_block| try self.checkPrivateUsesInNode(&declared, static_block);
        }
    }

    /// Parse `(params) { body }` after a method name, returning a function node.
    /// `is_gen` marks a generator method (`*m() {}`).
    fn parseMethodTail(self: *Parser, name: []const u8, is_gen: bool, is_async: bool, start: usize) ParseError!*Node {
        const params = try self.parseFunctionParamList(is_gen, is_async);
        try self.checkDuplicateParams(params); // method definitions forbid duplicate params in all modes
        const own_use_strict = self.peekUseStrict();
        const fn_strict = self.strict or own_use_strict; // captured before parseFnBody (see parseFunctionDecl)
        const body = try self.parseFnBody(is_gen, is_async);
        if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
        if (fn_strict) try validateStrictParams(params);
        try self.checkParamBodyConflict(params, body);
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = fn_strict, .is_method = true };
        return self.alloc(.{ .function = fnode });
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        try self.expect(.lbracket);
        const saved_no_in = self.no_in; // array elements are `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var elems: std.ArrayListUnmanaged(*Node) = .empty;
        var rest_trailing_comma = false;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            // Elision / hole: a bare `,` yields an empty slot (v1: undefined, as
            // arrays are dense). `[ , x ]`, `[1, , 3]`, `[,]`.
            if (self.check(.comma)) {
                try elems.append(self.arena, try self.alloc(.elision));
                _ = self.advance();
                continue;
            }
            const el = try self.parseSpreadable();
            try elems.append(self.arena, el);
            if (!self.match(.comma)) break;
            // A trailing comma right after a rest element (`[...x,]`) is fine in a
            // literal but invalid in the pattern refinement — flag it.
            if (el.* == .spread and self.check(.rbracket)) rest_trailing_comma = true;
        }
        try self.expect(.rbracket);
        const node = try self.alloc(.{ .array_lit = elems.items });
        if (rest_trailing_comma) try self.rest_trailing_comma_arrays.put(self.arena, node, {});
        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.check(.identifier)) {
            if (self.isEscapedReservedWord(self.cur())) return ParseError.UnexpectedToken;
            const w = self.cur().text;
            if (std.mem.eql(u8, w, "function")) return self.parseFunctionExpr(false);
            // `async [no LineTerminator here] function` — a newline after `async`
            // breaks the async-function-expression form (`async` is then a plain
            // identifier reference).
            if (std.mem.eql(u8, w, "async") and !self.cur().escaped_identifier and self.peekIsKeyword(1, "function") and self.noNewlineBefore(1)) return self.parseFunctionExpr(true);
            if (std.mem.eql(u8, w, "new")) return self.parseNew();
            if (std.mem.eql(u8, w, "class")) return self.parseClassExpr();
            if (std.mem.eql(u8, w, "super")) return self.parseSuper();
            if (std.mem.eql(u8, w, "import")) return self.parseImportExpr();
        }
        // A decorated class expression: `@dec class {…}`.
        if (self.check(.at)) {
            try self.parseDecorators();
            return self.parseClassExpr();
        }
        if (self.check(.lbrace)) return self.parseObjectLiteral();
        if (self.check(.lbracket)) return self.parseArrayLiteral();
        const t = self.advance();
        switch (t.kind) {
            .number => {
                // Legacy octal / non-octal-decimal literals are SyntaxErrors in strict mode.
                if (self.strict and t.legacy_octal) return ParseError.UnexpectedToken;
                if (t.is_bigint) return self.alloc(.{ .bigint_lit = .{ .value = t.bigint, .text = t.bigint_text } });
                return self.alloc(.{ .number = t.number });
            },
            .string => {
                // A string with a legacy octal / non-octal-decimal escape is a
                // SyntaxError in strict mode.
                if (self.strict and t.legacy_octal) return ParseError.UnexpectedToken;
                return self.alloc(.{ .string = t.text });
            },
            .template => return self.parseTemplate(t.text),
            .regex => {
                // A regex literal's pattern and flags are early errors: validate
                // them at parse time so an invalid literal fails the parse (the
                // `phase: parse` negative tests rely on this), matching the same
                // compile the interpreter runs eagerly at evaluation.
                try validateRegexLiteral(self.arena, t.text, t.flags);
                return self.alloc(.{ .regex_literal = .{ .pattern = t.text, .flags = t.flags } });
            },
            .lparen => {
                const saved_no_in = self.no_in; // a parenthesized expr is `[+In]`
                self.no_in = false;
                const e = try self.parseExpression();
                self.no_in = saved_no_in;
                try self.expect(.rparen);
                // Record the parenthesization: a parenthesized array/object
                // literal is not a valid destructuring assignment target
                // (`({}) = 1`), even though a parenthesized identifier/member is.
                try self.markParenWrapped(e);
                self.paren_assign_target_name = if (self.check(.assign) and e.* == .identifier) e.identifier else null;
                return e;
            },
            .identifier => {
                if (std.mem.eql(u8, t.text, "true")) return self.alloc(.{ .boolean = true });
                if (std.mem.eql(u8, t.text, "false")) return self.alloc(.{ .boolean = false });
                if (std.mem.eql(u8, t.text, "null")) return self.alloc(.null_lit);
                if (std.mem.eql(u8, t.text, "this")) return self.alloc(.this_expr);
                if (isAlwaysReservedBinding(t.text) or (self.strict and isStrictReservedBinding(t.text))) return ParseError.UnexpectedToken;
                // `yield`/`await` are reserved words in their contexts, so neither
                // may appear here as an IdentifierReference — `void yield` inside a
                // generator, `void await` inside an async function/module — even
                // though a YieldExpression/AwaitExpression (handled higher up) is
                // fine. (Outside those contexts they are ordinary identifiers.)
                if (self.in_generator and std.mem.eql(u8, t.text, "yield")) return ParseError.UnexpectedToken;
                if ((self.in_async or self.module) and std.mem.eql(u8, t.text, "await")) return ParseError.UnexpectedToken;
                return self.alloc(.{ .identifier = t.text });
            },
            else => return ParseError.UnexpectedToken,
        }
    }
};

/// Decode one escape char in a template literal's literal text.
/// Given the raw template text and the index just past a `${`, return the index
/// of the matching `}` (or `raw.len` if unterminated). Brace- and string-aware.
/// Within a template substitution, whether a `/` at `last_sig` begins a regex
/// literal (true) rather than a division. Mirrors the lexer's heuristic.
/// Validate a regex literal's flags and pattern, returning a parse error for an
/// invalid one. Mirrors the interpreter's eager compile so the result is the
/// same whether the literal is rejected at parse or at evaluation.
fn validateRegexLiteral(arena: std.mem.Allocator, pattern: []const u8, flags: []const u8) ParseError!void {
    var seen = std.mem.zeroes([128]bool);
    for (flags) |f| {
        if (f >= 128 or std.mem.indexOfScalar(u8, "dgimsuvy", f) == null or seen[f]) return ParseError.UnexpectedToken;
        seen[f] = true;
    }
    if (seen['u'] and seen['v']) return ParseError.UnexpectedToken;
    const cf = regex.common.CompileFlags{
        .case_insensitive = seen['i'],
        .multiline = seen['m'],
        .dot_all = seen['s'],
        .unicode = seen['u'] or seen['v'],
        .unicode_sets = seen['v'],
        .ecmascript = true,
    };
    _ = regex.Regex.compileWithFlags(arena, pattern, cf) catch return ParseError.UnexpectedToken;
}

fn substRegexAllowed(last: u8) bool {
    return switch (last) {
        0, '(', '[', '{', ',', ';', ':', '?', '=', '+', '-', '*', '/', '%', '!', '&', '|', '^', '~', '<', '>' => true,
        else => false,
    };
}

fn substEnd(raw: []const u8, start: usize) usize {
    var depth: usize = 1;
    var i = start;
    var last_sig: u8 = 0; // last significant byte — drives regex-vs-division
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => {},
            '{' => {
                depth += 1;
                last_sig = '{';
            },
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
                last_sig = '}';
            },
            '\'', '"' => {
                i += 1;
                while (i < raw.len) : (i += 1) {
                    if (raw[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (raw[i] == c) break;
                }
                last_sig = '"';
            },
            '`' => {
                // Nested template — skip to its matching backtick, honoring its
                // own `${ }` substitutions recursively.
                i += 1;
                while (i < raw.len) : (i += 1) {
                    if (raw[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (raw[i] == '`') break;
                    if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                        const inner = substEnd(raw, i + 2);
                        i = if (inner < raw.len) inner else raw.len - 1;
                    }
                }
                last_sig = '`';
            },
            '/' => {
                const n = if (i + 1 < raw.len) raw[i + 1] else 0;
                if (n == '/') {
                    while (i < raw.len and raw[i] != '\n') i += 1;
                    continue; // i now at '\n' or end; outer loop re-checks
                } else if (n == '*') {
                    i += 2;
                    while (i + 1 < raw.len and !(raw[i] == '*' and raw[i + 1] == '/')) i += 1;
                    i += 1; // land on the closing '/', then the trailing i+=1 passes it
                    last_sig = '/';
                } else if (substRegexAllowed(last_sig)) {
                    // Regex literal: skip to the unescaped terminating '/'.
                    i += 1;
                    var in_class = false;
                    while (i < raw.len) : (i += 1) {
                        const rc = raw[i];
                        if (rc == '\\') {
                            i += 1;
                            continue;
                        }
                        if (rc == '[') in_class = true else if (rc == ']') in_class = false else if (rc == '/' and !in_class) break;
                    }
                    // skip flags
                    var j = i + 1;
                    while (j < raw.len and std.ascii.isAlphabetic(raw[j])) j += 1;
                    i = j - 1; // trailing i+=1 lands past the flags
                    last_sig = 'r';
                } else {
                    last_sig = '/';
                }
            },
            '\\' => i += 1,
            else => last_sig = c,
        }
        i += 1;
    }
    return raw.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parser builds precedence-correct tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = try Parser.init(arena.allocator(), "1 + 2 * 3");
    const prog = try p.parseProgram();
    try std.testing.expect(prog.* == .program);
    const stmt = prog.program[0];
    try std.testing.expect(stmt.* == .expr_stmt);
    const e = stmt.expr_stmt;
    try std.testing.expect(e.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, e.binary.op);
    // right side must be the multiplication (binds tighter)
    try std.testing.expect(e.binary.right.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.mul, e.binary.right.binary.op);
}

test "parser handles var decl and if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = try Parser.init(arena.allocator(), "let x = 1; if (x) x = 2; else x = 3;");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.program.len);
    try std.testing.expect(prog.program[0].* == .var_decl);
    try std.testing.expect(prog.program[1].* == .if_stmt);
}

test "parser requires statement boundary between same-line tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var single = try Parser.init(arena.allocator(), "var str = '''';");
    try std.testing.expectError(ParseError.UnexpectedToken, single.parseProgram());

    var double = try Parser.init(arena.allocator(), "var str = \"\"\"\";");
    try std.testing.expectError(ParseError.UnexpectedToken, double.parseProgram());

    var adjacent_expr = try Parser.init(arena.allocator(), "a b");
    try std.testing.expectError(ParseError.UnexpectedToken, adjacent_expr.parseProgram());
}

test "parser rejects malformed untagged template escapes" {
    const invalid = [_][]const u8{
        "`\\x0`",
        "`\\x0G`",
        "`\\xG`",
        "`\\u0`",
        "`\\u0g`",
        "`\\u00g`",
        "`\\u000g`",
        "`\\u{g`",
        "`\\u{0`",
        "`\\u{10FFFFF}`",
        "`\\u{1F_639}`",
        "`\\u`",
        "`\\00`",
        "`\\8`",
        "`\\9`",
    };
    for (invalid) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var p = try Parser.init(arena.allocator(), src);
        try std.testing.expectError(ParseError.UnexpectedToken, p.parseProgram());
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ok = try Parser.init(arena.allocator(), "`\\n${1}\\u{41}`");
    _ = try ok.parseProgram();
}

test "parser enforces reserved words in identifier positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var shorthand_true = try Parser.init(arena.allocator(), "({ true });");
    try std.testing.expectError(ParseError.UnexpectedToken, shorthand_true.parseProgram());

    var shorthand_false = try Parser.init(arena.allocator(), "({ false });");
    try std.testing.expectError(ParseError.UnexpectedToken, shorthand_false.parseProgram());

    var shorthand_null = try Parser.init(arena.allocator(), "({ null });");
    try std.testing.expectError(ParseError.UnexpectedToken, shorthand_null.parseProgram());

    var property_name = try Parser.init(arena.allocator(), "({ true: 1, false() {}, get null() { return 1; } });");
    const property_prog = try property_name.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), property_prog.program.len);

    var module_await = try Parser.init(arena.allocator(), "var await;");
    try std.testing.expectError(ParseError.UnexpectedToken, module_await.parseModule());

    var script_await = try Parser.init(arena.allocator(), "var await;");
    const script_prog = try script_await.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), script_prog.program.len);
}

test "parser accepts ASI line terminators between statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lf = try Parser.init(arena.allocator(), "var a = 1\nvar b = 2");
    const lf_prog = try lf.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), lf_prog.program.len);

    var cr = try Parser.init(arena.allocator(), "var a = 1\rvar b = 2");
    const cr_prog = try cr.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), cr_prog.program.len);

    var ls = try Parser.init(arena.allocator(), "var a = 1\u{2028}var b = 2");
    const ls_prog = try ls.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), ls_prog.program.len);

    var prefix_inc = try Parser.init(arena.allocator(), "var x = 0; var y = 0; x\n++y");
    const prefix_inc_prog = try prefix_inc.parseProgram();
    try std.testing.expectEqual(@as(usize, 4), prefix_inc_prog.program.len);

    var prefix_dec = try Parser.init(arena.allocator(), "var x = 0; var y = 2; x\n--y");
    const prefix_dec_prog = try prefix_dec.parseProgram();
    try std.testing.expectEqual(@as(usize, 4), prefix_dec_prog.program.len);

    var assign_then_inc = try Parser.init(arena.allocator(), "var a=1,b=2,c=3; a=b\n++c");
    const assign_then_inc_prog = try assign_then_inc.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), assign_then_inc_prog.program.len);

    var return_newline = try Parser.init(arena.allocator(), "function f(){ return\n1; }");
    const return_newline_prog = try return_newline.parseProgram();
    const return_body = return_newline_prog.program[0].func_decl.body.block;
    try std.testing.expect(return_body[0].return_stmt == null);
    try std.testing.expect(return_body[1].* == .expr_stmt);

    var break_newline = try Parser.init(arena.allocator(), "label: while (true) { break\nlabel; }");
    const break_newline_prog = try break_newline.parseProgram();
    const break_stmt = break_newline_prog.program[0].labeled_stmt.body.while_stmt.body.block[0];
    try std.testing.expect(break_stmt.break_stmt == null);

    var continue_newline = try Parser.init(arena.allocator(), "label: while (true) { continue\nlabel; }");
    const continue_newline_prog = try continue_newline.parseProgram();
    const continue_stmt = continue_newline_prog.program[0].labeled_stmt.body.while_stmt.body.block[0];
    try std.testing.expect(continue_stmt.continue_stmt == null);

    var throw_newline = try Parser.init(arena.allocator(), "throw\n1;");
    try std.testing.expectError(ParseError.UnexpectedToken, throw_newline.parseProgram());
}

test "parser requires module import export statement boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var named = try Parser.init(arena.allocator(), "export {} null;");
    try std.testing.expectError(ParseError.UnexpectedToken, named.parseModule());

    var named_from = try Parser.init(arena.allocator(), "export {} from './m.js' null;");
    try std.testing.expectError(ParseError.UnexpectedToken, named_from.parseModule());

    var namespace_from = try Parser.init(arena.allocator(), "export * as ns from './m.js' null;");
    try std.testing.expectError(ParseError.UnexpectedToken, namespace_from.parseModule());

    var bare_import = try Parser.init(arena.allocator(), "import './m.js' null;");
    try std.testing.expectError(ParseError.UnexpectedToken, bare_import.parseModule());

    var default_expr = try Parser.init(arena.allocator(), "export default 1 null;");
    try std.testing.expectError(ParseError.UnexpectedToken, default_expr.parseModule());
}

test "parser accepts module import export ASI line terminators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var named = try Parser.init(arena.allocator(), "export {}\nexport {}");
    const named_prog = try named.parseModule();
    try std.testing.expectEqual(@as(usize, 2), named_prog.program.len);

    var bare_import = try Parser.init(arena.allocator(), "import './m.js'\nexport {}");
    const import_prog = try bare_import.parseModule();
    try std.testing.expectEqual(@as(usize, 2), import_prog.program.len);
}

test "parser rejects module duplicate lexical and exported names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexical = try Parser.init(arena.allocator(), "let x; const x = 0;");
    try std.testing.expectError(ParseError.UnexpectedToken, lexical.parseModule());

    var var_lex = try Parser.init(arena.allocator(), "var f; function f() {}");
    try std.testing.expectError(ParseError.UnexpectedToken, var_lex.parseModule());

    var default_dup = try Parser.init(arena.allocator(), "var x, y; export default x; export { y as default };");
    try std.testing.expectError(ParseError.UnexpectedToken, default_dup.parseModule());

    var star_dup = try Parser.init(arena.allocator(), "var x; export { x as z }; export * as z from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, star_dup.parseModule());
}

test "parser rejects unresolved local exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var missing = try Parser.init(arena.allocator(), "export { unresolvable };");
    try std.testing.expectError(ParseError.UnexpectedToken, missing.parseModule());

    var global = try Parser.init(arena.allocator(), "export { Number };");
    try std.testing.expectError(ParseError.UnexpectedToken, global.parseModule());

    var declared_later = try Parser.init(arena.allocator(), "export { value as renamed }; const value = 1;");
    const prog = try declared_later.parseModule();
    try std.testing.expectEqual(@as(usize, 2), prog.program.len);
}

test "parser rejects forbidden strict import bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var args = try Parser.init(arena.allocator(), "import { x as arguments } from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, args.parseModule());

    var eval_name = try Parser.init(arena.allocator(), "import eval from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, eval_name.parseModule());
}

test "parser validates static import attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var attrs = try Parser.init(arena.allocator(),
        \\import x from './a.js' with {};
        \\import './b.js'
        \\  with { type: "json", "test262": "", };
        \\export * from './c.js' with { if: "" };
    );
    const prog = try attrs.parseModule();
    try std.testing.expectEqual(@as(usize, 3), prog.program.len);

    var dup_import = try Parser.init(arena.allocator(), "import './m.js' with { type: 'json', 'typ\\u0065': '' };");
    try std.testing.expectError(ParseError.UnexpectedToken, dup_import.parseModule());

    var dup_export = try Parser.init(arena.allocator(), "export * from './m.js' with { type: 'json', 'type': '' };");
    try std.testing.expectError(ParseError.UnexpectedToken, dup_export.parseModule());

    var non_string = try Parser.init(arena.allocator(), "import './m.js' with { type: 1 };");
    try std.testing.expectError(ParseError.UnexpectedToken, non_string.parseModule());
}

test "parser accepts source-phase import bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_import = try Parser.init(arena.allocator(), "import source mod from '<module source>';");
    const source_prog = try source_import.parseModule();
    try std.testing.expectEqualStrings("source", source_prog.program[0].import_decl.entries[0].imported);
    try std.testing.expectEqualStrings("mod", source_prog.program[0].import_decl.entries[0].local);

    var source_named_source = try Parser.init(arena.allocator(), "import source source from '<module source>';");
    const named_source_prog = try source_named_source.parseModule();
    try std.testing.expectEqualStrings("source", named_source_prog.program[0].import_decl.entries[0].local);

    var source_named_from = try Parser.init(arena.allocator(), "import source from from '<module source>';");
    const named_from_prog = try source_named_from.parseModule();
    try std.testing.expectEqualStrings("from", named_from_prog.program[0].import_decl.entries[0].local);

    var default_source = try Parser.init(arena.allocator(), "import source from './m.js';");
    const default_prog = try default_source.parseModule();
    try std.testing.expectEqualStrings("default", default_prog.program[0].import_decl.entries[0].imported);
    try std.testing.expectEqualStrings("source", default_prog.program[0].import_decl.entries[0].local);
}

test "parser validates module label early errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var undef_continue = try Parser.init(arena.allocator(), "while (false) { continue undef; }");
    try std.testing.expectError(ParseError.UnexpectedToken, undef_continue.parseModule());

    var duplicate = try Parser.init(arena.allocator(), "label: { label: 0; }");
    try std.testing.expectError(ParseError.UnexpectedToken, duplicate.parseModule());

    var labeled_loop = try Parser.init(arena.allocator(), "label: while (false) { continue label; }");
    const labeled_prog = try labeled_loop.parseModule();
    try std.testing.expectEqual(@as(usize, 1), labeled_prog.program.len);

    var labeled_block_continue = try Parser.init(arena.allocator(), "label: { while (false) { continue label; } }");
    try std.testing.expectError(ParseError.UnexpectedToken, labeled_block_continue.parseModule());
}

test "parser rejects top-level new target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var top_level = try Parser.init(arena.allocator(), "new.target;");
    try std.testing.expectError(ParseError.UnexpectedToken, top_level.parseModule());

    var script_top_level = try Parser.init(arena.allocator(), "new.target;");
    try std.testing.expectError(ParseError.UnexpectedToken, script_top_level.parseProgram());

    var nested = try Parser.init(arena.allocator(), "function f() { new.target; }");
    const prog = try nested.parseModule();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);

    var nested_arrow = try Parser.init(arena.allocator(), "function f() { return () => new.target; }");
    const arrow_prog = try nested_arrow.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), arrow_prog.program.len);

    var default_param = try Parser.init(arena.allocator(), "function f(x = new.target) { return x; }");
    const default_prog = try default_param.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), default_prog.program.len);

    var top_level_arrow = try Parser.init(arena.allocator(), "() => new.target;");
    try std.testing.expectError(ParseError.UnexpectedToken, top_level_arrow.parseProgram());

    var static_block = try Parser.init(arena.allocator(), "class C { static { new.target; } }");
    const static_prog = try static_block.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), static_prog.program.len);
}

test "parser validates module string export names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var local_string = try Parser.init(arena.allocator(), "export { \"foo\" as \"bar\" }; function foo() {}");
    try std.testing.expectError(ParseError.UnexpectedToken, local_string.parseModule());

    var bad_export = try Parser.init(arena.allocator(), "export { Foo as \"\\uD83D\" }; function Foo() {}");
    try std.testing.expectError(ParseError.UnexpectedToken, bad_export.parseModule());

    var bad_import = try Parser.init(arena.allocator(), "import { \"\\uD83D\" as foo } from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, bad_import.parseModule());

    var good_reexport = try Parser.init(arena.allocator(), "export { \"foo\" as \"bar\" } from './m.js';");
    const prog = try good_reexport.parseModule();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);
}

test "parser validates class private name uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var method_use = try Parser.init(arena.allocator(), "class C { f() { this.#x; } }");
    try std.testing.expectError(ParseError.UnexpectedToken, method_use.parseModule());

    var field_use = try Parser.init(arena.allocator(), "class C { y = this.#x; }");
    try std.testing.expectError(ParseError.UnexpectedToken, field_use.parseModule());

    var declared = try Parser.init(arena.allocator(), "class C { #x; f() { this.#x; } }");
    const prog = try declared.parseModule();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);

    var nested = try Parser.init(arena.allocator(),
        \\class Outer {
        \\  #x;
        \\  f() { return class Inner { g() { return this.#x; } } }
        \\}
    );
    const nested_prog = try nested.parseModule();
    try std.testing.expectEqual(@as(usize, 1), nested_prog.program.len);
}

test "parser rejects new await only when await is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var module_new_await = try Parser.init(arena.allocator(), "new await;");
    try std.testing.expectError(ParseError.UnexpectedToken, module_new_await.parseModule());

    var script_new_await = try Parser.init(arena.allocator(), "function await() {} new await;");
    const prog = try script_new_await.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.program.len);
}

test "parser does not propagate module await into function parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var decl_param = try Parser.init(arena.allocator(), "function fn(x = await 1) {}");
    try std.testing.expectError(ParseError.UnexpectedToken, decl_param.parseModule());

    var expr_param = try Parser.init(arena.allocator(), "0, function (x = await 1) {};");
    try std.testing.expectError(ParseError.UnexpectedToken, expr_param.parseModule());
}
