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
    at, // @ (decorator)
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
    /// A `123n` BigInt literal. `bigint_text`, when present, holds a canonical
    /// decimal value too large for the current i128 fast path.
    is_bigint: bool = false,
    bigint: i128 = 0,
    bigint_text: ?[]const u8 = null,
    /// True when an IdentifierName token contained at least one `\u` escape.
    escaped_identifier: bool = false,
};

pub const LexError = error{ UnexpectedCharacter, UnterminatedString, UnterminatedComment, InvalidNumber, OutOfMemory };

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
    last_identifier_escaped: bool = false,
    last_error_offset: ?usize = null,
    /// A stack of brace kinds (true = object literal `{`, false = block `{`), to
    /// resolve the `}`-then-`/` ambiguity: `{…} / x` divides an object literal,
    /// whereas a block `}` allows a regex.
    brace_obj: [512]bool = undefined,
    brace_top: usize = 0,
    last_rbrace_object: bool = false,
    pending_function_expr: bool = false,
    /// Annex B B.1.3 HTML-like comments (`<!--` … and line-leading `-->` …).
    /// Allowed in Script source, forbidden in Module source — `parseModule`
    /// re-tokenizes with this off so a module rejects them as a SyntaxError.
    html_comments: bool = true,
    /// Whether only trivia (and possibly a line terminator) has been seen since
    /// the previous significant token — true at the start of input. A line-
    /// leading `-->` is an HTML close comment only in this state.
    at_line_start: bool = true,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .arena = arena };
    }

    pub fn initOptions(arena: std.mem.Allocator, src: []const u8, html_comments: bool) Lexer {
        return .{ .src = src, .arena = arena, .html_comments = html_comments };
    }

    pub fn errorOffset(self: *const Lexer) usize {
        return self.last_error_offset orelse @min(self.i, self.src.len);
    }

    fn peek(self: *Lexer) u8 {
        return if (self.i < self.src.len) self.src[self.i] else 0;
    }

    fn peek2(self: *Lexer) u8 {
        return if (self.i + 1 < self.src.len) self.src[self.i + 1] else 0;
    }

    fn skipTrivia(self: *Lexer) LexError!void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            // ASCII whitespace incl. vertical tab (0x0B) and form feed (0x0C).
            if (c == '\r' or c == '\n') {
                self.i += 1;
                self.at_line_start = true; // a `-->` after this is an HTML close comment
            } else if (c == ' ' or c == '\t' or c == 0x0B or c == 0x0C) {
                self.i += 1;
            } else if (c == '/' and self.peek2() == '/') {
                self.i += 2;
                self.skipSingleLineCommentBody();
            } else if (c == '/' and self.peek2() == '*') {
                const had_nl = self.skipBlockComment() catch return LexError.UnterminatedComment;
                // A block comment containing a line terminator counts as a
                // LineTerminatorSequence for the purpose of a following `-->`.
                if (had_nl) self.at_line_start = true;
            } else if (self.html_comments and c == '<' and self.peek2() == '!' and
                self.i + 3 < self.src.len and self.src[self.i + 2] == '-' and self.src[self.i + 3] == '-')
            {
                // SingleLineHTMLOpenComment `<!--` — always a line comment.
                self.i += 4;
                self.skipSingleLineCommentBody();
            } else if (self.html_comments and self.at_line_start and c == '-' and self.peek2() == '-' and
                self.i + 2 < self.src.len and self.src[self.i + 2] == '>')
            {
                // SingleLineHTMLCloseComment `-->` — a line comment only when it
                // is the first non-trivia content of a line (or of the input).
                self.i += 3;
                self.skipSingleLineCommentBody();
            } else if (c >= 0x80) {
                // Unicode whitespace (NBSP, U+2000–200A, …) or line terminators
                // (U+2028/U+2029) and the BOM are all trivia between tokens.
                const len = std.unicode.utf8ByteSequenceLength(c) catch break;
                if (self.i + len > self.src.len) break;
                const cp = std.unicode.utf8Decode(self.src[self.i .. self.i + len]) catch break;
                if (isLineTermCp(cp)) {
                    self.i += len;
                    self.at_line_start = true;
                } else if (isSpaceCp(cp)) {
                    self.i += len;
                } else break;
            } else break;
        }
    }

    /// Skip a `/* … */` block comment (cursor at the opening `/`). Returns whether
    /// the comment body contained a line terminator. Errors if unterminated.
    fn skipBlockComment(self: *Lexer) error{Unterminated}!bool {
        self.i += 2; // `/*`
        var had_nl = false;
        while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) {
            const ch = self.src[self.i];
            if (ch == '\n' or ch == '\r') {
                had_nl = true;
            } else if (ch >= 0x80) {
                const len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
                if (self.i + len <= self.src.len) {
                    const cp = std.unicode.utf8Decode(self.src[self.i .. self.i + len]) catch 0;
                    if (isLineTermCp(cp)) had_nl = true;
                }
            }
            self.i += 1;
        }
        if (self.i + 1 >= self.src.len) return error.Unterminated;
        self.i += 2; // `*/`
        return had_nl;
    }

    fn skipSingleLineCommentBody(self: *Lexer) void {
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == '\n' or ch == '\r') break;
            if (ch >= 0x80) {
                const len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    self.i += 1;
                    continue;
                };
                if (self.i + len > self.src.len) {
                    self.i += 1;
                    continue;
                }
                const cp = std.unicode.utf8Decode(self.src[self.i .. self.i + len]) catch {
                    self.i += len;
                    continue;
                };
                if (isLineTermCp(cp)) break;
                self.i += len;
            } else {
                self.i += 1;
            }
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

    fn lineTerminatorLenAt(self: *Lexer, idx: usize) ?usize {
        return lineTerminatorLen(self.src, idx);
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
        if (cp == 0x2E2F or cp == 0x180E) return false; // VERTICAL TILDE / MONGOLIAN VOWEL SEP: not ID
        return true;
    }

    /// IdentifierPart test for a decoded code point. Like `isIdStartCp` but also
    /// admits ZWNJ/ZWJ (U+200C/U+200D), which are valid in IdentifierPart.
    fn isIdContinueCp(cp: u21) bool {
        if (cp < 0x80) return isIdentPart(@intCast(cp));
        if (isSpaceCp(cp) or isLineTermCp(cp)) return false;
        if (cp == 0x2E2F or cp == 0x180E) return false; // VERTICAL TILDE / MONGOLIAN VOWEL SEP: not ID
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
        var first = true;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\\') return self.lexEscapedIdentName(start, first);
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
        self.last_identifier_escaped = false;
        return self.src[start..self.i];
    }

    /// Continue an IdentifierName scan after its first escape. The ordinary
    /// path above keeps its source-slice-only loop; only escaped names carry
    /// decode state and owned storage.
    fn lexEscapedIdentName(self: *Lexer, start: usize, first_in: bool) LexError![]const u8 {
        var decoded: std.ArrayListUnmanaged(u8) = .empty;
        var raw_start = start;
        var first = first_in;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\\') {
                const escape_start = self.i;
                self.i += 1;
                if (self.peek() != 'u') return LexError.UnexpectedCharacter;
                self.i += 1; // 'u'
                const cp = try self.scanUnicodeEscapeCp();
                if (!(if (first) isIdStartCp(cp) else isIdContinueCp(cp))) return LexError.UnexpectedCharacter;
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(cp, &encoded) catch return LexError.UnexpectedCharacter;
                // Decode during the validating scan. Ordinary source bytes stay
                // borrowed until an escape requires owned storage, then move in
                // contiguous spans rather than one append per byte.
                try decoded.appendSlice(self.arena, self.src[raw_start..escape_start]);
                try decoded.appendSlice(self.arena, encoded[0..encoded_len]);
                raw_start = self.i;
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
        self.last_identifier_escaped = true;
        try decoded.appendSlice(self.arena, self.src[raw_start..self.i]);
        return decoded.toOwnedSlice(self.arena);
    }

    /// Decode and advance past a `\u` escape's digits. `self.i` points just
    /// past the `u`.
    fn scanUnicodeEscapeCp(self: *Lexer) LexError!u21 {
        if (self.peek() == '{') {
            self.i += 1;
            const ds = self.i;
            while (self.i < self.src.len and self.src[self.i] != '}') self.i += 1;
            if (self.i >= self.src.len or self.i == ds) return LexError.UnexpectedCharacter;
            // Only hex digits are allowed — `std.fmt.parseInt` would otherwise
            // silently accept a `_` separator (`\u{0_0}`), which JS forbids.
            for (self.src[ds..self.i]) |d| if (!std.ascii.isHex(d)) return LexError.UnexpectedCharacter;
            const cp = std.fmt.parseInt(u21, self.src[ds..self.i], 16) catch return LexError.UnexpectedCharacter;
            if (cp > 0x10FFFF) return LexError.UnexpectedCharacter;
            self.i += 1; // '}'
            return cp;
        } else {
            const ds = self.i;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                if (self.i >= self.src.len or !std.ascii.isHex(self.src[self.i])) return LexError.UnexpectedCharacter;
                self.i += 1;
            }
            return std.fmt.parseInt(u21, self.src[ds..self.i], 16) catch return LexError.UnexpectedCharacter;
        }
    }

    pub fn next(self: *Lexer) LexError!Token {
        const prev = self.prev_kind;
        const prev_text = self.prev_text;
        var t = self.nextRaw() catch |err| {
            self.last_error_offset = @min(self.i, self.src.len);
            return err;
        };
        // A real token has been scanned: a subsequent `-->` is only an HTML close
        // comment once a fresh line terminator (set in skipTrivia) precedes it.
        self.at_line_start = false;
        t.end = self.i;
        if (t.kind == .lbrace) {
            if (self.brace_top < self.brace_obj.len) {
                const function_expr_body = self.pending_function_expr and prev == .rparen;
                self.brace_obj[self.brace_top] = function_expr_body or bracePosIsObject(prev, prev_text);
                self.brace_top += 1;
                if (function_expr_body) self.pending_function_expr = false;
            }
        } else if (t.kind == .rbrace) {
            self.last_rbrace_object = if (self.brace_top > 0) blk: {
                self.brace_top -= 1;
                break :blk self.brace_obj[self.brace_top];
            } else false;
        } else if (t.kind == .identifier and std.mem.eql(u8, t.text, "function")) {
            self.pending_function_expr = functionExprAllowed(prev, prev_text);
        } else if (self.pending_function_expr and (t.kind == .semicolon or t.kind == .colon or t.kind == .eof)) {
            self.pending_function_expr = false;
        }
        self.prev_kind = t.kind;
        self.prev_text = t.text;
        return t;
    }

    /// True when a `/` here begins a regex literal rather than division — i.e.
    /// the previous token does not end an expression.
    fn regexAllowed(self: *Lexer) bool {
        return switch (self.prev_kind) {
            .number, .string, .template, .regex, .private_name, .rparen, .rbracket => false,
            // A `}` that closed an object literal ends an expression (division);
            // one that closed a block does not (regex allowed).
            .rbrace => !self.last_rbrace_object,
            .identifier => isOperandKeyword(self.prev_text), // `return /re/` yes, `x / y` no
            else => true,
        };
    }

    fn nextRaw(self: *Lexer) LexError!Token {
        try self.skipTrivia();
        const start = self.i;
        if (self.i >= self.src.len) return .{ .kind = .eof, .text = "", .pos = start };

        const c = self.src[self.i];

        // HashbangComment (`#!...`) — only valid at the very start of the source.
        if (c == '#' and self.peek2() == '!' and start == 0) {
            self.i += 2;
            self.skipSingleLineCommentBody();
            return self.nextRaw();
        }
        // Numbers
        if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(self.peek2()))) {
            const num = try self.lexNumber();
            // A numeric literal may not be immediately followed by an
            // IdentifierStart (a digit is already consumed): `3in`, `3abc`,
            // `3.toString()` are SyntaxErrors.
            if (self.i < self.src.len and self.identStartHere()) return LexError.UnexpectedCharacter;
            return num;
        }
        // Identifiers / keywords — ASCII, Unicode letters, or `\u` escapes.
        if (self.identStartHere()) {
            const name = try self.lexIdentName();
            return .{ .kind = .identifier, .text = name, .pos = start, .escaped_identifier = self.last_identifier_escaped };
        }
        // Private names (#ident) for class private members; the name after the
        // `#` may itself use Unicode letters or `\u` escapes.
        if (c == '#') {
            self.i += 1; // '#'
            if (!self.identStartHere()) return LexError.UnexpectedCharacter;
            const name = try self.lexIdentName();
            // The token's complete unescaped spelling is already stable source.
            // Escapes still require owned decoded bytes joined to their `#`.
            const text = if (self.last_identifier_escaped)
                try std.fmt.allocPrint(self.arena, "#{s}", .{name})
            else
                self.src[start..self.i];
            return .{ .kind = .private_name, .text = text, .pos = start };
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
            '@' => return tok(.at, self.src[start..self.i], start),
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
                if (!separatorsValid(self.src[ds..self.i], r)) return LexError.InvalidNumber;
                const cleaned = try stripSeparators(self.arena, self.src[ds..self.i]);
                if (self.peek() == 'n') {
                    self.i += 1; // `0xFFn` — a BigInt literal.
                    if (std.fmt.parseInt(u128, cleaned, r)) |n| {
                        if (n <= @as(u128, @intCast(std.math.maxInt(i128))))
                            return .{ .kind = .number, .text = self.src[start..self.i], .number = @floatFromInt(n), .pos = start, .is_bigint = true, .bigint = @intCast(n) };
                    } else |_| {}
                    return .{ .kind = .number, .text = self.src[start..self.i], .pos = start, .is_bigint = true, .bigint_text = try radixDigitsToDecimal(self.arena, cleaned, r) };
                }
                const n = std.fmt.parseInt(u128, cleaned, r) catch return LexError.InvalidNumber;
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
        // Decimal separators must sit between two decimal digits — `.`, `e`,
        // signs, and the `n` suffix are not digits, so e.g. `1_.5`, `1_e3`, `1_n`
        // are rejected. A `0`-prefixed legacy literal admits no separators at all.
        if (!separatorsValid(self.src[start..self.i], 10)) return LexError.InvalidNumber;
        if (self.src[start] == '0' and self.i - start > 1 and
            (std.ascii.isDigit(self.src[start + 1]) or self.src[start + 1] == '_') and
            std.mem.indexOfScalar(u8, self.src[start..self.i], '_') != null) return LexError.InvalidNumber;
        if (self.peek() == 'n') {
            // `123n` — a decimal BigInt literal (no fraction/exponent allowed).
            if (std.mem.indexOfAny(u8, self.src[start..self.i], ".eE") != null) return LexError.InvalidNumber;
            // The integer part may not have a leading zero: only `0n` is legal,
            // `00n`/`01n`/`08n`/`0123n` (legacy-octal-like or non-octal-decimal)
            // are SyntaxErrors in every mode.
            if (self.src[start] == '0' and self.i - start > 1) return LexError.InvalidNumber;
            const digits = try stripSeparators(self.arena, self.src[start..self.i]);
            self.i += 1;
            if (std.fmt.parseInt(i128, digits, 10)) |bi| {
                return .{ .kind = .number, .text = self.src[start..self.i], .number = @floatFromInt(bi), .pos = start, .is_bigint = true, .bigint = bi };
            } else |_| {
                return .{ .kind = .number, .text = self.src[start..self.i], .pos = start, .is_bigint = true, .bigint_text = canonicalDecimalDigits(digits) };
            }
        }
        const cleaned = try stripSeparators(self.arena, self.src[start..self.i]);
        var n = std.fmt.parseFloat(f64, cleaned) catch return LexError.InvalidNumber;
        // A leading `0` immediately followed by another digit is a legacy octal
        // (`0123`) or non-octal-decimal (`08`) literal — flagged for strict mode.
        const num_tok = self.src[start..self.i];
        const legacy = self.src[start] == '0' and start + 1 < self.src.len and std.ascii.isDigit(self.src[start + 1]);
        if (legacy) {
            // A LegacyOctalIntegerLiteral is `0` followed by only octal digits
            // (0-7) and has the octal value. A NonOctalDecimalIntegerLiteral
            // (e.g. `08`, `019` — a digit 8/9 appears) keeps its decimal value.
            var all_octal = true;
            for (num_tok) |c| if (c < '0' or c > '7') {
                all_octal = false;
                break;
            };
            if (all_octal) {
                var v: f64 = 0;
                for (num_tok) |c| v = v * 8 + @as(f64, @floatFromInt(c - '0'));
                n = v;
            }
        }
        return .{ .kind = .number, .text = num_tok, .number = n, .pos = start, .legacy_octal = legacy };
    }

    fn lexString(self: *Lexer) LexError!Token {
        const start = self.i;
        const quote = self.src[self.i];
        self.i += 1;
        const content_start = self.i;
        // A LegacyOctalEscapeSequence (`\1`..`\7`, `\0` followed by a digit) or a
        // NonOctalDecimalEscapeSequence (`\8`/`\9`) makes the literal a SyntaxError
        // in strict-mode code; flag it so the parser can reject it (mirrors the
        // numeric legacy-octal flag).
        var legacy = false;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var decoded = false;
        var raw_start = content_start;
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == quote) {
                const content_end = self.i;
                self.i += 1;
                if (!decoded) return .{
                    .kind = .string,
                    .text = self.src[content_start..content_end],
                    .pos = start,
                    .legacy_octal = legacy,
                };
                try buf.appendSlice(self.arena, self.src[raw_start..content_end]);
                return .{ .kind = .string, .text = try buf.toOwnedSlice(self.arena), .pos = start, .legacy_octal = legacy };
            }
            if (ch == '\\') {
                if (self.i + 1 >= self.src.len) return LexError.UnterminatedString;
                // The source backing outlives every parser/AST consumer. Borrow
                // an unescaped value directly; only the first escape converts
                // the token to owned decoded storage. Copy subsequent raw spans
                // in batches instead of growing the arena list once per byte.
                try buf.appendSlice(self.arena, self.src[raw_start..self.i]);
                decoded = true;
                const e = self.src[self.i + 1];
                if (e >= '1' and e <= '9') {
                    legacy = true;
                } else if (e == '0' and self.i + 2 < self.src.len and std.ascii.isDigit(self.src[self.i + 2])) {
                    legacy = true;
                }
                try validateStringEscape(self.src, self.i + 1);
                self.i = try appendEscape(self.arena, &buf, self.src, self.i + 1);
                raw_start = self.i;
            } else if (ch == '\n' or ch == '\r') {
                return LexError.UnterminatedString;
            } else {
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
        // Last significant byte scanned inside the current `${ }` — drives the
        // regex-vs-division decision for a `/` (see `templateRegexAllowed`).
        var last_sig: u8 = 0;
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
                    last_sig = 0;
                    self.i += 2;
                    continue;
                }
                self.i += 1;
            } else {
                // Inside a `${ ... }` substitution: skip strings, regexes,
                // comments, and nested templates so their braces/quotes don't
                // confuse the outer brace-depth tracking.
                switch (c) {
                    ' ', '\t', '\n', '\r' => self.i += 1,
                    '{' => {
                        depth += 1;
                        last_sig = '{';
                        self.i += 1;
                    },
                    '}' => {
                        depth -= 1;
                        last_sig = '}';
                        self.i += 1;
                    },
                    '\'', '"' => {
                        self.skipStringLiteral(c);
                        last_sig = '"';
                    },
                    '`' => {
                        _ = try self.lexTemplate(); // nested template (recurses)
                        last_sig = '`';
                    },
                    '/' => {
                        const n = self.peek2();
                        if (n == '/') {
                            while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                        } else if (n == '*') {
                            self.i += 2;
                            while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) self.i += 1;
                            self.i = @min(self.i + 2, self.src.len);
                        } else if (templateRegexAllowed(last_sig)) {
                            self.skipRegexLiteral();
                            last_sig = 'r';
                        } else {
                            last_sig = '/';
                            self.i += 1;
                        }
                    },
                    '\\' => {
                        self.i += 2;
                        last_sig = '\\';
                    },
                    else => {
                        last_sig = c;
                        self.i += 1;
                    },
                }
            }
        }
        return LexError.UnterminatedString;
    }

    /// Within a template substitution, decide whether a `/` begins a regex
    /// literal (true) or is a division operator (false), from the previous
    /// significant byte. Regex is allowed at the start of the substitution or
    /// after an operator/opening punctuator — never after a value-producing
    /// char (identifier, digit, or closing `)`/`]`/`}`/quote).
    fn templateRegexAllowed(last: u8) bool {
        return switch (last) {
            0, '(', '[', '{', ',', ';', ':', '?', '=', '+', '-', '*', '/', '%', '!', '&', '|', '^', '~', '<', '>' => true,
            else => false,
        };
    }

    /// Advance `self.i` past a `/pattern/flags` regex literal (no token built);
    /// used by the template-substitution scanner.
    fn skipRegexLiteral(self: *Lexer) void {
        self.i += 1; // opening /
        var in_class = false;
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == '\n') return;
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
        if (self.i >= self.src.len) return;
        self.i += 1; // closing /
        while (self.i < self.src.len and std.ascii.isAlphabetic(self.src[self.i])) self.i += 1;
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
            if (self.lineTerminatorLenAt(self.i) != null) return LexError.UnterminatedString;
            if (c == '\\') {
                if (lineTerminatorLen(self.src, self.i + 1) != null) return LexError.UnterminatedString;
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

pub fn lineTerminatorLen(src: []const u8, idx: usize) ?usize {
    if (idx >= src.len) return null;
    return switch (src[idx]) {
        '\n' => 1,
        '\r' => if (idx + 1 < src.len and src[idx + 1] == '\n') 2 else 1,
        0xe2 => if (idx + 2 < src.len and src[idx + 1] == 0x80 and (src[idx + 2] == 0xa8 or src[idx + 2] == 0xa9)) 3 else null,
        else => null,
    };
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Append a UTF-8-encoded code point to `buf`. Lone surrogates are emitted as
/// WTF-8 so JS strings can preserve UTF-16 code units that are not scalar values.
fn appendCodePoint(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) std.mem.Allocator.Error!void {
    // A codepoint past the Unicode maximum only reaches here from a `\u{…}` escape
    // whose value overflows 0x10FFFF. That is always an invalid escape — a
    // SyntaxError in a string (rejected before this runs) and a discarded
    // (cooked=undefined) quasi in a tagged template — so emit U+FFFD rather than
    // feed the out-of-range scalar to utf8Encode, which panics. (Fixes a crash on
    // ``\u{110000}`` in a tagged template.)
    if (cp > 0x10FFFF) {
        try buf.appendSlice(arena, "\u{FFFD}");
        return;
    }
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch {
        try buf.append(arena, @intCast(0xE0 | (cp >> 12)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
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
    if (lineTerminatorLen(src, i)) |len| return i + len;
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
            // LegacyOctalEscapeSequence (Annex B.1.2): 1-3 octal digits with
            // value ≤ 0o377 (255). A leading 0-3 admits up to two more octal
            // digits; a leading 4-7 admits one more. (`\0` not followed by an
            // octal digit is the non-legacy NUL escape — value 0, zero extra
            // digits — and falls out of the same loop.)
            var val: u21 = @as(u21, e - '0');
            var j = i + 1;
            const max_more: usize = if (e <= '3') 2 else 1;
            var taken: usize = 0;
            while (taken < max_more and j < src.len and src[j] >= '0' and src[j] <= '7') : (taken += 1) {
                val = val * 8 + @as(u21, src[j] - '0');
                j += 1;
            }
            try appendCodePoint(arena, buf, val);
            return j;
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
                    if (cp >= 0xD800 and cp <= 0xDBFF and i + 10 < src.len and src[i + 5] == '\\' and src[i + 6] == 'u') {
                        const e2 = hexVal(src[i + 7]);
                        const f2 = hexVal(src[i + 8]);
                        const g2 = hexVal(src[i + 9]);
                        const h2 = hexVal(src[i + 10]);
                        if (e2 != null and f2 != null and g2 != null and h2 != null) {
                            const lo = (@as(u21, e2.?) << 12) | (@as(u21, f2.?) << 8) | (@as(u21, g2.?) << 4) | h2.?;
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                const full: u21 = 0x10000 + (((cp - 0xD800) << 10) | (lo - 0xDC00));
                                try appendCodePoint(arena, buf, full);
                                return i + 11;
                            }
                        }
                    }
                    try appendCodePoint(arena, buf, cp);
                    return i + 5;
                }
            }
            try buf.append(arena, 'u');
            return i + 1;
        },
        else => {
            // `\\ \` \$ \" \'` and any NonEscapeCharacter → the character itself.
            try buf.append(arena, e);
            return i + 1;
        },
    }
}

