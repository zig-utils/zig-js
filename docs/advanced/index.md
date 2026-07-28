---
title: Advanced
description: Operating and extending zig-js — embedding, memory and GC, execution tiers, debugging, and the verification system.
---

# Advanced

The [Features](/features/) section describes what the engine gives your
JavaScript. This section is about **operating and extending the engine itself**:
how to embed it, how memory behaves, how code tiers, how to debug it, and how
its claims are verified.

## Pages

| Page | Covers |
| --- | --- |
| [Embedding](/advanced/embedding) | The Zig `Context` API, options, module hosts, termination, and how it relates to the C and Objective-C surfaces. |
| [Memory & GC](/advanced/memory-and-gc) | Arena vs. precise GC, heap budgets, generational collection, compaction, weak references, and root safety. |
| [Execution tiers](/advanced/execution-tiers) | Tree-walker → bytecode VM → baseline native → optimizing tier, and how to keep them in agreement. |
| [Debugging & tooling](/advanced/debugging) | Inspector protocol, corpus diagnostics, profiles, sanitizers, and the build cache. |
| [Verification & evidence](/advanced/verification) | How every published claim is gated, and how to add a gate. |

## Deep dives elsewhere in these docs

- [Architecture](/architecture) — the execution model and source map.
- [Threads](/threads/) — the full concurrency documentation set.
- [Baseline native tier](/baseline-jit) and [Optimizing JIT](/optimizing-jit).
- [JavaScriptCore C API](/api), [Inspector protocol](/inspector).
- [WebAssembly](/wasm) and the [packed spec runner](/wasm-spec).
- [Benchmarks](/benchmarks), [Conformance](/conformance),
  [Platform matrix](/platforms).
- [Build cache](/dev-cache) — what `.zig-cache/` and `zig-out/` contain and how
  to reclaim them safely.

## Working in the repository

Contributor setup, the full command list, and the commit/PR conventions are in
[`CONTRIBUTING.md`](https://github.com/zig-utils/zig-js/blob/main/CONTRIBUTING.md).
Coding agents should start from
[`CLAUDE.md`](https://github.com/zig-utils/zig-js/blob/main/CLAUDE.md)
(symlinked as `AGENTS.md`), which encodes the same rules plus the traps that have
cost real time here.
