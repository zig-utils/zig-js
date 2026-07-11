#!/usr/bin/env python3
"""Audit non-promoted WebKit PR-249 thread corpus files.

The green allowlists are the authoritative executable corpus: the default
allowlist plus any parallel_js-only witnesses. This helper keeps the remaining
reference-only set honest by requiring every non-helper JS file outside that
promoted coverage to have an explicit blocker category.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CORPUS = REPO / "reference" / "webkit-249" / "threads-tests"
RUNNER = REPO / "conformance" / "threads_test.zig"

HELPERS = {
    "harness.js",
    "bench/harness.js",
    "scaling/harness.js",
    "resources/assert.js",
    "vmstate/resources/workload.js",
}

EXPLICIT_CASE_CATEGORIES = {
    "cve/mc-df-arraycopy-relabel.js": (
        "JSC butterfly verification shell option",
        "typed-array set length race semantics",
    ),
    "cve/mc-life-creator-thread-dies.js": (
        "detached ArrayBuffer fresh-view construction race",
        "portable creator-owned buffer survival already covered",
    ),
    "dw2-marklistset-storm.js": (
        "JSC shared-GC mark-list hooks",
    ),
    "w16-c1-prevent-collection.js": (
        "JSC heap snapshot/preventCollection hooks",
    ),
    "semantics/oom-one-thread.js": (
        "allocation-site catchable OOM",
    ),
}

PROMOTION_PROBES = (
    "cve/mc-df-arraycopy-relabel.js",
    "cve/mc-life-creator-thread-dies.js",
    "dw2-marklistset-storm.js",
    "w16-c1-prevent-collection.js",
    "semantics/oom-one-thread.js",
)


@dataclass(frozen=True)
class ProbeExpectation:
    status: str
    evidence: tuple[str, ...] = ()


PROMOTION_PROBE_EXPECTATIONS = {
    "cve/mc-df-arraycopy-relabel.js": ProbeExpectation(
        "fail",
        ("RangeError: offset is out of bounds",),
    ),
    "cve/mc-life-creator-thread-dies.js": ProbeExpectation(
        "fail",
        ("TypeError: Cannot construct a TypedArray on a detached buffer",),
    ),
    "dw2-marklistset-storm.js": ProbeExpectation("timeout"),
    "w16-c1-prevent-collection.js": ProbeExpectation("timeout"),
    "semantics/oom-one-thread.js": ProbeExpectation(
        "fail",
        ("OutOfMemoryError: Context heap limit exceeded",),
    ),
}


def load_allowlist() -> set[str]:
    src = RUNNER.read_text()
    before_helpers = src.split("fn runsWithoutThreadGlobal", 1)[0]
    return set(re.findall(r'"([^"]+\.js)"', before_helpers))


def all_cases() -> list[str]:
    return sorted(
        str(path.relative_to(CORPUS))
        for path in CORPUS.rglob("*.js")
    )


def classify(case: str, src: str) -> list[str]:
    categories: list[str] = []
    path = Path(case)

    if case in HELPERS:
        return ["helper/preload"]

    if case in EXPLICIT_CASE_CATEGORIES:
        return list(EXPLICIT_CASE_CATEGORIES[case])

    if case.startswith("checktraps-") or "checkTraps" in src or "haveBadTime" in src:
        categories.append("checktraps / haveBadTime shell controls")

    lower = case.lower() + "\n" + src.lower()
    if "webassembly" in src or "wasm" in lower:
        categories.append("WebAssembly construction/grow/relocation")

    if (
        case.startswith("jit/")
        or "/mc-jit-" in f"/{case}"
        or "jit" in lower
        or "disassembly" in lower
        or "retired-artifact" in lower
    ):
        categories.append("JIT/code-artifact hooks")

    if "$vm" in src or "sharedHeapTest" in src:
        categories.append("$vm shared-heap/shell hooks")

    if case == "cve/mc-spec-timer-capability.js":
        categories.append("SAB-off/timer shell capability")

    if "requireOptions" in src and not categories:
        categories.append("unsupported shell option")

    if path.parts and path.parts[0] == "cve" and not categories:
        categories.append("CVE witness awaiting matching engine feature")

    return categories


def audit() -> tuple[list[str], dict[str, list[str]], dict[str, list[str]], list[str]]:
    allowlist = load_allowlist()
    cases = all_cases()
    case_set = set(cases)
    missing_allowlist = sorted(case for case in allowlist if case not in case_set)
    remaining = [case for case in cases if case not in allowlist]
    classified: dict[str, list[str]] = {}
    uncategorized: dict[str, list[str]] = {}

    for case in remaining:
        src = (CORPUS / case).read_text(errors="replace")
        cats = classify(case, src)
        if cats:
            classified[case] = cats
        else:
            uncategorized[case] = []

    return remaining, classified, uncategorized, missing_allowlist


def print_text(
    remaining: list[str],
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    missing_allowlist: list[str],
) -> None:
    by_category: dict[str, list[str]] = defaultdict(list)
    for case, cats in classified.items():
        for cat in cats:
            by_category[cat].append(case)

    helpers = sum(1 for case in remaining if case in HELPERS)
    executable = len(remaining) - helpers
    print(f"PR-249 promoted coverage: {len(load_allowlist())}/{len(all_cases()) - helpers} executable files")
    print(f"reference-only: {len(remaining)} total ({executable} executable, {helpers} helper/preload)")
    print()
    for cat in sorted(by_category):
        cases = by_category[cat]
        print(f"{cat}: {len(cases)}")
        for case in cases:
            print(f"  - {case}")
        print()
    if uncategorized:
        print("uncategorized:")
        for case in sorted(uncategorized):
            print(f"  - {case}")
    if missing_allowlist:
        print("missing allowlist entries:")
        for case in missing_allowlist:
            print(f"  - {case}")


def print_markdown(
    remaining: list[str],
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    missing_allowlist: list[str],
) -> None:
    helpers = sum(1 for case in remaining if case in HELPERS)
    executable = len(remaining) - helpers
    print(f"- Promoted coverage: `{len(load_allowlist())}/{len(all_cases()) - helpers}` executable PR-249 files.")
    print(f"- Reference-only: `{executable}` executable files plus `{helpers}` helper/preload files.")
    print()
    for case in sorted(classified):
        print(f"- `{case}`: {', '.join(classified[case])}.")
    if uncategorized:
        print()
        print("Uncategorized:")
        for case in sorted(uncategorized):
            print(f"- `{case}`")
    if missing_allowlist:
        print()
        print("Missing allowlist entries:")
        for case in missing_allowlist:
            print(f"- `{case}`")


def probe_candidates(
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
) -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    for case in PROMOTION_PROBES:
        cats = classified.get(case) or uncategorized.get(case)
        if cats is None:
            continue
        expected = PROMOTION_PROBE_EXPECTATIONS.get(case)
        candidates.append({
            "case": case,
            "categories": cats,
            "command": [
                "zig",
                "build",
                "threads-test",
                f"-Dthreads-case={case}",
            ],
            "expected_current_blocker": None if expected is None else {
                "status": expected.status,
                "evidence": list(expected.evidence),
            },
        })
    return candidates


def audit_json_summary(
    remaining: list[str],
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    missing_allowlist: list[str],
) -> dict[str, object]:
    by_category: dict[str, list[str]] = defaultdict(list)
    for case, cats in classified.items():
        for cat in cats:
            by_category[cat].append(case)

    helpers = sum(1 for case in remaining if case in HELPERS)
    executable_total = len(all_cases()) - helpers
    executable_passed = len(load_allowlist())
    reference_executable = len(remaining) - helpers
    return {
        "promoted_executable": executable_passed,
        "executable_total": executable_total,
        "reference_only_executable": reference_executable,
        "helper_preload": helpers,
        "allowlist": {
            "executable_passed": executable_passed,
            "executable_total": executable_total,
        },
        "reference_only": {
            "total": len(remaining),
            "executable": reference_executable,
            "helper_preload": helpers,
            "cases": remaining,
        },
        "categories": {cat: sorted(cases) for cat, cases in sorted(by_category.items())},
        "uncategorized": sorted(uncategorized),
        "missing_allowlist_entries": missing_allowlist,
        "promotion_probe_candidates": probe_candidates(classified, uncategorized),
    }


def print_probe_candidates(
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    *,
    markdown: bool,
) -> None:
    if markdown:
        print()
        print("Promotion probe candidates:")
    else:
        print()
        print("promotion probe candidates:")

    for candidate in probe_candidates(classified, uncategorized):
        case = candidate["case"]
        cats = candidate["categories"]
        reason = ", ".join(cats) if cats else "uncategorized"
        command = " ".join(candidate["command"])
        if markdown:
            print(f"- `{case}`: {reason}. Probe with `{command}`.")
        else:
            print(f"  - {case}: {reason}")
            print(f"    {command}")


def probe_evidence_lines(lines: list[str]) -> list[str]:
    evidence: list[str] = []
    for line in lines:
        stripped = line.strip()
        if re.match(r"^(PASS|FAIL|SKIP|MISS)\s+", stripped):
            evidence.append(line)
            continue
        if re.match(r"^\d+/\d+ corpus files passed$", stripped):
            evidence.append(line)
            continue
        if (
            "RangeError:" in stripped
            or "ReferenceError:" in stripped
            or "SyntaxError:" in stripped
            or "TypeError:" in stripped
            or "CorpusFailures" in stripped
        ):
            evidence.append(line)
    return evidence


def probe_output_summary(output: str | bytes) -> dict[str, list[str]]:
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    lines = [line for line in output.splitlines() if line.strip()]
    evidence = probe_evidence_lines(lines)
    return {
        "evidence": evidence[-10:],
        "tail": lines[-8:],
    }


def print_probe_output_tail(output: str | bytes, *, prefix: str = "      ") -> None:
    summary = probe_output_summary(output)
    evidence = summary["evidence"]
    if evidence:
        print(f"{prefix}runner evidence:")
        for line in evidence:
            print(f"{prefix}  {line}")
        print(f"{prefix}build tail:")
    for line in summary["tail"]:
        print(f"{prefix}{line}")


def run_probe_command(cmd: list[str], timeout_s: float) -> tuple[str, int | None, str]:
    proc = subprocess.Popen(
        cmd,
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        stdout, _ = proc.communicate(timeout=timeout_s)
        return "done", proc.returncode, stdout or ""
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, _ = proc.communicate()
        return "timeout", None, stdout or ""


def check_probe_expectation(
    case: str,
    status: str,
    output: str | bytes | None,
    *,
    emit: bool = True,
) -> bool:
    expected = PROMOTION_PROBE_EXPECTATIONS.get(case)
    if expected is None:
        return True
    if status != expected.status:
        if emit:
            print(f"    UNEXPECTED: expected {expected.status}, got {status}")
        return False
    if not expected.evidence:
        if emit:
            print("    expected blocker confirmed")
        return True
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    haystack = output or ""
    missing = [needle for needle in expected.evidence if needle not in haystack]
    if missing:
        if emit:
            print("    UNEXPECTED: missing expected blocker evidence:")
            for needle in missing:
                print(f"      - {needle}")
        return False
    if emit:
        print("    expected blocker confirmed")
    return True


def run_probe_candidates(
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    *,
    timeout_s: float,
    expect_current_blockers: bool,
    skip_timeout_probes: bool,
    emit: bool = True,
) -> tuple[int, list[dict[str, object]]]:
    if emit:
        print()
        print(f"running promotion probes (timeout {timeout_s:g}s each):")
    failures = 0
    results: list[dict[str, object]] = []
    for case in PROMOTION_PROBES:
        cats = classified.get(case) or uncategorized.get(case)
        if cats is None:
            continue
        reason = ", ".join(cats) if cats else "uncategorized"
        expected = PROMOTION_PROBE_EXPECTATIONS.get(case)
        if skip_timeout_probes and expected is not None and expected.status == "timeout":
            if emit:
                print(f"  - {case}: {reason}")
                print("    SKIP expected timeout blocker")
            results.append({
                "case": case,
                "status": "skipped",
                "skip_reason": "expected timeout blocker",
                "exit_code": None,
                "expected_current_blocker": expect_current_blockers,
                "expectation_matched": None,
                "output": {
                    "evidence": [],
                    "tail": [],
                },
            })
            continue
        cmd = [
            "zig",
            "build",
            "threads-test",
            f"-Dthreads-case={case}",
            "--summary",
            "all",
        ]
        if emit:
            print(f"  - {case}: {reason}")
        run_status, returncode, output = run_probe_command(cmd, timeout_s)
        if run_status == "timeout":
            if emit:
                print("    TIMEOUT")
            result = {
                "case": case,
                "status": "timeout",
                "exit_code": None,
                "expected_current_blocker": expect_current_blockers,
                "output": probe_output_summary(output),
            }
            if emit and output:
                print_probe_output_tail(output)
            if expect_current_blockers:
                ok = check_probe_expectation(case, "timeout", output, emit=emit)
                result["expectation_matched"] = ok
                if not ok:
                    failures += 1
            else:
                result["expectation_matched"] = None
                failures += 1
            results.append(result)
            continue
        if returncode == 0:
            if emit:
                print("    PASS")
            result = {
                "case": case,
                "status": "pass",
                "exit_code": returncode,
                "expected_current_blocker": expect_current_blockers,
                "output": probe_output_summary(output),
            }
            if expect_current_blockers:
                ok = check_probe_expectation(case, "pass", output, emit=emit)
                result["expectation_matched"] = ok
                if not ok:
                    failures += 1
            else:
                result["expectation_matched"] = None
        else:
            if emit:
                print(f"    FAIL exit={returncode}")
                print_probe_output_tail(output)
            result = {
                "case": case,
                "status": "fail",
                "exit_code": returncode,
                "expected_current_blocker": expect_current_blockers,
                "output": probe_output_summary(output),
            }
            if expect_current_blockers:
                ok = check_probe_expectation(case, "fail", output, emit=emit)
                result["expectation_matched"] = ok
                if not ok:
                    failures += 1
            else:
                result["expectation_matched"] = None
                failures += 1
        results.append(result)
    return failures, results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "markdown", "json"), default="text")
    parser.add_argument("--fail-on-uncategorized", action="store_true")
    parser.add_argument(
        "--probe-candidates",
        action="store_true",
        help="Also print the reference-only files closest to allowlist promotion and their focused run commands.",
    )
    parser.add_argument(
        "--run-probes",
        action="store_true",
        help="Run the closest promotion probes with per-case timeouts and report pass/fail/timeout evidence.",
    )
    parser.add_argument(
        "--probe-timeout",
        type=float,
        default=60.0,
        help="Timeout in seconds for each --run-probes focused case (default: 60).",
    )
    parser.add_argument(
        "--expect-current-blockers",
        action="store_true",
        help=(
            "With --run-probes, succeed only when the closest probes still fail "
            "or time out with the documented current blocker evidence."
        ),
    )
    parser.add_argument(
        "--skip-timeout-probes",
        action="store_true",
        help=(
            "With --run-probes, skip probes whose documented blocker is an expected timeout. "
            "This keeps quick evidence gates focused on probes with concrete failure text."
        ),
    )
    args = parser.parse_args(argv)

    remaining, classified, uncategorized, missing_allowlist = audit()
    if args.format == "markdown":
        print_markdown(remaining, classified, uncategorized, missing_allowlist)
    elif args.format == "json":
        pass
    else:
        print_text(remaining, classified, uncategorized, missing_allowlist)
    if args.probe_candidates and args.format != "json":
        print_probe_candidates(classified, uncategorized, markdown=args.format == "markdown")
    probe_failures = 0
    probe_results: list[dict[str, object]] = []
    if args.run_probes:
        probe_failures, probe_results = run_probe_candidates(
            classified,
            uncategorized,
            timeout_s=args.probe_timeout,
            expect_current_blockers=args.expect_current_blockers,
            skip_timeout_probes=args.skip_timeout_probes,
            emit=args.format != "json",
        )
    if args.format == "json":
        summary = audit_json_summary(remaining, classified, uncategorized, missing_allowlist)
        if args.run_probes:
            summary["probe_results"] = probe_results
            summary["probe_failures"] = probe_failures
        print(json.dumps(summary, indent=2, sort_keys=True))

    if missing_allowlist:
        return 1
    if args.fail_on_uncategorized and uncategorized:
        return 1
    if args.run_probes and probe_failures:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
