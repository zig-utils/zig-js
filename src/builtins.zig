//! Native (Zig) implementations of common JS global functions and the `Math`,
//! `Object`, and `Array` namespace methods. Each is a `value.NativeFn`: the
//! first argument is the `*Interpreter` (type-erased), so a builtin can allocate
//! via its arena and raise JS exceptions. Registered in `interpreter.installGlobals`.

const std = @import("std");
const value = @import("value.zig");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const Parser = @import("parser.zig").Parser;

const Value = value.Value;
const HostError = value.HostError;

fn interp(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

/// Whether `v` is an ECMAScript Object — `.object` that is not one of the
/// primitive values represented as objects internally (BigInt, Symbol).
/// True for a genuine Object — excluding the internally object-tagged primitives
/// (Symbol, BigInt). The Reflect.* methods and several Object.* methods require
/// an Object argument and must throw TypeError for a Symbol/BigInt.
pub fn isRealObject(v: Value) bool {
    return v == .object and !v.object.is_bigint and !v.object.is_symbol;
}

// ---- global functions --------------------------------------------------

pub fn isNaNFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    // Spec: `Let num be ? ToNumber(number)` — so a Symbol/BigInt argument and an
    // object whose toPrimitive throws propagate that throw, not silently NaN.
    const n = try interp(ctx).toNumberV(arg(args, 0));
    return .{ .boolean = std.math.isNan(n) };
}

pub fn isFiniteFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const n = try interp(ctx).toNumberV(arg(args, 0));
    return .{ .boolean = !std.math.isNan(n) and !std.math.isInf(n) };
}

pub fn stringFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    const s: []const u8 = blk: {
        if (args.len == 0) break :blk "";
        // String(symbol) (called, not constructed) → SymbolDescriptiveString; in
        // any other case ToString (toStringV, running @@toPrimitive/toString/
        // valueOf and throwing for a Symbol under `new String(sym)`).
        if (ip.new_target == .undefined and args[0] == .object and args[0].object.is_symbol)
            break :blk try std.fmt.allocPrint(ip.arena, "Symbol({s})", .{args[0].object.sym_desc orelse ""});
        break :blk try ip.toStringV(args[0]);
    };
    if (ip.new_target != .undefined) return ip.makeWrapper(.{ .string = s });
    return .{ .string = s };
}

pub fn numberFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    const n: f64 = if (args.len == 0) 0 else blk: {
        const v = args[0];
        // ToNumeric: an object coerces via ToPrimitive(number) (valueOf/@@toPrimitive)
        // — e.g. a Date yields its time value; a Symbol is a TypeError. A BigInt
        // operand converts to the nearest Number (Number(10n) === 10).
        if (v == .object and !v.object.is_bigint) {
            if (v.object.is_symbol) return ip.throwError("TypeError", "Cannot convert a Symbol value to a number");
            break :blk (try ip.toPrimitive(v, .number)).toNumber();
        }
        break :blk v.toNumber();
    };
    if (ip.new_target != .undefined) return ip.makeWrapper(.{ .number = n });
    return .{ .number = n };
}

pub fn booleanFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    const b = arg(args, 0).toBoolean();
    if (ip.new_target != .undefined) return ip.makeWrapper(.{ .boolean = b });
    return .{ .boolean = b };
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
        body = try args[args.len - 1].toString(self.arena);
        var i: usize = 0;
        while (i + 1 < args.len) : (i += 1) {
            if (i != 0) try params.append(self.arena, ',');
            try params.appendSlice(self.arena, try args[i].toString(self.arena));
        }
    }
    const source = try std.fmt.allocPrint(self.arena, "(function anonymous({s}\n) {{\n{s}\n}})", .{ params.items, body });
    var parser = Parser.init(self.arena, source) catch
        return self.throwError("SyntaxError", "Function: invalid parameters or body");
    const prog = parser.parseProgram() catch
        return self.throwError("SyntaxError", "Function: invalid parameters or body");
    return self.eval(prog);
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
    const s = try arg(args, 0).toString(interp(ctx).arena);
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
        return .{ .number = if (i > sign_start and s[sign_start] == '-') -std.math.inf(f64) else std.math.inf(f64) };
    const num_start = i;
    var saw_digit = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) saw_digit = true;
    }
    if (!saw_digit) return .{ .number = nan }; // no mantissa digits → NaN
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
    const n = std.fmt.parseFloat(f64, s[num_start..i]) catch return .{ .number = nan };
    return .{ .number = if (sign_start != num_start and s[sign_start] == '-') -n else n };
}

pub fn parseIntFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const s = try arg(args, 0).toString(interp(ctx).arena);
    var radix: u8 = 10;
    if (args.len >= 2) {
        const r = arg(args, 1).toNumber();
        if (!std.math.isNan(r) and r >= 2 and r <= 36) radix = @intFromFloat(r);
    }
    // Skip leading StrWhiteSpace (the full WhiteSpace+LineTerminator set, incl.
    // U+2028/U+2029 and non-ASCII spaces), not just the four ASCII blanks.
    var i: usize = skipStrWhiteSpace(s);
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    if ((radix == 16 or args.len < 2) and i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        radix = 16;
        i += 2;
    }
    var acc: f64 = 0;
    var any = false;
    while (i < s.len) : (i += 1) {
        const d = digitValue(s[i]);
        if (d == null or d.? >= radix) break;
        acc = acc * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d.?));
        any = true;
    }
    if (!any) return .{ .number = std.math.nan(f64) };
    return .{ .number = if (neg) -acc else acc };
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

fn num1(args: []const Value) f64 {
    return arg(args, 0).toNumber();
}

pub fn mathFloor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = @floor(num1(args)) };
}
pub fn mathCeil(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = @ceil(num1(args)) };
}
pub fn mathTrunc(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = @trunc(num1(args)) };
}
pub fn mathRound(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const n = num1(args);
    if (std.math.isNan(n) or std.math.isInf(n) or n == 0) return .{ .number = n }; // preserves ±0
    // Halves round toward +Infinity, but a value rounding to zero keeps the
    // sign of the operand: `Math.round(-0.5)` is -0, `Math.round(-0.4)` is -0.
    if (n > 0 and n < 0.5) return .{ .number = 0 };
    if (n < 0 and n >= -0.5) return .{ .number = -0.0 };
    return .{ .number = @floor(n + 0.5) };
}
pub fn mathAbs(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = @abs(num1(args)) };
}
pub fn mathSqrt(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = @sqrt(num1(args)) };
}
pub fn mathSign(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const n = num1(args);
    if (std.math.isNan(n)) return .{ .number = n };
    if (n > 0) return .{ .number = 1 };
    if (n < 0) return .{ .number = -1 };
    return .{ .number = n }; // preserves +0 / -0
}
pub fn mathPow(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const base = try self.toNumberV(arg(args, 0));
    const exp = try self.toNumberV(arg(args, 1));
    // JS exponentiation overrides IEEE pow: a NaN exponent is always NaN (even
    // `pow(1, NaN)`), and `pow(±1, ±Infinity)` is NaN (IEEE returns 1).
    if (std.math.isNan(exp)) return .{ .number = std.math.nan(f64) };
    if (std.math.isInf(exp) and @abs(base) == 1) return .{ .number = std.math.nan(f64) };
    return .{ .number = std.math.pow(f64, base, exp) };
}
pub fn mathMax(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var m: f64 = -std.math.inf(f64);
    for (args) |v| {
        const n = try self.toNumberV(v); // ToNumber per element, in order
        if (std.math.isNan(n)) return .{ .number = n };
        // +0 is greater than -0: prefer +0 when both are zero.
        if (n > m or (n == 0 and m == 0 and std.math.signbit(m) and !std.math.signbit(n))) m = n;
    }
    return .{ .number = m };
}
pub fn mathMin(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var m: f64 = std.math.inf(f64);
    for (args) |v| {
        const n = try self.toNumberV(v);
        if (std.math.isNan(n)) return .{ .number = n };
        // -0 is less than +0: prefer -0 when both are zero.
        if (n < m or (n == 0 and m == 0 and !std.math.signbit(m) and std.math.signbit(n))) m = n;
    }
    return .{ .number = m };
}

