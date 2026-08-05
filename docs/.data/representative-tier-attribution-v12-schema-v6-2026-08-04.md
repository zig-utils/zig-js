# Representative tier attribution — zig-js-representative-v12

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

## Allocation throughput

Backing rows count successful Context allocator calls and growth bytes. GC-cell rows count logical slab/delegated cell issuance separately, so backing growth is never double-counted as a cell allocation.

| family | phase | base backing ops | variant backing ops | base backing bytes | variant backing bytes | base GC cells | variant GC cells | base GC bytes | variant GC bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 3553406 | 3553960 | 395094548 | 394514298 | 2483800 | 2484350 | 227392000 | 227427200 |
| `strings_unicode` | invocation | 3553152 | 3553724 | 404442632 | 403862436 | 2483800 | 2484350 | 227392000 | 227427200 |
| `regexp` | warmup | 2593135 | 2592453 | 189925724 | 10682159688 | 1728010 | 1728010 | 138241280 | 138241280 |
| `regexp` | invocation | 2592472 | 2592061 | 210465521 | 13325748221 | 1728001 | 1728001 | 138240128 | 138240128 |
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
| `application_mix` | warmup | 2259142 | 2258204 | 407890656 | 415839014 | 1245120 | 1244160 | 127303680 | 127242240 |
| `application_mix` | invocation | 2258914 | 2257926 | 412588142 | 404634134 | 1245120 | 1244160 | 127303680 | 127242240 |
| `wasm_scalar` | warmup | 803 | 803 | 460576 | 460576 | 0 | 0 | 0 | 0 |
| `wasm_scalar` | invocation | 800 | 800 | 460160 | 460160 | 0 | 0 | 0 | 0 |
| `wasm_simd` | warmup | 1003 | 1003 | 491616 | 491616 | 0 | 0 | 0 | 0 |
| `wasm_simd` | invocation | 1000 | 1000 | 491200 | 491200 | 0 | 0 | 0 | 0 |
| `wasm_memory` | warmup | 903 | 903 | 442496 | 442496 | 0 | 0 | 0 | 0 |
| `wasm_memory` | invocation | 900 | 900 | 442080 | 442080 | 0 | 0 | 0 | 0 |
| `promises_async_microtasks` | warmup | 5041664 | 5041911 | 825665108 | 833074824 | 3645130 | 3614914 | 940595392 | 932046464 |
| `promises_async_microtasks` | invocation | 5045831 | 5045860 | 1405270400 | 1407865216 | 3741711 | 3709865 | 962907840 | 954369280 |
| `temporal` | warmup | 193197 | 193195 | 31705656 | 31638072 | 128050 | 128050 | 16390400 | 16390400 |
| `temporal` | invocation | 193050 | 193052 | 27284400 | 27351984 | 128050 | 128050 | 16390400 | 16390400 |
| `modules_dynamic_import` | warmup | 1 | 1 | 320 | 320 | 0 | 0 | 0 | 0 |
| `modules_dynamic_import` | invocation | 381 | 381 | 2294393 | 2294372 | 37 | 37 | 8064 | 8064 |

## GC pause distribution

Each phase contains the exact completed minor/full cycle samples appended during that interval. Percentiles use the nearest-rank method; `none` means the phase completed no collection, and any sample overflow rejects the artifact.

