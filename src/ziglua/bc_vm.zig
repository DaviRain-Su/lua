const std = @import("std");

// =============================================================================
// Lua 5.5 Bytecode Instruction Set
// Based on lopcodes.h — register-based VM with 32-bit instructions
// =============================================================================

/// Instruction format: 32-bit unsigned integer
/// Format iABC:  [7:Op][8:A][1:k][8:B][8:C]
/// Format iABx:  [7:Op][8:A][17:Bx]
/// Format iAsBx: [7:Op][8:A][17:sBx] (signed, excess-K)
/// Format iAx:   [7:Op][25:Ax]
/// Format isJ:   [7:Op][25:sJ] (signed jump)
pub const Instruction = u32;

pub const Op = enum(u7) {
    // Load/Move
    OP_MOVE = 0,
    OP_LOADI,
    OP_LOADF,
    OP_LOADK,
    OP_LOADKX,
    OP_LOADFALSE,
    OP_LFALSESKIP,
    OP_LOADTRUE,
    OP_LOADNIL,
    // Upvalues
    OP_GETUPVAL,
    OP_SETUPVAL,
    // Table access
    OP_GETTABUP,
    OP_GETTABLE,
    OP_GETI,
    OP_GETFIELD,
    OP_SETTABUP,
    OP_SETTABLE,
    OP_SETI,
    OP_SETFIELD,
    OP_NEWTABLE,
    OP_SELF,
    // Arithmetic (constant variant)
    OP_ADDI,
    OP_ADDK,
    OP_SUBK,
    OP_MULK,
    OP_MODK,
    OP_POWK,
    OP_DIVK,
    OP_IDIVK,
    OP_BANDK,
    OP_BORK,
    OP_BXORK,
    OP_SHLI,
    OP_SHRI,
    // Arithmetic (register variant)
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_MOD,
    OP_POW,
    OP_DIV,
    OP_IDIV,
    OP_BAND,
    OP_BOR,
    OP_BXOR,
    OP_SHL,
    OP_SHR,
    // Metamethod helpers
    OP_MMBIN,
    OP_MMBINI,
    OP_MMBINK,
    // Unary
    OP_UNM,
    OP_BNOT,
    OP_NOT,
    OP_LEN,
    OP_CONCAT,
    // Closures
    OP_CLOSE,
    OP_TBC,
    // Control flow
    OP_JMP,
    // Comparisons
    OP_EQ,
    OP_LT,
    OP_LE,
    OP_EQK,
    OP_EQI,
    OP_LTI,
    OP_LEI,
    OP_GTI,
    OP_GEI,
    OP_TEST,
    OP_TESTSET,
    // Function calls
    OP_CALL,
    OP_TAILCALL,
    OP_RETURN,
    OP_RETURN0,
    OP_RETURN1,
    // Loops
    OP_FORLOOP,
    OP_FORPREP,
    OP_TFORPREP,
    OP_TFORCALL,
    OP_TFORLOOP,
    // Tables & misc
    OP_SETLIST,
    OP_CLOSURE,
    OP_VARARG,
    OP_GETVARG,
    OP_ERRNNIL,
    OP_VARARGPREP,
    OP_EXTRAARG,
    // Sentinel
    _,
};

// Instruction bit layout
pub const SIZE_OP = 7;
pub const SIZE_A = 8;
pub const SIZE_B = 8;
pub const SIZE_C = 8;
pub const SIZE_Bx = SIZE_C + SIZE_B + 1; // 17
pub const SIZE_Ax = SIZE_Bx + SIZE_A; // 25
pub const SIZE_sJ = SIZE_Bx + SIZE_A; // 25

pub const POS_OP = 0;
pub const POS_A = SIZE_OP;
pub const POS_k = POS_A + SIZE_A;
pub const POS_B = POS_k + 1;
pub const POS_C = POS_B + SIZE_B;

// Bit masks
pub const MASK_OP = (@as(u32, 1) << SIZE_OP) - 1;
pub const MASK_A = (@as(u32, 1) << SIZE_A) - 1;
pub const MASK_B = (@as(u32, 1) << SIZE_B) - 1;
pub const MASK_C = (@as(u32, 1) << SIZE_C) - 1;
pub const MASK_Bx = (@as(u32, 1) << SIZE_Bx) - 1;
pub const MASK_Ax = (@as(u32, 1) << SIZE_Ax) - 1;

// Instruction decoding
pub fn getOp(i: Instruction) Op {
    return @enumFromInt(i & MASK_OP);
}

pub fn getA(i: Instruction) u8 {
    return @intCast((i >> POS_A) & MASK_A);
}

pub fn getB(i: Instruction) u8 {
    return @intCast((i >> POS_B) & MASK_B);
}

pub fn getC(i: Instruction) u8 {
    return @intCast((i >> POS_C) & MASK_C);
}

pub fn getk(i: Instruction) bool {
    return ((i >> POS_k) & 1) != 0;
}

pub fn getBx(i: Instruction) u17 {
    return @intCast((i >> POS_k) & MASK_Bx);
}

pub fn getAx(i: Instruction) u25 {
    return @intCast(i >> POS_A);
}

