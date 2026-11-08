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
library exports 117 public functions plus 35 zig-js extensions. The extension
inventory includes the existing script-cache, CPU-profile and UTF-8 evaluation
entry points as well as the opt-in rejection checkpoint.

`ZJSValueIsPromise` and `ZJSValueIsProxy` inspect native brands without running
Proxy traps, user getters, jobs or Promise reactions. A revoked Proxy remains
a Proxy; a Proxy wrapping a Promise is not itself a Promise. Same-group realm
handles are accepted, while null inputs and foreign-group handles return false.
These owner-thread inspection calls are zig-js extensions declared in
`zig-js/Extensions.h`, not additions to system JavaScriptCore's public API.
`zig build test-c-api-value-brands` runs C and C++ fixtures covering ordinary
and spoofed objects, subclasses, revoked/callable proxies, realm ownership,
unchanged rejection notifications, host private-data transfer and protected
precise-GC lifetime. The aggregate `test-c-api` gate includes both fixtures.

`ZJSContextTakeUnhandledRejection` consumes a still-unhandled notification after
the host's microtask checkpoint, returning the original reason and Promise.
It distinguishes an empty queue from a rejection with an `undefined` reason,
omits rejections handled before consumption, and preserves notification order.
The host owns event dispatch and failure policy. Protect the returned ordinary
C-API handles before running more JavaScript or collecting garbage. This is a
zig-js extension; it does not add a system JavaScriptCore API or claim complete
Node rejection-event semantics. `zig build test-c-api-rejections` exercises the
boundary, including handled filtering, realm isolation and protected lifetime.

`ZJSContextGetAsyncContext` and `ZJSContextSwapAsyncContext` expose a rooted
execution value to owner-thread native callbacks. The inactive value is
`undefined`; there is no realm-global store. Nested host/JS entries in the same
realm share the active slot, while other realms and OS mutators remain isolated.
Promise/await reactions and callback jobs capture the value at registration and
restore the previous scope on normal or abrupt completion. Calls without an
active matching execution fail; returned handles retain ordinary C-API lifetime.
This is an embedder primitive, not a complete Node async_hooks implementation.
`zig build test-c-api-async-context` exercises identity, nested entry, job scope
restoration, await/thenable/species capture, real precise compaction, and
independent owner-thread contexts through C, C++ and a focused native job probe.

Run `zig build c-api-audit` after changing `src/c_api.zig`, the headers, or the
inventory. On a machine with the pinned SDK, pass its root to
`home-tool run tools/verify-c-api.ts --sdk-root <path>` to detect upstream header drift.
`zig build test-c-api` additionally compiles, links, and runs C and C++ hosts.
On macOS, `zig build c-api-jsc-diff` verifies those hashes, compiles
the value/class and context-group fixtures against both zig-js and the system
JavaScriptCore framework, and compares their output byte-for-byte.
The current 35-row fixture digest is `4738a98b624bd0a6`.
