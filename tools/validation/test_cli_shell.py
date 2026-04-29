import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "zig-out" / "bin" / "lua-zig"


def run(
    *command: str,
    stdin: str | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    child_env = os.environ.copy()
    child_env.update(env or {})
    return subprocess.run(
        list(command),
        cwd=REPO,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=child_env,
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
        self.assertIn("command_id", summary["ledger"][0])
        self.assertIn("timestamp_unix_ms", summary["ledger"][0])
        self.assertIn("source_sha256", summary["ledger"][0]["fixture"])

    def test_test_command_runs_explicit_fixtures_and_classifies_target_coverage(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            pass_fixture = temp_path / "pass.lua"
            pass_fixture.write_text("print(21 + 21)\n")
            fail_fixture = temp_path / "fail.lua"
            fail_fixture.write_text('local x = "bad" + 1\nprint(x)\n')
            env = {"LUA_ZIG_EVIDENCE_DIR": str(temp_path / "evidence")}

            passing = run(str(CLI), "test", "--fixture", str(pass_fixture), "--target", "native-full", env=env)
            self.assertEqual(passing.returncode, 0, passing.stderr + passing.stdout)
            pass_summary = json.loads(passing.stdout)
            self.assertEqual(pass_summary["accounting"]["native_pass_count"], 1)
            self.assertEqual(pass_summary["accounting"]["fail_count"], 0)
            self.assertEqual(pass_summary["ledger"][0]["fixture"]["path"], str(pass_fixture.resolve()))
            self.assertEqual(pass_summary["ledger"][0]["implementation_mode"], "native")

            failing = run(str(CLI), "test", "--fixture", str(fail_fixture), "--target", "native-full", env=env)
            self.assertNotEqual(failing.returncode, 0, failing.stderr + failing.stdout)
            fail_summary = json.loads(failing.stdout)
            self.assertEqual(fail_summary["state"], "fail")
            self.assertEqual(fail_summary["accounting"]["fail_count"], 1)
            self.assertEqual(fail_summary["accounting"]["native_pass_count"], 0)
            self.assertIn("attempt to perform arithmetic", fail_summary["ledger"][0]["diagnostic"])

            wasm = run(str(CLI), "test", "--fixture", str(pass_fixture), "--target", "wasm-full", env=env)
            self.assertEqual(wasm.returncode, 0, wasm.stderr + wasm.stdout)
            wasm_summary = json.loads(wasm.stdout)
            self.assertEqual(wasm_summary["accounting"]["native_pass_count"], 0)
            self.assertEqual(wasm_summary["accounting"]["unsupported_count"], 1)
            self.assertEqual(wasm_summary["ledger"][0]["state"], "unsupported")
            self.assertNotEqual(wasm_summary["ledger"][0]["implementation_mode"], "native")

            sbf = run(str(CLI), "test", "--fixture", str(pass_fixture), "--target", "sbf-experimental", env=env)
            self.assertEqual(sbf.returncode, 0, sbf.stderr + sbf.stdout)
            sbf_summary = json.loads(sbf.stdout)
            self.assertEqual(sbf_summary["accounting"]["native_pass_count"], 0)
            self.assertEqual(sbf_summary["accounting"]["expected_skip_count"], 1)
            self.assertEqual(sbf_summary["ledger"][0]["state"], "expected-skip")

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

        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            workload = temp_path / "workload.lua"
            workload.write_text('print("program-out")\nio.stderr:write("program-err\\n")\nprint(arg[1], arg[2])\n')
            env = {"LUA_ZIG_EVIDENCE_DIR": str(temp_path / "evidence")}

            metrics_result = run(
                str(CLI),
                "profile",
                "metrics",
                str(workload),
                "--",
                "alpha",
                "--beta",
                env=env,
            )
            self.assertEqual(metrics_result.returncode, 0, metrics_result.stderr + metrics_result.stdout)
            self.assertEqual(metrics_result.stderr, "")
            metrics = json.loads(metrics_result.stdout)
            self.assertEqual(metrics["mode"], "runtime-metrics")
            self.assertIn("timing_ms", metrics["metrics"])
            self.assertGreaterEqual(metrics["metrics"]["timing_ms"], 0)
            self.assertEqual(metrics["program"]["stdout"], "program-out\nalpha\t--beta\n")
            self.assertEqual(metrics["program"]["stderr"], "program-err\n")
            self.assertEqual(metrics["program"]["exit_code"], 0)
            self.assertEqual(metrics["workload"]["path"], str(workload.resolve()))
            self.assertEqual(metrics["workload"]["args"], ["alpha", "--beta"])

            invalid = run(str(CLI), "profile", "metrics", str(workload), "alpha", env=env)
            self.assertEqual(invalid.stdout, "")
            self.assertEqual(invalid.returncode, 2, invalid.stderr + invalid.stdout)
            diagnostic = json.loads(invalid.stderr)
            self.assertEqual(diagnostic["kind"], "trailing-args")

    def test_report_command_separates_fallback_and_unsupported_from_native_compatibility(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            evidence_dir = temp_path / "evidence"
            env = {"LUA_ZIG_EVIDENCE_DIR": str(evidence_dir)}
            fixture = temp_path / "fixture.lua"
            fixture.write_text("print(40 + 2)\n")
            advanced = temp_path / "advanced.lua"
            advanced.write_text('local t = setmetatable({}, { __index = function() return 42 end })\nprint(t.answer)\n')
            workload = temp_path / "workload.lua"
            workload.write_text('print("profiled")\n')

            self.assertEqual(run(str(CLI), "build", env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "check", env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "run", "-", stdin=advanced.read_text(), env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "test", "--fixture", str(fixture), env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "profile", "metrics", str(workload), env=env).returncode, 0)

            completed = run(str(CLI), "report", "--format", "json", env=env)

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
            self.assertGreaterEqual(report["accounting"]["blocked_count"], 2)
            self.assertEqual(report["evidence"]["source"], str(evidence_dir.resolve()))
            self.assertGreaterEqual(report["evidence"]["record_count"], 5)
            self.assertTrue(any(entry["state"] == "fallback-pass" for entry in report["ledger"]))
            self.assertTrue(any(entry["command"] == "profile" for entry in report["ledger"]))
            self.assertTrue(any(entry["command"] == "test" and entry["fixture"]["path"] == str(fixture.resolve()) for entry in report["ledger"]))

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
