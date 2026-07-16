//! Native (Zig) implementations of common JS global functions and the `Math`,
//! `Object`, and `Array` namespace methods. Each is a `value.NativeFn`: the
//! first argument is the `*Interpreter` (type-erased), so a builtin can allocate
//! via its arena and raise JS exceptions. Registered in `interpreter.installGlobals`.

const std = @import("std");
const gc_mod = @import("gc.zig");
const value = @import("value.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const promise = @import("promise.zig");
const agent = @import("agent.zig");

const Value = value.Value;
const HostError = value.HostError;

fn interp(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn enterActiveNativeRealm(self: *Interpreter) ?*interpreter.Environment {
    const saved = self.env;
    if (self.active_native) |callee| {
        if (callee.private_data) |pd| {
            self.env = @ptrCast(@alignCast(pd));
            return saved;
        }
    }
    return null;
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undef();
}

/// Whether `v` is an ECMAScript Object — `.object` that is not one of the
/// primitive values represented as objects internally (BigInt, Symbol).
/// True for a genuine Object — excluding the internally object-tagged primitives
/// (Symbol, BigInt). The Reflect.* methods and several Object.* methods require
/// an Object argument and must throw TypeError for a Symbol/BigInt.
pub fn isRealObject(v: Value) bool {
    return v.isObject() and !v.asObj().is_bigint and !v.asObj().is_symbol;
}

// ---- global functions --------------------------------------------------

pub fn isNaNFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    // Spec: `Let num be ? ToNumber(number)` — so a Symbol/BigInt argument and an
    // object whose toPrimitive throws propagate that throw, not silently NaN.
    const n = try interp(ctx).toNumberV(arg(args, 0));
    return Value.boolVal(std.math.isNan(n));
}

pub fn isFiniteFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const n = try interp(ctx).toNumberV(arg(args, 0));
    return Value.boolVal(!std.math.isNan(n) and !std.math.isInf(n));
}

pub fn stringFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    const s: []const u8 = blk: {
        if (args.len == 0) break :blk "";
        // String(symbol) (called, not constructed) → SymbolDescriptiveString; in
        // any other case ToString (toStringV, running @@toPrimitive/toString/
        // valueOf and throwing for a Symbol under `new String(sym)`).
        if (ip.new_target.isUndefined() and args[0].isObject() and args[0].asObj().is_symbol)
            break :blk try std.fmt.allocPrint(ip.arena, "Symbol({s})", .{args[0].asObj().symbolDescription() orelse ""});
        break :blk try ip.toStringV(args[0]);
    };
    if (!ip.new_target.isUndefined()) return ip.makeWrapper(try Value.strAlloc(ip.arena, s));
    return try Value.strAlloc(ip.arena, s);
}

pub fn numberFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    const n: f64 = if (args.len == 0) 0 else blk: {
        const v = args[0];
        // ToNumeric: an object coerces via ToPrimitive(number) (valueOf/@@toPrimitive)
        // — e.g. a Date yields its time value; a Symbol is a TypeError. A BigInt
        // operand converts to the nearest Number (Number(10n) === 10).
        if (v.isObject() and !v.asObj().is_bigint) {
            if (v.asObj().is_symbol) return ip.throwError("TypeError", "Cannot convert a Symbol value to a number");
            const prim = try ip.toPrimitive(v, .number);
            if (prim.isObject() and prim.asObj().is_symbol) return ip.throwError("TypeError", "Cannot convert a Symbol value to a number");
            break :blk prim.toNumber();
        }
        break :blk v.toNumber();
    };
    if (!ip.new_target.isUndefined()) return ip.makeWrapper(Value.num(n));
    return Value.num(n);
}

pub fn booleanFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    const b = arg(args, 0).toBoolean();
    if (!ip.new_target.isUndefined()) return ip.makeWrapper(Value.boolVal(b));
    return Value.boolVal(b);
}

/// `Function(p1, ..., pn, body)` / `new Function(...)` — build a function from
/// source. The last argument is the body; the earlier ones are parameter lists
/// joined with commas. The text is wrapped in a function expression, parsed, and
/// evaluated in the global scope (where `Function`-created functions live).
pub fn functionConstructor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var params: std.ArrayListUnmanaged(u8) = .empty;
    var body: []const u8 = "";
    if (args.len > 0) {
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            if (i != 0) try params.append(self.arena, ',');
            try params.appendSlice(self.arena, try self.toStringV(args[i]));
        }
        body = try self.toStringV(args[args.len - 1]);
    }
    // CreateDynamicFunction uses the constructor's realm for parsing and for
    // any SyntaxError it creates, not the caller's current realm.
    const nt = self.new_target;
    const saved_env = self.env;
    var swapped = false;
    if (self.active_native) |callee| {
        if (callee.private_data) |pd| {
            self.env = @ptrCast(@alignCast(pd));
            swapped = true;
        }
    }
    if (!swapped and nt.isObject() and nt.asObj().native_ctor and nt.asObj().private_data != null) {
        self.env = @ptrCast(@alignCast(nt.asObj().private_data.?));
        swapped = true;
    }
    defer if (swapped) {
        self.env = saved_env;
    };
    // The `)` goes on its OWN line (matching the assembled source below): a
    // trailing Annex B HTML-open-comment param (`Function("<!--", "")`) comments
    // out to end-of-line, so without the newline it would swallow the `)`.
    const param_source = try std.fmt.allocPrint(self.arena, "({s}\n)", .{params.items});
    var param_lex_diagnostic: ?parser_mod.SourceLocation = null;
    var param_parser = Parser.initWithDiagnostic(self.arena, param_source, &param_lex_diagnostic) catch |err|
        return self.throwParserSyntaxErrorAt("Function parameters", param_lex_diagnostic orelse parser_mod.sourceLocationAt(param_source, 0), err);
    param_parser.parseDynamicFunctionParams(false, false) catch |err|
        return self.throwParserSyntaxError("Function parameters", param_source, &param_parser, err);
    const source = try std.fmt.allocPrint(self.arena, "(function({s}\n) {{\n{s}\n}})", .{ params.items, body });
    var lex_diagnostic: ?parser_mod.SourceLocation = null;
    var parser = Parser.initWithDiagnostic(self.arena, source, &lex_diagnostic) catch |err|
        return self.throwParserSyntaxErrorAt("Function body", lex_diagnostic orelse parser_mod.sourceLocationAt(source, 0), err);
    const prog = parser.parseProgram() catch |err|
        return self.throwParserSyntaxError("Function body", source, &parser, err);
    // Create the function in the Function constructor's own realm (so its
    // closure — and thus [[Realm]] — is that realm).
    const fn_v = try self.eval(prog);
    if (fn_v.isObject() and fn_v.asObj().jsFunction() != null) {
        try fn_v.asObj().setOwn(self.arena, self.root_shape, "name", Value.str("anonymous"));
        try fn_v.asObj().setAttr(self.arena, "name", .{ .writable = false, .enumerable = false, .configurable = true });
        if (Interpreter.funcOf(fn_v)) |f| {
            f.name = "anonymous";
            f.source = try std.fmt.allocPrint(self.arena, "function anonymous({s}\n) {{\n{s}\n}}", .{ params.items, body });
        }
        if (nt.isObject()) fn_v.asObj().proto = try self.ctorRealmIntrinsicProto(nt.asObj(), "Function");
        _ = try self.protoObject(fn_v.asObj());
        try fn_v.asObj().setAttr(self.arena, "prototype", .{ .writable = true, .enumerable = false, .configurable = false });
    }
    return fn_v;
}

/// Byte offset past the leading run of ECMAScript StrWhiteSpace (WhiteSpace +
/// LineTerminator, the same set `trim` strips) in UTF-8 `s` — for parseInt /
/// parseFloat, whose argument is trimmed of leading whitespace before scanning.
fn skipStrWhiteSpace(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const len: usize = if (c < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(c) catch break);
        if (i + len > s.len) break;
        const cp: u21 = if (len == 1) @as(u21, c) else (std.unicode.utf8Decode(s[i .. i + len]) catch break);
        if (!interpreter.isJsTrimCp(cp)) break;
        i += len;
    }
    return i;
}

pub fn parseFloatFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // ToString(string) — throws a TypeError for a Symbol argument (per spec),
    // rather than silently stringifying it to NaN.
    const s = try self.toStringV(arg(args, 0));
    const nan = std.math.nan(f64);
    // ParseFloat: trim leading StrWhiteSpace, then take the longest prefix that is
    // a StrDecimalLiteral. We scan that grammar by hand rather than leaning on
    // `std.fmt.parseFloat`, which accepts Zig-isms JS rejects (notably `_`
    // digit separators, so `parseFloat("1_0")` must be 1, not 10).
    var i = skipStrWhiteSpace(s);
    const sign_start = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    // "Infinity" (optionally signed) parses to ±∞.
    if (std.mem.startsWith(u8, s[i..], "Infinity"))
        return Value.num(if (i > sign_start and s[sign_start] == '-') -std.math.inf(f64) else std.math.inf(f64));
    const num_start = i;
    var saw_digit = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return Value.num(nan); // no mantissa digits → NaN
    // An exponent counts only if it has at least one digit; otherwise the `e`
    // is not part of the number (`parseFloat("1e")` is 1).
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and s[j] >= '0' and s[j] <= '9') {
            while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
            i = j;
        }
    }
    const n = std.fmt.parseFloat(f64, s[num_start..i]) catch return Value.num(nan);
    return Value.num(if (sign_start != num_start and s[sign_start] == '-') -n else n);
}

pub fn parseIntFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // ToString(string) — throws a TypeError for a Symbol argument (per spec).
    const s = try self.toStringV(arg(args, 0));
    var radix: i32 = 10;
    var strip_prefix = true;
    if (args.len >= 2 and !args[1].isUndefined()) {
        const r = @as(i32, @bitCast(Value.uint32FromF64(try self.toNumberV(args[1]))));
        if (r != 0) {
            if (r < 2 or r > 36) return Value.num(std.math.nan(f64));
            radix = r;
            strip_prefix = r == 16;
        }
    }
    // Skip leading StrWhiteSpace (the full WhiteSpace+LineTerminator set, incl.
    // U+2028/U+2029 and non-ASCII spaces), not just the four ASCII blanks.
    var i: usize = skipStrWhiteSpace(s);
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    if (strip_prefix and i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        radix = 16;
        i += 2;
    }
    const digit_start = i;
    var acc: f64 = 0;
    var any = false;
    while (i < s.len) : (i += 1) {
        const d = digitValue(s[i]);
        if (d == null or @as(i32, d.?) >= radix) break;
        acc = acc * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d.?));
        any = true;
    }
    if (!any) return Value.num(std.math.nan(f64));
    // The digit-by-digit accumulation above drifts by up to a few ULP once the
    // value exceeds 2^53. For decimal (the common case) re-parse the digit run
    // with a correctly-rounded string→f64 conversion so large inputs round like
    // the spec (and other engines) require.
    if (radix == 10 and i - digit_start > 15) {
        if (std.fmt.parseFloat(f64, s[digit_start..i])) |exact| {
            return Value.num(if (neg) -exact else exact);
        } else |_| {}
    }
    return Value.num(if (neg) -acc else acc);
}

fn digitValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => null,
    };
}

// ---- Math --------------------------------------------------------------

fn num1(ctx: *anyopaque, args: []const Value) HostError!f64 {
    return interp(ctx).toNumberV(arg(args, 0));
}

pub fn mathFloor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.num(@floor(try num1(ctx, args)));
}
pub fn mathCeil(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.num(@ceil(try num1(ctx, args)));
}
pub fn mathTrunc(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.num(@trunc(try num1(ctx, args)));
}
pub fn mathRound(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const n = try num1(ctx, args);
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return Value.num(n); // preserves ±0
    if (@abs(n) >= 0x1.0p52) return Value.num(n);
    // Halves round toward +Infinity, but a value rounding to zero keeps the
    // sign of the operand: `Math.round(-0.5)` is -0, `Math.round(-0.4)` is -0.
    if (n > 0 and n < 0.5) return Value.num(0);
    if (n < 0 and n >= -0.5) return Value.num(-0.0);
    return Value.num(@floor(n + 0.5));
}
pub fn mathAbs(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.num(@abs(try num1(ctx, args)));
}
pub fn mathSqrt(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.num(@sqrt(try num1(ctx, args)));
}
pub fn mathSign(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const n = try num1(ctx, args);
    if (std.math.isNan(n)) return Value.num(n);
    if (n > 0) return Value.num(1);
    if (n < 0) return Value.num(-1);
    return Value.num(n); // preserves +0 / -0
}
pub fn mathPow(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const base = try self.toNumberV(arg(args, 0));
    const exp = try self.toNumberV(arg(args, 1));
    // JS exponentiation overrides IEEE pow: a NaN exponent is always NaN (even
    // `pow(1, NaN)`), and `pow(±1, ±Infinity)` is NaN (IEEE returns 1).
    if (std.math.isNan(exp)) return Value.num(std.math.nan(f64));
    if (std.math.isInf(exp) and @abs(base) == 1) return Value.num(std.math.nan(f64));
    return Value.num(std.math.pow(f64, base, exp));
}
pub fn mathMax(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var m: f64 = -std.math.inf(f64);
    var saw_nan = false;
    for (args) |v| {
        const n = try self.toNumberV(v); // ToNumber per element, in order
        if (std.math.isNan(n)) {
            saw_nan = true;
            continue;
        }
        // +0 is greater than -0: prefer +0 when both are zero.
        if (n > m or (n == 0 and m == 0 and std.math.signbit(m) and !std.math.signbit(n))) m = n;
    }
    if (saw_nan) return Value.num(std.math.nan(f64));
    return Value.num(m);
}
pub fn mathMin(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var m: f64 = std.math.inf(f64);
    var saw_nan = false;
    for (args) |v| {
        const n = try self.toNumberV(v);
        if (std.math.isNan(n)) {
            saw_nan = true;
            continue;
        }
        // -0 is less than +0: prefer -0 when both are zero.
        if (n < m or (n == 0 and m == 0 and !std.math.signbit(m) and std.math.signbit(n))) m = n;
    }
    if (saw_nan) return Value.num(std.math.nan(f64));
    return Value.num(m);
}

/// Build a `Math` native from a plain `f64 -> f64` function (the trig / log /
/// exp family). Keeps registration to one line each.
pub fn unaryMath(comptime f: fn (f64) f64) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = this;
            return Value.num(f(try interp(ctx).toNumberV(arg(args, 0))));
        }
    }.call;
}

/// f64 wrappers for the unary Math functions (Zig builtins where available,
/// std.math otherwise).
pub const mfns = struct {
    pub fn sin(x: f64) f64 {
        return @sin(x);
    }
    pub fn cos(x: f64) f64 {
        return @cos(x);
    }
    pub fn tan(x: f64) f64 {
        return std.math.tan(x);
    }
    pub fn asin(x: f64) f64 {
        return std.math.asin(x);
    }
    pub fn acos(x: f64) f64 {
        return std.math.acos(x);
    }
    pub fn atan(x: f64) f64 {
        return std.math.atan(x);
    }
    pub fn sinh(x: f64) f64 {
        return std.math.sinh(x);
    }
    pub fn cosh(x: f64) f64 {
        return std.math.cosh(x);
    }
    pub fn tanh(x: f64) f64 {
        return std.math.tanh(x);
    }
    pub fn asinh(x: f64) f64 {
        return std.math.asinh(x);
    }
    pub fn acosh(x: f64) f64 {
        return std.math.acosh(x);
    }
    pub fn atanh(x: f64) f64 {
        return std.math.atanh(x);
    }
    pub fn exp(x: f64) f64 {
        if (x == 1) return std.math.e;
        if (x == -1) return 1.0 / std.math.e;
        return @exp(x);
    }
    pub fn expm1(x: f64) f64 {
        return std.math.expm1(x);
    }
    pub fn log(x: f64) f64 {
        return @log(x);
    }
    pub fn log2(x: f64) f64 {
        if (exactLog2Power(x)) |e| return @floatFromInt(e);
        return @log2(x);
    }
    pub fn log10(x: f64) f64 {
        return @log10(x);
    }
    pub fn log1p(x: f64) f64 {
        return std.math.log1p(x);
    }
    pub fn cbrt(x: f64) f64 {
        return std.math.cbrt(x);
    }
    pub fn fround(x: f64) f64 {
        return @floatCast(@as(f32, @floatCast(x))); // round to nearest float32
    }
    pub fn f16round(x: f64) f64 {
        return @floatCast(@as(f16, @floatCast(x))); // round to nearest binary16 (ES2025)
    }
};

fn exactLog2Power(x: f64) ?i32 {
    if (x <= 0 or !std.math.isFinite(x)) return null;
    const bits: u64 = @bitCast(x);
    const exp_bits: u11 = @intCast((bits >> 52) & 0x7ff);
    const mant = bits & ((@as(u64, 1) << 52) - 1);
    if (exp_bits != 0) {
        if (mant != 0) return null;
        return @as(i32, @intCast(exp_bits)) - 1023;
    }
    if (mant == 0 or (mant & (mant - 1)) != 0) return null;
    return @as(i32, @intCast(@ctz(mant))) - 1074;
}

pub fn mathAtan2(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const y = try self.toNumberV(arg(args, 0));
    const x = try self.toNumberV(arg(args, 1));
    return Value.num(std.math.atan2(y, x));
}

pub fn mathHypot(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // Scale by the running max magnitude so no square overflows or underflows:
    // hypot(1e200) is 1e200 (naive n*n gives Infinity), hypot(5e-324, 5e-324)
    // is ~7e-324 (naive gives 0). Every arg is still coerced in order (abrupt
    // propagates), and ±Infinity wins over NaN per the spec.
    var any_inf = false;
    var any_nan = false;
    var max: f64 = 0;
    var sum: f64 = 0; // running sum of (arg / max)^2
    for (args) |v| {
        const n = try self.toNumberV(v);
        if (std.math.isInf(n)) any_inf = true;
        if (std.math.isNan(n)) any_nan = true;
        const a = @abs(n);
        if (a > max) {
            if (max != 0) {
                const ratio = max / a; // rescale the accumulated sum to the new max
                sum = sum * ratio * ratio;
            }
            sum += 1; // the new max contributes (a/a)^2 = 1
            max = a;
        } else if (max != 0) {
            const ratio = a / max;
            sum += ratio * ratio;
        }
    }
    if (any_inf) return Value.num(std.math.inf(f64));
    if (any_nan) return Value.num(std.math.nan(f64));
    return Value.num(max * @sqrt(sum)); // max==0 (all zero / no args) -> 0
}

