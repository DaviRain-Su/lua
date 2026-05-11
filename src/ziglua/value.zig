const std = @import("std");

const function_mod = @import("function.zig");
const string_mod = @import("string.zig");
const table_mod = @import("table.zig");
const thread_mod = @import("thread.zig");
const userdata_mod = @import("userdata.zig");

pub const Tag = enum {
    nil,
    boolean,
    integer,
    float,
    string,
    table,
    function,
    closure,
    thread,
    userdata,
};

pub const Value = struct {
    payload: Payload,

    const Payload = union(Tag) {
        nil: void,
        boolean: bool,
        integer: i64,
        float: f64,
        string: *string_mod.String,
        table: *table_mod.Table,
        function: *function_mod.Function,
        closure: *function_mod.Closure,
        thread: *thread_mod.Thread,
        userdata: *userdata_mod.Userdata,
    };

    pub fn nil() Value {
        return .{ .payload = .{ .nil = {} } };
    }

    pub fn boolean(value: bool) Value {
        return .{ .payload = .{ .boolean = value } };
    }

    pub fn integer(value: i64) Value {
        return .{ .payload = .{ .integer = value } };
    }

    pub fn float(value: f64) Value {
        return .{ .payload = .{ .float = value } };
    }

    pub fn string(value: *string_mod.String) Value {
        return .{ .payload = .{ .string = value } };
    }

    pub fn table(value: *table_mod.Table) Value {
        return .{ .payload = .{ .table = value } };
    }

    pub fn function(value: *function_mod.Function) Value {
        return .{ .payload = .{ .function = value } };
    }

    pub fn closure(value: *function_mod.Closure) Value {
        return .{ .payload = .{ .closure = value } };
    }

    pub fn thread(value: *thread_mod.Thread) Value {
        return .{ .payload = .{ .thread = value } };
    }

    pub fn userdata(value: *userdata_mod.Userdata) Value {
        return .{ .payload = .{ .userdata = value } };
    }

    pub fn tag(self: Value) Tag {
        return std.meta.activeTag(self.payload);
    }
};

test "value tags cover lua kinds" {
    const failing = std.testing.failing_allocator;

    try std.testing.expectEqual(Tag.nil, Value.nil().tag());
    try std.testing.expectEqual(Tag.boolean, Value.boolean(false).tag());
    try std.testing.expectEqual(Tag.integer, Value.integer(-7).tag());
    try std.testing.expectEqual(Tag.float, Value.float(2.25).tag());
    try std.testing.expectError(error.OutOfMemory, failing.alloc(u8, 1));

    const alloc = std.testing.allocator;

    const s = try string_mod.String.create(alloc, "v");
    defer s.destroy(alloc);
    try std.testing.expectEqual(Tag.string, Value.string(s).tag());

    const t = try table_mod.Table.create(alloc);
    defer t.destroy(alloc);
    try std.testing.expectEqual(Tag.table, Value.table(t).tag());

    const f = try function_mod.Function.create(alloc, .lua);
    defer f.destroy(alloc);
    try std.testing.expectEqual(Tag.function, Value.function(f).tag());

    const c = try function_mod.Closure.create(alloc, f, 0);
    defer c.destroy(alloc);
    try std.testing.expectEqual(Tag.closure, Value.closure(c).tag());

    const th = try thread_mod.Thread.create(alloc);
    defer th.destroy(alloc);
    try std.testing.expectEqual(Tag.thread, Value.thread(th).tag());

    const ud = try userdata_mod.Userdata.create(alloc, 0);
    defer ud.destroy(alloc);
    try std.testing.expectEqual(Tag.userdata, Value.userdata(ud).tag());
}
