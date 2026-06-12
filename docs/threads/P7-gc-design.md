# Phase 7 GC design: `zig-gc`, a precise non-moving collector

Status: design (pre-implementation). This is the concrete plan for the tracing
GC that gates Phase 7 (GIL removal / Layer C), per the prerequisites audit in
[`P7-gil-removal.md`](P7-gil-removal.md). It also delivers value *before* Phase
7: it makes `WeakRef` / `WeakMap` / `WeakSet` / `FinalizationRegistry` real
(today they are approximations — `value.zig:598-602` literally notes "with no
real GC the target is never reclaimed").

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
| `object` | `value.zig` `Object` | `shape`, `proto`, `ctor_ref`, `proxy_target`, `proxy_handler` (`*Object`); every `Value` in `slots` and `elements`; `accessors` map get/set Values; `prim` (`?Value`); `js_func`/`gen`/`bound`/`promise`/`iter_helper`/`module_ns`/`arg_map_env` (type-erased cells); `array_buffer`/`typed_array`/`data_view`/`temporal`; **weak**: `weak_ref_target`, and WeakMap/WeakSet entries in `elements` |
| `shape` | `shape.zig` `Shape` | `parent`; the `*Shape` values in `transitions` (the keys are property-name strings) |
| `env` | `interpreter.zig:126` `Environment` | every `Value` in `vars`; `parent`; `aliases` (live cross-env bindings); `disposables` |
| `function` | `interpreter.zig:266` `Function` | closure `env`; bound `this`/home-object Values (AST nodes are immutable — see below) |
| `generator` / `boundfn` / `promise` / `iterhelper` / `modulens` / `temporal` | side structs | their captured Values / envs / reaction callbacks |
| `arraybuffer` / `typedarray` / `dataview` | buffer structs | the viewed `*Object` buffer; **finalize** non-shared `ArrayBufferData` byte storage; SAB storage is refcounted (`shared_buffer.zig`) — `finalize` releases the retain |

`private_data: ?*anyopaque` (`value.zig:512`) is **host-owned and opaque** — the
GC never traces it; embedders that stash a cell there must root it themselves
(documented C-API rule).

### Roots

`traceRoots` enumerates, per live `Context`:
- `global_object`, `env`, `root_shape`, `tdz_marker` (`context.zig`)
- the `microtasks` queue (each `Microtask` holds callback + argument Values)
- `exception` slot, `async_waiters`, `js_threads` records
- **the live interpreter's VM value stack + call frames** during execution —
  the transient roots; an executing thread parks at a safepoint with its stack
  in a scannable state.
- `sab_retains` are *not* GC roots — SAB storage is refcounted process-wide;
  the GC only `finalize`s the wrapper's retain.

### The handle problem (C-API)

Embedders hold `JSValueRef`s — pointers to `Boxed` cells (`c_api.zig`) — that
must keep objects alive across calls, but the GC can't see the embedder's
variables. Solution: a **handle table** (JSC "protected values" / V8
`HandleScope` model). `box()` registers the `Boxed` in a per-context handle set
that `traceRoots` walks; `JS*Release`/scope-exit unregisters. This is the one
piece of new C-API bookkeeping M1 adds.

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
  size classes are few.
- **Mark:** explicit mark stack (no recursion — JS graphs are deep). Tri-color:
  white = unmarked, grey = on stack, black = traced.
- **Weak processing:** after the mark stack drains, every registered weak edge
  whose target is still white is cleared; `FinalizationRegistry` cells whose
  held target died queue their cleanup callback as a microtask (fired on the
  owning thread's loop, per spec). `WeakMap`/`WeakSet` drop white-keyed entries.
- **Sweep:** walk blocks; white cells → `finalize` then return to the free
  list; flip black→white for next cycle. Lazy/incremental sweep is an M2 option.
- **Trigger:** `maybeCollect` at the existing `(steps & 1023)` safepoints
  (`interpreter.zig` `eval`, `vm.zig` `execLoop`) and on allocation when the
  heap exceeds a growth threshold (e.g. 2× live-after-last-collect).

## Staging plan

- **M0 — interface, no behavior change.** Land `zig-gc` skeleton + wire a
  `GcAllocator` in zig-js that still bump-allocates from the arena (GC disabled).
  Add the `gc_header` field and `Kind` tags. test262 byte-identical.
- **M1 — single-threaded mark-sweep under the GIL.** Implement `traceRoots` +
  per-`Kind` `trace` + the handle table; enable `collect`. **Deliverable: weak
  refs/finalizers become correct; test262 stays green; long-running contexts
  stop leaking.** This is shippable on its own, independent of Phase 7.
- **M2 — incremental.** Insertion write barrier; incremental mark + lazy sweep
  to bound pause times. Still GIL'd.
- **M3 — concurrent (Phase 7).** Per-shape/per-object locks (per
  `P7-gil-removal.md` blocker map), drop the GIL, run mark concurrently with
  mutators behind the barrier; safepoint-coordinate sweep. TSan campaign to
  zero unsuppressed races; serial-perf gate; stress amplifiers.

## Verification

- `zig-gc` unit tests: toy object graph with cycles, weak edges, finalizer
  queue — collect and assert exact reclamation (precise, so counts are exact).
- zig-js: a GC stress test (allocate-heavy loop bounded heap), the existing
  `WeakRef`/`FinalizationRegistry`/`WeakMap` test262 buckets now asserting real
  collection, `zig build test262` non-regression at each milestone, TSan on M3.

## Open questions

- **`Value` width for M3:** NaN-box to 8 bytes so a slot is one atomic word
  (blocker #7 in the audit). Independent of M1; sequence before M3.
- **String ownership:** property-name strings are arena-owned today
  (`Shape.transition` dupes into the shape's arena). Decide in M1 whether
  strings become GC cells or stay in a permanent string arena (simpler; keeps
  them out of the trace surface). Default: permanent arena until M3 needs a
  sharded intern table.
- **Generational?** A nursery would cut M1 pause times but adds a remembered
  set + minor/major split. Defer; mark-sweep first, measure, then decide.
