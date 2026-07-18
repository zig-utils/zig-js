#!/usr/bin/env python3
"""Validate benchmark history and generate the README scorecard (#50)."""

from __future__ import annotations

import argparse
import importlib.util
import math
import os
import pathlib
import statistics
import sys
from collections import defaultdict


DRIVER_PATH = pathlib.Path(__file__).with_name("benchmark-comparison.py")
SPEC = importlib.util.spec_from_file_location("benchmark_comparison_publication", DRIVER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER_PATH}")
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)

README_START = "<!-- benchmark-comparison:start -->"
README_END = "<!-- benchmark-comparison:end -->"
LIKE_FOR_LIKE_KEYS = ("Host", "OS", "Zig", "zig-gc", "zig-regex", "JavaScriptCore")
REGRESSION_THRESHOLD_PERCENT = 10.0
MAX_RSD_PERCENT = 5.0


def read_rows(path: pathlib.Path):
    lines = path.read_text().splitlines()
    expected_header = "engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum"
    if not lines or lines[0] != expected_header:
        raise ValueError(f"{path}: invalid benchmark TSV header")
    rows = [benchmark.parse_row(line) for line in lines[1:] if line]
    if not rows:
        raise ValueError(f"{path}: no benchmark rows")
    samples, lanes, quick = matrix_configuration(rows)
    benchmark.validate(rows, samples, lanes, quick)
    return rows


