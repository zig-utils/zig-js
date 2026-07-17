#!/usr/bin/env python3
"""Compile one Objective-C fixture against zig-js and system JSC, then compare."""

from __future__ import annotations

import difflib
import hashlib
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/objc_api_value_diff.m"


def run(command: list[str]) -> bytes:
    return subprocess.run(command, cwd=ROOT, check=True, stdout=subprocess.PIPE).stdout


def compile_fixture(output: Path, extra: list[str]) -> None:
    subprocess.run(
        [
            "xcrun",
            "--sdk",
            "macosx",
            "clang",
            "-fobjc-arc",
            "-fblocks",
            str(FIXTURE),
            *extra,
            "-framework",
            "Foundation",
            "-o",
            str(output),
        ],
        cwd=ROOT,
        check=True,
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: objc-api-jsc-diff.py <libzig-js.a>")
    if platform.system() != "Darwin":
        raise SystemExit("the pinned Objective-C differential gate requires macOS")

    sdk_root = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).decode().strip()
    subprocess.run(
        [sys.executable, "tools/verify-objc-api.py", "--sdk-root", sdk_root],
        cwd=ROOT,
        check=True,
    )

    with tempfile.TemporaryDirectory(prefix="zig-js-objc-diff-") as directory:
        temporary = Path(directory)
        reference = temporary / "system-jsc"
        actual = temporary / "zig-js"
        compile_fixture(reference, ["-framework", "JavaScriptCore"])
        compile_fixture(actual, ["-I", str(ROOT / "include"), sys.argv[1], "-lffi"])
        expected_output = run([str(reference)])
        actual_output = run([str(actual)])

    if actual_output != expected_output:
        difference = difflib.unified_diff(
            expected_output.decode().splitlines(),
            actual_output.decode().splitlines(),
            fromfile="system JavaScriptCore",
            tofile="zig-js",
            lineterm="",
        )
        raise SystemExit("Objective-C API differential mismatch:\n" + "\n".join(difference))

    digest = hashlib.sha256(actual_output).hexdigest()[:16]
    print(f"Objective-C JSC differential: matched {len(actual_output.splitlines())} rows ({digest})")


if __name__ == "__main__":
    main()