/// Build a `Math` native from a plain `f64 -> f64` function (the trig / log /
/// exp family). Keeps registration to one line each.
pub fn unaryMath(comptime f: fn (f64) f64) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = ctx;
            _ = this;
            return .{ .number = f(arg(args, 0).toNumber()) };
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
        return @exp(x);
    }
    pub fn expm1(x: f64) f64 {
        return std.math.expm1(x);
    }
    pub fn log(x: f64) f64 {
        return @log(x);
    }
    pub fn log2(x: f64) f64 {
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

pub fn mathAtan2(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = std.math.atan2(arg(args, 0).toNumber(), arg(args, 1).toNumber()) };
}

pub fn mathHypot(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var sum: f64 = 0;
    var any_inf = false;
    var any_nan = false;
    for (args) |v| {
        const n = try self.toNumberV(v); // coerce every arg in order (abrupt propagates)
        if (std.math.isInf(n)) any_inf = true;
        if (std.math.isNan(n)) any_nan = true;
        sum += n * n;
    }
    // ±Infinity in any argument wins over a NaN in another.
    if (any_inf) return .{ .number = std.math.inf(f64) };
    if (any_nan) return .{ .number = std.math.nan(f64) };
    return .{ .number = @sqrt(sum) };
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
    var acc = [_]u32{0} ** SUM_WORDS;
    var count: usize = 0;
    var has_nan = false;
    var has_pos_inf = false;
    var has_neg_inf = false;
    var all_neg_zero = true; // an exact-zero result is -0 only if every element was -0
    while (true) {
        const r = try self.callMethod(iter, "next", &.{});
        if (r != .object) return self.throwError("TypeError", "iterator.next() did not return an object");
        if ((try self.getProperty(r, "done")).toBoolean()) break;
        const v = try self.getProperty(r, "value");
        if (v != .number) {
            self.iteratorClose(iter) catch {};
            return self.throwError("TypeError", "Math.sumPrecise: every element must be a Number");
        }
        count += 1;
        const x = v.number;
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
    if (count == 0) return .{ .number = -0.0 };
    if (has_nan) return .{ .number = std.math.nan(f64) };
    if (has_pos_inf and has_neg_inf) return .{ .number = std.math.nan(f64) };
    if (has_pos_inf) return .{ .number = std.math.inf(f64) };
    if (has_neg_inf) return .{ .number = -std.math.inf(f64) };
    const result = sumRoundToF64(&acc);
    if (result == 0) return .{ .number = if (all_neg_zero) -0.0 else 0.0 };
    return .{ .number = result };
}

pub fn mathClz32(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = @floatFromInt(@clz(arg(args, 0).toUint32())) };
}

pub fn mathImul(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const a: i32 = arg(args, 0).toInt32();
    const b: i32 = arg(args, 1).toInt32();
    return .{ .number = @floatFromInt(a *% b) };
}

var math_prng = std.Random.DefaultPrng.init(0x2545F4914F6CDD1D);

pub fn mathRandom(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return .{ .number = math_prng.random().float(f64) };
}

// ---- Object / Array ----------------------------------------------------

/// Own enumerable string keys of `o`, in spec order: integer array indices
/// ascending first, then named keys in insertion order. Array element indices
/// live in the dense `elements` store (not the shape), so they're added here;
/// a per-index `enumerable:false` (from defineProperty) hides one.
fn ownEnumerableKeys(self: *Interpreter, o: *value.Object) HostError![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    // A module namespace's enumerable own keys are exactly its (sorted) string
    // export names; the @@toStringTag is non-enumerable.
    if (interpreter.isModuleNs(o)) {
        try list.appendSlice(self.arena, interpreter.moduleNsNames(o));
        return list.items;
    }
    // A Proxy's enumerable own string keys: [[OwnPropertyKeys]] (ownKeys trap)
    // filtered by [[GetOwnProperty]] (getOwnPropertyDescriptor trap) enumerable.
    if (o.proxy_handler != null or o.proxy_revoked) {
        for (try self.proxyOwnKeys(o)) |k| {
            if (value.isSymbolKey(k) or value.isPrivateKey(k)) continue;
            const desc = try objectGetOwnPropertyDescriptor(self, .undefined, &.{ .{ .object = o }, self.keyToValue(k) });
            if (desc == .object and (try self.getProperty(desc, "enumerable")).toBoolean())
                try list.append(self.arena, k);
        }
        return list.items;
    }
    if (o.is_array) {
        var i: usize = 0;
        while (i < o.elements.items.len) : (i += 1) {
            const k = try std.fmt.allocPrint(self.arena, "{d}", .{i});
            if (o.getAttr(k).enumerable) try list.append(self.arena, k);
        }
    }
    for (try o.enumerableKeys(self.arena)) |k| try list.append(self.arena, k);
    return list.items;
}

/// Own value of `key` on `o`, resolving an array index to its dense element.
fn ownValueOf(o: *value.Object, key: []const u8) Value {
    if (o.is_array) {
        if (arrayIndexOf(key)) |i| {
            if (i < o.elements.items.len) return o.elements.items[i];
        }
    }
    return o.getOwn(key) orelse .undefined;
}

pub fn objectKeys(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const keys = try ownEnumerableKeys(self, arg(args, 0).object);
        for (keys) |k| try result.object.elements.append(self.arena, .{ .string = k });
    }
    return result;
}

pub fn objectValues(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        const keys = try ownEnumerableKeys(self, o);
        for (keys) |k| try result.object.elements.append(self.arena, ownValueOf(o, k));
    }
    return result;
}

/// `Object.hasOwn(O, P)` — HasOwnProperty after ToObject(O) / ToPropertyKey(P).
/// The ergonomic replacement for `Object.prototype.hasOwnProperty.call`.
pub fn objectHasOwn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const key = try self.keyOf(arg(args, 1));
    switch (arg(args, 0)) {
        .undefined, .null => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
        .object => |o| return .{ .boolean = interpreter.objectHasOwn(o, key) },
        .string => |s| {
            if (std.mem.eql(u8, key, "length")) return .{ .boolean = true };
            if (Interpreter.arrayIndex(key)) |i| return .{ .boolean = i < s.len };
            return .{ .boolean = false };
        },
        else => return .{ .boolean = false },
    }
}

pub fn objectAssign(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // ToObject(target): null/undefined throw; a primitive boxes to a wrapper.
    const to = try self.toObject(arg(args, 0));
    const to_v: Value = .{ .object = to };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        // A null/undefined source is skipped; other primitives ToObject.
        if (args[i] == .null or args[i] == .undefined) continue;
        const src_v: Value = .{ .object = try self.toObject(args[i]) };
        // Every enumerable own key — string AND symbol (private excluded) — is
        // copied, in [[OwnPropertyKeys]] order.
        for (try src_v.object.ownKeys(self.arena)) |k| {
            if (value.isPrivateKey(k)) continue;
            if (!src_v.object.getAttr(k).enumerable) continue;
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
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        const keys = try ownEnumerableKeys(self, o);
        for (keys) |k| {
            const pair = try self.newArray();
            try pair.object.elements.append(self.arena, .{ .string = k });
            try pair.object.elements.append(self.arena, ownValueOf(o, k));
            try result.object.elements.append(self.arena, pair);
        }
    }
    return result;
}

pub fn objectFromEntries(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const iterable = arg(args, 0);
    // RequireObjectCoercible(iterable): undefined/null throw.
    if (iterable == .null or iterable == .undefined)
        return self.throwError("TypeError", "Object.fromEntries requires an iterable argument");
    const result = try self.newObject();
    const iter = try self.iteratorOf(iterable); // GetIterator — non-iterable throws
    while (true) {
        // IteratorStep: a next() that isn't callable / doesn't return an object
        // throws WITHOUT closing the iterator.
        const r = try self.callMethod(iter, "next", &.{});
        if (r != .object) return self.throwError("TypeError", "iterator.next() did not return an object");
        if ((try self.getProperty(r, "done")).toBoolean()) break;
        const entry = try self.getProperty(r, "value");
        // Each entry must be an Object; otherwise close the iterator, then throw.
        if (entry != .object) {
            self.iteratorClose(iter) catch {};
            return self.throwError("TypeError", "Object.fromEntries entry is not an object");
        }
        // key = ToPropertyKey(Get(entry,"0")); value = Get(entry,"1"); a throw in
        // either step closes the iterator (IteratorClose on abrupt completion).
        const key = self.keyOf(try self.getProperty(entry, "0")) catch |e| {
            self.iteratorClose(iter) catch {};
            return e;
        };
        const v = self.getProperty(entry, "1") catch |e| {
            self.iteratorClose(iter) catch {};
            return e;
        };
        try self.setMember(result, key, v);
    }
    return result;
}

