#!/usr/bin/env python3
"""Unit tests for exact-parent identity, pairing, and regression gates."""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


TOOL = pathlib.Path(__file__).with_name("exact-parent-regression.py")
SPEC = importlib.util.spec_from_file_location("exact_parent_regression", TOOL)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {TOOL}")
regression = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = regression
SPEC.loader.exec_module(regression)
SCHEMA = regression.attribution.load_schema()


def synthetic_samples(parent: list[int], candidate: list[int]):
    result = []
    for pair_sample, (parent_wall, candidate_wall) in enumerate(zip(parent, candidate)):
        order = ("parent", "candidate") if pair_sample % 2 == 0 else ("candidate", "parent")
        walls = {"parent": parent_wall, "candidate": candidate_wall}
        for position, variant in enumerate(order):
            row = regression.RunnerRow(
                engine="zig-js",
                mode="single",
                workload="representative_json",
                lanes=1,
                jobs=2200,
                elapsed_ns=walls[variant],
                checksum=324952086,
                process_cpu_user_ns=max(0, walls[variant] - 100),
                process_cpu_system_ns=100,
                peak_rss_bytes=10_000_000,
            )
            result.append(regression.sample_record(row, variant, pair_sample, position, SCHEMA))
    return result


class ExactParentTests(unittest.TestCase):
    def test_current_head_and_first_parent_validate(self) -> None:
        head = regression.resolve_revision("HEAD")
        parent = regression.resolve_revision("HEAD^1")
        self.assertEqual((parent, head), regression.validate_exact_parent(parent, head))

    def test_non_parent_commit_fails(self) -> None:
        head = regression.resolve_revision("HEAD")
        grandparent = regression.resolve_revision("HEAD~2")
        with self.assertRaisesRegex(ValueError, "not requested exact parent"):
            regression.validate_exact_parent(grandparent, head)

    def test_runner_row_identity_is_exact(self) -> None:
        stdout = "zig-js\tsingle\trepresentative_json\t1\t2200\t0\t60000000\t324952086\n"
        self.assertEqual(
            ("zig-js", 60_000_000, 324_952_086),
            regression.parse_benchmark(stdout, "single", "representative_json", 1, 2200),
        )
        with self.assertRaisesRegex(ValueError, "identity drift"):
            regression.parse_benchmark(stdout, "single", "representative_regexp", 1, 2200)

    def test_quiet_stable_regression_blocks(self) -> None:
        samples = synthetic_samples([100, 101, 99, 100], [112, 113, 111, 112])
        summary = regression.summarize(samples, SCHEMA, "quiet_reference")
        self.assertTrue(summary["blocks_publication"])
        self.assertEqual("blocked_regression", summary["status"])

    def test_diagnostic_and_noisy_rows_never_block(self) -> None:
        stable = synthetic_samples([100, 101, 99, 100], [112, 113, 111, 112])
        self.assertEqual("diagnostic_only", regression.summarize(stable, SCHEMA, "diagnostic")["status"])
        noisy = synthetic_samples([100, 130, 70, 100], [150, 90, 130, 110])
        summary = regression.summarize(noisy, SCHEMA, "quiet_reference")
        self.assertFalse(summary["blocks_publication"])
        self.assertEqual("inconclusive_noise", summary["status"])

    def test_complete_exact_parent_artifact_validates(self) -> None:
        samples = synthetic_samples([100, 101], [99, 100])
        metadata = {field: "test" for field in SCHEMA["required_metadata"]}
        metadata.update({
            "parent_revision": "a" * 40,
            "candidate_revision": "b" * 40,
            "candidate_first_parent": "a" * 40,
            "zig_gc_revision": "c" * 40,
            "zig_regex_revision": "d" * 40,
            "workload_source_sha256": "1" * 64,
            "parent_binary_sha256": "2" * 64,
            "candidate_binary_sha256": "3" * 64,
            "host_class": "diagnostic",
            "mode": "single",
            "workload": "representative_json",
            "lanes": 1,
            "jobs": 2200,
            "expected_checksum": 324952086,
        })
        metadata["samples"] = 2
        metadata["timed_boundary"] = "test boundary"
        artifact = {
            "schema_version": SCHEMA["schema_version"],
            "profile_id": SCHEMA["profile_id"],
            "kind": "exact_parent_ab",
            "metadata": metadata,
            "samples": samples,
            "summary": regression.summarize(samples, SCHEMA, "diagnostic"),
        }
        regression.attribution.validate_artifact(artifact, SCHEMA)

    def test_clean_worktree_guard_distinguishes_clean_and_dirty(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = pathlib.Path(directory)
            subprocess.run(
                ["git", "init", "-q", str(repository)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(["git", "-C", str(repository), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(repository), "config", "user.email", "test@example.com"], check=True)
            tracked = repository / "tracked.txt"
            tracked.write_text("clean\n")
            subprocess.run(["git", "-C", str(repository), "add", "tracked.txt"], check=True)
            subprocess.run(["git", "-C", str(repository), "commit", "-qm", "test"], check=True)
            regression.require_clean(repository)
            tracked.write_text("dirty\n")
            with self.assertRaisesRegex(ValueError, "dirty tracked worktree"):
                regression.require_clean(repository)


if __name__ == "__main__":
    unittest.main()
