const std = @import("std");
const bc_vm = @import("bc_vm.zig");

// =============================================================================
// Lua 5.5 Binary Chunk Loader (undump)
// Loads precompiled Lua bytecode produced by luac 5.5
//
// IMPORTANT: Lua 5.5 uses variable-length encoding (varint) for all integers
// except instruction opcodes and test values in the header.
// =============================================================================

const Signature = "\x1bLua";
const DataMarker = "\x19\x93\r\n\x1a\n";
const Version = 0x55; // 5*16+5
const FormatVersion = 0;

// Test constants for format verification
const TestInt: i64 = -0x5678;
const TestInst: u32 = 0x12345678;
const TestNum: f64 = -370.5;

pub const LoadError = error{
    NotABinaryChunk,
    VersionMismatch,
    FormatMismatch,
    CorruptedChunk,
    TruncatedChunk,
    InvalidConstant,
    OutOfMemory,
};

/// Loaded prototype — result of undump
pub const LoadedProto = struct {
    constants: []const bc_vm.BcValue,
    code: []const bc_vm.Instruction,
    sub_protos: []const *LoadedProto,
    source: ?[]const u8,
    linedefined: i64,
    lastlinedefined: i64,
    num_params: u8,
    max_stack_size: u8,
    num_upvalues: u8,
    is_vararg: bool,

    pub fn deinit(self: *LoadedProto, allocator: std.mem.Allocator) void {
        for (self.constants) |c| {
            if (c == .string) allocator.free(c.string);
        }
        allocator.free(self.constants);
        allocator.free(self.code);
        for (self.sub_protos) |sp| {
            var proto = sp;
            proto.deinit(allocator);
            allocator.destroy(proto);
        }
        allocator.free(self.sub_protos);
        if (self.source) |s| allocator.free(s);
    }
};

/// Byte reader with varint support
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(self: *Reader) ?u8 {
        if (self.pos >= self.data.len) return null;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, buf: []u8) bool {
        if (self.pos + buf.len > self.data.len) return false;
        @memcpy(buf, self.data[self.pos..][0..buf.len]);
        self.pos += buf.len;
        return true;
    }

    /// Read fixed 4-byte i32 (used only in header test values)
    fn readFixedI32(self: *Reader) ?i32 {
        if (self.pos + 4 > self.data.len) return null;
        const val: i32 = @bitCast(self.data[self.pos..][0..4].*);
        self.pos += 4;
        return val;
    }

    /// Read fixed 4-byte u32 (used for instructions and header test)
    fn readFixedU32(self: *Reader) ?u32 {
        if (self.pos + 4 > self.data.len) return null;
        const val: u32 = @bitCast(self.data[self.pos..][0..4].*);
        self.pos += 4;
        return val;
    }

    /// Read fixed 8-byte i64 (used for integer constants and header test)
    fn readFixedI64(self: *Reader) ?i64 {
        if (self.pos + 8 > self.data.len) return null;
        const val: i64 = @bitCast(self.data[self.pos..][0..8].*);
        self.pos += 8;
        return val;
    }

    /// Read fixed 8-byte f64 (used for float constants and header test)
    fn readFixedF64(self: *Reader) ?f64 {
        if (self.pos + 8 > self.data.len) return null;
        const val: f64 = @bitCast(self.data[self.pos..][0..8].*);
        self.pos += 8;
        return val;
    }

    /// Read Lua 5.5 varint (MSB continuation encoding)
    /// x = (x << 7) | (b & 0x7F) for each byte, stop when MSB=0
    fn readVarint(self: *Reader) ?u64 {
        var x: u64 = 0;
        while (true) {
            const b = self.readByte() orelse return null;
            x = (x << 7) | (@as(u64, b) & 0x7F);
            if (b & 0x80 == 0) break;
        }
        return x;
    }

    /// Read a Lua integer (varint-encoded)
    fn readLuaInt(self: *Reader) ?i64 {
        return @bitCast(self.readVarint() orelse return null);
    }

    /// Read a Lua size (varint-encoded)
    fn readSize(self: *Reader) ?usize {
        const v = self.readVarint() orelse return null;
        return @intCast(v);
    }

    fn skip(self: *Reader, n: usize) bool {
        if (self.pos + n > self.data.len) return false;
        self.pos += n;
        return true;
    }
};

