#!/usr/bin/env python3
"""Audit non-promoted WebKit PR-249 thread corpus files.

The green allowlists are the authoritative executable corpus: the default
allowlist plus any parallel_js-only witnesses. This helper keeps the remaining
reference-only set honest by requiring every non-helper JS file outside that
promoted coverage to have an explicit blocker category.
"""

from __future__ import annotations

import argparse
import copy
import difflib
import hashlib
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
REFERENCE_ROOT = REPO / "reference" / "webkit-249"
RUNNER = REPO / "conformance" / "threads_test.zig"
INVENTORY = REPO / "docs" / ".data" / "pr249-reference-inventory.json"
SOURCE_HEAD = "3a14f2a821ac56fcb01d1c765200be7e9dfdb458"

HELPERS = {
    "harness.js",
    "bench/harness.js",
    "scaling/harness.js",
    "resources/assert.js",
    "vmstate/resources/workload.js",
}

EXPLICIT_CASE_CATEGORIES = {
    "api/wasm-refused-sd7.js": (
        "JSC-specific spawned-thread WebAssembly refusal contract",
        "zig-js intentionally supports WebAssembly in shared-realm Threads",
    ),
    "cve/mc-df-arraycopy-relabel.js": (
        "JSC butterfly verification shell option",
        "typed-array set source-length snapshot covered by zig-js witnesses",
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
}

PROMOTION_PROBES = (
    "cve/mc-df-arraycopy-relabel.js",
    "cve/mc-life-creator-thread-dies.js",
    "dw2-marklistset-storm.js",
    "w16-c1-prevent-collection.js",
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
}


EXPECTED_REFERENCE_ONLY_PASSES = {
    "congc-t2-lockorder-lint.js": (
        "$vm.sharedHeapTest-gated JSC lock-order harness; zig-js only reaches "
        "the trailing arithmetic sanity check."
    ),
    "congc-t8-stop-interleaving.js": (
        "$vm shared-GC / haveABadTime arms are JSC-shell hooks and are not "
        "portable to zig-js."
    ),
    "cve/mc-aint-poll-resume-stale-elided.js": (
        "GIL-mode premise skip; the post-UNGIL JSC DFG poll-resume hook is not "
        "exposed by zig-js."
    ),
}

DEPENDENCY_CATALOG = {
    "buffer-lifetime": {
        "description": "Resizable, transferred, and creator-owned buffer lifetime under concurrent access",
        "owner_issues": [143],
    },
    "cross-realm-weak-gc": {
        "description": "Cross-realm weak registries during concurrent pruning",
        "owner_issues": [145],
    },
    "jit-artifact-lifetime": {
        "description": "Optimized code, call-link records, retirement epochs, and jettison",
        "owner_issues": [146],
    },
    "jit-trap-polling": {
        "description": "Optimized-tier trap polling, invalidation, and resume",
        "owner_issues": [146],
    },
    "jsc-butterfly-verifier": {
        "description": "JSC-private butterfly verification and indexing-mode invariants",
        "owner_issues": [143, 146],
    },
    "jsc-heap-snapshot": {
        "description": "JSC-private heap snapshot and preventCollection controls",
        "owner_issues": [143, 144],
    },
    "jsc-mark-list": {
        "description": "JSC-private shared-GC mark-list storage and shell controls",
        "owner_issues": [143, 144],
    },
    "jsc-shared-heap-shell": {
        "description": "JSC $vm sharedHeapTest and shared-heap diagnostic controls",
        "owner_issues": [143, 145],
    },
    "jsc-spawned-thread-wasm-refusal": {
        "description": "JSC-specific refusal of WebAssembly on spawned shared-realm threads",
        "owner_issues": [143],
        "resolution": "explicitly-incompatible: zig-js supports WebAssembly in shared-realm threads",
    },
    "optimizing-jit": {
        "description": "DFG/FTL-style profiling, speculation, invalidation, and tier evidence",
        "owner_issues": [146],
    },
    "shared-concurrent-gc": {
        "description": "Concurrent shared-heap collection, stop coordination, and diagnostics",
        "owner_issues": [145],
    },
    "typed-array-race-semantics": {
        "description": "TypedArray copy and detached-view race semantics",
        "owner_issues": [143],
    },
    "wasm-shared-memory-lifetime": {
        "description": "WebAssembly memory growth and backing-store lifetime during concurrent access",
        "owner_issues": [265, 287],
    },
}

REFERENCE_ONLY_DEPENDENCIES = {
    "api/wasm-refused-sd7.js": ("jsc-spawned-thread-wasm-refusal",),
    "checktraps-invalidation.js": ("jit-trap-polling", "optimizing-jit"),
    "congc-t11-diagnostics.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "congc-t2-lockorder-lint.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "congc-t3-barrier-storm.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "congc-t4-alloc-steal-storm.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "congc-t5-celllock-audit.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "congc-t8-stop-interleaving.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "congc-t9-attach-exit-churn.js": ("jsc-shared-heap-shell", "shared-concurrent-gc"),
    "cve/mc-aint-poll-resume-stale-elided.js": (
        "jit-trap-polling",
        "jsc-shared-heap-shell",
        "optimizing-jit",
    ),
    "cve/mc-code-calllink-writer-writer.js": (
        "jit-artifact-lifetime",
        "jsc-shared-heap-shell",
        "optimizing-jit",
    ),
    "cve/mc-df-arraycopy-relabel.js": (
        "jsc-butterfly-verifier",
        "typed-array-race-semantics",
    ),
    "cve/mc-dos-retired-artifact-churn.js": ("jit-artifact-lifetime", "optimizing-jit"),
    "cve/mc-gc-weakgcmap-registry-vs-prune.js": (
        "cross-realm-weak-gc",
        "shared-concurrent-gc",
    ),
    "cve/mc-grow-buffer-storm.js": ("buffer-lifetime", "wasm-shared-memory-lifetime"),
    "cve/mc-jit-stale-base-grow-oob.js": ("jsc-butterfly-verifier", "optimizing-jit"),
    "cve/mc-life-creator-thread-dies.js": ("buffer-lifetime",),
    "cve/mc-safe-gcwait-vs-classa-stop-noropevariant.js": (
        "optimizing-jit",
        "shared-concurrent-gc",
    ),
    "cve/mc-safe-gcwait-vs-classa-stop.js": ("optimizing-jit", "shared-concurrent-gc"),
    "cve/mc-val-fire-vs-link.js": ("optimizing-jit",),
    "dw2-marklistset-storm.js": ("jsc-mark-list",),
    "jit/foreign-reify-getbyid-converges.js": ("optimizing-jit",),
    "jit/ic-publish-reset-loops.js": (
        "jsc-shared-heap-shell",
        "optimizing-jit",
    ),
    "w16-c1-prevent-collection.js": ("jsc-heap-snapshot",),
}

SHELL_GLOBAL_HOOKS = (
    "MemoryFootprint",
    "drainMicrotasks",
    "fullGC",
    "gc",
    "generateHeapSnapshot",
    "generateHeapSnapshotForGCDebugging",
    "jscOptions",
    "load",
    "noInline",
    "numberOfDFGCompiles",
    "preciseTime",
    "print",
    "quit",
    "transferArrayBuffer",
)


def probe_command(case: str) -> list[str]:
    return [
        "zig",
        "build",
        "threads-test",
        f"-Dthreads-case={case}",
    ]


def load_allowlist() -> set[str]:
    src = RUNNER.read_text()
    before_helpers = src.split("fn runsWithoutThreadGlobal", 1)[0]
    return set(re.findall(r'"([^"]+\.js)"', before_helpers))


def all_cases() -> list[str]:
    return sorted(
        str(path.relative_to(CORPUS))
        for path in CORPUS.rglob("*.js")
    )


def artifact_kind(path: Path) -> str:
    if path.suffix == ".js":
        return "javascript"
    if path.name.endswith(".js.skip"):
        return "disabled-javascript"
    if path.suffix == ".md":
        return "documentation"
    if path.suffix == ".sh":
        return "shell"
    if path.suffix in {".yaml", ".yml"}:
        return "manifest"
    return "other"


def required_shell_hooks(src: str) -> list[str]:
    hooks: set[str] = set()
    for annotation in re.findall(r"requireOptions\(([^)]*)\)", src):
        for option in re.findall(r'"(--[^"]+)"', annotation):
            hooks.add(f"option:{option}")

    code = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    code = re.sub(r"//[^\n]*", "", code)
    for method in re.findall(r"\$vm\.([A-Za-z_$][A-Za-z0-9_$]*)", code):
        hooks.add(f"$vm.{method}")
    for name in SHELL_GLOBAL_HOOKS:
        if re.search(rf"(?<![.\w$]){re.escape(name)}\s*\(", code):
            hooks.add(f"global:{name}")
    return sorted(hooks)


def reference_files() -> list[Path]:
    return sorted(
        (path for path in REFERENCE_ROOT.rglob("*") if path.is_file()),
        key=lambda path: str(path.relative_to(REFERENCE_ROOT)),
    )


def build_reference_inventory() -> dict[str, object]:
    source_readme = (REFERENCE_ROOT / "README.md").read_text()
    if f"Head SHA: `{SOURCE_HEAD}`" not in source_readme:
        raise ValueError("vendored reference README does not declare SOURCE_HEAD")
    remaining, _, uncategorized, missing_allowlist = audit()
    if uncategorized:
        raise ValueError(f"uncategorized reference-only cases: {sorted(uncategorized)}")
    if missing_allowlist:
        raise ValueError(f"allowlist paths missing from corpus: {missing_allowlist}")

    allowlist = load_allowlist()
    remaining_set = set(remaining)
    reference_executable = remaining_set - HELPERS
    disposition_set = set(REFERENCE_ONLY_DEPENDENCIES)
    if reference_executable != disposition_set:
        missing = sorted(reference_executable - disposition_set)
        stale = sorted(disposition_set - reference_executable)
        raise ValueError(
            f"reference-only disposition drift: missing={missing}, stale={stale}"
        )

    entries: list[dict[str, object]] = []
    state_counts = defaultdict(int)
    kind_counts = defaultdict(int)
    for path in reference_files():
        rel = str(path.relative_to(REFERENCE_ROOT))
        data = path.read_bytes()
        kind = artifact_kind(path)
        kind_counts[kind] += 1
        entry: dict[str, object] = {
            "path": rel,
            "kind": kind,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        if path.suffix == ".js":
            if not rel.startswith("threads-tests/"):
                raise ValueError(f"JavaScript outside threads-tests: {rel}")
            case = rel.removeprefix("threads-tests/")
            if case in HELPERS:
                state = "helper/preload"
            elif case in allowlist:
                state = "promoted"
            elif case in reference_executable:
                state = "reference-only"
            else:
                raise ValueError(f"unowned JavaScript case: {case}")
            state_counts[state] += 1
            entry["case"] = case
            entry["execution_state"] = state
            entry["required_shell_hooks"] = required_shell_hooks(
                data.decode(errors="replace")
            )
            if state == "reference-only":
                dependencies = list(REFERENCE_ONLY_DEPENDENCIES[case])
                entry["dependencies"] = dependencies
                entry["owner_issues"] = sorted({
                    issue
                    for dependency in dependencies
                    for issue in DEPENDENCY_CATALOG[dependency]["owner_issues"]
                })
        entries.append(entry)

    executable_total = state_counts["promoted"] + state_counts["reference-only"]
    return {
        "schema_version": 1,
        "source": {
            "repository": "https://github.com/oven-sh/WebKit",
            "pull_request": 249,
            "head": SOURCE_HEAD,
        },
        "dependency_catalog": {
            key: DEPENDENCY_CATALOG[key] for key in sorted(DEPENDENCY_CATALOG)
        },
        "summary": {
            "files": len(entries),
            "artifact_kinds": dict(sorted(kind_counts.items())),
            "javascript": sum(state_counts.values()),
            "executable": executable_total,
            "promoted": state_counts["promoted"],
            "reference_only": state_counts["reference-only"],
            "helper_preload": state_counts["helper/preload"],
        },
        "files": entries,
    }


def validate_reference_inventory(inventory: dict[str, object]) -> list[str]:
    errors: list[str] = []
    files = inventory.get("files")
    if not isinstance(files, list):
        return ["files must be an array"]
    paths = [entry.get("path") for entry in files if isinstance(entry, dict)]
    if len(paths) != len(files) or any(not isinstance(path, str) for path in paths):
        errors.append("every file entry must have a string path")
        return errors
    if paths != sorted(paths):
        errors.append("file entries are not path-sorted")
    if len(paths) != len(set(paths)):
        errors.append("file paths are not unique")

    dependency_catalog = inventory.get("dependency_catalog")
    if not isinstance(dependency_catalog, dict):
        errors.append("dependency_catalog must be an object")
        dependency_catalog = {}
    referenced_dependencies: set[str] = set()
    states = defaultdict(int)
    for entry in files:
        if not isinstance(entry, dict):
            errors.append("file entry must be an object")
            continue
        path = entry.get("path", "<missing>")
        digest = entry.get("sha256")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            errors.append(f"{path}: invalid sha256")
        if entry.get("kind") != "javascript":
            continue
        state = entry.get("execution_state")
        states[state] += 1
        dependencies = entry.get("dependencies", [])
        owners = entry.get("owner_issues", [])
        if state == "reference-only":
            if not isinstance(dependencies, list) or not dependencies:
                errors.append(f"{path}: reference-only case lacks dependencies")
                continue
            if not isinstance(owners, list) or not owners:
                errors.append(f"{path}: reference-only case lacks owner issues")
            for dependency in dependencies:
                if dependency not in dependency_catalog:
                    errors.append(f"{path}: unknown dependency {dependency!r}")
                else:
                    referenced_dependencies.add(dependency)
        elif dependencies or owners:
            errors.append(f"{path}: non-reference case has a stale disposition")
        if state not in {"promoted", "reference-only", "helper/preload"}:
            errors.append(f"{path}: invalid execution_state {state!r}")
        hooks = entry.get("required_shell_hooks")
        if not isinstance(hooks, list) or hooks != sorted(set(hooks)):
            errors.append(f"{path}: required_shell_hooks must be sorted and unique")

    stale_dependencies = sorted(set(dependency_catalog) - referenced_dependencies)
    if stale_dependencies:
        errors.append(f"unreferenced dependency catalog entries: {stale_dependencies}")

    summary = inventory.get("summary")
    if not isinstance(summary, dict):
        errors.append("summary must be an object")
    else:
        expected = {
            "files": len(files),
            "javascript": sum(states.values()),
            "executable": states["promoted"] + states["reference-only"],
            "promoted": states["promoted"],
            "reference_only": states["reference-only"],
            "helper_preload": states["helper/preload"],
        }
        for key, value in expected.items():
            if summary.get(key) != value:
                errors.append(
                    f"summary.{key}: expected {value}, found {summary.get(key)!r}"
                )
    source = inventory.get("source")
    if not isinstance(source, dict) or source.get("head") != SOURCE_HEAD:
        errors.append(f"source.head must be {SOURCE_HEAD}")
    return errors


def inventory_text(inventory: dict[str, object]) -> str:
    return json.dumps(inventory, indent=2, sort_keys=True) + "\n"


def inventory_diff(
    checked_in: dict[str, object],
    generated: dict[str, object],
) -> list[str]:
    return list(difflib.unified_diff(
        inventory_text(checked_in).splitlines(),
        inventory_text(generated).splitlines(),
        fromfile=str(INVENTORY.relative_to(REPO)),
        tofile="generated inventory",
        lineterm="",
    ))


def check_reference_inventory(*, emit: bool) -> bool:
    generated = build_reference_inventory()
    generated_errors = validate_reference_inventory(generated)
    if generated_errors:
        if emit:
            print("generated PR-249 inventory is invalid:")
            for error in generated_errors:
                print(f"  - {error}")
        return False
    try:
        checked_in = json.loads(INVENTORY.read_text())
    except (OSError, json.JSONDecodeError) as error:
        if emit:
            print(f"cannot read {INVENTORY.relative_to(REPO)}: {error}")
        return False
    checked_errors = validate_reference_inventory(checked_in)
    diff = inventory_diff(checked_in, generated)
    if checked_errors or diff:
        if emit:
            if checked_errors:
                print("checked-in PR-249 inventory is invalid:")
                for error in checked_errors:
                    print(f"  - {error}")
            if diff:
                print("checked-in PR-249 inventory is stale:")
                for line in diff[:120]:
                    print(line)
                if len(diff) > 120:
                    print(f"... {len(diff) - 120} more diff lines")
        return False
    if emit:
        summary = generated["summary"]
        print(
            "PR-249 inventory verified: "
            f"{summary['files']} files, {summary['executable']} executable "
            f"({summary['promoted']} promoted, "
            f"{summary['reference_only']} reference-only), "
            f"{summary['helper_preload']} helpers"
        )
    return True


def self_test_reference_inventory(*, emit: bool) -> bool:
    generated = build_reference_inventory()
    cases: list[tuple[str, dict[str, object], bool]] = []

    addition = copy.deepcopy(generated)
    addition["files"].append({
        "path": "threads-tests/zz-inventory-addition.js",
        "kind": "javascript",
        "bytes": 0,
        "sha256": "0" * 64,
        "case": "zz-inventory-addition.js",
        "execution_state": "promoted",
        "required_shell_hooks": [],
    })
    cases.append(("addition", addition, True))

    deletion = copy.deepcopy(generated)
    deletion["files"].pop()
    cases.append(("deletion", deletion, True))

    checksum = copy.deepcopy(generated)
    checksum["files"][0]["sha256"] = "0" * 64
    cases.append(("checksum drift", checksum, True))

    allowlist = copy.deepcopy(generated)
    promoted = next(
        entry for entry in allowlist["files"]
        if entry.get("execution_state") == "promoted"
    )
    promoted["execution_state"] = "reference-only"
    cases.append(("allowlist movement", allowlist, True))

    missing = copy.deepcopy(generated)
    reference = next(
        entry for entry in missing["files"]
        if entry.get("execution_state") == "reference-only"
    )
    reference.pop("dependencies")
    cases.append(("missing disposition", missing, True))

    stale = copy.deepcopy(generated)
    promoted = next(
        entry for entry in stale["files"]
        if entry.get("execution_state") == "promoted"
    )
    promoted["dependencies"] = ["optimizing-jit"]
    promoted["owner_issues"] = [146]
    cases.append(("stale disposition", stale, True))

    failures: list[str] = []
    for name, mutated, should_fail in cases:
        detected = bool(
            validate_reference_inventory(mutated)
            or inventory_diff(mutated, generated)
        )
        if detected != should_fail:
            failures.append(name)
    if emit:
        if failures:
            print(f"PR-249 inventory self-tests failed: {', '.join(failures)}")
        else:
            print(f"PR-249 inventory self-tests: {len(cases)}/{len(cases)} passed")
    return not failures


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
            "command": probe_command(case),
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
        "expected_reference_only_passes": EXPECTED_REFERENCE_ONLY_PASSES,
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
        cmd = [*probe_command(case), "--summary", "all"]
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


def run_reference_only_scan(
    remaining: list[str],
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    *,
    timeout_s: float,
    emit: bool = True,
) -> tuple[int, list[dict[str, object]]]:
    """Run all reference-only executables and fail on surprising passes."""

    if emit:
        print()
        print(f"scanning reference-only executables (timeout {timeout_s:g}s each):")

    unexpected_passes = 0
    results: list[dict[str, object]] = []
    for case in sorted(remaining):
        if case in HELPERS:
            continue

        cats = classified.get(case) or uncategorized.get(case) or []
        reason = ", ".join(cats) if cats else "uncategorized"
        if emit:
            print(f"  - {case}: {reason}")

        run_status, returncode, output = run_probe_command(
            [*probe_command(case), "--summary", "all"],
            timeout_s,
        )
        output_summary = probe_output_summary(output)
        if run_status == "timeout":
            if emit:
                print("    TIMEOUT")
                if output:
                    print_probe_output_tail(output)
            results.append({
                "case": case,
                "status": "timeout",
                "exit_code": None,
                "categories": cats,
                "output": output_summary,
            })
            continue

        if returncode == 0:
            expected_pass_reason = EXPECTED_REFERENCE_ONLY_PASSES.get(case)
            if expected_pass_reason is None:
                unexpected_passes += 1
                status = "pass"
                if emit:
                    print("    UNEXPECTED PASS: promote or reclassify this file")
            else:
                status = "expected-reference-only-pass"
                if emit:
                    print(f"    expected reference-only pass: {expected_pass_reason}")
            results.append({
                "case": case,
                "status": status,
                "exit_code": returncode,
                "categories": cats,
                "expected_reference_only_pass": expected_pass_reason,
                "output": output_summary,
            })
        else:
            if emit:
                print(f"    expected non-promotion evidence exit={returncode}")
                print_probe_output_tail(output)
            results.append({
                "case": case,
                "status": "fail",
                "exit_code": returncode,
                "categories": cats,
                "output": output_summary,
            })

    return unexpected_passes, results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=("text", "markdown", "json"), default="text")
    parser.add_argument("--fail-on-uncategorized", action="store_true")
    parser.add_argument(
        "--print-inventory",
        action="store_true",
        help="Print the deterministic complete PR-249 reference inventory as JSON.",
    )
    parser.add_argument(
        "--check-inventory",
        action="store_true",
        help="Require the checked-in complete inventory to match the vendored tree and dispositions.",
    )
    parser.add_argument(
        "--self-test-inventory",
        action="store_true",
        help="Run focused inventory drift-detector tests without compiling the engine.",
    )
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
    parser.add_argument(
        "--scan-reference-only",
        action="store_true",
        help=(
            "Run every reference-only executable file and return nonzero if any passes. "
            "This slower opt-in sweep catches stale blockers that should be promoted."
        ),
    )
    args = parser.parse_args(argv)

    if args.print_inventory:
        generated = build_reference_inventory()
        errors = validate_reference_inventory(generated)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print(inventory_text(generated), end="")
        return 0

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
    scan_failures = 0
    scan_results: list[dict[str, object]] = []
    if args.scan_reference_only:
        scan_failures, scan_results = run_reference_only_scan(
            remaining,
            classified,
            uncategorized,
            timeout_s=args.probe_timeout,
            emit=args.format != "json",
        )
    inventory_ok = True
    if args.check_inventory:
        inventory_ok = check_reference_inventory(emit=args.format != "json")
    inventory_self_test_ok = True
    if args.self_test_inventory:
        inventory_self_test_ok = self_test_reference_inventory(
            emit=args.format != "json"
        )
    if args.format == "json":
        summary = audit_json_summary(remaining, classified, uncategorized, missing_allowlist)
        if args.run_probes:
            summary["probe_results"] = probe_results
            summary["probe_failures"] = probe_failures
        if args.scan_reference_only:
            summary["reference_only_scan_results"] = scan_results
            summary["reference_only_scan_unexpected_passes"] = scan_failures
        if args.check_inventory:
            summary["inventory_matches"] = inventory_ok
        if args.self_test_inventory:
            summary["inventory_self_tests_pass"] = inventory_self_test_ok
        print(json.dumps(summary, indent=2, sort_keys=True))

    if missing_allowlist:
        return 1
    if args.fail_on_uncategorized and uncategorized:
        return 1
    if args.run_probes and probe_failures:
        return 1
    if args.scan_reference_only and scan_failures:
        return 1
    if not inventory_ok or not inventory_self_test_ok:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
