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

Run the fail-closed audit after adding or removing any runtime or test thread:

```bash
zig build runtime-thread-audit
```

The audit reconciles every typed resource call site and every remaining direct
`std.Thread.spawn` token under `src/`. A count change, unknown resource kind,
missing inventory row, or direct spawn in a new source file fails. Update the
JSON only after reviewing whether the new work belongs to production, test
scaffolding, or an existing resource class.

The typed boundary does not yet change scheduling. All six resource classes are
currently marked `uncoordinated`; issue
[#502](https://github.com/zig-utils/zig-js/issues/502) owns shared CPU slots,
backpressure, cancellation, memory pressure, and embedder controls.
