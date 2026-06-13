# Threads

zig-js has two deliberately different threading models:

1. **Agent/worker isolation** — each OS thread owns its own `Context`, arena,
   global object, shapes, microtasks, and exception state. Values cross by
   structured clone; `SharedArrayBuffer` crosses by retaining process-wide
   storage. This is the model used by `$262.agent` and the embedder `Worker`
   API.
2. **Shared-realm `Thread`** — an opt-in `Context.createWith(.{
   .enable_threads = true })` mode that installs `Thread`, `Lock`,
   `Condition`, `ThreadLocal`, `ConcurrentAccessError`, and property-mode
   `Atomics.*`. Threads run in the same realm and share object identity, but
   all JS and heap access is serialized by the context GIL. This gives
   concurrency and blocking semantics without pretending the arena/object/shape
   model is ready for parallel mutation.

The shared-realm model is the supported Layer-B state until the tracing-GC and
ungil prerequisites in [Phase 7](./P7-gil-removal.md) land.

## Shipping Surface

| Area | Code | Verification |
|---|---|---|
| Refcounted SAB storage | `src/shared_buffer.zig`, `src/value.zig` atomic typed-array helpers | Unit tests plus test262 SAB/Atomics shards |
| `$262.agent` + typed-array `Atomics.wait/notify/waitAsync` | `src/agent.zig`, `src/interpreter.zig` | Unit tests and real test262 agent cases |
| Structured clone | `src/structured_clone.zig` | Unit tests, workers, agents |
| Embedder workers | `src/worker.zig`, C-API hooks in `src/c_api.zig` | Worker unit tests and C-API round trip |
| Shared-realm `Thread` API | `src/gil.zig`, `src/jsthread.zig`, `src/context.zig` | `zig build threads-test` vendored PR-249 allowlist |

## Invariants

- `enable_threads = false` keeps the original single-thread affinity rule and
  installs no `Thread` globals.
- `enable_threads = true` changes the debug invariant from “creator thread
  only” to “current thread holds the context GIL.”
- Blocking points release the GIL: `Thread.join`, contended `Lock.hold`,
  `Condition.wait`, property-mode `Atomics.wait`, and typed-array
  `Atomics.wait`.
- Promise and microtask queues are per running interpreter/thread. Shared
  promises can settle on another thread; `await` and the evaluate tail yield or
  sleep at the GIL boundary until observable settlements are delivered.
- Process-global mutable state must be listed in [bindings.md](./bindings.md)
  with a `per-thread`, `locked`, or `refused` ruling.

## Test Commands

```sh
zig build test
zig build threads-test
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build threads-test -Dthreads-sweep=true
zig build test -Dtsan=true
```

The normal `threads-test` step runs the green allowlist in
`conformance/threads_test.zig`. `sweep` probes every vendored `api/`,
`atomics/`, and `sync/` file; files requiring JIT, WebAssembly, finalizer, or
unguarded shared-object machinery remain reference-only until the later phases
documented here.

## Reading Order

- [bindings.md](./bindings.md) — mutable-state audit and rules.
- [P2-agents.md](./P2-agents.md) — OS-thread agents and typed-array Atomics.
- [P5-workers.md](./P5-workers.md) — embedder worker API.
- [P6-thread-api.md](./P6-thread-api.md) — shared-realm `Thread`/sync API.
- [P7-gc-design.md](./P7-gc-design.md) and
  [P7-gil-removal.md](./P7-gil-removal.md) — what must land before true
  parallel shared-object mutation.
- [P8-structs.md](./P8-structs.md) — TC39 shared-struct alignment decision.
