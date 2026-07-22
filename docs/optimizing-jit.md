# Optimizing JIT

The optimizing tier is under construction in [#146](https://github.com/zig-utils/zig-js/issues/146). The baseline numeric tier remains the general native tier; unsupported optimizer plans always retain baseline or bytecode execution.

## Current foundation

[#431](https://github.com/zig-utils/zig-js/issues/431) now provides:

- per-function entry, branch, backedge, result/property value-kind, and shape observations;
- per-entry local deltas, merged atomically once, so hot loops do not perform atomic profile increments;
- a serialized publication state machine and generation counter distinct from baseline code, with stale claims rejected and unsupported plans cached;
- compile counts that advance only when an executable optimizer artifact is installed;
- deterministic CFG plus block-argument SSA for the current numeric/control bytecode subset;
- effect-aware canonicalization and dead-value elimination, including loop-carried locals and operand stacks;
- an architecture-neutral virtual-register program consumed by native optimizer backends; and
- fail-closed rejection for unsupported opcodes and invalid jump targets.

## Executable subset

On supported AArch64 hosts, a guarded numeric SSA region lowers to immutable native code. The subset includes primitive constants and returns plus Number parameters used by `+`, `-`, `*`, `/`, relational comparisons, and numeric equality. Parameters used only for recovery need no Number guard, so callees, receivers, and arguments survive every direct, method, explicit-`this`, spread, tail, and construction side exit. The tier also accepts one Boolean branch into two terminal returns. Equal-cost paths execute only the selected arm and complete natively; unequal-cost paths execute the common prefix and resume the selected successor in bytecode.

Every representation guard runs before step accounting; a mismatch immediately retries baseline or bytecode with the untouched activation and budget. Optimizer-native and fallback executions therefore preserve the same result and exact bytecode-step delta. General merges and nested control, remainder, native coercions/properties/arrays, and additional backends remain tracked by #146 and its child issues. No JSC-compatible optimizing-tier counters are exposed yet.

## Deoptimization foundation

Optimizer SSA retains deterministic locals-plus-operand-stack frame states at every reachable block entry, branch, ordinary return, explicit throw, and return-through-finally. Lowering resolves those states to immutable recovery records owned by the published artifact, including the exact resume IP, accumulator value, handler depth, and source scratch slot for every value. The VM distinguishes a deoptimized outcome from an entry miss, reconstructs `Exec` and frame slots from the selected record, and prevents partial-exit artifacts from using the restart-only direct-call path.

Deoptimization metadata can also own ordered catch/finally records with exact stack depths. Reconstruction validates every range and handler before reserving both VM lists, then replaces locals, operand stack, accumulator, handlers, and IP as one no-fail commit; malformed metadata leaves the activation untouched. The optimizer graph propagates structured normal-flow `push_handler`/`pop_handler` stacks through frame and edge states and rejects mismatched merges or unbalanced pops. Explicit throws publish exceptional SSA edges carrying the unwound locals, operand stack, exception/completion values, and outer handler stack. Calls, constructors, and interpreter-owned effects also publish owned exceptional targets with exact catch/finally destination, unwind depth, target depth, and remaining outer handlers; because the exception value does not exist before the mandatory pre-effect exit, these are control metadata rather than SSA value edges. Deterministic chains can execute nested catches and finally bodies in AArch64 native code; a return inside finally can override the pending throw natively, while a pending completion side-exits immediately before `end_finally` for canonical dispatch. Debugger, host, or profiler statement hooks force bytecode even when an artifact exists. Recovery issue #436 is complete; native dynamic-finally dispatch and native call/effect execution continue in #439.

Every optimizer recovery point owns a precise frame/scratch stack map. Primitive numeric regions publish empty masks. Unknown/object-valued effect inputs recover from marked frame slots; recovery-only loop locals travel through marked scratch slots without acquiring Number guards. Native entry registers a scoped frame-plus-map descriptor, and tracing/relocation validates its selected index and masks before visiting only runtime-tagged candidates. Malformed or unpublished indexes fail closed.

Generated loops now reach a moving-GC safepoint at most 32 completed backedges after a compaction request can be observed. The poll runs after canonical backedge copies, publishes the exact loop-header recovery index, preserves the native ABI state, and enters the runtime with no managed pointer held only in a register. Compaction rewrites marked frame and scratch words in place, then native execution reloads them on the next iteration. This poll is separate from the exact 1,024-step budget, termination, trap, and GIL checkpoint, so it cannot invent or delay those semantics. Real-GC tests move a recovery-only object during optimized execution and verify the post-exit property read in single-mutator and no-GIL modes, normally and under TSan. Termination differentials prove that native work exits before the exact 1,024-step boundary and bytecode consumes cooperative stop, expired-watchdog, and shell-timeout requests there. Future pointer-producing native operations must extend the same map discipline as they land.

The first generated side exit handles a guarded numeric branch whose two paths have unequal bytecode costs. Native code executes and accounts for the common prefix, publishes the selected successor state, and resumes that path in bytecode without restarting the function. Entry declines before doing work when the prefix would cross a budget or 1,024-step checkpoint.

Every CFG edge also retains its exact locals-plus-stack state separately from the target block-entry state. This distinction matters at loop headers: the preheader and backedge can supply different SSA values to the same block arguments. Loop headers produce an immutable OSR-entry contract with exact IP, locals, operand-stack depth, handler depth, accumulator, and VM-to-SSA scratch imports. Entry is ineligible on any shape mismatch.

The AArch64 loop tier keeps specialized encodings for common straight, guard-chain, and sequential-diamond shapes, then falls back to a general reducible region. A single-header region becomes a single-entry scheduling DAG after its header backedges are removed. A region with nested cycles instead selects the exact outermost OSR header, proves every removed internal backedge targets a dominator, schedules all forward edges first, and lowers loop-carried copies only after their sources exist. Every CFG edge owns a distinct parallel-copy operation group, so arbitrary nested branches may reconverge, exit, or reach independent latches without conflating SSA state.

Single-header code reserves its longest acyclic path. Fused nested regions additionally poll invalidation, checkpoint distance, and budget at every internal block entry, using an immutable deopt record for that exact state; unbounded inner iterations therefore cannot cross pending work hidden by an outer reservation. Every inner and outer latch applies its own header copies, publishes the target header's moving safepoint, and backedges. Every exit reconstructs its exact source edge and resumes the outer target without double execution. Native code imports one exact selected frame and executes multiple iterations before reconstruction. Only values consumed by numeric operations require Number guards; recovery-only object locals remain precisely mapped. Parallel-copy cycles use one reusable scratch slot. A deterministic invalidation race verifies exact header reconstruction under normal and TSan gates; production artifacts emit no observer. Irreducible multi-entry cycles reject before publication.

Executable-code invalidation now closes native entry immediately while existing owner leases keep published mappings alive. Function entry and direct calls poll the owner before entering native code. Optimizer machine code then compares the artifact's owner generation before its first operation, closing the race after the VM poll; the native loop repeats that poll at every header and side-exits exact current state when it changes. Rejection before work performs no step accounting or state mutation, while a later poll preserves completed iterations and resumes bytecode at the current header.

Focused verification:

```sh
zig build test-jit
zig build test-jit test -Dtest-filter='safepoint'
zig build test -Dtest-filter='constant SSA return converges'
zig build test -Dtest-filter='guarded parameter SSA'
zig build test -Dtest-filter='optimizer exact branch'
zig build test -Dtest-filter='optimizer lowering executes'
zig build test -Dtest-filter='keeps an uncaught throw'
zig build test -Dtest-filter='finally body'
zig build test -Dtest-filter='exceptional target'
zig build test -Dtest-filter='abrupt return side exit'
zig build test -Dtest-filter='abrupt break side exit'
zig build test -Dtest-filter='pre-call side exit'
zig build test -Dtest-filter='pre-tail-call side exit'
zig build test -Dtest-filter='property-effect side exit'
zig build test -Dtest-filter='interpreter-owned side exits'
zig build test -Dtest-filter='computed-property-effect side exit'
zig build test -Dtest-filter='coercion-effect side exit'
zig build test -Dtest-filter='optimizer interpreter-owned'
zig build test -Dtest-filter='pre-construction side exit'
zig build test -Dtest-filter='optimizer enters a loop header'
zig build test-jit -Dtest-filter='parallel'
zig build test-jit -Dtest-filter='nested branch'
zig build test-jit test -Dtest-filter='conditional loop exit'
zig build test-jit -Dtest-filter='multi-exit chain'
zig build test -Dtest-filter='conditional exit prefix'
zig build test-jit -Dtest-filter='multiple loop iterations'
zig build test -Dtest-filter='unsupported optimizer input caches rejection'
zig build test -Dtest-filter='active interpreter containers'
```
