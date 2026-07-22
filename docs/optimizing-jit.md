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

Deoptimization metadata can also own ordered catch/finally records with exact stack depths. Reconstruction validates every range and handler before reserving both VM lists, then replaces locals, operand stack, accumulator, handlers, and IP as one no-fail commit; malformed metadata leaves the activation untouched. The optimizer graph propagates structured normal-flow `push_handler`/`pop_handler` stacks through frame and edge states and rejects mismatched merges or unbalanced pops. Explicit `throw`, return/break/continue through `finally`, every call/construct shape, and interpreter-owned environment, allocation, object-initialization, iteration, property, coercion, brand, and scope effects are terminal optimizer exits. One shared classification drives support checks, block boundaries, successors, and frame states. Native code executes only a proven primitive prefix, restores all inputs plus active handlers, and resumes the original opcode before observable work, preserving results, mutations, exceptions, debugger notification, and unwinding exactly once. Handler-only blocks beyond that mandatory exit may contain unsupported bytecode. Suspension/resumption, explicit exceptional CFG successors, and native catch/finally execution remain tracked by #436.

Every optimizer recovery point owns a precise frame/scratch stack map. Primitive numeric regions publish empty masks. Unknown/object-valued effect inputs recover from marked frame slots; recovery-only loop locals travel through marked scratch slots without acquiring Number guards. Native entry registers a scoped frame-plus-map descriptor, and tracing/relocation validates its selected index and masks before visiting only runtime-tagged candidates. Malformed or unpublished indexes fail closed.

Generated loops now reach a moving-GC safepoint at most 64 completed backedges after a compaction request can be observed. The poll runs after canonical backedge copies, publishes the exact loop-header recovery index, preserves the native ABI state, and enters the runtime with no managed pointer held only in a register. Compaction rewrites marked frame and scratch words in place, then native execution reloads them on the next iteration. This poll is separate from the exact 1,024-step budget, termination, trap, and GIL checkpoint, so it cannot invent or delay those semantics. Real-GC tests move a recovery-only object during optimized execution and verify the post-exit property read in single-mutator and no-GIL modes, normally and under TSan. Termination differentials prove that native work exits before the exact 1,024-step boundary and bytecode consumes cooperative stop, expired-watchdog, and shell-timeout requests there. Future pointer-producing native operations must extend the same map discipline as they land.

The first generated side exit handles a guarded numeric branch whose two paths have unequal bytecode costs. Native code executes and accounts for the common prefix, publishes the selected successor state, and resumes that path in bytecode without restarting the function. Entry declines before doing work when the prefix would cross a budget or 1,024-step checkpoint.

Every CFG edge also retains its exact locals-plus-stack state separately from the target block-entry state. This distinction matters at loop headers: the preheader and backedge can supply different SSA values to the same block arguments. Loop headers produce an immutable OSR-entry contract with exact IP, locals, operand-stack depth, handler depth, accumulator, and VM-to-SSA scratch imports. Entry is ineligible on any shape mismatch.

The first AArch64 loop OSR region handles a guarded numeric header with a straight-line body or one inner branch whose arms merge into a shared latch, backedge independently, or make one conditional exit while the other backedges. Each arm owns its exact bytecode cost; the header reserves the larger safe quantum, then the selected arm accounts its actual cost. Backedge arms update budget and checkpoint distance before continuing; an exit arm reconstructs the exact edge state and resumes at the outer exit target without executing it twice. Native code imports the exact header frame, applies block arguments as raw parallel assignments, and executes multiple iterations before reconstructing an exit edge. Only values consumed by numeric operations require Number guards; recovery-only object locals remain precisely mapped. The lowering breaks copy cycles with one reusable scratch slot, and swapped multi-local backedges verify exact recovery. Every native header polls invalidation and side-exits exact current state before pending work. A deterministic instrumented race changes the owner generation only after a completed native backedge and verifies exact header reconstruction on the next poll under normal and TSan gates; production artifacts emit no observer. Deeper control, multiple conditional exits, nested loops, and irreducible graphs remain outside this region.

Executable-code invalidation now closes native entry immediately while existing owner leases keep published mappings alive. Function entry and direct calls poll the owner before entering native code. Optimizer machine code then compares the artifact's owner generation before its first operation, closing the race after the VM poll; the native loop repeats that poll at every header and side-exits exact current state when it changes. Rejection before work performs no step accounting or state mutation, while a later poll preserves completed iterations and resumes bytecode at the current header.

Focused verification:

```sh
zig build test-jit
zig build test-jit test -Dtest-filter='safepoint'
zig build test -Dtest-filter='constant SSA return converges'
zig build test -Dtest-filter='guarded parameter SSA'
zig build test -Dtest-filter='optimizer exact branch'
zig build test -Dtest-filter='optimizer throw side exit'
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
zig build test-jit -Dtest-filter='multiple loop iterations'
zig build test -Dtest-filter='unsupported optimizer input caches rejection'
zig build test -Dtest-filter='active interpreter containers'
```
