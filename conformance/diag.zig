//! THROWAWAY diagnostic. Two modes over the test262 `test/language` tree:
//!   (default)  parse-only: prints `err<TAB>tokKind<TAB>snippet<TAB>path` for
//!              every parse failure.
//!   `run`      full eval: prints `name<TAB>message` for every runtime throw, so
//!              the highest-leverage missing builtin/semantic is found via
//!              `| sort | uniq -c | sort -rn`. Tests with `includes:` are skipped
//!              in run-mode (their harness helpers aren't loaded), to cut noise.
//! Delete after use.

const std = @import("std");
const js = @import("js");
const build_options = @import("build_options");
const Parser = js.Parser;

const harness_shim =
    \\function Test262Error(message) { this.message = message || ""; this.name = "Test262Error"; }
    \\Test262Error.thrower = function (message) { throw new Test262Error(message); };
    \\function $ERROR(message) { throw new Test262Error(message); }
    \\function $DONOTEVALUATE() { throw "Test262: This statement should not be evaluated."; }
    \\var assert = function (m, msg) { if (m === true) return; throw new Test262Error(msg || "Expected true"); };
    \\assert._isSameValue = function (a, b) { if (a === b) return a !== 0 || 1 / a === 1 / b; return a !== a && b !== b; };
    \\assert.sameValue = function (a, e, msg) { if (assert._isSameValue(a, e)) return; throw new Test262Error(msg || "SameValue"); };
    \\assert.notSameValue = function (a, u, msg) { if (!assert._isSameValue(a, u)) return; throw new Test262Error(msg || "NotSameValue"); };
    \\assert.throws = function (E, fn, msg) { try { fn(); } catch (t) { return; } throw new Test262Error(msg || "Expected throw"); };
    \\
;

const Meta = struct {
    skip: bool = false,
    negative: bool = false,
    raw: bool = false,
    only_strict: bool = false,
    includes: [12][]const u8 = undefined,
    includes_n: usize = 0,
};

fn parseMeta(src: []const u8) Meta {
    var meta: Meta = .{};
    const start = std.mem.indexOf(u8, src, "/*---") orelse return meta;
    const end_rel = std.mem.indexOf(u8, src[start..], "---*/") orelse return meta;
    const front = src[start .. start + end_rel];
    if (std.mem.indexOf(u8, front, "flags:")) |fi| {
        const le = std.mem.indexOfScalarPos(u8, front, fi, '\n') orelse front.len;
        const flags = front[fi..le];
        if (std.mem.indexOf(u8, flags, "module") != null or
            std.mem.indexOf(u8, flags, "async") != null) meta.skip = true;
        if (std.mem.indexOf(u8, flags, "raw") != null) meta.raw = true;
        if (std.mem.indexOf(u8, flags, "onlyStrict") != null) meta.only_strict = true;
    }
    meta.negative = std.mem.indexOf(u8, front, "negative:") != null;
    if (std.mem.indexOf(u8, front, "includes:")) |ii| {
        const after = front[ii + "includes:".len ..];
        const nl = std.mem.indexOfScalar(u8, after, '\n') orelse after.len;
        if (std.mem.indexOfScalar(u8, after, '[')) |lb| {
            if (lb < nl) {
                const rb = std.mem.indexOfScalarPos(u8, after, lb, ']') orelse after.len;
                var it = std.mem.tokenizeAny(u8, after[lb + 1 .. rb], ", \t\r");
                while (it.next()) |name| {
                    if (meta.includes_n < meta.includes.len) {
                        meta.includes[meta.includes_n] = name;
                        meta.includes_n += 1;
                    }
                }
            }
        }
    }
    return meta;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const root = build_options.root;
    const sub = "test/language";

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const run_mode = if (args.next()) |m| std.mem.eql(u8, m, "run") else false;
    // Optional third arg overrides the subtree (e.g. `test/built-ins/Symbol`).
    const subtree = args.next() orelse sub;

    const path = try std.fs.path.join(gpa, &.{ root, subtree });
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch {
        std.debug.print("missing {s}\n", .{path});
        return;
    };
    defer dir.close(io);

    const out = std.Io.File.stdout();
    var wbuf: [4096]u8 = undefined;

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;

        const src = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(src);
        const meta = parseMeta(src);
        if (meta.skip or meta.negative or meta.raw) continue;

        if (run_mode) {
            runOne(gpa, io, root, out, &wbuf, src, meta, entry.path);
        } else {
            parseOne(gpa, out, io, &wbuf, src, entry.path);
        }
    }
}

fn readHarness(gpa: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) ?[]const u8 {
    const hpath = std.fs.path.join(gpa, &.{ root, "harness", name }) catch return null;
    defer gpa.free(hpath);
    return std.Io.Dir.cwd().readFileAlloc(io, hpath, gpa, .limited(1 << 20)) catch null;
}

