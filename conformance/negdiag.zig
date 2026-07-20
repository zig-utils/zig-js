//! THROWAWAY negative-axis diagnostic. Walks a test262 subtree and, for every
//! `negative:` test whose `phase:` is `parse`, tries to PARSE it with the same
//! `Parser.parseProgram` entry `Context.evaluate` uses (prepending `"use strict"`
//! for `onlyStrict`). A phase:parse test MUST be an early SyntaxError, so any
//! test that parses WITHOUT error is a MISSING early error — the tool prints its
//! path. Usage: `negdiag [subtree]` (default `test/language`). Cluster with:
//!   negdiag | sed 's#/[^/]*$##' | sort | uniq -c | sort -rn
//! Delete after use.

const std = @import("std");
const js = @import("js");
const build_options = @import("build_options");
const Parser = js.Parser;

const Meta = struct {
    negative_parse: bool = false,
    only_strict: bool = false,
    module: bool = false,
    neg_type: []const u8 = "",
};

fn parseMeta(src: []const u8) Meta {
    var m: Meta = .{};
    const start = std.mem.indexOf(u8, src, "/*---") orelse return m;
    const end_rel = std.mem.indexOf(u8, src[start..], "---*/") orelse return m;
    const front = src[start .. start + end_rel];
    if (std.mem.indexOf(u8, front, "flags:")) |fi| {
        const flags = flagsRegion(front, fi); // handles both `[a, b]` and multi-line `- a` forms
        if (std.mem.indexOf(u8, flags, "onlyStrict") != null) m.only_strict = true;
        if (std.mem.indexOf(u8, flags, "module") != null) m.module = true;
    }
    if (std.mem.indexOf(u8, front, "negative:") != null) {
        if (std.mem.indexOf(u8, front, "phase: parse") != null or
            std.mem.indexOf(u8, front, "phase:parse") != null) m.negative_parse = true;
        if (std.mem.indexOf(u8, front, "type:")) |ti| {
            const after = front[ti + "type:".len ..];
            const le = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
            m.neg_type = std.mem.trim(u8, after[0..le], " \t\r");
        }
    }
    return m;
}

/// Extract the `flags:` value region, covering both the inline `[a, b]` form and
/// the multi-line YAML list (`flags:` then `  - a` lines). Ported from diag.zig.
fn flagsRegion(front: []const u8, fi: usize) []const u8 {
    const line_end = std.mem.indexOfScalarPos(u8, front, fi, '\n') orelse front.len;
    const line = front[fi..line_end];
    if (std.mem.indexOfScalar(u8, line, '[') != null) {
        const flags_end = if (std.mem.indexOfScalar(u8, line, ']') == null)
            (std.mem.indexOfScalarPos(u8, front, line_end, ']') orelse line_end) + 1
        else
            line_end;
        return front[fi..flags_end];
    }
    var end = line_end;
    var pos = if (line_end < front.len) line_end + 1 else line_end;
    while (pos < front.len) {
        const next = std.mem.indexOfScalarPos(u8, front, pos, '\n') orelse front.len;
        var t = front[pos..next];
        while (t.len > 0 and (t[0] == ' ' or t[0] == '\t' or t[0] == '\r')) t = t[1..];
        if (t.len == 0 or t[0] == '-') {
            end = next;
            pos = if (next < front.len) next + 1 else next;
            continue;
        }
        break;
    }
    return front[fi..end];
}

/// True if `src` parses WITHOUT error under the given strictness — mirroring the
/// FULL engine oracle: `parseProgram`/`parseModule` PLUS the post-parse
/// `scanEvalContext` early-error scan that `Context.evaluate` applies (line 5706),
/// so we don't false-positive on errors caught by that scan (e.g. global `super`).
fn parsesClean(gpa: std.mem.Allocator, src: []const u8, strict: bool, module: bool) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (strict) buf.appendSlice(a, "\"use strict\";\n") catch return false;
    buf.appendSlice(a, src) catch return false;
    var parser = Parser.init(a, buf.items) catch return false;
    if (module) {
        _ = parser.parseModule() catch return false;
        return true;
    }
    const program = parser.parseProgram() catch return false;
    if (program.* == .program)
        parser.scanEvalContext(program.program, true, true) catch return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const root = build_options.root;
    const root_abs = try std.fs.path.resolve(gpa, &.{root});
    defer gpa.free(root_abs);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const subtree = args.next() orelse "test/language";

    const path = try std.fs.path.resolve(gpa, &.{ root_abs, subtree });
    defer gpa.free(path);

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        std.debug.print("missing {s}\n", .{path});
        return;
    };
    defer dir.close(io);

    const out = std.Io.File.stdout();
    var wbuf: [4096]u8 = undefined;

    var total: usize = 0;
    var missing: usize = 0;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;

        const src = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(src);
        const m = parseMeta(src);
        if (!m.negative_parse) continue;
        total += 1;

        // A phase:parse test must fail to parse in the mode the runner uses.
        // Default & noStrict → reject sloppy; onlyStrict → reject strict. If the
        // required mode parses clean, the early error is missing.
        if (parsesClean(gpa, src, m.only_strict, m.module)) {
            missing += 1;
            const line = std.fmt.bufPrint(&wbuf, "{s}\t{s}\t{s}\n", .{
                if (m.neg_type.len > 0) m.neg_type else "?",
                if (m.module) "module" else if (m.only_strict) "strict" else "sloppy",
                entry.path,
            }) catch continue;
            out.writeStreamingAll(io, line) catch {};
        }
    }
    var sbuf: [160]u8 = undefined;
    const summary = std.fmt.bufPrint(&sbuf, "# {d} missing / {d} negative-parse tests in {s}\n", .{ missing, total, subtree }) catch return;
    out.writeStreamingAll(io, summary) catch {};
}
