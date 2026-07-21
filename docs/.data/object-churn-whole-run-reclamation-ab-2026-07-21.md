# Whole-run nursery backing A/B — 2026-07-21

Order-balanced exact-parent diagnostic for [zig-js #427](https://github.com/zig-utils/zig-js/issues/427) and [zig-gc #42](https://github.com/zig-utils/zig-gc/issues/42).

- parent: zig-js `8e4580cf` + zig-gc `529e0f2`
- candidate: zig-js working tree consuming zig-gc `64d2660`
- sampling: 7 alternating fresh-process pairs per lane; ReleaseFast; exact `object_churn`, 100 jobs/lane
- every checksum and collector accounting invariant matched across both variants

| lanes | parent wall | candidate wall | wall speedup | parent sweep | candidate sweep | sweep speedup | pair wins |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 116.525 ms | 117.864 ms | 0.989x | 0.000 ms | 0.000 ms | 1.000x | 2/7 |
| 2 | 144.723 ms | 143.462 ms | 1.009x | 0.000 ms | 0.000 ms | 1.000x | 4/7 |
| 4 | 240.444 ms | 239.796 ms | 1.003x | 0.000 ms | 0.000 ms | 1.000x | 2/7 |
| 8 | 1,903.723 ms | 1,920.615 ms | 0.991x | 456.326 ms | 453.324 ms | 1.007x | 2/7 |

## Verdict

Rejected and fully reverted. The candidate improved eight-lane sweep by only
0.7% while regressing eight-lane wall time by 0.9% and winning 2/7 pairs; one
lane also regressed 1.1%. No zig-js activation was committed. The generic
zig-gc experiment (`64d2660`) was removed by `88ea254`, restoring its source
exactly to the tested parent tree. The remaining sweep cost is not governed by
backing bitmap/free-slot transitions, so the next work must attribute the
collector's per-cell finalization, indexing, header, and iteration work.

README scores are unchanged; this focused A/B is not a complete zig-js/JSC matrix.
