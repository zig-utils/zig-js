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
- VM/tree-walker numbers below come from [docs/.data/bench-2026-07-04.txt](docs/.data/bench-2026-07-04.txt); the JSC comparison comes from the [July 15, 2026 128-byte-slab report](docs/.data/benchmark-comparison-2026-07-15-128-byte-slab.md) and its [1,540 raw timing samples](docs/.data/benchmark-comparison-2026-07-15-128-byte-slab.tsv).
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

<!-- benchmark-comparison:start -->
<!-- Generated by tools/benchmark-publication.py; do not edit headline numbers manually. -->

The latest [full report](docs/.data/benchmark-comparison-2026-07-15-128-byte-slab.md) preserves all [1,540 raw timing samples](docs/.data/benchmark-comparison-2026-07-15-128-byte-slab.tsv) from clean zig-js commit `12aa217c`, zig-gc `092d8d76`, and zig-regex `50764b03` on Apple M3 Pro, 11 physical / 11 logical CPUs, 18.0 GiB. The run used Zig `0.17.0-dev.956+2dca73595`, system framework 22625.1.20.11.3, and Battery Power (discharging). Every full-run median exceeds the 50 ms timing floor; equal work/checksums, alternating runner order, and per-row dispersion are validated by the harness.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.67x** | — | — |
| independent steady contexts | 8 | 10 / 10 | **2.95x** | **5.14x** | 4.77x |
| independent cold lifecycles | 8 | 10 / 10 | **2.91x** | **5.18x** | 4.76x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **3.97x** | — |

Lower time is better. A throughput ratio above 1.00x favors zig-js. Shared-realm threads share one object graph and therefore have no direct public-JSC embedding equivalent.

| workload | zig-js direct (ms) | JSC direct (ms) | zig-js / JSC throughput | zig-js shared scaling |
| --- | ---: | ---: | ---: | ---: |
| `arithmetic` | 91.807 | 356.516 | 3.88x | 6.29x |
| `properties` | 98.723 | 301.017 | 3.05x | 4.87x |
| `polymorphic_properties` | 100.367 | 214.948 | 2.14x | 5.76x |
| `object_churn` | 101.799 | 123.020 | 1.21x | 0.70x |
| `arrays` | 89.919 | 161.737 | 1.80x | 1.91x |
| `direct_calls` | 59.878 | 125.692 | 2.10x | 5.50x |
| `method_calls` | 66.639 | 144.348 | 2.17x | 5.55x |
| `closure_calls` | 65.634 | 198.020 | 3.02x | 5.63x |
| `arguments_calls` | 71.725 | 317.639 | 4.43x | 4.78x |
| `fibonacci` | 86.891 | 471.204 | 5.42x | 5.05x |

zig-js wins all 10 direct rows and all 10 maximum-lane rows in both symmetric independent-context modes. The geometric-mean throughput lead is 2.67x direct, 2.95x warmed-independent, and 2.91x cold-lifecycle; shared-realm scaling is 3.97x at 8 lanes.
<!-- benchmark-comparison:end -->

Object instances now occupy a 128-byte GC slab (`96` bytes of payload and `128` raw bytes including collector metadata). One lazy storage wrapper owns cold/exotic state, external named-slot metadata, dense/internal element metadata, and backing-allocator bookkeeping; a plain object with four or fewer named properties keeps its values entirely inline and allocates none of those side states. The current 128-byte object bucket uses 64 KiB chunks; larger 256/512/1024/2048-byte classes use their separately calibrated geometry. The accepted matrix reports object-churn medians of 101.799 versus 123.020 ms direct, 168.520 versus 185.412 ms at eight warmed contexts, and 181.819 versus 190.980 ms across cold eight-context lifecycles. Shared object churn is 1,671.114 ms at eight lanes with 0.70x scaling. An [exact-parent A/B](docs/.data/object-churn-128-byte-slab-ab-2026-07-15.md) isolates the slab crossing from session noise: the candidate is 1.04–1.65x faster in every direct/independent mode and 1.19–1.39x faster in the confirmatory shared one- and four-lane rows; its shared eight-lane median is 1.16x faster with roughly stable scaling.

