# Thread Memory Model

This page defines the contract for threaded zig-js contexts:

- Engine state must stay race-free, memory-safe, and ThreadSanitizer-clean.
- JavaScript program state can still have program-level races when code shares
  mutable data without synchronization.
- ThreadSanitizer runs without suppressions. If a future JavaScript
  program-byte false positive needs one, it must land with a dedicated
  load-bearing witness and must never cover engine metadata or GC state.

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
Resizable `ArrayBuffer` storage is in this engine-state category even when the
JavaScript program intentionally races view operations with resize. Typed-array
and `DataView` helpers borrow the live byte slice through the buffer lock when a
peer resize/free is possible, and bulk-copy helpers such as `slice` and
`sliceToImmutable` re-resolve the range and copy from one locked source
snapshot. Those guards are memory-safety guarantees, not a promise that
unsynchronized JavaScript resize races produce deterministic values.
The protected-handle table is covered by a focused mid-script parallel-GC unit
witness: `JSValueProtect` keeps an otherwise-unrooted C-API object alive while
shared-realm `Thread`s drive a finishing sweep, and `JSValueUnprotect` releases
that root afterward.

Shape transitions use an append-only publication rule. The transition hash map
is still mutated only while holding the parent shape's transition lock, but each
fully initialized child shape is also release-published onto an immutable child
list. Cached transition hits may traverse that list with acquire ordering
without taking the transition lock; misses still re-enter the locked hash map
path so duplicate same-name insertions converge on one child shape.

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

### Locks and conditions

Releasing a `Lock` or `Atomics.Mutex` publishes the releasing thread's prior
ordinary JavaScript writes to the next thread that successfully acquires that
same lock. This applies to normal return, explicit unlock/release functions,
unlock tokens, `[Symbol.dispose]`, and exception unwinding from `hold(fn)`.

`Condition.wait(lock)` and the token-based `Atomics.Condition` operations
atomically register the wait, release the associated lock, and reacquire it
before returning. The reacquire is the publication edge. `notify`/`notifyAll`
select current waiters but are not, by themselves, a replacement for protecting
the predicate with the same lock. Notifications are not buffered, spurious
wakeups are allowed, and callers must test the predicate in a loop.

### Atomics

Typed-array `Atomics.*` operations use the ECMAScript sequentially consistent
atomic order for the addressed shared integer element. A reader that observes a
published atomic flag also observes writes sequenced before the publishing
atomic operation. Non-atomic shared-buffer byte access does not gain this edge.

Property-mode `Atomics.*` operations are linearized for the addressed
`(object, property key)` cell. A load/RMW/wait observation of a value written by
an earlier atomic operation on that cell publishes writes sequenced before the
writer's operation. This contract does not make a multi-property transaction
atomic; use one `Lock` when an invariant spans several keys or objects.

For both typed-array and property waiters, the value is checked again while the
waiter-table synchronization is held before enqueue. `notify` wakes only current
matching waiters and does not itself change the value. Correct protocols publish
the new value atomically and then notify; waiters always re-check in a loop.

### Thread completion

Publishing a thread's completion synchronizes with a successful `join()` and
with settlement of every `asyncJoin()` promise. The joiner/observer sees the
thread body's prior side effects, the returned value by identity, or the actual
thrown value by identity. A completed `join()` is still an ordering edge even
when it does not need to park.

A spawned thread drains its own pending microtasks before publishing completion.
Promise reactions are FIFO within one queue, including jobs appended by an
earlier job. Cross-thread queue handoff is synchronized, but there is no promised
global total order between independent producers; only the order in which jobs
were appended to the destination queue is observed there.

### GC publication is not program synchronization

The GC's insertion barriers, remembered old-owner set, root-publication
handshake, and born-cell protocol ensure that reachable engine cells are not
collected during minor, incremental, or concurrent full collection. They do not
make unsynchronized JavaScript reads/writes deterministic and do not create a
program-level happens-before edge. WeakRef targets and weak collection keys stay
weak under the same rule.

## Unsynchronized and restricted access

Ordinary shared objects, arrays, Maps/Sets, and non-atomic shared-buffer access
have no cross-operation ordering guarantee without one of the edges above. The
engine preserves valid internal shapes, storage, references, and complete
`Value` representations, but programs must not depend on which racing write
wins, whether a read sees an earlier or later racing value, or whether a compound
read-modify-write loses an update.

`ConcurrentAccessError` is narrower and explicit: after `Thread.restrict(obj)`
successfully claims a supported plain object or array, an enforced foreign-thread
access throws. The engine does not automatically restrict ordinary shared
objects, and restriction does not turn other objects into synchronized data.

## ThreadSanitizer Suppression Policy

CI currently runs the no-GIL ThreadSanitizer corpus without a suppression file.
Plain typed-array paths take the buffer lock, and Atomics paths use hardware
atomics, so even JavaScript program-byte access stays TSan-clean today.

If a future JS-defined program-byte false positive genuinely requires a
suppression, it must land with a deterministic, load-bearing witness that fails
without the suppression and passes with it. A suppression file must not cover:

- object metadata, shape trees, property slots, or key-order storage,
- environments, closures, frames, stacks, promises, or microtasks,
- lock, waiter, thread, join, or condition state,
- GC allocation, mark bits, barriers, roots, finalization, or shared-buffer
  lifetime metadata,
- C-API handle ownership, protection counters, or string refcounts.

## C-API Rules

`JSStringRef` values are immutable and use atomic retain/release.
Retain-count overflow is rejected instead of wrapping.

GC-enabled `JSValueRef` wrappers are made durable across collection with
`JSValueProtect` and `JSValueUnprotect`. The counted protected-handle table
deduplicates roots and rejects protection-count overflow instead of wrapping.
`JSValueRef` and `JSObjectRef` boxes carry the context that created them, so
context-taking APIs reject wrong-realm handles instead of mixing arenas or object
graphs. Do not infer additional cross-thread handle semantics beyond the
documented threaded context APIs.

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
- `test262-parallel`,
- `threadfuzz`, including TSan and deterministic-result verifier modes.

Focused unit tests whose names begin with `memory model:` exercise lock/condition
publication, property and typed-array Atomics message passing, join/asyncJoin
result and exception publication, and per-thread microtask FIFO-before-completion.

When local TSan sweeps are impractical, CI remains the source of truth. Do not
claim a race class is newly verified unless the relevant gate actually passed.
