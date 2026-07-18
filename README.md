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
- VM/tree-walker numbers below come from [docs/.data/bench-2026-07-04.txt](docs/.data/bench-2026-07-04.txt); the JSC comparison comes from the [July 17, 2026 structured-stack report](docs/.data/benchmark-comparison-2026-07-17-structured-stacks.md) and its [1,540 raw timing samples](docs/.data/benchmark-comparison-2026-07-17-structured-stacks.tsv).
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

The pinned upstream WebAssembly wg-1.0 corpus is scored separately. All **18,840 / 18,840 applicable binary-runtime commands pass** across all 73 MVP files, with **0 failures** and **0 runner errors**. The checked-in [19,270-command inventory](docs/.data/wasm-spec-inventory.json) records each execution mode: 16,801 commands use the public JavaScript API, 2,039 exact NaN payload/sign commands use the test-only bit-exact path, and 430 text-format parser assertions are explicitly outside the binary API. See [WebAssembly MVP status](docs/wasm.md) for the exact specification/WABT pins and reproduction commands.

The opt-in WebAssembly Core 2 structural profile is also complete against the
official pinned corpus: **27,437 / 27,437 applicable binary-runtime commands
pass** across all 90 `wg-2.0` core files, with **0 failures** and **0 runner
errors**. Its checked-in [28,018-command inventory](docs/.data/wasm-core-2-structural-inventory.json)
accounts for 25,350 public-JavaScript-API commands, 2,087 bit-exact float
commands, and 581 explicitly non-applicable text-format parser commands. This
score covers sign extension, nontrapping conversions, multi-value control,
reference types, and bulk memory/table operations; it does not claim SIMD,
Threads, exceptions/tail calls, memory64/GC, or shell-only hooks. Exact pins,
feature-area subtotals, CI gates, and reproduction are in [WebAssembly status](docs/wasm.md).

