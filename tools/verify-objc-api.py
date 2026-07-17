#!/usr/bin/env python3
"""Capture and verify the pinned Objective-C JavaScriptCore header surface."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "docs/objc-api/jsc-objc-api-macos-27.0.json"
FRAMEWORK = Path("System/Library/Frameworks/JavaScriptCore.framework/Headers")
HEADERS = ("JSContext.h", "JSValue.h", "JSVirtualMachine.h", "JSManagedValue.h", "JSExport.h")
VALID_STATUSES = {"implemented", "pending", "platform_gated"}


def fail(message: str) -> None:
    print(f"objc-api audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_sha256(path: Path) -> str:
    lines = path.read_bytes().splitlines(keepends=True)
    normalized = b"".join(
        line.rstrip(b" \t\r\n") + (b"\n" if line.endswith((b"\n", b"\r")) else b"")
        for line in lines
    )
    return hashlib.sha256(normalized).hexdigest()


def normalize(text: str) -> str:
    return " ".join(text.split())


def uncomment(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def selector(tail: str) -> str:
    parts = re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:", tail)
    if parts:
        return ":".join(parts) + ":"
    match = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", tail)
    if not match:
        fail(f"cannot derive selector from {tail!r}")
    return match.group(1)


def property_name(declaration: str) -> str:
    block = re.search(r"\(\^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", declaration)
    if block:
        return block.group(1)
    body = declaration.split(" API_", 1)[0].split(" NS_", 1)[0]
    names = re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", body)
    if not names:
        fail(f"cannot derive property name from {declaration!r}")
    return names[-1]


def pending_issue(header: str, name: str) -> int:
    if header == "JSManagedValue.h" or name in {
        "addManagedReference:withOwner:",
        "removeManagedReference:withOwner:",
    }:
        return 159
    if header == "JSExport.h":
        return 160
    return 158


def parse_header(header: str, source: str) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    text = uncomment(source)
    containers: list[dict[str, object]] = []
    declarations: list[dict[str, object]] = []
    block_re = re.compile(
        r"@(interface|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"
        r"(?:\s*\(([^)]*)\))?(?:\s*:\s*([A-Za-z_][A-Za-z0-9_]*))?"
        r"(?:\s*<([^>]*)>)?(.*?)@end",
        re.S,
    )
    for match in block_re.finditer(text):
        kind, name, category, superclass, adopted, body = match.groups()
        container = name if not category else f"{name}({normalize(category)})"
        prefix = text[max(0, match.start() - 200) : match.start()]
        availability_matches = re.findall(
            r"(?:API_AVAILABLE|NS_CLASS_AVAILABLE)\([^\n]*\)", prefix
        )
        containers.append(
            {
                "header": header,
                "kind": kind,
                "name": name,
                "category": normalize(category) if category else None,
                "superclass": superclass,
                "adopted_protocols": sorted(
                    item.strip() for item in (adopted or "").split(",") if item.strip()
                ),
                "availability": availability_matches[-1] if availability_matches else None,
            }
        )
        for method in re.finditer(r"(?ms)^[ \t]*([+-])\s*\(([^)]*)\)\s*(.*?);", body):
            polarity, return_type, tail = method.groups()
            method_selector = selector(tail)
            declarations.append(
                {
                    "header": header,
                    "container": container,
                    "kind": "class_method" if polarity == "+" else "instance_method",
                    "name": method_selector,
                    "declaration": normalize(f"{polarity} ({return_type}) {tail}"),
                    "status": "pending",
                    "issue": pending_issue(header, method_selector),
                }
            )
        for prop in re.finditer(r"(?ms)^[ \t]*@property\s+(.*?);", body):
            declaration = normalize(f"@property {prop.group(1)}")
            name_value = property_name(declaration)
            declarations.append(
                {
                    "header": header,
                    "container": container,
                    "kind": "property",
                    "name": name_value,
                    "declaration": declaration,
                    "status": "pending",
                    "issue": pending_issue(header, name_value),
                }
            )
    for typedef in re.finditer(r"(?m)^typedef\s+([^;]*\bJSValueProperty)\s*;", text):
        declarations.append(
            {
                "header": header,
                "container": "global",
                "kind": "typedef",
                "name": "JSValueProperty",
                "declaration": normalize(f"typedef {typedef.group(1)}"),
                "status": "pending",
                "issue": 158,
            }
        )
    for symbol in re.finditer(
        r"(?m)^JS_EXPORT\s+extern\s+([^;]*\b(JSPropertyDescriptor[A-Za-z0-9_]+))\s*;",
        text,
    ):
        declarations.append(
            {
                "header": header,
                "container": "global",
                "kind": "data_symbol",
                "name": symbol.group(2),
                "declaration": normalize(f"JS_EXPORT extern {symbol.group(1)}"),
                "status": "pending",
                "issue": 158,
            }
        )
    return containers, declarations


def parse_surface(headers_root: Path) -> tuple[dict[str, str], dict[str, str], list[dict[str, object]], list[dict[str, object]]]:
    containers: list[dict[str, object]] = []
    declarations: list[dict[str, object]] = []
    hashes: dict[str, str] = {}
    normalized_hashes: dict[str, str] = {}
    for header in HEADERS:
        path = headers_root / header
        if not path.is_file():
            fail(f"missing SDK header {path}")
        source = path.read_text()
        parsed_containers, parsed_declarations = parse_header(header, source)
        containers.extend(parsed_containers)
        declarations.extend(parsed_declarations)
        hashes[header] = sha256(path)
        normalized_hashes[header] = normalized_sha256(path)
    if "@protocol JSExport" not in uncomment((headers_root / "JSExport.h").read_text()):
        fail("JSExport protocol is absent")
    declarations.append(
        {
            "header": "JSExport.h",
            "container": "global",
            "kind": "macro",
            "name": "JSExportAs",
            "declaration": "#define JSExportAs(PropertyName, Selector)",
            "status": "pending",
            "issue": 160,
        }
    )
    containers.sort(key=lambda item: (str(item["header"]), str(item["kind"]), str(item["name"]), str(item["category"])))
    declarations.sort(key=lambda item: (str(item["header"]), str(item["container"]), str(item["kind"]), str(item["name"]), str(item["declaration"])))
    return hashes, normalized_hashes, containers, declarations


def capture(sdk_root: Path) -> dict[str, object]:
    hashes, normalized_hashes, containers, declarations = parse_surface(sdk_root / FRAMEWORK)
    return {
        "schema_version": 1,
        "target": {
            "platform": "macOS",
            "sdk_version": "27.0",
            "sdk_build": "26A5368g",
            "captured_at": "2026-07-16",
        },
        "source_headers": hashes,
        "checked_header_hashes": normalized_hashes,
        "containers": containers,
        "declarations": declarations,
    }


def declaration_key(entry: dict[str, object]) -> tuple[str, str, str, str, str]:
    return tuple(str(entry.get(field, "")) for field in ("header", "container", "kind", "name", "declaration"))


def validate(data: dict[str, object]) -> None:
    if data.get("schema_version") != 1:
        fail("schema_version must be 1")
    if set(data.get("source_headers", {})) != set(HEADERS):
        fail("source_headers must name exactly the five targeted Objective-C headers")
    if set(data.get("checked_header_hashes", {})) != set(HEADERS):
        fail("checked_header_hashes must name exactly the five targeted Objective-C headers")
    containers = data.get("containers")
    declarations = data.get("declarations")
    if not isinstance(containers, list) or not isinstance(declarations, list):
        fail("containers and declarations must be arrays")
    container_keys = [
        (entry.get("header"), entry.get("kind"), entry.get("name"), entry.get("category"))
        for entry in containers
    ]
    if len(container_keys) != len(set(container_keys)):
        fail("container entries must be unique")
    declaration_keys = [declaration_key(entry) for entry in declarations]
    if len(declaration_keys) != len(set(declaration_keys)):
        fail("declaration entries must be unique")
    known_containers = {entry.get("name") if not entry.get("category") else f"{entry.get('name')}({entry.get('category')})" for entry in containers}
    for entry in declarations:
        if entry.get("container") != "global" and entry.get("container") not in known_containers:
            fail(f"unknown declaration container {entry.get('container')}")
        status = entry.get("status")
        if status not in VALID_STATUSES:
            fail(f"{entry.get('name')} has invalid status {status!r}")
        if status != "implemented" and not isinstance(entry.get("issue"), int):
            fail(f"unfinished {entry.get('name')} must link a numeric GitHub issue")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk-root", type=Path, help="SDK root to compare with the pin")
    parser.add_argument("--capture", action="store_true", help="print a fresh inventory from --sdk-root")
    args = parser.parse_args()
    if args.capture:
        if args.sdk_root is None:
            fail("--capture requires --sdk-root")
        print(json.dumps(capture(args.sdk_root), indent=2) + "\n", end="")
        return
    if not INVENTORY.is_file():
        fail(f"missing inventory {INVENTORY.relative_to(ROOT)}")
    data = json.loads(INVENTORY.read_text())
    validate(data)
    _, checked_hashes, checked_containers, checked_declarations = parse_surface(
        ROOT / "include/JavaScriptCore"
    )
    if checked_hashes != data["checked_header_hashes"]:
        fail("checked-in Objective-C header hashes drifted from the pin")
    if checked_containers != data["containers"]:
        fail("checked-in Objective-C containers drifted from the inventory")
    if [declaration_key(entry) for entry in checked_declarations] != [
        declaration_key(entry) for entry in data["declarations"]
    ]:
        fail("checked-in Objective-C declarations drifted from the inventory")
    if args.sdk_root is not None:
        actual = capture(args.sdk_root)
        if actual["source_headers"] != data["source_headers"]:
            fail("pinned Objective-C SDK header hashes drifted")
        if actual["checked_header_hashes"] != data["checked_header_hashes"]:
            fail("normalized Objective-C SDK header hashes drifted")
        if actual["containers"] != data["containers"]:
            fail("pinned Objective-C containers drifted")
        actual_keys = [declaration_key(entry) for entry in actual["declarations"]]
        expected_keys = [declaration_key(entry) for entry in data["declarations"]]
        if actual_keys != expected_keys:
            fail("pinned Objective-C declarations drifted")
    implemented = sum(entry["status"] == "implemented" for entry in data["declarations"])
    pending = len(data["declarations"]) - implemented
    print(
        f"objc-api audit: {len(data['containers'])} containers, "
        f"{len(data['declarations'])} declarations, {implemented} complete, {pending} pending"
    )


if __name__ == "__main__":
    main()
