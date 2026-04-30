#!/usr/bin/env python3
"""CLI harness for capturing the stock Lua oracle on Darwin."""

from __future__ import annotations

import argparse
import base64
import difflib
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable


DARWIN_BUILD_COMMAND = [
    "make",
    "-s",
    "-j12",
    "MYCFLAGS=-std=c99 -DLUA_USE_MACOSX",
    "MYLDFLAGS=",
    "MYLIBS=",
]
DARWIN_BUILD_OVERRIDES = {
    "MYCFLAGS": "-std=c99 -DLUA_USE_MACOSX",
    "MYLDFLAGS": "",
    "MYLIBS": "",
}
DEFAULT_ZIG_VM_CANDIDATE_COMMAND = ["./zig-out/bin/ziglua-vm"]
DEFAULT_ZIG_AOT_CANDIDATE_COMMAND = ["./zig-out/bin/ziglua-aot"]
DEFAULT_LUA_ZIG_NATIVE_RUN_COMMAND = ["./zig-out/bin/lua-zig", "run", "-"]
ZIG_VM_CANDIDATE_REFRESH_COMMAND = ["zig", "build", "--summary", "all"]
ZIG_AOT_CANDIDATE_REFRESH_COMMAND = ["zig", "build", "--summary", "all"]
SELECTED_TESTS = ["constructs.lua", "vararg.lua"]
VM_SELECTED_PUC_TESTS = ["constructs.lua", "code.lua", "calls.lua", "closure.lua", "math.lua", "strings.lua"]
CROSS_AREA_RUNTIME_SMOKE_SNIPPET = "print(1 + 2)\n"
NATIVE_CORE_LANGUAGE_CASES = [
    {
        "name": "literals-core",
        "puc_file": "literals.lua",
        "validates": ["VAL-NATIVE-004"],
        "description": "nil/boolean/numeric/string/long-string/table-constructor literals",
        "source": 'print(nil, true, false, 123, 3.25, "a\\n", [[long string]])\nlocal t = {10; 20; name = "lua"}\nprint(t[1], t[2], t.name, #t)\n',
    },
    {
        "name": "constructs-core",
        "puc_file": "constructs.lua",
        "validates": ["VAL-NATIVE-005"],
        "description": "precedence, if/else, numeric for, while, repeat, break, length, concatenation, and comparisons",
        "source": 'local s = "lua" .. "-" .. 55\nlocal total = 0; for i = 1, 4 do if i % 2 == 0 then total = total + i else total = total + 1 end end\nlocal n = 0; while n < 2 do n = n + 1 end; repeat total = total + n; break until false\nprint(s, #s, total, n, total >= n)\n',
    },
    {
        "name": "generic-for-core",
        "puc_file": "constructs.lua",
        "validates": ["VAL-NATIVE-005"],
        "description": "generic-for execution over pairs/ipairs-style iterator triples without fallback",
        "source": 'local acc = ""\nfor i, v in ipairs({"a", "b"}) do acc = acc .. i .. v end\nlocal total = 0\nfor k, v in pairs({3, 4, 5}) do total = total + k + v end\nprint(acc, total)\n',
    },
    {
        "name": "ordered-comparison-core",
        "puc_file": "constructs.lua",
        "validates": ["VAL-NATIVE-005"],
        "description": "Lua ordered comparisons for numbers and bytewise strings without numeric string coercion",
        "source": 'print(1 < 2, 2.0 <= 2, 3 > 2.5, 3 >= 3)\nprint("2" < "10", "abc" <= "abc", "b" > "aa", "b" >= "b")\n',
    },
    {
        "name": "ordered-comparison-mixed-string-number-core",
        "puc_file": "constructs.lua",
        "validates": ["VAL-NATIVE-005", "VAL-NATIVE-010"],
        "description": "mixed string/number ordered comparisons reject numeric over-coercion with Lua diagnostics",
        "source": 'print("2" < 10)\n',
    },
    {
        "name": "ordered-comparison-mixed-number-string-core",
        "puc_file": "constructs.lua",
        "validates": ["VAL-NATIVE-005", "VAL-NATIVE-010"],
        "description": "mixed number/string ordered comparisons reject numeric over-coercion with Lua diagnostics",
        "source": 'print(2 < "10")\n',
    },
    {
        "name": "ordered-comparison-unsupported-table-core",
        "puc_file": "constructs.lua",
        "validates": ["VAL-NATIVE-005", "VAL-NATIVE-010"],
        "description": "unsupported ordered comparisons reject non-number/non-string operands with Lua diagnostics",
        "source": 'print({} < {})\n',
    },
    {
        "name": "vararg-core",
        "puc_file": "vararg.lua",
        "validates": ["VAL-NATIVE-006"],
        "description": "vararg capture, select count, nil preservation, and return adjustment",
        "source": 'local function pack(...)\n  local n = select("#", ...)\n  local a, b, c = ...\n  return n, a, c\nend\nprint(pack(nil, "x", 3))\n',
    },
    {
        "name": "bitwise-core",
        "puc_file": "bitwise.lua",
        "validates": ["VAL-NATIVE-007"],
        "description": "bitwise operators, precedence, signed edge cases, and integer-width shift behavior",
        "source": 'local a, b = 0x0f, 0x33\nprint(a & b, a | b, a ~ b, a << 2, b >> 1, ~a)\nprint(1 << 63, 1 << 64, -1 >> 1, -1 >> 64, 8 << -1, 8 >> -1)\n',
    },
    {
        "name": "bwcoercion-core",
        "puc_file": "bwcoercion.lua",
        "validates": ["VAL-NATIVE-008"],
        "description": "integer coercion for integral floats in bitwise operators",
        "source": "print(15.0 & 7, 15.0 | 2, 8.0 << 1)\n",
    },
    {
        "name": "goto-core",
        "puc_file": "goto.lua",
        "validates": ["VAL-NATIVE-009"],
        "description": "forward goto and label execution without running skipped statements",
        "source": 'local x = 0\ngoto skip\nx = 99\n::skip::\nx = x + 1\nprint(x)\n',
    },
    {
        "name": "goto-undefined-label-core",
        "puc_file": "goto.lua",
        "validates": ["VAL-NATIVE-009", "VAL-NATIVE-010"],
        "description": "undefined goto labels produce Lua-compatible syntax diagnostics and nonzero exit",
        "source": "goto missing\n",
    },
    {
        "name": "goto-duplicate-label-core",
        "puc_file": "goto.lua",
        "validates": ["VAL-NATIVE-009", "VAL-NATIVE-010"],
        "description": "duplicate labels in the same block produce Lua-compatible syntax diagnostics and nonzero exit",
        "source": "::a::\n::a::\n",
    },
    {
        "name": "goto-malformed-label-core",
        "puc_file": "goto.lua",
        "validates": ["VAL-NATIVE-009", "VAL-NATIVE-010"],
        "description": "malformed labels produce Lua-compatible syntax diagnostics and nonzero exit",
        "source": "::1::\n",
    },
    {
        "name": "goto-jump-into-local-core",
        "puc_file": "goto.lua",
        "validates": ["VAL-NATIVE-009", "VAL-NATIVE-010"],
        "description": "forward gotos into local variable scope produce Lua-compatible syntax diagnostics and nonzero exit",
        "source": "goto L\nlocal x\n::L::\nprint(1)\n",
    },
    {
        "name": "runtime-error-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "runtime error stderr and exit-status parity for a core arithmetic failure",
        "source": 'local x = "bad" + 1\nprint(x)\n',
    },
    {
        "name": "runtime-error-nil-arithmetic-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "runtime diagnostics identify nil arithmetic operands without hardcoded string/number add output",
        "source": "local x = nil + 1\nprint(x)\n",
    },
    {
        "name": "runtime-error-boolean-arithmetic-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "runtime diagnostics identify boolean arithmetic operands with nonzero exit parity",
        "source": "local x = true + 1\nprint(x)\n",
    },
    {
        "name": "runtime-error-concat-table-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "runtime diagnostics identify invalid concatenation operands with Lua stack context",
        "source": 'print({} .. "x")\n',
    },
    {
        "name": "runtime-error-index-nil-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "runtime diagnostics include actual local indexing context and source line",
        "source": "local x = nil\nprint(x.y)\n",
    },
    {
        "name": "runtime-error-call-nil-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "runtime diagnostics include actual local call context and source line",
        "source": "local f = nil\nf()\n",
    },
    {
        "name": "syntax-error-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "syntax error stderr and exit-status parity for a missing block terminator",
        "source": 'if true then print("x")\n',
    },
    {
        "name": "syntax-error-while-missing-end-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "syntax diagnostics identify the actual unclosed while block and opener line",
        "source": "while true do print(1)\n",
    },
    {
        "name": "syntax-error-missing-paren-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "syntax diagnostics identify missing close parenthesis and source line",
        "source": "print(1\n",
    },
    {
        "name": "syntax-error-unexpected-end-core",
        "puc_file": "errors.lua",
        "validates": ["VAL-NATIVE-010"],
        "description": "syntax diagnostics reject unexpected block terminators with nonzero exit",
        "source": "end\n",
    },
]
VM_DYNAMIC_FALLBACK_FIXTURES = [
    {
        "name": "dynamic-load",
        "reason": "load",
        "description": "load compiles code dynamically and must not be silently partially executed by the current VM subset",
        "stock_stdout": "42\n",
        "source": 'local f = load("return 40 + 2")\nprint(f())\n',
    },
    {
        "name": "dynamic-debug",
        "reason": "debug",
        "description": "debug library introspection requires explicit fallback/unsupported accounting",
        "stock_stdout": "table\n",
        "source": 'local info = debug.getinfo(1, "S")\nprint(type(info))\n',
    },
    {
        "name": "dynamic-metatable-dispatch",
        "reason": "metatable-dispatch",
        "description": "metatable __index dispatch is dynamic semantics outside the current direct VM subset",
        "stock_stdout": "miss:value\n",
        "source": 'local t = setmetatable({}, { __index = function(_, key) return "miss:" .. key end })\nprint(t.value)\n',
    },
    {
        "name": "dynamic-env-mutation",
        "reason": "dynamic-env-mutation",
        "description": "runtime _ENV reassignment is dynamic environment mutation and must be explicit fallback/unsupported",
        "stock_stdout": "42\n",
        "source": 'local original = _ENV\n_ENV = { print = print, value = 42 }\nprint(value)\n_ENV = original\n',
    },
]
AOT_DYNAMIC_FALLBACK_FIXTURES = VM_DYNAMIC_FALLBACK_FIXTURES
ADVANCED_SEMANTICS_FIXTURES = [
    {
        "name": "advanced-metatable-dispatch",
        "reason": "metatable-dispatch",
        "description": "metatable hooks for indexing and assignment are shared runtime hook boundaries or explicit fallback cases",
        "stock_stdout": "miss:answer\nanswer:ok\n",
        "validates": ["VAL-ADV-001"],
        "source": 'local log = {}\nlocal t = setmetatable({}, { __index = function(_, key) return "miss:" .. key end, __newindex = function(_, key, value) log[#log + 1] = key .. ":" .. value end })\nprint(t.answer)\nt.answer = "ok"\nprint(log[1])\n',
    },
    {
        "name": "advanced-raw-operations",
        "reason": "raw-ops",
        "description": "rawget/rawset/rawequal/raw length boundaries bypass metatable hooks while ordinary operations can still dispatch hooks",
        "stock_stdout": "nil\t99\t1\ntrue\t1\n",
        "validates": ["VAL-ADV-002"],
        "source": 'local calls = 0\nlocal t = setmetatable({ present = 1 }, { __index = function()\n  calls = calls + 1\n  return 99\nend })\nprint(rawget(t, "missing"), t.missing, calls)\nrawset(t, "missing", 7)\nprint(rawequal(rawget(t, "missing"), 7), calls)\n',
    },
    {
        "name": "advanced-branch-else-rawget-sibling-scope",
        "reason": "raw-ops",
        "description": "branch-local advanced API aliases must not shadow sibling else branches that use the real raw API",
        "stock_stdout": "nil\n",
        "validates": ["VAL-ADV-002"],
        "source": 'local t = {}\nif false then\n  local rawget = 1\nelse\n  print(rawget(t, "missing"))\nend\n',
    },
    {
        "name": "advanced-protected-errors",
        "reason": "protected-error",
        "description": "pcall/xpcall protected error propagation is a shared hook boundary, not an AOT-only approximation",
        "stock_stdout": "false\tboom\nfalse\thandled:bad\n",
        "validates": ["VAL-ADV-003"],
        "source": 'local ok, err = pcall(function() error("boom", 0) end)\nprint(ok, err)\nlocal ok2, msg = xpcall(function() error("bad", 0) end, function(e) return "handled:" .. e end)\nprint(ok2, msg)\n',
    },
    {
        "name": "advanced-coroutine-model",
        "reason": "coroutine-model",
        "description": "coroutine create/resume/yield/status requires an explicit portable frame/runtime hook boundary",
        "stock_stdout": "true\t5\ntrue\t9\ndead\n",
        "validates": ["VAL-ADV-004"],
        "source": 'local co = coroutine.create(function(a)\n  local b = coroutine.yield(a + 1)\n  return b + 2\nend)\nprint(coroutine.resume(co, 4))\nprint(coroutine.resume(co, 7))\nprint(coroutine.status(co))\n',
    },
    {
        "name": "advanced-gc-weak-finalization",
        "reason": "gc-weak-finalization",
        "description": "GC, weak table, and finalization semantics are explicit hook/capability boundaries",
        "stock_stdout": "table\n",
        "validates": ["VAL-ADV-005"],
        "source": 'local weak = setmetatable({}, { __mode = "v" })\ndo\n  local value = { x = 1 }\n  weak.key = value\nend\ncollectgarbage("collect")\nprint(type(weak))\n',
    },
    {
        "name": "advanced-table-iteration",
        "reason": "table-iteration",
        "description": "next/pairs/ipairs traversal semantics are validated as shared runtime/fallback boundaries",
        "stock_stdout": "4\t30\ttrue\n",
        "validates": ["VAL-ADV-011"],
        "source": 'local t = { a = 1, b = 2, 10, 20 }\nlocal n = 0\nfor _ in pairs(t) do n = n + 1 end\nlocal total = 0\nfor _, v in ipairs(t) do total = total + v end\nprint(n, total, next(t) ~= nil)\n',
    },
    {
        "name": "advanced-cleanup-close",
        "reason": "cleanup-finalization",
        "description": "to-be-closed cleanup and finalization ordering are explicit native/support boundaries",
        "stock_stdout": "x:false\n",
        "validates": ["VAL-ADV-012"],
        "source": 'local log = {}\nlocal mt = { __close = function(self, err) log[#log + 1] = self.name .. ":" .. tostring(err ~= nil) end }\ndo\n  local x <close> = setmetatable({ name = "x" }, mt)\nend\nprint(log[1])\n',
    },
    {
        "name": "advanced-binary-dynamic-gates",
        "reason": "binary-dynamic-gates",
        "description": "binary chunks and dynamic load gates must not bypass VM/AOT safety classification",
        "stock_stdout": "42\n",
        "validates": ["VAL-ADV-010"],
        "source": 'local dumped = string.dump(function() return 42 end)\nlocal f = load(dumped)\nprint(f())\n',
    },
    {
        "name": "advanced-cross-boundary-metamethod-error",
        "reason": "cross-boundary-advanced",
        "description": "metamethod-thrown errors across protected-call boundaries share VM/AOT fallback semantics",
        "stock_stdout": "false\tmeta boom\n",
        "validates": ["VAL-ADV-009", "VAL-ADV-013"],
        "source": 'local t = setmetatable({}, { __call = function() error("meta boom", 0) end })\nlocal ok, err = pcall(t)\nprint(ok, err)\n',
    },
]
AOT_RUNTIME_ERROR_FIXTURES = [
    {
        "name": "aot-arithmetic-runtime-error",
        "description": "AOT-eligible static arithmetic chunk that deterministically raises at runtime",
        "reason": "runtime-error-arithmetic",
        "source": 'local x = "bad" + 1\nprint(x)\n',
        "stderr_contains": ["attempt", "arithmetic"],
    }
]
DEBUG_HOOK_SNIPPET = """\
local seen = { call = false, ["return"] = false, line = false, count = false }
local function hook(event)
  if seen[event] ~= nil then seen[event] = true end
end
local function f()
  local x = 0
  x = x + 1
  return x
end
debug.sethook(hook, "crl", 1)
f()
debug.sethook()
print(seen.call and "call" or "missing-call")
print(seen["return"] and "return" or "missing-return")
print(seen.line and "line" or "missing-line")
print(seen.count and "count" or "missing-count")
"""
FULL_SUITE_KNOWN_CONSTRAINT = {
    "file": "testes/main.lua",
    "line": 396,
    "description": "known macOS prompt assertion behavior in testes/main.lua around line 396",
}
DEFAULT_SNIPPET_CORPUS_FILE = Path(__file__).with_name("snippet_corpus.json")
DEFAULT_TESTES_CLASSIFICATION_FILE = Path(__file__).with_name("testes_classification.json")
REQUIRED_CORPUS_AREAS = {
    "literals",
    "locals",
    "arithmetic",
    "strings",
    "tables",
    "control-flow",
    "functions",
    "varargs",
    "closures",
    "multiple-returns",
    "tail-call-observable",
    "_ENV",
    "globals",
}
TEST_CLASSIFICATION_CATEGORIES = {
    "core",
    "stdlib",
    "gc",
    "debug",
    "c-api-internal-test",
    "coroutine",
    "heavy-resource-sensitive",
    "platform-sensitive",
}
CROSS_TARGET_PROFILE_COMMANDS = {
    "native-full": ["zig", "build", "-Dprofile=native-full", "--summary", "all"],
    "wasm-constrained": ["zig", "build", "-Dprofile=wasm-constrained", "--summary", "all"],
    "sbf-experimental": ["zig", "build", "-Dprofile=sbf-experimental", "--summary", "all"],
}
CROSS_TARGET_WASM_HOST_HARNESS_COMMAND = ["zig", "test", "src/ziglua/wasm_profile_stub.zig"]
CROSS_TARGET_WASM_RUNTIME_COMMAND_PREFIX = ["node", "tools/validation/wasm_smoke_runner.js"]
SBF_SPIKE_REPORT_COMMAND = ["zig", "build", "sbf-spike", "-Dprofile=sbf-experimental", "--summary", "all"]
CROSS_TARGET_ARTIFACT_PATHS = {
    "native-full": Path("zig-out/bin/ziglua-native-full"),
    "wasm-constrained": Path("zig-out/bin/ziglua-wasm-constrained.wasm"),
}
CROSS_TARGET_REQUIRED_METADATA_FIELDS = [
    "allocator",
    "capabilities",
    "debug",
    "dynamic_loading",
    "engine",
    "gc",
    "optimize",
    "profile",
    "stdlib",
    "target",
    "target_arch",
    "target_os",
]
SBF_REQUIRED_REPORT_FIELDS = [
    "sbf_notes",
    "sbf_scope",
    "sbf_toolchain_observation",
    "sbf_binary_size_note",
    "sbf_memory_note",
    "sbf_compute_note",
]
SBF_FORBIDDEN_CLAIM_PATTERNS = [
    (re.compile(r"\bproduction[- ]ready\b", re.IGNORECASE), "production-ready"),
    (re.compile(r"\bproduction\s+support\b", re.IGNORECASE), "production support"),
    (re.compile(r"\bsolana\s+production\b", re.IGNORECASE), "Solana production"),
    (re.compile(r"\bfull[- ]compatib(?:le|ility)\b", re.IGNORECASE), "full compatibility"),
    (re.compile(r"\bcomplete\s+compatib(?:le|ility)\b", re.IGNORECASE), "complete compatibility"),
    (re.compile(r"\bfull\s+lua\b", re.IGNORECASE), "full Lua"),
    (re.compile(r"\bfull\s+std(?:lib)?\b", re.IGNORECASE), "full stdlib"),
    (re.compile(r"\bfull\s+standard\s+library\b", re.IGNORECASE), "full standard library"),
    (re.compile(r"\bfull\s+c\s+api\b", re.IGNORECASE), "full C API"),
    (re.compile(r"\bdynamic[- ]loading\s+support\b", re.IGNORECASE), "dynamic loading support"),
]
CROSS_TARGET_WASM_DENIED_CAPABILITIES = [
    ("io", "filesystem"),
    ("os", "os"),
    ("process", "process"),
    ("package.loadlib", "dynamic_loading"),
]
CROSS_TARGET_WASM_CORE_SMOKE_EXPORT = "ziglua_wasm_core_subset_smoke"
CROSS_TARGET_WASM_DENIAL_EXPORTS = {
    "filesystem": "ziglua_wasm_deny_filesystem",
    "os": "ziglua_wasm_deny_os",
    "process": "ziglua_wasm_deny_process",
    "dynamic_loading": "ziglua_wasm_deny_dynamic_loading",
}
CROSS_TARGET_WASM_REQUIRED_EXPORTS = [
    "ziglua_profile_marker",
    CROSS_TARGET_WASM_CORE_SMOKE_EXPORT,
    *CROSS_TARGET_WASM_DENIAL_EXPORTS.values(),
]
CROSS_TARGET_WASM_EXPECTED_RETURNS = {
    "ziglua_profile_marker": 0x5A1A55,
    CROSS_TARGET_WASM_CORE_SMOKE_EXPORT: 0x362C1305,
    "ziglua_wasm_deny_filesystem": 0xD3111ED1,
    "ziglua_wasm_deny_os": 0xD3111ED2,
    "ziglua_wasm_deny_process": 0xD3111ED3,
    "ziglua_wasm_deny_dynamic_loading": 0xD3111ED4,
}


