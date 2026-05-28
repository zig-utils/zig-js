//! Native (Zig) implementations of common JS global functions and the `Math`,
//! `Object`, and `Array` namespace methods. Each is a `value.NativeFn`: the
//! first argument is the `*Interpreter` (type-erased), so a builtin can allocate
//! via its arena and raise JS exceptions. Registered in `interpreter.installGlobals`.

const std = @import("std");
const value = @import("value.zig");
const Interpreter = @import("interpreter.zig").Interpreter;

const Value = value.Value;
const HostError = value.HostError;

fn interp(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

// ---- global functions --------------------------------------------------

pub fn isNaNFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .boolean = std.math.isNan(arg(args, 0).toNumber()) };
}

pub fn isFiniteFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const n = arg(args, 0).toNumber();
    return .{ .boolean = !std.math.isNan(n) and !std.math.isInf(n) };
}

pub fn stringFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    if (args.len == 0) return .{ .string = "" };
    return .{ .string = try args[0].toString(interp(ctx).arena) };
}

pub fn numberFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    if (args.len == 0) return .{ .number = 0 };
    return .{ .number = args[0].toNumber() };
}

pub fn booleanFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .boolean = arg(args, 0).toBoolean() };
}

pub fn parseFloatFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    const s = try arg(args, 0).toString(interp(ctx).arena);
    _ = this;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    // Longest leading prefix that parses as a float.
    var end: usize = trimmed.len;
    while (end > 0) : (end -= 1) {
        if (std.fmt.parseFloat(f64, trimmed[0..end])) |n| {
            return .{ .number = n };
        } else |_| {}
    }
    return .{ .number = std.math.nan(f64) };
}

pub fn parseIntFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const s = try arg(args, 0).toString(interp(ctx).arena);
    var radix: u8 = 10;
    if (args.len >= 2) {
        const r = arg(args, 1).toNumber();
        if (!std.math.isNan(r) and r >= 2 and r <= 36) radix = @intFromFloat(r);
    }
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
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
    if (std.math.isNan(n) or std.math.isInf(n)) return .{ .number = n };
    return .{ .number = @floor(n + 0.5) }; // JS rounds halves toward +Infinity
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
    _ = ctx;
    _ = this;
    return .{ .number = std.math.pow(f64, num1(args), arg(args, 1).toNumber()) };
}
pub fn mathMax(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    var m: f64 = -std.math.inf(f64);
    for (args) |v| {
        const n = v.toNumber();
        if (std.math.isNan(n)) return .{ .number = n };
        if (n > m) m = n;
    }
    return .{ .number = m };
}
pub fn mathMin(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    var m: f64 = std.math.inf(f64);
    for (args) |v| {
        const n = v.toNumber();
        if (std.math.isNan(n)) return .{ .number = n };
        if (n < m) m = n;
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
};

pub fn mathAtan2(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    return .{ .number = std.math.atan2(arg(args, 0).toNumber(), arg(args, 1).toNumber()) };
}

pub fn mathHypot(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    var sum: f64 = 0;
    for (args) |v| {
        const n = v.toNumber();
        sum += n * n;
    }
    return .{ .number = @sqrt(sum) };
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

pub fn objectKeys(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const keys = try arg(args, 0).object.enumerableKeys(self.arena);
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
        const keys = try o.enumerableKeys(self.arena);
        for (keys) |k| try result.object.elements.append(self.arena, o.getOwn(k) orelse .undefined);
    }
    return result;
}

pub fn objectAssign(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (target != .object) return target;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (args[i] != .object) continue;
        const src = args[i].object;
        const keys = try src.enumerableKeys(self.arena);
        for (keys) |k| try self.setMember(target, k, src.getOwn(k) orelse .undefined);
    }
    return target;
}

pub fn objectEntries(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        const keys = try o.enumerableKeys(self.arena);
        for (keys) |k| {
            const pair = try self.newArray();
            try pair.object.elements.append(self.arena, .{ .string = k });
            try pair.object.elements.append(self.arena, o.getOwn(k) orelse .undefined);
            try result.object.elements.append(self.arena, pair);
        }
    }
    return result;
}

