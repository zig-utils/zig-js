const std = @import("std");
const Shape = @import("shape.zig").Shape;

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

/// Error set a native builtin may return (mirrors the interpreter's EvalError;
/// error values are global by name, so they coerce). `OptShortCircuit` is an
/// internal control-flow signal natives never actually produce, included only
/// so the sets unify.
pub const HostError = error{ OutOfMemory, Throw, OptShortCircuit };

/// A Zig-native function exposed to JS. Unlike `HostCallback` (the C-ABI JSC
/// shape used across the FFI boundary), this is the in-process hook the
/// interpreter calls directly: `ctx` is the `*Interpreter` (type-erased to
/// avoid an import cycle; cast it back), `this` is the receiver, and the native
/// may allocate via the interpreter's arena and raise JS exceptions. Used for
/// engine builtins and the conformance harness's `assert`.
pub const NativeFn = *const fn (ctx: *anyopaque, this: Value, args: []const Value) HostError!Value;

/// A JavaScript object. v1 keeps this deliberately small: a string-keyed
/// property map, an optional dense array part, and three flavors of callable:
/// a JS-defined function (`js_func`, type-erased `*Function` to avoid an
/// import cycle with the interpreter), a Zig-native builtin (`native`), and a
/// C-ABI host callback (`callback`). Everything is allocated in the owning
/// Context's arena, so there is no per-object teardown yet.
pub const Object = struct {
    /// Named properties live behind a shared `Shape` (null = no own properties)
    /// plus a flat per-object `slots` array indexed by the shape. See shape.zig.
    shape: ?*Shape = null,
    slots: std.ArrayListUnmanaged(Value) = .empty,
    /// Prototype link ([[Prototype]]): property lookup walks this chain. An
    /// instance's proto is its constructor's `.prototype`; a class's `.prototype`
    /// protos to its superclass's `.prototype`.
    proto: ?*Object = null,
    /// Accessor (get/set) properties, lazily allocated. Checked before the data
    /// slot at each level of the prototype walk.
    accessors: ?*std.StringHashMapUnmanaged(Accessor) = null,
    elements: std.ArrayListUnmanaged(Value) = .empty,
    /// Per-property attribute overrides, lazily allocated. Absent name = the
    /// all-true default (a plain-assignment property). See `PropAttr`.
    attrs: ?*std.StringHashMapUnmanaged(PropAttr) = null,
    /// When false (set by `Object.preventExtensions`/`seal`/`freeze`), new own
    /// properties can't be added.
    extensible: bool = true,
    /// A Symbol (a tagged object so identity `===` and storage reuse the object
    /// machinery; `typeof` reports "symbol"). `sym_key` is its unique property-key
    /// encoding (used when a symbol is an object property key).
    is_symbol: bool = false,
    sym_key: []const u8 = "",
    /// A `Date` instance — its time (ms since the Unix epoch) is the own `__t`
    /// property; methods are dispatched in `dateMethod`.
    is_date: bool = false,
    is_array: bool = false,
    /// For arrays, a *logical* length floor used when it exceeds the physically
    /// stored `elements` — so `new Array(4294967295)` / `arr.length = big` track a
    /// length without materializing (and OOM-ing on) that many holes. The array's
    /// observable length is `max(elements.items.len, array_len)`.
    array_len: usize = 0,
    callback: ?HostCallback = null,
    native: ?NativeFn = null,
    /// For a `native` function, whether it implements [[Construct]] — i.e. is
    /// `new`-able. Most built-ins are *not* constructors (methods, `Math.*`,
    /// `parseInt`, `Symbol`, …); only the handful that the spec defines as
    /// constructors (`Array`, `Object`, `Map`, `RegExp`, …) set this, so
    /// `new Object.keys()` / `new Symbol()` throw a TypeError as required.
    native_ctor: bool = false,
    /// `*Interpreter.Function`, type-erased to break the value↔interpreter
    /// import cycle. The interpreter casts it back when calling.
    js_func: ?*anyopaque = null,
    /// `*vm.Generator`, type-erased (same cycle break as `js_func`). Non-null
    /// marks a generator *object* — the iterator returned by calling a
    /// `function*`; its `.next()`/`.return()`/`.throw()` drive the suspendable VM.
    gen: ?*anyopaque = null,
    /// `*Interpreter.BoundFn`, type-erased. Non-null marks a bound function
    /// (`fn.bind(this, ...args)`): calling it invokes the target with the bound
    /// `this` and the bound args prepended.
    bound: ?*anyopaque = null,
    /// Opaque `data` pointer carried for `JSObjectMake(ctx, class, data)` and
    /// surfaced to host callbacks via private-data accessors later.
    private_data: ?*anyopaque = null,
    /// True for `Error`-family instances; drives `toString` and `instanceof`.
    is_error: bool = false,
    /// True for `RegExp` instances (carries `source`/`flags` properties; matching
    /// is backed by zig-regex).
    is_regex: bool = false,
    /// `Map`/`Set` instances. A Map keeps `[key,value]` pair-arrays in
    /// `elements`; a Set keeps values directly. `size` is a maintained property.
    is_map: bool = false,
    is_set: bool = false,
    /// For error instances, the error class name (e.g. "TypeError"); for a
    /// builtin error *constructor* object, see `error_ctor`.
    error_name: []const u8 = "",
    /// Non-null marks this object as a builtin error constructor; the value is
    /// the class name it produces ("Error", "TypeError", ...). Callable both
    /// plainly (`TypeError("x")`) and via `new`.
    error_ctor: ?[]const u8 = null,
    /// For objects created by `new F()`, the constructor function's object —
    /// used by `instanceof` to walk the (flat, v1) construction link.
    ctor_ref: ?*Object = null,
    /// A primitive-wrapper object's boxed [[NumberData]]/[[StringData]]/
    /// [[BooleanData]] — set by `new Number(x)` / `new String(x)` / `new
    /// Boolean(x)`. Non-null marks the object as a wrapper: `typeof` is still
    /// "object", but `valueOf`/ToPrimitive unwrap it and `Object.prototype.
    /// toString` reports `[object Number|String|Boolean]`.
    prim: ?Value = null,

    pub fn isCallableObject(self: *const Object) bool {
        return self.callback != null or self.native != null or
            self.js_func != null or self.error_ctor != null or self.bound != null;
    }

    /// Own named property keys in insertion order (for `for-in` / enumeration).
    pub fn ownKeys(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        var s = self.shape;
        while (s) |sh| {
            if (sh.name) |n| try list.append(arena, n);
            s = sh.parent;
        }
        std.mem.reverse([]const u8, list.items); // chain is newest-first → insertion order
        return list.items;
    }

    /// The attributes of own property `name` (all-true default if no override).
    pub fn getAttr(self: *const Object, name: []const u8) PropAttr {
        if (self.attrs) |m| {
            if (m.get(name)) |a| return a;
        }
        return .{};
    }

    /// Record an attribute override for `name`.
    pub fn setAttr(self: *Object, arena: std.mem.Allocator, name: []const u8, a: PropAttr) std.mem.Allocator.Error!void {
        if (self.attrs == null) {
            self.attrs = try arena.create(std.StringHashMapUnmanaged(PropAttr));
            self.attrs.?.* = .{};
        }
        const gop = try self.attrs.?.getOrPut(arena, name);
        if (!gop.found_existing) gop.key_ptr.* = try arena.dupe(u8, name);
        gop.value_ptr.* = a;
    }

    /// Own named data + accessor keys whose [[Enumerable]] is true, in insertion
    /// order (for `Object.keys`/`values`/`entries`, `for-in`, JSON).
    pub fn enumerableKeys(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (try self.ownKeys(arena)) |k| {
            if (isSymbolKey(k)) continue; // symbol-keyed props are never string-enumerable
            if (self.getAttr(k).enumerable) try list.append(arena, k);
        }
        return list.items;
    }

    /// An own accessor (get/set) property, if present.
    pub fn getAccessor(self: *const Object, name: []const u8) ?Accessor {
        const m = self.accessors orelse return null;
        return m.get(name);
    }

    /// Define/merge an own accessor (get and/or set). Promotes the name to an
    /// accessor property.
    pub fn setAccessor(self: *Object, arena: std.mem.Allocator, name: []const u8, get: ?Value, set: ?Value) std.mem.Allocator.Error!void {
        if (self.accessors == null) {
            self.accessors = try arena.create(std.StringHashMapUnmanaged(Accessor));
            self.accessors.?.* = .{};
        }
        const gop = try self.accessors.?.getOrPut(arena, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try arena.dupe(u8, name);
            gop.value_ptr.* = .{};
        }
        if (get) |g| gop.value_ptr.get = g;
        if (set) |s| gop.value_ptr.set = s;
    }

    /// Read an own named property, or null if absent. No allocation.
    pub fn getOwn(self: *const Object, name: []const u8) ?Value {
        const sh = self.shape orelse return null;
        // `lookup` doesn't mutate; the const-cast keeps Object read-only here.
        const slot = (@constCast(sh)).lookup(name) orelse return null;
        return self.slots.items[slot];
    }

    /// Set an own named property, transitioning the shape and growing `slots`
    /// when the name is new. `root` is the Context's empty shape; `arena` backs
    /// the slot storage and shape tree.
    pub fn setOwn(self: *Object, arena: std.mem.Allocator, root: *Shape, name: []const u8, v: Value) std.mem.Allocator.Error!void {
        if (self.shape) |sh| {
            if (sh.lookup(name)) |slot| {
                self.slots.items[slot] = v;
                return;
            }
        }
        const base = self.shape orelse root;
        const child = try base.transition(name);
        try self.slots.append(arena, v); // new slot index == base.count == child.slot
        self.shape = child;
    }
};