The latest [exact-parent shared object-churn A/B](docs/.data/object-churn-amortized-publication-ab-2026-07-16.md) covers the post-publication allocation work on current `main`. A bounded, explicitly rooted 272-cell reserve is enabled only while multiple shared-realm workers contend; zig-gc privately chains only batches of at least 64 cells and O(1)-splices them before publishing the ownership bitmap outside its allocation lock. Seven order-balanced pairs measured 100.562 / 112.393 / 141.772 / 1,239.637 ms at 1/2/4/8 lanes, versus exact-parent medians of 99.901 / 168.035 / 272.951 / 1,542.720 ms. That is neutral at one lane and 1.50x / 1.93x / 1.24x faster at 2/4/8 lanes, with exact checksums and 7/7 pair wins in every contended row. Eight-lane scaling improves from 0.52x to 0.65x but remains below the 1.0x target, so the generated JSC headline above remains the latest complete accepted matrix rather than mixing a focused development run into it. See [Performance Benchmarks](docs/benchmarks.md) for boundaries, dispersion, reproduction, and raw evidence.

Full hosted comparison runs are available through the manual-only [Performance workflow](.github/workflows/performance.yml). Its report and raw TSV are retained as artifacts for review; hosted timing is never an ordinary-CI gate or automatically substituted for the documented reference-host baseline.

Implemented performance machinery includes the bytecode VM, frame slots/upvalues, object shapes, inline caches, guarded loop and recurrence kernels, a [profiled baseline native tier](docs/.data/baseline-jit-profile-2026-07-16.md), the engine-wide 8-byte NaN-boxed `Value`, GC slab backing with per-chunk reusable-slot bitmaps plus lock-amortized allocation and sweep-release batches, and an opt-in-GC one-cycle nursery that reclaims young garbage at quiescent boundaries and immediately tenures survivors. Future work includes broader native-tier coverage, nursery sizing and pause optimization, deeper generational policies, and a general optimizing tier.

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

Install the library and checked-in `<JavaScriptCore/JavaScript.h>`-compatible
headers with `zig build`, then link `libzig-js.a` from `zig-out/lib`:

```c
JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
JSStringRef script = JSStringCreateWithUTF8CString("1 + 1");
JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);
double n = JSValueToNumber(ctx, result, NULL); // 2.0
```

The current exported C surface has 129 functions:

- **Context lifecycle** - real shared-VM context groups with distinct realms and cross-realm values, global classes, inspectability with versioned in-process inspector sessions, create/retain/release, global object/context lookup, owned context names, syntax-only checking, evaluation, collection, and the threaded-context extension.
- **Values** - type and Symbol/BigInt predicates, equality/relations/`instanceof`, public-class identity, primitive/fresh-Symbol/exact-BigInt construction, JSON parse/stringify, exact 32/64-bit conversions, coercions, and protected handles.
- **Objects and classes** - complete `JSClassRef` ownership and inheritance, parent-first initialization/child-first finalization, GC-rooted shared prototypes, static functions and values, deterministic enumeration, every dynamic callback family, retained property-name snapshots, `JSObjectMake`, and `JSObjectMakeConstructor`. Foreign-context and invalid callback returns fail deterministically. Private data, prototype get/set, string/Symbol/coerced-key property operations, indexed reads/writes, real Date/Error/RegExp/dynamic-Function/Array/deferred-Promise construction, and function call/construct helpers are also implemented.
- **Typed arrays and buffers** - `JSValueGetTypedArrayType`, the four public `JSObjectMakeTypedArray*` construction paths, typed-array type/bytes/length/offset/buffer queries, and no-copy `ArrayBuffer` construction/bytes/length with exactly-once embedder deallocation.
- **Strings** - UTF-8 and UTF-16 construction, retain/release, UTF-16 length and stable borrowed characters, maximum UTF-8 sizing and conversion, and code-unit/UTF-8 equality.
- **Extensions** - resource-bounded `JSWorker*`, observable `ZJSValueProtect`/`ZJSValueUnprotect`, threaded contexts, and authenticated-transport-neutral `ZJSInspectorSession*`.

`ZJSGlobalContextCreateThreaded`, `ZJSValueProtect`/`ZJSValueUnprotect`,
`ZJSInspectorSession*`, and `JSWorker*` are zig-js extensions, not public JSC symbols. The `ZJSValue*`
variants report invalid handles, refcount overflow, and unmatched unprotects;
the public JSC-compatible calls correctly return `void`. `JSObjectMakeDeferredPromise` returns a pending native Promise plus paired resolving functions; callers observe settlement at the next microtask checkpoint (for example, after `JSEvaluateScript` returns).

