# Representative tier attribution — zig-js-representative-v13

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

## Tier-up and deoptimization latency

Tier-up time starts after a successful compilation claim and ends when code publication succeeds or the attempt is rejected. Deoptimization time starts when native code returns a recoverable exit and ends after the interpreter continuation is fully reconstructed; it excludes native execution before the exit.

| family | phase | base tier-ups | variant tier-ups | base tier-up time | variant tier-up time | base deopts | variant deopts | base deopt time | variant deopt time |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 1 | 1 | 178708 ns | 160000 ns | 0 | 0 | 0 ns | 0 ns |
| `strings_unicode` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `regexp` | warmup | 1 | 1 | 149250 ns | 189667 ns | 0 | 0 | 0 ns | 0 ns |
| `regexp` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `json` | warmup | 1 | 1 | 112708 ns | 158166 ns | 0 | 0 | 0 ns | 0 ns |
| `json` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `map_set` | warmup | 2 | 2 | 244126 ns | 236125 ns | 230393 | 230393 | 4814443 ns | 4733107 ns |
| `map_set` | invocation | 0 | 0 | 0 ns | 0 ns | 230400 | 230400 | 4626269 ns | 4601799 ns |
| `weak_collections` | warmup | 1 | 1 | 144500 ns | 116792 ns | 0 | 0 | 0 ns | 0 ns |
| `weak_collections` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `typed_arrays_dataview` | warmup | 1 | 1 | 152500 ns | 221125 ns | 0 | 0 | 0 ns | 0 ns |
| `typed_arrays_dataview` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `classes_private_fields` | warmup | 2 | 2 | 241875 ns | 227459 ns | 1799993 | 1799993 | 35021179 ns | 36337296 ns |
| `classes_private_fields` | invocation | 0 | 0 | 0 ns | 0 ns | 1800000 | 1800000 | 35170449 ns | 35567534 ns |
| `iterators_generators` | warmup | 1 | 1 | 116250 ns | 98583 ns | 0 | 0 | 0 ns | 0 ns |
| `iterators_generators` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `proxies_accessors` | warmup | 4 | 4 | 400666 ns | 454667 ns | 249993 | 249993 | 7859475 ns | 7941169 ns |
| `proxies_accessors` | invocation | 0 | 0 | 0 ns | 0 ns | 250000 | 250000 | 7614008 ns | 7606939 ns |
| `intl` | warmup | 1 | 1 | 117834 ns | 126542 ns | 0 | 0 | 0 ns | 0 ns |
| `intl` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `mixed_long_lived_graph` | warmup | 1 | 1 | 124041 ns | 96583 ns | 0 | 0 | 0 ns | 0 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `application_mix` | warmup | 1 | 1 | 101375 ns | 136875 ns | 0 | 0 | 0 ns | 0 ns |
| `application_mix` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_scalar` | warmup | 1 | 1 | 104333 ns | 116542 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_scalar` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_simd` | warmup | 1 | 1 | 125041 ns | 114125 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_simd` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_memory` | warmup | 1 | 1 | 128459 ns | 130708 ns | 0 | 0 | 0 ns | 0 ns |
| `wasm_memory` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `promises_async_microtasks` | warmup | 5 | 5 | 523626 ns | 506709 ns | 179922 | 179922 | 4463748 ns | 4430471 ns |
| `promises_async_microtasks` | invocation | 0 | 0 | 0 ns | 0 ns | 179943 | 179943 | 4428855 ns | 4414237 ns |
| `temporal` | warmup | 1 | 1 | 128667 ns | 114833 ns | 0 | 0 | 0 ns | 0 ns |
| `temporal` | invocation | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `modules_dynamic_import` | warmup | 0 | 0 | 0 ns | 0 ns | 0 | 0 | 0 ns | 0 ns |
| `modules_dynamic_import` | invocation | 1 | 1 | 112041 ns | 267458 ns | 0 | 0 | 0 ns | 0 ns |

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
| `promises_async_microtasks` | invocation | 5045819 | 5045860 | 1404864896 | 1407865216 | 3741711 | 3709865 | 962907840 | 954369280 |
| `temporal` | warmup | 193197 | 193195 | 31705656 | 31638072 | 128050 | 128050 | 16390400 | 16390400 |
| `temporal` | invocation | 193050 | 193052 | 27284400 | 27351984 | 128050 | 128050 | 16390400 | 16390400 |
| `modules_dynamic_import` | warmup | 1 | 1 | 320 | 320 | 0 | 0 | 0 | 0 |
| `modules_dynamic_import` | invocation | 381 | 381 | 2294393 | 2294372 | 37 | 37 | 8064 | 8064 |

## GC pause distribution

Each phase contains the exact completed minor/full cycle samples appended during that interval. Percentiles use the nearest-rank method; `none` means the phase completed no collection, and any sample overflow rejects the artifact.

| family | phase | base cycles | variant cycles | base p50 | variant p50 | base p95 | variant p95 | base max | variant max |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 55 | 55 | 1603250 ns | 1599542 ns | 1804792 ns | 1802792 ns | 1865500 ns | 2359167 ns |
| `strings_unicode` | invocation | 54 | 54 | 1663250 ns | 1657333 ns | 1794625 ns | 1706167 ns | 2477583 ns | 1788167 ns |
| `regexp` | warmup | 34 | 34 | 1551541 ns | 1835958 ns | 1814125 ns | 2459417 ns | 1905584 ns | 2685166 ns |
| `regexp` | invocation | 33 | 33 | 1572083 ns | 1812917 ns | 1638083 ns | 1922750 ns | 1644541 ns | 1948708 ns |
| `json` | warmup | 31 | 31 | 1063875 ns | 1048292 ns | 1177833 ns | 1331958 ns | 1206750 ns | 1380291 ns |
| `json` | invocation | 30 | 30 | 1072833 ns | 1038750 ns | 1177875 ns | 1227500 ns | 1182125 ns | 1281667 ns |
| `map_set` | warmup | 13 | 13 | 1725209 ns | 1683959 ns | 2125292 ns | 1920042 ns | 2125292 ns | 1920042 ns |
| `map_set` | invocation | 13 | 13 | 1628708 ns | 1646167 ns | 1867542 ns | 1742625 ns | 1867542 ns | 1742625 ns |
| `weak_collections` | warmup | 15 | 15 | 968917 ns | 1072875 ns | 1465292 ns | 1392959 ns | 1465292 ns | 1392959 ns |
| `weak_collections` | invocation | 14 | 14 | 793750 ns | 773750 ns | 1039417 ns | 1430792 ns | 1039417 ns | 1430792 ns |
| `typed_arrays_dataview` | warmup | 0 | 0 | none | none | none | none | none | none |
| `typed_arrays_dataview` | invocation | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | warmup | 0 | 0 | none | none | none | none | none | none |
| `classes_private_fields` | invocation | 0 | 0 | none | none | none | none | none | none |
| `iterators_generators` | warmup | 13 | 13 | 748500 ns | 738833 ns | 1153958 ns | 1118792 ns | 1153958 ns | 1118792 ns |
| `iterators_generators` | invocation | 13 | 13 | 586459 ns | 612708 ns | 987459 ns | 872666 ns | 987459 ns | 872666 ns |
| `proxies_accessors` | warmup | 8 | 8 | 1378125 ns | 1421459 ns | 1623250 ns | 1657750 ns | 1623250 ns | 1657750 ns |
| `proxies_accessors` | invocation | 8 | 8 | 1391917 ns | 1372750 ns | 1435584 ns | 1464250 ns | 1435584 ns | 1464250 ns |
| `intl` | warmup | 17 | 17 | 1521083 ns | 1562958 ns | 1777834 ns | 1831750 ns | 1777834 ns | 1831750 ns |
| `intl` | invocation | 17 | 17 | 1528875 ns | 1523750 ns | 1679500 ns | 1605041 ns | 1679500 ns | 1605041 ns |
| `mixed_long_lived_graph` | warmup | 1 | 1 | 1452417 ns | 1408583 ns | 1452417 ns | 1408583 ns | 1452417 ns | 1408583 ns |
| `mixed_long_lived_graph` | invocation | 0 | 0 | none | none | none | none | none | none |
| `application_mix` | warmup | 32 | 32 | 1787791 ns | 1784834 ns | 2015625 ns | 2012667 ns | 2202500 ns | 2028750 ns |
| `application_mix` | invocation | 31 | 31 | 1831750 ns | 1837250 ns | 1943417 ns | 2018916 ns | 1986000 ns | 2048375 ns |
| `wasm_scalar` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_scalar` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_simd` | invocation | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | warmup | 0 | 0 | none | none | none | none | none | none |
| `wasm_memory` | invocation | 0 | 0 | none | none | none | none | none | none |
| `promises_async_microtasks` | warmup | 316 | 319 | 16379250 ns | 18290041 ns | 99110667 ns | 63575000 ns | 112627583 ns | 122048791 ns |
| `promises_async_microtasks` | invocation | 215 | 223 | 75611333 ns | 69258666 ns | 564959375 ns | 577028958 ns | 600258583 ns | 593137583 ns |
| `temporal` | warmup | 5 | 5 | 1507000 ns | 1519917 ns | 1773875 ns | 1665542 ns | 1773875 ns | 1665542 ns |
| `temporal` | invocation | 3 | 3 | 1449208 ns | 1343625 ns | 1458209 ns | 1362042 ns | 1458209 ns | 1362042 ns |
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
| `strings_unicode` | warmup | 1848721000 ns | 1809784000 ns | 54427648 bytes | 54444032 bytes | 54427648 bytes | 54444032 bytes |
| `strings_unicode` | invocation | 1857594000 ns | 1801059000 ns | 86016000 bytes | 85983232 bytes | 86016000 bytes | 85983232 bytes |
| `regexp` | warmup | 539428000 ns | 2473365000 ns | 90603520 bytes | 3719413760 bytes | 90603520 bytes | 3652993024 bytes |
| `regexp` | invocation | 539165000 ns | 2463935000 ns | 160972800 bytes | 3723182080 bytes | 160972800 bytes | 3284385792 bytes |
| `json` | warmup | 586945000 ns | 577124000 ns | 722108416 bytes | 720535552 bytes | 722108416 bytes | 720535552 bytes |
| `json` | invocation | 592733000 ns | 582196000 ns | 1426669568 bytes | 1423507456 bytes | 1426669568 bytes | 1423507456 bytes |
| `map_set` | warmup | 300696000 ns | 307823000 ns | 24330240 bytes | 24428544 bytes | 24330240 bytes | 24428544 bytes |
| `map_set` | invocation | 298765000 ns | 305451000 ns | 25329664 bytes | 25427968 bytes | 25329664 bytes | 25427968 bytes |
| `weak_collections` | warmup | 411883000 ns | 413550000 ns | 19922944 bytes | 19808256 bytes | 19496960 bytes | 19382272 bytes |
| `weak_collections` | invocation | 407025000 ns | 408399000 ns | 19922944 bytes | 19808256 bytes | 19529728 bytes | 19415040 bytes |
| `typed_arrays_dataview` | warmup | 398820000 ns | 347260000 ns | 12615680 bytes | 12615680 bytes | 11239424 bytes | 11206656 bytes |
| `typed_arrays_dataview` | invocation | 419729000 ns | 380062000 ns | 12615680 bytes | 12615680 bytes | 11649024 bytes | 11649024 bytes |
| `classes_private_fields` | warmup | 664354000 ns | 689680000 ns | 11485184 bytes | 11485184 bytes | 11157504 bytes | 11157504 bytes |
| `classes_private_fields` | invocation | 655703000 ns | 696638000 ns | 11485184 bytes | 11485184 bytes | 11436032 bytes | 11436032 bytes |
| `iterators_generators` | warmup | 337678000 ns | 338850000 ns | 16089088 bytes | 16089088 bytes | 15679488 bytes | 15679488 bytes |
| `iterators_generators` | invocation | 332007000 ns | 339319000 ns | 16089088 bytes | 16089088 bytes | 15712256 bytes | 15712256 bytes |
| `proxies_accessors` | warmup | 468292000 ns | 474252000 ns | 17645568 bytes | 17678336 bytes | 17432576 bytes | 17465344 bytes |
| `proxies_accessors` | invocation | 463946000 ns | 469156000 ns | 17645568 bytes | 17678336 bytes | 17465344 bytes | 17498112 bytes |
| `intl` | warmup | 515577000 ns | 517276000 ns | 85688320 bytes | 85688320 bytes | 85688320 bytes | 85688320 bytes |
| `intl` | invocation | 524609000 ns | 523357000 ns | 200146944 bytes | 200146944 bytes | 200146944 bytes | 200146944 bytes |
| `mixed_long_lived_graph` | warmup | 447652000 ns | 448204000 ns | 19415040 bytes | 19415040 bytes | 19415040 bytes | 19415040 bytes |
| `mixed_long_lived_graph` | invocation | 434904000 ns | 436759000 ns | 19447808 bytes | 19447808 bytes | 19447808 bytes | 19447808 bytes |
| `application_mix` | warmup | 649667000 ns | 649078000 ns | 41893888 bytes | 43892736 bytes | 41893888 bytes | 43892736 bytes |
| `application_mix` | invocation | 645224000 ns | 648027000 ns | 52953088 bytes | 56885248 bytes | 52953088 bytes | 56885248 bytes |
| `wasm_scalar` | warmup | 609558000 ns | 621493000 ns | 10797056 bytes | 10846208 bytes | 10387456 bytes | 10436608 bytes |
| `wasm_scalar` | invocation | 609171000 ns | 625588000 ns | 10797056 bytes | 10846208 bytes | 10420224 bytes | 10469376 bytes |
| `wasm_simd` | warmup | 469283000 ns | 415973000 ns | 10878976 bytes | 10846208 bytes | 10469376 bytes | 10436608 bytes |
| `wasm_simd` | invocation | 435418000 ns | 410912000 ns | 10878976 bytes | 10846208 bytes | 10502144 bytes | 10469376 bytes |
| `wasm_memory` | warmup | 410648000 ns | 420210000 ns | 10846208 bytes | 10846208 bytes | 10436608 bytes | 10436608 bytes |
| `wasm_memory` | invocation | 408763000 ns | 420384000 ns | 10846208 bytes | 10846208 bytes | 10469376 bytes | 10469376 bytes |
| `promises_async_microtasks` | warmup | 8540812000 ns | 9208793000 ns | 425771008 bytes | 416153600 bytes | 425771008 bytes | 416153600 bytes |
| `promises_async_microtasks` | invocation | 42257843000 ns | 43356545000 ns | 1619951616 bytes | 1618313216 bytes | 1619607552 bytes | 1612988416 bytes |
| `temporal` | warmup | 77912000 ns | 76219000 ns | 23134208 bytes | 23134208 bytes | 23134208 bytes | 23134208 bytes |
| `temporal` | invocation | 73023000 ns | 73155000 ns | 23166976 bytes | 23166976 bytes | 23166976 bytes | 23166976 bytes |
| `modules_dynamic_import` | warmup | 117000 ns | 266000 ns | 7389184 bytes | 7405568 bytes | 7389184 bytes | 7405568 bytes |
| `modules_dynamic_import` | invocation | 63235000 ns | 80594000 ns | 9043968 bytes | 9093120 bytes | 9043968 bytes | 9093120 bytes |

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
| `promises_async_microtasks` | invocation | 81920 | 81920 | 452777720 | 452549920 | 531 | 542 |
| `temporal` | warmup | 16384 | 16384 | 638968 | 639480 | 5 | 5 |
| `temporal` | invocation | 16384 | 16384 | 4440312 | 4419832 | 8 | 8 |
| `modules_dynamic_import` | warmup | 0 | 0 | 245760 | 245760 | 0 | 0 |
| `modules_dynamic_import` | invocation | 16384 | 16384 | 252176 | 252176 | 0 | 0 |

Raw attribution: [`representative-tier-attribution-v13-schema-v7-2026-08-04.json`](representative-tier-attribution-v13-schema-v7-2026-08-04.json)
