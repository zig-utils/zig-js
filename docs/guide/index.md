---
title: What is zig-js?
description: A JavaScript engine written in pure Zig — standalone interpreter and JavaScriptCore-shaped C API subset.
---

# What is zig-js?

**zig-js** is a JavaScript engine written from scratch in [Zig](https://ziglang.org), with **no external C dependencies**. It is two things at once:

- a **standalone JavaScript interpreter** — a tree-walking evaluator backed by a tiered bytecode VM; and
- a **JavaScriptCore-shaped C API subset** — link `libzig-js.a` in place of the system `JavaScriptCore.framework` when your host uses the implemented public C API surface, while the pre-stabilization API keeps room to drop inert compatibility shims.

It is built as a general embeddable JavaScript engine for Zig applications, language runtimes, tools, and hosts that want to own their JS stack.

## Status

zig-js runs a correct tree-walking interpreter as its semantic baseline, a suspendable bytecode VM, object shapes with inline caches, and native baseline and optimizing tiers above them. Alongside the language it implements a precise tracing garbage collector, GIL-free shared-realm threading, a pure-Zig WebAssembly runtime, and `Intl` / `Temporal` over checked-in CLDR and IANA data. It is scored continuously against the **real** pinned tc39/test262 corpus, and APIs remain pre-stabilization.

<Test262Progress :stats="data.test262" />

## What's implemented

::: tip Language
`var`/`let`/`const` with TDZ · full operator set incl. `**`, bitwise, `??`, optional chaining · `if`/`while`/`do`/`for`/`for-of`/`for-in`/`for await`/`switch` · functions, arrows, closures, `this`/`new`, proper tail calls · `class` with inheritance, getters/setters, private fields and methods, static blocks · generators, async functions, async generators · modules with dynamic `import()`, `import.meta`, and top-level `await` · destructuring, spread/rest, template literals · `using` / `await using` · `try`/`catch`/`finally`. Full detail: [Language](/features/language).
:::

::: tip Built-ins
`Object`, `Array`, `String`, `Number`, `Boolean`, `BigInt`, `Math`, `JSON`, `Map`, `Set`, `WeakMap`, `WeakSet`, `WeakRef`, `FinalizationRegistry`, `Symbol`, `Function`, `Date`, the `Error` family, `Promise`, `Proxy`, `Reflect`, `Iterator` helpers, and `RegExp` — including modern surface like ES2024 `Set` operations, `Object.groupBy`, `Array` hole/sparse semantics, and well-known symbols. Plus `ArrayBuffer` with resize/transfer/immutable, all twelve typed arrays, `DataView`, `SharedArrayBuffer`, and `Atomics` ([Binary data](/features/binary-data)); ten `Intl` constructors and the `Temporal` namespace ([Intl & Temporal](/features/intl-temporal)); and host-shaped APIs such as timers, `URL`, `TextEncoder`/`TextDecoder`, `Headers`/`Request`/`Response`, `AbortController`, and `structuredClone` ([Web-shaped APIs](/features/web-apis)). The complete [WebAssembly MVP](/wasm) binary runtime and JavaScript API are scored against the pinned upstream wg-1.0 corpus.
:::

::: tip Runtime
Precise tracing GC with generational collection and explicit compaction · GIL-free shared-realm `Thread`s, `Lock`, `Condition`, `ThreadLocal`, and property-mode `Atomics` · isolated `Worker` agents · an embedder-transported inspector protocol. See [Concurrency](/features/concurrency) and [Memory & GC](/advanced/memory-and-gc).
:::

::: warning Scope caveat
The configured test262 runner currently has zero skipped tests, zero excluded files, and no VALID failure tail in the checked-in score. Proper-tail-call coverage, dynamic-import catch-target behavior, import-defer async-module coverage, and module+async/top-level-await graph ordering are scored. Two non-normative SpiderMonkey staging files are removed from the configured corpus before scoring because their pending expectations contradict stronger Annex B coverage; they are not skip-list or exclusion-list entries.
:::

## Next steps

- [Building & Running](/guide/building) — get the engine compiled and run the suite.
- [Features](/features/) — the full picture of what is implemented: language, built-ins, Intl/Temporal, binary data, concurrency, WebAssembly.
- [Advanced](/advanced/) — embedding, memory and GC, execution tiers, debugging, and how claims are verified.
- [Architecture](/architecture) — the tiered execution model and the source map.
- [Conformance](/conformance) — how test262 is run and scored.
- [JavaScriptCore C-API](/api) — embed zig-js in an existing app.
- [Contributing](/guide/contributing) — set up the toolchain and land a change.
