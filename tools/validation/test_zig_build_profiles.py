import json
import subprocess
import unittest
from pathlib import Path

import baseline_oracle


REPO = Path(__file__).resolve().parents[2]


def run_zig_build(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["zig", "build", *args],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def read_profile_metadata(profile: str) -> dict[str, object]:
    return json.loads((REPO / "zig-out" / "share" / "ziglua" / "profiles" / f"{profile}.json").read_text())


class ZigBuildProfileTests(unittest.TestCase):
    def test_native_full_profile_generates_machine_checkable_metadata(self):
        completed = run_zig_build("-Dprofile=native-full", "--summary", "all")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        metadata = read_profile_metadata("native-full")
        self.assertEqual(metadata["profile"], "native-full")
        self.assertEqual(metadata["stdlib"], "full")
        self.assertEqual(metadata["allocator"], "host")
        self.assertEqual(metadata["debug"], "full")
        self.assertEqual(metadata["gc"], "lua-compatible")
        self.assertEqual(metadata["engine"], "vm-aot")
        self.assertEqual(metadata["dynamic_loading"], "enabled")
        self.assertFalse(metadata["sbf_experimental"])
        self.assertIn(metadata["target_arch"], ["aarch64", "x86_64"])

    def test_wasm_constrained_profile_defaults_to_wasm_and_disables_host_capabilities(self):
        completed = run_zig_build("-Dprofile=wasm-constrained", "--summary", "all")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        metadata = read_profile_metadata("wasm-constrained")
        self.assertEqual(metadata["profile"], "wasm-constrained")
        self.assertEqual(metadata["target_arch"], "wasm32")
        self.assertEqual(metadata["stdlib"], "constrained")
        self.assertEqual(metadata["allocator"], "bounded")
        self.assertEqual(metadata["debug"], "subset")
        self.assertEqual(metadata["gc"], "bounded")
        self.assertEqual(metadata["engine"], "vm")
        self.assertEqual(metadata["dynamic_loading"], "disabled")
        self.assertFalse(metadata["sbf_experimental"])

    def test_sbf_experimental_profile_is_metadata_only_and_spike_scoped(self):
        completed = run_zig_build("sbf-spike", "-Dprofile=sbf-experimental", "--summary", "all")

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        metadata = read_profile_metadata("sbf-experimental")
        self.assertEqual(metadata["profile"], "sbf-experimental")
        self.assertEqual(metadata["target_arch"], "bpfel")
        self.assertEqual(metadata["artifact_kind"], "metadata-only")
        self.assertTrue(metadata["sbf_experimental"])
        self.assertEqual(metadata["sbf_status"], "experimental-spike-only")
        self.assertIn("experimental spike only", metadata["sbf_notes"])
        self.assertIn("metadata-only", metadata["sbf_scope"])
        self.assertIn("Zig", metadata["sbf_toolchain_observation"])
        self.assertIn("bpfel-freestanding", metadata["sbf_toolchain_observation"])
        self.assertIn("no deployable", metadata["sbf_binary_size_note"])
        self.assertIn("bounded", metadata["sbf_memory_note"])
        self.assertIn("compute", metadata["sbf_compute_note"])

    def test_invalid_profile_fails_fast_with_accepted_profile_names(self):
        completed = run_zig_build("-Dprofile=invalid-profile", "--summary", "all")

        self.assertNotEqual(completed.returncode, 0)
        output = completed.stderr + completed.stdout
        self.assertIn("invalid profile", output)
        self.assertIn("native-full", output)
        self.assertIn("wasm-constrained", output)
        self.assertIn("sbf-experimental", output)

    def test_invalid_profile_target_combination_fails_fast(self):
        completed = run_zig_build("-Dprofile=wasm-constrained", "-Dtarget=aarch64-macos", "--summary", "all")

        self.assertNotEqual(completed.returncode, 0)
        output = completed.stderr + completed.stdout
        self.assertIn("invalid profile/target combination", output)
        self.assertIn("wasm-constrained", output)
        self.assertIn("wasm32", output)

    def test_sbf_experimental_rejects_native_target_combination(self):
        completed = run_zig_build("-Dprofile=sbf-experimental", "-Dtarget=aarch64-macos", "--summary", "all")

        self.assertNotEqual(completed.returncode, 0)
        output = completed.stderr + completed.stdout
        self.assertIn("invalid profile/target combination", output)
        self.assertIn("sbf-experimental", output)
        self.assertIn("bpfel-freestanding", output)

    def test_allocator_feature_flag_accepts_supported_modes(self):
        for allocator in ("host", "arena", "bounded", "failing"):
            with self.subTest(allocator=allocator):
                completed = run_zig_build(
                    "-Dprofile=native-full",
                    f"-Dallocator={allocator}",
                    "--summary",
                    "all",
                )

                self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
                metadata = read_profile_metadata("native-full")
                self.assertEqual(metadata["allocator"], allocator)

    def test_wasm_constrained_allocator_modes_are_build_test_gated(self):
        for allocator in ("bounded", "failing"):
            with self.subTest(allocator=allocator):
                completed = run_zig_build(
                    "test",
                    "-Dprofile=wasm-constrained",
                    f"-Dallocator={allocator}",
                    "--summary",
                    "all",
                )

                self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
                metadata = read_profile_metadata("wasm-constrained")
                self.assertEqual(metadata["allocator"], allocator)

        for allocator in ("host", "arena"):
            with self.subTest(allocator=allocator):
                completed = run_zig_build(
                    "test",
                    "-Dprofile=wasm-constrained",
                    f"-Dallocator={allocator}",
                    "--summary",
                    "all",
                )

                self.assertNotEqual(completed.returncode, 0)
                output = completed.stderr + completed.stdout
                self.assertIn("allocator", output)
                self.assertIn("wasm-constrained", output)

    def test_invalid_feature_flag_values_fail_fast(self):
        invalid_cases = [
            ("-Dallocator=invalid", "allocator", "host"),
            ("-Dstdlib=invalid", "stdlib", "full"),
            ("-Ddebug=maybe", "debug", "true"),
            ("-Dgc=invalid", "gc", "lua-compatible"),
            ("-Dengine=invalid", "engine", "vm"),
            ("-Dos=maybe", "os", "enabled"),
            ("-Dfilesystem=maybe", "filesystem", "enabled"),
            ("-Dprocess=maybe", "process", "enabled"),
            ("-Ddynamic-loading=maybe", "dynamic-loading", "enabled"),
        ]

        for flag, label, accepted_value in invalid_cases:
            with self.subTest(flag=flag):
                completed = run_zig_build(flag, "--summary", "all")

                self.assertNotEqual(completed.returncode, 0)
                output = completed.stderr + completed.stdout
                self.assertIn(f"invalid {label}", output)
                self.assertIn(accepted_value, output)

    def test_wasm_constrained_accepts_constrained_stdlib_and_rejects_host_capabilities(self):
        completed = run_zig_build(
            "-Dprofile=wasm-constrained",
            "-Dstdlib=constrained",
            "--summary",
            "all",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        metadata = read_profile_metadata("wasm-constrained")
        self.assertEqual(metadata["stdlib"], "constrained")
        self.assertEqual(metadata["capabilities"]["os"], "disabled")
        self.assertEqual(metadata["capabilities"]["filesystem"], "disabled")
        self.assertEqual(metadata["capabilities"]["process"], "disabled")
        self.assertEqual(metadata["capabilities"]["dynamic_loading"], "disabled")

        disallowed = [
            ("-Dos=enabled", "os"),
            ("-Dfilesystem=enabled", "filesystem"),
            ("-Dprocess=enabled", "process"),
            ("-Ddynamic-loading=enabled", "dynamic-loading"),
        ]
        for flag, capability in disallowed:
            with self.subTest(flag=flag):
                completed = run_zig_build(
                    "-Dprofile=wasm-constrained",
                    "-Dstdlib=constrained",
                    flag,
                    "--summary",
                    "all",
                )

                self.assertNotEqual(completed.returncode, 0)
                output = completed.stderr + completed.stdout
                self.assertIn("capability", output)
                self.assertIn(capability, output)
                self.assertIn("wasm-constrained", output)

    def test_debug_gc_and_engine_flags_are_profile_scoped_and_reflected_in_metadata(self):
        native = run_zig_build(
            "-Dprofile=native-full",
            "-Ddebug=true",
            "-Dgc=lua-compatible",
            "-Dengine=vm",
            "--summary",
            "all",
        )
        self.assertEqual(native.returncode, 0, native.stderr + native.stdout)
        native_metadata = read_profile_metadata("native-full")
        self.assertEqual(native_metadata["debug"], "full")
        self.assertEqual(native_metadata["gc"], "lua-compatible")
        self.assertEqual(native_metadata["engine"], "vm")

        wasm = run_zig_build(
            "-Dprofile=wasm-constrained",
            "-Dgc=bounded",
            "-Dengine=aot",
            "--summary",
            "all",
        )
        self.assertEqual(wasm.returncode, 0, wasm.stderr + wasm.stdout)
        wasm_metadata = read_profile_metadata("wasm-constrained")
        self.assertEqual(wasm_metadata["debug"], "subset")
        self.assertEqual(wasm_metadata["gc"], "bounded")
        self.assertEqual(wasm_metadata["engine"], "aot")
        self.assertEqual(wasm_metadata["dynamic_semantics_fallback"], "vm-required")
        self.assertIn("load", wasm_metadata["dynamic_semantics_fallback_reasons"])

        sbf_gc = run_zig_build(
            "-Dprofile=sbf-experimental",
            "-Dgc=lua-compatible",
            "--summary",
            "all",
        )
        self.assertNotEqual(sbf_gc.returncode, 0)
        self.assertIn("gc", sbf_gc.stderr + sbf_gc.stdout)

    def test_sbf_experimental_debug_flag_is_explicitly_gated(self):
        for disabled_value in ("false", "disabled"):
            with self.subTest(debug=disabled_value):
                completed = run_zig_build(
                    "-Dprofile=sbf-experimental",
                    f"-Ddebug={disabled_value}",
                    "--summary",
                    "all",
                )

                self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
                metadata = read_profile_metadata("sbf-experimental")
                self.assertEqual(metadata["debug"], "disabled")

        completed = run_zig_build(
            "-Dprofile=sbf-experimental",
            "-Ddebug=true",
            "--summary",
            "all",
        )
        self.assertNotEqual(completed.returncode, 0)
        output = completed.stderr + completed.stdout
        self.assertIn("debug", output)
        self.assertIn("sbf-experimental", output)
        self.assertIn("disabled", output)

    def test_sbf_experimental_rejects_host_capabilities_and_marks_fallback_metadata(self):
        completed = run_zig_build(
            "-Dprofile=sbf-experimental",
            "-Dallocator=bounded",
            "-Dengine=vm",
            "--summary",
            "all",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        metadata = read_profile_metadata("sbf-experimental")
        self.assertEqual(metadata["artifact_kind"], "metadata-only")
        self.assertEqual(metadata["stdlib"], "minimal")
        self.assertEqual(metadata["debug"], "disabled")
        self.assertEqual(metadata["gc"], "spike-only")
        self.assertEqual(metadata["engine"], "vm")
        self.assertEqual(metadata["capabilities"]["os"], "disabled")
        self.assertEqual(metadata["capabilities"]["filesystem"], "disabled")
        self.assertEqual(metadata["capabilities"]["process"], "disabled")
        self.assertEqual(metadata["capabilities"]["dynamic_loading"], "disabled")
        self.assertEqual(metadata["dynamic_semantics_fallback"], "vm-required")
        self.assertTrue(metadata["sbf_experimental"])
        self.assertFalse(baseline_oracle.sbf_forbidden_claim_errors(metadata))

        completed = run_zig_build(
            "-Dprofile=sbf-experimental",
            "-Ddynamic-loading=enabled",
            "--summary",
            "all",
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("dynamic-loading", completed.stderr + completed.stdout)


if __name__ == "__main__":
    unittest.main()
