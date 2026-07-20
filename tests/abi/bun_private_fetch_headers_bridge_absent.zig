const std = @import("std");

const FetchHeaders = opaque {};

extern "c" fn WebCore__FetchHeaders__createFromUWS(*anyopaque) *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__deref(*FetchHeaders) void;
extern "c" fn WebCore__FetchHeaders__isEmpty(*FetchHeaders) bool;

pub fn main() void {
    var opaque_request: u8 = 0;
    const headers = WebCore__FetchHeaders__createFromUWS(&opaque_request);
    defer WebCore__FetchHeaders__deref(headers);
    if (!WebCore__FetchHeaders__isEmpty(headers))
        std.debug.panic("missing UWS bridge did not fail closed", .{});
    std.debug.print("Bun private FetchHeaders: missing request bridge fails closed\n", .{});
}
