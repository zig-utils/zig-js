# Limits & Roadmap

The core JavaScript multithreading architecture for issue #1 is implemented:
isolated agents/workers, shared memory, structured clone, Workers, and
shared-realm `Thread`s are all present, and shared-realm threads run
true-parallel by default. The remaining work is production hardening:
performance, documentation, stress breadth, and promotion of reference-only
tests as the matching engine features land.

## Supported Today

- Agent and worker isolation: one `Context` per OS thread, values crossing by
  structured clone or retained `SharedArrayBuffer` storage.
- Shared-realm `Thread`: one `Context`, one heap, one global object, real OS
  threads, same-realm identity, and no-GIL parallel execution by default.
- Serialized shared-realm fallback:
  `Context.createWith(.{ .enable_threads = true, .gil = true })`.
- C embedder surface: `ZJSGlobalContextCreateThreaded(gil)`.
- Typed-array `Atomics.wait` / `notify` / `waitAsync` over shared buffers.
- Property-mode `Atomics.load` / `store` / `exchange` /
  `compareExchange` / RMW / `wait` / `waitAsync` / `notify`.
- `Thread`, `Lock`, `Condition`, `ThreadLocal`, `ConcurrentAccessError`,
  `Atomics.Mutex`, and `Atomics.Condition`.
- GC-managed parallel contexts with thread-safe allocation, write barriers,
  root tracing for active VM frames, conservative stack scanning where sound,
  and abort-safe mid-script collection experiments.
- Test-shell helpers such as `print`, `setTimeout`, `drainMicrotasks`, `gc`,
  and supported `$vm` compatibility hooks for conformance coverage.

## Explicit Non-Goals / Not Stable

- Sharing ordinary JS values between isolated agents or workers without
  structured clone.
- Treating test-shell helpers or `$vm` as an embedder event-loop/API surface.
- Treating `Context.TestingOptions.parallel_js`,
  `Context.TestingOptions.parallel_midscript_gc`, or other testing knobs as
  public API.
- Assuming unsupported JSC `$vm` hooks exist: `sharedHeapTest`, dictionary
  conversion, code deletion, disassembly, stop counters, and related JIT
  artifact controls are absent until backed by real engine behavior.
- Treating JavaScript-level data races as engine-level synchronization. For
  example, racing accesses to shared buffer program bytes are JS program races;
  ThreadSanitizer suppressions are deliberately limited to those program-byte
  frames and are guarded by a suppression-narrowness witness. See
  [Memory Model](./memory-model.md).
- Treating deep recursive call behavior as a finished VM-stack feature. VM and
  tree-walker calls both throw catchable `RangeError`s before native stack
  overflow, but they still consume native stack per call, so tests requiring
  thousands of pre-overflow calls remain future work.
- Treating remaining WebAssembly/JIT-specific PR-249 files as implemented when
  the required WebAssembly surface, JIT artifact hooks, or JSC shell controls do
  not exist in this engine.

## C-API and Context Affinity

The C API keeps the original rule for non-threaded contexts: handles are
affine to the thread that owns their `JSContextRef`.

Threaded contexts should be created with `ZJSGlobalContextCreateThreaded(gil)`.
With `gil == false`, the context uses the same no-GIL parallel path as
`Context.createWith(.{ .enable_threads = true })`. With `gil == true`, the
context uses the serialized fallback and embedders must respect the GIL model.

`JSStringRef` values are immutable and use atomic retain/release. GC-enabled
`JSValueRef` wrappers use counted `JSValueProtect` / `JSValueUnprotect` roots.
Do not infer cross-thread handle semantics beyond the documented threaded
context APIs.

## Remaining Roadmap

