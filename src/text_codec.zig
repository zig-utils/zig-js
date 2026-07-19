//! Revision-pinned native TextCodec fallback used by the Home/Bun private ABI.
//!
//! The pinned consumer deliberately handles UTF-8, UTF-16, and Latin-1 outside
//! this boundary. This registry therefore mirrors only its remaining Encoding
//! Standard codecs and keeps incremental decoder state in an opaque record.

const std = @import("std");
const tables = @import("text_codec_tables.zig");

pub const Encoding = enum {
    x_user_defined,
    replacement,
    big5,
    euc_jp,
    shift_jis,
    euc_kr,
    iso_2022_jp,
    gbk,
    gb18030,
    iso_8859_3,
    iso_8859_6,
    iso_8859_7,
    iso_8859_8,
    iso_8859_8_i,
    windows_874,
    windows_1253,
    windows_1255,
    windows_1257,
    koi8_u,
    ibm866,

    pub fn canonicalName(self: Encoding) []const u8 {
        return switch (self) {
            .x_user_defined => "x-user-defined",
            .replacement => "replacement",
            .big5 => "Big5",
            .euc_jp => "EUC-JP",
            .shift_jis => "Shift_JIS",
            .euc_kr => "EUC-KR",
            .iso_2022_jp => "ISO-2022-JP",
            .gbk => "GBK",
            .gb18030 => "gb18030",
            .iso_8859_3 => "ISO-8859-3",
            .iso_8859_6 => "ISO-8859-6",
            .iso_8859_7 => "ISO-8859-7",
            .iso_8859_8 => "ISO-8859-8",
            .iso_8859_8_i => "ISO-8859-8-I",
            .windows_874 => "windows-874",
            .windows_1253 => "windows-1253",
            .windows_1255 => "windows-1255",
            .windows_1257 => "windows-1257",
            .koi8_u => "KOI8-U",
            .ibm866 => "IBM866",
        };
    }
};

const AliasGroup = struct {
    encoding: Encoding,
    aliases: []const []const u8,
};

const alias_groups = [_]AliasGroup{
    .{ .encoding = .x_user_defined, .aliases = &.{"x-user-defined"} },
    .{ .encoding = .replacement, .aliases = &.{ "replacement", "csiso2022kr", "hz-gb-2312", "iso-2022-cn", "iso-2022-cn-ext", "iso-2022-kr" } },
    .{ .encoding = .big5, .aliases = &.{ "Big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5" } },
    .{ .encoding = .euc_jp, .aliases = &.{ "EUC-JP", "cseucpkdfmtjapanese", "x-euc-jp" } },
    .{ .encoding = .shift_jis, .aliases = &.{ "Shift_JIS", "csshiftjis", "ms932", "ms_kanji", "shift-jis", "sjis", "windows-31j", "x-sjis" } },
    .{ .encoding = .euc_kr, .aliases = &.{ "EUC-KR", "cseuckr", "csksc56011987", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "windows-949", "x-windows-949", "x-uhc" } },
    .{ .encoding = .iso_2022_jp, .aliases = &.{ "ISO-2022-JP", "csiso2022jp" } },
    .{ .encoding = .gbk, .aliases = &.{ "GBK", "chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80", "iso-ir-58", "x-gbk", "cn-gb", "csgb231280", "x-euc-cn", "euc-cn", "cp936", "ms936", "gb2312-1980", "windows-936", "windows-936-2000" } },
    .{ .encoding = .gb18030, .aliases = &.{ "gb18030", "ibm-1392", "windows-54936" } },
    .{ .encoding = .iso_8859_3, .aliases = &.{ "ISO-8859-3", "csisolatin3", "iso-ir-109", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "l3", "latin3" } },
    .{ .encoding = .iso_8859_6, .aliases = &.{ "ISO-8859-6", "arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987" } },
    .{ .encoding = .iso_8859_7, .aliases = &.{ "ISO-8859-7", "csisolatingreek", "ecma-118", "elot_928", "greek", "greek8", "iso-ir-126", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "sun_eu_greek" } },
    .{ .encoding = .iso_8859_8, .aliases = &.{ "ISO-8859-8", "csiso88598e", "csisolatinhebrew", "hebrew", "iso-8859-8-e", "iso-ir-138", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "visual" } },
    .{ .encoding = .iso_8859_8_i, .aliases = &.{ "ISO-8859-8-I", "csiso88598i", "logical" } },
    .{ .encoding = .windows_874, .aliases = &.{ "windows-874", "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620" } },
    .{ .encoding = .windows_1253, .aliases = &.{ "windows-1253", "cp1253", "x-cp1253" } },
    .{ .encoding = .windows_1255, .aliases = &.{ "windows-1255", "cp1255", "x-cp1255" } },
    .{ .encoding = .windows_1257, .aliases = &.{ "windows-1257", "cp1257", "x-cp1257" } },
    .{ .encoding = .koi8_u, .aliases = &.{ "KOI8-U", "koi8-ru" } },
    .{ .encoding = .ibm866, .aliases = &.{ "IBM866", "866", "cp866", "csibm866" } },
};

