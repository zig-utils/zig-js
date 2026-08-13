# Template raw normalization exact-parent evidence — 2026-08-13

Diagnostic exact-parent evidence for
[#550](https://github.com/zig-utils/zig-js/issues/550), comparing benchmark
parent `48556702fec31b7cd59bdc45f8323ef33bf4e6e7` with implementation
`ab8c6d9eb5ad5d7f655e6c046cef9d30d410c532`. Both ReleaseFast runners use the
same committed parser-only workloads and independently validate every complete
normalized value. The raw artifacts retain workload and binary hashes,
dependency revisions, Zig `0.17.0-dev.1441+d5181a9c9`, macOS 27.0, and the
11-core Apple M3 Pro host.

Each row contains seven order-balanced fresh-process pairs with no discarded
samples. A sample runs 200 parser-only jobs after ten 20-job warmups. Source
construction is outside the timed boundary; lexing, TRV normalization, AST
construction, and exact value validation stay inside it. Logical allocation
requests and bytes come from an untimed replay of identical work immediately
above the parser arena.

| normalized templates | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 40.209 ms → 36.143 ms | 0.899x | 779,337,313 → 717,425,840 | 0.9206x | 415,800 → 415,800 | 151,830,400 → 137,272,400 |
| 2,048 | 74.082 ms → 68.418 ms | 0.924x | 1,560,053,651 → 1,434,257,957 | 0.9194x | 826,000 → 826,000 | 229,115,200 → 200,221,200 |
| 4,096 | 159.458 ms → 141.139 ms | 0.885x | 3,143,410,180 → 2,883,612,017 | 0.9174x | 1,645,800 → 1,645,800 | 541,577,600 → 484,011,600 |

Both variants make one raw-normalization request per template; the candidate
retains exactly the normalized bytes instead of list growth capacity.
Cumulative parser allocation bytes fall 9.6%, 12.6%, and 10.6%. Stable retired
instructions fall 7.9%, 8.1%, and 8.3%. The 1K and 2K wall rows are below 5%
RSD and improve 10.1% and 7.6%. Candidate wall dispersion reaches 7.36% at 4K,
so its 11.5% lower median remains diagnostic. Instruction growth remains
near-linear as template count doubles in both variants.

The tagged 4,096-template row validates exact normalized raw/cooked equality.
Allocation requests remain exact at 4,103,600 while bytes fall from 723,260,800
to 665,694,800 (0.9204x). Stable retired instructions fall from 4,447,891,009
to 4,196,362,656 (0.9434x), and stable wall falls from 243.634 ms to
223.933 ms (0.919x).

Every thermal boundary is nominal. The artifacts use the `diagnostic` host
classification, so the stable rows are causal evidence rather than
quiet-reference publication claims. The noisy 2K peak-RSS row and 4K untagged
wall row are not promoted.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-normalized-templates-1024-2026-08-13.md) · [raw JSON](exact-parent-frontend-normalized-templates-1024-2026-08-13.json)
- [2K report](exact-parent-frontend-normalized-templates-2048-2026-08-13.md) · [raw JSON](exact-parent-frontend-normalized-templates-2048-2026-08-13.json)
- [4K report](exact-parent-frontend-normalized-templates-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-normalized-templates-4096-2026-08-13.json)
- [tagged 4K report](exact-parent-frontend-normalized-templates-control-tagged-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-normalized-templates-control-tagged-4096-2026-08-13.json)
