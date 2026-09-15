# Exact-parent performance A/B — representative_frontend_templates_tagged_4096 (single, 1 lane(s))

- logical parent: `bff189afd18a122ad0b6c5919b45e684fa92c0fc`
- logical candidate: `261981c53b904158e0b2fdc090500fad9a4dacdf`
- binary provenance: `direct`
- parent binary revision: `bff189afd18a122ad0b6c5919b45e684fa92c0fc`
- candidate binary revision: `261981c53b904158e0b2fdc090500fad9a4dacdf`
- shared measurement overlay: none (direct builds)
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3`
- zig-regex: `c60344dec54f71efe885c62a02e29dfd7ab0f5c0`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: Complete parse and AST-shape validation in a fresh arena per job; source generation, warmup, and identical allocation replay excluded

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 826.597 ms | 854.122 ms | 1.033x | 1.95% | 3.24% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11993088 | 12468224 | 1.0396x | 3.89% | 3.08% |
| `allocations` | 16422000 | 16422000 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 3454208000 | 3454208000 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 15212552510 | 15185675466 | 0.9982x | 0.02% | 0.04% |
| `cycles` | 2760310192 | 2843587157 | 1.0302x | 0.50% | 0.68% |
| `energy_joules` | 4.062969111 | 4.158323287 | 1.0235x | 0.47% | 0.61% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
