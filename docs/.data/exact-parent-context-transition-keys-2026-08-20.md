# Exact-parent performance A/B — context_no_evaluation (context_lifecycle, 1 lane(s))

- parent: `b815b3e7f11df03b5f9f98577ff3c5093fe25c0c`
- candidate: `cb0200bc2f941993352626920fd96ca4912b789f`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every complete process used at least 60% CPU occupancy; before/after snapshots reject persistent competing jobs
- timed boundary: cold production Context create, no evaluation, exact destroy and finalization; no hidden warmup or pooling

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 883.977 ms | 702.634 ms | 0.795x | 2.39% | 1.30% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 16105472 | 16072704 | 0.9980x | 1.91% | 3.11% |
| `retained_rss_bytes` | 15990784 | 15958016 | 0.9980x | 1.92% | 3.13% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 13935980181 | 12356134984 | 0.8866x | 0.03% | 0.04% |
| `cycles` | 3260557520 | 2595550333 | 0.7960x | 1.00% | 0.63% |
| `energy_joules` | 3.808944368 | 3.209809691 | 0.8427x | 0.67% | 0.51% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
