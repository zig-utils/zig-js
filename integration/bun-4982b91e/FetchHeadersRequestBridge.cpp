// Consumer-side bridge for Bun 4982b91e3702094330f3be3883354c52b8c01323.
// Compile this translation unit inside Bun so the includes resolve to Bun's
// pinned uWebSockets checkout, then link it with zig-js.

#include <zig-js/FetchHeadersBridge.h>

#include <bun-uws/src/App.h>
#include <bun-uws/src/Http3Request.h>

#include <string_view>

static ZJSFetchHeadersBridgeSpanV1 span(std::string_view value)
{
    return { reinterpret_cast<const uint8_t*>(value.data()), value.size() };
}

extern "C" bool ZigJS__FetchHeadersBridge__visitUWSRequestV1(
    void* rawRequest,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor)
{
    if (!rawRequest || !visitor)
        return false;
    auto request = *reinterpret_cast<uWS::HttpRequest*>(rawRequest);
    for (const auto& header : request) {
        if (!visitor(context, span(header.first), span(header.second)))
            return false;
    }
    return true;
}

extern "C" bool ZigJS__FetchHeadersBridge__visitH3RequestV1(
    void* rawRequest,
    void* context,
    ZJSFetchHeadersBridgeVisitorV1 visitor)
{
    if (!rawRequest || !visitor)
        return false;
    auto* request = reinterpret_cast<uWS::Http3Request*>(rawRequest);
    bool accepted = true;
    request->forEachHeader([&](std::string_view name, std::string_view value) {
        if (accepted)
            accepted = visitor(context, span(name), span(value));
    });
    return accepted;
}
