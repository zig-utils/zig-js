# Exact-parent algorithmic growth — representative_string_utf16_astral_<width>

- parent: `5bca24a359b2b571010547bdf096b3321f8d22d7`
- candidate: `c65729e5db60041ef68bf0bc7ae5f3d880a368f7`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- Zig: `0.17.0-dev.1441+d5181a9c9`
- host: arm64; Apple M3 Pro
- OS: Darwin Chris-MacBook 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11 22:03:57 PDT 2026; root:xnu-13432.1.9~3/RELEASE_ARM64_T6030 arm64 arm Darwin
- host class: `diagnostic`
- widths: 1024, 2048, 4096; 2 order-balanced pairs per width; no samples discarded
- scored boundary: Only normalized retired instructions and exact allocation replay are scored across frozen input widths. Wall time, CPU time, RSS, cycles, energy, and thermal observations are retained from the embedded exact-parent artifacts as diagnostics and cannot support a throughput, latency, energy, or full-efficiency claim.

This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.

| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1024 | 10 | 1746666082 | 296785999.20 | 0.00% | 33330059.50 | 0.00% | 0.1123x | 17636.60 / 17637 | 2507950.60 / 2507984.20 | diagnostic_only |
| 2048 | 10 | 3532868194 | 1137136641.45 | 0.00% | 69069947.70 | 0.00% | 0.0607x | 34021.40 / 34021.80 | 4268260.20 / 4268319.40 | diagnostic_only |
| 4096 | 10 | 7231101538 | 4435336983.50 | 0.00% | 134546004.65 | 0.00% | 0.0303x | 66789.50 / 66789.90 | 7847295.60 / 7847406 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.8315x | 1.938 | 2.0723x | 1.051 |
| 2048 → 4096 | 2.00x | 3.9004x | 1.964 | 1.9480x | 0.962 |

First→last (1024→4096) instruction growth: parent 14.9446x (exponent 1.951), candidate 4.0368x (exponent 1.007).

## Embedded source artifacts

- 1024: `exact-parent-string-indexing-astral-1024-2026-08-26.json` (file SHA-256 `297d7bdecc5e7abcd830a86989dc6836a8f8553fc97cfb7bbc479cc09efd1363`; embedded SHA-256 `6804953a195c81738032a66388c08417bb7bdc59ab289d30ae89144077e0b871`)
- 2048: `exact-parent-string-indexing-astral-2048-2026-08-26.json` (file SHA-256 `ba361b42b11fefc88ac30c2dba1d317cdbc93d7107f69badf133fbd704dbeffd`; embedded SHA-256 `c0d1601122723b613a45b4ef7ab223d7f869ad7c815abb0649475ea455888221`)
- 4096: `exact-parent-string-indexing-astral-4096-2026-08-26.json` (file SHA-256 `c2d8b42bae1f00cabb6ede90f3aecb1b7076906a500de447e77fd744a56404e4`; embedded SHA-256 `dd3687df2477f0f81a4c32dad38adbc5a8b92983b9ecc615eba16272648ef99e`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.`.
