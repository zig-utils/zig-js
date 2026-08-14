# Exact-parent performance A/B — representative_json_stringify_sparse_escapes_65536 (single, 1 lane(s))

- parent: `9897268879745600b8e6c7799ca2765ddd0cc40d`
- candidate: `a7da43f4121c449ffebc8f0e325ed885f6fa83c4`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt 65536-ordinary-byte string with sixteen sparse mixed escape clusters after ten one-job warmups; exact length and fixed beginning/middle/end probes validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.600 ms | 1.551 ms | 0.970x | 0.81% | 1.97% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 18546688 | 18415616 | 0.9929x | 0.16% | 0.07% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 32109069 | 30745508 | 0.9575x | 0.16% | 0.17% |
| `cycles` | 5872244 | 5691490 | 0.9692x | 1.07% | 1.21% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | 197.74% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
