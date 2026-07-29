#!/usr/bin/env python3
"""Validate the #134 release compatibility matrix and README removal gate."""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
from pathlib import Path
import re
import statistics


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
README_NOTICE_START = "<!-- release-compatibility:notice:start -->"
README_NOTICE_END = "<!-- release-compatibility:notice:end -->"
README_STATUS_START = "<!-- release-compatibility:status:start -->"
README_STATUS_END = "<!-- release-compatibility:status:end -->"
README_WASM_PERFORMANCE_START = "<!-- release-compatibility:wasm-performance:start -->"
README_WASM_PERFORMANCE_END = "<!-- release-compatibility:wasm-performance:end -->"
README_GC_COMPACTION_START = "<!-- release-compatibility:gc-compaction:start -->"
README_GC_COMPACTION_END = "<!-- release-compatibility:gc-compaction:end -->"
README_BUILD_TEST_START = "<!-- release-compatibility:build-test:start -->"
README_BUILD_TEST_END = "<!-- release-compatibility:build-test:end -->"
README_USE_START = "<!-- release-compatibility:use:start -->"
README_USE_END = "<!-- release-compatibility:use:end -->"
README_OVERVIEW_START = "<!-- release-compatibility:overview:start -->"
README_OVERVIEW_END = "<!-- release-compatibility:overview:end -->"
README_QUICKSTART_START = "<!-- release-compatibility:quickstart:start -->"
README_QUICKSTART_END = "<!-- release-compatibility:quickstart:end -->"
README_NOTICE_GATE_LABELS = {
    "platform_matrix": "supported platform correctness/sanitizer/performance matrix publication",
    "moving_gc": "automatic shared/mid-script compaction evidence",
    "generational_gc": "moving nursery for the multi-age GC",
    "optimizing_jit": "optimizing-JIT backend/differential evidence",
    "readme_generation": "fully generated README/release claims",
}
README_USE_LINKS = (
    ("Zig API", "src/root.zig"),
    ("C API", "docs/api.md"),
    ("timers", "docs/timers.md"),
    ("WebAssembly and direct-chunk streaming compilation", "docs/wasm.md"),
    ("threads/GC", "docs/threads/index.md"),
)
README_BUILD_TEST_COMMANDS = (
    ("zig build", "library and headers", None),
    ("zig build test", "main test root", "test"),
    ("zig build test262", "configured tc39/test262 corpus", "test262"),
    ("zig build test-c-api", "C and C++ embedding fixtures", "test-c-api"),
    ("zig build benchmark-comparison", "zig-js single/multithread vs JSC", "benchmark-comparison"),
)
README_ZIG_VERSION = "0.17.0-dev"
SIMD_BASE_ITERATIONS = {
    "integer": 20_000,
    "float": 20_000,
    "shuffle": 4_000,
    "memory": 20_000,
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"release-compatibility: {message}")


def load_python_module(relative: str, name: str):
    path = artifact_path(relative)
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, f"cannot load Python module: {relative}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def build_step_names(build_source: str) -> set[str]:
    return set(re.findall(r'b\.step\(\s*"([^"]+)"', build_source))


def package_dependency_names(package_source: str) -> set[str]:
    return set(re.findall(r'\.(zig_[A-Za-z0-9_]+)\s*=', package_source))


def require_install_claims(build_source: str) -> None:
    require('.name = "zig-js"' in build_source, "README build command requires zig-js library target")
    require('"libzig-js.a"' in build_source, "README build command requires libzig-js.a install")
    require(
        "addInstallDirectory" in build_source and ".install_dir = .header" in build_source,
        "README build command requires header install",
    )


def read_tsv(relative: str) -> list[dict[str, str]]:
    return list(csv.DictReader(artifact_path(relative).read_text().splitlines(), delimiter="\t"))


def median_int(rows: list[dict[str, str]], field: str) -> float:
    values = [int(row[field]) for row in rows]
    require(values, f"no values for {field}")
    return statistics.median(values)


def tsv_median_ns(rows: list[dict[str, str]], **fields: object) -> float:
    values = [
        int(row["elapsed_ns"])
        for row in rows
        if all(row[key] == str(value) for key, value in fields.items())
    ]
    require(values, f"no benchmark samples match {fields}")
    return statistics.median(values)


def simd_logical_updates(family: str, jobs: int, lanes: int) -> int:
    base = SIMD_BASE_ITERATIONS[family]
    return sum(base + ((job + lane) & 15) for lane in range(lanes) for job in range(jobs))


