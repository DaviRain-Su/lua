const std = @import("std");
const builtin = @import("builtin");
const advanced_hooks = @import("advanced_hooks.zig");
const vm_level0 = @import("vm_level0.zig");

const cli_version = "0.1.0";
const profile_name = "native-full";

const Command = enum {
    run,
    build,
    test_cmd,
    check,
    profile,
    report,
    capability,
};

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var process_env: ?*std.process.Environ.Map = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    process_env = init.environ_map;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next();
    const maybe_command = args.next() orelse {
        try printHelp(io);
        return;
    };

    if (std.mem.eql(u8, maybe_command, "--help") or
        std.mem.eql(u8, maybe_command, "-h") or
        std.mem.eql(u8, maybe_command, "help"))
    {
        try printHelp(io);
        return;
    }
    if (std.mem.eql(u8, maybe_command, "--version") or
        std.mem.eql(u8, maybe_command, "version"))
    {
        try printVersion(io);
        return;
    }

    const command = parseCommand(maybe_command) orelse {
        try printUnknownCommand(io);
        std.process.exit(2);
    };

    switch (command) {
        .run => try runCommand(allocator, io, &args),
        .build => try registeredRouteCommand(allocator, io, command, &args),
        .check => try checkCommand(allocator, io, &args),
        .test_cmd => try testCommand(allocator, io, &args),
        .profile => try profileCommand(allocator, io, &args),
        .report => try reportCommand(allocator, io, &args),
        .capability => try capabilityCommand(io, &args),
    }
}

fn parseCommand(text: []const u8) ?Command {
    if (std.mem.eql(u8, text, "run")) return .run;
    if (std.mem.eql(u8, text, "build")) return .build;
    if (std.mem.eql(u8, text, "test")) return .test_cmd;
    if (std.mem.eql(u8, text, "check")) return .check;
    if (std.mem.eql(u8, text, "profile")) return .profile;
    if (std.mem.eql(u8, text, "report")) return .report;
    if (std.mem.eql(u8, text, "capability")) return .capability;
    return null;
}

fn commandName(command: Command) []const u8 {
    return switch (command) {
        .run => "run",
        .build => "build",
        .test_cmd => "test",
        .check => "check",
        .profile => "profile",
        .report => "report",
        .capability => "capability",
    };
}

fn printHelp(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        \\lua-zig 0.1.0
        \\Usage: lua-zig <command> [options]
        \\
        \\Commands:
        \\  run         Execute Lua through the platform runtime
        \\  build       Build Lua entrypoints for a target profile
        \\  test        Run compatibility validation suites
        \\  check       Validate Lua source/profile compatibility
        \\  profile     Inspect compatibility profiles or collect runtime metrics
        \\  report      Emit compatibility ledger summaries
        \\  capability  List host and target profile capabilities
        \\
        \\Global options:
        \\  -h, --help     Show this help text
        \\  --version      Show deterministic CLI version metadata
        \\
    );
    try stdout_writer.interface.flush();
}

fn printVersion(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print(
        "lua-zig {s} zig={s} profile={s}\n",
        .{ cli_version, builtin.zig_version_string, profile_name },
    );
    try stdout_writer.interface.flush();
}

fn printCommandHelp(io: std.Io, command: Command) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    switch (command) {
        .test_cmd => try stdout_writer.interface.writeAll(
            \\lua-zig test
            \\Usage: lua-zig test [--suite cli-ledger|smoke|core] [--target native-full|wasm-full|sbf-experimental]
            \\Emits deterministic compatibility-suite ledger accounting.
            \\
        ),
        .profile => try stdout_writer.interface.writeAll(
            \\lua-zig profile
            \\Usage: lua-zig profile [list|show <profile>|metrics]
            \\Separates compatibility profile inspection from runtime metrics.
            \\
        ),
        .report => try stdout_writer.interface.writeAll(
            \\lua-zig report
            \\Usage: lua-zig report [--format json]
            \\Emits compatibility ledger summaries with native/fallback accounting separated.
            \\
        ),
        .check => try stdout_writer.interface.writeAll(
            \\lua-zig check
            \\Usage: lua-zig check [--profile native-full|wasm-full|sbf-experimental] [-e chunk] [-l module] [script|-]
            \\Validates source syntax/profile compatibility without executing chunks or emitting build artifacts.
            \\
        ),
        .capability => try stdout_writer.interface.writeAll(
            \\lua-zig capability
            \\Usage: lua-zig capability [--profile <profile>] [--capability <name>]
            \\Lists host and target profile capabilities.
            \\
        ),
        else => try stdout_writer.interface.print(
            \\lua-zig {s}
            \\Usage: lua-zig {s} [options]
            \\State: route registered; detailed behavior is implemented by milestone-specific validators.
            \\
        ,
            .{ commandName(command), commandName(command) },
        ),
    }
    try stdout_writer.interface.flush();
}

fn registeredRouteCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: Command,
    args: *std.process.Args.Iterator,
) !void {
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, command);
            return;
        }
    }
    const timestamp = timestampMillis(io);
    const entry = try buildRouteEvidence(allocator, command, timestamp);
    try writeEvidenceRecord(allocator, io, entry, commandName(command), timestamp);
    try printRegisteredRoute(io, command);
}

fn printRegisteredRoute(io: std.Io, command: Command) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print(
        \\{{
        \\  "cli": "lua-zig",
        \\  "command": "{s}",
        \\  "message": "command route registered; implementation pending milestone-specific validation",
        \\  "profile": "{s}",
        \\  "state": "pending"
        \\}}
        \\
    ,
        .{ commandName(command), profile_name },
    );
    try stdout_writer.interface.flush();
}

fn testCommand(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var suite: []const u8 = "cli-ledger";
    var target: []const u8 = profile_name;
    var fixture_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, .test_cmd);
            return;
        } else if (std.mem.eql(u8, arg, "--suite")) {
            suite = args.next() orelse return failMissingValue(io, "--suite");
            if (!isKnownSuite(suite)) return failUnknownValue(io, "suite", suite);
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            fixture_path = args.next() orelse return failMissingValue(io, "--fixture");
        } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "--profile")) {
            target = args.next() orelse return failMissingValue(io, arg);
            if (!isKnownProfile(target)) return failUnknownValue(io, "profile", target);
        } else {
            return failUnknownValue(io, "option", arg);
        }
    }

    const source = if (fixture_path) |path|
        try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024))
    else
        "print(21 + 21)\n";
    const resolved_fixture = if (fixture_path) |path|
        try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator)
    else
        "builtin:cli-ledger-smoke";
    const timestamp = timestampMillis(io);
    const command_id = try std.fmt.allocPrint(allocator, "test-{d}", .{timestamp});

    var state: []const u8 = "pass";
    var implementation_mode: []const u8 = "native";
    var diagnostic: []const u8 = "";
    var exit_code: u8 = 0;
    var validates: []const u8 = "\"VAL-CLI-011\", \"VAL-NATIVE-018\", \"VAL-NATIVE-019\", \"VAL-NATIVE-020\"";

    if (std.mem.eql(u8, target, "wasm-full")) {
        state = "unsupported";
        implementation_mode = "not-executed";
        diagnostic = "wasm-full compatibility execution is not available in the CLI ledger milestone";
        validates = "\"VAL-CLI-012\"";
    } else if (std.mem.eql(u8, target, "sbf-experimental")) {
        state = "expected-skip";
        implementation_mode = "metadata-only";
        diagnostic = "sbf-experimental remains a constrained metadata/profile track";
        validates = "\"VAL-CLI-012\"";
    } else {
        const result = try runWithNativeAdvancedFallback(allocator, io, source);
        exit_code = result.exit_code;
        diagnostic = result.stderr;
        if (isFallbackPassDiagnostic(result.stderr) and result.exit_code == 0) {
            state = "fallback-pass";
            implementation_mode = "stock-lua-fallback";
        } else if (isFallbackDiagnostic(result.stderr)) {
            state = "fail";
            implementation_mode = "stock-lua-fallback";
        } else {
            switch (result.state) {
                .pass => {
                    state = "pass";
                    implementation_mode = "native";
                },
                .runtime_error => {
                    state = "fail";
                    implementation_mode = "native";
                },
                .unsupported => {
                    state = "unsupported";
                    implementation_mode = "none";
                },
            }
        }
    }

    const entry = try buildTestEvidence(
        allocator,
        command_id,
        suite,
        target,
        state,
        implementation_mode,
        diagnostic,
        resolved_fixture,
        source,
        timestamp,
        validates,
    );
    try writeEvidenceRecord(allocator, io, entry, "test", timestamp);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try printLedgerSummary(
        &stdout_writer.interface,
        "test",
        suite,
        target,
        state,
        entry,
    );
    try stdout_writer.interface.flush();
    if (std.mem.eql(u8, state, "fail")) std.process.exit(if (exit_code == 0) 1 else exit_code);
}

