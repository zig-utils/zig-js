//! Structured serialize/deserialize (Phase 4 of
//! https://github.com/zig-utils/zig-js/issues/1): the HTML structured-clone
//! algorithm subset for the engine's types, in two phases — serialize a value
//! graph into a context-independent byte stream, deserialize that stream into
//! a (possibly different) realm's arena. The byte form is deliberately the
//! contract: it is the `postMessage` wire format for Phase 5 workers, so it
//! must never contain pointers into a source arena. The single exception is
//! a SharedArrayBuffer payload, which carries a *retained* pointer to its
//! process-wide storage (that is the point of a SAB; the reference is
//! consumed by deserialize).
//!
//! Supported: primitives, BigInt, plain objects (own enumerable props, read
//! through [[Get]] so getters run), Arrays (dense elements + holes + named
//! props), Date, RegExp, Map, Set, Error family, Boolean/Number/String
//! wrappers, ArrayBuffer (byte copy; resizability preserved), growable and
//! fixed SharedArrayBuffer (storage shared), every TypedArray kind, DataView.
//! Cycles and identity (`a.x === a.y`) are preserved via a memo table.
//! Rejected with a DataCloneError-style TypeError: functions, symbols,
//! proxies, promises, generators, WeakMap/WeakSet/WeakRef, module namespaces,
//! arguments objects, detached ArrayBuffers.

const std = @import("std");
const value = @import("value.zig");
const interpreter = @import("interpreter.zig");
const builtins = @import("builtins.zig");
const shared_buffer = @import("shared_buffer.zig");

const Value = value.Value;
const Interpreter = interpreter.Interpreter;
const HostError = value.HostError;

const Tag = enum(u8) {
    undef,
    null_v,
    bool_v,
    number,
    string,
    bigint,
    bigint_text,
    ref,
    object,
    array,
    date,
    regexp,
    map,
    set,
    error_obj,
    wrapper,
    array_buffer,
    shared_array_buffer,
    typed_array,
    data_view,
};

// ---- writer -----------------------------------------------------------------

const Writer = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator,

    fn tag(w: *Writer, t: Tag) error{OutOfMemory}!void {
        try w.out.append(w.gpa, @intFromEnum(t));
    }
    fn byte(w: *Writer, b: u8) error{OutOfMemory}!void {
        try w.out.append(w.gpa, b);
    }
    fn int(w: *Writer, comptime T: type, v: T) error{OutOfMemory}!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try w.out.appendSlice(w.gpa, &buf);
    }
    fn num(w: *Writer, v: f64) error{OutOfMemory}!void {
        try w.int(u64, @bitCast(v));
    }
    fn str(w: *Writer, s: []const u8) error{OutOfMemory}!void {
        try w.int(u32, @intCast(s.len));
        try w.out.appendSlice(w.gpa, s);
    }
};

// ---- reader -----------------------------------------------------------------

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Error = error{Malformed};

    fn tag(r: *Reader) Error!Tag {
        const b = try r.byte();
        if (b > @intFromEnum(Tag.data_view)) return error.Malformed;
        return @enumFromInt(b);
    }
    fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.bytes.len) return error.Malformed;
        defer r.pos += 1;
        return r.bytes[r.pos];
    }
    fn int(r: *Reader, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (r.pos + n > r.bytes.len) return error.Malformed;
        defer r.pos += n;
        return std.mem.readInt(T, r.bytes[r.pos..][0..n], .little);
    }
    fn num(r: *Reader) Error!f64 {
        return @bitCast(try r.int(u64));
    }
    fn str(r: *Reader) Error![]const u8 {
        const n = try r.int(u32);
        if (r.pos + n > r.bytes.len) return error.Malformed;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }
};

// ---- serialize ----------------------------------------------------------------

