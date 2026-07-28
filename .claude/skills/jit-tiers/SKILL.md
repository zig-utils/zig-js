---
name: jit-tiers
description: Work on the zig-js native execution tiers — the baseline AArch64 tier and the optimizing tier, their tier records, entry ABI, safepoints, deoptimization, executable-memory policy, and the forced-off/forced-on differential gates. Use when the task mentions the JIT, native tier, tiering, OSR, deopt, profiling counters, NativeFrame, MAP_JIT, or a bug that only appears with enable_jit on.
---

# Native tiers (baseline and optimizing)

Above the bytecode VM sit two native tiers: the **baseline** tier (issue #52,
[`docs/baseline-jit.md`](../../../docs/baseline-jit.md)) and the **optimizing**
tier (issue #146, [`docs/optimizing-jit.md`](../../../docs/optimizing-jit.md)).
Code lives in [`src/jit.zig`](../../../src/jit.zig) and
[`src/jit/`](../../../src/jit/) (`compiler.zig`, `aarch64.zig`, `optimizer.zig`,
`optimizer_compiler.zig`).

## 1. The rules the tiers exist under

- **It must never recognize a benchmark, source string, or function name.** The
  tier is for general throughput.
- **An exact interpreter fallback is always retained.** An unsupported plan or
  operation means bytecode/baseline execution, never a semantic approximation.
- Every `Chunk` owns one atomic tier record: `cold` → `compiling` → `ready` /
  `rejected`. Only the winner of `cold → compiling` allocates code; other
  threads keep interpreting. Publication uses release/acquire ordering.
  **Rejection is cached** so unsupported bytecode does not re-enter the compiler.
- Compilation happens only at a **chunk entry**, never inside the opcode loop.
- Generated code is **immutable after publication**, and a tier record may be
  shared by JavaScript `Thread`s — so publication and rejection must stay
  race-safe. Context teardown owns all generated mappings and waits until no
  engine thread can execute them.
- A side exit at an unsupported instruction must reconstruct an **exact** `Exec`
  state: operand stack, accumulator, instruction pointer, handler stack, frame.

## 2. Entry ABI and safepoints

The native entry point takes one pointer to a stable `NativeFrame` defined by the
JIT module — never Zig's private calling convention or the in-memory layout of
`Interpreter`/`Exec`.

Back edges and calls are **safepoints**. Before either, native code spills live
values and publishes the current instruction pointer, and the runtime stub
applies the same obligations as `runChunk`:

- increment and enforce the evaluation step budget;
- observe worker termination;
- yield a contended JavaScript GIL when configured;
- service a requested precise-GC safepoint with all values visible;
- preserve the handler stack and pending exception.

**Until precise native stack maps exist, no GC pointer may be live only in a
machine register across a safepoint.** This is the easiest way to introduce a
rare, GC-timing-dependent crash.

Compaction: direct `Context.compactGarbage` movement is permitted between
evaluations once the active-interpreter registry proves no `NativeFrame` exists.
`requestGarbageCompaction` may also be serviced inside the AArch64 numeric tier's
checkpoint island — it publishes canonical locals, spills live operands, and
keeps only numeric managed state in registers. Every generic VM, host-callback,
side-exit, exception, other-thread, and conservative-stack boundary stays
**fail-closed**.

## 3. Executable memory

Write-xor-execute. The emitted backend is **AArch64 on Darwin**: `MAP_JIT`
mappings, `pthread_jit_write_protect_np` around writes, then
`sys_icache_invalidate`. Unsupported targets leave the tier disabled and continue
in bytecode; tests that execute generated entries skip when the backend is
unavailable. Other POSIX transitions and an x86-64 emitter are future work.

## 4. The optimizing tier's foundation

Profiling provides per-function entry, branch, backedge, result/property
value-kind, and shape observations, with per-entry local deltas merged atomically
once so hot loops do not perform atomic increments. Publication is a serialized
state machine with its own generation counter, distinct from baseline code; stale
claims are rejected and unsupported plans are cached. **Compile counts advance
only when an executable optimizer artifact is installed** — a count that moves
without an artifact is an accounting bug, not a success.

Deoptimization is built on a backend-neutral runtime-operation ABI appended to
`NativeFrame`: one callback selects an immutable operation descriptor and returns
a distinct status for normal value, catchable exception, termination, watchdog
expiry, debugger trap, host trap, allocation failure, or invalidation. Normal and
exceptional values share one raw result slot; status details get a separate word.
Lowering links each descriptor to its exact deopt state, bytecode origin, step
delta, inputs, and exceptional target. Destruction and owner invalidation release
that metadata with the code.

## 5. Verifying a tier change

The mandatory pattern is **differential: same source, tier forced off vs. forced
on**, comparing result, exception, and externally visible state.
`Context.Options.enable_jit = false` is fixed for the context lifetime precisely
so this comparison is not timing-sensitive.

```bash
zig build test-jit                  # focused production baseline-JIT tests
zig build test-vm test-concurrency  # the other focused engine suites
zig build gc-relocation-inventory-check
zig build test-parallel             # full unit suite
zig build test -Dtsan=true          # tier records are shared across Threads
zig build threadfuzz -Dfuzz-iters=400
```

GC stress, termination, recursion, and shared-realm tests are **required before
those paths may enter native code** — not after.

Performance evidence uses the symmetric JSC protocol
([`docs/benchmarks.md`](../../../docs/benchmarks.md)). Quick paired measurements
guide development; the full publication matrix is rerun only after a meaningful
batch of optimizations. **A speedup is not accepted if checksums, supported rows,
or execution accounting differ.**

## 6. Practical notes

- Repeated focused tier builds grow `.zig-cache` fast. See
  [`docs/dev-cache.md`](../../../docs/dev-cache.md) — everything in
  `.zig-cache/` and `zig-out/` is reproducible and safe to delete.
- The current evidence boundary for native coverage is the dispatch profile in
  `docs/.data/baseline-jit-profile-2026-07-16.md`. Extending coverage means
  moving that boundary with new evidence, not asserting it.
- Optimizing-tier backend and differential evidence are **open release gates** in
  `docs/.data/release-compatibility-matrix.json`. Closing one is a matrix update,
  not a prose edit.
