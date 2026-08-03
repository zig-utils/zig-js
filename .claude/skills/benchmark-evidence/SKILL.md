---
name: benchmark-evidence
description: Produce and publish zig-js performance evidence — the JavaScriptCore comparison matrix, GC compaction/generation benchmarks, Wasm SIMD/threads benchmarks, the VM-vs-tree-walker baseline, and the marker-delimited README scorecard. Use when the task involves benchmarking, throughput/scaling numbers, a suspected performance regression, publishing a perf claim, or profiling GC/thread contention.
---

# Benchmarks and performance evidence

Performance claims here are **published artifacts**, not impressions. Every
public number traces to a dated report plus its raw samples under `docs/.data/`.
Read [`docs/benchmarks.md`](../../../docs/benchmarks.md) for the full method.

## 1. Which harness answers your question

| Question | Harness |
| --- | --- |
| Is zig-js faster than JavaScriptCore on workload X? | `zig build benchmark-comparison` (macOS only) |
| Did the VM regress against the tree-walker? | `zig build bench` |
| Did GC compaction change retained bytes / pause? | `zig build gc-compaction-benchmark` |
| Did generational policy change pause or throughput? | `zig build gc-generation-benchmark` |
| Wasm SIMD or threads scaling? | `python3 tools/wasm-simd-benchmark.py`, `tools/wasm-threads-benchmark.py` |
| Where is no-GIL contention? | `zig build threads-profile` |
| Mid-script parallel-GC convergence/pauses? | `zig build midgc-profile` |
| GC allocation and Context lifecycle cost? | `zig build gc-profile` |

The profiles (`threads-profile`, `midgc-profile`, `gc-profile`) are **not
correctness gates** and are not publication evidence. They are for locating a
cost, not for making a claim.

## 2. The JSC comparison matrix

macOS only — it links the system `JavaScriptCore.framework`. Elsewhere the build
step fails with an explicit unsupported-platform message.

```bash
# Iterating on the harness: one reduced sample of every combination.
zig build benchmark-comparison -Dbenchmark-comparison-quick=true

# Validation/publication guards only — no compile, no benchmarking.
zig build benchmark-comparison-test

# The real measurement: seven samples, printed as Markdown.
zig build benchmark-comparison

# Save raw evidence and the dated report together.
zig build benchmark-comparison \
  -Dbenchmark-comparison-raw-out=docs/.data/benchmark-comparison-YYYY-MM-DD.tsv \
  -Dbenchmark-comparison-markdown-out=docs/.data/benchmark-comparison-YYYY-MM-DD.md
```

Four modes are measured: direct warmed context, independent steady contexts,
independent cold lifecycles, and zig-js shared-realm no-GIL. The first three are
cross-engine; **the shared-realm panel has no JSC ratio** because JSC's public
API exposes no equivalent — report it as a separate scaling reference and never
as a ratio against independent JSC contexts.

The harness enforces equal work, alternating runner order, a 50 ms timing floor,
dispersion limits, and cross-engine checksum equality. It will refuse to emit
evidence from a dirty tracked worktree.

## 3. Publishing

```bash
home-tool run tools/benchmark-publication.ts \
  --current-raw docs/.data/benchmark-comparison-YYYY-MM-DD.tsv \
  --current-report docs/.data/benchmark-comparison-YYYY-MM-DD.md \
  --readme README.md
```

The tool reruns the full matrix/sample-index/timing-floor/checksum validation,
reproduces the supplied report byte-for-byte from its raw TSV, and rewrites the
README block between `<!-- benchmark-comparison:start -->` and `:end`
idempotently. **Never hand-edit inside those markers.**

For a controlled before/after, pass both pairs and get a per-row history:

```bash
home-tool run tools/benchmark-publication.ts \
  --current-raw  docs/.data/benchmark-comparison-current.tsv \
  --current-report docs/.data/benchmark-comparison-current.md \
  --baseline-raw docs/.data/benchmark-comparison-baseline.tsv \
  --baseline-report docs/.data/benchmark-comparison-baseline.md \
  --history-out docs/.data/benchmark-history-current-vs-baseline.md
```

Historical comparison requires exact host, OS, Zig, zig-gc, zig-regex,
JavaScriptCore, matrix, jobs, and sample-count matches. A zig-js row gates
publication only when its median worsens by more than 10% **and** both runs are
within 5% RSD; JSC rows are visible controls, not gates.

## 4. Rules that get enforced

From [`docs/DOCS_ACCURACY_PLAN.md`](../../../docs/DOCS_ACCURACY_PLAN.md):

- State hardware, engine versions, sample count, statistic, workload scope, and
  the saved raw evidence path with every published claim.
- **Quick-mode smoke timings never go into a public table.**
- Never publish from a dirty tracked worktree; the report's commit must identify
  the exact runner/workload source that produced the samples.
- Keep `zig build bench` results in their own file — a VM/tree-walker change must
  not be able to silently rewrite the external comparison methodology.
- The runner pins nothing, discards no outliers, and does not lock frequency.
  Compare medians from the same host and power state, read the raw range, and
  demand repeated evidence before calling a small delta a regression.

## 5. Measurement hygiene on this machine

- The full matrix is measurement work, not a per-edit check. Use quick mode while
  changing the harness; run the full matrix once after the related changes are
  assembled.
- **Never run another corpus or benchmark job concurrently** — contention
  invalidates the samples, and some drivers `pkill` binaries by name and will
  kill the other run's processes.
- The manual-only [performance workflow](../../../.github/workflows/performance.yml)
  runs the same macOS matrix and keeps raw + report as a 90-day artifact. It
  never gates CI: hosted-runner timing is evidence to inspect, not an automatic
  comparison with the recorded M3 Pro baseline. Promote an artifact into
  `docs/.data/` only after reviewing it and rerunning any causal candidate on the
  reference host.
- The platform support boundary for published performance lives in
  [`docs/platforms.md`](../../../docs/platforms.md), generated by
  `tools/platform-release-matrix.ts` through Home.
