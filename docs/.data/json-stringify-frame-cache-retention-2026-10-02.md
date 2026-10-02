# `JSON.stringify` frame-cache retention evidence

Measured on 2026-10-02 for [issue #1022](https://github.com/zig-utils/zig-js/issues/1022).
This is a deterministic allocation/capacity diagnostic, not a throughput,
wall-time, RSS, or JavaScriptCore comparison.

## Revisions and method

- Baseline: `9453de45b6f66543b08f8c06904e29f37172362d`.
- Candidate: `3e3188657ff9e4b4204ecf2663175d9943230381`.
- Collecting zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3`.
- zig-regex: `fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b`.
- Zig `0.17.0-dev.2163+89ff10d56`, Debug, arm64 macOS.
- [Raw counters](json-stringify-frame-cache-retention-2026-10-02.json).

The witness appends directly through the production `Stringifier.FrameStack`,
allows its ordinary unwind path to run, and reads allocator capacity plus the
machine-readable cache gauges. The capacity is therefore the allocator's
actual deterministic growth result, not a requested or estimated size. Each
frame is 96 bytes. The baseline cache record is 56 bytes; the candidate's
accounted cache record is 72 bytes.

## One-off high-water retention

| active frames | allocator capacity | baseline retained after unwind | candidate retained after unwind | released retained bytes |
| ---: | ---: | ---: | ---: | ---: |
| 4,096 | 5,900 | 566,456 B | 72 B | 566,384 B |
| 50,000 | 67,247 | 6,455,768 B | 72 B | 6,455,696 B |

The candidate retains only the live cache record after either first
observation; frame capacity returns to zero. `Interpreter.deinit` then returns
the remaining current cache count and bytes to zero.

## Reuse and release sequence

The first 4,096-frame call grows through 15 capacity changes and releases its
5,900-slot allocation. A second comparable call confirms the working set and
retains those 5,900 slots. A third call reuses the allocation with the growth
counter unchanged at 30. One shallow invocation releases the retained slots.
The subsequent one-off 50,000-frame call observes 67,247 slots and again
returns current frame capacity to zero.

The final sequence reports 51 growth events, 3 release events, 7,588,512
released frame bytes, a 6,455,784-byte peak including candidate metadata, and
zero current bytes after interpreter teardown. Exact current/peak capacity,
bytes, growth, and release fields are also published through memory-inventory
schema 4; they overlap Context allocator backing and are not added to its owned
subtotal.

## Qualification boundary

The retained-capacity witness and exhaustive allocation-failure/lease-unwind
test pass together (`3 passed; 0 failed`). Separate production-Context tests
pass for 50,000-level object and array limits in both forced tree and
required-VM modes, callback-triggered moving GC, and shared no-GIL execution.
The no-GIL case also passes direct Zig ThreadSanitizer with zero reports. These
tests use the collecting zig-gc revision named above rather than the local
non-collecting compatibility shim.

The pinned `test/built-ins/JSON` subtree reports `165 pass; 0 fail`. Its forced
tree/required-VM witness reports `165 agree; 0 diverge`. No timing field is
collected or used for acceptance.
