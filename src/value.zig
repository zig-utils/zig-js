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

/// The element type of a typed array (no BigInt variants — those need a BigInt
/// value type). Each carries its byte width and how to read/write a value.
pub const TAKind = enum {
    i8,
    u8,
    u8c, // Uint8ClampedArray
    i16,
    u16,
    i32,
    u32,
    f16,
    f32,
    f64,
    i64, // BigInt64Array  (elements are BigInt)
    u64, // BigUint64Array (elements are BigInt)

    pub fn byteSize(self: TAKind) usize {
        return switch (self) {
            .i8, .u8, .u8c => 1,
            .i16, .u16, .f16 => 2,
            .i32, .u32, .f32 => 4,
            .f64, .i64, .u64 => 8,
        };
    }

    /// The constructor/`Symbol.toStringTag` name (`"Int8Array"`, …).
    pub fn ctorName(self: TAKind) []const u8 {
        return switch (self) {
            .i8 => "Int8Array",
            .u8 => "Uint8Array",
            .u8c => "Uint8ClampedArray",
            .i16 => "Int16Array",
            .u16 => "Uint16Array",
            .i32 => "Int32Array",
            .u32 => "Uint32Array",
            .f16 => "Float16Array",
            .f32 => "Float32Array",
            .f64 => "Float64Array",
            .i64 => "BigInt64Array",
            .u64 => "BigUint64Array",
        };
    }

    /// Whether the element type is BigInt (BigInt64Array / BigUint64Array): such
    /// arrays read/write BigInt values rather than Numbers.
    pub fn isBigInt(self: TAKind) bool {
        return self == .i64 or self == .u64;
    }

    pub fn fromName(name: []const u8) ?TAKind {
        inline for (.{ .i8, .u8, .u8c, .i16, .u16, .i32, .u32, .f16, .f32, .f64, .i64, .u64 }) |k| {
            if (std.mem.eql(u8, name, (@as(TAKind, k)).ctorName())) return k;
        }
        return null;
    }
};

/// An `ArrayBuffer`'s backing bytes. `detached` is set by `$262.detachArrayBuffer`
/// / transfer; a detached buffer's views read undefined / throw on length checks.
pub const ArrayBufferData = struct {
    data: []u8,
    detached: bool = false,
    /// For a resizable ArrayBuffer (or growable SharedArrayBuffer), the maximum
    /// byte length; null means fixed-length (not resizable/growable).
    max_byte_length: ?usize = null,
    /// A SharedArrayBuffer (never detaches; `grow` only increases length).
    is_shared: bool = false,
    /// An immutable ArrayBuffer (from `transferToImmutable`/`sliceToImmutable`):
    /// fixed-length, never detaches, and rejects every write.
    immutable: bool = false,
};

/// Read typed-array element `i` (within bounds, buffer attached) as a Number.
pub fn taRead(ta: *const TypedArrayData, i: usize) Value {
    const bytes = ta.buffer.array_buffer.?.data;
    const off = ta.byte_offset + i * ta.kind.byteSize();
    // A resizable buffer may have shrunk below the view's cached length; reading
    // out of bounds returns 0 rather than a panic.
    if (off + ta.kind.byteSize() > bytes.len) return .{ .number = 0 };
    const n: f64 = switch (ta.kind) {
        .i8 => @floatFromInt(@as(i8, @bitCast(bytes[off]))),
        .u8, .u8c => @floatFromInt(bytes[off]),
        .i16 => @floatFromInt(std.mem.readInt(i16, bytes[off..][0..2], .little)),
        .u16 => @floatFromInt(std.mem.readInt(u16, bytes[off..][0..2], .little)),
        .i32 => @floatFromInt(std.mem.readInt(i32, bytes[off..][0..4], .little)),
        .u32 => @floatFromInt(std.mem.readInt(u32, bytes[off..][0..4], .little)),
        .f16 => @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, bytes[off..][0..2], .little)))),
        .f32 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[off..][0..4], .little)))),
        .f64 => @bitCast(std.mem.readInt(u64, bytes[off..][0..8], .little)),
        // A BigInt element read as a Number is lossy, but keeps the Number-typed
        // method paths crash-free; the interpreter's index get uses `taReadBig`.
        .i64 => @floatFromInt(std.mem.readInt(i64, bytes[off..][0..8], .little)),
        .u64 => @floatFromInt(std.mem.readInt(u64, bytes[off..][0..8], .little)),
    };
    return .{ .number = n };
}

