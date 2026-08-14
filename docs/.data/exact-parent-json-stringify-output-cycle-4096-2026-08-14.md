# Exact-parent performance A/B — representative_json_stringify_cycle_4096 (single, 1 lane(s))

- parent: `ac9dc52bee6f44411fa377a6e2618d5458df821f`
- candidate: `3ec9847fa69afac69c321ae935ad619c99b2d72e`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-4096 object chain with a real ancestor cycle after ten one-job warmups; exact TypeError and frozen checksum validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.566 ms | 1.672 ms | 1.068x | 55.18% | 3.69% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 56639488 | 56492032 | 0.9974x | 0.20% | 0.05% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 21772891 | 22601866 | 1.0381x | 1.50% | 0.60% |
| `cycles` | 5768399 | 6229793 | 1.0800x | 28.59% | 2.83% |
| `energy_joules` | 0 | 0 | NaNx | 171.36% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
