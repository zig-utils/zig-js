# Exact-parent performance A/B — representative_frontend_compile_tdz_clear_2048 (single, 1 lane(s))

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
| 320.295 ms | 8.240 ms | 0.026x | 0.98% | 4.88% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12058624 | 12075008 | 1.0014x | 3.05% | 3.16% |
| `allocations` | 63050 | 63050 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 56427870 | 56427870 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6208910652 | 142212198 | 0.0229x | 0.02% | 0.32% |
| `cycles` | 1142927102 | 29842167 | 0.0261x | 0.57% | 3.86% |
| `energy_joules` | 1.404378406 | 0 | 0.0000x | 1.11% | 180.17% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
