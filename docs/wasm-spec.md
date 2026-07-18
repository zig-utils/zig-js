# WebAssembly wg-1.0 spec suite (packed runner)

This document describes the self-contained upstream spec runner
(`zig build wasm-spec`) and its checked-in artifacts. A second, complementary
harness — the live-WABT corpus evaluator (`zig build wasm-spec-eval` +
`tools/wasm-spec.py`) — is documented in [wasm.md](wasm.md). Both pin the same
upstream corpus; they differ in how NaN-boundary assertions are scored (see
below).

## Pin

- Upstream: `WebAssembly/spec` tag `wg-1.0` (pure MVP surface), commit
  `977f97014c962f7bd1291fcc6d28b41a924882bf`.
- Converter: npm `wabt` via `tools/wasm-spec/gen.mjs` (bun). The generator
  normalizes modernized elem/data text forms and packs every binary module
  into `tests/wasm/spec/modules.bin` with a `manifest.json` directive index.

## Running

```sh
zig build wasm-spec                       # full suite, prints per-file + total
zig build wasm-spec -Dwasm-spec-filter=linking   # only matching files
zig build wasm-spec -Dwasm-spec-out=tests/wasm/spec/inventory.json
```

`WASM_SPEC_DIR` overrides the artifact directory. For CI compatibility the
step also accepts `-Dwasm-spec-inventory=<path>` (alias of `-Dwasm-spec-out`)
and `-Dwast2json=<path>` (unused — the packed artifacts already embed
converter output, so no converter is needed at run time). The runner
re-executes itself once per `.wast` file (`WASM_SPEC_WORKER=<file>`) for crash
isolation: a worker that dies or exceeds the 120 s watchdog is recorded as a
crash entry instead of aborting the inventory. Every directive executes
through the real JavaScript `WebAssembly` API — no test-only engine hooks.

## Current inventory

Checked in at `tests/wasm/spec/inventory.json`:

| files | pass | fail | skip | crash |
| ----: | ---: | ---: | ---: | ----: |
|    73 | 18,791 | 0 | 479 | 0 |

All 479 skips are classified — there are no hidden exclusions:

| count | class | rationale |
| ----: | --- | --- |
| 430 | `assert_malformed` quote/text modules | The wat text format is outside the binary runtime; a binary-only engine cannot express these. |
| 40 | NaN payload/sign expectations | `SetToNaN` is implementation-defined at the JS Number boundary; the argument's NaN pattern cannot cross the JS API, so the expectation is unobservable. The eval harness in [wasm.md](wasm.md) scores these exactly through a test-only bit-exact path. |
| 4 | generator rejects | npm wabt itself cannot parse these generated fragments (`data.wast:315`, `data.wast:323`, `elem.wast:281`, `elem.wast:289`). |
| 5 | Core 2.0 policy | The engine deliberately implements Core 2.0 semantics (matching V8): transactional-instantiation visibility at `linking.wast:236/248/342/354` and `br_table` polymorphic-bottom typing at `unreached-invalid.wast:538`. Each is locked by a dedicated exec/validate unit test. |

### Error-text aliases

The WebAssembly JS API fixes only the *class* of each failure
(`CompileError`/`LinkError`/`RuntimeError`); diagnostic text is
implementation-defined. The runner therefore carries a small, explicit alias
table (6 compile-wording and 2 link-wording groups) mapping the reference
interpreter's expected strings onto this engine's deterministic diagnostics;
the error class always matches, and every alias was verified against the
specific directives it unlocks. Notably the 32 "segment does not fit"
directives surface as `RuntimeError`, matching V8.

## Regenerating the artifacts

Only needed when the pin changes:

```sh
sh tools/wasm-spec/fetch.sh /tmp/spec-src          # fetch pinned tarball
(cd tools/wasm-spec && bun install)                # install npm wabt
bun tools/wasm-spec/gen.mjs /tmp/spec-src/test/core tests/wasm/spec
zig build wasm-spec -Dwasm-spec-out=tests/wasm/spec/inventory.json
```

Commit all three regenerated files (`manifest.json`, `modules.bin`,
`inventory.json`) together. The checked-in artifacts are the source of truth;
CI and local runs never touch the network.
