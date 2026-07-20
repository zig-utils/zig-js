# GC fragmentation and compaction — 2026-07-19

> Dated explicit-compaction evidence, not a general application benchmark.
> Identical heaps, checksums, live-slot counts, alternating process order, and the dense second-pass fixed point are enforced by the harness.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-19 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | 9f296900abc8adf33da4e18b24d6e8f628feddb4 |
| zig-gc | 5883b028b0bbfc3dc0864cd76cfcd522af368060 |
| zig-regex | 86159c5b9e0996ce6942b99d4ea76ed6c80a9a24 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22872163) 100%; charged; 0:00 remaining present: true |

## Result

| result | non-moving control | explicit compaction | change |
| --- | ---: | ---: | ---: |
| retained backing | 8.81 MiB | 0.81 MiB | **-90.8%** |
| retained chunks | 141 | 13 | **-90.8%** |
| live slots | 6559 | 6559 | unchanged |
| action median | 0.230 ms | 0.990 ms | compaction pause |
| post-action probe median | 1966.930 ms | 1971.688 ms | 1.00x compact/control throughput |

Every compact sample moved tail cells, reduced both retained metrics, preserved the exact live-slot count and checksum, and returned `no_candidates` with zero movement on its immediate second pass.

## Workload and method

Each fresh context allocates 32,768 retained two-object records followed by 2,048 retained two-object records, drops the first group, and performs a precise collection. The control performs another non-moving collection; the compact row calls explicit stop-the-world compaction. Process order alternates for 7 samples.
The untimed integrity setup is followed by 1,000 complete reads of the retained graph. The expected integer checksum is `4194304000`. The harness rejects backing growth, unequal starting heaps, live-slot drift, movement/fixed-point failures, and stable probe regressions over 10%.
Raw evidence: [gc-compaction-2026-07-19.tsv](gc-compaction-2026-07-19.tsv)

## Dispersion

| mode | action RSD | probe RSD |
| --- | ---: | ---: |
| non-moving control | 14.99% | 6.36% |
| explicit compaction | 9.37% | 5.31% |

## Reproduce

```sh
zig build gc-compaction-benchmark -Doptimize=ReleaseFast
zig build gc-compaction-benchmark -Dgc-compaction-benchmark-quick=true
```
