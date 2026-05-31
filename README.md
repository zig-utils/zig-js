# zig-js

A **homegrown JavaScript engine in pure Zig** — and a **drop-in replacement for the
JavaScriptCore C API**. No JSC, no V8, no external C libraries.

It exists to give [`craft`](../../Tools/craft)'s "Loom" web engine and
[`Home/lang`](../../Home/lang)'s Bun-port runtime a single, dependency-free JS engine they
both own. lang's `packages/runtime/src/jsc/extern_fns.zig` declares the system JavaScriptCore
C API; link `zig-js` instead and those call sites work unchanged.

> Status: **maturing.** A spec-tracking engine with two execution tiers — a tree-walking
> interpreter (the correctness oracle) and a suspendable stack **bytecode VM** that lowers the
> hot subset *and* generators / async functions / async generators. It runs the **real
> tc39/test262 corpus** against the upstream harness (`sta.js` + `assert.js` + `includes:`):
> `zig build test262` currently passes **VALID 26,071 / 30,486 (85.5%)** across `language/`
> (including ES modules + top-level await) and the implemented built-in subtrees, and
> `zig build conformance` keeps a 33/33 always-green smoke suite.
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
> fallback for not-yet-lowered constructs. See craft's `docs/architecture/web-engine-plan.md`.

## Conformance progress

Measured by `zig build test262` against the pinned [tc39/test262](https://github.com/tc39/test262)
submodule, over `language/` plus the implemented built-in subtrees. The score is split on two
honest axes — **valid** tests measure whether we can *run* a program; **negative** tests measure
*strictness* (rejecting invalid input). Mixing them flatters a weak parser (it "passes" negatives by
failing to parse valid code too), so they're kept apart:

| axis | meaning | passing |
| ---- | ------- | ------: |
| **valid** | can we run the program? | **25,977 / 30,486 (85.2%)** |
| negative | do we reject invalid input? (early errors — partial) | 1,704 / 4,455 (38.2%) |

Per area (valid):

| area | passing | | area | passing |
| ---- | ------: | - | ---- | ------: |
| `language` (incl. modules) | 16,097 / 19,104 (84.3%) | | `Math` | 299 / 327 (91.4%) |
| `Object` | 2,865 / 3,411 (84.0%) | | `Date` | 466 / 594 (78.5%) |
| `Array` | 2,319 / 3,081 (75.3%) | | `Function` | 401 / 509 (78.8%) |
| `String` | 850 / 1,223 (69.5%) | | `Promise` | 493 / 677 (72.8%) |
| `Number` | 270 / 340 (79.4%) | | `Map`/`Set` | 75–78% |

> `zig build test262` prints the per-subtree pass rate plus a `parse-fail` / `runtime-fail` split so
> the work stays data-driven. The runtime drives the **async** corpus (the `$DONE` protocol) and the
> **ES-module** corpus (parse → link → dependency-order evaluation, live bindings, live namespace
> objects, top-level await), and scores both. The biggest remaining gaps are whole subsystems:
> **TypedArray**/**BigInt**, the `$262` host hooks (`createRealm`), advanced RegExp, and full Unicode
> case mapping. Bump the corpus with `git submodule update --remote test262`.

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
exception until promises land.

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
