#!/usr/bin/env python3
"""Compare the public WebAssembly exception JS API with system JavaScriptCore."""

from __future__ import annotations

import difflib
import hashlib
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/wasm_exception_jsc_diff.c"


def run(command: list[str]) -> bytes:
    return subprocess.run(command, cwd=ROOT, check=True, stdout=subprocess.PIPE).stdout


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: wasm-exception-jsc-diff.py <zig-js fixture>")
    if platform.system() != "Darwin":
        raise SystemExit("the WebAssembly exception JavaScriptCore differential requires macOS")

    with tempfile.TemporaryDirectory(prefix="zig-js-wasm-exception-jsc-") as directory:
        reference = Path(directory) / "wasm-exception-jsc"
        subprocess.run(
            [
                "xcrun", "--sdk", "macosx", "clang", str(FIXTURE),
                "-framework", "JavaScriptCore", "-o", str(reference),
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
        raise SystemExit("WebAssembly exception JSC differential mismatch:\n" + "\n".join(difference))
    digest = hashlib.sha256(actual).hexdigest()[:16]
    print(f"WebAssembly exception JSC differential: matched {len(actual.splitlines())} rows ({digest})")


if __name__ == "__main__":
    main()
