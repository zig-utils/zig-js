#!/usr/bin/env python3
"""Generate and verify Home's revision-pinned private extern-fn inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/abi/home-private-7ed99c02-inventory.json"
PUBLIC_INVENTORY = ROOT / "docs/c-api/jsc-public-api-macos-27.0.json"
EXPORT_SOURCE = ROOT / "src/c_api.zig"
PROFILE_ID = "home-private-7ed99c02"
REVISION = "7ed99c02e50034f869d0db6d487115bb44332fe4"
ALIAS_PROFILES = {
    "home-private-5e829ad4": ROOT / "docs/abi/home-private-5e829ad4.json",
    "home-private-38702f9e": ROOT / "docs/abi/home-private-38702f9e.json",
}
SOURCE_ROOT = Path("packages/runtime/src/jsc")
EXTERN_RE = re.compile(r"\b(?:pub\s+)?extern\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
PLATFORM_IMPORTS = {"gnu_get_libc_version"}
EXPORT_RE = re.compile(r"^export fn ([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)


def fail(message: str) -> None:
    print(f"Home private ABI audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def mask_non_code(source: str) -> str:
    """Mask Zig comments and string/character literals while retaining offsets."""
    chars = list(source)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(chars):
        current = chars[index]
        following = chars[index + 1] if index + 1 < len(chars) else ""
        if state == "code":
            if current == "/" and following == "/":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "line_comment"
                continue
            if current == "/" and following == "*":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "block_comment"
                block_depth = 1
                continue
            if current == '"':
                chars[index] = " "
                index += 1
                state = "string"
                continue
            if current == "'":
                chars[index] = " "
                index += 1
                state = "character"
                continue
            if current == "\\" and following == "\\":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "multiline_string"
                continue
            index += 1
            continue

        if state in {"line_comment", "multiline_string"}:
            if current == "\n":
                state = "code"
            else:
                chars[index] = " "
            index += 1
            continue

        if state == "block_comment":
            if current == "/" and following == "*":
                chars[index] = chars[index + 1] = " "
                block_depth += 1
                index += 2
            elif current == "*" and following == "/":
                chars[index] = chars[index + 1] = " "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                if current != "\n":
                    chars[index] = " "
                index += 1
            continue

        if state in {"string", "character"}:
            delimiter = '"' if state == "string" else "'"
            if current == "\\":
                chars[index] = " "
                if index + 1 < len(chars):
                    if chars[index + 1] != "\n":
                        chars[index + 1] = " "
                    index += 2
                else:
                    index += 1
            elif current == delimiter:
                chars[index] = " "
                index += 1
                state = "code"
            else:
                if current != "\n":
                    chars[index] = " "
                index += 1
            continue

    return "".join(chars)


def normalize(declaration: str) -> str:
    return re.sub(r"\s+", " ", declaration.strip())


def declarations(path: Path, source_root: Path, public_names: set[str]) -> list[dict[str, object]]:
    source = path.read_text()
    masked = mask_non_code(source)
    result: list[dict[str, object]] = []
    for match in EXTERN_RE.finditer(masked):
        name = match.group(1)
        open_paren = masked.find("(", match.start())
        if re.search(r'extern\s+"c"\s+fn', source[match.start():open_paren]):
            continue
        depth = 0
        close_paren = -1
        for index in range(open_paren, len(masked)):
            if masked[index] == "(":
                depth += 1
            elif masked[index] == ")":
                depth -= 1
                if depth == 0:
                    close_paren = index
                    break
        if close_paren < 0:
            fail(f"unterminated parameter list for {name} in {path}")
        semicolon = masked.find(";", close_paren)
        if semicolon < 0:
            fail(f"unterminated declaration for {name} in {path}")
        declaration = normalize(source[match.start():semicolon + 1])
        convention_match = re.search(r"callconv\(([^)]+)\)", source[close_paren + 1:semicolon])
        calling_convention = convention_match.group(1).strip() if convention_match else "C"
        if name in public_names:
            classification = "public_c_api"
            status = "implemented"
            issue = None
        elif name in PLATFORM_IMPORTS:
            classification = "platform_import"
            status = "external"
            issue = None
        else:
            classification = "private_jsc"
            status = "pending"
            issue = 163
        entry: dict[str, object] = {
            "name": name,
            "source": path.relative_to(source_root).as_posix(),
            "line": source.count("\n", 0, match.start()) + 1,
            "calling_convention": calling_convention,
            "classification": classification,
            "status": status,
            "declaration": declaration,
            "declaration_sha256": sha256_bytes(declaration.encode()),
        }
        if issue is not None:
            entry["issue"] = issue
        result.append(entry)
    return result


def revision(root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot determine Home revision at {root}: {error}")


def generate(home_root: Path) -> dict[str, object]:
    actual_revision = revision(home_root)
    if actual_revision != REVISION:
        fail(f"Home revision mismatch: {actual_revision} != {REVISION}")
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    absolute_source_root = home_root / SOURCE_ROOT
    entries: list[dict[str, object]] = []
    source_hashes: dict[str, str] = {}
    for path in sorted(absolute_source_root.rglob("*.zig")):
        found = declarations(path, absolute_source_root, public_names)
        if not found:
            continue
        relative = path.relative_to(home_root).as_posix()
        source_hashes[relative] = sha256(path)
        entries.extend(found)
    entries.sort(key=lambda entry: (str(entry["name"]), str(entry["source"]), int(entry["line"])))

    names = [str(entry["name"]) for entry in entries]
    duplicates = sorted(name for name, count in Counter(names).items() if count > 1)
    if duplicates:
        fail(f"conflicting duplicate symbol declarations: {duplicates}")
    classifications = Counter(str(entry["classification"]) for entry in entries)
    return {
        "schema_version": 1,
        "profile_id": PROFILE_ID,
        "kind": "private_abi_inventory",
        "consumer": {
            "name": "Home",
            "revision": REVISION,
            "source_root": SOURCE_ROOT.as_posix(),
            "source_files": source_hashes,
        },
        "boundary": {
            "included": "Zig extern fn declarations under packages/runtime/src/jsc",
            "excluded": "explicit extern \"c\" public profile declarations tracked by home-public-c-7ed99c02",
            "implementation_issue": 163,
        },
        "calling_conventions": {
            "C": "extern default C calling convention",
            ".c": "explicit C calling convention",
            "jsc.conv": "x86_64 SysV on Windows x64; C on every other Home target"
        },
        "totals": {
            "symbols": len(entries),
            "source_files": len(source_hashes),
            "by_classification": dict(sorted(classifications.items())),
        },
        "declarations": entries,
    }


def refresh_implementation_status(data: dict[str, object]) -> None:
    zig_js_exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    for entry in data["declarations"]:
        if entry["classification"] != "private_jsc":
            continue
        if entry["name"] in zig_js_exports:
            entry["status"] = "implemented"
            entry.pop("issue", None)
            entry["implementation"] = "src/c_api.zig"
        else:
            entry["status"] = "pending"
            entry["issue"] = 163
            entry.pop("implementation", None)
    statuses = Counter(str(entry["status"]) for entry in data["declarations"])
    data["totals"]["by_status"] = dict(sorted(statuses.items()))


def verify_alias(home_root: Path, stored: dict[str, object], profile_id: str) -> None:
    alias = json.loads(ALIAS_PROFILES[profile_id].read_text())
    if alias.get("schema_version") != 1 or alias.get("profile_id") != profile_id:
        fail("alias profile schema or identity mismatch")
    if alias.get("base_profile") != PROFILE_ID or alias.get("base_revision") != REVISION:
        fail("alias base-profile identity mismatch")
    actual_revision = revision(home_root)
    expected_revision = alias["consumer"]["revision"]
    if actual_revision != expected_revision:
        fail(f"Home revision mismatch: {actual_revision} != {expected_revision}")

    source_files = stored["consumer"]["source_files"]
    canonical_manifest = json.dumps(source_files, sort_keys=True, separators=(",", ":")).encode()
    if sha256_bytes(canonical_manifest) != alias.get("source_manifest_sha256"):
        fail("alias source-manifest digest mismatch")
    for relative, expected_digest in source_files.items():
        path = home_root / relative
        if not path.is_file() or sha256(path) != expected_digest:
            fail(f"alias source hash mismatch for {relative}")

    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    absolute_source_root = home_root / SOURCE_ROOT
    current: list[dict[str, object]] = []
    current_source_files: set[str] = set()
    for path in sorted(absolute_source_root.rglob("*.zig")):
        found = declarations(path, absolute_source_root, public_names)
        if found:
            current.extend(found)
            current_source_files.add(path.relative_to(home_root).as_posix())
    current.sort(key=lambda entry: (str(entry["name"]), str(entry["source"]), int(entry["line"])))
    if current_source_files != set(source_files):
        fail("alias extern source-file set differs from the base profile")
    contract_keys = (
        "name", "source", "line", "calling_convention", "classification",
        "declaration", "declaration_sha256",
    )
    base_contract = [{key: entry[key] for key in contract_keys} for entry in stored["declarations"]]
    current_contract = [{key: entry[key] for key in contract_keys} for entry in current]
    if current_contract != base_contract:
        fail("alias declaration/signature/calling-convention contract differs from the base profile")
    if any(value != 0 for value in alias.get("comparison", {}).values()):
        fail("byte-identical alias must report a zero declaration diff")


def validate_stored(data: dict[str, object]) -> None:
    if data.get("schema_version") != 1 or data.get("profile_id") != PROFILE_ID:
        fail("stored inventory schema or profile identity mismatch")
    entries = data.get("declarations")
    if not isinstance(entries, list) or not entries:
        fail("stored inventory has no declarations")
    names: list[str] = []
    counts: Counter[str] = Counter()
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    conventions = set(data.get("calling_conventions", {}))
    zig_js_exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    for entry in entries:
        name = entry.get("name")
        declaration = entry.get("declaration")
        classification = entry.get("classification")
        if not isinstance(name, str) or not isinstance(declaration, str):
            fail("stored declaration is missing a name or signature")
        if entry.get("calling_convention") not in conventions:
            fail(f"{name} has an unsupported calling convention")
        if classification not in {"public_c_api", "platform_import", "private_jsc"}:
            fail(f"{name} is unclassified")
        if entry.get("declaration_sha256") != sha256_bytes(declaration.encode()):
            fail(f"{name} declaration digest drift")
        if classification == "private_jsc":
            expected_status = "implemented" if name in zig_js_exports else "pending"
            if entry.get("status") != expected_status:
                fail(f"{name} private implementation status drift")
            if expected_status == "pending" and entry.get("issue") != 163:
                fail(f"{name} pending status is not linked to #163")
            if expected_status == "implemented" and entry.get("implementation") != "src/c_api.zig":
                fail(f"{name} implementation location drift")
        expected_classification = (
            "public_c_api" if name in public_names
            else "platform_import" if name in PLATFORM_IMPORTS
            else "private_jsc"
        )
        if classification != expected_classification:
            fail(f"{name} classification drift: {classification} != {expected_classification}")
        names.append(name)
        counts[str(classification)] += 1
    if len(names) != len(set(names)):
        fail("stored inventory contains duplicate symbols")
    totals = data.get("totals", {})
    if totals.get("symbols") != len(entries) or totals.get("by_classification") != dict(sorted(counts.items())):
        fail("stored inventory totals drift")
    statuses = Counter(str(entry["status"]) for entry in entries)
    if totals.get("by_status") != dict(sorted(statuses.items())):
        fail("stored implementation-status totals drift")
    source_files = data.get("consumer", {}).get("source_files", {})
    if totals.get("source_files") != len(source_files):
        fail("stored source-file total drift")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=(PROFILE_ID, *ALIAS_PROFILES), default=PROFILE_ID)
    parser.add_argument("--home-root", type=Path)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--refresh-implementation-status", action="store_true")
    args = parser.parse_args()
    if args.write and not args.home_root:
        fail("--write requires --home-root")
    if args.write and args.profile != PROFILE_ID:
        fail("the alias profile reuses the immutable base inventory and cannot be generated separately")
    if args.write and args.refresh_implementation_status:
        fail("--write and --refresh-implementation-status are mutually exclusive")

    if args.home_root and args.profile == PROFILE_ID:
        generated = generate(args.home_root.resolve())
        refresh_implementation_status(generated)
        if args.write:
            OUTPUT.write_text(json.dumps(generated, indent=2) + "\n")
        elif not OUTPUT.is_file() or generated != json.loads(OUTPUT.read_text()):
            fail("checked-in inventory differs from the pinned Home source; regenerate deliberately")
    if not OUTPUT.is_file():
        fail(f"missing checked-in inventory {OUTPUT}")
    stored = json.loads(OUTPUT.read_text())
    if args.refresh_implementation_status:
        refresh_implementation_status(stored)
        OUTPUT.write_text(json.dumps(stored, indent=2) + "\n")
    validate_stored(stored)
    if args.home_root and args.profile in ALIAS_PROFILES:
        verify_alias(args.home_root.resolve(), stored, args.profile)
    totals = stored["totals"]
    classes = totals["by_classification"]
    statuses = totals["by_status"]
    print(
        f"Home private ABI audit: {args.profile}: {totals['symbols']} symbols from {totals['source_files']} files; "
        f"private={classes.get('private_jsc', 0)}, public={classes.get('public_c_api', 0)}, "
        f"platform={classes.get('platform_import', 0)}, "
        f"implemented-private={statuses.get('implemented', 0) - classes.get('public_c_api', 0)}, "
        f"pending-private={statuses.get('pending', 0)}, unclassified=0"
    )


if __name__ == "__main__":
    main()
