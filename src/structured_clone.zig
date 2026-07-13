//! Structured serialize/deserialize (Phase 4 of
//! https://github.com/zig-utils/zig-js/issues/1): the HTML structured-clone
//! algorithm subset for the engine's types, in two phases — serialize a value
//! graph into a context-independent byte stream, deserialize that stream into
//! a (possibly different) realm's arena. The byte form is deliberately the
//! contract: it is the `postMessage` wire format for Phase 5 workers, so it
//! must never contain pointers. SharedArrayBuffer payloads carry an opaque,
//! unguessable, single-use token for one retained process-wide storage
//! reference; deserialize or release atomically consumes that token.
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
const agent = @import("agent.zig");

const Value = value.Value;
const Interpreter = interpreter.Interpreter;
const HostError = value.HostError;

const SharedRefToken = [16]u8;
const SharedRefEntry = struct {
    token: SharedRefToken,
    storage: *shared_buffer.SharedBufferStorage,
    next: ?*SharedRefEntry = null,
};

var shared_ref_lock: std.atomic.Mutex = .unlocked;
var shared_ref_head: ?*SharedRefEntry = null;

fn lockSharedRefs() void {
    var spins: usize = 0;
    while (!shared_ref_lock.tryLock()) : (spins += 1) {
        if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
    }
}

fn tokenExistsLocked(token: SharedRefToken) bool {
    var current = shared_ref_head;
    while (current) |entry| : (current = entry.next) {
        if (std.mem.eql(u8, &entry.token, &token)) return true;
    }
    return false;
}

fn registerSharedRefToken(storage: *shared_buffer.SharedBufferStorage) error{OutOfMemory}!SharedRefToken {
    const entry = try std.heap.page_allocator.create(SharedRefEntry);
    errdefer std.heap.page_allocator.destroy(entry);
    entry.storage = storage.tryRetain() orelse return error.OutOfMemory;
    errdefer entry.storage.release();

    while (true) {
        agent.engineIo().randomSecure(&entry.token) catch return error.OutOfMemory;
        lockSharedRefs();
        if (tokenExistsLocked(entry.token)) {
            shared_ref_lock.unlock();
            continue;
        }
        entry.next = shared_ref_head;
        shared_ref_head = entry;
        shared_ref_lock.unlock();
        return entry.token;
    }
}

fn consumeSharedRefToken(token: SharedRefToken) ?*shared_buffer.SharedBufferStorage {
    lockSharedRefs();
    var link = &shared_ref_head;
    while (link.*) |entry| {
        if (std.mem.eql(u8, &entry.token, &token)) {
            link.* = entry.next;
            shared_ref_lock.unlock();
            const storage = entry.storage;
            std.heap.page_allocator.destroy(entry);
            return storage;
        }
        link = &entry.next;
    }
    shared_ref_lock.unlock();
    return null;
}

fn releaseSharedRefToken(token: SharedRefToken) bool {
    const storage = consumeSharedRefToken(token) orelse return false;
    storage.release();
    return true;
}

fn sharedRefTokenExists(token: SharedRefToken) bool {
    lockSharedRefs();
    defer shared_ref_lock.unlock();
    return tokenExistsLocked(token);
}

