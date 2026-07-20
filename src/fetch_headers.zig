//! Shared Fetch `Headers` storage used by the JavaScript implementation and
//! Bun/Home's private `WebCore::FetchHeaders` ABI.
//!
//! The record owns every byte and is independently reference counted so a
//! native handle can outlive a JS wrapper (and vice versa). Normal headers are
//! stored once with their already-combined value. `Set-Cookie` is the one
//! exception: each occurrence remains a distinct row, matching WebCore's
//! `HTTPHeaderMap` and `FetchHeaders::Iterator`.

const std = @import("std");

pub const Error = error{ InvalidName, InvalidValue, OutOfMemory };

pub const known_names = [_][]const u8{
    "Accept",
    "Accept-Charset",
    "Accept-Encoding",
    "Accept-Language",
    "Accept-Ranges",
    "Access-Control-Allow-Credentials",
    "Access-Control-Allow-Headers",
    "Access-Control-Allow-Methods",
    "Access-Control-Allow-Origin",
    "Access-Control-Expose-Headers",
    "Access-Control-Max-Age",
    "Access-Control-Request-Headers",
    "Access-Control-Request-Method",
    "Age",
    "Authorization",
    "Cache-Control",
    "Connection",
    "Content-Disposition",
    "Content-Encoding",
    "Content-Language",
    "Content-Length",
    "Content-Location",
    "Content-Range",
    "Content-Security-Policy",
    "Content-Security-Policy-Report-Only",
    "Content-Type",
    "Cookie",
    "Cookie2",
    "Cross-Origin-Embedder-Policy",
    "Cross-Origin-Embedder-Policy-Report-Only",
    "Cross-Origin-Opener-Policy",
    "Cross-Origin-Opener-Policy-Report-Only",
    "Cross-Origin-Resource-Policy",
    "DNT",
    "Date",
    "Default-Style",
    "ETag",
    "Expect",
    "Expires",
    "Host",
    "Icy-MetaInt",
    "Icy-Metadata",
    "If-Match",
    "If-Modified-Since",
    "If-None-Match",
    "If-Range",
    "If-Unmodified-Since",
    "Keep-Alive",
    "Last-Event-ID",
    "Last-Modified",
    "Link",
    "Location",
    "Origin",
    "Ping-From",
    "Ping-To",
    "Pragma",
    "Proxy-Authorization",
    "Proxy-Connection",
    "Purpose",
    "Range",
    "Referer",
    "Referrer-Policy",
    "Refresh",
    "Report-To",
    "Sec-Fetch-Dest",
    "Sec-Fetch-Mode",
    "Sec-WebSocket-Accept",
    "Sec-WebSocket-Extensions",
    "Sec-WebSocket-Key",
    "Sec-WebSocket-Protocol",
    "Sec-WebSocket-Version",
    "Server-Timing",
    "Service-Worker",
    "Service-Worker-Allowed",
    "Service-Worker-Navigation-Preload",
    "Set-Cookie",
    "Set-Cookie2",
    "SourceMap",
    "Strict-Transport-Security",
    "TE",
    "Timing-Allow-Origin",
    "Trailer",
    "Transfer-Encoding",
    "Upgrade",
    "Upgrade-Insecure-Requests",
    "User-Agent",
    "Vary",
    "Via",
    "X-Content-Type-Options",
    "X-DNS-Prefetch-Control",
    "X-Frame-Options",
    "X-SourceMap",
    "X-Temp-Tablet",
    "X-XSS-Protection",
};

comptime {
    if (known_names.len != 94) @compileError("HTTPHeaderName ABI must contain exactly 94 entries");
}

pub const set_cookie_index: u8 = 75;
pub const cookie_index: u8 = 26;

pub fn knownName(index: u8) ?[]const u8 {
    if (index >= known_names.len) return null;
    return known_names[index];
}

