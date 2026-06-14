# Threads

zig-js supports two different thread stories. They are intentionally separate:
one isolates JavaScript heaps across OS threads, and the other shares one realm
behind a VM lock.

## Start Here

| Model | What shares | What crosses | Primary docs |
|---|---|---|---|
| Agent / worker isolation | Nothing JS-heap-owned; each OS thread owns a `Context`, arena, global object, shapes, jobs, and exception state. | Structured-clone bytes and retained `SharedArrayBuffer` storage. | [Agents](./P2-agents.md), [Workers](./P5-workers.md) |
| Shared-realm `Thread` | One `Context`, one global object, one heap, one shape tree, and object identity. | Function arguments and return values stay in the same realm; access is serialized by the context GIL. | [Thread API](./api.md), [Phase 6](./P6-thread-api.md) |

The shared-realm model is concurrent, not parallel. `Thread` runs on real OS
threads, but only one thread executes JS or mutates the shared heap at a time.
The context GIL is what makes arena allocation, shape transitions, ordinary
objects, and promise state safe in today's engine.

## Shipping Surface

| Area | Status | Verification |
|---|---|---|
| Refcounted `SharedArrayBuffer` storage | Implemented in `src/shared_buffer.zig` and typed-array storage in `src/value.zig`. | Unit tests and test262 SAB / Atomics shards. |
| `$262.agent` and typed-array `Atomics.wait` / `notify` / `waitAsync` | Implemented in `src/agent.zig` with hooks in `src/interpreter.zig`. | Unit tests and real test262 agent cases. |
| Structured clone | Implemented in `src/structured_clone.zig`. | Unit tests, workers, and agents. |
| Embedder `Worker` API | Implemented in `src/worker.zig` with C-API hooks in `src/c_api.zig`. | Worker unit tests and C-API round trip. |
| Shared-realm `Thread` API | Implemented in `src/gil.zig`, `src/jsthread.zig`, and `src/context.zig`. | `zig build threads-test` green allowlist: 194/194. |

## Core Rules

- `Context.createWith(.{ .enable_threads = false })` keeps the original
  single-thread affinity rule and installs no `Thread` globals.
- `Context.createWith(.{ .enable_threads = true })` installs `Thread`, `Lock`,
  `Condition`, `ThreadLocal`, `ConcurrentAccessError`, property-mode
  `Atomics.*`, and proposal-aligned `Atomics.Mutex` / `Atomics.Condition`
  static methods.
- Blocking points release the GIL: `Thread.join`, contended `Lock.hold`,
  `Condition.wait`, property-mode `Atomics.wait`, and typed-array
  `Atomics.wait`.
- Promise and microtask queues are per running interpreter / thread. Shared
  promises can settle from another thread, and `await` yields at the GIL
  boundary until the settlement is observable.
- Process-global mutable state must be listed in [bindings.md](./bindings.md)
  with a `per-thread`, `locked`, or `refused` ruling.

## Reading Order

- [Thread API](./api.md) - the supported shared-realm JavaScript surface.
- [Testing](./testing.md) - exact Zig `0.17-dev` verification commands.
- [Limits & Roadmap](./limits.md) - GIL semantics, host knobs, and Layer-C
  blockers.
- [bindings.md](./bindings.md) - mutable-state audit and contribution rule.
- [P2-agents.md](./P2-agents.md), [P5-workers.md](./P5-workers.md), and
  [P6-thread-api.md](./P6-thread-api.md) - implementation design records.
- [P7-gc-design.md](./P7-gc-design.md), [P7-gil-removal.md](./P7-gil-removal.md),
  and [P8-structs.md](./P8-structs.md) - future shared-heap prerequisites and
  proposal tracking.
