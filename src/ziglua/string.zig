const std = @import("std");
const object = @import("object.zig");

/// Interned string storage. All strings with the same content share one
/// `String` allocation. This enables O(1) string equality by pointer comparison
/// and reduces memory for repeated strings.
///
/// Usage:
///   var st = StringTable.init(allocator);
///   defer st.deinit();
///   const s = try st.intern("hello");
///   const s2 = try st.intern("hello");
///   assert(s == s2); // same pointer
pub const StringTable = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(*String),
    byte_count: usize,

    pub fn init(allocator: std.mem.Allocator) StringTable {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(*String).init(allocator),
            .byte_count = 0,
        };
    }

    pub fn deinit(self: *StringTable) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            const s = entry.value_ptr.*;
            self.allocator.free(s.bytes);
            self.allocator.destroy(s);
        }
        self.map.deinit();
        self.byte_count = 0;
    }

    /// Intern a string. If an identical string already exists, returns the
    /// existing pointer. Otherwise creates a new one.
    pub fn intern(self: *StringTable, source: []const u8) !*String {
        if (self.map.get(source)) |existing| return existing;
        const owned = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned);

        const s = try self.allocator.create(String);
        errdefer self.allocator.destroy(s);

        s.* = .{
            .header = object.Header.init(.string),
            .bytes = owned,
        };
        try self.map.put(owned, s);
        self.byte_count += source.len;
        return s;
    }

    /// Look up an interned string without creating one.
    /// Returns null if the string has not been interned.
    pub fn lookup(self: *StringTable, source: []const u8) ?*String {
        return self.map.get(source);
    }

    /// Total number of unique interned strings.
    pub fn count(self: *StringTable) usize {
        return self.map.count();
    }

    /// Total bytes stored across all interned strings.
    pub fn totalBytes(self: *StringTable) usize {
        return self.byte_count;
    }
};

/// A single interned string. Owns its bytes via the StringTable's allocator.
/// Destroy by calling StringTable.deinit() (not individual String.destroy).
pub const String = struct {
    header: object.Header,
    bytes: []u8,

    pub fn create(allocator: std.mem.Allocator, source: []const u8) !*String {
        const self = try allocator.create(String);
        errdefer allocator.destroy(self);

        const owned = try allocator.dupe(u8, source);
        errdefer allocator.free(owned);

        self.* = .{
            .header = object.Header.init(.string),
            .bytes = owned,
        };
        return self;
    }

    pub fn destroy(self: *String, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    pub fn slice(self: *const String) []const u8 {
        return self.bytes;
    }
};

test "string owns copied bytes" {
    const alloc = std.testing.allocator;
    var source = [_]u8{ 'a', 0, 'b' };

    const s = try String.create(alloc, source[0..]);
    defer s.destroy(alloc);

    source[0] = 'z';

    try std.testing.expectEqual(object.Kind.string, s.header.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', 0, 'b' }, s.slice());
}

test "string table interns identical strings to same pointer" {
    const alloc = std.testing.allocator;
    var st = StringTable.init(alloc);
    defer st.deinit();

    const s1 = try st.intern("hello");
    const s2 = try st.intern("hello");
    const s3 = try st.intern("world");

    try std.testing.expect(s1 == s2);
    try std.testing.expect(s1 != s3);
    try std.testing.expectEqual(@as(usize, 2), st.count());
    try std.testing.expectEqualStrings("hello", s1.slice());
    try std.testing.expectEqualStrings("world", s3.slice());
}

test "string table lookup without creation" {
    const alloc = std.testing.allocator;
    var st = StringTable.init(alloc);
    defer st.deinit();

    try std.testing.expect(st.lookup("missing") == null);

    const s = try st.intern("found");
    const found = st.lookup("found");
    try std.testing.expect(found != null);
    try std.testing.expect(found.? == s);
}

test "string table deinit frees all memory" {
    const alloc = std.testing.allocator;
    var st = StringTable.init(alloc);
    _ = try st.intern("one");
    _ = try st.intern("two");
    _ = try st.intern("three");
    try std.testing.expectEqual(@as(usize, 3), st.count());
    st.deinit();
    // No leaks — std.testing.allocator would catch them
}

test "string table byte count" {
    const alloc = std.testing.allocator;
    var st = StringTable.init(alloc);
    defer st.deinit();

    _ = try st.intern("abc"); // 3 bytes
    _ = try st.intern("abc"); // dedup, not counted again
    _ = try st.intern("de"); // 2 bytes
    try std.testing.expectEqual(@as(usize, 5), st.totalBytes());
}

test "string table with empty string" {
    const alloc = std.testing.allocator;
    var st = StringTable.init(alloc);
    defer st.deinit();

    const s = try st.intern("");
    try std.testing.expectEqualStrings("", s.slice());
    try std.testing.expectEqual(@as(usize, 1), st.count());
}
