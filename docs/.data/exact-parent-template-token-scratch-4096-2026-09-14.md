# Exact-parent performance A/B — representative_frontend_templates_tagged_substitutions_4096 (single, 1 lane(s))

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
| 795.730 ms | 820.790 ms | 1.031x | 9.56% | 1.40% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11206656 | 8634368 | 0.7705x | 5.38% | 2.00% |
| `allocations` | 8205000 | 4110000 | 0.5009x | 0.00% | 0.00% |
| `allocated_bytes` | 1411152000 | 493872000 | 0.3500x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 12338840841 | 12226714876 | 0.9909x | 0.06% | 0.02% |
| `cycles` | 2659045087 | 2729019029 | 1.0263x | 1.69% | 0.38% |
| `energy_joules` | 3.608155675 | 3.63163824 | 1.0065x | 1.53% | 0.73% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
