# Exact-parent algorithmic growth — representative_string_utf16_bmp_<width>

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
| 1024 | 10 | 461463722 | 454163775.75 | 0.00% | 35233221.15 | 0.01% | 0.0776x | 17636.60 / 17637 | 2506002.30 / 2506035.90 | diagnostic_only |
| 2048 | 10 | 964307114 | 1765515919.30 | 0.00% | 72903794.95 | 0.00% | 0.0413x | 34021.40 / 34021.80 | 4264314.30 / 4264373.50 | diagnostic_only |
| 4096 | 10 | 2095823018 | 6946256077.50 | 0.00% | 142176698.30 | 0.01% | 0.0205x | 66789.50 / 66789.90 | 7839521.10 / 7839631.50 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.8874x | 1.959 | 2.0692x | 1.049 |
| 2048 → 4096 | 2.00x | 3.9344x | 1.976 | 1.9502x | 0.964 |

First→last (1024→4096) instruction growth: parent 15.2946x (exponent 1.967), candidate 4.0353x (exponent 1.006).

## Embedded source artifacts

- 1024: `exact-parent-string-indexing-bmp-1024-2026-08-26.json` (file SHA-256 `dffa971a3cdfce5192821e4528d4a13a3ed06008f82123113e53236322905e40`; embedded SHA-256 `7c8f5f26ed618158ee7ad53f6a1629fd6cf67ecef6fe31a5162a98da907a1a20`)
- 2048: `exact-parent-string-indexing-bmp-2048-2026-08-26.json` (file SHA-256 `19d2f107a498b95d2fc0cd24d8d3d6d782ecdf8aee4bfe313945f2f18a24b450`; embedded SHA-256 `57ada6bbe5430e12de5ac65f00b01cd664bd836dc6919e7c211b9f8bf2d7be48`)
- 4096: `exact-parent-string-indexing-bmp-4096-2026-08-26.json` (file SHA-256 `74572441318e1fb5557b8aace635f426f11c66fd66a01284a51878ac47921116`; embedded SHA-256 `1f250036b96c5aedc35d106006279ad9750866880bed3c6fb3e9a5f9b44f7608`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.`.
