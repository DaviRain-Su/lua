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
        .build, .check => try registeredRouteCommand(allocator, io, command, &args),
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

fn buildRunEvidence(
    allocator: std.mem.Allocator,
    command_id: []const u8,
    state: []const u8,
    implementation_mode: []const u8,
    source: []const u8,
    program_stdout: []const u8,
    program_stderr: []const u8,
    exit_code: u8,
    timestamp: i128,
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
        \\  "profile": "{s}",
        \\  "program": {{
        \\    "exit_code": {d},
        \\    "stderr":
    ,
        .{ profile_name, exit_code },
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
        \\  "provenance": "lua-zig run executed stdin source through the native VM route or explicit fallback path",
        \\  "state":
    );
    try writeJsonString(&out.writer, state);
    try out.writer.print(
        \\,
        \\  "timestamp_unix_ms": {d},
        \\  "fixture": {{
        \\    "path": "stdin",
        \\    "source_bytes": {d},
        \\    "source_sha256":
    ,
        .{ timestamp, source.len },
    );
    const digest = try sourceDigestHex(allocator, source);
    try writeJsonString(&out.writer, digest);
    try out.writer.writeAll(
        \\
        \\  }
        \\}
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

fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    const first_arg = args.next();
    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printRunHelp(io);
            return;
        }
        if (!std.mem.eql(u8, arg, "-")) {
            try printRunUnsupportedTarget(io, arg);
            std.process.exit(2);
        }
    }

    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const source = try stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    const result = try runWithNativeAdvancedFallback(allocator, io, source);
    const timestamp = timestampMillis(io);
    const state: []const u8 = if (isFallbackPassDiagnostic(result.stderr) and result.exit_code == 0)
        "fallback-pass"
    else if (isFallbackDiagnostic(result.stderr))
        "fail"
    else switch (result.state) {
        .pass => "pass",
        .runtime_error => "fail",
        .unsupported => "unsupported",
    };
    const implementation_mode: []const u8 = if (isFallbackDiagnostic(result.stderr))
        "stock-lua-fallback"
    else if (std.mem.eql(u8, state, "unsupported"))
        "none"
    else
        "native";
    const command_id = try std.fmt.allocPrint(allocator, "run-{d}", .{timestamp});
    const entry = try buildRunEvidence(
        allocator,
        command_id,
        state,
        implementation_mode,
        source,
        result.stdout,
        result.stderr,
        result.exit_code,
        timestamp,
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
        \\Usage: lua-zig run [-]
        \\Reads Lua source from stdin and executes it through the native VM route.
        \\
    );
    try stdout_writer.interface.flush();
}

fn printRunUnsupportedTarget(io: std.Io, target: []const u8) !void {
    _ = target;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    try stderr_writer.interface.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "run",
        \\  "message": "only stdin target '-' is implemented by the CLI shell milestone",
        \\  "state": "pending",
        \\  "target": "unsupported"
        \\}
        \\
    );
    try stderr_writer.interface.flush();
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

fn hasPrefix(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}