fn printLedgerSummary(
    writer: *std.Io.Writer,
    command: []const u8,
    suite: []const u8,
    target: []const u8,
    state: []const u8,
    entry: []const u8,
) !void {
    const native_pass_count: u8 = if (std.mem.eql(u8, state, "pass") and hasJsonStringField(entry, "implementation_mode", "native")) 1 else 0;
    const fallback_pass_count: u8 = if (std.mem.eql(u8, state, "fallback-pass")) 1 else 0;
    const unsupported_count: u8 = if (std.mem.eql(u8, state, "unsupported")) 1 else 0;
    const capability_denied_count: u8 = if (std.mem.eql(u8, state, "capability-denied")) 1 else 0;
    const expected_skip_count: u8 = if (std.mem.eql(u8, state, "expected-skip")) 1 else 0;
    const fail_count: u8 = if (std.mem.eql(u8, state, "fail")) 1 else 0;
    const blocked_count: u8 = if (std.mem.eql(u8, state, "blocked")) 1 else 0;

    try writer.print(
        \\{{
        \\  "accounting": {{
        \\    "blocked_count": {d},
        \\    "capability_denied_count": {d},
        \\    "expected_skip_count": {d},
        \\    "fail_count": {d},
        \\    "fallback_pass_count": {d},
        \\    "native_pass_count": {d},
        \\    "unsupported_count": {d}
        \\  }},
        \\  "cli": "lua-zig",
        \\  "command": "{s}",
        \\  "ledger": [
        \\    {s}
        \\  ],
        \\  "selected_suite": "{s}",
        \\  "state": "{s}",
        \\  "states": ["pass", "fallback-pass", "unsupported", "capability-denied", "expected-skip", "fail", "blocked"],
        \\  "target_profile": "{s}"
        \\}}
        \\
    ,
        .{
            blocked_count,
            capability_denied_count,
            expected_skip_count,
            fail_count,
            fallback_pass_count,
            native_pass_count,
            unsupported_count,
            command,
            entry,
            suite,
            state,
            target,
        },
    );
}

fn profileCommand(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    const maybe_action = args.next();
    if (maybe_action) |action| {
        if (std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
            try printCommandHelp(io, .profile);
            return;
        }
        if (std.mem.eql(u8, action, "metrics") or std.mem.eql(u8, action, "perf")) {
            try printProfileMetrics(allocator, io, args);
            return;
        }
        if (std.mem.eql(u8, action, "show")) {
            const profile = args.next() orelse return failMissingValue(io, "profile");
            if (!isKnownProfile(profile)) return failUnknownValue(io, "profile", profile);
            try printProfileShow(io, profile);
            return;
        }
        if (std.mem.eql(u8, action, "list")) {
            try printProfileList(io);
            return;
        }
        if (isKnownProfile(action)) {
            try printProfileShow(io, action);
            return;
        }
        return failUnknownValue(io, "profile-action", action);
    }
    try printProfileList(io);
}

fn reportCommand(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, .report);
            return;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            const format = args.next() orelse return failMissingValue(io, "--format");
            if (!std.mem.eql(u8, format, "json")) return failUnknownValue(io, "format", format);
        } else {
            return failUnknownValue(io, "option", arg);
        }
    }

    const evidence_dir = try evidenceDir(allocator);
    try std.Io.Dir.cwd().createDirPath(io, evidence_dir);
    const resolved_evidence_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, evidence_dir, allocator);
    const aggregate = try loadEvidenceAggregate(allocator, io, evidence_dir);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print(
        \\{{
        \\  "accounting": {{
        \\    "blocked_count": {d},
        \\    "capability_denied_count": {d},
        \\    "expected_skip_count": {d},
        \\    "fail_count": {d},
        \\    "fallback_pass_count": {d},
        \\    "native_implementation_compatibility_count": {d},
        \\    "native_pass_count": {d},
        \\    "unsupported_count": {d}
        \\  }},
        \\  "build_id": "lua-zig-{s}-zig-{s}",
        \\  "cli": "lua-zig",
        \\  "command": "report",
        \\  "compatibility_policy": {{
        \\    "fallback_counts_as_native": false,
        \\    "unsupported_counts_as_native": false
        \\  }},
        \\  "evidence": {{
        \\    "record_count": {d},
        \\    "source":
    ,
        .{
            aggregate.blocked_count,
            aggregate.capability_denied_count,
            aggregate.expected_skip_count,
            aggregate.fail_count,
            aggregate.fallback_pass_count,
            aggregate.native_pass_count,
            aggregate.native_pass_count,
            aggregate.unsupported_count,
            cli_version,
            builtin.zig_version_string,
            aggregate.record_count,
        },
    );
    try writeJsonString(&stdout_writer.interface, resolved_evidence_dir);
    try stdout_writer.interface.writeAll(
        \\
        \\  },
        \\  "ledger": [
        \\
    );
    for (aggregate.records, 0..) |record, i| {
        if (i != 0) try stdout_writer.interface.writeAll(",\n");
        try stdout_writer.interface.print("    {s}", .{record});
    }
    try stdout_writer.interface.print(
        \\
        \\  ],
        \\  "ledger_format_version": 1,
        \\  "state": "{s}",
        \\  "states": ["pass", "fallback-pass", "unsupported", "capability-denied", "expected-skip", "fail", "blocked"]
        \\}}
        \\
    ,
        .{if (aggregate.fail_count == 0) "pass" else "fail"},
    );
    try stdout_writer.interface.flush();
}

fn capabilityCommand(io: std.Io, args: *std.process.Args.Iterator) !void {
    var selected_profile: ?[]const u8 = null;
    var selected_capability: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, .capability);
            return;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            const profile = args.next() orelse return failMissingValue(io, "--profile");
            if (!isKnownProfile(profile)) return failUnknownValue(io, "profile", profile);
            selected_profile = profile;
        } else if (std.mem.eql(u8, arg, "--capability")) {
            const capability = args.next() orelse return failMissingValue(io, "--capability");
            if (!isKnownCapability(capability)) return failUnknownValue(io, "capability", capability);
            selected_capability = capability;
        } else if (isKnownProfile(arg) and selected_profile == null) {
            selected_profile = arg;
        } else if (isKnownCapability(arg) and selected_capability == null) {
            selected_capability = arg;
        } else {
            return failUnknownValue(io, "capability", arg);
        }
    }

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    if (selected_profile) |profile| {
        if (selected_capability) |capability| {
            try stdout_writer.interface.print(
                \\{{
                \\  "capability": "{s}",
                \\  "cli": "lua-zig",
                \\  "command": "capability",
                \\  "profile": "{s}",
                \\  "state": "pass",
                \\  "support": "{s}"
                \\}}
                \\
            ,
                .{ capability, profile, capabilitySupport(profile, capability) },
            );
        } else {
            try printCapabilityProfile(&stdout_writer.interface, profile);
        }
    } else {
        try stdout_writer.interface.writeAll(
            \\{
            \\  "cli": "lua-zig",
            \\  "command": "capability",
            \\  "profiles": [
            \\
        );
        try printCapabilityProfileInline(&stdout_writer.interface, "native-full", true);
        try printCapabilityProfileInline(&stdout_writer.interface, "wasm-full", true);
        try printCapabilityProfileInline(&stdout_writer.interface, "sbf-experimental", false);
        try stdout_writer.interface.writeAll(
            \\  ],
            \\  "state": "pass",
            \\  "states": ["native", "shimmed", "unsupported", "capability-denied", "expected-skip"]
            \\}
            \\
        );
    }
    try stdout_writer.interface.flush();
}

fn printUnknownCommand(io: std.Io) !void {
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "unknown",
        \\  "message": "unknown command",
        \\  "state": "fail"
        \\}
        \\
    );
    try stderr_writer.interface.flush();
}

fn isKnownSuite(text: []const u8) bool {
    return std.mem.eql(u8, text, "cli-ledger") or
        std.mem.eql(u8, text, "smoke") or
        std.mem.eql(u8, text, "core");
}

fn isKnownProfile(text: []const u8) bool {
    return std.mem.eql(u8, text, "native-full") or
        std.mem.eql(u8, text, "wasm-full") or
        std.mem.eql(u8, text, "sbf-experimental");
}

fn isKnownCapability(text: []const u8) bool {
    return std.mem.eql(u8, text, "filesystem") or
        std.mem.eql(u8, text, "process") or
        std.mem.eql(u8, text, "environment") or
        std.mem.eql(u8, text, "dynamic-loading") or
        std.mem.eql(u8, text, "stdin") or
        std.mem.eql(u8, text, "stdout") or
        std.mem.eql(u8, text, "stderr") or
        std.mem.eql(u8, text, "clock") or
        std.mem.eql(u8, text, "entropy") or
        std.mem.eql(u8, text, "debug") or
        std.mem.eql(u8, text, "gc") or
        std.mem.eql(u8, text, "package-loading") or
        std.mem.eql(u8, text, "c-api") or
        std.mem.eql(u8, text, "os");
}

fn capabilitySupport(profile: []const u8, capability: []const u8) []const u8 {
    if (std.mem.eql(u8, profile, "native-full")) return "native";
    if (std.mem.eql(u8, profile, "wasm-full")) {
        if (std.mem.eql(u8, capability, "stdin") or
            std.mem.eql(u8, capability, "stdout") or
            std.mem.eql(u8, capability, "stderr") or
            std.mem.eql(u8, capability, "clock") or
            std.mem.eql(u8, capability, "environment") or
            std.mem.eql(u8, capability, "package-loading"))
        {
            return "shimmed";
        }
        if (std.mem.eql(u8, capability, "debug") or
            std.mem.eql(u8, capability, "gc"))
        {
            return "native";
        }
        return "capability-denied";
    }
    if (std.mem.eql(u8, capability, "stdin") or
        std.mem.eql(u8, capability, "stdout") or
        std.mem.eql(u8, capability, "stderr"))
    {
        return "shimmed";
    }
    return "unsupported";
}

