//! Dependency-free documentation link and sidebar integrity gate (#497).
//!
//! The parser intentionally preserves the former documentation gate's narrow syntax:
//! Markdown `[text](target)` destinations stop at whitespace or `)`, sidebar
//! destinations come from literal `link: '...'` entries, fragments and query
//! strings do not participate in file resolution, and external schemes are
//! outside this offline consistency check.

const std = @import("std");

const max_file_bytes = 16 * 1024 * 1024;
const root_docs = [_][]const u8{ "README.md", "CONTRIBUTING.md", "CLAUDE.md" };
const skipped_prefixes = [_][]const u8{ "http://", "https://", "mailto:", "#", "data:", "tel:" };

const MarkdownLinks = struct {
    source: []const u8,
    cursor: usize = 0,

    fn next(self: *MarkdownLinks) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, self.source, self.cursor, '[')) |open| {
            const label_end = std.mem.indexOfScalarPos(u8, self.source, open + 1, ']') orelse return null;
            self.cursor = label_end + 1;
            if (self.cursor >= self.source.len or self.source[self.cursor] != '(') continue;
            var start = self.cursor + 1;
            while (start < self.source.len and std.ascii.isWhitespace(self.source[start])) start += 1;
            var end = start;
            while (end < self.source.len and self.source[end] != ')' and !std.ascii.isWhitespace(self.source[end])) end += 1;
            self.cursor = @max(end, self.cursor + 1);
            if (end != start) return self.source[start..end];
        }
        return null;
    }
};

const SidebarLinks = struct {
    source: []const u8,
    cursor: usize = 0,

    fn next(self: *SidebarLinks) ?[]const u8 {
        const marker = "link:";
        while (std.mem.indexOfPos(u8, self.source, self.cursor, marker)) |at| {
            var start = at + marker.len;
            self.cursor = start;
            while (start < self.source.len and std.ascii.isWhitespace(self.source[start])) start += 1;
            if (start >= self.source.len or (self.source[start] != '\'' and self.source[start] != '"')) continue;
            start += 1;
            var end = start;
            while (end < self.source.len and self.source[end] != '\'' and self.source[end] != '"') end += 1;
            self.cursor = @min(end + 1, self.source.len);
            if (end != start) return self.source[start..end];
        }
        return null;
    }
};

fn isExternal(target: []const u8) bool {
    for (skipped_prefixes) |prefix| if (std.mem.startsWith(u8, target, prefix)) return true;
    return false;
}

fn stripFragment(target: []const u8) []const u8 {
    var end = target.len;
    if (std.mem.indexOfScalar(u8, target, '#')) |at| end = @min(end, at);
    if (std.mem.indexOfScalar(u8, target, '?')) |at| end = @min(end, at);
    return target[0..end];
}

fn exists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn resolveSiteAbsolute(gpa: std.mem.Allocator, io: std.Io, target: []const u8) !bool {
    const relative = std.mem.trim(u8, target, "/");
    if (relative.len == 0) return exists(io, "docs/index.md");

    const page = try std.fmt.allocPrint(gpa, "docs/{s}.md", .{relative});
    defer gpa.free(page);
    if (try exists(io, page)) return true;
    const index = try std.fmt.allocPrint(gpa, "docs/{s}/index.md", .{relative});
    defer gpa.free(index);
    return exists(io, index);
}

fn addFailure(gpa: std.mem.Allocator, failures: *std.ArrayList([]u8), source_path: []const u8, target: []const u8) !void {
    try failures.append(gpa, try std.fmt.allocPrint(gpa, "{s} -> {s}", .{ source_path, target }));
}

fn checkMarkdownFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    site_absolute_root: bool,
    failures: *std.ArrayList([]u8),
) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(source);
    var links = MarkdownLinks{ .source = source };
    while (links.next()) |raw| {
        if (isExternal(raw)) continue;
        const target = stripFragment(raw);
        if (target.len == 0) continue;
        if (target[0] == '/') {
            if (!site_absolute_root or !try resolveSiteAbsolute(gpa, io, target))
                try addFailure(gpa, failures, path, raw);
            continue;
        }
        const parent = std.fs.path.dirname(path) orelse ".";
        const candidate = try std.fs.path.join(gpa, &.{ parent, target });
        defer gpa.free(candidate);
        if (!try exists(io, candidate)) try addFailure(gpa, failures, path, raw);
    }
}

