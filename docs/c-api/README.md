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

Current result: 97 of 117 functions are implemented, 20 remain linked to open
issues, and the library exports 98 public functions plus 9 zig-js extensions.

Run `zig build c-api-audit` after changing `src/c_api.zig`, the headers, or the
inventory. On a machine with the pinned SDK, pass its root to
`tools/verify-c-api.py --sdk-root <path>` to detect upstream header drift.
`zig build test-c-api` additionally compiles, links, and runs C and C++ hosts.
On macOS, `zig build c-api-jsc-diff` verifies those hashes, compiles
`tests/c_api_value_diff.c` against both zig-js and the system JavaScriptCore
framework, and compares their value/class output byte-for-byte.
