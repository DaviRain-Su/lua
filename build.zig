const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = "0.16.0";

const Profile = enum {
    native_full,
    wasm_constrained,
    sbf_experimental,
};

const ProfileDefaults = struct {
    allocator: []const u8,
    stdlib: []const u8,
    debug: []const u8,
    gc: []const u8,
    engine: []const u8,
    os: []const u8,
    filesystem: []const u8,
    process: []const u8,
    dynamic_loading: []const u8,
    artifact_kind: []const u8,
    sbf_experimental: bool,
    sbf_status: []const u8,
    sbf_notes: []const u8,
    sbf_scope: []const u8,
    sbf_toolchain_observation: []const u8,
    sbf_binary_size_note: []const u8,
    sbf_memory_note: []const u8,
    sbf_compute_note: []const u8,
};

const FeatureConfig = struct {
    allocator: []const u8,
    stdlib: []const u8,
    debug: []const u8,
    gc: []const u8,
    engine: []const u8,
    os: []const u8,
    filesystem: []const u8,
    process: []const u8,
    dynamic_loading: []const u8,
};

pub fn build(b: *std.Build) void {
    requireZigVersion();

    const profile_text = b.option([]const u8, "profile", "Platform profile: native-full, wasm-constrained, or sbf-experimental") orelse "native-full";
    const profile = parseProfile(profile_text) orelse fatal(
        "invalid profile '{s}'; accepted profiles: native-full, wasm-constrained, sbf-experimental",
        .{profile_text},
    );

    const target_text = b.option([]const u8, "target", "Target triple for the selected profile") orelse defaultTargetText(profile);
    const query = std.Build.parseTargetQuery(.{ .arch_os_abi = target_text }) catch fatal(
        "invalid target '{s}' for profile '{s}'",
        .{ target_text, profileName(profile) },
    );
    const target = b.resolveTargetQuery(query);

    validateProfileTarget(profile, target);

    const optimize = b.standardOptimizeOption(.{});
    const defaults = profileDefaults(profile);
    const config = resolveFeatureConfig(b, profile, defaults);
    const metadata = metadataJson(b, profile, target, target_text, optimize, defaults, config);
    const write_files = b.addWriteFiles();
    const metadata_path = write_files.add(
        b.fmt("profiles/{s}.json", .{profileName(profile)}),
        metadata,
    );
    const install_metadata = b.addInstallFile(
        metadata_path,
        b.fmt("share/ziglua/profiles/{s}.json", .{profileName(profile)}),
    );
    b.getInstallStep().dependOn(&install_metadata.step);

    switch (profile) {
        .native_full, .wasm_constrained => {
            const root_source = if (profile == .wasm_constrained)
                "src/ziglua/wasm_profile_stub.zig"
            else
                "src/ziglua/profile_stub.zig";
            const module = b.createModule(.{
                .root_source_file = b.path(root_source),
                .target = target,
                .optimize = optimize,
            });
            const exe = b.addExecutable(.{
                .name = b.fmt("ziglua-{s}", .{profileName(profile)}),
                .root_module = module,
            });
            if (profile == .wasm_constrained and target.result.os.tag == .freestanding) {
                exe.entry = .disabled;
                exe.rdynamic = true;
            }
            b.installArtifact(exe);

            if (profile == .native_full) {
                const vm_module = b.createModule(.{
                    .root_source_file = b.path("src/ziglua/vm_runner.zig"),
                    .target = target,
                    .optimize = optimize,
                });
                const vm_exe = b.addExecutable(.{
                    .name = "ziglua-vm",
                    .root_module = vm_module,
                });
                b.installArtifact(vm_exe);

                const cli_module = b.createModule(.{
                    .root_source_file = b.path("src/ziglua/cli_shell.zig"),
                    .target = target,
                    .optimize = optimize,
                });
                const cli_exe = b.addExecutable(.{
                    .name = "lua-zig",
                    .root_module = cli_module,
                });
                b.installArtifact(cli_exe);

                const aot_module = b.createModule(.{
                    .root_source_file = b.path("src/ziglua/aot_runner.zig"),
                    .target = target,
                    .optimize = optimize,
                });
                const aot_exe = b.addExecutable(.{
                    .name = "ziglua-aot",
                    .root_module = aot_module,
                });
                b.installArtifact(aot_exe);

                const tests = b.addTest(.{
                    .root_module = b.createModule(.{
                        .root_source_file = b.path("src/ziglua/runtime_tests.zig"),
                        .target = target,
                        .optimize = optimize,
                    }),
                });
                const run_tests = b.addRunArtifact(tests);
                const test_step = b.step("test", "Run Zig skeleton tests");
                test_step.dependOn(&run_tests.step);
                test_step.dependOn(&cli_exe.step);
                test_step.dependOn(&vm_exe.step);
                test_step.dependOn(&aot_exe.step);
            } else {
                const test_step = b.step("test", "Validate constrained profile build/test boundary");
                test_step.dependOn(&install_metadata.step);
                test_step.dependOn(&exe.step);
            }
        },
        .sbf_experimental => {
            const sbf_step = b.step("sbf-spike", "Generate SBF experimental spike metadata only");
            sbf_step.dependOn(&install_metadata.step);
        },
    }
}