- **GC allocation fast path / nursery.** The first cell-allocation fast path has
  landed: GC cells use a reusable size-class slab backing instead of calling the
  backing allocator for every cell. Fresh chunks now use lazy bump cursors with
  a per-bucket bump hint instead of pre-linking every unused slot during
  short-lived context setup, and a per-bucket fresh-chunk cursor skips chunks
  whose bump range is already exhausted. Freed-cell, capacity, and issued-slot
  accounting is maintained per bucket, so GC cell-backing stats no longer walk
  every free-list node or slab chunk after a collection. Slab ownership checks
  are bucket-local with an address-span reject before the recent-chunk hint and
  sorted per-bucket chunk address index, so frees do not scan unrelated
  size-class chunks or linearly walk a large bucket during collection or
  teardown. Context teardown also
  skips rebuilding slab freelists for owned cells that will be released by the
  following whole-chunk free, while bucket-shaped delegated side allocations
  still classify once and free through the wrapped allocator. Non-owned
  bucket-shaped resize/remap/free paths also reuse the classification lock
  instead of retaking it before delegation. Single-mutator GC object side stores
  bypass the cell-slab classifier and allocate from the context allocator
  directly; true-parallel JS contexts still route side stores through the
  synchronized backing wrapper because an embedder allocator may not be
  thread-safe. GC-enabled context creation now groups the heap, root-tracing
  binding, and cell backing in one stable lifecycle state allocation instead of
  three separate GPA objects, reducing create/destroy allocator churn while
  keeping the existing internal pointers stable. Live `SharedArrayBuffer` retain
  teardown is covered for arena, no-GIL threaded, and `.gil = true` contexts.
  Correctness is gated, but tight-loop block-scope allocation and
  create/destroy-heavy context lifecycles are still slower under the GC path than
  under the old arena model. `zig build gc-profile` remains the repeatable
  baseline before nursery/generational or lifecycle pooling work lands, and now
  splits context lifecycle time into create and destroy columns while also
  including a create-per-task versus long-lived-context reuse table with periodic
  collection to quantify the embedder lifecycle tradeoff, plus a workload destroy
  table that compares live object-heavy destroy against quiescent pre-collection
  and post-collection destroy. That keeps finalizer draining visible separately
  from teardown that remains after a collection. The profile also prints GC
  cell-backing attribution for both the intrinsic empty-context footprint and an
  object-heavy allocation run: chunk count, total cell-slot capacity, live cells
  at context creation, live cells after allocation, free slots after collection,
  and live cells after collection. The same profile now follows with
  per-size-class bucket tables for the empty context and the object workload, so
  future nursery/generational and context-lifecycle work can separate global
  setup pressure from workload pressure while targeting the slot sizes that
  dominate chunk count, issued cells, free cells, and surviving live cells. The
  object-sized 1024/2048-byte buckets now use 384 KiB chunks: the local profile
  keeps the intrinsic empty context at three object-cell chunks with 1152 slots,
  and the object-heavy profile at roughly 55 object-cell chunks instead of the
  former 83, without the reserved-slot overhang of a 512 KiB chunk. It also
  splits GC finalizer attribution between empty-context destroy and destroy
  after the object workload.
- **Context lifecycle cost.** Long-lived embedders amortize the GC setup and
  teardown costs, but create-per-unit-of-work embedders need either cheaper
  context lifecycle or clearer guidance.
