# Thread Testing

Thread support is verified with Zig `0.17-dev`. The package declares this in
`build.zig.zon`, and the build options below use the Zig 0.17 build API.

## Required Checks

```sh
zig build test
zig build threads-test
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build test -Dtsan=true
bun run docs:build
```

`zig build test` runs the unit and C-API suite, including focused tests for
agents, workers, shared buffers, property-mode Atomics, `Thread`, `Lock`,
`Condition`, `ThreadLocal`, and the main can-block gate.

`zig build threads-test` runs the green WebKit PR-249 allowlist from
`reference/webkit-249/threads-tests`. The current allowlist is 168/168 and
covers:

- `smoke.js`: the root shared-realm sanity check.
- `api/` and `lifecycle/`: constructor shape, lifecycle, ids, constructor
  errors, exceptions, restriction, return values, join semantics, blocking
  gates, lock/condition basics, async lock/condition behavior, thread-local
  storage, and termination watchdog cases.
- `arrays/` and `shared-objects/`: shared identity, array elements, holes,
  push/resize interleavings, typed arrays over `SharedArrayBuffer`, property
  reads/writes/adds/deletes, accessors, prototype chains, frozen/sealed
  objects, and dictionary-mode objects under the context GIL.
- `bench/`: deterministic benchmark checksum coverage for inline property
  reads/writes, array-element reads/writes, flat-butterfly reads/writes,
  megamorphic access, and transition-heavy construction. The corpus runner
  validates correctness only; `zig build bench` owns timing baselines.
- `cve/`: the green GIL-compatible safety subset for code invalidation windows,
  data-format transitions, SAB lifetime churn, handler/teardown ordering,
  generator/async-generator claims, re-entrant coercion order, missing-indexed
  define races, date/rope tear checks, atom identity, LLInt cache churn,
  multislot clone behavior, and property-wait lost-wakeup protection.
- `atomics/`: property load/store, RMW, SameValueZero compare-exchange, errors,
  CAS delete/race/storm cases, missing-property store races, wait/notify,
  wait termination, waitAsync timeout behavior, waiter-table isolation, and
  typed-array lane guardrails.
- `sync/`: mutex-style counters, asyncHold callback/release behavior, condition
  handshakes, notify-all behavior, and thread-local isolation.
- `races/`: GIL-valid counter, join-storm, transition/read/write interleavings,
  enumerator-cache invalidation, and wait/notify stress cases.
- `heap-option-off.js`: the heap-option-off shell-mode guardrail.
- `invariants/`: all current delete quarantine, lost-property/element,
  time-travel, and torn-shape invariant tests.
- `objectmodel/`: the green GIL-compatible subset of array resize/CAS,
  same-shape add storms, first-install races, shared-double writes,
  single-thread flag-on/off identity, stale-spine growth, convert/grow reads
  across requested GC, delete-quarantine re-adds across requested GC, visit-range
  out-of-line coverage, forced-storage stress workloads, and named-vs-indexed
  first-install coverage.
- `semantics/`: atom/string/date/regexp/symbol shared-state checks, private
  field/method brand identity across threads, plus the green IC-vs-transition
  matrix entries.
- `scaling/`: checksum-correct independent-work workloads plus the lock
  fairness/starvation envelope. The default corpus validates correctness and
  liveness; the external scaling gate still owns speedup thresholds.
- `vmstate/`: flag-off / VMLite / all-thread-flags identity, per-thread
  exception state, microtask ordering, regexp churn, stack limits, and
  structure churn/lock identity checks.

`zig build test -Dtsan=true` builds the unit suite under ThreadSanitizer. This
is the concurrency gate for shared-buffer storage, agent waiters, workers, and
the shared-realm GIL path.

The runner models PR-249 command-line options with `Context.Options`:
`blocking-gate.js` runs with `.main_can_block = false`,
`thread-id-bounds.js` runs with `.max_js_threads = 4`, and
`*-termination.js` cases run with a 500 ms watchdog whose termination throw is
the passing outcome. Benchmark files preload `bench/harness.js` with
runner-local sizing so the default corpus checks deterministic results without
turning into a timing benchmark. Files that explicitly call the test-shell
`gc()` helper run with `.enable_gc = true`; the helper requests a collection and
the Context services that request at the next quiescent entry point, matching
the M1 collector's root-completeness boundary.

## Focused Runs

Use `-Dthreads-case=<path>` to run a single vendored thread test. A
comma-separated list runs a mini-sequence in one runner process, which is useful
when investigating order-dependent teardown or scheduler behavior:

```sh
zig build threads-test -Dthreads-case=api/thread-basic.js
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
```

Use this when developing one behavior or debugging a regression. The path is
relative to `reference/webkit-249/threads-tests`.

## Sweep Runs

Use `-Dthreads-sweep=true` to run every vendored file in the original
default-gate directories (`api/`, `arrays/`, `atomics/`, `bench/`,
`lifecycle/`, `races/`, `scaling/`, `shared-objects/`, and `sync/`). Harness
libraries such as `bench/harness.js` and `scaling/harness.js` are preloaded when
needed and are skipped as standalone sweep entries:

```sh
zig build threads-test -Dthreads-sweep=true
```

Sweep mode is exploratory and intentionally narrower than the promoted
allowlist because it does not scan root files or promoted
invariants/objectmodel/semantics/vmstate subsets. A file can fail because it
requires machinery outside today's GIL'd tree-walker support, or because it
targets a future Layer-C object-model invariant. Keep the default allowlist
green; promote files only when their behavior is implemented and stable.

## Docs Checks

```sh
bun run docs:build
rg '[2]7/[2]7|[3]0/[3]0|[5]4/[5]4|[6]9/[6]9|13[0]/13[0]|14[0]/14[0]|threads-test -[-]' README.md docs bunpress.config.ts
```

The search should find no stale 27-of-27, 30-of-30, 54-of-54, 69-of-69,
130-of-130, or 140-of-140 counts and no removed thread-test pass-through command
syntax. Use the `-Dthreads-case` and `-Dthreads-sweep` options instead.

## When Adding Thread Work

- Add or update unit tests for narrow engine behavior.
- Add a WebKit PR-249 corpus file to the allowlist only after it passes
  consistently.
- Update [bindings.md](./bindings.md) for every new file-scope mutable `var`,
  `pub var`, `threadlocal`, or container-scope mutable static.
- Re-run the ThreadSanitizer suite before merging any change that affects
  waiters, shared buffers, workers, GIL ownership, or cross-thread task
  delivery.
