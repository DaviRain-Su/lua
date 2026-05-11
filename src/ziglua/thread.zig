const std = @import("std");
const object = @import("object.zig");

pub const Status = enum(u8) {
    fresh,
    running,
    suspended,
    dead,
};

pub const Thread = struct {
    header: object.Header,
    status: Status,
    stack_slots: usize,

    pub fn create(allocator: std.mem.Allocator) !*Thread {
        const self = try allocator.create(Thread);
        self.* = .{
            .header = object.Header.init(.thread),
            .status = .fresh,
            .stack_slots = 0,
        };
        return self;
    }

    pub fn destroy(self: *Thread, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

test "thread placeholder allocation contract" {
    const th = try Thread.create(std.testing.allocator);
    defer th.destroy(std.testing.allocator);
    try std.testing.expectEqual(object.Kind.thread, th.header.kind);
    try std.testing.expectEqual(Status.fresh, th.status);
}