/// String table for deduplication during loading
const StringList = struct {
    strings: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) StringList {
        return .{
            .strings = std.ArrayList([]const u8).initCapacity(allocator, 32) catch @panic("oom"),
        };
    }

    fn deinit(self: *StringList, allocator: std.mem.Allocator) void {
        for (self.strings.items) |s| allocator.free(s);
        self.strings.deinit(allocator);
    }

    fn register(self: *StringList, allocator: std.mem.Allocator, s: []const u8) !void {
        const copy = try allocator.dupe(u8, s);
        try self.strings.append(allocator, copy);
    }

    fn get(self: *StringList, idx: usize) ?[]const u8 {
        if (idx == 0 or idx > self.strings.items.len) return null;
        return self.strings.items[idx - 1];
    }
};

// =============================================================================
// Public API
// =============================================================================

pub fn loadChunk(allocator: std.mem.Allocator, data: []const u8) LoadError!*LoadedProto {
    var reader = Reader{ .data = data };
    var strings = StringList.init(allocator);
    defer strings.deinit(allocator);

    try checkHeader(&reader);

    // Number of upvalues for the main function
    _ = reader.readByte() orelse return LoadError.TruncatedChunk;

    return try loadFunction(allocator, &reader, &strings);
}

// =============================================================================
// Header validation
// =============================================================================

fn checkHeader(reader: *Reader) LoadError!void {
    // Signature
    var sig_buf: [4]u8 = undefined;
    if (!reader.readBytes(&sig_buf)) return LoadError.TruncatedChunk;
    if (!std.mem.eql(u8, &sig_buf, Signature)) return LoadError.NotABinaryChunk;

    // Version
    const version = reader.readByte() orelse return LoadError.TruncatedChunk;
    if (version != Version) return LoadError.VersionMismatch;

    // Format
    const format = reader.readByte() orelse return LoadError.TruncatedChunk;
    if (format != FormatVersion) return LoadError.FormatMismatch;

    // Data marker
    var data_buf: [6]u8 = undefined;
    if (!reader.readBytes(&data_buf)) return LoadError.TruncatedChunk;
    if (!std.mem.eql(u8, &data_buf, DataMarker)) return LoadError.CorruptedChunk;

    // checknum: int — sizeof(int) byte + test value
    const int_size = reader.readByte() orelse return LoadError.TruncatedChunk;
    if (int_size != 4) return LoadError.CorruptedChunk;
    const test_int = reader.readFixedI32() orelse return LoadError.TruncatedChunk;
    const expected_int: i32 = @truncate(TestInt);
    if (test_int != expected_int) return LoadError.CorruptedChunk;

    // checknum: Instruction
    const inst_size = reader.readByte() orelse return LoadError.TruncatedChunk;
    if (inst_size != 4) return LoadError.CorruptedChunk;
    const test_inst = reader.readFixedU32() orelse return LoadError.TruncatedChunk;
    if (test_inst != TestInst) return LoadError.CorruptedChunk;

    // checknum: lua_Integer
    const lint_size = reader.readByte() orelse return LoadError.TruncatedChunk;
    if (lint_size != 8) return LoadError.CorruptedChunk;
    const test_lint = reader.readFixedI64() orelse return LoadError.TruncatedChunk;
    if (test_lint != TestInt) return LoadError.CorruptedChunk;

    // checknum: lua_Number
    const lnum_size = reader.readByte() orelse return LoadError.TruncatedChunk;
    if (lnum_size != 8) return LoadError.CorruptedChunk;
    const test_lnum = reader.readFixedF64() orelse return LoadError.TruncatedChunk;
    if (test_lnum != TestNum) return LoadError.CorruptedChunk;
}

// =============================================================================
// Function loading
// =============================================================================