def simd_rate(rows: list[dict[str, str]], engine: str, mode: str, family: str, lanes: int) -> float:
    workload = f"wasm_{family}_simd"
    matching_jobs = {
        int(row["jobs"])
        for row in rows
        if row["engine"] == engine
        and row["mode"] == mode
        and row["workload"] == workload
        and int(row["lanes"]) == lanes
    }
    require(len(matching_jobs) == 1, f"ambiguous SIMD job count for {engine}/{mode}/{workload}/{lanes}")
    jobs = next(iter(matching_jobs))
    elapsed = tsv_median_ns(rows, engine=engine, mode=mode, workload=workload, lanes=lanes, jobs=jobs)
    return simd_logical_updates(family, jobs, lanes) / (elapsed / 1e9)


def format_factor_range(values: list[float]) -> str:
    require(values, "cannot format empty factor range")
    low = min(values)
    high = max(values)
    if round(low, 2) == round(high, 2):
        return f"{low:.2f}x"
    return f"{low:.2f}–{high:.2f}x"


def generated_readme_wasm_performance() -> str:
    simd_rows = read_tsv("docs/.data/wasm-simd-benchmark-2026-07-18.tsv")
    simd_lanes = max(int(row["lanes"]) for row in simd_rows if row["mode"] == "independent_steady")
    require(simd_lanes == 8, "README SIMD performance headline expects eight-lane samples")
    scaling = []
    jsc_relative = []
    for family in SIMD_BASE_ITERATIONS:
        z1 = simd_rate(simd_rows, "zig-js", "single", family, 1)
        zm = simd_rate(simd_rows, "zig-js", "independent_steady", family, simd_lanes)
        jm = simd_rate(simd_rows, "JavaScriptCore", "independent_steady", family, simd_lanes)
        scaling.append(zm / z1)
        jsc_relative.append(zm / jm)

    thread_rows = read_tsv("docs/.data/wasm-threads-benchmark-2026-07-18.tsv")
    thread_lanes = max(int(row["lanes"]) for row in thread_rows if row["mode"] == "shared")
    require(thread_lanes == 8, "README Threads performance headline expects eight-worker samples")
    add_jobs = next(
        int(row["jobs"])
        for row in thread_rows
        if row["mode"] == "shared" and row["workload"] == "wasm_threads_atomic_add" and int(row["lanes"]) == thread_lanes
    )
    add_elapsed = tsv_median_ns(
        thread_rows,
        mode="shared",
        workload="wasm_threads_atomic_add",
        lanes=thread_lanes,
        jobs=add_jobs,
    )
    add_rate_millions = add_jobs * thread_lanes / (add_elapsed / 1e9) / 1e6
    wait_jobs = next(
        int(row["jobs"])
        for row in thread_rows
        if row["mode"] == "shared" and row["workload"] == "wasm_threads_wait_notify" and int(row["lanes"]) == thread_lanes
    )
    wait_elapsed = tsv_median_ns(
        thread_rows,
        mode="shared",
        workload="wasm_threads_wait_notify",
        lanes=thread_lanes,
        jobs=wait_jobs,
    )
    wait_handoffs = wait_jobs * thread_lanes / 2 / (wait_elapsed / 1e9)

    return "\n".join([
        README_WASM_PERFORMANCE_START,
        f"- **SIMD:** {format_factor_range(scaling)} eight-lane scaling; {format_factor_range(jsc_relative)} JSC throughput ([report](docs/.data/wasm-simd-benchmark-2026-07-18.md) · [samples](docs/.data/wasm-simd-benchmark-2026-07-18.tsv)).",
        f"- **Threads:** {add_rate_millions:.2f} M/s contended adds and {wait_handoffs:,.0f} wait/notify handoffs/s at eight workers ([report](docs/.data/wasm-threads-benchmark-2026-07-18.md) · [samples](docs/.data/wasm-threads-benchmark-2026-07-18.tsv)).",
        README_WASM_PERFORMANCE_END,
    ])