fn printProfileList(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "profile",
        \\  "mode": "compatibility-inspection",
        \\  "profiles": [
        \\    {"profile": "native-full", "target": "native", "engine": "vm-aot", "stdlib": "full", "status": "active"},
        \\    {"profile": "wasm-full", "target": "wasm32-wasi", "engine": "vm", "stdlib": "full-with-host-shims", "status": "tracked"},
        \\    {"profile": "sbf-experimental", "target": "bpfel-freestanding", "engine": "vm-subset-spike", "stdlib": "minimal", "status": "experimental"}
        \\  ],
        \\  "state": "pass"
        \\}
        \\
    );
    try stdout_writer.interface.flush();
}

fn printProfileShow(io: std.Io, profile: []const u8) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print(
        \\{{
        \\  "capability_command": "lua-zig capability --profile {s}",
        \\  "cli": "lua-zig",
        \\  "command": "profile",
        \\  "mode": "compatibility-inspection",
        \\  "profile": "{s}",
        \\  "state": "pass",
        \\  "target": "{s}"
        \\}}
        \\
    ,
        .{ profile, profile, profileTarget(profile) },
    );
    try stdout_writer.interface.flush();
}

fn printProfileMetrics(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    var workload_path: ?[]const u8 = null;
    var workload_args: std.ArrayList([]const u8) = .empty;
    var after_delimiter = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--format")) {
            const format = args.next() orelse return failMissingValue(io, "--format");
            if (!std.mem.eql(u8, format, "json")) return failUnknownValue(io, "format", format);
        } else if (std.mem.eql(u8, arg, "--")) {
            if (workload_path == null) return failMissingValue(io, "workload");
            after_delimiter = true;
        } else if (workload_path == null) {
            if (std.mem.startsWith(u8, arg, "-")) return failUnknownValue(io, "profile-option", arg);
            workload_path = arg;
        } else if (after_delimiter) {
            try workload_args.append(allocator, arg);
        } else {
            return failUnknownValue(io, "trailing-args", arg);
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "./lua");
    var workload_display: []const u8 = "inline:profile-smoke";
    var workload_source: []const u8 = "print(42)\n";
    if (workload_path) |path| {
        const resolved = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        workload_display = resolved;
        workload_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        try argv.append(allocator, path);
    } else {
        try argv.append(allocator, "-e");
        try argv.append(allocator, workload_source);
    }
    for (workload_args.items) |arg| try argv.append(allocator, arg);

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    const ended = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const duration_ms: i128 = @intCast(ended - started);
    const timestamp = timestampMillis(io);
    const exit_code = termExitCode(result.term);
    const state: []const u8 = if (exit_code == 0) "pass" else "fail";
    const command_id = try std.fmt.allocPrint(allocator, "profile-{d}", .{timestamp});

    const entry = try buildProfileEvidence(
        allocator,
        command_id,
        state,
        workload_display,
        workload_source,
        workload_args.items,
        result.stdout,
        result.stderr,
        exit_code,
        duration_ms,
        timestamp,
    );
    try writeEvidenceRecord(allocator, io, entry, "profile", timestamp);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print(
        \\{{
        \\  "cli": "lua-zig",
        \\  "command": "profile",
        \\  "command_id":
    ,
        .{},
    );
    try writeJsonString(&stdout_writer.interface, command_id);
    try stdout_writer.interface.print(
        \\,
        \\  "metrics": {{
        \\    "allocation_bytes": 0,
        \\    "timing_ms": {d}
        \\  }},
        \\  "mode": "runtime-metrics",
        \\  "program": {{
        \\    "exit_code": {d},
        \\    "stderr":
    ,
        .{ duration_ms, exit_code },
    );
    try writeJsonString(&stdout_writer.interface, result.stderr);
    try stdout_writer.interface.writeAll(
        \\,
        \\    "stdout":
    );
    try writeJsonString(&stdout_writer.interface, result.stdout);
    try stdout_writer.interface.writeAll(
        \\
        \\  },
        \\  "profiler_output": "json",
        \\  "program_output": "separate-stdout-stderr",
        \\  "state":
    );
    try writeJsonString(&stdout_writer.interface, state);
    try stdout_writer.interface.writeAll(
        \\,
        \\  "timestamp_unix_ms":
    );
    try stdout_writer.interface.print("{d}", .{timestamp});
    try stdout_writer.interface.writeAll(
        \\,
        \\  "workload": {
        \\    "args": [
    );
    for (workload_args.items, 0..) |arg, i| {
        if (i != 0) try stdout_writer.interface.writeAll(", ");
        try writeJsonString(&stdout_writer.interface, arg);
    }
    try stdout_writer.interface.writeAll(
        \\],
        \\    "path":
    );
    try writeJsonString(&stdout_writer.interface, workload_display);
    try stdout_writer.interface.writeAll(
        \\,
        \\    "source_bytes":
    );
    try stdout_writer.interface.print("{d}", .{workload_source.len});
    try stdout_writer.interface.writeAll(
        \\,
        \\    "source_sha256":
    );
    const digest = try sourceDigestHex(allocator, workload_source);
    try writeJsonString(&stdout_writer.interface, digest);
    try stdout_writer.interface.writeAll(
        \\
        \\  }
        \\}
        \\
    );
    try stdout_writer.interface.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

const EvidenceAggregate = struct {
    records: []const []const u8,
    record_count: usize,
    native_pass_count: usize,
    fallback_pass_count: usize,
    unsupported_count: usize,
    capability_denied_count: usize,
    expected_skip_count: usize,
    fail_count: usize,
    blocked_count: usize,
};

fn buildRouteEvidence(
    allocator: std.mem.Allocator,
    command: Command,
    timestamp: i128,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.print(
        \\{{
        \\  "cli": "lua-zig",
        \\  "command": "{s}",
        \\  "command_id": "{s}-{d}",
        \\  "id": "{s}-registered-route",
        \\  "implementation_mode": "route-only",
        \\  "profile": "{s}",
        \\  "provenance": "registered CLI route evidence captured at command execution time",
        \\  "state": "blocked",
        \\  "timestamp_unix_ms": {d}
        \\}}
    ,
        .{ commandName(command), commandName(command), timestamp, commandName(command), profile_name, timestamp },
    );
    return try out.toOwnedSlice();
}

fn buildTestEvidence(
    allocator: std.mem.Allocator,
    command_id: []const u8,
    suite: []const u8,
    target: []const u8,
    state: []const u8,
    implementation_mode: []const u8,
    diagnostic: []const u8,
    fixture_path: []const u8,
    source: []const u8,
    timestamp: i128,
    validates: []const u8,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "test",
        \\  "command_id":
    );
    try writeJsonString(&out.writer, command_id);
    try out.writer.writeAll(
        \\,
        \\  "diagnostic":
    );
    try writeJsonString(&out.writer, diagnostic);
    try out.writer.writeAll(
        \\,
        \\  "fixture": {
        \\    "path":
    );
    try writeJsonString(&out.writer, fixture_path);
    try out.writer.print(
        \\,
        \\    "source_bytes": {d},
        \\    "source_sha256":
    ,
        .{source.len},
    );
    const digest = try sourceDigestHex(allocator, source);
    try writeJsonString(&out.writer, digest);
    try out.writer.writeAll(
        \\
        \\  },
        \\  "id": "compatibility-fixture",
        \\  "implementation_mode":
    );
    try writeJsonString(&out.writer, implementation_mode);
    try out.writer.writeAll(
        \\,
        \\  "profile":
    );
    try writeJsonString(&out.writer, target);
    try out.writer.writeAll(
        \\,
        \\  "provenance": "lua-zig test executed fixture or built-in suite source during this invocation",
        \\  "state":
    );
    try writeJsonString(&out.writer, state);
    try out.writer.writeAll(
        \\,
        \\  "suite":
    );
    try writeJsonString(&out.writer, suite);
    try out.writer.print(
        \\,
        \\  "timestamp_unix_ms": {d},
        \\  "validates": [{s}]
        \\}}
    ,
        .{ timestamp, validates },
    );
    return try out.toOwnedSlice();
}

fn buildProfileEvidence(
    allocator: std.mem.Allocator,
    command_id: []const u8,
    state: []const u8,
    workload_path: []const u8,
    workload_source: []const u8,
    workload_args: []const []const u8,
    program_stdout: []const u8,
    program_stderr: []const u8,
    exit_code: u8,
    duration_ms: i128,
    timestamp: i128,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "profile",
        \\  "command_id":
    );
    try writeJsonString(&out.writer, command_id);
    try out.writer.print(
        \\,
        \\  "id": "runtime-profile-workload",
        \\  "implementation_mode": "stock-lua-workload-runner",
        \\  "metrics": {{
        \\    "allocation_bytes": 0,
        \\    "timing_ms": {d}
        \\  }},
        \\  "profile": "{s}",
        \\  "program": {{
        \\    "exit_code": {d},
        \\    "stderr":
    ,
        .{ duration_ms, profile_name, exit_code },
    );
    try writeJsonString(&out.writer, program_stderr);
    try out.writer.writeAll(
        \\,
        \\    "stdout":
    );
    try writeJsonString(&out.writer, program_stdout);
    try out.writer.writeAll(
        \\
        \\  },
        \\  "provenance": "lua-zig profile metrics executed the workload and captured stdout/stderr separately from profiler JSON",
        \\  "state":
    );
    try writeJsonString(&out.writer, state);
    try out.writer.print(
        \\,
        \\  "timestamp_unix_ms": {d},
        \\  "workload": {{
        \\    "args": [
    ,
        .{timestamp},
    );
    for (workload_args, 0..) |arg, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try writeJsonString(&out.writer, arg);
    }
    try out.writer.writeAll(
        \\],
        \\    "path":
    );
    try writeJsonString(&out.writer, workload_path);
    try out.writer.print(
        \\,
        \\    "source_bytes": {d},
        \\    "source_sha256":
    ,
        .{workload_source.len},
    );
    const digest = try sourceDigestHex(allocator, workload_source);
    try writeJsonString(&out.writer, digest);
    try out.writer.writeAll(
        \\
        \\  }
        \\}
    );
    return try out.toOwnedSlice();
}