pub fn objectFromEntries(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newObject();
    if (arg(args, 0) == .object and arg(args, 0).object.is_array) {
        for (arg(args, 0).object.elements.items) |entry| {
            if (entry != .object or !entry.object.is_array) continue;
            const items = entry.object.elements.items;
            const k = if (items.len > 0) try items[0].toString(self.arena) else "";
            const v = if (items.len > 1) items[1] else .undefined;
            try self.setMember(result, k, v);
        }
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
        var i: usize = 0;
        const len: usize = @intFromFloat(n);
        while (i < len) : (i += 1) try arr.object.elements.append(self.arena, .undefined);
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
    return self.newObject(); // primitives → a fresh object (boxing is approximate in v1)
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
    return interp(ctx).makeMap(arg(args, 0));
}

pub fn setFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    return interp(ctx).makeSet(arg(args, 0));
}

/// `RegExp(pattern, flags)` / `new RegExp(...)`. Accepts a string source or an
/// existing RegExp (copying its source).
pub fn regExpFn(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const a0 = arg(args, 0);
    var pattern: []const u8 = "";
    if (a0 == .object and a0.object.is_regex) {
        pattern = (a0.object.getOwn("source") orelse Value{ .string = "" }).string;
    } else if (a0 != .undefined) {
        pattern = try a0.toString(self.arena);
    }
    const flags = if (arg(args, 1) != .undefined) try arg(args, 1).toString(self.arena) else "";
    return self.makeRegex(pattern, flags);
}

