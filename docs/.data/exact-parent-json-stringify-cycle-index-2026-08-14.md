# JSON.stringify active-cycle identity index — exact-parent evidence (2026-08-14)

Order-balanced exact-parent diagnostic for [#556](https://github.com/zig-utils/zig-js/issues/556).

- parent: `4be2bc64c995d43a778294b1b99e1ff07656e1d2`
- candidate: `63d054374b1398ce627c16782748ed9f514d04ec`
- source: `bench/representative_comparison.js`
- host: Apple M3 Pro, macOS 27.0.0, arm64
- power: AC power, charging; every sample recorded `nominal->nominal` thermal state
- sampling: seven alternating fresh-process pairs per row, no discarded samples
- mode/jobs: `single`, one scored job after ten one-job warmups
- identity: every runner, source, dependency, mode, job, output, and checksum identity matched

| workload | parent wall | candidate wall | wall ratio | median process CPU parent → candidate | parent instructions | candidate instructions | instruction ratio | candidate / parent peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| acyclic depth 512 | 0.695 ms | 0.672 ms | 0.968× | 10 → 0 ms | 7,873,667 | 7,763,338 | 0.9860× | 1.0062× |
| acyclic depth 1,024 | 1.839 ms | 1.831 ms | 0.995× | 20 → 20 ms | 20,980,658 | 19,481,960 | 0.9286× | 1.0027× |
| acyclic depth 2,048 | 5.992 ms | 5.595 ms | 0.934× | 70 → 60 ms | 64,189,683 | 55,900,332 | 0.8709× | 1.0015× |
| acyclic depth 4,096 | 19.916 ms | 18.131 ms | 0.910× | 240 → 210 ms | 216,536,198 | 178,683,094 | 0.8252× | 1.0009× |
| real cycle depth 4,096 | 3.823 ms | 1.612 ms | 0.422× | 40 → 10 ms | 59,457,654 | 21,927,790 | 0.3688× | 1.0476× |
| shallow repeated alias width 4,096 | 2.641 ms | 2.656 ms | 1.006× | 30 → 30 ms | 47,795,317 | 48,388,213 | 1.0124× | 1.0005× |

The deep real-cycle row isolates active-ancestor membership because it throws at
the back-edge before copying a successful nested result back through every
ancestor. Its 0.3688× retired-instruction ratio is the clearest causal signal
that the indexed path removes the former linear scan at every depth. The
acyclic rows retain identical complete output and show progressively larger
instruction reductions as depth increases.

The shallow control never promotes the index: each repeated object is removed
before its sibling is visited, so active depth stays two. Its 1.0124×
instruction and 1.006× wall ratios keep common shallow aliasing neutral while
also proving the implementation did not substitute a global visited set.

Wall dispersion is too high for a stable latency claim on several sub-20 ms
rows, so wall values remain diagnostic. Retired instructions are the causal
decision metric. Process CPU is the median sum of `/usr/bin/time -l` user and
system observations and retains that source's 10 ms granularity; cycles and
energy are retained with their exact availability and dispersion in each raw
artifact. The 4K acyclic peak RSS reflects a separate nested-output copying
cost and is not attributed to the bounded cycle index.

## Row artifacts

- [depth 512 report](exact-parent-json-stringify-depth-512-2026-08-14.md) · [raw JSON](exact-parent-json-stringify-depth-512-2026-08-14.json)
- [depth 1,024 report](exact-parent-json-stringify-depth-1024-2026-08-14.md) · [raw JSON](exact-parent-json-stringify-depth-1024-2026-08-14.json)
- [depth 2,048 report](exact-parent-json-stringify-depth-2048-2026-08-14.md) · [raw JSON](exact-parent-json-stringify-depth-2048-2026-08-14.json)
- [depth 4,096 report](exact-parent-json-stringify-depth-4096-2026-08-14.md) · [raw JSON](exact-parent-json-stringify-depth-4096-2026-08-14.json)
- [real cycle report](exact-parent-json-stringify-cycle-4096-2026-08-14.md) · [raw JSON](exact-parent-json-stringify-cycle-4096-2026-08-14.json)
- [shallow repeated-alias control](exact-parent-json-stringify-shallow-4096-2026-08-14.md) · [raw JSON](exact-parent-json-stringify-shallow-4096-2026-08-14.json)
