#!/usr/bin/env python3
"""Benchmark zig-js WebAssembly Threads kernels and document the JSC boundary."""

from __future__ import annotations

import argparse
from collections import defaultdict
from dataclasses import dataclass
import datetime as dt
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
WORKLOADS = (
    "wasm_threads_atomic_add",
    "wasm_threads_atomic_cas",
    "wasm_threads_atomic_disjoint",
)
LABELS = {
    "wasm_threads_atomic_add": "contended atomic add",
    "wasm_threads_atomic_cas": "contended CAS increment",
    "wasm_threads_atomic_disjoint": "disjoint atomic add",
}
JOBS = {
    "wasm_threads_atomic_add": 900_000,
    "wasm_threads_atomic_cas": 500_000,
    "wasm_threads_atomic_disjoint": 850_000,
    "wasm_threads_wait_notify": 30_000,
}
PINNED_WABT = "1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95)"
MODULE_SHA256 = "890076044756dcfb67445614cd08d0c73de9529e500d7ec13eeca424ae230d57"


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
    def key(self) -> tuple[str, str, int, int]:
        return self.mode, self.workload, self.lanes, self.jobs


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
        rows.append(Row(fields[0], fields[1], fields[2], int(fields[3]),
                        int(fields[4]), int(fields[5]), int(fields[6]), int(fields[7])))
    return rows


def run(runner: Path, mode: str, workload: str, jobs: int, samples: int, lanes: int) -> list[Row]:
    command = [str(runner), mode, workload, str(jobs), str(samples)]
    if mode != "single":
        command.append(str(lanes))
    completed = subprocess.run(command, check=True, text=True, capture_output=True, timeout=120)
    rows = parse_rows(completed.stdout)
    expected_lanes = 1 if mode == "single" else lanes
    if len(rows) != samples:
        raise ValueError(f"{mode}/{workload}: expected {samples} samples, got {len(rows)}")
    expected_checksum = jobs * expected_lanes
    for sample, row in enumerate(rows):
        expected = ("zig-js", mode, workload, expected_lanes, jobs, sample)
        actual = (row.engine, row.mode, row.workload, row.lanes, row.jobs, row.sample)
        if actual != expected:
            raise ValueError(f"runner metadata mismatch: expected {expected}, got {actual}")
        if row.elapsed_ns <= 0 or row.checksum != expected_checksum:
            raise ValueError(f"{mode}/{workload}: invalid timing/checksum {row}")
    return rows


def probe_jsc(runner: Path) -> tuple[str, str]:
    sab = output(["osascript", "-l", "JavaScript", "-e",
                  "typeof WebAssembly + ':' + typeof SharedArrayBuffer"])
    command = [str(runner), "single", "wasm_threads_atomic_add", "1", "1"]
    rejected = subprocess.run(command, text=True, capture_output=True).returncode != 0
    if not rejected:
        raise ValueError("system JSC unexpectedly accepted the shared-memory module; add equivalent scored rows")
    return sab, "rejected with JavaScriptException"


def collect(runner: Path, samples: int, lanes: tuple[int, ...], quick: bool) -> list[Row]:
    rows: list[Row] = []
    for workload in WORKLOADS:
        jobs = 10 if quick else JOBS[workload]
        rows.extend(run(runner, "single", workload, jobs, samples, 1))
        for lane_count in lanes:
            rows.extend(run(runner, "shared", workload, jobs, samples, lane_count))
    wait_jobs = 2 if quick else JOBS["wasm_threads_wait_notify"]
    for lane_count in lanes:
        rows.extend(run(runner, "shared", "wasm_threads_wait_notify", wait_jobs, samples, lane_count))
    return rows


def revision() -> str:
    commit = output(["git", "-C", str(ROOT), "rev-parse", "HEAD"])
    relevant = [
        "bench/comparison_zig_js.zig", "bench/comparison_jsc.zig",
        "bench/wasm_threads_comparison.js", "bench/wasm_threads_kernels.wat",
        "tools/wasm-threads-benchmark.py", "build.zig",
    ]
    dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--", *relevant],
                           check=True, text=True, capture_output=True).stdout.strip()
    return commit + (" (benchmark inputs dirty)" if dirty else "")


def metadata() -> dict[str, str]:
    info = Path("/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist")
    memory = output(["sysctl", "-n", "hw.memsize"])
    memory_gib = f"{int(memory) / (1024 ** 3):.1f} GiB" if memory.isdigit() else memory
    return {
        "Date": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "Host": f"{output(['sysctl', '-n', 'machdep.cpu.brand_string'], platform.processor())}; "
                f"{output(['sysctl', '-n', 'hw.physicalcpu'])} physical / "
                f"{output(['sysctl', '-n', 'hw.logicalcpu'])} logical CPUs; {memory_gib}",
        "OS": f"macOS {output(['sw_vers', '-productVersion'])} ({output(['sw_vers', '-buildVersion'])})",
        "Zig": output(["zig", "version"]),
        "zig-js": revision(),
        "JavaScriptCore": f"system framework {output(['plutil', '-extract', 'CFBundleVersion', 'raw', str(info)])}",
        "WABT source compiler": PINNED_WABT,
        "Wasm module SHA-256": MODULE_SHA256,
        "Power": " ".join(output(["pmset", "-g", "batt"]).split()),
    }


def median(group: list[Row]) -> float:
    return statistics.median(row.elapsed_ns for row in group)


def rsd(group: list[Row]) -> float:
    values = [row.elapsed_ns for row in group]
    return statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0


