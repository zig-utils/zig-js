# Phase 7: GIL removal (Layer C) — prerequisites audit

Status: charter + prerequisites note (Phase 7 is **not scheduled** — it is
blocked on a real tracing GC, which is tier-5 engine work). Per the issue:
"Record the prerequisites now so earlier phases don't paint us into corners."
This note audits the *current* architecture (grounded in `src/` as of this
writing) so the eventual GC + ungil work has an accurate blocker map rather
than discovering each one by crashing.

Reference design for the end state: Pizlo, "Concurrent JavaScript: It Can
Work!" (https://webkit.org/blog/7846/) — but it presupposes a GC, which is the
gating prerequisite below.

## Where Layer B leaves us

Phases 1–6 ship a **GIL'd** shared heap (`src/gil.zig`): exactly one thread
runs JS at a time, so arena allocation, remaining direct element side doors,
and every existing invariant are safe even before their final per-structure
synchronization exists. Threads interleave only at the step
checkpoints (`(steps & 1023) == 0` in `src/interpreter.zig` `eval` and
`src/vm.zig` `execLoop`, both calling `Gil.yieldIfContended`) and release the
lock at every blocking point. Removing the GIL means every one of the
structures the GIL currently protects needs its own correctness story. The
shape transition **map** and ordinary named-property helper paths now have that
first story: `Shape.transition` locks the per-shape transition table, and
`Object.property_lock` serializes helper-routed shape, slot, accessor,
attribute, and key-order state.

## The gating prerequisite: a tracing GC

The arena model cannot express cross-thread object lifetimes. `Context` owns one
`arena_state: *std.heap.ArenaAllocator` (`src/context.zig:22`); everything
(values, objects, strings, AST, shapes, environments) lives there until
`Context.destroy()` frees it en masse (`arena_state.deinit()`). There is no
per-object reclamation. A shared parallel heap needs objects whose lifetime
spans agents and is reclaimed by tracing — `SharedBufferStorage`
(`src/shared_buffer.zig`) carries *bytes*, not object identity, which is why it
was sufficient for Layer A but cannot back shared *objects*. **No ungil work
should begin before a tracing GC with safepoints replaces the arena.** The step
checkpoints above are the natural safepoint sites — they already exist and are
polled in both engines.

**Progress:** the GC (M1, opt-in) now collects *mid-script* at those checkpoints,
including **while peer threads are parked** — conservative native-stack +
register scanning (`src/stack_scan.zig`) roots the tree-walker's live `Value`
locals, active VM `Exec` operand stacks are registered as precise roots, and a
parking thread publishes a conservative scan range that a GIL-holding collector
walks for every parked peer (the multi-thread safepoint protocol; a
safety net aborts collection unless every peer is parked-and-published). See
[`P7-gc-design.md`](P7-gc-design.md). The GC can now reclaim at safepoints under
the full threading model with the GIL still held; lifting the GIL itself is M3
(NaN-boxed `Value`, write barrier, concurrent mark).

**M3 progress:** the NaN-boxed 8-byte `Value` (#7) has landed (the slot is now a
single atomic word), and the collector can now **mark concurrently with a live
mutator** — a dedicated marker thread traces while one GIL-serialized mutator
runs, with the insertion barrier handing newly-stored cells to the marker and
the tracer reading per-object storage under the same `property_lock`/
`elements_lock` the mutator takes (validated TSan-clean against real `Object`
graphs; see `P7-gc-design.md` M3). This is the GC half of GIL removal. The
remaining ungil work is: funnel the still-GIL-coupled paths (WeakMap/WeakSet
entries, FinalizationRegistry records, microtask queues), drive the production
collector to mark concurrently rather than only while peers are parked, make
cell allocation thread-safe for multiple parallel mutators, then drop the GIL
and run the TSan campaign + serial-perf gate.

## Blocker map (each is GIL-protected today)

