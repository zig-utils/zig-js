# zig-js

A **homegrown JavaScript engine in pure Zig** — and a **drop-in replacement for the
JavaScriptCore C API**. No JSC, no V8, no external C libraries.

It exists to give [`craft`](../../Tools/craft)'s "Loom" web engine and
[`Home/lang`](../../Home/lang)'s Bun-port runtime a single, dependency-free JS engine they
both own. lang's `packages/runtime/src/jsc/extern_fns.zig` declares the system JavaScriptCore
C API; link `zig-js` instead and those call sites work unchanged.

> Status: **early v1.** A correct tree-walking interpreter over a modern expression/statement
> subset — including functions, closures, recursion, and arrow functions — plus the JSC C-API
> surface lang consumes, and a test262-style conformance runner (`zig build conformance`, 18/18).
> Next milestones: `throw`/`try`/`catch`, object/array literals + member access, real test262
> ingestion, then a bytecode VM and a GC. See craft's `docs/architecture/web-engine-plan.md`.

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
`JSObjectCallAsFunction`, `JSObjectMakeFunctionWithCallback`, `JSObjectIsFunction`), and
strings (`JSStringCreateWithUTF8CString`, `JSStringRetain/Release`, `JSStringGetLength`,
`JSStringGetUTF8CString`). `JSObjectMakeDeferredPromise` / `JSObjectCallAsConstructor` raise a
`NotImplemented` exception until the object/function milestones land.

## Language subset (v1)

- Literals: number (int/float/hex/exp), string (`'…'` / `"…"` with escapes), `true`/`false`/`null`/`undefined`
- Variables: `var` / `let` / `const`, assignment, identifier reference, lexical scoping
- Operators: `+ - * / % **`, comparisons (`< <= > >= == != === !==`), logical (`&& ||`),
  unary (`- + ! typeof`), ternary `?:`, grouping, JS `+` string concatenation
- Functions: declarations, expressions, arrow functions, calls, `return`, closures, recursion
- Statements: expression statements, `if`/`else`, `while`, blocks; program returns the
  completion value (what `JSEvaluateScript` hands back)

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
zig build              # builds libzig-js.a (the JSC drop-in)
zig build test         # runs unit + C-API tests (23/23)
zig build conformance  # runs the test262-style suite, prints pass % (18/18)
```

Requires Zig **0.17.0-dev**.

## License

MIT — see [LICENSE](./LICENSE).
