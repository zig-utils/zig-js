# Numeric-separator exact-parent evidence — 2026-08-12

Diagnostic exact-parent evidence for
[#544](https://github.com/zig-utils/zig-js/issues/544). The engine pair is
`0a212b51184f6e6e0eeb0ad49ad205ef34ea3f79` →
`4fdff17b1d8a09a03d5fe4a03e325766eb062c10`. Both ReleaseFast binaries were
built in clean worktrees with the same counter and allocation-observer harness
from `ad8403fb` and `eb657c07`; after those harness patches, the two build trees
differed only in `src/lexer.zig`. Every binary and workload source is hashed in
the raw artifacts.

Each row used seven order-balanced fresh-process pairs with no discarded
samples. One sample is ten parser-only parse-and-AST-validation jobs over a
preconstructed source after ten one-job warmups. Allocation metrics come from
an untimed replay of identical work immediately above the parser arena, so
observer overhead is outside the wall and hardware-counter boundary.

| workload | wall candidate / parent | wall RSD parent / candidate | instructions candidate / parent | instructions RSD parent / candidate | allocation requests parent → candidate | allocated bytes parent → candidate | peak RSS candidate / parent |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| separated 1K | 0.920x | 3.12% / 36.81% | 0.9463x | 0.06% / 1.68% | 31,030 → 20,790 | 10,345,760 → 9,147,680 | 0.9956x |
| separated 2K | 0.891x | 20.95% / 17.65% | 0.9440x | 1.28% / 1.09% | 61,780 → 41,300 | 16,870,160 → 14,474,000 | 0.9503x |
| separated 4K | 0.887x | 3.86% / 3.42% | 0.9455x | 0.01% / 0.01% | 123,250 → 82,290 | 36,485,920 → 31,693,600 | 0.9933x |
| unseparated 4K control | 1.005x | 8.85% / 4.38% | 0.9728x | 0.23% / 0.07% | 41,330 → 41,330 | 21,795,040 → 21,795,040 | 0.9944x |

The separated rows remove exactly one logical allocation/resize request per
literal: 10,240, 20,480, and 40,960 requests across ten jobs. Cumulative parser
allocation bytes fall by 11.6–14.2%. The unseparated control has byte-for-byte
identical allocation counters, consistent with the focused zero-normalization-
allocation witness.

Retired instructions are stable and fall by 5.4–5.6% on every separated row.
Only the 4K wall row clears the 5% dispersion threshold for both variants; it
records an 11.3% reduction. The 1K/2K wall rows remain diagnostic because of
noise. The unseparated control records no wall, allocation, byte, or RSS
regression. Energy readings at this duration are zero or noisy, so these are
diagnostic causal results rather than a quiet-reference publication claim.

Per-row reports and raw samples:

- [separated 1K report](exact-parent-frontend-numeric-separators-1024-2026-08-12.md) · [raw JSON](exact-parent-frontend-numeric-separators-1024-2026-08-12.json)
- [separated 2K report](exact-parent-frontend-numeric-separators-2048-2026-08-12.md) · [raw JSON](exact-parent-frontend-numeric-separators-2048-2026-08-12.json)
- [separated 4K report](exact-parent-frontend-numeric-separators-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-numeric-separators-4096-2026-08-12.json)
- [unseparated 4K control report](exact-parent-frontend-numeric-unseparated-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-numeric-unseparated-4096-2026-08-12.json)
