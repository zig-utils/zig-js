#!/usr/bin/env python3
"""Reject private-ABI executables that omit the selected TSan mode."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build.zig"
PRIVATE_LINK_RE = re.compile(
    r"(?m)^    (?P<name>\w+)\.root_module\.linkLibrary\("
    r"(?P<profile>home_private_lib|bun_private_lib)\);"
)


def main() -> None:
    source = BUILD.read_text()
    checked: list[tuple[str, str]] = []
    missing: list[str] = []
    for match in PRIVATE_LINK_RE.finditer(source):
        name = match.group("name")
        profile = match.group("profile")
        start = source.rfind(f"    const {name} = b.addExecutable(.{{", 0, match.start())
        if start < 0:
            raise SystemExit(f"private ABI TSan audit: cannot find executable definition for {name}")
        definition = source[start : match.end()]
        checked.append((name, profile))
        if ".sanitize_thread = tsan" not in definition:
            missing.append(name)

    home = sum(profile == "home_private_lib" for _, profile in checked)
    bun = sum(profile == "bun_private_lib" for _, profile in checked)
    if (home, bun) != (14, 22):
        raise SystemExit(
            f"private ABI TSan audit: fixture inventory drift: Home={home}, Bun={bun}"
        )
    if missing:
        raise SystemExit(f"private ABI TSan audit: missing propagation: {', '.join(missing)}")
    print(f"Private ABI TSan audit: {len(checked)}/{len(checked)} executables propagate -Dtsan")


if __name__ == "__main__":
    main()
