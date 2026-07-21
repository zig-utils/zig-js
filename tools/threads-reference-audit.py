#!/usr/bin/env python3
"""Audit promoted, blocked, and terminal WebKit PR-249 thread corpus files.

The green allowlists are the authoritative executable corpus: the default
allowlist plus any parallel_js-only witnesses. This helper keeps the remaining
unpromoted set honest by requiring every non-helper JS file outside that
promoted coverage to have either an implementation blocker or a structured
terminal disposition.
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
NON_JIT_RESOLUTION = REPO / "docs" / ".data" / "pr249-non-jit-resolution-2026-07-21.json"
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
        "portable snapshot graph/parse/ownership promoted by test-private-heap-snapshot",
        "JSC shared-collector preventCollection election hook has a terminal disposition",
    ),
}

DISPOSITION_PROBES = (
    "api/wasm-refused-sd7.js",
    "congc-t2-lockorder-lint.js",
    "congc-t8-stop-interleaving.js",
    "cve/mc-df-arraycopy-relabel.js",
    "cve/mc-life-creator-thread-dies.js",
)


@dataclass(frozen=True)
class ProbeExpectation:
    status: str
    evidence: tuple[str, ...] = ()


DISPOSITION_PROBE_EXPECTATIONS = {
    "api/wasm-refused-sd7.js": ProbeExpectation(
        "fail",
        ('expected "TypeError" but got "no-throw"',),
    ),
    "congc-t2-lockorder-lint.js": ProbeExpectation("pass"),
    "congc-t8-stop-interleaving.js": ProbeExpectation("pass"),
    "cve/mc-df-arraycopy-relabel.js": ProbeExpectation(
        "fail",
        ("RangeError: offset is out of bounds",),
    ),
    "cve/mc-life-creator-thread-dies.js": ProbeExpectation(
        "fail",
        ("TypeError: Cannot construct a TypedArray on a detached buffer",),
    ),
}

BLOCKED_EXPECTED_SERIALIZED_PASSES = {
    "cve/mc-aint-poll-resume-stale-elided.js": (
        "The serialized leg skips the post-UNGIL JSC optimizing-tier poll/resume arm; "
        "#429 owns real no-GIL promotion."
    ),
}


TERMINAL_DISPOSITIONS = {
    "api/wasm-refused-sd7.js": {
        "category": "intentionally-incompatible",
        "premise": "Every WebAssembly entry point must throw TypeError on a spawned shared-realm thread.",
        "zig_js_contract": "WebAssembly is intentionally available from shared-realm Thread workers.",
        "owner_issues": [428],
        "verification": {
            "default": {"status": "fail", "evidence": "expected TypeError but got no-throw"},
            "parallel_js": {"status": "fail", "evidence": "expected TypeError but got no-throw"},
        },
    },
    "congc-t2-lockorder-lint.js": {
        "category": "jsc-private-premise",
        "premise": "The meaningful arms call JSC's $vm.sharedHeapTest lock-order diagnostics.",
        "zig_js_contract": "zig-js tests its collector lock order through native stress/fault gates and does not emulate JSC internal lock classes.",
        "owner_issues": [428],
        "verification": {
            "default": {"status": "pass", "evidence": "only the trailing arithmetic sanity branch executes"},
            "parallel_js": {"status": "pass", "evidence": "only the trailing arithmetic sanity branch executes"},
        },
    },
    "congc-t8-stop-interleaving.js": {
        "category": "jsc-private-premise",
        "premise": "All collector-stop arms require JSC's $vm.sharedHeapTest dispatcher and its internal stop counters.",
        "zig_js_contract": "zig-js verifies stop/GC interleavings through maintained collector and debugger stress gates, not JSC's private dispatcher.",
        "owner_issues": [428],
        "verification": {
            "default": {"status": "pass", "evidence": "the sharedHeapTest-gated body is not entered"},
            "parallel_js": {"status": "pass", "evidence": "the sharedHeapTest-gated body is not entered"},
        },
    },
    "cve/mc-df-arraycopy-relabel.js": {
        "category": "intentionally-incompatible",
        "premise": "A racing Array growth must not be observed by TypedArray.prototype.set and JSC's butterfly verifier must be present.",
        "zig_js_contract": "The source length is snapshotted at the specified set operation point; growth before that snapshot may correctly make the copy reject with RangeError.",
        "owner_issues": [428],
        "verification": {
            "default": {"status": "fail", "evidence": "RangeError: offset is out of bounds"},
            "parallel_js": {"status": "fail", "evidence": "RangeError: offset is out of bounds"},
        },
    },
    "cve/mc-life-creator-thread-dies.js": {
        "category": "intentionally-incompatible",
        "premise": "A reader repeatedly constructs a new TypedArray from a buffer after a concurrent transfer has detached it.",
        "zig_js_contract": "Constructing any TypedArray over an already detached ArrayBuffer throws TypeError; creator-owned backing lifetime is tested separately.",
        "owner_issues": [428],
        "verification": {
            "default": {"status": "fail", "evidence": "TypeError: Cannot construct a TypedArray on a detached buffer"},
            "parallel_js": {"status": "fail", "evidence": "TypeError: Cannot construct a TypedArray on a detached buffer"},
        },
    },
    "w16-c1-prevent-collection.js": {
        "category": "jsc-private-premise",
        "premise": "The verdict requires JSC's concurrent Heap::preventCollection election through shell snapshot functions.",
        "zig_js_contract": "VM-wide heap snapshots are real and separately gated, but zig-js has no JSC preventCollection election or fake shell equivalent.",
        "owner_issues": [428],
        "verification": {
            "default": {"status": "pass", "evidence": "snapshot/preventCollection branches are unavailable"},
            "parallel_js": {"status": "pass", "evidence": "snapshot/preventCollection branches are unavailable"},
        },
    },
}


PROMOTED_TERMINAL_PREMISES = {
    case: [{
        "category": "jsc-private-branch",
        "hook": "$vm.sharedHeapTest",
        "reason": "JSC-internal diagnostic sub-arms are terminal; the maintained Thread/$vm.gc stress arm executes real zig-js behavior.",
    }]
    for case in (
        "congc-t3-barrier-storm.js",
        "congc-t4-alloc-steal-storm.js",
        "congc-t5-celllock-audit.js",
        "congc-t9-attach-exit-churn.js",
        "congc-t11-diagnostics.js",
    )
}
PROMOTED_TERMINAL_PREMISES["dw2-marklistset-storm.js"] = [{
    "category": "implementation-private-premise",
    "hook": "JSC MarkedVector/MarkListSet internals",
    "reason": "The portable sort/apply/GC root-pressure witness is maintained; zig-js does not claim JSC's private marker-container implementation.",
}]

NON_JIT_PROMOTED = {
    "congc-t3-barrier-storm.js",
    "congc-t4-alloc-steal-storm.js",
    "congc-t5-celllock-audit.js",
    "congc-t9-attach-exit-churn.js",
    "congc-t11-diagnostics.js",
    "cve/mc-gc-weakgcmap-registry-vs-prune.js",
    "cve/mc-grow-buffer-storm.js",
    "dw2-marklistset-storm.js",
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
        "owner_issues": [146, 429],
    },
    "jit-trap-polling": {
        "description": "Optimized-tier trap polling, invalidation, and resume",
        "owner_issues": [146, 429],
    },
    "jsc-butterfly-verifier": {
        "description": "JSC-private butterfly verification and indexing-mode invariants",
        "owner_issues": [143, 146, 429],
    },
    "jsc-heap-snapshot": {
        "description": "JSC-private heap snapshot and preventCollection controls",
        "owner_issues": [143, 144],
        "resolution": "terminal: portable snapshot serialization is promoted by #403; JSC's shared-collector election is implementation-private",
    },
    "jsc-mark-list": {
        "description": "JSC-private shared-GC mark-list storage and shell controls",
        "owner_issues": [143, 144],
    },
    "jsc-shared-heap-shell": {
        "description": "JSC $vm sharedHeapTest and shared-heap diagnostic controls",
        "owner_issues": [143, 145, 429],
    },
    "jsc-spawned-thread-wasm-refusal": {
        "description": "JSC-specific refusal of WebAssembly on spawned shared-realm threads",
        "owner_issues": [143],
        "resolution": "explicitly-incompatible: zig-js supports WebAssembly in shared-realm threads",
    },
    "optimizing-jit": {
        "description": "DFG/FTL-style profiling, speculation, invalidation, and tier evidence",
        "owner_issues": [146, 429],
    },
    "shared-concurrent-gc": {
        "description": "Concurrent shared-heap collection, stop coordination, and diagnostics",
        "owner_issues": [145, 429],
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

BLOCKED_DEPENDENCIES = {
    "checktraps-invalidation.js": ("jit-trap-polling", "optimizing-jit"),
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
    "cve/mc-dos-retired-artifact-churn.js": ("jit-artifact-lifetime", "optimizing-jit"),
    "cve/mc-jit-stale-base-grow-oob.js": ("jsc-butterfly-verifier", "optimizing-jit"),
    "cve/mc-safe-gcwait-vs-classa-stop-noropevariant.js": (
        "optimizing-jit",
        "shared-concurrent-gc",
    ),
    "cve/mc-safe-gcwait-vs-classa-stop.js": ("optimizing-jit", "shared-concurrent-gc"),
    "cve/mc-val-fire-vs-link.js": ("optimizing-jit",),
    "jit/foreign-reify-getbyid-converges.js": ("optimizing-jit",),
    "jit/ic-publish-reset-loops.js": (
        "jsc-shared-heap-shell",
        "optimizing-jit",
    ),
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
        str(REPO / "zig-out" / "bin" / "threads-test"),
        "one",
        case,
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
        raise ValueError(f"uncategorized unpromoted cases: {sorted(uncategorized)}")
    if missing_allowlist:
        raise ValueError(f"allowlist paths missing from corpus: {missing_allowlist}")

    allowlist = load_allowlist()
    remaining_set = set(remaining)
    unpromoted_executable = remaining_set - HELPERS
    disposition_set = set(BLOCKED_DEPENDENCIES) | set(TERMINAL_DISPOSITIONS)
    if unpromoted_executable != disposition_set:
        missing = sorted(unpromoted_executable - disposition_set)
        stale = sorted(disposition_set - unpromoted_executable)
        raise ValueError(
            f"unpromoted disposition drift: missing={missing}, stale={stale}"
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
            elif case in TERMINAL_DISPOSITIONS:
                state = "terminal-disposition"
            elif case in BLOCKED_DEPENDENCIES:
                state = "blocked"
            else:
                raise ValueError(f"unowned JavaScript case: {case}")
            state_counts[state] += 1
            entry["case"] = case
            entry["execution_state"] = state
            entry["required_shell_hooks"] = required_shell_hooks(
                data.decode(errors="replace")
            )
            if state == "blocked":
                dependencies = list(BLOCKED_DEPENDENCIES[case])
                entry["dependencies"] = dependencies
                entry["owner_issues"] = sorted({
                    issue
                    for dependency in dependencies
                    for issue in DEPENDENCY_CATALOG[dependency]["owner_issues"]
                })
            elif state == "terminal-disposition":
                entry["terminal_disposition"] = TERMINAL_DISPOSITIONS[case]
            elif case in PROMOTED_TERMINAL_PREMISES:
                entry["terminal_premises"] = PROMOTED_TERMINAL_PREMISES[case]
        entries.append(entry)

    executable_total = (
        state_counts["promoted"]
        + state_counts["blocked"]
        + state_counts["terminal-disposition"]
    )
    blocked_dependencies = {
        dependency
        for dependencies in BLOCKED_DEPENDENCIES.values()
        for dependency in dependencies
    }
    return {
        "schema_version": 2,
        "source": {
            "repository": "https://github.com/oven-sh/WebKit",
            "pull_request": 249,
            "head": SOURCE_HEAD,
        },
        "dependency_catalog": {
            key: DEPENDENCY_CATALOG[key] for key in sorted(blocked_dependencies)
        },
        "summary": {
            "files": len(entries),
            "artifact_kinds": dict(sorted(kind_counts.items())),
            "javascript": sum(state_counts.values()),
            "executable": executable_total,
            "promoted": state_counts["promoted"],
            "promoted_with_terminal_premises": len(PROMOTED_TERMINAL_PREMISES),
            "blocked": state_counts["blocked"],
            "terminal_disposition": state_counts["terminal-disposition"],
            "helper_preload": state_counts["helper/preload"],
        },
        "files": entries,
    }


def validate_reference_inventory(inventory: dict[str, object]) -> list[str]:
    errors: list[str] = []
    if inventory.get("schema_version") != 2:
        errors.append("schema_version must be 2")
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
        terminal_disposition = entry.get("terminal_disposition")
        terminal_premises = entry.get("terminal_premises", [])
        if state == "blocked":
            if not isinstance(dependencies, list) or not dependencies:
                errors.append(f"{path}: blocked case lacks dependencies")
                continue
            if not isinstance(owners, list) or not owners:
                errors.append(f"{path}: blocked case lacks owner issues")
            for dependency in dependencies:
                if dependency not in dependency_catalog:
                    errors.append(f"{path}: unknown dependency {dependency!r}")
                else:
                    referenced_dependencies.add(dependency)
            if terminal_disposition is not None or terminal_premises:
                errors.append(f"{path}: blocked case has a terminal disposition")
        elif state == "terminal-disposition":
            if dependencies or owners or terminal_premises:
                errors.append(f"{path}: terminal case has stale blocked/promoted metadata")
            if not isinstance(terminal_disposition, dict):
                errors.append(f"{path}: terminal case lacks a structured disposition")
            else:
                for field in ("category", "premise", "zig_js_contract", "owner_issues", "verification"):
                    if not terminal_disposition.get(field):
                        errors.append(f"{path}: terminal disposition lacks {field}")
        elif state == "promoted":
            if dependencies or owners or terminal_disposition is not None:
                errors.append(f"{path}: promoted case has stale disposition metadata")
            if terminal_premises:
                if not isinstance(terminal_premises, list):
                    errors.append(f"{path}: terminal_premises must be an array")
                else:
                    for premise in terminal_premises:
                        if not isinstance(premise, dict) or not all(
                            premise.get(field) for field in ("category", "hook", "reason")
                        ):
                            errors.append(f"{path}: invalid promoted terminal premise")
        elif dependencies or owners:
            errors.append(f"{path}: helper has stale disposition metadata")
        if state not in {"promoted", "blocked", "terminal-disposition", "helper/preload"}:
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
            "executable": states["promoted"] + states["blocked"] + states["terminal-disposition"],
            "promoted": states["promoted"],
            "promoted_with_terminal_premises": sum(
                1 for entry in files if isinstance(entry, dict) and entry.get("terminal_premises")
            ),
            "blocked": states["blocked"],
            "terminal_disposition": states["terminal-disposition"],
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


def validate_non_jit_resolution() -> list[str]:
    errors: list[str] = []
    try:
        evidence = json.loads(NON_JIT_RESOLUTION.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return [f"cannot read {NON_JIT_RESOLUTION.relative_to(REPO)}: {error}"]
    if evidence.get("schema_version") != 1:
        errors.append("non-JIT evidence schema_version must be 1")
    if evidence.get("issue") != 428 or evidence.get("source_head") != SOURCE_HEAD:
        errors.append("non-JIT evidence issue/source pin drift")
    cases = evidence.get("cases")
    if not isinstance(cases, list):
        return [*errors, "non-JIT evidence cases must be an array"]
    by_case = {
        entry.get("case"): entry
        for entry in cases
        if isinstance(entry, dict) and isinstance(entry.get("case"), str)
    }
    expected_cases = NON_JIT_PROMOTED | set(TERMINAL_DISPOSITIONS)
    if len(by_case) != len(cases) or set(by_case) != expected_cases:
        errors.append(
            f"non-JIT evidence case drift: expected={sorted(expected_cases)}, found={sorted(by_case)}"
        )
    allowlist = load_allowlist()
    for case in sorted(expected_cases & set(by_case)):
        entry = by_case[case]
        if case in NON_JIT_PROMOTED:
            if entry.get("resolution") != "promoted" or case not in allowlist:
                errors.append(f"{case}: promoted evidence/allowlist drift")
            for mode in ("default", "parallel_js"):
                result = entry.get(mode)
                if not isinstance(result, dict) or result.get("status") != "pass":
                    errors.append(f"{case}: {mode} must record pass")
            tsan_result = entry.get("tsan_parallel_js")
            if not isinstance(tsan_result, dict) or tsan_result.get("status") != "pass":
                errors.append(f"{case}: tsan_parallel_js must record pass")
        else:
            if entry.get("resolution") != "terminal-disposition" or case in allowlist:
                errors.append(f"{case}: terminal evidence/allowlist drift")
            expected = TERMINAL_DISPOSITIONS[case]["verification"]
            for mode in ("default", "parallel_js"):
                result = entry.get(mode)
                if not isinstance(result, dict) or result.get("status") != expected[mode]["status"]:
                    errors.append(f"{case}: {mode} terminal status drift")
    summary = evidence.get("summary")
    expected_summary = {
        "cases": len(expected_cases),
        "mode_runs": len(expected_cases) * 2,
        "promoted": len(NON_JIT_PROMOTED),
        "terminal_dispositions": len(TERMINAL_DISPOSITIONS),
        "tsan_mode_runs": len(NON_JIT_PROMOTED),
        "tsan_pass": len(NON_JIT_PROMOTED),
        "tsan_ci_debug_runs": 1,
        "tsan_ci_debug_pass": 1,
    }
    dw2 = by_case.get("dw2-marklistset-storm.js")
    if not isinstance(dw2, dict) or not isinstance(dw2.get("tsan_ci_debug"), dict) or dw2["tsan_ci_debug"].get("status") != "pass":
        errors.append("dw2-marklistset-storm.js: tsan_ci_debug must record pass")
    if not isinstance(summary, dict) or any(summary.get(key) != value for key, value in expected_summary.items()):
        errors.append(f"non-JIT evidence summary must be {expected_summary}")
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
    evidence_errors = validate_non_jit_resolution()
    diff = inventory_diff(checked_in, generated)
    if checked_errors or evidence_errors or diff:
        if emit:
            if checked_errors:
                print("checked-in PR-249 inventory is invalid:")
                for error in checked_errors:
                    print(f"  - {error}")
            if evidence_errors:
                print("checked-in PR-249 non-JIT evidence is invalid:")
                for error in evidence_errors:
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
            f"{summary['blocked']} blocked, "
            f"{summary['terminal_disposition']} terminal), "
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
    promoted["execution_state"] = "blocked"
    cases.append(("allowlist movement", allowlist, True))

    missing = copy.deepcopy(generated)
    reference = next(
        entry for entry in missing["files"]
        if entry.get("execution_state") == "blocked"
    )
    reference.pop("dependencies")
    cases.append(("missing disposition", missing, True))

    missing_terminal = copy.deepcopy(generated)
    terminal = next(
        entry for entry in missing_terminal["files"]
        if entry.get("execution_state") == "terminal-disposition"
    )
    terminal.pop("terminal_disposition")
    cases.append(("missing terminal disposition", missing_terminal, True))

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
    blocked = sum(1 for case in remaining if case in BLOCKED_DEPENDENCIES)
    terminal = sum(1 for case in remaining if case in TERMINAL_DISPOSITIONS)
    print(f"PR-249 promoted coverage: {len(load_allowlist())}/{len(all_cases()) - helpers} executable files")
    print(f"unpromoted: {blocked} blocked, {terminal} terminal dispositions, {helpers} helper/preload")
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
    blocked = sum(1 for case in remaining if case in BLOCKED_DEPENDENCIES)
    terminal = sum(1 for case in remaining if case in TERMINAL_DISPOSITIONS)
    print(f"- Promoted coverage: `{len(load_allowlist())}/{len(all_cases()) - helpers}` executable PR-249 files.")
    print(f"- Unpromoted: `{blocked}` blocked files, `{terminal}` terminal dispositions, and `{helpers}` helper/preload files.")
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


def disposition_probe_candidates(
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
) -> list[dict[str, object]]:
    candidates: list[dict[str, object]] = []
    for case in DISPOSITION_PROBES:
        cats = classified.get(case) or uncategorized.get(case)
        if cats is None:
            continue
        expected = DISPOSITION_PROBE_EXPECTATIONS.get(case)
        candidates.append({
            "case": case,
            "categories": cats,
            "command": probe_command(case),
            "expected_terminal_disposition": None if expected is None else {
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
    blocked_cases = sorted(case for case in remaining if case in BLOCKED_DEPENDENCIES)
    terminal_cases = sorted(case for case in remaining if case in TERMINAL_DISPOSITIONS)
    return {
        "promoted_executable": executable_passed,
        "executable_total": executable_total,
        "blocked_executable": len(blocked_cases),
        "terminal_disposition_executable": len(terminal_cases),
        "helper_preload": helpers,
        "allowlist": {
            "executable_passed": executable_passed,
            "executable_total": executable_total,
        },
        "unpromoted": {
            "blocked": blocked_cases,
            "terminal_dispositions": {
                case: TERMINAL_DISPOSITIONS[case] for case in terminal_cases
            },
            "helper_preload": sorted(case for case in remaining if case in HELPERS),
        },
        "categories": {cat: sorted(cases) for cat, cases in sorted(by_category.items())},
        "uncategorized": sorted(uncategorized),
        "missing_allowlist_entries": missing_allowlist,
        "disposition_probe_candidates": disposition_probe_candidates(classified, uncategorized),
    }


def print_disposition_probe_candidates(
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    *,
    markdown: bool,
) -> None:
    if markdown:
        print()
        print("Terminal-disposition probes:")
    else:
        print()
        print("terminal-disposition probes:")

    for candidate in disposition_probe_candidates(classified, uncategorized):
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


def check_disposition_expectation(
    case: str,
    status: str,
    output: str | bytes | None,
    *,
    emit: bool = True,
) -> bool:
    expected = DISPOSITION_PROBE_EXPECTATIONS.get(case)
    if expected is None:
        return True
    if status != expected.status:
        if emit:
            print(f"    UNEXPECTED: expected {expected.status}, got {status}")
        return False
    if not expected.evidence:
        if emit:
            print("    terminal disposition confirmed")
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
        print("    terminal disposition confirmed")
    return True


def run_disposition_probes(
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    *,
    timeout_s: float,
    expect_terminal_dispositions: bool,
    skip_timeout_probes: bool,
    emit: bool = True,
) -> tuple[int, list[dict[str, object]]]:
    if emit:
        print()
        print(f"running terminal-disposition probes (timeout {timeout_s:g}s each):")
    failures = 0
    results: list[dict[str, object]] = []
    for case in DISPOSITION_PROBES:
        cats = classified.get(case) or uncategorized.get(case)
        if cats is None:
            continue
        reason = ", ".join(cats) if cats else "uncategorized"
        expected = DISPOSITION_PROBE_EXPECTATIONS.get(case)
        if skip_timeout_probes and expected is not None and expected.status == "timeout":
            if emit:
                print(f"  - {case}: {reason}")
                print("    SKIP expected timeout blocker")
            results.append({
                "case": case,
                "status": "skipped",
                "skip_reason": "expected timeout blocker",
                "exit_code": None,
                "expected_terminal_disposition": expect_terminal_dispositions,
                "expectation_matched": None,
                "output": {
                    "evidence": [],
                    "tail": [],
                },
            })
            continue
        cmd = probe_command(case)
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
                "expected_terminal_disposition": expect_terminal_dispositions,
                "output": probe_output_summary(output),
            }
            if emit and output:
                print_probe_output_tail(output)
            if expect_terminal_dispositions:
                ok = check_disposition_expectation(case, "timeout", output, emit=emit)
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
                "expected_terminal_disposition": expect_terminal_dispositions,
                "output": probe_output_summary(output),
            }
            if expect_terminal_dispositions:
                ok = check_disposition_expectation(case, "pass", output, emit=emit)
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
                "expected_terminal_disposition": expect_terminal_dispositions,
                "output": probe_output_summary(output),
            }
            if expect_terminal_dispositions:
                ok = check_disposition_expectation(case, "fail", output, emit=emit)
                result["expectation_matched"] = ok
                if not ok:
                    failures += 1
            else:
                result["expectation_matched"] = None
                failures += 1
        results.append(result)
    return failures, results


def run_unpromoted_scan(
    remaining: list[str],
    classified: dict[str, list[str]],
    uncategorized: dict[str, list[str]],
    *,
    timeout_s: float,
    emit: bool = True,
) -> tuple[int, list[dict[str, object]]]:
    """Run all unpromoted executables and fail on disposition drift."""

    if emit:
        print()
        print(f"scanning unpromoted executables (timeout {timeout_s:g}s each):")

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
            probe_command(case),
            timeout_s,
        )
        output_summary = probe_output_summary(output)
        if run_status == "timeout":
            terminal = TERMINAL_DISPOSITIONS.get(case)
            if emit:
                print("    TIMEOUT")
                if output:
                    print_probe_output_tail(output)
            if terminal is not None and terminal["verification"]["default"]["status"] != "timeout":
                unexpected_passes += 1
            results.append({
                "case": case,
                "status": "terminal-disposition-drift" if terminal is not None else "timeout",
                "exit_code": None,
                "categories": cats,
                "terminal_disposition": terminal,
                "output": output_summary,
            })
            continue

        observed_status = "pass" if returncode == 0 else "fail"
        terminal = TERMINAL_DISPOSITIONS.get(case)
        if terminal is not None:
            expected_status = terminal["verification"]["default"]["status"]
            if observed_status != expected_status:
                unexpected_passes += 1
                status = "terminal-disposition-drift"
                if emit:
                    print(f"    TERMINAL DRIFT: expected {expected_status}, got {observed_status}")
            else:
                status = "terminal-disposition-confirmed"
                if emit:
                    print(f"    terminal disposition confirmed ({observed_status})")
            results.append({
                "case": case,
                "status": status,
                "observed_status": observed_status,
                "exit_code": returncode,
                "categories": cats,
                "terminal_disposition": terminal,
                "output": output_summary,
            })
            continue

        if returncode == 0:
            expected_pass_reason = BLOCKED_EXPECTED_SERIALIZED_PASSES.get(case)
            if expected_pass_reason is None:
                unexpected_passes += 1
                status = "pass"
                if emit:
                    print("    UNEXPECTED PASS: promote or reclassify this file")
            else:
                status = "expected-blocked-serialized-pass"
                if emit:
                    print(f"    expected blocked serialized pass: {expected_pass_reason}")
            results.append({
                "case": case,
                "status": status,
                "exit_code": returncode,
                "categories": cats,
                "expected_blocked_serialized_pass": expected_pass_reason,
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
        "--print-disposition-probes",
        action="store_true",
        help="Also print the focused terminal-disposition probes and commands.",
    )
    parser.add_argument(
        "--run-disposition-probes",
        action="store_true",
        help="Run focused terminal-disposition probes and verify their exact pass/fail evidence.",
    )
    parser.add_argument(
        "--probe-timeout",
        type=float,
        default=60.0,
        help="Timeout in seconds for each focused disposition probe (default: 60).",
    )
    parser.add_argument(
        "--expect-terminal-dispositions",
        action="store_true",
        help=(
            "With --run-disposition-probes, succeed only when every probe matches "
            "its documented terminal pass/fail evidence."
        ),
    )
    parser.add_argument(
        "--skip-timeout-probes",
        action="store_true",
        help=(
            "With --run-disposition-probes, skip probes whose documented disposition is an expected timeout."
        ),
    )
    parser.add_argument(
        "--scan-unpromoted",
        action="store_true",
        help=(
            "Run every blocked or terminal executable and return nonzero on disposition drift. "
            "This slower opt-in sweep catches stale blockers and terminal premises."
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
    if args.print_disposition_probes and args.format != "json":
        print_disposition_probe_candidates(classified, uncategorized, markdown=args.format == "markdown")
    probe_failures = 0
    probe_results: list[dict[str, object]] = []
    if args.run_disposition_probes:
        probe_failures, probe_results = run_disposition_probes(
            classified,
            uncategorized,
            timeout_s=args.probe_timeout,
            expect_terminal_dispositions=args.expect_terminal_dispositions,
            skip_timeout_probes=args.skip_timeout_probes,
            emit=args.format != "json",
        )
    scan_failures = 0
    scan_results: list[dict[str, object]] = []
    if args.scan_unpromoted:
        scan_failures, scan_results = run_unpromoted_scan(
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
        if args.run_disposition_probes:
            summary["disposition_probe_results"] = probe_results
            summary["disposition_probe_failures"] = probe_failures
        if args.scan_unpromoted:
            summary["unpromoted_scan_results"] = scan_results
            summary["unpromoted_scan_disposition_drift"] = scan_failures
        if args.check_inventory:
            summary["inventory_matches"] = inventory_ok
        if args.self_test_inventory:
            summary["inventory_self_tests_pass"] = inventory_self_test_ok
        print(json.dumps(summary, indent=2, sort_keys=True))

    if missing_allowlist:
        return 1
    if args.fail_on_uncategorized and uncategorized:
        return 1
    if args.run_disposition_probes and probe_failures:
        return 1
    if args.scan_unpromoted and scan_failures:
        return 1
    if not inventory_ok or not inventory_self_test_ok:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
