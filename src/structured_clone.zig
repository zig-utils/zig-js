//! Structured serialize/deserialize (Phase 4 of
//! https://github.com/zig-utils/zig-js/issues/1): the HTML structured-clone
//! algorithm subset for the engine's types, in two phases — serialize a value
//! graph into a context-independent byte stream, deserialize that stream into
//! a (possibly different) realm's arena. The byte form is deliberately the
//! contract: it is the `postMessage` wire format for Phase 5 workers, so it
//! must never contain pointers. Each frame owns a manifest of opaque,
//! unguessable, single-use SharedArrayBuffer tokens; payloads refer to the
//! manifest by canonical index. Deserialization or frame release atomically
//! consumes every retained process-wide storage reference. The manifest keeps
//! cleanup independent of payload parsing, including for rejected payloads.
//!
//! Supported: primitives, BigInt, plain objects (own enumerable props, read
//! through [[Get]] so getters run), Arrays (dense elements + holes + named
//! props), Date, RegExp, Map, Set, Error family, Boolean/Number/String
//! wrappers, ArrayBuffer (byte copy; resizability preserved), growable and
//! fixed SharedArrayBuffer (storage shared), every TypedArray kind, DataView.
//! Cycles and identity (`a.x === a.y`) are preserved via a memo table.
//! Rejected with a DataCloneError DOMException: functions, symbols,
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
pub const SerializeLimitError = HostError || error{MessageTooLarge};

const SharedRefToken = [16]u8;
const wire_magic = "ZJSC".*;
const wire_version: u8 = 1;
const wire_header_len = wire_magic.len + @sizeOf(u8) + @sizeOf(u32) + @sizeOf(u64);
/// Root is depth zero. A payload may nest this many child values while keeping
/// serializer, preflight, and deserializer recursion safely off the host stack
/// limit. This is a wire-format complexity contract, not a JS call-stack cap.
pub const max_nesting_depth: u16 = 256;

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
    blob,
    file,
};

// ---- writer -----------------------------------------------------------------