def generated_readme_gc_compaction() -> str:
    rows = read_tsv("docs/.data/gc-compaction-2026-07-19.tsv")
    control = [row for row in rows if row["mode"] == "control"]
    compact = [row for row in rows if row["mode"] == "compact"]
    require(len(control) == len(compact) and control, "GC compaction benchmark requires paired control/compact rows")
    require(
        {row["sample"] for row in control} == {row["sample"] for row in compact},
        "GC compaction benchmark samples are not paired",
    )
    require(
        all(row["action_status"] == "control" and row["fixed_status"] == "not_run" for row in control),
        "GC compaction control rows drifted",
    )
    require(
        all(row["action_status"] == "compacted" and row["fixed_status"] == "no_candidates" for row in compact),
        "GC compaction rows are not compacted fixed points",
    )
    require(
        all(int(row["before_live_slots"]) == int(row["after_live_slots"]) for row in rows),
        "GC compaction benchmark live-slot drift",
    )
    require(
        all(int(row["moved_cells"]) > 0 and int(row["moved_bytes"]) > 0 for row in compact),
        "GC compaction rows did not move tail cells",
    )
    control_capacity = median_int(control, "after_capacity_bytes")
    compact_capacity = median_int(compact, "after_capacity_bytes")
    require(compact_capacity < control_capacity, "GC compaction did not reduce retained backing")
    retained_reduction = 1 - compact_capacity / control_capacity
    compact_pause_ms = median_int(compact, "action_ns") / 1e6
    probe_ratio = median_int(control, "probe_ns") / median_int(compact, "probe_ns")
    require(0.99 <= probe_ratio <= 1.01, f"GC compaction probe throughput drifted to {probe_ratio:.3f}x")

    return "\n".join([
        README_GC_COMPACTION_START,
        f"- **Explicit compaction:** {retained_reduction * 100:.1f}% less retained fragmented backing ({control_capacity / 1048576:.2f} → {compact_capacity / 1048576:.2f} MiB) with a {compact_pause_ms:.2f} ms median pause and unchanged post-action throughput ([report](docs/.data/gc-compaction-2026-07-19.md) · [samples](docs/.data/gc-compaction-2026-07-19.tsv)).",
        README_GC_COMPACTION_END,
    ])


def generated_readme_benchmark_comparison(summary: dict[str, object], readme_path: Path) -> str:
    raw_relative = summary.get("raw")
    report_relative = summary.get("report")
    require(isinstance(raw_relative, str) and raw_relative, "benchmark comparison raw path is required")
    require(isinstance(report_relative, str) and report_relative, "benchmark comparison report path is required")
    raw_path = artifact_path(raw_relative)
    report_path = artifact_path(report_relative)
    publication = load_python_module("tools/benchmark-publication.py", "benchmark_publication_release")
    rows = publication.read_rows(raw_path)
    metadata = publication.parse_metadata(report_path)
    publication.ensure_report_matches(rows, metadata, raw_path, report_path)
    require(summary.get("samples") == len(rows), "benchmark comparison sample-count drift")
    report_link = report_path.relative_to(readme_path.parent).as_posix()
    raw_link = raw_path.relative_to(readme_path.parent).as_posix()
    generated = publication.readme_scorecard(rows, metadata, report_link, raw_link)
    return f"{publication.README_START}\n{generated.rstrip()}\n{publication.README_END}"


def replace_readme_benchmark_comparison(readme: str, generated: str) -> str:
    publication = load_python_module("tools/benchmark-publication.py", "benchmark_publication_update")
    require(generated.startswith(publication.README_START + "\n"), "generated benchmark scorecard missing start marker")
    require(generated.endswith("\n" + publication.README_END), "generated benchmark scorecard missing end marker")
    inner = generated.removeprefix(publication.README_START + "\n").removesuffix("\n" + publication.README_END)
    return publication.replace_readme_block(readme, inner)


def generated_readme_build_test() -> str:
    build_source = artifact_path("build.zig").read_text()
    ci_source = artifact_path(".github/workflows/ci.yml").read_text()
    steps = build_step_names(build_source)
    require_install_claims(build_source)
    require(f"zig@{README_ZIG_VERSION}" in ci_source, "README Zig version drift")
    for command, _, step in README_BUILD_TEST_COMMANDS:
        if step is not None:
            require(step in steps, f"README command `{command}` references a missing build step")

    width = max(len(command) for command, _, _ in README_BUILD_TEST_COMMANDS) + 2
    lines = [
        README_BUILD_TEST_START,
        f"Requires Zig {README_ZIG_VERSION}.",
        "",
        "```sh",
    ]
    lines.extend(
        f"{command:<{width}}# {description}"
        for command, description, _ in README_BUILD_TEST_COMMANDS
    )
    lines.extend([
        "```",
        README_BUILD_TEST_END,
    ])
    return "\n".join(lines)


