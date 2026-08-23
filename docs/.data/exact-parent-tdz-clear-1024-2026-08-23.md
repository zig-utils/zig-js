# Exact-parent performance A/B — representative_frontend_compile_tdz_clear_1024 (single, 1 lane(s))

- parent: `e9412de8aad3ba2b0ebb9dc4eb40b4f8e4e41d53`
- candidate: `8da47d8ed2aa7e05101026f1541f0bbcabd5cffb`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every complete process used at least 60% CPU occupancy; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated TDZ-clear source; process startup, twenty warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 81.079 ms | 3.810 ms | 0.047x | 1.45% | 3.45% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9142272 | 9109504 | 0.9964x | 0.19% | 0.00% |
| `allocations` | 32150 | 32150 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 25286190 | 25286190 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1574673147 | 70434605 | 0.0447x | 0.11% | 1.37% |
| `cycles` | 293209118 | 13794606 | 0.0470x | 0.61% | 3.27% |
| `energy_joules` | 0.348425698 | 0 | 0.0000x | 3.36% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
