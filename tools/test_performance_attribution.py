#!/usr/bin/env python3
"""Structural tests for the stable performance-attribution contract."""

from __future__ import annotations

import copy
import importlib.util
import pathlib
import sys
import unittest


TOOL = pathlib.Path(__file__).with_name("performance-attribution.py")
SPEC = importlib.util.spec_from_file_location("performance_attribution", TOOL)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {TOOL}")
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)
SCHEMA = profile.load_schema()


class AttributionContractTests(unittest.TestCase):
    def test_checked_in_schema_passes(self) -> None:
        profile.validate_schema(SCHEMA)

    def test_metric_removal_fails(self) -> None:
        changed = copy.deepcopy(SCHEMA)
        changed["metrics"] = [metric for metric in changed["metrics"] if metric["name"] != "optimizer_deopts"]
        with self.assertRaisesRegex(ValueError, "optimizer_deopts"):
            profile.validate_schema(changed)

    def test_metric_addition_requires_a_new_schema_version(self) -> None:
        changed = copy.deepcopy(SCHEMA)
        changed["metrics"].append({"name": "silent_new_metric", "unit": "count", "scope": "test", "kind": "counter"})
        with self.assertRaisesRegex(ValueError, "extra=.*silent_new_metric"):
            profile.validate_schema(changed)

    def test_unavailable_is_not_encoded_as_zero(self) -> None:
        with self.assertRaisesRegex(ValueError, "null value"):
            profile.observation("unavailable", 0, "", "missing")

    def test_independent_legacy_artifact_migrates_losslessly(self) -> None:
        source = profile.ROOT / "docs/.data/object-churn-independent-id-block-ab-2026-07-29.tsv"
        artifact = profile.migrate_legacy_tsv(source, SCHEMA)
        profile.validate_artifact(artifact, SCHEMA)
        self.assertEqual(profile.sha256(source), artifact["legacy"]["source_sha256"])
        self.assertEqual(112, len(artifact["samples"]))
        first = artifact["samples"][0]
        self.assertEqual(first["legacy_fields"]["elapsed_ns"], first["metrics"]["wall_time_ns"]["value"])
        self.assertEqual("measured", first["metrics"]["peak_rss_bytes"]["status"])
        self.assertEqual("unavailable", first["metrics"]["optimizer_deopts"]["status"])

    def test_shared_gc_legacy_artifact_maps_phase_counters(self) -> None:
        source = profile.ROOT / "docs/.data/object-churn-shared-reserve-ab-2026-07-29.tsv"
        artifact = profile.migrate_legacy_tsv(source, SCHEMA)
        profile.validate_artifact(artifact, SCHEMA)
        self.assertEqual(56, len(artifact["samples"]))
        first = artifact["samples"][0]
        self.assertEqual(first["legacy_fields"]["minor_cycles"], first["metrics"]["gc_minor_cycles"]["value"])
        self.assertEqual(first["legacy_fields"]["object_batch_cells"], first["metrics"]["allocator_publication_cells"]["value"])
        self.assertEqual("measured", first["metrics"]["thread_join_wait_ns"]["status"])


if __name__ == "__main__":
    unittest.main()