def generated_readme_use() -> str:
    build_source = artifact_path("build.zig").read_text()
    require_install_claims(build_source)
    artifact_path("include/JavaScriptCore/JavaScript.h")
    artifact_path("include/zig-js/Extensions.h")
    for _, relative in README_USE_LINKS:
        artifact_path(relative)
    link_text = ", ".join(f"[{label}]({relative})" for label, relative in README_USE_LINKS)
    return "\n".join([
        README_USE_START,
        f"`zig build` installs `libzig-js.a` and compatible headers under `zig-out/`. See the {link_text}.",
        README_USE_END,
    ])


def generated_readme_overview() -> str:
    package_source = artifact_path("build.zig.zon").read_text()
    build_source = artifact_path("build.zig").read_text()
    root_source = artifact_path("src/root.zig").read_text()
    c_api_source = artifact_path("src/c_api.zig").read_text()
    objc_source = artifact_path("src/objc_bridge.m").read_text()
    dependencies = package_dependency_names(package_source)
    require(dependencies == {"zig_regex", "zig_gc"}, f"README overview dependency drift: {sorted(dependencies)}")
    require("@import(\"js\")" in root_source and "Context.create" in root_source, "README overview requires Zig module API evidence")
    require("JavaScriptCore-shaped C API" in c_api_source, "README overview requires JSC-shaped C API evidence")
    require("#import <JavaScriptCore/JavaScriptCore.h>" in objc_source, "README overview requires Objective-C bridge evidence")
    require("src/objc_bridge.m" in build_source, "README overview requires Objective-C bridge build wiring")
    steps = build_step_names(build_source)
    require({"benchmark-comparison", "c-api-jsc-diff", "wasm-exception-jsc-diff"} <= steps, "README overview requires explicit system-JSC evidence steps")
    require('linkFramework("JavaScriptCore"' in build_source, "README overview requires system-JSC link evidence")

    return "\n".join([
        README_OVERVIEW_START,
        "Core engine and importable `js` module code are Zig; the static library exports JavaScriptCore-shaped C headers/symbols, with macOS Objective-C bridge glue in `src/objc_bridge.m`. The package depends on `zig-regex` and `zig-gc`, not bundled JSC/V8; system JavaScriptCore is used only by explicit differential and benchmark targets. APIs are pre-stabilization.",
        README_OVERVIEW_END,
    ])


def generated_readme_quickstart() -> str:
    build_source = artifact_path("build.zig").read_text()
    root_source = artifact_path("src/root.zig").read_text()
    context_source = artifact_path("src/context.zig").read_text()
    require('b.addModule("js"' in build_source, "README quickstart requires `js` module wiring")
    require("pub const Context = @import(\"context.zig\").Context;" in root_source, "README quickstart requires Context re-export")
    require("pub fn create(gpa: std.mem.Allocator) !*Context" in context_source, "README quickstart requires Context.create")
    require("pub fn destroy(self: *Context)" in context_source, "README quickstart requires Context.destroy")
    require("pub fn evaluate(self: *Context, source: []const u8)" in context_source, "README quickstart requires Context.evaluate")
    return "\n".join([
        README_QUICKSTART_START,
        "```zig",
        "const js = @import(\"js\");",
        "",
        "const ctx = try js.Context.create(allocator);",
        "defer ctx.destroy();",
        "",
        "const value = try ctx.evaluate(\"let x = 40; x + 2\");",
        "```",
        README_QUICKSTART_END,
    ])


def generated_readme_notice(matrix: dict[str, object]) -> str:
    gates = matrix["gates"]
    gate_by_id = {gate["id"]: gate for gate in gates}
    open_ids = [gate["id"] for gate in gates if gate["status"] != "green"]
    lines = [README_NOTICE_START]
    if "shell_and_reference_hooks" in open_ids:
        inventory = json.loads(artifact_path("docs/.data/pr249-reference-inventory.json").read_text())
        scan_relative = pr249_scan_path(gate_by_id["shell_and_reference_hooks"])
        summary = inventory["summary"]
        blocked = summary["blocked"]
        blocked_noun = "file" if blocked == 1 else "files"
        blocked_verb = "remains" if blocked == 1 else "remain"
        lines.append(
            "- PR-249 reference tail: "
            f"**{blocked}** {blocked_noun} {blocked_verb} blocked on shell/JIT evidence; "
            f"**{summary['terminal_disposition']}** JSC-private or incompatible premises have terminal dispositions "
            f"([inventory](docs/.data/pr249-reference-inventory.json) · [scan]({scan_relative}))."
        )
    release_gate_labels = [
        README_NOTICE_GATE_LABELS[gate_id]
        for gate_id in open_ids
        if gate_id in README_NOTICE_GATE_LABELS
    ]
    if release_gate_labels:
        lines.append(
            "- Open release gates: "
            + "; ".join(release_gate_labels)
            + " ([matrix](docs/.data/release-compatibility-matrix.json))."
        )
    lines.extend([
        "",
        "The [release matrix](docs/.data/release-compatibility-matrix.json) tracks "
        "[#134](https://github.com/zig-utils/zig-js/issues/134); removal of this section is gated by "
        "[#246](https://github.com/zig-utils/zig-js/issues/246).",
        README_NOTICE_END,
    ])
    return "\n".join(lines)


