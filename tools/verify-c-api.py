#!/usr/bin/env python3
"""Verify the pinned JSC C inventory, checked-in headers, and Zig exports."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "docs/c-api/jsc-public-api-macos-27.0.json"
PRIVATE_INVENTORIES = (
    ROOT / "docs/abi/home-private-7ed99c02-inventory.json",
    ROOT / "docs/abi/bun-private-core-4982b91e-inventory.json",
)
# Bun's StringImpl retain/release helpers are native support for by-value
# BunString results. The pinned Zig source inventories do not declare them:
# Zig performs ref/deref inline and calls only the cold destroy path, while the
# Rust consumer uses the full explicit trio. Keep this exception closed and
# auditable instead of accepting arbitrary Bun__ exports.
PRIVATE_SUPPORT_EXPORTS = {
    "Bun__WTFStringImpl__ref",
    "Bun__WTFStringImpl__deref",
    "Bun__WTFStringImpl__destroy",
    # Generated bun.cpp adapters classify the exact internal descriptor cells;
    # the consumer Zig inventories only declare the four methods on the casts.
    "JSC__JSValue__isGetterSetter",
    "JSC__JSValue__isCustomGetterSetter",
    # Generated/native exception projection entry used beside the inventoried
    # ZigException methods; it is absent from the consumer extern inventories.
    "JSC__JSValue__toZigException",
    # Generated bindgen adapter: the consumer inventories the three methods on
    # the leaked ArrayBuffer pointer, while C++ performs this producer step.
    "JSC__IDLArrayBufferRef__convertToExtern",
}
INCLUDE = ROOT / "include/JavaScriptCore"
SOURCE = ROOT / "src/c_api.zig"

FUNCTION_RE = re.compile(r"JS_EXPORT\s+(?!extern\s+const\b).*?\b(JS[A-Za-z0-9_]+)\s*\(", re.S)
EXPORT_RE = re.compile(r"^export\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)
VALID_STATUSES = {"implemented", "pending", "platform_gated"}


def fail(message: str) -> None:
    print(f"c-api audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_entries(section: str, entries: list[dict[str, object]]) -> None:
    names = [str(entry.get("name", "")) for entry in entries]
    if not all(names) or len(names) != len(set(names)):
        fail(f"{section} names must be non-empty and unique")
    for entry in entries:
        status = entry.get("status")
        if status not in VALID_STATUSES:
            fail(f"{entry['name']} has invalid status {status!r}")
        if status != "implemented" and not isinstance(entry.get("issue"), int):
            fail(f"unfinished {entry['name']} must link a numeric GitHub issue")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sdk-root",
        type=Path,
        help="optional SDK root whose JavaScriptCore headers must match the pin",
    )
    args = parser.parse_args()

    data = json.loads(INVENTORY.read_text())
    functions = data["functions"]
    if len(functions) != 117:
        fail(f"expected 117 pinned functions, found {len(functions)}")
    for section in ("functions", "types", "callbacks", "enums", "data_symbols"):
        validate_entries(section, data[section])

    inventory_names = {entry["name"] for entry in functions}
    declared_by_header: dict[str, set[str]] = {}
    for header in data["source_headers"]:
        path = INCLUDE / header
        if not path.is_file():
            fail(f"missing checked-in header include/JavaScriptCore/{header}")
        declared_by_header[header] = set(FUNCTION_RE.findall(path.read_text()))

    declared_names = set().union(*declared_by_header.values())
    missing_declarations = sorted(inventory_names - declared_names)
    extra_declarations = sorted(declared_names - inventory_names)
    if missing_declarations or extra_declarations:
        fail(
            f"header/inventory drift; missing={missing_declarations}, "
            f"extra={extra_declarations}"
        )
    for entry in functions:
        if entry["name"] not in declared_by_header[entry["header"]]:
            fail(f"{entry['name']} is not declared by its recorded header {entry['header']}")

    all_header_text = "\n".join(path.read_text() for path in INCLUDE.glob("*.h"))
    for section in ("types", "callbacks", "enums", "data_symbols"):
        for entry in data[section]:
            if not re.search(rf"\b{re.escape(entry['name'])}\b", all_header_text):
                fail(f"{section} entry {entry['name']} is absent from checked-in headers")

    exports = set(EXPORT_RE.findall(SOURCE.read_text()))
    implemented = {entry["name"] for entry in functions if entry["status"] == "implemented"}
    missing_exports = sorted(implemented - exports)
    if missing_exports:
        fail(f"implemented functions missing Zig exports: {missing_exports}")

    extensions = set(data["zig_js_extensions"])
    private_exports = set(PRIVATE_SUPPORT_EXPORTS)
    for private_inventory in PRIVATE_INVENTORIES:
        private_data = json.loads(private_inventory.read_text())
        private_exports.update(
            entry["name"] for entry in private_data["declarations"]
            if entry["classification"] == "private_jsc" and entry["status"] == "implemented"
        )
    unexpected_exports = sorted(exports - inventory_names - extensions - private_exports)
    missing_extensions = sorted(extensions - exports)
    if unexpected_exports or missing_extensions:
        fail(
            f"Zig export classification drift; unexpected={unexpected_exports}, "
            f"missing_extensions={missing_extensions}"
        )

    if args.sdk_root:
        framework_headers = (
            args.sdk_root
            / "System/Library/Frameworks/JavaScriptCore.framework/Headers"
        )
        for header, expected in data["source_headers"].items():
            actual = sha256(framework_headers / header)
            if actual != expected:
                fail(f"pinned SDK header drift for {header}: {actual} != {expected}")

    pending = sum(entry["status"] != "implemented" for entry in functions)
    existing = len(inventory_names & exports)
    print(
        f"c-api audit: 117 declarations, {len(implemented)} complete, "
        f"{pending} pending, {existing} public symbols present, "
        f"{len(extensions)} zig-js extensions, {len(private_exports)} private profile exports"
    )


if __name__ == "__main__":
    main()
