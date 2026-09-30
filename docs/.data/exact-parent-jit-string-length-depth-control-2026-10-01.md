# Exact-parent performance A/B — representative_json_stringify_depth_4096 (single, 1 lane(s))

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
| 49.426 ms | 47.925 ms | 0.970x | 1.41% | 4.30% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 59015168 | 58851328 | 0.9972x | 0.47% | 0.60% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 538933307 | 538864841 | 0.9999x | 0.31% | 0.15% |
| `cycles` | 164758647 | 162886751 | 0.9886x | 1.28% | 1.69% |
| `energy_joules` | 0.198239624 | 0.190622949 | 0.9616x | 5.86% | 3.55% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
