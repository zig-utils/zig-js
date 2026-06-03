const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("ast.zig");
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
    /// True when parsing a Module (via `parseModule`): top-level `import` and
    /// `export` declarations are recognized, and the body is implicitly strict.
    module: bool = false,

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
    /// Whether no line terminator separates the token `ahead` positions away from
    /// the one just before it (the restricted-production check, e.g. `using` may
    /// not be followed by a newline before its binding identifier).
    fn noNewlineBefore(self: *Parser, ahead: usize) bool {
        const idx = self.pos + ahead;
        if (idx == 0 or idx >= self.tokens.len) return true;
        const gap = self.source[self.tokens[idx - 1].end..self.tokens[idx].pos];
        return std.mem.indexOfScalar(u8, gap, '\n') == null;
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
    fn isContextual(self: *Parser, word: []const u8) bool {
        return isKeyword(self.cur(), word);
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
        if (self.check(.identifier) and !isReservedWord(self.cur().text)) {
            return self.advance().text;
        }
        return null;
    }

    fn isReservedWord(text: []const u8) bool {
        const words = [_][]const u8{
            "true",     "false",   "null",     "undefined", "this",  "typeof",
            "void",     "new",     "in",       "instanceof", "function", "return",
            "var",      "let",     "const",    "if",        "else",  "while",
            "do",       "for",     "switch",   "case",      "default", "break",
            "continue", "throw",   "try",      "catch",     "finally", "delete",
            "class",    "extends", "super",    "yield",
        };
        for (words) |w| {
            if (std.mem.eql(u8, text, w)) return true;
        }
        return false;
    }

    fn alloc(self: *Parser, node: Node) ParseError!*Node {
        const p = try self.arena.create(Node);
        p.* = node;
        return p;
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
                if (node.class_expr.name.len == 0) node.class_expr.name = name;
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
                .decl_group => |g| for (g) |d2| {
                    if (d2.* == .var_decl and d2.var_decl.kind != .@"var") try self.addDecl(&seen, d2.var_decl.name, true);
                },
                .func_decl => |fnode| if (funcs_lexical and fnode.name.len > 0)
                    try self.addDecl(&seen, fnode.name, fnode.is_async or fnode.is_generator),
                else => {},
            }
        }
        for (stmts) |s| try self.recurseScope(s);
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

    /// Parse the token stream as a Module: a Module is always strict, and its
    /// top level additionally permits `import`/`export` declarations.
    pub fn parseModule(self: *Parser) ParseError!*Node {
        self.module = true;
        self.strict = true;
        // A Module is an async context for `await` at the top level (top-level
        // await). Nested non-async functions reset this via `parseFnBody`.
        self.in_async = true;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.eof)) {
            try stmts.append(self.arena, try self.parseModuleItem());
        }
        return self.alloc(.{ .program = stmts.items });
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
            _ = self.match(.semicolon);
            return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = &.{} } });
        }
        // Default binding: `import name ...`
        if (self.check(.identifier) and !std.mem.eql(u8, self.cur().text, "from")) {
            const name = self.advance().text;
            try entries.append(self.arena, .{ .imported = "default", .local = name });
            _ = self.match(.comma);
        }
        // `* as ns` namespace, or `{ ... }` named bindings.
        if (self.check(.star)) {
            _ = self.advance();
            try self.expectContextual("as");
            const ns = self.advance().text;
            try entries.append(self.arena, .{ .imported = "*", .local = ns });
        } else if (self.check(.lbrace)) {
            try self.parseNamedImports(&entries);
        }
        try self.expectContextual("from");
        const spec = if (self.check(.string)) self.advance().text else return ParseError.UnexpectedToken;
        _ = self.match(.semicolon);
        return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = entries.items } });
    }

    /// `{ a, b as c, "str" as d }` import bindings.
    fn parseNamedImports(self: *Parser, entries: *std.ArrayListUnmanaged(ast.ImportEntry)) ParseError!void {
        try self.expect(.lbrace);
        while (!self.check(.rbrace)) {
            const imported = self.moduleExportName();
            var local = imported;
            if (self.checkContextual("as")) {
                _ = self.advance();
                local = self.advance().text;
            }
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
                node.star_as = self.moduleExportName();
            }
            try self.expectContextual("from");
            node.from = self.advance().text;
            _ = self.match(.semicolon);
            return self.alloc(.{ .export_decl = node });
        }
        if (self.check(.lbrace)) {
            // `export { a, b as c }` [from "m"]
            var entries: std.ArrayListUnmanaged(ast.ExportEntry) = .empty;
            _ = self.advance(); // `{`
            while (!self.check(.rbrace)) {
                const first = self.moduleExportName();
                var exported = first;
                if (self.checkContextual("as")) {
                    _ = self.advance();
                    exported = self.moduleExportName();
                }
                try entries.append(self.arena, .{ .local = first, .exported = exported });
                if (!self.match(.comma)) break;
            }
            try self.expect(.rbrace);
            if (self.checkContextual("from")) {
                _ = self.advance();
                node.from = self.advance().text;
                // Re-export: the names are imported from the source module, not local.
                for (entries.items) |*e| {
                    e.imported = e.local;
                    e.local = "";
                }
            }
            node.entries = entries.items;
            _ = self.match(.semicolon);
            return self.alloc(.{ .export_decl = node });
        }
        if (self.isContextual("default")) {
            _ = self.advance(); // `default`
            // `export default function/class …` binds a (possibly anonymous) name.
            if (self.isContextual("function") or (self.isContextual("async") and self.peekIsKeyword(1, "function"))) {
                // `export default function …` may be anonymous, so parse it as a
                // function *expression* (which permits no name).
                const is_async = self.isContextual("async");
                const decl = try self.parseFunctionExpr(is_async);
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
            _ = self.match(.semicolon);
            return self.alloc(.{ .export_decl = node });
        }
        // `export <declaration>` — var/let/const/function/class. The declaration
        // also binds locally; its bound names become exports.
        const decl = try self.parseStatement();
        node.declaration = decl;
        return self.alloc(.{ .export_decl = node });
    }

    /// A ModuleExportName: an identifier or a string literal (ES2022).
    fn moduleExportName(self: *Parser) []const u8 {
        return self.advance().text;
    }

    fn parseStatement(self: *Parser) ParseError!*Node {
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
            if (std.mem.eql(u8, t.text, "var")) return self.parseVarDecl(.@"var");
            if (std.mem.eql(u8, t.text, "let")) return self.parseVarDecl(.let);
            if (std.mem.eql(u8, t.text, "const")) return self.parseVarDecl(.@"const");
            // `using x = e, …;` (explicit resource management): a block-scoped,
            // initializer-required declaration — parsed like `const` (disposal at
            // scope exit is not yet implemented). `using` not followed (on the
            // same line) by a binding identifier is an ordinary expression.
            if (std.mem.eql(u8, t.text, "using") and self.peekKind(1) == .identifier and
                self.noNewlineBefore(1) and !isReservedWord(self.tokens[self.pos + 1].text))
                return self.parseVarDeclDispose(.@"const", 1);
            if (std.mem.eql(u8, t.text, "await") and self.peekIsKeyword(1, "using") and
                self.peekKind(2) == .identifier and self.noNewlineBefore(2)) {
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
                const body = try self.parseStatement();
                return self.alloc(.{ .with_stmt = .{ .obj = obj, .body = body } });
            }
            if (std.mem.eql(u8, t.text, "function")) return self.parseFunctionDecl(false);
            // `async function …` declaration (contextual keyword: `async`
            // immediately followed by `function`). `async` followed by anything
            // else is an ordinary expression statement (async arrow / identifier).
            if (std.mem.eql(u8, t.text, "async") and self.peekIsKeyword(1, "function")) return self.parseFunctionDecl(true);
            if (std.mem.eql(u8, t.text, "return")) return self.parseReturn();
            if (std.mem.eql(u8, t.text, "throw")) return self.parseThrow();
            if (std.mem.eql(u8, t.text, "try")) return self.parseTry();
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
                return self.alloc(.{ .break_stmt = label });
            }
            if (std.mem.eql(u8, t.text, "continue")) {
                _ = self.advance();
                const label = self.optionalLabel();
                _ = self.match(.semicolon);
                // `continue` requires an enclosing loop (labeled or not).
                if (self.iter_depth == 0) return ParseError.UnexpectedToken;
                return self.alloc(.{ .continue_stmt = label });
            }
            // Labeled statement: `label: stmt` (identifier directly followed by `:`).
            if (self.peekKind(1) == .colon and !isReservedWord(t.text)) {
                _ = self.advance(); // label
                _ = self.advance(); // ':'
                const body = try self.parseStatement();
                return self.alloc(.{ .labeled_stmt = .{ .label = t.text, .body = body } });
            }
        }
        if (t.kind == .lbrace) return self.parseBlock();

        const expr = try self.parseExpression();
        _ = self.match(.semicolon);
        return self.alloc(.{ .expr_stmt = expr });
    }

    /// Convert an array/object *literal* on the LHS of `=` into a destructuring
    /// pattern (the cover-grammar reinterpretation).
    fn litToPattern(self: *Parser, node: *Node) ParseError!*Node {
        switch (node.*) {
            .array_lit => |elems| {
                var out: std.ArrayListUnmanaged(ast.ArrPatElem) = .empty;
                var rest: ?*Node = null;
                for (elems) |e| {
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
                var out: std.ArrayListUnmanaged(ast.ObjPatProp) = .empty;
                for (props) |p| {
                    if (p.value.* == .assign) {
                        try out.append(self.arena, .{ .key = p.key, .key_expr = p.key_expr, .target = try self.exprToTarget(p.value.assign.target), .default = p.value.assign.value });
                    } else {
                        try out.append(self.arena, .{ .key = p.key, .key_expr = p.key_expr, .target = try self.exprToTarget(p.value) });
                    }
                }
                return self.alloc(.{ .obj_pattern = .{ .props = out.items, .rest = null } });
            },
            else => return ParseError.InvalidAssignmentTarget,
        }
    }

    fn exprToTarget(self: *Parser, node: *Node) ParseError!*Node {
        return switch (node.*) {
            .identifier, .member => node,
            .array_lit, .object_lit => try self.litToPattern(node),
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
        return self.alloc(.{ .identifier = name.text });
    }

    fn parseObjectPattern(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        var props: std.ArrayListUnmanaged(ast.ObjPatProp) = .empty;
        var rest: ?[]const u8 = null;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.ellipsis)) {
                const r = self.advance();
                if (r.kind != .identifier) return ParseError.UnexpectedToken;
                rest = r.text;
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
            // `{ key }` shorthand, or `{ key: target }`.
            const target = if (self.match(.colon))
                try self.parseBindingTarget()
            else
                try self.alloc(.{ .identifier = key });
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
            _ = self.match(.semicolon);
            return self.alloc(.{ .destructure_decl = .{ .kind = kind, .pattern = pattern, .init = init_expr } });
        }
        // One or more comma-separated declarators: `let a, b = 1, c`.
        var decls: std.ArrayListUnmanaged(*Node) = .empty;
        while (true) {
            const name_tok = self.advance();
            if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
            // Strict mode forbids `eval`/`arguments` as binding names.
            if (self.strict and isEvalOrArguments(name_tok.text)) return ParseError.UnexpectedToken;
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
        _ = self.match(.semicolon);
        // A single declarator stays a bare var_decl; multiples become a
        // transparent declaration group (NOT a block — no new scope).
        if (decls.items.len == 1) return decls.items[0];
        return self.alloc(.{ .decl_group = decls.items });
    }

    fn parseBlock(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
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
        const cons = try self.parseStatement();
        var alt: ?*Node = null;
        if (isKeyword(self.cur(), "else")) {
            _ = self.advance();
            alt = try self.parseStatement();
        }
        return self.alloc(.{ .if_stmt = .{ .cond = cond, .consequent = cons, .alternate = alt } });
    }

    /// Parse a loop body, tracking that `break`/`continue` are now legal.
    fn parseLoopBody(self: *Parser) ParseError!*Node {
        self.iter_depth += 1;
        defer self.iter_depth -= 1;
        return self.parseStatement();
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
        if (isKeyword(self.cur(), "var")) {
            decl_kind = .@"var";
            _ = self.advance();
        } else if (isKeyword(self.cur(), "let")) {
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
            _ = self.advance();
        }
        // Iteration form `for ([decl] target in/of iterable)`, where `target`
        // is an identifier, a destructuring pattern, or (assignment form) a
        // member expression. Parse a target, then require `in`/`of`; otherwise
        // rewind to `save` and parse a classic `for(;;)`.
        if (self.tryForTarget(decl_kind) catch null) |target| {
            if (isKeyword(self.cur(), "in") or isKeyword(self.cur(), "of")) {
                const is_of = isKeyword(self.advance(), "of"); // consume in/of
                // `for-in` takes an Expression, `for-of` an AssignmentExpression.
                const iterable = if (is_of) try self.parseAssignment() else try self.parseExpression();
                try self.expect(.rparen);
                const body = try self.parseLoopBody();
                return self.alloc(.{ .for_in = .{
                    .decl_kind = decl_kind,
                    .target = target,
                    .iterable = iterable,
                    .body = body,
                    .is_of = is_of,
                    .is_await = is_await,
                } });
            }
        }
        self.pos = save; // not an iteration form — rewind and parse a classic for

        var init_node: ?*Node = null;
        if (self.match(.semicolon)) {
            // empty initializer
        } else if (isKeyword(self.cur(), "var")) {
            init_node = try self.parseVarDecl(.@"var"); // consumes the ';'
        } else if (isKeyword(self.cur(), "let")) {
            init_node = try self.parseVarDecl(.let);
        } else if (isKeyword(self.cur(), "const")) {
            init_node = try self.parseVarDecl(.@"const");
        } else if (isKeyword(self.cur(), "using") and self.peekKind(1) == .identifier and self.noNewlineBefore(1)) {
            // `for (using x = e; …)` — a using declaration head (the `using of`
            // lookahead restriction applies only to for-of, not the classic for).
            init_node = try self.parseVarDeclDispose(.@"const", 1);
        } else {
            init_node = try self.parseExpression();
            try self.expect(.semicolon);
        }
        var cond: ?*Node = null;
        if (!self.check(.semicolon)) cond = try self.parseExpression();
        try self.expect(.semicolon);
        var update: ?*Node = null;
        if (!self.check(.rparen)) update = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseLoopBody();
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
            // Assignment form: an array/object literal cover → destructuring pattern.
            return try self.litToPattern(try self.parsePrimary());
        }
        if (decl_kind != null) {
            // A declaration binds a single BindingIdentifier.
            if (self.check(.identifier) and !isReservedWord(self.cur().text))
                return try self.alloc(.{ .identifier = self.advance().text });
            return null;
        }
        // Assignment form: a LeftHandSideExpression that must be a valid
        // assignment target. Anything else (a call, `this`, a literal, …) makes
        // this not an iteration form, so the caller rewinds and it becomes a
        // syntax error in the classic-`for` path.
        const node = try self.parsePostfix();
        return switch (node.*) {
            .identifier, .member, .super_member => node,
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
        defer self.switch_depth -= 1;
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            var test_expr: ?*Node = null;
            if (isKeyword(self.cur(), "case")) {
                _ = self.advance();
                test_expr = try self.parseExpression();
            } else if (isKeyword(self.cur(), "default")) {
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
        if (!self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof)) {
            arg = try self.parseExpression();
        }
        _ = self.match(.semicolon);
        return self.alloc(.{ .return_stmt = arg });
    }

    fn parseThrow(self: *Parser) ParseError!*Node {
        _ = self.advance(); // throw
        const arg = try self.parseExpression();
        _ = self.match(.semicolon);
        return self.alloc(.{ .throw_stmt = arg });
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
            // Destructuring parameter: `function f({a}, [b])`.
            if (!is_rest and (self.check(.lbrace) or self.check(.lbracket))) {
                const pat = try self.parseBindingTarget();
                const default = if (self.match(.assign)) try self.parseAssignment() else null;
                try params.append(self.arena, .{ .name = "", .pattern = pat, .default = default });
                if (!self.match(.comma)) break;
                continue;
            }
            const p = self.advance();
            if (p.kind != .identifier) return ParseError.UnexpectedToken;
            var default: ?*Node = null;
            if (!is_rest and self.match(.assign)) default = try self.parseAssignment();
            try params.append(self.arena, .{ .name = p.text, .default = default, .is_rest = is_rest });
            if (is_rest) break; // a rest parameter must be last
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return params.items;
    }

    fn isEvalOrArguments(name: []const u8) bool {
        return std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments");
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
            for (params[0..i]) |q| {
                if (q.pattern == null and std.mem.eql(u8, q.name, p.name)) return ParseError.UnexpectedToken;
            }
        }
    }

    fn parseFunctionDecl(self: *Parser, is_async: bool) ParseError!*Node {
        const start = self.pos;
        if (is_async) _ = self.advance(); // async
        _ = self.advance(); // function
        const is_gen = self.match(.star); // `function*` / `async function*`
        const name_tok = self.advance();
        if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
        const params = try self.parseParamList();
        const body = try self.parseFnBody(is_gen, is_async);
        if (self.last_fn_strict) try validateStrictParams(params);
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name_tok.text, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = self.last_fn_strict };
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
                name = self.advance().text;
            }
        }
        const params = try self.parseParamList();
        const body = try self.parseFnBody(is_gen, is_async);
        if (self.last_fn_strict) try validateStrictParams(params);
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = self.last_fn_strict };
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
        self.in_generator = is_gen;
        self.in_async = is_async;
        // A function body opens a fresh control-flow context: `return` is now
        // legal and `break`/`continue` can't target an outer loop/switch.
        self.fn_depth += 1;
        self.iter_depth = 0;
        self.switch_depth = 0;
        // A function is strict if it lexically inherits strictness or its own
        // body opens with a `"use strict"` directive prologue. Detect it up
        // front so nested functions parsed within inherit correctly.
        self.strict = saved_strict or self.peekUseStrict();
        self.last_fn_strict = self.strict;
        defer {
            self.in_generator = saved_gen;
            self.in_async = saved_async;
            self.strict = saved_strict;
            self.fn_depth -= 1;
            self.iter_depth = saved_iter;
            self.switch_depth = saved_switch;
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
            if (std.mem.eql(u8, self.tokens[i].text, "use strict")) return true;
            i += 1;
            if (i < self.tokens.len and self.tokens[i].kind == .semicolon) i += 1;
        }
        return false;
    }

    /// `yield [expr]` / `yield* expr`. Only reached inside a generator body.
    fn parseYield(self: *Parser) ParseError!*Node {
        _ = self.advance(); // yield
        const delegate = self.match(.star);
        var arg: ?*Node = null;
        // A bare `yield` (no operand) is allowed before a terminator; `yield*`
        // always takes an operand.
        if (delegate or self.startsExpression()) arg = try self.parseAssignment();
        return self.alloc(.{ .yield_expr = .{ .argument = arg, .delegate = delegate } });
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
        if (isKeyword(self.cur(), "async")) {
            const start = self.pos;
            if (self.peekKind(1) == .identifier and self.peekKind(2) == .arrow and !isReservedWord(self.tokens[self.pos + 1].text)) {
                _ = self.advance(); // async
                const param = self.advance().text;
                const params = try self.arena.dupe(ast.Param, &.{.{ .name = param }});
                return self.parseArrowBody(params, true, start);
            }
            if (self.peekKind(1) == .lparen and self.arrowAheadAt(self.pos + 1)) {
                _ = self.advance(); // async
                const params = try self.parseParamList();
                return self.parseArrowBody(params, true, start);
            }
        }
        // Arrow functions: `x => ...` and `(a, b) => ...`.
        if (self.check(.identifier) and self.peekKind(1) == .arrow) {
            const start = self.pos;
            const param = self.advance().text;
            const params = try self.arena.dupe(ast.Param, &.{.{ .name = param }});
            return self.parseArrowBody(params, false, start);
        }
        if (self.check(.lparen) and self.arrowAhead()) {
            const start = self.pos;
            const params = try self.parseParamList();
            return self.parseArrowBody(params, false, start);
        }

        const left = try self.parseConditional();
        if (self.check(.assign)) {
            // An array/object literal on the LHS is a destructuring pattern.
            const target = switch (left.*) {
                .identifier, .member, .super_member => left,
                .array_lit, .object_lit => try self.litToPattern(left),
                else => return ParseError.InvalidAssignmentTarget,
            };
            // Strict mode forbids assigning to `eval`/`arguments`.
            if (self.strict and target.* == .identifier and isEvalOrArguments(target.identifier))
                return ParseError.UnexpectedToken;
            _ = self.advance();
            const value = try self.parseAssignment();
            if (target.* == .identifier) nameAnon(value, target.identifier); // `f = function(){}`
            return self.alloc(.{ .assign = .{ .target = target, .value = value } });
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
            if (left.* != .identifier and left.* != .member and left.* != .super_member) return ParseError.InvalidAssignmentTarget;
            if (self.strict and left.* == .identifier and isEvalOrArguments(left.identifier))
                return ParseError.UnexpectedToken;
            _ = self.advance();
            const rhs = try self.parseAssignment();
            const bin = try self.alloc(.{ .binary = .{ .op = op, .left = left, .right = rhs } });
            return self.alloc(.{ .assign = .{ .target = left, .value = bin } });
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
            _ = self.advance();
            const rhs = try self.parseAssignment();
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
        if (!isKeyword(self.cur(), "async")) return false;
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

    fn parseArrowBody(self: *Parser, params: []const ast.Param, is_async: bool, start: usize) ParseError!*Node {
        try self.expect(.arrow);
        const fnode = try self.arena.create(ast.FunctionNode);
        // An arrow's body opens its own async context (so `await` inside an
        // `async () => …` is recognized), restored on exit.
        const saved_async = self.in_async;
        const saved_strict = self.strict;
        const saved_iter = self.iter_depth;
        const saved_switch = self.switch_depth;
        self.in_async = is_async;
        self.fn_depth += 1;
        self.iter_depth = 0;
        self.switch_depth = 0;
        defer {
            self.in_async = saved_async;
            self.strict = saved_strict;
            self.fn_depth -= 1;
            self.iter_depth = saved_iter;
            self.switch_depth = saved_switch;
        }
        if (self.check(.lbrace)) {
            self.strict = saved_strict or self.peekUseStrict();
            fnode.* = .{ .params = params, .body = try self.parseBlock(), .is_expr_body = false, .is_arrow = true, .is_async = is_async, .is_strict = self.strict };
        } else {
            fnode.* = .{ .params = params, .body = try self.parseAssignment(), .is_expr_body = true, .is_arrow = true, .is_async = is_async, .is_strict = saved_strict };
        }
        fnode.source = self.sourceFrom(start);
        return self.alloc(.{ .function = fnode });
    }

    fn parseConditional(self: *Parser) ParseError!*Node {
        const cond = try self.parseBinary(0);
        if (self.match(.question)) {
            const cons = try self.parseAssignment();
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
        if (isKeyword(self.cur(), "in")) return .{ .bp = 7, .binary = .in_op };
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
        // `in` (a private brand check). Represent it as an identifier whose text
        // keeps the leading `#` so the interpreter can recognize it.
        var left = if (self.in_class and self.check(.private_name) and self.peekIsKeyword(1, "in"))
            try self.alloc(.{ .identifier = self.advance().text })
        else
            try self.parseUnary();
        while (self.curBinInfo()) |info| {
            if (info.bp < min_bp) break;
            _ = self.advance();
            const next_min: u8 = if (info.right_assoc) info.bp else info.bp + 1;
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
        if (self.in_async and isKeyword(self.cur(), "await")) {
            _ = self.advance();
            return self.alloc(.{ .await_expr = .{ .argument = try self.parseUnary() } });
        }
        if (self.check(.plus_plus) or self.check(.minus_minus)) {
            const inc = self.cur().kind == .plus_plus;
            _ = self.advance();
            const operand = try self.parseUnary();
            // The operand of a prefix `++`/`--` must be a simple assignment
            // target (identifier or member access) — `++import(x)`, `++f()`,
            // `++1` are early SyntaxErrors.
            if (operand.* != .identifier and operand.* != .member and operand.* != .super_member)
                return ParseError.InvalidAssignmentTarget;
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
            return self.alloc(.{ .unary = .{ .op = o, .operand = operand } });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*Node {
        const e = try self.parsePrimary();
        const m = try self.parseMemberTail(e);
        if (self.check(.plus_plus) or self.check(.minus_minus)) {
            // A postfix `++`/`--` target must be a simple assignment target —
            // `import(x)++`, `f()++`, `1++` are early SyntaxErrors.
            if (m.* != .identifier and m.* != .member and m.* != .super_member)
                return ParseError.InvalidAssignmentTarget;
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
                e = try self.alloc(.{ .member = .{ .object = e, .property = name.text } });
            } else if (self.match(.question_dot)) {
                has_optional = true;
                if (self.check(.lparen)) {
                    const args = try self.parseArgs();
                    e = try self.alloc(.{ .call = .{ .callee = e, .args = args, .optional = true } });
                } else if (self.match(.lbracket)) {
                    const idx = try self.parseExpression();
                    try self.expect(.rbracket);
                    e = try self.alloc(.{ .member = .{ .object = e, .computed = idx, .optional = true } });
                } else {
                    const name = self.advance();
                    if (name.kind != .identifier) return ParseError.UnexpectedToken;
                    e = try self.alloc(.{ .member = .{ .object = e, .property = name.text, .optional = true } });
                }
            } else if (self.match(.lbracket)) {
                const idx = try self.parseExpression();
                try self.expect(.rbracket);
                e = try self.alloc(.{ .member = .{ .object = e, .computed = idx } });
            } else if (self.check(.lparen)) {
                const args = try self.parseArgs();
                e = try self.alloc(.{ .call = .{ .callee = e, .args = args } });
            } else if (self.check(.template)) {
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
        // `new.target` meta-property.
        if (self.match(.dot)) {
            const m = self.advance();
            if (m.kind != .identifier or !std.mem.eql(u8, m.text, "target")) return ParseError.UnexpectedToken;
            return self.alloc(.new_target_expr);
        }
        var callee = try self.parsePrimary();
        // `new import(...)` is a SyntaxError: an ImportCall is a CallExpression,
        // not a valid MemberExpression operand for `new`. (`import.meta` parses to
        // `.import_meta`, so `new import.meta.x()` is unaffected.)
        if (callee.* == .import_call) return ParseError.UnexpectedToken;
        while (true) {
            if (self.match(.dot)) {
                const name = self.advance();
                if (name.kind != .identifier) return ParseError.UnexpectedToken;
                callee = try self.alloc(.{ .member = .{ .object = callee, .property = name.text } });
            } else if (self.match(.lbracket)) {
                const idx = try self.parseExpression();
                try self.expect(.rbracket);
                callee = try self.alloc(.{ .member = .{ .object = callee, .computed = idx } });
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
                i = try lex.appendEscape(self.arena, &lit, raw, i + 1);
            } else if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                // Flush the literal run so far, then parse the substitution.
                node = try self.concatStr(node, lit.items);
                lit = .empty;
                const expr_start = i + 2;
                const expr_end = substEnd(raw, expr_start);
                var sub = try Parser.init(self.arena, raw[expr_start..expr_end]);
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
        var cooked: std.ArrayListUnmanaged([]const u8) = .empty;
        var raws: std.ArrayListUnmanaged([]const u8) = .empty;
        var exprs: std.ArrayListUnmanaged(*Node) = .empty;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var raw_start: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                i = try lex.appendEscape(self.arena, &buf, raw, i + 1);
            } else if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                try cooked.append(self.arena, try buf.toOwnedSlice(self.arena));
                try raws.append(self.arena, raw[raw_start..i]);
                buf = .empty;
                const expr_start = i + 2;
                const expr_end = substEnd(raw, expr_start);
                var sub = try Parser.init(self.arena, raw[expr_start..expr_end]);
                try exprs.append(self.arena, try sub.parseExpression());
                i = if (expr_end < raw.len) expr_end + 1 else expr_end; // skip `}`
                raw_start = i;
            } else {
                try buf.append(self.arena, c);
                i += 1;
            }
        }
        try cooked.append(self.arena, try buf.toOwnedSlice(self.arena));
        try raws.append(self.arena, raw[raw_start..]);
        return self.alloc(.{ .tagged_template = .{ .tag = tag, .cooked = cooked.items, .raw = raws.items, .exprs = exprs.items } });
    }

    fn concatStr(self: *Parser, node: ?*Node, bytes: []const u8) ParseError!*Node {
        const s = try self.alloc(.{ .string = try self.arena.dupe(u8, bytes) });
        if (node) |n| return self.alloc(.{ .binary = .{ .op = .add, .left = n, .right = s } });
        return s;
    }

    fn concatExpr(self: *Parser, node: ?*Node, expr: *Node) ParseError!*Node {
        if (node) |n| return self.alloc(.{ .binary = .{ .op = .add, .left = n, .right = expr } });
        return expr;
    }

    fn parseObjectLiteral(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
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
            if (!async_method and !gen_method and (isKeyword(self.cur(), "get") or isKeyword(self.cur(), "set")) and self.propNameAhead()) {
                const kind: ast.AccessorKind = if (isKeyword(self.cur(), "get")) .get else .set;
                _ = self.advance(); // get/set
                const pn = try self.parsePropertyName();
                const func = try self.parseMethodTail(pn.key, false, false, member_start);
                try validateAccessor(func, kind);
                try props.append(self.arena, .{ .key = pn.key, .key_expr = pn.expr, .value = func, .accessor = kind });
                if (!self.match(.comma)) break;
                continue;
            }
            const key_tok = self.advance();
            const key: []const u8 = switch (key_tok.kind) {
                .identifier, .string => key_tok.text,
                .number => try std.fmt.allocPrint(self.arena, "{d}", .{key_tok.number}),
                else => return ParseError.UnexpectedToken,
            };
            var val: *Node = undefined;
            if (self.check(.lparen)) {
                // Method shorthand `{ m(args) { ... } }` -> a function value.
                val = try self.parseMethodTail(key, gen_method, async_method, member_start);
            } else if (self.match(.colon)) {
                val = try self.parseAssignment();
                nameAnon(val, key); // `{ m: function(){} }` ⇒ name "m"
            } else if (key_tok.kind == .identifier) {
                const ident = try self.alloc(.{ .identifier = key });
                // Shorthand `{ a }`, or `{ a = default }` (a destructuring
                // default surfaced via the cover grammar).
                if (self.match(.assign)) {
                    val = try self.alloc(.{ .assign = .{ .target = ident, .value = try self.parseAssignment() } });
                } else {
                    val = ident;
                }
            } else return ParseError.ExpectedToken;
            try props.append(self.arena, .{ .key = key, .value = val });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .object_lit = props.items });
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
        if (self.match(.dot)) {
            const m = self.advance();
            if (m.kind != .identifier) return ParseError.UnexpectedToken;
            // `import.meta` — meta-property. `import.source(x)` / `import.defer(x)`
            // — the source-phase-import / import-defer proposals; parse them as a
            // phased dynamic import (the phase doesn't change the AST here).
            if (std.mem.eql(u8, m.text, "meta")) return self.alloc(.import_meta);
            if (std.mem.eql(u8, m.text, "source") or std.mem.eql(u8, m.text, "defer")) {
                // fall through to the call form below.
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
        return self.alloc(.{ .import_call = .{ .specifier = spec, .options = options } });
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
            .number => try std.fmt.allocPrint(self.arena, "{d}", .{t.number}),
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
        var name: []const u8 = "";
        if (self.check(.identifier) and !isKeyword(self.cur(), "extends")) name = self.advance().text;
        var superclass: ?*Node = null;
        if (isKeyword(self.cur(), "extends")) {
            _ = self.advance();
            // Superclass is a LeftHandSide expression (allow member/call chains).
            superclass = try self.parseUnary();
        }
        try self.expect(.lbrace);
        // Class bodies are always strict mode; members inherit it via `self.strict`.
        const saved_strict = self.strict;
        self.strict = true;
        defer self.strict = saved_strict;
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
            if (isKeyword(self.cur(), "static") and self.peekKind(1) != .lparen and self.peekKind(1) != .assign) {
                is_static = true;
                _ = self.advance();
            }
            // `static { ... }` initialization block.
            if (is_static and self.check(.lbrace)) {
                const block = try self.parseBlock();
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
            // Accessor: `get x() {}` / `set x(v) {}`.
            if (!async_method and !gen_method and (isKeyword(self.cur(), "get") or isKeyword(self.cur(), "set")) and self.propNameAhead()) {
                const kind: ast.AccessorKind = if (isKeyword(self.cur(), "get")) .get else .set;
                _ = self.advance(); // get/set
                const apn = try self.parsePropertyName();
                const func = try self.parseMethodTail(apn.key, false, false, member_start);
                try validateAccessor(func, kind);
                try members.append(self.arena, .{ .key = apn.key, .key_expr = apn.expr, .func = func, .is_static = is_static, .accessor = kind });
                continue;
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
                _ = self.match(.semicolon);
                try members.append(self.arena, .{ .key = pn.key, .key_expr = pn.expr, .field_init = init_expr, .is_static = is_static, .is_field = true });
            }
        }
        try self.expect(.rbrace);
        try self.checkPrivateNames(members.items);
        return self.alloc(.{ .class_expr = .{ .name = name, .superclass = superclass, .members = members.items, .source = self.sourceFrom(start) } });
    }

    /// Early error: a class may not declare the same private name twice, except
    /// for a single `get`/`set` pair at the same placement (both static or both
    /// instance). Any other repeat — get/get, set/set, method/method,
    /// field/anything, or a get+set split across static and instance — is a
    /// SyntaxError.
    fn checkPrivateNames(self: *Parser, members: []const ast.ClassMember) ParseError!void {
        for (members, 0..) |m, i| {
            if (m.key_expr != null or m.key.len == 0 or m.key[0] != '#') continue;
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

    /// Parse `(params) { body }` after a method name, returning a function node.
    /// `is_gen` marks a generator method (`*m() {}`).
    fn parseMethodTail(self: *Parser, name: []const u8, is_gen: bool, is_async: bool, start: usize) ParseError!*Node {
        const params = try self.parseParamList();
        const body = try self.parseFnBody(is_gen, is_async);
        if (self.last_fn_strict) try validateStrictParams(params);
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = self.last_fn_strict };
        return self.alloc(.{ .function = fnode });
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        try self.expect(.lbracket);
        var elems: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            // Elision / hole: a bare `,` yields an empty slot (v1: undefined, as
            // arrays are dense). `[ , x ]`, `[1, , 3]`, `[,]`.
            if (self.check(.comma)) {
                try elems.append(self.arena, try self.alloc(.elision));
                _ = self.advance();
                continue;
            }
            try elems.append(self.arena, try self.parseSpreadable());
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbracket);
        return self.alloc(.{ .array_lit = elems.items });
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.check(.identifier)) {
            const w = self.cur().text;
            if (std.mem.eql(u8, w, "function")) return self.parseFunctionExpr(false);
            if (std.mem.eql(u8, w, "async") and self.peekIsKeyword(1, "function")) return self.parseFunctionExpr(true);
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
                if (t.is_bigint) return self.alloc(.{ .bigint_lit = t.bigint });
                return self.alloc(.{ .number = t.number });
            },
            .string => return self.alloc(.{ .string = t.text }),
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
                const e = try self.parseExpression();
                try self.expect(.rparen);
                return e;
            },
            .identifier => {
                if (std.mem.eql(u8, t.text, "true")) return self.alloc(.{ .boolean = true });
                if (std.mem.eql(u8, t.text, "false")) return self.alloc(.{ .boolean = false });
                if (std.mem.eql(u8, t.text, "null")) return self.alloc(.null_lit);
                if (std.mem.eql(u8, t.text, "undefined")) return self.alloc(.undefined_lit);
                if (std.mem.eql(u8, t.text, "this")) return self.alloc(.this_expr);
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
