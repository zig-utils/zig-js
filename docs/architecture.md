---
title: Architecture
description: The execution model and source map of zig-js.
---

# Architecture

zig-js runs JavaScript through a tree-walking interpreter and a suspendable bytecode VM that share the same object model. The **tree-walker is the semantic baseline**. Supported functions and programs compile to bytecode for suspend-and-resume, a heap activation stack for deep recursion and proper tail calls, and the optimization substrate. Hot bytecode tiers into native code under the [baseline JIT contract](baseline-jit.md), with a further [optimizing tier](optimizing-jit.md) over its documented subset; unsupported code always retains an exact interpreter fallback. [Execution tiers](/advanced/execution-tiers) walks the whole ladder and the divergence risk between its rungs.

## Execution paths

| Path | What it is | What it buys |
| ---- | ---------- | ------------ |
| **Tree-walk** | A direct AST evaluator (`interpreter.zig`). | The correctness baseline and the default path for nearly all code. |
| **Bytecode VM** | AST lowered to a linear instruction stream (`compiler.zig`) run on a stack machine (`vm.zig`). | Suspend/resume for generators, async functions, and async generators; and a heap-allocated activation stack (`vm.runDriver`) so deep recursion and proper tail calls are bounded by the logical call-depth cap, not the native OS stack. Not a general speedup. |
| **Slots & closures** | Slot-allocated locals and frame-linked closures. | Removes hash lookups for locals and captured variables on the VM path. |
| **Shapes & inline caches** | Hidden classes (`shape.zig`) + monomorphic property-access caches. | Object property access without per-access hashmap cost. |
| **Baseline native tier** | AArch64 code compiled at a chunk entry from proven-hot bytecode (`jit.zig`, `jit/aarch64.zig`). | General native throughput, with an exact bytecode fallback for anything the tier cannot represent. |
| **Optimizing tier** | Speculative compilation over an exact documented subset (`jit/optimizer*.zig`). | Profile-driven specialization, with deoptimization back to a precise interpreter state. |

### When each path runs

Because the VM buys capability rather than speed, tiering is deliberately narrow (`plainFunctionMayUseBytecode`, `compiler.zig`):

- **Generators / async / async generators** always compile to the VM — they need suspend/resume, which the tree-walker cannot express.
- A **plain function or method** (non-generator, non-async, not using `arguments`) compiles to the VM only when it can actually benefit: it is strict and may contain a tail call/property operation, or it recurses by its own name (deep recursion that would otherwise overflow the native stack). Method activations preserve their exact home object and `super` constructor. Otherwise the function stays on the tree-walker.
- Everything else — top-level code, and any function using a construct the compiler does not lower — tree-walks.

Because most code tree-walks, the VM path is comparatively under-exercised, so VM/tree-walker semantic divergences are a known bug surface (see the block-scoping note below).

`zig build bench` currently shows VM/tree-walk parity on the saved microbenchmarks, not a broad VM speedup claim. See `docs/.data/bench-2026-07-04.txt` and the README performance table for the current numbers.

## Lexical scoping and the slot model

The VM gives each compiled function one **activation slot array**: locals are frame slots indexed in O(1), and closures capture the defining frame. Compile-time lexical scope maps allocate distinct slots for same-named block, loop, switch, and catch bindings and restore the enclosing binding map on scope exit. Lexical bindings retain TDZ and immutability semantics: when a control-flow scan finds a possible forward reference or repeated lexical spelling, function activation and block entry install the realm's unique uninitialized marker and checked local/upvalue loads throw `ReferenceError`. Assignments distinguish mutable `let` from immutable `const`. Chunks proven free of those hazards keep the ordinary hot load/store opcodes.

Captured identifier bindings and yield-free destructuring bindings without default/computed evaluation in classic `for` and `for-of` heads use fresh declarative Environment Records per iteration, while uncaptured heads retain frame slots. Captured declarations in repeated loop bodies likewise receive a fresh environment at the nested block, catch, or switch scope that owns them; yield-free destructuring without default/computed evaluation uses the same path. Each VM activation tracks its local environment depth, and break/continue records carry their target depth directly or through `finally`, so ordinary and labeled jumps cannot leak a repeated-body binding record into the update or next iteration. Destructuring default/computed evaluation remains on the exact tree-walker path. Deferred class members are admitted when they use only globals or an environment-backed binding, but a member that captures a frame slot rejects its enclosing function. Base constructors without fields can use bytecode; derived constructors and constructors with field initialization retain an explicit tree-walker barrier until bytecode activations model their initialization state.

Admission is observable rather than inferred from a null chunk. Every runtime
`Function` retains a stable `BytecodeAdmissionReason`, and
`Context.bytecodeAdmissionSnapshot()` returns per-realm atomic counts for
program, plain-function, generator, async, and nested-template decisions. This
keeps no-GIL profiles race-free and makes each remaining fallback category an
explicit target for removal. Source-policy skips and null nested-template chunks
retain their exact causal subreason; legacy generic counters remain in the stable
schema but new decisions do not increment them.

Test harnesses can create a context with `TestingOptions.bytecode_execution_mode`
set to `tree_walker` or `required`. The former suppresses bytecode for plain
synchronous code; the latter throws an `InternalError` if a program or called
plain function lacks compiled bytecode. Differential tests can therefore prove
both tier witnesses explicitly instead of treating a silent fallback as VM
coverage. Production contexts always use automatic admission.

## Source map

