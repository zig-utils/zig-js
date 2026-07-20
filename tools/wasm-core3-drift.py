#!/usr/bin/env python3
"""Report WebAssembly spec main drift from zig-js's accepted Core 3 pin."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent.parent
BASE_TAG = "wg-3.0"
BASE_COMMIT = "9d36019973201a19f9c9ebb0f10828b2fe2374aa"


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return result.stdout.strip()


def corpus_files(repo: Path, revision: str) -> list[str]:
    return sorted(
        path
        for path in git(repo, "ls-tree", "-r", "--name-only", revision, "--", "test/core").splitlines()
        if path.endswith(".wast")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec-root", type=Path, default=ROOT / "wasm-spec-wg3")
    parser.add_argument("--upstream-ref", default="origin/main")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    repo = args.spec_root.resolve()
    pinned = git(repo, "rev-parse", "HEAD")
    if pinned != BASE_COMMIT:
        raise SystemExit(f"Core 3 submodule pin drift: expected {BASE_COMMIT}, found {pinned}")
    if git(repo, "rev-parse", f"{BASE_TAG}^{{commit}}") != BASE_COMMIT:
        raise SystemExit(f"Core 3 tag drift: {BASE_TAG} does not resolve to {BASE_COMMIT}")

    upstream = git(repo, "rev-parse", f"{args.upstream_ref}^{{commit}}")
    base_files = corpus_files(repo, BASE_COMMIT)
    upstream_files = corpus_files(repo, upstream)
    changes = []
    for line in git(
        repo,
        "diff",
        "--name-status",
        "--find-renames",
        BASE_COMMIT,
        upstream,
        "--",
        "test/core",
    ).splitlines():
        fields = line.split("\t")
        if not fields or not fields[0]:
            continue
        entry = {"status": fields[0], "path": fields[-1]}
        if len(fields) == 3:
            entry["previous_path"] = fields[1]
        changes.append(entry)

    report = {
        "schema_version": 1,
        "kind": "webassembly_core_3_upstream_drift",
        "accepted": {
            "tag": BASE_TAG,
            "commit": BASE_COMMIT,
            "corpus_files": len(base_files),
        },
        "upstream": {
            "ref": args.upstream_ref,
            "commit": upstream,
            "corpus_files": len(upstream_files),
        },
        "core_test_diff": {
            "changed_files": len(changes),
            "added_files": len(set(upstream_files) - set(base_files)),
            "removed_files": len(set(base_files) - set(upstream_files)),
            "entries": changes,
        },
        "accepted_score_changed": False,
    }
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
