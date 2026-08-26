# Exact-parent algorithmic growth — representative_string_utf16_ascii_<width>

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
| 1024 | 10 | 23880132 | 24848903.50 | 0.02% | 25353599.00 | 0.00% | 1.0203x | 17636.50 / 17636.50 | 2425795.50 / 2425795.50 | diagnostic_only |
| 2048 | 10 | 89700804 | 52112176.45 | 0.00% | 53095048.25 | 0.00% | 1.0189x | 34021.40 / 34021.40 | 4251404.70 / 4251404.70 | diagnostic_only |
| 4096 | 10 | 347171268 | 100723784.30 | 0.00% | 102638357.25 | 0.00% | 1.0190x | 66789.40 / 66789.40 | 7700648.10 / 7700648.10 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 2.0972x | 1.068 | 2.0942x | 1.066 |
| 2048 → 4096 | 2.00x | 1.9328x | 0.951 | 1.9331x | 0.951 |

First→last (1024→4096) instruction growth: parent 4.0534x (exponent 1.010), candidate 4.0483x (exponent 1.009).

## Embedded source artifacts

- 1024: `exact-parent-string-indexing-ascii-1024-2026-08-26.json` (file SHA-256 `bbd52c75c481f27afcbaddb661e83dac55ca80d9bbfea231917188fa505b05bb`; embedded SHA-256 `49b3bb8389e7151d146a9755067bb98d750e7ceb662a41eb0a8ee45b70e6b5d1`)
- 2048: `exact-parent-string-indexing-ascii-2048-2026-08-26.json` (file SHA-256 `8147c0454c8a63c20c53b0f0b0fba5e1857209337fe0811ba099e450551a729f`; embedded SHA-256 `9dc99099db97ffa42cc44540135bee409fcc4f5d44bd6fa2bbe574286b8aa653`)
- 4096: `exact-parent-string-indexing-ascii-4096-2026-08-26.json` (file SHA-256 `87d42cc5eec5bf13042379b490441c4b6a998fd73b6c2a20440b3fcda5d5f034`; embedded SHA-256 `d2569e301a9ee6b0c42eb661066db06099f73529cffc3355b7661cf7133d1666`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.`.
