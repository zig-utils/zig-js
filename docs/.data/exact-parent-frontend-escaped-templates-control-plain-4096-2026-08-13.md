# Exact-parent performance A/B — representative_frontend_templates_4096 (single, 1 lane(s))

- parent: `67149a3ffdfac6f41225f0ec92071823193bc98f`
- candidate: `b3c8c3bad46fd2200c723c2e6b4d4f07a97f0858`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact cooked-template validation jobs over one preconstructed 4,096-quasi plain-template control source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 106.700 ms | 101.824 ms | 0.954x | 1.59% | 6.97% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10420224 | 10436608 | 1.0016x | 2.40% | 4.46% |
| `allocations` | 826600 | 826600 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 435900800 | 435900800 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2257325463 | 2097058198 | 0.9290x | 0.03% | 0.11% |
| `cycles` | 386567013 | 368666164 | 0.9537x | 0.74% | 2.72% |
| `energy_joules` | 0.446877337 | 0.428100289 | 0.9580x | 2.58% | 1.75% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