fn collectMarkdown(gpa: std.mem.Allocator, io: std.Io, root: []const u8, paths: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        try paths.append(gpa, try std.fs.path.join(gpa, &.{ root, entry.path }));
    }
}

fn pathLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn checkSidebar(gpa: std.mem.Allocator, io: std.Io, failures: *std.ArrayList([]u8)) !void {
    const path = "docs.config.ts";
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try failures.append(gpa, try gpa.dupe(u8, "docs.config.ts not found"));
            return;
        },
        else => return err,
    };
    defer gpa.free(source);
    var links = SidebarLinks{ .source = source };
    while (links.next()) |raw| {
        if (isExternal(raw)) continue;
        if (!try resolveSiteAbsolute(gpa, io, stripFragment(raw))) try addFailure(gpa, failures, path, raw);
    }
}

fn run(gpa: std.mem.Allocator, io: std.Io, quiet: bool) !u8 {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit(gpa);
    }
    try collectMarkdown(gpa, io, "docs", &paths);
    std.mem.sort([]u8, paths.items, {}, pathLessThan);

    var failures: std.ArrayList([]u8) = .empty;
    defer {
        for (failures.items) |failure| gpa.free(failure);
        failures.deinit(gpa);
    }

    var checked: usize = 0;
    for (paths.items) |path| {
        try checkMarkdownFile(gpa, io, path, true, &failures);
        checked += 1;
    }
    for (root_docs) |path| {
        if (!try exists(io, path)) continue;
        try checkMarkdownFile(gpa, io, path, false, &failures);
        checked += 1;
    }

    for (paths.items) |path| gpa.free(path);
    paths.clearRetainingCapacity();
    try collectMarkdown(gpa, io, ".claude/skills", &paths);
    std.mem.sort([]u8, paths.items, {}, pathLessThan);
    for (paths.items) |path| {
        try checkMarkdownFile(gpa, io, path, false, &failures);
        checked += 1;
    }
    try checkSidebar(gpa, io, &failures);

    if (failures.items.len != 0) {
        std.debug.print("docs-link-check: {d} unresolved link(s)\n", .{failures.items.len});
        for (failures.items) |failure| std.debug.print("  {s}\n", .{failure});
        return 1;
    }
    if (!quiet) {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(io, &buffer);
        try writer.interface.print("docs-link-check: {d} files, all links resolve\n", .{checked});
        try writer.interface.flush();
    }
    return 0;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var quiet = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else {
            std.debug.print("usage: docs-link-check [--quiet]\nerror: unrecognized argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    const status = try run(init.gpa, init.io, quiet);
    if (status != 0) std.process.exit(status);
}

test "markdown links preserve target and malformed-input behavior" {
    const source = "[one]( /features/language \\\"title\\\") [two](../api.md#x) [open](target";
    var links = MarkdownLinks{ .source = source };
    try std.testing.expectEqualStrings("/features/language", links.next().?);
    try std.testing.expectEqualStrings("../api.md#x", links.next().?);
    try std.testing.expectEqualStrings("target", links.next().?);
    try std.testing.expect(links.next() == null);
}

test "sidebar links require literal quoted values" {
    const source = "link: '/features/'\nlink: \"https://example.com\"\nlink: dynamic";
    var links = SidebarLinks{ .source = source };
    try std.testing.expectEqualStrings("/features/", links.next().?);
    try std.testing.expectEqualStrings("https://example.com", links.next().?);
    try std.testing.expect(links.next() == null);
}

test "fragments queries and external schemes retain the prior contract" {
    try std.testing.expectEqualStrings("../api.md", stripFragment("../api.md?mode=1#section"));
    try std.testing.expectEqualStrings("", stripFragment("#section"));
    try std.testing.expect(isExternal("mailto:test@example.com"));
    try std.testing.expect(!isExternal("./mailto:test@example.com"));
}

test "missing relative links produce the established source and target diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "source.md",
        .data = "[missing](missing.md) [external](https://example.com)",
    });
    const source_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/source.md",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(source_path);
    var failures: std.ArrayList([]u8) = .empty;
    defer {
        for (failures.items) |failure| std.testing.allocator.free(failure);
        failures.deinit(std.testing.allocator);
    }
    try checkMarkdownFile(std.testing.allocator, std.testing.io, source_path, false, &failures);
    try std.testing.expectEqual(@as(usize, 1), failures.items.len);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s} -> missing.md", .{source_path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, failures.items[0]);
}
