# Shared object-churn sharded-enumeration A/B — 2026-07-18

This is the second downstream screen for
[zig-gc #33](https://github.com/zig-utils/zig-gc/issues/33) under
[zig-js #97](https://github.com/zig-utils/zig-js/issues/97). Unlike the first
traversal-only candidate, zig-gc `79b26c1` also publishes large owned batches
through stable per-thread aggregate shards: no heap allocation lock, CAS, or
global write is performed per batch. The collector closes a read-mostly gate,
drains active publishers, and folds shard deltas once before using the exact
address-ordered bitmap iterator.

- Exact parent: zig-js `e9869bc4`, zig-gc `79b26c1`, zig-regex `86159c5b`.
- Candidate: identical revisions plus the local zig-js owned-iterator binding
  hook; no other source changed.
- Workload: exact `bench/comparison.js` `object_churn` bytes, shared mode,
  100 jobs per lane, ReleaseFast runners.
- Sampling: seven fresh-process pairs at 1/2/4/8 lanes with alternating process
  order; every checksum matched.
- Host: Apple M3 Pro, 11 physical/logical CPUs, 18 GiB; AC power reported while
  the battery was 56% and discharging.
- Raw evidence: [all 56 process results](object-churn-sharded-enumeration-ab-2026-07-18.tsv).

Lower time is better. Speedup is parent median divided by candidate median;
values above 1.00x favor the candidate. Scaling is aggregate throughput against
each variant's own one-lane median.

| lanes | parent (ms) | parent RSD | parent scaling | candidate (ms) | candidate RSD | candidate scaling | speedup | pair wins |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 138.431 | 10.54% | 1.00x | 132.092 | 18.86% | 1.00x | 1.05x | 4 / 7 |
| 2 | 181.595 | 10.75% | 1.53x | 178.958 | 4.01% | 1.48x | 1.02x | 3 / 7 |
| 4 | 606.266 | 14.48% | 0.91x | 560.652 | 17.89% | 0.94x | 1.08x | 4 / 7 |
| 8 | 1,737.706 | 9.13% | 0.64x | 1,842.108 | 5.71% | 0.57x | **0.94x** | 2 / 7 |

## Decision

Reject the downstream activation again. The candidate improves the 1/2/4-lane
medians by 4.8% / 1.5% / 8.1%, but eight lanes regresses 6.0%, loses five of
seven pairs, and scales 0.574x versus the parent's 0.637x. Removing both the
intrusive walk and heap-wide aggregate publication is therefore insufficient
while every allocation batch still writes zig-js's global cooperative-GC byte
counter and serializes through the same size-class backing lock.

The generic zig-gc iterator/shards and the dormant zig-js backing iterator stay;
the production binding hook is removed. The accepted README benchmark matrix is
unchanged because this candidate did not ship.