const Writer = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator,
    limit: usize = std.math.maxInt(usize),
    limit_exceeded: bool = false,

    fn reserve(w: *Writer, additional: usize) error{OutOfMemory}!void {
        if (additional > w.limit -| w.out.items.len) {
            w.limit_exceeded = true;
            return error.OutOfMemory;
        }
    }

    fn tag(w: *Writer, t: Tag) error{OutOfMemory}!void {
        try w.reserve(@sizeOf(u8));
        try w.out.append(w.gpa, @intFromEnum(t));
    }
    fn byte(w: *Writer, b: u8) error{OutOfMemory}!void {
        try w.reserve(@sizeOf(u8));
        try w.out.append(w.gpa, b);
    }
    fn int(w: *Writer, comptime T: type, v: T) error{OutOfMemory}!void {
        try w.reserve(@sizeOf(T));
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try w.out.appendSlice(w.gpa, &buf);
    }
    fn num(w: *Writer, v: f64) error{OutOfMemory}!void {
        try w.int(u64, @bitCast(v));
    }
    fn str(w: *Writer, s: []const u8) error{ OutOfMemory, Overflow }!void {
        const len = std.math.cast(u32, s.len) orelse return error.Overflow;
        const field_len = std.math.add(usize, @sizeOf(u32), s.len) catch return error.Overflow;
        try w.reserve(field_len);
        // Reserve the whole field atomically, then append without repeating
        // the budget check in `int`.
        var len_buf: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, len, .little);
        try w.out.appendSlice(w.gpa, &len_buf);
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
        if (b > @intFromEnum(Tag.file)) return error.Malformed;
        return @enumFromInt(b);
    }
    fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.bytes.len) return error.Malformed;
        defer r.pos += 1;
        return r.bytes[r.pos];
    }
    fn flag(r: *Reader) Error!bool {
        const b = try r.byte();
        if (b > 1) return error.Malformed;
        return b == 1;
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
        const n = std.math.cast(usize, try r.int(u32)) orelse return error.Malformed;
        if (n > r.bytes.len - r.pos) return error.Malformed;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    fn ensureCountFits(r: *Reader, count: u32, minimum_bytes_each: usize) Error!void {
        const n = std.math.cast(usize, count) orelse return error.Malformed;
        if (n > (r.bytes.len - r.pos) / minimum_bytes_each) return error.Malformed;
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
    shared_tokens: std.ArrayListUnmanaged(SharedRefToken) = .empty,

    fn throwClone(s: *Serializer, what: []const u8) HostError {
        // A structured-clone failure is a DataCloneError DOMException (not a plain
        // TypeError). The call sites label their detail "DataCloneError: X"; the
        // name carries that now, so strip the redundant prefix for the message.
        const prefix = "DataCloneError: ";
        const detail = if (std.mem.startsWith(u8, what, prefix)) what[prefix.len..] else what;
        return s.self.throwDOMException("DataCloneError", detail);
    }

    fn writeStr(s: *Serializer, text: []const u8) HostError!void {
        return s.w.str(text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Overflow => s.throwClone("DataCloneError: structured clone string is too large"),
        };
    }

    fn wireU32(s: *Serializer, n: usize, what: []const u8) HostError!u32 {
        return std.math.cast(u32, n) orelse return s.throwClone(what);
    }

    fn wireU64(s: *Serializer, n: usize, what: []const u8) HostError!u64 {
        return std.math.cast(u64, n) orelse return s.throwClone(what);
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

    fn childDepth(s: *Serializer, depth: u16) HostError!u16 {
        if (depth >= max_nesting_depth)
            return s.throwClone("DataCloneError: structured clone nesting limit exceeded");
        return depth + 1;
    }

    fn ser(s: *Serializer, v: Value, depth: u16) HostError!void {
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
                try s.writeStr(v.asStr());
            },
            .object => try s.serObject(v.asObj(), depth),
        }
    }

    fn serObject(s: *Serializer, o: *value.Object, depth: u16) HostError!void {
        // BigInts are JS *values*: no identity to preserve, no memo entry.
        if (o.is_bigint) {
            if (o.bigIntText()) |t| {
                try s.w.tag(.bigint_text);
                try s.writeStr(t);
            } else {
                try s.w.tag(.bigint);
                try s.w.int(i128, o.bigIntValue());
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
        if (o.js_func != null or o.native != null or o.hostCallback() != null or o.bound != null)
            return s.throwClone("DataCloneError: function objects cannot be cloned");
        if (o.is_symbol) return s.throwClone("DataCloneError: Symbol values cannot be cloned");
        if (o.proxy_target != null or o.proxy_revoked)
            return s.throwClone("DataCloneError: Proxy objects cannot be cloned");
        if (o.promise != null) return s.throwClone("DataCloneError: Promise objects cannot be cloned");
        if (o.gen != null) return s.throwClone("DataCloneError: generator objects cannot be cloned");
        if (o.is_weak or o.weakRefTarget() != null)
            return s.throwClone("DataCloneError: weak collections cannot be cloned");
        if (o.moduleNs() != null) return s.throwClone("DataCloneError: module namespaces cannot be cloned");
        if (o.is_arguments) return s.throwClone("DataCloneError: arguments objects cannot be cloned");
        if (o.is_htmldda) return s.throwClone("DataCloneError: this object cannot be cloned");

        const object_id = s.next_id;
        const next_id = std.math.add(u32, object_id, 1) catch
            return s.throwClone("DataCloneError: too many structured clone objects");
        try s.memo.put(s.w.gpa, o, object_id);
        s.next_id = next_id;

        if (o.array_buffer) |ab| {
            if (ab.is_shared) {
                const storage = ab.shared orelse return s.throwClone("DataCloneError: malformed SharedArrayBuffer");
                if (@sizeOf(SharedRefToken) > s.w.limit -| s.w.out.items.len) {
                    s.w.limit_exceeded = true;
                    return error.OutOfMemory;
                }
                s.w.limit -= @sizeOf(SharedRefToken);
                const token = try registerSharedRefToken(storage);
                const token_index = std.math.cast(u32, s.shared_tokens.items.len) orelse {
                    _ = releaseSharedRefToken(token);
                    return s.throwClone("DataCloneError: too many SharedArrayBuffers");
                };
                s.shared_tokens.append(s.w.gpa, token) catch {
                    _ = releaseSharedRefToken(token);
                    return error.OutOfMemory;
                };
                try s.w.tag(.shared_array_buffer);
                try s.w.int(u32, token_index);
                return;
            }
            if (ab.isDetached()) return s.throwClone("DataCloneError: detached ArrayBuffer cannot be cloned");
            try s.w.tag(.array_buffer);
            try s.w.int(u64, if (ab.max_byte_length) |m|
                try s.wireU64(m, "DataCloneError: ArrayBuffer maximum is too large")
            else
                std.math.maxInt(u64));
            try s.writeStr(ab.bytes());
            return;
        }
        if (o.typed_array) |ta| {
            try s.w.tag(.typed_array);
            try s.w.byte(@intFromEnum(ta.kind));
            try s.serObject(ta.buffer, try s.childDepth(depth));
            try s.w.int(u64, try s.wireU64(ta.byte_offset, "DataCloneError: TypedArray offset is too large"));
            try s.w.int(u64, if (ta.track_length) 0 else try s.wireU64(ta.length, "DataCloneError: TypedArray length is too large"));
            try s.w.byte(@intFromBool(ta.track_length));
            return;
        }
        if (o.data_view) |dv| {
            try s.w.tag(.data_view);
            try s.serObject(dv.buffer, try s.childDepth(depth));
            try s.w.int(u64, try s.wireU64(dv.byte_offset, "DataCloneError: DataView offset is too large"));
            try s.w.int(u64, if (dv.track_length) 0 else try s.wireU64(dv.byte_length, "DataCloneError: DataView length is too large"));
            try s.w.byte(@intFromBool(dv.track_length));
            return;
        }
        if (o.is_date) {
            try s.w.tag(.date);
            try s.w.num(o.dateMs());
            return;
        }
        if (o.is_regex) {
            try s.w.tag(.regexp);
            try s.writeStr(o.regexSource());
            try s.writeStr(o.regexFlags());
            return;
        }
        if (o.is_map) {
            try s.w.tag(.map);
            const root_mark = s.self.gc_temp_roots.items.len;
            defer s.self.restoreTempRoots(root_mark);
            const entries = try s.snapshotMapEntries(o);
            defer s.w.gpa.free(entries);
            try s.w.int(u32, try s.wireU32(entries.len, "DataCloneError: too many Map entries"));
            if (entries.len == 0) return;
            const child_depth = try s.childDepth(depth);
            for (entries) |entry| {
                try s.ser(entry.key, child_depth);
                try s.ser(entry.val, child_depth);
            }
            return;
        }
        if (o.is_set) {
            try s.w.tag(.set);
            const root_mark = s.self.gc_temp_roots.items.len;
            defer s.self.restoreTempRoots(root_mark);
            const entries = try s.snapshotSetEntries(o);
            defer s.w.gpa.free(entries);
            try s.w.int(u32, try s.wireU32(entries.len, "DataCloneError: too many Set entries"));
            if (entries.len == 0) return;
            const child_depth = try s.childDepth(depth);
            for (entries) |entry| try s.ser(entry, child_depth);
            return;
        }
        if (o.is_error) {
            try s.w.tag(.error_obj);
            try s.writeStr(o.errorName());
            const msg = try s.self.getProperty(Value.obj(o), "message");
            if (msg.isString()) {
                try s.w.byte(1);
                try s.writeStr(msg.asStr());
            } else {
                try s.w.byte(0);
            }
            // HTML structured clone copies an Error's own `cause` when present
            // (an own `cause` of `undefined` still counts as present).
            if (o.getOwn("cause")) |cause| {
                try s.w.byte(1);
                try s.ser(cause, try s.childDepth(depth));
            } else {
                try s.w.byte(0);
            }
            return;
        }
        if (o.getOwn("\x00blobbuf")) |bufv| {
            // Blob/File: copy the byte payload, MIME type, and (File) name/mtime.
            const is_file = o.getOwn("\x00filename") != null;
            try s.w.tag(if (is_file) .file else .blob);
            const bytes: []const u8 = if (bufv.isObject()) (if (bufv.asObj().array_buffer) |ab| ab.bytes() else &.{}) else &.{};
            try s.writeStr(bytes);
            const tv = o.getOwn("\x00blobtype");
            try s.writeStr(if (tv != null and tv.?.isString()) tv.?.asStr() else "");
            if (is_file) {
                const nv = o.getOwn("\x00filename");
                try s.writeStr(if (nv != null and nv.?.isString()) nv.?.asStr() else "");
                const mv = o.getOwn("\x00filemod");
                try s.w.num(if (mv != null and mv.?.isNumber()) mv.?.asNum() else 0);
            }
            return;
        }
        if (o.prim) |p| {
            // Boolean/Number/String wrapper: the boxed primitive only.
            try s.w.tag(.wrapper);
            try s.ser(p, try s.childDepth(depth));
            return;
        }
        if (o.is_array) {
            try s.w.tag(.array);
            const root_mark = s.self.gc_temp_roots.items.len;
            defer s.self.restoreTempRoots(root_mark);
            const snap = try s.snapshotArrayElements(o);
            defer s.w.gpa.free(snap.elements);
            defer s.w.gpa.free(snap.holes);
            try s.w.int(u64, try s.wireU64(snap.logical_len, "DataCloneError: Array length is too large"));
            try s.w.int(u32, try s.wireU32(snap.elements.len, "DataCloneError: too many Array elements"));
            for (snap.elements, snap.holes) |el, hole| {
                try s.w.byte(@intFromBool(hole));
                if (!hole) try s.ser(el, try s.childDepth(depth));
            }
            try s.serNamedProps(o, true, depth);
            return;
        }
        try s.w.tag(.object);
        try s.serNamedProps(o, false, depth);
    }

    /// Own enumerable named properties, read through [[Get]] (getters run),
    /// in creation order. For arrays, index-shaped keys are skipped (the
    /// elements were serialized densely already).
    fn serNamedProps(s: *Serializer, o: *value.Object, skip_indices: bool, depth: u16) HostError!void {
        const keys = try builtins.ownEnumerableKeys(s.self, o);
        var count: u32 = 0;
        for (keys) |k| {
            if (skip_indices and isIndexKey(k)) continue;
            count = std.math.add(u32, count, 1) catch
                return s.throwClone("DataCloneError: too many object properties");
        }
        try s.w.int(u32, count);
        if (count == 0) return;
        const child_depth = try s.childDepth(depth);
        for (keys) |k| {
            if (skip_indices and isIndexKey(k)) continue;
            try s.writeStr(k);
            try s.ser(try s.self.getProperty(Value.obj(o), k), child_depth);
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
    return serializeWithLimit(self, gpa, v, std.math.maxInt(usize)) catch |err| switch (err) {
        error.MessageTooLarge => unreachable,
        error.OutOfMemory => error.OutOfMemory,
        error.Throw => error.Throw,
        error.OptShortCircuit => error.OptShortCircuit,
    };
}

/// Serialize while bounding the complete frame (header + SAB manifest +
/// payload). Limit rejection is a catchable clone error, and tokens retained
/// before a later rejection are released by the normal serializer unwind.
pub fn serializeWithLimit(
    self: *Interpreter,
    gpa: std.mem.Allocator,
    v: Value,
    max_frame_bytes: usize,
) SerializeLimitError![]u8 {
    const payload_limit = if (max_frame_bytes >= wire_header_len)
        max_frame_bytes - wire_header_len
    else
        0;
    var s = Serializer{ .self = self, .w = .{ .gpa = gpa, .limit = payload_limit } };
    defer s.memo.deinit(gpa);
    defer s.shared_tokens.deinit(gpa);
    defer s.w.out.deinit(gpa);
    errdefer {
        for (s.shared_tokens.items) |token| _ = releaseSharedRefToken(token);
    }
    s.ser(v, 0) catch |err| {
        if (err == error.OutOfMemory and s.w.limit_exceeded)
            return error.MessageTooLarge;
        return err;
    };
    const manifest_len = std.math.mul(usize, s.shared_tokens.items.len, @sizeOf(SharedRefToken)) catch
        return error.MessageTooLarge;
    const framed_len = std.math.add(usize, wire_header_len, manifest_len) catch
        return error.MessageTooLarge;
    const total_len = std.math.add(usize, framed_len, s.w.out.items.len) catch
        return error.MessageTooLarge;
    if (total_len > max_frame_bytes) return error.MessageTooLarge;
    return encodeFrame(gpa, s.shared_tokens.items, s.w.out.items) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => s.throwClone("DataCloneError: structured clone payload is too large"),
    };
}

/// Release the SAB storage references a serialized stream holds (use when a
/// stream is dropped without being deserialized). Manifests are independent
/// of payload validation, so cleanup remains complete for rejected payloads.
pub fn releaseSerialized(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const frame_len = releaseFrame(remaining) orelse return;
        remaining = remaining[frame_len..];
    }
}

const Frame = struct {
    tokens: []const u8,
    payload: []const u8,
    frame_len: usize,

    fn tokenCount(frame: Frame) usize {
        return frame.tokens.len / @sizeOf(SharedRefToken);
    }

    fn token(frame: Frame, index: usize) SharedRefToken {
        const start = index * @sizeOf(SharedRefToken);
        return frame.tokens[start .. start + @sizeOf(SharedRefToken)][0..@sizeOf(SharedRefToken)].*;
    }
};

fn encodeFrame(
    gpa: std.mem.Allocator,
    tokens: []const SharedRefToken,
    payload: []const u8,
) error{ OutOfMemory, Overflow }![]u8 {
    const token_count = std.math.cast(u32, tokens.len) orelse return error.Overflow;
    const payload_len = std.math.cast(u64, payload.len) orelse return error.Overflow;
    const manifest_len = std.math.mul(usize, tokens.len, @sizeOf(SharedRefToken)) catch return error.Overflow;
    const prefix_len = std.math.add(usize, wire_header_len, manifest_len) catch return error.Overflow;
    const total_len = std.math.add(usize, prefix_len, payload.len) catch return error.Overflow;
    const framed = try gpa.alloc(u8, total_len);
    var pos: usize = 0;
    @memcpy(framed[pos .. pos + wire_magic.len], &wire_magic);
    pos += wire_magic.len;
    framed[pos] = wire_version;
    pos += @sizeOf(u8);
    std.mem.writeInt(u32, framed[pos..][0..@sizeOf(u32)], token_count, .little);
    pos += @sizeOf(u32);
    std.mem.writeInt(u64, framed[pos..][0..@sizeOf(u64)], payload_len, .little);
    pos += @sizeOf(u64);
    for (tokens) |token| {
        @memcpy(framed[pos .. pos + @sizeOf(SharedRefToken)], &token);
        pos += @sizeOf(SharedRefToken);
    }
    @memcpy(framed[pos..], payload);
    return framed;
}

fn readFrame(bytes: []const u8) Reader.Error!Frame {
    if (bytes.len < wire_header_len) return error.Malformed;
    if (!std.mem.eql(u8, bytes[0..wire_magic.len], &wire_magic)) return error.Malformed;
    if (bytes[wire_magic.len] != wire_version) return error.Malformed;
    var pos: usize = wire_magic.len + @sizeOf(u8);
    const token_count = std.math.cast(usize, std.mem.readInt(u32, bytes[pos..][0..@sizeOf(u32)], .little)) orelse
        return error.Malformed;
    pos += @sizeOf(u32);
    const payload_len_raw = std.mem.readInt(u64, bytes[pos..][0..@sizeOf(u64)], .little);
    pos += @sizeOf(u64);
    const payload_len = std.math.cast(usize, payload_len_raw) orelse return error.Malformed;
    const manifest_len = std.math.mul(usize, token_count, @sizeOf(SharedRefToken)) catch return error.Malformed;
    if (manifest_len > bytes.len - pos) return error.Malformed;
    const payload_start = pos + manifest_len;
    if (payload_len > bytes.len - payload_start) return error.Malformed;
    const frame_len = std.math.add(usize, payload_start, payload_len) catch return error.Malformed;
    return .{
        .tokens = bytes[pos..payload_start],
        .payload = bytes[payload_start..frame_len],
        .frame_len = frame_len,
    };
}

/// Release a frame's manifest before inspecting its payload length. This is
/// deliberately separate from `readFrame`: a truncated or otherwise rejected
/// payload still owns every complete token named by its frame header.
fn releaseFrame(bytes: []const u8) ?usize {
    if (bytes.len < wire_header_len) return null;
    if (!std.mem.eql(u8, bytes[0..wire_magic.len], &wire_magic)) return null;
    if (bytes[wire_magic.len] != wire_version) return null;
    var pos: usize = wire_magic.len + @sizeOf(u8);
    const token_count = std.math.cast(usize, std.mem.readInt(u32, bytes[pos..][0..@sizeOf(u32)], .little)) orelse
        return null;
    pos += @sizeOf(u32);
    const payload_len_raw = std.mem.readInt(u64, bytes[pos..][0..@sizeOf(u64)], .little);
    pos += @sizeOf(u64);
    const manifest_len = std.math.mul(usize, token_count, @sizeOf(SharedRefToken)) catch return null;
    if (manifest_len > bytes.len - pos) return null;
    const tokens = bytes[pos .. pos + manifest_len];
    for (0..token_count) |i| {
        const start = i * @sizeOf(SharedRefToken);
        _ = releaseSharedRefToken(tokens[start .. start + @sizeOf(SharedRefToken)][0..@sizeOf(SharedRefToken)].*);
    }
    const payload_len = std.math.cast(usize, payload_len_raw) orelse return null;
    const payload_start = pos + manifest_len;
    if (payload_len > bytes.len - payload_start) return null;
    return std.math.add(usize, payload_start, payload_len) catch null;
}

const SkipState = struct {
    frame: Frame,
    next_shared: u32 = 0,
    next_object: u32 = 0,

    fn validateToken(state: *SkipState, index: u32) Reader.Error!void {
        if (index != state.next_shared) return error.Malformed;
        const token_index = std.math.cast(usize, index) orelse return error.Malformed;
        if (token_index >= state.frame.tokenCount()) return error.Malformed;
        if (!sharedRefTokenExists(state.frame.token(token_index))) return error.Malformed;
        state.next_shared = std.math.add(u32, state.next_shared, 1) catch return error.Malformed;
    }

    fn addObject(state: *SkipState) Reader.Error!void {
        state.next_object = std.math.add(u32, state.next_object, 1) catch return error.Malformed;
    }
};

fn wireChildDepth(depth: u16) Reader.Error!u16 {
    if (depth >= max_nesting_depth) return error.Malformed;
    return depth + 1;
}

fn wireUsize(raw: u64) Reader.Error!usize {
    return std.math.cast(usize, raw) orelse return error.Malformed;
}

fn tagCreatesObject(tag: Tag) bool {
    return switch (tag) {
        .object,
        .array,
        .date,
        .regexp,
        .map,
        .set,
        .error_obj,
        .wrapper,
        .array_buffer,
        .shared_array_buffer,
        .typed_array,
        .data_view,
        .blob,
        .file,
        => true,
        else => false,
    };
}

fn skipSerialized(r: *Reader, state: *SkipState, depth: u16) Reader.Error!void {
    const tag = try r.tag();
    if (tagCreatesObject(tag)) try state.addObject();
    switch (tag) {
        .undef, .null_v => {},
        .bool_v => _ = try r.flag(),
        .number, .date => _ = try r.num(),
        .string, .bigint_text => _ = try r.str(),
        .bigint => _ = try r.int(i128),
        .ref => {
            const id = try r.int(u32);
            if (id >= state.next_object) return error.Malformed;
        },
        .shared_array_buffer => {
            try state.validateToken(try r.int(u32));
        },
        .array_buffer => {
            const max_raw = try r.int(u64);
            const bytes = try r.str();
            if (max_raw != std.math.maxInt(u64)) {
                const max = try wireUsize(max_raw);
                if (max < bytes.len) return error.Malformed;
            }
        },
        .typed_array => {
            const kind = try r.byte();
            if (kind > @intFromEnum(value.TAKind.u64)) return error.Malformed;
            try skipSerialized(r, state, try wireChildDepth(depth));
            _ = try wireUsize(try r.int(u64));
            const len = try wireUsize(try r.int(u64));
            const track = try r.flag();
            if (track and len != 0) return error.Malformed;
        },
        .data_view => {
            try skipSerialized(r, state, try wireChildDepth(depth));
            _ = try wireUsize(try r.int(u64));
            const len = try wireUsize(try r.int(u64));
            const track = try r.flag();
            if (track and len != 0) return error.Malformed;
        },
        .regexp => {
            _ = try r.str();
            _ = try r.str();
        },
        .blob, .file => {
            _ = try r.str(); // bytes
            _ = try r.str(); // type
            if (tag == .file) {
                _ = try r.str(); // name
                _ = try r.num(); // lastModified
            }
        },
        .map => {
            const n = try r.int(u32);
            try r.ensureCountFits(n, 2);
            if (n == 0) return;
            const child_depth = try wireChildDepth(depth);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                try skipSerialized(r, state, child_depth);
                try skipSerialized(r, state, child_depth);
            }
        },
        .set => {
            const n = try r.int(u32);
            try r.ensureCountFits(n, 1);
            if (n == 0) return;
            const child_depth = try wireChildDepth(depth);
            var i: u32 = 0;
            while (i < n) : (i += 1) try skipSerialized(r, state, child_depth);
        },
        .error_obj => {
            _ = try r.str();
            if (try r.flag()) _ = try r.str();
            // A present `cause` is a full serialized value (matches serialize/deser).
            if (try r.flag()) try skipSerialized(r, state, try wireChildDepth(depth));
        },
        .wrapper => try skipSerialized(r, state, try wireChildDepth(depth)),
        .array => {
            const logical_len = try wireUsize(try r.int(u64));
            const n = try r.int(u32);
            const element_count = std.math.cast(usize, n) orelse return error.Malformed;
            if (r.bytes.len - r.pos < @sizeOf(u32)) return error.Malformed;
            if (element_count > r.bytes.len - r.pos - @sizeOf(u32)) return error.Malformed;
            if (element_count > logical_len) return error.Malformed;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (!try r.flag())
                    try skipSerialized(r, state, try wireChildDepth(depth));
            }
            try skipNamed(r, state, depth);
        },
        .object => try skipNamed(r, state, depth),
    }
}

