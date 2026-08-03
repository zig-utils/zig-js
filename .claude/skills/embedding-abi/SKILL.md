---
name: embedding-abi
description: Change or verify zig-js embedding surfaces — the JavaScriptCore-shaped public C API, the macOS Objective-C bridge, and the revision-pinned private ABI profiles for named consumers (Home, Bun). Use when the task touches src/c_api.zig, src/private_abi*, include/, an exported symbol, a JSC-shaped header, a struct layout or enum value, or an audit/diff step.
---

# Embedding surfaces: public C API, Objective-C bridge, private ABI

These are **pinned contracts with external consumers**, not internal code. A
symbol, struct layout, enum value, or availability annotation that changes
without updating its inventory breaks a revision-checked downstream build.

## 1. The three surfaces

| Surface | Source | Inventory |
| --- | --- | --- |
| Public C API (JSC-shaped) | [`src/c_api.zig`](../../../src/c_api.zig) | [`docs/c-api/README.md`](../../../docs/c-api/README.md) + `jsc-public-api-macos-27.0.json` |
| Objective-C bridge (macOS) | [`src/objc_bridge.m`](../../../src/objc_bridge.m) | [`docs/objc-api/README.md`](../../../docs/objc-api/README.md) + `jsc-objc-api-macos-27.0.json` |
| Private ABI profiles | [`src/private_abi.zig`](../../../src/private_abi.zig), `src/private_abi/` | [`docs/abi/README.md`](../../../docs/abi/README.md) |

Headers install to `zig-out/include/JavaScriptCore/`; the library is
`zig-out/lib/libzig-js.a`. Embedding fixtures live in
[`tests/`](../../../tests/) (C, C++, Objective-C hosts).

**Language discipline:** this is an *implemented public subset target*. Never
call it "the JavaScriptCore framework", "full JSC", or "a drop-in". The
inventories separate `implemented` (exported with the pinned ABI **and** covered
by behavior tests) from `pending` (declared for source compatibility only).

## 2. Private profiles are revision-pinned

A private profile is supported only when its checked-in symbol/type contract,
its compile-link-runtime fixture, and its revision check all pass. Unknown
profile IDs and mismatched source revisions are **errors** — zig-js does not
silently approximate a moving private ABI. Profiles select with
`-Dprivate-abi-consumer=<consumer>`, `-Dhome-private-abi-profile=<id>`, and
source roots via `-Dhome-source-root` / `-Dbun-source-root`.

## 3. Verify

Audits (contract vs. inventory vs. exports):

```bash
zig build c-api-audit
zig build home-public-abi-audit
zig build home-private-abi-audit
zig build bun-private-abi-audit
zig build private-jstype-abi-audit
zig build objc-api-audit
```

Behavior fixtures — the boundary legs run each in **Debug, ReleaseSafe, and
TSan**, because a layout or lifetime bug frequently only appears in one:

```bash
zig build test-c-api                      # C and C++ hosts
zig build test-home-private-abi
zig build test-home-private-abi -Doptimize=ReleaseSafe
zig build test-home-private-abi -Dtsan=true
zig build test-private-consumer-providers
zig build test-bun-private-sql-structure -Dprivate-abi-consumer=bun
zig build test-private-global-lifecycle
zig build test-private-process-initialization
zig build test-private-heap-snapshot
zig build test-private-cpu-profile
zig build test-private-readable-stream
zig build test-private-wasm-streaming-compiler
zig build test-private-abi-mixed-profiles -Dprivate-abi-consumer=bun
```

Differential checks against the real system JavaScriptCore (macOS):

```bash
zig build c-api-jsc-diff
zig build objc-api-jsc-diff
zig build wasm-exception-jsc-diff
python3 tools/verify-c-api.py
python3 tools/verify-objc-api.py
python3 tools/verify-abi-profile.py
~/Code/Home/lang/zig-out/bin/home-tool run tools/private-abi-tsan.ts
python3 -m unittest tools/test_home_private_abi.py
```

Objective-C evidence matrix (macOS):

```bash
zig build test-objc-api-headers test-objc-api test-objc-api-lifetime
zig build test-objc-api-sanitize test-objc-api-leaks test-objc-api-faults
zig build test-objc-api-evidence     # the complete matrix
```

The exact CI leg list is in
[`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml) under
`private-abi-boundary` — treat it as the definition of "done".

## 4. Changing a surface

1. Decide whether the change is **additive** (new symbol, new pending entry) or
   **breaking** (signature, layout, enum value, removal). Breaking changes need
   the consumer revision pin updated in the same commit.
2. Update the JSON inventory alongside the code — audits compare them and fail
   on drift, including SHA-256s of the pinned system headers.
3. Move an entry from `pending` to `implemented` only when behavior tests cover
   it, not when the declaration compiles.
4. Run the audit, the fixture in all three build modes, and the JSC diff where
   one exists.
5. If the release matrix tracks the surface, refresh it:
   `zig build release-compatibility` and, when the headline moves,
   `python3 tools/release-compatibility.py --update-readme`.

## 5. Related surfaces

- **Inspector protocol** (`zig-js-inspector/0.1`) is exposed through
  `include/zig-js/Extensions.h`; public JSC inspectability stays opt-in and
  requires `JSGlobalContextSetInspectable(ctx, true)` before a session can be
  created. See [`docs/inspector.md`](../../../docs/inspector.md).
- **Threaded context creation** for embedders is
  `ZJSGlobalContextCreateThreaded(gil)` — the C-level form of the
  `.enable_threads` / `.gil` choice.
- The Home migration analysis lives in
  [`docs/HOME_INTEGRATION.md`](../../../docs/HOME_INTEGRATION.md); keep its
  status line honest about what is verified versus planned.
