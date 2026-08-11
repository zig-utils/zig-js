# Exact-parent performance A/B — representative_array_like_sparse_proxy_4096 (single, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: prebuilt sparse Proxy over a 4,096-property plain target; one scored six-job generic traversal

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 681.685 ms | 120.308 ms | 0.176x | 6.73% | 7.17% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 45072384 | 46039040 | 1.0214x | 11.16% | 0.11% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5067090847 | 1823640682 | 0.3599x | 0.64% | 1.03% |
| `cycles` | 2252592708 | 389066322 | 0.1727x | 3.32% | 3.67% |
| `energy_joules` | 1.754708644 | 0.441157219 | 0.2514x | 1.03% | 3.34% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
