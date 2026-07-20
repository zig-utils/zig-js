// Consumer-side response bridge for Bun
// 4982b91e3702094330f3be3883354c52b8c01323.

#include <zig-js/FetchHeadersBridge.h>

#include <bun-uws/src/App.h>
#include <bun-uws/src/Http3Response.h>

#include <string_view>

static std::string_view view(ZJSFetchHeadersBridgeSpanV1 value)
{
    return { reinterpret_cast<const char*>(value.ptr), value.len };
}

static bool equalsIgnoringASCIICase(std::string_view left, std::string_view right)
{
    if (left.size() != right.size())
        return false;
    for (size_t index = 0; index < left.size(); ++index) {
        char a = left[index];
        char b = right[index];
        if (a >= 'A' && a <= 'Z')
            a = static_cast<char>(a + ('a' - 'A'));
        if (b >= 'A' && b <= 'Z')
            b = static_cast<char>(b + ('a' - 'A'));
        if (a != b)
            return false;
    }
    return true;
}

template<bool isSSL>
static bool writeHTTPResponse(
    void* rawResponse,
    const ZJSFetchHeadersBridgeRowV1* rows,
    size_t count)
{
    auto* response = reinterpret_cast<uWS::HttpResponse<isSSL>*>(rawResponse);
    auto* data = response->getHttpResponseData();
    for (size_t index = 0; index < count; ++index) {
        auto name = view(rows[index].name);
        if (equalsIgnoringASCIICase(name, "content-length")) {
            if (!(data->state & uWS::HttpResponseData<isSSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER)) {
                data->state |= uWS::HttpResponseData<isSSL>::HTTP_WROTE_CONTENT_LENGTH_HEADER;
                response->writeMark();
            }
        } else if (equalsIgnoringASCIICase(name, "date")) {
            data->state |= uWS::HttpResponseData<isSSL>::HTTP_WROTE_DATE_HEADER;
        } else if (equalsIgnoringASCIICase(name, "transfer-encoding")) {
            data->state |= uWS::HttpResponseData<isSSL>::HTTP_WROTE_TRANSFER_ENCODING_HEADER;
        }
        response->writeHeader(name, view(rows[index].value));
    }
    return true;
}

static bool writeH3Response(
    void* rawResponse,
    const ZJSFetchHeadersBridgeRowV1* rows,
    size_t count)
{
    auto* response = reinterpret_cast<uWS::Http3Response*>(rawResponse);
    auto* data = response->getHttpResponseData();
    for (size_t index = 0; index < count; ++index) {
        auto name = view(rows[index].name);
        if (equalsIgnoringASCIICase(name, "content-length")) {
            if (!(data->state & uWS::Http3ResponseData::HTTP_WROTE_CONTENT_LENGTH_HEADER)) {
                data->state |= uWS::Http3ResponseData::HTTP_WROTE_CONTENT_LENGTH_HEADER;
                response->writeMark();
            }
        } else if (equalsIgnoringASCIICase(name, "date")) {
            data->state |= uWS::Http3ResponseData::HTTP_WROTE_DATE_HEADER;
        }
        response->writeHeader(name, view(rows[index].value));
    }
    return true;
}

extern "C" bool ZigJS__FetchHeadersBridge__writeResponseV1(
    void* rawResponse,
    int32_t kind,
    const ZJSFetchHeadersBridgeRowV1* rows,
    size_t count)
{
    if (!rawResponse || (count && !rows))
        return false;
    switch (kind) {
    case kZJSFetchHeadersBridgeResponseTCP:
        return writeHTTPResponse<false>(rawResponse, rows, count);
    case kZJSFetchHeadersBridgeResponseSSL:
        return writeHTTPResponse<true>(rawResponse, rows, count);
    case kZJSFetchHeadersBridgeResponseH3:
        return writeH3Response(rawResponse, rows, count);
    default:
        return false;
    }
}
