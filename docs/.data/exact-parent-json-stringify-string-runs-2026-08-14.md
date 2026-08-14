# JSON.stringify ordinary string runs — exact-parent evidence (2026-08-14)

Order-balanced exact-parent diagnostic for [#557](https://github.com/zig-utils/zig-js/issues/557).

- parent: `9897268879745600b8e6c7799ca2765ddd0cc40d`
- candidate: `a7da43f4121c449ffebc8f0e325ed885f6fa83c4`
- source: `bench/representative_comparison.js`
- host: Apple M3 Pro, macOS 27.0.0, arm64
- Zig: `0.17.0-dev.1441+d5181a9c9`
- power: battery power, continuously discharging from 64% to 62%; no AC-powered sample is mixed into the set
- thermal: every sample recorded `nominal->nominal`
- sampling: seven alternating fresh-process pairs per row, 98 processes total, no discarded samples
- mode/jobs: `single`, one scored job after ten one-job warmups
- identity: every runner, source, dependency, mode, job, output probe, and checksum identity matched

| workload | parent wall | candidate wall | wall ratio | median process CPU parent -> candidate | parent instructions | candidate instructions | instruction ratio | candidate / parent peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| plain ASCII 4,096 bytes | 0.176 ms | 0.269 ms | 1.530x | 0 -> 0 ms | 2,269,822 | 2,183,423 | 0.9619x | 0.9972x |
| plain ASCII 16,384 bytes | 0.503 ms | 0.495 ms | 0.984x | 10 -> 10 ms | 8,160,194 | 7,800,918 | 0.9560x | 0.9926x |
| plain ASCII 65,536 bytes | 1.697 ms | 1.612 ms | 0.950x | 20 -> 20 ms | 31,843,472 | 30,458,217 | 0.9565x | 0.9867x |
| valid multibyte Unicode, 4,096 motifs | 1.759 ms | 1.717 ms | 0.976x | 20 -> 20 ms | 30,035,587 | 29,152,874 | 0.9706x | 0.9882x |
| 65,536 ordinary bytes + 16 mixed escape clusters | 1.600 ms | 1.551 ms | 0.970x | 20 -> 20 ms | 32,109,069 | 30,745,508 | 0.9575x | 0.9929x |
| separated lone surrogates, 4,096 code units | 0.394 ms | 0.365 ms | 0.927x | 10 -> 0 ms | 6,902,153 | 6,972,789 | 1.0102x | 1.0028x |
| short plain-string control | 0.040 ms | 0.033 ms | 0.822x | 0 -> 0 ms | 306,784 | 268,643 | 0.8757x | 1.0000x |

The three plain-width rows retain identical complete output identities while
retired instructions improve by `3.81%`, `4.40%`, and `4.35%`. The 65,536-byte
sparse-escape row improves by `4.25%`, showing that sixteen real escape clusters
do not erase the benefit of bulk-appending the ordinary spans between them.
Valid multibyte Unicode improves by `2.94%` with its bytes preserved verbatim.

The lone-surrogate control exercises the required lowercase `\\u` path rather
than a long safe run. Its `1.0102x` instruction ratio and `1.0028x` peak-RSS
ratio are neutral and below the repository's 10% material-regression threshold.
The short control has high relative timing and instruction dispersion because
the scored boundary is only tens of microseconds; it shows no regression, but
its apparent improvement is not used as a performance claim.

Wall values remain diagnostic: the 4,096-byte and short rows are dominated by
sub-millisecond noise, and the host was on battery power. Retired instructions
are the causal decision metric; their RSD is below 3% on every substantive row
and below 0.4% on the Unicode, sparse-escape, and lone-surrogate rows. Process
CPU retains `/usr/bin/time -l`'s 10 ms granularity. Peak RSS remains within
1.33% of the parent in every row. Cycles, energy availability, thermal state,
and complete dispersion are retained in each raw artifact; no unavailable
counter is represented as a measured zero.

## Row artifacts

- [plain 4,096 report](exact-parent-json-stringify-string-runs-plain-4096-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-plain-4096-2026-08-14.json)
- [plain 16,384 report](exact-parent-json-stringify-string-runs-plain-16384-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-plain-16384-2026-08-14.json)
- [plain 65,536 report](exact-parent-json-stringify-string-runs-plain-65536-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-plain-65536-2026-08-14.json)
- [valid Unicode report](exact-parent-json-stringify-string-runs-unicode-4096-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-unicode-4096-2026-08-14.json)
- [sparse mixed-escape report](exact-parent-json-stringify-string-runs-sparse-escapes-65536-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-sparse-escapes-65536-2026-08-14.json)
- [lone-surrogate control](exact-parent-json-stringify-string-runs-lone-surrogates-4096-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-lone-surrogates-4096-2026-08-14.json)
- [short-string control](exact-parent-json-stringify-string-runs-short-control-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-string-runs-short-control-2026-08-14.json)
