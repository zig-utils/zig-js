# Exact-parent performance A/B — representative_json_stringify_depth_2048 (single, 1 lane(s))

- parent: `ac9dc52bee6f44411fa377a6e2618d5458df821f`
- candidate: `3ec9847fa69afac69c321ae935ad619c99b2d72e`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-2048 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 5.788 ms | 1.244 ms | 0.215x | 42.00% | 6.96% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 665190400 | 36438016 | 0.0548x | 0.01% | 0.10% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 55883794 | 21004531 | 0.3759x | 1.81% | 0.32% |
| `cycles` | 20336275 | 4611055 | 0.2267x | 7.15% | 4.00% |
| `energy_joules` | 0.015599673 | 0 | 0.0000x | 45.56% | 264.58% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
