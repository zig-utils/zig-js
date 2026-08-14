# Exact-parent performance A/B — representative_json_stringify_depth_4096 (single, 1 lane(s))

- parent: `ac9dc52bee6f44411fa377a6e2618d5458df821f`
- candidate: `3ec9847fa69afac69c321ae935ad619c99b2d72e`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-4096 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 33.227 ms | 2.952 ms | 0.089x | 19.74% | 8.39% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 1836728320 | 57098240 | 0.0311x | 19.35% | 0.03% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 179392635 | 42001313 | 0.2341x | 1.37% | 0.34% |
| `cycles` | 74516541 | 10426862 | 0.1399x | 5.66% | 4.22% |
| `energy_joules` | 0.058781209 | 0.004031336 | 0.0686x | 3.14% | 84.13% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
