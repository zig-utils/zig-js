# Exact-parent performance A/B — representative_frontend_templates_escaped_4096 (single, 1 lane(s))

- parent: `67149a3ffdfac6f41225f0ec92071823193bc98f`
- candidate: `b3c8c3bad46fd2200c723c2e6b4d4f07a97f0858`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact cooked-template validation jobs over one preconstructed 4,096-quasi escaped-template source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 133.165 ms | 128.316 ms | 0.964x | 2.91% | 2.58% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11059200 | 10764288 | 0.9733x | 4.57% | 0.24% |
| `allocations` | 1645800 | 1645800 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 541577600 | 475819600 | 0.8786x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2681311458 | 2620530447 | 0.9773x | 0.03% | 0.03% |
| `cycles` | 480146573 | 451788773 | 0.9409x | 1.05% | 1.06% |
| `energy_joules` | 0.543938046 | 0.536812583 | 0.9869x | 2.13% | 2.24% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