def validate_platform_matrix(matrix: dict[str, object], gate: dict[str, object]) -> None:
    required = {
        "tools/platform-release-matrix.py",
        "docs/.data/platform-release-matrix-2026-07-28.json",
        "docs/platforms.md",
        ".github/workflows/ci.yml",
        "docs/.data/benchmark-comparison-2026-07-22-property-osr.md",
        "docs/.data/benchmark-comparison-2026-07-22-property-osr.tsv",
    }
    evidence = set(gate.get("evidence", []))
    require(required <= evidence, "platform matrix gate evidence is incomplete")

    generator = load_python_module("tools/platform-release-matrix.py", "platform_release_matrix_check")
    expected = generator.build_matrix()
    checked = json.loads(artifact_path("docs/.data/platform-release-matrix-2026-07-28.json").read_text())
    require(checked == expected, "platform release matrix drift")
    require(artifact_path("docs/platforms.md").read_text() == generator.render_markdown(expected), "platform matrix Markdown drift")
    require(checked["status"] == "published", "platform release matrix is not published")
    summary = checked["summary"]
    require(summary["correctness_gated_platforms"] >= 1, "platform matrix lacks correctness coverage")
    require(summary["sanitizer_gated_platforms"] >= 1, "platform matrix lacks sanitizer coverage")
    require(summary["performance_published_platforms"] >= 1, "platform matrix lacks performance coverage")

    platform_scope = matrix.get("platform_scope", {})
    require(
        platform_scope == {
            "matrix": "docs/.data/platform-release-matrix-2026-07-28.json",
            "correctness": [{"os": "linux", "architecture": "x86_64", "status": "gated"}],
            "sanitizers": [{"os": "linux", "architecture": "x86_64", "status": "gated"}],
            "performance": [{"os": "macos", "architecture": "arm64", "status": "published"}],
        },
        "platform scope summary drift",
    )


def pr249_scan_path(gate: dict[str, object]) -> str:
    scans = [
        relative
        for relative in gate.get("evidence", [])
        if isinstance(relative, str)
        and relative.startswith("docs/.data/pr249-unpromoted-scan-")
        and relative.endswith(".json")
    ]
    require(len(scans) == 1, "shell/reference gate must cite exactly one PR-249 unpromoted scan")
    return scans[0]