/// The pinned registry rejects empty/non-ASCII labels and caps labels at 63
/// bytes before performing ASCII-only case folding. It does not trim input.
pub fn canonicalEncoding(label: []const u8) ?Encoding {
    if (label.len == 0 or label.len > 63) return null;
    for (label) |byte| if (!std.ascii.isAscii(byte)) return null;
    for (alias_groups) |group| {
        for (group.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(label, alias)) return group.encoding;
        }
    }
    return null;
}

pub const DecodeResult = struct {
    bytes: []u8,
    saw_error: bool,

    pub fn deinit(self: DecodeResult, allocator: std.mem.Allocator) void {
        if (self.bytes.len > 0) allocator.free(self.bytes);
    }
};

const Iso2022State = enum(u3) {
    ascii,
    roman,
    katakana,
    lead_byte,
    trail_byte,
    escape_start,
    escape,
};

pub const Codec = struct {
    encoding: Encoding,
    replacement_sent: bool = false,
    jis0212: bool = false,
    iso_state: Iso2022State = .ascii,
    iso_output_state: Iso2022State = .ascii,
    iso_output: bool = false,
    iso_second_prepended: ?u8 = null,
    gb_first: u8 = 0,
    gb_second: u8 = 0,
    gb_third: u8 = 0,
    lead: u8 = 0,
    prepended: ?u8 = null,

    pub fn init(encoding: Encoding) Codec {
        return .{ .encoding = encoding };
    }

    pub fn deinit(self: *Codec) void {
        _ = self;
    }

    pub fn decode(
        self: *Codec,
        allocator: std.mem.Allocator,
        data: []const u8,
        flush: bool,
        stop_on_error: bool,
    ) error{OutOfMemory}!DecodeResult {
        return switch (self.encoding) {
            .x_user_defined => self.decodeUserDefined(allocator, data),
            .replacement => self.decodeReplacement(allocator),
            .iso_8859_3,
            .iso_8859_6,
            .iso_8859_7,
            .iso_8859_8,
            .iso_8859_8_i,
            .windows_874,
            .windows_1253,
            .windows_1255,
            .windows_1257,
            .koi8_u,
            .ibm866,
            => self.decodeSingleByte(allocator, data, stop_on_error),
            .iso_2022_jp => self.decodeIso2022Jp(allocator, data, flush, stop_on_error),
            .gbk, .gb18030 => self.decodeGb(allocator, data, flush, stop_on_error),
            .big5, .euc_jp, .shift_jis, .euc_kr => self.decodeCommon(allocator, data, flush, stop_on_error),
        };
    }

    fn decodeUserDefined(
        self: *Codec,
        allocator: std.mem.Allocator,
        data: []const u8,
    ) error{OutOfMemory}!DecodeResult {
        _ = self;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.ensureTotalCapacity(allocator, data.len *| 3);
        for (data) |byte| {
            if (byte < 0x80) {
                out.appendAssumeCapacity(byte);
            } else {
                var encoded: [3]u8 = undefined;
                const count = std.unicode.utf8Encode(@as(u21, 0xf700) | byte, &encoded) catch unreachable;
                out.appendSliceAssumeCapacity(encoded[0..count]);
            }
        }
        return finish(&out, allocator, false);
    }

    fn decodeReplacement(
        self: *Codec,
        allocator: std.mem.Allocator,
    ) error{OutOfMemory}!DecodeResult {
        if (self.replacement_sent) return .{ .bytes = &.{}, .saw_error = true };
        self.replacement_sent = true;
        return .{ .bytes = try allocator.dupe(u8, "\xef\xbf\xbd"), .saw_error = true };
    }

    fn finish(out: *std.ArrayList(u8), allocator: std.mem.Allocator, saw_error: bool) error{OutOfMemory}!DecodeResult {
        return .{ .bytes = try out.toOwnedSlice(allocator), .saw_error = saw_error };
    }

    fn appendCodePoint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, code_point: u21) error{OutOfMemory}!void {
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(code_point, &encoded) catch unreachable;
        try out.appendSlice(allocator, encoded[0..count]);
    }

    fn appendReplacement(out: *std.ArrayList(u8), allocator: std.mem.Allocator) error{OutOfMemory}!void {
        try appendCodePoint(out, allocator, 0xfffd);
    }

    fn singleByteTable(self: *const Codec) u4 {
        return switch (self.encoding) {
            .iso_8859_3 => 0,
            .iso_8859_6 => 1,
            .iso_8859_7 => 2,
            .iso_8859_8, .iso_8859_8_i => 3,
            .windows_874 => 4,
            .windows_1253 => 5,
            .windows_1255 => 6,
            .windows_1257 => 7,
            .koi8_u => 8,
            .ibm866 => 9,
            else => unreachable,
        };
    }

    fn decodeSingleByte(
        self: *Codec,
        allocator: std.mem.Allocator,
        data: []const u8,
        stop_on_error: bool,
    ) error{OutOfMemory}!DecodeResult {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.ensureTotalCapacity(allocator, data.len *| 3);
        var saw_error = false;
        for (data) |byte| {
            const code_point: u21 = if (byte < 0x80) byte else tables.singleByte(self.singleByteTable(), byte);
            if (code_point == 0xfffd) saw_error = true;
            try appendCodePoint(&out, allocator, code_point);
            if (saw_error and stop_on_error) break;
        }
        return finish(&out, allocator, saw_error);
    }

    fn parseCommonByte(
        self: *Codec,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        byte: u8,
        saw_error: *bool,
    ) error{OutOfMemory}!bool {
        return switch (self.encoding) {
            .euc_jp => self.parseEucJp(out, allocator, byte),
            .shift_jis => self.parseShiftJis(out, allocator, byte),
            .euc_kr => self.parseEucKr(out, allocator, byte),
            .big5 => self.parseBig5(out, allocator, byte),
            .gbk, .gb18030 => self.parseGb(out, allocator, byte, saw_error),
            else => unreachable,
        };
    }

    fn processCommonByte(
        self: *Codec,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        byte: u8,
        stop_on_error: bool,
        saw_error: *bool,
    ) error{OutOfMemory}!bool {
        if (!try self.parseCommonByte(out, allocator, byte, saw_error)) return false;
        saw_error.* = true;
        try appendReplacement(out, allocator);
        if (!stop_on_error) return false;
        self.lead = 0;
        return true;
    }

    fn processCommon(
        self: *Codec,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        data: []const u8,
        flush: bool,
        stop_on_error: bool,
        saw_error: *bool,
    ) error{OutOfMemory}!bool {
        if (self.prepended) |prepended| {
            self.prepended = null;
            if (try self.processCommonByte(out, allocator, prepended, stop_on_error, saw_error)) return true;
        }
        for (data) |byte| {
            if (try self.processCommonByte(out, allocator, byte, stop_on_error, saw_error)) return true;
            if (self.prepended) |prepended| {
                self.prepended = null;
                if (try self.processCommonByte(out, allocator, prepended, stop_on_error, saw_error)) return true;
            }
        }
        if (flush and self.lead != 0) {
            self.lead = 0;
            saw_error.* = true;
            try appendReplacement(out, allocator);
        }
        return false;
    }

    fn decodeCommon(
        self: *Codec,
        allocator: std.mem.Allocator,
        data: []const u8,
        flush: bool,
        stop_on_error: bool,
    ) error{OutOfMemory}!DecodeResult {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var saw_error = false;
        _ = try self.processCommon(&out, allocator, data, flush, stop_on_error, &saw_error);
        return finish(&out, allocator, saw_error);
    }

    fn parseEucJp(self: *Codec, out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) error{OutOfMemory}!bool {
        if (self.lead != 0) {
            const lead = self.lead;
            self.lead = 0;
            if (lead == 0x8e and byte >= 0xa1 and byte <= 0xdf) {
                try appendCodePoint(out, allocator, @as(u21, 0xff61) - 0xa1 + byte);
                return false;
            }
            if (lead == 0x8f and byte >= 0xa1 and byte <= 0xfe) {
                self.jis0212 = true;
                self.lead = byte;
                return false;
            }
            if (lead >= 0xa1 and lead <= 0xfe and byte >= 0xa1 and byte <= 0xfe) {
                const pointer: u16 = (@as(u16, lead) - 0xa1) * 94 + byte - 0xa1;
                const use_jis0212 = self.jis0212;
                self.jis0212 = false;
                const code_point = if (use_jis0212) tables.jis0212(pointer) else tables.jis0208(pointer);
                if (code_point) |value| {
                    try appendCodePoint(out, allocator, value);
                    return false;
                }
            }
            if (byte < 0x80) self.prepended = byte;
            return true;
        }
        if (byte < 0x80) {
            try out.append(allocator, byte);
            return false;
        }
        if (byte == 0x8e or byte == 0x8f or (byte >= 0xa1 and byte <= 0xfe)) {
            self.lead = byte;
            return false;
        }
        return true;
    }

    fn parseShiftJis(self: *Codec, out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) error{OutOfMemory}!bool {
        if (self.lead != 0) {
            const lead = self.lead;
            self.lead = 0;
            const offset: u8 = if (byte < 0x7f) 0x40 else 0x41;
            const lead_offset: u8 = if (lead < 0xa0) 0x81 else 0xc1;
            if ((byte >= 0x40 and byte <= 0x7e) or (byte >= 0x80 and byte <= 0xfc)) {
                const pointer: u16 = (@as(u16, lead) - lead_offset) * 188 + byte - offset;
                if (pointer >= 8836 and pointer <= 10715) {
                    try appendCodePoint(out, allocator, 0xe000 - 8836 + pointer);
                    return false;
                }
                if (tables.jis0208(pointer)) |code_point| {
                    try appendCodePoint(out, allocator, code_point);
                    return false;
                }
            }
            if (byte < 0x80) self.prepended = byte;
            return true;
        }
        if (byte < 0x80 or byte == 0x80) {
            try appendCodePoint(out, allocator, byte);
            return false;
        }
        if (byte >= 0xa1 and byte <= 0xdf) {
            try appendCodePoint(out, allocator, @as(u21, 0xff61) - 0xa1 + byte);
            return false;
        }
        if ((byte >= 0x81 and byte <= 0x9f) or (byte >= 0xe0 and byte <= 0xfc)) {
            self.lead = byte;
            return false;
        }
        return true;
    }

    fn parseEucKr(self: *Codec, out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) error{OutOfMemory}!bool {
        if (self.lead != 0) {
            const lead = self.lead;
            self.lead = 0;
            if (byte >= 0x41 and byte <= 0xfe) {
                const pointer: u16 = (@as(u16, lead) - 0x81) * 190 + byte - 0x41;
                if (tables.eucKr(pointer)) |code_point| {
                    try appendCodePoint(out, allocator, code_point);
                    return false;
                }
            }
            if (byte < 0x80) self.prepended = byte;
            return true;
        }
        if (byte < 0x80) {
            try out.append(allocator, byte);
            return false;
        }
        if (byte >= 0x81 and byte <= 0xfe) {
            self.lead = byte;
            return false;
        }
        return true;
    }

    fn parseBig5(self: *Codec, out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) error{OutOfMemory}!bool {
        if (self.lead != 0) {
            const lead = self.lead;
            self.lead = 0;
            const offset: u8 = if (byte < 0x7f) 0x40 else 0x62;
            if ((byte >= 0x40 and byte <= 0x7e) or (byte >= 0xa1 and byte <= 0xfe)) {
                const pointer: u16 = (@as(u16, lead) - 0x81) * 157 + byte - offset;
                switch (pointer) {
                    1133 => {
                        try appendCodePoint(out, allocator, 0x00ca);
                        try appendCodePoint(out, allocator, 0x0304);
                        return false;
                    },
                    1135 => {
                        try appendCodePoint(out, allocator, 0x00ca);
                        try appendCodePoint(out, allocator, 0x030c);
                        return false;
                    },
                    1164 => {
                        try appendCodePoint(out, allocator, 0x00ea);
                        try appendCodePoint(out, allocator, 0x0304);
                        return false;
                    },
                    1166 => {
                        try appendCodePoint(out, allocator, 0x00ea);
                        try appendCodePoint(out, allocator, 0x030c);
                        return false;
                    },
                    else => if (tables.big5(pointer)) |code_point| {
                        try appendCodePoint(out, allocator, code_point);
                        return false;
                    },
                }
            }
            if (byte < 0x80) self.prepended = byte;
            return true;
        }
        if (byte < 0x80) {
            try out.append(allocator, byte);
            return false;
        }
        if (byte >= 0x81 and byte <= 0xfe) {
            self.lead = byte;
            return false;
        }
        return true;
    }

    fn parseGb(
        self: *Codec,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        byte: u8,
        saw_error: *bool,
    ) error{OutOfMemory}!bool {
        if (self.gb_third != 0) {
            if (byte < 0x30 or byte > 0x39) {
                saw_error.* = true;
                try appendReplacement(out, allocator);
                self.gb_first = 0;
                const second = self.gb_second;
                const third = self.gb_third;
                self.gb_second = 0;
                self.gb_third = 0;
                if (try self.parseGb(out, allocator, second, saw_error)) {
                    saw_error.* = true;
                    try appendReplacement(out, allocator);
                }
                if (try self.parseGb(out, allocator, third, saw_error)) {
                    saw_error.* = true;
                    try appendReplacement(out, allocator);
                }
                return self.parseGb(out, allocator, byte, saw_error);
            }
            const first = self.gb_first;
            const second = self.gb_second;
            const third = self.gb_third;
            self.gb_first = 0;
            self.gb_second = 0;
            self.gb_third = 0;
            const pointer: u32 = (@as(u32, first) - 0x81) * 10 * 126 * 10 +
                (@as(u32, second) - 0x30) * 10 * 126 +
                (@as(u32, third) - 0x81) * 10 + byte - 0x30;
            if (tables.gb18030RangeCodePoint(pointer)) |code_point| {
                try appendCodePoint(out, allocator, code_point);
                return false;
            }
            return true;
        }
        if (self.gb_second != 0) {
            if (byte >= 0x81 and byte <= 0xfe) {
                self.gb_third = byte;
                return false;
            }
            saw_error.* = true;
            try appendReplacement(out, allocator);
            self.gb_first = 0;
            const second = self.gb_second;
            self.gb_second = 0;
            if (try self.parseGb(out, allocator, second, saw_error)) {
                saw_error.* = true;
                try appendReplacement(out, allocator);
            }
            return self.parseGb(out, allocator, byte, saw_error);
        }
        if (self.gb_first != 0) {
            if (byte >= 0x30 and byte <= 0x39) {
                self.gb_second = byte;
                return false;
            }
            const lead = self.gb_first;
            self.gb_first = 0;
            const offset: u8 = if (byte < 0x7f) 0x40 else 0x41;
            if ((byte >= 0x40 and byte <= 0x7e) or (byte >= 0x80 and byte <= 0xfe)) {
                const pointer: u16 = (@as(u16, lead) - 0x81) * 190 + byte - offset;
                if (pointer < 23940) {
                    try appendCodePoint(out, allocator, tables.gb18030(pointer));
                    return false;
                }
            }
            if (byte < 0x80) self.prepended = byte;
            return true;
        }
        if (byte < 0x80) {
            try out.append(allocator, byte);
            return false;
        }
        if (byte == 0x80) {
            try appendCodePoint(out, allocator, 0x20ac);
            return false;
        }
        if (byte >= 0x81 and byte <= 0xfe) {
            self.gb_first = byte;
            return false;
        }
        return true;
    }

    fn decodeGb(
        self: *Codec,
        allocator: std.mem.Allocator,
        data: []const u8,
        flush: bool,
        stop_on_error: bool,
    ) error{OutOfMemory}!DecodeResult {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var saw_error = false;
        _ = try self.processCommon(&out, allocator, data, flush, stop_on_error, &saw_error);
        if (flush and (self.gb_first != 0 or self.gb_second != 0 or self.gb_third != 0)) {
            self.gb_first = 0;
            self.gb_second = 0;
            self.gb_third = 0;
            saw_error = true;
            try appendReplacement(&out, allocator);
        }
        return finish(&out, allocator, saw_error);
    }

    fn parseIso2022Jp(self: *Codec, out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) error{OutOfMemory}!bool {
        switch (self.iso_state) {
            .ascii => {
                if (byte == 0x1b) {
                    self.iso_state = .escape_start;
                    return false;
                }
                if (byte <= 0x7f and byte != 0x0e and byte != 0x0f) {
                    self.iso_output = false;
                    try out.append(allocator, byte);
                    return false;
                }
                self.iso_output = false;
                return true;
            },
            .roman => {
                if (byte == 0x1b) {
                    self.iso_state = .escape_start;
                    return false;
                }
                self.iso_output = false;
                if (byte == 0x5c) {
                    try appendCodePoint(out, allocator, 0x00a5);
                    return false;
                }
                if (byte == 0x7e) {
                    try appendCodePoint(out, allocator, 0x203e);
                    return false;
                }
                if (byte <= 0x7f and byte != 0x0e and byte != 0x0f) {
                    try out.append(allocator, byte);
                    return false;
                }
                return true;
            },
            .katakana => {
                if (byte == 0x1b) {
                    self.iso_state = .escape_start;
                    return false;
                }
                self.iso_output = false;
                if (byte >= 0x21 and byte <= 0x5f) {
                    try appendCodePoint(out, allocator, @as(u21, 0xff61) - 0x21 + byte);
                    return false;
                }
                return true;
            },
            .lead_byte => {
                if (byte == 0x1b) {
                    self.iso_state = .escape_start;
                    return false;
                }
                self.iso_output = false;
                if (byte >= 0x21 and byte <= 0x7e) {
                    self.lead = byte;
                    self.iso_state = .trail_byte;
                    return false;
                }
                return true;
            },
            .trail_byte => {
                if (byte == 0x1b) {
                    self.iso_state = .escape_start;
                    return true;
                }
                self.iso_state = .lead_byte;
                if (byte >= 0x21 and byte <= 0x7e) {
                    const pointer: u16 = (@as(u16, self.lead) - 0x21) * 94 + byte - 0x21;
                    if (tables.jis0208(pointer)) |code_point| {
                        try appendCodePoint(out, allocator, code_point);
                        return false;
                    }
                }
                return true;
            },
            .escape_start => {
                if (byte == 0x24 or byte == 0x28) {
                    self.lead = byte;
                    self.iso_state = .escape;
                    return false;
                }
                self.prepended = byte;
                self.iso_output = false;
                self.iso_state = self.iso_output_state;
                return true;
            },
            .escape => {
                const lead = self.lead;
                self.lead = 0;
                const next: ?Iso2022State = if (lead == 0x28)
                    switch (byte) {
                        0x42 => .ascii,
                        0x4a => .roman,
                        0x49 => .katakana,
                        else => null,
                    }
                else if (lead == 0x24 and (byte == 0x40 or byte == 0x42))
                    .lead_byte
                else
                    null;
                if (next) |state| {
                    self.iso_state = state;
                    self.iso_output_state = state;
                    const repeated = self.iso_output;
                    self.iso_output = true;
                    return repeated;
                }
                self.prepended = lead;
                self.iso_second_prepended = byte;
                self.iso_output = false;
                self.iso_state = self.iso_output_state;
                return true;
            },
        }
    }

    fn isoError(
        self: *Codec,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        stop_on_error: bool,
        saw_error: *bool,
    ) error{OutOfMemory}!bool {
        saw_error.* = true;
        try appendReplacement(out, allocator);
        if (!stop_on_error) return false;
        self.lead = 0;
        return true;
    }

    fn decodeIso2022Jp(
        self: *Codec,
        allocator: std.mem.Allocator,
        data: []const u8,
        flush: bool,
        stop_on_error: bool,
    ) error{OutOfMemory}!DecodeResult {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var saw_error = false;

        if (self.prepended) |byte| {
            self.prepended = null;
            if (try self.parseIso2022Jp(&out, allocator, byte) and
                try self.isoError(&out, allocator, stop_on_error, &saw_error))
                return finish(&out, allocator, saw_error);
        }
        if (self.iso_second_prepended) |byte| {
            self.iso_second_prepended = null;
            if (try self.parseIso2022Jp(&out, allocator, byte) and stop_on_error) {
                _ = try self.isoError(&out, allocator, true, &saw_error);
                return finish(&out, allocator, saw_error);
            }
        }
        for (data) |byte| {
            if (try self.parseIso2022Jp(&out, allocator, byte) and
                try self.isoError(&out, allocator, stop_on_error, &saw_error))
                return finish(&out, allocator, saw_error);
            if (self.prepended) |prepended| {
                self.prepended = null;
                if (try self.parseIso2022Jp(&out, allocator, prepended) and
                    try self.isoError(&out, allocator, stop_on_error, &saw_error))
                    return finish(&out, allocator, saw_error);
            }
            if (self.iso_second_prepended) |second| {
                self.iso_second_prepended = null;
                if (try self.parseIso2022Jp(&out, allocator, second) and stop_on_error) {
                    _ = try self.isoError(&out, allocator, true, &saw_error);
                    return finish(&out, allocator, saw_error);
                }
            }
        }

        if (flush) switch (self.iso_state) {
            .ascii, .roman, .katakana, .lead_byte => {},
            .trail_byte => {
                self.iso_state = .lead_byte;
                saw_error = true;
                try appendReplacement(&out, allocator);
            },
            .escape_start => {
                saw_error = true;
                try appendReplacement(&out, allocator);
            },
            .escape => {
                saw_error = true;
                try appendReplacement(&out, allocator);
                if (self.lead != 0) {
                    try out.append(allocator, self.lead);
                    self.lead = 0;
                }
            },
        };
        return finish(&out, allocator, saw_error);
    }
};

