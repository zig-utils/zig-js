# JIT publication and retirement gate — 2026-07-22

Commit: `fdb27940`

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

The retirement witness rotates and reclaims 32 executable generations, verifies zero live/retired bytes at steady state, and proves a later-generation reader does not delay an older generation. The publication witness races two writers and a resetter against a reader for 20,000 iterations each, then the VM witness proves the installed link is consumed by a real optimizer call.

The accepted README benchmark report remains unchanged: its workloads and measured tier selection did not change in this batch.
