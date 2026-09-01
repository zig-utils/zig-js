# Exact-parent performance A/B — representative_vm_arithmetic_bigint (single_no_jit, 1 lane(s))

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
| 1513.581 ms | 1502.853 ms | 0.993x | 5.96% | 12.98% | `inconclusive_noise` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 320700416 | 320782336 | 1.0003x | 0.01% | 0.01% |
| `allocations` | 34012294 | 34012294 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 5327543122 | 5327542822 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 29524571165 | 29581236541 | 1.0019x | 0.01% | 0.04% |
| `cycles` | 5594832151 | 5589338358 | 0.9990x | 1.73% | 2.69% |
| `energy_joules` | 7.205129825 | 7.224952366 | 1.0028x | 0.16% | 1.31% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
