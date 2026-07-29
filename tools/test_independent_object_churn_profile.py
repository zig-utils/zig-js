#!/usr/bin/env python3
"""Structural tests for the independent object-churn A/B profiler."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


DRIVER = pathlib.Path(__file__).with_name("independent-object-churn-profile.py")
SPEC = importlib.util.spec_from_file_location("independent_object_churn_profile", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


class ProfileTests(unittest.TestCase):
    def test_parse_benchmark_and_rss(self) -> None:
        row = profile.parse_benchmark(
            "zig-js\tindependent_steady\tobject_churn\t8\t100\t0\t250000000\t42\n",
            "candidate", "independent_steady", 8, 3, 1,
            "  123456 maximum resident set size\n",
        )
        self.assertEqual(250000000, row.elapsed_ns)
        self.assertEqual(123456, row.max_rss_bytes)

    def test_classification_separates_identity_from_nursery(self) -> None:
        self.assertEqual("cell publication", profile.classify("heap.Heap(gc.Binding).create__anon_1"))
        self.assertEqual("nursery collection", profile.classify("gc.Binding.realmForCell"))
        self.assertEqual("host allocator", profile.classify("nanov2_malloc"))
        self.assertEqual("GC rendezvous", profile.classify("Context.cooperativeGcRendezvous"))

    def test_validation_rejects_checksum_drift(self) -> None:
        rows = []
        for variant in ("parent", "candidate"):
            for mode in ("independent_steady", "independent_cold"):
                rows.append(profile.Row(variant, mode, 1, 0, int(variant == "candidate"), 10, int(variant == "candidate"), 100))
        with self.assertRaisesRegex(ValueError, "checksum drift"):
            profile.validate(rows, 1, [1])


if __name__ == "__main__":
    unittest.main()