def matrix_configuration(rows) -> tuple[int, list[int], bool]:
    grouped = groups(rows)
    sample_counts = {len(group) for group in grouped.values()}
    if len(sample_counts) != 1:
        raise ValueError(f"benchmark matrix has inconsistent sample counts: {sorted(sample_counts)}")
    samples = sample_counts.pop()
    lanes = sorted({row.lanes for row in rows if row.lanes > 1})
    jobs = {workload: next(row.jobs for row in rows if row.workload == workload) for workload in benchmark.WORKLOADS}
    if jobs == benchmark.WORKLOADS:
        quick = False
    elif jobs == {workload: max(1, count // 20) for workload, count in benchmark.WORKLOADS.items()}:
        quick = True
    else:
        raise ValueError(f"benchmark matrix has unsupported workload job counts: {jobs}")
    return samples, lanes, quick


def parse_metadata(path: pathlib.Path) -> dict[str, str]:
    metadata: dict[str, str] = {}
    in_environment = False
    for line in path.read_text().splitlines():
        if line == "## Environment":
            in_environment = True
            continue
        if in_environment and line.startswith("## "):
            break
        if not in_environment or not line.startswith("|"):
            continue
        fields = [field.strip() for field in line.strip("|").split("|")]
        if len(fields) != 2 or fields[0] in {"item", "---"}:
            continue
        metadata[fields[0]] = fields[1]
    missing = {"Date", "Power", "zig-js", *LIKE_FOR_LIKE_KEYS} - metadata.keys()
    if missing:
        raise ValueError(f"{path}: missing environment metadata: {sorted(missing)}")
    return metadata


def groups(rows):
    result = defaultdict(list)
    for row in rows:
        result[row.key].append(row)
    return result


def matrix_signature(rows) -> set[tuple[str, str, str, int, int]]:
    return {row.key for row in rows}


def power_signature(value: str) -> tuple[str, str]:
    source = "Battery Power" if "Battery Power" in value else "AC Power" if "AC Power" in value else value
    state = next(
        (candidate for candidate in ("discharging", "charging", "charged") if candidate in value.lower()),
        "unknown",
    )
    return source, state


def ensure_report_matches(rows, metadata: dict[str, str], raw_path: pathlib.Path, report_path: pathlib.Path) -> None:
    _, lanes, _ = matrix_configuration(rows)
    expected = benchmark.render(rows, lanes, raw_path, metadata)
    if report_path.read_text() != expected:
        raise ValueError(f"{report_path}: report does not exactly match {raw_path}")


def ensure_like_for_like(
    current_metadata: dict[str, str],
    baseline_metadata: dict[str, str],
    current_rows,
    baseline_rows,
) -> None:
    mismatches = {
        key: (baseline_metadata[key], current_metadata[key])
        for key in LIKE_FOR_LIKE_KEYS
        if current_metadata[key] != baseline_metadata[key]
    }
    if mismatches:
        detail = "; ".join(f"{key}: {old!r} != {new!r}" for key, (old, new) in mismatches.items())
        raise ValueError(f"benchmark environments are not like-for-like: {detail}")
    if power_signature(current_metadata["Power"]) != power_signature(baseline_metadata["Power"]):
        raise ValueError(
            "benchmark environments are not like-for-like: "
            f"Power: {power_signature(baseline_metadata['Power'])!r} != "
            f"{power_signature(current_metadata['Power'])!r}"
        )
    if matrix_signature(current_rows) != matrix_signature(baseline_rows):
        raise ValueError("benchmark matrices are not like-for-like (engine/mode/workload/lanes/jobs differ)")
    if {key: len(value) for key, value in groups(current_rows).items()} != {
        key: len(value) for key, value in groups(baseline_rows).items()
    }:
        raise ValueError("benchmark matrices are not like-for-like (sample counts differ)")


def relative_stddev(values: list[int]) -> float:
    return statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0


def regression_rows(
    current_rows,
    baseline_rows,
    threshold_percent: float = REGRESSION_THRESHOLD_PERCENT,
    max_rsd_percent: float = MAX_RSD_PERCENT,
):
    current = groups(current_rows)
    baseline = groups(baseline_rows)
    regressions = []
    for key in sorted(current):
        if key[0] != "zig-js":
            continue
        current_values = [row.elapsed_ns for row in current[key]]
        baseline_values = [row.elapsed_ns for row in baseline[key]]
        current_median = statistics.median(current_values)
        baseline_median = statistics.median(baseline_values)
        delta_percent = (current_median / baseline_median - 1) * 100
        current_rsd = relative_stddev(current_values)
        baseline_rsd = relative_stddev(baseline_values)
        if (
            delta_percent > threshold_percent
            and current_rsd <= max_rsd_percent
            and baseline_rsd <= max_rsd_percent
        ):
            regressions.append((key, delta_percent, baseline_median, current_median, baseline_rsd, current_rsd))
    return regressions


def history_rows(current_rows, baseline_rows):
    current = groups(current_rows)
    baseline = groups(baseline_rows)
    result = []
    for key in sorted(current):
        current_values = [row.elapsed_ns for row in current[key]]
        baseline_values = [row.elapsed_ns for row in baseline[key]]
        current_median = statistics.median(current_values)
        baseline_median = statistics.median(baseline_values)
        delta_percent = (current_median / baseline_median - 1) * 100
        current_rsd = relative_stddev(current_values)
        baseline_rsd = relative_stddev(baseline_values)
        if key[0] != "zig-js":
            status = "control"
        elif delta_percent > REGRESSION_THRESHOLD_PERCENT:
            status = "regression" if max(current_rsd, baseline_rsd) <= MAX_RSD_PERCENT else "noisy"
        elif delta_percent < -REGRESSION_THRESHOLD_PERCENT:
            status = "improved"
        else:
            status = "stable"
        result.append((key, delta_percent, baseline_median, current_median, baseline_rsd, current_rsd, status))
    return result


def geometric_mean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def median_ns(grouped, key) -> float:
    return statistics.median(row.elapsed_ns for row in grouped[key])


def readme_scorecard(rows, metadata: dict[str, str], report_link: str, raw_link: str) -> str:
    grouped = groups(rows)
    workloads = list(benchmark.WORKLOADS)
    max_lanes = max(row.lanes for row in rows)
    jobs = {workload: next(row.jobs for row in rows if row.workload == workload) for workload in workloads}

    direct_ratios = []
    steady_ratios = []
    cold_ratios = []
    zig_steady_scaling = []
    jsc_steady_scaling = []
    zig_cold_scaling = []
    jsc_cold_scaling = []
    shared_scaling = []
    for workload in workloads:
        count = jobs[workload]
        direct_ratios.append(
            median_ns(grouped, ("JavaScriptCore", "single", workload, 1, count))
            / median_ns(grouped, ("zig-js", "single", workload, 1, count))
        )
        for mode, ratios, zig_scaling, jsc_scaling in (
            ("independent_steady", steady_ratios, zig_steady_scaling, jsc_steady_scaling),
            ("independent_cold", cold_ratios, zig_cold_scaling, jsc_cold_scaling),
        ):
            zig_one = median_ns(grouped, ("zig-js", mode, workload, 1, count))
            jsc_one = median_ns(grouped, ("JavaScriptCore", mode, workload, 1, count))
            zig_max = median_ns(grouped, ("zig-js", mode, workload, max_lanes, count))
            jsc_max = median_ns(grouped, ("JavaScriptCore", mode, workload, max_lanes, count))
            ratios.append(jsc_max / zig_max)
            zig_scaling.append(max_lanes * zig_one / zig_max)
            jsc_scaling.append(max_lanes * jsc_one / jsc_max)
        shared_one = median_ns(grouped, ("zig-js", "shared", workload, 1, count))
        shared_max = median_ns(grouped, ("zig-js", "shared", workload, max_lanes, count))
        shared_scaling.append(max_lanes * shared_one / shared_max)

    direct_wins = sum(value > 1 for value in direct_ratios)
    steady_wins = sum(value > 1 for value in steady_ratios)
    cold_wins = sum(value > 1 for value in cold_ratios)

    zig_revision = metadata["zig-js"].split()[0][:8]
    gc_revision = metadata["zig-gc"].split()[0][:8]
    regex_revision = metadata["zig-regex"].split()[0][:8]
    host = metadata["Host"].replace(";", ",")
    power_source, power_state = power_signature(metadata["Power"])
    lines = [
        "<!-- Generated by tools/benchmark-publication.py; do not edit headline numbers manually. -->",
        "",
        f"Latest [report]({report_link}) and [{len(rows):,} raw samples]({raw_link}): zig-js `{zig_revision}`, zig-gc `{gc_revision}`, zig-regex `{regex_revision}`; {host}; Zig `{metadata['Zig']}`; {metadata['JavaScriptCore']}; {power_source} ({power_state}). The harness validates equal work, alternating order, dispersion, and a 50 ms timing floor.",
        "",
        "| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
        f"| direct warmed context | 1 | {direct_wins} / {len(workloads)} | **{geometric_mean(direct_ratios):.2f}x** | — | — |",
        f"| independent steady contexts | {max_lanes} | {steady_wins} / {len(workloads)} | **{geometric_mean(steady_ratios):.2f}x** | **{geometric_mean(zig_steady_scaling):.2f}x** | {geometric_mean(jsc_steady_scaling):.2f}x |",
        f"| independent cold lifecycles | {max_lanes} | {cold_wins} / {len(workloads)} | **{geometric_mean(cold_ratios):.2f}x** | **{geometric_mean(zig_cold_scaling):.2f}x** | {geometric_mean(jsc_cold_scaling):.2f}x |",
        f"| shared realm, no GIL | {max_lanes} | no public-JSC equivalent | — | **{geometric_mean(shared_scaling):.2f}x** | — |",
        "",
        "A throughput ratio above 1.00x favors zig-js. Shared-realm threads share one object graph and have no public-JSC embedding equivalent.",
    ]
    return "\n".join(lines)


def replace_readme_block(text: str, generated: str) -> str:
    if text.count(README_START) != 1 or text.count(README_END) != 1:
        raise ValueError("README must contain exactly one ordered benchmark-comparison marker pair")
    before, remainder = text.split(README_START, 1)
    _, after = remainder.split(README_END, 1)
    return f"{before}{README_START}\n{generated.rstrip()}\n{README_END}{after}"


def render_history(comparisons, current_metadata, baseline_metadata, current_report, baseline_report) -> str:
    regressions = [row for row in comparisons if row[-1] == "regression"]
    lines = [
        f"# Benchmark history: {baseline_metadata['Date']} → {current_metadata['Date']}",
        "",
        f"- Baseline: zig-js `{baseline_metadata['zig-js']}` from `{baseline_report}`",
        f"- Current: zig-js `{current_metadata['zig-js']}` from `{current_report}`",
        f"- Controlled environment: {current_metadata['Host']}; {current_metadata['OS']}; {power_signature(current_metadata['Power'])[0]} ({power_signature(current_metadata['Power'])[1]})",
        "",
        "Environment, matrix, jobs, and sample counts are like-for-like. A zig-js regression fails publication only",
        f"when median wall time worsens by more than {REGRESSION_THRESHOLD_PERCENT:.0f}% and both baseline/current RSD are at most {MAX_RSD_PERCENT:.0f}%.",
        "JSC rows are retained as environmental controls but never gate zig-js publication.",
        "",
        "| engine | mode | workload | lanes | jobs | baseline (ms) | current (ms) | delta | baseline RSD | current RSD | status |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for key, delta, baseline, current, baseline_rsd, current_rsd, status in comparisons:
        lines.append(
            f"| {key[0]} | {key[1]} | {key[2]} | {key[3]} | {key[4]} | "
            f"{baseline / 1e6:.3f} | {current / 1e6:.3f} | {delta:+.2f}% | "
            f"{baseline_rsd:.2f}% | {current_rsd:.2f}% | {status} |"
        )
    lines.extend(["", f"Noise-qualified zig-js regressions: **{len(regressions)}**."])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current-raw", type=pathlib.Path, required=True)
    parser.add_argument("--current-report", type=pathlib.Path, required=True)
    parser.add_argument("--readme", type=pathlib.Path)
    parser.add_argument("--baseline-raw", type=pathlib.Path)
    parser.add_argument("--baseline-report", type=pathlib.Path)
    parser.add_argument("--history-out", type=pathlib.Path)
    args = parser.parse_args()
    if not args.readme and not args.baseline_raw and not args.baseline_report:
        parser.error("request --readme and/or a baseline raw/report pair")
    if (args.baseline_raw is None) != (args.baseline_report is None):
        parser.error("--baseline-raw and --baseline-report must be provided together")
    if args.history_out and args.baseline_raw is None:
        parser.error("--history-out requires a baseline raw/report pair")

    current_rows = read_rows(args.current_raw)
    current_metadata = parse_metadata(args.current_report)
    ensure_report_matches(current_rows, current_metadata, args.current_raw, args.current_report)
    if args.readme:
        report_link = pathlib.Path(os.path.relpath(args.current_report, args.readme.parent)).as_posix()
        raw_link = pathlib.Path(os.path.relpath(args.current_raw, args.readme.parent)).as_posix()
        generated = readme_scorecard(current_rows, current_metadata, report_link, raw_link)
        args.readme.write_text(replace_readme_block(args.readme.read_text(), generated))

    if args.baseline_raw:
        baseline_rows = read_rows(args.baseline_raw)
        baseline_metadata = parse_metadata(args.baseline_report)
        ensure_report_matches(baseline_rows, baseline_metadata, args.baseline_raw, args.baseline_report)
        ensure_like_for_like(current_metadata, baseline_metadata, current_rows, baseline_rows)
        regressions = regression_rows(current_rows, baseline_rows)
        history = render_history(
            history_rows(current_rows, baseline_rows),
            current_metadata,
            baseline_metadata,
            args.current_report,
            args.baseline_report,
        )
        if args.history_out:
            args.history_out.parent.mkdir(parents=True, exist_ok=True)
            args.history_out.write_text(history)
        else:
            sys.stdout.write(history)
        if regressions:
            raise ValueError(f"{len(regressions)} noise-qualified benchmark regressions exceeded 10%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
