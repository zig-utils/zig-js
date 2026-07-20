#ifndef ZIG_JS_FETCH_HEADERS_BRIDGE_H
#define ZIG_JS_FETCH_HEADERS_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Versioned consumer bridge for FetchHeaders APIs whose pinned signatures
 * carry opaque C++ uWebSockets objects. zig-js provides weak fail-closed
 * definitions; a consumer's strong definitions replace them when linked.
 * Every span is borrowed only for the duration of the visitor call.
 */
#define ZJS_FETCH_HEADERS_BRIDGE_ABI_VERSION 1u

typedef struct ZJSFetchHeadersBridgeSpanV1 {
    const uint8_t* ptr;
    size_t len;
} ZJSFetchHeadersBridgeSpanV1;

typedef bool (*ZJSFetchHeadersBridgeVisitorV1)(
    void* context,
    ZJSFetchHeadersBridgeSpanV1 name,
    ZJSFetchHeadersBridgeSpanV1 value);

bool ZigJS__FetchHeadersBridge__visitUWSRequestV1(
    void* request,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor);

bool ZigJS__FetchHeadersBridge__visitH3RequestV1(
    void* request,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor);

#ifdef __cplusplus
}
#endif

#endif
