# Representative tier attribution — zig-js-representative-v15

| family | phase | base tiers | variant tiers | base env allocations | variant env allocations |
| --- | --- | --- | --- | ---: | ---: |
| `strings_unicode` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `strings_unicode` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `regexp` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `regexp` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `json` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `json` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `map_set` | warmup | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 0 | 0 |
| `map_set` | invocation | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 0 | 0 |
| `weak_collections` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `weak_collections` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `typed_arrays_dataview` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `typed_arrays_dataview` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `classes_private_fields` | warmup | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | 300 | 300 |
| `classes_private_fields` | invocation | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | 300 | 300 |
| `iterators_generators` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1600 | 1600 |
| `iterators_generators` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1600 | 1600 |
| `proxies_accessors` | warmup | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 0 | 0 |
| `proxies_accessors` | invocation | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 0 | 0 |
| `intl` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `intl` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `mixed_long_lived_graph` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `mixed_long_lived_graph` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `application_mix` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `application_mix` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `wasm_scalar` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `wasm_scalar` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `wasm_simd` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `wasm_simd` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `wasm_memory` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `wasm_memory` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `promises_async_microtasks` | warmup | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | 120000 | 120000 |
| `promises_async_microtasks` | invocation | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | 120000 | 120000 |
| `temporal` | warmup | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `temporal` | invocation | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 |
| `modules_dynamic_import` | warmup | `vm_entries` | `vm_entries` | 0 | 0 |
| `modules_dynamic_import` | invocation | `vm_entries+baseline_entries` | `vm_entries+baseline_entries` | 3 | 3 |

## Additional workload panels

These repository-owned #460 workloads use the same complete single-context attribution inventory; they are not silently omitted from the family report.

| panel | workload | tiers | checksum |
| --- | --- | --- | ---: |
| `wasm_memory_scalar_oracle` | `wasm_representative_memory_scalar` | `vm_entries+optimizer_entries` | 96064657104 |
| `wasm_memory_shared_atomic` | `wasm_threads_representative_memory_shared` | `vm_entries+optimizer_entries+deoptimizations` | 850000 |

## Tier-up and deoptimization latency

Tier-up time starts after a successful compilation claim and ends when code publication succeeds or the attempt is rejected. Deoptimization time starts when native code returns a recoverable exit and ends after the interpreter continuation is fully reconstructed; it excludes native execution before the exit.

| family | phase | base tier-ups | variant tier-ups | base tier-up time | variant tier-up time | base deopts | variant deopts | base deopt time | variant deopt time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 1 | 1 | 109000 ns | 110916 ns | 0 | 0 | 0 ns | 0 ns |
| `strings_unicode` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `regexp` | warmup | 1 | 1 | 98583 ns | 99959 ns | 0 | 0 | 0 ns | 0 ns |
| `regexp` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `json` | warmup | 1 | 1 | 99208 ns | 98125 ns | 0 | 0 | 0 ns | 0 ns |
| `json` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `map_set` | warmup | 2 | 2 | 210416 ns | 206501 ns | 230393 | 230393 | 4829604 ns | 5075271 ns |
| `map_set` | invocation | 0 | 0 | 0 ns | 0 ns | 230400 | 230400 | 4963392 ns | 4681407 ns |
| `weak_collections` | warmup | 1 | 1 | 91750 ns | 116125 ns | 0 | 0 | 0 ns | 0 ns |
| `weak_collections` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `typed_arrays_dataview` | warmup | 1 | 1 | 96875 ns | 165916 ns | 0 | 0 | 0 ns | 0 ns |
| `typed_arrays_dataview` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `classes_private_fields` | warmup | 2 | 2 | 294458 ns | 187916 ns | 1799993 | 1799993 | 35620051 ns | 36779748 ns |
| `classes_private_fields` | invocation | 0 | 0 | 0 ns | 0 ns | 1800000 | 1800000 | 34988351 ns | 36054720 ns |
| `iterators_generators` | warmup | 1 | 1 | 118708 ns | 93084 ns | 0 | 0 | 0 ns | 0 ns |
| `iterators_generators` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `proxies_accessors` | warmup | 4 | 4 | 381501 ns | 385292 ns | 249993 | 249993 | 8440836 ns | 8389902 ns |
| `proxies_accessors` | invocation | 0 | 0 | 0 ns | 0 ns | 250000 | 250000 | 8611739 ns | 8405158 ns |
| `intl` | warmup | 1 | 1 | 91375 ns | 106833 ns | 0 | 0 | 0 ns | 0 ns |
| `intl` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `mixed_long_lived_graph` | warmup | 1 | 1 | 105042 ns | 103334 ns | 0 | 0 | 0 ns | 0 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `application_mix` | warmup | 1 | 1 | 101208 ns | 98458 ns | 0 | 0 | 0 ns | 0 ns |
| `application_mix` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_scalar` | warmup | 1 | 1 | 107583 ns | 119208 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_scalar` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_simd` | warmup | 1 | 1 | 113458 ns | 315250 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_simd` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_memory` | warmup | 1 | 1 | 101583 ns | 109917 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_memory` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `promises_async_microtasks` | warmup | 5 | 5 | 539874 ns | 489792 ns | 179922 | 179922 | 4936748 ns | 4982325 ns |
| `promises_async_microtasks` | invocation | 0 | 0 | 0 ns | 0 ns | 179943 | 179943 | 5228143 ns | 6767337 ns |
| `temporal` | warmup | 1 | 1 | 136791 ns | 129542 ns | 0 | 0 | 0 ns | 0 ns |
| `temporal` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `modules_dynamic_import` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `modules_dynamic_import` | invocation | 1 | 1 | 104333 ns | 107625 ns | 0 | 0 | 0 ns | 0 ns |