fn requireZigVersion() void {
    if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
        fatal("Zig {s} is required; found Zig {s}", .{ required_zig_version, builtin.zig_version_string });
    }
}

fn parseProfile(text: []const u8) ?Profile {
    if (std.mem.eql(u8, text, "native-full")) return .native_full;
    if (std.mem.eql(u8, text, "wasm-constrained")) return .wasm_constrained;
    if (std.mem.eql(u8, text, "sbf-experimental")) return .sbf_experimental;
    return null;
}

fn profileName(profile: Profile) []const u8 {
    return switch (profile) {
        .native_full => "native-full",
        .wasm_constrained => "wasm-constrained",
        .sbf_experimental => "sbf-experimental",
    };
}

fn defaultTargetText(profile: Profile) []const u8 {
    return switch (profile) {
        .native_full => "native",
        .wasm_constrained => "wasm32-freestanding",
        .sbf_experimental => "bpfel-freestanding",
    };
}

fn profileDefaults(profile: Profile) ProfileDefaults {
    return switch (profile) {
        .native_full => .{
            .allocator = "host",
            .stdlib = "full",
            .debug = "full",
            .gc = "lua-compatible",
            .engine = "vm-aot",
            .os = "enabled",
            .filesystem = "enabled",
            .process = "enabled",
            .dynamic_loading = "enabled",
            .artifact_kind = "native-executable",
            .sbf_experimental = false,
            .sbf_status = "not-applicable",
            .sbf_notes = "not an SBF profile",
            .sbf_scope = "not-applicable",
            .sbf_toolchain_observation = "not-applicable",
            .sbf_binary_size_note = "not-applicable",
            .sbf_memory_note = "not-applicable",
            .sbf_compute_note = "not-applicable",
        },
        .wasm_constrained => .{
            .allocator = "bounded",
            .stdlib = "constrained",
            .debug = "subset",
            .gc = "bounded",
            .engine = "vm",
            .os = "disabled",
            .filesystem = "disabled",
            .process = "disabled",
            .dynamic_loading = "disabled",
            .artifact_kind = "wasm-artifact",
            .sbf_experimental = false,
            .sbf_status = "not-applicable",
            .sbf_notes = "not an SBF profile",
            .sbf_scope = "not-applicable",
            .sbf_toolchain_observation = "not-applicable",
            .sbf_binary_size_note = "not-applicable",
            .sbf_memory_note = "not-applicable",
            .sbf_compute_note = "not-applicable",
        },
        .sbf_experimental => .{
            .allocator = "bounded",
            .stdlib = "minimal",
            .debug = "disabled",
            .gc = "spike-only",
            .engine = "vm-subset-spike",
            .os = "disabled",
            .filesystem = "disabled",
            .process = "disabled",
            .dynamic_loading = "disabled",
            .artifact_kind = "metadata-only",
            .sbf_experimental = true,
            .sbf_status = "experimental-spike-only",
            .sbf_notes = "experimental spike only; metadata-only feasibility report; no deployable runtime artifact emitted",
            .sbf_scope = "metadata-only experimental spike report; constrained subset analysis only",
            .sbf_toolchain_observation = "Zig 0.16.0 exposes bpfel-freestanding target metadata; Solana SBF deployment proof is not attempted",
            .sbf_binary_size_note = "no deployable SBF artifact emitted; binary size measurement unavailable until proof build",
            .sbf_memory_note = "bounded memory allocator profile records heap and stack risk; no host filesystem/process/dynamic loader capability",
            .sbf_compute_note = "compute budget risk is report-only until a measured constrained proof exists",
        },
    };
}