// ---- Math.sumPrecise (ES2025): maximally-precise summation -----------------
//
// Each finite double is added *exactly* into a fixed-point superaccumulator —
// a two's-complement integer equal to (exact sum) × 2^1074 (1074 = the bit
// offset of the smallest subnormal). A double `m × 2^e` contributes its 53-bit
// mantissa at bit position `e + 1074`, so no intermediate value overflows (the
// `[1e308, 1e308, …, -1e308, -1e308]` cancellation is exact), and the result is
// converted to f64 with a single round-to-nearest-even at the end.
const SUM_WORDS = 72; // u32 limbs ≈ 2304 bits; max |sum| ≈ 2^2098 scaled, ample headroom

/// Add `mantissa` (≤53 significant bits) shifted left by `bitpos` into the
/// little-endian two's-complement accumulator, subtracting when `neg`.
fn sumAddShifted(acc: *[SUM_WORDS]u32, mantissa: u64, bitpos: usize, neg: bool) void {
    const word = bitpos / 32;
    const off: u7 = @intCast(bitpos % 32);
    const wide: u128 = @as(u128, mantissa) << off; // spans ≤3 limbs
    const parts = [3]u32{ @truncate(wide), @truncate(wide >> 32), @truncate(wide >> 64) };
    if (!neg) {
        var carry: u64 = 0;
        var i: usize = 0;
        while (word + i < SUM_WORDS) : (i += 1) {
            const add: u64 = (if (i < 3) parts[i] else 0) + carry;
            const s = @as(u64, acc[word + i]) + add;
            acc[word + i] = @truncate(s);
            carry = s >> 32;
            if (i >= 3 and carry == 0) break;
        }
    } else {
        var borrow: u64 = 0;
        var i: usize = 0;
        while (word + i < SUM_WORDS) : (i += 1) {
            const sub: u64 = (if (i < 3) parts[i] else 0) + borrow;
            const cur = @as(u64, acc[word + i]);
            if (cur >= sub) {
                acc[word + i] = @truncate(cur - sub);
                borrow = 0;
            } else {
                acc[word + i] = @truncate(cur + (@as(u64, 1) << 32) - sub);
                borrow = 1;
            }
            if (i >= 3 and borrow == 0) break;
        }
    }
}

/// Add one finite double exactly (its zero contributes nothing — handled by the caller).
fn sumAddDouble(acc: *[SUM_WORDS]u32, x: f64) void {
    const bits: u64 = @bitCast(x);
    const neg = (bits >> 63) == 1;
    const biased = (bits >> 52) & 0x7FF;
    const frac = bits & 0xFFFFFFFFFFFFF;
    // Subnormal: mantissa = frac, LSB at 2^-1074 (bit 0). Normal: implicit bit
    // set, LSB at bit (biased - 1) of the scaled accumulator.
    const mantissa: u64 = if (biased == 0) frac else (frac | (@as(u64, 1) << 52));
    const bitpos: usize = if (biased == 0) 0 else @intCast(biased - 1);
    sumAddShifted(acc, mantissa, bitpos, neg);
}

/// Up to 64 bits of the magnitude starting at bit `start`.
fn sumReadBits(acc: *const [SUM_WORDS]u32, start: usize, n: u32) u64 {
    const w = start / 32;
    const off: u7 = @intCast(start % 32);
    var v: u128 = 0;
    var k: usize = 0;
    while (k < 3 and w + k < SUM_WORDS) : (k += 1) v |= @as(u128, acc[w + k]) << @as(u7, @intCast(k * 32));
    v >>= off;
    const mask: u128 = if (n >= 64) ~@as(u64, 0) else (@as(u128, 1) << @as(u7, @intCast(n))) - 1;
    return @truncate(v & mask);
}

/// Any set bit strictly below position `p`?
fn sumAnyBitBelow(acc: *const [SUM_WORDS]u32, p: usize) bool {
    const w = p / 32;
    const off = p % 32;
    var i: usize = 0;
    while (i < w) : (i += 1) if (acc[i] != 0) return true;
    if (off > 0 and w < SUM_WORDS) {
        const mask = (@as(u32, 1) << @as(u5, @intCast(off))) - 1;
        if (acc[w] & mask != 0) return true;
    }
    return false;
}

/// Convert the accumulator (exact sum × 2^1074, two's complement) to the nearest
/// f64 (ties to even); ±Infinity on overflow. Returns +0 for a zero magnitude
/// (the caller decides the zero sign). Mutates `acc` (negates in place if needed).
fn sumRoundToF64(acc: *[SUM_WORDS]u32) f64 {
    const neg = (acc[SUM_WORDS - 1] >> 31) == 1;
    if (neg) { // two's-complement negate → magnitude
        var carry: u64 = 1;
        for (acc) |*w| {
            const s = @as(u64, ~w.*) + carry;
            w.* = @truncate(s);
            carry = s >> 32;
        }
    }
    // Highest set bit.
    var msb: isize = -1;
    var wi: isize = SUM_WORDS - 1;
    while (wi >= 0) : (wi -= 1) {
        const w = acc[@intCast(wi)];
        if (w != 0) {
            msb = wi * 32 + (31 - @as(isize, @clz(w)));
            break;
        }
    }
    if (msb < 0) return 0; // zero magnitude
    const L: usize = @intCast(msb + 1);
    var mantissa: u64 = undefined;
    var shift: usize = undefined; // low bits dropped
    if (L <= 53) {
        mantissa = sumReadBits(acc, 0, 64);
        shift = 0;
    } else {
        shift = L - 53;
        const top54 = sumReadBits(acc, shift - 1, 54);
        const guard = top54 & 1;
        mantissa = top54 >> 1; // 53 bits
        const sticky = sumAnyBitBelow(acc, shift - 1);
        if (guard == 1 and (sticky or (mantissa & 1) == 1)) {
            mantissa += 1;
            if (mantissa == (@as(u64, 1) << 53)) { // carry out of 53 bits
                mantissa >>= 1;
                shift += 1;
            }
        }
    }
    const val = std.math.ldexp(@as(f64, @floatFromInt(mantissa)), @as(i32, @intCast(shift)) - 1074);
    return if (neg) -val else val;
}

pub fn mathSumPrecise(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // GetIterator(items): a non-iterable argument is a TypeError.
    const iter = try self.iteratorOf(arg(args, 0));
    var acc = std.mem.zeroes([SUM_WORDS]u32);
    var count: usize = 0;
    var has_nan = false;
    var has_pos_inf = false;
    var has_neg_inf = false;
    var all_neg_zero = true; // an exact-zero result is -0 only if every element was -0
    while (true) {
        const r = try self.callMethod(iter, "next", &.{});
        if (!isRealObject(r)) return self.throwError("TypeError", "iterator.next() did not return an object");
        if ((try self.getProperty(r, "done")).toBoolean()) break;
        const v = try self.getProperty(r, "value");
        if (!v.isNumber()) {
            self.iteratorClose(iter) catch {};
            return self.throwError("TypeError", "Math.sumPrecise: every element must be a Number");
        }
        count += 1;
        const x = v.asNum();
        if (std.math.isNan(x)) {
            has_nan = true;
            all_neg_zero = false;
            continue;
        }
        if (std.math.isInf(x)) {
            if (x > 0) has_pos_inf = true else has_neg_inf = true;
            all_neg_zero = false;
            continue;
        }
        if (!(x == 0 and std.math.signbit(x))) all_neg_zero = false;
        if (x != 0) sumAddDouble(&acc, x);
    }
    if (count == 0) return Value.num(-0.0);
    if (has_nan) return Value.num(std.math.nan(f64));
    if (has_pos_inf and has_neg_inf) return Value.num(std.math.nan(f64));
    if (has_pos_inf) return Value.num(std.math.inf(f64));
    if (has_neg_inf) return Value.num(-std.math.inf(f64));
    const result = sumRoundToF64(&acc);
    if (result == 0) return Value.num(if (all_neg_zero) -0.0 else 0.0);
    return Value.num(result);
}

pub fn mathClz32(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const n = try interp(ctx).toNumberV(arg(args, 0));
    return Value.num(@floatFromInt(@clz(Value.uint32FromF64(n))));
}

pub fn mathImul(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const a: i32 = @bitCast(Value.uint32FromF64(try self.toNumberV(arg(args, 0))));
    const b: i32 = @bitCast(Value.uint32FromF64(try self.toNumberV(arg(args, 1))));
    return Value.num(@floatFromInt(a *% b));
}

// Per-thread: concurrent agents each get their own PRNG stream (a shared one
// would be a data race — bindings.md ruling). Seed lazily from OS entropy so
// independent processes/threads do not replay one fixed Math.random sequence.
threadlocal var math_prng_seeded = false;
threadlocal var math_prng = std.Random.DefaultPrng.init(0);

fn mathRandomSeed() u64 {
    var bytes: [8]u8 = undefined;
    agent.engineIo().randomSecure(&bytes) catch {
        const now: u64 = @bitCast(@as(i64, @intCast(std.Io.Timestamp.now(agent.engineIo(), .awake).nanoseconds)));
        return 0x2545F4914F6CDD1D ^ now ^ @as(u64, @intCast(std.Thread.getCurrentId()));
    };
    return std.mem.readInt(u64, &bytes, .little);
}

fn mathRandomPrng() *std.Random.DefaultPrng {
    if (!math_prng_seeded) {
        math_prng = std.Random.DefaultPrng.init(mathRandomSeed());
        math_prng_seeded = true;
    }
    return &math_prng;
}

pub fn mathRandom(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return Value.num(mathRandomPrng().random().float(f64));
}

// ---- Object / Array ----------------------------------------------------

/// Own enumerable string keys of `o`, in spec order. Use the full
/// [[OwnPropertyKeys]] path so exotic own keys (String and TypedArray indices,
/// module namespace exports, Proxy traps, array dense elements) are included,
/// then filter through [[GetOwnProperty]] for the live enumerable bit.
pub fn ownEnumerableKeys(self: *Interpreter, o: *value.Object) HostError![]const []const u8 {
    try self.checkRestricted(o);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (try self.objectOwnKeysList(o)) |k| {
        if (value.isSymbolKey(k) or value.isPrivateKey(k)) continue;
        const desc = try objectGetOwnPropertyDescriptor(self, Value.undef(), &.{ Value.obj(o), try self.keyToValue(k) });
        if (desc.isObject() and (try self.getProperty(desc, "enumerable")).toBoolean())
            try list.append(self.arena, k);
    }
    return list.items;
}

/// Own value of `key` on `o`, resolving an array index to its dense element.
fn ownValueOf(o: *value.Object, key: []const u8) Value {
    if (o.is_array) {
        if (arrayIndexOf(key)) |i| {
            if (o.denseElement(i)) |v| return v;
        }
    }
    return o.getOwn(key) orelse Value.undef();
}

/// All own *string* keys of `o` in [[OwnPropertyKeys]] order (integer indices
/// ascending, then strings in insertion order) WITHOUT filtering on enumerable —
/// the EnumerableOwnPropertyNames snapshot, before the per-key live recheck.
fn ownStringKeysOrdered(self: *Interpreter, o: *value.Object) HostError![]const []const u8 {
    // [[OwnPropertyKeys]] (array indices / String chars / "length" / symbols, in
    // spec order), keeping only the string keys.
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (try self.objectOwnKeysList(o)) |k| {
        if (value.isSymbolKey(k) or value.isPrivateKey(k)) continue;
        try list.append(self.arena, k);
    }
    return list.items;
}

const EnumKind = enum { key, value, key_value };

/// EnumerableOwnProperties(ToObject(arg), kind): snapshot own string keys, then —
/// per key, in order — re-check [[Enumerable]] live (a getter run for an earlier
/// key may have toggled it) and [[Get]] the value (running accessors).
fn enumerableOwnProperties(self: *Interpreter, arg0: Value, kind: EnumKind) HostError!Value {
    const o = try self.toObject(arg0); // RequireObjectCoercible + ToObject
    const ov: Value = Value.obj(o);
    const result = try self.newArray();
    const is_proxy = o.proxyHandler() != null or o.proxy_revoked;
    const is_module_ns = interpreter.isModuleNs(o);
    for (try ownStringKeysOrdered(self, o)) |k| {
        // [[GetOwnProperty]] enumerable check, read live so an earlier getter's
        // mutation is observed; a key deleted in the meantime drops out.
        const enumerable = if (is_module_ns) blk: {
            const desc = try interpreter.moduleNsDesc(self, o, k);
            break :blk desc.isObject() and descBool(desc.asObj(), "enumerable", false);
        } else if (is_proxy) blk: {
            const desc = try objectGetOwnPropertyDescriptor(self, Value.undef(), &.{ ov, try self.keyToValue(k) });
            break :blk desc.isObject() and (try self.getProperty(desc, "enumerable")).toBoolean();
        } else if (o.boxedPrimitive() != null and o.boxedPrimitive().?.isString())
            // A String wrapper exposes only its char indices as enumerable own keys.
            (arrayIndexOf(k) != null and arrayIndexOf(k).? < o.boxedPrimitive().?.asStr().len)
        else if ((o.is_array or o.typedArray() != null) and std.mem.eql(u8, k, "length"))
            // An Array's / TypedArray's "length" is a non-enumerable own property.
            false
        else
            ((interpreter.objectHasOwn(o, k) or (if (o.is_array) blk: {
                const idx = arrayIndexOf(k) orelse break :blk false;
                break :blk o.denseElementPresent(idx);
            } else false)) and o.getAttr(k).enumerable);
        if (!enumerable) continue;
        if (kind == .key) {
            try result.asObj().appendElement(self.arena, try Value.strAlloc(self.arena, k));
            continue;
        }
        const v = try self.getProperty(ov, k); // [[Get]] — runs an accessor getter
        if (kind == .value) {
            try result.asObj().appendElement(self.arena, v);
        } else {
            const pair = try self.newArray();
            try pair.asObj().appendElement(self.arena, try Value.strAlloc(self.arena, k));
            try pair.asObj().appendElement(self.arena, v);
            try result.asObj().appendElement(self.arena, pair);
        }
    }
    return result;
}

pub fn objectKeys(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (args.len > 0 and args[0].isObject()) try self.checkRestricted(args[0].asObj());
    return enumerableOwnProperties(self, arg(args, 0), .key);
}

pub fn objectValues(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (args.len > 0 and args[0].isObject()) try self.checkRestricted(args[0].asObj());
    return enumerableOwnProperties(self, arg(args, 0), .value);
}

/// `Object.hasOwn(O, P)` — HasOwnProperty after ToObject(O) / ToPropertyKey(P).
/// The ergonomic replacement for `Object.prototype.hasOwnProperty.call`.
pub fn objectHasOwn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const o = try self.toObject(arg(args, 0));
    const key = try self.keyOf(arg(args, 1));
    return Value.boolVal(interpreter.objectHasOwn(o, key));
}

pub fn objectAssign(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // ToObject(target): null/undefined throw; a primitive boxes to a wrapper.
    const to = try self.toObject(arg(args, 0));
    const to_v: Value = Value.obj(to);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        // A null/undefined source is skipped; other primitives ToObject.
        if (args[i].isNull() or args[i].isUndefined()) continue;
        const from = try self.toObject(args[i]);
        const src_v: Value = Value.obj(from);
        const is_proxy = from.proxyHandler() != null or from.proxy_revoked;
        // Every enumerable own key — string AND symbol (private excluded) — is
        // copied, in [[OwnPropertyKeys]] order (array indices / String chars /
        // "length" / symbols all included).
        for (try self.objectOwnKeysList(from)) |k| {
            if (value.isPrivateKey(k)) continue;
            // [[GetOwnProperty]] for the enumerable bit (proxy-aware, and a key
            // dropped since the snapshot is skipped).
            const enumerable = if (is_proxy) blk: {
                const desc = try objectGetOwnPropertyDescriptor(self, Value.undef(), &.{ src_v, try self.keyToValue(k) });
                break :blk desc.isObject() and (try self.getProperty(desc, "enumerable")).toBoolean();
            } else if (from.boxedPrimitive() != null and from.boxedPrimitive().?.isString())
                // A String wrapper's only enumerable own keys are its char indices
                // ("length" and inherited methods are non-enumerable).
                (arrayIndexOf(k) != null and arrayIndexOf(k).? < from.boxedPrimitive().?.asStr().len)
            else if ((from.is_array or from.typedArray() != null) and std.mem.eql(u8, k, "length"))
                false
            else
                ((interpreter.objectHasOwn(from, k) or (if (from.is_array) blk: {
                    const idx = arrayIndexOf(k) orelse break :blk false;
                    break :blk from.denseElementPresent(idx);
                } else false)) and from.getAttr(k).enumerable);
            if (!enumerable) continue;
            // Get(from, key) runs a source getter, then Set(to, key, v, true) —
            // assignment to a read-only / non-extensible / setter-less target
            // property must throw, so force the throwing (strict) [[Set]].
            const v = try self.getProperty(src_v, k);
            const saved = self.strict;
            self.strict = true;
            self.setMember(to_v, k, v) catch |e| {
                self.strict = saved;
                return e;
            };
            self.strict = saved;
        }
    }
    return to_v;
}

pub fn objectEntries(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (args.len > 0 and args[0].isObject()) try self.checkRestricted(args[0].asObj());
    return enumerableOwnProperties(self, arg(args, 0), .key_value);
}