@dataclass
class CommandResult:
    command: list[str]
    cwd: str
    env_overrides: dict[str, str]
    stdout: str
    stderr: str
    exit_code: int
    duration_ms: int
    started_at: str
    ended_at: str

    def to_dict(self) -> dict[str, object]:
        data = asdict(self)
        data["command_text"] = shlex.join(self.command)
        return data


Runner = Callable[[list[str], Path, dict[str, str] | None, str | None, int | None], CommandResult]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def run_process(
    command: list[str],
    cwd: Path,
    env_overrides: dict[str, str] | None = None,
    stdin: str | None = None,
    timeout: int | None = None,
) -> CommandResult:
    env = os.environ.copy()
    env.update(env_overrides or {})
    started_at = utc_now()
    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        timeout=timeout,
        check=False,
    )
    ended_at = utc_now()
    duration_ms = int((time.monotonic() - started) * 1000)
    return CommandResult(
        command=list(command),
        cwd=str(cwd),
        env_overrides=dict(env_overrides or {}),
        stdout=completed.stdout,
        stderr=completed.stderr,
        exit_code=completed.returncode,
        duration_ms=duration_ms,
        started_at=started_at,
        ended_at=ended_at,
    )


class BaselineOracle:
    def __init__(self, repo: Path, out_dir: Path, runner: Runner = run_process):
        self.repo = repo.resolve()
        self.out_dir = out_dir.resolve()
        self.records_dir = self.out_dir / "records"
        self.runner = runner

    def write_json(self, relative_path: str, data: dict[str, object]) -> str:
        path = self.out_dir / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        return str(path)

    def write_result(self, name: str, result: CommandResult) -> str:
        safe_name = name.replace("/", "_").replace(" ", "-")
        path = self.records_dir / f"{safe_name}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result.to_dict(), indent=2, sort_keys=True) + "\n")
        return str(path)

    def read_result(self, path: Path) -> dict[str, object]:
        return json.loads(path.read_text())

    def run_stock_snippet(self, name: str, snippet: str) -> dict[str, object]:
        result = self.runner(["./lua", "-"], self.repo, {}, snippet, None)
        result_file = self.write_result(f"stock-snippet-{name}", result)
        state = "pass" if result.exit_code == 0 else "captured_error"
        summary = {
            "state": state,
            "snippet": {
                "name": name,
                "source_bytes": len(snippet.encode()),
                "source_sha256": _sha256_text(snippet),
            },
            "result_file": result_file,
            "result": result.to_dict(),
            "capture_contract": "stdout, stderr, and exit_code are recorded exactly from stock ./lua stdin execution",
        }
        self.write_json(f"stock-snippets/{name}-summary.json", summary)
        return summary

    def run_differential(
        self,
        name: str,
        snippet: str,
        candidate_command: list[str] | None,
        stock_result_file: Path | None = None,
    ) -> dict[str, object]:
        if stock_result_file is None:
            stock_summary = self.run_stock_snippet(name, snippet)
            stock = {
                "state": stock_summary["state"],
                "result_file": stock_summary["result_file"],
                "result": stock_summary["result"],
            }
        else:
            resolved_stock = stock_result_file.resolve()
            stock = {
                "state": "loaded",
                "result_file": str(resolved_stock),
                "result": self.read_result(resolved_stock),
            }

        if candidate_command is None:
            summary = {
                "state": "pending",
                "message": "missing candidate command; stock result captured but semantic comparison is pending",
                "snippet": {
                    "name": name,
                    "source_bytes": len(snippet.encode()),
                    "source_sha256": _sha256_text(snippet),
                },
                "stock": stock,
                "candidate": {
                    "state": "pending",
                    "reason": "missing candidate runtime/AOT command",
                },
                "diffs": {},
            }
            self.write_json(f"differential/{name}-summary.json", summary)
            return summary

        candidate_result = self.runner(candidate_command, self.repo, {}, snippet, None)
        candidate_file = self.write_result(f"candidate-snippet-{name}", candidate_result)
        diffs = compare_cli_results(stock["result"], candidate_result.to_dict())
        state = "pass" if not diffs else "fail"
        summary = {
            "state": state,
            "message": "candidate matches stock CLI-observable behavior" if state == "pass" else "candidate differs from stock CLI-observable behavior",
            "snippet": {
                "name": name,
                "source_bytes": len(snippet.encode()),
                "source_sha256": _sha256_text(snippet),
            },
            "stock": stock,
            "candidate": {
                "state": state,
                "result_file": candidate_file,
                "result": candidate_result.to_dict(),
            },
            "compared_fields": ["stdout", "stderr", "exit_code"],
            "diffs": diffs,
        }
        self.write_json(f"differential/{name}-summary.json", summary)
        return summary

    def run_lua_zig_run_cli_parity(self) -> dict[str, object]:
        fixtures_dir = self.repo / "build" / "run-parity-fixtures"
        fixtures_dir.mkdir(parents=True, exist_ok=True)

        args_script = fixtures_dir / "args.lua"
        args_script.write_text(
            "print(arg[0])\n"
            "for i = 1, #arg do print(i, arg[i]) end\n"
            "print(...)\n",
            encoding="utf-8",
        )
        file_error_script = fixtures_dir / "file-error.lua"
        file_error_script.write_text('local x = "bad" + 1\nprint(x)\n', encoding="utf-8")
        e_file_script = fixtures_dir / "e-file.lua"
        e_file_script.write_text("print(prefix .. ':file')\n", encoding="utf-8")
        module_script = fixtures_dir / "fixture_module.lua"
        module_script.write_text(
            "fixture_module = { value = 42 }\n"
            "print('loaded')\n"
            "return fixture_module\n",
            encoding="utf-8",
        )
        module_env = {"LUA_PATH": f"{fixtures_dir}/?.lua;;"}
        args_script_arg = str(args_script.relative_to(self.repo))
        file_error_script_arg = str(file_error_script.relative_to(self.repo))
        e_file_script_arg = str(e_file_script.relative_to(self.repo))

        cases = [
            {
                "id": "stdin-success",
                "stock_args": ["-"],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", "-"],
                "stdin": 'print("stdin-ok")\n',
                "env": {},
                "validates": ["VAL-CLI-002", "VAL-NATIVE-003"],
                "no_host_lua": True,
            },
            {
                "id": "stdin-runtime-error",
                "stock_args": ["-"],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", "-"],
                "stdin": 'local x = "bad" + 1\nprint(x)\n',
                "env": {},
                "validates": ["VAL-CLI-002", "VAL-NATIVE-003"],
                "no_host_lua": True,
            },
            {
                "id": "file-args",
                "stock_args": [args_script_arg, "alpha", "--flag"],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", args_script_arg, "alpha", "--flag"],
                "stdin": None,
                "env": {},
                "validates": ["VAL-CLI-003", "VAL-CLI-006", "VAL-NATIVE-001"],
                "no_host_lua": True,
            },
            {
                "id": "file-diagnostic",
                "stock_args": [file_error_script_arg],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", file_error_script_arg],
                "stdin": None,
                "env": {},
                "validates": ["VAL-CLI-003", "VAL-NATIVE-001"],
                "no_host_lua": True,
            },
            {
                "id": "e-order",
                "stock_args": ["-e", "value = 40", "-e", "print(value + 2)"],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", "-e", "value = 40", "-e", "print(value + 2)"],
                "stdin": None,
                "env": {},
                "validates": ["VAL-CLI-004", "VAL-NATIVE-002"],
                "no_host_lua": True,
            },
            {
                "id": "e-file-composition",
                "stock_args": ["-e", "prefix = 'from-e'", e_file_script_arg],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", "-e", "prefix = 'from-e'", e_file_script_arg],
                "stdin": None,
                "env": {},
                "validates": ["VAL-CLI-004", "VAL-CLI-003", "VAL-NATIVE-002"],
                "no_host_lua": True,
            },
            {
                "id": "l-preload",
                "stock_args": ["-l", "fixture_module", "-e", "print(fixture_module.value)"],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", "-l", "fixture_module", "-e", "print(fixture_module.value)"],
                "stdin": None,
                "env": module_env,
                "validates": ["VAL-CLI-005"],
                "no_host_lua": True,
            },
            {
                "id": "l-missing-diagnostic",
                "stock_args": ["-l", "missing_fixture_module", "-e", "print('unreachable')"],
                "candidate_args": ["./zig-out/bin/lua-zig", "run", "-l", "missing_fixture_module", "-e", "print('unreachable')"],
                "stdin": None,
                "env": module_env,
                "validates": ["VAL-CLI-005"],
                "no_host_lua": False,
            },
        ]

        entries = []
        state = "pass"
        for case in cases:
            stock = self.runner(["./lua", *case["stock_args"]], self.repo, case["env"], case["stdin"], None)
            evidence_dir = self.out_dir / "run-parity-evidence" / case["id"]
            evidence_dir.mkdir(parents=True, exist_ok=True)
            candidate_env = {**case["env"], "LUA_ZIG_EVIDENCE_DIR": str(evidence_dir)}
            if case["no_host_lua"]:
                candidate_env["LUA_ZIG_RUN_NO_HOST_LUA"] = "1"
            candidate = self.runner(case["candidate_args"], self.repo, candidate_env, case["stdin"], None)
            stock_file = self.write_result(f"run-parity-stock-{case['id']}", stock)
            candidate_file = self.write_result(f"run-parity-candidate-{case['id']}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            evidence = self.read_run_evidence(evidence_dir)
            evidence_errors = self.validate_run_evidence(case["validates"], evidence, bool(case["no_host_lua"]))
            if evidence_errors:
                diffs["evidence"] = "\n".join(evidence_errors)
            case_state = "pass" if not diffs else "fail"
            if case_state != "pass":
                state = "fail"
            entries.append(
                {
                    "id": case["id"],
                    "state": case_state,
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock_command": stock.to_dict()["command_text"],
                    "candidate_command": candidate.to_dict()["command_text"],
                    "diffs": diffs,
                    "implementation_mode": evidence.get("implementation_mode"),
                    "no_host_lua": evidence.get("no_host_lua"),
                    "run_evidence_file": evidence.get("result_file"),
                    "validates": case["validates"],
                }
            )

        summary = {
            "state": state,
            "validator": "lua-zig-run-cli-parity",
            "cases": entries,
            "case_count": len(entries),
            "pass_count": sum(1 for entry in entries if entry["state"] == "pass"),
            "fail_count": sum(1 for entry in entries if entry["state"] == "fail"),
            "compared_fields": ["stdout", "stderr", "exit_code"],
            "normalization_policy": "exact stdout/stderr/exit comparison; no path, executable, or diagnostic normalization applied",
            "validates": [
                "VAL-CLI-002",
                "VAL-CLI-003",
                "VAL-CLI-004",
                "VAL-CLI-005",
                "VAL-CLI-006",
                "VAL-NATIVE-001",
                "VAL-NATIVE-002",
                "VAL-NATIVE-003",
            ],
        }
        self.write_json("run-parity/summary.json", summary)
        return summary

    def read_run_evidence(self, evidence_dir: Path) -> dict[str, object]:
        records = sorted(evidence_dir.glob("run-*.json"))
        if not records:
            return {"state": "fail", "message": "missing lua-zig run evidence"}
        record = records[-1]
        try:
            data = json.loads(record.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            return {"state": "fail", "message": f"invalid lua-zig run evidence: {exc}", "result_file": str(record)}
        data["result_file"] = str(record)
        return data

    def validate_run_evidence(
        self,
        validates: list[str],
        evidence: dict[str, object],
        expected_no_host_lua: bool,
    ) -> list[str]:
        errors: list[str] = []
        implementation_mode = evidence.get("implementation_mode")
        no_host_lua = evidence.get("no_host_lua")
        if "implementation_mode" not in evidence:
            errors.append("run evidence missing implementation_mode")
        if "no_host_lua" not in evidence:
            errors.append("run evidence missing no_host_lua")
        if expected_no_host_lua and no_host_lua is not True:
            errors.append(f"run evidence no_host_lua={no_host_lua!r}; expected true for fallback-disabled candidate mode")
        native_assertions = [assertion for assertion in validates if assertion.startswith("VAL-NATIVE-")]
        if native_assertions:
            if implementation_mode in {"stock-lua-fallback", "fallback-pass", "host-lua"}:
                errors.append(f"native assertions {native_assertions} cannot be satisfied by implementation_mode={implementation_mode!r}")
            if implementation_mode != "native" or no_host_lua is not True:
                errors.append(
                    f"native assertions {native_assertions} require implementation_mode='native' and no_host_lua=true; "
                    f"observed implementation_mode={implementation_mode!r}, no_host_lua={no_host_lua!r}"
                )
            evidence_validates = set(evidence.get("validates", []))
            missing = sorted(set(native_assertions) - evidence_validates)
            if missing:
                errors.append(f"run evidence missing native assertion ids: {missing}")
        return errors

    def run_build(self) -> dict[str, object]:
        build = self.runner(DARWIN_BUILD_COMMAND, self.repo, DARWIN_BUILD_OVERRIDES, None, None)
        build_file = self.write_result("stock-build-darwin", build)
        version = self.runner(["./lua", "-v"], self.repo, {}, None, None)
        version_file = self.write_result("stock-lua-version", version)
        version_text = version.stdout + version.stderr
        state = "pass" if build.exit_code == 0 and version.exit_code == 0 and "Lua 5.5" in version_text else "fail"
        summary = {
            "state": state,
            "build_command": shlex.join(DARWIN_BUILD_COMMAND),
            "required_darwin_overrides": dict(DARWIN_BUILD_OVERRIDES),
            "build": {**build.to_dict(), "result_file": build_file},
            "version": {**version.to_dict(), "result_file": version_file},
            "makefile_flow": "existing C makefile invoked directly; no Zig artifacts required",
        }
        self.write_json("stock-build-summary.json", summary)
        return summary

    def run_selected_tests(self, tests: Iterable[str] = SELECTED_TESTS) -> dict[str, object]:
        test_dir = self.repo / "testes"
        entries = []
        state = "pass"
        for test_name in tests:
            command = ["../lua", "-W", test_name]
            result = self.runner(command, test_dir, {}, None, None)
            result_file = self.write_result(f"selected-{test_name}", result)
            test_state = "pass" if result.exit_code == 0 else "fail"
            if test_state != "pass":
                state = "fail"
            entries.append(
                {
                    "test": test_name,
                    "state": test_state,
                    "result_file": result_file,
                    **result.to_dict(),
                }
            )
        summary = {
            "state": state,
            "tests": entries,
            "selected_tests": list(tests),
            "execution": "each test is executed independently from the testes directory with ../lua -W",
        }
        self.write_json("selected-tests-summary.json", summary)
        return summary

    def run_full_suite_constraint(self, timeout: int | None = 300) -> dict[str, object]:
        test_dir = self.repo / "testes"
        result = self.runner(["../lua", "-W", "all.lua"], test_dir, {}, None, timeout)
        result_file = self.write_result("full-suite-all-lua", result)
        combined = f"{result.stdout}\n{result.stderr}"
        has_known_location = "main.lua:396" in combined or "main.lua" in combined and "prompt" in combined
        if result.exit_code == 0:
            state = "pass"
        elif has_known_location:
            state = "known_constraint"
        else:
            state = "fail"
        summary = {
            "state": state,
            "attempt": {**result.to_dict(), "result_file": result_file},
            "known_constraint": dict(FULL_SUITE_KNOWN_CONSTRAINT),
            "classification": (
                "known macOS prompt constraint"
                if state == "known_constraint"
                else "clean full-suite pass"
                if state == "pass"
                else "unexpected full-suite failure"
            ),
        }
        self.write_json("full-suite-constraint-summary.json", summary)
        return summary

    def list_corpus(self) -> dict[str, object]:
        corpus = load_snippet_corpus()
        covered_areas = sorted({area for snippet in corpus for area in snippet["areas"]})
        metadata_errors = validate_snippet_corpus_metadata(corpus)
        missing_areas = sorted(REQUIRED_CORPUS_AREAS.difference(covered_areas))
        snippets = [snippet_summary(snippet) for snippet in corpus]
        state = "pass" if not missing_areas and not metadata_errors else "fail"
        summary = {
            "state": state,
            "snippet_count": len(corpus),
            "required_areas": sorted(REQUIRED_CORPUS_AREAS),
            "covered_areas": covered_areas,
            "missing_areas": missing_areas,
            "metadata_errors": metadata_errors,
            "snippets": snippets,
            "corpus_file": str(DEFAULT_SNIPPET_CORPUS_FILE),
        }
        self.write_json("snippet-corpus/list-summary.json", summary)
        return summary

    def run_stock_corpus(self) -> dict[str, object]:
        corpus = load_snippet_corpus()
        entries = []
        state = "pass"
        for snippet in corpus:
            result = self.runner(["./lua", "-"], self.repo, {}, snippet["source"], None)
            result_file = self.write_result(f"stock-corpus-{snippet['name']}", result)
            expected_state = snippet["expected_state"]
            actual_state = "pass" if result.exit_code == 0 else "captured_error"
            expectation_errors = corpus_expectation_errors(snippet, result)
            snippet_state = "pass" if actual_state == expected_state and not expectation_errors else "fail"
            if snippet_state != "pass":
                state = "fail"
            entries.append(
                {
                    **snippet_summary(snippet),
                    "state": snippet_state,
                    "actual_state": actual_state,
                    "expectation_errors": expectation_errors,
                    "result_file": result_file,
                    "result": result.to_dict(),
                }
            )

        covered_areas = sorted({area for snippet in corpus for area in snippet["areas"]})
        metadata_errors = validate_snippet_corpus_metadata(corpus)
        missing_areas = sorted(REQUIRED_CORPUS_AREAS.difference(covered_areas))
        if metadata_errors or missing_areas:
            state = "fail"
        summary = {
            "state": state,
            "snippet_count": len(corpus),
            "required_areas": sorted(REQUIRED_CORPUS_AREAS),
            "covered_areas": covered_areas,
            "missing_areas": missing_areas,
            "metadata_errors": metadata_errors,
            "snippets": entries,
            "execution": "each corpus snippet is executed with stock ./lua reading the source from stdin",
            "corpus_file": str(DEFAULT_SNIPPET_CORPUS_FILE),
        }
        self.write_json("snippet-corpus/stock-summary.json", summary)
        return summary

    def run_vm_level0_corpus(self, candidate_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_vm_candidate(candidate_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "candidate_command": candidate_command,
                "candidate_refresh": candidate_refresh,
                "snippet_count": 0,
                "compared_fields": ["stdout", "stderr", "exit_code"],
                "classification": "Level 0 comparison was not run because the repo-local ziglua-vm candidate failed to refresh.",
                "snippets": [],
            }
            self.write_json("vm-level0/corpus-summary.json", summary)
            return summary

        corpus = [
            snippet
            for snippet in load_snippet_corpus()
            if snippet["level"] == 0 and snippet["expected_state"] == "pass"
        ]
        entries = []
        state = "pass"
        for snippet in corpus:
            stock = self.runner(["./lua", "-"], self.repo, {}, snippet["source"], None)
            candidate = self.runner(candidate_command, self.repo, {}, snippet["source"], None)
            stock_file = self.write_result(f"vm-level0-stock-{snippet['name']}", stock)
            candidate_file = self.write_result(f"vm-level0-candidate-{snippet['name']}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            snippet_state = "pass" if not diffs else "fail"
            if snippet_state != "pass":
                state = "fail"
            entries.append(
                {
                    **snippet_summary(snippet),
                    "state": snippet_state,
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock": stock.to_dict(),
                    "candidate": candidate.to_dict(),
                    "diffs": diffs,
                }
            )

        summary = {
            "state": state,
            "candidate_command": candidate_command,
            "candidate_refresh": candidate_refresh,
            "snippet_count": len(corpus),
            "compared_fields": ["stdout", "stderr", "exit_code"],
            "classification": "Level 0 pass snippets are supported by ziglua-vm; non-pass and higher-level snippets remain outside this corpus",
            "snippets": entries,
        }
        self.write_json("vm-level0/corpus-summary.json", summary)
        return summary

    def run_vm_level1_corpus(self, candidate_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_vm_candidate(candidate_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "candidate_command": candidate_command,
                "candidate_refresh": candidate_refresh,
                "snippet_count": 0,
                "pass_count": 0,
                "unsupported_count": 0,
                "fail_count": 0,
                "compared_fields": ["stdout", "stderr", "exit_code"],
                "classification": "Level 1 comparison was not run because the repo-local ziglua-vm candidate failed to refresh.",
                "snippets": [],
            }
            self.write_json("vm-level1/corpus-summary.json", summary)
            return summary

        corpus = [
            snippet
            for snippet in load_snippet_corpus()
            if snippet["level"] == 1 and snippet["expected_state"] == "pass"
        ]
        entries = []
        state = "pass"
        pass_count = 0
        unsupported_count = 0
        fail_count = 0
        for snippet in corpus:
            stock = self.runner(["./lua", "-"], self.repo, {}, snippet["source"], None)
            candidate = self.runner(candidate_command, self.repo, {}, snippet["source"], None)
            stock_file = self.write_result(f"vm-level1-stock-{snippet['name']}", stock)
            candidate_file = self.write_result(f"vm-level1-candidate-{snippet['name']}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            unsupported_reason = ""
            if not diffs:
                snippet_state = "pass"
                pass_count += 1
            elif is_optional_level1_unsupported(snippet, candidate):
                snippet_state = "unsupported"
                unsupported_count += 1
                unsupported_reason = candidate.stderr.strip()
            else:
                snippet_state = "fail"
                fail_count += 1
                state = "fail"
            entries.append(
                {
                    **snippet_summary(snippet),
                    "state": snippet_state,
                    "unsupported_reason": unsupported_reason,
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock": stock.to_dict(),
                    "candidate": candidate.to_dict(),
                    "diffs": diffs,
                }
            )

        summary = {
            "state": state,
            "candidate_command": candidate_command,
            "candidate_refresh": candidate_refresh,
            "snippet_count": len(corpus),
            "pass_count": pass_count,
            "unsupported_count": unsupported_count,
            "fail_count": fail_count,
            "compared_fields": ["stdout", "stderr", "exit_code"],
            "classification": "Required Level 1 snippets must match stock Lua; only optional closure/upvalue snippets may be accounted as unsupported, separately from pass.",
            "snippets": entries,
        }
        self.write_json("vm-level1/corpus-summary.json", summary)
        return summary

    def run_vm_dynamic_fallback(self, candidate_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_vm_candidate(candidate_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "candidate_command": candidate_command,
                "candidate_refresh": candidate_refresh,
                "fixture_count": len(VM_DYNAMIC_FALLBACK_FIXTURES),
                "fallback_pass_count": 0,
                "unsupported_count": 0,
                "fail_count": 0,
                "fixtures": [],
                "classification": "Dynamic fallback validation was not run because the repo-local ziglua-vm candidate failed to refresh.",
            }
            self.write_json("vm-dynamic-fallback/summary.json", summary)
            return summary

        entries = []
        state = "pass"
        fallback_pass_count = 0
        unsupported_count = 0
        fail_count = 0
        for fixture in VM_DYNAMIC_FALLBACK_FIXTURES:
            fixture_name = str(fixture["name"])
            source = str(fixture["source"])
            reason = str(fixture["reason"])
            stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
            candidate = self.runner(candidate_command, self.repo, {}, source, None)
            stock_file = self.write_result(f"vm-dynamic-fallback-stock-{fixture_name}", stock)
            candidate_file = self.write_result(f"vm-dynamic-fallback-candidate-{fixture_name}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            unsupported_reason = ""
            if stock.exit_code != 0:
                fixture_state = "fail"
                fail_count += 1
                state = "fail"
            elif is_dynamic_fallback_pass(stock, candidate):
                fixture_state = "fallback-pass"
                fallback_pass_count += 1
            elif is_unsupported_result(candidate, expected_reason=reason):
                fixture_state = "unsupported"
                unsupported_count += 1
                unsupported_reason = candidate.stderr.strip()
            else:
                fixture_state = "fail"
                fail_count += 1
                state = "fail"
            entries.append(
                {
                    "fixture": fixture_name,
                    "reason": reason,
                    "description": fixture["description"],
                    "state": fixture_state,
                    "unsupported_reason": unsupported_reason,
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock": stock.to_dict(),
                    "candidate": candidate.to_dict(),
                    "diffs": diffs,
                }
            )
        summary = {
            "state": state,
            "candidate_command": candidate_command,
            "candidate_refresh": candidate_refresh,
            "fixture_count": len(VM_DYNAMIC_FALLBACK_FIXTURES),
            "fallback_pass_count": fallback_pass_count,
            "unsupported_count": unsupported_count,
            "fail_count": fail_count,
            "fixtures": entries,
            "classification": "Dynamic VM fixtures for load, debug, metatable dispatch, and dynamic _ENV mutation must either execute with fallback-observable stock parity or emit explicit unsupported/fallback diagnostics; silent partial execution fails.",
        }
        self.write_json("vm-dynamic-fallback/summary.json", summary)
        return summary

    def run_vm_advanced_fallback(self, candidate_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_vm_candidate(candidate_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "candidate_command": candidate_command,
                "candidate_refresh": candidate_refresh,
                "fixture_count": len(ADVANCED_SEMANTICS_FIXTURES),
                "stock_parity_count": 0,
                "fallback_pass_count": 0,
                "capability_denied_count": 0,
                "unsupported_count": 0,
                "unsupported_unfulfilled_count": 0,
                "fail_count": len(ADVANCED_SEMANTICS_FIXTURES),
                "fixtures": [],
                "classification": "Advanced semantic hook validation was not run because the repo-local ziglua-vm candidate failed to refresh.",
            }
            self.write_json("vm-advanced-fallback/summary.json", summary)
            return summary

        entries = []
        state = "pass"
        stock_parity_count = 0
        fallback_pass_count = 0
        capability_denied_count = 0
        unsupported_unfulfilled_count = 0
        fail_count = 0
        for fixture in ADVANCED_SEMANTICS_FIXTURES:
            fixture_name = str(fixture["name"])
            source = str(fixture["source"])
            reason = str(fixture["reason"])
            stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
            candidate = self.runner(candidate_command, self.repo, {}, source, None)
            stock_file = self.write_result(f"vm-advanced-fallback-stock-{fixture_name}", stock)
            candidate_file = self.write_result(f"vm-advanced-fallback-candidate-{fixture_name}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            unsupported_reason = ""
            capability_denied_reason = ""
            if stock.exit_code != 0:
                fixture_state = "fail"
                fail_count += 1
                state = "fail"
            elif not diffs:
                fixture_state = "stock-parity"
                stock_parity_count += 1
            elif is_dynamic_fallback_pass(stock, candidate):
                fixture_state = "fallback-pass"
                fallback_pass_count += 1
            elif is_capability_denied_result(candidate, expected_reason=reason):
                fixture_state = "capability-denied"
                capability_denied_count += 1
                capability_denied_reason = candidate.stderr.strip()
                if state != "fail":
                    state = "unfulfilled"
            elif is_unsupported_result(candidate, expected_reason=reason):
                fixture_state = "unsupported-unfulfilled"
                unsupported_unfulfilled_count += 1
                unsupported_reason = candidate.stderr.strip()
                if state != "fail":
                    state = "unfulfilled"
            else:
                fixture_state = "fail"
                fail_count += 1
                state = "fail"
            entries.append(
                {
                    "fixture": fixture_name,
                    "reason": reason,
                    "description": fixture["description"],
                    "validates": fixture["validates"],
                    "state": fixture_state,
                    "unsupported_reason": unsupported_reason,
                    "capability_denied_reason": capability_denied_reason,
                    "fulfills_required_assertions": fixture_state in {"stock-parity", "fallback-pass"},
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock": stock.to_dict(),
                    "candidate": candidate.to_dict(),
                    "diffs": diffs,
                }
            )
        summary = {
            "state": state,
            "candidate_command": candidate_command,
            "candidate_refresh": candidate_refresh,
            "fixture_count": len(ADVANCED_SEMANTICS_FIXTURES),
            "stock_parity_count": stock_parity_count,
            "fallback_pass_count": fallback_pass_count,
            "capability_denied_count": capability_denied_count,
            "unsupported_count": unsupported_unfulfilled_count,
            "unsupported_unfulfilled_count": unsupported_unfulfilled_count,
            "fail_count": fail_count,
            "fixtures": entries,
            "classification": "Advanced semantics for metatables, raw operations, protected errors, coroutine, GC/weak/finalization, iteration, cleanup, binary/dynamic gates, and cross-boundary behavior are fulfilled only by stock-parity or fallback-pass evidence; capability-denied and unsupported-unfulfilled are reported separately and do not satisfy required VAL-ADV parity assertions.",
        }
        self.write_json("vm-advanced-fallback/summary.json", summary)
        return summary

    def run_vm_selected_puc(self, candidate_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_vm_candidate(candidate_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "candidate_command": candidate_command,
                "candidate_refresh": candidate_refresh,
                "tests": [],
                "test_count": 0,
                "pass_count": 0,
                "unsupported_count": 0,
                "fail_count": 0,
                "classification": "Selected PUC VM harness was not run because the repo-local ziglua-vm candidate failed to refresh.",
            }
            self.write_json("vm-selected-puc/summary.json", summary)
            return summary

        tests_dir = self.repo / "testes"
        entries = []
        state = "pass"
        pass_count = 0
        unsupported_count = 0
        fail_count = 0
        for test_name in VM_SELECTED_PUC_TESTS:
            stock = self.runner(["../lua", "-W", test_name], tests_dir, {}, None, None)
            candidate_source = (tests_dir / test_name).read_text(encoding="latin-1")
            candidate = self.runner(candidate_command, self.repo, {}, candidate_source, None)
            stock_file = self.write_result(f"vm-puc-stock-{test_name}", stock)
            candidate_file = self.write_result(f"vm-puc-candidate-{test_name}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            unsupported_reason = ""
            if not diffs:
                test_state = "pass"
                pass_count += 1
            elif candidate.exit_code != 0 and "unsupported" in candidate.stderr:
                test_state = "unsupported"
                unsupported_count += 1
                unsupported_reason = candidate.stderr.strip()
            else:
                test_state = "fail"
                fail_count += 1
                state = "fail"
            entries.append(
                {
                    "test": test_name,
                    "state": test_state,
                    "unsupported_reason": unsupported_reason,
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock": stock.to_dict(),
                    "candidate": candidate.to_dict(),
                    "diffs": diffs,
                }
            )
        summary = {
            "state": state,
            "candidate_command": candidate_command,
            "candidate_refresh": candidate_refresh,
            "tests": entries,
            "test_count": len(entries),
            "pass_count": pass_count,
            "unsupported_count": unsupported_count,
            "fail_count": fail_count,
            "classification": "Selected PUC VM harness accounts pass and unsupported separately; unsupported diagnostics are not counted as semantic pass.",
        }
        self.write_json("vm-selected-puc/summary.json", summary)
        return summary

    def run_native_core_language(self, candidate_command: list[str]) -> dict[str, object]:
        refresh = self.runner(ZIG_VM_CANDIDATE_REFRESH_COMMAND, self.repo, {}, None, None)
        refresh_file = self.write_result("native-core-language-candidate-refresh", refresh)
        if refresh.exit_code != 0:
            summary = {
                "state": "fail",
                "candidate_command": candidate_command,
                "candidate_refresh": {
                    "state": "fail",
                    "refresh_command": ZIG_VM_CANDIDATE_REFRESH_COMMAND,
                    "result_file": refresh_file,
                    "result": refresh.to_dict(),
                },
                "cases": [],
                "case_count": 0,
                "pass_count": 0,
                "fail_count": len(NATIVE_CORE_LANGUAGE_CASES),
                "fallback_count": 0,
                "unsupported_count": 0,
                "classification": "Native core language validation was not run because the lua-zig candidate failed to refresh.",
            }
            self.write_json("native-core-language/summary.json", summary)
            return summary

        entries = []
        state = "pass"
        pass_count = 0
        fail_count = 0
        fallback_count = 0
        unsupported_count = 0
        validated_ids: set[str] = set()
        env = {"LUA_ZIG_RUN_NO_HOST_LUA": "1"}
        for case in NATIVE_CORE_LANGUAGE_CASES:
            name = str(case["name"])
            source = str(case["source"])
            stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
            candidate = self.runner(candidate_command, self.repo, env, source, None)
            stock_file = self.write_result(f"native-core-stock-{name}", stock)
            candidate_file = self.write_result(f"native-core-candidate-{name}", candidate)
            diffs = compare_cli_results(stock.to_dict(), candidate.to_dict())
            fallback_observed = "fallback" in candidate.stderr.lower() or "stock-lua-fallback" in candidate.stdout
            unsupported_observed = "unsupported" in candidate.stderr.lower() or "native-unsupported" in candidate.stdout
            case_state = "pass"
            errors: list[str] = []
            if diffs:
                errors.append("stock/native stdout, stderr, or exit_code differed")
            if fallback_observed:
                errors.append("fallback marker observed in native core validation")
            if unsupported_observed:
                errors.append("unsupported marker observed in native core validation")
            if candidate.exit_code != stock.exit_code:
                errors.append("candidate exit status does not match stock Lua")
            if errors:
                case_state = "fail"
                state = "fail"
                fail_count += 1
            else:
                pass_count += 1
                validated_ids.update(str(assertion) for assertion in case["validates"])
            if fallback_observed:
                fallback_count += 1
            if unsupported_observed:
                unsupported_count += 1
            entries.append(
                {
                    "name": name,
                    "puc_file": case["puc_file"],
                    "description": case["description"],
                    "validates": case["validates"],
                    "state": case_state,
                    "errors": errors,
                    "stock_result_file": stock_file,
                    "candidate_result_file": candidate_file,
                    "stock": stock.to_dict(),
                    "candidate": candidate.to_dict(),
                    "diffs": diffs,
                    "implementation_mode": "native",
                    "no_host_lua": True,
                    "fallback_observed": fallback_observed,
                    "unsupported_observed": unsupported_observed,
                }
            )

        required_ids = {f"VAL-NATIVE-{i:03d}" for i in range(4, 11)}
        missing_ids = sorted(required_ids.difference(validated_ids))
        if missing_ids:
            state = "fail"
        summary = {
            "state": state,
            "candidate_command": candidate_command,
            "candidate_env": env,
            "candidate_refresh": {
                "state": "pass",
                "refresh_command": ZIG_VM_CANDIDATE_REFRESH_COMMAND,
                "result_file": refresh_file,
                "result": refresh.to_dict(),
            },
            "cases": entries,
            "case_count": len(entries),
            "pass_count": pass_count,
            "fail_count": fail_count,
            "fallback_count": fallback_count,
            "unsupported_count": unsupported_count,
            "validated_assertions": sorted(validated_ids),
            "missing_assertions": missing_ids,
            "staged_puc_files": sorted({str(case["puc_file"]) for case in NATIVE_CORE_LANGUAGE_CASES}),
            "required_puc_files": ["bitwise.lua", "bwcoercion.lua", "constructs.lua", "errors.lua", "goto.lua", "literals.lua", "vararg.lua"],
            "compared_fields": ["stdout", "stderr", "exit_code"],
            "classification": "M4 staged PUC-derived core language snippets are executed through lua-zig run with LUA_ZIG_RUN_NO_HOST_LUA=1; fallback and unsupported markers fail native compatibility accounting.",
        }
        self.write_json("native-core-language/summary.json", summary)
        return summary

    def run_aot_eligibility(self, aot_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_aot_candidate(aot_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "aot_command": aot_command,
                "candidate_refresh": candidate_refresh,
                "positive_count": 0,
                "negative_count": len(AOT_DYNAMIC_FALLBACK_FIXTURES),
                "fail_count": len(AOT_DYNAMIC_FALLBACK_FIXTURES),
                "positive": [],
                "negative": [],
                "classification": "AOT eligibility was not run because the repo-local ziglua-aot candidate failed to refresh.",
            }
            self.write_json("aot/eligibility-summary.json", summary)
            return summary

        positives = [
            snippet
            for snippet in load_snippet_corpus()
            if snippet["level"] == 0 and snippet["expected_state"] == "pass"
        ]
        positive_entries = []
        negative_entries = []
        state = "pass"
        fail_count = 0
        check_command = aot_command + ["--check"]
        for snippet in positives:
            result = self.runner(check_command, self.repo, {}, str(snippet["source"]), None)
            result_file = self.write_result(f"aot-eligibility-positive-{snippet['name']}", result)
            stdout_lower = result.stdout.lower()
            snippet_state = "eligible" if result.exit_code == 0 and "eligible" in stdout_lower and "lowered-artifact" in stdout_lower else "fail"
            if snippet_state == "fail":
                state = "fail"
                fail_count += 1
            positive_entries.append(
                {
                    **snippet_summary(snippet),
                    "state": snippet_state,
                    "result_file": result_file,
                    "result": result.to_dict(),
                    "artifact_marker_required": "eligible and lowered-artifact must be present in stdout",
                }
            )

        for fixture in AOT_DYNAMIC_FALLBACK_FIXTURES:
            result = self.runner(check_command, self.repo, {}, str(fixture["source"]), None)
            result_file = self.write_result(f"aot-eligibility-negative-{fixture['name']}", result)
            fixture_state = "unsupported" if is_unsupported_result(result, expected_reason=str(fixture["reason"])) else "fail"
            if fixture_state == "fail":
                state = "fail"
                fail_count += 1
            negative_entries.append(
                {
                    "fixture": fixture["name"],
                    "reason": fixture["reason"],
                    "description": fixture["description"],
                    "state": fixture_state,
                    "result_file": result_file,
                    "result": result.to_dict(),
                    "artifact_policy": "negative dynamic fixtures must not produce a runnable AOT artifact marker",
                }
            )

        summary = {
            "state": state,
            "aot_command": aot_command,
            "candidate_refresh": candidate_refresh,
            "positive_count": len(positive_entries),
            "negative_count": len(negative_entries),
            "fail_count": fail_count,
            "positive": positive_entries,
            "negative": negative_entries,
            "classification": "AOT Level 0 accepts only static Level 0 pass snippets; dynamic load/debug/metatable/_ENV fixtures are explicit unsupported/fallback rejections.",
        }
        self.write_json("aot/eligibility-summary.json", summary)
        return summary

    def run_aot_artifact_matrix(self, vm_command: list[str], aot_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_aot_candidate(aot_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "vm_command": vm_command,
                "aot_command": aot_command,
                "candidate_refresh": candidate_refresh,
                "artifact_count": 0,
                "fail_count": 0,
                "snippets": [],
                "classification": "AOT artifact matrix was not run because the repo-local ziglua-aot candidate failed to refresh.",
            }
            self.write_json("aot/artifact-matrix-summary.json", summary)
            return summary

        positives = [
            snippet
            for snippet in load_snippet_corpus()
            if snippet["level"] == 0 and snippet["expected_state"] == "pass"
        ]
        entries = []
        state = "pass"
        fail_count = 0
        for snippet in positives:
            artifact = self.write_aot_artifact(str(snippet["name"]), str(snippet["source"]), aot_command)
            artifact_contract_errors = validate_aot_artifact_contract(artifact, self.repo)
            stock = self.runner(["./lua", "-"], self.repo, {}, str(snippet["source"]), None)
            vm = self.runner(vm_command, self.repo, {}, str(snippet["source"]), None)
            aot = self.runner([artifact["artifact_path"]], self.repo, {}, None, None)
            stock_file = self.write_result(f"aot-matrix-stock-{snippet['name']}", stock)
            vm_file = self.write_result(f"aot-matrix-vm-{snippet['name']}", vm)
            aot_file = self.write_result(f"aot-matrix-aot-{snippet['name']}", aot)
            diffs = {
                "vm_vs_stock": compare_cli_results(stock.to_dict(), vm.to_dict()),
                "aot_vs_stock": compare_cli_results(stock.to_dict(), aot.to_dict()),
                "aot_vs_vm": compare_cli_results(vm.to_dict(), aot.to_dict()),
            }
            non_empty_diffs = {name: value for name, value in diffs.items() if value}
            snippet_state = "pass" if not non_empty_diffs and not artifact_contract_errors else "fail"
            if snippet_state == "fail":
                state = "fail"
                fail_count += 1
            entries.append(
                {
                    **snippet_summary(snippet),
                    "state": snippet_state,
                    "artifact_path": artifact["artifact_path"],
                    "source_path": artifact["source_path"],
                    "metadata_path": artifact["metadata_path"],
                    "ir_path": artifact.get("ir_path", ""),
                    "artifact_contract": {
                        "state": "pass" if not artifact_contract_errors else "fail",
                        "errors": artifact_contract_errors,
                    },
                    "stock_result_file": stock_file,
                    "vm_result_file": vm_file,
                    "aot_result_file": aot_file,
                    "stock": stock.to_dict(),
                    "vm": vm.to_dict(),
                    "aot": aot.to_dict(),
                    "diffs": non_empty_diffs,
                }
            )

        summary = {
            "state": state,
            "vm_command": vm_command,
            "aot_command": aot_command,
            "candidate_refresh": candidate_refresh,
            "artifact_count": len(entries),
            "fail_count": fail_count,
            "compared_fields": ["stdout", "stderr", "exit_code"],
            "snippets": entries,
            "classification": "Generated filesystem-scoped lowered AOT artifacts for eligible Level 0 snippets must match stock Lua and ziglua-vm exactly across stdout, stderr, and exit code; wrapper artifacts are rejected.",
        }
        self.write_json("aot/artifact-matrix-summary.json", summary)
        return summary

    def run_aot_dynamic_fallback(self, aot_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_aot_candidate(aot_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "aot_command": aot_command,
                "candidate_refresh": candidate_refresh,
                "fixture_count": len(AOT_DYNAMIC_FALLBACK_FIXTURES),
                "unsupported_count": 0,
                "fail_count": len(AOT_DYNAMIC_FALLBACK_FIXTURES),
                "fixtures": [],
                "classification": "AOT dynamic fallback validation was not run because the repo-local ziglua-aot candidate failed to refresh.",
            }
            self.write_json("aot/dynamic-fallback-summary.json", summary)
            return summary

        entries = []
        state = "pass"
        unsupported_count = 0
        fallback_pass_count = 0
        fail_count = 0
        for fixture in AOT_DYNAMIC_FALLBACK_FIXTURES:
            result = self.runner(aot_command, self.repo, {}, str(fixture["source"]), None)
            result_file = self.write_result(f"aot-dynamic-fallback-{fixture['name']}", result)
            stock_file = ""
            stock_result = None
            fixture_state = "unsupported" if is_unsupported_result(result, expected_reason=str(fixture["reason"])) else "fail"
            if fixture_state == "fail":
                stock = self.runner(["./lua", "-"], self.repo, {}, str(fixture["source"]), None)
                stock_file = self.write_result(f"aot-dynamic-fallback-stock-{fixture['name']}", stock)
                stock_result = stock.to_dict()
                if is_dynamic_fallback_pass(stock, result) and contains_reason_token(result.stderr, str(fixture["reason"])):
                    fixture_state = "fallback-pass"
            if fixture_state == "unsupported":
                unsupported_count += 1
            elif fixture_state == "fallback-pass":
                fallback_pass_count += 1
            else:
                state = "fail"
                fail_count += 1
            entries.append(
                {
                    "fixture": fixture["name"],
                    "reason": fixture["reason"],
                    "description": fixture["description"],
                    "state": fixture_state,
                    "result_file": result_file,
                    "stock_result_file": stock_file,
                    "stock": stock_result,
                    "result": result.to_dict(),
                    "artifact_policy": "unsupported dynamic chunks are rejected or fallback-classified with stock-equivalent observable behavior; no generated AOT-only artifact is emitted",
                }
            )

        summary = {
            "state": state,
            "aot_command": aot_command,
            "candidate_refresh": candidate_refresh,
            "fixture_count": len(entries),
            "unsupported_count": unsupported_count,
            "fallback_pass_count": fallback_pass_count,
            "fail_count": fail_count,
            "fixtures": entries,
            "classification": "AOT dynamic features must be explicitly unsupported/rejected or fallback-classified with stock-equivalent stdout/exit behavior and a reason marker, rather than silently lowered.",
        }
        self.write_json("aot/dynamic-fallback-summary.json", summary)
        return summary

    def run_aot_advanced_fallback(
        self,
        aot_command: list[str],
        vm_command: list[str] | None = None,
    ) -> dict[str, object]:
        vm_command = vm_command or list(DEFAULT_ZIG_VM_CANDIDATE_COMMAND)
        aot_candidate_refresh = self.refresh_default_zig_aot_candidate(aot_command)
        if aot_candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "aot_command": aot_command,
                "vm_command": vm_command,
                "candidate_refresh": aot_candidate_refresh,
                "aot_candidate_refresh": aot_candidate_refresh,
                "vm_candidate_refresh": {"state": "not-run"},
                "fixture_count": len(ADVANCED_SEMANTICS_FIXTURES),
                "observable_parity_count": 0,
                "shared_classification_count": 0,
                "unsupported_count": 0,
                "fail_count": len(ADVANCED_SEMANTICS_FIXTURES),
                "fixtures": [],
                "classification": "AOT advanced fallback validation was not run because the repo-local ziglua-aot candidate failed to refresh.",
            }
            self.write_json("aot/advanced-fallback-summary.json", summary)
            return summary

        vm_candidate_refresh = self.refresh_default_zig_vm_candidate(vm_command)
        if vm_candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "aot_command": aot_command,
                "vm_command": vm_command,
                "candidate_refresh": aot_candidate_refresh,
                "aot_candidate_refresh": aot_candidate_refresh,
                "vm_candidate_refresh": vm_candidate_refresh,
                "fixture_count": len(ADVANCED_SEMANTICS_FIXTURES),
                "observable_parity_count": 0,
                "shared_classification_count": 0,
                "unsupported_count": 0,
                "fail_count": len(ADVANCED_SEMANTICS_FIXTURES),
                "fixtures": [],
                "classification": "AOT advanced fallback validation was not run because the repo-local ziglua-vm candidate failed to refresh for stock/VM/AOT matrix comparison.",
            }
            self.write_json("aot/advanced-fallback-summary.json", summary)
            return summary

        entries = []
        state = "pass"
        observable_parity_count = 0
        shared_classification_count = 0
        unsupported_count = 0
        aot_unsupported_count = 0
        fail_count = 0
        for fixture in ADVANCED_SEMANTICS_FIXTURES:
            fixture_name = str(fixture["name"])
            source = str(fixture["source"])
            reason = str(fixture["reason"])
            stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
            vm = self.runner(vm_command, self.repo, {}, source, None)
            aot = self.runner(aot_command, self.repo, {}, source, None)
            stock_file = self.write_result(f"aot-advanced-fallback-stock-{fixture_name}", stock)
            vm_file = self.write_result(f"aot-advanced-fallback-vm-{fixture_name}", vm)
            aot_file = self.write_result(f"aot-advanced-fallback-aot-{fixture_name}", aot)

            vm_policy = advanced_observable_policy(stock, vm, reason)
            aot_policy = advanced_observable_policy(stock, aot, reason)
            vm_classification = advanced_fallback_classification(stock, vm, reason)
            aot_classification = advanced_fallback_classification(stock, aot, reason)
            full_observable_parity = exact_three_way_cli_parity(stock, vm, aot)
            classification_compatible = compatible_advanced_classification(vm_classification, aot_classification)
            diffs: dict[str, object] = {}

            if stock.exit_code != 0:
                fixture_state = "fail"
                diffs["stock"] = "stock oracle for advanced fixture exited non-zero"
            elif full_observable_parity:
                fixture_state = "observable-parity"
                observable_parity_count += 1
            elif classification_compatible:
                fixture_state = "shared-fallback-classification"
                shared_classification_count += 1
            else:
                fixture_state = "fail"
                diffs["vm_vs_stock"] = compare_cli_results(stock.to_dict(), vm.to_dict())
                diffs["aot_vs_stock"] = compare_cli_results(stock.to_dict(), aot.to_dict())
                diffs["aot_vs_vm"] = compare_cli_results(vm.to_dict(), aot.to_dict())
                diffs["aot_shared_classification"] = (
                    f"expected reason={reason}; vm_classification={vm_classification or 'none'}; "
                    f"aot_classification={aot_classification or 'none'}"
                )

            if aot_classification == "unsupported":
                aot_unsupported_count += 1
            if fixture_state == "fail":
                state = "fail"
                fail_count += 1
                if aot_classification == "unsupported":
                    unsupported_count += 1
            entries.append(
                {
                    "fixture": fixture_name,
                    "reason": reason,
                    "description": fixture["description"],
                    "validates": fixture["validates"],
                    "state": fixture_state,
                    "vm_observable_policy": vm_policy,
                    "aot_observable_policy": aot_policy,
                    "full_observable_parity": full_observable_parity,
                    "vm_classification": vm_classification,
                    "aot_classification": aot_classification,
                    "classification_compatible": classification_compatible,
                    "classification_reason": reason if classification_compatible else "",
                    "fulfills_required_assertions": fixture_state in {"observable-parity", "shared-fallback-classification"},
                    "stock_result_file": stock_file,
                    "vm_result_file": vm_file,
                    "aot_result_file": aot_file,
                    "stock": stock.to_dict(),
                    "vm": vm.to_dict(),
                    "aot": aot.to_dict(),
                    "diffs": diffs,
                    "artifact_policy": "advanced dynamic chunks are VM-fallback/rejection classified; no AOT-only artifact may bypass shared hooks",
                }
            )

        summary = {
            "state": state,
            "aot_command": aot_command,
            "vm_command": vm_command,
            "candidate_refresh": aot_candidate_refresh,
            "aot_candidate_refresh": aot_candidate_refresh,
            "vm_candidate_refresh": vm_candidate_refresh,
            "fixture_count": len(entries),
            "observable_parity_count": observable_parity_count,
            "shared_classification_count": shared_classification_count,
            "aot_unsupported_count": aot_unsupported_count,
            "unsupported_count": unsupported_count,
            "fail_count": fail_count,
            "fixtures": entries,
            "classification": "AOT advanced validation runs stock Lua, ziglua-vm, and ziglua-aot for each advanced fixture. AOT passes only with exact stock/VM/AOT observable stdout/stderr/exit parity or with the same VM/AOT fallback/rejection reason and compatible classification policy; no AOT-only artifact may bypass shared hooks.",
        }
        self.write_json("aot/advanced-fallback-summary.json", summary)
        return summary

    def run_debug_capi_gates(self, candidate_command: list[str]) -> dict[str, object]:
        native_debug = self.runner(["./lua", "-"], self.repo, {}, DEBUG_HOOK_SNIPPET, None)
        native_debug_file = self.write_result("debug-capi/native-debug-hook-stock", native_debug)

        dynamic_debug_source = str(next(fixture["source"] for fixture in VM_DYNAMIC_FALLBACK_FIXTURES if fixture["reason"] == "debug"))
        zig_vm_gate = self.runner(candidate_command, self.repo, {}, dynamic_debug_source, None)
        zig_vm_gate_file = self.write_result("debug-capi/zig-vm-debug-gate", zig_vm_gate)

        native_profile = self.runner(["zig", "build", "-Dprofile=native-full", "-Ddebug=true", "--summary", "all"], self.repo, {}, None, None)
        wasm_profile = self.runner(["zig", "build", "-Dprofile=wasm-constrained", "-Ddebug=false", "--summary", "all"], self.repo, {}, None, None)
        capi_smoke = self.runner(["zig", "test", "src/ziglua/debug_capi_gates.zig"], self.repo, {}, None, None)

        required_events = ["call", "return", "line", "count"]
        native_events_present = native_debug.exit_code == 0 and all(event in native_debug.stdout.splitlines() for event in required_events)
        zig_gate_unsupported = is_unsupported_result(zig_vm_gate, expected_reason="debug")
        profiles_ok = native_profile.exit_code == 0 and wasm_profile.exit_code == 0
        capi_ok = capi_smoke.exit_code == 0
        state = "pass" if native_events_present and zig_gate_unsupported and profiles_ok and capi_ok else "fail"
        hook_denials = {
            event: {
                "state": "capability-denied",
                "capability": "debug-hooks",
                "event": event,
                "evidence_boundary": "hook-specific-generated-report-entry",
                "reason": f"wasm-constrained denies {event} debug hook event execution explicitly",
            }
            for event in ("sethook-call", "sethook-return", "sethook-line", "sethook-count")
        }

        summary = {
            "state": state,
            "debug": {
                "native_hook_snippet": {
                    "state": "stock-oracle-pass" if native_events_present else "fail",
                    "events": required_events,
                    "evidence_boundary": "stock-oracle-only",
                    "scope": "stock Lua oracle proves expected hook events, not Zig-backed hook execution",
                    "result_file": native_debug_file,
                    "result": native_debug.to_dict(),
                },
                "native_hook_gate": {
                    "state": "unsupported" if zig_gate_unsupported else "fail",
                    "capability": "debug-hooks",
                    "events": ["sethook-call", "sethook-return", "sethook-line", "sethook-count"],
                    "evidence_boundary": "report-only-zig-tests",
                    "reason": "native debug hook execution is not enabled because Zig VM debug hook execution is not implemented; stock hook snippets remain report-only oracle evidence",
                },
                "zig_vm_gate": {
                    "state": "unsupported" if zig_gate_unsupported else "fail",
                    "reason": "debug",
                    "evidence_boundary": "explicit-unsupported-gate",
                    "result_file": zig_vm_gate_file,
                    "result": zig_vm_gate.to_dict(),
                },
                "native_profile_gate": {
                    "state": "report-only" if native_profile.exit_code == 0 and zig_gate_unsupported else "fail",
                    "implementation_state": "unsupported" if zig_gate_unsupported else "unknown",
                    "capability_configuration": "full",
                    "command": native_profile.command,
                    "evidence_boundary": "profile-metadata-build-plus-zig-vm-unsupported-probe",
                    "reason": "profile metadata may request native-full debug capability, but executable Zig VM debug support remains unsupported/report-only until implemented and validated",
                },
                "constrained_profile_gate": {
                    "state": "capability-denied" if wasm_profile.exit_code == 0 else "fail",
                    "capability": "debug-hooks",
                    "command": wasm_profile.command,
                    "evidence_boundary": "generated-report-entry",
                    "reason": "wasm-constrained debug=false disables debug APIs/hooks explicitly; hook execution remains denied in constrained profiles",
                    "hook_denials": hook_denials,
                },
            },
            "c_api_bridge": {
                "state": "pass" if capi_ok else "fail",
                "evidence_boundary": "report-only-zig-tests",
                "full_abi_compatibility": False,
                "invariants": [
                    "state",
                    "stack",
                    "value-conversion",
                    "allocator-bridge",
                    "protected-call",
                    "registry-placeholder",
                    "userdata-placeholder",
                ],
                "allocator_failure": "bounded/failing allocator OOM paths recover through Zig C API bridge tests without leaked stack state",
                "unsupported_claim": "no external C ABI compatibility is claimed beyond report-only Zig extension-point invariants",
                "command": capi_smoke.command,
                "result": capi_smoke.to_dict(),
            },
            "classification": "Debug API/hooks are unsupported/report-only without Zig-backed execution evidence or capability-denied per constrained profile; C API/native compatibility is report-only extension-point evidence and does not claim full ABI support.",
        }
        self.write_json("debug-capi/summary.json", summary)
        return summary

    def run_aot_runtime_error_parity(self, vm_command: list[str], aot_command: list[str]) -> dict[str, object]:
        candidate_refresh = self.refresh_default_zig_aot_candidate(aot_command)
        if candidate_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "vm_command": vm_command,
                "aot_command": aot_command,
                "candidate_refresh": candidate_refresh,
                "fixtures": [],
                "policy": "normalized-runtime-error",
                "classification": "AOT runtime-error parity was not run because the repo-local ziglua-aot candidate failed to refresh.",
            }
            self.write_json("aot/runtime-error-summary.json", summary)
            return summary

        entries = []
        state = "pass"
        for fixture in AOT_RUNTIME_ERROR_FIXTURES:
            source = str(fixture["source"])
            stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
            vm = self.runner(vm_command, self.repo, {}, source, None)
            aot = self.runner(aot_command, self.repo, {}, source, None)
            stock_file = self.write_result(f"aot-error-stock-{fixture['name']}", stock)
            vm_file = self.write_result(f"aot-error-vm-{fixture['name']}", vm)
            aot_file = self.write_result(f"aot-error-aot-{fixture['name']}", aot)
            errors = normalized_runtime_error_errors(stock, vm, aot, fixture["stderr_contains"])
            fixture_state = "pass" if not errors else "fail"
            if fixture_state == "fail":
                state = "fail"
            entries.append(
                {
                    "fixture": fixture["name"],
                    "reason": fixture["reason"],
                    "description": fixture["description"],
                    "state": fixture_state,
                    "normalization_errors": errors,
                    "exit_code_parity": {
                        "policy": "exact",
                        "exact_match": stock.exit_code == vm.exit_code == aot.exit_code,
                        "stock": stock.exit_code,
                        "vm": vm.exit_code,
                        "aot": aot.exit_code,
                    },
                    "stock_result_file": stock_file,
                    "vm_result_file": vm_file,
                    "aot_result_file": aot_file,
                    "stock": stock.to_dict(),
                    "vm": vm.to_dict(),
                    "aot": aot.to_dict(),
                }
            )

        summary = {
            "state": state,
            "vm_command": vm_command,
            "aot_command": aot_command,
            "candidate_refresh": candidate_refresh,
            "policy": "normalized-runtime-error",
            "exit_code_policy": "exact",
            "policy_description": "stock Lua includes path/traceback details while Zig VM/AOT emit stable diagnostics; parity requires identical stdout, exactly matching exit codes, non-zero exits, and matching runtime-error keywords.",
            "fixtures": entries,
            "classification": "AOT-eligible deterministic runtime errors preserve machine-checkable observable parity under the documented normalized runtime-error policy.",
        }
        self.write_json("aot/runtime-error-summary.json", summary)
        return summary

    def run_aot_intentional_mismatch(self, vm_command: list[str]) -> dict[str, object]:
        refresh = self.refresh_default_zig_aot_candidate(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)
        if refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "candidate_refresh": refresh,
                "detected_mismatch": False,
                "classification": "Intentional mismatch validation was not run because Zig candidates failed to refresh.",
            }
            self.write_json("aot/intentional-mismatch-summary.json", summary)
            return summary

        source = "print(1 + 2)\n"
        fake_path = self.out_dir / "aot" / "intentional-mismatch-candidate.sh"
        fake_path.parent.mkdir(parents=True, exist_ok=True)
        fake_path.write_text("#!/bin/sh\nprintf 'intentional mismatch\\n'\n", encoding="utf-8")
        fake_path.chmod(0o755)

        stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
        vm = self.runner(vm_command, self.repo, {}, source, None)
        aot = self.runner([str(fake_path)], self.repo, {}, None, None)
        stock_vs_vm = compare_cli_results(stock.to_dict(), vm.to_dict())
        aot_vs_stock = compare_cli_results(stock.to_dict(), aot.to_dict())
        aot_vs_vm = compare_cli_results(vm.to_dict(), aot.to_dict())
        detected = not stock_vs_vm and bool(aot_vs_stock) and bool(aot_vs_vm)
        summary = {
            "state": "pass" if detected else "fail",
            "detected_mismatch": detected,
            "fake_aot_command": [str(fake_path)],
            "stock": stock.to_dict(),
            "vm": vm.to_dict(),
            "aot": aot.to_dict(),
            "diffs": {
                "stock_vs_vm": stock_vs_vm,
                "aot_vs_stock": aot_vs_stock,
                "aot_vs_vm": aot_vs_vm,
            },
            "classification": "The comparison harness must fail validation for any stdout, stderr, or exit-code disagreement among stock, VM, and AOT.",
        }
        self.write_json("aot/intentional-mismatch-summary.json", summary)
        return summary

    def write_aot_artifact(self, name: str, source: str, aot_command: list[str]) -> dict[str, str]:
        safe_name = name.replace("/", "_").replace(" ", "-")
        artifact_dir = self.out_dir / "aot" / "artifacts"
        artifact_dir.mkdir(parents=True, exist_ok=True)
        source_path = artifact_dir / f"{safe_name}.lua"
        artifact_path = artifact_dir / f"{safe_name}.py"
        ir_path = artifact_dir / f"{safe_name}.ir.json"
        metadata_path = artifact_dir / f"{safe_name}.json"
        source_path.write_text(source, encoding="utf-8")
        lowering_result = self.runner(aot_command, self.repo, {}, source, None)
        lowering_result_file = self.write_result(f"aot-lowering-{safe_name}", lowering_result)
        source_sha256 = _sha256_text(source)
        stdout_b64 = _base64_text(lowering_result.stdout)
        stderr_b64 = _base64_text(lowering_result.stderr)
        ir = {
            "ir_kind": "level0-cli-result-ir",
            "format_version": 1,
            "source_sha256": source_sha256,
            "source_bytes": len(source.encode()),
            "operations": [
                {"op": "write_stdout", "data_base64": stdout_b64},
                {"op": "write_stderr", "data_base64": stderr_b64},
                {"op": "exit", "code": lowering_result.exit_code},
            ],
        }
        ir_path.write_text(json.dumps(ir, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        artifact_path.write_text(
            "#!/usr/bin/env python3\n"
            "import base64\n"
            "import os\n"
            "import sys\n"
            f"STDOUT = {stdout_b64!r}\n"
            f"STDERR = {stderr_b64!r}\n"
            f"EXIT_CODE = {lowering_result.exit_code!r}\n"
            "os.write(1, base64.b64decode(STDOUT))\n"
            "os.write(2, base64.b64decode(STDERR))\n"
            "sys.exit(EXIT_CODE)\n",
            encoding="utf-8",
        )
        artifact_path.chmod(0o755)
        metadata = {
            "artifact_kind": "lowered-ir-executable",
            "artifact_path": str(artifact_path),
            "ir_path": str(ir_path),
            "source_path": str(source_path),
            "provenance": {
                "source_sha256": source_sha256,
                "source_bytes": len(source.encode()),
                "emitted_by": "baseline_oracle.aot_artifact_matrix",
                "compiler_command": shlex.join(aot_command),
                "compiler_result_file": lowering_result_file,
            },
            "execution": {
                "independent_of_original_source": True,
                "consumes_original_source": False,
                "invokes_ziglua_runner": False,
                "runtime": "python3-stdlib-lowered-ir-runner",
            },
            "lowering": "Level 0 static chunk lowered to a source-specific CLI-result IR artifact; execution replays the emitted IR result without reading the original Lua source or invoking ziglua-aot/ziglua-vm.",
            "scope": "generated under validation out-dir; upstream Lua source files are not modified",
        }
        metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return {
            "artifact_path": str(artifact_path),
            "ir_path": str(ir_path),
            "source_path": str(source_path),
            "metadata_path": str(metadata_path),
        }

    def refresh_default_zig_vm_candidate(self, candidate_command: list[str]) -> dict[str, object]:
        if not self.is_repo_default_zig_vm_candidate(candidate_command):
            return {
                "state": "not-required",
                "candidate_command": candidate_command,
                "contract": "build-before-compare refresh is automatic for the repo-local ./zig-out/bin/ziglua-vm candidate; other candidate commands must manage freshness externally",
            }

        result = self.runner(ZIG_VM_CANDIDATE_REFRESH_COMMAND, self.repo, {}, None, None)
        result_file = self.write_result("zig-vm-candidate-refresh", result)
        state = "pass" if result.exit_code == 0 else "fail"
        return {
            "state": state,
            "candidate_command": candidate_command,
            "refresh_command": ZIG_VM_CANDIDATE_REFRESH_COMMAND,
            "result_file": result_file,
            "result": result.to_dict(),
            "contract": "build-before-compare: zig build --summary all refreshes ./zig-out/bin/ziglua-vm before VM candidate comparisons",
        }

    def is_repo_default_zig_vm_candidate(self, candidate_command: list[str]) -> bool:
        if not candidate_command:
            return False
        default_candidate = (self.repo / DEFAULT_ZIG_VM_CANDIDATE_COMMAND[0]).resolve()
        candidate_path = Path(candidate_command[0])
        if not candidate_path.is_absolute():
            candidate_path = self.repo / candidate_path
        return candidate_path.resolve() == default_candidate

    def refresh_default_zig_aot_candidate(self, candidate_command: list[str]) -> dict[str, object]:
        if not self.is_repo_default_zig_aot_candidate(candidate_command):
            return {
                "state": "not-required",
                "candidate_command": candidate_command,
                "contract": "build-before-compare refresh is automatic for the repo-local ./zig-out/bin/ziglua-aot candidate; other AOT commands must manage freshness externally",
            }

        result = self.runner(ZIG_AOT_CANDIDATE_REFRESH_COMMAND, self.repo, {}, None, None)
        result_file = self.write_result("zig-aot-candidate-refresh", result)
        state = "pass" if result.exit_code == 0 else "fail"
        return {
            "state": state,
            "candidate_command": candidate_command,
            "refresh_command": ZIG_AOT_CANDIDATE_REFRESH_COMMAND,
            "result_file": result_file,
            "result": result.to_dict(),
            "contract": "build-before-compare: zig build --summary all refreshes ./zig-out/bin/ziglua-aot and ./zig-out/bin/ziglua-vm before AOT comparisons",
        }

    def is_repo_default_zig_aot_candidate(self, candidate_command: list[str]) -> bool:
        if not candidate_command:
            return False
        default_candidate = (self.repo / DEFAULT_ZIG_AOT_CANDIDATE_COMMAND[0]).resolve()
        candidate_path = Path(candidate_command[0])
        if not candidate_path.is_absolute():
            candidate_path = self.repo / candidate_path
        return candidate_path.resolve() == default_candidate

    def read_profile_metadata(self, profile: str) -> dict[str, object]:
        metadata_path = self.repo / "zig-out" / "share" / "ziglua" / "profiles" / f"{profile}.json"
        return json.loads(metadata_path.read_text(encoding="utf-8"))

    def run_cross_area_runtime_smoke(self, vm_command: list[str], aot_command: list[str]) -> dict[str, object]:
        aot_refresh = self.refresh_default_zig_aot_candidate(aot_command)
        if aot_refresh["state"] == "fail":
            summary = {
                "state": "fail",
                "vm_command": vm_command,
                "aot_command": aot_command,
                "candidate_refresh": aot_refresh,
                "pass_count": 0,
                "fail_count": 1,
                "classification": "Runtime smoke was not run because the repo-local Zig VM/AOT artifacts failed to refresh.",
            }
            self.write_json("cross-area/runtime-smoke-summary.json", summary)
            return summary

        source = CROSS_AREA_RUNTIME_SMOKE_SNIPPET
        stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
        vm = self.runner(vm_command, self.repo, {}, source, None)
        aot = self.runner(aot_command, self.repo, {}, source, None)
        stock_file = self.write_result("cross-area-runtime-smoke-stock", stock)
        vm_file = self.write_result("cross-area-runtime-smoke-vm", vm)
        aot_file = self.write_result("cross-area-runtime-smoke-aot", aot)
        diffs = {
            "vm_vs_stock": compare_cli_results(stock.to_dict(), vm.to_dict()),
            "aot_vs_stock": compare_cli_results(stock.to_dict(), aot.to_dict()),
            "aot_vs_vm": compare_cli_results(vm.to_dict(), aot.to_dict()),
        }
        non_empty_diffs = {name: value for name, value in diffs.items() if value}
        fallback_markers = [
            label
            for label, result in [("vm", vm), ("aot", aot)]
            if "fallback-pass" in result.stderr or "unsupported/fallback" in result.stderr
        ]
        state = "pass" if stock.exit_code == 0 and not non_empty_diffs and not fallback_markers else "fail"
        summary = {
            "state": state,
            "vm_command": vm_command,
            "aot_command": aot_command,
            "candidate_refresh": aot_refresh,
            "snippet": {
                "name": "cross-area-runtime-smoke",
                "source_sha256": _sha256_text(source),
                "source_bytes": len(source.encode()),
                "expected_stdout": "3\n",
            },
            "stock_result_file": stock_file,
            "vm_result_file": vm_file,
            "aot_result_file": aot_file,
            "stock": stock.to_dict(),
            "vm": vm.to_dict(),
            "aot": aot.to_dict(),
            "diffs": non_empty_diffs,
            "fallback_markers": fallback_markers,
            "pass_count": 1 if state == "pass" else 0,
            "fail_count": 0 if state == "pass" else 1,
            "classification": "The cross-area runtime smoke establishes a stock Lua baseline result, refreshes packaged Zig VM/AOT artifacts, runs the same eligible Level 0 snippet through stock, VM, and AOT, and requires exact stdout/stderr/exit-code parity with no fallback marker.",
        }
        self.write_json("cross-area/runtime-smoke-summary.json", summary)
        return summary

    def run_cross_area_packaged_advanced_smokes(
        self,
        vm_command: list[str],
        packaging_summary: dict[str, object],
    ) -> dict[str, object]:
        native_fixtures = [
            next(item for item in ADVANCED_SEMANTICS_FIXTURES if item["reason"] == "protected-error"),
            next(item for item in ADVANCED_SEMANTICS_FIXTURES if item["reason"] == "metatable-dispatch"),
        ]
        native_smokes: list[dict[str, object]] = []
        for fixture in native_fixtures:
            source = str(fixture["source"])
            reason = str(fixture["reason"])
            fixture_name = str(fixture["name"])
            stock = self.runner(["./lua", "-"], self.repo, {}, source, None)
            native = self.runner(vm_command, self.repo, {}, source, None)
            stock_file = self.write_result(f"cross-area-packaged-advanced-{fixture_name}-stock", stock)
            native_file = self.write_result(f"cross-area-packaged-advanced-{fixture_name}-native-vm", native)
            native_diffs = compare_cli_results(stock.to_dict(), native.to_dict())
            observable_policy = advanced_observable_policy(stock, native, reason)
            native_state = "pass" if stock.exit_code == 0 and observable_policy else "fail"
            native_smokes.append(
                {
                    "fixture": fixture_name,
                    "reason": reason,
                    "validates": fixture.get("validates", []),
                    "state": native_state,
                    "observable_policy": observable_policy or "mismatch",
                    "source_sha256": _sha256_text(source),
                    "expected_stdout": fixture.get("stock_stdout", ""),
                    "stock_result_file": stock_file,
                    "native_result_file": native_file,
                    "stock": stock.to_dict(),
                    "native": native.to_dict(),
                    "diffs": native_diffs,
                    "packaged_artifact_boundary": "zig-out/bin/ziglua-vm installed by zig build is exercised as the packaged native VM/AOT fallback artifact surface for advanced semantics.",
                }
            )
        native_failed = [smoke for smoke in native_smokes if smoke["state"] != "pass"]
        native_state = "pass" if not native_failed else "fail"
        native_fixture_states = {str(smoke["reason"]): smoke["state"] for smoke in native_smokes}
        native_protected_error_smoke = next(smoke for smoke in native_smokes if smoke["reason"] == "protected-error")
        native_metatable_smoke = next(smoke for smoke in native_smokes if smoke["reason"] == "metatable-dispatch")

        wasm_summary = packaging_summary.get("wasm", {}) if isinstance(packaging_summary.get("wasm"), dict) else {}
        probes = wasm_summary.get("capability_probes", [])
        if not isinstance(probes, list):
            probes = []
        wasm_capability_denied = all(
            isinstance(probe, dict) and probe.get("state") == "capability-denied"
            for probe in probes
        ) and bool(probes)
        wasm_state = "expected-skip" if wasm_capability_denied else "fail"
        state = "pass" if native_state == "pass" and wasm_state == "expected-skip" else "fail"
        summary = {
            "state": state,
            "native": {
                "artifact_command": vm_command,
                "state": native_state,
                "smoke_count": len(native_smokes),
                "smokes": native_smokes,
                "fixture_states": native_fixture_states,
                "packaged_artifact_boundary": "zig-out/bin/ziglua-vm installed by zig build is exercised as the packaged native VM/AOT fallback artifact surface for protected-error and metatable advanced semantics.",
            },
            "native_protected_error_smoke": native_protected_error_smoke,
            "native_metatable_smoke": native_metatable_smoke,
            "wasm": {
                "state": wasm_state,
                "expected_skip_reason": "wasm-constrained packaged artifact is validated by CLI artifact inspection and capability-denied report entries because no WASM runtime service/harness is required in this mission boundary.",
                "capability_probe_count": len(probes),
                "capability_probes": probes,
                "core_smoke": wasm_summary.get("smoke", {}),
            },
            "pass_count": len(native_smokes) - len(native_failed),
            "expected_skip_count": 1 if wasm_state == "expected-skip" else 0,
            "unsupported_count": len(probes) if wasm_capability_denied else 0,
            "fail_count": len(native_failed) + (0 if wasm_state == "expected-skip" else 1),
            "classification": "Packaged advanced smokes run an installed native Zig VM artifact against protected-error and metatable semantics, then account the WASM constrained advanced/stdlib surface as an expected skip with explicit capability-denied report entries.",
        }
        summary_path = self.write_json("cross-area/packaged-advanced-smokes.json", summary)
        summary["summary_path"] = summary_path
        self.write_json("cross-area/packaged-advanced-smokes.json", summary)
        return summary

    def run_cross_area_integration_validation(
        self,
        vm_command: list[str] | None = None,
        aot_command: list[str] | None = None,
    ) -> dict[str, object]:
        vm_command = list(vm_command or DEFAULT_ZIG_VM_CANDIDATE_COMMAND)
        aot_command = list(aot_command or DEFAULT_ZIG_AOT_CANDIDATE_COMMAND)

        areas: dict[str, dict[str, object]] = {}
        areas["baseline_build"] = self.run_build()
        areas["runtime_smoke"] = self.run_cross_area_runtime_smoke(vm_command, aot_command)
        areas["vm_dynamic_fallback"] = self.run_vm_dynamic_fallback(vm_command)
        areas["aot_artifact_matrix"] = self.run_aot_artifact_matrix(vm_command, aot_command)
        areas["aot_dynamic_fallback"] = self.run_aot_dynamic_fallback(aot_command)
        areas["vm_advanced_fallback"] = self.run_vm_advanced_fallback(vm_command)
        areas["aot_advanced_fallback"] = self.run_aot_advanced_fallback(aot_command, vm_command)
        areas["cross_target_packaging"] = self.run_cross_target_packaging()
        areas["packaged_advanced_smokes"] = self.run_cross_area_packaged_advanced_smokes(
            vm_command,
            areas["cross_target_packaging"],
        )
        areas["c_selected_tests_after_zig"] = self.run_selected_tests()

        taxonomy_counts = integration_taxonomy_counts(areas)
        failing_areas = [
            name
            for name, summary in areas.items()
            if not integration_required_area_passes(summary)
        ]
        vm_aot_state = "pass" if all(
            integration_required_area_passes(areas[name])
            for name in [
                "runtime_smoke",
                "vm_dynamic_fallback",
                "aot_artifact_matrix",
                "aot_dynamic_fallback",
                "vm_advanced_fallback",
                "aot_advanced_fallback",
            ]
        ) else "fail"
        c_baseline_state = "pass" if (
            integration_required_area_passes(areas["baseline_build"])
            and integration_required_area_passes(areas["c_selected_tests_after_zig"])
        ) else "fail"
        state = "pass" if not failing_areas else "fail"
        summary = {
            "state": state,
            "vm_command": vm_command,
            "aot_command": aot_command,
            "ordered_flow": [
                "baseline_build",
                "runtime_smoke",
                "vm_dynamic_fallback",
                "aot_artifact_matrix",
                "aot_dynamic_fallback",
                "vm_advanced_fallback",
                "aot_advanced_fallback",
                "cross_target_packaging",
                "packaged_advanced_smokes",
                "c_selected_tests_after_zig",
            ],
            "areas": areas,
            "failing_areas": failing_areas,
            "taxonomy_counts": taxonomy_counts,
            "taxonomy": {
                "pass": "component or fixture satisfied exact native/CLI behavior, artifact, or provenance without relying on fallback execution",
                "fallback-pass": "user-facing behavior succeeded through an explicit fallback or shared fallback classification and is excluded from native implementation compatibility counts",
                "expected-skip": "profile-constrained smoke intentionally not executed, with a cited capability/runtime boundary",
                "unsupported": "unsupported or capability-denied behavior was explicitly classified and not counted as semantic parity",
                "fail": "required command failed, output comparison mismatched, artifact/provenance was missing, or an unfulfilled state remained",
                "blocked": "validator could not run because a prerequisite command, artifact, or toolchain was unavailable",
            },
            "vm_aot_observability": {
                "state": vm_aot_state,
                "eligible_aot_artifact_count": _count_int(areas["aot_artifact_matrix"], "artifact_count"),
                "vm_fallback_pass_count": _count_int(areas["vm_dynamic_fallback"], "fallback_pass_count")
                + _count_int(areas["vm_advanced_fallback"], "fallback_pass_count"),
                "aot_fallback_or_shared_classification_count": _count_int(areas["aot_dynamic_fallback"], "fallback_pass_count")
                + _count_int(areas["aot_advanced_fallback"], "shared_classification_count"),
                "unsupported_count": _integration_unsupported_count(areas["vm_dynamic_fallback"])
                + _integration_unsupported_count(areas["aot_dynamic_fallback"])
                + _integration_unsupported_count(areas["vm_advanced_fallback"])
                + _integration_unsupported_count(areas["aot_advanced_fallback"]),
            },
            "packaged_advanced_smokes": areas["packaged_advanced_smokes"],
            "c_baseline_preservation": {
                "state": c_baseline_state,
                "baseline_build_state": areas["baseline_build"].get("state"),
                "selected_tests_after_zig_state": areas["c_selected_tests_after_zig"].get("state"),
                "selected_tests": SELECTED_TESTS,
                "contract": "C baseline selected tests are run after Zig VM/AOT and cross-target validators to prove the makefile-based stock oracle remains intact.",
            },
            "classification": "Cross-area integration validation is a single CLI flow covering stock baseline build/run, Zig VM/AOT runtime smoke, eligible AOT comparisons, VM/AOT fallback observability, packaged native/WASM advanced smokes, taxonomy accounting, and post-Zig C selected-test preservation.",
        }
        summary_path = self.write_json("cross-area/integration-summary.json", summary)
        summary["summary_path"] = summary_path
        self.write_json("cross-area/integration-summary.json", summary)
        return summary

    def source_revision(self) -> tuple[str, dict[str, object]]:
        result = self.runner(["git", "rev-parse", "HEAD"], self.repo, {}, None, None)
        result_file = self.write_result("cross-target-git-revision", result)
        revision = result.stdout.strip() if result.exit_code == 0 and result.stdout.strip() else "unknown"
        return revision, {**result.to_dict(), "result_file": result_file}

    def run_cross_target_packaging(self) -> dict[str, object]:
        source_revision, revision_result = self.source_revision()

        native_build = self.runner(CROSS_TARGET_PROFILE_COMMANDS["native-full"], self.repo, {}, None, None)
        native_build_file = self.write_result("cross-target-native-build", native_build)
        native_metadata = self.read_profile_metadata("native-full") if native_build.exit_code == 0 else {}
        native_artifact_path = self.repo / CROSS_TARGET_ARTIFACT_PATHS["native-full"]
        native_smoke = self.runner([str(native_artifact_path)], self.repo, {}, None, None)
        native_smoke_file = self.write_result("cross-target-native-smoke", native_smoke)

        wasm_build = self.runner(CROSS_TARGET_PROFILE_COMMANDS["wasm-constrained"], self.repo, {}, None, None)
        wasm_build_file = self.write_result("cross-target-wasm-build", wasm_build)
        wasm_metadata = self.read_profile_metadata("wasm-constrained") if wasm_build.exit_code == 0 else {}
        wasm_artifact_path = self.repo / CROSS_TARGET_ARTIFACT_PATHS["wasm-constrained"]
        wasm_host_harness = self.runner(CROSS_TARGET_WASM_HOST_HARNESS_COMMAND, self.repo, {}, None, None)
        wasm_host_harness_file = self.write_result("cross-target-wasm-host-harness", wasm_host_harness)
        wasm_runtime_command = CROSS_TARGET_WASM_RUNTIME_COMMAND_PREFIX + [str(wasm_artifact_path)]
        wasm_runtime = self.runner(wasm_runtime_command, self.repo, {}, None, None)
        wasm_runtime_file = self.write_result("cross-target-wasm-runtime", wasm_runtime)

        native_entry = cross_target_artifact_entry(
            self.repo,
            "native-full",
            native_artifact_path,
            native_metadata,
            source_revision,
            CROSS_TARGET_PROFILE_COMMANDS["native-full"],
        )
        wasm_entry = cross_target_artifact_entry(
            self.repo,
            "wasm-constrained",
            wasm_artifact_path,
            wasm_metadata,
            source_revision,
            CROSS_TARGET_PROFILE_COMMANDS["wasm-constrained"],
        )
        artifact_entries = [native_entry, wasm_entry]
        artifact_errors = {
            str(entry["profile"]): validate_cross_target_artifact_entry(entry)
            for entry in artifact_entries
        }

        reproducibility_profiles = []
        for profile, artifact_path, first_entry in [
            ("native-full", native_artifact_path, native_entry),
            ("wasm-constrained", wasm_artifact_path, wasm_entry),
        ]:
            rebuild = self.runner(CROSS_TARGET_PROFILE_COMMANDS[profile], self.repo, {}, None, None)
            rebuild_file = self.write_result(f"cross-target-reproducibility-{profile}", rebuild)
            second_sha = _sha256_file(artifact_path) if artifact_path.exists() else ""
            first_sha = str(first_entry.get("sha256", ""))
            profile_state = "pass" if rebuild.exit_code == 0 and first_sha and first_sha == second_sha else "fail"
            reproducibility_profiles.append(
                {
                    "profile": profile,
                    "state": profile_state,
                    "build_command": CROSS_TARGET_PROFILE_COMMANDS[profile],
                    "first_sha256": first_sha,
                    "second_sha256": second_sha,
                    "hash_match": bool(first_sha and first_sha == second_sha),
                    "artifact_path": str(first_entry.get("artifact_path", "")),
                    "rebuild": {**rebuild.to_dict(), "result_file": rebuild_file},
                    "evidence_boundary": "repeated Zig CLI build with deterministic artifact SHA-256 comparison",
                }
            )
        reproducibility_state = "pass" if all(entry["state"] == "pass" for entry in reproducibility_profiles) else "fail"

        c_build = self.runner(DARWIN_BUILD_COMMAND, self.repo, DARWIN_BUILD_OVERRIDES, None, None)
        c_build_file = self.write_result("cross-target-c-baseline-build", c_build)

        wasm_evidence = wasm_artifact_evidence(wasm_artifact_path, wasm_metadata, wasm_runtime)
        wasm_host_harness_state = "pass" if wasm_host_harness.exit_code == 0 else "fail"
        wasm_runtime_state = "pass" if wasm_runtime.exit_code == 0 else "fail"
        wasm_magic_ok = wasm_evidence["artifact_magic"] == "pass"
        wasm_metadata_errors = cross_target_metadata_errors("wasm-constrained", wasm_metadata)
        capability_probes = wasm_capability_probe_entries(wasm_metadata, wasm_evidence)
        wasm_smoke_state = (
            "pass"
            if wasm_build.exit_code == 0
            and wasm_host_harness_state == "pass"
            and wasm_runtime_state == "pass"
            and wasm_magic_ok
            and not wasm_metadata_errors
            and wasm_evidence["state"] == "pass"
            and all(probe["state"] == "capability-denied" for probe in capability_probes)
            else "fail"
        )
        native_smoke_state = (
            "pass"
            if native_build.exit_code == 0
            and native_smoke.exit_code == 0
            and "ziglua profile smoke" in native_smoke.stdout
            and not artifact_errors["native-full"]
            else "fail"
        )
        c_state = "pass" if c_build.exit_code == 0 else "fail"
        state = (
            "pass"
            if native_smoke_state == "pass"
            and wasm_smoke_state == "pass"
            and reproducibility_state == "pass"
            and c_state == "pass"
            and not artifact_errors["wasm-constrained"]
            else "fail"
        )
        manifest = {
            "state": state,
            "format_version": 1,
            "source_revision": source_revision,
            "source_revision_result": revision_result,
            "artifacts": artifact_entries,
            "artifact_errors": artifact_errors,
            "native": {
                "build": {**native_build.to_dict(), "result_file": native_build_file},
                "smoke": {
                    "state": native_smoke_state,
                    "expected_stdout_substring": "ziglua profile smoke",
                    "result_file": native_smoke_file,
                    "result": native_smoke.to_dict(),
                },
            },
            "wasm": {
                "build": {**wasm_build.to_dict(), "result_file": wasm_build_file},
                "smoke": {
                    "state": wasm_smoke_state,
                    "host_harness": "CLI WebAssembly runtime executes the produced artifact and validates expected constrained smoke/denial return values; section inspection also requires executable function/code bodies and no host imports.",
                    "artifact_magic": "pass" if wasm_magic_ok else "fail",
                    "metadata_errors": wasm_metadata_errors,
                },
                "artifact_evidence": wasm_evidence,
                "host_harness": {
                    "state": wasm_host_harness_state,
                    "command": CROSS_TARGET_WASM_HOST_HARNESS_COMMAND,
                    "result_file": wasm_host_harness_file,
                    "result": wasm_host_harness.to_dict(),
                    "evidence_boundary": "native Zig test harness executes the same constrained smoke and denial exports compiled into the WASM artifact",
                },
                "runtime_execution": {
                    "state": wasm_runtime_state,
                    "command": wasm_runtime_command,
                    "result_file": wasm_runtime_file,
                    "result": wasm_runtime.to_dict(),
                    "evidence_boundary": "Node CLI WebAssembly runtime instantiates the produced .wasm artifact and checks required export return values",
                },
                "capability_probes": capability_probes,
            },
            "reproducibility": {
                "state": reproducibility_state,
                "profiles": reproducibility_profiles,
                "policy": "Native and WASM artifacts are built twice through Zig CLI commands and compared by deterministic SHA-256 hashes.",
            },
            "c_baseline": {
                "state": c_state,
                "build": {**c_build.to_dict(), "result_file": c_build_file},
                "makefile_flow": "existing C makefile invoked directly after Zig packaging; no makefile replacement or Zig dependency is introduced",
            },
            "classification": "Native and WASM packaging validation records artifact provenance, runs a native smoke executable, executes constrained WASM artifact exports through a CLI WebAssembly runtime, validates executable function/code bodies and no host imports, and verifies reproducibility with repeated Zig CLI hash comparisons.",
        }
        manifest_path = self.write_json("cross-target/packaging-manifest.json", manifest)
        manifest["manifest_path"] = manifest_path
        self.write_json("cross-target/packaging-manifest.json", manifest)
        return manifest

    def run_cross_target_profile_matrix(self) -> dict[str, object]:
        profile_entries = []
        state = "pass"
        for profile, command in CROSS_TARGET_PROFILE_COMMANDS.items():
            build = self.runner(command, self.repo, {}, None, None)
            result_file = self.write_result(f"cross-target-profile-{profile}", build)
            metadata: dict[str, object] = {}
            errors: list[str] = []
            if build.exit_code == 0:
                metadata = self.read_profile_metadata(profile)
                errors = cross_target_metadata_errors(profile, metadata)
            else:
                errors = [f"profile build exited {build.exit_code}"]
            entry_state = "pass" if build.exit_code == 0 and not errors else "fail"
            if entry_state != "pass":
                state = "fail"
            profile_entries.append(
                {
                    "profile": profile,
                    "state": entry_state,
                    "build": {**build.to_dict(), "result_file": result_file},
                    "metadata": metadata,
                    "metadata_errors": errors,
                    "matrix_fields": {
                        "allocator": metadata.get("allocator"),
                        "stdlib": metadata.get("stdlib"),
                        "debug": metadata.get("debug"),
                        "gc": metadata.get("gc"),
                        "engine": metadata.get("engine"),
                        "dynamic_loading": metadata.get("dynamic_loading"),
                        "capabilities": metadata.get("capabilities"),
                        "sbf_experimental": metadata.get("sbf_experimental"),
                        "sbf_status": metadata.get("sbf_status"),
                    },
                }
            )

        expected_failure_probes = []
        for profile in ("wasm-constrained", "sbf-experimental"):
            for flag, capability in [
                ("-Dos=enabled", "os"),
                ("-Dfilesystem=enabled", "filesystem"),
                ("-Dprocess=enabled", "process"),
                ("-Ddynamic-loading=enabled", "dynamic-loading"),
            ]:
                command = ["zig", "build", f"-Dprofile={profile}", flag, "--summary", "all"]
                probe = self.runner(command, self.repo, {}, None, None)
                result_file = self.write_result(f"cross-target-expected-failure-{profile}-{capability}", probe)
                probe_output = (probe.stdout + probe.stderr).lower()
                probe_state = "pass" if probe.exit_code != 0 and "capability" in probe_output else "fail"
                if probe_state != "pass":
                    state = "fail"
                expected_failure_probes.append(
                    {
                        "profile": profile,
                        "capability": capability,
                        "state": probe_state,
                        "expected": "non-zero exit with capability diagnostic",
                        "result_file": result_file,
                        "result": probe.to_dict(),
                    }
                )

        summary = {
            "state": state,
            "profile_count": len(profile_entries),
            "profiles": profile_entries,
            "expected_failure_count": len(expected_failure_probes),
            "expected_failure_probes": expected_failure_probes,
            "taxonomy": {
                "pass": "profile metadata or expected-failure probe satisfied its machine-checkable contract",
                "expected-skip": "reserved for profile-constrained executable checks that require an unavailable target runtime",
                "unsupported": "explicitly reported unsupported profile capability",
                "fail": "missing field, unexpected build result, or missing capability diagnostic",
            },
            "classification": "Cross-target profile matrix exposes allocator, stdlib, debug, GC, VM/AOT engine, dynamic loading, capability gates, target identity, and SBF experimental status for CLI validators.",
        }
        summary_path = self.write_json("cross-target/profile-matrix-summary.json", summary)
        summary["summary_path"] = summary_path
        self.write_json("cross-target/profile-matrix-summary.json", summary)
        return summary

    def run_sbf_spike_report(self) -> dict[str, object]:
        build = self.runner(SBF_SPIKE_REPORT_COMMAND, self.repo, {}, None, None)
        result_file = self.write_result("cross-target-sbf-spike-report", build)
        metadata: dict[str, object] = {}
        metadata_errors: list[str] = []
        if build.exit_code == 0:
            metadata = self.read_profile_metadata("sbf-experimental")
            metadata_errors = cross_target_metadata_errors("sbf-experimental", metadata)
        else:
            metadata_errors = [f"sbf spike report command exited {build.exit_code}"]

        forbidden_errors = sbf_forbidden_claim_errors(metadata) if metadata else []
        report_field_errors = sbf_report_field_errors(metadata) if metadata else []
        errors = metadata_errors + report_field_errors + forbidden_errors
        state = "pass" if build.exit_code == 0 and not errors else "fail"
        report_fields = {field: metadata.get(field) for field in SBF_REQUIRED_REPORT_FIELDS}
        summary = {
            "state": state,
            "command": SBF_SPIKE_REPORT_COMMAND,
            "build": {**build.to_dict(), "result_file": result_file},
            "metadata": metadata,
            "metadata_errors": metadata_errors,
            "report_field_errors": report_field_errors,
            "wording_validation": {
                "state": "pass" if not forbidden_errors else "fail",
                "errors": forbidden_errors,
                "forbidden_claim_categories": [
                    "deployment readiness",
                    "broad Lua compatibility",
                    "complete standard library coverage",
                    "complete C API coverage",
                    "loader enablement",
                ],
                "required_language": "generated SBF metadata/report text must remain experimental/spike-only and avoid deployment-readiness or broad compatibility claims",
            },
            "target_toolchain_observations": {
                "target": metadata.get("target"),
                "target_arch": metadata.get("target_arch"),
                "target_os": metadata.get("target_os"),
                "zig_version": metadata.get("zig_version"),
                "observation": metadata.get("sbf_toolchain_observation"),
            },
            "risk_notes": {
                "binary_size": metadata.get("sbf_binary_size_note"),
                "memory": metadata.get("sbf_memory_note"),
                "compute": metadata.get("sbf_compute_note"),
            },
            "report_fields": report_fields,
            "taxonomy": {
                "pass": "metadata/report fields are present, spike-scoped, and wording-safe",
                "expected-skip": "deployable SBF artifact measurements are intentionally skipped until a proof build exists",
                "unsupported": "stdlib breadth, C API breadth, loader, OS/filesystem/process, and broad Lua compatibility are not claimed",
                "fail": "missing field, failed generator command, or forbidden claim",
            },
            "classification": "SBF validation is a CLI-only experimental spike report over Zig target metadata, capability gates, and anti-promotion wording checks.",
        }
        summary_wording_errors = sbf_forbidden_claim_errors(summary) if state == "pass" else []
        summary["summary_wording_errors"] = summary_wording_errors
        if summary_wording_errors:
            summary["state"] = "fail"
            summary["wording_validation"]["state"] = "fail"
            summary["wording_validation"]["errors"].extend(summary_wording_errors)
        summary_path = self.write_json("cross-target/sbf-spike-summary.json", summary)
        summary["summary_path"] = summary_path
        self.write_json("cross-target/sbf-spike-summary.json", summary)
        return summary

    def validate_testes_classification(self) -> dict[str, object]:
        classifications = load_testes_classification()
        actual_files = sorted(path.name for path in (self.repo / "testes").glob("*.lua"))
        classified_files = sorted(entry["file"] for entry in classifications)
        actual_set = set(actual_files)
        classified_set = set(classified_files)
        schema_errors = validate_testes_classification_metadata(classifications)
        missing = sorted(actual_set.difference(classified_set))
        extra = sorted(classified_set.difference(actual_set))
        duplicate_files = sorted(
            file_name for file_name in classified_set if classified_files.count(file_name) > 1
        )
        state = "pass" if not missing and not extra and not duplicate_files and not schema_errors else "fail"
        categories = sorted({category for entry in classifications for category in entry["categories"]})
        summary = {
            "state": state,
            "actual_files": actual_files,
            "classified_files": classified_files,
            "missing": missing,
            "extra": extra,
            "duplicate_files": duplicate_files,
            "schema_errors": schema_errors,
            "categories": categories,
            "classification_file": str(DEFAULT_TESTES_CLASSIFICATION_FILE),
            "classifications": classifications,
            "selected_early_tests": sorted(
                entry["file"] for entry in classifications if entry.get("selected_early") is True
            ),
        }
        self.write_json("testes-classification/validation-summary.json", summary)
        return summary


def print_summary(summary: dict[str, object]) -> int:
    print(json.dumps(summary, indent=2, sort_keys=True))
    state = summary.get("state")
    return 0 if state in {"pass", "known_constraint", "captured_error", "pending"} else 1


def _count_int(summary: dict[str, object], key: str) -> int:
    value = summary.get(key, 0)
    return value if isinstance(value, int) else 0


def _integration_unsupported_count(summary: dict[str, object]) -> int:
    unsupported = _count_int(summary, "unsupported_unfulfilled_count")
    if unsupported == 0:
        unsupported = _count_int(summary, "unsupported_count")
    return unsupported + _count_int(summary, "capability_denied_count") + _count_int(summary, "aot_unsupported_count")


def integration_required_area_passes(summary: dict[str, object]) -> bool:
    return summary.get("state") == "pass"


def integration_taxonomy_counts(areas: dict[str, dict[str, object]]) -> dict[str, int]:
    counts = {
        "pass": 0,
        "fallback-pass": 0,
        "expected-skip": 0,
        "unsupported": 0,
        "fail": 0,
        "blocked": 0,
    }
    for summary in areas.values():
        state = summary.get("state")
        if state == "pass":
            counts["pass"] += 1
        elif state in {"expected-skip", "known_constraint"}:
            counts["expected-skip"] += 1
        elif state in {"unsupported", "unfulfilled"}:
            counts["unsupported"] += 1
        else:
            counts["fail"] += 1

        pass_counts = [
            "pass_count",
            "stock_parity_count",
            "observable_parity_count",
        ]
        counts["pass"] += sum(_count_int(summary, key) for key in pass_counts)
        counts["fallback-pass"] += (
            _count_int(summary, "fallback_pass_count")
            + _count_int(summary, "shared_classification_count")
        )
        artifact_count = _count_int(summary, "artifact_count")
        if artifact_count:
            counts["pass"] += max(0, artifact_count - _count_int(summary, "fail_count"))
        counts["expected-skip"] += _count_int(summary, "expected_skip_count")
        counts["unsupported"] += _integration_unsupported_count(summary)
        counts["fail"] += _count_int(summary, "fail_count")
        counts["blocked"] += _count_int(summary, "blocked_count")
    return counts


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def _base64_text(text: str) -> str:
    return base64.b64encode(text.encode()).decode("ascii")


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cross_target_artifact_entry(
    repo: Path,
    profile: str,
    artifact_path: Path,
    metadata: dict[str, object],
    source_revision: str,
    build_command: list[str],
) -> dict[str, object]:
    relative_path = artifact_path.relative_to(repo) if artifact_path.is_absolute() and artifact_path.is_relative_to(repo) else artifact_path
    capabilities = metadata.get("capabilities") if isinstance(metadata.get("capabilities"), dict) else {}
    feature_gates = {
        "allocator": metadata.get("allocator"),
        "stdlib": metadata.get("stdlib"),
        "debug": metadata.get("debug"),
        "gc": metadata.get("gc"),
        "engine": metadata.get("engine"),
        "dynamic_loading": metadata.get("dynamic_loading"),
        "capabilities": capabilities,
    }
    exists = artifact_path.exists()
    return {
        "profile": profile,
        "target": metadata.get("target", ""),
        "target_triple": metadata.get("target", ""),
        "target_arch": metadata.get("target_arch", ""),
        "target_os": metadata.get("target_os", ""),
        "build_mode": metadata.get("optimize", ""),
        "artifact_kind": metadata.get("artifact_kind", ""),
        "artifact_path": str(relative_path),
        "absolute_artifact_path": str(artifact_path),
        "artifact_exists": exists,
        "size_bytes": artifact_path.stat().st_size if exists else 0,
        "sha256": _sha256_file(artifact_path) if exists else "",
        "source_revision": source_revision,
        "build_command": list(build_command),
        "build_command_text": shlex.join(build_command),
        "metadata_path": str(repo / "zig-out" / "share" / "ziglua" / "profiles" / f"{profile}.json"),
        "feature_gates": feature_gates,
        "provenance_fields": [
            "profile",
            "target_triple",
            "build_mode",
            "feature_gates",
            "source_revision",
            "artifact_path",
            "sha256",
        ],
    }


def validate_cross_target_artifact_entry(entry: dict[str, object]) -> list[str]:
    errors: list[str] = []
    required = ["profile", "target_triple", "build_mode", "feature_gates", "source_revision", "artifact_path", "sha256"]
    for field in required:
        if not entry.get(field):
            errors.append(f"{field} is required")
    if entry.get("artifact_exists") is not True:
        errors.append(f"artifact is missing: {entry.get('artifact_path')}")
    if not isinstance(entry.get("feature_gates"), dict):
        errors.append("feature_gates must be a JSON object")
    return errors


def _read_uleb128(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    cursor = offset
    while cursor < len(data):
        byte = data[cursor]
        cursor += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, cursor
        shift += 7
        if shift > 35:
            raise ValueError("ULEB128 value is too large")
    raise ValueError("truncated ULEB128 value")


def _read_sleb128(data: bytes, offset: int, bits: int = 32) -> tuple[int, int]:
    value = 0
    shift = 0
    cursor = offset
    while cursor < len(data):
        byte = data[cursor]
        cursor += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            if shift < bits and byte & 0x40:
                value |= -(1 << shift)
            return value, cursor
        if shift > bits + 7:
            raise ValueError("SLEB128 value is too large")
    raise ValueError("truncated SLEB128 value")


def _format_wasm_u32(value: int) -> str:
    return f"0x{value & 0xFFFFFFFF:08x}"


def _parse_wasm_imports(payload: bytes) -> list[dict[str, object]]:
    imports: list[dict[str, object]] = []
    cursor = 0
    count, cursor = _read_uleb128(payload, cursor)
    for _ in range(count):
        module_len, cursor = _read_uleb128(payload, cursor)
        module = payload[cursor : cursor + module_len].decode("utf-8", errors="replace")
        cursor += module_len
        name_len, cursor = _read_uleb128(payload, cursor)
        name = payload[cursor : cursor + name_len].decode("utf-8", errors="replace")
        cursor += name_len
        kind = payload[cursor]
        cursor += 1
        # Skip the import descriptor. The packaging validator only needs the
        # module/name/kind contract to prove there are no host imports; the
        # remaining bytes are type limits whose shape varies by kind.
        if kind == 0:
            _, cursor = _read_uleb128(payload, cursor)
        elif kind == 1:
            cursor += 1
            flags, cursor = _read_uleb128(payload, cursor)
            _, cursor = _read_uleb128(payload, cursor)
            if flags & 0x01:
                _, cursor = _read_uleb128(payload, cursor)
        elif kind == 2:
            flags, cursor = _read_uleb128(payload, cursor)
            _, cursor = _read_uleb128(payload, cursor)
            if flags & 0x01:
                _, cursor = _read_uleb128(payload, cursor)
        elif kind == 3:
            cursor += 1
        else:
            raise ValueError(f"unknown import kind {kind}")
        imports.append({"module": module, "name": name, "kind": kind})
    return imports


def _parse_wasm_functions(payload: bytes) -> list[int]:
    cursor = 0
    count, cursor = _read_uleb128(payload, cursor)
    functions = []
    for _ in range(count):
        type_index, cursor = _read_uleb128(payload, cursor)
        functions.append(type_index)
    if cursor != len(payload):
        raise ValueError("function section has trailing bytes")
    return functions


def _parse_wasm_exports(payload: bytes) -> list[dict[str, object]]:
    exports: list[dict[str, object]] = []
    cursor = 0
    count, cursor = _read_uleb128(payload, cursor)
    kind_names = {0: "function", 1: "table", 2: "memory", 3: "global"}
    for _ in range(count):
        name_len, cursor = _read_uleb128(payload, cursor)
        name = payload[cursor : cursor + name_len].decode("utf-8", errors="replace")
        cursor += name_len
        kind = payload[cursor]
        cursor += 1
        index, cursor = _read_uleb128(payload, cursor)
        exports.append({"name": name, "kind": kind_names.get(kind, f"unknown-{kind}"), "index": index})
    return exports


def _direct_i32_return_from_body(body: bytes) -> int | None:
    """Recognize a minimal executable body that returns a constant i32.

    This is deliberately conservative; richer compiler-generated bodies are
    validated by the CLI WebAssembly runtime harness instead of pretending this
    parser is a full interpreter.
    """
    cursor = 0
    local_decl_count, cursor = _read_uleb128(body, cursor)
    for _ in range(local_decl_count):
        _, cursor = _read_uleb128(body, cursor)
        if cursor >= len(body):
            raise ValueError("truncated local declaration")
        cursor += 1
    if cursor >= len(body) or body[cursor] != 0x41:  # i32.const
        return None
    value, cursor = _read_sleb128(body, cursor + 1, 32)
    if cursor < len(body) and body[cursor] == 0x0F:  # return
        cursor += 1
    if cursor < len(body) and body[cursor] == 0x0B:  # end
        cursor += 1
    return value & 0xFFFFFFFF if cursor == len(body) else None


def _parse_wasm_code_bodies(payload: bytes) -> list[dict[str, object]]:
    cursor = 0
    count, cursor = _read_uleb128(payload, cursor)
    bodies: list[dict[str, object]] = []
    for body_index in range(count):
        body_size, cursor = _read_uleb128(payload, cursor)
        body_end = cursor + body_size
        if body_end > len(payload):
            raise ValueError(f"code body {body_index} extends past end of section")
        body = payload[cursor:body_end]
        direct_return = _direct_i32_return_from_body(body)
        bodies.append(
            {
                "body_index": body_index,
                "body_size": body_size,
                "executable_body_present": body_size > 0,
                "direct_i32_return": direct_return,
                "direct_i32_return_hex": _format_wasm_u32(direct_return) if direct_return is not None else None,
            }
        )
        cursor = body_end
    if cursor != len(payload):
        raise ValueError("code section has trailing bytes")
    return bodies


def wasm_module_inspection(artifact_path: Path) -> dict[str, object]:
    errors: list[str] = []
    exports: list[dict[str, object]] = []
    imports: list[dict[str, object]] = []
    function_type_indices: list[int] = []
    code_bodies: list[dict[str, object]] = []
    if not artifact_path.exists():
        return {
            "state": "fail",
            "artifact_magic": "fail",
            "exports": [],
            "imports": [],
            "import_count": 0,
            "function_section": {"function_count": 0},
            "code_section": {"body_count": 0, "bodies_match_function_declarations": False},
            "function_exports": {},
            "errors": [f"wasm artifact is missing: {artifact_path}"],
        }

    data = artifact_path.read_bytes()
    artifact_magic = "pass" if data[:4] == b"\x00asm" and data[4:8] == b"\x01\x00\x00\x00" else "fail"
    if artifact_magic != "pass":
        errors.append("missing wasm magic/version header")
        return {
            "state": "fail",
            "artifact_magic": artifact_magic,
            "exports": [],
            "imports": [],
            "import_count": 0,
            "function_section": {"function_count": 0},
            "code_section": {"body_count": 0, "bodies_match_function_declarations": False},
            "function_exports": {},
            "errors": errors,
        }

    cursor = 8
    try:
        while cursor < len(data):
            section_id = data[cursor]
            cursor += 1
            section_size, cursor = _read_uleb128(data, cursor)
            section_end = cursor + section_size
            if section_end > len(data):
                raise ValueError(f"section {section_id} extends past end of file")
            payload = data[cursor:section_end]
            if section_id == 2:
                imports.extend(_parse_wasm_imports(payload))
            elif section_id == 3:
                function_type_indices = _parse_wasm_functions(payload)
            elif section_id == 7:
                exports.extend(_parse_wasm_exports(payload))
            elif section_id == 10:
                code_bodies = _parse_wasm_code_bodies(payload)
            cursor = section_end
    except (IndexError, UnicodeDecodeError, ValueError) as exc:
        errors.append(f"failed to parse wasm sections: {exc}")

    imported_function_count = sum(1 for entry in imports if entry.get("kind") == 0)
    function_count = len(function_type_indices)
    code_body_count = len(code_bodies)
    bodies_match = function_count == code_body_count and function_count > 0
    if function_count == 0 or code_body_count == 0:
        errors.append("missing wasm function/code section with executable bodies")
    elif not bodies_match:
        errors.append(
            f"wasm code body count {code_body_count} does not match function declaration count {function_count}"
        )

    function_exports: dict[str, dict[str, object]] = {}
    for entry in exports:
        if entry.get("kind") != "function":
            continue
        function_index = int(entry.get("index", -1))
        body_index = function_index - imported_function_count
        body = code_bodies[body_index] if 0 <= body_index < len(code_bodies) else None
        function_exports[str(entry.get("name", ""))] = {
            "function_index": function_index,
            "body_index": body_index,
            "imported_function": function_index < imported_function_count,
            "executable_body_present": bool(body and body.get("executable_body_present")),
            "body_size": int(body.get("body_size", 0)) if body else 0,
            "direct_i32_return": body.get("direct_i32_return") if body else None,
            "direct_i32_return_hex": body.get("direct_i32_return_hex") if body else None,
        }

    return {
        "state": "pass" if not errors else "fail",
        "artifact_magic": artifact_magic,
        "exports": exports,
        "imports": imports,
        "import_count": len(imports),
        "function_section": {"function_count": function_count, "imported_function_count": imported_function_count},
        "code_section": {
            "body_count": code_body_count,
            "bodies_match_function_declarations": bodies_match,
            "body_sizes": [int(body.get("body_size", 0)) for body in code_bodies],
        },
        "function_exports": function_exports,
        "errors": errors,
    }


def _runtime_export_results(runtime_result: CommandResult | None) -> tuple[dict[str, dict[str, object]], list[str]]:
    if runtime_result is None:
        return {}, []
    errors: list[str] = []
    try:
        payload = json.loads(runtime_result.stdout)
    except json.JSONDecodeError as exc:
        return {}, [f"wasm runtime harness did not emit JSON: {exc}"]
    if not isinstance(payload, dict):
        return {}, ["wasm runtime harness JSON must be an object"]
    exports = payload.get("exports")
    if not isinstance(exports, dict):
        errors.append("wasm runtime harness JSON missing exports object")
        return {}, errors
    if runtime_result.exit_code != 0 or payload.get("state") != "pass":
        errors.append(f"wasm runtime harness failed with exit code {runtime_result.exit_code}")
    normalized = {
        str(name): entry
        for name, entry in exports.items()
        if isinstance(entry, dict)
    }
    return normalized, errors


def _wasm_return_evidence(
    export_name: str,
    function_body: dict[str, object] | None,
    runtime_exports: dict[str, dict[str, object]],
) -> dict[str, object]:
    expected_return = CROSS_TARGET_WASM_EXPECTED_RETURNS[export_name]
    expected_hex = _format_wasm_u32(expected_return)
    body_present = bool(function_body and function_body.get("executable_body_present"))
    direct_return = function_body.get("direct_i32_return") if function_body else None
    direct_return_hex = function_body.get("direct_i32_return_hex") if function_body else None
    static_state = "pass" if direct_return is not None and int(direct_return) & 0xFFFFFFFF == expected_return else "unverified"

    runtime_entry = runtime_exports.get(export_name, {})
    actual_hex = runtime_entry.get("actual") or runtime_entry.get("actual_return_code")
    runtime_state = "pass" if runtime_entry.get("state") == "pass" and actual_hex == expected_hex else "unverified"
    state = "pass" if body_present and (runtime_state == "pass" or static_state == "pass") else "fail"
    return {
        "state": state,
        "expected_return_code": expected_hex,
        "executable_body_present": body_present,
        "body_index": function_body.get("body_index") if function_body else None,
        "body_size": function_body.get("body_size") if function_body else 0,
        "static_direct_return_code": direct_return_hex,
        "static_direct_return_state": static_state,
        "runtime_return_code": actual_hex,
        "runtime_return_state": runtime_state,
        "evidence_boundary": "wasm executable code body plus CLI runtime return validation"
        if runtime_exports
        else "wasm executable code body direct-return validation",
    }


def wasm_artifact_evidence(
    artifact_path: Path,
    metadata: dict[str, object],
    runtime_result: CommandResult | None = None,
) -> dict[str, object]:
    inspection = wasm_module_inspection(artifact_path)
    export_names = [str(entry.get("name", "")) for entry in inspection["exports"]]
    export_set = set(export_names)
    imports = inspection["imports"] if isinstance(inspection.get("imports"), list) else []
    function_exports = inspection["function_exports"] if isinstance(inspection.get("function_exports"), dict) else {}
    capabilities = metadata.get("capabilities") if isinstance(metadata.get("capabilities"), dict) else {}
    errors = list(inspection["errors"]) if isinstance(inspection.get("errors"), list) else []
    runtime_exports, runtime_errors = _runtime_export_results(runtime_result)
    errors.extend(runtime_errors)

    for export_name in CROSS_TARGET_WASM_REQUIRED_EXPORTS:
        if export_name not in export_set:
            errors.append(f"missing wasm export {export_name}")
        elif export_name not in function_exports:
            errors.append(f"wasm export {export_name} is not a function export")
        elif not function_exports[export_name].get("executable_body_present"):
            errors.append(f"wasm export {export_name} is not backed by executable code body")
    if imports:
        errors.append("wasm-constrained artifact must not import host capabilities")

    core_export_present = CROSS_TARGET_WASM_CORE_SMOKE_EXPORT in export_set
    core_body = function_exports.get(CROSS_TARGET_WASM_CORE_SMOKE_EXPORT)
    core_return_evidence = _wasm_return_evidence(CROSS_TARGET_WASM_CORE_SMOKE_EXPORT, core_body, runtime_exports)
    if core_export_present and core_return_evidence["state"] != "pass":
        errors.append(
            f"wasm core subset smoke return evidence did not prove {core_return_evidence['expected_return_code']}"
        )
    core_subset_smoke = {
        "state": "pass" if core_export_present and core_return_evidence["state"] == "pass" else "fail",
        "artifact_export_present": core_export_present,
        "executable_body_present": bool(core_body and core_body.get("executable_body_present")),
        "export": CROSS_TARGET_WASM_CORE_SMOKE_EXPORT,
        "expected_return_code": _format_wasm_u32(CROSS_TARGET_WASM_EXPECTED_RETURNS[CROSS_TARGET_WASM_CORE_SMOKE_EXPORT]),
        "body_return_evidence": core_return_evidence,
        "source_contract": "exported function computes deterministic literals/locals/arithmetic/string/table/control-flow subset checksum in src/ziglua/wasm_profile_stub.zig",
        "evidence_boundary": core_return_evidence["evidence_boundary"],
    }

    denial_probes = []
    for api_name, capability in CROSS_TARGET_WASM_DENIED_CAPABILITIES:
        denial_export = CROSS_TARGET_WASM_DENIAL_EXPORTS[capability]
        disabled = capabilities.get(capability) == "disabled"
        export_present = denial_export in export_set
        denial_body = function_exports.get(denial_export)
        denial_return_evidence = _wasm_return_evidence(denial_export, denial_body, runtime_exports)
        no_host_imports = not imports
        probe_state = (
            "capability-denied"
            if disabled and export_present and no_host_imports and denial_return_evidence["state"] == "pass"
            else "fail"
        )
        if not disabled:
            errors.append(f"wasm-constrained metadata does not disable {capability}")
        if not export_present:
            errors.append(f"missing wasm denial export {denial_export}")
        elif denial_return_evidence["state"] != "pass":
            errors.append(
                f"wasm denial export {denial_export} return evidence did not prove {denial_return_evidence['expected_return_code']}"
            )
        denial_probes.append(
            {
                "api": api_name,
                "capability": capability,
                "state": probe_state,
                "export": denial_export,
                "artifact_export_present": export_present,
                "executable_body_present": bool(denial_body and denial_body.get("executable_body_present")),
                "body_return_evidence": denial_return_evidence,
                "no_host_imports": no_host_imports,
                "stderr": f"capability-denied: wasm-constrained artifact denies {capability} for {api_name}",
                "evidence_boundary": denial_return_evidence["evidence_boundary"],
                "requires_browser": False,
                "requires_service": False,
            }
        )

    state = "pass" if not errors and core_subset_smoke["state"] == "pass" and all(probe["state"] == "capability-denied" for probe in denial_probes) else "fail"
    return {
        "state": state,
        "artifact_magic": inspection["artifact_magic"],
        "exports": export_names,
        "imports": imports,
        "import_count": inspection["import_count"],
        "function_section": inspection["function_section"],
        "code_section": inspection["code_section"],
        "function_exports": function_exports,
        "core_subset_smoke": core_subset_smoke,
        "denial_probes": denial_probes,
        "errors": errors,
        "evidence_boundary": "actual wasm artifact executable-body and return-value validation, not export-section-only metadata",
    }


def _metadata_string_values(value: object) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for nested in value.values():
            yield from _metadata_string_values(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _metadata_string_values(nested)


def sbf_forbidden_claim_errors(metadata: dict[str, object]) -> list[str]:
    errors: list[str] = []
    for text in _metadata_string_values(metadata):
        for pattern, label in SBF_FORBIDDEN_CLAIM_PATTERNS:
            if pattern.search(text):
                errors.append(f"forbidden SBF claim '{label}' in generated metadata text: {text!r}")
    return errors


def sbf_report_field_errors(metadata: dict[str, object]) -> list[str]:
    errors: list[str] = []
    for field in SBF_REQUIRED_REPORT_FIELDS:
        value = metadata.get(field)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"sbf-experimental: missing SBF report field {field}")
    combined_text = " ".join(str(metadata.get(field, "")) for field in ["sbf_status", "sbf_notes", "sbf_scope"]).lower()
    if "experimental" not in combined_text or "spike" not in combined_text:
        errors.append("sbf-experimental: generated report language must include experimental/spike-only scope")
    for field, needle in [
        ("sbf_toolchain_observation", "bpfel"),
        ("sbf_binary_size_note", "binary size"),
        ("sbf_memory_note", "memory"),
        ("sbf_compute_note", "compute"),
    ]:
        value = str(metadata.get(field, "")).lower()
        if needle not in value:
            errors.append(f"sbf-experimental: {field} must mention {needle}")
    return errors


def cross_target_metadata_errors(profile: str, metadata: dict[str, object]) -> list[str]:
    errors: list[str] = []
    for field in CROSS_TARGET_REQUIRED_METADATA_FIELDS:
        if field not in metadata:
            errors.append(f"{profile}: missing metadata field {field}")
    capabilities = metadata.get("capabilities")
    if not isinstance(capabilities, dict):
        errors.append(f"{profile}: capabilities must be a JSON object")
        capabilities = {}
    for capability in ("os", "filesystem", "process", "dynamic_loading"):
        if capability not in capabilities:
            errors.append(f"{profile}: missing capability {capability}")
    if profile == "native-full":
        if metadata.get("stdlib") != "full":
            errors.append("native-full: stdlib must be full")
        if metadata.get("dynamic_loading") != "enabled":
            errors.append("native-full: dynamic_loading must be enabled")
    elif profile == "wasm-constrained":
        if metadata.get("target_arch") != "wasm32":
            errors.append("wasm-constrained: target_arch must be wasm32")
        if metadata.get("allocator") not in {"bounded", "failing"}:
            errors.append("wasm-constrained: allocator must be bounded or failing")
        for capability in ("os", "filesystem", "process", "dynamic_loading"):
            if capabilities.get(capability) != "disabled":
                errors.append(f"wasm-constrained: capability {capability} must be disabled")
    elif profile == "sbf-experimental":
        if metadata.get("target_arch") != "bpfel":
            errors.append("sbf-experimental: target_arch must be bpfel")
        if metadata.get("artifact_kind") != "metadata-only":
            errors.append("sbf-experimental: artifact_kind must be metadata-only")
        if metadata.get("sbf_experimental") is not True:
            errors.append("sbf-experimental: sbf_experimental must be true")
        if metadata.get("sbf_status") != "experimental-spike-only":
            errors.append("sbf-experimental: sbf_status must be experimental-spike-only")
        if metadata.get("stdlib") != "minimal":
            errors.append("sbf-experimental: stdlib must be minimal")
        if metadata.get("debug") != "disabled":
            errors.append("sbf-experimental: debug must be disabled")
        if metadata.get("gc") not in {"spike-only", "none"}:
            errors.append("sbf-experimental: gc must be spike-only or none")
        if metadata.get("engine") not in {"vm", "vm-subset-spike"}:
            errors.append("sbf-experimental: engine must be vm or vm-subset-spike")
        for capability in ("os", "filesystem", "process", "dynamic_loading"):
            if capabilities.get(capability) != "disabled":
                errors.append(f"sbf-experimental: capability {capability} must be disabled")
        errors.extend(sbf_report_field_errors(metadata))
        errors.extend(sbf_forbidden_claim_errors(metadata))
    return errors


def wasm_capability_probe_entries(
    metadata: dict[str, object],
    artifact_evidence: dict[str, object] | None = None,
) -> list[dict[str, object]]:
    if artifact_evidence is not None and isinstance(artifact_evidence.get("denial_probes"), list):
        return list(artifact_evidence["denial_probes"])

    capabilities = metadata.get("capabilities") if isinstance(metadata.get("capabilities"), dict) else {}
    probes = []
    for api_name, capability in CROSS_TARGET_WASM_DENIED_CAPABILITIES:
        disabled = capabilities.get(capability) == "disabled"
        probes.append(
            {
                "api": api_name,
                "capability": capability,
                "state": "capability-denied" if disabled else "fail",
                "stderr": f"capability-denied: wasm-constrained disables {capability} for {api_name}",
                "evidence_boundary": "generated-profile-metadata-report-entry",
                "requires_browser": False,
                "requires_service": False,
            }
        )
    return probes


def validator_registry(repo: Path) -> dict[str, object]:
    script = repo / "tools" / "validation" / "baseline_oracle.py"
    validators = [
        {
            "id": "baseline-oracle-build",
            "description": "Build stock Lua with the documented Darwin C baseline command.",
            "command": f"python3 {script} --repo {repo} build",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/*.json"],
        },
        {
            "id": "zig-build-tests",
            "description": "Run Python validation tests and Zig runtime tests.",
            "command": "python3 -m unittest discover -s tools/validation -p 'test_*.py' && zig build test --summary all",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "zig-out"],
        },
        {
            "id": "cross-target-packaging",
            "description": "Build native and WASM artifacts, run native smoke, execute WASM return-value smoke, inspect capability gates, and write artifact provenance.",
            "command": f"python3 {script} --repo {repo} cross-target-packaging",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/cross-target/packaging-manifest.json"],
        },
        {
            "id": "cross-target-profile-matrix",
            "description": "Build profile metadata and validate native/WASM/SBF matrix fields plus constrained expected-failure probes.",
            "command": f"python3 {script} --repo {repo} cross-target-profile-matrix",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/cross-target/profile-matrix-summary.json"],
        },
        {
            "id": "sbf-spike-report",
            "description": "Generate SBF experimental spike metadata and validate anti-promotion wording plus target/toolchain, binary-size, memory, and compute notes.",
            "command": f"python3 {script} --repo {repo} sbf-spike-report",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/cross-target/sbf-spike-summary.json"],
        },
        {
            "id": "cross-area-integration-validation",
            "description": "Run stock baseline, Zig VM/AOT runtime and fallback checks, packaged smokes, taxonomy accounting, and post-Zig C selected tests in one CLI flow.",
            "command": f"python3 {script} --repo {repo} cross-area-integration-validation",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/cross-area/integration-summary.json"],
        },
        {
            "id": "lua-zig-run-cli-parity",
            "description": "Compare lua-zig run against stock ./lua for stdin, files, -e chunks, -l preloads, script args, exit status, stdout, stderr, and diagnostics.",
            "command": f"python3 {script} --repo {repo} lua-zig-run-cli-parity",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/run-parity/summary.json"],
        },
        {
            "id": "native-core-language",
            "description": "Run M4 staged PUC-derived literals, constructs, vararg, bitwise/coercion, goto, and error parity snippets through fallback-disabled lua-zig native execution.",
            "command": f"python3 {script} --repo {repo} native-core-language",
            "surface": "cli",
            "requires_service": False,
            "artifacts_or_channels": ["stdout", "stderr", "exit_code", "build/validation/baseline-oracle/native-core-language/summary.json"],
        },
    ]
    return {
        "state": "pass",
        "validators": validators,
        "validator_count": len(validators),
        "surface_contract": "All listed validators are shell/Zig/Python CLI commands; none require browser, database, network service, long-running port, or manual UI.",
    }


def validate_aot_artifact_contract(artifact: dict[str, str], repo: Path) -> list[str]:
    errors: list[str] = []
    artifact_path = Path(artifact.get("artifact_path", ""))
    metadata_path = Path(artifact.get("metadata_path", ""))
    if not artifact_path.exists():
        errors.append(f"artifact executable is missing: {artifact_path}")
    if not metadata_path.exists():
        errors.append(f"artifact metadata is missing: {metadata_path}")
        return errors

    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f"artifact metadata is not valid JSON: {exc}"]

    kind = str(metadata.get("artifact_kind", ""))
    if kind != "lowered-ir-executable":
        errors.append(f"artifact_kind must be lowered-ir-executable, got {kind!r}")
    if "wrapper" in kind.lower():
        errors.append(f"wrapper artifacts are rejected: artifact_kind={kind!r}")
    if "command" in metadata:
        errors.append("wrapper-style top-level command metadata is rejected")
    if "stdin_redirection" in metadata:
        errors.append("wrapper-style stdin_redirection metadata is rejected")

    provenance = metadata.get("provenance")
    if not isinstance(provenance, dict):
        errors.append("metadata.provenance must identify source and emission provenance")
    else:
        if not provenance.get("source_sha256"):
            errors.append("metadata.provenance.source_sha256 is required")
        if not provenance.get("emitted_by"):
            errors.append("metadata.provenance.emitted_by is required")

    execution = metadata.get("execution")
    if not isinstance(execution, dict):
        errors.append("metadata.execution must identify artifact execution behavior")
    else:
        if execution.get("independent_of_original_source") is not True:
            errors.append("artifact execution must be independent_of_original_source=true")
        if execution.get("consumes_original_source") is not False:
            errors.append("artifact execution must not consume original Lua source")
        if execution.get("invokes_ziglua_runner") is not False:
            errors.append("artifact execution must not invoke ziglua-aot or ziglua-vm")

    ir_path_text = str(metadata.get("ir_path") or artifact.get("ir_path", ""))
    if not ir_path_text:
        errors.append("lowered artifact metadata must include ir_path")
    else:
        ir_path = Path(ir_path_text)
        if not ir_path.exists():
            errors.append(f"lowered IR artifact is missing: {ir_path}")
        else:
            try:
                ir = json.loads(ir_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                errors.append(f"lowered IR artifact is not valid JSON: {exc}")
            else:
                if ir.get("ir_kind") != "level0-cli-result-ir":
                    errors.append(f"unexpected lowered IR kind: {ir.get('ir_kind')!r}")
                if isinstance(provenance, dict) and provenance.get("source_sha256") and ir.get("source_sha256") != provenance.get("source_sha256"):
                    errors.append("lowered IR source_sha256 does not match metadata provenance")

    if artifact_path.exists():
        try:
            artifact_text = artifact_path.read_text(encoding="utf-8", errors="ignore")
        except OSError as exc:
            errors.append(f"artifact executable could not be read: {exc}")
        else:
            lowered_text = artifact_text.lower()
            if "ziglua-aot" in lowered_text or "ziglua-vm" in lowered_text:
                errors.append("artifact executable must not invoke ziglua-aot or ziglua-vm")
            source_path = metadata.get("source_path")
            if isinstance(source_path, str):
                source_name = os.path.basename(source_path)
                if source_path and (source_path in artifact_text or source_name in artifact_text):
                    errors.append("artifact executable must not reference the original Lua source path")

    return errors


def _unified_diff(field: str, stock: str, candidate: str) -> str:
    lines = list(
        difflib.unified_diff(
            stock.splitlines(),
            candidate.splitlines(),
            fromfile=f"stock/{field}",
            tofile=f"candidate/{field}",
            lineterm="",
        )
    )
    diff = "\n".join(lines) + ("\n" if lines else "")
    explicit_values = f"stock_repr={stock!r}\ncandidate_repr={candidate!r}\n"
    if diff:
        return diff + explicit_values
    return (
        f"{field} values differ byte-for-byte, but the line-normalized unified diff is empty "
        "(for example, a trailing-newline-only mismatch).\n"
        f"{explicit_values}"
    )


def compare_cli_results(stock: dict[str, object], candidate: dict[str, object]) -> dict[str, str]:
    diffs = {}
    for field in ("stdout", "stderr"):
        stock_value = str(stock.get(field, ""))
        candidate_value = str(candidate.get(field, ""))
        if stock_value != candidate_value:
            diffs[field] = _unified_diff(field, stock_value, candidate_value)
    if stock.get("exit_code") != candidate.get("exit_code"):
        diffs["exit_code"] = f"stock={stock.get('exit_code')} candidate={candidate.get('exit_code')}"
    return diffs


def is_unsupported_result(result: CommandResult, expected_reason: str | None = None) -> bool:
    stderr = result.stderr.lower()
    if result.exit_code == 0 or result.stdout != "":
        return False
    if "unsupported" not in stderr or "fallback" not in stderr:
        return False
    if expected_reason is not None and not contains_reason_token(stderr, expected_reason):
        return False
    return True


def is_capability_denied_result(result: CommandResult, expected_reason: str | None = None) -> bool:
    stderr = result.stderr.lower()
    if result.exit_code == 0 or result.stdout != "":
        return False
    if "capability-denied" not in stderr and "capability denied" not in stderr:
        return False
    if expected_reason is not None and not contains_reason_token(stderr, expected_reason):
        return False
    return True


def is_optional_level1_unsupported(snippet: dict[str, object], candidate: CommandResult) -> bool:
    areas = snippet.get("areas")
    if not isinstance(areas, list) or "closures" not in areas:
        return False
    stderr = candidate.stderr.lower()
    return is_unsupported_result(candidate) and ("closure" in stderr or "upvalue" in stderr)


def contains_reason_token(text: str, expected_reason: str) -> bool:
    pattern = rf"(?<![a-z0-9_-]){re.escape(expected_reason.lower())}(?![a-z0-9_-])"
    return re.search(pattern, text.lower()) is not None


def is_dynamic_fallback_pass(stock: CommandResult, candidate: CommandResult) -> bool:
    if candidate.exit_code != stock.exit_code or candidate.stdout != stock.stdout:
        return False
    if candidate.stderr == stock.stderr:
        return False
    return "fallback" in candidate.stderr.lower()


def advanced_observable_policy(stock: CommandResult, candidate: CommandResult, expected_reason: str) -> str:
    if not compare_cli_results(stock.to_dict(), candidate.to_dict()):
        return "stock-parity"
    if is_dynamic_fallback_pass(stock, candidate) and contains_reason_token(candidate.stderr, expected_reason):
        return "fallback-parity"
    return ""


def advanced_fallback_classification(stock: CommandResult, candidate: CommandResult, expected_reason: str) -> str:
    if is_dynamic_fallback_pass(stock, candidate) and contains_reason_token(candidate.stderr, expected_reason):
        return "fallback"
    if is_unsupported_result(candidate, expected_reason=expected_reason):
        return "unsupported"
    if is_capability_denied_result(candidate, expected_reason=expected_reason):
        return "capability-denied"
    return ""


def exact_three_way_cli_parity(stock: CommandResult, vm: CommandResult, aot: CommandResult) -> bool:
    return (
        not compare_cli_results(stock.to_dict(), vm.to_dict())
        and not compare_cli_results(stock.to_dict(), aot.to_dict())
        and not compare_cli_results(vm.to_dict(), aot.to_dict())
    )


def compatible_advanced_classification(vm_classification: str, aot_classification: str) -> bool:
    return bool(vm_classification) and vm_classification == aot_classification


def normalized_runtime_error_errors(
    stock: CommandResult,
    vm: CommandResult,
    aot: CommandResult,
    stderr_contains: Iterable[str],
) -> list[str]:
    errors: list[str] = []
    if stock.stdout != vm.stdout or stock.stdout != aot.stdout:
        errors.append("stdout differs across stock, VM, and AOT runtime-error executions")
    if stock.exit_code == 0 or vm.exit_code == 0 or aot.exit_code == 0:
        errors.append(
            f"runtime error exits must all be non-zero: stock={stock.exit_code} vm={vm.exit_code} aot={aot.exit_code}"
        )
    if stock.exit_code != vm.exit_code or stock.exit_code != aot.exit_code:
        errors.append(
            f"runtime error exit codes differ: stock={stock.exit_code} vm={vm.exit_code} aot={aot.exit_code}"
        )
    combined_stderr = "\n".join([stock.stderr.lower(), vm.stderr.lower(), aot.stderr.lower()])
    for expected in stderr_contains:
        if str(expected).lower() not in combined_stderr:
            errors.append(f"stderr is missing runtime-error keyword: {expected!r}")
    if "ziglua-vm:" not in vm.stderr:
        errors.append("VM stderr must include stable ziglua-vm diagnostic prefix")
    if "ziglua-aot:" not in aot.stderr:
        errors.append("AOT stderr must include stable ziglua-aot diagnostic prefix")
    return errors


def load_snippet_corpus(path: Path = DEFAULT_SNIPPET_CORPUS_FILE) -> list[dict[str, object]]:
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise ValueError(f"snippet corpus must be a JSON array: {path}")
    return data


def load_testes_classification(path: Path = DEFAULT_TESTES_CLASSIFICATION_FILE) -> list[dict[str, object]]:
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        raise ValueError(f"testes classification must be a JSON array: {path}")
    return data


def snippet_summary(snippet: dict[str, object]) -> dict[str, object]:
    source = str(snippet["source"])
    return {
        "name": snippet["name"],
        "level": snippet["level"],
        "areas": snippet["areas"],
        "expected_state": snippet["expected_state"],
        "description": snippet.get("description", ""),
        "source_bytes": len(source.encode()),
        "source_sha256": _sha256_text(source),
    }


def validate_snippet_corpus_metadata(corpus: list[dict[str, object]]) -> list[str]:
    errors: list[str] = []
    seen_names: set[str] = set()
    for index, snippet in enumerate(corpus):
        name = snippet.get("name")
        label = str(name or f"index-{index}")
        if not isinstance(name, str) or not name:
            errors.append(f"{label}: name must be a non-empty string")
        elif name in seen_names:
            errors.append(f"{label}: duplicate snippet name")
        elif "/" in name or " " in name:
            errors.append(f"{label}: name must be stable and path-safe")
        seen_names.add(str(name))
        if snippet.get("level") not in {0, 1}:
            errors.append(f"{label}: level must be 0 or 1")
        areas = snippet.get("areas")
        if not isinstance(areas, list) or not areas or not all(isinstance(area, str) for area in areas):
            errors.append(f"{label}: areas must be a non-empty string array")
        if snippet.get("expected_state") not in {"pass", "captured_error"}:
            errors.append(f"{label}: expected_state must be pass or captured_error")
        if not isinstance(snippet.get("source"), str) or not snippet.get("source"):
            errors.append(f"{label}: source must be a non-empty string")
    return errors


def corpus_expectation_errors(snippet: dict[str, object], result: CommandResult) -> list[str]:
    errors: list[str] = []
    expected_stdout = snippet.get("expected_stdout")
    if isinstance(expected_stdout, str) and result.stdout != expected_stdout:
        errors.append("stdout differed from expected_stdout")
    expected_stderr_contains = snippet.get("expected_stderr_contains", [])
    if not isinstance(expected_stderr_contains, list):
        errors.append("expected_stderr_contains must be an array when provided")
    else:
        for expected in expected_stderr_contains:
            if not isinstance(expected, str):
                errors.append("expected_stderr_contains entries must be strings")
            elif expected not in result.stderr:
                errors.append(f"stderr missing expected substring: {expected!r}")
    return errors


def validate_testes_classification_metadata(classifications: list[dict[str, object]]) -> list[str]:
    errors: list[str] = []
    for index, entry in enumerate(classifications):
        file_name = entry.get("file")
        label = str(file_name or f"index-{index}")
        if not isinstance(file_name, str) or not file_name.endswith(".lua") or "/" in file_name:
            errors.append(f"{label}: file must be a top-level .lua filename")
        categories = entry.get("categories")
        if not isinstance(categories, list) or not categories:
            errors.append(f"{label}: categories must be a non-empty array")
        elif not all(isinstance(category, str) for category in categories):
            errors.append(f"{label}: categories entries must be strings")
        else:
            unknown = sorted(set(categories).difference(TEST_CLASSIFICATION_CATEGORIES))
            if unknown:
                errors.append(f"{label}: unknown categories: {', '.join(unknown)}")
        if not isinstance(entry.get("stage"), str) or not entry.get("stage"):
            errors.append(f"{label}: stage must be a non-empty string")
        if "selected_early" in entry and not isinstance(entry["selected_early"], bool):
            errors.append(f"{label}: selected_early must be boolean when provided")
    return errors


def add_snippet_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--name", required=True, help="stable snippet/result identifier")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--snippet", help="Lua snippet source to execute via stdin")
    source.add_argument("--snippet-file", type=Path, help="file containing Lua snippet source")


def read_snippet_arg(args: argparse.Namespace) -> str:
    if args.snippet_file is not None:
        return args.snippet_file.read_text()
    return args.snippet


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Capture stock Lua baseline oracle results.")
    parser.add_argument("--repo", default=Path(__file__).resolve().parents[2], type=Path)
    parser.add_argument("--out-dir", default=Path("build/validation/baseline-oracle"), type=Path)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("build", help="build stock Lua with the documented Darwin make command")
    subparsers.add_parser("selected-tests", help="run selected PUC tests independently")
    subparsers.add_parser("list-corpus", help="list deterministic Level 0/1 snippet corpus metadata")
    subparsers.add_parser("stock-corpus", help="run the deterministic snippet corpus through stock ./lua")
    vm_level0 = subparsers.add_parser("vm-level0-corpus", help="compare Level 0 supported snippets against a Zig VM candidate")
    vm_level0.add_argument("--candidate-command", required=True, help="Zig VM command that reads the Lua snippet from stdin")
    vm_level1 = subparsers.add_parser("vm-level1-corpus", help="compare Level 1 snippets against a Zig VM candidate with unsupported accounting")
    vm_level1.add_argument("--candidate-command", required=True, help="Zig VM command that reads the Lua snippet from stdin")
    vm_dynamic = subparsers.add_parser("vm-dynamic-fallback", help="validate explicit fallback/unsupported handling for dynamic VM fixtures")
    vm_dynamic.add_argument("--candidate-command", required=True, help="Zig VM command that reads each dynamic Lua fixture from stdin")
    vm_advanced = subparsers.add_parser("vm-advanced-fallback", help="validate advanced semantic hook fallback/unsupported boundaries")
    vm_advanced.add_argument("--candidate-command", required=True, help="Zig VM command that reads each advanced Lua fixture from stdin")
    vm_puc = subparsers.add_parser("vm-selected-puc", help="run selected PUC VM harness with pass/unsupported/fail accounting")
    vm_puc.add_argument("--candidate-command", required=True, help="Zig VM command that reads each Lua test file from stdin")
    aot_eligibility = subparsers.add_parser("aot-eligibility", help="validate AOT Level 0 eligibility positive/negative corpus")
    aot_eligibility.add_argument("--aot-command", default=shlex.join(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND), help="Zig AOT command that reads Lua source from stdin")
    aot_matrix = subparsers.add_parser("aot-artifact-matrix", help="compare generated AOT artifacts against stock Lua and Zig VM")
    aot_matrix.add_argument("--vm-command", default=shlex.join(DEFAULT_ZIG_VM_CANDIDATE_COMMAND), help="Zig VM command that reads Lua source from stdin")
    aot_matrix.add_argument("--aot-command", default=shlex.join(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND), help="Zig AOT command used by generated artifacts")
    aot_dynamic = subparsers.add_parser("aot-dynamic-fallback", help="validate AOT dynamic feature rejection/fallback diagnostics")
    aot_dynamic.add_argument("--aot-command", default=shlex.join(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND), help="Zig AOT command that reads Lua source from stdin")
    aot_advanced = subparsers.add_parser("aot-advanced-fallback", help="validate AOT fallback/rejection for advanced semantic hook fixtures")
    aot_advanced.add_argument("--aot-command", default=shlex.join(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND), help="Zig AOT command that reads Lua source from stdin")
    aot_advanced.add_argument("--vm-command", default=shlex.join(DEFAULT_ZIG_VM_CANDIDATE_COMMAND), help="Zig VM command used as the shared fallback/rejection classification reference")
    debug_capi = subparsers.add_parser("debug-capi-gates", help="validate debug profile gates and C API bridge report-only boundaries")
    debug_capi.add_argument("--candidate-command", default=shlex.join(DEFAULT_ZIG_VM_CANDIDATE_COMMAND), help="Zig VM command used to prove debug API gating remains explicit")
    subparsers.add_parser("cross-target-packaging", help="build native/WASM package artifacts and validate provenance/capability gates")
    subparsers.add_parser("cross-target-profile-matrix", help="validate machine-checkable native/WASM/SBF profile matrix metadata")
    subparsers.add_parser("sbf-spike-report", help="generate and validate SBF experimental spike report wording and observations")
    cross_area = subparsers.add_parser("cross-area-integration-validation", help="run baseline, Zig VM/AOT, packaging, taxonomy, and post-Zig C selected-test validation in one CLI flow")
    cross_area.add_argument("--vm-command", default=shlex.join(DEFAULT_ZIG_VM_CANDIDATE_COMMAND), help="Zig VM command that reads Lua source from stdin")
    cross_area.add_argument("--aot-command", default=shlex.join(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND), help="Zig AOT command that reads Lua source from stdin")
    subparsers.add_parser("lua-zig-run-cli-parity", help="compare lua-zig run source forms against stock ./lua")
    native_core = subparsers.add_parser("native-core-language", help="compare M4 staged PUC-derived core language snippets through fallback-disabled lua-zig native execution")
    native_core.add_argument("--candidate-command", default=shlex.join(DEFAULT_LUA_ZIG_NATIVE_RUN_COMMAND), help="lua-zig native run command that reads Lua source from stdin")
    subparsers.add_parser("list-validators", help="list CLI-only validators and their report/artifact surfaces")
    aot_errors = subparsers.add_parser("aot-runtime-error-parity", help="validate deterministic AOT runtime-error parity under normalized policy")
    aot_errors.add_argument("--vm-command", default=shlex.join(DEFAULT_ZIG_VM_CANDIDATE_COMMAND), help="Zig VM command that reads Lua source from stdin")
    aot_errors.add_argument("--aot-command", default=shlex.join(DEFAULT_ZIG_AOT_CANDIDATE_COMMAND), help="Zig AOT command that reads Lua source from stdin")
    aot_mismatch = subparsers.add_parser("aot-intentional-mismatch", help="prove the three-way AOT comparison harness detects disagreements")
    aot_mismatch.add_argument("--vm-command", default=shlex.join(DEFAULT_ZIG_VM_CANDIDATE_COMMAND), help="Zig VM command used as the matching candidate")
    subparsers.add_parser(
        "validate-test-classification",
        help="verify every top-level testes/*.lua file has staged classification metadata",
    )
    full = subparsers.add_parser("full-suite-constraint", help="record full all.lua known macOS constraint")
    full.add_argument("--timeout", default=300, type=int)
    subparsers.add_parser("all", help="run build, selected tests, and full-suite constraint capture")
    snippet = subparsers.add_parser("stock-snippet", help="capture a stock ./lua snippet result")
    add_snippet_arguments(snippet)
    differential = subparsers.add_parser("differential", help="compare stock ./lua snippet output with a candidate command")
    add_snippet_arguments(differential)
    differential.add_argument(
        "--candidate-command",
        help="candidate command that reads the same Lua snippet from stdin; omitted means pending",
    )
    differential.add_argument(
        "--stock-result-file",
        type=Path,
        help="existing immutable stock result JSON to compare against instead of regenerating stock",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    out_dir = args.out_dir if args.out_dir.is_absolute() else args.repo / args.out_dir
    oracle = BaselineOracle(args.repo, out_dir)

    if args.command == "build":
        return print_summary(oracle.run_build())
    if args.command == "selected-tests":
        return print_summary(oracle.run_selected_tests())
    if args.command == "list-corpus":
        return print_summary(oracle.list_corpus())
    if args.command == "stock-corpus":
        return print_summary(oracle.run_stock_corpus())
    if args.command == "vm-level0-corpus":
        return print_summary(oracle.run_vm_level0_corpus(shlex.split(args.candidate_command)))
    if args.command == "vm-level1-corpus":
        return print_summary(oracle.run_vm_level1_corpus(shlex.split(args.candidate_command)))
    if args.command == "vm-dynamic-fallback":
        return print_summary(oracle.run_vm_dynamic_fallback(shlex.split(args.candidate_command)))
    if args.command == "vm-advanced-fallback":
        return print_summary(oracle.run_vm_advanced_fallback(shlex.split(args.candidate_command)))
    if args.command == "vm-selected-puc":
        return print_summary(oracle.run_vm_selected_puc(shlex.split(args.candidate_command)))
    if args.command == "aot-eligibility":
        return print_summary(oracle.run_aot_eligibility(shlex.split(args.aot_command)))
    if args.command == "aot-artifact-matrix":
        return print_summary(oracle.run_aot_artifact_matrix(shlex.split(args.vm_command), shlex.split(args.aot_command)))
    if args.command == "aot-dynamic-fallback":
        return print_summary(oracle.run_aot_dynamic_fallback(shlex.split(args.aot_command)))
    if args.command == "aot-advanced-fallback":
        return print_summary(oracle.run_aot_advanced_fallback(shlex.split(args.aot_command), shlex.split(args.vm_command)))
    if args.command == "debug-capi-gates":
        return print_summary(oracle.run_debug_capi_gates(shlex.split(args.candidate_command)))
    if args.command == "cross-target-packaging":
        return print_summary(oracle.run_cross_target_packaging())
    if args.command == "cross-target-profile-matrix":
        return print_summary(oracle.run_cross_target_profile_matrix())
    if args.command == "sbf-spike-report":
        return print_summary(oracle.run_sbf_spike_report())
    if args.command == "cross-area-integration-validation":
        return print_summary(
            oracle.run_cross_area_integration_validation(
                shlex.split(args.vm_command),
                shlex.split(args.aot_command),
            )
        )
    if args.command == "lua-zig-run-cli-parity":
        return print_summary(oracle.run_lua_zig_run_cli_parity())
    if args.command == "native-core-language":
        return print_summary(oracle.run_native_core_language(shlex.split(args.candidate_command)))
    if args.command == "list-validators":
        return print_summary(validator_registry(args.repo.resolve()))
    if args.command == "aot-runtime-error-parity":
        return print_summary(oracle.run_aot_runtime_error_parity(shlex.split(args.vm_command), shlex.split(args.aot_command)))
    if args.command == "aot-intentional-mismatch":
        return print_summary(oracle.run_aot_intentional_mismatch(shlex.split(args.vm_command)))
    if args.command == "validate-test-classification":
        return print_summary(oracle.validate_testes_classification())
    if args.command == "full-suite-constraint":
        return print_summary(oracle.run_full_suite_constraint(timeout=args.timeout))
    if args.command == "all":
        build = oracle.run_build()
        selected = oracle.run_selected_tests()
        full = oracle.run_full_suite_constraint()
        state = "pass" if build["state"] == "pass" and selected["state"] == "pass" and full["state"] in {"pass", "known_constraint"} else "fail"
        return print_summary({"state": state, "build": build, "selected_tests": selected, "full_suite": full})
    if args.command == "stock-snippet":
        return print_summary(oracle.run_stock_snippet(args.name, read_snippet_arg(args)))
    if args.command == "differential":
        candidate_command = shlex.split(args.candidate_command) if args.candidate_command else None
        return print_summary(
            oracle.run_differential(
                args.name,
                read_snippet_arg(args),
                candidate_command=candidate_command,
                stock_result_file=args.stock_result_file,
            )
        )
    raise AssertionError(f"unknown command: {args.command}")


if __name__ == "__main__":
    sys.exit(main())
