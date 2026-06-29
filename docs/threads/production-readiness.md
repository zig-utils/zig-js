# No-GIL Parallelism: Production-Readiness Status

GIL-free shared-realm execution is correct, the default, and CI-gated. What
remains is mostly performance, documentation, and broader stress coverage rather
than new correctness architecture.

## Summary

| # | Item | Status |
|---|------|--------|
| 1 | Broaden no-GIL correctness coverage | Done; ongoing expansion |
| 2 | GC maturity | Correct; performance and pause-time work remaining |
| 3 | Parallel performance validation | Benchmarked; optimization remaining |
| 4 | Embedder API | Done (Zig + C) |
| 5 | Robustness | Fuzzed and gated; continue broadening |
| 6 | CI gating on every PR/push | Done |

## 1. Coverage

- VM shared-state audits closed the known escaped-frame races:
  `load_local` / `store_local` / `load_upval` / `store_upval` on
  closure-escaped frames serialize on a gated per-frame lock.
- Tree-walker entry into VM-compiled closures now dispatches through the VM,
  so spawned `Thread` entry and normal calls agree on upvalue resolution.
- Active VM frame slots are traced as GC roots, not only operand stacks, closing
  the mid-script parallel-GC use-after-free found by the fuzzer.
- `-Dtest262-parallel-js` runs a broad language-surface slice in GIL-free
  parallel contexts and asserts no new failures versus the baseline.
- The PR-249 allowlist remains 219/219 in normal mode and is covered by the
  sharded no-GIL ThreadSanitizer corpus gate.
- The reference-only PR-249 tail is checked by
  `zig build threads-reference-audit`, so unsupported shell hooks, JIT,
  WebAssembly, deep-stack, and heap-cap/OOM witnesses stay explicit instead of
  becoming accidental no-op passes.

Remaining: keep widening generated and hand-written stress toward exceptions,
termination, cleanup, waiters, and cross-thread lifecycle.

## 2. GC Maturity

The GC is correct under parallel mutation. Current coverage includes
test262-parallel, `parallel_gc` tests, mid-script collector tests, and a
sustained `parallel_gc soak` that checks retained graphs survive and the live
set stays bounded across rounds.

Known performance/maturity work:

- GC cells now use `Context.GcCellBacking`, a reusable size-class slab backing
  that recycles 16-byte-aligned cell allocations and delegates non-cell heap side
  storage unchanged. Ownership classification is now bucket-local too, so
  collection and context teardown first reject pointers outside each bucket's
  address span and do not scan unrelated size-class chunks when freeing a cell.
  A per-bucket recent-chunk hint keeps repeated frees/remaps from the same slab
  on the fast path instead of restarting the bucket chunk walk each time.
  During `Context.destroy`, the backing enters bulk-teardown mode so `zig-gc`'s
  per-cell frees do not rebuild freelists immediately before the backing releases
  whole chunks. This cuts the old
  one-general-allocator-call-per-cell profile without changing the collector API.
- Tight-loop block-scoped allocation is still slower under the GC path compared
  with arena bulk allocation. This still needs a nursery/generational strategy
  or an engine optimization for non-captured per-iteration bindings.
- Context create/destroy remains more expensive than the arena model because
  global setup and GC finalization still touch many cells. Long-lived contexts
  amortize this; create-per-task embedders still need additional lifecycle
  reductions or guidance.
- `zig build gc-profile` is the local baseline for those costs. It compares
  arena, explicit-GC, no-GIL threaded GC, and `.gil = true` contexts across
  create/destroy, object-heavy allocation, block-scoped `let` allocation, and
  explicit `collectGarbage()`.
- Mid-script parallel GC remains abort-safe. Sync wait/lock/condition peers are
  not treated as frozen parked stacks; their lock-free pump points now service
  root publication, and the collector waits long enough for one bounded park
  wake. This lets property `Atomics.wait`, `Condition.wait`, and contended
  `Lock` acquisition converge under the mid-script collector while preserving
  quiescent collection as the fallback for heavier non-converging cycles.

## 3. Parallel Performance

- `zig build bench` includes a scaling benchmark where N JS `Thread`s run
  independent compute loops in one GIL-free context.
- `zig build threads-profile` is the dedicated contention harness. It compares
  the no-GIL default with `.gil = true` across independent compute, shared
  object properties, shared array append, typed-array Atomics, contended
  `Lock.hold`, `Lock.asyncHold` delivery, and thread lifecycle churn. Each row
  enables and includes internal contention counters: `events` count logical
  contention (`Lock`/`Condition`/property wait and queued `asyncHold` grants),
  `parks` count timed wait/pump iterations including `Thread.join`, and
  `empty`/`jobs` split the run-loop task pump into empty fast-path hits and
  delivered async-hold jobs.
