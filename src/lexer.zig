const std = @import("std");

pub const TokenKind = enum {
    eof,
    number,
    string,
    template, // `...${expr}...` — `text` is the raw inner source (between backticks)
    regex, // /pattern/flags — `text` is the pattern, `flags` the flag chars
    private_name, // #ident (class private member); `text` includes the `#`
    identifier,
    // punctuation / operators
    plus,
    minus,
    star,
    star_star,
    slash,
    percent,
    plus_plus,
    minus_minus,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    star_star_eq, // **=
    shl_eq, // <<=
    shr_eq, // >>=
    ushr_eq, // >>>=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    qq, // ??
    question_dot, // ?.
    amp_amp_eq, // &&=
    pipe_pipe_eq, // ||=
    qq_eq, // ??=
    assign,
    eq, // ==
    eq_strict, // ===
    neq, // !=
    neq_strict, // !==
    lt,
    le,
    gt,
    ge,
    bang,
    amp_amp,
    pipe_pipe,
    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    shl, // <<
    shr, // >>
    ushr, // >>>
    question,
    colon,
    semicolon,
    comma,
    dot,
    ellipsis, // ...
    arrow, // =>
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
};

pub const Token = struct {
    kind: TokenKind,
    /// Slice into the original source for identifiers/strings (decoded for
    /// strings) and the raw lexeme otherwise.
    text: []const u8,
    number: f64 = 0,
    /// Regex flag characters (only for `.regex` tokens).
    flags: []const u8 = "",
    pos: usize,
};

pub const LexError = error{ UnexpectedCharacter, UnterminatedString, InvalidNumber, OutOfMemory };

