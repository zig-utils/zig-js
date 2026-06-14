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
`reference/webkit-249/threads-tests`. The current allowlist is 194/194 and
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
  multislot clone behavior, property-wait lost-wakeup protection, waiter-table
  reclamation under async microtask GC, watchdog delivery under notify storms,
  blocked-native-root GC coverage, thread-shell finalizer storms,
  resizable-tail quarantine checks, and TID recycle storms.
- `gc-stress/`: the green GIL-compatible GC stress subset for parked-frame
  liveness, indexed-prototype bad-time transitions, watchpoint/prototype churn,
  and zombie-canary reuse checks. These use the supported `$vm.gc` /
  `$vm.edenGC` shell hooks, which request the same quiescent M1 collection as
  global `gc()`.
- `jit/`: the green tree-walker-compatible JIT audit subset, including
  deterministic constructor/fire benchmark checksums plus thread semantics for
  tail-call data-IC argument preservation, direct-call relink churn,
  fire-vs-execute and stop-budget smoke coverage, fixed golden-disasm workload
  execution, tag-discipline workload execution, jettison-vs-execute smoke
  coverage, OSR/catch-loop amplification, spawned-thread butterfly stress, and
  TID-tag three-thread behavior. Real `$vm` JIT artifact counters, stop
  counters, disassembly hooks, and ArrayStorage forcing remain outside the
  default corpus until backed by real engine behavior.
- `atomics/`: property load/store, RMW, SameValueZero compare-exchange, errors,
  CAS delete/race/storm cases, missing-property store races, wait/notify,
  wait termination, waitAsync timeout behavior, waiter-table isolation, and
  typed-array lane guardrails.
- `sync/`: mutex-style counters, asyncHold callback/release behavior, condition
  handshakes, notify-all behavior, and thread-local isolation.
- `races/`: GIL-valid counter, join-storm, transition/read/write interleavings,
  enumerator-cache invalidation, and wait/notify stress cases.
- Top-level heap witnesses: `heap-option-off.js` for the option-off shell-mode
  guardrail and `heap-bench-allocation.js` for deterministic allocation-churn
  checksum coverage. The `$vm.sharedHeapTest` heap harness remains outside the
  default corpus until it exercises real shared-heap machinery here.
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

The runner models PR-249 command-line options with
`Context.createWithTestingOptions` and `Context.TestingOptions`:
`blocking-gate.js` runs with `.main_can_block = false`,
`thread-id-bounds.js` runs with `.max_js_threads = 4`, and
`*-termination.js` cases run with a 500 ms watchdog whose termination throw is
the passing outcome. Benchmark files preload `bench/harness.js` with
runner-local sizing so the default corpus checks deterministic results without
turning into a timing benchmark. Files that explicitly call the test-shell
`gc()` helper run with `.enable_gc = true`; the helper requests a collection and
the Context services that request at the next quiescent entry point, matching
the M1 collector's root-completeness boundary. During a microtask drain, a
pending shell GC request is also serviced between jobs once the previous job has
unwound and the remaining jobs are rooted by the queue; shared-realm contexts
still skip collection while any spawned JS thread is actively running. `$vm.gc`
and `$vm.edenGC` are aliases for that same shell request, `$vm.useThreadGIL()`
reports whether the current context is using the shared-realm GIL, and
`$vm.indexingMode()` is a narrow PR-249 compatibility hook for array-mode
feature checks. Other JSC `$vm` hooks, such as `sharedHeapTest`, dictionary
conversion, and code/disassembly controls, are left absent until backed by real
engine behavior.

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

## Remaining Reference-Only Areas

The default corpus is intentionally not a "run every file" mode. Remaining
PR-249 files are held back for specific, observed reasons:

- Heap harness files (`heap-*`) still require real `$vm.sharedHeapTest` C-level
  scenarios; the `$vm` object intentionally does not expose that hook.
- WebAssembly CVE files remain out until WebAssembly construction, compilation,
  and relocating grow surfaces exist in this engine.
- Post-UNGIL JIT/CVE files require true GIL-off parallel mutation, ASAN or JIT
  artifact hooks, stop-the-world counters, or JSC-specific shell controls. They
  are not valid witnesses while the shared realm is serialized by the context
  GIL.
- `jit/ic-publish-reset-loops.js` currently stalls under the tree-walker and
  scheduler envelope; keep it reference-only until it completes reliably.
- `jit/shared-arraystorage-stress.js` self-skips without
  `$vm.ensureArrayStorage`; it is not default coverage until backed by real
  ArrayStorage behavior.
- `semantics/stack-overflow-per-thread.js` expects 2000-deep recursion before
  overflow storming. The tree-walker's native recursion cannot safely meet that
  by raising `max_call_depth` alone; a 4096-depth experiment overflowed the
  host stack in the unit suite. This needs iterative or trampolined calls, or a
  VM-stack execution path.
- `cve/mc-spec-timer-capability.js` needs SharedArrayBuffer-off option modeling
  and true parallel property-Atomics timing. Under the context GIL it is not a
  meaningful timing witness.
- `semantics/oom-one-thread.js` remains out until there is a real heap cap and
  per-thread OOM handling contract.

## Docs Checks

```sh
bun run docs:build
rg '[2]7/[2]7|[3]0/[3]0|[5]4/[5]4|[6]9/[6]9|13[0]/13[0]|14[0]/14[0]|16[8]/16[8]|17[6]/17[6]|18[2]/18[2]|18[3]/18[3]|18[4]/18[4]|18[6]/18[6]|18[7]/18[7]|18[8]/18[8]|19[3]/19[3]|threads-test -[-]' README.md docs bunpress.config.ts
```

The search should find no stale 27-of-27, 30-of-30, 54-of-54, 69-of-69,
130-of-130, 140-of-140, 168-of-168, 176-of-176, 182-of-182, 183-of-183,
184-of-184, 186-of-186, 187-of-187, 188-of-188, or 193-of-193 counts and no
removed thread-test pass-through command syntax. Use the `-Dthreads-case` and
`-Dthreads-sweep` options instead.

## When Adding Thread Work

- Add or update unit tests for narrow engine behavior.
- Add a WebKit PR-249 corpus file to the allowlist only after it passes
  consistently.
- Update [bindings.md](./bindings.md) for every new file-scope mutable `var`,
  `pub var`, `threadlocal`, or container-scope mutable static.
- Re-run the ThreadSanitizer suite before merging any change that affects
  waiters, shared buffers, workers, GIL ownership, or cross-thread task
  delivery.