pub fn knownNameIndex(name: []const u8) ?u8 {
    for (known_names, 0..) |candidate, index| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) return @intCast(index);
    }
    return null;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

pub fn normalizeValue(value: []const u8) []const u8 {
    var result = value;
    while (result.len != 0 and isHttpSpace(result[0])) result = result[1..];
    while (result.len != 0 and isHttpSpace(result[result.len - 1])) result = result[0 .. result.len - 1];
    return result;
}

fn isHttpSpace(char: u8) bool {
    return char == '\t' or char == '\n' or char == '\r' or char == ' ';
}

pub fn validValue(value: []const u8) bool {
    for (value) |char| if (char == 0 or char == '\n' or char == '\r') return false;
    return true;
}

const Entry = struct {
    /// Canonical WebCore spelling for known names; first spelling for uncommon
    /// names. Comparisons always use `lower_name`.
    display_name: []u8,
    lower_name: []u8,
    value: []u8,
    known_index: ?u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.display_name);
        allocator.free(self.lower_name);
        allocator.free(self.value);
    }
};

pub const SnapshotMode = enum { lower, display };

pub const Row = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: Row, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const Snapshot = struct {
    rows: []Row,

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        for (self.rows) |row| row.deinit(allocator);
        allocator.free(self.rows);
    }
};

