# Phase 7: GIL removal (Layer C) — prerequisites audit

Status: charter + prerequisites note (Phase 7 is **not scheduled** — it is
blocked on a real tracing GC, which is tier-5 engine work). Per the issue:
"Record the prerequisites now so earlier phases don't paint us into corners."
This note audits the *current* architecture (grounded in `src/` as of this
writing) so the eventual GC + ungil work has an accurate blocker map rather
than discovering each one by crashing.

Reference design for the end state: Pizlo, "Concurrent JavaScript: It Can
Work!" (https://webkit.org/blog/7846/) — but it presupposes a GC, which is the
gating prerequisite below.

## Where Layer B leaves us

Phases 1–6 ship a **GIL'd** shared heap (`src/gil.zig`): exactly one thread
runs JS at a time, so arena allocation, remaining direct element side doors,
and every existing invariant are safe even before their final per-structure
synchronization exists. Threads interleave only at the step
checkpoints (`(steps & 1023) == 0` in `src/interpreter.zig` `eval` and
`src/vm.zig` `execLoop`, both calling `Gil.yieldIfContended`) and release the
lock at every blocking point. Removing the GIL means every one of the
structures the GIL currently protects needs its own correctness story. The
shape transition **map** and ordinary named-property helper paths now have that
first story: `Shape.transition` locks the per-shape transition table, and
`Object.property_lock` serializes helper-routed shape, slot, accessor,
attribute, and key-order state.

## The gating prerequisite: a tracing GC

The arena model cannot express cross-thread object lifetimes. `Context` owns one
`arena_state: *std.heap.ArenaAllocator` (`src/context.zig:22`); everything
(values, objects, strings, AST, shapes, environments) lives there until
`Context.destroy()` frees it en masse (`arena_state.deinit()`). There is no
per-object reclamation. A shared parallel heap needs objects whose lifetime
spans agents and is reclaimed by tracing — `SharedBufferStorage`
(`src/shared_buffer.zig`) carries *bytes*, not object identity, which is why it
was sufficient for Layer A but cannot back shared *objects*. **No ungil work
should begin before a tracing GC with safepoints replaces the arena.** The step
checkpoints above are the natural safepoint sites — they already exist and are
polled in both engines.

**Progress:** the GC (M1, opt-in) now collects *mid-script* at those checkpoints
for single-threaded execution — conservative native-stack + register scanning
(`src/stack_scan.zig`) roots the tree-walker's live `Value` locals and active VM
`Exec` operand stacks are registered as precise roots (see
[`P7-gc-design.md`](P7-gc-design.md)). The remaining safepoint work for Layer C
is scanning a *parked* thread's native stack while another thread collects (the
multi-thread safepoint protocol), after which the GIL guard on mid-script
collection can be lifted.

## Blocker map (each is GIL-protected today)

| # | Structure | Site | Tear without the GIL | Fix direction |
|---|---|---|---|---|
| 1 | Per-context arena | `context.zig:22`, alloc via `arena()` | `ArenaAllocator` + backing GPA are not thread-safe; concurrent alloc corrupts free lists | GC-managed heap, or per-thread nurseries with a shared old space |
| 2 | **Shape transition map** | `shape.zig` `transitions: StringHashMapUnmanaged(*Shape)` plus per-shape `transition_lock`, mutated only in `Shape.transition()` | **Closed for the map itself:** `Shape.transition` locks the table around lookup/allocation/publish, so two mutators adding the same property to one parent shape converge on one child instead of corrupting/diverging. Arena allocation remains covered by #1 until the shared heap/nursery story is complete. | Keep all transition writes behind `Shape.transition`; later Layer-C work may swap the lock for a lock-free table only with equivalent convergence tests. |
| 3 | Object shape pointer | `value.zig` `Object.property_lock`, `shape`, `setOwnUnlocked`, `deleteNamedDataOwn`; VM property ICs in `vm.zig` | **Closed for ordinary named properties:** `Object.setOwn` / `getOwn` / `deleteNamedDataOwn` and VM plain-property IC reads/writes hold `property_lock` while reading, publishing, or rebuilding the shape pointer. | Keep all ordinary named-property shape publication behind `property_lock`; later Layer-C work may replace this with an atomic shape slot only if it preserves publish ordering and delete/rebuild convergence. |
| 4 | Object slot storage | `value.zig` `Object.property_lock`, `slots: ArrayListUnmanaged(Value)`, `setOwnUnlocked`, `deleteNamedDataOwn`; VM property ICs in `vm.zig` | **Closed for ordinary named properties:** slot append, same-slot updates, and delete/rebuild compaction through `Object` helpers and VM plain-property ICs are serialized by `property_lock`. Dense element storage and direct array/collection element mutations remain separate blockers. | Keep slot-vector mutation behind `property_lock`; move any future direct slot side door into `Object` before removing the GIL. |
| 5 | Object element storage | `value.zig` `Object.elements_lock`, `elements: ArrayListUnmanaged(Value)`; dense-array, Map/Set helper, and cursor paths in `interpreter.zig` | **Partially closed:** `Object` now has an element-store lock. Central dense-array get/set/delete/length, packed reverse/sort/splice fast paths, non-callback Map/Set helpers, Map/Set `forEach` per-slot snapshots, native Set helper scans, and Map/Set cursors use it before reading or mutating element-backed storage. Remaining direct tuple/internal `elements` side doors are still GIL-protected. | Continue moving every direct `elements.items` read/write/append/clear behind `Object.elements_lock` or a narrower equivalent, and do not hold it across JS callbacks. |
| 6 | Accessor / attribute maps | `value.zig` `Object.property_lock`, `setAccessor`/`setAttr` `StringHashMapUnmanaged` puts, `deleteAccessorOwn` removes | **Closed for ordinary named properties:** accessor and attribute map lookup/mutation/removal through `Object` helpers is serialized by `property_lock`. | Keep accessor/attribute state behind `property_lock`; add tests for any future descriptor side door before ungil. |
| 7 | **Value width** | `value.zig:888` `Value = union(enum)` — ~24 bytes (slice payload + tag), **not pointer-width** | A 24-byte slot cannot be read/written atomically; readers tear against writers | NaN-box `Value` to 8 bytes so a slot is a single atomic word — a design input *before* any ungil bring-up |
| 8 | Strings | `value.zig` `string: []const u8` (uninterned arena slices); `jsstring.zig` atomic `retain`/`release` refcount | No shared intern table exists to race on (good). FFI `JSStringRef` retain/release is now atomic; arena slices still have context lifetime. | Keep uninterned until Layer C chooses a sharded intern table; continue avoiding pointer-identity assumptions for equal strings. |
| 9 | Promise settlement and reactions | `promise.zig` `Promise.lock`, `state`, `value`, `on_fulfill`, `on_reject`; `gc.zig` `tracePromise`; `interpreter.zig` `awaitValue` | **Closed for per-promise state:** resolve/reject/then registration, snapshot reads, async thenable job guards, and GC tracing lock the Promise before reading or moving settlement/reaction state. Microtask queues and async waiter arrays remain separate GIL-protected host state. | Keep all Promise state reads through `promise.snapshot`/`isPending` or under `Promise.lock`; do not treat microtask queue mutation as ungil-ready until the per-thread event-loop story is explicit. |

