# Phase 8: TC39 proposal-structs re-evaluation

Status: evaluation note (the Phase-8 charter is "track + decide", not
implement). Trigger condition met: Phases 1–3 are green (refcounted SAB
storage, real concurrent agents, blocking + async Atomics), so per the issue
this is the point to re-evaluate https://github.com/tc39/proposal-structs
against the engine and decide whether Layer B's API stays engine-specific
(Bun-style `Thread`/`Lock`/`Condition`) or aligns with the proposal's names.

## What the proposal is (Stage 2)

Three layers, escalating in cost:

1. **Structs** — fixed-layout objects: a sealed, declared set of fields, no
   dynamic add/delete, no prototype mutation. A shape that can never transition.
2. **Shared structs** — structs whose instances live in shared memory and can
   be referenced from multiple agents. Fields hold primitives or other shared
   things; every field access is an atomic (SeqCst) step. No `this`-bound
   methods that close over unshared state.
3. **`Atomics.Mutex` / `Atomics.Condition`** — synchronization primitives built
   for the shared world: a non-recursive lock with `Atomics.Mutex.lock(m, fn)`
   and a condition variable with wait/notify, both usable across agents.

## Mapping to the engine today

| Proposal piece | zig-js analogue | Gap |
|---|---|---|
| Struct (fixed layout) | `Shape` transition chain (`src/shape.zig`); a struct = a shape frozen at declaration | No "sealed-at-birth, never-transitions" shape kind; would be a new object flag + a fast inline-slot read path |
| Shared struct (shared heap) | `SharedBufferStorage` (Phase 1) is the only cross-agent heap we have — raw bytes, not object graphs | **The blocker.** Shared *objects* need a shared object heap with cross-agent lifetimes = a tracing GC. We are arena-allocated; this is exactly the Phase-7/Layer-C prerequisite. |
| `Atomics.Mutex` | `Lock` (`src/jsthread.zig`): non-recursive, `hold(fn)` finally-release, FIFO handoff, GIL'd | Names differ; semantics already match (non-recursive, scoped hold). Aligning = an alias + moving the waiter onto a shared-struct field instead of an object-pointer key. |
| `Atomics.Condition` | `Condition` (`src/jsthread.zig`): `wait(lock)` atomic release+park+reacquire, `notify`/`notifyAll`, cross-kind FIFO queue | Same: semantics match, only the name and the backing-store key differ. |

## The decision

**Defer alignment; keep Layer B engine-specific for now.** Rationale:

- The **sync-primitive** half (`Atomics.Mutex`/`Condition`) is essentially a
  rename of the already-shipping, corpus-green `Lock`/`Condition`. There is no
  semantic work to do — only a naming commitment. Committing now risks churn if
  the proposal's API shifts before Stage 3 (it is Stage 2). Cheap to adopt
  later: add `Atomics.Mutex`/`Atomics.Condition` as thin aliases over the
  existing records, re-keying their waiter tables from object-pointer+key to a
  shared-struct field address.
- The **shared-struct** half is blocked on the same thing as Phase 7: a real
  tracing GC with safepoints. Under the current arena model there is no way to
  express an object whose lifetime spans agents. `SharedBufferStorage` carries
  bytes, not object identity. So shared structs cannot land before Layer C
  regardless of the proposal's maturity.
- The **plain-struct** (fixed-layout, single-agent) half *is* implementable on
  today's `Shape` machinery without a GC — a sealed shape that never
  transitions, with inline slot reads. It would be a perf/ergonomics feature
  independent of threading. Worth tracking as a separate non-threading task if
  fixed-layout objects become a priority; it is not on the issue-#1 critical
  path.

## Prerequisites to revisit (so earlier phases don't paint us out)

Already designed-in by Phase 7's charter (`docs/threads/` + the issue's Phase 7
list): tracing GC with safepoints, shape-transition synchronization, an
intern/string strategy, and `Value`-width atomicity if NaN-boxing lands. Shared
structs map cleanly onto `SharedBufferStorage` + a frozen `Shape` **once a GC
exists** — fixed layout means no transition races, and field-as-atomic-step is
exactly the Phase-1 aligned-load/store + `@atomicRmw` path we already use for
typed arrays over SAB.

## Action

- Track the proposal's stage; revisit when it reaches Stage 3 **or** when a
  tracing GC lands (whichever first).
- At that point: alias `Atomics.Mutex`/`Atomics.Condition` onto `Lock`/
  `Condition` (small), and scope shared structs into the Layer-C GC work.
- No code change in this phase; this note is the decision record.
