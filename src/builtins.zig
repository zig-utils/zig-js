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

// ---- Object / Array ----------------------------------------------------

pub fn objectKeys(ctx: *anyopaque, this: Value, args: []const Value) HostError!Value {
    _ = this;
    const self = interp(ctx);
    const result = try self.newArray();
    if (arg(args, 0) == .object) {
        const keys = try arg(args, 0).object.ownKeys(self.arena);
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
        const keys = try o.ownKeys(self.arena);
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
        const keys = try src.ownKeys(self.arena);
        for (keys) |k| try self.setMember(target, k, src.getOwn(k) orelse .undefined);
    }
    return target;
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
