# JIT shape-invalidation exact-parent counters — 2026-08-02

Counter-focused exact-parent diagnostic for [#471](https://github.com/zig-utils/zig-js/issues/471) under the attribution rules of [#461](https://github.com/zig-utils/zig-js/issues/461). This is not a benchmark publication: a separate Home compiler process was active on one host core, so elapsed observations are retained in the raw file but excluded from performance claims.

## Identity

- Parent: zig-js `c27c2fc96029d0fa23e163b96f54ab0baa595784`.
- Candidate: zig-js `092f34c7e05e6d3c3c8965be45a561e4f2b2cba2`; its first parent is exactly the parent above.
- zig-gc: `c89a10fc4454bfba3d28183cfa7fade08fab8aa4`.
- zig-regex: `2de46683b948ec895e5fa9a9e7e4c384aceccdfe`.
- Zig: `0.17.0-dev.1441+d5181a9c9`; `ReleaseSafe`; macOS 27.0 (26A5388g), Apple M3 Pro, 11 physical/logical CPUs, 18 GiB.
- Workload: `reference/webkit-249/threads-tests/cve/mc-val-fire-vs-link.js`, SHA-256 `3186501c0ea9809298fba1d27542409ce6d2c34c175a0551fee784c6454e375e`.
- Parent binary SHA-256: `52f6cd0a0a3e045b4f94ca9b1cb8688cb1d01950593c9915263f7a143e63e072`.
- Candidate binary SHA-256: `356d33fe50c9e0ac3a3469bd5d3d7c275a9558160985a8f8f70fa1b7413d583e`.
- Host class: `diagnostic`; seven alternating fresh-process pairs, no discarded samples.

Each process ran:

```sh
threads-test parallel-js one cve/mc-val-fire-vs-link.js
```

The case's own assertions are the result oracle. All 14 processes reported `1/1 corpus files passed`, and every process performed exactly one GC collection.

## Counters

| metric | exact parent | candidate | change |
| --- | ---: | ---: | ---: |
| passing processes | 7/7 | 7/7 | unchanged |
| optimizer publications, total | 288 | 284 | -1.4% |
| optimizer publications, median | 41 | 40 | necessary compile count restored |
| owner invalidations, total | 281 | 4 | **-98.6%** |
| owner invalidations, median | 40 | 0 | **eliminated in the median process** |
| reclaimed executable mappings, total | 281 | 4 | **-98.6%** |
| post-quiescent retired mappings, total | 0 | 0 | all retired mappings reclaimed |
| exact shape retirements | unavailable | 4 | candidate path exercised |
| survivor observations | unavailable | 67 | unaffected mappings remained published |
| precisely retired executable bytes | unavailable | 65,536 | candidate attribution |

The parent predates the precise-shape fields, so those cells are explicitly unavailable rather than zero. Its owner-wide lifecycle counters still report every reclaimed mapping. The candidate's four nonzero stops name exact shape retirements and account for the same four reclaimed mappings; it did not hide churn in a second retirement path.

## Causal chain

The checked pre-fix no-GIL inventory in [`pr249-execution-nogil.json`](pr249-execution-nogil.json) records 294,094 publications and 294,094 invalidations for one ReleaseSafe process. The earlier mutation-classification slice reduced that compile storm to the exact parent's near-necessary 40–44 publications, but still reclaimed one owner-wide mapping after almost every publication. The candidate changes only artifact lifetime and exact shape scope: across the seven paired processes it keeps the compile count at 40–43 while reducing invalidation and executable-mapping churn from 281 to 4.

This separates the two causes instead of attributing both gains to one patch:

1. mutation classification removes unnecessary recompilation after value-only stores;
2. artifact-local cells and exact shape retirement preserve unaffected native mappings through the remaining real assumption changes.

Elapsed medians were 4,327 ms for the parent and 3,399 ms for the candidate, with five of seven candidate pair wins. They are recorded only as diagnostic observations because the host was not quiet. No wall-time ratio from this run is used to accept or publish the change.

## Hosted performance guard

[Performance run 30784074991](https://github.com/zig-utils/zig-js/actions/runs/30784074991) independently exercised the full symmetric matrix after the precise-retirement series at zig-js `186083b82264ec92ca324593a89e115fe32f6a4f`. It used zig-gc `98edfaa4aa1b2676680d95801d14118f8ed84156`, zig-regex `2de46683b948ec895e5fa9a9e7e4c384aceccdfe`, Home `351dc2c59e80d077fab44247e86a893bdb262777`, Pantry action `4ad0cc7b728ba6dc295fcccf9b88240f9fe610c9`, and exact Zig `0.17.0-dev.1441+d5181a9c9`.

The clean shallow checkout passed the Home-powered comparison-harness contract, generated all 1,540 raw samples, passed the publication validator, and uploaded the raw TSV and report. The raw TSV SHA-256 is `4d007bf582dfdf7897df95d19f8dbb316a883759adec55bb2790147451a19f31`; the generated report SHA-256 is `6def88900400bf12bbf93abb5d1ba9ce1cc8d83a9a060d38f859ae8b55a28e14`; the uploaded artifact ZIP digest is `dd638bc2d9b4cb5bac0cb911eaf36f9fca6af724626a0790fcb1e048a371880a`.

The #44 semantic/performance guard remained intact in that diagnostic environment: zig-js won all 10 direct rows, all 10 eight-lane independent steady rows, and all 10 eight-lane independent cold rows. Every shared-realm workload remained above `1.0x` scaling at every multi-lane point, with `2.68x` eight-lane geometric-mean scaling. The runner was a three-CPU virtual Apple M1 host, not the documented quiet M3 Pro reference host, so its absolute timings and ratios are diagnostic and do not replace or extend the controlled publication baseline.

Raw observations: [`jit-shape-invalidation-exact-parent-2026-08-02.tsv`](jit-shape-invalidation-exact-parent-2026-08-02.tsv).