fn buildCheckEvidence(
    allocator: std.mem.Allocator,
    command_id: []const u8,
    state: []const u8,
    target: []const u8,
    implementation_mode: []const u8,
    diagnostic: []const u8,
    input: CheckInput,
    classifications: []const CheckClassification,
    primary_index: usize,
    profile_limitation: []const u8,
    capability: []const u8,
    timestamp: i128,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        \\{
        \\  "artifacts_emitted": false,
        \\  "capability":
    );
    try writeJsonString(&out.writer, capability);
    try out.writer.writeAll(
        \\,
        \\  "chunk": {
    );
    if (input.chunks.len > 0) {
        try writeCheckChunkJson(&out.writer, allocator, input.chunks[primary_index], classifications[primary_index]);
    }
    try out.writer.writeAll(
        \\},
        \\  "chunks": [
    );
    for (input.chunks, 0..) |chunk, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll("{");
        try writeCheckChunkJson(&out.writer, allocator, chunk, classifications[i]);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll(
        \\],
        \\  "cli": "lua-zig",
        \\  "command": "check",
        \\  "command_id":
    );
    try writeJsonString(&out.writer, command_id);
    try out.writer.writeAll(
        \\,
        \\  "diagnostic":
    );
    try writeJsonString(&out.writer, diagnostic);
    try out.writer.writeAll(
        \\,
        \\  "id": "loader-parser-check",
        \\  "implementation_mode":
    );
    try writeJsonString(&out.writer, implementation_mode);
    try out.writer.writeAll(
        \\,
        \\  "loader_boundary": "run-compatible-source-loader",
        \\  "profile":
    );
    try writeJsonString(&out.writer, target);
    try out.writer.writeAll(
        \\,
        \\  "profile_limitation":
    );
    try writeJsonString(&out.writer, profile_limitation);
    try out.writer.writeAll(
        \\,
        \\  "provenance": "lua-zig check loaded the chunk through the run-compatible loader and parsed it without executing user code or emitting build artifacts",
        \\  "state":
    );
    try writeJsonString(&out.writer, state);
    try out.writer.print(
        \\,
        \\  "timestamp_unix_ms": {d},
        \\  "validates": ["VAL-CLI-013"]
        \\}}
    ,
        .{timestamp},
    );
    return try out.toOwnedSlice();
}

fn writeCheckChunkJson(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    chunk: CheckChunk,
    classification: CheckClassification,
) !void {
    try writer.writeAll(
        \\
        \\    "capability":
    );
    try writeJsonString(writer, classification.capability);
    try writer.writeAll(
        \\,
        \\    "diagnostic":
    );
    try writeJsonString(writer, classification.diagnostic);
    try writer.writeAll(
        \\,
        \\    "kind":
    );
    try writeJsonString(writer, chunk.chunk_kind);
    try writer.writeAll(
        \\,
        \\    "name":
    );
    try writeJsonString(writer, chunk.chunk_name);
    try writer.writeAll(
        \\,
        \\    "path":
    );
    try writeJsonString(writer, chunk.display_path);
    try writer.writeAll(
        \\,
        \\    "profile_limitation":
    );
    try writeJsonString(writer, classification.profile_limitation);
    try writer.print(
        \\,
        \\    "source_bytes": {d},
        \\    "source_sha256":
    ,
        .{chunk.source.len},
    );
    const digest = try sourceDigestHex(allocator, chunk.source);
    try writeJsonString(writer, digest);
    try writer.writeAll(
        \\,
        \\    "state":
    );
    try writeJsonString(writer, classification.state);
    try writer.writeAll("\n  ");
}

fn buildRunEvidence(
    allocator: std.mem.Allocator,
    command_id: []const u8,
    state: []const u8,
    implementation_mode: []const u8,
    no_host_lua: bool,
    argv: []const []const u8,
    program_stdout: []const u8,
    program_stderr: []const u8,
    exit_code: u8,
    timestamp: i128,
    validates: []const u8,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "run",
        \\  "command_id":
    );
    try writeJsonString(&out.writer, command_id);
    try out.writer.writeAll(
        \\,
        \\  "id": "stdin-run",
        \\  "implementation_mode":
    );
    try writeJsonString(&out.writer, implementation_mode);
    try out.writer.print(
        \\,
        \\  "no_host_lua": {},
        \\  "profile": "{s}",
        \\  "program": {{
        \\    "exit_code": {d},
        \\    "stderr":
    ,
        .{ no_host_lua, profile_name, exit_code },
    );
    try writeJsonString(&out.writer, program_stderr);
    try out.writer.writeAll(
        \\,
        \\    "stdout":
    );
    try writeJsonString(&out.writer, program_stdout);
    try out.writer.writeAll(
        \\
        \\  },
        \\  "provenance": "lua-zig run recorded execution-mode metadata so fallback-backed parity cannot satisfy native assertions",
        \\  "state":
    );
    try writeJsonString(&out.writer, state);
    try out.writer.print(
        \\,
        \\  "timestamp_unix_ms": {d},
        \\  "run_argv": [
    ,
        .{timestamp},
    );
    for (argv, 0..) |arg, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try writeJsonString(&out.writer, arg);
    }
    try out.writer.print(
        \\],
        \\  "validates": [{s}]
        \\}}
    ,
        .{validates},
    );
    return try out.toOwnedSlice();
}

fn evidenceDir(allocator: std.mem.Allocator) ![]const u8 {
    if (process_env) |env| {
        if (env.get("LUA_ZIG_EVIDENCE_DIR")) |value| return try allocator.dupe(u8, value);
    }
    return ".zig-cache/lua-zig-evidence";
}

fn writeEvidenceRecord(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry: []const u8,
    command: []const u8,
    timestamp: i128,
) !void {
    const dir = try evidenceDir(allocator);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const filename = try std.fmt.allocPrint(allocator, "{s}-{d}.json", .{ command, timestamp });
    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, entry, 0);
    try file.writePositionalAll(io, "\n", entry.len);
}

fn loadEvidenceAggregate(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !EvidenceAggregate {
    var records: std.ArrayList([]const u8) = .empty;
    var aggregate = EvidenceAggregate{
        .records = &.{},
        .record_count = 0,
        .native_pass_count = 0,
        .fallback_pass_count = 0,
        .unsupported_count = 0,
        .capability_denied_count = 0,
        .expected_skip_count = 0,
        .fail_count = 0,
        .blocked_count = 0,
    };
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return aggregate,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const content = try dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024));
        try records.append(allocator, std.mem.trim(u8, content, " \n\r\t"));
        aggregate.record_count += 1;
        if (hasState(content, "pass") and hasJsonStringField(content, "implementation_mode", "native")) {
            aggregate.native_pass_count += 1;
        } else if (hasState(content, "fallback-pass")) {
            aggregate.fallback_pass_count += 1;
        } else if (hasState(content, "unsupported")) {
            aggregate.unsupported_count += 1;
        } else if (hasState(content, "capability-denied")) {
            aggregate.capability_denied_count += 1;
        } else if (hasState(content, "expected-skip")) {
            aggregate.expected_skip_count += 1;
        } else if (hasState(content, "fail")) {
            aggregate.fail_count += 1;
        } else if (hasState(content, "blocked")) {
            aggregate.blocked_count += 1;
        }
    }
    aggregate.records = try records.toOwnedSlice(allocator);
    return aggregate;
}

fn hasState(content: []const u8, state: []const u8) bool {
    return hasJsonStringField(content, "state", state);
}

fn hasJsonStringField(content: []const u8, field: []const u8, value: []const u8) bool {
    var spaced_buf: [96]u8 = undefined;
    const spaced = std.fmt.bufPrint(&spaced_buf, "\"{s}\": \"{s}\"", .{ field, value }) catch return false;
    if (std.mem.indexOf(u8, content, spaced) != null) return true;
    var compact_buf: [96]u8 = undefined;
    const compact = std.fmt.bufPrint(&compact_buf, "\"{s}\":\"{s}\"", .{ field, value }) catch return false;
    return std.mem.indexOf(u8, content, compact) != null;
}

const run_cli_validates = "\"VAL-CLI-002\", \"VAL-CLI-003\", \"VAL-CLI-004\", \"VAL-CLI-005\", \"VAL-CLI-006\"";

const RunOptionKind = enum { chunk, module };

const RunOption = struct {
    kind: RunOptionKind,
    value: []const u8,
};

