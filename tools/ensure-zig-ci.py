#!/usr/bin/env python3
"""Install Zig master from ziglang.org when the primary CI setup left no binary."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


INDEX_URL = "https://ziglang.org/download/index.json"


def target_key() -> str:
    architecture = platform.machine().lower()
    architecture = {"amd64": "x86_64", "arm64": "aarch64"}.get(architecture, architecture)
    system = {"linux": "linux", "darwin": "macos"}.get(platform.system().lower())
    if system is None:
        raise RuntimeError(f"unsupported CI host: {platform.system()} {platform.machine()}")
    return f"{architecture}-{system}"


def fetch_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def download(url: str, destination: Path) -> None:
    with urllib.request.urlopen(url, timeout=180) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def main() -> int:
    existing = shutil.which("zig")
    if existing:
        version = subprocess.run([existing, "version"], check=True, text=True, capture_output=True).stdout.strip()
        print(f"Using primary Zig {version} at {existing}")
        return 0

    target = target_key()
    master = fetch_json(INDEX_URL)["master"]
    artifact = master.get(target)
    if not artifact:
        raise RuntimeError(f"Zig master has no artifact for {target}")

    runner_temp = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir()))
    install_root = runner_temp / f"zig-fallback-{master['version']}-{target}"
    archive = runner_temp / Path(artifact["tarball"]).name
    print(f"Primary setup produced no zig; downloading Zig {master['version']} for {target}")
    download(artifact["tarball"], archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != artifact["shasum"]:
        raise RuntimeError(f"Zig archive checksum mismatch: expected {artifact['shasum']}, got {digest}")

    if install_root.exists():
        shutil.rmtree(install_root)
    install_root.mkdir(parents=True)
    with tarfile.open(archive, "r:xz") as bundle:
        try:
            bundle.extractall(install_root, filter="data")
        except TypeError:  # Python < 3.12 on older supported macOS runners.
            bundle.extractall(install_root)
    candidates = list(install_root.glob("*/zig"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected one Zig executable, found {candidates}")
    bin_dir = candidates[0].parent
    with Path(os.environ["GITHUB_PATH"]).open("a") as github_path:
        github_path.write(f"{bin_dir}\n")
    version = subprocess.run([candidates[0], "version"], check=True, text=True, capture_output=True).stdout.strip()
    print(f"Installed fallback Zig {version} at {candidates[0]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
