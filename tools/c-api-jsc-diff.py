#!/usr/bin/env python3
"""Compile the value/class API fixture against system JSC and compare output."""

from __future__ import annotations

import difflib
import hashlib
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/c_api_value_diff.c"


def run(command: list[str]) -> bytes:
    return subprocess.run(command, cwd=ROOT, check=True, stdout=subprocess.PIPE).stdout


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: c-api-jsc-diff.py <zig-js fixture executable>")
    if platform.system() != "Darwin":
        raise SystemExit("the pinned JavaScriptCore differential gate requires macOS")

    sdk_root = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
    subprocess.run(
        [sys.executable, "tools/verify-c-api.py", "--sdk-root", sdk_root],
        cwd=ROOT,
        check=True,
    )
    with tempfile.TemporaryDirectory(prefix="zig-js-jsc-diff-") as directory:
        reference = Path(directory) / "jsc-value-diff"
        subprocess.run(
            [
                "xcrun", "--sdk", "macosx", "clang",
                str(FIXTURE), "-framework", "JavaScriptCore", "-o", str(reference),
            ],
            cwd=ROOT,
            check=True,
        )
        expected = run([str(reference)])
        actual = run([sys.argv[1]])

    if actual != expected:
        difference = difflib.unified_diff(
            expected.decode().splitlines(),
            actual.decode().splitlines(),
            fromfile="system JavaScriptCore",
            tofile="zig-js",
            lineterm="",
        )
        raise SystemExit("C API differential mismatch:\n" + "\n".join(difference))
    digest = hashlib.sha256(actual).hexdigest()[:16]
    print(f"c-api JSC differential: matched {len(actual.splitlines())} rows ({digest})")


if __name__ == "__main__":
    main()
