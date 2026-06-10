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

Line numbers below were measured at commit `e923761` (2026-06-10). They will
drift; re-measure with the commands in [How to re-run this audit](#how-to-re-run-this-audit)
before acting on one. Note in particular that issue #1's prose cites
`g_agent` at interpreter.zig:18531 / `t_is_agent` at :18536 — those have since
shifted to :18559 / :18564.

---

## Engine: `src/builtins.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `math_prng` | `src/builtins.zig:634` | `std.Random.DefaultPrng` seeded with a fixed constant; mutated on every `Math.random()` call (`mathRandom`, :637). | **per-thread** | **Not anticipated by the issue #1 plan.** Concurrent `random()` calls from two agents are a data race on the Xoshiro state (UB, not just bad randomness). Move into `Interpreter`/`Context` (preferred — also fixes the determinism smell of a process-wide fixed seed) or make it `threadlocal`. Phase 2a. |

## Engine: `src/interpreter.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `g_agent: AgentState` | `src/interpreter.zig:18559` | The cooperative `$262.agent` coordination state: `pending` agent sources, FIFO `reports`, and the latest broadcast's raw `bcast_ptr`/`bcast_len`. Mutated by `agent.start/broadcast/report/getReport` and reset in `installAgent` (`agentResetState`, :18567). | **locked** | Phase 2a replaces it wholesale with a mutex-protected `AgentGroup` (suggest `src/agent.zig`) owned by the main `Context`: locked report queue, agent-handle list, broadcast rendezvous. Until then it is only safe because agents run synchronously on the calling thread (`agentRunSync`, :18588). The raw `bcast_ptr` aliasing also dies in Phase 1 (`SharedBufferStorage` retain/release replaces `makeSharedArrayBufferOver`'s pointer wrap, :18576). |
| `g_agent_alloc` | `src/interpreter.zig:18560` | `const` binding to `std.heap.page_allocator`; allocates agent sources and report strings so they outlive per-test arenas. | **locked** | The binding is immutable and `page_allocator` is internally thread-safe, so this is already sound. Folded into `AgentGroup`'s allocator in Phase 2a. Listed because it is the allocator that report-string copies (which cross threads) must keep using — never a context arena. |
| `t_is_agent` | `src/interpreter.zig:18564` | `threadlocal var bool` — true while executing inside a cooperatively-spawned agent realm; keeps `installAgent` from resetting the parent's agent state. | **per-thread** | Already threadlocal (correct by construction). Phase 2a upgrades it from a bool to a threadlocal pointer/handle to the current agent record in the `AgentGroup`. |
| `symbol_counter` | `src/interpreter.zig:24890` | `var usize` — monotonic id for unique `Symbol` property-key encodings (`"\x00s{d}"`, `makeSymbolObj` :24894). Its own doc comment says "single-threaded; test262 workers are separate processes". | **locked** | **Not anticipated by the issue #1 plan.** Two agents minting symbols concurrently race the increment and can mint *colliding* `sym_key`s. Replace with `std.atomic.Value(usize)` `fetchAdd` (cheapest), or make per-context with a per-context prefix. Atomic is preferred: key uniqueness must hold process-wide if any symbol-keyed structure ever crosses threads (Layer B `Thread.restrict`, shared structs). Phase 2a. |

## Engine: `src/c_api.zig`

| Symbol | Location | What it is | Ruling | Notes / phase |
|---|---|---|---|---|
| `gpa` | `src/c_api.zig:40` | `const gpa = std.heap.page_allocator` — backs every C-API-created `Context` and `JsString`. | **locked** | Immutable binding; `page_allocator` is internally synchronized, so concurrent `JSGlobalContextCreate` / `JSStringCreateWithUTF8CString` from different threads are safe. No handle registry exists (refs are raw pointers; lifetime is the caller's problem), so there is no other C-API global to rule on. The Phase 0 thread rule still applies: each created `JS*Ref` is affine to its context's thread. |

No other mutable globals: the `var buf` / `var exception` hits at :452/:465/:497
are locals inside `test` blocks.

## Engine: all other `src/*.zig`

A brace-tracking scan of every file (see re-run section) found **no** other
file-scope or container-scope `var`/`threadlocal` in `src/`. Specifically
verified clean: `ast.zig`, `bytecode.zig`, `cldr_*.zig`, `compiler.zig`,
`context.zig`, `jsstring.zig` (no string-interning table exists — strings live
in context arenas), `lexer.zig`, `numbering_systems.zig` (its `var arr` at :91
is inside a `comptime` block producing a `const`), `parser.zig` (reentrant, no
statics), `promise.zig`, `root.zig`, `shape.zig`, `unicode_case*.zig`,
`value.zig`, `vm.zig`. There are no date/time caches: nothing in `src/` calls
`std.time` or caches a timezone — `Date` math is pure arithmetic on the
`date_ms` slot (the engine is UTC-only).

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

- **10** process-global mutable (or globally stateful) items found:
  **5** in `src/` (`math_prng`, `g_agent`, `g_agent_alloc`, `t_is_agent`,
  `symbol_counter`), **4** in conformance hosts, **1** in zig-regex.
- Rulings: **2 per-thread** (`math_prng`, `t_is_agent`),
  **4 locked** (`g_agent`, `g_agent_alloc`, `symbol_counter`,
  zig-regex `c_allocator`), **4 refused** (conformance-host state).
- Plus **8** per-Context/per-Interpreter rulings recorded above
  (7 per-thread, 1 locked) so Phase 2c can execute against a single list.
- Surprises vs. the issue #1 plan: `math_prng` (a racing process-global PRNG
  behind `Math.random()`) and `symbol_counter` (racy symbol-key uniqueness)
  were not in the issue's known-globals list; zig-regex turned out to have no
  static match state at all (better than feared), and its documented
  `zig_regex_get_last_error` does not exist.

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
