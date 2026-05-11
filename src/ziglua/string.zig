const std = @import("std");
const object = @import("object.zig");

pub const String = struct {
    header: object.Header,
    bytes: []u8,

    pub fn create(allocator: std.mem.Allocator, source: []const u8) !*String {
        const self = try allocator.create(String);
        errdefer allocator.destroy(self);

        const owned = try allocator.dupe(u8, source);
        errdefer allocator.free(owned);

        self.* = .{
            .header = object.Header.init(.string),
            .bytes = owned,
        };
        return self;
    }

    pub fn destroy(self: *String, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    pub fn slice(self: *const String) []const u8 {
        return self.bytes;
    }
};

test "string owns copied bytes" {
    const alloc = std.testing.allocator;
    var source = [_]u8{ 'a', 0, 'b' };

    const s = try String.create(alloc, source[0..]);
    defer s.destroy(alloc);

    source[0] = 'z';

    try std.testing.expectEqual(object.Kind.string, s.header.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', 0, 'b' }, s.slice());
}
