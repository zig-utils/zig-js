# Statement-location indexing exact-parent evidence — 2026-08-14

Diagnostic exact-parent evidence for [#554](https://github.com/zig-utils/zig-js/issues/554), comparing benchmark parent `3bba3de96499a3321b14a87af7da67b9836ec5e0` with implementation `87eba6c25446d41347920ea9f92b73589fab4aa5`. Both ReleaseFast runners use the same committed parser-only workloads. Every process independently validates AST identity, statement-location order and cardinality, exact byte offsets, one-based lines and columns, source length, and checksum.

Each row contains seven order-balanced fresh-process pairs with no discarded samples. A sample prepares its source once, performs ten single-parse warmups, then scores one complete lex/parse/statement-location/AST/validation job. Source construction is outside the timed boundary; all frontend work and validation remain inside it. Allocation counters are an untimed identical-work replay.

| workload | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate | peak RSS parent → candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 sequential statements | 5.466 ms → 0.209 ms | 0.038x | 138,890,199 → 3,649,926 | 0.0263x | 2,086 → 2,087 | 917,184 → 925,384 | 7,487,488 → 7,503,872 |
| 2,048 sequential statements | 21.228 ms → 0.426 ms | 0.020x | 563,959,279 → 7,332,673 | 0.0130x | 4,139 → 4,140 | 1,434,800 → 1,451,192 | 8,142,848 → 8,175,616 |
| 4,096 sequential statements | 86.982 ms → 0.876 ms | 0.010x | 2,301,460,713 → 14,829,228 | 0.0064x | 8,240 → 8,241 | 3,438,856 → 3,471,632 | 10,141,696 → 10,207,232 |
| 4,096 mixed comments and terminators | 158.953 ms → 0.945 ms | 0.006x | 3,408,922,483 → 16,281,753 | 0.0048x | 8,240 → 8,241 | 3,438,856 → 3,471,632 | 10,256,384 → 10,305,536 |
| 1,024 nested statements | 34.476 ms → 0.430 ms | 0.012x | 882,542,236 → 7,653,114 | 0.0087x | 6,188 → 6,189 | 3,042,296 → 3,066,880 | 9,666,560 → 9,682,944 |
| 4,096-element single-statement control | 0.241 ms → 0.242 ms | 1.004x | 4,803,468 → 4,799,105 | 0.9991x | 4,133 → 4,133 | 2,470,848 → 2,470,848 | 9,060,352 → 9,076,736 |

The old path rescanned each statement's complete source prefix. Its retired instructions grow about fourfold when the sequential statement count doubles. The indexed path keeps the first two lookups allocation-free, then performs two bounded source scans to allocate and fill one exact line-start table and uses binary search thereafter. Candidate instructions grow approximately linearly across the 1K/2K/4K rows, while one allocation and 8,200/16,392/32,776 bytes account for the bounded line index.

The wide one-statement control does not build an index: allocation requests and allocated bytes are identical, instructions improve 0.09%, wall is 0.4% higher within 2.67%/3.56% RSD, and peak RSS differs by 0.18%. The repeated-statement rows reduce median wall time by 96.2% to 99.4% and retired instructions by 97.37% to 99.52%. The 1K candidate wall measurement is only 0.209 ms and has 14.55% RSD; its wall median is therefore diagnostic, while its retired-instruction row remains stable at 0.45% RSD. All other primary wall rows are at or below 3.92% RSD.

The host changed from nominal to fair before the later rows and was on battery, so these artifacts deliberately use the `diagnostic` classification. Candidate energy deltas fall below the process counter's resolution and appear as measured zero in the raw samples; no energy-ratio claim is made. Instructions, cycles, energy availability, thermal boundaries, CPU time, allocation requests/bytes, peak RSS, binary/source hashes, dependency revisions, and host/power identity remain preserved in the raw JSON.

Correctness gates on the exact implementation include frontend Debug and TSan at 12/12 each; 1,625 full unit passes plus one expected skip with zero failures/leaks; exact-parent test262 comparisons for line terminators, source text, debugger statements, and Annex B totaling `1,130 → 1,130` with zero failures or flips; and four real-corpus witnesses passing in both forced tree-walker and required-bytecode modes.

Per-row reports and raw samples:

- [1K sequential report](exact-parent-frontend-statement-locations-1024-2026-08-14.md) · [raw JSON](exact-parent-frontend-statement-locations-1024-2026-08-14.json)
- [2K sequential report](exact-parent-frontend-statement-locations-2048-2026-08-14.md) · [raw JSON](exact-parent-frontend-statement-locations-2048-2026-08-14.json)
- [4K sequential report](exact-parent-frontend-statement-locations-4096-2026-08-14.md) · [raw JSON](exact-parent-frontend-statement-locations-4096-2026-08-14.json)
- [4K mixed-terminator report](exact-parent-frontend-statement-locations-mixed-4096-2026-08-14.md) · [raw JSON](exact-parent-frontend-statement-locations-mixed-4096-2026-08-14.json)
- [1K nested report](exact-parent-frontend-statement-locations-nested-1024-2026-08-14.md) · [raw JSON](exact-parent-frontend-statement-locations-nested-1024-2026-08-14.json)
- [single-statement control report](exact-parent-frontend-statement-locations-control-single-4096-2026-08-14.md) · [raw JSON](exact-parent-frontend-statement-locations-control-single-4096-2026-08-14.json)
