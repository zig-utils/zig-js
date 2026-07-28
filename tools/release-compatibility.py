#!/usr/bin/env python3
"""Validate the #134 release compatibility matrix and README removal gate."""

from __future__ import annotations

import argparse
import csv
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
README_NOTICE_GATE_LABELS = {
    "platform_matrix": "supported platform correctness/sanitizer/performance matrix publication",
    "moving_gc": "automatic shared-realm compaction",
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
    return set(re.findall(r'b\.step\("([^"]+)"', build_source))


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


def generated_readme_notice(matrix: dict[str, object]) -> str:
    gates = matrix["gates"]
    open_ids = [gate["id"] for gate in gates if gate["status"] != "green"]
    lines = [README_NOTICE_START]
    if "shell_and_reference_hooks" in open_ids:
        inventory = json.loads(artifact_path("docs/.data/pr249-reference-inventory.json").read_text())
        summary = inventory["summary"]
        lines.append(
            "- PR-249 reference tail: "
            f"**{summary['blocked']}** files remain blocked on shell/JIT evidence; "
            f"**{summary['terminal_disposition']}** JSC-private or incompatible premises have terminal dispositions "
            "([inventory](docs/.data/pr249-reference-inventory.json))."
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
    for gate_id in ("public_jsc_c_api", "objective_c_bridge", "inspector"):
        inventory = json.loads(artifact_path(gate_by_id[gate_id]["evidence"][0]).read_text())
        require(statuses(inventory) == {"implemented"}, f"{gate_id}: inventory is not fully implemented")

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

    all_green = all(gate["status"] == "green" for gate in gates)
    require(matrix.get("all_green") is all_green, "all_green does not match gate states")
    policy = matrix.get("readme_policy", {})
    require(policy.get("remove_only_when_all_green") is True, "README removal policy drift")
    readme_path = artifact_path(policy.get("path", ""))
    readme = readme_path.read_text()
    heading = policy.get("not_implemented_heading")
    require(isinstance(heading, str) and heading, "README heading policy is required")
    if args.update_readme:
        readme = replace_readme_status(readme, generated_readme_status(test262_pass, test262_total, wasm))
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
    require(generated_readme_status(test262_pass, test262_total, wasm) in readme, "README status table drift")
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
