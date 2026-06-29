# Bindings audit — process-global mutable state

**Phase 0 deliverable of the multithreading plan
([zig-utils/zig-js#1](https://github.com/zig-utils/zig-js/issues/1)), modeled on
WebKit PR-249's "binding audit".**

## The contract

This document enumerates **every piece of process-global (or otherwise
thread-singular) mutable state** in the engine, and gives each one a ruling for
the multithreaded bring-up:

| Ruling | Meaning |
|---|---|
| **per-thread** | Must become per-agent / per-thread state (instance field, threadlocal, or per-agent record). A second thread gets its own copy. |
| **locked** | Will remain shared and be guarded by a mutex or replaced with atomics. |
| **refused** | Must never be reachable from a second thread; the entry explains why that is structurally guaranteed. |

**No new process-global mutable state may land without a ruling added here.**
Reviewers and CI enforce this (issue #1 invariant: *"No new process-global
mutable state without a written ruling (per-thread / locked / refused) in
`docs/threads/bindings.md`"*). If you add a `var` at file or container scope —
or a `threadlocal` — your PR must add a row to the appropriate table below.
Phase 2c executes this document as its checklist.

Line numbers below were refreshed on 2026-06-28. They will drift; re-measure
with the commands in [How to re-run this audit](#how-to-re-run-this-audit)
before acting on one.

---

## Engine: `src/builtins.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `math_prng` | `src/builtins.zig:638` | `threadlocal std.Random.DefaultPrng` seeded with a fixed constant; mutated on every `Math.random()` call. | **per-thread** | Completed: this is threadlocal, so agents/workers/threads never race the PRNG state. A future quality pass may seed per context instead of using the fixed deterministic seed. |

## Engine: `src/interpreter.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `symbol_counter` | `src/interpreter.zig:26365` | `std.atomic.Value(usize)` — monotonic id for unique `Symbol` property-key encodings (`"\x00s{d}"`). | **locked** | Completed: `makeSymbolObj` uses atomic `fetchAdd`, so cross-agent and shared-realm symbol creation cannot collide. |

## Engine: `src/agent.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `io_threaded` / `io_state` | `src/agent.zig:26-27` | Lazy process-wide `std.Io.Threaded` bootstrap for mutexes, conditions, sleeping, and timestamps. | **locked** | `io_state` is atomic and publishes the initialized `io_threaded` before use. One Io backend is intentionally shared process-wide. |
| `group` / `group_used` | `src/agent.zig:66-70` | The `$262.agent` group: agent records, reports, broadcast storage/generation, and teardown state. | **locked** | All group fields are guarded by `group.mutex`; `group_used` is an atomic fast-path guard for reset/takeReport when no agent API was touched. |
| `t_agent` | `src/agent.zig:76` | Threadlocal pointer to the current spawned `$262.agent` record. | **per-thread** | Used by `canBlock`, broadcast receive, and report paths. Main/foreign threads see null. |
| `mono_base` | `src/agent.zig:247` | Atomic monotonic-clock zero point for `$262.agent.monotonicNow()`. | **locked** | Initialized with compare-exchange; reads are atomic. |
| `waiters`, `waiters_mutex`, `waiters_cond`, `waiters_used` | `src/agent.zig:288-293` | Typed-array `Atomics.wait` / `notify` / `waitAsync` waiter table. | **locked** | The table is guarded by `waiters_mutex`; `waiters_cond` wakes async harvesters; `waiters_used` is an atomic fast-path guard. |
| `live_agents` | `src/agent.zig:296` | Atomic count of currently running spawned agents. | **locked** | Lets async waiter harvesting avoid waiting forever when no notifier can still exist. |
| `async_id_counter` | `src/agent.zig:399` | Atomic id source for typed-array `Atomics.waitAsync` tickets. | **locked** | Uses atomic `fetchAdd`, unique process-wide. |

## Engine: `src/gc.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `active_heap` | `src/gc.zig:244` | Threadlocal pointer to the currently active GC heap used by allocation shims. | **per-thread** | `Context.createWith` and evaluation set/restore it around heap-cell allocation. Threadlocal keeps nested/parallel contexts isolated. |

## Engine: `src/gil.zig` / `src/jsthread.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `t_current` | `src/jsthread.zig:47` | Threadlocal pointer to the current shared-realm `ThreadRecord`. | **per-thread** | Drives `Thread.current`, self-join detection, and per-thread identity. |
| `Gil.tasks` / `tasks_head` / `tasks_queued` | `src/gil.zig:28` | Per-realm run-loop task queue for `Lock.asyncHold` grant delivery. | **locked + atomic empty check** | Enqueue/dequeue mutate the queue under `Gil.api_lock`; empty pump/quiescence checks use `tasks_queued`. `tasks_head` gives FIFO dequeue without front-shifting the arena-backed task list, and task pumps copy bounded FIFO bursts under the lock before running grants outside it. GC traces queued `HoldJob` callback/promise roots through `jsthread.traceGilTaskRoots`. |
| `LockRecord.pending` / `pending_head` | `src/jsthread.zig:528` | Per-lock FIFO of queued `Lock.asyncHold` / async condition reacquire grants. | **locked** | Protected by `LockRecord.mutex` with sync lock state. `pending_head` gives FIFO grant selection without front-shifting the arena-backed pending list; rare requeue-at-front uses the same helper. GC traces pending `HoldJob` callback/promise roots through the owning Lock object's native private data, and job creation fires insertion barriers for active marks. |
| `Gil.prop_waiters` / `Gil.prop_async` / `Gil.prop_mutex` | `src/gil.zig:31-40` | Per-realm property-mode `Atomics.wait` and `waitAsync` waiter queues plus their table mutex. | **locked** | Protected by `Gil.prop_mutex`, not process-global; independent `enable_threads` contexts cannot race or cross-notify each other. Sync wait and waitAsync revalidate the property value under this mutex immediately before enqueueing, closing the store+notify lost-wakeup window; async ticket settlement collects under the mutex and resolves promises after releasing it. |
| `CondRecord.queue` / `CondRecord.mutex` | `src/jsthread.zig:392-399` | Per-condition FIFO for sync and async `Condition` waiters. | **locked** | Protected by `CondRecord.mutex`; sync wait registers before releasing the associated `Lock`, and `notify` marks/broadcasts under the same mutex. Async waiters hand off to the `Lock.asyncHold` grant path outside JS execution. GC traces async waiter promises through the Condition object's native private data. |

## Engine: `src/c_api.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `gpa` | `src/c_api.zig:40` | `const gpa = std.heap.page_allocator` — backs every C-API-created `Context` and `JsString`. | **locked** | Immutable binding; `page_allocator` is internally synchronized, so concurrent `JSGlobalContextCreate` / `JSStringCreateWithUTF8CString` from different threads are safe. `JSStringRef` retain/release uses an atomic refcount and is thread-safe. |
| `Context.c_api_handles` | `src/context.zig:109` | Per-context counted `JSValueProtect` roots for GC-enabled C-API handles. | **per-thread** | Owned by the `Context` and mutated only through context-affine C-API calls. `JSValueRef`/`JSObjectRef` remain raw context-affine wrappers; `JSValueProtect` only controls GC reachability, not cross-thread access. |

No other mutable globals: the `var buf` / `var exception` hits at :452/:465/:497
are locals inside `test` blocks.

## Engine: all other `src/*.zig`

A file-scope scan found no other current `src/` mutable globals beyond the
rows above. Specifically verified clean: `ast.zig`, `bytecode.zig`,
`cldr_*.zig`, `compiler.zig`, `context.zig`, `jsstring.zig` (no string-interning
table exists — strings live in context arenas), `lexer.zig`,
`numbering_systems.zig` (its `var arr` is inside a `comptime` block producing a
`const`), `parser.zig` (reentrant, no statics), `promise.zig`, `root.zig`,
`shape.zig`, `shared_buffer.zig`, `structured_clone.zig`, `unicode_case*.zig`,
`value.zig`, `vm.zig`, and `worker.zig`.

### `comptime` / `const` tables

All CLDR data (`cldr_locale.zig`, `cldr_numbers.zig`, `cldr_plurals.zig`,
`cldr_timedata.zig`, `cldr_tzalias.zig`), Unicode tables
(`unicode_case_data.zig`), and `numbering_systems.zig` tables are
`const`/comptime-built immutable data: **shared read-only, safe from any number
of threads, not enumerated further.** The same applies to
`zig-regex`'s `unicode_gc_data.zig` / `unicode_prop_data.zig`.

---

## Per-Context / per-Interpreter state that is thread-relevant

These are **not** process globals today — they are instance fields — but each is
exactly the kind of VM-singular state PR-249's audit existed to catch, so they
get explicit rulings here to make this the one-stop checklist. Non-threaded
contexts remain owner-thread-affine. Threaded contexts created with
`Context.createWith(.{ .enable_threads = true })` run shared-realm `Thread`s in
parallel by default, so any state reachable from those threads must either be
per-thread/per-interpreter, guarded by its own lock, or deliberately refused.
The `.gil = true` fallback keeps the same API behind the serialized execution
path, but these rulings are written for the no-GIL default.

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `Context.exception` / `Interpreter.exception` | `src/context.zig`, `src/interpreter.zig` | The C-API/top-level pending exception slot and each active evaluator's thrown value. | **per-thread at execution boundaries** | Active execution carries exceptions in the per-`Interpreter` / per-thread evaluator state. The context slot is only the boundary handoff for the owning host call after evaluation/linking unwinds; it must not be used as shared in-flight exception state. |
| `Context.microtasks` / per-`ThreadRecord` queues | `src/context.zig`, `src/jsthread.zig`, `src/interpreter.zig` | Promise-reaction queues: the realm queue plus per-running-thread queues used by shared-realm `Thread`s. | **locked / per-thread** | Each running JS thread drains its own queue. Cross-thread handoff cases, such as `asyncJoin` settlement and abandoned worker queues, transfer into the realm queue under `Context.microtask_lock` in the no-GIL path. The lock only covers queue mutation; jobs run outside it. |
| `Promise.lock` + settlement/reaction state | `src/promise.zig`, traced by `src/gc.zig` | Per-promise `state`, `value`, fulfill/reject reaction lists, and GC tracing of those fields. | **locked** | `resolve`/`reject` settle through a locked move of reaction lists, `performThen` registers under the same lock, `awaitValue` reads through `promise.snapshot`, and `tracePromise` locks before marking. The microtask queue itself remains `Context.microtasks` / per-thread. |
| `Context.print_buffer` | `src/context.zig` | Test-shell `print()` output accumulator, shared with each `Interpreter`. | **refused for concurrent no-GIL use** | Non-threaded contexts are owner-affine, and GIL-mode shared-realm contexts serialize `print()` through the GIL. `print()` is a test-shell helper, not a stable embedder API or synchronization primitive. Do not make concurrent no-GIL `print()` a supported behavior without adding an explicit lock or per-thread buffer transfer. |
| `Context.root_shape` + `Shape.transitions` | `src/context.zig`, `src/shape.zig` | The per-context shape tree; transition maps (`StringHashMapUnmanaged(*Shape)`) are mutated on property addition. | **locked** | One shape tree per context. `Shape.transition` owns all transition-map mutation and holds the per-shape `transition_lock` around lookup/allocation/publish, so duplicate same-name transitions converge even when callers race. Object shape-pointer publication, named slots, accessors, attrs, and key-order metadata are protected by `Object.property_lock`; indexed storage is protected separately by `Object.elements_lock`. |
| `Object.property_lock` + named property metadata | `src/value.zig`, `src/vm.zig` | Per-object lock for ordinary named-property shape publication, slot vector updates, accessor maps, attribute maps, creation-order metadata, and named-property delete/rebuild. | **locked** | `Object.getOwn` / `setOwn` / `deleteNamedDataOwn` / `getAccessor` / `setAccessor` / `deleteAccessorOwn` / `getAttr` / `setAttr` / `ownKeys` serialize through `property_lock`, and the VM's plain-property inline caches lock before reading/writing `shape` and `slots`. Indexed storage is tracked separately under `Object.elements_lock`. |
| `Object.elements_lock` + element storage | `src/value.zig`, `src/interpreter.zig` | Per-object lock for `elements: ArrayListUnmanaged(Value)`, used by arrays, Map/Set data, iterator cursor cells, and engine tuples. | **locked; residual direct paths tracked** | `Object.lockElements` / `appendElement` / `elementAt` / `setElementAt` / dense-array helpers are the synchronization funnel. Central dense-array get/set/delete/length, packed reverse/sort/splice fast paths, Map/Set helper methods, Map/Set `forEach` slot snapshots, native Set helper scans, and Map/Set cursors use it. Dense/indexed helper writes also publish `indexed_own_seen`, a conservative cross-thread marker used by prototype-chain indexed-store guards in no-GIL mode. Continue migrating any remaining internal tuple/array side doors before making them reachable from shared-realm parallel JS. Never hold this lock across a JS callback. |
| `Context.mod_cache` (+ `mod_host`, `script_referrer`) | `src/context.zig` | Module-graph cache for `evaluateModule` / dynamic `import()`; host-script dynamic import may point at a host-owned map, and `evaluateModule` points at a stack-local map only during the call. | **per-thread** | Per-context, mutated only inside the owner thread's `evaluate*` calls. The GC traces active caches while they are installed, and `evaluateModule` clears its transient cache/host pointers before returning. The stack-local backing remains unreachable from other threads. |
| `Context.TestingOptions.main_can_block` / `.max_js_threads` | `src/context.zig` | Host/test knobs replacing the old process-global conformance controls. | **per-context** | `main_can_block` models the VM's `[[CanBlock]]` bit; `max_js_threads` caps live shared-realm `Thread` records. Runners pass them through `Context.TestingOptions` via `createWithTestingOptions`, keeping them out of stable `Context.Options` while concurrent contexts avoid process-global knob races. |
| `Interpreter.re_legacy` | field `src/interpreter.zig:394`, struct `:323` | Annex-B `RegExp.$1`/`lastMatch`/… legacy match state, updated on every successful regex match (`:20540`). | **per-thread** | Already a per-`Interpreter` instance field — **confirmed and ruled done** (Phase 2c checklist item). Each agent's interpreter has its own. No static regex scratch exists on the zig-js side. |
| `Interpreter.depth` / `Interpreter.steps` | `src/interpreter.zig` | Call-depth and step counters. The bytecode VM increments the same per-`Interpreter` counters through its `vm` parameter. | **per-thread** | Each active evaluation/thread owns its `Interpreter`, so recursion and step limits are per executing JS thread rather than per shared `Context`. Keep future VM entry points on this per-interpreter path. |
| `value.ArrayBufferData` | `src/value.zig` | ArrayBuffer metadata and backing bytes. SharedArrayBuffer wrappers point at `SharedBufferStorage`; non-shared resizable buffers own `local_data`. | **locked** | Shared buffers use `SharedBufferStorage` with atomic refcount and atomic grow-only length. Non-shared `ArrayBufferData` now has `lock`; `ArrayBuffer.prototype.resize` holds it while copying/publishing replacement `local_data`, and typed-array read/write helpers hold it while borrowing the live slice. This closes the no-GIL resize-vs-view UAF window. |
| `shared_buffer.RetainList` | `src/shared_buffer.zig` | Per-realm list of retained `SharedBufferStorage` references released at teardown/finalization. | **locked** | `track`, `releaseTracked`, and `deinit` hold the list mutex around `ArrayListUnmanaged` mutation, while `SharedBufferStorage` lifetime itself remains atomic-refcounted. |
| `ThreadLocal` value map | `src/jsthread.zig` | Per-`ThreadLocal` map from JS thread id to stored `Value`. | **locked** | `ThreadLocal.value` get/set uses `TLRecord.map_lock`; GC traces stored object values through the ThreadLocal object's native private data so per-thread values are not hidden from collection. |

---

## Hosts: `conformance/*.zig` (not engine code)

The conformance binaries are hosts, not the engine; their globals can never be
linked into a library consumer. Ruled anyway for completeness.

| Symbol | Location | What it is | Ruling | Notes |
|---|---|---|---|---|
| `failed`, `fail_msg` | `conformance/runner.zig:19-20` | Smoke-harness assertion state, reset before each case ("Single-threaded harness state" per its own comment). | **refused** | The runner creates one `Context` on the main thread and never spawns threads; the native `assert` writing these is only installed into that context. If the runner ever drives multi-threaded tests, these must move into a per-case struct first. |
| `g_mod_io`, `g_mod_gpa` | `conformance/diag.zig:158-159` | Module-load hooks' io/allocator for the single-file diagnostic CLI. | **refused** | Set once at startup of a strictly single-threaded one-shot CLI before any evaluation; no thread is ever created. |
| — | `conformance/test262.zig` | No file/container-scope mutable state. | n/a | Parallelism here is multi-**process** workers (crash isolation), orthogonal to in-engine threads. |

---

## Path dependency: `../zig-regex` (`/Users/chrisbreuer/Code/Libraries/zig-regex/src`)

RegExp is backed by the sibling zig-regex repo. Full scan of its `src/*.zig`:

| Symbol | Location | What it is | Ruling | Notes |
|---|---|---|---|---|
| `c_allocator` | `zig-regex/src/c_api.zig:39` | `var c_allocator = std.heap.c_allocator` — the C-API allocator. Declared `var` but never reassigned. | **locked** | `std.heap.c_allocator` (malloc/free) is internally thread-safe, so this is sound as-is; it *should* be `const` to make the audit trivially green (upstream fix). zig-js does not link zig-regex's C API anyway (it uses the Zig API), so this is unreachable from engine threads today. The doc comment at `:43` mentions a `zig_regex_get_last_error()` — **no such function or last-error global exists**; the comment is stale, there is no hidden error state. |
| — | everything else | No other file- or container-scope mutable state in any of the 31 files (engines `vm.zig`, `backtrack.zig`, `dfa.zig`, `onepass.zig` included). | n/a | `thread_safety.zig` documents the guarantees this audit confirms: compiled `Regex` is immutable after `compile()`; every match call allocates its own VM/capture state from the caller's allocator; **no match state is static**; no internal caches. The only cross-thread requirement is a thread-safe allocator — zig-js passes per-context arenas, which is fine under context affinity (each agent's regexes live in its own arena). |

---

## Summary

- Every current file-scope `var`, `pub var`, and `threadlocal` hit in `src/*.zig`
  has a ruling above.
- The two original surprise hazards are fixed: `math_prng` is threadlocal, and
  `symbol_counter` is atomic.
- `$262.agent` and typed-array waiter state are explicitly locked in
  `src/agent.zig`.
- Shared-realm `Thread` state is either per-thread (`t_current`) or per-context
  locked (`Gil.tasks` via `Gil.api_lock`; `Gil.prop_waiters` / `Gil.prop_async`
  via `Gil.prop_mutex`).
- Conformance-host and zig-regex entries remain documented so the audit can be
  rerun from one place.

---

## How to re-run this audit

**Gotcha that will silently ruin the scan:** `src/interpreter.zig` (and several
data files) contain high bytes, so plain `grep` classifies them as binary and
prints nothing — *without an error*. Always use `LC_ALL=C grep -a` on `src/`.

1. **File-scope globals and threadlocals** (engine, hosts, and the path dep):

   ```sh
   LC_ALL=C grep -an "^var \|^pub var \|^threadlocal\|^pub threadlocal" src/*.zig
   LC_ALL=C grep -an "^var \|^pub var \|^threadlocal\|^pub threadlocal" conformance/*.zig
   LC_ALL=C grep -an "^var \|^pub var \|^threadlocal\|^pub threadlocal" ../zig-regex/src/*.zig
   ```

2. **Container-scope statics** (a `var` at struct/namespace scope, not inside a
   `fn`/`test` — Zig makes these globals too). Raw grep is hopelessly noisy
   (~1,200 function-local hits); filter to candidates and verify each hit's
   enclosing scope by reading context:

   ```sh
   LC_ALL=C grep -an "[[:space:]]var [A-Za-z_]" src/*.zig | LC_ALL=C grep -av "fn \|for \|while \|if " \
     # then: LC_ALL=C sed -n '<hit-30>,<hit>p' the file and check whether the
     # nearest enclosing block opener is a struct (global!) or a fn/test (fine).
   ```

   A brace-tracking script (push `fn`/`test` vs `struct` per `{`, report `var`
   when no `fn` is on the stack) gets the candidate list down to ~30 lines to
   eyeball. Watch for multi-line `fn` signatures — a naive single-line
   classifier mislabels their bodies as container scope.

3. **Allocator and time-source spot checks:**

   ```sh
   LC_ALL=C grep -an "page_allocator\|c_allocator\|std.time" src/*.zig ../zig-regex/src/c_api.zig
   ```

4. **Diff against this document.** Any hit not listed here is either new
   (add a row with a ruling) or a function-local false positive (verify scope
   before dismissing). Update the measured commit hash at the top.