| # | Structure | Site | Tear without the GIL | Fix direction |
|---|---|---|---|---|
| 1 | Per-context arena | `context.zig:22`, alloc via `arena()` | `ArenaAllocator` + backing GPA are not thread-safe; concurrent alloc corrupts free lists | GC-managed heap, or per-thread nurseries with a shared old space. **Partially addressed for the one-mutator + concurrent-marker model:** GC scratch (`mark_stack`/`barrier_buf`) is on a separate thread-safe `aux` allocator while cell slabs stay on the (GIL-serialized, mutator-only) `backing`, so marker and mutator never race on an allocator. Multiple *parallel* mutators still need thread-safe cell allocation. |
| 2 | **Shape transition map** | `shape.zig` `transitions: StringHashMapUnmanaged(*Shape)` plus per-shape `transition_lock`, mutated only in `Shape.transition()` | **Closed for the map itself:** `Shape.transition` locks the table around lookup/allocation/publish, so two mutators adding the same property to one parent shape converge on one child instead of corrupting/diverging. Arena allocation remains covered by #1 until the shared heap/nursery story is complete. | Keep all transition writes behind `Shape.transition`; later Layer-C work may swap the lock for a lock-free table only with equivalent convergence tests. |
| 3 | Object shape pointer | `value.zig` `Object.property_lock`, `shape`, `setOwnUnlocked`, `deleteNamedDataOwn`; VM property ICs in `vm.zig` | **Closed for ordinary named properties:** `Object.setOwn` / `getOwn` / `deleteNamedDataOwn` and VM plain-property IC reads/writes hold `property_lock` while reading, publishing, or rebuilding the shape pointer. | Keep all ordinary named-property shape publication behind `property_lock`; later Layer-C work may replace this with an atomic shape slot only if it preserves publish ordering and delete/rebuild convergence. |
| 4 | Object slot storage | `value.zig` `Object.property_lock`, `slots: ArrayListUnmanaged(Value)`, `setOwnUnlocked`, `deleteNamedDataOwn`; VM property ICs in `vm.zig` | **Closed for ordinary named properties:** slot append, same-slot updates, and delete/rebuild compaction through `Object` helpers and VM plain-property ICs are serialized by `property_lock`. Dense element storage and direct array/collection element mutations remain separate blockers. | Keep slot-vector mutation behind `property_lock`; move any future direct slot side door into `Object` before removing the GIL. |
| 5 | Object element storage | `value.zig` `Object.elements_lock`, `elements: ArrayListUnmanaged(Value)`; dense-array, Map/Set helper, and cursor paths in `interpreter.zig` | **Partially closed:** `Object` now has an element-store lock. Central dense-array get/set/delete/length, packed reverse/sort/splice fast paths, non-callback Map/Set helpers, Map/Set `forEach` per-slot snapshots, native Set helper scans, and Map/Set cursors use it before reading or mutating element-backed storage. Remaining direct tuple/internal `elements` side doors are still GIL-protected. | Continue moving every direct `elements.items` read/write/append/clear behind `Object.elements_lock` or a narrower equivalent, and do not hold it across JS callbacks. |
| 6 | Accessor / attribute maps | `value.zig` `Object.property_lock`, `setAccessor`/`setAttr` `StringHashMapUnmanaged` puts, `deleteAccessorOwn` removes | **Closed for ordinary named properties:** accessor and attribute map lookup/mutation/removal through `Object` helpers is serialized by `property_lock`. | Keep accessor/attribute state behind `property_lock`; add tests for any future descriptor side door before ungil. |
| 7 | **Value width** | `value.zig` `Value = union(enum)` — ~24 bytes (slice payload + tag), **not pointer-width** | A 24-byte slot cannot be read/written atomically; readers tear against writers | NaN-box `Value` to 8 bytes so a slot is a single atomic word. **Codec landed** in `src/nanbox.zig` (8-byte `NanBox`: number / object-ptr / string-ptr / bool / null / undefined in the negative-qNaN boxed space, NaN-canonicalized; exhaustive round-trip tests incl. the `0xFFF8…` collision case and a pointer sweep). Standalone — not yet swapped into the engine; that integration also needs strings to become a single-pointer cell (#8), since a `[]const u8` slice is two words. |
| 8 | Strings | `value.zig` `string: []const u8` (uninterned arena slices); `jsstring.zig` atomic `retain`/`release` refcount | No shared intern table exists to race on (good). FFI `JSStringRef` retain/release is now atomic; arena slices still have context lifetime. A `[]const u8` is two words, so it also blocks the 8-byte NaN-box (#7). | **Mechanism landed** in `src/strcell.zig`: a single-pointer `StringCell` {bytes, cached hash} (the NaN-box string payload target) + an opt-in **sharded, thread-safe `InternTable`** (the Layer-C shared-string story — equal bytes → one canonical cell across threads; per-shard atomic spinlock; TSan-clean under 8-thread convergence). Standalone/uninterned-by-default; the engine wires `Value`'s string payload to `*StringCell` as part of the mechanical `Value` swap. |
| 9 | Promise settlement and reactions | `promise.zig` `Promise.lock`, `state`, `value`, `on_fulfill`, `on_reject`; `gc.zig` `tracePromise`; `interpreter.zig` `awaitValue` | **Closed for per-promise state:** resolve/reject/then registration, snapshot reads, async thenable job guards, and GC tracing lock the Promise before reading or moving settlement/reaction state. Microtask queues and async waiter arrays remain separate GIL-protected host state. | Keep all Promise state reads through `promise.snapshot`/`isPending` or under `Promise.lock`; do not treat microtask queue mutation as ungil-ready until the per-thread event-loop story is explicit. |

## Design inputs to lock in now (so earlier phases don't foreclose them)

- **Keep `Value` shrinkable.** Nothing should depend on the union's current
  layout or 24-byte size; NaN-boxing must remain a drop-in (#7). The C-API
  already hides `Value` behind an opaque `Boxed` pointer (`c_api.zig`), so the
  ABI is insulated.
- **Keep strings uninterned.** No code should assume pointer-identity of equal
  strings; equality is by bytes (#8). This preserves the freedom to add a
  sharded intern table only in Layer C. `JSStringRef` lifecycle is already
  thread-safe: `src/jsstring.zig` uses an atomic refcount, so C-API strings can
  be retained and released from any thread while remaining immutable.
- **Keep shape transitions funnel-shaped.** All transitions go through
  `Shape.transition` (`shape.zig`), whose per-shape lock is now the
  synchronization point for the transition table (#2). Do not add side doors
  that mutate `transitions` directly.
- **Keep object named properties funnel-shaped.** Ordinary named property
  helper paths now synchronize on `Object.property_lock` (`value.zig`), and the
  VM's plain-property inline caches take that lock before touching `shape` or
  `slots`. Named data/accessor delete and shape+slot rebuild also live behind
  the same lock. Do not add new direct mutations of `shape`, `slots`,
  `accessors`, `attrs`, or `key_order`.
- **Keep Promise state funnel-shaped.** Promise settlement and reaction-list
  mutation now synchronize on `Promise.lock` (`promise.zig`), and `awaitValue`
  observes settled promises through `promise.snapshot`. Do not add direct reads
  of `Promise.state` or `Promise.value` outside `promise.zig`/locked GC
  tracing.
- **Keep element storage funnel-shaped.** `Object.elements_lock` is the
  synchronization point for indexed storage. Dense-array helper paths, Map/Set
  helper paths, and cursor paths already use it, and callback paths must
  snapshot one slot or one key list before invoking JS. Do not add new direct
  `elements.items` access on shared data paths; finish moving internal engine
  tuples behind helpers.
- **Keep the safepoint checkpoints as the only interleave points.** Both
  engines already poll at `(steps & 1023) == 0`; a GC needs exactly these as
  safepoints. Do not add heap mutation paths that can run for an unbounded
  number of steps without hitting a checkpoint.

## Bring-up ladder (when a GC lands)

Mirror PR-249's phase-2 ladder, already proven for Layer B:
1. Per-shape + per-object locks (coarse), GIL still present, prove correctness.
2. Drop the GIL; run the vendored corpus + test262 SAB/Atomics under **real**
   parallelism with TSan; drive unsuppressed races to zero.
3. Serial-perf gate: single-thread throughput must not regress materially.
4. Stress amplifiers (transition storms, property-add races, shared-TA atomics
   storms) flake-free in CI.

## Action

This note began as the prerequisite record. The tracing GC (M1/M2),
NaN-boxed `Value` (#7), and concurrent marking (M3 GC half) have since landed,
and the **heap is now parallel-safe and proven** (see below). The remaining work
is the execution-path GIL drop, specified next.

## Execution-path GIL removal — the remaining campaign

The GC half of M3 is complete and the heap-mutation foundations for GIL removal
are done and validated:

- **Thread-safe allocation.** GC cell slabs: `zig-gc` `Heap.setParallel` (all-list
  prepend + counters + born hand-off under `alloc_lock`). Arena (shapes, strings,
  AST, binding tables): `Context.LockedArena`, installed **before** the
  create-time arena is captured, so `root_shape`/`env` and `Shape.transition`
  (which reuses the root shape's captured allocator) are thread-safe. Backing-store
  accounting counters are atomic.
- **Per-structure locks** (the object model + collections): `Object.property_lock`
  / `elements_lock`, `Shape.transition_lock`, `Environment.binding_lock`,
  `Promise.lock`; weak collections use isMarked-based clearing.
- **Proven:** the `parallel_gc` bring-up test runs 4 threads creating +
  shape-transitioning + writing 4,000 disjoint objects **with no GIL** — intact
  and TSan-clean.

What remains is dropping the GIL from the **execution path** so the `Thread` API
actually runs JS in parallel. The touchpoints (each must be synchronized or made
per-thread before threads stop holding the GIL):

1. **`evaluate` / `evaluateModule` realm state.** Good news from the audit: the
   *executing* state is already per-thread — each `Thread` runs its own
   `Interpreter` (`ctx.interpreter()` in `threadMain`) with its own
   `Interpreter.exception` (the `Context.exception` slot is only the host/join
   hand-off, written at quiescent points), so threads don't clobber each other's
   throw state. The shared touchpoints that remain: `active_interpreters`
   (push/pop + GC-trace iteration on a shared list — needs a lock), the
   evaluate-top `collectGarbage` (stop-the-world; parallel evaluates collide —
   gate behind the safepoint protocol or a collection lock), `gc_execs`
   registration, and the realm microtask/finalization drains.
   *Parallel mid-script collection.* The **quiescent** model is validated and
   shipping: parallel threads build a rooted shared graph (contended
   `elements_lock`/`property_lock` + insertion barrier), join, then a
   `collectGarbage` reclaims the garbage while keeping the live graph intact —
   TSan-clean (`parallel_gc … quiescent collection after a parallel build` in
   `context.zig`). The `h.parallel` guard skips the *mid-script* safepoint
   collector in this mode, so parallel execution never races a marker.

   *Mid-script parallel collection — the STW barrier was a dead end; the fix is a
   ragged handshake.* A stop-the-world safepoint barrier (peers park at their GC
   safepoints, collector waits for `par_active == 1`) was prototyped and
   *deadlocked*: a mutator spinning to **acquire** a per-structure lock (e.g.
   `Object.property_lock`) can't reach its safepoint, while the thread holding
   that lock had already blocked at the barrier — so the lock is never released
   and the barrier never completes (a `sample` showed exactly this:
   `property_lock` held-but-unowned while the collector spun). The defect is
   fundamental to **any** protocol that blocks a mutator where it may transitively
   hold a lock. The replacement is now built: a **ragged (non-blocking)
   root-publication handshake** (`src/root_handshake.zig`) — the collector
   *requests* roots, and each mutator publishes its own roots at its safepoint
   (between bytecodes, where it provably holds no per-structure lock) and **keeps
   running**, so no mutator ever blocks and can always progress to release a lock.
   Only the collector waits, on a monotonic ack counter. The primitive is
   standalone + tested (a test reproduces the exact lock-contention hazard the STW
   barrier deadlocked on), TSan-clean. Wiring it into a concurrent parallel marker
   (collector marks while mutators run behind the insertion barrier; a second
   handshake re-scans roots at finish; sweep with born-black allocation) is the
   next step — the parked-thread rooting machinery (`active_interpreters` +
   `gc_execs` + park records) is already in place.
2. **Thread-API shared state in `Gil`** (`tasks`, `prop_waiters`, `prop_async`,
   `next_thread_id`, `park_records`) — the old "mutated/read only under the
   GIL" model is being split into dedicated locks. **Spawn done:** the spawn critical section (live-cap check + id
   allocation + `js_threads.append` + OS spawn) is now one atomic unit under
   `Gil.api_lock` (`lockApi`/`unlockApi`), independent of the GIL — two concurrent
   `Thread` constructions can't both pass the cap or claim the same id.
   **Property waiters done:** `Gil.prop_mutex` now guards `prop_waiters` /
   `prop_async`; sync wait parks on that mutex, and notify/timeout collect async
   tickets under the mutex but settle promises after releasing it. **Run-loop
   tasks done:** `Gil.tasks` enqueue/dequeue uses `Gil.api_lock`, and grant
   delivery runs outside that lock. **Condition done:** `CondRecord.mutex`
   guards the FIFO sync/async waiter queue, and sync waits park on
   `CondRecord.cond` without using the context GIL as the queue mutex.
3. **Lock-free READ paths vs concurrent writes — the central hot-path decision.**
   Bring-up tests (`parallel_gc`) prove **writer-vs-writer** is safe: 4 threads
   concurrently appending to a shared array (`elements_lock`) and adding distinct
   properties to a shared object (`property_lock` + `Shape.transition`) lose
   nothing and are TSan-clean — the per-structure *write* locks serialize
   mutators correctly. **Reader-vs-writer is now also handled (RESOLVED).**
   `Object.getOwn` already read under `property_lock`; `Environment.get`/
   `isConst`/`isFnName`/`isAlias` now read each scope's binding tables under
   `binding_lock` (the writers `put`/`assign`/`putAlias`/`putConst`/`putFnName`
   lock the matching tables), so a reader can't tear against or read a freed table
   from a concurrent rehash. The hot-path perf concern is handled by **gating all
   binding locks on `Environment.binding_locks_enabled`** — set only for a
   `concurrent_gc`/`parallel_gc` context, so the default GIL-serialized engine
   leaves `lockBindings`/`unlockBindings` a single relaxed load (no CAS) and is
   byte-identical/full-speed (verified: test262 unchanged at 90.7%, same run
   time). Validated by a concurrent reader+writer test on a shared global env,
   TSan-clean. (A seqlock/RCU read path remains a possible future optimization if
   the lock proves a parallel-throughput bottleneck, but it is no longer a
   correctness blocker.)
4. **Other shared globals** — **symbol registry done:** the cross-realm
   GlobalSymbolRegistry get-or-create (`Symbol.for` + lazy registry creation) is
   now atomic under `Gil.symbol_registry_lock` (the key `ToString` is computed
   *before* the lock, so a user `toString` can't reenter it); a test drives the
   racing critical section, TSan-clean. **VM inline caches done:** the
   plain-property inline caches (`chunk.ics`) — shared mutable `(shape, slot)`
   written from the hot `get_prop`/`set_prop` path, where two threads racing the
   same instruction over different objects could tear the pair into a *stable*
   inconsistency — are now a **seqlock** (`InlineCache.lookupSlot`/`record`: a
   version-bracketed read + a try-claim write, best-effort so a writer that can't
   claim just skips caching). Gated by `bytecode.ic_seqlock_enabled` (set with
   `binding_locks_enabled` for the parallel/concurrent contexts); the default
   GIL-serialized path keeps plain field access (one extra relaxed flag load),
   behavior-identical. Validated by an isolation test (two writers, distinct
   shapes, one cache) **and** an integrated test (4 threads run one shared chunk
   over one shared object, no GIL — never-written reads never tear), both
   TSan-clean. *Remaining:* realm-level caches (Date/regex) and the string story
   (arena slices today; a shared intern table would need the sharded
   `strcell.InternTable`) — to be surfaced empirically by the GIL-free bring-up.
5. **Corpus semantics.** The threads corpus partly *pins GIL-serialized
   behavior* (deterministic interleavings, run-loop grant ordering). Dropping the
   GIL changes the model, so the campaign must re-derive which corpus expectations
   are synchronization-correctness (must still hold under true parallelism — Lock/
   Condition/Atomics) vs. GIL-specific ordering (may legitimately change), and
   drive real races to zero under TSan with the whole corpus running in parallel.
6. **Gates:** whole-corpus TSan campaign to zero unsuppressed races; serial-perf
   gate (single-thread throughput must not regress); stress amplifiers.

Validated so far (`parallel_gc` / `parallel_js` bring-up tests): parallel heap
mutation; parallel parse+compile+VM execution of disjoint scripts; contended
parallel append to a shared array; contended parallel property-add + shape
growth on a shared object; quiescent collection after a parallel build (live
graph kept, garbage reclaimed); atomic GlobalSymbolRegistry get-or-create under
contention; **seqlock inline caches** (isolation: two writers, distinct shapes,
one cache); and **one shared compiled chunk run over one shared object on 4
threads with no GIL** (shared ICs + `property_lock` + `binding_lock`, never-written
reads never tear). The first production-`Thread` vertical slice is also in place:
test-only `Context.TestingOptions.parallel_js` drops the execution-path GIL while
real shared-realm `Thread` workers contend the shipped `Atomics.Mutex` /
`LockRecord` sync path and the `Lock.asyncHold` grant-delivery path; the focused
`parallel_js` tests are TSan-clean. Plus the standalone ragged root-publication
handshake primitive.
These cover allocation, the object/shape model, the writer-vs-writer and
reader-vs-writer locks, the inline caches, quiescent GC, the named shared-global
prerequisites (symbol registry + spawn bookkeeping), one real production sync
primitive under the `Thread` entrypoint, and async lock-grant delivery. What
remains: wire the root handshake into a concurrent parallel marker (mid-script
collection #1); move the property waiter tables and condition-variable waiter
state onto their own locks (#2); broaden `parallel_js` beyond the mutex/async
lock-grant slice; then run the full corpus campaign (#5).

This is the final, largest step — major surgery on the core execution path plus a
semantics campaign, to be done as a focused effort (not a mechanical flip), now
that every heap prerequisite is in place.

## Coordination-primitive rewrite — the critical path (design)

The heap and bytecode-execution prerequisites are validated under real parallel
GIL-free bytecode (objects/shapes/elements/env/arena/GC-alloc/promise/
inline-caches/symbol-registry/lazy-prototypes; strings are uninterned so there is
no shared intern-table race). The remaining blocker for true parallel JS *via the
`Thread` API* is finishing the **coordination primitives**. The first slice has
landed: `LockRecord` (`Atomics.Mutex` / `Lock`) now has a per-record
`std.Io.Mutex`, and sync `acquireLock`/`releaseLock`/unlock-token paths guard
`locked`, `holder`, `sync_waiting`, and `sync_generation` with that mutex. A
test-only `parallel_js` context drops the execution-path GIL and proves real
`Thread` workers can contend one production `Atomics.Mutex` without races.
The next slice also landed: async `Lock.asyncHold` grant state (`pending`,
`grant_pending`, `active_release`, `async_runner`) uses that same per-record
mutex, and the realm task queue is checked/enqueued/dequeued under `Gil.api_lock`
so task delivery is TSan-clean with no context GIL.

`src/jsthread.zig` coordination state migrated in the focused `parallel_js`
campaign:

- `LockRecord` sync and async-grant state uses `LockRecord.mutex`.
- `Condition` sync/async waiter FIFO state uses `CondRecord.mutex`; waiters
  register under the condition mutex before releasing the associated `Lock`, so
  `notify` cannot miss the release+park transition.
- property-mode `Atomics.wait` / `notify` use `Gil.prop_waiters` /
  `Gil.prop_async` guarded by `Gil.prop_mutex`; wait and waitAsync revalidate
  the property value under that mutex immediately before enqueueing, so a
  racing store+notify cannot strand a waiter after the value already differs.
- named property-mode Atomics load/store/exchange/compare-exchange/RMW hold
  `Object.property_lock` for the whole property step, so no-GIL RMW counters no
  longer lose updates.
- typed-array `Atomics.wait` only releases/reacquires the context GIL in the
  shipped GIL mode; `parallel_js` parks directly on the agent waiter table.

The remaining work is no longer a single coordination queue; it is broadening the
GIL-free execution campaign across the full PR-249 corpus and continuing to
close object/heap/shape/promise mutation paths called out in the blocker map.

**Target design (per-waitable mutex+condvar).** Give each waitable its own real
`std.Io.Mutex`:

- `LockRecord`: add `mutex: std.Io.Mutex`. `acquireLock` locks `rec.mutex`, tests
  `locked`/generation, and `rec.cond.wait(&rec.mutex)` on contention;
  `releaseLock` locks `rec.mutex`, hands off / signals `rec.cond`. The state fields
  move from "GIL-protected" to "`rec.mutex`-protected". The async hold-job
  machinery (`HoldJob`, `pending`, grant delivery, `enqueueHoldJob`/`pumpTasks`)
  re-expresses "deliver a grant" as a `rec.mutex`-guarded transition plus the
  existing `api_lock`-guarded run-loop queue.
- `Condition`: the condition record has its own queue mutex. A waiter registers
  in the FIFO while holding `CondRecord.mutex`, releases the associated `Lock`
  under that mutex, then parks on `CondRecord.cond`; `notify` pops, marks, and
  broadcasts under the same mutex, and async waiters are handed to the already
  migrated `Lock.asyncHold` grant path.
- Property `Atomics.wait`/`notify`: the per-realm `Gil.prop_mutex` now guards
  `prop_waiters`/`prop_async`; `propNotify` collects matching async tickets under
  the table mutex and settles them *after* releasing it (settling runs JS →
  per-structure locks, lock order: table-mutex must not be held across JS).
- Termination/abandon (`teardown_stop`, worker `terminate`, D9 trap-on-parked):
  each park loop keeps polling `stop_flag` between waits, as today.

**The GIL becomes the "bytecode runs without it" lock.** It stays as the home of
the threading bookkeeping (`api_lock`, `symbol_registry_lock`, `lazy_init_lock`,
`park_records`) and is acquired only by the specific shared-bookkeeping operations
— never held across bytecode. `threadMain`/`evaluate` stop wrapping execution in
`g.acquire()`/`g.release()`; the per-structure locks (already validated) carry
correctness during execution.

**Corpus-semantics caveat.** The threads corpus partly *pins* GIL-serialized
interleavings and run-loop grant ordering (`docs/threads/api.md`, the `cve/mc-*`
and `lock/`/`condition/` cases). Dropping the GIL changes the model, so this is a
re-derivation: classify each expectation as synchronization-correctness (must hold
under true parallelism) vs. GIL-specific ordering (may legitimately change), adjust
the corpus/notes, and drive races to zero under a whole-corpus TSan run. This is
why it is a campaign, not a flip.

**Sequencing.** (1) Per-record `mutex` on `LockRecord` + sync
`acquireLock`/`releaseLock`/unlock-token paths off the GIL, behind gated
`parallel_js`: **landed and TSan-clean for the focused real-`Thread`
Atomics.Mutex test**. (2) Hold-jobs / `Lock.asyncHold` off the GIL: **landed and
TSan-clean for the focused real-`Thread` async-grant test**. (3) Property
`Atomics.wait`/`notify` waiter-table mutex: **landed and TSan-clean for the
focused real-`Thread` property-waiter test**. (4) `Condition` waiter queue
mutex: **landed and TSan-clean for the focused real-`Thread` condition-waiter
test**. (5) Broaden the execution-path GIL drop in `threadMain`/`evaluate` under
`parallel_js`; the corpus runner now has `-Dthreads-parallel-js=true` so PR-249
files can be probed under the same GIL-free mode instead of only via unit
witnesses. The first full-allowlist probe is intentionally not a gate yet:
`smoke.js`, `api/condition-async-wait.js`, and the lifecycle join/exception
cluster now pass under `parallel_js`; so do the promoted ordinary-array
mutation probes `arrays/push-resize-multithread.js` and
`arrays/shared-element-read-write.js`. The broad promoted-allowlist
`parallel_js` probe now carries one explicit budget skip:
`cve/mc-df-segmented-length.js`, which is green in the normal GIL mode but is
still too slow under no-GIL dense-array shrink/regrow contention. Targeted
`-Dthreads-case=cve/mc-df-segmented-length.js` remains the repro for that
frontier. The CVE tail now gets past resizable ArrayBuffer resize churn and SAB
retain-list churn under `parallel_js`; `cve/mc-lock-cow-materialize-race.js`
and `cve/mc-val-llint-cache-storm.js` are also focused-green after test-harness
repairs that preserve their real oracles while removing no-GIL shutdown/budget
artifacts. `gc-stress/havebadtime-vs-indexed-fastpath.js` is also focused-green
under `parallel_js` after two changes: prototype-chain indexed-store guards now
consult a conservative per-object "indexed own ever seen" marker instead of a
per-key own-property lookup on every hot indexed store, and the no-GIL run uses a
smaller stress budget while keeping the same bad-time flip and trap-index
oracles as the full GIL-mode file. The promoted JIT-audit subset is now
focused-green under `parallel_js` through constructor/fire benchmarks, tailcall
argument preservation, OSR/catch-loop locals, golden-disasm workload execution,
int-gate smoke files, shared-ArrayStorage stress, spawned-thread butterfly
stress, tag-discipline, and TID-tag witnesses. The normal GIL-mode JIT files
keep their original stress sizes; `parallel_js` trims the tailcall,
OSR/catch-loop, golden-disasm, stop-budget, spawned-thread butterfly, and
tag-discipline loop counts so those files remain correctness witnesses rather
than serial-performance gates. `races/counter-atomics.js` is also
focused-green under `parallel_js`; the GIL-mode file keeps its original
100,000-add/1,000-CAS amplifier, while no-GIL keeps the same 8-worker
lost-update/CAS oracle at a smaller interpreter budget. `races/counter-lock.js`
uses the same split for contended `Lock.hold`, and the promoted race block now
passes under `parallel_js` through `races/wait-notify-storm.js`. The promoted
heap block is also focused-green under `parallel_js`, from
`heap-access-blocking.js` through `heap-stop-interleavings.js`. The promoted
invariants block is focused-green 7/7, and the promoted objectmodel block is
focused-green in verified slices through
`objectmodel/i08-named-vs-indexed-first-install.js`. The full promoted
semantics block is focused-green 15/15 under `parallel_js`; the IC transition
files keep their original GIL-mode pass counts while no-GIL uses smaller
watchdog-safe pass budgets. The full promoted scaling block is also
focused-green 6/6 under `parallel_js`; `scaling/raytrace-like.js` and
`scaling/richards-like.js` keep their normal corpus/gate workloads while using
smaller no-GIL standalone budgets. The VM-state block is focused-green 10/10
under `parallel_js`. The promoted CVE tail after
`cve/mc-int-resizable-tail-quarantine.js` is focused-green in slices through
`cve/mc-wait-property-wait-lost-wakeup.js`, including the async-generator
resume-head claim case `cve/mc-prim-async-generator-resume-claim.js`; that
case is also TSan-clean as a focused `threads-test` probe. The GC-stress block
is focused-green 4/4, the promoted Atomics block is focused-green 15/15, and
the promoted JIT-audit subset is focused-green in verified slices through
`jit/tid-tag-3-threads.js`. Broader promoted-allowlist `parallel_js` remains
exploratory until the monolithic cumulative budget probe is cleared; with a
30-minute cap the single run now clears the CVE tail and GC-stress and times
out later in the promoted JIT-audit block around `jit/golden-disasm-corpus.js`
/ the int-gate smoke files. (6)
Whole-corpus TSan campaign +
serial-perf gate. Mid-script concurrent-parallel GC (the ragged
`root_handshake` → concurrent marker) is independent of this and is a GC
pause-time optimization, not on this critical path (quiescent collection is
already correct under parallel mutation).
