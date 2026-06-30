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
- The PR-249 allowlist remains 224/224 in normal mode and is covered by the
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
  per-cell frees do not rebuild freelists or reclassify bucket ownership
  immediately before the backing releases whole chunks. This cuts the old
  one-general-allocator-call-per-cell profile without changing the collector API.
  Live `SharedArrayBuffer` retain teardown is also regression covered across the
  arena path, the no-GIL threaded path, and the `.gil = true` serialized
  fallback.
- Single-mutator GC contexts now allocate object side stores directly from the
  context allocator instead of going through the cell-slab classifier only to
  delegate. True-parallel JS contexts keep the synchronized backing wrapper for
  those side stores because the embedder-provided allocator may not be
  thread-safe.
- Tight-loop block-scoped allocation is still slower under the GC path compared
  with arena bulk allocation. This still needs a nursery/generational strategy
  or an engine optimization for non-captured per-iteration bindings.
- Context create/destroy remains more expensive than the arena model because
  global setup and GC finalization still touch many cells. Long-lived contexts
  amortize this; create-per-task embedders still need additional lifecycle
  reductions or guidance.
- `zig build gc-profile` is the local baseline for those costs. It compares
  arena, explicit-GC, no-GIL threaded GC, and `.gil = true` contexts across
  create/destroy, create-per-task versus long-lived-context reuse with periodic
  collection, object-heavy allocation, block-scoped `let` allocation, and
  explicit `collectGarbage()`. It also prints GC cell-backing attribution for an
  object-heavy allocation run: chunk count, total cell-slot capacity, live cells
  at context creation, live cells after allocation, free slots after collection,
  and live cells after collection.
- Mid-script parallel GC remains abort-safe. Sync wait/lock/condition peers are
  not treated as frozen parked stacks; their lock-free pump points now service
  root publication, and the collector waits long enough for one bounded park
  wake. This lets property `Atomics.wait`, `Condition.wait`, and contended
  `Lock` acquisition converge under the mid-script collector while preserving
  quiescent collection as the fallback for heavier non-converging cycles. The
  `zig-gc` barrier hand-off also re-checks `marking` and `concurrent` while
  holding the barrier lock, so a stale mutator that observed an active
  collection just before an abort cannot append into `barrier_buf` after the
  abort path has cleared it; the dependency has a deterministic regression test
  for that abort boundary and is covered by the local `parallel_js` TSan slice.

## 3. Parallel Performance

- `zig build bench` includes a scaling benchmark where N JS `Thread`s run
  independent compute loops in one GIL-free context.
- `zig build threads-profile` is the dedicated contention harness. It compares
  the no-GIL default with `.gil = true` across independent compute, shared
  object properties, shared array append, typed-array Atomics, contended
  property `Atomics.wait` / `notify`, `Condition.wait` / `notifyAll`,
  `Lock.hold`, `Lock.asyncHold` delivery, observed `Lock.asyncHold` callback
  settlement, no-fn `Lock.asyncHold` release-function delivery, and thread
  lifecycle churn. Each row enables and includes internal contention counters:
  `events` count logical contention (`Lock`/`Condition`/property wait and
  queued `asyncHold` grants), `parks` count timed wait/pump iterations
  including `Thread.join`, and `empty`/`jobs` split the run-loop task pump into
  empty fast-path hits and delivered async-hold jobs.
- Parked sync waiters still pump the realm run-loop so async-hold grants make
  progress, but empty pumps now use an atomic queue-count fast path and avoid
  taking the shared threading API lock.
- Async-hold delivery also dequeues both the per-lock pending grant list and the
  realm task queue with FIFO head cursors instead of front-shifting lists,
  keeping delivery cost proportional to delivered jobs rather than pending queue
  length. Task pumps now copy bounded FIFO bursts under the shared threading API
  lock and run every grant outside it, reducing delivery lock acquisitions from
  one per job to one per burst.
- Promise microtask drains now use a FIFO head cursor instead of
  `orderedRemove(0)`, so observed async-hold callback settlement and no-fn
  release-function reactions do not shift the remaining reaction queue on every
  delivered job while preserving checkpoint order.
- Condition notify/notifyAll use the same FIFO head-cursor pattern for the
  mixed sync/async waiter queue, avoiding one front-shift per notified waiter.
  Timed-out or terminated sync condition waiters are marked canceled and skipped
  by the head cursor instead of being removed from the middle of the queue.
- Property-mode `Atomics.notify` stable-compacts matching waiter queues in one
  pass. Sync wait stack tickets are unlinked before signal, so awakened peers no
  longer each rescan and front-shift the table on return; matching `waitAsync`
  tickets are collected for post-unlock settlement without repeated middle
  removals. Individual sync wait timeout/termination cleanup now stable-compacts
  the waiter table in one pass instead of front-shifting the remaining waiters.
  Timeout polling now also compacts all expired property `waitAsync` tickets in
  one pass and realm teardown frees abandoned property `waitAsync` tickets by
  linear scan.