## Allocation throughput

Backing rows count successful Context allocator calls and growth bytes. GC-cell rows count logical slab/delegated cell issuance separately, so backing growth is never double-counted as a cell allocation.

| family | phase | base backing ops | variant backing ops | base backing bytes | variant backing bytes | base GC cells | variant GC cells | base GC bytes | variant GC bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 3553406 | 3553960 | 395094548 | 394514298 | 2483800 | 2484350 | 227392000 | 227427200 |
| `strings_unicode` | invocation | 3553152 | 3553724 | 404442632 | 403862436 | 2483800 | 2484350 | 227392000 | 227427200 |
| `regexp` | warmup | 2593445 | 2593066 | 189966744 | 723843104 | 1728010 | 1728010 | 138241280 | 138241280 |
| `regexp` | invocation | 2592470 | 2592140 | 210539089 | 418121817 | 1728001 | 1728001 | 138240128 | 138240128 |
| `json` | warmup | 999513 | 999375 | 980634630 | 979813860 | 1196800 | 1196800 | 127705600 | 127705600 |
| `json` | invocation | 998900 | 998869 | 1211710004 | 1210547532 | 1196800 | 1196800 | 127705600 | 127705600 |
| `map_set` | warmup | 1057564 | 1057556 | 91240598 | 91240598 | 578250 | 578250 | 52041600 | 52041600 |
| `map_set` | invocation | 1056600 | 1056600 | 84357450 | 84357450 | 578250 | 578250 | 52041600 | 52041600 |
| `weak_collections` | warmup | 50529 | 50529 | 65887624 | 65887624 | 464400 | 464400 | 59443200 | 59443200 |
| `weak_collections` | invocation | 50386 | 50386 | 61539008 | 61539008 | 464400 | 464400 | 59443200 | 59443200 |
| `typed_arrays_dataview` | warmup | 403 | 403 | 202016 | 202016 | 120 | 120 | 15360 | 15360 |
| `typed_arrays_dataview` | invocation | 452 | 452 | 294384 | 294384 | 135 | 135 | 17280 | 17280 |
| `classes_private_fields` | warmup | 1354 | 1354 | 131960 | 131960 | 450 | 450 | 96000 | 96000 |
| `classes_private_fields` | invocation | 1352 | 1352 | 198984 | 198984 | 450 | 450 | 96000 | 96000 |
| `iterators_generators` | warmup | 16144 | 16144 | 5344497 | 5344497 | 414401 | 414401 | 53555328 | 53555328 |
| `iterators_generators` | invocation | 16000 | 16000 | 1058400 | 1058400 | 414400 | 414400 | 53555200 | 53555200 |
| `proxies_accessors` | warmup | 502198 | 502198 | 8151226 | 8151226 | 500900 | 500900 | 32179200 | 32179200 |
| `proxies_accessors` | invocation | 502050 | 502050 | 3666050 | 3666050 | 500900 | 500900 | 32179200 | 32179200 |
| `intl` | warmup | 1080711 | 1080711 | 178592204 | 178592236 | 720100 | 720100 | 69129600 | 69129600 |
| `intl` | invocation | 1080151 | 1080151 | 290408271 | 290408271 | 720010 | 720010 | 69120960 | 69120960 |
| `mixed_long_lived_graph` | warmup | 61707 | 61707 | 9071176 | 9071176 | 40970 | 40970 | 5244160 | 5244160 |
| `mixed_long_lived_graph` | invocation | 6157 | 6157 | 498784 | 498784 | 4097 | 4097 | 524416 | 524416 |
| `application_mix` | warmup | 2259151 | 2258309 | 415835886 | 417064384 | 1245120 | 1244160 | 127303680 | 127242240 |
| `application_mix` | invocation | 2258903 | 2257942 | 404643046 | 405433656 | 1245120 | 1244160 | 127303680 | 127242240 |
| `wasm_scalar` | warmup | 803 | 803 | 460576 | 460576 | 0 | 0 | 0 | 0 |
| `wasm_scalar` | invocation | 800 | 800 | 460160 | 460160 | 0 | 0 | 0 | 0 |
| `wasm_simd` | warmup | 1003 | 1003 | 491616 | 491616 | 0 | 0 | 0 | 0 |
| `wasm_simd` | invocation | 1000 | 1000 | 491200 | 491200 | 0 | 0 | 0 | 0 |
| `wasm_memory` | warmup | 903 | 903 | 442496 | 442496 | 0 | 0 | 0 | 0 |
| `wasm_memory` | invocation | 900 | 900 | 442080 | 442080 | 0 | 0 | 0 | 0 |
| `promises_async_microtasks` | warmup | 5041664 | 5041911 | 825665108 | 833074824 | 3645130 | 3614914 | 940595392 | 932046464 |
| `promises_async_microtasks` | invocation | 5045819 | 5045860 | 1404864896 | 1407865216 | 3741711 | 3709865 | 962907840 | 954369280 |
| `temporal` | warmup | 193197 | 193195 | 31705656 | 31638072 | 128050 | 128050 | 16390400 | 16390400 |
| `temporal` | invocation | 193050 | 193052 | 27284400 | 27351984 | 128050 | 128050 | 16390400 | 16390400 |
| `modules_dynamic_import` | warmup | 1 | 1 | 320 | 320 | 0 | 0 | 0 | 0 |
| `modules_dynamic_import` | invocation | 381 | 381 | 2294393 | 2294372 | 37 | 37 | 8064 | 8064 |

## GC pause distribution

Each phase contains the exact completed minor/full cycle samples appended during that interval. Percentiles use the nearest-rank method; `none` means the phase completed no collection, and any sample overflow rejects the artifact.

