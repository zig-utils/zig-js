# Parse-time arguments-use derivation exact-parent evidence — 2026-08-14

Diagnostic exact-parent evidence for [#555](https://github.com/zig-utils/zig-js/issues/555), comparing benchmark parent `6ce7124367ddb18d174c4381c572561515a26153` with implementation `00a401d77f9dddd4ad94f95795774b4523dd7b9b`. Both ReleaseFast runners use the same committed parser-only workloads. Every process independently validates the exact AST topology and depth, function names, retained source starts and lengths, `uses_arguments` facts, leaf behavior, source length, and checksum.

Each row contains seven order-balanced fresh-process pairs with no discarded samples. A sample prepares its source once, performs ten single-parse warmups, then scores one complete lex/parse/function-scope-metadata/AST/source-range validation job. Source construction is outside the scored wall boundary. Allocation counters are an untimed identical-work replay. Process CPU includes process startup, warmups, the scored parse, validation, and allocation replay; `/usr/bin/time` reports it at a coarse 10 ms resolution, so the raw CPU observations are preserved without a ratio claim.

| workload | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | process CPU parent → candidate | allocations | allocated bytes | peak RSS parent → candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ordinary depth 256 | 1.251 ms → 0.160 ms | 0.127x | 14,046,194 → 2,541,003 | 0.1809x | 10 ms → 0 ms | 1,568 → 1,568 | 818,080 → 818,080 | 7,618,560 → 7,618,560 |
| ordinary depth 512 | 4.747 ms → 0.284 ms | 0.060x | 51,553,060 → 5,026,272 | 0.0975x | 50 ms → 0 ms | 3,107 → 3,107 | 1,384,168 → 1,384,168 | 8,339,456 → 8,339,456 |
| ordinary depth 1,024 | 18.788 ms → 0.615 ms | 0.033x | 197,002,392 → 10,152,848 | 0.0515x | 220 ms → 0 ms | 6,182 → 6,182 | 2,862,432 → 2,862,432 | 10,567,680 → 10,600,448 |
| depth 1,024 with string/comment/identifier decoys | 6.021 ms → 1.005 ms | 0.167x | 43,290,192 → 17,454,164 | 0.4032x | 70 ms → 10 ms | 11,306 → 11,306 | 4,999,856 → 4,999,856 | 12,435,456 → 12,402,688 |
| depth 1,024 with a real innermost `arguments` use | 5.666 ms → 0.590 ms | 0.104x | 35,865,252 → 10,126,172 | 0.2823x | 60 ms → 0 ms | 6,183 → 6,183 | 2,862,512 → 2,862,512 | 10,567,680 → 10,567,680 |
| 1,024-arrow inherited-`arguments` control | 0.099 ms → 0.097 ms | 0.977x | 1,357,499 → 1,353,039 | 0.9967x | 0 ms → 0 ms | 2,078 → 2,078 | 914,264 → 914,264 | 7,995,392 → 7,995,392 |

The parent ordinary-function rows retire about 3.7–3.8× more instructions each time nesting depth doubles; the candidate rows retire about 2.0× more. At depth 1,024, removing the overlapping complete-source scans reduces retired instructions by 94.85% and the diagnostic wall median by 96.73%. The decoy and real-use rows retain the same work and checksums while reducing instructions by 59.68% and 71.77%, respectively. The arrow control changes retired instructions by only -0.33%, consistent with arrows already sharing one ordinary owner rather than producing overlapping ordinary-function source scans.

Allocation requests and allocated bytes are exactly identical between parent and candidate in all six rows, demonstrating that the parse-time scope flag introduces no tracking allocation. Median peak RSS is identical in four rows and differs by +0.31% and -0.26% in the other two.

All thermal observations are `nominal->nominal`, and instructions, cycles, process energy, process CPU, allocation requests/bytes, and peak RSS are present in every raw sample. Energy frequently falls below the process counter's resolution and is recorded as measured zero; no energy claim is made. The host was on battery and the artifacts are deliberately `diagnostic`. Candidate wall RSD is 11.29%, 11.59%, and 32.22% for the depth-1,024 base, decoy, and sub-0.1 ms arrow rows, so those wall medians are not treated as stable publication claims. Retired-instruction RSD remains at or below 0.51% for every ordinary-function row and at or below 4.92% for the arrow control, providing the stable causal growth evidence.

Correctness gates on the exact implementation include frontend Debug and TSan at 12/12 each; 1,627 full unit passes plus one expected skip with zero failures or leaks; a dedicated tree-walker/required-bytecode witness with identical result bits, one compiled template, zero arguments-policy rejections, and zero fallback; and exact-parent test262 comparisons across arguments, eval, function, arrow, class-arguments, and dynamic function-constructor subtrees totaling `2,470 → 2,470` passes with zero failures or flips.

Per-row reports and raw samples:

- [ordinary depth-256 report](exact-parent-frontend-nested-functions-256-2026-08-14.md) · [raw JSON](exact-parent-frontend-nested-functions-256-2026-08-14.json)
- [ordinary depth-512 report](exact-parent-frontend-nested-functions-512-2026-08-14.md) · [raw JSON](exact-parent-frontend-nested-functions-512-2026-08-14.json)
- [ordinary depth-1,024 report](exact-parent-frontend-nested-functions-1024-2026-08-14.md) · [raw JSON](exact-parent-frontend-nested-functions-1024-2026-08-14.json)
- [depth-1,024 decoy report](exact-parent-frontend-nested-functions-decoys-1024-2026-08-14.md) · [raw JSON](exact-parent-frontend-nested-functions-decoys-1024-2026-08-14.json)
- [depth-1,024 real-arguments report](exact-parent-frontend-nested-functions-arguments-1024-2026-08-14.md) · [raw JSON](exact-parent-frontend-nested-functions-arguments-1024-2026-08-14.json)
- [1,024-arrow inherited-arguments control report](exact-parent-frontend-nested-arrows-arguments-1024-2026-08-14.md) · [raw JSON](exact-parent-frontend-nested-arrows-arguments-1024-2026-08-14.json)
