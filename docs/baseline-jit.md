# Baseline native tier

This remains the general native JavaScript tier. The separate [optimizing tier](optimizing-jit.md) executes only its documented exact subset and otherwise preserves this baseline/bytecode fallback.

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

On Darwin AArch64, every baseline numeric and optimizer entry that changes SP
or calls a runtime helper creates the canonical frame record: it saves x29/x30,
sets x29 to the resulting SP, and restores the pair through one final epilogue.
This keeps the native caller reachable to asynchronous frame-chain walkers
after the two-instruction prologue. Constant-return leaf stubs remain frameless
because they neither change SP nor call another function.

The code generator publishes that distinction as an explicit unwind plan; an
external publisher never recognizes instructions after the fact. The opt-in
Darwin adapter turns the plan into one PC-relative AArch64 DWARF FDE with exact
rows at function entry, after each prologue instruction, throughout the body,
and after the final frame-record restore. The rows describe every saved x19-x28
and d8-d15 register used by the baseline variant, not only the caller PC. The
adapter registers the FDE with `__register_frame` before publication completes
and calls `__deregister_frame` before releasing the FDE or executable mapping.
Leaf entries receive the corresponding SP/LR rule without a synthetic frame.

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

Direct `Context.compactGarbage` movement is permitted between evaluations,
after the active-interpreter registry proves that no `NativeFrame` exists.
`Context.requestGarbageCompaction` may also be serviced inside the current
AArch64 numeric tier's checkpoint island: it first publishes canonical locals,
spills live operands, and retains only numeric managed state in registers.
Published code, tier records, bytecode chunks, and the `NativeFrame` itself do
not move, so the same entry resumes after its registered frame/realm roots are
rewritten. Every generic VM, host-callback, side-exit, exception, other-thread,
and conservative-stack boundary remains fail-closed.

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

### Native PC ownership

`Context.Options.native_observability` opts a context into an owned native-PC
registry. At publication, each baseline or optimizer artifact receives a stable
artifact id and sanitized symbol name plus its exact half-open executable range,
function identity, script id, source URL, and definition coordinates. The
registry covers live artifacts and mappings retained by an older execution
epoch. Lookup returns an owned copy, so releasing the owner lock cannot leave a
profiler holding slices into reclaimed metadata.

Observed baseline compilation also emits sorted, artifact-relative PC change
rows. Each executable range names its exact bytecode offset; prologue,
epilogue, and other artifact plumbing are explicitly unmapped. When that
bytecode is an inspector statement boundary, adoption copies the same script
identity and one-based source position used by the inspector. Bytecodes without
an explicit statement node remain source-unmapped instead of inheriting a
guessed nearest line. The rows are passed to external publishers and returned
by owned PC lookups. Disabled compilation does not allocate or retain a map.

Observed optimizer compilation uses the same row format. Real SSA operations
carry their graph's bytecode origin; branch tests, return arms, side exits,
deopt polls, and loop controls use their explicit branch or recovery record.
Hoisted operations retain their real origin, while synthetic edge-copy
shuffles, path-dependent joins, and the shared epilogue reset attribution to
unmapped. The VM resolves exact inspector statement sites for optimizer rows at
the same pre-publication boundary used by baseline code.

Retirement removes the registry row before unmapping executable memory. Once the
last execution lease releases and reclamation completes, the old PC no longer
resolves; address reuse therefore cannot inherit a stale function identity.
With the option disabled, publication allocates and retains no native metadata.

`Context.Options.native_code_publisher` installs an embedder-owned external
publisher and implies `native_observability`. Publication returns an opaque
artifact-owned token; retirement invokes its infallible unregister callback
before metadata destruction and executable unmapping. The publisher and its
context must outlive the Context and its shared realms.

`jit.gdbJitPublisher()` is the opt-in macOS adapter for the standard GDB JIT
protocol, which LLDB also implements. It builds an in-memory Mach-O object whose
`__text` section has the exact existing executable address and byte size. When
an artifact has exact source rows, the object also owns minimal DWARF v4
`__debug_abbrev`, `__debug_info`, and `__debug_line` sections. Each mapped PC
sets its exact one-based line and column. An explicitly unmapped PC closes the
current line sequence, so a debugger cannot inherit a nearby JavaScript line
across prologue, join, move, or epilogue plumbing. The adapter registers and
unregisters the object with the artifact; it does not copy, link, or remap
executable code. The process-global `__jit_debug_descriptor` and
`__jit_debug_register_code` symbols are emitted only when an embedder selects
this adapter, so the default static library does not collide with a host that
already owns the protocol. LLDB disables this loader by default on macOS; use
`settings set plugin.jit-loader.gdb.enable on`.

`zig build native-observability-lldb-test` drives the real LLDB loader. Pending
baseline and optimizer symbol breakpoints must resolve at offset zero of their
exact JIT sections. Both objects must expose one compilation unit, leave their
entry prologues unmapped, and resolve source breakpoints to the exact fixture
file, line, and nonzero column. After the baseline canonical frame prologue,
LLDB must also walk from the generated frame to the host binary. The production
fixture requires
`_Unwind_Find_FDE` to resolve the exact live generated range and to stop
resolving it after Context teardown; both debugger symbols must disappear at
the same boundary. System-profiler image publication, inline-frame maps,
logical async/deopt/Wasm stack reconstruction, and crash-path integration
remain separate work; the process-local registry alone still does not make
anonymous `MAP_JIT` leaves visible to an external profiler.

## Correctness and performance gates

Each compiler feature lands with differential tests that execute the same
source with the native tier forced off and forced on, comparing result,
exception, and externally visible state. GC stress, termination, recursion,
and shared-realm tests are required before those paths can enter native code.

Performance evidence uses the symmetric JSC protocol in
[`benchmarks.md`](benchmarks.md). Quick paired measurements guide development;
the 1,540-sample publication matrix is rerun only after a meaningful batch of
optimizations. A speedup is not accepted if checksums, supported rows, or
execution accounting differ.

The [July 16 dispatch profile](.data/baseline-jit-profile-2026-07-16.md)
captures arithmetic, properties, arrays, and recursive Fibonacci from the same
ReleaseFast comparison runner. Arithmetic spends 93.3% of reported collapsed
leaf samples in generated `MAP_JIT` code with no residual `runChunk` leaves;
properties split between guarded VM kernels and residual dispatch; arrays
remain primarily residual dispatch plus dense-array runtime helpers; Fibonacci
spends 96.6% in the guarded observable-recurrence kernel. This is the current
evidence boundary for broader native coverage.

Repeated focused test builds grow the reproducible `.zig-cache` quickly; see
[`dev-cache.md`](dev-cache.md) for inspecting and safely reclaiming it.
