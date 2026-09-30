# Exact-parent performance A/B — representative_json_escaped_strings (single, 1 lane(s))

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
| 48.831 ms | 48.477 ms | 0.993x | 7.23% | 4.00% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 53313536 | 53346304 | 1.0006x | 0.29% | 0.28% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 768414408 | 768339439 | 0.9999x | 0.08% | 0.20% |
| `cycles` | 163637259 | 160225066 | 0.9791x | 7.32% | 2.82% |
| `energy_joules` | 0.21282357 | 0.220941512 | 1.0381x | 4.65% | 5.71% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