fn runOne(gpa: std.mem.Allocator, io: std.Io, root: []const u8, out: std.Io.File, buf: []u8, src: []const u8, meta: Meta, path: []const u8) void {
    var full: std.ArrayListUnmanaged(u8) = .empty;
    defer full.deinit(gpa);
    // Match the runner: onlyStrict tests run as strict-mode code.
    if (meta.only_strict) full.appendSlice(gpa, "\"use strict\";\n") catch return;
    // Prefer the real upstream harness (sta.js + assert.js) so the diagnostic
    // matches the runner; fall back to the shim if they can't be read.
    if (readHarness(gpa, io, root, "sta.js")) |sta| {
        defer gpa.free(sta);
        if (readHarness(gpa, io, root, "assert.js")) |ass| {
            defer gpa.free(ass);
            full.appendSlice(gpa, sta) catch return;
            full.append(gpa, '\n') catch return;
            full.appendSlice(gpa, ass) catch return;
            full.append(gpa, '\n') catch return;
        } else full.appendSlice(gpa, harness_shim) catch return;
    } else full.appendSlice(gpa, harness_shim) catch return;
    // Prepend any `includes:` harness files (propertyHelper, compareArray, …).
    var i: usize = 0;
    while (i < meta.includes_n) : (i += 1) {
        const hpath = std.fs.path.join(gpa, &.{ root, "harness", meta.includes[i] }) catch return;
        defer gpa.free(hpath);
        const inc = std.Io.Dir.cwd().readFileAlloc(io, hpath, gpa, .limited(1 << 20)) catch return; // unloadable → skip
        defer gpa.free(inc);
        full.appendSlice(gpa, inc) catch return;
        full.append(gpa, '\n') catch return;
    }
    full.appendSlice(gpa, src) catch return;

    const ctx = js.Context.create(gpa) catch return;
    defer ctx.destroy();
    if (ctx.evaluate(full.items)) |_| {
        // pass — nothing to report
    } else |err| {
        if (err != error.Throw) return; // parse errors are the other mode's job
        var name: []const u8 = "?";
        var msg: []const u8 = "";
        if (ctx.exception) |ex| {
            if (ex == .object) {
                const o = ex.object;
                if (o.error_name.len > 0) name = o.error_name;
                if (o.getOwn("name")) |nv| {
                    if (nv == .string) name = nv.string;
                }
                if (o.getOwn("message")) |mv| {
                    if (mv == .string) msg = mv.string;
                }
            } else if (ex == .string) {
                name = "(string)";
                msg = ex.string;
            } else name = @tagName(ex);
        }
        emit2(out, io, buf, name, msg, path);
    }
}

fn parseOne(gpa: std.mem.Allocator, out: std.Io.File, io: std.Io, buf: []u8, src: []const u8, path: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = Parser.init(a, src) catch |e| {
        var lx = js.Lexer.init(a, src);
        while (true) {
            _ = lx.next() catch break;
            if (lx.i >= src.len) break;
        }
        var ctxbuf: [16]u8 = undefined;
        const lo = lx.i -| 1;
        const hi = @min(lo + 4, src.len);
        var k: usize = 0;
        var j = lo;
        while (j < hi and k + 4 < ctxbuf.len) : (j += 1) {
            k += (std.fmt.bufPrint(ctxbuf[k..], "{x:0>2} ", .{src[j]}) catch break).len;
        }
        const line = std.fmt.bufPrint(buf, "{s}\tlex\t{s}\t{s}\n", .{ @errorName(e), ctxbuf[0..k], path }) catch return;
        out.writeStreamingAll(io, line) catch {};
        return;
    };
    _ = parser.parseProgram() catch |e| {
        const tok = parser.tokens[parser.pos];
        const n = @min(tok.text.len, 24);
        const line = std.fmt.bufPrint(buf, "{s}\t{s}\t{s}\t{s}\n", .{ @errorName(e), @tagName(tok.kind), tok.text[0..n], path }) catch return;
        out.writeStreamingAll(io, line) catch {};
    };
}

fn emit2(out: std.Io.File, io: std.Io, buf: []u8, name: []const u8, msg: []const u8, path: []const u8) void {
    var clean: [60]u8 = undefined;
    var n: usize = 0;
    for (msg) |c| {
        if (n >= clean.len) break;
        clean[n] = if (c == '\n' or c == '\t' or c == '\r') ' ' else c;
        n += 1;
    }
    const line = std.fmt.bufPrint(buf, "{s}\t{s}\t{s}\n", .{ name, clean[0..n], path }) catch return;
    out.writeStreamingAll(io, line) catch {};
}
