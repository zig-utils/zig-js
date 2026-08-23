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

- 1024: `exact-parent-tdz-clear-1024-2026-08-23.json` (file SHA-256 `f3d1cdd910f266969ab46cad77285b8e86018b4d81d2072c73b0a45db25fe2dc`; embedded SHA-256 `1378500df2201adfa6d8baabaa1bf9d083f48cd7b19d8ef40f2496774c58db1c`)
- 2048: `exact-parent-tdz-clear-2048-2026-08-23.json` (file SHA-256 `47a860d51e7e2b0fc4eeb9e486616304b6a90e77d8ce83713c3cbe3b1de14ab1`; embedded SHA-256 `8a194e4d33a1c9c51410bfa73ec727cf51ec1f97581d74aca5a4c65f08c0b7e9`)
- 4096: `exact-parent-tdz-clear-4096-2026-08-23.json` (file SHA-256 `37bbb175176bd6d832c753696907f8fbecf0160ebfb0602fd0e3862ebf627227`; embedded SHA-256 `8632937f694fab8ba45740fc9987dfdaec587c7fbdab169b820d15ebb10544da`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 63%; charging; (no estimate) present: true`, `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 75%; charging; (no estimate) present: true`, `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 79%; charging; (no estimate) present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated TDZ-clear source; process startup, twenty warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns`.
