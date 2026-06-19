# Thread Testing

Thread support is verified with Zig `0.17-dev`. The package declares this in
`build.zig.zon`, and the build options below use the Zig 0.17 build API.

## Required Checks

```sh
zig build test
zig build threads-test
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=sync/condition-wait-notify.js
zig build test -Dtsan=true
zig build test -Dtsan=true -Dtest-filter=parallel_js
bun run docs:build
```

`zig build test` runs the unit and C-API suite, including focused tests for
agents, workers, shared buffers, property-mode Atomics, `Thread`, `Lock`,
`Condition`, `ThreadLocal`, and the main can-block gate.

`zig build threads-test` runs the green WebKit PR-249 allowlist from
`reference/webkit-249/threads-tests`. The current allowlist is 209/209 and
covers:

- `smoke.js`: the root shared-realm sanity check.
- `api/` and `lifecycle/`: constructor shape, lifecycle, ids, constructor
  errors, exceptions, restriction, return values, join semantics, blocking
  gates, lock/condition basics, async lock/condition behavior, thread-local
  storage, `Thread.restrict` foreign-access `ConcurrentAccessError`, and
  termination watchdog cases.
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
  blocked-native-root GC coverage, spawned-conductor FinalizationRegistry
  cleanup delivery, thread-shell finalizer storms,
  resizable-tail quarantine checks, TID recycle storms, and Wasm-class
  premise/refusal witnesses for this engine's no-WebAssembly configuration.
- `gc-stress/`: the green GIL-compatible GC stress subset for parked-frame
  liveness, indexed-prototype bad-time transitions, watchpoint/prototype churn,
  and zombie-canary reuse checks. These use the supported `$vm.gc` /
  `$vm.edenGC` shell hooks, which request the same quiescent M1 collection as
  global `gc()`.
- `jit/`: the green tree-walker-compatible JIT audit subset, including
  deterministic constructor/fire benchmark checksums plus thread semantics for
  tail-call data-IC argument preservation, direct-call relink churn,
  fire-vs-execute, epoch-reclaim, and stop-budget smoke coverage, fixed
  golden-disasm workload execution, tag-discipline workload execution,
  jettison-vs-execute smoke coverage, OSR/catch-loop amplification,
  spawned-thread butterfly stress, TID-tag three-thread behavior, and the
  shared-ArrayStorage stress witness. `$vm.ensureArrayStorage` is implemented
  for this corpus as an explicit request to keep an array on zig-js's generic
  element backing and report that mode through `$vm.indexingMode`; real `$vm`
  JIT artifact counters, stop counters, and disassembly controls remain outside
  the default corpus until backed by real engine behavior.
- `atomics/`: property load/store, RMW, SameValueZero compare-exchange, errors,
  CAS delete/race/storm cases, missing-property store races, wait/notify,
  wait termination, waitAsync timeout behavior, waiter-table isolation, and
  typed-array lane guardrails.
- `sync/`: mutex-style counters, asyncHold callback/release behavior, condition
  handshakes, notify-all behavior, and thread-local isolation.
- `races/`: GIL-valid counter, join-storm, transition/read/write interleavings,
  enumerator-cache invalidation, and wait/notify stress cases.
- Top-level heap witnesses: the full set of `heap-*.js` drivers is promoted.
  `heap-bench-allocation.js` provides deterministic allocation-churn checksum
  coverage, `heap-option-off.js` covers the option-off shell-mode guardrail, and
  the JSC `$vm.sharedHeapTest` harness drivers self-skip cleanly because that
  C-level shared-heap hook is intentionally absent here.
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
the shared-realm GIL path. The narrower
`zig build test -Dtsan=true -Dtest-filter=parallel_js` gate covers the current
test-only execution-path GIL-removal slice: real shared-realm `Thread` workers
running without the context GIL while contending one production
`Atomics.Mutex` and while registering/delivering `Lock.asyncHold` grants through
the realm task queue, plus property-mode `Atomics.wait`/`notify` waiter-table
contention guarded by `Gil.prop_mutex`, and `Condition.wait` / `notifyAll`
waiter-queue contention guarded by `CondRecord.mutex`.

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
unwound, the remaining jobs are rooted by the queue, and the active
Interpreter's checkpoint fields are registered as roots, including the current
environment cell and engine-owned Promise/VM native closure side records.
Shared-realm contexts still skip collection while any spawned JS thread is
actively running or parked inside native code. `$vm.gc` and `$vm.edenGC` are
aliases for that same shell request, `$vm.useThreadGIL()` reports whether the
current interpreter is using the shared-realm GIL, `$vm.indexingMode()` reports the
engine's array/typed-array mode witness, and `$vm.ensureArrayStorage(array)`
forces the array-mode witness used by the PR-249 shared-ArrayStorage stress
file. Other JSC `$vm` hooks, such as `sharedHeapTest`, dictionary conversion,
and code/disassembly controls, are left absent until backed by real engine
behavior.
The shell-compatible `quit()` helper throws a runner-recognized early-exit
sentinel, used by premise-skip tests after printing their skip marker.

