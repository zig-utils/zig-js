# Exact-parent performance A/B — representative_json_stringify_plain_4096 (single, 1 lane(s))

- parent: `9897268879745600b8e6c7799ca2765ddd0cc40d`
- candidate: `a7da43f4121c449ffebc8f0e325ed885f6fa83c4`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt 4096-byte plain ASCII string after ten one-job warmups; exact length and fixed beginning/middle/end probes validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.176 ms | 0.269 ms | 1.530x | 36.19% | 34.08% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 17383424 | 17334272 | 0.9972x | 0.17% | 0.18% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2269822 | 2183423 | 0.9619x | 2.58% | 1.21% |
| `cycles` | 666639 | 746884 | 1.1204x | 21.93% | 22.94% |
| `energy_joules` | 0 | 0 | NaNx | 173.93% | 131.45% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
