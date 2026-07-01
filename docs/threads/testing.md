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
`reference/webkit-249/threads-tests`. The current allowlist is 225/225 and
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
The `api/lock-async-hold.js` barging witness now starts its child `Thread`
inside the setup `lock.hold`, so the async ticket is deterministically queued
against an already-active sync hold instead of racing with immediate no-fn
`asyncHold()` grant delivery under true parallel scheduling.

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
focused unit suite also locks in property-mode `Atomics.notify` queue
compaction: matching sync waiters are unlinked before signal, unmatched waiters
keep FIFO order, and async tickets are collected without repeated removals.
Property `waitAsync` timeout polling now has a direct unit witness for
one-pass expired-ticket compaction that preserves unexpired FIFO order. The
mid-script GC profile (`-Dfuzz-midgc=true`) uses the internal testing context to
enable `parallel_midscript_gc`, blocks peers in property `Atomics.wait`,
`Condition.wait`, and contended `Lock` acquisition, queues a FIFO async-hold
grant chain including a root-bearing rejected grant plus async condition
reacquire grants through those pump points, keeps a typed-array `waitAsync`
promise/reaction graph reachable only through the native waiter queue until
notification, keeps pending `Thread.asyncJoin`
fulfillment/rejection promise reactions reachable only through native completion
records until the child threads are released, keeps a registered object
reachable only through `ThreadLocal.value` while the
owning thread is parked, keeps a completed-but-unjoined `Thread` result object
and a completed-but-unjoined thrown exception object reachable only through the
thread completion record, adds a promise-publication subprogram that leaves a
child-returned typed-array `waitAsync` promise, a child-returned rejected
promise, a child-returned user thenable, and a child-thrown object rooted
through thread completion/native waiter state until after a finishing sweep,
then verifies `join()` / `asyncJoin()` fulfillment, rejection, thenable
assimilation, and thrown-object publication from observers registered both
before and after child completion, adds a sync-wait cleanup subprogram that
parks peers in property `Atomics.wait`, `Condition.wait`, and contended
`Lock.hold` acquisition through a finishing sweep before verifying their stack
roots after resume plus exact `FinalizationRegistry` cleanup count/sum delivery,
settles expired property `waitAsync` tickets while those peers are still
parked, keeps a live property `waitAsync` ticket rooted through the finishing
sweep, keeps an isolated Worker parked on a retained `SharedArrayBuffer` through
the same sweep, and then notifies both with exact captured-root and Worker-reply
oracles,
adds a sync-timeout subprogram that parks property `Atomics.wait` peers and
static `Atomics.Condition.waitFor` peers through a finishing sweep, rejects
early cleanup while their stack roots are still live, then requires timeout
results, `Atomics.Mutex.UnlockToken` reacquisition/unlock, and exact
`FinalizationRegistry` cleanup after quiescence,
adds a sync-wait burst subprogram that parks multiple waiters on the same
property, the same `Condition`, and the same contended `Lock` through a
finishing sweep, rejects early cleanup while those stack roots are still live,
then releases all three wait sets and verifies exact cleanup after quiescence,
adds an `Atomics.Mutex.lockIfAvailable` subprogram that parks
acquire-after-release and timeout token waiters behind a holder through a
finishing sweep, rejects early cleanup while those roots are live, then requires
reused-token acquire and timeout results plus exact `FinalizationRegistry`
cleanup after quiescence,
adds a static `Atomics.Condition.wait` subprogram that parks notify/reacquire
token waiters through a finishing sweep, rejects early cleanup while their stack
roots are live, then requires exact notify counts, token reacquisition,
`asyncJoin` observers, and cleanup after quiescence,
adds a ThreadLocal-finalization subprogram that parks owner threads with
targets reachable only through `ThreadLocal.value`, drives a finishing
mid-script sweep, verifies cleanup is not delivered while those hidden roots are
live, then clears the values and requires exact cleanup count/sum delivery,
adds a Thread.restrict-finalization subprogram that parks owner threads with
restricted owner-local objects registered for finalization, verifies nested
foreign reads still throw `ConcurrentAccessError`, drives a finishing
mid-script sweep, rejects early cleanup while those owner-thread roots are live,
then releases the owners and requires exact asyncJoin and cleanup oracles,
adds a pending-microtask subprogram that queues Promise, typed-array
`waitAsync`, `Thread.asyncJoin`, with-fn `Lock.asyncHold`, no-fn
release-function, and `FinalizationRegistry` cleanup roots through a finishing
mid-script sweep before draining the realm run loop and verifying exact
reaction/cleanup oracles,
adds a creator-owned buffer subprogram that leaves child-created
`SharedArrayBuffer` and `ArrayBuffer` storage rooted through unjoined `Thread`
completion records and delayed `asyncJoin` observers across a finishing sweep,
then verifies blocking `join()`, post-sweep `asyncJoin()`, and
`ArrayBuffer.transfer()` observers see exact contents after the creating thread
has exited,
adds script Worker/SAB and module Worker/SAB cleanup subprograms that run
isolated Workers on the same retained `SharedArrayBuffer` while shared-realm
`Thread`s register cleanup targets and park stack roots through a finishing
sweep, then verify exact Worker progress, joined thread roots, asyncJoin
reactions, and cleanup count/sum, adds script and module Worker handler-
exception cleanup subprograms that first recover from an expected thrown
`onmessage` delivery and then prove the same Worker/SAB progress plus
shared-realm cleanup oracle through the finishing sweep, adds script and module
Worker close/terminate subprograms that keep exact FIFO drain/drop ordering,
post-close drop, post-terminate receive silence, shared-realm joined roots,
asyncJoin reactions, and cleanup count/sum live across the finishing sweep,
adds a weak-collection subprogram that parks property
`Atomics.wait`, `Condition.wait`, and contended `Lock.hold` peers while live
WeakMap values are reachable only through live weak keys, dead WeakMap/WeakSet
targets are reachable only through weak structures and WeakRefs, and
FinalizationRegistry unregister-token records are compacted through a finishing
sweep, then verifies live ephemeron values, cleared dead refs, exact cleanup
count/sum, and exact unregister suppression, and adds an expected-termination
subprogram that parks children after installing child-owned typed-array
`waitAsync` tickets, drives a finishing mid-script parallel sweep, then
verifies teardown `asyncJoin` rejection reactions and zero leaked waitAsync
tickets. It also has a focused
join-termination unit witness that checks parked-state/mutex cleanup, then
requires exact script completion or exact expected termination plus at least one
finishing parallel sweep and exact
`FinalizationRegistry` cleanup count/sum delivery plus unregister-token
suppression after a quiescent collect. Each seed currently runs 21 deterministic
mid-GC subprograms. The
lifecycle profile
(`-Dfuzz-lifecycle=true`) adds expected-throw termination storms for
parked/unjoined shared-realm `Thread`s, exact Atomics counter oracles for script
`Worker` plus simple-import, diamond-shaped, and fanout/rejoin module `Worker`
overlap with shared-realm `Thread`s on one retained `SharedArrayBuffer`,
Worker/thread/finalization scheduling on one retained SAB, exact cleanup after
terminating spinning Workers that share the retained SAB, Worker termination
while top-level failure tears down parked shared-realm `Thread`s, pending
`asyncJoin` rejection reactions, and already-ready cleanup jobs on the same
retained SAB, module Worker termination with the same shared-realm
teardown/reaction/cleanup oracle, exact FIFO drain/drop ordering for mixed
script and module Worker `close` / `terminate` / `postMessage` lifecycles,
plus worker handler-exception recovery after a thrown `onmessage`,
Worker handler-exception recovery composed with shared-realm Thread
finalization cleanup on one retained SAB, module Worker handler-exception
recovery composed with the same retained-SAB cleanup oracle,
`Thread.restrict` lifecycle isolation plus `Thread.restrict`-owned
`FinalizationRegistry` cleanup after owner-thread exit,
Thread exception identity through `join()` / `asyncJoin()`
while property and condition waiters are parked, thread-returned typed-array
`waitAsync` promise assimilation through
`join()` / `asyncJoin()` while waiters are parked,
typed-array `waitAsync` settlement interleaved with `asyncJoin` reactions and
exact `FinalizationRegistry` cleanup delivery, deterministic
`Condition.asyncWait` reacquire delivery interleaved with `join()` /
`asyncJoin()` reactions and exact `FinalizationRegistry` cleanup delivery,
proposal-style `Atomics.Mutex` / `Atomics.Condition.waitFor` token waiters
that take both notify and timeout paths while `asyncJoin` observers and exact
cleanup share the same lifecycle window, `Atomics.Mutex.lockIfAvailable`
token waiters that take both acquire-after-release and timeout paths with
reused tokens in that same cleanup window,
`Lock.asyncHold()` barging where a sync hold legally overtakes a queued no-fn
async ticket before `await` delivers its release function, no-fn
`Lock.asyncHold()` release-function delivery while property and condition
waiters stay parked before exact cleanup after they resume, teardown termination
with pending `asyncJoin` rejection reactions and
child-owned typed-array `waitAsync` tickets that must be abandoned before the
child's stack-owned waiter token disappears, cross-thread `FinalizationRegistry`
cleanup count/sum oracles, teardown termination while property `waitAsync`
timeout compaction, async condition reacquire, a pending `asyncJoin` rejection
reaction, and already-ready `FinalizationRegistry` cleanup jobs share the same
realm turn, module Worker termination composed with the same child-owned
typed-array `waitAsync` ticket abandonment, pending `asyncJoin` rejection
cleanup, and exact `FinalizationRegistry` cleanup,
Promise reaction queue churn from with-fn `Lock.asyncHold`, no-fn release
functions, typed-array `waitAsync`, `Thread.asyncJoin`, and exact
`FinalizationRegistry` cleanup,
`Lock.asyncHold(fn)` throw/release ordering with queued no-fn release grants and
exact `FinalizationRegistry` cleanup,
creator-owned `SharedArrayBuffer` and `ArrayBuffer` storage that survives the
creating Thread's exit, sibling-thread reads, GC pressure, and post-creator
`ArrayBuffer.transfer()`, child-created SAB/ArrayBuffer storage crossing
isolated Worker structured-clone after the creator Thread exits, plus sibling
script Worker and module Worker clone/finalization cleanup/transfer observer
variants,
cleanup delivery interleaved with `join()` /
`asyncJoin()` and unregister-token suppression, cleanup delivery after parked
property/condition waiters resume, child-returned fulfilled/rejected promises
and user thenables published through both `join()` and `asyncJoin()`, plus
`ThreadLocal` isolation across normal, throwing, nested, and async-joined
thread lifecycles, plus
`ThreadLocal` values registered with `FinalizationRegistry` across
park/resume/clear/join cleanup lifecycles with exact cleanup count/sum delivery
after quiescent collection. It also parks child Threads behind parent-created
`asyncJoin()` promises that outlive the parent Thread's local microtask queue,
then verifies child release, nested `ThreadLocal` roots, rerouted async
settlement, and exact finalization cleanup after both thread layers exit. It now
also composes isolated Worker termination with shared-realm teardown that
abandons child-owned typed-array `waitAsync` tickets, rejects pending
`asyncJoin` reactions, and delivers exact cleanup. Each seed currently runs 38
deterministic lifecycle
subprograms.

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
`notify`, property `Atomics.waitAsync` timeout settlement,
`Condition.wait` / `notifyAll`, single-lock and multi-lock
`Condition.asyncWait`, contended `Lock.hold`, `Lock.asyncHold` delivery,
observed `Lock.asyncHold` callback settlement, no-fn `Lock.asyncHold`
release-function delivery, and thread lifecycle churn.
Its opt-in counters let
`events` count logical contention in `Lock`/`Condition`/property waits and
queued `asyncHold` grants, and `parks` count timed wait/pump iterations
including `Thread.join`. The `joins` columns split the `Thread.join` subset out
of aggregate parks so lifecycle churn can be attributed separately from lock,
condition, and property wait pressure.
The `lock`/`cond`/`prop` columns split the remaining sync park pressure by
contended `Lock.hold`, `Condition.wait`, and property `Atomics.wait`, so
source-specific waiter regressions do not hide inside aggregate parks.
The `async`/`done` columns split `Condition.asyncWait` plus property
`waitAsync` registration from completed async-condition reacquires plus settled
property `waitAsync` tickets, making timeout-settlement parity and async
condition regrant pressure visible in the same run.
The `empty`/`jobs` columns split the run-loop task pump into empty atomic
fast-path hits and real grant-job delivery, and the paired `hold`/`cjob`
columns split those delivered jobs into ordinary `Lock.asyncHold` grants versus
`Condition.asyncWait` reacquire grants. Run it before and after synchronization
or lifecycle changes so performance work has an attributed baseline instead of
only elapsed time. The profile also prints a separate isolated `Worker` table
for structured-clone inbox/outbox round-trips, empty
receive polling, and spawn/post/receive/join/destroy lifecycle churn; it
now emits separate script and module Worker rows so import-graph startup and
lifecycle cost can be compared with plain source Workers. It intentionally has
no `.gil = true` column because each Worker owns its own `Context`.
Empty sync-wait task pumps now have a
lock-free fast path;
real async-hold delivery drains larger bounded FIFO bursts from the realm task
queue under one API-lock acquisition before running grants outside that lock,
task-queue writers publish the atomic pending hint from the locked queue length
instead of writer-side atomic RMW, and retry-front async-hold grants use a front
stash instead of shifting the per-lock pending list when no consumed head slot
is available; condition notify/notifyAll uses a FIFO head cursor for the mixed
sync/async waiter queue;
timed-out or terminated sync condition waiters are marked canceled and skipped
by that cursor instead of being removed from the middle of the queue; sync
notifyAll handoff now waits on the waiter's condition ack signal instead of a
fixed 1ms polling sleep;
property-mode `Atomics.wait` timeout/termination cleanup stable-compacts the
sync waiter table in one pass instead of shifting the remaining waiters;
typed-array `Atomics.notify` unlinks sync stack tickets before signal, and
typed-array `waitAsync` harvest/abandon paths stable-compact matching tickets
in one pass while preserving FIFO order for other waiters;
Worker inbox/outbox channels use the same shape for structured-clone message
delivery, and empty internal `Worker.receive(..., 0)` polls skip timed condition
wait setup and drained-queue compaction. Active interpreter roots, protected
C-API handles, and GIL park records remove with swap semantics because those
root sets have no observable order. `C-API: JSValueProtect roots survive
mid-script parallel GC` protects an otherwise-unrooted C-API object while
shared-realm `Thread`s drive a finishing mid-script parallel sweep, verifies the
object and nested child survive while protected, then proves the final
`JSValueUnprotect` releases it. `worker channel pops FIFO without front shifts` keeps that queue
shape and zero-timeout polling behavior under a direct unit guard, while
`condition queue head cursor skips canceled sync waiters` covers the condition
timeout/termination queue shape directly, and `condition sync handoff countdown
tracks acknowledged tickets` covers the no-rescan sync notify handoff counter.
`jsthread lock pending async jobs are cursor FIFO` covers FIFO pop,
consumed-slot retry, and front-stash retry without front shifts, while
`jsthread traces queued async hold task roots` covers the GC roots behind both
queued realm tasks and retry-front lock grants. The public condition corpus
cases exercise the single wake-list notify path for async-only and sync
notify-all wakes: `api/condition-async-wait.js`,
`sync/condition-wait-notify.js`, and
`sync/condition-notify-all-multi-waiter.js`. The same notify path batches
contiguous same-lock async condition regrants under one lock acquisition per
fixed-size stack batch instead of retaking that lock once per async waiter.
`property waiter removal
stable-compacts timed-out sync ticket` covers the property waiter cleanup shape,
`waiter table notify unlinks sync tickets and preserves async FIFO tail` plus
`waiter table harvestAsync stable-compacts settled owner tickets` cover the
typed-array waiter-table shapes, and `api/condition-wait-termination.js` keeps
the JS termination path exercised.
Promise microtask drains now use the same FIFO head-cursor pattern, with
`microtask queue is FIFO with a head cursor` guarding the direct queue shape and
the asyncHold corpus case exercising observed callback/release-function
reactions through the public API. The async-hold task pump snapshots the
microtask enqueue generation before and after each delivered grant, so
unobserved grants that settle without queuing reactions keep the required task
turn while skipping an otherwise-empty no-GIL microtask drain. No-fn async-hold
release states are embedded in their already arena-lived hold jobs, so the same
public asyncHold corpus case also covers the release-function path after that
allocation reduction.
The property `waitAsync` timeout row should keep `async` and `done` equal after
finite tickets settle; the single-lock `Condition.asyncWait` row exposes
same-lock regrant batching, while the multi-lock row exercises FIFO-bursted
realm task enqueue across lock groups and the paired run-loop job delivery
pressure separately through the `hold` versus `cjob` split.
`threads-profile` remains the check that this kind of targeted optimization
does not merely move overhead elsewhere.