- Parked sync waiters still pump the realm run-loop so async-hold grants make
  progress, but empty pumps now use an atomic queue-count fast path and avoid
  taking the shared threading API lock.
- Async-hold delivery also dequeues both the per-lock pending grant list and the
  realm task queue with FIFO head cursors instead of front-shifting lists,
  keeping delivery cost proportional to delivered jobs rather than pending queue
  length.
- Measured speedup shows real parallelism: roughly 1.8x at 2 threads and 2.5x
  at 4 threads in the recorded checkpoint.

Remaining: use the attribution columns to drive targeted reductions in
contended user-level locks, join/lifecycle waiting, object/element storage
contention, context lifecycle pooling, and nursery/generational work.

## 4. Embedder API

- Zig: `Context.createWith(.{ .enable_threads = true })` is parallel by
  default; `.gil = true` opts into serialized execution.
- C: `ZJSGlobalContextCreateThreaded(gil)` exposes the same choice.
- Non-threaded contexts remain single-threaded and avoid the parallel
  synchronization protocols.
- The public memory-model contract is documented in
  [Memory Model](./memory-model.md): JS-defined program races remain program
  races, while engine-state races are bugs and remain TSan-gated.

Remaining: keep C-API context-affinity guidance and memory-model wording current
as embedders exercise more threaded host patterns.

## 5. Robustness

- Re-entrant getter/shared-mutation tests prove per-object locks are not held
  across JS callbacks in a way that deadlocks.
- The `cve/` PR-249 subset covers teardown, waiters, lifecycle, GC, and
  synchronization hazards.
- `threadfuzz` generates random shared object / array / closure / typed-array
  programs in GIL-free contexts and supports single-file reproduction. Its
  broad profile now adds caught exceptions/finally, nested thread lifecycle,
  `asyncJoin`, property `wait` / `waitAsync`, `Condition`, `Thread.restrict`,
  and `FinalizationRegistry` cleanup coverage under GC-backed parallel
  contexts.
- The mid-script GC fuzzer profile blocks peers in property `Atomics.wait`,
  `Condition.wait`, and contended `Lock` acquisition while allocation pressure
  drives `parallel_midscript_gc`; every seed must complete exactly and finish at
  least one parallel sweep, then deliver the expected `FinalizationRegistry`
  cleanup count/sum after a quiescent collect.
- Host-side thread queues are now explicit GC roots: queued `Lock.asyncHold`
  tasks in `Gil.tasks`, per-lock pending grants, async condition waiters,
  ThreadLocal values, and thread completion results trace or barrier their
  hidden JS values instead of relying on a JS property path.
- The lifecycle fuzzer profile adds deterministic termination storms where main
  JS throws with parked/unjoined `Thread`s, exact-counter oracles for script
  and module `Worker`s overlapping shared-realm `Thread`s on one retained
  `SharedArrayBuffer`, and mixed `close` / `terminate` / `postMessage`
  ordering coverage plus worker handler-exception recovery, Thread exception
  identity through `join()` / `asyncJoin()` while property and condition waiters
  are parked, cross-thread `FinalizationRegistry` cleanup count/sum oracles, and
  `ThreadLocal` isolation across normal, throwing, nested, and async-joined
  thread lifecycles.
- CI runs the fuzzer in several modes: default seeded, TSan, high-contention
  amplified, broad semantic, mid-script GC wait-pump, lifecycle, ReleaseSafe,
  and deterministic-result verification.

Remaining: keep extending the lifecycle profile toward more cross-realm
scheduling, worker module-graph shapes, richer cleanup/finalization
interleavings, async-grant execution during active mid-script GC windows, and
additional teardown race variants.

## 6. CI Gating

Every pull request and push to `main` runs:

- unit tests,
- GIL-mode PR-249 corpus,
- focused no-GIL thread witness,
- TSan unit gates,
- TSan `parallel_js` unit slice,
- `threadfuzz`,
- TSan `threadfuzz`,
- amplified `threadfuzz`,
- broad semantic `threadfuzz`,
- mid-script GC wait-pump `threadfuzz`,
- lifecycle `threadfuzz`,
- ReleaseSafe `threadfuzz`,
- deterministic-result `threadfuzz-verify`,
- sharded no-GIL PR-249 corpus TSan sweep,
- TSan suppression-narrowness witness
  (`tools/tsan-suppression-witness.sh`),
- test262-parallel representative slice.

The no-GIL corpus TSan gate hard-blocks on engine-state races. The suppression
witness proves the program-byte suppressions are both load-bearing and narrow.