const Serializer = struct {
    self: *Interpreter,
    w: Writer,
    /// Object identity → pre-order id (the deserializer reconstructs the same
    /// numbering by creating object shells in read order).
    memo: std.AutoHashMapUnmanaged(*value.Object, u32) = .empty,
    next_id: u32 = 0,

    fn throwClone(s: *Serializer, what: []const u8) HostError {
        return s.self.throwError("TypeError", what);
    }

    fn ser(s: *Serializer, v: Value) HostError!void {
        switch (v) {
            .undefined => try s.w.tag(.undef),
            .null => try s.w.tag(.null_v),
            .boolean => |b| {
                try s.w.tag(.bool_v);
                try s.w.byte(@intFromBool(b));
            },
            .number => |n| {
                try s.w.tag(.number);
                try s.w.num(n);
            },
            .string => |str| {
                try s.w.tag(.string);
                try s.w.str(str);
            },
            .object => |o| try s.serObject(o),
        }
    }

    fn serObject(s: *Serializer, o: *value.Object) HostError!void {
        // BigInts are JS *values*: no identity to preserve, no memo entry.
        if (o.is_bigint) {
            if (o.bigint_text) |t| {
                try s.w.tag(.bigint_text);
                try s.w.str(t);
            } else {
                try s.w.tag(.bigint);
                try s.w.int(i128, o.bigint);
            }
            return;
        }
        if (s.memo.get(o)) |id| {
            try s.w.tag(.ref);
            try s.w.int(u32, id);
            return;
        }
        // The DataCloneError set: values with behavior or identity that cannot
        // cross a serialization boundary.
        if (o.js_func != null or o.native != null or o.callback != null or o.bound != null)
            return s.throwClone("DataCloneError: function objects cannot be cloned");
        if (o.is_symbol) return s.throwClone("DataCloneError: Symbol values cannot be cloned");
        if (o.proxy_target != null or o.proxy_revoked)
            return s.throwClone("DataCloneError: Proxy objects cannot be cloned");
        if (o.promise != null) return s.throwClone("DataCloneError: Promise objects cannot be cloned");
        if (o.gen != null) return s.throwClone("DataCloneError: generator objects cannot be cloned");
        if (o.is_weak or o.weak_ref_target != null)
            return s.throwClone("DataCloneError: weak collections cannot be cloned");
        if (o.module_ns != null) return s.throwClone("DataCloneError: module namespaces cannot be cloned");
        if (o.is_arguments) return s.throwClone("DataCloneError: arguments objects cannot be cloned");
        if (o.is_htmldda) return s.throwClone("DataCloneError: this object cannot be cloned");

        try s.memo.put(s.w.gpa, o, s.next_id);
        s.next_id += 1;

        if (o.array_buffer) |ab| {
            if (ab.is_shared) {
                const storage = ab.shared orelse return s.throwClone("DataCloneError: malformed SharedArrayBuffer");
                try s.w.tag(.shared_array_buffer);
                // The one non-self-contained payload: a retained reference to
                // the process-wide storage, consumed by deserialize.
                try s.w.int(u64, @intFromPtr(storage.retain()));
                return;
            }
            if (ab.detached) return s.throwClone("DataCloneError: detached ArrayBuffer cannot be cloned");
            try s.w.tag(.array_buffer);
            try s.w.int(u64, if (ab.max_byte_length) |m| @intCast(m) else std.math.maxInt(u64));
            try s.w.str(ab.bytes());
            return;
        }
        if (o.typed_array) |ta| {
            try s.w.tag(.typed_array);
            try s.w.byte(@intFromEnum(ta.kind));
            try s.serObject(ta.buffer);
            try s.w.int(u64, @intCast(ta.byte_offset));
            try s.w.int(u64, @intCast(ta.length));
            try s.w.byte(@intFromBool(ta.track_length));
            return;
        }
        if (o.data_view) |dv| {
            try s.w.tag(.data_view);
            try s.serObject(dv.buffer);
            try s.w.int(u64, @intCast(dv.byte_offset));
            try s.w.int(u64, @intCast(dv.byte_length));
            try s.w.byte(@intFromBool(dv.track_length));
            return;
        }
        if (o.is_date) {
            try s.w.tag(.date);
            try s.w.num(o.date_ms);
            return;
        }
        if (o.is_regex) {
            try s.w.tag(.regexp);
            try s.w.str(o.regex_source);
            try s.w.str(o.regex_flags);
            return;
        }
        if (o.is_map) {
            try s.w.tag(.map);
            try s.w.int(u32, @intCast(o.elements.items.len));
            for (o.elements.items) |entry| {
                if (entry != .object or entry.object.elements.items.len < 2)
                    return s.throwClone("DataCloneError: malformed Map entry");
                try s.ser(entry.object.elements.items[0]);
                try s.ser(entry.object.elements.items[1]);
            }
            return;
        }
        if (o.is_set) {
            try s.w.tag(.set);
            try s.w.int(u32, @intCast(o.elements.items.len));
            for (o.elements.items) |entry| try s.ser(entry);
            return;
        }
        if (o.is_error) {
            try s.w.tag(.error_obj);
            try s.w.str(o.error_name);
            const msg = try s.self.getProperty(.{ .object = o }, "message");
            if (msg == .string) {
                try s.w.byte(1);
                try s.w.str(msg.string);
            } else {
                try s.w.byte(0);
            }
            return;
        }
        if (o.prim) |p| {
            // Boolean/Number/String wrapper: the boxed primitive only.
            try s.w.tag(.wrapper);
            try s.ser(p);
            return;
        }
        if (o.is_array) {
            try s.w.tag(.array);
            const len = @max(o.elements.items.len, o.array_len);
            try s.w.int(u64, @intCast(len));
            try s.w.int(u32, @intCast(o.elements.items.len));
            for (o.elements.items, 0..) |el, i| {
                const hole = o.holes != null and o.holes.?.contains(i);
                try s.w.byte(@intFromBool(hole));
                if (!hole) try s.ser(el);
            }
            try s.serNamedProps(o, true);
            return;
        }
        try s.w.tag(.object);
        try s.serNamedProps(o, false);
    }

    /// Own enumerable named properties, read through [[Get]] (getters run),
    /// in creation order. For arrays, index-shaped keys are skipped (the
    /// elements were serialized densely already).
    fn serNamedProps(s: *Serializer, o: *value.Object, skip_indices: bool) HostError!void {
        const keys = try builtins.ownEnumerableKeys(s.self, o);
        var count: u32 = 0;
        for (keys) |k| {
            if (skip_indices and isIndexKey(k)) continue;
            count += 1;
        }
        try s.w.int(u32, count);
        for (keys) |k| {
            if (skip_indices and isIndexKey(k)) continue;
            try s.w.str(k);
            try s.ser(try s.self.getProperty(.{ .object = o }, k));
        }
    }
};