- **Parallel scaling optimization.** Benchmarks show real speedup, but scaling
  is sub-linear. `zig build threads-profile` now provides a repeatable baseline
  against the `.gil = true` fallback for independent compute, shared object
  properties, shared array append, typed-array Atomics, property
  `Atomics.wait` / `notify`, property `Atomics.waitAsync` timeout settlement,
  `Condition.wait` / `notifyAll`, single-lock and multi-lock `Condition.asyncWait`,
  `Lock.asyncHold` delivery, observed `Lock.asyncHold` callback settlement,
  no-fn `Lock.asyncHold` release-function delivery, and lifecycle churn. Use it
  to drive contention reductions in global/environment bindings,
  property/element locks, sync waiters, property `waitAsync` timeout
  settlement, async condition regrant delivery, unobserved async-hold grant
  delivery, promise-observed callback settlement, no-fn release-function
  delivery, collection helpers, and GC allocation. Its `joins` columns split
  `Thread.join` parks from aggregate park pressure, its `lock`/`cond`/`prop`
  columns split the remaining sync park pressure by contended `Lock.hold`,
  `Condition.wait`, and property `Atomics.wait`, its `async`/`done` columns
  now split async condition/property-waitAsync registration from completed
  async-condition reacquires plus settled property `waitAsync` tickets, and its
  `empty`/`jobs` columns show whether run-loop task-pump overhead is empty
  fast-path churn or real grant delivery, with `hold`/`cjob` splitting the
  delivered jobs into ordinary `Lock.asyncHold` grants versus
  `Condition.asyncWait` reacquire grants. Empty sync-wait
  task pumps no longer take the shared run-loop task lock, reducing one measured
  cost in contended lock/lifecycle paths; task-queue writers publish the
  pending-count hint from the locked queue length instead of writer-side atomic
  RMW; real async-hold delivery now uses FIFO
  head cursors for both per-lock pending grants and realm task delivery, and
  retry-front grants use an amortized O(1) front stash when no consumed head
  slot is available, so failed grant delivery does not fall back to shifting the
  whole pending list. Realm task delivery copies larger bounded FIFO bursts
  under the shared API lock before running grants outside it, so queue drains do
  not front-shift remaining jobs and already-queued grant storms need fewer
  shared-lock acquisitions. The async-hold task
  pump also snapshots the microtask enqueue
  generation around each grant, so unobserved grants that settle without queued
  reactions skip an otherwise-empty no-GIL microtask drain while preserving
  checkpoint order for grants that do enqueue reactions. No-fn async-hold grants
  embed their once-only release state in the already arena-lived hold job, so
  delivered release functions avoid a second small state allocation. Condition
  notify/notifyAll also dequeues the mixed sync/async
  waiter queue through a FIFO head cursor instead of shifting every notified
  waiter. Timed-out or terminated sync condition waiters are marked canceled and
  skipped by that cursor instead of being removed from the middle of the queue.
  Sync notifyAll handoff now waits on the condition ack signal instead of a
  fixed 1ms polling sleep, reducing ready-waiter latency without changing the
  timeout fallback. Async-only condition notifications now move no-fn async
  regrant preparation outside the condition queue mutex; mixed sync/async
  wakeups keep the existing sync handoff ordering. Notify records woken
  sync/async entries in one pre-sized wake list instead of allocating separate
  per-kind wake lists for each notification. Contiguous async condition
  regrants for the same lock are prepared in fixed-size stack batches and
  applied under one lock acquisition per batch, so `notifyAll()` no longer
  retakes that lock once per async waiter. Ready async-condition reacquire jobs
  are appended to the realm task queue in FIFO bursts, amortizing the shared API
  lock when a notification wakes multiple lock groups, and sync handoff
  completion uses a pending-waiter countdown instead of rescanning that wake
  list until every ticket acknowledges.
  Promise microtask drains use a FIFO head cursor, so observed async-hold
  callback settlement and no-fn release-function reactions preserve FIFO order
  without shifting the remaining reaction queue on each job.
  Property-mode `Atomics.notify` now stable-compacts matching sync and async
  waiters in one pass: notified heap-owned sync tickets leave the realm waiter
  table before signal, and matching `waitAsync` tickets are collected without
  repeated middle removals. Individual sync wait timeout/termination cleanup also
  stable-compacts the waiter table in one pass instead of shifting the remaining
  waiters. Timeout polling now uses the same one-pass compaction shape for
  expired property `waitAsync` tickets, and realm teardown frees abandoned
  property `waitAsync` tickets by linear scan. Typed-array `Atomics.notify`
  unlinks notified sync stack tickets before signal, and typed-array
  `waitAsync` harvest/abandon paths stable-compact settled or owner tickets in
  one pass while preserving FIFO order for remaining waiters. Worker
  inbox/outbox channels now drain
  structured-clone messages with FIFO head cursors as well, avoiding front
  shifts in receive-heavy Worker loops. `$262.agent` report delivery uses the
  same FIFO head-cursor shape, so report-heavy Atomics/test262 agent cases do
  not shift the whole report queue on each `getReport()`. Empty internal
  `Worker.receive(..., 0)` polls return under the channel lock without entering
  a timed condition wait or touching drained-queue compaction. Active interpreter roots, protected
  C-API handles, and GIL park records are unordered root sets, so removal now
  uses swap semantics instead of order-preserving list shifts on evaluate,
  handle-unprotect, and thread teardown paths. WeakMap/WeakSet delete and GC
  dead-key pruning now use unordered tail removal too, and
  FinalizationRegistry `unregister` removes matching records with one stable
  compaction pass so survivor cleanup order is preserved without repeated
  middle shifts.
  The profile now includes a separate isolated `Worker` section for
  structured-clone inbox/outbox round-trips, empty receive polling, and
  spawn/post/receive/join/destroy lifecycle cost, with separate script and
  module Worker rows so import-graph startup/lifecycle pressure has its own
  baseline instead of being inferred from shared-realm `Thread` rows.