test "TextCodec registry mirrors the pinned fallback profile" {
    for (alias_groups) |group| {
        try std.testing.expectEqualStrings(group.encoding.canonicalName(), group.aliases[0]);
        for (group.aliases) |alias| try std.testing.expectEqual(group.encoding, canonicalEncoding(alias).?);
    }
    try std.testing.expectEqual(Encoding.shift_jis, canonicalEncoding("sJiS").?);
    try std.testing.expectEqualStrings("Shift_JIS", canonicalEncoding("windows-31j").?.canonicalName());
    try std.testing.expectEqual(Encoding.replacement, canonicalEncoding("ISO-2022-KR").?);
    try std.testing.expect(canonicalEncoding("utf-8") == null);
    try std.testing.expect(canonicalEncoding(" latin3") == null);
    try std.testing.expect(canonicalEncoding("\xc3\xa9") == null);
    var too_long: [64]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expect(canonicalEncoding(&too_long) == null);
}

test "TextCodec direct codecs preserve replacement and user-defined state" {
    const allocator = std.testing.allocator;
    var user = Codec.init(.x_user_defined);
    defer user.deinit();
    const mapped = try user.decode(allocator, &.{ 0x41, 0x80, 0xff }, false, false);
    defer mapped.deinit(allocator);
    try std.testing.expectEqualStrings("A\u{f780}\u{f7ff}", mapped.bytes);
    try std.testing.expect(!mapped.saw_error);

    var replacement = Codec.init(.replacement);
    defer replacement.deinit();
    const first = try replacement.decode(allocator, &.{}, false, false);
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("\u{fffd}", first.bytes);
    try std.testing.expect(first.saw_error);
    const second = try replacement.decode(allocator, "ignored", true, true);
    defer second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), second.bytes.len);
    try std.testing.expect(second.saw_error);
}