`zig build gc-profile` also includes an embedder task-lifecycle table. It
compares create/evaluate/destroy per task against evaluating the same task
repeatedly in one long-lived context with periodic `collectGarbage()` calls, so
context-heavy embedders can quantify the cost of create-per-unit-of-work designs
while the GC allocator and lifecycle paths continue to mature. The lifecycle
table splits total time into create and destroy columns so teardown reductions
are visible separately from global setup costs. The workload destroy table
compares destroying the same object-heavy context while the workload is still
live with a quiescent `collectGarbage()` followed by destroy, so finalizer
draining and post-collection teardown costs can be tracked separately. The
profile also prints GC cell-backing attribution for the intrinsic empty-context
footprint and for an object-heavy allocation run: chunk count, total cell-slot
capacity, live cells at context creation, live cells after allocation, free
slots after collection, and live cells after collection. It then prints
per-size-class bucket tables for the empty context and the same object workload,
showing slot size, chunks, capacity, issued cells, free cells, and surviving
live cells. GC finalizer attribution is also split between empty-context destroy
and destroy after the object workload.
These snapshot paths use exact per-bucket free, capacity, and issued-slot
counters rather than walking every free-list node or slab chunk. The
object-sized 1024/2048-byte buckets use larger slab chunks than the small
buckets, so compare chunk counts alongside wall-clock timings when evaluating GC
allocation or lifecycle changes.
Direct `GcCellBacking` unit tests cover lazy fresh-slot bumping, free-list
recycling, fresh-chunk cursor advancement, ownership span/hint classification,
stats accounting, multi-chunk maintained-counter snapshots, bucket attribution,
bulk-teardown behavior, and bucket-shaped delegated side frees during teardown.
`enable_gc: heap binding and cell backing share one lifecycle allocation` covers
the context-lifecycle reduction where the GC heap, root-tracing binding, and cell
backing live in one stable state allocation instead of three separate GPA
objects.
The unit suite also covers live `SharedArrayBuffer` retain release during
context teardown across arena, no-GIL threaded, and `.gil = true` contexts.
Collection-helper removal witnesses live in the same unit suite:
`WeakMap and WeakSet entry delete is unordered tail removal`,
`gc pruneDeadWeakEntries removes dead weak keys with unordered tail removal`,
and `FinalizationRegistry unregister stable-compacts matching records` guard
the weak-entry tail-removal and stable unregister compaction shapes.
`agent reports drain FIFO with a head cursor` guards `$262.agent` report queue
FIFO order, cursor compaction, and teardown cleanup for report-heavy Atomics
agent tests.

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
./zig-out/bin/threadfuzz workerclose 5 1
./zig-out/bin/threadfuzz moduleworkerclose 5 1
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
- `cve/mc-life-creator-thread-dies.js` still depends on reference-shell buffer
  variants and detach assumptions that are not promotable as-is. The stable
  subset is covered by `threadfuzz creatorbuffers`, which checks child-created
  `SharedArrayBuffer` / `ArrayBuffer` storage after creator exit, sibling reads,
  GC pressure, and post-creator `ArrayBuffer.transfer()`.
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
python3 tools/threads-reference-audit.py --format json
python3 tools/threads-reference-audit.py --probe-candidates
python3 tools/threads-reference-audit.py --run-probes --probe-timeout 60
python3 tools/threads-reference-audit.py --run-probes --expect-current-blockers --probe-timeout 60
```

`--run-probes` executes the closest reference-only candidates with focused
`threads-test` commands and returns nonzero on any failure or timeout. A timed
out or failing probe is not promotion evidence; keep the file reference-only
until the underlying behavior lands and the focused run passes reliably. Failed
probes print focused runner evidence before the Zig build tail so the concrete
JS error, corpus failure, or timeout is visible in one command.
`--format json` emits the same allowlist counts, reference-only categories,
closest probe commands, and expected current blocker evidence in a stable
machine-readable form for CI reports, dashboards, or issue-tracker updates.
`--expect-current-blockers` flips that maintenance check into a negative gate:
it succeeds only while the nearest probes still fail or time out with the
documented blocker evidence. If it starts failing because a probe passes, or
because the failure shape changed, re-run that single `-Dthreads-case=...`
probe, promote the file only when the underlying behavior is implemented, and
update the docs/issue tracker in the same change.

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
