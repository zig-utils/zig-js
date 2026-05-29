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
    /// Byte offset just past the token's raw lexeme (the lexer cursor after the
    /// scan). Unlike `pos + text.len`, this is exact for decoded strings, so it
    /// lets callers slice the original source (e.g. `Function.prototype.toString`).
    end: usize = 0,
    /// A legacy octal (`0123`) or non-octal-decimal (`08`) integer literal —
    /// a SyntaxError in strict mode (the parser checks).
    legacy_octal: bool = false,
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
            // ASCII whitespace incl. vertical tab (0x0B) and form feed (0x0C).
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0B or c == 0x0C) {
                self.i += 1;
            } else if (c == '/' and self.peek2() == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
            } else if (c == '/' and self.peek2() == '*') {
                self.i += 2;
                while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) self.i += 1;
                self.i = @min(self.i + 2, self.src.len);
            } else if (c >= 0x80) {
                // Unicode whitespace (NBSP, U+2000–200A, …) or line terminators
                // (U+2028/U+2029) and the BOM are all trivia between tokens.
                const len = std.unicode.utf8ByteSequenceLength(c) catch break;
                if (self.i + len > self.src.len) break;
                const cp = std.unicode.utf8Decode(self.src[self.i .. self.i + len]) catch break;
                if (isSpaceCp(cp) or isLineTermCp(cp)) {
                    self.i += len;
                } else break;
            } else break;
        }
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
    }

    fn isIdentPart(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
    }

    /// ECMAScript WhiteSpace code points (TAB/VT/FF/SP handled as ASCII above)
    /// plus the BOM, which the spec treats as white space.
    fn isSpaceCp(cp: u21) bool {
        return switch (cp) {
            0x0009, 0x000B, 0x000C, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
            else => false,
        };
    }

    /// ECMAScript LineTerminator code points.
    fn isLineTermCp(cp: u21) bool {
        return cp == 0x000A or cp == 0x000D or cp == 0x2028 or cp == 0x2029;
    }

    /// IdentifierStart test for a decoded code point. Exact for ASCII; for
    /// non-ASCII it admits any code point that is not white space, a line
    /// terminator, a zero-width joiner (those are continue-only), or the BOM —
    /// which covers every Unicode letter test262's positive identifier tests
    /// use. (Full ID_Start property tables are a later refinement and only
    /// matter for rejecting invalid identifiers — the negative/strictness axis.)
    fn isIdStartCp(cp: u21) bool {
        if (cp < 0x80) return isIdentStart(@intCast(cp));
        if (isSpaceCp(cp) or isLineTermCp(cp)) return false;
        if (cp == 0x200C or cp == 0x200D) return false; // ZWNJ/ZWJ: continue-only
        return true;
    }

    /// IdentifierPart test for a decoded code point. Like `isIdStartCp` but also
    /// admits ZWNJ/ZWJ (U+200C/U+200D), which are valid in IdentifierPart.
    fn isIdContinueCp(cp: u21) bool {
        if (cp < 0x80) return isIdentPart(@intCast(cp));
        if (isSpaceCp(cp) or isLineTermCp(cp)) return false;
        return true;
    }

    /// True when an IdentifierStart begins at `self.i`: an ASCII ident-start, a
    /// `\u` escape, or a non-ASCII Unicode ID-start code point.
    fn identStartHere(self: *Lexer) bool {
        const c = self.src[self.i];
        if (isIdentStart(c)) return true;
        if (c == '\\' and self.peek2() == 'u') return true;
        if (c < 0x80) return false;
        const len = std.unicode.utf8ByteSequenceLength(c) catch return false;
        if (self.i + len > self.src.len) return false;
        const cp = std.unicode.utf8Decode(self.src[self.i .. self.i + len]) catch return false;
        return isIdStartCp(cp);
    }

    /// Scan an IdentifierName from `self.i`, returning its *decoded* text: `\u`
    /// escapes resolved to UTF-8 and raw Unicode letters copied through. Fast
    /// path — a pure-ASCII name with no escape — returns a zero-copy source
    /// slice, so the common case allocates nothing.
    fn lexIdentName(self: *Lexer) LexError![]const u8 {
        const start = self.i;
        var needs_decode = false;
        var first = true;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\\') {
                needs_decode = true;
                self.i += 1;
                if (self.peek() != 'u') return LexError.UnexpectedCharacter;
                self.i += 1; // 'u'
                try self.skipUnicodeEscape();
                first = false;
                continue;
            }
            if (c < 0x80) {
                if (!(if (first) isIdentStart(c) else isIdentPart(c))) break;
                self.i += 1;
            } else {
                const len = std.unicode.utf8ByteSequenceLength(c) catch break;
                if (self.i + len > self.src.len) break;
                const cp = std.unicode.utf8Decode(self.src[self.i .. self.i + len]) catch break;
                if (!(if (first) isIdStartCp(cp) else isIdContinueCp(cp))) break;
                self.i += len;
            }
            first = false;
        }
        const raw = self.src[start..self.i];
        return if (needs_decode) self.decodeIdent(raw) else raw;
    }

    /// Advance past a `\u` escape's digits (`\u{XXXX}` or exactly four hex
    /// digits). `self.i` points just past the `u`.
    fn skipUnicodeEscape(self: *Lexer) LexError!void {
        if (self.peek() == '{') {
            self.i += 1;
            const ds = self.i;
            while (self.i < self.src.len and self.src[self.i] != '}') self.i += 1;
            if (self.i >= self.src.len or self.i == ds) return LexError.UnexpectedCharacter;
            self.i += 1; // '}'
        } else {
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                if (self.i >= self.src.len or !std.ascii.isHex(self.src[self.i])) return LexError.UnexpectedCharacter;
                self.i += 1;
            }
        }
    }

    /// Decode an identifier slice containing `\u` escapes into a fresh UTF-8
    /// buffer (literal bytes copied through, escapes resolved + re-encoded).
    fn decodeIdent(self: *Lexer, raw: []const u8) LexError![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var j: usize = 0;
        while (j < raw.len) {
            if (raw[j] != '\\') {
                try buf.append(self.arena, raw[j]);
                j += 1;
                continue;
            }
            j += 2; // skip "\u"
            var cp: u21 = undefined;
            if (j < raw.len and raw[j] == '{') {
                j += 1;
                const s = j;
                while (j < raw.len and raw[j] != '}') j += 1;
                cp = std.fmt.parseInt(u21, raw[s..j], 16) catch return LexError.UnexpectedCharacter;
                j += 1; // '}'
            } else {
                cp = std.fmt.parseInt(u21, raw[j .. j + 4], 16) catch return LexError.UnexpectedCharacter;
                j += 4;
            }
            var ub: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &ub) catch return LexError.UnexpectedCharacter;
            try buf.appendSlice(self.arena, ub[0..n]);
        }
        return buf.toOwnedSlice(self.arena);
    }

    pub fn next(self: *Lexer) LexError!Token {
        var t = try self.nextRaw();
        t.end = self.i;
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

        // HashbangComment (`#!...`) — only valid at the very start of the source.
        if (c == '#' and self.peek2() == '!' and start == 0) {
            while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
            return self.nextRaw();
        }
        // Numbers
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(self.peek2()))) {
            return self.lexNumber();
        }
        // Identifiers / keywords — ASCII, Unicode letters, or `\u` escapes.
        if (self.identStartHere()) {
            return .{ .kind = .identifier, .text = try self.lexIdentName(), .pos = start };
        }
        // Private names (#ident) for class private members; the name after the
        // `#` may itself use Unicode letters or `\u` escapes.
        if (c == '#') {
            self.i += 1; // '#'
            if (!self.identStartHere()) return LexError.UnexpectedCharacter;
            const name = try self.lexIdentName();
            return .{ .kind = .private_name, .text = try std.fmt.allocPrint(self.arena, "#{s}", .{name}), .pos = start };
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
        // A leading `0` immediately followed by another digit is a legacy octal
        // (`0123`) or non-octal-decimal (`08`) literal — flagged for strict mode.
        const legacy = self.src[start] == '0' and start + 1 < self.src.len and std.ascii.isDigit(self.src[start + 1]);
        return .{ .kind = .number, .text = self.src[start..self.i], .number = n, .pos = start, .legacy_octal = legacy };
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
                if (self.i + 1 >= self.src.len) return LexError.UnterminatedString;
                self.i = try appendEscape(self.arena, &buf, self.src, self.i + 1);
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

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Append a UTF-8-encoded code point to `buf` (lone surrogates and out-of-range
/// values fall back to a single raw byte so decoding never fails).
fn appendCodePoint(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) std.mem.Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch {
        try buf.append(arena, @truncate(cp));
        return;
    };
    try buf.appendSlice(arena, tmp[0..n]);
}

/// Decode one escape sequence and append its bytes to `buf`. `src[i]` is the
/// character immediately after the backslash; returns the index just past the
/// escape. Handles `\n \t \r \b \f \v \0`, `\xHH`, `\uHHHH`, `\u{...}`, line
/// continuations, and (per spec) any other character as itself. Shared by the
/// string lexer and the template-literal parser. Malformed hex/unicode escapes
/// degrade to the literal character rather than erroring.
pub fn appendEscape(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), src: []const u8, i: usize) std.mem.Allocator.Error!usize {
    const e = src[i];
    switch (e) {
        'n' => {
            try buf.append(arena, '\n');
            return i + 1;
        },
        't' => {
            try buf.append(arena, '\t');
            return i + 1;
        },
        'r' => {
            try buf.append(arena, '\r');
            return i + 1;
        },
        'b' => {
            try buf.append(arena, 8);
            return i + 1;
        },
        'f' => {
            try buf.append(arena, 12);
            return i + 1;
        },
        'v' => {
            try buf.append(arena, 11);
            return i + 1;
        },
        '0'...'7' => {
            // `\0` (not followed by a digit) is NUL; legacy octal escapes are
            // out of scope, so any other digit is taken literally below.
            if (e == '0' and (i + 1 >= src.len or !std.ascii.isDigit(src[i + 1]))) {
                try buf.append(arena, 0);
                return i + 1;
            }
            try buf.append(arena, e);
            return i + 1;
        },
        'x' => {
            if (i + 2 < src.len) {
                if (hexVal(src[i + 1])) |hi| if (hexVal(src[i + 2])) |lo| {
                    try appendCodePoint(arena, buf, @as(u21, hi) * 16 + lo);
                    return i + 3;
                };
            }
            try buf.append(arena, 'x');
            return i + 1;
        },
        'u' => {
            if (i + 1 < src.len and src[i + 1] == '{') {
                // `\u{ HHHH }` — variable-length, up to 0x10FFFF.
                var j = i + 2;
                var cp: u21 = 0;
                var any = false;
                while (j < src.len and src[j] != '}') : (j += 1) {
                    const h = hexVal(src[j]) orelse break;
                    cp = @truncate(@as(u32, cp) * 16 + h);
                    any = true;
                }
                if (any and j < src.len and src[j] == '}') {
                    try appendCodePoint(arena, buf, cp);
                    return j + 1;
                }
            } else if (i + 4 < src.len) {
                // `\uHHHH` — exactly four hex digits.
                const a = hexVal(src[i + 1]);
                const b = hexVal(src[i + 2]);
                const c = hexVal(src[i + 3]);
                const d = hexVal(src[i + 4]);
                if (a != null and b != null and c != null and d != null) {
                    const cp = (@as(u21, a.?) << 12) | (@as(u21, b.?) << 8) | (@as(u21, c.?) << 4) | d.?;
                    try appendCodePoint(arena, buf, cp);
                    return i + 5;
                }
            }
            try buf.append(arena, 'u');
            return i + 1;
        },
        '\r' => {
            // Line continuation: `\` + CR or CRLF produces nothing.
            if (i + 1 < src.len and src[i + 1] == '\n') return i + 2;
            return i + 1;
        },
        '\n' => return i + 1, // line continuation
        else => {
            // `\\ \` \$ \" \'` and any NonEscapeCharacter → the character itself.
            try buf.append(arena, e);
            return i + 1;
        },
    }
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
