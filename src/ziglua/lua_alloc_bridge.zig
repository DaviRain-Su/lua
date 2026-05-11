const std = @import("std");

const allocator_profiles = @import("allocator.zig");

pub const LuaAllocFn = *const fn (
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque;

pub const bridge_alignment: std.mem.Alignment = .fromByteUnits(16);

pub const LuaAllocatorBridge = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LuaAllocatorBridge {
        return .{ .allocator = allocator };
    }

    pub fn userdata(self: *LuaAllocatorBridge) ?*anyopaque {
        return self;
    }

    pub fn callback() LuaAllocFn {
        return luaAlloc;
    }

    pub fn luaAlloc(
        ud: ?*anyopaque,
        ptr: ?*anyopaque,
        osize: usize,
        nsize: usize,
    ) callconv(.c) ?*anyopaque {
        const self: *LuaAllocatorBridge = @ptrCast(@alignCast(ud orelse return null));
        return self.reallocate(ptr, osize, nsize);
    }

    fn reallocate(self: *LuaAllocatorBridge, ptr: ?*anyopaque, osize: usize, nsize: usize) ?*anyopaque {
        const ret_addr = @returnAddress();

        if (nsize == 0) {
            if (ptr) |old_ptr| {
                if (osize != 0) {
                    self.allocator.rawFree(bytesFromOpaque(old_ptr, osize), bridge_alignment, ret_addr);
                }
            }
            return null;
        }

        if (ptr == null or osize == 0) {
            const new_ptr = self.allocator.rawAlloc(nsize, bridge_alignment, ret_addr) orelse return null;
            return @ptrCast(new_ptr);
        }

        if (osize == nsize) return ptr;

        const old_ptr = ptr.?;
        const old_memory = bytesFromOpaque(old_ptr, osize);

        if (self.allocator.rawRemap(old_memory, bridge_alignment, nsize, ret_addr)) |remapped| {
            return @ptrCast(remapped);
        }

        const new_ptr = self.allocator.rawAlloc(nsize, bridge_alignment, ret_addr) orelse return null;
        const copy_len = @min(osize, nsize);
        @memcpy(new_ptr[0..copy_len], old_memory[0..copy_len]);
        self.allocator.rawFree(old_memory, bridge_alignment, ret_addr);
        return @ptrCast(new_ptr);
    }
};

fn bytesFromOpaque(ptr: *anyopaque, len: usize) []u8 {
    const bytes: [*]u8 = @ptrCast(ptr);
    return bytes[0..len];
}

test "lua alloc bridge semantics" {
    var bridge = LuaAllocatorBridge.init(std.testing.allocator);
    const ud = bridge.userdata();

    const allocated = LuaAllocatorBridge.luaAlloc(ud, null, 0, 4) orelse return error.OutOfMemory;
    var bytes: [*]u8 = @ptrCast(allocated);
    bytes[0] = 0xde;
    bytes[1] = 0xad;
    bytes[2] = 0xbe;
    bytes[3] = 0xef;

    const grown = LuaAllocatorBridge.luaAlloc(ud, allocated, 4, 12) orelse return error.OutOfMemory;
    bytes = @ptrCast(grown);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, bytes[0..4]);
    bytes[4] = 0x44;
    bytes[5] = 0x55;

    const shrunk = LuaAllocatorBridge.luaAlloc(ud, grown, 12, 6) orelse return error.OutOfMemory;
    bytes = @ptrCast(shrunk);
    try std.testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef, 0x44, 0x55 }, bytes[0..6]);

    const freed = LuaAllocatorBridge.luaAlloc(ud, shrunk, 6, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), freed);
}

test "lua alloc bridge returns null on allocation failure" {
    var bounded = allocator_profiles.BoundedAllocator.init(std.testing.allocator, 0);
    var bridge = LuaAllocatorBridge.init(bounded.allocator());

    try std.testing.expectEqual(
        @as(?*anyopaque, null),
        LuaAllocatorBridge.luaAlloc(bridge.userdata(), null, 0, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), bounded.used);
}

test "lua alloc bridge leak clean failure paths" {
    var bounded = allocator_profiles.BoundedAllocator.init(std.testing.allocator, 8);
    var bridge = LuaAllocatorBridge.init(bounded.allocator());
    const ud = bridge.userdata();

    const allocated = LuaAllocatorBridge.luaAlloc(ud, null, 0, 8) orelse return error.OutOfMemory;
    var bytes: [*]u8 = @ptrCast(allocated);
    bytes[0] = 0xa1;
    bytes[7] = 0xb2;
    try std.testing.expectEqual(@as(usize, 8), bounded.used);

    const failed_grow = LuaAllocatorBridge.luaAlloc(ud, allocated, 8, 9);
    try std.testing.expectEqual(@as(?*anyopaque, null), failed_grow);
    try std.testing.expectEqual(@as(usize, 8), bounded.used);
    try std.testing.expectEqual(@as(u8, 0xa1), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xb2), bytes[7]);

    const freed = LuaAllocatorBridge.luaAlloc(ud, allocated, 8, 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), freed);
    try std.testing.expectEqual(@as(usize, 0), bounded.used);
}
