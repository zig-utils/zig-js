const std = @import("std");
const js = @import("js");

const EncodedValue = js.private_abi.EncodedValue;

fn fail(message: []const u8) noreturn {
    std.debug.print("private ABI encoded value: {s}\n", .{message});
    std.process.exit(1);
}

pub fn main() void {
    if (@sizeOf(EncodedValue) != 8 or @alignOf(EncodedValue) != 8)
        fail("layout mismatch");
    if (EncodedValue.undefined.rawBits() != 0xa or
        EncodedValue.null.rawBits() != 0x2 or
        EncodedValue.false.rawBits() != 0x6 or
        EncodedValue.true.rawBits() != 0x7)
        fail("immediate constants mismatch");

    const internal_values = [_]js.Value{
        js.Value.undef(),
        js.Value.nul(),
        js.Value.boolVal(false),
        js.Value.boolVal(true),
        js.Value.num(-0.0),
        js.Value.num(42.5),
        js.Value.num(std.math.inf(f64)),
        js.Value.num(@bitCast(@as(u64, 0x7ff8_0000_0000_0042))),
    };
    for (internal_values) |internal| {
        const encoded = EncodedValue.fromInternalPrimitive(internal) catch
            fail("internal primitive encoding failed");
        const decoded = encoded.toInternalPrimitive(js.Value) catch
            fail("internal primitive decoding failed");
        if (internal.isNumber()) {
            if (@as(u64, @bitCast(internal.asNum())) != @as(u64, @bitCast(decoded.asNum())))
                fail("number payload changed");
        } else if (internal.kind() != decoded.kind() or
            (internal.isBoolean() and internal.asBool() != decoded.asBool()))
            fail("primitive kind changed");
    }

    if (EncodedValue.fromInternalPrimitive(js.Value.staticStr("cell"))) |_| {
        fail("string converted without an external cell handle");
    } else |error_value| if (error_value != error.CellRequiresHandle) {
        fail("wrong string conversion error");
    }

    std.debug.print("private ABI encoded value: exact JSC64 layout and primitive bridge passed\n", .{});
}
