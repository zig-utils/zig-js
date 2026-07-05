---
title: Architecture
description: The tiered execution model and source map of zig-js.
---

# Architecture

zig-js runs JavaScript through progressively faster tiers. Everything is correct at tier 0; the higher tiers exist purely to go faster without changing semantics.

## Execution tiers

| Tier | What it is | What it buys |
| ---- | ---------- | ------------ |
| **0 — Tree-walk** | A direct AST evaluator (`interpreter.zig`). The semantic source of truth. | Correctness; the fallback for any construct the VM doesn't cover yet. |
| **1 — Bytecode VM** | AST lowered to a linear instruction stream (`compiler.zig`) run on a stack machine (`vm.zig`). | ~1.1–1.7× on compute-heavy code. |
| **2 — Slots & closures** | Slot-allocated locals and frame-linked closures. | Removes hash lookups for locals and captured variables. |
| **3 — Shapes & inline caches** | Hidden classes (`shape.zig`) + monomorphic property-access caches. | Object property access without per-access hashmap cost. |

Constructs the VM hasn't learned yet (e.g. `throw`/`try` in some paths) transparently fall back to the tree-walker.

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
