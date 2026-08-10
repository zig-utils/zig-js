# Exact-parent performance A/B — representative_json (single, 1 lane(s))

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
| 700.662 ms | 705.343 ms | 1.007x | 4.00% | 16.22% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 10063155863 | 9848994731 | 0.9787x | 0.11% | 0.26% |
| `cycles` | 2336519582 | 2341694791 | 1.0022x | 1.87% | 6.60% |
| `energy_joules` | 2.684921322 | 2.580495712 | 0.9611x | 0.77% | 2.99% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
