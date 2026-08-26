# Exact-parent performance A/B — representative_frontend_compile_binding_hash_default_bucket_4096 (single, 1 lane(s))

- logical parent: `2f2c8a55e9a7370ea6595e50b306ccc54ca8682c`
- logical candidate: `a3c398170325189d712520defe6287a2ce6e406f`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 2 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: Ten production parse plus plain-function admission/compile jobs over one frozen generated binding-inventory source; source construction, process startup, allocation replay, and hardware snapshots are outside elapsed_ns.

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 611.709 ms | 26.877 ms | 0.044x | 1.03% | 45.59% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 16515072 | 17178624 | 1.0402x | 0.00% | 4.11% |
| `allocations` | 124570 | 124570 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 93562360 | 93562600 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 10435860675.5 | 283066982.5 | 0.0271x | 0.01% | 0.26% |
| `cycles` | 2232605149 | 78700171.5 | 0.0353x | 0.24% | 19.17% |
| `energy_joules` | 2.067563449 | 0.052271975 | 0.0253x | 0.32% | 23.05% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
