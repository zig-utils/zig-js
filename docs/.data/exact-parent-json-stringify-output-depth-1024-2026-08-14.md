# Exact-parent performance A/B — representative_json_stringify_depth_1024 (single, 1 lane(s))

- parent: `ac9dc52bee6f44411fa377a6e2618d5458df821f`
- candidate: `3ec9847fa69afac69c321ae935ad619c99b2d72e`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-1024 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2.165 ms | 0.702 ms | 0.324x | 26.58% | 14.58% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 184811520 | 26116096 | 0.1413x | 0.03% | 0.12% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 19555766 | 10546423 | 0.5393x | 1.09% | 1.36% |
| `cycles` | 7627358 | 2423097 | 0.3177x | 15.33% | 9.97% |
| `energy_joules` | 0.003844953 | 0 | 0.0000x | 75.42% | 204.03% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