pub fn objectGetPrototypeOf(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    if (arg(args, 0) == .object) {
        if (arg(args, 0).object.proto) |p| return .{ .object = p };
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
    return .{ .object = obj };
}

pub fn objectDefineProperty(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (target != .object) return self.throwError("TypeError", "Object.defineProperty called on non-object");
    const key = try arg(args, 1).toString(self.arena);
    const desc = arg(args, 2);
    if (desc != .object) return self.throwError("TypeError", "Property description must be an object");
    try defineOne(self, target.object, key, desc.object);
    return target;
}

/// Core of `Object.defineProperty` / `defineProperties`: apply descriptor `d` to
/// `target[key]`, honoring attributes and bypassing [[Set]].
fn defineOne(self: *Interpreter, target: *value.Object, key: []const u8, d: *value.Object) HostError!void {
    const get = d.getOwn("get");
    const set = d.getOwn("set");
    // Redefining keeps the current attributes for any omitted field; a new
    // property defaults omitted fields to false.
    const exists = target.getOwn(key) != null or target.getAccessor(key) != null;
    var attr: value.PropAttr = if (exists) target.getAttr(key) else .{ .writable = false, .enumerable = false, .configurable = false };
    if (d.getOwn("enumerable")) |e| attr.enumerable = e.toBoolean();
    if (d.getOwn("configurable")) |c| attr.configurable = c.toBoolean();
    if (get != null or set != null) {
        try target.setAccessor(self.arena, key, get, set);
    } else {
        if (d.getOwn("writable")) |w| attr.writable = w.toBoolean();
        try target.setOwn(self.arena, self.root_shape, key, d.getOwn("value") orelse .undefined);
    }
    try target.setAttr(self.arena, key, attr);
}

pub fn objectDefineProperties(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (target != .object) return self.throwError("TypeError", "Object.defineProperties called on non-object");
    const props = arg(args, 1);
    if (props == .object) {
        for (try props.object.enumerableKeys(self.arena)) |k| {
            const d = props.object.getOwn(k) orelse continue;
            if (d != .object) return self.throwError("TypeError", "Property description must be an object");
            try defineOne(self, target.object, k, d.object);
        }
    }
    return target;
}

pub fn objectPreventExtensions(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const o = arg(args, 0);
    if (o == .object) o.object.extensible = false;
    return o;
}

pub fn objectIsExtensible(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = ctx;
    _ = this;
    const o = arg(args, 0);
    return .{ .boolean = o == .object and o.object.extensible };
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
    if (o.is_array and o.elements.items.len > 0) return false;
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
    _ = ctx;
    _ = this;
    const o = arg(args, 0);
    if (o == .object) {
        const p = arg(args, 1);
        o.object.proto = if (p == .object) p.object else null;
    }
    return o;
}

pub fn objectGetOwnPropertySymbols(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    _ = args;
    return interp(ctx).newArray(); // no Symbol type yet → always empty
}

pub fn objectGetOwnPropertyDescriptors(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newObject();
    if (arg(args, 0) == .object) {
        const o = arg(args, 0).object;
        for (try o.ownKeys(self.arena)) |k| {
            const d = try objectGetOwnPropertyDescriptor(ctx, .undefined, &.{ arg(args, 0), .{ .string = k } });
            try self.setMember(result, k, d);
        }
    }
    return result;
}

pub fn objectGetOwnPropertyDescriptor(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const ov = arg(args, 0);
    if (ov != .object) return .undefined;
    const o = ov.object;
    const key = try arg(args, 1).toString(self.arena);

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
        if (std.mem.eql(u8, key, "length"))
            return dataDescriptor(self, .{ .number = @floatFromInt(o.elements.items.len) }, .{ .writable = true, .enumerable = false, .configurable = false });
        if (arrayIndexOf(key)) |i| {
            if (i < o.elements.items.len)
                return dataDescriptor(self, o.elements.items[i], .{ .writable = true, .enumerable = true, .configurable = true });
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
        if (o.is_array) {
            var i: usize = 0;
            while (i < o.elements.items.len) : (i += 1) {
                try result.object.elements.append(self.arena, .{ .string = try std.fmt.allocPrint(self.arena, "{d}", .{i}) });
            }
        }
        const keys = try o.ownKeys(self.arena);
        for (keys) |k| {
            if (value.isSymbolKey(k)) continue; // symbol keys are excluded from getOwnPropertyNames
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

// ---- JSON --------------------------------------------------------------

pub fn jsonStringify(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const present = try stringifyValue(self, &buf, arg(args, 0));
    if (!present) return .undefined;
    return .{ .string = try buf.toOwnedSlice(self.arena) };
}

/// Serialize `v` into `buf`. Returns false when the value is omitted
/// (undefined / function), per `JSON.stringify`.
fn stringifyValue(self: *Interpreter, buf: *std.ArrayListUnmanaged(u8), v: Value) HostError!bool {
    const a = self.arena;
    switch (v) {
        .undefined => return false,
        .null => {
            try buf.appendSlice(a, "null");
            return true;
        },
        .boolean => |b| {
            try buf.appendSlice(a, if (b) "true" else "false");
            return true;
        },
        .number => |n| {
            if (std.math.isNan(n) or std.math.isInf(n)) {
                try buf.appendSlice(a, "null");
            } else {
                try buf.appendSlice(a, try value.numberToString(a, n));
            }
            return true;
        },
        .string => |s| {
            try writeJsonString(a, buf, s);
            return true;
        },
        .object => |o| {
            if (o.isCallableObject()) return false;
            if (o.is_array) {
                try buf.append(a, '[');
                for (o.elements.items, 0..) |el, i| {
                    if (i != 0) try buf.append(a, ',');
                    if (!try stringifyValue(self, buf, el)) try buf.appendSlice(a, "null");
                }
                try buf.append(a, ']');
            } else {
                try buf.append(a, '{');
                const keys = try o.enumerableKeys(a); // JSON serializes only enumerable own props
                var first = true;
                for (keys) |k| {
                    const pv = try self.getProperty(v, k);
                    // Probe whether the property is omitted before writing the key.
                    var tmp: std.ArrayListUnmanaged(u8) = .empty;
                    if (!try stringifyValue(self, &tmp, pv)) continue;
                    if (!first) try buf.append(a, ',');
                    first = false;
                    try writeJsonString(a, buf, k);
                    try buf.append(a, ':');
                    try buf.appendSlice(a, tmp.items);
                }
                try buf.append(a, '}');
            }
            return true;
        },
    }
}

fn writeJsonString(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) HostError!void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\t' => try buf.appendSlice(a, "\\t"),
            '\r' => try buf.appendSlice(a, "\\r"),
            else => try buf.append(a, c),
        }
    }
    try buf.append(a, '"');
}

pub fn jsonParse(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const text = try arg(args, 0).toString(self.arena);
    var p = JsonParser{ .s = text, .i = 0, .interp = self };
    p.skipWs();
    const v = p.parseValue() catch return self.throwError("SyntaxError", "JSON.parse: invalid JSON");
    p.skipWs();
    if (p.i != text.len) return self.throwError("SyntaxError", "JSON.parse: trailing characters");
    return v;
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
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                '0'...'9', '-', '+', '.', 'e', 'E' => {},
                else => break,
            }
        }
        if (p.i == start) return error.Invalid;
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
                    else => e,
                });
                p.i += 1;
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