/// Read a BigInt typed-array element `i` as an `i128` (the raw 64-bit value,
/// sign-extended for BigInt64Array).
pub fn taReadBig(ta: *const TypedArrayData, i: usize) i128 {
    const bytes = ta.buffer.array_buffer.?.data;
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + 8 > bytes.len) return 0;
    return switch (ta.kind) {
        .i64 => std.mem.readInt(i64, bytes[off..][0..8], .little),
        .u64 => @as(i128, std.mem.readInt(u64, bytes[off..][0..8], .little)),
        else => 0,
    };
}

/// Write a BigInt typed-array element `i` from an `i128` (the low 64 bits).
pub fn taWriteBig(ta: *const TypedArrayData, i: usize, val: i128) void {
    const bytes = ta.buffer.array_buffer.?.data;
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + 8 > bytes.len) return;
    const low: u64 = @truncate(@as(u128, @bitCast(val)));
    std.mem.writeInt(u64, bytes[off..][0..8], low, .little);
}

/// ToInt of `num` truncated to a wrapping integer width (NaN/±Inf → 0).
fn taToInt(comptime T: type, num: f64) T {
    if (std.math.isNan(num) or std.math.isInf(num)) return 0;
    const bits = @bitSizeOf(T);
    const two_pow: f64 = std.math.pow(f64, 2, @floatFromInt(bits));
    var m = @mod(@trunc(num), two_pow); // wrap into [0, 2^bits)
    if (m < 0) m += two_pow;
    // For a signed target, map the upper half [2^(bits-1), 2^bits) to negatives.
    if (@typeInfo(T).int.signedness == .signed and m >= two_pow / 2) m -= two_pow;
    return @intFromFloat(m);
}

/// Write Number `num` into typed-array element `i`, coercing to the element type
/// (integer wrap, Uint8Clamped rounding/clamping, float narrowing).
pub fn taWrite(ta: *const TypedArrayData, i: usize, num: f64) void {
    const bytes = ta.buffer.array_buffer.?.data;
    const off = ta.byte_offset + i * ta.kind.byteSize();
    if (off + ta.kind.byteSize() > bytes.len) return; // shrunk resizable buffer
    switch (ta.kind) {
        .i8 => bytes[off] = @bitCast(taToInt(i8, num)),
        .u8 => bytes[off] = taToInt(u8, num),
        .u8c => {
            // ToUint8Clamp: NaN→0, round-half-to-even, clamp [0,255].
            if (std.math.isNan(num) or num <= 0) {
                bytes[off] = 0;
            } else if (num >= 255) {
                bytes[off] = 255;
            } else {
                const f = @floor(num);
                const rounded: f64 = if (num - f == 0.5)
                    (if (@mod(f, 2) == 0) f else f + 1)
                else
                    @round(num);
                bytes[off] = @intFromFloat(rounded);
            }
        },
        .i16 => std.mem.writeInt(i16, bytes[off..][0..2], taToInt(i16, num), .little),
        .u16 => std.mem.writeInt(u16, bytes[off..][0..2], taToInt(u16, num), .little),
        .i32 => std.mem.writeInt(i32, bytes[off..][0..4], taToInt(i32, num), .little),
        .u32 => std.mem.writeInt(u32, bytes[off..][0..4], taToInt(u32, num), .little),
        .f16 => std.mem.writeInt(u16, bytes[off..][0..2], @bitCast(@as(f16, @floatCast(num))), .little),
        .f32 => std.mem.writeInt(u32, bytes[off..][0..4], @bitCast(@as(f32, @floatCast(num))), .little),
        .f64 => std.mem.writeInt(u64, bytes[off..][0..8], @bitCast(num), .little),
        // A Number written to a BigInt array is only reached via the lossy
        // Number-typed method paths; the index set uses `taWriteBig`.
        .i64 => std.mem.writeInt(i64, bytes[off..][0..8], taToInt(i64, num), .little),
        .u64 => std.mem.writeInt(u64, bytes[off..][0..8], taToInt(u64, num), .little),
    }
}

