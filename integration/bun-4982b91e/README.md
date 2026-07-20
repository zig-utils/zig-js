# Bun 4982b91e FetchHeaders bridge

This directory contains the consumer half of zig-js's version-1 FetchHeaders
server bridge for Bun commit `4982b91e3702094330f3be3883354c52b8c01323`.
The pinned private ABI passes uWebSockets request objects as `*anyopaque`; their
C++ layout is intentionally never reproduced in Zig.

Compile all three `.cpp` files as Bun C++ translation units with zig-js's
installed headers on the include path, then link the objects with `libzig-js`.
The request/response files define the three callbacks declared by
`<zig-js/FetchHeadersBridge.h>`:

- `ZigJS__FetchHeadersBridge__visitUWSRequestV1`
- `ZigJS__FetchHeadersBridge__visitH3RequestV1`
- `ZigJS__FetchHeadersBridge__writeResponseV1`

The first copies Bun's pinned `uWS::HttpRequest` view and iterates it exactly as
the original binding did. The second calls the pinned
`uWS::Http3Request::forEachHeader`. Both synchronously lend each name/value span
to zig-js; zig-js copies the bytes before the callback returns. Returning
`false` aborts the whole import atomically. Null objects, invalid spans, callback
failure, or a missing bridge produce a valid empty native Headers handle.

`FetchHeadersBridgeInstall.cpp` installs a copied version/size-checked function
table during C++ static initialization. Without that installer, every opaque
adapter fails closed, independently of Mach-O/ELF/COFF symbol-preemption rules.
No C++ object is ever interpreted by zig-js itself.

The response bridge receives copied rows in the pinned binding order:
Set-Cookie occurrences first, then known/common headers, then uncommon headers.
It dispatches Bun's exact `ResponseKind` values (TCP `0`, SSL `1`, H3 `2`),
calls the concrete `writeHeader`/`writeMark` methods, and updates the pinned
Content-Length, Date, and Transfer-Encoding state flags. HTTP/3 has no
Transfer-Encoding state flag, matching the pinned implementation.

This contract is revisioned, not a promise that arbitrary uWebSockets versions
share an object layout. A future incompatible adapter must add a new symbol
version rather than silently changing `V1`.