fn sharedRefTokenCount() usize {
    lockSharedRefs();
    defer shared_ref_lock.unlock();
    var count: usize = 0;
    var current = shared_ref_head;
    while (current) |entry| : (current = entry.next) count += 1;
    return count;
}

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
    fn sharedToken(w: *Writer, token: SharedRefToken) error{OutOfMemory}!void {
        try w.out.appendSlice(w.gpa, &token);
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
        if (n > r.bytes.len - r.pos) return error.Malformed;
        defer r.pos += n;
        return std.mem.readInt(T, r.bytes[r.pos..][0..n], .little);
    }
    fn num(r: *Reader) Error!f64 {
        return @bitCast(try r.int(u64));
    }
    fn str(r: *Reader) Error![]const u8 {
        const n: usize = try r.int(u32);
        if (n > r.bytes.len - r.pos) return error.Malformed;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }
    fn sharedToken(r: *Reader) Error!SharedRefToken {
        if (@sizeOf(SharedRefToken) > r.bytes.len - r.pos) return error.Malformed;
        defer r.pos += @sizeOf(SharedRefToken);
        return r.bytes[r.pos..][0..@sizeOf(SharedRefToken)].*;
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

    const MapEntrySnapshot = struct { key: Value, val: Value };
    const ArraySnapshot = struct { logical_len: usize, elements: []Value, holes: []bool };

    fn rootSnapshotValue(s: *Serializer, v: Value) HostError!void {
        if (v.isObject()) _ = try s.self.pushTempRoot(v);
    }

    fn snapshotSetEntries(s: *Serializer, o: *value.Object) HostError![]Value {
        var list: std.ArrayListUnmanaged(Value) = .empty;
        errdefer list.deinit(s.w.gpa);
        o.lockElements();
        defer o.unlockElements();
        for (o.elements.items) |entry| {
            if (entry.isObject() and entry.asObj().is_set_deleted) continue;
            try s.rootSnapshotValue(entry);
            try list.append(s.w.gpa, entry);
        }
        return list.items;
    }

    fn snapshotMapEntries(s: *Serializer, o: *value.Object) HostError![]MapEntrySnapshot {
        var list: std.ArrayListUnmanaged(MapEntrySnapshot) = .empty;
        errdefer list.deinit(s.w.gpa);
        o.lockElements();
        defer o.unlockElements();
        for (o.elements.items) |entry_v| {
            if (!entry_v.isObject()) return s.throwClone("DataCloneError: malformed Map entry");
            const entry = entry_v.asObj();
            {
                entry.lockElements();
                defer entry.unlockElements();
                if (entry.elements.items.len == 0) continue; // deleted MapData slot
                if (entry.elements.items.len < 2) return s.throwClone("DataCloneError: malformed Map entry");
                const k = entry.elements.items[0];
                const v = entry.elements.items[1];
                try s.rootSnapshotValue(k);
                try s.rootSnapshotValue(v);
                try list.append(s.w.gpa, .{ .key = k, .val = v });
            }
        }
        return list.items;
    }

    fn snapshotArrayElements(s: *Serializer, o: *value.Object) HostError!ArraySnapshot {
        o.lockElements();
        defer o.unlockElements();
        const n = o.elements.items.len;
        const elements = try s.w.gpa.alloc(Value, n);
        errdefer s.w.gpa.free(elements);
        const holes = try s.w.gpa.alloc(bool, n);
        errdefer s.w.gpa.free(holes);
        @memcpy(elements, o.elements.items);
        for (elements, 0..) |el, i| {
            const hole = o.holes != null and o.holes.?.contains(i);
            holes[i] = hole;
            if (!hole) try s.rootSnapshotValue(el);
        }
        return .{ .logical_len = @max(n, o.array_len), .elements = elements, .holes = holes };
    }

    fn ser(s: *Serializer, v: Value) HostError!void {
        switch (v.kind()) {
            .undefined => try s.w.tag(.undef),
            .null => try s.w.tag(.null_v),
            .boolean => {
                try s.w.tag(.bool_v);
                try s.w.byte(@intFromBool(v.asBool()));
            },
            .number => {
                try s.w.tag(.number);
                try s.w.num(v.asNum());
            },
            .string => {
                try s.w.tag(.string);
                try s.w.str(v.asStr());
            },
            .object => try s.serObject(v.asObj()),
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
                const token = try registerSharedRefToken(storage);
                var token_written = false;
                errdefer {
                    if (!token_written) _ = releaseSharedRefToken(token);
                }
                try s.w.tag(.shared_array_buffer);
                try s.w.sharedToken(token);
                token_written = true;
                return;
            }
            if (ab.isDetached()) return s.throwClone("DataCloneError: detached ArrayBuffer cannot be cloned");
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
            const root_mark = s.self.gc_temp_roots.items.len;
            defer s.self.restoreTempRoots(root_mark);
            const entries = try s.snapshotMapEntries(o);
            defer s.w.gpa.free(entries);
            try s.w.int(u32, @intCast(entries.len));
            for (entries) |entry| {
                try s.ser(entry.key);
                try s.ser(entry.val);
            }
            return;
        }
        if (o.is_set) {
            try s.w.tag(.set);
            const root_mark = s.self.gc_temp_roots.items.len;
            defer s.self.restoreTempRoots(root_mark);
            const entries = try s.snapshotSetEntries(o);
            defer s.w.gpa.free(entries);
            try s.w.int(u32, @intCast(entries.len));
            for (entries) |entry| try s.ser(entry);
            return;
        }
        if (o.is_error) {
            try s.w.tag(.error_obj);
            try s.w.str(o.error_name);
            const msg = try s.self.getProperty(Value.obj(o), "message");
            if (msg.isString()) {
                try s.w.byte(1);
                try s.w.str(msg.asStr());
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
            const root_mark = s.self.gc_temp_roots.items.len;
            defer s.self.restoreTempRoots(root_mark);
            const snap = try s.snapshotArrayElements(o);
            defer s.w.gpa.free(snap.elements);
            defer s.w.gpa.free(snap.holes);
            try s.w.int(u64, @intCast(snap.logical_len));
            try s.w.int(u32, @intCast(snap.elements.len));
            for (snap.elements, snap.holes) |el, hole| {
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
            try s.ser(try s.self.getProperty(Value.obj(o), k));
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
    while (r.pos < r.bytes.len) skipSerialized(&r, .release) catch return;
}

const SkipMode = enum { validate, release };

fn skipSerialized(r: *Reader, mode: SkipMode) Reader.Error!void {
    switch (try r.tag()) {
        .undef, .null_v => {},
        .bool_v => _ = try r.byte(),
        .number, .date => _ = try r.num(),
        .string, .bigint_text => _ = try r.str(),
        .bigint => _ = try r.int(i128),
        .ref => _ = try r.int(u32),
        .shared_array_buffer => {
            const token = try r.sharedToken();
            switch (mode) {
                .validate => if (!sharedRefTokenExists(token)) return error.Malformed,
                // Cleanup is intentionally idempotent: an earlier partial
                // deserialize may already have consumed this token. Keep
                // parsing so later still-live tokens are not stranded.
                .release => _ = releaseSharedRefToken(token),
            }
        },
        .array_buffer => {
            _ = try r.int(u64);
            _ = try r.str();
        },
        .typed_array => {
            _ = try r.byte();
            try skipSerialized(r, mode);
            _ = try r.int(u64);
            _ = try r.int(u64);
            _ = try r.byte();
        },
        .data_view => {
            try skipSerialized(r, mode);
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
                try skipSerialized(r, mode);
                try skipSerialized(r, mode);
            }
        },
        .set => {
            const n = try r.int(u32);
            var i: u32 = 0;
            while (i < n) : (i += 1) try skipSerialized(r, mode);
        },
        .error_obj => {
            _ = try r.str();
            if (try r.byte() == 1) _ = try r.str();
        },
        .wrapper => try skipSerialized(r, mode),
        .array => {
            _ = try r.int(u64);
            const n = try r.int(u32);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (try r.byte() == 0) try skipSerialized(r, mode);
            }
            try skipNamed(r, mode);
        },
        .object => try skipNamed(r, mode),
    }
}

fn skipNamed(r: *Reader, mode: SkipMode) Reader.Error!void {
    const n = try r.int(u32);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.str();
        try skipSerialized(r, mode);
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
        if (!c.isObject()) return null;
        return d.self.protoObject(c.asObj()) catch null;
    }

    fn deser(d: *Deserializer) HostError!Value {
        const a = d.self.arena;
        const t = d.r.tag() catch return d.fail();
        switch (t) {
            .undef => return Value.undef(),
            .null_v => return Value.nul(),
            .bool_v => return Value.boolVal((d.r.byte() catch return d.fail()) != 0),
            .number => return Value.num(d.r.num() catch return d.fail()),
            .string => return try Value.strOwned(a, try a.dupe(u8, d.r.str() catch return d.fail())),
            .bigint => return d.self.makeBigInt(d.r.int(i128) catch return d.fail()),
            .bigint_text => return d.self.makeBigIntText(try a.dupe(u8, d.r.str() catch return d.fail())),
            .ref => {
                const id = d.r.int(u32) catch return d.fail();
                if (id >= d.objs.items.len) return d.fail();
                return Value.obj(d.objs.items[id]);
            },
            .object => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                try d.deserNamedProps(o);
                return Value.obj(o);
            },
            .array => {
                const arr = (try d.self.newArray()).asObj();
                try d.objs.append(a, arr);
                const len: usize = @intCast(d.r.int(u64) catch return d.fail());
                const n = d.r.int(u32) catch return d.fail();
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const hole = (d.r.byte() catch return d.fail()) != 0;
                    if (hole) {
                        try arr.appendElement(a, Value.undef());
                        try arr.markHole(a, i);
                    } else {
                        try arr.appendElement(a, try d.deser());
                    }
                }
                arr.array_len = len;
                try d.deserNamedProps(arr);
                return Value.obj(arr);
            },
            .date => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_date = true;
                o.date_ms = d.r.num() catch return d.fail();
                if (d.protoFor("Date")) |p| o.proto = p;
                return Value.obj(o);
            },
            .regexp => {
                const src = try a.dupe(u8, d.r.str() catch return d.fail());
                const flags = try a.dupe(u8, d.r.str() catch return d.fail());
                // Rebuild through the realm's RegExp constructor so the
                // compiled program and lastIndex slot are consistent.
                const ctor = d.self.env.get("RegExp") orelse return d.fail();
                if (!ctor.isObject()) return d.fail();
                const re = try d.self.construct(ctor, &.{ try Value.strOwned(a, src), try Value.strOwned(a, flags) });
                if (!re.isObject()) return d.fail();
                try d.objs.append(a, re.asObj());
                return re;
            },
            .map => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_map = true;
                if (d.protoFor("Map")) |p| o.proto = p;
                const n = d.r.int(u32) catch return d.fail();
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const k = try d.deser();
                    const v = try d.deser();
                    const pair = (try d.self.newArray()).asObj();
                    try pair.appendElement(a, k);
                    try pair.appendElement(a, v);
                    pair.array_len = 2;
                    try o.appendInternalElement(a, Value.obj(pair));
                }
                return Value.obj(o);
            },
            .set => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_set = true;
                if (d.protoFor("Set")) |p| o.proto = p;
                const n = d.r.int(u32) catch return d.fail();
                var i: u32 = 0;
                while (i < n) : (i += 1) try o.appendInternalElement(a, try d.deser());
                return Value.obj(o);
            },
            .error_obj => {
                const name = try a.dupe(u8, d.r.str() catch return d.fail());
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_error = true;
                o.error_name = name;
                o.proto = d.protoFor(name) orelse d.protoFor("Error");
                if ((d.r.byte() catch return d.fail()) == 1) {
                    const msg = try a.dupe(u8, d.r.str() catch return d.fail());
                    try o.setOwn(a, d.self.root_shape, "message", try Value.strOwned(a, msg));
                    try o.setAttr(a, "message", .{ .writable = true, .enumerable = false, .configurable = true });
                }
                return Value.obj(o);
            },
            .wrapper => {
                const p = try d.deser();
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.prim = p;
                const ctor_name: []const u8 = switch (p.kind()) {
                    .number => "Number",
                    .string => "String",
                    .boolean => "Boolean",
                    else => return d.fail(),
                };
                if (d.protoFor(ctor_name)) |pr| o.proto = pr;
                return Value.obj(o);
            },
            .array_buffer => {
                const max_raw = d.r.int(u64) catch return d.fail();
                const bytes = d.r.str() catch return d.fail();
                const o = try d.self.makeArrayBuffer(bytes.len);
                try d.objs.append(a, o);
                @memcpy(o.array_buffer.?.bytes()[0..bytes.len], bytes);
                if (max_raw != std.math.maxInt(u64)) o.array_buffer.?.max_byte_length = @intCast(max_raw);
                return Value.obj(o);
            },
            .shared_array_buffer => {
                const token = d.r.sharedToken() catch return d.fail();
                const storage = consumeSharedRefToken(token) orelse return d.fail();
                // The consumed reference transfers to the wrapper. The wrapper
                // constructor owns failure cleanup as part of that contract.
                const o = try interpreter.makeSharedArrayBufferWrapper(d.self, storage);
                try d.objs.append(a, o);
                return Value.obj(o);
            },
            .typed_array => {
                const kind_b = d.r.byte() catch return d.fail();
                if (kind_b > @intFromEnum(value.TAKind.u64)) return d.fail();
                const kind: value.TAKind = @enumFromInt(kind_b);
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                const buf = try d.deser();
                if (!buf.isObject() or buf.asObj().array_buffer == null) return d.fail();
                const ta = try o.typedArrayAllocator(a).create(value.TypedArrayData);
                ta.* = .{
                    .buffer = buf.asObj(),
                    .byte_offset = @intCast(d.r.int(u64) catch return d.fail()),
                    .length = @intCast(d.r.int(u64) catch return d.fail()),
                    .kind = kind,
                    .track_length = (d.r.byte() catch return d.fail()) != 0,
                };
                o.typed_array = ta;
                if (d.protoFor(kind.ctorName())) |p| o.proto = p;
                return Value.obj(o);
            },
            .data_view => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                const buf = try d.deser();
                if (!buf.isObject() or buf.asObj().array_buffer == null) return d.fail();
                const dv = try o.dataViewAllocator(a).create(value.DataViewData);
                dv.* = .{
                    .buffer = buf.asObj(),
                    .byte_offset = @intCast(d.r.int(u64) catch return d.fail()),
                    .byte_length = @intCast(d.r.int(u64) catch return d.fail()),
                    .track_length = (d.r.byte() catch return d.fail()) != 0,
                };
                o.data_view = dv;
                if (d.protoFor("DataView")) |p| o.proto = p;
                return Value.obj(o);
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
/// stream's single-use SAB tokens transfer their retained references to the
/// wrappers they create. A successful root must consume the entire stream;
/// valid trailing token payloads are released before malformed input fails.
pub fn deserialize(self: *Interpreter, bytes: []const u8) HostError!Value {
    var verify = Reader{ .bytes = bytes };
    skipSerialized(&verify, .validate) catch return self.throwError("TypeError", "structured clone: malformed payload");
    if (verify.pos != bytes.len) {
        releaseSerialized(bytes);
        return self.throwError("TypeError", "structured clone: malformed payload");
    }
    var d = Deserializer{ .self = self, .r = .{ .bytes = bytes } };
    return d.deser();
}

