# Exact-parent performance A/B — representative_array_like_4096 (single, 1 lane(s))

- parent: `6e519a751126fa237c8893eb37e778cd9f08a206`
- candidate: `bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 4 Array.prototype.forEach invocations over one prebuilt 4,096-element plain array-like object

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 588.190 ms | 581.754 ms | 0.989x | 0.69% | 0.55% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 34209792 | 33767424 | 0.9871x | 0.10% | 0.07% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 4459480866 | 4469833589 | 1.0023x | 0.29% | 0.29% |
| `cycles` | 2221516354 | 2189232487 | 0.9855x | 0.68% | 0.39% |
| `energy_joules` | 1.616444811 | 1.628252922 | 1.0073x | 0.95% | 1.00% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
