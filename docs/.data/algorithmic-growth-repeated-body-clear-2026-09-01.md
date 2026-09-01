# Exact-parent algorithmic growth — representative_frontend_compile_repeated_body_clear_<width>

- parent: `3fcd7f027954b4c9c1ed5d89f2e7a503b4a5ae91`
- candidate: `14ca5cd4588b8f40baea15eb931e3d696d3c66bc`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- Zig: `0.17.0-dev.1441+d5181a9c9`
- host: arm64; Apple M3 Pro
- OS: Darwin Chris-MacBook 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11 22:03:57 PDT 2026; root:xnu-13432.1.9~3/RELEASE_ARM64_T6030 arm64 arm Darwin
- host class: `quiet_reference`
- widths: 1024, 2048, 4096; 7 order-balanced pairs per width; no samples discarded
- scored boundary: Only normalized retired instructions and exact allocation replay are scored across frozen input widths. Wall time, CPU time, RSS, cycles, energy, and thermal observations are retained from the embedded exact-parent artifacts as diagnostics and cannot support a throughput, latency, energy, or full-efficiency claim.

This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.

| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1024 | 10 | 740669260 | 63796006.90 | 0.07% | 7576872.60 | 0.02% | 0.1188x | 3224 / 3233 | 2530094 / 2603894 | blocked_efficiency_evidence |
| 2048 | 10 | 4773359130 | 241011135.20 | 0.00% | 15307550.80 | 0.09% | 0.0635x | 6314 / 6324 | 5644262 / 5791814 | blocked_efficiency_evidence |
| 4096 | 10 | 386073430 | 935045746.70 | 0.01% | 30548079.00 | 0.04% | 0.0327x | 12474 / 12485 | 9689038 / 9984070 | pass |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.7778x | 1.918 | 2.0203x | 1.015 |
| 2048 → 4096 | 2.00x | 3.8797x | 1.956 | 1.9956x | 0.997 |

First→last (1024→4096) instruction growth: parent 14.6568x (exponent 1.937), candidate 4.0318x (exponent 1.006).

## Embedded source artifacts

- 1024: `exact-parent-repeated-body-clear-1024-2026-09-01.json` (file SHA-256 `3e3dac51a5252386284608a309f8ea8725e020d2d8415a3d0f18fb287a1238cd`; embedded SHA-256 `1dc4c955906c06276f16237fcdc0c9d44352bfdeed6af7851c9c069b8ac17f54`)
- 2048: `exact-parent-repeated-body-clear-2048-2026-09-01.json` (file SHA-256 `0e3941e4574a26f9da385d27b8eaef1bdae827ba56aca2246fb11fc27105fe25`; embedded SHA-256 `824113fd2a9a265f1a970fdae0cabe94f8e916ecaab29c2113e36e09beb92080`)
- 4096: `exact-parent-repeated-body-clear-4096-2026-09-01.json` (file SHA-256 `d2d8ad509c1624cce6b844a76b4bff9d230b3a87122e63acb8f44d405f951e31`; embedded SHA-256 `cdb4fa4e294f5988467af60b9ebe0175deb20b7bd6b51bf3b343d2a6dd0c3994`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=40239203) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated closure-free repeated-body source; process startup, two one-job warmups, hardware snapshots, and untimed identical-work allocation replay are outside elapsed_ns`.
