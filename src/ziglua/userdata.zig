const std = @import("std");
const object = @import("object.zig");

pub const Userdata = struct {
    header: object.Header,
    bytes: []u8,
    user_values: usize,

    pub fn create(allocator: std.mem.Allocator, len: usize) !*Userdata {
        const self = try allocator.create(Userdata);
        errdefer allocator.destroy(self);

        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);

        self.* = .{
            .header = object.Header.init(.userdata),
            .bytes = bytes,
            .user_values = 0,
        };
        return self;
    }

    pub fn destroy(self: *Userdata, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.destroy(self);
    }
};

test "userdata placeholder allocation contract" {
    const ud = try Userdata.create(std.testing.allocator, 3);
    defer ud.destroy(std.testing.allocator);
    try std.testing.expectEqual(object.Kind.userdata, ud.header.kind);
    try std.testing.expectEqual(@as(usize, 3), ud.bytes.len);
}