Fixed-width SIMD is now executing beyond its complete 236-opcode decoder and
validator foundation. The declared 20-file movement/integer profile from the
pinned 56-file proposal corpus passes **2,253 / 2,253 applicable commands**,
with **0 failures**, **351 explicit text-format n/a**, and **0 runner errors**
at `6306ed59`. The checked-in [2,604-command inventory](docs/.data/wasm-simd-movement-inventory.json)
records every result. Remaining arithmetic/conversion families are tracked by
[#281](https://github.com/zig-utils/zig-js/issues/281) and
[#282](https://github.com/zig-utils/zig-js/issues/282); exact pins and
reproduction are in [WebAssembly status](docs/wasm.md).

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

The latest [full report](docs/.data/benchmark-comparison-2026-07-17-structured-stacks.md) preserves all [1,540 raw timing samples](docs/.data/benchmark-comparison-2026-07-17-structured-stacks.tsv) from clean zig-js commit `01fcf42c`, zig-gc `c67e344d`, and zig-regex `86159c5b` on Apple M3 Pro, 11 physical / 11 logical CPUs, 18.0 GiB. The run used Zig `0.17.0-dev.956+2dca73595`, system framework 22625.1.20.11.3, and AC Power (charged). Every full-run median exceeds the 50 ms timing floor; equal work/checksums, alternating runner order, and per-row dispersion are validated by the harness.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.43x** | — | — |
| independent steady contexts | 8 | 10 / 10 | **2.71x** | **4.67x** | 4.13x |
| independent cold lifecycles | 8 | 9 / 10 | **2.53x** | **4.40x** | 4.07x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **3.84x** | — |

Lower time is better. A throughput ratio above 1.00x favors zig-js. Shared-realm threads share one object graph and therefore have no direct public-JSC embedding equivalent.

| workload | zig-js direct (ms) | JSC direct (ms) | zig-js / JSC throughput | zig-js shared scaling |
| --- | ---: | ---: | ---: | ---: |
| `arithmetic` | 85.429 | 358.819 | 4.20x | 5.34x |
| `properties` | 100.759 | 294.505 | 2.92x | 5.30x |
| `polymorphic_properties` | 97.913 | 209.625 | 2.14x | 4.51x |
| `object_churn` | 96.410 | 129.002 | 1.34x | 0.92x |
| `arrays` | 100.417 | 166.654 | 1.66x | 2.47x |
| `direct_calls` | 81.097 | 122.462 | 1.51x | 5.26x |
| `method_calls` | 86.833 | 148.788 | 1.71x | 4.70x |
| `closure_calls` | 90.154 | 229.340 | 2.54x | 4.88x |
| `arguments_calls` | 96.357 | 326.770 | 3.39x | 4.35x |
| `fibonacci` | 90.338 | 489.696 | 5.42x | 4.54x |

zig-js wins 10/10 direct rows, 10/10 maximum-lane warmed-independent rows, and 9/10 maximum-lane cold-lifecycle rows. The geometric-mean throughput lead is 2.43x direct, 2.71x warmed-independent, and 2.53x cold-lifecycle; shared-realm scaling is 3.84x at 8 lanes.
<!-- benchmark-comparison:end -->

The ABI and WebAssembly/conformance changes through `6306ed59` do not execute in these
benchmark workloads, so the validated 1,540-sample July 17 matrix remains the
latest score set; no unchanged benchmark was rerun for debugger metadata or
WebAssembly module/store/reference-root, reference-call, bulk-memory, or Core 2
corpus/SIMD paths.

Object instances occupy a 128-byte GC slab (`96` bytes of payload and `128` raw bytes including collector metadata). One lazy storage wrapper owns cold/exotic state, external named-slot metadata, dense/internal element metadata, and backing-allocator bookkeeping; a plain object with four or fewer named properties keeps its values entirely inline and allocates none of those side states. In the current matrix, object churn favors zig-js at 96.410 versus 129.002 ms direct and 222.502 versus 229.380 ms across eight warmed contexts. Its 243.603 versus 235.093 ms eight-lane cold lifecycle is the matrix's one JSC win. Shared object churn reaches 1,651.879 ms at eight lanes, 0.92x scaling, and 9.07% RSD, so it remains a clear contention target.

Historical exact-parent studies isolate two important allocation changes: the [128-byte slab A/B](docs/.data/object-churn-128-byte-slab-ab-2026-07-15.md) and the [amortized shared-publication A/B](docs/.data/object-churn-amortized-publication-ab-2026-07-16.md). They remain causal evidence for those changes, but the generated July 17 matrix above is the current complete comparison. See [Performance Benchmarks](docs/benchmarks.md) for boundaries, dispersion, reproduction, and raw evidence.

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

**Built-ins** - `Object`, `Function`, `Array`, `String`, `RegExp` via [`zig-regex`](../zig-regex), `Number`, `Boolean`, `Math`, `JSON`, `Symbol`, `Map`, `Set`, `WeakMap`, `WeakSet`, `Promise`, `Date`, errors, `Proxy`, `Reflect`, `globalThis`, typed arrays, `ArrayBuffer`, `SharedArrayBuffer`, `DataView`, `Atomics`, `WeakRef`, `FinalizationRegistry`, broad `Temporal` and `Intl` coverage, plus the documented [WebAssembly MVP API](docs/wasm.md).

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

The current exported C surface has 136 functions:

- **Context lifecycle** - real shared-VM context groups with distinct realms and cross-realm values, global classes, inspectability with versioned in-process inspector sessions, create/retain/release, global object/context lookup, owned context names, syntax-only checking, evaluation, collection, and the threaded-context extension.
- **Values** - type and Symbol/BigInt predicates, equality/relations/`instanceof`, public-class identity, primitive/fresh-Symbol/exact-BigInt construction, JSON parse/stringify, exact 32/64-bit conversions, coercions, and protected handles.
- **Objects and classes** - complete `JSClassRef` ownership and inheritance, parent-first initialization/child-first finalization, GC-rooted shared prototypes, static functions and values, deterministic enumeration, every dynamic callback family, retained property-name snapshots, `JSObjectMake`, and `JSObjectMakeConstructor`. Foreign-context and invalid callback returns fail deterministically. Private data, prototype get/set, string/Symbol/coerced-key property operations, indexed reads/writes, real Date/Error/RegExp/dynamic-Function/Array/deferred-Promise construction, and function call/construct helpers are also implemented.
- **Typed arrays and buffers** - `JSValueGetTypedArrayType`, the four public `JSObjectMakeTypedArray*` construction paths, typed-array type/bytes/length/offset/buffer queries, and no-copy `ArrayBuffer` construction/bytes/length with exactly-once embedder deallocation.
- **Strings** - UTF-8 and UTF-16 construction, retain/release, UTF-16 length and stable borrowed characters, maximum UTF-8 sizing and conversion, and code-unit/UTF-8 equality.
- **Extensions** - resource-bounded `JSWorker*`, stable worker inspector target metadata and owner-pumped cross-thread sessions, observable `ZJSValueProtect`/`ZJSValueUnprotect`, context-group collection epochs and semantic reachability, threaded contexts, and authenticated-transport-neutral `ZJSInspectorSession*`.
- **Objective-C inventory** - macOS SDK 27.0 build 26A5368g is pinned at 11
  containers / 108 declarations with byte-for-byte header and selector-level
  drift checks. Runtime coverage is 108/108 declarations across
  `JSVirtualMachine`, `JSContext`, `JSValue`, `JSManagedValue`, `JSExport`, and
  typed Objective-C blocks. The macOS system-JSC differential matches all 18
  published Objective-C rows (`360c1ad3ccf51d6b`), including managed-owner
  behavior, same-VM cross-context value identity, exported receivers,
  constructors, prototypes, and target-context wrapper behavior.

`ZJSGlobalContextCreateThreaded`, `ZJSValueProtect`/`ZJSValueUnprotect`,
`ZJSInspectorSession*`, and `JSWorker*` are zig-js extensions, not public JSC symbols. The `ZJSValue*`
variants report invalid handles, refcount overflow, and unmatched unprotects;
the public JSC-compatible calls correctly return `void`. `JSObjectMakeDeferredPromise` returns a pending native Promise plus paired resolving functions; callers observe settlement at the next microtask checkpoint (for example, after `JSEvaluateScript` returns).

The [macOS 27.0 public API inventory](docs/c-api/jsc-public-api-macos-27.0.json)
tracks all 117 pinned C functions and links every unfinished declaration to its
implementation issue. The current audit is **117 implemented / 0 pending**, with
**117 public functions + 19 zig-js extensions** exported. `zig build c-api-audit` checks declaration/export drift;
`zig build test-c-api` additionally compiles, links, and runs real C and C++ hosts.
On macOS, `zig build c-api-jsc-diff` verifies the pinned SDK hashes, compiles the
same value/class and context-group fixtures against zig-js and system JavaScriptCore,
and requires byte-for-byte identical results. The current fixtures match all **34 rows**
(`a8ecd5e83f9f35ca`), including inspectability toggles, shared-VM realm identity/lifetime, global classes,
every class callback family, inherited call and
conversion behavior, ordinary and callback-backed constructors, property-name
snapshots, coerced and Symbol keys, fallback behavior, reflection, attributes,
and callback throws.

The first downstream consumer profile is also pinned and green:
[Home public C profile `home-public-c-7ed99c02`](docs/abi/README.md) records the
exact Home revision and source hashes, all **50 C-calling-convention Zig
externs**, opaque-pointer and enum layouts, and lifetime assumptions. Its audit
reports **50/50 zig-js exports with zero missing**, and its Zig fixture forces
every symbol through the linker before running context, evaluation, retain, GC,
and typed-array checks. This is explicitly a public embedding profile—not a
claim that Home's or Bun's private `JSC__*`/`Bun__*` ABI is implemented.
The separately generated
[Home private inventory](docs/abi/home-private-7ed99c02-inventory.json) makes
that remaining boundary concrete: **448 unique extern symbols from 58 pinned
files**, classified as 431 private (**276 implemented / 155 pending**), 15
already-covered public-C overlaps, one platform import, and one
consumer-generated `JSFunctionCall` definition, with zero duplicate or
unclassified entries.
Exact Home revisions `7ed99c02`, `5e829ad4`, `38702f9e`, and `4389ddee` are
supported; all three newer revisions are verified byte-identical JSC-source
aliases with zero added/removed/changed declarations, not unreviewed moving targets.
The first private-ABI foundation is implemented without changing engine values:
`private_abi.EncodedValue` translates primitives to the pinned eight-byte JSC64
encoding (including exact int32/double/NaN/cell rules), while rejecting
string/object conversion until a validated external cell handle exists.
The first 276 private exports—encoded identity/cell equality, truthiness,
int32 extraction, exact signed/unsigned 64-bit BigInt construction, and
modulo-2^64 BigInt extraction with pinned number fallbacks, plus exact `===` and
SameValue equality, two exact cell-type queries, six opaque BigInt cell
operations, three exact BigInt comparison/arithmetic operations, seven
JSCell/JSString operations, three ordinary-object foundation operations, and
two object-coercion/prototype operations, two numeric DateInstance operations,
four Date parsing/UTC/ISO operations,
nine VM-shared pending-exception operations, 18 exception-scope, termination,
and native-error operations, nine VM heap/accounting/scheduling operations,
one exact VM entry-state query,
two exact JSFunction source/tier-up controls,
one exact internal length projection,
one exact private property-path traversal,
five exact non-indexed property/accessor-cell operations,
seven realm/VM job, rejection, module-registry, and code-invalidation operations,
four debugger async-call scheduling, cancellation, and dispatch operations,
eight VM-owned strong/weak embedding-reference operations,
13 caller-owned native StringBuilder operations,
five rooted native argument/registry container operations,
six stateful Yarr RegularExpression operations,
five WTF parsing, CPU, allocator-release, and HTTP-date helpers,
five live Uint8Array/Buffer constructors plus exact Bun Buffer identity,
one explicit uninitialized Uint8Array allocator,
two generic no-copy ArrayBuffer/TypedArray adopters,
one validated no-copy shared-memfd ArrayBuffer/Uint8Array importer,
one exact JSValue-to-ArrayBuffer view projection,
three independently retained native ArrayBuffer backing-handle operations,
one VM-owned exact `typeof`-string projection,
seven array/index operations, including revalidated contiguous vectors, and
two packed/hole JSArray constructors, full ECMAScript ToNumber coercion, and
exact has-instance/iterator-method predicates, UTF-16 string inclusion,
class/AggregateError classification, private Object keys/values, ten native
Promise/InternalPromise creation, downcast, and wrapping operations, the exact
queued Promise-to-JSHostFn reaction bridge, one exact Promise-chain async Error
stack reconstruction bridge, one exact
CommonAbortReason-to-DOMException conversion, seven direct native Map
operations, and two process warning operations—now pass
focused Zig compile-link-runtime consumer fixtures. The string boundary covers
exact UTF-16 length for astral and lone-surrogate strings, 8-bit eligibility, value equality,
ordinary-object access, primitive boxing, and foreign-context rejection. The
object foundation creates fresh Object.prototype/null-prototype objects and
unwraps Number/String/Boolean/BigInt wrappers with exact int32, double, `-0`,
and NaN encoding. Private ToObject preserves ordinary-object identity, boxes all
five object-capable primitive kinds in the selected realm, rejects nullish and
foreign inputs, and observes proxy and null prototypes exactly. The
numeric DateInstance boundary creates selected-realm Date cells without
constructor TimeClip and preserves fractional values, signed zero, NaN,
infinities, and out-of-range internal numbers. Its parsing/formatting companion
creates fresh Date cells from complete NUL-terminated strings, extracts owned
UTC epoch milliseconds, and writes exact 24- or 27-byte UTC ISO text without a
terminator or partial failure. `Date.now()`, `Date()`, and `new Date()` now share
the real Unix wall clock used by the private Date-now writer. The pinned Bun Zig
declaration for that writer is stale; zig-js implements the executable Bun
wrapper/C++ `(global, *[28]u8) -> c_int` contract. The
pending-exception boundary gives sibling realms one VM identity and one stable
exception cell, preserves arbitrary thrown primitives and Error identity, and
supports has/clear/take/rethrow plus exact exception/Error classification. The
companion exception-control boundary stores the pinned top scope in caller-owned
8- or 56-byte, 8-aligned memory, separates pure reads from trap-aware termination
materialization, and keeps one stable VM-wide termination exception across
sibling realms. Atomic request/clear operations, termination-preserving selective
clear, the pinned set-only execution-forbidden flag, selected-realm
OutOfMemoryError/RangeError creation, and first-exception preservation are all
covered. Nine VM heap controls now report VM-shared live, external, and
saturating extra-memory totals; request deferred collection; return the exact
post-full-collection size; process weak state; reclaim idle footprint; and run
queued jobs only at a positive-duration opportunistic checkpoint. Precise heaps
use zig-gc's race-safe live/last-full snapshot, while arena VMs report committed
arena capacity. The seven job/registry controls retain native callback payloads
until exactly-once execution, validate encoded jobs against the selected VM,
drain one realm or every live VM realm to quiescence, preserve queued work after
a throwing job, and emit each still-unhandled rejection once. Module registry
entries persist per realm until exact ZigString deletion; `deleteAllCode` drains
jobs, clears the selected realm's module/source caches, waits for executing or
compiling native leases, invalidates every tier before unmapping executable
pages, and leaves later calls on safe bytecode/recompilation fallback. Eight
strong/weak embedding-reference exports preserve Bun's direct EncodedJSValue
slot layout, root strong values across collection, accept sibling realms, and
reject foreign-VM replacement. Weak object targets use atomic zig-gc slots and
clear without retention; collected FetchResponse owners are notified once
outside the collector lock, while explicit clear/delete suppress notification.
Both wrapper kinds retain their VM until deletion and synchronize root-list
mutation with concurrent tracing. The StringBuilder boundary keeps the pinned
24-byte/8-byte caller-owned layout, preserves Latin-1, UTF-8, UTF-16, astral
pairs, and lone surrogates, and formats integers and doubles with WebKit's
shortest-roundtrip rules. JSON quoting uses WebKit's exact control, quote,
backslash, and unpaired-surrogate escapes; overflow stays sticky until
`toString` publishes OOM without replacing an existing VM exception. Repeated
conversion is non-destructive. The
marked-argument callback owns a synchronous opaque buffer whose appended cells
are precise-GC roots only for the callback extent; cross-VM cells are rejected
and cleanup is unconditional. Per-realm CommonJS extension registries root
their values and reproduce JSC append, replacement, and swap-remove index
semantics without leaking state into sibling realms. The
array boundary creates exact logical lengths and holes, distinguishes missing
indices from present `undefined`, performs direct indexed writes and pushes
without invoking inherited setters, observes prototypes/getters through the
ordinary indexed read, publishes abrupt completion to the VM exception slot,
and covers sparse and maximum-u32 length boundaries. The JSArray constructor
pair validates every input before exposing a result, builds packed elements in
order with exact owned-cell identity (including sibling realms in the same VM),
creates hole-only arrays through the maximum u32 length, and publishes
foreign-item or invalid-length failures atomically. The paired
contiguous-vector boundary exposes exact JSC64 snapshots only for
safe packed Int32/boxed arrays and revalidates array, vector, length, backing,
shape, prototype chain, and element encodings before every fast read. It keeps
simultaneous iterators independent, survives GC, and invalidates to ordinary
indexed Get after replacement, growth, holes, accessors, double/undecided
storage, or prototype pollution without observing pending exceptions. The
shared-memfd boundary duplicates the caller descriptor only long enough to
validate and map it, verifies the complete regular-file extent and requested
slice without overflow, and exposes the selected profile's exact ArrayBuffer or
Uint8Array tag over a writable `MAP_PRIVATE` view. It never consumes the caller
descriptor, never copies the slice, and unmaps the complete original region
exactly once on construction failure, precise collection, or realm teardown.
Invalid descriptors, ranges, sizes, and result tags return empty without a
partial owner or a replacement exception. The
[`IDLArrayBufferRef` contract](docs/abi/array-buffer-handle-contract.json)
implements the pinned `RefPtr<JSC::ArrayBuffer>` producer and `leakRef()`
transfer as an independently reference-counted backing handle. Its bytes
outlive the JavaScript wrapper, realm, and VM; atomic `ref`/`deref` operations
cannot underflow or steal wrapper/tracking ownership; external storage runs its
callback exactly once after the final owner; and `asBunArrayBuffer` fills the
exact 40-byte borrowed projection with stable pointer, length, shared, and
resizable state. The generated fixture covers required, optional, and union
consumer fields, explicit clone/drop, live resize, teardown, over-release, and
shared/external storage. The
ToNumber boundary preserves all primitive conversions, runs ordinary
object-to-primitive hooks in spec order, distinguishes ordinary NaN from
exceptional NaN, throws for Symbol/BigInt, accepts same-VM sibling values, and
publishes conversion or
foreign-value failures without replacing an existing exception. The predicate
pair matches JSC's private boundaries rather than language-level shortcuts:
has-instance prechecks internal capability before running callable/custom/proxy
logic, while iterator detection rejects primitives and performs object
`GetMethod`, including getters, callability errors, and VM exception
publication. Private string inclusion performs full receiver-then-search
ToString coercion and searches UTF-16 code units, including surrogate halves
inside astral characters, while preserving thrown values and VM ownership.
Class classification distinguishes JS class executables, native constructors,
bound functions, and constructable proxies; AggregateError uses immutable
internal error metadata rather than spoofable properties. Context-group sibling
realms now also share well-known Symbol identity and the Symbol registry.
Private Object reflection returns fresh selected-realm arrays in exact own
enumerable string-key order: keys avoid value reads, values perform ordered Get,
proxy traps and thrown getters propagate through the shared exception slot, and
string wrappers enumerate UTF-16 code units rather than UTF-8 bytes. The
private Promise boundary creates selected-realm pending and directly settled
native promises, preserves exact result/reason identity without accidental
thenable assimilation, and aliases InternalPromise to the pinned JSPromise cell
type. Callback wrapping passes native promises through, converts thrown values
and Error instances into rejections, and uses normal resolution—including
thenable assimilation and self-resolution rejection—when settling an existing
AnyPromise. `JSC__JSValue___then` attaches distinct fulfillment and rejection
callbacks without allocating a dependent Promise. Delivery is never inline:
the selected JSHostFn runs from the realm's FIFO Promise queue with exact JSC64
arguments `(settlement value, retained context)`. The reaction graph stays
rooted through GC; sibling realms, later settlement, nested registration,
callback throws, and post-throw queue preservation are covered. The private Map
boundary creates selected-realm native maps and
operates directly on `[[MapData]]`, bypassing mutable userland prototypes while
preserving SameValueZero keys, insertion/reinsertion order, exact value identity,
and failure-atomic same-VM ownership checks. The shared FFI slow paths convert
validated JSC64 BigInt cells with exact signed/unsigned modulo-2^64 behavior,
including arbitrary-size values. Common abort reasons now create fresh
selected-realm `TimeoutError`/`AbortError` DOMExceptions with the pinned
messages and legacy codes. BigInt decimal conversion returns the pinned
24-byte `BunString` with a fresh refcount-one 8-bit `WTFStringImpl`; matching
atomic ref/deref/destroy exports make ownership explicit for Zig and Rust
consumers. Four BunString conversion exports decode every pinned Empty,
Dead, 8/16-bit WTFStringImpl, and Latin-1/UTF-8/UTF-16 ZigString representation;
they preserve lone surrogates, truncate by UTF-16 code unit, transfer ownership
only after success, and construct selected-realm arrays failure-atomically.
Four ZigString error bridges create fresh selected-realm Error, TypeError,
RangeError, and SyntaxError objects with exact messages and intrinsic
prototypes. The complete ZigString DOMException bridge covers every pinned
code from 0 through 40: WebCore names, messages, and legacy codes; Bun's
intentional code-9 SyntaxError divergence; the RangeError, TypeError, ordinary
Error, and undefined special branches; Node-style error codes; caller-message
override; and the unknown-code empty-name DOMException fallback. It selects the
requested realm and preserves the first pending exception. Four copied, atomic,
and rope string constructors now cover all tagged ZigString encodings, raw UTF-8
validation, mutation-safe copying, VM-scoped atom backing, ordered observable
ToString coercion, exact UTF-16 concatenation, sibling realms, foreign-VM
rejection, and first-exception preservation. Two borrowed ZigString output
bridges provide stable group-lifetime views: untagged Latin-1 for 8-bit strings
and bit-63-tagged UTF-16 otherwise. JSValue output performs full ToString and
publishes abrupt completion without replacing an existing exception. Five
private error factories create fresh selected-realm Error, TypeError, and
RangeError instances from every ZigString/BunString representation. Coded
RangeErrors expose a read-only `code`; coded TypeErrors retain the pinned
writable descriptor. Three AggregateError bridges create ordered fresh error
arrays or preserve an existing exact array/cause, install standard non-enumerable
descriptors, and read `errors` directly without consulting mutable prototypes.
Eight property-boundary exports now create two-key selected-realm objects with
the pinned key-2-first definition order, distinguish direct own writes from
observable property-key coercion, implement ordinary deletion, and provide
prototype-aware, pollution-mitigated, and own-only reads with exact
empty/deleted sentinels. Numeric and Symbol keys, accessors, proxies, duplicate
keys, sibling realms, Latin-1 names, foreign values, and first-exception
preservation are covered without adding a second observable `has` lookup.
The separate property-path export reproduces the pinned permissive UTF-16
dot/bracket grammar and string/number array paths. It boxes each traversed value
with `ToObject`, performs one ordinary `Get` per segment, distinguishes absent
properties from present `undefined`, and preserves inherited array entries,
proxies, numeric key formatting, and abrupt completion without adding a `has`
trap.
Four class/display-name projections now distinguish stable static class-info
metadata from calculated instance names and observable display-name lookup.
They preserve function/internal names, constructor-derived class names,
VM-inquiry `@@toStringTag` behavior for class calculation, one observable tag
read for name projection, stable borrowed ZigString views, and owned Latin-1 or
UTF-16 BunString results.
The normal and fast private JSON writers now share the complete runtime
serializer while preserving their pinned space arguments: an unsigned,
ten-space-clamped indent versus `undefined` for compact output. Both retain
`toJSON`, getters/proxies, ordering, omission/null, BigInt/cycle errors, Unicode
escaping, selected-realm execution, and owned BunString lifetime.
Two native record-construction exports now reproduce the pinned direct object
boundary. `fromEntries` creates a selected-realm ordinary object, copies every
ZigString key/value, preserves duplicate last-value and integer-key ordering,
and makes both clone modes independent of caller-buffer mutation. `putRecord`
maps zero, one, or multiple values to an empty array, scalar string, or ordered
string array, then defines a writable/enumerable/configurable own property
without invoking inherited setters. Invalid pointers, oversized counts,
foreign VMs, allocation failure, and existing exceptions fail without exposing
a partial object or replacing the first exception.
The private JSX predicate performs one ordinary `$$typeof` read and accepts
only the VM registry identities for `react.element` and
`react.transitional.element`. Inherited properties, accessors, proxies, and
same-VM sibling realms retain normal JavaScript behavior; local symbols,
description impostors, primitives, and foreign VMs fail, while abrupt and
pre-existing exceptions remain first-wins.
The paired core deep-equality exports reproduce Bun's pinned structural engine.
Both use SameValue primitives, active cycle-pair tracking, enumerable
string/Symbol traversal, unordered deep Map/Set matching, and exact handling
for arrays, boxed strings, Dates, RegExps, Errors and causes, ArrayBuffers,
DataView, and numeric TypedArrays. Strict mode adds calculated-class,
sparse-hole, property-count, missing/undefined, cause-presence, and
bitwise-float distinctions. Both boundaries preserve getter/proxy exceptions,
same-VM sibling values, foreign rejection, bounded recursion, and first-wins
pending state.
The three Jest-aware variants add right-first asymmetric dispatch for
anything/any, string-containing/matching, array/object-containing, close-to,
settled-promise, negation, and custom `jest.asymmetricMatcher` hooks. Recursive
deep matching preserves inherited-property lookup, exact array subsets,
independent cycle sets, nested object-containing exhaustiveness, Symbols, and
optional direct replacement of matched properties. Non-Jest equality never
consults those hooks.
Five process-wide remote-inspector controls implement one-way auto-start
disable, explicit idempotent start, console-log selection, and an atomic
get/set inspection default. Apple-family targets use modern JSC's deterministic
disabled default while other targets default enabled; callers can override it
without coupling it to per-context inspectability.
The proxy inspector projection returns the live target or handler directly
without invoking a trap, returns `null` after revocation, and rejects non-proxy
or unknown-field inputs. A VM-wide canonical private-object handle table keeps
the returned EncodedJSValue bit-identical across repeated publication and
sibling realms while preserving independent-VM isolation.
Stable script-execution-context identifiers are assigned lazily from a
process-wide atomic sequence. Every live global receives one nonzero 32-bit ID;
sibling realms remain distinct, repeated reads are stable, parallel independent
creation is race-free, and identifier reads never disturb pending exceptions.
Pure diagnostic stringification now covers exact Number, Boolean, null,
undefined, arbitrary-size BigInt, and Symbol forms, returns input strings by raw
identity, and maps every other value to `[object Object]`. It bypasses getters,
proxies, conversion hooks, and mutable globals while preserving pending state.
Unhandled-rejection error-like classification now matches JSC's own-`stack`
descriptor test. Data and accessor descriptors count without reading a value;
inherited properties do not, and proxy descriptor traps remain exactly
observable with abrupt completion published through the VM exception channel.
Process warning emission now normalizes strings and Error instances with pinned
type/code/detail descriptors, queues FIFO realm-local `warning` events, and
preserves selected-realm prototypes and listener failures. The rejection path
emits the reason warning followed by Bun's exact
`UnhandledPromiseRejectionWarning`, clears throwing stack reads, and falls back
to pure diagnostic stringification.
Process rejection and fatal dispatch preserves exact reason/Promise identity,
sends `uncaughtExceptionMonitor` before capture or ordinary handlers, gives a
capture callback precedence, and uses the pinned origins and handled return
codes. The rejection wrapper has Bun's exact `UnhandledPromiseRejection` name,
code, and message. Promise checkpoints suppress early-handled rejections, emit
one `unhandledRejection`, then emit one `rejectionHandled` if the same Promise
gains a late handler; repeated checkpoints do not duplicate either event.
`beforeExit` and one-shot `exit` use the same realm-local listener store.
`process.nextTick` now has its own precisely rooted FIFO instead of masquerading
as a Promise job. The two private scheduling exports retain exact one- and
two-argument calls, next ticks drain before microtasks, and the checkpoint loops
after the Promise phase if it queued more next-tick work. Reentrant scheduling,
handled and fatal callback failures, foreign-VM rejection, and `_exiting`
suppression are covered.
IPC-to-process dispatch now gates `message`, `error`, and `disconnect` on an
existing listener before decoding. This preserves exact value/handle identity
and event arity while making absent-listener calls—including `error` with a
foreign value—true no-ops. Sibling-realm delivery, once/removal behavior,
foreign-VM rejection when observed, and listener throws are covered.
Native iterable traversal now performs one exact `@@iterator` acquisition,
caches `next`, and forwards every IteratorValue with stable VM/global/context
metadata. Arrays, strings, Map/Set, generators, and custom iterators preserve
observable order; callback exceptions close the iterator without replacing the
first failure.
Non-indexed property traversal now returns exact JSType 7 GetterSetter and
JSType 8 CustomGetterSetter cells without invoking accessors, while preserving
stable descriptor identity across sibling realms and callback-triggered GC.
It visits own string/Symbol keys in pinned order, filters indices, length,
constructor, private/internal keys, and the non-enumerable special cases, clears
property-read failures where JSC does, and stops immediately on a callback-published
exception. The 278/278 compiled fixture covers data and every accessor shape,
C-class accessors, proxies, Symbols, filtering, reentry, GC, and foreign inputs.
ZigString JSON parsing now constructs selected-realm values from every tagged
string form. Syntax failures are returned as cleared SyntaxError values exactly
as Bun expects, while impossible over-limit spans are rejected before pointer
access with `ERR_STRING_TOO_LONG`.
Three fast built-in-name reads pin all 24 byte IDs, including the two Symbol
keys, and preserve direct-data, own-slot, and pollution-mitigated lookup as
separate operations. Bun's additional pure `code` VM inquiry walks data slots
without invoking accessors, custom hooks, or proxies.
Three Symbol bridges decode every ZigString form into the VM-wide global
registry and expose stable borrowed description/registry-key views. C-API
sibling realms now share the registry even before their first `Symbol.for`,
while local and well-known Symbols remain correctly absent from `keyFor`.
The three private module-loader exports now provide and normalize source under
persistent per-realm keys, resolve relative dependencies from supplied source
or the filesystem, preserve namespace/cache identity, and return JSC's exact
fulfilled/rejected/pending boundary across synchronous evaluation and
top-level await. Module completion promises, deferred namespaces, cached
errors, and namespace waiters are precise-GC roots. The private JSString
backing iterator validates the caller-owned callback layout and delivers exact
Latin-1 or UTF-16 units without coercion, including embedded NUL, astral pairs,
lone surrogates, empty strings, and stop/null/foreign boundaries. The
`JSFunction__createFromZig` bridge creates selected-realm native functions with
owned names, exact `name`/`length` attributes, and the pinned JSC64 `CallFrame`
register layout for ordinary calls and explicit constructors. It validates
returned cells and translates callback exceptions without losing identity.
The three CallFrame introspection exports associate each synchronous callback
with its exact owning VM and visible JavaScript caller while leaving those
registers unchanged. They return an owned source URL with one-based coordinates,
recognize `builtin://bun/main`, preserve nested/reentrant frames, reject stale or
foreign inputs, and provide a stable NUL-terminated debug description.
The four FFI-function exports reuse that exact callback path while branding FFI
functions separately from ordinary native functions. They own names and arity,
support the upstream call/construct behavior, keep atomic nullable `dataPtr`
state independent from dynamic-library metadata, and optionally expose the
callback address bit-cast as the read-only enumerable `ptr` number. Valid FFI
cells remain introspectable across VMs; ordinary functions and immediate values
are rejected without mutation.
`JSC__Exception__getStackTrace` independently projects retained creation-time
function/module/global frames through the exact consumer layouts, with owned
names/URLs, zero-based positions, async/constructor metadata, and no parsing of
the mutable formatted `.stack` property. Full `ZigException` conversion adds
the exact 216-byte record, owned error/system metadata, cause runtime type,
stable exception-cell identity, and capped current/preceding source lines from
the retained script rather than `.stack`. Native/event-loop errors can also
recover exact async function, source, and suspension positions from pending
Promise await and transparent forwarding chains. The walker preserves existing
or materialized stacks, honors the selected realm's `Error.stackTraceLimit`,
stops at combinators/settled links or after 32 transparent hops per frame, and
keeps activation links precise across GC without retaining completed work. The
278-symbol combined fixture covers sibling realms, foreign-VM rejection,
callback reentrancy, exception clearing, and already-settled targets.
The BigInt cell gate downcasts only real owned cells, compares arbitrary-size
values exactly against i64/u64/f64 (including 2^53, subnormal, infinity, and 10^400
boundaries), performs signed modulo-2^64 extraction without lossy double
conversion, and returns owned decimal text across same-VM sibling realms. The
value-level BigInt gate preserves JSC's four comparison results,
adds arbitrary-size values without narrowing, and reproduces the pinned
`sec * 1_000_000 + nsec` timeval formula at both signed i64 extremes. The
constructors return real context-owned BigInt cells.
The [full private `JSType` layout](docs/abi/private-jstype-layouts.json) proves
that Home has 97 members while Bun has 98: Bun's one inserted tag renumbers 70
later members. `-Dprivate-abi-consumer=home|bun` selects the exact layout, and
separately compiled fixtures pass 20 real cell kinds for each, including exact
GetterSetter and CustomGetterSetter tags. All 276 private exports remain
excluded from the 117-function public count and 19
extensions.
The separate pinned
[Bun core inventory](docs/abi/bun-private-core-4982b91e-inventory.json) contains
437 symbols from 54 `src/jsc` files: 421 private (**268 implemented / 153
pending**), 15 public overlaps, and one consumer-generated `JSFunctionCall`
definition. Its exact comparison with Home finds 434
shared names, 3 Bun-only names, 14 Home-only names, and 28 changed signatures;
neither private profile is inferred from the other.
The pinned public C inventory has no pending declarations. Inspector sessions
now publish stable scripts and exact statement locations, and provide real
`debugger;`, explicit pause/resume control, and deterministically resolved
script/URL breakpoints with removal. Logical-depth step-into, step-over, and
step-out cover ordinary calls plus suspendable generator/async VM execution,
alongside none/all/uncaught exception pause policy and thrown-exception events.
The four pinned private debugger async-call hooks now copy scheduling stacks
without rooting their originating realm, key calls by exact type and callback
ID, preserve nested/reentrant dispatch ancestry, and retire cancelled or
single-shot work at the matching lifecycle boundary. Their
[`enum(u8)` and forwarding contract](docs/abi/debugger-async-call-contract.json)
pins all five call types and the upstream no-agent fast no-op. While a task is
dispatching, `Debugger.paused` includes its owned `asyncStackTrace`; completion,
disable, detach, and teardown clear the ancestry deterministically.
The [machine-readable protocol inventory](docs/inspector-protocol-0.1.json)
contains both implemented transports, 20 commands, and 8 events with no hidden
accepted stubs.
Every paused event now includes the live JavaScript call stack with stable
pause-local frame IDs, function/source locations, `this`, and lexical, block,
closure, and summarized global scope chains across tree-walker and suspendable
VM execution, plus warmed ordinary VM activations. `Debugger.evaluateOnCallFrame` reads and mutates those live
lexical bindings while preserving the paused program's control/exception state.
Session-owned remote values and scope handles support non-invoking own-property
inspection plus explicit object/group release; values are protected across GC,
while pause-only scope handles expire on resume. With multiple sessions, one
deterministic owner controls continuation after observers receive the pause
snapshot; observer resume attempts are rejected. Releasing a session from its
own synchronous callback is lifetime-guarded, including pause, response, and
detach callbacks. Independently-created `JSWorkerRef` runtimes have stable
process-wide target IDs and explicit owner-pumped inspector sessions; commands
run only on the worker runtime thread, including while paused, while callbacks
run only on the worker-handle owner thread. Script and module targets publish
their source graphs, first-statement `debugger;` pauses are retained in bytecode,
multiple sessions preserve deterministic continuation ownership, and detach or
termination unblocks a paused target. Worker transcripts also cover URL
breakpoints, stepping, caught-exception pauses, live frames/scopes and frame
evaluation, and GC-rooted remote-object property inspection. Two workers and a
main context can pause simultaneously and resume independently. Session detach
and whole-worker release each synchronously complete runtime-side cleanup,
unroot retained values exactly once, and close accepted pending traffic. The
completed worker-target matrix is recorded in
[#156](https://github.com/zig-utils/zig-js/issues/156); see
[docs/inspector.md](docs/inspector.md).
For scripts registered while debugging, ordinary bytecode/native entry is
disabled and asserted by both focused Zig tests and the real C host; debug-aware
generator/async chunks retain VM statement checkpoints. Script identity/source
history is now context-owned, so late attach and detach/reattach publish the same
pre-existing scripts. Historical bytecode carries latent checkpoints; attachment
disables native entry and exposes live named VM slots, so breakpoints, stepping,
and frame evaluation work inside warmed functions without recompilation.
Direct and indirect eval now publish independent sourceURL-aware scripts on
every successful parse, including repeated identical evaluations. All supported
generated-function constructors do the same, and `JSObjectMakeFunction` preserves
its explicit URL/starting line. JavaScript module graphs publish canonical
entry/dependency paths and exact sources, with graph-local deduplication and
working module breakpoints. The completed origin/teardown matrix is recorded in
[#155](https://github.com/zig-utils/zig-js/issues/155).

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
zig build home-public-abi-audit  # pinned Home revision-independent profile gate
zig build test-home-public-abi   # Home Zig consumer compile-link-runtime gate
zig build home-public-abi-audit -Dhome-source-root="$HOME/Code/Home/lang"
zig build home-private-abi-audit # 448-symbol pinned private denominator
zig build home-private-abi-audit \
  -Dhome-private-abi-profile=home-private-4389ddee \
  -Dhome-source-root="$HOME/Code/Home/lang"
zig build test-private-abi-value # exact JSC64 value codec + internal bridge
zig build test-home-private-abi # implemented Home private shim slices
zig build test-home-private-abi \
  -Dhome-private-abi-profile=home-private-4389ddee \
  -Dhome-source-root="$HOME/Code/Home/lang"
zig build bun-private-abi-audit # pinned 437-symbol Bun core denominator
zig build bun-private-abi-audit -Dbun-source-root="$HOME/Code/bun"
zig build private-jstype-abi-audit # exact 97-member Home / 98-member Bun layouts
zig build test-private-jstype # default Home private tag profile
zig build test-private-jstype -Dprivate-abi-consumer=bun # separately compiled Bun tags
zig build objc-api-audit         # pinned Objective-C header/inventory drift gate
zig build test-objc-api-headers  # macOS ARC/blocks header compilation gate
zig build test-objc-api          # macOS Objective-C compile-link-runtime gate
zig build objc-api-jsc-diff      # Objective-C Foundation conversion vs system JSC
zig build test-objc-api-lifetime # 200-cycle VM/wrapper/autorelease teardown stress
zig build test-objc-api-sanitize # lifetime stress under ASan + UBSan
zig build test-objc-api-leaks    # lifetime stress under Apple's leak checker
zig build test-objc-api-faults   # deterministic allocation/registration rollback
zig build test-objc-api-evidence # complete Objective-C bridge evidence matrix
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

The isolated `Worker` implementation lives in [src/worker.zig](src/worker.zig) and is exposed to C embedders through the `JSWorker*` extension functions. Workers use their own precise GC heap by default rather than retaining every allocation until join. `ZJSWorkerGetInspectorTargetInfo` and `ZJSWorkerInspectorSession*` provide stable target metadata plus cross-thread debugging without exposing the worker Context.

Current thread status is tracked in:

- [docs/threads/index.md](docs/threads/index.md)
- [docs/threads/testing.md](docs/threads/testing.md)
- [docs/threads/memory-model.md](docs/threads/memory-model.md)
- [issue #1](https://github.com/zig-utils/zig-js/issues/1)

The README intentionally avoids duplicating the detailed thread/GC implementation log; those docs and the commands above are the source of truth.

## What Is Not Implemented

Do not read the green configured runner as "the whole JavaScript universe is finished." Known non-implemented or non-scored areas include:

Implementation is tracked by [roadmap #134](https://github.com/zig-utils/zig-js/issues/134),
and the final evidence-backed removal of this section is tracked by
[issue #246](https://github.com/zig-utils/zig-js/issues/246).

- full JavaScriptCore framework/private internals and Bun/Home private JSC ABI;
- the remaining post-Core-2 WebAssembly profiles and WebAssembly/JIT shell hooks
  from the PR-249 reference corpus, including remaining SIMD arithmetic/conversions, Threads, exceptions/tail
  calls, and memory64/GC (the complete MVP binary runtime, JavaScript API,
  opt-in Core 2.0 structural profile, the exact pinned 236-opcode SIMD
  type/decoder/validator foundation, complete feature-gated reference instructions, typed multi-table runtime,
  precise-GC funcref/externref slots, arbitrary externref Table/Global identity
  and reclamation, canonical reference-valued function calls, and complete
  DataCount/passive-segment bulk memory and table operations,
  exact 27,437-command applicable upstream score, and [version-pinned planned profile registry](docs/.data/wasm-feature-profiles.json)
  are documented in [WebAssembly status](docs/wasm.md));
- moving or multi-age generational GC, parallel mid-script minor collection, and any optimizing JIT.

## Used By

- [home-lang/craft](https://github.com/home-lang/craft)

## License

MIT - see [LICENSE](LICENSE).
