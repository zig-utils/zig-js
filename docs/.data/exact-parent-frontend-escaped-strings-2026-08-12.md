# Escaped string decoding exact-parent evidence — 2026-08-12

Diagnostic exact-parent evidence for
[#548](https://github.com/zig-utils/zig-js/issues/548), comparing benchmark
parent `44d584817521be0c8011c5f09b29a87cadab3ff9` with implementation
`3ca764e2867e891bcd4158213f2769aac217e732`. Both ReleaseFast runners use the
same committed parser-only workload and exact decoded-string validation. The
raw artifacts retain the workload and binary hashes, dependency revisions,
Zig `0.17.0-dev.1441+d5181a9c9`, macOS 27.0, and the 11-core Apple M3 Pro host.

Each row contains seven order-balanced fresh-process pairs with no discarded
samples. A sample runs 200 parser-only jobs after ten 20-job warmups. Source
construction is outside the timed boundary; lexing, escape validation,
decoding, AST construction, and exact decoded-value checks remain inside it.
Logical allocation requests and bytes come from an untimed replay of identical
work immediately above the parser arena.

| string literals | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 25.520 ms → 23.815 ms | 0.933x | 465,916,263 → 451,289,783 | 0.9686x | 620,600 → 415,800 | 206,915,200 → 190,309,200 |
| 2,048 | 43.934 ms → 43.541 ms | 0.991x | 920,380,605 → 895,035,106 | 0.9725x | 1,235,600 → 826,000 | 337,403,200 → 304,413,200 |
| 4,096 | 142.332 ms → 134.644 ms | 0.946x | 1,866,125,490 → 1,818,004,343 | 0.9742x | 2,465,000 → 1,645,800 | 729,718,400 → 663,960,400 |

The request deltas are exactly 204,800, 409,600, and 819,200: one removed
allocation/resize request for every decoded literal in every one of the 200
jobs. Total parser allocation requests fall 33.0%, 33.2%, and 33.2%; cumulative
allocated bytes fall 8.0%, 9.8%, and 9.0%. Stable retired instructions fall
3.1%, 2.8%, and 2.6%. Instruction growth remains near-linear as the literal
count doubles: parent totals grow 1.98x then 2.03x, and candidate totals grow
1.98x then 2.03x.

The ordinary 4,096-literal control preserves allocation requests and bytes
exactly at 826,600 and 435,900,800. Its stable retired instructions fall from
1,447,116,114 to 1,358,992,254 (0.9391x) because the lexer scans with a local
cursor instead of writing its public cursor for every source byte. Peak RSS in
all four rows stays within 0.2% at the median.

These are diagnostic artifacts, not quiet-reference publication claims. Wall
dispersion exceeds 5% in at least one variant of every row; the 4K escaped row
records 5.14% parent and 6.34% candidate RSD, and the ordinary control is noisier.
Energy is likewise not used as a claim. Instructions and allocation accounting
are stable and agree on less work, while all thermal boundaries remain nominal.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-escaped-strings-1024-2026-08-12.md) · [raw JSON](exact-parent-frontend-escaped-strings-1024-2026-08-12.json)
- [2K report](exact-parent-frontend-escaped-strings-2048-2026-08-12.md) · [raw JSON](exact-parent-frontend-escaped-strings-2048-2026-08-12.json)
- [4K report](exact-parent-frontend-escaped-strings-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-escaped-strings-4096-2026-08-12.json)
- [ordinary 4K control report](exact-parent-frontend-escaped-strings-control-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-escaped-strings-control-4096-2026-08-12.json)
