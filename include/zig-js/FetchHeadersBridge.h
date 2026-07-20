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
 * carry opaque C++ uWebSockets objects. A consumer installs a copied v1 table;
 * absent callbacks fail closed without any linker-specific weak imports.
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

typedef bool (*ZJSFetchHeadersBridgeVisitRequestV1)(
    void* request,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor);

typedef struct ZJSFetchHeadersBridgeRowV1 {
    ZJSFetchHeadersBridgeSpanV1 name;
    ZJSFetchHeadersBridgeSpanV1 value;
} ZJSFetchHeadersBridgeRowV1;

typedef enum ZJSFetchHeadersBridgeResponseKindV1 {
    kZJSFetchHeadersBridgeResponseTCP = 0,
    kZJSFetchHeadersBridgeResponseSSL = 1,
    kZJSFetchHeadersBridgeResponseH3 = 2,
} ZJSFetchHeadersBridgeResponseKindV1;

typedef bool (*ZJSFetchHeadersBridgeWriteResponseV1)(
    void* response,
    int32_t kind,
    const ZJSFetchHeadersBridgeRowV1* rows,
    size_t count);

typedef struct ZJSFetchHeadersBridgeV1 {
    uint32_t abiVersion;
    uint32_t structSize;
    ZJSFetchHeadersBridgeVisitRequestV1 visitUWSRequest;
    ZJSFetchHeadersBridgeVisitRequestV1 visitH3Request;
    ZJSFetchHeadersBridgeWriteResponseV1 writeResponse;
} ZJSFetchHeadersBridgeV1;

/* Copies each callback with release ordering; adapter calls acquire only the
 * callback they use. NULL clears the table. Invalid versions/sizes leave the
 * current table intact. */
bool ZigJS__FetchHeadersBridge__installV1(
    const ZJSFetchHeadersBridgeV1* bridge);

bool ZigJS__FetchHeadersBridge__visitUWSRequestV1(
    void* request,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor);

bool ZigJS__FetchHeadersBridge__visitH3RequestV1(
    void* request,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor);

bool ZigJS__FetchHeadersBridge__writeResponseV1(
    void* response,
    int32_t kind,
    const ZJSFetchHeadersBridgeRowV1* rows,
    size_t count);

#ifdef __cplusplus
}
#endif

#endif