/// A typed-array view: `length` elements of `kind`, starting at `byte_offset`
/// into `buffer`'s bytes.
pub const TypedArrayData = struct {
    buffer: *Object,
    byte_offset: usize,
    length: usize,
    kind: TAKind,
    /// A length-tracking view (created without an explicit length on a resizable
    /// ArrayBuffer): its length follows the buffer's current size rather than the
    /// cached `length`.
    track_length: bool = false,

    /// The view's current element length, or null if it is out of bounds (the
    /// backing resizable buffer shrank below it) or detached. A length-tracking
    /// view recomputes from the live buffer size; a fixed view keeps `length`
    /// unless its range no longer fits.
    pub fn currentLength(self: *const TypedArrayData) ?usize {
        const buf = self.buffer.array_buffer orelse return null;
        if (buf.detached) return null;
        const esz = self.kind.byteSize();
        if (self.byte_offset > buf.data.len) return null;
        if (self.track_length) return (buf.data.len - self.byte_offset) / esz;
        if (self.byte_offset + self.length * esz > buf.data.len) return null;
        return self.length;
    }
};

/// A `DataView`: a typed read/write window of `byte_length` bytes starting at
/// `byte_offset` into `buffer`'s bytes, with per-access endianness.
pub const DataViewData = struct {
    buffer: *Object,
    byte_offset: usize,
    byte_length: usize,
    /// A length-tracking DataView (no explicit byteLength on a resizable buffer).
    track_length: bool = false,

    /// The view's current byte length, or null if it is out of bounds (the
    /// resizable buffer shrank below it) or detached.
    pub fn currentByteLength(self: *const DataViewData) ?usize {
        const buf = self.buffer.array_buffer orelse return null;
        if (buf.detached) return null;
        if (self.byte_offset > buf.data.len) return null;
        if (self.track_length) return buf.data.len - self.byte_offset;
        if (self.byte_offset + self.byte_length > buf.data.len) return null;
        return self.byte_length;
    }
};

/// Internal slots for the `Temporal.*` types. One flat record covers every
/// kind (the `kind` tag selects which fields are meaningful), keeping the
/// `Object` footprint to a single pointer.
pub const TemporalData = struct {
    pub const Kind = enum { instant, plain_date, plain_time, plain_date_time, plain_year_month, plain_month_day, duration, zoned_date_time };
    kind: Kind,
    // ISO date components (PlainDate/DateTime/YearMonth/MonthDay/ZonedDateTime).
    year: i32 = 0,
    month: u8 = 1,
    day: u8 = 1,
    // ISO time components (PlainTime/DateTime/ZonedDateTime).
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
    microsecond: u16 = 0,
    nanosecond: u16 = 0,
    // Instant / ZonedDateTime: nanoseconds since the Unix epoch.
    epoch_ns: i128 = 0,
    // ZonedDateTime time zone: its identifier and (for fixed-offset zones) the
    // UTC offset in nanoseconds. IANA-named zones without DST data use offset 0.
    tz_name: []const u8 = "UTC",
    tz_offset_ns: i64 = 0,
    // Duration components (signed, may be fractional only for the smallest set).
    dur: [10]f64 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, // years,months,weeks,days,hours,minutes,seconds,ms,us,ns
};

