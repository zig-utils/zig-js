# Representative tier attribution — zig-js-representative-v10

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
| `iterators_generators` | warmup | 16384 | 16384 | 4239856 | 4241080 | 13 | 13 |
| `iterators_generators` | invocation | 16384 | 16384 | 3220472 | 3224632 | 26 | 26 |
| `proxies_accessors` | warmup | 65536 | 65536 | 3870360 | 3870776 | 8 | 8 |
| `proxies_accessors` | invocation | 65536 | 65536 | 2484536 | 2483544 | 16 | 16 |
| `intl` | warmup | 16384 | 16384 | 3053752 | 3053752 | 17 | 17 |
| `intl` | invocation | 16384 | 16384 | 809080 | 809080 | 34 | 34 |
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
| `promises_async_microtasks` | invocation | 81920 | 81920 | 452783136 | 452554376 | 531 | 542 |
| `temporal` | warmup | 16384 | 16384 | 639352 | 639992 | 5 | 5 |
| `temporal` | invocation | 16384 | 16384 | 4440824 | 4420472 | 8 | 8 |
| `modules_dynamic_import` | warmup | 0 | 0 | 245760 | 245760 | 0 | 0 |
| `modules_dynamic_import` | invocation | 16384 | 16384 | 252176 | 252176 | 0 | 0 |

Raw attribution: [`representative-tier-attribution-v10-schema-v4-2026-08-04.json`](representative-tier-attribution-v10-schema-v4-2026-08-04.json)
