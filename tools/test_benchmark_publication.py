#!/usr/bin/env python3
"""Tests for benchmark history validation and README generation."""

from __future__ import annotations

import dataclasses
import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).with_name("benchmark-publication.py")
SPEC = importlib.util.spec_from_file_location("benchmark_publication", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
publication = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = publication
SPEC.loader.exec_module(publication)


def metadata(**updates):
    result = {
        "Date": "2026-07-16",
        "Host": "Example CPU; 8 physical / 8 logical CPUs; 16.0 GiB",
        "OS": "macOS 27.0 (A)",
        "Zig": "0.17.0-dev",
        "zig-js": "new",
        "zig-gc": "gc",
        "zig-regex": "regex",
        "JavaScriptCore": "system framework 1",
        "Power": "AC Power",
    }
    result.update(updates)
    return result


def rows(elapsed=(100, 101, 99)):
    return [
        publication.benchmark.Row("zig-js", "single", "arithmetic", 1, 1, sample, value, 1)
        for sample, value in enumerate(elapsed)
    ] + [
        publication.benchmark.Row("JavaScriptCore", "single", "arithmetic", 1, 1, sample, 200, 1)
        for sample in range(len(elapsed))
    ]


class HistoryTests(unittest.TestCase):
    def test_like_for_like_allows_zig_js_revision_change(self) -> None:
        publication.ensure_like_for_like(metadata(**{"zig-js": "new"}), metadata(**{"zig-js": "old"}), rows(), rows())

    def test_environment_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "not like-for-like"):
            publication.ensure_like_for_like(metadata(Zig="new"), metadata(Zig="old"), rows(), rows())

    def test_battery_percentage_is_not_environment_identity(self) -> None:
        current = metadata(Power="Battery Power 32%; discharging")
        baseline = metadata(Power="Battery Power 91%; discharging")
        publication.ensure_like_for_like(current, baseline, rows(), rows())

    def test_power_state_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Power"):
            publication.ensure_like_for_like(
                metadata(Power="AC Power; charged"),
                metadata(Power="Battery Power 91%; discharging"),
                rows(),
                rows(),
            )

    def test_matrix_mismatch_is_rejected(self) -> None:
        changed = [dataclasses.replace(row, jobs=2) for row in rows()]
        with self.assertRaisesRegex(ValueError, "matrices are not like-for-like"):
            publication.ensure_like_for_like(metadata(), metadata(), changed, rows())

    def test_low_dispersion_regression_fails_threshold(self) -> None:
        found = publication.regression_rows(rows((121, 120, 119)), rows((100, 101, 99)))
        self.assertEqual(1, len(found))

    def test_noisy_regression_does_not_false_fail(self) -> None:
        found = publication.regression_rows(rows((80, 120, 160)), rows((100, 101, 99)))
        self.assertEqual([], found)

    def test_history_retains_every_engine_row(self) -> None:
        found = publication.history_rows(rows(), rows())
        self.assertEqual(["control", "stable"], sorted(row[-1] for row in found))


class ReadmeTests(unittest.TestCase):
    def test_marker_replacement_is_idempotent(self) -> None:
        initial = f"before\n{publication.README_START}\nold\n{publication.README_END}\nafter\n"
        once = publication.replace_readme_block(initial, "generated")
        twice = publication.replace_readme_block(once, "generated")
        self.assertEqual(once, twice)

    def test_missing_markers_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one"):
            publication.replace_readme_block("no markers", "generated")


if __name__ == "__main__":
    unittest.main()
