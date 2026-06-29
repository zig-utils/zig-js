# Thread Testing

Thread support is verified with Zig `0.17-dev`. The package declares this in
`build.zig.zon`, and the build options below use the Zig 0.17 build API.

## Required Checks

Run the fast local gates before changing thread behavior or docs:

```sh
zig build test
zig build threads-test
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=sync/condition-wait-notify.js
zig build test -Dtsan=true
zig build test -Dtsan=true -Dtest-filter=parallel_js
zig build threadfuzz -Dfuzz-iters=20
zig build threadfuzz -Dfuzz-midgc=true -Dfuzz-iters=5
zig build threadfuzz -Dfuzz-lifecycle=true -Dfuzz-iters=20
zig build threadfuzz -Dfuzz-verify=true -Dfuzz-iters=300
bun run docs:build
```

For performance work, also run:

```sh
zig build threads-profile
zig build gc-profile
```

These profiles are not correctness gates. `threads-profile` is the local
contention baseline for comparing the no-GIL default against `.gil = true`
across the hot shared structures named in the production roadmap. `gc-profile`
is the local allocation/lifecycle baseline for comparing arena, explicit-GC,
no-GIL threaded GC, and `.gil = true` context modes, including the reusable
GC-cell slab backing.

CI additionally runs heavier no-GIL production gates on every pull request and
push to `main`:

```sh
zig build threadfuzz -Dfuzz-iters=400
zig build threadfuzz -Dtsan=true -Dfuzz-iters=60
zig build threadfuzz -Dfuzz-amplify=true -Dfuzz-iters=30
zig build threadfuzz -Dfuzz-broad=true -Dfuzz-iters=80
zig build threadfuzz -Dfuzz-midgc=true -Dfuzz-iters=20
zig build threadfuzz -Dfuzz-lifecycle=true -Dfuzz-iters=60
zig build threadfuzz -Doptimize=ReleaseSafe -Dfuzz-iters=400
zig build threadfuzz -Dfuzz-verify=true -Dfuzz-iters=300
zig build threads-test-bin -Dtsan=true
./zig-out/bin/threads-test parallel-js one <allowlisted-case>
```

The corpus TSan sweep is sharded in CI and runs each allowlisted case in its own
process to avoid TSan shadow-memory growth across a single long run. It fails on
engine-state races. JS-defined program-byte races are covered by narrow
suppressions plus a suppression witness that proves the suppressions are both
load-bearing and not hiding engine-state frames. The witness is
`tools/tsan-suppression-witness.sh`; run it after building
`threads-test-bin -Dtsan=true` when changing `tsan-suppressions.txt`, raw
TypedArray/shared-buffer access helpers, or the memory-model boundary.

## What Each Gate Covers

`zig build test` runs unit and C-API tests, including agents, workers, shared
buffers, property-mode Atomics, `Thread`, `Lock`, `Condition`, `ThreadLocal`,
parallel-GC witnesses, C embedder threading, and the main can-block gate.

`zig build threads-test` runs the green WebKit PR-249 allowlist from
`reference/webkit-249/threads-tests`. The current allowlist is 219/219 and
covers:

- `api/` and `lifecycle/`: constructor shape, lifecycle, ids, constructor
  errors, exceptions, restriction, return values, join semantics, blocking
  gates, lock/condition basics, async lock/condition behavior, thread-local
  storage, termination watchdogs, and `Thread.restrict`.
- `arrays/` and `shared-objects/`: shared identity, dense elements, holes,
  push/resize interleavings, typed arrays over `SharedArrayBuffer`, property
  reads/writes/adds/deletes, accessors, prototype chains, frozen/sealed
  objects, and dictionary-mode objects.
- `atomics/` and `sync/`: property load/store/RMW/CAS, wait/notify,
  waitAsync timeout behavior, typed-array lane guardrails, mutex-style
  counters, condition handshakes, notify-all behavior, and thread-local
  isolation.
- `races/`, `invariants/`, `objectmodel/`, and `semantics/`: transition
  interleavings, lost-property/element prevention, shape/storage invariants,
  private fields, regexp/date/string/symbol shared state, IC-vs-transition
  cases, and termination storms.
- `heap-*`, `gc-stress/`, and `cve/`: heap option/epoch/deferral/stress
  drivers, parked-frame/root witnesses, teardown/lifecycle hazards,
  waiter-table reclamation, FinalizationRegistry delivery, buffer/SAB lifetime,
  and no-WebAssembly premise/refusal witnesses.
