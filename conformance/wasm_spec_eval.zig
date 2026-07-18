//! Evaluate one generated upstream WebAssembly specification script.
//!
//! The Python corpus driver owns WAST conversion and inventory generation; this
//! deliberately tiny executable keeps the measured engine path identical to an
//! ordinary zig-js Context and prints the script's final JSON string verbatim.
//! `WASM_SPEC_PROFILE=core-2-structural` enables the completed structural set;
//! `WASM_SPEC_PROFILE=simd` adds fixed-width SIMD; `threads` selects shared
//! memories and atomic execution; `tail-calls`, `exception-handling`,
//! `memory64`, and `gc` select their exact pinned proposal feature gates.

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

    const profile = init.environ_map.get("WASM_SPEC_PROFILE") orelse "";
    const structural = std.mem.eql(u8, profile, "core-2-structural") or
        std.mem.eql(u8, profile, "simd") or
        std.mem.eql(u8, profile, "tail-calls") or
        std.mem.eql(u8, profile, "exception-handling") or
        std.mem.eql(u8, profile, "memory64") or
        std.mem.eql(u8, profile, "gc");
    const simd = std.mem.eql(u8, profile, "simd");
    const threads = std.mem.eql(u8, profile, "threads");
    const tail_calls = std.mem.eql(u8, profile, "tail-calls");
    const exception_handling = std.mem.eql(u8, profile, "exception-handling");
    const memory64 = std.mem.eql(u8, profile, "memory64");
    const wasm_gc = std.mem.eql(u8, profile, "gc");
    const ctx = try js.Context.createWithTestingOptions(gpa, .{
        .enable_threads = threads,
        .enable_gc = threads or wasm_gc,
        .parallel_gc = threads,
        .parallel_js = threads,
        .wasm_spec_bit_exact = true,
        .wasm_features = if (threads) .{
            .threads = true,
        } else if (structural) .{
            .sign_extension_ops = true,
            .nontrapping_float_to_int = true,
            .multi_value = true,
            .reference_types = true,
            .bulk_memory = true,
            .fixed_width_simd = simd,
            .tail_calls = tail_calls or exception_handling,
            .exception_handling = exception_handling,
            .typed_function_references = wasm_gc,
            .gc = wasm_gc,
            .memory64 = memory64,
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
