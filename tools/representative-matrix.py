#!/usr/bin/env python3
"""Validate the frozen representative performance-matrix contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib


ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "docs/.data/representative-benchmark-matrix-v1.json"
SOURCE = ROOT / "bench/representative_comparison.js"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(manifest: dict, root: pathlib.Path = ROOT) -> None:
    require(manifest.get("schema_version") == 1, "unsupported representative matrix schema")
    require(manifest.get("status") == "frozen", "representative matrix must be frozen")
    lanes = manifest.get("lanes")
    require(lanes == [1, 2, 4, 8], "v1 lanes must be exactly 1/2/4/8")

    compatibility = manifest.get("compatibility_panel", {})
    for field in ("source", "source_sha256", "driver", "driver_sha256"):
        require(isinstance(compatibility.get(field), str), f"compatibility panel missing {field}")
    for path_field, hash_field in (("source", "source_sha256"), ("driver", "driver_sha256")):
        path = root / compatibility[path_field]
        require(path.is_file(), f"compatibility panel path does not exist: {path}")
        require(digest(path) == compatibility[hash_field], f"compatibility panel changed without a matrix version bump: {path}")

    required = manifest.get("required_families")
    require(isinstance(required, list) and required, "required_families must be non-empty")
    require(len(required) == len(set(required)), "required_families contains duplicates")
    implemented = manifest.get("implemented_families")
    deferred = manifest.get("deferred_families")
    require(isinstance(implemented, list) and implemented, "implemented_families must be non-empty")
    require(isinstance(deferred, list), "deferred_families must be a list")
    implemented_names = [entry.get("family") for entry in implemented]
    deferred_names = [entry.get("family") for entry in deferred]
    require(len(implemented_names) == len(set(implemented_names)), "implemented family is duplicated")
    require(len(deferred_names) == len(set(deferred_names)), "deferred family is duplicated")
    require(set(implemented_names).isdisjoint(deferred_names), "family cannot be implemented and deferred")
    require(set(implemented_names) | set(deferred_names) == set(required), "implemented/deferred inventory must exactly cover required_families")
    for entry in deferred:
        require(isinstance(entry.get("reason"), str) and entry["reason"], f"deferred family lacks a reason: {entry}")

    source = SOURCE.read_text()
    workload_ids: set[str] = set()
    for entry in implemented:
        jobs = entry.get("jobs", {})
        require(isinstance(jobs.get("full"), int) and jobs["full"] > 0, f"invalid full jobs: {entry}")
        require(isinstance(jobs.get("quick"), int) and 0 < jobs["quick"] < jobs["full"], f"invalid quick jobs: {entry}")
        for role in ("base", "variant"):
            workload = entry.get(role)
            require(isinstance(workload, str) and workload.startswith("representative_"), f"invalid {role} workload: {entry}")
            require(workload not in workload_ids, f"duplicate workload id: {workload}")
            workload_ids.add(workload)
            require(f'"{workload}"' in source, f"workload is absent from representative source dispatch: {workload}")
            checksums = entry.get("checksums", {}).get(role, {})
            for scale in ("full", "quick"):
                values = checksums.get(scale)
                require(isinstance(values, list) and len(values) == len(lanes), f"{workload} {scale} checksums must match lanes")
                require(all(isinstance(value, int) and 0 <= value < 2**53 for value in values), f"{workload} {scale} checksum is not an exact non-negative integer")
        require(entry["base"] != entry["variant"], f"base and variant must differ: {entry['family']}")

    protocol = manifest.get("protocol", {})
    require(protocol.get("minimum_full_median_ns") == 50_000_000, "v1 must retain the 50 ms timing floor")
    require(protocol.get("full_samples") == 7, "v1 must retain seven full samples")
    modes = manifest.get("modes", {})
    require(set(modes) == {"single_warm", "independent_steady", "independent_cold", "shared"}, "v1 mode inventory changed")
    require(modes["shared"].get("engines") == ["zig-js"], "shared mode must not construct a JSC ratio")
    require(isinstance(manifest.get("pending_metric_panels"), list), "pending metric inventory must remain explicit")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    validate(manifest)
    print(
        f"OK {manifest['matrix_id']}: "
        f"{len(manifest['implemented_families'])} implemented families, "
        f"{len(manifest['deferred_families'])} explicit deferred families"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