- Worker inbox/outbox channels now use FIFO head cursors for structured-clone
  message queues, so Worker-heavy lifecycle and receive loops do not pay one
  front shift per delivered message. Empty internal `Worker.receive(..., 0)`
  polls now return from the channel while holding the queue lock instead of
  entering a timed condition wait, and skip drained-queue compaction on the
  empty fast path.
- Active interpreter roots, protected C-API handles, and GIL park records are
  unordered root sets, so their removals now use swap removal instead of
  order-preserving list shifts on evaluate, handle-unprotect, and thread
  teardown paths.
- The same `threads-profile` run now includes a separate isolated `Worker`
  section for structured-clone inbox/outbox round-trips, empty receive polling,
  spawn/post/receive/join/destroy lifecycle cost. It is reported outside the
  no-GIL versus `.gil = true` table because Workers already isolate each
  `Context` onto its own OS thread.
- Measured speedup shows real parallelism: roughly 1.8x at 2 threads and 2.5x
  at 4 threads in the recorded checkpoint.

Remaining: use the attribution columns to drive targeted reductions in
contended user-level locks, Worker-heavy lifecycle and message traffic,
join/lifecycle waiting, object/element storage contention, context lifecycle
pooling, and nursery/generational work.

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
  drives `parallel_midscript_gc`; every seed now runs a normal completion
  wait-pump subprogram, a sync-wait cleanup subprogram, a promise-publication
  subprogram, a pending-microtask subprogram, a creator-owned buffer
  subprogram, an isolated Worker/SAB cleanup subprogram, and an expected
  teardown-termination subprogram, and each must finish at least one parallel
  sweep. The wait-pump subprogram queues a
  FIFO `Lock.asyncHold` grant chain including a root-bearing rejected grant plus
  an async `Condition.wait` reacquire with hidden captured JS roots and requires
  sync-wait pump points to deliver both during the same mid-script GC pressure
  window, keeps a typed-array `waitAsync` promise/reaction graph
  reachable only through the native waiter queue until notification, keeps
  pending `Thread.asyncJoin` fulfillment/rejection promise reactions reachable
  only through native completion records until the child threads are released,
  keeps a registered object reachable only through
  `ThreadLocal.value` while that owner is parked, keeps a completed-but-unjoined
  `Thread` result object and a completed-but-unjoined thrown exception object
  reachable only through the thread completion record, then delivers the
  expected `FinalizationRegistry` cleanup count/sum after a quiescent collect.
  The promise-publication subprogram keeps a child-returned typed-array
  `waitAsync` promise pending through the sweep, keeps a child-returned rejected
  promise and a child-returned user thenable parked behind pre-completion
  `asyncJoin()` observers, and verifies post-sweep `Thread.asyncJoin()`
  fulfillment/rejection/thenable assimilation plus `Thread.join()` returning the
  original promise/thenable for post-completion observers; it also keeps a
  child-thrown object with a nested promise rooted through completion state
  until post-sweep `asyncJoin()`/`join()` publication.
  The sync-wait cleanup subprogram parks peers in property `Atomics.wait`,
  `Condition.wait`, and contended `Lock.hold` acquisition through a finishing
  sweep, then verifies each resumed peer's stack root plus exact
  `FinalizationRegistry` cleanup count/sum delivery.
  The pending-microtask subprogram keeps Promise, typed-array `waitAsync`,
  `Thread.asyncJoin`, with-fn `Lock.asyncHold`, no-fn release-function, and
  `FinalizationRegistry` cleanup roots queued through a finishing mid-script
  sweep, then drains the realm run loop and checks exact reaction/cleanup
  oracles.
  The creator-owned buffer subprogram leaves child-created
  `SharedArrayBuffer` and `ArrayBuffer` storage rooted through unjoined
  `Thread` completion records and delayed `asyncJoin` observers across a
  finishing sweep, then verifies blocking `join()`, post-sweep `asyncJoin()`,
  and `ArrayBuffer.transfer()` observers see exact contents after the creating
  thread has exited.
  The Worker/SAB cleanup subprogram runs isolated Workers on the same retained
  `SharedArrayBuffer` while shared-realm `Thread`s register cleanup targets and
  park stack roots through a finishing sweep, then verifies exact Worker
  progress, joined thread roots, asyncJoin reactions, and cleanup count/sum.
  The teardown subprogram parks children after installing child-owned typed-array
  `waitAsync` tickets, verifies pending `asyncJoin` rejection reactions with
  captured roots after the parent throws, and proves post-termination notify
  wakes zero leaked child waitAsync tickets.