pub const Record = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.atomic.Mutex = .unlocked,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn create() Error!*Record {
        const allocator = std.heap.page_allocator;
        const self = allocator.create(Record) catch return error.OutOfMemory;
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn retain(self: *Record) *Record {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Record) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.lock();
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    fn lock(self: *Record) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn findLocked(self: *const Record, lower_name: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.lower_name, lower_name)) return index;
        }
        return null;
    }

    fn lowerAlloc(self: *Record, name: []const u8) Error![]u8 {
        const lower = self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
        for (name, lower) |char, *slot| slot.* = std.ascii.toLower(char);
        return lower;
    }

    fn makeEntry(self: *Record, name: []const u8, value: []const u8, known_index: ?u8) Error!Entry {
        const display = self.allocator.dupe(u8, if (known_index) |index| known_names[index] else name) catch return error.OutOfMemory;
        errdefer self.allocator.free(display);
        const lower = try self.lowerAlloc(name);
        errdefer self.allocator.free(lower);
        const owned_value = self.allocator.dupe(u8, value) catch return error.OutOfMemory;
        return .{ .display_name = display, .lower_name = lower, .value = owned_value, .known_index = known_index };
    }

    pub fn append(self: *Record, name: []const u8, raw_value: []const u8) Error!void {
        if (!validName(name)) return error.InvalidName;
        const value = normalizeValue(raw_value);
        if (!validValue(value)) return error.InvalidValue;
        const known_index = knownNameIndex(name);
        const is_set_cookie = known_index == set_cookie_index;

        self.lock();
        defer self.mutex.unlock();

        if (!is_set_cookie) {
            var lower_stack: [64]u8 = undefined;
            const lower = if (name.len <= lower_stack.len) lower_stack[0..name.len] else self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
            defer if (name.len > lower_stack.len) self.allocator.free(lower);
            for (name, lower) |char, *slot| slot.* = std.ascii.toLower(char);
            if (self.findLocked(lower)) |index| {
                const entry = &self.entries.items[index];
                const separator: []const u8 = if (entry.known_index == cookie_index) "; " else ", ";
                const joined = std.mem.concat(self.allocator, u8, &.{ entry.value, separator, value }) catch return error.OutOfMemory;
                self.allocator.free(entry.value);
                entry.value = joined;
                return;
            }
        }

        const entry = try self.makeEntry(name, value, known_index);
        errdefer entry.deinit(self.allocator);
        self.entries.append(self.allocator, entry) catch return error.OutOfMemory;
    }

    pub fn appendKnown(self: *Record, index: u8, value: []const u8) Error!void {
        return self.append(knownName(index) orelse return error.InvalidName, value);
    }

    /// Import a header row that has already been parsed by an HTTP parser.
    /// Unlike the WebIDL mutation path, this deliberately preserves value
    /// bytes without trimming or re-validating them. It matches the pinned
    /// `HTTPHeaderMap` adapter semantics: known duplicates combine, Cookie
    /// uses `; `, Set-Cookie stays multi-row, and uncommon duplicates replace
    /// the value while retaining the first name spelling.
    pub fn putParsed(self: *Record, name: []const u8, value: []const u8) Error!void {
        const known_index = knownNameIndex(name);
        const is_set_cookie = known_index == set_cookie_index;
        var lower_stack: [64]u8 = undefined;
        const lower = if (name.len <= lower_stack.len) lower_stack[0..name.len] else self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
        defer if (name.len > lower_stack.len) self.allocator.free(lower);
        for (name, lower) |char, *slot| slot.* = std.ascii.toLower(char);

        self.lock();
        defer self.mutex.unlock();

        if (!is_set_cookie) {
            if (self.findLocked(lower)) |index| {
                const entry = &self.entries.items[index];
                if (known_index != null) {
                    const separator: []const u8 = if (known_index == cookie_index) "; " else ", ";
                    const joined = std.mem.concat(self.allocator, u8, &.{ entry.value, separator, value }) catch return error.OutOfMemory;
                    self.allocator.free(entry.value);
                    entry.value = joined;
                } else {
                    const replacement = self.allocator.dupe(u8, value) catch return error.OutOfMemory;
                    self.allocator.free(entry.value);
                    entry.value = replacement;
                }
                return;
            }
        }

        const entry = try self.makeEntry(name, value, known_index);
        errdefer entry.deinit(self.allocator);
        self.entries.append(self.allocator, entry) catch return error.OutOfMemory;
    }

    pub fn set(self: *Record, name: []const u8, raw_value: []const u8) Error!void {
        if (!validName(name)) return error.InvalidName;
        const value = normalizeValue(raw_value);
        if (!validValue(value)) return error.InvalidValue;
        const known_index = knownNameIndex(name);
        const replacement = try self.makeEntry(name, value, known_index);
        var owns_replacement = true;
        defer if (owns_replacement) replacement.deinit(self.allocator);

        self.lock();
        defer self.mutex.unlock();

        var first: ?usize = null;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!std.mem.eql(u8, self.entries.items[index].lower_name, replacement.lower_name)) {
                index += 1;
                continue;
            }
            if (first == null) {
                first = index;
                index += 1;
                continue;
            }
            const removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator);
        }
        if (first) |found| {
            const old = self.entries.items[found];
            self.entries.items[found] = replacement;
            owns_replacement = false;
            old.deinit(self.allocator);
        } else {
            self.entries.append(self.allocator, replacement) catch return error.OutOfMemory;
            owns_replacement = false;
        }
    }

    pub fn setKnown(self: *Record, index: u8, value: []const u8) Error!void {
        return self.set(knownName(index) orelse return error.InvalidName, value);
    }

    pub fn remove(self: *Record, name: []const u8) Error!void {
        if (!validName(name)) return error.InvalidName;
        var lower_stack: [64]u8 = undefined;
        const lower = if (name.len <= lower_stack.len) lower_stack[0..name.len] else self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
        defer if (name.len > lower_stack.len) self.allocator.free(lower);
        for (name, lower) |char, *slot| slot.* = std.ascii.toLower(char);

        self.lock();
        defer self.mutex.unlock();
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (!std.mem.eql(u8, self.entries.items[index].lower_name, lower)) {
                index += 1;
                continue;
            }
            const removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator);
        }
    }

    pub fn removeKnown(self: *Record, index: u8) void {
        self.remove(knownName(index) orelse return) catch {};
    }

    pub fn has(self: *Record, name: []const u8) Error!bool {
        if (!validName(name)) return error.InvalidName;
        var lower_stack: [64]u8 = undefined;
        const lower = if (name.len <= lower_stack.len) lower_stack[0..name.len] else self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
        defer if (name.len > lower_stack.len) self.allocator.free(lower);
        for (name, lower) |char, *slot| slot.* = std.ascii.toLower(char);
        self.lock();
        defer self.mutex.unlock();
        return self.findLocked(lower) != null;
    }

    pub fn hasKnown(self: *Record, index: u8) bool {
        return self.has(knownName(index) orelse return false) catch false;
    }

    /// Caller owns the returned byte slice. Set-Cookie is joined with `, ` for
    /// `get`, while iterator snapshots keep its rows separate.
    pub fn getCopy(self: *Record, allocator: std.mem.Allocator, name: []const u8) Error!?[]u8 {
        if (!validName(name)) return error.InvalidName;
        var lower_stack: [64]u8 = undefined;
        const lower = if (name.len <= lower_stack.len) lower_stack[0..name.len] else self.allocator.alloc(u8, name.len) catch return error.OutOfMemory;
        defer if (name.len > lower_stack.len) self.allocator.free(lower);
        for (name, lower) |char, *slot| slot.* = std.ascii.toLower(char);

        self.lock();
        defer self.mutex.unlock();
        var total: usize = 0;
        var matches: usize = 0;
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.lower_name, lower)) {
            total = std.math.add(usize, total, entry.value.len) catch return error.OutOfMemory;
            if (matches != 0) total = std.math.add(usize, total, 2) catch return error.OutOfMemory;
            matches += 1;
        };
        if (matches == 0) return null;
        const result = allocator.alloc(u8, total) catch return error.OutOfMemory;
        var used: usize = 0;
        var seen: usize = 0;
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.lower_name, lower)) {
            if (seen != 0) {
                @memcpy(result[used .. used + 2], ", ");
                used += 2;
            }
            @memcpy(result[used .. used + entry.value.len], entry.value);
            used += entry.value.len;
            seen += 1;
        };
        return result;
    }

    pub fn getKnownCopy(self: *Record, allocator: std.mem.Allocator, index: u8) Error!?[]u8 {
        return self.getCopy(allocator, knownName(index) orelse return error.InvalidName);
    }

    pub fn isEmpty(self: *Record) bool {
        self.lock();
        defer self.mutex.unlock();
        return self.entries.items.len == 0;
    }

    pub fn count(self: *Record) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    pub fn clone(self: *Record) Error!*Record {
        const result = try Record.create();
        errdefer result.release();
        self.lock();
        defer self.mutex.unlock();
        result.entries.ensureTotalCapacity(result.allocator, self.entries.items.len) catch return error.OutOfMemory;
        for (self.entries.items) |entry| {
            const copied = result.makeEntry(entry.display_name, entry.value, entry.known_index) catch return error.OutOfMemory;
            result.entries.appendAssumeCapacity(copied);
        }
        return result;
    }

    pub fn snapshot(self: *Record, allocator: std.mem.Allocator, mode: SnapshotMode) Error!Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const rows = allocator.alloc(Row, self.entries.items.len) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (rows[0..initialized]) |row| row.deinit(allocator);
            allocator.free(rows);
        }
        for (self.entries.items, rows) |entry, *row| {
            const name = allocator.dupe(u8, if (mode == .lower) entry.lower_name else entry.display_name) catch return error.OutOfMemory;
            const header_value = allocator.dupe(u8, entry.value) catch {
                allocator.free(name);
                return error.OutOfMemory;
            };
            row.* = .{ .name = name, .value = header_value };
            initialized += 1;
        }
        // Stable block sort keeps Set-Cookie rows in insertion order while the
        // sentinel comparison moves the entire cookie run after normal names.
        std.sort.block(Row, rows, {}, struct {
            fn lessThan(_: void, left: Row, right: Row) bool {
                const left_cookie = std.ascii.eqlIgnoreCase(left.name, "set-cookie");
                const right_cookie = std.ascii.eqlIgnoreCase(right.name, "set-cookie");
                if (left_cookie != right_cookie) return !left_cookie;
                if (left_cookie) return false;
                return std.mem.order(u8, left.name, right.name) == .lt;
            }
        }.lessThan);
        return .{ .rows = rows };
    }
};