pub fn arrayOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    for (args) |v| try result.object.elements.append(self.arena, v);
    return result;
}

/// `Array(...)` / `new Array(...)`: a single numeric argument is a length
/// (RangeError if not a valid array index count); otherwise the arguments become
/// the elements.
pub fn arrayConstructor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const arr = try self.newArray();
    if (args.len == 1 and args[0] == .number) {
        const n = args[0].number;
        if (n < 0 or @trunc(n) != n or n > 4294967295) return self.throwError("RangeError", "Invalid array length");
        // `new Array(len)` is a sparse array — length `len`, no elements (every
        // index a hole, so `0 in new Array(1)` is false and forEach/map skip
        // them). Only the logical length is set.
        arr.object.array_len = @intFromFloat(n);
    } else {
        for (args) |v| try arr.object.elements.append(self.arena, v);
    }
    return arr;
}

/// `Object(...)` / `new Object(...)`: returns the argument coerced to an object
/// (a fresh `{}` for null/undefined; the object itself when already one).
pub fn objectConstructor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const v = arg(args, 0);
    if (v == .object) return v;
    if (v == .undefined or v == .null) return self.newObject();
    // ToObject of a primitive boxes it into the matching wrapper, whose
    // prototype is that primitive constructor's `.prototype` (so e.g.
    // `new Object("s").constructor === String`). Note this is *not* the
    // in-flight `new.target` (always Object here), so makeWrapper isn't right.
    const ctor_name: []const u8 = switch (v) {
        .string => "String",
        .number => "Number",
        .boolean => "Boolean",
        else => return self.newObject(),
    };
    const o = try self.arena.create(value.Object);
    o.* = .{ .prim = v };
    if (self.env.get(ctor_name)) |ctor| {
        if (ctor == .object) o.proto = try self.protoObject(ctor.object);
    }
    return .{ .object = o };
}

pub fn arrayFrom(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    const src = arg(args, 0);
    const map_fn = arg(args, 1);
    const has_map = map_fn == .object and map_fn.object.isCallableObject();

    if (self.isIterable(src)) {
        // Iterator path: strings, arrays, generators, user `[Symbol.iterator]`.
        const it = try self.iteratorOf(src);
        var idx: f64 = 0;
        while (true) {
            const res = try self.callMethod(it, "next", &.{});
            if ((try self.getProperty(res, "done")).toBoolean()) break;
            var v = try self.getProperty(res, "value");
            if (has_map) v = try self.callValue(map_fn, &.{ v, .{ .number = idx } });
            try result.object.elements.append(self.arena, v);
            idx += 1;
        }
    } else if (src == .object) {
        // Array-like: copy indices 0..length-1.
        if (src.object.getOwn("length")) |len_v| {
            const n: usize = @intFromFloat(@max(@trunc(len_v.toNumber()), 0));
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
                var v = src.object.getOwn(key) orelse .undefined;
                if (has_map) v = try self.callValue(map_fn, &.{ v, .{ .number = @floatFromInt(i) } });
                try result.object.elements.append(self.arena, v);
            }
        }
    }
    return result;
}

pub fn identity1(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return arg(args, 0);
}

pub fn arrayIsArray(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .boolean = arg(args, 0) == .object and arg(args, 0).object.is_array };
}

pub fn mapFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    // Map/WeakMap are constructors only: a plain call (`Map()`) throws.
    if (ip.new_target == .undefined) return ip.throwError("TypeError", "Constructor Map/WeakMap requires 'new'");
    return ip.makeMap(arg(args, 0));
}

pub fn setFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const ip = interp(ctx);
    if (ip.new_target == .undefined) return ip.throwError("TypeError", "Constructor Set/WeakSet requires 'new'");
    return ip.makeSet(arg(args, 0));
}

/// `RegExp(pattern, flags)` / `new RegExp(...)`. Accepts a string source or an
/// existing RegExp (copying its source).
pub fn regExpFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const a0 = arg(args, 0);
    var pattern: []const u8 = "";
    var src_flags: []const u8 = "";
    if (a0 == .object and a0.object.is_regex) {
        pattern = a0.object.regex_source;
        src_flags = a0.object.regex_flags; // `new RegExp(re)` inherits re's flags
    } else if (a0 != .undefined) {
        pattern = try a0.toString(self.arena);
    }
    const flags = if (arg(args, 1) != .undefined) try arg(args, 1).toString(self.arena) else src_flags;
    return self.makeRegex(pattern, flags);
}

pub fn objectGetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        if (o.proxy_handler != null or o.proxy_revoked) return self.proxyGetProto(o);
        // [[GetPrototypeOf]]: a callable with no explicit prototype reports
        // %Function.prototype% (every function inherits it).
        if (self.effectiveProto(o)) |p| return .{ .object = p };
    }
    return .null;
}

pub fn objectCreate(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const obj = (try self.newObject()).object;
    switch (arg(args, 0)) {
        .object => |p| obj.proto = p,
        .null => obj.proto = null,
        else => return self.throwError("TypeError", "Object prototype may only be an Object or null"),
    }
    // The optional second argument is a Properties object processed exactly like
    // `Object.defineProperties` (skipped only when undefined).
    if (arg(args, 1) != .undefined) try applyProperties(self, obj, arg(args, 1));
    return .{ .object = obj };
}

pub fn objectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (!isRealObject(target)) return self.throwError("TypeError", "Object.defineProperty called on non-object");
    const key = try self.keyOf(arg(args, 1));
    const desc = arg(args, 2);
    // ToPropertyDescriptor requires an Object — a BigInt or Symbol value (boxed
    // as an object internally) is a primitive and must be rejected.
    if (!isRealObject(desc)) return self.throwError("TypeError", "Property description must be an object");
    try defineOne(self, target.object, key, desc.object);
    return target;
}

/// Core of `Object.defineProperty` / `defineProperties`: apply descriptor `d` to
/// `target[key]`, honoring attributes and bypassing [[Set]].
/// Read a property-descriptor field per ToPropertyDescriptor: present iff
/// HasProperty (own *or inherited*), value via Get (so an inherited or accessor
/// descriptor field is honored). Returns null when absent.
fn descField(self: *Interpreter, d: *value.Object, name: []const u8) HostError!?Value {
    if (!interpreter.hasProperty(d, name)) return null;
    return try self.getProperty(.{ .object = d }, name);
}

