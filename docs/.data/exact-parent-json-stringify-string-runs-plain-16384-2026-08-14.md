# Exact-parent performance A/B — representative_json_stringify_plain_16384 (single, 1 lane(s))

- parent: `9897268879745600b8e6c7799ca2765ddd0cc40d`
- candidate: `a7da43f4121c449ffebc8f0e325ed885f6fa83c4`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt 16384-byte plain ASCII string after ten one-job warmups; exact length and fixed beginning/middle/end probes validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.503 ms | 0.495 ms | 0.984x | 53.34% | 8.74% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 17645568 | 17514496 | 0.9926x | 0.10% | 0.08% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 8160194 | 7800918 | 0.9560x | 1.41% | 0.84% |
| `cycles` | 1609038 | 1520430 | 0.9449x | 18.25% | 8.98% |
| `energy_joules` | 0 | 0 | NaNx | 232.11% | 247.31% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
