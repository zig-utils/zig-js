#!/bin/sh
# tools/wasm-spec/fetch.sh — fetch the pinned upstream WebAssembly spec
# testsuite (wg-1.0, pure MVP) into a local directory for regeneration.
#
# Usage: sh tools/wasm-spec/fetch.sh <out-dir>
# Then:  (cd tools/wasm-spec && bun install) && bun tools/wasm-spec/gen.mjs <out-dir>/test/core tests/wasm/spec
# Finally: zig build wasm-spec -Dwasm-spec-out=tests/wasm/spec/inventory.json
set -eu

PIN_SHA="977f97014c962f7bd1291fcc6d28b41a924882bf"
OUT="${1:?usage: fetch.sh <out-dir>}"

mkdir -p "$OUT"
curl -sL "https://github.com/WebAssembly/spec/archive/${PIN_SHA}.tar.gz" | tar -xz --strip-components=1 -C "$OUT"
echo "fetched WebAssembly/spec@${PIN_SHA} (wg-1.0) into $OUT"
