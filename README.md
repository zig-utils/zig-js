# zig-js

A JavaScript engine written in pure Zig, with an implemented JavaScriptCore-shaped C API subset. No JSC, no V8, no external C libraries.

`zig-js` is a small embeddable engine for Zig applications, tools, experiments, and runtimes that want to own their JavaScript stack. Use it directly as a Zig module, or link `libzig-js.a` for hosts that only need the implemented public C API subset. The project is still pre-stabilization, so clean zig-js semantics win over preserving inert compatibility shims.

The configured conformance runner is green against the pinned tc39/test262 corpus it scores: **48,506 / 48,506 valid** and **4,669 / 4,669 negative**, with **0 parse**, **0 runtime**, **0 host**, **0 skipped**, and **0 excluded** failures. That is a scoped result, not a claim of full ECMAScript completion.

```zig
const js = @import("js");

const ctx = try js.Context.create(allocator);
defer ctx.destroy();

const v = try ctx.evaluate("let x = 40; x + 2");
// v == .{ .number = 42 }
```

## Contents

- [Status](#status)
- [How It Works](#how-it-works)
- [Conformance](#conformance)
- [Performance](#performance)
- [Language And Runtime Coverage](#language-and-runtime-coverage)
- [Using It](#using-it)
- [Architecture](#architecture)
- [Build And Test](#build-and-test)
- [Threads And GC](#threads-and-gc)
- [What Is Not Implemented](#what-is-not-implemented)
- [License](#license)

## Status

Current public status is evidence-scoped:

- test262 totals come from [docs/.data/test262.json](docs/.data/test262.json), regenerated from [docs/.data/test262-run-2026-07-05.txt](docs/.data/test262-run-2026-07-05.txt).
- The skipped-test inventory is [docs/.data/test262-skips.tsv](docs/.data/test262-skips.tsv), currently zero.
- The exact excluded-file inventory is [docs/.data/test262-excluded.tsv](docs/.data/test262-excluded.tsv), currently zero.
- VM/tree-walker numbers below come from [docs/.data/bench-2026-07-04.txt](docs/.data/bench-2026-07-04.txt); the JSC comparison comes from the [July 15, 2026 report](docs/.data/benchmark-comparison-2026-07-15.md) and its [1,540 raw timing samples](docs/.data/benchmark-comparison-2026-07-15.tsv).
- C API scope comes from the exported symbols in [src/c_api.zig](src/c_api.zig).
- Threading and GC status are documented under [docs/threads](docs/threads) and [docs/architecture.md](docs/architecture.md).

The documentation guardrails live in [docs/DOCS_ACCURACY_PLAN.md](docs/DOCS_ACCURACY_PLAN.md). Public claims should be tied to a run transcript, generated data file, source file, or current command output.

## How It Works

The engine has two execution paths sharing one object model:

- **Tree-walking interpreter** - the semantic baseline and fallback path.
- **Suspendable stack bytecode VM** - the compiled path for supported top-level code, functions, generators, async functions, and async generators.

The compiler lowers the subset it knows. Unsupported constructs fall back to the tree-walker where that is semantically safe, so VM coverage can grow without sacrificing correctness. Object shapes and inline caches are implemented for property access, and function activations use frame slots/upvalues for compiled code.

Default contexts use arena lifetime: values and objects are released when the context is destroyed. Opt-in GC contexts (`Context.createWith(.{ .enable_gc = true })`) use the precise collector described in [docs/architecture.md](docs/architecture.md) and [docs/threads/P7-gc-design.md](docs/threads/P7-gc-design.md).

## Conformance

Measured by `zig build test262` against the pinned `test262/` submodule. The runner scores two axes separately:

| axis | meaning | passing |
| ---- | ------- | ------: |
| **valid** | can the engine run the program? | **48,506 / 48,506 (100.0%)** |
| **negative** | does the engine reject invalid input? | **4,669 / 4,669 (100.0%)** |

Failure shape on the valid axis: **0 parse failures**, **0 runtime failures**, **0 host failures**.

Skipped tests are excluded from both denominators. Current skipped count: **0**. Current excluded count: **0**.

Two non-normative SpiderMonkey staging files are removed from the configured corpus definition because their `esid: pending` expectations contradict the normative Annex B `arguments` tests in `test/annexB`. They are tracked in `conformance/test262.zig` as removed corpus inputs, not as engine failures, skips, or exclusions.

Representative green areas from the saved run:

| area | passing | area | passing |
| ---- | ------: | ---- | ------: |
| `test/language` | saved-run subtrees 100% | `test/annexB` | 1,071 / 1,071 |
| `test/intl402` | saved-run subtrees 100% | `test/staging` | 1,476 / 1,476 |
| `Array` | 3,081 / 3,081 | `Object` | 3,411 / 3,411 |
| `RegExp` | saved-run subtrees 100% | `String` | 1,223 / 1,223 |
| `Temporal` | 4,603 / 4,603 | `TypedArray` | 1,446 / 1,446 |
| `Atomics` | 390 / 390 | `SharedArrayBuffer` | 104 / 104 |
| `Map` | 204 / 204 | `Set` | 383 / 383 |
| `WeakMap` | 141 / 141 | `WeakSet` | 85 / 85 |
| `WeakRef` | 29 / 29 | `FinalizationRegistry` | 47 / 47 |

`zig build conformance` is a separate fast smoke suite; the July 4, 2026 verification run passed 33/33 cases. Use `zig build test262` for the full configured corpus.

## Performance

`zig build bench` currently times the bytecode VM against the tree-walker on a small set of microbenchmarks. The latest saved local run is [docs/.data/bench-2026-07-04.txt](docs/.data/bench-2026-07-04.txt):

| case | VM ns/op | tree ns/op | VM/tree |
| ---- | -------: | ---------: | ------: |
| `fib(27)` recursion | 172,360,029 | 166,933,604 | 0.97x |
| tight loop sum to 100k | 8,614,833 | 8,547,850 | 0.99x |
| object property churn | 7,563,963 | 7,356,334 | 0.97x |
| array push/sum | 8,484,360 | 8,475,588 | 1.00x |
| deep recursion, depth 500 | 112,897 | 115,296 | 1.02x |

Those numbers show current VM/tree-walk parity on these microbenchmarks, not a broad speedup claim. The same benchmark run also prints no-shared-state thread throughput scaling:

| threads | wall ns | scaling |
| ------: | ------: | ------: |
| 1 | 258,529,500 | 1.00x |
| 2 | 297,057,916 | 1.74x |
| 4 | 315,458,875 | 3.28x |
| 8 | 362,099,959 | 5.71x |

### zig-js vs JavaScriptCore

`zig build benchmark-comparison` runs the same pure-JavaScript kernels through GC-enabled zig-js and the macOS system JavaScriptCore, checks deterministic results across engines, and reports seven-sample medians with dispersion. It directly compares warmed single contexts, warmed independent contexts on persistent OS workers, and cold thread/context lifecycles; zig-js shared-realm threads remain a separate capability panel. The latest [full report](docs/.data/benchmark-comparison-2026-07-15.md) preserves all [1,540 raw timing samples](docs/.data/benchmark-comparison-2026-07-15.tsv) from clean zig-js commit `fff12f90`, zig-gc commit `9d4af0d`, and zig-regex commit `5937fa7d` on an 11-core Apple M3 Pro. The harness recorded battery power at 83% and discharging. Every full-run median exceeds the 50 ms timing floor, equal work counts are identical for both engines, and the runners alternate execution order. Dispersion is shown in the full report; do not treat small cross-session differences as causal.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.76x** | — | — |
| independent steady contexts | 8 | 9 / 10 | **2.88x** | **5.30x** | 5.04x |
| independent cold lifecycles | 8 | 9 / 10 | **2.98x** | **5.41x** | 4.88x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **4.23x** | — |

Lower time is better. A throughput ratio above 1.00x favors zig-js; below 1.00x favors JSC.

| workload | zig-js single (ms) | JSC single (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: |
| arithmetic | 83.460 | 356.409 | 4.27x |
| properties | 90.049 | 298.925 | 3.32x |
| polymorphic properties | 84.488 | 227.078 | 2.69x |
| object churn | 109.144 | 117.864 | 1.08x |
| arrays | 80.170 | 152.181 | 1.90x |
| direct calls | 57.853 | 119.884 | 2.07x |
| method calls | 63.367 | 141.896 | 2.24x |
| closure calls | 64.975 | 196.604 | 3.03x |
| arguments calls | 70.252 | 300.100 | 4.27x |
| Fibonacci | 82.233 | 455.227 | 5.54x |

At eight warmed independent contexts, both engines use the same persistent-worker protocol and every lane performs the full job count:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 107.624 | 537.507 | 4.99x | 6.20x | 5.29x |
| properties | 127.531 | 470.714 | 3.69x | 5.70x | 5.00x |
| polymorphic properties | 124.906 | 321.927 | 2.58x | 5.88x | 6.10x |
| object churn | 266.624 | 183.781 | 0.69x | 3.28x | 5.07x |
| arrays | 128.020 | 265.918 | 2.08x | 5.03x | 4.57x |
| direct calls | 86.650 | 209.146 | 2.41x | 5.66x | 4.69x |
| method calls | 94.638 | 225.753 | 2.39x | 5.45x | 5.00x |
| closure calls | 94.428 | 338.457 | 3.58x | 5.44x | 4.56x |
| arguments calls | 100.188 | 507.589 | 5.07x | 5.56x | 4.79x |
| Fibonacci | 120.613 | 660.264 | 5.47x | 5.53x | 5.48x |

zig-js's no-GIL shared-realm mode has no direct public-JSC equivalent because its threads share one object graph. Its latest eight-lane scaling is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 83.622 | 109.544 | 6.11x |
| properties | 129.786 | 185.549 | 5.60x |
| polymorphic properties | 597.711 | 757.858 | 6.31x |
| object churn | 193.853 | 2,374.329 | 0.65x |
| arrays | 83.483 | 242.194 | 2.76x |
| direct calls | 59.257 | 85.414 | 5.55x |
| method calls | 124.318 | 199.988 | 4.97x |
| closure calls | 67.528 | 96.832 | 5.58x |
| arguments calls | 70.621 | 102.137 | 5.53x |
| Fibonacci | 257.612 | 374.975 | 5.50x |

zig-js wins all 10 direct rows and 9 of 10 eight-lane rows in both directly comparable multi-context modes; object churn is the remaining loss. Its geometric-mean throughput lead is 2.76x direct, 2.88x at eight warmed independent contexts, and 2.98x in the symmetric eight-lane cold lifecycle. Mode-local eight-lane scaling is 5.30x for zig-js versus 5.04x for JSC when warmed and 5.41x versus 4.88x when cold; shared-realm scaling is 4.23x by geometric mean.

The shipping no-GIL heap now reclaims young garbage after a 1 GiB aggregate GC-cell tranche once at least two workers exist. An exact order-balanced same-session A/B held one-lane object churn effectively flat (195.479 versus 196.399 ms, -0.5%) while reducing eight-lane time from 5,554.628 to 2,214.625 ms (-60.1%), with identical checksums. In the full matrix, shared object churn is 2,374.329 ms at eight lanes, 0.65x scaling, and 6.32% RSD; that is a large improvement but still the clearest shared-GC bottleneck. Direct object churn is 109.144 versus 117.864 ms for JSC, while eight warmed contexts are 266.624 versus 183.781 ms and cold contexts are 275.548 versus 188.630 ms. See [Performance Benchmarks](docs/benchmarks.md) for every lane count, exact boundaries, dispersion, caveats, reproduction, and raw evidence.

Implemented performance machinery includes the bytecode VM, frame slots/upvalues, object shapes, inline caches, guarded loop and recurrence kernels, a baseline native tier, the engine-wide 8-byte NaN-boxed `Value`, GC slab backing with per-chunk reusable-slot bitmaps plus lock-amortized allocation and sweep-release batches, and an opt-in-GC one-cycle nursery that reclaims young garbage at quiescent boundaries and immediately tenures survivors. Future work includes broader native-tier coverage, nursery sizing and pause optimization, deeper generational policies, and a general optimizing tier.

## Language And Runtime Coverage

The configured test262 coverage for these surfaces is green.

**Syntax and operators** - literals, strings, regex literals, template literals, objects, arrays, destructuring, spread/rest, optional chaining, nullish coalescing, logical assignment, exponentiation, bitwise/shift operators, `in`, `instanceof`, `typeof`, `delete`, `void`, and comma.

**Bindings and scope** - `var`/`let`/`const`, TDZ, block scope, closures, direct and indirect `eval`, `with`, destructuring in declarations/parameters/assignment, and mapped/unmapped `arguments`.

**Functions and classes** - declarations, expressions, arrows, default/rest parameters, `this`, `new`, `new.target`, getters/setters, class fields, private members, static members/blocks, `super`, derived constructors, and `extends`.

**Control flow** - `if`, loops, `for-in`, `for-of`, `for await`, `switch`, labels, `break`, `continue`, `throw`, `try`, `catch`, `finally`, and using/disposal syntax covered by the configured runner.

**Generators and async** - `function*`, `yield`, `yield*`, async functions, async generators, `await`, Promise jobs, microtask ordering, proper tail calls in strict return-position calls, and module+async/top-level-await tests in the configured surface.

**Modules** - imports, exports, default/named/namespace re-exports, `export *`, live bindings, namespace objects, `import.meta`, dynamic `import()`, dynamic-import catch-target behavior, `import defer` async-module behavior, and top-level-await graph ordering covered by the configured runner.

**Built-ins** - `Object`, `Function`, `Array`, `String`, `RegExp` via [`zig-regex`](../zig-regex), `Number`, `Boolean`, `Math`, `JSON`, `Symbol`, `Map`, `Set`, `WeakMap`, `WeakSet`, `Promise`, `Date`, errors, `Proxy`, `Reflect`, `globalThis`, typed arrays, `ArrayBuffer`, `SharedArrayBuffer`, `DataView`, `Atomics`, `WeakRef`, `FinalizationRegistry`, broad `Temporal`, and `Intl` coverage.

## Using It

### As A Zig Module

```zig
const js = @import("js");

const ctx = try js.Context.create(allocator);
defer ctx.destroy();

const v = try ctx.evaluate("let x = 40; x + 2");
```

### As A C API Subset

Link `libzig-js.a` for hosts that use the implemented subset of Apple's public `<JavaScriptCore/JSValueRef.h>` / `<JSObjectRef.h>`-shaped surface:

```c
JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
JSStringRef script = JSStringCreateWithUTF8CString("1 + 1");
JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);
double n = JSValueToNumber(ctx, result, NULL); // 2.0
```

The current exported C surface has 52 functions:

- **Context lifecycle** - `JSGlobalContextCreate`, `ZJSGlobalContextCreateThreaded(gil)`, `JSGlobalContextRelease`, `JSGlobalContextRetain`, `JSContextGetGlobalObject`, `JSEvaluateScript`, `JSGarbageCollect`.
- **Values** - `JSValueGetType`, `JSValueIs*`, `JSValueIsEqual`, `JSValueIsStrictEqual`, `JSValueMake*`, `JSValueTo*`, `JSValueProtect`, `JSValueUnprotect`.
- **Objects** - `JSObjectMake`, `JSObjectGetPrivate`, `JSObjectSetPrivate`, `JSObjectMakeArray`, `JSObjectMakeDeferredPromise`, `JSObjectGetProperty`, `JSObjectSetProperty`, `JSObjectGetPropertyAtIndex`, `JSObjectCallAsFunction`, `JSObjectCallAsConstructor`, `JSObjectMakeFunctionWithCallback`, `JSObjectIsFunction`, `JSObjectIsConstructor`.
- **Strings** - `JSStringCreateWithUTF8CString`, `JSStringRetain`, `JSStringRelease`, `JSStringGetLength`, `JSStringGetUTF8CString`.
- **Worker extension** - `JSWorkerCreate`, resource-bounded `JSWorkerCreateWithLimits`, `JSWorkerPostMessage`, `JSWorkerReceive`, `JSWorkerTerminate`, `JSWorkerRelease`.

`ZJSGlobalContextCreateThreaded` and `JSWorker*` are zig-js extensions, not public JSC symbols. `JSObjectMakeDeferredPromise` returns a pending native Promise plus paired resolving functions; callers observe settlement at the next microtask checkpoint (for example, after `JSEvaluateScript` returns).

See [docs/api.md](docs/api.md) and [docs/HOME_INTEGRATION.md](docs/HOME_INTEGRATION.md) for the fuller embedding story and the important warning that zig-js is not a drop-in replacement for Bun/Home's private JSC internals.

## Architecture

| file | responsibility |
| ---- | -------------- |
| [src/value.zig](src/value.zig) | `Value`, `Object`, coercions, equality, object slots/elements/accessors |
| [src/lexer.zig](src/lexer.zig) | tokenizer |
| [src/ast.zig](src/ast.zig) | AST node model |
| [src/parser.zig](src/parser.zig) | recursive-descent parser |
| [src/interpreter.zig](src/interpreter.zig) | tree-walking evaluator and built-in library |
| [src/compiler.zig](src/compiler.zig) | AST to bytecode compiler |
| [src/bytecode.zig](src/bytecode.zig) | bytecode instruction and template definitions |
| [src/vm.zig](src/vm.zig) | suspendable bytecode VM |
| [src/shape.zig](src/shape.zig) | hidden-class/shape transition tree |
| [src/promise.zig](src/promise.zig) | Promise state and microtask queue |
| [src/context.zig](src/context.zig) | context lifecycle, module loader/cache, GC/thread options |
| [src/gc.zig](src/gc.zig) | opt-in precise GC |
| [src/jsthread.zig](src/jsthread.zig) | shared-realm `Thread` API |
| [src/worker.zig](src/worker.zig) | isolated worker agents |
| [src/jsstring.zig](src/jsstring.zig) | refcounted `JSStringRef` backing |
| [src/c_api.zig](src/c_api.zig) | exported C API |
| [src/root.zig](src/root.zig) | `@import("js")` entry point |

## Build And Test

Requires Zig 0.17.0-dev.

```sh
zig build                         # builds libzig-js.a
zig build test                    # unit + C-API tests
zig build conformance             # fast smoke suite
zig build test262                 # configured tc39/test262 corpus
zig build test262-bin             # build the test262 runner only
./zig-out/bin/test262 --list-skips > docs/.data/test262-skips.tsv
./zig-out/bin/test262 --list-excluded > docs/.data/test262-excluded.tsv

bun run docs:data
bun run docs:build

zig build bench                   # VM/tree-walk and thread-scaling benchmark
zig build benchmark-comparison    # zig-js direct/independent/shared vs system JSC (macOS)
zig build benchmark-comparison -Dbenchmark-comparison-quick=true
zig build benchmark-comparison-test
zig build threads-test            # WebKit PR-249 thread allowlist
zig build threads-reference-audit # classify non-promoted PR-249 files
python3 tools/threads-reference-audit.py --probe-candidates
python3 tools/threads-reference-audit.py --run-probes --expect-current-blockers --probe-timeout 60

zig build threadfuzz
zig build threadfuzz -Dfuzz-midgc=true
zig build threadfuzz -Dfuzz-lifecycle=true
zig build test -Dtsan=true
zig build threads-profile
zig build threads-profile -Dthreads-profile-case='global binding churn' -Dthreads-profile-max-workers=1
zig build threads-profile -Dthreads-profile-case='condition asyncWait'
zig build threads-profile -Dthreads-profile-case='condition asyncWait parked'
zig build threads-profile -Dthreads-profile-case='condition asyncWait multi-lock'
zig build threads-profile -Dthreads-profile-case='promise microtasks'
zig build threads-profile -Dthreads-profile-case='promise thenables'
zig build midgc-profile
zig build gc-profile
zig build gc-profile -Dgc-profile-case='nursery'
```

The test262 corpus is vendored as the `test262/` git submodule. `zig build test262` uses it by default and skips cleanly if it is absent.

## Threads And GC

`Context.createWith(.{ .enable_threads = true })` installs the shared-realm `Thread`, `Lock`, `Condition`, `ThreadLocal`, property-mode `Atomics.*`, proposal-aligned `Atomics.Mutex` / `Atomics.Condition`, and related surfaces. Shared-realm threads run true-parallel by default; `.gil = true` is available as a serialized compatibility mode.

```zig
const parallel = try js.Context.createWith(gpa, .{ .enable_threads = true });
const serialized = try js.Context.createWith(gpa, .{ .enable_threads = true, .gil = true });
```

The isolated `Worker` implementation lives in [src/worker.zig](src/worker.zig) and is exposed to C embedders through the `JSWorker*` extension functions.

Current thread status is tracked in:

- [docs/threads/index.md](docs/threads/index.md)
- [docs/threads/testing.md](docs/threads/testing.md)
- [docs/threads/memory-model.md](docs/threads/memory-model.md)
- [issue #1](https://github.com/zig-utils/zig-js/issues/1)

The README intentionally avoids duplicating the detailed thread/GC implementation log; those docs and the commands above are the source of truth.

## What Is Not Implemented

Do not read the green configured runner as "the whole JavaScript universe is finished." Known non-implemented or non-scored areas include:

- full JavaScriptCore framework/private internals, Objective-C bridge, inspector/debugger APIs, and Bun/Home private JSC ABI;
- WebAssembly and JIT shell hooks from the PR-249 reference corpus;
- moving or multi-age generational GC, parallel mid-script minor collection, and any optimizing JIT.

## Used By

- [home-lang/craft](https://github.com/home-lang/craft)

## License

MIT - see [LICENSE](LICENSE).
