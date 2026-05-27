const std = @import("std");

/// The C-ABI shape of a host (Zig/C) function exposed to JS via
/// `JSObjectMakeFunctionWithCallback`. Kept here so both the interpreter and
/// the C-API layer agree on the type. All ref args are word-sized opaque
/// pointers (JSValueRef / JSObjectRef / JSContextRef in JSC terms).
pub const HostCallback = *const fn (
    ctx: ?*anyopaque,
    function: ?*anyopaque,
    this_object: ?*anyopaque,
    argument_count: usize,
    arguments: [*c]const ?*anyopaque,
    exception: [*c]?*anyopaque,
) callconv(.c) ?*anyopaque;

/// A Zig-native function exposed to JS. Unlike `HostCallback` (the C-ABI JSC
/// shape used across the FFI boundary), this is the in-process hook the
/// interpreter can call directly with `Value` args — used for engine builtins
/// and the conformance harness's `assert`.
pub const NativeFn = *const fn (args: []const Value) Value;

/// A JavaScript object. v1 keeps this deliberately small: a string-keyed
/// property map, an optional dense array part, and three flavors of callable:
/// a JS-defined function (`js_func`, type-erased `*Function` to avoid an
/// import cycle with the interpreter), a Zig-native builtin (`native`), and a
/// C-ABI host callback (`callback`). Everything is allocated in the owning
/// Context's arena, so there is no per-object teardown yet.
pub const Object = struct {
    properties: std.StringHashMapUnmanaged(Value) = .{},
    elements: std.ArrayListUnmanaged(Value) = .empty,
    is_array: bool = false,
    callback: ?HostCallback = null,
    native: ?NativeFn = null,
    /// `*Interpreter.Function`, type-erased to break the value↔interpreter
    /// import cycle. The interpreter casts it back when calling.
    js_func: ?*anyopaque = null,
    /// Opaque `data` pointer carried for `JSObjectMake(ctx, class, data)` and
    /// surfaced to host callbacks via private-data accessors later.
    private_data: ?*anyopaque = null,

    pub fn isCallableObject(self: *const Object) bool {
        return self.callback != null or self.native != null or self.js_func != null;
    }
};

/// A JavaScript value. Strings and objects point into the Context arena.
pub const Value = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    object: *Object,

    pub fn isCallable(self: Value) bool {
        return switch (self) {
            .object => |o| o.callback != null or o.native != null or o.js_func != null,
            else => false,
        };
    }

    /// ECMAScript ToBoolean.
    pub fn toBoolean(self: Value) bool {
        return switch (self) {
            .undefined, .null => false,
            .boolean => |b| b,
            .number => |n| n != 0 and !std.math.isNan(n),
            .string => |s| s.len != 0,
            .object => true,
        };
    }

    /// ECMAScript ToNumber (subset: objects coerce to NaN for now).
    pub fn toNumber(self: Value) f64 {
        return switch (self) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .string => |s| stringToNumber(s),
            .object => std.math.nan(f64),
        };
    }

    /// The `typeof` operator result.
    pub fn typeOf(self: Value) []const u8 {
        return switch (self) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => |o| if (o.isCallableObject()) "function" else "object",
        };
    }

    /// ECMAScript ToString, allocating in `arena`.
    pub fn toString(self: Value, arena: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| try numberToString(arena, n),
            .string => |s| s,
            .object => |o| if (o.is_array) "[object Array]" else "[object Object]",
        };
    }
};

/// ECMAScript ToString for numbers (best-effort; full Number::toString comes
/// with the test262 number slice). Integer-valued numbers print without a
/// trailing ".0" to match JS.
pub fn numberToString(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n < 0) "-Infinity" else "Infinity";
    if (n == 0) return "0";
    if (@floor(n) == n and @abs(n) < 9.007199254740992e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// Parse a string to a number per a simplified ToNumber(string): trims ASCII
/// whitespace, empty string is 0, otherwise float parse or NaN.
pub fn stringToNumber(s: []const u8) f64 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

/// Strict equality (===).
pub fn strictEquals(a: Value, b: Value) bool {
    return switch (a) {
        .undefined => b == .undefined,
        .null => b == .null,
        .boolean => |x| b == .boolean and b.boolean == x,
        .number => |x| b == .number and b.number == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .object => |x| b == .object and b.object == x,
    };
}

/// Abstract Equality Comparison (==), simplified for the v1 value set.
pub fn looseEquals(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) == @as(std.meta.Tag(Value), b)) {
        return strictEquals(a, b);
    }
    if ((a == .null and b == .undefined) or (a == .undefined and b == .null)) return true;
    switch (a) {
        .number, .string, .boolean => switch (b) {
            .number, .string, .boolean => return a.toNumber() == b.toNumber(),
            else => {},
        },
        else => {},
    }
    return false;
}
