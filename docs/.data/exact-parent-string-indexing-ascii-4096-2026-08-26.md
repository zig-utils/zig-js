# Exact-parent performance A/B — representative_string_utf16_ascii_4096 (single_no_jit, 1 lane(s))

- logical parent: `5bca24a359b2b571010547bdf096b3321f8d22d7`
- logical candidate: `c65729e5db60041ef68bf0bc7ae5f3d880a368f7`
- parent binary revision: `7d82c96e05ca32a64e8d885ae98e7a935795ab3c`
- candidate binary revision: `a5975dbb504e0d3eb9fbce1df6bc99e632e05996`
- shared measurement overlay: `bench/comparison_zig_js.zig`, `bench/frontend_parse.zig`, `docs/.data/algorithmic-growth-schema-v2.json`, `docs/.data/bunpress-output-v1.json`, `docs/.data/performance-attribution-schema-v2.json`, `docs/.data/representative-benchmark-matrix-v24.json`, `docs/benchmarks.md`, `tools/algorithmic-growth.ts`, `tools/exact-parent-regression.ts`, `tools/instrumentation-overhead.ts`, `tools/performance-attribution.ts`, `tools/representative-matrix.ts`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 2 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 50.964 ms | 51.729 ms | 1.015x | 0.61% | 1.43% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 30670848 | 30801920 | 1.0043x | 0.08% | 0.15% |
| `allocations` | 667894 | 667894 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 77006481 | 77006481 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1007237843 | 1026383572.5 | 1.0190x | 0.00% | 0.00% |
| `cycles` | 188751174.5 | 194114099 | 1.0284x | 0.25% | 1.75% |
| `energy_joules` | 0.2315734305 | 0.24838962250000002 | 1.0726x | 10.65% | 2.87% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
