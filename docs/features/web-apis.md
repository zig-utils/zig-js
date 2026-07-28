---
title: Web-shaped APIs
description: Timers, URL, text encoding, fetch data types, abort signals, base64, and structured clone in zig-js.
---

# Web-shaped APIs

zig-js is not a browser and ships no DOM. It does implement the host-shaped APIs
that server-side runtimes and embedders expect, so a JavaScript runtime built on
this engine does not have to reimplement them.

## Timers

Context-owned `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`.
Scheduling returns immediately; callbacks run only on the event loop that created
the timer. Handles are stable objects with `ref()`, `unref()`, `hasRef()`, and
`refresh()`. Full details: [Timers](/timers).

## URLs

`URL` and `URLSearchParams`, including origin/host/port parsing, percent
encoding, and IDNA handling via the checked-in `unicode_idna_data.zig` tables.

## Text encoding

`TextEncoder` and `TextDecoder` over the generated codec tables
(`text_codec.zig`, `text_codec_tables.zig`, `encoding_multibyte*.zig`,
`encoding_singlebyte_data.zig`), covering the single-byte and multi-byte legacy
encodings alongside UTF-8, with the standard streaming and fatal/replacement
behaviours.

`btoa` and `atob` provide base64 at the global level.

## Fetch data types

`Headers`, `Request`, `Response`, `FormData`, and `Blob` are implemented as data
types — header normalization and guard rules, body consumption
(`text`/`json`/`arrayBuffer`/`blob`/`formData`), multipart parsing, and
`Blob` slicing. Header semantics live in
[`src/fetch_headers.zig`](https://github.com/zig-utils/zig-js/blob/main/src/fetch_headers.zig).

**There is no network stack.** These types exist so an embedder can wire its own
transport to standard shapes; the engine performs no I/O.

## Cancellation

`AbortController` and `AbortSignal`, including `AbortSignal.timeout()` and the
abort-reason propagation that consumers check. Signal timeout generations are
tracked by the `Context`, so a torn-down context cannot fire a stale abort.

## Structured clone

`structuredClone()` uses the same wire format as Worker `postMessage`
([`src/structured_clone.zig`](https://github.com/zig-utils/zig-js/blob/main/src/structured_clone.zig)):
cyclic graphs, `Map`/`Set`/`Date`/`RegExp`/`Error`, typed arrays and
`DataView`, `ArrayBuffer` **transfer** (the source detaches), and
`SharedArrayBuffer` **retention** (shared, not copied).

## Microtasks and the run loop

`queueMicrotask` shares the promise-reaction queue. The host drains microtasks at
defined checkpoints; timers are a separate macrotask stage. Harness globals
`drainMicrotasks`, `$drainRunLoop`, and `$drainFinalizationCleanup` let a test
host step the loop deterministically — they are harness surface, not stable
embedder API.

## What an embedder still owns

- Networking, filesystem, process, and stdio.
- Module specifier resolution and loading (`Context.evaluateModule` takes a host
  hook — see [Embedding](/advanced/embedding)).
- Logging: there is no `console`.
- The event-loop policy itself. The engine exposes the queues and the drain
  points; the run loop is the host's.
