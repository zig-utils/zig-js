# No-GIL parallelism: production-readiness status

GIL-free parallel execution is **correct, the default, and CI-gated**. What
remains is largely *performance* (GC + scaling) and *breadth of coverage*, not
new correctness architecture. This tracks the six work items.

## Summary

| # | Item | Status |
|---|------|--------|
| 1 | Broaden no-GIL correctness coverage | Largely done; ongoing |
| 2 | GC maturity | Correct; perf work remaining |
| 3 | Parallel performance validation | Benchmarked; optimization remaining |
| 4 | Embedder API | Done (C + Zig) |
| 5 | Robustness | Covered; fuzzing remaining |
| 6 | CI gating on every PR/push | Done |

## 1. Coverage

- **VM shared-state audit + fix.** `load_upval`/`store_upval` and
  `load_local`/`store_local` on a frame captured by a closure that escapes to
  another thread now serialize on a per-Frame `slot_lock` (gated on the parallel
  flag, escaped-only — non-captured frames pay nothing). This closed a race the
  tree-walker `lookupIdent` fix had missed.
- **`-Dtest262-parallel-js`** runs the whole test262 corpus (the entire language
  surface) in GIL-free parallel contexts, exercising the parallel-mode locked
  paths + the GC allocator across every feature. A CI leg asserts a curated
  cross-section introduces **no new failures vs the baseline arena engine**.
- *Remaining:* more concurrent-JS stress patterns (the VM upvalue race shows the
  threads corpus is a narrow slice); the full test262-parallel sweep is too slow
  per-context under GC to gate (see #2) so only a representative slice runs.

## 2. GC maturity

The GC is **correct** under parallel mutation (validated by the test262-parallel
"no new failures" leg + the `parallel_gc` / mid-script-collector tests). The gaps
are performance:

- **Tight-loop allocation is pathologically slow.** A per-iteration block-scoped
  `let` allocates a GC cell each iteration; under the GC engine a 4M-iteration
  loop took ~66 s (the arena engine bulk-frees, so it's fine there). Needs a
  tight-loop allocation fast path (nursery / generational, or an engine
  optimization to reuse non-captured per-iteration bindings).
- **Context lifecycle is ~100× the arena engine** (GC cell setup + per-cell
  teardown/finalizers vs bulk arena free). Amortized for real embedders (one
  long-lived context) but slow for create-per-unit-of-work patterns.
- *Remaining:* the allocation fast path, mid-script collection promoted from
  opt-in to default (so long parallel workloads collect without unbounded heap
  growth), and a sustained-load soak for leaks/UAF.

## 3. Parallel performance

- **Scaling benchmark added** (`zig build bench`): N JS `Thread`s each run an
  independent compute loop in one GIL-free context. Measured **~1.8× at 2
  threads, ~2.5× at 4** — real parallelism (a GIL gives ~1.0×).
- *Remaining:* scaling is sub-linear and falls off at high thread counts —
  profile lock contention (shared global-env bindings, the GC backing lock) and
  decide finer-grained vs lock-free where it bottlenecks.

## 4. Embedder API

- **`Context.Options.parallel`/`.gil`** (Zig) and **`ZJSGlobalContextCreateThreaded(gil)`**
  (C) expose the parallel/GIL choice. The parallel path is usable directly from C
  (parallel contexts have no owner-GIL); GIL-mode contexts, like JSC, expect the
  embedder to hold the GIL around use.
- *Remaining:* document the memory model (Atomics / SharedArrayBuffer
  happens-before, which races are JS-defined vs bugs — the TSan suppression
  rationale is the seed).

## 5. Robustness

- A re-entrant-getter + shared-object-mutation test proves no re-entrant-lock
  deadlock (per-object locks are released before JS callbacks) and stays
  TSan-clean (property access is serialized) under 6 threads.
- The `cve/` corpus covers many lifecycle/lock/teardown hazards, gated TSan-clean.
- *Remaining:* a concurrent-JS fuzzer; exhaustive cross-thread exception /
  termination / cleanup coverage.

## 6. CI gating

The whole-corpus no-GIL ThreadSanitizer sweep (4 shards), the suppression-narrowness
witness, and the test262-parallel leg run on **every pull request and main push**
(not just nightly), and the corpus gate **hard-blocks** (it is at zero engine-state
races, so a TSan report fails the run).
