# Exact-parent performance A/B — representative_frontend_private_names_escaped_1024 (single, 1 lane(s))

- parent: `d05d9942effd95d9d15c625029fcfbdec65467ee`
- candidate: `364149025b03d96228c22cd7818b1a52b963869b`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-private-key validation jobs over one preconstructed 1,024-field escaped-private-class source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 28.279 ms | 26.382 ms | 0.933x | 0.67% | 1.82% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7471104 | 7471104 | 1.0000x | 3.45% | 5.54% |
| `allocations` | 1033000 | 418600 | 0.4052x | 0.00% | 0.00% |
| `allocated_bytes` | 246270000 | 214168000 | 0.8696x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 541895551 | 487582258 | 0.8998x | 0.03% | 0.04% |
| `cycles` | 102140929 | 94773124 | 0.9279x | 0.73% | 1.53% |
| `energy_joules` | 0.111423468 | 0.106579883 | 0.9565x | 9.69% | 9.26% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