pub fn defineOne(self: *Interpreter, target: *value.Object, key: []const u8, d_obj: *value.Object) HostError!void {
    // Materialize the descriptor once over the prototype chain (a field may be
    // inherited or itself an accessor), into a plain own-property record the
    // rest of this function reads via `getOwn`.
    const d = (try self.newObject()).object;
    for ([_][]const u8{ "enumerable", "configurable", "value", "writable", "get", "set" }) |f| {
        if (try descField(self, d_obj, f)) |v| try d.setOwn(self.arena, self.root_shape, f, v);
    }
    const get = d.getOwn("get");
    const set = d.getOwn("set");
    // ToPropertyDescriptor validation: a descriptor may not mix accessor fields
    // (get/set) with data fields (value/writable), and a present get/set must be
    // callable or undefined.
    if ((get != null or set != null) and (d.getOwn("value") != null or d.getOwn("writable") != null))
        return self.throwError("TypeError", "Invalid property descriptor: cannot both specify accessors and a value or writable attribute");
    if (get) |g| {
        if (g != .undefined and !(g == .object and g.object.isCallableObject()))
            return self.throwError("TypeError", "Getter must be a function");
    }
    if (set) |s| {
        if (s != .undefined and !(s == .object and s.object.isCallableObject()))
            return self.throwError("TypeError", "Setter must be a function");
    }
    // [[DefineOwnProperty]] on a Proxy: invoke the `defineProperty` trap with the
    // normalized descriptor object; a falsy result is a TypeError. An absent trap
    // forwards to the target.
    if (target.proxy_handler != null or target.proxy_revoked) {
        if (target.proxy_revoked) return self.throwError("TypeError", "Cannot perform 'defineProperty' on a revoked proxy");
        const handler = target.proxy_handler.?;
        const tgt = target.proxy_target.?;
        const trap = try self.getProperty(.{ .object = handler }, "defineProperty");
        if (trap == .undefined or trap == .null) return defineOne(self, tgt, key, d);
        if (!trap.isCallable()) return self.throwError("TypeError", "proxy 'defineProperty' trap is not callable");
        const res = try self.callValueWithThis(trap, &.{ .{ .object = tgt }, self.keyToValue(key), .{ .object = d } }, .{ .object = handler });
        if (!res.toBoolean()) return self.throwError("TypeError", "proxy 'defineProperty' trap returned falsish for property");
        // [[DefineOwnProperty]] invariants (9.5.6) for an ordinary target.
        if (tgt.proxy_handler == null and !tgt.proxy_revoked) {
            const setting_nonconfig = if (d.getOwn("configurable")) |c| !c.toBoolean() else false;
            const has_own = tgt.getOwn(key) != null or tgt.getAccessor(key) != null;
            if (!has_own) {
                if (!tgt.extensible) return self.throwError("TypeError", "proxy 'defineProperty' cannot add a property to a non-extensible target");
                if (setting_nonconfig) return self.throwError("TypeError", "proxy 'defineProperty' cannot define a non-configurable property absent from the target");
            } else {
                // Reporting a property as non-configurable that the target still
                // exposes as configurable is a lie.
                if (setting_nonconfig and tgt.getAttr(key).configurable)
                    return self.throwError("TypeError", "proxy 'defineProperty' cannot report a configurable target property as non-configurable");
                // A non-configurable target property only admits a compatible
                // redefinition (IsCompatiblePropertyDescriptor).
                if (!tgt.getAttr(key).configurable)
                    try rejectIncompatibleRedefine(self, tgt.getAttr(key), tgt.getOwn(key), tgt.getAccessor(key), d);
            }
        }
        return;
    }
    // Array `length` is a data property { writable, !enumerable, !configurable }.
    // Redefining it can change the value (ToUint32, truncating/extending) and
    // toggle writability, but not make it configurable/enumerable or an accessor.
    if (target.is_array and std.mem.eql(u8, key, "length")) {
        if (get != null or set != null) return self.throwError("TypeError", "Cannot redefine 'length' as an accessor");
        if (d.getOwn("configurable")) |c| {
            if (c.toBoolean()) return self.throwError("TypeError", "Cannot redefine property: length");
        }
        if (d.getOwn("enumerable")) |e| {
            if (e.toBoolean()) return self.throwError("TypeError", "Cannot redefine property: length");
        }
        const cur_writable = if (target.attrs != null) target.getAttr("length").writable else true;
        // ArraySetLength (ES 10.4.2.4): reducing `length` deletes elements from
        // the top down; a non-configurable element blocks the deletion — `length`
        // stops just above it and the redefinition fails (a TypeError). `length`
        // and its (possibly new) writability are still applied before throwing.
        var blocked = false;
        if (d.getOwn("value")) |val| {
            // ToUint32(ToNumber(value)): a value object's valueOf/toString runs
            // here (and a Symbol/BigInt throws) — newLen must equal numberLen.
            const n = try self.toNumberV(val);
            const u = Value.uint32FromF64(n);
            if (@as(f64, @floatFromInt(u)) != n) return self.throwError("RangeError", "Invalid array length");
            if (!cur_writable and u != @max(target.elements.items.len, target.array_len))
                return self.throwError("TypeError", "Cannot assign to read only property 'length'");
            var new_len: usize = u;
            if (u < target.elements.items.len) {
                // Only an array carrying per-index attributes can hold a
                // non-configurable element; otherwise truncate straight to `u`.
                if (target.attrs != null) {
                    var i: usize = target.elements.items.len;
                    while (i > u) {
                        i -= 1;
                        if (target.isHole(i)) continue;
                        var kb: [24]u8 = undefined;
                        const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
                        if (!target.getAttr(k).configurable) {
                            new_len = i + 1;
                            blocked = true;
                            break;
                        }
                    }
                }
                target.elements.shrinkRetainingCapacity(new_len);
            }
            target.array_len = @intCast(new_len);
        }
        var lattr: value.PropAttr = .{ .writable = cur_writable, .enumerable = false, .configurable = false };
        if (d.getOwn("writable")) |w| lattr.writable = w.toBoolean();
        try target.setAttr(self.arena, "length", lattr);
        if (blocked) return self.throwError("TypeError", "Cannot delete a non-configurable array element while reducing length");
        return;
    }
    // Array index with a data descriptor: keep the value in the dense element
    // store and record its attributes in the string-keyed `attrs` map (so
    // reads/writes/getOwnPropertyDescriptor agree), rather than splitting it
    // into the named-property store. Accessor descriptors on an index, huge or
    // gappy indices, and `length` fall through to the generic path below.
    if (target.is_array and get == null and set == null and !std.mem.eql(u8, key, "length") and target.getAccessor(key) == null) {
        if (arrayIndexOf(key)) |i| {
            if (i <= target.elements.items.len + 1024 and i < (1 << 24)) {
                const within = i < target.elements.items.len;
                const cur_attr = target.getAttr(key);
                if (within and !cur_attr.configurable) {
                    try rejectIncompatibleRedefine(self, cur_attr, target.elements.items[i], null, d);
                } else if (!within and !target.extensible) {
                    return self.throwError("TypeError", "Cannot define property, object is not extensible");
                }
                while (target.elements.items.len <= i) try target.elements.append(self.arena, .undefined);
                if (d.getOwn("value")) |val| target.elements.items[i] = val;
                // Omitted fields keep the current value when redefining an
                // existing element (implicitly all-true), else default to false.
                var attr: value.PropAttr = if (within) cur_attr else .{ .writable = false, .enumerable = false, .configurable = false };
                if (d.getOwn("writable")) |w| attr.writable = w.toBoolean();
                if (d.getOwn("enumerable")) |e| attr.enumerable = e.toBoolean();
                if (d.getOwn("configurable")) |c| attr.configurable = c.toBoolean();
                try target.setAttr(self.arena, key, attr);
                if (i >= target.array_len) target.array_len = i + 1;
                return;
            }
        }
    }
    const cur_data = target.getOwn(key);
    const cur_acc = target.getAccessor(key);
    const exists = cur_data != null or cur_acc != null;
    // ValidateAndApplyPropertyDescriptor: reject (TypeError) any change that the
    // current state forbids — adding to a non-extensible object, or altering a
    // non-configurable property in an incompatible way.
    if (!exists) {
        if (!target.extensible)
            return self.throwError("TypeError", "Cannot define property, object is not extensible");
    } else if (!target.getAttr(key).configurable) {
        try rejectIncompatibleRedefine(self, target.getAttr(key), cur_data, cur_acc, d);
    }
    // Redefining keeps the current attributes for any omitted field; a new
    // property defaults omitted fields to false.
    var attr: value.PropAttr = if (exists) target.getAttr(key) else .{ .writable = false, .enumerable = false, .configurable = false };
    if (d.getOwn("enumerable")) |e| attr.enumerable = e.toBoolean();
    if (d.getOwn("configurable")) |c| attr.configurable = c.toBoolean();
    if (get != null or set != null) {
        try target.setAccessor(self.arena, key, get, set);
    } else {
        if (d.getOwn("writable")) |w| attr.writable = w.toBoolean();
        // An omitted `value` keeps the existing data property's value on a
        // redefine (a partial descriptor like `{enumerable:false}` must not reset
        // it); a brand-new property — or one converted from an accessor — defaults
        // to undefined.
        const new_value = d.getOwn("value") orelse (cur_data orelse .undefined);
        try target.setOwn(self.arena, self.root_shape, key, new_value);
    }
    try target.setAttr(self.arena, key, attr);
    // Defining an own property at an array index at or past the current length
    // extends the array's length (so iteration sees it).
    if (target.is_array) {
        if (arrayIndexOf(key)) |i| {
            if (i + 1 > target.array_len and i + 1 > target.elements.items.len) target.array_len = i + 1;
        }
    }
}

