# Exact-parent performance A/B — representative_vm_arithmetic_number (single_no_jit, 1 lane(s))

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
| 389.271 ms | 370.190 ms | 0.951x | 2.45% | 1.44% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 17285120 | 17334272 | 1.0028x | 0.25% | 0.10% |
| `allocations` | 12129 | 12129 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2869694 | 2869694 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 7045821659 | 6688296448 | 0.9493x | 0.01% | 0.01% |
| `cycles` | 1423065609 | 1358719572 | 0.9548x | 0.82% | 0.51% |
| `energy_joules` | 1.86093933 | 1.748557991 | 0.9396x | 1.11% | 0.80% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
