#!/usr/bin/env python3
"""Append objects to an existing static library without re-parsing Mach-O."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit("usage: merge-static-library.py OUTPUT BASE OBJECT...")

    output = Path(sys.argv[1])
    base = Path(sys.argv[2])
    objects = [Path(argument) for argument in sys.argv[3:]]
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(base, output)
    subprocess.run(["xcrun", "ar", "-q", output, *objects], check=True)
    subprocess.run(["xcrun", "ranlib", output], check=True)


if __name__ == "__main__":
    main()
