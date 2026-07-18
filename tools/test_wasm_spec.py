#!/usr/bin/env python3
"""Structural regression tests for the live-WABT corpus driver."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


DRIVER = pathlib.Path(__file__).with_name("wasm-spec.py")
SPEC = importlib.util.spec_from_file_location("wasm_spec", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
wasm_spec = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = wasm_spec
SPEC.loader.exec_module(wasm_spec)


class WastParserTests(unittest.TestCase):
    def test_comments_strings_spans_and_lines(self) -> None:
        source = (
            ";; leading\n"
            '(module $M (func (export "(; not a comment ;)")))\n'
            "(; outer (; nested ;) comment ;)\n"
            "(wait $T)\n"
        )
        forms = wasm_spec.parse_wast_forms(source)
        self.assertEqual([form.head for form in forms], ["module", "wait"])
        self.assertEqual([form.line for form in forms], [2, 4])
        self.assertEqual(source[forms[0].start : forms[0].end], source.splitlines()[1])

    def test_thread_shared_modules_and_nested_body(self) -> None:
        source = (
            "(thread $outer\n"
            "  (shared (module $Mem))\n"
            "  (thread $inner (shared (module $Mem)) (wait $leaf))\n"
            "  (wait $inner))\n"
        )
        form = wasm_spec.parse_wast_forms(source)[0]
        name, shared, body = wasm_spec.thread_parts(form)
        self.assertEqual(name, "$outer")
        self.assertEqual(shared, ["$Mem"])
        self.assertEqual([item.head for item in body], ["thread", "wait"])

    def test_mask_keeps_only_converter_owned_forms_and_line_numbers(self) -> None:
        source = "(module $M)\n(thread $T (wait $X))\n(assert_return (invoke \"f\"))\n"
        masked = wasm_spec.masked_scope_source(source, wasm_spec.parse_wast_forms(source))
        self.assertEqual(masked.count("\n"), source.count("\n"))
        self.assertIn("(module $M)", masked)
        self.assertIn('(assert_return (invoke "f"))', masked)
        self.assertNotIn("thread", masked)

    def test_malformed_script_directives_are_rejected(self) -> None:
        with self.assertRaisesRegex(wasm_spec.WastSyntaxError, "unterminated block comment"):
            wasm_spec.parse_wast_forms("(; never closed")
        malformed = wasm_spec.parse_wast_forms("(thread $T (shared (module)))")[0]
        with self.assertRaisesRegex(wasm_spec.WastSyntaxError, "malformed shared module"):
            wasm_spec.thread_parts(malformed)


class ScriptGenerationTests(unittest.TestCase):
    def test_thread_wait_and_either_modes_are_explicit(self) -> None:
        directory = pathlib.Path(".")
        thread_js = wasm_spec.generate_command(0, {
            "type": "thread",
            "line": 3,
            "name": "$T",
            "shared": ["$Mem"],
            "document": {"commands": []},
        }, directory)
        wait_js = wasm_spec.generate_command(1, {
            "type": "wait", "line": 4, "name": "$T",
        }, directory)
        either_js = wasm_spec.generate_command(2, {
            "type": "assert_return",
            "line": 5,
            "action": {"type": "invoke", "field": "f"},
            "either": [
                {"type": "i32", "value": "0"},
                {"type": "i32", "value": "1"},
            ],
        }, directory)
        self.assertIn("proposal_thread", thread_js)
        self.assertIn('__modules["$Mem"]=__shared[0]', thread_js)
        self.assertIn("proposal_wait", wait_js)
        self.assertIn(".join()", wait_js)
        self.assertIn("||", either_js)


if __name__ == "__main__":
    unittest.main()