test "TextCodec single-byte decoders use the pinned tables" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { encoding: Encoding, byte: u8, expected: []const u8 }{
        .{ .encoding = .iso_8859_3, .byte = 0xa1, .expected = "\u{0126}" },
        .{ .encoding = .iso_8859_6, .byte = 0xc7, .expected = "\u{0627}" },
        .{ .encoding = .iso_8859_7, .byte = 0xc1, .expected = "\u{0391}" },
        .{ .encoding = .iso_8859_8, .byte = 0xe0, .expected = "\u{05d0}" },
        .{ .encoding = .iso_8859_8_i, .byte = 0xe0, .expected = "\u{05d0}" },
        .{ .encoding = .windows_874, .byte = 0xa1, .expected = "\u{0e01}" },
        .{ .encoding = .windows_1253, .byte = 0xc1, .expected = "\u{0391}" },
        .{ .encoding = .windows_1255, .byte = 0xe0, .expected = "\u{05d0}" },
        .{ .encoding = .windows_1257, .byte = 0xc0, .expected = "\u{0104}" },
        .{ .encoding = .koi8_u, .byte = 0xe1, .expected = "\u{0410}" },
        .{ .encoding = .ibm866, .byte = 0x80, .expected = "\u{0410}" },
    };
    for (cases) |case| {
        var codec = Codec.init(case.encoding);
        const decoded = try codec.decode(allocator, &.{case.byte}, true, false);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualStrings(case.expected, decoded.bytes);
        try std.testing.expect(!decoded.saw_error);
    }

    var invalid = Codec.init(.iso_8859_3);
    const stopped = try invalid.decode(allocator, &.{ 0xa5, 'A' }, true, true);
    defer stopped.deinit(allocator);
    try std.testing.expectEqualStrings("\u{fffd}", stopped.bytes);
    try std.testing.expect(stopped.saw_error);
}

