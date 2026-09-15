# Exact-parent performance A/B — representative_frontend_templates_tagged_substitutions_1024 (single, 1 lane(s))

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
| 197.693 ms | 201.870 ms | 1.021x | 2.78% | 1.27% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7716864 | 7028736 | 0.9108x | 1.90% | 0.40% |
| `allocations` | 2061000 | 1038000 | 0.5036x | 0.00% | 0.00% |
| `allocated_bytes` | 354384000 | 125232000 | 0.3534x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3020824039 | 2977722029 | 0.9857x | 0.05% | 0.02% |
| `cycles` | 656221549 | 670458771 | 1.0217x | 0.48% | 0.44% |
| `energy_joules` | 0.876558047 | 0.885551431 | 1.0103x | 1.86% | 1.72% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