/// The rejection half of ValidateAndApplyPropertyDescriptor, for an existing
/// *non-configurable* property: throw a TypeError if descriptor `d` tries to
/// flip configurable on, change enumerable, switch between data/accessor, or —
/// for a non-writable data property — change writability or value. A generic
/// descriptor (no value/writable/get/set) only constrains config/enumerable.
fn rejectIncompatibleRedefine(
    self: *Interpreter,
    cur_attr: value.PropAttr,
    cur_data: ?Value,
    cur_acc: ?value.Accessor,
    d: *value.Object,
) HostError!void {
    if (d.getOwn("configurable")) |c| {
        if (c.toBoolean()) return self.throwError("TypeError", "Cannot redefine property: not configurable");
    }
    if (d.getOwn("enumerable")) |e| {
        if (e.toBoolean() != cur_attr.enumerable)
            return self.throwError("TypeError", "Cannot redefine property: not configurable");
    }
    const d_get = d.getOwn("get");
    const d_set = d.getOwn("set");
    const d_is_accessor = d_get != null or d_set != null;
    const d_is_data = d.getOwn("value") != null or d.getOwn("writable") != null;
    if (!d_is_accessor and !d_is_data) return; // generic descriptor: nothing more to check

    const cur_is_accessor = cur_acc != null;
    if (d_is_accessor != cur_is_accessor)
        return self.throwError("TypeError", "Cannot redefine property: not configurable");

    if (cur_is_accessor) {
        const acc = cur_acc.?;
        if (d_get) |g| {
            if (!sameValue(g, acc.get orelse .undefined)) return self.throwError("TypeError", "Cannot redefine property: not configurable");
        }
        if (d_set) |s| {
            if (!sameValue(s, acc.set orelse .undefined)) return self.throwError("TypeError", "Cannot redefine property: not configurable");
        }
    } else if (!cur_attr.writable) {
        if (d.getOwn("writable")) |w| {
            if (w.toBoolean()) return self.throwError("TypeError", "Cannot redefine property: not configurable");
        }
        if (d.getOwn("value")) |v| {
            if (!sameValue(v, cur_data orelse .undefined)) return self.throwError("TypeError", "Cannot redefine property: not configurable");
        }
    }
}

pub fn objectDefineProperties(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (target != .object) return self.throwError("TypeError", "Object.defineProperties called on non-object");
    try applyProperties(self, target.object, arg(args, 1));
    return target;
}

/// Apply each enumerable own property of `props` to `target` as a descriptor —
/// the shared core of `Object.defineProperties` and `Object.create`'s second
/// argument. Each value must itself be an object (a property descriptor).
fn applyProperties(self: *Interpreter, target: *value.Object, props: Value) HostError!void {
    // ToObject(Properties): null/undefined throw; other primitives box to an
    // object with no own enumerable properties (a no-op).
    if (props == .null or props == .undefined)
        return self.throwError("TypeError", "Cannot convert undefined or null to object");
    if (props != .object) return;
    // Snapshot the enumerable own keys, then read each descriptor object via
    // [[Get]] (so an accessor-valued descriptor property runs its getter), per
    // ObjectDefineProperties — not the raw data slot.
    for (try props.object.enumerableKeys(self.arena)) |k| {
        const d = try self.getProperty(props, k);
        if (!isRealObject(d)) return self.throwError("TypeError", "Property description must be an object");
        try defineOne(self, target, k, d.object);
    }
}

pub fn objectPreventExtensions(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const o = arg(args, 0);
    if (o == .object) {
        if (o.object.proxy_handler != null or o.object.proxy_revoked) {
            _ = try self.proxyPreventExt(o.object);
        } else o.object.extensible = false;
    }
    return o;
}

pub fn objectIsExtensible(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const o = arg(args, 0);
    if (o != .object) return .{ .boolean = false };
    if (o.object.proxy_handler != null or o.object.proxy_revoked) return .{ .boolean = try self.proxyIsExtensible(o.object) };
    return .{ .boolean = o.object.extensible };
}

pub fn objectSeal(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    _ = this;
    const o = arg(args, 0);
    if (o == .object) {
        o.object.extensible = false;
        try lockKeys(self, o.object, false);
    }
    return o;
}

pub fn objectFreeze(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const self = interp(ctx);
    _ = this;
    const o = arg(args, 0);
    if (o == .object) {
        o.object.extensible = false;
        try lockKeys(self, o.object, true);
    }
    return o;
}

/// Make every own property non-configurable (and, when `freeze`, every data
/// property non-writable). Backs `seal`/`freeze`.
fn lockKeys(self: *Interpreter, o: *value.Object, freeze: bool) HostError!void {
    for (try o.ownKeys(self.arena)) |k| {
        var a = o.getAttr(k);
        a.configurable = false;
        if (freeze) a.writable = false;
        try o.setAttr(self.arena, k, a);
    }
    if (o.accessors) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            var a = o.getAttr(e.key_ptr.*);
            a.configurable = false;
            try o.setAttr(self.arena, e.key_ptr.*, a);
        }
    }
    // An array's dense element indices live in `elements` (not the shape), so
    // they aren't in `ownKeys` — lock each present one, plus `length` (which
    // `freeze` additionally makes non-writable).
    if (o.is_array) {
        var i: usize = 0;
        while (i < o.elements.items.len) : (i += 1) {
            if (o.isHole(i)) continue;
            var kb: [24]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
            var a = o.getAttr(k);
            a.configurable = false;
            if (freeze) a.writable = false;
            try o.setAttr(self.arena, k, a);
        }
        var la = o.getAttr("length");
        if (freeze) la.writable = false;
        la.configurable = false;
        try o.setAttr(self.arena, "length", la);
    }
}

pub fn objectIsSealed(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .boolean = isLocked(arg(args, 0), false) };
}

pub fn objectIsFrozen(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .boolean = isLocked(arg(args, 0), true) };
}

/// A non-object is trivially sealed/frozen. Otherwise: non-extensible, every own
/// property non-configurable (and, for `frozen`, every data property
/// non-writable). Arrays with elements can't be frozen (no per-index attrs yet).
fn isLocked(ov: Value, frozen: bool) bool {
    if (ov != .object) return true;
    const o = ov.object;
    if (o.extensible) return false;
    // An array's dense element indices must each be non-configurable (and, for
    // frozen, non-writable). A frozen array additionally needs non-writable
    // `length`. Holes carry no property, so they don't block.
    if (o.is_array) {
        var i: usize = 0;
        while (i < o.elements.items.len) : (i += 1) {
            if (o.isHole(i)) continue;
            var kb: [24]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
            const a = o.getAttr(k);
            if (a.configurable) return false;
            if (frozen and a.writable) return false;
        }
        if (frozen and o.getAttr("length").writable) return false;
    }
    var s = o.shape;
    while (s) |sh| {
        if (sh.name) |n| {
            const a = o.getAttr(n);
            if (a.configurable) return false;
            if (frozen and a.writable) return false;
        }
        s = sh.parent;
    }
    if (o.accessors) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            if (o.getAttr(e.key_ptr.*).configurable) return false;
        }
    }
    return true;
}

pub fn objectIs(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .boolean = sameValue(arg(args, 0), arg(args, 1)) };
}

/// SameValue: like `===` but NaN equals NaN and +0 differs from -0.
fn sameValue(a: Value, b: Value) bool {
    if (a == .number and b == .number) {
        const x = a.number;
        const y = b.number;
        if (std.math.isNan(x) and std.math.isNan(y)) return true;
        if (x == 0 and y == 0) return (1.0 / x) == (1.0 / y); // +0 vs -0
        return x == y;
    }
    return value.strictEquals(a, b);
}