/// Reject the malformed `\x`/`\u` escape sequences that are an early SyntaxError
/// in a *string* literal (12.9.4.1): `\x` not followed by two hex digits, `\u`
/// not followed by four hex digits or a `\u{ H+ }` with 1..0x10FFFF. These are
/// tolerated (yielding an `undefined` cooked value) in template literals, so
/// this runs only from `lexString`, never from `appendEscape`. Lone surrogates
/// (`\uD800`) remain valid. `i` indexes the character right after the backslash.
fn validateStringEscape(src: []const u8, i: usize) LexError!void {
    if (i >= src.len) return;
    switch (src[i]) {
        'x' => {
            if (i + 2 >= src.len or hexVal(src[i + 1]) == null or hexVal(src[i + 2]) == null)
                return LexError.UnexpectedCharacter;
        },
        'u' => {
            if (i + 1 < src.len and src[i + 1] == '{') {
                var j = i + 2;
                var cp: u32 = 0;
                var any = false;
                while (j < src.len and src[j] != '}') : (j += 1) {
                    const h = hexVal(src[j]) orelse return LexError.UnexpectedCharacter;
                    cp = cp * 16 + h;
                    any = true;
                    if (cp > 0x10FFFF) return LexError.UnexpectedCharacter;
                }
                if (!any) return LexError.UnexpectedCharacter; // `\u{}`
                if (j >= src.len or src[j] != '}') return LexError.UnexpectedCharacter; // unterminated
            } else if (i + 4 >= src.len or hexVal(src[i + 1]) == null or hexVal(src[i + 2]) == null or
                hexVal(src[i + 3]) == null or hexVal(src[i + 4]) == null)
            {
                return LexError.UnexpectedCharacter;
            }
        },
        else => {},
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

/// A numeric separator `_` is legal only *between* two digits of the literal's
/// radix — never leading/trailing, doubled (`1__0`), adjacent to the radix
/// prefix (`0x_1`), or next to a `.`/`e`/sign/`n` (those aren't radix digits).
fn separatorsValid(s: []const u8, radix: u8) bool {
    for (s, 0..) |c, i| {
        if (c != '_') continue;
        if (i == 0 or i + 1 >= s.len) return false;
        if (!isRadixDigit(s[i - 1], radix) or !isRadixDigit(s[i + 1], radix)) return false;
    }
    return true;
}

/// Strip `_` numeric separators, trimming a trailing BigInt `n` too. Returns a
/// slice safe to hand to `parseInt`/`parseFloat`.
fn stripSeparators(arena: std.mem.Allocator, s: []const u8) LexError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '_') == null and (s.len == 0 or s[s.len - 1] != 'n')) return s;
    const end = if (s.len != 0 and s[s.len - 1] == 'n') s.len - 1 else s.len;
    var separator_count: usize = 0;
    for (s[0..end]) |c| separator_count += @intFromBool(c == '_');
    const normalized = try arena.alloc(u8, end - separator_count);
    var out: usize = 0;
    for (s[0..end]) |c| {
        if (c == '_') continue;
        normalized[out] = c;
        out += 1;
    }
    std.debug.assert(out == normalized.len);
    return normalized;
}

