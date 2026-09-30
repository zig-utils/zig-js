# Exact-parent performance A/B — representative_json_variant (single, 1 lane(s))

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
| 365.022 ms | 357.797 ms | 0.980x | 3.71% | 16.73% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 109035520 | 108969984 | 0.9994x | 0.08% | 0.06% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5546914367 | 5517757801 | 0.9947x | 0.58% | 0.41% |
| `cycles` | 1219046184 | 1207833244 | 0.9908x | 2.41% | 4.80% |
| `energy_joules` | 1.740393162 | 1.69815578 | 0.9757x | 0.95% | 2.46% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
