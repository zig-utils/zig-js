# Exact-parent performance A/B — representative_json_stringify_plain_65536 (single, 1 lane(s))

- parent: `9897268879745600b8e6c7799ca2765ddd0cc40d`
- candidate: `a7da43f4121c449ffebc8f0e325ed885f6fa83c4`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt 65536-byte plain ASCII string after ten one-job warmups; exact length and fixed beginning/middle/end probes validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.697 ms | 1.612 ms | 0.950x | 3.43% | 4.34% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 18546688 | 18300928 | 0.9867x | 0.28% | 0.08% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 31843472 | 30458217 | 0.9565x | 0.09% | 0.19% |
| `cycles` | 5938129 | 5725853 | 0.9643x | 0.78% | 1.59% |
| `energy_joules` | 0.003110191 | 0.003834177 | 1.2328x | 74.29% | 93.84% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
