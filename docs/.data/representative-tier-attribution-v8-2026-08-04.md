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

Raw attribution: [`representative-tier-attribution-v8-2026-08-04.json`](representative-tier-attribution-v8-2026-08-04.json)
