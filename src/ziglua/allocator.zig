const std = @import("std");

pub const RuntimeAllocator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RuntimeAllocator {
        return .{ .allocator = allocator };
    }
};

pub const HostAllocator = struct {
    backing: std.mem.Allocator,

    pub fn init(backing: std.mem.Allocator) HostAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: HostAllocator) std.mem.Allocator {
        return self.backing;
    }
};

pub const ArenaAllocator = struct {
    arena: std.heap.ArenaAllocator,
    active: bool = true,

    pub fn init(backing: std.mem.Allocator) ArenaAllocator {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn allocator(self: *ArenaAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = arenaAlloc,
                .resize = arenaResize,
                .remap = arenaRemap,
                .free = arenaFree,
            },
        };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        if (self.active) {
            self.arena.deinit();
            self.active = false;
        }
    }

    fn arenaAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.active) return null;
        return self.arena.allocator().rawAlloc(len, alignment, ret_addr);
    }

    fn arenaResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.active) return false;
        return self.arena.allocator().rawResize(memory, alignment, new_len, ret_addr);
    }

    fn arenaRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.active) return null;
        return self.arena.allocator().rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn arenaFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        if (!self.active) return;
        self.arena.allocator().rawFree(memory, alignment, ret_addr);
    }
};

pub const BoundedAllocator = struct {
    backing: std.mem.Allocator,
    budget: usize,
    used: usize = 0,

    pub fn init(backing: std.mem.Allocator, budget: usize) BoundedAllocator {
        return .{ .backing = backing, .budget = budget };
    }

    pub fn allocator(self: *BoundedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = boundedAlloc,
                .resize = boundedResize,
                .remap = boundedRemap,
                .free = boundedFree,
            },
        };
    }

    fn remaining(self: BoundedAllocator) usize {
        return self.budget - self.used;
    }

    fn canGrow(self: BoundedAllocator, old_len: usize, new_len: usize) bool {
        return new_len <= old_len or new_len - old_len <= self.remaining();
    }

    fn adjustAfterResize(self: *BoundedAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.used += new_len - old_len;
        } else {
            self.used -= old_len - new_len;
        }
    }

    fn boundedAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.remaining()) return null;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.used += len;
        return ptr;
    }

    fn boundedResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.canGrow(memory.len, new_len)) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.adjustAfterResize(memory.len, new_len);
        return true;
    }

    fn boundedRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.canGrow(memory.len, new_len)) return null;
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse fallback: {
            const new_ptr = self.backing.rawAlloc(new_len, alignment, ret_addr) orelse return null;
            const copy_len = @min(memory.len, new_len);
            @memcpy(new_ptr[0..copy_len], memory[0..copy_len]);
            self.backing.rawFree(memory, alignment, ret_addr);
            break :fallback new_ptr;
        };
        self.adjustAfterResize(memory.len, new_len);
        return ptr;
    }

    fn boundedFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        self.used -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

pub const FailingAllocator = struct {
    backing: std.mem.Allocator,
    fail_after: usize,
    attempts: usize = 0,
    outstanding_bytes: usize = 0,

    pub fn init(backing: std.mem.Allocator, fail_after: usize) FailingAllocator {
        return .{ .backing = backing, .fail_after = fail_after };
    }

    pub fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = failingAlloc,
                .resize = failingResize,
                .remap = failingRemap,
                .free = failingFree,
            },
        };
    }

    fn shouldFail(self: *FailingAllocator) bool {
        defer self.attempts += 1;
        return self.attempts >= self.fail_after;
    }

    fn failingAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.shouldFail()) return null;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.outstanding_bytes += len;
        return ptr;
    }

    fn failingResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.shouldFail()) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            self.outstanding_bytes += new_len - memory.len;
        } else {
            self.outstanding_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn failingRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and self.shouldFail()) return null;
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse fallback: {
            const new_ptr = self.backing.rawAlloc(new_len, alignment, ret_addr) orelse return null;
            const copy_len = @min(memory.len, new_len);
            @memcpy(new_ptr[0..copy_len], memory[0..copy_len]);
            self.backing.rawFree(memory, alignment, ret_addr);
            break :fallback new_ptr;
        };
        if (new_len >= memory.len) {
            self.outstanding_bytes += new_len - memory.len;
        } else {
            self.outstanding_bytes -= memory.len - new_len;
        }
        return ptr;
    }

    fn failingFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.outstanding_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

var failing_allocator_state: u8 = 0;