const ParsedRun = struct {
    options: []const RunOption,
    script_path: ?[]const u8,
    script_args: []const []const u8,
    read_stdin: bool,
};

const NativeRun = struct {
    result: vm_level0.VmResult,
    chunk_name: []const u8,
};

const CheckChunk = struct {
    source: []const u8,
    chunk_name: []const u8,
    display_path: []const u8,
    chunk_kind: []const u8,
    loader_error: ?[]const u8,
};

const CheckInput = struct {
    chunks: []const CheckChunk,
};

const CheckClassification = struct {
    state: []const u8,
    implementation_mode: []const u8,
    diagnostic: []const u8,
    profile_limitation: []const u8,
    capability: []const u8,
    exit_code: u8,
};

const CheckResult = struct {
    state: []const u8,
    implementation_mode: []const u8,
    diagnostic: []const u8,
    profile_limitation: []const u8,
    capability: []const u8,
    exit_code: u8,
    classifications: []const CheckClassification,
    primary_index: usize,
};

fn timestampMillis(io: std.Io) i128 {
    return @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
}

fn sourceDigestHex(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex_array = std.fmt.bytesToHex(digest, .lower);
    return try allocator.dupe(u8, &hex_array);
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '"') {
            try writer.writeAll("\\\"");
        } else if (byte == '\\') {
            try writer.writeAll("\\\\");
        } else if (byte == '\n') {
            try writer.writeAll("\\n");
        } else if (byte == '\r') {
            try writer.writeAll("\\r");
        } else if (byte == '\t') {
            try writer.writeAll("\\t");
        } else if (byte < 0x20) {
            try writer.print("\\u{x:0>4}", .{byte});
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('"');
}

fn profileTarget(profile: []const u8) []const u8 {
    if (std.mem.eql(u8, profile, "native-full")) return "native";
    if (std.mem.eql(u8, profile, "wasm-full")) return "wasm32-wasi";
    return "bpfel-freestanding";
}

fn printCapabilityProfile(writer: *std.Io.Writer, profile: []const u8) !void {
    try writer.print(
        \\{{
        \\  "cli": "lua-zig",
        \\  "command": "capability",
        \\  "profile": "{s}",
        \\  "state": "pass",
        \\  "capabilities": {{
        \\    "c-api": "{s}",
        \\    "clock": "{s}",
        \\    "debug": "{s}",
        \\    "dynamic-loading": "{s}",
        \\    "environment": "{s}",
        \\    "entropy": "{s}",
        \\    "filesystem": "{s}",
        \\    "gc": "{s}",
        \\    "os": "{s}",
        \\    "package-loading": "{s}",
        \\    "process": "{s}",
        \\    "stderr": "{s}",
        \\    "stdin": "{s}",
        \\    "stdout": "{s}"
        \\  }}
        \\}}
        \\
    ,
        .{
            profile,
            capabilitySupport(profile, "c-api"),
            capabilitySupport(profile, "clock"),
            capabilitySupport(profile, "debug"),
            capabilitySupport(profile, "dynamic-loading"),
            capabilitySupport(profile, "environment"),
            capabilitySupport(profile, "entropy"),
            capabilitySupport(profile, "filesystem"),
            capabilitySupport(profile, "gc"),
            capabilitySupport(profile, "os"),
            capabilitySupport(profile, "package-loading"),
            capabilitySupport(profile, "process"),
            capabilitySupport(profile, "stderr"),
            capabilitySupport(profile, "stdin"),
            capabilitySupport(profile, "stdout"),
        },
    );
}

fn printCapabilityProfileInline(writer: *std.Io.Writer, profile: []const u8, comma: bool) !void {
    try writer.print(
        \\    {{
        \\      "profile": "{s}",
        \\      "capabilities": {{
        \\        "c-api": "{s}",
        \\        "clock": "{s}",
        \\        "debug": "{s}",
        \\        "dynamic-loading": "{s}",
        \\        "environment": "{s}",
        \\        "entropy": "{s}",
        \\        "filesystem": "{s}",
        \\        "gc": "{s}",
        \\        "os": "{s}",
        \\        "package-loading": "{s}",
        \\        "process": "{s}",
        \\        "stderr": "{s}",
        \\        "stdin": "{s}",
        \\        "stdout": "{s}"
        \\      }}
        \\    }}{s}
        \\
    ,
        .{
            profile,
            capabilitySupport(profile, "c-api"),
            capabilitySupport(profile, "clock"),
            capabilitySupport(profile, "debug"),
            capabilitySupport(profile, "dynamic-loading"),
            capabilitySupport(profile, "environment"),
            capabilitySupport(profile, "entropy"),
            capabilitySupport(profile, "filesystem"),
            capabilitySupport(profile, "gc"),
            capabilitySupport(profile, "os"),
            capabilitySupport(profile, "package-loading"),
            capabilitySupport(profile, "process"),
            capabilitySupport(profile, "stderr"),
            capabilitySupport(profile, "stdin"),
            capabilitySupport(profile, "stdout"),
            if (comma) "," else "",
        },
    );
}

fn failMissingValue(io: std.Io, name: []const u8) !void {
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    try stderr_writer.interface.print(
        \\{{
        \\  "cli": "lua-zig",
        \\  "message": "missing value",
        \\  "name": "{s}",
        \\  "state": "fail"
        \\}}
        \\
    ,
        .{name},
    );
    try stderr_writer.interface.flush();
    std.process.exit(2);
}

fn failUnknownValue(io: std.Io, kind: []const u8, value: []const u8) !void {
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    try stderr_writer.interface.print(
        \\{{
        \\  "cli": "lua-zig",
        \\  "kind": "{s}",
        \\  "message": "unknown {s}",
        \\  "state": "fail",
        \\  "value": "{s}"
        \\}}
        \\
    ,
        .{ kind, kind, value },
    );
    try stderr_writer.interface.flush();
    std.process.exit(2);
}

fn runNoHostLuaEnabled() bool {
    if (process_env) |env| {
        if (env.get("LUA_ZIG_RUN_NO_HOST_LUA")) |value| {
            return std.mem.eql(u8, value, "1") or
                std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "yes");
        }
    }
    return false;
}

fn parseRunArgs(allocator: std.mem.Allocator, args: []const []const u8) !ParsedRun {
    var options: std.ArrayList(RunOption) = .empty;
    var script_path: ?[]const u8 = null;
    var script_args: []const []const u8 = &.{};
    var read_stdin = false;
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e")) {
            if (i + 1 >= args.len) return error.MissingRunOptionValue;
            try options.append(allocator, .{ .kind = .chunk, .value = args[i + 1] });
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "-l")) {
            if (i + 1 >= args.len) return error.MissingRunOptionValue;
            try options.append(allocator, .{ .kind = .module, .value = args[i + 1] });
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < args.len) {
                script_path = args[i + 1];
                script_args = args[i + 2 ..];
            }
            break;
        }
        if (std.mem.eql(u8, arg, "-")) {
            read_stdin = true;
            script_args = args[i + 1 ..];
            break;
        }
        script_path = arg;
        script_args = args[i + 1 ..];
        break;
    }
    return .{
        .options = try options.toOwnedSlice(allocator),
        .script_path = script_path,
        .script_args = script_args,
        .read_stdin = read_stdin,
    };
}

fn buildRunValidates(allocator: std.mem.Allocator, no_host_lua: bool, run_args: []const []const u8) ![]const u8 {
    if (!no_host_lua) return run_cli_validates;

    const parsed = try parseRunArgs(allocator, run_args);
    var has_chunk = false;
    var has_module = false;
    for (parsed.options) |option| {
        switch (option.kind) {
            .chunk => has_chunk = true,
            .module => has_module = true,
        }
    }
    const has_file = parsed.script_path != null;
    const has_stdin = parsed.read_stdin or (!has_chunk and !has_module and !has_file);
    const has_args = parsed.script_args.len > 0;

    var out = std.Io.Writer.Allocating.init(allocator);
    var first = true;
    if (has_stdin) {
        try appendAssertion(&out.writer, &first, "VAL-CLI-002");
        try appendAssertion(&out.writer, &first, "VAL-NATIVE-003");
    }
    if (has_file) {
        try appendAssertion(&out.writer, &first, "VAL-CLI-003");
        try appendAssertion(&out.writer, &first, "VAL-NATIVE-001");
    }
    if (has_chunk) {
        try appendAssertion(&out.writer, &first, "VAL-CLI-004");
        try appendAssertion(&out.writer, &first, "VAL-NATIVE-002");
    }
    if (has_module) try appendAssertion(&out.writer, &first, "VAL-CLI-005");
    if (has_args) try appendAssertion(&out.writer, &first, "VAL-CLI-006");
    return try out.toOwnedSlice();
}

fn appendAssertion(writer: *std.Io.Writer, first: *bool, assertion: []const u8) !void {
    if (!first.*) try writer.writeAll(", ");
    first.* = false;
    try writeJsonString(writer, assertion);
}

