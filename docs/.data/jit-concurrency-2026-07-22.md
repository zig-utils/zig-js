# JIT publication and retirement gate — 2026-07-22

Commits: `fdb27940`, `26ef6127`

This gate covers [#454](https://github.com/zig-utils/zig-js/issues/454) execution-epoch retirement and [#455](https://github.com/zig-utils/zig-js/issues/455) atomic optimizer call links. Both changes were batched before the focused and complete JIT runs.

| configuration | filter | result |
| --- | --- | ---: |
| normal | `Owner ` | 7 / 7 |
| normal | `optimizer call-link` | 2 / 2 |
| normal | `optimizer native call resumes a function-valued parameter` | 3 / 3 |
| TSan | `Owner ` | 7 / 7 |
| TSan | `optimizer call-link` | 2 / 2 |
| TSan | `optimizer native call resumes a function-valued parameter` | 3 / 3 |
| normal | complete `test-jit` gate | 171 / 171 |
| TSan | complete `test-jit` gate | 171 / 171 |
| normal + TSan | Class-A mutation / shared-GC conductor ordering | 4 / 4 each |
| normal + TSan | cooperative nursery rendezvous | 3 / 3 each |
| normal + TSan | cooperative collector-exit cleanup | 3 / 3 each |
| normal + TSan | parallel M3 wait-peer publication | 3 / 3 each |
| normal + TSan | parallel allocation-failure recovery | 4 / 4 each |

The retirement witness rotates and reclaims 32 executable generations, verifies zero live/retired bytes at steady state, and proves a later-generation reader does not delay an older generation. The publication witness races two writers and a resetter against a reader for 20,000 iterations each, then the VM witness proves the installed link is consumed by a real optimizer call.

The conductor witness holds a shared collection window while a competing Class-A invalidator attempts to run. The optimizer generation remains unchanged until the window closes, then advances exactly once before the invalidator returns. A second witness warms a real named-property optimizer artifact, mutates the observed object through the parallel VM fast path, proves one generation rotation, and verifies the new value after fallback. Cooperative, abort-safe M3, and allocation-failure collectors retain their existing bounded convergence under the same lock in normal and TSan modes.

The accepted README benchmark report remains unchanged: its workloads and measured tier selection did not change in this batch.
