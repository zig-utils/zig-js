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
- Treating deep recursive call behavior as a finished VM-stack feature. The
  tree-walker still uses native recursion for calls, so tests requiring
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
  are bucket-local with an address-span reject before chunk-list scans, so frees
  do not scan unrelated size-class chunks
  during collection or teardown. Ownership lookups
  also keep a per-bucket recent-chunk hint, avoiding repeated full bucket walks
  when GC frees/remaps arrive from the same slab chunk. Context teardown also
  skips rebuilding slab freelists and reclassifying bucket ownership for cells
  that will be released by the following whole-chunk free. Single-mutator GC
  object side stores bypass the cell-slab classifier and allocate from the
  context allocator directly; true-parallel JS contexts still route side stores
  through the synchronized backing wrapper because an embedder allocator may not
  be thread-safe. Live `SharedArrayBuffer` retain teardown is covered for arena,
  no-GIL threaded, and `.gil = true` contexts.
  Correctness is gated, but tight-loop block-scope allocation and
  create/destroy-heavy context lifecycles are still slower under the GC path than
  under the old arena model. `zig build gc-profile` remains the repeatable
  baseline before nursery/generational or lifecycle pooling work lands, and now
  splits context lifecycle time into create and destroy columns while also
  including a create-per-task versus long-lived-context reuse table with periodic
  collection to quantify the embedder lifecycle tradeoff plus GC cell-backing
  attribution for an object-heavy allocation run: chunk count, total cell-slot
  capacity, live cells at context creation, live cells after allocation, free
  slots after collection, and live cells after collection.
- **Context lifecycle cost.** Long-lived embedders amortize the GC setup and
  teardown costs, but create-per-unit-of-work embedders need either cheaper
  context lifecycle or clearer guidance.
- **Parallel scaling optimization.** Benchmarks show real speedup, but scaling
  is sub-linear. `zig build threads-profile` now provides a repeatable baseline
  against the `.gil = true` fallback for independent compute, shared object
  properties, shared array append, typed-array Atomics, property
  `Atomics.wait` / `notify`, property `Atomics.waitAsync` timeout settlement,
  `Condition.wait` / `notifyAll`, `Condition.asyncWait`,
  `Lock.asyncHold` delivery, observed `Lock.asyncHold` callback settlement,
  no-fn `Lock.asyncHold` release-function delivery, and lifecycle churn. Use it
  to drive contention reductions in global/environment bindings,
  property/element locks, sync waiters, property `waitAsync` timeout
  settlement, async condition regrant delivery, unobserved async-hold grant
  delivery, promise-observed callback settlement, no-fn release-function
  delivery, collection helpers, and GC allocation. Its `async`/`done` columns
  now split async condition/property-waitAsync registration from completed
  async-condition reacquires plus settled property `waitAsync` tickets, and its
  `empty`/`jobs` columns show whether
  run-loop task-pump overhead is empty fast-path churn or real async-hold
  delivery. Empty sync-wait
  task pumps no longer take the shared run-loop task lock, reducing one measured
  cost in contended lock/lifecycle paths; real async-hold delivery now uses FIFO
  head cursors for both per-lock pending grants and realm task delivery, and
  retry-front grants use an amortized O(1) front stash when no consumed head
  slot is available, so failed grant delivery does not fall back to shifting the
  whole pending list. Realm task delivery copies bounded FIFO bursts under the
  shared API lock before running grants outside it, so queue drains do not
  front-shift remaining jobs or lock once per delivered job. The async-hold task
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
  per-kind wake lists for each notification.
  Promise microtask drains use a FIFO head cursor, so observed async-hold
  callback settlement and no-fn release-function reactions preserve FIFO order
  without shifting the remaining reaction queue on each job.
  Property-mode `Atomics.notify` now stable-compacts matching sync and async
  waiters in one pass: notified sync stack tickets leave the realm waiter table
  before signal, and matching `waitAsync` tickets are collected without repeated
  middle removals. Individual sync wait timeout/termination cleanup also
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
  spawn/post/receive/join/destroy lifecycle cost, so Worker-heavy follow-up
  optimization has its own baseline instead of being inferred from shared-realm
  `Thread` rows.
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
  results, release-function lock records, and contended `Lock.hold`
  receiver/callback pairs now trace, barrier, or temp-root their hidden JS
  values. The mid-GC fuzzer now queues a FIFO `Lock.asyncHold` grant
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
  thrown-object publication, plus a sibling sync-wait cleanup subprogram where
  property `Atomics.wait`, `Condition.wait`, and contended `Lock.hold` peers
  stay parked through a finishing sweep before their stack roots and exact
  `FinalizationRegistry` cleanup count/sum are verified, where expired property
  `waitAsync` tickets compact while those peers are parked and a live property
  `waitAsync` ticket stays rooted through the sweep until notification, plus a sibling
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
  in a parked peer, keeps pending Promise/microtask roots live across
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
  delivery, teardown termination with pending `asyncJoin` rejection reactions
  and child-owned typed-array `waitAsync` tickets that must be
  abandoned before the child exits, cross-thread `FinalizationRegistry`
  cleanup count/sum oracles, teardown termination while property `waitAsync`
  timeout compaction, async condition reacquire, a pending `asyncJoin`
  rejection reaction, and already-ready `FinalizationRegistry` cleanup jobs
  share the same realm turn, Worker termination composed with condition async
  reacquire, pending `asyncJoin` rejection cleanup, and exact
  `FinalizationRegistry` cleanup,
  deterministic `Lock.asyncHold()` barging where a
  sync hold legally overtakes a queued no-fn async ticket before `await`
  delivers its release function, Promise reaction queue churn from with-fn
  `Lock.asyncHold`, no-fn release functions, typed-array `waitAsync`,
  `Thread.asyncJoin`, and exact `FinalizationRegistry` cleanup,
  creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage that survives the
  creating Thread's exit, sibling-thread reads, GC pressure, and post-creator
  `ArrayBuffer.transfer()`, child-created SAB/ArrayBuffer storage crossing
  isolated Worker structured-clone after creator exit, and cleanup
  delivery interleaved with `join()` / `asyncJoin()` plus unregister-token
  suppression, plus cleanup delivery after
  parked property/condition waiters resume, plus `ThreadLocal` values registered
  with `FinalizationRegistry` across park/resume/clear/join cleanup lifecycles
  with exact cleanup count/sum delivery after quiescent collection, plus
  parent-created child `Thread`s whose `asyncJoin()` promises outlive the parent
  Thread's local queue before child release, nested `ThreadLocal` roots,
  rerouted async settlement, and exact finalization cleanup after both thread
  layers exit. Keep
  extending it toward more teardown ordering, broader cross-realm scheduling,
  and richer cleanup/finalization interleavings.
- **Reference-only PR-249 files.** Promote only when the engine implements the
  behavior and the file is reliable under Zig `0.17-dev`, especially the
  WebAssembly-required files, JIT/shell-hook witnesses, deep stack-overflow
  cases, and real heap cap / per-thread OOM semantics.
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
