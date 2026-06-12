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
runs JS at a time, so arena allocation, shape transitions, and every existing
invariant are safe with zero per-structure synchronization. Threads interleave
only at the step checkpoints (`(steps & 1023) == 0` in `src/interpreter.zig`
`eval` and `src/vm.zig` `execLoop`, both calling `Gil.yieldIfContended`) and
release the lock at every blocking point. Removing the GIL means every one of
the structures the GIL currently protects needs its own correctness story.

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

## Blocker map (each is GIL-protected today)

| # | Structure | Site | Tear without the GIL | Fix direction |
|---|---|---|---|---|
| 1 | Per-context arena | `context.zig:22`, alloc via `arena()` | `ArenaAllocator` + backing GPA are not thread-safe; concurrent alloc corrupts free lists | GC-managed heap, or per-thread nurseries with a shared old space |
| 2 | **Shape transition map** | `shape.zig:29` `transitions: StringHashMapUnmanaged(*Shape)`, mutated in `transition()` `shape.zig:56` (`transitions.put`) | Two mutators adding the same property to one parent shape both miss the `get`, both `put` → divergent child shapes, broken monomorphism, corrupt map | Per-shape lock on the transition map, or a lock-free transition table; this is the *first* thing two mutators tear |
| 3 | Object shape pointer | `value.zig:832` `self.shape = child` in `setOwn` | Non-atomic pointer store; a concurrent reader can see a torn/stale shape on weakly-ordered ISAs | Atomic shape slot + publish-after-populate ordering |
| 4 | Object slot storage | `value.zig:434` `slots: ArrayListUnmanaged(Value)`, appended in `setOwn` (`value.zig:831`) | `append` reallocates; a concurrent reader dereferences a freed buffer | Per-object lock, or stable-segmented slot vectors that never move |
| 5 | Object element storage | `elements: ArrayListUnmanaged(Value)` (Array push) | Same realloc-move hazard as slots | Same as #4 |
| 6 | Accessor / attribute maps | `setAccessor`/`setAttr` `StringHashMapUnmanaged` puts | HashMap not thread-safe | Fold under the per-object lock |
| 7 | **Value width** | `value.zig:888` `Value = union(enum)` — ~24 bytes (slice payload + tag), **not pointer-width** | A 24-byte slot cannot be read/written atomically; readers tear against writers | NaN-box `Value` to 8 bytes so a slot is a single atomic word — a design input *before* any ungil bring-up |
| 8 | Strings | `value.zig` `string: []const u8` (uninterned arena slices); `jsstring.zig` `retain`/`release` non-atomic refcount | No shared intern table exists to race on (good) — but the FFI refcount is non-atomic, and arena slices have arena lifetime | Keep uninterned until Layer C chooses a sharded intern table; make the `JsString` refcount atomic |

## Design inputs to lock in now (so earlier phases don't foreclose them)

- **Keep `Value` shrinkable.** Nothing should depend on the union's current
  layout or 24-byte size; NaN-boxing must remain a drop-in (#7). The C-API
  already hides `Value` behind an opaque `Boxed` pointer (`c_api.zig`), so the
  ABI is insulated.
- **Keep strings uninterned.** No code should assume pointer-identity of equal
  strings; equality is by bytes (#8). This preserves the freedom to add a
  sharded intern table only in Layer C.
- **Keep shape transitions funnel-shaped.** All transitions go through
  `Shape.transition` (`shape.zig:56`) — a single chokepoint to wrap in a lock
  or swap for a lock-free table (#2). Do not add side doors that mutate
  `transitions` directly.
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