fn canonicalDecimalDigits(digits: []const u8) []const u8 {
    var i: usize = 0;
    while (i < digits.len and digits[i] == '0') i += 1;
    if (i == digits.len) return "0";
    // Decimal literal validation already owns the lifetime: plain digits point
    // into immutable source and separated digits point into the parser arena's
    // exact normalized allocation. Canonicalization needs only a subslice.
    return digits[i..];
}

fn radixDigitsToDecimal(arena: std.mem.Allocator, digits: []const u8, radix: u8) LexError![]const u8 {
    var first: usize = 0;
    while (first < digits.len and digits[first] == '0') first += 1;
    if (first == digits.len) return "0";
    const significant = digits[first..];

    const bits_per_digit: usize = switch (radix) {
        2 => 1,
        8 => 3,
        16 => 4,
        else => return LexError.InvalidNumber,
    };
    const chunk_digits: usize = switch (radix) {
        2 => 29,
        8 => 9,
        16 => 7,
        else => unreachable,
    };
    // A base-1e9 limb carries fewer than 30 bits. Dividing the input bit
    // ceiling by 29 intentionally rounds capacity upward without floats.
    const bit_count = std.math.mul(usize, significant.len, bits_per_digit) catch return LexError.OutOfMemory;
    const limb_capacity = std.math.add(usize, bit_count, 28) catch return LexError.OutOfMemory;
    const limbs = try arena.alloc(u32, @max(@as(usize, 1), limb_capacity / 29));
    limbs[0] = 0;
    var used: usize = 1;

    var offset: usize = 0;
    while (offset < significant.len) {
        const remaining = significant.len - offset;
        const take = if (offset == 0 and remaining % chunk_digits != 0) remaining % chunk_digits else @min(chunk_digits, remaining);
        var chunk: u32 = 0;
        var multiplier: u32 = 1;
        for (significant[offset .. offset + take]) |c| {
            const digit = std.fmt.charToDigit(c, radix) catch return LexError.InvalidNumber;
            chunk = chunk * radix + digit;
            multiplier *= radix;
        }
        var carry: u64 = chunk;
        for (limbs[0..used]) |*limb| {
            const value = @as(u64, limb.*) * multiplier + carry;
            limb.* = @intCast(value % 1_000_000_000);
            carry = value / 1_000_000_000;
        }
        while (carry != 0) {
            std.debug.assert(used < limbs.len);
            limbs[used] = @intCast(carry % 1_000_000_000);
            used += 1;
            carry /= 1_000_000_000;
        }
        offset += take;
    }

    const high = limbs[used - 1];
    var high_digits: usize = 1;
    var high_tail = high;
    while (high_tail >= 10) : (high_tail /= 10) high_digits += 1;
    const tail_digits = std.math.mul(usize, used - 1, 9) catch return LexError.OutOfMemory;
    const output_len = std.math.add(usize, high_digits, tail_digits) catch return LexError.OutOfMemory;
    const out = try arena.alloc(u8, output_len);

    var write = high_digits;
    var high_value = high;
    while (write != 0) {
        write -= 1;
        out[write] = '0' + @as(u8, @intCast(high_value % 10));
        high_value /= 10;
    }
    var limb_index = used - 1;
    write = high_digits;
    while (limb_index != 0) {
        limb_index -= 1;
        var value = limbs[limb_index];
        var end = write + 9;
        while (end != write) {
            end -= 1;
            out[end] = '0' + @as(u8, @intCast(value % 10));
            value /= 10;
        }
        write += 9;
    }
    std.debug.assert(write == out.len);
    return out;
}

