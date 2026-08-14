# Module single-tokenization exact-parent evidence — 2026-08-13

Diagnostic exact-parent evidence for [#553](https://github.com/zig-utils/zig-js/issues/553), comparing benchmark parent `1240045a7d5f4f7fe2e7a9d99d220b5984102629` with implementation `78dbd220f160d43b668d26a4457dea8de30a6486`. Both ReleaseFast runners use the same committed parser-only workloads and independently validate every module specifier, imported/local/exported name and order, AST node kind, declaration and initializer, entry cardinality, source-location marker, and checksum. Raw artifacts retain workload/binary hashes, dependency revisions, Zig `0.17.0-dev.1441+d5181a9c9`, macOS 27.0, and the 11-core Apple M3 Pro host.

Each row contains seven order-balanced fresh-process pairs with no discarded samples. A sample runs 200 parser-only jobs after ten 20-job warmups. Source construction is outside the timed boundary; lexing, parsing, AST construction, module early errors, source locations, and exact validation remain inside it. Allocation counters are an untimed identical-work replay.

| module entries | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate | peak RSS parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 97.356 ms → 63.060 ms | 0.648x | 2,122,915,279 → 1,409,815,551 | 0.6641x | 18,400 → 14,600 | 665,972,800 → 456,219,200 | 9,846,784 → 8,945,664 |
| 2,048 | 215.212 ms → 134.458 ms | 0.625x | 4,280,388,495 → 2,830,994,458 | 0.6614x | 20,400 → 16,200 | 1,305,972,800 → 771,844,800 | 13,582,336 → 11,436,032 |
| 4,096 | 502.327 ms → 316.135 ms | 0.629x | 8,776,804,818 → 5,753,759,501 | 0.6556x | 22,200 → 17,600 | 3,697,497,600 → 1,927,113,600 | 23,756,800 → 16,547,840 |

The Script-goal lexer now records the first Annex B HTML-like comment it accepts. Module parsing rejects that exact offset before consuming the existing token stream, preserving Module lexical-goal behavior without discarding a complete attacker-proportional Script token list and scanning the source again. Script HTML-comment handling is unchanged.

Stable retired instructions fall 33.6%, 33.9%, and 34.4%. Deterministic allocation requests fall 20.7%, 20.6%, and 20.7%; allocated bytes fall 31.5%, 40.9%, and 47.9% as the removed token capacity grows. Peak RSS falls 9.1%, 15.8%, and 30.3%. The 1K wall row is stable and improves 35.2%. Both 2K wall variants exceed 13% RSD and the 4K parent exceeds 17% RSD, so those wall medians remain diagnostic only. Every thermal boundary is nominal. These artifacts use the `diagnostic` host classification, so stable rows remain causal evidence rather than quiet-reference publication claims.

Correctness gates on the exact implementation include 1,623 full unit passes plus one expected skip with zero failures/leaks; the focused frontend suite in Debug and TSan; and exact-parent test262 comparisons for module-code, import, `import.meta`, and Annex B comments, totaling `756 → 756` with zero failures or flips.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-modules-1024-2026-08-13.md) · [raw JSON](exact-parent-frontend-modules-1024-2026-08-13.json)
- [2K report](exact-parent-frontend-modules-2048-2026-08-13.md) · [raw JSON](exact-parent-frontend-modules-2048-2026-08-13.json)
- [4K report](exact-parent-frontend-modules-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-modules-4096-2026-08-13.json)
