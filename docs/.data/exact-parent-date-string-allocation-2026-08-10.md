# Exact-parent Date string allocation attribution — 2026-08-10

Allocation companion for [#526](https://github.com/zig-utils/zig-js/issues/526).
The workload performs ten warmup passes and one scored pass of 4,096 iterations.
Each iteration constructs and consumes complete `toDateString`, `toTimeString`,
`toString`, `toUTCString`, `toISOString`, and Date-fast-path `toJSON` results;
checksum `27028737` matches both exact revisions.

- parent: `cdabd71fee32bf72abcd31283237a8a25f8c0f1e`
- candidate: `0b01b7899ed847349b66605bea73be8a949fc065`
- raw snapshots: [exact-parent-date-string-allocation-2026-08-10.json](exact-parent-date-string-allocation-2026-08-10.json)

| scored 4K invocation delta | parent | candidate | candidate - parent |
| --- | ---: | ---: | ---: |
| backing allocation calls | 950,294 | 950,293 | -1 |
| backing allocation bytes | 281,847,835 | 123,246,379 | -158,601,456 |
| backing growth calls | 215 | 0 | -215 |
| backing growth bytes | 16,358 | 0 | -16,358 |
| backing release calls | 918,650 | 935,034 | +16,384 |
| backing released bytes | 118,918,859 | 119,152,331 | +233,472 |
| backing current bytes | 162,945,334 | 4,094,048 | -158,851,286 |
| backing peak increase | 158,852,748 | 1,462 | -158,851,286 |
| GC-cell calls / bytes | 487,427 / 60,818,048 | 487,427 / 60,818,048 | 0 / 0 |

The candidate removes 158,851,286 bytes (97.5%) of new retained Context backing
from the scored invocation without changing logical managed-cell issuance. Its
final string bytes move onto reclaimable realm backing: the invocation performs
16,384 additional releases and returns 233,472 additional bytes while eliminating
all 215 backing-growth events. No output cache, skipped conversion, or replacement
GC-cell population accounts for the reduction.

The ten-pass warmup includes 146 automatic collections. Both revisions issue the
same 4,874,270 logical GC cells and 608,180,480 requested cell bytes there. The
candidate records 302 fewer backing-growth events, 163,840 more releases, and
466,578 fewer current/peak backing bytes; its requested allocation bytes are
1,892,550 higher because final outputs now originate in reclaimable realm storage
instead of untracked arena intermediates. The scored post-warm invocation exposes
the causal high-water difference above.

Seven-pair process evidence is reported separately. The ordinary 4K row records
stable peak RSS at `0.9670x`; the retained-RSS observer is intentionally not used
for a directional claim because its parent and candidate RSDs are 37.00% and
43.95%. The unrelated Date getter control is neutral at `0.9987x` instructions
and `1.003x` wall time.