/// Keywords after which a `/` begins a regex (they expect an operand).
/// Whether a `{` following a token of kind `prev_kind` begins an object literal
/// (expression position) rather than a block. Used only to disambiguate a later
/// `}`-then-`/`; an imperfect heuristic is fine since it only affects regex-vs-
/// division at a `}`.
fn bracePosIsObject(prev_kind: TokenKind, prev_text: []const u8) bool {
    return switch (prev_kind) {
        .lparen,
        .lbracket,
        .comma,
        .colon,
        .question,
        .assign,
        .plus_eq,
        .minus_eq,
        .star_eq,
        .slash_eq,
        .percent_eq,
        .star_star_eq,
        .shl_eq,
        .shr_eq,
        .ushr_eq,
        .amp_eq,
        .pipe_eq,
        .caret_eq,
        .amp_amp_eq,
        .pipe_pipe_eq,
        .qq_eq,
        .plus,
        .minus,
        .star,
        .star_star,
        .slash,
        .percent,
        .eq,
        .eq_strict,
        .neq,
        .neq_strict,
        .lt,
        .le,
        .gt,
        .ge,
        .bang,
        .tilde,
        .amp,
        .pipe,
        .caret,
        .amp_amp,
        .pipe_pipe,
        .qq,
        .shl,
        .shr,
        .ushr,
        => true,
        // Expression-introducing keywords (but NOT do/else/case/default, which
        // introduce a block/clause body).
        .identifier => isOperandKeyword(prev_text) and
            !std.mem.eql(u8, prev_text, "do") and !std.mem.eql(u8, prev_text, "else") and
            !std.mem.eql(u8, prev_text, "case") and !std.mem.eql(u8, prev_text, "default"),
        else => false,
    };
}

