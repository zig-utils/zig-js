---
title: Dependency Ownership
description: The fail-closed dependency, platform, oracle, and acquisition policy for zig-js.
---

# Dependency ownership

zig-js has a machine-readable dependency boundary:
[`docs/.data/dependency-inventory-v1.json`](.data/dependency-inventory-v1.json),
plus the issue #497 repository-tool migration inventory at
[`docs/.data/tool-migration-inventory-v1.json`](.data/tool-migration-inventory-v1.json).
`zig build dependency-audit` validates both inventories and rejects an unknown
local package, system link, build subprocess, script runtime, registry package,
submodule, corpus checkout, release download, or production dynamic-loading
edge. The gate itself is implemented in Zig and performs no network access.

Every external edge has exactly one class:

| Class | Permitted use |
| --- | --- |
| `zig_toolchain` | The Zig compiler and standard library used to produce the engine. |
| `standard_platform_interface` | Target C/C++ ABI and named SDK interfaces such as Foundation; never an imported JavaScript implementation. |
| `owner_maintained_local` | An owner-maintained sibling checkout resolved by local path. The production allowlist is exactly `../zig-regex` and `../zig-gc`; owned tools such as BunPress are scoped separately. |
| `owner_maintained_pinned_tooling` | An owner-maintained build/bootstrap tool fixed to immutable source and executable versions; never part of engine semantics. |
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

Documentation deliberately uses the owner-maintained BunPress source checkout
at `../../Tools/bunpress`. BunPress, STX, and ts-syntax-highlighter are each
resolved from their owner-maintained sibling checkout, and all three exact
revisions are recorded in the inventory. CI uses the same `Libraries/` plus
`Tools/` layout, builds those owned sources, and verifies the workspace links
before rendering. Missing behavior is fixed in the owning repository and then
consumed here; zig-js does not carry substitutes.

The macOS Objective-C bridge may use the Xcode SDK and Foundation as the
platform interface it implements. System JavaScriptCore is isolated to the
explicit differential and benchmark executables; it never links into
`libzig-js.a` or supplies engine semantics. Upstream corpora and Wasm converters
are likewise oracle-only inputs to named targets, with git or SHA-256 pins.

## Open migration edges

The BunPress edge is fully classified: zig-js consumes its exact local source,
CI pins the complete owned renderer graph, and BunPress declares, builds, and
verifies its STX and syntax-highlighter workspaces from its own frozen lockfile.
The remaining inventory deliberately records current violations instead of
relabeling them as acceptable:

- Python and legacy JavaScript tooling, unpinned generator acquisition, and
  mutable checkout actions are owned by
  [#497](https://github.com/zig-utils/zig-js/issues/497).

Those entries have `migration_required` status. They remain visible and gated,
but are not permanent exceptions to the owned-dependency target.

The tool migration inventory classifies 70 executable tools: 44 `.py`, 2
`.mjs`, 24 `.ts`, and no `.sh`; shared TypeScript modules are counted separately
by the dependency gate. The documentation link gate has already moved to
the tested in-tree `docs-link-check` Zig executable and is no longer part of
that migration set. Each remaining record identifies its role, inputs, outputs,
subprocesses, caller/reference files, effective exit and diagnostic contract,
ordering and schema requirements, network policy, and disposition. Durable
tools are candidates for TypeScript execution on the owner-maintained Home
engine after that runner contract is ready; the inventory does not require a
one-for-one rewrite of every legacy script. The audit reads the Git index and
rejects a missing or stale tool record, extension/runtime mismatch, unknown
contract profile, or new caller/reference file. Tracked symlinks are not
followed because their real tracked targets are audited directly.

The former system-libffi edge was removed by the owned Zig/assembly dispatcher
tracked in [#463](https://github.com/zig-utils/zig-js/issues/463); it is no
longer an inventory entry or link dependency.

## Changing a dependency edge

Update the implementation and inventory in the same commit, including the
semantic-effect ruling and an exact pin where the class requires one. Then run:

```bash
zig build dependency-audit
```

Adding an edge without a complete classification is intentionally impossible to
land through the required CI gate.
