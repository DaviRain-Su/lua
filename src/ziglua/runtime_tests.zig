const std = @import("std");

const advanced_hooks = @import("advanced_hooks.zig");
const allocator = @import("allocator.zig");
const debug_capi_gates = @import("debug_capi_gates.zig");
const function = @import("function.zig");
const lua_alloc_bridge = @import("lua_alloc_bridge.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const thread = @import("thread.zig");
const userdata = @import("userdata.zig");
const value = @import("value.zig");
const vm_level0 = @import("vm_level0.zig");

test {
    _ = advanced_hooks;
    _ = debug_capi_gates;
    _ = lua_alloc_bridge;
    _ = vm_level0;
}

test "runtime constructors require allocator" {
    const alloc = std.testing.allocator;

    const s = try string.String.create(alloc, "runtime");
    defer s.destroy(alloc);
    try std.testing.expectEqual(object.Kind.string, s.header.kind);

    const t = try table.Table.create(alloc);
    defer t.destroy(alloc);
    try std.testing.expectEqual(object.Kind.table, t.header.kind);

    const proto = try function.Function.create(alloc, .lua);
    defer proto.destroy(alloc);
    try std.testing.expectEqual(object.Kind.function, proto.header.kind);

    const closure = try function.Closure.create(alloc, proto, 0);
    defer closure.destroy(alloc);
    try std.testing.expectEqual(object.Kind.closure, closure.header.kind);

    const th = try thread.Thread.create(alloc);
    defer th.destroy(alloc);
    try std.testing.expectEqual(object.Kind.thread, th.header.kind);

    const ud = try userdata.Userdata.create(alloc, 16);
    defer ud.destroy(alloc);
    try std.testing.expectEqual(object.Kind.userdata, ud.header.kind);
}

test "immediate scalar values allocate nothing" {
    const failing = allocator.failingAllocator();

    try std.testing.expectEqual(value.Tag.nil, value.Value.nil().tag());
    try std.testing.expectEqual(value.Tag.boolean, value.Value.boolean(true).tag());
    try std.testing.expectEqual(value.Tag.integer, value.Value.integer(42).tag());
    try std.testing.expectEqual(value.Tag.float, value.Value.float(3.5).tag());

    try std.testing.expectError(error.OutOfMemory, failing.alloc(u8, 1));
}

test "oom is reported not panicked" {
    var zero_budget = allocator.BoundedAllocator.init(std.testing.allocator, 0);
    try std.testing.expectError(error.OutOfMemory, string.String.create(zero_budget.allocator(), "oom"));
    try std.testing.expectError(error.OutOfMemory, table.Table.create(zero_budget.allocator()));
    try std.testing.expectError(error.OutOfMemory, function.Function.create(zero_budget.allocator(), .lua));
    try std.testing.expectEqual(@as(usize, 0), zero_budget.used);

    var fail_immediately = allocator.FailingAllocator.init(std.testing.allocator, 0);
    try std.testing.expectError(error.OutOfMemory, string.String.create(fail_immediately.allocator(), "oom"));
    try std.testing.expectError(error.OutOfMemory, table.Table.create(fail_immediately.allocator()));
    try std.testing.expectError(error.OutOfMemory, function.Function.create(fail_immediately.allocator(), .lua));
    try std.testing.expectEqual(@as(usize, 0), fail_immediately.outstanding_bytes);
}

test "constrained allocator policy" {
    var bounded = allocator.BoundedAllocator.init(std.testing.allocator, @sizeOf(string.String) + 11);
    const alloc = bounded.allocator();
    const s = try string.String.create(alloc, "constrained");
    defer s.destroy(alloc);
    try std.testing.expectEqualSlices(u8, "constrained", s.slice());
}

test "runtime allocator leak detection" {
    var bounded = allocator.BoundedAllocator.init(std.testing.allocator, @sizeOf(string.String) + @sizeOf(table.Table) + @sizeOf(function.Function) + 4);
    const bounded_alloc = bounded.allocator();

    const s = try string.String.create(bounded_alloc, "leak");
    const t = try table.Table.create(bounded_alloc);
    const f = try function.Function.create(bounded_alloc, .lua);
    f.destroy(bounded_alloc);
    t.destroy(bounded_alloc);
    s.destroy(bounded_alloc);
    try std.testing.expectEqual(@as(usize, 0), bounded.used);

    var too_small = allocator.BoundedAllocator.init(std.testing.allocator, @sizeOf(string.String));
    try std.testing.expectError(error.OutOfMemory, string.String.create(too_small.allocator(), "x"));
    try std.testing.expectEqual(@as(usize, 0), too_small.used);

    for (0..2) |fail_after| {
        var failing_profile = allocator.FailingAllocator.init(std.testing.allocator, fail_after);
        try std.testing.expectError(error.OutOfMemory, string.String.create(failing_profile.allocator(), "fail"));
        try std.testing.expectEqual(@as(usize, 0), failing_profile.outstanding_bytes);
    }
}

test "advanced semantic hook boundaries are allocator owned and fail clean" {
    const alloc = std.testing.allocator;
    const record = try advanced_hooks.HookRecord.create(alloc, .metatable_dispatch);
    defer record.destroy(alloc);
    try std.testing.expectEqual(advanced_hooks.HookBoundary.metatable_dispatch, record.boundary);
    try std.testing.expectEqualStrings("metatable-dispatch", advanced_hooks.reasonName(record.boundary));

    var fail_immediately = allocator.FailingAllocator.init(std.testing.allocator, 0);
    try std.testing.expectError(error.OutOfMemory, advanced_hooks.HookRecord.create(fail_immediately.allocator(), .coroutine_model));
    try std.testing.expectEqual(@as(usize, 0), fail_immediately.outstanding_bytes);
}

test "debug and c api gates are explicit and allocator failure recoverable" {
    const native_debug = debug_capi_gates.debugGate(.native_full, .full, .sethook_line);
    try std.testing.expectEqual(debug_capi_gates.GateState.unsupported, native_debug.state);
    try std.testing.expectEqual(debug_capi_gates.EvidenceBoundary.report_only_zig_tests, native_debug.evidence);

    const wasm_hook = debug_capi_gates.debugGate(.wasm_constrained, .subset, .sethook_count);
    try std.testing.expectEqual(debug_capi_gates.GateState.capability_denied, wasm_hook.state);
    try std.testing.expectEqualStrings("debug-hooks", wasm_hook.capability);
    try std.testing.expect(std.mem.indexOf(u8, wasm_hook.reason, "sethook-count") != null);

    var failing_profile = allocator.FailingAllocator.init(std.testing.allocator, 0);
    try std.testing.expectError(
        error.OutOfMemory,
        debug_capi_gates.DebugHookRecord.create(failing_profile.allocator(), .sethook_call),
    );
    try std.testing.expectEqual(@as(usize, 0), failing_profile.outstanding_bytes);

    var capi = try debug_capi_gates.CApiBridgeState.init(std.testing.allocator);
    defer capi.deinit();
    try capi.push(value.Value.integer(42));
    const protected = capi.protectedCall(debug_capi_gates.failingNativeCallback);
    try std.testing.expect(!protected.ok);
    try std.testing.expectEqual(@as(usize, 1), capi.stackDepth());
    try std.testing.expectEqual(value.Tag.integer, capi.peek().?.tag());

    try std.testing.expect(debug_capi_gates.cApiBridgeReport().report_only);
    try std.testing.expect(!debug_capi_gates.cApiBridgeReport().full_abi_compatibility);
}
