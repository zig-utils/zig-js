#!/usr/bin/env python3
"""Structural tests for the representative performance-matrix contract."""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import sys
import unittest


TOOL = pathlib.Path(__file__).with_name("representative-matrix.py")
SPEC = importlib.util.spec_from_file_location("representative_matrix", TOOL)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {TOOL}")
matrix = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = matrix
SPEC.loader.exec_module(matrix)


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(matrix.DEFAULT_MANIFEST.read_text())

    def test_checked_in_manifest_passes(self) -> None:
        matrix.validate(self.manifest)

    def test_missing_family_fails(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["deferred_families"].pop()
        with self.assertRaisesRegex(ValueError, "exactly cover"):
            matrix.validate(changed)

    def test_missing_variant_dispatch_fails(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["implemented_families"][0]["variant"] = "representative_absent_variant"
        with self.assertRaisesRegex(ValueError, "absent from representative source dispatch"):
            matrix.validate(changed)

    def test_checksum_lane_mismatch_fails(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["implemented_families"][0]["checksums"]["base"]["full"].pop()
        with self.assertRaisesRegex(ValueError, "checksums must match lanes"):
            matrix.validate(changed)

    def test_shared_jsc_ratio_fails(self) -> None:
        changed = copy.deepcopy(self.manifest)
        changed["modes"]["shared"]["engines"].append("JavaScriptCore")
        with self.assertRaisesRegex(ValueError, "must not construct a JSC ratio"):
            matrix.validate(changed)


if __name__ == "__main__":
    unittest.main()
