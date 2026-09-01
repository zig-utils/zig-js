# Exact-parent performance A/B — representative_vm_arithmetic_polymorphic (single_no_jit, 1 lane(s))

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
| 291.309 ms | 287.219 ms | 0.986x | 1.29% | 1.57% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 32587776 | 32653312 | 1.0020x | 0.10% | 0.10% |
| `allocations` | 3012337 | 3012337 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 384800928 | 384800928 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5426950974 | 5398739746 | 0.9948x | 0.01% | 0.02% |
| `cycles` | 1073374038 | 1064201041 | 0.9915x | 0.44% | 0.86% |
| `energy_joules` | 1.40251717 | 1.398655479 | 0.9972x | 1.21% | 1.10% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
