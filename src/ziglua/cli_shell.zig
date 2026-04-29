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
        .build, .test_cmd, .check, .profile, .report, .capability => {
            if (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    try printCommandHelp(io, command);
                    return;
                }
            }
            try printRegisteredRoute(io, command);
        },
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
    try stdout_writer.interface.print(
        \\lua-zig {s}
        \\Usage: lua-zig {s} [options]
        \\State: route registered; detailed behavior is implemented by milestone-specific validators.
        \\
    ,
        .{ commandName(command), commandName(command) },
    );
    try stdout_writer.interface.flush();
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
