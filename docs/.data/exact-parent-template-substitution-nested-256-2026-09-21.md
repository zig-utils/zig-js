# Exact-parent performance A/B — representative_frontend_template_substitution_nested_256 (single, 1 lane(s))

- logical parent: `0837949c1db626ae271c0bd15610d981127b5fcb`
- logical candidate: `c86ea2e1a9895b4e2d490f3f523c13d119a6368b`
- binary provenance: `direct`
- parent binary revision: `0837949c1db626ae271c0bd15610d981127b5fcb`
- candidate binary revision: `c86ea2e1a9895b4e2d490f3f523c13d119a6368b`
- shared measurement overlay: none (direct builds)
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3`
- zig-regex: `73cc22d859d6d15043c640996a38b4825b90f1d6`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: parse and structurally validate one preconstructed carrier function per logical job

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 203.366 ms | 9.774 ms | 0.048x | 0.21% | 7.28% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 173457408 | 101351424 | 0.5843x | 0.01% | 0.01% |
| `allocations` | 201598 | 201346 | 0.9987x | 0.00% | 0.00% |
| `allocated_bytes` | 203834984 | 106934736 | 0.5246x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3470786961 | 233432815 | 0.0673x | 0.02% | 0.75% |
| `cycles` | 821065315 | 37916467 | 0.0462x | 0.08% | 2.87% |
| `energy_joules` | 0.886666293 | 0 | 0.0000x | 0.72% | 175.01% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
