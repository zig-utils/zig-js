#!/usr/bin/env python3
"""Generate and verify revision-pinned Home/Bun private JSType layouts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/abi/private-jstype-layouts.json"
SOURCE = Path("packages/runtime/src/jsc/JSType.zig")
BUN_SOURCE = Path("src/jsc/JSType.zig")
HOME_REVISIONS = {
    "7ed99c02e50034f869d0db6d487115bb44332fe4",
    "5e829ad483bb9e5ccb19766997df6462edd8e167",
    "38702f9e43b3aecbee7d5b7aa48cc66d41cabde7",
}
BUN_REVISION = "4982b91e3702094330f3be3883354c52b8c01323"
HOME_SOURCE_SHA256 = "93abf0de1e71007acea7d2b41da258130d676be1d94494d5a572da511b9299dc"
BUN_SOURCE_SHA256 = "34370d4e5230020e38d162fd0e2f047160bf94a1408670cedde168ca2b6555ee"
ENUM_START = "pub const JSType = enum(u8) {"
MEMBER_RE = re.compile(r"^    ([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+),\s*$", re.M)


def fail(message: str) -> None:
    print(f"private JSType ABI audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def revision(root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot determine revision at {root}: {error}")


def parse(path: Path) -> dict[str, int]:
    source = path.read_text()
    if source.count(ENUM_START) != 1:
        fail(f"expected exactly one JSType enum in {path}")
    body = source.split(ENUM_START, 1)[1].split("\n    _,", 1)[0]
    members = {name: int(value) for name, value in MEMBER_RE.findall(body)}
    if not members or len(members) != len(MEMBER_RE.findall(body)):
        fail(f"duplicate or empty JSType members in {path}")
    values = sorted(members.values())
    if values != list(range(len(values))):
        fail(f"JSType values are not contiguous from zero in {path}")
    return members


def source_record(
    root: Path,
    source: Path,
    allowed_revisions: set[str],
    expected_sha256: str,
) -> dict[str, object]:
    actual_revision = revision(root)
    if actual_revision not in allowed_revisions:
        fail(f"unsupported revision {actual_revision} at {root}")
    path = root / source
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != expected_sha256:
        fail(f"source digest mismatch for {path}: {digest}")
    return {
        "revision": actual_revision,
        "source": source.as_posix(),
        "source_sha256": digest,
        "members": parse(path),
    }


def comparison(home: dict[str, int], bun: dict[str, int]) -> dict[str, object]:
    shared = sorted(home.keys() & bun.keys())
    return {
        "shared_members": len(shared),
        "home_only": sorted(home.keys() - bun.keys()),
        "bun_only": sorted(bun.keys() - home.keys()),
        "renumbered": [
            {"name": name, "home": home[name], "bun": bun[name]}
            for name in shared
            if home[name] != bun[name]
        ],
    }


def generate(home_root: Path, bun_root: Path) -> dict[str, object]:
    home = source_record(home_root, SOURCE, HOME_REVISIONS, HOME_SOURCE_SHA256)
    bun = source_record(bun_root, BUN_SOURCE, {BUN_REVISION}, BUN_SOURCE_SHA256)
    return {
        "schema_version": 1,
        "kind": "private_jstype_layouts",
        "profiles": {
            "home": home,
            "bun": bun,
        },
        "comparison": comparison(home["members"], bun["members"]),
    }


def validate(data: dict[str, object]) -> None:
    if data.get("schema_version") != 1 or data.get("kind") != "private_jstype_layouts":
        fail("schema or kind mismatch")
    profiles = data.get("profiles", {})
    if set(profiles) != {"home", "bun"}:
        fail("expected exactly the home and bun profiles")
    home = profiles["home"]
    bun = profiles["bun"]
    if home.get("revision") not in HOME_REVISIONS or bun.get("revision") != BUN_REVISION:
        fail("stored revision mismatch")
    if home.get("source") != SOURCE.as_posix() or bun.get("source") != BUN_SOURCE.as_posix():
        fail("stored source path mismatch")
    if home.get("source_sha256") != HOME_SOURCE_SHA256 or bun.get("source_sha256") != BUN_SOURCE_SHA256:
        fail("stored source digest mismatch")
    for name, profile in profiles.items():
        members = profile.get("members", {})
        if not members or sorted(members.values()) != list(range(len(members))):
            fail(f"stored {name} members are not contiguous from zero")
        if not re.fullmatch(r"[0-9a-f]{64}", str(profile.get("source_sha256", ""))):
            fail(f"stored {name} source digest is invalid")
    expected = comparison(home["members"], bun["members"])
    if data.get("comparison") != expected:
        fail("stored Home/Bun comparison drift")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home-root", type=Path)
    parser.add_argument("--bun-root", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write and (not args.home_root or not args.bun_root):
        fail("--write requires --home-root and --bun-root")
    if (args.home_root is None) != (args.bun_root is None):
        fail("live verification requires both --home-root and --bun-root")
    if args.home_root:
        generated = generate(args.home_root.resolve(), args.bun_root.resolve())
        if args.write:
            OUTPUT.write_text(json.dumps(generated, indent=2) + "\n")
        elif not OUTPUT.is_file() or generated != json.loads(OUTPUT.read_text()):
            fail("checked-in layouts differ from the pinned consumer sources")
    if not OUTPUT.is_file():
        fail(f"missing checked-in layout inventory {OUTPUT}")
    stored = json.loads(OUTPUT.read_text())
    validate(stored)
    comparison_data = stored["comparison"]
    print(
        "private JSType ABI audit: "
        f"Home={len(stored['profiles']['home']['members'])}, "
        f"Bun={len(stored['profiles']['bun']['members'])}, "
        f"shared={comparison_data['shared_members']}, "
        f"Bun-only={len(comparison_data['bun_only'])}, "
        f"renumbered={len(comparison_data['renumbered'])}"
    )


if __name__ == "__main__":
    main()
