# Exact-parent performance A/B — representative_frontend_compile_tdz_clear_4096 (single, 1 lane(s))

- parent: `e9412de8aad3ba2b0ebb9dc4eb40b4f8e4e41d53`
- candidate: `8da47d8ed2aa7e05101026f1541f0bbcabd5cffb`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every complete process used at least 60% CPU occupancy; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated TDZ-clear source; process startup, two warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1456.847 ms | 19.234 ms | 0.013x | 16.30% | 6.51% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 16580608 | 16646144 | 1.0040x | 2.22% | 1.79% |
| `allocations` | 124650 | 124650 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 96875630 | 96875630 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 24821050958 | 283318534 | 0.0114x | 0.21% | 0.27% |
| `cycles` | 4858887352 | 67185645 | 0.0138x | 5.77% | 4.78% |
| `energy_joules` | 5.916113571 | 0.078481351 | 0.0133x | 0.72% | 23.75% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