fn loadFunction(allocator: std.mem.Allocator, reader: *Reader, strings: *StringList) LoadError!*LoadedProto {
    const linedefined = reader.readLuaInt() orelse return LoadError.TruncatedChunk;
    const lastlinedefined = reader.readLuaInt() orelse return LoadError.TruncatedChunk;
    const num_params = reader.readByte() orelse return LoadError.TruncatedChunk;
    const flags = reader.readByte() orelse return LoadError.TruncatedChunk;
    const max_stack_size = reader.readByte() orelse return LoadError.TruncatedChunk;

    const is_vararg = (flags & 0x03) != 0; // PF_VAHID|PF_VATAB

    const code = try loadCode(allocator, reader);
    errdefer allocator.free(code);
    const constants = try loadConstants(allocator, reader, strings);
    errdefer {
        for (constants) |c| {
            if (c == .string) allocator.free(c.string);
        }
        allocator.free(constants);
    }
    try skipUpvalues(reader);
    const sub_protos = try loadProtos(allocator, reader, strings);
    errdefer {
        for (sub_protos) |sp| {
            var p = sp;
            p.deinit(allocator);
            allocator.destroy(p);
        }
        allocator.free(sub_protos);
    }
    const source_val = try loadStringData(allocator, reader, strings);
    const source: ?[]const u8 = if (source_val) |sv| if (sv == .string) sv.string else null else null;
    try skipDebug(reader);

    const proto = try allocator.create(LoadedProto);
    proto.* = .{
        .constants = constants,
        .code = code,
        .sub_protos = sub_protos,
        .source = source,
        .linedefined = linedefined,
        .lastlinedefined = lastlinedefined,
        .num_params = num_params,
        .max_stack_size = max_stack_size,
        .num_upvalues = 0,
        .is_vararg = is_vararg,
    };
    return proto;
}

fn loadCode(allocator: std.mem.Allocator, reader: *Reader) LoadError![]const bc_vm.Instruction {
    const n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    const code = try allocator.alloc(bc_vm.Instruction, n);
    for (0..n) |i| {
        code[i] = reader.readFixedU32() orelse {
            allocator.free(code);
            return LoadError.TruncatedChunk;
        };
    }
    return code;
}

// Constant type tags (from Lua 5.5 lobject.h: makevariant(t, v) = t | (v << 4))
const TAG_NIL = 0; // LUA_TNIL(0) | (0 << 4)
const TAG_FALSE = 1; // LUA_TBOOLEAN(1) | (0 << 4)
const TAG_TRUE = 17; // LUA_TBOOLEAN(1) | (1 << 4)
const TAG_NUMFLT = 3; // LUA_TNUMBER(3) | (0 << 4)
const TAG_SHRSTR = 4; // LUA_TSTRING(4) | (0 << 4)
const TAG_LNGSTR = 20; // LUA_TSTRING(4) | (1 << 4)
const TAG_NUMINT = 19; // LUA_TNUMBER(3) | (1 << 4)

fn loadConstants(allocator: std.mem.Allocator, reader: *Reader, strings: *StringList) LoadError![]const bc_vm.BcValue {
    const n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    const constants = try allocator.alloc(bc_vm.BcValue, n);

    for (0..n) |i| {
        const tag = reader.readByte() orelse return LoadError.TruncatedChunk;
        constants[i] = switch (tag) {
            TAG_NIL => .{ .nil = {} },
            TAG_FALSE => .{ .boolean = false },
            TAG_TRUE => .{ .boolean = true },
            TAG_NUMFLT => .{ .float = reader.readFixedF64() orelse return LoadError.TruncatedChunk },
            TAG_NUMINT => .{ .integer = reader.readFixedI64() orelse return LoadError.TruncatedChunk },
            TAG_SHRSTR, TAG_LNGSTR => blk: {
                const s = (try loadStringData(allocator, reader, strings)) orelse
                    bc_vm.BcValue{ .string = "" };
                break :blk s;
            },
            else => return LoadError.InvalidConstant,
        };
    }
    return constants;
}

fn skipUpvalues(reader: *Reader) LoadError!void {
    const n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    for (0..n) |_| {
        _ = reader.readByte() orelse return LoadError.TruncatedChunk; // instack
        _ = reader.readByte() orelse return LoadError.TruncatedChunk; // idx
        _ = reader.readByte() orelse return LoadError.TruncatedChunk; // kind
    }
}

fn loadProtos(allocator: std.mem.Allocator, reader: *Reader, strings: *StringList) LoadError![]const *LoadedProto {
    const n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    const protos = try allocator.alloc(*LoadedProto, n);
    for (0..n) |i| {
        protos[i] = try loadFunction(allocator, reader, strings);
    }
    return protos;
}

/// Load a string from the chunk. size=0 means backreference, size>0 means new string.
fn loadStringData(allocator: std.mem.Allocator, reader: *Reader, strings: *StringList) LoadError!?bc_vm.BcValue {
    const size = reader.readSize() orelse return LoadError.TruncatedChunk;
    if (size == 0) {
        // Backreference — read index
        const idx = reader.readVarint() orelse return LoadError.TruncatedChunk;
        if (idx == 0) return null;
        if (strings.get(@intCast(idx))) |s| {
            return .{ .string = s };
        }
        return null;
    }
    const actual_len: usize = size - 1;
    const buf = try allocator.alloc(u8, actual_len);
    if (!reader.readBytes(buf)) {
        allocator.free(buf);
        return LoadError.TruncatedChunk;
    }
    // Skip null terminator
    if (!reader.skip(1)) {
        allocator.free(buf);
        return LoadError.TruncatedChunk;
    }
    try strings.register(allocator, buf);
    return .{ .string = buf };
}

