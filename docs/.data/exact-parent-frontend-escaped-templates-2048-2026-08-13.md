# Exact-parent performance A/B — representative_frontend_templates_escaped_2048 (single, 1 lane(s))

- parent: `67149a3ffdfac6f41225f0ec92071823193bc98f`
- candidate: `b3c8c3bad46fd2200c723c2e6b4d4f07a97f0858`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact cooked-template validation jobs over one preconstructed 2,048-quasi escaped-template source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 70.512 ms | 61.868 ms | 0.877x | 4.69% | 3.44% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9404416 | 9043968 | 0.9617x | 5.15% | 5.26% |
| `allocations` | 826000 | 826000 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 229115200 | 196125200 | 0.8560x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1335615696 | 1299941995 | 0.9733x | 0.07% | 0.06% |
| `cycles` | 243605698 | 222930585 | 0.9151x | 1.76% | 1.33% |
| `energy_joules` | 0.264019015 | 0.263288853 | 0.9972x | 3.55% | 3.62% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
