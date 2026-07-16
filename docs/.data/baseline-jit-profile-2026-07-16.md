# Baseline tier and VM dispatch profile — 2026-07-16

This saved profile closes the dispatch-attribution evidence requested by
[issue #52](https://github.com/zig-utils/zig-js/issues/52). It distinguishes
generated machine code, VM quickening/runtime kernels, and residual bytecode
dispatch across four directly published comparison workloads.

## Method

- Source: zig-js `76a1119faec9ee237a68198b3aca7660c10b4e07` with zig-gc
  `dee13e6ddbe76b54a86daaec86d9be0dff2d66ea`.
- Binary: `benchmark-comparison-bin`, `ReleaseFast`, Darwin AArch64.
- Host: Apple M3 Pro, 11 cores, 18 GB, battery power while discharging.
- Profiler: macOS `sample`, five seconds at one-millisecond intervals with
  `-mayDie -fullPaths`.
- Work: the exact `bench/comparison.js` bytes and published job count, repeated
  for 100 samples in one process so the profiler observes warmed execution.
- Reported counts: `sample` section “Sort by top of stack, same collapsed.”
  Frames below five samples are omitted by the profiler, so percentages use the
  reported collapsed total for each workload rather than implying cycle-exact
  accounting.

Reproduction pattern:

```sh
zig build benchmark-comparison-bin -Doptimize=ReleaseFast
zig-out/bin/bench-comparison-zig-js single arithmetic 240 100 &
sample $! 5 1 -mayDie -fullPaths -file /tmp/zig-js-jit-arithmetic.sample.txt
```

The other published job counts are properties 300, arrays 550, and Fibonacci
125.

## Collapsed leaf attribution

| workload | reported leaves | dominant execution | samples | share | other material leaves |
| --- | ---: | --- | ---: | ---: | --- |
| arithmetic | 4,060 | generated `MAP_JIT` addresses | 3,790 | **93.3%** | `collectMidScript` 133; `nativeCheckpoint` 86; `shouldCollectOld` 51 |
| properties | 4,170 | `tryQuickPropertyKernel` | 1,626 | **39.0%** | `runChunk` 1,539 (36.9%); `tryNumericPropertyUpdate` 889 (21.3%); `quickResolvedSlots` 61 |
| arrays | 3,955 | `runChunk` | 2,582 | **65.3%** | `memmove` 297; `quickArrayBoundValue` 221; `Value.toInt32` 179; dense append 153; prototype resolution 144 |
| recursive Fibonacci | 4,124 | `runQuickObservableRecurrence` | 3,985 | **96.6%** | `advanceQuickSteps` 89; `collectMidScript` 45 |

## Interpretation

Arithmetic is the one workload in this group covered by the baseline native
tier. Every hot sample descends through the symbolized
`vm.tryRunNativeDirectCall` entry. macOS `sample` labels the anonymous `MAP_JIT`
mapping itself as `<unknown binary>` because it has no Mach-O symbol table; the
3,790 leaf addresses are tightly clustered in that generated mapping and there
are zero residual `runChunk` leaf samples. The only symbolized runtime work is
the exact native checkpoint/GC contract.

Property opcodes intentionally still reject native compilation. The profile
shows the current three-way split: guarded synchronized property kernels,
numeric-property specialization, and residual `runChunk` dispatch. Native
property coverage would need to replace that dispatch while preserving shape
seqlocks, exact side exits, and GC barriers; the profile does not justify
bypassing those contracts.

Arrays also remain a VM/runtime-stub workload. Residual dispatch is the largest
leaf family, followed by dense storage movement, bound calculation, value
conversion, append, and prototype validation. This points to broader verified
array regions or a native runtime-stub entry as future work, not a benchmark
recognizer.

Recursive Fibonacci is not baseline-native code: the general guarded observable
recurrence kernel removes per-opcode dispatch while retaining exact step and
checkpoint accounting. It accounts for 96.6% of reported leaves and leaves zero
`runChunk` leaf samples. This is an important boundary for #52: high-level
quickening can already remove dispatch for a semantic shape that is not yet safe
to lower into the native frame ABI.

Together these profiles prove that the native tier removes arithmetic dispatch,
identify the precise VM/runtime work that remains for properties and arrays,
and show that recursion is currently handled by general guarded quickening.

