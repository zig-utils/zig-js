# Exact-parent performance A/B — representative_json_stringify_depth_512 (single, 1 lane(s))

- parent: `ac9dc52bee6f44411fa377a6e2618d5458df821f`
- candidate: `3ec9847fa69afac69c321ae935ad619c99b2d72e`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-512 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.845 ms | 0.374 ms | 0.442x | 15.57% | 14.30% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 61538304 | 21168128 | 0.3440x | 0.07% | 0.23% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 7781847 | 5384101 | 0.6919x | 1.38% | 1.25% |
| `cycles` | 2881109 | 1354415 | 0.4701x | 11.81% | 9.90% |
| `energy_joules` | 0.000283845 | 0 | 0.0000x | 114.58% | 160.49% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
