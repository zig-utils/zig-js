# Exact-parent performance A/B — representative_intl_date_time_format_resolved_hour_cycle (single, 1 lane(s))

- logical parent: `dcee39153fcb8ff7ebec7a28f3a26027c2d5bec9`
- logical candidate: `66c150fd0afe8806380a6d295e8ab3cca9b7da61`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: warmed persistent Context; one exact 100-job invocation producing 12,800 fresh resolvedOptions results

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 474.578 ms | 473.258 ms | 0.997x | 0.95% | 0.89% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 87408640 | 87343104 | 0.9993x | 0.08% | 0.07% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 9074768986 | 9070309858 | 0.9995x | 0.01% | 0.02% |
| `cycles` | 1778259008 | 1776550201 | 0.9990x | 0.46% | 0.51% |
| `energy_joules` | 2.311385772 | 2.313420489 | 1.0009x | 0.55% | 0.63% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
