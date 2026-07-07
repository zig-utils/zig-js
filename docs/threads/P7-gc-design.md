# Phase 7 GC Design: `zig-gc`, a Precise Non-Moving Collector

Status: historical design record plus GC implementation notes. The shared-realm
`Thread` API is now true-parallel by default; current shipping status lives in
[`index.md`](./index.md), [`production-readiness.md`](./production-readiness.md),
[`limits.md`](./limits.md), and issue
[#1](https://github.com/zig-utils/zig-js/issues/1).

Older milestone counts in this file, including `threads-test` 209/209
checkpoints, are preserved as checkpoint history. The current PR-249 allowlist
status is documented in [`testing.md`](./testing.md).

This is the concrete plan and implementation record for the tracing GC that
enabled no-GIL shared-realm work. GC contexts reclaim unreachable cells, clear
`WeakRef` targets, run `WeakMap` / `WeakSet` weak-key cleanup through the
ephemeron/weak-slot pass, and make `FinalizationRegistry` records available to
`cleanupSome()` and automatic cleanup jobs after quiescent collection.

## Decisions (and why)

- **Precise, not conservative.** The collector knows the engine's exact types
  and traces only real references. JS heaps are full of `f64`s (and, later,
  NaN-boxed words) that alias pointers; conservative scanning would falsely
  retain them, and precise reachability is *required* to clear weak refs and
  fire finalizers correctly.
- **Non-moving.** No compaction, no pointer rewriting, no read barriers. This
  matches the Phase-7 reference design (WebKit Riptide is non-moving) and keeps
  M1 tractable. Compaction can come much later, if ever.
- **Mark-sweep, tri-color.** Simple, well-understood, incrementalizable, and
  concurrentizable with a write barrier — the path to Phase 7.
- **A reusable library + a thin engine binding** (the MMTk model: a
  language-agnostic core used by V8/Ruby/Julia proves this split works). The
  collector owns the *mechanism*; zig-js provides the *policy* (roots +
  per-type tracing). No third-party dependency — pure Zig.
- **Staged: single-threaded under the GIL first.** M1 ships a stop-the-world
  collector while the GIL still holds, proving the allocation/root/trace
  refactor and fixing weak semantics with test262 staying green. Concurrency
  (M3) is "make the existing collector concurrent," not "invent both at once."

## Library shape: `~/Code/Libraries/zig-gc`

A sibling path-dep, exactly like `../zig-regex`. The core is generic over a
*binding* the embedder supplies at comptime.

```zig
// The contract the runtime implements. All comptime-dispatched (no vtable
// cost on the allocation hot path); `Binding` is a type with these decls.
pub fn Heap(comptime Binding: type) type { ... }

// Binding provides:
//   const ObjectHeader = ...;                       // embedder's cell header type
//   fn traceRoots(gc: *Heap, v: *Visitor) void;     // enumerate all roots
//   fn trace(cell: *anyopaque, kind: Kind, v: *Visitor) void; // trace one cell
//   fn finalize(cell: *anyopaque, kind: Kind) void; // run a finalizer (optional)

pub const Visitor = struct {
    // The mutator calls these from its per-cell trace fn. `mark` pushes onto
    // the mark stack if white; idempotent.
    pub fn mark(v: *Visitor, cell: *anyopaque) void;
    pub fn markValue(v: *Visitor, word: u64) void;   // decode a tagged Value, mark if it's a cell
    pub fn markWeak(v: *Visitor, slot: *?*anyopaque) void; // register a weak edge
};

// Allocation: size-class segregated free lists over page-aligned blocks.
pub fn alloc(gc: *Heap, comptime T: type, kind: Kind) !*T;   // bump within a block
pub fn allocBytes(gc: *Heap, n: usize, kind: Kind) ![]u8;

// Collection cycle (M1: stop-the-world):
//   1. mark from roots (traceRoots → drain mark stack via trace)
//   2. process weak edges: any weak slot whose target stayed white → clear it,
//      queue its registry's finalizer
//   3. sweep: free white cells (calling finalize), reset mark bits
pub fn collect(gc: *Heap) void;
pub fn maybeCollect(gc: *Heap) void; // heap-growth-policy triggered, called at safepoints
```

Each cell carries a one-word GC header (mark bit + `Kind` tag + free-list
link); the engine's structs gain an embedded `gc_header` field. `Kind` is the
engine's cell taxonomy so `trace`/`finalize` can switch without RTTI.

## The zig-js binding

### Cell kinds (the trace surface)

The engine heap is one monolithic `Object` (`value.zig:430`) plus side cells.
`trace` switches on `Kind`:

| Kind | Type | References to visit |
|---|---|---|
| `object` | `value.zig` `Object` | `shape`, `proto`, `ctor_ref`, `proxy_target`, `proxy_handler` (`*Object`); every `Value` in `slots` and strong `elements`; `accessors` map get/set Values; `prim` (`?Value`); `js_func`/`gen`/`bound`/`promise`/`iter_helper`/`module_ns`/`arg_map_env` (type-erased cells); engine-owned native `private_data` records for Promise/VM async callbacks; `array_buffer`/`typed_array`/`data_view`/`temporal`; **weak**: `weak_ref_target` and WeakMap/WeakSet `weak_entries`; **ephemeron**: WeakMap values when their keys are live |
| `shape` | `shape.zig` `Shape` | `parent`; the `*Shape` values in `transitions` (the keys are property-name strings) |
| `env` | `interpreter.zig:126` `Environment` | every `Value` in `vars`; `parent`; `aliases` (live cross-env bindings); `disposables` |
| `function` | `interpreter.zig:266` `Function` | closure `env`; bound `this`/home-object Values (AST nodes are immutable — see below) |
| `generator` / `boundfn` / `promise` / `iterhelper` / `modulens` / `temporal` | side structs | their captured Values / envs / reaction callbacks |
| `arraybuffer` / `typedarray` / `dataview` | buffer structs | the viewed `*Object` buffer; **finalize** non-shared `ArrayBufferData` byte storage; SAB storage is refcounted (`shared_buffer.zig`) — `finalize` releases the retain |

`private_data: ?*anyopaque` (`value.zig`) is host-owned and opaque for embedder
callbacks, so embedders that stash cells there must root them themselves. Engine
native closures are the exception: the object tracer recognizes the VM/Promise
closure functions that carry generator, resolving-function, `finally`, and
combinator side records, then marks their captured cells explicitly.

### Roots

`traceRoots` enumerates, per live `Context`:
- `global_object`, `env`, `root_shape`, `tdz_marker` (`context.zig`)
- the `microtasks` queue (each `Microtask` holds callback + argument Values)
- `exception` slot, `async_waiters`, completed `js_threads` records, and
  property-mode `waitAsync` tickets
- active module caches (`Context.mod_cache`) while `evaluateModule` or host
  script dynamic import is holding a module graph; each cached module roots its
  module environment and namespace object
- registered active `Interpreter` roots at quiescent checkpoints: the current
  environment cell plus its bindings, local microtask/waiter/finalization
  queues, `this`, return/exception/`new.target`, active native function, `with`
  objects, symbols, and `import.meta`
- `sab_retains` are *not* GC roots — SAB storage is refcounted process-wide;
  the GC only `finalize`s the wrapper's retain.

### The handle problem (C-API)

Embedders hold `JSValueRef`s — pointers to `Boxed` cells (`c_api.zig`) — that
must keep objects alive across calls, but the GC can't see the embedder's
variables. Solution: a **handle table** (JSC "protected values" / V8
`HandleScope` model). `JSValueProtect` registers the `Boxed` in a per-context
counted handle table that `traceRoots` walks; matching `JSValueUnprotect` calls
decrement and remove the root. This is the one piece of new C-API bookkeeping
M1 adds.

### Write barrier

M1 is stop-the-world, so **no barrier is needed** (the whole graph is stable
during collection). M2/M3 add a Dijkstra-style insertion barrier at the
handful of reference-storing sites — all of which already funnel through a
small set of helpers: `Object.setOwn`/`setSlot` (`value.zig:822`),
`elements.append`, `Environment` binding writes, and `Shape.transition`
(`shape.zig:56`). The funnel discipline the engine already follows is what
makes a precise barrier insert at O(10) sites, not everywhere.

### AST is immutable and arena-owned

Parsed `ast.Node` trees never mutate and outlive every object that references
them; keep them in a per-context arena *outside* the GC heap (or a permanent
GC space that's never swept). Functions reference AST by pointer but the GC
treats those as non-cells. This keeps the trace surface to runtime values only.

## Algorithm details (M1)

- **Allocation:** segregated free lists by size class over `mmap`/page-allocator
  blocks (e.g. 16 KiB). Small cells bump within a block; large cells get
  dedicated blocks. Per-`Kind` size is mostly fixed (`Object` is one size), so
  size classes are few. In zig-js this first ships as `Context.GcCellBacking`:
  the `zig-gc` heap still sees a normal allocator, while 16-byte-aligned cell
  slabs are recycled from 64 KiB size-class chunks and non-cell heap side storage
  delegates unchanged. Fresh chunks reserve chunk/bump-offset/address-index
  metadata in fixed-size capacity chunks, then hand out cells lazily through
  bump cursors and a per-bucket bump hint rather than pre-linking every slot up
  front. Chunk ownership is tracked per size class, so free/remap
  classification first rejects pointers outside the bucket address span, tries a
  per-bucket recent-chunk hint, and only then scans the matching-size chunks
  instead of the entire backing. At context teardown the backing switches to
  bulk-teardown mode: `zig-gc` still finalizes every live cell, but owned cell
  frees skip freelist rebuilds because the backing releases all chunks
  immediately afterward. Bucket-shaped delegated side allocations are still
  classified once and freed through the wrapped allocator, and non-owned
  bucket-shaped resize/remap/free paths do not retake the backing lock after
  classification. Explicit quiescent collection uses per-slab live counters to
  trim fully unused tail chunks after one-off allocation spikes, while retaining
  non-empty and empty inner chunks for reuse. Single-mutator object side stores
  now bypass the `GcCellBacking` wrapper and allocate directly from the context
  allocator; true-parallel JS keeps the synchronized wrapper for those stores so
  no-GIL embedders are not required to provide a thread-safe allocator.
- **Mark:** explicit mark stack (no recursion — JS graphs are deep). Tri-color:
  white = unmarked, grey = on stack, black = traced.
- **Weak processing:** after the strong mark stack drains, an ephemeron
  fixed-point marks WeakMap values whose keys are live. Then every registered
  weak edge whose target is still white is cleared, WeakMap/WeakSet drop
  white-keyed entries, and FinalizationRegistry records whose targets died are
  marked ready for `cleanupSome()` or automatic host cleanup jobs.
- **Sweep:** walk blocks; white cells → `finalize` then return to the free
  list; flip black→white for next cycle. Lazy/incremental sweep is an M2 option.
- **Trigger:** `maybeCollect` at the existing `(steps & 1023)` safepoints
  (`interpreter.zig` `eval`, `vm.zig` `execLoop`) and on allocation when the
  heap exceeds a growth threshold (e.g. 2× live-after-last-collect).

## The library exists

`zig-gc` is scaffolded as a sibling at `../zig-gc` (its own git repo, MIT,
no deps): `gc.Heap(comptime Binding)` — a working precise non-moving mark-sweep
collector with `create`/`collect`/`maybeCollect`/`deinit`, a `Visitor` with
`mark`/`markWeak`, the `Binding` contract (`Kind` + `traceRoots`/`trace`/
`finalize`), 16-byte-aligned single-word cell headers, and a 2×-live growth
policy. `zig build test` is green (leak-checked: cycles survive via a root,
garbage is swept, weak edges clear before their target is freed, finalizers
run). This is the M1 mechanism; what remains is the zig-js *binding*.

## Consuming it (M0 wiring — turnkey)

Do this once the engine's `context.zig`/`interpreter.zig` surface is settled
(it carries the root set and the side-cell type definitions the binding traces):

1. **Dependency.** `build.zig.zon`: add `.zig_gc = .{ .path = "../zig-gc" }`.
   `build.zig`: `const gc_mod = b.dependency("zig_gc", .{...}).module("gc");`
   and add `.{ .name = "gc", .module = gc_mod }` to every module's `imports`
   (mirrors the existing `regex` wiring at `build.zig:7-15`).
2. **The binding — `src/gc.zig`.** Define `Kind` (the cell taxonomy table
   above), `traceRoots(ctx, v)` (the root set below), `trace(cell, kind, v)`
   (the per-kind reference list above), `finalize(ctx, cell, kind)` (release
   SAB retains / free non-shared `ArrayBufferData` bytes). `ctx` is `*Context`.
3. **`Context` holds the heap.** Add `gc: gc.Heap(GcBinding)` next to
   `arena_state` (`context.zig:22`); `create` inits it, `destroy` `deinit`s it.
   Add the handle table for C-API `Boxed` roots.
4. **M0 stays disabled by default.** Route `arena()`-style allocation through a
   shim that still bump-allocates until M1 flips `create` on — so M0 is
   byte-identical on test262 and the wiring lands independently of the collector
   going live.

## Staging plan

- **M0 — interface, no behavior change. ✅ DONE** (`0515c33`). `zig-gc` wired as
  a dependency; `src/gc.zig` is the binding — `CellKind`, `traceObject`/
  `traceEnv`/`traceFunction`/`traceBoundFn`/`tracePromise`/`traceGenerator`/
  `traceIterHelper`/`traceModuleNs`, `Binding.traceRoots` over the `Context`
  persistent roots, and `finalize` — all written against the real engine types
  and **validated in isolation** on real `value.Object` graphs (cycles, proto,
  slots, accessors, garbage; leak-checked). GC stays inert (the arena still
  allocates), so test262 is byte-identical (42,734/47,930). Lesson banked for
  M1: `finalize` must free a dying cell's non-arena sub-allocations
  (`slots`/`elements`/`accessors` backing) — the GC frees only the cell itself.
- **M1 — single-threaded mark-sweep under the GIL.** *Foundation landed:*
  `Context.Options.enable_gc` + `Context.gc`/`gc_binding` (the collector plus a
  small `Binding` wrapping the `*Context`, so the shared `zig-gc` library needs
  no change), `Interpreter.gc` plumbed, and `newObject` funnels through
  `gc_mod.allocObject` (GC when on, arena when off). Flag **off** =
  byte-identical (test262 unchanged); flag **on**, validated: full test262
  **42,745/47,930, 0 crashes**, conformance 33/33, threads 209/209, and a
  leak-checked `enable_gc` unit test (object-heavy run + clean teardown).
  *Uniform Object heap landed:* all ~171 `value.Object` allocation sites across
  8 files now go through `gc_mod.allocObj(arena)`, which routes via a
  **thread-local active heap** (`setActiveHeap`, set/restored in `createWith`
  for intrinsics, `evaluate`/`evaluateModule` for execution, and shared-realm
  `Thread` entry for spawned JS threads) — so every site funnels through the GC
  when on, the arena when off, *without* threading the heap pointer through
  hundreds of signatures. Intrinsics (`installGlobals`) and user objects are all
  GC cells now. Validated: flag off byte-identical; flag on
  full test262 **42,753/47,930, 0 crashes**, conformance 33/33, and the **whole
  unit suite leak-checked** with GC defaulted on. (`global_obj`/`tdz` predate the
  heap so they stay arena for now — fine while collection is teardown-only.)
  *Uniform cell heap landed:* the 28 side-cell sites (`Environment`×17,
  `Function`×2, `Generator`×3, `BoundFn`, `Promise`, `IterHelper`×3, `ModuleNs`)
  now funnel through per-type `gc_mod.allocEnv`/`allocFunction`/… (each tagged
  its own `CellKind`), and `createWith` was reordered so `global_obj`/`tdz` are
  GC cells too. **Every heap cell a GC cell when enabled** — the corruption-free
  prerequisite for mid-run marking (a GC cell never references arena memory that
  `mark` would mis-read). Validated: flag off byte-identical; flag on full
  test262 **42,757/47,930, 0 crashes, host-fail 0**, conformance 33/33, whole
  unit suite leak-checked. (At this point, cell *sub-allocations* —
  `Object.slots`/`elements`, `Environment.vars`, promise reaction lists — stayed
  arena; later bullets below record the pieces that have since moved to
  GC-finalized storage.)
  *Quiescent collection landed — the GC reclaims now.* `Context.collectGarbage()`
  runs a precise mark-sweep, called automatically at the top of `evaluate`
  (before the interpreter starts, so the Zig stack holds no live `Value`s and
  the `Context` roots `gc.zig`'s binding traces are complete) and callable
  directly by embedders at any quiescent point. Registered active interpreter
  roots cover host checkpoints such as microtask/module drains; collection is
  still guarded to skip while spawned shared-realm threads may hold arbitrary
  parked native/Zig stacks. Validated:
  flag off byte-identical; flag on full test262 **42,771/47,930, 0 crashes,
  host-fail 0** (collection runs on every one of ~24k contexts — proof the root
  set is complete, since a missed root would free a live intrinsic and crash);
  conformance 33/33; whole unit suite leak-checked *with collection on*; and a
  reclamation test (`collectGarbage` frees 500 unreachable temporaries while a
  `globalThis`-retained graph survives intact). Note: test262 doesn't *observe*
  GC (no `$262.gc`; one `evaluate` per test), so the conformance number is
  unchanged by design — the win is operational (memory reclamation for
  long-running contexts).
  *Microtask-boundary shell GC landed:* `gc()` / `$vm.gc()` requests are now
  serviced between microtask jobs after the previous job has unwound and the
  remaining queue is rooted, including in threaded contexts once every spawned
  `Thread` record is done. The tracer now covers completed thread records,
  property-mode `waitAsync` tickets, promise resolving-function private data,
  VM async resume callback private data, and active interpreter checkpoint
  fields such as `import.meta`. This promotes
  `cve/mc-dos-waiter-table-storm.js`, whose reclamation arm depends on
  WeakRefs clearing across async microtask turns.
  *Thread host-queue roots landed:* shared-realm threading queues now participate
  in the root policy rather than relying on incidental JS references. Queued
  `Lock.asyncHold` tasks in `Gil.tasks`, per-lock pending grant jobs, async
  condition waiters, typed-array `waitAsync` waiter/reaction roots, pending
  `Thread.asyncJoin` promise/reaction roots, ThreadLocal stored values, thread
  completion results, and release-function lock records trace or barrier their
  hidden JS values, covering callbacks/promises that live only in native side
  records. Contended
  `Lock.hold` also temp-roots its receiver and callback while native acquisition
  parks and pumps. The mid-script GC fuzzer now leaves children completed but
  unjoined across the allocation-pressure window and verifies that both an
  object result and a thrown exception object survive until `join()`, directly
  exercising the completion-record roots. It also keeps a typed-array
  `waitAsync` promise/reaction graph reachable only through the native waiter
  queue until notification, pending `Thread.asyncJoin` fulfillment/rejection
  reactions reachable only through native completion records until the child
  threads are released, a sibling promise-publication case where a
  child-returned typed-array `waitAsync` promise, a child-returned rejected
  promise, a child-returned user thenable, and a child-thrown object remain
  rooted through completion/native waiter state until post-sweep
  `join()`/`asyncJoin()` fulfillment, rejection, thenable assimilation, and
  thrown-object publication, a sibling sync-wait cleanup case where property
  `Atomics.wait`, `Condition.wait`, and contended `Lock.hold` peers stay parked
  through a finishing sweep before their stack roots and exact
  `FinalizationRegistry` cleanup count/sum are verified, expired property
  `waitAsync` tickets compact while those peers are parked, and one live
  property `waitAsync` ticket plus an isolated Worker parked on a retained
  `SharedArrayBuffer` remain live through the sweep until notification/release,
  a sibling sync-wait burst case where multiple same-property,
  same-`Condition`, and same-`Lock` waiters stay parked through a finishing
  sweep before burst release and exact finalization cleanup, a sibling
  `Atomics.Mutex.lockIfAvailable` case where
  acquire-after-release and timeout token waiters stay parked behind a holder
  through a finishing sweep before reused-token acquire/timeout results and
  exact finalization cleanup are verified, a sibling static
  `Atomics.Condition.wait` case where notify/reacquire token waiters stay
  parked through a finishing sweep before exact notify counts, token
  reacquisition, `asyncJoin` observers, and finalization cleanup are verified,
  and a sibling teardown
  case where parked children hold child-owned typed-array `waitAsync` tickets
  through a finishing mid-script sweep before parent failure terminates them.
  `Thread.join()` park unwinds now clear `gc_parked` and leave the completion
  mutex balanced, and `gc_parked` is published only for the actual native
  condition wait rather than join-time task pumping, preventing stale or moving
  frozen-peer state after termination/errors. Requested shell/host GC also
  refuses to disturb an elected mid-script parallel collector while threads are
  live; later quiescent collection aborts stale parallel mark state before a
  fresh precise mark.
  *Dependency root helper landed:* `zig-gc` now exposes optional conservative
  word marking for native stack or register-spill ranges, with dependency-local
  tests covering exact and interior payload pointers. zig-js still needs
  per-thread stack-bound registration before this removes the arbitrary native
  stack root blocker.
  *Module-graph roots landed:* `gc.zig` now traces active `Context.mod_cache`
  module graphs, marking each module environment and namespace object while
  module evaluation or host script dynamic import owns the cache. `evaluateModule`
  clears its transient `mod_cache`/`mod_host` pointers on exit, removing the old
  stale stack-pointer hazard and allowing later quiescent collections to run.
  Validated by GC-enabled tests that a cached module environment survives
  collection and that a completed `evaluateModule` no longer blocks collection.
  *SharedArrayBuffer retain finalization landed:* a dying SAB wrapper cell now
  releases exactly one entry from the realm `RetainList`, so cross-agent shared
  backing storage is no longer pinned until `Context.destroy()` when the JS
  wrapper becomes unreachable. Multiple wrappers over the same backing store are
  handled one retain at a time. Validated by a GC-enabled WeakRef test that keeps
  a SAB alive while strongly reachable, then drops the strong reference and
  observes both the WeakRef target and the realm retain list clear after
  collection.
  *ArrayBuffer byte finalization landed:* non-shared `ArrayBufferData` metadata
  and byte slabs created in GC-enabled contexts now allocate from the context
  backing allocator, not the arena, and object finalization frees them with the
  original 8-byte alignment. Resizable `ArrayBuffer.prototype.resize()` releases
  the old slab when publishing a new one. Validated by GC-enabled tests that
  watch live byte accounting stay stable across resize and return to baseline
  immediately after a weak-only ArrayBuffer wrapper is collected.
  *Promise reaction-list finalization landed:* pending promise reaction buffers
  in GC-enabled contexts now allocate from the context backing allocator. They
  are released immediately when the promise settles and by the promise-cell
  finalizer when an unreachable pending promise is collected. Reaction-list
  appends reserve fixed-size capacity chunks under `Promise.lock` before
  capacity-assumed writes, reducing allocator growth while many observers attach
  to one pending promise. Validated by GC-enabled tests that track reaction-entry
  accounting across settlement and weak-only pending-promise collection.
  *Environment binding-table finalization landed:* GC-created lexical/function/
  module/realm environments now keep their binding hash tables, const/fn-name
  sets, import-alias table, disposable list, and duplicated binding-name strings
  in the context backing allocator. The environment finalizer releases those
  side tables and decrements binding-name accounting when the environment cell
  dies. Validated by a GC-enabled closure test that keeps a captured lexical
  environment alive, then drops the closure and observes the duplicated
  binding-name byte count return to baseline after collection.
  *Object named-property backing finalization landed:* in GC-enabled contexts,
  ordinary object named-property slots, accessor maps, accessor/data key-order
  lists, property-attribute maps, and array hole sets now allocate from the
  context backing allocator when first mutated. Each object records which
  stores are GC-owned so the object finalizer releases exactly those stores
  when the cell dies, while arena-mode objects remain unchanged. The rare
  delete/rebuild path now releases old GC-owned slots/key-order storage before
  rebuilding. Validated by a GC-enabled WeakRef test that exercises data
  properties, accessors, attributes, deletion, and holes, then observes the
  object backing-store count return to a stabilized baseline after collection.
  *Weak collection and FinalizationRegistry record backing finalization landed:*
  WeakMap/WeakSet entry buffers and FinalizationRegistry record buffers now use
  the same GC-mode object backing allocator and are released by the object
  finalizer when their owning collection/registry dies. Validated by a
  GC-enabled test that keeps WeakMap, WeakSet, and FinalizationRegistry records
  strongly reachable across collection, then drops the owner and observes
  backing-store accounting return to baseline.
  *Dense `Object.elements` finalization landed:* array elements, Map/Set entry
  storage, structured-clone element buffers, VM argument arrays, and built-in
  result arrays now use the owning object's GC-mode backing allocator for
  `append`/`appendSlice`/`insert`/capacity growth. The object finalizer releases
  the dense element buffer when the cell dies. Validated by a GC-enabled test
  that keeps array, Map, and Set element buffers alive across collection, then
  drops the owner and observes backing-store accounting return to baseline.
  *Typed-view, DataView, and Temporal metadata finalization landed:* typed array
  view records, DataView records, structured-clone typed-view metadata, and
  `Temporal.*` internal-slot records now allocate from the owning object's
  GC-mode backing allocator. The object finalizer destroys those metadata
  records when the wrapper cell dies. Validated by GC-enabled tests that keep
  typed arrays, subarrays, DataViews, structured-cloned typed views, PlainDate,
  and Duration objects live across collection, then drop the owners and observe
  backing-store accounting return to baseline.
  *Generator and mapped-arguments backing finalization landed:* suspended
  generator stack/handler buffers, async-generator request queues, and sloppy
  mapped-arguments parameter-map name slices now allocate from GC-owned backing
  allocators. The generator and object finalizers free those buffers when their
  cells die. Validated by GC-enabled tests for suspended generators,
  async-generator queued requests, and live mapped-arguments aliasing.
  *Shell `gc()` requests landed:* the test-shell `gc()` hook no longer calls
  `Heap.collect()` while JS is live on the Zig stack. It sets a per-Context
  pending bit, and `evaluate` / `evaluateModule` service that request at the
  next quiescent entry point. This keeps PR-249 object-model flag identity tests
  from crashing while preserving the M1 root-completeness rule.
  *Active interpreter and native closure roots landed:* registered interpreters
  now mark the active environment cell, not only its values, and object tracing
  follows engine-owned Promise/VM native `private_data` records. This keeps
  async microtask GC from reclaiming live function environments or Promise
  combinator result arrays while waiter-table and WeakRef reclamation tests run.
  *C-API protected handle table landed:* `JSValueProtect` registers each
  protected `Boxed` (`JSValueRef`) on `Context.c_api_handles` when the GC is on
  (`*Boxed` aliases `*Value`), and `traceRoots` marks them until matching
  `JSValueUnprotect` calls remove the counted root — so an embedder-held
  protected `JSValueRef` survives collection without pinning every transient
  result for the context lifetime.
  `JSGarbageCollect` is now a **real** precise mark-sweep (was a documented
  no-op) when the context opts into the GC; the default arena-backed
  `JSGlobalContextCreate` is unchanged, so it stays a no-op there. Validated by a
  C-API test (`JSGarbageCollect` reclaims 500 garbage objects while a protected
  `JSValueRef` keeps its object — `tag === 123` after collection — and later
  releases the object after the final `JSValueUnprotect`); conformance 33/33,
  threads 209/209, full unit suite leak-checked.
  *WeakRef weak edges landed:* `Object` now keeps a separate WeakRef brand and
  nullable target object slot; `gc.zig` registers that slot with
  `Visitor.markWeak`, so a collection clears the slot before sweeping an
  otherwise-unreachable referent. `WeakRef.prototype.deref()` now returns
  `undefined` after collection while continuing to brand-check the WeakRef
  object itself. Validated by GC-enabled tests for cleared weak-only targets and
  strongly reachable targets that survive collection.
  *WeakMap/WeakSet ephemerons landed:* `zig-gc` now exposes optional
  `traceEphemeron` and `afterWeak` hooks. WeakMap values are marked only at the
  ephemeron fixed point when their keys are live; dead WeakMap/WeakSet keys are
  cleared and pruned before sweep. Validated in `zig-gc` with an exact
  ephemeron test and in zig-js with GC-enabled WeakMap/WeakSet tests.
  *FinalizationRegistry cleanup landed:* registries now store typed records
  with weak target/token pointers and strong held values. Collection marks
  records ready when their target dies, and
  `FinalizationRegistry.prototype.cleanupSome()` delivers those holdings after
  the quiescent collection point. The same ready records are queued as
  per-context host cleanup jobs and drained by the interpreter checkpoint,
  including promise microtasks queued by cleanup callbacks.
  The GC binding also skips the embedded global environment when tracing
  function closures, fixing a root-completeness bug exposed by live cleanup
  callbacks.
  *Mid-script collection landed (single-threaded):* the GC now collects *while
  JS runs*, not only at quiescent points. Two new root sources make this sound.
  (1) **Conservative native-stack scanning** (`src/stack_scan.zig`): the
  collecting thread spills its callee-saved registers (aarch64/x86_64 inline
  asm), captures the live stack pointer, and conservatively marks every machine
  word in `[sp, frame_high]` that points into a managed cell — covering the
  tree-walker's `Value` locals/registers, which a precise tracer cannot see.
  `frame_high` is registered by `enter(@frameAddress())` at `evaluate` /
  `evaluateModule` / spawned-thread entry. The `zig-gc` `Visitor` already
  exposed `markConservativeWord`; the interior-pointer lookup was made O(log n)
  (a per-collection address-sorted index, built lazily only when a conservative
  mark actually occurs) so a stack scan no longer costs O(words × cells).
  (2) **Active VM `Exec` roots**: the VM operand stack is arena-backed (not a GC
  cell), so its live `Value`s are invisible to both the precise object graph and
  the conservative scan; each running `Exec` is registered on the interpreter
  (`gc_execs`) and the VM flushes `acc`/`ip` into it at the safepoint, so the
  tracer marks `exec.stack`/`exec.acc` precisely. Collection is driven at the
  existing `(steps & 1023)` checkpoints via `Context.collectMidScript`
  (heap-growth-triggered `maybeCollect`), guarded so it only runs when the GC is
  on, the target supports the stack scan, and **no other shared-realm thread is
  running** — a parked thread's native stack is not scanned yet, so mid-script
  collection stays single-threaded. Everything is gated behind `enable_gc`, so
  the arena engine is byte-identical (every new hook is a null-`fn`/`gc == null`
  no-op). Validated: GC-on unit tests (a 50 000-iteration allocating loop keeps
  the heap bounded with the arithmetic result exact — proving live operand-stack
  values are never wrongly freed; and a value reachable only through a native
  Zig local survives a collection that would otherwise sweep it), `threads-test`
  209/209 (incl. `gc-stress/conservative-scan-register.js`), test262 unchanged.
  *Parked-thread collection landed (multi-thread safepoint protocol):* the
  single-threaded guard is lifted — a thread holding the GIL can now collect
  mid-script while its peers are parked. A thread that releases the GIL to block
  publishes a conservative scan range (spilled callee-saved registers + stack
  pointer) into a per-thread `stack_scan.ParkScan` registered with the `Gil`,
  at every GIL park funnel (`Gil.wait`/`waitTimeout`/`yieldIfContended`, covering
  `Condition.wait`/`join`/`Lock`/property-mode `Atomics.wait`, plus the TA-mode
  `Atomics.wait` release). The collector scans its own stack plus every parked
  peer's published range. Soundness: the collector holds the GIL throughout so
  parked peers cannot run (their stacks are frozen); the publish (before GIL
  release) happens-before the scan (after GIL acquire) via the GIL mutex (no
  race, TSan-clean); and a safety net (`Gil.allOthersParked`) makes the collector
  abort unless every peer is parked-and-published, so a missed park site only
  costs a skipped collection, never a freed-live object. Parked peers' JS-level
  state stays precisely rooted via `active_interpreters` (their `Environment` and
  VM `Exec` operand stacks); the conservative parked-stack scan adds coverage for
  `Value`s in a parked thread's native frames. Validated: a GC+threads unit test
  (a peer's object reachable only from its own state survives collection while
  parked) and `threads-test` 209/209 with the GC+threads cases now exercising
  real collection-while-parked (`gc-stress/conservative-scan-register.js`,
  `cve/mc-gc-*`, `gc-stress/zombie-uaf-canary.js`), TSan-clean.
  *Remaining for the FULL deliverable:* keep new cell-owned side buffers behind
  the backing-store helpers and this audit, so future additions do not silently
  fall back to reclaim-at-destroy lifetime. NaN-box `Value` (#7) has landed; the
  M2 incremental-marking + write-barrier mechanism now exists in `zig-gc` (see
  M2 below) and now drives GC-on mid-script collections incrementally; remaining
  maturity work is nursery/generational policy and M3 (drop the GIL, concurrent
  mark behind the barrier).
- **M2 — incremental.** Insertion write barrier; incremental mark + lazy sweep
  to bound pause times. Still GIL'd.
  *Mechanism landed in `zig-gc`* (`startMarking` / `markStep(budget)` /
  `finishMarking` + a Dijkstra insertion `writeBarrier`; cells allocated
  mid-cycle are born black; `collect()` stays byte-for-byte stop-the-world).
  Tested in the collector: a stepped drain matches stop-the-world reachability,
  the barrier saves a cell reparented behind an already-black object, and
  mid-cycle allocations survive. This is the concurrent-marking enabler for M3.
  *Born-grey + finish-root-rescan refinement.* Cells allocated mid-cycle are
  born **grey** (traced), so their *creation-time* field writes (e.g. the ~167
  `proto` inits, initial slots) are caught when traced — the engine only needs
  barriers on **post-creation mutations**, not every initializing store.
  `finishMarking` re-scans roots, covering reachable-but-white cells the mutator
  moved onto a *volatile root* (operand stacks via `gc_execs`, the conservative
  native stack, the active `Environment`, microtask queues) after the start
  snapshot. So the engine barrier set is **heap→heap reference stores** only.
  *Engine barrier coverage — complete and driven.* Incremental marking is sound
  only if every post-creation store of a cell reference into a live GC cell
  shades the target via the insertion barrier (`gc_runtime.barrier` →
  `Heap.writeBarrier`). All such funnels are now barriered:
  - **Object named slots** — `Object.setOwnUnlocked`. ✅
  - **Object accessor maps** — `Object.setAccessor` (get/set). ✅
  - **Object dense elements** — `setDenseElement` / `growDenseElement` /
    `setOrGrowDenseElement` / `replaceDenseElementsAndSetLength` /
    `splicePackedDenseElements` / `setElementAt` / `appendElement`. ✅
  - **Environment bindings** — `Environment.put` (covers `putConst`/`putFnName`/
    `defineLexicalVM`) and `assign` (covers `assignVarVM`). ✅
  - **VM property inline-cache** fast-path slot writes (`vm.zig`). ✅
  - **Promise** reaction appends + settlement `value`; **Generator** async
    request appends. ✅
  - **Map** `set` entry + **Set** `add` key (stores into the live collection). ✅
  - **`proto` reparent** (`setPrototypeOfObject`) + **FinalizationRegistry**
    held value. ✅
  Two collector properties shrink this to heap→heap stores only: mid-cycle
  allocations are **born grey** (so creation-time field writes — the ~167 `proto`
  inits, initial slots, fresh-array builders' `elements.append` — are caught by
  tracing), and `finishMarking` **re-scans roots** (operand stacks via
  `gc_execs`, the conservative native stack, the active environment, microtask
  queues). Shapes are arena-permanent (not GC cells) — no barrier.
  *Driven at safepoints.* `Context.collectMidScript` now steps an incremental
  cycle (`startMarking` → bounded `markStep` per safepoint → `finishMarking`)
  instead of stop-the-world, for GC-on contexts, advancing only while every peer
  is parked-and-published. Explicit `collectGarbage()` stays stop-the-world. The
  arena engine (GC off, incl. test262) is unaffected — the barrier is one null
  check there. **Validated:** the GC-on unit suite runs its mid-script
  collections incrementally (a 50 000-iteration loop with an exact result; a
  long-lived array/`Map`/`Set` mutated under marking with exact final sizes +
  spot-checked values; a parked-peer collection; a reparent-behind-a-black-object
  barrier test); `threads-test` **209/209** with the GC+threads, gc-stress, and
  objectmodel/i03 grow/resize/race/quarantine-across-GC cases now collecting
  incrementally; conformance 33/33; full unit suite leak-clean; TSan clean.
- **M3 — concurrent (Phase 7).** Per-shape/per-object locks (per
  `P7-gil-removal.md` blocker map), drop the GIL, run mark concurrently with
  mutators behind the barrier; safepoint-coordinate sweep. TSan campaign to
  zero unsuppressed races; serial-perf gate; stress amplifiers.
  *Concurrent-marking mechanism landed in `zig-gc`.* The collector now marks on
  its own thread while a mutator runs (the WebKit-Riptide model adapted to one
  GIL-serialized mutator + a dedicated marker): `beginConcurrentMark` (world
  stopped — whiten + grey roots) → the marker loops `concurrentMarkRound`
  (trace grey, fold in the mutator's hand-off) while the mutator executes →
  `finishConcurrentMark` (world stopped — re-scan roots for cells moved onto a
  root mid-mark, drain, ephemeron/weak pass, sweep). The white→grey claim is an
  atomic compare-and-set (`claimMark`) so the marker and the mutator's
  `writeBarrier` never double-push; the barrier and born-grey allocations hand
  cells to the marker through a lock-guarded `barrier_buf`. Three races against a
  live mutator were closed and proven TSan-clean: (1) GC scratch
  (`mark_stack`/`barrier_buf`) moved onto a separate thread-safe `aux` allocator
  (cell slabs stay on the mutator-only `backing`) — the localized answer to
  blocker #1 for the one-mutator model; (2) a bare reference slot the marker
  reads while a mutator writes is accessed with relaxed atomics (a plain mov on
  x86_64/arm64), and collection-backed storage is read under the same per-object
  lock the mutator takes; (3) the abort path and `writeBarrier` now meet under
  the barrier lock, where the mutator re-checks `marking` and `concurrent`
  before appending, so a stale hand-off cannot repopulate `barrier_buf` after
  abort cleared it. `Visitor.concurrent()` lets the binding choose the
  locking path only when marking concurrently, so M1/M2 stay byte-identical.
  *Engine binding wired + validated.* `gc.zig`'s `traceObject` takes
  `property_lock`/`elements_lock` around slot/accessor/element reads and reads
  `proto` atomically when `v.concurrent()`; `Context` installs a thread-safe
  `aux` allocator for GC scratch. An engine-level test
  (`enable_gc concurrent (M3)`) runs a marker thread against real `Object`
  graphs while the mutator appends previously-white objects into a rooted array
  through the engine's `appendElement` funnel (insertion barrier + `elements_lock`):
  every appended cell survives intact and unreferenced garbage is still
  reclaimed, TSan-clean.
  *Weak-collection storage funneled.* WeakMap/WeakSet `weak_entries` and
  FinalizationRegistry `finalization_records` mutation now goes through
  `Object.weakEntry*`/`finRecord*` helpers — each self-contained and guarded by
  `elements_lock`, with the lock never held across the `getOrInsertComputed` /
  cleanup callbacks (which may re-enter the collection).
  *Concurrent weak-collection marking landed (isMarked-based clearing).* The
  marker no longer registers *interior* weak slots (`markWeak(&entry.key)`) that
  point into the growable `weak_entries`/`finalization_records` buffer — a
  concurrent append could reallocate it and dangle a slot registered earlier in
  the cycle (a hazard the read lock did not address; the TSan-slowed marker
  caught it as an alignment fault on a freed entry). Instead the marker doesn't
  read `weak_entries` during the cycle at all (keys are weak; values are
  ephemeron edges marked at the world-stopped finish), and `finalization_records`
  is read only to mark the strong `held` value (by value, under `elements_lock`).
  Weak-key / finalizer-target liveness is then decided at the finish pass by the
  cell's mark bit via `zig-gc` `Heap.isLive(ptr)` (O(1)) in
  `pruneDeadWeakEntries` — behavior-identical to the old markWeak-then-null-then-
  prune for M1/M2 (a dead key/target is exactly an unmarked managed cell), but
  with no registered interior pointer to dangle. Validated: a marker thread races
  a mutator inserting 1,000 WeakMap entries (`enable_gc concurrent (M3)`),
  TSan-clean; WeakRef still uses `markWeak(&o.weak_ref_target)` (a stable field
  address, safe). `WeakRef`/`WeakMap`/`WeakSet`/`FinalizationRegistry` test262
  buckets stay 100%; threads-test 209/209.
  *Production concurrent driver landed (M3, opt-in `concurrent_gc`).* With the
  flag on (requires `enable_gc`, single-mutator — no `enable_threads`),
  `collectMidScript` marks on a dedicated thread *concurrently with the running
  mutator*: it begins a cycle at one safepoint (snapshotting roots incl. the
  native stack while stable), spawns a marker thread that drains grey work + the
  barrier hand-off, and closes the cycle at the next safepoint (stop+join, then
  world-stopped finish — fold born cells, re-scan roots, sweep).
  `finishConcurrentGCIfActive` runs at every quiescent boundary (evaluate /
  evaluateModule exit, collectGarbage, destroy) so a marker never outlives its
  cycle. Default off → the M2 incremental driver and the arena engine are
  byte-identical. The pieces it composes: born-cell deferral
  (`born_concurrent`); O(1) `isManaged`; per-object (`Object`) and
  per-environment (`Environment.binding_lock`) concurrent-trace synchronization;
  the insertion barrier; the thread-safe `aux` scratch allocator. Validated by
  `enable_gc concurrent (M3): the production driver marks on a thread while JS
  runs` — a 4,000-iteration loop allocates objects + per-iter `let` environments
  and reassigns a global while the marker traces (~dozens of begin→marker→finish
  cycles); exact arithmetic, bounded heap, no marker outlives the run,
  **TSan-clean** (`-Dtsan`).
  **Every traced cell type is now concurrent-safe**, by one of three strategies:
  - *Inline under a per-structure lock / atomic slot* — `Object`
    (slots/accessors/elements under their locks, `proto` atomic), `Environment`
    (`binding_lock`), `Promise` (`Promise.lock`, both tracer and mutators).
  - *Creation-immutable* (born-cell handling covers them) — `Function`,
    `BoundFn`, `ModuleNs`.
  - *Deferred to the world-stopped finish* (`Visitor.deferToFinish`) — `Generator`
    (its `exec` is the live VM stack during resume) and `IterHelper`
    (`inner`/`inner_next`/`padding` update around JS callbacks; `inner` is a
    16-byte `?Value`). These are marked so they survive the cycle, but their
    edges are traced at `finishConcurrentMark`, where the mutator is at a
    safepoint and the storage is stable. Validated by `enable_gc concurrent (M3):
    generators and iterator helpers are safe under concurrent marking`
    (400 rounds of resumed generators + map/filter/take chains while the marker
    traces), TSan-clean.

  So the production concurrent driver is sound for **all** workloads under
  `concurrent_gc`.
  *Remaining for M3:*
  1. Drop the GIL for true multi-mutator parallelism (needs thread-safe cell
     allocation + the full per-structure-lock audit).
  3. TSan campaign to zero unsuppressed races; serial-perf gate; stress amplifiers.

## Verification

- `zig-gc` unit tests: toy object graph with cycles, weak edges, finalizer
  queue — collect and assert exact reclamation (precise, so counts are exact).
- zig-js: GC stress tests (allocate-heavy loop bounded heap, explicit
  `collectGarbage` reclamation, `WeakRef` clearing/retention, and
  WeakMap/WeakSet ephemeron behavior, FinalizationRegistry explicit and
  automatic cleanup delivery, and per-owner accounting tests for ArrayBuffer,
  Promise, Environment, and Object backing finalization including dense
  elements, typed-view/Temporal metadata, generator buffers, async-generator
  request queues, and mapped-arguments parameter maps), targeted
  `WeakRef`/`FinalizationRegistry`/`WeakMap` test262 buckets as each weak
  semantic lands, `zig build test262` non-regression at each milestone, TSan on
  M3.

## Open questions

- **Nursery/generational policy for M3:** `Value` is already one NaN-boxed
  8-byte word (blocker #7 closed), so the remaining allocator question is
  whether/when to add a nursery and remembered set before broader no-GIL work.
- **String ownership:** property-name strings are arena-owned today
  (`Shape.transition` dupes into the shape's arena). Decide in M1 whether
  strings become GC cells or stay in a permanent string arena (simpler; keeps
  them out of the trace surface). Default: permanent arena until M3 needs a
  sharded intern table.
- **Generational?** A nursery would cut M1 pause times but adds a remembered
  set + minor/major split. Defer; mark-sweep first, measure, then decide.
