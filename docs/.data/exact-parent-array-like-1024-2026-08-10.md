# Exact-parent performance A/B — representative_array_like_1024 (single, 1 lane(s))

- parent: `6e519a751126fa237c8893eb37e778cd9f08a206`
- candidate: `bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 100 Array.prototype.forEach invocations over one prebuilt 1,024-element plain array-like object

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 434.054 ms | 435.048 ms | 1.002x | 1.30% | 1.53% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 55115776 | 53477376 | 0.9703x | 0.04% | 0.08% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 8740867041 | 8711188817 | 0.9966x | 0.28% | 0.51% |
| `cycles` | 1557214657 | 1543458210 | 0.9912x | 0.65% | 1.02% |
| `energy_joules` | 1.907618252 | 1.887515788 | 0.9895x | 0.71% | 0.74% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