fn skipNamed(r: *Reader, state: *SkipState, depth: u16) Reader.Error!void {
    const n = try r.int(u32);
    try r.ensureCountFits(n, @sizeOf(u32) + @sizeOf(u8));
    if (n == 0) return;
    const child_depth = try wireChildDepth(depth);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        _ = try r.str();
        try skipSerialized(r, state, child_depth);
    }
}

// ---- deserialize ---------------------------------------------------------------

const Deserializer = struct {
    self: *Interpreter,
    r: Reader,
    /// Objects in creation order — mirrors the serializer's id numbering.
    objs: std.ArrayListUnmanaged(*value.Object) = .empty,
    frame: Frame,
    next_shared: u32 = 0,

    fn fail(d: *Deserializer) HostError {
        return d.self.throwError("TypeError", "structured clone: malformed payload");
    }

    fn childDepth(d: *Deserializer, depth: u16) HostError!u16 {
        if (depth >= max_nesting_depth) return d.fail();
        return depth + 1;
    }

    fn readUsize(d: *Deserializer) HostError!usize {
        const raw = d.r.int(u64) catch return d.fail();
        return std.math.cast(usize, raw) orelse return d.fail();
    }

    fn readFlag(d: *Deserializer) HostError!bool {
        return d.r.flag() catch return d.fail();
    }

    fn protoFor(d: *Deserializer, name: []const u8) ?*value.Object {
        const c = d.self.env.get(name) orelse return null;
        if (!c.isObject()) return null;
        return d.self.protoObject(c.asObj()) catch null;
    }

    fn deser(d: *Deserializer, depth: u16) HostError!Value {
        const a = d.self.arena;
        const t = d.r.tag() catch return d.fail();
        switch (t) {
            .undef => return Value.undef(),
            .null_v => return Value.nul(),
            .bool_v => return Value.boolVal(try d.readFlag()),
            .number => return Value.num(d.r.num() catch return d.fail()),
            .string => return try Value.strOwned(a, try a.dupe(u8, d.r.str() catch return d.fail())),
            .bigint => return d.self.makeBigInt(d.r.int(i128) catch return d.fail()),
            .bigint_text => return d.self.makeBigIntText(try a.dupe(u8, d.r.str() catch return d.fail())),
            .ref => {
                const id = d.r.int(u32) catch return d.fail();
                const object_index = std.math.cast(usize, id) orelse return d.fail();
                if (object_index >= d.objs.items.len) return d.fail();
                return Value.obj(d.objs.items[object_index]);
            },
            .object => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                try d.deserNamedProps(o, depth);
                return Value.obj(o);
            },
            .array => {
                const arr = (try d.self.newArray()).asObj();
                try d.objs.append(a, arr);
                const len = try d.readUsize();
                const n = std.math.cast(usize, d.r.int(u32) catch return d.fail()) orelse return d.fail();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const hole = try d.readFlag();
                    if (hole) {
                        try arr.appendElement(a, Value.undef());
                        try arr.markHole(a, i);
                    } else {
                        try arr.appendElement(a, try d.deser(try d.childDepth(depth)));
                    }
                }
                arr.array_len = len;
                try d.deserNamedProps(arr, depth);
                return Value.obj(arr);
            },
            .date => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_date = true;
                try o.initDateMs(a, d.r.num() catch return d.fail());
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
            .blob, .file => {
                const bytes = try a.dupe(u8, d.r.str() catch return d.fail());
                const blob_type = try a.dupe(u8, d.r.str() catch return d.fail());
                var name: []const u8 = "";
                var last_mod: f64 = 0;
                if (t == .file) {
                    name = try a.dupe(u8, d.r.str() catch return d.fail());
                    last_mod = d.r.num() catch return d.fail();
                }
                const blob = try d.self.makeClonedBlob(t == .file, bytes, blob_type, name, last_mod);
                if (!blob.isObject()) return d.fail();
                try d.objs.append(a, blob.asObj());
                return blob;
            },
            .map => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_map = true;
                if (d.protoFor("Map")) |p| o.proto = p;
                const n = d.r.int(u32) catch return d.fail();
                const child_depth = if (n == 0) 0 else try d.childDepth(depth);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const k = try d.deser(child_depth);
                    const v = try d.deser(child_depth);
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
                const child_depth = if (n == 0) 0 else try d.childDepth(depth);
                var i: u32 = 0;
                while (i < n) : (i += 1) try o.appendInternalElement(a, try d.deser(child_depth));
                return Value.obj(o);
            },
            .error_obj => {
                const name = try a.dupe(u8, d.r.str() catch return d.fail());
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                o.is_error = true;
                try o.setErrorName(a, name);
                o.proto = d.protoFor(name) orelse d.protoFor("Error");
                if (try d.readFlag()) {
                    const msg = try a.dupe(u8, d.r.str() catch return d.fail());
                    try o.setOwn(a, d.self.root_shape, "message", try Value.strOwned(a, msg));
                    try o.setAttr(a, "message", .{ .writable = true, .enumerable = false, .configurable = true });
                }
                if (try d.readFlag()) {
                    const cause = try d.deser(try d.childDepth(depth));
                    try o.setOwn(a, d.self.root_shape, "cause", cause);
                    try o.setAttr(a, "cause", .{ .writable = true, .enumerable = false, .configurable = true });
                }
                return Value.obj(o);
            },
            .wrapper => {
                const p = try d.deser(try d.childDepth(depth));
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
                if (max_raw != std.math.maxInt(u64))
                    o.array_buffer.?.max_byte_length = std.math.cast(usize, max_raw) orelse return d.fail();
                return Value.obj(o);
            },
            .shared_array_buffer => {
                const index = d.r.int(u32) catch return d.fail();
                const token_index = std.math.cast(usize, index) orelse return d.fail();
                if (index != d.next_shared or token_index >= d.frame.tokenCount()) return d.fail();
                d.next_shared = std.math.add(u32, d.next_shared, 1) catch return d.fail();
                const token = d.frame.token(token_index);
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
                const buf = try d.deser(try d.childDepth(depth));
                if (!buf.isObject() or buf.asObj().array_buffer == null) return d.fail();
                const byte_offset = try d.readUsize();
                const length = try d.readUsize();
                const track_length = try d.readFlag();
                const element_size = kind.byteSize();
                const ab = buf.asObj().array_buffer.?;
                ab.lockBuffer();
                const buffer_len = ab.bytes().len;
                const resizable = ab.max_byte_length != null;
                ab.unlockBuffer();
                if (byte_offset % element_size != 0 or byte_offset > buffer_len) return d.fail();
                if (track_length) {
                    if (!resizable or length != 0) return d.fail();
                } else {
                    const byte_length = std.math.mul(usize, length, element_size) catch return d.fail();
                    if (byte_length > buffer_len - byte_offset) return d.fail();
                }
                const ta = try o.typedArrayAllocator(a).create(value.TypedArrayData);
                ta.* = .{
                    .buffer = buf.asObj(),
                    .byte_offset = byte_offset,
                    .length = length,
                    .kind = kind,
                    .track_length = track_length,
                };
                o.typed_array = ta;
                if (d.protoFor(kind.ctorName())) |p| o.proto = p;
                return Value.obj(o);
            },
            .data_view => {
                const o = (try d.self.newObject()).asObj();
                try d.objs.append(a, o);
                const buf = try d.deser(try d.childDepth(depth));
                if (!buf.isObject() or buf.asObj().array_buffer == null) return d.fail();
                const byte_offset = try d.readUsize();
                const byte_length = try d.readUsize();
                const track_length = try d.readFlag();
                const ab = buf.asObj().array_buffer.?;
                ab.lockBuffer();
                const buffer_len = ab.bytes().len;
                const resizable = ab.max_byte_length != null;
                ab.unlockBuffer();
                if (byte_offset > buffer_len) return d.fail();
                if (track_length) {
                    if (!resizable or byte_length != 0) return d.fail();
                } else if (byte_length > buffer_len - byte_offset) return d.fail();
                const dv = try o.dataViewAllocator(a).create(value.DataViewData);
                dv.* = .{
                    .buffer = buf.asObj(),
                    .byte_offset = byte_offset,
                    .byte_length = byte_length,
                    .track_length = track_length,
                };
                o.data_view = dv;
                if (d.protoFor("DataView")) |p| o.proto = p;
                return Value.obj(o);
            },
        }
    }

    fn deserNamedProps(d: *Deserializer, o: *value.Object, depth: u16) HostError!void {
        const a = d.self.arena;
        const n = d.r.int(u32) catch return d.fail();
        if (n == 0) return;
        const child_depth = try d.childDepth(depth);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const k = try a.dupe(u8, d.r.str() catch return d.fail());
            const v = try d.deser(child_depth);
            try d.self.setProp(o, k, v);
        }
    }
};

