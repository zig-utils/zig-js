# Exact-parent performance A/B — representative_json_stringify_depth_4096 (single, 1 lane(s))

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
| 48.236 ms | 47.944 ms | 0.994x | 0.70% | 1.02% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 58621952 | 58884096 | 1.0045x | 0.61% | 0.26% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 538947665 | 539226780 | 1.0005x | 0.27% | 0.27% |
| `cycles` | 162264316 | 162097993 | 0.9990x | 0.80% | 1.00% |
| `energy_joules` | 0.191724719 | 0.194898823 | 1.0166x | 4.14% | 3.29% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
