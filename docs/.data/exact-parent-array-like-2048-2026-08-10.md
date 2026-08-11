# Exact-parent performance A/B — representative_array_like_2048 (single, 1 lane(s))

- parent: `6e519a751126fa237c8893eb37e778cd9f08a206`
- candidate: `bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 20 Array.prototype.forEach invocations over one prebuilt 2,048-element plain array-like object

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 539.106 ms | 527.360 ms | 0.978x | 1.33% | 1.67% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 36913152 | 36274176 | 0.9827x | 0.09% | 0.15% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5264399241 | 5229455948 | 0.9934x | 0.52% | 0.43% |
| `cycles` | 1929769318 | 1894506505 | 0.9817x | 2.18% | 1.21% |
| `energy_joules` | 1.621576822 | 1.588795768 | 0.9798x | 1.33% | 1.15% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