pub fn objectSetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const o = arg(args, 0);
    // RequireObjectCoercible; the new prototype must be an Object or null.
    if (o == .null or o == .undefined)
        return self.throwError("TypeError", "Object.setPrototypeOf called on null or undefined");
    const p = arg(args, 1);
    if (p != .object and p != .null)
        return self.throwError("TypeError", "Object prototype may only be an Object or null");
    if (o != .object) return o; // a primitive `this` has no own [[Prototype]] to set
    const new_proto: ?*value.Object = if (p == .object) p.object else null;
    if (o.object.proto == new_proto) return o; // no-op when unchanged
    if (!o.object.extensible)
        return self.throwError("TypeError", "Cannot set prototype of a non-extensible object");
    // Reject a cycle (a non-proxy chain that loops back to the target).
    var cur = new_proto;
    while (cur) |c| {
        if (c == o.object) return self.throwError("TypeError", "Cyclic __proto__ value");
        cur = c.proto;
    }
    o.object.proto = new_proto;
    return o;
}

pub fn objectGetOwnPropertySymbols(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        // [[OwnPropertyKeys]] (proxy-aware: the ownKeys trap + its invariants run
        // here and may throw), then keep only the symbol keys.
        for (try self.objectOwnKeysList(o)) |k| {
            if (value.isSymbolKey(k) and !value.isPrivateKey(k))
                try result.object.elements.append(self.arena, self.keyToValue(k));
        }
    }
    return result;
}

pub fn objectGetOwnPropertyDescriptors(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newObject();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        for (try o.ownKeys(self.arena)) |k| {
            if (value.isPrivateKey(k)) continue; // private slots aren't reflected
            const d = try objectGetOwnPropertyDescriptor(ctx, .undefined, &.{ arg(args, 0), .{ .string = k } });
            try self.setMember(result, k, d);
        }
    }
    return result;
}

/// CompletePropertyDescriptor ∘ FromPropertyDescriptor over a (possibly partial)
/// descriptor object — fills omitted fields with their defaults and returns a
/// fresh, fully-populated data or accessor descriptor object.
fn completeDescriptor(self: *Interpreter, desc_obj: *value.Object) HostError!Value {
    const getf = try descField(self, desc_obj, "get");
    const setf = try descField(self, desc_obj, "set");
    const is_accessor = getf != null or setf != null;
    const out = (try self.newObject()).object;
    if (is_accessor) {
        try self.setMember(.{ .object = out }, "get", getf orelse .undefined);
        try self.setMember(.{ .object = out }, "set", setf orelse .undefined);
    } else {
        try self.setMember(.{ .object = out }, "value", (try descField(self, desc_obj, "value")) orelse .undefined);
        try self.setMember(.{ .object = out }, "writable", .{ .boolean = if (try descField(self, desc_obj, "writable")) |w| w.toBoolean() else false });
    }
    try self.setMember(.{ .object = out }, "enumerable", .{ .boolean = if (try descField(self, desc_obj, "enumerable")) |e| e.toBoolean() else false });
    try self.setMember(.{ .object = out }, "configurable", .{ .boolean = if (try descField(self, desc_obj, "configurable")) |c| c.toBoolean() else false });
    return .{ .object = out };
}

pub fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const ov = arg(args, 0);
    if (ov != .object) return .undefined;
    const o = ov.object;
    const key = try self.keyOf(arg(args, 1));
    // Private members are internal slots — invisible to reflection.
    if (value.isPrivateKey(key)) return .undefined;
    if (interpreter.isModuleNs(o)) return interpreter.moduleNsDesc(self, o, key);

    // [[GetOwnProperty]] on a Proxy: the trap returns a descriptor object or
    // undefined; the result is normalized (CompletePropertyDescriptor). An
    // absent trap forwards to the target.
    if (o.proxy_handler != null or o.proxy_revoked) {
        if (o.proxy_revoked) return self.throwError("TypeError", "Cannot perform 'getOwnPropertyDescriptor' on a revoked proxy");
        const handler = o.proxy_handler.?;
        const tgt = o.proxy_target.?;
        const trap = try self.getProperty(.{ .object = handler }, "getOwnPropertyDescriptor");
        if (trap == .undefined or trap == .null)
            return objectGetOwnPropertyDescriptor(ctx, .undefined, &.{ .{ .object = tgt }, arg(args, 1) });
        if (!trap.isCallable()) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' trap is not callable");
        const res = try self.callValueWithThis(trap, &.{ .{ .object = tgt }, self.keyToValue(key) }, .{ .object = handler });
        if (res != .undefined and res != .object) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' trap must return an object or undefined");
        // [[GetOwnProperty]] invariants (9.5.5) for an ordinary target: a trap
        // that hides a property must respect non-configurability / extensibility.
        if (tgt.proxy_handler == null and !tgt.proxy_revoked) {
            const has_own = tgt.getOwn(key) != null or tgt.getAccessor(key) != null;
            if (res == .undefined and has_own) {
                if (!tgt.getAttr(key).configurable) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a non-configurable property as absent");
                if (!tgt.extensible) return self.throwError("TypeError", "proxy 'getOwnPropertyDescriptor' cannot report a property of a non-extensible target as absent");
            }
        }
        if (res == .undefined) return .undefined;
        return try completeDescriptor(self, res.object);
    }

    if (o.getAccessor(key)) |acc| {
        const a = o.getAttr(key);
        const desc = try self.newObject();
        try self.setMember(desc, "get", acc.get orelse .undefined);
        try self.setMember(desc, "set", acc.set orelse .undefined);
        try self.setMember(desc, "enumerable", .{ .boolean = a.enumerable });
        try self.setMember(desc, "configurable", .{ .boolean = a.configurable });
        return desc;
    }
    if (o.getOwn(key)) |v| {
        const a = o.getAttr(key);
        return dataDescriptor(self, v, a);
    }
    if (o.is_array) {
        if (std.mem.eql(u8, key, "length")) {
            const w = if (o.attrs != null) o.getAttr("length").writable else true;
            return dataDescriptor(self, .{ .number = @floatFromInt(@max(o.elements.items.len, o.array_len)) }, .{ .writable = w, .enumerable = false, .configurable = false });
        }
        if (arrayIndexOf(key)) |i| {
            // Per-index attributes recorded by `defineProperty` override the
            // all-true default for a dense element.
            if (i < o.elements.items.len)
                return dataDescriptor(self, o.elements.items[i], o.getAttr(key));
        }
    }
    return .undefined;
}

fn dataDescriptor(self: *Interpreter, v: Value, a: value.PropAttr) HostError!Value {
    const desc = try self.newObject();
    try self.setMember(desc, "value", v);
    try self.setMember(desc, "writable", .{ .boolean = a.writable });
    try self.setMember(desc, "enumerable", .{ .boolean = a.enumerable });
    try self.setMember(desc, "configurable", .{ .boolean = a.configurable });
    return desc;
}

/// Parse a canonical array index (no leading zeros, < 2^32-1) from a key.
fn arrayIndexOf(key: []const u8) ?usize {
    if (key.len == 0) return null;
    if (key.len > 1 and key[0] == '0') return null;
    var n: usize = 0;
    for (key) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

pub fn objectGetOwnPropertyNames(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        // [[OwnPropertyKeys]] (proxy-aware, array-index/length-aware), string
        // keys only (symbols go to getOwnPropertySymbols).
        for (try self.objectOwnKeysList(o)) |k| {
            if (value.isSymbolKey(k) or value.isPrivateKey(k)) continue;
            try result.object.elements.append(self.arena, .{ .string = k });
        }
    }
    return result;
}

// ---- Number statics ----------------------------------------------------

pub fn numberIsInteger(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    if (v != .number) return .{ .boolean = false };
    const n = v.number;
    return .{ .boolean = !std.math.isNan(n) and !std.math.isInf(n) and @trunc(n) == n };
}

