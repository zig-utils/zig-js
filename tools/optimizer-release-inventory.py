#!/usr/bin/env python3
"""Validate the optimizing-tier release contract and its checked evidence."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INVENTORY = ROOT / "docs/.data/optimizer-release-inventory.json"
REQUIRED_SUITES = {
    "fallback-build-linux-x86_64",
    "fallback-build-macos-x86_64",
    "focused-jit-debug",
    "focused-jit-tsan",
    "seeded-differential-debug",
    "seeded-differential-tsan",
    "full-unit-debug",
    "pr249-terminal-release-safe",
}


def fail(message: str) -> None:
    raise ValueError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def relative_path(value: object, field: str) -> Path:
    require(isinstance(value, str) and value, f"{field} must be a non-empty path")
    path = Path(value)
    require(not path.is_absolute() and ".." not in path.parts, f"{field} must stay inside the repository")
    resolved = ROOT / path
    require(resolved.is_file(), f"{field} does not exist: {path}")
    return resolved


def validate_inventory(path: Path) -> dict[str, object]:
    data = json.loads(path.read_text())
    require(data.get("schema_version") == 1, "schema_version must be 1")
    commit = data.get("implementation_commit")
    require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit) is not None,
            "implementation_commit must be a full lowercase Git commit")

    contract = data.get("contract")
    require(isinstance(contract, dict), "contract must be an object")
    supported = contract.get("supported")
    require(isinstance(supported, list) and len(supported) == 1,
            "the declared optimizer matrix must contain exactly one supported backend")
    backend = supported[0]
    require(isinstance(backend, dict), "supported backend must be an object")
    require(
        (backend.get("os"), backend.get("architecture"), backend.get("backend"), backend.get("status"))
        == ("macos", "aarch64", "macos_aarch64", "gated"),
        "the sole supported optimizer backend must be gated macOS AArch64",
    )
    require("MAP_JIT" in str(backend.get("executable_memory")),
            "supported backend must state its executable-memory contract")

    fallback = contract.get("fallback")
    require(isinstance(fallback, list) and len(fallback) >= 4,
            "fallback matrix must cover named unsupported host families")
    fallback_pairs = {
        (entry.get("os"), entry.get("architecture"))
        for entry in fallback
        if isinstance(entry, dict)
    }
    for pair in (("macos", "x86_64"), ("linux", "aarch64"), ("linux", "x86_64")):
        require(pair in fallback_pairs, f"missing explicit fallback matrix entry {pair}")
    for entry in fallback:
        require(isinstance(entry, dict), "fallback entries must be objects")
        require("baseline or bytecode" in str(entry.get("behavior")),
                "every unsupported host must name baseline/bytecode fallback")
        require("zero" in str(entry.get("behavior")),
                "every unsupported host must reject fake optimizer publication counts")

    correctness = data.get("correctness")
    require(isinstance(correctness, dict), "correctness must be an object")
    require(correctness.get("seed") == "0x434f4445585f3433", "seeded differential seed drifted")
    require(correctness.get("seeded_cases_per_mode") == 12,
            "seeded differential must retain twelve cases per execution mode")
    surfaces = correctness.get("surfaces")
    require(isinstance(surfaces, list) and len(surfaces) >= 8,
            "correctness surface inventory is incomplete")

    anchors = correctness.get("source_anchors")
    require(isinstance(anchors, list) and anchors, "source_anchors must be non-empty")
    for index, anchor in enumerate(anchors):
        require(isinstance(anchor, dict), f"source_anchors[{index}] must be an object")
        source = relative_path(anchor.get("path"), f"source_anchors[{index}].path")
        text = anchor.get("text")
        require(isinstance(text, str) and text in source.read_text(),
                f"source anchor missing from {source.relative_to(ROOT)}: {text!r}")

    suites = correctness.get("suites")
    require(isinstance(suites, list), "correctness.suites must be an array")
    by_id = {
        suite.get("id"): suite
        for suite in suites
        if isinstance(suite, dict) and isinstance(suite.get("id"), str)
    }
    require(set(by_id) == REQUIRED_SUITES,
            f"suite inventory drift: expected {sorted(REQUIRED_SUITES)}, found {sorted(by_id)}")
    for suite_id, suite in by_id.items():
        require(suite.get("failed") == 0, f"{suite_id} records failures")
        if "leaked" in suite:
            require(suite.get("leaked") == 0, f"{suite_id} records leaks")
        require(isinstance(suite.get("command"), str) and suite["command"],
                f"{suite_id} must carry a reproduction command")
    require(by_id["focused-jit-debug"].get("passed") == by_id["focused-jit-tsan"].get("passed"),
            "normal and TSan focused gates must cover the same test count")
    require(by_id["seeded-differential-debug"].get("seed_executions") == 24,
            "normal seeded gate must execute both twelve-case modes")
    require(by_id["seeded-differential-tsan"].get("seed_executions") == 24,
            "TSan seeded gate must execute both twelve-case modes")

    terminal = json.loads((ROOT / "docs/.data/pr249-terminal-execution.json").read_text())
    terminal_summary = terminal.get("summary", {})
    terminal_suite = by_id["pr249-terminal-release-safe"]
    for key in ("executable", "promoted", "terminal_disposition"):
        require(terminal_suite.get({
            "executable": "executables",
            "promoted": "promoted",
            "terminal_disposition": "terminal_disposition",
        }[key]) == terminal_summary.get(key), f"PR-249 {key} count drift")
    require(terminal_summary.get("blocked") == 0, "optimizer release evidence cannot retain blocked PR-249 cases")

    sanitizers = data.get("sanitizers")
    require(isinstance(sanitizers, dict), "sanitizers must be an object")
    require("ThreadSanitizer" in sanitizers.get("engine", []), "TSan evidence is required")
    require("AddressSanitizer for Zig engine code" in sanitizers.get("not_claimed", []),
            "unavailable Zig ASan must not be claimed")

    performance = data.get("performance")
    require(isinstance(performance, dict), "performance must be an object")
    report = relative_path(performance.get("report"), "performance.report")
    raw = relative_path(performance.get("raw_samples"), "performance.raw_samples")
    measured = performance.get("measured_zig_js_commit")
    require(isinstance(measured, str) and re.fullmatch(r"[0-9a-f]{40}", measured) is not None,
            "performance measured_zig_js_commit must be a full Git commit")
    report_text = report.read_text()
    require(measured in report_text, "performance report does not name its measured zig-js commit")
    require(raw.name in report_text, "performance report does not link its raw sample file")
    raw_lines = raw.read_text().splitlines()
    require(len(raw_lines) > 2 and raw_lines[0].startswith("engine\tmode\tworkload\t"),
            "performance raw sample file is empty or malformed")
    publication_gate = performance.get("publication_gate")
    require(isinstance(publication_gate, dict) and publication_gate.get("failed") == 0,
            "benchmark publication gate must be recorded green")

    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    args = parser.parse_args()
    try:
        data = validate_inventory(args.inventory.resolve())
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"optimizer release inventory: FAIL: {error}", file=sys.stderr)
        return 1

    correctness = data["correctness"]
    print(
        "optimizer release inventory: PASS "
        f"(1 supported backend, {len(correctness['surfaces'])} surfaces, "
        f"{len(correctness['suites'])} suites)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
