# Shared object-churn GC phase profile — 2026-07-21

Focused diagnostic for [#426](https://github.com/zig-utils/zig-js/issues/426); it is not a replacement for the published zig-js/JSC matrix.

- zig-js: `8b271b348c1c214d891554cd4def14ed45bba78c`
- zig-gc: `529e0f21e9369477f7e4ec41d70f2cfd41aa1702`
- host: macOS-27.0-arm64-arm-64bit · arm64
- sampling: 7 fresh ReleaseFast processes per lane; exact `object_churn`, 100 jobs/lane
- every checksum and collector accounting invariant matched

| lanes | median | RSD | scaling | coop pause | minor sweep | object-batch CPU | max worker |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 113.964 ms | 1.31% | 1.00x | 0.000 ms (0.0%) | 0.000 ms | 34.741 ms | 113.603 ms |
| 2 | 136.776 ms | 9.87% | 1.67x | 0.000 ms (0.0%) | 0.000 ms | 86.994 ms | 136.427 ms |
| 4 | 287.426 ms | 4.05% | 1.59x | 0.000 ms (0.0%) | 0.000 ms | 392.430 ms | 287.029 ms |
| 8 | 1,862.639 ms | 2.78% | 0.49x | 618.958 ms (33.2%) | 540.893 ms | 4,617.197 ms | 1,862.216 ms |

## Finding

At eight lanes, cooperative GC accounts for 33.2% of wall time. Nursery sweep is 87.4% of that pause (540.893 ms), versus 0.020 ms of rendezvous and 0.399 ms of trace. The median cycle reclaims 1.073 GB while retaining only 3,052 young cells. The next measured candidate is whole-run dead nursery backing reclamation ([zig-js #427](https://github.com/zig-utils/zig-js/issues/427), [zig-gc #42](https://github.com/zig-utils/zig-gc/issues/42)), not another rendezvous or tracing optimization.

`object-batch CPU` sums allocation/publication time across workers and may exceed wall time. Cooperative pause and phase columns are collector wall time while peers are stopped.
