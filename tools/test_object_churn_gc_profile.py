#!/usr/bin/env python3
"""Structural tests for the object-churn GC phase profiler."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


DRIVER = pathlib.Path(__file__).with_name("object-churn-gc-profile.py")
SPEC = importlib.util.spec_from_file_location("object_churn_gc_profile", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
profile = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = profile
SPEC.loader.exec_module(profile)


HEADER = "zig-js-gc\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum\tattempts\tcollections\ttimeouts\tpeer_parks\texit_cleanups\tpause_ns_total\tpause_ns_max\trendezvous_ns_total\trendezvous_ns_max\ttranche_bytes\tbytes_issued\tbytes_reset\tbytes_current\tminor_cycles\tminor_prepare_ns\tminor_trace_ns\tminor_sweep_ns\tminor_post_sweep_ns\tfull_cycles\tfull_prepare_ns\tfull_trace_ns\tfull_sweep_ns\tfull_post_sweep_ns\tobject_batch_calls\tobject_batch_cells\tobject_batch_ns_total\tobject_batch_ns_max\tworker_runs\tworker_run_ns\tworker_run_ns_max\tjoin_wait_ns\tjoin_parks\theap_collections\theap_minor_collections\theap_live_cells\theap_young_cells\theap_young_bytes\tlast_minor_young_bytes\tlast_minor_reclaimed_bytes\tlast_minor_survived_cells\tlast_minor_survived_bytes\tbacking_chunks\tbacking_capacity_slots\tbacking_live_slots\tbacking_free_slots"


def output(lanes: int = 2, checksum: int = 42) -> str:
    values = ["zig-js-gc", "object_churn", str(lanes), "100", "0", "100000000", str(checksum)]
    numeric = {
        name: 0 for name in HEADER.split("\t")[7:]
    }
    numeric.update({
        "attempts": int(lanes > 1), "collections": int(lanes > 1),
        "peer_parks": max(0, lanes - 1), "pause_ns_total": 30,
        "rendezvous_ns_total": 5, "bytes_issued": 1024 if lanes > 1 else 0,
        "minor_cycles": int(lanes > 1), "minor_prepare_ns": 5,
        "minor_trace_ns": 5, "minor_sweep_ns": 10, "minor_post_sweep_ns": 1,
        "worker_runs": lanes, "heap_collections": int(lanes > 1),
        "heap_minor_collections": int(lanes > 1),
    })
    values.extend(str(numeric[name]) for name in HEADER.split("\t")[7:])
    return "\n".join((HEADER, f"zig-js\tshared\tobject_churn\t{lanes}\t100\t0\t100000000\t{checksum}", "\t".join(values)))


class ProfileTests(unittest.TestCase):
    def test_parse_and_validate(self) -> None:
        rows = [profile.parse_output(output(lane), 0) for lane in (1, 2, 4, 8)]
        profile.validate(rows, 1, [1, 2, 4, 8])

    def test_checksum_disagreement_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "disagree"):
            profile.parse_output(output().replace("\t42\nzig-js-gc", "\t43\nzig-js-gc"), 0)

    def test_phase_incoherence_fails(self) -> None:
        row = profile.parse_output(output(), 0)
        row["minor_sweep_ns"] = 100
        with self.assertRaisesRegex(ValueError, "incoherent"):
            profile.validate([row], 1, [2])

    def test_render_identifies_measured_sweep_followup(self) -> None:
        rows = [profile.parse_output(output(lane), 0) for lane in (1, 2, 4, 8)]
        report = profile.render(rows, [1, 2, 4, 8], 1, "zig-js-rev", "zig-gc-rev")
        self.assertIn("## Finding", report)
        self.assertIn("Nursery sweep", report)
        self.assertIn("zig-js/issues/427", report)
        self.assertIn("zig-gc/issues/42", report)


if __name__ == "__main__":
    unittest.main()
