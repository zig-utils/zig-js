---
name: nogil-threading
description: Work on zig-js GIL-free shared-realm threading — data races, ThreadSanitizer reports, the PR-249 thread corpus, threadfuzz profiles, the no-GIL promotion gate, and parallel-GC root safety. Use when the task mentions threads, no-GIL, GIL, TSan, races, threadfuzz, PR-249, parallel_js, Atomics/Lock/Condition, or a hang/UAF that only reproduces under concurrency.
---

# No-GIL threading and race work

zig-js runs shared-realm `Thread`s **truly in parallel by default**; `.gil =
true` is the serialized compatibility mode. This is issue #1, and its rules are
binding. Read [`docs/threads/index.md`](../../../docs/threads/index.md) and
[`docs/threads/memory-model.md`](../../../docs/threads/memory-model.md) before
changing synchronization.

## 1. The contract you must not break

- **JavaScript program races are permitted. Engine-state races are not.** That
  distinction is the whole memory model; a TSan suppression encodes a decision
  about which side of it a report falls on.
- Object shapes, named properties, elements/collections, environments, promises,
  microtasks, inline caches, thread records, waiter queues, and shared-buffer
  storage each have explicit synchronization. **New mutable shared state must
  follow that pattern.**
- Process-global mutable state must appear in
  [`docs/threads/bindings.md`](../../../docs/threads/bindings.md) with a
  `per-thread`, `locked`, or `refused` ruling.
- `parallel_js` and `parallel_midscript_gc` are **test-only harness knobs**, not
  embedder API.

## 2. Fast iteration loop

Building the corpus binary is far cheaper than the unit suite:

```bash
zig build threads-test-bin              # ~40 s
zig-out/bin/threads-test one <case.js>               # serialized (GIL)
zig-out/bin/threads-test parallel-js one <case.js>   # no-GIL
zig-out/bin/threads-test list
```

Via the build system:

```bash
zig build threads-test
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=sync/condition-wait-notify.js
zig build threads-test -Dthreads-shard-index=0 -Dthreads-shard-count=4
zig build threads-test -Dthreads-inventory=/tmp/exec.json      # machine-readable results
zig build threads-reference-audit threads-reference-probes
```

## 3. Fuzzing — seeded, therefore a gate

`threadfuzz` generates random concurrent programs that share objects, arrays,
closures, and typed arrays across JS `Thread`s. It is **seeded and
deterministic**, so a failure is a real bug, not a flake. It found the
call-dispatch and frame-slot-rooting bugs.

```bash
zig build threadfuzz -Dfuzz-iters=400                       # default profile
zig build threadfuzz -Dfuzz-amplify=true  -Dfuzz-iters=30   # 6-14 threads, 5000-iter loops
zig build threadfuzz -Dfuzz-broad=true    -Dfuzz-iters=80   # exceptions, nested lifecycle, asyncJoin
zig build threadfuzz -Dfuzz-midgc=true    -Dfuzz-iters=20   # mid-script parallel GC under parked waiters
zig build threadfuzz -Dfuzz-lifecycle=true -Dfuzz-iters=60  # termination storms, Worker/Thread overlap
zig build threadfuzz -Dfuzz-verify=true   -Dfuzz-iters=300  # exact-value oracle: catches torn/lost updates
zig build threadfuzz -Dfuzz-seed=<n> -Dfuzz-iters=1         # replay one seed
```

Under TSan use small iteration counts (~10× slowdown) and raise the per-seed
watchdog where the profile needs it:

```bash
zig build threadfuzz -Dtsan=true -Dfuzz-iters=60
THREADFUZZ_SEED_TIMEOUT_MS=300000 zig build threadfuzz -Dtsan=true -Dfuzz-midgc=true -Dfuzz-iters=2
zig build threadfuzz -Dtsan=true -Dfuzz-lifecycle=true -Dfuzz-iters=2
```

`-Doptimize=ReleaseSafe` is a **different bug class** from TSan: it keeps Zig's
safety checks on under the optimizer and catches codegen-dependent faults the
Debug build hides. Run both.

## 4. ThreadSanitizer

```bash
zig build test -Dtsan=true
zig build test -Dtsan=true -Dtest-filter=parallel_js
```

Reading a report:

- **"Still fails WITH suppressions" is not automatically a TSan abort.** Read
  the actual `FAIL` line — it is frequently the case's own functional assertion
  (e.g. a use-after-free the test checks for), which is a different bug.
- Before widening a lock, check whether the witness *depends* on the suppressed
  race. Some suppressions are load-bearing: for `ArrayBuffer` resize, lock the
  **bulk** buffer copies (`Atomics` ops, `copyWithin`, `slice`) against resize,
  but do **not** lock `DataView` — that race is accepted and suppressed, and the
  witness relies on it. Do not narrow `needsElementLock` to "fix" it.
- The recurring fix pattern for a plain shared field raced cross-thread: make it
  atomic, use `.monotonic` unless you need stronger ordering, and make every
  access site go through the atomic accessor so the compiler enforces it.

## 5. The no-GIL promotion gate

A PR-249 case is only promoted when it passes **both** modes, and the no-GIL run
must finish inside the gate's budget. Several cases are ~20× slower with the GIL
off, so "it passes in GIL mode" is not promotion evidence — promoting such a
case breaks CI.

```bash
python3 tools/nogil-corpus-gate.py                       # full functional gate
python3 tools/nogil-corpus-gate.py --shard 0 --shards 4
python3 tools/nogil-corpus-gate.py --deadline 600 --build-mode releasesafe
```

The gate compares against `docs/.data/pr249-execution-nogil.json`:

- baseline `pass` that now fails → **regression, fails the gate**;
- baseline non-passing that still fails → reported, does not fail;
- **unknown to the baseline → must pass**, so a newly promoted case earns its
  place rather than inheriting an exemption by absence;
- a case that starts passing is reported — the baseline is stale, refresh it.

Build mode is part of the expectation; Debug and ReleaseSafe have different
timing profiles.

`tools/threads-reference-audit.py` keeps the unpromoted set honest: every
non-helper JS file outside the promoted allowlists must carry either an
implementation blocker or a structured terminal disposition. A blocked case that
happens to pass a probe is **not** promoted — probe each case in its *declared*
mode.

## 6. Running these safely

- **Never run two corpus jobs at once.** Some drivers reap survivors with
  `pkill -f zig-out/bin/threads-test` and will kill the other run's cases, which
  are then recorded as failures or timeouts. `tools/nogil-corpus-gate.py` reaps
  only its own process group; ad-hoc scripts usually do not. Check
  `pgrep -f 'zig-out/bin/threads-test'` is empty first.
- Do not run corpus cases beside the unit suite — the suite starves and looks
  hung.
- A "hung" job may be spinning: `sample <pid> 3 -f /tmp/out.txt` on macOS gives
  the recursive stack in seconds.

## 7. Before you call it done

```bash
zig build test-parallel
zig build threads-test
zig build threads-reference-audit threads-reference-probes
zig build test -Dtsan=true -Dtest-filter=parallel_js
zig build threadfuzz -Dfuzz-iters=400
zig build threadfuzz -Dfuzz-verify=true -Dfuzz-iters=300
python3 tools/nogil-corpus-gate.py
```

[`docs/threads/testing.md`](../../../docs/threads/testing.md) holds the complete
Required Checks list and what each gate covers. If you changed the promoted set,
refresh the inventory and the no-GIL baseline in the same commit as the change
that earned it.

Do not commit `reference/webkit-249/threads-tests/*` or `docs/threads/*` unless
that is explicitly your assignment — a separate actor stages those concurrently.
Stage explicit paths.