pub fn objectFromEntries(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const iterable = arg(args, 0);
    // RequireObjectCoercible(iterable): undefined/null throw.
    if (iterable.isNull() or iterable.isUndefined())
        return self.throwError("TypeError", "Object.fromEntries requires an iterable argument");
    const result = try self.newObject();
    const iter = try self.iteratorOf(iterable); // GetIterator — non-iterable throws
    while (true) {
        // IteratorStep: a next() that isn't callable / doesn't return an object
        // throws WITHOUT closing the iterator.
        const r = try self.callMethod(iter, "next", &.{});
        if (!r.isObject()) return self.throwError("TypeError", "iterator.next() did not return an object");
        if ((try self.getProperty(r, "done")).toBoolean()) break;
        const entry = try self.getProperty(r, "value");
        // Each entry must be an Object; otherwise close the iterator, then throw.
        if (!entry.isObject()) {
            self.iteratorClose(iter) catch {};
            return self.throwError("TypeError", "Object.fromEntries entry is not an object");
        }
        // AddEntriesFromIterable: k = Get(entry,"0"); v = Get(entry,"1"); THEN the
        // adder does ToPropertyKey(k) + CreateDataPropertyOrThrow — so the key's
        // ToString runs AFTER reading "1", and an abrupt completion in any step
        // closes the iterator (keeping the original throw).
        const k_raw = self.getProperty(entry, "0") catch |e| {
            self.iteratorCloseKeepingThrow(iter);
            return e;
        };
        const v = self.getProperty(entry, "1") catch |e| {
            self.iteratorCloseKeepingThrow(iter);
            return e;
        };
        const key = self.keyOf(k_raw) catch |e| {
            self.iteratorCloseKeepingThrow(iter);
            return e;
        };
        // CreateDataPropertyOrThrow(result, key, v): an own data property —
        // NOT [[Set]], so a poisoned Object.prototype setter is never invoked.
        try result.asObj().setOwn(self.arena, self.root_shape, key, v);
    }
    return result;
}

pub fn arrayOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    const saved_env = self.env;
    var swapped_env = false;
    if (self.active_native) |callee| {
        if (callee.private_data) |pd| {
            self.env = @ptrCast(@alignCast(pd));
            swapped_env = true;
        }
    }
    defer if (swapped_env) {
        self.env = saved_env;
    };
    // Array.of uses `this` as a constructor when it is one (so a subclass's
    // Array.of produces a subclass instance), via Construct(C, « len »).
    const len = args.len;
    const result: Value = if (interpreter.isConstructorValue(this))
        try self.construct(this, &.{Value.num(@floatFromInt(len))})
    else
        try self.newArray();
    for (args, 0..) |v, k| try createDataIndexOrThrow(self, result, k, v);
    try self.setMember(result, "length", Value.num(@floatFromInt(len)));
    return result;
}

/// `Array(...)` / `new Array(...)`: a single numeric argument is a length
/// (RangeError if not a valid array index count); otherwise the arguments become
/// the elements.
pub fn arrayConstructor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const arr = try self.newArray();
    if (self.new_target.isObject())
        arr.asObj().proto = try self.ctorRealmIntrinsicProto(self.new_target.asObj(), "Array");
    if (args.len == 1 and args[0].isNumber()) {
        const n = args[0].asNum();
        if (n < 0 or @trunc(n) != n or n > 4294967295) return self.throwError("RangeError", "Invalid array length");
        // `new Array(len)` is a sparse array — length `len`, no elements (every
        // index a hole, so `0 in new Array(1)` is false and forEach/map skip
        // them). Only the logical length is set.
        try arr.asObj().extendArrayLengthFloor(self.arena, @intFromFloat(n));
    } else {
        for (args) |v| try arr.asObj().appendElement(self.arena, v);
    }
    return arr;
}

/// `Object(...)` / `new Object(...)`: returns the argument coerced to an object
/// (a fresh `{}` for null/undefined; the object itself when already one).
pub fn objectConstructor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const saved_env = self.env;
    var swapped_env = false;
    if (self.active_native) |callee| {
        if (callee.private_data) |pd| {
            self.env = @ptrCast(@alignCast(pd));
            swapped_env = true;
        }
    }
    defer if (swapped_env) {
        self.env = saved_env;
    };
    if (self.new_target.isObject()) {
        if (self.active_native) |callee| {
            if (self.new_target.asObj() != callee) {
                const obj = (try self.newObject()).asObj();
                obj.proto = try self.ctorRealmIntrinsicProto(self.new_target.asObj(), "Object");
                return Value.obj(obj);
            }
        }
    }
    const v = arg(args, 0);
    if (v.isObject() and !v.asObj().is_bigint and !v.asObj().is_symbol) return v;
    if (v.isUndefined() or v.isNull()) {
        const obj = (try self.newObject()).asObj();
        if (self.new_target.isObject()) obj.proto = try self.ctorRealmIntrinsicProto(self.new_target.asObj(), "Object");
        return Value.obj(obj);
    }
    return Value.obj(try self.toObject(v));
}

/// CreateDataPropertyOrThrow(O, ToString(k), v) — define an own enumerable,
/// writable, configurable data property; throw if [[DefineOwnProperty]] fails.
fn createDataIndexOrThrow(self: *Interpreter, target: Value, k: usize, v: Value) HostError!void {
    if (target.isObject() and target.asObj().is_array and target.asObj().accessorsMap() == null) {
        // Fast path: appending the next index of a plain dense Array. The helper
        // does the next-index check and append under `elements_lock`.
        if (try target.asObj().appendDataIndexIfDense(self.arena, k, v)) return;
    }
    const key = try std.fmt.allocPrint(self.arena, "{d}", .{k});
    const desc = (try self.newObject()).asObj();
    try desc.setOwn(self.arena, self.root_shape, "value", v);
    try desc.setOwn(self.arena, self.root_shape, "writable", Value.boolVal(true));
    try desc.setOwn(self.arena, self.root_shape, "enumerable", Value.boolVal(true));
    try desc.setOwn(self.arena, self.root_shape, "configurable", Value.boolVal(true));
    if (!target.isObject()) return self.throwError("TypeError", "Cannot create property on non-object");
    if (!try defineOneResult(self, target.asObj(), key, desc))
        return self.throwError("TypeError", "Cannot create property");
}

fn setLengthOrThrow(self: *Interpreter, target: Value, len: usize) HostError!void {
    const saved = self.strict;
    self.strict = true;
    defer self.strict = saved;
    try self.setMember(target, "length", Value.num(@floatFromInt(len)));
}

pub fn arrayFrom(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    const saved_env = self.env;
    var swapped_env = false;
    if (self.active_native) |callee| {
        if (callee.private_data) |pd| {
            self.env = @ptrCast(@alignCast(pd));
            swapped_env = true;
        }
    }
    defer if (swapped_env) {
        self.env = saved_env;
    };
    const C = this; // the receiver: a constructor when called as Array.from / subclass.use_ctor below
    const items = arg(args, 0);
    const map_fn = arg(args, 1);
    const this_arg = arg(args, 2);
    var mapping = false;
    if (!map_fn.isUndefined()) {
        if (!map_fn.isCallable()) return self.throwError("TypeError", "Array.from: mapping function is not callable");
        mapping = true;
    }
    const use_ctor = interpreter.isConstructorValue(C);

    // GetMethod(items, @@iterator).
    var iter_method: Value = Value.undef();
    if (!items.isUndefined() and !items.isNull()) {
        if (self.wellKnownSymbolKey("iterator")) |ik| {
            const m = try self.getProperty(items, ik);
            if (!m.isUndefined() and !m.isNull()) {
                if (!m.isCallable()) return self.throwError("TypeError", "Array.from: @@iterator is not callable");
                iter_method = m;
            }
        }
    }

    if (!iter_method.isUndefined()) {
        const result: Value = if (use_ctor) try self.construct(C, &.{}) else try self.newArray();
        const it = try self.callValueWithThis(iter_method, &.{}, items);
        var k: usize = 0;
        while (true) {
            const res = try self.callMethod(it, "next", &.{});
            if (!isRealObject(res)) return self.throwError("TypeError", "iterator result is not an object");
            if ((try self.getProperty(res, "done")).toBoolean()) break;
            const v = try self.getProperty(res, "value");
            const mapped: Value = if (mapping) self.callValueWithThis(map_fn, &.{ v, Value.num(@floatFromInt(k)) }, this_arg) catch |e| {
                self.iteratorCloseKeepingThrow(it);
                return e;
            } else v;
            createDataIndexOrThrow(self, result, k, mapped) catch |e| {
                self.iteratorCloseKeepingThrow(it);
                return e;
            };
            k += 1;
        }
        try setLengthOrThrow(self, result, k);
        return result;
    }

    // Not iterable: ToObject(items) (throws for null/undefined), then copy
    // indices 0..LengthOfArrayLike-1 via [[Get]].
    const array_like = try self.toObject(items);
    // LengthOfArrayLike = ToLength(Get(arrayLike,"length")), clamped to
    // 2^53-1. `interpreter.toLen` intentionally caps at array-index range, which
    // would turn Infinity into a valid Array length here instead of letting
    // ArrayCreate/new Array reject it.
    const raw_len = try self.toNumberV(try self.getProperty(Value.obj(array_like), "length"));
    const to_length: f64 = if (std.math.isNan(raw_len) or raw_len <= 0) 0 else @min(@trunc(raw_len), 9007199254740991.0);
    if (!use_ctor and to_length > 4294967295.0) return self.throwError("RangeError", "Array.from: invalid array length");
    const len: usize = @intFromFloat(@min(to_length, 4294967295.0));
    const result: Value = if (use_ctor) try self.construct(C, &.{Value.num(to_length)}) else try self.newArray();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
        const v = try self.getProperty(Value.obj(array_like), key);
        const mapped: Value = if (mapping) try self.callValueWithThis(map_fn, &.{ v, Value.num(@floatFromInt(i)) }, this_arg) else v;
        try createDataIndexOrThrow(self, result, i, mapped);
    }
    try setLengthOrThrow(self, result, len);
    return result;
}

/// `Array.fromAsync(asyncItems, mapfn, thisArg)` — ES2024. Returns a promise of
/// an array built by async-iterating (Symbol.asyncIterator, else a sync iterable
/// wrapped so each value is awaited, else an array-like).
pub fn arrayFromAsync(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    const pobj = try promise.newPromise(self);
    const p = promise.promiseOf(Value.obj(pobj)).?;
    const result = arrayFromAsyncImpl(self, Value.obj(pobj), this, arg(args, 0), arg(args, 1), arg(args, 2)) catch |e| {
        if (e == error.Throw) {
            const reason = self.exception;
            self.exception = Value.undef();
            try promise.reject(self, p, reason);
            return Value.obj(pobj);
        }
        return e;
    };
    switch (result) {
        .immediate => |v| try promise.resolve(self, p, v),
        .scheduled => {},
    }
    return Value.obj(pobj);
}

const FromAsyncOutcome = union(enum) {
    immediate: Value,
    scheduled,
};

fn arrayFromAsyncImpl(self: *Interpreter, out_promise: Value, C: Value, items: Value, mapfn: Value, this_arg: Value) HostError!FromAsyncOutcome {
    var mapping = false;
    if (!mapfn.isUndefined()) {
        if (!mapfn.isCallable()) return self.throwError("TypeError", "Array.fromAsync: mapping function is not callable");
        mapping = true;
    }
    const use_ctor = interpreter.isConstructorValue(C);

    // GetMethod(items, @@asyncIterator), else GetMethod(items, @@iterator).
    var async_method: Value = Value.undef();
    var sync_method: Value = Value.undef();
    if (!items.isUndefined() and !items.isNull()) {
        if (self.wellKnownSymbolKey("asyncIterator")) |ak| {
            const m = try self.getProperty(items, ak);
            if (!m.isUndefined() and !m.isNull()) {
                if (!m.isCallable()) return self.throwError("TypeError", "Array.fromAsync: @@asyncIterator is not callable");
                async_method = m;
            }
        }
        if (async_method.isUndefined()) {
            if (self.wellKnownSymbolKey("iterator")) |ik| {
                const m = try self.getProperty(items, ik);
                if (!m.isUndefined() and !m.isNull()) {
                    if (!m.isCallable()) return self.throwError("TypeError", "Array.fromAsync: @@iterator is not callable");
                    sync_method = m;
                }
            }
        }
    }

    if (!async_method.isUndefined() or !sync_method.isUndefined()) {
        const is_async = !async_method.isUndefined();
        const method = if (is_async) async_method else sync_method;
        const result: Value = if (use_ctor) try self.construct(C, &.{}) else try self.newArray();
        const it = try self.callValueWithThis(method, &.{}, items);
        if (!is_async) {
            var k: usize = 0;
            if (try arrayFromAsyncSyncStep(self, it, mapfn, this_arg, mapping, k)) |mapped| {
                createDataIndexOrThrow(self, result, k, mapped) catch |e| {
                    self.iteratorCloseKeepingThrow(it);
                    return e;
                };
                k += 1;
                try scheduleArrayFromAsyncSyncRest(self, out_promise, result, it, mapfn, this_arg, mapping, k);
                return .scheduled;
            }
            try setLengthOrThrow(self, result, k);
            return .{ .immediate = result };
        }
        var k: usize = 0;
        while (true) {
            var res = try self.callMethod(it, "next", &.{});
            if (is_async) res = try self.awaitValue(res); // async next() yields a promise
            if (!isRealObject(res)) return self.throwError("TypeError", "Array.fromAsync: iterator result is not an object");
            if ((try self.getProperty(res, "done")).toBoolean()) break;
            var v = try self.getProperty(res, "value");
            // A sync iterable is wrapped as an async-from-sync iterator, which
            // awaits each produced value once.
            if (!is_async) {
                v = self.awaitValue(v) catch |e| {
                    self.iteratorCloseKeepingThrow(it);
                    return e;
                };
            }
            const mapped: Value = if (mapping) blk: {
                const mv = self.callValueWithThis(mapfn, &.{ v, Value.num(@floatFromInt(k)) }, this_arg) catch |e| {
                    self.iteratorCloseKeepingThrow(it);
                    return e;
                };
                break :blk self.awaitValue(mv) catch |e| {
                    self.iteratorCloseKeepingThrow(it);
                    return e;
                };
            } else v;
            createDataIndexOrThrow(self, result, k, mapped) catch |e| {
                self.iteratorCloseKeepingThrow(it);
                return e;
            };
            k += 1;
        }
        try setLengthOrThrow(self, result, k);
        return .{ .immediate = result };
    }

    // Not iterable: ToObject(items), await each index 0..length-1.
    const array_like = try self.toObject(items);
    // LengthOfArrayLike = ToLength(Get(arrayLike,"length")), clamped to 2^53-1.
    // (`interpreter.toLen` over-clamps to 2^32-1, which would mask the too-long
    // case below, so compute ToLength directly here.)
    const raw_len = try self.toNumberV(try self.getProperty(Value.obj(array_like), "length"));
    const to_length: f64 = if (std.math.isNan(raw_len) or raw_len <= 0) 0 else @min(@trunc(raw_len), 9007199254740991.0);
    // ArrayCreate(len) for the non-constructor case rejects len > 2^32 - 1.
    if (!use_ctor and to_length > 4294967295.0) return self.throwError("RangeError", "Array.fromAsync: invalid array length");
    const len: usize = @intFromFloat(@min(to_length, 4294967295.0));
    const result: Value = if (use_ctor) try self.construct(C, &.{Value.num(to_length)}) else try self.newArray();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
        const v = try self.awaitValue(try self.getProperty(Value.obj(array_like), key));
        const mapped: Value = if (mapping) try self.awaitValue(try self.callValueWithThis(mapfn, &.{ v, Value.num(@floatFromInt(i)) }, this_arg)) else v;
        try createDataIndexOrThrow(self, result, i, mapped);
    }
    try setLengthOrThrow(self, result, len);
    return .{ .immediate = result };
}

fn arrayFromAsyncSyncStep(self: *Interpreter, it: Value, mapfn: Value, this_arg: Value, mapping: bool, k: usize) HostError!?Value {
    const res = try self.callMethod(it, "next", &.{});
    if (!isRealObject(res)) return self.throwError("TypeError", "Array.fromAsync: iterator result is not an object");
    if ((try self.getProperty(res, "done")).toBoolean()) return null;
    var v = try self.getProperty(res, "value");
    v = self.awaitValue(v) catch |e| {
        self.iteratorCloseKeepingThrow(it);
        return e;
    };
    if (!mapping) return v;
    const mv = self.callValueWithThis(mapfn, &.{ v, Value.num(@floatFromInt(k)) }, this_arg) catch |e| {
        self.iteratorCloseKeepingThrow(it);
        return e;
    };
    return self.awaitValue(mv) catch |e| {
        self.iteratorCloseKeepingThrow(it);
        return e;
    };
}

fn scheduleArrayFromAsyncSyncRest(self: *Interpreter, out_promise: Value, result: Value, it: Value, mapfn: Value, this_arg: Value, mapping: bool, k: usize) HostError!void {
    const cb = try gc_mod.allocObj(self.arena);
    cb.* = .{ .native = arrayFromAsyncSyncRestFn };
    try cb.appendInternalElement(self.arena, out_promise);
    try cb.appendInternalElement(self.arena, result);
    try cb.appendInternalElement(self.arena, it);
    try cb.appendInternalElement(self.arena, mapfn);
    try cb.appendInternalElement(self.arena, this_arg);
    try cb.appendInternalElement(self.arena, Value.num(@floatFromInt(k)));
    try cb.appendInternalElement(self.arena, Value.boolVal(mapping));

    const tick_obj = try promise.newPromise(self);
    const tick = promise.promiseOf(Value.obj(tick_obj)).?;
    try promise.resolve(self, tick, Value.undef());
    _ = try promise.then(self, tick, Value.obj(cb), Value.undef());
}

fn arrayFromAsyncSyncRestFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    _ = args;
    const self = interp(ctx);
    const cb = self.active_native orelse return Value.undef();
    if (cb.elementsLen() < 7) return Value.undef();
    const out_p = promise.promiseOf(cb.elementAt(0) orelse return Value.undef()) orelse return Value.undef();
    const result = cb.elementAt(1) orelse return Value.undef();
    const it = cb.elementAt(2) orelse return Value.undef();
    const mapfn = cb.elementAt(3) orelse return Value.undef();
    const this_arg = cb.elementAt(4) orelse return Value.undef();
    var k = interpreter.toLen((cb.elementAt(5) orelse return Value.undef()).toNumber());
    const mapping = (cb.elementAt(6) orelse return Value.undef()).toBoolean();

    while (true) {
        const mapped = arrayFromAsyncSyncStep(self, it, mapfn, this_arg, mapping, k) catch |e| {
            if (e == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                try promise.reject(self, out_p, reason);
                return Value.undef();
            }
            return e;
        } orelse break;
        createDataIndexOrThrow(self, result, k, mapped) catch |e| {
            self.iteratorCloseKeepingThrow(it);
            if (e == error.Throw) {
                const reason = self.exception;
                self.exception = Value.undef();
                try promise.reject(self, out_p, reason);
                return Value.undef();
            }
            return e;
        };
        k += 1;
        _ = cb.setElementAt(5, Value.num(@floatFromInt(k)));
    }
    setLengthOrThrow(self, result, k) catch |e| {
        if (e == error.Throw) {
            const reason = self.exception;
            self.exception = Value.undef();
            try promise.reject(self, out_p, reason);
            return Value.undef();
        }
        return e;
    };
    try promise.resolve(self, out_p, result);
    return Value.undef();
}

