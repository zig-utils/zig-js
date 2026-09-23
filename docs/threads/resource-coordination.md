# Runtime Thread Inventory

Every OS thread created by production zig-js code crosses the typed boundary in
`src/runtime_threads.zig`. The checked
[`runtime-thread-inventory-v1.json`](../.data/runtime-thread-inventory-v1.json)
records each resource's owner, admission and multiplicity, stack policy,
blocking behavior, memory, and shutdown contract.

The current inventory contains six creation sites:

| Resource | Owner | Multiplicity | Priority | Current admission |
|---|---|---|---|---|
| test262 agent | Process agent group | One per live agent | Foreground | Per-resource thread/stack limits |
| concurrent GC marker | `Context` | At most one per context | Safety | Collection policy plus per-resource limits |
| shared-realm JavaScript `Thread` | `Context` thread record | One per live `Thread` | Foreground | Context and per-resource limits |
| script Worker | Caller-owned `Worker` | One per Worker | Background | Per-resource thread/stack limits |
| module Worker | Caller-owned `Worker` | One per Worker | Background | Per-resource thread/stack limits |
| private execution watchdog | C API `ContextGroup` | At most one per group | Safety | Deadline plus per-resource limits |

JIT and WebAssembly compilation remain synchronous and own no production helper
thread or artifact queue. Their CPU-heavy boundaries now enter the same runtime
coordinator as typed threads. Compilation performed by a typed engine thread
reuses that thread's runnable slot. An untyped embedder thread uses the reserved
host lane when available; additional host compilers enter the background queue
for general runnable capacity.

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
The schema-v7 thread invariants are `attempts = starts + spawn_failures +
admission_rejections + in_flight_attempts`, `live = starts - completions`, and
`live = runnable + blocked`. The scheduler row reports its runnable limit,
policy mode, detected logical CPU count, automatic host reservation, configured
override, active and peak slots, current and peak queued waiters, and cumulative
slot waits. It also reports current/peak internal work in general slots and in
the reserved host lane. Each priority row reports its weight, current/peak typed
thread waiters, cumulative grants, and last granted ticket. Each internal-work
row reports requests, starts, completions, current/peak active work, typed and
nested slot reuse, reserved/general host admissions, current/peak waiters,
cumulative waits and wait time, and last granted ticket. The coherent invariants
are `requests = starts + waiters`, `active = starts - completions`,
`active_slots = sum(resource.runnable) + internal_work_general_active`, and
`scheduled_cpu_total = active_slots + host_work_reserved_active`.
Configured stack bytes describe the `std.Thread.SpawnConfig` reservation, not
resident or committed process memory. Counters mutate only at OS-thread
lifecycle, blocking transitions, and synchronous internal-work boundaries;
snapshot readers retry across those short mutations so they cannot combine
fields from different completed states.

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

The process-wide general runnable limit is shared by all six resource classes
and excess untyped internal work. A typed thread acquires one slot before its
entry function, releases it at its outermost
blocking transition, reacquires one before returning from that wait, and
releases it at completion. Excess entries and resumes join allocation-free
intrusive queues and park on stack-owned conditions, without a spin or sleep
admission loop. Safety, foreground, and background grants follow a repeating
4:2:1 weighted cycle. Empty classes are skipped, FIFO order is preserved inside
each class, and a continuously queued class therefore cannot starve. New
arrivals queue behind existing eligible waiters instead of bypassing them.
Synchronous native and Wasm compilation use the background class without an
allocation: the queue node and condition live in the waiting host stack. One
untyped host compiler may use the automatic host reservation; further host
compilers consume available general slots or wait. Reserved admission can wake
only internal work, while general background grants preserve ticket order
between internal work and typed Worker waiters.

The coordinator reserves a slot, publishes the selected resource as runnable,
and removes its waiter in one coherent mutation before signaling it. A thread
woken from an engine condition never queues for that slot while holding its
reacquired wait mutex: it tries immediate admission first, and if capacity or
older waiters prevent it, releases the mutex, parks in the scheduler queue,
then reacquires the mutex before returning to its caller.

The runnable limit defaults to `max(1, logical CPUs - 1)`. The reserved lane
keeps capacity available for the embedder or foreground host mutator, which
runs outside the typed engine-thread boundary. If host detection fails, the
coordinator fails safe to one runnable slot. Passing `null` reapplies automatic
sizing and refreshes host detection; a numeric override is exact, including
zero to pause every new entry, resume, and untyped internal-work boundary, or
`maxInt(u64)` for intentional unlimited capacity. Lowering effective capacity
below current use does not interrupt existing runnable threads. Increasing it
grants exactly the newly
available capacity through the weighted queues.

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
runnable/blocked and synchronous internal-work state, and enforces automatically
sized, priority-scheduled shared CPU slots. Issue
[#985](https://github.com/zig-utils/zig-js/issues/985) owns synchronous compiler
admission and its performance evidence. Issue
[#502](https://github.com/zig-utils/zig-js/issues/502) owns the remaining
cross-subsystem memory-pressure work.
