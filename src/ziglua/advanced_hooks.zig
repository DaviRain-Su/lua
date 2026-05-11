const std = @import("std");

pub const HookBoundary = enum {
    metatable_dispatch,
    raw_ops,
    protected_error,
    coroutine_model,
    gc_weak_finalization,
    table_iteration,
    cleanup_finalization,
    binary_dynamic_gates,
    cross_boundary_advanced,
};

pub fn reasonName(boundary: HookBoundary) []const u8 {
    return switch (boundary) {
        .metatable_dispatch => "metatable-dispatch",
        .raw_ops => "raw-ops",
        .protected_error => "protected-error",
        .coroutine_model => "coroutine-model",
        .gc_weak_finalization => "gc-weak-finalization",
        .table_iteration => "table-iteration",
        .cleanup_finalization => "cleanup-finalization",
        .binary_dynamic_gates => "binary-dynamic-gates",
        .cross_boundary_advanced => "cross-boundary-advanced",
    };
}

pub fn isAdvancedReason(reason: []const u8) bool {
    inline for (@typeInfo(HookBoundary).@"enum".fields) |field| {
        const boundary: HookBoundary = @enumFromInt(field.value);
        if (std.mem.eql(u8, reason, reasonName(boundary))) return true;
    }
    return false;
}

pub const HookRecord = struct {
    boundary: HookBoundary,
    shared_by_vm: bool,
    shared_by_aot_fallback: bool,

    pub fn create(allocator: std.mem.Allocator, boundary: HookBoundary) !*HookRecord {
        const self = try allocator.create(HookRecord);
        self.* = .{
            .boundary = boundary,
            .shared_by_vm = true,
            .shared_by_aot_fallback = true,
        };
        return self;
    }

    pub fn destroy(self: *HookRecord, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

test "advanced semantics boundary table covers M6 hook reasons" {
    const expected = [_]struct {
        boundary: HookBoundary,
        reason: []const u8,
    }{
        .{ .boundary = .metatable_dispatch, .reason = "metatable-dispatch" },
        .{ .boundary = .raw_ops, .reason = "raw-ops" },
        .{ .boundary = .protected_error, .reason = "protected-error" },
        .{ .boundary = .coroutine_model, .reason = "coroutine-model" },
        .{ .boundary = .gc_weak_finalization, .reason = "gc-weak-finalization" },
        .{ .boundary = .table_iteration, .reason = "table-iteration" },
        .{ .boundary = .cleanup_finalization, .reason = "cleanup-finalization" },
        .{ .boundary = .binary_dynamic_gates, .reason = "binary-dynamic-gates" },
        .{ .boundary = .cross_boundary_advanced, .reason = "cross-boundary-advanced" },
    };

    inline for (expected) |entry| {
        try std.testing.expectEqualStrings(entry.reason, reasonName(entry.boundary));
    }
}

test "advanced reason lookup accepts only stable M6 hook names" {
    try std.testing.expect(isAdvancedReason("metatable-dispatch"));
    try std.testing.expect(isAdvancedReason("cross-boundary-advanced"));
    try std.testing.expect(!isAdvancedReason("load"));
    try std.testing.expect(!isAdvancedReason("debug"));
}

test "advanced hook records are shared VM/AOT fallback boundaries" {
    const record = try HookRecord.create(std.testing.allocator, .protected_error);
    defer record.destroy(std.testing.allocator);

    try std.testing.expect(record.shared_by_vm);
    try std.testing.expect(record.shared_by_aot_fallback);
}
