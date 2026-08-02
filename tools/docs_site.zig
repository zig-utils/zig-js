//! Owned, dependency-free documentation builder and preview server (#464).
//!
//! The renderer intentionally implements the complete Markdown and component
//! surface used by this repository. A checked output manifest makes page loss,
//! asset loss, or renderer drift fail closed in CI.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const max_file_bytes = 32 * 1024 * 1024;
const docs_dir = "docs";
const out_dir = "dist";
const manifest_path = "docs/.data/docs-site-manifest-v1.json";

const Link = struct { text: []const u8, link: []const u8 };
const Section = struct { text: []const u8, items: []const Link };
const Redirect = struct { from: []const u8, to: []const u8 };
const SiteConfig = struct {
    schema_version: u32,
    title: []const u8,
    description: []const u8,
    base_url: []const u8,
    nav: []const Link,
    sidebar: []const Section,
    redirects: []const Redirect,
};

const Page = struct { source: []const u8, route: []const u8 };
const Output = struct { path: []const u8, sha256: [32]u8 };
const Heading = struct { level: u8, text: []const u8, id: []const u8 };
const Meta = struct {
    title: []const u8,
    description: []const u8,
    layout_home: bool = false,
    hero_name: []const u8 = "zig-js",
    hero_text: []const u8 = "A JavaScript engine in pure Zig",
    hero_tagline: []const u8 = "",
};
const TemplateContext = struct { name: ?[]const u8 = null, value: ?std.json.Value = null };

const app_js =
    \\(() => {
    \\  const input = document.querySelector('[data-search]');
    \\  const results = document.querySelector('[data-search-results]');
    \\  if (!input || !results) return;
    \\  let index;
    \\  const load = async () => index ??= await (await fetch('/search.json')).json();
    \\  const close = () => { results.classList.remove('open'); results.innerHTML = ''; };
    \\  input.addEventListener('input', async () => {
    \\    const q = input.value.trim().toLowerCase();
    \\    if (!q) return close();
    \\    const rows = (await load()).filter(p => p.search.includes(q)).slice(0, 12);
    \\    results.innerHTML = rows.map(p => `<a href="${p.route}"><b>${p.title}</b><span>${p.description}</span></a>`).join('');
    \\    results.classList.toggle('open', rows.length > 0);
    \\  });
    \\  input.addEventListener('keydown', e => { if (e.key === 'Escape') { input.value = ''; close(); } });
    \\  document.addEventListener('click', e => { if (!e.target.closest('.search')) close(); });
    \\})();
;

fn append(buf: *std.ArrayListUnmanaged(u8), gpa: Allocator, bytes: []const u8) !void {
    try buf.appendSlice(gpa, bytes);
}

fn print(buf: *std.ArrayListUnmanaged(u8), gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const rendered = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(rendered);
    try append(buf, gpa, rendered);
}

fn read(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
}

fn ensureParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
}