pub fn identity1(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return arg(args, 0);
}

pub fn arrayIsArray(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.boolVal(try isArrayValue(interp(ctx), arg(args, 0)));
}

fn isArrayValue(self: *Interpreter, v: Value) HostError!bool {
    if (!v.isObject()) return false;
    var o = v.asObj();
    while (true) {
        if (o.proxy_revoked) return self.throwError("TypeError", "Cannot perform 'IsArray' on a revoked proxy");
        if (o.proxyHandler() != null) {
            o = o.proxyTarget() orelse return self.throwError("TypeError", "Cannot perform 'IsArray' on a revoked proxy");
            continue;
        }
        // The arguments exotic object is array-like but not an Array.
        return o.is_array and !o.is_arguments;
    }
}

pub fn mapFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    // Map/WeakMap are constructors only: a plain call (`Map()`) throws.
    if (ip.new_target.isUndefined()) return ip.throwError("TypeError", "Constructor Map/WeakMap requires 'new'");
    return ip.makeMap(arg(args, 0));
}

pub fn weakMapFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    if (ip.new_target.isUndefined()) return ip.throwError("TypeError", "Constructor Map/WeakMap requires 'new'");
    return ip.makeWeakMap(arg(args, 0));
}

pub fn setFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    if (ip.new_target.isUndefined()) return ip.throwError("TypeError", "Constructor Set/WeakSet requires 'new'");
    return ip.makeSet(arg(args, 0));
}

pub fn weakSetFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    if (ip.new_target.isUndefined()) return ip.throwError("TypeError", "Constructor Set/WeakSet requires 'new'");
    return ip.makeWeakSet(arg(args, 0));
}

/// `RegExp(pattern, flags)` / `new RegExp(...)`.
pub fn regExpFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const a0 = arg(args, 0);
    const flags_arg = arg(args, 1);
    const pattern_is_regexp = try self.isRegExp(a0);
    const regexp_ctor = self.env.get("RegExp") orelse Value.undef();
    const new_target = if (self.new_target.isUndefined()) regexp_ctor else self.new_target;

    if (self.new_target.isUndefined() and pattern_is_regexp and flags_arg.isUndefined()) {
        const ctor = try self.getProperty(a0, "constructor");
        if (value.strictEquals(ctor, new_target)) return a0;
    }

    var internal_pattern: ?[]const u8 = null;
    var internal_flags: ?[]const u8 = null;
    if (a0.isObject() and a0.asObj().behavior.is_regex) {
        internal_pattern = a0.asObj().regexSource();
        internal_flags = a0.asObj().regexFlags();
    }

    if (!self.new_target.isUndefined()) _ = try self.regexpPrototypeFromNewTarget();

    // RegExpInitialize (22.2.3.1): the pattern/flags VALUES may be undefined,
    // which maps to "" (not ToString(undefined) = "undefined"). For a
    // regexp-LIKE object (IsRegExp via @@match, but not an actual RegExp) the
    // values come from Get(obj,"source")/Get(obj,"flags"), and an absent property
    // reads undefined — so `new RegExp({[Symbol.match]:true})` is /(?:)/, not a
    // SyntaxError from parsing the literal "undefined".
    const pattern: []const u8 = if (internal_pattern) |p| p else blk: {
        const pv = if (pattern_is_regexp) try self.getProperty(a0, "source") else a0;
        break :blk if (pv.isUndefined()) "" else try self.toStringV(pv);
    };
    const flags: []const u8 = if (!flags_arg.isUndefined())
        try self.toStringV(flags_arg)
    else if (internal_flags) |f|
        f
    else blk: {
        const fv = if (pattern_is_regexp) try self.getProperty(a0, "flags") else Value.undef();
        break :blk if (fv.isUndefined()) "" else try self.toStringV(fv);
    };
    return self.makeRegex(pattern, flags);
}

pub fn objectGetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (v.isObject()) {
        const o = v.asObj();
        if (o.proxyHandler() != null or o.proxy_revoked) return self.proxyGetProto(o);
        // [[GetPrototypeOf]]: a callable with no explicit prototype reports
        // %Function.prototype% (every function inherits it).
        if (self.effectiveProto(o)) |p| return Value.obj(p);
        return Value.nul();
    }
    // ES2015+: ToObject(O) — null/undefined throw a TypeError; a primitive boxes
    // to its wrapper, so `Object.getPrototypeOf(0) === Number.prototype`.
    const boxed = try self.toObject(v);
    if (self.effectiveProto(boxed)) |p| return Value.obj(p);
    return Value.nul();
}

pub fn objectCreate(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const obj = (try self.newObject()).asObj();
    switch (arg(args, 0).kind()) {
        .object => obj.setProtoAtomic(arg(args, 0).asObj()),
        .null => obj.setProtoAtomic(null),
        else => return self.throwError("TypeError", "Object prototype may only be an Object or null"),
    }
    // The optional second argument is a Properties object processed exactly like
    // `Object.defineProperties` (skipped only when undefined).
    if (!arg(args, 1).isUndefined()) try applyProperties(self, obj, arg(args, 1));
    return Value.obj(obj);
}

pub fn objectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (!isRealObject(target)) return self.throwError("TypeError", "Object.defineProperty called on non-object");
    try self.checkRestricted(target.asObj());
    const key = try self.keyOf(arg(args, 1));
    const desc = arg(args, 2);
    // ToPropertyDescriptor requires an Object — a BigInt or Symbol value (boxed
    // as an object internally) is a primitive and must be rejected.
    if (!isRealObject(desc)) return self.throwError("TypeError", "Property description must be an object");
    try defineOne(self, target.asObj(), key, desc.asObj());
    return target;
}

pub fn reflectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (!isRealObject(target)) return self.throwError("TypeError", "Reflect.defineProperty called on non-object");
    const key = try self.keyOf(arg(args, 1));
    const desc = arg(args, 2);
    if (!isRealObject(desc)) return self.throwError("TypeError", "Property description must be an object");
    return Value.boolVal(try defineOneResult(self, target.asObj(), key, desc.asObj()));
}

/// Core of `Object.defineProperty` / `defineProperties`: apply descriptor `d` to
/// `target[key]`, honoring attributes and bypassing [[Set]].
/// Read a property-descriptor field per ToPropertyDescriptor: present iff
/// HasProperty (own *or inherited*), value via Get (so an inherited or accessor
/// descriptor field is honored). Returns null when absent.
fn descField(self: *Interpreter, d: *value.Object, name: []const u8) HostError!?Value {
    if (!try self.hasPropertyResult(d, name)) return null;
    return try self.getProperty(Value.obj(d), name);
}

pub fn defineOne(self: *Interpreter, target: *value.Object, key: []const u8, d_obj: *value.Object) HostError!void {
    if (!try defineOneResult(self, target, key, d_obj))
        return self.throwError("TypeError", "Cannot define property");
}

pub fn defineOneResult(self: *Interpreter, target: *value.Object, key: []const u8, d_obj: *value.Object) HostError!bool {
    // Materialize the descriptor once over the prototype chain (a field may be
    // inherited or itself an accessor), into a plain own-property record the
    // rest of this function reads via `getOwn`.
    const d = (try self.newObject()).asObj();
    for ([_][]const u8{ "enumerable", "configurable", "value", "writable", "get", "set" }) |f| {
        if (try descField(self, d_obj, f)) |v| {
            const field_value = if (std.mem.eql(u8, f, "enumerable") or
                std.mem.eql(u8, f, "configurable") or
                std.mem.eql(u8, f, "writable"))
                Value.boolVal(v.toBoolean())
            else
                v;
            try d.setOwn(self.arena, self.root_shape, f, field_value);
        }
    }
    const get = d.getOwn("get");
    const set = d.getOwn("set");
    // ToPropertyDescriptor validation: a descriptor may not mix accessor fields
    // (get/set) with data fields (value/writable), and a present get/set must be
    // callable or undefined.
    if ((get != null or set != null) and (d.getOwn("value") != null or d.getOwn("writable") != null))
        return self.throwError("TypeError", "Invalid property descriptor: cannot both specify accessors and a value or writable attribute");
    if (get) |g| {
        if (!g.isUndefined() and !(g.isObject() and g.asObj().isCallableObject()))
            return self.throwError("TypeError", "Getter must be a function");
    }
    if (set) |s| {
        if (!s.isUndefined() and !(s.isObject() and s.asObj().isCallableObject()))
            return self.throwError("TypeError", "Setter must be a function");
    }
    if (interpreter.isModuleNs(target)) {
        try interpreter.triggerDeferForKey(self, target, key); // `import defer`: a string [[DefineOwnProperty]] evaluates first
        return moduleNamespaceDefine(self, target, key, d);
    }
    // [[DefineOwnProperty]] on a Proxy: invoke the `defineProperty` trap with a
    // FromPropertyDescriptor object; a falsy result is a TypeError. An absent
    // trap forwards to the target.
    if (target.proxyHandler() != null or target.proxy_revoked) {
        if (target.proxy_revoked) return self.throwError("TypeError", "Cannot perform 'defineProperty' on a revoked proxy");
        const handler = target.proxyHandler().?;
        const tgt = target.proxyTarget() orelse return self.throwError("TypeError", "Cannot perform 'defineProperty' on a revoked proxy");
        const trap = try self.getProperty(Value.obj(handler), "defineProperty");
        if (trap.isUndefined() or trap.isNull()) return defineOneResult(self, tgt, key, d);
        if (!trap.isCallable()) return self.throwError("TypeError", "proxy 'defineProperty' trap is not callable");
        const trap_desc = try descriptorObjectForProxyTrap(self, d);
        const res = try self.callValueWithThis(trap, &.{ Value.obj(tgt), try self.keyToValue(key), trap_desc }, Value.obj(handler));
        if (!res.toBoolean()) return false;
        // [[DefineOwnProperty]] invariants (9.5.6) for an ordinary target.
        if (tgt.proxyHandler() == null and !tgt.proxy_revoked) {
            const setting_nonconfig = if (d.getOwn("configurable")) |c| !c.toBoolean() else false;
            const has_own = tgt.getOwn(key) != null or tgt.getAccessor(key) != null;
            if (!has_own) {
                if (!tgt.isExtensible()) return self.throwError("TypeError", "proxy 'defineProperty' cannot add a property to a non-extensible target");
                if (setting_nonconfig) return self.throwError("TypeError", "proxy 'defineProperty' cannot define a non-configurable property absent from the target");
            } else {
                // Reporting a property as non-configurable that the target still
                // exposes as configurable is a lie.
                if (setting_nonconfig and tgt.getAttr(key).configurable)
                    return self.throwError("TypeError", "proxy 'defineProperty' cannot report a configurable target property as non-configurable");
                if (!tgt.getAttr(key).configurable and tgt.getAttr(key).writable) {
                    if (d.getOwn("writable")) |w| {
                        if (!w.toBoolean())
                            return self.throwError("TypeError", "proxy 'defineProperty' cannot report a non-configurable writable property as non-writable");
                    }
                }
                // A non-configurable target property only admits a compatible
                // redefinition (IsCompatiblePropertyDescriptor).
                if (!tgt.getAttr(key).configurable and !try compatibleRedefine(tgt.getAttr(key), tgt.getOwn(key), tgt.getAccessor(key), d))
                    return self.throwError("TypeError", "proxy 'defineProperty' cannot report an incompatible non-configurable redefinition");
            }
        }
        return true;
    }
    // Integer-Indexed Exotic [[DefineOwnProperty]]: a canonical numeric key may
    // only be (re)defined as a configurable, enumerable, writable data property
    // at a valid index; anything else returns false (and Object.defineProperty
    // then throws). The value, if present, is written through [[Set]].
    if (target.typedArray()) |ta| {
        if (interpreter.canonicalNumericIndexString(key)) |n| {
            if (!interpreter.isValidIntegerIndex(ta, n)) return false;
            if (get != null or set != null) return false;
            if (d.getOwn("configurable")) |c| if (!c.toBoolean()) return false;
            if (d.getOwn("enumerable")) |e| if (!e.toBoolean()) return false;
            if (d.getOwn("writable")) |w| if (!w.toBoolean()) return false;
            if (d.getOwn("value")) |val|
                _ = try self.setMemberResult(Value.obj(target), key, val, Value.obj(target));
            return true;
        }
    }
    if (target.boxedPrimitive()) |p| {
        if (p.isString()) {
            if (std.mem.eql(u8, key, "length")) {
                const attr: value.PropAttr = .{ .writable = false, .enumerable = false, .configurable = false };
                return compatibleRedefine(attr, Value.num(@floatFromInt(p.asStr().len)), null, d);
            }
            if (arrayIndexOf(key)) |i| {
                if (i < p.asStr().len) {
                    const attr: value.PropAttr = .{ .writable = false, .enumerable = true, .configurable = false };
                    const ch: Value = try Value.strOwned(self.arena, try self.arena.dupe(u8, p.asStr()[i .. i + 1]));
                    return compatibleRedefine(attr, ch, null, d);
                }
            }
        }
    }
    // Array `length` is a data property { writable, !enumerable, !configurable }.
    // Redefining it can change the value (ToUint32, truncating/extending) and
    // toggle writability, but not make it configurable/enumerable or an accessor.
    // An arguments object is `is_array` only for index storage; its `length` is
    // an ORDINARY data property, so it falls through to the generic define path.
    if (target.is_array and !target.is_arguments and std.mem.eql(u8, key, "length")) {
        if (get != null or set != null) return false;
        // ArraySetLength (ES 10.4.2.4): ToUint32(value) is validated FIRST — a
        // value whose ToUint32 differs from its ToNumber is a RangeError, *before*
        // the (non-configurable / non-enumerable) attribute-compatibility checks.
        var new_len_opt: ?u32 = null;
        if (d.getOwn("value")) |val| {
            new_len_opt = try self.arrayLengthFromValue(val);
        }
        const cur_writable = if (target.attrsMap() != null) target.getAttr("length").writable else true;
        const old_len = target.arrayLength();
        if (d.getOwn("configurable")) |c| {
            if (c.toBoolean()) return false;
        }
        if (d.getOwn("enumerable")) |e| {
            if (e.toBoolean()) return false;
        }
        if (!cur_writable) {
            if (d.getOwn("writable")) |w| {
                if (w.toBoolean()) return false;
            }
        }
        // ArraySetLength: reducing `length` deletes elements from the top down; a
        // non-configurable element blocks the deletion — `length` stops just above
        // it and the redefinition fails. `length`/writability are still applied.
        var ok = true;
        if (new_len_opt) |u| {
            if (!cur_writable and u != old_len) return false;
            ok = try self.setArrayLength(target, u);
        }
        var lattr: value.PropAttr = .{ .writable = cur_writable, .enumerable = false, .configurable = false };
        if (d.getOwn("writable")) |w| lattr.writable = w.toBoolean();
        try target.setAttr(self.arena, "length", lattr);
        return ok;
    }
    // Array index with a data descriptor: keep the value in the dense element
    // store and record its attributes in the string-keyed `attrs` map (so
    // reads/writes/getOwnPropertyDescriptor agree), rather than splitting it
    // into the named-property store. Accessor descriptors on an index, huge or
    // gappy indices, and `length` fall through to the generic path below.
    if (target.is_array and get == null and set == null and !std.mem.eql(u8, key, "length") and target.getAccessor(key) == null) {
        if (arrayIndexOf(key)) |i| {
            if (i <= target.elementsLen() + 1024 and i < (1 << 24)) {
                const old_len = target.arrayLength();
                if (i >= old_len and target.attrsMap() != null and !target.getAttr("length").writable) return false;
                // A hole within bounds is NOT an existing property — treat it as a
                // new definition (so attributes default correctly and the hole is
                // materialized below), not a redefinition of a present element.
                const within = target.denseElementPresent(i);
                const cur_attr = target.getAttr(key);
                if (within and !cur_attr.configurable) {
                    const cur_value = target.denseElement(i) orelse Value.undef();
                    if (!try compatibleRedefine(cur_attr, cur_value, null, d)) return false;
                } else if (!within and !target.isExtensible()) {
                    return false;
                }
                const am_mapped = target.is_arguments and interpreter.argMapName(target, i) != null;
                const new_value = if (d.getOwn("value")) |val|
                    val
                else if (am_mapped)
                    // No explicit value: snapshot the binding so an unmap below
                    // leaves the current value frozen in the element.
                    interpreter.argMapGet(target, i) orelse Value.undef()
                else if (within)
                    target.denseElement(i) orelse Value.undef()
                else
                    Value.undef();
                // Defining the index makes it a present own element (clearing any
                // hole) and materializes gaps under `elements_lock`.
                if (!try target.setOrGrowDenseElement(self.arena, i, new_value, 1 << 24)) return false;
                if (d.getOwn("value")) |val| {
                    // A mapped index also writes its parameter binding.
                    if (am_mapped) interpreter.argMapSet(target, i, val);
                }
                // Omitted fields keep the current value when redefining an
                // existing element (implicitly all-true), else default to false.
                var attr: value.PropAttr = if (within) cur_attr else .{ .writable = false, .enumerable = false, .configurable = false };
                if (d.getOwn("writable")) |w| attr.writable = w.toBoolean();
                if (d.getOwn("enumerable")) |e| attr.enumerable = e.toBoolean();
                if (d.getOwn("configurable")) |c| attr.configurable = c.toBoolean();
                try target.setAttr(self.arena, key, attr);
                target.has_indexed_property.store(true, .monotonic);
                // Redefining a mapped index as non-writable severs the parameter link.
                if (am_mapped and !attr.writable) interpreter.argMapSever(target, i);
                try target.extendArrayLengthFloor(self.arena, i + 1);
                return true;
            }
        }
    }
    if (std.mem.eql(u8, key, "prototype") and Interpreter.jsFunctionHasOwnPrototypeSlot(target) and target.getOwn("prototype") == null and target.getAccessor("prototype") == null)
        _ = try self.getProperty(Value.obj(target), key);
    // A dense array element lives in the element store (not `slots`/`accessors`),
    // so [[GetOwnProperty]] must surface it here too: redefining one — reaching
    // this generic path only for an accessor descriptor — is a redefinition of an
    // existing data property whose implicit attributes are all true, not the
    // creation of a brand-new (all-false) property.
    // Element-store reads go through the locked accessors so a peer thread's
    // `growDenseElement` cannot race this generic descriptor path.
    var dense_elem_index: ?usize = null;
    if (target.getAccessor(key) == null) {
        if (arrayIndexOf(key)) |i| {
            if (target.denseElementPresent(i)) dense_elem_index = i;
        }
    }
    if (target.is_array and !std.mem.eql(u8, key, "length")) {
        if (arrayIndexOf(key)) |i| {
            const old_len = target.arrayLength();
            if (i >= old_len and target.attrsMap() != null and !target.getAttr("length").writable) return false;
        }
    }
    const cur_data = target.getOwn(key) orelse (if (dense_elem_index) |i| target.denseElement(i) else null);
    const cur_acc = target.getAccessor(key);
    const exists = cur_data != null or cur_acc != null;
    // ValidateAndApplyPropertyDescriptor: reject (TypeError) any change that the
    // current state forbids — adding to a non-extensible object, or altering a
    // non-configurable property in an incompatible way.
    if (!exists) {
        if (!target.isExtensible()) return false;
    } else if (!target.getAttr(key).configurable) {
        if (!try compatibleRedefine(target.getAttr(key), cur_data, cur_acc, d)) return false;
    }
    // Redefining keeps the current attributes for any omitted field; a new
    // property defaults omitted fields to false.
    var attr: value.PropAttr = if (exists) target.getAttr(key) else .{ .writable = false, .enumerable = false, .configurable = false };
    if (d.getOwn("enumerable")) |e| attr.enumerable = e.toBoolean();
    if (d.getOwn("configurable")) |c| attr.configurable = c.toBoolean();
    const has_data_field = d.getOwn("value") != null or d.getOwn("writable") != null;
    if (get != null or set != null) {
        // (Partial) accessor definition: an omitted get/set keeps the existing
        // accessor's corresponding half (a redefine like `{get: g}` must not wipe
        // the setter); converting from a data property drops the old value.
        var new_get = get;
        var new_set = set;
        if (cur_acc) |a| {
            if (new_get == null) new_get = a.get;
            if (new_set == null) new_set = a.set;
        }
        // A converted-from-data key keeps its slot in the data shape (shadowed by
        // the accessor, which getProperty consults first) so own-key creation
        // order is preserved — accessors live in a separate, append-ordered map.
        try target.setAccessor(self.arena, key, new_get, new_set);
        // A dense array element converted to an accessor must vacate the element
        // store (now an accessor index) so it isn't double-counted in own keys.
        if (dense_elem_index) |i| try target.markHole(self.arena, i);
    } else if (has_data_field or cur_acc == null) {
        // A data property: either explicit data fields, or a generic descriptor on
        // a non-accessor (brand-new / existing data property).
        if (cur_acc != null) _ = try self.deleteOwn(target, key);
        if (d.getOwn("writable")) |w| {
            attr.writable = w.toBoolean();
        } else if (cur_acc != null) {
            attr.writable = false;
        }
        // An omitted `value` keeps the existing data property's value on a
        // redefine (a partial descriptor like `{enumerable:false}` must not reset
        // it); a brand-new property defaults to undefined.
        const new_value = d.getOwn("value") orelse (cur_data orelse Value.undef());
        try target.setOwn(self.arena, self.root_shape, key, new_value);
    }
    // else: a generic descriptor on an existing accessor keeps the accessor as-is;
    // only enumerable/configurable (in `attr`) change.
    try target.setAttr(self.arena, key, attr);
    // Defining an own property at an array index at or past the current length
    // extends the array's length (so iteration sees it).
    if (target.is_array) {
        if (arrayIndexOf(key)) |i| {
            // Only a valid array index (ToUint32(P) === P and < 2^32 - 1) updates
            // `length`; 2^32 - 1 and above are ordinary properties.
            if (i < 4294967295 and i + 1 > target.arrayLength()) try target.extendArrayLengthFloor(self.arena, i + 1);
            // Defining a mapped arguments index as an accessor severs its link.
            if (target.is_arguments and (get != null or set != null)) interpreter.argMapSever(target, i);
        }
    }
    return true;
}

