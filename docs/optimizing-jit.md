# Optimizing JIT

The optimizing tier is under construction in [#146](https://github.com/zig-utils/zig-js/issues/146). The existing baseline numeric tier remains the only native JavaScript execution tier.

## Current foundation

[#431](https://github.com/zig-utils/zig-js/issues/431) now provides:

- per-function entry, branch, backedge, result/property value-kind, and shape observations;
- per-entry local deltas, merged atomically once, so hot loops do not perform atomic profile increments;
- a publication state machine and generation counter distinct from baseline code;
- compile counts that advance only when an optimizer plan is actually installed;
- deterministic CFG plus block-argument SSA for the current numeric/control bytecode subset;
- effect-aware canonicalization and dead-value elimination, including loop-carried locals and operand stacks; and
- fail-closed rejection for unsupported opcodes and invalid jump targets.

No optimizer plan executes yet, and zig-js does not expose JSC optimizing-tier counters. Interpreter and baseline behavior are unchanged. Guarded lowering, OSR/deoptimization, precise stack maps, concurrent invalidation/artifact lifetime, properties, arrays, backends, and differential evidence remain tracked by #431, #432, #433, #132, #133, and #434.

Focused verification:

```sh
zig build test-jit
zig build test -Dtest-filter='optimizer profiles aggregate'
```
