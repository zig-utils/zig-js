# Exact-parent WeakMap/WeakSet allocation attribution — 2026-08-10

This is the allocation companion to the seven-pair post-moving-GC CPU and
memory evidence for [#523](https://github.com/zig-utils/zig-js/issues/523).

- parent: `bfc795fddf36240eab5124fcb04c5a670368c114`
- candidate: `6989099bb20f05ae19c3b0811b879bcc8439f414`
- workload: `representative_weak_post_compact_4096`, one job, checksum `25201340`
- runner mode: `attribution`; the identical mixed object/Symbol 4K WeakMap and
  4K WeakSet fixture is present in the configuration snapshot
- raw evidence: [exact-parent-weak-lookup-allocation-2026-08-10.json](exact-parent-weak-lookup-allocation-2026-08-10.json)

| metric | parent configuration | candidate configuration | candidate - parent |
| --- | ---: | ---: | ---: |
| backing allocation calls | 18,687 | 18,687 | 0 |
| backing allocation bytes | 11,841,343 | 11,841,351 | +8 |
| backing growth calls | 309 | 311 | +2 |
| backing growth bytes | 321,490 | 407,794 | +86,304 |
| backing current bytes | 11,819,697 | 11,906,009 | +86,312 |
| backing peak bytes | 11,819,697 | 11,906,009 | +86,312 |
| GC-cell allocation calls | 12,964 | 12,964 | 0 |
| GC-cell bytes | 1,462,016 | 1,462,016 | 0 |

The bounded 86,312-byte increase covers stable identities and authoritative
indexes for 8,192 total weak entries. The engine adds no fixture-level backing
allocation call and no GC cell.

| scored invocation delta | parent | candidate |
| --- | ---: | ---: |
| backing allocation calls | 9 | 9 |
| backing allocation bytes | 681 | 681 |
| backing growth calls / bytes | 0 / 0 | 0 / 0 |
| backing current bytes | 457 | 457 |
| backing peak bytes | 678 | 678 |
| GC-cell allocation calls / bytes | 2 / 512 | 2 / 512 |

The small identical invocation delta is the runner's evaluation wrapper. Weak
lookup itself performs no differential or proportional allocation, and the
candidate does not rebuild the authoritative index on lookup. The separate
post-compaction timing rows force successful cell movement before their timed
invocations; this attribution mode deliberately isolates allocation accounting
and does not claim to time or allocate the moving collection itself.
