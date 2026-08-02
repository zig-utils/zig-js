---
title: Dependency Ownership
description: The fail-closed dependency, platform, oracle, and acquisition policy for zig-js.
---

# Dependency ownership

zig-js has one machine-readable dependency boundary:
[`docs/.data/dependency-inventory-v1.json`](.data/dependency-inventory-v1.json).
`zig build dependency-audit` validates that inventory and rejects an unknown
local package, system link, build subprocess, script runtime, registry package,
submodule, corpus checkout, release download, or production dynamic-loading
edge. The gate itself is implemented in Zig and performs no network access.

Every external edge has exactly one class:

| Class | Permitted use |
| --- | --- |
| `zig_toolchain` | The Zig compiler and standard library used to produce the engine. |
| `standard_platform_interface` | Target C/C++ ABI and named SDK interfaces such as Foundation; never an imported JavaScript implementation. |
| `zig_utils_owned_local` | An owned sibling checkout resolved by local path. The production allowlist is exactly `../zig-regex` and `../zig-gc`. |
| `checksum_pinned_oracle` | A named test, differential, or benchmark input pinned by git object ID or release checksum. |
| `generated_data_acquisition_input` | A one-shot source for checked-in generated tables; it is not contacted by ordinary build or test steps. |
| `prohibited_unclassified` | An edge that cannot remain. A checked migration issue is mandatory, so this state cannot become a silent exemption. |

Each inventory record also states its scope, locator, pin, license, and whether
it can affect runtime semantics. Ambiguous or missing fields fail the audit.

## Production boundary

`build.zig.zon` contains only the two owned local dependencies. It has no URL or
package-registry resolution, and the normal library graph contains no fetch
command. CI checks out those siblings at the exact revisions recorded in the
inventory, using the same adjacent paths as a local build.

The macOS Objective-C bridge may use the Xcode SDK and Foundation as the
platform interface it implements. System JavaScriptCore is isolated to the
explicit differential and benchmark executables; it never links into
`libzig-js.a` or supplies engine semantics. Upstream corpora and Wasm converters
are likewise oracle-only inputs to named targets, with git or SHA-256 pins.

## Open migration edges

The inventory deliberately records current violations instead of relabeling
them as acceptable:

- system libffi in Objective-C call lowering is owned by [#463](https://github.com/zig-utils/zig-js/issues/463);
- the BunPress registry chain and Bun CI bootstrap are owned by [#464](https://github.com/zig-utils/zig-js/issues/464);
- Python, JavaScript/TypeScript, shell tooling, and legacy unpinned generator
  acquisition, plus mutable third-party CI bootstrap actions, are owned by
  [#497](https://github.com/zig-utils/zig-js/issues/497).

These entries have `migration_required` status. They remain visible and gated,
but are not permanent exceptions to the owned-dependency target.

## Changing a dependency edge

Update the implementation and inventory in the same commit, including the
semantic-effect ruling and an exact pin where the class requires one. Then run:

```bash
zig build dependency-audit
```

Adding an edge without a complete classification is intentionally impossible to
land through the required CI gate.
