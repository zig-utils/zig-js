# Exact-parent performance A/B — context_no_evaluation (context_lifecycle, 1 lane(s))

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
- timed boundary: cold production Context create, no evaluation, exact destroy and finalization; no hidden warmup or pooling

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 707.827 ms | 714.596 ms | 1.010x | 1.77% | 1.38% | `pass` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 16252928 | 16400384 | 1.0091x | 1.84% | 0.72% |
| `retained_rss_bytes` | 16121856 | 16318464 | 1.0122x | 1.85% | 0.72% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 12764268351 | 12813711748 | 1.0039x | 0.03% | 0.02% |
| `cycles` | 2648792857 | 2654733397 | 1.0022x | 0.77% | 0.77% |
| `energy_joules` | 3.257392017 | 3.250003076 | 0.9977x | 0.95% | 0.53% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