The [macOS 27.0 public API inventory](docs/c-api/jsc-public-api-macos-27.0.json)
tracks all 117 pinned C functions and links every unfinished declaration to its
implementation issue. The current audit is **117 implemented / 0 pending**, with
**117 public functions + 12 zig-js extensions** exported. `zig build c-api-audit` checks declaration/export drift;
`zig build test-c-api` additionally compiles, links, and runs real C and C++ hosts.
On macOS, `zig build c-api-jsc-diff` verifies the pinned SDK hashes, compiles the
same value/class and context-group fixtures against zig-js and system JavaScriptCore,
and requires byte-for-byte identical results. The current fixtures match all **34 rows**
(`a8ecd5e83f9f35ca`), including inspectability toggles, shared-VM realm identity/lifetime, global classes,
every class callback family, inherited call and
conversion behavior, ordinary and callback-backed constructors, property-name
snapshots, coerced and Symbol keys, fallback behavior, reflection, attributes,
and callback throws.
The pinned public C inventory has no pending declarations. Inspector sessions
now publish stable scripts and exact statement locations, and provide real
`debugger;`, explicit pause/resume control, and deterministically resolved
script/URL breakpoints with removal. Logical-depth step-into, step-over, and
step-out cover ordinary calls plus suspendable generator/async VM execution,
alongside none/all/uncaught exception pause policy and thrown-exception events.
The [machine-readable protocol inventory](docs/inspector-protocol-0.1.json)
contains 20 implemented commands and 8 events with no hidden accepted stubs.
Every paused event now includes the live JavaScript call stack with stable
pause-local frame IDs, function/source locations, `this`, and lexical, block,
closure, and summarized global scope chains across tree-walker and suspendable
VM execution. `Debugger.evaluateOnCallFrame` reads and mutates those live
lexical bindings while preserving the paused program's control/exception state.
Session-owned remote values and scope handles support non-invoking own-property
inspection plus explicit object/group release; values are protected across GC,
while pause-only scope handles expire on resume. With multiple sessions, one
deterministic owner controls continuation after observers receive the pause
snapshot; observer resume attempts are rejected. Releasing a session from its
own synchronous callback is lifetime-guarded, including pause, response, and
detach callbacks. Independently-created `JSWorkerRef` runtimes are not falsely
reported as children of an unrelated context session; they continue processing
messages while that context is paused. Explicit cross-thread worker target
discovery and transport continue under
[#156](https://github.com/zig-utils/zig-js/issues/156); see
[docs/inspector.md](docs/inspector.md).
For scripts registered while debugging, ordinary bytecode/native entry is
disabled and asserted by both focused Zig tests and the real C host; debug-aware
generator/async chunks retain VM statement checkpoints. Pre-attach and generated
script discovery remains tracked by [#155](https://github.com/zig-utils/zig-js/issues/155).

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
zig build test-jit               # small baseline-JIT production-module tests
zig build test-vm                # small bytecode/VM production-module tests
zig build test-concurrency       # small concurrency-primitive tests
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
zig build c-api-audit            # pinned headers/inventory/export drift
zig build test-c-api             # C and C++ compile-link-runtime ABI gate
zig build c-api-jsc-diff         # completed value APIs vs pinned system JSC (macOS)
zig build threads-test            # WebKit PR-249 thread allowlist
zig build threads-reference-audit # classify non-promoted PR-249 files
python3 tools/threads-reference-audit.py --probe-candidates
python3 tools/threads-reference-audit.py --run-probes --expect-current-blockers --probe-timeout 60

zig build threadfuzz
zig build threadfuzz -Dfuzz-midgc=true
zig build threadfuzz -Dfuzz-lifecycle=true
THREADFUZZ_SEED_TIMEOUT_MS=1000 THREADFUZZ_EXPECT_TIMEOUT=1 zig build threadfuzz -Dtsan=true -Dfuzz-amplify=true -Dfuzz-iters=1 -Dfuzz-seed=107
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

tools/zig-cache-tool.sh report      # inspect reproducible local build storage
tools/zig-cache-tool.sh prune       # safely remove only .zig-cache and zig-out
```

The final amplified command is the deterministic TSan watchdog-cleanup gate:
it intentionally interrupts the known-slow seed 107, cooperatively terminates
the VM, and succeeds only after the context has joined its active JavaScript
threads without a sanitizer leak. Ordinary amplified TSan replays use a
calibrated 300-second per-seed watchdog unless
`THREADFUZZ_SEED_TIMEOUT_MS` explicitly overrides it.

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

Completion of every item—and the evidence gate for removing this section—is tracked in [issue #134](https://github.com/zig-utils/zig-js/issues/134).

- full JavaScriptCore framework/private internals, Objective-C bridge, remaining debugger execution/paused-state APIs, and Bun/Home private JSC ABI;
- WebAssembly and JIT shell hooks from the PR-249 reference corpus;
- moving or multi-age generational GC, parallel mid-script minor collection, and any optimizing JIT.

## Used By

- [home-lang/craft](https://github.com/home-lang/craft)

## License

MIT - see [LICENSE](LICENSE).
