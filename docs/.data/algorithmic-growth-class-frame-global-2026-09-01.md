# Exact-parent algorithmic growth — representative_frontend_compile_class_frame_global_<width>

- parent: `be27ecd46dbb20b1bca090a256ad5927ae84b981`
- candidate: `8bbbf402d723815b19ad3de5da4d698ac1a74cd5`
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
| 1024 | 10 | 7382786190 | 149634848.30 | 0.01% | 13866856.20 | 0.04% | 0.0927x | 9381 / 9390 | 5004418 / 5074130 | blocked_efficiency_evidence |
| 2048 | 10 | 3710796050 | 572913194.70 | 0.02% | 28412832.80 | 0.04% | 0.0496x | 18617 / 18627 | 11871578 / 12010946 | pass |
| 4096 | 10 | 8784472430 | 2236689682.60 | 0.00% | 57667284.80 | 0.06% | 0.0258x | 37067 / 37078 | 21319562 / 21598218 | blocked_efficiency_evidence |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.8287x | 1.937 | 2.0490x | 1.035 |
| 2048 → 4096 | 2.00x | 3.9041x | 1.965 | 2.0296x | 1.021 |

First→last (1024→4096) instruction growth: parent 14.9477x (exponent 1.951), candidate 4.1586x (exponent 1.028).

## Embedded source artifacts

- 1024: `exact-parent-class-frame-global-1024-2026-09-01.json` (file SHA-256 `4a6240b3eb19f848fe6f2d41d990bdd87307fe69c313661663b9f3cd69879f72`; embedded SHA-256 `73b08eff3226dc48585c981aec91bad0207654974be8dd353fe30d4aebea2ead`)
- 2048: `exact-parent-class-frame-global-2048-2026-09-01.json` (file SHA-256 `523e5b0d2d90edc3a971fd9d9237ff7567fc63a59ec55d38b1fdbf3cd1055516`; embedded SHA-256 `50f3feecc065487a7cd20ea649fba8b40d289dc7a41d49317074639bf96eb228`)
- 4096: `exact-parent-class-frame-global-4096-2026-09-01.json` (file SHA-256 `e2e3b0af7c63686ca5e3f80c0c2912f26dc09771832891ea375816843feb6b14`; embedded SHA-256 `d701e9ee49d6526c5075e7edb8f1478ded7b12ddb60b33150de6b2733a81027b`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=40239203) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated global-only deferred-class source; process startup, two one-job warmups, hardware snapshots, and untimed identical-work allocation replay are outside elapsed_ns`.
