#!/usr/bin/env python3
"""Pack the revision-pinned WebKit decoder indexes used by TextCodec.

The inputs are the unmodified EncodingTables.cpp, TextCodecSingleByte.cpp, and
TextCodecCJK.cpp files from home-lang/home revision
7ed99c02e50034f869d0db6d487115bb44332fe4.
Normal builds consume the checked-in binary and never run this generator.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import struct
from pathlib import Path

ENCODING_TABLES_SHA256 = "ec3ec297dd8b52a64ac3065206d26ab186b9f59349790d7e6bfcda297051ad60"
SINGLE_BYTE_SHA256 = "6abca8d12653ab4dde31ad3eae0e089b392b793d7a9bc04c68081fb6536b8552"
CJK_SHA256 = "d178f1c382a2c590f7d812ff317d9b20e5085358604eeb4eb4b40f3697704508"
MAGIC = b"ZJTC0001"

SINGLE_BYTE_TABLES = (
    "iso88593",
    "iso88596",
    "iso88597",
    "iso88598",
    "windows874",
    "windows1253",
    "windows1255",
    "windows1257",
    "koi8u",
    "ibm866",
)


def checked_source(path: Path, expected_sha256: str) -> str:
    data = path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected_sha256:
        raise SystemExit(f"{path}: expected SHA-256 {expected_sha256}, got {actual}")
    return data.decode()


def initializer(source: str, marker: str) -> str:
    start = source.index(marker)
    start = source.index("{", start) + 1
    end = source.index("};", start)
    return source[start:end]


def pairs(source: str, marker: str, expected_count: int) -> list[tuple[int, int]]:
    result = [
        (int(key, 10), int(value, 16))
        for key, value in re.findall(r"\{\s*(\d+)\s*,\s*(0x[0-9a-fA-F]+)\s*\}", initializer(source, marker))
    ]
    if len(result) != expected_count:
        raise SystemExit(f"{marker}: expected {expected_count} entries, got {len(result)}")
    return result


def hex_values(source: str, marker: str, expected_count: int) -> list[int]:
    result = [int(value, 16) for value in re.findall(r"0x[0-9a-fA-F]+", initializer(source, marker))]
    if len(result) != expected_count:
        raise SystemExit(f"{marker}: expected {expected_count} entries, got {len(result)}")
    return result


def dense(entries: list[tuple[int, int]], count: int) -> list[int]:
    result = [0] * count
    for pointer, code_point in entries:
        if pointer >= count or result[pointer] != 0:
            raise SystemExit(f"invalid or duplicate pointer {pointer}")
        result[pointer] = code_point
    return result


def write_u16(output: bytearray, values: list[int]) -> None:
    for value in values:
        output.extend(struct.pack("<H", value))


def write_u32(output: bytearray, values: list[int]) -> None:
    for value in values:
        output.extend(struct.pack("<I", value))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("encoding_tables", type=Path)
    parser.add_argument("single_byte", type=Path)
    parser.add_argument("cjk", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    encoding = checked_source(args.encoding_tables, ENCODING_TABLES_SHA256)
    single = checked_source(args.single_byte, SINGLE_BYTE_SHA256)
    cjk = checked_source(args.cjk, CJK_SHA256)
    output = bytearray(MAGIC)

    for name in SINGLE_BYTE_TABLES:
        write_u16(output, hex_values(single, f"SingleByteDecodeTable {name}", 128))

    write_u16(output, dense(pairs(encoding, "jis0208Data", 7724), 11104))
    write_u16(output, dense(pairs(encoding, "jis0212Data", 6067), 7211))
    write_u32(output, dense(pairs(encoding, "big5Data", 18590), 19782))
    write_u16(output, dense(pairs(encoding, "eucKRData", 17048), 23750))
    write_u16(output, hex_values(encoding, "gb18030Data", 23940))

    ranges = pairs(cjk, "gb18030Ranges", 207)
    write_u32(output, [value for pair in ranges for value in pair])

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)
    print(f"wrote {len(output)} bytes to {args.output}")


if __name__ == "__main__":
    main()
