# Exact-parent performance A/B — representative_shape_transition_fanout (single, 1 lane(s))

- logical parent: `b815b3e7f11df03b5f9f98577ff3c5093fe25c0c`
- logical candidate: `cb0200bc2f941993352626920fd96ca4912b789f`
- parent binary revision: `3f7725a13ccaef4a4fb4481fefb2d727c6f856e7`
- candidate binary revision: `72aceae93192389abe4d227aaa36b0bfa1a8e458`
- shared measurement overlay: `bench/comparison_zig_js.zig`, `bench/frontend_parse.zig`, `docs/.data/algorithmic-growth-schema-v2.json`, `docs/.data/bunpress-output-v1.json`, `docs/.data/performance-attribution-schema-v2.json`, `docs/.data/representative-benchmark-matrix-v24.json`, `docs/benchmarks.md`, `tools/algorithmic-growth.ts`, `tools/exact-parent-regression.ts`, `tools/instrumentation-overhead.ts`, `tools/performance-attribution.ts`, `tools/representative-matrix.ts`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: warmed persistent Context; one exact 100,000-job invocation over prepared Shape-transition keys

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 337.674 ms | 346.949 ms | 1.027x | 1.51% | 4.91% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 121421824 | 119554048 | 0.9846x | 0.05% | 11.79% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6360367238 | 6373559422 | 1.0021x | 0.94% | 0.89% |
| `cycles` | 1258533440 | 1282413622 | 1.0190x | 1.25% | 3.14% |
| `energy_joules` | 1.511983941 | 1.535114621 | 1.0153x | 1.05% | 1.46% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
