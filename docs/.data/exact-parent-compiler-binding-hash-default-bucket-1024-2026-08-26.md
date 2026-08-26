# Exact-parent performance A/B — representative_frontend_compile_binding_hash_default_bucket_1024 (single, 1 lane(s))

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
| 41.768 ms | 4.465 ms | 0.107x | 0.14% | 1.21% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9437184 | 9404416 | 0.9965x | 0.00% | 0.00% |
| `allocations` | 32090 | 32090 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 24461720 | 24461960 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 700752937.5 | 69607925 | 0.0993x | 0.00% | 0.22% |
| `cycles` | 155841432 | 16571602.5 | 0.1063x | 0.19% | 0.99% |
| `energy_joules` | 0.129740505 | 0 | 0.0000x | 10.15% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
