# WebAssembly Threads comparison — 2026-07-18

> Dated measurement, not a universal engine score. Higher throughput is better.
> Checksums, generation counts, timeouts, and the 120-second per-run watchdog are validated by the harness.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-18T06:56:34-07:00 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | eb43a2f9ada2dff9c72c2f372116c66008c302f5 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| WABT source compiler | 1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95) |
| Wasm module SHA-256 | 890076044756dcfb67445614cd08d0c73de9529e500d7ec13eeca424ae230d57 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Atomic throughput

Each operation is executed inside the same shared Wasm module. `1` worker calls the export on the owner thread; multi-worker rows spawn zig-js shared-realm `Thread`s that contend on the same instance and memory.

| kernel | workers | median | operations/s | scaling vs 1 | RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| contended atomic add | 1 | 61.82 ms | 14.56 M/s | 1.00x | 0.76% |
| contended atomic add | 2 | 93.81 ms | 19.19 M/s | 1.32x | 14.00% |
| contended atomic add | 4 | 190.64 ms | 18.88 M/s | 1.30x | 4.30% |
| contended atomic add | 8 | 417.91 ms | 17.23 M/s | 1.18x | 0.83% |
| contended CAS increment | 1 | 56.73 ms | 8.81 M/s | 1.00x | 0.56% |
| contended CAS increment | 2 | 138.45 ms | 7.22 M/s | 0.82x | 1.66% |
| contended CAS increment | 4 | 323.60 ms | 6.18 M/s | 0.70x | 8.07% |
| contended CAS increment | 8 | 843.32 ms | 4.74 M/s | 0.54x | 2.78% |
| disjoint atomic add | 1 | 61.28 ms | 13.87 M/s | 1.00x | 1.55% |
| disjoint atomic add | 2 | 88.05 ms | 19.31 M/s | 1.39x | 1.09% |
| disjoint atomic add | 4 | 171.09 ms | 19.87 M/s | 1.43x | 5.64% |
| disjoint atomic add | 8 | 393.60 ms | 17.28 M/s | 1.25x | 1.08% |

## Wait/notify handoffs

Workers are paired. Each generation increments a request counter, parks with `memory.atomic.wait32`, increments an acknowledgement counter, and wakes with `memory.atomic.notify`; the harness rejects timeouts or mismatched final generations.

| workers | median | pair handoffs/s | RSD |
| ---: | ---: | ---: | ---: |
| 2 | 115.62 ms | 259,476 | 10.30% |
| 4 | 56.22 ms | 1,067,241 | 7.61% |
| 8 | 417.47 ms | 287,444 | 8.21% |

## JavaScriptCore comparison boundary

The system JSC public embedding API was probed before scoring. There is no equivalent row to report for this module:

| probe | result |
| --- | --- |
| automation JavaScript context (`typeof WebAssembly:typeof SharedArrayBuffer`) | `object:undefined` |
| shared-memory/atomic module through `JSGlobalContext` | rejected with JavaScriptException |
| equivalent shared-realm worker API | not present in the public C API |

JSC is therefore `N/A`, not zero and not slower. The main README comparison separately scores zig-js and system JSC for equivalent single and independent-context workloads.

## Method and timing boundary

The artifact contains 105 raw samples across 15 rows. Module decoding, validation, instantiation, JavaScript setup, and warm-up are outside the timer.
The published performance support boundary is the macOS arm64 host recorded above; this artifact makes no Linux or x86 throughput claim. Portable correctness and sanitizer hosts are tracked separately.
Single-worker rows time one selected Wasm invocation. Multi-worker rows deliberately include shared-realm `Thread` construction, dispatch, joins, and the final checksum/generation validation; every worker executes the displayed per-worker job count.
Contended add targets word zero. CAS retries until each requested increment commits. Disjoint add assigns one cache-adjacent word per worker. Wait/notify uses two monotonic words per pair so scheduling delays cannot lose a generation.

## Reproduce

```sh
zig build wasm-threads-benchmark -Doptimize=ReleaseFast
zig build wasm-threads-benchmark -Doptimize=ReleaseFast -Dwasm-threads-benchmark-quick=true
```

Regenerate the embedded module after editing its readable source:

```sh
wat2wasm --enable-threads bench/wasm_threads_kernels.wat -o /tmp/wasm_threads_kernels.wasm
shasum -a 256 /tmp/wasm_threads_kernels.wasm
```