/// Deserialize a stream produced by `serialize` into `self`'s realm. The
/// stream's single-use SAB tokens transfer their retained references to the
/// wrappers they create. A successful root must consume the entire stream;
/// valid trailing token payloads are released before malformed input fails.
pub fn deserialize(self: *Interpreter, bytes: []const u8) HostError!Value {
    const frame = readFrame(bytes) catch return self.throwError("TypeError", "structured clone: malformed payload");
    if (frame.frame_len != bytes.len) {
        releaseSerialized(bytes);
        return self.throwError("TypeError", "structured clone: malformed payload");
    }
    var verify = Reader{ .bytes = frame.payload };
    var skip = SkipState{ .frame = frame };
    skipSerialized(&verify, &skip, 0) catch {
        releaseSerialized(bytes);
        return self.throwError("TypeError", "structured clone: malformed payload");
    };
    const frame_token_count = std.math.cast(u32, frame.tokenCount()) orelse {
        releaseSerialized(bytes);
        return self.throwError("TypeError", "structured clone: malformed payload");
    };
    if (verify.pos != frame.payload.len or skip.next_shared != frame_token_count) {
        releaseSerialized(bytes);
        return self.throwError("TypeError", "structured clone: malformed payload");
    }
    var d = Deserializer{ .self = self, .r = .{ .bytes = frame.payload }, .frame = frame };
    return d.deser(0) catch |err| {
        // Tokens already consumed by wrappers are absent from the registry;
        // manifest cleanup is idempotent and releases every later token.
        releaseSerialized(bytes);
        return err;
    };
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

    const undef_frame = try encodeFrame(std.testing.allocator, &.{}, &.{@intFromEnum(Tag.undef)});
    defer std.testing.allocator.free(undef_frame);
    var sab_payload: [1 + @sizeOf(u32)]u8 = undefined;
    sab_payload[0] = @intFromEnum(Tag.shared_array_buffer);
    std.mem.writeInt(u32, sab_payload[1..][0..@sizeOf(u32)], 0, .little);
    const sab_frame = try encodeFrame(std.testing.allocator, &.{token}, &sab_payload);
    defer std.testing.allocator.free(sab_frame);

    const root = try readFrame(undef_frame);
    try std.testing.expectEqual(@as(usize, 1), root.payload.len);
    releaseSerialized(sab_frame);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
    releaseSerialized(sab_frame);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());

    const already_consumed = try registerSharedRefToken(storage);
    const still_live = try registerSharedRefToken(storage);
    const held = consumeSharedRefToken(already_consumed) orelse return error.TestUnexpectedResult;
    held.release();
    var pair_payload: [2 * (1 + @sizeOf(u32))]u8 = undefined;
    pair_payload[0] = @intFromEnum(Tag.shared_array_buffer);
    std.mem.writeInt(u32, pair_payload[1..][0..@sizeOf(u32)], 0, .little);
    const second_tag = 1 + @sizeOf(u32);
    pair_payload[second_tag] = @intFromEnum(Tag.shared_array_buffer);
    std.mem.writeInt(u32, pair_payload[second_tag + 1 ..][0..@sizeOf(u32)], 1, .little);
    const pair = try encodeFrame(std.testing.allocator, &.{ already_consumed, still_live }, &pair_payload);
    defer std.testing.allocator.free(pair);
    releaseSerialized(pair);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());

    const truncated_token = try registerSharedRefToken(storage);
    const truncated = try encodeFrame(std.testing.allocator, &.{truncated_token}, &.{
        @intFromEnum(Tag.shared_array_buffer), 0, 0, 0, 0,
    });
    defer std.testing.allocator.free(truncated);
    releaseSerialized(truncated[0 .. truncated.len - 1]);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
}