fn functionExprAllowed(prev_kind: TokenKind, prev_text: []const u8) bool {
    return switch (prev_kind) {
        .lparen,
        .lbracket,
        .comma,
        .colon,
        .question,
        .assign,
        .plus_eq,
        .minus_eq,
        .star_eq,
        .slash_eq,
        .percent_eq,
        .star_star_eq,
        .shl_eq,
        .shr_eq,
        .ushr_eq,
        .amp_eq,
        .pipe_eq,
        .caret_eq,
        .amp_amp_eq,
        .pipe_pipe_eq,
        .qq_eq,
        .plus,
        .minus,
        .star,
        .star_star,
        .slash,
        .percent,
        .eq,
        .eq_strict,
        .neq,
        .neq_strict,
        .lt,
        .le,
        .gt,
        .ge,
        .bang,
        .tilde,
        .amp,
        .pipe,
        .caret,
        .amp_amp,
        .pipe_pipe,
        .qq,
        .shl,
        .shr,
        .ushr,
        => true,
        .identifier => isOperandKeyword(prev_text),
        else => false,
    };
}

fn isOperandKeyword(text: []const u8) bool {
    const words = [_][]const u8{
        "return", "typeof",  "instanceof", "in",   "new",
        "delete", "void",    "throw",      "case", "do",
        "else",   "default",
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

test "lexer normalizes numeric separators in one exact allocation" {
    const separated = "100_000_000_123";
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const normalized = try stripSeparators(measured.allocator(), separated);
    defer measured.allocator().free(normalized);
    try std.testing.expectEqualStrings("100000000123", normalized);
    try std.testing.expectEqual(@as(usize, 1), measured.alloc_index);
    try std.testing.expectEqual(normalized.len, measured.allocated_bytes);

    const plain = "100000000123";
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    const borrowed = try stripSeparators(fixed.allocator(), plain);
    try std.testing.expectEqual(@intFromPtr(plain.ptr), @intFromPtr(borrowed.ptr));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, stripSeparators(failing.allocator(), separated));
}

test "lexer preserves numeric separator values forms and source offsets" {
    const numbers = [_]struct { source: []const u8, expected: f64 }{
        .{ .source = "1_000_000", .expected = 1_000_000 },
        .{ .source = "1_2.3_4", .expected = 12.34 },
        .{ .source = "1_2.5e1_0", .expected = 125_000_000_000 },
        .{ .source = "0b1010_0101", .expected = 165 },
        .{ .source = "0o7_7_7", .expected = 511 },
        .{ .source = "0xFF_FF", .expected = 65_535 },
    };
    for (numbers) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lexer = Lexer.init(arena.allocator(), case.source);
        const token = try lexer.next();
        try std.testing.expectEqual(TokenKind.number, token.kind);
        try std.testing.expectEqual(case.expected, token.number);
        try std.testing.expectEqualStrings(case.source, token.text);
        try std.testing.expectEqual(@as(usize, 0), token.pos);
        try std.testing.expectEqual(case.source.len, token.end);
    }

    var bigint_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer bigint_arena.deinit();
    var small_bigint = Lexer.init(bigint_arena.allocator(), "123_456n");
    const small = try small_bigint.next();
    try std.testing.expect(small.is_bigint);
    try std.testing.expectEqual(@as(i128, 123_456), small.bigint);

    const large_source = "340_282_366_920_938_463_463_374_607_431_768_211_456n";
    var large_bigint = Lexer.init(bigint_arena.allocator(), large_source);
    const large = try large_bigint.next();
    try std.testing.expect(large.is_bigint);
    try std.testing.expectEqualStrings("340282366920938463463374607431768211456", large.bigint_text.?);
    try std.testing.expectEqualStrings(large_source, large.text);
    try std.testing.expectEqual(large_source.len, large.end);

    const invalid = [_][]const u8{
        "1__0",
        "1_",
        "0x_1",
        "0b1_",
        "1_.0",
        "1._0",
        "1e_1",
        "1e1_",
        "1_n",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lexer = Lexer.init(arena.allocator(), source);
        try std.testing.expectError(LexError.InvalidNumber, lexer.next());
    }
}

