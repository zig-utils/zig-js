# Tagged-template substitution arrays exact-parent evidence — 2026-08-13

Diagnostic exact-parent evidence for [#552](https://github.com/zig-utils/zig-js/issues/552), comparing benchmark parent `efa336aa0724cbd7e85c28ebe124734c0e76279f` with implementation `c3449e6b007a13c12525c13818af0a55d423eb67`. Both ReleaseFast runners use the same committed parser-only workloads and independently validate every raw/cooked quasi, source pointer, expression node, cardinality, and checksum. Raw artifacts retain workload/binary hashes, dependency revisions, Zig `0.17.0-dev.1441+d5181a9c9`, macOS 27.0, and the 11-core Apple M3 Pro host.

Each row contains seven order-balanced fresh-process pairs with no discarded samples. A sample runs 200 parser-only jobs after ten 20-job warmups. Source construction is outside the timed boundary; lexing, nested substitution scanning, parsing, AST construction, and exact validation remain inside it. Allocation counters are an untimed identical-work replay.

| substitutions | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 31.637 ms → 31.042 ms | 0.981x | 608,513,598 → 599,886,538 | 0.9858x | 417,400 → 412,200 | 80,697,600 → 70,876,800 |
| 2,048 | 63.027 ms → 61.645 ms | 0.978x | 1,237,291,798 → 1,219,721,620 | 0.9858x | 828,200 → 821,800 | 169,572,800 → 141,328,000 |
| 4,096 | 131.400 ms → 132.740 ms | 1.010x | 2,494,483,254 → 2,461,482,634 | 0.9868x | 1,648,400 → 1,641,000 | 345,382,400 → 282,230,400 |

The lexer records top-level substitution cardinality during its already-required nested template scan. The parser therefore allocates exact N+1 cooked, N+1 raw, and N expression arrays instead of retaining three list-growth capacities. Requests fall 1.25%, 0.77%, and 0.45%; the diminishing percentage reflects the intentionally unchanged per-substitution token and AST allocations. Bytes fall 12.2%, 16.7%, and 18.3%. Stable retired instructions fall 1.4%, 1.4%, and 1.3%, with near-linear growth in both variants.

The 1K and 2K wall rows are stable and improve 1.9% and 2.2%. Both 4K wall variants exceed 12% RSD, so that median is diagnostic only. RSS and dispersed energy rows are not promoted. All thermal boundaries are nominal. These artifacts use the `diagnostic` host classification, so stable rows remain causal evidence rather than quiet-reference publication claims.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-tagged-substitutions-1024-2026-08-13.md) · [raw JSON](exact-parent-frontend-tagged-substitutions-1024-2026-08-13.json)
- [2K report](exact-parent-frontend-tagged-substitutions-2048-2026-08-13.md) · [raw JSON](exact-parent-frontend-tagged-substitutions-2048-2026-08-13.json)
- [4K report](exact-parent-frontend-tagged-substitutions-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-tagged-substitutions-4096-2026-08-13.json)