fn validateProfileTarget(profile: Profile, target: std.Build.ResolvedTarget) void {
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;
    switch (profile) {
        .native_full => {
            if (!((arch == .aarch64 or arch == .x86_64) and os != .freestanding and os != .wasi)) {
                fatal(
                    "invalid profile/target combination: native-full requires aarch64 or x86_64 native OS targets; got {s}-{s}",
                    .{ @tagName(arch), @tagName(os) },
                );
            }
        },
        .wasm_constrained => {
            if (!(arch == .wasm32 and (os == .freestanding or os == .wasi))) {
                fatal(
                    "invalid profile/target combination: wasm-constrained requires wasm32-freestanding or wasm32-wasi; got {s}-{s}",
                    .{ @tagName(arch), @tagName(os) },
                );
            }
        },
        .sbf_experimental => {
            if (!(arch == .bpfel and os == .freestanding)) {
                fatal(
                    "invalid profile/target combination: sbf-experimental requires bpfel-freestanding metadata/spike target; got {s}-{s}",
                    .{ @tagName(arch), @tagName(os) },
                );
            }
        },
    }
}

fn resolveFeatureConfig(b: *std.Build, profile: Profile, defaults: ProfileDefaults) FeatureConfig {
    const allocator_text = b.option([]const u8, "allocator", "Allocator mode: host, arena, bounded, or failing") orelse defaults.allocator;
    validateAllocator(profile, allocator_text);

    const stdlib_text = b.option([]const u8, "stdlib", "Standard library capability set: full, constrained, or minimal") orelse defaults.stdlib;
    validateStdlib(profile, stdlib_text);

    const debug_text = b.option([]const u8, "debug", "Debug support: true, false, full, subset, or disabled") orelse defaults.debug;
    const debug = normalizeDebug(profile, debug_text);

    const gc_text = b.option([]const u8, "gc", "GC mode: lua-compatible, bounded, none, or spike-only") orelse defaults.gc;
    validateGc(profile, gc_text);

    const engine_text = b.option([]const u8, "engine", "Execution engine: vm, aot, vm-aot, or vm-subset-spike") orelse defaults.engine;
    validateEngine(profile, engine_text);

    const os_text = b.option([]const u8, "os", "OS capability: enabled or disabled") orelse defaults.os;
    validateCapability(profile, "os", os_text);

    const filesystem_text = b.option([]const u8, "filesystem", "Filesystem capability: enabled or disabled") orelse defaults.filesystem;
    validateCapability(profile, "filesystem", filesystem_text);

    const process_text = b.option([]const u8, "process", "Process capability: enabled or disabled") orelse defaults.process;
    validateCapability(profile, "process", process_text);

    const dynamic_loading_text = b.option([]const u8, "dynamic-loading", "Dynamic loading capability: enabled or disabled") orelse defaults.dynamic_loading;
    validateCapability(profile, "dynamic-loading", dynamic_loading_text);

    return .{
        .allocator = allocator_text,
        .stdlib = stdlib_text,
        .debug = debug,
        .gc = gc_text,
        .engine = engine_text,
        .os = os_text,
        .filesystem = filesystem_text,
        .process = process_text,
        .dynamic_loading = dynamic_loading_text,
    };
}

