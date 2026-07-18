#!/usr/bin/env python3
"""Validate the versioned WebAssembly feature/profile registry."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
SHA = re.compile(r"[0-9a-f]{40}")
ALLOWED_PROFILE_STATUS = {"implemented", "planned"}
ALLOWED_STANDARDIZATION = {"finished", "phase_4"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"wasm-feature-profiles: {message}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "registry",
        nargs="?",
        type=Path,
        default=ROOT / "docs/.data/wasm-feature-profiles.json",
    )
    parser.add_argument(
        "--feature-source",
        type=Path,
        default=ROOT / "src/wasm/types.zig",
    )
    args = parser.parse_args()
    document = json.loads(args.registry.read_text())

    require(document.get("schema_version") == 1, "unsupported schema version")
    tracker = document.get("tracker", {})
    require(SHA.fullmatch(tracker.get("commit", "")) is not None, "invalid tracker commit")

    features = document.get("features", [])
    feature_ids = [entry.get("id") for entry in features]
    require(len(feature_ids) == len(set(feature_ids)), "duplicate feature id")
    known = set(feature_ids)
    source = args.feature_source.read_text()
    enum_body = source.split("pub const Feature = enum {", 1)[1].split("pub fn name", 1)[0]
    runtime_features = set(re.findall(r"^    ([a-z][a-z0-9_]*),$", enum_body, re.MULTILINE))
    require(runtime_features == known, f"registry/runtime feature drift: registry-only={sorted(known - runtime_features)}, runtime-only={sorted(runtime_features - known)}")
    gate_source = (ROOT / "src/wasm/decode.zig").read_text() + (ROOT / "src/wasm/validate.zig").read_text()
    ungated = sorted(feature_id for feature_id in known if re.search(rf"\.{re.escape(feature_id)}\b", gate_source) is None)
    require(not ungated, f"registry features without decoder/validator gates: {ungated}")
    for feature in features:
        feature_id = feature.get("id")
        require(isinstance(feature_id, str) and feature_id, "feature id is required")
        commit = feature.get("commit", "")
        require(SHA.fullmatch(commit) is not None and set(commit) != {"0"}, f"{feature_id}: invalid commit")
        require(feature.get("standardization") in ALLOWED_STANDARDIZATION, f"{feature_id}: invalid standardization")
        require(isinstance(feature.get("issue"), int), f"{feature_id}: issue is required")
        dependencies = feature.get("dependencies")
        require(isinstance(dependencies, list), f"{feature_id}: dependencies must be a list")
        require(feature_id not in dependencies, f"{feature_id}: self dependency")
        unknown = set(dependencies) - known
        require(not unknown, f"{feature_id}: unknown dependencies {sorted(unknown)}")

    profiles = document.get("profiles", [])
    profile_ids = [profile.get("id") for profile in profiles]
    require(len(profile_ids) == len(set(profile_ids)), "duplicate profile id")
    defaults = [profile for profile in profiles if profile.get("default")]
    require(len(defaults) == 1 and defaults[0].get("id") == "mvp", "MVP must be the only default profile")
    for profile in profiles:
        profile_id = profile.get("id")
        require(profile.get("status") in ALLOWED_PROFILE_STATUS, f"{profile_id}: invalid status")
        selected = profile.get("features")
        require(isinstance(selected, list), f"{profile_id}: features must be a list")
        require(not (set(selected) - known), f"{profile_id}: unknown feature")
        closure = set(selected)
        changed = True
        while changed:
            changed = False
            for feature in features:
                if feature["id"] in closure:
                    for dependency in feature["dependencies"]:
                        if dependency not in closure:
                            closure.add(dependency)
                            changed = True
        require(closure == set(selected), f"{profile_id}: missing dependency closure {sorted(closure - set(selected))}")
        if profile.get("status") == "implemented":
            require(profile_id == "mvp", f"{profile_id}: implementation status is ahead of runtime")

    print(f"WebAssembly feature registry: {len(profiles)} profiles, {len(features)} pinned features")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
