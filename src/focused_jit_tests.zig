//! Small test root for baseline-JIT development.
//!
//! Imported tests are the production JIT, selector, and backend tests; this
//! root deliberately excludes Context, C-API, Worker, and unrelated language
//! modules pulled into the full integration root.

test {
    _ = @import("jit.zig");
    _ = @import("jit/compiler.zig");
    _ = @import("jit/optimizer.zig");
    _ = @import("jit/aarch64.zig");
}
