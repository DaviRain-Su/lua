const std = @import("std");
const advanced_hooks = @import("advanced_hooks.zig");
const vm_level0 = @import("vm_level0.zig");

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const first_arg = args.next();
    const check_only = first_arg != null and std.mem.eql(u8, first_arg.?, "--check");

    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    const source = try stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    const result = try vm_level0.runLevel0(allocator, source);

    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);

    if (check_only) {
        switch (result.state) {
            .pass, .runtime_error => {
                try stdout_writer.interface.print(
                    "ziglua-aot: eligible Level 0 lowered-artifact=ir source-stdin-bytes={d}\n",
                    .{source.len},
                );
                try stdout_writer.interface.flush();
                std.process.exit(0);
            },
            .unsupported => {
                try stderr_writer.interface.print(
                    "ziglua-aot: unsupported/fallback AOT Level 0 chunk: {s}\n",
                    .{unsupportedReason(result.stderr)},
                );
                try stderr_writer.interface.flush();
                std.process.exit(1);
            },
        }
    }

    switch (result.state) {
        .pass => {
            try stdout_writer.interface.writeAll(result.stdout);
            try stdout_writer.interface.flush();
            std.process.exit(result.exit_code);
        },
        .runtime_error => {
            try stderr_writer.interface.print("ziglua-aot:{s}", .{diagnosticMessage(result.stderr)});
            try stderr_writer.interface.flush();
            std.process.exit(result.exit_code);
        },
        .unsupported => {
            const reason = unsupportedReason(result.stderr);
            if (advanced_hooks.isAdvancedReason(reason)) {
                const stock = try std.process.run(allocator, io, .{
                    .argv = &.{ "./lua", "-e", source },
                    .stdout_limit = .unlimited,
                    .stderr_limit = .unlimited,
                });
                try stdout_writer.interface.writeAll(stock.stdout);
                try stdout_writer.interface.flush();
                try stderr_writer.interface.print("ziglua-aot: fallback-pass reason={s}\n", .{reason});
                try stderr_writer.interface.writeAll(stock.stderr);
                try stderr_writer.interface.flush();
                std.process.exit(termExitCode(stock.term));
            }
            try stderr_writer.interface.print(
                "ziglua-aot: unsupported/fallback AOT Level 0 chunk: {s}\n",
                .{reason},
            );
            try stderr_writer.interface.flush();
            std.process.exit(1);
        },
    }
}

fn unsupportedReason(stderr: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, stderr, "\r\n");
    if (std.mem.lastIndexOf(u8, trimmed, ": ")) |idx| {
        return trimmed[idx + 2 ..];
    }
    return "outside-level0-subset";
}

fn diagnosticMessage(stderr: []const u8) []const u8 {
    const vm_prefix = "ziglua-vm:";
    if (std.mem.startsWith(u8, stderr, vm_prefix)) {
        return stderr[vm_prefix.len..];
    }
    return stderr;
}

fn termExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

test "aot unsupported reason extracts final diagnostic reason" {
    try std.testing.expectEqualStrings(
        "load",
        unsupportedReason("ziglua-vm: unsupported/fallback Level 1 snippet: load\n"),
    );
}