test "lexer borrows canonical oversized decimal BigInt digits" {
    const plain = "340282366920938463463374607431768211456n";
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    var plain_lexer = Lexer.init(fixed.allocator(), plain);
    const plain_token = try plain_lexer.next();
    try std.testing.expect(plain_token.is_bigint);
    try std.testing.expectEqualStrings(plain[0 .. plain.len - 1], plain_token.bigint_text.?);
    try std.testing.expectEqual(@intFromPtr(plain.ptr), @intFromPtr(plain_token.bigint_text.?.ptr));

    const separated = "340_282_366_920_938_463_463_374_607_431_768_211_456n";
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var separated_lexer = Lexer.init(measured.allocator(), separated);
    const separated_token = try separated_lexer.next();
    defer measured.allocator().free(separated_token.bigint_text.?);
    try std.testing.expectEqualStrings(plain[0 .. plain.len - 1], separated_token.bigint_text.?);
    try std.testing.expectEqual(@as(usize, 1), measured.alloc_index);
    try std.testing.expectEqual(separated_token.bigint_text.?.len, measured.allocated_bytes);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failing_lexer = Lexer.init(failing.allocator(), separated);
    try std.testing.expectError(error.OutOfMemory, failing_lexer.next());
}

test "lexer converts oversized radix BigInts through bounded exact storage" {
    const expected = "340282366920938463463374607431768211456";
    const cases = [_][]const u8{
        "0x100000000000000000000000000000000n",
        "0X100000000000000000000000000000000n",
        "0x000100000000000000000000000000000000n",
        "0x1_0000_0000_0000_0000_0000_0000_0000_0000n",
        "0o4000000000000000000000000000000000000000000n",
        "0b100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000n",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lexer = Lexer.init(arena.allocator(), source);
        const token = try lexer.next();
        try std.testing.expect(token.is_bigint);
        try std.testing.expectEqualStrings(expected, token.bigint_text.?);
        try std.testing.expectEqualStrings(source, token.text);
        try std.testing.expectEqual(@as(usize, 0), token.pos);
        try std.testing.expectEqual(source.len, token.end);
    }

    var small_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer small_arena.deinit();
    var small_lexer = Lexer.init(small_arena.allocator(), "0xFFn");
    const small = try small_lexer.next();
    try std.testing.expectEqual(@as(i128, 255), small.bigint);
    try std.testing.expectEqual(@as(?[]const u8, null), small.bigint_text);

    const wide = "ffffffffffffffffffffffffffffffff";
    var measured_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer measured_arena.deinit();
    var measured = std.testing.FailingAllocator.init(measured_arena.allocator(), .{});
    const decimal = try radixDigitsToDecimal(measured.allocator(), wide, 16);
    try std.testing.expectEqualStrings("340282366920938463463374607431768211455", decimal);
    try std.testing.expectEqual(@as(usize, 2), measured.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), measured.resize_index);
    try std.testing.expectEqual(decimal.len + 5 * @sizeOf(u32), measured.allocated_bytes);

    var scratch_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, radixDigitsToDecimal(scratch_failure.allocator(), wide, 16));
    var failure_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer failure_arena.deinit();
    var output_failure = std.testing.FailingAllocator.init(failure_arena.allocator(), .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, radixDigitsToDecimal(output_failure.allocator(), wide, 16));
}

