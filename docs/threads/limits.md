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
- Typed-array `Atomics.wait` / `notify` / `waitAsync` use the process-wide
  agent waiter table.
- Property-mode `Atomics.wait` / `notify` / `waitAsync` use per-context waiter
  queues on `Gil`.
- `Atomics.Mutex` and `Atomics.Condition` are proposal-aligned aliases for the
  shipped `Lock` and `Condition` constructors in threaded contexts.

## Not Supported Today

- True parallel mutation of ordinary JS objects.
- Dropping the GIL around arbitrary heap, shape, object, array, or promise
  mutation.
- Sharing ordinary JS values between isolated agents or workers without
  structured clone.
- Treating PR-249 JIT, GC-stress, WebAssembly, object-model, CVE, or
  scaling/benchmark files as part of the default green suite.
- Exposing test-only host knobs as stable embedder API.

## Host Knobs

Two knobs exist for tests and conformance hosts:

- `js.jsthread.max_threads`: caps live shared-realm `Thread` spawns for corpus
  cases such as `thread-id-bounds.js`.
- `js.agent.main_can_block`: models the host's `[[CanBlock]]` bit for tests
  such as `blocking-gate.js`.

Do not expose these as general embedder API without a separate design. They are
process-visible knobs today and are set around individual tests.

## C-API and Context Affinity

The C API keeps the Phase-0 rule: handles are affine to the thread that owns
their `JSContextRef`. A `Context` created without `enable_threads` must only be
touched from its creator thread.

For an `enable_threads` context, the debug invariant changes from creator-thread
affinity to GIL ownership. Internal thread entry points acquire the GIL before
touching shared context state. Embedders should still treat the C-API handles as
thread-affine unless a future API explicitly says otherwise.

## Why the GIL Stays

The engine still uses arena allocation for ordinary JS objects. Arena-backed
object graphs do not have per-object lifetime management, cross-thread roots,
or write barriers. The GIL protects:

- arena allocation and teardown,
- shape transition maps,
- object shape pointers,
- slot and element vectors,
- accessor and attribute maps,
- promise and async waiter state,
- non-atomic `Value` slots.

Removing the GIL before those have their own synchronization and lifetime story
would turn ordinary property access into data races.

## Layer-C Blockers

GIL removal is blocked on:

- a tracing GC with safepoints and complete roots for running threads,
- object and shape synchronization,
- safe slot and element storage under concurrent readers and writers,
- an atomic representation story for `Value`,
- C-API string / handle lifetime rules that work across threads,
- stress coverage that can run under real parallel mutation with
  ThreadSanitizer clean.

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
