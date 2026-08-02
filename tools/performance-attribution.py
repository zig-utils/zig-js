#!/usr/bin/env python3
"""Validate attribution-v1 artifacts and losslessly migrate legacy A/B TSVs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import pathlib
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SCHEMA = ROOT / "docs/.data/performance-attribution-schema-v1.json"
ALLOWED_STATES = {"measured", "unavailable", "not_applicable"}
ALLOWED_KINDS = {"duration", "gauge", "counter", "hardware_counter", "environment"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_schema(path: pathlib.Path = DEFAULT_SCHEMA) -> dict[str, Any]:
    schema = json.loads(path.read_text())
    validate_schema(schema)
    return schema


def validate_schema(schema: dict[str, Any]) -> None:
    require(schema.get("schema_version") == 1, "unsupported attribution schema")
    require(schema.get("profile_id") == "zig-js-performance-attribution-v1", "unexpected profile id")
    require(set(schema.get("metric_states", {})) == ALLOWED_STATES, "metric state inventory drift")
    require(schema.get("sample_identity") == [
        "variant", "pair_sample", "order", "engine", "mode",
        "workload", "lanes", "jobs", "checksum",
    ], "sample identity drift")
    required_metadata = schema.get("required_metadata")
    require(isinstance(required_metadata, list) and len(required_metadata) == len(set(required_metadata)), "metadata inventory is invalid")
    policy = schema.get("regression_policy", {})
    require(policy.get("wall_regression_ratio") == 1.1, "regression threshold must remain 10%")
    require(policy.get("maximum_rsd") == 0.05, "stable-row RSD threshold must remain 5%")
    require(policy.get("gate_host_class") == "quiet_reference", "only the quiet reference host may gate")
    metrics = schema.get("metrics")
    require(isinstance(metrics, list) and metrics, "metrics must be non-empty")
    names = [metric.get("name") for metric in metrics]
    require(len(names) == len(set(names)), "metric names must be unique")
    for metric in metrics:
        require(isinstance(metric.get("name"), str) and metric["name"], "metric name is missing")
        require(isinstance(metric.get("unit"), str) and metric["unit"], f"metric unit missing: {metric}")
        require(isinstance(metric.get("scope"), str) and metric["scope"], f"metric scope missing: {metric}")
        require(metric.get("kind") in ALLOWED_KINDS, f"metric kind is invalid: {metric}")
    expected_metrics = (
        "wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns",
        "peak_rss_bytes", "retained_rss_bytes", "allocations", "allocated_bytes",
        "interpreter_entries", "vm_dispatches", "vm_quick_kernel_hits",
        "baseline_compilations", "baseline_entries", "optimizer_compilations",
        "optimizer_publications", "optimizer_osr_entries", "optimizer_deopts",
        "tier_rejections", "tier_up_ns", "compilation_ns", "deoptimization_ns",
        "generated_code_bytes", "retired_code_bytes", "reclaimed_code_bytes",
        "invalidations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
        "gc_minor_cycles", "gc_full_cycles", "gc_pause_total_ns", "gc_pause_p50_ns",
        "gc_pause_p95_ns", "gc_pause_max_ns", "gc_prepare_ns", "gc_trace_ns",
        "gc_sweep_ns", "gc_post_sweep_ns", "allocator_publication_calls",
        "allocator_publication_cells", "allocator_publication_ns",
        "shape_lock_contentions", "property_lock_contentions", "element_lock_contentions",
        "lock_wait_ns", "worker_runs", "worker_run_ns", "worker_wait_ns",
        "thread_join_wait_ns", "cycles", "instructions", "cache_misses",
        "energy_joules", "thermal_state", "symbolized_native_samples",
        "anonymous_native_samples",
    )
    missing = sorted(set(expected_metrics) - set(names))
    extra = sorted(set(names) - set(expected_metrics))
    require(not missing and not extra, f"v1 metric inventory drift; missing={missing}, extra={extra}")


def observation(status: str, value: int | float | str | None, source: str, reason: str = "") -> dict[str, Any]:
    require(status in ALLOWED_STATES, f"invalid metric state: {status}")
    if status == "measured":
        require(value is not None, "measured observation requires a value")
        require(bool(source), "measured observation requires a source")
        require(not reason, "measured observation cannot carry an unavailable reason")
    else:
        require(value is None, f"{status} observation must have a null value")
        require(bool(reason), f"{status} observation requires a reason")
    return {"status": status, "value": value, "source": source, "reason": reason}


def unavailable_metrics(schema: dict[str, Any], reason: str) -> dict[str, dict[str, Any]]:
    return {
        metric["name"]: observation("unavailable", None, "", reason)
        for metric in schema["metrics"]
    }


def validate_metrics(metrics: dict[str, Any], schema: dict[str, Any]) -> None:
    definitions = {metric["name"]: metric for metric in schema["metrics"]}
    require(set(metrics) == set(definitions), "sample metric inventory does not exactly match schema")
    for name, metric in metrics.items():
        require(isinstance(metric, dict), f"metric observation must be an object: {name}")
        status = metric.get("status")
        require(status in ALLOWED_STATES, f"invalid state for {name}")
        value = metric.get("value")
        reason = metric.get("reason")
        source = metric.get("source")
        require(isinstance(reason, str) and isinstance(source, str), f"invalid provenance for {name}")
        if status == "measured":
            require(value is not None and source, f"measured {name} lacks value/source")
            if definitions[name]["unit"] != "categorical":
                require(isinstance(value, (int, float)) and not isinstance(value, bool), f"measured {name} must be numeric")
                require(value >= 0, f"measured {name} must be non-negative")
            require(reason == "", f"measured {name} has a reason")
        else:
            require(value is None and reason, f"{status} {name} must be null with a reason")


def validate_artifact(artifact: dict[str, Any], schema: dict[str, Any]) -> None:
    require(artifact.get("schema_version") == schema["schema_version"], "artifact schema version mismatch")
    require(artifact.get("profile_id") == schema["profile_id"], "artifact profile id mismatch")
    require(artifact.get("kind") in {"exact_parent_ab", "legacy_migration"}, "artifact kind is invalid")
    metadata = artifact.get("metadata")
    require(isinstance(metadata, dict), "artifact metadata is missing")
    for field in schema["required_metadata"]:
        require(field in metadata, f"artifact metadata missing {field}")
    samples = artifact.get("samples")
    require(isinstance(samples, list) and samples, "artifact samples are missing")
    identities: set[tuple[Any, ...]] = set()
    for sample in samples:
        require(isinstance(sample, dict), "sample must be an object")
        identity = sample.get("identity")
        require(isinstance(identity, dict), "sample identity is missing")
        require(set(identity) == set(schema["sample_identity"]), "sample identity fields drifted")
        key = tuple(identity[field] for field in schema["sample_identity"])
        require(key not in identities, f"duplicate sample identity: {key}")
        identities.add(key)
        require(identity["variant"] in {"parent", "candidate"}, "sample variant is invalid")
        require(identity["order"] in {0, 1}, "sample order is invalid")
        require(isinstance(identity["pair_sample"], int) and identity["pair_sample"] >= 0, "pair sample is invalid")
        require(isinstance(identity["lanes"], int) and identity["lanes"] > 0, "lane count is invalid")
        require(isinstance(identity["jobs"], int) and identity["jobs"] > 0, "job count is invalid")
        require(isinstance(identity["checksum"], int) and identity["checksum"] >= 0, "checksum is invalid")
        validate_metrics(sample.get("metrics", {}), schema)
    if artifact["kind"] == "exact_parent_ab":
        for field in ("parent_revision", "candidate_revision", "candidate_first_parent", "zig_gc_revision", "zig_regex_revision"):
            require(isinstance(metadata[field], str) and len(metadata[field]) == 40 and all(char in "0123456789abcdef" for char in metadata[field]), f"exact-parent metadata has invalid {field}")
        require(metadata["candidate_first_parent"] == metadata["parent_revision"], "candidate first parent does not match parent revision")
        for field in ("workload_source_sha256", "parent_binary_sha256", "candidate_binary_sha256"):
            require(isinstance(metadata[field], str) and len(metadata[field]) == 64 and all(char in "0123456789abcdef" for char in metadata[field]), f"exact-parent metadata has invalid {field}")
        require(metadata["host_class"] in {"diagnostic", "quiet_reference"}, "exact-parent host class is invalid")
        require(isinstance(metadata["samples"], int) and metadata["samples"] >= 2, "exact-parent sample count is invalid")
        expected = {
            (variant, pair_sample)
            for variant in ("parent", "candidate")
            for pair_sample in range(metadata["samples"])
        }
        actual = {(sample["identity"]["variant"], sample["identity"]["pair_sample"]) for sample in samples}
        require(actual == expected and len(samples) == len(expected), "exact-parent pair inventory drift")
        for pair_sample in range(metadata["samples"]):
            pair = [sample["identity"] for sample in samples if sample["identity"]["pair_sample"] == pair_sample]
            require(sorted(item["order"] for item in pair) == [0, 1], f"pair {pair_sample} order drift")
            require(len({item["checksum"] for item in pair}) == 1, f"pair {pair_sample} checksum drift")
            first = next(item for item in pair if item["order"] == 0)
            expected_first = "parent" if pair_sample % 2 == 0 else "candidate"
            require(first["variant"] == expected_first, f"pair {pair_sample} did not alternate process order")
        identities = [sample["identity"] for sample in samples]
        for field in ("engine", "mode", "workload", "lanes", "jobs", "checksum"):
            require(len({identity[field] for identity in identities}) == 1, f"exact-parent {field} drift")
        for field in ("mode", "workload", "lanes", "jobs"):
            require(metadata.get(field) == identities[0][field], f"exact-parent metadata/sample {field} mismatch")
        require(metadata.get("expected_checksum") == identities[0]["checksum"], "exact-parent frozen checksum mismatch")


def integer_row(row: dict[str, str]) -> dict[str, int | str]:
    result: dict[str, int | str] = {}
    for name, value in row.items():
        try:
            result[name] = int(value)
        except ValueError:
            result[name] = value
    return result


def measured(metrics: dict[str, dict[str, Any]], name: str, value: int | float, source: str) -> None:
    metrics[name] = observation("measured", value, source)


def migrate_legacy_tsv(path: pathlib.Path, schema: dict[str, Any]) -> dict[str, Any]:
    with path.open(newline="") as stream:
        rows = [integer_row(row) for row in csv.DictReader(stream, delimiter="\t")]
    require(rows, f"legacy artifact has no rows: {path}")
    fields = set(rows[0])
    independent = fields == {"variant", "mode", "lanes", "sample", "order", "elapsed_ns", "checksum", "max_rss_bytes"}
    shared = {"variant", "pair_sample", "order", "workload", "lanes", "jobs", "elapsed_ns", "checksum", "kind"}.issubset(fields)
    require(independent or shared, f"unsupported legacy A/B schema: {sorted(fields)}")
    reason = "metric was not present in the losslessly retained legacy TSV row"
    samples: list[dict[str, Any]] = []
    for row in rows:
        metrics = unavailable_metrics(schema, reason)
        measured(metrics, "wall_time_ns", int(row["elapsed_ns"]), "legacy_fields.elapsed_ns")
        if "max_rss_bytes" in row:
            measured(metrics, "peak_rss_bytes", int(row["max_rss_bytes"]), "legacy_fields.max_rss_bytes")
        if shared:
            mapping = {
                "gc_minor_cycles": "minor_cycles",
                "gc_full_cycles": "full_cycles",
                "gc_pause_total_ns": "pause_ns_total",
                "gc_pause_max_ns": "pause_ns_max",
                "allocator_publication_calls": "object_batch_calls",
                "allocator_publication_cells": "object_batch_cells",
                "allocator_publication_ns": "object_batch_ns_total",
                "worker_runs": "worker_runs",
                "worker_run_ns": "worker_run_ns",
                "thread_join_wait_ns": "join_wait_ns",
            }
            for target, source in mapping.items():
                if source in row:
                    measured(metrics, target, int(row[source]), f"legacy_fields.{source}")
            for target, sources in {
                "gc_prepare_ns": ("minor_prepare_ns", "full_prepare_ns"),
                "gc_trace_ns": ("minor_trace_ns", "full_trace_ns"),
                "gc_sweep_ns": ("minor_sweep_ns", "full_sweep_ns"),
                "gc_post_sweep_ns": ("minor_post_sweep_ns", "full_post_sweep_ns"),
            }.items():
                if all(source in row for source in sources):
                    measured(metrics, target, sum(int(row[source]) for source in sources), "+".join(f"legacy_fields.{source}" for source in sources))
        pair_sample = int(row.get("pair_sample", row.get("sample", 0)))
        mode = str(row.get("mode", "shared"))
        samples.append({
            "identity": {
                "variant": str(row["variant"]),
                "pair_sample": pair_sample,
                "order": int(row["order"]),
                "engine": "zig-js",
                "mode": mode,
                "workload": str(row.get("workload", "object_churn")),
                "lanes": int(row["lanes"]),
                "jobs": int(row.get("jobs", 100)),
                "checksum": int(row["checksum"]),
            },
            "metrics": metrics,
            "legacy_fields": row,
        })
    unavailable = "unavailable: legacy TSV does not encode this metadata; consult its paired Markdown report"
    artifact = {
        "schema_version": schema["schema_version"],
        "profile_id": schema["profile_id"],
        "kind": "legacy_migration",
        "metadata": {field: unavailable for field in schema["required_metadata"]},
        "legacy": {
            "source_path": path.name,
            "source_sha256": sha256(path),
            "source_columns": list(rows[0]),
            "rows": len(rows),
        },
        "samples": samples,
    }
    artifact["metadata"]["samples"] = len({sample["identity"]["pair_sample"] for sample in samples})
    artifact["metadata"]["timed_boundary"] = "preserved in legacy_fields; consult paired Markdown report"
    validate_artifact(artifact, schema)
    return artifact


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", type=pathlib.Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--artifact", type=pathlib.Path)
    parser.add_argument("--migrate-legacy", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    schema = load_schema(args.schema)
    if args.artifact and args.migrate_legacy:
        parser.error("choose --artifact or --migrate-legacy")
    if args.artifact:
        validate_artifact(json.loads(args.artifact.read_text()), schema)
        print(f"OK {args.artifact}: {schema['profile_id']}")
        return 0
    if args.migrate_legacy:
        if args.output is None:
            parser.error("--migrate-legacy requires --output")
        artifact = migrate_legacy_tsv(args.migrate_legacy, schema)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
        print(f"OK migrated {len(artifact['samples'])} rows from {args.migrate_legacy}")
        return 0
    validate_schema(schema)
    print(f"OK {schema['profile_id']}: {len(schema['metrics'])} metrics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
