# Exact-parent performance A/B — representative_intl_date_time_format_resolved_hour_cycle (single, 1 lane(s))

- logical parent: `dcee39153fcb8ff7ebec7a28f3a26027c2d5bec9`
- logical candidate: `66c150fd0afe8806380a6d295e8ab3cca9b7da61`
- allocation replay signature: `zig-js-allocation-replay-signature-v1:representative_intl_date_time_format_resolved_hour_cycle` from `docs/.data/allocation-replay-signature-intl-date-time-format-hour-cycle-v1.json` (`c3e60e497bcb022ff96a0e160938f9f057c4b010b7b8248f9d8fc22d7b41aa34`)
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: warmed persistent Context; one exact 100-job invocation producing 12,800 fresh resolvedOptions results

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 498.286 ms | 489.356 ms | 0.982x | 2.81% | 1.44% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 87425024 | 87490560 | 1.0007x | 0.05% | 0.08% |
| `allocations` | 1428928 | 1417728 | 0.9922x | 0.00% | 0.00% |
| `allocated_bytes` | 209090873 | 209057273 | 0.9998x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 9076937979 | 9070521609 | 0.9993x | 0.03% | 0.01% |
| `cycles` | 1804504155 | 1778068104 | 0.9853x | 1.07% | 0.35% |
| `energy_joules` | 2.355796902 | 2.333874701 | 0.9907x | 0.82% | 0.80% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