pub fn numberIsSafeInteger(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    if (v != .number) return .{ .boolean = false };
    const n = v.number;
    return .{ .boolean = !std.math.isNan(n) and !std.math.isInf(n) and @trunc(n) == n and @abs(n) <= 9007199254740991 };
}

pub fn numberIsNaN(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    return .{ .boolean = v == .number and std.math.isNan(v.number) };
}

pub fn numberIsFinite(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const v = arg(args, 0);
    return .{ .boolean = v == .number and !std.math.isNan(v.number) and !std.math.isInf(v.number) };
}

pub fn stringFromCharCode(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (args) |c| {
        const n = c.toNumber();
        const code: u8 = if (std.math.isNan(n) or std.math.isInf(n)) 0 else @intFromFloat(@mod(@trunc(n), 256));
        try buf.append(self.arena, code);
    }
    return .{ .string = try buf.toOwnedSlice(self.arena) };
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
    for (args) |c| {
        const n = c.toNumber();
        if (std.math.isNan(n) or @trunc(n) != n or n < 0 or n > 0x10FFFF)
            return self.throwError("RangeError", "Invalid code point");
        const cp: u21 = @intFromFloat(n);
        // A lone surrogate (0xD800–0xDFFF) is a valid fromCodePoint argument even
        // though it is not a valid UTF-8 scalar; encode it as WTF-8 (the generic
        // 3-byte form) rather than rejecting it the way std.unicode does.
        try appendCodePointWtf8(self.arena, &buf, cp);
    }
    return .{ .string = try buf.toOwnedSlice(self.arena) };
}

/// `String.raw(template, ...subs)` — reassemble a template literal from its
/// `raw` strings interleaved with the substitutions (ToString'd). Generic over
/// any array-like with a `raw` whose `length` and indices it reads via [[Get]].
pub fn stringRaw(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const cooked = arg(args, 0);
    if (cooked == .null or cooked == .undefined)
        return self.throwError("TypeError", "Cannot convert undefined or null to object");
    const raw = try self.getProperty(cooked, "raw");
    if (raw == .null or raw == .undefined)
        return self.throwError("TypeError", "Cannot convert undefined or null to object");
    const len_v = try self.toPrimitive(try self.getProperty(raw, "length"), .number);
    const segs = interpreter.toLen(len_v.toNumber());
    if (segs == 0) return .{ .string = "" };
    const subs: []const Value = if (args.len > 1) args[1..] else &.{};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
        try buf.appendSlice(self.arena, try (try self.getProperty(raw, key)).toString(self.arena));
        if (i + 1 == segs) break;
        if (i < subs.len) try buf.appendSlice(self.arena, try subs[i].toString(self.arena));
    }
    return .{ .string = try buf.toOwnedSlice(self.arena) };
}

// ---- JSON --------------------------------------------------------------

