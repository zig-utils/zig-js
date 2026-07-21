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

On supported AArch64 hosts, a guarded numeric SSA region lowers to immutable native code. The subset includes primitive constants and returns plus Number parameters used by `+`, `-`, `*`, `/`, relational comparisons, and numeric equality. It also accepts one Boolean branch into two terminal returns. Equal-cost paths complete natively; unequal-cost paths execute the common prefix and resume the selected successor in bytecode. Equal-cost branch-local numeric expressions are safe to evaluate eagerly because every live input is guarded and the accepted operations have no observable coercion effects.

Every representation guard runs before step accounting; a mismatch immediately retries baseline or bytecode with the untouched activation and budget. Optimizer-native and fallback executions therefore preserve the same result and exact bytecode-step delta. General merges and nested control, remainder, coercions, movable pointer stack maps, properties, arrays, and additional backends remain tracked by #146 and its child issues. No JSC-compatible optimizing-tier counters are exposed yet.

## Deoptimization foundation

Optimizer SSA retains deterministic locals-plus-operand-stack frame states at every reachable block entry, branch, and return. Lowering resolves those states to immutable recovery records owned by the published artifact, including the exact resume IP, accumulator value, handler depth, and source scratch slot for every value. The VM distinguishes a deoptimized outcome from an entry miss, reconstructs `Exec` and frame slots from the selected record, and prevents partial-exit artifacts from using the restart-only direct-call path.

Deoptimization metadata can also own ordered catch/finally records with exact stack depths. Reconstruction validates every range and handler before reserving both VM lists, then replaces locals, operand stack, accumulator, handlers, and IP as one no-fail commit; malformed metadata leaves the activation untouched. Current optimizer lowering still publishes an empty handler list until #436 models throwing bytecode and exception edges.

Every optimizer recovery point also owns a precise frame/scratch stack map. The currently executable optimizer subset guards or constructs only Numbers, Booleans, null, and undefined, so all published movable-root masks are correctly empty; the maps still make that fact explicit and keep deoptimization indexes aligned. Pointer-producing operations and relocation of live optimized roots remain required before #432's precise-GC acceptance item can close.

The first generated side exit handles a guarded numeric branch whose two paths have unequal bytecode costs. Native code executes and accounts for the common prefix, publishes the selected successor state, and resumes that path in bytecode without restarting the function. Entry declines before doing work when the prefix would cross a budget or 1,024-step checkpoint.

Every CFG edge also retains its exact locals-plus-stack state separately from the target block-entry state. This distinction matters at loop headers: the preheader and backedge can supply different SSA values to the same block arguments. Loop headers produce an immutable OSR-entry contract with exact IP, locals, operand-stack depth, handler depth, accumulator, and VM-to-SSA scratch imports. Entry is ineligible on any shape mismatch.

The first AArch64 loop OSR region handles a guarded numeric header with either a straight-line body or one equal-cost inner `if/else` diamond. After a hot backedge, native code imports the exact header frame, applies block arguments as parallel assignments, and executes multiple iterations before reconstructing the exit edge. The lowering breaks copy cycles with one reusable scratch slot; swapped multi-local backedges verify exact recovery. Every native header polls invalidation and checks the remaining budget and 1,024-step checkpoint distance, side-exiting exact current state before pending work. A deterministic instrumented race changes the owner generation only after a completed native backedge and verifies exact header reconstruction on the next poll under normal and TSan gates; production artifacts emit no observer. Unequal inner paths and deeper control remain outside this first region.

Executable-code invalidation now closes native entry immediately while existing owner leases keep published mappings alive. Function entry and direct calls poll the owner before entering native code. Optimizer machine code then compares the artifact's owner generation before its first operation, closing the race after the VM poll; the native loop repeats that poll at every header and side-exits exact current state when it changes. Rejection before work performs no step accounting or state mutation, while a later poll preserves completed iterations and resumes bytecode at the current header.

Focused verification:

```sh
zig build test-jit
zig build test -Dtest-filter='constant SSA return converges'
zig build test -Dtest-filter='guarded parameter SSA'
zig build test -Dtest-filter='optimizer exact branch'
zig build test -Dtest-filter='optimizer enters a loop header'
zig build test-jit -Dtest-filter='parallel'
zig build test-jit -Dtest-filter='nested branch'
zig build test-jit -Dtest-filter='multiple loop iterations'
zig build test -Dtest-filter='unsupported optimizer input caches rejection'
```
