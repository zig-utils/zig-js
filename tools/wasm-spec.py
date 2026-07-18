#!/usr/bin/env python3
"""Run and inventory pinned upstream WebAssembly specification corpora."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SPEC_COMMIT = "977f97014c962f7bd1291fcc6d28b41a924882bf"
WABT_VERSION = "1.0.12"
WABT_COMMIT = "cf261f2bd561297e0da7008ddde8c09ba5ea35a2"

PROFILES = {
    "mvp": {
        "kind": "webassembly_wg_1_0_core_inventory",
        "repository": "https://github.com/WebAssembly/spec.git",
        "tag": "wg-1.0",
        "commit": SPEC_COMMIT,
        "wabt_version": WABT_VERSION,
        "wabt_commit": WABT_COMMIT,
        "evaluator_profile": None,
        "features": [],
        "corpus_glob": "test/core/*.wast",
    },
    "core-2-structural": {
        "kind": "webassembly_core_2_0_structural_inventory",
        "repository": "https://github.com/WebAssembly/spec.git",
        "tag": "wg-2.0",
        "commit": "fffc6e12fa454e475455a7b58d3b5dc343980c10",
        "wabt_version": "1.0.39",
        "wabt_commit": "ad75c5edcdff96d73c245b57fbc07607aaca9f95",
        "evaluator_profile": "core-2-structural",
        "features": [
            "sign_extension_ops",
            "nontrapping_float_to_int",
            "multi_value",
            "reference_types",
            "bulk_memory",
        ],
        "corpus_glob": "test/core/*.wast",
    },
    "simd-movement": {
        "kind": "webassembly_fixed_width_simd_movement_inventory",
        "repository": "https://github.com/WebAssembly/simd.git",
        "tag": "proposal-revision",
        "commit": "a78b98a6899c9e91a13095e560767af6e99d98fd",
        "wabt_version": "1.0.39",
        "wabt_commit": "ad75c5edcdff96d73c245b57fbc07607aaca9f95",
        "evaluator_profile": "simd",
        "features": [
            "sign_extension_ops",
            "nontrapping_float_to_int",
            "multi_value",
            "reference_types",
            "bulk_memory",
            "fixed_width_simd",
        ],
        "corpus_glob": "test/core/simd/*.wast",
        "default_files": [
            "simd_address.wast",
            "simd_align.wast",
            "simd_bitwise.wast",
            "simd_boolean.wast",
            "simd_const.wast",
            "simd_lane.wast",
            "simd_load.wast",
            "simd_load8_lane.wast",
            "simd_load16_lane.wast",
            "simd_load32_lane.wast",
            "simd_load64_lane.wast",
            "simd_load_extend.wast",
            "simd_load_splat.wast",
            "simd_load_zero.wast",
            "simd_splat.wast",
            "simd_store.wast",
            "simd_store8_lane.wast",
            "simd_store16_lane.wast",
            "simd_store32_lane.wast",
            "simd_store64_lane.wast",
        ],
    },
    "simd": {
        "kind": "webassembly_fixed_width_simd_inventory",
        "repository": "https://github.com/WebAssembly/simd.git",
        "tag": "proposal-revision",
        "commit": "a78b98a6899c9e91a13095e560767af6e99d98fd",
        "wabt_version": "1.0.39",
        "wabt_commit": "ad75c5edcdff96d73c245b57fbc07607aaca9f95",
        "evaluator_profile": "simd",
        "features": [
            "sign_extension_ops",
            "nontrapping_float_to_int",
            "multi_value",
            "reference_types",
            "bulk_memory",
            "fixed_width_simd",
        ],
        "corpus_glob": "test/core/simd/*.wast",
    },
    "threads": {
        "kind": "webassembly_threads_inventory",
        "repository": "https://github.com/WebAssembly/threads.git",
        "tag": "proposal-revision",
        "commit": "979d0fcb994439423d63b2f0a8a7332d6285dd84",
        "wabt_version": "1.0.39",
        "wabt_commit": "ad75c5edcdff96d73c245b57fbc07607aaca9f95",
        "evaluator_profile": "threads",
        "features": ["threads"],
        "corpus_glob": "test/core/threads/*.wast",
        "converter_args": ["--enable-threads"],
    },
}


def fail(message: str) -> None:
    print(f"wasm-spec: {message}", file=sys.stderr)
    raise SystemExit(2)


def checked_output(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        fail(f"command failed: {' '.join(command)}\n{result.stderr.strip()}")
    return result.stdout.strip()


def verify_tools(spec_root: Path, converter: Path, engine: Path, profile: dict) -> None:
    corpus_root = spec_root / Path(profile["corpus_glob"]).parent
    if not corpus_root.is_dir():
        fail(f"missing corpus at {spec_root}; run `git submodule update --init wasm-spec`")
    actual_spec = checked_output(["git", "rev-parse", "HEAD"], spec_root)
    if actual_spec != profile["commit"]:
        fail(f"wasm-spec pin drift: expected {profile['commit']}, found {actual_spec}")
    if not converter.is_file():
        fail(
            f"missing wast2json at {converter}; build WABT {profile['wabt_version']} "
            f"({profile['wabt_commit']}) and pass --wast2json"
        )
    if profile["wabt_version"] != WABT_VERSION:
        version = checked_output([str(converter), "--version"])
        if version != profile["wabt_version"]:
            fail(
                f"wast2json version drift: expected {profile['wabt_version']} "
                f"({profile['wabt_commit']}), found {version}"
            )
        if not engine.is_file():
            fail(f"missing evaluator at {engine}; run `zig build wasm-spec-eval`")
        return
    # WABT 1.0.12 predates `--version`. Probe the two syntax boundaries that
    # distinguish it from converters too old for final `local.get` spelling and
    # newer converters that removed wg-1.0's NaN assertion commands.
    with tempfile.TemporaryDirectory(prefix="zig-js-wabt-probe-") as raw_probe:
        probe = Path(raw_probe)
        source = probe / "probe.wast"
        source.write_text(
            "(module (func (export \"f\") (param i32) (result i32) (local.get 0)))\n"
            "(assert_return (invoke \"f\" (i32.const 1)) (i32.const 1))\n"
            "(module (func (export \"n\") (result f32) (f32.const nan)))\n"
            "(assert_return_canonical_nan (invoke \"n\"))\n"
        )
        converted = subprocess.run(
            [str(converter), str(source), "-o", str(probe / "probe.json")],
            text=True,
            capture_output=True,
        )
        if converted.returncode != 0:
            fail(
                f"wast2json is not compatible with pinned WABT {WABT_VERSION} "
                f"({WABT_COMMIT}): {converted.stderr.strip()}"
            )
    if not engine.is_file():
        fail(f"missing evaluator at {engine}; run `zig build wasm-spec-eval`")


def js_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def binary_expression(path: Path) -> str:
    data = path.read_bytes()
    return "new Uint8Array([" + ",".join(str(byte) for byte in data) + "])"


def instance_expression(action: dict) -> str:
    name = action.get("module")
    return f"__modules[{js_string(name)}]" if name is not None else "__last"


def value_expression(value: dict) -> str:
    kind = value["type"]
    raw = js_string(value["value"])
    if kind == "i32":
        return f"(Number({raw}) | 0)"
    if kind == "i64":
        return f"BigInt.asIntN(64, BigInt({raw}))"
    if kind == "f32":
        if value["value"].startswith("nan:"):
            return "NaN"
        return f"__f32({raw})"
    if kind == "f64":
        if value["value"].startswith("nan:"):
            return "NaN"
        return f"__f64({raw})"
    if kind == "externref":
        return f"__externref({raw})"
    if kind == "funcref" and value["value"] == "null":
        return "null"
    raise ValueError(f"unknown value type {kind}")


def raw_value_bits(value: dict) -> str:
    kind = value["type"]
    if kind != "v128":
        return str(value["value"])
    widths = {"i8": 8, "i16": 16, "i32": 32, "i64": 64, "f32": 32, "f64": 64}
    lane_type = value.get("lane_type")
    if lane_type not in widths:
        raise ValueError(f"unknown v128 lane type {lane_type}")
    width = widths[lane_type]
    mask = (1 << width) - 1
    lanes = value.get("value")
    if not isinstance(lanes, list) or len(lanes) * width != 128:
        raise ValueError(f"invalid v128 {lane_type} lane count")
    bits = sum((int(lane, 0) & mask) << (index * width) for index, lane in enumerate(lanes))
    return str(bits)


def action_expression(action: dict) -> str:
    instance = instance_expression(action)
    field = js_string(action["field"])
    if action["type"] == "get":
        return f"__get({instance}, {field})"
    if action["type"] == "invoke":
        args = ",".join(value_expression(value) for value in action.get("args", []))
        return f"{instance}.exports[{field}]({args})"
    raise ValueError(f"unknown action type {action['type']}")


def raw_action_expression(action: dict) -> str:
    instance = instance_expression(action)
    target = f"{instance}.exports[{js_string(action['field'])}]"
    if action["type"] == "get":
        return f"__wasmSpecInvokeBits({target})"
    if action["type"] == "invoke":
        args = "".join(
            f",{js_string(raw_value_bits(value))}" for value in action.get("args", [])
        )
        return f"__wasmSpecInvokeBits({target}{args})"
    raise ValueError(f"unknown raw action type {action['type']}")


def is_nan_bits(value: dict) -> bool:
    kind = value.get("type")
    if kind not in ("f32", "f64"):
        return False
    literal = value.get("value", "0")
    if not isinstance(literal, str) or literal.startswith("nan:"):
        return False
    raw = int(literal, 0)
    if kind == "f32":
        return raw & 0x7F800000 == 0x7F800000 and raw & 0x007FFFFF != 0
    if kind == "f64":
        return (
            raw & 0x7FF0000000000000 == 0x7FF0000000000000
            and raw & 0x000FFFFFFFFFFFFF != 0
        )
    return False


def requires_bit_exact_nan(command: dict) -> bool:
    expected = command.get("expected", [])
    if any(str(value.get("value", "")).startswith("nan:") for value in expected):
        return False
    values = expected + command.get("action", {}).get("args", [])
    return any(is_nan_bits(value) for value in values)


def requires_vector_bits(command: dict) -> bool:
    values = command.get("expected", []) + command.get("action", {}).get("args", [])
    return any(value.get("type") == "v128" for value in values)


PRELUDE = r"""
const __report = { commands: [] };
const __modules = Object.create(null);
const __registry = Object.create(null);
let __last = null;
const __scratch = new ArrayBuffer(8);
const __externrefs = new Map();
const __view = new DataView(__scratch);
function __f32(bits) { __view.setUint32(0, Number(bits), true); return __view.getFloat32(0, true); }
function __f64(bits) { __view.setBigUint64(0, BigInt(bits), true); return __view.getFloat64(0, true); }
function __f32bits(value) { __view.setFloat32(0, value, true); return __view.getUint32(0, true); }
function __f64bits(value) { __view.setFloat64(0, value, true); return __view.getBigUint64(0, true); }
function __externref(value) {
  if (value === 'null') return null;
  if (!__externrefs.has(value)) __externrefs.set(value, { specExternref: value });
  return __externrefs.get(value);
}
function __record(index, line, type, status, detail, mode) {
  const entry = { index, line, type, status, mode: mode || 'javascript_api' };
  if (detail) entry.detail = detail;
  __report.commands.push(entry);
}
function __message(error) {
  try { return String(error); } catch (_) { return '<unprintable>'; }
}
function __get(instance, field) {
  const value = instance.exports[field];
  return value instanceof WebAssembly.Global ? value.value : value;
}
function __sameOne(actual, item) {
  if (item.type === 'i32') return (actual | 0) === (Number(item.value) | 0);
  if (item.type === 'i64') return actual === BigInt.asIntN(64, BigInt(item.value));
  if (item.type === 'f32') return item.value.startsWith('nan:') ? Number.isNaN(actual) : __f32bits(actual) === Number(item.value);
  if (item.type === 'f64') return item.value.startsWith('nan:') ? Number.isNaN(actual) : __f64bits(actual) === BigInt(item.value);
  if (item.type === 'externref') return actual === __externref(item.value);
  if (item.type === 'funcref' && item.value === 'null') return actual === null;
  return false;
}
function __same(actual, expected) {
  if (expected.length === 0) return actual === undefined;
  const values = expected.length === 1 ? [actual] : actual;
  if (!Array.isArray(values) || values.length !== expected.length) return false;
  for (let i = 0; i < expected.length; i++) if (!__sameOne(values[i], expected[i])) return false;
  return true;
}
function __sameV128Bits(actual, laneType, expected) {
  const widths = { i8: 8n, i16: 16n, i32: 32n, i64: 64n, f32: 32n, f64: 64n };
  const width = widths[laneType];
  if (!width) return false;
  let bits;
  try { bits = BigInt(actual); } catch (_) { return false; }
  const mask = (1n << width) - 1n;
  for (let index = 0; index < expected.length; index++) {
    const lane = (bits >> (BigInt(index) * width)) & mask;
    const value = expected[index];
    if (value === 'nan:canonical') {
      const magnitude = lane & (laneType === 'f32' ? 0x7fffffffn : 0x7fffffffffffffffn);
      const canonical = laneType === 'f32' ? 0x7fc00000n : 0x7ff8000000000000n;
      if (magnitude !== canonical) return false;
    } else if (value === 'nan:arithmetic') {
      const quietMask = laneType === 'f32' ? 0x7fc00000n : 0x7ff8000000000000n;
      if ((lane & quietMask) !== quietMask) return false;
    } else if (lane !== (BigInt(value) & mask)) {
      return false;
    }
  }
  return true;
}
__registry.spectest = {
  print() {}, print_i32() {}, print_i64() {}, print_f32() {}, print_f64() {},
  print_i32_f32() {}, print_f64_f64() {},
  global_i32: 666,
  global_i64: 666n,
  global_f32: 666.6,
  global_f64: 666.6,
  table: new WebAssembly.Table({ initial: 10, maximum: 20, element: 'anyfunc' }),
  memory: new WebAssembly.Memory({ initial: 1, maximum: 2 }),
};
"""


def record_line(
    index: int,
    command: dict,
    status: str,
    detail: str = "",
    mode: str = "javascript_api",
) -> str:
    return (
        f"__record({index},{int(command.get('line', 0))},"
        f"{js_string(command['type'])},{js_string(status)},{js_string(detail)},"
        f"{js_string(mode)});"
    )


def expected_exception(
    index: int,
    command: dict,
    expression: str,
    exception_name: str,
) -> str:
    passed = record_line(index, command, "pass")
    missing = record_line(index, command, "fail", f"expected {exception_name}")
    wrong_prefix = (
        f"__record({index},{int(command.get('line', 0))},{js_string(command['type'])},"
        f"'fail','expected {exception_name}, got ' + __message(__error));"
    )
    return (
        "{let __threw=false;try{" + expression + ";}catch(__error){__threw=true;"
        f"if(__error instanceof {exception_name}){{{passed}}}else{{{wrong_prefix}}}"
        f"}}if(!__threw){{{missing}}}}}"
    )


def generate_command(index: int, command: dict, directory: Path) -> str:
    kind = command["type"]
    try:
        if kind == "module":
            binary = binary_expression(directory / command["filename"])
            name = command.get("name")
            assign_name = f"__modules[{js_string(name)}]=__last;" if name is not None else ""
            passed = record_line(index, command, "pass")
            failed = (
                f"__record({index},{int(command.get('line', 0))},{js_string(kind)},"
                "'fail',__message(__error));"
            )
            return (
                f"{{try{{__last=new WebAssembly.Instance(new WebAssembly.Module({binary}),__registry);"
                f"{assign_name}{passed}}}catch(__error){{{failed}}}}}"
            )
        if kind == "register":
            source = (
                f"__modules[{js_string(command['name'])}]"
                if command.get("name") is not None
                else "__last"
            )
            return (
                f"{{try{{__registry[{js_string(command['as'])}]={source}.exports;"
                f"{record_line(index, command, 'pass')}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind == "action":
            expression = action_expression(command["action"])
            return (
                f"{{try{{{expression};{record_line(index, command, 'pass')}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind == "assert_return":
            if requires_vector_bits(command):
                expected = command.get("expected", [])
                expression = raw_action_expression(command["action"])
                vector_nan_policy = any(
                    value.get("type") == "v128" and any(
                        str(lane).startswith("nan:") for lane in value.get("value", [])
                    )
                    for value in expected
                )
                vector_mode = "vector_nan_policy" if vector_nan_policy else "vector_bits"
                if len(expected) == 0:
                    comparison = "__actual===undefined"
                elif len(expected) == 1 and expected[0].get("type") == "v128" and any(
                    str(lane).startswith("nan:") for lane in expected[0].get("value", [])
                ):
                    comparison = (
                        f"__sameV128Bits(__actual,{js_string(expected[0]['lane_type'])},"
                        f"{json.dumps(expected[0]['value'], separators=(',', ':'))})"
                    )
                elif len(expected) == 1:
                    comparison = f"__actual==={js_string(raw_value_bits(expected[0]))}"
                else:
                    expected_bits = [raw_value_bits(value) for value in expected]
                    comparison = f"JSON.stringify(__actual)==={js_string(json.dumps(expected_bits, separators=(',', ':')))}"
                return (
                    f"{{try{{const __actual={expression};if({comparison}){{"
                    f"{record_line(index, command, 'pass', mode=vector_mode)}"
                    f"}}else{{{record_line(index, command, 'fail', 'raw vector result mismatch', vector_mode)}}}"
                    f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                    f"{js_string(kind)},'fail',__message(__error),{js_string(vector_mode)});}}}}"
                )
            if requires_bit_exact_nan(command):
                expected = command.get("expected", [])
                if len(expected) != 1:
                    return record_line(
                        index,
                        command,
                        "runner_error",
                        "bit-exact MVP assertion must have one result",
                        "bit_exact",
                    )
                expression = raw_action_expression(command["action"])
                expected_bits = js_string(expected[0]["value"])
                return (
                    f"{{try{{const __actual={expression};if(__actual==={expected_bits}){{"
                    f"{record_line(index, command, 'pass', mode='bit_exact')}"
                    f"}}else{{{record_line(index, command, 'fail', 'raw result mismatch', 'bit_exact')}}}"
                    f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                    f"{js_string(kind)},'fail',__message(__error),'bit_exact');}}}}"
                )
            expression = action_expression(command["action"])
            expected = json.dumps(command.get("expected", []), separators=(",", ":"))
            return (
                f"{{try{{const __actual={expression};if(__same(__actual,{expected})){{"
                f"{record_line(index, command, 'pass')}"
                f"}}else{{{record_line(index, command, 'fail', 'result mismatch')}}}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind in ("assert_return_canonical_nan", "assert_return_arithmetic_nan"):
            expression = action_expression(command["action"])
            return (
                f"{{try{{const __actual={expression};if(Number.isNaN(__actual)){{"
                f"{record_line(index, command, 'pass')}"
                f"}}else{{{record_line(index, command, 'fail', 'expected NaN')}}}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind in ("assert_trap", "assert_exhaustion"):
            action = raw_action_expression(command["action"]) if requires_vector_bits(command) else action_expression(command["action"])
            return expected_exception(
                index,
                command,
                action,
                "WebAssembly.RuntimeError",
            )
        if kind in ("assert_malformed", "assert_invalid"):
            if command.get("module_type") == "text":
                return record_line(
                    index,
                    command,
                    "not_applicable",
                    "text-format syntax is not exposed by the JavaScript binary API",
                    "not_applicable",
                )
            binary = binary_expression(directory / command["filename"])
            return expected_exception(
                index,
                command,
                f"new WebAssembly.Module({binary})",
                "WebAssembly.CompileError",
            )
        if kind == "assert_unlinkable":
            binary = binary_expression(directory / command["filename"])
            expression = (
                f"new WebAssembly.Instance(new WebAssembly.Module({binary}),__registry)"
            )
            return expected_exception(index, command, expression, "WebAssembly.LinkError")
        if kind == "assert_uninstantiable":
            binary = binary_expression(directory / command["filename"])
            expression = (
                f"new WebAssembly.Instance(new WebAssembly.Module({binary}),__registry)"
            )
            return expected_exception(index, command, expression, "WebAssembly.RuntimeError")
    except (KeyError, ValueError) as error:
        return record_line(index, command, "runner_error", str(error))
    return record_line(index, command, "runner_error", "unsupported command kind")


def generate_script(document: dict, directory: Path) -> str:
    lines = [PRELUDE]
    for index, command in enumerate(document["commands"]):
        lines.append(generate_command(index, command, directory))
    lines.append("JSON.stringify(__report);")
    return "\n".join(lines)


def run_file(
    wast: Path,
    converter: Path,
    engine: Path,
    work_root: Path,
    timeout: float,
    spec_root: Path,
    evaluator_profile: str | None,
    converter_args: list[str],
) -> dict:
    stem = wast.stem
    directory = work_root / stem
    directory.mkdir()
    json_path = directory / f"{stem}.json"
    converted = subprocess.run(
        [str(converter), *converter_args, str(wast), "-o", str(json_path)],
        text=True,
        capture_output=True,
    )
    if converted.returncode != 0:
        detail = converted.stderr.strip()
        return {
            "path": wast.relative_to(spec_root).as_posix(),
            "status": "conversion_failed",
            "detail": detail,
            "commands": [{
                "index": 0,
                "line": 0,
                "type": "conversion",
                "status": "runner_error",
                "detail": detail,
            }],
        }
    document = json.loads(json_path.read_text())
    script_path = directory / f"{stem}.js"
    script_path.write_text(generate_script(document, directory))
    try:
        env = os.environ.copy()
        if evaluator_profile:
            env["WASM_SPEC_PROFILE"] = evaluator_profile
        evaluated = subprocess.run(
            [str(engine), str(script_path)],
            text=True,
            capture_output=True,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        commands = [
            {
                "index": index,
                "line": command.get("line", 0),
                "type": command["type"],
                "status": "runner_error",
                "detail": "engine timeout",
            }
            for index, command in enumerate(document["commands"])
        ]
        return {"path": wast.relative_to(spec_root).as_posix(), "commands": commands}
    if evaluated.returncode != 0:
        detail = evaluated.stderr.strip() or f"engine exited {evaluated.returncode}"
        commands = [
            {
                "index": index,
                "line": command.get("line", 0),
                "type": command["type"],
                "status": "runner_error",
                "detail": detail,
            }
            for index, command in enumerate(document["commands"])
        ]
        return {"path": wast.relative_to(spec_root).as_posix(), "commands": commands}
    try:
        report = json.loads(evaluated.stdout)
    except json.JSONDecodeError as error:
        commands = [
            {
                "index": index,
                "line": command.get("line", 0),
                "type": command["type"],
                "status": "runner_error",
                "detail": f"invalid evaluator JSON: {error}",
            }
            for index, command in enumerate(document["commands"])
        ]
        return {"path": wast.relative_to(spec_root).as_posix(), "commands": commands}
    return {"path": wast.relative_to(spec_root).as_posix(), "commands": report["commands"]}


def counts(commands: list[dict]) -> dict[str, int]:
    result = {key: 0 for key in ("pass", "fail", "not_applicable", "runner_error")}
    for command in commands:
        result[command["status"]] = result.get(command["status"], 0) + 1
    result["total"] = len(commands)
    return result


def feature_area(profile_name: str, filename: str) -> str:
    if profile_name == "mvp":
        return "mvp"
    if profile_name == "simd-movement":
        return "fixed_width_simd_movement"
    if profile_name == "simd":
        return "fixed_width_simd"
    if profile_name == "threads":
        return "threads"
    stem = Path(filename).stem
    if stem in {
        "bulk", "memory_copy", "memory_fill", "memory_init", "table_copy", "table_init",
    }:
        return "bulk_memory"
    if stem in {
        "ref_func", "ref_is_null", "ref_null", "table-sub", "table_fill", "table_get",
        "table_grow", "table_set", "table_size",
    }:
        return "reference_types"
    if stem in {
        "block", "br", "br_if", "br_table", "call", "call_indirect", "func", "if",
        "loop", "return", "select", "type",
    }:
        return "multi_value_control"
    if stem == "conversions":
        return "numeric_extensions"
    return "shared_core"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="mvp")
    parser.add_argument("--spec-root", type=Path)
    parser.add_argument(
        "--wast2json",
        type=Path,
        default=Path(os.environ.get("WAST2JSON", shutil.which("wast2json") or "wast2json")),
    )
    parser.add_argument("--engine", type=Path, default=ROOT / "zig-out/bin/wasm-spec-eval")
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--filter", help="run only corpus paths containing this text")
    parser.add_argument(
        "--timeout",
        type=float,
        help="per-file evaluator timeout (default: 600s for Core 2 structural, 120s otherwise)",
    )
    parser.add_argument("--keep-work", type=Path)
    parser.add_argument("--allow-failures", action="store_true")
    args = parser.parse_args()

    profile = PROFILES[args.profile]
    timeout = args.timeout if args.timeout is not None else (
        600.0 if args.profile == "core-2-structural" else 120.0
    )
    spec_root = (args.spec_root or ROOT / "wasm-spec").resolve()
    converter = args.wast2json.resolve()
    engine = args.engine.resolve()
    default_inventories = {
        "mvp": ROOT / "docs/.data/wasm-spec-inventory.json",
        "core-2-structural": ROOT / "docs/.data/wasm-core-2-structural-inventory.json",
        "simd-movement": ROOT / "docs/.data/wasm-simd-movement-inventory.json",
        "simd": ROOT / "docs/.data/wasm-simd-inventory.json",
        "threads": ROOT / "docs/.data/wasm-threads-inventory.json",
    }
    inventory_path = args.inventory or default_inventories[args.profile]
    verify_tools(spec_root, converter, engine, profile)
    all_wast = sorted(spec_root.glob(profile["corpus_glob"]))
    if args.filter:
        selected = [path for path in all_wast if args.filter in path.as_posix()]
    elif profile.get("default_files"):
        selected_names = set(profile["default_files"])
        selected = [path for path in all_wast if path.name in selected_names]
        missing = selected_names - {path.name for path in selected}
        if missing:
            fail(f"pinned profile files missing: {sorted(missing)}")
    else:
        selected = all_wast
    if not selected:
        fail("no corpus files selected")

    temporary = None
    if args.keep_work:
        work_root = args.keep_work.resolve()
        work_root.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="zig-js-wasm-spec-")
        work_root = Path(temporary.name)

    files = []
    for number, wast in enumerate(selected, 1):
        entry = run_file(
            wast,
            converter,
            engine,
            work_root,
            timeout,
            spec_root,
            profile["evaluator_profile"],
            profile.get("converter_args", []),
        )
        area = feature_area(args.profile, wast.name)
        entry["feature_area"] = area
        for command in entry["commands"]:
            command.setdefault("mode", "javascript_api")
            command["feature_area"] = area
        entry["counts"] = counts(entry["commands"])
        files.append(entry)
        print(
            f"[{number:02d}/{len(selected):02d}] {wast.name}: "
            f"{entry['counts']['pass']} pass, {entry['counts']['fail']} fail, "
            f"{entry['counts']['not_applicable']} n/a, "
            f"{entry['counts']['runner_error']} runner"
        )

    all_commands = [command for entry in files for command in entry["commands"]]
    totals = counts(all_commands)
    totals_by_feature_area = {
        area: counts([command for command in all_commands if command["feature_area"] == area])
        for area in sorted({command["feature_area"] for command in all_commands})
    }
    engine_commit = checked_output(["git", "rev-parse", "HEAD"], ROOT)
    inventory = {
        "schema_version": 2,
        "kind": profile["kind"],
        "profile": args.profile,
        "features": profile["features"],
        "spec": {
            "repository": profile["repository"],
            "tag": profile["tag"],
            "commit": profile["commit"],
            "license": "Apache-2.0",
            "suite": profile["corpus_glob"],
            "files_available": len(all_wast),
            "files_scored": len(selected),
        },
        "converter": {
            "repository": "https://github.com/WebAssembly/wabt.git",
            "version": profile["wabt_version"],
            "commit": profile["wabt_commit"],
        },
        "engine_commit": engine_commit,
        "totals": totals,
        "totals_by_feature_area": totals_by_feature_area,
        "files": files,
    }
    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    inventory_path.write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
    print(
        f"TOTAL: {totals['pass']}/{totals['total']} pass, "
        f"{totals['fail']} fail, {totals['not_applicable']} n/a, "
        f"{totals['runner_error']} runner; inventory={inventory_path}"
    )
    if temporary is not None:
        temporary.cleanup()
    if args.allow_failures:
        return 0
    return 1 if totals["fail"] or totals["runner_error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