pub fn jsonStringify(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const a = self.arena;
    var st = Stringifier{ .self = self };

    // arg 1 — replacer: a callable (transform) or an array (property allowlist).
    const replacer = arg(args, 1);
    if (replacer == .object) {
        if (replacer.object.isCallableObject()) {
            st.replacer_fn = replacer;
        } else if (replacer.object.is_array) {
            var allow: std.ArrayListUnmanaged([]const u8) = .empty;
            for (replacer.object.elements.items) |item| {
                // Items are property keys: strings as-is, numbers ToString'd,
                // String/Number wrappers unwrapped; anything else is ignored.
                var k: ?[]const u8 = null;
                switch (item) {
                    .string => |s| k = s,
                    .number => |n| k = try value.numberToString(a, n),
                    .object => |o| if (o.prim) |p| switch (p) {
                        .string => |s| k = s,
                        .number => |n| k = try value.numberToString(a, n),
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
    // a Number/String wrapper is unwrapped first.
    var space = arg(args, 2);
    if (space == .object) if (space.object.prim) |p| {
        space = p;
    };
    switch (space) {
        .number => |n| {
            const cnt: usize = if (std.math.isNan(n) or n < 1) 0 else @intFromFloat(@min(@trunc(n), 10));
            const sp = try a.alloc(u8, cnt);
            @memset(sp, ' ');
            st.gap = sp;
        },
        .string => |s| st.gap = s[0..@min(s.len, 10)],
        else => {},
    }

    // Wrap the value in a holder { "": value } so toJSON/replacer apply to it.
    const holder = (try self.newObject()).object;
    try self.setMember(.{ .object = holder }, "", arg(args, 0));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (!try st.serialize(&buf, .{ .object = holder }, "")) return .undefined;
    return .{ .string = try buf.toOwnedSlice(a) };
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
        const a = self.arena;
        var v = try self.getProperty(holder, key);
        if (v == .object and !v.object.is_symbol) {
            const tj = try self.getProperty(v, "toJSON");
            if (tj == .object and tj.object.isCallableObject())
                v = try self.callValueWithThis(tj, &.{.{ .string = key }}, v);
        }
        if (st.replacer_fn) |rf|
            v = try self.callValueWithThis(rf, &.{ .{ .string = key }, v }, holder);
        if (v == .object) if (v.object.prim) |p| {
            v = p;
        };
        switch (v) {
            .undefined => return false,
            .null => try buf.appendSlice(a, "null"),
            .boolean => |b| try buf.appendSlice(a, if (b) "true" else "false"),
            .number => |n| try buf.appendSlice(a, if (std.math.isNan(n) or std.math.isInf(n)) "null" else try value.numberToString(a, n)),
            .string => |s| try writeJsonString(a, buf, s),
            .object => |o| {
                if (o.isCallableObject() or o.is_symbol) return false; // functions/symbols omitted
                for (st.stack.items) |s| if (s == o)
                    return self.throwError("TypeError", "Converting circular structure to JSON");
                try st.stack.append(a, o);
                defer _ = st.stack.pop();
                if (o.is_array) try st.serializeArray(buf, o) else try st.serializeObject(buf, .{ .object = o });
            },
        }
        return true;
    }

    fn serializeArray(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8), o: *value.Object) HostError!void {
        const a = st.self.arena;
        const len: usize = @max(o.elements.items.len, o.array_len);
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
            if (!try st.serialize(buf, .{ .object = o }, key)) try buf.appendSlice(a, "null");
        }
        st.indent.shrinkRetainingCapacity(outer);
        try st.newlineIndent(buf);
        try buf.append(a, ']');
    }

    fn serializeObject(st: *Stringifier, buf: *std.ArrayListUnmanaged(u8), v: Value) HostError!void {
        const self = st.self;
        const a = self.arena;
        const o = v.object;
        const keys = if (st.allow) |al| al else try o.enumerableKeys(a);
        const outer = st.indent.items.len;
        try st.indent.appendSlice(a, st.gap);
        var tmp: std.ArrayListUnmanaged(u8) = .empty;
        var count: usize = 0;
        for (keys) |k| {
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

fn writeJsonString(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) HostError!void {
    try buf.append(a, '"');
    for (s) |c| {
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
    }
    try buf.append(a, '"');
}

pub fn jsonParse(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    // ToString(text) — a value object's @@toPrimitive/toString/valueOf runs (and
    // a Symbol throws) before parsing.
    const text = try self.toStringV(arg(args, 0));
    var p = JsonParser{ .s = text, .i = 0, .interp = self };
    p.skipWs();
    const v = p.parseValue() catch return self.throwError("SyntaxError", "JSON.parse: invalid JSON");
    p.skipWs();
    if (p.i != text.len) return self.throwError("SyntaxError", "JSON.parse: trailing characters");

    // Optional reviver: walk the result bottom-up, replacing (or deleting, when
    // the reviver returns undefined) each property by the reviver's return.
    const reviver = arg(args, 1);
    if (reviver == .object and reviver.object.isCallableObject()) {
        const holder = (try self.newObject()).object;
        try self.setMember(.{ .object = holder }, "", v);
        return internalizeJson(self, .{ .object = holder }, "", reviver);
    }
    return v;
}

/// InternalizeJSONProperty: recursively apply `reviver` to `holder[key]` and its
/// nested elements/properties (children first), returning the reviver's result.
fn internalizeJson(self: *Interpreter, holder: Value, key: []const u8, reviver: Value) HostError!Value {
    const a = self.arena;
    const val = try self.getProperty(holder, key);
    if (val == .object and !val.object.isCallableObject()) {
        const o = val.object;
        if (o.is_array) {
            var i: usize = 0;
            // LengthOfArrayLike: Get(val, "length") — observable, and propagates a
            // throw if the reviver replaced `length` with a throwing accessor.
            const len = interpreter.toLen(try self.toNumberV(try self.getProperty(val, "length")));
            while (i < len) : (i += 1) {
                const k = try std.fmt.allocPrint(a, "{d}", .{i});
                const nv = try internalizeJson(self, val, k, reviver);
                try internalizeStore(self, o, val, k, nv);
            }
        } else {
            for (try ownEnumerableKeys(self, o)) |k| {
                const nv = try internalizeJson(self, val, k, reviver);
                try internalizeStore(self, o, val, k, nv);
            }
        }
    }
    return self.callValueWithThis(reviver, &.{ .{ .string = key }, val }, holder);
}

/// InternalizeJSONProperty's store step: `undefined` ⇒ DeletePropertyOrThrow,
/// else CreateDataProperty. On a Proxy these route through the deleteProperty /
/// defineProperty traps (so a throwing trap propagates); a plain object takes
/// the fast `setMember` path.
fn internalizeStore(self: *Interpreter, o: *value.Object, val: Value, key: []const u8, nv: Value) HostError!void {
    if (nv == .undefined) {
        const ok = try self.deleteOwn(o, key); // routes to the proxy deleteProperty trap
        if (!ok) return self.throwError("TypeError", "Cannot delete property");
        return;
    }
    if (o.proxy_handler != null or o.proxy_revoked) {
        // CreateDataProperty(o, key, nv) → the proxy defineProperty trap.
        const desc = (try self.newObject()).object;
        try desc.setOwn(self.arena, self.root_shape, "value", nv);
        try desc.setOwn(self.arena, self.root_shape, "writable", .{ .boolean = true });
        try desc.setOwn(self.arena, self.root_shape, "enumerable", .{ .boolean = true });
        try desc.setOwn(self.arena, self.root_shape, "configurable", .{ .boolean = true });
        try defineOne(self, o, key, desc);
        return;
    }
    try self.setMember(val, key, nv);
}

/// Explicit error set so the mutually-recursive parser methods don't form an
/// inferred-error-set dependency loop.
const JErr = error{Invalid} || HostError;

const JsonParser = struct {
    s: []const u8,
    i: usize,
    interp: *Interpreter,

    fn skipWs(p: *JsonParser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == '\n' or p.s[p.i] == '\r')) p.i += 1;
    }

    fn parseValue(p: *JsonParser) JErr!Value {
        p.skipWs();
        if (p.i >= p.s.len) return error.Invalid;
        const c = p.s[p.i];
        switch (c) {
            '{' => return p.parseObject(),
            '[' => return p.parseArray(),
            '"' => return .{ .string = try p.parseString() },
            't' => return p.parseLiteral("true", .{ .boolean = true }),
            'f' => return p.parseLiteral("false", .{ .boolean = false }),
            'n' => return p.parseLiteral("null", .null),
            else => return p.parseNumber(),
        }
    }

    fn parseLiteral(p: *JsonParser, lit: []const u8, v: Value) JErr!Value {
        if (p.i + lit.len > p.s.len or !std.mem.eql(u8, p.s[p.i .. p.i + lit.len], lit)) return error.Invalid;
        p.i += lit.len;
        return v;
    }

    fn parseNumber(p: *JsonParser) JErr!Value {
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
        return .{ .number = n };
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
                        // \uXXXX — emit the low byte (ASCII subset for v1).
                        if (p.i + 4 >= p.s.len) return error.Invalid;
                        const code = std.fmt.parseInt(u16, p.s[p.i + 1 .. p.i + 5], 16) catch return error.Invalid;
                        p.i += 4;
                        try buf.append(a, @intCast(code & 0xff));
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

    fn parseArray(p: *JsonParser) JErr!Value {
        p.i += 1; // [
        const result = try p.interp.newArray();
        p.skipWs();
        if (p.i < p.s.len and p.s[p.i] == ']') {
            p.i += 1;
            return result;
        }
        while (true) {
            const v = try p.parseValue();
            try result.object.elements.append(p.interp.arena, v);
            p.skipWs();
            if (p.i >= p.s.len) return error.Invalid;
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == ']') {
                p.i += 1;
                return result;
            }
            return error.Invalid;
        }
    }

    fn parseObject(p: *JsonParser) JErr!Value {
        p.i += 1; // {
        const result = try p.interp.newObject();
        p.skipWs();
        if (p.i < p.s.len and p.s[p.i] == '}') {
            p.i += 1;
            return result;
        }
        while (true) {
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != '"') return error.Invalid;
            const key = try p.parseString();
            p.skipWs();
            if (p.i >= p.s.len or p.s[p.i] != ':') return error.Invalid;
            p.i += 1;
            const v = try p.parseValue();
            try p.interp.setMember(result, key, v);
            p.skipWs();
            if (p.i >= p.s.len) return error.Invalid;
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == '}') {
                p.i += 1;
                return result;
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

/// Encode (24.5.2.1): ToString, then percent-escape every byte not in the
/// `unescaped` set. `component` excludes the reserved set (encodeURIComponent).
fn uriEncode(self: *Interpreter, v: Value, comptime component: bool) HostError!Value {
    const s = try self.toStringV(v);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        const keep = b < 0x80 and (std.mem.indexOfScalar(u8, uri_unreserved, b) != null or
            (!component and std.mem.indexOfScalar(u8, uri_reserved, b) != null));
        if (keep) {
            try buf.append(self.arena, b);
        } else {
            // A non-ASCII byte must be part of a well-formed UTF-8 sequence; a
            // lone/invalid byte is a URIError.
            if (b >= 0x80) {
                const n = std.unicode.utf8ByteSequenceLength(b) catch return self.throwError("URIError", "URI malformed");
                if (i + n > s.len) return self.throwError("URIError", "URI malformed");
                _ = std.unicode.utf8Decode(s[i .. i + n]) catch return self.throwError("URIError", "URI malformed");
                for (s[i .. i + n]) |bb| {
                    try buf.append(self.arena, '%');
                    try buf.append(self.arena, hexDigit(bb >> 4));
                    try buf.append(self.arena, hexDigit(bb & 0xF));
                }
                i += n - 1;
            } else {
                try buf.append(self.arena, '%');
                try buf.append(self.arena, hexDigit(b >> 4));
                try buf.append(self.arena, hexDigit(b & 0xF));
            }
        }
    }
    return .{ .string = try buf.toOwnedSlice(self.arena) };
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
            _ = std.unicode.utf8Decode(bytes[0..n]) catch return self.throwError("URIError", "URI malformed");
            try buf.appendSlice(self.arena, bytes[0..n]);
            i = j;
        }
    }
    return .{ .string = try buf.toOwnedSlice(self.arena) };
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
pub fn escapeFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const s = try self.toStringV(arg(args, 0));
    const keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80 and std.mem.indexOfScalar(u8, keep, @intCast(cp)) != null) {
            try buf.append(self.arena, @intCast(cp));
        } else if (cp < 0x100) {
            try buf.append(self.arena, '%');
            try buf.append(self.arena, hexDigit(@intCast(cp >> 4)));
            try buf.append(self.arena, hexDigit(@intCast(cp & 0xF)));
        } else {
            try buf.appendSlice(self.arena, "%u");
            try buf.append(self.arena, hexDigit(@intCast((cp >> 12) & 0xF)));
            try buf.append(self.arena, hexDigit(@intCast((cp >> 8) & 0xF)));
            try buf.append(self.arena, hexDigit(@intCast((cp >> 4) & 0xF)));
            try buf.append(self.arena, hexDigit(@intCast(cp & 0xF)));
        }
    }
    return .{ .string = try buf.toOwnedSlice(self.arena) };
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
    return .{ .string = try buf.toOwnedSlice(self.arena) };
}
