# Shared object-churn amortized-publication A/B — 2026-07-16

This focused comparison isolates the combined allocation-publication change for
[zig-js #97](https://github.com/zig-utils/zig-js/issues/97) and
[zig-gc #25](https://github.com/zig-utils/zig-gc/issues/25). The candidate keeps
unused fixed-shape objects in a bounded, precisely traced interpreter reserve
while multiple shared-realm workers contend. Its zig-gc dependency privately
chains owned batches of at least 64 cells, splices the entire chain under the
allocation-metadata lock, and publishes the binding ownership bitmap after
releasing that lock. A lone worker retains the prior 17-cell checkpoint batch.

- Exact parent: zig-js `0ff344664d461d9c95b2c47cd741476a8b271c92`,
  zig-gc `092d8d76b41b3c47c8cc4acb8646ee1d66879c20`.
- Candidate: zig-js `76a1119faec9ee237a68198b3aca7660c10b4e07`,
  zig-gc implementation `dee13e6ddbe76b54a86daaec86d9be0dff2d66ea`.
- Workload: the exact `bench/comparison.js` `object_churn` bytes, shared mode,
  100 jobs in every lane, ReleaseFast runners.
- Sampling: seven fresh-process pairs per lane; parent/candidate process order
  alternated inside each lane. Every checksum matched.
- Host: Apple M3 Pro, 11 cores, 18 GB, battery power while discharging.
- Raw evidence: [all 56 process results](object-churn-amortized-publication-ab-2026-07-16.tsv).

Lower time is better. Speedup is parent median divided by candidate median, so
values above 1.00x favor the candidate. Scaling is aggregate throughput relative
to that variant's own one-lane median. RSD is the sample standard deviation
divided by the sample mean.

| lanes | parent (ms) | parent RSD | parent scaling | candidate (ms) | candidate RSD | candidate scaling | speedup | pair wins |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 99.901 | 1.12% | 1.00x | 100.562 | 0.71% | 1.00x | 0.99x | 2 / 7 |
| 2 | 168.035 | 1.41% | 1.19x | 112.393 | 0.43% | 1.79x | **1.50x** | 7 / 7 |
| 4 | 272.951 | 2.37% | 1.46x | 141.772 | 3.97% | 2.84x | **1.93x** | 7 / 7 |
| 8 | 1,542.720 | 8.78% | 0.52x | 1,239.637 | 3.18% | 0.65x | **1.24x** | 7 / 7 |

The thresholded design fixes the lower-lane regression that caused the earlier
standalone O(1)-splice experiment to be rejected. One lane changes by only
0.66%, within the observed dispersion, while every contended pair wins. The
largest relative improvement is at four lanes, where candidate aggregate
scaling nearly doubles from 1.46x to 2.84x.

This does not close zig-js #97. Eight-lane absolute time improves 19.6% and its
mode-local scaling improves from 0.52x to 0.65x, but the issue requires at least
1.0x scaling at every shared lane with repeated low-dispersion evidence. This is
also a focused zig-js-only A/B, not a replacement for the complete published
zig-js/JavaScriptCore matrix.

Validation after measurement:

- zig-gc: full normal and ThreadSanitizer unit suites pass.
- zig-js: 777/777 full unit tests pass with zero leaks.
- zig-js: all five `fixed-shape` tests pass under ThreadSanitizer, including the
  real shared-Thread allocation test and precise checkpoint-root test.

