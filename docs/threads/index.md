# Threads

zig-js supports two complementary thread models:

| Model | What shares | What crosses | Primary docs |
|---|---|---|---|
| Agent / worker isolation | No JS heap state; each OS thread owns a `Context`, global object, jobs, allocator state, and exception state. | Structured-clone bytes and retained `SharedArrayBuffer` storage. | [Agents](./P2-agents.md), [Workers](./P5-workers.md) |
| Shared-realm `Thread` | One `Context`, global object, heap, shape tree, and object identity. | Same-realm function arguments and return values. | [Thread API](./api.md), [Phase 6](./P6-thread-api.md), [GIL removal](./P7-gil-removal.md) |

The shared-realm model is now true-parallel by default:

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
```

That installs `Thread`, `Lock`, `Condition`, `ThreadLocal`,
`ConcurrentAccessError`, property-mode `Atomics.*`, and proposal-aligned
`Atomics.Mutex` / `Atomics.Condition`. Spawned `Thread`s run JavaScript
concurrently on real OS threads over the GC-managed, thread-safe heap.

The serialized fallback is still supported when deterministic GIL interleavings
or legacy compatibility are useful:

```zig
const ctx = try js.Context.createWith(gpa, .{
    .enable_threads = true,
    .gil = true,
});
```

The C API exposes the same choice with `ZJSGlobalContextCreateThreaded(gil)`.
Non-threaded contexts remain single-threaded and keep the original affinity
rules.

## Shipping Surface

| Area | Status | Verification |
|---|---|---|
| Refcounted `SharedArrayBuffer` storage | Implemented in `src/shared_buffer.zig` and typed-array storage in `src/value.zig`. | Unit tests, test262 SAB / Atomics shards, TSan gates. |
| WebAssembly shared memory and atomic execution | Complete atomic opcode execution, SeqCst RMW/CAS/fence, wait32/wait64/notify, fixed historical Memory buffers, and targeted termination interruption. Terminal proposal-script/TSan/scaling evidence remains in issue #287. | Pinned `threads/atomic.wast` 372/372, 1,069-test root, focused overlapping-access TSan witnesses. |
| `$262.agent` and typed-array `Atomics.wait` / `notify` / `waitAsync` | Implemented in `src/agent.zig` with hooks in the interpreter and VM. | Unit tests and real test262 agent cases. |
| Structured clone and ArrayBuffer transfer/detach | Implemented in `src/structured_clone.zig`. | Unit tests, workers, and agents. |
| Embedder `Worker` API | Implemented in `src/worker.zig` with C-API hooks in `src/c_api.zig`. | Worker unit tests, exact host-hook wake coverage, and C-API round trips. |
| Shared-realm `Thread` API | Implemented in `src/jsthread.zig`, `src/gil.zig`, and `src/context.zig`; parallel by default, GIL opt-out available. | PR-249 green coverage: 235 compatible promoted files out of 259 executable files (233 default `zig build threads-test`, plus 2 `parallel_js`-only witnesses); the [complete inventory](../.data/pr249-reference-inventory.json) checksums all 339 vendored files and assigns dependencies, required hooks, and owners to all 24 reference-only executables. Negative promotion probes, the no-GIL TSan corpus sweep, and fuzzers guard the executable surface. |
| Concurrent GC / root safety | GC-managed parallel contexts use thread-safe allocation, write barriers, per-structure locks, precise VM frame roots, and conservative native-stack rooting where applicable. | Unit tests, `parallel_gc` soak, no-GIL corpus TSan, test262-parallel. |

## Core Rules

- `Context.createWith(.{ .enable_threads = false })` installs no `Thread`
  globals and keeps the original single-thread affinity rule.
- `Context.createWith(.{ .enable_threads = true })` runs shared-realm
  `Thread`s in parallel by default and implies the GC-managed, thread-safe cell
  path.
- `Context.createWith(.{ .enable_threads = true, .gil = true })` keeps the same
  JavaScript API but serializes execution behind the context GIL.
- Blocking APIs (`join`, `Lock`, `Condition`, typed-array Atomics wait, and
  property-mode Atomics wait) use their own synchronization paths in no-GIL
  mode and release the context GIL in serialized mode.
- Object shapes, named properties, elements/collections, environments, promises,
  microtasks, inline caches, thread records, waiter queues, and shared-buffer
  storage each have explicit synchronization. New mutable shared state must
  follow that pattern.
- JavaScript program races are distinct from engine-state races. See
  [Memory Model](./memory-model.md) for the public contract and the
  ThreadSanitizer suppression boundary.
- Test-only knobs such as `parallel_js` and `parallel_midscript_gc` remain
  internal harness controls. They are not stable embedder APIs.
- Process-global mutable state must be listed in [bindings.md](./bindings.md)
  with a `per-thread`, `locked`, or `refused` ruling.

## Reading Order

- [Thread API](./api.md) - supported shared-realm JavaScript surface.
- [Testing](./testing.md) - exact Zig `0.17-dev` verification commands and
  CI gates.
- [Memory Model](./memory-model.md) - JS program races, engine-state races, and
  the TSan suppression boundary.
- [Production Readiness](./production-readiness.md) - current no-GIL status and
  remaining hardening work.
- [Limits & Roadmap](./limits.md) - unsupported surfaces, test-only knobs, and
  remaining performance/coverage goals.
- [bindings.md](./bindings.md) - mutable-state audit and contribution rule.
- [GitHub issue #1](https://github.com/zig-utils/zig-js/issues/1) - concise
  umbrella tracker. Detailed acceptance criteria live in its linked GC,
  contention, mid-script-GC, fuzzing, PR-249, and memory-model child issues.
- [P2-agents.md](./P2-agents.md), [P5-workers.md](./P5-workers.md), and
  [P6-thread-api.md](./P6-thread-api.md) - implementation design records.
- [P7-gc-design.md](./P7-gc-design.md), [P7-gil-removal.md](./P7-gil-removal.md),
  and [P8-structs.md](./P8-structs.md) - GC, no-GIL, and TC39 structs planning.
