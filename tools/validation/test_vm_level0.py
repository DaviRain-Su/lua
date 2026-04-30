import json
import importlib.util
import shlex
import subprocess
import sys
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "tools" / "validation" / "snippet_corpus.json"
VM_COMMAND = "./zig-out/bin/ziglua-vm"
BASELINE_ORACLE = REPO / "tools" / "validation" / "baseline_oracle.py"


def run(*command: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        cwd=REPO,
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
        candidate = run(VM_COMMAND, stdin='local x = "bad" + 1\nprint(x)\n')

        self.assertNotEqual(candidate.returncode, 0)
        self.assertEqual(candidate.stdout, "")
        self.assertIn("ziglua-vm:", candidate.stderr)
        self.assertIn("arithmetic", candidate.stderr)

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