def validate_pr249_tail(gate: dict[str, object]) -> None:
    inventory = json.loads(artifact_path("docs/.data/pr249-reference-inventory.json").read_text())
    summary = inventory["summary"]
    files = inventory["files"]
    blocked = sorted(
        entry["case"]
        for entry in files
        if entry.get("execution_state") == "blocked"
    )
    terminal = sorted(
        entry["case"]
        for entry in files
        if entry.get("execution_state") == "terminal-disposition"
    )
    helpers = sorted(
        entry["case"]
        for entry in files
        if entry.get("execution_state") == "helper/preload"
    )
    require(summary["blocked"] == len(blocked), "PR-249 blocked summary drift")
    require(summary["terminal_disposition"] == len(terminal), "PR-249 terminal summary drift")
    require(summary["helper_preload"] == len(helpers), "PR-249 helper summary drift")

    scan_relative = pr249_scan_path(gate)
    scan = json.loads(artifact_path(scan_relative).read_text())
    allowlist = scan.get("allowlist", {})
    require(allowlist.get("executable_passed") == summary["promoted"], "PR-249 scan promoted count drift")
    require(allowlist.get("executable_total") == summary["executable"], "PR-249 scan executable count drift")
    require(scan.get("blocked_executable") == summary["blocked"], "PR-249 scan blocked count drift")
    require(scan.get("terminal_disposition_executable") == summary["terminal_disposition"], "PR-249 scan terminal count drift")
    require(scan.get("helper_preload") == summary["helper_preload"], "PR-249 scan helper count drift")
    require(scan.get("missing_allowlist_entries") == [], "PR-249 scan has missing allowlist entries")
    require(scan.get("uncategorized") == [], "PR-249 scan has uncategorized entries")
    require(scan.get("unpromoted_scan_disposition_drift") == 0, "PR-249 unpromoted scan found disposition drift")

    unpromoted = scan.get("unpromoted", {})
    require(unpromoted.get("blocked") == blocked, "PR-249 scan blocked file list drift")
    require(sorted(unpromoted.get("terminal_dispositions", {}).keys()) == terminal, "PR-249 scan terminal file list drift")
    require(unpromoted.get("helper_preload") == helpers, "PR-249 scan helper file list drift")

    results = scan.get("unpromoted_scan_results")
    require(isinstance(results, list), "PR-249 scan results must be a list")
    by_case = {
        entry.get("case"): entry
        for entry in results
        if isinstance(entry, dict) and isinstance(entry.get("case"), str)
    }
    expected_scanned = set(blocked) | set(terminal)
    require(set(by_case) == expected_scanned, "PR-249 scan result coverage drift")
    for case in terminal:
        entry = by_case[case]
        require(entry.get("status") == "terminal-disposition-confirmed", f"{case}: terminal disposition is not confirmed")
        disposition = entry.get("terminal_disposition", {})
        verification = disposition.get("verification", {})
        mode_results = entry.get("mode_results", {})
        require(set(mode_results) == {"parallel-js", "serialized"}, f"{case}: terminal mode coverage drift")
        for mode, verification_key in (("serialized", "default"), ("parallel-js", "parallel_js")):
            mode_result = mode_results.get(mode, {})
            expected_status = verification.get(verification_key, {}).get("status")
            require(mode_result.get("expected_status") == expected_status, f"{case}: {mode} expected status drift")
            require(mode_result.get("observed_status") == expected_status, f"{case}: {mode} observed status drift")
            require(mode_result.get("expectation_matched") is True, f"{case}: {mode} terminal expectation mismatch")
    for case in blocked:
        entry = by_case[case]
        status = entry.get("status")
        require(status in {
            "timeout",
            "fail",
            "expected-blocked-serialized-pass",
            "expected-blocked-no-optimizer-evidence",
        }, f"{case}: blocked scan status is not accounted")
        require(entry.get("terminal_disposition") is None, f"{case}: blocked case has terminal disposition")
        if status == "expected-blocked-serialized-pass":
            require(entry.get("expected_blocked_serialized_pass"), f"{case}: serialized pass lacks blocker reason")
        if status == "expected-blocked-no-optimizer-evidence":
            require(entry.get("expected_blocked_no_optimizer_evidence"), f"{case}: optimizer pass lacks blocker reason")

def private_abi_count(relative: str) -> int:
    inventory = json.loads(artifact_path(relative).read_text())
    by_classification = inventory.get("totals", {}).get("by_classification", {})
    return int(by_classification.get("private_jsc", 0))


def generated_readme_status(
    test262_pass: int,
    test262_total: int,
    wasm: dict[str, object],
) -> str:
    wasm_totals = wasm["combined_totals"]
    core_3 = next((profile for profile in wasm["profiles"] if profile["id"] == "core-3"), None)
    require(core_3 is not None, "README status generation requires Core 3 profile")
    core_3_totals = core_3["totals"]
    home_private = private_abi_count("docs/abi/home-private-7ed99c02-inventory.json")
    bun_private = private_abi_count("docs/abi/bun-private-core-4982b91e-inventory.json")
    return "\n".join([
        README_STATUS_START,
        "| profile | result | evidence |",
        "| --- | ---: | --- |",
        f"| configured test262 | **{test262_pass:,} / {test262_total:,}** | [run](docs/.data/test262-run-2026-07-27.txt) · [data](docs/.data/test262.json) |",
        f"| ten-profile WebAssembly matrix | **{wasm_totals['pass']:,} / {wasm_totals['pass']:,} applicable** | Core 3: {core_3_totals['pass']:,}/{core_3_totals['pass']:,} · [matrix](docs/.data/wasm-conformance-matrix.json) · [upstream-main shadow](docs/.data/wasm-core-main-shadow-inventory.json) · [reproduce](docs/wasm.md) |",
        f"| pinned private ABI | **Home {home_private}/{home_private} · Bun {bun_private}/{bun_private}** | [inventories, provider audit, precise lifecycle, and exact reproduction](docs/abi/README.md) |",
        README_STATUS_END,
    ])


