# Exact-parent performance A/B — representative_json_reviver_source (single, 1 lane(s))

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
| 29.563 ms | 29.181 ms | 0.987x | 4.52% | 4.54% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 60899328 | 61259776 | 1.0059x | 0.39% | 0.65% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 466348654 | 466103794 | 0.9995x | 0.86% | 0.46% |
| `cycles` | 100024389 | 98707061 | 0.9868x | 4.27% | 3.53% |
| `energy_joules` | 0.144503604 | 0.139518515 | 0.9655x | 6.31% | 6.09% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