fn validateAllocator(profile: Profile, text: []const u8) void {
    if (!(eql(text, "host") or eql(text, "arena") or eql(text, "bounded") or eql(text, "failing"))) {
        fatal("invalid allocator '{s}'; accepted values: host, arena, bounded, failing", .{text});
    }
    switch (profile) {
        .native_full => {},
        .wasm_constrained => {
            if (eql(text, "host") or eql(text, "arena")) {
                fatal("allocator '{s}' is not supported for profile wasm-constrained; accepted values: bounded, failing", .{text});
            }
        },
        .sbf_experimental => {
            if (!(eql(text, "bounded") or eql(text, "failing"))) {
                fatal("allocator '{s}' is not supported for profile sbf-experimental; accepted values: bounded, failing", .{text});
            }
        },
    }
}

fn validateStdlib(profile: Profile, text: []const u8) void {
    if (!(eql(text, "full") or eql(text, "constrained") or eql(text, "minimal"))) {
        fatal("invalid stdlib '{s}'; accepted values: full, constrained, minimal", .{text});
    }
    switch (profile) {
        .native_full => {},
        .wasm_constrained => {
            if (eql(text, "full")) {
                fatal("stdlib 'full' is not supported for profile wasm-constrained; accepted values: constrained, minimal", .{});
            }
        },
        .sbf_experimental => {
            if (!eql(text, "minimal")) {
                fatal("stdlib '{s}' is not supported for profile sbf-experimental; accepted value: minimal", .{text});
            }
        },
    }
}

fn normalizeDebug(profile: Profile, text: []const u8) []const u8 {
    if (eql(text, "true")) {
        return switch (profile) {
            .native_full => "full",
            .wasm_constrained => "subset",
            .sbf_experimental => fatal(
                "debug 'true' is not supported for profile sbf-experimental; accepted values: false, disabled",
                .{},
            ),
        };
    }
    if (eql(text, "false")) return "disabled";
    if (!(eql(text, "full") or eql(text, "subset") or eql(text, "disabled"))) {
        fatal("invalid debug '{s}'; accepted values: true, false, full, subset, disabled", .{text});
    }
    switch (profile) {
        .native_full => {},
        .wasm_constrained => {
            if (eql(text, "full")) {
                fatal("debug 'full' is not supported for profile wasm-constrained; accepted values: true, false, subset, disabled", .{});
            }
        },
        .sbf_experimental => {
            if (!eql(text, "disabled")) {
                fatal("debug '{s}' is not supported for profile sbf-experimental; accepted values: false, disabled", .{text});
            }
        },
    }
    return text;
}

fn validateGc(profile: Profile, text: []const u8) void {
    if (!(eql(text, "lua-compatible") or eql(text, "bounded") or eql(text, "none") or eql(text, "spike-only"))) {
        fatal("invalid gc '{s}'; accepted values: lua-compatible, bounded, none, spike-only", .{text});
    }
    switch (profile) {
        .native_full => {
            if (eql(text, "spike-only")) {
                fatal("gc 'spike-only' is not supported for profile native-full; accepted values: lua-compatible, bounded, none", .{});
            }
        },
        .wasm_constrained => {
            if (!(eql(text, "bounded") or eql(text, "none"))) {
                fatal("gc '{s}' is not supported for profile wasm-constrained; accepted values: bounded, none", .{text});
            }
        },
        .sbf_experimental => {
            if (!(eql(text, "spike-only") or eql(text, "none"))) {
                fatal("gc '{s}' is not supported for profile sbf-experimental; accepted values: spike-only, none", .{text});
            }
        },
    }
}

