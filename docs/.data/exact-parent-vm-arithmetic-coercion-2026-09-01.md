# Exact-parent performance A/B — representative_vm_arithmetic_coercion (single_no_jit, 1 lane(s))

- logical parent: `9333b9851f850c491a5ad1e9e794eec16044372e`
- logical candidate: `fd6747c63e328aea497017f5627dfe2d804179bb`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: warmed persistent Context; one exact 500,000-job invocation with native tiers disabled and required-bytecode admission

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 176.310 ms | 175.920 ms | 0.998x | 2.09% | 2.15% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 17317888 | 17350656 | 1.0019x | 0.20% | 0.18% |
| `allocations` | 12283 | 12283 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2880982 | 2880982 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3330527302 | 3283260789 | 0.9858x | 0.01% | 0.01% |
| `cycles` | 657746462 | 646372413 | 0.9827x | 0.55% | 0.76% |
| `energy_joules` | 0.852132164 | 0.824278462 | 0.9673x | 1.89% | 1.85% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
