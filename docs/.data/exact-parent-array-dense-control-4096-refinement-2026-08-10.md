# Exact-parent performance A/B — representative_array_dense_control_4096 (single, 1 lane(s))

- parent: `6e519a751126fa237c8893eb37e778cd9f08a206`
- candidate: `bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 15 order-balanced pairs; no discarded samples
- timed boundary: 100 Array.prototype.forEach invocations over one prebuilt dense 4,096-element Array control

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 385.487 ms | 385.964 ms | 1.001x | 3.15% | 4.29% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 142147584 | 142131200 | 0.9999x | 0.02% | 0.02% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 8421679178 | 8488780480 | 1.0080x | 2.88% | 3.85% |
| `cycles` | 1439778066 | 1444448733 | 1.0032x | 3.23% | 4.26% |
| `energy_joules` | 1.940294569 | 1.929111948 | 0.9942x | 2.61% | 3.00% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