test "structured clone SAB tokens are single-use and reject forgery" {
    const baseline = sharedRefTokenCount();
    const storage = try shared_buffer.SharedBufferStorage.create(8, null);
    defer storage.release();

    const token = try registerSharedRefToken(storage);
    try std.testing.expectEqual(baseline + 1, sharedRefTokenCount());
    const consumed = consumeSharedRefToken(token) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(storage, consumed);
    try std.testing.expect(consumeSharedRefToken(token) == null);
    consumed.release();
    try std.testing.expectEqual(baseline, sharedRefTokenCount());

    var forged = token;
    forged[0] ^= 0xff;
    try std.testing.expect(consumeSharedRefToken(forged) == null);

    const released = try registerSharedRefToken(storage);
    try std.testing.expect(releaseSharedRefToken(released));
    try std.testing.expect(!releaseSharedRefToken(released));
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
}

test "structured clone SAB token consumption is atomic" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const baseline = sharedRefTokenCount();
    const storage = try shared_buffer.SharedBufferStorage.create(8, null);
    defer storage.release();
    const token = try registerSharedRefToken(storage);

    var wins = std.atomic.Value(usize).init(0);
    const Consumer = struct {
        fn run(t: SharedRefToken, won: *std.atomic.Value(usize)) void {
            if (consumeSharedRefToken(t)) |held| {
                _ = won.fetchAdd(1, .monotonic);
                held.release();
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Consumer.run, .{ token, &wins });
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(usize, 1), wins.load(.monotonic));
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
}

