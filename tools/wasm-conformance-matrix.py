#!/usr/bin/env python3
"""Generate or verify the terminal WebAssembly conformance matrix."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs/.data/wasm-conformance-matrix.json"

PROFILES = [
    ("mvp", "wasm-spec-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
    ("core-2-structural", "wasm-core-2-structural-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
    ("simd", "wasm-simd-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
    ("threads", "wasm-threads-inventory.json", {"decode_validate": ["portable"], "execute": ["threaded-context"]}),
    ("tail-calls", "wasm-tail-call-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
    ("exception-handling", "wasm-exception-handling-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
    ("multi-memory", "wasm-multi-memory-runtime-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
    ("memory64", "wasm-memory64-runtime-inventory.json", {"decode_validate": ["pointer-width-32", "pointer-width-64"], "execute": ["pointer-width-64"]}),
    ("gc", "wasm-gc-runtime-inventory.json", {"decode_validate": ["portable"], "execute": ["portable"]}),
]


def ordered_counts(values: Counter[str]) -> dict[str, int]:
    return {key: values[key] for key in sorted(values)}


def build_matrix() -> dict:
    profiles = []
    combined = Counter()
    for profile_id, filename, hosts in PROFILES:
        path = ROOT / "docs/.data" / filename
        inventory = json.loads(path.read_text())
        if inventory.get("schema_version") != 2:
            raise SystemExit(f"{profile_id}: terminal inventory schema drift")
        totals = inventory.get("totals", {})
        if totals.get("fail") != 0 or totals.get("runner_error") != 0:
            raise SystemExit(f"{profile_id}: terminal inventory is not green")
        for key, value in totals.items():
            combined[key] += value

        commands = [command for entry in inventory["files"] for command in entry["commands"]]
        modes = Counter(command.get("mode", "javascript_api") for command in commands)
        not_applicable = Counter(
            command.get("detail", "unspecified")
            for command in commands
            if command.get("status") == "not_applicable"
        )
        spec = inventory["spec"]
        profiles.append({
            "id": profile_id,
            "default": profile_id == "mvp",
            "status": "terminal",
            "inventory": f"docs/.data/{filename}",
            "engine_commit": inventory["engine_commit"],
            "features": inventory.get("features", []),
            "spec": {
                "repository": spec["repository"],
                "commit": spec["commit"],
                "tag": spec["tag"],
                "files_scored": spec["files_scored"],
            },
            "converter": inventory["converter"],
            "execution_modes": ordered_counts(modes),
            "not_applicable_reasons": ordered_counts(not_applicable),
            "host_scope": hosts,
            "architecture_scope": ["architecture-independent-interpreter"],
            "totals": totals,
        })

    return {
        "schema_version": 1,
        "kind": "zig_js_webassembly_conformance_matrix",
        "profiles": profiles,
        "combined_totals": {
            key: combined[key]
            for key in ("pass", "not_applicable", "fail", "runner_error", "total")
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="rewrite the checked-in matrix")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()

    rendered = json.dumps(build_matrix(), indent=2, sort_keys=True) + "\n"
    if args.write:
        args.output.write_text(rendered)
        print(f"WebAssembly conformance matrix written: {args.output}")
        return 0
    if not args.output.is_file() or args.output.read_text() != rendered:
        raise SystemExit("WebAssembly conformance matrix drift; run tools/wasm-conformance-matrix.py --write")
    matrix = json.loads(rendered)
    print(
        f"WebAssembly conformance matrix: {len(matrix['profiles'])} terminal profiles, "
        f"{matrix['combined_totals']['pass']} applicable passes"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
