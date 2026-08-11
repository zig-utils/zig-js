# Exact-parent performance A/B — representative_array_dense_control_4096 (single, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 15 order-balanced pairs; no discarded samples
- timed boundary: prebuilt dense 4,096-element Array fast-path control; one scored 100-job traversal

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 533.742 ms | 559.534 ms | 1.048x | 9.91% | 25.97% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 128778240 | 117604352 | 0.9132x | 18.06% | 23.18% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 8514908941 | 9262117296 | 1.0878x | 2.72% | 2.85% |
| `cycles` | 1713261216 | 1788665997 | 1.0440x | 4.10% | 7.76% |
| `energy_joules` | 1.947806543 | 2.051566643 | 1.0533x | 5.06% | 4.67% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
