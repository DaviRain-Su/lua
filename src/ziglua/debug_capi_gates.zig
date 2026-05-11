const std = @import("std");

const value = @import("value.zig");

pub const Profile = enum {
    native_full,
    wasm_constrained,
    sbf_experimental,
};

pub const DebugMode = enum {
    full,
    subset,
    disabled,
};

pub const DebugApi = enum {
    getinfo,
    sethook_call,
    sethook_return,
    sethook_line,
    sethook_count,
};

pub const GateState = enum {
    enabled,
    unsupported,
    capability_denied,
};

pub const EvidenceBoundary = enum {
    executable_stock_oracle,
    report_only_zig_tests,
    capability_denied_report,
};

pub const DebugGate = struct {
    state: GateState,
    evidence: EvidenceBoundary,
    capability: []const u8,
    reason: []const u8,
};

pub fn debugGate(profile: Profile, mode: DebugMode, api: DebugApi) DebugGate {
    if (mode == .disabled) {
        return denied(debugCapability(api), "debug support disabled for selected profile");
    }

    return switch (profile) {
        .native_full => switch (mode) {
            .full => if (isHook(api))
                .{
                    .state = .unsupported,
                    .evidence = .report_only_zig_tests,
                    .capability = "debug-hooks",
                    .reason = "Zig VM debug hook execution is not implemented; native-full hook evidence is report-only until Zig-backed call/return/line/count hooks are validated",
                }
            else
                .{
                    .state = .unsupported,
                    .evidence = .report_only_zig_tests,
                    .capability = "debug-api",
                    .reason = "Zig VM debug API execution is not implemented; native-full debug introspection evidence is report-only until Zig-backed execution is validated",
                },
            .subset => if (isHook(api))
                .{
                    .state = .unsupported,
                    .evidence = .report_only_zig_tests,
                    .capability = "debug-hooks",
                    .reason = "subset debug mode does not claim hook event execution",
                }
            else
                .{
                    .state = .unsupported,
                    .evidence = .report_only_zig_tests,
                    .capability = "debug-api",
                    .reason = "subset debug introspection is a report-only extension boundary",
                },
            .disabled => unreachable,
        },
        .wasm_constrained => if (isHook(api))
            denied("debug-hooks", hookDeniedReason(api))
        else if (mode == .subset)
            .{
                .state = .unsupported,
                .evidence = .report_only_zig_tests,
                .capability = "debug-api",
                .reason = "wasm-constrained exposes debug introspection only as an explicit subset/report boundary",
            }
        else
            denied("debug-api", "debug support disabled for selected profile"),
        .sbf_experimental => denied(debugCapability(api), "sbf-experimental keeps debug support disabled in spike metadata"),
    };
}

fn denied(capability: []const u8, reason: []const u8) DebugGate {
    return .{
        .state = .capability_denied,
        .evidence = .capability_denied_report,
        .capability = capability,
        .reason = reason,
    };
}

fn isHook(api: DebugApi) bool {
    return switch (api) {
        .getinfo => false,
        .sethook_call, .sethook_return, .sethook_line, .sethook_count => true,
    };
}

fn debugCapability(api: DebugApi) []const u8 {
    return if (isHook(api)) "debug-hooks" else "debug-api";
}

fn hookDeniedReason(api: DebugApi) []const u8 {
    return switch (api) {
        .getinfo => "constrained profiles deny debug API execution explicitly",
        .sethook_call => "constrained profiles deny sethook-call debug hook event execution explicitly",
        .sethook_return => "constrained profiles deny sethook-return debug hook event execution explicitly",
        .sethook_line => "constrained profiles deny sethook-line debug hook event execution explicitly",
        .sethook_count => "constrained profiles deny sethook-count debug hook event execution explicitly",
    };
}

