# Exact-parent deep Shape index evidence — 2026-08-10

Exact-parent performance, work, and memory evidence for
[#530](https://github.com/zig-utils/zig-js/issues/530). The direct edge is
parent `8592a7dc844d4ac1911263cdd9c6b938a4d739e7` to implementation
`7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`. Every process uses the same
checked-in workload, frozen checksum, `zig-gc` revision, and `zig-regex`
revision. Fixture construction is outside the scored traversal boundary.

The implementation keeps shapes shallower than 32 operations on the compact
parent chain. At depth 32 it builds an immutable exact-key AVL index, then
path-copies one logarithmic spine per later operation. Transition fanout uses
the same collision-free persistent representation. Writers publish a complete
root under the existing transition lock; readers acquire that immutable root.

## Exact timing and work

| workload | jobs | pairs | wall | instructions | instruction RSD parent / candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1,024-property plain array-like | 400 | 7 | 0.276x | 0.288x | 1.43% / 1.92% |
| 2,048-property plain array-like | 30 | 7 | 0.105x | 0.190x | 0.81% / 3.96% |
| 4,096-property plain array-like | 12 | 7 | 0.037x | 0.092x | 0.39% / 3.57% |
| sparse Proxy over 4,096-property target | 6 | 7 | 0.176x | 0.360x | 0.64% / 1.03% |
| dense 4,096-element Array control | 100 | 15 | 1.048x | 1.088x | 2.72% / 2.85% |
| shallow classes control | 8 | 7 | 1.003x | 1.011x | 3.45% / 3.43% |
| mixed application control | 50 | 7 | 0.973x | 0.999x | 1.92% / 2.10% |

Ratios are candidate / exact parent, so lower is better. Instruction evidence
is stable and is the causal complexity measure. Wall medians are diagnostic:
this host's wall RSD exceeds the publication threshold on some deep rows, most
notably the short 4K candidate. No samples were discarded.

Normalized median instructions per traversed property stay nearly flat in the
candidate while rising with depth in the parent:

| width | parent instructions / property / job | candidate | candidate growth from 1K |
| ---: | ---: | ---: | ---: |
| 1,024 | 85,040.920 | 24,494.523 | 1.000x |
| 2,048 | 129,106.024 | 24,532.532 | 1.002x |
| 4,096 | 273,604.149 | 25,086.776 | 1.024x |

The deterministic structural witnesses independently cap a 4,096-name lookup
index and a 2,048-way transition index at AVL height 16; every successful and
missing exact lookup performs no more comparisons than the tree height.

Raw order-balanced artifacts:

- [1K plain array-like](exact-parent-deep-shape-array-like-1024-2026-08-10.json)
- [2K plain array-like](exact-parent-deep-shape-array-like-2048-2026-08-10.json)
- [4K plain array-like](exact-parent-deep-shape-array-like-4096-2026-08-10.json)
- [4K sparse Proxy](exact-parent-deep-shape-sparse-proxy-4096-2026-08-10.json)
- [dense Array control](exact-parent-deep-shape-dense-control-4096-2026-08-10.json)
- [classes control](exact-parent-deep-shape-classes-control-2026-08-10.json)
- [application control](exact-parent-deep-shape-application-control-2026-08-10.json)

## Memory and allocation cost

The persistent index deliberately spends bounded arena memory to remove linear
lookup. Seven fresh-process observed pairs measure the post-invocation retained
RSS cost at 4K:

| process memory | parent median | candidate median | candidate / parent |
| --- | ---: | ---: | ---: |
| peak RSS | 38,371,328 | 40,550,400 | 1.057x |
| retained RSS | 38,322,176 | 40,501,248 | 1.057x |

The retained increase is 2,179,072 bytes. It is finite, released with the
Context arena, and separately covered by a real moving-compaction test under a
32 MiB JavaScript heap limit. Full samples are in the
[retained-RSS artifact](exact-parent-deep-shape-retained-4096-2026-08-10.json).

One deterministic attribution process per revision separates configuration,
workload setup, and one scored 4K traversal:

| backing-allocation phase delta | parent | candidate | candidate / parent |
| --- | ---: | ---: | ---: |
| configuration current bytes | 9,527,395 | 13,824,457 | 1.451x |
| workload-setup current bytes | 10,491,607 | 12,540,899 | 1.195x |
| scored traversal requested bytes | 10,249,592 | 984,200 | 0.096x |
| scored traversal current-byte increase | 10,257,696 | 983,976 | 0.096x |
| scored traversal growth events | 29 | 0 | 0.000x |
| scored traversal GC-cell bytes | 2,098,368 | 2,098,368 | 1.000x |

The first two rows expose the index's construction cost; the invocation rows
also include reuse of the larger arena capacity established during setup, so
they are a phase attribution rather than a claim that the index eliminates all
allocation. The fresh-process retained-RSS median above is the primary memory
result. Exact snapshots and binary identities are in the
[allocation artifact](exact-parent-deep-shape-allocation-2026-08-10.json).

## Correctness, concurrency, and hostile inputs

- Full exact-source units: 1,586 passed, 1 skipped, 0 failed, 0 leaked.
- Focused suppression-free TSan: the four-lane no-GIL deep-shape and 256-way
  fanout convergence witness passes.
- Default and broad threadfuzz: 400 seeds each, zero failures.
- Lifecycle threadfuzz: 3,359 of 3,360 subcases pass. The sole failure is a
  schedule-sensitive microtask/`asyncHold` score mismatch in the separately
  owned jobs surface. The exact parent reproduces the same failure class in a
  10-seed lifecycle run (559 of 560 pass), while the isolated seed passes five
  candidate repetitions. No Shape, transition, GC, race, crash, or watchdog
  failure occurred.
- Exhaustive allocation-failure injection leaves no half-published lookup or
  transition root. Deep delete/re-add preserves the original stable slot and
  immediate undo shape.
- A 4,096-property object survives re-entrant collection and real moving
  compaction under a 32 MiB heap limit.
- Object, Array-prototype, and Proxy test262 subtrees pass 6,532 cases in both
  revisions with zero flips and nonzero denominators.

The remaining 1/2/4/8-lane transition-throughput publication is kept visible
on #530 rather than inferred from the four-lane functional/TSan witness.