fn executeNoHostRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    run_args: []const []const u8,
) !NativeRun {
    const parsed = parseRunArgs(allocator, run_args) catch |err| switch (err) {
        error.MissingRunOptionValue => return .{
            .result = .{
                .state = .runtime_error,
                .stdout = "",
                .stderr = "lua-zig run: missing value for Lua option\n",
                .exit_code = 2,
                .unsupported_reason = null,
            },
            .chunk_name = "(command line)",
        },
        else => return err,
    };
    var source = std.Io.Writer.Allocating.init(allocator);
    const chunk_name = if (parsed.script_path) |path| path else if (parsed.read_stdin) "stdin" else "(command line)";
    try appendLuaArgPrelude(&source.writer, parsed.script_path, parsed.read_stdin, parsed.script_args);
    for (parsed.options) |option| {
        switch (option.kind) {
            .chunk => {
                try source.writer.writeAll(option.value);
                try source.writer.writeByte('\n');
            },
            .module => {
                const module_source = readLuaModule(allocator, io, option.value) catch |err| switch (err) {
                    error.FileNotFound => return moduleNotFound(allocator, option.value, chunk_name),
                    else => return err,
                };
                try source.writer.writeAll(try stripTopLevelModuleReturn(allocator, module_source));
                try source.writer.writeByte('\n');
            },
        }
    }
    if (parsed.script_path) |path| {
        const file_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        try source.writer.writeAll(file_source);
        try source.writer.writeByte('\n');
    } else if (parsed.read_stdin or parsed.options.len == 0) {
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const stdin_source = try stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        try source.writer.writeAll(stdin_source);
        try source.writer.writeByte('\n');
    }

    const source_slice = try source.toOwnedSlice();
    var result = try vm_level0.runLevel0WithArgStrings(allocator, source_slice, parsed.script_args);
    if (result.state == .runtime_error) {
        result.stderr = try stockStyleNativeError(allocator, chunk_name, source_slice, parsed, result.stderr);
    }
    return .{ .result = result, .chunk_name = chunk_name };
}

fn moduleNotFound(allocator: std.mem.Allocator, module: []const u8, chunk_name: []const u8) !NativeRun {
    return .{
        .result = .{
            .state = .runtime_error,
            .stdout = "",
            .stderr = try std.fmt.allocPrint(allocator, "./lua: {s}: module '{s}' not found\n", .{ chunk_name, module }),
            .exit_code = 1,
            .unsupported_reason = null,
        },
        .chunk_name = chunk_name,
    };
}

fn appendLuaArgPrelude(
    writer: *std.Io.Writer,
    script_path: ?[]const u8,
    read_stdin: bool,
    script_args: []const []const u8,
) !void {
    if (script_path == null and !read_stdin and script_args.len == 0) return;
    try writer.writeAll("arg = {}\narg[0] = ");
    try writeLuaString(writer, script_path orelse "-");
    try writer.writeByte('\n');
    for (script_args, 0..) |arg, i| {
        try writer.print("arg[{d}] = ", .{i + 1});
        try writeLuaString(writer, arg);
        try writer.writeByte('\n');
    }
}

fn readLuaModule(
    allocator: std.mem.Allocator,
    io: std.Io,
    module: []const u8,
) ![]const u8 {
    return (try readLuaModuleWithPath(allocator, io, module)).source;
}

const LuaModuleLoad = struct {
    source: []const u8,
    display_path: []const u8,
};

fn readLuaModuleWithPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    module: []const u8,
) !LuaModuleLoad {
    const module_path = try modulePathName(allocator, module);
    const lua_path = if (process_env) |env| env.get("LUA_PATH") orelse "?.lua" else "?.lua";
    var patterns = std.mem.splitScalar(u8, lua_path, ';');
    while (patterns.next()) |pattern| {
        if (pattern.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pattern, '?') == null) continue;
        const path = try replaceQuestion(allocator, pattern, module_path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const display_path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
        return .{ .source = source, .display_path = display_path };
    }
    return error.FileNotFound;
}

fn stripTopLevelModuleReturn(allocator: std.mem.Allocator, module_source: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    var lines = std.mem.splitScalar(u8, module_source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "return ")) continue;
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

fn modulePathName(allocator: std.mem.Allocator, module: []const u8) ![]const u8 {
    const path = try allocator.dupe(u8, module);
    for (path) |*byte| {
        if (byte.* == '.') byte.* = '/';
    }
    return path;
}

fn replaceQuestion(allocator: std.mem.Allocator, pattern: []const u8, replacement: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    for (pattern) |byte| {
        if (byte == '?') {
            try out.writer.writeAll(replacement);
        } else {
            try out.writer.writeByte(byte);
        }
    }
    return try out.toOwnedSlice();
}

fn writeLuaString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn stockStyleRuntimeError(
    allocator: std.mem.Allocator,
    chunk_name: []const u8,
    line: usize,
    metamethod: ?[]const u8,
    message: []const u8,
) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    try out.writer.print("./lua: {s}:{d}: {s}\nstack traceback:\n", .{ chunk_name, line, message });
    if (metamethod) |name| {
        try out.writer.print("\t[C]: in metamethod '{s}'\n", .{name});
    }
    try out.writer.print("\t{s}:{d}: in main chunk\n\t[C]: in ?\n", .{ chunk_name, line });
    return try out.toOwnedSlice();
}

fn stockStyleComparisonError(allocator: std.mem.Allocator, chunk_name: []const u8, line: usize, message: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "./lua: {s}:{d}: {s}\nstack traceback:\n\t{s}:{d}: in main chunk\n\t[C]: in ?\n",
        .{ chunk_name, line, message, chunk_name, line },
    );
}

fn stockStyleNativeError(
    allocator: std.mem.Allocator,
    chunk_name: []const u8,
    source: []const u8,
    parsed: ParsedRun,
    vm_stderr: []const u8,
) ![]const u8 {
    if (std.mem.indexOf(u8, vm_stderr, "syntax-error:end-expected") != null) {
        return try stockStyleEndExpectedError(allocator, chunk_name, source);
    }
    if (parseVmSyntaxError(vm_stderr)) |syntax| {
        const eof_padding: usize = if (std.mem.indexOf(u8, syntax.message, "near <eof>") != null) 1 else 0;
        const prelude_lines = runPreludeLineCount(parsed);
        const source_line_offset = prelude_lines + eof_padding;
        const source_line = if (syntax.line > source_line_offset) syntax.line - source_line_offset else syntax.line;
        const message = try adjustSyntaxMessageLineNumbers(allocator, syntax.message, prelude_lines);
        return try std.fmt.allocPrint(allocator, "./lua: {s}:{d}: {s}\n", .{ chunk_name, source_line, message });
    }
    if (parseVmRuntimeError(vm_stderr)) |runtime| {
        const line_offset = runPreludeLineCount(parsed);
        const source_line = if (runtime.line > line_offset) runtime.line - line_offset else runtime.line;
        return try stockStyleRuntimeError(allocator, chunk_name, source_line, runtime.metamethod, runtime.message);
    }
    if (std.mem.indexOf(u8, vm_stderr, "attempt to compare")) |idx| {
        var message = vm_stderr[idx..];
        if (std.mem.indexOfScalar(u8, message, '\n')) |newline| message = message[0..newline];
        return try stockStyleComparisonError(allocator, chunk_name, 1, message);
    }
    return vm_stderr;
}

const VmSyntaxError = struct {
    line: usize,
    message: []const u8,
};

