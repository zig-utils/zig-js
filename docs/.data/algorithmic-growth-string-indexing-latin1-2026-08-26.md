# Exact-parent algorithmic growth — representative_string_utf16_latin1_<width>

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
| 1024 | 10 | 28538922 | 420401664.10 | 0.00% | 34574085.50 | 0.01% | 0.0822x | 17636.50 / 17636.90 | 2430100.60 / 2430134.20 | diagnostic_only |
| 2048 | 10 | 99013674 | 1630803047.70 | 0.00% | 71553499.35 | 0.00% | 0.0439x | 34021.40 / 34021.80 | 4260091.80 / 4260151 | diagnostic_only |
| 4096 | 10 | 365792298 | 6408467773.40 | 0.00% | 139588796.55 | 0.00% | 0.0218x | 66789.40 / 66789.80 | 7717855.60 / 7717966 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.8792x | 1.956 | 2.0696x | 1.049 |
| 2048 → 4096 | 2.00x | 3.9296x | 1.974 | 1.9508x | 0.964 |

First→last (1024→4096) instruction growth: parent 15.2437x (exponent 1.965), candidate 4.0374x (exponent 1.007).

## Embedded source artifacts

- 1024: `exact-parent-string-indexing-latin1-1024-2026-08-26.json` (file SHA-256 `3671df5c6e06daa69df7f17768b38dafacae6c46aca490028cb71ef427589b67`; embedded SHA-256 `12abfc74fc9b867f07dedd47dead55cc04e1b3ee8565976e0d9e3cb55bcfe6dc`)
- 2048: `exact-parent-string-indexing-latin1-2048-2026-08-26.json` (file SHA-256 `efefadc7db41a1f1afe5b95494124da47eebe5f62cf1c9726ff25584614f4403`; embedded SHA-256 `1957be829723714ec353697ab5c521c1c30bba70fb3f2ff77a69c5b0db709ba9`)
- 4096: `exact-parent-string-indexing-latin1-4096-2026-08-26.json` (file SHA-256 `ad036800f33fd36fcd8777c592c8f46ba41fb536e76e0bc704108e1329c30cab`; embedded SHA-256 `5766d243d7c8752e52fd6e8846e33e5b0f24dd79de8cafad60b750a4e9d7e4c0`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `One full-work invocation in one persistent production Context after ten one-job warmups. Fixture pattern expansion, exact-width slicing, String boxing, source/configuration, Context creation/destruction, attribution, and hardware snapshots are outside elapsed_ns. Each job performs the declared five operations once per UTF-16 code unit plus the three named boundary probes.`.
