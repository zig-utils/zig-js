---
title: Architecture
description: The execution model and source map of zig-js.
---

# Architecture

zig-js runs JavaScript through a tree-walking interpreter and a suspendable bytecode VM that share the same object model. The tree-walker is the semantic baseline and fallback; the VM is the compiled path for constructs it can lower safely.

## Execution paths

| Path | What it is | What it buys |
| ---- | ---------- | ------------ |
| **Tree-walk** | A direct AST evaluator (`interpreter.zig`). | Correctness baseline; fallback for constructs the VM does not cover yet. |
| **Bytecode VM** | AST lowered to a linear instruction stream (`compiler.zig`) run on a stack machine (`vm.zig`). | Suspend/resume support for generators, async functions, and async generators; compiled execution for supported code. |
| **Slots & closures** | Slot-allocated locals and frame-linked closures. | Removes hash lookups for locals and captured variables in compiled code. |
| **Shapes & inline caches** | Hidden classes (`shape.zig`) + monomorphic property-access caches. | Object property access without per-access hashmap cost. |

`zig build bench` currently shows VM/tree-walk parity on the saved microbenchmarks, not a broad VM speedup claim. See `docs/.data/bench-2026-07-04.txt` and the README performance table for the current numbers.

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
| `value.zig` | The `Value` union and `Object` struct; coercions (`ToNumber`/`ToString`/…), equality, `typeof`. |
| `shape.zig` | Object shapes: a shared transition tree + flat per-object slots. |
| `context.zig` | The engine instance (`JSGlobalContextRef` analog): arena allocator, globals, exception state, microtask queue. |
| `builtins.zig` | Every built-in constructor and prototype method. |
| `promise.zig` | Promise runtime + microtask queue. |
| `c_api.zig` | The exported JavaScriptCore C-ABI surface. |
| `jsstring.zig` | Refcounted `JSStringRef` backing. |
| `root.zig` | Module entry point and `installGlobals` bootstrap. |

## Memory model

A default `Context` owns an **arena allocator**: values and objects are bump-allocated and freed wholesale when the context is released. Opt-in contexts created with `Context.createWith(.{ .enable_gc = true })` route heap cells through the Phase-7 precise collector and can run quiescent `collectGarbage()`; this already reclaims unreachable cells, clears `WeakRef` targets, prunes WeakMap/WeakSet weak keys, makes FinalizationRegistry records available to `cleanupSome()`, and drains automatic FinalizationRegistry cleanup jobs at host checkpoints. Arbitrary mid-script collection remains future GC work.

## Why a C-API-compatible subset?

By exporting the implemented public JavaScriptCore C-API subset from `c_api.zig`, embedders that only use that surface can swap `JavaScriptCore.framework` for `libzig-js.a` and keep calling `JSGlobalContextCreate`, `JSEvaluateScript`, `JSObjectCallAsFunction`, and friends unchanged. See the [C-API guide](/api).
