//! Unstable, revision-pinned private consumer ABI building blocks.

pub const EncodedValue = @import("private_abi/encoded_value.zig").EncodedValue;
pub const encoded_value = @import("private_abi/encoded_value.zig");
pub const jstype = @import("private_abi/jstype.zig");

test {
    _ = @import("private_abi/encoded_value.zig");
    _ = @import("private_abi/jstype.zig");
}
