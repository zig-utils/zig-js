#!/usr/bin/env python3
"""Collect a stable, order-balanced exact-parent performance A/B artifact."""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import os
import pathlib
import platform
import re
import resource
import statistics
import subprocess
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
ATTRIBUTION_TOOL = pathlib.Path(__file__).with_name("performance-attribution.py")
SPEC = importlib.util.spec_from_file_location("performance_attribution_contract", ATTRIBUTION_TOOL)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {ATTRIBUTION_TOOL}")
attribution = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = attribution
SPEC.loader.exec_module(attribution)

RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size\s*$", re.MULTILINE)
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")


@dataclasses.dataclass(frozen=True)
class RunnerRow:
    engine: str
    mode: str
    workload: str
    lanes: int
    jobs: int
    elapsed_ns: int
    checksum: int
    process_cpu_user_ns: int
    process_cpu_system_ns: int
    peak_rss_bytes: int


def command_output(arguments: list[str], default: str = "unknown") -> str:
    try:
        return subprocess.run(arguments, check=True, text=True, capture_output=True).stdout.strip() or default
    except (FileNotFoundError, subprocess.CalledProcessError):
        return default


def resolve_revision(revision: str) -> str:
    resolved = command_output(["git", "-C", str(ROOT), "rev-parse", f"{revision}^{{commit}}"], "")
    if not REVISION_RE.fullmatch(resolved):
        raise ValueError(f"cannot resolve commit: {revision}")
    return resolved


def validate_exact_parent(parent: str, candidate: str) -> tuple[str, str]:
    parent_revision = resolve_revision(parent)
    candidate_revision = resolve_revision(candidate)
    candidate_parent = resolve_revision(f"{candidate_revision}^1")
    if candidate_parent != parent_revision:
        raise ValueError(
            f"candidate first parent is {candidate_parent}, not requested exact parent {parent_revision}"
        )
    return parent_revision, candidate_revision


def repository_revision(path: pathlib.Path) -> str:
    revision = command_output(["git", "-C", str(path), "rev-parse", "HEAD"], "")
    if not REVISION_RE.fullmatch(revision):
        raise ValueError(f"cannot resolve repository revision: {path}")
    return revision


