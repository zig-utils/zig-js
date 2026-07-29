#!/usr/bin/env python3
"""Run and publish the generational nursery policy benchmark."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
from pathlib import Path
import platform
import statistics
import subprocess


ROOT = Path(__file__).resolve().parent.parent
MIB = 1024 * 1024
README_START = "<!-- gc-generation:start -->"
README_END = "<!-- gc-generation:end -->"


@dataclass(frozen=True)
class Row:
    trigger: str
    scenario: str
    tenuring_age: int
    moving: int
    trigger_bytes: int
    sample: int
    rounds: int
    batch: int
    elapsed_ns: int
    checksum: int
    minor_collections: int
    full_collections: int
    young_input_bytes: int
    survived_bytes: int
    reclaimed_bytes: int
    promoted_bytes: int
    moving_minor_collections: int
    moved_cells: int
    moved_bytes: int
    move_failures: int
    live_bytes: int
    young_bytes: int
    next_threshold_bytes: int
    backing_chunks: int
    backing_capacity_bytes: int
    pause_total_ns: int
    pause_max_ns: int
    cooperative_attempts: int
    cooperative_collections: int
    cooperative_parks: int
    cooperative_timeouts: int


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
        raise ValueError(f"invalid runner row with {len(fields)} fields: {lines[0]!r}")
    return Row(fields[0], fields[1], *(int(value) for value in fields[2:]))


def run(
    runner: Path,
    trigger: str,
    scenario: str,
    age: int,
    moving: int,
    trigger_bytes: int,
    rounds: int,
    batch: int,
    sample: int,
) -> Row:
    command = [
        str(runner), trigger, scenario, str(age), str(moving), str(trigger_bytes),
        str(rounds), str(batch), str(sample),
    ]
    try:
        completed = subprocess.run(command, check=True, text=True, capture_output=True, timeout=180)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            f"runner failed with exit {error.returncode}: {' '.join(command)}\n"
            f"stdout:\n{error.stdout or '<empty>'}\n"
            f"stderr:\n{error.stderr or '<empty>'}"
        ) from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"runner timed out after {error.timeout}s: {' '.join(command)}") from error
    return parse_row(completed.stdout)


def validate_row(row: Row, quick: bool) -> None:
    if row.trigger not in {"forced", "automatic", "shared"}:
        raise ValueError(f"invalid trigger: {row.trigger}")
    if (
        row.scenario not in {"ephemeral", "mixed", "high"}
        or row.tenuring_age not in {1, 3}
        or row.moving not in {0, 1}
    ):
        raise ValueError(f"invalid policy row: {row}")
    expected = row.rounds * row.batch * row.batch * (3 if row.trigger == "shared" else 1)
    if row.checksum != expected or row.elapsed_ns <= 0:
        raise ValueError(f"checksum/timing failure: {row}")
    if not quick and row.elapsed_ns < 50_000_000:
        raise ValueError(f"sample is below the 50 ms timing floor: {row}")
    expected_full_collections = 1 if row.trigger == "shared" and row.moving else 0
    if row.minor_collections <= 0 or row.full_collections != expected_full_collections:
        raise ValueError(f"invalid collection mix: {row}")
    if row.young_input_bytes != row.survived_bytes + row.reclaimed_bytes:
        raise ValueError(f"minor byte conservation failure: {row}")
    if row.promoted_bytes > row.survived_bytes or row.pause_total_ns < row.pause_max_ns or row.pause_max_ns <= 0:
        raise ValueError(f"invalid promotion/pause telemetry: {row}")
    movement = (
        row.moving_minor_collections,
        row.moved_cells,
        row.moved_bytes,
        row.move_failures,
    )
    if row.moving:
        if min(movement[:3]) <= 0 or row.move_failures != 0:
            raise ValueError(f"invalid moving-minor telemetry: {row}")
    elif movement != (0, 0, 0, 0):
        raise ValueError(f"unexpected moving-minor telemetry: {row}")
    if row.next_threshold_bytes < 4 * MIB or row.backing_chunks <= 0 or row.backing_capacity_bytes <= 0:
        raise ValueError(f"invalid heap telemetry: {row}")
    cooperative = (
        row.cooperative_attempts,
        row.cooperative_collections,
        row.cooperative_parks,
        row.cooperative_timeouts,
    )
    if row.trigger == "shared":
        timeout_limit = 2 if row.moving else 0
        if (
            min(cooperative[:3]) <= 0
            or cooperative[1] > cooperative[0]
            or cooperative[3] > timeout_limit
        ):
            raise ValueError(f"invalid cooperative rendezvous: {row}")
    elif cooperative != (0, 0, 0, 0):
        raise ValueError(f"unexpected cooperative telemetry: {row}")


def configurations(quick: bool) -> list[tuple[str, str, int, int, int, int]]:
    if quick:
        return [
            ("forced", scenario, moving, 4 * MIB, 4, 2048)
            for scenario in ("ephemeral", "mixed", "high")
            for moving in (0, 1)
        ] + [
            ("shared", "mixed", moving, 43 * MIB, 4, 8000)
            for moving in (0, 1)
        ]
    return [
        ("forced", scenario, moving, threshold, 8, 24576)
        for scenario in ("ephemeral", "mixed", "high")
        for threshold in (4 * MIB,)
        for moving in (0, 1)
    ] + [
        ("shared", "mixed", moving, tranche, 6, 8000)
        for tranche in (43 * MIB,)
        for moving in (0, 1)
    ]


def collect(runner: Path, samples: int, warmups: int, quick: bool) -> list[Row]:
    rows: list[Row] = []
    for trigger, scenario, moving, trigger_bytes, rounds, batch in configurations(quick):
        for warmup in range(warmups):
            for age in (1, 3):
                validate_row(
                    run(runner, trigger, scenario, age, moving, trigger_bytes, rounds, batch, warmup),
                    quick,
                )
        for sample in range(samples):
            ages = (1, 3) if sample % 2 == 0 else (3, 1)
            for age in ages:
                row = run(runner, trigger, scenario, age, moving, trigger_bytes, rounds, batch, sample)
                validate_row(row, quick)
                rows.append(row)
    rows.sort(
        key=lambda row: (
            row.trigger,
            row.scenario,
            row.trigger_bytes,
            row.moving,
            row.tenuring_age,
            row.sample,
        )
    )
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
        "Power": " ".join(output(["pmset", "-g", "batt"]).split()),
    }


def rsd(values: list[int]) -> float:
    return statistics.stdev(values) / statistics.mean(values) * 100 if len(values) > 1 else 0.0


def percentile(values: list[int], fraction: float) -> float:
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def groups(rows: list[Row]) -> list[tuple[tuple[str, str, int, int], list[Row], list[Row]]]:
    keys = sorted({(row.trigger, row.scenario, row.trigger_bytes, row.moving) for row in rows})
    return [
        (
            key,
            [
                row
                for row in rows
                if (row.trigger, row.scenario, row.trigger_bytes, row.moving) == key
                and row.tenuring_age == 1
            ],
            [
                row
                for row in rows
                if (row.trigger, row.scenario, row.trigger_bytes, row.moving) == key
                and row.tenuring_age == 3
            ],
        )
        for key in keys
    ]


def moving_groups(rows: list[Row]) -> list[tuple[tuple[str, str, int, int], list[Row], list[Row]]]:
    keys = sorted({(row.trigger, row.scenario, row.trigger_bytes, row.tenuring_age) for row in rows})
    return [
        (
            key,
            [
                row
                for row in rows
                if (row.trigger, row.scenario, row.trigger_bytes, row.tenuring_age) == key
                and row.moving == 0
            ],
            [
                row
                for row in rows
                if (row.trigger, row.scenario, row.trigger_bytes, row.tenuring_age) == key
                and row.moving == 1
            ],
        )
        for key in keys
    ]


def validate_matrix(rows: list[Row], samples: int, quick: bool) -> None:
    for key, age_one, age_three in groups(rows):
        if [row.sample for row in age_one] != list(range(samples)) or [row.sample for row in age_three] != list(range(samples)):
            raise ValueError(f"missing or duplicate samples for {key}")
        if quick:
            continue
        for age_rows in (age_one, age_three):
            if rsd([row.elapsed_ns for row in age_rows]) > 15.0:
                raise ValueError(f"elapsed dispersion exceeds 15% for {key}, age {age_rows[0].tenuring_age}")
        age_one_median = statistics.median(row.elapsed_ns for row in age_one)
        age_three_median = statistics.median(row.elapsed_ns for row in age_three)
        if age_three_median > age_one_median * 1.20 and max(
            rsd([row.elapsed_ns for row in age_one]), rsd([row.elapsed_ns for row in age_three])
        ) <= 5.0:
            raise ValueError(f"stable age-three throughput regression exceeds 20% for {key}")
    for key, nonmoving, moving in moving_groups(rows):
        if [row.sample for row in nonmoving] != list(range(samples)) or [
            row.sample for row in moving
        ] != list(range(samples)):
            raise ValueError(f"missing exact moving parent for {key}")


def percentage(numerator: float, denominator: float) -> float:
    return numerator / denominator * 100 if denominator else 0.0


def render(rows: list[Row], info: dict[str, str], raw_path: Path | None) -> str:
    lines = [
        f"# GC generation policy — {info['Date']}", "",
        "> Dated nursery-policy evidence, not a general application benchmark.",
        "> Exact moving/non-moving parents, exact work/checksums, alternating age order, a 50 ms timing floor, byte conservation, zero unscheduled full-GC contamination, zero movement failures, zero conservative-parent timeouts, and at most two bounded moving retries are enforced. Shared moving rows include the one production automatic-compaction follow-on.",
        "", "## Environment", "", "| item | value |", "| --- | --- |",
    ]
    lines.extend(f"| {key} | {value} |" for key, value in info.items())
    lines.extend([
        "", "## Age-three policy versus age-one control", "",
        "| trigger | workload | trigger | movement | age 1 median | age 3 median | age 3 throughput | age 3 pause p50 / p95 | age 1 → age 3 promoted | age 1 → age 3 retained backing |",
        "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for (trigger, scenario, trigger_bytes, moving), age_one, age_three in groups(rows):
        elapsed_one = statistics.median(row.elapsed_ns for row in age_one)
        elapsed_three = statistics.median(row.elapsed_ns for row in age_three)
        throughput = elapsed_one / elapsed_three
        pause_values = [row.pause_max_ns for row in age_three]
        promoted_one = percentage(sum(row.promoted_bytes for row in age_one), sum(row.young_input_bytes for row in age_one))
        promoted_three = percentage(sum(row.promoted_bytes for row in age_three), sum(row.young_input_bytes for row in age_three))
        backing_one = statistics.median(row.backing_capacity_bytes for row in age_one) / MIB
        backing_three = statistics.median(row.backing_capacity_bytes for row in age_three) / MIB
        lines.append(
            f"| {trigger} | {scenario} | {trigger_bytes / MIB:.2f} MiB | "
            f"{'moving' if moving else 'non-moving'} | "
            f"{elapsed_one / 1e6:.2f} ms | {elapsed_three / 1e6:.2f} ms | **{throughput:.2f}x** | "
            f"{statistics.median(pause_values) / 1e6:.3f} / {percentile(pause_values, .95) / 1e6:.3f} ms | "
            f"{promoted_one:.1f}% → {promoted_three:.1f}% | {backing_one:.2f} → {backing_three:.2f} MiB |"
        )
    lines.extend([
        "", "Age-three is the production policy; age one is the control. Every moving row has an exact non-moving parent with the same trigger, workload, age, sample, and checksum. Forced rows isolate the quiescent minor pause after each equal allocation round. Shared rows run three JavaScript mutators without a context GIL and use the displayed cooperative allocation tranche.",
        "", "## Moving age-three exact-parent comparison", "",
        "| trigger | workload | trigger | non-moving median | moving median | moving throughput | moving pause p50 / p95 | copied | promoted | retained backing | timeouts |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for (trigger, scenario, trigger_bytes, age), nonmoving, moving_rows in moving_groups(rows):
        if age != 3:
            continue
        elapsed_nonmoving = statistics.median(row.elapsed_ns for row in nonmoving)
        elapsed_moving = statistics.median(row.elapsed_ns for row in moving_rows)
        pause_values = [row.pause_max_ns for row in moving_rows]
        promoted = percentage(
            sum(row.promoted_bytes for row in moving_rows),
            sum(row.young_input_bytes for row in moving_rows),
        )
        lines.append(
            f"| {trigger} | {scenario} | {trigger_bytes / MIB:.2f} MiB | "
            f"{elapsed_nonmoving / 1e6:.2f} ms | {elapsed_moving / 1e6:.2f} ms | "
            f"**{elapsed_nonmoving / elapsed_moving:.2f}x** | "
            f"{statistics.median(pause_values) / 1e6:.3f} / "
            f"{percentile(pause_values, .95) / 1e6:.3f} ms | "
            f"{sum(row.moved_bytes for row in moving_rows) / MIB:.2f} MiB | "
            f"{promoted:.1f}% | "
            f"{statistics.median(row.backing_capacity_bytes for row in moving_rows) / MIB:.2f} MiB | "
            f"{sum(row.cooperative_timeouts for row in moving_rows)} |"
        )
    lines.extend([
        "", "## Telemetry and dispersion", "",
        "| trigger | workload | configured trigger | movement | age | elapsed RSD | reclaimed | survived | minor / moving / full | copied | pause max | rendezvous attempts / parks / timeouts |",
        "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for key, age_one, age_three in groups(rows):
        for age_rows in (age_one, age_three):
            first = age_rows[0]
            young = sum(row.young_input_bytes for row in age_rows)
            lines.append(
                f"| {key[0]} | {key[1]} | {key[2] / MIB:.2f} MiB | "
                f"{'moving' if first.moving else 'non-moving'} | {first.tenuring_age} | "
                f"{rsd([row.elapsed_ns for row in age_rows]):.2f}% | "
                f"{percentage(sum(row.reclaimed_bytes for row in age_rows), young):.1f}% | "
                f"{percentage(sum(row.survived_bytes for row in age_rows), young):.1f}% | "
                f"{statistics.median(row.minor_collections for row in age_rows):.0f} / "
                f"{statistics.median(row.moving_minor_collections for row in age_rows):.0f} / "
                f"{statistics.median(row.full_collections for row in age_rows):.0f} | "
                f"{sum(row.moved_bytes for row in age_rows) / MIB:.2f} MiB | "
                f"{max(row.pause_max_ns for row in age_rows) / 1e6:.3f} ms | "
                f"{sum(row.cooperative_attempts for row in age_rows)} / {sum(row.cooperative_parks for row in age_rows)} / {sum(row.cooperative_timeouts for row in age_rows)} |"
            )
    raw_line = f"Raw evidence: [{raw_path.name}]({raw_path.name})" if raw_path else "Pass --raw-out to preserve the raw TSV."
    lines.extend([
        "", "## Method", "",
        "Ephemeral rows retain nothing. Mixed rows retain 1/16 of graphs for two cycles, exposing premature age-one promotion. High-survival rows retain half the graphs for eight cycles, exercising legitimate promotion. Every graph contributes to an exact integer checksum.",
        "Each process is fresh. One unrecorded warmup per matrix row precedes seven recorded samples; age order alternates per sample, and moving/non-moving configurations retain the same sample indexes. The harness rejects checksum drift, byte imbalance, any full collection except the single production automatic-compaction follow-on in a shared moving row, missing minor/movement/rendezvous activity, movement failures, any conservative-parent timeout, more than two bounded moving retries, samples below 50 ms, elapsed RSD above 15%, and stable age-three regressions above 20%.",
        raw_line,
        "", "## Reproduce", "", "```sh",
        "zig build gc-generation-benchmark -Doptimize=ReleaseFast",
        "zig build gc-generation-benchmark -Dgc-generation-benchmark-quick=true",
        "```", "",
    ])
    return "\n".join(lines)


def readme_scorecard(rows: list[Row], report_path: Path, raw_path: Path) -> str:
    single = [
        (key, a1, a3)
        for key, a1, a3 in groups(rows)
        if key[0] == "forced" and key[3] == 1
    ]
    moving_parents = [
        (key, nonmoving, moving)
        for key, nonmoving, moving in moving_groups(rows)
        if key[3] == 3
    ]
    shared_moving = [
        moving
        for key, _, moving in moving_parents
        if key[0] == "shared"
    ]
    age_throughput = [
        statistics.median(row.elapsed_ns for row in a1)
        / statistics.median(row.elapsed_ns for row in a3)
        for _, a1, a3 in single
    ]
    moving_throughput = [
        statistics.median(row.elapsed_ns for row in nonmoving)
        / statistics.median(row.elapsed_ns for row in moving)
        for _, nonmoving, moving in moving_parents
    ]
    shared_pause = max(row.pause_max_ns for group in shared_moving for row in group)
    copied = sum(row.moved_bytes for _, _, moving in moving_parents for row in moving)
    timeouts = sum(row.cooperative_timeouts for row in rows)
    return (
        f"{README_START}\n"
        f"- **Generational GC:** moving age-three is {min(moving_throughput):.2f}–{max(moving_throughput):.2f}x its exact non-moving parents and {min(age_throughput):.2f}–{max(age_throughput):.2f}x moving age-one across accepted single-mutator rows; {copied / MIB:.2f} MiB copied in the recorded moving age-three rows; shared no-GIL minor pause max {shared_pause / 1e6:.2f} ms with {timeouts} timeouts "
        f"([report]({report_path.as_posix()}) · [samples]({raw_path.as_posix()})).\n"
        f"{README_END}"
    )


def replace_readme_block(text: str, generated: str) -> str:
    if text.count(README_START) != 1 or text.count(README_END) != 1:
        raise ValueError("README must contain exactly one GC generation marker pair")
    before, remainder = text.split(README_START, 1)
    _, after = remainder.split(README_END, 1)
    return before + generated + after


def write_raw(rows: list[Row], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [HEADER]
    lines.extend("\t".join(str(getattr(row, field)) for field in Row.__annotations__) for row in rows)
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runner", type=Path)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--raw-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--readme", type=Path)
    args = parser.parse_args()
    if args.quick:
        args.samples, args.warmups = 1, 0
    if args.samples <= 0 or args.warmups < 0:
        parser.error("samples must be positive and warmups non-negative")
    if args.readme and not (args.raw_out and args.markdown_out):
        parser.error("--readme requires --raw-out and --markdown-out")

    info = metadata()
    if (args.raw_out or args.markdown_out or args.readme) and any(
        value.endswith(" (tracked worktree dirty)") for value in info.values()
    ):
        raise ValueError("refusing to publish benchmark evidence from a dirty tracked worktree")
    rows = collect(args.runner.resolve(), args.samples, args.warmups, args.quick)
    validate_matrix(rows, args.samples, args.quick)
    if args.raw_out:
        write_raw(rows, args.raw_out)
    report = render(rows, info, args.raw_out)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(report)
    if args.readme:
        generated = readme_scorecard(
            rows,
            args.markdown_out.resolve().relative_to(ROOT),
            args.raw_out.resolve().relative_to(ROOT),
        )
        args.readme.write_text(replace_readme_block(args.readme.read_text(), generated))
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
