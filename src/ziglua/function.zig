const std = @import("std");
const object = @import("object.zig");
const runtime_allocator = @import("allocator.zig");

pub const FunctionFlavor = enum(u8) {
    lua,
    native,
};

pub const Function = struct {
    header: object.Header,
    flavor: FunctionFlavor,
    arity: u8,

    pub fn create(allocator: std.mem.Allocator, flavor: FunctionFlavor) !*Function {
        const self = try allocator.create(Function);
        self.* = .{
            .header = object.Header.init(.function),
            .flavor = flavor,
            .arity = 0,
        };
        return self;
    }

    pub fn destroy(self: *Function, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

pub const Closure = struct {
    header: object.Header,
    function: ?*Function,
    upvalue_count: usize,

    pub fn create(allocator: std.mem.Allocator, function: ?*Function, upvalue_count: usize) !*Closure {
        const self = try allocator.create(Closure);
        self.* = .{
            .header = object.Header.init(.closure),
            .function = function,
            .upvalue_count = upvalue_count,
        };
        return self;
    }

    pub fn destroy(self: *Closure, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

pub const Upvalue = struct {
    header: object.Header,
    slot_index: ?usize,

    pub fn create(allocator: std.mem.Allocator, slot_index: ?usize) !*Upvalue {
        const self = try allocator.create(Upvalue);
        self.* = .{
            .header = object.Header.init(.upvalue),
            .slot_index = slot_index,
        };
        return self;
    }

    pub fn destroy(self: *Upvalue, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

test "function placeholders allocation contract" {
    var counter = runtime_allocator.CountingAllocator.init(std.testing.allocator);
    const alloc = counter.allocator();

    const f = try Function.create(alloc, .lua);
    defer f.destroy(alloc);
    try std.testing.expectEqual(object.Kind.function, f.header.kind);
    try std.testing.expectEqual(FunctionFlavor.lua, f.flavor);
    try std.testing.expectEqual(@as(u8, 0), f.arity);

    const c = try Closure.create(alloc, f, 1);
    defer c.destroy(alloc);
    try std.testing.expectEqual(object.Kind.closure, c.header.kind);
    try std.testing.expectEqual(f, c.function.?);
    try std.testing.expectEqual(@as(usize, 1), c.upvalue_count);

    const up = try Upvalue.create(alloc, 0);
    defer up.destroy(alloc);
    try std.testing.expectEqual(object.Kind.upvalue, up.header.kind);
    try std.testing.expectEqual(@as(?usize, 0), up.slot_index);

    try std.testing.expectEqual(@as(usize, 3), counter.allocations);
}
