# zig-js

A **JavaScript engine written in pure Zig**, with a **JavaScriptCore C-API-compatible** surface. No JSC, no V8, no external C libraries — just Zig.

`zig-js` is a small, embeddable engine for Zig applications, tools, and runtimes that want to own their JS stack. Use it directly as a Zig module, or link it in place of `JavaScriptCore.framework` when a host already targets the JSC C API.

It tracks the ECMAScript spec closely and is graded against the **real [tc39/test262](https://github.com/tc39/test262) corpus** — currently **46,167 / 48,247 (95.7%)** of the scored "can we run it" tests pass. See [Conformance](#conformance) for the full breakdown.

```zig
const js = @import("js");

const ctx = try js.Context.create(allocator);
defer ctx.destroy();

const v = try ctx.evaluate("let x = 40; x + 2");
// v == .{ .number = 42 }
```

## Contents

- [How it works](#how-it-works)
- [Conformance](#conformance)
- [Performance](#performance)
- [Language & runtime coverage](#language--runtime-coverage)
- [Using it](#using-it)
- [Used by](#used-by)
- [Architecture](#architecture)
- [Build & test](#build--test)
- [Multithreading roadmap](#multithreading-roadmap)
- [License](#license)

## How it works

The engine has **two execution tiers that share one object model**, so behavior is identical no matter which runs:

- A **tree-walking interpreter** — the correctness oracle and the fallback for anything not yet lowered.
- A **suspendable stack bytecode VM** — lowers the hot subset of the language plus generators, async functions, and async generators (their bodies must suspend/resume, so they run *only* on the VM).

Top-level and function code compiles to bytecode and runs on the VM; any construct the compiler can't yet lower transparently falls back to the tree-walker. A shared microtask queue drives Promises and async jobs.

> **Status: maturing.** Most of the language and the core built-in library are implemented and spec-faithful enough to satisfy test262's `propertyHelper` (brand checks, attribute fidelity, exact error types). The main gaps are `Intl`/CLDR locale data, `Temporal` edge cases, full regex-engine coverage, and a handful of early-error subsystems.

## Conformance

Measured by `zig build test262` against the pinned tc39/test262 submodule. The score is split on two honest axes so a weak parser can't flatter itself — **valid** tests measure whether we can *run* a program, **negative** tests measure *strictness* (rejecting invalid input). Mixing them lets a parser "pass" negatives by failing to parse valid code too, so they're kept apart:

| axis | meaning | passing |
| ---- | ------- | ------: |
| **valid** | can we run the program? (scored corpus) | **46,167 / 48,247 (95.7%)** |
| negative | do we reject invalid input? (early errors) | 4,661 / 4,669 (99.8%) |

Of the valid corpus: **29 parse failures**, **2,039 runtime failures**, **12 host failures**. The runner currently skips 261 tests that need more harness work (top-level-await modules, some async-harness protocols, unloadable includes). Remaining valid failures concentrate in `intl402` (CLDR data), `Temporal` edge cases, `staging`, Annex B, and the async-generator / `for await` VM lowering in `language`.

### Per area (valid)

| area | passing | area | passing |
| ---- | ------: | ---- | ------: |
| `language` | 18,604 / 19,070 (97.6%) | `Object` | 3,411 / 3,411 (100%) |
| `Array` | 3,078 / 3,081 (99.9%) | `RegExp` | 1,685 / 1,687 (99.9%) |
| `String` | 1,223 / 1,223 (100%) | `TypedArray` | 1,446 / 1,446 (100%) |
| `TypedArrayConstructors` | 738 / 738 (100%) | `Uint8Array` | 70 / 70 (100%) |
| `Map` | 204 / 204 (100%) | `Set` | 383 / 383 (100%) |
| `BigInt` | 77 / 77 (100%) | `Symbol` | 98 / 98 (100%) |
| `Boolean` | 51 / 51 (100%) | `Math` | 327 / 327 (100%) |
| `DataView` | 561 / 561 (100%) | `Number` | 340 / 340 (100%) |
| `WeakSet` | 85 / 85 (100%) | `WeakMap` | 141 / 141 (100%) |
| `WeakRef` | 29 / 29 (100%) | `FinalizationRegistry` | 47 / 47 (100%) |
| `Temporal` | 4,009 / 4,603 (87.1%) | `intl402` | 2,675 / 3,341 (80.1%) |
| `annexB` | 984 / 1,071 (91.9%) | `staging` | 1,084 / 1,345 (80.6%) |
| `SharedArrayBuffer` | 104 / 104 (100%) | `ArrayBuffer` | 221 / 221 (100%) |
| `Atomics` | 390 / 390 (100%) | — | — |
| `SuppressedError` | 22 / 22 (100%) | `ThrowTypeError` | 14 / 14 (100%) |
| `AbstractModuleSource` | 8 / 8 (100%) | `AggregateError` | 25 / 25 (100%) |
| `parseFloat` | 54 / 54 (100%) | `parseInt` | 55 / 55 (100%) |
| `decodeURI` | 55 / 55 (100%) | `decodeURIComponent` | 56 / 56 (100%) |
| `encodeURI` | 31 / 31 (100%) | `encodeURIComponent` | 31 / 31 (100%) |
| `AsyncIteratorPrototype` | 13 / 13 (100%) | `eval` | 10 / 10 (100%) |
| `global` | 29 / 29 (100%) | `Function` | 509 / 509 (100%) |
| `Proxy` | 310 / 310 (100%) | `Reflect` | 153 / 153 (100%) |

Latest focused `test/intl402` worker checkpoint: **2,658 / 3,341 (79.6%)**, up **+4** from the previous focused checkpoint of 2,654 / 3,341 after using authoritative Persian year starts and one observed Um Al-Qura date for Temporal string roundtrips.

> `zig build test262` prints each subtree's pass rate plus `parse-fail` / `runtime-fail` / `host-fail` counts, so the work stays data-driven. `zig build conformance` keeps a separate 33/33 always-green smoke suite for fast iteration. Refresh the corpus with `git submodule update --remote test262`.

## Performance

Each tier is gated by test262 (never regress correctness for speed) and timed by `zig build bench`:

| tier | what | status | vs tree-walk |
| ---- | ---- | :----: | -----------: |
| 0 | tree-walk interpreter | ✅ | 1× (baseline) |
| 1 | **stack bytecode VM** — lowers nearly the whole language (objects, arrays, members, `new`, methods, `++`, `instanceof`) | ✅ | ~1.1× |
| 2 | **slot-allocated locals + frame-linked closures** — params/locals resolved to a flat frame array at compile time | ✅ | 1.3–1.85× |
| 3 | **object shapes (hidden classes) + inline caches** — shared shape-transition tree, flat slots, monomorphic IC per property site | ✅ | **1.6–1.7×** |
| 4 | NaN-boxed values | next | — |
| 5 | generational GC (replaces the arena) | planned | — |
| 6 | baseline → optimizing JIT | planned | — |

Tier-2 nearly doubled compute/call-heavy code; tier-3 brought object-property churn from a 1.33× laggard up to 1.73× (objects no longer allocate a per-instance hashmap, and repeat property access is an inline-cache hit). The tree-walker remains the oracle and the fallback for not-yet-lowered constructs.

## Language & runtime coverage

**Literals & operators** — numbers (int/float/hex/octal/binary/exp, spec `ToString`), strings (full escape set incl. `\u{…}`), `true`/`false`/`null`/`undefined`, objects (shorthand, computed keys, getters/setters, spread), arrays (incl. holes/sparse), regex literals, template literals + tagged templates; the full operator set incl. `**`, `??`, `?.`, `&&=`/`||=`/`??=`, bitwise/shift, `in`/`instanceof`/`typeof`/`delete`/`void`, comma.

**Bindings & scope** — `var`/`let`/`const`, block scoping + TDZ, destructuring (array/object, defaults, rest) in declarations, parameters, and assignment; `with`; `eval` (direct & indirect).

**Functions** — declarations/expressions (incl. named-expression self-binding), arrows, default/rest params (including destructuring rest), `arguments` (mapped & unmapped), closures, `new`, `new.target`, getters/setters; `Function.prototype` `call`/`apply`/`bind`/`toString`.

**Classes** — fields, private members + methods, `static` members + blocks, accessors, `super` (calls and member access), derived constructors, `extends`.

**Generators & async** — `function*` + `yield`/`yield*` (with throw/return delegation, destructuring-assignment-with-yield), `async` functions + `await`, `async function*` + `for await … of` — all driven on the suspendable VM.

**Control flow** — `if`/`else`, `while`/`do…while`, `for`/`for-in`/`for-of`, `switch`, labels, `break`/`continue`, `throw`/`try`/`catch`/`finally`.

**Modules** — `import`/`export` (default, named, namespace, re-export, `export *`), graph linking with live bindings and live namespace objects (see [Conformance](#conformance) for scoring status).

**Built-in library** — `Object`, `Function`, `Array` (incl. holes/sparse, `fromAsync`, freeze/seal), `String` + a homegrown `RegExp` backed by [`zig-regex`](../zig-regex), `Number`, `Boolean`, `Math`, `JSON`, `Symbol` (+ well-known symbols), `Map`/`Set`/`WeakMap`/`WeakSet`, `Promise` (combinators, subclassing/species, microtask ordering), `Date`, the `Error` family, `Proxy`/`Reflect`, `globalThis`, typed arrays + `ArrayBuffer`/`SharedArrayBuffer`/`DataView`/`Atomics`, `WeakRef`/`FinalizationRegistry`, and partial `Temporal` + `Intl`. Each is brand-checking and attribute-faithful enough to satisfy test262's `propertyHelper`.

## Using it

### As a Zig module

```zig
const js = @import("js");

const ctx = try js.Context.create(allocator);
defer ctx.destroy();
const v = try ctx.evaluate("let x = 40; x + 2");
// v == .{ .number = 42 }
```

### As a JavaScriptCore C-API drop-in

Link `libzig-js.a` in place of `JavaScriptCore.framework`. The exported symbols match Apple's `<JavaScriptCore/JSValueRef.h>` / `<JSObjectRef.h>`:

```c
JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
JSStringRef script = JSStringCreateWithUTF8CString("1 + 1");
JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);
double n = JSValueToNumber(ctx, result, NULL); // 2.0
```

Implemented C-API symbols:

- **Context lifecycle** — `JSGlobalContextCreate`, `ZJSGlobalContextCreateThreaded(gil)`, `JSGlobalContextRelease`/`Retain`, `JSContextGetGlobalObject`, `JSEvaluateScript`, `JSGarbageCollect`.
- **Value inspection** — `JSValueGetType`, `JSValueIs*`, `JSValueIsEqual`/`StrictEqual`.
- **Constructors & coercion** — `JSValueMake*`, `JSValueTo*`, `JSValueProtect`/`Unprotect`.
- **Objects** — `JSObjectMake`, `JSObjectMakeArray`, `JSObjectGet`/`SetProperty`, `JSObjectGetPropertyAtIndex`, `JSObjectCallAsFunction`, `JSObjectCallAsConstructor`, `JSObjectMakeFunctionWithCallback`, `JSObjectIsFunction`/`IsConstructor`.
- **Strings** — `JSStringCreateWithUTF8CString`, `JSStringRetain`/`Release`, `JSStringGetLength`, `JSStringGetUTF8CString`.

`JSObjectCallAsFunction`/`CallAsConstructor` drive the interpreter, so JS functions and the built-in `Error` constructors are callable across the C boundary; thrown JS values surface as the C-API `exception` out-param. `JSObjectMakeDeferredPromise` raises a `NotImplemented` exception until the deferred-promise plumbing lands.

### Used by

- [home-lang/craft](https://github.com/home-lang/craft)

## Architecture

```
                          ┌─► compiler ─► bytecode ─► VM ──┐  (hot subset + generators/async)
source ─► lexer ─► parser ─┤                                ├─► Value
              (AST)        └─► tree-walk interpreter ───────┘  (oracle + fallback)
                                                     │
                                          c_api.zig (JSC drop-in exports)
```

| file | responsibility |
| ---- | -------------- |
| `src/value.zig` | `Value` union + `ToBoolean`/`ToNumber`/`ToString`/`typeof`, equality, `Object` (shapes, per-index attrs, accessors, array elements/holes) |
| `src/lexer.zig` | single-pass tokenizer |
| `src/ast.zig` | unified expression/statement/module node |
| `src/parser.zig` | recursive-descent + precedence climbing (`parseProgram` / `parseModule`) |
| `src/interpreter.zig` | tree-walking evaluator, environments, and the built-in library |
| `src/compiler.zig` | AST → stack bytecode (functions, generators, async) |
| `src/bytecode.zig` | instruction set + chunk/function templates |
| `src/vm.zig` | the suspendable bytecode VM (frames, generators, async drivers) |
| `src/shape.zig` | hidden-class (shape) transition tree |
| `src/promise.zig` | Promise state machine + microtask queue |
| `src/context.zig` | engine instance (arena, persistent global env, module loader/linker) |
| `src/jsstring.zig` | refcounted `JSStringRef` backing |
| `src/c_api.zig` | the exported JavaScriptCore C-API symbols |
| `src/root.zig` | `@import("js")` entry point |

## Build & test

Requires Zig **0.17.0-dev**.

```sh
zig build                       # builds libzig-js.a (the JSC drop-in)
zig build test                  # runs the unit + C-API test suite
zig build conformance           # runs the always-green smoke suite (33/33)
zig build threads-test          # runs the green WebKit PR-249 threads corpus (225/225)
zig build threads-reference-audit # classifies the remaining reference-only PR-249 files
python3 tools/threads-reference-audit.py --probe-candidates # prints closest promotion probes
zig build test -Dtsan=true      # unit suite under ThreadSanitizer
zig build threadfuzz            # seeded concurrent-JS fuzzer
zig build threadfuzz -Dfuzz-midgc=true # mid-script GC wait-pump + microtask + creator buffers + sync-wait cleanup + teardown + promise + script/module Worker/SAB + Worker exception + Worker close/terminate + weak-collection fuzzer
zig build test262               # runs the real tc39/test262 corpus, prints pass %
zig build test262 -Dtest262=DIR # …with an explicit corpus root
zig build bench                 # times the bytecode VM against the tree-walker
zig build threads-profile       # profiles no-GIL Thread scaling/lock contention
zig build gc-profile            # profiles GC allocation/context lifecycle costs
```

The test262 corpus is vendored as the `test262/` git submodule (`git submodule update --init`); `zig build test262` uses it by default and skips cleanly if it isn't present. For speed it runs `ReleaseFast` under subprocess isolation, so a single pathological test can't abort the run.

## Multithreading roadmap

`Context.createWith(.{ .enable_threads = true })` installs the shared-realm
`Thread`, `Lock`, `Condition`, `ThreadLocal`, `ConcurrentAccessError`,
property-mode `Atomics.*`, and proposal-aligned `Atomics.Mutex` /
`Atomics.Condition` surface. Shared-realm `Thread`s now run true-parallel by
default on the GC-managed, thread-safe heap:

```zig
const parallel = try js.Context.createWith(gpa, .{ .enable_threads = true });
const serialized = try js.Context.createWith(gpa, .{ .enable_threads = true, .gil = true });
```

The `.gil = true` path remains a supported opt-out for strict serialized
interleavings and compatibility testing. The C API exposes the same choice with
`ZJSGlobalContextCreateThreaded(gil)`.

Thread support is tracked in the canonical
[issue #1](https://github.com/zig-utils/zig-js/issues/1) and the design/status
docs under `docs/threads`. Current coverage includes isolated agents, retained
`SharedArrayBuffer` storage, typed-array and property-mode `Atomics.wait` /
`notify` / `waitAsync`, structured clone, ArrayBuffer transfer/detach, Worker
message passing, and the shared-realm `Thread` API. The vendored WebKit PR-249
allowlist is **225/225** green.

Correctness is now gated by the ordinary unit/corpus suite plus no-GIL coverage:
ThreadSanitizer unit tests, a sharded no-GIL PR-249 corpus TSan sweep, a
suppression-narrowness witness for JS-defined program-byte races,
`test262-parallel`, and seeded concurrent-JS fuzzing (`threadfuzz`, TSan
fuzzing, amplified fuzzing, broad semantic fuzzing,
mid-script-GC wait-pump/microtask/creator-buffer/sync-wait-cleanup/promise/teardown/Worker-SAB/Worker-exception/Worker-close/weak-collection fuzzing, lifecycle
fuzzing, ReleaseSafe fuzzing, and deterministic-result verification).

Remaining work is concentrated in production hardening rather than the core
threading architecture:

- **GC performance** - `zig build gc-profile` compares arena, explicit-GC,
  no-GIL threaded GC, and `.gil = true` lifecycle/allocation costs, including a
  create-per-task versus long-lived-context reuse section with periodic
  collection, and now splits context lifecycle time into create and destroy
  columns before printing GC cell-backing attribution around an object-heavy
  allocation run: chunk count, total cell-slot capacity, live cells at context
  creation, live cells after script allocation, free slots after collection, and
  live cells after collection. GC cells now allocate through a reusable
  size-class slab backing instead of one backing allocator call per cell, and
  fresh slab chunks hand out cells lazily with a per-bucket bump hint instead of
  pre-linking every unused slot during short-lived context setup; a per-bucket
  fresh-chunk cursor skips chunks whose bump range is already exhausted. Freed
  cells are still recycled through the per-bucket free lists, with exact
  per-bucket free counts so profile/stat snapshots do not walk every freed cell,
  and classified against per-size-class address spans plus a recent-chunk hint
  before scanning chunk lists to keep collection/destroy lookup costs bounded.
  Single-mutator GC object side stores now allocate directly from the context
  allocator instead of round-tripping through that cell-slab
  classifier, while true-parallel contexts keep the synchronized backing wrapper.
  Context teardown now enters a slab bulk-teardown mode so per-cell frees do not
  rebuild freelists or reclassify bucket ownership immediately before whole
  chunks are released. Live `SharedArrayBuffer` retain teardown is regression
  covered across arena, no-GIL threaded, and `.gil = true` contexts. Keep using
  the profile attribution to drive nursery/generational work and further
  lifecycle reductions for create-per-task embedders.
- **Parallel scaling** - `zig build threads-profile` compares the no-GIL
  default against `.gil = true` across independent compute, shared object
  properties, array append, typed-array Atomics, property `Atomics.wait` /
  `notify`, property `Atomics.waitAsync` timeout settlement,
  `Condition.wait` / `notifyAll`, `Condition.asyncWait`, contended `Lock.hold`, and
  `Lock.asyncHold` delivery plus observed callback and no-fn release-function
  variants, along with lifecycle churn. It now enables and prints internal
  contention events, timed wait/pump parks, async waiter registration/completion
  counts for `Condition.asyncWait` and property `waitAsync`, and run-loop
  task-pump empty/job counts beside wall-clock time, so follow-up optimization
  can separate property waiters, property `waitAsync` timeout settlement,
  condition waiters, async condition regrant delivery, user-level lock pressure,
  thread-join/lifecycle waiting, unobserved async-hold grant delivery,
  promise-observed callback settlement, no-fn release-function delivery,
  object/element storage contention, and GC allocation costs under high thread
  counts. It also prints
  a separate isolated `Worker` section for structured-clone inbox/outbox
  round-trips and spawn/post/receive/join/destroy lifecycle cost; that section
  has no `.gil = true` comparison because each Worker owns its own `Context`.
  The sync-wait pump path now skips the shared run-loop task lock entirely when
  no async hold jobs are queued, and async-hold delivery now dequeues both the
  per-lock pending list and the realm task queue through FIFO head cursors
  instead of front-shifting task lists. Realm task pumps also copy bounded FIFO
  bursts under the shared API lock before running grants outside it, so delivery
  no longer takes that lock once per job. `Condition.notify` / `notifyAll` now
  use the same FIFO head-cursor shape for their mixed sync/async waiter queue,
  avoiding one front shift per notified waiter; timed-out or terminated sync
  condition waiters are marked canceled and skipped by that cursor instead of
  being removed from the middle of the queue. Sync `notifyAll` handoff also
  waits on the condition's ack signal instead of sleeping in fixed 1ms polling
  chunks, so ready waiters can re-enter the lock path immediately. Async-only
  condition notifications now deliver their lock regrants after releasing the
  condition queue mutex, so no-fn release-function creation and realm task
  enqueueing do not lengthen that critical section; mixed sync/async wakeups
  keep the existing sync handoff ordering. Notify now also tracks the woken
  sync/async entries in one pre-sized wake list instead of allocating separate
  per-kind wake lists for every notification.
  Property-mode `Atomics.notify` now stable-compacts matching waiters in one
  pass: sync stack tickets are
  unlinked before signal, and matching `waitAsync` tickets are collected without
  repeated `orderedRemove` shifts. Individual sync wait timeout/termination
  cleanup also stable-compacts the waiter table in one pass instead of
  front-shifting the remaining waiters, and timeout polling plus realm teardown
  now scan property `waitAsync` tickets once instead of removing one middle
  entry per expired/abandoned ticket. Typed-array `Atomics.notify` now unlinks
  notified sync stack tickets before signaling, so awakened waiters do not each
  rescan and shift the process-wide waiter list; typed-array `waitAsync`
  harvest and abandon paths stable-compact settled/owner tickets in one pass
  while preserving FIFO order for remaining waiters. Worker inbox/outbox channels now drain
  through the same FIFO head-cursor shape instead of front-shifting
  structured-clone message queues, and empty internal `Worker.receive(..., 0)`
  polls return under the channel lock without entering timed condition waits or
  touching drained-queue compaction. Active interpreter roots, protected C-API
  handles, and GIL park records are unordered root sets, so their removals now
  use swap removal instead of preserving order with list shifts on evaluate,
  unprotect, and thread teardown paths. WeakMap/WeakSet entry delete and GC
  dead-key pruning now use the same unordered tail-removal shape, and
  FinalizationRegistry `unregister` removes matching records with one stable
  compaction pass so later cleanup delivery keeps survivor order without
  repeated middle shifts.
  Promise microtask drains now use a FIFO head cursor too, so observed
  `Lock.asyncHold` callbacks and no-fn release-function reactions do not pay one
  front shift per pending reaction while preserving checkpoint order. The
  async-hold task pump also snapshots the microtask enqueue generation around
  each delivered grant, so unobserved grants that settle without queuing any
  reaction skip the otherwise-empty microtask drain lock in no-GIL mode.
  No-fn async-hold grants embed their once-only release state in the already
  arena-lived hold job, avoiding an extra small allocation per delivered release
  function.
  The profile now also has direct rows for property `waitAsync` finite-timeout
  settlement and `Condition.asyncWait` reacquire delivery, with async/done
  columns that show ticket registration, completed async-condition reacquires,
  and exact property-ticket settlement parity during local performance work.
  The Worker profile prints that empty-receive polling cost separately from
  real message-delivery and lifecycle cost. Continue using the profile for the
  remaining async-condition delivery, contended-lock, Worker message, and
  lifecycle hot spots.
- **Memory-model maintenance** - keep
  [docs/threads/memory-model.md](docs/threads/memory-model.md) aligned with the
  TSan suppression witness, synchronization primitives, and promoted corpus
  coverage.
- **Mid-script parallel GC** - sync-wait pump points now publish roots for
  property `Atomics.wait`, `Condition.wait`, and contended `Lock` acquisition,
  so the abort-safe collector can finish while those peers are blocked. The GC
  root set now also covers host-side thread queues such as `Gil.tasks`,
  per-lock async grants, async condition waiters, typed-array `waitAsync`
  waiter/reaction roots, pending `Thread.asyncJoin` promise/reaction roots,
  ThreadLocal values, thread completion results, release-function lock records,
  and contended `Lock.hold` receiver/callback pairs. Keep maturing convergence
  and stress coverage for heavier
  wait/cleanup mixes; the mid-GC fuzzer now queues a FIFO `Lock.asyncHold`
  grant chain including a root-bearing rejected grant, an async
  `Condition.wait` reacquire path, and a typed-array `waitAsync` reaction graph
  reachable only through the native waiter queue, and pending
  `Thread.asyncJoin` fulfillment/rejection reaction graphs
  reachable only through native completion records while allocation pressure
  collects. A sibling promise-publication subprogram leaves a child-returned
  typed-array `waitAsync` promise, a child-returned rejected promise, a
  child-returned user thenable, and a child-thrown object parked in thread
  completion/native waiter state through a finishing sweep, then verifies
  `join()` / `asyncJoin()` fulfillment, rejection, thenable assimilation, and
  thrown-object publication from observers registered both before and after
  child completion. Another sibling sync-wait cleanup subprogram parks peers in
  property `Atomics.wait`, `Condition.wait`, and contended `Lock.hold`
  acquisition, drives a finishing sweep, then verifies their stack roots after
  resume plus exact `FinalizationRegistry` cleanup count/sum delivery; the same
  subprogram now settles expired property `waitAsync` tickets while those peers
  are parked, keeps a live property `waitAsync` ticket rooted through the
  finishing sweep, then notifies it and verifies the exact captured-root score.
  Script Worker/SAB and module Worker/SAB cleanup subprograms run isolated
  Workers on the same retained `SharedArrayBuffer` while shared-realm `Thread`s
  register cleanup targets and park stack roots through a finishing sweep, then
  verify exact Worker progress, joined thread roots, asyncJoin reactions, and
  cleanup count/sum; sibling script/module Worker handler-exception cleanup
  subprograms first recover from an expected thrown `onmessage` delivery, then
  prove the same progress and cleanup oracle through the finishing sweep.
  Script and module Worker close/terminate subprograms now compose exact FIFO
  drain/drop ordering, post-close drop, post-terminate receive silence, joined
  shared-realm roots, asyncJoin reactions, and cleanup count/sum with the same
  finishing mid-script sweep.
  A pending-microtask subprogram queues Promise, typed-array `waitAsync`,
  `Thread.asyncJoin`, with-fn `Lock.asyncHold`, no-fn release-function, and
  `FinalizationRegistry` cleanup roots through a finishing mid-script sweep,
  then drains the realm run loop and verifies exact reaction and cleanup
  oracles.
  A creator-owned buffer subprogram leaves child-created `SharedArrayBuffer`
  and `ArrayBuffer` storage rooted through unjoined `Thread` completion records
  and delayed `asyncJoin` observers across a finishing sweep, then verifies
  blocking `join()`, post-sweep `asyncJoin()`, and `ArrayBuffer.transfer()`
  observers see exact contents after the creating thread has exited.
  A weak-collection subprogram parks property `Atomics.wait`,
  `Condition.wait`, and contended `Lock.hold` peers while allocation pressure
  leaves live WeakMap values reachable only through live weak keys, dead
  WeakMap/WeakSet targets reachable only through weak structures and WeakRefs,
  and FinalizationRegistry unregister-token records queued through a finishing
  sweep; it then verifies live ephemeron values, cleared dead refs, exact
  cleanup count/sum, and exact unregister-token suppression.
  A sibling mid-GC teardown subprogram parks children after installing
  child-owned typed-array `waitAsync` tickets, verifies pending `asyncJoin`
  rejection reactions after parent failure, and proves later notify wakes zero
  leaked waitAsync tickets. The profile also verifies exact
  `FinalizationRegistry` cleanup count/sum delivery plus unregister-token
  suppression after those wait-pump sweeps and keeps a registered object
  reachable only through `ThreadLocal.value` while the owning thread is parked,
  proving that hidden
  native ThreadLocal roots survive the mid-script collection window. Join-side
  parked-root state is now balanced across termination/error unwinds, so a
  failed `Thread.join()` cannot leave the interpreter permanently marked as a
  frozen parked peer, and joiners now publish that parked state only for the
  actual native condition wait, not while pumping tasks. Requested shell/host
  GC now leaves active mid-script parallel marks alone until the realm is
  quiescent, then aborts stale parallel mark state before a fresh precise
  collection.
- **Stress breadth** - the broad fuzzer profile now covers exceptions/finally,
  cleanup, waiters, `asyncJoin`, `Thread.restrict`, and nested thread lifecycle;
  the mid-GC profile covers sync-wait root publication during finishing
  mid-script sweeps, queued async-hold delivery including rejected grant
  reactions, async condition reacquire delivery, typed-array `waitAsync` native
  waiter/reaction roots, pending `Thread.asyncJoin` reaction roots,
  child-returned `waitAsync` promise fulfillment/rejection, user thenable
  assimilation, and thrown-object publication through `join()` / `asyncJoin()`,
  pending Promise/microtask roots across asyncHold callback/release delivery,
  typed-array `waitAsync`, `Thread.asyncJoin`, and cleanup reactions,
  creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage rooted through
  unjoined Thread completion records and delayed `asyncJoin` observers,
  isolated script/module Worker/SAB progress, Worker handler-exception
  recovery, and Worker close/terminate drain/drop while shared-realm cleanup
  roots are swept,
  teardown termination with pending asyncJoin/waitAsync roots,
  ThreadLocal-only hidden roots in parked peers, and deterministic
  completed-but-unjoined Thread result and thrown exception roots, and
  deterministic cleanup count/sum delivery plus unregister-token suppression;
  the lifecycle
  profile adds deterministic termination storms, script Worker/thread overlap
  plus simple-import, diamond-shaped, and fanout/rejoin module Worker/thread
  overlap over retained `SharedArrayBuffer` storage, Worker/thread/finalization
  scheduling on one retained SAB, Worker termination interleaved with exact
  shared-realm finalization cleanup on a retained SAB, Worker termination while
  top-level failure tears down parked shared-realm `Thread`s, pending
  `asyncJoin` rejection reactions, and already-ready cleanup jobs on the same
  retained SAB, module Worker termination with the same shared-realm
  teardown/reaction/cleanup oracle, exact FIFO drain/drop ordering for mixed
  script and module Worker `close` /
  `terminate` / `postMessage` lifecycles, plus worker
  handler-exception recovery, Worker handler-exception recovery composed with
  shared-realm Thread finalization cleanup on one retained SAB, and module
  Worker handler-exception recovery composed with the same retained-SAB cleanup
  oracle,
  `Thread.restrict` lifecycle isolation plus `Thread.restrict`-owned
  `FinalizationRegistry` cleanup after owner-thread exit,
  Thread exception identity through
  `join()` / `asyncJoin()` while property and condition waiters are parked,
  thread-returned typed-array `waitAsync` promise
  assimilation through `join()` / `asyncJoin()` while waiters are parked,
  typed-array `waitAsync` settlement interleaved with `asyncJoin` reactions and
  exact `FinalizationRegistry` cleanup delivery,
  `Condition.asyncWait` reacquire delivery interleaved with `join()` /
  `asyncJoin()` reactions and exact `FinalizationRegistry` cleanup delivery,
  teardown termination with pending `asyncJoin` rejection reactions and
  child-owned typed-array `waitAsync` tickets that must be abandoned before the
  child exits,
  teardown termination while property `waitAsync` timeout compaction, async
  condition reacquire, a pending `asyncJoin` rejection reaction, and
  already-ready `FinalizationRegistry` cleanup jobs share the same realm turn,
  deterministic `Lock.asyncHold()` barging where a sync hold legally overtakes
  a queued no-fn async ticket before `await` delivers its release function,
  Promise reaction queue churn from with-fn `Lock.asyncHold`, no-fn
  release-function delivery, typed-array `waitAsync`, `Thread.asyncJoin`, and
  exact `FinalizationRegistry` cleanup,
  creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage that survives the
  creating Thread's exit, sibling-thread reads, GC pressure, and post-creator
  `ArrayBuffer.transfer()`, plus child-created SAB/ArrayBuffer storage crossing
  isolated Worker structured-clone after the creator Thread exits,
  cross-thread `FinalizationRegistry` cleanup count/sum oracles, cleanup
  delivery interleaved with `join()` / `asyncJoin()` and unregister-token
  suppression, cleanup delivery after parked property/condition waiters resume,
  `ThreadLocal` isolation across normal, throwing, nested, and async-joined
  thread lifecycles, and `ThreadLocal` values registered with
  `FinalizationRegistry` across park/resume/clear/join cleanup lifecycles with
  exact cleanup count/sum delivery after quiescent collection, plus
  parent-created child `Thread`s whose `asyncJoin()` promises outlive the
  parent Thread's local queue before child release, nested `ThreadLocal` root
  checks, and exact finalization cleanup after both thread layers exit.
  Keep extending the fuzzers toward more teardown and cross-realm scheduling
  oracles.
- **Reference-only PR-249 files** - promote only when the needed engine feature
  exists, especially WebAssembly/JIT shell hooks, deep recursive VM-stack
  behavior, heap caps/OOM semantics, and unsupported `$vm` controls.
  `zig build threads-reference-audit` keeps every non-promoted file tied to one
  of those blocker categories, and
  `python3 tools/threads-reference-audit.py --probe-candidates` lists the
  closest focused `-Dthreads-case=...` probes before any allowlist promotion.

The [TC39 structs proposal](https://github.com/tc39/proposal-structs) remains a
tracked future layer. Shared structs, `Atomics.Mutex`, and
`Atomics.Condition` should build on this existing worker, structured clone,
`SharedArrayBuffer`, Atomics, and shared-realm thread foundation.

## License

MIT — see [LICENSE](./LICENSE).