fn write(io: Io, path: []const u8, data: []const u8) !void {
    try ensureParent(io, path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn htmlEscape(buf: *std.ArrayListUnmanaged(u8), gpa: Allocator, value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try append(buf, gpa, "&amp;"),
        '<' => try append(buf, gpa, "&lt;"),
        '>' => try append(buf, gpa, "&gt;"),
        '"' => try append(buf, gpa, "&quot;"),
        else => try buf.append(gpa, c),
    };
}

fn jsonEscape(buf: *std.ArrayListUnmanaged(u8), gpa: Allocator, value: []const u8) !void {
    for (value) |c| switch (c) {
        '"' => try append(buf, gpa, "\\\""),
        '\\' => try append(buf, gpa, "\\\\"),
        '\n' => try append(buf, gpa, "\\n"),
        '\r' => try append(buf, gpa, "\\r"),
        '\t' => try append(buf, gpa, "\\t"),
        0...8, 11...12, 14...0x1f => try print(buf, gpa, "\\u00{x:0>2}", .{c}),
        else => try buf.append(gpa, c),
    };
}

fn sha(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

fn lessPath(_: void, a: Page, b: Page) bool {
    return std.mem.lessThan(u8, a.source, b.source);
}
fn lessOutput(_: void, a: Output, b: Output) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn routeFor(gpa: Allocator, relative: []const u8) ![]const u8 {
    const no_ext = relative[0 .. relative.len - 3];
    if (std.mem.eql(u8, no_ext, "index")) return try gpa.dupe(u8, "/");
    if (std.mem.endsWith(u8, no_ext, "/index")) {
        return try std.fmt.allocPrint(gpa, "/{s}/", .{no_ext[0 .. no_ext.len - "/index".len]});
    }
    return try std.fmt.allocPrint(gpa, "/{s}", .{no_ext});
}

fn outputPathForRoute(gpa: Allocator, route: []const u8) ![]const u8 {
    if (std.mem.eql(u8, route, "/")) return try gpa.dupe(u8, "dist/index.html");
    return try std.fmt.allocPrint(gpa, "dist/{s}/index.html", .{std.mem.trim(u8, route, "/")});
}

fn discover(gpa: Allocator, io: Io, pages: *std.ArrayListUnmanaged(Page), assets: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, docs_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try gpa.dupe(u8, entry.path);
        if (std.mem.startsWith(u8, path, ".components/")) continue;
        if (std.mem.eql(u8, path, ".data/docs-site-manifest-v1.json")) continue;
        if (std.mem.startsWith(u8, path, ".data/")) {
            try assets.append(gpa, path);
        } else if (std.mem.endsWith(u8, path, ".md")) {
            try pages.append(gpa, .{ .source = path, .route = try routeFor(gpa, path) });
        } else if (!std.mem.eql(u8, path, "site.json") and !std.mem.eql(u8, path, "site.css")) {
            try assets.append(gpa, path);
        }
    }
    std.mem.sort(Page, pages.items, {}, lessPath);
    std.mem.sort([]const u8, assets.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
}

fn yamlValue(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var value = std.mem.trim(u8, line[at + 1 ..], " \t");
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
    return value;
}

fn parseMeta(source: []const u8, fallback: []const u8) struct { meta: Meta, body: []const u8 } {
    var meta = Meta{ .title = fallback, .description = "" };
    if (!std.mem.startsWith(u8, source, "---\n")) return .{ .meta = meta, .body = source };
    const end = std.mem.indexOf(u8, source[4..], "\n---\n") orelse return .{ .meta = meta, .body = source };
    const front = source[4 .. 4 + end];
    var in_hero = false;
    var lines = std.mem.splitScalar(u8, front, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
        if (std.mem.eql(u8, trimmed, "hero:")) {
            in_hero = true;
            continue;
        }
        if (in_hero and std.mem.eql(u8, trimmed, "actions:")) {
            in_hero = false;
            continue;
        }
        if (indent == 0 and std.mem.indexOfScalar(u8, trimmed, ':') != null) in_hero = false;
        if (std.mem.startsWith(u8, trimmed, "layout:")) meta.layout_home = std.mem.eql(u8, yamlValue(trimmed).?, "home") else if (std.mem.startsWith(u8, trimmed, "title:")) meta.title = yamlValue(trimmed).? else if (std.mem.startsWith(u8, trimmed, "description:")) meta.description = yamlValue(trimmed).? else if (in_hero and std.mem.startsWith(u8, trimmed, "name:")) meta.hero_name = yamlValue(trimmed).? else if (in_hero and std.mem.startsWith(u8, trimmed, "text:")) meta.hero_text = yamlValue(trimmed).? else if (in_hero and std.mem.startsWith(u8, trimmed, "tagline:")) meta.hero_tagline = yamlValue(trimmed).?;
    }
    return .{ .meta = meta, .body = source[4 + end + 5 ..] };
}

fn valueAt(root: std.json.Value, expression: []const u8, ctx: TemplateContext) ?std.json.Value {
    var expr = std.mem.trim(u8, expression, " \t\n\r");
    var current = root;
    if (ctx.name) |name| {
        if (std.mem.eql(u8, expr, name)) return ctx.value;
        if (std.mem.startsWith(u8, expr, name) and expr.len > name.len and expr[name.len] == '.') {
            current = ctx.value.?;
            expr = expr[name.len + 1 ..];
        }
    }
    var parts = std.mem.splitScalar(u8, expr, '.');
    while (parts.next()) |part| {
        current = switch (current) {
            .object => |obj| obj.get(part) orelse return null,
            else => return null,
        };
    }
    return current;
}

fn appendJsonValue(buf: *std.ArrayListUnmanaged(u8), gpa: Allocator, value: std.json.Value) !void {
    switch (value) {
        .string => |s| try htmlEscape(buf, gpa, s),
        .integer => |n| try print(buf, gpa, "{d}", .{n}),
        .float => |n| try print(buf, gpa, "{d}", .{n}),
        .bool => |b| try append(buf, gpa, if (b) "true" else "false"),
        .null => {},
        else => return error.NonScalarTemplateValue,
    }
}

fn replaceTemplates(gpa: Allocator, input: []const u8, data: std.json.Value, ctx: TemplateContext) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest = input;
    while (std.mem.indexOf(u8, rest, "{{")) |start| {
        try append(&out, gpa, rest[0..start]);
        const close = std.mem.indexOf(u8, rest[start + 2 ..], "}}") orelse return error.UnclosedTemplate;
        const expr = rest[start + 2 .. start + 2 + close];
        const value = valueAt(data, expr, ctx) orelse {
            std.debug.print("docs: unknown template value '{{{{{s}}}}}'\n", .{std.mem.trim(u8, expr, " \t")});
            return error.UnknownTemplateValue;
        };
        try appendJsonValue(&out, gpa, value);
        rest = rest[start + 2 + close + 2 ..];
    }
    try append(&out, gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn expandLoops(gpa: Allocator, input: []const u8, data: std.json.Value) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest = input;
    const marker = "@foreach (";
    while (std.mem.indexOf(u8, rest, marker)) |start| {
        try append(&out, gpa, rest[0..start]);
        const header_end = std.mem.indexOfScalarPos(u8, rest, start + marker.len, ')') orelse return error.InvalidForeach;
        const header = rest[start + marker.len .. header_end];
        const as_at = std.mem.indexOf(u8, header, " as ") orelse return error.InvalidForeach;
        const expression = std.mem.trim(u8, header[0..as_at], " \t");
        const name = std.mem.trim(u8, header[as_at + 4 ..], " \t");
        const body_start = std.mem.indexOfScalarPos(u8, rest, header_end, '\n') orelse return error.InvalidForeach;
        const end = std.mem.indexOf(u8, rest[body_start + 1 ..], "@endforeach") orelse return error.InvalidForeach;
        const body = rest[body_start + 1 .. body_start + 1 + end];
        const array = valueAt(data, expression, .{}) orelse return error.UnknownTemplateValue;
        switch (array) {
            .array => |items| for (items.items) |item| {
                const rendered = try replaceTemplates(gpa, body, data, .{ .name = name, .value = item });
                try append(&out, gpa, rendered);
            },
            else => return error.ForeachNeedsArray,
        }
        rest = rest[body_start + 1 + end + "@endforeach".len ..];
    }
    try append(&out, gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var rest = tag;
    while (std.mem.indexOf(u8, rest, name)) |start| {
        const after_name = start + name.len;
        if (after_name + 2 <= rest.len and std.mem.startsWith(u8, rest[after_name..], "=\"")) {
            const value_start = after_name + 2;
            const end = std.mem.indexOfScalarPos(u8, rest, value_start, '"') orelse return null;
            return rest[value_start..end];
        }
        rest = rest[after_name..];
    }
    return null;
}

fn scalarString(data: std.json.Value, expression: []const u8) ![]const u8 {
    return switch (valueAt(data, expression, .{}) orelse return error.UnknownTemplateValue) {
        .string => |s| s,
        else => return error.TemplateValueNeedsString,
    };
}

fn scalarNumber(gpa: Allocator, data: std.json.Value, expression: []const u8) ![]const u8 {
    const value = valueAt(data, expression, .{}) orelse return error.UnknownTemplateValue;
    return switch (value) {
        .integer => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
        .float => |n| try std.fmt.allocPrint(gpa, "{d}", .{n}),
        else => return error.TemplateValueNeedsNumber,
    };
}

fn progressComponent(gpa: Allocator, data: std.json.Value) ![]const u8 {
    const pct = try scalarNumber(gpa, data, "data.test262.valid.percentage");
    const passing = try scalarNumber(gpa, data, "data.test262.valid.passing");
    const total = try scalarNumber(gpa, data, "data.test262.valid.total");
    const parse_fail = try scalarNumber(gpa, data, "data.test262.valid.parseFail");
    const runtime_fail = try scalarNumber(gpa, data, "data.test262.valid.runtimeFail");
    const negative = try scalarNumber(gpa, data, "data.test262.negative.percentage");
    const skipped = try scalarNumber(gpa, data, "data.test262.skipped");
    const harness = try scalarString(data, "data.test262.harness");
    const generated = try scalarString(data, "data.test262.generatedAt");
    return std.fmt.allocPrint(gpa,
        \\<div class="t262"><div class="t262-head"><span class="t262-label">test262 · valid — can we run it?</span><span class="t262-pct">{s}%</span></div>
        \\<div class="t262-track"><div class="t262-fill" style="width: {s}%"></div></div>
        \\<div class="t262-sub"><b>{s}</b> / {s} valid tests passing · {s} · updated {s}</div>
        \\<div class="t262-stats"><div class="t262-stat"><div class="n good">{s}</div><div class="k">passing</div></div><div class="t262-stat"><div class="n bad">{s}</div><div class="k">parse-fail</div></div><div class="t262-stat"><div class="n bad">{s}</div><div class="k">runtime-fail</div></div><div class="t262-stat"><div class="n">{s}%</div><div class="k">negative (strictness)</div></div><div class="t262-stat"><div class="n">{s}</div><div class="k">skipped</div></div></div></div>
    , .{ pct, pct, passing, total, harness, generated, passing, parse_fail, runtime_fail, negative, skipped });
}

fn replaceComponent(gpa: Allocator, input: []const u8, open_name: []const u8, close_name: []const u8, kind: enum { terminal, card }) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest = input;
    while (std.mem.indexOf(u8, rest, open_name)) |start| {
        try append(&out, gpa, rest[0..start]);
        const tag_end = std.mem.indexOfScalarPos(u8, rest, start, '>') orelse return error.InvalidComponent;
        const close_at_rel = std.mem.indexOf(u8, rest[tag_end + 1 ..], close_name) orelse return error.InvalidComponent;
        const close_at = tag_end + 1 + close_at_rel;
        const tag = rest[start..tag_end];
        const slot = rest[tag_end + 1 .. close_at];
        switch (kind) {
            .terminal => {
                const title = attr(tag, "title") orelse return error.InvalidComponent;
                try append(&out, gpa, "<div class=\"term\"><div class=\"term-bar\"><span class=\"term-dot r\"></span><span class=\"term-dot y\"></span><span class=\"term-dot g\"></span><span class=\"term-title\">");
                try htmlEscape(&out, gpa, title);
                try append(&out, gpa, "</span></div><div class=\"term-body\">");
                try append(&out, gpa, slot);
                try append(&out, gpa, "</div></div>");
            },
            .card => {
                const tag_value = attr(tag, "tag") orelse return error.InvalidComponent;
                const title = attr(tag, "title") orelse return error.InvalidComponent;
                try append(&out, gpa, "<div class=\"card\"><div class=\"ico\">");
                try htmlEscape(&out, gpa, tag_value);
                try append(&out, gpa, "</div><h3>");
                try htmlEscape(&out, gpa, title);
                try append(&out, gpa, "</h3><p>");
                try append(&out, gpa, slot);
                try append(&out, gpa, "</p></div>");
            },
        }
        rest = rest[close_at + close_name.len ..];
    }
    try append(&out, gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn preprocess(gpa: Allocator, input: []const u8, data: std.json.Value) ![]const u8 {
    const loops = try expandLoops(gpa, input, data);
    var with_progress: std.ArrayListUnmanaged(u8) = .empty;
    var rest = loops;
    const progress = "<Test262Progress :stats=\"data.test262\" />";
    while (std.mem.indexOf(u8, rest, progress)) |at| {
        try append(&with_progress, gpa, rest[0..at]);
        try append(&with_progress, gpa, try progressComponent(gpa, data));
        rest = rest[at + progress.len ..];
    }
    try append(&with_progress, gpa, rest);
    const terminals = try replaceComponent(gpa, with_progress.items, "<Terminal ", "</Terminal>", .terminal);
    const cards = try replaceComponent(gpa, terminals, "<FeatureCard ", "</FeatureCard>", .card);
    return replaceTemplates(gpa, cards, data, .{});
}

fn inlineRender(gpa: Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, input, i, '>')) |end| {
                try append(&out, gpa, input[i .. end + 1]);
                i = end + 1;
                continue;
            }
        }
        if (input[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, input, i + 1, '`')) |end| {
                try append(&out, gpa, "<code>");
                try htmlEscape(&out, gpa, input[i + 1 .. end]);
                try append(&out, gpa, "</code>");
                i = end + 1;
                continue;
            }
        }
        if (i + 1 < input.len and input[i] == '!' and input[i + 1] == '[') {
            if (std.mem.indexOf(u8, input[i + 2 ..], "](")) |mid_rel| {
                const mid = i + 2 + mid_rel;
                if (std.mem.indexOfScalarPos(u8, input, mid + 2, ')')) |end| {
                    try append(&out, gpa, "<img alt=\"");
                    try htmlEscape(&out, gpa, input[i + 2 .. mid]);
                    try append(&out, gpa, "\" src=\"");
                    try htmlEscape(&out, gpa, input[mid + 2 .. end]);
                    try append(&out, gpa, "\">");
                    i = end + 1;
                    continue;
                }
            }
        }
        if (input[i] == '[') {
            if (std.mem.indexOf(u8, input[i + 1 ..], "](")) |mid_rel| {
                const mid = i + 1 + mid_rel;
                if (std.mem.indexOfScalarPos(u8, input, mid + 2, ')')) |end| {
                    try append(&out, gpa, "<a href=\"");
                    try htmlEscape(&out, gpa, input[mid + 2 .. end]);
                    try append(&out, gpa, "\">");
                    const label = try inlineRender(gpa, input[i + 1 .. mid]);
                    try append(&out, gpa, label);
                    try append(&out, gpa, "</a>");
                    i = end + 1;
                    continue;
                }
            }
        }
        const Mark = struct { token: []const u8, open: []const u8, close: []const u8 };
        const marks = [_]Mark{ .{ .token = "**", .open = "<strong>", .close = "</strong>" }, .{ .token = "__", .open = "<strong>", .close = "</strong>" }, .{ .token = "~~", .open = "<del>", .close = "</del>" }, .{ .token = "*", .open = "<em>", .close = "</em>" }, .{ .token = "_", .open = "<em>", .close = "</em>" } };
        var marked = false;
        for (marks) |mark| {
            if (!std.mem.startsWith(u8, input[i..], mark.token)) continue;
            if (std.mem.indexOf(u8, input[i + mark.token.len ..], mark.token)) |rel| {
                const end = i + mark.token.len + rel;
                try append(&out, gpa, mark.open);
                try append(&out, gpa, try inlineRender(gpa, input[i + mark.token.len .. end]));
                try append(&out, gpa, mark.close);
                i = end + mark.token.len;
                marked = true;
                break;
            }
        }
        if (marked) continue;
        switch (input[i]) {
            '&' => try append(&out, gpa, "&amp;"),
            '>' => try append(&out, gpa, "&gt;"),
            else => try out.append(gpa, input[i]),
        }
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn slugify(gpa: Allocator, text_value: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var dash = false;
    var in_tag = false;
    for (text_value) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag or c == '`' or c == '*' or c == '_' or c == '~') continue;
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 0) try out.append(gpa, '-');
            try out.append(gpa, std.ascii.toLower(c));
            dash = false;
        } else if (c >= 0x80) {
            if (dash and out.items.len > 0) try out.append(gpa, '-');
            try out.append(gpa, c);
            dash = false;
        } else if (out.items.len > 0) dash = true;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

