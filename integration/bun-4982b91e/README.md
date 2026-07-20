# Bun 4982b91e FetchHeaders bridge

This directory contains the consumer half of zig-js's version-1 FetchHeaders
server bridge for Bun commit `4982b91e3702094330f3be3883354c52b8c01323`.
The pinned private ABI passes uWebSockets request objects as `*anyopaque`; their
C++ layout is intentionally never reproduced in Zig.

Compile `FetchHeadersRequestBridge.cpp` as one Bun C++ translation unit with
zig-js's installed headers on the include path, then link the object with
`libzig-js`. It provides strong definitions for the two symbols declared by
`<zig-js/FetchHeadersBridge.h>`:

- `ZigJS__FetchHeadersBridge__visitUWSRequestV1`
- `ZigJS__FetchHeadersBridge__visitH3RequestV1`

The first copies Bun's pinned `uWS::HttpRequest` view and iterates it exactly as
the original binding did. The second calls the pinned
`uWS::Http3Request::forEachHeader`. Both synchronously lend each name/value span
to zig-js; zig-js copies the bytes before the callback returns. Returning
`false` aborts the whole import atomically. Null objects, invalid spans, callback
failure, or a missing bridge produce a valid empty native Headers handle.

`libzig-js` contains weak fail-closed definitions so ordinary embedders link on
Mach-O, ELF, and COFF without this object. Linking this translation unit
replaces those defaults; no C++ object is ever interpreted by zig-js itself.

This contract is revisioned, not a promise that arbitrary uWebSockets versions
share an object layout. A future incompatible adapter must add a new symbol
version rather than silently changing `V1`.