/// An accessor property: getter and/or setter functions.
pub const Accessor = struct { get: ?Value = null, set: ?Value = null };

/// A symbol's internal property-key encoding is a NUL-led string, which can't
/// be produced by user code — so symbol-keyed properties never collide with
/// string keys and are excluded from string enumeration.
pub fn isSymbolKey(k: []const u8) bool {
    return k.len > 0 and k[0] == 0;
}

/// A property's [[Writable]]/[[Enumerable]]/[[Configurable]] attributes. The
/// default (all true) matches a property created by plain assignment, so only
/// `Object.defineProperty`/`freeze`/etc. allocate an override entry.
pub const PropAttr = struct {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
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
            .object => |o| o.isCallableObject(),
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

    /// ECMAScript ToInt32 — used by the bitwise/shift operators. NaN/±Inf → 0,
    /// otherwise truncate toward zero and reduce modulo 2^32 into a signed int.
    pub fn toInt32(self: Value) i32 {
        const n = self.toNumber();
        if (std.math.isNan(n) or std.math.isInf(n)) return 0;
        const t = @trunc(n);
        const m = t - @floor(t / 4294967296.0) * 4294967296.0; // t mod 2^32, in [0, 2^32)
        return @bitCast(@as(u32, @intFromFloat(m)));
    }

    /// ECMAScript ToUint32 (the same bit pattern, read unsigned).
    pub fn toUint32(self: Value) u32 {
        return @bitCast(self.toInt32());
    }

    /// The `typeof` operator result.
    pub fn typeOf(self: Value) []const u8 {
        return switch (self) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => |o| if (o.is_symbol) "symbol" else if (o.isCallableObject()) "function" else "object",
        };
    }

    /// ECMAScript ToString, allocating in `arena`.
    pub fn toString(self: Value, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return switch (self) {
            .undefined => "undefined",
            .null => "null",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| try numberToString(arena, n),
            .string => |s| s,
            .object => |o| try objectToString(o, arena),
        };
    }
};

/// ECMAScript-ish ToString for objects: errors render `Name: message`, arrays
/// join their elements with commas (Array.prototype.toString), everything else
/// is `[object Object]`.
fn objectToString(o: *Object, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    // A primitive-wrapper object stringifies as its boxed primitive.
    if (o.prim) |p| return p.toString(arena);
    if (o.is_error) {
        const name = if (o.getOwn("name")) |v|
            (if (v == .string) v.string else o.error_name)
        else
            o.error_name;
        const msg = if (o.getOwn("message")) |v|
            (if (v == .string) v.string else "")
        else
            "";
        if (msg.len == 0) return name;
        return std.mem.concat(arena, u8, &.{ name, ": ", msg });
    }
    if (o.is_array) {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (o.elements.items, 0..) |el, i| {
            if (i != 0) try buf.append(arena, ',');
            // null/undefined render as empty per Array.prototype.join.
            const part = switch (el) {
                .undefined, .null => "",
                else => try el.toString(arena),
            };
            try buf.appendSlice(arena, part);
        }
        return buf.toOwnedSlice(arena);
    }
    return "[object Object]";
}

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
