# Exact-parent algorithmic growth — representative_string_utf16_lone_<width>

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
| 1024 | 10 | 873332912 | 210455690.90 | 0.00% | 30994406.15 | 0.01% | 0.1473x | 17636.50 / 17636.90 | 2430100 / 2430133.60 | diagnostic_only |
| 2048 | 10 | 1787501744 | 793032512.60 | 0.00% | 64414123.75 | 0.01% | 0.0812x | 34021.40 / 34021.80 | 4260091.20 / 4260150.40 | diagnostic_only |
| 4096 | 10 | 3741668528 | 3061309835.25 | 0.00% | 125319310.15 | 0.00% | 0.0409x | 66789.40 / 66789.80 | 7717855 / 7717965.40 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.7682x | 1.914 | 2.0782x | 1.055 |
| 2048 → 4096 | 2.00x | 3.8603x | 1.949 | 1.9455x | 0.960 |

First→last (1024→4096) instruction growth: parent 14.5461x (exponent 1.931), candidate 4.0433x (exponent 1.008).

## Embedded source artifacts

- 1024: `exact-parent-string-indexing-lone-1024-2026-08-26.json` (file SHA-256 `67f5f2a60664196ca8b1912fa784a32eed67d4e59ee82bca70220c4084179729`; embedded SHA-256 `7564750470a3ee9b0dade7baa551a97b562be9230a8b8b032d3bc4706e62dddf`)
- 2048: `exact-parent-string-indexing-lone-2048-2026-08-26.json` (file SHA-256 `7d977b715aac4230cf81e5be5e11dccd79e9aad0f07ea4bae7888edeed328010`; embedded SHA-256 `afc41e4253ceab35d0c81907529894b7c0aad8d09579b8d1472f7b9520c3c598`)
- 4096: `exact-parent-string-indexing-lone-4096-2026-08-26.json` (file SHA-256 `a877953fd9a734116933ac01f3bb467b4ed2ee8ad87aa46ac46535f50d179d06`; embedded SHA-256 `7ae0baef36cc6343d7a2908d46fc2f01350df62eec3deca218d747c41eddcf82`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.`.
