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


def verify_terminal_inventory(
    path: Path,
    *,
    kind: str,
    profile: str,
    repository: str,
    commit: str,
    features: list[str],
    files: list[tuple[str, int, int]],
    pass_modes: tuple[str, ...] = ("javascript_api",),
    converter_kind: str | None = None,
    converter_version: str = "1.0.39",
    converter_commit: str = "ad75c5edcdff96d73c245b57fbc07607aaca9f95",
    not_applicable_types: tuple[str, ...] = ("assert_malformed",),
) -> None:
    document = json.loads(path.read_text())
    require(document.get("schema_version") == 2, f"{profile}: unsupported terminal inventory schema")
    require(document.get("kind") == kind, f"{profile}: terminal inventory kind drift")
    require(document.get("profile") == profile, f"{profile}: terminal inventory profile drift")
    require(document.get("features") == features, f"{profile}: terminal inventory feature drift")
    require(SHA.fullmatch(document.get("engine_commit", "")) is not None, f"{profile}: invalid engine commit")
    spec = document.get("spec", {})
    declared = [name for name, _, _ in files]
    require(spec.get("repository") == repository, f"{profile}: repository drift")
    require(spec.get("commit") == commit, f"{profile}: proposal pin drift")
    require(spec.get("declared_files") == declared, f"{profile}: declared file drift")
    require(spec.get("files_declared") == len(files), f"{profile}: declared file count drift")
    require(spec.get("files_scored") == len(files), f"{profile}: hidden file filtering")
    converter = document.get("converter", {})
    if converter_kind is not None:
        require(converter.get("kind") == converter_kind, f"{profile}: converter kind drift")
    require(converter.get("version") == converter_version, f"{profile}: converter version drift")
    require(converter.get("commit") == converter_commit, f"{profile}: converter pin drift")
    entries = document.get("files", [])
    require([Path(entry.get("path", "")).name for entry in entries] == declared, f"{profile}: scored file drift")
    expected_pass = sum(passed for _, passed, _ in files)
    expected_na = sum(not_applicable for _, _, not_applicable in files)
    totals = document.get("totals", {})
    require(
        totals == {
            "fail": 0,
            "not_applicable": expected_na,
            "pass": expected_pass,
            "runner_error": 0,
            "total": expected_pass + expected_na,
        },
        f"{profile}: terminal totals are not green",
    )
    for entry, (_, passed, not_applicable) in zip(entries, files):
        commands = entry.get("commands", [])
        require(len(commands) == passed + not_applicable, f"{profile}: per-file command count drift")
        require(entry.get("counts") == {
            "fail": 0,
            "not_applicable": not_applicable,
            "pass": passed,
            "runner_error": 0,
            "total": passed + not_applicable,
        }, f"{profile}: per-file totals are not green")
        require(
            all(command.get("status") in {"pass", "not_applicable"} for command in commands),
            f"{profile}: hidden failed command",
        )
        require(
            all(
                command.get("mode") == "not_applicable"
                if command.get("status") == "not_applicable"
                else command.get("mode") in pass_modes
                for command in commands
            ),
            f"{profile}: command execution mode drift",
        )
        require(
            all(
                command.get("type") in not_applicable_types
                and command.get("detail") == "text-format syntax is not exposed by the JavaScript binary API"
                for command in commands
                if command.get("status") == "not_applicable"
            ),
            f"{profile}: unexplained non-applicable command",
        )


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
    parser.add_argument(
        "--simd-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-simd-opcodes.json",
    )
    parser.add_argument(
        "--simd-source",
        type=Path,
        default=ROOT / "src/wasm/simd.zig",
    )
    parser.add_argument(
        "--relaxed-simd-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-relaxed-simd-opcodes.json",
    )
    parser.add_argument(
        "--atomic-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-atomic-opcodes.json",
    )
    parser.add_argument(
        "--atomic-source",
        type=Path,
        default=ROOT / "src/wasm/atomic.zig",
    )
    parser.add_argument(
        "--tail-call-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-tail-call-opcodes.json",
    )
    parser.add_argument(
        "--exception-handling-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-exception-handling-opcodes.json",
    )
    parser.add_argument(
        "--exception-runtime-source",
        type=Path,
        default=ROOT / "src/wasm/exec.zig",
    )
    parser.add_argument(
        "--tail-call-terminal-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-tail-call-inventory.json",
    )
    parser.add_argument(
        "--exception-handling-terminal-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-exception-handling-inventory.json",
    )
    parser.add_argument(
        "--multi-memory-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-multi-memory-binary-inventory.json",
    )
    parser.add_argument(
        "--multi-memory-terminal-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-multi-memory-runtime-inventory.json",
    )
    parser.add_argument(
        "--memory64-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-memory64-binary-inventory.json",
    )
    parser.add_argument(
        "--memory64-terminal-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-memory64-runtime-inventory.json",
    )
    parser.add_argument(
        "--gc-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-gc-binary-inventory.json",
    )
    parser.add_argument(
        "--gc-source",
        type=Path,
        default=ROOT / "src/wasm/gc.zig",
    )
    parser.add_argument(
        "--simd-movement-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-simd-movement-inventory.json",
    )
    parser.add_argument(
        "--simd-complete-inventory",
        type=Path,
        default=ROOT / "docs/.data/wasm-simd-inventory.json",
    )
    parser.add_argument(
        "--ci-workflow",
        type=Path,
        default=ROOT / ".github/workflows/ci.yml",
    )
    args = parser.parse_args()
    document = json.loads(args.registry.read_text())

    ci_source = args.ci_workflow.read_text()
    required_ci_tokens = (
        "wasm-post-mvp-smoke",
        "wasm-core-3-memory64-gc-smoke",
        "a6003d06aefef41e20a3e36fe2e500062555c895",
        "af287a73d8f3bf7ea216c10592f9e350b947c4f2",
        "cf8b5aa27257311b8eac80ae83f4ba22ee308064",
        "9003cd5e24e53b84cd9027ea3dd7ae57159a6db1",
        "756060f5816c7e2159f4817fbdee76cf52f9c923",
        "9d36019973201a19f9c9ebb0f10828b2fe2374aa",
        "4e2898f7ca3bd0536218ed9b7b36ff7b86954c57ae0e6272fde69728cbe01088",
        "--profile tail-calls",
        "--profile exception-handling",
        "--profile multi-memory",
        "--profile memory64",
        "--profile gc",
        "test/core/relaxed-simd/",
    )
    require(
        all(token in ci_source for token in required_ci_tokens),
        "post-MVP CI smoke/pin coverage drift",
    )

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
    decode_source = (ROOT / "src/wasm/decode.zig").read_text()
    validate_source = (ROOT / "src/wasm/validate.zig").read_text()
    gate_source = decode_source + validate_source
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

    simd_feature = next(feature for feature in features if feature["id"] == "fixed_width_simd")
    simd_inventory = json.loads(args.simd_inventory.read_text())
    require(simd_inventory.get("schema_version") == 1, "SIMD inventory: unsupported schema version")
    require(simd_inventory.get("kind") == "webassembly_fixed_width_simd_opcode_inventory", "SIMD inventory: invalid kind")
    require(simd_inventory.get("prefix") == "0xfd", "SIMD inventory: invalid opcode prefix")
    require(simd_inventory.get("source", {}).get("commit") == simd_feature["commit"], "SIMD inventory/registry commit drift")
    require(simd_inventory.get("source", {}).get("corpus_files") == 56, "SIMD inventory: expected 56 corpus files")
    simd_opcodes = simd_inventory.get("opcodes", [])
    require(simd_inventory.get("opcode_count") == len(simd_opcodes) == 236, "SIMD inventory: expected 236 opcodes")
    subopcodes = [entry.get("subopcode") for entry in simd_opcodes]
    names = [entry.get("name") for entry in simd_opcodes]
    require(len(subopcodes) == len(set(subopcodes)), "SIMD inventory: duplicate subopcode")
    require(len(names) == len(set(names)), "SIMD inventory: duplicate instruction name")
    require(all(isinstance(value, int) and 0 <= value <= 255 for value in subopcodes), "SIMD inventory: invalid subopcode")
    require(all(entry.get("immediate") in {"none", "memarg", "v128", "lane16", "lane", "memarg_lane"} for entry in simd_opcodes), "SIMD inventory: invalid immediate kind")
    simd_source = args.simd_source.read_text()
    enum_body = simd_source.split("pub const Op = enum(u16) {", 1)[1].split("pub fn fromSubopcode", 1)[0]
    runtime_simd = {
        (name, int(value, 16))
        for name, value in re.findall(r"^    ([a-z][a-z0-9_]*?) = 0x([0-9A-F]{2}),$", enum_body, re.MULTILINE)
    }
    inventoried_simd = {(name.replace(".", "_"), subopcode) for name, subopcode in zip(names, subopcodes)}
    require(runtime_simd == inventoried_simd, "SIMD inventory/runtime opcode drift")

    relaxed_feature = next(feature for feature in features if feature["id"] == "relaxed_simd")
    relaxed_inventory = json.loads(args.relaxed_simd_inventory.read_text())
    require(relaxed_inventory.get("schema_version") == 1, "relaxed SIMD inventory: unsupported schema version")
    require(relaxed_inventory.get("kind") == "webassembly_relaxed_simd_opcode_inventory", "relaxed SIMD inventory: invalid kind")
    require(relaxed_inventory.get("prefix") == "0xfd", "relaxed SIMD inventory: invalid opcode prefix")
    require(relaxed_inventory.get("source", {}).get("repository") == relaxed_feature["repository"], "relaxed SIMD inventory/registry repository drift")
    require(relaxed_inventory.get("source", {}).get("commit") == relaxed_feature["commit"], "relaxed SIMD inventory/registry commit drift")
    require(relaxed_inventory.get("source", {}).get("tag") == "wg-3.0", "relaxed SIMD inventory: expected wg-3.0 tag")
    require(relaxed_inventory.get("source", {}).get("corpus_files") == 7, "relaxed SIMD inventory: expected 7 corpus files")
    relaxed_opcodes = relaxed_inventory.get("opcodes", [])
    require(relaxed_inventory.get("opcode_count") == len(relaxed_opcodes) == 20, "relaxed SIMD inventory: expected 20 opcodes")
    relaxed_subopcodes = [entry.get("subopcode") for entry in relaxed_opcodes]
    relaxed_names = [entry.get("name") for entry in relaxed_opcodes]
    require(relaxed_subopcodes == list(range(0x100, 0x114)), "relaxed SIMD inventory: unexpected subopcode range")
    require(len(relaxed_names) == len(set(relaxed_names)), "relaxed SIMD inventory: duplicate instruction name")
    require(all(entry.get("immediate") == "none" for entry in relaxed_opcodes), "relaxed SIMD inventory: unexpected immediate")
    runtime_relaxed_simd = {
        (name, int(value, 16))
        for name, value in re.findall(r"^    ([a-z][a-z0-9_]*?) = 0x([0-9A-F]{3}),$", enum_body, re.MULTILINE)
    }
    inventoried_relaxed_simd = {
        (name.replace(".", "_"), subopcode)
        for name, subopcode in zip(relaxed_names, relaxed_subopcodes)
    }
    require(runtime_relaxed_simd == inventoried_relaxed_simd, "relaxed SIMD inventory/runtime opcode drift")

    threads_feature = next(feature for feature in features if feature["id"] == "threads")
    atomic_inventory = json.loads(args.atomic_inventory.read_text())
    require(atomic_inventory.get("schema_version") == 1, "atomic inventory: unsupported schema version")
    require(atomic_inventory.get("kind") == "webassembly_threads_atomic_opcode_inventory", "atomic inventory: invalid kind")
    require(atomic_inventory.get("prefix") == "0xfe", "atomic inventory: invalid opcode prefix")
    require(atomic_inventory.get("source", {}).get("repository") == threads_feature["repository"], "atomic inventory/registry repository drift")
    require(atomic_inventory.get("source", {}).get("commit") == threads_feature["commit"], "atomic inventory/registry commit drift")
    require(atomic_inventory.get("source", {}).get("corpus_files") == 13, "atomic inventory: expected 13 corpus files")
    atomic_opcodes = atomic_inventory.get("opcodes", [])
    require(atomic_inventory.get("opcode_count") == len(atomic_opcodes) == 67, "atomic inventory: expected 67 opcodes")
    atomic_subopcodes = [entry.get("subopcode") for entry in atomic_opcodes]
    atomic_names = [entry.get("name") for entry in atomic_opcodes]
    require(len(atomic_subopcodes) == len(set(atomic_subopcodes)), "atomic inventory: duplicate subopcode")
    require(len(atomic_names) == len(set(atomic_names)), "atomic inventory: duplicate instruction name")
    require(all(isinstance(value, int) and 0 <= value <= 0x4E for value in atomic_subopcodes), "atomic inventory: invalid subopcode")
    require(set(range(0x04, 0x10)).isdisjoint(atomic_subopcodes), "atomic inventory: reserved subopcode used")
    require(atomic_inventory.get("reserved_subopcode_ranges") == [[0x04, 0x0F]], "atomic inventory: reserved range drift")
    require(all(entry.get("immediate") in {"memarg", "fence"} for entry in atomic_opcodes), "atomic inventory: invalid immediate kind")
    require(all(entry.get("natural_alignment") in {None, 0, 1, 2, 3} for entry in atomic_opcodes), "atomic inventory: invalid natural alignment")
    require(all(entry.get("shape") in {"notify", "wait32", "wait64", "fence", "load_i32", "load_i64", "store_i32", "store_i64", "rmw_i32", "rmw_i64", "cmpxchg_i32", "cmpxchg_i64"} for entry in atomic_opcodes), "atomic inventory: invalid stack shape")
    atomic_source = args.atomic_source.read_text()
    atomic_enum = atomic_source.split("pub const Op = enum(u8) {", 1)[1].split("pub fn fromSubopcode", 1)[0]
    runtime_atomic = {
        (name, int(value, 16))
        for name, value in re.findall(r"^    ([a-z][a-z0-9_]*?) = 0x([0-9A-F]{2}),$", atomic_enum, re.MULTILINE)
    }
    inventoried_atomic = {(name.replace(".", "_"), subopcode) for name, subopcode in zip(atomic_names, atomic_subopcodes)}
    require(runtime_atomic == inventoried_atomic, "atomic inventory/runtime opcode drift")

    tail_feature = next(feature for feature in features if feature["id"] == "tail_calls")
    tail_inventory = json.loads(args.tail_call_inventory.read_text())
    require(tail_inventory.get("schema_version") == 1, "tail-call inventory: unsupported schema version")
    require(tail_inventory.get("kind") == "webassembly_tail_call_opcode_inventory", "tail-call inventory: invalid kind")
    tail_source = tail_inventory.get("source", {})
    require(tail_source.get("repository") == tail_feature["repository"], "tail-call inventory/registry repository drift")
    require(tail_source.get("commit") == tail_feature["commit"], "tail-call inventory/registry commit drift")
    require(tail_source.get("corpus_files") == 2, "tail-call inventory: expected 2 corpus files")
    tail_opcodes = tail_inventory.get("opcodes", [])
    require(tail_inventory.get("opcode_count") == len(tail_opcodes) == 2, "tail-call inventory: expected 2 opcodes")
    require(
        [(entry.get("name"), entry.get("opcode")) for entry in tail_opcodes]
        == [("return_call", 0x12), ("return_call_indirect", 0x13)],
        "tail-call inventory: opcode map drift",
    )
    require(
        [entry.get("immediate") for entry in tail_opcodes]
        == ["function_index", "type_index_table_index"],
        "tail-call inventory: immediate-kind drift",
    )
    require(
        [entry.get("binary_fields") for entry in tail_opcodes]
        == [["function_index:u32"], ["type_index:u32", "table_index:u32"]],
        "tail-call inventory: binary-field order drift",
    )
    require(
        [entry.get("stack") for entry in tail_opcodes]
        == ["[t3* t1*] -> [t4*]", "[t3* t1* i32] -> [t4*]"],
        "tail-call inventory: stack signature drift",
    )
    require(all(entry.get("stack_polymorphic") is True for entry in tail_opcodes), "tail-call inventory: stack-polymorphism drift")
    expected_tail_rules = [
        [
            "current_function_return_type_present",
            "function_index_defined",
            "callee_results_equal_current_function_results",
            "pop_callee_parameters",
        ],
        [
            "current_function_return_type_present",
            "table_index_defined",
            "table_element_type_funcref",
            "type_index_defined",
            "callee_results_equal_current_function_results",
            "pop_i32_table_element_index",
            "pop_callee_parameters",
        ],
    ]
    require([entry.get("validation_rules") for entry in tail_opcodes] == expected_tail_rules, "tail-call inventory: validation-rule drift")
    op_enum = source.split("pub const Op = enum(u16) {", 1)[1].split("pub fn fromByte", 1)[0]
    runtime_direct = {
        (name, int(value, 16))
        for name, value in re.findall(r"^    ([a-z][a-z0-9_]*?) = 0x([0-9A-F]{2}),$", op_enum, re.MULTILINE)
        if name in {"return_call", "return_call_indirect"}
    }
    require(runtime_direct == {(entry["name"], entry["opcode"]) for entry in tail_opcodes}, "tail-call inventory/runtime opcode drift")
    tail_corpus = tail_inventory.get("corpus", {})
    corpus_files = tail_corpus.get("files", [])
    require(tail_corpus.get("top_level_commands") == 119, "tail-call inventory: expected 119 corpus commands")
    require(
        [(entry.get("path"), entry.get("top_level_commands"), entry.get("source_token_occurrences")) for entry in corpus_files]
        == [
            ("test/core/return_call.wast", 44, 28),
            ("test/core/return_call_indirect.wast", 75, 56),
        ],
        "tail-call inventory: corpus file/count drift",
    )
    require(
        sum(sum(entry.get("commands", {}).values()) for entry in corpus_files) == 119,
        "tail-call inventory: command breakdown drift",
    )

    exception_feature = next(feature for feature in features if feature["id"] == "exception_handling")
    exception_runtime_source = args.exception_runtime_source.read_text()
    exception_api_source = (ROOT / "src/wasm/api.zig").read_text()
    exception_diff_source = (ROOT / "tests/wasm_exception_jsc_diff.c").read_text()
    build_source = (ROOT / "build.zig").read_text()
    exception_inventory = json.loads(args.exception_handling_inventory.read_text())
    require(exception_inventory.get("schema_version") == 1, "exception inventory: unsupported schema version")
    require(exception_inventory.get("kind") == "webassembly_exception_handling_binary_inventory", "exception inventory: invalid kind")
    exception_source = exception_inventory.get("source", {})
    require(exception_source.get("repository") == exception_feature["repository"], "exception inventory/registry repository drift")
    require(exception_source.get("commit") == exception_feature["commit"], "exception inventory/registry commit drift")
    require(exception_source.get("corpus_files") == 4, "exception inventory: expected 4 corpus files")
    require(exception_inventory.get("value_types") == [{"name": "exnref", "byte": 0x69, "reference": True}], "exception inventory: exnref drift")
    require(
        [(entry.get("name"), entry.get("id"), entry.get("order_after"), entry.get("order_before")) for entry in exception_inventory.get("sections", [])]
        == [("tag", 13, "memory", "global")],
        "exception inventory: tag section drift",
    )
    require(
        [(entry.get("name"), entry.get("byte")) for entry in exception_inventory.get("external_kinds", [])]
        == [("tag", 4)],
        "exception inventory: external kind drift",
    )
    require(
        [(entry.get("name"), entry.get("opcode"), entry.get("immediate")) for entry in exception_inventory.get("opcodes", [])]
        == [("throw", 0x08, "tag_index"), ("throw_ref", 0x0A, "none"), ("try_table", 0x1F, "block_type_catch_vector")],
        "exception inventory: opcode map drift",
    )
    require(
        [(entry.get("name"), entry.get("kind"), entry.get("binary_fields")) for entry in exception_inventory.get("catch_clauses", [])]
        == [
            ("catch", 0, ["tag_index:u32", "label_index:u32"]),
            ("catch_ref", 1, ["tag_index:u32", "label_index:u32"]),
            ("catch_all", 2, ["label_index:u32"]),
            ("catch_all_ref", 3, ["label_index:u32"]),
        ],
        "exception inventory: catch-clause drift",
    )
    exception_corpus = exception_inventory.get("corpus", {})
    exception_files = exception_corpus.get("files", [])
    require(exception_corpus.get("top_level_commands") == 86, "exception inventory: expected 86 corpus commands")
    require(
        [(entry.get("path"), entry.get("top_level_commands")) for entry in exception_files]
        == [
            ("test/core/tag.wast", 4),
            ("test/core/throw.wast", 13),
            ("test/core/throw_ref.wast", 15),
            ("test/core/try_table.wast", 54),
        ],
        "exception inventory: corpus file/count drift",
    )
    require(
        sum(sum(entry.get("commands", {}).values()) for entry in exception_files) == 86,
        "exception inventory: command breakdown drift",
    )
    require(
        re.search(r"^    tag = 4,$", source, re.MULTILINE) is not None,
        "exception inventory/runtime tag external-kind drift",
    )
    require(
        re.search(r"pub const Tag = struct \{\s+type_index: u32,\s+\};", source) is not None,
        "exception inventory/runtime tag declaration drift",
    )
    require(
        re.search(r"^    exnref = 0x69,$", source, re.MULTILINE) is not None,
        "exception inventory/runtime exnref drift",
    )
    runtime_exception_ops = {
        (name, int(value, 16))
        for name, value in re.findall(r"^    ([a-z][a-z0-9_]*?) = 0x([0-9A-F]{2}),$", op_enum, re.MULTILINE)
        if name in {"throw", "throw_ref", "try_table"}
    }
    require(
        runtime_exception_ops == {(entry["name"], entry["opcode"]) for entry in exception_inventory["opcodes"]},
        "exception inventory/runtime opcode drift",
    )
    require(
        "13 => 6," in decode_source
        and "mod.tags = try parseTagSection(&r, a);" in decode_source,
        "exception inventory/runtime tag section drift",
    )
    require(
        ".tag = try r.readTag()" in decode_source
        and "malformed tag attribute" in decode_source,
        "exception inventory/runtime tag import drift",
    )
    require(
        "fn validateTagType" in validate_source
        and "e.index >= mod.totalTags()" in validate_source,
        "exception inventory/runtime tag validation drift",
    )
    require(
        all(token in decode_source for token in (".catch_tag", ".catch_ref", ".catch_all", ".catch_all_ref")),
        "exception inventory/runtime catch-clause drift",
    )
    require(
        all(token in exception_runtime_source for token in (
            "fn handleException",
            "fn throwTag",
            "fn throwReference",
            "fn handleHostException",
            "fn finalizeExceptions",
            "deepExceptionBody(512)",
            "exception references publish concurrently",
        )),
        "exception inventory/runtime unwinding evidence drift",
    )
    require(
        all(token in exception_api_source for token in (
            "fn tagParameterTypes",
            "fn tagConstructor",
            "fn exceptionConstructor",
            "fn exposeUncaughtException",
            '"JSTag"',
            "wasm api transports typed exceptions",
            "wasm api exception payloads and wrappers survive precise GC",
        )),
        "exception inventory/JavaScript API evidence drift",
    )
    require(
        "wasm-exception-jsc-diff" in build_source
        and "WebAssembly.Exception.prototype.getArg" in exception_diff_source
        and "WebAssembly.JSTag" in exception_diff_source,
        "exception inventory/JavaScriptCore differential evidence drift",
    )
    tail_feature = next(feature for feature in features if feature["id"] == "tail_calls")
    verify_terminal_inventory(
        args.tail_call_terminal_inventory,
        kind="webassembly_tail_call_inventory",
        profile="tail-calls",
        repository=tail_feature["repository"],
        commit=tail_feature["commit"],
        features=["multi_value", "reference_types", "bulk_memory", "tail_calls"],
        files=[("return_call.wast", 44, 0), ("return_call_indirect.wast", 64, 11)],
    )
    verify_terminal_inventory(
        args.exception_handling_terminal_inventory,
        kind="webassembly_exception_handling_inventory",
        profile="exception-handling",
        repository=exception_feature["repository"],
        commit=exception_feature["commit"],
        features=["multi_value", "reference_types", "bulk_memory", "tail_calls", "exception_handling"],
        files=[("tag.wast", 4, 0), ("throw.wast", 13, 0), ("throw_ref.wast", 15, 0), ("try_table.wast", 52, 2)],
    )
    multi_memory_feature = next(feature for feature in features if feature["id"] == "multi_memory")
    multi_memory = json.loads(args.multi_memory_inventory.read_text())
    require(multi_memory.get("schema_version") == 1, "multi-memory inventory: unsupported schema version")
    require(multi_memory.get("kind") == "webassembly_multi_memory_binary_inventory", "multi-memory inventory: invalid kind")
    multi_memory_source = multi_memory.get("source", {})
    require(multi_memory_source.get("repository") == multi_memory_feature["repository"], "multi-memory inventory/registry repository drift")
    require(multi_memory_source.get("commit") == multi_memory_feature["commit"], "multi-memory inventory/registry commit drift")
    require(multi_memory.get("standardization") == multi_memory_feature["standardization"] == "finished", "multi-memory inventory standardization drift")
    require(multi_memory.get("edition") == multi_memory_feature["edition"] == "3.0", "multi-memory inventory edition drift")
    require(multi_memory.get("dependencies") == multi_memory_feature["dependencies"] == [], "multi-memory inventory dependency drift")
    require(
        multi_memory_source.get("document_sha256") == {
            "proposals/multi-memory/Overview.md": "6e75c9c80c961a0ae63647b128fd6bf3ebcdac859f96108ddfb3ef047706a977",
            "document/core/binary/instructions.rst": "36d52da86f46f26435ac82dec7afa6d700745ab71568aacbd08dd506fdee91f4",
            "document/core/text/instructions.rst": "4730bd06008b74d505165e155c26024bd688e17333e78a5cf7d5604f4515016e",
            "document/core/syntax/instructions.rst": "6b7b74c53c0f946bef5990bd0c45040a165f24843e1eddb28451fab6092e40ca",
        },
        "multi-memory inventory normative document drift",
    )
    multi_memory_binary = multi_memory.get("binary_changes", {})
    require(multi_memory_binary.get("new_opcodes") == [], "multi-memory inventory must not declare new opcodes")
    require(multi_memory_binary.get("memory_index") == "u32", "multi-memory inventory index encoding drift")
    multi_memory_memarg = multi_memory_binary.get("memarg", {})
    require(
        multi_memory_memarg.get("implicit_memory_zero") == {
            "fields": ["align_flags:u32", "offset:u32"],
            "align_flags_range": [0, 63],
            "memory_index": 0,
        },
        "multi-memory inventory implicit memarg drift",
    )
    require(
        multi_memory_memarg.get("explicit_memory") == {
            "fields": ["align_flags:u32", "memory_index:u32", "offset:u32"],
            "align_flags_range": [64, 127],
            "explicit_memory_index_bit": 6,
            "decoded_alignment": "align_flags - 64",
        },
        "multi-memory inventory explicit memarg drift",
    )
    require(
        [(entry.get("instruction", entry.get("family")), entry.get("opcode"), entry.get("fields")) for entry in multi_memory_binary.get("instruction_immediates", [])]
        == [
            ("scalar/vector load/store", None, ["memarg"]),
            ("memory.size", "0x3f", ["memory_index:u32"]),
            ("memory.grow", "0x40", ["memory_index:u32"]),
            ("memory.init", "0xfc:8", ["data_index:u32", "memory_index:u32"]),
            ("memory.copy", "0xfc:10", ["destination_memory_index:u32", "source_memory_index:u32"]),
            ("memory.fill", "0xfc:11", ["memory_index:u32"]),
        ],
        "multi-memory inventory instruction immediate drift",
    )
    multi_memory_text = multi_memory.get("text_changes", {})
    require(multi_memory_text.get("omitted_memory_index") == 0, "multi-memory inventory text default drift")
    require(multi_memory_text.get("load_store_order") == ["memory_index", "offset", "align"], "multi-memory inventory load/store text order drift")
    require(
        multi_memory_text.get("memory_copy_order") == ["destination_memory_index", "source_memory_index"]
        and multi_memory_text.get("memory_copy_presence") == "both_or_neither",
        "multi-memory inventory memory.copy text drift",
    )
    require(
        multi_memory.get("complete_upstream_inventory") == args.multi_memory_terminal_inventory.name,
        "multi-memory inventory terminal evidence link drift",
    )
    require(
        all(token in decode_source for token in (
            "const has_memory_index = flags & 0x40 != 0;",
            "if (has_memory_index and !self.features.multi_memory)",
            "const memory_index = if (has_memory_index) try self.readU32Leb() else 0;",
            ".align_ = if (has_memory_index) flags - 0x40 else flags,",
            ".memory_index = memory_index,",
        )),
        "multi-memory inventory/runtime memarg decoder drift",
    )
    verify_terminal_inventory(
        args.multi_memory_terminal_inventory,
        kind="webassembly_multi_memory_runtime_inventory",
        profile="multi-memory",
        repository=multi_memory_feature["repository"],
        commit=multi_memory_feature["commit"],
        features=["multi_value", "reference_types", "bulk_memory", "multi_memory"],
        files=[
            ("memory-multi.wast", 6, 0), ("address0.wast", 92, 0),
            ("address1.wast", 127, 0), ("align0.wast", 5, 0),
            ("binary0.wast", 7, 0), ("data0.wast", 7, 0),
            ("data1.wast", 14, 0), ("data_drop0.wast", 11, 0),
            ("exports0.wast", 8, 0), ("float_exprs0.wast", 14, 0),
            ("float_exprs1.wast", 3, 0), ("float_memory0.wast", 30, 0),
            ("imports0.wast", 8, 0), ("imports1.wast", 5, 0),
            ("imports2.wast", 20, 0), ("imports3.wast", 10, 0),
            ("imports4.wast", 16, 0), ("linking0.wast", 6, 0),
            ("linking1.wast", 14, 0), ("linking2.wast", 11, 0),
            ("linking3.wast", 14, 0), ("load0.wast", 3, 0),
            ("load1.wast", 18, 0), ("load2.wast", 38, 0),
            ("memory_copy0.wast", 29, 0), ("memory_copy1.wast", 14, 0),
            ("memory_fill0.wast", 16, 0), ("memory_init0.wast", 13, 0),
            ("memory_size0.wast", 8, 0), ("memory_size1.wast", 15, 0),
            ("memory_size2.wast", 21, 0), ("memory_size3.wast", 2, 0),
            ("memory_trap0.wast", 14, 0), ("memory_trap1.wast", 168, 0),
            ("start0.wast", 9, 0), ("store0.wast", 5, 0),
            ("store1.wast", 13, 0), ("traps0.wast", 15, 0),
        ],
        pass_modes=("javascript_api", "bit_exact"),
    )
    multi_memory_terminal = json.loads(args.multi_memory_terminal_inventory.read_text())
    require(
        sum(
            command.get("mode") == "bit_exact"
            for entry in multi_memory_terminal.get("files", [])
            for command in entry.get("commands", [])
        ) == 6,
        "multi-memory: bit-exact assertion count drift",
    )
    memory64_feature = next(feature for feature in features if feature["id"] == "memory64")
    verify_terminal_inventory(
        args.memory64_terminal_inventory,
        kind="webassembly_memory64_runtime_inventory",
        profile="memory64",
        repository=memory64_feature["repository"],
        commit=memory64_feature["commit"],
        features=[
            "memory64", "multi_memory", "typed_function_references",
            "tail_calls", "exception_handling",
        ],
        files=[
            ("address64.wast", 242, 0), ("align64.wast", 110, 46),
            ("call_indirect.wast", 160, 11), ("endianness64.wast", 69, 0),
            ("float_memory64.wast", 90, 0), ("imports.wast", 243, 16),
            ("load64.wast", 84, 13), ("memory64.wast", 69, 0),
            ("memory_copy.wast", 8900, 0), ("memory_fill.wast", 200, 0),
            ("memory_grow64.wast", 49, 0), ("memory_init.wast", 480, 0),
            ("memory_redundancy64.wast", 8, 0), ("memory_trap64.wast", 172, 0),
            ("table.wast", 54, 6), ("table_copy.wast", 1772, 0),
            ("table_copy_mixed.wast", 4, 0), ("table_fill.wast", 80, 0),
            ("table_get.wast", 17, 0), ("table_grow.wast", 79, 0),
            ("table_init.wast", 876, 0), ("table_set.wast", 28, 0),
            ("table_size.wast", 40, 0),
        ],
        pass_modes=("javascript_api", "bit_exact"),
        converter_kind="wasm-tools",
        converter_version="1.253.0",
        converter_commit="c799bb87b9cf9dc4fa7d11d63c5d52cbb3c4eb38",
        not_applicable_types=("assert_malformed", "assert_invalid"),
    )
    memory64_terminal = json.loads(args.memory64_terminal_inventory.read_text())
    require(
        sum(
            command.get("mode") == "bit_exact"
            for entry in memory64_terminal.get("files", [])
            for command in entry.get("commands", [])
        ) == 20,
        "memory64: bit-exact assertion count drift",
    )
    memory64 = json.loads(args.memory64_inventory.read_text())
    require(memory64.get("schema_version") == 1, "memory64 inventory: unsupported schema version")
    require(memory64.get("kind") == "webassembly_memory64_binary_inventory", "memory64 inventory: invalid kind")
    memory64_source = memory64.get("source", {})
    require(memory64_source.get("repository") == memory64_feature["repository"], "memory64 inventory/registry repository drift")
    require(memory64_source.get("commit") == memory64_feature["commit"], "memory64 inventory/registry commit drift")
    require(memory64.get("dependencies") == memory64_feature["dependencies"], "memory64 inventory dependency drift")
    require(memory64.get("hosts") == memory64_feature["hosts"] == ["pointer_width_64"], "memory64 inventory host drift")
    require(
        memory64.get("address_types") == [
            {"name": "i32", "bits": 32, "memory_max_pages": 65536, "table_max_elements": 4294967295},
            {"name": "i64", "bits": 64, "memory_max_pages": 281474976710656, "table_max_elements": 18446744073709551615},
        ],
        "memory64 inventory address-type drift",
    )
    require(
        [
            (entry.get("flag"), entry.get("address_type"), entry.get("minimum"), entry.get("maximum"), entry.get("shared"))
            for entry in memory64.get("limit_flags", [])
        ] == [
            (0, "i32", "u32", None, False),
            (1, "i32", "u32", "u32", False),
            (2, "i32", "u32", None, True),
            (3, "i32", "u32", "u32", True),
            (4, "i64", "u64", None, False),
            (5, "i64", "u64", "u64", False),
            (6, "i64", "u64", None, True),
            (7, "i64", "u64", "u64", True),
        ],
        "memory64 inventory limits encoding drift",
    )
    memory64_binary = memory64.get("binary_changes", {})
    require(memory64_binary.get("new_opcodes") == [], "memory64 inventory must not declare new opcodes")
    require(memory64_binary.get("memarg_fields") == ["align:u32", "offset:u64"], "memory64 inventory memarg drift")
    memory64_corpus = memory64.get("corpus", {})
    memory64_files = memory64_corpus.get("files", [])
    expected_memory64_files = [
        ("address64.wast", 242), ("align64.wast", 156), ("call_indirect.wast", 171),
        ("endianness64.wast", 69), ("float_memory64.wast", 90), ("imports.wast", 259),
        ("load64.wast", 97), ("memory64.wast", 69), ("memory_copy.wast", 8900),
        ("memory_fill.wast", 200), ("memory_grow64.wast", 49), ("memory_init.wast", 480),
        ("memory_redundancy64.wast", 8), ("memory_trap64.wast", 172), ("table.wast", 60),
        ("table_copy.wast", 1772), ("table_copy_mixed.wast", 4), ("table_fill.wast", 80),
        ("table_get.wast", 17), ("table_grow.wast", 79), ("table_init.wast", 876),
        ("table_set.wast", 28), ("table_size.wast", 40),
    ]
    require(
        [(Path(entry.get("path", "")).name, entry.get("top_level_commands")) for entry in memory64_files]
        == expected_memory64_files,
        "memory64 inventory corpus file/count drift",
    )
    require(memory64_corpus.get("files_available") == 120, "memory64 inventory available-file drift")
    require(memory64_corpus.get("files_declared") == len(expected_memory64_files) == 23, "memory64 inventory declared-file drift")
    require(memory64_corpus.get("top_level_commands") == 13918, "memory64 inventory command total drift")
    require(sum(sum(entry.get("commands", {}).values()) for entry in memory64_files) == 13918, "memory64 inventory command breakdown drift")
    require(sum(entry.get("memory64_declarations", 0) for entry in memory64_files) == 824, "memory64 inventory declaration drift")
    require(sum(entry.get("table64_declarations", 0) for entry in memory64_files) == 151, "table64 inventory declaration drift")

    gc_feature = next(feature for feature in features if feature["id"] == "gc")
    gc_inventory = json.loads(args.gc_inventory.read_text())
    require(gc_inventory.get("schema_version") == 1, "GC inventory: unsupported schema version")
    require(gc_inventory.get("kind") == "webassembly_gc_binary_inventory", "GC inventory: invalid kind")
    gc_source = gc_inventory.get("source", {})
    require(gc_source.get("repository") == gc_feature["repository"], "GC inventory/registry repository drift")
    require(gc_source.get("commit") == gc_feature["commit"], "GC inventory/registry commit drift")
    require(gc_inventory.get("dependencies") == gc_feature["dependencies"] == ["typed_function_references"], "GC inventory dependency drift")
    require(gc_source.get("corpus_tree") == "97755327e6db5943ccd4cce6bc92e1a72c523e3f", "GC inventory corpus tree drift")
    gc_hashes = gc_source.get("document_sha256", {})
    require(
        gc_hashes == {
            "proposals/gc/Overview.md": "1cc66876b716e4359f8623e8ad8492641a412965523fbb77fe691a6888cf5102",
            "document/core/binary/types.rst": "ee8858f4d82bbf9435512cc9b47cd0b30ad6a3fc667c2bc2db3f17cd1bf893ca",
            "document/core/binary/instructions.rst": "8d74c260473617cc61b794ac67c480821578c4be3f65011bc9f597e3c30aba4a",
            "document/core/valid/types.rst": "2fc40d1e0bd3e2b3c6024942f967533eaa2d55c577ebceeb289ba0c25ca65e1a",
            "document/core/valid/instructions.rst": "8dd56035753cb9019fda35f860c00fed01162a382a05e39841e58c8fb0aae754",
        },
        "GC inventory normative document drift",
    )
    gc_types = gc_inventory.get("type_encodings", {})
    require(gc_types.get("packed") == [{"name": "i8", "byte": 0x78}, {"name": "i16", "byte": 0x77}], "GC packed-type encoding drift")
    require(
        [(entry.get("name"), entry.get("byte")) for entry in gc_types.get("abstract_heap", [])]
        == list(zip(
            ["nofunc", "noextern", "none", "func", "extern", "any", "eq", "i31", "struct", "array"],
            range(0x73, 0x69, -1),
        )),
        "GC abstract heap-type encoding drift",
    )
    require(
        [(entry.get("name"), entry.get("byte"), entry.get("nullable")) for entry in gc_types.get("reference", [])]
        == [("ref", 0x64, False), ("ref_null", 0x63, True)],
        "GC reference-type encoding drift",
    )
    require(
        [(entry.get("name"), entry.get("byte")) for entry in gc_types.get("composite", [])]
        == [("func", 0x60), ("struct", 0x5F), ("array", 0x5E)],
        "GC composite-type encoding drift",
    )
    require(
        [(entry.get("byte"), entry.get("final")) for entry in gc_types.get("subtype", [])]
        == [(0x50, False), (0x4F, True)]
        and gc_types.get("recursive_group", {}).get("byte") == 0x4E,
        "GC recursive/subtype encoding drift",
    )
    gc_opcodes = gc_inventory.get("opcodes", [])
    require(gc_inventory.get("opcode_count") == len(gc_opcodes) == 33, "GC inventory: expected 33 opcodes")
    require(
        [(entry.get("name"), entry.get("opcode")) for entry in gc_opcodes[:2]]
        == [("ref.eq", 0xD3), ("ref.as_non_null", 0xD4)],
        "GC direct opcode drift",
    )
    expected_gc_prefixed_names = [
        "struct.new", "struct.new_default", "struct.get", "struct.get_s", "struct.get_u", "struct.set",
        "array.new", "array.new_default", "array.new_fixed", "array.new_data", "array.new_elem",
        "array.get", "array.get_s", "array.get_u", "array.set", "array.len", "array.fill", "array.copy",
        "array.init_data", "array.init_elem", "ref.test", "ref.test_null", "ref.cast", "ref.cast_null",
        "br_on_cast", "br_on_cast_fail", "any.convert_extern", "extern.convert_any", "ref.i31", "i31.get_s", "i31.get_u",
    ]
    require(
        [(entry.get("name"), entry.get("prefix"), entry.get("subopcode")) for entry in gc_opcodes[2:]]
        == [(name, 0xFB, subopcode) for subopcode, name in enumerate(expected_gc_prefixed_names)],
        "GC prefixed opcode drift",
    )
    require(len({entry.get("name") for entry in gc_opcodes}) == 33, "GC duplicate instruction name")
    gc_runtime_source = args.gc_source.read_text()
    gc_runtime_enum = gc_runtime_source.split("pub const Op = enum(u8) {", 1)[1].split("pub fn fromSubopcode", 1)[0]
    runtime_gc_opcodes = [
        (name, int(value, 16))
        for name, value in re.findall(r"^    ([a-z][a-z0-9_]*) = 0x([0-9A-F]{2}),$", gc_runtime_enum, re.MULTILINE)
    ]
    require(
        runtime_gc_opcodes == [(name.replace(".", "_"), subopcode) for subopcode, name in enumerate(expected_gc_prefixed_names)],
        "GC inventory/runtime prefixed opcode drift",
    )
    require(
        all(token in source for token in ("ref_eq = 0xD3", "ref_as_non_null = 0xD4", "gc = 0xFB")),
        "GC inventory/runtime direct opcode drift",
    )
    gc_corpus = gc_inventory.get("corpus", {})
    gc_files = gc_corpus.get("files", [])
    expected_gc_files = [
        ("array.wast", 46), ("array_copy.wast", 35), ("array_fill.wast", 17),
        ("array_init_data.wast", 33), ("array_init_elem.wast", 23), ("array_new_data.wast", 15),
        ("array_new_elem.wast", 22), ("binary-gc.wast", 1), ("br_on_cast.wast", 37),
        ("br_on_cast_fail.wast", 37), ("extern.wast", 18), ("i31.wast", 73),
        ("ref_cast.wast", 45), ("ref_eq.wast", 89), ("ref_test.wast", 71),
        ("struct.wast", 30), ("type-subtyping-invalid.wast", 4), ("type-subtyping.wast", 102),
    ]
    require(
        [(Path(entry.get("path", "")).name, entry.get("top_level_commands")) for entry in gc_files]
        == expected_gc_files,
        "GC inventory corpus file/count drift",
    )
    require(gc_corpus.get("files_declared") == len(expected_gc_files) == 18, "GC inventory declared-file drift")
    require(gc_corpus.get("top_level_commands") == 698, "GC inventory command total drift")
    require(sum(sum(entry.get("commands", {}).values()) for entry in gc_files) == 698, "GC inventory command breakdown drift")
    expected_gc_occurrences = {
        "any.convert_extern": 8, "array.copy": 9, "array.fill": 5, "array.get": 14,
        "array.get_s": 1, "array.get_u": 13, "array.init_data": 5, "array.init_elem": 5,
        "array.len": 6, "array.new": 8, "array.new_data": 9, "array.new_default": 13,
        "array.new_elem": 9, "array.new_fixed": 4, "array.set": 6, "br_on_cast": 61,
        "br_on_cast_fail": 72, "extern.convert_any": 6, "i31.get_s": 2, "i31.get_u": 14,
        "ref.as_non_null": 2, "ref.cast": 64, "ref.eq": 11, "ref.i31": 46,
        "ref.test": 121, "struct.get": 11, "struct.get_s": 12, "struct.get_u": 10,
        "struct.new": 5, "struct.new_default": 46, "struct.set": 6,
    }
    require(gc_corpus.get("instruction_occurrences") == expected_gc_occurrences, "GC inventory instruction-occurrence drift")

    movement = json.loads(args.simd_movement_inventory.read_text())
    require(movement.get("schema_version") == 2, "SIMD movement inventory: unsupported schema version")
    require(movement.get("kind") == "webassembly_fixed_width_simd_movement_inventory", "SIMD movement inventory: invalid kind")
    require(movement.get("profile") == "simd-movement", "SIMD movement inventory: invalid profile")
    require(movement.get("spec", {}).get("repository") == simd_feature["repository"], "SIMD movement inventory: repository drift")
    require(movement.get("spec", {}).get("commit") == simd_feature["commit"], "SIMD movement inventory: commit drift")
    require(movement.get("spec", {}).get("files_available") == 56, "SIMD movement inventory: expected 56 available files")
    require(movement.get("spec", {}).get("files_scored") == 20, "SIMD movement inventory: expected 20 scored files")
    require(SHA.fullmatch(movement.get("engine_commit", "")) is not None, "SIMD movement inventory: invalid engine commit")
    movement_totals = movement.get("totals", {})
    require(movement_totals.get("pass") == 2253, "SIMD movement inventory: expected 2253 passing commands")
    require(movement_totals.get("not_applicable") == 351, "SIMD movement inventory: expected 351 explicit n/a commands")
    require(movement_totals.get("total") == 2604, "SIMD movement inventory: expected 2604 total commands")
    require(movement_totals.get("fail") == 0 and movement_totals.get("runner_error") == 0, "SIMD movement inventory: terminal score is not green")
    require(len(movement.get("files", [])) == 20, "SIMD movement inventory: file detail count drift")

    complete = json.loads(args.simd_complete_inventory.read_text())
    require(complete.get("schema_version") == 2, "complete SIMD inventory: unsupported schema version")
    require(complete.get("kind") == "webassembly_fixed_width_simd_inventory", "complete SIMD inventory: invalid kind")
    require(complete.get("profile") == "simd", "complete SIMD inventory: invalid profile")
    require(complete.get("spec", {}).get("repository") == simd_feature["repository"], "complete SIMD inventory: repository drift")
    require(complete.get("spec", {}).get("commit") == simd_feature["commit"], "complete SIMD inventory: commit drift")
    require(complete.get("spec", {}).get("files_available") == 56, "complete SIMD inventory: expected 56 available files")
    require(complete.get("spec", {}).get("files_scored") == 56, "complete SIMD inventory: expected 56 scored files")
    require(SHA.fullmatch(complete.get("engine_commit", "")) is not None, "complete SIMD inventory: invalid engine commit")
    complete_totals = complete.get("totals", {})
    require(complete_totals.get("pass") == 25466, "complete SIMD inventory: expected 25466 passing commands")
    require(complete_totals.get("not_applicable") == 510, "complete SIMD inventory: expected 510 explicit n/a commands")
    require(complete_totals.get("total") == 25976, "complete SIMD inventory: expected 25976 total commands")
    require(complete_totals.get("fail") == 0 and complete_totals.get("runner_error") == 0, "complete SIMD inventory: terminal score is not green")
    complete_files = complete.get("files", [])
    require(len(complete_files) == 56, "complete SIMD inventory: file detail count drift")
    require(len({entry.get("path") for entry in complete_files}) == 56, "complete SIMD inventory: duplicate file detail")
    complete_modes = {
        command.get("mode")
        for entry in complete_files
        for command in entry.get("commands", [])
    }
    require(
        complete_modes == {"javascript_api", "not_applicable", "vector_bits", "vector_nan_policy"},
        f"complete SIMD inventory: execution-mode drift {sorted(complete_modes)}",
    )

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
