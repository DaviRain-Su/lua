const std = @import("std");

pub const allocator = @import("allocator.zig");
pub const function = @import("function.zig");
pub const lua_alloc_bridge = @import("lua_alloc_bridge.zig");
pub const object = @import("object.zig");
pub const string = @import("string.zig");
pub const table = @import("table.zig");
pub const thread = @import("thread.zig");
pub const userdata = @import("userdata.zig");
pub const value = @import("value.zig");
pub const vm_level0 = @import("vm_level0.zig");

var stdout_buffer: [256]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").target.os.tag != .freestanding) {
        var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        try stdout_writer.interface.print("ziglua profile smoke marker=0x{x}\n", .{ziglua_profile_marker()});
        try stdout_writer.interface.flush();
    }
}

export fn ziglua_profile_marker() u32 {
    return 0x5a1a55;
}

test "profile stub marker is stable" {
    try std.testing.expectEqual(@as(u32, 0x5a1a55), ziglua_profile_marker());
}
