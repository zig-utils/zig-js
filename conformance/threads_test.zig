//! Runner for the vendored WebKit PR-249 threads corpus
//! (reference/webkit-249/threads-tests/) against the Phase-6 Thread API —
//! `zig build threads-test`. Each file runs in a fresh `enable_threads`
//! Context with the corpus's own assert.js + harness.js preloaded (their
//! `load()` becomes a no-op; the files are read from the reference tree, not
//! copied — see reference/webkit-249/README.md licensing notes).
//!
//! The allowlist below is the green set; it grows as API surface lands.
//! Files needing machinery a GIL'd tree-walker structurally lacks (JIT/GC
//! stress, $vm hooks) stay reference-only.

const std = @import("std");
const js = @import("js");

const corpus_root = "reference/webkit-249/threads-tests";

const allowlist = [_][]const u8{
    "api/lock-basic.js",
    "api/threadlocal-basic.js",
    // "api/thread-restrict.js" — needs the ConcurrentAccessError global ctor
    // and the full restrict-validation matrix (globalThis/proxy/exotic
    // rejections); v1 restrict is the owner-tid field + get/set checks only.
    "atomics/property-load-store.js",
    "atomics/property-rmw.js",
    "atomics/property-cas-samevaluezero.js",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var dir = cwd.openDir(io, corpus_root, .{}) catch {
        std.debug.print("threads-test: corpus not found at {s} (run from the repo root)\n", .{corpus_root});
        return error.CorpusMissing;
    };
    defer dir.close(io);

    const assert_src = try dir.readFileAlloc(io, "resources/assert.js", gpa, .limited(1 << 20));
    defer gpa.free(assert_src);
    const harness_src = try dir.readFileAlloc(io, "harness.js", gpa, .limited(1 << 20));
    defer gpa.free(harness_src);

    var failed: usize = 0;
    for (allowlist) |name| {
        const test_src = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch {
            std.debug.print("  MISS  {s}\n", .{name});
            failed += 1;
            continue;
        };
        defer gpa.free(test_src);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(gpa);
        // Their `load(path)` becomes a no-op: everything it would pull in is
        // concatenated below in dependency order.
        try buf.appendSlice(gpa, "const load = () => {};\n");
        try buf.appendSlice(gpa, assert_src);
        try buf.appendSlice(gpa, "\n");
        try buf.appendSlice(gpa, harness_src);
        try buf.appendSlice(gpa, "\n");
        try buf.appendSlice(gpa, test_src);

        const ctx = js.Context.createWith(gpa, .{ .enable_threads = true }) catch {
            std.debug.print("  FAIL  {s} (context)\n", .{name});
            failed += 1;
            continue;
        };
        defer ctx.destroy();
        if (ctx.evaluate(buf.items)) |_| {
            std.debug.print("  PASS  {s}\n", .{name});
        } else |_| {
            failed += 1;
            // Stringifying the exception can run JS (Error.prototype.toString):
            // hold the GIL like any other entry into the realm.
            if (ctx.gil) |g| g.acquire();
            const msg = if (ctx.exception) |e| descr: {
                var machine = ctx.interpreter();
                break :descr machine.toStringV(e) catch "?";
            } else "?";
            std.debug.print("  FAIL  {s}: {s}\n", .{ name, msg });
            if (ctx.gil) |g| g.release();
        }
    }
    std.debug.print("------------------------\n{d}/{d} corpus files passed\n", .{ allowlist.len - failed, allowlist.len });
    if (failed != 0) return error.CorpusFailures;
}