test "structured clone wire depth is bounded and rejected manifests clean up" {
    const allowed_wrappers: usize = max_nesting_depth;
    const allowed_payload = try std.testing.allocator.alloc(u8, allowed_wrappers + 1);
    defer std.testing.allocator.free(allowed_payload);
    @memset(allowed_payload[0..allowed_wrappers], @intFromEnum(Tag.wrapper));
    allowed_payload[allowed_wrappers] = @intFromEnum(Tag.undef);
    const allowed_frame_bytes = try encodeFrame(std.testing.allocator, &.{}, allowed_payload);
    defer std.testing.allocator.free(allowed_frame_bytes);
    const allowed_frame = try readFrame(allowed_frame_bytes);
    var allowed_reader = Reader{ .bytes = allowed_frame.payload };
    var allowed_state = SkipState{ .frame = allowed_frame };
    try skipSerialized(&allowed_reader, &allowed_state, 0);
    try std.testing.expectEqual(allowed_frame.payload.len, allowed_reader.pos);

    const baseline = sharedRefTokenCount();
    const storage = try shared_buffer.SharedBufferStorage.create(8, null);
    defer storage.release();
    const token = try registerSharedRefToken(storage);
    const rejected_wrappers = allowed_wrappers + 1;
    const rejected_payload = try std.testing.allocator.alloc(u8, rejected_wrappers + 1 + @sizeOf(u32));
    defer std.testing.allocator.free(rejected_payload);
    @memset(rejected_payload[0..rejected_wrappers], @intFromEnum(Tag.wrapper));
    rejected_payload[rejected_wrappers] = @intFromEnum(Tag.shared_array_buffer);
    std.mem.writeInt(u32, rejected_payload[rejected_wrappers + 1 ..][0..@sizeOf(u32)], 0, .little);
    const rejected_frame_bytes = try encodeFrame(std.testing.allocator, &.{token}, rejected_payload);
    defer std.testing.allocator.free(rejected_frame_bytes);
    const rejected_frame = try readFrame(rejected_frame_bytes);
    var rejected_reader = Reader{ .bytes = rejected_frame.payload };
    var rejected_state = SkipState{ .frame = rejected_frame };
    try std.testing.expectError(error.Malformed, skipSerialized(&rejected_reader, &rejected_state, 0));
    releaseSerialized(rejected_frame_bytes);
    try std.testing.expectEqual(baseline, sharedRefTokenCount());
}