- `bench/`, `scaling/`, `jit/`, and `vmstate/`: deterministic checksum
  coverage, independent-work scaling witnesses, tree-walker-compatible JIT audit
  files, per-thread exception/regexp/stack/structure state, and flag identity
  checks.

`zig build threads-test -Dthreads-parallel-js=true` runs the allowlist through
the same no-GIL path that `enable_threads` uses by default. CI's TSan sweep uses
`threads-test-bin -Dtsan=true` and invokes each case with `parallel-js one`.

`zig build threadfuzz` generates random programs that share objects, arrays,
closures, constructors, Maps/Sets, accessors, and typed arrays across JS
`Thread`s in a parallel context. The default oracle is "no unexpected throw,
deadlock, UAF, or engine race"; `-Dtsan=true` turns unsynchronized engine access
into a race report; `-Dfuzz-amplify=true` raises contention; `-Doptimize=ReleaseSafe`
keeps safety checks under optimization; `-Dfuzz-verify=true` generates
deterministic atomic programs whose exact result is predicted. The broad profile
(`-Dfuzz-broad=true`) enables GC and adds caught exception/finally paths, nested
thread lifecycle, `asyncJoin`, property `wait` / `waitAsync`, `Condition`
wakeups, `Thread.restrict`, and `FinalizationRegistry` cleanup sidecars. The
mid-script GC profile (`-Dfuzz-midgc=true`) uses the internal testing context to
enable `parallel_midscript_gc`, blocks peers in property `Atomics.wait`,
`Condition.wait`, and contended `Lock` acquisition, queues a FIFO async-hold
grant chain plus async condition reacquire grants through those pump points,
then requires exact script completion plus at least one finishing parallel sweep
and exact
`FinalizationRegistry` cleanup count/sum delivery after a quiescent collect. The
lifecycle profile
(`-Dfuzz-lifecycle=true`) adds expected-throw termination storms for
parked/unjoined shared-realm `Thread`s, exact Atomics counter oracles for script
`Worker` plus simple-import, diamond-shaped, and fanout/rejoin module `Worker`
overlap with shared-realm `Thread`s on one retained `SharedArrayBuffer`, and
mixed `close` / `terminate` / `postMessage` ordering coverage plus worker
handler-exception recovery after a thrown `onmessage`, Thread exception identity
through `join()` / `asyncJoin()` while property and condition waiters are
parked, thread-returned typed-array `waitAsync` promise assimilation through
`join()` / `asyncJoin()` while waiters are parked, and cross-thread
`FinalizationRegistry` cleanup count/sum oracles, cleanup delivery interleaved
with `join()` / `asyncJoin()` and unregister-token suppression, plus
`ThreadLocal` isolation across normal, throwing, nested, and async-joined thread
lifecycles. Each seed currently runs 12 deterministic lifecycle subprograms.

`zig build test262 -Dtest262-parallel-js=true` runs test262 programs in
GIL-free parallel contexts. The full corpus is too slow for every PR, so CI
uses a curated representative slice and asserts no new failures versus the
baseline arena engine.

`zig build threads-reference-audit` scans the vendored PR-249 corpus and fails
if any non-allowlisted executable file lacks an explicit reference-only blocker
classification. This keeps shell-hook, WebAssembly, JIT, deep-stack, and
heap-cap gaps visible without inflating the green allowlist with no-op passes.

`zig build threads-profile` is not a pass/fail correctness gate. It is the local
scaling and contention profiler for issue #1. The wall-clock columns compare the
no-GIL default with `.gil = true` across independent compute, shared object
properties, shared array append, typed-array Atomics, property `Atomics.wait` /
`notify`, `Condition.wait` / `notifyAll`, contended `Lock.hold`,
`Lock.asyncHold` delivery, and thread lifecycle churn. Its opt-in counters let
`events` count logical contention in `Lock`/`Condition`/property waits and
queued `asyncHold` grants, and `parks` count timed wait/pump iterations
including `Thread.join`.
The `empty`/`jobs` columns split the run-loop task pump into empty atomic
fast-path hits and real async-hold job delivery. Run it before and after
synchronization or lifecycle changes so performance work has an attributed
baseline instead of only elapsed time. Empty sync-wait task pumps now have a
lock-free fast path;
real async-hold delivery drains bounded FIFO bursts from the realm task queue
under one API-lock acquisition before running grants outside that lock;
`threads-profile` remains the check that this kind of targeted optimization does
not merely move overhead elsewhere.

