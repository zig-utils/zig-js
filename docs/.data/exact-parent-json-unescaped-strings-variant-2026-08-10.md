# Exact-parent performance A/B — representative_json_variant (single, 1 lane(s))

- parent: `e7d430f7075fc5b31352e4011d29fad21eb384bf`
- candidate: `88b5b1693aa2753fe2799057fd623b11eb725015`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 725.824 ms | 704.365 ms | 0.970x | 7.34% | 4.31% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 9924750669 | 9712350323 | 0.9786x | 0.08% | 0.08% |
| `cycles` | 2341646808 | 2308929334 | 0.9860x | 1.95% | 1.65% |
| `energy_joules` | 2.614438858 | 2.553611075 | 0.9767x | 0.99% | 0.86% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