fn descriptorObjectForProxyTrap(self: *Interpreter, d: *value.Object) HostError!Value {
    const out = try self.newObject();
    if (d.getOwn("get") != null or d.getOwn("set") != null) {
        if (d.getOwn("get")) |v| try self.setMember(out, "get", v);
        if (d.getOwn("set")) |v| try self.setMember(out, "set", v);
    } else {
        if (d.getOwn("value")) |v| try self.setMember(out, "value", v);
        if (d.getOwn("writable")) |v| try self.setMember(out, "writable", v);
    }
    if (d.getOwn("enumerable")) |v| try self.setMember(out, "enumerable", v);
    if (d.getOwn("configurable")) |v| try self.setMember(out, "configurable", v);
    return out;
}

fn moduleNamespaceDefine(self: *Interpreter, target: *value.Object, key: []const u8, d: *value.Object) HostError!bool {
    const current = try interpreter.moduleNsDesc(self, target, key);
    if (!current.isObject()) return false;
    if (d.getOwn("get") != null or d.getOwn("set") != null) return false;
    const cur = current.asObj();
    if (d.getOwn("configurable")) |v|
        if (v.toBoolean() != descBool(cur, "configurable", false)) return false;
    if (d.getOwn("enumerable")) |v|
        if (v.toBoolean() != descBool(cur, "enumerable", false)) return false;
    if (d.getOwn("writable")) |v|
        if (v.toBoolean() != descBool(cur, "writable", false)) return false;
    if (d.getOwn("value")) |v|
        if (!sameValue(v, cur.getOwn("value") orelse Value.undef())) return false;
    return true;
}

fn descBool(o: *value.Object, name: []const u8, default: bool) bool {
    if (o.getOwn(name)) |v| return v.toBoolean();
    return default;
}

/// The rejection half of ValidateAndApplyPropertyDescriptor for an existing
/// *non-configurable* property. Returns false if descriptor `d` tries to flip
/// configurable on, change enumerable, switch between data/accessor, or — for a
/// non-writable data property — change writability or value. A generic
/// descriptor (no value/writable/get/set) only constrains config/enumerable.
fn compatibleRedefine(
    cur_attr: value.PropAttr,
    cur_data: ?Value,
    cur_acc: ?value.Accessor,
    d: *value.Object,
) HostError!bool {
    if (d.getOwn("configurable")) |c| {
        if (c.toBoolean()) return false;
    }
    if (d.getOwn("enumerable")) |e| {
        if (e.toBoolean() != cur_attr.enumerable) return false;
    }
    const d_get = d.getOwn("get");
    const d_set = d.getOwn("set");
    const d_is_accessor = d_get != null or d_set != null;
    const d_is_data = d.getOwn("value") != null or d.getOwn("writable") != null;
    if (!d_is_accessor and !d_is_data) return true; // generic descriptor: nothing more to check

    const cur_is_accessor = cur_acc != null;
    if (d_is_accessor != cur_is_accessor) return false;

    if (cur_is_accessor) {
        const acc = cur_acc.?;
        if (d_get) |g| {
            if (!sameValue(g, acc.get orelse Value.undef())) return false;
        }
        if (d_set) |s| {
            if (!sameValue(s, acc.set orelse Value.undef())) return false;
        }
    } else if (!cur_attr.writable) {
        if (d.getOwn("writable")) |w| {
            if (w.toBoolean()) return false;
        }
        if (d.getOwn("value")) |v| {
            if (!sameValue(v, cur_data orelse Value.undef())) return false;
        }
    }
    return true;
}

pub fn objectDefineProperties(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (!target.isObject()) return self.throwError("TypeError", "Object.defineProperties called on non-object");
    try applyProperties(self, target.asObj(), arg(args, 1));
    return target;
}

/// Apply each enumerable own property of `props` to `target` as a descriptor —
/// the shared core of `Object.defineProperties` and `Object.create`'s second
/// argument. Each value must itself be an object (a property descriptor).
fn applyProperties(self: *Interpreter, target: *value.Object, props: Value) HostError!void {
    if (props.isNull() or props.isUndefined())
        return self.throwError("TypeError", "Cannot convert undefined or null to object");
    const props_obj = try self.toObject(props);
    // Snapshot the enumerable own keys, then read each descriptor object via
    // [[Get]] (so an accessor-valued descriptor property runs its getter), per
    // ObjectDefineProperties — not the raw data slot.
    for (try self.objectOwnKeysList(props_obj)) |k| {
        const prop_desc = try objectGetOwnPropertyDescriptor(self, Value.undef(), &.{ Value.obj(props_obj), try self.keyToValue(k) });
        if (!prop_desc.isObject() or !completedDescAttr(prop_desc.asObj()).enumerable) continue;
        const d = try self.getProperty(Value.obj(props_obj), k);
        if (!isRealObject(d)) return self.throwError("TypeError", "Property description must be an object");
        try defineOne(self, target, k, d.asObj());
    }
}

/// IsTypedArrayFixedLength: false for a length-tracking view, or a view over a
/// NON-shared resizable ArrayBuffer (its length can change). A view over a fixed
/// buffer — or a growable SHARED buffer, which can only grow — is fixed-length.
/// A TypedArray's [[PreventExtensions]] returns false (→ Object.preventExtensions/
/// seal/freeze throw, Reflect.preventExtensions returns false) when this is false.
pub fn isTypedArrayFixedLength(o: *value.Object) bool {
    const ta = o.typedArray() orelse return true;
    if (ta.track_length) return false;
    const ab = ta.buffer.arrayBuffer() orelse return true;
    if (ab.max_byte_length != null and !ab.is_shared) return false;
    return true;
}

pub fn objectPreventExtensions(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (args.len > 0 and isRealObject(args[0])) try self.checkRestricted(args[0].asObj());
    const o = arg(args, 0);
    if (isRealObject(o)) {
        if (o.asObj().proxyHandler() != null or o.asObj().proxy_revoked) {
            if (!try self.proxyPreventExt(o.asObj()))
                return self.throwError("TypeError", "Cannot prevent extensions on proxy target");
        } else if (!isTypedArrayFixedLength(o.asObj())) {
            return self.throwError("TypeError", "Cannot prevent extensions on a length-variable TypedArray");
        } else o.asObj().setExtensible(false);
    }
    return o;
}

pub fn objectIsExtensible(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (args.len > 0 and isRealObject(args[0])) try self.checkRestricted(args[0].asObj());
    const o = arg(args, 0);
    if (!isRealObject(o)) return Value.boolVal(false);
    if (o.asObj().proxyHandler() != null or o.asObj().proxy_revoked) return Value.boolVal(try self.proxyIsExtensible(o.asObj()));
    return Value.boolVal(o.asObj().isExtensible());
}

pub fn objectSeal(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    _ = this;
    const o = arg(args, 0);
    if (isRealObject(o)) try setIntegrityLevel(ctx, self, o.asObj(), false);
    return o;
}

pub fn objectFreeze(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    _ = this;
    const o = arg(args, 0);
    if (isRealObject(o)) try setIntegrityLevel(ctx, self, o.asObj(), true);
    return o;
}

/// SetIntegrityLevel(O, sealed|frozen): a Proxy runs the spec algorithm through
/// its internal methods (so a `preventExtensions`/`defineProperty` trap that
/// returns false — or throws — surfaces a TypeError, and the trap's reported
/// keys drive the loop). An ordinary object uses the direct attribute path.
fn setIntegrityLevel(ctx: *anyopaque, self: *Interpreter, o: *value.Object, freeze: bool) HostError!void {
    // SetIntegrityLevel on a TypedArray throws unless the view is a FIXED-LENGTH
    // EMPTY one: [[PreventExtensions]] fails for a length-variable view (length-
    // tracking, or over a non-shared resizable buffer; a growable SHARED buffer's
    // view stays fixed-length), and a non-empty view can't have its integer-indexed
    // elements redefined non-configurable, so the per-property step throws.
    if (o.typedArray()) |ta| {
        if (!isTypedArrayFixedLength(o))
            return self.throwError("TypeError", "Cannot seal or freeze a TypedArray with elements");
        if ((ta.currentLength() orelse 0) > 0) {
            o.setExtensible(false);
            return self.throwError("TypeError", "Cannot seal or freeze a TypedArray with elements");
        }
    }
    if (o.proxyHandler() != null or o.proxy_revoked or interpreter.isModuleNs(o)) {
        if (o.proxyHandler() != null or o.proxy_revoked) {
            if (!try self.proxyPreventExt(o))
                return self.throwError("TypeError", "Object.seal/freeze: [[PreventExtensions]] returned false");
        } else {
            o.setExtensible(false);
        }
        for (try self.objectOwnKeysList(o)) |k| {
            const cur = try objectGetOwnPropertyDescriptor(ctx, Value.undef(), &.{ Value.obj(o), try self.keyToValue(k) });
            if (!cur.isObject()) continue; // [[GetOwnProperty]] returned undefined
            const is_accessor = cur.asObj().getOwn("get") != null or cur.asObj().getOwn("set") != null;
            const d = (try self.newObject()).asObj();
            try self.setProp(d, "configurable", Value.boolVal(false));
            // A frozen *data* property is also made non-writable; an accessor only
            // gets {configurable:false} (writable is invalid on an accessor).
            if (freeze and !is_accessor) try self.setProp(d, "writable", Value.boolVal(false));
            if (!try defineOneResult(self, o, k, d))
                return self.throwError("TypeError", "Object.seal/freeze: could not redefine property");
        }
        return;
    }
    o.setExtensible(false);
    try lockKeys(self, o, freeze);
}

/// Make every own property non-configurable (and, when `freeze`, every data
/// property non-writable). Backs `seal`/`freeze`.
fn lockKeys(self: *Interpreter, o: *value.Object, freeze: bool) HostError!void {
    for (try o.ownKeys(self.arena)) |k| {
        if (value.isPrivateKey(k)) continue;
        var a = o.getAttr(k);
        a.configurable = false;
        if (freeze) a.writable = false;
        try o.setAttr(self.arena, k, a);
    }
    // Accessor keys via a locked snapshot, not the live `accessors` map: a peer
    // freezing/sealing the same shared object under `parallel_js` may grow that
    // `StringHashMap` mid-iteration (the "grow vs lookup" panic). See
    // `Object.accessorKeysSnapshot`.
    for (try o.accessorKeysSnapshot(self.arena)) |k| {
        if (value.isPrivateKey(k)) continue;
        var a = o.getAttr(k);
        a.configurable = false;
        try o.setAttr(self.arena, k, a);
    }
    // Dense element indices live in `elements` (not the shape), so they aren't
    // in `ownKeys` — lock each present one, plus Array `length` below.
    var i: usize = 0;
    while (i < o.elementsLen()) : (i += 1) {
        if (!o.denseElementPresent(i)) continue;
        var kb: [24]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
        var a = o.getAttr(k);
        a.configurable = false;
        if (freeze) a.writable = false;
        try o.setAttr(self.arena, k, a);
    }
    if (o.is_array) {
        var la = o.getAttr("length");
        if (freeze) la.writable = false;
        la.configurable = false;
        try o.setAttr(self.arena, "length", la);
    }
}

pub fn objectIsSealed(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.boolVal(try isLocked(interp(ctx), arg(args, 0), false));
}

pub fn objectIsFrozen(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return Value.boolVal(try isLocked(interp(ctx), arg(args, 0), true));
}

/// A non-object is trivially sealed/frozen. Otherwise: non-extensible, every own
/// property non-configurable (and, for `frozen`, every data property
/// non-writable). Arrays with elements can't be frozen (no per-index attrs yet).
fn isLocked(self: *Interpreter, ov: Value, frozen: bool) HostError!bool {
    if (!isRealObject(ov)) return true;
    const o = ov.asObj();
    if (o.proxyHandler() != null or o.proxy_revoked or interpreter.isModuleNs(o)) {
        if (o.proxyHandler() != null or o.proxy_revoked) {
            if (try self.proxyIsExtensible(o)) return false;
        } else if (o.isExtensible()) return false;
        const ov_obj: Value = Value.obj(o);
        for (try self.objectOwnKeysList(o)) |k| {
            const desc = try objectGetOwnPropertyDescriptor(self, Value.undef(), &.{ ov_obj, try self.keyToValue(k) });
            if (!desc.isObject()) continue;
            const configurable = try self.getProperty(desc, "configurable");
            if (configurable.toBoolean()) return false;
            if (frozen) {
                const writable = try self.getProperty(desc, "writable");
                if (writable.toBoolean()) return false;
            }
        }
        return true;
    }
    if (o.isExtensible()) return false;
    if (o.typedArray()) |ta| {
        if ((ta.currentLength() orelse 0) > 0) return false;
    }
    // Dense element indices must each be non-configurable (and, for frozen,
    // non-writable). A frozen array additionally needs non-writable `length`.
    // Holes carry no property, so they don't block.
    var i: usize = 0;
    while (i < o.elementsLen()) : (i += 1) {
        if (!o.denseElementPresent(i)) continue;
        var kb: [24]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
        const a = o.getAttr(k);
        if (a.configurable) return false;
        if (frozen and a.writable) return false;
    }
    if (o.is_array) {
        if (frozen and o.getAttr("length").writable) return false;
    }
    var s = o.shape;
    while (s) |sh| {
        if (sh.name) |n| {
            if (value.isPrivateKey(n)) {
                s = sh.parent;
                continue;
            }
            const a = o.getAttr(n);
            if (a.configurable) return false;
            if (frozen and a.writable) return false;
        }
        s = sh.parent;
    }
    // Locked snapshot, not live iteration: a concurrent `setAccessor` on a shared
    // object under `parallel_js` may grow this map mid-walk. See
    // `Object.accessorKeysSnapshot`.
    for (try o.accessorKeysSnapshot(self.arena)) |k| {
        if (value.isPrivateKey(k)) continue;
        if (o.getAttr(k).configurable) return false;
    }
    return true;
}

