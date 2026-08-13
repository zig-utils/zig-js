# Escaped private-name ownership exact-parent evidence — 2026-08-13

Diagnostic exact-parent evidence for [#551](https://github.com/zig-utils/zig-js/issues/551), comparing benchmark parent `d05d9942effd95d9d15c625029fcfbdec65467ee` with implementation `364149025b03d96228c22cd7818b1a52b963869b`. Both ReleaseFast runners use the same committed parser-only escaped-private-class workloads and validate every complete decoded key. Raw artifacts retain workload/binary hashes, dependency revisions, Zig `0.17.0-dev.1441+d5181a9c9`, macOS 27.0, and the 11-core Apple M3 Pro host.

Each row contains seven order-balanced fresh-process pairs with no discarded samples. A sample runs 200 parser-only jobs after ten 20-job warmups. Source construction is outside the timed boundary; lexing, Unicode escape validation/decoding, parsing, duplicate validation, AST construction, and exact member checks remain inside it. Allocation counters are an untimed identical-work replay.

| escaped private fields | wall parent → candidate | wall ratio | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 28.279 ms → 26.382 ms | 0.933x | 541,895,551 → 487,582,258 | 0.8998x | 1,033,000 → 418,600 | 246,270,000 → 214,168,000 |
| 2,048 | 65.128 ms → 61.058 ms | 0.937x | 1,083,009,891 → 973,672,827 | 0.8990x | 2,057,800 → 829,000 | 418,150,000 → 353,280,000 |
| 4,096 | 123.536 ms → 112.749 ms | 0.913x | 2,178,010,555 → 1,957,185,087 | 0.8986x | 4,106,600 → 1,649,000 | 882,820,400 → 752,414,400 |

Requests fall 59.5%, 59.7%, and 59.8% because each escaped private name now owns one complete `#`-prefixed decode list instead of retaining that list plus a second formatted token allocation and their growth operations. Bytes fall 13.0%, 15.5%, and 14.8%. Stable retired instructions fall 10.0%, 10.1%, and 10.1%, preserving near-linear growth. Stable 1K and 4K wall medians improve 6.7% and 8.7%; both 2K wall variants exceed 10% RSD, so that median remains diagnostic. RSS and dispersed energy rows are not promoted.

All thermal boundaries are nominal. These artifacts use the `diagnostic` host classification, so stable rows are causal evidence rather than quiet-reference publication claims.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-escaped-private-names-1024-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-private-names-1024-2026-08-13.json)
- [2K report](exact-parent-frontend-escaped-private-names-2048-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-private-names-2048-2026-08-13.json)
- [4K report](exact-parent-frontend-escaped-private-names-4096-2026-08-13.md) · [raw JSON](exact-parent-frontend-escaped-private-names-4096-2026-08-13.json)