/// Signed sBx (excess-K encoding: max/2)
pub fn getsBx(i: Instruction) i18 {
    const raw: u17 = @intCast((i >> POS_k) & MASK_Bx);
    const max: u17 = MASK_Bx >> 1;
    return @as(i18, @intCast(raw)) - @as(i18, @intCast(max));
}

/// Signed sJ (excess-K encoding)
pub fn getsJ(i: Instruction) i26 {
    const raw: u25 = @intCast(i >> POS_A);
    const max: u25 = MASK_Ax >> 1;
    return @as(i26, @intCast(raw)) - @as(i26, @intCast(max));
}

// Instruction encoding helpers
pub fn encodeABC(op: Op, a: u8, b: u8, c: u8) Instruction {
    return @intFromEnum(op) |
        (@as(Instruction, a) << POS_A) |
        (@as(Instruction, b) << POS_B) |
        (@as(Instruction, c) << POS_C);
}

pub fn encodeABx(op: Op, a: u8, bx: u17) Instruction {
    return @intFromEnum(op) |
        (@as(Instruction, a) << POS_A) |
        (@as(Instruction, bx) << POS_k);
}

pub fn encodeAsBx(op: Op, a: u8, sbx: i18) Instruction {
    const offset: i18 = @intCast(MASK_Bx >> 1);
    const raw: u17 = @intCast(sbx + offset);
    return @intFromEnum(op) |
        (@as(Instruction, a) << POS_A) |
        (@as(Instruction, raw) << POS_k);
}

pub fn encodeAx(op: Op, ax: u25) Instruction {
    return @intFromEnum(op) | (@as(Instruction, ax) << POS_A);
}

// =============================================================================
// Bytecode Value for the register-based VM
// =============================================================================

pub const BcValue = union(enum) {
    nil: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    // table/closure/function represented by indices or pointers at runtime
};

// =============================================================================
// Prototype — a compiled function body
// =============================================================================

pub const Prototype = struct {
    constants: []const BcValue,
    code: []const Instruction,
    prototypes: []const *Prototype,
    /// Source line for each instruction (1-based)
    line_info: []const u32,
    /// Number of registers needed
    max_stack_size: u8,
    /// Number of upvalues
    num_upvalues: u8,
    /// Number of parameters
    num_params: u8,
    /// Has varargs
    is_vararg: bool,
};

// =============================================================================
// Bytecode Compiler — converts Lua source to bytecode
// =============================================================================

pub fn compile(allocator: std.mem.Allocator, source: []const u8) !*Prototype {
    _ = allocator;
    _ = source;
    // TODO: Implement compiler — for now return an error
    return error.NotImplemented;
}

// =============================================================================
// Bytecode VM — executes compiled Lua bytecode
// =============================================================================

pub const BcVm = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(BcValue),

    pub fn init(allocator: std.mem.Allocator) BcVm {
        return .{
            .allocator = allocator,
            .stack = std.ArrayList(BcValue).initCapacity(allocator, 256) catch @panic("oom"),
        };
    }

    pub fn deinit(self: *BcVm) void {
        self.stack.deinit(self.allocator);
    }

    /// Execute a prototype
    pub fn execute(self: *BcVm, _proto: *Prototype) !void {
        _ = self;
        _ = _proto;
        // Full bytecode execution pending compiler implementation
    }
};

// =============================================================================
// Tests
// =============================================================================

test "instruction encoding and decoding roundtrip" {
    const i = encodeABC(.OP_ADD, 5, 10, 3);
    try std.testing.expectEqual(Op.OP_ADD, getOp(i));
    try std.testing.expectEqual(@as(u8, 5), getA(i));
    try std.testing.expectEqual(@as(u8, 10), getB(i));
    try std.testing.expectEqual(@as(u8, 3), getC(i));
}

test "ABx encoding roundtrip" {
    const i = encodeABx(.OP_LOADK, 2, 1000);
    try std.testing.expectEqual(Op.OP_LOADK, getOp(i));
    try std.testing.expectEqual(@as(u8, 2), getA(i));
    try std.testing.expectEqual(@as(u17, 1000), getBx(i));
}

test "sBx signed encoding roundtrip" {
    const i = encodeAsBx(.OP_JMP, 0, -10);
    try std.testing.expectEqual(Op.OP_JMP, getOp(i));
    try std.testing.expectEqual(@as(i18, -10), getsBx(i));
}

test "sBx zero offset" {
    const i = encodeAsBx(.OP_FORLOOP, 3, 0);
    try std.testing.expectEqual(@as(i18, 0), getsBx(i));
}

test "Ax encoding roundtrip" {
    const i = encodeAx(.OP_EXTRAARG, 12345);
    try std.testing.expectEqual(Op.OP_EXTRAARG, getOp(i));
    try std.testing.expectEqual(@as(u25, 12345), getAx(i));
}

test "k flag in ABC" {
    // OP_EQ uses k flag
    const i: Instruction = @intFromEnum(Op.OP_EQ) |
        (@as(Instruction, 1) << POS_A) |
        (@as(Instruction, 1) << POS_k) |
        (@as(Instruction, 2) << POS_B) |
        (@as(Instruction, 3) << POS_C);
    try std.testing.expectEqual(Op.OP_EQ, getOp(i));
    try std.testing.expect(getk(i));
    try std.testing.expectEqual(@as(u8, 1), getA(i));
}
