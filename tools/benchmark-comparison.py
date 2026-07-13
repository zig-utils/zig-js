#!/usr/bin/env python3
"""Run and report the reproducible zig-js / system-JSC comparison matrix."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import math
import os
import pathlib
import platform
import statistics
import subprocess
import sys
from collections import defaultdict


WORKLOADS = {
    # Equal work is used for both engines. These counts keep the fastest row
    # above the full-run 50 ms timing floor on the reference M3 Pro while
    # keeping the shared-realm stress matrix practical.
    "arithmetic": 80,
    "properties": 80,
    "arrays": 180,
    "fibonacci": 24,
}

MIN_FULL_MEDIAN_NS = 50_000_000


@dataclasses.dataclass(frozen=True)
class Row:
    engine: str
    mode: str
    workload: str
    lanes: int
    jobs: int
    sample: int
    elapsed_ns: int
    checksum: int

    @property
    def key(self) -> tuple[str, str, str, int, int]:
        return self.engine, self.mode, self.workload, self.lanes, self.jobs


def command_output(args: list[str], default: str = "unknown") -> str:
    try:
        return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip() or default
    except (FileNotFoundError, subprocess.CalledProcessError):
        return default


def parse_row(line: str) -> Row:
    fields = line.rstrip("\n").split("\t")
    if len(fields) != 8:
        raise ValueError(f"expected 8 TSV fields, got {len(fields)}: {line!r}")
    return Row(
        engine=fields[0],
        mode=fields[1],
        workload=fields[2],
        lanes=int(fields[3]),
        jobs=int(fields[4]),
        sample=int(fields[5]),
        elapsed_ns=int(fields[6]),
        checksum=int(fields[7]),
    )


def run_case(binary: pathlib.Path, arguments: list[str]) -> list[Row]:
    command = [str(binary), *arguments]
    print("+ " + " ".join(command), file=sys.stderr, flush=True)
    completed = subprocess.run(
        command,
        check=True,
        text=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    return [parse_row(line) for line in completed.stdout.splitlines() if line.strip()]


def collect(
    zig_js: pathlib.Path,
    jsc: pathlib.Path,
    samples: int,
    lanes: list[int],
    quick: bool,
) -> list[Row]:
    rows: list[Row] = []
    pair_index = 0

    def run_pair(zig_arguments: list[str], jsc_arguments: list[str]) -> None:
        nonlocal pair_index
        pair = ((zig_js, zig_arguments), (jsc, jsc_arguments))
        # Deterministically alternate process order by matrix row. Samples stay
        # consecutive inside each already-warmed runner, but neither engine is
        # systematically favored by always running first on a cooler machine.
        if pair_index % 2:
            pair = tuple(reversed(pair))
        pair_index += 1
        for binary, arguments in pair:
            rows.extend(run_case(binary, arguments))

    for workload, default_jobs in WORKLOADS.items():
        jobs = max(1, default_jobs // 20) if quick else default_jobs
        run_pair(
            ["single", workload, str(jobs), str(samples)],
            ["single", workload, str(jobs), str(samples)],
        )
        for lane_count in lanes:
            run_pair(
                ["shared", workload, str(jobs), str(samples), str(lane_count)],
                ["contexts", workload, str(jobs), str(samples), str(lane_count)],
            )
    return rows


def validate(rows: list[Row], samples: int, lanes: list[int], quick: bool) -> None:
    grouped: dict[tuple[str, str, str, int, int], list[Row]] = defaultdict(list)
    for row in rows:
        grouped[row.key].append(row)

    expected_groups = len(WORKLOADS) * 2 * (1 + len(lanes))
    if len(grouped) != expected_groups:
        raise RuntimeError(f"expected {expected_groups} result groups, got {len(grouped)}")
    for key, group in grouped.items():
        if len(group) != samples:
            raise RuntimeError(f"{key} has {len(group)} samples, expected {samples}")
        if sorted(row.sample for row in group) != list(range(samples)):
            raise RuntimeError(f"{key} has invalid sample indexes")
        checksums = {row.checksum for row in group}
        if len(checksums) != 1:
            raise RuntimeError(f"{key} produced unstable checksums: {sorted(checksums)}")
        if not quick and statistics.median(row.elapsed_ns for row in group) < MIN_FULL_MEDIAN_NS:
            raise RuntimeError(
                f"{key} median is shorter than the {MIN_FULL_MEDIAN_NS / 1e6:.0f} ms full-run timing floor"
            )

    by_work: dict[tuple[str, int, int], set[int]] = defaultdict(set)
    for row in rows:
        by_work[(row.workload, row.lanes, row.jobs)].add(row.checksum)
    mismatches = {key: values for key, values in by_work.items() if len(values) != 1}
    if mismatches:
        raise RuntimeError(f"cross-engine checksum mismatch: {mismatches}")


def median_ns(groups: dict[tuple[str, str, str, int, int], list[Row]], key: tuple[str, str, str, int, int]) -> float:
    return statistics.median(row.elapsed_ns for row in groups[key])


def spread(groups: dict[tuple[str, str, str, int, int], list[Row]], key: tuple[str, str, str, int, int]) -> tuple[float, float, float]:
    values = [row.elapsed_ns for row in groups[key]]
    relative_stddev = statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0
    return min(values), max(values), relative_stddev


def geometric_mean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def metadata() -> dict[str, str]:
    jsc_framework = pathlib.Path("/System/Library/Frameworks/JavaScriptCore.framework").resolve()
    info = jsc_framework / "Resources" / "Info.plist"
    jsc_version = command_output(["plutil", "-extract", "CFBundleVersion", "raw", str(info)])
    macos = command_output(["sw_vers", "-productVersion"], platform.platform())
    macos_build = command_output(["sw_vers", "-buildVersion"])
    cpu = command_output(["sysctl", "-n", "machdep.cpu.brand_string"], platform.processor())
    physical = command_output(["sysctl", "-n", "hw.physicalcpu"])
    logical = command_output(["sysctl", "-n", "hw.logicalcpu"])
    memory = command_output(["sysctl", "-n", "hw.memsize"])
    memory_gib = f"{int(memory) / (1024 ** 3):.1f} GiB" if memory.isdigit() else memory
    commit = command_output(["git", "rev-parse", "HEAD"])
    dirty = command_output(["git", "status", "--porcelain", "--untracked-files=no"], "")
    return {
        "Date": dt.date.today().isoformat(),
        "Host": f"{cpu}; {physical} physical / {logical} logical CPUs; {memory_gib}",
        "OS": f"macOS {macos} ({macos_build})",
        "Zig": command_output(["zig", "version"]),
        "zig-js": commit + (" (tracked worktree dirty)" if dirty else ""),
        "JavaScriptCore": f"system framework {jsc_version}",
    }


def render(rows: list[Row], lanes: list[int], raw_path: pathlib.Path | None, info: dict[str, str]) -> str:
    groups: dict[tuple[str, str, str, int, int], list[Row]] = defaultdict(list)
    for row in rows:
        groups[row.key].append(row)
    lines = [
        f"# zig-js / JavaScriptCore benchmark — {info['Date']}",
        "",
        "> This is a dated measurement, not a universal engine score. The workload source, raw samples,",
        "> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.",
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
        "## Single-thread result",
        "",
        "Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.",
        "Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.",
        "Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.",
        "",
        "| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    single_ratios: list[float] = []
    for workload in WORKLOADS:
        jobs = next(row.jobs for row in rows if row.workload == workload)
        zig = median_ns(groups, ("zig-js", "single", workload, 1, jobs))
        jsc = median_ns(groups, ("JavaScriptCore", "single", workload, 1, jobs))
        zig_min, zig_max, zig_rsd = spread(groups, ("zig-js", "single", workload, 1, jobs))
        jsc_min, jsc_max, jsc_rsd = spread(groups, ("JavaScriptCore", "single", workload, 1, jobs))
        ratio = zig / jsc
        single_ratios.append(ratio)
        lines.append(
            f"| `{workload}` | {jobs} | {zig / 1e6:.3f} | {zig_min / 1e6:.3f}–{zig_max / 1e6:.3f} | {zig_rsd:.2f}% | "
            f"{jsc / 1e6:.3f} | {jsc_min / 1e6:.3f}–{jsc_max / 1e6:.3f} | {jsc_rsd:.2f}% | {ratio:.2f}x |"
        )

    lines.extend([
        "",
        "## zig-js shared-realm scaling",
        "",
        "Every lane performs the full per-row job count. The timed region creates and joins shared-realm no-GIL",
        "JavaScript `Thread`s. `scaling` compares aggregate throughput with the zig-js single-context row.",
        "",
        "| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    zig_max_scaling: list[float] = []
    max_lanes = lanes[-1]
    for workload in WORKLOADS:
        jobs = next(row.jobs for row in rows if row.workload == workload)
        zig_one = median_ns(groups, ("zig-js", "single", workload, 1, jobs))
        for lane_count in lanes:
            zig = median_ns(groups, ("zig-js", "shared", workload, lane_count, jobs))
            zig_min, zig_max, zig_rsd = spread(groups, ("zig-js", "shared", workload, lane_count, jobs))
            zig_scaling = lane_count * zig_one / zig
            if lane_count == max_lanes:
                zig_max_scaling.append(zig_scaling)
            lines.append(
                f"| `{workload}` | {lane_count} | {jobs} | {zig / 1e6:.3f} | "
                f"{zig_min / 1e6:.3f}–{zig_max / 1e6:.3f} | {zig_rsd:.2f}% | {zig_scaling:.2f}x |"
            )

    lines.extend([
        "",
        "## JSC independent-context scaling reference",
        "",
        "Each lane owns a separately prepared and warmed `JSGlobalContext`. The timed region creates the OS threads,",
        "evaluates one invocation per context, and joins them. This is an isolated-context scaling reference, not a",
        "direct throughput competitor for zig-js's shared object graph.",
        "",
        "| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    jsc_max_scaling: list[float] = []
    for workload in WORKLOADS:
        jobs = next(row.jobs for row in rows if row.workload == workload)
        jsc_one = median_ns(groups, ("JavaScriptCore", "single", workload, 1, jobs))
        for lane_count in lanes:
            jsc = median_ns(groups, ("JavaScriptCore", "contexts", workload, lane_count, jobs))
            jsc_min, jsc_max, jsc_rsd = spread(groups, ("JavaScriptCore", "contexts", workload, lane_count, jobs))
            jsc_scaling = lane_count * jsc_one / jsc
            if lane_count == max_lanes:
                jsc_max_scaling.append(jsc_scaling)
            lines.append(
                f"| `{workload}` | {lane_count} | {jobs} | {jsc / 1e6:.3f} | "
                f"{jsc_min / 1e6:.3f}–{jsc_max / 1e6:.3f} | {jsc_rsd:.2f}% | {jsc_scaling:.2f}x |"
            )

    lines.extend([
        "",
        "## Reading the result",
        "",
        f"Across these four deliberately small kernels, JSC's single-context throughput is {geometric_mean(single_ratios):.2f}x",
        "the zig-js throughput by geometric mean. This is expected: the system JSC is a mature optimizing JIT, while",
        "zig-js currently has interpreters and no JIT. The number is a compact description of this matrix, not a claim",
        "about applications or unsupported workloads.",
        "",
        f"At {max_lanes} lanes, geometric-mean throughput scaling is {geometric_mean(zig_max_scaling):.2f}x for zig-js's",
        f"shared realm and {geometric_mean(jsc_max_scaling):.2f}x for the separate JSC isolated-context reference.",
        "These are deliberately not divided into a cross-engine parallel ratio because the programming models differ.",
        "Per-workload rows matter more than either aggregate.",
        "",
        "## Method and timed boundaries",
        "",
        "- Both engines evaluate the exact bytes in `bench/comparison.js`; the single-context rows time the exact same invocation bytes, and the driver rejects unstable or cross-engine checksum mismatches.",
        "- zig-js is built `ReleaseFast`. Its single row explicitly enables precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.",
        "- Each context evaluates the workload source and performs three reduced-size warm-up calls before measurement.",
        "- A single sample times one host evaluation call. Context/source setup and warm-up are outside the timer.",
        "- Parallel JS state and JSC contexts are prepared and warmed before measurement. The timed region creates the zig-js `Thread`s / JSC OS threads, performs the work, and ends after every thread joins. JSC context teardown is outside the timer.",
        "- Runner process order alternates deterministically for each matrix row instead of always favoring one engine with the cooler first run.",
        f"- Full runs reject any row whose median is shorter than {MIN_FULL_MEDIAN_NS / 1e6:.0f} ms; quick harness validation skips that timing floor.",
        "- Samples run sequentially on an otherwise ordinary host. No CPU pinning, frequency locking, or background-process suppression is attempted.",
        "- Median is the headline; min/max and relative standard deviation expose dispersion, and every raw sample is retained.",
        "",
        "## Reproduce",
        "",
        "Requires macOS because the comparison links the system JavaScriptCore framework.",
        "",
        "```sh",
        "zig build benchmark-comparison",
        "zig build benchmark-comparison -Dbenchmark-comparison-raw-out=docs/.data/benchmark-comparison-YYYY-MM-DD.tsv -Dbenchmark-comparison-markdown-out=docs/.data/benchmark-comparison-YYYY-MM-DD.md",
        "zig build benchmark-comparison -Dbenchmark-comparison-quick=true",
        "```",
    ])
    if raw_path is not None:
        lines.extend(["", f"Raw samples: [`{raw_path.name}`]({raw_path.name})"])
    return "\n".join(lines) + "\n"


def write_raw(path: pathlib.Path, rows: list[Row]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum"]
    lines.extend(
        f"{row.engine}\t{row.mode}\t{row.workload}\t{row.lanes}\t{row.jobs}\t{row.sample}\t{row.elapsed_ns}\t{row.checksum}"
        for row in rows
    )
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("zig_js_runner", type=pathlib.Path)
    parser.add_argument("jsc_runner", type=pathlib.Path)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--lanes", default="2,4,8")
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--raw-out", type=pathlib.Path)
    parser.add_argument("--markdown-out", type=pathlib.Path)
    args = parser.parse_args()
    lanes = sorted({int(value) for value in args.lanes.split(",") if value})
    samples = 1 if args.quick else args.samples
    if samples <= 0 or not lanes or any(value <= 1 for value in lanes):
        parser.error("samples must be positive and lanes must contain values greater than one")
    for binary in (args.zig_js_runner, args.jsc_runner):
        if not binary.is_file():
            parser.error(f"runner does not exist: {binary}")

    info = metadata()
    publishing = args.raw_out is not None or args.markdown_out is not None
    if publishing and info["zig-js"].endswith(" (tracked worktree dirty)"):
        parser.error("refusing to publish benchmark evidence from a dirty tracked worktree")

    rows = collect(args.zig_js_runner, args.jsc_runner, samples, lanes, args.quick)
    validate(rows, samples, lanes, args.quick)
    report = render(rows, lanes, args.raw_out, info)
    if args.raw_out:
        write_raw(args.raw_out, rows)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(report)
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
