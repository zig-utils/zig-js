# Exact-parent performance A/B — representative_json_stringify_lone_surrogates_4096 (single, 1 lane(s))

- parent: `9897268879745600b8e6c7799ca2765ddd0cc40d`
- candidate: `a7da43f4121c449ffebc8f0e325ed885f6fa83c4`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt 4096-code-unit string containing separated lone high and low surrogates after ten one-job warmups; exact length and fixed beginning/middle/end probes validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.394 ms | 0.365 ms | 0.927x | 10.35% | 1.37% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 17481728 | 17530880 | 1.0028x | 0.15% | 0.13% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6902153 | 6972789 | 1.0102x | 0.38% | 0.21% |
| `cycles` | 1381435 | 1362276 | 0.9861x | 4.43% | 1.54% |
| `energy_joules` | 0 | 0 | NaNx | 185.01% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
