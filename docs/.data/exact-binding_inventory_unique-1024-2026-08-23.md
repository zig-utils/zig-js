# Exact-parent performance A/B — representative_frontend_compile_binding_inventory_unique_1024 (single, 1 lane(s))

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
| 3.906 ms | 3.752 ms | 0.961x | 3.42% | 2.55% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9175040 | 9109504 | 0.9929x | 0.25% | 0.19% |
| `allocations` | 32170 | 32080 | 0.9972x | 0.00% | 0.00% |
| `allocated_bytes` | 25290090 | 24265930 | 0.9595x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 70659927 | 66428176 | 0.9401x | 0.07% | 0.08% |
| `cycles` | 14037309 | 13481385 | 0.9604x | 2.58% | 2.06% |
| `energy_joules` | 0.000047357 | 0.002802295 | 59.1738x | 125.02% | 106.10% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
