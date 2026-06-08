# zig-js

A **homegrown JavaScript engine in pure Zig** and a **JavaScriptCore C API-compatible**
runtime library. No JSC, no V8, no external C libraries.

`zig-js` is meant to be a small, embeddable JavaScript engine for Zig applications, tools,
experiments, and runtimes that want to own their JS stack. It can be imported directly as a Zig
module or linked in place of `JavaScriptCore.framework` when a host already targets the
JavaScriptCore C API.

> Status: **maturing.** A spec-tracking engine with two execution tiers: a tree-walking
> interpreter (the correctness oracle) and a suspendable stack **bytecode VM** that lowers the
> hot subset plus generators, async functions, and async generators. It runs the **real
> tc39/test262 corpus** against the upstream harness (`sta.js`, `assert.js`, and `includes:`).
> The latest full run passes **VALID 40,671 / 47,928 (84.9%)**, with **146 parse failures**,
> **7,111 runtime failures**, **0 host failures**, and **NEGATIVE 3,213 / 4,668 (68.8%)**.
> `zig build conformance` keeps a 33/33 always-green smoke suite. Some flagged suites are still
> skipped by the runner while module, async-harness, and include-loading support is completed.
>
> Implemented language + runtime: closures, arrow functions, **classes** (fields, private members,
> getters/setters, `static`, `super`, derived constructors), **destructuring** (array/object,
> defaults, rest), **spread/rest**, **template literals** + tagged templates, optional chaining,
> **generators** + `yield*` delegation, **async/await**, **async generators** + `for await`,
> **Promises** (combinators, subclassing/species, microtask ordering), **ES modules** (parse +
> link + live bindings; see below), `with`, `eval`, block scoping + TDZ, `Symbol` + well-known
> symbols, **Proxy/Reflect**, and the built-in library: `Object`, `Array` (incl. holes/sparse,
> freeze/seal), `String` (+ a homegrown `RegExp` backed by [`zig-regex`](../zig-regex)), `Number`,
> `Boolean`, `Math`, `JSON`, `Map`/`Set`/`WeakMap`/`WeakSet`, `Date`, `Error` family — each
> brand-checking and attribute-faithful enough to satisfy test262's `propertyHelper`.
>
> **Performance tiers** (each gated by test262, measured by `zig build bench`):
>
> | tier | what | status | bench vs tree-walk |
> | ---- | ---- | ------ | ------------------ |
> | 0 | tree-walk interpreter | ✅ | 1× (baseline) |
> | 1 | **stack bytecode VM** — lowers nearly the whole language (objects, arrays, members, `new`, methods, `++`, `instanceof`); only `throw`/`try` falls back | ✅ | ~1.1× |
> | 2 | **slot-allocated locals + frame-linked closures** — params/locals resolved to a flat frame array at compile time; globals stay by name | ✅ | 1.3–1.85× |
> | 3 | **object shapes (hidden classes) + inline caches** — shared shape transition tree + flat slots; monomorphic IC per property site | ✅ | **1.6–1.7×** across the board |
> | 4 | NaN-boxed values | next | — |
> | 5 | generational GC (replaces the arena) | planned | — |
> | 6 | baseline → optimizing JIT | planned | — |
>
> Tier-2 nearly doubled compute/call-heavy code; tier-3 brought object-property churn from the
> 1.33× laggard up to 1.73× (objects no longer allocate a per-instance hashmap, and repeat
> property access is an inline-cache hit). The tree-walker remains the correctness oracle and the
> fallback for not-yet-lowered constructs.

## Conformance progress

