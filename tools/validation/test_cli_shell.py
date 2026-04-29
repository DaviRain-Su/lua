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

    def test_registered_build_and_check_commands_return_deterministic_json_route_metadata(self):
        for command in ("build", "check"):
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

    def test_test_command_emits_compatibility_ledger_with_native_accounting(self):
        completed = run(str(CLI), "test", "--suite", "cli-ledger", "--target", "native-full")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        self.assertEqual(completed.stderr, "")
        summary = json.loads(completed.stdout)
        self.assertEqual(summary["state"], "pass")
        self.assertEqual(summary["command"], "test")
        self.assertEqual(summary["selected_suite"], "cli-ledger")
        self.assertEqual(summary["target_profile"], "native-full")
        self.assertIn("fallback-pass", summary["states"])
        self.assertEqual(summary["accounting"]["native_pass_count"], 1)
        self.assertEqual(summary["accounting"]["fallback_pass_count"], 0)
        self.assertEqual(summary["ledger"][0]["implementation_mode"], "native")

    def test_profile_command_separates_compatibility_inspection_from_runtime_metrics(self):
        list_result = run(str(CLI), "profile", "list")
        self.assertEqual(list_result.returncode, 0, list_result.stderr + list_result.stdout)
        profiles = json.loads(list_result.stdout)
        self.assertEqual(profiles["mode"], "compatibility-inspection")
        self.assertEqual(
            [profile["profile"] for profile in profiles["profiles"]],
            ["native-full", "wasm-full", "sbf-experimental"],
        )

        show_result = run(str(CLI), "profile", "show", "wasm-full")
        self.assertEqual(show_result.returncode, 0, show_result.stderr + show_result.stdout)
        shown = json.loads(show_result.stdout)
        self.assertEqual(shown["mode"], "compatibility-inspection")
        self.assertEqual(shown["profile"], "wasm-full")

        metrics_result = run(str(CLI), "profile", "metrics")
        self.assertEqual(metrics_result.returncode, 0, metrics_result.stderr + metrics_result.stdout)
        metrics = json.loads(metrics_result.stdout)
        self.assertEqual(metrics["mode"], "runtime-metrics")
        self.assertIn("timing_ms", metrics["metrics"])

    def test_report_command_separates_fallback_and_unsupported_from_native_compatibility(self):
        completed = run(str(CLI), "report")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        self.assertEqual(completed.stderr, "")
        report = json.loads(completed.stdout)
        self.assertEqual(report["state"], "pass")
        self.assertEqual(report["ledger_format_version"], 1)
        self.assertIn("fallback-pass", report["states"])
        self.assertIn("capability-denied", report["states"])
        self.assertIn("expected-skip", report["states"])
        self.assertIn("blocked", report["states"])
        self.assertFalse(report["compatibility_policy"]["fallback_counts_as_native"])
        self.assertFalse(report["compatibility_policy"]["unsupported_counts_as_native"])
        self.assertEqual(
            report["accounting"]["native_implementation_compatibility_count"],
            report["accounting"]["native_pass_count"],
        )
        self.assertGreater(report["accounting"]["fallback_pass_count"], 0)
        self.assertTrue(any(entry["state"] == "fallback-pass" for entry in report["ledger"]))

    def test_capability_command_lists_profiles_and_rejects_unknown_capabilities(self):
        completed = run(str(CLI), "capability")
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        self.assertEqual(completed.stderr, "")
        matrix = json.loads(completed.stdout)
        self.assertEqual(matrix["state"], "pass")
        self.assertEqual(
            [profile["profile"] for profile in matrix["profiles"]],
            ["native-full", "wasm-full", "sbf-experimental"],
        )
        wasm = next(profile for profile in matrix["profiles"] if profile["profile"] == "wasm-full")
        self.assertEqual(wasm["capabilities"]["process"], "capability-denied")
        self.assertEqual(wasm["capabilities"]["stdin"], "shimmed")

        single = run(str(CLI), "capability", "--profile", "native-full", "--capability", "filesystem")
        self.assertEqual(single.returncode, 0, single.stderr + single.stdout)
        single_summary = json.loads(single.stdout)
        self.assertEqual(single_summary["support"], "native")

        rejected = run(str(CLI), "capability", "--profile", "native-full", "--capability", "telepathy")
        self.assertEqual(rejected.stdout, "")
        self.assertEqual(rejected.returncode, 2, rejected.stderr + rejected.stdout)
        diagnostic = json.loads(rejected.stderr)
        self.assertEqual(diagnostic["state"], "fail")
        self.assertEqual(diagnostic["kind"], "capability")

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
