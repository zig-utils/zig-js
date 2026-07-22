# Optimizer packed-array exact-parent CPU profile — 2026-07-22

This exact-parent profile checks whether reallocating and variadic optimizer
`push` changed ownership of the published `arrays` workload. It is profiler
attribution, not a benchmark publication; timings collected while `sample` was
attached are intentionally excluded from the accepted comparison report.

## Method

- Parent: zig-js `db91caba`.
- Candidate: zig-js `f4916c3c`, zig-gc
  `88ea25433d1841483a57567c80557df04146a53d`, and zig-regex
  `b8ca89df644976801e0b6444419444b708eeaa25`.
- Binary: `benchmark-comparison-bin`, `ReleaseFast`, Zig
  `0.17.0-dev.1441+d5181a9c9`, Darwin AArch64.
- Host: Apple M3 Pro, 11 cores, 18 GB.
- Work: exact `bench/comparison.js` `arrays` bytes, 550 jobs, repeated 100
  times in one process. Every repetition produced checksum `29007000000`.
- Profiler: macOS `sample` for five seconds at one-millisecond intervals with
  `-mayDie -fullPaths`.
- Counts: collapsed leaf section; 4,108 reported parent samples and 4,160
  candidate samples. Frames below five samples are omitted by `sample`.

Reproduction pattern:

```sh
zig build benchmark-comparison-bin -Doptimize=ReleaseFast
zig-out/bin/bench-comparison-zig-js single arrays 550 100 &
sample $! 5 1 -mayDie -fullPaths -file /tmp/zig-js-arrays.sample.txt
```

## Attribution

| leaf family | parent | candidate | candidate share |
| --- | ---: | ---: | ---: |
| `tryQuickArrayLoop` | 1,621 | 1,554 | 37.4% |
| `vm.runChunk` | 779 | 796 | 19.1% |
| `_platform_memmove` | 262 | 263 | 6.3% |
| `Value.toInt32` | 223 | 215 | 5.2% |
| `quickArrayBoundValue` | 128 | 160 | 3.8% |
| `Object.appendPackedDenseElements` | 121 | 119 | 2.9% |
| `Interpreter.tryFastArrayPush` | 40 | 40 | 1.0% |
| `arrayProtoChainCleanForDenseAppend` | 40 | 31 | 0.7% |

No `nativeArrayPushGrow` leaf appears in either profile. The focused quickening
witness also records the packed-push and packed-sum kernels, so the attribution
matches the runtime tier counters rather than relying on symbol names alone.

## Decision

Keep the current tier priority. The exact published workload is still owned by
the older guarded VM packed-push and packed-sum kernels before optimizer OSR;
the new native path serves general optimizer regions whose push shapes are not
claimed by that kernel. The nearby parent/candidate leaf counts show sampling
variation, not a transfer into repeated native guards or callbacks. Because
the accepted comparison matrix did not change, its README scores and raw
benchmark artifact remain unchanged.
