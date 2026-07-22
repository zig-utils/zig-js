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

On supported AArch64 hosts, a guarded numeric SSA region lowers to immutable native code. The subset includes primitive constants and returns plus Number parameters used by arithmetic, relational comparisons, and equality. Parameters used only for recovery need no Number guard. Instruction-profiled dynamic arithmetic/comparisons/equality; unary, exponentiation, bitwise, and shift coercions; property reads/writes; membership; ordinary, method, direct-eval, explicit-`this`, spread, and proper-tail calls; ordinary/spread construction; literal object/array allocation and initialization; and five-way finally completion dispatch execute through the runtime-operation ABI. Named properties carry immutable four-shape IC snapshots. Isolated AArch64 named reads and existing-slot writes revalidate the cache pair, NaN-box tag, live shape, inline storage, and ordinary-object flags before touching the slot directly. Packed Array reads, existing-index writes, exact-end assignment, literal append, and intrinsic `push` likewise require ordinary dense storage with no holes or indexed hooks. Push with zero through eight values publishes spare-capacity elements directly after every GC barrier, then publishes length and the indexed-own witness once; wider or reallocating push uses one narrow callback whose exact scratch range roots the receiver and every value. Storage reserve is the only fallible mutation step and happens before barriers or publication, so OOM leaves length, elements, and the witness untouched. Shared mode, overrides, sparse or special storage, oversized lengths, and every guard miss use canonical dispatch. Other environment, iterator, class, and closure effects side-exit. Zero-cost `dup`/`swap` aliases let the compiler-generated method sequence read a callable once and invoke it with the original receiver. The tier also accepts one Boolean branch into two terminal returns. Runtime operations in the common prefix retain exact step ownership before that branch; equal-cost paths execute only the selected arm and complete natively, while unequal-cost paths resume the selected successor in bytecode.

Every representation guard runs before step accounting; a mismatch immediately retries baseline or bytecode with the untouched activation and budget. Optimizer-native and fallback executions therefore preserve the same result and exact bytecode-step delta. A ready managed baseline loop keeps precedence over a slower generic optimizer region; effect/property chunks that baseline cannot compile still reach the optimizer. Remaining work includes irreducible control, iterator/class/closure effects, broader array regions, and additional backends. No JSC-compatible optimizing-tier counters are exposed yet.

## Deoptimization foundation

Optimizer SSA retains deterministic locals-plus-operand-stack frame states at every reachable block entry, branch, ordinary return, explicit throw, and return-through-finally. Lowering resolves those states to immutable recovery records owned by the published artifact, including the exact resume IP, accumulator value, handler depth, and source scratch slot for every value. The VM distinguishes a deoptimized outcome from an entry miss, reconstructs `Exec` and frame slots from the selected record, and prevents partial-exit artifacts from using the restart-only direct-call path.

Deoptimization metadata can also own ordered catch/finally records with exact stack depths. Reconstruction validates every range and handler before reserving both VM lists, then replaces locals, operand stack, accumulator, handlers, and IP as one no-fail commit; malformed metadata leaves the activation untouched. The optimizer graph propagates structured normal-flow `push_handler`/`pop_handler` stacks through frame and edge states and rejects mismatched merges or unbalanced pops. Explicit throws publish exceptional SSA edges carrying the unwound locals, operand stack, exception/completion values, and outer handler stack. Calls, constructors, and interpreter-owned effects also publish owned exceptional targets with exact catch/finally destination, unwind depth, target depth, and remaining outer handlers. Deterministic chains execute nested catches, finally bodies, and `end_finally` in AArch64 native code. Generated dispatch distinguishes normal, throw, return, break, and continue from the raw completion record, publishes its exact recovery point and value, and lets the VM consume that selected completion once. Remaining outer catches/finally blocks are resumed from the reconstructed handler stack; malformed completion kinds fail closed. Debugger, host, or profiler statement hooks force bytecode even when an artifact exists. Recovery #436 and executable effect/completion issue #439 are complete.

#439 starts from a backend-neutral runtime-operation ABI appended to `NativeFrame`. One callback selects an immutable operation descriptor and returns a distinct status for a normal value, catchable exception, termination, watchdog expiry, debugger trap, host trap, allocation failure, or invalidation. Normal and exceptional values share one raw result slot; status-specific details have a separate word. Lowering links each descriptor to its exact deopt state, bytecode origin, step delta, inputs, and exceptional target, then transfers owned metadata into the published artifact. Destruction and owner invalidation release it with the code.