Successful top-level scripts keep the shell alive until spawned shared-realm
`Thread`s finish, because their completion may settle `asyncJoin` promises and
queue microtasks. Abrupt top-level failure is different: the context requests
thread termination before the keepalive wait, so a main-thread exception cannot
strand parked child threads and hang runner teardown. The unit suite includes a
parked-thread regression for that path.

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

Add `-Dthreads-parallel-js=true` to run threaded corpus files through the
test-only Layer-C execution mode. Threaded files get
`Context.TestingOptions.parallel_js = true` together with the required
`enable_gc` / `parallel_gc` pair; the few corpus files that intentionally
exercise `Thread`-off behavior still run without a `Thread` global:

```sh
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=sync/condition-wait-notify.js
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=api/lock-basic.js,atomics/property-wait-notify.js
```

This is the bridge between focused unit witnesses and the future whole-corpus
GIL-free campaign. Promote a file to the regular allowlist only when both the
normal mode and the relevant `parallel_js` probe are green.

Full promoted-allowlist `parallel_js` mode is intentionally exploratory today:

```sh
zig build threads-test -Dthreads-parallel-js=true
```

It currently exposes real Layer-C blockers rather than serving as a required
green gate. Named property-mode Atomics RMW/CAS/load/store, typed-array
`Atomics.wait`, property wait lost-wakeup coverage, `smoke.js`, and
`api/condition-async-wait.js`, lifecycle join semantics, async joins, return
values, nested joins, cross-thread exception joins, contended dense-array
push/resize, and property-mode Atomics on dense array elements now have focused
green `parallel_js` probes. A full
`zig build threads-test -Dthreads-parallel-js=true` probe now skips
`cve/mc-df-segmented-length.js` as a known no-GIL budget frontier, because the
file is green in normal mode but can spend minutes in dense-array shrink/regrow
contention under the current interpreter lock granularity. The skip applies only
to the broad promoted-allowlist probe; targeted
`-Dthreads-case=cve/mc-df-segmented-length.js` still runs the file and remains
the repro for that performance frontier. This mode remains exploratory and is
not a green gate.

The no-GIL CVE tail has also moved forward: `cve/mc-int-resizable-tail-quarantine.js`,
`cve/mc-life-detach-quarantine-storm.js`, `cve/mc-life-sab-refchurn.js`,
`cve/mc-life-wasm-grow-relocate.js`, `cve/mc-lock-cow-materialize-race.js`,
and `cve/mc-val-llint-cache-storm.js` are focused-green under `parallel_js`.
The buffer and SAB lifetime files were fixed by serializing non-shared
ArrayBuffer resize/typed-array backing-slice borrows and the per-realm
SharedArrayBuffer retain list. The COW file's shutdown handshake no longer
publishes a fake work round, and the LLInt-cache storm keeps the original
30,000 iterations in GIL mode while using a smaller no-GIL stress budget. A
broad promoted probe now reaches through these files and times out later in the
cumulative safe/teardown/value stress region.

## Sweep Runs

Use `-Dthreads-sweep=true` to run every vendored file in the original
default-gate directories (`api/`, `arrays/`, `atomics/`, `bench/`,
`lifecycle/`, `races/`, `scaling/`, `shared-objects/`, and `sync/`). Harness
libraries such as `bench/harness.js` and `scaling/harness.js` are preloaded when
needed and are skipped as standalone sweep entries:

```sh
zig build threads-test -Dthreads-sweep=true
zig build threads-test -Dthreads-sweep=true -Dthreads-parallel-js=true
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

- As of 2026-06-15, the allowlist is 209 promoted files and 19 standalone
  reference-only files. Helper/preload files such as `harness.js`,
  `bench/harness.js`, `scaling/harness.js`, `resources/assert.js`, and
  `vmstate/resources/workload.js` are not counted as standalone remaining
  tests.
- WebAssembly CVE files that can prove the current no-WebAssembly/refusal
  premise are promoted; files that require real WebAssembly construction,
  compilation, and relocating grow behavior remain reference-only until those
  surfaces exist in this engine.
- Post-UNGIL JIT/CVE files require true GIL-off parallel mutation, ASAN or JIT
  artifact hooks, stop-the-world counters, or JSC-specific shell controls. They
  are not valid witnesses while the shared realm is serialized by the context
  GIL.
- The remaining post-UNGIL CVE/JIT set is:
  `cve/mc-aint-poll-resume-stale-elided.js`,
  `cve/mc-code-calllink-writer-writer.js`,
  `cve/mc-dos-retired-artifact-churn.js`,
  `cve/mc-grow-buffer-storm.js`,
  `cve/mc-init-butterfly-grow-slack.js`,
  `cve/mc-init-cloned-arguments-specials.js`,
  `cve/mc-init-direct-arguments-override.js`,
  `cve/mc-jit-delete-reuse-stale-offset.js`,
  `cve/mc-jit-double-relabel-stale-shape.js`,
  `cve/mc-jit-stale-base-grow-oob.js`,
  `cve/mc-jit-ta-resize-hoisted-base.js`,
  `cve/mc-lock-stop-vs-park.js`,
  `cve/mc-safe-gcwait-vs-classa-stop.js`,
  `cve/mc-tear-typedarray-detach-grow-shrink.js`,
  `cve/mc-val-fire-vs-link.js`, and `jit/ic-publish-reset-loops.js`.
  Focused probes of the two arguments-publication files
  (`mc-init-cloned-arguments-specials.js` and
  `mc-init-direct-arguments-override.js`) timed out under the serialized
  Debug runner rather than producing a semantic failure; they remain
  reference-only because their publication-order race is a post-GIL witness.
- `jit/ic-publish-reset-loops.js` currently stalls under the tree-walker and
  scheduler envelope; keep it reference-only until it completes reliably.
- `semantics/stack-overflow-per-thread.js` expects 2000-deep recursion before
  overflow storming. The tree-walker's native recursion cannot safely meet that
  by raising `max_call_depth` alone; Zig `0.17-dev` probes at 2048 and 4096
  both overflowed the host stack before producing catchable JS `RangeError`
  objects. This needs iterative or trampolined calls, or a VM-stack execution
  path.
- `cve/mc-spec-timer-capability.js` needs SharedArrayBuffer-off option modeling
  and true parallel property-Atomics timing. Under the context GIL it is not a
  meaningful timing witness.
- `semantics/oom-one-thread.js` remains out until there is a real heap cap and
  per-thread OOM handling contract.

## Docs Checks

```sh
bun run docs:build
rg '[2]7/[2]7|[3]0/[3]0|[5]4/[5]4|[6]9/[6]9|13[0]/13[0]|14[0]/14[0]|16[8]/16[8]|17[6]/17[6]|18[2]/18[2]|18[3]/18[3]|18[4]/18[4]|18[6]/18[6]|18[7]/18[7]|18[8]/18[8]|19[347]/19[347]|20[3]/20[3]|threads-test -[-]' README.md docs bunpress.config.ts
```

The search should find no stale 27-of-27, 30-of-30, 54-of-54, 69-of-69,
130-of-130, 140-of-140, 168-of-168, 176-of-176, 182-of-182, 183-of-183,
184-of-184, 186-of-186, 187-of-187, 188-of-188, 193-of-193, 194-of-194,
197-of-197, or 203-of-203 counts and no removed thread-test pass-through
command syntax. Use the `-Dthreads-case` and `-Dthreads-sweep` options instead.

## When Adding Thread Work

- Add or update unit tests for narrow engine behavior.
- Add a WebKit PR-249 corpus file to the allowlist only after it passes
  consistently.
- Update [bindings.md](./bindings.md) for every new file-scope mutable `var`,
  `pub var`, `threadlocal`, or container-scope mutable static.
- Re-run the ThreadSanitizer suite before merging any change that affects
  waiters, shared buffers, workers, GIL ownership, or cross-thread task
  delivery.