## Focused Runs

Use `-Dthreads-case=<path>` to run one vendored thread test. A comma-separated
list runs a mini-sequence in one runner process, useful for order-dependent
teardown or scheduler debugging:

```sh
zig build threads-test -Dthreads-case=api/thread-basic.js
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build threads-test -Dthreads-case=api/lock-basic.js,atomics/property-wait-notify.js
```

Add `-Dthreads-parallel-js=true` to force the no-GIL path explicitly:

```sh
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=sync/condition-wait-notify.js
```

Use `-Dthreads-sweep=true` to run every file in the original default-gate
directories (`api/`, `arrays/`, `atomics/`, `bench/`, `lifecycle/`, `races/`,
`scaling/`, `shared-objects/`, and `sync/`). Sweep mode is narrower than the
promoted allowlist because it does not scan root files or promoted
invariants/objectmodel/semantics/vmstate subsets:

```sh
zig build threads-test -Dthreads-sweep=true
zig build threads-test -Dthreads-sweep=true -Dthreads-parallel-js=true
```

For fuzzer reproduction:

```sh
zig build threadfuzz-bin
./zig-out/bin/threadfuzz file /path/to/repro.js
```

## Remaining Reference-Only Areas

The default corpus is intentionally not a "run every file" mode. Remaining
PR-249 files stay reference-only for concrete reasons:

- WebAssembly-required CVE files remain out until this engine has the matching
  WebAssembly construction, compilation, relocation, and grow behavior.
- JIT/CVE files that require JSC-specific code artifact hooks, ASAN controls,
  stop counters, disassembly controls, or retired-artifact machinery remain out
  until real engine behavior backs those hooks.
- `semantics/stack-overflow-per-thread.js` expects thousands of recursive calls
  before catchable overflow. The tree-walker still uses native recursion, so
  this needs iterative/trampolined calls or a VM-stack execution path.
- `cve/mc-spec-timer-capability.js` needs SharedArrayBuffer-off option modeling
  and timing semantics beyond today's shell surface.
- `semantics/oom-one-thread.js` remains out until there is a real heap cap and
  per-thread OOM handling contract.
- Helper/preload files such as `harness.js`, `bench/harness.js`,
  `scaling/harness.js`, `resources/assert.js`, and
  `vmstate/resources/workload.js` are not counted as standalone remaining
  tests.

Promote a reference-only file only when the engine implements the behavior, the
file passes reliably under Zig `0.17-dev`, and the docs/issue counts are updated
in the same change.

Run the reference audit after promotion attempts:

```sh
zig build threads-reference-audit
python3 tools/threads-reference-audit.py --format markdown
```

## Docs Checks

```sh
bun run docs:build
rg '[2]7/[2]7|[3]0/[3]0|[5]4/[5]4|[6]9/[6]9|13[0]/13[0]|14[0]/14[0]|16[8]/16[8]|17[6]/17[6]|18[2]/18[2]|18[3]/18[3]|18[4]/18[4]|18[6]/18[6]|18[7]/18[7]|18[8]/18[8]|19[347]/19[347]|20[3]/20[3]|threads-test -[-]' README.md docs bunpress.config.ts
```

The search should find no stale partial allowlist counts and no removed
thread-test pass-through command syntax. Use `-Dthreads-case` and
`-Dthreads-sweep`.

## When Adding Thread Work

- Add or update focused unit tests for narrow engine behavior.
- Add or update PR-249 corpus coverage when the behavior is externally
  observable.
- Add fuzzer generation or deterministic fuzzer oracles when the behavior can
  be randomized.
- Update [bindings.md](./bindings.md) for every new file-scope mutable `var`,
  `pub var`, `threadlocal`, or container-scope mutable static.
- Re-run ThreadSanitizer before merging changes that affect waiters, shared
  buffers, workers, GC roots/barriers, task queues, C handles, or cross-thread
  value/state publication.
- Keep [GitHub issue #1](https://github.com/zig-utils/zig-js/issues/1) and these
  docs aligned whenever behavior, counts, or blockers change.