The executable operations are `to_numeric`; unary `-`/`+`/`!`/`~`, `typeof`, increment/decrement, ToString, and ToPropertyKey; profiled dynamic arithmetic, relational, and equality operators; exponentiation; all bitwise and shift operators; property reads/writes; all three membership forms; ordinary, method, direct-eval, explicit-`this`, spread, and proper-tail calls; ordinary/spread construction; every object/array literal allocation, property/prototype/spread/accessor initialization, append, hole, and iterable-spread operation; and normal/throw/return/break/continue finally dispatch on deterministic AArch64 paths. Direct eval preserves lexical scope, method getters run before argument evaluation, and native JS-to-JS tails replace the current heap activation. Literal mutations return the same rooted container; a throwing spread preserves completed mutations and resumes its exact catch/finally target without replay. `void` lowers directly to undefined. Per-bytecode atomic operand profiles keep observed Number-only sites on the existing guarded inline path and select rooted runtime SSA values only for sites that observed dynamic inputs. Generated code publishes exact operation/origin/deopt/step state and distinguishes normal, throw, exceptional continuation, every completion dispatch, allocation failure, invalidation, and fail-closed trap outcomes.

Each exceptional continuation is immutable artifact metadata containing its catch/finally IP, unwind and target stack depths, outer-handler slice, and completion kind. Once a callback throws, reconstruction reserves all VM storage, validates and materializes the pre-effect state, removes the consumed handler, injects either the exception or `[exception, throw]`, and resumes the target bytecode without replaying the operation. A normal result continues through the existing native region or exact side exit. Hot object-coercion differentials verify one `valueOf` call for catch and finally paths, including canonical `end_finally` rethrow to an outer catch.

The callback stack map marks every live scratch recovery value plus the descriptor's explicit inputs; frame recoveries keep their existing masks. Native entry registers that map before generated code runs, so coercion inputs, receivers, keys, assigned values, membership operands, callees, and constructors remain movable and traceable across re-entry. Bytecode IC snapshots use the existing parallel seqlock bracket and become artifact-owned shape/slot tokens; link-time lookup revalidation rejects poisoned pairs, and contention omits the advisory cache rather than publishing a torn pair. Focused witnesses prove zero general callback entries for direct polymorphic inline named access, packed existing-index access, and zero-, one-, or multi-value spare-capacity push, including object writes after a moving-GC checkpoint. Separate counters distinguish direct publication, narrow push calls, actual growth, and canonical dispatch. Full capacity and wider pushes enter the rooted narrow boundary; forced OOM is failure-atomic. Shared mode, named access on arrays, transitions, malformed slots, holes, non-index keys, accessors, proxies, and initial backing creation fall back exactly. The wider suite covers primitive effects, calls, roots, catch/finally continuation, all five completion kinds, OOM, traps, invalidation, and exact steps. Both append helpers were added at the end of the native frame, so prior field offsets and numeric unmanaged leaves are unchanged.

Every optimizer recovery point owns a precise frame/scratch stack map. Primitive numeric regions publish empty masks. Unknown/object-valued effect inputs recover from marked frame slots; recovery-only loop locals travel through marked scratch slots without acquiring Number guards. Native entry registers a scoped frame-plus-map descriptor, and tracing/relocation validates its selected index and masks before visiting only runtime-tagged candidates. Malformed or unpublished indexes fail closed.

Generated loops now reach a moving-GC safepoint at most 32 completed backedges after a compaction request can be observed. The poll runs after canonical backedge copies, publishes the exact loop-header recovery index, preserves the native ABI state, and enters the runtime with no managed pointer held only in a register. Compaction rewrites marked frame and scratch words in place, then native execution reloads them on the next iteration. This poll is separate from the exact 1,024-step budget, termination, trap, and GIL checkpoint, so it cannot invent or delay those semantics. Real-GC tests move a recovery-only object during optimized execution and verify the post-exit property read in single-mutator and no-GIL modes, normally and under TSan. Termination differentials prove that native work exits before the exact 1,024-step boundary and bytecode consumes cooperative stop, expired-watchdog, and shell-timeout requests there. Future pointer-producing native operations must extend the same map discipline as they land.

The first generated side exit handles a guarded numeric branch whose two paths have unequal bytecode costs. Native code executes and accounts for the common prefix, publishes the selected successor state, and resumes that path in bytecode without restarting the function. Entry declines before doing work when the prefix would cross a budget or 1,024-step checkpoint.

