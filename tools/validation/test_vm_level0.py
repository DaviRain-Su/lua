import json
import importlib.util
import os
import shlex
import subprocess
import sys
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "tools" / "validation" / "snippet_corpus.json"
VM_COMMAND = "./zig-out/bin/ziglua-vm"
BASELINE_ORACLE = REPO / "tools" / "validation" / "baseline_oracle.py"


def run(*command: str, stdin: str | None = None, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    process_env = os.environ.copy()
    if env is not None:
        process_env.update(env)
    return subprocess.run(
        list(command),
        cwd=REPO,
        env=process_env,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def pass_snippets(level: int) -> list[dict[str, object]]:
    return [
        snippet
        for snippet in json.loads(CORPUS.read_text())
        if snippet["level"] == level and snippet["expected_state"] == "pass"
    ]


def advanced_semantics_fixtures() -> list[dict[str, object]]:
    spec = importlib.util.spec_from_file_location("baseline_oracle", BASELINE_ORACLE)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load baseline_oracle.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return list(module.ADVANCED_SEMANTICS_FIXTURES)


class VmLevel0Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        completed = run("zig", "build", "-Dprofile=native-full", "--summary", "all")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr + completed.stdout)

    def test_level0_corpus_matches_stock_lua(self):
        self.assertTrue((REPO / "zig-out" / "bin" / "ziglua-vm").exists())
        for snippet in pass_snippets(0):
            with self.subTest(snippet=snippet["name"]):
                stock = run("./lua", "-", stdin=str(snippet["source"]))
                candidate = run(VM_COMMAND, stdin=str(snippet["source"]))

                self.assertEqual(stock.returncode, 0, stock.stderr)
                self.assertEqual(candidate.returncode, 0, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertEqual(candidate.stderr, stock.stderr)

    def test_dynamic_feature_is_explicitly_unsupported(self):
        candidate = run(VM_COMMAND, stdin='load("print(1)")()\n')

        self.assertNotEqual(candidate.returncode, 0)
        self.assertEqual(candidate.stdout, "")
        self.assertIn("unsupported", candidate.stderr)
        self.assertIn("load", candidate.stderr)

    def test_advanced_semantics_fallback_passes_through_stock_lua_with_reason_marker(self):
        for fixture in advanced_semantics_fixtures():
            with self.subTest(fixture=fixture["name"]):
                source = str(fixture["source"])
                stock = run("./lua", "-", stdin=source)
                candidate = run(VM_COMMAND, stdin=source)

                self.assertEqual(stock.returncode, 0, stock.stderr)
                self.assertEqual(candidate.returncode, stock.returncode, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertIn("fallback", candidate.stderr)
                self.assertIn(str(fixture["reason"]), candidate.stderr)

    def test_level1_supported_corpus_matches_stock_lua_or_classifies_closures(self):
        closure_snippets = {
            "level1-closures",
            "level1-named-closure-escape",
            "level1-aliased-closure-escape",
            "level1-parenthesized-return-alias-closure-escape",
            "level1-parenthesized-local-alias-closure-escape",
            "level1-parenthesized-assignment-alias-closure-escape",
            "level1-multiname-local-closure-escape",
            "level1-multitarget-assignment-closure-escape",
            "level1-global-assignment-closure-escape",
            "level1-table-assignment-closure-escape",
        }
        for snippet in pass_snippets(1):
            with self.subTest(snippet=snippet["name"]):
                stock = run("./lua", "-", stdin=str(snippet["source"]))
                candidate = run(VM_COMMAND, stdin=str(snippet["source"]))

                self.assertEqual(stock.returncode, 0, stock.stderr)
                if snippet["name"] in closure_snippets:
                    self.assertNotEqual(candidate.returncode, 0)
                    self.assertEqual(candidate.stdout, "")
                    self.assertIn("unsupported", candidate.stderr)
                    self.assertIn("closure", candidate.stderr)
                    continue

                self.assertEqual(candidate.returncode, 0, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertEqual(candidate.stderr, stock.stderr)

    def test_supported_runtime_error_path_is_nonzero_and_diagnostic(self):
        candidate = run(VM_COMMAND, stdin="local x = nil + 1\nprint(x)\n")

        self.assertNotEqual(candidate.returncode, 0)
        self.assertEqual(candidate.stdout, "")
        self.assertIn("ziglua-vm:", candidate.stderr)
        self.assertIn("runtime-error:1", candidate.stderr)
        self.assertIn("arithmetic", candidate.stderr)
        self.assertIn("nil", candidate.stderr)

    def test_no_host_lua_core_diagnostics_match_stock_lua(self):
        cases = {
            "string-number-add": 'local x = "bad" + 1\nprint(x)\n',
            "nil-arithmetic": "local x = nil + 1\nprint(x)\n",
            "boolean-arithmetic": "local x = true + 1\nprint(x)\n",
            "table-concat": 'print({} .. "x")\n',
            "nil-index-local-line": "local x = nil\nprint(x.y)\n",
            "nil-call-local-line": "local f = nil\nf()\n",
            "missing-close-paren": "print(1\n",
            "unexpected-end": "end\n",
            "while-missing-end": "while true do print(1)\n",
            "if-missing-end": 'if true then print("x")\n',
        }
        for name, source in cases.items():
            with self.subTest(case=name):
                stock = run("./lua", "-", stdin=source)
                candidate = run(
                    "./zig-out/bin/lua-zig",
                    "run",
                    "-",
                    stdin=source,
                    env={"LUA_ZIG_RUN_NO_HOST_LUA": "1"},
                )

                self.assertNotEqual(stock.returncode, 0, name)
                self.assertEqual(candidate.returncode, stock.returncode, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertEqual(candidate.stderr, stock.stderr)

    def test_no_host_lua_goto_label_legality_matches_stock_lua(self):
        cases = {
            "undefined-label": "goto missing\n",
            "duplicate-label": "::a::\n::a::\n",
            "malformed-label": "::1::\n",
            "malformed-goto-label": "goto end\n",
            "jump-into-local-scope": "goto L\nlocal x\n::L::\nprint(1)\n",
            "nested-duplicate-visible-label": "::l1::\ndo\n  ::l1::\nend\n",
        }
        for name, source in cases.items():
            with self.subTest(case=name):
                stock = run("./lua", "-", stdin=source)
                candidate = run(
                    "./zig-out/bin/lua-zig",
                    "run",
                    "-",
                    stdin=source,
                    env={"LUA_ZIG_RUN_NO_HOST_LUA": "1"},
                )

                self.assertNotEqual(stock.returncode, 0, name)
                self.assertEqual(candidate.returncode, stock.returncode, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertEqual(candidate.stderr, stock.stderr)

    def test_no_host_lua_goto_end_of_block_scope_visibility_matches_stock_lua(self):
        cases = {
            "top-level-end-label-after-local": "goto L\nlocal x\n::L::\n",
            "nested-end-label-after-local": 'do\ngoto L\nlocal x\n::L::\nend\nprint("ok")\n',
            "end-label-after-local-and-empty-statements": "goto L\nlocal x\n; ; ::L:: ; ;\n",
        }
        for name, source in cases.items():
            with self.subTest(case=name):
                stock = run("./lua", "-", stdin=source)
                candidate = run(
                    "./zig-out/bin/lua-zig",
                    "run",
                    "-",
                    stdin=source,
                    env={"LUA_ZIG_RUN_NO_HOST_LUA": "1"},
                )

                self.assertEqual(stock.returncode, 0, name)
                self.assertEqual(candidate.returncode, stock.returncode, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertEqual(candidate.stderr, stock.stderr)

    def test_no_host_lua_generic_for_and_ordered_comparisons_match_stock_lua(self):
        cases = {
            "ipairs-generic-for": 'for i,v in ipairs({"a","b"}) do print(i,v) end\n',
            "pairs-array-generic-for": "local total = 0\nfor k,v in pairs({3,4,5}) do total = total + k + v end\nprint(total)\n",
            "ordered-number-and-string": 'print(1 < 2, 2.0 <= 2, 3 > 2.5, 3 >= 3)\nprint("2" < "10", "abc" <= "abc", "b" > "aa", "b" >= "b")\n',
            "mixed-string-number-rejected": 'print("2" < 10)\n',
            "mixed-number-string-rejected": 'print(2 < "10")\n',
            "unsupported-table-comparison-rejected": "print({} < {})\n",
        }
        for name, source in cases.items():
            with self.subTest(case=name):
                stock = run("./lua", "-", stdin=source)
                candidate = run(
                    "./zig-out/bin/lua-zig",
                    "run",
                    "-",
                    stdin=source,
                    env={"LUA_ZIG_RUN_NO_HOST_LUA": "1"},
                )

                self.assertEqual(candidate.returncode, stock.returncode, candidate.stderr)
                self.assertEqual(candidate.stdout, stock.stdout)
                self.assertEqual(candidate.stderr, stock.stderr)

    def test_baseline_oracle_vm_level0_corpus_command_reports_pass(self):
        completed = run(
            "python3",
            "tools/validation/baseline_oracle.py",
            "--repo",
            str(REPO),
            "vm-level0-corpus",
            "--candidate-command",
            VM_COMMAND,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        summary = json.loads(completed.stdout)
        self.assertEqual(summary["state"], "pass")
        self.assertGreaterEqual(summary["snippet_count"], 7)
        self.assertEqual(summary["candidate_command"], shlex.split(VM_COMMAND))

    def test_native_core_language_validator_reports_no_fallback_or_unsupported(self):
        completed = run(
            "python3",
            "tools/validation/baseline_oracle.py",
            "--repo",
            str(REPO),
            "native-core-language",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        summary = json.loads(completed.stdout)
        self.assertEqual(summary["state"], "pass")
        self.assertEqual(summary["fallback_count"], 0)
        self.assertEqual(summary["unsupported_count"], 0)
        self.assertEqual(summary["missing_assertions"], [])
        self.assertEqual(
            summary["validated_assertions"],
            [
                "VAL-NATIVE-004",
                "VAL-NATIVE-005",
                "VAL-NATIVE-006",
                "VAL-NATIVE-007",
                "VAL-NATIVE-008",
                "VAL-NATIVE-009",
                "VAL-NATIVE-010",
            ],
        )


if __name__ == "__main__":
    unittest.main()