pub fn objectIs(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return Value.boolVal(sameValue(arg(args, 0), arg(args, 1)));
}

/// SameValue: like `===` but NaN equals NaN and +0 differs from -0.
fn sameValue(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNum();
        const y = b.asNum();
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        if (x == 0 and y == 0) return (1.0 / x) == (1.0 / y); // +0 vs -0
        return x == y;
    }
    return value.strictEquals(a, b);
}

pub fn objectSetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const saved_env = enterActiveNativeRealm(self);
    defer if (saved_env) |env| {
        self.env = env;
    };
    const o = arg(args, 0);
    // RequireObjectCoercible; the new prototype must be an Object or null.
    if (o.isNull() or o.isUndefined())
        return self.throwError("TypeError", "Object.setPrototypeOf called on null or undefined");
    const p = arg(args, 1);
    if (!p.isNull() and !isRealObject(p))
        return self.throwError("TypeError", "Object prototype may only be an Object or null");
    if (!o.isObject()) return o; // a primitive `this` has no own [[Prototype]] to set
    const new_proto: ?*value.Object = if (p.isObject()) p.asObj() else null;
    if (!try self.setPrototypeOfObject(o.asObj(), new_proto))
        return self.throwError("TypeError", "Cannot set object prototype");
    return o;
}

pub fn objectGetOwnPropertySymbols(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    const o = try self.toObject(arg(args, 0));
    // [[OwnPropertyKeys]] (proxy-aware: the ownKeys trap + its invariants run
    // here and may throw), then keep only the symbol keys.
    for (try self.objectOwnKeysList(o)) |k| {
        if (value.isRealSymbolKey(k))
            try result.asObj().appendElement(self.arena, try self.keyToValue(k));
    }
    return result;
}

pub fn objectGetOwnPropertyDescriptors(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newObject();
    // ToObject(arg): null/undefined throw; a primitive boxes to a wrapper.
    const o = try self.toObject(arg(args, 0));
    const ov: Value = Value.obj(o);
    // [[OwnPropertyKeys]] order (array indices / String chars / "length" aware).
    for (try self.objectOwnKeysList(o)) |k| {
        if (value.isPrivateKey(k)) continue; // private slots aren't reflected
        const d = try objectGetOwnPropertyDescriptor(ctx, Value.undef(), &.{ ov, try self.keyToValue(k) });
        if (d.isUndefined()) continue; // CreateDataPropertyOrThrow only for present descs
        try self.setMember(result, k, d);
    }
    return result;
}

/// CompletePropertyDescriptor ∘ FromPropertyDescriptor over a (possibly partial)
/// descriptor object — fills omitted fields with their defaults and returns a
/// fresh, fully-populated data or accessor descriptor object.
fn completeDescriptor(self: *Interpreter, desc_obj: *value.Object) HostError!Value {
    const enumerable = try descField(self, desc_obj, "enumerable");
    const configurable = try descField(self, desc_obj, "configurable");
    const valuef = try descField(self, desc_obj, "value");
    const writable = try descField(self, desc_obj, "writable");
    const getf = try descField(self, desc_obj, "get");
    const setf = try descField(self, desc_obj, "set");
    const is_accessor = getf != null or setf != null;
    const is_data = valuef != null or writable != null;
    if (is_accessor and is_data)
        return self.throwError("TypeError", "Invalid property descriptor: cannot both specify accessors and a value or writable attribute");
    if (getf) |g| {
        if (!g.isUndefined() and !(g.isObject() and g.asObj().isCallableObject()))
            return self.throwError("TypeError", "Getter must be a function");
    }
    if (setf) |s| {
        if (!s.isUndefined() and !(s.isObject() and s.asObj().isCallableObject()))
            return self.throwError("TypeError", "Setter must be a function");
    }
    const out = (try self.newObject()).asObj();
    if (is_accessor) {
        try self.setMember(Value.obj(out), "get", getf orelse Value.undef());
        try self.setMember(Value.obj(out), "set", setf orelse Value.undef());
    } else {
        try self.setMember(Value.obj(out), "value", valuef orelse Value.undef());
        try self.setMember(Value.obj(out), "writable", Value.boolVal(if (writable) |w| w.toBoolean() else false));
    }
    try self.setMember(Value.obj(out), "enumerable", Value.boolVal(if (enumerable) |e| e.toBoolean() else false));
    try self.setMember(Value.obj(out), "configurable", Value.boolVal(if (configurable) |c| c.toBoolean() else false));
    return Value.obj(out);
}

fn completedDescAttr(d: *value.Object) value.PropAttr {
    return .{
        .writable = if (d.getOwn("writable")) |w| w.toBoolean() else false,
        .enumerable = if (d.getOwn("enumerable")) |e| e.toBoolean() else false,
        .configurable = if (d.getOwn("configurable")) |c| c.toBoolean() else false,
    };
}

fn completedDescAccessor(d: *value.Object) ?value.Accessor {
    if (d.getOwn("get") == null and d.getOwn("set") == null) return null;
    return .{ .get = d.getOwn("get"), .set = d.getOwn("set") };
}

fn proxyTargetExtensible(self: *Interpreter, target: *value.Object) HostError!bool {
    if (target.proxyHandler() != null or target.proxy_revoked) return self.proxyIsExtensible(target);
    if (interpreter.isModuleNs(target)) return false;
    return target.isExtensible();
}

pub fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const ov = arg(args, 0);
    // ES2015+: ToObject(O) — null/undefined throw; a primitive boxes to its
    // wrapper (so `Object.getOwnPropertyDescriptor("ab", 0)` sees the chars).
    const o = if (ov.isObject()) ov.asObj() else try self.toObject(ov);
    const key = try self.keyOf(arg(args, 1));
    // Private members are internal slots — invisible to reflection.
    if (value.isPrivateKey(key)) return Value.undef();
    if (interpreter.isModuleNs(o)) {
        try interpreter.triggerDeferForKey(self, o, key); // `import defer`: a string [[GetOwnProperty]] evaluates first
        return interpreter.moduleNsDesc(self, o, key);
    }

    // [[GetOwnProperty]] on a Proxy: the trap returns a descriptor object or
    // undefined; the result is normalized (CompletePropertyDescriptor). An
    // absent trap forwards to the target.
    if (o.proxyHandler() != null or o.proxy_revoked) {
        if (o.proxy_revoked) return self.throwError("TypeError", "Cannot perform 'getOwnPropertyDescriptor' on a revoked proxy");
        const handler = o.proxyHandler().?;
        const tgt = o.proxyTarget() orelse return self.throwError("TypeError", "Cannot perform 'getOwnPropertyDescriptor' on a revoked proxy");
        const trap = try self.getProperty(Value.obj(handler), "getOwnPropertyDescriptor");
        if (trap.isUndefined() or trap.isNull())
            return objectGetOwnPropertyDescriptor(ctx, Value.undef(), &.{ Value.obj(tgt), arg(args, 1) });
        if (!trap.isCallable()) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' trap is not callable");
        const res = try self.callValueWithThis(trap, &.{ Value.obj(tgt), try self.keyToValue(key) }, Value.obj(handler));
        if (!res.isUndefined() and !isRealObject(res)) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' trap must return an object or undefined");
        const target_desc = try objectGetOwnPropertyDescriptor(ctx, Value.undef(), &.{ Value.obj(tgt), try self.keyToValue(key) });
        const target_extensible = try proxyTargetExtensible(self, tgt);
        if (res.isUndefined()) {
            if (target_desc.isObject()) {
                const target_attr = completedDescAttr(target_desc.asObj());
                if (!target_attr.configurable) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a non-configurable property as absent");
                if (!target_extensible) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a property of a non-extensible target as absent");
            }
            return Value.undef();
        }
        const completed = try completeDescriptor(self, res.asObj());
        const result_desc = completed.asObj();
        const result_attr = completedDescAttr(result_desc);
        if (!target_desc.isObject()) {
            if (!target_extensible) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a new property on a non-extensible target");
            if (!result_attr.configurable) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a new non-configurable property");
        } else {
            const target_obj = target_desc.asObj();
            const target_attr = completedDescAttr(target_obj);
            const target_acc = completedDescAccessor(target_obj);
            const target_data = target_obj.getOwn("value");
            if (!target_attr.configurable and !try compatibleRedefine(target_attr, target_data, target_acc, result_desc))
                return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' reported an incompatible descriptor");
            if (!result_attr.configurable) {
                if (target_attr.configurable) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a configurable target property as non-configurable");
                if (result_desc.getOwn("writable")) |w| {
                    if (!w.toBoolean() and target_attr.writable)
                        return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a non-configurable writable target property as non-writable");
                }
            }
        }
        return completed;
    }

    // Integer-Indexed Exotic [[GetOwnProperty]]: a valid index is a configurable,
    // enumerable, writable data property; any other canonical numeric key is absent.
    if (o.typedArray()) |ta| {
        if (interpreter.canonicalNumericIndexString(key)) |n| {
            if (!interpreter.isValidIntegerIndex(ta, n)) return Value.undef();
            const el = try self.getProperty(ov, key);
            return dataDescriptor(self, el, .{ .writable = true, .enumerable = true, .configurable = true });
        }
    }
    if (std.mem.eql(u8, key, "prototype") and o.jsFunction() != null and o.getOwn("prototype") == null and o.getAccessor("prototype") == null)
        _ = try self.getProperty(ov, key);
    if (o.boxedPrimitive()) |p| {
        if (p.isString()) {
            if (std.mem.eql(u8, key, "length"))
                return dataDescriptor(self, Value.num(@floatFromInt(p.asStr().len)), .{ .writable = false, .enumerable = false, .configurable = false });
            if (arrayIndexOf(key)) |i| {
                if (i < p.asStr().len)
                    return dataDescriptor(self, try Value.strOwned(self.arena, try self.arena.dupe(u8, p.asStr()[i .. i + 1])), .{ .writable = false, .enumerable = true, .configurable = false });
            }
        }
    }
    if (o.getAccessor(key)) |acc| {
        const a = o.getAttr(key);
        const desc = try self.newObject();
        try self.setMember(desc, "get", acc.get orelse Value.undef());
        try self.setMember(desc, "set", acc.set orelse Value.undef());
        try self.setMember(desc, "enumerable", Value.boolVal(a.enumerable));
        try self.setMember(desc, "configurable", Value.boolVal(a.configurable));
        return desc;
    }
    if (o.getOwn(key)) |v| {
        const a = o.getAttr(key);
        return dataDescriptor(self, v, a);
    }
    if (!o.is_array) {
        if (arrayIndexOf(key)) |i| {
            if (o.denseElement(i)) |el|
                return dataDescriptor(self, el, o.getAttr(key));
        }
    }
    if (o.is_array) {
        // A real Array's exotic `length`. An arguments object's `length` is an
        // ordinary own property handled by the getOwn path above (so a deleted
        // one is absent), so exclude it here.
        if (!o.is_arguments and std.mem.eql(u8, key, "length")) {
            const w = if (o.attrsMap() != null) o.getAttr("length").writable else true;
            return dataDescriptor(self, Value.num(@floatFromInt(o.arrayLength())), .{ .writable = w, .enumerable = false, .configurable = false });
        }
        if (arrayIndexOf(key)) |i| {
            // A mapped arguments index reports its current parameter binding value.
            if (interpreter.argMapGet(o, i)) |bv|
                return dataDescriptor(self, bv, o.getAttr(key));
            // Per-index attributes recorded by `defineProperty` override the
            // all-true default for a dense element.
            if (o.denseElement(i)) |el|
                return dataDescriptor(self, el, o.getAttr(key));
        }
    }
    return Value.undef();
}

fn dataDescriptor(self: *Interpreter, v: Value, a: value.PropAttr) HostError!Value {
    const desc = try self.newObject();
    try self.setMember(desc, "value", v);
    try self.setMember(desc, "writable", Value.boolVal(a.writable));
    try self.setMember(desc, "enumerable", Value.boolVal(a.enumerable));
    try self.setMember(desc, "configurable", Value.boolVal(a.configurable));
    return desc;
}

/// Parse a canonical array index (no leading zeros, < 2^32-1) from a key.
fn arrayIndexOf(key: []const u8) ?usize {
    if (key.len == 0) return null;
    if (key.len > 1 and key[0] == '0') return null;
    var n: usize = 0;
    for (key) |c| {
        if (c < '0' or c > '9') return null;
        const d = c - '0';
        if (n > 429496729 or (n == 429496729 and d > 4)) return null;
        n = n * 10 + d;
    }
    return n;
}

pub fn objectGetOwnPropertyNames(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (args.len > 0 and args[0].isObject()) try self.checkRestricted(args[0].asObj());
    const result = try self.newArray();
    // ToObject(arg): null/undefined throw; a primitive boxes (a String exposes
    // its character indices + "length").
    const o = try self.toObject(arg(args, 0));
    // [[OwnPropertyKeys]] (proxy-aware, array-index/length-aware), string
    // keys only (symbols go to getOwnPropertySymbols).
    for (try self.objectOwnKeysList(o)) |k| {
        if (value.isSymbolKey(k) or value.isPrivateKey(k)) continue;
        try result.asObj().appendElement(self.arena, try Value.strAlloc(self.arena, k));
    }
    return result;
}

// ---- Number statics ----------------------------------------------------

pub fn numberIsInteger(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.boolVal(false);
    const n = v.asNum();
    return Value.boolVal(!std.math.isNan(n) and !std.math.isInf(n) and @trunc(n) == n);
}

pub fn numberIsSafeInteger(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.boolVal(false);
    const n = v.asNum();
    return Value.boolVal(!std.math.isNan(n) and !std.math.isInf(n) and @trunc(n) == n and @abs(n) <= 9007199254740991);
}

pub fn numberIsNaN(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    return Value.boolVal(v.isNumber() and std.math.isNan(v.asNum()));
}

pub fn numberIsFinite(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    return Value.boolVal(v.isNumber() and !std.math.isNan(v.asNum()) and !std.math.isInf(v.asNum()));
}

pub fn stringFromCharCode(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (args) |c| {
        const n = try self.toNumberV(c);
        const code: u16 = if (std.math.isNan(n) or std.math.isInf(n)) 0 else @intFromFloat(@mod(@trunc(n), 65536));
        try appendCodePointWtf8(self.arena, &buf, @intCast(code));
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}

/// Append code point `cp` (already validated to be ≤ 0x10FFFF) to `buf`. A lone
/// surrogate, which `std.unicode.utf8Encode` rejects, is emitted in the generic
/// 3-byte form (WTF-8) so `String.fromCodePoint(0xD800)` succeeds.
fn appendCodePointWtf8(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) std.mem.Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    if (std.unicode.utf8Encode(cp, &tmp)) |n| {
        try buf.appendSlice(arena, tmp[0..n]);
    } else |_| {
        try buf.append(arena, @intCast(0xE0 | (cp >> 12)));
        try buf.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(arena, @intCast(0x80 | (cp & 0x3F)));
    }
}