- **Memory model maintenance.** Keep [Memory Model](./memory-model.md) aligned
  with the TSan suppression witness, new synchronization primitives, and any
  promoted PR-249 coverage that exercises JS-defined races.
- **Mid-script parallel GC maturity.** The abort-safe collector now has
  cooperative root publication at sync-wait pump points, covering property
  `Atomics.wait`, `Condition.wait`, and contended `Lock` acquisition without
  tracing those peers as frozen parked stacks. Host-side thread queues are part
  of the root set too: `Gil.tasks`, `LockRecord.pending`, async condition
  waiters, typed-array `waitAsync` waiter/reaction roots, pending
  `Thread.asyncJoin` promise/reaction roots, ThreadLocal maps, thread completion
  results, protected C-API handles, release-function lock records, and
  contended `Lock.hold` receiver/callback pairs now trace, barrier, or
  temp-root their hidden JS values. A focused C-API unit witness now protects an
  otherwise-unrooted object while shared-realm `Thread`s drive a finishing
  mid-script parallel sweep, then proves that `JSValueProtect` keeps the object
  alive until the final `JSValueUnprotect`. The mid-GC fuzzer now queues a FIFO
  `Lock.asyncHold` grant
  chain including a root-bearing rejected grant, an async `Condition.wait`
  reacquire path with captured JS roots, a typed-array `waitAsync` reaction
  graph reachable only through the native waiter queue, and pending
  `Thread.asyncJoin` fulfillment/rejection reaction graphs reachable only
  through native completion records; it also runs a sibling expected-termination
  subprogram where parked children hold child-owned typed-array `waitAsync`
  tickets through a finishing mid-script sweep, then teardown `asyncJoin`
  rejection reactions run and post-termination notify sees zero leaked waitAsync
  tickets, plus a sibling promise-publication subprogram where a child-returned
  typed-array `waitAsync` promise, a child-returned rejected promise, a
  child-returned user thenable, and a child-thrown object remain rooted through
  thread completion/native waiter state until post-sweep
  `join()`/`asyncJoin()` fulfillment, rejection, thenable assimilation, and
  thrown-object publication, plus a sibling property `Atomics.waitAsync`
  late-settlement subprogram where finite-timeout property tickets are removed
  after the registering child queue has closed, then rerouted through realm
  draining to exact `join()`/`asyncJoin()` observers after a finishing sweep,
  plus a sibling sync-wait cleanup subprogram where
  property `Atomics.wait`, `Condition.wait`, and contended `Lock.hold` peers
  stay parked through a finishing sweep before their stack roots and exact
  `FinalizationRegistry` cleanup count/sum are verified, where expired property
  `waitAsync` tickets compact while those peers are parked and a live property
  `waitAsync` ticket stays rooted through the sweep until notification, and
  where an isolated Worker stays parked on a retained `SharedArrayBuffer`
  through the same sweep before its reply is verified, plus a sibling
  sync-wait burst subprogram where multiple waiters on the same property, the
  same `Condition`, and the same contended `Lock` stay parked through a
  finishing sweep before burst release and exact finalization cleanup, plus a sibling
  sync-timeout subprogram where property `Atomics.wait` and static
  `Atomics.Condition.waitFor` peers stay parked through a finishing sweep,
  reject early cleanup while their stack roots are live, then time out with
  exact `UnlockToken` reacquisition/unlock and finalization cleanup, plus a sibling
  `Atomics.Mutex.lockIfAvailable` subprogram where acquire-after-release and
  timeout token waiters stay parked behind a holder through a finishing sweep,
  reject early cleanup while their roots are live, then verify reused-token
  acquire/timeout results and exact finalization cleanup, plus a sibling
  static `Atomics.Condition.wait` subprogram where notify/reacquire token
  waiters stay parked through a finishing sweep, reject early cleanup while
  their roots are live, then verify exact notify counts, token reacquisition,
  `asyncJoin` observers, and finalization cleanup, plus a sibling
  async-hold release cleanup subprogram where no-fn `Lock.asyncHold()` release
  functions are delivered while property and condition waiters stay parked
  through a finishing sweep before exact cleanup count/sum is verified, plus a sibling
  nested parent/child `Thread.asyncJoin` cleanup subprogram where parent
  `ThreadLocal` roots, child `ThreadLocal` roots, child completion records, and
  asyncJoin reactions stay live through a finishing sweep before exact cleanup
  count/sum is verified, plus a sibling
  pending-microtask subprogram where Promise, typed-array `waitAsync`,
  `Thread.asyncJoin`, with-fn `Lock.asyncHold`, no-fn release-function, and
  `FinalizationRegistry` cleanup roots stay queued through a finishing sweep
  until exact post-drain reaction/cleanup checks pass, plus a sibling
  creator-owned buffer subprogram where child-created `SharedArrayBuffer` and
  `ArrayBuffer` storage stays rooted through unjoined `Thread` completion
  records and delayed `asyncJoin` observers until blocking `join()`,
  post-sweep `asyncJoin()`, and `ArrayBuffer.transfer()` observers verify exact
  contents after the creator exits, plus a weak-collection subprogram where
  live WeakMap values stay reachable only through live weak keys, dead
  WeakMap/WeakSet targets are reachable only through weak structures and
  WeakRefs, and FinalizationRegistry unregister-token records compact while
  property `Atomics.wait`, `Condition.wait`, and contended `Lock.hold` peers
  stay parked through a finishing sweep, then live ephemeron values, cleared
  dead refs, exact cleanup count/sum, and exact unregister suppression are
  verified, plus script Worker/SAB and module Worker/SAB cleanup subprograms
  where isolated Workers keep progressing on a retained `SharedArrayBuffer`
  while shared-realm `Thread`s publish cleanup targets and parked stack roots
  through a finishing sweep, plus sibling script/module Worker handler-exception
  cleanup subprograms that recover from an expected thrown `onmessage` before
  proving the same Worker progress and cleanup oracle, plus script/module
  Worker close/terminate subprograms that preserve exact FIFO drain/drop,
  post-close drop, post-terminate silence, joined roots, asyncJoin reactions,
  and cleanup count/sum through the finishing sweep. Sync-wait pump points
  must execute the async grants during the
  same allocation-pressure window that produces a finishing parallel sweep, and
  the `waitAsync` reaction must run intact after notification. Join-side
  `gc_parked` state is balanced on termination/error unwinds and scoped to the
  actual native condition wait rather than join-time task pumping, so a failed
  or active `Thread.join()` cannot leave the interpreter looking like a stale or
  moving frozen parked peer. Requested shell/host GC does not disturb an elected
  mid-script parallel collector while threads are live; later quiescent
  collection aborts stale parallel mark state before a fresh precise mark.
  Keep quiescent collection as the fallback for cycles that still cannot
  converge, and keep widening wait/cleanup stress around this protocol.
