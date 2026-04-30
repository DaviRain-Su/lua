import json
import tempfile
import unittest
from pathlib import Path

import baseline_oracle


class FakeRunner:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def __call__(self, command, cwd, env_overrides=None, stdin=None, timeout=None):
        self.calls.append(
            {
                "command": list(command),
                "cwd": Path(cwd),
                "env_overrides": dict(env_overrides or {}),
                "stdin": stdin,
                "timeout": timeout,
            }
        )
        if not self.results:
            raise AssertionError(f"unexpected command: {command!r}")
        return self.results.pop(0)


def result(command, cwd, *, stdout="", stderr="", exit_code=0):
    return baseline_oracle.CommandResult(
        command=list(command),
        cwd=str(cwd),
        env_overrides={},
        stdout=stdout,
        stderr=stderr,
        exit_code=exit_code,
        duration_ms=7,
        started_at="2026-04-29T00:00:00Z",
        ended_at="2026-04-29T00:00:00Z",
    )


def wasm_export_fixture(export_names):
    def uleb(value):
        encoded = bytearray()
        while True:
            byte = value & 0x7F
            value >>= 7
            if value:
                byte |= 0x80
            encoded.append(byte)
            if not value:
                return bytes(encoded)

    export_payload = bytearray()
    export_payload.extend(uleb(len(export_names)))
    for index, name in enumerate(export_names):
        encoded_name = name.encode()
        export_payload.extend(uleb(len(encoded_name)))
        export_payload.extend(encoded_name)
        export_payload.append(0)  # function export
        export_payload.extend(uleb(index))
    return b"\x00asm\x01\x00\x00\x00" + b"\x07" + uleb(len(export_payload)) + bytes(export_payload)


def wasm_executable_fixture(export_names, expected_returns=None):
    expected_returns = expected_returns or {}

    def uleb(value):
        encoded = bytearray()
        while True:
            byte = value & 0x7F
            value >>= 7
            if value:
                byte |= 0x80
            encoded.append(byte)
            if not value:
                return bytes(encoded)

    def sleb_i32(value):
        if value >= 2**31:
            value -= 2**32
        encoded = bytearray()
        more = True
        while more:
            byte = value & 0x7F
            value >>= 7
            sign_bit_set = byte & 0x40
            more = not ((value == 0 and not sign_bit_set) or (value == -1 and sign_bit_set))
            if more:
                byte |= 0x80
            encoded.append(byte)
        return bytes(encoded)

    def section(section_id, payload):
        return bytes([section_id]) + uleb(len(payload)) + payload

    type_payload = bytearray()
    type_payload.extend(uleb(1))
    type_payload.append(0x60)  # function type
    type_payload.extend(uleb(0))  # no params
    type_payload.extend(uleb(1))  # one result
    type_payload.append(0x7F)  # i32

    function_payload = bytearray()
    function_payload.extend(uleb(len(export_names)))
    for _ in export_names:
        function_payload.extend(uleb(0))

    export_payload = bytearray()
    export_payload.extend(uleb(len(export_names)))
    for index, name in enumerate(export_names):
        encoded_name = name.encode()
        export_payload.extend(uleb(len(encoded_name)))
        export_payload.extend(encoded_name)
        export_payload.append(0)  # function export
        export_payload.extend(uleb(index))

    code_payload = bytearray()
    code_payload.extend(uleb(len(export_names)))
    for index, name in enumerate(export_names):
        expected = expected_returns.get(name, index)
        body = b"\x00" + b"\x41" + sleb_i32(expected) + b"\x0f\x0b"
        code_payload.extend(uleb(len(body)))
        code_payload.extend(body)

    return (
        b"\x00asm\x01\x00\x00\x00"
        + section(1, bytes(type_payload))
        + section(3, bytes(function_payload))
        + section(7, bytes(export_payload))
        + section(10, bytes(code_payload))
    )


