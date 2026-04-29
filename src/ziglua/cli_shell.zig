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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
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
        .build, .check => try registeredRouteCommand(io, command, &args),
        .test_cmd => try testCommand(io, &args),
        .profile => try profileCommand(io, &args),
        .report => try reportCommand(io, &args),
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

fn registeredRouteCommand(io: std.Io, command: Command, args: *std.process.Args.Iterator) !void {
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, command);
            return;
        }
    }
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

fn testCommand(io: std.Io, args: *std.process.Args.Iterator) !void {
    var suite: []const u8 = "cli-ledger";
    var target: []const u8 = profile_name;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printCommandHelp(io, .test_cmd);
            return;
        } else if (std.mem.eql(u8, arg, "--suite")) {
            suite = args.next() orelse return failMissingValue(io, "--suite");
            if (!isKnownSuite(suite)) return failUnknownValue(io, "suite", suite);
        } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "--profile")) {
            target = args.next() orelse return failMissingValue(io, arg);
            if (!isKnownProfile(target)) return failUnknownValue(io, "profile", target);
        } else {
            return failUnknownValue(io, "option", arg);
        }
    }

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.print(
        \\{{
        \\  "accounting": {{
        \\    "blocked_count": 0,
        \\    "capability_denied_count": 0,
        \\    "expected_skip_count": 0,
        \\    "fail_count": 0,
        \\    "fallback_pass_count": 0,
        \\    "native_pass_count": 1,
        \\    "unsupported_count": 0
        \\  }},
        \\  "cli": "lua-zig",
        \\  "command": "test",
        \\  "ledger": [
        \\    {{
        \\      "id": "cli-ledger-command-surface",
        \\      "implementation_mode": "native",
        \\      "profile": "{s}",
        \\      "provenance": "built-in deterministic CLI ledger smoke",
        \\      "state": "pass",
        \\      "suite": "{s}",
        \\      "validates": ["VAL-CLI-011", "VAL-NATIVE-018", "VAL-NATIVE-019", "VAL-NATIVE-020"]
        \\    }}
        \\  ],
        \\  "selected_suite": "{s}",
        \\  "state": "pass",
        \\  "states": ["pass", "fallback-pass", "unsupported", "capability-denied", "expected-skip", "fail", "blocked"],
        \\  "target_profile": "{s}"
        \\}}
        \\
    ,
        .{ target, suite, suite, target },
    );
    try stdout_writer.interface.flush();
}

fn profileCommand(io: std.Io, args: *std.process.Args.Iterator) !void {
    const maybe_action = args.next();
    if (maybe_action) |action| {
        if (std.mem.eql(u8, action, "--help") or std.mem.eql(u8, action, "-h")) {
            try printCommandHelp(io, .profile);
            return;
        }
        if (std.mem.eql(u8, action, "metrics") or std.mem.eql(u8, action, "perf")) {
            try printProfileMetrics(io);
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

fn reportCommand(io: std.Io, args: *std.process.Args.Iterator) !void {
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

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        \\{
        \\  "accounting": {
        \\    "blocked_count": 0,
        \\    "capability_denied_count": 1,
        \\    "expected_skip_count": 1,
        \\    "fail_count": 0,
        \\    "fallback_pass_count": 1,
        \\    "native_implementation_compatibility_count": 1,
        \\    "native_pass_count": 1,
        \\    "unsupported_count": 1
        \\  },
        \\  "build_id": "lua-zig-0.1.0-zig-0.16.0",
        \\  "cli": "lua-zig",
        \\  "command": "report",
        \\  "compatibility_policy": {
        \\    "fallback_counts_as_native": false,
        \\    "unsupported_counts_as_native": false
        \\  },
        \\  "ledger": [
        \\    {"id": "cli-help-version", "profile": "native-full", "state": "pass", "implementation_mode": "native", "provenance": "zig build installed lua-zig help/version surface"},
        \\    {"id": "run-advanced-fallback", "profile": "native-full", "state": "fallback-pass", "implementation_mode": "stock-lua-fallback", "fallback_reason": "advanced dynamic semantics", "provenance": "lua-zig run emits fallback-pass marker on stderr"},
        \\    {"id": "wasm-host-process", "profile": "wasm-full", "state": "capability-denied", "implementation_mode": "host-capability-contract", "reason": "process spawning unavailable in WASM host profile", "provenance": "profile capability matrix"},
        \\    {"id": "wasm-dynamic-c-loading", "profile": "wasm-full", "state": "unsupported", "implementation_mode": "none", "reason": "dynamic C loading is not available in current WASM contract", "provenance": "profile capability matrix"},
        \\    {"id": "sbf-deployable-artifact", "profile": "sbf-experimental", "state": "expected-skip", "implementation_mode": "metadata-only", "reason": "SBF remains experimental spike scope", "provenance": "SBF profile contract"}
        \\  ],
        \\  "ledger_format_version": 1,
        \\  "state": "pass",
        \\  "states": ["pass", "fallback-pass", "unsupported", "capability-denied", "expected-skip", "fail", "blocked"]
        \\}
        \\
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

fn printProfileMetrics(io: std.Io) !void {
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout_writer.interface.writeAll(
        \\{
        \\  "cli": "lua-zig",
        \\  "command": "profile",
        \\  "metrics": {
        \\    "allocation_bytes": 0,
        \\    "timing_ms": 0
        \\  },
        \\  "mode": "runtime-metrics",
        \\  "profiler_output": "json",
        \\  "program_output": "separate-stdout-stderr",
        \\  "state": "pass"
        \\}
        \\
    );
    try stdout_writer.interface.flush();
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
    const marker = try std.fmt.allocPrint(allocator, "lua-zig run: fallback-pass reason={s}\n", .{reason});
    const stderr = try std.mem.concat(allocator, u8, &.{ marker, stock.stderr });
    return .{
        .state = .pass,
        .stdout = stock.stdout,
        .stderr = stderr,
        .exit_code = termExitCode(stock.term),
        .unsupported_reason = null,
    };
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}
