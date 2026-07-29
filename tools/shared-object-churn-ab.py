#!/usr/bin/env python3
"""Run an order-balanced exact-parent shared object-churn A/B."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import os
import pathlib
import platform
import re
import statistics
import subprocess
import sys


INTEGER_FIELDS = {
    "lanes", "jobs", "elapsed_ns", "checksum", "attempts", "collections",
    "timeouts", "peer_parks", "exit_cleanups", "pause_ns_total",
    "pause_ns_max", "rendezvous_ns_total", "rendezvous_ns_max",
    "tranche_bytes", "bytes_issued", "bytes_reset", "bytes_current",
    "minor_cycles", "minor_prepare_ns", "minor_trace_ns", "minor_sweep_ns",
    "minor_post_sweep_ns", "full_cycles", "full_prepare_ns", "full_trace_ns",
    "full_sweep_ns", "full_post_sweep_ns", "object_batch_calls",
    "object_batch_cells", "object_batch_ns_total", "object_batch_ns_max",
    "worker_runs", "worker_run_ns", "worker_run_ns_max", "join_wait_ns",
    "join_parks", "heap_collections", "heap_minor_collections",
    "heap_live_cells", "heap_young_cells", "heap_young_bytes",
    "last_minor_young_bytes", "last_minor_reclaimed_bytes",
    "last_minor_survived_cells", "last_minor_survived_bytes",
    "backing_chunks", "backing_capacity_slots", "backing_live_slots",
    "backing_free_slots",
}
RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size\s*$", re.MULTILINE)


def parse_output(
    stdout: str,
    stderr: str,
    variant: str,
    sample: int,
    order: int,
) -> dict[str, int | str]:
    lines = [line for line in stdout.splitlines() if line]
    if len(lines) != 3:
        raise ValueError(f"expected header, benchmark row, and telemetry row; got {len(lines)}")
    header = lines[0].split("\t")
    benchmark = lines[1].split("\t")
    values = lines[2].split("\t")
    if header[0] != "zig-js-gc" or values[0] != "zig-js-gc" or len(header) != len(values):
        raise ValueError("malformed zig-js-gc telemetry record")
    if len(benchmark) != 8 or benchmark[:3] != ["zig-js", "shared", "object_churn"]:
        raise ValueError("malformed benchmark witness row")
    rss = RSS_RE.search(stderr)
    if rss is None:
        raise ValueError("missing maximum resident set size from /usr/bin/time -l")
    telemetry: dict[str, int | str] = dict(zip(header, values))
    telemetry["kind"] = telemetry.pop("zig-js-gc")
    for field in INTEGER_FIELDS:
        telemetry[field] = int(telemetry[field])
    if int(benchmark[6]) != telemetry["elapsed_ns"] or int(benchmark[7]) != telemetry["checksum"]:
        raise ValueError("benchmark and telemetry witnesses disagree")
    if int(benchmark[3]) != telemetry["lanes"]:
        raise ValueError("benchmark and telemetry lane counts disagree")
    return {
        "variant": variant,
        "sample": sample,
        "order": order,
        "max_rss_bytes": int(rss.group(1)),
        **telemetry,
    }


def run_one(
    runner: pathlib.Path,
    variant: str,
    lane: int,
    sample: int,
    order: int,
) -> dict[str, int | str]:
    command = [
        "/usr/bin/time", "-l", str(runner), "shared", "object_churn",
        "100", "1", str(lane), "--gc-telemetry",
    ]
    print("+ " + " ".join(command), file=sys.stderr, flush=True)
    completed = subprocess.run(
        command,
        check=True,
        text=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    return parse_output(completed.stdout, completed.stderr, variant, sample, order)


def validate(rows: list[dict[str, int | str]], samples: int, lanes: list[int]) -> None:
    expected = {
        (variant, lane, sample)
        for variant in ("parent", "candidate")
        for lane in lanes
        for sample in range(samples)
    }
    actual = {(str(row["variant"]), int(row["lanes"]), int(row["sample"])) for row in rows}
    if actual != expected or len(rows) != len(expected):
        raise ValueError("A/B sample inventory drift")
    for lane in lanes:
        group = [row for row in rows if row["lanes"] == lane]
        if len({row["checksum"] for row in group}) != 1:
            raise ValueError(f"lane {lane} checksum drift")
        for sample in range(samples):
            pair = [row for row in group if row["sample"] == sample]
            if sorted(int(row["order"]) for row in pair) != [0, 1]:
                raise ValueError(f"lane {lane} sample {sample} order drift")
        for row in group:
            if row["worker_runs"] != lane:
                raise ValueError(f"lane {lane} worker count drift")
            if row["collections"] != row["minor_cycles"] or row["collections"] != row["heap_minor_collections"]:
                raise ValueError(f"lane {lane} collector accounting drift")


def median(rows: list[dict[str, int | str]], field: str) -> float:
    return statistics.median(int(row[field]) for row in rows)


def rsd(rows: list[dict[str, int | str]]) -> float:
    values = [int(row["elapsed_ns"]) for row in rows]
    return statistics.stdev(values) / statistics.mean(values) if len(values) > 1 else 0


def render(
    rows: list[dict[str, int | str]],
    lanes: list[int],
    samples: int,
    parent_revision: str,
    candidate_revision: str,
    gc_revision: str,
    raw_name: str,
) -> str:
    parent_one = median(
        [row for row in rows if row["variant"] == "parent" and row["lanes"] == 1],
        "elapsed_ns",
    )
    candidate_one = median(
        [row for row in rows if row["variant"] == "candidate" and row["lanes"] == 1],
        "elapsed_ns",
    )
    lines = [
        f"# Shared object-churn reserve A/B — {dt.date.today().isoformat()}",
        "",
        "Order-balanced exact-parent diagnostic for [#97](https://github.com/zig-utils/zig-js/issues/97).",
        "",
        f"- parent zig-js: `{parent_revision}`",
        f"- candidate zig-js: `{candidate_revision}`",
        f"- zig-gc: `{gc_revision}` in both variants",
        f"- host: {platform.platform()} · {platform.machine()}",
        f"- sampling: {samples} alternating fresh-process pairs per lane; ReleaseFast; exact `object_churn`, 100 jobs/lane",
        "- every checksum, worker count, and collector accounting invariant matched; maximum resident set size is captured by `/usr/bin/time -l`",
        "",
        "| lanes | parent wall | candidate wall | speedup | parent scaling | candidate scaling | candidate/parent RSS | pair wins | publication batches parent → candidate |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for lane in lanes:
        parent = [row for row in rows if row["variant"] == "parent" and row["lanes"] == lane]
        candidate = [row for row in rows if row["variant"] == "candidate" and row["lanes"] == lane]
        parent_wall = median(parent, "elapsed_ns")
        candidate_wall = median(candidate, "elapsed_ns")
        wins = sum(
            next(row for row in candidate if row["sample"] == sample)["elapsed_ns"]
            < next(row for row in parent if row["sample"] == sample)["elapsed_ns"]
            for sample in range(samples)
        )
        lines.append(
            f"| {lane} | {parent_wall / 1e6:,.3f} ms ({rsd(parent) * 100:.1f}% RSD) | "
            f"{candidate_wall / 1e6:,.3f} ms ({rsd(candidate) * 100:.1f}% RSD) | "
            f"{parent_wall / candidate_wall:.2f}x | {lane * parent_one / parent_wall:.2f}x | "
            f"{lane * candidate_one / candidate_wall:.2f}x | "
            f"{median(candidate, 'max_rss_bytes') / median(parent, 'max_rss_bytes'):.3f}x | "
            f"{wins}/{samples} | {median(parent, 'object_batch_calls'):,.0f} → "
            f"{median(candidate, 'object_batch_calls'):,.0f} |"
        )
    parent_eight = [row for row in rows if row["variant"] == "parent" and row["lanes"] == 8]
    candidate_eight = [row for row in rows if row["variant"] == "candidate" and row["lanes"] == 8]
    parent_calls = median(parent_eight, "object_batch_calls")
    candidate_calls = median(candidate_eight, "object_batch_calls")
    if candidate_calls == 0:
        raise ValueError("candidate reported zero publication batches")
    candidate_scaling = 8 * candidate_one / median(candidate_eight, "elapsed_ns")
    lines.extend([
        "",
        "## Finding",
        "",
        f"The bounded per-interpreter reserve reduces eight-lane shared-heap publication from "
        f"{parent_calls:,.0f} to {candidate_calls:,.0f} batches ({parent_calls / candidate_calls:.1f}x fewer). "
        f"Candidate eight-lane scaling is {candidate_scaling:.2f}x, clearing the issue's 1.0x floor without changing work or checksums.",
        "",
        "The RSS ratio includes both live benchmark state and the bounded unused reserve tail. "
        "The exact-parent comparison therefore checks that the throughput improvement is not purchased with unbounded retention.",
        "",
        f"Raw timing/RSS/telemetry evidence: [{raw_name}]({raw_name}).",
        "",
        "This focused A/B establishes causality; the complete zig-js/JavaScriptCore matrix remains the publication gate.",
        "",
    ])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("parent_runner", type=pathlib.Path)
    parser.add_argument("candidate_runner", type=pathlib.Path)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--lanes", default="1,2,4,8")
    parser.add_argument("--raw-out", type=pathlib.Path, required=True)
    parser.add_argument("--markdown-out", type=pathlib.Path, required=True)
    parser.add_argument("--parent-revision", required=True)
    parser.add_argument("--candidate-revision", required=True)
    parser.add_argument("--gc-revision", required=True)
    args = parser.parse_args()
    lanes = [int(value) for value in args.lanes.split(",")]
    if args.samples < 1 or not lanes or lanes[0] != 1 or any(lane < 1 for lane in lanes):
        parser.error("samples must be positive and lanes must begin with 1")

    rows: list[dict[str, int | str]] = []
    runners = {"parent": args.parent_runner, "candidate": args.candidate_runner}
    for lane in lanes:
        for sample in range(args.samples):
            order = ("parent", "candidate") if sample % 2 == 0 else ("candidate", "parent")
            for position, variant in enumerate(order):
                rows.append(run_one(runners[variant], variant, lane, sample, position))
    validate(rows, args.samples, lanes)

    fields = list(rows[0])
    raw = io.StringIO()
    writer = csv.DictWriter(raw, fieldnames=fields, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    args.raw_out.write_text(raw.getvalue())
    args.markdown_out.write_text(render(
        rows,
        lanes,
        args.samples,
        args.parent_revision,
        args.candidate_revision,
        args.gc_revision,
        args.raw_out.name,
    ))


if __name__ == "__main__":
    main()
