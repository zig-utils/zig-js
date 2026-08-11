# Exact-parent canonical locale-list evidence — 2026-08-10

Exact-parent performance and allocation evidence for
[#528](https://github.com/zig-utils/zig-js/issues/528). Fixture construction is
outside the timed boundary. Every process uses the same checked-in workload,
frozen checksum, `zig-gc` revision, and `zig-regex` revision.

The implementation landed in two direct-parent commits:

1. `77b939131f6191cc18c92cc05bfad2f7f61d5bff` →
   `9cc8d4964bbcc3b37cca35faf5254329a6d654f3` adds the secure native index,
   bounded numeric keys, reclaimable per-element canonicalization scratch, and
   failure-atomic OOM handling.
2. `9cc8d4964bbcc3b37cca35faf5254329a6d654f3` →
   `c4662097610ff13199b804fca380e4b95802d439` retains one bounded scratch
   capacity per invocation and resets it between elements.

## Seven-pair timing and efficiency

| workload | jobs | first edge wall | first edge instructions | refinement wall | refinement instructions |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8 unique (linear control) | 10,000 | 1.030x | 1.054x | 0.941x | 0.905x |
| 1,024 unique | 100 | 0.252x | 0.219x | — | — |
| 2,048 unique | 50 | 0.156x | 0.141x | — | — |
| 4,096 unique | 20 | 0.084x | 0.071x | 0.826x | 0.781x |
| 4,096 input / 32 unique | 100 | 0.862x | 0.921x | — | — |

Ratios are candidate / exact parent, so lower is better. Chaining both direct
edges makes the final 8-item control approximately `0.969x` wall / `0.954x`
instructions and the final 4K unique row approximately `0.069x` wall / `0.056x`
instructions. The final control therefore does not purchase wide-list scaling
with an ordinary-list regression.

Every timing artifact contains seven order-balanced fresh-process pairs, exact
binary/source/dependency identities, wall time, instructions, cycles, energy,
thermal state, peak RSS, and the frozen checksum. Raw artifacts:

- [8-item control](exact-parent-locale-list-8-2026-08-10.json) and
  [control refinement](exact-parent-locale-list-8-refinement-2026-08-10.json)
- [1K unique](exact-parent-locale-list-1024-2026-08-10.json)
- [2K unique](exact-parent-locale-list-2048-2026-08-10.json)
- [4K unique](exact-parent-locale-list-4096-2026-08-10.json) and
  [4K refinement](exact-parent-locale-list-4096-refinement-2026-08-10.json)
- [4K duplicate-heavy](exact-parent-locale-list-duplicates-4096-2026-08-10.json)

## Deterministic allocation attribution

One attribution process per exact revision records cumulative configuration,
warmup, and invocation snapshots. The table subtracts warmup from invocation,
isolating one scored 20-job pass over the prebuilt 4,096-element unique array.
Checksum `87980` matches all three revisions.

| scored invocation delta | benchmark parent | indexed candidate | refined candidate | final / original |
| --- | ---: | ---: | ---: | ---: |
| backing allocation calls | 164,272 | 328,130 | 82,450 | 0.502x |
| backing allocation bytes | 61,486,226 | 107,539,406 | 13,048,926 | 0.212x |
| backing growth calls | 282 | 227 | 227 | 0.805x |
| backing release calls | 159,924 | 328,027 | 82,347 | 0.515x |
| backing current-byte increase | 60,710,606 | 4,191,682 | 4,191,682 | 0.069x |
| backing peak-byte increase | 59,429,908 | 2,449,643 | 2,449,643 | 0.041x |
| GC-cell calls | 163,922 | 82,002 | 82,002 | 0.500x |
| GC-cell requested bytes | 10,496,512 | 5,253,632 | 5,253,632 | 0.501x |

The first edge removes managed decimal-index strings and realm-owned
canonicalization intermediates; that halves logical GC-cell work and reduces the
scored retained-backing increase by 56,518,924 bytes (93.1%). Its initial
per-element arena lifecycle increases transient native calls. The second edge
keeps the same bounded high-water while removing 245,680 allocation and 245,680
release calls from that edge's scored invocation. Final versus original uses
81,822 fewer allocation calls and requests 48,437,300 fewer backing bytes.

Full snapshots and binary SHA-256 identities are in
[the allocation artifact](exact-parent-locale-list-allocation-2026-08-10.json).
The exact equality checks, Proxy order test, moving-nursery test, bounded 4 MiB
heap test, deterministic OOM sweep, no-GIL TSan test, full unit suite, and
3,341-case Intl402 run establish that the reductions do not come from skipped
work or cached output.