def replace_readme_status(readme: str, generated: str) -> str:
    heading = "## Status\n"
    require(heading in readme, "README status heading is absent")
    before, section_and_after = readme.split(heading, 1)
    next_heading_at = section_and_after.find("\n## ")
    require(next_heading_at != -1, "README status section is unterminated")
    after = section_and_after[next_heading_at + 1 :]
    return f"{before}{heading}\n{generated}\n\n{after}"


def replace_readme_overview(readme: str, generated: str) -> str:
    heading = "# zig-js\n\n"
    require(heading in readme, "README title is absent")
    before, section_and_after = readme.split(heading, 1)
    if README_QUICKSTART_START in section_and_after:
        quickstart_start = section_and_after.find(README_QUICKSTART_START)
        after = section_and_after[quickstart_start:]
    else:
        code_start = section_and_after.find("\n```zig\n")
        require(code_start != -1, "README overview code sample is absent")
        after = section_and_after[code_start + 1 :]
    return f"{before}{heading}{generated}\n\n{after}"


def replace_readme_quickstart(readme: str, generated: str) -> str:
    if README_QUICKSTART_START in readme or README_QUICKSTART_END in readme:
        require(
            readme.count(README_QUICKSTART_START) == 1 and readme.count(README_QUICKSTART_END) == 1,
            "README quickstart marker pair drift",
        )
        before, remainder = readme.split(README_QUICKSTART_START, 1)
        _, after = remainder.split(README_QUICKSTART_END, 1)
        return f"{before}{generated}\n\n{after.lstrip(chr(10))}"
    overview_end = README_OVERVIEW_END + "\n\n"
    require(overview_end in readme, "README quickstart requires overview marker")
    before, section_and_after = readme.split(overview_end, 1)
    code_end = section_and_after.find("\n```\n")
    require(section_and_after.startswith("```zig\n") and code_end != -1, "README quickstart code block is absent")
    after = section_and_after[code_end + len("\n```\n") :]
    return f"{before}{overview_end}{generated}\n\n{after.lstrip(chr(10))}"


def replace_readme_use(readme: str, generated: str) -> str:
    heading = "## Use\n"
    require(heading in readme, "README use heading is absent")
    before, section_and_after = readme.split(heading, 1)
    next_heading_at = section_and_after.find("\n## ")
    require(next_heading_at != -1, "README use section is unterminated")
    after = section_and_after[next_heading_at + 1 :]
    return f"{before}{heading}\n{generated}\n\n{after}"


def replace_readme_wasm_performance(readme: str, generated: str) -> str:
    heading = "### WebAssembly\n"
    require(heading in readme, "README WebAssembly performance heading is absent")
    before, section_and_after = readme.split(heading, 1)
    next_heading_at = section_and_after.find("\n### ")
    require(next_heading_at != -1, "README WebAssembly performance section is unterminated")
    after = section_and_after[next_heading_at + 1 :]
    return f"{before}{heading}\n{generated}\n\n{after}"


def replace_readme_gc_compaction(readme: str, generated: str) -> str:
    if README_GC_COMPACTION_START in readme or README_GC_COMPACTION_END in readme:
        require(
            readme.count(README_GC_COMPACTION_START) == 1 and readme.count(README_GC_COMPACTION_END) == 1,
            "README GC compaction marker pair drift",
        )
        before, remainder = readme.split(README_GC_COMPACTION_START, 1)
        _, after = remainder.split(README_GC_COMPACTION_END, 1)
        return f"{before}{generated}{after}"
    old = next(
        (line for line in readme.splitlines() if line.startswith("- **Explicit compaction:** ")),
        None,
    )
    require(old is not None, "README explicit compaction bullet is absent")
    return readme.replace(old, generated, 1)


def replace_readme_build_test(readme: str, generated: str) -> str:
    if README_BUILD_TEST_START in readme or README_BUILD_TEST_END in readme:
        require(
            readme.count(README_BUILD_TEST_START) == 1 and readme.count(README_BUILD_TEST_END) == 1,
            "README build/test marker pair drift",
        )
        before, remainder = readme.split(README_BUILD_TEST_START, 1)
        _, after = remainder.split(README_BUILD_TEST_END, 1)
        return f"{before}{generated}{after}"

    heading = "## Build And Test\n\n"
    sentinel = "\nRun `zig build --help` for the full command list."
    require(heading in readme and sentinel in readme, "README build/test section is absent")
    before, section_and_after = readme.split(heading, 1)
    _, after = section_and_after.split(sentinel, 1)
    return f"{before}{heading}{generated}\n{sentinel}{after}"


