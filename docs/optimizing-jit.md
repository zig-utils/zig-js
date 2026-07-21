# Optimizing JIT

The optimizing tier is under construction in [#146](https://github.com/zig-utils/zig-js/issues/146). The baseline numeric tier remains the general native tier; the optimizer now has one deliberately narrow executable subset.

## Current foundation

[#431](https://github.com/zig-utils/zig-js/issues/431) now provides:

- per-function entry, branch, backedge, result/property value-kind, and shape observations;
- per-entry local deltas, merged atomically once, so hot loops do not perform atomic profile increments;
- a serialized publication state machine and generation counter distinct from baseline code, with stale claims rejected and unsupported plans cached;
- compile counts that advance only when an executable optimizer artifact is installed;
- deterministic CFG plus block-argument SSA for the current numeric/control bytecode subset;
- effect-aware canonicalization and dead-value elimination, including loop-carried locals and operand stacks; and
- fail-closed rejection for unsupported opcodes and invalid jump targets.

## Executable subset

On supported AArch64 hosts, one reachable primitive-constant SSA return, with arithmetic/comparisons restricted to numeric constants, lowers to immutable native code. Publication shares the context owner's execution/compilation lease, preserves exact bytecode step accounting, and runs ahead of baseline once hot. Parameters, merges, coercions, and multiple returns are cached as unsupported and continue through baseline or bytecode.

Broader guarded lowering, OSR/deoptimization, precise stack maps, properties, arrays, and additional backends remain tracked by #431, #432, #132, #133, and #434. Executable-artifact concurrency/lifetime remains under #433. No JSC-compatible optimizing-tier counters are exposed yet.

Focused verification:

```sh
zig build test-jit
zig build test -Dtest-filter='constant SSA return converges'
zig build test -Dtest-filter='unsupported optimizer input caches rejection'
```
