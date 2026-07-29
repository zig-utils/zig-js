#!/usr/bin/env python3
"""Structural tests for the shared object-churn reserve A/B."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


DRIVER = pathlib.Path(__file__).with_name("shared-object-churn-ab.py")
SPEC = importlib.util.spec_from_file_location("shared_object_churn_ab", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


def output(lane: int, checksum: int = 42) -> str:
    fields = sorted(profile.INTEGER_FIELDS - {"lanes", "elapsed_ns", "checksum"})
    header = ["zig-js-gc", "lanes", "elapsed_ns", "checksum", *fields]
    values: list[str] = ["zig-js-gc", str(lane), "250000000", str(checksum)]
    for field in fields:
        if field == "worker_runs":
            values.append(str(lane))
        elif field in ("collections", "minor_cycles", "heap_minor_collections"):
            values.append("0")
        else:
            values.append("1")
    return (
        "\t".join(header)
        + "\n"
        + f"zig-js\tshared\tobject_churn\t{lane}\t100\t0\t250000000\t{checksum}\n"
        + "\t".join(values)
        + "\n"
    )


class ProfileTests(unittest.TestCase):
    def test_parse_benchmark_telemetry_and_rss(self) -> None:
        row = profile.parse_output(
            output(8),
            "  123456 maximum resident set size\n",
            "candidate",
            3,
            1,
        )
        self.assertEqual(8, row["lanes"])
        self.assertEqual(123456, row["max_rss_bytes"])
        self.assertEqual("candidate", row["variant"])

    def test_validation_rejects_checksum_drift(self) -> None:
        rows = [
            profile.parse_output(output(1, 41), "  100 maximum resident set size\n", "parent", 0, 0),
            profile.parse_output(output(1, 42), "  100 maximum resident set size\n", "candidate", 0, 1),
        ]
        with self.assertRaisesRegex(ValueError, "checksum drift"):
            profile.validate(rows, 1, [1])

    def test_render_reports_scaling_and_publication_reduction(self) -> None:
        rows = []
        for lane in (1, 8):
            for order, variant in enumerate(("parent", "candidate")):
                row = profile.parse_output(
                    output(lane),
                    "  100 maximum resident set size\n",
                    variant,
                    0,
                    order,
                )
                row["object_batch_calls"] = 100 if variant == "parent" else 10
                rows.append(row)
        profile.validate(rows, 1, [1, 8])
        report = profile.render(rows, [1, 8], 1, "parent", "candidate", "gc", "raw.tsv")
        self.assertIn("Candidate eight-lane scaling", report)
        self.assertIn("10.0x fewer", report)


if __name__ == "__main__":
    unittest.main()
