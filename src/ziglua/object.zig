const std = @import("std");

pub const Kind = enum(u8) {
    string,
    table,
    function,
    closure,
    upvalue,
    thread,
    userdata,
};

pub const Lifecycle = enum(u8) {
    white,
    gray,
    black,
    finalized,
};

pub const Header = struct {
    kind: Kind,
    lifecycle: Lifecycle,
    flags: u8,

    pub fn init(object_kind: Kind) Header {
        return .{
            .kind = object_kind,
            .lifecycle = .white,
            .flags = 0,
        };
    }

    pub fn mark(self: *Header, next_lifecycle: Lifecycle) void {
        self.lifecycle = next_lifecycle;
    }

    pub fn isFinalized(self: Header) bool {
        return self.lifecycle == .finalized;
    }
};

pub fn kind(header: *const Header) Kind {
    return header.kind;
}

pub fn lifecycle(header: *const Header) Lifecycle {
    return header.lifecycle;
}

test "object header contract" {
    const string = @import("string.zig");
    const table = @import("table.zig");
    const function = @import("function.zig");
    const thread = @import("thread.zig");
    const userdata = @import("userdata.zig");

    const alloc = std.testing.allocator;

    const s = try string.String.create(alloc, "header");
    defer s.destroy(alloc);
    try std.testing.expectEqual(Kind.string, kind(&s.header));
    try std.testing.expectEqual(Lifecycle.white, lifecycle(&s.header));

    const t = try table.Table.create(alloc);
    defer t.destroy(alloc);
    try std.testing.expectEqual(Kind.table, kind(&t.header));

    const f = try function.Function.create(alloc, .lua);
    defer f.destroy(alloc);
    try std.testing.expectEqual(Kind.function, kind(&f.header));

    const c = try function.Closure.create(alloc, f, 2);
    defer c.destroy(alloc);
    try std.testing.expectEqual(Kind.closure, kind(&c.header));

    const up = try function.Upvalue.create(alloc, 1);
    defer up.destroy(alloc);
    try std.testing.expectEqual(Kind.upvalue, kind(&up.header));

    const th = try thread.Thread.create(alloc);
    defer th.destroy(alloc);
    try std.testing.expectEqual(Kind.thread, kind(&th.header));

    const ud = try userdata.Userdata.create(alloc, 4);
    defer ud.destroy(alloc);
    try std.testing.expectEqual(Kind.userdata, kind(&ud.header));

    t.header.mark(.gray);
    try std.testing.expectEqual(Lifecycle.gray, lifecycle(&t.header));
}
