#!/usr/bin/env python3
"""Benchmark zig-js and system JSC WebAssembly SIMD against scalar oracles."""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import datetime as dt
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
RUNNERS = {
    "zig-js": ROOT / "zig-out/bin/bench-comparison-zig-js",
    "JavaScriptCore": ROOT / "zig-out/bin/bench-comparison-jsc",
}
BASE_ITERATIONS = {
    "integer": 20_000,
    "float": 20_000,
    "shuffle": 4_000,
    "memory": 20_000,
}
JOBS = {
    "wasm_integer_simd": 200,
    "wasm_integer_scalar": 160,
    "wasm_float_simd": 180,
    "wasm_float_scalar": 180,
    "wasm_shuffle_simd": 800,
    "wasm_shuffle_scalar": 35,
    "wasm_memory_simd": 180,
    "wasm_memory_scalar": 120,
}
FAMILIES = tuple(BASE_ITERATIONS)
KINDS = ("simd", "scalar")
MODES = ("single", "independent_steady")
PINNED_WABT = "1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95)"
MODULE_SHA256 = "5f33169c01f36873c1ac4ec8bb07675b8d4d770a6a4f3d961454f139f1818957"


@dataclass(frozen=True)
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


def output(command: list[str], fallback: str = "unavailable") -> str:
    try:
        return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        return fallback


def parse_rows(text: str) -> list[Row]:
    rows: list[Row] = []
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) != 8:
            raise ValueError(f"invalid runner row: {line!r}")
        rows.append(Row(
            engine=fields[0],
            mode=fields[1],
            workload=fields[2],
            lanes=int(fields[3]),
            jobs=int(fields[4]),
            sample=int(fields[5]),
            elapsed_ns=int(fields[6]),
            checksum=int(fields[7]),
        ))
    return rows


def run(engine: str, mode: str, workload: str, jobs: int, samples: int, lanes: int) -> list[Row]:
    command = [str(RUNNERS[engine]), mode, workload, str(jobs), str(samples)]
    if mode != "single":
        command.append(str(lanes))
    completed = subprocess.run(command, check=True, text=True, capture_output=True)
    rows = parse_rows(completed.stdout)
    expected_lanes = 1 if mode == "single" else lanes
    if len(rows) != samples:
        raise ValueError(f"{engine}/{mode}/{workload}: expected {samples} samples, got {len(rows)}")
    for sample, row in enumerate(rows):
        expected = (engine, mode, workload, expected_lanes, jobs, sample)
        actual = (row.engine, row.mode, row.workload, row.lanes, row.jobs, row.sample)
        if actual != expected:
            raise ValueError(f"runner metadata mismatch: expected {expected}, got {actual}")
        if row.elapsed_ns <= 0:
            raise ValueError(f"{engine}/{mode}/{workload}: non-positive elapsed time")
    if len({row.checksum for row in rows}) != 1:
        raise ValueError(f"{engine}/{mode}/{workload}: checksum changed between samples")
    return rows


def validate_oracles() -> None:
    checksums: dict[tuple[str, str], int] = {}
    for engine in RUNNERS:
        for family in FAMILIES:
            for kind in KINDS:
                workload = f"wasm_{family}_{kind}"
                checksums[engine, workload] = run(engine, "single", workload, 1, 1, 1)[0].checksum
            simd = checksums[engine, f"wasm_{family}_simd"]
            scalar = checksums[engine, f"wasm_{family}_scalar"]
            if simd != scalar:
                raise ValueError(f"{engine}/{family}: SIMD checksum {simd} != scalar oracle {scalar}")
        for workload in JOBS:
            other = "JavaScriptCore" if engine == "zig-js" else "zig-js"
            if (other, workload) in checksums and checksums[engine, workload] != checksums[other, workload]:
                raise ValueError(f"{workload}: cross-engine checksum mismatch")


def collect(samples: int, lanes: int, quick: bool) -> list[Row]:
    validate_oracles()
    rows: list[Row] = []
    ordinal = 0
    for mode in MODES:
        for family in FAMILIES:
            for kind in KINDS:
                workload = f"wasm_{family}_{kind}"
                jobs = 1 if quick else JOBS[workload]
                engines = tuple(RUNNERS)
                if ordinal & 1:
                    engines = tuple(reversed(engines))
                for engine in engines:
                    rows.extend(run(engine, mode, workload, jobs, samples, lanes))
                ordinal += 1
    return rows


