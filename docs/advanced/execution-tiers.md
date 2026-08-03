---
title: Execution tiers
description: How zig-js chooses between the tree-walking interpreter, the bytecode VM, the baseline native tier, and the optimizing tier — and how the tiers are kept in agreement.
---

# Execution tiers

zig-js has four execution paths. Understanding **why** each exists matters more
than the list, because the reasons are not the usual ones.

| Tier | Source | Exists for |
| --- | --- | --- |
| Tree-walking interpreter | `interpreter.zig` | **Correctness.** This is the semantic baseline and runs nearly all code. |
| Bytecode VM | `compiler.zig` → `bytecode.zig` → `vm.zig` | **Capability**, not speed: suspend/resume, deep recursion, proper tail calls. |
| Baseline native tier | `jit.zig`, `jit/aarch64.zig` | General native throughput above hot bytecode. |
| Optimizing tier | `jit/optimizer*.zig` | Speculative optimization of an exact documented subset. |

## The VM is a capability tier

This is the counter-intuitive part. The bytecode VM is **not** a general speedup;
`zig build bench` shows VM/tree-walk parity on the saved microbenchmarks. It
exists because the tree-walker cannot express certain things:

- **Suspend and resume** — generators, async functions, async generators.
- **A heap-allocated activation stack** (`vm.runDriver`), so deep recursion and
  proper tail calls are bounded by the logical call-depth cap rather than the
  native OS stack.

So tiering into the VM is deliberately narrow
(`plainFunctionMayUseBytecode` in `compiler.zig`):

- generators / async / async generators **always** compile to the VM;
- a **plain** function (non-method, non-generator, non-async, not using
  `arguments`) compiles only when it can benefit — it is strict and may contain
  a tail call, or it recurses by its own name;
- everything else, including top-level code and any function using a construct
  the compiler does not lower, tree-walks.

### The slot model and remaining lexical boundary

A compiled function gets one **activation slot array**: locals are frame slots
indexed in O(1), and closures capture the defining frame. Compile-time lexical
scope maps give same-named block, switch, loop, and catch bindings distinct slots,
then restore the enclosing mapping on exit. Lexical bindings retain their
TDZ and const/let kind. A control-flow scan marks chunks that can observe a
forward reference; only those chunks install the TDZ marker and use checked
local/captured loads. Proven initialized hot loops keep the ordinary opcodes,
while checked stores preserve `const` immutability. Forward lexical reads
therefore execute with the same exception semantics in the VM and tree-walker.

Captured simple bindings in classic `for` and `for-of` heads use fresh
per-iteration declarative environments; uncaptured heads keep the slot fast path.
Captured destructuring heads, captured lexicals declared inside a repeated loop
body, and labeled jumps that cross more than one such environment retain the
exact tree-walker path until their environment-unwind metadata is explicit.

## The practical consequence: divergence

Because most code tree-walks, **the VM path is comparatively under-exercised**,
and VM/tree-walker semantic divergence is a known bug surface. test262 will not
reliably catch it: a VM-only bug can hide behind a completely green corpus run.

When changing semantics:

1. Fix the tree-walker.
2. Ask whether `vm.zig` implements the same operation, and fix it there too.
3. Probe the VM deliberately — generators, IIFEs, self-recursive strict
   functions, and `--eval` scripts shaped to tier.

Known historical examples: computed property keys keyed off `toString()` instead
of `ToPropertyKey` on the VM path; a bare `var x;` re-clobbering an existing
binding in a VM-compiled function. Both were correct on the tree-walker.

## Native tiers

Both native tiers hold two invariants absolutely:

- **They must never recognize a benchmark, source string, or function name.**
- **An exact interpreter fallback is always retained.** Anything the tier cannot
  represent falls back; it never approximates.

### Tier records

Every `Chunk` owns one atomic tier record: `cold` → `compiling` → `ready` /
`rejected`. Exactly one thread claims compilation while others keep interpreting;
publication uses release/acquire ordering; **rejection is cached** so unsupported
bytecode does not repeatedly re-enter the compiler. Compilation happens only at a
chunk entry, never inside the opcode loop.

Generated code is immutable after publication, and a tier record may be shared by
JavaScript `Thread`s — so publication and rejection are race-safe. Context
teardown owns all generated mappings and waits until no engine thread can execute
them.

### Entry ABI and safepoints

The native entry point takes a pointer to a stable `NativeFrame` defined by the
JIT module, rather than depending on Zig's calling convention or the layout of
`Interpreter` / `Exec`.

Back edges and calls are safepoints. Before either, native code spills live
values and publishes the instruction pointer, and the runtime stub applies the
same obligations as `runChunk`: step budget, worker termination, GIL yielding
where configured, precise-GC safepoint service with all values visible, and
handler-stack / pending-exception preservation.

> Until precise native stack maps exist, **no GC pointer may be live only in a
> machine register across a safepoint.**

### Executable memory

Write-xor-execute. The emitted backend is AArch64 on Darwin: `MAP_JIT` mappings,
`pthread_jit_write_protect_np` around writes, `sys_icache_invalidate` after.
Unsupported targets leave the tier disabled and continue in bytecode. Other POSIX
transitions and an x86-64 emitter are future work.

### The optimizing tier

Profiling records per-function entry, branch, backedge, result/property
value-kind, and shape observations, merged from per-entry local deltas so hot
loops do not perform atomic increments. Publication is a serialized state machine
with its own generation counter; stale claims are rejected and unsupported plans
cached. Compile counts advance **only** when an executable artifact is installed.

Deoptimization rides a backend-neutral runtime-operation ABI appended to
`NativeFrame`: one callback selects an immutable operation descriptor and returns
a distinct status for a normal value, catchable exception, termination, watchdog
expiry, debugger trap, host trap, allocation failure, or invalidation. Each
descriptor links to its exact deopt state, bytecode origin, step delta, inputs,
and exceptional target.

Full contracts: [Baseline native tier](/baseline-jit),
[Optimizing JIT](/optimizing-jit).

## Turning tiers off

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_jit = false });
```

The switch is **fixed for the context lifetime**, so a differential test can
compare identical source with the tier forced off and forced on without a
timing-sensitive toggle or partially published code. That comparison — same
source, same inputs, comparing result, exception, and externally visible state —
is the mandatory way to land a tier change.

## Verifying tier work

```bash
zig build test-jit test-vm test-concurrency
zig build gc-relocation-inventory-check
zig build test-parallel
zig build test -Dtsan=true          # tier records are shared across Threads
zig build threadfuzz -Dfuzz-iters=400
```

GC stress, termination, recursion, and shared-realm tests are required **before**
a path may enter native code. A speedup is not accepted if checksums, supported
rows, or execution accounting differ.

The current evidence boundary for native coverage is the
[dispatch profile](https://github.com/zig-utils/zig-js/blob/main/docs/.data/baseline-jit-profile-2026-07-16.md):
arithmetic spends 93.3% of collapsed leaf samples in generated `MAP_JIT` code,
and recursive Fibonacci 96.6% in the guarded observable-recurrence kernel, while
arrays remain primarily residual dispatch. Extending coverage means moving that
boundary with new evidence.
