# Exact-parent performance A/B — representative_frontend_compile_binding_inventory_unique_2048 (single, 1 lane(s))

- parent: `3bc06b01305fcd2b73973e0cc39dcf35a172c08d`
- candidate: `84efdae532e0bc9a198b3764dc9a20645bea2ed0`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every complete process used at least 60% CPU occupancy; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated source; process startup, two warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 9.677 ms | 9.158 ms | 0.946x | 3.58% | 6.48% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12255232 | 12206080 | 0.9960x | 4.01% | 3.36% |
| `allocations` | 63070 | 62970 | 0.9984x | 0.00% | 0.00% |
| `allocated_bytes` | 56431770 | 54383370 | 0.9637x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 142261690 | 133679040 | 0.9397x | 0.15% | 0.20% |
| `cycles` | 32542139 | 31405082 | 0.9651x | 2.33% | 3.13% |
| `energy_joules` | 0.031767046 | 0.034879556 | 1.0980x | 9.90% | 8.94% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
