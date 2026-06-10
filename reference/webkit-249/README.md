# WebKit PR #249 reference material — shared-memory threads for JavaScriptCore

Unmodified reference copies vendored from **oven-sh/WebKit pull request #249**
("Shared-memory threads for JavaScriptCore").

- Source: https://github.com/oven-sh/WebKit/pull/249
- Head SHA: `25375a997f4f1faebc123f4733a546ba789107bd`
- Fetched: 2026-06-10 (sparse partial clone of `JSTests/threads`, `docs/threads`,
  `THREAD.md`, `JSTests/threads.yaml` from the PR head)

## Licensing

These files are copied verbatim and remain under WebKit's licenses.
`threads-tests/threads.yaml` carries an explicit 2-clause BSD header
("Copyright (C) 2026 Oven, Inc. All rights reserved."). The individual `.js`
test files and the markdown docs do **not** carry per-file license headers;
they fall under the WebKit project's standard licensing (BSD/LGPL, see
WebKit's top-level license files). Do not relicense; keep these as reference
material only, do not ship them in zig-js binaries or merge them into source.

## Layout

| Path | Contents |
| --- | --- |
| `threads-tests/` | Full contents of `JSTests/threads/` from the PR head, plus `threads.yaml` (the JSTests runner manifest, copied here as `threads-tests/threads.yaml`). |
| `docs/` | Full contents of `docs/threads/` from the PR head: design specs (`SPEC-*.md`), their `-history` files, integration notes (`INTEGRATE-*.md`), TSAN/CVE-audit notes, and a `cve/` subdir of per-CVE mapping docs. |
| `THREAD.md` | The top-level design writeup from the PR head repo root. |

## Inventory (240 files in threads-tests/, 66 in docs/, ~5.4 MB total)

`threads-tests/` — .js counts per subdir (every subdir is all-.js unless noted):

| Subdir | .js files | Notes |
| --- | ---: | --- |
| `api/` | 16 | Thread/join/asyncJoin/Lock/Condition/ThreadLocal API conformance |
| `arrays/` | 5 | racing array/butterfly operations |
| `atomics/` | 15 | `Atomics.*` extended to object properties |
| `bench/` | 9 | scalability/contention benchmarks |
| `cve/` | 57 | regression tests modeled on historical JSC CVEs |
| `gc-stress/` | 4 | shared-heap GC stress |
| `invariants/` | 7 | object-model invariants under races |
| `jit/` | 15 | +5 non-js: `README.md`, `run-jit-tests.sh`, `golden-disasm.sh`, `lint.sh`, `bench-gates.sh` |
| `lifecycle/` | 8 | +1 `.js.skip` file |
| `objectmodel/` | 23 | flat/segmented butterfly + per-object lock regimes |
| `races/` | 7 | adversarial race interleavings |
| `resources/` | 1 | `assert.js` (shared assertion helpers loaded by `harness.js`) |
| `scaling/` | 7 | N-thread scaling |
| `semantics/` | 17 | memory-model / observable-semantics tests |
| `shared-objects/` | 7 | cross-thread object sharing |
| `sync/` | 11 | Lock/Condition/wait-notify synchronization |
| `vmstate/` | 11 | +1 `README.md`; per-thread VM-lite state |
| top level | 13 | `harness.js`, `smoke.js`, `heap-*.js` heap tests, `threads.yaml` |

Note: the PR's corpus grew well beyond the originally expected
api/atomics/arrays/bench/cve layout — the 12 additional subdirs above
(gc-stress, invariants, jit, lifecycle, objectmodel, races, resources,
scaling, semantics, shared-objects, sync, vmstate) are included in full.

`docs/` — 43 top-level .md files (SPEC-api/heap/jit/congc/objectmodel/ungil/
vmstate/nativeaffinity + `-annex`/`-history` variants, INTEGRATE-* notes,
TSAN-*, CVE-AUDIT*, BENCH/SCALEBENCH/FUZZ/AMPLIFIER handouts) plus `cve/`
(23 files: per-CVE-class mapping docs `map-MC-*.md`, `jsengine-sab.md`,
`jvm.md`).

Nothing planned was missing: `docs/threads/`, `THREAD.md`, and
`JSTests/threads.yaml` all exist on the branch and are included.

## Concept mapping: WebKit PR #249 → zig-js

| WebKit / PR #249 concept | zig-js counterpart |
| --- | --- |
| `VM` / `JSGlobalObject` (per-thread VM-lite split: top call frame, exception state, microtask queue) | `src/context.zig` `Context` — single mutable interpreter state |
| Per-thread microtask queues (`SPEC-vmstate.md`) | `Context.microtasks` (`std.ArrayListUnmanaged(Microtask)`) — currently one queue per Context; needs a per-thread lift for shared-memory threads |
| `harness.js` + `resources/assert.js` (shouldBe, shouldThrow, spawnN, withTimeout) | the harness shim zig-js Phase 6 will provide so the corpus runs unmodified |
| `threads-tests/api/`, `atomics/`, `arrays/` | the primary corpus zig-js Phase 6 ports behind that harness shim |
| `threads-tests/cve/` + `bench/` (+ `jit/`, `gc-stress/`) | Layer C checklist — mostly target JIT/GC machinery (butterflies, Structures, ICs, concurrent GC) that zig-js does not have; useful as a behavioral checklist, not directly portable |
| Butterfly regimes / Structure watchpoints (`SPEC-objectmodel.md`) | zig-js shapes/property storage — design reference only |
| GIL'd `Thread()` first, then layer-by-layer GIL removal (`THREAD.md`, `SPEC-ungil.md`) | suggested staging for any zig-js threads work: cooperative GIL over `Context` first, corpus green, then relax |
