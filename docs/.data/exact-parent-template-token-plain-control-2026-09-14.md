# Exact-parent performance A/B — representative_frontend_templates_4096 (single, 1 lane(s))

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
| 605.033 ms | 612.220 ms | 1.012x | 5.40% | 10.67% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11780096 | 11763712 | 0.9986x | 3.25% | 1.01% |
| `allocations` | 4133000 | 4133000 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2470848000 | 2470848000 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 10766460006 | 10746916043 | 0.9982x | 0.09% | 0.15% |
| `cycles` | 1968706739 | 2021693061 | 1.0269x | 1.38% | 2.45% |
| `energy_joules` | 2.801905628 | 2.892182449 | 1.0322x | 2.43% | 2.74% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