def replace_readme_notice(readme: str, heading: str, generated: str) -> str:
    heading_line = heading + "\n"
    require(heading_line in readme, "README missing-surface heading is absent")
    before, section_and_after = readme.split(heading_line, 1)
    next_heading_at = section_and_after.find("\n## ")
    require(next_heading_at != -1, "README missing-surface section is unterminated")
    after = section_and_after[next_heading_at + 1 :]
    return f"{before}{heading_line}\n{generated}\n\n{after}"


def remove_readme_notice(readme: str, heading: str) -> str:
    heading_line = heading + "\n"
    if heading_line not in readme:
        return readme
    before, section_and_after = readme.split(heading_line, 1)
    next_heading_at = section_and_after.find("\n## ")
    require(next_heading_at != -1, "README missing-surface section is unterminated")
    after = section_and_after[next_heading_at + 1 :]
    return before.rstrip() + "\n\n" + after


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("matrix", nargs="?", type=Path, default=DEFAULT_MATRIX)
    parser.add_argument("--release", action="store_true", help="fail unless every roadmap gate is green")
    parser.add_argument("--update-readme", action="store_true", help="rewrite the README missing-surface notice from the matrix")
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
    validate_platform_matrix(matrix, gate_by_id["platform_matrix"])
    for gate_id in ("public_jsc_c_api", "objective_c_bridge", "inspector"):
        inventory = json.loads(artifact_path(gate_by_id[gate_id]["evidence"][0]).read_text())
        require(statuses(inventory) == {"implemented"}, f"{gate_id}: inventory is not fully implemented")
    validate_pr249_tail(gate_by_id["shell_and_reference_hooks"])

    private_pending = 0
    for relative in gate_by_id["private_abi_profiles"]["evidence"]:
        inventory = json.loads(artifact_path(relative).read_text())
        private_pending += inventory.get("totals", {}).get("by_status", {}).get("pending", 0)
    if gate_by_id["private_abi_profiles"]["status"] == "green":
        require(private_pending == 0, "private ABI gate is green with pending entries")
    else:
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

    benchmark_summary = summaries.get("benchmark_comparison", {})
    require(isinstance(benchmark_summary, dict), "benchmark comparison summary is required")

    all_green = all(gate["status"] == "green" for gate in gates)
    require(matrix.get("all_green") is all_green, "all_green does not match gate states")
    policy = matrix.get("readme_policy", {})
    require(policy.get("remove_only_when_all_green") is True, "README removal policy drift")
    readme_path = artifact_path(policy.get("path", ""))
    readme = readme_path.read_text()
    heading = policy.get("not_implemented_heading")
    require(isinstance(heading, str) and heading, "README heading policy is required")
    if args.update_readme:
        readme = replace_readme_overview(readme, generated_readme_overview())
        readme = replace_readme_quickstart(readme, generated_readme_quickstart())
        readme = replace_readme_status(readme, generated_readme_status(test262_pass, test262_total, wasm))
        readme = replace_readme_benchmark_comparison(
            readme,
            generated_readme_benchmark_comparison(benchmark_summary, readme_path),
        )
        readme = replace_readme_use(readme, generated_readme_use())
        readme = replace_readme_wasm_performance(readme, generated_readme_wasm_performance())
        readme = replace_readme_gc_compaction(readme, generated_readme_gc_compaction())
        readme = replace_readme_build_test(readme, generated_readme_build_test())
        readme = (
            remove_readme_notice(readme, heading)
            if all_green
            else replace_readme_notice(readme, heading, generated_readme_notice(matrix))
        )
        readme_path.write_text(readme)
    require((heading not in readme) is all_green, "README missing-surface section does not match release state")
    require(generated_readme_overview() in readme, "README overview drift")
    require(generated_readme_quickstart() in readme, "README quickstart drift")
    require(generated_readme_status(test262_pass, test262_total, wasm) in readme, "README status table drift")
    require(generated_readme_benchmark_comparison(benchmark_summary, readme_path) in readme, "README benchmark comparison drift")
    require(generated_readme_use() in readme, "README use section drift")
    require(generated_readme_wasm_performance() in readme, "README WebAssembly performance drift")
    require(generated_readme_gc_compaction() in readme, "README GC compaction drift")
    require(generated_readme_build_test() in readme, "README build/test drift")
    if not all_green:
        require(generated_readme_notice(matrix) in readme, "README missing-surface notice drift")
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
