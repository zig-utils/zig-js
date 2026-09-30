# Exact-parent performance A/B — representative_json_escaped_strings (single, 1 lane(s))

- logical parent: `0efe89eda72f6a3665ee4a95547992253712c4cf`
- logical candidate: `ac67db51c988fd2a458f5b7bc44c55dbaed05d2b`
- binary provenance: `direct`
- parent binary revision: `0efe89eda72f6a3665ee4a95547992253712c4cf`
- candidate binary revision: `ac67db51c988fd2a458f5b7bc44c55dbaed05d2b`
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
| 46.816 ms | 46.416 ms | 0.991x | 3.24% | 6.05% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 53362688 | 53395456 | 1.0006x | 0.32% | 0.27% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 767987369 | 768231299 | 1.0003x | 0.08% | 0.18% |
| `cycles` | 157939405 | 157638206 | 0.9981x | 1.97% | 2.19% |
| `energy_joules` | 0.215699941 | 0.221345558 | 1.0262x | 8.60% | 4.97% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
