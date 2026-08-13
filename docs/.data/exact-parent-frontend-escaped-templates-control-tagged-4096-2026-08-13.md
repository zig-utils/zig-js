# Exact-parent performance A/B — representative_frontend_templates_tagged_4096 (single, 1 lane(s))

- parent: `67149a3ffdfac6f41225f0ec92071823193bc98f`
- candidate: `b3c8c3bad46fd2200c723c2e6b4d4f07a97f0858`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact raw/cooked tagged-template validation jobs over one preconstructed 4,096-quasi plain tagged-template control source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 209.501 ms | 188.505 ms | 0.900x | 62.79% | 8.68% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12353536 | 11272192 | 0.9125x | 0.29% | 0.84% |
| `allocations` | 3284400 | 3284400 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 827299200 | 617584000 | 0.7465x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3609151473 | 3362363451 | 0.9316x | 0.92% | 0.22% |
| `cycles` | 704746208 | 640575841 | 0.9089x | 19.06% | 2.38% |
| `energy_joules` | 0.773292339 | 0.726033199 | 0.9389x | 5.49% | 1.19% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
