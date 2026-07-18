//! Evaluate one generated upstream WebAssembly specification script.
//!
//! The Python corpus driver owns WAST conversion and inventory generation; this
//! deliberately tiny executable keeps the measured engine path identical to an
//! ordinary zig-js Context and prints the script's final JSON string verbatim.
//! `WASM_SPEC_PROFILE=core-2-structural` enables the completed sign-extension,
//! nontrapping-conversion, multi-value, reference-types, and bulk-memory set.

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

    const structural = if (init.environ_map.get("WASM_SPEC_PROFILE")) |profile|
        std.mem.eql(u8, profile, "core-2-structural")
    else
        false;
    const ctx = try js.Context.createWithTestingOptions(gpa, .{
        .wasm_spec_bit_exact = true,
        .wasm_features = if (structural) .{
            .sign_extension_ops = true,
            .nontrapping_float_to_int = true,
            .multi_value = true,
            .reference_types = true,
            .bulk_memory = true,
        } else .{},
    });
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