def logical_updates(family: str, jobs: int, lanes: int) -> int:
    base = BASE_ITERATIONS[family]
    return sum(base + ((job + lane) & 15) for lane in range(lanes) for job in range(jobs))


def median_ns(groups: dict[tuple[str, str, str, int, int], list[Row]], key: tuple[str, str, str, int, int]) -> float:
    return statistics.median(row.elapsed_ns for row in groups[key])


def rate(groups: dict[tuple[str, str, str, int, int], list[Row]], engine: str, mode: str, family: str, kind: str, lanes: int) -> float:
    workload = f"wasm_{family}_{kind}"
    jobs = next(row.jobs for row in groups[next(key for key in groups if key[:3] == (engine, mode, workload))])
    key = (engine, mode, workload, lanes, jobs)
    return logical_updates(family, jobs, lanes) / (median_ns(groups, key) / 1e9)


def rsd(groups: dict[tuple[str, str, str, int, int], list[Row]], engine: str, mode: str, family: str, kind: str, lanes: int) -> float:
    workload = f"wasm_{family}_{kind}"
    key = next(key for key in groups if key[:4] == (engine, mode, workload, lanes))
    values = [row.elapsed_ns for row in groups[key]]
    return statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0


def revision() -> str:
    commit = output(["git", "-C", str(ROOT), "rev-parse", "HEAD"])
    relevant = [
        "bench/comparison_zig_js.zig",
        "bench/comparison_jsc.zig",
        "bench/wasm_simd_comparison.js",
        "bench/wasm_simd_kernels.wat",
        "tools/wasm-simd-benchmark.py",
    ]
    dirty = subprocess.run(
        ["git", "-C", str(ROOT), "status", "--porcelain", "--", *relevant],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()
    return commit + (" (benchmark inputs dirty)" if dirty else "")


def metadata() -> dict[str, str]:
    info = Path("/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist")
    memory = output(["sysctl", "-n", "hw.memsize"])
    memory_gib = f"{int(memory) / (1024 ** 3):.1f} GiB" if memory.isdigit() else memory
    return {
        "Date": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "Host": f"{output(['sysctl', '-n', 'machdep.cpu.brand_string'], platform.processor())}; "
                f"{output(['sysctl', '-n', 'hw.physicalcpu'])} physical / {output(['sysctl', '-n', 'hw.logicalcpu'])} logical CPUs; {memory_gib}",
        "OS": f"macOS {output(['sw_vers', '-productVersion'])} ({output(['sw_vers', '-buildVersion'])})",
        "Zig": output(["zig", "version"]),
        "zig-js": revision(),
        "JavaScriptCore": f"system framework {output(['plutil', '-extract', 'CFBundleVersion', 'raw', str(info)])}",
        "WABT source compiler": PINNED_WABT,
        "Wasm module SHA-256": MODULE_SHA256,
        "Power": " ".join(output(["pmset", "-g", "batt"]).split()),
    }


def render(rows: list[Row], lanes: int, info: dict[str, str]) -> str:
    groups: dict[tuple[str, str, str, int, int], list[Row]] = defaultdict(list)
    for row in rows:
        groups[row.key].append(row)
    lines = [
        f"# WebAssembly SIMD comparison — {info['Date'][:10]}",
        "",
        "> Dated measurement, not a universal engine score. Lower elapsed time and higher throughput are better.",
        "> Every SIMD kernel has a byte-identical-module scalar oracle; the harness rejects checksum disagreement.",
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
        "## SIMD throughput",
        "",
        "Throughput is millions of logical 128-bit state updates per second, normalized by the exact inner-loop count.",
        f"The `{lanes}-thread` rows use `{lanes}` warmed, independent contexts and module instances on persistent OS workers.",
        "",
        "| family | zig-js 1-thread | zig-js {0}-thread | zig-js scaling | JSC 1-thread | JSC {0}-thread | JSC scaling | zig-js / JSC, 1-thread | zig-js / JSC, {0}-thread | max RSD |".format(lanes),
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for family in FAMILIES:
        z1 = rate(groups, "zig-js", "single", family, "simd", 1)
        zm = rate(groups, "zig-js", "independent_steady", family, "simd", lanes)
        j1 = rate(groups, "JavaScriptCore", "single", family, "simd", 1)
        jm = rate(groups, "JavaScriptCore", "independent_steady", family, "simd", lanes)
        dispersion = max(
            rsd(groups, engine, mode, family, "simd", 1 if mode == "single" else lanes)
            for engine in RUNNERS for mode in MODES
        )
        lines.append(
            f"| `{family}` | {z1 / 1e6:.2f} M/s | {zm / 1e6:.2f} M/s | {zm / z1:.2f}x | "
            f"{j1 / 1e6:.2f} M/s | {jm / 1e6:.2f} M/s | {jm / j1:.2f}x | {z1 / j1:.2f}x | {zm / jm:.2f}x | {dispersion:.2f}% |"
        )
    lines.extend([
        "",
        "## SIMD speedup over the scalar oracle",
        "",
        "Each cell is SIMD logical-update throughput divided by its semantically equivalent scalar export.",
        "Values above `1.00x` favor SIMD; the scalar path deliberately performs the same lane work without vector instructions.",
        "",
        "| family | zig-js 1-thread | zig-js {0}-thread | JSC 1-thread | JSC {0}-thread |".format(lanes),
        "| --- | ---: | ---: | ---: | ---: |",
    ])
    for family in FAMILIES:
        values = []
        for engine in RUNNERS:
            for mode, lane_count in (("single", 1), ("independent_steady", lanes)):
                values.append(rate(groups, engine, mode, family, "simd", lane_count) / rate(groups, engine, mode, family, "scalar", lane_count))
        lines.append(f"| `{family}` | {values[0]:.2f}x | {values[1]:.2f}x | {values[2]:.2f}x | {values[3]:.2f}x |")
    medians_ms = [statistics.median(row.elapsed_ns for row in group) / 1e6 for group in groups.values()]
    lines.extend([
        "",
        "## Method and boundaries",
        "",
        f"The run contains {len(rows):,} raw samples ({len(groups)} scored rows). Each row is sampled independently; engine launch order alternates by workload.",
        f"Scored-row medians span {min(medians_ms):.1f}–{max(medians_ms):.1f} ms. The timer excludes process launch, source evaluation, module compilation/instantiation, and three warm-up invocations.",
        "Single-thread timing covers only `__benchmarkSelected(jobs, lane)`. Multi-thread timing covers symmetric semaphore dispatch, one invocation per persistent worker, and the completion wait.",
        "The two engines receive the exact same JavaScript, Wasm bytes, job counts, and logical update counts. Independent contexts are the common public-API concurrency model; zig-js shared-realm Threads are intentionally outside this cross-engine panel.",
        "The integer kernel uses `i32x4.add/mul`; float uses `f32x4.add/mul`; shuffle rotates all 16 bytes with `i8x16.shuffle`; memory uses aligned `v128.load/store`. Scalar exports live in the same module and return identical checksums.",
        "",
        "## Reproduce",
        "",
        "```sh",
        "zig build benchmark-comparison-bin -Doptimize=ReleaseFast",
        f"python3 tools/wasm-simd-benchmark.py --samples {len(next(iter(groups.values())))} --lanes {lanes} \\",
        "  --raw-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.tsv \\",
        "  --markdown-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.md",
        "```",
        "",
        "Regenerate the embedded module after editing the readable source:",
        "",
        "```sh",
        "wat2wasm --enable-all bench/wasm_simd_kernels.wat -o /tmp/wasm_simd_kernels.wasm",
        "shasum -a 256 /tmp/wasm_simd_kernels.wasm",
        "```",
        "",
    ])
    return "\n".join(lines)


def write_raw(rows: list[Row], path: Path) -> None:
    lines = ["engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum"]
    lines.extend(
        f"{row.engine}\t{row.mode}\t{row.workload}\t{row.lanes}\t{row.jobs}\t{row.sample}\t{row.elapsed_ns}\t{row.checksum}"
        for row in rows
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--lanes", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--raw-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()
    if args.samples <= 0 or args.lanes <= 1:
        parser.error("--samples must be positive and --lanes must be greater than one")
    for runner in RUNNERS.values():
        if not runner.is_file():
            parser.error(f"missing {runner}; run `zig build benchmark-comparison-bin -Doptimize=ReleaseFast`")
    rows = collect(1 if args.quick else args.samples, args.lanes, args.quick)
    info = metadata()
    report = render(rows, args.lanes, info)
    if args.raw_out:
        write_raw(rows, args.raw_out)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(report)
    else:
        print(report)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"wasm-simd-benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
