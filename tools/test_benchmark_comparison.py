#!/usr/bin/env python3
"""Standalone structural tests for the comparison benchmark driver."""

from __future__ import annotations

import dataclasses
import importlib.util
import pathlib
import sys
import unittest


DRIVER = pathlib.Path(__file__).with_name("benchmark-comparison.py")
SPEC = importlib.util.spec_from_file_location("benchmark_comparison", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


def synthetic_rows(*, samples: int = 1, quick: bool = True, elapsed_ns: int = 60_000_000):
    rows = []
    all_lanes = [1, 2, 4, 8]
    for workload_index, (workload, default_jobs) in enumerate(benchmark.WORKLOADS.items(), start=1):
        jobs = max(1, default_jobs // 20) if quick else default_jobs

        def add(engine: str, mode: str, lanes: int) -> None:
            for sample in range(samples):
                rows.append(benchmark.Row(
                    engine=engine,
                    mode=mode,
                    workload=workload,
                    lanes=lanes,
                    jobs=jobs,
                    sample=sample,
                    elapsed_ns=elapsed_ns + sample,
                    checksum=workload_index * 1000 * lanes,
                ))

        add("zig-js", "single", 1)
        add("JavaScriptCore", "single", 1)
        for lane_count in all_lanes:
            add("zig-js", "shared", lane_count)
            for engine in ("zig-js", "JavaScriptCore"):
                add(engine, "independent_steady", lane_count)
                add(engine, "independent_cold", lane_count)
    return rows


class ValidationTests(unittest.TestCase):
    def test_complete_matrix_passes(self) -> None:
        benchmark.validate(synthetic_rows(), 1, [2, 4, 8], True)

    def test_missing_group_fails(self) -> None:
        rows = synthetic_rows()
        rows.pop()
        with self.assertRaisesRegex(RuntimeError, "result matrix mismatch"):
            benchmark.validate(rows, 1, [2, 4, 8], True)

    def test_duplicate_row_fails(self) -> None:
        rows = synthetic_rows()
        rows.append(rows[0])
        with self.assertRaisesRegex(RuntimeError, "has 2 samples"):
            benchmark.validate(rows, 1, [2, 4, 8], True)

    def test_checksum_mismatch_fails(self) -> None:
        rows = synthetic_rows()
        target = next(index for index, row in enumerate(rows) if row.engine == "JavaScriptCore")
        rows[target] = dataclasses.replace(rows[target], checksum=rows[target].checksum + 1)
        with self.assertRaisesRegex(RuntimeError, "cross-engine checksum mismatch"):
            benchmark.validate(rows, 1, [2, 4, 8], True)

    def test_short_full_sample_fails(self) -> None:
        rows = synthetic_rows(quick=False)
        rows[0] = dataclasses.replace(rows[0], elapsed_ns=1_000_000)
        with self.assertRaisesRegex(RuntimeError, "median is shorter"):
            benchmark.validate(rows, 1, [2, 4, 8], False)


class PublicationTests(unittest.TestCase):
    def test_dirty_evidence_publication_fails(self) -> None:
        info = {"zig-js": "deadbeef (tracked worktree dirty)"}
        with self.assertRaisesRegex(ValueError, "dirty tracked worktree"):
            benchmark.ensure_publishable(info, True)

    def test_dirty_nonpublishing_run_passes(self) -> None:
        benchmark.ensure_publishable({"zig-js": "deadbeef (tracked worktree dirty)"}, False)


if __name__ == "__main__":
    unittest.main()
