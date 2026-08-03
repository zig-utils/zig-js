---
name: wasm-conformance
description: Run and extend zig-js WebAssembly work against the pinned upstream spec corpora — MVP/wg-1.0, Core 2, Core 3, SIMD, threads, tail calls, exception handling, multi-memory, memory64, and Wasm GC — including feature gates, inventories, and the ten-profile conformance matrix. Use when the task mentions WebAssembly, .wast/.wat, a wasm opcode, a wasm feature proposal, or the wasm score.
---

# WebAssembly conformance

zig-js implements a pure-Zig WebAssembly pipeline in
[`src/wasm/`](../../../src/wasm/): `decode.zig`, `validate.zig`, `exec.zig`,
`simd.zig`, `atomic.zig`, `gc.zig`, `types.zig`, plus the JavaScript API in
`api.zig`. Status and evidence live in [`docs/wasm.md`](../../../docs/wasm.md);
WebAssembly is scored **separately from test262** because it has its own upstream
corpora.

## 1. Two harnesses, deliberately

| Harness | What it is |
| --- | --- |
| `zig build wasm-spec` | Self-contained packed runner over the checked-in wg-1.0 artifacts. Documented in [`docs/wasm-spec.md`](../../../docs/wasm-spec.md). |
| `zig build wasm-spec-eval` + `tools/wasm-spec.py` | Live corpus evaluator against a real upstream checkout, converted with WABT `wast2json` or `wasm-tools`. |

Both pin the same upstream corpus; they differ in how NaN-boundary assertions
are scored. Do not treat one's number as the other's.

```bash
zig build wasm-spec                                     # packed wg-1.0 runner
zig build wasm-spec -Dwasm-spec-filter=linking -Dwasm-spec-inventory=/tmp/linking.json
zig build wasm-spec-bin                                 # build only
zig build wasm-spec-eval                                # build the live evaluator
```

## 2. Driving the live evaluator

```bash
python3 tools/wasm-spec.py \
  --profile <profile> \
  --spec-root <upstream checkout> \
  --wast2json <path>            # WABT-converted profiles
  --converter <wasm-tools path> # Core 3 / memory64 / gc profiles
  --filter <file-or-dir> \
  --inventory /tmp/<name>.json
```

Profiles: `mvp`, `core-2-structural`, `core-3`, `core-main-shadow`, `simd`,
`threads`, `tail-calls`, `exception-handling`, `multi-memory`, `memory64`, `gc`.
`--changed-only` narrows the upstream-main shadow profile to the changed slice.

Corpus checkouts and converter versions are **pinned by commit and SHA-256** in
[`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) — copy the exact
pin from there rather than fetching a moving branch. The `wasm-spec-wg1` and
`wasm-spec-wg3` submodules cover the wg-1.0 and Core 3 roots.

Other steps:

```bash
zig build wasm-core-3                 # pinned Core 3 profile
zig build wasm-core-main-shadow       # non-blocking upstream-main drift
zig build wasm-feature-profiles       # feature-gate matrix
zig build wasm-feature-profiles-check # CI form
~/Code/Home/lang/zig-out/bin/home-tool run tools/wasm-conformance-matrix.ts --write
~/Code/Home/lang/zig-out/bin/home-tool run tools/wasm-core3-drift.ts
python3 -m unittest tools/test_wasm_spec.py
```

## 3. Feature gates

Post-MVP features are **off by default** and enabled explicitly per context via
`Context.Options.wasm_features` (`src/wasm/types.zig`):

`sign_extension_ops`, `nontrapping_float_to_int`, `multi_value`,
`reference_types`, `bulk_memory`, `fixed_width_simd`, `relaxed_simd`, `threads`,
`tail_calls`, `typed_function_references`, `gc`, `exception_handling`,
`memory64`, `multi_memory`.

Dependencies are checked and rejected with a diagnostic:
`relaxed_simd` → `fixed_width_simd`; `typed_function_references` →
`reference_types`; `gc` → `typed_function_references`; `exception_handling` →
`reference_types`. Enabling an unfinished feature produces an implementation
diagnostic rather than silently degrading.

## 4. When adding or extending a feature

1. Decode → validate → execute, in that order, each with stable byte-offset
   diagnostics. A validation gap that only shows up at execution is a bug.
2. Add the feature flag and its dependency rule in `src/wasm/types.zig`.
3. Run the matching upstream profile with `--inventory` and check in the
   inventory JSON under `docs/.data/`.
4. Regenerate the ten-profile matrix (`tools/wasm-conformance-matrix.ts`) with
   Home's native tool runner and,
   if the headline changes, the README status block via
   `python3 tools/release-compatibility.py --update-readme`.
5. Add the smoke filter to the CI matrix leg so the profile stays gated.

## 5. Threads and SIMD specifics

- Wasm threads execute atomic opcodes with SeqCst RMW/CAS/fence, `wait32` /
  `wait64` / `notify`, fixed historical `Memory` buffers, and targeted
  termination interruption. The `threads` profile executes in a
  **threaded-context** rather than the portable one.
- Benchmarks for both live under
  [`docs/benchmarks.md`](../../../docs/benchmarks.md) —
  `tools/wasm-simd-benchmark.py` and `tools/wasm-threads-benchmark.py` — and
  publish through the same evidence rules as every other perf claim.

## 6. Reporting

Never state a wasm pass count that is not in a checked-in inventory under
`docs/.data/` or in live command output. Applicable-test denominators differ per
profile; say which profile a number belongs to.
