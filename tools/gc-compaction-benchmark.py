#!/usr/bin/env python3
"""Run and publish the deterministic explicit-compaction fragmentation benchmark."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
from pathlib import Path
import platform
import statistics
import subprocess


ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Row:
    mode: str
    sample: int
    dead: int
    live: int
    probe_rounds: int
    probe_ns: int
    checksum: int
    action_ns: int
    before_chunks: int
    after_chunks: int
    before_capacity_bytes: int
    after_capacity_bytes: int
    before_live_slots: int
    after_live_slots: int
    moved_cells: int
    moved_bytes: int
    action_status: str
    fixed_status: str
    fixed_ns: int


HEADER = "\t".join(Row.__annotations__)


def output(command: list[str], fallback: str = "unavailable") -> str:
    try:
        return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        return fallback


def parse_row(text: str) -> Row:
    lines = [line for line in text.splitlines() if line]
    if len(lines) != 1:
        raise ValueError(f"expected one runner row, got {lines!r}")
    fields = lines[0].split("\t")
    if len(fields) != len(Row.__annotations__):
        raise ValueError(f"invalid runner row: {lines[0]!r}")
    numeric = [int(value) for value in fields[1:16]]
    return Row(fields[0], *numeric, fields[16], fields[17], int(fields[18]))


def run(runner: Path, mode: str, dead: int, live: int, probe_rounds: int, sample: int) -> Row:
    command = [str(runner), mode, str(dead), str(live), str(probe_rounds), str(sample)]
    completed = subprocess.run(command, check=True, text=True, capture_output=True, timeout=120)
    return parse_row(completed.stdout)


def validate_row(row: Row) -> None:
    if row.mode not in {"control", "compact"}:
        raise ValueError(f"invalid mode: {row.mode}")
    if row.probe_ns <= 0 or row.action_ns <= 0 or row.checksum != row.probe_rounds * row.live * row.live:
        raise ValueError(f"invalid timing/checksum: {row}")
    if row.before_live_slots != row.after_live_slots:
        raise ValueError(f"live-slot drift: {row}")
    if row.after_chunks > row.before_chunks or row.after_capacity_bytes > row.before_capacity_bytes:
        raise ValueError(f"backing grew: {row}")
    if row.mode == "control":
        if (row.moved_cells, row.moved_bytes, row.action_status, row.fixed_status, row.fixed_ns) != (0, 0, "control", "not_run", 0):
            raise ValueError(f"invalid control result: {row}")
        if (row.after_chunks, row.after_capacity_bytes) != (row.before_chunks, row.before_capacity_bytes):
            raise ValueError(f"stable control backing changed: {row}")
    else:
        if row.action_status != "compacted" or row.fixed_status != "no_candidates":
            raise ValueError(f"compaction did not reach a dense fixed point: {row}")
        if row.moved_cells <= 0 or row.moved_bytes <= 0 or row.fixed_ns <= 0:
            raise ValueError(f"compaction did not move cells: {row}")
        if row.after_chunks >= row.before_chunks or row.after_capacity_bytes >= row.before_capacity_bytes:
            raise ValueError(f"compaction did not reduce backing: {row}")


def collect(runner: Path, samples: int, dead: int, live: int, probe_rounds: int) -> list[Row]:
    rows: list[Row] = []
    for sample in range(samples):
        modes = ("control", "compact") if sample % 2 == 0 else ("compact", "control")
        for mode in modes:
            row = run(runner, mode, dead, live, probe_rounds, sample)
            validate_row(row)
            rows.append(row)
    rows.sort(key=lambda row: (row.mode, row.sample))
    for sample in range(samples):
        control = next(row for row in rows if row.mode == "control" and row.sample == sample)
        compact = next(row for row in rows if row.mode == "compact" and row.sample == sample)
        if (control.before_chunks, control.before_capacity_bytes, control.before_live_slots) != (
            compact.before_chunks, compact.before_capacity_bytes, compact.before_live_slots
        ):
            raise ValueError(f"sample {sample} started from unequal heaps")
    return rows


def revision(path: Path) -> str:
    commit = output(["git", "-C", str(path), "rev-parse", "HEAD"])
    dirty = output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"], "")
    return commit + (" (tracked worktree dirty)" if dirty else "")


def metadata() -> dict[str, str]:
    memory = output(["sysctl", "-n", "hw.memsize"])
    memory_gib = f"{int(memory) / (1024 ** 3):.1f} GiB" if memory.isdigit() else memory
    return {
        "Date": dt.date.today().isoformat(),
        "Host": f"{output(['sysctl', '-n', 'machdep.cpu.brand_string'], platform.processor())}; "
                f"{output(['sysctl', '-n', 'hw.physicalcpu'])} physical / "
                f"{output(['sysctl', '-n', 'hw.logicalcpu'])} logical CPUs; {memory_gib}",
        "OS": f"macOS {output(['sw_vers', '-productVersion'], platform.platform())} "
              f"({output(['sw_vers', '-buildVersion'])})",
        "Zig": output(["zig", "version"]),
        "zig-js": revision(ROOT),
        "zig-gc": revision(ROOT.parent / "zig-gc"),
        "zig-regex": revision(ROOT.parent / "zig-regex"),
        "Power": " ".join(output(["pmset", "-g", "batt"]).split()),
    }


def rsd(values: list[int]) -> float:
    return statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0


def validate_matrix(rows: list[Row], samples: int, quick: bool) -> None:
    for mode in ("control", "compact"):
        group = [row for row in rows if row.mode == mode]
        if [row.sample for row in group] != list(range(samples)):
            raise ValueError(f"invalid {mode} sample indexes")
    if quick:
        return
    control = [row.probe_ns for row in rows if row.mode == "control"]
    compact = [row.probe_ns for row in rows if row.mode == "compact"]
    ratio = statistics.median(control) / statistics.median(compact)
    if ratio < 0.90 and rsd(control) <= 5.0 and rsd(compact) <= 5.0:
        raise ValueError(f"stable post-compaction probe regression exceeds 10%: {ratio:.3f}x")


def render(rows: list[Row], info: dict[str, str], raw_path: Path | None) -> str:
    control = [row for row in rows if row.mode == "control"]
    compact = [row for row in rows if row.mode == "compact"]
    c0, c1 = control[0], compact[0]
    capacity_reduction = 1 - c1.after_capacity_bytes / c0.after_capacity_bytes
    chunk_reduction = 1 - c1.after_chunks / c0.after_chunks
    probe_ratio = statistics.median(row.probe_ns for row in control) / statistics.median(row.probe_ns for row in compact)
    lines = [
        f"# GC fragmentation and compaction — {info['Date']}", "",
        "> Dated explicit-compaction evidence, not a general application benchmark.",
        "> Identical heaps, checksums, live-slot counts, alternating process order, and the dense second-pass fixed point are enforced by the harness.",
        "", "## Environment", "", "| item | value |", "| --- | --- |",
    ]
    lines.extend(f"| {key} | {value} |" for key, value in info.items())
    lines.extend([
        "", "## Result", "",
        "| result | non-moving control | explicit compaction | change |",
        "| --- | ---: | ---: | ---: |",
        f"| retained backing | {c0.after_capacity_bytes / 1048576:.2f} MiB | {c1.after_capacity_bytes / 1048576:.2f} MiB | **-{capacity_reduction * 100:.1f}%** |",
        f"| retained chunks | {c0.after_chunks} | {c1.after_chunks} | **-{chunk_reduction * 100:.1f}%** |",
        f"| live slots | {c0.after_live_slots} | {c1.after_live_slots} | unchanged |",
        f"| action median | {statistics.median(row.action_ns for row in control) / 1e6:.3f} ms | {statistics.median(row.action_ns for row in compact) / 1e6:.3f} ms | compaction pause |",
        f"| post-action probe median | {statistics.median(row.probe_ns for row in control) / 1e6:.3f} ms | {statistics.median(row.probe_ns for row in compact) / 1e6:.3f} ms | {probe_ratio:.2f}x compact/control throughput |",
        "", "Every compact sample moved tail cells, reduced both retained metrics, preserved the exact live-slot count and checksum, and returned `no_candidates` with zero movement on its immediate second pass.",
        "", "## Workload and method", "",
        f"Each fresh context allocates {c0.dead:,} retained two-object records followed by {c0.live:,} retained two-object records, drops the first group, and performs a precise collection. The control performs another non-moving collection; the compact row calls explicit stop-the-world compaction. Process order alternates for {len(control)} samples.",
        f"The untimed integrity setup is followed by {c0.probe_rounds:,} complete reads of the retained graph. The expected integer checksum is `{c0.checksum}`. The harness rejects backing growth, unequal starting heaps, live-slot drift, movement/fixed-point failures, and stable probe regressions over 10%.",
        f"Raw evidence: [{raw_path.name}]({raw_path.name})" if raw_path else "Raw evidence was printed only; pass --raw-out to preserve it.",
        "", "## Dispersion", "", "| mode | action RSD | probe RSD |", "| --- | ---: | ---: |",
        f"| non-moving control | {rsd([row.action_ns for row in control]):.2f}% | {rsd([row.probe_ns for row in control]):.2f}% |",
        f"| explicit compaction | {rsd([row.action_ns for row in compact]):.2f}% | {rsd([row.probe_ns for row in compact]):.2f}% |",
        "", "## Reproduce", "", "```sh",
        "zig build gc-compaction-benchmark -Doptimize=ReleaseFast",
        "zig build gc-compaction-benchmark -Dgc-compaction-benchmark-quick=true",
        "```", "",
    ])
    return "\n".join(lines)


def write_raw(rows: list[Row], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [HEADER]
    lines.extend("\t".join(str(getattr(row, name)) for name in Row.__annotations__) for row in rows)
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runner", type=Path)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--dead", type=int, default=32768)
    parser.add_argument("--live", type=int, default=2048)
    parser.add_argument("--probe-rounds", type=int, default=1000)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--raw-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()
    if args.quick:
        args.samples, args.dead, args.live, args.probe_rounds = 1, 1024, 128, 10
    if min(args.samples, args.dead, args.live, args.probe_rounds) <= 0:
        parser.error("sample and workload sizes must be positive")

    info = metadata()
    if (args.raw_out or args.markdown_out) and any(value.endswith(" (tracked worktree dirty)") for value in info.values()):
        raise ValueError("refusing to publish benchmark evidence from a dirty tracked worktree")
    rows = collect(args.runner.resolve(), args.samples, args.dead, args.live, args.probe_rounds)
    validate_matrix(rows, args.samples, args.quick)
    if args.raw_out:
        write_raw(rows, args.raw_out)
    report = render(rows, info, args.raw_out)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(report)
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
