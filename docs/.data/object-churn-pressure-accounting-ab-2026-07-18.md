# Shared object-churn pressure-accounting A/B — 2026-07-18

This exact-parent screen tests [zig-js #310](https://github.com/zig-utils/zig-js/issues/310)
under [zig-js #97](https://github.com/zig-utils/zig-js/issues/97). The candidate
replaces the heap-wide cooperative-GC allocation-byte atomic RMW with six
per-size-class counters. Allocation updates its counter under the bucket lock it
already holds; each threshold read and reset acquires all bucket locks to obtain
an exact snapshot.

- Exact parent: zig-js `e9869bc4`, zig-gc `79b26c1`, zig-regex `86159c5`.
- Candidate: identical revisions plus only the local `src/context.zig`
  pressure-counter patch; the temporary worktree contained no other source
  changes.
- Workload: exact `bench/comparison.js` `object_churn` bytes, shared mode,
  100 jobs per lane, ReleaseFast runners.
- Sampling: seven fresh-process pairs at 1/2/4/8 lanes with alternating process
  order; every checksum matched.
- Host: Apple M3 Pro, 11 physical/logical CPUs, 18 GiB; AC power reported after
  the matrix while the battery was 29% and discharging.
- Raw evidence: [all 56 process results](object-churn-pressure-accounting-ab-2026-07-18.tsv).

Lower time is better. Speedup is parent median divided by candidate median;
values above 1.00x favor the candidate. Scaling is aggregate throughput against
each variant's own one-lane median.

| lanes | parent (ms) | parent RSD | parent scaling | candidate (ms) | candidate RSD | candidate scaling | speedup | pair wins |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 150.130 | 12.01% | 1.00x | 157.426 | 8.46% | 1.00x | **0.95x** | 3 / 7 |
| 2 | 154.534 | 20.42% | 1.94x | 178.145 | 5.71% | 1.77x | **0.87x** | 3 / 7 |
| 4 | 513.544 | 9.20% | 1.17x | 589.645 | 2.61% | 1.07x | **0.87x** | 0 / 7 |
| 8 | 1,988.980 | 7.81% | 0.60x | 2,357.016 | 5.04% | 0.53x | **0.84x** | 0 / 7 |

## Decision

Reject and revert this counter design. It regresses every median by 4.9% / 15.3%
/ 12.8% / 18.5%; the candidate loses every paired sample at four and eight
lanes. Removing one heap-wide RMW does not compensate for exact threshold reads
that acquire all six bucket locks at cooperative safepoints. A future counter
candidate needs a cheap non-blocking read path and must still prove exact reset
semantics.

The normal and suppression-free TSan backing/cooperative tests passed before
measurement, including exact concurrent increments and reset exclusion. Those
tests and the runtime patch are removed with the rejected design. The accepted
README benchmark matrix is unchanged.
