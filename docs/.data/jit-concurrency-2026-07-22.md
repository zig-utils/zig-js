# JIT publication and retirement closure gate — 2026-07-29

Implementation commits: `fdb27940`, `26ef6127`, `01306740`, `16b2a1a2`,
`a757cd1a`, `2bdb47be`, `3f2fe88b`, `4dfc2aca`, `aa99feb2`, `821a5242`

This gate closes [#433](https://github.com/zig-utils/zig-js/issues/433) and
covers [#454](https://github.com/zig-utils/zig-js/issues/454) execution-epoch
retirement, [#455](https://github.com/zig-utils/zig-js/issues/455) atomic
optimizer call links, [#456](https://github.com/zig-utils/zig-js/issues/456)
shared-GC/Class-A ordering, and
[#457](https://github.com/zig-utils/zig-js/issues/457) inherited-property
watchpoints.

| configuration | filter | result |
| --- | --- | ---: |
| normal | `Owner ` | 7 / 7 |
| normal | `optimizer call-link` | 2 / 2 |
| normal | `optimizer native call resumes a function-valued parameter` | 3 / 3 |
| TSan | `Owner ` | 7 / 7 |
| TSan | `optimizer call-link` | 2 / 2 |
| TSan | `optimizer native call resumes a function-valued parameter` | 3 / 3 |
| normal | complete `test-jit` gate | 175 / 175, 0 leaked |
| TSan | complete `test-jit` gate | 175 / 175, 0 leaked |
| normal + TSan | Class-A mutation / shared-GC conductor ordering | 4 / 4 each |
| normal + TSan | cooperative nursery rendezvous | 3 / 3 each |
| normal + TSan | cooperative collector-exit cleanup | 3 / 3 each |
| normal + TSan | parallel M3 wait-peer publication | 3 / 3 each |
| normal + TSan | parallel allocation-failure recovery | 4 / 4 each |

The retirement witness rotates and reclaims 32 executable generations, verifies zero live/retired bytes at steady state, and proves a later-generation reader does not delay an older generation. The publication witness races two writers and a resetter against a reader for 20,000 iterations each, then the VM witness proves the installed link is consumed by a real optimizer call.

The conductor witness holds a shared collection window while a competing Class-A invalidator attempts to run. The optimizer generation remains unchanged until the window closes, then advances exactly once before the invalidator returns. A second witness warms a real named-property optimizer artifact, mutates the observed object through the parallel VM fast path, proves one generation rotation, and verifies the new value after fallback. Cooperative, abort-safe M3, and allocation-failure collectors retain their existing bounded convergence under the same lock in normal and TSan modes.

The terminal PR-249 optimizer witnesses add non-vacuous no-GIL coverage. The
call-link writer/writer case published 1,500 optimizer artifacts and 12,393
call links while reclaiming all 1,500 invalidated artifacts. The trap
invalidation case published 50 artifacts and reclaimed 49 invalidated
generations. Both inherited-property GC-wait/Class-A cases published 18
artifacts, fired 13 invalidations, and completed a cooperative collection.
The stale-array-base guard case published both reader and writer artifacts.
Each witness also passed its TSan profile without a race report.

The engine's Zig 0.17 build exposes ThreadSanitizer, safety-checked Debug and
ReleaseSafe modes, allocator leak checks, and explicit fault-injection tests.
It does not expose AddressSanitizer for Zig engine code; the build's ASan/UBSan
step covers only the Objective-C bridge. The optimizer closure gate therefore
claims the supported engine sanitizer matrix rather than treating an
unavailable ASan configuration as executed evidence.

The accepted README benchmark report remains unchanged: its workloads and measured tier selection did not change in this batch.
