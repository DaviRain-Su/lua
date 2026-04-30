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
        stock = run("make", "-s", "-j12", "MYCFLAGS=-std=c99 -DLUA_USE_MACOSX", "MYLDFLAGS=", "MYLIBS=")
        if stock.returncode != 0:
            raise AssertionError(stock.stderr + stock.stdout)
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

    def test_registered_build_command_returns_deterministic_json_route_metadata(self):
        completed = run(str(CLI), "build")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        self.assertEqual(completed.stderr, "")
        summary = json.loads(completed.stdout)
        self.assertEqual(summary["state"], "pending")
        self.assertEqual(summary["command"], "build")
        self.assertEqual(summary["cli"], "lua-zig")
        self.assertEqual(summary["profile"], "native-full")
        self.assertIn("registered", summary["message"])

    def test_check_validates_source_syntax_without_executing_or_emitting_artifacts(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            script = temp_path / "valid.lua"
            script.write_text('print("SHOULD_NOT_EXECUTE")\nlocal x = 21 + 21\n')
            evidence_dir = temp_path / "evidence"
            artifact_dir = temp_path / "artifacts"
            artifact_dir.mkdir()

            completed = run(
                str(CLI),
                "check",
                "--profile",
                "native-full",
                str(script),
                env={"LUA_ZIG_EVIDENCE_DIR": str(evidence_dir)},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(completed.stderr, "")
            summary = json.loads(completed.stdout)
            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["command"], "check")
            self.assertEqual(summary["target_profile"], "native-full")
            self.assertEqual(summary["accounting"]["native_pass_count"], 0)
            self.assertEqual(summary["accounting"]["fail_count"], 0)
            self.assertEqual(summary["accounting"]["unsupported_count"], 0)
            self.assertNotIn("SHOULD_NOT_EXECUTE", completed.stdout)
            ledger = summary["ledger"][0]
            self.assertEqual(ledger["implementation_mode"], "loader-parser-check")
            self.assertEqual(ledger["chunk"]["kind"], "source")
            self.assertEqual(ledger["chunk"]["path"], str(script.resolve()))
            self.assertFalse(ledger["artifacts_emitted"])
            self.assertIn("VAL-CLI-013", ledger["validates"])
            self.assertEqual(list(artifact_dir.iterdir()), [])
            evidence = json.loads(next(evidence_dir.glob("check-*.json")).read_text())
            self.assertFalse(evidence["artifacts_emitted"])

    def test_check_reports_syntax_errors_and_profile_limitations(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            invalid = temp_path / "invalid.lua"
            invalid.write_text("function nope(\n")
            unsupported = temp_path / "unsupported.lua"
            unsupported.write_text('debug.getinfo(1)\n')
            wasm_denied = temp_path / "wasm-denied.lua"
            wasm_denied.write_text('io.open("file.txt", "w")\n')
            env = {"LUA_ZIG_EVIDENCE_DIR": str(temp_path / "evidence")}

            syntax = run(str(CLI), "check", str(invalid), env=env)
            self.assertNotEqual(syntax.returncode, 0, syntax.stderr + syntax.stdout)
            self.assertEqual(syntax.stderr, "")
            syntax_summary = json.loads(syntax.stdout)
            self.assertEqual(syntax_summary["state"], "fail")
            self.assertEqual(syntax_summary["accounting"]["fail_count"], 1)
            self.assertEqual(syntax_summary["ledger"][0]["chunk"]["path"], str(invalid.resolve()))
            self.assertIn(invalid.name, syntax_summary["ledger"][0]["diagnostic"])

            native_limit = run(str(CLI), "check", str(unsupported), env=env)
            self.assertNotEqual(native_limit.returncode, 0, native_limit.stderr + native_limit.stdout)
            native_summary = json.loads(native_limit.stdout)
            self.assertEqual(native_summary["state"], "unsupported")
            self.assertEqual(native_summary["accounting"]["unsupported_count"], 1)
            self.assertEqual(native_summary["ledger"][0]["profile_limitation"], "debug-api-not-yet-native")

            wasm_limit = run(str(CLI), "check", "--profile", "wasm-full", str(wasm_denied), env=env)
            self.assertNotEqual(wasm_limit.returncode, 0, wasm_limit.stderr + wasm_limit.stdout)
            wasm_summary = json.loads(wasm_limit.stdout)
            self.assertEqual(wasm_summary["state"], "capability-denied")
            self.assertEqual(wasm_summary["accounting"]["capability_denied_count"], 1)
            self.assertIn("filesystem", wasm_summary["ledger"][0]["capability"])

    def test_check_preserves_loader_chunks_for_composite_inputs_and_syntax_attribution(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            script = temp_path / "script.lua"
            script.write_text("local script_value = 42\n")
            module = temp_path / "fixture_module.lua"
            module.write_text("local module_value = 7\nreturn {value = module_value}\n")
            env = {
                "LUA_PATH": f"{temp_path}/?.lua",
                "LUA_ZIG_EVIDENCE_DIR": str(temp_path / "evidence"),
            }

            completed = run(
                str(CLI),
                "check",
                "-e",
                "local inline_value = 1",
                "-l",
                "fixture_module",
                str(script),
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(completed.stderr, "")
            summary = json.loads(completed.stdout)
            self.assertEqual(summary["state"], "pass")
            ledger = summary["ledger"][0]
            self.assertFalse(ledger["artifacts_emitted"])
            chunks = ledger["chunks"]
            self.assertEqual([chunk["kind"] for chunk in chunks], ["inline", "module", "source"])
            self.assertEqual([chunk["state"] for chunk in chunks], ["pass", "pass", "pass"])
            self.assertEqual(chunks[0]["name"], "=(command line)")
            self.assertEqual(chunks[0]["path"], "(command line)")
            self.assertEqual(chunks[1]["name"], "@fixture_module")
            self.assertEqual(chunks[1]["path"], str(module.resolve()))
            self.assertEqual(chunks[2]["name"], f"@{script}")
            self.assertEqual(chunks[2]["path"], str(script.resolve()))

            stdin = run(str(CLI), "check", "-", stdin="local stdin_value = 3\n", env=env)
            self.assertEqual(stdin.returncode, 0, stdin.stderr + stdin.stdout)
            stdin_chunk = json.loads(stdin.stdout)["ledger"][0]["chunks"][0]
            self.assertEqual(stdin_chunk["kind"], "stdin")
            self.assertEqual(stdin_chunk["name"], "=stdin")
            self.assertEqual(stdin_chunk["path"], "stdin")

            syntax = run(
                str(CLI),
                "check",
                "-e",
                "local ok = true",
                "-e",
                "function broken(",
                str(script),
                env=env,
            )
            self.assertNotEqual(syntax.returncode, 0, syntax.stderr + syntax.stdout)
            syntax_summary = json.loads(syntax.stdout)
            self.assertEqual(syntax_summary["state"], "fail")
            self.assertEqual(syntax_summary["accounting"]["fail_count"], 1)
            syntax_chunks = syntax_summary["ledger"][0]["chunks"]
            self.assertEqual([chunk["kind"] for chunk in syntax_chunks], ["inline", "inline", "source"])
            self.assertEqual([chunk["state"] for chunk in syntax_chunks], ["pass", "fail", "pass"])
            self.assertIn("(command line)", syntax_chunks[1]["diagnostic"])
            self.assertEqual(syntax_summary["ledger"][0]["chunk"], syntax_chunks[1])

    def test_check_profile_limitation_scanner_ignores_comments_and_strings(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            comments_and_strings = temp_path / "comments-and-strings.lua"
            comments_and_strings.write_text(
                "\n".join(
                    [
                        "-- debug.getinfo(1)",
                        "-- io.open('comment.txt', 'w')",
                        "local a = \"debug.getinfo(1)\"",
                        "local b = 'io.open(\"string.txt\", \"w\")'",
                        "local c = [[os.exit(1) and load('return 1')]]",
                        "--[[ loadfile('commented.lua') ]]",
                        "local d = [=[debug.sethook(function() end)]=]",
                        "local ok = 21 + 21",
                    ]
                )
                + "\n"
            )
            real_debug = temp_path / "real-debug.lua"
            real_debug.write_text("debug.getinfo(1)\n")

            native = run(str(CLI), "check", str(comments_and_strings))
            self.assertEqual(native.returncode, 0, native.stderr + native.stdout)
            native_summary = json.loads(native.stdout)
            self.assertEqual(native_summary["state"], "pass")
            self.assertEqual(native_summary["accounting"]["unsupported_count"], 0)

            wasm = run(str(CLI), "check", "--profile", "wasm-full", str(comments_and_strings))
            self.assertEqual(wasm.returncode, 0, wasm.stderr + wasm.stdout)
            wasm_summary = json.loads(wasm.stdout)
            self.assertEqual(wasm_summary["state"], "pass")
            self.assertEqual(wasm_summary["accounting"]["capability_denied_count"], 0)

            unsupported = run(str(CLI), "check", str(real_debug))
            self.assertNotEqual(unsupported.returncode, 0, unsupported.stderr + unsupported.stdout)
            unsupported_summary = json.loads(unsupported.stdout)
            self.assertEqual(unsupported_summary["state"], "unsupported")
            self.assertEqual(unsupported_summary["ledger"][0]["profile_limitation"], "debug-api-not-yet-native")

    def test_check_reports_binary_chunk_loader_limitation(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            binary_chunk = temp_path / "chunk.luac"
            binary_chunk.write_bytes(b"\x1bLua\x00synthetic")

            completed = run(str(CLI), "check", str(binary_chunk))

            self.assertNotEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(completed.stderr, "")
            summary = json.loads(completed.stdout)
            self.assertEqual(summary["state"], "unsupported")
            self.assertEqual(summary["accounting"]["unsupported_count"], 1)
            ledger = summary["ledger"][0]
            self.assertEqual(ledger["chunk"]["kind"], "binary")
            self.assertEqual(ledger["profile_limitation"], "binary-chunk-loader-unimplemented")
            self.assertFalse(ledger["artifacts_emitted"])

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
            fallback_fail_fixture = temp_path / "fallback-fail.lua"
            fallback_fail_fixture.write_text(
                'local t = setmetatable({}, { __index = function() error("fallback boom") end })\n'
                "print(t.answer)\n"
            )
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

            fallback_failing = run(
                str(CLI),
                "test",
                "--fixture",
                str(fallback_fail_fixture),
                "--target",
                "native-full",
                env=env,
            )
            self.assertNotEqual(fallback_failing.returncode, 0, fallback_failing.stderr + fallback_failing.stdout)
            fallback_fail_summary = json.loads(fallback_failing.stdout)
            self.assertEqual(fallback_fail_summary["state"], "fail")
            self.assertEqual(fallback_fail_summary["accounting"]["fail_count"], 1)
            self.assertEqual(fallback_fail_summary["accounting"]["fallback_pass_count"], 0)
            self.assertEqual(fallback_fail_summary["accounting"]["native_pass_count"], 0)
            self.assertEqual(fallback_fail_summary["ledger"][0]["state"], "fail")
            self.assertEqual(fallback_fail_summary["ledger"][0]["implementation_mode"], "stock-lua-fallback")
            self.assertIn("fallback-fail", fallback_fail_summary["ledger"][0]["diagnostic"])
            self.assertIn("fallback boom", fallback_fail_summary["ledger"][0]["diagnostic"])

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
            advanced_fail = temp_path / "advanced-fail.lua"
            advanced_fail.write_text(
                'local t = setmetatable({}, { __index = function() error("fallback boom") end })\n'
                "print(t.answer)\n"
            )
            workload = temp_path / "workload.lua"
            workload.write_text('print("profiled")\n')

            self.assertEqual(run(str(CLI), "build", env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "check", env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "run", "-", stdin=advanced.read_text(), env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "test", "--fixture", str(fixture), env=env).returncode, 0)
            self.assertNotEqual(run(str(CLI), "test", "--fixture", str(advanced_fail), env=env).returncode, 0)
            self.assertEqual(run(str(CLI), "profile", "metrics", str(workload), env=env).returncode, 0)

            completed = run(str(CLI), "report", "--format", "json", env=env)

            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(completed.stderr, "")
            report = json.loads(completed.stdout)
            self.assertEqual(report["state"], "fail")
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
            self.assertEqual(report["accounting"]["fail_count"], 1)
            self.assertGreater(report["accounting"]["fallback_pass_count"], 0)
            self.assertGreaterEqual(report["accounting"]["blocked_count"], 1)
            self.assertEqual(report["evidence"]["source"], str(evidence_dir.resolve()))
            self.assertGreaterEqual(report["evidence"]["record_count"], 6)
            self.assertTrue(any(entry["state"] == "fallback-pass" for entry in report["ledger"]))
            self.assertTrue(
                any(
                    entry["state"] == "fail"
                    and entry["implementation_mode"] == "stock-lua-fallback"
                    and entry["fixture"]["path"] == str(advanced_fail.resolve())
                    for entry in report["ledger"]
                )
            )
            self.assertTrue(any(entry["command"] == "profile" for entry in report["ledger"]))
            self.assertTrue(any(entry["command"] == "check" and entry["state"] == "pass" for entry in report["ledger"]))
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

    def test_run_no_host_mode_records_native_evidence_for_native_assertions(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence_dir = Path(temp) / "evidence"
            completed = run(
                str(CLI),
                "run",
                "-",
                stdin="print(21 + 21)\n",
                env={"LUA_ZIG_EVIDENCE_DIR": str(evidence_dir), "LUA_ZIG_RUN_NO_HOST_LUA": "1"},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            self.assertEqual(completed.stdout, "42\n")
            evidence_files = list(evidence_dir.glob("run-*.json"))
            self.assertEqual(len(evidence_files), 1)
            evidence = json.loads(evidence_files[0].read_text())
            self.assertEqual(evidence["implementation_mode"], "native")
            self.assertIs(evidence["no_host_lua"], True)
            self.assertIn("VAL-NATIVE-003", evidence["validates"])

    def test_run_fallback_evidence_cannot_claim_native_assertions(self):
        with tempfile.TemporaryDirectory() as temp:
            evidence_dir = Path(temp) / "evidence"
            completed = run(
                str(CLI),
                "run",
                "-",
                stdin="print(21 + 21)\n",
                env={"LUA_ZIG_EVIDENCE_DIR": str(evidence_dir)},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
            evidence = json.loads(next(evidence_dir.glob("run-*.json")).read_text())
            self.assertEqual(evidence["implementation_mode"], "stock-lua-fallback")
            self.assertIs(evidence["no_host_lua"], False)
            self.assertFalse(any(assertion.startswith("VAL-NATIVE-") for assertion in evidence["validates"]))

    def assertRunParity(
        self,
        stock_args: list[str],
        candidate_args: list[str],
        *,
        stdin: str | None = None,
        env: dict[str, str] | None = None,
    ) -> None:
        stock = run("./lua", *stock_args, stdin=stdin, env=env)
        candidate = run(str(CLI), "run", *candidate_args, stdin=stdin, env=env)
        self.assertEqual(candidate.returncode, stock.returncode, stock.stderr + stock.stdout + candidate.stderr + candidate.stdout)
        self.assertEqual(candidate.stdout, stock.stdout)
        self.assertEqual(candidate.stderr, stock.stderr)

    def test_run_observable_parity_for_stdin_success_and_diagnostics(self):
        self.assertRunParity(["-"], ["-"], stdin='io.stdout:write("ok\\n")\n')
        self.assertRunParity(["-"], ["-"], stdin='local x = "bad" + 1\nprint(x)\n')
        self.assertRunParity(["-"], ["-"], stdin="function nope(\n")

    def test_run_observable_parity_for_files_args_and_file_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            script = temp_path / "args.lua"
            script.write_text(
                "print(arg[0])\n"
                "for i = 1, #arg do print(i, arg[i]) end\n"
                "print(...)\n"
            )
            self.assertRunParity([str(script), "alpha", "--flag"], [str(script), "alpha", "--flag"])

            error_script = temp_path / "boom.lua"
            error_script.write_text('error("file boom", 0)\n')
            self.assertRunParity([str(error_script)], [str(error_script)])

    def test_run_observable_parity_for_e_chunks_order_and_file_composition(self):
        self.assertRunParity(
            ["-e", "value = 40", "-e", "print(value + 2)"],
            ["-e", "value = 40", "-e", "print(value + 2)"],
        )
        self.assertRunParity(["-e", "function nope("], ["-e", "function nope("])

        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / "uses_e.lua"
            script.write_text("print(prefix .. ':file')\n")
            self.assertRunParity(
                ["-e", "prefix = 'from-e'", str(script)],
                ["-e", "prefix = 'from-e'", str(script)],
            )

    def test_run_observable_parity_for_l_preload_and_require_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            module = temp_path / "fixture_module.lua"
            module.write_text("fixture_module = { value = 42 }\nio.write('loaded\\n')\nreturn fixture_module\n")
            lua_path = f"{temp_path}/?.lua;;"
            env = {"LUA_PATH": lua_path}

            self.assertRunParity(
                ["-l", "fixture_module", "-e", "print(fixture_module.value)"],
                ["-l", "fixture_module", "-e", "print(fixture_module.value)"],
                env=env,
            )
            self.assertRunParity(
                ["-l", "missing_fixture_module", "-e", "print('unreachable')"],
                ["-l", "missing_fixture_module", "-e", "print('unreachable')"],
                env=env,
            )

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