fn highlight(gpa: Allocator, code: []const u8, language: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const keywords = [_][]const u8{ "const", "var", "fn", "pub", "try", "catch", "return", "if", "else", "for", "while", "switch", "struct", "enum", "union", "error", "defer", "async", "await", "function", "class", "new", "throw", "import", "export", "from", "void", "bool", "true", "false", "null", "undefined", "int", "double", "size_t" };
    var i: usize = 0;
    while (i < code.len) {
        const shell_comment = (std.mem.eql(u8, language, "sh") or std.mem.eql(u8, language, "bash")) and code[i] == '#';
        if (shell_comment or (i + 1 < code.len and code[i] == '/' and code[i + 1] == '/')) {
            const end = std.mem.indexOfScalarPos(u8, code, i, '\n') orelse code.len;
            try append(&out, gpa, "<span class=\"tok-comment\">");
            try htmlEscape(&out, gpa, code[i..end]);
            try append(&out, gpa, "</span>");
            i = end;
            continue;
        }
        if (code[i] == '"' or code[i] == '\'') {
            const quote = code[i];
            var end = i + 1;
            while (end < code.len) : (end += 1) if (code[end] == quote and code[end - 1] != '\\') {
                end += 1;
                break;
            };
            try append(&out, gpa, "<span class=\"tok-string\">");
            try htmlEscape(&out, gpa, code[i..@min(end, code.len)]);
            try append(&out, gpa, "</span>");
            i = @min(end, code.len);
            continue;
        }
        if (std.ascii.isDigit(code[i])) {
            var end = i + 1;
            while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or code[end] == '.' or code[end] == '_')) : (end += 1) {}
            try append(&out, gpa, "<span class=\"tok-number\">");
            try htmlEscape(&out, gpa, code[i..end]);
            try append(&out, gpa, "</span>");
            i = end;
            continue;
        }
        if (std.ascii.isAlphabetic(code[i]) or code[i] == '_') {
            var end = i + 1;
            while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or code[end] == '_')) : (end += 1) {}
            var is_keyword = false;
            for (keywords) |keyword| if (std.mem.eql(u8, code[i..end], keyword)) {
                is_keyword = true;
                break;
            };
            if (is_keyword) try append(&out, gpa, "<span class=\"tok-keyword\">");
            try htmlEscape(&out, gpa, code[i..end]);
            if (is_keyword) try append(&out, gpa, "</span>");
            i = end;
            continue;
        }
        try htmlEscape(&out, gpa, code[i .. i + 1]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```");
}
fn isHeading(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    var n: usize = 0;
    while (n < trimmed.len and trimmed[n] == '#') : (n += 1) {}
    return n > 0 and n <= 6 and n < trimmed.len and trimmed[n] == ' ';
}
fn listInfo(line: []const u8) ?struct { indent: usize, ordered: bool, content: []const u8 } {
    const trimmed = std.mem.trimStart(u8, line, " ");
    const indent = line.len - trimmed.len;
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') return .{ .indent = indent, .ordered = false, .content = trimmed[2..] };
    var n: usize = 0;
    while (n < trimmed.len and std.ascii.isDigit(trimmed[n])) : (n += 1) {}
    if (n > 0 and n + 1 < trimmed.len and trimmed[n] == '.' and trimmed[n + 1] == ' ') return .{ .indent = indent, .ordered = true, .content = trimmed[n + 2 ..] };
    return null;
}
fn tableSeparator(line: []const u8) bool {
    var saw_dash = false;
    for (std.mem.trim(u8, line, " |\t")) |c| switch (c) {
        '-', ':', '|', ' ' => if (c == '-') {
            saw_dash = true;
        },
        else => return false,
    };
    return saw_dash;
}
fn blockStart(lines: []const []const u8, i: usize) bool {
    const line = lines[i];
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or isFence(line) or isHeading(line) or listInfo(line) != null or std.mem.startsWith(u8, t, ">") or std.mem.startsWith(u8, t, ":::") or std.mem.startsWith(u8, t, "<") or std.mem.eql(u8, t, "---")) return true;
    return t[0] == '|' and i + 1 < lines.len and tableSeparator(lines[i + 1]);
}

fn renderList(gpa: Allocator, lines: []const []const u8, index: *usize, base_indent: usize, out: *std.ArrayListUnmanaged(u8)) !void {
    const first = listInfo(lines[index.*]).?;
    const tag = if (first.ordered) "ol" else "ul";
    try print(out, gpa, "<{s}>", .{tag});
    while (index.* < lines.len) {
        const info = listInfo(lines[index.*]) orelse break;
        if (info.indent < base_indent or info.ordered != first.ordered) break;
        if (info.indent > base_indent) {
            try renderList(gpa, lines, index, info.indent, out);
            continue;
        }
        try append(out, gpa, "<li>");
        try append(out, gpa, try inlineRender(gpa, info.content));
        index.* += 1;
        while (index.* < lines.len) {
            if (listInfo(lines[index.*])) |nested| {
                if (nested.indent > base_indent) {
                    try renderList(gpa, lines, index, nested.indent, out);
                    continue;
                }
            }
            break;
        }
        try append(out, gpa, "</li>\n");
    }
    try print(out, gpa, "</{s}>\n", .{tag});
}

fn splitTableRow(gpa: Allocator, line: []const u8) ![][]const u8 {
    var cells: std.ArrayListUnmanaged([]const u8) = .empty;
    var raw = std.mem.trim(u8, line, " \t\r");
    if (raw.len > 0 and raw[0] == '|') raw = raw[1..];
    if (raw.len > 0 and raw[raw.len - 1] == '|') raw = raw[0 .. raw.len - 1];
    var parts = std.mem.splitScalar(u8, raw, '|');
    while (parts.next()) |cell| try cells.append(gpa, std.mem.trim(u8, cell, " \t"));
    return cells.toOwnedSlice(gpa);
}

fn renderMarkdown(gpa: Allocator, input: []const u8, headings: *std.ArrayListUnmanaged(Heading)) ![]const u8 {
    var line_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, input, '\n');
    while (iterator.next()) |line| try line_list.append(gpa, std.mem.trimEnd(u8, line, "\r"));
    const lines = line_list.items;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) {
            i += 1;
            continue;
        }
        if (isFence(line)) {
            const fence = std.mem.trimStart(u8, line, " \t");
            var language = std.mem.trim(u8, fence[3..], " \t");
            var label: []const u8 = "";
            if (std.mem.indexOfScalar(u8, language, '[')) |at| {
                if (std.mem.endsWith(u8, language, "]")) {
                    label = language[at + 1 .. language.len - 1];
                    language = std.mem.trimEnd(u8, language[0..at], " \t");
                }
            }
            i += 1;
            var code: std.ArrayListUnmanaged(u8) = .empty;
            while (i < lines.len and !isFence(lines[i])) : (i += 1) {
                try append(&code, gpa, lines[i]);
                try code.append(gpa, '\n');
            }
            if (i >= lines.len) return error.UnclosedCodeFence;
            i += 1;
            try append(&out, gpa, "<pre data-language=\"");
            try htmlEscape(&out, gpa, language);
            try append(&out, gpa, "\"><code>");
            if (label.len > 0) {
                try append(&out, gpa, "<span class=\"code-label\">");
                try htmlEscape(&out, gpa, label);
                try append(&out, gpa, "</span>");
            }
            try append(&out, gpa, try highlight(gpa, code.items, language));
            try append(&out, gpa, "</code></pre>\n");
            continue;
        }
        if (std.mem.startsWith(u8, t, ":::")) {
            const spec = std.mem.trim(u8, t[3..], " \t");
            i += 1;
            var inner: std.ArrayListUnmanaged(u8) = .empty;
            while (i < lines.len and !std.mem.eql(u8, std.mem.trim(u8, lines[i], " \t\r"), ":::")) : (i += 1) {
                try append(&inner, gpa, lines[i]);
                try inner.append(gpa, '\n');
            }
            if (i >= lines.len) return error.UnclosedContainer;
            i += 1;
            if (std.mem.eql(u8, spec, "code-group")) {
                try append(&out, gpa, "<div class=\"code-group\">\n");
                try append(&out, gpa, try renderMarkdown(gpa, inner.items, headings));
                try append(&out, gpa, "</div>\n");
            } else {
                const space = std.mem.indexOfScalar(u8, spec, ' ');
                const kind = if (space) |at| spec[0..at] else spec;
                const title = if (space) |at| spec[at + 1 ..] else kind;
                try append(&out, gpa, "<aside class=\"admonition ");
                try htmlEscape(&out, gpa, kind);
                try append(&out, gpa, "\"><div class=\"admonition-title\">");
                try htmlEscape(&out, gpa, title);
                try append(&out, gpa, "</div>");
                try append(&out, gpa, try renderMarkdown(gpa, inner.items, headings));
                try append(&out, gpa, "</aside>\n");
            }
            continue;
        }
        if (isHeading(line)) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            var level: usize = 0;
            while (trimmed[level] == '#') : (level += 1) {}
            const text_value = std.mem.trim(u8, trimmed[level + 1 ..], " \t#");
            const id = try slugify(gpa, text_value);
            try headings.append(gpa, .{ .level = @intCast(level), .text = text_value, .id = id });
            try print(&out, gpa, "<h{d} id=\"", .{level});
            try htmlEscape(&out, gpa, id);
            try append(&out, gpa, "\">");
            try append(&out, gpa, try inlineRender(gpa, text_value));
            try print(&out, gpa, "</h{d}>\n", .{level});
            i += 1;
            continue;
        }
        if (t[0] == '|' and i + 1 < lines.len and tableSeparator(lines[i + 1])) {
            const headers = try splitTableRow(gpa, line);
            i += 2;
            try append(&out, gpa, "<table><thead><tr>");
            for (headers) |cell| {
                try append(&out, gpa, "<th>");
                try append(&out, gpa, try inlineRender(gpa, cell));
                try append(&out, gpa, "</th>");
            }
            try append(&out, gpa, "</tr></thead><tbody>\n");
            while (i < lines.len and std.mem.startsWith(u8, std.mem.trimStart(u8, lines[i], " \t"), "|")) : (i += 1) {
                const cells = try splitTableRow(gpa, lines[i]);
                try append(&out, gpa, "<tr>");
                for (cells) |cell| {
                    try append(&out, gpa, "<td>");
                    try append(&out, gpa, try inlineRender(gpa, cell));
                    try append(&out, gpa, "</td>");
                }
                try append(&out, gpa, "</tr>\n");
            }
            try append(&out, gpa, "</tbody></table>\n");
            continue;
        }
        if (listInfo(line)) |info| {
            try renderList(gpa, lines, &i, info.indent, &out);
            continue;
        }
        if (std.mem.startsWith(u8, t, ">")) {
            var quoted: std.ArrayListUnmanaged(u8) = .empty;
            var alert_kind: []const u8 = "";
            i += 0;
            while (i < lines.len and std.mem.startsWith(u8, std.mem.trimStart(u8, lines[i], " \t"), ">")) : (i += 1) {
                var q = std.mem.trimStart(u8, std.mem.trimStart(u8, lines[i], " \t")[1..], " ");
                if (std.mem.startsWith(u8, q, "[!") and std.mem.endsWith(u8, q, "]")) alert_kind = q[2 .. q.len - 1] else {
                    try append(&quoted, gpa, q);
                    try quoted.append(gpa, '\n');
                }
            }
            if (alert_kind.len > 0) {
                try append(&out, gpa, "<aside class=\"admonition ");
                for (alert_kind) |c| try out.append(gpa, std.ascii.toLower(c));
                try append(&out, gpa, "\"><div class=\"admonition-title\">");
                try htmlEscape(&out, gpa, alert_kind);
                try append(&out, gpa, "</div>");
                try append(&out, gpa, try renderMarkdown(gpa, quoted.items, headings));
                try append(&out, gpa, "</aside>\n");
            } else {
                try append(&out, gpa, "<blockquote>");
                try append(&out, gpa, try renderMarkdown(gpa, quoted.items, headings));
                try append(&out, gpa, "</blockquote>\n");
            }
            continue;
        }
        if (std.mem.eql(u8, t, "---")) {
            try append(&out, gpa, "<hr>\n");
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, t, "<")) {
            try append(&out, gpa, line);
            try out.append(gpa, '\n');
            i += 1;
            continue;
        }
        var paragraph: std.ArrayListUnmanaged(u8) = .empty;
        while (i < lines.len and !blockStart(lines, i)) : (i += 1) {
            if (paragraph.items.len > 0) try paragraph.append(gpa, ' ');
            try append(&paragraph, gpa, std.mem.trim(u8, lines[i], " \t\r"));
        }
        try append(&out, gpa, "<p>");
        try append(&out, gpa, try inlineRender(gpa, paragraph.items));
        try append(&out, gpa, "</p>\n");
    }
    return out.toOwnedSlice(gpa);
}

fn renderNav(gpa: Allocator, config: SiteConfig, route: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    try append(out, gpa, "<nav class=\"nav\"><div class=\"nav-inner\"><a class=\"brand\" href=\"/\">zig-js</a><div class=\"nav-links\">");
    for (config.nav) |item| {
        try append(out, gpa, "<a href=\"");
        try htmlEscape(out, gpa, item.link);
        try append(out, gpa, if (std.mem.startsWith(u8, route, item.link)) "\" class=\"active\">" else "\">");
        try htmlEscape(out, gpa, item.text);
        try append(out, gpa, "</a>");
    }
    try append(out, gpa, "</div><div class=\"search\"><input data-search type=\"search\" aria-label=\"Search documentation\" placeholder=\"Search docs…\"><div class=\"search-results\" data-search-results></div></div></div></nav>");
}

fn renderSidebar(gpa: Allocator, config: SiteConfig, route: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    try append(out, gpa, "<aside class=\"sidebar\" aria-label=\"Documentation\">");
    for (config.sidebar) |section| {
        try append(out, gpa, "<section><h2>");
        try htmlEscape(out, gpa, section.text);
        try append(out, gpa, "</h2>");
        for (section.items) |item| {
            try append(out, gpa, "<a href=\"");
            try htmlEscape(out, gpa, item.link);
            try append(out, gpa, if (std.mem.eql(u8, route, item.link)) "\" class=\"active\">" else "\">");
            try htmlEscape(out, gpa, item.text);
            try append(out, gpa, "</a>");
        }
        try append(out, gpa, "</section>");
    }
    try append(out, gpa, "</aside>");
}

fn renderToc(gpa: Allocator, headings: []const Heading, out: *std.ArrayListUnmanaged(u8)) !void {
    try append(out, gpa, "<aside class=\"toc\"><h2>On this page</h2>");
    for (headings) |heading| if (heading.level == 2 or heading.level == 3) {
        try append(out, gpa, "<a class=\"level-");
        try print(out, gpa, "{d}\" href=\"#", .{heading.level});
        try htmlEscape(out, gpa, heading.id);
        try append(out, gpa, "\">");
        try htmlEscape(out, gpa, heading.text);
        try append(out, gpa, "</a>");
    };
    try append(out, gpa, "</aside>");
}

fn renderHead(gpa: Allocator, config: SiteConfig, meta: Meta, route: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    const description = if (meta.description.len > 0) meta.description else config.description;
    try append(out, gpa, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try htmlEscape(out, gpa, meta.title);
    if (!std.mem.eql(u8, meta.title, config.title)) {
        try append(out, gpa, " · ");
        try htmlEscape(out, gpa, config.title);
    }
    try append(out, gpa, "</title><meta name=\"description\" content=\"");
    try htmlEscape(out, gpa, description);
    try append(out, gpa, "\"><meta name=\"generator\" content=\"zig-js-docs/1\"><link rel=\"canonical\" href=\"");
    try htmlEscape(out, gpa, config.base_url);
    try htmlEscape(out, gpa, route);
    try append(out, gpa, "\"><meta property=\"og:type\" content=\"website\"><meta property=\"og:title\" content=\"");
    try htmlEscape(out, gpa, meta.title);
    try append(out, gpa, "\"><meta property=\"og:description\" content=\"");
    try htmlEscape(out, gpa, description);
    try append(out, gpa, "\"><link rel=\"stylesheet\" href=\"/style.css\"><script defer src=\"/app.js\"></script></head><body><a class=\"skip\" href=\"#content\">Skip to content</a>");
}

fn renderPage(gpa: Allocator, config: SiteConfig, meta: Meta, route: []const u8, body: []const u8, headings: []const Heading) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try renderHead(gpa, config, meta, route, &out);
    try renderNav(gpa, config, route, &out);
    if (meta.layout_home) {
        try append(&out, gpa, "<header class=\"hero\"><div class=\"hero-inner\"><h1>");
        try htmlEscape(&out, gpa, meta.hero_name);
        try append(&out, gpa, "</h1><div class=\"hero-text\">");
        try htmlEscape(&out, gpa, meta.hero_text);
        try append(&out, gpa, "</div><p class=\"hero-tagline\">");
        try htmlEscape(&out, gpa, meta.hero_tagline);
        try append(&out, gpa, "</p><div class=\"hero-actions\"><a class=\"button brand\" href=\"/guide/\">Get Started →</a><a class=\"button\" href=\"/architecture\">Architecture</a></div></div></header><main id=\"content\" class=\"doc home-layout\">");
        try append(&out, gpa, body);
        try append(&out, gpa, "</main>");
    } else {
        try append(&out, gpa, "<div class=\"layout\">");
        try renderSidebar(gpa, config, route, &out);
        try append(&out, gpa, "<main id=\"content\" class=\"doc\">");
        try append(&out, gpa, body);
        try append(&out, gpa, "</main>");
        try renderToc(gpa, headings, &out);
        try append(&out, gpa, "</div>");
    }
    try append(&out, gpa, "<footer class=\"footer\">Built offline by the repository-owned Zig documentation tool.</footer></body></html>\n");
    return out.toOwnedSlice(gpa);
}

fn plainSearchText(gpa: Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var in_tag = false;
    var space = false;
    for (source) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            space = true;
            continue;
        }
        if (in_tag) continue;
        if (std.ascii.isAlphanumeric(c) or c >= 0x80) {
            if (space and out.items.len > 0) try out.append(gpa, ' ');
            try out.append(gpa, std.ascii.toLower(c));
            space = false;
        } else space = true;
    }
    return out.toOwnedSlice(gpa);
}

fn normalizeRepoPath(gpa: Allocator, base: []const u8, target: []const u8) ![]const u8 {
    const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, target });
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, joined, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (segments.items.len == 0) return error.LinkEscapesRepository;
            _ = segments.pop();
        } else try segments.append(gpa, part);
    }
    return std.mem.join(gpa, "/", segments.items);
}

fn siteLink(gpa: Allocator, source: []const u8, target: []const u8) ![]const u8 {
    if (target.len == 0 or target[0] == '/' or target[0] == '#' or std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "mailto:") or std.mem.startsWith(u8, target, "data:")) return target;
    const suffix_at = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const path_part = target[0..suffix_at];
    const suffix = target[suffix_at..];
    const source_path = try std.fmt.allocPrint(gpa, "docs/{s}", .{source});
    const base = std.fs.path.dirname(source_path) orelse "docs";
    const normalized = try normalizeRepoPath(gpa, base, path_part);
    if (std.mem.startsWith(u8, normalized, "docs/")) {
        const docs_relative = normalized["docs/".len..];
        if (std.mem.endsWith(u8, docs_relative, ".md") and !std.mem.startsWith(u8, docs_relative, ".data/")) {
            const route = try routeFor(gpa, docs_relative);
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ route, suffix });
        }
        return std.fmt.allocPrint(gpa, "/{s}{s}", .{ docs_relative, suffix });
    }
    return std.fmt.allocPrint(gpa, "https://github.com/zig-utils/zig-js/blob/main/{s}{s}", .{ normalized, suffix });
}

fn rewriteRelativeLinks(gpa: Allocator, html: []const u8, source: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var rest = html;
    while (true) {
        const href_at = std.mem.indexOf(u8, rest, "href=\"");
        const src_at = std.mem.indexOf(u8, rest, "src=\"");
        const at = if (href_at) |h| if (src_at) |s| @min(h, s) else h else src_at orelse break;
        const marker_len: usize = if (href_at != null and at == href_at.?) "href=\"".len else "src=\"".len;
        try append(&out, gpa, rest[0 .. at + marker_len]);
        const end = std.mem.indexOfScalarPos(u8, rest, at + marker_len, '"') orelse return error.InvalidRenderedLink;
        try append(&out, gpa, try siteLink(gpa, source, rest[at + marker_len .. end]));
        rest = rest[end..];
    }
    try append(&out, gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn recordOutput(gpa: Allocator, outputs: *std.ArrayListUnmanaged(Output), path: []const u8, data: []const u8) !void {
    try outputs.append(gpa, .{ .path = try gpa.dupe(u8, path["dist/".len..]), .sha256 = sha(data) });
}

fn buildManifest(gpa: Allocator, outputs: []Output, page_count: usize, asset_count: usize) ![]const u8 {
    std.mem.sort(Output, outputs, {}, lessOutput);
    var tree = std.crypto.hash.sha2.Sha256.init(.{});
    for (outputs) |item| {
        tree.update(item.path);
        tree.update(&.{0});
        tree.update(&item.sha256);
    }
    var tree_digest: [32]u8 = undefined;
    tree.final(&tree_digest);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try print(&out, gpa, "{{\n  \"schema_version\": 1,\n  \"page_count\": {d},\n  \"asset_count\": {d},\n  \"output_count\": {d},\n  \"tree_sha256\": \"{x}\",\n  \"outputs\": [\n", .{ page_count, asset_count, outputs.len, tree_digest });
    for (outputs, 0..) |item, i| {
        try append(&out, gpa, "    { \"path\": \"");
        try jsonEscape(&out, gpa, item.path);
        try print(&out, gpa, "\", \"sha256\": \"{x}\" }}{s}\n", .{ item.sha256, if (i + 1 == outputs.len) "" else "," });
    }
    try append(&out, gpa, "  ]\n}\n");
    return out.toOwnedSlice(gpa);
}

fn buildSite(gpa: Allocator, io: Io, update_manifest: bool) !void {
    const config_source = try read(gpa, io, "docs/site.json");
    const parsed_config = try std.json.parseFromSlice(SiteConfig, gpa, config_source, .{ .allocate = .alloc_always });
    if (parsed_config.value.schema_version != 1) return error.UnsupportedSiteSchema;
    const test262_source = try read(gpa, io, "docs/.data/test262.json");
    const wrapped_data = try std.fmt.allocPrint(gpa, "{{\"data\":{{\"test262\":{s}}}}}", .{test262_source});
    const parsed_data = try std.json.parseFromSlice(std.json.Value, gpa, wrapped_data, .{ .allocate = .alloc_always });
    const data = parsed_data.value;
    var pages: std.ArrayListUnmanaged(Page) = .empty;
    var assets: std.ArrayListUnmanaged([]const u8) = .empty;
    try discover(gpa, io, &pages, &assets);
    if (pages.items.len == 0) return error.NoDocumentationPages;
    Io.Dir.cwd().deleteTree(io, out_dir) catch |err| if (err != error.FileNotFound) return err;
    try Io.Dir.cwd().createDirPath(io, out_dir);
    var outputs: std.ArrayListUnmanaged(Output) = .empty;
    var search: std.ArrayListUnmanaged(u8) = .empty;
    try append(&search, gpa, "[\n");
    var sitemap: std.ArrayListUnmanaged(u8) = .empty;
    try append(&sitemap, gpa, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    for (pages.items, 0..) |page, page_index| {
        const source_path = try std.fmt.allocPrint(gpa, "docs/{s}", .{page.source});
        const source = try read(gpa, io, source_path);
        const parsed = parseMeta(source, page.route);
        const expanded = try preprocess(gpa, parsed.body, data);
        var headings: std.ArrayListUnmanaged(Heading) = .empty;
        const rendered_body = try renderMarkdown(gpa, expanded, &headings);
        const body = try rewriteRelativeLinks(gpa, rendered_body, page.source);
        const html = try renderPage(gpa, parsed_config.value, parsed.meta, page.route, body, headings.items);
        const target = try outputPathForRoute(gpa, page.route);
        try write(io, target, html);
        try recordOutput(gpa, &outputs, target, html);
        const description = if (parsed.meta.description.len > 0) parsed.meta.description else parsed_config.value.description;
        const search_text = try plainSearchText(gpa, expanded);
        try append(&search, gpa, "  { \"route\": \"");
        try jsonEscape(&search, gpa, page.route);
        try append(&search, gpa, "\", \"title\": \"");
        try jsonEscape(&search, gpa, parsed.meta.title);
        try append(&search, gpa, "\", \"description\": \"");
        try jsonEscape(&search, gpa, description);
        try append(&search, gpa, "\", \"search\": \"");
        try jsonEscape(&search, gpa, search_text);
        try print(&search, gpa, "\" }}{s}\n", .{if (page_index + 1 == pages.items.len) "" else ","});
        try append(&sitemap, gpa, "  <url><loc>");
        try htmlEscape(&sitemap, gpa, parsed_config.value.base_url);
        try htmlEscape(&sitemap, gpa, page.route);
        try append(&sitemap, gpa, "</loc></url>\n");
    }
    try append(&search, gpa, "]\n");
    try append(&sitemap, gpa, "</urlset>\n");
    for (assets.items) |asset| {
        const source_path = try std.fmt.allocPrint(gpa, "docs/{s}", .{asset});
        const target = try std.fmt.allocPrint(gpa, "dist/{s}", .{asset});
        const bytes = try read(gpa, io, source_path);
        try write(io, target, bytes);
        try recordOutput(gpa, &outputs, target, bytes);
    }
    const css = try read(gpa, io, "docs/site.css");
    try write(io, "dist/style.css", css);
    try recordOutput(gpa, &outputs, "dist/style.css", css);
    try write(io, "dist/app.js", app_js);
    try recordOutput(gpa, &outputs, "dist/app.js", app_js);
    try write(io, "dist/search.json", search.items);
    try recordOutput(gpa, &outputs, "dist/search.json", search.items);
    try write(io, "dist/sitemap.xml", sitemap.items);
    try recordOutput(gpa, &outputs, "dist/sitemap.xml", sitemap.items);
    const robots = "User-agent: *\nAllow: /\nSitemap: https://zig-js.dev/sitemap.xml\n";
    try write(io, "dist/robots.txt", robots);
    try recordOutput(gpa, &outputs, "dist/robots.txt", robots);
    const not_found = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Not found · zig-js</title><link rel=\"stylesheet\" href=\"/style.css\"></head><body><main class=\"doc home-layout\"><h1>404</h1><p>The requested documentation page does not exist.</p><p><a href=\"/\">Return home</a></p></main></body></html>\n";
    try write(io, "dist/404.html", not_found);
    try recordOutput(gpa, &outputs, "dist/404.html", not_found);
    for (parsed_config.value.redirects) |redirect| {
        const target = try outputPathForRoute(gpa, redirect.from);
        var redirect_html: std.ArrayListUnmanaged(u8) = .empty;
        try append(&redirect_html, gpa, "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=");
        try htmlEscape(&redirect_html, gpa, redirect.to);
        try append(&redirect_html, gpa, "\"><link rel=\"canonical\" href=\"");
        try htmlEscape(&redirect_html, gpa, parsed_config.value.base_url);
        try htmlEscape(&redirect_html, gpa, redirect.to);
        try append(&redirect_html, gpa, "\">\n");
        try write(io, target, redirect_html.items);
        try recordOutput(gpa, &outputs, target, redirect_html.items);
    }
    const manifest = try buildManifest(gpa, outputs.items, pages.items.len, assets.items.len);
    if (update_manifest) {
        try write(io, manifest_path, manifest);
        std.debug.print("docs manifest updated: {d} pages, {d} assets, {d} outputs\n", .{ pages.items.len, assets.items.len, outputs.items.len });
    } else {
        const expected = read(gpa, io, manifest_path) catch |err| {
            std.debug.print("docs: checked manifest missing; run 'zig build docs-manifest-update' ({t})\n", .{err});
            return error.DocsManifestMismatch;
        };
        if (!std.mem.eql(u8, expected, manifest)) {
            std.debug.print("docs: deterministic output manifest drifted; inspect the build and run 'zig build docs-manifest-update'\n", .{});
            return error.DocsManifestMismatch;
        }
        std.debug.print("docs build ok: {d} pages, {d} assets, {d} deterministic outputs\n", .{ pages.items.len, assets.items.len, outputs.items.len });
    }
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml; charset=utf-8";
    return "application/octet-stream";
}

fn acceptConnection(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);
    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    const raw_target = std.mem.sliceTo(request.head.target, '?');
    if (std.mem.indexOf(u8, raw_target, "..") != null) {
        request.respond("bad request\n", .{ .status = .bad_request }) catch {};
        return;
    }
    var relative = std.mem.trimStart(u8, raw_target, "/");
    if (relative.len == 0) relative = "index.html";
    var path_buf: [4096]u8 = undefined;
    var path = std.fmt.bufPrint(&path_buf, "dist/{s}", .{relative}) catch {
        request.respond("path too long\n", .{ .status = .uri_too_long }) catch {};
        return;
    };
    if (!std.mem.containsAtLeast(u8, std.fs.path.basename(path), 1, ".")) path = std.fmt.bufPrint(&path_buf, "dist/{s}/index.html", .{relative}) catch unreachable;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(max_file_bytes)) catch {
        const not_found = Io.Dir.cwd().readFileAlloc(io, "dist/404.html", std.heap.page_allocator, .limited(max_file_bytes)) catch {
            request.respond("not found\n", .{ .status = .not_found }) catch {};
            return;
        };
        defer std.heap.page_allocator.free(not_found);
        request.respond(not_found, .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} }) catch {};
        return;
    };
    defer std.heap.page_allocator.free(bytes);
    request.respond(bytes, .{ .extra_headers = &.{.{ .name = "content-type", .value = contentType(path) }} }) catch {};
}

fn preview(io: Io, port: u16) !void {
    const address = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const actual_port = server.socket.address.getPort();
    std.debug.print("docs preview: http://127.0.0.1:{d}/\n", .{actual_port});
    while (true) {
        const stream = try server.accept(io);
        acceptConnection(io, stream);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const command = args.next() orelse "build";
    if (std.mem.eql(u8, command, "build")) return buildSite(allocator, init.io, false);
    if (std.mem.eql(u8, command, "update-manifest")) return buildSite(allocator, init.io, true);
    if (std.mem.eql(u8, command, "preview")) {
        try buildSite(allocator, init.io, false);
        const port = if (args.next()) |value| try std.fmt.parseInt(u16, value, 10) else 4173;
        return preview(init.io, port);
    }
    std.debug.print("usage: docs-site [build|update-manifest|preview [port]]\n", .{});
    return error.UnknownCommand;
}
