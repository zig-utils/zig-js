# Independent object-churn stable-identity A/B — 2026-07-29

Order-balanced exact-parent diagnostic for [#445](https://github.com/zig-utils/zig-js/issues/445).

- zig-js: `56ffd9b77d6f8dcac8d0416798778f230b3eb02e` in both variants
- parent zig-gc: `958563a340ca4517deff05faa785b2c633e8798a`
- candidate zig-gc: `a09c015`
- host: macOS-27.0-arm64-arm-64bit · arm64
- sampling: 7 alternating fresh-process pairs per lane and mode; ReleaseFast; exact `object_churn`, 100 jobs/lane
- every checksum matched; maximum resident set size is captured by `/usr/bin/time -l`

| mode | lanes | parent wall | candidate wall | speedup | parent scaling | candidate scaling | candidate/parent RSS | pair wins |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| steady | 1 | 123.381 ms (2.8% RSD) | 122.121 ms (3.0% RSD) | 1.01x | 1.00x | 1.00x | 0.999x | 3/7 |
| steady | 2 | 222.875 ms (14.2% RSD) | 140.873 ms (5.4% RSD) | 1.58x | 1.11x | 1.73x | 1.003x | 7/7 |
| steady | 4 | 772.431 ms (1.4% RSD) | 148.633 ms (3.3% RSD) | 5.20x | 0.64x | 3.29x | 1.051x | 7/7 |
| steady | 8 | 3,253.011 ms (7.0% RSD) | 237.193 ms (21.3% RSD) | 13.71x | 0.30x | 4.12x | 1.031x | 7/7 |
| cold | 1 | 130.733 ms (13.0% RSD) | 135.089 ms (5.0% RSD) | 0.97x | 1.00x | 1.00x | 1.001x | 3/7 |
| cold | 2 | 246.856 ms (6.6% RSD) | 140.693 ms (1.0% RSD) | 1.75x | 1.06x | 1.92x | 1.002x | 7/7 |
| cold | 4 | 780.727 ms (0.7% RSD) | 163.349 ms (2.7% RSD) | 4.78x | 0.67x | 3.31x | 1.000x | 7/7 |
| cold | 8 | 3,443.252 ms (8.6% RSD) | 243.537 ms (3.5% RSD) | 14.14x | 0.30x | 4.44x | 1.011x | 7/7 |

## Focused eight-lane leaf profile

| category | parent samples | candidate samples |
| --- | ---: | ---: |
| host allocator | 0 | 0 |
| GC rendezvous | 0 | 0 |
| nursery collection | 946 | 3,177 |
| cell publication | 7,326 | 1,404 |
| mutator execution | 2,033 | 2,041 |
| worker lifecycle/wait | 1,323 | 2,155 |
| other | 233 | 546 |

## Finding

The parent profile records 6,301 leaf samples in `Heap.create`, whose inlined publication path assigned every cell through one process-global stable-ID CAS. The candidate records 541 there after reserving non-recycled 4,096-ID blocks per allocator thread. Independent contexts do not arm cooperative GC rendezvous or shared-heap publication locks, and the leaf profile finds no competing allocator-lock or rendezvous cluster.

The cold/steady proximity rules out worker creation as the throughput knee. Nursery work becomes visible only after the global identity cache line is removed; it does not prevent monotonic candidate scaling. Checksums are identical, and the RSS column verifies that the speedup does not come from unbounded retained storage.

Raw timing/RSS evidence: [object-churn-independent-id-block-ab-2026-07-29.tsv](object-churn-independent-id-block-ab-2026-07-29.tsv).
Collapsed profiler evidence: [object-churn-independent-profile-2026-07-29.tsv](object-churn-independent-profile-2026-07-29.tsv).

This focused A/B is causal evidence for the dependency change; it does not replace the complete zig-js/JavaScriptCore publication matrix.
