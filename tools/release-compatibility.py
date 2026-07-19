#!/usr/bin/env python3
"""Validate the #134 release compatibility matrix and README removal gate."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MATRIX = ROOT / "docs/.data/release-compatibility-matrix.json"
EXPECTED_GATES = {
    "platform_matrix",
    "public_jsc_c_api",
    "objective_c_bridge",
    "inspector",
    "private_abi_profiles",
    "webassembly_mvp",
    "webassembly_profiles",
    "shell_and_reference_hooks",
    "moving_gc",
    "generational_gc",
    "optimizing_jit",
    "readme_generation",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"release-compatibility: {message}")


def artifact_path(relative: str) -> Path:
    path = (ROOT / relative).resolve()
    require(path.is_relative_to(ROOT), f"artifact escapes repository: {relative}")
    require(path.is_file(), f"missing artifact: {relative}")
    require(path.stat().st_size > 0, f"empty artifact: {relative}")
    if path.suffix == ".json":
        json.loads(path.read_text())
    return path


def statuses(value: object) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        if isinstance(value.get("status"), str):
            found.add(value["status"])
        for child in value.values():
            found.update(statuses(child))
    elif isinstance(value, list):
        for child in value:
            found.update(statuses(child))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matrix", nargs="?", type=Path, default=DEFAULT_MATRIX)
    parser.add_argument("--release", action="store_true", help="fail unless every roadmap gate is green")
    args = parser.parse_args()

    matrix = json.loads(args.matrix.read_text())
    require(matrix.get("schema_version") == 1, "unsupported schema version")
    require(matrix.get("kind") == "zig_js_release_compatibility_matrix", "invalid matrix kind")
    require(matrix.get("roadmap_issue") == 134, "roadmap issue drift")
    require(matrix.get("release_issue") == 147, "release issue drift")
    require(matrix.get("readme_removal_issue") == 246, "README removal issue drift")

    gates = matrix.get("gates", [])
    gate_ids = [gate.get("id") for gate in gates]
    require(len(gate_ids) == len(set(gate_ids)), "duplicate gate id")
    require(set(gate_ids) == EXPECTED_GATES, f"gate coverage drift: {sorted(set(gate_ids) ^ EXPECTED_GATES)}")
    for gate in gates:
        gate_id = gate["id"]
        require(gate.get("status") in {"green", "open"}, f"{gate_id}: invalid status")
        require(isinstance(gate.get("issue"), int), f"{gate_id}: issue is required")
        evidence = gate.get("evidence")
        require(isinstance(evidence, list) and evidence, f"{gate_id}: evidence is required")
        require(len(evidence) == len(set(evidence)), f"{gate_id}: duplicate evidence")
        for relative in evidence:
            artifact_path(relative)
        blockers = gate.get("blockers")
        require(isinstance(blockers, list), f"{gate_id}: blockers must be a list")
        if gate["status"] == "green":
            require(not blockers, f"{gate_id}: green gate has blockers")
        else:
            require(blockers, f"{gate_id}: open gate has no blocker")

    gate_by_id = {gate["id"]: gate for gate in gates}
    for gate_id in ("public_jsc_c_api", "objective_c_bridge", "inspector"):
        inventory = json.loads(artifact_path(gate_by_id[gate_id]["evidence"][0]).read_text())
        require(statuses(inventory) == {"implemented"}, f"{gate_id}: inventory is not fully implemented")

    private_pending = 0
    for relative in gate_by_id["private_abi_profiles"]["evidence"]:
        inventory = json.loads(artifact_path(relative).read_text())
        private_pending += inventory.get("totals", {}).get("by_status", {}).get("pending", 0)
    require(private_pending > 0, "private ABI inventories are terminal; mark their gate green")

    summaries = matrix.get("summaries", {})
    test262_summary = summaries.get("test262", {})
    test262 = json.loads(artifact_path(test262_summary.get("artifact", "")).read_text())
    test262_pass = test262["valid"]["passing"] + test262["negative"]["passing"]
    test262_total = test262["valid"]["total"] + test262["negative"]["total"]
    require(
        test262_summary == {
            "artifact": "docs/.data/test262.json",
            "pass": test262_pass,
            "total": test262_total,
            "skipped": test262["skipped"],
        },
        "test262 summary drift",
    )

    wasm_summary = summaries.get("webassembly", {})
    wasm = json.loads(artifact_path(wasm_summary.get("artifact", "")).read_text())
    wasm_totals = wasm["combined_totals"]
    require(
        wasm_summary == {
            "artifact": "docs/.data/wasm-conformance-matrix.json",
            "profiles": len(wasm["profiles"]),
            "pass": wasm_totals["pass"],
            "not_applicable": wasm_totals["not_applicable"],
            "fail": wasm_totals["fail"],
            "runner_error": wasm_totals["runner_error"],
        },
        "WebAssembly summary drift",
    )
    require(wasm_totals["fail"] == wasm_totals["runner_error"] == 0, "WebAssembly matrix is not terminal green")
    mvp = next((profile for profile in wasm["profiles"] if profile["id"] == "mvp"), None)
    require(mvp is not None and mvp["status"] == "terminal", "MVP WebAssembly gate drift")

    all_green = all(gate["status"] == "green" for gate in gates)
    require(matrix.get("all_green") is all_green, "all_green does not match gate states")
    policy = matrix.get("readme_policy", {})
    require(policy.get("remove_only_when_all_green") is True, "README removal policy drift")
    readme = artifact_path(policy.get("path", "")).read_text()
    heading = policy.get("not_implemented_heading")
    require(isinstance(heading, str) and heading, "README heading policy is required")
    require((heading not in readme) is all_green, "README missing-surface section does not match release state")
    require(f"**{test262_pass:,} / {test262_total:,}**" in readme, "README test262 score drift")
    require(f"**{wasm_totals['pass']:,} / {wasm_totals['pass']:,} applicable**" in readme, "README WebAssembly score drift")

    green = sum(gate["status"] == "green" for gate in gates)
    print(f"Release compatibility matrix: {green}/{len(gates)} gates green; private ABI pending={private_pending}")
    if args.release and not all_green:
        open_ids = ", ".join(gate["id"] for gate in gates if gate["status"] != "green")
        raise SystemExit(f"release-compatibility: release blocked by: {open_ids}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
