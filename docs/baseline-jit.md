# Baseline native tier

Issue [#52](https://github.com/zig-utils/zig-js/issues/52) tracks the first
native-code tier above the bytecode VM. Its purpose is general engine
throughput: compile bytecode that has proved hot, preserve the interpreter's
semantics, and fall back cleanly whenever the tier cannot yet represent an
operation. It must never recognize a benchmark, source string, or function
name.

## Tier contract

Every `Chunk` starts in the interpreter and owns one atomic tier record:

1. `cold`: count completed entries without adding work to each opcode.
2. `compiling`: exactly one thread claimed compilation; other threads keep
   interpreting.
3. `ready`: the entry pointer and immutable metadata have been published with
   release/acquire ordering.
4. `rejected`: this chunk cannot currently be compiled. Rejection is cached so
   unsupported bytecode does not repeatedly enter the compiler.

Compilation happens only at a chunk entry, never in the opcode loop. The first
implementation may reject a whole chunk when any instruction is unsupported.
Later versions can leave side exits at unsupported instructions, but they must
reconstruct an exact `Exec` state: operand stack, accumulator, instruction
pointer, handler stack, and frame.

Generated code is immutable after publication. A tier record may be shared by
JavaScript `Thread`s, so publication and rejection are race-safe; only the
winner of the `cold` to `compiling` transition allocates code. Context teardown
owns all generated mappings and waits until no engine thread can execute them.

Embedders can set `Context.Options.enable_jit = false` to keep every chunk on
the bytecode VM. The switch is fixed for the context lifetime, so differential
tests and profiles can compare identical source without a timing-sensitive tier
toggle or partially published code.

## Entry ABI

The native entry point receives one pointer to a stable `NativeFrame` defined
by the JIT module, rather than depending on Zig's private calling convention or
the in-memory layout of `Interpreter` and `Exec`. The current frame contains:

- raw frame slots and numeric operand-spill storage;
- the exact interpreter step counter plus checkpoint and budget countdowns;
- an opaque runtime context and C-callable checkpoint/remainder helpers;
- result bits and an exit instruction pointer written by native code.

It intentionally does not expose the private `Interpreter`, `Chunk`, or `Exec`
layouts. A future resumable side exit must append the state it needs to this
ABI and reconstruct the full interpreter activation explicitly; returning
`side_exit` from a partially executed entry and simply restarting the function
would duplicate steps and side effects.

`Value` is an eight-byte NaN-boxed word. Native arithmetic may stay unboxed in
registers inside a proven numeric region, but every safepoint and side exit
must materialize canonical `Value`s in GC-visible frame or operand slots.
Generated code may not embed movable GC pointers. Constants are loaded through
the owning `Chunk` or recorded as explicit roots.

The entry returns a small status, not a Zig error union:

- `complete`: the result is in the native frame accumulator;
- `side_exit`: resume the bytecode interpreter at the published instruction;
- `throw`: the interpreter exception slot and exact VM state are live;
- `stop`: termination, step-budget, GIL-yield, or GC work requires the runtime.

This keeps exceptions and allocation in ordinary Zig runtime stubs. Native
code never unwinds through Zig frames.

## First supported region

The first useful compiler covers bytecode common to numeric functions and
loops:

- constants, booleans, stack moves, accumulator updates;
- local loads and stores;
- Number guards and `+`, `-`, `*`, `/`, remainder, and comparisons;
- unconditional and conditional branches;
- return and halt.

Integer remainder is permitted only under the same guards as the VM fast path;
all other Number cases call the semantic helper. A failed Number, frame, stack,
or bounds guard exits to the interpreter before changing observable state.

Property access follows after the numeric core. Its generated fast path uses
the existing shape/slot inline-cache contract, including the parallel seqlock
mode and GC write barrier. Arrays and calls use runtime stubs until dedicated
representations are proven correct.

## Guarded integer specialization

Issue [#56](https://github.com/zig-utils/zig-js/issues/56) tracks the next
numeric tier. Development measurements show that removing FP register moves or
constant setup is no longer material: integer-valued loop state still travels
through doubles, and remainder repeatedly validates and converts it. The next
speed tier therefore specializes proven integer regions rather than adding
benchmark-specific peepholes.

Entry guards run before native step accounting and before any frame-slot
mutation. If a parameter violates the compiled integer/range assumptions, the
entry may return to bytecode at instruction zero with no state to reconstruct.
Once observable native work begins, a failed assumption may use only one of
these exact paths:

- a cold semantic helper that completes the current bytecode operation;
- a range proof that made failure impossible; or
- a resumable side exit that publishes the precise instruction, operand stack,
  locals, and already-consumed step count.

The dataflow lattice distinguishes signed/non-negative integers and conservative
ranges at control-flow merges. Integer locals and operands may stay in GPRs,
but safepoints and returns materialize canonical Number words. Overflow cannot
wrap: it must be proved absent, handled by a full-precision cold path, or leave
through the precise side-exit contract. Fractional values, NaN, infinities,
and negative zero continue in the generic Number tier or interpreter.

The specialization is selected from bytecode plus runtime guards. It must not
inspect source strings, function names, benchmark names, or call-site identity.

## Safepoints and accounting

Back edges and calls are safepoints. Before either one, native code spills live
values and publishes the current instruction pointer. The runtime stub applies
the same obligations as `runChunk`:

- increment and enforce the evaluation step budget;
- observe worker termination;
- yield a contended JavaScript GIL when configured;
- service a requested precise-GC safepoint with all values visible;
- preserve the handler stack and pending exception.

The compiler emits a bytecode-to-native map for diagnostics and future stack
maps. Until precise native stack maps exist, no GC pointer may be live only in
a machine register across a safepoint.

## Executable memory

Code memory follows write-xor-execute policy. The currently emitted backend is
AArch64 on Darwin:

- macOS allocates `MAP_JIT` mappings and uses
  `pthread_jit_write_protect_np` around writes, followed by
  `sys_icache_invalidate`;
- unsupported targets leave the tier disabled and continue in bytecode.

The memory layer is independently tested with tiny architecture-specific code,
but bytecode analysis remains separate from the AArch64 assembler. Other POSIX
memory transitions and an x86-64 emitter remain future backend work; tests that
execute generated entries skip when that backend is unavailable.

## Correctness and performance gates

Each compiler feature lands with differential tests that execute the same
source with the native tier forced off and forced on, comparing result,
exception, and externally visible state. GC stress, termination, recursion,
and shared-realm tests are required before those paths can enter native code.

Performance evidence uses the symmetric JSC protocol in
[`benchmarks.md`](benchmarks.md). Quick paired measurements guide development;
the 616-sample publication matrix is rerun only after a meaningful batch of
optimizations. A speedup is not accepted if checksums, supported rows, or
execution accounting differ.
