# JSON.stringify nested-output streaming — exact-parent evidence (2026-08-14)

Order-balanced exact-parent diagnostic for [#558](https://github.com/zig-utils/zig-js/issues/558).

- parent: `ac9dc52bee6f44411fa377a6e2618d5458df821f`
- candidate: `3ec9847fa69afac69c321ae935ad619c99b2d72e`
- source: `bench/representative_comparison.js`
- host: Apple M3 Pro, macOS 27.0.0, arm64
- Zig: `0.17.0-dev.1441+d5181a9c9`
- power: AC power, charging
- thermal: every depth row recorded `fair->fair`; the shallow and real-cycle controls recorded `nominal->nominal`
- sampling: seven alternating fresh-process pairs per row, no discarded samples
- mode/jobs: `single`, one scored job after ten one-job warmups
- identity: every runner, source, dependency, mode, job, output, and checksum identity matched

| workload | parent wall | candidate wall | wall ratio | median process CPU parent -> candidate | parent peak RSS | candidate peak RSS | RSS ratio | parent instructions | candidate instructions | instruction ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| acyclic depth 512 | 0.845 ms | 0.374 ms | 0.442x | 10 -> 0 ms | 61,538,304 | 21,168,128 | 0.3440x | 7,781,847 | 5,384,101 | 0.6919x |
| acyclic depth 1,024 | 2.165 ms | 0.702 ms | 0.324x | 20 -> 10 ms | 184,811,520 | 26,116,096 | 0.1413x | 19,555,766 | 10,546,423 | 0.5393x |
| acyclic depth 2,048 | 5.788 ms | 1.244 ms | 0.215x | 60 -> 10 ms | 665,190,400 | 36,438,016 | 0.0548x | 55,883,794 | 21,004,531 | 0.3759x |
| acyclic depth 4,096 | 33.227 ms | 2.952 ms | 0.089x | 270 -> 30 ms | 1,836,728,320 | 57,098,240 | 0.0311x | 179,392,635 | 42,001,313 | 0.2341x |
| shallow repeated alias width 4,096 | 2.626 ms | 2.585 ms | 0.984x | 30 -> 30 ms | 62,717,952 | 49,725,440 | 0.7928x | 48,395,773 | 46,763,359 | 0.9663x |
| real cycle depth 4,096 | 1.566 ms | 1.672 ms | 1.068x | 20 -> 20 ms | 56,639,488 | 56,492,032 | 0.9974x | 21,772,891 | 22,601,866 | 1.0381x |

The successful acyclic rows isolate the former recursive copy: output bytes and
topology are identical, while the instruction ratio falls monotonically from
`0.6919x` at depth 512 to `0.2341x` at depth 4,096. At depth 4,096, median peak
RSS falls from 1,836,728,320 bytes to 57,098,240 bytes (`0.0311x`). The widening
gap is consistent with replacing a descendant-suffix copy at every ancestor
with one authoritative output buffer and exact omission rollback.

The shallow repeated-alias control remains neutral in wall and process CPU and
improves slightly in retired instructions. It serializes the same 4,096 legal
sibling aliases without deep successful unwind. The real-cycle control throws
at the back-edge before any successful nested result unwinds; its peak RSS and
process CPU remain neutral, while its `1.0381x` instruction ratio is below the
repository's 10% material-regression threshold. Together the controls bound the
result to successful nested-output construction rather than input recognition,
cycle handling, or reduced work.

Wall dispersion is too high for a stable latency claim on several short rows,
and the depth rows ran at the host's `fair` thermal state, so wall values remain
diagnostic. Retired instructions and peak RSS are the causal decision metrics.
Process CPU is the median sum of `/usr/bin/time -l` user and system observations
and retains that source's 10 ms granularity. Cycles, energy availability,
thermal state, and dispersion are retained in each raw artifact; no unavailable
counter is represented as a measured zero.

## Row artifacts

- [depth 512 report](exact-parent-json-stringify-output-depth-512-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-output-depth-512-2026-08-14.json)
- [depth 1,024 report](exact-parent-json-stringify-output-depth-1024-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-output-depth-1024-2026-08-14.json)
- [depth 2,048 report](exact-parent-json-stringify-output-depth-2048-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-output-depth-2048-2026-08-14.json)
- [depth 4,096 report](exact-parent-json-stringify-output-depth-4096-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-output-depth-4096-2026-08-14.json)
- [shallow repeated-alias control](exact-parent-json-stringify-output-shallow-4096-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-output-shallow-4096-2026-08-14.json)
- [real-cycle control](exact-parent-json-stringify-output-cycle-4096-2026-08-14.md) - [raw JSON](exact-parent-json-stringify-output-cycle-4096-2026-08-14.json)
