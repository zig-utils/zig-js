#!/usr/bin/env python3
"""Run and summarize exact shared object-churn GC telemetry."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import os
import pathlib
import platform
import statistics
import subprocess
import sys


INTEGER_FIELDS = {
    "lanes", "jobs", "sample", "elapsed_ns", "checksum", "attempts",
    "collections", "timeouts", "peer_parks", "exit_cleanups",
    "pause_ns_total", "pause_ns_max", "rendezvous_ns_total",
    "rendezvous_ns_max", "tranche_bytes", "bytes_issued", "bytes_reset",
    "bytes_current", "minor_cycles", "minor_prepare_ns", "minor_trace_ns",
    "minor_sweep_ns", "minor_post_sweep_ns", "full_cycles",
    "full_prepare_ns", "full_trace_ns", "full_sweep_ns",
    "full_post_sweep_ns", "object_batch_calls", "object_batch_cells",
    "object_batch_ns_total", "object_batch_ns_max", "worker_runs",
    "worker_run_ns", "worker_run_ns_max", "join_wait_ns", "join_parks",
    "heap_collections", "heap_minor_collections", "heap_live_cells",
    "heap_young_cells", "heap_young_bytes", "last_minor_young_bytes",
    "last_minor_reclaimed_bytes", "last_minor_survived_cells",
    "last_minor_survived_bytes", "backing_chunks", "backing_capacity_slots",
    "backing_live_slots", "backing_free_slots",
}


def parse_output(output: str, sample: int) -> dict[str, int | str]:
    lines = [line for line in output.splitlines() if line]
    if len(lines) != 3:
        raise ValueError(f"expected header, benchmark row, and telemetry row; got {len(lines)}")
    header = lines[0].split("\t")
    benchmark = lines[1].split("\t")
    values = lines[2].split("\t")
    if header[0] != "zig-js-gc" or values[0] != "zig-js-gc":
        raise ValueError("missing zig-js-gc telemetry record")
    if len(header) != len(values):
        raise ValueError(f"telemetry width mismatch: {len(header)} != {len(values)}")
    if len(benchmark) != 8 or benchmark[:3] != ["zig-js", "shared", "object_churn"]:
        raise ValueError("malformed benchmark witness row")
    raw: dict[str, int | str] = dict(zip(header, values))
    row: dict[str, int | str] = {"kind": raw.pop("zig-js-gc"), **raw}
    for field in INTEGER_FIELDS:
        row[field] = int(row[field])
    row["sample"] = sample
    if int(benchmark[6]) != row["elapsed_ns"] or int(benchmark[7]) != row["checksum"]:
        raise ValueError("benchmark and telemetry witnesses disagree")
    return row


def validate(rows: list[dict[str, int | str]], samples: int, lanes: list[int]) -> None:
    for lane in lanes:
        group = [row for row in rows if row["lanes"] == lane]
        if len(group) != samples or sorted(int(row["sample"]) for row in group) != list(range(samples)):
            raise ValueError(f"lane {lane} sample inventory drift")
        if len({row["checksum"] for row in group}) != 1:
            raise ValueError(f"lane {lane} checksum drift")
        for row in group:
            if row["worker_runs"] != lane:
                raise ValueError(f"lane {lane} worker count drift")
            if row["collections"] != row["minor_cycles"] or row["collections"] != row["heap_minor_collections"]:
                raise ValueError(f"lane {lane} cooperative/minor accounting drift")
            phase_ns = sum(int(row[name]) for name in (
                "minor_prepare_ns", "minor_trace_ns", "minor_sweep_ns", "minor_post_sweep_ns",
            ))
            if phase_ns > row["pause_ns_total"] or row["rendezvous_ns_total"] > row["pause_ns_total"]:
                raise ValueError(f"lane {lane} phase timing is incoherent")
            if lane == 1 and (row["attempts"] != 0 or row["bytes_issued"] != 0):
                raise ValueError("one-lane profile unexpectedly armed cooperative GC")


def command_output(args: list[str], default: str = "unknown") -> str:
    try:
        return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip() or default
    except (FileNotFoundError, subprocess.CalledProcessError):
        return default


def median(rows: list[dict[str, int | str]], field: str) -> float:
    return statistics.median(int(row[field]) for row in rows)


def render(rows: list[dict[str, int | str]], lanes: list[int], samples: int, revision: str, gc_revision: str) -> str:
    groups = {lane: [row for row in rows if row["lanes"] == lane] for lane in lanes}
    one = median(groups[1], "elapsed_ns")
    lines = [
        f"# Shared object-churn GC phase profile — {dt.date.today().isoformat()}",
        "",
        "Focused diagnostic for [#426](https://github.com/zig-utils/zig-js/issues/426); it is not a replacement for the published zig-js/JSC matrix.",
        "",
        f"- zig-js: `{revision}`",
        f"- zig-gc: `{gc_revision}`",
        f"- host: {platform.platform()} · {platform.machine()}",
        f"- sampling: {samples} fresh ReleaseFast processes per lane; exact `object_churn`, 100 jobs/lane",
        "- every checksum and collector accounting invariant matched",
        "",
        "| lanes | median | RSD | scaling | coop pause | minor sweep | object-batch CPU | max worker |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for lane in lanes:
        group = groups[lane]
        elapsed = median(group, "elapsed_ns")
        rsd = statistics.stdev(int(row["elapsed_ns"]) for row in group) / statistics.mean(int(row["elapsed_ns"]) for row in group) if samples > 1 else 0
        pause = median(group, "pause_ns_total")
        sweep = median(group, "minor_sweep_ns")
        batch = median(group, "object_batch_ns_total")
        worker = median(group, "worker_run_ns_max")
        lines.append(
            f"| {lane} | {elapsed / 1e6:,.3f} ms | {rsd * 100:.2f}% | {lane * one / elapsed:.2f}x | "
            f"{pause / 1e6:,.3f} ms ({pause / elapsed * 100:.1f}%) | {sweep / 1e6:,.3f} ms | "
            f"{batch / 1e6:,.3f} ms | {worker / 1e6:,.3f} ms |"
        )
    if 8 in groups:
        eight = groups[8]
        elapsed = median(eight, "elapsed_ns")
        pause = median(eight, "pause_ns_total")
        sweep = median(eight, "minor_sweep_ns")
        rendezvous = median(eight, "rendezvous_ns_total")
        trace = median(eight, "minor_trace_ns")
        reclaimed = median(eight, "last_minor_reclaimed_bytes")
        survived = median(eight, "last_minor_survived_cells")
        lines.extend([
            "",
            "## Finding",
            "",
            f"At eight lanes, cooperative GC accounts for {pause / elapsed * 100:.1f}% of wall time. "
            f"Nursery sweep is {sweep / pause * 100:.1f}% of that pause "
            f"({sweep / 1e6:,.3f} ms), versus {rendezvous / 1e6:,.3f} ms of rendezvous and "
            f"{trace / 1e6:,.3f} ms of trace. The median cycle reclaims "
            f"{reclaimed / 1e9:,.3f} GB while retaining only {survived:,.0f} young cells. "
            "The next measured candidate is whole-run dead nursery backing reclamation "
            "([zig-js #427](https://github.com/zig-utils/zig-js/issues/427), "
            "[zig-gc #42](https://github.com/zig-utils/zig-gc/issues/42)), not another "
            "rendezvous or tracing optimization.",
        ])
    lines.extend([
        "",
        "`object-batch CPU` sums allocation/publication time across workers and may exceed wall time. Cooperative pause and phase columns are collector wall time while peers are stopped.",
        "",
    ])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("runner", type=pathlib.Path)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--lanes", default="1,2,4,8")
    parser.add_argument("--raw-out", type=pathlib.Path, required=True)
    parser.add_argument("--markdown-out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    lanes = [int(value) for value in args.lanes.split(",")]
    if args.samples < 1 or not lanes or lanes[0] != 1 or any(lane < 1 for lane in lanes):
        parser.error("samples must be positive and lanes must begin with 1")

    rows: list[dict[str, int | str]] = []
    for lane in lanes:
        for sample in range(args.samples):
            command = [str(args.runner), "shared", "object_churn", "100", "1", str(lane), "--gc-telemetry"]
            print("+ " + " ".join(command), file=sys.stderr, flush=True)
            completed = subprocess.run(command, check=True, text=True, capture_output=True, env={**os.environ, "LC_ALL": "C"})
            rows.append(parse_output(completed.stdout, sample))
    validate(rows, args.samples, lanes)

    fields = list(rows[0])
    raw = io.StringIO()
    writer = csv.DictWriter(raw, fieldnames=fields, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    args.raw_out.write_text(raw.getvalue())

    root = pathlib.Path(__file__).resolve().parents[1]
    revision = command_output(["git", "-C", str(root), "rev-parse", "HEAD"])
    gc_revision = command_output(["git", "-C", str(root.parent / "zig-gc"), "rev-parse", "HEAD"])
    args.markdown_out.write_text(render(rows, lanes, args.samples, revision, gc_revision))


if __name__ == "__main__":
    main()
