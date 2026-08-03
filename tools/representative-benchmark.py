#!/usr/bin/env python3
"""Collect the versioned representative zig-js / JavaScriptCore matrix."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import statistics
import subprocess
import sys
from collections import defaultdict


ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPARISON_DRIVER = pathlib.Path(__file__).with_name("benchmark-comparison.py")
MATRIX_TOOL = pathlib.Path(__file__).with_name("representative-matrix.ts")
HOME_TOOL = os.environ.get("HOME_TOOL", str(pathlib.Path.home() / "Code/Home/lang/zig-out/bin/home-tool"))
DEFAULT_MANIFEST = ROOT / "docs/.data/representative-benchmark-matrix-v1.json"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


comparison = load_module("representative_comparison_driver", COMPARISON_DRIVER)
Row = comparison.Row


def workload_entries(manifest: dict):
    for family in manifest["implemented_families"]:
        yield family, "base", family["base"]
        yield family, "variant", family["variant"]


def jobs_for(family: dict, quick: bool) -> int:
    return family["jobs"]["quick" if quick else "full"]


def collect(
    zig_js: pathlib.Path,
    jsc: pathlib.Path,
    manifest: dict,
    samples: int,
    lanes: list[int],
    quick: bool,
) -> list[Row]:
    rows: list[Row] = []
    pair_index = 0
    all_lanes = [1, *lanes]

    def run_pair(arguments: list[str]) -> None:
        nonlocal pair_index
        pair = (zig_js, jsc) if pair_index % 2 == 0 else (jsc, zig_js)
        pair_index += 1
        for binary in pair:
            rows.extend(comparison.run_case(binary, arguments))

    for family in manifest["implemented_families"]:
        jobs = jobs_for(family, quick)
        for workload in (family["base"], family["variant"]):
            run_pair(["single", workload, str(jobs), str(samples)])
        for lane_count in all_lanes:
            for mode in ("independent_steady", "independent_cold"):
                run_pair([mode, family["base"], str(jobs), str(samples), str(lane_count)])
            rows.extend(comparison.run_case(
                zig_js,
                ["shared", family["base"], str(jobs), str(samples), str(lane_count)],
            ))
    return rows


def expected_checksum(manifest: dict, workload: str, jobs: int, lanes: int) -> int:
    lane_index = manifest["lanes"].index(lanes)
    for family, role, identifier in workload_entries(manifest):
        if identifier != workload:
            continue
        scale = "full" if jobs == family["jobs"]["full"] else "quick" if jobs == family["jobs"]["quick"] else None
        if scale is None:
            raise ValueError(f"unsupported jobs for {workload}: {jobs}")
        return family["checksums"][role][scale][lane_index]
    raise ValueError(f"unknown workload: {workload}")


def validate(rows: list[Row], manifest: dict, samples: int, lanes: list[int], quick: bool) -> None:
    grouped = defaultdict(list)
    for row in rows:
        grouped[row.key].append(row)
    all_lanes = [1, *lanes]
    expected = set()
    for family in manifest["implemented_families"]:
        jobs = jobs_for(family, quick)
        for workload in (family["base"], family["variant"]):
            expected.add(("zig-js", "single", workload, 1, jobs))
            expected.add(("JavaScriptCore", "single", workload, 1, jobs))
        for lane_count in all_lanes:
            expected.add(("zig-js", "shared", family["base"], lane_count, jobs))
            for engine in ("zig-js", "JavaScriptCore"):
                expected.add((engine, "independent_steady", family["base"], lane_count, jobs))
                expected.add((engine, "independent_cold", family["base"], lane_count, jobs))
    actual = set(grouped)
    if actual != expected:
        raise RuntimeError(
            f"representative matrix mismatch; missing={sorted(expected - actual)}, "
            f"unexpected={sorted(actual - expected)}"
        )

    floor = manifest["protocol"]["minimum_full_median_ns"]
    for key, group in grouped.items():
        if len(group) != samples:
            raise RuntimeError(f"{key} has {len(group)} samples, expected {samples}")
        if sorted(row.sample for row in group) != list(range(samples)):
            raise RuntimeError(f"{key} has invalid sample indexes")
        expected_value = expected_checksum(manifest, key[2], key[4], key[3])
        values = {row.checksum for row in group}
        if values != {expected_value}:
            raise RuntimeError(f"{key} checksum {sorted(values)} does not match frozen {expected_value}")
        if not quick and statistics.median(row.elapsed_ns for row in group) < floor:
            raise RuntimeError(f"{key} median is shorter than the {floor / 1e6:.0f} ms full-run timing floor")

    for row in rows:
        peers = {
            candidate.checksum
            for candidate in rows
            if candidate.mode == row.mode
            and candidate.workload == row.workload
            and candidate.lanes == row.lanes
            and candidate.jobs == row.jobs
        }
        if len(peers) != 1:
            raise RuntimeError(f"cross-engine checksum mismatch for {row.key}: {sorted(peers)}")


def groups(rows: list[Row]):
    result = defaultdict(list)
    for row in rows:
        result[row.key].append(row)
    return result


def median_ms(grouped, key) -> float:
    return statistics.median(row.elapsed_ns for row in grouped[key]) / 1e6


def rsd(grouped, key) -> float:
    values = [row.elapsed_ns for row in grouped[key]]
    return statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0


def render(rows: list[Row], manifest: dict, lanes: list[int], raw_path: pathlib.Path | None, info: dict[str, str]) -> str:
    grouped = groups(rows)
    all_lanes = [1, *lanes]
    lines = [
        f"# Representative zig-js / JavaScriptCore matrix — {info['Date']}",
        "",
        "> This is a dated, workload-scoped measurement. It is not a universal engine score.",
        f"> Contract: `{manifest['matrix_id']}`; deferred families remain outside this report.",
        "",
        "## Environment",
        "",
        "| item | value |",
        "| --- | --- |",
    ]
    for key, value in info.items():
        lines.append(f"| {key} | {value} |")
    lines.extend([
        "",
        "## Direct warmed contexts and anti-specialization variants",
        "",
        "| family | workload | jobs | zig-js median (ms) | zig-js RSD | JSC median (ms) | JSC RSD | zig-js / JSC throughput |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for family, role, workload in workload_entries(manifest):
        jobs = next(row.jobs for row in rows if row.workload == workload)
        zig_key = ("zig-js", "single", workload, 1, jobs)
        jsc_key = ("JavaScriptCore", "single", workload, 1, jobs)
        zig = median_ms(grouped, zig_key)
        jsc = median_ms(grouped, jsc_key)
        lines.append(
            f"| `{family['family']}` | `{role}` | {jobs} | {zig:.3f} | {rsd(grouped, zig_key):.2f}% | "
            f"{jsc:.3f} | {rsd(grouped, jsc_key):.2f}% | {jsc / zig:.2f}x |"
        )

    for mode, heading in (
        ("independent_steady", "Independent-context steady state"),
        ("independent_cold", "Independent-context cold lifecycle"),
    ):
        lines.extend([
            "",
            f"## {heading}",
            "",
            "| family | lanes | jobs/lane | zig-js median (ms) | JSC median (ms) | zig-js / JSC throughput |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ])
        for family in manifest["implemented_families"]:
            workload = family["base"]
            jobs = next(row.jobs for row in rows if row.workload == workload)
            for lane_count in all_lanes:
                zig = median_ms(grouped, ("zig-js", mode, workload, lane_count, jobs))
                jsc = median_ms(grouped, ("JavaScriptCore", mode, workload, lane_count, jobs))
                lines.append(f"| `{family['family']}` | {lane_count} | {jobs} | {zig:.3f} | {jsc:.3f} | {jsc / zig:.2f}x |")

    lines.extend([
        "",
        "## zig-js shared-realm capability panel",
        "",
        "JSC's public API has no equivalent shared-realm execution model, so this panel has no cross-engine ratio.",
        "",
        "| family | lanes | jobs/lane | median (ms) | scaling |",
        "| --- | ---: | ---: | ---: | ---: |",
    ])
    for family in manifest["implemented_families"]:
        workload = family["base"]
        jobs = next(row.jobs for row in rows if row.workload == workload)
        one = median_ms(grouped, ("zig-js", "shared", workload, 1, jobs))
        for lane_count in all_lanes:
            elapsed = median_ms(grouped, ("zig-js", "shared", workload, lane_count, jobs))
            lines.append(f"| `{family['family']}` | {lane_count} | {jobs} | {elapsed:.3f} | {lane_count * one / elapsed:.2f}x |")

    lines.extend([
        "",
        "## Coverage boundary",
        "",
        f"Implemented families in this version: {len(manifest['implemented_families'])}.",
        "The following pre-registered families are explicit deferrals, not passes or exclusions:",
        "",
    ])
    for entry in manifest["deferred_families"]:
        lines.append(f"- `{entry['family']}` — {entry['reason']}")
    lines.extend([
        "",
        "The original ten-kernel compatibility panel remains separately collected and hash-pinned by the manifest.",
        "Every recorded checksum must equal the checked-in jobs/lane value; cross-engine equality alone is insufficient.",
        "Full rows retain seven samples and a 50 ms median floor. Quick runs are validation only and are not publication evidence.",
    ])
    if raw_path is not None:
        lines.extend(["", f"Raw samples: [`{raw_path.name}`]({raw_path.name})"])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("zig_js_runner", type=pathlib.Path)
    parser.add_argument("jsc_runner", type=pathlib.Path)
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--samples", type=int)
    parser.add_argument("--lanes", default="2,4,8")
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--raw-out", type=pathlib.Path)
    parser.add_argument("--markdown-out", type=pathlib.Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    subprocess.run([HOME_TOOL, "run", str(MATRIX_TOOL), "--manifest", str(args.manifest)], check=True)
    lanes = sorted({int(value) for value in args.lanes.split(",") if value})
    if not lanes or any(value not in manifest["lanes"] or value == 1 for value in lanes):
        parser.error("lanes must be a non-empty subset of the manifest lanes above one")
    samples = 1 if args.quick else args.samples or manifest["protocol"]["full_samples"]
    if samples <= 0:
        parser.error("samples must be positive")
    for binary in (args.zig_js_runner, args.jsc_runner):
        if not binary.is_file():
            parser.error(f"runner does not exist: {binary}")

    info = comparison.metadata()
    publishing = args.raw_out is not None or args.markdown_out is not None
    comparison.ensure_publishable(info, publishing)
    rows = collect(args.zig_js_runner, args.jsc_runner, manifest, samples, lanes, args.quick)
    validate(rows, manifest, samples, lanes, args.quick)
    report = render(rows, manifest, lanes, args.raw_out, info)
    if args.raw_out:
        comparison.write_raw(args.raw_out, rows)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(report)
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
