---
title: Features
description: What zig-js implements — language, built-ins, internationalization, web-shaped APIs, binary data, concurrency, and WebAssembly.
---

# Features

zig-js is an embeddable JavaScript engine written from scratch in Zig. This
section describes **what the engine gives you**. For how it runs that code, see
[Architecture](/architecture) and [Advanced](/advanced/).

Everything here is scored against the pinned tc39/test262 corpus through the
configured runner; see [Conformance](/conformance) for the methodology and what
sits outside the denominator.

<Test262Progress :stats="data.test262" />

## The map

<div class="cards">
<FeatureCard tag="// syntax" title="Language">Classes with private fields and static blocks, generators, async/await, modules, destructuring, optional chaining, explicit resource management.</FeatureCard>
<FeatureCard tag="// stdlib" title="Built-ins">Object, Array, String, Map/Set, Promise, Proxy/Reflect, Symbol, BigInt, RegExp, iterator helpers, and the Error family.</FeatureCard>
<FeatureCard tag="// i18n" title="Intl & Temporal">Ten Intl constructors over checked-in CLDR/IANA tables, plus the Temporal date/time namespace.</FeatureCard>
<FeatureCard tag="// host" title="Web-shaped APIs">Timers, URL, TextEncoder/TextDecoder, Headers/Request/Response, Blob, FormData, AbortController, structuredClone.</FeatureCard>
<FeatureCard tag="// bytes" title="Binary data">ArrayBuffer with resize/transfer/immutable, all twelve typed arrays, DataView, SharedArrayBuffer, Atomics.</FeatureCard>
<FeatureCard tag="// parallel" title="Concurrency">GIL-free shared-realm Threads, Workers, agents, and property-mode Atomics on real OS threads.</FeatureCard>
</div>

## Pages

| Page | Covers |
| --- | --- |
| [Language](/features/language) | Syntax and semantics: declarations, functions, classes, generators, async, modules, resource management. |
| [Built-ins](/features/builtins) | The standard library and the global object. |
| [Binary data](/features/binary-data) | `ArrayBuffer`, typed arrays, `DataView`, `SharedArrayBuffer`, `Atomics`. |
| [Intl & Temporal](/features/intl-temporal) | Internationalization constructors and the Temporal namespace. |
| [Web-shaped APIs](/features/web-apis) | Timers, URL, encoding, fetch data types, abort signals, structured clone. |
| [Concurrency](/features/concurrency) | Threads, Workers, agents, and what is shared between them. |
| [WebAssembly](/wasm) | The pure-Zig Wasm runtime, its JavaScript API, and post-MVP feature gates. |

## Opting features in

Some capabilities are **off by default** and enabled per `Context`:

```zig
const ctx = try js.Context.createWith(gpa, .{
    .enable_threads = true,     // shared-realm Thread, Lock, Condition, ThreadLocal, Atomics
    .enable_gc = true,          // precise tracing GC instead of the arena
    .enable_jit = true,         // baseline native tier (default on)
    .heap_limit_bytes = 64 << 20,
    .wasm_features = .{ .fixed_width_simd = true },
});
defer ctx.destroy();
```

See [Embedding](/advanced/embedding) for the full option surface and
[Memory & GC](/advanced/memory-and-gc) for what each allocator mode implies.

## What is deliberately not here

- **No `console`.** The engine ships no host I/O object; a `print` global exists
  for harness use. Embedders install their own logging.
- **No module resolver.** `Context.evaluateModule` takes a host hook; module
  resolution and file loading belong to the embedder.
- **Decorators are parsed and discarded.** The syntax is accepted so decorated
  sources parse, but decorator application is not implemented.
- **Skipped or excluded corpus categories are outside the denominator**, not
  implemented. [Conformance](/conformance) names them.

Open release gates and remaining work are tracked in
[`docs/.data/release-compatibility-matrix.json`](https://github.com/zig-utils/zig-js/blob/main/docs/.data/release-compatibility-matrix.json)
and summarized in the README's "What Is Not Implemented" section.
