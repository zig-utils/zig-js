# Exact-parent performance A/B — representative_frontend_bigint_hex_2048 (single, 1 lane(s))

- parent: `faa212516d330bceff9bf1f5bffcf93c02bbe205`
- candidate: `727d87a50a0abb65900d0ddf8fa01552263f6173`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parse-and-full-decimal-oracle-validation jobs over one preconstructed 2,048-digit hexadecimal BigInt source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 430.573 ms | 7.137 ms | 0.017x | 2.83% | 4.07% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6471680 | 6488064 | 1.0025x | 0.23% | 0.19% |
| `allocations` | 1600 | 1100 | 0.6875x | 0.00% | 0.00% |
| `allocated_bytes` | 807000 | 590300 | 0.7315x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2799470758 | 51572824 | 0.0184x | 0.18% | 0.19% |
| `cycles` | 1532165586 | 25454891 | 0.0166x | 0.37% | 0.99% |
| `energy_joules` | 0.934859378 | 0.015725192 | 0.0168x | 2.42% | 23.69% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
