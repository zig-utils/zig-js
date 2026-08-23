# Exact-parent performance A/B — representative_frontend_compile_binding_inventory_unique_4096 (single, 1 lane(s))

- parent: `3bc06b01305fcd2b73973e0cc39dcf35a172c08d`
- candidate: `84efdae532e0bc9a198b3764dc9a20645bea2ed0`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every complete process used at least 60% CPU occupancy; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated source; process startup, twenty warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 18.002 ms | 17.488 ms | 0.972x | 3.48% | 2.34% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 16646144 | 16252928 | 0.9764x | 0.08% | 0.29% |
| `allocations` | 124670 | 124560 | 0.9991x | 0.00% | 0.00% |
| `allocated_bytes` | 96879530 | 92782890 | 0.9577x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 283674369 | 266791518 | 0.9405x | 0.15% | 0.24% |
| `cycles` | 64573870 | 62167377 | 0.9627x | 2.98% | 1.81% |
| `energy_joules` | 0.064939276 | 0.064183595 | 0.9884x | 18.59% | 17.79% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