/// `String.fromCodePoint(...cps)` — like fromCharCode but validates that each
/// argument is an integer code point in [0, 0x10FFFF] (else RangeError). In
/// this byte-string engine a code point is emitted as its UTF-8 encoding.
pub fn stringFromCodePoint(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.ensureTotalCapacity(self.arena, args.len * 4);
    for (args) |c| {
        // ToNumber(arg) runs valueOf/@@toPrimitive (and throws for a Symbol/BigInt)
        // BEFORE the integer-code-point range check.
        const n = try self.toNumberV(c);
        if (std.math.isNan(n) or @trunc(n) != n or n < 0 or n > 0x10FFFF)
            return self.throwError("RangeError", "Invalid code point");
        const cp: u21 = @intFromFloat(n);
        // A lone surrogate (0xD800–0xDFFF) is a valid fromCodePoint argument even
        // though it is not a valid UTF-8 scalar; encode it as WTF-8 (the generic
        // 3-byte form) rather than rejecting it the way std.unicode does.
        try appendCodePointWtf8(self.arena, &buf, cp);
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}

/// `String.raw(template, ...subs)` — reassemble a template literal from its
/// `raw` strings interleaved with the substitutions (ToString'd). Generic over
/// any array-like with a `raw` whose `length` and indices it reads via [[Get]].
pub fn stringRaw(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const cooked = arg(args, 0);
    if (cooked.isNull() or cooked.isUndefined())
        return self.throwError("TypeError", "Cannot convert undefined or null to object");
    const raw = try self.getProperty(cooked, "raw");
    if (raw.isNull() or raw.isUndefined())
        return self.throwError("TypeError", "Cannot convert undefined or null to object");
    // ToLength(Get(raw,"length")) — ToNumber throws for a Symbol/BigInt length.
    const segs = interpreter.toLen(try self.toNumberV(try self.getProperty(raw, "length")));
    if (segs == 0) return Value.str("");
    const subs: []const Value = if (args.len > 1) args[1..] else &.{};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
        // ToString of each cooked segment and substitution runs valueOf/toString
        // (and throws for a Symbol), propagating any abrupt completion.
        try buf.appendSlice(self.arena, try self.toStringV(try self.getProperty(raw, key)));
        if (i + 1 == segs) break;
        if (i < subs.len) try buf.appendSlice(self.arena, try self.toStringV(subs[i]));
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}

// ---- JSON --------------------------------------------------------------

pub fn jsonStringify(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const saved_env = enterActiveNativeRealm(self);
    defer if (saved_env) |env| {
        self.env = env;
    };
    const a = self.arena;
    var st = Stringifier{ .self = self };

    // arg 1 — replacer: a callable (transform) or an array (property allowlist).
    const replacer = arg(args, 1);
    if (replacer.isObject()) {
        if (replacer.asObj().isCallableObject()) {
            st.replacer_fn = replacer;
        } else if (try interpreter.objectToStringIsArray(self, replacer.asObj())) {
            // PropertyList: read via LengthOfArrayLike + Get(replacer, ToString(i))
            // so a Proxy/array-like replacer's traps run (and abrupts propagate).
            var allow: std.ArrayListUnmanaged([]const u8) = .empty;
            const rlen = interpreter.toLen(try self.toNumberV(try self.getProperty(replacer, "length")));
            var idx: usize = 0;
            while (idx < rlen) : (idx += 1) {
                const ikey = try std.fmt.allocPrint(a, "{d}", .{idx});
                const item = try self.getProperty(replacer, ikey);
                // Items are property keys: strings as-is, numbers ToString'd,
                // String/Number wrappers unwrapped; anything else is ignored.
                var k: ?[]const u8 = null;
                switch (item.kind()) {
                    .string => k = item.asStr(),
                    .number => k = try value.numberToString(a, item.asNum()),
                    // A String/Number wrapper is ToString'd (invoking its own
                    // toString, e.g. an overridden one), not unwrapped raw.
                    .object => if (item.asObj().boxedPrimitive()) |p| switch (p.kind()) {
                        .string, .number => k = try self.toStringV(item),
                        else => {},
                    },
                    else => {},
                }
                if (k) |key| {
                    var dup = false;
                    for (allow.items) |e| if (std.mem.eql(u8, e, key)) {
                        dup = true;
                        break;
                    };
                    if (!dup) try allow.append(a, key);
                }
            }
            st.allow = allow.items;
        }
    }

    // arg 2 — space: up to 10 spaces (number) or the first 10 chars (string);
    // a Number wrapper is ToNumber'd and a String wrapper ToString'd (running
    // any overridden valueOf/toString), not unwrapped raw.
    var space = arg(args, 2);
    if (space.isObject()) if (space.asObj().boxedPrimitive()) |p| {
        // Compute into a temp first (result-location aliasing — see serialize).
        switch (p.kind()) {
            .number => {
                const n = try self.toNumberV(space);
                space = Value.num(n);
            },
            .string => {
                const s = try self.toStringV(space);
                space = try Value.strAlloc(self.arena, s);
            },
            else => space = p,
        }
    };
    switch (space.kind()) {
        .number => {
            const n = space.asNum();
            const cnt: usize = if (std.math.isNan(n) or n < 1) 0 else @intFromFloat(@min(@trunc(n), 10));
            const sp = try a.alloc(u8, cnt);
            @memset(sp, ' ');
            st.gap = sp;
        },
        .string => st.gap = space.asStr()[0..@min(space.asStr().len, 10)],
        else => {},
    }

    // Wrap the value in a holder { "": value } so toJSON/replacer apply to it.
    const holder = (try self.newObject()).asObj();
    try holder.setOwn(self.arena, self.root_shape, "", arg(args, 0));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (!try st.serialize(&buf, Value.obj(holder), "")) return Value.undef();
    return try Value.strOwned(a, try buf.toOwnedSlice(a));
}

/// Carries the `JSON.stringify` options (replacer / allowlist / indent gap)
/// and the cycle-detection stack across the recursive serialization.
const Stringifier = struct {
    self: *Interpreter,
    replacer_fn: ?Value = null,
    allow: ?[]const []const u8 = null,
    gap: []const u8 = "",
    indent: std.ArrayListUnmanaged(u8) = .empty,
    stack: std.ArrayListUnmanaged(*value.Object) = .empty,

    /// SerializeJSONProperty: write `holder[key]` (after toJSON + replacer +
    /// wrapper unwrapping) into `buf`. Returns false when the value is omitted.
    fn serialize(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8), holder: Value, key: []const u8) HostError!bool {
        const self = st.self;
        // Count each nested serialize toward the call-depth limit so a replacer
        // that fabricates ever-deeper values (`(k,v)=>[v]`) — non-circular, so the
        // cycle check never fires — throws a catchable RangeError instead of
        // overflowing the native stack.
        self.depth += 1;
        defer self.depth -= 1;
        try self.stackGuard();
        const a = self.arena;
        var v = try self.getProperty(holder, key);
        if (v.isObject() and !v.asObj().is_symbol) {
            const tj = try self.getProperty(v, "toJSON");
            if (tj.isObject() and tj.asObj().isCallableObject())
                v = try self.callValueWithThis(tj, &.{try Value.strAlloc(self.arena, key)}, v);
        }
        if (st.replacer_fn) |rf|
            v = try self.callValueWithThis(rf, &.{ try Value.strAlloc(self.arena, key), v }, holder);
        // A JSON.rawJSON object emits its validated text verbatim.
        if (v.isObject() and v.asObj().behavior.is_raw_json) {
            const raw = (v.asObj().getOwn("rawJSON") orelse Value.str("")).asStr();
            try buf.appendSlice(a, raw);
            return true;
        }
        // SerializeJSONProperty: a [[NumberData]] wrapper → ToNumber, a
        // [[StringData]] wrapper → ToString (both run overridden valueOf/toString),
        // a [[BooleanData]] wrapper → its boolean.
        if (v.isObject()) if (v.asObj().boxedPrimitive()) |p| {
            // Compute into a temp first: `v = Value.num(toNumberV(v))` would
            // clobber v's tag before toNumberV reads it (result-location aliasing).
            switch (p.kind()) {
                .number => {
                    const n = try self.toNumberV(v);
                    v = Value.num(n);
                },
                .string => {
                    const s = try self.toStringV(v);
                    v = try Value.strAlloc(self.arena, s);
                },
                else => v = p,
            }
        };
        // A BigInt (primitive or [[BigIntData]] wrapper) is not serializable.
        if (v.isObject() and v.asObj().is_bigint)
            return self.throwError("TypeError", "Do not know how to serialize a BigInt");
        switch (v.kind()) {
            .undefined => return false,
            .null => try buf.appendSlice(a, "null"),
            .boolean => try buf.appendSlice(a, if (v.asBool()) "true" else "false"),
            .number => {
                const n = v.asNum();
                try buf.appendSlice(a, if (std.math.isNan(n) or std.math.isInf(n)) "null" else try value.numberToString(a, n));
            },
            .string => try writeJsonString(a, buf, v.asStr()),
            .object => {
                const o = v.asObj();
                if (o.isCallableObject() or o.is_symbol) return false; // functions/symbols omitted
                for (st.stack.items) |s| if (s == o)
                    return self.throwError("TypeError", "Converting circular structure to JSON");
                try st.stack.append(a, o);
                defer _ = st.stack.pop();
                const shape = try st.jsonShape(o);
                if (shape.is_array) try st.serializeArray(buf, Value.obj(o), shape) else try st.serializeObject(buf, Value.obj(o), shape);
            },
        }
        return true;
    }

    fn jsonShape(st: *Stringifier, o: *value.Object) HostError!*value.Object {
        var shape = o;
        var guard: u32 = 0;
        while (shape.proxyHandler() != null or shape.proxy_revoked) {
            guard += 1;
            if (guard > 10000) return st.self.throwError("RangeError", "Maximum call stack size exceeded");
            shape = shape.proxyTarget() orelse return st.self.throwError("TypeError", "Cannot stringify a revoked proxy");
        }
        return shape;
    }

    fn serializeArray(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8), holder: Value, shape: *value.Object) HostError!void {
        const a = st.self.arena;
        // SerializeJSONArray reads the length via LengthOfArrayLike (Get) — for a
        // Proxy that runs the "length" trap (and propagates an abrupt completion).
        const len: usize = if (holder.isObject() and (holder.asObj().proxyHandler() != null or holder.asObj().proxy_revoked))
            interpreter.toLen(try st.self.toNumberV(try st.self.getProperty(holder, "length")))
        else
            shape.arrayLength();
        if (len == 0) {
            try buf.appendSlice(a, "[]");
            return;
        }
        const outer = st.indent.items.len;
        try st.indent.appendSlice(a, st.gap);
        try buf.append(a, '[');
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (i != 0) try buf.append(a, ',');
            try st.newlineIndent(buf);
            const key = try std.fmt.allocPrint(a, "{d}", .{i});
            if (!try st.serialize(buf, holder, key)) try buf.appendSlice(a, "null");
        }
        st.indent.shrinkRetainingCapacity(outer);
        try st.newlineIndent(buf);
        try buf.append(a, ']');
    }

    fn serializeObject(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8), v: Value, shape: *value.Object) HostError!void {
        const self = st.self;
        const a = self.arena;
        const keys = if (st.allow) |al| al else try st.jsonObjectKeys(v.asObj(), shape);
        // A Proxy's enumerability comes from [[GetOwnProperty]] (the
        // getOwnPropertyDescriptor trap), which EnumerableOwnPropertyNames runs
        // per key — the raw shape can't answer it, and a throwing or
        // absent-descriptor trap must be observed (not silently serialized).
        const is_proxy = v.asObj().proxyHandler() != null or v.asObj().proxy_revoked;
        const outer = st.indent.items.len;
        try st.indent.appendSlice(a, st.gap);
        var tmp: std.ArrayListUnmanaged(u8) = .empty;
        var count: usize = 0;
        for (keys) |k| {
            if (jsonHiddenKey(k)) continue;
            if (st.allow == null) {
                const enumerable = if (is_proxy) blk: {
                    const desc = try objectGetOwnPropertyDescriptor(self, Value.undef(), &.{ v, try self.keyToValue(k) });
                    break :blk desc.isObject() and (try self.getProperty(desc, "enumerable")).toBoolean();
                } else shape.getAttr(k).enumerable;
                if (!enumerable) continue;
            }
            var member: std.ArrayListUnmanaged(u8) = .empty;
            if (!try st.serialize(&member, v, k)) continue; // omitted property
            if (count != 0) try tmp.append(a, ',');
            try st.newlineIndentTo(&tmp, st.indent.items);
            try writeJsonString(a, &tmp, k);
            try tmp.append(a, ':');
            if (st.gap.len != 0) try tmp.append(a, ' ');
            try tmp.appendSlice(a, member.items);
            count += 1;
        }
        st.indent.shrinkRetainingCapacity(outer);
        if (count == 0) {
            try buf.appendSlice(a, "{}");
            return;
        }
        try buf.append(a, '{');
        try buf.appendSlice(a, tmp.items);
        try st.newlineIndent(buf);
        try buf.append(a, '}');
    }

    fn jsonObjectKeys(st: *Stringifier, object: *value.Object, shape: *value.Object) HostError![]const []const u8 {
        _ = shape;
        // Full [[OwnPropertyKeys]] order, which includes integer-indexed dense
        // elements. Those live in `elements`, outside the shape, so `shape.ownKeys`
        // would drop a key set via `o[0]=…` on an ordinary object — making
        // `JSON.stringify({...; o[0]="a"})` wrongly emit `{}`. SerializeJSONObject
        // enumerates every own *string* key; symbols/private are filtered by
        // `jsonHiddenKey` in the caller, non-enumerables by the live attr check.
        return st.self.objectOwnKeysList(object);
    }

    /// Emit a newline + the current indent when pretty-printing (no-op for the
    /// compact form).
    fn newlineIndent(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8)) HostError!void {
        try st.newlineIndentTo(buf, st.indent.items);
    }
    fn newlineIndentTo(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8), ind: []const u8) HostError!void {
        if (st.gap.len == 0) return;
        try buf.append(st.self.arena, '\n');
        try buf.appendSlice(st.self.arena, ind);
    }
};

fn jsonHiddenKey(k: []const u8) bool {
    if (value.isPrivateKey(k)) return true;
    if (value.isRealSymbolKey(k)) return true;
    return k.len > 1 and k[0] == 0 and std.ascii.isAlphabetic(k[1]);
}

fn wtf8SurrogateAt(s: []const u8, i: usize) ?u21 {
    if (i + 2 >= s.len or s[i] != 0xED) return null;
    if (s[i + 1] < 0xA0 or s[i + 1] > 0xBF) return null;
    if ((s[i + 2] & 0xC0) != 0x80) return null;
    return (@as(u21, s[i] & 0x0F) << 12) | (@as(u21, s[i + 1] & 0x3F) << 6) | @as(u21, s[i + 2] & 0x3F);
}

fn appendJsonHex4(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) HostError!void {
    const digits = "0123456789abcdef";
    try buf.appendSlice(a, "\\u");
    try buf.append(a, digits[(cp >> 12) & 0x0f]);
    try buf.append(a, digits[(cp >> 8) & 0x0f]);
    try buf.append(a, digits[(cp >> 4) & 0x0f]);
    try buf.append(a, digits[cp & 0x0f]);
}

fn appendUtf8Codepoint(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) HostError!void {
    if (cp <= 0x7F) {
        try buf.append(a, @intCast(cp));
    } else if (cp <= 0x7FF) {
        try buf.append(a, @intCast(0xC0 | (cp >> 6)));
        try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp <= 0xFFFF) {
        try buf.append(a, @intCast(0xE0 | (cp >> 12)));
        try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try buf.append(a, @intCast(0xF0 | (cp >> 18)));
        try buf.append(a, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try buf.append(a, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try buf.append(a, @intCast(0x80 | (cp & 0x3F)));
    }
}

fn writeJsonString(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) HostError!void {
    try buf.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        if (wtf8SurrogateAt(s, i)) |sur| {
            try appendJsonHex4(a, buf, sur);
            i += 3;
            continue;
        }
        const c = s[i];
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\t' => try buf.appendSlice(a, "\\t"),
            '\r' => try buf.appendSlice(a, "\\r"),
            8 => try buf.appendSlice(a, "\\b"),
            12 => try buf.appendSlice(a, "\\f"),
            // Other control characters are emitted as \u00XX escapes.
            0...7, 11, 14...31 => try buf.print(a, "\\u{x:0>4}", .{c}),
            else => try buf.append(a, c),
        }
        i += 1;
    }
    try buf.append(a, '"');
}

/// `JSON.rawJSON(text)`: validate `text` as a single JSON primitive and wrap it
/// in a frozen, null-prototype `[[IsRawJSON]]` object emitted verbatim later.
pub fn jsonRawJSON(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const saved_env = enterActiveNativeRealm(self);
    defer if (saved_env) |env| {
        self.env = env;
    };
    const s = try self.toStringV(arg(args, 0));
    const isJsonWs = struct {
        fn f(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }
    }.f;
    if (s.len == 0 or isJsonWs(s[0]) or isJsonWs(s[s.len - 1]))
        return self.throwError("SyntaxError", "JSON.rawJSON text must be non-empty and not start or end with whitespace");
    var p = JsonParser{ .s = s, .i = 0, .interp = self };
    p.skipWs();
    const parsed = p.parseValue() catch return self.throwError("SyntaxError", "JSON.rawJSON: invalid JSON");
    const v = parsed.value;
    p.skipWs();
    if (p.i != s.len) return self.throwError("SyntaxError", "JSON.rawJSON: trailing characters");
    // The outermost value must be a primitive (not an object or array).
    if (v.isObject() and !v.asObj().is_bigint and !v.asObj().is_symbol)
        return self.throwError("SyntaxError", "JSON.rawJSON text must be a primitive JSON value");
    const o = try gc_mod.allocObj(self.arena);
    o.* = .{ .proto = null, .behavior = .{ .is_raw_json = true } };
    try o.setOwn(self.arena, self.root_shape, "rawJSON", try Value.strAlloc(self.arena, s));
    try o.setAttr(self.arena, "rawJSON", .{ .writable = false, .enumerable = true, .configurable = false });
    o.setExtensible(false); // SetIntegrityLevel(frozen)
    return Value.obj(o);
}

/// `JSON.isRawJSON(O)`: true iff `O` is a `JSON.rawJSON` result.
pub fn jsonIsRawJSON(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    return Value.boolVal(v.isObject() and v.asObj().behavior.is_raw_json);
}

pub fn jsonParse(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const saved_env = enterActiveNativeRealm(self);
    defer if (saved_env) |env| {
        self.env = env;
    };
    // ToString(text) — a value object's @@toPrimitive/toString/valueOf runs (and
    // a Symbol throws) before parsing.
    const text = try self.toStringV(arg(args, 0));
    var p = JsonParser{ .s = text, .i = 0, .interp = self };
    p.skipWs();
    const parsed = p.parseValue() catch return self.throwError("SyntaxError", "JSON.parse: invalid JSON");
    const v = parsed.value;
    p.skipWs();
    if (p.i != text.len) return self.throwError("SyntaxError", "JSON.parse: trailing characters");

    // Optional reviver: walk the result bottom-up, replacing (or deleting, when
    // the reviver returns undefined) each property by the reviver's return.
    const reviver = arg(args, 1);
    if (reviver.isObject() and reviver.asObj().isCallableObject()) {
        const holder = (try self.newObject()).asObj();
        // CreateDataPropertyOrThrow(holder, "", v) — not [[Set]], so an inherited
        // Object.prototype[""] setter is not invoked.
        try holder.setOwn(self.arena, self.root_shape, "", v);
        if (parsed.source) |src| try p.sources.append(self.arena, .{ .holder = holder, .key = "", .value = v, .source = src });
        return internalizeJson(self, Value.obj(holder), "", reviver, p.sources.items);
    }
    return v;
}

/// InternalizeJSONProperty: recursively apply `reviver` to `holder[key]` and its
/// nested elements/properties (children first), returning the reviver's result.
fn internalizeJson(self: *Interpreter, holder: Value, key: []const u8, reviver: Value, sources: []const JsonSourceEntry) HostError!Value {
    const a = self.arena;
    const val = try self.getProperty(holder, key);
    if (val.isObject() and !val.asObj().isCallableObject()) {
        const o = val.asObj();
        if (try interpreter.objectToStringIsArray(self, o)) {
            var i: usize = 0;
            // LengthOfArrayLike: Get(val, "length") — observable, and propagates a
            // throw if the reviver replaced `length` with a throwing accessor.
            const len = interpreter.toLen(try self.toNumberV(try self.getProperty(val, "length")));
            while (i < len) : (i += 1) {
                const k = try std.fmt.allocPrint(a, "{d}", .{i});
                const nv = try internalizeJson(self, val, k, reviver, sources);
                try internalizeStore(self, o, val, k, nv);
            }
        } else {
            for (try ownEnumerableKeys(self, o)) |k| {
                const nv = try internalizeJson(self, val, k, reviver, sources);
                try internalizeStore(self, o, val, k, nv);
            }
        }
    }
    const context = try jsonReviverContext(self, holder, key, val, sources);
    return self.callValueWithThis(reviver, &.{ try Value.strAlloc(self.arena, key), val, context }, holder);
}