test "FetchHeaders combines normal values and preserves Set-Cookie rows" {
    const headers = try Record.create();
    defer headers.release();
    try headers.append("X-Test", " one ");
    try headers.append("x-test", "two");
    try headers.append("Cookie", "a=1");
    try headers.append("cookie", "b=2");
    try headers.append("Set-Cookie", "a=1");
    try headers.append("set-cookie", "b=2");

    const test_value = (try headers.getCopy(std.testing.allocator, "x-test")).?;
    defer std.testing.allocator.free(test_value);
    try std.testing.expectEqualStrings("one, two", test_value);
    const cookie_value = (try headers.getCopy(std.testing.allocator, "cookie")).?;
    defer std.testing.allocator.free(cookie_value);
    try std.testing.expectEqualStrings("a=1; b=2", cookie_value);
    const set_cookie = (try headers.getCopy(std.testing.allocator, "set-cookie")).?;
    defer std.testing.allocator.free(set_cookie);
    try std.testing.expectEqualStrings("a=1, b=2", set_cookie);
    try std.testing.expectEqual(@as(usize, 4), headers.count());

    const rows = try headers.snapshot(std.testing.allocator, .lower);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cookie", rows.rows[0].name);
    try std.testing.expectEqualStrings("x-test", rows.rows[1].name);
    try std.testing.expectEqualStrings("set-cookie", rows.rows[2].name);
    try std.testing.expectEqualStrings("a=1", rows.rows[2].value);
    try std.testing.expectEqualStrings("b=2", rows.rows[3].value);
}