pub const DebugHookRecord = struct {
    api: DebugApi,
    event_name: []const u8,
    gate: DebugGate,

    pub fn create(allocator: std.mem.Allocator, api: DebugApi) !*DebugHookRecord {
        const self = try allocator.create(DebugHookRecord);
        self.* = .{
            .api = api,
            .event_name = debugApiName(api),
            .gate = debugGate(.native_full, .full, api),
        };
        return self;
    }

    pub fn destroy(self: *DebugHookRecord, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

pub fn debugApiName(api: DebugApi) []const u8 {
    return switch (api) {
        .getinfo => "getinfo",
        .sethook_call => "sethook-call",
        .sethook_return => "sethook-return",
        .sethook_line => "sethook-line",
        .sethook_count => "sethook-count",
    };
}

pub const ProtectedCallResult = struct {
    ok: bool,
    error_name: []const u8,
};

pub const NativeCallback = *const fn (*CApiBridgeState) anyerror!void;

pub const CApiBridgeState = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(value.Value) = .empty,
    protected_depth: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !CApiBridgeState {
        var self = CApiBridgeState{ .allocator = allocator };
        errdefer self.deinit();
        try self.stack.ensureTotalCapacity(allocator, 2);
        return self;
    }

    pub fn deinit(self: *CApiBridgeState) void {
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *CApiBridgeState, v: value.Value) !void {
        try self.stack.append(self.allocator, v);
    }

    pub fn pop(self: *CApiBridgeState) ?value.Value {
        if (self.stack.items.len == 0) return null;
        return self.stack.pop().?;
    }

    pub fn peek(self: *const CApiBridgeState) ?value.Value {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn stackDepth(self: *const CApiBridgeState) usize {
        return self.stack.items.len;
    }

    pub fn protectedCall(self: *CApiBridgeState, callback: NativeCallback) ProtectedCallResult {
        const base = self.stack.items.len;
        self.protected_depth += 1;
        defer self.protected_depth -= 1;

        callback(self) catch |err| {
            self.stack.shrinkRetainingCapacity(base);
            return .{ .ok = false, .error_name = @errorName(err) };
        };
        return .{ .ok = true, .error_name = "" };
    }
};

pub fn failingNativeCallback(_: *CApiBridgeState) anyerror!void {
    return error.NativeCallbackFailed;
}

pub fn pushingThenFailingNativeCallback(state: *CApiBridgeState) anyerror!void {
    try state.push(value.Value.boolean(true));
    return error.NativeCallbackFailed;
}

pub const CApiBridgeReport = struct {
    report_only: bool,
    full_abi_compatibility: bool,
    evidence_boundary: []const u8,
    invariants: []const []const u8,
    unsupported_claim: []const u8,
};

const c_api_invariants = [_][]const u8{
    "state",
    "stack",
    "value-conversion",
    "allocator-bridge",
    "protected-call",
    "registry-placeholder",
    "userdata-placeholder",
};

pub fn cApiBridgeReport() CApiBridgeReport {
    return .{
        .report_only = true,
        .full_abi_compatibility = false,
        .evidence_boundary = "report-only-zig-tests",
        .invariants = &c_api_invariants,
        .unsupported_claim = "no external C ABI compatibility is claimed beyond these Zig-side extension-point invariants",
    };
}

test "debug gates keep native hooks report-only and deny constrained hooks explicitly" {
    const native_line = debugGate(.native_full, .full, .sethook_line);
    try std.testing.expectEqual(GateState.unsupported, native_line.state);
    try std.testing.expectEqual(EvidenceBoundary.report_only_zig_tests, native_line.evidence);
    try std.testing.expect(std.mem.indexOf(u8, native_line.reason, "Zig VM debug hook execution is not implemented") != null);

    const hook_apis = [_]DebugApi{ .sethook_call, .sethook_return, .sethook_line, .sethook_count };
    for (hook_apis) |hook_api| {
        const wasm_hook = debugGate(.wasm_constrained, .subset, hook_api);
        try std.testing.expectEqual(GateState.capability_denied, wasm_hook.state);
        try std.testing.expectEqual(EvidenceBoundary.capability_denied_report, wasm_hook.evidence);
        try std.testing.expectEqualStrings("debug-hooks", wasm_hook.capability);
        try std.testing.expect(std.mem.indexOf(u8, wasm_hook.reason, debugApiName(hook_api)) != null);
    }

    const sbf_info = debugGate(.sbf_experimental, .disabled, .getinfo);
    try std.testing.expectEqual(GateState.capability_denied, sbf_info.state);
    try std.testing.expectEqualStrings("debug-api", sbf_info.capability);
}

test "debug hook records allocate through supplied allocator and fail clean" {
    const record = try DebugHookRecord.create(std.testing.allocator, .sethook_call);
    defer record.destroy(std.testing.allocator);
    try std.testing.expectEqual(DebugApi.sethook_call, record.api);
    try std.testing.expectEqualStrings("sethook-call", record.event_name);

    var failing = @import("allocator.zig").FailingAllocator.init(std.testing.allocator, 0);
    try std.testing.expectError(error.OutOfMemory, DebugHookRecord.create(failing.allocator(), .sethook_return));
    try std.testing.expectEqual(@as(usize, 0), failing.outstanding_bytes);
}

test "c api bridge preserves stack and protected-call invariants" {
    var state = try CApiBridgeState.init(std.testing.allocator);
    defer state.deinit();

    try state.push(value.Value.integer(7));
    const failed = state.protectedCall(pushingThenFailingNativeCallback);
    try std.testing.expect(!failed.ok);
    try std.testing.expectEqualStrings("NativeCallbackFailed", failed.error_name);
    try std.testing.expectEqual(@as(usize, 1), state.stackDepth());
    try std.testing.expectEqual(value.Tag.integer, state.peek().?.tag());

    const ok = state.protectedCall(struct {
        fn callback(s: *CApiBridgeState) anyerror!void {
            try s.push(value.Value.boolean(false));
        }
    }.callback);
    try std.testing.expect(ok.ok);
    try std.testing.expectEqual(@as(usize, 2), state.stackDepth());
    try std.testing.expectEqual(value.Tag.boolean, state.peek().?.tag());
}

test "c api bridge allocation failures are recoverable and leak clean" {
    var failing = @import("allocator.zig").FailingAllocator.init(std.testing.allocator, 0);
    try std.testing.expectError(error.OutOfMemory, CApiBridgeState.init(failing.allocator()));
    try std.testing.expectEqual(@as(usize, 0), failing.outstanding_bytes);

    const report = cApiBridgeReport();
    try std.testing.expect(report.report_only);
    try std.testing.expect(!report.full_abi_compatibility);
    try std.testing.expectEqualStrings("report-only-zig-tests", report.evidence_boundary);
}