test "structured clone wire rejects impossible counts and noncanonical fields" {
    const Check = struct {
        fn malformed(payload: []const u8) !void {
            const frame_bytes = try encodeFrame(std.testing.allocator, &.{}, payload);
            defer std.testing.allocator.free(frame_bytes);
            const frame = try readFrame(frame_bytes);
            var reader = Reader{ .bytes = frame.payload };
            var state = SkipState{ .frame = frame };
            try std.testing.expectError(error.Malformed, skipSerialized(&reader, &state, 0));
        }
    };

    var collection: [1 + @sizeOf(u32)]u8 = undefined;
    inline for (.{ Tag.map, Tag.set, Tag.object }) |tag| {
        collection[0] = @intFromEnum(tag);
        std.mem.writeInt(u32, collection[1..][0..@sizeOf(u32)], std.math.maxInt(u32), .little);
        try Check.malformed(&collection);
    }

    var string: [1 + @sizeOf(u32)]u8 = undefined;
    string[0] = @intFromEnum(Tag.string);
    std.mem.writeInt(u32, string[1..][0..@sizeOf(u32)], std.math.maxInt(u32), .little);
    try Check.malformed(&string);

    var array: [1 + @sizeOf(u64) + @sizeOf(u32)]u8 = undefined;
    array[0] = @intFromEnum(Tag.array);
    std.mem.writeInt(u64, array[1..][0..@sizeOf(u64)], std.math.maxInt(u64), .little);
    std.mem.writeInt(u32, array[1 + @sizeOf(u64) ..][0..@sizeOf(u32)], std.math.maxInt(u32), .little);
    try Check.malformed(&array);

    var short_array: [1 + @sizeOf(u64) + @sizeOf(u32) + 1]u8 = undefined;
    short_array[0] = @intFromEnum(Tag.array);
    std.mem.writeInt(u64, short_array[1..][0..@sizeOf(u64)], 0, .little);
    std.mem.writeInt(u32, short_array[1 + @sizeOf(u64) ..][0..@sizeOf(u32)], 1, .little);
    short_array[short_array.len - 1] = 1;
    try Check.malformed(&short_array);

    try Check.malformed(&.{ @intFromEnum(Tag.bool_v), 2 });
    try Check.malformed(&.{ @intFromEnum(Tag.error_obj), 0, 0, 0, 0, 2 });
    try Check.malformed(&.{ @intFromEnum(Tag.typed_array), std.math.maxInt(u8) });
    try Check.malformed(&.{ @intFromEnum(Tag.ref), 0, 0, 0, 0 });
}
