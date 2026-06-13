# Phase 7 GC design: `zig-gc`, a precise non-moving collector

Status: M1 foundation implemented behind `Context.Options.enable_gc`; arbitrary
mid-script collection and Layer-C GIL removal remain future work. This is the
concrete plan for the tracing GC that gates Phase 7 (GIL removal / Layer C),
per the prerequisites audit in [`P7-gil-removal.md`](P7-gil-removal.md). It also
delivers value *before* Phase 7: opt-in contexts already reclaim unreachable GC
cells at quiescent points and clear `WeakRef` targets when their referent dies.
`WeakMap` / `WeakSet` weak-key cleanup and `FinalizationRegistry` cleanup jobs
remain follow-on work.

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
  **42,745/47,930, 0 crashes**, conformance 33/33, threads 29/29, and a
  leak-checked `enable_gc` unit test (object-heavy run + clean teardown).
  *Uniform Object heap landed:* all ~171 `value.Object` allocation sites across
  8 files now go through `gc_mod.allocObj(arena)`, which routes via a
  **thread-local active heap** (`setActiveHeap`, set/restored in `createWith`
  for intrinsics and `evaluate`/`evaluateModule` for execution) — so every site
  funnels through the GC when on, the arena when off, *without* threading the
  heap pointer through hundreds of signatures. Intrinsics (`installGlobals`) and
  user objects are all GC cells now. Validated: flag off byte-identical; flag on
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
  unit suite leak-checked. (Cell *sub-allocations* — `Object.slots`/`elements`,
  `Environment.vars`, promise reaction lists — stay arena; they are never passed
  to `mark`, so no tracing hazard, only a reclaim-at-teardown-vs-on-collect
  difference, addressed after mid-run lands.)
  *Quiescent collection landed — the GC reclaims now.* `Context.collectGarbage()`
  runs a precise mark-sweep, called automatically at the top of `evaluate`
  (before the interpreter starts, so the Zig stack holds no live `Value`s and
  the `Context` roots `gc.zig`'s binding traces are complete) and callable
  directly by embedders at any quiescent point. Guarded to skip while threads or
  a module graph hold objects the root set doesn't yet enumerate. Validated:
  flag off byte-identical; flag on full test262 **42,771/47,930, 0 crashes,
  host-fail 0** (collection runs on every one of ~24k contexts — proof the root
  set is complete, since a missed root would free a live intrinsic and crash);
  conformance 33/33; whole unit suite leak-checked *with collection on*; and a
  reclamation test (`collectGarbage` frees 500 unreachable temporaries while a
  `globalThis`-retained graph survives intact). Note: test262 doesn't *observe*
  GC (no `$262.gc`; one `evaluate` per test), so the conformance number is
  unchanged by design — the win is operational (memory reclamation for
  long-running contexts).
  *C-API handle table landed:* `box()` registers each `Boxed` (`JSValueRef`) on
  `Context.c_api_handles` when the GC is on (`*Boxed` aliases `*Value`), and
  `traceRoots` marks them — so an embedder-held `JSValueRef` survives collection.
  `JSGarbageCollect` is now a **real** precise mark-sweep (was a documented
  no-op) when the context opts into the GC; the default arena-backed
  `JSGlobalContextCreate` is unchanged, so it stays a no-op there. Validated by a
  C-API test (`JSGarbageCollect` reclaims 500 garbage objects while a held
  `JSValueRef` keeps its object — `tag === 123` after collection); conformance
  33/33, threads 29/29, full unit suite leak-checked. (No `JSValueUnprotect`
  yet, so a boxed object is pinned for the context's life — conservative but
  sound.)
  *WeakRef weak edges landed:* `Object` now keeps a separate WeakRef brand and
  nullable target object slot; `gc.zig` registers that slot with
  `Visitor.markWeak`, so a collection clears the slot before sweeping an
  otherwise-unreachable referent. `WeakRef.prototype.deref()` now returns
  `undefined` after collection while continuing to brand-check the WeakRef
  object itself. Validated by GC-enabled tests for cleared weak-only targets and
  strongly reachable targets that survive collection.
  *Remaining for the FULL deliverable:* (a) **arbitrary mid-script collection**
  needs conservative stack scanning (a tree-walker holds live `Value`s as Zig
  locals/registers a precise GC can't see) — the quiescent points avoid this; a
  Boehm-style stack scan with register spill would generalize it. (b) migrate
  cell sub-allocations (`slots`/`elements`/`vars`/reaction lists) to gpa so
  `finalize` frees them on collect — turning "reclaims cells" into "reclaims
  everything" (today sub-allocations are reclaimed at teardown, so a collected
  object's backing buffers persist until `destroy`). (c) WeakMap/WeakSet need
  typed weak-key table cleanup, and FinalizationRegistry still needs cleanup-job
  scheduling.
- **M2 — incremental.** Insertion write barrier; incremental mark + lazy sweep
  to bound pause times. Still GIL'd.
- **M3 — concurrent (Phase 7).** Per-shape/per-object locks (per
  `P7-gil-removal.md` blocker map), drop the GIL, run mark concurrently with
  mutators behind the barrier; safepoint-coordinate sweep. TSan campaign to
  zero unsuppressed races; serial-perf gate; stress amplifiers.

## Verification

- `zig-gc` unit tests: toy object graph with cycles, weak edges, finalizer
  queue — collect and assert exact reclamation (precise, so counts are exact).
- zig-js: GC stress tests (allocate-heavy loop bounded heap, explicit
  `collectGarbage` reclamation, and `WeakRef` clearing/retention), targeted
  `WeakRef`/`FinalizationRegistry`/`WeakMap` test262 buckets as each weak
  semantic lands, `zig build test262` non-regression at each milestone, TSan on
  M3.

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