test "radix BigInt decimal conversion matches independent chunk boundaries" {
    const lengths = [_]usize{ 1, 2, 7, 8, 9, 28, 29, 30, 127, 256 };
    for ([_]u8{ 2, 8, 16 }) |radix| {
        for (lengths) |len| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const digits = try arena.allocator().alloc(u8, len);
            for (digits, 0..) |*digit, index| {
                const value: u8 = if (index < 2) 0 else @intCast((index *% 11 +% len) % radix);
                digit.* = if (value < 10)
                    '0' + value
                else if (index % 2 == 0)
                    'a' + value - 10
                else
                    'A' + value - 10;
            }

            var oracle = try std.math.big.int.Managed.init(std.testing.allocator);
            defer oracle.deinit();
            try oracle.setString(radix, digits);
            const expected = try oracle.toString(std.testing.allocator, 10, .lower);
            defer std.testing.allocator.free(expected);

            const actual = try radixDigitsToDecimal(arena.allocator(), digits, radix);
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
}

test "lexer borrows ordinary identifiers and owns escaped decoding" {
    const ordinary_source = "ordinary_π";
    var no_memory: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_memory);
    var ordinary = Lexer.init(failing.allocator(), ordinary_source);
    const borrowed = try ordinary.next();
    try std.testing.expectEqual(TokenKind.identifier, borrowed.kind);
    try std.testing.expectEqualStrings(ordinary_source, borrowed.text);
    try std.testing.expectEqual(@intFromPtr(ordinary_source.ptr), @intFromPtr(borrowed.text.ptr));
    try std.testing.expect(!borrowed.escaped_identifier);

    var escaped_oom = Lexer.init(failing.allocator(), "paramet\\u0065r");
    try std.testing.expectError(error.OutOfMemory, escaped_oom.next());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const escaped_source = "paramet\\u0065r\\u{3c0}";
    var escaped = Lexer.init(arena.allocator(), escaped_source);
    const decoded = try escaped.next();
    try std.testing.expectEqual(TokenKind.identifier, decoded.kind);
    try std.testing.expectEqualStrings("parameterπ", decoded.text);
    try std.testing.expect(decoded.escaped_identifier);
    try std.testing.expectEqual(@as(usize, 0), decoded.pos);
    try std.testing.expectEqual(escaped_source.len, decoded.end);
    try std.testing.expect(@intFromPtr(escaped_source.ptr) != @intFromPtr(decoded.text.ptr));

    const private_source = "#plain_π";
    var private_borrowed = Lexer.init(failing.allocator(), private_source);
    const plain_private_name = try private_borrowed.next();
    try std.testing.expectEqual(TokenKind.private_name, plain_private_name.kind);
    try std.testing.expectEqualStrings(private_source, plain_private_name.text);
    try std.testing.expectEqual(@intFromPtr(private_source.ptr), @intFromPtr(plain_private_name.text.ptr));
    try std.testing.expectEqual(@as(usize, 0), plain_private_name.pos);
    try std.testing.expectEqual(private_source.len, plain_private_name.end);

    var private_oom = Lexer.init(failing.allocator(), "#priv\\u0061te");
    try std.testing.expectError(error.OutOfMemory, private_oom.next());

    const escaped_private_source = "#priv\\u0061te";
    var private = Lexer.init(arena.allocator(), escaped_private_source);
    const private_name = try private.next();
    try std.testing.expectEqual(TokenKind.private_name, private_name.kind);
    try std.testing.expectEqualStrings("#private", private_name.text);
    try std.testing.expect(@intFromPtr(escaped_private_source.ptr) != @intFromPtr(private_name.text.ptr));
    try std.testing.expectEqual(@as(usize, 0), private_name.pos);
    try std.testing.expectEqual(escaped_private_source.len, private_name.end);
}

