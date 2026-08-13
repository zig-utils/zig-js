# Decimal BigInt canonical-storage exact-parent evidence — 2026-08-12

Diagnostic exact-parent evidence for
[#545](https://github.com/zig-utils/zig-js/issues/545), comparing benchmark
parent `04dd782e35e05d833d36c9f2a0ddc902c41dec6d` with implementation
`f91369c6fb7645beb95f01ad52e01f39d99727d3`. Both ReleaseFast runners use the
same committed parser-only workload and allocation/counter instrumentation.
The raw artifacts retain revisions and hashes for the workload source, both
binaries, zig-gc, and zig-regex.

Each row contains seven order-balanced fresh-process pairs with no discarded
samples. A sample runs 1,000 parser-only parses and validates every canonical
BigInt digit over a preconstructed source after ten 100-job warmups. Logical
allocation requests and bytes come from an untimed replay of identical work
immediately above the parser arena.

| workload | wall candidate / parent | wall RSD parent / candidate | instructions candidate / parent | allocation requests parent → candidate | allocated bytes parent → candidate | peak RSS candidate / parent |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| unseparated 1K | 0.995x | 1.86% / 2.07% | 0.9904x | 10,000 → 9,000 | 3,328,000 → 1,824,000 | 0.9975x |
| unseparated 2K | 0.979x | 1.60% / 2.01% | 0.9908x | 10,000 → 9,000 | 4,352,000 → 1,824,000 | 0.9975x |
| unseparated 4K | 1.019x | 1.27% / 0.90% | 0.9931x | 10,000 → 9,000 | 6,400,000 → 1,824,000 | 0.9949x |
| separated 4K same-value control | 0.991x | 0.30% / 0.39% | 0.9937x | 11,000 → 10,000 | 10,496,000 → 6,400,000 | 0.9924x |

Every row removes exactly one logical allocation request per parse. Unseparated
allocation bytes fall by 45.2%, 58.1%, and 71.5% at 1K, 2K, and 4K because the
canonical digit span now borrows immutable source storage. The separated 4K
control falls by 39.0% because its existing exact normalization allocation is
reused instead of copied. Its request count remains one above unseparated 4K,
matching the focused witness that separator normalization owns exactly one
allocation.

All wall medians remain within 2.1% of the parent and all peak-RSS ratios remain
below 1.0. The stable unseparated 4K result is a visible 1.9% wall increase, so
this evidence establishes allocation ownership and absence of a material wall
regression, not a throughput speedup. Energy readings remain noisy at these
durations; the artifacts are therefore diagnostic rather than quiet-reference
publication claims.

Per-row reports and raw samples:

- [unseparated 1K report](exact-parent-frontend-bigint-decimal-1024-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-decimal-1024-2026-08-12.json)
- [unseparated 2K report](exact-parent-frontend-bigint-decimal-2048-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-decimal-2048-2026-08-12.json)
- [unseparated 4K report](exact-parent-frontend-bigint-decimal-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-decimal-4096-2026-08-12.json)
- [separated 4K report](exact-parent-frontend-bigint-decimal-separated-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-decimal-separated-4096-2026-08-12.json)
