#!/usr/bin/env python3
"""Build and verify the terminal PR-249 execution artifact for issue #430.

The complete reproduction is deliberately two long, serialized corpus jobs:

  zig build threads-test -Doptimize=ReleaseSafe \
    -Dthreads-inventory=docs/.data/pr249-execution-serialized.json
  zig build threads-test -Doptimize=ReleaseSafe -Dthreads-parallel-js=true \
    -Dthreads-inventory=docs/.data/pr249-execution-nogil.json
  python3 tools/threads-reference-audit.py --format json --scan-unpromoted \
    --output docs/.data/pr249-unpromoted-scan-2026-07-28.json
  python3 tools/pr249-terminal-execution.py --generate --commit <40-hex-commit>

Ordinary CI runs only ``--check``. It verifies the checked artifacts,
checksums, declared modes, dispositions, and totals without rerunning the
multi-hour corpus.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
REFERENCE = REPO / "docs" / ".data" / "pr249-reference-inventory.json"
SERIALIZED = REPO / "docs" / ".data" / "pr249-execution-serialized.json"
NOGIL = REPO / "docs" / ".data" / "pr249-execution-nogil.json"
TAIL_SCAN = REPO / "docs" / ".data" / "pr249-unpromoted-scan-2026-07-28.json"
OUTPUT = REPO / "docs" / ".data" / "pr249-terminal-execution.json"


class ArtifactError(ValueError):
    pass


def load(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ArtifactError(f"{path.relative_to(REPO)}: {exc}") from exc
    if not isinstance(value, dict):
        raise ArtifactError(f"{path.relative_to(REPO)}: root must be an object")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ArtifactError(message)


def mode_records(
    artifact: dict[str, object],
    *,
    expected_mode: str,
) -> dict[str, dict[str, object]]:
    require(artifact.get("schema_version") == 2, f"{expected_mode}: schema_version must be 2")
    require(artifact.get("build_mode") == "ReleaseSafe", f"{expected_mode}: build_mode must be ReleaseSafe")
    require(artifact.get("mode") == expected_mode, f"{expected_mode}: mode field drift")
    raw_cases = artifact.get("cases")
    require(isinstance(raw_cases, list), f"{expected_mode}: cases must be an array")
    records: dict[str, dict[str, object]] = {}
    for raw in raw_cases:
        require(isinstance(raw, dict), f"{expected_mode}: case record must be an object")
        case = raw.get("case")
        require(isinstance(case, str), f"{expected_mode}: case name must be a string")
        require(case not in records, f"{expected_mode}: duplicate case {case}")
        require(raw.get("mode") == expected_mode, f"{expected_mode}: {case} mode drift")
        require(raw.get("result") == "pass", f"{expected_mode}: promoted case {case} did not pass")
        require(isinstance(raw.get("ms"), int) and raw["ms"] >= 0, f"{expected_mode}: {case} invalid duration")
        for counter in ("optimizer_publications", "optimizer_invalidations"):
            require(
                isinstance(raw.get(counter), int) and raw[counter] >= 0,
                f"{expected_mode}: {case} invalid {counter}",
            )
        records[case] = raw
    summary = artifact.get("summary")
    require(isinstance(summary, dict), f"{expected_mode}: summary must be an object")
    require(summary.get("cases") == len(records), f"{expected_mode}: summary case count drift")
    require(summary.get("passed") == len(records), f"{expected_mode}: every promoted case must pass")
    require(summary.get("failed") == 0, f"{expected_mode}: failed count must be zero")
    require(summary.get("skipped") == 0, f"{expected_mode}: skipped count must be zero")
    require(
        summary.get("cases_reaching_optimizer")
        == sum(1 for record in records.values() if record["optimizer_publications"] != 0),
        f"{expected_mode}: optimizer summary drift",
    )
    require(
        summary.get("total_ms") == sum(record["ms"] for record in records.values()),
        f"{expected_mode}: total_ms drift",
    )
    return records


def terminal_mode_records(
    scan: dict[str, object],
) -> dict[str, dict[str, dict[str, object]]]:
    require(scan.get("unpromoted_scan_disposition_drift") == 0, "terminal scan disposition drift")
    results = scan.get("unpromoted_scan_results")
    require(isinstance(results, list), "terminal scan results must be an array")
    records: dict[str, dict[str, dict[str, object]]] = {}
    for raw in results:
        require(isinstance(raw, dict), "terminal scan record must be an object")
        case = raw.get("case")
        require(isinstance(case, str), "terminal scan case must be a string")
        require(raw.get("status") == "terminal-disposition-confirmed", f"{case}: terminal disposition drift")
        modes = raw.get("mode_results")
        require(isinstance(modes, dict), f"{case}: terminal mode results missing")
        require(set(modes) == {"parallel-js", "serialized"}, f"{case}: terminal modes incomplete")
        checked: dict[str, dict[str, object]] = {}
        for mode in ("parallel-js", "serialized"):
            mode_result = modes[mode]
            require(isinstance(mode_result, dict), f"{case}: {mode} result must be an object")
            require(mode_result.get("expectation_matched") is True, f"{case}: {mode} expectation drift")
            require(
                mode_result.get("observed_status") == mode_result.get("expected_status"),
                f"{case}: {mode} observed/expected mismatch",
            )
            require(
                isinstance(mode_result.get("ms"), int) and mode_result["ms"] >= 0,
                f"{case}: {mode} invalid duration",
            )
            checked[mode] = mode_result
        require(case not in records, f"duplicate terminal scan case {case}")
        records[case] = checked
    return records


def compact_promoted_result(record: dict[str, object]) -> dict[str, object]:
    return {
        "ms": record["ms"],
        "optimizer_invalidations": record["optimizer_invalidations"],
        "optimizer_publications": record["optimizer_publications"],
        "result": "pass",
    }


def build_artifact(commit: str) -> dict[str, object]:
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "commit must be a full 40-hex SHA")
    reference = load(REFERENCE)
    require(reference.get("schema_version") == 2, "reference inventory schema drift")
    reference_summary = reference.get("summary")
    require(isinstance(reference_summary, dict), "reference summary missing")
    require(reference_summary.get("executable") == 259, "reference executable total drift")
    require(reference_summary.get("blocked") == 0, "terminal publication requires zero blocked cases")

    serialized = mode_records(load(SERIALIZED), expected_mode="serialized")
    nogil = mode_records(load(NOGIL), expected_mode="parallel-js")
    terminal = terminal_mode_records(load(TAIL_SCAN))

    files = reference.get("files")
    require(isinstance(files, list), "reference files missing")
    executable_entries = [
        entry
        for entry in files
        if isinstance(entry, dict)
        and entry.get("execution_state") in {"promoted", "terminal-disposition"}
    ]
    helpers = [
        entry
        for entry in files
        if isinstance(entry, dict) and entry.get("execution_state") == "helper/preload"
    ]
    require(len(executable_entries) == 259, "reference executable records drift")

    cases: list[dict[str, object]] = []
    expected_serialized: set[str] = set()
    expected_nogil: set[str] = set()
    expected_terminal: set[str] = set()
    for entry in sorted(executable_entries, key=lambda item: item["case"]):
        case = entry["case"]
        modes = entry.get("execution_modes")
        require(isinstance(modes, list) and modes, f"{case}: execution_modes missing")
        executions: dict[str, object] = {}
        if entry["execution_state"] == "promoted":
            expected_nogil.add(case)
            require(case in nogil, f"{case}: missing no-GIL execution")
            executions["parallel-js"] = compact_promoted_result(nogil[case])
            if "serialized" in modes:
                expected_serialized.add(case)
                require(case in serialized, f"{case}: missing serialized execution")
                executions["serialized"] = compact_promoted_result(serialized[case])
            require(set(executions) == set(modes), f"{case}: promoted mode coverage drift")
            owner = {"kind": "implementation", "issues": [143]}
        else:
            expected_terminal.add(case)
            require(case in terminal, f"{case}: missing terminal execution")
            disposition = entry["terminal_disposition"]
            category = disposition["category"]
            terminal_result = (
                "intentional-incompatibility"
                if category == "intentionally-incompatible"
                else "terminal-private-premise"
            )
            for mode in modes:
                measured = terminal[case][mode]
                executions[mode] = {
                    "expected_result": measured["expected_status"],
                    "ms": measured["ms"],
                    "observed_result": measured["observed_status"],
                    "result": terminal_result,
                }
            owner = {
                "kind": "terminal-disposition",
                "issues": disposition["owner_issues"],
            }
        record: dict[str, object] = {
            "case": case,
            "execution_state": entry["execution_state"],
            "executions": executions,
            "owner": owner,
            "path": entry["path"],
            "sha256": entry["sha256"],
        }
        if entry.get("terminal_premises"):
            record["terminal_premises"] = entry["terminal_premises"]
        if entry["execution_state"] == "terminal-disposition":
            disposition = entry["terminal_disposition"]
            record["terminal_disposition"] = {
                "category": disposition["category"],
                "premise": disposition["premise"],
                "zig_js_contract": disposition["zig_js_contract"],
            }
        cases.append(record)

    require(set(serialized) == expected_serialized, "serialized inventory has missing or extra cases")
    require(set(nogil) == expected_nogil, "no-GIL inventory has missing or extra cases")
    require(set(terminal) == expected_terminal, "terminal scan has missing or extra cases")

    helper_records = [
        {
            "case": entry["case"],
            "execution_state": "helper/preload",
            "path": entry["path"],
            "sha256": entry["sha256"],
        }
        for entry in sorted(helpers, key=lambda item: item["case"])
    ]
    return {
        "schema_version": 1,
        "source": {
            "measured_commit": commit,
            "reference_head": reference["source"]["head"],
            "reference_pull_request": reference["source"]["pull_request"],
            "reference_repository": reference["source"]["repository"],
        },
        "summary": {
            "blocked": 0,
            "executable": len(cases),
            "helper_preload": len(helper_records),
            "parallel_js_required": len(expected_nogil) + len(expected_terminal),
            "promoted": sum(case["execution_state"] == "promoted" for case in cases),
            "serialized_required": len(expected_serialized) + len(expected_terminal),
            "terminal_disposition": len(expected_terminal),
        },
        "cases": cases,
        "helpers": helper_records,
    }


def validate_checked() -> None:
    checked = load(OUTPUT)
    source = checked.get("source")
    require(isinstance(source, dict), "checked terminal artifact source missing")
    commit = source.get("measured_commit")
    require(isinstance(commit, str), "checked terminal artifact measured_commit missing")
    generated = build_artifact(commit)
    require(checked == generated, "checked terminal artifact is stale")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generate", action="store_true", help=f"write {OUTPUT.relative_to(REPO)}")
    parser.add_argument("--check", action="store_true", help="verify the checked terminal artifact")
    parser.add_argument("--commit", help="full measured source commit for --generate")
    args = parser.parse_args(argv)
    if args.generate == args.check:
        parser.error("choose exactly one of --generate or --check")
    try:
        if args.generate:
            if args.commit is None:
                parser.error("--generate requires --commit")
            artifact = build_artifact(args.commit)
            OUTPUT.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
            print(
                "PR-249 terminal artifact written: "
                f"{artifact['summary']['executable']} executable, "
                f"{artifact['summary']['promoted']} promoted, "
                f"{artifact['summary']['terminal_disposition']} terminal"
            )
        else:
            validate_checked()
            print("PR-249 terminal execution artifact verified")
    except ArtifactError as exc:
        print(f"pr249-terminal-execution: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
