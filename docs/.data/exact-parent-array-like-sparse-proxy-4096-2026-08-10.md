# Exact-parent performance A/B — representative_array_like_sparse_proxy_4096 (single, 1 lane(s))

- parent: `6e519a751126fa237c8893eb37e778cd9f08a206`
- candidate: `bbe18b9dcda051dc013d58635b3f2e8dfd12ca28`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 6 Array.prototype.forEach invocations over one prebuilt sparse 4,096-length Proxy array-like object

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 541.296 ms | 554.107 ms | 1.024x | 1.32% | 2.17% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 45891584 | 45105152 | 0.9829x | 0.05% | 0.11% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5038721386 | 5046161559 | 1.0015x | 0.51% | 0.69% |
| `cycles` | 2009870040 | 2050147918 | 1.0200x | 0.78% | 1.00% |
| `energy_joules` | 1.652616233 | 1.678975612 | 1.0160x | 0.54% | 1.11% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
