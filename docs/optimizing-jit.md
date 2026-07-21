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

On supported AArch64 hosts, a guarded numeric SSA region lowers to immutable native code. The subset includes primitive constants and returns plus Number parameters used by `+`, `-`, `*`, `/`, relational comparisons, and numeric equality. It also accepts one Boolean branch into two terminal returns when both paths execute exactly the same number of bytecode instructions; unequal paths fail closed. Branch-local numeric expressions are safe to evaluate eagerly because every live input is guarded and the accepted operations have no observable coercion effects.

Every representation guard runs before step accounting; a mismatch immediately retries baseline or bytecode with the untouched activation and budget. Optimizer-native and fallback executions therefore preserve the same result and exact bytecode-step delta. General merges/loops, unequal-path control, remainder, coercions, OSR/deoptimization, precise stack maps, properties, arrays, and additional backends remain tracked by #146 and its child issues. No JSC-compatible optimizing-tier counters are exposed yet.

Focused verification:

```sh
zig build test-jit
zig build test -Dtest-filter='constant SSA return converges'
zig build test -Dtest-filter='guarded parameter SSA'
zig build test -Dtest-filter='optimizer exact branch'
zig build test -Dtest-filter='unsupported optimizer input caches rejection'
```
