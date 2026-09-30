# Exact-parent performance A/B — representative_json_stringify_shallow_4096 (single, 1 lane(s))

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
| 34.384 ms | 34.402 ms | 1.001x | 1.64% | 1.48% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 42942464 | 42827776 | 0.9973x | 0.20% | 0.15% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 542116827 | 542303315 | 1.0003x | 0.03% | 0.41% |
| `cycles` | 115884982 | 115638681 | 0.9979x | 0.75% | 0.67% |
| `energy_joules` | 0.143393805 | 0.147400182 | 1.0279x | 7.57% | 7.48% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
