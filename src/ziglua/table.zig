const std = @import("std");
const object = @import("object.zig");
const runtime_allocator = @import("allocator.zig");

/// Object-model-level Table placeholder.
/// The full Table implementation lives in vm_level0.zig (for the VM's Value type).
/// This struct provides the GC-compatible header and basic lifecycle.
/// When Value types are unified (T1.4), this will merge with the VM Table.
pub const Table = struct {
    header: object.Header,
    array_slots: usize,
    hash_slots: usize,
    metatable: ?*Table,

    pub fn create(allocator: std.mem.Allocator) !*Table {
        const self = try allocator.create(Table);
        self.* = .{
            .header = object.Header.init(.table),
            .array_slots = 0,
            .hash_slots = 0,
            .metatable = null,
        };
        return self;
    }

    pub fn destroy(self: *Table, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

test "table uses supplied allocator" {
    var counter = runtime_allocator.CountingAllocator.init(std.testing.allocator);
    const alloc = counter.allocator();

    const t = try Table.create(alloc);
    try std.testing.expectEqual(object.Kind.table, t.header.kind);
    try std.testing.expectEqual(@as(usize, 1), counter.allocations);
    try std.testing.expectEqual(@as(usize, 0), counter.frees);

    t.destroy(alloc);
    try std.testing.expectEqual(@as(usize, 1), counter.frees);
    try std.testing.expectEqual(counter.bytes_allocated, counter.bytes_freed);
}
