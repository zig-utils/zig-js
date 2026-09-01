# Exact-parent performance A/B — representative_shape_transition_fanout (single, 1 lane(s))

- logical parent: `cb0200bc2f941993352626920fd96ca4912b789f`
- logical candidate: `1605a1187b9d893c0261a0cc3b9c0f7641c733b7`
- parent binary revision: `72aceae93192389abe4d227aaa36b0bfa1a8e458`
- candidate binary revision: `1b778c489dcc0b9d4b268c5de2303c1d144a4eb5`
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
| 348.249 ms | 340.216 ms | 0.977x | 2.08% | 4.41% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 119554048 | 119881728 | 1.0027x | 0.05% | 0.05% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6358585803 | 6414493107 | 1.0088x | 1.61% | 1.13% |
| `cycles` | 1279324651 | 1270425867 | 0.9930x | 1.55% | 3.04% |
| `energy_joules` | 1.549913985 | 1.548576307 | 0.9991x | 1.70% | 1.70% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
