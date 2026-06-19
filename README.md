# zig-js

A **JavaScript engine written in pure Zig**, with a **JavaScriptCore C-API-compatible** surface. No JSC, no V8, no external C libraries — just Zig.

`zig-js` is a small, embeddable engine for Zig applications, tools, and runtimes that want to own their JS stack. Use it directly as a Zig module, or link it in place of `JavaScriptCore.framework` when a host already targets the JSC C API.

It tracks the ECMAScript spec closely and is graded against the **real [tc39/test262](https://github.com/tc39/test262) corpus** — currently **43,386 / 47,930 (90.5%)** of the scored "can we run it" tests pass. See [Conformance](#conformance) for the full breakdown.

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
| **valid** | can we run the program? (scored corpus) | **43,386 / 47,930 (90.5%)** |
| negative | do we reject invalid input? (early errors — partial) | 3,305 / 4,668 (70.8%) |

Of the valid corpus: **45 parse failures**, **4,499 runtime failures**, **0 host failures**. The runner currently skips 579 tests that need more harness work (top-level-await modules, some async-harness protocols, unloadable includes). Remaining valid failures concentrate in `intl402` (CLDR data), `Temporal` edge cases, `language`, `staging`, and Annex B.

### Per area (valid)

| area | passing | area | passing |
| ---- | ------: | ---- | ------: |
| `language` | 17,682 / 19,070 (92.7%) | `Object` | 3,411 / 3,411 (100%) |
| `Array` | 3,056 / 3,081 (99.2%) | `RegExp` | 1,687 / 1,687 (100%) |
| `String` | 1,223 / 1,223 (100%) | `TypedArray` | 1,446 / 1,446 (100%) |
| `TypedArrayConstructors` | 738 / 738 (100%) | `Uint8Array` | 70 / 70 (100%) |
| `Map` | 204 / 204 (100%) | `Set` | 383 / 383 (100%) |
| `BigInt` | 77 / 77 (100%) | `Symbol` | 98 / 98 (100%) |
| `Boolean` | 51 / 51 (100%) | `Math` | 327 / 327 (100%) |
| `DataView` | 561 / 561 (100%) | `Number` | 340 / 340 (100%) |
| `WeakSet` | 85 / 85 (100%) | `WeakMap` | 141 / 141 (100%) |
| `WeakRef` | 29 / 29 (100%) | `FinalizationRegistry` | 47 / 47 (100%) |
| `Temporal` | 3,622 / 4,603 (78.7%) | `intl402` | 2,375 / 3,341 (71.1%) |
| `annexB` | 965 / 1,071 (90.1%) | `staging` | 742 / 1,028 (72.2%) |
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

Latest focused `test/intl402` worker checkpoint: **2,375 / 3,341 (71.1%)**, up **+56** from the previous focused checkpoint of 2,319 / 3,341 after the Temporal ZonedDateTime calendar-preserving `with()` fixes.

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

- **Context lifecycle** — `JSGlobalContextCreate`/`Release`/`Retain`, `JSContextGetGlobalObject`, `JSEvaluateScript`, `JSGarbageCollect`.
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
zig build threads-test          # runs the green WebKit PR-249 threads corpus (209/209)
zig build test262               # runs the real tc39/test262 corpus, prints pass %
zig build test262 -Dtest262=DIR # …with an explicit corpus root
zig build bench                 # times the bytecode VM against the tree-walker
```

The test262 corpus is vendored as the `test262/` git submodule (`git submodule update --init`); `zig build test262` uses it by default and skips cleanly if it isn't present. For speed it runs `ReleaseFast` under subprocess isolation, so a single pathological test can't abort the run.

## Multithreading roadmap

`Context.createWith(.{ .enable_threads = true })` now exposes an experimental shared-realm `Thread`, `Lock`, `Condition`, `ThreadLocal`, and property-`Atomics.wait` surface. That path is serialized by a VM lock and is tracked against the vendored WebKit PR-249 threads corpus; the current green allowlist is **209/209**.

That is a useful host-threading layer, but full JavaScript multithreading needs a broader agent model:

- **Agent boundaries** — make ordinary `Context` ownership explicit, keep C-API handles agent-local, and define which values can cross threads.
- **Worker agents** — one `Context` per OS thread with its own global object, realms, job queues, allocator state, module loader hooks, cancellation, and teardown.
- **Structured clone & transfer** — implement `structuredClone`, message passing, ArrayBuffer transfer/detach, and host hooks for worker lifecycle.
- **Shared-memory baseline** — finish `SharedArrayBuffer`, typed-array views over shared storage, `Atomics`, `Atomics.wait`/`notify`, and the real test262 `$262.agent` harness.
- **Scheduler & queues** — keep per-agent microtask queues separate from host task queues, define blocking behavior for waits, and preserve deterministic promise-job ordering.
- **Heap & lifetime model** — replace or contain the arena before shared lifetimes leak between agents; a future GC needs roots, write barriers, and cross-agent ownership rules.
- **Concurrency tests** — grow the PR-249 corpus, then stress transfer/detach races, shared typed-array atomics, worker teardown, and host callback reentrancy before optimizing.

The [TC39 structs proposal](https://github.com/tc39/proposal-structs) is worth tracking. Fixed-layout structs, shared structs, `Atomics.Mutex`, and `Atomics.Condition` could become a natural data model for parallel JS because shared structs are designed to cross agents without copying. They should layer on top of the worker, structured clone, `SharedArrayBuffer`, and `Atomics` foundation rather than replace it.

## License

MIT — see [LICENSE](./LICENSE).