test "TextCodec CJK decoders match pinned representative vectors" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { encoding: Encoding, bytes: []const u8, expected: []const u8 }{
        .{ .encoding = .euc_jp, .bytes = &.{ 0xa4, 0xa2 }, .expected = "\u{3042}" },
        .{ .encoding = .shift_jis, .bytes = &.{ 0x82, 0xa0 }, .expected = "\u{3042}" },
        .{ .encoding = .iso_2022_jp, .bytes = &.{ 0x1b, 0x24, 0x42, 0x24, 0x22 }, .expected = "\u{3042}" },
        .{ .encoding = .euc_kr, .bytes = &.{ 0xb0, 0xa1 }, .expected = "\u{ac00}" },
        .{ .encoding = .big5, .bytes = &.{ 0xa4, 0x40 }, .expected = "\u{4e00}" },
        .{ .encoding = .gbk, .bytes = &.{ 0xd2, 0xbb }, .expected = "\u{4e00}" },
        .{ .encoding = .gb18030, .bytes = &.{ 0x81, 0x30, 0x81, 0x30 }, .expected = "\u{0080}" },
    };
    for (cases) |case| {
        var decoder = Codec.init(case.encoding);
        const decoded = try decoder.decode(allocator, case.bytes, true, false);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualStrings(case.expected, decoded.bytes);
        try std.testing.expect(!decoded.saw_error);
    }
}

test "TextCodec CJK decoder retains split sequences and flushes errors" {
    const allocator = std.testing.allocator;
    var codec = Codec.init(.shift_jis);
    defer codec.deinit();

    const lead = try codec.decode(allocator, &.{0x82}, false, false);
    defer lead.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), lead.bytes.len);
    try std.testing.expect(!lead.saw_error);
    const trail = try codec.decode(allocator, &.{0xa0}, false, false);
    defer trail.deinit(allocator);
    try std.testing.expectEqualStrings("\u{3042}", trail.bytes);
    try std.testing.expect(!trail.saw_error);

    const invalid = try codec.decode(allocator, &.{ 0xfd, 'A' }, true, true);
    defer invalid.deinit(allocator);
    try std.testing.expectEqualStrings("\u{fffd}", invalid.bytes);
    try std.testing.expect(invalid.saw_error);
    const split = try codec.decode(allocator, &.{0x82}, true, false);
    defer split.deinit(allocator);
    try std.testing.expectEqualStrings("\u{fffd}", split.bytes);
    try std.testing.expect(split.saw_error);
}