test "structured clone consumed SAB token releases on wrapper allocation failure" {
    const baseline = sharedRefTokenCount();
    const storage = try shared_buffer.SharedBufferStorage.create(8, null);
    defer storage.release();
    try std.testing.expectEqual(@as(usize, 1), storage.retainCount());

    const token = try registerSharedRefToken(storage);
    try std.testing.expectEqual(@as(usize, 2), storage.retainCount());
    const held = consumeSharedRefToken(token) orelse return error.TestUnexpectedResult;

    var no_memory: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_memory);
    var machine: Interpreter = undefined;
    machine.arena = failing.allocator();
    machine.gc = null;
    machine.sab_retains = null;
    try std.testing.expectError(error.OutOfMemory, interpreter.makeSharedArrayBufferWrapper(&machine, held));
    try std.testing.expectEqual(@as(usize, 1), storage.retainCount());
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
}

test "structured clone SAB release rejects replay and cleans valid trailing token" {
    const baseline = sharedRefTokenCount();
    const storage = try shared_buffer.SharedBufferStorage.create(8, null);
    defer storage.release();
    const token = try registerSharedRefToken(storage);

    var bytes: [1 + 1 + @sizeOf(SharedRefToken)]u8 = undefined;
    bytes[0] = @intFromEnum(Tag.undef);
    bytes[1] = @intFromEnum(Tag.shared_array_buffer);
    @memcpy(bytes[2..], &token);

    var root = Reader{ .bytes = &bytes };
    try skipSerialized(&root, .validate);
    try std.testing.expectEqual(@as(usize, 1), root.pos);
    releaseSerialized(bytes[root.pos..]);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
    releaseSerialized(bytes[root.pos..]);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());

    const already_consumed = try registerSharedRefToken(storage);
    const still_live = try registerSharedRefToken(storage);
    const held = consumeSharedRefToken(already_consumed) orelse return error.TestUnexpectedResult;
    held.release();
    var pair: [2 * (1 + @sizeOf(SharedRefToken))]u8 = undefined;
    pair[0] = @intFromEnum(Tag.shared_array_buffer);
    @memcpy(pair[1 .. 1 + @sizeOf(SharedRefToken)], &already_consumed);
    const second_tag = 1 + @sizeOf(SharedRefToken);
    pair[second_tag] = @intFromEnum(Tag.shared_array_buffer);
    @memcpy(pair[second_tag + 1 ..], &still_live);
    releaseSerialized(&pair);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
}