/// A single-pass JavaScript tokenizer for the v1 expression/statement subset.
/// String escapes are decoded into freshly allocated buffers in `arena`.
pub const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    arena: std.mem.Allocator,
    /// Previous significant token, used to disambiguate `/` (division vs the
    /// start of a regex literal).
    prev_kind: TokenKind = .eof,
    prev_text: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .arena = arena };
    }

    fn peek(self: *Lexer) u8 {
        return if (self.i < self.src.len) self.src[self.i] else 0;
    }

    fn peek2(self: *Lexer) u8 {
        return if (self.i + 1 < self.src.len) self.src[self.i + 1] else 0;
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
            } else if (c == '/' and self.peek2() == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
            } else if (c == '/' and self.peek2() == '*') {
                self.i += 2;
                while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) self.i += 1;
                self.i = @min(self.i + 2, self.src.len);
            } else break;
        }
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
    }

    fn isIdentPart(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
    }

    pub fn next(self: *Lexer) LexError!Token {
        const t = try self.nextRaw();
        self.prev_kind = t.kind;
        self.prev_text = t.text;
        return t;
    }

    /// True when a `/` here begins a regex literal rather than division — i.e.
    /// the previous token does not end an expression.
    fn regexAllowed(self: *Lexer) bool {
        return switch (self.prev_kind) {
            .number, .string, .template, .regex, .rparen, .rbracket => false,
            .identifier => isOperandKeyword(self.prev_text), // `return /re/` yes, `x / y` no
            else => true,
        };
    }

    fn nextRaw(self: *Lexer) LexError!Token {
        self.skipTrivia();
        const start = self.i;
        if (self.i >= self.src.len) return .{ .kind = .eof, .text = "", .pos = start };

        const c = self.src[self.i];

        // Numbers
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(self.peek2()))) {
            return self.lexNumber();
        }
        // Identifiers / keywords
        if (isIdentStart(c)) {
            self.i += 1;
            while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
            return .{ .kind = .identifier, .text = self.src[start..self.i], .pos = start };
        }
        // Private names (#ident) for class private members.
        if (c == '#' and isIdentStart(self.peek2())) {
            self.i += 1; // '#'
            while (self.i < self.src.len and isIdentPart(self.src[self.i])) self.i += 1;
            return .{ .kind = .private_name, .text = self.src[start..self.i], .pos = start };
        }
        // Strings
        if (c == '"' or c == '\'') return self.lexString();
        // Template literals
        if (c == '`') return self.lexTemplate();

        // Operators / punctuation
        self.i += 1;
        switch (c) {
            '+' => {
                if (self.peek() == '+') {
                    self.i += 1;
                    return tok(.plus_plus, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.plus_eq, self.src[start..self.i], start);
                }
                return tok(.plus, self.src[start..self.i], start);
            },
            '-' => {
                if (self.peek() == '-') {
                    self.i += 1;
                    return tok(.minus_minus, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.minus_eq, self.src[start..self.i], start);
                }
                return tok(.minus, self.src[start..self.i], start);
            },
            '*' => {
                if (self.peek() == '*') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.star_star_eq, self.src[start..self.i], start);
                    }
                    return tok(.star_star, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.star_eq, self.src[start..self.i], start);
                }
                return tok(.star, self.src[start..self.i], start);
            },
            '/' => {
                // Regex literal where an expression is expected.
                if (self.regexAllowed()) {
                    self.i = start; // rewind to the opening `/`
                    return self.lexRegex();
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.slash_eq, self.src[start..self.i], start);
                }
                return tok(.slash, self.src[start..self.i], start);
            },
            '%' => {
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.percent_eq, self.src[start..self.i], start);
                }
                return tok(.percent, self.src[start..self.i], start);
            },
            '(' => return tok(.lparen, self.src[start..self.i], start),
            ')' => return tok(.rparen, self.src[start..self.i], start),
            '{' => return tok(.lbrace, self.src[start..self.i], start),
            '}' => return tok(.rbrace, self.src[start..self.i], start),
            '[' => return tok(.lbracket, self.src[start..self.i], start),
            ']' => return tok(.rbracket, self.src[start..self.i], start),
            ';' => return tok(.semicolon, self.src[start..self.i], start),
            ',' => return tok(.comma, self.src[start..self.i], start),
            '.' => {
                if (self.peek() == '.' and self.peek2() == '.') {
                    self.i += 2;
                    return tok(.ellipsis, self.src[start..self.i], start);
                }
                return tok(.dot, self.src[start..self.i], start);
            },
            '?' => {
                if (self.peek() == '?') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.qq_eq, self.src[start..self.i], start);
                    }
                    return tok(.qq, self.src[start..self.i], start);
                }
                // `?.` optional chaining — but `?.5` is the conditional `?` then `.5`.
                if (self.peek() == '.' and !std.ascii.isDigit(self.peek2())) {
                    self.i += 1;
                    return tok(.question_dot, self.src[start..self.i], start);
                }
                return tok(.question, self.src[start..self.i], start);
            },
            ':' => return tok(.colon, self.src[start..self.i], start),
            '<' => {
                if (self.peek() == '<') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.shl_eq, self.src[start..self.i], start);
                    }
                    return tok(.shl, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.le, self.src[start..self.i], start);
                }
                return tok(.lt, self.src[start..self.i], start);
            },
            '>' => {
                if (self.peek() == '>') {
                    self.i += 1;
                    if (self.peek() == '>') {
                        self.i += 1;
                        if (self.peek() == '=') {
                            self.i += 1;
                            return tok(.ushr_eq, self.src[start..self.i], start);
                        }
                        return tok(.ushr, self.src[start..self.i], start);
                    }
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.shr_eq, self.src[start..self.i], start);
                    }
                    return tok(.shr, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.ge, self.src[start..self.i], start);
                }
                return tok(.gt, self.src[start..self.i], start);
            },
            '=' => {
                if (self.peek() == '>') {
                    self.i += 1;
                    return tok(.arrow, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.eq_strict, self.src[start..self.i], start);
                    }
                    return tok(.eq, self.src[start..self.i], start);
                }
                return tok(.assign, self.src[start..self.i], start);
            },
            '!' => {
                if (self.peek() == '=') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.neq_strict, self.src[start..self.i], start);
                    }
                    return tok(.neq, self.src[start..self.i], start);
                }
                return tok(.bang, self.src[start..self.i], start);
            },
            '&' => {
                if (self.peek() == '&') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.amp_amp_eq, self.src[start..self.i], start);
                    }
                    return tok(.amp_amp, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.amp_eq, self.src[start..self.i], start);
                }
                return tok(.amp, self.src[start..self.i], start);
            },
            '|' => {
                if (self.peek() == '|') {
                    self.i += 1;
                    if (self.peek() == '=') {
                        self.i += 1;
                        return tok(.pipe_pipe_eq, self.src[start..self.i], start);
                    }
                    return tok(.pipe_pipe, self.src[start..self.i], start);
                }
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.pipe_eq, self.src[start..self.i], start);
                }
                return tok(.pipe, self.src[start..self.i], start);
            },
            '^' => {
                if (self.peek() == '=') {
                    self.i += 1;
                    return tok(.caret_eq, self.src[start..self.i], start);
                }
                return tok(.caret, self.src[start..self.i], start);
            },
            '~' => return tok(.tilde, self.src[start..self.i], start),
            else => return LexError.UnexpectedCharacter,
        }
    }

    fn lexNumber(self: *Lexer) LexError!Token {
        const start = self.i;
        // Radix prefixes: 0x / 0o / 0b (digits may use `_` separators).
        if (self.peek() == '0' and self.peek2() != 0) {
            const radix: ?u8 = switch (self.peek2()) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                'b', 'B' => 2,
                else => null,
            };
            if (radix) |r| {
                self.i += 2;
                const ds = self.i;
                while (self.i < self.src.len and (isRadixDigit(self.src[self.i], r) or self.src[self.i] == '_')) self.i += 1;
                const cleaned = try stripSeparators(self.arena, self.src[ds..self.i]);
                const n = std.fmt.parseInt(u128, cleaned, r) catch return LexError.InvalidNumber;
                if (self.peek() == 'n') self.i += 1; // BigInt suffix: treated as a number for v1
                return .{ .kind = .number, .text = self.src[start..self.i], .number = @floatFromInt(n), .pos = start };
            }
        }
        while (self.i < self.src.len and (std.ascii.isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
        if (self.peek() == '.') {
            self.i += 1;
            while (self.i < self.src.len and (std.ascii.isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            self.i += 1;
            if (self.peek() == '+' or self.peek() == '-') self.i += 1;
            while (self.i < self.src.len and (std.ascii.isDigit(self.src[self.i]) or self.src[self.i] == '_')) self.i += 1;
        }
        if (self.peek() == 'n') self.i += 1; // BigInt suffix → number for v1
        const cleaned = try stripSeparators(self.arena, self.src[start..self.i]);
        const n = std.fmt.parseFloat(f64, cleaned) catch return LexError.InvalidNumber;
        return .{ .kind = .number, .text = self.src[start..self.i], .number = n, .pos = start };
    }

    fn lexString(self: *Lexer) LexError!Token {
        const start = self.i;
        const quote = self.src[self.i];
        self.i += 1;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == quote) {
                self.i += 1;
                return .{ .kind = .string, .text = try buf.toOwnedSlice(self.arena), .pos = start };
            }
            if (ch == '\\') {
                self.i += 1;
                if (self.i >= self.src.len) return LexError.UnterminatedString;
                const esc = self.src[self.i];
                const decoded: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    '\\' => '\\',
                    '\'' => '\'',
                    '"' => '"',
                    '`' => '`',
                    else => esc,
                };
                try buf.append(self.arena, decoded);
                self.i += 1;
            } else {
                try buf.append(self.arena, ch);
                self.i += 1;
            }
        }
        return LexError.UnterminatedString;
    }

    /// Scan a `` `...` `` template, returning a token whose `text` is the raw
    /// inner source (still containing `${...}` and escapes — the parser splits
    /// and decodes it). Tracks `${ }` brace depth and skips quoted strings so
    /// braces inside a substitution or a string don't end the template early.
    fn lexTemplate(self: *Lexer) LexError!Token {
        const start = self.i;
        self.i += 1; // opening backtick
        const text_start = self.i;
        var depth: usize = 0; // brace depth inside ${ ... }
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (depth == 0) {
                if (c == '`') {
                    const text = self.src[text_start..self.i];
                    self.i += 1; // closing backtick
                    return .{ .kind = .template, .text = text, .pos = start };
                }
                if (c == '\\') {
                    self.i += 2; // escaped char (\` \$ \\ ...)
                    continue;
                }
                if (c == '$' and self.peek2() == '{') {
                    depth = 1;
                    self.i += 2;
                    continue;
                }
                self.i += 1;
            } else {
                switch (c) {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    '\'', '"' => {
                        self.skipStringLiteral(c);
                        continue;
                    },
                    '\\' => self.i += 1,
                    else => {},
                }
                self.i += 1;
            }
        }
        return LexError.UnterminatedString;
    }

    /// Scan `/pattern/flags`. `text` is the pattern (between the slashes,
    /// escapes kept raw), `flags` the trailing flag chars.
    fn lexRegex(self: *Lexer) LexError!Token {
        const start = self.i;
        self.i += 1; // opening /
        const pat_start = self.i;
        var in_class = false;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\n') return LexError.UnterminatedString;
            if (c == '\\') {
                self.i += 2;
                continue;
            }
            if (c == '[') {
                in_class = true;
            } else if (c == ']') {
                in_class = false;
            } else if (c == '/' and !in_class) {
                break;
            }
            self.i += 1;
        }
        if (self.i >= self.src.len) return LexError.UnterminatedString;
        const pattern = self.src[pat_start..self.i];
        self.i += 1; // closing /
        const flags_start = self.i;
        while (self.i < self.src.len and std.ascii.isAlphabetic(self.src[self.i])) self.i += 1;
        return .{ .kind = .regex, .text = pattern, .flags = self.src[flags_start..self.i], .pos = start };
    }

    /// Advance past a quoted string starting at `self.i` (whose char is `quote`),
    /// honoring backslash escapes. Used while scanning inside `${ ... }`.
    fn skipStringLiteral(self: *Lexer, quote: u8) void {
        self.i += 1; // opening quote
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\\') {
                self.i += 2;
                continue;
            }
            self.i += 1;
            if (c == quote) return;
        }
    }
};

