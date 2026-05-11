#!/usr/bin/env node
"use strict";

const fs = require("fs");

const expectedReturns = {
  ziglua_profile_marker: 0x005a1a55,
  ziglua_wasm_core_subset_smoke: 0x362c1305,
  ziglua_wasm_deny_filesystem: 0xd3111ed1,
  ziglua_wasm_deny_os: 0xd3111ed2,
  ziglua_wasm_deny_process: 0xd3111ed3,
  ziglua_wasm_deny_dynamic_loading: 0xd3111ed4,
};

function hex32(value) {
  return `0x${(value >>> 0).toString(16).padStart(8, "0")}`;
}

async function main() {
  const artifactPath = process.argv[2];
  if (!artifactPath) {
    throw new Error("usage: wasm_smoke_runner.js <artifact.wasm>");
  }

  const bytes = fs.readFileSync(artifactPath);
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const exports = {};
  let state = "pass";

  for (const [name, expected] of Object.entries(expectedReturns)) {
    const exported = instance.exports[name];
    if (typeof exported !== "function") {
      exports[name] = {
        state: "fail",
        expected: hex32(expected),
        actual: null,
        error: "missing function export",
      };
      state = "fail";
      continue;
    }

    const actual = exported() >>> 0;
    const entryState = actual === expected ? "pass" : "fail";
    if (entryState !== "pass") {
      state = "fail";
    }
    exports[name] = {
      state: entryState,
      expected: hex32(expected),
      actual: hex32(actual),
    };
  }

  const payload = {
    state,
    runtime: "node-webassembly",
    artifact_path: artifactPath,
    exports,
  };
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  process.exitCode = state === "pass" ? 0 : 1;
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
