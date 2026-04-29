import json
import subprocess
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "zig-out" / "bin" / "lua-zig"


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


class LuaZigCliShellTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        completed = run("zig", "build", "-Dprofile=native-full", "--summary", "all")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr + completed.stdout)

    def test_help_and_version_identify_registered_product_commands(self):
        self.assertTrue(CLI.exists(), "native-full build should install zig-out/bin/lua-zig")

        help_result = run(str(CLI), "--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr + help_result.stdout)
        self.assertEqual(help_result.stderr, "")
        self.assertIn("Usage: lua-zig <command>", help_result.stdout)
        for command in ("run", "build", "test", "check", "profile", "report", "capability"):
            with self.subTest(command=command):
                self.assertIn(command, help_result.stdout)

        version_result = run(str(CLI), "--version")
        self.assertEqual(version_result.returncode, 0, version_result.stderr + version_result.stdout)
        self.assertEqual(version_result.stderr, "")
        self.assertRegex(version_result.stdout, r"^lua-zig 0\.1\.0 zig=0\.16\.0 profile=native-full\n$")

    def test_registered_non_run_commands_return_deterministic_json_route_metadata(self):
        for command in ("build", "test", "check", "profile", "report", "capability"):
            with self.subTest(command=command):
                completed = run(str(CLI), command)

                self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
                self.assertEqual(completed.stderr, "")
                summary = json.loads(completed.stdout)
                self.assertEqual(summary["state"], "pending")
                self.assertEqual(summary["command"], command)
                self.assertEqual(summary["cli"], "lua-zig")
                self.assertEqual(summary["profile"], "native-full")
                self.assertIn("registered", summary["message"])

    def test_run_stdin_routes_to_existing_vm_without_breaking_legacy_binaries(self):
        self.assertTrue((REPO / "zig-out" / "bin" / "ziglua-vm").exists())
        self.assertTrue((REPO / "zig-out" / "bin" / "ziglua-aot").exists())

        completed = run(str(CLI), "run", "-", stdin="print(21 + 21)\n")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        self.assertEqual(completed.stdout, "42\n")
        self.assertEqual(completed.stderr, "")

    def test_unknown_command_fails_with_machine_checkable_diagnostic(self):
        completed = run(str(CLI), "not-a-command")

        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.returncode, 2, completed.stderr + completed.stdout)
        diagnostic = json.loads(completed.stderr)
        self.assertEqual(diagnostic["state"], "fail")
        self.assertEqual(diagnostic["command"], "unknown")
        self.assertEqual(diagnostic["cli"], "lua-zig")


if __name__ == "__main__":
    unittest.main()
