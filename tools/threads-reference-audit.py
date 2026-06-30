#!/usr/bin/env python3
"""Audit non-promoted WebKit PR-249 thread corpus files.

The green allowlist is the authoritative executable corpus. This helper keeps
the remaining reference-only set honest by requiring every non-helper JS file
outside the allowlist to have an explicit blocker category.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
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

PROMOTION_PROBES = (
    "cve/mc-df-arraycopy-relabel.js",
    "cve/mc-life-creator-thread-dies.js",
    "dw2-marklistset-storm.js",
    "w16-c1-prevent-collection.js",
    "semantics/oom-one-thread.js",
    "semantics/stack-overflow-per-thread.js",
)


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

    if case == "semantics/stack-overflow-per-thread.js":
        categories.append("deep recursion / VM stack")

    if case == "semantics/oom-one-thread.js":
        categories.append("heap cap / per-thread OOM")

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
    print(f"PR-249 allowlist: {len(load_allowlist())}/{len(all_cases()) - helpers} executable files")
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
    print(f"- Allowlist: `{len(load_allowlist())}/{len(all_cases()) - helpers}` executable PR-249 files.")
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

    for case in PROMOTION_PROBES:
        cats = classified.get(case) or uncategorized.get(case)
        if cats is None:
            continue
        reason = ", ".join(cats) if cats else "uncategorized"
        command = f"zig build threads-test -Dthreads-case={case}"
        if markdown:
            print(f"- `{case}`: {reason}. Probe with `{command}`.")
        else:
            print(f"  - {case}: {reason}")
            print(f"    {command}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "markdown"), default="text")
    parser.add_argument("--fail-on-uncategorized", action="store_true")
    parser.add_argument(
        "--probe-candidates",
        action="store_true",
        help="Also print the reference-only files closest to allowlist promotion and their focused run commands.",
    )
    args = parser.parse_args(argv)

    remaining, classified, uncategorized, missing_allowlist = audit()
    if args.format == "markdown":
        print_markdown(remaining, classified, uncategorized, missing_allowlist)
    else:
        print_text(remaining, classified, uncategorized, missing_allowlist)
    if args.probe_candidates:
        print_probe_candidates(classified, uncategorized, markdown=args.format == "markdown")

    if missing_allowlist:
        return 1
    if args.fail_on_uncategorized and uncategorized:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