fn jsonReviverContext(self: *Interpreter, holder: Value, key: []const u8, val: Value, sources: []const JsonSourceEntry) HostError!Value {
    const ctx = (try self.newObject()).asObj();
    if (holder.isObject()) {
        var i = sources.len;
        while (i > 0) {
            i -= 1;
            const entry = sources[i];
            if (entry.holder == holder.asObj() and std.mem.eql(u8, entry.key, key) and value.strictEquals(entry.value, val)) {
                try ctx.setOwn(self.arena, self.root_shape, "source", try Value.strAlloc(self.arena, entry.source));
                break;
            }
        }
    }
    return Value.obj(ctx);
}

/// InternalizeJSONProperty's store step: `undefined` ⇒ DeletePropertyOrThrow,
/// else CreateDataProperty. On a Proxy these route through the deleteProperty /
/// defineProperty traps (so a throwing trap propagates); a plain object takes
/// the fast `setMember` path.
fn internalizeStore(self: *Interpreter, o: *value.Object, val: Value, key: []const u8, nv: Value) HostError!void {
    _ = val;
    // InternalizeJSONProperty: a removed value is [[Delete]]'d, otherwise the
    // result is CreateDataProperty'd. Both use the plain internal method whose
    // boolean result is IGNORED (a non-configurable property is left as-is, no
    // TypeError) — only an abrupt completion from a Proxy trap propagates.
    if (nv.isUndefined()) {
        _ = try self.deleteOwn(o, key); // routes to the proxy deleteProperty trap
        return;
    }
    // CreateDataProperty(o, key, nv) — a full {value,w,e,c}=true data descriptor.
    const desc = (try self.newObject()).asObj();
    try desc.setOwn(self.arena, self.root_shape, "value", nv);
    try desc.setOwn(self.arena, self.root_shape, "writable", Value.boolVal(true));
    try desc.setOwn(self.arena, self.root_shape, "enumerable", Value.boolVal(true));
    try desc.setOwn(self.arena, self.root_shape, "configurable", Value.boolVal(true));
    _ = try defineOneResult(self, o, key, desc);
}

/// Explicit error set so the mutually-recursive parser methods don't form an
/// inferred-error-set dependency loop.
const JErr = error{Invalid} || HostError;

const JsonParsed = struct {
    value: Value,
    source: ?[]const u8 = null,
};

const JsonSourceEntry = struct {
    holder: *value.Object,
    key: []const u8,
    value: Value,
    source: []const u8,
};

const JsonParser = struct {
    s: []const u8,
    i: usize,
    interp: *Interpreter,
    sources: std.ArrayListUnmanaged(JsonSourceEntry) = .empty,

    fn skipWs(p: *JsonParser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    fn parseValue(p: *JsonParser) JErr!JsonParsed {
        p.skipWs();
        if (p.i >= p.s.len) return error.Invalid;
        const c = p.s[p.i];
        switch (c) {
            '{' => return p.parseObject(),
            '[' => return p.parseArray(),
            '"' => {
                const start = p.i;
                const s = try p.parseString();
                return .{ .value = try Value.strAlloc(p.interp.arena, s), .source = p.s[start..p.i] };
            },
            't' => return p.parseLiteral("true", Value.boolVal(true)),
            'f' => return p.parseLiteral("false", Value.boolVal(false)),
            'n' => return p.parseLiteral("null", Value.nul()),
            else => return p.parseNumber(),
        }
    }

    fn parseLiteral(p: *JsonParser, lit: []const u8, v: Value) JErr!JsonParsed {
        const start = p.i;
        if (p.i + lit.len > p.s.len or !std.mem.eql(u8, p.s[p.i .. p.i + lit.len], lit)) return error.Invalid;
        p.i += lit.len;
        return .{ .value = v, .source = p.s[start..p.i] };
    }

    fn parseNumber(p: *JsonParser) JErr!JsonParsed {
        const start = p.i;
        const digit = std.ascii.isDigit;
        if (p.i < p.s.len and p.s[p.i] == '-') p.i += 1; // optional minus (no leading '+')
        // Integer part: a lone '0', or [1-9] followed by digits (no leading zeros).
        if (p.i >= p.s.len) return error.Invalid;
        if (p.s[p.i] == '0') {
            p.i += 1;
        } else if (p.s[p.i] >= '1' and p.s[p.i] <= '9') {
            while (p.i < p.s.len and digit(p.s[p.i])) p.i += 1;
        } else return error.Invalid;
        // Fraction: a '.' must be followed by at least one digit.
        if (p.i < p.s.len and p.s[p.i] == '.') {
            p.i += 1;
            if (p.i >= p.s.len or !digit(p.s[p.i])) return error.Invalid;
            while (p.i < p.s.len and digit(p.s[p.i])) p.i += 1;
        }
        // Exponent: e/E, optional sign, at least one digit.
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E')) {
            p.i += 1;
            if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) p.i += 1;
            if (p.i >= p.s.len or !digit(p.s[p.i])) return error.Invalid;
            while (p.i < p.s.len and digit(p.s[p.i])) p.i += 1;
        }
        const n = std.fmt.parseFloat(f64, p.s[start..p.i]) catch return error.Invalid;
        return .{ .value = Value.num(n), .source = p.s[start..p.i] };
    }

    fn parseString(p: *JsonParser) JErr![]const u8 {
        p.i += 1; // opening quote
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const a = p.interp.arena;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '"') {
                p.i += 1;
                return buf.toOwnedSlice(a);
            }
            if (c == '\\') {
                p.i += 1;
                if (p.i >= p.s.len) return error.Invalid;
                const e = p.s[p.i];
                try buf.append(a, switch (e) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    'b' => 8,
                    'f' => 12,
                    '/' => '/',
                    '"' => '"',
                    '\\' => '\\',
                    'u' => {
                        // \uXXXX — decode the UTF-16 code unit(s) and store (W)TF-8.
                        if (p.i + 4 >= p.s.len) return error.Invalid;
                        const code = std.fmt.parseInt(u16, p.s[p.i + 1 .. p.i + 5], 16) catch return error.Invalid;
                        p.i += 4;
                        // A high surrogate immediately followed by a low surrogate
                        // combines into an astral code point. Any UNPAIRED surrogate
                        // (lone high, lone low, or high followed by a non-low) is a
                        // valid lone UTF-16 code unit per JSON — emit it as WTF-8,
                        // NOT a SyntaxError (matches `JSON.parse('"\\uD834"')`).
                        if (code >= 0xD800 and code <= 0xDBFF and
                            p.i + 6 < p.s.len and p.s[p.i + 1] == '\\' and p.s[p.i + 2] == 'u')
                        {
                            const low = std.fmt.parseInt(u16, p.s[p.i + 3 .. p.i + 7], 16) catch return error.Invalid;
                            if (low >= 0xDC00 and low <= 0xDFFF) {
                                const cp: u21 = 0x10000 + ((@as(u21, code) - 0xD800) << 10) + (@as(u21, low) - 0xDC00);
                                try appendUtf8Codepoint(a, &buf, cp);
                                p.i += 6;
                            } else {
                                try appendUtf8Codepoint(a, &buf, code); // lone high surrogate
                            }
                        } else {
                            try appendUtf8Codepoint(a, &buf, code); // BMP char or lone surrogate
                        }
                        p.i += 1;
                        continue;
                    },
                    else => return error.Invalid, // unknown escape
                });
                p.i += 1;
            } else if (c < 0x20) {
                return error.Invalid; // raw control characters are not allowed in JSON strings
            } else {
                try buf.append(a, c);
                p.i += 1;
            }
        }
        return error.Invalid;
    }

    fn parseArray(p: *JsonParser) JErr!JsonParsed {
        p.i += 1; // [
        const result = try p.interp.newArray();
        p.skipWs();
        if (p.i < p.s.len and p.s[p.i] == ']') {
            p.i += 1;
            return .{ .value = result };
        }
        var index: usize = 0;
        while (true) {
            const child = try p.parseValue();
            try result.asObj().appendElement(p.interp.arena, child.value);
            if (child.source) |src| {
                const key = try std.fmt.allocPrint(p.interp.arena, "{d}", .{index});
                try p.sources.append(p.interp.arena, .{ .holder = result.asObj(), .key = key, .value = child.value, .source = src });
            }
            index += 1;
            p.skipWs();
            if (p.i >= p.s.len) return error.Invalid;
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == ']') {
                p.i += 1;
                return .{ .value = result };
            }
            return error.Invalid;
        }
    }

    fn parseObject(p: *JsonParser) JErr!JsonParsed {
        p.i += 1; // {
        const result = try p.interp.newObject();
        p.skipWs();
        if (p.i < p.s.len and p.s[p.i] == '}') {
            p.i += 1;
            return .{ .value = result };
        }
        while (true) {
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != '"') return error.Invalid;
            const key = try p.parseString();
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != ':') return error.Invalid;
            p.i += 1;
            const child = try p.parseValue();
            // CreateDataPropertyOrThrow: define an own data property (default
            // attrs). Not [[Set]] — so "__proto__" becomes a normal own property
            // and duplicate keys overwrite without invoking inherited setters.
            try result.asObj().setOwn(p.interp.arena, p.interp.root_shape, key, child.value);
            if (child.source) |src|
                try p.sources.append(p.interp.arena, .{ .holder = result.asObj(), .key = key, .value = child.value, .source = src });
            p.skipWs();
            if (p.i >= p.s.len) return error.Invalid;
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == '}') {
                p.i += 1;
                return .{ .value = result };
            }
            return error.Invalid;
        }
    }
};

// ===== URI handling (encodeURI / decodeURI / …) ======================

const uri_unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";
const uri_reserved = ";/?:@&=+$,#"; // uriReserved + '#'

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'A' + (v - 10);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isHighSurrogateCp(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDBFF;
}

fn isLowSurrogateCp(cp: u21) bool {
    return cp >= 0xDC00 and cp <= 0xDFFF;
}

fn appendUriEscapedByte(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), b: u8) std.mem.Allocator.Error!void {
    try buf.append(arena, '%');
    try buf.append(arena, hexDigit(b >> 4));
    try buf.append(arena, hexDigit(b & 0xF));
}

fn appendUriEscapedCodePoint(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) std.mem.Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
    for (tmp[0..n]) |b| try appendUriEscapedByte(arena, buf, b);
}

/// Encode (24.5.2.1): ToString, then percent-escape every byte not in the
/// `unescaped` set. `component` excludes the reserved set (encodeURIComponent).
fn uriEncode(self: *Interpreter, v: Value, comptime component: bool) HostError!Value {
    const s = try self.toStringV(v);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const keep = b < 0x80 and (std.mem.indexOfScalar(u8, uri_unreserved, b) != null or
            (!component and std.mem.indexOfScalar(u8, uri_reserved, b) != null));
        if (keep) {
            try buf.append(self.arena, b);
            i += 1;
        } else if (b >= 0x80) {
            if (wtf8SurrogateAt(s, i)) |lead| {
                if (!isHighSurrogateCp(lead)) return self.throwError("URIError", "URI malformed");
                const trail = wtf8SurrogateAt(s, i + 3) orelse return self.throwError("URIError", "URI malformed");
                if (!isLowSurrogateCp(trail)) return self.throwError("URIError", "URI malformed");
                const cp: u21 = 0x10000 + ((lead - 0xD800) << 10) + (trail - 0xDC00);
                try appendUriEscapedCodePoint(self.arena, &buf, cp);
                i += 6;
            } else {
                const n = std.unicode.utf8ByteSequenceLength(b) catch return self.throwError("URIError", "URI malformed");
                if (i + n > s.len) return self.throwError("URIError", "URI malformed");
                _ = std.unicode.utf8Decode(s[i .. i + n]) catch return self.throwError("URIError", "URI malformed");
                for (s[i .. i + n]) |bb| try appendUriEscapedByte(self.arena, &buf, bb);
                i += n;
            }
        } else {
            try appendUriEscapedByte(self.arena, &buf, b);
            i += 1;
        }
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}

/// Decode (24.5.2.2): ToString, then un-escape `%XX` runs. A single byte whose
/// decoded value is in the `reserved` set keeps its escape; multi-byte UTF-8
/// runs are decoded and validated. `full` (decodeURIComponent) has no reserved
/// set. A malformed escape/sequence is a URIError.
fn uriDecode(self: *Interpreter, v: Value, comptime full: bool) HostError!Value {
    const s = try self.toStringV(v);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            try buf.append(self.arena, s[i]);
            i += 1;
            continue;
        }
        if (i + 3 > s.len) return self.throwError("URIError", "URI malformed");
        const h = hexVal(s[i + 1]) orelse return self.throwError("URIError", "URI malformed");
        const l = hexVal(s[i + 2]) orelse return self.throwError("URIError", "URI malformed");
        const b0: u8 = h * 16 + l;
        if (b0 < 0x80) {
            if (!full and std.mem.indexOfScalar(u8, uri_reserved, b0) != null) {
                try buf.appendSlice(self.arena, s[i .. i + 3]); // keep the escape
            } else {
                try buf.append(self.arena, b0);
            }
            i += 3;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(b0) catch return self.throwError("URIError", "URI malformed");
            var bytes: [4]u8 = undefined;
            bytes[0] = b0;
            var k: usize = 1;
            var j: usize = i + 3;
            while (k < n) : (k += 1) {
                if (j + 3 > s.len or s[j] != '%') return self.throwError("URIError", "URI malformed");
                const hh = hexVal(s[j + 1]) orelse return self.throwError("URIError", "URI malformed");
                const ll = hexVal(s[j + 2]) orelse return self.throwError("URIError", "URI malformed");
                const bk: u8 = hh * 16 + ll;
                if (bk & 0xC0 != 0x80) return self.throwError("URIError", "URI malformed");
                bytes[k] = bk;
                j += 3;
            }
            const cp = std.unicode.utf8Decode(bytes[0..n]) catch return self.throwError("URIError", "URI malformed");
            if (cp > 0xFFFF) {
                const high: u21 = 0xD800 + ((cp - 0x10000) >> 10);
                const low: u21 = 0xDC00 + ((cp - 0x10000) & 0x3FF);
                try appendCodePointWtf8(self.arena, &buf, high);
                try appendCodePointWtf8(self.arena, &buf, low);
            } else {
                try buf.appendSlice(self.arena, bytes[0..n]);
            }
            i = j;
        }
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}

pub fn encodeURIFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return uriEncode(interp(ctx), arg(args, 0), false);
}
pub fn encodeURIComponentFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return uriEncode(interp(ctx), arg(args, 0), true);
}
pub fn decodeURIFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return uriDecode(interp(ctx), arg(args, 0), false);
}
pub fn decodeURIComponentFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return uriDecode(interp(ctx), arg(args, 0), true);
}

/// `escape` (Annex B B.2.1): legacy escape — `%XX` for a code unit < 256, else
/// `%uXXXX`; the unreserved set is `A–Za–z0–9@*_+-./`.
/// Escape a single UTF-16 code unit per Annex B `escape`: keep unreserved ASCII,
/// `%XX` for code units < 0x100, `%uXXXX` otherwise.
fn escapeCodeUnit(arena: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), keep: []const u8, cu: u16) !void {
    if (cu < 0x80 and std.mem.indexOfScalar(u8, keep, @intCast(cu)) != null) {
        try buf.append(arena, @intCast(cu));
    } else if (cu < 0x100) {
        try buf.append(arena, '%');
        try buf.append(arena, hexDigit(@intCast(cu >> 4)));
        try buf.append(arena, hexDigit(@intCast(cu & 0xF)));
    } else {
        try buf.appendSlice(arena, "%u");
        try buf.append(arena, hexDigit(@intCast((cu >> 12) & 0xF)));
        try buf.append(arena, hexDigit(@intCast((cu >> 8) & 0xF)));
        try buf.append(arena, hexDigit(@intCast((cu >> 4) & 0xF)));
        try buf.append(arena, hexDigit(@intCast(cu & 0xF)));
    }
}

pub fn escapeFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const s = try self.toStringV(arg(args, 0));
    const keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        // `escape` is defined over UTF-16 code units, not code points: an astral
        // scalar (>= U+10000) is two code units (a surrogate pair) and each is
        // escaped separately, e.g. U+1D306 -> "%uD834%uDF06".
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            const high: u16 = @intCast(0xD800 + (v >> 10));
            const low: u16 = @intCast(0xDC00 + (v & 0x3FF));
            escapeCodeUnit(self.arena, &buf, keep, high) catch return error.OutOfMemory;
            escapeCodeUnit(self.arena, &buf, keep, low) catch return error.OutOfMemory;
        } else {
            escapeCodeUnit(self.arena, &buf, keep, @intCast(cp)) catch return error.OutOfMemory;
        }
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}

/// `unescape` (Annex B B.2.2): reverse of `escape` — `%uXXXX` and `%XX`.
pub fn unescapeFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const s = try self.toStringV(arg(args, 0));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var cpbuf: [4]u8 = undefined;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 6 <= s.len and s[i + 1] == 'u' and
            hexVal(s[i + 2]) != null and hexVal(s[i + 3]) != null and
            hexVal(s[i + 4]) != null and hexVal(s[i + 5]) != null)
        {
            const cp: u21 = @as(u21, hexVal(s[i + 2]).?) << 12 | @as(u21, hexVal(s[i + 3]).?) << 8 |
                @as(u21, hexVal(s[i + 4]).?) << 4 | hexVal(s[i + 5]).?;
            const n = std.unicode.utf8Encode(cp, &cpbuf) catch 1;
            try buf.appendSlice(self.arena, cpbuf[0..n]);
            i += 6;
        } else if (s[i] == '%' and i + 3 <= s.len and hexVal(s[i + 1]) != null and hexVal(s[i + 2]) != null) {
            const cp: u21 = @as(u21, hexVal(s[i + 1]).?) * 16 + hexVal(s[i + 2]).?;
            const n = std.unicode.utf8Encode(cp, &cpbuf) catch 1;
            try buf.appendSlice(self.arena, cpbuf[0..n]);
            i += 3;
        } else {
            try buf.append(self.arena, s[i]);
            i += 1;
        }
    }
    return try Value.strOwned(self.arena, try buf.toOwnedSlice(self.arena));
}
