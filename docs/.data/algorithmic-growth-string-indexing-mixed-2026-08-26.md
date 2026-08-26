# Exact-parent algorithmic growth — representative_string_utf16_mixed_<width>

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
| 1024 | 10 | 877793102 | 313754056.60 | 0.00% | 32780307.20 | 0.00% | 0.1045x | 17636.80 / 17637.20 | 2431497.90 / 2431531.50 | diagnostic_only |
| 2048 | 10 | 1801105604 | 1204965342.25 | 0.00% | 67955028.90 | 0.00% | 0.0564x | 34021.70 / 34022.10 | 4262794.50 / 4262853.70 | diagnostic_only |
| 4096 | 10 | 3769774258 | 4706255581.45 | 0.00% | 132348290.35 | 0.01% | 0.0281x | 66789.80 / 66790.20 | 7836438.90 / 7836549.30 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.8405x | 1.941 | 2.0730x | 1.052 |
| 2048 → 4096 | 2.00x | 3.9057x | 1.966 | 1.9476x | 0.962 |

First→last (1024→4096) instruction growth: parent 14.9998x (exponent 1.953), candidate 4.0374x (exponent 1.007).

## Embedded source artifacts

- 1024: `exact-parent-string-indexing-mixed-1024-2026-08-26.json` (file SHA-256 `6df3ebd88e53e369f6dfef7fe3da8e7d6a4124c6ff0e35cfafdbeacd8bd8bace`; embedded SHA-256 `806b72a23e2adc292609ec7e2395840d19e3bcb973ef407c29d69de4381b5459`)
- 2048: `exact-parent-string-indexing-mixed-2048-2026-08-26.json` (file SHA-256 `ff15279082746e8334ae7ff37030efa8223a338e0425d9515a3d470489724625`; embedded SHA-256 `90e759c62c7ea1357bce4c6af984f4a63648fa5f76155ca39ecb4deb242a74b2`)
- 4096: `exact-parent-string-indexing-mixed-4096-2026-08-26.json` (file SHA-256 `945b5da7043869fc9f3b732d14186eff5fc1fd64919354fb2b5f05a2bbd062df`; embedded SHA-256 `e6a4f6e08f68a73628cbfb907ba66cf5b2a7e96f7f3cc122b8cab563da728475`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.`.