- **Fuzzer breadth.** The broad `threadfuzz` profile now covers caught
  exceptions/finally, nested thread lifecycle, `asyncJoin`, property
  `wait`/`waitAsync`, `Condition`, `Thread.restrict`, and
  `FinalizationRegistry` cleanup under GC-backed parallel contexts. The mid-GC
  profile now hammers sync-wait root publication during finishing
  `parallel_midscript_gc` sweeps, executes a queued async-hold grant chain
  including rejected grant reactions and async condition reacquire grants from
  those pump points, keeps a typed-array `waitAsync` promise/reaction graph live
  only through the native waiter queue,
  keeps pending `Thread.asyncJoin` fulfillment/rejection reactions live only
  through native completion records, keeps a ThreadLocal-only hidden root live
  in a parked peer, parks ThreadLocal-only `FinalizationRegistry` targets
  through a finishing sweep before clearing them with an exact cleanup oracle,
  and parks Thread.restrict-owned finalization targets through a finishing sweep
  while nested foreign access still throws `ConcurrentAccessError` before owner
  release,
  keeps pending Promise/microtask roots live across
  asyncHold callback/release delivery, typed-array `waitAsync`,
  `Thread.asyncJoin`, and cleanup reactions, keeps completed-but-unjoined
  Thread result and thrown exception objects live through the thread completion
  record, keeps creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage live
  through unjoined Thread completion records and delayed `asyncJoin` observers,
  verifies isolated script/module Worker/SAB progress plus script/module Worker
  handler-exception recovery and close/terminate drain/drop while shared-realm
  cleanup roots are swept, and
  verifies exact `FinalizationRegistry` cleanup count/sum delivery afterward. The lifecycle
  profile now adds deterministic termination storms,
  script Worker/thread retained-`SharedArrayBuffer` overlap, simple-import,
  diamond-shaped, and fanout/rejoin module Worker/thread overlap with exact
  Atomics counter oracles, Worker/thread/finalization scheduling on one retained
  SAB, Worker termination interleaved with exact shared-realm finalization
  cleanup on a retained SAB, Worker termination while top-level failure tears
  down parked shared-realm `Thread`s, pending `asyncJoin` rejection reactions,
  and already-ready cleanup jobs on the same retained SAB, module Worker
  termination with the same shared-realm teardown/reaction/cleanup oracle, exact
  FIFO drain/drop ordering for mixed script and module Worker
  terminate/close/postMessage lifecycles, worker
  handler-exception recovery, and Worker handler-exception recovery composed
  with shared-realm Thread finalization cleanup on one retained SAB, module
  Worker handler-exception recovery composed with the same retained-SAB cleanup
  oracle, plus
  `Thread.restrict`
  lifecycle isolation plus `Thread.restrict`-owned `FinalizationRegistry`
  cleanup after owner-thread exit, Thread
  exception identity through `join()` / `asyncJoin()` while property and
  condition waiters are parked,
  thread-returned typed-array `waitAsync` promise assimilation through `join()` /
  `asyncJoin()` while waiters are parked, typed-array `waitAsync` settlement
  interleaved with `asyncJoin` reactions and exact `FinalizationRegistry`
  cleanup delivery, `Condition.asyncWait` reacquire delivery interleaved with
  `join()` / `asyncJoin()` reactions and exact `FinalizationRegistry` cleanup
  delivery, proposal-style `Atomics.Mutex` / `Atomics.Condition.waitFor` token
  waiters that take both notify and timeout paths while `asyncJoin` observers
  and exact cleanup share the same lifecycle window, `Atomics.Mutex.lockIfAvailable`
  token waiters that take both acquire-after-release and timeout paths with
  reused tokens in that same cleanup window, teardown termination with
  pending `asyncJoin` rejection reactions
  and child-owned typed-array `waitAsync` tickets that must be
  abandoned before the child exits, cross-thread `FinalizationRegistry`
  cleanup count/sum oracles, teardown termination while property `waitAsync`
  timeout compaction, async condition reacquire, a pending `asyncJoin`
  rejection reaction, and already-ready `FinalizationRegistry` cleanup jobs
  share the same realm turn, Worker termination composed with condition async
  reacquire, pending `asyncJoin` rejection cleanup, and exact
  `FinalizationRegistry` cleanup, Worker termination composed with child-owned
  typed-array `waitAsync` ticket abandonment, pending `asyncJoin` rejection
  cleanup, and exact `FinalizationRegistry` cleanup, module Worker termination
  composed with the same child-owned typed-array `waitAsync` ticket
  abandonment, pending `asyncJoin` rejection cleanup, and exact
  `FinalizationRegistry` cleanup,
  deterministic `Lock.asyncHold()` barging where a
  sync hold legally overtakes a queued no-fn async ticket before `await`
  delivers its release function, no-fn `Lock.asyncHold()` release-function
  delivery while property and condition waiters stay parked before exact cleanup
  after they resume, Promise reaction queue churn from with-fn
  `Lock.asyncHold`, no-fn release functions, typed-array `waitAsync`,
  `Thread.asyncJoin`, and exact `FinalizationRegistry` cleanup,
  property `Atomics.waitAsync` late settlement where peer timeout polling races
  an owning Thread closing its stack-local microtask queue,
  post-completion `Thread.asyncJoin()` promises plus sibling cleanup roots
  staying live after blocking joins while property waiters stay parked through
  a finishing sweep,
  creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage that survives the
  creating Thread's exit, sibling-thread reads, GC pressure, and post-creator
  `ArrayBuffer.transfer()`, child-created SAB/ArrayBuffer storage crossing
  isolated Worker structured-clone after creator exit plus sibling script and
  module Worker clone/finalization cleanup/transfer observer variants, and
  cleanup
  delivery interleaved with `join()` / `asyncJoin()` plus unregister-token
  suppression, plus cleanup delivery after
  parked property/condition waiters resume, plus `ThreadLocal` values registered
  with `FinalizationRegistry` across park/resume/clear/join cleanup lifecycles
  with exact cleanup count/sum delivery after quiescent collection, plus
  parent-created child `Thread`s whose `asyncJoin()` promises outlive the parent
  Thread's local queue before child release, nested `ThreadLocal` roots,
  rerouted async settlement, and exact finalization cleanup after both thread
  layers exit, plus post-completion `Thread.asyncJoin()` fulfillment and
  rejection observers settling after blocking joins while property waiters stay
  parked before exact cleanup.
  CI now runs small TSan smoke seeds for both the mid-script-GC
  and lifecycle profiles in addition to their larger non-TSan breadth gates, and
  nightly/manual CI extends sanitizer depth with higher-iteration default,
  mid-script-GC, and lifecycle fuzz sweeps. That keeps hidden-root,
  parked-waiter, Worker, cleanup, termination, and async-join combinations
  race-gated while deeper sanitizer expansion continues. Keep extending it
  toward more teardown ordering, broader cross-realm scheduling, and richer
  cleanup/finalization interleavings.