| family | phase | base cycles | variant cycles | base p50 | variant p50 | base p95 | variant p95 | base max | variant max |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 55 | 55 | 1642250 ns | 1822292 ns | 2172291 ns | 3182583 ns | 5048709 ns | 4071166 ns |
| `strings_unicode` | invocation | 54 | 54 | 1746583 ns | 1714625 ns | 2634417 ns | 2072708 ns | 3910666 ns | 2412292 ns |
| `regexp` | warmup | 34 | 34 | 1613625 ns | 1717042 ns | 1756500 ns | 2881375 ns | 1932417 ns | 3730209 ns |
| `regexp` | invocation | 33 | 33 | 1660625 ns | 1711208 ns | 2047333 ns | 3804792 ns | 2490417 ns | 4170583 ns |
| `json` | warmup | 31 | 31 | 1113750 ns | 1069542 ns | 1556292 ns | 1273791 ns | 1928625 ns | 1440500 ns |
| `json` | invocation | 30 | 30 | 1081709 ns | 1099792 ns | 1402500 ns | 1297250 ns | 1468209 ns | 1378291 ns |
| `map_set` | warmup | 13 | 13 | 1792167 ns | 1805708 ns | 2152458 ns | 2188459 ns | 2152458 ns | 2188459 ns |
| `map_set` | invocation | 13 | 13 | 1738000 ns | 1711458 ns | 1829625 ns | 1797625 ns | 1829625 ns | 1797625 ns |
| `weak_collections` | warmup | 15 | 15 | 1035000 ns | 1039958 ns | 1504250 ns | 1325042 ns | 1504250 ns | 1325042 ns |
| `weak_collections` | invocation | 14 | 14 | 824709 ns | 765208 ns | 1120458 ns | 1645625 ns | 1120458 ns | 1645625 ns |
| `typed_arrays_dataview` | warmup | 0 | 0 | none | none | none | none | none | none |
| `typed_arrays_dataview` | invocation | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | warmup | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | invocation | 0 | 0 | none | none | none | none | none | none |
| `iterators_generators` | warmup | 13 | 13 | 827750 ns | 777167 ns | 1101583 ns | 948208 ns | 1101583 ns | 948208 ns |
| `iterators_generators` | invocation | 13 | 13 | 724458 ns | 641125 ns | 1036209 ns | 792208 ns | 1036209 ns | 792208 ns |
| `proxies_accessors` | warmup | 8 | 8 | 1416666 ns | 1522792 ns | 1748875 ns | 1942125 ns | 1748875 ns | 1942125 ns |
| `proxies_accessors` | invocation | 8 | 8 | 1418667 ns | 1426458 ns | 1508958 ns | 1483292 ns | 1508958 ns | 1483292 ns |
| `intl` | warmup | 17 | 17 | 1541750 ns | 1642292 ns | 1860208 ns | 3100291 ns | 1860208 ns | 3100291 ns |
| `intl` | invocation | 17 | 17 | 1531417 ns | 1539792 ns | 2017958 ns | 1783792 ns | 2017958 ns | 1783792 ns |
| `mixed_long_lived_graph` | warmup | 1 | 1 | 1478541 ns | 1578667 ns | 1478541 ns | 1578667 ns | 1478541 ns | 1578667 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | none | none | none | none | none | none |
| `application_mix` | warmup | 32 | 32 | 1821709 ns | 1845209 ns | 2141958 ns | 2218708 ns | 2423459 ns | 2388375 ns |
| `application_mix` | invocation | 31 | 31 | 1896625 ns | 1874708 ns | 2048625 ns | 2075583 ns | 2146959 ns | 2173833 ns |
| `wasm_scalar` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_scalar` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | invocation | 0 | 0 | none | none | none | none | none | none |
| `promises_async_microtasks` | warmup | 316 | 319 | 17912334 ns | 19127208 ns | 103854542 ns | 70003208 ns | 170234791 ns | 128771958 ns |
| `promises_async_microtasks` | invocation | 215 | 223 | 76555459 ns | 73443250 ns | 616451292 ns | 718967583 ns | 792337250 ns | 1870686000 ns |
| `temporal` | warmup | 5 | 5 | 1586292 ns | 2320417 ns | 1971209 ns | 3384584 ns | 1971209 ns | 3384584 ns |
| `temporal` | invocation | 3 | 3 | 1628625 ns | 2026916 ns | 1771375 ns | 2045209 ns | 1771375 ns | 2045209 ns |
| `modules_dynamic_import` | warmup | 0 | 0 | none | none | none | none | none | none |
| `modules_dynamic_import` | invocation | 0 | 0 | none | none | none | none | none | none |

## Runtime dispatch

Counts are exact successful or entered runtime boundaries for each phase; they are not sampled estimates.

| family | phase | base VM dispatches | variant VM dispatches | base quick kernels | variant quick kernels | base runtime ops | variant runtime ops | base host callbacks | variant host callbacks | base Wasm dispatches | variant Wasm dispatches |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 24130010 | 24482010 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `strings_unicode` | invocation | 24129635 | 24481635 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `regexp` | warmup | 17294110 | 17294130 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `regexp` | invocation | 17293645 | 17293647 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `json` | warmup | 11581210 | 11583410 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `json` | invocation | 11580835 | 11583035 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `map_set` | warmup | 16030760 | 17182760 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `map_set` | invocation | 16030385 | 17182385 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `weak_collections` | warmup | 33799610 | 34260410 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `weak_collections` | invocation | 33799235 | 34260035 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `typed_arrays_dataview` | warmup | 46224090 | 45243930 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `typed_arrays_dataview` | invocation | 52001675 | 50898995 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `classes_private_fields` | warmup | 64804310 | 70204310 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `classes_private_fields` | invocation | 64803935 | 70203935 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `iterators_generators` | warmup | 18053210 | 19282010 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `iterators_generators` | invocation | 18052835 | 19281635 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `proxies_accessors` | warmup | 13302143 | 14047893 | 0 | 0 | 1484724 | 1486044 | 0 | 0 | 0 | 0 |
| `proxies_accessors` | invocation | 13297068 | 14047419 | 0 | 0 | 1486181 | 1486073 | 0 | 0 | 0 | 0 |
| `intl` | warmup | 14786040 | 14786050 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `intl` | invocation | 14785548 | 14785549 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `mixed_long_lived_graph` | warmup | 101757690 | 101758690 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `mixed_long_lived_graph` | invocation | 100513263 | 100514263 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `application_mix` | warmup | 18266330 | 18268250 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `application_mix` | invocation | 18265955 | 18267875 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `wasm_scalar` | warmup | 4104 | 4904 | 0 | 0 | 12 | 12 | 0 | 0 | 160 | 160 |
| `wasm_scalar` | invocation | 3715 | 4515 | 0 | 0 | 4 | 4 | 0 | 0 | 160 | 160 |
| `wasm_simd` | warmup | 5024 | 6024 | 0 | 0 | 12 | 12 | 0 | 0 | 200 | 200 |
| `wasm_simd` | invocation | 4635 | 5635 | 0 | 0 | 4 | 4 | 0 | 0 | 200 | 200 |
| `wasm_memory` | warmup | 4564 | 5464 | 0 | 0 | 12 | 12 | 0 | 0 | 180 | 180 |
| `wasm_memory` | invocation | 4175 | 5075 | 0 | 0 | 4 | 4 | 0 | 0 | 180 | 180 |
| `promises_async_microtasks` | warmup | 9181412 | 9241412 | 0 | 0 | 3 | 3 | 0 | 0 | 0 | 0 |
| `promises_async_microtasks` | invocation | 9180190 | 9240190 | 0 | 0 | 1 | 1 | 0 | 0 | 0 | 0 |
| `temporal` | warmup | 1284810 | 1285460 | 0 | 0 | 6 | 6 | 0 | 0 | 0 | 0 |
| `temporal` | invocation | 1284435 | 1285085 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `modules_dynamic_import` | warmup | 13 | 13 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `modules_dynamic_import` | invocation | 13 | 13 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

## Synchronization and worker lifecycle

Phase rows are deltas from process-global opt-in counters. Single-context rows can legitimately report zero; zero is measured, not a substitute for unavailable telemetry.

| family | phase | base contentions | variant contentions | base wait | variant wait | base worker runs | variant worker runs | base worker time | variant worker time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `strings_unicode` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `regexp` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `regexp` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `json` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `json` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `map_set` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `map_set` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `weak_collections` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `weak_collections` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `typed_arrays_dataview` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `typed_arrays_dataview` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `classes_private_fields` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `classes_private_fields` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `iterators_generators` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `iterators_generators` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `proxies_accessors` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `proxies_accessors` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `intl` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `intl` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `mixed_long_lived_graph` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `application_mix` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `application_mix` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_scalar` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_scalar` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_simd` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_simd` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_memory` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_memory` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `promises_async_microtasks` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `promises_async_microtasks` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `temporal` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `temporal` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `modules_dynamic_import` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `modules_dynamic_import` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |

## Process CPU and resident memory

CPU values are exact getrusage deltas for the fresh runner process. Peak and retained RSS are Mach task_vm_info resident_size_peak/resident_size gauges captured in one phase-boundary snapshot. The invocation values are captured after the workload host checkpoint and before Context destruction.

| family | phase | base CPU | variant CPU | base peak RSS | variant peak RSS | base retained RSS | variant retained RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 1934729000 ns | 2110060000 ns | 54460416 bytes | 54427648 bytes | 54460416 bytes | 54427648 bytes |
| `strings_unicode` | invocation | 2028762000 ns | 1918728000 ns | 86032384 bytes | 85950464 bytes | 86032384 bytes | 85950464 bytes |
| `regexp` | warmup | 562845000 ns | 1358906000 ns | 90701824 bytes | 427065344 bytes | 90701824 bytes | 427065344 bytes |
| `regexp` | invocation | 581709000 ns | 1376490000 ns | 161120256 bytes | 832749568 bytes | 161120256 bytes | 832749568 bytes |
| `json` | warmup | 634585000 ns | 599455000 ns | 722059264 bytes | 720486400 bytes | 722059264 bytes | 720486400 bytes |
| `json` | invocation | 625390000 ns | 609035000 ns | 1426620416 bytes | 1423474688 bytes | 1426620416 bytes | 1423474688 bytes |
| `map_set` | warmup | 311024000 ns | 328387000 ns | 24363008 bytes | 24363008 bytes | 24363008 bytes | 24363008 bytes |
| `map_set` | invocation | 311949000 ns | 314287000 ns | 25362432 bytes | 25362432 bytes | 25362432 bytes | 25362432 bytes |
| `weak_collections` | warmup | 432540000 ns | 438783000 ns | 19841024 bytes | 19857408 bytes | 19415040 bytes | 19431424 bytes |
| `weak_collections` | invocation | 420462000 ns | 431720000 ns | 19841024 bytes | 19857408 bytes | 19447808 bytes | 19464192 bytes |
| `typed_arrays_dataview` | warmup | 387257000 ns | 354869000 ns | 12533760 bytes | 12550144 bytes | 11157504 bytes | 11173888 bytes |
| `typed_arrays_dataview` | invocation | 430570000 ns | 404152000 ns | 12533760 bytes | 12550144 bytes | 11583488 bytes | 11599872 bytes |
| `classes_private_fields` | warmup | 698290000 ns | 737490000 ns | 11403264 bytes | 11403264 bytes | 11075584 bytes | 11075584 bytes |
| `classes_private_fields` | invocation | 685967000 ns | 740883000 ns | 11403264 bytes | 11403264 bytes | 11370496 bytes | 11370496 bytes |
| `iterators_generators` | warmup | 359457000 ns | 354238000 ns | 16089088 bytes | 16056320 bytes | 15679488 bytes | 15646720 bytes |
| `iterators_generators` | invocation | 352786000 ns | 363109000 ns | 16089088 bytes | 16056320 bytes | 15712256 bytes | 15679488 bytes |
| `proxies_accessors` | warmup | 487995000 ns | 501316000 ns | 17661952 bytes | 17645568 bytes | 17432576 bytes | 17416192 bytes |
| `proxies_accessors` | invocation | 496017000 ns | 487713000 ns | 17661952 bytes | 17645568 bytes | 17465344 bytes | 17448960 bytes |
| `intl` | warmup | 557661000 ns | 565662000 ns | 85639168 bytes | 85606400 bytes | 85639168 bytes | 85606400 bytes |
| `intl` | invocation | 584535000 ns | 576952000 ns | 200097792 bytes | 200065024 bytes | 200097792 bytes | 200065024 bytes |
| `mixed_long_lived_graph` | warmup | 458880000 ns | 494694000 ns | 19431424 bytes | 19415040 bytes | 19431424 bytes | 19415040 bytes |
| `mixed_long_lived_graph` | invocation | 446720000 ns | 468648000 ns | 19464192 bytes | 19447808 bytes | 19464192 bytes | 19447808 bytes |
| `application_mix` | warmup | 665006000 ns | 678167000 ns | 44122112 bytes | 46104576 bytes | 44122112 bytes | 46104576 bytes |
| `application_mix` | invocation | 666850000 ns | 669846000 ns | 58638336 bytes | 62570496 bytes | 58638336 bytes | 62570496 bytes |
| `wasm_scalar` | warmup | 670295000 ns | 677185000 ns | 10797056 bytes | 10829824 bytes | 10387456 bytes | 10420224 bytes |
| `wasm_scalar` | invocation | 627300000 ns | 652639000 ns | 10797056 bytes | 10829824 bytes | 10420224 bytes | 10452992 bytes |
| `wasm_simd` | warmup | 448484000 ns | 443811000 ns | 10813440 bytes | 10829824 bytes | 10403840 bytes | 10420224 bytes |
| `wasm_simd` | invocation | 428517000 ns | 444553000 ns | 10813440 bytes | 10829824 bytes | 10436608 bytes | 10452992 bytes |
| `wasm_memory` | warmup | 429160000 ns | 434440000 ns | 10846208 bytes | 10829824 bytes | 10436608 bytes | 10420224 bytes |
| `wasm_memory` | invocation | 424040000 ns | 438950000 ns | 10846208 bytes | 10829824 bytes | 10469376 bytes | 10452992 bytes |
| `promises_async_microtasks` | warmup | 9092509000 ns | 9567386000 ns | 425721856 bytes | 415858688 bytes | 425721856 bytes | 415858688 bytes |
| `promises_async_microtasks` | invocation | 45146805000 ns | 50319503000 ns | 1374945280 bytes | 1239646208 bytes | 1230995456 bytes | 1239646208 bytes |
| `temporal` | warmup | 84409000 ns | 105630000 ns | 23035904 bytes | 23035904 bytes | 23035904 bytes | 23035904 bytes |
| `temporal` | invocation | 86418000 ns | 95711000 ns | 23068672 bytes | 23085056 bytes | 23068672 bytes | 23085056 bytes |
| `modules_dynamic_import` | warmup | 118000 ns | 115000 ns | 7307264 bytes | 7323648 bytes | 7307264 bytes | 7323648 bytes |
| `modules_dynamic_import` | invocation | 69585000 ns | 71250000 ns | 9027584 bytes | 9076736 bytes | 9027584 bytes | 9076736 bytes |

## Native-code and heap state

These values are phase-boundary gauges or cumulative counters, not timing-row measurements.

| family | phase | base live code bytes | variant live code bytes | base heap live bytes | variant heap live bytes | base collections | variant collections |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 16384 | 16384 | 1728120 | 1882424 | 55 | 55 |
| `strings_unicode` | invocation | 16384 | 16384 | 2439352 | 2767288 | 109 | 109 |
| `regexp` | warmup | 16384 | 16384 | 749880 | 749880 | 34 | 34 |
| `regexp` | invocation | 16384 | 16384 | 418168 | 418168 | 67 | 67 |
| `json` | warmup | 16384 | 16384 | 2763960 | 2766328 | 31 | 31 |
| `json` | invocation | 16384 | 16384 | 4451192 | 4475128 | 61 | 61 |
| `map_set` | warmup | 32768 | 32768 | 3367736 | 3367736 | 13 | 13 |
| `map_set` | invocation | 32768 | 32768 | 1288952 | 1288952 | 26 | 26 |
| `weak_collections` | warmup | 16384 | 16384 | 1899512 | 1900664 | 15 | 15 |
| `weak_collections` | invocation | 16384 | 16384 | 2742776 | 2741880 | 29 | 29 |
| `typed_arrays_dataview` | warmup | 16384 | 16384 | 283128 | 283128 | 0 | 0 |
| `typed_arrays_dataview` | invocation | 16384 | 16384 | 300408 | 300408 | 0 | 0 |
| `classes_private_fields` | warmup | 32768 | 32768 | 361368 | 361368 | 0 | 0 |
| `classes_private_fields` | invocation | 32768 | 32768 | 454968 | 454968 | 0 | 0 |
| `iterators_generators` | warmup | 16384 | 16384 | 4238392 | 4241080 | 13 | 13 |
| `iterators_generators` | invocation | 16384 | 16384 | 3218168 | 3223416 | 26 | 26 |
| `proxies_accessors` | warmup | 65536 | 65536 | 3867256 | 3869496 | 8 | 8 |
| `proxies_accessors` | invocation | 65536 | 65536 | 2474296 | 2474680 | 16 | 16 |
| `intl` | warmup | 16384 | 16384 | 3053752 | 3053752 | 17 | 17 |
| `intl` | invocation | 16384 | 16384 | 808952 | 808952 | 34 | 34 |
| `mixed_long_lived_graph` | warmup | 16384 | 16384 | 1839608 | 1839608 | 1 | 1 |
| `mixed_long_lived_graph` | invocation | 16384 | 16384 | 2364024 | 2364024 | 1 | 1 |
| `application_mix` | warmup | 16384 | 16384 | 901624 | 900536 | 32 | 32 |
| `application_mix` | invocation | 16384 | 16384 | 768632 | 768248 | 63 | 63 |
| `wasm_scalar` | warmup | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_scalar` | invocation | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_simd` | warmup | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_simd` | invocation | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_memory` | warmup | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_memory` | invocation | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `promises_async_microtasks` | warmup | 81920 | 81920 | 43104832 | 40382432 | 316 | 319 |
| `promises_async_microtasks` | invocation | 81920 | 81920 | 452778128 | 452549920 | 531 | 542 |
| `temporal` | warmup | 16384 | 16384 | 638968 | 639480 | 5 | 5 |
| `temporal` | invocation | 16384 | 16384 | 4440312 | 4419832 | 8 | 8 |
| `modules_dynamic_import` | warmup | 0 | 0 | 245760 | 245760 | 0 | 0 |
| `modules_dynamic_import` | invocation | 16384 | 16384 | 252176 | 252176 | 0 | 0 |

