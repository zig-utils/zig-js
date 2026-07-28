#!/usr/bin/env python3
"""Generate or verify the supported release platform matrix."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"
BENCHMARK_REPORT = ROOT / "docs/.data/benchmark-comparison-2026-07-22-property-osr.md"
BENCHMARK_RAW = ROOT / "docs/.data/benchmark-comparison-2026-07-22-property-osr.tsv"
OUTPUT_JSON = ROOT / "docs/.data/platform-release-matrix-2026-07-28.json"
OUTPUT_MD = ROOT / "docs/platforms.md"

REQUIRED_TOP_LEVEL_JOBS = {
    "gate",
    "tsan-nogil-corpus",
    "nogil-corpus-functional",
    "nogil-corpus-releasesafe",
    "nightly-threadfuzz-tsan",
    "test262-parallel",
    "docs",
}

REQUIRED_GATE_MATRIX = {
    "unit (shard 0/4)",
    "unit (shard 1/4)",
    "unit (shard 2/4)",
    "unit (shard 3/4)",
    "threads-gil (shard 0/4)",
    "threads-gil (shard 1/4)",
    "threads-gil (shard 2/4)",
    "threads-gil (shard 3/4)",
    "threads-nogil-witness",
    "threads-reference-audit",
    "threads-execution-inventory-witness",
    "benchmark-comparison-harness",
    "wasm-feature-profiles",
    "wasm-mvp-smoke",
    "wasm-core-2-structural-smoke",
    "wasm-simd-smoke",
    "wasm-threads-smoke",
    "wasm-post-mvp-smoke",
    "wasm-core-3-memory64-gc-smoke",
    "focused-engine-tests",
    "private-abi-boundary",
    "tsan-unit (shard 0/4)",
    "tsan-unit (shard 1/4)",
    "tsan-unit (shard 2/4)",
    "tsan-unit (shard 3/4)",
    "tsan-parallel-js",
    "threadfuzz",
    "tsan-threadfuzz",
    "tsan-threadfuzz-watchdog-cleanup",
    "tsan-threadfuzz-midgc",
    "tsan-threadfuzz-lifecycle",
    "threadfuzz-amplified",
    "threadfuzz-broad",
    "threadfuzz-midgc",
    "threadfuzz-lifecycle",
    "releasesafe-threadfuzz",
    "threadfuzz-verify",
}

SANITIZER_GATE_MATRIX = {
    "private-abi-boundary",
    "tsan-unit (shard 0/4)",
    "tsan-unit (shard 1/4)",
    "tsan-unit (shard 2/4)",
    "tsan-unit (shard 3/4)",
    "tsan-parallel-js",
    "tsan-threadfuzz",
    "tsan-threadfuzz-watchdog-cleanup",
    "tsan-threadfuzz-midgc",
    "tsan-threadfuzz-lifecycle",
}


def fail(message: str) -> None:
    raise SystemExit(f"platform-release-matrix: {message}")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def top_level_jobs(workflow: str) -> list[str]:
    jobs: list[str] = []
    in_jobs = False
    for line in workflow.splitlines():
        if line == "jobs:":
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line and not line.startswith(" ") and not line.startswith("#"):
            break
        if (
            line.startswith("  ")
            and not line.startswith("    ")
            and line.strip().endswith(":")
            and not line.strip().startswith("#")
        ):
            jobs.append(line.strip()[:-1])
    return jobs


def job_block(workflow: str, job: str) -> str:
    pattern = re.compile(rf"^  {re.escape(job)}:\n", re.M)
    match = pattern.search(workflow)
    if match is None:
        fail(f"missing CI job {job}")
    next_match = re.search(r"^  [A-Za-z0-9_-]+:\n", workflow[match.end():], re.M)
    end = match.end() + next_match.start() if next_match is not None else len(workflow)
    return workflow[match.start():end]


def gate_matrix_names(gate: str) -> list[str]:
    return re.findall(r"^\s{10}- name: (.+)$", gate, re.M)


def parse_report_metadata(report: str) -> dict[str, str]:
    metadata: dict[str, str] = {}
    in_environment = False
    for line in report.splitlines():
        if line == "## Environment":
            in_environment = True
            continue
        if in_environment and line.startswith("## "):
            break
        if not in_environment or not line.startswith("|"):
            continue
        fields = [field.strip() for field in line.strip("|").split("|")]
        if len(fields) == 2 and fields[0] not in {"item", "---"}:
            metadata[fields[0]] = fields[1]
    for key in ("Date", "Host", "OS", "Zig", "zig-js", "zig-gc", "zig-regex", "JavaScriptCore"):
        if key not in metadata:
            fail(f"benchmark report missing {key}")
    return metadata


def raw_sample_count(raw: str) -> int:
    lines = [line for line in raw.splitlines() if line]
    if not lines or lines[0] != "engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum":
        fail("benchmark raw TSV header drift")
    return len(lines) - 1


def validate_inputs() -> tuple[str, list[str], dict[str, str], int]:
    workflow = WORKFLOW.read_text()
    jobs = top_level_jobs(workflow)
    duplicates = sorted({job for job in jobs if jobs.count(job) > 1})
    if duplicates:
        fail(f"duplicate top-level CI jobs: {duplicates}")
    missing_jobs = sorted(REQUIRED_TOP_LEVEL_JOBS - set(jobs))
    if missing_jobs:
        fail(f"missing top-level CI jobs: {missing_jobs}")
    for job in REQUIRED_TOP_LEVEL_JOBS:
        block = job_block(workflow, job)
        if job != "nightly-threadfuzz-tsan" and "runs-on: ubuntu-latest" not in block:
            fail(f"{job}: release CI runner is not ubuntu-latest")

    if "pull_request:" not in workflow or "branches: [main]" not in workflow:
        fail("workflow trigger drift")
    if "schedule:" not in workflow or "workflow_dispatch:" not in workflow:
        fail("manual/nightly platform trigger drift")

    gate = job_block(workflow, "gate")
    matrix_names = gate_matrix_names(gate)
    missing_matrix = sorted(REQUIRED_GATE_MATRIX - set(matrix_names))
    if missing_matrix:
        fail(f"missing gate matrix entries: {missing_matrix}")
    if sorted(SANITIZER_GATE_MATRIX - set(matrix_names)):
        fail("sanitizer matrix entries are missing")
    if "TSAN_OPTIONS=\"halt_on_error=1\"" not in job_block(workflow, "tsan-nogil-corpus"):
        fail("TSan corpus gate no longer halts on first race")
    if "tools/nogil-corpus-gate.py" not in job_block(workflow, "nogil-corpus-functional"):
        fail("Debug no-GIL corpus gate drift")
    if "tools/nogil-corpus-gate.py" not in job_block(workflow, "nogil-corpus-releasesafe"):
        fail("ReleaseSafe no-GIL corpus gate drift")
    test262_parallel = job_block(workflow, "test262-parallel")
    if "zig build test262-bin -Dtest262-parallel-js=true" not in test262_parallel:
        fail("test262 parallel platform gate drift")
    if "parallel mode introduced" not in test262_parallel:
        fail("test262 parallel baseline comparison drift")

    metadata = parse_report_metadata(BENCHMARK_REPORT.read_text())
    if not metadata["Host"].startswith("Apple M3 Pro"):
        fail("benchmark host is no longer macOS arm64 release evidence")
    if not metadata["OS"].startswith("macOS "):
        fail("benchmark OS is not macOS")
    samples = raw_sample_count(BENCHMARK_RAW.read_text())
    if samples != 1540:
        fail(f"benchmark sample count drift: {samples}")
    return workflow, matrix_names, metadata, samples


def build_matrix() -> dict[str, object]:
    workflow, matrix_names, metadata, samples = validate_inputs()
    correctness_names = sorted(name for name in matrix_names if name not in SANITIZER_GATE_MATRIX)
    return {
        "schema_version": 1,
        "kind": "zig_js_platform_release_matrix",
        "status": "published",
        "generated_at": "2026-07-28",
        "inputs": {
            ".github/workflows/ci.yml": digest(WORKFLOW),
            "docs/.data/benchmark-comparison-2026-07-22-property-osr.md": digest(BENCHMARK_REPORT),
            "docs/.data/benchmark-comparison-2026-07-22-property-osr.tsv": digest(BENCHMARK_RAW),
        },
        "triggers": ["pull_request", "push:main", "workflow_dispatch", "nightly:schedule"],
        "platforms": [
            {
                "id": "linux-x86_64-ci",
                "os": "linux",
                "architecture": "x86_64",
                "runner": "ubuntu-latest",
                "correctness": {
                    "status": "gated",
                    "jobs": correctness_names,
                    "evidence": [".github/workflows/ci.yml"],
                },
                "sanitizers": {
                    "status": "gated",
                    "jobs": sorted(SANITIZER_GATE_MATRIX | {"tsan-nogil-corpus", "nightly-threadfuzz-tsan"}),
                    "evidence": [".github/workflows/ci.yml"],
                },
                "performance": {
                    "status": "not_claimed",
                    "reason": "No checked release throughput artifact is published for Linux x86_64.",
                },
            },
            {
                "id": "macos-arm64-performance",
                "os": "macos",
                "architecture": "arm64",
                "runner": "local-Apple-M3-Pro",
                "correctness": {
                    "status": "not_release_gated",
                    "reason": "macOS correctness exists in host-specific build/test steps but is not the final release CI correctness matrix.",
                },
                "sanitizers": {
                    "status": "not_release_gated",
                    "reason": "macOS sanitizer coverage is host-specific and not the final release CI sanitizer matrix.",
                },
                "performance": {
                    "status": "published",
                    "host": metadata["Host"],
                    "os": metadata["OS"],
                    "samples": samples,
                    "evidence": [
                        "docs/.data/benchmark-comparison-2026-07-22-property-osr.md",
                        "docs/.data/benchmark-comparison-2026-07-22-property-osr.tsv",
                    ],
                },
            },
        ],
        "summary": {
            "correctness_gated_platforms": 1,
            "sanitizer_gated_platforms": 1,
            "performance_published_platforms": 1,
            "linux_gate_matrix_entries": len(matrix_names),
            "benchmark_samples": samples,
        },
        "unclaimed": [
            "No Windows release platform is claimed.",
            "No Linux throughput artifact is claimed.",
            "No macOS release CI correctness or sanitizer gate is claimed by this matrix.",
            "No architecture-specific WebAssembly or JIT fast path is claimed beyond the artifacts cited by their own gates.",
        ],
    }


def render_markdown(matrix: dict[str, object]) -> str:
    linux, mac = matrix["platforms"]
    lines = [
        "# Supported Platform Matrix",
        "",
        "<!-- Generated by tools/platform-release-matrix.py; do not edit by hand. -->",
        "",
        "This is the release support boundary for correctness, sanitizer, and performance evidence.",
        "It records what is gated or published; it does not imply broader OS or architecture support.",
        "",
        "| platform | correctness | sanitizer | performance | evidence |",
        "| --- | --- | --- | --- | --- |",
        (
            f"| Linux x86_64 (`ubuntu-latest`) | gated ({matrix['summary']['linux_gate_matrix_entries']} CI matrix entries) "
            f"| gated (TSan unit/fuzz/corpus legs) | not claimed "
            f"| [workflow](../.github/workflows/ci.yml) |"
        ),
        (
            f"| macOS arm64 (`Apple M3 Pro`) | not release-gated | not release-gated "
            f"| published ({mac['performance']['samples']} samples) "
            f"| [report](.data/benchmark-comparison-2026-07-22-property-osr.md) · [raw](.data/benchmark-comparison-2026-07-22-property-osr.tsv) |"
        ),
        "",
        "## Unclaimed",
        "",
    ]
    lines.extend(f"- {item}" for item in matrix["unclaimed"])
    lines.extend([
        "",
        "The machine-readable matrix is checked in at "
        "[`platform-release-matrix-2026-07-28.json`](.data/platform-release-matrix-2026-07-28.json).",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="rewrite the checked-in platform matrix and Markdown")
    parser.add_argument("--json-output", type=Path, default=OUTPUT_JSON)
    parser.add_argument("--markdown-output", type=Path, default=OUTPUT_MD)
    args = parser.parse_args()

    matrix = build_matrix()
    rendered_json = json.dumps(matrix, indent=2, sort_keys=True) + "\n"
    rendered_md = render_markdown(matrix)
    if args.write:
        args.json_output.write_text(rendered_json)
        args.markdown_output.write_text(rendered_md)
        print(f"platform release matrix written: {args.json_output}, {args.markdown_output}")
        return 0
    if not args.json_output.is_file() or args.json_output.read_text() != rendered_json:
        fail("JSON drift; run tools/platform-release-matrix.py --write")
    if not args.markdown_output.is_file() or args.markdown_output.read_text() != rendered_md:
        fail("Markdown drift; run tools/platform-release-matrix.py --write")
    print(
        "platform release matrix: "
        f"{matrix['summary']['correctness_gated_platforms']} correctness, "
        f"{matrix['summary']['sanitizer_gated_platforms']} sanitizer, "
        f"{matrix['summary']['performance_published_platforms']} performance platform"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
