# Exact-parent performance A/B — representative_frontend_templates_escaped_1024 (single, 1 lane(s))

- parent: `67149a3ffdfac6f41225f0ec92071823193bc98f`
- candidate: `b3c8c3bad46fd2200c723c2e6b4d4f07a97f0858`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact cooked-template validation jobs over one preconstructed 1,024-quasi escaped-template source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 33.503 ms | 30.704 ms | 0.916x | 1.26% | 0.81% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7454720 | 7356416 | 0.9868x | 3.30% | 2.66% |
| `allocations` | 415800 | 415800 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 151830400 | 135224400 | 0.8906x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 668511165 | 649994858 | 0.9723x | 0.02% | 0.03% |
| `cycles` | 121457683 | 112301783 | 0.9246x | 0.62% | 0.72% |
| `energy_joules` | 0.13466644 | 0.133864324 | 0.9940x | 10.92% | 6.38% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