| File | Responsibility |
| ---- | -------------- |
| `interpreter.zig` | Tree-walking evaluator + flat environment: expressions, statements, control flow, closures, `this`/`new`, exceptions. |
| `parser.zig` | Recursive-descent + precedence-climbing parser → AST. |
| `lexer.zig` | Single-pass tokenizer (escapes, template literals, numeric bases, regex-flag detection). |
| `ast.zig` | The unified `Node` enum for expressions and statements. |
| `compiler.zig` | Bytecode compiler (AST → instruction stream). |
| `vm.zig` | Stack-based bytecode interpreter. |
| `bytecode.zig` | The `Op` instruction-set definition. |
| `value.zig` | The 8-byte NaN-boxed `Value` and the `Object` struct; coercions (`ToNumber`/`ToString`/…), equality, `typeof`. |
| `shape.zig` | Object shapes: a shared transition tree + flat per-object slots. |
| `context.zig` | The engine instance (`JSGlobalContextRef` analog): arena allocator, globals, exception state, microtask queue. |
| `builtins.zig` | Every built-in constructor and prototype method. |
| `promise.zig` | Promise runtime + microtask queue. |
| `jsstring.zig` | Refcounted `JSStringRef` backing. |
| `root.zig` | Module entry point and `installGlobals` bootstrap. |

### Native tiers

| File | Responsibility |
| ---- | -------------- |
| `jit.zig` | Tier records, entry ABI, safepoints, and executable-memory policy. |
| `jit/compiler.zig`, `jit/aarch64.zig` | The baseline tier and its AArch64 emitter. |
| `jit/optimizer.zig`, `jit/optimizer_compiler.zig` | Profiling, plan selection, and the optimizing tier. |

### Memory and concurrency

| File | Responsibility |
| ---- | -------------- |
| `gc.zig`, `gc_runtime.zig` | The precise-collector binding: cell kinds, trace surface, roots. |
| `gc_relocation.zig` | Pointer rewriting and pinning for moving collection. |
| `stack_scan.zig`, `root_handshake.zig` | Conservative native-stack scanning and cross-thread root publication. |
| `gil.zig`, `parallel_lock.zig` | The context lock and the per-structure locks the no-GIL path uses instead. |
| `jsthread.zig` | Shared-realm `Thread`, `Lock`, `Condition`, `ThreadLocal`, property-mode `Atomics`. |
| `worker.zig`, `agent.zig` | Isolated worker agents and the `$262.agent` / `Atomics.wait` waiter table. |
| `shared_buffer.zig`, `structured_clone.zig` | Refcounted `SharedArrayBuffer` storage and the clone/transfer wire format. |

### WebAssembly and embedding

| File | Responsibility |
| ---- | -------------- |
| `wasm/decode.zig`, `wasm/validate.zig`, `wasm/exec.zig` | The binary pipeline: decode → validate → execute. |
| `wasm/simd.zig`, `wasm/atomic.zig`, `wasm/gc.zig` | Post-MVP feature execution. |
| `wasm/api.zig`, `wasm/types.zig` | The JavaScript `WebAssembly` namespace and the feature gates. |
| `c_api.zig` | The exported JavaScriptCore-shaped C API subset. |
| `private_abi.zig`, `private_abi/` | Revision-pinned private consumer profiles. |
| `objc_bridge.m` | The macOS Objective-C bridge. |

### Generated tables

`cldr_*.zig`, `iana_*.zig`, `unicode_*.zig`, `intl_*.zig`, `encoding_*.zig`,
`numbering_systems.zig`, and `text_codec_tables.zig` are produced by the
`tools/gen_*` scripts. Edit the generator, never the table.

## Memory model

A default `Context` owns an **arena allocator**: values and objects are bump-allocated and freed wholesale when the context is released. `Context.Options.heap_limit_bytes` can wrap the context allocator with an outstanding-byte cap for embedders that need a first resource-control boundary; arena-backed caps fail closed, while GC-backed caps can collect and retry at safe allocation-recovery points. Opt-in contexts created with `Context.createWith(.{ .enable_gc = true })` route heap cells through the Phase-7 precise collector and can run quiescent `collectGarbage()`; this reclaims unreachable cells, clears `WeakRef` targets, prunes WeakMap/WeakSet weak keys, queues FinalizationRegistry records, and drains their registered cleanup callbacks as host cleanup jobs at checkpoints. Under the no-GIL threading model the collector also runs **abort-safe mid-script** while other threads execute; see [`docs/threads/production-readiness.md`](/threads/production-readiness) for the current GC status and the remaining pause-time work.

## Concurrency

zig-js supports **GIL-free shared-realm parallelism**. A context created with `Context.createWith(.{ .enable_threads = true })` installs `Thread`, `Lock`, `Condition`, `ThreadLocal`, and property-mode `Atomics`; shared-realm threads run truly in parallel by default, with `.gil = true` available as a serialized compatibility mode. This is [issue #1](https://github.com/zig-utils/zig-js/issues/1) and has its own documentation set under [`docs/threads/`](/threads/) — start with [`production-readiness.md`](/threads/production-readiness) for status and [`memory-model.md`](/threads/memory-model) for the concurrency semantics.

## Why a C API subset?

By exporting an implemented JavaScriptCore-shaped C API subset from `c_api.zig`, embedders that only use that documented surface can try `libzig-js.a` with familiar calls like `JSGlobalContextCreate`, `JSEvaluateScript`, `JSObjectCallAsFunction`, and friends. This is an adoption path, not a reason to freeze inert compatibility parameters before zig-js stabilizes. See the [C API guide](/api).
