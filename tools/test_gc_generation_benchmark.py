#!/usr/bin/env python3
"""Tests for GC generation benchmark validation and README publication."""

from __future__ import annotations

import dataclasses
import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("gc-generation-benchmark.py")
SPEC = importlib.util.spec_from_file_location("gc_generation_benchmark", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
benchmark = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = benchmark
SPEC.loader.exec_module(benchmark)


def row(**updates):
    base = benchmark.Row(
        trigger="automatic",
        scenario="mixed",
        tenuring_age=3,
        moving=0,
        trigger_bytes=4 * benchmark.MIB,
        sample=0,
        rounds=8,
        batch=24576,
        elapsed_ns=100_000_000,
        checksum=8 * 24576 * 24576,
        minor_collections=4,
        full_collections=0,
        young_input_bytes=1000,
        survived_bytes=250,
        reclaimed_bytes=750,
        promoted_bytes=100,
        moving_minor_collections=0,
        moved_cells=0,
        moved_bytes=0,
        move_failures=0,
        live_bytes=500,
        young_bytes=50,
        next_threshold_bytes=4 * benchmark.MIB,
        backing_chunks=10,
        backing_capacity_bytes=10 * benchmark.MIB,
        pause_total_ns=1_000_000,
        pause_max_ns=400_000,
        cooperative_attempts=0,
        cooperative_collections=0,
        cooperative_parks=0,
        cooperative_timeouts=0,
    )
    return dataclasses.replace(base, **updates)


class RowTests(unittest.TestCase):
    def test_parse_round_trip(self) -> None:
        expected = row()
        text = "\t".join(str(getattr(expected, field)) for field in benchmark.Row.__annotations__)
        self.assertEqual(expected, benchmark.parse_row(text))

    def test_byte_conservation_is_required(self) -> None:
        with self.assertRaisesRegex(ValueError, "conservation"):
            benchmark.validate_row(row(reclaimed_bytes=749), quick=False)

    def test_shared_requires_bounded_rendezvous(self) -> None:
        shared = row(
            trigger="shared",
            checksum=3 * 8 * 24576 * 24576,
            cooperative_attempts=3,
            cooperative_collections=3,
            cooperative_parks=3,
        )
        benchmark.validate_row(shared, quick=False)
        with self.assertRaisesRegex(ValueError, "rendezvous"):
            benchmark.validate_row(dataclasses.replace(shared, cooperative_timeouts=1), quick=False)
        moving = dataclasses.replace(
            shared,
            moving=1,
            moving_minor_collections=1,
            moved_cells=8,
            moved_bytes=1024,
            full_collections=1,
            cooperative_timeouts=2,
        )
        benchmark.validate_row(moving, quick=False)
        with self.assertRaisesRegex(ValueError, "rendezvous"):
            benchmark.validate_row(dataclasses.replace(moving, cooperative_timeouts=3), quick=False)

    def test_non_shared_rejects_cooperative_telemetry(self) -> None:
        with self.assertRaisesRegex(ValueError, "unexpected cooperative"):
            benchmark.validate_row(row(cooperative_attempts=1), quick=False)

    def test_moving_rows_require_copy_telemetry(self) -> None:
        moving = row(
            moving=1,
            moving_minor_collections=3,
            moved_cells=12,
            moved_bytes=4096,
        )
        benchmark.validate_row(moving, quick=False)
        with self.assertRaisesRegex(ValueError, "moving-minor"):
            benchmark.validate_row(dataclasses.replace(moving, moved_bytes=0), quick=False)
        benchmark.validate_row(
            row(
                scenario="ephemeral",
                moving=1,
                moving_minor_collections=3,
            ),
            quick=False,
        )

    def test_nonmoving_rows_reject_copy_telemetry(self) -> None:
        with self.assertRaisesRegex(ValueError, "unexpected moving-minor"):
            benchmark.validate_row(row(moved_bytes=4096), quick=False)


class PublicationTests(unittest.TestCase):
    def test_readme_marker_replacement_is_idempotent(self) -> None:
        initial = f"before\n{benchmark.README_START}\nold\n{benchmark.README_END}\nafter\n"
        generated = f"{benchmark.README_START}\nnew\n{benchmark.README_END}"
        once = benchmark.replace_readme_block(initial, generated)
        twice = benchmark.replace_readme_block(once, generated)
        self.assertEqual(once, twice)

    def test_readme_requires_one_marker_pair(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one"):
            benchmark.replace_readme_block("missing", "generated")

    def test_stable_age_three_regression_is_rejected(self) -> None:
        rows = []
        for sample, elapsed in enumerate((100_000_000, 101_000_000, 99_000_000)):
            for moving in (0, 1):
                movement = {
                    "moving": moving,
                    "moving_minor_collections": 3 if moving else 0,
                    "moved_cells": 12 if moving else 0,
                    "moved_bytes": 4096 if moving else 0,
                }
                rows.append(row(tenuring_age=1, sample=sample, elapsed_ns=elapsed, **movement))
                rows.append(row(tenuring_age=3, sample=sample, elapsed_ns=elapsed * 2, **movement))
        with self.assertRaisesRegex(ValueError, "regression"):
            benchmark.validate_matrix(rows, 3, quick=False)


if __name__ == "__main__":
    unittest.main()