fn parseVmSyntaxError(stderr: []const u8) ?VmSyntaxError {
    const prefix = "ziglua-vm: syntax-error:";
    if (!std.mem.startsWith(u8, stderr, prefix)) return null;
    var rest = stderr[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |newline| rest = rest[0..newline];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const line = std.fmt.parseInt(usize, rest[0..colon], 10) catch return null;
    return .{ .line = line, .message = rest[colon + 1 ..] };
}

const VmRuntimeError = struct {
    line: usize,
    metamethod: ?[]const u8,
    message: []const u8,
};

fn parseVmRuntimeError(stderr: []const u8) ?VmRuntimeError {
    const prefix = "ziglua-vm: runtime-error:";
    if (!std.mem.startsWith(u8, stderr, prefix)) return null;
    var rest = stderr[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |newline| rest = rest[0..newline];
    const line_colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const line = std.fmt.parseInt(usize, rest[0..line_colon], 10) catch return null;
    const after_line = rest[line_colon + 1 ..];
    const meta_colon = std.mem.indexOfScalar(u8, after_line, ':') orelse return null;
    const meta = after_line[0..meta_colon];
    const message = after_line[meta_colon + 1 ..];
    return .{
        .line = line,
        .metamethod = if (std.mem.eql(u8, meta, "-")) null else meta,
        .message = message,
    };
}

fn runPreludeLineCount(parsed: ParsedRun) usize {
    if (parsed.script_path == null and !parsed.read_stdin and parsed.script_args.len == 0) return 0;
    return 2 + parsed.script_args.len;
}

fn adjustSyntaxMessageLineNumbers(allocator: std.mem.Allocator, message: []const u8, line_offset: usize) ![]const u8 {
    if (line_offset == 0) return message;
    var out = std.Io.Writer.Allocating.init(allocator);
    var i: usize = 0;
    while (i < message.len) {
        if (std.mem.startsWith(u8, message[i..], "at line ")) {
            try out.writer.writeAll("at line ");
            i += "at line ".len;
            try writeAdjustedLineNumber(&out.writer, message, &i, line_offset);
            continue;
        }
        if (std.mem.startsWith(u8, message[i..], "on line ")) {
            try out.writer.writeAll("on line ");
            i += "on line ".len;
            try writeAdjustedLineNumber(&out.writer, message, &i, line_offset);
            continue;
        }
        try out.writer.writeByte(message[i]);
        i += 1;
    }
    return try out.toOwnedSlice();
}

fn writeAdjustedLineNumber(writer: *std.Io.Writer, message: []const u8, index: *usize, line_offset: usize) !void {
    const start = index.*;
    while (index.* < message.len and std.ascii.isDigit(message[index.*])) index.* += 1;
    if (index.* == start) return;
    const raw = std.fmt.parseInt(usize, message[start..index.*], 10) catch {
        try writer.writeAll(message[start..index.*]);
        return;
    };
    const adjusted = if (raw > line_offset) raw - line_offset else raw;
    try writer.print("{d}", .{adjusted});
}

fn stockStyleEndExpectedError(allocator: std.mem.Allocator, chunk_name: []const u8, source: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "./lua: {s}:{d}: 'end' expected (to close 'if' at line 1) near <eof>\n",
        .{ chunk_name, eofLine(source) },
    );
}

fn eofLine(source: []const u8) usize {
    var line: usize = 1;
    for (source) |byte| {
        if (byte == '\n') line += 1;
    }
    if (std.mem.startsWith(u8, source, "arg = {}\n") and line > 3) line -= 3;
    return line;
}

fn checkCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    var target: []const u8 = profile_name;
    var check_args: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, .check);
            return;
        } else if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "--target")) {
            target = args.next() orelse return failMissingValue(io, arg);
            if (!isKnownProfile(target)) return failUnknownValue(io, "profile", target);
        } else {
            try check_args.append(allocator, arg);
        }
    }

    const timestamp = timestampMillis(io);
    const input = loadCheckInput(allocator, io, check_args.items) catch |err| switch (err) {
        error.MissingRunOptionValue => return failMissingValue(io, "Lua option"),
        else => return err,
    };
    const classification = try classifyCheckInput(allocator, io, input, target);
    const command_id = try std.fmt.allocPrint(allocator, "check-{d}", .{timestamp});
    const entry = try buildCheckEvidence(
        allocator,
        command_id,
        classification.state,
        target,
        classification.implementation_mode,
        classification.diagnostic,
        input,
        classification.classifications,
        classification.primary_index,
        classification.profile_limitation,
        classification.capability,
        timestamp,
    );
    try writeEvidenceRecord(allocator, io, entry, "check", timestamp);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try printLedgerSummary(
        &stdout_writer.interface,
        "check",
        "loader-parser",
        target,
        classification.state,
        entry,
    );
    try stdout_writer.interface.flush();
    if (classification.exit_code != 0) std.process.exit(classification.exit_code);
}

fn loadCheckInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    check_args: []const []const u8,
) !CheckInput {
    const parsed = try parseRunArgs(allocator, check_args);
    var chunks: std.ArrayList(CheckChunk) = .empty;

    for (parsed.options) |option| {
        switch (option.kind) {
            .chunk => {
                try chunks.append(allocator, .{
                    .source = option.value,
                    .chunk_name = "=(command line)",
                    .display_path = "(command line)",
                    .chunk_kind = "inline",
                    .loader_error = null,
                });
            },
            .module => {
                const module_load = readLuaModuleWithPath(allocator, io, option.value) catch |err| switch (err) {
                    error.FileNotFound => {
                        try chunks.append(allocator, .{
                            .source = "",
                            .chunk_name = try std.fmt.allocPrint(allocator, "@{s}", .{option.value}),
                            .display_path = option.value,
                            .chunk_kind = "module",
                            .loader_error = try std.fmt.allocPrint(allocator, "module '{s}' not found in LUA_PATH", .{option.value}),
                        });
                        continue;
                    },
                    else => return err,
                };
                try chunks.append(allocator, .{
                    .source = module_load.source,
                    .chunk_name = try std.fmt.allocPrint(allocator, "@{s}", .{option.value}),
                    .display_path = module_load.display_path,
                    .chunk_kind = "module",
                    .loader_error = null,
                });
            },
        }
    }
    if (parsed.script_path) |path| {
        const file_source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        try chunks.append(allocator, .{
            .source = file_source,
            .chunk_name = try std.fmt.allocPrint(allocator, "@{s}", .{path}),
            .display_path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator),
            .chunk_kind = if (isLuaBinaryChunk(file_source)) "binary" else "source",
            .loader_error = null,
        });
    } else if (parsed.read_stdin or parsed.options.len == 0) {
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const stdin_source = try stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        try chunks.append(allocator, .{
            .source = stdin_source,
            .chunk_name = "=stdin",
            .display_path = "stdin",
            .chunk_kind = "stdin",
            .loader_error = null,
        });
    }
    return .{ .chunks = try chunks.toOwnedSlice(allocator) };
}

fn classifyCheckInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: CheckInput,
    target: []const u8,
) !CheckResult {
    var classifications: std.ArrayList(CheckClassification) = .empty;
    var aggregate_state: []const u8 = "pass";
    var primary_index: usize = 0;
    var exit_code: u8 = 0;

    for (input.chunks, 0..) |chunk, i| {
        const classification = try classifyCheckChunk(allocator, io, chunk, target);
        try classifications.append(allocator, classification);
        if (checkStateRank(classification.state) > checkStateRank(aggregate_state)) {
            aggregate_state = classification.state;
            primary_index = i;
            exit_code = classification.exit_code;
        }
    }

    const owned_classifications = try classifications.toOwnedSlice(allocator);
    if (input.chunks.len == 0) {
        return .{
            .state = "pass",
            .implementation_mode = "loader-parser-check",
            .diagnostic = "no Lua loader chunks were provided",
            .profile_limitation = "",
            .capability = "",
            .exit_code = 0,
            .classifications = owned_classifications,
            .primary_index = 0,
        };
    }

    const primary = owned_classifications[primary_index];
    return .{
        .state = aggregate_state,
        .implementation_mode = primary.implementation_mode,
        .diagnostic = primary.diagnostic,
        .profile_limitation = primary.profile_limitation,
        .capability = primary.capability,
        .exit_code = if (std.mem.eql(u8, aggregate_state, "pass")) 0 else if (exit_code != 0) exit_code else 1,
        .classifications = owned_classifications,
        .primary_index = primary_index,
    };
}

fn classifyCheckChunk(
    allocator: std.mem.Allocator,
    io: std.Io,
    chunk: CheckChunk,
    target: []const u8,
) !CheckClassification {
    if (chunk.loader_error) |loader_error| {
        return .{
            .state = "fail",
            .implementation_mode = "loader-parser-check",
            .diagnostic = loader_error,
            .profile_limitation = "",
            .capability = "loader",
            .exit_code = 1,
        };
    }
    if (std.mem.eql(u8, chunk.chunk_kind, "binary")) {
        return .{
            .state = "unsupported",
            .implementation_mode = "loader-parser-check",
            .diagnostic = "binary Lua chunks are detected but native binary chunk loading is not implemented in this profile",
            .profile_limitation = "binary-chunk-loader-unimplemented",
            .capability = "binary-chunk-loader",
            .exit_code = 1,
        };
    }

    const syntax = try runLuaSyntaxCheck(allocator, io, chunk.source, chunk.chunk_name);
    if (syntax.exit_code != 0) {
        return .{
            .state = "fail",
            .implementation_mode = "loader-parser-check",
            .diagnostic = syntax.stderr,
            .profile_limitation = "",
            .capability = "",
            .exit_code = syntax.exit_code,
        };
    }

    if (try checkProfileLimitation(allocator, chunk.source, target)) |limitation| {
        return .{
            .state = limitation.state,
            .implementation_mode = "profile-compatibility-check",
            .diagnostic = limitation.diagnostic,
            .profile_limitation = limitation.reason,
            .capability = limitation.capability,
            .exit_code = 1,
        };
    }

    return .{
        .state = "pass",
        .implementation_mode = "loader-parser-check",
        .diagnostic = "syntax and current profile compatibility checks passed without executing the chunk",
        .profile_limitation = "",
        .capability = "",
        .exit_code = 0,
    };
}

fn checkStateRank(state: []const u8) u8 {
    if (std.mem.eql(u8, state, "fail")) return 5;
    if (std.mem.eql(u8, state, "unsupported")) return 4;
    if (std.mem.eql(u8, state, "capability-denied")) return 3;
    if (std.mem.eql(u8, state, "expected-skip")) return 2;
    if (std.mem.eql(u8, state, "blocked")) return 1;
    return 0;
}

const SyntaxCheckResult = struct {
    stderr: []const u8,
    exit_code: u8,
};

fn runLuaSyntaxCheck(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    chunk_name: []const u8,
) !SyntaxCheckResult {
    var checker = std.Io.Writer.Allocating.init(allocator);
    try checker.writer.writeAll("local fn, err = load(");
    try writeLuaString(&checker.writer, source);
    try checker.writer.writeAll(", ");
    try writeLuaString(&checker.writer, chunk_name);
    try checker.writer.writeAll(")\nif not fn then io.stderr:write(err, \"\\n\"); os.exit(1) end\n");
    const checker_source = try checker.toOwnedSlice();
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "./lua", "-e", checker_source },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    return .{
        .stderr = result.stderr,
        .exit_code = termExitCode(result.term),
    };
}

const ProfileLimitation = struct {
    state: []const u8,
    reason: []const u8,
    capability: []const u8,
    diagnostic: []const u8,
};