fn isIndexKey(k: []const u8) bool {
    if (k.len == 0) return false;
    for (k) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Serialize `v` into a self-contained byte stream allocated from `gpa`.
/// On error nothing is retained (SAB references taken for an earlier part of
/// a graph that later fails are released).
pub fn serialize(self: *Interpreter, gpa: std.mem.Allocator, v: Value) HostError![]u8 {
    var s = Serializer{ .self = self, .w = .{ .gpa = gpa } };
    defer s.memo.deinit(gpa);
    errdefer {
        releaseSerialized(s.w.out.items);
        s.w.out.deinit(gpa);
    }
    try s.ser(v);
    return s.w.out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Release the SAB storage references a serialized stream holds (use when a
/// stream is dropped without being deserialized).
pub fn releaseSerialized(bytes: []const u8) void {
    var r = Reader{ .bytes = bytes };
    skipReleasing(&r) catch {};
}

fn skipReleasing(r: *Reader) Reader.Error!void {
    switch (try r.tag()) {
        .undef, .null_v => {},
        .bool_v => _ = try r.byte(),
        .number, .date => _ = try r.num(),
        .string, .bigint_text => _ = try r.str(),
        .bigint => _ = try r.int(i128),
        .ref => _ = try r.int(u32),
        .shared_array_buffer => {
            const p: *shared_buffer.SharedBufferStorage = @ptrFromInt(try r.int(u64));
            p.release();
        },
        .array_buffer => {
            _ = try r.int(u64);
            _ = try r.str();
        },
        .typed_array => {
            _ = try r.byte();
            try skipReleasing(r);
            _ = try r.int(u64);
            _ = try r.int(u64);
            _ = try r.byte();
        },
        .data_view => {
            try skipReleasing(r);
            _ = try r.int(u64);
            _ = try r.int(u64);
            _ = try r.byte();
        },
        .regexp => {
            _ = try r.str();
            _ = try r.str();
        },
        .map => {
            const n = try r.int(u32);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try skipReleasing(r);
                try skipReleasing(r);
            }
        },
        .set => {
            const n = try r.int(u32);
            var i: u32 = 0;
            while (i < n) : (i += 1) try skipReleasing(r);
        },
        .error_obj => {
            _ = try r.str();
            if (try r.byte() == 1) _ = try r.str();
        },
        .wrapper => try skipReleasing(r),
        .array => {
            _ = try r.int(u64);
            const n = try r.int(u32);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (try r.byte() == 0) try skipReleasing(r);
            }
            try skipNamed(r);
        },
        .object => try skipNamed(r),
    }
}

fn skipNamed(r: *Reader) Reader.Error!void {
    const n = try r.int(u32);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.str();
        try skipReleasing(r);
    }
}

