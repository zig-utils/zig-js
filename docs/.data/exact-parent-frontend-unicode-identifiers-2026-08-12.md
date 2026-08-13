# Unicode identifier classification exact-parent evidence — 2026-08-12

Diagnostic exact-parent evidence for
[#547](https://github.com/zig-utils/zig-js/issues/547), comparing benchmark
parent `b7bbea782aa5d2ef1b19a891ab18d6d188135cd1` with implementation
`085cb6224cf135113b6dd112370a4e2aefcc0252`. Both ReleaseFast runners use the
same committed parser-only workloads and allocation/counter instrumentation.
The raw artifacts retain revisions and hashes for the workload source, both
binaries, zig-gc, and zig-regex.

Each row contains seven order-balanced fresh-process pairs with no discarded
samples. A sample runs 100 parser-only parses over one preconstructed source
after ten 10-job warmups. The Unicode rows validate every decoded parameter
prefix and unique ordinal; allocation requests and bytes come from an untimed
replay of identical work immediately above the parser arena.

| workload | wall candidate / parent | wall RSD parent / candidate | instructions candidate / parent | allocations parent → candidate | allocated bytes parent → candidate | peak RSS candidate / parent |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| raw Unicode 1K | 1.085x | 4.33% / 8.91% | 1.0776x | 5,700 → 5,700 | 69,876,800 → 69,876,800 | 1.0083x |
| raw Unicode 2K | 1.130x | 4.81% / 4.39% | 1.0779x | 6,200 → 6,200 | 102,460,800 → 102,460,800 | 1.0038x |
| raw Unicode 4K | 1.093x | 0.99% / 1.58% | 1.0774x | 6,800 → 6,800 | 252,188,000 → 252,188,000 | 1.0068x |
| ASCII 4K control | 0.997x | 0.75% / 13.98% | 1.0079x | 6,800 → 6,800 | 252,188,000 → 252,188,000 | 1.0017x |
| escaped-ASCII 4K control | 0.993x | 0.64% / 0.83% | 1.0045x | 826,000 → 826,000 | 402,783,200 → 402,783,200 | 1.0411x |

Exact Unicode-property validation has a measured cost: raw-Unicode retired
instructions rise consistently by 7.7–7.8%, while the stable 4K wall row rises
9.3%. This is the cost of rejecting symbols, punctuation, unassigned code
points, and continue-only starts that the parent accepted as identifiers. No
allocation count or byte volume changes, and candidate raw-Unicode work remains
near-linear: 2K/1K and 4K/2K instruction ratios are 2.01x and 2.02x.

The branch-local ASCII path remains isolated. Its 4K control changes retired
instructions by 0.79%; the wall row is too noisy to support a difference. The
escaped-ASCII control changes instructions by 0.45% and stable wall by -0.7%.
Peak RSS is process-level and noisy, particularly for the escaped control; no
memory improvement or regression claim is made. These artifacts are diagnostic
correctness-cost evidence, not production throughput claims.

Per-row reports and raw samples:

- [raw Unicode 1K report](exact-parent-frontend-unicode-identifiers-1024-2026-08-12.md) · [raw JSON](exact-parent-frontend-unicode-identifiers-1024-2026-08-12.json)
- [raw Unicode 2K report](exact-parent-frontend-unicode-identifiers-2048-2026-08-12.md) · [raw JSON](exact-parent-frontend-unicode-identifiers-2048-2026-08-12.json)
- [raw Unicode 4K report](exact-parent-frontend-unicode-identifiers-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-unicode-identifiers-4096-2026-08-12.json)
- [ASCII 4K control report](exact-parent-frontend-unicode-identifiers-ascii-control-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-unicode-identifiers-ascii-control-4096-2026-08-12.json)
- [escaped-ASCII 4K control report](exact-parent-frontend-unicode-identifiers-escaped-control-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-unicode-identifiers-escaped-control-4096-2026-08-12.json)