/// State for a lazy Iterator Helper (the object returned by `map`/`filter`/…).
pub const IterHelper = struct {
    pub const Kind = enum(u8) { map, filter, take, drop, flat_map, wrap, concat, zip, zip_keyed };
    src: Value, // the underlying iterator (its `.next()` is pulled)
    next_method: Value = .undefined, // captured once (GetIteratorDirect); called per step
    kind: Kind,
    func: Value = .undefined, // mapper/filterer/flatMapper; or zip_keyed's key array
    counter: f64 = 0, // index argument to the callback
    limit: f64 = 0, // take/drop count; or zip mode (0 shortest, 1 longest, 2 strict)
    inner: ?Value = null, // flat_map's current inner iterator; or zip's per-source done-flag array
    inner_next: Value = .undefined, // flat_map inner iterator's captured `next`
    padding: Value = .undefined, // zip(longest)'s per-source padding values
    done: bool = false,
    started: bool = false, // drop: the initial skip has run
    is_async: bool = false, // AsyncIterator helper: `next` returns a promise
};

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
    /// A BigInt primitive (`typeof` reports "bigint"; treated as a primitive in
    /// equality/arithmetic). Small values use the `i128` fast path; oversized
    /// literals/decimal strings keep a canonical decimal identity in
    /// `bigint_text` until full arbitrary-precision arithmetic lands.
    is_bigint: bool = false,
    bigint: i128 = 0,
    bigint_text: ?[]const u8 = null,
    /// A Symbol's `[[Description]]`: `null` = no description (reads as
    /// `undefined`), else the string. Held in this dedicated slot rather than an
    /// own `description` property so it stays invisible to reflection
    /// (`Object.getOwnPropertyDescriptor(sym, "description")` is undefined) —
    /// `Symbol.prototype.description` is a prototype accessor instead.
    sym_desc: ?[]const u8 = null,
    /// A `Date` instance — its [[DateValue]] (ms since the Unix epoch, or NaN
    /// for an invalid date) is the internal-slot field `date_ms`, invisible to
    /// reflection/enumeration; methods are dispatched in `dateMethod`.
    is_date: bool = false,
    date_ms: f64 = 0,
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
    /// True for function `arguments` objects; they are array-like internally but
    /// carry the Arguments brand for Object.prototype.toString.
    is_arguments: bool = false,
    /// A mapped (sloppy-mode, simple-parameter) arguments object's
    /// `[[ParameterMap]]`: the call's environment record (type-erased
    /// `*Environment`) and the parameter name each index maps to (`""` = not
    /// mapped). A mapped index reads/writes the parameter binding; defining it as
    /// an accessor or non-writable, or deleting it, severs the mapping.
    arg_map_env: ?*anyopaque = null,
    arg_map_names: [][]const u8 = &.{},
    /// `Map`/`Set` instances. A Map keeps `[key,value]` pair-arrays in
    /// `elements`; a Set keeps values directly. `size` is a maintained property.
    is_map: bool = false,
    is_set: bool = false,
    /// A WeakMap/WeakSet reuses the `is_map`/`is_set` storage but carries this
    /// flag so the brand checks can tell a Map from a WeakMap (and Set/WeakSet).
    is_weak: bool = false,
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
    /// `*Interpreter.Promise`, type-erased (cycle break like `js_func`/`gen`).
    /// Non-null marks a Promise object — its `then`/`catch`/`finally` are
    /// dispatched specially and it carries pending reactions + settled state.
    promise: ?*anyopaque = null,
    /// A primitive-wrapper object's boxed [[NumberData]]/[[StringData]]/
    /// [[BooleanData]] — set by `new Number(x)` / `new String(x)` / `new
    /// Boolean(x)`. Non-null marks the object as a wrapper: `typeof` is still
    /// "object", but `valueOf`/ToPrimitive unwrap it and `Object.prototype.
    /// toString` reports `[object Number|String|Boolean]`.
    prim: ?Value = null,
    /// `Proxy` exotic object: the wrapped target and the handler object. Both
    /// non-null marks a proxy — property operations route through the handler's
    /// traps (falling back to the target). A revoked proxy has both set to a
    /// sentinel `revoked` flag.
    proxy_target: ?*Object = null,
    proxy_handler: ?*Object = null,
    proxy_revoked: bool = false,
    /// Proxies keep their [[Call]] exotic behavior even after revocation. Once
    /// revoked, the target slot is gone, so cache the callable bit at creation.
    proxy_callable: bool = false,
    /// Module Namespace exotic object: points to an `interpreter.ModuleNs`
    /// (its sorted export names + live bindings). When set, this object is a
    /// `[[Module]]` namespace and the engine intercepts its essential internal
    /// methods (live [[Get]], [[HasProperty]], sorted [[OwnPropertyKeys]],
    /// frozen/non-extensible, throwing [[Set]]/[[Delete]]/[[DefineOwnProperty]]).
    module_ns: ?*anyopaque = null,
    /// For arrays: the set of dense-index *holes* (gaps that read as absent — a
    /// deleted element, an elision in `[1,,3]`, or a gap created by a sparse
    /// assignment). The `elements` slot for a hole still exists (holds undefined),
    /// but `HasProperty`/iteration treat the index as not present. Lazily allocated.
    holes: ?*std.AutoHashMapUnmanaged(usize, void) = null,

    /// `ArrayBuffer` backing store (non-null marks an ArrayBuffer object).
    array_buffer: ?*ArrayBufferData = null,
    /// Typed-array view (non-null marks a `Int8Array`/…/`Float64Array`): an
    /// integer-indexed view over `buffer`'s bytes. Index get/set read/write the
    /// underlying bytes coerced to/from the element type.
    typed_array: ?*TypedArrayData = null,
    /// `DataView` view (non-null marks a DataView): a typed read/write window
    /// over `buffer`'s bytes with per-access endianness.
    data_view: ?*DataViewData = null,
    /// A RegExp's [[OriginalSource]] / [[OriginalFlags]] internal slots. Held off
    /// the property map so `source`/`flags`/`global`/… resolve through the
    /// RegExp.prototype accessor getters (not instance own data properties).
    regex_source: []const u8 = "",
    regex_flags: []const u8 = "",
    /// A `WeakRef`'s target (the held value). Non-null marks a WeakRef; with no
    /// real GC the target is never reclaimed, so `deref()` always returns it.
    weak_ref_target: ?Value = null,
    /// Marks a `FinalizationRegistry` (its cleanup callback never fires — no GC).
    is_finalization_registry: bool = false,
    /// Lazy Iterator-Helper state (`map`/`filter`/`take`/`drop`/`flatMap`/wrap),
    /// non-null on a helper iterator returned by those methods.
    iter_helper: ?*IterHelper = null,
    /// Marks a `ShadowRealm` instance (its child realm's Environment is in
    /// `private_data`).
    is_shadow_realm: bool = false,
    /// `Temporal.*` internal slots (PlainDate/Time/DateTime/Duration/Instant/…),
    /// non-null on a Temporal object.
    temporal: ?*TemporalData = null,

    /// Whether dense array index `i` is a hole (absent).
    pub fn isHole(self: *const Object, i: usize) bool {
        const h = self.holes orelse return false;
        return h.contains(i);
    }

    /// Mark dense index `i` as a hole.
    pub fn markHole(self: *Object, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
        if (self.holes == null) {
            self.holes = try arena.create(std.AutoHashMapUnmanaged(usize, void));
            self.holes.?.* = .{};
        }
        try self.holes.?.put(arena, i, {});
    }

    /// Clear the hole at index `i` (an assignment fills it).
    pub fn clearHole(self: *Object, i: usize) void {
        if (self.holes) |h| _ = h.remove(i);
    }

    pub fn isCallableObject(self: *const Object) bool {
        // A proxy is callable iff its target is; walk iteratively (bounded) so a
        // pathological proxy→target cycle can't blow the stack.
        var o = self;
        var guard: u32 = 0;
        while (o.proxy_target) |t| {
            guard += 1;
            if (guard > 10000) return false;
            o = t;
        }
        if (o.proxy_revoked) return o.proxy_callable;
        return o.callback != null or o.native != null or
            o.js_func != null or o.error_ctor != null or o.bound != null;
    }

    /// Own named property keys in insertion order (for `for-in` / enumeration).
    pub fn ownKeys(self: *const Object, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
        var insertion: std.ArrayListUnmanaged([]const u8) = .empty;
        var s = self.shape;
        while (s) |sh| {
            if (sh.name) |n| try insertion.append(arena, n);
            s = sh.parent;
        }
        std.mem.reverse([]const u8, insertion.items); // chain is newest-first → insertion order
        // Accessor-only properties live in a separate map (not the data-slot
        // shape); include any whose key isn't already a data slot, so getters/
        // setters appear in Object.keys / for-in / JSON / spread / rest.
        if (self.accessors) |m| {
            var it = m.iterator();
            next: while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                for (insertion.items) |existing| if (std.mem.eql(u8, existing, k)) continue :next;
                try insertion.append(arena, k);
            }
        }
        // OrdinaryOwnPropertyKeys order: canonical array-index keys ascending
        // first, then string keys in insertion order, then Symbol keys in
        // insertion order. Keep internal/private keys in the string bucket here:
        // public reflection filters them at the interpreter boundary, while
        // engine algorithms that call this low-level helper still need them.
        var indices: std.ArrayListUnmanaged([]const u8) = .empty;
        var strings: std.ArrayListUnmanaged([]const u8) = .empty;
        var symbols: std.ArrayListUnmanaged([]const u8) = .empty;
        for (insertion.items) |k| {
            if (canonicalIndex(k) != null) {
                try indices.append(arena, k);
            } else if (isRealSymbolKey(k)) {
                try symbols.append(arena, k);
            } else {
                try strings.append(arena, k);
            }
        }
        std.mem.sort([]const u8, indices.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return canonicalIndex(x).? < canonicalIndex(y).?;
            }
        }.lt);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        try out.appendSlice(arena, indices.items);
        try out.appendSlice(arena, strings.items);
        try out.appendSlice(arena, symbols.items);
        return out.items;
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
            if (isSymbolKey(k) or isPrivateKey(k)) continue; // symbol/private keys aren't string-enumerable
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

