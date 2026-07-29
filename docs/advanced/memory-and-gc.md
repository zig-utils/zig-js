---
title: Memory & GC
description: Arena and precise-GC allocation modes, heap budgets, generational collection, compaction and relocation, weak references, and root safety.
---

# Memory & GC

zig-js has **two allocation modes**, chosen per `Context`. Which one you pick
changes lifetimes, reclamation, and what your host code must do to keep values
alive.

## Mode 1 — arena (default)

A default `Context` owns an arena allocator. Values and objects are
bump-allocated and freed **wholesale** when the context is destroyed. Nothing is
reclaimed during the context's life.

This is the right mode for short-lived contexts: it is the fastest allocation
path, and teardown is a single release. It is the wrong mode for a long-running
realm that churns objects, because nothing comes back until `destroy()`.

## Mode 2 — precise tracing GC

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_gc = true });
```

Heap cells route through the precise collector (the sibling `zig-gc` package,
bound in [`src/gc.zig`](https://github.com/zig-utils/zig-js/blob/main/src/gc.zig)).
Design record: [P7 GC design](/threads/P7-gc-design).

The collector is **precise, not conservative** — it knows the engine's exact
types and traces only real references. That is not a purity preference: a JS
heap is full of `f64`s that alias pointers, and precise reachability is
*required* to clear weak references and fire finalizers correctly.

`collectGarbage()` runs a quiescent collection: it reclaims unreachable cells,
clears `WeakRef` targets, prunes WeakMap/WeakSet weak keys, queues
`FinalizationRegistry` records, and drains their cleanup callbacks as host
cleanup jobs at checkpoints.

A no-GIL threaded context implies this path, and there the collector also runs
**abort-safe mid-script** while other threads execute.

## Roots — what keeps a value alive

Per live `Context`, the tracer enumerates the global object, the environment
chain, the root shape and TDZ marker, the microtask queue, the exception slot,
async waiters, completed thread records, property-mode `waitAsync` tickets,
active module caches (each cached module roots its environment and namespace
object), and registered active interpreter roots at checkpoints — current
environment and bindings, `this`, return/exception/`new.target`, active native
function, `with` objects, symbols, and `import.meta`.

`SharedArrayBuffer` retains are deliberately **not** roots: SAB storage is
refcounted process-wide, and the GC only finalizes the wrapper's retain.

### Host handles

The collector cannot see your Zig or C variables. A value held only by host code
must be registered:

```zig
const handle = try ctx.protectValue(v);
defer _ = ctx.unprotectValue(handle);
```

C embedders use `JSValueProtect` / `JSValueUnprotect`, which register the boxed
cell in a per-context counted handle table that the tracer walks.

## Write barriers and funnelled mutation

Concurrent and parallel collection use a Dijkstra-style insertion barrier at the
reference-storing sites. This is affordable precisely because the engine funnels
mutation: `Object.setOwn` / `setSlot`, element appends, environment binding
writes, and shape transitions. **Keep new reference stores inside that funnel** —
a fresh ad-hoc store site is a missing barrier.

The AST is immutable and arena-owned, outside the GC heap. Functions reference it
by pointer without the collector tracing it.

## Generational collection

A nursery with an age-based promotion policy is implemented and benchmarked. The
current published evidence
([report](https://github.com/zig-utils/zig-js/blob/main/docs/.data/gc-generation-2026-07-29.md))
pairs moving and non-moving age-one and age-three parents. Across the accepted
single-mutator rows, moving age three is 0.63–1.01× its exact non-moving parent
and 0.84–1.02× moving age one. The recorded moving age-three rows copied
480.42 MiB with zero movement failures. The shared three-mutator rows recorded
a 110.56 ms maximum moving pause and 12 bounded retries across 14 samples; every
sample completed within the enforced two-retry ceiling.

Reproduce with:

```bash
zig build gc-generation-benchmark
zig build gc-generation-benchmark -Dgc-generation-benchmark-quick=true
```

The **moving nursery** relocates multi-age survivors at exact quiescent, VM,
optimizer, and shared no-GIL safepoints. Opaque peers retain the moving request
and fall back conservatively after a bounded allocation window; shared exact
rendezvous retries are bounded rather than making unrewritable native frames
movable.

## Compaction and relocation

Moving collection exists, but under an explicit contract
([GC relocation contract](/threads/gc-relocation)):

- `Context.compactGarbage` moves on a **quiescent** precise-GC realm;
- the automatic quiescent full-GC policy moves when slab pressure leaves at
  least 512 KiB of reclaimable fragmented backing;
- `Context.requestGarbageCompaction` is consumed at the AArch64 numeric tier's
  declared precise checkpoint;
- published code, tier metadata, bytecode chunks, and native-frame storage
  **do not move**;
- running JS threads, generic/native-host checkpoints, conservative stack scans,
  and in-flight concurrent/parallel collections **fail closed**.

C and Objective-C embedders get the same boundaries through
`ZJSGlobalContextCreateGarbageCollected`, `ZJSContextRequestGarbageCompaction`,
and `ZJSContextCompactGarbage`.

The checked-in relocation inventory covers all nine production cell kinds and 27
pointer surfaces, each naming its representation, source anchor, and required
relocation or pinning rule. The drift gate is cheap and runs in ordinary CI:

```bash
zig build gc-relocation-inventory-check
```

**If you add a cell kind or a pointer surface, you add an inventory entry and a
rewriter in the same change** — the verifier derives the live `CellKind` enum
from `src/gc.zig` and requires exact ordered coverage.

Published compaction evidence: 90.8% less retained fragmented backing
(8.81 → 0.81 MiB) with a 0.99 ms median pause and unchanged post-action
throughput ([report](https://github.com/zig-utils/zig-js/blob/main/docs/.data/gc-compaction-2026-07-19.md)).
Automatic shared/mid-script compaction evidence remains an open release gate.

## Heap budgets

```zig
const ctx = try js.Context.createWith(gpa, .{ .heap_limit_bytes = 64 << 20 });
```

The cap covers Context-owned allocations: arena chunks, GC cell slabs and side
storage, thread records, and other allocations routed through the context
allocator. **Arena-backed caps fail closed. GC-backed caps can collect and retry**
at safe allocation-recovery points.

Inspect at runtime:

```zig
_ = ctx.heapBudgetStats();        // limit / used / peak
_ = ctx.runtimeHeapAccounting();
_ = ctx.parallelGcStats();        // no-GIL collector telemetry
```

## Weak references and finalization

`WeakRef` and `FinalizationRegistry` are only meaningful under `enable_gc` —
they need precise reachability. Cleanup callbacks are queued as host cleanup jobs
and drained at checkpoints, never inline during a collection. The harness global
`$drainFinalizationCleanup` steps that queue deterministically in tests.

## Native stack safety

Where native frames may hold references, the engine uses conservative stack
scanning ([`src/stack_scan.zig`](https://github.com/zig-utils/zig-js/blob/main/src/stack_scan.zig))
plus a root handshake ([`src/root_handshake.zig`](https://github.com/zig-utils/zig-js/blob/main/src/root_handshake.zig))
to publish roots across threads.

For the native tiers there is a hard rule until precise native stack maps exist:
**no GC pointer may be live only in a machine register across a safepoint.** See
[Execution tiers](/advanced/execution-tiers).

## Profiling memory work

```bash
zig build gc-profile                       # allocation and Context lifecycle cost
zig build gc-profile -Dgc-profile-case='nursery'
zig build midgc-profile                    # mid-script parallel-GC convergence and pauses
zig build gc-compaction-benchmark
zig build gc-generation-benchmark
```

Profiles locate cost; they are not correctness gates and not publication
evidence. Publishing a memory or pause claim follows the same rules as any
performance claim — see [Benchmarks](/benchmarks).
