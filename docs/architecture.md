---
title: Architecture
description: The execution model and source map of zig-js.
---

# Architecture

zig-js runs JavaScript through a tree-walking interpreter and a suspendable bytecode VM that share the same object model. The **tree-walker is the primary engine** — the semantic baseline and the default execution path. The bytecode VM is a **targeted second path chosen for capability, not throughput**: on the saved microbenchmarks the two run at parity, so the VM exists for what the tree-walker structurally cannot do — suspend-and-resume, and a heap activation stack for deep recursion and proper tail calls — rather than to run supported code faster.

## Execution paths

| Path | What it is | What it buys |
| ---- | ---------- | ------------ |
| **Tree-walk** | A direct AST evaluator (`interpreter.zig`). | The correctness baseline and the default path for nearly all code. |
| **Bytecode VM** | AST lowered to a linear instruction stream (`compiler.zig`) run on a stack machine (`vm.zig`). | Suspend/resume for generators, async functions, and async generators; and a heap-allocated activation stack (`vm.runDriver`) so deep recursion and proper tail calls are bounded by the logical call-depth cap, not the native OS stack. Not a general speedup. |
| **Slots & closures** | Slot-allocated locals and frame-linked closures. | Removes hash lookups for locals and captured variables on the VM path. |
| **Shapes & inline caches** | Hidden classes (`shape.zig`) + monomorphic property-access caches. | Object property access without per-access hashmap cost. |

### When each path runs

Because the VM buys capability rather than speed, tiering is deliberately narrow (`plainFunctionMayUseBytecode`, `compiler.zig`):

- **Generators / async / async generators** always compile to the VM — they need suspend/resume, which the tree-walker cannot express.
- A **plain function** (non-method, non-generator, non-async, not using `arguments`) compiles to the VM only when it can actually benefit: it is strict and may contain a tail call, or it recurses by its own name (deep recursion that would otherwise overflow the native stack). Otherwise it stays on the tree-walker.
- Everything else — top-level code, and any function using a construct the compiler does not lower — tree-walks.

Because most code tree-walks, the VM path is comparatively under-exercised, so VM/tree-walker semantic divergences are a known bug surface (see the block-scoping note below).

`zig build bench` currently shows VM/tree-walk parity on the saved microbenchmarks, not a broad VM speedup claim. See `docs/.data/bench-2026-07-04.txt` and the README performance table for the current numbers.

## Lexical scoping and the slot model

The VM gives each compiled function one **flat, block-transparent slot array**: locals are frame slots indexed in O(1), and closures capture the defining frame. This is fast but does not model per-block lexical scope, so the compiler keeps functions on the tree-walker whenever correct block scoping would matter — a `let`/`const` that shadows another binding, a read in the Temporal Dead Zone (before a binding's declaration), or a `for (let …)` head captured per-iteration by a body closure. The tree-walker's `Environment` chain enforces those correctly. Proper per-block slot scoping on the VM (which would let those functions tier) is possible but unbuilt; it is only worthwhile if the VM becomes a genuine performance tier.

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
| `c_api.zig` | The exported JavaScriptCore-shaped C API subset. |
| `jsstring.zig` | Refcounted `JSStringRef` backing. |
| `root.zig` | Module entry point and `installGlobals` bootstrap. |

## Memory model

A default `Context` owns an **arena allocator**: values and objects are bump-allocated and freed wholesale when the context is released. `Context.Options.heap_limit_bytes` can wrap the context allocator with an outstanding-byte cap for embedders that need a first resource-control boundary; arena-backed caps fail closed, while GC-backed caps can collect and retry at safe allocation-recovery points. Opt-in contexts created with `Context.createWith(.{ .enable_gc = true })` route heap cells through the Phase-7 precise collector and can run quiescent `collectGarbage()`; this reclaims unreachable cells, clears `WeakRef` targets, prunes WeakMap/WeakSet weak keys, makes FinalizationRegistry records available to `cleanupSome()`, and drains automatic FinalizationRegistry cleanup jobs at host checkpoints. Under the no-GIL threading model the collector also runs **abort-safe mid-script** while other threads execute; see [`docs/threads/production-readiness.md`](/threads/production-readiness) for the current GC status and the remaining pause-time work.

## Concurrency

zig-js supports **GIL-free shared-realm parallelism**. A context created with `Context.createWith(.{ .enable_threads = true })` installs `Thread`, `Lock`, `Condition`, `ThreadLocal`, and property-mode `Atomics`; shared-realm threads run truly in parallel by default, with `.gil = true` available as a serialized compatibility mode. This is [issue #1](https://github.com/zig-utils/zig-js/issues/1) and has its own documentation set under [`docs/threads/`](/threads/) — start with [`production-readiness.md`](/threads/production-readiness) for status and [`memory-model.md`](/threads/memory-model) for the concurrency semantics.

## Why a C API subset?

By exporting an implemented JavaScriptCore-shaped C API subset from `c_api.zig`, embedders that only use that documented surface can try `libzig-js.a` with familiar calls like `JSGlobalContextCreate`, `JSEvaluateScript`, `JSObjectCallAsFunction`, and friends. This is an adoption path, not a reason to freeze inert compatibility parameters before zig-js stabilizes. See the [C API guide](/api).
