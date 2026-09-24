# RegExp compiled-program retention diagnostic

Measured 2026-09-25 local time (2026-09-24 UTC). This is a **Debug memory
diagnostic**, not a throughput benchmark or JavaScriptCore comparison. It
investigates [issue #989](https://github.com/zig-utils/zig-js/issues/989): the
unchanged pinned test262 case
`test/built-ins/RegExp/character-class-escape-non-whitespace.js` exceeded the
repository's 3072 MiB process-tree guard before the fix. The candidate completes
that case without changing the input, assertions, execution mode, GC setting,
or guard.

## Evidence and revisions

- [Raw evidence bundle](regexp-retention-2026-09-25.json), including all 56
  memory samples, complete corpus receipts, source inventories, binary and
  source hashes, controller snapshots, failed-attempt logs, LLDB output, and
  exhaustive-run logs.
- Exact engine baseline: `0d0bb75cb89f3ee1c96963df82288c1fdc4fa741`.
- Candidate: `517a53855356a5226aa222e2860ed9274c70a61f`, the baseline's direct child.
- zig-regex: `601edb49ba0579f1a30e4318290a7d7fb919aeed` on both sides.
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3` on both sides; the real
  collector checkout, not the local non-collecting stub.
- test262: `4249661388e5d3f92a85186213da140a6481490f`.
- Zig `0.17.0-dev.1441+d5181a9c9`, Debug; Apple M2 Pro, 16 GiB; macOS
  26.3.1 (a), build 25D771280a.

All heavy work ran sequentially through the shared machine lock with the
existing 3072 MiB process-tree ceiling. The collection happened on battery and
this desktop was not qualified as a quiet reference host. These facts do not
invalidate a retained-footprint diagnosis, but they exclude timing or energy
claims.

## Cause and fix boundary

The upstream case constructs a fresh `/\S+/g` object in each iteration.
JavaScript requires fresh RegExp object identity and independent `lastIndex`;
it does not require recompiling an identical immutable regex program. The
baseline eagerly compiled every object into the Context arena and keyed matcher
scratch by each distinct program pointer. An LLDB checkpoint observed 254
matcher-cache entries early in the failing case. A separate allocation probe
recorded arena capacity before compilation and after initial matching.

The candidate adds a bounded 64-entry, interpreter-local source-and-flags
lookup for immutable Thompson programs, including immutable one-pass plans.
Backtracking programs are excluded because the dependency embeds mutable search
state in them. Each JavaScript evaluation still allocates a fresh RegExp object;
matcher scratch remains interpreter-local; `.compile()` replaces only the
receiver's slots; eviction removes a lookup entry rather than a live program.
Invalid patterns still compile and throw through the ordinary path.

This is not a general bound on Context-arena growth. Unique patterns deliberately
miss the cache, and mutable backtracking programs remain outside it.

## Retained-footprint controls

Four small scripts isolate repeated compilation from matching. Each side ran in
a fresh process, seven samples per side, with alternating order by pair and row.
`/usr/bin/time -l` supplies peak process footprint; all outputs and exact
checksums had to match. No sample was discarded or retried.

| control | exact-parent median | candidate median | candidate / parent | interpretation |
| --- | ---: | ---: | ---: | --- |
| fresh `/\S+/g` plus replace | 186.58 MiB | 12.78 MiB | 0.0685× | repeated immutable compile + match |
| one hoisted `/\S+/g` plus replace | 11.50 MiB | 11.50 MiB | 1.0000× | no repeated compile |
| fresh `/\S+/g`, construction only | 155.94 MiB | 10.30 MiB | 0.0660× | repeated immutable compile without matching |
| 2,048 unique patterns | 31.98 MiB | 31.98 MiB | 1.0000× | intentional cache-miss control |

The two repeated-identical-program controls retain 93.1% and 93.4% less peak
process footprint. The hoisted and unique-pattern controls are unchanged at the
displayed precision. This isolates duplicate immutable compilation as the
dominant measured domain; it does not establish a universal memory reduction.

## Unchanged upstream case

The exact baseline was rebuilt and run against the unchanged upstream case. It
was terminated by the same 3072 MiB guard after a sampled process-tree reading
of 3249 MiB, so it has neither a completed testcase outcome nor a valid peak.
The candidate completed the case three additional times. Every run emitted
`0:p` and `DONE`, and every run reported the same 145,818,056-byte (139.06 MiB)
peak process footprint.

The guard's sampled process-tree reading can overshoot its ceiling and counts
shared pages more than once. It is not comparable to `/usr/bin/time -l`'s
per-process peak. Consequently this report does **not** calculate a baseline to
candidate ratio from the killed baseline run.

## Conformance qualification

The candidate completed an inventoried 2,456-case affected corpus:

| subtree | completed | positive / negative |
| --- | ---: | ---: |
| `test/built-ins/RegExp` | 1,879 / 1,879 | 1,687 / 192 |
| `test/language/literals/regexp` | 238 / 238 | 52 / 186 |
| six `String.prototype` RegExp integration subtrees | 339 / 339 | 339 / 0 |

The audit also compared 70 Annex B cases on the exact baseline and candidate,
for 2,526 candidate cases in the complete qualification boundary. All cases
completed. The prior #988 candidate receipts supply outcomes for 1,878 baseline
RegExp cases only after the audit verified byte-identical engine/runner sources,
the same corpus revision, and the same dependency pins. Candidate outcomes
matched every previously completed baseline outcome; the one previously
resource-incomplete case, index 1648, now passes. Observed completed-case
regressions: zero.

Four cache unit tests, 30 focused runtime cases, an 18-check semantic fixture
against Node and both zig-js execution tiers, and a direct-root interpreter
test also passed. The semantic checks cover fresh object identity, independent
`lastIndex`, `.compile()`, eviction, invalid patterns, and the mutable
backtracking exclusion.

## Reproduce

Build the exact revisions and use the pinned corpus. Run the unchanged case by
path so traversal order cannot change the selected test:

```sh
HOME_RUN_MAX_MB=3072 HOME_RUN_LOCK="$HOME/.cache/home-run.lock" \
  perl ../home/scripts/run-bounded.pl 300 /usr/bin/time -l \
  /path/to/test262 --worker \
  test/built-ins/RegExp/character-class-escape-non-whitespace.js 0 1
```

A successful positive case must emit both `0:p` and `DONE`. Empty output, a
timeout, or guard termination is not a pass. The raw bundle preserves the exact
collector and qualification controllers with their original host paths; adjust
those paths when replaying elsewhere rather than treating them as portable
defaults.
