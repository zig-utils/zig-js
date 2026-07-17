#!/usr/bin/env python3
"""Verify revision-pinned consumer ABI profiles against zig-js exports."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {
    "home-public-c-7ed99c02": ROOT / "docs/abi/home-public-c-7ed99c02.json",
}
FIXTURES = {
    "home-public-c-7ed99c02": ROOT / "tests/abi/home_public_c_7ed99c02.zig",
}
EXPORT_SOURCE = ROOT / "src/c_api.zig"
EXTERN_RE = re.compile(r"^(?:pub )?extern \"c\" fn ([A-Za-z_][A-Za-z0-9_]*)(.*);$", re.M)
EXPORT_RE = re.compile(r"^export fn ([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)


def fail(message: str) -> None:
    print(f"ABI profile audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def declarations(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for name, suffix in EXTERN_RE.findall(path.read_text()):
        normalized = re.sub(r"\s+", " ", suffix.strip())
        if name in result:
            fail(f"duplicate extern declaration {name} in {path}")
        result[name] = normalized
    return result


def verify_home_source(root: Path, data: dict[str, object], fixture_decls: dict[str, str]) -> None:
    consumer = data["consumer"]
    expected_revision = consumer["revision"]
    try:
        actual_revision = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot read Home revision at {root}: {error}")
    if actual_revision != expected_revision:
        fail(f"Home revision mismatch: {actual_revision} != {expected_revision}")

    for relative, expected_digest in consumer["sources"].items():
        path = root / relative
        if not path.is_file():
            fail(f"missing pinned Home source {path}")
        actual_digest = sha256(path)
        if actual_digest != expected_digest:
            fail(f"Home source digest mismatch for {relative}: {actual_digest} != {expected_digest}")

    source_decls = declarations(root / "packages/runtime/src/jsc/extern_fns.zig")
    if source_decls != fixture_decls:
        missing = sorted(fixture_decls.keys() - source_decls.keys())
        extra = sorted(source_decls.keys() - fixture_decls.keys())
        changed = sorted(
            name for name in fixture_decls.keys() & source_decls.keys()
            if fixture_decls[name] != source_decls[name]
        )
        fail(f"Home declaration drift; missing={missing}, extra={extra}, changed={changed}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="home-public-c-7ed99c02")
    parser.add_argument("--home-root", type=Path)
    args = parser.parse_args()

    if args.profile not in PROFILES:
        fail(f"unsupported profile {args.profile!r}; supported={sorted(PROFILES)}")
    data = json.loads(PROFILES[args.profile].read_text())
    if data.get("schema_version") != 1 or data.get("profile_id") != args.profile:
        fail("profile schema or identity mismatch")
    if data.get("kind") != "public_c_embedding":
        fail("Home public profile must not be classified as a private ABI shim")
    if data["abi"].get("calling_convention") != "C":
        fail("unsupported calling convention")

    names = data.get("functions")
    if not isinstance(names, list) or len(names) != 50 or len(names) != len(set(names)):
        fail("Home profile must contain 50 unique functions")
    fixture_decls = declarations(FIXTURES[args.profile])
    if set(names) != set(fixture_decls):
        fail(
            f"fixture/profile drift; missing={sorted(set(names) - set(fixture_decls))}, "
            f"extra={sorted(set(fixture_decls) - set(names))}"
        )
    exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    missing_exports = sorted(set(names) - exports)
    if missing_exports:
        fail(f"zig-js exports are missing {missing_exports}")

    enums = data["abi"]["enums"]
    if enums["JSType"]["backing"] != "c_uint" or enums["JSTypedArrayType"]["backing"] != "c_uint":
        fail("enum backing-type drift")
    if enums["JSType"]["values"].get("kJSTypeBigInt") != 7:
        fail("JSType value drift")
    if enums["JSTypedArrayType"]["values"].get("kJSTypedArrayTypeBigUint64Array") != 12:
        fail("JSTypedArrayType value drift")
    if len(data.get("semantic_assumptions", [])) < 5:
        fail("semantic assumption inventory is incomplete")

    if args.home_root:
        verify_home_source(args.home_root.resolve(), data, fixture_decls)

    source_note = " and pinned Home source" if args.home_root else ""
    print(f"ABI profile audit: {args.profile}: 50/50 exports{source_note}; zero missing")


if __name__ == "__main__":
    main()