def require_clean(path: pathlib.Path) -> None:
    try:
        dirty = subprocess.run(
            ["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot verify tracked worktree cleanliness: {path}") from error
    if dirty:
        raise ValueError(f"refusing exact-parent publication from dirty tracked worktree: {path}")


def parse_benchmark(stdout: str, expected_mode: str, expected_workload: str, lanes: int, jobs: int) -> tuple[str, int, int]:
    rows = [line for line in stdout.splitlines() if line.startswith("zig-js\t")]
    if len(rows) != 1:
        raise ValueError(f"expected one zig-js benchmark row, got {len(rows)}")
    fields = rows[0].split("\t")
    if len(fields) != 8:
        raise ValueError(f"benchmark row width is {len(fields)}, expected 8")
    engine, mode, workload = fields[:3]
    if engine != "zig-js" or mode != expected_mode or workload != expected_workload:
        raise ValueError(f"benchmark row identity drift: {fields[:3]}")
    if int(fields[3]) != lanes or int(fields[4]) != jobs or int(fields[5]) != 0:
        raise ValueError("benchmark lane/jobs/sample identity drift")
    return engine, int(fields[6]), int(fields[7])


def parse_peak_rss(stderr: str) -> int:
    match = RSS_RE.search(stderr)
    if match is None:
        raise ValueError("missing maximum resident set size from /usr/bin/time -l")
    return int(match.group(1))


def runner_arguments(mode: str, workload: str, jobs: int, lanes: int) -> list[str]:
    if mode == "single":
        if lanes != 1:
            raise ValueError("single mode requires one lane")
        return [mode, workload, str(jobs), "1"]
    if mode not in {"independent_steady", "independent_cold", "shared"}:
        raise ValueError(f"unsupported benchmark mode: {mode}")
    return [mode, workload, str(jobs), "1", str(lanes)]


def run_one(binary: pathlib.Path, mode: str, workload: str, jobs: int, lanes: int) -> RunnerRow:
    arguments = runner_arguments(mode, workload, jobs, lanes)
    command = ["/usr/bin/time", "-l", str(binary), *arguments]
    print("+ " + " ".join(command), file=sys.stderr, flush=True)
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    completed = subprocess.run(
        command,
        check=True,
        text=True,
        capture_output=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    engine, elapsed_ns, checksum = parse_benchmark(completed.stdout, mode, workload, lanes, jobs)
    return RunnerRow(
        engine=engine,
        mode=mode,
        workload=workload,
        lanes=lanes,
        jobs=jobs,
        elapsed_ns=elapsed_ns,
        checksum=checksum,
        process_cpu_user_ns=round((after.ru_utime - before.ru_utime) * 1_000_000_000),
        process_cpu_system_ns=round((after.ru_stime - before.ru_stime) * 1_000_000_000),
        peak_rss_bytes=parse_peak_rss(completed.stderr),
    )


def sample_record(
    row: RunnerRow,
    variant: str,
    pair_sample: int,
    order: int,
    schema: dict[str, Any],
) -> dict[str, Any]:
    metrics = attribution.unavailable_metrics(
        schema,
        "instrumentation is not yet connected for this metric; absence is explicit and is not a zero",
    )
    attribution.measured(metrics, "wall_time_ns", row.elapsed_ns, "benchmark_runner.elapsed_ns")
    attribution.measured(metrics, "process_cpu_user_ns", row.process_cpu_user_ns, "getrusage(RUSAGE_CHILDREN).ru_utime")
    attribution.measured(metrics, "process_cpu_system_ns", row.process_cpu_system_ns, "getrusage(RUSAGE_CHILDREN).ru_stime")
    attribution.measured(metrics, "peak_rss_bytes", row.peak_rss_bytes, "/usr/bin/time -l maximum resident set size")
    return {
        "identity": {
            "variant": variant,
            "pair_sample": pair_sample,
            "order": order,
            "engine": row.engine,
            "mode": row.mode,
            "workload": row.workload,
            "lanes": row.lanes,
            "jobs": row.jobs,
            "checksum": row.checksum,
        },
        "metrics": metrics,
    }


def relative_stddev(values: list[int]) -> float:
    return statistics.stdev(values) / statistics.mean(values) if len(values) > 1 else 0.0


def summarize(samples: list[dict[str, Any]], schema: dict[str, Any], host_class: str) -> dict[str, Any]:
    walls = {
        variant: [
            int(sample["metrics"]["wall_time_ns"]["value"])
            for sample in samples
            if sample["identity"]["variant"] == variant
        ]
        for variant in ("parent", "candidate")
    }
    parent_median = statistics.median(walls["parent"])
    candidate_median = statistics.median(walls["candidate"])
    ratio = candidate_median / parent_median
    parent_rsd = relative_stddev(walls["parent"])
    candidate_rsd = relative_stddev(walls["candidate"])
    policy = schema["regression_policy"]
    stable = parent_rsd <= policy["maximum_rsd"] and candidate_rsd <= policy["maximum_rsd"]
    gating_host = host_class == policy["gate_host_class"]
    regression = ratio > policy["wall_regression_ratio"]
    blocks = gating_host and stable and regression
    if blocks:
        status = "blocked_regression"
    elif not gating_host:
        status = "diagnostic_only"
    elif not stable:
        status = "inconclusive_noise"
    elif regression:
        status = "visible_non_gating_regression"
    else:
        status = "pass"
    return {
        "parent_wall_median_ns": parent_median,
        "candidate_wall_median_ns": candidate_median,
        "candidate_over_parent": ratio,
        "parent_wall_rsd": parent_rsd,
        "candidate_wall_rsd": candidate_rsd,
        "stable": stable,
        "gating_host": gating_host,
        "regression": regression,
        "blocks_publication": blocks,
        "status": status,
    }


def collect(
    parent_binary: pathlib.Path,
    candidate_binary: pathlib.Path,
    mode: str,
    workload: str,
    jobs: int,
    lanes: int,
    expected_checksum: int,
    samples: int,
    schema: dict[str, Any],
) -> list[dict[str, Any]]:
    binaries = {"parent": parent_binary, "candidate": candidate_binary}
    result: list[dict[str, Any]] = []
    for pair_sample in range(samples):
        order = ("parent", "candidate") if pair_sample % 2 == 0 else ("candidate", "parent")
        for position, variant in enumerate(order):
            row = run_one(binaries[variant], mode, workload, jobs, lanes)
            if row.checksum != expected_checksum:
                raise ValueError(
                    f"{variant} pair {pair_sample} checksum {row.checksum} != frozen {expected_checksum}"
                )
            result.append(sample_record(row, variant, pair_sample, position, schema))
    return result


def render(artifact: dict[str, Any]) -> str:
    metadata = artifact["metadata"]
    summary = artifact["summary"]
    return "\n".join([
        f"# Exact-parent performance A/B — {metadata['workload']} ({metadata['mode']}, {metadata['lanes']} lane(s))",
        "",
        f"- parent: `{metadata['parent_revision']}`",
        f"- candidate: `{metadata['candidate_revision']}`",
        f"- zig-gc: `{metadata['zig_gc_revision']}`",
        f"- zig-regex: `{metadata['zig_regex_revision']}`",
        f"- host class: `{metadata['host_class']}`",
        f"- sampling: {metadata['samples']} order-balanced pairs; no discarded samples",
        f"- timed boundary: {metadata['timed_boundary']}",
        "",
        "| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |",
        "| ---: | ---: | ---: | ---: | ---: | --- |",
        f"| {summary['parent_wall_median_ns'] / 1e6:.3f} ms | "
        f"{summary['candidate_wall_median_ns'] / 1e6:.3f} ms | "
        f"{summary['candidate_over_parent']:.3f}x | "
        f"{summary['parent_wall_rsd'] * 100:.2f}% | "
        f"{summary['candidate_wall_rsd'] * 100:.2f}% | `{summary['status']}` |",
        "",
        "All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.",
        "",
    ])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("parent_runner", type=pathlib.Path)
    parser.add_argument("candidate_runner", type=pathlib.Path)
    parser.add_argument("--parent-revision", required=True)
    parser.add_argument("--candidate-revision", default="HEAD")
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--mode", choices=("single", "independent_steady", "independent_cold", "shared"), required=True)
    parser.add_argument("--workload", required=True)
    parser.add_argument("--jobs", type=int, required=True)
    parser.add_argument("--lanes", type=int, default=1)
    parser.add_argument("--expected-checksum", type=int, required=True)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--host-class", choices=("diagnostic", "quiet_reference"), default="diagnostic")
    parser.add_argument("--timed-boundary", required=True)
    parser.add_argument("--schema", type=pathlib.Path, default=attribution.DEFAULT_SCHEMA)
    parser.add_argument("--raw-out", type=pathlib.Path, required=True)
    parser.add_argument("--markdown-out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.samples < 2 or args.jobs <= 0 or args.lanes <= 0 or args.expected_checksum < 0:
        parser.error("samples must be >=2; jobs/lanes positive; checksum non-negative")
    for path in (args.parent_runner, args.candidate_runner, args.source):
        if not path.is_file():
            parser.error(f"input does not exist: {path}")
    schema = attribution.load_schema(args.schema)
    parent_revision, candidate_revision = validate_exact_parent(args.parent_revision, args.candidate_revision)
    for repository in (ROOT, ROOT.parent / "zig-gc", ROOT.parent / "zig-regex"):
        require_clean(repository)
    samples = collect(
        args.parent_runner, args.candidate_runner, args.mode, args.workload,
        args.jobs, args.lanes, args.expected_checksum, args.samples, schema,
    )
    candidate_first_parent = resolve_revision(f"{candidate_revision}^1")
    metadata = {
        "parent_revision": parent_revision,
        "candidate_revision": candidate_revision,
        "candidate_first_parent": candidate_first_parent,
        "zig_gc_revision": repository_revision(ROOT.parent / "zig-gc"),
        "zig_regex_revision": repository_revision(ROOT.parent / "zig-regex"),
        "zig_version": command_output(["zig", "version"]),
        "os": platform.platform(),
        "hardware": platform.machine() + "; " + command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "power": " ".join(command_output(["pmset", "-g", "batt"], "unavailable").split()),
        "host_class": args.host_class,
        "workload_source_sha256": attribution.sha256(args.source),
        "parent_binary_sha256": attribution.sha256(args.parent_runner),
        "candidate_binary_sha256": attribution.sha256(args.candidate_runner),
        "samples": args.samples,
        "timed_boundary": args.timed_boundary,
        "mode": args.mode,
        "workload": args.workload,
        "lanes": args.lanes,
        "jobs": args.jobs,
        "expected_checksum": args.expected_checksum,
    }
    artifact = {
        "schema_version": schema["schema_version"],
        "profile_id": schema["profile_id"],
        "kind": "exact_parent_ab",
        "metadata": metadata,
        "samples": samples,
        "summary": summarize(samples, schema, args.host_class),
    }
    attribution.validate_artifact(artifact, schema)
    args.raw_out.parent.mkdir(parents=True, exist_ok=True)
    args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
    args.raw_out.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    args.markdown_out.write_text(render(artifact))
    if artifact["summary"]["blocks_publication"]:
        print("noise-qualified >10% regression blocks reference-host publication", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
