//! Integration evidence for the WebAssembly MVP (issue #141): the
//! `WebAssembly` JavaScript namespace is installed in every context —
//! including worker contexts — so modules compile, instantiate, and execute
//! on a worker thread, with results round-tripping to the parent over the
//! worker channel. The store stays per-context; only structured-cloneable
//! values cross.

const std = @import("std");
const Context = @import("../context.zig").Context;
const Worker = @import("../worker.zig").Worker;

// (module
//   (func (export "add") (param i32 i32) (result i32)
//     local.get 0 local.get 1 i32.add))
const add_module_src =
    \\const bytes = new Uint8Array([
    \\  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    \\  0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    \\  0x03, 0x02, 0x01, 0x00,
    \\  0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    \\  0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    \\]);
;

test "wasm api runs inside a worker and round-trips the result" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    var machine = ctx.interpreter();

    const worker_src = add_module_src ++
        \\try {
        \\  const m = new WebAssembly.Module(bytes);
        \\  const r = new WebAssembly.Instance(m).exports.add(40, 2);
        \\  postMessage({ ok: r, validated: WebAssembly.validate(bytes) });
        \\} catch (e) {
        \\  postMessage({ err: String(e) });
        \\}
        \\close();
    ;
    const worker = try Worker.spawn(worker_src);
    const reply = (try worker.receive(&machine, 10_000)) orelse return error.TestUnexpectedResult;
    worker.join();
    worker.destroy();

    const err_val = try machine.getProperty(reply, "err");
    if (!err_val.isUndefined()) return error.TestUnexpectedResult;
    try std.testing.expect((try machine.getProperty(reply, "validated")).asBool());
    try std.testing.expectEqual(@as(f64, 42), (try machine.getProperty(reply, "ok")).asNum());
}
