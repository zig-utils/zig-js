# Runtime Thread Inventory

Every OS thread created by production zig-js code crosses the typed boundary in
`src/runtime_threads.zig`. The checked
[`runtime-thread-inventory-v1.json`](../.data/runtime-thread-inventory-v1.json)
records each resource's owner, admission and multiplicity, stack policy,
blocking behavior, memory, and shutdown contract.

The current inventory contains six creation sites:

| Resource | Owner | Multiplicity | Current admission |
|---|---|---|---|
| test262 agent | Process agent group | One per live agent | Per-resource thread/stack limits |
| concurrent GC marker | `Context` | At most one per context | Collection policy plus per-resource limits |
| shared-realm JavaScript `Thread` | `Context` thread record | One per live `Thread` | Context and per-resource limits |
| script Worker | Caller-owned `Worker` | One per Worker | Per-resource thread/stack limits |
| module Worker | Caller-owned `Worker` | One per Worker | Per-resource thread/stack limits |
| private execution watchdog | C API `ContextGroup` | At most one per group | Deadline plus per-resource limits |

JIT and WebAssembly compilation are synchronous today, so neither owns a
production helper thread or queue. Their test files do create concurrency to
exercise publication and atomic behavior; those sites are classified separately
as test-only.

The public Zig module exposes a coherent process-wide telemetry snapshot:

```zig
const resources = js.runtimeThreadSnapshot();
const workers = resources.resource(.script_worker);

const previous = js.setRuntimeThreadLimits(.script_worker, .{
    .max_threads = 8,
    .max_configured_stack_bytes = 128 * 1024 * 1024,
});

const previous_scheduler = js.setRuntimeThreadSchedulerLimits(.{
    .max_runnable_threads = 4,
});

// Restore automatic host sizing. An explicit maxInt(u64) means unlimited.
_ = js.setRuntimeThreadSchedulerLimits(.{});
```

Each resource row reports attempts, successful starts, completions, spawn
failures, policy rejections, in-flight spawn calls, admitted reservations, live
and peak threads, current/peak runnable and blocked threads, block/resume
transition totals, current/peak configured stack bytes, and the active limits.
The schema-v5 invariants are `attempts = starts + spawn_failures +
admission_rejections + in_flight_attempts`, `live = starts - completions`, and
`live = runnable + blocked`. The scheduler row reports its runnable limit,
policy mode, detected logical CPU count, automatic host reservation, configured
override, active and peak slots, current and peak queued waiters, and cumulative
slot waits. Its cross-resource invariant is
`active_slots = sum(resource.runnable)`.
Configured stack bytes describe the `std.Thread.SpawnConfig` reservation, not
resident or committed process memory. Counters mutate only at OS-thread
creation, blocking transitions, and exit; snapshot readers retry across those
short mutations so they cannot combine fields from different completed states.

Limits are process-wide per resource class. A spawn reserves one thread and its
configured stack before calling the OS; concurrent callers cannot cross either
limit. OS failure and thread exit release both reservations. Lowering a limit
below current use leaves existing threads alone and refuses new ones until use
falls below the limit. The defaults are unlimited, preserving existing
admission behavior.

Each typed thread starts runnable. Engine waits use nested blocking scopes: the
outermost scope moves the thread from runnable to blocked, and its matching end
moves it back. This covers agent broadcast/sleep/Atomics waits, Worker inbox and
inspector queues, shared-realm Lock/Condition/Atomics/join/GIL waits, collector
joins, and watchdog sleeps. Nested waits do not double-count, and calls made by
host or test threads outside the typed boundary are inert. Thread completion
requires the blocking depth to be zero, so a missing scope end fails in debug
and test builds instead of silently corrupting the state totals.

The process-wide runnable limit is shared by all six resource classes. A typed
thread acquires one slot before its entry function, releases it at its outermost
blocking transition, reacquires one before returning from that wait, and
releases it at completion. Excess entries and resumes park on a condition
variable, without a spin or sleep admission loop. A condition waiter never
queues for a slot while holding its reacquired wait mutex: it tries the slot
first, and if capacity is unavailable it releases the mutex, parks, then
reacquires the mutex before returning to its caller.

The runnable limit defaults to `max(1, logical CPUs - 1)`. The reserved lane
keeps capacity available for the embedder or foreground host mutator, which
runs outside the typed engine-thread boundary. If host detection fails, the
coordinator fails safe to one runnable slot. Passing `null` reapplies automatic
sizing and refreshes host detection; a numeric override is exact, including
zero to pause every new entry and resume, or `maxInt(u64)` for intentional
unlimited capacity. Lowering effective capacity below current use does not
interrupt existing runnable threads. Increasing it wakes queued threads to
compete under the coordinator mutex.

Run the fail-closed audit after adding or removing any runtime or test thread:

```bash
zig build runtime-thread-audit
```

The audit reconciles every typed resource call site and every remaining direct
`std.Thread.spawn` token under `src/`. A count change, unknown resource kind,
missing inventory row, or direct spawn in a new source file fails. Update the
JSON only after reviewing whether the new work belongs to production, test
scaffolding, or an existing resource class.

The boundary controls live-thread/configured-stack admission, records
runnable/blocked state, and enforces automatically sized shared CPU slots.
Issue [#502](https://github.com/zig-utils/zig-js/issues/502) owns priority policy,
compilation queues, cancellation, and memory pressure.
