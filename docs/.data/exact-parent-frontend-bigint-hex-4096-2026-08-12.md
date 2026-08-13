# Exact-parent performance A/B — representative_frontend_bigint_hex_4096 (single, 1 lane(s))

- parent: `faa212516d330bceff9bf1f5bffcf93c02bbe205`
- candidate: `727d87a50a0abb65900d0ddf8fa01552263f6173`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parse-and-full-decimal-oracle-validation jobs over one preconstructed 4,096-digit hexadecimal BigInt source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1847.163 ms | 29.703 ms | 0.016x | 7.35% | 3.36% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6389760 | 6520832 | 1.0205x | 1.27% | 0.41% |
| `allocations` | 1800 | 1100 | 0.6111x | 0.00% | 0.00% |
| `allocated_bytes` | 1690100 | 949700 | 0.5619x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 11191280909 | 183268047 | 0.0164x | 0.30% | 0.16% |
| `cycles` | 6152205645 | 100225289 | 0.0163x | 0.61% | 0.75% |
| `energy_joules` | 3.69162737 | 0.063297663 | 0.0171x | 7.24% | 4.43% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
