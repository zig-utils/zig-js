# Exact-parent performance A/B — representative_array_dense_control_4096 (single, 1 lane(s))

- parent: `6e519a751126fa237c8893eb37e778cd9f08a206`
- candidate: `bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 200 Array.prototype.forEach invocations over one prebuilt dense 4,096-element Array control

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 787.832 ms | 767.772 ms | 0.975x | 7.41% | 8.55% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 260194304 | 260210688 | 1.0001x | 0.01% | 0.01% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 16596340069 | 17363356234 | 1.0462x | 6.72% | 4.30% |
| `cycles` | 2877611728 | 2895767093 | 1.0063x | 7.60% | 7.04% |
| `energy_joules` | 3.856676766 | 3.921545134 | 1.0168x | 5.74% | 3.80% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