- **Reference-only PR-249 files.** Promote only when the engine implements the
  behavior and the file is reliable under Zig `0.17-dev`, especially the
  WebAssembly-required files, JIT/shell-hook witnesses, deep stack-overflow
  cases, and real heap cap / per-thread OOM semantics. Run
  `python3 tools/threads-reference-audit.py --run-probes --expect-current-blockers --probe-timeout 60`
  to keep the nearest-probe negative baseline honest: it passes only while
  those files still fail or time out with their documented blocker evidence,
  and fails when a candidate starts passing or changes failure shape. Use
  `python3 tools/threads-reference-audit.py --format json` when automation needs
  the same counts, blocker categories, promotion probes, and expected blocker
  evidence without scraping human-readable output.
- **TC39 structs tracking.** Keep `proposal-structs` tracking in
  [P8-structs.md](./P8-structs.md) and this issue; do not split it into a
  parallel tracker.

## Contribution Rule

No new process-global mutable state may land without a ruling in
[bindings.md](./bindings.md). Use one of:

- `per-thread`: each agent or shared-realm thread gets its own state,
- `locked`: shared state is protected by a mutex or atomics,
- `refused`: the state must never be reachable from a second thread.

This rule applies to file-scope `var`, `pub var`, `threadlocal`, and
container-scope mutable statics.
