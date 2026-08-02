#!/usr/bin/env python3
"""Structural tests for representative matrix result validation."""

from __future__ import annotations

import dataclasses
import importlib.util
import json
import pathlib
import sys
import unittest


DRIVER = pathlib.Path(__file__).with_name("representative-benchmark.py")
SPEC = importlib.util.spec_from_file_location("representative_benchmark", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)
MANIFEST = json.loads(benchmark.DEFAULT_MANIFEST.read_text())


def synthetic_rows(samples: int = 1, quick: bool = True, elapsed_ns: int = 60_000_000):
    rows = []
    all_lanes = [1, 2, 4, 8]
    scale = "quick" if quick else "full"
    for family in MANIFEST["implemented_families"]:
        jobs = family["jobs"][scale]

        def add(engine: str, mode: str, workload: str, role: str, lanes: int) -> None:
            checksum = family["checksums"][role][scale][MANIFEST["lanes"].index(lanes)]
            for sample in range(samples):
                rows.append(benchmark.Row(engine, mode, workload, lanes, jobs, sample, elapsed_ns + sample, checksum))

        for role in ("base", "variant"):
            workload = family[role]
            add("zig-js", "single", workload, role, 1)
            add("JavaScriptCore", "single", workload, role, 1)
        for lane_count in all_lanes:
            add("zig-js", "shared", family["base"], "base", lane_count)
            for engine in ("zig-js", "JavaScriptCore"):
                add(engine, "independent_steady", family["base"], "base", lane_count)
                add(engine, "independent_cold", family["base"], "base", lane_count)
    return rows


class ValidationTests(unittest.TestCase):
    def test_complete_quick_matrix_passes(self) -> None:
        benchmark.validate(synthetic_rows(), MANIFEST, 1, [2, 4, 8], True)

    def test_missing_row_fails(self) -> None:
        rows = synthetic_rows()
        rows.pop()
        with self.assertRaisesRegex(RuntimeError, "matrix mismatch"):
            benchmark.validate(rows, MANIFEST, 1, [2, 4, 8], True)

    def test_frozen_checksum_mismatch_fails(self) -> None:
        rows = synthetic_rows()
        rows[0] = dataclasses.replace(rows[0], checksum=rows[0].checksum + 1)
        with self.assertRaisesRegex(RuntimeError, "does not match frozen"):
            benchmark.validate(rows, MANIFEST, 1, [2, 4, 8], True)

    def test_short_full_row_fails(self) -> None:
        rows = synthetic_rows(quick=False, elapsed_ns=1_000_000)
        with self.assertRaisesRegex(RuntimeError, "timing floor"):
            benchmark.validate(rows, MANIFEST, 1, [2, 4, 8], False)


if __name__ == "__main__":
    unittest.main()