fn validateEngine(profile: Profile, text: []const u8) void {
    if (!(eql(text, "vm") or eql(text, "aot") or eql(text, "vm-aot") or eql(text, "vm-subset-spike"))) {
        fatal("invalid engine '{s}'; accepted values: vm, aot, vm-aot, vm-subset-spike", .{text});
    }
    switch (profile) {
        .native_full => {
            if (eql(text, "vm-subset-spike")) {
                fatal("engine 'vm-subset-spike' is not supported for profile native-full; accepted values: vm, aot, vm-aot", .{});
            }
        },
        .wasm_constrained => {
            if (eql(text, "vm-subset-spike")) {
                fatal("engine 'vm-subset-spike' is not supported for profile wasm-constrained; accepted values: vm, aot, vm-aot", .{});
            }
        },
        .sbf_experimental => {
            if (!(eql(text, "vm") or eql(text, "vm-subset-spike"))) {
                fatal("engine '{s}' is not supported for profile sbf-experimental; accepted values: vm, vm-subset-spike", .{text});
            }
        },
    }
}

fn validateCapability(profile: Profile, name: []const u8, text: []const u8) void {
    if (!(eql(text, "enabled") or eql(text, "disabled"))) {
        fatal("invalid {s} '{s}'; accepted values: enabled, disabled", .{ name, text });
    }
    switch (profile) {
        .native_full => {},
        .wasm_constrained, .sbf_experimental => {
            if (eql(text, "enabled")) {
                fatal(
                    "capability {s} is unsupported for profile {s}; constrained profiles require {s}=disabled",
                    .{ name, profileName(profile), name },
                );
            }
        },
    }
}

fn metadataJson(
    b: *std.Build,
    profile: Profile,
    target: std.Build.ResolvedTarget,
    target_text: []const u8,
    optimize: std.builtin.OptimizeMode,
    defaults: ProfileDefaults,
    config: FeatureConfig,
) []const u8 {
    return std.fmt.allocPrint(
        b.allocator,
        \\{{
        \\  "allocator": "{s}",
        \\  "artifact_kind": "{s}",
        \\  "capabilities": {{
        \\    "dynamic_loading": "{s}",
        \\    "filesystem": "{s}",
        \\    "os": "{s}",
        \\    "process": "{s}"
        \\  }},
        \\  "debug": "{s}",
        \\  "dynamic_loading": "{s}",
        \\  "dynamic_semantics_fallback": "vm-required",
        \\  "dynamic_semantics_fallback_reasons": [
        \\    "load",
        \\    "debug",
        \\    "metatable-dispatch",
        \\    "raw-ops",
        \\    "protected-error",
        \\    "coroutine-model",
        \\    "gc-weak-finalization",
        \\    "table-iteration",
        \\    "cleanup-finalization",
        \\    "binary-dynamic-gates",
        \\    "cross-boundary-advanced",
        \\    "dynamic-env",
        \\    "binary-chunks"
        \\  ],
        \\  "engine": "{s}",
        \\  "gc": "{s}",
        \\  "optimize": "{s}",
        \\  "profile": "{s}",
        \\  "sbf_binary_size_note": "{s}",
        \\  "sbf_compute_note": "{s}",
        \\  "sbf_experimental": {},
        \\  "sbf_memory_note": "{s}",
        \\  "sbf_notes": "{s}",
        \\  "sbf_scope": "{s}",
        \\  "sbf_status": "{s}",
        \\  "sbf_toolchain_observation": "{s}",
        \\  "stdlib": "{s}",
        \\  "target": "{s}",
        \\  "target_abi": "{s}",
        \\  "target_arch": "{s}",
        \\  "target_os": "{s}",
        \\  "zig_version": "{s}"
        \\}}
        \\
    ,
        .{
            config.allocator,
            defaults.artifact_kind,
            config.dynamic_loading,
            config.filesystem,
            config.os,
            config.process,
            config.debug,
            config.dynamic_loading,
            config.engine,
            config.gc,
            @tagName(optimize),
            profileName(profile),
            defaults.sbf_binary_size_note,
            defaults.sbf_compute_note,
            defaults.sbf_experimental,
            defaults.sbf_memory_note,
            defaults.sbf_notes,
            defaults.sbf_scope,
            defaults.sbf_status,
            defaults.sbf_toolchain_observation,
            config.stdlib,
            target_text,
            @tagName(target.result.abi),
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            builtin.zig_version_string,
        },
    ) catch @panic("OOM");
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
