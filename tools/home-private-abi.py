#!/usr/bin/env python3
"""Generate and verify Home's revision-pinned private extern-fn inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/abi/home-private-7ed99c02-inventory.json"
SCRIPT_EXECUTION_CONTEXT_CONTRACT = ROOT / "docs/abi/home-script-execution-context-7ed99c02.json"
CPU_PROFILE_CONTRACT = ROOT / "docs/abi/cpu-profile-sampling-404.json"
READABLE_STREAM_CONTRACT = ROOT / "docs/abi/readable-stream-consumption-405.json"
FETCH_BODY_CONTRACT = ROOT / "docs/abi/fetch-body-lifecycle-407.json"
WASM_STREAMING_CONTRACT = ROOT / "docs/abi/wasm-streaming-api-408.json"
WASM_STREAMING_COMPILER_CONTRACT = ROOT / "docs/abi/wasm-streaming-compiler-feed-409.json"
WASM_STREAMING_RESPONSE_FEED_CONTRACT = ROOT / "docs/abi/wasm-streaming-response-feed-410.json"
SQL_OBJECT_STRUCTURE_CONTRACT = ROOT / "docs/abi/sql-object-structure-411.json"
WASM_WEB_API_SOURCE = ROOT / "wasm-spec-wg3/document/web-api/index.bs"
PUBLIC_INVENTORY = ROOT / "docs/c-api/jsc-public-api-macos-27.0.json"
EXPORT_SOURCE = ROOT / "src/c_api.zig"
PROFILE_ID = "home-private-7ed99c02"
REVISION = "7ed99c02e50034f869d0db6d487115bb44332fe4"
ALIAS_PROFILES = {
    "home-private-5e829ad4": ROOT / "docs/abi/home-private-5e829ad4.json",
    "home-private-38702f9e": ROOT / "docs/abi/home-private-38702f9e.json",
    "home-private-4389ddee": ROOT / "docs/abi/home-private-4389ddee.json",
}
SOURCE_ROOT = Path("packages/runtime/src/jsc")
# String literals are masked to spaces before this expression runs, so the
# whitespace between `extern` and `fn` covers both the default spelling and an
# explicit link name. declarations() inspects the original slice and keeps only
# the default linkage or the C library name.
EXTERN_RE = re.compile(r"\b(?:pub\s+)?extern\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
EXTERN_LINK_RE = re.compile(r'^\s*"([^"]+)"\s*$')
PLATFORM_IMPORTS = {
    "connect",
    "gnu_get_libc_version",
    "kill",
    "poll",
    "recvfrom",
    "sendto",
    "socket",
}
# Symbols declared in the pinned Zig sources but defined by the consumer rather
# than imported from JavaScriptCore. Keep them in the revision-pinned inventory
# for provenance, but never require zig-js to export a duplicate definition.
CONSUMER_PROVIDED = {"JSFunctionCall"}
EXPORT_RE = re.compile(r"^export fn ([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)


def fail(message: str) -> None:
    print(f"Home private ABI audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def mask_non_code(source: str) -> str:
    """Mask Zig comments and string/character literals while retaining offsets."""
    chars = list(source)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(chars):
        current = chars[index]
        following = chars[index + 1] if index + 1 < len(chars) else ""
        if state == "code":
            if current == "/" and following == "/":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "line_comment"
                continue
            if current == "/" and following == "*":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "block_comment"
                block_depth = 1
                continue
            if current == '"':
                chars[index] = " "
                index += 1
                state = "string"
                continue
            if current == "'":
                chars[index] = " "
                index += 1
                state = "character"
                continue
            if current == "\\" and following == "\\":
                chars[index] = chars[index + 1] = " "
                index += 2
                state = "multiline_string"
                continue
            index += 1
            continue

        if state in {"line_comment", "multiline_string"}:
            if current == "\n":
                state = "code"
            else:
                chars[index] = " "
            index += 1
            continue

        if state == "block_comment":
            if current == "/" and following == "*":
                chars[index] = chars[index + 1] = " "
                block_depth += 1
                index += 2
            elif current == "*" and following == "/":
                chars[index] = chars[index + 1] = " "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                if current != "\n":
                    chars[index] = " "
                index += 1
            continue

        if state in {"string", "character"}:
            delimiter = '"' if state == "string" else "'"
            if current == "\\":
                chars[index] = " "
                if index + 1 < len(chars):
                    if chars[index + 1] != "\n":
                        chars[index + 1] = " "
                    index += 2
                else:
                    index += 1
            elif current == delimiter:
                chars[index] = " "
                index += 1
                state = "code"
            else:
                if current != "\n":
                    chars[index] = " "
                index += 1
            continue

    return "".join(chars)


def normalize(declaration: str) -> str:
    return re.sub(r"\s+", " ", declaration.strip())


def expected_classification(name: str, public_names: set[str]) -> str:
    if name in public_names:
        return "public_c_api"
    if name in PLATFORM_IMPORTS:
        return "platform_import"
    if name in CONSUMER_PROVIDED:
        return "consumer_provided"
    return "private_jsc"


def unique_symbol_declarations(
    entries: list[dict[str, object]],
) -> list[dict[str, object]]:
    """Collapse repeated imports into one deterministic symbol contract.

    Consumer modules legitimately redeclare the same C symbol with local type
    aliases. Prefer the longstanding default-linkage spelling when present and
    retain every other declaration so revision/signature provenance is not
    discarded.
    """
    grouped: dict[str, list[dict[str, object]]] = {}
    for entry in entries:
        grouped.setdefault(str(entry["name"]), []).append(entry)

    result: list[dict[str, object]] = []
    for name in sorted(grouped):
        candidates = sorted(
            grouped[name],
            key=lambda entry: (
                'extern "' in str(entry["declaration"]),
                str(entry["source"]),
                int(entry["line"]),
            ),
        )
        canonical = candidates[0]
        if len(candidates) > 1:
            canonical["alternate_declarations"] = [
                {
                    "source": entry["source"],
                    "line": entry["line"],
                    "declaration": entry["declaration"],
                    "declaration_sha256": entry["declaration_sha256"],
                }
                for entry in candidates[1:]
            ]
        result.append(canonical)
    return result


def declarations(path: Path, source_root: Path, public_names: set[str]) -> list[dict[str, object]]:
    source = path.read_text()
    masked = mask_non_code(source)
    result: list[dict[str, object]] = []
    for match in EXTERN_RE.finditer(masked):
        name = match.group(1)
        open_paren = masked.find("(", match.start())
        if open_paren < 0:
            fail(f"missing parameter list for {name} in {path}")
        extern_start = masked.find("extern", match.start(), open_paren)
        fn_start = masked.find("fn", extern_start + len("extern"), open_paren)
        if extern_start < 0 or fn_start < 0:
            fail(f"cannot parse extern declaration for {name} in {path}")
        link_source = source[extern_start + len("extern"):fn_start]
        if link_source.strip():
            link_match = EXTERN_LINK_RE.fullmatch(link_source)
            if link_match is None or link_match.group(1).lower() != "c":
                continue
        depth = 0
        close_paren = -1
        for index in range(open_paren, len(masked)):
            if masked[index] == "(":
                depth += 1
            elif masked[index] == ")":
                depth -= 1
                if depth == 0:
                    close_paren = index
                    break
        if close_paren < 0:
            fail(f"unterminated parameter list for {name} in {path}")
        semicolon = masked.find(";", close_paren)
        if semicolon < 0:
            fail(f"unterminated declaration for {name} in {path}")
        declaration = normalize(source[match.start():semicolon + 1])
        convention_match = re.search(r"callconv\(([^)]+)\)", source[close_paren + 1:semicolon])
        calling_convention = convention_match.group(1).strip() if convention_match else "C"
        classification = expected_classification(name, public_names)
        if classification == "public_c_api":
            status = "implemented"
            issue = None
        elif classification in {"platform_import", "consumer_provided"}:
            status = "external"
            issue = None
        else:
            classification = "private_jsc"
            status = "pending"
            issue = 163
        entry: dict[str, object] = {
            "name": name,
            "source": path.relative_to(source_root).as_posix(),
            "line": source.count("\n", 0, match.start()) + 1,
            "calling_convention": calling_convention,
            "classification": classification,
            "status": status,
            "declaration": declaration,
            "declaration_sha256": sha256_bytes(declaration.encode()),
        }
        if issue is not None:
            entry["issue"] = issue
        result.append(entry)
    return result


def revision(root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot determine Home revision at {root}: {error}")


def generate(home_root: Path) -> dict[str, object]:
    actual_revision = revision(home_root)
    if actual_revision != REVISION:
        fail(f"Home revision mismatch: {actual_revision} != {REVISION}")
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    absolute_source_root = home_root / SOURCE_ROOT
    entries: list[dict[str, object]] = []
    source_hashes: dict[str, str] = {}
    for path in sorted(absolute_source_root.rglob("*.zig")):
        found = declarations(path, absolute_source_root, public_names)
        if not found:
            continue
        relative = path.relative_to(home_root).as_posix()
        source_hashes[relative] = sha256(path)
        entries.extend(found)
    entries = unique_symbol_declarations(entries)
    classifications = Counter(str(entry["classification"]) for entry in entries)
    return {
        "schema_version": 1,
        "profile_id": PROFILE_ID,
        "kind": "private_abi_inventory",
        "consumer": {
            "name": "Home",
            "revision": REVISION,
            "source_root": SOURCE_ROOT.as_posix(),
            "source_files": source_hashes,
        },
        "boundary": {
            "included": "unique symbols from Zig extern fn and extern \"c\"/\"C\" fn declarations under packages/runtime/src/jsc; repeated imports retain alternate declaration provenance",
            "excluded": "non-C named-library declarations; consumer-generated definitions such as JSFunctionCall remain inventoried as consumer_provided",
            "implementation_issue": 163,
        },
        "calling_conventions": {
            "C": "extern default C calling convention, with optional explicit c/C library linkage",
            ".c": "explicit C calling convention",
            "jsc.conv": "x86_64 SysV on Windows x64; C on every other Home target"
        },
        "totals": {
            "symbols": len(entries),
            "source_files": len(source_hashes),
            "by_classification": dict(sorted(classifications.items())),
        },
        "declarations": entries,
    }


def refresh_implementation_status(data: dict[str, object]) -> None:
    zig_js_exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    for entry in data["declarations"]:
        entry["classification"] = expected_classification(str(entry["name"]), public_names)
        if entry["classification"] != "private_jsc":
            if entry["classification"] == "public_c_api":
                entry["status"] = "implemented"
            else:
                entry["status"] = "external"
            entry.pop("issue", None)
            entry.pop("implementation", None)
            continue
        if entry["name"] in zig_js_exports:
            entry["status"] = "implemented"
            entry.pop("issue", None)
            entry["implementation"] = "src/c_api.zig"
        else:
            entry["status"] = "pending"
            entry["issue"] = 163
            entry.pop("implementation", None)
    statuses = Counter(str(entry["status"]) for entry in data["declarations"])
    classifications = Counter(str(entry["classification"]) for entry in data["declarations"])
    data["totals"]["by_status"] = dict(sorted(statuses.items()))
    data["totals"]["by_classification"] = dict(sorted(classifications.items()))


def verify_alias(home_root: Path, stored: dict[str, object], profile_id: str) -> None:
    alias = json.loads(ALIAS_PROFILES[profile_id].read_text())
    if alias.get("schema_version") != 1 or alias.get("profile_id") != profile_id:
        fail("alias profile schema or identity mismatch")
    if alias.get("base_profile") != PROFILE_ID or alias.get("base_revision") != REVISION:
        fail("alias base-profile identity mismatch")
    actual_revision = revision(home_root)
    expected_revision = alias["consumer"]["revision"]
    if actual_revision != expected_revision:
        fail(f"Home revision mismatch: {actual_revision} != {expected_revision}")

    source_files = stored["consumer"]["source_files"]
    canonical_manifest = json.dumps(source_files, sort_keys=True, separators=(",", ":")).encode()
    if sha256_bytes(canonical_manifest) != alias.get("source_manifest_sha256"):
        fail("alias source-manifest digest mismatch")
    for relative, expected_digest in source_files.items():
        path = home_root / relative
        if not path.is_file() or sha256(path) != expected_digest:
            fail(f"alias source hash mismatch for {relative}")

    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    absolute_source_root = home_root / SOURCE_ROOT
    current: list[dict[str, object]] = []
    current_source_files: set[str] = set()
    for path in sorted(absolute_source_root.rglob("*.zig")):
        found = declarations(path, absolute_source_root, public_names)
        if found:
            current.extend(found)
            current_source_files.add(path.relative_to(home_root).as_posix())
    current = unique_symbol_declarations(current)
    if current_source_files != set(source_files):
        fail("alias extern source-file set differs from the base profile")
    contract_keys = (
        "name", "source", "line", "calling_convention", "classification",
        "declaration", "declaration_sha256",
    )
    base_contract = [
        {
            **{key: entry[key] for key in contract_keys},
            "alternate_declarations": entry.get("alternate_declarations", []),
        }
        for entry in stored["declarations"]
    ]
    current_contract = [
        {
            **{key: entry[key] for key in contract_keys},
            "alternate_declarations": entry.get("alternate_declarations", []),
        }
        for entry in current
    ]
    if current_contract != base_contract:
        fail("alias declaration/signature/calling-convention contract differs from the base profile")
    if any(value != 0 for value in alias.get("comparison", {}).values()):
        fail("byte-identical alias must report a zero declaration diff")


def validate_stored(data: dict[str, object]) -> None:
    if data.get("schema_version") != 1 or data.get("profile_id") != PROFILE_ID:
        fail("stored inventory schema or profile identity mismatch")
    entries = data.get("declarations")
    if not isinstance(entries, list) or not entries:
        fail("stored inventory has no declarations")
    names: list[str] = []
    counts: Counter[str] = Counter()
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    conventions = set(data.get("calling_conventions", {}))
    zig_js_exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    for entry in entries:
        name = entry.get("name")
        declaration = entry.get("declaration")
        classification = entry.get("classification")
        if not isinstance(name, str) or not isinstance(declaration, str):
            fail("stored declaration is missing a name or signature")
        if entry.get("calling_convention") not in conventions:
            fail(f"{name} has an unsupported calling convention")
        if classification not in {"public_c_api", "platform_import", "consumer_provided", "private_jsc"}:
            fail(f"{name} is unclassified")
        if entry.get("declaration_sha256") != sha256_bytes(declaration.encode()):
            fail(f"{name} declaration digest drift")
        alternates = entry.get("alternate_declarations", [])
        if not isinstance(alternates, list):
            fail(f"{name} alternate declarations are malformed")
        for alternate in alternates:
            alternate_declaration = alternate.get("declaration")
            if (
                not isinstance(alternate_declaration, str)
                or alternate.get("declaration_sha256")
                != sha256_bytes(alternate_declaration.encode())
            ):
                fail(f"{name} alternate declaration digest drift")
        if classification == "private_jsc":
            expected_status = "implemented" if name in zig_js_exports else "pending"
            if entry.get("status") != expected_status:
                fail(f"{name} private implementation status drift")
            if expected_status == "pending" and entry.get("issue") != 163:
                fail(f"{name} pending status is not linked to #163")
            if expected_status == "implemented" and entry.get("implementation") != "src/c_api.zig":
                fail(f"{name} implementation location drift")
        expected = expected_classification(name, public_names)
        if classification != expected:
            fail(f"{name} classification drift: {classification} != {expected}")
        names.append(name)
        counts[str(classification)] += 1
    if len(names) != len(set(names)):
        fail("stored inventory contains duplicate symbols")
    totals = data.get("totals", {})
    if totals.get("symbols") != len(entries) or totals.get("by_classification") != dict(sorted(counts.items())):
        fail("stored inventory totals drift")
    statuses = Counter(str(entry["status"]) for entry in entries)
    if totals.get("by_status") != dict(sorted(statuses.items())):
        fail("stored implementation-status totals drift")
    source_files = data.get("consumer", {}).get("source_files", {})
    if totals.get("source_files") != len(source_files):
        fail("stored source-file total drift")


def validate_script_execution_context_contract(home_root: Path | None) -> None:
    if not SCRIPT_EXECUTION_CONTEXT_CONTRACT.is_file():
        fail(f"missing checked-in ScriptExecutionContext contract {SCRIPT_EXECUTION_CONTEXT_CONTRACT}")
    contract = json.loads(SCRIPT_EXECUTION_CONTEXT_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "script-execution-context-registry-lifecycle"
        or contract.get("revision") != REVISION
        or contract.get("issue") != 401
        or contract.get("parent_issue") != 140
    ):
        fail("ScriptExecutionContext contract schema, revision, or issue drift")
    expected_sources = {
        "packages/runtime/src/native/napi_weak_home_dups.cpp",
        "packages/runtime/upstream/src/jsc/bindings/ScriptExecutionContext.cpp",
    }
    sources = contract.get("sources")
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("ScriptExecutionContext contract source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid ScriptExecutionContext digest for {relative}")
        if home_root is not None:
            path = home_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"ScriptExecutionContext source drift for {relative}")
    expected_exports = {
        "ScriptExecutionContextIdentifier__forGlobalObject",
        "ScriptExecutionContextIdentifier__getGlobalObject",
        "Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier",
    }
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("ScriptExecutionContext export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 8 or len(semantics) != len(set(semantics)):
        fail("ScriptExecutionContext semantic inventory is incomplete or duplicated")


def validate_cpu_profile_contract(home_root: Path | None) -> None:
    if not CPU_PROFILE_CONTRACT.is_file():
        fail(f"missing checked-in CPU profile contract {CPU_PROFILE_CONTRACT}")
    contract = json.loads(CPU_PROFILE_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "per-vm-cpu-sampling-profile"
        or contract.get("issue") != 404
        or contract.get("parent_issues") != [140, 143, 163, 164]
        or contract.get("revisions") != {"home": REVISION, "bun": "4982b91e3702094330f3be3883354c52b8c01323"}
    ):
        fail("CPU profile contract schema, revisions, or issue lineage drift")
    sources = contract.get("sources")
    expected_sources = {
        "packages/runtime/src/jsc/BunCPUProfiler.zig",
        "packages/runtime/upstream/src/jsc/BunCPUProfiler.zig",
        "packages/runtime/upstream/src/jsc/bindings/BunCPUProfiler.cpp",
    }
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("CPU profile source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid CPU profile digest for {relative}")
        if home_root is not None:
            path = home_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"CPU profile source drift for {relative}")
    expected_exports = {"Bun__setSamplingInterval", "Bun__startCPUProfiler", "Bun__stopCPUProfiler"}
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("CPU profile export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 10 or len(semantics) != len(set(semantics)):
        fail("CPU profile semantic inventory is incomplete or duplicated")


def validate_readable_stream_contract(home_root: Path | None) -> None:
    if not READABLE_STREAM_CONTRACT.is_file():
        fail(f"missing checked-in ReadableStream contract {READABLE_STREAM_CONTRACT}")
    contract = json.loads(READABLE_STREAM_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "readable-stream-consumption"
        or contract.get("issue") != 405
        or contract.get("parent_issues") != [140, 143, 163, 164]
        or contract.get("revisions") != {"home": REVISION, "bun": "4982b91e3702094330f3be3883354c52b8c01323"}
    ):
        fail("ReadableStream contract schema, revisions, or issue lineage drift")
    sources = contract.get("sources")
    expected_home = {
        "packages/runtime/src/jsc/JSGlobalObject.zig",
        "packages/runtime/upstream/src/jsc/bindings/webcore/ReadableStream.cpp",
        "packages/runtime/upstream/src/js/builtins/ReadableStream.ts",
        "packages/runtime/upstream/src/js/builtins/ReadableStreamInternals.ts",
    }
    if not isinstance(sources, dict) or set(sources) != {"home", "bun"}:
        fail("ReadableStream contract profile source set drift")
    home_sources = sources.get("home")
    bun_sources = sources.get("bun")
    if not isinstance(home_sources, dict) or set(home_sources) != expected_home or not isinstance(bun_sources, dict):
        fail("ReadableStream contract Home source set drift")
    for profile_sources in (home_sources, bun_sources):
        for relative, digest in profile_sources.items():
            if not isinstance(relative, str) or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                fail(f"invalid ReadableStream digest for {relative}")
    if home_root is not None:
        for relative, digest in home_sources.items():
            path = home_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"ReadableStream source drift for {relative}")
    expected_exports = {
        "ZigGlobalObject__readableStreamToArrayBuffer",
        "ZigGlobalObject__readableStreamToBytes",
        "ZigGlobalObject__readableStreamToText",
        "ZigGlobalObject__readableStreamToJSON",
        "ZigGlobalObject__readableStreamToFormData",
        "ZigGlobalObject__readableStreamToBlob",
    }
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("ReadableStream export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 14 or len(semantics) != len(set(semantics)):
        fail("ReadableStream semantic inventory is incomplete or duplicated")


def validate_fetch_body_contract(home_root: Path | None) -> None:
    if not FETCH_BODY_CONTRACT.is_file():
        fail(f"missing checked-in Fetch Body contract {FETCH_BODY_CONTRACT}")
    contract = json.loads(FETCH_BODY_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "fetch-body-lifecycle"
        or contract.get("issue") != 407
        or contract.get("parent_issues") != [405, 406]
        or contract.get("revisions") != {"home": REVISION, "bun": "4982b91e3702094330f3be3883354c52b8c01323"}
    ):
        fail("Fetch Body contract schema, revisions, or issue lineage drift")
    sources = contract.get("sources")
    expected_home = {
        "packages/runtime/src/runtime/webcore/Body.zig",
        "packages/runtime/src/runtime/webcore/Response.zig",
        "packages/runtime/upstream/src/js/builtins/ReadableStream.ts",
        "packages/runtime/upstream/src/js/builtins/ReadableStreamInternals.ts",
    }
    if not isinstance(sources, dict) or set(sources) != {"home", "bun"}:
        fail("Fetch Body contract profile source set drift")
    home_sources = sources.get("home")
    bun_sources = sources.get("bun")
    if not isinstance(home_sources, dict) or set(home_sources) != expected_home or not isinstance(bun_sources, dict):
        fail("Fetch Body contract Home source set drift")
    for profile_sources in (home_sources, bun_sources):
        for relative, digest in profile_sources.items():
            if not isinstance(relative, str) or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                fail(f"invalid Fetch Body digest for {relative}")
    if home_root is not None:
        for relative, digest in home_sources.items():
            path = home_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"Fetch Body source drift for {relative}")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 12 or len(semantics) != len(set(semantics)):
        fail("Fetch Body semantic inventory is incomplete or duplicated")


def validate_wasm_streaming_contract(home_root: Path | None) -> None:
    if not WASM_STREAMING_CONTRACT.is_file():
        fail(f"missing checked-in WebAssembly streaming contract {WASM_STREAMING_CONTRACT}")
    contract = json.loads(WASM_STREAMING_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "wasm-streaming-api"
        or contract.get("issue") != 408
        or contract.get("parent_issues") != [140, 141, 143, 406]
        or contract.get("follow_up_issue") != 409
        or contract.get("incremental_feed_issue") != 410
        or contract.get("revisions") != {
            "home": REVISION,
            "bun": "4982b91e3702094330f3be3883354c52b8c01323",
            "webassembly_spec": "9d36019973201a19f9c9ebb0f10828b2fe2374aa",
        }
    ):
        fail("WebAssembly streaming contract schema, revisions, or issue lineage drift")
    specification = contract.get("specification")
    if not isinstance(specification, dict) or specification.get("source") != "wasm-spec-wg3/document/web-api/index.bs":
        fail("WebAssembly streaming specification source drift")
    spec_digest = specification.get("sha256")
    if not isinstance(spec_digest, str) or re.fullmatch(r"[0-9a-f]{64}", spec_digest) is None:
        fail("invalid WebAssembly streaming specification digest")
    if WASM_WEB_API_SOURCE.is_file() and sha256(WASM_WEB_API_SOURCE) != spec_digest:
        fail("WebAssembly WG3 Web API source drift")
    sources = contract.get("sources")
    expected_home = {
        "packages/runtime/src/jsc/JSGlobalObject.zig",
        "packages/runtime/upstream/src/jsc/bindings/ZigGlobalObject.cpp",
        "packages/runtime/upstream/src/jsc/bindings/ZigGlobalObject.h",
        "packages/runtime/src/runtime/webcore/Body.zig",
    }
    if not isinstance(sources, dict) or set(sources) != {"home", "bun"}:
        fail("WebAssembly streaming contract profile source set drift")
    home_sources = sources.get("home")
    bun_sources = sources.get("bun")
    if not isinstance(home_sources, dict) or set(home_sources) != expected_home or not isinstance(bun_sources, dict):
        fail("WebAssembly streaming contract Home source set drift")
    for profile_sources in (home_sources, bun_sources):
        for relative, digest in profile_sources.items():
            if not isinstance(relative, str) or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                fail(f"invalid WebAssembly streaming digest for {relative}")
    if home_root is not None:
        for relative, digest in home_sources.items():
            path = home_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"WebAssembly streaming source drift for {relative}")
    profiles = contract.get("feature_profiles")
    if not isinstance(profiles, list) or len(profiles) != 10 or len(profiles) != len(set(profiles)):
        fail("WebAssembly streaming feature-profile inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 15 or len(semantics) != len(set(semantics)):
        fail("WebAssembly streaming semantic inventory is incomplete or duplicated")


def validate_wasm_streaming_compiler_contract(home_root: Path | None) -> None:
    if not WASM_STREAMING_COMPILER_CONTRACT.is_file():
        fail(f"missing checked-in Wasm StreamingCompiler contract {WASM_STREAMING_COMPILER_CONTRACT}")
    contract = json.loads(WASM_STREAMING_COMPILER_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "wasm-streaming-compiler-feed"
        or contract.get("issue") != 409
        or contract.get("parent_issues") != [140, 143, 163, 164, 406]
        or contract.get("related_issue") != 408
        or contract.get("revisions") != {"home": REVISION, "bun": "4982b91e3702094330f3be3883354c52b8c01323"}
    ):
        fail("Wasm StreamingCompiler contract schema, revisions, or issue lineage drift")
    sources = contract.get("sources")
    expected_home = {
        "packages/runtime/src/jsc/JSGlobalObject.zig",
        "packages/runtime/upstream/src/jsc/bindings/ZigGlobalObject.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWasmStreamingCompiler.cpp",
        "packages/runtime/upstream/src/jsc/bindings/webcore/JSWasmStreamingCompiler.h",
    }
    if not isinstance(sources, dict) or set(sources) != {"home", "bun"}:
        fail("Wasm StreamingCompiler contract profile source set drift")
    home_sources = sources.get("home")
    bun_sources = sources.get("bun")
    if not isinstance(home_sources, dict) or set(home_sources) != expected_home or not isinstance(bun_sources, dict):
        fail("Wasm StreamingCompiler contract Home source set drift")
    for profile_sources in (home_sources, bun_sources):
        for relative, digest in profile_sources.items():
            if not isinstance(relative, str) or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                fail(f"invalid Wasm StreamingCompiler digest for {relative}")
    if home_root is not None:
        for relative, digest in home_sources.items():
            path = home_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"Wasm StreamingCompiler source drift for {relative}")
    if contract.get("exports") != ["JSC__Wasm__StreamingCompiler__addBytes"]:
        fail("Wasm StreamingCompiler export inventory drift")
    expected_extensions = {
        "ZJSWasmStreamingCompilerCreate",
        "ZJSWasmStreamingCompilerFinalize",
        "ZJSWasmStreamingCompilerRelease",
    }
    extensions = contract.get("extensions")
    if not isinstance(extensions, list) or set(extensions) != expected_extensions or not expected_extensions <= set(EXPORT_RE.findall(EXPORT_SOURCE.read_text())):
        fail("Wasm StreamingCompiler lifecycle extension inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 15 or len(semantics) != len(set(semantics)):
        fail("Wasm StreamingCompiler semantic inventory is incomplete or duplicated")


def validate_wasm_streaming_response_feed_contract() -> None:
    if not WASM_STREAMING_RESPONSE_FEED_CONTRACT.is_file():
        fail(f"missing checked-in Wasm Response feed contract {WASM_STREAMING_RESPONSE_FEED_CONTRACT}")
    contract = json.loads(WASM_STREAMING_RESPONSE_FEED_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "wasm-streaming-response-feed"
        or contract.get("issue") != 410
        or contract.get("parent_issue") != 406
        or contract.get("depends_on") != [407, 409]
        or contract.get("related_issue") != 408
        or contract.get("implementation") != ["src/interpreter.zig", "src/wasm/api.zig"]
    ):
        fail("Wasm Response feed contract schema or issue lineage drift")
    for relative in contract["implementation"]:
        if not (ROOT / relative).is_file():
            fail(f"missing Wasm Response feed implementation {relative}")
    expected_profiles = {
        "mvp",
        "fixed-width-simd",
        "threads",
        "exception-handling",
        "memory64",
        "gc/core-3",
    }
    profiles = contract.get("feature_profiles")
    if not isinstance(profiles, list) or set(profiles) != expected_profiles or len(profiles) != len(expected_profiles):
        fail("Wasm Response feed feature-profile inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 10 or len(semantics) != len(set(semantics)):
        fail("Wasm Response feed semantic inventory is incomplete or duplicated")


def validate_sql_object_structure_contract(
    home_root: Path | None = None,
    bun_root: Path | None = None,
) -> None:
    if not SQL_OBJECT_STRUCTURE_CONTRACT.is_file():
        fail(f"missing checked-in SQL object Structure contract {SQL_OBJECT_STRUCTURE_CONTRACT}")
    contract = json.loads(SQL_OBJECT_STRUCTURE_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "sql-object-structure"
        or contract.get("issue") != 411
        or contract.get("parent_issues") != [140, 163, 164]
        or contract.get("roadmap_issue") != 134
        or contract.get("revisions") != {
            "home": REVISION,
            "bun": "4982b91e3702094330f3be3883354c52b8c01323",
            "bun_webkit": "cd821fecca0d39c8bac874c283d956868c7f0de0",
        }
    ):
        fail("SQL object Structure contract schema, revisions, or issue lineage drift")
    sources = contract.get("sources")
    expected_sources = {
        "home_js_object",
        "bun_js_object",
        "bun_sql_client",
        "bun_webkit_js_object",
    }
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("SQL object Structure source inventory drift")
    for source in sources.values():
        if (
            not isinstance(source, dict)
            or set(source) != {"path", "sha256"}
            or not isinstance(source["path"], str)
            or not isinstance(source["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", source["sha256"]) is None
        ):
            fail("invalid SQL object Structure source contract")
    for root, key in ((home_root, "home_js_object"), (bun_root, "bun_js_object"), (bun_root, "bun_sql_client")):
        if root is None:
            continue
        source = sources[key]
        path = root / source["path"]
        if not path.is_file() or sha256(path) != source["sha256"]:
            fail(f"SQL object Structure source drift for {source['path']}")
    if contract.get("implementation") != ["src/c_api.zig", "src/value.zig"]:
        fail("SQL object Structure implementation inventory drift")
    fixtures = contract.get("fixtures")
    if not isinstance(fixtures, list) or fixtures != [
        "tests/abi/home_private_value_shims.zig",
        "tests/abi/bun_private_sql_structure.zig",
    ]:
        fail("SQL object Structure fixture inventory drift")
    for relative in (*contract["implementation"], *fixtures):
        if not isinstance(relative, str) or not (ROOT / relative).is_file():
            fail(f"missing SQL object Structure implementation evidence {relative}")
    expected_symbols = {
        "JSC__JSObject__maxInlineCapacity",
        "JSC__createStructure",
        "JSC__createEmptyObjectWithStructure",
        "JSC__putDirectOffset",
    }
    symbols = contract.get("symbols")
    source_text = EXPORT_SOURCE.read_text()
    if (
        not isinstance(symbols, list)
        or set(symbols) != expected_symbols
        or len(symbols) != len(expected_symbols)
        or not expected_symbols - {"JSC__JSObject__maxInlineCapacity"} <= set(EXPORT_RE.findall(source_text))
        or re.search(r"^export const JSC__JSObject__maxInlineCapacity\s*:", source_text, re.M) is None
    ):
        fail("SQL object Structure export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 8 or len(semantics) != len(set(semantics)):
        fail("SQL object Structure semantic inventory is incomplete or duplicated")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=(PROFILE_ID, *ALIAS_PROFILES), default=PROFILE_ID)
    parser.add_argument("--home-root", type=Path)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--refresh-implementation-status", action="store_true")
    args = parser.parse_args()
    if args.write and not args.home_root:
        fail("--write requires --home-root")
    if args.write and args.profile != PROFILE_ID:
        fail("the alias profile reuses the immutable base inventory and cannot be generated separately")
    if args.write and args.refresh_implementation_status:
        fail("--write and --refresh-implementation-status are mutually exclusive")

    if args.home_root and args.profile == PROFILE_ID:
        generated = generate(args.home_root.resolve())
        refresh_implementation_status(generated)
        if args.write:
            OUTPUT.write_text(json.dumps(generated, indent=2) + "\n")
        elif not OUTPUT.is_file() or generated != json.loads(OUTPUT.read_text()):
            fail("checked-in inventory differs from the pinned Home source; regenerate deliberately")
    if not OUTPUT.is_file():
        fail(f"missing checked-in inventory {OUTPUT}")
    stored = json.loads(OUTPUT.read_text())
    if args.refresh_implementation_status:
        refresh_implementation_status(stored)
        OUTPUT.write_text(json.dumps(stored, indent=2) + "\n")
    validate_stored(stored)
    validate_script_execution_context_contract(args.home_root.resolve() if args.home_root else None)
    validate_cpu_profile_contract(args.home_root.resolve() if args.home_root else None)
    validate_readable_stream_contract(args.home_root.resolve() if args.home_root else None)
    validate_fetch_body_contract(args.home_root.resolve() if args.home_root else None)
    validate_wasm_streaming_contract(args.home_root.resolve() if args.home_root else None)
    validate_wasm_streaming_compiler_contract(args.home_root.resolve() if args.home_root else None)
    validate_wasm_streaming_response_feed_contract()
    validate_sql_object_structure_contract(args.home_root.resolve() if args.home_root else None)
    if args.home_root and args.profile in ALIAS_PROFILES:
        verify_alias(args.home_root.resolve(), stored, args.profile)
    totals = stored["totals"]
    classes = totals["by_classification"]
    statuses = totals["by_status"]
    print(
        f"Home private ABI audit: {args.profile}: {totals['symbols']} symbols from {totals['source_files']} files; "
        f"private={classes.get('private_jsc', 0)}, public={classes.get('public_c_api', 0)}, "
        f"platform={classes.get('platform_import', 0)}, "
        f"consumer-provided={classes.get('consumer_provided', 0)}, "
        f"implemented-private={statuses.get('implemented', 0) - classes.get('public_c_api', 0)}, "
        f"pending-private={statuses.get('pending', 0)}, unclassified=0"
    )


if __name__ == "__main__":
    main()
