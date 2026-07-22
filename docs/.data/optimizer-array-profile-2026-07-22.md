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

## Focused optimizer-region dispatch A/B

The published workload cannot measure #452 because its VM kernel wins before
optimizer OSR. The existing moving-GC `optimizerArrayGrow` differential is the
focused complement: it warms the same reducible one-value push loop, then runs
20,000 iterations against a retained array in native and bytecode contexts.
Both parent and candidate pass the same 4/4 filtered group with equal result
`20007`; the candidate also moves the retained target and value successfully.

| exact engine revision | direct | narrow | actual growth | general operation |
| --- | ---: | ---: | ---: | ---: |
| parent `db91caba` | 19,564 | 0 | 0 | 14 |
| candidate `f4916c3c` | 19,564 | 14 | 14 | **0** |

The parent run used only a temporary print hook around the existing before/after
counters. Candidate commit `bb0c54e7` keeps the machine-readable line in the
focused test:

```sh
zig build test -Dtest-filter='optimizer allocating array'
```

This is a causal dispatch result, not a timing claim: all 14 reallocations move
from the general operation dispatcher to the rooted narrow callback, while the
19,564 spare-capacity publications remain direct. The general-dispatch count
therefore falls 100% for the measured growth subset without adding repeated
callbacks to the direct path.

## Decision

Keep the current tier priority. The exact published workload is still owned by
the older guarded VM packed-push and packed-sum kernels before optimizer OSR;
the new native path serves general optimizer regions whose push shapes are not
claimed by that kernel. The nearby parent/candidate leaf counts show sampling
variation, not a transfer into repeated native guards or callbacks. Because
the accepted comparison matrix did not change, its README scores and raw
benchmark artifact remain unchanged.

## Combined completion gate

After the implementation and attribution batches settled, `bad067d8` completed
the once-per-checkpoint gate:

- unit shards: 353/353, 352/352, 352/352, and 352/352 (1,409/1,409 total);
- no-GIL corpus mini-suite: `arrays/shared-element-read-write.js`,
  `arrays/push-resize-multithread.js`, and
  `jit/shared-arraystorage-stress.js`, 3/3 normally and 3/3 under TSan with
  `TSAN_OPTIONS=halt_on_error=1` and no suppressions;
- benchmark publication/validation harnesses: 4 + 7 + 11 + 7 tests passed;
- release compatibility: 6/12 declared gates green, private ABI pending 0.

The first unsharded unit pass found that the allocating optimizer step witness
inherited process-global shared-realm mode from earlier Context tests. The
fixture now saves, disables, and restores that mode just like its companion
direct-array tests; the exact failing CI shard then passed 352/352. This changes
no production path and makes the direct-path step witness independent of test
order.
