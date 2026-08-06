---
title: Embedding
description: Drive zig-js from Zig — Context creation, options, evaluation, modules, values, termination, and how the Zig API relates to the C and Objective-C surfaces.
---

# Embedding zig-js

There are three ways to embed the engine. They are the same engine, exposed at
three levels of contract stability.

| Surface | Use it when | Stability |
| --- | --- | --- |
| **Zig module** (`@import("js")`) | You are writing Zig and want the whole engine. | Pre-stabilization; the richest surface. |
| **Public C API** ([guide](/api) · [inventory](/c-api/README)) | Your host already speaks the JavaScriptCore C API. | A pinned, inventoried subset target. |
| **Objective-C bridge** ([inventory](/objc-api/README)) | macOS hosts using `JSContext` / `JSValue`. | Pinned against a specific macOS SDK. |

Private, revision-pinned profiles for named downstream consumers are a separate
thing again — see [Private ABI profiles](/abi/README).

## Wiring the dependency

`zig build` installs `libzig-js.a` into `zig-out/lib` and JavaScriptCore-shaped
headers into `zig-out/include/JavaScriptCore`. As a Zig package, zig-js itself
resolves `zig-regex` and `zig-gc` **by local path** — both must be checked out
next to the `zig-js` directory (see
[Building & Running](/guide/building)).

## The basic loop

```zig
const js = @import("js");

const ctx = try js.Context.create(allocator);
defer ctx.destroy();

const value = try ctx.evaluate("let x = 40; x + 2");
```

`evaluate` returns a `js.Value` — an 8-byte NaN-boxed value — or an error from
`Context.RunError` (parse errors plus evaluation errors). Related entry points:

```zig
try ctx.evaluateWithThis(source, this_value);
try ctx.evaluateModule(entry_path, entry_source, host);
```

The convenience helper `js.evalNumber(source)` spins up a throwaway context; it
is only safe for primitives, because the context — and therefore everything it
allocated — is destroyed before it returns.

## Options

```zig
const ctx = try js.Context.createWith(allocator, .{
    .enable_jit = true,          // baseline native tier where the target supports it
    .enable_threads = false,     // shared-realm Thread API
    .gil = false,                // with enable_threads: serialize instead of running parallel
    .enable_gc = false,          // precise tracing GC instead of the arena
    .concurrent_gc = false,      // mark concurrently with a single mutator
    .heap_limit_bytes = null,    // fail-closed cap on outstanding Context bytes
    .native_observability = false, // retain owned native-PC identity metadata
    .wasm_features = .{},        // post-MVP WebAssembly gates, all off by default
});
```

Notes that matter in practice:

- **`enable_jit` is fixed for the context lifetime.** That is deliberate: it lets
  differential tests and profiles compare identical source without a
  timing-sensitive tier toggle. Unsupported targets interpret regardless.
- **`enable_threads` implies the GC-managed, thread-safe cell path.** Threads run
  in parallel by default; `.gil = true` is the serialized fallback.
- **`concurrent_gc` requires `enable_gc` and is single-mutator only** — it cannot
  be combined with `enable_threads`.
- **`heap_limit_bytes` covers Context-owned allocations** — arena chunks, GC cell
  slabs and side storage, thread records. Arena-backed caps fail closed;
  GC-backed caps can collect and retry at safe allocation-recovery points.
- **`native_observability` is opt-in and fixed for the context lifetime.** It
  retains stable generated-code names, PC ranges, and source identity through
  execution-epoch retirement for profiler/debugger adapters. It does not by
  itself publish an image to the system profiler.
- **Wasm features are off by default** and dependency-checked; enabling an
  unfinished one produces an implementation diagnostic rather than degrading
  silently.

`Context.TestingOptions` exists alongside `Options` for conformance and fuzzing
drivers — `[[CanBlock]]`, thread caps, step budgets, `parallel_js`,
`parallel_midscript_gc`. **These are harness controls, not embedder API**; do not
build a product on them.

## Modules

`evaluateModule` takes a host hook, because the engine does not resolve
specifiers:

```zig
const host = js.Context.ModuleHost{
    .ctx = @ptrCast(my_loader),
    .load = myLoadFn,   // (ctx, referrer, specifier, out_path) -> ?source
};
const result = try ctx.evaluateModule("/entry.js", entry_source, host);
```

Your `load` returns the module source and writes back the resolved path (used as
the module's identity for cycle detection and re-export resolution), or `null` to
report resolution failure. The engine owns graph construction, linking, cycle
handling, top-level `await`, and async-module evaluation ordering.

## Values and lifetimes

- A default `Context` bump-allocates into an **arena**; everything is freed
  wholesale on `destroy()`. Values do not outlive their context.
- With `enable_gc`, cells are traced. A value reachable only from your Zig code
  must be **protected** so a collection cannot reclaim it:

  ```zig
  const handle = try ctx.protectValue(v);
  defer _ = ctx.unprotectValue(handle);
  ```

- Host-owned external buffers and strings have explicit owner objects with
  deferred release, so the engine can hand back native memory without copying.
  See `createExternalBufferOwner` / `createExternalStringOwner`.

## Host functions and globals

The Zig-level primitives are `value.NativeFn` plus the interpreter helpers
`installNativeProps`, `setNative`, and `setNativeGetter`, applied to the
context's `global_object` and root shape. This is how every built-in in the
engine is installed, so it is fully expressive — but it is lower-level than the
C API's callback surface.

If you want the ergonomic path, the C API's `JSObjectMakeFunctionWithCallback`
and class-definition surface is documented, inventoried, and covered by
behaviour tests: [`/api`](/api).

## Threading rules

- A non-threaded context is single-threaded and keeps the original affinity rule;
  `isOwnerThread()` and `assertOwnerThread()` enforce it.
- With `enable_threads`, shared-realm `Thread`s share one realm and real object
  identity. The C-level equivalent is
  `ZJSGlobalContextCreateThreaded(gil)`.
- Read [Memory model](/threads/memory-model) before sharing engine state from
  host code.

## Termination and resource control

```zig
ctx.requestTermination();          // cooperative; observed at safepoints
_ = ctx.terminationRequested();
```

Termination is cooperative: it is observed at safepoints in the interpreter, the
VM, and native tiers, and it joins active threads before teardown completes. A
step budget bounds runaway evaluation, and `heap_limit_bytes` bounds memory.

Collection and diagnostics:

```zig
ctx.collectGarbage();                  // quiescent collection (enable_gc)
ctx.requestGarbageCollection();        // request at the next safepoint
_ = ctx.requestGarbageCompaction();    // explicit compaction
_ = ctx.heapBudgetStats();
_ = ctx.parallelGcStats();
_ = ctx.runtimeHeapAccounting();
```

See [Memory & GC](/advanced/memory-and-gc).

## Debugging hooks

`registerDebugScript` / `registerDebugScriptWithLocations` give scripts stable
identities and source locations for the inspector. Public inspectability stays
opt-in — `JSGlobalContextSetInspectable(ctx, true)` must run before a session can
be created. See [Inspector protocol](/inspector).

## Stability

The APIs are **pre-stabilization**. Compatibility shims are not frozen before
stabilization, and the public C API is an implemented subset target rather than
the whole JavaScriptCore framework. Track the release gates in
[`docs/.data/release-compatibility-matrix.json`](https://github.com/zig-utils/zig-js/blob/main/docs/.data/release-compatibility-matrix.json).
