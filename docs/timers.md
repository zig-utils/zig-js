# Timers

zig-js provides context-owned `setTimeout`, `clearTimeout`, `setInterval`, and
`clearInterval` globals. Scheduling returns immediately; JavaScript callbacks
run only on the event loop that created the timer.

## Handles

`setTimeout` and `setInterval` return stable objects with:

- `ref()`, `unref()`, and `hasRef()`;
- `refresh()` to restart the original delay;
- `close()` as a cancellation alias;
- numeric coercion to a context-unique ID accepted by both clear functions.

Handles are refed by default. Dropping a handle does not cancel its timer. An
active record precisely roots its callback and extra arguments until it fires,
is cancelled, or its event loop is torn down.

## Scheduling

- Delays use the monotonic clock. Fractions are truncated; missing, non-finite,
  sub-millisecond, negative, and greater-than-`2^31 - 1` delays become 1 ms.
- Ready timers are selected by deadline and then insertion order.
- Each callback is one task. Its next-tick and Promise jobs drain before the
  next ready timer callback.
- Cancelling a running interval suppresses its next iteration. `refresh()` from
  a running one-shot callback schedules it again.
- Callback arguments and `this === undefined` follow Node-style host timers;
  string callbacks are rejected with `TypeError`.

Refed timers keep a shell, module, worker callback, or shared-realm thread alive.
The host parks only after the current top-level task and microtask checkpoint.
Unrefed timers never extend keepalive; they run if due at a later Context entry
or another normal event-loop checkpoint. Background threads never execute timer
JavaScript.

`AbortSignal.timeout()` uses a separate unrefed, ABI-shaped timer lane. It does
not create a public timer handle or affect public-timer keepalive.