## Shared-realm attribution

Each row is the invocation delta after the scored shared-mode warmup boundary. Worker work, joins, contention, GC, allocation, CPU, and resident memory are observed in the same fresh profiled process after every spawned worker has joined.

| family | lanes | base tiers | variant tiers | base contentions | variant contentions | base wait | variant wait | base worker runs | variant worker runs | base CPU | variant CPU | base retained RSS | variant retained RSS |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 1929878997 ns | 1904949830 ns | 1 | 1 | 2012911000 ns | 1990755000 ns | 1416249344 bytes | 1395048448 bytes |
| `strings_unicode` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 88713 | 93082 | 3491284218 ns | 3688922768 ns | 2 | 2 | 6585427000 ns | 6875225000 ns | 1979006976 bytes | 2378694656 bytes |
| `strings_unicode` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 817748 | 783285 | 8787918339 ns | 9039800842 ns | 4 | 4 | 31158535000 ns | 33905293000 ns | 3059302400 bytes | 1054621696 bytes |
| `strings_unicode` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1808402 | 1831160 | 55807038943 ns | 84212099092 ns | 8 | 8 | 332753303000 ns | 507334037000 ns | 1866760192 bytes | 1533444096 bytes |
| `regexp` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 844655755 ns | 2655881475 ns | 1 | 1 | 901508000 ns | 2704721000 ns | 639139840 bytes | 1455980544 bytes |
| `regexp` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 184259 | 58306 | 2033540175 ns | 4550028492 ns | 2 | 2 | 4035400000 ns | 9157576000 ns | 1185906688 bytes | 4594581504 bytes |
| `regexp` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 764912 | 314999 | 7119026594 ns | 16858628438 ns | 4 | 4 | 26294256000 ns | 60533592000 ns | 2275196928 bytes | 1240694784 bytes |
| `regexp` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1504075 | 740010 | 91112461572 ns | 98557325011 ns | 8 | 8 | 517641097000 ns | 634269177000 ns | 309854208 bytes | 1018609664 bytes |
| `json` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 884457129 ns | 899147130 ns | 1 | 1 | 919323000 ns | 932132000 ns | 4047110144 bytes | 4043358208 bytes |
| `json` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 123867 | 121315 | 1562054412 ns | 1627578375 ns | 2 | 2 | 3095397000 ns | 3208478000 ns | 1746272256 bytes | 6399901696 bytes |
| `json` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 781758 | 788291 | 4288542469 ns | 5033379359 ns | 4 | 4 | 15299700000 ns | 17448854000 ns | 1065598976 bytes | 4088807424 bytes |
| `json` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 2017135 | 1750540 | 36815468820 ns | 42070520555 ns | 8 | 8 | 212408716000 ns | 211569715000 ns | 772472832 bytes | 494567424 bytes |
| `map_set` | 1 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 0 | 0 | 336886419 ns | 351487168 ns | 1 | 1 | 361581000 ns | 376020000 ns | 303038464 bytes | 303022080 bytes |
| `map_set` | 2 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 28036 | 26680 | 984099745 ns | 1638358495 ns | 2 | 2 | 1855856000 ns | 2185115000 ns | 557170688 bytes | 580419584 bytes |
| `map_set` | 4 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 286045 | 50862 | 2966766080 ns | 4663100946 ns | 4 | 4 | 10959520000 ns | 7432854000 ns | 1062551552 bytes | 603045888 bytes |
| `map_set` | 8 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 562931 | 309787 | 13380381367 ns | 38700632902 ns | 8 | 8 | 75822719000 ns | 200668428000 ns | 2094301184 bytes | 338575360 bytes |
| `weak_collections` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 662356917 ns | 490538626 ns | 1 | 1 | 574263000 ns | 504881000 ns | 123715584 bytes | 129826816 bytes |
| `weak_collections` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 178203 | 201302 | 1663070358 ns | 1267970952 ns | 2 | 2 | 2905337000 ns | 2319278000 ns | 223068160 bytes | 240467968 bytes |
| `weak_collections` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1478741 | 1667398 | 3614231407 ns | 3316388033 ns | 4 | 4 | 12448217000 ns | 12491000000 ns | 461897728 bytes | 483983360 bytes |
| `weak_collections` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 3127126 | 5033591 | 6663630963 ns | 7346192248 ns | 8 | 8 | 28727510000 ns | 42284372000 ns | 921321472 bytes | 914522112 bytes |
| `typed_arrays_dataview` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 506762878 ns | 737019540 ns | 1 | 1 | 480515000 ns | 639012000 ns | 13860864 bytes | 9633792 bytes |
| `typed_arrays_dataview` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 105776 | 404789 | 1916352410 ns | 1423205253 ns | 2 | 2 | 1650057000 ns | 2183664000 ns | 10747904 bytes | 16859136 bytes |
| `typed_arrays_dataview` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 328630 | 3118917 | 2885183842 ns | 3047467495 ns | 4 | 4 | 3360865000 ns | 9157967000 ns | 9732096 bytes | 21381120 bytes |
| `typed_arrays_dataview` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 835086 | 1759960 | 5142115895 ns | 4578057528 ns | 8 | 8 | 7000843000 ns | 9242363000 ns | 17874944 bytes | 22691840 bytes |
| `classes_private_fields` | 1 | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | 0 | 0 | 899649086 ns | 981505250 ns | 1 | 1 | 861485000 ns | 912489000 ns | 318259200 bytes | 158449664 bytes |
| `classes_private_fields` | 2 | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | 39414 | 39688 | 2136574073 ns | 1841201703 ns | 2 | 2 | 3250837000 ns | 3410664000 ns | 723533824 bytes | 218382336 bytes |
| `classes_private_fields` | 4 | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | 786737 | 503681 | 5061106605 ns | 5031797941 ns | 4 | 4 | 12131885000 ns | 10319309000 ns | 41517056 bytes | 184172544 bytes |
| `classes_private_fields` | 8 | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | `tree_walker_entries+vm_entries+optimizer_entries+deoptimizations` | 1168921 | 3192046 | 12255215147 ns | 10988679615 ns | 8 | 8 | 23474152000 ns | 43897211000 ns | 81559552 bytes | 202473472 bytes |
| `iterators_generators` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 410626917 ns | 391598915 ns | 1 | 1 | 415440000 ns | 401082000 ns | 71745536 bytes | 71581696 bytes |
| `iterators_generators` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 51626 | 78684 | 1064211918 ns | 852586240 ns | 2 | 2 | 1322356000 ns | 1433612000 ns | 129712128 bytes | 126795776 bytes |
| `iterators_generators` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 928089 | 652669 | 2883048462 ns | 2941698909 ns | 4 | 4 | 8180082000 ns | 7078648000 ns | 255279104 bytes | 109838336 bytes |
| `iterators_generators` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 2439443 | 1863410 | 5824888404 ns | 5169985882 ns | 8 | 8 | 25514710000 ns | 18671933000 ns | 219185152 bytes | 276004864 bytes |
| `proxies_accessors` | 1 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 0 | 0 | 566504912 ns | 590016253 ns | 1 | 1 | 569117000 ns | 579380000 ns | 403144704 bytes | 122634240 bytes |
| `proxies_accessors` | 2 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 40277 | 32501 | 1063151581 ns | 1024407875 ns | 2 | 2 | 2085885000 ns | 2021204000 ns | 641875968 bytes | 317210624 bytes |
| `proxies_accessors` | 4 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 1000808 | 921471 | 2855744585 ns | 3095066406 ns | 4 | 4 | 9632217000 ns | 9543823000 ns | 437698560 bytes | 315293696 bytes |
| `proxies_accessors` | 8 | `vm_entries+optimizer_entries+deoptimizations` | `vm_entries+optimizer_entries+deoptimizations` | 2029352 | 1900406 | 6033899538 ns | 5740700983 ns | 8 | 8 | 27324546000 ns | 22246180000 ns | 368672768 bytes | 409960448 bytes |
| `intl` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 703179424 ns | 634158331 ns | 1 | 1 | 709963000 ns | 660984000 ns | 547422208 bytes | 915865600 bytes |
| `intl` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 24061 | 16629 | 2117443795 ns | 1123632995 ns | 2 | 2 | 2629494000 ns | 2161319000 ns | 623919104 bytes | 850116608 bytes |
| `intl` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 489379 | 301972 | 3568457909 ns | 2826219504 ns | 4 | 4 | 13511268000 ns | 10680609000 ns | 1368965120 bytes | 978321408 bytes |
| `intl` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1234459 | 1344667 | 14421308541 ns | 12991181890 ns | 8 | 8 | 86631623000 ns | 84776345000 ns | 497582080 bytes | 861732864 bytes |
| `mixed_long_lived_graph` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 560547416 ns | 514803090 ns | 1 | 1 | 543811000 ns | 510146000 ns | 20758528 bytes | 20283392 bytes |
| `mixed_long_lived_graph` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 7 | 46 | 1133577247 ns | 1154883279 ns | 2 | 2 | 2184232000 ns | 2236182000 ns | 17268736 bytes | 17842176 bytes |
| `mixed_long_lived_graph` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 126 | 191 | 2809870322 ns | 2629102992 ns | 4 | 4 | 10519782000 ns | 10192305000 ns | 20758528 bytes | 21151744 bytes |
| `mixed_long_lived_graph` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 447 | 413 | 7455329509 ns | 7387359293 ns | 8 | 8 | 54307370000 ns | 51574378000 ns | 22822912 bytes | 21561344 bytes |
| `application_mix` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 789479294 ns | 774935287 ns | 1 | 1 | 853280000 ns | 855936000 ns | 685719552 bytes | 1025507328 bytes |
| `application_mix` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 62214 | 58231 | 1902583462 ns | 1911457510 ns | 2 | 2 | 3916236000 ns | 3837462000 ns | 952762368 bytes | 1074987008 bytes |
| `application_mix` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 306626 | 311657 | 5672612549 ns | 6815558208 ns | 4 | 4 | 20465310000 ns | 23545760000 ns | 734806016 bytes | 404340736 bytes |
| `application_mix` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 432625 | 523409 | 92362671187 ns | 58003979572 ns | 8 | 8 | 455262303000 ns | 315976013000 ns | 385400832 bytes | 503136256 bytes |
| `wasm_scalar` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 624807413 ns | 628174794 ns | 1 | 1 | 623863000 ns | 626066000 ns | 10977280 bytes | 11026432 bytes |
| `wasm_scalar` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 684494159 ns | 654308326 ns | 2 | 2 | 1316849000 ns | 1285409000 ns | 11403264 bytes | 11386880 bytes |
| `wasm_scalar` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1 | 4 | 724197374 ns | 843374341 ns | 4 | 4 | 2727692000 ns | 3128439000 ns | 12419072 bytes | 12124160 bytes |
| `wasm_scalar` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1 | 2 | 1234178539 ns | 1069406124 ns | 8 | 8 | 8056336000 ns | 7714271000 ns | 13975552 bytes | 14008320 bytes |
| `wasm_simd` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 445973092 ns | 437443460 ns | 1 | 1 | 445242000 ns | 437488000 ns | 11026432 bytes | 6782976 bytes |
| `wasm_simd` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 471983670 ns | 434503876 ns | 2 | 2 | 923730000 ns | 863926000 ns | 11436032 bytes | 11436032 bytes |
| `wasm_simd` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 450409752 ns | 491136333 ns | 4 | 4 | 1757918000 ns | 1905680000 ns | 12255232 bytes | 12763136 bytes |
| `wasm_simd` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1 | 1 | 747909252 ns | 777203177 ns | 8 | 8 | 5202854000 ns | 5596878000 ns | 14041088 bytes | 14598144 bytes |
| `promises_async_microtasks` | 1 | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | 0 | 0 | 1044973870 ns | 1150358665 ns | 1 | 1 | 1510479000 ns | 1693904000 ns | 2571763712 bytes | 2163654656 bytes |
| `promises_async_microtasks` | 2 | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | 465726 | 371645 | 3580681369 ns | 4948211997 ns | 2 | 2 | 49801943000 ns | 67629756000 ns | 3641376768 bytes | 1077510144 bytes |
| `promises_async_microtasks` | 4 | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | 1222586 | 943804 | 11077321346 ns | 15304429171 ns | 4 | 4 | 217019423000 ns | 232204857000 ns | 3413786624 bytes | 2025848832 bytes |
| `promises_async_microtasks` | 8 | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | `vm_entries+baseline_entries+optimizer_entries+deoptimizations` | 1628869 | 1762648 | 55885994757 ns | 42688509260 ns | 8 | 8 | 724725455000 ns | 718835869000 ns | 2180890624 bytes | 2436513792 bytes |
| `temporal` | 1 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 0 | 0 | 74954665 ns | 73003710 ns | 1 | 1 | 87006000 ns | 85924000 ns | 71614464 bytes | 71204864 bytes |
| `temporal` | 2 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 206223 | 206780 | 191171788 ns | 193023336 ns | 2 | 2 | 395561000 ns | 400958000 ns | 128466944 bytes | 129040384 bytes |
| `temporal` | 4 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 642509 | 833898 | 520472959 ns | 489616337 ns | 4 | 4 | 1785720000 ns | 1584605000 ns | 259473408 bytes | 251691008 bytes |
| `temporal` | 8 | `vm_entries+optimizer_entries` | `vm_entries+optimizer_entries` | 1754184 | 1625887 | 1008729752 ns | 870306290 ns | 8 | 8 | 4937090000 ns | 3233709000 ns | 477429760 bytes | 479870976 bytes |
| `wasm_memory_shared_atomic` | 1 | `vm_entries+optimizer_entries+deoptimizations` | n/a | 0 | n/a | 61320043 ns | n/a | 1 | n/a | 61586000 ns | n/a | 10518528 bytes | n/a |
| `wasm_memory_shared_atomic` | 2 | `vm_entries+optimizer_entries+deoptimizations` | n/a | 0 | n/a | 90918376 ns | n/a | 2 | n/a | 181949000 ns | n/a | 10911744 bytes | n/a |
| `wasm_memory_shared_atomic` | 4 | `vm_entries+optimizer_entries+deoptimizations` | n/a | 0 | n/a | 115265542 ns | n/a | 4 | n/a | 460939000 ns | n/a | 12435456 bytes | n/a |
| `wasm_memory_shared_atomic` | 8 | `vm_entries+optimizer_entries+deoptimizations` | n/a | 0 | n/a | 384970795 ns | n/a | 8 | n/a | 2804168000 ns | n/a | 13484032 bytes | n/a |

Raw attribution: [`representative-tier-attribution-v15-schema-v10-2026-08-05.json`](representative-tier-attribution-v15-schema-v10-2026-08-05.json)