- Host-side thread queues are now explicit GC roots: queued `Lock.asyncHold`
  tasks in `Gil.tasks`, per-lock pending grants, async condition waiters,
  typed-array `waitAsync` waiter/reaction roots, pending `Thread.asyncJoin`
  promise/reaction roots, ThreadLocal values, thread completion results,
  release-function lock records, and contended `Lock.hold` receiver/callback
  pairs trace or temp-root their hidden JS values instead of relying on a JS
  property path or native stack scan. Join-side parked-root state now clears
  and releases the completion mutex on termination/error unwinds, and joiners
  only publish `gc_parked` for the actual native condition wait rather than
  while pumping tasks, so failed or active `Thread.join()` calls do not leave
  stale or moving frozen-peer state behind. Requested shell/host GC leaves an
  elected mid-script parallel collector untouched while threads are live, and a
  later quiescent collection aborts stale parallel mark state before starting a
  fresh precise mark.
- The lifecycle fuzzer profile adds deterministic termination storms where main
  JS throws with parked/unjoined `Thread`s, exact-counter oracles for script
  `Worker`s plus simple-import, diamond-shaped, and fanout/rejoin module
  `Worker`s overlapping shared-realm `Thread`s on one retained
  `SharedArrayBuffer`, Worker/thread/finalization scheduling on one retained
  SAB, Worker termination interleaved with exact shared-realm finalization
  cleanup on a retained SAB, Worker termination while top-level failure tears
  down parked shared-realm `Thread`s, pending `asyncJoin` rejection reactions,
  and already-ready cleanup jobs on the same retained SAB, exact FIFO drain/drop
  ordering for mixed Worker `close` / `terminate` / `postMessage` lifecycles,
  plus worker
  handler-exception recovery, Worker handler-exception recovery composed with
  shared-realm Thread finalization cleanup on one retained SAB,
  `Thread.restrict` lifecycle isolation,
  Thread exception identity through `join()` / `asyncJoin()` while
  property and condition waiters are parked,
  thread-returned typed-array `waitAsync` promise assimilation through `join()` /
  `asyncJoin()` while waiters are parked, typed-array `waitAsync` settlement
  interleaved with `asyncJoin` reactions and exact `FinalizationRegistry`
  cleanup delivery, teardown termination with pending `asyncJoin` rejection
  reactions and child-owned typed-array `waitAsync` tickets that must be
  abandoned before the child exits, cross-thread `FinalizationRegistry`
  cleanup count/sum oracles, teardown termination while property `waitAsync`
  timeout compaction, async condition reacquire, a pending `asyncJoin`
  rejection reaction, and already-ready `FinalizationRegistry` cleanup jobs
  share the same realm turn,
  cleanup delivery interleaved with `join()` /
  `asyncJoin()` and unregister-token suppression, cleanup delivery after parked
  property/condition waiters resume, deterministic `Lock.asyncHold()` barging
  where a sync hold legally overtakes a queued no-fn async ticket before
  `await` delivers its release function, Promise reaction queue churn from
  with-fn `Lock.asyncHold`, no-fn release functions, typed-array `waitAsync`,
  `Thread.asyncJoin`, and exact `FinalizationRegistry` cleanup,
  creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage that survives the
  creating Thread's exit, sibling-thread reads, GC pressure, and post-creator
  `ArrayBuffer.transfer()`, and
  `ThreadLocal` isolation across
  normal, throwing, nested, and async-joined thread lifecycles, plus
  `ThreadLocal` values registered with `FinalizationRegistry` across
  park/resume/clear/join cleanup lifecycles with exact cleanup count/sum
  delivery after quiescent collection, plus child-created SAB/ArrayBuffer
  storage crossing isolated Worker structured-clone after the creator Thread
  exits.
- CI runs the fuzzer in several modes: default seeded, TSan, high-contention
  amplified, broad semantic,
  mid-script GC wait-pump/microtask/creator-buffer/sync-wait-cleanup/promise/teardown/Worker-SAB,
  lifecycle, ReleaseSafe, and deterministic-result verification.

Remaining: keep extending the lifecycle profile toward more cross-realm
scheduling, richer cleanup/finalization interleavings, more async-grant/
mid-script-GC variants, and additional teardown race variants.

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
- mid-script GC wait-pump/microtask/creator-buffer/sync-wait-cleanup/promise/teardown/Worker-SAB
  `threadfuzz`,
- lifecycle `threadfuzz`,
- ReleaseSafe `threadfuzz`,
- deterministic-result `threadfuzz-verify`,
- sharded no-GIL PR-249 corpus TSan sweep,
- TSan suppression-narrowness witness
  (`tools/tsan-suppression-witness.sh`),
- test262-parallel representative slice.

The no-GIL corpus TSan gate hard-blocks on engine-state races. The suppression
witness proves the program-byte suppressions are both load-bearing and narrow.