Every CFG edge also retains its exact locals-plus-stack state separately from the target block-entry state. This distinction matters at loop headers: the preheader and backedge can supply different SSA values to the same block arguments. Loop headers produce an immutable OSR-entry contract with exact IP, locals, operand-stack depth, handler depth, accumulator, and VM-to-SSA scratch imports. Entry is ineligible on any shape mismatch.

The AArch64 loop tier keeps specialized encodings for common straight, guard-chain, and sequential-diamond shapes, then falls back to a general reducible region. A single-header region becomes a single-entry scheduling DAG after its header backedges are removed. A region with nested cycles instead selects the exact outermost OSR header, proves every removed internal backedge targets a dominator, schedules all forward edges first, and lowers loop-carried copies only after their sources exist. Every CFG edge owns a distinct parallel-copy operation group, so arbitrary nested branches may reconverge, exit, or reach independent latches without conflating SSA state.

Single-header code reserves its longest acyclic path. Fused nested regions additionally poll invalidation, checkpoint distance, and budget at every internal block entry, using an immutable deopt record for that exact state; unbounded inner iterations therefore cannot cross pending work hidden by an outer reservation. Every inner and outer latch applies its own header copies, publishes the target header's moving safepoint, and backedges. Every exit reconstructs its exact source edge and resumes the outer target without double execution. Native code imports one exact selected frame and executes multiple iterations before reconstruction. Named and packed existing-index reads/writes plus remainder execute inside reducible loop regions; numeric-required reads side-exit before observable work on a guard miss. Calls, construction, and literal object/array effects stage variable-arity inputs from the exact loop frame state and use the rooted runtime ABI, preserving allocation, OOM, exception, and moving-GC outcomes. Only values consumed by numeric operations require Number guards, while recovery-only objects remain precisely mapped across 128 scratch slots. Parallel-copy cycles use one reusable scratch slot. A deterministic invalidation race verifies exact header reconstruction under normal and TSan gates; production artifacts emit no observer. Irreducible multi-entry cycles reject before publication. Guarded packed indexing is complete in [#448](https://github.com/zig-utils/zig-js/issues/448); allocating loop effects are tracked by [#450](https://github.com/zig-utils/zig-js/issues/450).

The published arrays workload still selects the older guarded VM packed-push and packed-sum kernels before optimizer OSR. [#451](https://github.com/zig-utils/zig-js/issues/451) added direct spare-capacity append; [#452](https://github.com/zig-utils/zig-js/issues/452) adds zero/variadic direct publication plus precisely rooted reallocating push. The [exact-parent array profile](.data/optimizer-array-profile-2026-07-22.md) shows no transfer into the new helper, so the measured tier priority and accepted benchmark score remain unchanged. Its focused optimizer-region A/B keeps 19,564 appends direct while moving all 14 measured reallocations from general dispatch to the narrow rooted callback.

The saved [July 21 property profile](.data/optimizer-property-profile-2026-07-21.md) attributes 46.2% of collapsed leaves to generated code and records 52.6% fewer `runChunk`, 69.1% fewer quick-property, and 40.0% fewer numeric-property leaves than the July 16 baseline.

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
zig build test -Dtest-filter='native call'
zig build test -Dtest-filter='native construction'
zig build test -Dtest-filter='native named'
zig build test -Dtest-filter='native computed'
zig build test -Dtest-filter='to_numeric'
zig build test -Dtest-filter='unary coerc'
zig build test -Dtest-filter='binary coerc'
zig build test -Dtest-filter='dynamic arithmetic'
zig build test-jit -Dtest-filter='non-tail invocation'
zig build test-jit -Dtest-filter='object and array construction'
zig build test -Dtest-filter='logical not'
zig build test-jit -Dtest-filter='tail call'
zig build test -Dtest-filter='native named write'
zig build test -Dtest-filter='native computed write'
zig build test -Dtest-filter='optimizer packed index'
zig build test -Dtsan=true -Dtest-filter='optimizer packed index'
zig build test -Dtest-filter='optimizer allocating array'
zig build test -Dtsan=true -Dtest-filter='optimizer allocating array'
zig build test -Dtest-filter='optimizer packed index guards'
zig build test -Dtest-filter='native in operator'
zig build test -Dtest-filter='native instanceof'
zig build test -Dtest-filter='native private-in'
zig build test -Dtest-filter='interpreter-owned side exits'
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