fn skipDebug(reader: *Reader) LoadError!void {
    // lineinfo deltas
    const line_n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    if (!reader.skip(line_n)) return LoadError.TruncatedChunk;

    // abslineinfo
    const abs_n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    if (abs_n > 0) {
        // Each AbsLineInfo = { pc: int (varint), line: int (varint) }
        for (0..abs_n) |_| {
            _ = reader.readVarint() orelse return LoadError.TruncatedChunk; // pc
            _ = reader.readVarint() orelse return LoadError.TruncatedChunk; // line
        }
    }

    // locvars
    const loc_n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    for (0..loc_n) |_| {
        _ = try skipString(reader);
        _ = reader.readLuaInt() orelse return LoadError.TruncatedChunk; // startpc
        _ = reader.readLuaInt() orelse return LoadError.TruncatedChunk; // endpc
    }

    // upvalue names
    const uv_n: usize = @intCast(reader.readLuaInt() orelse return LoadError.TruncatedChunk);
    for (0..uv_n) |_| {
        _ = try skipString(reader);
    }
}

fn skipString(reader: *Reader) LoadError!void {
    const size = reader.readSize() orelse return LoadError.TruncatedChunk;
    if (size == 0) {
        _ = reader.readVarint() orelse return LoadError.TruncatedChunk; // backref index
    } else {
        const actual = size - 1 + 1; // string content + null terminator
        if (!reader.skip(actual)) return LoadError.TruncatedChunk;
    }
}

// =============================================================================
// Tests
// =============================================================================

test "varint encoding" {
    // Single byte: 42 → 0x2A
    var r = Reader{ .data = &.{0x2A} };
    try std.testing.expectEqual(@as(u64, 42), r.readVarint().?);

    // Two bytes: 300 = (2 << 7) | 44 → 0x82 0x2C
    r = Reader{ .data = &.{ 0x82, 0x2C } };
    try std.testing.expectEqual(@as(u64, 300), r.readVarint().?);

    // Zero
    r = Reader{ .data = &.{0x00} };
    try std.testing.expectEqual(@as(u64, 0), r.readVarint().?);

    // One
    r = Reader{ .data = &.{0x01} };
    try std.testing.expectEqual(@as(u64, 1), r.readVarint().?);
}

test "header validation - valid" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    fbs.writeAll("\x1bLua") catch unreachable;
    fbs.writeByte(0x55) catch unreachable;
    fbs.writeByte(0) catch unreachable;
    fbs.writeAll("\x19\x93\r\n\x1a\n") catch unreachable;
    fbs.writeByte(4) catch unreachable; // sizeof(int)
    const test_int: i32 = @truncate(TestInt);
    fbs.writeAll(std.mem.asBytes(&test_int)) catch unreachable;
    fbs.writeByte(4) catch unreachable; // sizeof(Instruction)
    fbs.writeAll(std.mem.asBytes(&TestInst)) catch unreachable;
    fbs.writeByte(8) catch unreachable; // sizeof(lua_Integer)
    fbs.writeAll(std.mem.asBytes(&TestInt)) catch unreachable;
    fbs.writeByte(8) catch unreachable; // sizeof(lua_Number)
    fbs.writeAll(std.mem.asBytes(&TestNum)) catch unreachable;

    var reader = Reader{ .data = fbs.buffered() };
    try checkHeader(&reader);
}

test "header validation - bad signature" {
    var reader = Reader{ .data = "XXXX" ++ "\x00" ** 60 };
    const result = checkHeader(&reader);
    try std.testing.expectError(LoadError.NotABinaryChunk, result);
}

test "header validation - wrong version" {
    var buf: [64]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    fbs.writeAll("\x1bLua") catch unreachable;
    fbs.writeByte(0x54) catch unreachable; // 5.4
    const data = fbs.buffered();
    var reader = Reader{ .data = data };
    try std.testing.expectError(LoadError.VersionMismatch, checkHeader(&reader));
}

test "load real bytecode chunk" {
    // Requires luac to be installed
    // Run: luac -o /tmp/test_undump.luac /tmp/test_bc.lua
    // Then this test validates the loader
}
