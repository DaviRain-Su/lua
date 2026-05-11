const std = @import("std");

// =============================================================================
// Shared helpers for Lua float/integer conversion
// =============================================================================

pub const FloatToIntegerMode = enum { eq, floor, ceil };

/// Convert a float to integer if the float represents an exact integer value.
/// Returns null if the float has a fractional part, is NaN, or overflows i64.
pub fn floatToInteger(value: f64, mode: FloatToIntegerMode) ?i64 {
    if (value != value) return null;
    var rounded = @floor(value);
    if (value != rounded) {
        switch (mode) {
            .eq => return null,
            .floor => {},
            .ceil => rounded += 1.0,
        }
    }
    if (rounded < -9223372036854775808.0 or rounded >= 9223372036854775808.0) return null;
    return @intFromFloat(rounded);
}

/// Reinterpret f64 bits as u64 for use as a hash map key.
pub fn floatTableKey(value: f64) u64 {
    return @bitCast(value);
}

test "floatToInteger exact" {
    try std.testing.expectEqual(@as(i64, 3), floatToInteger(3.0, .eq));
    try std.testing.expectEqual(@as(i64, -7), floatToInteger(-7.0, .eq));
    try std.testing.expect(floatToInteger(3.5, .eq) == null);
    try std.testing.expect(floatToInteger(std.math.nan(f64), .eq) == null);
}

test "floatToInteger floor/ceil" {
    try std.testing.expectEqual(@as(i64, 3), floatToInteger(3.5, .floor));
    try std.testing.expectEqual(@as(i64, 4), floatToInteger(3.5, .ceil));
}

test "floatTableKey roundtrip" {
    const f: f64 = 3.14;
    const key = floatTableKey(f);
    const back: f64 = @bitCast(key);
    try std.testing.expect(f == back);
}