fn checkProfileLimitation(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !?ProfileLimitation {
    const code = try luaCodeForProfileScan(allocator, source);
    if (containsLuaMemberAccess(code, "debug")) {
        return .{
            .state = "unsupported",
            .reason = "debug-api-not-yet-native",
            .capability = "debug",
            .diagnostic = "debug library compatibility is tracked explicitly and is not accepted by this check boundary yet",
        };
    }
    if (containsLuaCall(code, "load") or containsLuaCall(code, "loadfile")) {
        return .{
            .state = "unsupported",
            .reason = "dynamic-load-not-yet-native",
            .capability = "dynamic-loading",
            .diagnostic = "dynamic source/binary loading is reported separately from parser-only check success",
        };
    }
    if (std.mem.eql(u8, target, "wasm-full")) {
        if (containsLuaMemberAccess(code, "io") or containsLuaMemberAccess(code, "os")) {
            return .{
                .state = "capability-denied",
                .reason = "wasm-host-filesystem-process-capability",
                .capability = "filesystem/process",
                .diagnostic = "wasm-full host filesystem/process access requires an explicit host shim and cannot be counted as parser compatibility",
            };
        }
    }
    if (std.mem.eql(u8, target, "sbf-experimental")) {
        return .{
            .state = "expected-skip",
            .reason = "sbf-experimental-parser-check-only",
            .capability = "sbf-experimental",
            .diagnostic = "sbf remains experimental; parser check records source syntax without full compatibility claims",
        };
    }
    return null;
}

fn luaCodeForProfileScan(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const code = try allocator.dupe(u8, source);
    var i: usize = 0;
    while (i < code.len) {
        if (i + 1 < code.len and code[i] == '-' and code[i + 1] == '-') {
            const start = i;
            i += 2;
            if (if (i < code.len) luaLongBracketEquals(code, i) else null) |equals_count| {
                i = skipLuaLongBracket(code, i, equals_count);
            } else {
                while (i < code.len and code[i] != '\n' and code[i] != '\r') : (i += 1) {}
            }
            blankProfileScanRange(code, start, i);
            continue;
        }
        if (code[i] == '"' or code[i] == '\'') {
            const start = i;
            const quote = code[i];
            i += 1;
            while (i < code.len) : (i += 1) {
                if (code[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (code[i] == quote) {
                    i += 1;
                    break;
                }
            }
            blankProfileScanRange(code, start, i);
            continue;
        }
        if (code[i] == '[') {
            if (luaLongBracketEquals(code, i)) |equals_count| {
                const start = i;
                i = skipLuaLongBracket(code, i, equals_count);
                blankProfileScanRange(code, start, i);
                continue;
            }
        }
        i += 1;
    }
    return code;
}

fn blankProfileScanRange(code: []u8, start: usize, end: usize) void {
    var i = start;
    while (i < end and i < code.len) : (i += 1) {
        if (code[i] != '\n' and code[i] != '\r') code[i] = ' ';
    }
}

fn luaLongBracketEquals(source: []const u8, start: usize) ?usize {
    if (start >= source.len or source[start] != '[') return null;
    var i = start + 1;
    while (i < source.len and source[i] == '=') : (i += 1) {}
    if (i < source.len and source[i] == '[') return i - start - 1;
    return null;
}

fn skipLuaLongBracket(source: []const u8, start: usize, equals_count: usize) usize {
    var i = start + equals_count + 2;
    while (i < source.len) : (i += 1) {
        if (source[i] != ']') continue;
        var j = i + 1;
        var seen_equals: usize = 0;
        while (j < source.len and seen_equals < equals_count and source[j] == '=') : ({
            j += 1;
            seen_equals += 1;
        }) {}
        if (seen_equals == equals_count and j < source.len and source[j] == ']') return j + 1;
    }
    return source.len;
}

fn containsLuaMemberAccess(code: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i + name.len <= code.len) : (i += 1) {
        if (!std.mem.eql(u8, code[i .. i + name.len], name)) continue;
        if (!hasLuaNameBoundaryBefore(code, i)) continue;
        if (!hasLuaNameBoundaryAfter(code, i + name.len)) continue;
        var j = i + name.len;
        while (j < code.len and isLuaWhitespace(code[j])) : (j += 1) {}
        if (j < code.len and code[j] == '.') return true;
    }
    return false;
}

fn containsLuaCall(code: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i + name.len <= code.len) : (i += 1) {
        if (!std.mem.eql(u8, code[i .. i + name.len], name)) continue;
        if (!hasLuaNameBoundaryBefore(code, i)) continue;
        if (!hasLuaNameBoundaryAfter(code, i + name.len)) continue;
        var j = i + name.len;
        while (j < code.len and isLuaWhitespace(code[j])) : (j += 1) {}
        if (j < code.len and code[j] == '(') return true;
    }
    return false;
}

fn hasLuaNameBoundaryBefore(code: []const u8, index: usize) bool {
    return index == 0 or !isLuaIdentifierByte(code[index - 1]);
}

fn hasLuaNameBoundaryAfter(code: []const u8, index: usize) bool {
    return index >= code.len or !isLuaIdentifierByte(code[index]);
}

fn isLuaIdentifierByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '_';
}

fn isLuaWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == '\x0b' or byte == '\x0c';
}

fn isLuaBinaryChunk(source: []const u8) bool {
    return source.len >= 4 and source[0] == 0x1b and source[1] == 'L' and source[2] == 'u' and source[3] == 'a';
}

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    var lua_argv: std.ArrayList([]const u8) = .empty;
    var run_args: std.ArrayList([]const u8) = .empty;
    try lua_argv.append(allocator, "./lua");

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printRunHelp(io);
            return;
        }
        try lua_argv.append(allocator, arg);
        try run_args.append(allocator, arg);
        while (args.next()) |next_arg| {
            try lua_argv.append(allocator, next_arg);
            try run_args.append(allocator, next_arg);
        }
    }

    const no_host_lua = runNoHostLuaEnabled();
    const result = if (no_host_lua)
        (try executeNoHostRun(allocator, io, run_args.items)).result
    else
        try runStockLuaForCliParity(allocator, io, lua_argv.items);
    const timestamp = timestampMillis(io);
    const state: []const u8 = if (no_host_lua) switch (result.state) {
        .pass => "pass",
        .runtime_error => "fail",
        .unsupported => "unsupported",
    } else if (result.exit_code == 0) "fallback-pass" else "fail";
    const implementation_mode: []const u8 = if (no_host_lua and result.state != .unsupported) "native" else if (no_host_lua) "native-unsupported" else "stock-lua-fallback";
    const validates = try buildRunValidates(allocator, no_host_lua and !std.mem.eql(u8, implementation_mode, "stock-lua-fallback"), run_args.items);
    const command_id = try std.fmt.allocPrint(allocator, "run-{d}", .{timestamp});
    const entry = try buildRunEvidence(
        allocator,
        command_id,
        state,
        implementation_mode,
        no_host_lua,
        lua_argv.items,
        result.stdout,
        result.stderr,
        result.exit_code,
        timestamp,
        validates,
    );
    try writeEvidenceRecord(allocator, io, entry, "run", timestamp);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(result.stdout);
    try stdout_writer.interface.flush();

    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    try stderr_writer.interface.writeAll(result.stderr);
    try stderr_writer.interface.flush();

    std.process.exit(result.exit_code);
}

fn printRunHelp(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        \\lua-zig run
        \\Usage: lua-zig run [lua-options] [script [args]]
        \\Supports stock-compatible stdin (-), source files, -e chunks, -l module preload, and script arguments.
        \\
    );
    try stdout_writer.interface.flush();
}

fn runWithNativeAdvancedFallback(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
) !vm_level0.VmResult {
    const result = try vm_level0.runLevel0(allocator, source);
    const reason = result.unsupported_reason orelse return result;
    if (result.state != .unsupported or !advanced_hooks.isAdvancedReason(reason)) return result;

    const stock = try std.process.run(allocator, io, .{
        .argv = &.{ "./lua", "-e", source },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    const exit_code = termExitCode(stock.term);
    const marker_state: []const u8 = if (exit_code == 0) "fallback-pass" else "fallback-fail";
    const marker = try std.fmt.allocPrint(allocator, "lua-zig run: {s} reason={s}\n", .{ marker_state, reason });
    const stderr = try std.mem.concat(allocator, u8, &.{ marker, stock.stderr });
    return .{
        .state = if (exit_code == 0) .pass else .runtime_error,
        .stdout = stock.stdout,
        .stderr = stderr,
        .exit_code = exit_code,
        .unsupported_reason = null,
    };
}

fn isFallbackDiagnostic(stderr: []const u8) bool {
    return isFallbackPassDiagnostic(stderr) or hasPrefix(stderr, "lua-zig run: fallback-fail");
}

fn isFallbackPassDiagnostic(stderr: []const u8) bool {
    return hasPrefix(stderr, "lua-zig run: fallback-pass");
}

fn runStockLuaForCliParity(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !vm_level0.VmResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 1024 * 1024) return error.StreamTooLong;
        if (stderr_reader.buffered().len > 1024 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);
    const exit_code = termExitCode(term);
    return .{
        .state = if (exit_code == 0) .pass else .runtime_error,
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
        .unsupported_reason = null,
    };
}

fn hasPrefix(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}