def render(rows: list[Row], lanes: tuple[int, ...], info: dict[str, str], jsc_probe: tuple[str, str]) -> str:
    groups: dict[tuple[str, str, int, int], list[Row]] = defaultdict(list)
    for row in rows:
        groups[row.key].append(row)
    lines = [
        f"# WebAssembly Threads comparison — {info['Date'][:10]}", "",
        "> Dated measurement, not a universal engine score. Higher throughput is better.",
        "> Checksums, generation counts, timeouts, and the 120-second per-run watchdog are validated by the harness.",
        "", "## Environment", "", "| item | value |", "| --- | --- |",
    ]
    for key, value in info.items():
        lines.append(f"| {key} | {value} |")
    lines.extend([
        "", "## Atomic throughput", "",
        "Each operation is executed inside the same shared Wasm module. `1` worker calls the export on the owner thread; multi-worker rows spawn zig-js shared-realm `Thread`s that contend on the same instance and memory.",
        "", "| kernel | workers | median | operations/s | scaling vs 1 | RSD |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for workload in WORKLOADS:
        single_key = ("single", workload, 1, next(k[3] for k in groups if k[:3] == ("single", workload, 1)))
        single_group = groups[single_key]
        single_rate = single_key[3] / (median(single_group) / 1e9)
        for mode, lane_count in (("single", 1), *(("shared", n) for n in lanes)):
            key = next(k for k in groups if k[:3] == (mode, workload, lane_count))
            group = groups[key]
            rate = key[3] * lane_count / (median(group) / 1e9)
            lines.append(f"| {LABELS[workload]} | {lane_count} | {median(group) / 1e6:.2f} ms | "
                         f"{rate / 1e6:.2f} M/s | {rate / single_rate:.2f}x | {rsd(group):.2f}% |")
    lines.extend([
        "", "## Wait/notify handoffs", "",
        "Workers are paired. Each generation increments a request counter, parks with `memory.atomic.wait32`, increments an acknowledgement counter, and wakes with `memory.atomic.notify`; the harness rejects timeouts or mismatched final generations.",
        "", "| workers | median | pair handoffs/s | RSD |", "| ---: | ---: | ---: | ---: |",
    ])
    for lane_count in lanes:
        key = next(k for k in groups if k[:3] == ("shared", "wasm_threads_wait_notify", lane_count))
        group = groups[key]
        handoffs = key[3] * lane_count / 2
        lines.append(f"| {lane_count} | {median(group) / 1e6:.2f} ms | "
                     f"{handoffs / (median(group) / 1e9):,.0f} | {rsd(group):.2f}% |")
    lines.extend([
        "", "## JavaScriptCore comparison boundary", "",
        "The system JSC public embedding API was probed before scoring. There is no equivalent row to report for this module:",
        "", "| probe | result |", "| --- | --- |",
        f"| automation JavaScript context (`typeof WebAssembly:typeof SharedArrayBuffer`) | `{jsc_probe[0]}` |",
        f"| shared-memory/atomic module through `JSGlobalContext` | {jsc_probe[1]} |",
        "| equivalent shared-realm worker API | not present in the public C API |",
        "", "JSC is therefore `N/A`, not zero and not slower. The main README comparison separately scores zig-js and system JSC for equivalent single and independent-context workloads.",
        "", "## Method and timing boundary", "",
        f"The artifact contains {len(rows):,} raw samples across {len(groups)} rows. Module decoding, validation, instantiation, JavaScript setup, and warm-up are outside the timer.",
        "Single-worker rows time one selected Wasm invocation. Multi-worker rows deliberately include shared-realm `Thread` construction, dispatch, joins, and the final checksum/generation validation; every worker executes the displayed per-worker job count.",
        "Contended add targets word zero. CAS retries until each requested increment commits. Disjoint add assigns one cache-adjacent word per worker. Wait/notify uses two monotonic words per pair so scheduling delays cannot lose a generation.",
        "", "## Reproduce", "", "```sh",
        "zig build wasm-threads-benchmark -Doptimize=ReleaseFast",
        "zig build wasm-threads-benchmark -Doptimize=ReleaseFast -Dwasm-threads-benchmark-quick=true",
        "```", "", "Regenerate the embedded module after editing its readable source:", "", "```sh",
        "wat2wasm --enable-threads bench/wasm_threads_kernels.wat -o /tmp/wasm_threads_kernels.wasm",
        "shasum -a 256 /tmp/wasm_threads_kernels.wasm", "```", "",
    ])
    return "\n".join(lines)


def write_raw(rows: list[Row], path: Path) -> None:
    lines = ["engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum"]
    lines.extend(f"{r.engine}\t{r.mode}\t{r.workload}\t{r.lanes}\t{r.jobs}\t{r.sample}\t{r.elapsed_ns}\t{r.checksum}" for r in rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zig_runner", nargs="?", type=Path, default=ROOT / "zig-out/bin/bench-comparison-zig-js")
    parser.add_argument("jsc_runner", nargs="?", type=Path, default=ROOT / "zig-out/bin/bench-comparison-jsc")
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--lanes", default=",".join(map(str, (2, 4, min(8, os.cpu_count() or 2)))))
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--raw-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()
    lanes = tuple(dict.fromkeys(int(value) for value in args.lanes.split(",")))
    if args.samples <= 0 or not lanes or any(value < 2 or value % 2 for value in lanes):
        parser.error("--samples must be positive and --lanes must contain even integers >= 2")
    if not args.zig_runner.is_file() or not args.jsc_runner.is_file():
        parser.error("missing comparison runner; build benchmark-comparison-bin first")
    samples = 1 if args.quick else args.samples
    jsc_probe = probe_jsc(args.jsc_runner)
    rows = collect(args.zig_runner, samples, lanes, args.quick)
    report = render(rows, lanes, metadata(), jsc_probe)
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
    except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"wasm-threads-benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
