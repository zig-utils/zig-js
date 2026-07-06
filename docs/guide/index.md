---
title: What is zig-js?
description: A JavaScript engine written in pure Zig — standalone interpreter and JavaScriptCore C-API-compatible subset.
---

# What is zig-js?

**zig-js** is a JavaScript engine written from scratch in [Zig](https://ziglang.org), with **no external C dependencies**. It is two things at once:

- a **standalone JavaScript interpreter** — a tree-walking evaluator backed by a tiered bytecode VM; and
- a **JavaScriptCore C-API-compatible subset** — link `libzig-js.a` in place of the system `JavaScriptCore.framework` when your host uses the implemented public C-API surface.

It is built as a general embeddable JavaScript engine for Zig applications, language runtimes, tools, and hosts that want to own their JS stack.

## Status

zig-js is an early but capable v1: a correct tree-walking interpreter over a broad language subset, a tier-1 bytecode VM, object shapes, and inline caches. It is scored continuously against the **real** pinned tc39/test262 corpus.

<Test262Progress :stats="data.test262" />

## What's implemented

::: tip Language
`var`/`let`/`const` with TDZ · full operator set incl. `**`, bitwise, `??`, optional chaining · `if`/`while`/`do`/`for`/`for-of`/`for-in`/`switch` · functions, arrows, closures, `this`/`new` · `class` with inheritance, getters/setters, private fields, static blocks · destructuring, spread/rest, template literals · `try`/`catch`/`finally`.
:::

::: tip Built-ins
`Object`, `Array`, `String`, `Number`, `Boolean`, `Math`, `JSON`, `Map`, `Set`, `WeakMap`, `WeakSet`, `Symbol`, `Function`, `Date`, the `Error` family, `Promise`, `Proxy`, `Reflect`, and `RegExp` — including modern surface like ES2024 `Set` operations, `Object.groupBy`, `Array` hole/sparse semantics, and well-known symbols.
:::

::: warning Scope caveat
The configured test262 runner is green with zero skipped tests and zero excluded files. Proper-tail-call coverage, dynamic-import catch-target behavior, import-defer async-module coverage, and module+async/top-level-await graph ordering are scored. Two non-normative SpiderMonkey staging files are removed from the configured corpus because their pending expectations contradict stronger Annex B coverage.
:::

## Next steps

- [Building & Running](/guide/building) — get the engine compiled and run the suite.
- [Architecture](/architecture) — the tiered execution model and the source map.
- [Conformance](/conformance) — how test262 is run and scored.
- [JavaScriptCore C-API](/api) — embed zig-js in an existing app.
