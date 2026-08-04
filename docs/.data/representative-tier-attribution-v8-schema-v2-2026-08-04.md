# Representative tier attribution — zig-js-representative-v8

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

## Native-code and heap state

These values are phase-boundary gauges or cumulative counters, not timing-row measurements.

| family | phase | base live code bytes | variant live code bytes | base heap live bytes | variant heap live bytes | base collections | variant collections |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `strings_unicode` | warmup | 16384 | 16384 | 1728120 | 1882424 | 55 | 55 |
| `strings_unicode` | invocation | 16384 | 16384 | 2439352 | 2767288 | 109 | 109 |
| `regexp` | warmup | 16384 | 16384 | 749944 | 749944 | 34 | 34 |
| `regexp` | invocation | 16384 | 16384 | 418232 | 418232 | 67 | 67 |
| `json` | warmup | 16384 | 16384 | 2764024 | 2766392 | 31 | 31 |
| `json` | invocation | 16384 | 16384 | 4451256 | 4475192 | 61 | 61 |
| `map_set` | warmup | 32768 | 32768 | 3368696 | 3368696 | 13 | 13 |
| `map_set` | invocation | 32768 | 32768 | 1289912 | 1289912 | 26 | 26 |
| `weak_collections` | warmup | 16384 | 16384 | 1899576 | 1900728 | 15 | 15 |
| `weak_collections` | invocation | 16384 | 16384 | 2742968 | 2742072 | 29 | 29 |
| `typed_arrays_dataview` | warmup | 16384 | 16384 | 283128 | 283128 | 0 | 0 |
| `typed_arrays_dataview` | invocation | 16384 | 16384 | 300408 | 300408 | 0 | 0 |
| `classes_private_fields` | warmup | 32768 | 32768 | 361368 | 361368 | 0 | 0 |
| `classes_private_fields` | invocation | 32768 | 32768 | 454968 | 454968 | 0 | 0 |
| `iterators_generators` | warmup | 16384 | 16384 | 4243768 | 4242296 | 13 | 13 |
| `iterators_generators` | invocation | 16384 | 16384 | 3229048 | 3228536 | 26 | 26 |
| `proxies_accessors` | warmup | 65536 | 65536 | 3867736 | 3871384 | 8 | 8 |
| `proxies_accessors` | invocation | 65536 | 65536 | 2491896 | 2486136 | 16 | 16 |
| `intl` | warmup | 16384 | 16384 | 3053816 | 3053816 | 17 | 17 |
| `intl` | invocation | 16384 | 16384 | 809016 | 809016 | 34 | 34 |
| `mixed_long_lived_graph` | warmup | 16384 | 16384 | 1839608 | 1839608 | 1 | 1 |
| `mixed_long_lived_graph` | invocation | 16384 | 16384 | 2364024 | 2364024 | 1 | 1 |
| `application_mix` | warmup | 16384 | 16384 | 901688 | 900600 | 32 | 32 |
| `application_mix` | invocation | 16384 | 16384 | 768696 | 768312 | 63 | 63 |
| `wasm_scalar` | warmup | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_scalar` | invocation | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_simd` | warmup | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_simd` | invocation | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_memory` | warmup | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `wasm_memory` | invocation | 16384 | 16384 | 401504 | 401504 | 0 | 0 |
| `promises_async_microtasks` | warmup | 81920 | 81920 | 43104832 | 40382432 | 316 | 319 |
| `promises_async_microtasks` | invocation | 81920 | 81920 | 452782320 | 452554376 | 531 | 542 |
| `temporal` | warmup | 16384 | 16384 | 639224 | 639864 | 5 | 5 |
| `temporal` | invocation | 16384 | 16384 | 4440696 | 4420088 | 8 | 8 |
| `modules_dynamic_import` | warmup | 0 | 0 | 245760 | 245760 | 0 | 0 |
| `modules_dynamic_import` | invocation | 16384 | 16384 | 252176 | 252176 | 0 | 0 |

Raw attribution: [`representative-tier-attribution-v8-schema-v2-2026-08-04.json`](representative-tier-attribution-v8-schema-v2-2026-08-04.json)
