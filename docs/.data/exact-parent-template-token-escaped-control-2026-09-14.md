# Exact-parent performance A/B — representative_frontend_templates_escaped_4096 (single, 1 lane(s))

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
| 745.314 ms | 823.120 ms | 1.104x | 22.09% | 26.57% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12140544 | 12173312 | 1.0027x | 1.07% | 1.36% |
| `allocations` | 8229000 | 8229000 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2670442000 | 2670442000 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 13639918290 | 13642586837 | 1.0002x | 0.47% | 0.52% |
| `cycles` | 2466922333 | 2545112814 | 1.0317x | 6.30% | 6.99% |
| `energy_joules` | 3.506852212 | 3.496914569 | 0.9972x | 6.89% | 7.81% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
