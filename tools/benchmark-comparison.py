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
    "arithmetic": 160,
    "properties": 200,
    "arrays": 450,
    "direct_calls": 500,
    "fibonacci": 100,
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
    all_lanes = [1, *lanes]

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
        for lane_count in all_lanes:
            for mode in ("independent_steady", "independent_cold"):
                arguments = [mode, workload, str(jobs), str(samples), str(lane_count)]
                run_pair(arguments, arguments)
            rows.extend(
                run_case(
                    zig_js,
                    ["shared", workload, str(jobs), str(samples), str(lane_count)],
                )
            )
    return rows


def validate(rows: list[Row], samples: int, lanes: list[int], quick: bool) -> None:
    grouped: dict[tuple[str, str, str, int, int], list[Row]] = defaultdict(list)
    for row in rows:
        grouped[row.key].append(row)

    all_lanes = [1, *lanes]
    expected: set[tuple[str, str, str, int, int]] = set()
    for workload, default_jobs in WORKLOADS.items():
        jobs = max(1, default_jobs // 20) if quick else default_jobs
        expected.update({
            ("zig-js", "single", workload, 1, jobs),
            ("JavaScriptCore", "single", workload, 1, jobs),
        })
        for lane_count in all_lanes:
            expected.add(("zig-js", "shared", workload, lane_count, jobs))
            for engine in ("zig-js", "JavaScriptCore"):
                expected.add((engine, "independent_steady", workload, lane_count, jobs))
                expected.add((engine, "independent_cold", workload, lane_count, jobs))
    actual = set(grouped)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        raise RuntimeError(f"result matrix mismatch; missing={missing}, unexpected={unexpected}")
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
    power = " ".join(command_output(["pmset", "-g", "batt"], "unavailable").split())
    return {
        "Date": dt.date.today().isoformat(),
        "Host": f"{cpu}; {physical} physical / {logical} logical CPUs; {memory_gib}",
        "OS": f"macOS {macos} ({macos_build})",
        "Zig": command_output(["zig", "version"]),
        "zig-js": commit + (" (tracked worktree dirty)" if dirty else ""),
        "JavaScriptCore": f"system framework {jsc_version}",
        "Power": power,
    }


def ensure_publishable(info: dict[str, str], publishing: bool) -> None:
    if publishing and info["zig-js"].endswith(" (tracked worktree dirty)"):
        raise ValueError("refusing to publish benchmark evidence from a dirty tracked worktree")


def render(rows: list[Row], lanes: list[int], raw_path: pathlib.Path | None, info: dict[str, str]) -> str:
    groups: dict[tuple[str, str, str, int, int], list[Row]] = defaultdict(list)
    for row in rows:
        groups[row.key].append(row)
    all_lanes = [1, *lanes]
    max_lanes = all_lanes[-1]
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
        "## Independent-context steady state",
        "",
        "Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the",
        "same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.",
        "`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.",
        "",
        "| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    steady_max_ratios: list[float] = []
    zig_steady_max_scaling: list[float] = []
    jsc_steady_max_scaling: list[float] = []
    for workload in WORKLOADS:
        jobs = next(row.jobs for row in rows if row.workload == workload)
        zig_one = median_ns(groups, ("zig-js", "independent_steady", workload, 1, jobs))
        jsc_one = median_ns(groups, ("JavaScriptCore", "independent_steady", workload, 1, jobs))
        for lane_count in all_lanes:
            zig_key = ("zig-js", "independent_steady", workload, lane_count, jobs)
            jsc_key = ("JavaScriptCore", "independent_steady", workload, lane_count, jobs)
            zig = median_ns(groups, zig_key)
            jsc = median_ns(groups, jsc_key)
            zig_min, zig_max, zig_rsd = spread(groups, zig_key)
            jsc_min, jsc_max, jsc_rsd = spread(groups, jsc_key)
            zig_scaling = lane_count * zig_one / zig
            jsc_scaling = lane_count * jsc_one / jsc
            ratio = zig / jsc
            if lane_count == max_lanes:
                steady_max_ratios.append(ratio)
                zig_steady_max_scaling.append(zig_scaling)
                jsc_steady_max_scaling.append(jsc_scaling)
            lines.append(
                f"| `{workload}` | {lane_count} | {jobs} | {zig / 1e6:.3f} | {zig_min / 1e6:.3f}–{zig_max / 1e6:.3f} | {zig_rsd:.2f}% | "
                f"{jsc / 1e6:.3f} | {jsc_min / 1e6:.3f}–{jsc_max / 1e6:.3f} | {jsc_rsd:.2f}% | {ratio:.2f}x | {zig_scaling:.2f}x | {jsc_scaling:.2f}x |"
            )

    lines.extend([
        "",
        "## Independent-context cold lifecycle",
        "",
        "Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source",
        "evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.",
        "`scaling` uses the same engine and cold lifecycle at one lane.",
        "",
        "| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    cold_max_ratios: list[float] = []
    zig_cold_max_scaling: list[float] = []
    jsc_cold_max_scaling: list[float] = []
    for workload in WORKLOADS:
        jobs = next(row.jobs for row in rows if row.workload == workload)
        zig_one = median_ns(groups, ("zig-js", "independent_cold", workload, 1, jobs))
        jsc_one = median_ns(groups, ("JavaScriptCore", "independent_cold", workload, 1, jobs))
        for lane_count in all_lanes:
            zig_key = ("zig-js", "independent_cold", workload, lane_count, jobs)
            jsc_key = ("JavaScriptCore", "independent_cold", workload, lane_count, jobs)
            zig = median_ns(groups, zig_key)
            jsc = median_ns(groups, jsc_key)
            zig_min, zig_max, zig_rsd = spread(groups, zig_key)
            jsc_min, jsc_max, jsc_rsd = spread(groups, jsc_key)
            zig_scaling = lane_count * zig_one / zig
            jsc_scaling = lane_count * jsc_one / jsc
            ratio = zig / jsc
            if lane_count == max_lanes:
                cold_max_ratios.append(ratio)
                zig_cold_max_scaling.append(zig_scaling)
                jsc_cold_max_scaling.append(jsc_scaling)
            lines.append(
                f"| `{workload}` | {lane_count} | {jobs} | {zig / 1e6:.3f} | {zig_min / 1e6:.3f}–{zig_max / 1e6:.3f} | {zig_rsd:.2f}% | "
                f"{jsc / 1e6:.3f} | {jsc_min / 1e6:.3f}–{jsc_max / 1e6:.3f} | {jsc_rsd:.2f}% | {ratio:.2f}x | {zig_scaling:.2f}x | {jsc_scaling:.2f}x |"
            )

    lines.extend([
        "",
        "## zig-js shared-realm scaling",
        "",
        "This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.",
        "The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same",
        "shared-realm path at one lane, so thread lifecycle overhead is present in every row.",
        "",
        "| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    zig_shared_max_scaling: list[float] = []
    for workload in WORKLOADS:
        jobs = next(row.jobs for row in rows if row.workload == workload)
        zig_one = median_ns(groups, ("zig-js", "shared", workload, 1, jobs))
        for lane_count in all_lanes:
            key = ("zig-js", "shared", workload, lane_count, jobs)
            zig = median_ns(groups, key)
            zig_min, zig_max, zig_rsd = spread(groups, key)
            zig_scaling = lane_count * zig_one / zig
            if lane_count == max_lanes:
                zig_shared_max_scaling.append(zig_scaling)
            lines.append(
                f"| `{workload}` | {lane_count} | {jobs} | {zig / 1e6:.3f} | "
                f"{zig_min / 1e6:.3f}–{zig_max / 1e6:.3f} | {zig_rsd:.2f}% | {zig_scaling:.2f}x |"
            )

    lines.extend([
        "",
        "## Reading the result",
        "",
        f"Across these {len(WORKLOADS)} deliberately small kernels, JSC's single-context throughput is {geometric_mean(single_ratios):.2f}x",
        "the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that",
        "zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.",
        "The number is a compact description of this matrix, not a claim about applications or unsupported workloads.",
        "",
        f"At {max_lanes} independent warmed contexts, JSC throughput is {geometric_mean(steady_max_ratios):.2f}x zig-js by",
        f"geometric mean; scaling from the mode's own one-lane baseline is {geometric_mean(zig_steady_max_scaling):.2f}x",
        f"for zig-js and {geometric_mean(jsc_steady_max_scaling):.2f}x for JSC. In the symmetric cold lifecycle, JSC",
        f"throughput is {geometric_mean(cold_max_ratios):.2f}x zig-js, with {geometric_mean(zig_cold_max_scaling):.2f}x",
        f"and {geometric_mean(jsc_cold_max_scaling):.2f}x scaling respectively.",
        "",
        f"zig-js's shared-realm path scales {geometric_mean(zig_shared_max_scaling):.2f}x at {max_lanes} lanes from its",
        "own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes",
        "isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows",
        "matter more than any aggregate.",
        "",
        "## Method and timed boundaries",
        "",
        "- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.",
        "- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.",
        "- Every measured zig-js context uses the process-wide thread-safe libc allocator, whose reusable infrastructure outlives timed cold contexts; cold mode still times every context-owned allocation and release. JSC uses its internal process allocator.",
        "- Single mode evaluates the workload source, configures the context, and performs three reduced-size warm-up calls before timing one host evaluation call per sample.",
        "- Independent steady mode uses the same persistent-worker protocol in both runners. Every worker creates, configures, and warms its own thread-affine context before measurement. Each timer includes semaphore dispatch, one invocation per lane, and completion waits; worker/context teardown follows all samples.",
        "- Independent cold mode performs no warm-up. Every timer includes OS-thread spawn, worker-owned context creation, workload-source evaluation and configuration, one invocation, context destruction, and OS-thread join.",
        "- Shared mode prepares and warms one zig-js shared realm outside the timer. Every timed sample creates and joins the requested JavaScript `Thread`s. Its one-lane row is the scaling baseline.",
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
    try:
        ensure_publishable(info, publishing)
    except ValueError as error:
        parser.error(str(error))

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
