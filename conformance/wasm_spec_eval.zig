//! Evaluate one generated upstream WebAssembly specification script.
//!
//! The Python corpus driver owns WAST conversion and inventory generation; this
//! deliberately tiny executable keeps the measured engine path identical to an
//! ordinary zig-js Context and prints the script's final JSON string verbatim.

const std = @import("std");
const js = @import("js");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.MissingScriptPath;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(source);

    const ctx = try js.Context.createWithTestingOptions(gpa, .{ .wasm_spec_bit_exact = true });
    defer ctx.destroy();
    const result = ctx.evaluate(source) catch |err| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "evaluation failed: {s}\n", .{@errorName(err)}) catch "evaluation failed\n";
        std.Io.File.stderr().writeStreamingAll(io, line) catch {};
        return error.EvaluationFailed;
    };
    if (!result.isString()) return error.NonStringResult;
    try std.Io.File.stdout().writeStreamingAll(io, result.asStr());
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