class BaselineOracleTests(unittest.TestCase):
    def test_build_records_required_darwin_command_and_lua_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake = FakeRunner(
                [
                    result(baseline_oracle.DARWIN_BUILD_COMMAND, repo),
                    result(["./lua", "-v"], repo, stdout="Lua 5.5.1\n"),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_build()

            self.assertEqual(summary["state"], "pass")
            self.assertIn("-DLUA_USE_MACOSX", " ".join(fake.calls[0]["command"]))
            self.assertEqual(fake.calls[0]["env_overrides"]["MYLDFLAGS"], "")
            self.assertEqual(fake.calls[0]["env_overrides"]["MYLIBS"], "")
            self.assertEqual(fake.calls[1]["command"], ["./lua", "-v"])
            self.assertIn("Lua 5.5", summary["version"]["stdout"])

    def test_selected_tests_run_independently_and_persist_test_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            tests = repo / "testes"
            tests.mkdir()
            fake = FakeRunner(
                [
                    result(["../lua", "-W", "constructs.lua"], tests, stdout="constructs ok\n"),
                    result(["../lua", "-W", "vararg.lua"], tests, stdout="vararg ok\n"),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_selected_tests()

            self.assertEqual(summary["state"], "pass")
            self.assertEqual([entry["test"] for entry in summary["tests"]], ["constructs.lua", "vararg.lua"])
            self.assertEqual(fake.calls[0]["cwd"], tests.resolve())
            self.assertEqual(fake.calls[1]["cwd"], tests.resolve())
            self.assertNotEqual(summary["tests"][0]["result_file"], summary["tests"][1]["result_file"])

    def test_full_suite_prompt_failure_is_known_constraint_not_hidden(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            tests = repo / "testes"
            tests.mkdir()
            fake = FakeRunner(
                [
                    result(
                        ["../lua", "-W", "all.lua"],
                        tests,
                        stderr="testes/main.lua:396: assertion failed near prompt\n",
                        exit_code=1,
                    )
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_full_suite_constraint()

            self.assertEqual(summary["state"], "known_constraint")
            self.assertEqual(summary["known_constraint"]["file"], "testes/main.lua")
            self.assertEqual(summary["known_constraint"]["line"], 396)
            self.assertIn("prompt", summary["known_constraint"]["description"])
            self.assertEqual(summary["attempt"]["exit_code"], 1)

    def test_written_result_contains_reproducible_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake = FakeRunner([result(["./lua", "-v"], repo, stdout="Lua 5.5.1\n")])
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            written = oracle.write_result("version", fake.results.pop(0))
            data = json.loads(Path(written).read_text())

            self.assertEqual(data["command"], ["./lua", "-v"])
            self.assertEqual(data["cwd"], str(repo))
            self.assertIn("started_at", data)
            self.assertIn("ended_at", data)
            self.assertEqual(data["stdout"], "Lua 5.5.1\n")
            self.assertEqual(data["exit_code"], 0)

    def test_stock_snippet_captures_stdout_stderr_exit_and_stdin(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = 'print(_VERSION); io.stderr:write("err\\n")\n'
            fake = FakeRunner(
                [
                    result(["./lua", "-"], repo, stdout="Lua 5.5\n", stderr="err\n", exit_code=0),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_stock_snippet("success-snippet", snippet)

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["snippet"]["name"], "success-snippet")
            self.assertEqual(summary["result"]["stdout"], "Lua 5.5\n")
            self.assertEqual(summary["result"]["stderr"], "err\n")
            self.assertEqual(summary["result"]["exit_code"], 0)
            self.assertEqual(fake.calls[0]["command"], ["./lua", "-"])
            self.assertEqual(fake.calls[0]["stdin"], snippet)

    def test_stock_snippet_preserves_error_stderr_and_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = 'error("boom")\n'
            fake = FakeRunner(
                [
                    result(
                        ["./lua", "-"],
                        repo,
                        stderr="stdin:1: boom\nstack traceback:\n",
                        exit_code=1,
                    ),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_stock_snippet("error-snippet", snippet)

            self.assertEqual(summary["state"], "captured_error")
            self.assertEqual(summary["result"]["exit_code"], 1)
            self.assertEqual(summary["result"]["stdout"], "")
            self.assertIn("boom", summary["result"]["stderr"])

    def test_differential_missing_candidate_is_pending_not_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = "print('stock only')\n"
            fake = FakeRunner([result(["./lua", "-"], repo, stdout="stock only\n")])
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_differential("absent-candidate", snippet, candidate_command=None)

            self.assertEqual(summary["state"], "pending")
            self.assertEqual(summary["candidate"]["state"], "pending")
            self.assertNotEqual(summary["state"], "pass")
            self.assertIn("missing candidate", summary["message"])
            self.assertEqual(summary["stock"]["result"]["stdout"], "stock only\n")

    def test_differential_reports_stream_and_exit_mismatches(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = "print('expected')\n"
            fake = FakeRunner(
                [
                    result(["./lua", "-"], repo, stdout="expected\n", stderr="", exit_code=0),
                    result(["candidate-lua", "-"], repo, stdout="actual\n", stderr="warn\n", exit_code=2),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_differential("mismatch", snippet, candidate_command=["candidate-lua", "-"])

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["candidate"]["state"], "fail")
            self.assertIn("stdout", summary["diffs"])
            self.assertIn("stderr", summary["diffs"])
            self.assertIn("exit_code", summary["diffs"])
            self.assertIn("-expected", summary["diffs"]["stdout"])
            self.assertIn("+actual", summary["diffs"]["stdout"])

    def test_differential_reports_stdout_trailing_newline_only_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = "io.write('line')\n"
            fake = FakeRunner(
                [
                    result(["./lua", "-"], repo, stdout="line\n", exit_code=0),
                    result(["candidate-lua", "-"], repo, stdout="line", exit_code=0),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_differential("stdout-trailing-newline", snippet, candidate_command=["candidate-lua", "-"])

            self.assertEqual(summary["state"], "fail")
            self.assertIn("stdout", summary["diffs"])
            self.assertTrue(summary["diffs"]["stdout"].strip())
            self.assertIn("stock_repr='line\\n'", summary["diffs"]["stdout"])
            self.assertIn("candidate_repr='line'", summary["diffs"]["stdout"])

    def test_differential_reports_stderr_trailing_newline_only_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = "io.stderr:write('warn')\n"
            fake = FakeRunner(
                [
                    result(["./lua", "-"], repo, stderr="warn\n", exit_code=0),
                    result(["candidate-lua", "-"], repo, stderr="warn", exit_code=0),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_differential("stderr-trailing-newline", snippet, candidate_command=["candidate-lua", "-"])

            self.assertEqual(summary["state"], "fail")
            self.assertIn("stderr", summary["diffs"])
            self.assertTrue(summary["diffs"]["stderr"].strip())
            self.assertIn("stock_repr='warn\\n'", summary["diffs"]["stderr"])
            self.assertIn("candidate_repr='warn'", summary["diffs"]["stderr"])

    def test_candidate_comparison_does_not_mutate_existing_stock_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            snippet = "print('immutable')\n"
            stock_record = repo / "stock-record.json"
            stock_data = result(["./lua", "-"], repo, stdout="immutable\n").to_dict()
            stock_record.write_text(json.dumps(stock_data, indent=2, sort_keys=True) + "\n")
            before = stock_record.read_bytes()
            fake = FakeRunner(
                [
                    result(["candidate-lua", "-"], repo, stdout="immutable\n"),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_differential(
                "immutable-stock",
                snippet,
                candidate_command=["candidate-lua", "-"],
                stock_result_file=stock_record,
            )

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(stock_record.read_bytes(), before)
            self.assertEqual(len(fake.calls), 1)
            self.assertEqual(fake.calls[0]["command"], ["candidate-lua", "-"])
            self.assertNotEqual(summary["stock"]["result_file"], summary["candidate"]["result_file"])

    def test_vm_level1_corpus_accounts_for_pass_and_unsupported_closure(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            level1 = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 1 and snippet["expected_state"] == "pass"
            ]
            for snippet in level1:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(snippet.get("expected_stdout", ""))))
                if snippet["name"] == "level1-closures":
                    fake_results.append(
                        result(
                            ["ziglua-vm"],
                            repo,
                            stderr="ziglua-vm: unsupported/fallback Level 1 snippet: closure-upvalues\n",
                            exit_code=1,
                        )
                    )
                else:
                    fake_results.append(result(["ziglua-vm"], repo, stdout=str(snippet.get("expected_stdout", ""))))
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_level1_corpus(["ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["candidate_command"], ["ziglua-vm"])
            self.assertGreaterEqual(summary["pass_count"], 5)
            self.assertEqual(summary["unsupported_count"], 1)
            closure = next(entry for entry in summary["snippets"] if entry["name"] == "level1-closures")
            self.assertEqual(closure["state"], "unsupported")
            self.assertIn("closure", closure["unsupported_reason"])

    def test_vm_level1_corpus_fails_required_feature_unsupported(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            level1 = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 1 and snippet["expected_state"] == "pass"
            ]
            for snippet in level1:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(snippet.get("expected_stdout", ""))))
                if snippet["name"] == "level1-functions":
                    fake_results.append(
                        result(
                            ["ziglua-vm"],
                            repo,
                            stderr="ziglua-vm: unsupported/fallback Level 1 snippet: direct-call\n",
                            exit_code=1,
                        )
                    )
                else:
                    fake_results.append(result(["ziglua-vm"], repo, stdout=str(snippet.get("expected_stdout", ""))))
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_level1_corpus(["ziglua-vm"])

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["unsupported_count"], 0)
            self.assertEqual(summary["fail_count"], 1)
            direct_call = next(entry for entry in summary["snippets"] if entry["name"] == "level1-functions")
            self.assertEqual(direct_call["state"], "fail")
            self.assertEqual(direct_call["unsupported_reason"], "")

    def test_default_vm_candidate_is_refreshed_before_level1_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [result(baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND, repo)]
            level1 = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 1 and snippet["expected_state"] == "pass"
            ]
            for snippet in level1:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(snippet.get("expected_stdout", ""))))
                fake_results.append(
                    result(
                        baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                        repo,
                        stdout=str(snippet.get("expected_stdout", "")),
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_level1_corpus(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND)

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(fake.calls[0]["command"], baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND)
            self.assertEqual(summary["candidate_refresh"]["state"], "pass")
            self.assertIn("build-before-compare", summary["candidate_refresh"]["contract"])

    def test_default_vm_candidate_refresh_failure_stops_before_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake = FakeRunner(
                [
                    result(
                        baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND,
                        repo,
                        stderr="compile error\n",
                        exit_code=1,
                    )
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_level1_corpus(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND)

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["candidate_refresh"]["state"], "fail")
            self.assertEqual(summary["snippet_count"], 0)
            self.assertEqual(len(fake.calls), 1)

    def test_vm_dynamic_fallback_accepts_required_unsupported_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stderr=f"ziglua-vm: unsupported/fallback Level 1 snippet: {fixture['reason']}\n",
                        exit_code=1,
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_dynamic_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["fixture_count"], len(baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES))
            self.assertEqual(summary["fallback_pass_count"], 0)
            self.assertEqual(summary["unsupported_count"], len(baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES))
            self.assertEqual(summary["fail_count"], 0)
            self.assertEqual(
                {entry["fixture"] for entry in summary["fixtures"]},
                {"dynamic-load", "dynamic-debug", "dynamic-metatable-dispatch", "dynamic-env-mutation"},
            )
            self.assertTrue(all(entry["state"] == "unsupported" for entry in summary["fixtures"]))

    def test_vm_dynamic_fallback_fails_partial_or_silent_misexecution(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                if fixture["name"] == "dynamic-load":
                    fake_results.append(result(["ziglua-vm"], repo, stdout="wrong\n", exit_code=0))
                else:
                    fake_results.append(
                        result(
                            ["ziglua-vm"],
                            repo,
                            stderr=f"ziglua-vm: unsupported/fallback Level 1 snippet: {fixture['reason']}\n",
                            exit_code=1,
                        )
                    )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_dynamic_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["fail_count"], 1)
            load = next(entry for entry in summary["fixtures"] if entry["fixture"] == "dynamic-load")
            self.assertEqual(load["state"], "fail")
            self.assertIn("stdout", load["diffs"])

    def test_vm_dynamic_fallback_rejects_silent_stock_equivalent_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(result(["ziglua-vm"], repo, stdout=str(fixture["stock_stdout"])))
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_dynamic_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["fallback_pass_count"], 0)
            self.assertEqual(summary["unsupported_count"], 0)
            self.assertEqual(summary["fail_count"], len(baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES))
            self.assertTrue(all(entry["state"] == "fail" for entry in summary["fixtures"]))

    def test_vm_dynamic_fallback_accepts_stock_parity_with_explicit_fallback_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stdout=str(fixture["stock_stdout"]),
                        stderr=f"ziglua-vm: fallback executed dynamic fixture: {fixture['reason']}\n",
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_dynamic_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["fallback_pass_count"], len(baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES))
            self.assertEqual(summary["unsupported_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "fallback-pass" for entry in summary["fixtures"]))

    def test_vm_dynamic_fallback_rejects_fallback_marker_in_program_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stdout=str(fixture["stock_stdout"]) + f"fallback: {fixture['reason']}\n",
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_dynamic_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["fallback_pass_count"], 0)
            self.assertEqual(summary["unsupported_count"], 0)
            self.assertEqual(summary["fail_count"], len(baseline_oracle.VM_DYNAMIC_FALLBACK_FIXTURES))
            self.assertTrue(all(entry["state"] == "fail" for entry in summary["fixtures"]))
            self.assertTrue(all("stdout" in entry["diffs"] for entry in summary["fixtures"]))

    def test_vm_advanced_fallback_reports_required_hook_diagnostics_unfulfilled(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stderr=f"ziglua-vm: unsupported/fallback Level 1 snippet: {fixture['reason']}\n",
                        exit_code=1,
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_advanced_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "unfulfilled")
            self.assertEqual(summary["fixture_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["stock_parity_count"], 0)
            self.assertEqual(summary["fallback_pass_count"], 0)
            self.assertEqual(summary["capability_denied_count"], 0)
            self.assertEqual(
                summary["unsupported_unfulfilled_count"],
                len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES),
            )
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "unsupported-unfulfilled" for entry in summary["fixtures"]))

    def test_vm_advanced_fallback_accepts_exact_stock_parity(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(result(["ziglua-vm"], repo, stdout=str(fixture["stock_stdout"])))
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_advanced_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["stock_parity_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["fallback_pass_count"], 0)
            self.assertEqual(summary["capability_denied_count"], 0)
            self.assertEqual(summary["unsupported_unfulfilled_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "stock-parity" for entry in summary["fixtures"]))

    def test_vm_advanced_fallback_accepts_stock_parity_with_explicit_fallback_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stdout=str(fixture["stock_stdout"]),
                        stderr=f"ziglua-vm: fallback executed advanced fixture: {fixture['reason']}\n",
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_advanced_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["stock_parity_count"], 0)
            self.assertEqual(summary["fallback_pass_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["capability_denied_count"], 0)
            self.assertEqual(summary["unsupported_unfulfilled_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "fallback-pass" for entry in summary["fixtures"]))

    def test_vm_advanced_fallback_separates_capability_denied_from_unfulfilled(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = []
            for fixture in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stderr=f"ziglua-vm: capability-denied advanced fixture: {fixture['reason']}\n",
                        exit_code=1,
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_advanced_fallback(["ziglua-vm"])

            self.assertEqual(summary["state"], "unfulfilled")
            self.assertEqual(summary["stock_parity_count"], 0)
            self.assertEqual(summary["fallback_pass_count"], 0)
            self.assertEqual(summary["capability_denied_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["unsupported_unfulfilled_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "capability-denied" for entry in summary["fixtures"]))

    def test_aot_advanced_fallback_runs_stock_vm_and_aot_for_shared_classification(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [
                result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                result(baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND, repo),
            ]
            for fixture in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(
                    result(
                        baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                        repo,
                        stdout=str(fixture["stock_stdout"]),
                        stderr=f"ziglua-vm: fallback-pass reason={fixture['reason']}\n",
                    )
                )
                fake_results.append(
                    result(
                        baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
                        repo,
                        stdout=str(fixture["stock_stdout"]),
                        stderr=f"ziglua-aot: fallback-pass reason={fixture['reason']}\n",
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_advanced_fallback(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["fixture_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["shared_classification_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["observable_parity_count"], 0)
            self.assertEqual(summary["unsupported_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "shared-fallback-classification" for entry in summary["fixtures"]))
            self.assertTrue(all("stock_result_file" in entry for entry in summary["fixtures"]))
            self.assertTrue(all("vm_result_file" in entry for entry in summary["fixtures"]))
            self.assertTrue(all("aot_result_file" in entry for entry in summary["fixtures"]))
            self.assertTrue(all(entry["artifact_policy"] == "advanced dynamic chunks are VM-fallback/rejection classified; no AOT-only artifact may bypass shared hooks" for entry in summary["fixtures"]))

    def test_aot_advanced_fallback_fails_divergent_non_empty_classifications(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fixture = baseline_oracle.ADVANCED_SEMANTICS_FIXTURES[0]
            fake_results = [
                result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                result(baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND, repo),
                result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])),
                result(
                    baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                    repo,
                    stdout=str(fixture["stock_stdout"]),
                    stderr=f"ziglua-vm: fallback-pass reason={fixture['reason']}\n",
                ),
                result(
                    baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
                    repo,
                    stderr=f"ziglua-aot: unsupported/fallback AOT Level 0 chunk: {fixture['reason']}\n",
                    exit_code=1,
                ),
            ]
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            original_fixtures = baseline_oracle.ADVANCED_SEMANTICS_FIXTURES
            try:
                baseline_oracle.ADVANCED_SEMANTICS_FIXTURES = [fixture]
                summary = oracle.run_aot_advanced_fallback(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)
            finally:
                baseline_oracle.ADVANCED_SEMANTICS_FIXTURES = original_fixtures

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["shared_classification_count"], 0)
            self.assertEqual(summary["observable_parity_count"], 0)
            self.assertEqual(summary["fail_count"], 1)
            self.assertEqual(summary["fixtures"][0]["vm_classification"], "fallback")
            self.assertEqual(summary["fixtures"][0]["aot_classification"], "unsupported")
            self.assertEqual(summary["fixtures"][0]["state"], "fail")
            self.assertIn("aot_shared_classification", summary["fixtures"][0]["diffs"])

    def test_aot_advanced_fallback_accepts_observable_stock_vm_aot_parity(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [
                result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                result(baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND, repo),
            ]
            for fixture in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES:
                fake_results.append(result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(result(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, repo, stdout=str(fixture["stock_stdout"])))
                fake_results.append(result(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, repo, stdout=str(fixture["stock_stdout"])))
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_advanced_fallback(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["observable_parity_count"], len(baseline_oracle.ADVANCED_SEMANTICS_FIXTURES))
            self.assertEqual(summary["shared_classification_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "observable-parity" for entry in summary["fixtures"]))

    def test_aot_advanced_fallback_fails_when_aot_classification_differs_from_vm(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fixture = baseline_oracle.ADVANCED_SEMANTICS_FIXTURES[-1]
            fake_results = [
                result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                result(baseline_oracle.ZIG_VM_CANDIDATE_REFRESH_COMMAND, repo),
                result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])),
                result(
                    baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                    repo,
                    stdout=str(fixture["stock_stdout"]),
                    stderr=f"ziglua-vm: fallback-pass reason={fixture['reason']}\n",
                ),
                result(
                    baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
                    repo,
                    stderr="ziglua-aot: unsupported/fallback AOT Level 0 chunk: wrong-reason\n",
                    exit_code=1,
                ),
            ]
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            original_fixtures = baseline_oracle.ADVANCED_SEMANTICS_FIXTURES
            try:
                baseline_oracle.ADVANCED_SEMANTICS_FIXTURES = [fixture]
                summary = oracle.run_aot_advanced_fallback(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)
            finally:
                baseline_oracle.ADVANCED_SEMANTICS_FIXTURES = original_fixtures

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["fail_count"], 1)
            self.assertEqual(summary["fixtures"][0]["state"], "fail")
            self.assertIn("aot_shared_classification", summary["fixtures"][0]["diffs"])

    def test_aot_dynamic_fallback_accepts_explicit_stock_equivalent_fallback_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fixture = baseline_oracle.AOT_DYNAMIC_FALLBACK_FIXTURES[2]
            fake_results = [
                result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                result(
                    baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
                    repo,
                    stdout=str(fixture["stock_stdout"]),
                    stderr=f"ziglua-aot: fallback-pass reason={fixture['reason']}\n",
                ),
                result(["./lua", "-"], repo, stdout=str(fixture["stock_stdout"])),
            ]
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            original_fixtures = baseline_oracle.AOT_DYNAMIC_FALLBACK_FIXTURES
            try:
                baseline_oracle.AOT_DYNAMIC_FALLBACK_FIXTURES = [fixture]
                summary = oracle.run_aot_dynamic_fallback(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)
            finally:
                baseline_oracle.AOT_DYNAMIC_FALLBACK_FIXTURES = original_fixtures

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["fallback_pass_count"], 1)
            self.assertEqual(summary["unsupported_count"], 0)
            self.assertEqual(summary["fail_count"], 0)
            self.assertEqual(summary["fixtures"][0]["state"], "fallback-pass")

    def test_debug_capi_gate_report_separates_executable_and_report_only_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [
                result(["./lua", "-"], repo, stdout="call\nreturn\nline\ncount\n"),
                result(["./zig-out/bin/ziglua-vm"], repo, stderr="ziglua-vm: unsupported/fallback Level 1 snippet: debug\n", exit_code=1),
                result(["zig", "build", "-Dprofile=native-full", "-Ddebug=true", "--summary", "all"], repo),
                result(["zig", "build", "-Dprofile=wasm-constrained", "-Ddebug=false", "--summary", "all"], repo),
                result(["zig", "test", "src/ziglua/debug_capi_gates.zig"], repo, stdout="All 6 tests passed\n"),
            ]
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_debug_capi_gates(["./zig-out/bin/ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["debug"]["native_hook_snippet"]["state"], "stock-oracle-pass")
            self.assertEqual(summary["debug"]["native_hook_snippet"]["evidence_boundary"], "stock-oracle-only")
            self.assertEqual(summary["debug"]["native_hook_gate"]["state"], "unsupported")
            self.assertEqual(summary["debug"]["native_hook_gate"]["evidence_boundary"], "report-only-zig-tests")
            self.assertIn("not implemented", summary["debug"]["native_hook_gate"]["reason"])
            self.assertEqual(summary["debug"]["zig_vm_gate"]["state"], "unsupported")
            self.assertEqual(summary["debug"]["constrained_profile_gate"]["state"], "capability-denied")
            hook_denials = summary["debug"]["constrained_profile_gate"]["hook_denials"]
            self.assertEqual(set(hook_denials), {"sethook-call", "sethook-return", "sethook-line", "sethook-count"})
            for event, denial in hook_denials.items():
                self.assertEqual(denial["state"], "capability-denied")
                self.assertEqual(denial["capability"], "debug-hooks")
                self.assertIn(event, denial["reason"])
                self.assertEqual(denial["evidence_boundary"], "hook-specific-generated-report-entry")
            self.assertEqual(summary["debug"]["native_profile_gate"]["state"], "report-only")
            self.assertEqual(summary["debug"]["native_profile_gate"]["implementation_state"], "unsupported")
            self.assertEqual(summary["c_api_bridge"]["evidence_boundary"], "report-only-zig-tests")
            self.assertFalse(summary["c_api_bridge"]["full_abi_compatibility"])
            self.assertIn("state", summary["c_api_bridge"]["invariants"])
            self.assertIn("protected-call", summary["c_api_bridge"]["invariants"])

    def test_vm_selected_puc_harness_accounts_unsupported_without_false_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            tests = repo / "testes"
            tests.mkdir()
            selected = ["constructs.lua", "code.lua", "calls.lua", "closure.lua", "math.lua", "strings.lua"]
            fake_results = []
            for test_name in selected:
                (tests / test_name).write_text(f"-- {test_name}\n")
                fake_results.append(result(["../lua", "-W", test_name], tests, stdout=f"{test_name} stock\n"))
                fake_results.append(
                    result(
                        ["ziglua-vm"],
                        repo,
                        stderr=f"ziglua-vm: unsupported/fallback PUC test: {test_name}\n",
                        exit_code=1,
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_vm_selected_puc(["ziglua-vm"])

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["unsupported_count"], len(selected))
            self.assertEqual(summary["fail_count"], 0)
            self.assertEqual([entry["test"] for entry in summary["tests"]], selected)
            self.assertTrue(all(entry["state"] == "unsupported" for entry in summary["tests"]))

    def test_aot_eligibility_accepts_level0_and_rejects_dynamic_fixtures(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo)]
            positives = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 0 and snippet["expected_state"] == "pass"
            ]
            for snippet in positives:
                fake_results.append(
                    result(
                        baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND + ["--check"],
                        repo,
                        stdout=f"ziglua-aot: eligible Level 0 lowered-artifact=ir source={snippet['name']}\n",
                    )
                )
            for fixture in baseline_oracle.AOT_DYNAMIC_FALLBACK_FIXTURES:
                fake_results.append(
                    result(
                        baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND + ["--check"],
                        repo,
                        stderr=f"ziglua-aot: unsupported/fallback AOT Level 0 chunk: {fixture['reason']}\n",
                        exit_code=1,
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_eligibility(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["positive_count"], len(positives))
            self.assertEqual(summary["negative_count"], len(baseline_oracle.AOT_DYNAMIC_FALLBACK_FIXTURES))
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(entry["state"] == "eligible" for entry in summary["positive"]))
            self.assertTrue(all(entry["state"] == "unsupported" for entry in summary["negative"]))

    def test_aot_artifact_matrix_compares_stock_vm_and_generated_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo)]
            positives = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 0 and snippet["expected_state"] == "pass"
            ]
            for snippet in positives:
                expected = str(snippet.get("expected_stdout", ""))
                fake_results.extend(
                    [
                        result(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, repo, stdout=expected),
                        result(["./lua", "-"], repo, stdout=expected),
                        result(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, repo, stdout=expected),
                        result(["aot-artifact"], repo, stdout=expected),
                    ]
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_artifact_matrix(
                baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["artifact_count"], len(positives))
            self.assertEqual(summary["fail_count"], 0)
            self.assertTrue(all(Path(entry["artifact_path"]).exists() for entry in summary["snippets"]))
            self.assertTrue(all(entry["state"] == "pass" for entry in summary["snippets"]))
            self.assertTrue(all(entry["artifact_contract"]["state"] == "pass" for entry in summary["snippets"]))

    def test_aot_artifacts_are_lowered_ir_not_source_wrappers(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            expected = "3\n"
            fake = FakeRunner(
                [
                    result(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, repo, stdout=expected),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            artifact = oracle.write_aot_artifact(
                "lowered-smoke",
                "print(1 + 2)\n",
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            metadata = json.loads(Path(artifact["metadata_path"]).read_text())
            artifact_text = Path(artifact["artifact_path"]).read_text()
            ir = json.loads(Path(artifact["ir_path"]).read_text())

            self.assertEqual(metadata["artifact_kind"], "lowered-ir-executable")
            self.assertEqual(metadata["provenance"]["source_sha256"], baseline_oracle._sha256_text("print(1 + 2)\n"))
            self.assertTrue(metadata["execution"]["independent_of_original_source"])
            self.assertFalse(metadata["execution"]["consumes_original_source"])
            self.assertFalse(metadata["execution"]["invokes_ziglua_runner"])
            self.assertNotIn("stdin_redirection", metadata)
            self.assertNotIn("command", metadata)
            self.assertNotIn("ziglua-aot", artifact_text)
            self.assertNotIn("ziglua-vm", artifact_text)
            self.assertNotIn("print(1 + 2)", artifact_text)
            self.assertEqual(ir["ir_kind"], "level0-cli-result-ir")
            self.assertEqual(ir["source_sha256"], metadata["provenance"]["source_sha256"])
            self.assertEqual(baseline_oracle.validate_aot_artifact_contract(artifact, repo), [])

    def test_aot_artifact_matrix_rejects_wrapper_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            positives = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 0 and snippet["expected_state"] == "pass"
            ]
            fake_results = []
            for snippet in positives:
                expected = str(snippet.get("expected_stdout", ""))
                fake_results.extend(
                    [
                        result(["./lua", "-"], repo, stdout=expected),
                        result(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, repo, stdout=expected),
                        result(["wrapper-artifact"], repo, stdout=expected),
                    ]
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)
            wrapper_dir = repo / "build" / "aot" / "wrapper"
            wrapper_dir.mkdir(parents=True)
            wrapper_script = wrapper_dir / "wrapper.sh"
            source_path = wrapper_dir / "wrapped.lua"
            metadata_path = wrapper_dir / "wrapper.json"
            wrapper_script.write_text("#!/bin/sh\nexec ./zig-out/bin/ziglua-aot < wrapped.lua\n")
            source_path.write_text("print(1 + 2)\n")
            metadata_path.write_text(
                json.dumps(
                    {
                        "artifact_kind": "filesystem-scoped-aot-wrapper",
                        "artifact_path": str(wrapper_script),
                        "source_path": str(source_path),
                        "source_sha256": baseline_oracle._sha256_text("print(1 + 2)\n"),
                        "command": baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
                        "stdin_redirection": "wrapped.lua",
                    }
                )
            )
            wrapper = {
                "artifact_path": str(wrapper_script),
                "source_path": str(source_path),
                "metadata_path": str(metadata_path),
            }
            oracle.refresh_default_zig_aot_candidate = lambda _command: {"state": "pass"}
            oracle.write_aot_artifact = lambda _name, _source, _command: wrapper

            summary = oracle.run_aot_artifact_matrix(
                baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            self.assertEqual(summary["state"], "fail")
            self.assertGreater(summary["fail_count"], 0)
            first = summary["snippets"][0]
            self.assertEqual(first["artifact_contract"]["state"], "fail")
            self.assertTrue(any("wrapper" in error for error in first["artifact_contract"]["errors"]))

    def test_aot_runtime_error_parity_uses_documented_normalized_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake = FakeRunner(
                [
                    result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                    result(["./lua", "-"], repo, stderr="lua: stdin:1: attempt to perform arithmetic on a string value\nstack traceback:\n", exit_code=1),
                    result(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, repo, stderr="ziglua-vm: attempt to perform arithmetic on an unsupported value\n", exit_code=1),
                    result(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, repo, stderr="ziglua-aot: attempt to perform arithmetic on an unsupported value\n", exit_code=1),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_runtime_error_parity(
                baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["policy"], "normalized-runtime-error")
            self.assertTrue(all(entry["state"] == "pass" for entry in summary["fixtures"]))

    def test_aot_runtime_error_parity_fails_on_differing_nonzero_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake = FakeRunner(
                [
                    result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo),
                    result(["./lua", "-"], repo, stderr="lua: stdin:1: attempt to perform arithmetic on a string value\nstack traceback:\n", exit_code=1),
                    result(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, repo, stderr="ziglua-vm: attempt to perform arithmetic on an unsupported value\n", exit_code=2),
                    result(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, repo, stderr="ziglua-aot: attempt to perform arithmetic on an unsupported value\n", exit_code=1),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_runtime_error_parity(
                baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["exit_code_policy"], "exact")
            first = summary["fixtures"][0]
            self.assertEqual(first["state"], "fail")
            self.assertFalse(first["exit_code_parity"]["exact_match"])
            self.assertEqual(first["exit_code_parity"]["stock"], 1)
            self.assertEqual(first["exit_code_parity"]["vm"], 2)
            self.assertEqual(first["exit_code_parity"]["aot"], 1)
            self.assertTrue(
                any("exit codes differ" in error for error in first["normalization_errors"]),
                first["normalization_errors"],
            )

    def test_aot_disagreement_detection_fails_matrix_on_stream_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            fake_results = [result(baseline_oracle.ZIG_AOT_CANDIDATE_REFRESH_COMMAND, repo)]
            positives = [
                snippet
                for snippet in baseline_oracle.load_snippet_corpus()
                if snippet["level"] == 0 and snippet["expected_state"] == "pass"
            ]
            for index, snippet in enumerate(positives):
                expected = str(snippet.get("expected_stdout", ""))
                aot_stdout = "intentional mismatch\n" if index == 0 else expected
                fake_results.extend(
                    [
                        result(baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, repo, stdout=expected),
                        result(["./lua", "-"], repo, stdout=expected),
                        result(baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, repo, stdout=expected),
                        result(["aot-artifact"], repo, stdout=aot_stdout),
                    ]
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_aot_artifact_matrix(
                baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            self.assertEqual(summary["state"], "fail")
            self.assertEqual(summary["fail_count"], 1)
            first = summary["snippets"][0]
            self.assertEqual(first["state"], "fail")
            self.assertIn("aot_vs_stock", first["diffs"])

    def test_default_snippet_corpus_covers_required_level_0_and_1_areas(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build")

            summary = oracle.list_corpus()

            self.assertEqual(summary["state"], "pass")
            self.assertTrue(baseline_oracle.REQUIRED_CORPUS_AREAS.issubset(set(summary["covered_areas"])))
            self.assertGreaterEqual(summary["snippet_count"], len(baseline_oracle.REQUIRED_CORPUS_AREAS))
            for snippet in summary["snippets"]:
                self.assertIn(snippet["level"], [0, 1])
                self.assertIn(snippet["expected_state"], ["pass", "captured_error"])
                self.assertTrue(snippet["areas"])
                self.assertTrue(snippet["source_sha256"])

    def test_stock_corpus_runs_all_snippets_and_accepts_expected_error_fixtures(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            corpus = baseline_oracle.load_snippet_corpus()
            fake_results = []
            for snippet in corpus:
                if snippet["expected_state"] == "captured_error":
                    fake_results.append(
                        result(
                            ["./lua", "-"],
                            repo,
                            stderr="\tattempt to add\nstack traceback:\n",
                            exit_code=1,
                        )
                    )
                else:
                    fake_results.append(result(["./lua", "-"], repo, stdout=snippet.get("expected_stdout", "")))
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_stock_corpus()

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["snippet_count"], len(corpus))
            self.assertEqual(len(summary["snippets"]), len(corpus))
            self.assertTrue(baseline_oracle.REQUIRED_CORPUS_AREAS.issubset(set(summary["covered_areas"])))
            self.assertEqual(len(fake.calls), len(corpus))
            self.assertTrue(all(call["command"] == ["./lua", "-"] for call in fake.calls))

    def test_default_testes_classification_covers_every_top_level_lua_file(self):
        repo = Path(__file__).resolve().parents[2]
        oracle = baseline_oracle.BaselineOracle(repo, repo / "build")

        summary = oracle.validate_testes_classification()

        self.assertEqual(summary["state"], "pass")
        self.assertEqual(summary["missing"], [])
        self.assertEqual(summary["extra"], [])
        required_files = {
            "constructs.lua",
            "vararg.lua",
            "literals.lua",
            "code.lua",
            "calls.lua",
            "closure.lua",
            "events.lua",
            "coroutine.lua",
            "gc.lua",
            "math.lua",
            "strings.lua",
            "bitwise.lua",
        }
        self.assertTrue(required_files.issubset(set(summary["classified_files"])))
        for entry in summary["classifications"]:
            self.assertTrue(entry["categories"], entry["file"])
            self.assertTrue(entry["stage"], entry["file"])

    def test_cross_target_packaging_records_native_wasm_provenance_and_capability_gates(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            native_artifact = repo / "zig-out" / "bin" / "ziglua-native-full"
            wasm_artifact = repo / "zig-out" / "bin" / "ziglua-wasm-constrained.wasm"
            profile_dir = repo / "zig-out" / "share" / "ziglua" / "profiles"
            native_artifact.parent.mkdir(parents=True)
            profile_dir.mkdir(parents=True)
            native_artifact.write_text("#!/bin/sh\nprintf 'ziglua profile smoke marker=0x5a1a55\\n'\n")
            native_artifact.chmod(0o755)
            wasm_artifact.write_bytes(
                wasm_executable_fixture(
                    baseline_oracle.CROSS_TARGET_WASM_REQUIRED_EXPORTS,
                    baseline_oracle.CROSS_TARGET_WASM_EXPECTED_RETURNS,
                )
            )
            (profile_dir / "native-full.json").write_text(
                json.dumps(
                    {
                        "profile": "native-full",
                        "target": "native",
                        "target_arch": "aarch64",
                        "target_os": "macos",
                        "allocator": "host",
                        "stdlib": "full",
                        "debug": "full",
                        "gc": "lua-compatible",
                        "engine": "vm-aot",
                        "optimize": "Debug",
                        "capabilities": {"os": "enabled", "filesystem": "enabled", "process": "enabled", "dynamic_loading": "enabled"},
                        "dynamic_loading": "enabled",
                        "sbf_experimental": False,
                    }
                )
            )
            (profile_dir / "wasm-constrained.json").write_text(
                json.dumps(
                    {
                        "profile": "wasm-constrained",
                        "target": "wasm32-freestanding",
                        "target_arch": "wasm32",
                        "target_os": "freestanding",
                        "allocator": "bounded",
                        "stdlib": "constrained",
                        "debug": "subset",
                        "gc": "bounded",
                        "engine": "vm",
                        "optimize": "Debug",
                        "capabilities": {"os": "disabled", "filesystem": "disabled", "process": "disabled", "dynamic_loading": "disabled"},
                        "dynamic_loading": "disabled",
                        "sbf_experimental": False,
                    }
                )
            )
            fake = FakeRunner(
                [
                    result(["git", "rev-parse", "HEAD"], repo, stdout="abc123\n"),
                    result(["zig", "build", "-Dprofile=native-full", "--summary", "all"], repo),
                    result([str(native_artifact)], repo, stdout="ziglua profile smoke marker=0x5a1a55\n"),
                    result(["zig", "build", "-Dprofile=wasm-constrained", "--summary", "all"], repo),
                    result(["zig", "test", "src/ziglua/wasm_profile_stub.zig"], repo, stdout="All 2 tests passed\n"),
                    result(
                        ["node", "tools/validation/wasm_smoke_runner.js", str(wasm_artifact)],
                        repo,
                        stdout=json.dumps(
                            {
                                "state": "pass",
                                "runtime": "node-webassembly",
                                "exports": {
                                    name: {
                                        "state": "pass",
                                        "expected": f"0x{return_code:08x}",
                                        "actual": f"0x{return_code:08x}",
                                    }
                                    for name, return_code in baseline_oracle.CROSS_TARGET_WASM_EXPECTED_RETURNS.items()
                                },
                            }
                        ),
                    ),
                    result(["zig", "build", "-Dprofile=native-full", "--summary", "all"], repo),
                    result(["zig", "build", "-Dprofile=wasm-constrained", "--summary", "all"], repo),
                    result(baseline_oracle.DARWIN_BUILD_COMMAND, repo),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_cross_target_packaging()

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["native"]["smoke"]["state"], "pass")
            self.assertEqual(summary["wasm"]["smoke"]["state"], "pass")
            self.assertEqual(summary["wasm"]["artifact_evidence"]["state"], "pass")
            self.assertEqual(summary["wasm"]["host_harness"]["state"], "pass")
            self.assertIn("ziglua_wasm_core_subset_smoke", summary["wasm"]["artifact_evidence"]["exports"])
            self.assertTrue(summary["wasm"]["artifact_evidence"]["code_section"]["body_count"])
            self.assertEqual(summary["wasm"]["artifact_evidence"]["core_subset_smoke"]["body_return_evidence"]["state"], "pass")
            self.assertTrue(all(probe["state"] == "capability-denied" for probe in summary["wasm"]["capability_probes"]))
            self.assertTrue(all(entry["state"] == "pass" for entry in summary["reproducibility"]["profiles"]))
            self.assertEqual({entry["profile"] for entry in summary["artifacts"]}, {"native-full", "wasm-constrained"})
            for entry in summary["artifacts"]:
                self.assertEqual(entry["source_revision"], "abc123")
                self.assertTrue(entry["sha256"])
                self.assertTrue(entry["artifact_path"])
                self.assertIn("feature_gates", entry)
            self.assertEqual(summary["c_baseline"]["state"], "pass")
            self.assertTrue(Path(summary["manifest_path"]).exists())

    def test_wasm_artifact_evidence_rejects_metadata_only_probe(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            wasm_artifact = repo / "zig-out" / "bin" / "ziglua-wasm-constrained.wasm"
            wasm_artifact.parent.mkdir(parents=True)
            wasm_artifact.write_bytes(b"\x00asm\x01\x00\x00\x00profile-stub")

            evidence = baseline_oracle.wasm_artifact_evidence(
                wasm_artifact,
                {
                    "capabilities": {
                        "os": "disabled",
                        "filesystem": "disabled",
                        "process": "disabled",
                        "dynamic_loading": "disabled",
                    }
                },
            )

            self.assertEqual(evidence["state"], "fail")
            self.assertTrue(any("missing wasm export" in error for error in evidence["errors"]), evidence["errors"])
            self.assertFalse(evidence["core_subset_smoke"]["artifact_export_present"])

    def test_wasm_artifact_evidence_rejects_export_section_only_pseudo_wasm(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            wasm_artifact = repo / "zig-out" / "bin" / "ziglua-wasm-constrained.wasm"
            wasm_artifact.parent.mkdir(parents=True)
            wasm_artifact.write_bytes(wasm_export_fixture(baseline_oracle.CROSS_TARGET_WASM_REQUIRED_EXPORTS))

            evidence = baseline_oracle.wasm_artifact_evidence(
                wasm_artifact,
                {
                    "capabilities": {
                        "os": "disabled",
                        "filesystem": "disabled",
                        "process": "disabled",
                        "dynamic_loading": "disabled",
                    }
                },
            )

            self.assertEqual(evidence["state"], "fail")
            self.assertTrue(any("missing wasm function/code section" in error for error in evidence["errors"]), evidence["errors"])
            self.assertEqual(evidence["core_subset_smoke"]["body_return_evidence"]["state"], "fail")

    def test_cross_target_profile_matrix_checks_required_fields_and_expected_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            profile_dir = repo / "zig-out" / "share" / "ziglua" / "profiles"
            profile_dir.mkdir(parents=True)
            for profile, target_arch, stdlib, dynamic_loading, sbf in [
                ("native-full", "aarch64", "full", "enabled", False),
                ("wasm-constrained", "wasm32", "constrained", "disabled", False),
                ("sbf-experimental", "bpfel", "minimal", "disabled", True),
            ]:
                (profile_dir / f"{profile}.json").write_text(
                    json.dumps(
                        {
                            "profile": profile,
                            "target": "native" if profile == "native-full" else "wasm32-freestanding" if profile == "wasm-constrained" else "bpfel-freestanding",
                            "target_arch": target_arch,
                            "target_os": "macos" if profile == "native-full" else "freestanding",
                            "allocator": "host" if profile == "native-full" else "bounded",
                            "stdlib": stdlib,
                            "debug": "full" if profile == "native-full" else "subset" if profile == "wasm-constrained" else "disabled",
                            "gc": "lua-compatible" if profile == "native-full" else "bounded" if profile == "wasm-constrained" else "spike-only",
                            "engine": "vm-aot" if profile == "native-full" else "vm" if profile == "wasm-constrained" else "vm-subset-spike",
                            "optimize": "Debug",
                            "capabilities": {"os": dynamic_loading, "filesystem": dynamic_loading, "process": dynamic_loading, "dynamic_loading": dynamic_loading},
                            "dynamic_loading": dynamic_loading,
                            "sbf_experimental": sbf,
                            "sbf_status": "experimental-spike-only" if sbf else "not-applicable",
                            "artifact_kind": "metadata-only" if sbf else "native-executable" if profile == "native-full" else "wasm-artifact",
                            "sbf_notes": "experimental spike only; metadata-only feasibility report" if sbf else "not an SBF profile",
                            "sbf_scope": "metadata-only experimental spike report" if sbf else "not-applicable",
                            "sbf_toolchain_observation": "Zig 0.16.0 exposes bpfel-freestanding target metadata for feasibility analysis" if sbf else "not-applicable",
                            "sbf_binary_size_note": "no deployable SBF artifact emitted; binary size measurement unavailable until proof build" if sbf else "not-applicable",
                            "sbf_memory_note": "bounded memory allocator profile records heap and stack risk for later constrained proof" if sbf else "not-applicable",
                            "sbf_compute_note": "compute budget risk is report-only until a measured constrained proof exists" if sbf else "not-applicable",
                        }
                    )
                )
            fake_results = [
                result(["zig", "build", "-Dprofile=native-full", "--summary", "all"], repo),
                result(["zig", "build", "-Dprofile=wasm-constrained", "--summary", "all"], repo),
                result(["zig", "build", "-Dprofile=sbf-experimental", "--summary", "all"], repo),
            ]
            for flag in ("-Dos=enabled", "-Dfilesystem=enabled", "-Dprocess=enabled", "-Ddynamic-loading=enabled"):
                fake_results.append(
                    result(
                        ["zig", "build", "-Dprofile=wasm-constrained", flag, "--summary", "all"],
                        repo,
                        stderr="error: capability denied\n",
                        exit_code=1,
                    )
                )
            for flag in ("-Dos=enabled", "-Dfilesystem=enabled", "-Dprocess=enabled", "-Ddynamic-loading=enabled"):
                fake_results.append(
                    result(
                        ["zig", "build", "-Dprofile=sbf-experimental", flag, "--summary", "all"],
                        repo,
                        stderr="error: capability denied for sbf-experimental\n",
                        exit_code=1,
                    )
                )
            fake = FakeRunner(fake_results)
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_cross_target_profile_matrix()

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["profile_count"], 3)
            self.assertEqual(summary["expected_failure_count"], 8)
            self.assertTrue(all(entry["state"] == "pass" for entry in summary["profiles"]))
            self.assertTrue(all(probe["state"] == "pass" for probe in summary["expected_failure_probes"]))

    def test_sbf_spike_report_validation_blocks_forbidden_claims(self):
        safe_metadata = {
            "profile": "sbf-experimental",
            "target": "bpfel-freestanding",
            "target_arch": "bpfel",
            "target_os": "freestanding",
            "allocator": "bounded",
            "stdlib": "minimal",
            "debug": "disabled",
            "gc": "spike-only",
            "engine": "vm-subset-spike",
            "optimize": "Debug",
            "artifact_kind": "metadata-only",
            "capabilities": {"os": "disabled", "filesystem": "disabled", "process": "disabled", "dynamic_loading": "disabled"},
            "dynamic_loading": "disabled",
            "sbf_experimental": True,
            "sbf_status": "experimental-spike-only",
            "sbf_notes": "experimental spike only; metadata-only feasibility report",
            "sbf_scope": "metadata-only experimental spike report",
            "sbf_toolchain_observation": "Zig 0.16.0 exposes bpfel-freestanding target metadata for feasibility analysis",
            "sbf_binary_size_note": "no deployable SBF artifact emitted; binary size measurement unavailable until proof build",
            "sbf_memory_note": "bounded memory allocator profile records heap and stack risk for later constrained proof",
            "sbf_compute_note": "compute budget risk is report-only until a measured constrained proof exists",
        }

        self.assertEqual(baseline_oracle.cross_target_metadata_errors("sbf-experimental", safe_metadata), [])
        for forbidden in (
            "SBF is production-ready",
            "supports full Lua semantics",
            "includes full stdlib",
            "provides full C API ABI",
            "dynamic loading support is available",
            "Solana production runtime",
        ):
            with self.subTest(forbidden=forbidden):
                metadata = dict(safe_metadata)
                metadata["sbf_notes"] = forbidden
                errors = baseline_oracle.cross_target_metadata_errors("sbf-experimental", metadata)
                self.assertTrue(any("forbidden SBF claim" in error for error in errors), errors)

    def test_sbf_spike_report_runner_writes_machine_checkable_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            profile_dir = repo / "zig-out" / "share" / "ziglua" / "profiles"
            profile_dir.mkdir(parents=True)
            (profile_dir / "sbf-experimental.json").write_text(
                json.dumps(
                    {
                        "profile": "sbf-experimental",
                        "target": "bpfel-freestanding",
                        "target_arch": "bpfel",
                        "target_os": "freestanding",
                        "allocator": "bounded",
                        "stdlib": "minimal",
                        "debug": "disabled",
                        "gc": "spike-only",
                        "engine": "vm-subset-spike",
                        "optimize": "Debug",
                        "artifact_kind": "metadata-only",
                        "capabilities": {"os": "disabled", "filesystem": "disabled", "process": "disabled", "dynamic_loading": "disabled"},
                        "dynamic_loading": "disabled",
                        "sbf_experimental": True,
                        "sbf_status": "experimental-spike-only",
                        "sbf_notes": "experimental spike only; metadata-only feasibility report",
                        "sbf_scope": "metadata-only experimental spike report",
                        "sbf_toolchain_observation": "Zig 0.16.0 exposes bpfel-freestanding target metadata for feasibility analysis",
                        "sbf_binary_size_note": "no deployable SBF artifact emitted; binary size measurement unavailable until proof build",
                        "sbf_memory_note": "bounded memory allocator profile records heap and stack risk for later constrained proof",
                        "sbf_compute_note": "compute budget risk is report-only until a measured constrained proof exists",
                    }
                )
            )
            fake = FakeRunner([result(["zig", "build", "sbf-spike", "-Dprofile=sbf-experimental", "--summary", "all"], repo)])
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_sbf_spike_report()

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["metadata"]["artifact_kind"], "metadata-only")
            self.assertEqual(summary["wording_validation"]["state"], "pass")
            self.assertTrue(Path(summary["summary_path"]).exists())

    def test_validator_discovery_lists_cli_only_cross_target_validators(self):
        repo = Path("/repo")

        summary = baseline_oracle.validator_registry(repo)

        self.assertEqual(summary["state"], "pass")
        validator_ids = {entry["id"] for entry in summary["validators"]}
        self.assertIn("cross-target-packaging", validator_ids)
        self.assertIn("cross-target-profile-matrix", validator_ids)
        self.assertIn("sbf-spike-report", validator_ids)
        self.assertIn("cross-area-integration-validation", validator_ids)
        self.assertIn("lua-zig-run-cli-parity", validator_ids)
        self.assertTrue(all(entry["surface"] == "cli" for entry in summary["validators"]))
        self.assertTrue(all(not entry["requires_service"] for entry in summary["validators"]))
        self.assertTrue(all("command" in entry for entry in summary["validators"]))

    def test_run_parity_native_assertions_reject_stock_lua_fallback_evidence(self):
        repo = Path("/repo")
        oracle = baseline_oracle.BaselineOracle(repo, repo / "build")

        errors = oracle.validate_run_evidence(
            ["VAL-CLI-002", "VAL-NATIVE-003"],
            {"implementation_mode": "stock-lua-fallback", "no_host_lua": False, "validates": ["VAL-CLI-002"]},
            expected_no_host_lua=True,
        )

        self.assertTrue(any("cannot be satisfied" in error for error in errors))
        self.assertTrue(any("no_host_lua" in error for error in errors))

    def test_native_core_coverage_requires_multiple_native_no_host_fixtures(self):
        entries = []
        for case in baseline_oracle.NATIVE_CORE_LANGUAGE_CASES:
            entries.append(
                {
                    "name": case["name"],
                    "puc_file": case["puc_file"],
                    "validates": case["validates"],
                    "coverage_tags": case["coverage_tags"],
                    "state": "pass",
                    "implementation_mode": "native",
                    "no_host_lua": True,
                    "fallback_observed": False,
                    "unsupported_observed": False,
                }
            )

        coverage, errors = baseline_oracle.validate_native_core_coverage(entries)

        self.assertEqual(errors, [])
        self.assertGreaterEqual(coverage["VAL-NATIVE-004"]["case_count"], 4)
        self.assertIn("literal:table-constructor", coverage["VAL-NATIVE-004"]["tags"])
        self.assertGreaterEqual(coverage["VAL-NATIVE-006"]["case_count"], 4)
        self.assertIn("vararg:main-chunk", coverage["VAL-NATIVE-006"]["tags"])
        self.assertGreaterEqual(coverage["VAL-NATIVE-008"]["case_count"], 5)
        self.assertIn("coercion:overflow-error", coverage["VAL-NATIVE-008"]["tags"])
        self.assertIn("diagnostic:bitwise-coercion", coverage["VAL-NATIVE-010"]["tags"])
        self.assertIn("closure:loop-variable-numeric-for", coverage["VAL-NATIVE-012"]["tags"])
        self.assertIn("closure:loop-variable-generic-for", coverage["VAL-NATIVE-012"]["tags"])

    def test_native_core_coverage_rejects_fallback_or_missing_evidence(self):
        entries = [
            {
                "name": "single-fallback-literal",
                "puc_file": "literals.lua",
                "validates": ["VAL-NATIVE-004"],
                "coverage_tags": ["literal:nil-boolean"],
                "state": "pass",
                "implementation_mode": "stock-lua-fallback",
                "no_host_lua": False,
                "fallback_observed": True,
                "unsupported_observed": False,
            },
            {
                "name": "missing-evidence-vararg",
                "puc_file": "vararg.lua",
                "validates": ["VAL-NATIVE-006"],
                "state": "pass",
            },
        ]

        _, errors = baseline_oracle.validate_native_core_coverage(entries)

        self.assertTrue(any("without native/no_host_lua evidence" in error for error in errors), errors)
        self.assertTrue(any("missing evidence fields" in error for error in errors), errors)
        self.assertTrue(any("VAL-NATIVE-004 requires at least" in error for error in errors), errors)

    def test_native_core_coverage_requires_numeric_and_generic_loop_closure_tags(self):
        entries = []
        for case in baseline_oracle.NATIVE_CORE_LANGUAGE_CASES:
            tags = [
                tag
                for tag in case["coverage_tags"]
                if tag not in {"closure:loop-variable-numeric-for", "closure:loop-variable-generic-for"}
            ]
            entries.append(
                {
                    "name": case["name"],
                    "puc_file": case["puc_file"],
                    "validates": case["validates"],
                    "coverage_tags": tags,
                    "state": "pass",
                    "implementation_mode": "native",
                    "no_host_lua": True,
                    "fallback_observed": False,
                    "unsupported_observed": False,
                }
            )

        coverage, errors = baseline_oracle.validate_native_core_coverage(entries)

        self.assertIn("closure:loop-variable", coverage["VAL-NATIVE-012"]["tags"])
        self.assertTrue(
            any(
                "VAL-NATIVE-012 missing required native coverage tags" in error
                and "closure:loop-variable-numeric-for" in error
                and "closure:loop-variable-generic-for" in error
                for error in errors
            ),
            errors,
        )

    def test_native_core_coverage_rejects_non_native_loop_closure_evidence(self):
        entries = []
        for case in baseline_oracle.NATIVE_CORE_LANGUAGE_CASES:
            is_loop_closure = "closure:loop-variable" in case["coverage_tags"]
            entries.append(
                {
                    "name": case["name"],
                    "puc_file": case["puc_file"],
                    "validates": case["validates"],
                    "coverage_tags": case["coverage_tags"],
                    "state": "pass",
                    "implementation_mode": "stock-lua-fallback" if is_loop_closure else "native",
                    "no_host_lua": False if is_loop_closure else True,
                    "fallback_observed": True if is_loop_closure else False,
                    "unsupported_observed": False,
                }
            )

        coverage, errors = baseline_oracle.validate_native_core_coverage(entries)

        self.assertNotIn("closure:loop-variable-numeric-for", coverage["VAL-NATIVE-012"]["tags"])
        self.assertNotIn("closure:loop-variable-generic-for", coverage["VAL-NATIVE-012"]["tags"])
        self.assertTrue(any("without native/no_host_lua evidence" in error for error in errors), errors)
        self.assertTrue(
            any(
                "VAL-NATIVE-012 missing required native coverage tags" in error
                and "closure:loop-variable-numeric-for" in error
                and "closure:loop-variable-generic-for" in error
                for error in errors
            ),
            errors,
        )

    def test_packaged_advanced_smokes_run_protected_and_metatable_native_fixtures(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            protected_fixture = next(
                item for item in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES if item["reason"] == "protected-error"
            )
            metatable_fixture = next(
                item for item in baseline_oracle.ADVANCED_SEMANTICS_FIXTURES if item["reason"] == "metatable-dispatch"
            )
            vm_command = ["./zig-out/bin/ziglua-vm"]
            fake = FakeRunner(
                [
                    result(["./lua", "-"], repo, stdout=str(protected_fixture["stock_stdout"])),
                    result(
                        vm_command,
                        repo,
                        stdout=str(protected_fixture["stock_stdout"]),
                        stderr="ziglua-vm: fallback-pass reason=protected-error\n",
                    ),
                    result(["./lua", "-"], repo, stdout=str(metatable_fixture["stock_stdout"])),
                    result(
                        vm_command,
                        repo,
                        stdout=str(metatable_fixture["stock_stdout"]),
                        stderr="ziglua-vm: fallback-pass reason=metatable-dispatch\n",
                    ),
                ]
            )
            oracle = baseline_oracle.BaselineOracle(repo, repo / "build", runner=fake)

            summary = oracle.run_cross_area_packaged_advanced_smokes(
                vm_command,
                {"wasm": {"capability_probes": [{"state": "capability-denied"}], "smoke": {"state": "pass"}}},
            )

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(summary["pass_count"], 2)
            self.assertEqual(summary["native"]["state"], "pass")
            self.assertEqual(
                [smoke["reason"] for smoke in summary["native"]["smokes"]],
                ["protected-error", "metatable-dispatch"],
            )
            self.assertEqual(summary["native"]["fixture_states"]["protected-error"], "pass")
            self.assertEqual(summary["native"]["fixture_states"]["metatable-dispatch"], "pass")
            self.assertEqual(summary["native_metatable_smoke"]["state"], "pass")
            self.assertIn("metatable", summary["classification"])
            native_calls = [call for call in fake.calls if call["command"] == vm_command]
            self.assertEqual([call["stdin"] for call in native_calls], [protected_fixture["source"], metatable_fixture["source"]])

    def test_cross_area_integration_summary_orchestrates_required_flows_and_taxonomy(self):
        class RecordingIntegrationOracle(baseline_oracle.BaselineOracle):
            def __init__(self, repo, out_dir):
                super().__init__(repo, out_dir)
                self.calls = []

            def run_build(self):
                self.calls.append("build")
                return {"state": "pass"}

            def run_cross_area_runtime_smoke(self, vm_command, aot_command):
                self.calls.append(("runtime-smoke", vm_command, aot_command))
                return {"state": "pass", "pass_count": 1}

            def run_vm_dynamic_fallback(self, vm_command):
                self.calls.append(("vm-dynamic", vm_command))
                return {"state": "pass", "fallback_pass_count": 1, "unsupported_count": 1, "fail_count": 0}

            def run_aot_artifact_matrix(self, vm_command, aot_command):
                self.calls.append(("aot-artifact", vm_command, aot_command))
                return {"state": "pass", "artifact_count": 2, "fail_count": 0}

            def run_aot_dynamic_fallback(self, aot_command):
                self.calls.append(("aot-dynamic", aot_command))
                return {"state": "pass", "fallback_pass_count": 1, "unsupported_count": 1, "fail_count": 0}

            def run_vm_advanced_fallback(self, vm_command):
                self.calls.append(("vm-advanced", vm_command))
                return {"state": "pass", "fallback_pass_count": 1, "unsupported_unfulfilled_count": 0, "fail_count": 0}

            def run_aot_advanced_fallback(self, aot_command, vm_command=None):
                self.calls.append(("aot-advanced", aot_command, vm_command))
                return {"state": "pass", "shared_classification_count": 1, "unsupported_count": 0, "fail_count": 0}

            def run_cross_target_packaging(self):
                self.calls.append("packaging")
                return {
                    "state": "pass",
                    "wasm": {"capability_probes": [{"state": "capability-denied"}]},
                    "native": {"smoke": {"state": "pass"}},
                }

            def run_cross_area_packaged_advanced_smokes(self, vm_command, packaging_summary):
                self.calls.append(("packaged-advanced", vm_command, packaging_summary["state"]))
                return {"state": "pass", "pass_count": 1, "expected_skip_count": 1, "unsupported_count": 0, "fail_count": 0}

            def run_selected_tests(self):
                self.calls.append("selected-tests")
                return {"state": "pass", "pass_count": 2}

        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            oracle = RecordingIntegrationOracle(repo, repo / "build")

            summary = oracle.run_cross_area_integration_validation(
                baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND,
                baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND,
            )

            self.assertEqual(summary["state"], "pass")
            self.assertEqual(
                oracle.calls,
                [
                    "build",
                    ("runtime-smoke", baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND),
                    ("vm-dynamic", baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND),
                    ("aot-artifact", baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND),
                    ("aot-dynamic", baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND),
                    ("vm-advanced", baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND),
                    ("aot-advanced", baseline_oracle.DEFAULT_ZIG_AOT_CANDIDATE_COMMAND, baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND),
                    "packaging",
                    ("packaged-advanced", baseline_oracle.DEFAULT_ZIG_VM_CANDIDATE_COMMAND, "pass"),
                    "selected-tests",
                ],
            )
            self.assertEqual(summary["c_baseline_preservation"]["state"], "pass")
            self.assertEqual(summary["vm_aot_observability"]["state"], "pass")
            self.assertGreater(summary["taxonomy_counts"]["pass"], 0)
            self.assertGreater(summary["taxonomy_counts"]["expected-skip"], 0)
            self.assertGreater(summary["taxonomy_counts"]["unsupported"], 0)
            self.assertEqual(summary["taxonomy_counts"]["fail"], 0)
            self.assertTrue(Path(summary["summary_path"]).exists())

    def test_integration_taxonomy_counts_do_not_count_fallback_as_native_pass(self):
        counts = baseline_oracle.integration_taxonomy_counts(
            {
                "native": {"state": "pass", "pass_count": 2},
                "fallback": {"state": "pass", "fallback_pass_count": 3},
                "shared": {"state": "pass", "shared_classification_count": 4},
                "unsupported": {"state": "unfulfilled", "unsupported_count": 1},
                "blocked": {"state": "pass", "blocked_count": 1},
            }
        )

        # Four top-level areas passed plus two native pass fixtures; fallback classifications
        # are reported separately and never inflate the native/pass fixture count.
        self.assertEqual(counts["pass"], 6)
        self.assertEqual(counts["fallback-pass"], 7)
        self.assertEqual(counts["unsupported"], 2)
        self.assertEqual(counts["blocked"], 1)

    def test_cross_area_integration_fails_when_required_component_fails(self):
        class FailingIntegrationOracle(baseline_oracle.BaselineOracle):
            def run_build(self):
                return {"state": "pass"}

            def run_cross_area_runtime_smoke(self, vm_command, aot_command):
                return {"state": "fail", "fail_count": 1}

            def run_vm_dynamic_fallback(self, vm_command):
                return {"state": "pass"}

            def run_aot_artifact_matrix(self, vm_command, aot_command):
                return {"state": "pass"}

            def run_aot_dynamic_fallback(self, aot_command):
                return {"state": "pass"}

            def run_vm_advanced_fallback(self, vm_command):
                return {"state": "pass"}

            def run_aot_advanced_fallback(self, aot_command, vm_command=None):
                return {"state": "pass"}

            def run_cross_target_packaging(self):
                return {"state": "pass"}

            def run_cross_area_packaged_advanced_smokes(self, vm_command, packaging_summary):
                return {"state": "pass"}

            def run_selected_tests(self):
                return {"state": "pass"}

        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            oracle = FailingIntegrationOracle(repo, repo / "build")

            summary = oracle.run_cross_area_integration_validation()

            self.assertEqual(summary["state"], "fail")
            self.assertGreaterEqual(summary["taxonomy_counts"]["fail"], 1)
            self.assertEqual(summary["areas"]["runtime_smoke"]["state"], "fail")


if __name__ == "__main__":
    unittest.main()
