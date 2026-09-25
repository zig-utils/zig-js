# RegExp owned-cache retention diagnostic

Measured 2026-09-25 local time. This is a **Debug retained-memory
diagnostic**, not a throughput benchmark or JavaScriptCore comparison. It
closes the ownership gap tracked by
[#990](https://github.com/zig-utils/zig-js/issues/990): after #989 reused
identical immutable programs, distinct programs and their lazy matcher scratch
were still allocated from the Context arena and survived cache eviction.

## Evidence and revisions

- [Raw evidence](regexp-cache-ownership-2026-09-25.json) preserves every
  before/after row, exact checksums, timing fields, binary hashes, dependency
  pins, complete affected-corpus counts, tier receipts, and no-GIL TSan cases.
- Exact baseline: `e3e2ca49119937119d8dbe32bc731f0743a2a5bc`.
- Candidate: `fe0d3260aa1119c59b0cf4eacdc70909bc397a47`.
- zig-regex: `601edb49ba0579f1a30e4318290a7d7fb919aeed`.
- zig-gc for the TSan/no-GIL gate:
  `0285ef801dd221a4ae8e88b31a09ae31627657a3` (the real collector, not the
  local measurement-only shim).
- test262: `4249661388e5d3f92a85186213da140a6481490f`.
- Zig `0.17.0-dev.1441+d5181a9c9`, Debug memory runners; Apple M2 Pro,
  16 GiB; macOS 26.3.1 (a), build 25D771280a.

All heavy commands ran sequentially under the repository's shared machine lock
and 3072 MiB process-tree ceiling. The desktop was not qualified as a quiet
reference host, and each matrix point has one sample. The raw wall/user fields
therefore support no throughput claim.

## Ownership boundary

The candidate keeps at most 64 interpreter-local entries with stable slot
indices. Each entry owns three retained-capacity arenas: immutable compilation,
persistent matcher scratch, and resettable match results. An unpinned eviction
recycles those arenas; pinned entries cannot move, and all-pinned reentrant use
gets a transient owned lease. Immutable Thompson programs remain reusable by
source and flags. Mutable backtracking programs additionally require the stable
RegExp object identity, so their search state is never shared between objects.

Interpreter teardown releases every occupied owner. Failed compilation destroys
or returns the selected owner, and match results reset only their result arena
after consumers have copied captures into JavaScript values. No JavaScript
pattern limit was lowered and no valid pattern is rejected to enforce the
bound.

## Exact-parent memory matrix

Each row is a fresh process. `strings` creates only the unique pattern source;
`construct` also calls `new RegExp(source)`; `match` performs one successful
`.test()` per object. All before/after checksums are exact. Values below are
peak RSS from `/usr/bin/time -l`, in MiB.

| mode | patterns | exact parent | candidate | reduction |
| --- | ---: | ---: | ---: | ---: |
| strings | 512 | 19.06 | 19.11 | -0.2% |
| strings | 2,048 | 20.50 | 20.56 | -0.3% |
| strings | 8,192 | 26.09 | 26.12 | -0.1% |
| strings | 32,768 | 48.64 | 48.67 | -0.1% |
| construct | 512 | 23.61 | 22.95 | 2.8% |
| construct | 2,048 | 36.66 | 26.70 | 27.2% |
| construct | 8,192 | 88.94 | 41.58 | 53.3% |
| construct | 32,768 | 301.64 | 73.34 | **75.7%** |
| match | 512 | 27.30 | 25.08 | 8.1% |
| match | 2,048 | 50.92 | 29.05 | 42.9% |
| match | 8,192 | 145.67 | 44.86 | 69.2% |
| match | 32,768 | 531.52 | 108.28 | **79.6%** |

The 32,768-source string control is unchanged within 0.1%, while construction
retains 228.30 MiB less and construction plus first match retains 423.24 MiB
less. The remaining growth includes the intentionally retained source strings,
fresh JavaScript RegExp objects, and other Context-arena state outside #990's
compiled-program/matcher ownership boundary.

## Correctness and concurrency qualification

- Six cache ownership tests pass, including unpinned arena recycling without
  moving a pinned lease, hot result-arena reuse, mutable-backtracking identity,
  and all-pinned transient ownership.
- Two interpreter integration tests and the linked JIT test pass.
- The unchanged upstream retention witness
  `character-class-escape-non-whitespace.js` emits `0:p` then `DONE` at a
  127 MiB guarded process-tree peak.
- The 8,192-pattern match fixture returns `OK 228266` in both the tree and VM
  tiers.
- All 2,456 affected test262 cases pass in ReleaseFast: 1,879 RegExp built-ins,
  238 regexp literals, and 339 String `match`, `matchAll`, `replace`,
  `replaceAll`, `search`, and `split` cases. There are zero failures.
- A real-collector TSan build passes both no-GIL witnesses with no sanitizer
  report: shared `RegExp.lastIndex` and concurrent RegExp churn.

An earlier full Debug RegExp diagnostic reached its explicit 1,200-second wall
limit after reporting no failure. It is retained as an interrupted attempt, not
called a pass; the complete 1,879-case ReleaseFast run supersedes it for the
affected-subtree gate.

## Reproduce

Generate each fixture from the template embedded in the raw JSON, then run the
exact baseline and candidate Debug binaries in fresh processes:

```sh
/usr/bin/time -lp /path/to/test262 --eval /path/to/fixture.js
```

The complete affected corpus gate is:

```sh
zig build test262-bin -Doptimize=ReleaseFast
zig-out/bin/test262 --diag test/built-ins/RegExp
zig-out/bin/test262 --diag test/language/literals/regexp
```

Run the six `test/built-ins/String/prototype/{match,matchAll,replace,replaceAll,
search,split}` paths as separate diagnostics. Run every build and corpus command
sequentially through `scripts/run-bounded.pl` with `HOME_RUN_MAX_MB=3072`; a
timeout, guard termination, missing denominator, or incomplete worker protocol
is not a pass.
