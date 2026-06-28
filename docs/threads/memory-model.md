# Thread Memory Model

This page defines the contract for threaded zig-js contexts:

- Engine state must stay race-free, memory-safe, and ThreadSanitizer-clean.
- JavaScript program state can still have program-level races when code shares
  mutable data without synchronization.
- ThreadSanitizer suppressions are allowed only for intentional JavaScript
  program-byte races, never for engine metadata or GC state.

## Contexts

Non-threaded contexts keep the original single-thread affinity rule. A
`JSContextRef` created without thread support must be used by the owning thread.

Threaded contexts are created in Zig with:

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
```

That mode is true-parallel by default. Shared-realm `Thread`s execute
JavaScript on real OS threads over one `Context`, one global object, and one
GC-managed heap.

The serialized fallback is explicit:

```zig
const ctx = try js.Context.createWith(gpa, .{
    .enable_threads = true,
    .gil = true,
});
```

The C API exposes the same choice with `ZJSGlobalContextCreateThreaded(gil)`.
Test harness options such as `parallel_js` and `parallel_midscript_gc` are not
stable embedder APIs.

## Engine State vs Program State

Engine state is the interpreter, VM, heap, and object implementation machinery
that must remain correct regardless of JavaScript interleavings. This includes:

- object shapes, named-property metadata, property slots, accessors, and
  key-order storage,
- indexed elements, arrays, maps, sets, typed-array views, and collection
  helpers,
- lexical environments, closure frames, VM frames, operand stacks, promises,
  reactions, and microtask queues,
- inline caches, thread records, join records, waiter queues, condition
  variables, mutexes, and lock bookkeeping,
- GC allocation, barriers, mark state, roots, finalization state, shared-buffer
  ownership, and C-API protected handles.

Races in that state are engine bugs. They must be fixed with locks, atomics,
publication protocols, or ownership changes. They must not be hidden by
ThreadSanitizer suppressions.

Program state is the mutable data that JavaScript code intentionally shares:

- bytes in `SharedArrayBuffer` or transferred/shared `ArrayBuffer` storage,
- ordinary object properties reachable from multiple shared-realm threads,
- arrays and collections shared by reference,
- higher-level invariants built from multiple reads and writes.

Unsynchronized program-state access is a JavaScript program race. The engine
still has to stay memory-safe and preserve its internal invariants, but it does
not make compound program operations atomic. For example, two threads updating
the same property without `Atomics`, `Lock`, or another synchronization edge can
observe ordinary interleavings and lost updates.

## Happens-Before Tools

Use explicit synchronization for cross-thread program invariants:

- Typed-array `Atomics.*` operations over shared buffer storage provide atomic
  access to the addressed element and drive typed-array `wait`, `waitAsync`, and
  `notify`.
- Property-mode `Atomics.*` operations synchronize through the `(object, key)`
  property cell and provide atomic load, store, exchange, compare-exchange,
  read-modify-write, wait, waitAsync, and notify behavior.
- `Lock`, `Condition`, `Atomics.Mutex`, and `Atomics.Condition` provide
  critical sections and condition waiting for larger invariants.
- `Thread.join()` and `Thread.asyncJoin()` publish thread completion and the
  returned value or thrown exception to the joining thread.
- Agent and worker isolation crosses state by structured clone, transfer, or
  retained `SharedArrayBuffer` storage rather than by sharing ordinary JS heap
  objects.

When a program needs deterministic behavior, protect every shared invariant with
one of these edges. The default no-GIL mode intentionally does not serialize all
JavaScript execution.

## ThreadSanitizer Suppressions

`tsan-suppressions.txt` is intentionally narrow. It suppresses only raw
JavaScript program-byte reads and writes on shared buffer storage where the JS
memory model permits unsynchronized concurrent access. The suppressed frames
must access only the buffer data bytes.

The suppression file must not cover:

- object metadata, shape trees, property slots, or key-order storage,
- environments, closures, frames, stacks, promises, or microtasks,
- lock, waiter, thread, join, or condition state,
- GC allocation, mark bits, barriers, roots, finalization, or shared-buffer
  lifetime metadata,
- C-API handle ownership, protection counters, or string refcounts.

CI runs `tools/tsan-suppression-witness.sh` to prove the suppressions are
load-bearing and narrow. The selected cases must race without the suppression
file, every reported race must name only approved program-byte frames, and the
same cases must pass with suppressions enabled. The script owns the executable
approved-frame regex; keep it in sync with `tsan-suppressions.txt` whenever a
new program-byte access helper is added.

## C-API Rules

`JSStringRef` values are immutable and use atomic retain/release.

GC-enabled `JSValueRef` wrappers are made durable across collection with
`JSValueProtect` and `JSValueUnprotect`. Do not infer additional cross-thread
handle semantics beyond the documented threaded context APIs.

For non-threaded contexts, use handles only on the owning thread. For threaded
contexts, create the context with `ZJSGlobalContextCreateThreaded(gil)` and use
the synchronization rules above for shared program invariants.

## New Shared State

Any new process-global mutable state, file-scope `var`, container-scope mutable
static, or `threadlocal` reachable from threading code must be listed in
[bindings.md](./bindings.md) with one of:

- `per-thread`: each agent or shared-realm thread owns separate state,
- `locked`: shared state is protected by a mutex or atomic protocol,
- `refused`: the state must never be reachable from a second thread.

New shared engine state also needs focused tests and, when it can be reached
from no-GIL execution, TSan coverage.

## Verification

The public contract is checked by:

- `zig build test`,
- `zig build threads-test`,
- `zig build test -Dtsan=true`,
- `zig build test -Dtsan=true -Dtest-filter=parallel_js`,
- the sharded no-GIL PR-249 corpus TSan sweep,
- the TSan suppression-narrowness witness
  (`tools/tsan-suppression-witness.sh`),
- `test262-parallel`,
- `threadfuzz`, including TSan and deterministic-result verifier modes.

When local TSan sweeps are impractical, CI remains the source of truth. Do not
claim a race class is newly verified unless the relevant gate actually passed.
