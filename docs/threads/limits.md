# Limits & Roadmap

The current supported shared-realm thread model is Layer B: real OS threads
with one shared JavaScript realm and one context GIL. It is useful for testing
thread APIs, blocking semantics, waiter behavior, and shared object identity,
but it is not true parallel JavaScript heap mutation.

## Supported Today

- Agent and worker isolation: one `Context` per OS thread, values crossing by
  structured clone or retained `SharedArrayBuffer` storage.
- Shared-realm `Thread`: one `Context`, one heap, one global object, real OS
  threads, and serialized JS execution under the GIL.
- Blocking points release the GIL so other JS threads can run while one thread
  is parked.
- Successful shell evaluations keep the realm alive until spawned
  shared-realm `Thread`s finish. Abrupt top-level failures request thread
  termination before teardown so parked child threads cannot strand the
  context.
- Typed-array `Atomics.wait` / `notify` / `waitAsync` use the process-wide
  agent waiter table.
- Property-mode `Atomics.wait` / `notify` / `waitAsync` use per-context waiter
  queues on `Gil`.
- `Atomics.Mutex` and `Atomics.Condition` share the shipped `Lock` and
  `Condition` constructors in threaded contexts and expose proposal-style
  static token APIs on top of those records.
- Host/test knobs that used to be process-global are now per-context
  `Context.TestingOptions` controls for the conformance runners:
  `main_can_block` and `max_js_threads`.
- `Context.TestingOptions.parallel_js` is a test-only Layer-C bring-up switch,
  not a public embedder API. It currently validates the sync `Atomics.Mutex` /
  `Lock` path and `Lock.asyncHold` grant delivery with real `Thread` workers
  running without the context GIL.
- Test-shell helpers such as `print`, `setTimeout`, `drainMicrotasks`,
  `noInline`, `gc`, and the supported `$vm` compatibility hooks (`gc`,
  `edenGC`, `indexingMode`, `useThreadGIL`, `noInline`) exist for conformance
  coverage and corpus compatibility. In GC-enabled contexts, `gc()` /
  `$vm.gc()` request a collection that is serviced at the next safe quiescent
  point, including between microtask jobs after the previous job has unwound.

## Not Supported Today

- True parallel mutation of ordinary JS objects.
- Dropping the GIL around arbitrary heap, array, collection, microtask, async
  waiter, or non-atomic `Value` mutation.
- Sharing ordinary JS values between isolated agents or workers without
  structured clone.
- Treating `Context.TestingOptions` as a general embedder API with a long-term
  compatibility contract.
- Treating `parallel_js` as supported application behavior. It is a focused
  synchronization test mode, not the shipped `enable_threads` model.
- Treating test-shell helpers or `$vm` as an embedder event-loop/API surface.
- Assuming unsupported JSC `$vm` hooks exist: `sharedHeapTest`, dictionary
  conversion, code deletion, disassembly, and related JIT artifact controls are
  intentionally absent until backed by real engine behavior. Supported
  compatibility hooks are deliberately narrow: `gc`, `edenGC`, `noInline`,
  `useThreadGIL`, `indexingMode`, and `ensureArrayStorage`.
- Depending on shell GC while a spawned shared-realm JS thread is actively
  running or parked inside a native call. Active interpreter fields are traced
  at quiescent checkpoints, including the current environment cell and
  engine-owned Promise/VM native closure side records, but arbitrary native/Zig
  stacks are still a Layer-C root-completeness blocker. The `zig-gc`
  dependency has an optional conservative-word marking helper for stack ranges;
  zig-js still needs per-thread stack-bound registration before it can rely on
  that helper for arbitrary parked/running native frames.
- Treating deep recursive call tests as an implemented VM-stack feature. The
  tree-walker still uses native recursion for calls, so PR-249 stack-overflow
  tests that require thousands of pre-overflow calls remain future work.
- Treating remaining PR-249 unpromoted high-pressure JIT, WebAssembly-required
  CVE, and semantic files as part of the default green suite.

## C-API and Context Affinity

The C API keeps the Phase-0 rule: handles are affine to the thread that owns
their `JSContextRef`. A `Context` created without `enable_threads` must only be
touched from its creator thread.

For an `enable_threads` context, the debug invariant changes from creator-thread
affinity to GIL ownership. Internal thread entry points acquire the GIL before
touching shared context state. Embedders should still treat the C-API handles as
thread-affine unless a future API explicitly says otherwise.

## Why the GIL Stays

The GC is still M1: it collects only at quiescent points. Running thread
stacks and ordinary heap mutation also do not yet have the barriers/locks
needed for parallel mutators. Shape transition maps have a per-shape lock now,
ordinary named-property helper paths plus VM plain-property inline caches hold
`Object.property_lock` around shape/slot/accessor/attribute state, including
named-property delete/rebuild, and Promise settlement/reaction lists have a
per-promise lock. Dense-array helper paths and Map/Set helper/cursor paths now
use `Object.elements_lock`, but remaining direct `elements` side doors still
rely on the GIL. Arena allocation, remaining direct collection/tuple element
stores, microtask queues, async waiter arrays, and non-atomic `Value` slots
still rely on the GIL. The GIL protects:

- arena allocation and teardown,
- remaining direct `Object.elements` side doors,
- microtask queues and async waiter arrays,
- non-atomic `Value` slots.

Removing the GIL before those have complete root, synchronization, barrier, and
lifetime stories would turn ordinary property access into data races or
use-after-free bugs.

## Layer-C Blockers

GIL removal is blocked on:

- conservative or precise stack roots for arbitrary running/parked threads,
- object and shape synchronization,
- safe slot and element storage under concurrent readers and writers,
- an atomic representation story for `Value`,
- stress coverage that can run under real parallel mutation with
  ThreadSanitizer clean.

C-API string and handle lifetime is no longer a Layer-C blocker in this list:
`JSStringRef` retain/release is atomic, and GC-enabled `JSValueRef` wrappers use
counted `JSValueProtect` / `JSValueUnprotect` roots. C-API access remains
context-affine unless a future public API explicitly says otherwise.

The detailed prerequisite record lives in [P7-gil-removal.md](./P7-gil-removal.md),
and the GC foundation is tracked in [P7-gc-design.md](./P7-gc-design.md).

## Contribution Rule

No new process-global mutable state may land without a ruling in
[bindings.md](./bindings.md). Use one of:

- `per-thread`: each agent or shared-realm thread gets its own state,
- `locked`: shared state is protected by a mutex or atomics,
- `refused`: the state must never be reachable from a second thread.

This rule applies to file-scope `var`, `pub var`, `threadlocal`, and
container-scope mutable statics.
