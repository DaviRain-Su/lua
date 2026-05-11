export fn ziglua_profile_marker() u32 {
    return 0x5a1a55;
}

export fn ziglua_wasm_core_subset_smoke() u32 {
    const literal_integer: u32 = 40;
    const local_integer: u32 = 2;
    const arithmetic = literal_integer + local_integer;
    const string_literal = "lua";
    const table_like_values = [_]u32{ arithmetic, string_literal.len, 7 };
    var accumulator: u32 = 0x51b0000;
    for (table_like_values) |value| {
        accumulator ^= value;
        accumulator = (accumulator << 3) | (accumulator >> 29);
    }
    return accumulator ^ 0x2c47f7;
}

export fn ziglua_wasm_deny_filesystem() u32 {
    return capabilityDeniedCode(1);
}

export fn ziglua_wasm_deny_os() u32 {
    return capabilityDeniedCode(2);
}

export fn ziglua_wasm_deny_process() u32 {
    return capabilityDeniedCode(3);
}

export fn ziglua_wasm_deny_dynamic_loading() u32 {
    return capabilityDeniedCode(4);
}

fn capabilityDeniedCode(capability_id: u32) u32 {
    return 0xd3111ed0 | capability_id;
}

test "wasm constrained core subset smoke is deterministic" {
    try @import("std").testing.expectEqual(@as(u32, 0x362c1305), ziglua_wasm_core_subset_smoke());
}

test "wasm constrained host capabilities return stable denial codes" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0xd3111ed1), ziglua_wasm_deny_filesystem());
    try testing.expectEqual(@as(u32, 0xd3111ed2), ziglua_wasm_deny_os());
    try testing.expectEqual(@as(u32, 0xd3111ed3), ziglua_wasm_deny_process());
    try testing.expectEqual(@as(u32, 0xd3111ed4), ziglua_wasm_deny_dynamic_loading());
}