// ---- deserialize ---------------------------------------------------------------

const Deserializer = struct {
    self: *Interpreter,
    r: Reader,
    /// Objects in creation order — mirrors the serializer's id numbering.
    objs: std.ArrayListUnmanaged(*value.Object) = .empty,

    fn fail(d: *Deserializer) HostError {
        return d.self.throwError("TypeError", "structured clone: malformed payload");
    }

    fn protoFor(d: *Deserializer, name: []const u8) ?*value.Object {
        const c = d.self.env.get(name) orelse return null;
        if (c != .object) return null;
        return d.self.protoObject(c.object) catch null;
    }

    fn deser(d: *Deserializer) HostError!Value {
        const a = d.self.arena;
        const t = d.r.tag() catch return d.fail();
        switch (t) {
            .undef => return .undefined,
            .null_v => return .null,
            .bool_v => return .{ .boolean = (d.r.byte() catch return d.fail()) != 0 },
            .number => return .{ .number = d.r.num() catch return d.fail() },
            .string => return .{ .string = try a.dupe(u8, d.r.str() catch return d.fail()) },
            .bigint => return d.self.makeBigInt(d.r.int(i128) catch return d.fail()),
            .bigint_text => return d.self.makeBigIntText(try a.dupe(u8, d.r.str() catch return d.fail())),
            .ref => {
                const id = d.r.int(u32) catch return d.fail();
                if (id >= d.objs.items.len) return d.fail();
                return .{ .object = d.objs.items[id] };
            },
            .object => {
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                try d.deserNamedProps(o);
                return .{ .object = o };
            },
            .array => {
                const arr = (try d.self.newArray()).object;
                try d.objs.append(a, arr);
                const len: usize = @intCast(d.r.int(u64) catch return d.fail());
                const n = d.r.int(u32) catch return d.fail();
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const hole = (d.r.byte() catch return d.fail()) != 0;
                    if (hole) {
                        try arr.elements.append(a, .undefined);
                        try arr.markHole(a, i);
                    } else {
                        try arr.elements.append(a, try d.deser());
                    }
                }
                arr.array_len = len;
                try d.deserNamedProps(arr);
                return .{ .object = arr };
            },
            .date => {
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                o.is_date = true;
                o.date_ms = d.r.num() catch return d.fail();
                if (d.protoFor("Date")) |p| o.proto = p;
                return .{ .object = o };
            },
            .regexp => {
                const src = try a.dupe(u8, d.r.str() catch return d.fail());
                const flags = try a.dupe(u8, d.r.str() catch return d.fail());
                // Rebuild through the realm's RegExp constructor so the
                // compiled program and lastIndex slot are consistent.
                const ctor = d.self.env.get("RegExp") orelse return d.fail();
                if (ctor != .object) return d.fail();
                const re = try d.self.construct(ctor, &.{ .{ .string = src }, .{ .string = flags } });
                if (re != .object) return d.fail();
                try d.objs.append(a, re.object);
                return re;
            },
            .map => {
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                o.is_map = true;
                if (d.protoFor("Map")) |p| o.proto = p;
                const n = d.r.int(u32) catch return d.fail();
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const k = try d.deser();
                    const v = try d.deser();
                    const pair = (try d.self.newArray()).object;
                    try pair.elements.append(a, k);
                    try pair.elements.append(a, v);
                    pair.array_len = 2;
                    try o.elements.append(a, .{ .object = pair });
                }
                return .{ .object = o };
            },
            .set => {
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                o.is_set = true;
                if (d.protoFor("Set")) |p| o.proto = p;
                const n = d.r.int(u32) catch return d.fail();
                var i: u32 = 0;
                while (i < n) : (i += 1) try o.elements.append(a, try d.deser());
                return .{ .object = o };
            },
            .error_obj => {
                const name = try a.dupe(u8, d.r.str() catch return d.fail());
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                o.is_error = true;
                o.error_name = name;
                o.proto = d.protoFor(name) orelse d.protoFor("Error");
                if ((d.r.byte() catch return d.fail()) == 1) {
                    const msg = try a.dupe(u8, d.r.str() catch return d.fail());
                    try o.setOwn(a, d.self.root_shape, "message", .{ .string = msg });
                    try o.setAttr(a, "message", .{ .writable = true, .enumerable = false, .configurable = true });
                }
                return .{ .object = o };
            },
            .wrapper => {
                const p = try d.deser();
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                o.prim = p;
                const ctor_name: []const u8 = switch (p) {
                    .number => "Number",
                    .string => "String",
                    .boolean => "Boolean",
                    else => return d.fail(),
                };
                if (d.protoFor(ctor_name)) |pr| o.proto = pr;
                return .{ .object = o };
            },
            .array_buffer => {
                const max_raw = d.r.int(u64) catch return d.fail();
                const bytes = d.r.str() catch return d.fail();
                const o = try d.self.makeArrayBuffer(bytes.len);
                try d.objs.append(a, o);
                @memcpy(o.array_buffer.?.bytes()[0..bytes.len], bytes);
                if (max_raw != std.math.maxInt(u64)) o.array_buffer.?.max_byte_length = @intCast(max_raw);
                return .{ .object = o };
            },
            .shared_array_buffer => {
                const storage: *shared_buffer.SharedBufferStorage = @ptrFromInt(d.r.int(u64) catch return d.fail());
                // The stream's reference transfers to the wrapper.
                const o = try interpreter.makeSharedArrayBufferWrapper(d.self, storage);
                try d.objs.append(a, o);
                return .{ .object = o };
            },
            .typed_array => {
                const kind_b = d.r.byte() catch return d.fail();
                if (kind_b > @intFromEnum(value.TAKind.u64)) return d.fail();
                const kind: value.TAKind = @enumFromInt(kind_b);
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                const buf = try d.deser();
                if (buf != .object or buf.object.array_buffer == null) return d.fail();
                const ta = try a.create(value.TypedArrayData);
                ta.* = .{
                    .buffer = buf.object,
                    .byte_offset = @intCast(d.r.int(u64) catch return d.fail()),
                    .length = @intCast(d.r.int(u64) catch return d.fail()),
                    .kind = kind,
                    .track_length = (d.r.byte() catch return d.fail()) != 0,
                };
                o.typed_array = ta;
                if (d.protoFor(kind.ctorName())) |p| o.proto = p;
                return .{ .object = o };
            },
            .data_view => {
                const o = (try d.self.newObject()).object;
                try d.objs.append(a, o);
                const buf = try d.deser();
                if (buf != .object or buf.object.array_buffer == null) return d.fail();
                const dv = try a.create(value.DataViewData);
                dv.* = .{
                    .buffer = buf.object,
                    .byte_offset = @intCast(d.r.int(u64) catch return d.fail()),
                    .byte_length = @intCast(d.r.int(u64) catch return d.fail()),
                    .track_length = (d.r.byte() catch return d.fail()) != 0,
                };
                o.data_view = dv;
                if (d.protoFor("DataView")) |p| o.proto = p;
                return .{ .object = o };
            },
        }
    }

    fn deserNamedProps(d: *Deserializer, o: *value.Object) HostError!void {
        const a = d.self.arena;
        const n = d.r.int(u32) catch return d.fail();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const k = try a.dupe(u8, d.r.str() catch return d.fail());
            const v = try d.deser();
            try d.self.setProp(o, k, v);
        }
    }
};

/// Deserialize a stream produced by `serialize` into `self`'s realm. The
/// stream's SAB references transfer to the wrappers it creates. On a midway
/// failure, references in the unconsumed tail are NOT released (the storage
/// leaks until process exit) — callers treat a failed stream as poisoned and
/// must not retry it.
pub fn deserialize(self: *Interpreter, bytes: []const u8) HostError!Value {
    var d = Deserializer{ .self = self, .r = .{ .bytes = bytes } };
    return d.deser();
}
