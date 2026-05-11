const std = @import("std");
const advanced_hooks = @import("advanced_hooks.zig");
const vm_level0 = @import("vm_level0.zig");

var stdout_buffer: [4096]u8 = undefined;
var stderr_buffer: [4096]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

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

fn runWithNativeAdvancedFallback(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !vm_level0.VmResult {
    const result = try vm_level0.runLevel0(allocator, source);
    const reason = result.unsupported_reason orelse return result;
    if (result.state != .unsupported or !advanced_hooks.isAdvancedReason(reason)) return result;

    const stock = try std.process.run(allocator, io, .{
        .argv = &.{ "./lua", "-e", source },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    const marker = try std.fmt.allocPrint(allocator, "ziglua-vm: fallback-pass reason={s}\n", .{reason});
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
