# Optimizer property-region CPU profile — 2026-07-21

This profile records where the published `properties` workload spends CPU after
native guarded property reads/writes and loop-region effects landed. It is
profiler attribution, not a benchmark score; timings collected while `sample`
is attached are intentionally excluded from the comparison report.

## Method

- Source: zig-js `f55cb51bb5b87969f23da10e2333165337e5add8`, zig-gc
  `88ea25433d1841483a57567c80557df04146a53d`.
- Binary: `benchmark-comparison-bin`, `ReleaseFast`, Darwin AArch64.
- Host: Apple M3 Pro, 11 cores, 18 GB.
- Work: exact `bench/comparison.js` `properties` bytes, 300 jobs, repeated for
  100 samples in one process.
- Profiler: macOS `sample` for five seconds at one-millisecond intervals.
- Counts: collapsed leaf section, 3,978 reported samples total.

Reproduction pattern:

```sh
zig build benchmark-comparison-bin -Doptimize=ReleaseFast
zig-out/bin/bench-comparison-zig-js single properties 300 100 &
sample $! 5 -file /tmp/zig-js-properties.sample.txt
```

## Attribution

| leaf family | July 16 baseline | July 21 property optimizer | current share | change |
| --- | ---: | ---: | ---: | ---: |
| generated `MAP_JIT` code | 0 | 1,839 | **46.2%** | newly attributed |
| `vm.runChunk` | 1,539 | 730 | 18.4% | **52.6% fewer** |
| `tryQuickPropertyKernel` | 1,626 | 503 | 12.6% | **69.1% fewer** |
| `tryNumericPropertyUpdate` | 889 | 533 | 13.4% | **40.0% fewer** |
| quick resolved-slot lookup | 61 | 75 | 1.9% | residual guard work |
| native property write barrier | 0 | 60 | 1.5% | required GC barrier |
| native remainder helper | 0 | 47 | 1.2% | exact `%` semantics |
| optimizer OSR entry | 0 | 23 | 0.6% | native loop entry |

The July 16 comparison uses the saved
[baseline profile](baseline-jit-profile-2026-07-16.md), whose property total was
4,170 collapsed samples. Counts therefore describe profiler leaves rather than
cycle-exact deltas; the percentage reductions compare the named leaf families.

## Interpretation

Generated property regions are now the largest leaf family. Residual bytecode
and quick kernels remain because guard misses, unsupported shapes, checkpoint
boundaries, and outer-loop work continue through canonical VM paths. The write
barrier and remainder leaves are expected semantic costs, not bypassable
dispatch. This profile demonstrates material dispatch removal while preserving
shape validation, exact step accounting, side exits, and moving-GC roots.
