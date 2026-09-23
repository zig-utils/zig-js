# Runtime Thread Inventory

Every OS thread created by production zig-js code crosses the typed boundary in
`src/runtime_threads.zig`. The checked
[`runtime-thread-inventory-v1.json`](../.data/runtime-thread-inventory-v1.json)
records each resource's owner, admission and multiplicity, stack policy,
blocking behavior, memory, and shutdown contract.

The current inventory contains six creation sites:

| Resource | Owner | Multiplicity | Current admission |
|---|---|---|---|
| test262 agent | Process agent group | One per live agent | Allocation and OS limits |
| concurrent GC marker | `Context` | At most one per context | Opt-in and collection due |
| shared-realm JavaScript `Thread` | `Context` thread record | One per live `Thread` | Optional `max_js_threads` and thread-ID space |
| script Worker | Caller-owned `Worker` | One per Worker | Allocation and OS limits |
| module Worker | Caller-owned `Worker` | One per Worker | Allocation and OS limits |
| private execution watchdog | C API `ContextGroup` | At most one per group | First finite execution deadline |

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
```

Each resource row reports attempts, successful starts, completions, spawn
failures, policy rejections, in-flight spawn calls, admitted reservations, live
and peak threads, current/peak configured stack bytes, and the active limits.
The schema-v2 invariants are `attempts = starts + spawn_failures +
admission_rejections + in_flight_attempts` and `live = starts - completions`.
Configured stack bytes describe the `std.Thread.SpawnConfig` reservation, not
resident or committed process memory. Counters mutate only at OS-thread
creation and exit; snapshot readers retry across those short mutations so they
cannot combine fields from different completed states.

Limits are process-wide per resource class. A spawn reserves one thread and its
configured stack before calling the OS; concurrent callers cannot cross either
limit. OS failure and thread exit release both reservations. Lowering a limit
below current use leaves existing threads alone and refuses new ones until use
falls below the limit. The defaults are unlimited, preserving existing
admission behavior.

Run the fail-closed audit after adding or removing any runtime or test thread:

```bash
zig build runtime-thread-audit
```

The audit reconciles every typed resource call site and every remaining direct
`std.Thread.spawn` token under `src/`. A count change, unknown resource kind,
missing inventory row, or direct spawn in a new source file fails. Update the
JSON only after reviewing whether the new work belongs to production, test
scaffolding, or an existing resource class.

The boundary controls live-thread and configured-stack admission. It does not
yet allocate runnable CPU slots or change scheduling; all six resource classes
remain marked `uncoordinated` for that work. Issue
[#502](https://github.com/zig-utils/zig-js/issues/502) owns shared CPU slots,
backpressure, cancellation, memory pressure, and embedder controls.