| family | phase | base cycles | variant cycles | base p50 | variant p50 | base p95 | variant p95 | base max | variant max |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 55 | 55 | 1583125 ns | 1575167 ns | 1894166 ns | 1751791 ns | 2299708 ns | 1770500 ns |
| `strings_unicode` | invocation | 54 | 54 | 1648416 ns | 1625458 ns | 1780084 ns | 1693250 ns | 1791958 ns | 1810125 ns |
| `regexp` | warmup | 34 | 34 | 1545750 ns | 1634709 ns | 1715542 ns | 2020875 ns | 1761500 ns | 2671667 ns |
| `regexp` | invocation | 33 | 33 | 1523625 ns | 1622666 ns | 1665166 ns | 1716084 ns | 1744167 ns | 1764166 ns |
| `json` | warmup | 31 | 31 | 1085917 ns | 1050750 ns | 1262208 ns | 1183792 ns | 1271917 ns | 1214417 ns |
| `json` | invocation | 30 | 30 | 1059167 ns | 1075792 ns | 1216625 ns | 1188875 ns | 1247584 ns | 1297375 ns |
| `map_set` | warmup | 13 | 13 | 1698000 ns | 1712250 ns | 2001542 ns | 2091250 ns | 2001542 ns | 2091250 ns |
| `map_set` | invocation | 13 | 13 | 1640083 ns | 1623083 ns | 1753958 ns | 1759125 ns | 1753958 ns | 1759125 ns |
| `weak_collections` | warmup | 15 | 15 | 953500 ns | 1100042 ns | 1316208 ns | 1664792 ns | 1316208 ns | 1664792 ns |
| `weak_collections` | invocation | 14 | 14 | 838375 ns | 775291 ns | 2137791 ns | 1080875 ns | 2137791 ns | 1080875 ns |
| `typed_arrays_dataview` | warmup | 0 | 0 | none | none | none | none | none | none |
| `typed_arrays_dataview` | invocation | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | warmup | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | invocation | 0 | 0 | none | none | none | none | none | none |
| `iterators_generators` | warmup | 13 | 13 | 752875 ns | 747167 ns | 1200708 ns | 1086708 ns | 1200708 ns | 1086708 ns |
| `iterators_generators` | invocation | 13 | 13 | 631041 ns | 724625 ns | 815458 ns | 814250 ns | 815458 ns | 814250 ns |
| `proxies_accessors` | warmup | 8 | 8 | 1396750 ns | 1447000 ns | 1626875 ns | 1592750 ns | 1626875 ns | 1592750 ns |
| `proxies_accessors` | invocation | 8 | 8 | 1377417 ns | 1380209 ns | 1474417 ns | 1450125 ns | 1474417 ns | 1450125 ns |
| `intl` | warmup | 17 | 17 | 1539041 ns | 1529458 ns | 1811584 ns | 1915792 ns | 1811584 ns | 1915792 ns |
| `intl` | invocation | 17 | 17 | 1482958 ns | 1534000 ns | 1641666 ns | 1657833 ns | 1641666 ns | 1657833 ns |
| `mixed_long_lived_graph` | warmup | 1 | 1 | 1630666 ns | 1444166 ns | 1630666 ns | 1444166 ns | 1630666 ns | 1444166 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | none | none | none | none | none | none |
| `application_mix` | warmup | 32 | 32 | 1807375 ns | 1740709 ns | 2177209 ns | 2004708 ns | 2223500 ns | 2128750 ns |
| `application_mix` | invocation | 31 | 31 | 1846875 ns | 1844000 ns | 2101208 ns | 1983833 ns | 2259000 ns | 2053583 ns |
| `wasm_scalar` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_scalar` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | invocation | 0 | 0 | none | none | none | none | none | none |
| `promises_async_microtasks` | warmup | 316 | 319 | 16695917 ns | 17962750 ns | 98732125 ns | 62309625 ns | 110330292 ns | 117995666 ns |
| `promises_async_microtasks` | invocation | 215 | 223 | 71376042 ns | 68732666 ns | 545905458 ns | 547236750 ns | 570154250 ns | 561720208 ns |
| `temporal` | warmup | 5 | 5 | 1465708 ns | 1485708 ns | 1672375 ns | 1491208 ns | 1672375 ns | 1491208 ns |
| `temporal` | invocation | 3 | 3 | 1343083 ns | 1351208 ns | 1428834 ns | 1358833 ns | 1428834 ns | 1358833 ns |
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

| family | phase | base contentions | variant contentions | base wait | variant wait | base worker runs | variant worker runs | base worker CPU | variant worker CPU |
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

CPU values are exact getrusage deltas for the fresh runner process. Peak RSS is the cumulative Darwin ru_maxrss gauge; retained RSS is Mach resident_size sampled at the phase boundary. The invocation retained value is captured after the workload host checkpoint and before Context destruction.

| family | phase | base CPU | variant CPU | base peak RSS | variant peak RSS | base retained RSS | variant retained RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 1857469000 ns | 1792493000 ns | 54362112 bytes | 54345728 bytes | 54362112 bytes | 54345728 bytes |
| `strings_unicode` | invocation | 1831211000 ns | 1799038000 ns | 85950464 bytes | 85884928 bytes | 85950464 bytes | 85884928 bytes |
| `regexp` | warmup | 540796000 ns | 2469655000 ns | 90537984 bytes | 3172679680 bytes | 90537984 bytes | 3062054912 bytes |
| `regexp` | invocation | 540566000 ns | 2435859000 ns | 160907264 bytes | 3172679680 bytes | 160907264 bytes | 2986147840 bytes |
| `json` | warmup | 588176000 ns | 578549000 ns | 721993728 bytes | 720437248 bytes | 721993728 bytes | 720437248 bytes |
| `json` | invocation | 591060000 ns | 582720000 ns | 1426554880 bytes | 1423409152 bytes | 1426554880 bytes | 1423409152 bytes |
| `map_set` | warmup | 293707000 ns | 302936000 ns | 24330240 bytes | 24330240 bytes | 24330240 bytes | 24330240 bytes |
| `map_set` | invocation | 292368000 ns | 300617000 ns | 25329664 bytes | 25329664 bytes | 25329664 bytes | 25329664 bytes |
| `weak_collections` | warmup | 409321000 ns | 414244000 ns | 19791872 bytes | 19791872 bytes | 19365888 bytes | 19365888 bytes |
| `weak_collections` | invocation | 434786000 ns | 407868000 ns | 19791872 bytes | 19791872 bytes | 19431424 bytes | 19398656 bytes |
| `typed_arrays_dataview` | warmup | 375455000 ns | 342532000 ns | 12550144 bytes | 12550144 bytes | 11190272 bytes | 11173888 bytes |
| `typed_arrays_dataview` | invocation | 421183000 ns | 386681000 ns | 12550144 bytes | 12550144 bytes | 11599872 bytes | 11599872 bytes |
| `classes_private_fields` | warmup | 631024000 ns | 672824000 ns | 11419648 bytes | 11419648 bytes | 11091968 bytes | 11091968 bytes |
| `classes_private_fields` | invocation | 635032000 ns | 670978000 ns | 11419648 bytes | 11419648 bytes | 11370496 bytes | 11370496 bytes |
| `iterators_generators` | warmup | 340146000 ns | 346185000 ns | 16007168 bytes | 15990784 bytes | 15597568 bytes | 15581184 bytes |
| `iterators_generators` | invocation | 339412000 ns | 341056000 ns | 16007168 bytes | 15990784 bytes | 15630336 bytes | 15613952 bytes |
| `proxies_accessors` | warmup | 468067000 ns | 474746000 ns | 17629184 bytes | 17645568 bytes | 17416192 bytes | 17432576 bytes |
| `proxies_accessors` | invocation | 469466000 ns | 476902000 ns | 17629184 bytes | 17645568 bytes | 17448960 bytes | 17465344 bytes |
| `intl` | warmup | 541607000 ns | 537007000 ns | 85573632 bytes | 85557248 bytes | 85573632 bytes | 85557248 bytes |
| `intl` | invocation | 547914000 ns | 544799000 ns | 200032256 bytes | 200032256 bytes | 200032256 bytes | 200032256 bytes |
| `mixed_long_lived_graph` | warmup | 450906000 ns | 451492000 ns | 19398656 bytes | 19398656 bytes | 19398656 bytes | 19398656 bytes |
| `mixed_long_lived_graph` | invocation | 434744000 ns | 436409000 ns | 19431424 bytes | 19431424 bytes | 19431424 bytes | 19431424 bytes |
| `application_mix` | warmup | 646385000 ns | 647414000 ns | 41844736 bytes | 43843584 bytes | 41844736 bytes | 43843584 bytes |
| `application_mix` | invocation | 667457000 ns | 650344000 ns | 52920320 bytes | 56819712 bytes | 52920320 bytes | 56819712 bytes |
| `wasm_scalar` | warmup | 625279000 ns | 613912000 ns | 10747904 bytes | 10747904 bytes | 10338304 bytes | 10338304 bytes |
| `wasm_scalar` | invocation | 629947000 ns | 607534000 ns | 10747904 bytes | 10747904 bytes | 10371072 bytes | 10371072 bytes |
| `wasm_simd` | warmup | 408053000 ns | 407513000 ns | 10797056 bytes | 10797056 bytes | 10387456 bytes | 10387456 bytes |
| `wasm_simd` | invocation | 410073000 ns | 403083000 ns | 10797056 bytes | 10797056 bytes | 10420224 bytes | 10420224 bytes |
| `wasm_memory` | warmup | 398074000 ns | 410881000 ns | 10780672 bytes | 10764288 bytes | 10371072 bytes | 10354688 bytes |
| `wasm_memory` | invocation | 396318000 ns | 408870000 ns | 10780672 bytes | 10764288 bytes | 10403840 bytes | 10387456 bytes |
| `promises_async_microtasks` | warmup | 8473569000 ns | 9005795000 ns | 425689088 bytes | 415694848 bytes | 425689088 bytes | 415694848 bytes |
| `promises_async_microtasks` | invocation | 40638356000 ns | 41854951000 ns | 1611776000 bytes | 1621458944 bytes | 1611431936 bytes | 1621082112 bytes |
| `temporal` | warmup | 82454000 ns | 78833000 ns | 23019520 bytes | 23019520 bytes | 23019520 bytes | 23019520 bytes |
| `temporal` | invocation | 75393000 ns | 82067000 ns | 23052288 bytes | 23052288 bytes | 23052288 bytes | 23052288 bytes |
| `modules_dynamic_import` | warmup | 104000 ns | 106000 ns | 7356416 bytes | 7340032 bytes | 7356416 bytes | 7340032 bytes |
| `modules_dynamic_import` | invocation | 62947000 ns | 65245000 ns | 9043968 bytes | 9076736 bytes | 9043968 bytes | 9076736 bytes |

## Native-code and heap state

These values are phase-boundary gauges or cumulative counters, not timing-row measurements.

| family | phase | base live code bytes | variant live code bytes | base heap live bytes | variant heap live bytes | base collections | variant collections |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 16384 | 16384 | 1728056 | 1882360 | 55 | 55 |
| `strings_unicode` | invocation | 16384 | 16384 | 2439288 | 2767224 | 109 | 109 |
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
| `iterators_generators` | warmup | 16384 | 16384 | 4238768 | 4241080 | 13 | 13 |
| `iterators_generators` | invocation | 16384 | 16384 | 3218168 | 3223416 | 26 | 26 |
| `proxies_accessors` | warmup | 65536 | 65536 | 3865400 | 3866424 | 8 | 8 |
| `proxies_accessors` | invocation | 65536 | 65536 | 2470648 | 2472952 | 16 | 16 |
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
| `promises_async_microtasks` | invocation | 81920 | 81920 | 452777720 | 452549920 | 531 | 542 |
| `temporal` | warmup | 16384 | 16384 | 638968 | 639480 | 5 | 5 |
| `temporal` | invocation | 16384 | 16384 | 4440312 | 4419832 | 8 | 8 |
| `modules_dynamic_import` | warmup | 0 | 0 | 245760 | 245760 | 0 | 0 |
| `modules_dynamic_import` | invocation | 16384 | 16384 | 252176 | 252176 | 0 | 0 |

Raw attribution: [`representative-tier-attribution-v12-schema-v6-2026-08-04.json`](representative-tier-attribution-v12-schema-v6-2026-08-04.json)