pub fn failingAllocator() std.mem.Allocator {
    return .{
        .ptr = &failing_allocator_state,
        .vtable = &.{
            .alloc = std.mem.Allocator.noAlloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = std.mem.Allocator.noFree,
        },
    };
}

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    frees: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.bytes_allocated += len;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            self.bytes_allocated += new_len - memory.len;
        } else {
            self.bytes_freed += memory.len - new_len;
        }
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) {
            self.bytes_allocated += new_len - memory.len;
        } else {
            self.bytes_freed += memory.len - new_len;
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.bytes_freed += memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const RepresentativeObjects = struct {
    string: *@import("string.zig").String,
    table: *@import("table.zig").Table,
    function: *@import("function.zig").Function,

    fn destroy(self: RepresentativeObjects, alloc: std.mem.Allocator) void {
        self.function.destroy(alloc);
        self.table.destroy(alloc);
        self.string.destroy(alloc);
    }
};

fn allocateRepresentativeObjects(alloc: std.mem.Allocator) !RepresentativeObjects {
    const string = @import("string.zig");
    const table = @import("table.zig");
    const function = @import("function.zig");

    const s = try string.String.create(alloc, "oom");
    errdefer s.destroy(alloc);

    const t = try table.Table.create(alloc);
    errdefer t.destroy(alloc);

    const f = try function.Function.create(alloc, .lua);
    errdefer f.destroy(alloc);

    return .{
        .string = s,
        .table = t,
        .function = f,
    };
}

test "runtime allocator wrapper stores explicit allocator" {
    const runtime = RuntimeAllocator.init(std.testing.allocator);
    const bytes = try runtime.allocator.alloc(u8, 2);
    defer runtime.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 2), bytes.len);
}

test "host allocator profile" {
    const string = @import("string.zig");
    const table = @import("table.zig");
    const function = @import("function.zig");

    const profile = HostAllocator.init(std.testing.allocator);
    const alloc = profile.allocator();

    const s = try string.String.create(alloc, "host");
    defer s.destroy(alloc);

    const t = try table.Table.create(alloc);
    defer t.destroy(alloc);

    const f = try function.Function.create(alloc, .lua);
    defer f.destroy(alloc);
}

test "arena allocator profile" {
    const string = @import("string.zig");
    const table = @import("table.zig");
    const function = @import("function.zig");

    var profile = ArenaAllocator.init(std.testing.allocator);
    const alloc = profile.allocator();

    const s = try string.String.create(alloc, "compile phase");
    const t = try table.Table.create(alloc);
    const f = try function.Function.create(alloc, .lua);

    try std.testing.expectEqualSlices(u8, "compile phase", s.slice());
    try std.testing.expectEqual(@as(usize, 0), t.array_slots);
    try std.testing.expectEqual(function.FunctionFlavor.lua, f.flavor);

    profile.deinit();
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
}

test "bounded allocator budget" {
    const string = @import("string.zig");
    const table = @import("table.zig");

    var bounded = BoundedAllocator.init(std.testing.allocator, @sizeOf(string.String) + 4);
    const alloc = bounded.allocator();

    const s = try string.String.create(alloc, "okay");
    try std.testing.expectEqual(@as(usize, @sizeOf(string.String) + 4), bounded.used);
    s.destroy(alloc);
    try std.testing.expectEqual(@as(usize, 0), bounded.used);

    var too_small_for_string_bytes = BoundedAllocator.init(std.testing.allocator, @sizeOf(string.String));
    try std.testing.expectError(error.OutOfMemory, string.String.create(too_small_for_string_bytes.allocator(), "x"));
    try std.testing.expectEqual(@as(usize, 0), too_small_for_string_bytes.used);

    var too_small_for_table = BoundedAllocator.init(std.testing.allocator, @sizeOf(table.Table) - 1);
    try std.testing.expectError(error.OutOfMemory, table.Table.create(too_small_for_table.allocator()));
    try std.testing.expectEqual(@as(usize, 0), too_small_for_table.used);
}

test "failing allocator deterministic oom" {
    for (0..5) |fail_after| {
        var failing = FailingAllocator.init(std.testing.allocator, fail_after);
        if (fail_after < 4) {
            try std.testing.expectError(error.OutOfMemory, allocateRepresentativeObjects(failing.allocator()));
        } else {
            const group = try allocateRepresentativeObjects(failing.allocator());
            group.destroy(failing.allocator());
        }
        try std.testing.expectEqual(@as(usize, 0), failing.outstanding_bytes);
    }
}

test "bounded allocator accounting" {
    var bounded = BoundedAllocator.init(std.testing.allocator, 16);
    const alloc = bounded.allocator();

    var bytes = try alloc.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), bounded.used);

    bytes = try alloc.realloc(bytes, 12);
    try std.testing.expectEqual(@as(usize, 12), bounded.used);

    try std.testing.expectError(error.OutOfMemory, alloc.realloc(bytes, 20));
    try std.testing.expectEqual(@as(usize, 12), bounded.used);
    bytes[0] = 0xaa;

    bytes = try alloc.realloc(bytes, 4);
    try std.testing.expectEqual(@as(usize, 4), bounded.used);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);

    alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bounded.used);

    const reused = try alloc.alloc(u8, 16);
    alloc.free(reused);
    try std.testing.expectEqual(@as(usize, 0), bounded.used);
}
