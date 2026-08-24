# Exact-parent algorithmic growth — representative_frontend_compile_tdz_clear_<width>

- parent: `e9412de8aad3ba2b0ebb9dc4eb40b4f8e4e41d53`
- candidate: `8da47d8ed2aa7e05101026f1541f0bbcabd5cffb`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- Zig: `0.17.0-dev.1441+d5181a9c9`
- host: arm64; Apple M3 Pro
- OS: Darwin Chris-MacBook 27.0.0 Darwin Kernel Version 27.0.0: Tue Jul 14 21:38:48 PDT 2026; root:xnu-13432.0.94.501.4~1/RELEASE_ARM64_T6030 arm64 arm Darwin
- host class: `quiet_reference`
- widths: 1024, 2048, 4096; 7 order-balanced pairs per width; no samples discarded
- scored boundary: Only normalized retired instructions and exact allocation replay are scored across frozen input widths. Wall time, CPU time, RSS, cycles, energy, and thermal observations are retained from the embedded exact-parent artifacts as diagnostics and cannot support a throughput, latency, energy, or full-efficiency claim.

This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.

| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1024 | 10 | 152135090 | 157467314.70 | 0.11% | 7043460.50 | 1.37% | 0.0447x | 3215 / 3215 | 2528619 / 2528619 | blocked_efficiency_evidence |
| 2048 | 10 | 8124090670 | 620891065.20 | 0.02% | 14221219.80 | 0.32% | 0.0229x | 6305 / 6305 | 5642787 / 5642787 | blocked_efficiency_evidence |
| 4096 | 10 | 765513290 | 2482105095.80 | 0.21% | 28331853.40 | 0.27% | 0.0114x | 12465 / 12465 | 9687563 / 9687563 | blocked_efficiency_evidence |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.9430x | 1.979 | 2.0191x | 1.014 |
| 2048 → 4096 | 2.00x | 3.9976x | 1.999 | 1.9922x | 0.994 |

First→last (1024→4096) instruction growth: parent 15.7627x (exponent 1.989), candidate 4.0224x (exponent 1.004).

## Embedded source artifacts

- 1024: `exact-parent-tdz-clear-1024-2026-08-23.json` (file SHA-256 `e359f93212aa79da5d5e0384a3ea136691b9ca0713945d9b5b9677dd6a6f2e26`; embedded SHA-256 `bd675474f3a5f17ba86fd4f9473a3e8f8d528d82a77067cbfc2d3087f32df941`)
- 2048: `exact-parent-tdz-clear-2048-2026-08-23.json` (file SHA-256 `f932425309401306d5f50c947326447f164f761ecceff2b390e94b63f42ec8d2`; embedded SHA-256 `a26101e1e71b6726a4459278055dca5b089ad14a51899b9ac5afc66c0694e1e8`)
- 4096: `exact-parent-tdz-clear-4096-2026-08-23.json` (file SHA-256 `d38b3434f8c4de7df16fe27ddda439f475299771a107a1503066ceca1048f059`; embedded SHA-256 `cf1b79d3c6998a59b17eb26ea57d44a457e706b8afdcfae14558b67974672f8a`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 63%; charging; (no estimate) present: true`, `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 75%; charging; (no estimate) present: true`, `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 79%; charging; (no estimate) present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated TDZ-clear source; process startup, two warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns`.
