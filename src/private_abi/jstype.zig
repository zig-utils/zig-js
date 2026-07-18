//! Revision-pinned private JSType tags selected for one consumer build.

const options = @import("private_abi_options");

pub const Profile = enum {
    home,
    bun,
};

pub const selected_profile: Profile = if (options.is_bun) .bun else .home;

/// The Home values are explicit. Bun inserts WebAssemblyStreamingContext at
/// tag 27, so every shared member after it is shifted by one in the pinned Bun
/// profile. The full 97/98-member layouts and their source hashes live in
/// docs/abi/private-jstype-layouts.json.
pub const Kind = enum(u8) {
    String = 2,
    HeapBigInt = 3,
    Symbol = 6,
    GetterSetter = 7,
    CustomGetterSetter = 8,
    FinalObject = 34,
    JSFunction = 36,
    InternalFunction = 37,
    BooleanObject = 39,
    NumberObject = 40,
    ErrorInstance = 41,
    DirectArguments = 43,
    Array = 46,
    ArrayBuffer = 48,
    Int8Array = 49,
    Uint8Array = 50,
    Uint8ClampedArray = 51,
    Int16Array = 52,
    Uint16Array = 53,
    Int32Array = 54,
    Uint32Array = 55,
    Float16Array = 56,
    Float32Array = 57,
    Float64Array = 58,
    BigInt64Array = 59,
    BigUint64Array = 60,
    DataView = 61,
    ModuleNamespaceObject = 70,
    ShadowRealm = 71,
    RegExpObject = 72,
    JSDate = 73,
    ProxyObject = 74,
    Generator = 75,
    IteratorHelper = 79,
    JSPromise = 86,
    Map = 87,
    Set = 88,
    WeakMap = 89,
    WeakSet = 90,
    StringObject = 94,
};

pub inline fn selectedTag(kind: Kind) u8 {
    const home_tag = @intFromEnum(kind);
    return home_tag + @intFromBool(selected_profile == .bun and home_tag >= 27);
}

test "profile shift begins after the Bun-only tag" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 2), selectedTag(.String));
    try std.testing.expectEqual(
        @as(u8, if (selected_profile == .bun) 35 else 34),
        selectedTag(.FinalObject),
    );
    try std.testing.expectEqual(
        @as(u8, if (selected_profile == .bun) 61 else 60),
        selectedTag(.BigUint64Array),
    );
}
