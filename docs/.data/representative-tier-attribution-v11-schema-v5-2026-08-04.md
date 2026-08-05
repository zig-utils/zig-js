# Representative tier attribution — zig-js-representative-v11

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
| `strings_unicode` | warmup | 55 | 55 | 1518959 ns | 1506125 ns | 1745541 ns | 1705167 ns | 1877417 ns | 1738583 ns |
| `strings_unicode` | invocation | 54 | 54 | 1579209 ns | 1557750 ns | 1601834 ns | 1677833 ns | 1656208 ns | 1713500 ns |
| `regexp` | warmup | 34 | 34 | 1548500 ns | 1587583 ns | 1776458 ns | 1830667 ns | 1801084 ns | 1860250 ns |
| `regexp` | invocation | 33 | 33 | 1530375 ns | 1590958 ns | 1566125 ns | 1633500 ns | 1576417 ns | 1647167 ns |
| `json` | warmup | 31 | 31 | 982500 ns | 985042 ns | 1182709 ns | 1108500 ns | 1368333 ns | 1193458 ns |
| `json` | invocation | 30 | 30 | 969458 ns | 975458 ns | 1069833 ns | 1037792 ns | 1083292 ns | 1049625 ns |
| `map_set` | warmup | 13 | 13 | 1638625 ns | 1602167 ns | 1786375 ns | 1737791 ns | 1786375 ns | 1737791 ns |
| `map_set` | invocation | 13 | 13 | 1568250 ns | 1564959 ns | 1622667 ns | 1766542 ns | 1622667 ns | 1766542 ns |
| `weak_collections` | warmup | 15 | 15 | 821083 ns | 829375 ns | 1116292 ns | 1046709 ns | 1116292 ns | 1046709 ns |
| `weak_collections` | invocation | 14 | 14 | 673291 ns | 677708 ns | 834584 ns | 826125 ns | 834584 ns | 826125 ns |
| `typed_arrays_dataview` | warmup | 0 | 0 | none | none | none | none | none | none |
| `typed_arrays_dataview` | invocation | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | warmup | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | invocation | 0 | 0 | none | none | none | none | none | none |
| `iterators_generators` | warmup | 13 | 13 | 636667 ns | 638292 ns | 871166 ns | 928375 ns | 871166 ns | 928375 ns |
| `iterators_generators` | invocation | 13 | 13 | 532416 ns | 636250 ns | 643459 ns | 664833 ns | 643459 ns | 664833 ns |
| `proxies_accessors` | warmup | 8 | 8 | 1420792 ns | 1429750 ns | 1532250 ns | 1571375 ns | 1532250 ns | 1571375 ns |
| `proxies_accessors` | invocation | 8 | 8 | 1403625 ns | 1378834 ns | 1482250 ns | 1429959 ns | 1482250 ns | 1429959 ns |
| `intl` | warmup | 17 | 17 | 1467625 ns | 1466375 ns | 1654958 ns | 1641625 ns | 1654958 ns | 1641625 ns |
| `intl` | invocation | 17 | 17 | 1464541 ns | 1445209 ns | 1492750 ns | 1487916 ns | 1492750 ns | 1487916 ns |
| `mixed_long_lived_graph` | warmup | 1 | 1 | 1450292 ns | 1438042 ns | 1450292 ns | 1438042 ns | 1450292 ns | 1438042 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | none | none | none | none | none | none |
| `application_mix` | warmup | 32 | 32 | 1629000 ns | 1635709 ns | 1764125 ns | 1780875 ns | 1813583 ns | 1861041 ns |
| `application_mix` | invocation | 31 | 31 | 1713834 ns | 1694750 ns | 1848750 ns | 1732708 ns | 2005708 ns | 1739209 ns |
| `wasm_scalar` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_scalar` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | invocation | 0 | 0 | none | none | none | none | none | none |
| `promises_async_microtasks` | warmup | 316 | 319 | 14254542 ns | 15648459 ns | 85832291 ns | 56508041 ns | 103601666 ns | 106337375 ns |
| `promises_async_microtasks` | invocation | 215 | 223 | 64464417 ns | 60514833 ns | 475763417 ns | 486456375 ns | 554069000 ns | 497079083 ns |
| `temporal` | warmup | 5 | 5 | 1330042 ns | 1276875 ns | 1441791 ns | 1423791 ns | 1441791 ns | 1423791 ns |
| `temporal` | invocation | 3 | 3 | 1116958 ns | 1122208 ns | 1165208 ns | 1142792 ns | 1165208 ns | 1142792 ns |
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

Raw attribution: [`representative-tier-attribution-v11-schema-v5-2026-08-04.json`](representative-tier-attribution-v11-schema-v5-2026-08-04.json)