fn tok(kind: TokenKind, text: []const u8, pos: usize) Token {
    return .{ .kind = kind, .text = text, .pos = pos };
}

fn isRadixDigit(c: u8, radix: u8) bool {
    const v: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return false,
    };
    return v < radix;
}

/// Strip `_` numeric separators, trimming a trailing BigInt `n` too. Returns a
/// slice safe to hand to `parseInt`/`parseFloat`.
fn stripSeparators(arena: std.mem.Allocator, s: []const u8) LexError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '_') == null and (s.len == 0 or s[s.len - 1] != 'n')) return s;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '_' or c == 'n') continue;
        try buf.append(arena, c);
    }
    return buf.toOwnedSlice(arena);
}

/// Keywords after which a `/` begins a regex (they expect an operand).
fn isOperandKeyword(text: []const u8) bool {
    const words = [_][]const u8{
        "return", "typeof", "instanceof", "in",    "of",    "new",
        "delete", "void",   "throw",      "case",  "do",    "else",
        "yield",  "await",  "default",
    };
    for (words) |w| {
        if (std.mem.eql(u8, text, w)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lexer tokenizes arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "1 + 2 * 3");
    try std.testing.expectEqual(@as(f64, 1), (try lx.next()).number);
    try std.testing.expectEqual(TokenKind.plus, (try lx.next()).kind);
    try std.testing.expectEqual(@as(f64, 2), (try lx.next()).number);
    try std.testing.expectEqual(TokenKind.star, (try lx.next()).kind);
    try std.testing.expectEqual(@as(f64, 3), (try lx.next()).number);
    try std.testing.expectEqual(TokenKind.eof, (try lx.next()).kind);
}

test "lexer decodes string escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "'a\\nb'");
    const t = try lx.next();
    try std.testing.expectEqual(TokenKind.string, t.kind);
    try std.testing.expectEqualStrings("a\nb", t.text);
}

test "lexer handles multi-char operators and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "a === b // trailing\n!== c");
    try std.testing.expectEqual(TokenKind.identifier, (try lx.next()).kind);
    try std.testing.expectEqual(TokenKind.eq_strict, (try lx.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lx.next()).kind);
    try std.testing.expectEqual(TokenKind.neq_strict, (try lx.next()).kind);
    try std.testing.expectEqual(TokenKind.identifier, (try lx.next()).kind);
}