test "FetchHeaders validates atomically and clones independently" {
    const headers = try Record.create();
    defer headers.release();
    try headers.append("Accept", "text/plain");
    try std.testing.expectError(error.InvalidName, headers.append("bad name", "value"));
    try std.testing.expectError(error.InvalidValue, headers.set("Accept", "bad\rvalue"));
    const original = (try headers.getKnownCopy(std.testing.allocator, 0)).?;
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("text/plain", original);

    const cloned = try headers.clone();
    defer cloned.release();
    try cloned.setKnown(0, "application/json");
    const changed = (try cloned.getKnownCopy(std.testing.allocator, 0)).?;
    defer std.testing.allocator.free(changed);
    try std.testing.expectEqualStrings("application/json", changed);
    const unchanged = (try headers.getKnownCopy(std.testing.allocator, 0)).?;
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("text/plain", unchanged);
}

test "FetchHeaders imports parsed HTTP rows without WebIDL normalization" {
    const headers = try Record.create();
    defer headers.release();
    try headers.putParsed("Accept", " one ");
    try headers.putParsed("accept", "two");
    try headers.putParsed("Cookie", "a=1");
    try headers.putParsed("cookie", "b=2");
    try headers.putParsed("X-Raw", "first");
    try headers.putParsed("x-raw", "last");
    try headers.putParsed("Set-Cookie", "a=1");
    try headers.putParsed("set-cookie", "b=2");

    const accept = (try headers.getCopy(std.testing.allocator, "accept")).?;
    defer std.testing.allocator.free(accept);
    try std.testing.expectEqualStrings(" one , two", accept);
    const cookie = (try headers.getCopy(std.testing.allocator, "cookie")).?;
    defer std.testing.allocator.free(cookie);
    try std.testing.expectEqualStrings("a=1; b=2", cookie);
    const raw = (try headers.getCopy(std.testing.allocator, "x-raw")).?;
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("last", raw);
    try std.testing.expectEqual(@as(usize, 5), headers.count());
}
