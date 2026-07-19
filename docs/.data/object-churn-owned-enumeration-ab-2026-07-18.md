# Shared object-churn owned-enumeration A/B — 2026-07-18

This focused comparison evaluates the first downstream activation of
[zig-gc #33](https://github.com/zig-utils/zig-gc/issues/33) for
[zig-js #97](https://github.com/zig-utils/zig-js/issues/97). The candidate
replaces zig-gc's intrusive all-cells list with the zig-js slab backing's exact
published-slot iterator. The iterator merges all six sorted size-class chunk
indexes into global address order and excludes private reservations and holes.

- Exact parent: zig-js `062ef265ca1196ee0cfe813124a06e09836fcc4a`,
  zig-gc `c67e344dd42e5246079a1c7835b9df3af42ff5e7`.
- Candidate: the same zig-js parent plus the local binding activation of
  zig-gc `30ac716d`; zig-regex stayed at `86159c5b`.
- Workload: exact `bench/comparison.js` `object_churn` bytes, shared mode,
  100 jobs per lane, ReleaseFast runners.
- Sampling: seven fresh-process pairs at 1/2/4/8 lanes; process order alternated
  within each lane and every checksum matched.
- Host: Apple M3 Pro, 11 physical/logical CPUs, 18 GiB; AC power with the
  battery at 85% and discharging.
- Raw evidence: [all 56 process results](object-churn-owned-enumeration-ab-2026-07-18.tsv).

Lower time is better. Speedup is parent median divided by candidate median;
values above 1.00x favor the candidate. Scaling is aggregate throughput against
each variant's own one-lane median. RSD is sample standard deviation divided by
the sample mean.

| lanes | parent (ms) | parent RSD | parent scaling | candidate (ms) | candidate RSD | candidate scaling | speedup | pair wins |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 137.718 | 7.35% | 1.00x | 134.511 | 3.82% | 1.00x | 1.02x | 5 / 7 |
| 2 | 186.382 | 8.22% | 1.48x | 187.012 | 9.28% | 1.44x | 1.00x | 3 / 7 |
| 4 | 425.992 | 19.44% | 1.29x | 327.088 | 15.41% | 1.64x | **1.30x** | 5 / 7 |
| 8 | 2,122.534 | 19.72% | 0.52x | 2,138.732 | 18.91% | 0.50x | 0.99x | 4 / 7 |

## Decision

Reject this downstream activation. One lane is slightly faster and two lanes
are neutral, but the required eight-lane improvement is absent: median time is
0.8% slower and scaling falls from 0.519x to 0.503x. Four lanes improve 30%,
which confirms that slab-local enumeration can help, but it does not satisfy the
issue's all-contended-lane gate and dispersion remains high.

The generic zig-gc iterator and the independently useful zig-js backing iterator
remain. The production binding hook is removed until aggregate publication can
also be sharded without a heap-wide per-batch lock. The accepted README benchmark
matrix is unchanged because this candidate did not ship.
