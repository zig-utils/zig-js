---
title: Concurrency
description: GIL-free shared-realm Threads, Workers, agents, and what each model shares.
---

# Concurrency

zig-js supports **two complementary models**. They are not alternatives to pick
between casually — they share different things, and that difference is the whole
design.

| Model | Shares | Crosses the boundary |
| --- | --- | --- |
| **Agent / Worker isolation** | Nothing on the JS heap. Each OS thread owns its own `Context`, global object, job queue, allocator state, and exception state. | Structured-clone bytes and retained `SharedArrayBuffer` storage. |
| **Shared-realm `Thread`** | One `Context`, global object, heap, shape tree, and object identity. | Same-realm function arguments and return values — real object references. |

The full contract, status, and testing rules live under [Threads](/threads/).
This page is the feature-level summary.

## Shared-realm threads

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
```

That installs `Thread`, `Lock`, `Condition`, `ThreadLocal`,
`ConcurrentAccessError`, property-mode `Atomics.*`, and the proposal-aligned
`Atomics.Mutex` / `Atomics.Condition`.

**Spawned threads run JavaScript truly in parallel on real OS threads**, over a
GC-managed, thread-safe heap — this is the default, not an opt-in. The
serialized global-lock mode is the opt-*out*:

```zig
const ctx = try js.Context.createWith(gpa, .{
    .enable_threads = true,
    .gil = true,     // deterministic interleavings / legacy compatibility
});
```

Embedders using the C API get the same choice through
`ZJSGlobalContextCreateThreaded(gil)`.

A context created without `enable_threads` is single-threaded, installs no thread
globals, keeps the original affinity rule, and pays nothing.

### The JavaScript surface

- `Thread` — spawn, `join`, `asyncJoin`, results, exceptions, `Thread.restrict`.
- `Lock` and `Condition` — blocking and async (`asyncWait`) forms.
- `ThreadLocal` — per-thread storage.
- Property-mode `Atomics` — atomic operations, `wait`, `waitAsync`, and `notify`
  against ordinary object properties.
- `ConcurrentAccessError` — thrown where concurrent access is refused rather
  than raced.

See the [Thread API reference](/threads/api) for exact signatures.

## Workers and agents

`Worker` gives each OS thread its own `Context` and global object, communicating
by `postMessage` over the structured-clone wire format, with cooperative
termination. It is created by the embedder
([`src/worker.zig`](https://github.com/zig-utils/zig-js/blob/main/src/worker.zig),
with C-API hooks), not by a JavaScript global in an ordinary realm.

`$262.agent` plus typed-array `Atomics.wait` / `notify` / `waitAsync` implement
the test262 agent model over the shared waiter table in
[`src/agent.zig`](https://github.com/zig-utils/zig-js/blob/main/src/agent.zig).

## The memory model in one rule

**JavaScript program races are permitted. Engine-state races are not.**

Your JavaScript can race its own data — that is the language's model, and
`Atomics` is how you avoid it. What must never race is the engine: shapes,
properties, elements, environments, promises, microtasks, inline caches, thread
records, waiter queues, and shared-buffer storage each have explicit
synchronization. [Memory model](/threads/memory-model) defines the contract and
the ThreadSanitizer suppression boundary.

## Garbage collection while threads run

Threaded contexts imply the GC-managed cell path. The collector uses thread-safe
allocation, write barriers, per-structure locks, precise VM frame roots, and
conservative native-stack rooting where needed, and it can run **abort-safe
mid-script** while other threads execute. Status and remaining pause-time work:
[Production readiness](/threads/production-readiness).

## How it is verified

Concurrency here is gated, not asserted:

- the PR-249 thread corpus, run in both serialized and no-GIL modes;
- a whole-corpus **ThreadSanitizer** sweep that requires zero engine-state races;
- a functional no-GIL gate against a published baseline, in Debug and
  ReleaseSafe;
- `threadfuzz` — seeded, deterministic random concurrent programs across six
  profiles, including an exact-value oracle that catches lost or torn updates;
- `test262-parallel`, proving parallel execution introduces no new failures.

[Thread testing](/threads/testing) lists every gate.

## Limits

`parallel_js` and `parallel_midscript_gc` are **test-only harness knobs**, not
stable embedder API. Unsupported surfaces and the remaining roadmap are in
[Limits & Roadmap](/threads/limits).
