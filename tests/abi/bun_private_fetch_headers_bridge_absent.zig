const std = @import("std");

const FetchHeaders = opaque {};

extern "c" fn WebCore__FetchHeaders__createFromUWS(*anyopaque) *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__deref(*FetchHeaders) void;
extern "c" fn WebCore__FetchHeaders__isEmpty(*FetchHeaders) bool;
extern "c" fn WebCore__FetchHeaders__toUWSResponse(*FetchHeaders, i32, ?*anyopaque) void;

pub fn main() void {
    var opaque_request: u8 = 0;
    const headers = WebCore__FetchHeaders__createFromUWS(&opaque_request);
    defer WebCore__FetchHeaders__deref(headers);
    if (!WebCore__FetchHeaders__isEmpty(headers))
        std.debug.panic("missing UWS bridge did not fail closed", .{});
    var opaque_response: u8 = 0;
    WebCore__FetchHeaders__toUWSResponse(headers, 0, &opaque_response);
    std.debug.print("Bun private FetchHeaders: missing request/response bridges fail closed\n", .{});
}
