# Exact-parent generic Array index-key evidence — 2026-08-10

Exact-parent performance and allocation evidence for
[#529](https://github.com/zig-utils/zig-js/issues/529). Fixture construction is
outside the timed boundary. Every process uses the same checked-in workload,
frozen checksum, `zig-gc` revision, and `zig-regex` revision.

The direct edge is benchmark parent
`6e519a751126fa237c8893eb37e778cd9f08a206` to implementation
`bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`. The implementation bounds
ephemeral decimal index keys; it does not address the independently tracked
deep-Shape lookup curve in [#530](https://github.com/zig-utils/zig-js/issues/530).

## Exact timing and process evidence

| workload | jobs | pairs | wall | instructions | peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,024-property plain array-like | 100 | 7 | 1.002x | 0.997x | 0.970x |
| 2,048-property plain array-like | 20 | 7 | 0.978x | 0.993x | 0.983x |
| 4,096-property plain array-like | 4 | 7 | 0.989x | 1.002x | 0.987x |
| sparse 4,096-length Proxy | 6 | 7 | 1.024x | 1.001x | 0.983x |
| dense 4,096-element Array control | 100 | 15 | 1.001x | 1.008x | 1.000x |

Ratios are candidate / exact parent, so lower is better. The generic rows remain
dominated by the O(depth) Shape lookup diagnosed in #530; #529 therefore makes
no unsupported throughput claim. The 15-pair dense refinement shows that the
unchanged dense fast path remains neutral while the generic ownership fix lands.

Each artifact contains order-balanced fresh-process pairs, exact
binary/source/dependency identities, wall time, instructions, cycles, energy,
thermal state, peak RSS, and a frozen checksum. Raw artifacts:

- [1K plain array-like](exact-parent-array-like-1024-2026-08-10.json)
- [2K plain array-like](exact-parent-array-like-2048-2026-08-10.json)
- [4K plain array-like](exact-parent-array-like-4096-2026-08-10.json)
- [4K sparse Proxy](exact-parent-array-like-sparse-proxy-4096-2026-08-10.json)
- [dense control](exact-parent-array-dense-control-4096-2026-08-10.json) and
  [15-pair refinement](exact-parent-array-dense-control-4096-refinement-2026-08-10.json)

## Deterministic allocation attribution

One attribution process per exact revision records cumulative configuration,
warmup, and invocation snapshots. The table subtracts warmup from invocation,
isolating one scored 100-job pass over the prebuilt 1,024-property plain
array-like object. Checksum `209715200` matches both revisions.

| scored invocation delta | benchmark parent | candidate | candidate / parent |
| --- | ---: | ---: | ---: |
| backing allocation calls | 410,210 | 410,209 | 1.000x |
| backing allocation bytes | 59,423,930 | 38,534,342 | 0.648x |
| backing growth calls | 215 | 28 | 0.130x |
| backing growth bytes | 24,138 | 7,968 | 0.330x |
| backing release calls | 406,103 | 406,103 | 1.000x |
| backing current-byte increase | 35,070,438 | 14,164,680 | 0.404x |
| backing peak-byte increase | 33,607,932 | 13,914,144 | 0.414x |
| GC-cell calls | 205,102 | 205,102 | 1.000x |
| GC-cell requested bytes | 52,499,712 | 52,499,712 | 1.000x |
| attribution-process retained RSS | 55,230,464 | 53,477,376 | 0.968x |

The change removes 20,889,588 requested backing bytes, 187 backing-growth
events, and 20,905,758 retained backing bytes from the scored invocation. Equal
GC-cell work is expected: the removed decimal keys were native arena bytes, not
managed JavaScript strings. Full warmup/invocation snapshots and binary SHA-256
identities are in
[the allocation artifact](exact-parent-array-index-key-allocation-2026-08-10.json).

The exact Proxy/accessor/inherited-hole order tests, post-return ownership test,
deterministic allocation-failure sweep, re-entrant and moving-GC test, bounded
32 MiB heap test, no-GIL TSan test, full unit suite, and 2,810-case Array
prototype test262 run establish that the reduction does not come from skipped
work, cached output, or weakened semantics.
