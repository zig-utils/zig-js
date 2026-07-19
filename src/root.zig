//! zig-js — a homegrown JavaScript engine in pure Zig.
//!
//! Two ways to use it:
//!   1. As a Zig module (`@import("js")`): drive the engine directly via
//!      `Context.create` / `Context.evaluate`, working with `Value`.
//!   2. Through the implemented JavaScriptCore-shaped C API subset: link the
//!      static library and call the exported `JSGlobalContextCreate` /
//!      `JSEvaluateScript` / ... symbols. See `c_api.zig`.
//!
//! v1 scope: expressions, `var`/`let`/`const`, `if`/`else`, `while`, blocks,
//! string concatenation, and the JSC value/string/object C-API surface that
//! `~/Code/Home/lang`'s runtime consumes. Functions, closures, and a real GC
//! are the next milestones (see craft's docs/architecture/web-engine-plan.md).

const std = @import("std");

// Engine core
pub const Value = @import("value.zig").Value;
pub const Object = @import("value.zig").Object;
pub const NativeFn = @import("value.zig").NativeFn;
pub const HostError = @import("value.zig").HostError;
pub const strictEquals = @import("value.zig").strictEquals;
pub const looseEquals = @import("value.zig").looseEquals;
pub const Context = @import("context.zig").Context;
pub const WasmFeatures = @import("wasm/types.zig").Features;
pub const Interpreter = @import("interpreter.zig").Interpreter;
pub const Environment = @import("interpreter.zig").Environment;
pub const Lexer = @import("lexer.zig").Lexer;
pub const Parser = @import("parser.zig").Parser;
pub const JsString = @import("jsstring.zig").JsString;
pub const installGlobals = @import("interpreter.zig").installGlobals;
pub const shape = @import("shape.zig");
pub const promise_profile = @import("promise_profile.zig");
/// Revision-pinned private consumer ABI pieces. These are deliberately
/// separate from the stable engine `Value` representation and public C API.
pub const private_abi = @import("private_abi.zig");

// Agent/threading infrastructure ($262.agent, Atomics waiter table). Conformance
// runners use `Context.TestingOptions.main_can_block` to model [[CanBlock]].
pub const agent = @import("agent.zig");
// Worker agents: one Context per OS thread, postMessage over the
// structured-clone wire format, cooperative terminate.
pub const Worker = @import("worker.zig").Worker;
// Shared-realm Thread API internals.
pub const jsthread = @import("jsthread.zig");

// Bytecode pipeline (tier-1 VM): compiler lowers the AST, vm executes it.
pub const bytecode = @import("bytecode.zig");
pub const Compiler = @import("compiler.zig").Compiler;
pub const vm = @import("vm.zig");
pub const jit = @import("jit.zig");

// JavaScriptCore-shaped C API subset (re-exported for documentation / direct use).
pub const c_api = @import("c_api.zig");

// The precise-GC binding (issue #1 Phase 7). Opt-in contexts allocate heap
// cells through it; see docs/threads/P7-gc-design.md.
pub const gc = @import("gc.zig");

/// Convenience: evaluate a snippet in a throwaway context, returning the
/// completion value. The caller owns nothing — the context is destroyed, so
/// only copy out primitives (numbers/booleans). For strings/objects, drive a
/// `Context` directly.
pub fn evalNumber(source: []const u8) !f64 {
    const ctx = try Context.create(std.heap.page_allocator);
    defer ctx.destroy();
    const v = try ctx.evaluate(source);
    return v.toNumber();
}

test {
    // Pull in every module so `zig build test` runs their inline tests.
    _ = @import("value.zig");
    _ = @import("shape.zig");
    _ = @import("shared_buffer.zig");
    _ = @import("agent.zig");
    _ = @import("structured_clone.zig");
    _ = @import("worker.zig");
    _ = @import("gil.zig");
    _ = @import("jsthread.zig");
    _ = @import("promise_profile.zig");
    _ = @import("jsstring.zig");
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("interpreter.zig");
    _ = @import("builtins.zig");
    _ = @import("unicode_normalize.zig");
    _ = @import("bytecode.zig");
    _ = @import("compiler.zig");
    _ = @import("vm.zig");
    _ = @import("jit.zig");
    _ = @import("context.zig");
    _ = @import("c_api.zig");
    _ = @import("gc.zig");
    _ = @import("nanbox.zig");
    _ = @import("strcell.zig");
    _ = @import("text_codec.zig");
    _ = @import("valuebox.zig");
    _ = @import("value_nb.zig");
    _ = @import("root_handshake.zig");
    _ = @import("parallel_lock.zig");
    _ = @import("private_abi.zig");
    _ = @import("wasm/decode.zig");
    _ = @import("wasm/exec.zig");
    _ = @import("wasm/types.zig");
    _ = @import("wasm/validate.zig");
    _ = @import("wasm/api.zig");
    _ = @import("wasm/worker_integration.zig");
}

test "evalNumber convenience" {
    try std.testing.expectEqual(@as(f64, 6), try evalNumber("2 * 3"));
}
