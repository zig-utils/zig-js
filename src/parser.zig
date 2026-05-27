const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("ast.zig");

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

    pub fn init(arena: std.mem.Allocator, source: []const u8) ParseError!Parser {
        var lx = lex.Lexer.init(arena, source);
        var list: std.ArrayListUnmanaged(Token) = .empty;
        while (true) {
            const t = try lx.next();
            try list.append(arena, t);
            if (t.kind == .eof) break;
        }
        return .{ .tokens = list.items, .arena = arena };
    }

    fn cur(self: *Parser) Token {
        return self.tokens[self.pos];
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

    fn alloc(self: *Parser, node: Node) ParseError!*Node {
        const p = try self.arena.create(Node);
        p.* = node;
        return p;
    }

    // ----- program / statements -------------------------------------------

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.eof)) {
            try stmts.append(self.arena, try self.parseStatement());
        }
        return self.alloc(.{ .program = stmts.items });
    }

    fn parseStatement(self: *Parser) ParseError!*Node {
        const t = self.cur();
        if (t.kind == .identifier) {
            if (std.mem.eql(u8, t.text, "var")) return self.parseVarDecl(.@"var");
            if (std.mem.eql(u8, t.text, "let")) return self.parseVarDecl(.let);
            if (std.mem.eql(u8, t.text, "const")) return self.parseVarDecl(.@"const");
            if (std.mem.eql(u8, t.text, "if")) return self.parseIf();
            if (std.mem.eql(u8, t.text, "while")) return self.parseWhile();
            if (std.mem.eql(u8, t.text, "function")) return self.parseFunctionDecl();
            if (std.mem.eql(u8, t.text, "return")) return self.parseReturn();
        }
        if (t.kind == .lbrace) return self.parseBlock();

        const expr = try self.parseExpression();
        _ = self.match(.semicolon);
        return self.alloc(.{ .expr_stmt = expr });
    }

    fn parseVarDecl(self: *Parser, kind: ast.DeclKind) ParseError!*Node {
        _ = self.advance(); // var/let/const
        const name_tok = self.advance();
        if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
        var init_expr: ?*Node = null;
        if (self.match(.assign)) {
            init_expr = try self.parseAssignment();
        }
        _ = self.match(.semicolon);
        return self.alloc(.{ .var_decl = .{ .kind = kind, .name = name_tok.text, .init = init_expr } });
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

    fn parseWhile(self: *Parser) ParseError!*Node {
        _ = self.advance(); // while
        try self.expect(.lparen);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseStatement();
        return self.alloc(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseReturn(self: *Parser) ParseError!*Node {
        _ = self.advance(); // return
        var arg: ?*Node = null;
        if (!self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof)) {
            arg = try self.parseExpression();
        }
        _ = self.match(.semicolon);
        return self.alloc(.{ .return_stmt = arg });
    }

    /// Parse `(p1, p2, ...)` into a slice of identifier names.
    fn parseParamList(self: *Parser) ParseError![]const []const u8 {
        try self.expect(.lparen);
        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            const p = self.advance();
            if (p.kind != .identifier) return ParseError.UnexpectedToken;
            try params.append(self.arena, p.text);
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return params.items;
    }

    fn parseFunctionDecl(self: *Parser) ParseError!*Node {
        _ = self.advance(); // function
        const name_tok = self.advance();
        if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
        const params = try self.parseParamList();
        const body = try self.parseBlock();
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name_tok.text, .params = params, .body = body, .is_expr_body = false };
        return self.alloc(.{ .func_decl = fnode });
    }

    /// `function [name](params) { body }` in expression position.
    fn parseFunctionExpr(self: *Parser) ParseError!*Node {
        _ = self.advance(); // function
        var name: []const u8 = "";
        if (self.check(.identifier) and !std.mem.eql(u8, self.cur().text, "")) {
            // Optional name (anything that isn't the opening paren).
            if (!self.check(.lparen)) {
                name = self.advance().text;
            }
        }
        const params = try self.parseParamList();
        const body = try self.parseBlock();
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .is_expr_body = false };
        return self.alloc(.{ .function = fnode });
    }

    // ----- expressions ----------------------------------------------------

    fn parseExpression(self: *Parser) ParseError!*Node {
        return self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) ParseError!*Node {
        // Arrow functions: `x => ...` and `(a, b) => ...`.
        if (self.check(.identifier) and self.peekKind(1) == .arrow) {
            const param = self.advance().text;
            const params = try self.arena.dupe([]const u8, &.{param});
            return self.parseArrowBody(params);
        }
        if (self.check(.lparen) and self.arrowAhead()) {
            const params = try self.parseParamList();
            return self.parseArrowBody(params);
        }

        const left = try self.parseConditional();
        if (self.check(.assign)) {
            if (left.* != .identifier) return ParseError.InvalidAssignmentTarget;
            _ = self.advance();
            const value = try self.parseAssignment();
            return self.alloc(.{ .assign = .{ .name = left.identifier, .value = value } });
        }
        return left;
    }

    fn peekKind(self: *Parser, ahead: usize) TokenKind {
        const idx = self.pos + ahead;
        return if (idx < self.tokens.len) self.tokens[idx].kind else .eof;
    }

    /// Precondition: current token is `(`. Returns true if its matching `)` is
    /// immediately followed by `=>` (i.e. this is an arrow parameter list, not
    /// a parenthesized expression).
    fn arrowAhead(self: *Parser) bool {
        var depth: usize = 0;
        var i = self.pos;
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

    fn parseArrowBody(self: *Parser, params: []const []const u8) ParseError!*Node {
        try self.expect(.arrow);
        const fnode = try self.arena.create(ast.FunctionNode);
        if (self.check(.lbrace)) {
            fnode.* = .{ .params = params, .body = try self.parseBlock(), .is_expr_body = false };
        } else {
            fnode.* = .{ .params = params, .body = try self.parseAssignment(), .is_expr_body = true };
        }
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

    fn binInfo(kind: TokenKind) ?BinInfo {
        return switch (kind) {
            .pipe_pipe => .{ .bp = 3, .logical = .@"or" },
            .amp_amp => .{ .bp = 4, .logical = .@"and" },
            .eq => .{ .bp = 5, .binary = .eq },
            .neq => .{ .bp = 5, .binary = .neq },
            .eq_strict => .{ .bp = 5, .binary = .eq_strict },
            .neq_strict => .{ .bp = 5, .binary = .neq_strict },
            .lt => .{ .bp = 6, .binary = .lt },
            .le => .{ .bp = 6, .binary = .le },
            .gt => .{ .bp = 6, .binary = .gt },
            .ge => .{ .bp = 6, .binary = .ge },
            .plus => .{ .bp = 7, .binary = .add },
            .minus => .{ .bp = 7, .binary = .sub },
            .star => .{ .bp = 8, .binary = .mul },
            .slash => .{ .bp = 8, .binary = .div },
            .percent => .{ .bp = 8, .binary = .mod },
            .star_star => .{ .bp = 9, .binary = .pow, .right_assoc = true },
            else => null,
        };
    }

    fn parseBinary(self: *Parser, min_bp: u8) ParseError!*Node {
        var left = try self.parseUnary();
        while (binInfo(self.cur().kind)) |info| {
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
        const t = self.cur();
        const op: ?ast.UnaryOp = switch (t.kind) {
            .minus => .neg,
            .plus => .pos,
            .bang => .not,
            else => if (isKeyword(t, "typeof")) ast.UnaryOp.typeof else null,
        };
        if (op) |o| {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.alloc(.{ .unary = .{ .op = o, .operand = operand } });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*Node {
        var e = try self.parsePrimary();
        while (self.check(.lparen)) {
            try self.expect(.lparen);
            var args: std.ArrayListUnmanaged(*Node) = .empty;
            while (!self.check(.rparen) and !self.check(.eof)) {
                try args.append(self.arena, try self.parseAssignment());
                if (!self.match(.comma)) break;
            }
            try self.expect(.rparen);
            e = try self.alloc(.{ .call = .{ .callee = e, .args = args.items } });
        }
        return e;
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.check(.identifier) and std.mem.eql(u8, self.cur().text, "function")) {
            return self.parseFunctionExpr();
        }
        const t = self.advance();
        switch (t.kind) {
            .number => return self.alloc(.{ .number = t.number }),
            .string => return self.alloc(.{ .string = t.text }),
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
                return self.alloc(.{ .identifier = t.text });
            },
            else => return ParseError.UnexpectedToken,
        }
    }
};

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
