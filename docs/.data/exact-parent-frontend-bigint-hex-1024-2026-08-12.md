# Exact-parent performance A/B — representative_frontend_bigint_hex_1024 (single, 1 lane(s))

- parent: `faa212516d330bceff9bf1f5bffcf93c02bbe205`
- candidate: `727d87a50a0abb65900d0ddf8fa01552263f6173`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parse-and-full-decimal-oracle-validation jobs over one preconstructed 1,024-digit hexadecimal BigInt source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 106.733 ms | 1.895 ms | 0.018x | 2.08% | 2.91% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6471680 | 6471680 | 1.0000x | 0.23% | 0.34% |
| `allocations` | 1500 | 1100 | 0.7333x | 0.00% | 0.00% |
| `allocated_bytes` | 585500 | 410500 | 0.7011x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 703836711 | 16097931 | 0.0229x | 0.12% | 0.20% |
| `cycles` | 380118347 | 6827861 | 0.0180x | 0.39% | 1.00% |
| `energy_joules` | 0.234481361 | 0 | 0.0000x | 3.04% | 143.05% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