/// A key for an actual JS Symbol ("\x00s" + digits), as minted by makeSymbolObj
/// — distinct from the engine's hidden internal slots ("\x00intl", "\x00opts",
/// …), which are also NUL-prefixed but must not surface as symbols.
pub fn isRealSymbolKey(k: []const u8) bool {
    if (k.len < 3 or k[0] != 0 or k[1] != 's') return false;
    for (k[2..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// If `k` is a canonical array-index string — a non-negative integer below
/// 2**32-1 with no leading zeros or sign — return its numeric value, for the
/// spec's integer-keys-ascending property ordering. Otherwise null.
pub fn canonicalIndex(k: []const u8) ?u32 {
    if (k.len == 0) return null;
    if (k.len > 1 and k[0] == '0') return null; // leading zero → not canonical
    for (k) |c| if (c < '0' or c > '9') return null;
    const n = std.fmt.parseInt(u64, k, 10) catch return null;
    if (n >= 0xFFFFFFFF) return null; // not an array index
    return @intCast(n);
}

/// A class private member (`#x`). Stored under its `#`-prefixed name but hidden
/// from all reflection (Object.keys/getOwnPropertyNames/for-in/JSON) and never
/// enumerable — observable only through `obj.#x` inside the defining class.
pub fn isPrivateKey(k: []const u8) bool {
    return k.len > 0 and k[0] == '#';
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
            .object => |o| if (o.is_bigint) !bigIntIsZero(o) else true,
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
            // A BigInt's mathematical value (explicit `Number(1n) === 1`); other
            // objects coerce to NaN here (proper ToPrimitive is `Interpreter`-level).
            .object => |o| if (o.is_bigint) bigIntToNumber(o) else std.math.nan(f64),
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

    /// ECMAScript ToUint32 over an already-coerced Number (so a value object's
    /// valueOf/toString is run once by the caller via ToNumber, not again here).
    pub fn uint32FromF64(n: f64) u32 {
        if (std.math.isNan(n) or std.math.isInf(n)) return 0;
        const t = @trunc(n);
        const m = t - @floor(t / 4294967296.0) * 4294967296.0; // t mod 2^32
        return @intFromFloat(m);
    }

    /// The `typeof` operator result.
    pub fn typeOf(self: Value) []const u8 {
        return switch (self) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => |o| if (o.is_symbol) "symbol" else if (o.is_bigint) "bigint" else if (o.isCallableObject()) "function" else "object",
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
            .object => |o| if (o.is_bigint) try bigIntToString(o, arena) else try objectToString(o, arena),
        };
    }
};

pub fn bigIntIsZero(o: *Object) bool {
    if (o.bigint_text) |s| return std.mem.eql(u8, s, "0");
    return o.bigint == 0;
}

pub fn bigIntToNumber(o: *Object) f64 {
    if (o.bigint_text) |s| return std.fmt.parseFloat(f64, s) catch if (s.len > 0 and s[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    return @floatFromInt(o.bigint);
}

pub fn bigIntToString(o: *Object, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    if (o.bigint_text) |s| return s;
    return std.fmt.allocPrint(arena, "{d}", .{o.bigint});
}

fn bigIntEquals(a: *Object, b: *Object) bool {
    if (a.bigint_text) |as| {
        if (b.bigint_text) |bs| return std.mem.eql(u8, as, bs);
        const parsed = std.fmt.parseInt(i128, as, 10) catch return false;
        return parsed == b.bigint;
    }
    if (b.bigint_text) |bs| {
        const parsed = std.fmt.parseInt(i128, bs, 10) catch return false;
        return a.bigint == parsed;
    }
    return a.bigint == b.bigint;
}

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
/// ToString(number) per ECMAScript Number::toString (radix 10): the shortest
/// decimal that round-trips, formatted with the spec's fixed/exponential
/// thresholds (n > 21 or n <= -6 use `e` notation). `1e21` → "1e+21",
/// `1e-7` → "1e-7", `0.001` → "0.001".
pub fn numberToString(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n < 0) "-Infinity" else "Infinity";
    if (n == 0) return "0";
    // Fast path: an exactly-representable integer always renders without
    // exponent (its `n` is <= 21), so plain decimal output matches the spec.
    if (@floor(n) == n and @abs(n) < 9.007199254740992e15) {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    }

    const negative = n < 0;
    // Shortest round-tripping scientific form "d.ddde±X" / "deX".
    var sbuf: [512]u8 = undefined;
    const sci = std.fmt.float.render(&sbuf, @abs(n), .{ .mode = .scientific, .precision = null }) catch return error.OutOfMemory;
    const e_idx = std.mem.indexOfScalar(u8, sci, 'e') orelse return std.fmt.allocPrint(arena, "{d}", .{n});
    const exp = std.fmt.parseInt(i32, sci[e_idx + 1 ..], 10) catch return error.OutOfMemory;

    // Mantissa significant digits (drop the '.'), with trailing zeros trimmed.
    var digbuf: [64]u8 = undefined;
    var k: usize = 0;
    for (sci[0..e_idx]) |c| {
        if (c == '.') continue;
        digbuf[k] = c;
        k += 1;
    }
    while (k > 1 and digbuf[k - 1] == '0') k -= 1;
    const digits = digbuf[0..k];
    const ki: i32 = @intCast(k);
    const np: i32 = exp + 1; // the spec's `n`: value = digits × 10^(n-k)

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (negative) try out.append(arena, '-');
    if (np >= ki and np <= 21) {
        // Integer: all k digits, then (n-k) trailing zeros.
        try out.appendSlice(arena, digits);
        try out.appendNTimes(arena, '0', @intCast(np - ki));
    } else if (np > 0 and np <= 21) {
        // Decimal point inside the digit run.
        try out.appendSlice(arena, digits[0..@intCast(np)]);
        try out.append(arena, '.');
        try out.appendSlice(arena, digits[@intCast(np)..]);
    } else if (np > -6 and np <= 0) {
        // Leading "0.000…" then all the digits.
        try out.appendSlice(arena, "0.");
        try out.appendNTimes(arena, '0', @intCast(-np));
        try out.appendSlice(arena, digits);
    } else {
        // Exponential: first digit, optional fraction, then `e±(n-1)`.
        try out.append(arena, digits[0]);
        if (k > 1) {
            try out.append(arena, '.');
            try out.appendSlice(arena, digits[1..]);
        }
        try out.append(arena, 'e');
        const e2 = np - 1;
        try out.append(arena, if (e2 >= 0) '+' else '-');
        var ebuf: [12]u8 = undefined;
        try out.appendSlice(arena, std.fmt.bufPrint(&ebuf, "{d}", .{@abs(e2)}) catch unreachable);
    }
    return out.toOwnedSlice(arena);
}

fn isStringNumberWhitespace(cp: u21) bool {
    return switch (cp) {
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

fn trimStringNumberWhitespace(s: []const u8) []const u8 {
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    var start: usize = 0;
    var end: usize = 0;
    var seen_non_ws = false;
    const base = @intFromPtr(s.ptr);
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
        if (isStringNumberWhitespace(cp)) continue;
        const off = @intFromPtr(slice.ptr) - base;
        if (!seen_non_ws) {
            start = off;
            seen_non_ws = true;
        }
        end = off + slice.len;
    }
    if (!seen_non_ws) return s[0..0];
    return s[start..end];
}

/// Parse a string to a number per ToNumber(string): trims ECMAScript
/// StrWhiteSpace, empty string is 0, otherwise float parse or NaN.
pub fn stringToNumber(s: []const u8) f64 {
    const nan = std.math.nan(f64);
    const trimmed = trimStringNumberWhitespace(s);
    if (trimmed.len == 0) return 0;
    // Numeric separators (`_`) are a *source* lexical feature and never valid in
    // a runtime ToNumber(String) — `Number("1_0")` is NaN, not 10. (Zig's
    // parseFloat would otherwise accept them.)
    if (std.mem.indexOfScalar(u8, trimmed, '_') != null) return nan;
    // `Infinity` with an optional sign and exact casing (Zig also accepts
    // "inf"/"infinity"/"nan", which JS does not).
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    // Non-decimal integer literals: `0x`/`0o`/`0b` (unsigned, no sign, no '.').
    if (trimmed.len > 2 and trimmed[0] == '0') {
        const radix: ?u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            var acc: f64 = 0;
            for (trimmed[2..]) |c| {
                const d = std.fmt.charToDigit(c, r) catch return nan;
                acc = acc * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(d));
            }
            return acc;
        }
    }
    // A decimal literal: restrict to the StrDecimalLiteral character set so Zig's
    // parseFloat can't accept its extensions (hex floats, "inf"/"nan"); the parse
    // still rejects malformed combinations (e.g. "1e", "1.2.3") as NaN.
    for (trimmed) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return nan,
    };
    return std.fmt.parseFloat(f64, trimmed) catch nan;
}

/// Strict equality (===).
pub fn strictEquals(a: Value, b: Value) bool {
    return switch (a) {
        .undefined => b == .undefined,
        .null => b == .null,
        .boolean => |x| b == .boolean and b.boolean == x,
        .number => |x| b == .number and b.number == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        // BigInt is a primitive: `===` compares its value, not object identity.
        .object => |x| if (x.is_bigint)
            (b == .object and b.object.is_bigint and bigIntEquals(x, b.object))
        else
            (b == .object and b.object == x and !b.object.is_bigint),
    };
}

/// SameValueZero: strict equality except NaN equals NaN (and +0 equals -0).
/// Used by `Array.prototype.includes` and Map/Set key comparison.
pub fn sameValueZero(a: Value, b: Value) bool {
    if (a == .number and b == .number) {
        if (std.math.isNan(a.number) and std.math.isNan(b.number)) return true;
        return a.number == b.number;
    }
    return strictEquals(a, b);
}

/// Abstract Equality Comparison (==), simplified for the v1 value set.
pub fn looseEquals(a: Value, b: Value) bool {
    if (@as(std.meta.Tag(Value), a) == @as(std.meta.Tag(Value), b)) {
        return strictEquals(a, b);
    }
    if ((a == .null and b == .undefined) or (a == .undefined and b == .null)) return true;
    // BigInt == Number/Boolean/String: compare mathematically (a string is parsed
    // to a BigInt; a non-integer/unparseable comparand is unequal).
    const a_big = a == .object and a.object.is_bigint;
    const b_big = b == .object and b.object.is_bigint;
    if (a_big != b_big) {
        const big_obj = if (a_big) a.object else b.object;
        const other = if (a_big) b else a;
        if (big_obj.bigint_text != null) {
            return switch (other) {
                .string => |s| std.mem.eql(u8, std.mem.trim(u8, s, " \t\r\n"), big_obj.bigint_text.?),
                else => false,
            };
        }
        const big: i128 = big_obj.bigint;
        return switch (other) {
            .number => |n| @as(f64, @floatFromInt(big)) == n,
            .boolean => |x| big == @as(i128, if (x) 1 else 0),
            .string => |s| if (std.fmt.parseInt(i128, std.mem.trim(u8, s, " \t\r\n"), 10)) |p| p == big else |_| false,
            else => false,
        };
    }
    switch (a) {
        .number, .string, .boolean => switch (b) {
            .number, .string, .boolean => return a.toNumber() == b.toNumber(),
            else => {},
        },
        else => {},
    }
    return false;
}
