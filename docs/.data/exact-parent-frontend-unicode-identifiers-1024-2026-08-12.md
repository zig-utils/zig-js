# Exact-parent performance A/B — representative_frontend_unicode_identifiers_1024 (single, 1 lane(s))

- parent: `b7bbea782aa5d2ef1b19a891ab18d6d188135cd1`
- candidate: `085cb6224cf135113b6dd112370a4e2aefcc0252`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parses with exact decoded-name and ordinal validation over one preconstructed 1,024-parameter raw-Unicode source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 23.570 ms | 25.577 ms | 1.085x | 4.33% | 8.91% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7929856 | 7995392 | 1.0083x | 0.65% | 0.59% |
| `allocations` | 5700 | 5700 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 69876800 | 69876800 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 404762786 | 436181836 | 1.0776x | 0.07% | 0.28% |
| `cycles` | 79873922 | 86034622 | 1.0771x | 1.87% | 4.22% |
| `energy_joules` | 0.08358978 | 0.089620874 | 1.0722x | 5.62% | 2.76% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
