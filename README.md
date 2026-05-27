# zig-js

A **homegrown JavaScript engine in pure Zig** — and a **drop-in replacement for the
JavaScriptCore C API**. No JSC, no V8, no external C libraries.

It exists to give [`craft`](../../Tools/craft)'s "Loom" web engine and
[`Home/lang`](../../Home/lang)'s Bun-port runtime a single, dependency-free JS engine they
both own. lang's `packages/runtime/src/jsc/extern_fns.zig` declares the system JavaScriptCore
C API; link `zig-js` instead and those call sites work unchanged.

> Status: **early v1.** A correct tree-walking interpreter over a broad expression/statement
> subset — functions, closures, arrows, objects, arrays, member access, `this`, `new`,
> constructors, `instanceof`, `throw`/`try`/`catch`/`finally`, `for`/`while`/`break`/`continue`,
> `++`/`--` and compound assignment — plus the JSC C-API surface lang consumes. It runs the
> **real WebKit test262 corpus**: `zig build test262` currently passes **~25% of the `language/`
> tests** (3,590 / 14,385) via a subset harness shim, and `zig build conformance` keeps a 33/33
> always-green smoke suite.
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
submodule, over the `language/` subtrees (excluding tests skipped for ES modules, async, or extra
harness `includes:`). The score is split on two honest axes — **valid** tests measure whether we
can *run* a program; **negative** tests measure *strictness* (rejecting invalid input). Mixing them
flatters a weak parser (it "passes" negatives by failing to parse valid code too), so they're kept
apart:

| axis | meaning | passing |
| ---- | ------- | ------: |
| **valid** | can we run the program? | **789 / 10,909 (7.2%)** |
| negative | do we reject invalid input? (early errors — mostly unimplemented, so this is largely "we couldn't parse it either") | 2,848 / 3,476 (81.9%) |

> The valid number is the real one, and it's honest about how far there is to go. Of the ~10k
> failing valid tests, **~8,300 fail at parse time** (missing grammar: template literals, `class`,
> `for-of`/`for-in`, destructuring, spread/rest, generators, regex literals, …) and **~1,800 at run
> time** (missing builtins: `Object`/`Array`/`String`/`Number`/`Math`/`JSON`/`RegExp`). So the
> conformance lever is the parser first, then builtins — `zig build test262` prints the parse-fail
> vs runtime-fail split so the work stays data-driven. Bump the corpus with
> `git submodule update --remote test262`.

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

## Language subset (v1)

- Literals: number (int/float/hex/exp), string (`'…'` / `"…"` with escapes), `true`/`false`/`null`/`undefined`,
  object literals `{ … }` (incl. shorthand) and array literals `[ … ]`
- Variables: `var` / `let` / `const`, assignment, compound assignment (`+= -= *= /= %=`),
  identifier reference, lexical scoping
- Operators: `+ - * / % **`, comparisons (`< <= > >= == != === !==`), logical (`&& ||`),
  unary (`- + ! typeof`), `++`/`--` (prefix & postfix), ternary `?:`, `instanceof`, grouping,
  member access (`.x`, `[expr]`), JS `+` string concatenation
- Functions: declarations, expressions, arrow functions, calls, method calls (with `this`),
  `return`, closures, recursion; `new`, user constructors, and the `Error`-family builtins
- Objects/arrays: property get/set, array index/`length`, `push`/`pop`, comma-join `toString`
- Statements: expression statements, `if`/`else`, `while`, `for`, `break`/`continue`,
  `throw`/`try`/`catch`/`finally`, blocks; the program returns the completion value (what
  `JSEvaluateScript` hands back)

## Architecture

```
source ─► lexer ─► parser (Pratt) ─► AST ─► tree-walk interpreter ─► Value
                                                     │
                                          c_api.zig (JSC drop-in exports)
```

- `src/value.zig` — `Value` union + ToBoolean/ToNumber/ToString/typeof, strict/loose equality
- `src/lexer.zig` — single-pass tokenizer
- `src/ast.zig` — unified expression/statement node
- `src/parser.zig` — recursive-descent + precedence climbing
- `src/interpreter.zig` — tree-walking evaluator + flat environment
- `src/context.zig` — engine instance (arena + persistent global env)
- `src/jsstring.zig` — refcounted `JSStringRef` backing
- `src/c_api.zig` — the exported JavaScriptCore C-API symbols
- `src/root.zig` — `@import("js")` entry point

## Build & test

```sh
zig build                       # builds libzig-js.a (the JSC drop-in)
zig build test                  # runs unit + C-API tests (33/33)
zig build conformance           # runs the always-green smoke suite (33/33)
zig build test262               # runs the real tc39/test262 corpus, prints pass %
zig build test262 -Dtest262=DIR # …with an explicit corpus root
zig build bench                 # times the bytecode VM against the tree-walker
```

`zig build test262` defaults its corpus root to `../../WebKit/JSTests/test262` (the sibling
WebKit checkout) and skips cleanly if it isn't present. Requires Zig **0.17.0-dev**.

## License

MIT — see [LICENSE](./LICENSE).
