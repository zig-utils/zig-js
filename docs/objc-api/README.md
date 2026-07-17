# Objective-C JavaScriptCore Bridge

zig-js targets the Objective-C JavaScriptCore headers shipped by macOS SDK
27.0 build 26A5368g. The checked-in
[`jsc-objc-api-macos-27.0.json`](jsc-objc-api-macos-27.0.json) inventory records
the SHA-256 of `JSContext.h`, `JSValue.h`, `JSVirtualMachine.h`,
`JSManagedValue.h`, and `JSExport.h`, plus every interface, category, protocol,
method, property, typedef, data symbol, macro, signature, and availability
annotation parsed from those headers.

The inventory contains 11 containers and 108 declarations and records
**108 implemented / 0 pending**. An `implemented` entry has runtime behavior
exercised by the compile-link-runtime host; representative semantic families
are also compared with system JavaScriptCore.

Run the checked-in drift gate on every host:

```sh
zig build objc-api-audit
```

On macOS, compile the headers with the real Objective-C ARC/blocks frontend:

```sh
zig build test-objc-api-headers
```

Compile, link, and execute the implemented runtime slice on macOS:

```sh
zig build test-objc-api
```

The installed static archive includes the Objective-C bridge. A manual
Objective-C host link therefore needs both Foundation and the system `libffi`
used for typed block calls:

```sh
xcrun clang -fobjc-arc -fblocks host.m \
  -I zig-out/include -L zig-out/lib -lzig-js -lffi \
  -framework Foundation -o host
```

Compare the completed Foundation conversion rows with system JavaScriptCore:

```sh
zig build objc-api-jsc-diff
```

The hosts exercise VM/context construction and identity, evaluation and
exception capture, context naming/inspectability, C-ref round trips, every
published `JSValue` family, recursive and cyclic Foundation conversion, promise
callback state, exact wrapper identity, managed ownership, typed Objective-C
blocks, and `JSExport` instance/class/renamed-selector behavior. The 17-row
transcript matches system JavaScriptCore exactly (`189ef5b0eefd1054`), including
same-VM cross-context value identity, exported receivers, constructors,
prototypes, and target-context wrapper behavior.
`JSManagedValue` and VM owner relations use real weak targets plus weak owners;
because current context groups use the VM-lifetime arena policy, unreachable
targets remain available until VM teardown rather than being reclaimed mid-VM.
Issues #159 and #160 continue tracking stronger lifetime/stress and completion
evidence beyond the now-complete declared inventory.

Compare the pin against an installed SDK explicitly:

```sh
python3 tools/verify-objc-api.py \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)"
```

The live comparison fails on any source hash, container, selector, property,
signature, availability, typedef, data-symbol, or macro drift. A different SDK
revision must receive a separately named inventory instead of silently changing
the compatibility target.

The copied Objective-C declarations are exposed only when Clang targets the
Apple Objective-C runtime. C, C++, Zig, and non-Apple consumers continue to use
the public C headers without importing or linking Foundation.

Runtime implementation and evidence are split into:

- #158 — `JSContext`, `JSVirtualMachine`, and `JSValue` behavior;
- #159 — managed references, wrapper identity, and lifetime semantics;
- #160 — `JSExport`, Objective-C blocks, conversions, and completion evidence.
