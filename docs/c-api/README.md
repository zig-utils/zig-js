# Public C API inventory

`jsc-public-api-macos-27.0.json` pins the core C surface from the macOS 27.0
Command Line Tools SDK (build `26A5368f`). It inventories all 117 functions,
opaque and concrete types, callbacks, enums, and the exported class-definition
constant from the six headers included by the public C umbrella.

The matrix deliberately separates declarations from completion:

- `implemented` means zig-js exports the symbol with the pinned public ABI and
  the behavior is covered by the relevant implementation tests.
- `pending` means the declaration is available for source compatibility, but
  the linked GitHub issue still owns missing behavior, a missing symbol, or an
  ABI mismatch. Pending calls must not be used by hosts yet.

Current result: all 117 functions are implemented, none remain pending, and the
library exports 117 public functions plus 31 zig-js extensions. The extension
inventory includes the existing script-cache, CPU-profile and UTF-8 evaluation
entry points as well as the opt-in rejection checkpoint.

`ZJSContextTakeUnhandledRejection` consumes a still-unhandled notification after
the host's microtask checkpoint, returning the original reason and Promise.
It distinguishes an empty queue from a rejection with an `undefined` reason,
omits rejections handled before consumption, and preserves notification order.
The host owns event dispatch and failure policy. Protect the returned ordinary
C-API handles before running more JavaScript or collecting garbage. This is a
zig-js extension; it does not add a system JavaScriptCore API or claim complete
Node rejection-event semantics. `zig build test-c-api-rejections` exercises the
boundary, including handled filtering, realm isolation and protected lifetime.

Run `zig build c-api-audit` after changing `src/c_api.zig`, the headers, or the
inventory. On a machine with the pinned SDK, pass its root to
`home-tool run tools/verify-c-api.ts --sdk-root <path>` to detect upstream header drift.
`zig build test-c-api` additionally compiles, links, and runs C and C++ hosts.
On macOS, `zig build c-api-jsc-diff` verifies those hashes, compiles
the value/class and context-group fixtures against both zig-js and the system
JavaScriptCore framework, and compares their output byte-for-byte.
The current 35-row fixture digest is `4738a98b624bd0a6`.
