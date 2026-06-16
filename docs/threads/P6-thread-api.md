# Phase 6 design: `Thread`/`Lock`/`Condition`/`ThreadLocal` under a GIL

Status: implemented (`src/gil.zig`, `src/jsthread.zig`, `src/context.zig`,
`conformance/threads_test.zig`). Scope: Phase 6 of
https://github.com/zig-utils/zig-js/issues/1 — the shared-memory Thread API
from oven-sh/WebKit#249 (vendored at `reference/webkit-249/`), implemented
under one VM lock. Concurrency, not parallelism: their phase 1 proved this
mode is independently shippable and testable; for this engine it is the
*shipping* state until a GC exists (Layer C).

## What exists to build on

- Real OS threads, the engine-global `std.Io.Threaded`, the waiter table,
  and group teardown discipline (src/agent.zig, Phase 2).
- Per-realm microtask queues + async-waiter settle loops (Phases 2-3).
- The stop-word checkpoint in both engines (interpreter.zig `eval`,
  vm.zig dispatch — Phase 5): the same checkpoint is where the GIL yield
  goes.
- The corpus: `reference/webkit-249/threads-tests/{api,atomics,arrays,sync}/`
  (~47 files) is the spec; port behind a small shim that maps `Thread` etc.
  plus their `resources/assert.js`.

## The decisions (copy PR-249's, do not re-derive)

- `new Thread(fn, ...args)`: fn runs **in the same realm** — same globalThis,
  same heap, same module graph. `t.join()` blocks (releases the GIL),
  returns fn's value or rethrows its exception object; `t.asyncJoin()`
  settles on the requester's queue; `Thread.current`; `t.id` (main 0).
  `join()` settles only after the thread's *own* microtask queue drains.
- `Lock` non-recursive (`hold(fn)` = tryLock fast path + finally-equivalent
  release; `asyncHold`); `Condition.wait(lock)` = atomic release+park+
  reacquire, spurious wakeups allowed; `notify`/`notifyAll`; `ThreadLocal`
  (`.value` per-thread, any JS value); `Thread.restrict(obj)` →
  `ConcurrentAccessError` on enforced foreign access.
- `Atomics.*` extended to ordinary own data properties (SameValueZero CAS so
  NaN loops work; wait/notify on `(object, key)` — a second waiter table
  keyed by object pointer + property key). The property waiter queues live on
  the per-context `Gil`, not in process-global state, so independent threaded
  contexts stay isolated while each op is trivially one atomic step under the
  realm lock; implement the *semantics* per their
  `atomics/property-*.js` tests.
- Promise rules: reactions run on the settling thread's queue; termination
  drops undrained microtasks but keeps published settlements; a terminated
  thread's `join` rethrows a plain `Error`.

## Engine mapping

1. **Opt-in:** `Context.enable_threads: bool` (creation option). Off = no
   `Thread` global, zero new code on any path, the P0 affinity assert stays.
   On = the affinity assert relaxes to "holds the GIL" (the assert checks
   `gil.holder == current` instead of creator id).
2. **The GIL:** one `Io.Mutex` + holder id on Context. Spawned threads run
   `fn` via a per-thread `Interpreter` over the SHARED Context state (arena
   allocation is single-threaded *because* of the lock). Every blocking
   point releases it: `join`, `Lock` contention, `Condition.wait`,
   `Atomics.wait`, the agent parks.
3. **Yield point:** the existing step checkpoint (every 1024 steps) gains
   `if (gil_contended) { unlock; lock; }` — without it one thread starves
   all others. Contention flag = atomic counter of waiters on the GIL.
4. **Per-thread state** (the bindings audit, GIL edition): `Interpreter`
   instance (already per-call-site), its OWN microtask queue + async-waiter
   list (lift from "per-Context" to "per-Thread record"; the main thread
   keeps the Context-owned ones), call depth/steps (already per-Interpreter),
   `re_legacy` (already per-Interpreter), exception slot (per-Interpreter
   already; `Context.exception` stays main-only for the C boundary).
5. **Thread records:** `src/jsthread.zig` — JS-visible Thread objects carry a
   `*ThreadRecord` (private_data): std.Thread handle, result Value slot
   (heap value? lives in the shared arena — fine, one heap), state, its
   microtask queue, join cond. Ids from a counter; main = 0.
6. **Closures cross threads safely** because there is one heap and one lock:
   the function object, its captured environments, everything is just
   arena memory accessed under the GIL.
7. **Thread.restrict:** `restricted_to: ?std.Thread.Id` on Object (one
   optional field; checked in getProperty/setMember slow paths only when
   set — measure the cost, expect ~zero).
8. **Corpus port:** `test/threads/` + a runner target (`zig build
   threads-test`) that evaluates each file in an enable_threads Context with
   the shim prelude. Start with `api/thread-basic.js`, `api/lock-basic.js`,
   `api/condition-basic.js`, `atomics/property-load-store.js` and grow.
   Their `cve/`, `jit/`, `gc-stress/` dirs stay reference-only (target
   machinery a GIL'd tree-walker structurally lacks); record skips with
   reasons.

## Order of work (each its own commit)

1. `Context.enable_threads` + GIL struct + relaxed affinity assert + yield
   checkpoint. No JS surface yet; existing suites must be byte-identical
   with the option off (the invariant gate).
2. `Thread` global (ctor/join/current/id) + per-thread microtask queues +
   result/exception propagation. Port `api/thread-basic.js`,
   `thread-ctor-errors.js`, `thread-exc.js`.
3. `Lock` + `Condition` + `ThreadLocal` (reuse Io primitives; GIL released
   while parked). Port `api/lock-*.js`, `condition-*.js`,
   `threadlocal-basic.js`, `sync/`.
4. Atomics-on-properties + property waiter table. Port `atomics/property-*`.
5. `Thread.restrict` + `arrays/` subset + stress loops; TSan pass
   (`zig build test -Dtsan=true` must stay clean).

## Risks

- The GIL inverts the P0 affinity story for enable_threads contexts — the
  relaxation must be surgical (assert on GIL ownership, not thread id) or
  debug builds will panic on legitimate cross-thread use.
- `evaluate()`'s drain tail and the delivery loops assume one queue; the
  per-thread lift (4) is the fiddly part. Main-thread behavior must not
  change with the option off — gate everything.
- Shape transition maps have a per-shape lock, and ordinary named-property
  helper paths, including named-property delete/rebuild, have
  `Object.property_lock`, but dense element storage, non-atomic `Value` slots,
  and arena allocation still stay under the GIL. Dropping the GIL remains Layer
  C work, not a Phase 6 shortcut.
