#include <zig-js/FetchHeadersBridge.h>

namespace {
struct InstallFetchHeadersBridge {
    InstallFetchHeadersBridge()
    {
        const ZJSFetchHeadersBridgeV1 bridge {
            ZJS_FETCH_HEADERS_BRIDGE_ABI_VERSION,
            sizeof(ZJSFetchHeadersBridgeV1),
            ZigJS__FetchHeadersBridge__visitUWSRequestV1,
            ZigJS__FetchHeadersBridge__visitH3RequestV1,
            ZigJS__FetchHeadersBridge__writeResponseV1,
        };
        ZigJS__FetchHeadersBridge__installV1(&bridge);
    }
};

InstallFetchHeadersBridge installFetchHeadersBridge;
}