Measured by `zig build test262` against the pinned [tc39/test262](https://github.com/tc39/test262)
submodule. The score is split on two honest axes: **valid** tests measure whether we can *run* a
program; **negative** tests measure *strictness* (rejecting invalid input). Mixing them flatters a
weak parser because it can "pass" negatives by failing to parse valid code too, so they're kept
apart:

| axis | meaning | passing |
| ---- | ------- | ------: |
| **valid** | can we run the program? (scored corpus) | **40,671 / 47,928 (84.9%)** |
| negative | do we reject invalid input? (early errors - partial) | 3,213 / 4,668 (68.8%) |

The scored corpus currently skips 581 tests that require runner work for modules, async harness
protocols, or unloadable includes. The valid failures are concentrated in partially implemented
subsystems such as `intl402`, Annex B behavior, Temporal edge cases, and the remaining built-in
surface.

Per area (valid):

| area | passing | area | passing |
| ---- | ------: | ---- | ------: |
| `language` | 17,096 / 19,070 (89.6%) | `Object` | 3,277 / 3,411 (96.1%) |
| `Array` | 2,738 / 3,081 (88.9%) | `RegExp` | 1,465 / 1,687 (86.8%) |
| `String` | 1,075 / 1,223 (87.9%) | `TypedArray` | 1,411 / 1,446 (97.6%) |
| `TypedArrayConstructors` | 692 / 738 (93.8%) | `Uint8Array` | 70 / 70 (100%) |
| `Map` | 204 / 204 (100%) | `Set` | 363 / 383 (94.8%) |
| `BigInt` | 77 / 77 (100%) | `Symbol` | 98 / 98 (100%) |
| `Boolean` | 51 / 51 (100%) | `Math` | 327 / 327 (100%) |
| `DataView` | 561 / 561 (100%) | `Number` | 340 / 340 (100%) |
| `WeakSet` | 85 / 85 (100%) | `WeakMap` | 141 / 141 (100%) |
| `WeakRef` | 25 / 29 (86.2%) | `FinalizationRegistry` | 40 / 47 (85.1%) |
| `Temporal` | 3,209 / 4,603 (69.7%) | `intl402` | 1,427 / 3,341 (42.7%) |
| `annexB` | 919 / 1,071 (85.8%) | `staging` | 665 / 1,028 (64.7%) |
| `SharedArrayBuffer` | 88 / 104 (84.6%) | `ArrayBuffer` | 196 / 221 (88.7%) |
| `Atomics` | 308 / 388 (79.4%) | — | — |
| `SuppressedError` | 22 / 22 (100%) | `ThrowTypeError` | 14 / 14 (100%) |
| `AbstractModuleSource` | 8 / 8 (100%) | `AggregateError` | 25 / 25 (100%) |
| `parseFloat` | 54 / 54 (100%) | `parseInt` | 55 / 55 (100%) |
| `decodeURI` | 55 / 55 (100%) | `decodeURIComponent` | 56 / 56 (100%) |
| `encodeURI` | 31 / 31 (100%) | `encodeURIComponent` | 31 / 31 (100%) |
| `AsyncIteratorPrototype` | 9 / 9 (100%) | `eval` | 10 / 10 (100%) |
| `global` | 29 / 29 (100%) | `Function` | 509 / 509 (100%) |
| `Proxy` | 310 / 310 (100%) | `Reflect` | 153 / 153 (100%) |

> `zig build test262` prints each subtree's pass rate plus `parse-fail`, `runtime-fail`, and
> `host-fail` counts so the work stays data-driven. Bump the corpus with
> `git submodule update --remote test262`.

## Used By

- [home-lang/craft](https://github.com/home-lang/craft)

## Two ways to use it

### 1. As a Zig module

```zig
const js = @import("js");

const ctx = try js.Context.create(allocator);
defer ctx.destroy();
const v = try ctx.evaluate("let x = 40; x + 2");
// v == .{ .number = 42 }
```

### 2. As a JavaScriptCore C-API drop-in

Link `libzig-js.a` in place of `JavaScriptCore.framework`. The exported symbols match
Apple's `<JavaScriptCore/JSValueRef.h>` / `<JSObjectRef.h>`:

```c
JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
JSStringRef script = JSStringCreateWithUTF8CString("1 + 1");
JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);
double n = JSValueToNumber(ctx, result, NULL); // 2.0
```

Implemented C-API symbols: context lifecycle (`JSGlobalContextCreate/Release/Retain`,
`JSContextGetGlobalObject`, `JSEvaluateScript`, `JSGarbageCollect`), value inspection
(`JSValueGetType`, `JSValueIs*`, `JSValueIsEqual`/`StrictEqual`), constructors
(`JSValueMake*`), coercion (`JSValueTo*`, `JSValueProtect/Unprotect`), objects
(`JSObjectMake`, `JSObjectMakeArray`, `JSObjectGet/SetProperty`, `JSObjectGetPropertyAtIndex`,
`JSObjectCallAsFunction`, `JSObjectCallAsConstructor`, `JSObjectMakeFunctionWithCallback`,
`JSObjectIsFunction`/`IsConstructor`), and strings (`JSStringCreateWithUTF8CString`,
`JSStringRetain/Release`, `JSStringGetLength`, `JSStringGetUTF8CString`).
`JSObjectCallAsFunction`/`CallAsConstructor` drive the interpreter, so JS functions and the
built-in `Error` constructors are callable across the C boundary; thrown JS values surface as
the C-API `exception` out-param. `JSObjectMakeDeferredPromise` raises a `NotImplemented`
exception until deferred-promise C API plumbing lands.

## Language coverage

- **Literals & operators**: numbers (int/float/hex/octal/binary/exp, `ToString` per spec), strings
  (full escape set incl. `\u{…}`), `true`/`false`/`null`/`undefined`, objects (shorthand, computed
  keys, getters/setters, spread), arrays (incl. holes), regex literals, template literals + tagged
  templates; the full operator set incl. `**`, `??`, `?.`, `&&=`/`||=`/`??=`, bitwise/shift,
  `in`/`instanceof`/`typeof`/`delete`/`void`, comma.
- **Bindings & scope**: `var`/`let`/`const`, block scoping + TDZ, destructuring (array/object,
  defaults, rest) in declarations, parameters, and assignment; `with`.
- **Functions**: declarations/expressions (incl. named-expression self-binding), arrows, default/
  rest params, `arguments`, closures, `new`, `new.target`, getters/setters; `Function.prototype`
  `call`/`apply`/`bind`/`toString`.
- **Classes**: fields, private members + methods, `static` members + blocks, accessors, `super`
  (calls and member access), derived constructors, `extends`.
- **Generators & async**: `function*` + `yield`/`yield*` (with throw/return delegation), `async`
  functions + `await`, `async function*` + `for await … of`, all driven on the suspendable VM.
- **Control flow**: `if`/`else`, `while`/`do…while`, `for`/`for-in`/`for-of`, `switch`, labels,
  `break`/`continue`, `throw`/`try`/`catch`/`finally`.
- **Modules**: `import`/`export` (default, named, namespace, re-export, `export *`), graph linking
  with live bindings and live namespace objects (see *Conformance progress* for scoring status).
- **Built-ins**: `Object`, `Function`, `Array`, `String` + `RegExp`, `Number`, `Boolean`, `Math`,
  `JSON`, `Symbol` (+ well-known symbols), `Map`/`Set`/`WeakMap`/`WeakSet`, `Promise`, `Date`,
  `Error` family, `Proxy`/`Reflect`, `globalThis`, `eval`.

## Architecture

```
                          ┌─► compiler ─► bytecode ─► VM ──┐  (hot subset + generators/async)
source ─► lexer ─► parser ─┤                                ├─► Value
              (AST)        └─► tree-walk interpreter ───────┘  (oracle + fallback)
                                                     │
                                          c_api.zig (JSC drop-in exports)
```

Top-level code compiles to bytecode and runs on the VM; any construct the compiler can't yet lower
falls back to the tree-walker, so behavior is identical either way. Generators and async functions
are *only* on the VM (their bodies must suspend/resume), driven by the microtask queue.

- `src/value.zig` — `Value` union + ToBoolean/ToNumber/ToString/typeof, equality, `Object` (shapes,
  per-index attrs, accessors, array elements/holes)
- `src/lexer.zig` — single-pass tokenizer
- `src/ast.zig` — unified expression/statement/module node
- `src/parser.zig` — recursive-descent + precedence climbing (`parseProgram` / `parseModule`)
- `src/interpreter.zig` — tree-walking evaluator, environments, and the built-in library
- `src/compiler.zig` — AST → stack bytecode (functions, generators, async)
- `src/bytecode.zig` — instruction set + chunk/function templates
- `src/vm.zig` — the suspendable bytecode VM (frames, generators, async drivers)
- `src/shape.zig` — hidden-class (shape) transition tree
- `src/promise.zig` — Promise state machine + microtask queue
- `src/context.zig` — engine instance (arena, persistent global env, module loader/linker)
- `src/jsstring.zig` — refcounted `JSStringRef` backing
- `src/c_api.zig` — the exported JavaScriptCore C-API symbols
- `src/root.zig` — `@import("js")` entry point

## Multithreading roadmap

Today, a `Context` is single-thread-affine: the interpreter, VM, global object graph, environments,
microtask queue, and arena-backed allocation model assume one mutating thread. The first
multithreaded target should be isolated JavaScript agents, not shared mutable ordinary objects.

To get there:

- **Thread-affinity contract**: make `Context` ownership explicit, reject accidental cross-thread
  use, and document which C API handles are local to an agent.
- **Worker agents**: run one `Context` per OS thread with its own global object, realms, job queues,
  allocator state, and module loader hooks.
- **Structured clone and transfer**: implement `structuredClone`, message passing, ArrayBuffer
  transfer/detach, and the host hooks needed for worker lifecycle and cancellation.
- **Shared memory baseline**: finish `SharedArrayBuffer`, typed-array views over shared storage,
  `Atomics`, `Atomics.wait`/`notify`, and the real test262 `$262.agent` harness.
- **Heap and lifetime model**: replace or contain the current arena model before shared lifetimes
  leak between agents. A future GC needs clear rooting, write-barrier, and cross-agent ownership
  rules.
- **Scheduler and queues**: separate per-agent microtask queues from host task queues, define
  blocking behavior for waits, and keep promise jobs deterministic inside each agent.
- **Concurrency tests**: add stress tests for transfer/detach races, shared typed-array atomics,
  worker teardown, and host callback reentrancy before optimizing.

The [TC39 structs proposal](https://github.com/tc39/proposal-structs) is worth tracking here. It is
currently Stage 2 and proposes fixed-layout structs, shared structs, and higher-level
synchronization primitives (`Atomics.Mutex` and `Atomics.Condition`). Shared structs are especially
relevant because they are designed to be communicated between agents without copying while only
referencing primitives or other shared structs. That makes them a good future data model for
parallel JS, but they should come after the baseline worker, structured clone, `SharedArrayBuffer`,
and `Atomics` stack is correct.

## Build & test

```sh
zig build                       # builds libzig-js.a (the JSC drop-in)
zig build test                  # runs the unit + C-API test suite
zig build conformance           # runs the always-green smoke suite (33/33)
zig build test262               # runs the real tc39/test262 corpus, prints pass %
zig build test262 -Dtest262=DIR # …with an explicit corpus root
zig build bench                 # times the bytecode VM against the tree-walker
```

The test262 corpus is vendored as the `test262/` git submodule (`git submodule update --init`),
which `zig build test262` uses by default and skips cleanly if it isn't present. For speed it runs
`ReleaseFast` (`zig build test262 -Doptimize=ReleaseFast`) under subprocess isolation, so a single
pathological test can't abort the run. Requires Zig **0.17.0-dev**.

## License

MIT — see [LICENSE](./LICENSE).