test "lexer decodes string escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "'a\\nb'");
    const t = try lx.next();
    try std.testing.expectEqual(TokenKind.string, t.kind);
    try std.testing.expectEqualStrings("a\nb", t.text);
}

test "lexer borrows unescaped strings and allocates only for decoding" {
    const source = "'plain source-backed string'";
    var no_memory: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_memory);
    var borrowed = Lexer.init(failing.allocator(), source);
    const token = try borrowed.next();
    try std.testing.expectEqualStrings("plain source-backed string", token.text);
    try std.testing.expectEqual(@intFromPtr(source.ptr + 1), @intFromPtr(token.text.ptr));
    try std.testing.expectEqual(TokenKind.eof, (try borrowed.next()).kind);

    var escaped = Lexer.init(failing.allocator(), "'plain\\nstring'");
    try std.testing.expectError(error.OutOfMemory, escaped.next());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var decoded = Lexer.init(arena.allocator(), "'raw\\nspan\\u0021tail'");
    try std.testing.expectEqualStrings("raw\nspan!tail", (try decoded.next()).text);
}

test "lexer rejects raw line terminators in literals" {
    const strings = [_][]const u8{
        "'\n'",
        "'\r'",
    };
    for (strings) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), src);
        try std.testing.expectError(LexError.UnterminatedString, lx.next());
    }

    const regexes = [_][]const u8{
        "/\n/",
        "/\r/",
        "/\xe2\x80\xa8/",
        "/\xe2\x80\xa9/",
        "/\\\n/",
        "/\\\xe2\x80\xa8/",
    };
    for (regexes) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), src);
        try std.testing.expectError(LexError.UnterminatedString, lx.next());
    }
}

test "lexer permits json-superset string separators" {
    const strings = [_]struct { src: []const u8, expected: []const u8 }{
        .{ .src = "'\xe2\x80\xa8'", .expected = "\xe2\x80\xa8" },
        .{ .src = "'\xe2\x80\xa9'", .expected = "\xe2\x80\xa9" },
    };
    for (strings) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), case.src);
        const t = try lx.next();
        try std.testing.expectEqual(TokenKind.string, t.kind);
        try std.testing.expectEqualStrings(case.expected, t.text);
    }
}

test "lexer string line continuations accept all line terminators" {
    const strings = [_][]const u8{
        "'a\\\nb'",
        "'a\\\r\nb'",
        "'a\\\xe2\x80\xa8b'",
        "'a\\\xe2\x80\xa9b'",
    };
    for (strings) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), src);
        const t = try lx.next();
        try std.testing.expectEqual(TokenKind.string, t.kind);
        try std.testing.expectEqualStrings("ab", t.text);
    }
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

test "lexer hashbang comments stop at all line terminators" {
    const cases = [_][]const u8{
        "#! hashbang\n{}",
        "#! hashbang\r{}",
        "#! hashbang\xe2\x80\xa8{}",
        "#! hashbang\xe2\x80\xa9{}",
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var lx = Lexer.init(arena.allocator(), src);
        try std.testing.expectEqual(TokenKind.lbrace, (try lx.next()).kind);
        try std.testing.expectEqual(TokenKind.rbrace, (try lx.next()).kind);
        try std.testing.expectEqual(TokenKind.eof, (try lx.next()).kind);
    }
}

test "lexer single-line comments allow WTF-8 surrogate bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lx = Lexer.init(arena.allocator(), "// comment \xed\xa0\x80 text\n{}");
    try std.testing.expectEqual(TokenKind.lbrace, (try lx.next()).kind);
    try std.testing.expectEqual(TokenKind.rbrace, (try lx.next()).kind);
    try std.testing.expectEqual(TokenKind.eof, (try lx.next()).kind);
}
