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
  backing allocator for every cell. Correctness is gated, but tight-loop
  block-scope allocation and create/destroy-heavy context lifecycles are still
  slower under the GC path than under the old arena model. `zig build gc-profile`
  remains the repeatable baseline before nursery/generational or lifecycle
  pooling work lands.
- **Context lifecycle cost.** Long-lived embedders amortize the GC setup and
  teardown costs, but create-per-unit-of-work embedders need either cheaper
  context lifecycle or clearer guidance.
- **Parallel scaling optimization.** Benchmarks show real speedup, but scaling
  is sub-linear. `zig build threads-profile` now provides a repeatable baseline
  against the `.gil = true` fallback for independent compute, shared object
  properties, shared array append, typed-array Atomics, and lifecycle churn. Use
  it to drive contention reductions in global/environment bindings,
  property/element locks, collection helpers, and GC allocation.
- **Memory model maintenance.** Keep [Memory Model](./memory-model.md) aligned
  with the TSan suppression witness, new synchronization primitives, and any
  promoted PR-249 coverage that exercises JS-defined races.
- **Mid-script parallel GC maturity.** The abort-safe collector is correct, but
  sync waits that periodically pump tasks are not a simple "frozen parked peer"
  case. Keep quiescent collection as the correctness fallback and improve
  mid-script collection only when the wait/park protocol can publish roots
  without races or deadlocks.
- **Fuzzer breadth.** The broad `threadfuzz` profile now covers caught
  exceptions/finally, nested thread lifecycle, `asyncJoin`, property
  `wait`/`waitAsync`, `Condition`, `Thread.restrict`, and
  `FinalizationRegistry` cleanup under GC-backed parallel contexts. The
  lifecycle profile now adds deterministic termination storms and
  Worker/thread retained-`SharedArrayBuffer` overlap with an exact Atomics
  counter oracle. Keep extending it toward more teardown ordering,
  module-worker overlap, and mixed terminate/close/postMessage races.
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
