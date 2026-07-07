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
- VM-recursive calls use the same catchable stack guard as tree-walker calls,
  so bytecode recursion raises `RangeError` before native stack overflow.
  Recursion depth is native-stack-bound (the `stack_scan` redzone probe, not the
  16384 logical cap), so spawned `Thread`s now run on a 64 MiB stack — lifting
  worker recursion from ~577 to ~2337 frames (release), into the thousands the
  PR-249 deep-stack case needs. The main realm's depth is not a fixed cap: the
  guard is native-stack-bound (`stack_scan.nearLimit` probes the running thread's
  registered OS bounds), so it **auto-adapts to whatever stack the embedder's
  owner thread has** — a context created on a small (~8 MiB default) owner thread
  gets ~576 frames, one created on a large owner thread gets proportionally more,
  with no library change. The library cannot resize the embedder's own thread
  (the owner-thread affinity model binds `evaluate` to it via
  `assertOwnerThread`), so deep *main-realm* recursion is an embedder choice:
  create the context on a thread spawned with a larger `stack_size`, or run the
  deep-recursing code inside a `new Thread(...)` (spawned workers already get the
  64 MiB stack). Deep recursion beyond the native stack is now handled on the
  bytecode VM by a **call trampoline** (`vm.runDriver`): a JS→JS `.call` under
  the driver pushes an explicit heap `Activation` (frame + operand `exec` + saved
  caller state) instead of recursing natively, so a VM-compiled recursive
  function is bounded by the `max_call_depth` (16384) logical ceiling / heap, not
  the OS stack — e.g. `r(8000)` returns on an 8 MiB thread where a native path
  RangeErrors far earlier. Throws unwind the activation stack; each activation's
  `exec` is a precise GC root; `execLoop` (top-level program and generator/async
  bodies) and method/`new`/spread calls keep native dispatch (a method's *own*
  internal recursion still trampolines via its nested driver). Validated across
  the full Linux TSan gate. Tree-walked functions (constructs outside the
  compiler's lowering subset) still recurse natively, adapting to the owner
  thread stack as above.
- Active VM frame slots are traced as GC roots, not only operand stacks, closing
  the mid-script parallel-GC use-after-free found by the fuzzer.
- `-Dtest262-parallel-js` runs a broad language-surface slice in GIL-free
  parallel contexts and asserts no new failures versus the baseline.
- PR-249 coverage contains 229 promoted files out of 259 executable PR-249
  files: 227 in normal mode plus 2 `parallel_js`-only witnesses, covered by the
  sharded no-GIL
  ThreadSanitizer corpus gate.
- The no-GIL `cve/mc-dos-waiter-table-storm.js` focused gate covers property
  `Atomics.waitAsync` tickets removed by a peer while their owning spawned
  thread is closing its stack-local microtask queue; late settlements reroute to
  the realm queue instead of stranding reactions after the owner's final flush.
- The reference-only PR-249 tail is checked by
  `zig build threads-reference-audit`, so unsupported shell hooks, JIT,
  WebAssembly, and heap-cap/OOM witnesses stay explicit instead of
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
  storage unchanged. Fresh chunks hand out cells through lazy bump cursors with a
  per-bucket bump hint, so short-lived contexts do not pre-link every unused slot
  before teardown. Ownership classification is now bucket-local too, so
  collection and context teardown first reject pointers outside each bucket's
  address span and do not scan unrelated size-class chunks when freeing a cell.
  A per-bucket recent-chunk hint keeps repeated frees/remaps from the same slab
  on the fast path instead of restarting the bucket chunk walk each time.
  During `Context.destroy`, the backing enters bulk-teardown mode so `zig-gc`'s
  owned-cell frees do not rebuild freelists immediately before the backing
  releases whole chunks. Bucket-shaped delegated side allocations still classify
  once and free through the wrapped allocator, and the non-owned bucket-shaped
  resize/remap/free paths avoid retaking the backing lock after classification.
  This cuts the old one-general-allocator-call-per-cell profile without
  changing the collector API.
  The object-sized 1024/2048-byte buckets now use 384 KiB slab chunks, larger
  than the small cell buckets but smaller than the over-reserving 512 KiB
  alternative. The empty-context profile stays at three object-cell chunks with
  1152 slots, and the object-heavy profile drops to roughly 55 object-cell
  chunks, down from the former 83, while preserving the small-bucket footprint.
  Live `SharedArrayBuffer` retain teardown is also regression covered across the
  arena path, the no-GIL threaded path, and the `.gil = true` serialized
  fallback.
- Single-mutator GC contexts now allocate object side stores directly from the
  context allocator instead of going through the cell-slab classifier only to
  delegate. True-parallel JS contexts keep the synchronized backing wrapper for
  those side stores because the embedder-provided allocator may not be
  thread-safe.
- GC-enabled contexts now allocate the heap, root-tracing binding, and cell
  backing as one stable lifecycle state object instead of three separate GPA
  objects. Existing internal pointers still target the same subobjects, but
  create/destroy-heavy embedders pay fewer allocator calls per GC context.
- No-GIL context bootstrap now keeps the GC heap and cell backing in their
  single-mutator allocation mode until all globals and the `Thread` API are
  installed, then enables parallel heap/allocation locking immediately before
  returning the context. The realm is still unobservable during bootstrap, so
  public semantics are unchanged; locally this moved the `gc-profile`
  `threaded no-gil` create column from roughly 14.2 ms/context to roughly
  12.5 ms/context while the returned context still reports parallel heap and
  backing mode.
- Tight-loop per-scope allocation in the tree-walker is largely addressed: a
  `for`/`for-of`/`for-in` loop reuses one per-iteration binding environment when
  no closure captures it (keyed off `Environment.captured`), a block or a switch
  CaseBlock allocates no environment when it declares nothing block-scoped, and a
  non-arrow call skips building the `arguments` object unless the body could name
  it. A 4M-iteration tree-walked loop with a block body dropped ~74s→15s. What
  remains here is the genuinely per-iteration-allocating case (a captured loop
  binding, or a block that does declare a `let`), which still wants a
  nursery/generational fast path rather than an environment-reuse trick.
- Context create/destroy remains more expensive than the arena model because
  global setup and GC finalization still touch many cells. Long-lived contexts
  amortize this; create-per-task embedders still need additional lifecycle
  reductions or guidance.
- `zig build gc-profile` is the local baseline for those costs. It compares
  arena, explicit-GC, no-GIL threaded GC, and `.gil = true` contexts across
  create/destroy, create-per-task versus long-lived-context reuse with periodic
  collection, workload destroy attribution with and without a prior quiescent
  `collectGarbage()`, object-heavy allocation, block-scoped `let` allocation,
  and explicit `collectGarbage()`. The lifecycle row now breaks create and
  destroy apart, the workload destroy row separates finalizer/collection work
  from post-collection teardown, and the profile also prints GC cell-backing
  attribution for the intrinsic empty-context footprint and for an object-heavy
  allocation run: chunk count, total cell-slot capacity, live cells at context
  creation, live cells after allocation, free slots after collection, and live
  cells after collection, followed by per-size-class bucket tables for the empty
  context and the same workload. The bucket tables show slot size, chunks,
  capacity, issued cells, fresh allocations, reused allocations, freed cells,
  free cells, and live cells, using exact per-bucket free, capacity, issued,
  fresh, reused, and freed counters so profiling a collection no longer walks
  every freed cell or slab chunk. Finalizer attribution is likewise split
  between empty-context destroy and destroy after the object workload. Fresh-slot
  allocation skips slab chunks whose bump range is already exhausted, and the
  object-sized 1024/2048-byte buckets use larger chunks so the profile exposes
  reduced object-cell chunk churn separately from remaining create/destroy
  wall-clock costs. A repeated allocate-plus-collect churn table now reports
  fresh versus reused cells, freed cells, final chunk/live counts, and reuse
  percentage, giving nursery/generational work a direct freelist-reuse baseline
  instead of only a one-shot object workload. The no-GIL bootstrap row should
  also be read against the explicit parallel-lock deferral above: returned
  contexts are fully parallel, but private global/API installation no longer
  measures the atomic allocator lock on every cell allocation.
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
  property `Atomics.waitAsync` timeout settlement, single-lock and multi-lock
  `Condition.asyncWait`, `Lock.hold`, `Lock.asyncHold` delivery, observed
  `Lock.asyncHold` callback settlement, no-fn `Lock.asyncHold`
  release-function delivery, and thread lifecycle churn. Each row enables and
  includes internal contention counters:
  `events` count logical contention (`Lock`/`Condition`/property wait and
  queued `asyncHold` grants), `parks` count timed wait/pump iterations
  including `Thread.join`, `joins` split the `Thread.join` subset out of
  aggregate parks for lifecycle attribution, `lock`/`cond`/`prop` split the
  remaining sync park pressure by contended `Lock.hold`, `Condition.wait`, and
  property `Atomics.wait`, `waitus`/`jus`/`lus`/`cus`/`pus` split total native
  wait microseconds plus join/lock/condition/property wait microseconds,
  `async`/`done` split
  `Condition.asyncWait` plus property `waitAsync` registration from completed
  async-condition reacquires plus settled property `waitAsync` tickets, and
  `empty`/`jobs` split the run-loop task pump into empty fast-path hits and
  delivered grant jobs while `hold`/`cjob` split those delivered jobs into
  ordinary `Lock.asyncHold` grants and `Condition.asyncWait` reacquire grants.
- Parked sync waiters still pump the realm run-loop so async-hold grants make
  progress, but empty pumps now use an atomic queue-count fast path and avoid
  taking the shared threading API lock.
- Async-hold delivery also dequeues both the per-lock pending grant list and the
  realm task queue with FIFO head cursors instead of front-shifting lists,
  keeping delivery cost proportional to delivered jobs rather than pending queue
  length. Retry-front async-hold grants use an amortized O(1) front stash when
  no consumed head slot is available, so failed grant delivery does not shift
  the whole per-lock pending list. Task-queue writers publish the
  `tasks_queued` empty/pending hint from the locked queue length instead of
  doing writer-side atomic RMW, reducing one shared counter cost in async-grant
  registration and delivery. Task pumps now copy larger bounded FIFO bursts
  under the shared threading API lock and run every grant outside it, reducing
  delivery lock acquisitions from once per job to once per burst and needing
  fewer shared-lock acquisitions for already-queued grant storms; they also
  snapshot the microtask enqueue generation around each delivered grant, so
  unobserved grants that enqueue no reactions skip an otherwise-empty no-GIL
  microtask drain while preserving checkpoint order for grants that do enqueue
  reactions.
- Promise microtask drains now use a FIFO head cursor instead of
  `orderedRemove(0)`, so observed async-hold callback settlement and no-fn
  release-function reactions do not shift the remaining reaction queue on every
  delivered job while preserving checkpoint order.
- No-fn `Lock.asyncHold` grants embed their once-only release state in the
  already arena-lived hold job, avoiding an extra small allocation per delivered
  release function while preserving the release-function object and existing
  lock/GC ordering.
- The profile now has direct rows for property `Atomics.waitAsync` finite
  timeout settlement plus single-lock and multi-lock `Condition.asyncWait`
  reacquire delivery, so local performance work can separate async waiter
  registration, property ticket settlement, async-condition reacquire completion,
  FIFO-bursted task enqueue pressure, and run-loop grant delivery instead of
  inferring them from elapsed time alone.
- Condition notify/notifyAll use the same FIFO head-cursor pattern for the
  mixed sync/async waiter queue, avoiding one front-shift per notified waiter.
  Timed-out or terminated sync condition waiters are marked canceled and skipped
  by the head cursor instead of being removed from the middle of the queue.
  Sync notifyAll handoff now waits on the waiter's condition ack signal rather
  than sleeping in fixed 1ms chunks, with the same timeout fallback for spurious
  or missed wakes. Async-only condition notifications now release the condition
  queue mutex before preparing no-fn async regrants, so release-function
  creation and realm task enqueueing no longer run inside that queue critical
  section; mixed sync/async wakeups keep the existing sync handoff ordering.
  Notify records woken sync/async entries in one FIFO wake list; the common
  small-wake path uses a fixed stack buffer, and only larger notifications
  allocate a pre-sized heap list. Contiguous async condition regrants for the
  same lock are prepared in fixed-size stack batches and applied under one lock
  acquisition per batch, so `notifyAll()` no longer retakes that lock once per
  async waiter. Ready async-condition reacquire jobs are appended to the realm
  task queue in FIFO bursts, amortizing the shared API lock when a notification
  wakes multiple lock groups, and sync handoff completion uses a pending-waiter
  countdown instead of rescanning the wake list until every ticket acknowledges.
- Property-mode `Atomics.notify` stable-compacts matching waiter queues in one
  pass. Heap-owned sync wait tickets are unlinked before signal, so awakened
  peers no longer each rescan and front-shift the table on return; matching `waitAsync`
  tickets are collected for post-unlock settlement without repeated middle
  removals. Individual sync wait timeout/termination cleanup now stable-compacts
  the waiter table in one pass instead of front-shifting the remaining waiters.
  Timeout polling now also compacts all expired property `waitAsync` tickets in
  one pass and realm teardown frees abandoned property `waitAsync` tickets by
  linear scan.
- Typed-array `Atomics.notify` now unlinks sync stack tickets before signaling,
  so awakened waiters do not each rescan and shift the process-wide waiter list.
  Typed-array `waitAsync` harvest and abandon paths stable-compact matching
  tickets in one pass while preserving FIFO order for other waiters.
- Worker inbox/outbox channels now use FIFO head cursors for structured-clone
  message queues, so Worker-heavy lifecycle and receive loops do not pay one
  front shift per delivered message. `$262.agent` reports use the same FIFO
  head-cursor shape, so report-heavy Atomics/test262 agent cases avoid one
  front shift per `getReport()`. Empty internal `Worker.receive(..., 0)` polls
  now return from the channel while holding the queue lock instead of entering a
  timed condition wait, and skip drained-queue compaction on the empty fast
  path.
- Active interpreter roots, protected C-API handles, and GIL park records are
  unordered root sets, so their removals now use swap removal instead of
  order-preserving list shifts on evaluate, handle-unprotect, and thread
  teardown paths.
- WeakMap/WeakSet entry delete and GC dead-key pruning are unordered by
  observable JS semantics, so they now use tail removal instead of shifting
  later entries. FinalizationRegistry `unregister` still preserves survivor
  cleanup order, but it does so with one stable compaction pass rather than one
  middle removal per matching record.
- The same `threads-profile` run now includes isolated `Worker` sections for
  structured-clone inbox/outbox round-trips, empty receive polling, and
  teardown. The teardown table splits handler-driven self-close,
  owner-driven host-close drain of queued messages, and hard `terminate()` of
  spinning code, with separate script and module Worker rows so import-graph
  startup and teardown pressure are visible beside plain source Workers. It is
  reported outside the no-GIL versus `.gil = true` table because Workers
  already isolate each `Context` onto its own OS thread.
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
  subprogram, script and module Worker creator-owned cleanup subprograms, a
  nested parent/child `Thread.asyncJoin` cleanup subprogram, a
  finalization/`Thread.asyncJoin` unregister-token cleanup subprogram, a
  typed-array `waitAsync`/finalization cleanup subprogram, a
  `Condition.asyncWait`/finalization cleanup subprogram, a
  `Lock.asyncHold(fn)` throw/finalization cleanup subprogram, a
  ThreadLocal lifecycle subprogram, a ThreadLocal-finalization subprogram, a
  ThreadLocal-termination cleanup subprogram, a
  Thread.restrict lifecycle subprogram, a Thread.restrict-finalization
  subprogram, isolated script Worker/SAB and module
  Worker/SAB cleanup subprograms, script and module Worker/thread finalization
  cleanup subprograms that park isolated Workers on a retained SAB while
  shared-realm Threads publish `FinalizationRegistry` cleanup roots and
  `asyncJoin` observers through a finishing sweep, script and module Worker
  handler-exception cleanup subprograms, script and module Worker
  close/terminate drain/drop subprograms, script and module Worker
  terminate/finalization cleanup subprograms, an async-hold release/waiter
  cleanup subprogram, script and module Worker/thread teardown cleanup
  subprograms, script and module Worker/Condition.asyncWait teardown
  cleanup subprograms, script and module Worker/waitAsync teardown cleanup
  subprograms, script and module Worker/ThreadLocal/asyncHold teardown cleanup
  subprograms, a sync-wait burst
  cleanup subprogram, a sync-timeout exit
  subprogram, an `Atomics.Mutex.lockIfAvailable` acquire/timeout cleanup
  subprogram, an `Atomics.Condition.wait`
  notify/reacquire cleanup subprogram, a weak-collection cleanup subprogram,
  and an expected
  teardown-termination subprogram, and each must finish at least one parallel
  sweep. The wait-pump subprogram queues a
  FIFO `Lock.asyncHold` grant chain including a root-bearing rejected grant plus
  an async `Condition.wait` reacquire with hidden captured JS roots and requires
  sync-wait pump points to deliver both during the same mid-script GC pressure
  window, keeps a typed-array `waitAsync` promise/reaction graph
  reachable only through the native waiter queue until notification, keeps
  pending `Thread.asyncJoin` fulfillment/rejection promise reactions reachable
  only through native completion records until the child threads are released,
  keeps child-returned fulfilled/rejected promises, user thenables, and thrown
  objects published through both `join()` and `asyncJoin()` in the lifecycle
  profile,
  registers child-thread finalization targets with unregister tokens while
  fulfilled and rejected `asyncJoin` observers plus sync-wait peers remain live
  through the finishing sweep,
  keeps typed-array `waitAsync` reaction roots pending while notifying child
  threads stay parked through the finishing sweep before exact asyncJoin and
  cleanup verification,
  keeps `Condition.asyncWait` reacquire tickets and child `asyncJoin` observers
  pending through the finishing sweep before exact reacquire, asyncJoin, and
  cleanup verification,
  keeps queued `Lock.asyncHold(fn)` fulfillment/throw callbacks plus no-fn
  release grants pending while the lock remains held through the finishing
  sweep before exact reaction and cleanup verification,
  keeps a registered object reachable only through
  `ThreadLocal.value` while that owner is parked, keeps a completed-but-unjoined
  `Thread` result object and a completed-but-unjoined thrown exception object
  reachable only through the thread completion record, then delivers the
  expected `FinalizationRegistry` cleanup count/sum after a quiescent collect.
  The focused `C-API: JSValueProtect roots survive mid-script parallel GC` unit
  witness directly covers the protected-handle table as a parallel mid-script
  root: an otherwise unrooted C-API object stays alive through a finishing sweep
  driven by concurrently running shared-realm `Thread`s and is reclaimed after
  the final `JSValueUnprotect`.
  The ThreadLocal lifecycle subprogram parks owner threads with per-thread
  `ThreadLocal.value` objects through a finishing sweep before verifying
  per-thread isolation, nested-thread isolation, thrown-object identity, and
  `asyncJoin` observers.
  The ThreadLocal-finalization subprogram parks owner threads with registry
  targets reachable only through `ThreadLocal.value`, drives a finishing
  mid-script sweep, rejects any early cleanup delivery while those hidden roots
  are live, then clears the values and verifies exact cleanup count/sum after a
  quiescent collection.
  The ThreadLocal-termination cleanup subprogram keeps ThreadLocal-only cleanup
  targets live through a finishing sweep, then forces top-level-failure thread
  teardown, requires blocking joins to observe termination, and verifies exact
  cleanup after the owner-thread entries are released.
  The Thread.restrict lifecycle subprogram parks restricted owner-local objects
  through a finishing sweep before verifying owner isolation, nested foreign
  access rejection, thrown-object identity, and `asyncJoin` observers.
  The Thread.restrict-finalization subprogram parks owner threads with
  restricted owner-local objects registered for finalization, verifies nested
  foreign reads still throw `ConcurrentAccessError`, drives a finishing
  mid-script sweep, rejects early cleanup while those owner-thread roots are
  live, then releases the owners and verifies exact asyncJoin plus cleanup
  oracles after a quiescent collection.
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
  `FinalizationRegistry` cleanup count/sum delivery; it also lets property
  `waitAsync` timeout tickets expire while those sync peers are parked, keeps a
  live property `waitAsync` ticket rooted through the finishing sweep, notifies
  it, keeps an isolated Worker parked on a retained `SharedArrayBuffer` through
  the same sweep, and verifies exact captured-root scoring plus the Worker reply
  after the sweep.
  The sync-wait burst subprogram parks multiple waiters on the same property,
  the same `Condition`, and the same contended `Lock` through a finishing sweep,
  verifies cleanup is not delivered while those stack roots are live, then
  releases all three wait sets and verifies exact cleanup after quiescence.
  The sync-timeout exit subprogram parks property `Atomics.wait` peers and
  static `Atomics.Condition.waitFor` peers through a finishing sweep, verifies
  cleanup is not delivered while their stack roots are live, then requires
  timeout results, `Atomics.Mutex.UnlockToken` reacquisition/unlock, and exact
  cleanup after quiescence.
  The `Atomics.Mutex.lockIfAvailable` subprogram parks acquire-after-release
  and timeout token waiters behind a holder through a finishing sweep, verifies
  cleanup is not delivered while their stack roots are live, then requires
  reused-token acquire and timeout results plus exact cleanup after quiescence.
  The static `Atomics.Condition.wait` subprogram parks notify/reacquire token
  waiters through a finishing sweep, verifies cleanup is not delivered while
  their stack roots are live, then requires exact notify counts, token
  reacquisition, `asyncJoin` observers, and cleanup after quiescence.
  The pending-microtask subprogram keeps Promise, typed-array `waitAsync`,
  `Thread.asyncJoin`, with-fn `Lock.asyncHold`, no-fn release-function, and
  `FinalizationRegistry` cleanup roots queued through a finishing mid-script
  sweep, then drains the realm run loop and checks exact reaction/cleanup
  oracles.
  The weak-collection subprogram keeps live WeakMap values reachable only
  through live weak keys while dead WeakMap/WeakSet targets are reachable only
  through weak structures and WeakRefs, composes that with parked property
  `Atomics.wait`, `Condition.wait`, and contended `Lock.hold` peers, and
  verifies live ephemeron values, cleared dead refs, exact cleanup count/sum,
  and exact FinalizationRegistry unregister-token suppression after a finishing
  sweep.
  The creator-owned buffer subprogram leaves child-created
  `SharedArrayBuffer` and `ArrayBuffer` storage rooted through unjoined
  `Thread` completion records and delayed `asyncJoin` observers across a
  finishing sweep, then verifies blocking `join()`, post-sweep `asyncJoin()`,
  and `ArrayBuffer.transfer()` observers see exact contents after the creating
  thread has exited.
  The script and module Worker creator-owned cleanup subprograms carry
  child-created SAB/ArrayBuffer storage through Worker structured-clone while
  sibling `FinalizationRegistry` cleanup roots and transfer observers survive
  the finishing sweep.
  The script Worker/SAB and module Worker/SAB cleanup subprograms run isolated
  Workers on the same retained `SharedArrayBuffer` while shared-realm `Thread`s
  register cleanup targets and park stack roots through a finishing sweep, then
  verify exact Worker progress, joined thread roots, asyncJoin reactions, and
  cleanup count/sum; sibling script/module Worker handler-exception cleanup
  subprograms first recover from an expected thrown `onmessage` delivery, then
  prove the same Worker progress and cleanup oracle through the finishing sweep.
  Script/module Worker close/terminate subprograms now preserve exact FIFO
  drain/drop, post-close drop, post-terminate receive silence, joined roots,
  asyncJoin reactions, and cleanup count/sum through the same finishing sweep.
  Script/module Worker terminate/finalization subprograms keep spinning Workers
  alive on one retained `SharedArrayBuffer` while shared-realm `Thread`s publish
  cleanup roots, asyncJoin observers, joined roots, and exact cleanup count/sum
  through the same finishing sweep before Worker termination.
  The script and module Worker/thread teardown cleanup subprograms keep
  shared-realm Threads, pending `asyncJoin` rejection reactions, and cleanup
  jobs live through a finishing sweep while isolated Workers spin, then force
  top-level failure teardown and verify exact rejection and cleanup oracles.
  The script and module Worker/Condition.asyncWait teardown cleanup subprograms
  keep a condition async reacquire ticket, parked `Thread`, isolated Worker
  progress, and cleanup jobs live through a finishing sweep before notification,
  top-level failure, rejected `asyncJoin` observation, and exact cleanup.
  The script and module Worker/waitAsync teardown cleanup subprograms keep
  child-owned typed-array `waitAsync` tickets pending through a finishing sweep
  while isolated Workers spin, then force top-level failure teardown and verify
  rejected `asyncJoin` observers plus zero leaked child waiter tickets.
  The script and module Worker/ThreadLocal/asyncHold teardown cleanup
  subprograms compose isolated Worker termination with `ThreadLocal` hidden
  roots, no-fn `Lock.asyncHold()` release-function delivery, parked
  property/condition waiters, post-sweep rejection release, top-level failure,
  rejected `asyncJoin` observers, and exact cleanup through a finishing sweep.
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
- The lifecycle fuzzer profile adds deterministic resizable `ArrayBuffer` /
  `DataView` constructor races under no-GIL resize pressure, termination storms
  where main JS throws with parked/unjoined `Thread`s, exact-counter oracles for script
  `Worker`s plus simple-import, diamond-shaped, and fanout/rejoin module
  `Worker`s overlapping shared-realm `Thread`s on one retained
  `SharedArrayBuffer`, script/module Worker/thread/finalization scheduling on
  one retained SAB, script and module Worker termination interleaved with exact
  shared-realm finalization cleanup on a retained SAB, Worker termination while
  top-level failure tears down parked shared-realm `Thread`s, pending `asyncJoin` rejection reactions,
  and already-ready cleanup jobs on the same retained SAB, module Worker
  termination with the same shared-realm teardown/reaction/cleanup oracle, exact
  FIFO drain/drop ordering for mixed script and module Worker `close` /
  `terminate` / `postMessage` lifecycles,
  plus worker
  handler-exception recovery, Worker handler-exception recovery composed with
  shared-realm Thread finalization cleanup on one retained SAB, module Worker
  handler-exception recovery composed with the same retained-SAB cleanup oracle,
  `Thread.restrict` lifecycle isolation plus `Thread.restrict`-owned
  `FinalizationRegistry` cleanup after owner-thread exit,
  `ThreadLocal` roots kept live while no-fn `Lock.asyncHold()` release
  functions deliver with property and condition waiters parked, followed by
  exact cleanup,
  Thread exception identity through `join()` / `asyncJoin()` while
  property and condition waiters are parked,
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
  Worker termination composed with `ThreadLocal` hidden roots, no-fn
  `Lock.asyncHold()` release-function delivery, parked property/condition
  waiters, top-level teardown, rejected `asyncJoin` observers, and exact
  `FinalizationRegistry` cleanup,
  cleanup delivery interleaved with `join()` /
  `asyncJoin()` and unregister-token suppression, cleanup delivery after parked
  property/condition waiters resume, deterministic `Lock.asyncHold()` barging
  where a sync hold legally overtakes a queued no-fn async ticket before
  `await` delivers its release function, no-fn `Lock.asyncHold()`
  release-function delivery while property and condition waiters stay parked
  before exact cleanup after they resume, Promise reaction queue churn from
  with-fn `Lock.asyncHold`, no-fn release functions, typed-array `waitAsync`,
  `Thread.asyncJoin`, and exact `FinalizationRegistry` cleanup,
  `Lock.asyncHold(fn)` throw/release ordering with queued no-fn release grants
  and exact `FinalizationRegistry` cleanup,
  property `Atomics.waitAsync` late-settlement races where a peer removes
  timeout tickets from the global table while the owning Thread closes its
  stack-local microtask queue, with both `join()` and `asyncJoin()` observers,
  creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage that survives the
  creating Thread's exit, sibling-thread reads, GC pressure, and post-creator
  `ArrayBuffer.transfer()`, child-created SAB/ArrayBuffer storage crossing
  isolated Worker structured-clone after creator Thread exit plus a sibling
  script Worker clone/finalization cleanup/transfer observer variant plus a
  module Worker clone/finalization cleanup/transfer observer variant, and
  `ThreadLocal` isolation across
  normal, throwing, nested, and async-joined thread lifecycles, plus
  `ThreadLocal` values registered with `FinalizationRegistry` across
  park/resume/clear/join cleanup lifecycles with exact cleanup count/sum
  delivery after quiescent collection, plus `ThreadLocal`-only cleanup targets
  released when top-level failure forcibly terminates their owner threads, plus parent-created child `Thread`s
  whose `asyncJoin()` promises outlive the parent Thread's local microtask
  queue before child release, nested `ThreadLocal` root checks, rerouted async
  settlement, and exact finalization cleanup after both thread layers exit,
  plus post-completion `Thread.asyncJoin()` fulfillment and rejection
  observers settling after blocking joins while property waiters stay parked
  before exact cleanup,
  plus child-created SAB/ArrayBuffer storage crossing isolated Worker
  structured-clone after the creator Thread exits.
- CI runs the fuzzer in several modes: default seeded, TSan, high-contention
  amplified, broad semantic,
  mid-script GC wait-pump/microtask/property-waitAsync-late-settlement/late-asyncJoin-fulfillment-rejection-cleanup/creator-buffer/nested-asyncJoin/sync-wait-cleanup/sync-wait-burst/asyncHold-release-cleanup/promise/teardown/Worker-SAB/script-module-Worker-thread-finalization/Worker-exception/Worker-close/script-module-Worker-Condition-asyncWait-teardown/script-module-Worker-TLS-asyncHold-teardown/weak-collection,
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
- TSan mid-script-GC `threadfuzz` smoke,
- TSan lifecycle `threadfuzz` smoke,
- amplified `threadfuzz`,
- broad semantic `threadfuzz`,
- mid-script GC wait-pump/microtask/property-waitAsync-late-settlement/late-asyncJoin-fulfillment-rejection-cleanup/creator-buffer/nested-asyncJoin/sync-wait-cleanup/sync-wait-burst/asyncHold-release-cleanup/promise/teardown/Worker-SAB/script-module-Worker-thread-finalization/Worker-exception/Worker-close/script-module-Worker-Condition-asyncWait-teardown/script-module-Worker-TLS-asyncHold-teardown/weak-collection
  `threadfuzz`,
- lifecycle `threadfuzz`,
- ReleaseSafe `threadfuzz`,
- deterministic-result `threadfuzz-verify`,
- sharded no-GIL PR-249 corpus TSan sweep,
- TSan suppression-narrowness witness
  (`tools/tsan-suppression-witness.sh`),
- test262-parallel representative slice.

The no-GIL corpus TSan gate and specialized mid-GC/lifecycle TSan fuzzer smokes
hard-block on engine-state races. The suppression
witness proves the program-byte suppressions are both load-bearing and narrow.
Nightly/manual CI additionally runs higher-iteration TSan fuzzer sweeps for the
default, mid-script-GC, and lifecycle profiles so sanitizer depth keeps growing
without making every PR pay the full runtime.
