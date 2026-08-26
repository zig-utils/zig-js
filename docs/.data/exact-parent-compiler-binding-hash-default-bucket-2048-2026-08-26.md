# Exact-parent performance A/B — representative_frontend_compile_binding_hash_default_bucket_2048 (single, 1 lane(s))

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
| 155.480 ms | 9.095 ms | 0.058x | 0.14% | 0.55% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12189696 | 12206080 | 1.0013x | 0.00% | 0.00% |
| `allocations` | 62980 | 62980 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 54773720 | 54773960 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2672427871 | 140831058 | 0.0527x | 0.00% | 0.18% |
| `cycles` | 581211497 | 33882778.5 | 0.0583x | 0.41% | 0.07% |
| `energy_joules` | 0.5270577365 | 0 | 0.0000x | 1.44% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