## Design inputs to lock in now (so earlier phases don't foreclose them)

- **Keep `Value` shrinkable.** Nothing should depend on the union's current
  layout or 24-byte size; NaN-boxing must remain a drop-in (#7). The C-API
  already hides `Value` behind an opaque `Boxed` pointer (`c_api.zig`), so the
  ABI is insulated.
- **Keep strings uninterned.** No code should assume pointer-identity of equal
  strings; equality is by bytes (#8). This preserves the freedom to add a
  sharded intern table only in Layer C. `JSStringRef` lifecycle is already
  thread-safe: `src/jsstring.zig` uses an atomic refcount, so C-API strings can
  be retained and released from any thread while remaining immutable.
- **Keep shape transitions funnel-shaped.** All transitions go through
  `Shape.transition` (`shape.zig`), whose per-shape lock is now the
  synchronization point for the transition table (#2). Do not add side doors
  that mutate `transitions` directly.
- **Keep object named properties funnel-shaped.** Ordinary named property
  helper paths now synchronize on `Object.property_lock` (`value.zig`), and the
  VM's plain-property inline caches take that lock before touching `shape` or
  `slots`. Named data/accessor delete and shape+slot rebuild also live behind
  the same lock. Do not add new direct mutations of `shape`, `slots`,
  `accessors`, `attrs`, or `key_order`.
- **Keep Promise state funnel-shaped.** Promise settlement and reaction-list
  mutation now synchronize on `Promise.lock` (`promise.zig`), and `awaitValue`
  observes settled promises through `promise.snapshot`. Do not add direct reads
  of `Promise.state` or `Promise.value` outside `promise.zig`/locked GC
  tracing.
- **Keep element storage funnel-shaped.** `Object.elements_lock` is the
  synchronization point for indexed storage. Dense-array helper paths, Map/Set
  helper paths, and cursor paths already use it, and callback paths must
  snapshot one slot or one key list before invoking JS. Do not add new direct
  `elements.items` access on shared data paths; finish moving internal engine
  tuples behind helpers.
- **Keep the safepoint checkpoints as the only interleave points.** Both
  engines already poll at `(steps & 1023) == 0`; a GC needs exactly these as
  safepoints. Do not add heap mutation paths that can run for an unbounded
  number of steps without hitting a checkpoint.

## Bring-up ladder (when a GC lands)

Mirror PR-249's phase-2 ladder, already proven for Layer B:
1. Per-shape + per-object locks (coarse), GIL still present, prove correctness.
2. Drop the GIL; run the vendored corpus + test262 SAB/Atomics under **real**
   parallelism with TSan; drive unsuppressed races to zero.
3. Serial-perf gate: single-thread throughput must not regress materially.
4. Stress amplifiers (transition storms, property-add races, shared-TA atomics
   storms) flake-free in CI.

## Action

No code change in this phase. This note is the prerequisite record; the next
concrete step toward Layer C is the **tracing GC** (a tier-5 item independent
of the threading API), after which #2/#3/#7 are the critical path.
