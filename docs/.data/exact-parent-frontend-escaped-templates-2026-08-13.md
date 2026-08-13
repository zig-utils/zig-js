# Escaped template cooking exact-parent evidence — 2026-08-13

Diagnostic exact-parent evidence for
[#549](https://github.com/zig-utils/zig-js/issues/549), comparing benchmark
parent `67149a3ffdfac6f41225f0ec92071823193bc98f` with implementation
`b3c8c3bad46fd2200c723c2e6b4d4f07a97f0858`. Both ReleaseFast runners use the
same committed parser-only workload and exact cooked/raw template validation.
The raw artifacts retain workload and binary hashes, dependency revisions,
Zig `0.17.0-dev.1441+d5181a9c9`, macOS 27.0, and the 11-core Apple M3 Pro host.

Each row contains seven order-balanced fresh-process pairs with no discarded
samples. A sample runs 200 parser-only jobs after ten 20-job warmups. Source
construction is outside the timed boundary; lexing, TRV normalization, escape
validation and cooking, AST construction, and exact value checks stay inside
it. Logical allocation requests and bytes come from an untimed replay of
identical work immediately above the parser arena.

| escaped quasis | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 33.503 ms → 30.704 ms | 0.916x | 668,511,165 → 649,994,858 | 0.9723x | 415,800 → 415,800 | 151,830,400 → 135,224,400 |
| 2,048 | 70.512 ms → 61.868 ms | 0.877x | 1,335,615,696 → 1,299,941,995 | 0.9733x | 826,000 → 826,000 | 229,115,200 → 196,125,200 |
| 4,096 | 133.165 ms → 128.316 ms | 0.964x | 2,681,311,458 → 2,620,530,447 | 0.9773x | 1,645,800 → 1,645,800 | 541,577,600 → 475,819,600 |

Request counts remain exact because both variants make one cooked-byte request
per escaped quasi; the candidate eliminates growth capacity and transfer
storage rather than hiding the request. Cumulative parser allocation bytes fall
10.9%, 14.4%, and 12.1%. Stable retired instructions fall 2.8%, 2.7%, and 2.3%.
Wall medians improve 8.4%, 12.3%, and 3.6%; both variants remain below 5% wall
RSD in all three escaped rows. Instruction growth remains near-linear as quasi
count doubles: parent totals grow 2.00x then 2.01x, and candidate totals grow
2.00x then 2.02x.

The plain 4,096-quasi control preserves allocation requests and bytes exactly
at 826,600 and 435,900,800. Its stable retired instructions fall from
2,257,325,463 to 2,097,058,198 (0.9290x) because the no-substitution path no
longer performs a second general template scan. Its candidate wall RSD is
6.97%, so the 0.954x wall median remains diagnostic.

The plain tagged 4,096-quasi control keeps request count exact at 3,284,400
while allocated bytes fall from 827,299,200 to 617,584,000 (0.7465x), because
single-quasi cooked/raw arrays are now exact instead of list-capacity backed.
Stable retired instructions fall from 3,609,151,473 to 3,362,363,451 (0.9316x).
Its wall result is too noisy to interpret and is not promoted.

All thermal boundaries are nominal. The artifacts use the `diagnostic` host
classification, so even the stable escaped rows are causal evidence rather
than quiet-reference publication claims. No energy claim is made where either
variant exceeds the five-percent dispersion threshold.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-escaped-templates-1024-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-templates-1024-2026-08-13.json)
- [2K report](exact-parent-frontend-escaped-templates-2048-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-templates-2048-2026-08-13.json)
- [4K report](exact-parent-frontend-escaped-templates-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-templates-4096-2026-08-13.json)
- [plain 4K control report](exact-parent-frontend-escaped-templates-control-plain-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-templates-control-plain-4096-2026-08-13.json)
- [tagged 4K control report](exact-parent-frontend-escaped-templates-control-tagged-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-templates-control-tagged-4096-2026-08-13.json)
