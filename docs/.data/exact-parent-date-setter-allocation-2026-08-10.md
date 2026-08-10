# Exact-parent Date setter allocation attribution — 2026-08-10

Allocation companion for [#524](https://github.com/zig-utils/zig-js/issues/524).
The exact workload performs ten warmup passes of 4,096 four-component
`setUTCHours` calls, then one scored pass; checksum `2008733666` matches both
revisions.

- parent: `e2348ffdd64aa999f3d5872607a91f397414921f`
- candidate: `ddaae8a53005610ee646d3d3f9571bdc5f4073b3`
- raw snapshots: [exact-parent-date-setter-allocation-2026-08-10.json](exact-parent-date-setter-allocation-2026-08-10.json)

| ten-pass warmup delta | parent | candidate | candidate - parent |
| --- | ---: | ---: | ---: |
| backing allocation calls | 152 | 151 | -1 |
| backing allocation bytes | 15,443,554 | 6,178,222 | -9,265,332 |
| backing growth calls | 108 | 38 | -70 |
| backing growth bytes | 14,864 | 6,644 | -8,220 |
| backing current/peak bytes | 15,456,178 | 6,182,626 | -9,273,552 |
| GC-cell calls / bytes | 30 / 6,400 | 30 / 6,400 | 0 / 0 |

The candidate removes proportional argument-slice retention. The following
single scored pass has the same parent/candidate allocator deltas (15 backing
calls, 973 allocation bytes, 749 current/peak bytes, and 3 GC cells / 640
bytes), demonstrating that no replacement cache or scratch growth moved onto
the hot path after the warm arena reached its high-water mark.

Seven-pair observed process evidence independently reports 4K setter retained
RSS at `0.9468x` and peak RSS at `0.9469x`. The identical `setTime` control is
`1.0043x` for both retained and peak RSS, isolating the reduction to component
setter argument storage rather than a process-wide change.
