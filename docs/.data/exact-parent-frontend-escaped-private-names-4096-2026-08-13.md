# Exact-parent performance A/B — representative_frontend_private_names_escaped_4096 (single, 1 lane(s))

- parent: `d05d9942effd95d9d15c625029fcfbdec65467ee`
- candidate: `364149025b03d96228c22cd7818b1a52b963869b`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-private-key validation jobs over one preconstructed 4,096-field escaped-private-class source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 123.536 ms | 112.749 ms | 0.913x | 3.62% | 2.26% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12582912 | 12468224 | 0.9909x | 6.44% | 6.35% |
| `allocations` | 4106600 | 1649000 | 0.4015x | 0.00% | 0.00% |
| `allocated_bytes` | 882820400 | 752414400 | 0.8523x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2178010555 | 1957185087 | 0.8986x | 0.05% | 0.04% |
| `cycles` | 437440051 | 402096073 | 0.9192x | 1.80% | 1.23% |
| `energy_joules` | 0.540295127 | 0.492602737 | 0.9117x | 2.22% | 1.84% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
