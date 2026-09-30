# Exact-parent performance A/B — representative_json_reviver_source (single, 1 lane(s))

- logical parent: `ac67db51c988fd2a458f5b7bc44c55dbaed05d2b`
- logical candidate: `8ca0d15b180ff40fa942e21821ac36ddfe4d272d`
- binary provenance: `direct`
- parent binary revision: `ac67db51c988fd2a458f5b7bc44c55dbaed05d2b`
- candidate binary revision: `8ca0d15b180ff40fa942e21821ac36ddfe4d272d`
- shared measurement overlay: none (direct builds)
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3`
- zig-regex: `fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: warmed persistent context; one exact invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 30.488 ms | 30.453 ms | 0.999x | 3.55% | 4.44% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 61652992 | 61145088 | 0.9918x | 0.52% | 0.31% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 466756388 | 467245469 | 1.0010x | 0.37% | 0.51% |
| `cycles` | 103113722 | 103149534 | 1.0003x | 2.85% | 4.05% |
| `energy_joules` | 0.146512416 | 0.143420253 | 0.9789x | 4.13% | 10.55% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
