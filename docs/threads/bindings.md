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

Line numbers below were refreshed on 2026-06-13. They will drift; re-measure
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
| `main_can_block` | `src/agent.zig:74` | Host knob modeling the main agent's `[[CanBlock]]`. | **locked** | The conformance hosts set this around a single test before running JS. If embedders mutate it concurrently, make it an atomic or move it into host-owned context options. |
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
| `max_threads` | `src/jsthread.zig:135` | Host/test knob limiting live spawned shared-realm `Thread`s. | **locked** | The threads corpus runner sets this around a single test (`thread-id-bounds.js`). Concurrent embedders should prefer a per-context option before exposing this knob generally. |
| `Gil.tasks` | `src/gil.zig:28` | Per-realm run-loop task queue for `Lock.asyncHold` grant delivery. | **locked** | Protected by the owning context GIL; backing is realm-arena owned. |
| `Gil.prop_waiters` / `Gil.prop_async` | `src/gil.zig:31-34` | Per-realm property-mode `Atomics.wait` and `waitAsync` waiter queues. | **locked** | Protected by the owning context GIL and intentionally not process-global; independent `enable_threads` contexts cannot race or cross-notify each other. |

## Engine: `src/c_api.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `gpa` | `src/c_api.zig:40` | `const gpa = std.heap.page_allocator` — backs every C-API-created `Context` and `JsString`. | **locked** | Immutable binding; `page_allocator` is internally synchronized, so concurrent `JSGlobalContextCreate` / `JSStringCreateWithUTF8CString` from different threads are safe. No handle registry exists (refs are raw pointers; lifetime is the caller's problem), so there is no other C-API global to rule on. The Phase 0 thread rule still applies: each created `JS*Ref` is affine to its context's thread. |

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
get explicit rulings here to make this the one-stop checklist. The baseline
model (Phase 0, already encoded in `Context.owner_thread`,
`src/context.zig:25`): **a `Context` is single-thread-affine; one context per
thread; agents get their own `Context`.** Under that model "per-agent-Context"
satisfies "per-thread". Layer B (multiple JS threads under a GIL touching
shared objects) tightens some rulings as noted.

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `Context.exception` | `src/context.zig:30` | The pending-exception slot. | **per-thread** | Per-agent-Context suffices for Layer A. For Layer B this is *the* PR-249 trap (their bug list: "exception state per-thread"): two threads entering shared evaluation must each carry their own slot — move to a per-thread execution-state record when Layer B lands. |
| `Context.microtasks` | `src/context.zig:33` | The microtask queue (Promise reactions), shared with each `Interpreter` via pointer (`interpreter.zig:339`). | **per-thread** | Pinned PR-249 decision: each thread drains its own microtask queue; queues never interleave; reactions run on the settling thread. One queue per agent (Layer A) and per JS thread (Layer B). |
| `Context.print_buffer` | `src/context.zig:34` | `print()` output accumulator, shared with each `Interpreter` (`interpreter.zig:346`). | **per-thread** | Per-agent-Context for Layer A. If Layer B ever lets two threads print into one context, it needs a mutex — rule then; for now per-thread. |
| `Context.root_shape` + `Shape.transitions` | `src/context.zig:29`, `src/shape.zig:29` | The per-context shape tree; transition maps (`StringHashMapUnmanaged(*Shape)`) are mutated on property addition. | **per-thread** | One shape tree per context — agents never share shapes (this is why Layer A needs no shape locks, per issue #1). **refused** across threads without the Layer B GIL: a bare concurrent transition insert is a data race; under the GIL it is incidentally protected; Layer C re-opens this with per-tree locking or lock-free transitions. |
| `Context.mod_cache` (+ `mod_host`, `script_referrer`) | `src/context.zig:40` (`:38`, `:44`) | Module-graph cache for `evaluateModule` / dynamic `import()`; points at a stack-local map during evaluation (`:226-233`). | **per-thread** | Per-context, mutated only inside the owner thread's `evaluate*` calls. The stack-local backing makes cross-thread reachability structurally impossible today; keep it that way. |
| `Interpreter.re_legacy` | field `src/interpreter.zig:394`, struct `:323` | Annex-B `RegExp.$1`/`lastMatch`/… legacy match state, updated on every successful regex match (`:20540`). | **per-thread** | Already a per-`Interpreter` instance field — **confirmed and ruled done** (Phase 2c checklist item). Each agent's interpreter has its own. No static regex scratch exists on the zig-js side. |
| `Interpreter.depth` / `Interpreter.steps` | `src/interpreter.zig:440-441` (limit `max_call_depth`, `:26`) | Call-depth and step counters. The bytecode VM does **not** keep its own counter: `vm.zig`'s checks at `:739`, `:879`, `:1054`, `:1280` increment the *same* `Interpreter.depth` (its `vm` parameter is the `*Interpreter`), so interpreter and VM share one per-instance counter. | **per-thread** | One `Interpreter` per evaluation per context ⇒ per-agent today. PR-249 bug list: stack-overflow limits must be per-*thread*, not per-context — when Layer B lets one context run on several threads, `depth` moves to the per-thread execution record alongside `exception`. |
| `value.ArrayBufferData` (shared buffers) | `src/value.zig:90` | SAB backing storage: today `data: []u8` in some context's arena, raw-pointer-shared by broadcast. | **locked** | Phase 1 rewires shared buffers to a `SharedBufferStorage` with an atomic `refcount` and atomic length (grow-only, in-place), allocated from a stable global allocator — never a context arena. Element accesses are aligned ≤8-byte loads/stores; `Atomics.*` use `@atomicRmw`/`@cmpxchgStrong`. Non-shared buffers keep the arena path (per-thread by context affinity). |

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
  GIL-owned (`Gil.tasks`, `Gil.prop_waiters`, `Gil.prop_async`).
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
